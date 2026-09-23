//! The video thread: owns the EGL context, the `wl_egl_window` on the video
//! subsurface, and mpv's render context. Frames go from mpv to the compositor
//! without the GTK thread running anything at frame rate — the point of
//! WAYLAND-SUBSURFACE-PLAN.md §3.
//!
//! Two inputs: commands from the GTK thread ([`Cmd`]), and mpv's update
//! callback, which is coalesced into one `dirty` flag so a burst of callbacks
//! costs one `update()`. Everything that touches EGL, GL or the render
//! context happens here; the GTK thread only ever sends.
//!
//! # State machine, briefly
//!
//! - `Surface(sub)` gives the thread a subsurface to render into (a new one on
//!   every reparent: the main window's, then the picture-in-picture window's,
//!   then the main window's again). The EGL window surface is rebuilt on it;
//!   the render context and the EGL context survive, which is what keeps
//!   playback from restarting on a PiP move.
//! - `Attach` builds the render context on the current EGL surface and
//!   replies; if no surface exists yet the reply waits for one.
//! - `Resize` resizes the EGL window and sets the surface's scale, opaque
//!   region and crop in one go, then redraws after a short debounce (GTK
//!   allocates the placeholder twice per window resize).
//! - `Show`/`Hide` gate drawing. A hidden surface is unmapped and forgets its
//!   size, so the first frame after `Show` waits for a fresh `Resize` and
//!   never lands at a stale position.
//! - `Detach` frees the render context with the context current, which is
//!   the teardown order mpv requires and the one that used to trip a
//!   libepoxy assertion on quit when it ran on the GTK thread.
use crate::egl::{EglContext, EglDisplay, EglWindowSurface};
use crate::render::{NativeDisplay, RenderCtx};
use crate::wl;
use libmpv2::Mpv;
use std::ffi::c_void;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{mpsc, Arc};
use std::time::{Duration, Instant};

/// Logical geometry of the video, as the placeholder widget sees it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Size {
    /// Width of the placeholder.
    pub w_css: i32,
    /// Height mpv fits and letterboxes to: the placeholder plus the strip
    /// cropped off the bottom while the fullscreen bar is revealed.
    pub full_h_css: i32,
    /// Height actually shown (the placeholder's).
    pub vis_h_css: i32,
    /// GDK's integer scale; buffers are `css × scale`.
    pub scale: i32,
}

pub enum Cmd {
    /// Render into this subsurface from now on. Replaces the previous one,
    /// which is destroyed once its EGL window is gone.
    Surface(Arc<wl::Subsurface>),
    /// Build the render context for this core. The reply arrives once it
    /// exists — immediately if there is an EGL surface, otherwise when one
    /// is given — or with an error.
    Attach {
        mpv: Arc<Mpv>,
        reply: AttachReply,
    },
    /// Free the render context. The surface keeps its last frame until
    /// `Hide`.
    Detach,
    /// New geometry, measured against the toplevel whose `wl_surface` is
    /// `parent` (as a pointer). Only applies to a subsurface hanging off that
    /// toplevel; for any other it is held until such a subsurface arrives.
    /// GTK does not order a reparent's allocation and the new subsurface the
    /// same way in both directions (see [`State::pending`]).
    Resize { size: Size, parent: usize },
    /// The fullscreen bar was revealed (`bar_css` > 0) or hidden (0): crop
    /// the current size to `full_h - bar_css` *now*, without waiting for GTK
    /// to allocate the shrunk placeholder. In fullscreen the opaque video
    /// covers GTK's whole surface, Mutter then withholds frame callbacks
    /// from that surface, and GTK 3's frame clock stays frozen — no layout,
    /// no paint — until something exposes it. Cropping the video is that
    /// something: the strip under the bar becomes visible, the compositor
    /// paints it, the pending frame callback fires, and GTK thaws and
    /// allocates the placeholder, whose `Resize` then matches and is a
    /// no-op. Without this the bar toggle was lost whenever GTK's last
    /// fullscreen paint happened after the video went full-size (2 of 3
    /// runs on 4 Sep, `WAYLAND_DEBUG` showing a 16 s wait for `done`).
    Clip { bar_css: i32 },
    Show,
    Hide,
}

