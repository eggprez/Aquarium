//! The video surface: where libmpv's picture goes, overlaid on the webview.
//!
//! Two implementations behind one API ([`Surface`]), chosen once at startup:
//!
//! - **Wayland subsurface** (`Backend::Wl`, the default on a Wayland
//!   session): mpv renders on a thread of its own, through an EGL context of
//!   its own, into a `wl_subsurface` of the toplevel. GTK never repaints per
//!   video frame. The widget in the overlay is a plain `GtkDrawingArea` that
//!   paints the app background once per layout change, receives input (the
//!   subsurface has an empty input region, so the pointer falls through to
//!   it), and whose allocation is what positions and sizes the subsurface.
//!   See WAYLAND-SUBSURFACE-PLAN.md.
//! - **GtkGLArea** (`Backend::Gl`: X11 sessions, a Wayland compositor without
//!   `wp_viewporter`, or the `AQUARIUM_VIDEO_BACKEND=gl` override): mpv
//!   renders on the GTK thread into the GLArea's framebuffer, and every video
//!   frame costs GTK a repaint of the widget's rectangle. See
//!   WAYLAND-MIGRATION.md.
//!
//! Either way the layout is the direct analogue of the old X11 child window:
//! a `GtkOverlay` with the webview as its main child and the video widget as
//! an overlay child pinned to the top, sized to the same rectangle
//! `geometry()` has always computed. HTML still cannot draw over video —
//! which is why the player bar lives *below* it rather than on top — and the
//! pointer still lands on the video widget over the video region, so uosc's
//! hover, click and drag behave as they do today.
//!
//! # Threading
//!
//! GTK objects are not `Send`, so every widget lives in a thread-local that
//! only the main thread ever populates, and every operation is dispatched
//! there through `AppHandle::run_on_main_thread`. What callers off the main
//! thread need to read synchronously — is anything showing, are we in
//! picture-in-picture — is mirrored into atomics on [`Surface`] itself. On
//! the subsurface backend the main thread in turn only ever *sends* to the
//! video thread (`video_thread.rs`); it never touches EGL or the render
//! context.
//!
//! On the GLArea backend the render context is created lazily on the first
//! `render` signal. That is not a convenience: `GtkGLArea` only creates its
//! `GdkGLContext` inside its *own* realize handler, which runs after any
//! handler connected from Rust, so a `connect_realize` that touches GL
//! segfaults. `render` is the earliest point the context is guaranteed
//! current.
use crate::gl;
use crate::render::{NativeDisplay, RenderCtx};
use crate::video_thread::{self, Cmd, Size};
use crate::{egl, wl};
use gtk::gdk;
use gtk::glib;
use gtk::glib::translate::ToGlibPtr;
use gtk::prelude::*;
use libmpv2::Mpv;
use std::cell::{Cell, RefCell};
use std::ffi::c_void;
use std::rc::Rc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use tauri::{AppHandle, Manager};

/// CSS height of the bottom player bar; the video surface stops above it.
pub const BAR_HEIGHT_CSS: f64 = 72.0;

/// Opening size of the picture-in-picture window. 16:9 at a size that is
/// readable over a browser without being in the way; the compositor lets it be
/// dragged and resized from there. Unlike the X11 version there is no opening
/// position: a Wayland client cannot place its own toplevels.
const PIP_W: i32 = 480;
const PIP_H: i32 = 270;
const PIP_TITLE: &str = "Aquarium — Picture in Picture";

/// The app background, so the surface reads as part of the window before the
/// first frame arrives. Same colour the X11 child was filled with.
const BG: (f32, f32, f32) = (0x0e as f32 / 255.0, 0x0e as f32 / 255.0, 0x14 as f32 / 255.0);

extern "C" {
    fn gdk_wayland_display_get_wl_display(display: *mut c_void) -> *mut c_void;
    fn gdk_x11_display_get_xdisplay(display: *mut c_void) -> *mut c_void;
    /// On a child `GdkWindow` this returns the *toplevel's* surface (GTK3
    /// child windows are client-side); always call it on the toplevel's and
    /// position the subsurface in toplevel coordinates.
    fn gdk_wayland_window_get_wl_surface(window: *mut c_void) -> *mut c_void;
}

/// `AQUARIUM_SURFACE_TEST=1` turns on the migration's own diagnostics: the
/// widget tree the surface was built into, and what the render callback (or
/// the video thread) actually got handed. The failure modes here — a widget
/// allocated zero height, hwdec silently resolving to `no`, a subsurface
/// positioned off its rectangle — all look like nothing happening.
pub fn debug_enabled() -> bool {
    static ON: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    *ON.get_or_init(|| {
        matches!(
            std::env::var("AQUARIUM_SURFACE_TEST").as_deref(),
            Ok("1") | Ok("true")
        )
    })
}

fn dump_tree(w: &gtk::Widget, depth: usize) {
    let a = w.allocation();
    eprintln!(
        "aquarium:   {:indent$}{} {}x{}+{}+{} visible={}",
        "",
        w.type_().name(),
        a.width(),
        a.height(),
        a.x(),
        a.y(),
        w.is_visible(),
        indent = depth * 2
    );
    if let Some(c) = w.downcast_ref::<gtk::Container>() {
        for child in c.children() {
            dump_tree(&child, depth + 1);
        }
    }
}

/// Compute the video surface geometry in physical pixels.
/// `reserve_bar` leaves the bottom player bar visible below the video —
/// always in windowed mode, and in fullscreen while the auto-hiding
/// controls are revealed.
pub fn geometry(
    size: tauri::PhysicalSize<u32>,
    scale: f64,
    reserve_bar: bool,
) -> (i16, i16, u16, u16) {
    let bar = if reserve_bar {
        (BAR_HEIGHT_CSS * scale).ceil() as u32
    } else {
        0
    };
    let h = size.height.saturating_sub(bar).max(1);
    (0, 0, size.width.max(1) as u16, h as u16)
}

// ---------------------------------------------------------------- offscreen

/// An offscreen colour buffer sized to the *unclipped* surface, so mpv's fit,
/// letterboxing and zoom never depend on how much of it we choose to show.
/// GLArea backend only; the subsurface backend crops with `wp_viewport`.
///
/// This is what replaces the X11 SHAPE trick. Shrinking the surface makes mpv
/// re-fit the picture, so the whole frame jumps the moment the fullscreen
/// controls arrive; rendering full-size and blitting all but the bottom strip
/// leaves the picture pinned to the pixel and simply stops the strip from
/// being drawn, revealing the player bar underneath.
struct Offscreen {
    fbo: u32,
    tex: u32,
    w: i32,
    h: i32,
}

impl Offscreen {
    fn ensure<'a>(slot: &'a mut Option<Offscreen>, g: &gl::Api, w: i32, h: i32) -> &'a mut Offscreen {
        if slot.as_ref().map(|o| (o.w, o.h)) != Some((w, h)) {
            if let Some(old) = slot.take() {
                old.destroy(g);
            }
            let (mut fbo, mut tex) = (0u32, 0u32);
            unsafe {
                (g.gen_textures)(1, &mut tex);
                (g.bind_texture)(gl::TEXTURE_2D, tex);
                (g.tex_image_2d)(
                    gl::TEXTURE_2D,
                    0,
                    gl::RGBA8 as i32,
                    w,
                    h,
                    0,
                    gl::RGBA as i32,
                    gl::UNSIGNED_BYTE,
                    std::ptr::null(),
                );
                (g.tex_parameteri)(gl::TEXTURE_2D, gl::TEXTURE_MIN_FILTER, gl::NEAREST);
                (g.tex_parameteri)(gl::TEXTURE_2D, gl::TEXTURE_MAG_FILTER, gl::NEAREST);
                (g.bind_texture)(gl::TEXTURE_2D, 0);
                (g.gen_framebuffers)(1, &mut fbo);
                (g.bind_framebuffer)(gl::FRAMEBUFFER, fbo);
                (g.fb_texture_2d)(gl::FRAMEBUFFER, gl::COLOR_ATTACHMENT0, gl::TEXTURE_2D, tex, 0);
                let status = (g.check_fb_status)(gl::FRAMEBUFFER);
                if status != gl::FRAMEBUFFER_COMPLETE {
                    eprintln!("aquarium: offscreen FBO incomplete: 0x{status:x}");
                }
                (g.bind_framebuffer)(gl::FRAMEBUFFER, 0);
            }
            *slot = Some(Offscreen { fbo, tex, w, h });
        }
        slot.as_mut().unwrap()
    }

    fn destroy(self, g: &gl::Api) {
        unsafe {
            (g.del_framebuffers)(1, &self.fbo);
            (g.del_textures)(1, &self.tex);
        }
    }
}

// ------------------------------------------------------------- main-thread UI

