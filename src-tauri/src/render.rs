//! An owning wrapper around `mpv_render_context`.
//!
//! `libmpv2::render::RenderContext<'a>` borrows the `Mpv` it was created from,
//! which makes the obvious "one struct holding the handle and its context"
//! self-referential. The spike sidestepped that by leaking the handle; here the
//! handle is an `Arc<Mpv>` and the context is built directly on `libmpv2-sys`,
//! so the two can live in the same struct and be dropped in the right order.
//!
//! Everything in here must be called on the thread that owns the GL context
//! mpv was created against, with that context current — the GTK main thread
//! for the GLArea path, the video thread for the subsurface path. The one
//! exception is [`RenderCtx::set_update_callback`], whose callback fires on
//! mpv's own render thread and must not touch GL.
use libmpv2::Mpv;
use std::ffi::{c_char, c_int, c_void};
use std::sync::Arc;

/// mpv hands this the plain GL name; libepoxy's dispatch thunk resolves itself
/// against whatever context is current on first call.
unsafe extern "C" fn get_proc_address(_ctx: *mut c_void, name: *const c_char) -> *mut c_void {
    let Ok(name) = (unsafe { std::ffi::CStr::from_ptr(name) }).to_str() else {
        return std::ptr::null_mut();
    };
    crate::gl::proc_addr(name)
}

unsafe extern "C" fn update_thunk(ctx: *mut c_void) {
    if ctx.is_null() {
        return;
    }
    unsafe { (*(ctx as *mut Box<dyn Fn() + Send>))() };
}

/// Which display connection mpv is given at context creation. Passing it is
/// what makes hardware decode interop work; miss it and decoding silently
/// drops to software (`hwdec-current` reads `no`).
pub enum NativeDisplay {
    Wayland(*mut c_void),
    X11(*mut c_void),
}

pub struct RenderCtx {
    ctx: *mut libmpv2_sys::mpv_render_context,
    /// Keeps the mpv handle alive for at least as long as the context: mpv
    /// requires the render context to be freed before `mpv_destroy`.
    _mpv: Arc<Mpv>,
    update: Option<*mut Box<dyn Fn() + Send>>,
}

impl RenderCtx {
    /// Must run on the owning thread with the GL context current.
    ///
    /// `advanced` sets `MPV_RENDER_PARAM_ADVANCED_CONTROL`: the caller then
    /// promises to call [`RenderCtx::update`] after every update callback and
    /// [`RenderCtx::report_swap`] after every swap, and in return mpv does
    /// its decoder texture uploads on that thread eagerly instead of lazily
    /// inside `render`. Only the video thread can keep that promise; the
    /// GLArea path passes `false`.
    pub fn new(mpv: Arc<Mpv>, native: NativeDisplay, advanced: bool) -> Result<Self, String> {
        let api = libmpv2_sys::MPV_RENDER_API_TYPE_OPENGL.as_ptr() as *mut c_void;
        let mut init = libmpv2_sys::mpv_opengl_init_params {
            get_proc_address: Some(get_proc_address),
            get_proc_address_ctx: std::ptr::null_mut(),
        };
        let (native_type, native_ptr) = match native {
            NativeDisplay::Wayland(p) => (
                libmpv2_sys::mpv_render_param_type_MPV_RENDER_PARAM_WL_DISPLAY,
                p,
            ),
            NativeDisplay::X11(p) => (
                libmpv2_sys::mpv_render_param_type_MPV_RENDER_PARAM_X11_DISPLAY,
                p,
            ),
        };
        let mut adv: c_int = if advanced { 1 } else { 0 };
        // mpv copies out of these during the call, so locals are enough.
        let mut params = [
            libmpv2_sys::mpv_render_param {
                type_: libmpv2_sys::mpv_render_param_type_MPV_RENDER_PARAM_API_TYPE,
                data: api,
            },
            libmpv2_sys::mpv_render_param {
                type_: libmpv2_sys::mpv_render_param_type_MPV_RENDER_PARAM_OPENGL_INIT_PARAMS,
                data: &mut init as *mut _ as *mut c_void,
            },
            libmpv2_sys::mpv_render_param {
                type_: native_type,
                data: native_ptr,
            },
            libmpv2_sys::mpv_render_param {
                type_: libmpv2_sys::mpv_render_param_type_MPV_RENDER_PARAM_ADVANCED_CONTROL,
                data: &mut adv as *mut _ as *mut c_void,
            },
            // The array must end with type = 0.
            libmpv2_sys::mpv_render_param {
                type_: 0,
                data: std::ptr::null_mut(),
            },
        ];
        let mut ctx: *mut libmpv2_sys::mpv_render_context = std::ptr::null_mut();
        let err = unsafe {
            libmpv2_sys::mpv_render_context_create(&mut ctx, mpv.ctx.as_ptr(), params.as_mut_ptr())
        };
        if err < 0 || ctx.is_null() {
            return Err(format!("mpv_render_context_create failed: {err}"));
        }
        Ok(Self {
            ctx,
            _mpv: mpv,
            update: None,
        })
    }