enum Msg {
    Cmd(Cmd),
    Update,
}

/// The GTK thread's end. Cloneable; the thread lives for the process.
#[derive(Clone)]
pub struct Handle {
    tx: mpsc::Sender<Msg>,
    dirty: Arc<AtomicBool>,
    frames: Arc<AtomicU64>,
}

impl Handle {
    /// Start the thread and wait for it to have an EGL context, so a machine
    /// where that fails falls back to the GLArea before anything is built on
    /// the assumption.
    pub fn spawn(globals: Arc<wl::Globals>) -> Result<Handle, String> {
        let (tx, rx) = mpsc::channel();
        let (ready_tx, ready_rx) = mpsc::channel();
        let handle = Handle {
            tx,
            dirty: Arc::new(AtomicBool::new(false)),
            frames: Arc::new(AtomicU64::new(0)),
        };
        let h = handle.clone();
        std::thread::Builder::new()
            .name("aquarium-video".into())
            .spawn(move || run(globals, rx, h, ready_tx))
            .map_err(|e| format!("spawn video thread: {e}"))?;
        match ready_rx.recv() {
            Ok(Ok(desc)) => {
                eprintln!("aquarium: video thread up, EGL {desc}");
                Ok(handle)
            }
            Ok(Err(e)) => Err(e),
            Err(_) => Err("video thread died during startup".into()),
        }
    }

    pub fn send(&self, cmd: Cmd) {
        let _ = self.tx.send(Msg::Cmd(cmd));
    }

}

/// How long after the last `Resize` to redraw at the new size. Long enough
/// to swallow GTK's two allocation passes, short enough not to show.
const RESIZE_DEBOUNCE: Duration = Duration::from_millis(20);

type AttachReply = mpsc::Sender<Result<(), String>>;

struct State {
    globals: Arc<wl::Globals>,
    egl: EglContext,
    handle: Handle,
    tx: mpsc::Sender<Msg>,
    sub: Option<Arc<wl::Subsurface>>,
    win: Option<EglWindowSurface>,
    ctx: Option<RenderCtx>,
    /// Geometry for `sub`, i.e. measured in the toplevel `sub` hangs off.
    /// `None` means nothing may be drawn: a frame at a stale size, or at a
    /// position meant for another toplevel, is worse than no frame.
    size: Option<Size>,
    /// A `Resize` for a toplevel `sub` does not (yet) hang off. Entering
    /// picture-in-picture, `show_all` on the floating window allocates the
    /// placeholder before the GTK thread has made the new subsurface, so the
    /// size arrives first; leaving, the subsurface is made first and the
    /// allocation follows a frame later. Either way the size is applied when
    /// both halves are here, and the old toplevel's size is never drawn on
    /// the new one.
    pending: Option<(usize, Size)>,
    visible: bool,
    pending_attach: Option<(Arc<Mpv>, AttachReply)>,
    redraw_at: Option<Instant>,
    /// The size changed since the EGL window surface was created, so the
    /// next draw rebuilds it at the new size instead of drawing into it.
    ///
    /// `wl_egl_window_resize` is not enough. Mesa allocates the back buffer
    /// the first time anything validates the drawable — `eglMakeCurrent`,
    /// mpv setting up its render context, any draw — and a resize after that
    /// only takes effect once that buffer has been swapped out. Between the
    /// EGL surface's creation and its first swap, and after any GL activity
    /// while a frame is not being drawn, a resize is therefore ignored and
    /// the next swap attaches a buffer at the *old* size. The first run did
    /// exactly that: a 1×1 buffer under `set_buffer_scale(2)`, which is a
    /// protocol error, which is a disconnect. Recreating the surface at the
    /// new size sidesteps the whole question.
    win_stale: bool,
    /// When the last frame was swapped, for the stutter diagnostic in
    /// `draw` (debug builds of the log only).
    last_draw: Option<Instant>,
}