/// Everything the render signal needs. Kept apart from [`Ui`] so that a frame
/// arriving mid-operation cannot re-enter a borrow the caller is holding.
/// `mpv` is used by both backends (input goes through it); the rest is the
/// GLArea backend's.
struct Video {
    mpv: Option<Arc<Mpv>>,
    render: Option<RenderCtx>,
    off: Option<Offscreen>,
    /// The true unclipped physical height mpv should always fit/letterbox to
    /// — set synchronously from `Geom::h`, never from the GLArea's own
    /// allocation. The widget's allocated height lags this by up to a frame
    /// (its resize is only queued from an idle callback, see `Layout::apply`),
    /// so deriving the clip from *that* instead of from a fixed target would
    /// hand mpv a wrongly-sized FBO for that frame — mpv re-fits to it, and
    /// the picture visibly jolts before snapping back once the widget catches
    /// up. Keeping `full` fixed means mpv always fits the same height; only
    /// how much of it gets blitted out changes, so nothing ever re-fits.
    full: i32,
}

impl Video {
    /// Free the GL-side state. The caller must have made the GLArea's context
    /// current: mpv requires the render context to be freed on the thread that
    /// owns the GL context, with that context current.
    fn release_gl(&mut self) {
        self.render = None;
        if let (Some(off), Some(g)) = (self.off.take(), gl::api()) {
            off.destroy(g);
        }
    }
}

/// How tall the video widget should be, expressed as what it leaves *clear*
/// rather than as an absolute height.
///
/// The absolute height cannot come from the caller. `inner_size()` on the
/// Tauri window is the whole client area including the client-side title bar
/// — under GNOME Wayland that is 47 logical px the overlay never gets — so
/// sizing the widget to it silently covers the top of the player bar. Only the
/// *difference* between the window height and the height the caller asked for
/// is meaningful, and that difference is `trim`; the absolute size is anchored
/// to the overlay's own allocation, which is the real space available.
struct Layout {
    /// Logical px kept clear at the bottom of the overlay: the permanent
    /// player-bar reserve, plus in fullscreen the strip the revealed bar
    /// occupies.
    trim: Cell<i32>,
    /// Logical px of the fullscreen control strip alone — the part of `trim`
    /// that is cut *out of* the video rather than reserved below it. The
    /// subsurface backend adds it back to the widget's allocation to get the
    /// height mpv should fit to, so revealing the bar crops instead of
    /// re-fitting.
    bar_css: Cell<i32>,
    /// Last height requested, so an unchanged allocation queues nothing.
    requested: Cell<i32>,
    /// While the widget lives in the picture-in-picture window it fills it,
    /// and the overlay has nothing to say about its size.
    pip: Cell<bool>,
}

impl Layout {
    /// `avail` is the overlay's logical height. Applied from an idle rather
    /// than inline: GTK discards a resize queued from inside allocation, and
    /// this runs from `size-allocate`.
    fn apply(self: &Rc<Self>, area: &gtk::Widget, avail: i32) {
        if self.pip.get() {
            return;
        }
        let want = (avail - self.trim.get()).max(1);
        if debug_enabled() {
            eprintln!(
                "aquarium: layout: avail {avail} trim {} → want {want} (requested {}, allocated {})",
                self.trim.get(),
                self.requested.get(),
                area.allocated_height()
            );
        }
        if self.requested.get() == want {
            return;
        }
        self.requested.set(want);
        let area = area.clone();
        let me = self.clone();
        glib::idle_add_local_once(move || {
            if !me.pip.get() {
                if debug_enabled() {
                    eprintln!("aquarium: layout: set_size_request(-1, {})", me.requested.get());
                }
                area.set_size_request(-1, me.requested.get());
            }
        });
    }
}

/// The subsurface backend's main-thread state.
struct Wl {
    area: gtk::DrawingArea,
    thread: video_thread::Handle,
    globals: Arc<wl::Globals>,
    /// The subsurface the video is on right now, and the toplevel
    /// `wl_surface` it hangs off. Replaced whenever the widget finds itself
    /// in a different toplevel (picture-in-picture, and back).
    sub: Rc<RefCell<Option<Arc<wl::Subsurface>>>>,
    parent: Rc<Cell<*mut c_void>>,
    /// Last position sent, re-applied to a freshly created subsurface.
    last_pos: Rc<Cell<(i32, i32)>>,
}

enum Backend {
    Gl { area: gtk::GLArea },
    Wl(Wl),
}

struct Ui {
    overlay: gtk::Overlay,
    /// The video widget, whichever kind it is.
    widget: gtk::Widget,
    backend: Backend,
    pip_win: Option<gtk::Window>,
    video: Rc<RefCell<Video>>,
    layout: Rc<Layout>,
}

thread_local! {
    static UI: RefCell<Option<Ui>> = const { RefCell::new(None) };
}

/// Run `f` on the main thread with the UI, if it has been built.
fn with_ui<F: FnOnce(&mut Ui) + Send + 'static>(app: &AppHandle, f: F) {
    let _ = app.run_on_main_thread(move || {
        UI.with(|ui| {
            if let Some(ui) = ui.borrow_mut().as_mut() {
                f(ui);
            }
        })
    });
}

impl Ui {
    /// Make the GLArea's context current so GL objects can be freed, then drop
    /// them. Safe to call when the area was never realized. No-op on the
    /// subsurface backend, whose GL lives on the video thread.
    fn release_gl(&self) {
        if let Backend::Gl { area } = &self.backend {
            if area.is_realized() {
                area.make_current();
            }
            self.video.borrow_mut().release_gl();
        }
    }

    /// Build the render context outside the `render` signal, for
    /// [`Surface::attach`] on the GLArea backend. Returns whether it now
    /// exists.
    ///
    /// No-op until the GLArea is realized: `make_current()` cannot make a
    /// `GdkGLContext` current before GtkGLArea has created one, and the first
    /// GL call without one segfaults (Phase 0, finding 1). Once it is
    /// realized, though, "the context is current" is true anywhere on the main
    /// thread, not only inside the signal.
    fn ensure_render_ctx(&self) -> bool {
        let Backend::Gl { area } = &self.backend else {
            return false;
        };
        if !area.is_realized() || area.error().is_some() {
            return false;
        }
        area.make_current();
        build_render_ctx(area, &mut self.video.borrow_mut())
    }

    fn wl(&self) -> Option<&Wl> {
        match &self.backend {
            Backend::Wl(w) => Some(w),
            Backend::Gl { .. } => None,
        }
    }

    /// Make sure the video subsurface hangs off the toplevel the widget is
    /// in right now, creating a new one if the widget moved (picture-in-
    /// picture). Needs that toplevel realized, which every caller's toplevel
    /// is by the time it calls. The video thread takes over the new surface
    /// and destroys the old one.
    fn wl_ensure_subsurface(&self) {
        let Some(w) = self.wl() else { return };
        let Some(top) = self.widget.toplevel() else { return };
        let parent = toplevel_wl_surface(&top);
        if parent.is_null() {
            return;
        }
        if w.parent.get() == parent && w.sub.borrow().is_some() {
            return;
        }
        match wl::Subsurface::new(&w.globals, parent) {
            Ok(sub) => {
                let sub = Arc::new(sub);
                let (x, y) = w.last_pos.get();
                sub.set_position(x, y);
                if debug_enabled() {
                    let (sid, ssid) = sub.ids();
                    eprintln!(
                        "aquarium: video subsurface wl_surface#{sid}/wl_subsurface#{ssid} on toplevel {parent:?} at ({x},{y})"
                    );
                }
                w.parent.set(parent);
                *w.sub.borrow_mut() = Some(sub.clone());
                w.thread.send(Cmd::Surface(sub));
                // The position lands on the parent's next commit; a redraw
                // of the placeholder is what makes GTK commit.
                self.widget.queue_draw();
                // GTK allocates a toplevel's children before it maps it, and
                // GDK creates the `wl_surface` on map, so an allocation that
                // happened inside `show_all` on a fresh window had no parent
                // to be measured against and was dropped. Now there is one.
                // Coming back from picture-in-picture the widget has just
                // been unparented, which resets its allocation to 1×1, so
                // this sends nothing stale there.
                self.wl_push_geometry();
            }
            Err(e) => eprintln!("aquarium: video subsurface: {e}"),
        }
    }

    /// Send the widget's current allocation to the video thread as position
    /// and size. `size-allocate` does this by itself; this is for the moments
    /// (show, scale change) where the allocation may not change but the
    /// thread has forgotten it.
    fn wl_push_geometry(&self) {
        let Some(w) = self.wl() else { return };
        // In the app window the size is derived from the overlay, not read
        // off the widget: a hidden widget keeps the allocation of its last
        // session, and between sessions the window may have been resized or
        // — the common case — left fullscreen, where the last allocation was
        // the whole window with no bar strip trimmed off. Pushing that put a
        // full-window frame over the player bar at the start of a windowed
        // session; and with the opaque video covering all of GTK's surface,
        // Mutter withheld frame callbacks, GTK's frame clock froze, and the
        // allocation that would have corrected it never ran (see
        // `Cmd::Clip`). What `Layout::apply` will ask for is known now, so
        // ask the video thread for exactly that and let GTK's own pass land
        // as a no-op.
        let (origin, alloc) =
            intended_alloc(&self.layout, &self.widget, &self.overlay, &self.widget.allocation());
        if alloc.width() < 1 || alloc.height() < 1 {
            return;
        }
        wl_geometry_changed(w, &self.layout, &self.widget, origin, &alloc);
    }
}