    /// Fires on mpv's render thread when a new frame is ready. It must not
    /// touch GL or call back into mpv — only ask the main loop for a frame.
    pub fn set_update_callback<F: Fn() + Send + 'static>(&mut self, f: F) {
        let boxed: *mut Box<dyn Fn() + Send> = Box::into_raw(Box::new(Box::new(f)));
        unsafe {
            libmpv2_sys::mpv_render_context_set_update_callback(
                self.ctx,
                Some(update_thunk),
                boxed as *mut c_void,
            );
        }
        // Replace only after mpv has the new one, so it can never call into a
        // box we already freed.
        if let Some(old) = self.update.replace(boxed) {
            drop(unsafe { Box::from_raw(old) });
        }
    }

    /// Draw the current frame into `fbo` at `w`x`h` physical pixels. `flip` is
    /// always true for GL, whose Y axis runs the other way from video's.
    /// `MPV_RENDER_UPDATE_FRAME` in [`RenderCtx::update`]'s result: a new frame
    /// (or a redraw of the current one, for an OSD change) is due.
    pub const UPDATE_FRAME: u64 = 1 << 0;

    /// What the last update callback meant. mpv raises that callback for
    /// more than new frames — property changes, a display reconfiguration,
    /// installing the callback itself — and only this says whether
    /// [`RenderCtx::render`] is actually needed. Must run on the render
    /// thread, never inside the update callback (render.h).
    pub fn update(&self) -> u64 {
        unsafe { libmpv2_sys::mpv_render_context_update(self.ctx) }
    }

    pub fn render(&self, fbo: i32, w: i32, h: i32, flip: bool) -> Result<(), String> {
        let mut target = libmpv2_sys::mpv_opengl_fbo {
            fbo,
            w,
            h,
            internal_format: 0,
        };
        let mut flip_y: c_int = if flip { 1 } else { 0 };
        let mut params = [
            libmpv2_sys::mpv_render_param {
                type_: libmpv2_sys::mpv_render_param_type_MPV_RENDER_PARAM_OPENGL_FBO,
                data: &mut target as *mut _ as *mut c_void,
            },
            libmpv2_sys::mpv_render_param {
                type_: libmpv2_sys::mpv_render_param_type_MPV_RENDER_PARAM_FLIP_Y,
                data: &mut flip_y as *mut _ as *mut c_void,
            },
            libmpv2_sys::mpv_render_param {
                type_: 0,
                data: std::ptr::null_mut(),
            },
        ];
        let err = unsafe { libmpv2_sys::mpv_render_context_render(self.ctx, params.as_mut_ptr()) };
        if err < 0 {
            return Err(format!("mpv_render_context_render failed: {err}"));
        }
        Ok(())
    }

    /// Tell mpv the frame it last rendered has been handed to the display.
    /// Part of the advanced-control contract; mpv uses the timing for its
    /// vsync estimate.
    pub fn report_swap(&self) {
        unsafe { libmpv2_sys::mpv_render_context_report_swap(self.ctx) }
    }
}

impl Drop for RenderCtx {
    /// mpv requires this to run on the thread that owns the GL context, with
    /// that context current. Every drop site makes the GLArea current first.
    fn drop(&mut self) {
        // Detach before freeing so a frame arriving on mpv's render thread
        // cannot reach a callback box that is about to go away.
        unsafe {
            libmpv2_sys::mpv_render_context_set_update_callback(
                self.ctx,
                None,
                std::ptr::null_mut(),
            );
            libmpv2_sys::mpv_render_context_free(self.ctx);
        }
        if let Some(cb) = self.update.take() {
            drop(unsafe { Box::from_raw(cb) });
        }
        // `_mpv` drops after this, which is the order mpv documents.
    }
}