impl State {
    fn debug(&self) -> bool {
        crate::surface::debug_enabled()
    }

    fn buffer_dims(&self) -> (i32, i32) {
        match self.size {
            Some(s) => (s.w_css * s.scale, s.full_h_css * s.scale),
            None => (1, 1),
        }
    }

    /// (Re)build the EGL window surface on the current subsurface at the
    /// current size and make it current. The previous one is dropped only
    /// after the new one is current, so the render context never has a
    /// moment without a surface to be current on.
    fn recreate_win(&mut self) -> bool {
        let Some(sub) = self.sub.clone() else {
            return false;
        };
        let (w, h) = self.buffer_dims();
        let win = match EglWindowSurface::new(&self.egl, sub.surface as *mut c_void, w, h) {
            Ok(w) => w,
            Err(e) => {
                eprintln!("aquarium: video thread: {e}");
                return false;
            }
        };
        if !self.egl.make_current(&win) {
            eprintln!("aquarium: video thread: eglMakeCurrent failed");
            return false;
        }
        // mpv paces frames itself; a swap that waited for the compositor's
        // frame callback would stall forever on an occluded subsurface.
        self.egl.set_swap_interval(0);
        if self.debug() {
            let (sid, ssid) = sub.ids();
            eprintln!(
                "aquarium: video thread: EGL window on wl_surface#{sid} (wl_subsurface#{ssid}), buffer {}x{}",
                win.w, win.h
            );
        }
        self.win = Some(win);
        self.win_stale = false;
        true
    }

    fn set_surface(&mut self, sub: Arc<wl::Subsurface>) {
        // The size that was for the previous toplevel is not for this one.
        // A size that arrived ahead of us for this toplevel is.
        let parent = sub.parent as usize;
        let size = match self.pending {
            Some((p, s)) if p == parent => Some(s),
            _ => None,
        };
        let old_sub = self.sub.replace(sub.clone());
        let old_size = self.size;
        self.size = size;
        if !self.recreate_win() {
            // Keep whatever was there; the old subsurface may still work.
            self.sub = old_sub;
            self.size = old_size;
            return;
        }
        if size.is_some() {
            self.pending = None;
        }
        if let Some(old) = old_sub {
            old.destroy();
            self.globals.flush();
        }
        if let Some(s) = self.size {
            sub.set_size(s.w_css, s.full_h_css, s.vis_h_css, s.scale);
        }
        if self.debug() && self.size.is_none() {
            eprintln!("aquarium: video thread: waiting for the new toplevel's size before drawing");
        }
        self.try_attach();
        self.schedule_redraw(Duration::ZERO);
    }

    fn try_attach(&mut self) {
        if self.win.is_none() || self.pending_attach.is_none() {
            return;
        }
        let (mpv, reply) = self.pending_attach.take().unwrap();
        let native = NativeDisplay::Wayland(self.globals.display as *mut c_void);
        match RenderCtx::new(mpv, native, true) {
            Ok(mut ctx) => {
                let tx = self.tx.clone();
                let dirty = self.handle.dirty.clone();
                ctx.set_update_callback(move || {
                    // mpv's thread. One message per burst of callbacks.
                    if !dirty.swap(true, Ordering::AcqRel) {
                        let _ = tx.send(Msg::Update);
                    }
                });
                if self.debug() {
                    if let Some(g) = crate::gl::api() {
                        let name = |e: u32| unsafe {
                            let p = (g.get_string)(e);
                            if p.is_null() {
                                "?".to_string()
                            } else {
                                std::ffi::CStr::from_ptr(p as *const _).to_string_lossy().into_owned()
                            }
                        };
                        eprintln!(
                            "aquarium: video thread: render context up, GL vendor={} renderer={}",
                            name(0x1F00),
                            name(0x1F01)
                        );
                    }
                }
                self.ctx = Some(ctx);
                let _ = reply.send(Ok(()));
            }
            Err(e) => {
                let _ = reply.send(Err(e));
            }
        }
    }