/// The `wl_surface` of a toplevel widget (from `Widget::toplevel()`), or
/// null if it is not a realized, shown `gtk::Window` — GDK creates the
/// Wayland surface on show and destroys it on hide.
fn toplevel_wl_surface(top: &gtk::Widget) -> *mut c_void {
    if !top.is::<gtk::Window>() {
        return std::ptr::null_mut();
    }
    let Some(gw) = top.window() else {
        return std::ptr::null_mut();
    };
    let ptr = ToGlibPtr::<*mut gtk::gdk::ffi::GdkWindow>::to_glib_none(&gw).0 as *mut c_void;
    unsafe { gdk_wayland_window_get_wl_surface(ptr) }
}

/// The subsurface backend's reaction to the placeholder being allocated:
/// position the subsurface where the widget is, in toplevel-surface
/// coordinates, and tell the video thread the size.
///
/// Toplevel-widget coordinates *are* surface coordinates: the `GtkWindow`
/// widget is allocated the whole `wl_surface`, client-side shadow included
/// (Phase 0 confirmed the arithmetic: (26,60) in a 1332×809 surface for the
/// widget at the overlay's origin under a header bar).
/// `origin` is the widget whose (0, 0) is the video's top-left in the
/// toplevel: the video widget itself when `alloc` is its own allocation, the
/// overlay when `alloc` was derived from the overlay's instead.
fn wl_geometry_changed(
    w: &Wl,
    layout: &Layout,
    widget: &gtk::Widget,
    origin: &gtk::Widget,
    alloc: &gtk::Allocation,
) {
    if debug_enabled() {
        eprintln!(
            "aquarium: layout: placeholder allocated {}x{}+{}+{}",
            alloc.width(),
            alloc.height(),
            alloc.x(),
            alloc.y()
        );
    }
    // GTK's "not allocated yet" placeholder allocation is 1×1 at (-1,-1),
    // and the pass that puts the widget back under the overlay after
    // picture-in-picture allocates it full-width by 1 tall before the height
    // request lands. Neither is a size worth a buffer.
    if alloc.width() <= 1 || alloc.height() <= 1 {
        return;
    }
    let Some(top) = widget.toplevel() else { return };
    // The size only means something against the toplevel it was measured
    // in; the video thread matches it to the subsurface on that toplevel.
    let parent = toplevel_wl_surface(&top);
    if parent.is_null() {
        return;
    }
    let (x, y) = origin
        .translate_coordinates(&top, 0, 0)
        .unwrap_or((alloc.x(), alloc.y()));
    let scale = widget.scale_factor().max(1);
    let size = Size {
        w_css: alloc.width().max(1),
        full_h_css: alloc.height().max(1) + layout.bar_css.get(),
        vis_h_css: alloc.height().max(1),
        scale,
    };
    if debug_enabled() && w.last_pos.get() != (x, y) {
        eprintln!(
            "aquarium: video widget {}x{}+{}+{} → subsurface at ({x},{y}), fit height {} css, scale {scale}",
            alloc.width(),
            alloc.height(),
            alloc.x(),
            alloc.y(),
            size.full_h_css
        );
    }
    w.last_pos.set((x, y));
    if let Some(sub) = w.sub.borrow().as_ref() {
        sub.set_position(x, y);
    }
    w.thread.send(Cmd::Resize {
        size,
        parent: parent as usize,
    });
    widget.queue_draw();
}

// ------------------------------------------------------------------- Surface

#[derive(Clone, Copy)]
struct Geom {
    /// Physical height of the window's inner area, as the caller measured it.
    win_h: u32,
    /// Physical height the caller wants the video to occupy out of it.
    h: u32,
    /// Physical pixels of the fullscreen control strip cut out of the bottom.
    bar: u32,
}

pub struct Surface {
    app: AppHandle,
    geom: Mutex<Geom>,
    /// Id of the playback session currently owning the surface, 0 for none.
    /// A finished session must not tear down a surface a newer one just took.
    session: AtomicU64,
    next_session: AtomicU64,
    pip: AtomicBool,
    on_pip_close: Mutex<Option<Arc<dyn Fn() + Send + Sync>>>,
}

pub struct SurfaceShared(pub Option<Arc<Surface>>);

/// Which backend to build, and why not the other one.
fn choose_backend() -> Result<Arc<wl::Globals>, String> {
    if std::env::var("AQUARIUM_VIDEO_BACKEND").as_deref() == Ok("gl") {
        return Err("AQUARIUM_VIDEO_BACKEND=gl".into());
    }
    let display = gtk::gdk::Display::default().ok_or("no GDK display")?;
    if !display.type_().name().contains("Wayland") {
        return Err(format!("{} session", display.type_().name()));
    }
    if !wl::available() {
        return Err("libwayland-client unavailable".into());
    }
    if !egl::available() {
        return Err("libEGL / libwayland-egl unavailable".into());
    }
    let dpy: *mut c_void =
        ToGlibPtr::<*mut gtk::gdk::ffi::GdkDisplay>::to_glib_none(&display).0 as *mut c_void;
    let wl_display = unsafe { gdk_wayland_display_get_wl_display(dpy) };
    let globals = wl::Globals::new(wl_display)?;
    if !globals.has_viewporter() {
        // The fullscreen bar reveal needs the crop; without it the GLArea's
        // blit is the only way to keep the picture pinned.
        return Err("compositor has no wp_viewporter".into());
    }
    Ok(Arc::new(globals))
}