    fn detach(&mut self) {
        if let Some(ctx) = self.ctx.take() {
            if let Some(win) = &self.win {
                self.egl.make_current(win);
            }
            drop(ctx);
        }
        self.pending_attach = None;
    }

    fn resize(&mut self, size: Size, parent: usize) {
        let ours = self.sub.as_ref().is_some_and(|s| s.parent as usize == parent);
        if !ours {
            if self.debug() {
                eprintln!(
                    "aquarium: video thread: size {}x{} css is for toplevel {parent:#x}, not the current one; holding",
                    size.w_css, size.full_h_css
                );
            }
            self.pending = Some((parent, size));
            return;
        }
        if self.size == Some(size) {
            return;
        }
        let dims_before = self.buffer_dims();
        self.size = Some(size);
        // Surface state for the new size; applied by the next commit, which
        // is the swap of the first frame drawn at that size.
        if let Some(sub) = self.sub.as_ref() {
            sub.set_size(size.w_css, size.full_h_css, size.vis_h_css, size.scale);
        }
        // The fullscreen bar reveal changes only the visible height, i.e. the
        // viewport crop: the buffer stays the same size, so the EGL window is
        // fine as it is and the crop lands with the next swap. Only a change
        // of buffer dimensions needs the rebuild.
        if self.buffer_dims() != dims_before {
            self.win_stale = true;
        }
        if self.debug() {
            eprintln!(
                "aquarium: video thread: size {}x{} css, shown {} css, scale {}",
                size.w_css, size.full_h_css, size.vis_h_css, size.scale
            );
        }
        self.schedule_redraw(RESIZE_DEBOUNCE);
    }

    /// See [`Cmd::Clip`]. Nothing to do before the first size: the `Resize`
    /// that brings it already carries the visible height.
    fn clip(&mut self, bar_css: i32) {
        let Some(mut size) = self.size else { return };
        size.vis_h_css = (size.full_h_css - bar_css.max(0)).max(1);
        let parent = self.sub.as_ref().map(|s| s.parent as usize).unwrap_or(0);
        self.resize(size, parent);
    }

    fn schedule_redraw(&mut self, after: Duration) {
        if self.can_draw() {
            let at = Instant::now() + after;
            self.redraw_at = Some(match self.redraw_at {
                Some(t) if t < at => t,
                _ => at,
            });
        }
    }

    fn can_draw(&self) -> bool {
        self.visible && self.size.is_some() && self.ctx.is_some() && self.win.is_some()
    }

    fn draw(&mut self) {
        self.redraw_at = None;
        if !self.can_draw() {
            return;
        }
        if self.win_stale && !self.recreate_win() {
            return;
        }
        let (w, h) = self.buffer_dims();
        let ctx = self.ctx.as_ref().unwrap();
        let win = self.win.as_ref().unwrap();
        if let Err(e) = ctx.render(0, w, h, true) {
            eprintln!("aquarium: video thread: {e}");
        }
        let swap_started = Instant::now();
        if !self.egl.swap(win) {
            eprintln!("aquarium: video thread: eglSwapBuffers failed");
        }
        if self.debug() && swap_started.elapsed() > Duration::from_millis(30) {
            // Mesa's Wayland EGL blocks in the swap when the compositor has
            // not released a buffer to draw the next frame into. Seen on
            // 2026-09-06 lining up with gnome-shell's main loop pausing
            // ~100 ms every 10 s (its own per-repaint SetBacklight stream
            // stops for the same interval): the periodic stutter reported
            // for local playback was the compositor, not the player.
            eprintln!(
                "aquarium: video thread: swap took {} ms (at {})",
                swap_started.elapsed().as_millis(),
                crate::now_ms()
            );
        }
        ctx.report_swap();
        let n = self.handle.frames.fetch_add(1, Ordering::Relaxed);
        // Events for our own objects (surface enter/leave, preferred scale);
        // never blocks, never reads the socket.
        self.globals.dispatch();
        if self.debug() {
            // A frame that took more than two of its predecessors' intervals
            // to arrive is a stutter the viewer saw; log it with the time so
            // it can be lined up against whatever else the app was doing.
            let now = Instant::now();
            if let Some(last) = self.last_draw {
                let gap = now.duration_since(last);
                if gap > Duration::from_millis(80) {
                    eprintln!(
                        "aquarium: video thread: frame #{n} came {} ms after the previous one (at {})",
                        gap.as_millis(),
                        crate::now_ms()
                    );
                }
            }
            self.last_draw = Some(now);
        }
        if self.debug() && n.is_multiple_of(240) {
            eprintln!("aquarium: video thread: frame #{n} at {w}x{h}");
        }
    }