impl Surface {
    /// Build the widget tree. Must run on the main thread, after Tauri has
    /// created the window — i.e. from `setup()`.
    pub fn new(window: &tauri::WebviewWindow) -> Result<Arc<Self>, String> {
        // libmpv refuses to be created under a non-C LC_NUMERIC: `mpv_create()`
        // just returns NULL and prints one line to stderr. The mpv *binary*
        // does this for itself; in-process it is ours, and it has to happen
        // after GTK has set the locale from the environment — which by here it
        // has. Phase 2 creates the handle; this is the last safe moment before.
        unsafe {
            libc::setlocale(libc::LC_NUMERIC, c"C".as_ptr());
        }

        // Both backends hand mpv GL through libepoxy.
        if !gl::available() {
            return Err("no usable GL entry points (libepoxy missing?)".into());
        }

        let vbox = window
            .default_vbox()
            .map_err(|e| format!("no GTK vbox: {e}"))?;
        let children = vbox.children();
        // wry packs the webview into the vbox expanding; a menu bar, if there
        // is one, is packed before it. Match by type so the order cannot
        // matter, and fall back to the last child.
        let webview = children
            .iter()
            .find(|c| c.type_().name().contains("WebView"))
            .or_else(|| children.last())
            .cloned()
            .ok_or("window has no webview child")?;

        // tauri-runtime-wry connects `button-press-event` and `touch-event`
        // handlers on the webview (`undecorated_resizing::attach_resize_handler`,
        // click-to-resize for undecorated windows — a feature this app never
        // uses, since it ships with ordinary window decorations) unconditionally
        // on every Linux build, before this constructor ever runs. Both walk
        // `webview.parent().parent()`, unwrap a downcast of that to `GtkWindow`,
        // and only *then* check whether the window is undecorated. Nesting the
        // overlay inside tao's vbox added a third hop, so the walk landed on the
        // vbox and the first click reaching the page aborted the process;
        // stripping the click handler by signal id moved the abort to the first
        // touchscreen tap (the touch handler is a separate connection, and the
        // same signal carries wry's own back/forward mouse-button synthesis, so
        // matching by id is the wrong tool anyway). Instead the overlay takes
        // the vbox's place as the window's one child, the walk ends on the
        // window as wry expects, and both handlers become the no-ops they were
        // always meant to be here. The orphaned vbox is only ever used by tauri
        // for a menu bar, which this app has none of.
        let gtk_win = window
            .gtk_window()
            .map_err(|e| format!("no GTK window: {e}"))?;
        let overlay = gtk::Overlay::new();
        vbox.remove(&webview);
        gtk_win.remove(&vbox);
        overlay.add(&webview);
        gtk_win.add(&overlay);
        overlay.show();

        // Test hook: AQUARIUM_TEST_INPUT=1 fires a synthetic left click and a
        // touch-begin at the webview two seconds in, through the same signals
        // real input arrives on, so wry's handlers above run against this
        // widget tree. Handlers of our own, connected last so they run after
        // wry's, swallow the events before WebKit's class handler sees them.
        // The old tree aborted here; the log line proves the new one doesn't.
        if std::env::var_os("AQUARIUM_TEST_INPUT").is_some() {
            let webview = webview.clone();
            glib::timeout_add_local_once(std::time::Duration::from_secs(2), move || {
                webview.connect_button_press_event(|_, _| glib::Propagation::Stop);
                webview.connect_touch_event(|_, _| glib::Propagation::Stop);
                let click = gdk::Event::new(gdk::EventType::ButtonPress);
                unsafe {
                    (*(click.as_ptr() as *mut gdk::ffi::GdkEventButton)).button = 1;
                }
                let touch = gdk::Event::new(gdk::EventType::TouchBegin);
                let a = webview.emit_by_name::<bool>("button-press-event", &[&click]);
                let b = webview.emit_by_name::<bool>("touch-event", &[&touch]);
                eprintln!("aquarium: test input: click={a} touch={b} — survived");
            });
        }

        let video = Rc::new(RefCell::new(Video {
            mpv: None,
            render: None,
            off: None,
            full: 0,
        }));

        // The video thread comes up before the widget is chosen, so a machine
        // where EGL fails on the thread still gets the GLArea.
        let wl_thread = match choose_backend() {
            Ok(globals) => match video_thread::Handle::spawn(globals.clone()) {
                Ok(thread) => Some((globals, thread)),
                Err(e) => {
                    eprintln!("aquarium: video backend: GtkGLArea ({e})");
                    None
                }
            },
            Err(why) => {
                eprintln!("aquarium: video backend: GtkGLArea ({why})");
                None
            }
        };

        let (widget, backend): (gtk::Widget, Backend) = match wl_thread {
            Some((globals, thread)) => {
                eprintln!("aquarium: video backend: Wayland subsurface");
                let area = gtk::DrawingArea::new();
                // A GdkWindow of its own, like the GLArea has: for the cursor
                // below and so its events are its own rather than the
                // overlay's.
                area.set_has_window(true);
                (
                    area.clone().upcast(),
                    Backend::Wl(Wl {
                        area,
                        thread,
                        globals,
                        sub: Rc::new(RefCell::new(None)),
                        parent: Rc::new(Cell::new(std::ptr::null_mut())),
                        last_pos: Rc::new(Cell::new((0, 0))),
                    }),
                )
            }
            None => {
                let area = gtk::GLArea::new();
                area.set_auto_render(false);
                area.set_has_depth_buffer(false);
                area.set_has_stencil_buffer(false);
                (area.clone().upcast(), Backend::Gl { area })
            }
        };

        // The overlay child's rectangle, the analogue of the old
        // `configure_window` on the X11 child. `get-child-position` is not
        // needed for it — and is not enough on its own: gtk-rs 0.18 does not
        // bind it, and GTK falls back to the child's natural size (0 for a
        // GLArea) on allocation passes where it is not re-emitted.
        widget.set_halign(gtk::Align::Fill);
        widget.set_valign(gtk::Align::Start);
        widget.set_hexpand(true);
        // `show_all` on the toplevel must not reveal the video before anything
        // is playing; visibility is ours to drive.
        widget.set_no_show_all(true);
        // Under X11 the embedded child window had keyboard/mouse input for
        // free; a GTK widget gets plain GTK events instead, which
        // `connect_input` translates into the same commands a real mpv window
        // would produce.
        widget.set_can_focus(true);
        widget.add_events(
            gtk::gdk::EventMask::POINTER_MOTION_MASK
                | gtk::gdk::EventMask::BUTTON_PRESS_MASK
                | gtk::gdk::EventMask::BUTTON_RELEASE_MASK
                | gtk::gdk::EventMask::SCROLL_MASK
                | gtk::gdk::EventMask::SMOOTH_SCROLL_MASK
                | gtk::gdk::EventMask::KEY_PRESS_MASK
                | gtk::gdk::EventMask::KEY_RELEASE_MASK,
        );
        overlay.add_overlay(&widget);

        // A widget with no cursor of its own inherits the toplevel's, which is
        // whatever GTK last set — the resize arrows from a window edge, or a
        // hand from the page. Over the video that reads as "this is all
        // clickable", which it isn't.
        widget.connect_realize(|a| {
            if let (Some(win), Some(display)) = (a.window(), gtk::gdk::Display::default()) {
                if let Some(cursor) = gtk::gdk::Cursor::from_name(&display, "default") {
                    win.set_cursor(Some(&cursor));
                }
            }
        });

        connect_input(&widget, video.clone());

        // The overlay's own allocation is the only honest measure of the space
        // the video can have; re-derive the height request from it on every
        // layout pass. `get-child-position` would not do instead: gtk-rs 0.18
        // does not bind it, and GTK falls back to the child's natural size —
        // zero, for a GLArea — on passes where it is not re-emitted.
        let layout = Rc::new(Layout {
            trim: Cell::new(0),
            bar_css: Cell::new(0),
            requested: Cell::new(-1),
            pip: Cell::new(false),
        });
        {
            let widget = widget.clone();
            let layout = layout.clone();
            overlay.connect_size_allocate(move |_, alloc| layout.apply(&widget, alloc.height()));
        }

        match &backend {
            Backend::Gl { area } => {
                connect_gl_backend(area, &overlay, &webview, video.clone());
            }
            Backend::Wl(w) => {
                connect_wl_backend(w, &layout, &overlay);
            }
        }

        let surface = Arc::new(Surface {
            app: window.app_handle().clone(),
            geom: Mutex::new(Geom { win_h: 1, h: 1, bar: 0 }),
            session: AtomicU64::new(0),
            next_session: AtomicU64::new(0),
            pip: AtomicBool::new(false),
            on_pip_close: Mutex::new(None),
        });

        if debug_enabled() {
            eprintln!("aquarium: video surface widget tree:");
            dump_tree(gtk_win.upcast_ref::<gtk::Widget>(), 0);
        }

        UI.with(|slot| {
            *slot.borrow_mut() = Some(Ui {
                overlay,
                widget,
                backend,
                pip_win: None,
                video,
                layout,
            });
        });
        Ok(surface)
    }