    fn hide(&mut self) {
        self.visible = false;
        self.size = None;
        self.pending = None;
        self.redraw_at = None;
        if let Some(sub) = &self.sub {
            sub.unmap();
            self.globals.flush();
        }
    }
}

fn run(
    globals: Arc<wl::Globals>,
    rx: mpsc::Receiver<Msg>,
    handle: Handle,
    ready: mpsc::Sender<Result<String, String>>,
) {
    let display = match EglDisplay::new(globals.display as *mut c_void) {
        Ok(d) => d,
        Err(e) => {
            let _ = ready.send(Err(e));
            return;
        }
    };
    let egl = match EglContext::new(&display) {
        Ok(c) => c,
        Err(e) => {
            let _ = ready.send(Err(e));
            return;
        }
    };
    let _ = ready.send(Ok(display.describe()));

    let tx = handle.tx.clone();
    let mut st = State {
        globals,
        egl,
        handle,
        tx,
        sub: None,
        win: None,
        ctx: None,
        size: None,
        pending: None,
        visible: false,
        pending_attach: None,
        redraw_at: None,
        win_stale: false,
        last_draw: None,
    };

    loop {
        let msg = match st.redraw_at {
            Some(at) => match rx.recv_timeout(at.saturating_duration_since(Instant::now())) {
                Ok(m) => m,
                Err(mpsc::RecvTimeoutError::Timeout) => {
                    st.draw();
                    continue;
                }
                Err(mpsc::RecvTimeoutError::Disconnected) => break,
            },
            None => match rx.recv() {
                Ok(m) => m,
                Err(_) => break,
            },
        };
        match msg {
            Msg::Cmd(Cmd::Surface(sub)) => st.set_surface(sub),
            Msg::Cmd(Cmd::Attach { mpv, reply }) => {
                st.detach();
                st.pending_attach = Some((mpv, reply));
                st.try_attach();
                st.schedule_redraw(Duration::ZERO);
            }
            Msg::Cmd(Cmd::Detach) => st.detach(),
            Msg::Cmd(Cmd::Resize { size, parent }) => st.resize(size, parent),
            Msg::Cmd(Cmd::Clip { bar_css }) => st.clip(bar_css),
            Msg::Cmd(Cmd::Show) => {
                st.visible = true;
                st.schedule_redraw(Duration::ZERO);
            }
            Msg::Cmd(Cmd::Hide) => st.hide(),
            Msg::Update => {
                st.handle.dirty.store(false, Ordering::Release);
                // Must be called for every callback under advanced control,
                // rendered or not; a hidden frame is simply dropped.
                let due = st
                    .ctx
                    .as_ref()
                    .map(|c| c.update() & RenderCtx::UPDATE_FRAME != 0)
                    .unwrap_or(false);
                if due {
                    st.draw();
                }
            }
        }
    }

    // The GTK side is gone (channel closed): free what needs the context.
    st.detach();
    st.win = None;
    if let Some(sub) = st.sub.take() {
        sub.destroy();
        st.globals.flush();
    }
}