    /// Hand the surface the mpv handle it should render, and block until the
    /// render context actually exists.
    ///
    /// The wait is not politeness. mpv initialises `vo=libmpv` while it opens
    /// the file, and a render context that is not there by then means it gives
    /// up on video for that file entirely — "Error opening/initializing the
    /// selected video_out (--vo) device", then "Video: no video", with the
    /// audio playing on as if nothing were wrong. Building the context on the
    /// first `render` signal (Phase 1) leaves whether that signal beats
    /// `loadfile` to chance; on native Wayland it loses. So the caller waits
    /// here, and only then loads a file.
    ///
    /// Must not be called from the GTK main thread — it is that thread the
    /// wait is waiting on.
    pub fn attach(&self, mpv: Arc<Mpv>) -> Result<(), String> {
        let (wl_tx, wl_rx) = std::sync::mpsc::channel::<Result<(), String>>();
        with_ui(&self.app, move |ui| {
            ui.release_gl();
            ui.video.borrow_mut().mpv = Some(mpv.clone());
            match &ui.backend {
                Backend::Gl { area } => area.queue_render(),
                Backend::Wl(w) => {
                    ui.wl_ensure_subsurface();
                    w.thread.send(Cmd::Attach { mpv, reply: wl_tx });
                }
            }
        });
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
        loop {
            // Subsurface backend: the thread answers once the context exists.
            match wl_rx.try_recv() {
                Ok(r) => return r,
                Err(std::sync::mpsc::TryRecvError::Empty) => {}
                // The sender was dropped without a reply: GLArea backend, or
                // the UI is gone.
                Err(std::sync::mpsc::TryRecvError::Disconnected) => {}
            }
            let (tx, rx) = std::sync::mpsc::channel();
            with_ui(&self.app, move |ui| {
                let ready = match &ui.backend {
                    Backend::Gl { area } => {
                        let ready = ui.ensure_render_ctx();
                        if !ready {
                            // Not realized yet. Asking for a frame is what
                            // gets it there, and the signal builds the
                            // context too.
                            area.queue_render();
                        }
                        Some(ready)
                    }
                    Backend::Wl(_) => None,
                };
                let _ = tx.send(ready);
            });
            if let Ok(Some(true)) = rx.recv_timeout(std::time::Duration::from_millis(250)) {
                return Ok(());
            }
            if let Ok(r) = wl_rx.try_recv() {
                return r;
            }
            if std::time::Instant::now() >= deadline {
                return Err("video surface did not come up".into());
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
    }

    pub fn detach(&self) {
        with_ui(&self.app, |ui| {
            ui.release_gl();
            if let Some(w) = ui.wl() {
                w.thread.send(Cmd::Detach);
            }
            ui.video.borrow_mut().mpv = None;
        });
    }

    /// Reveal the surface at the given geometry and take ownership of it for a
    /// new playback session. The returned id is what [`Surface::hide_if`]
    /// checks, so a session that ends after a newer one started cannot tear
    /// down the newer one's surface.
    pub fn show(&self, _x: i16, _y: i16, _w: u16, h: u16) -> Result<u64, String> {
        let id = self.next_session.fetch_add(1, Ordering::SeqCst) + 1;
        let geom = Geom {
            win_h: self.window_inner_h(h),
            h: h as u32,
            bar: 0,
        };
        *self.geom.lock().unwrap() = geom;
        self.session.store(id, Ordering::SeqCst);
        let in_pip = self.pip.load(Ordering::SeqCst);
        with_ui(&self.app, move |ui| {
            if !in_pip {
                apply_geom(ui, geom);
            }
            ui.widget.show();
            match &ui.backend {
                Backend::Gl { area } => area.queue_render(),
                Backend::Wl(w) => {
                    ui.wl_ensure_subsurface();
                    w.thread.send(Cmd::Show);
                    // The allocation may not change from the last session;
                    // the thread forgot it on Hide.
                    ui.wl_push_geometry();
                }
            }
            // Match the X11 child window, which had input for free as soon as
            // playback started rather than only after the user clicked it.
            ui.widget.grab_focus();
        });
        Ok(id)
    }

    pub fn resize(&self, _x: i16, _y: i16, _w: u16, h: u16) {
        let win_h = self.window_inner_h(h);
        let geom = {
            let mut g = self.geom.lock().unwrap();
            g.win_h = win_h;
            g.h = h as u32;
            *g
        };
        if self.pip.load(Ordering::SeqCst) {
            return;
        }
        with_ui(&self.app, move |ui| apply_geom(ui, geom));
    }

    /// Hide the bottom `bar` physical pixels of the video without moving the
    /// picture. mpv keeps rendering at the full height; the widget shrinks,
    /// and either the GLArea blits only the rows above the strip out of an
    /// offscreen buffer, or the compositor crops the subsurface to them.
    /// `w` and `h` are accepted for symmetry with the geometry the caller
    /// just computed; the height that matters is the one `resize` stored.
    pub fn set_bottom_clip(&self, _w: u16, _h: u16, bar: u32) {
        let geom = {
            let mut g = self.geom.lock().unwrap();
            g.bar = bar;
            *g
        };
        if self.pip.load(Ordering::SeqCst) {
            return;
        }
        with_ui(&self.app, move |ui| {
            apply_geom(ui, geom);
            // Subsurface backend: crop right away as well. GTK's layout may
            // be frozen while the video covers its surface (see
            // `Cmd::Clip`); the crop is what unfreezes it.
            if let Backend::Wl(w) = &ui.backend {
                let scale = ui.widget.scale_factor().max(1);
                w.thread.send(Cmd::Clip {
                    bar_css: geom.bar as i32 / scale,
                });
            }
        });
    }

    /// Hide only if `id` is still the current session.
    pub fn hide_if(&self, id: u64) {
        if self
            .session
            .compare_exchange(id, 0, Ordering::SeqCst, Ordering::SeqCst)
            .is_ok()
        {
            self.hide_now();
        }
    }

    /// Unconditional teardown, for a caller that owns the surface outright.
    #[allow(dead_code)]
    pub fn hide(&self) {
        self.session.store(0, Ordering::SeqCst);
        self.hide_now();
    }

    fn hide_now(&self) {
        with_ui(&self.app, |ui| {
            ui.release_gl();
            if let Some(w) = ui.wl() {
                w.thread.send(Cmd::Hide);
            }
            ui.widget.hide();
        });
    }

    /// The window's inner height in physical px — the same measurement the
    /// caller used to compute the geometry it is passing. Only the difference
    /// between the two is used, so a resize landing between the two reads
    /// costs at most one frame at the old trim, which the overlay's next
    /// `size-allocate` corrects.
    fn window_inner_h(&self, at_least: u16) -> u32 {
        self.app
            .get_webview_window("main")
            .and_then(|w| w.inner_size().ok())
            .map(|s| s.height)
            .unwrap_or(at_least as u32)
            .max(at_least as u32)
    }

    pub fn has_surface(&self) -> bool {
        self.session.load(Ordering::SeqCst) != 0
    }

    // ---------- Picture in picture ----------

    pub fn is_pip(&self) -> bool {
        self.pip.load(Ordering::SeqCst)
    }

    /// Move the running video out into a small always-on-top window of its
    /// own. The *widget* moves, not the stream: mpv's playback core never
    /// learns about it, so nothing restarts and nothing buffers.
    ///
    /// GLArea backend: GTK unrealizes the GLArea on the way across and
    /// destroys its `GdkGLContext` with it, so the render context is freed
    /// here and rebuilt on the first frame in its new home. Subsurface
    /// backend: a `wl_subsurface` cannot change parent, so a new one is made
    /// on the floating window's surface and the video thread moves its EGL
    /// window over; the render context is not rebuilt.
    pub fn enter_pip(&self) -> Result<(), String> {
        if self.is_pip() {
            return Ok(());
        }
        if !self.has_surface() {
            return Err("no video surface to move".into());
        }
        self.pip.store(true, Ordering::SeqCst);
        let on_close = self.on_pip_close.lock().unwrap().clone();
        let app = self.app.clone();
        with_ui(&self.app, move |ui| {
            ui.release_gl();
            ui.overlay.remove(&ui.widget);

            let win = gtk::Window::new(gtk::WindowType::Toplevel);
            win.set_title(PIP_TITLE);
            win.set_default_size(PIP_W, PIP_H);
            win.set_keep_above(true);
            // The picture fills whatever size the user drags the window to;
            // no height request applies here.
            ui.layout.pip.set(true);
            ui.layout.requested.set(-1);
            // No bar to reserve inside the floating window: the picture fits
            // exactly what the widget is allocated.
            ui.layout.bar_css.set(0);
            // `Video::full` is still the windowed frame's unclipped height —
            // e.g. an 800px-tall app window — from the last `apply_geom` before
            // this call, and nothing in the pip path updates it (`set_bottom_clip`
            // and `resize_video_surface` both bail out while `is_pip()` is true).
            // Left alone, the render callback's `clip = full - visible` comes out
            // huge against the ~270px pip window, so every frame blits a thin
            // strip off the *bottom* of a full-window-height offscreen render
            // instead of the whole picture — the floating window shows a sliver
            // of video, not the frame. Zeroing it here makes `full.max(visible)`
            // track whatever height the pip window actually has, for every frame
            // of the session, so nothing gets clipped — there is no bar to
            // reserve inside the floating window in the first place.
            ui.video.borrow_mut().full = 0;
            ui.widget.set_halign(gtk::Align::Fill);
            ui.widget.set_valign(gtk::Align::Fill);
            ui.widget.set_vexpand(true);
            ui.widget.set_size_request(-1, -1);
            win.add(&ui.widget);

            // Closing the floating window has to put the picture back *and*
            // tell the frontend, or the player bar's button still reads "in
            // PiP". Handling the event ourselves (rather than letting GTK
            // destroy the window) is what keeps the widget alive.
            {
                let app = app.clone();
                let on_close = on_close.clone();
                win.connect_delete_event(move |_, _| {
                    leave_pip_on_main(&app);
                    if let Some(f) = &on_close {
                        f();
                    }
                    glib::Propagation::Stop
                });
            }
            win.show_all();
            ui.widget.show();
            ui.pip_win = Some(win);
            // The floating window is realized now: hang a new subsurface off
            // it. Its first allocation positions and sizes the video.
            ui.wl_ensure_subsurface();
        });
        Ok(())
    }

    /// Bring the picture back into the app window and close the floating one.
    /// The caller puts the surface back at the right geometry afterwards.
    pub fn leave_pip(&self) {
        if !self.pip.swap(false, Ordering::SeqCst) {
            return;
        }
        let geom = *self.geom.lock().unwrap();
        with_ui(&self.app, move |ui| {
            restore_from_pip(ui);
            apply_geom(ui, geom);
        });
    }

    /// Register what to run when the floating window is closed from its own
    /// title bar — the one thing only the window manager can tell us. It runs
    /// after the picture is already back in the app window.
    pub fn watch_pip(self: &Arc<Self>, on_close: impl Fn() + Send + Sync + 'static) {
        *self.on_pip_close.lock().unwrap() = Some(Arc::new(on_close));
    }
}

/// Is the video widget on screen inside the main window's overlay — i.e. over
/// the page, as opposed to hidden or in the picture-in-picture window?
fn video_covers(overlay: &gtk::Overlay, area: &gtk::GLArea) -> bool {
    area.is_mapped() && area.parent().as_ref() == Some(overlay.upcast_ref::<gtk::Widget>())
}

/// Stop GTK repainting what the video hides. GLArea backend only: on the
/// subsurface backend nothing invalidates the video rectangle per frame, so
/// there is nothing to suppress.
///
/// Every video frame invalidates the video widget's rectangle, and GTK then
/// redraws *everything* under that rectangle before blitting the frame over
/// it: the webview composites its full-window frame through cairo (a 21 MB
/// pixman pass at 2880×1920), and the toplevel fills its background under
/// that. Neither pixel survives the blit. Profiled at 55% and 18% of the main
/// thread respectively — three quarters of the app's CPU while a film played.
///
/// The webview's `GdkWindow` gets a shape that excludes the video rectangle,
/// so its draw handler sees an empty clip and paints nothing; the shape is
/// lifted the moment the video stops covering it (hidden, or moved to the
/// picture-in-picture window) — a stale shape would leave the top of the page
/// blank. The toplevel's own fill is skipped with `app_paintable`, but only
/// in fullscreen: in a window GTK draws the client-side decoration in the
/// same pass and would drop the shadow with it. Fullscreen has no decoration,
/// and the webview and video widget between them cover every pixel.
fn sync_webview_clip(overlay: &gtk::Overlay, area: &gtk::GLArea) {
    let covering = video_covers(overlay, area);
    let Some(webview) = overlay.child() else { return };
    if let Some(win) = webview.window() {
        if covering {
            let wv = webview.allocation();
            let va = area.allocation();
            let shape = gtk::cairo::Region::create_rectangle(&gtk::cairo::RectangleInt::new(
                0,
                0,
                wv.width(),
                wv.height(),
            ));
            let _ = shape.subtract_rectangle(&gtk::cairo::RectangleInt::new(
                va.x() - wv.x(),
                va.y() - wv.y(),
                va.width(),
                va.height(),
            ));
            win.shape_combine_region(Some(&shape), 0, 0);
        } else {
            win.shape_combine_region(None, 0, 0);
        }
    }
    if let Some(top) = overlay.toplevel() {
        let fullscreen = top
            .window()
            .map(|w| w.state().contains(gtk::gdk::WindowState::FULLSCREEN))
            .unwrap_or(false);
        top.set_app_paintable(covering && fullscreen);
    }
}

/// Everything the GLArea backend hooks up beyond the shared widget setup.
fn connect_gl_backend(
    area: &gtk::GLArea,
    overlay: &gtk::Overlay,
    webview: &gtk::Widget,
    video: Rc<RefCell<Video>>,
) {
    connect_render(area, video.clone());

    // Free everything GL-shaped while the context that made it still
    // exists. `unrealize` is RUN_LAST, so this runs before GtkGLArea's own
    // handler drops the GdkGLContext — the last moment `make_current` can
    // succeed. Without it, quitting mid-playback aborted the process:
    // the window is torn down first, `RunEvent::Exit` stops the player
    // after, and freeing the render context then has libmpv issue GL
    // calls that libepoxy can't resolve without a current context
    // (`epoxy_get_proc_address: Assertion ... Couldn't find current GLX
    // or EGL context`). Also covers the picture-in-picture moves, which
    // reparent the widget and unrealize it on the way.
    {
        let video = video.clone();
        area.connect_unrealize(move |a| {
            let Ok(mut v) = video.try_borrow_mut() else { return };
            if v.render.is_none() && v.off.is_none() {
                return;
            }
            a.make_current();
            v.release_gl();
        });
    }

    // Keep the webview from painting under the video — see
    // `sync_webview_clip`. Every allocation pass of the video widget, its
    // unmap (hide, or being lifted out for picture-in-picture), and the
    // toplevel going in or out of fullscreen are the moments the answer
    // can change.
    {
        let overlay = overlay.clone();
        area.connect_size_allocate(move |a, _| sync_webview_clip(&overlay, a));
    }
    {
        let overlay = overlay.clone();
        area.connect_unmap(move |a| sync_webview_clip(&overlay, a));
    }
    if let Some(top) = overlay.toplevel() {
        let overlay = overlay.clone();
        let area = area.clone();
        top.connect_window_state_event(move |_, _| {
            sync_webview_clip(&overlay, &area);
            glib::Propagation::Proceed
        });
    }
    // The shape above narrows what GDK considers visible; this is the
    // guarantee. GTK's draw pass clips a child window to its rectangle,
    // not its shape, so WebKit can still be handed the video rectangle
    // and composite its whole frame into it. A user handler on `draw`
    // runs before WebKit's own, and returning Stop is the one thing that
    // keeps that composite from happening at all. Refuse only a clip
    // that lies entirely under the video, and let one paint a second
    // through even then: WebKit acknowledges a web frame to its render
    // process from inside its draw handler, and a page never painted is a
    // page whose frames are never released.
    {
        let overlay = overlay.clone();
        let area = area.clone();
        let last_paint = Cell::new(std::time::Instant::now() - std::time::Duration::from_secs(10));
        webview.connect_draw(move |wv, cr| {
            if !video_covers(&overlay, &area) {
                return glib::Propagation::Proceed;
            }
            let Ok((x1, y1, x2, y2)) = cr.clip_extents() else {
                return glib::Propagation::Proceed;
            };
            let wa = wv.allocation();
            let va = area.allocation();
            let (vx, vy) = ((va.x() - wa.x()) as f64, (va.y() - wa.y()) as f64);
            let (vw, vh) = (va.width() as f64, va.height() as f64);
            let under_video = x1 >= vx && y1 >= vy && x2 <= vx + vw && y2 <= vy + vh;
            if !under_video {
                return glib::Propagation::Proceed;
            }
            if last_paint.get().elapsed() < std::time::Duration::from_secs(1) {
                return glib::Propagation::Stop;
            }
            last_paint.set(std::time::Instant::now());
            glib::Propagation::Proceed
        });
    }
}

/// Everything the subsurface backend hooks up beyond the shared widget
/// setup: the placeholder's paint, and geometry to the video thread.
/// The geometry the video should have right now: the widget's own allocation
/// in picture-in-picture (it fills that window), else the overlay's minus the
/// trim `Layout::apply` asks for — which is what the widget's allocation *will*
/// be once GTK's layout catches up. After a state change it has not: a hidden
/// widget keeps its last session's allocation (a full fullscreen window's,
/// say), GTK re-allocates it at that stale size on show, and the pass that
/// would shrink it runs from an idle a frame later — a frame that a video
/// covering the whole toplevel can stall indefinitely (see `Cmd::Clip`). So
/// the stale allocation is never what the video thread is told; the second
/// element is the widget whose (0, 0) is the video's origin in the toplevel.
fn intended_alloc<'a>(
    layout: &Layout,
    widget: &'a gtk::Widget,
    overlay: &'a gtk::Overlay,
    alloc: &gtk::Allocation,
) -> (&'a gtk::Widget, gtk::Allocation) {
    if layout.pip.get() {
        return (widget, *alloc);
    }
    let ov = overlay.allocation();
    let h = (ov.height() - layout.trim.get()).max(1);
    (overlay.upcast_ref(), gtk::Allocation::new(0, 0, ov.width(), h))
}

fn connect_wl_backend(w: &Wl, layout: &Rc<Layout>, overlay: &gtk::Overlay) {
    // The placeholder paints the app background — what shows through before
    // the first frame, and what the subsurface covers after. Nothing
    // invalidates it during playback, so this runs once per layout change.
    w.area.connect_draw(|_, cr| {
        cr.set_source_rgb(BG.0 as f64, BG.1 as f64, BG.2 as f64);
        let _ = cr.paint();
        glib::Propagation::Stop
    });

    {
        let w2 = Wl {
            area: w.area.clone(),
            thread: w.thread.clone(),
            globals: w.globals.clone(),
            sub: w.sub.clone(),
            parent: w.parent.clone(),
            last_pos: w.last_pos.clone(),
        };
        let layout = layout.clone();
        let overlay = overlay.clone();
        w.area.connect_size_allocate(move |a, alloc| {
            // The allocation is the trigger, not the size — see `intended_alloc`.
            let (origin, alloc) = intended_alloc(&layout, a.upcast_ref(), &overlay, alloc);
            wl_geometry_changed(&w2, &layout, a.upcast_ref(), origin, &alloc);
        });
    }
    // A monitor with a different scale: same allocation, different buffer.
    {
        let w2 = Wl {
            area: w.area.clone(),
            thread: w.thread.clone(),
            globals: w.globals.clone(),
            sub: w.sub.clone(),
            parent: w.parent.clone(),
            last_pos: w.last_pos.clone(),
        };
        let layout = layout.clone();
        let overlay = overlay.clone();
        w.area.connect_scale_factor_notify(move |a| {
            let (origin, alloc) = intended_alloc(&layout, a.upcast_ref(), &overlay, &a.allocation());
            if alloc.width() >= 1 && alloc.height() >= 1 {
                wl_geometry_changed(&w2, &layout, a.upcast_ref(), origin, &alloc);
            }
        });
    }
}

/// Size the video widget against the *overlay*, never the toplevel — see
/// [`Layout`].
fn apply_geom(ui: &Ui, geom: Geom) {
    let scale = ui.widget.scale_factor().max(1);
    // Everything the video must leave clear: the player-bar reserve the caller
    // asked for, plus the strip the revealed fullscreen bar sits in. Physical
    // px in, logical px out — the render callback works in physical pixels off
    // the allocation it actually gets, so rounding here cannot desync them.
    let trim = geom.win_h.saturating_sub(geom.h) as i32 + geom.bar as i32;
    // `geom.h` is the true unclipped height regardless of bar-reveal state —
    // in fullscreen it's always the whole window (the bar is cut from it by
    // blitting, not by shrinking what mpv fits to); in windowed mode it's the
    // window minus the permanent reserve, where clip is always zero anyway.
    ui.video.borrow_mut().full = geom.h as i32;
    ui.layout.trim.set(trim / scale);
    ui.layout.bar_css.set(geom.bar as i32 / scale);
    ui.layout.apply(&ui.widget, ui.overlay.allocated_height());
    match &ui.backend {
        Backend::Gl { area } => area.queue_render(),
        // The target size goes to the video thread now rather than after
        // GTK's next layout pass — which, with the video covering the whole
        // toplevel, may never come (see `wl_push_geometry`).
        Backend::Wl(_) => {
            if !ui.layout.pip.get() {
                ui.wl_push_geometry();
            }
        }
    }
    set_video_cursor(&ui.widget, geom.h >= geom.win_h && geom.bar == 0);
}

/// Fullscreen with the controls hidden is the one state where the pointer has
/// nothing to point at: it goes away until it moves, when the bar comes back
/// and it with it. The widget's own GdkWindow is what is under the pointer
/// there (it covers the window), so the cursor is set on that; everywhere
/// else — windowed, the bar revealed, picture-in-picture — it is the plain
/// arrow `Surface::new` gave it.
fn set_video_cursor(widget: &gtk::Widget, blank: bool) {
    let (Some(win), Some(display)) = (widget.window(), gdk::Display::default()) else { return };
    let cursor = if blank {
        gdk::Cursor::for_display(&display, gdk::CursorType::BlankCursor)
    } else {
        gdk::Cursor::from_name(&display, "default")
    };
    win.set_cursor(cursor.as_ref());
    if debug_enabled() {
        eprintln!("aquarium: video cursor {}", if blank { "hidden" } else { "shown" });
    }
}

/// Put the widget back under the overlay and dispose of the floating window.
/// `destroy` rather than `close`: `close` emits `delete-event`, which is the
/// handler that calls this, and re-entering it would deadlock the borrow.
fn restore_from_pip(ui: &mut Ui) {
    ui.release_gl();
    let win = ui.pip_win.take();
    if let Some(win) = &win {
        win.remove(&ui.widget);
    }
    ui.widget.set_valign(gtk::Align::Start);
    ui.widget.set_vexpand(false);
    ui.layout.pip.set(false);
    ui.overlay.add_overlay(&ui.widget);
    ui.widget.show();
    // Back on the main window's surface. The video thread drops the floating
    // window's subsurface, which can outlive the window it hung off.
    ui.wl_ensure_subsurface();
    if let Some(win) = win {
        // Safety: the widget was removed above, so nothing we keep a handle to
        // is a descendant of the window being destroyed.
        unsafe { win.destroy() };
    }
}

/// The `delete-event` path. Already on the main thread, and the UI borrow the
/// caller might hold is GTK's, not ours, so this can touch it directly.
fn leave_pip_on_main(app: &AppHandle) {
    if let Some(shared) = app.try_state::<SurfaceShared>() {
        if let Some(s) = shared.0.clone() {
            s.pip.store(false, Ordering::SeqCst);
            let geom = *s.geom.lock().unwrap();
            UI.with(|ui| {
                if let Some(ui) = ui.borrow_mut().as_mut() {
                    restore_from_pip(ui);
                    apply_geom(ui, geom);
                }
            });
        }
    }
}

// -------------------------------------------------------------- render signal
//
// GLArea backend only.

fn connect_render(area: &gtk::GLArea, video: Rc<RefCell<Video>>) {
    area.connect_render(move |area, _ctx| {
        if let Some(e) = area.error() {
            eprintln!("aquarium: GLArea failed to realize: {e}");
            return glib::Propagation::Proceed;
        }
        let Some(g) = gl::api() else {
            return glib::Propagation::Proceed;
        };
        // GTK leaves GL_INVALID_FRAMEBUFFER_OPERATION pending on the first
        // frame; mpv reads it back as its own and warns. Drain it so mpv's
        // diagnostics mean something.
        gl::drain_errors(g);

        let mut v = video.borrow_mut();
        let scale = area.scale_factor().max(1);
        let w = (area.allocated_width() * scale).max(1);
        let visible = (area.allocated_height() * scale).max(1);
        // `full` is the fixed target height set synchronously in `apply_geom`,
        // never the live widget allocation — see the comment on `Video::full`.
        // `visible` can still be momentarily behind it (the widget's own
        // resize is queued from an idle callback), in which case this simply
        // blits less of the same fit than steady state will settle on, rather
        // than handing mpv a wrongly-sized FBO to re-fit into.
        let full = v.full.max(visible);
        let clip = (full - visible).max(0);

        let mut target = 0i32;
        unsafe { (g.get_integerv)(gl::DRAW_FRAMEBUFFER_BINDING, &mut target) };

        if debug_enabled() {
            // Every geometry change, then one line a couple of seconds: enough
            // to see the clip take effect without drowning the log at 60fps.
            static N: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);
            static LAST: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
            let n = N.fetch_add(1, Ordering::Relaxed);
            let shape = ((w as u64) << 40) | ((visible as u64) << 20) | (clip.max(0) as u64);
            if LAST.swap(shape, Ordering::Relaxed) != shape || n.is_multiple_of(120) {
                eprintln!(
                    "aquarium: render #{n} widget={}x{} scale={scale} \
                     phys={w}x{visible} clip={clip} full={full} mpv={}",
                    area.allocated_width(),
                    area.allocated_height(),
                    v.mpv.is_some()
                );
            }
        }

        // No mpv attached yet: paint the app background, so the rectangle reads
        // as part of the window rather than as uninitialised memory.
        if v.mpv.is_none() {
            unsafe {
                (g.viewport)(0, 0, w, visible);
                (g.clear_color)(BG.0, BG.1, BG.2, 1.0);
                (g.clear)(gl::COLOR_BUFFER_BIT);
            }
            return glib::Propagation::Stop;
        }

        if !build_render_ctx(area, &mut v) {
            return glib::Propagation::Proceed;
        }
        let ctx = v.render.as_ref().unwrap();

        if clip == 0 {
            // Nothing to hide: render straight into the widget.
            let _ = ctx.render(target, w, visible, true);
        } else {
            let off = Offscreen::ensure(&mut v.off, g, w, full);
            let (fbo, ow, oh) = (off.fbo, off.w, off.h);
            let _ = v.render.as_ref().unwrap().render(fbo as i32, ow, oh, true);
            unsafe {
                (g.bind_framebuffer)(gl::READ_FRAMEBUFFER, fbo);
                (g.bind_framebuffer)(gl::DRAW_FRAMEBUFFER, target as u32);
                // Keep the picture pinned: take the top `visible` rows of a
                // full-height render rather than re-rendering smaller.
                (g.blit_framebuffer)(
                    0,
                    clip,
                    w,
                    full,
                    0,
                    0,
                    w,
                    visible,
                    gl::COLOR_BUFFER_BIT,
                    gl::NEAREST as u32,
                );
                (g.bind_framebuffer)(gl::FRAMEBUFFER, target as u32);
            }
        }
        glib::Propagation::Stop
    });
}

/// Build the render context if there is a handle to build one on and it isn't
/// built yet. Returns whether it exists afterwards. The caller must be on the
/// GTK main thread with the GLArea's context current.
fn build_render_ctx(area: &gtk::GLArea, v: &mut Video) -> bool {
    if v.render.is_some() {
        return true;
    }
    let Some(mpv) = v.mpv.clone() else {
        return false;
    };
    match make_render_ctx(area, mpv) {
        Ok(ctx) => {
            v.render = Some(ctx);
            true
        }
        Err(e) => {
            eprintln!("aquarium: {e}");
            false
        }
    }
}

/// Build the render context for whichever display connection GDK is on.
/// Passing it is what makes hardware decode interop work — miss it and `hwdec`
/// silently resolves to `no`, which looks exactly like the problem this
/// migration set out to fix.
fn make_render_ctx(area: &gtk::GLArea, mpv: Arc<Mpv>) -> Result<RenderCtx, String> {
    let display = gtk::gdk::Display::default().ok_or("no GDK display")?;
    let backend = display.type_().name().to_string();
    let dpy: *mut c_void =
        ToGlibPtr::<*mut gtk::gdk::ffi::GdkDisplay>::to_glib_none(&display).0 as *mut c_void;
    let native = if backend.contains("Wayland") {
        NativeDisplay::Wayland(unsafe { gdk_wayland_display_get_wl_display(dpy) })
    } else {
        NativeDisplay::X11(unsafe { gdk_x11_display_get_xdisplay(dpy) })
    };
    if let Some(g) = gl::api() {
        let name = |e: u32| unsafe {
            let p = (g.get_string)(e);
            if p.is_null() {
                "?".to_string()
            } else {
                std::ffi::CStr::from_ptr(p as *const _)
                    .to_string_lossy()
                    .into_owned()
            }
        };
        // GL_VENDOR / GL_RENDERER.
        eprintln!(
            "aquarium: video surface on {backend}, GL vendor={} renderer={}",
            name(0x1F00),
            name(0x1F01)
        );
    }
    let mut ctx = RenderCtx::new(mpv, native, false)?;

    let weak: glib::SendWeakRef<gtk::GLArea> = area.downgrade().into();
    ctx.set_update_callback(move || {
        // Fires on mpv's render thread: it must not touch GL or the mpv API,
        // only ask the main loop to find out what it meant.
        let weak = weak.clone();
        glib::idle_add_once(move || {
            let Some(a) = weak.upgrade() else { return };
            // mpv raises the callback for more than new frames, and a redraw
            // for anything else is a full-resolution re-render of the same
            // picture. `update()` is render-thread only, hence here and not
            // in the callback above. `None` — no context yet, or the cell is
            // busy — falls back to redrawing, never to dropping a frame.
            let due = UI.with(|ui| {
                let ui = ui.try_borrow().ok()?;
                let ui = ui.as_ref()?;
                let v = ui.video.try_borrow().ok()?;
                Some(v.render.as_ref()?.update() & RenderCtx::UPDATE_FRAME != 0)
            });
            if due.unwrap_or(true) {
                a.queue_render();
            }
        });
    });
    Ok(ctx)
}

// -------------------------------------------------------------- input events
//
// Under X11 the embedded child window had keyboard and mouse input for free,
// because it was mpv's own window as far as the display server was concerned.
// A GTK widget gets plain GTK input signals instead, which carry GDK's shape
// (keyvals, `ModifierType`, widget-relative coordinates) rather than mpv's.
// This translates one into the other by calling `mpv_command_string` with the
// same key/mouse command syntax a real mpv window's input driver would issue.
// See WAYLAND-MIGRATION.md Phase 4. On the subsurface backend the video
// surface itself has an empty input region, so every event over the video
// lands on this widget underneath it, exactly as on the GLArea.

/// Run one mpv input command (`"keydown MBTN_LEFT"`, `"mouse 12 34"`, ...) on
/// whatever core is currently attached. Silently a no-op with nothing
/// attached — the widget still receives events before playback starts and
/// briefly during a session handoff.
fn send_input(video: &Rc<RefCell<Video>>, cmd: &str) {
    let mpv = video.borrow().mpv.clone();
    let Some(mpv) = mpv else { return };
    let Ok(c) = std::ffi::CString::new(cmd) else { return };
    let err = unsafe { libmpv2_sys::mpv_command_string(mpv.ctx.as_ptr(), c.as_ptr()) };
    if err < 0 && debug_enabled() {
        eprintln!(
            "aquarium: input {cmd:?} failed: {}",
            libmpv2_sys::mpv_error_str(err)
        );
    }
}

/// mpv's name for a GDK button number, or `None` for a button mpv has no
/// input.conf-relevant name for (mpv still names buttons past this with
/// `MBTN9`.. but the bundled config has nothing to bind them to).
fn mbtn_name(button: u32) -> Option<&'static str> {
    match button {
        1 => Some("MBTN_LEFT"),
        2 => Some("MBTN_MID"),
        3 => Some("MBTN_RIGHT"),
        8 => Some("MBTN_BACK"),
        9 => Some("MBTN_FORWARD"),
        _ => None,
    }
}

/// The base mpv key name for a GDK keyval, and whether it is a *named* key
/// (`LEFT`, `ESC`, ...) rather than a literal character key (`a`, `[`, ...).
///
/// Only named keys take a `Shift+` prefix. For character keys GDK's keyval
/// already reflects the shifted glyph (`man mpv`: "the actual produced text
/// key name when shift is pressed should be used" — e.g. Shift+2 is `@`, not
/// `Shift+2`), so prefixing those too would be redundant at best.
fn mpv_key_name(keyval: gtk::gdk::keys::Key) -> Option<(String, bool)> {
    use gtk::gdk::keys::constants as k;
    let named = if keyval == k::Escape {
        "ESC"
    } else if keyval == k::Return {
        "ENTER"
    } else if keyval == k::KP_Enter {
        "KP_ENTER"
    } else if keyval == k::BackSpace {
        "BS"
    } else if keyval == k::Tab || keyval == k::ISO_Left_Tab {
        "TAB"
    } else if keyval == k::Delete {
        "DEL"
    } else if keyval == k::Insert {
        "INS"
    } else if keyval == k::Home {
        "HOME"
    } else if keyval == k::End {
        "END"
    } else if keyval == k::Page_Up {
        "PGUP"
    } else if keyval == k::Page_Down {
        "PGDWN"
    } else if keyval == k::Left {
        "LEFT"
    } else if keyval == k::Right {
        "RIGHT"
    } else if keyval == k::Up {
        "UP"
    } else if keyval == k::Down {
        "DOWN"
    } else if keyval == k::space {
        "SPACE"
    } else {
        ""
    };
    if !named.is_empty() {
        return Some((named.to_string(), true));
    }
    // F1..F24 are contiguous keysyms; every other named key mpv defines
    // (KP_*, MOUSE_*, ...) is either unreachable from a keyboard or not worth
    // the table entry for what input.conf actually binds.
    let (v, f1, f24) = (*keyval, *k::F1, *k::F24);
    if (f1..=f24).contains(&v) {
        return Some((format!("F{}", v - f1 + 1), true));
    }
    // Everything else: the literal UTF-8 codepoint GDK resolved from the
    // keyval, which is what mpv's text key names are (`man mpv`: "Unicode
    // code points encoded as UTF-8 ... what keyboard input would normally
    // produce").
    keyval.to_unicode().map(|c| (c.to_string(), false))
}

/// The full `keypress` argument for a key event: modifiers plus base name.
fn build_key_command(keyval: gtk::gdk::keys::Key, state: gtk::gdk::ModifierType) -> Option<String> {
    use gtk::gdk::ModifierType as M;
    let (base, is_named) = mpv_key_name(keyval)?;
    let mut prefix = String::new();
    if state.contains(M::CONTROL_MASK) {
        prefix.push_str("Ctrl+");
    }
    if state.contains(M::MOD1_MASK) {
        prefix.push_str("Alt+");
    }
    if state.contains(M::SUPER_MASK) || state.contains(M::META_MASK) {
        prefix.push_str("Meta+");
    }
    if is_named && state.contains(M::SHIFT_MASK) {
        prefix.push_str("Shift+");
    }
    Some(format!("{prefix}{base}"))
}

/// Wire up the video widget's input signals. Must run once, at widget
/// construction.
fn connect_input(area: &gtk::Widget, video: Rc<RefCell<Video>>) {
    // Accumulated fractional scroll units from a touchpad's smooth-scroll
    // events, carried across calls until they add up to a whole `WHEEL_*`.
    let smooth: Rc<Cell<(f64, f64)>> = Rc::new(Cell::new((0.0, 0.0)));

    area.connect_motion_notify_event({
        let video = video.clone();
        move |area, ev| {
            // Physical pixels, matching what the render callback computes the
            // widget's surface at — and what keeps mpv's `mouse-pos` property
            // (which the frontend observes for its fullscreen bar, and uosc
            // reads for hover) in the same coordinate space video pixels are.
            let scale = area.scale_factor().max(1) as f64;
            let (x, y) = ev.position();
            send_input(
                &video,
                &format!("mouse {} {}", (x * scale).round() as i64, (y * scale).round() as i64),
            );
            glib::Propagation::Stop
        }
    });

    area.connect_button_press_event({
        let video = video.clone();
        move |area, ev| {
            // Only the plain press matters here. mpv runs its own click timer
            // over the keydown/keyup MBTN_LEFT pairs below exactly as it would
            // over real hardware input, and synthesizes MBTN_LEFT_DBL itself —
            // confirmed against a real double click (see WAYLAND-MIGRATION.md
            // Phase 4); GTK's own `GDK_DOUBLE_BUTTON_PRESS`/`GDK_TRIPLE_BUTTON_PRESS`
            // events need no handling of their own, and synthesizing `_DBL`
            // here too double-fired `input.conf`'s fullscreen binding.
            if ev.event_type() == gtk::gdk::EventType::ButtonPress {
                area.grab_focus();
                if let Some(name) = mbtn_name(ev.button()) {
                    // keydown/keyup rather than the one-shot `mouse ...
                    // MBTN_LEFT`, so uosc can tell a press from a release and
                    // drag the timeline between them.
                    send_input(&video, &format!("keydown {name}"));
                }
            }
            glib::Propagation::Stop
        }
    });

    area.connect_button_release_event({
        let video = video.clone();
        move |_area, ev| {
            if let Some(name) = mbtn_name(ev.button()) {
                send_input(&video, &format!("keyup {name}"));
            }
            glib::Propagation::Stop
        }
    });

    area.connect_scroll_event({
        let video = video.clone();
        let smooth = smooth.clone();
        move |_area, ev| {
            use gtk::gdk::ScrollDirection as D;
            match ev.direction() {
                D::Up => send_input(&video, "keypress WHEEL_UP"),
                D::Down => send_input(&video, "keypress WHEEL_DOWN"),
                D::Left => send_input(&video, "keypress WHEEL_LEFT"),
                D::Right => send_input(&video, "keypress WHEEL_RIGHT"),
                D::Smooth => {
                    let (dx, dy) = ev.delta();
                    let (mut ax, mut ay) = smooth.get();
                    ax += dx;
                    ay += dy;
                    while ay >= 1.0 {
                        send_input(&video, "keypress WHEEL_DOWN");
                        ay -= 1.0;
                    }
                    while ay <= -1.0 {
                        send_input(&video, "keypress WHEEL_UP");
                        ay += 1.0;
                    }
                    while ax >= 1.0 {
                        send_input(&video, "keypress WHEEL_RIGHT");
                        ax -= 1.0;
                    }
                    while ax <= -1.0 {
                        send_input(&video, "keypress WHEEL_LEFT");
                        ax += 1.0;
                    }
                    smooth.set((ax, ay));
                }
                _ => {}
            }
            glib::Propagation::Stop
        }
    });

    area.connect_key_press_event({
        let video = video.clone();
        move |_area, ev| {
            // A bare modifier (Shift alone, etc.) has no mpv key name of its
            // own; GDK already knows which keyvals those are.
            if !ev.is_modifier() {
                if let Some(cmd) = build_key_command(ev.keyval(), ev.state()) {
                    send_input(&video, &format!("keypress {cmd}"));
                }
            }
            glib::Propagation::Stop
        }
    });
}
