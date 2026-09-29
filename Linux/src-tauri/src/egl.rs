//! EGL over a `wl_egl_window`: the display, one context of our own, and one
//! window surface on the video `wl_surface`. What the video thread renders
//! into instead of the GLArea's renderbuffer (WAYLAND-SUBSURFACE-PLAN.md §3).
//!
//! Entry points are resolved out of `libEGL.so.1` and `libwayland-egl.so.1`
//! by hand, the `gl.rs` way, so a build needs no EGL headers or `.so`
//! symlinks. Not through libepoxy, even though it exports `epoxy_egl*`: those
//! thunks gate on the EGL version, which epoxy probes from the *current*
//! display — and the video thread has none until this module gives it one,
//! so `epoxy_eglGetPlatformDisplay` aborts with "No provider found" (Phase 0
//! finding). GL itself still goes through epoxy once a context is current.
//!
//! The `EGLDisplay` is the one GDK already has for this `wl_display` — Mesa
//! returns the same display for the same native handle, and initialising it
//! again is a refcount — which is why it is never terminated.
//!
//! # Ownership and teardown
//!
//! Everything here is created, used and dropped on the video thread. The
//! order that matters: mpv's render context (which holds GL objects) must be
//! freed with the context current *before* the `EglWindowSurface` and then
//! the `EglContext` drop — `Drop` here cannot enforce that, the video thread
//! does.
#![allow(dead_code)] // the GLArea fallback leaves some of this unused on any one machine

use std::ffi::{c_char, c_int, c_void, CStr};
use std::sync::OnceLock;

pub type EGLDisplay = *mut c_void;
pub type EGLConfig = *mut c_void;
pub type EGLContext = *mut c_void;
pub type EGLSurface = *mut c_void;

const EGL_PLATFORM_WAYLAND_KHR: u32 = 0x31D8;
const EGL_OPENGL_API: u32 = 0x30A2;
const EGL_NONE: i32 = 0x3038;
const EGL_SURFACE_TYPE: i32 = 0x3033;
const EGL_WINDOW_BIT: i32 = 0x0004;
const EGL_RENDERABLE_TYPE: i32 = 0x3040;
const EGL_OPENGL_BIT: i32 = 0x0008;
const EGL_RED_SIZE: i32 = 0x3024;
const EGL_GREEN_SIZE: i32 = 0x3023;
const EGL_BLUE_SIZE: i32 = 0x3022;
const EGL_ALPHA_SIZE: i32 = 0x3021;
const EGL_CONTEXT_MAJOR_VERSION: i32 = 0x3098;
const EGL_CONTEXT_MINOR_VERSION: i32 = 0x30FB;
const EGL_CONTEXT_OPENGL_PROFILE_MASK: i32 = 0x30FD;
const EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT: i32 = 0x0001;
const EGL_VENDOR: i32 = 0x3053;
const EGL_VERSION: i32 = 0x3054;

// ------------------------------------------------------------------- loaders

static EGL_LIB: OnceLock<Option<libloading::Library>> = OnceLock::new();
static WL_EGL_LIB: OnceLock<Option<libloading::Library>> = OnceLock::new();

fn load_lib(
    slot: &'static OnceLock<Option<libloading::Library>>,
    name: &str,
) -> Option<&'static libloading::Library> {
    slot.get_or_init(|| unsafe {
        match libloading::Library::new(name) {
            Ok(l) => Some(l),
            Err(e) => {
                eprintln!("aquarium: {name} not loadable: {e}");
                None
            }
        }
    })
    .as_ref()
}

/// The address dlsym returned: for a function, its entry point.
fn sym(lib: &libloading::Library, name: &str) -> *mut c_void {
    let n = format!("{name}\0");
    unsafe {
        match lib.get::<*mut c_void>(n.as_bytes()) {
            Ok(s) => s.into_raw().into_raw(),
            Err(_) => std::ptr::null_mut(),
        }
    }
}

macro_rules! api_struct {
    ($struct:ident, $static:ident, $getter:ident, $slot:ident, $libname:literal;
     $( $field:ident : $c_name:literal , fn($($a:ty),*) $(-> $r:ty)? ; )*) => {
        pub struct $struct { $( pub $field: unsafe extern "C" fn($($a),*) $(-> $r)? , )* }
        static $static: OnceLock<Option<$struct>> = OnceLock::new();
        /// `None` if the library or any entry point is missing.
        pub fn $getter() -> Option<&'static $struct> {
            $static.get_or_init(|| {
                let lib = load_lib(&$slot, $libname)?;
                $( let $field = sym(lib, $c_name);
                   if $field.is_null() {
                       eprintln!(concat!("aquarium: ", $libname, " entry point missing: ", $c_name));
                       return None;
                   } )*
                Some($struct {
                    $( $field: unsafe {
                        std::mem::transmute::<*mut c_void, unsafe extern "C" fn($($a),*) $(-> $r)?>($field)
                    }, )*
                })
            })
            .as_ref()
        }
    };
}

api_struct! {
    Api, API, api, EGL_LIB, "libEGL.so.1";
    get_platform_display:  "eglGetPlatformDisplay",  fn(u32, *mut c_void, *const isize) -> EGLDisplay;
    initialize:            "eglInitialize",          fn(EGLDisplay, *mut i32, *mut i32) -> u32;
    bind_api:              "eglBindAPI",             fn(u32) -> u32;
    choose_config:         "eglChooseConfig",        fn(EGLDisplay, *const i32, *mut EGLConfig, i32, *mut i32) -> u32;
    create_context:        "eglCreateContext",       fn(EGLDisplay, EGLConfig, EGLContext, *const i32) -> EGLContext;
    create_window_surface: "eglCreateWindowSurface", fn(EGLDisplay, EGLConfig, *mut c_void, *const i32) -> EGLSurface;
    make_current:          "eglMakeCurrent",         fn(EGLDisplay, EGLSurface, EGLSurface, EGLContext) -> u32;
    swap_buffers:          "eglSwapBuffers",         fn(EGLDisplay, EGLSurface) -> u32;
    swap_interval:         "eglSwapInterval",        fn(EGLDisplay, i32) -> u32;
    destroy_surface:       "eglDestroySurface",      fn(EGLDisplay, EGLSurface) -> u32;
    destroy_context:       "eglDestroyContext",      fn(EGLDisplay, EGLContext) -> u32;
    get_error:             "eglGetError",            fn() -> i32;
    query_string:          "eglQueryString",         fn(EGLDisplay, i32) -> *const c_char;
}

api_struct! {
    WlEglApi, WL_EGL_API, wl_egl_api, WL_EGL_LIB, "libwayland-egl.so.1";
    window_create:  "wl_egl_window_create",  fn(*mut c_void, c_int, c_int) -> *mut c_void;
    window_destroy: "wl_egl_window_destroy", fn(*mut c_void);
    window_resize:  "wl_egl_window_resize",  fn(*mut c_void, c_int, c_int, c_int, c_int);
}

/// True once both libraries loaded and every entry point resolved.
pub fn available() -> bool {
    api().is_some() && wl_egl_api().is_some()
}

fn err(api: &Api) -> String {
    format!("EGL error 0x{:x}", unsafe { (api.get_error)() })
}

// ------------------------------------------------------------------- display

/// The process's EGL display for GDK's `wl_display`, initialised.
pub struct EglDisplay {
    api: &'static Api,
    pub dpy: EGLDisplay,
}

impl EglDisplay {
    pub fn new(wl_display: *mut c_void) -> Result<Self, String> {
        let api = api().ok_or("libEGL is not available")?;
        if wl_display.is_null() {
            return Err("no wl_display".into());
        }
        unsafe {
            let dpy = (api.get_platform_display)(EGL_PLATFORM_WAYLAND_KHR, wl_display, std::ptr::null());
            if dpy.is_null() {
                return Err(format!("eglGetPlatformDisplay: {}", err(api)));
            }
            let (mut major, mut minor) = (0, 0);
            if (api.initialize)(dpy, &mut major, &mut minor) == 0 {
                return Err(format!("eglInitialize: {}", err(api)));
            }
            Ok(Self { api, dpy })
        }
    }

    /// Vendor and version, for the log line that says which stack the video
    /// thread ended up on.
    pub fn describe(&self) -> String {
        let s = |what: i32| unsafe {
            let p = (self.api.query_string)(self.dpy, what);
            if p.is_null() {
                "?".to_string()
            } else {
                CStr::from_ptr(p).to_string_lossy().into_owned()
            }
        };
        format!("{} {}", s(EGL_VENDOR), s(EGL_VERSION))
    }
}

// ------------------------------------------------------------------- context

/// A GL context of our own — *not* shared with GDK's: it has nothing GDK's
/// needs, and sharing would tie its lifetime to a GTK widget's.
pub struct EglContext {
    api: &'static Api,
    dpy: EGLDisplay,
    config: EGLConfig,
    ctx: EGLContext,
}

impl EglContext {
    pub fn new(display: &EglDisplay) -> Result<Self, String> {
        let api = display.api;
        let dpy = display.dpy;
        unsafe {
            if (api.bind_api)(EGL_OPENGL_API) == 0 {
                return Err(format!("eglBindAPI(OpenGL): {}", err(api)));
            }
            // Opaque: the subsurface declares a full opaque region, so an
            // alpha channel would only cost bandwidth.
            let attribs = [
                EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
                EGL_RENDERABLE_TYPE, EGL_OPENGL_BIT,
                EGL_RED_SIZE, 8,
                EGL_GREEN_SIZE, 8,
                EGL_BLUE_SIZE, 8,
                EGL_ALPHA_SIZE, 0,
                EGL_NONE,
            ];
            let mut config: EGLConfig = std::ptr::null_mut();
            let mut n = 0;
            if (api.choose_config)(dpy, attribs.as_ptr(), &mut config, 1, &mut n) == 0 || n == 0 {
                return Err(format!("eglChooseConfig: {}", err(api)));
            }
            // Same profile GDK asks for, i.e. what mpv has been getting.
            let core = [
                EGL_CONTEXT_MAJOR_VERSION, 3,
                EGL_CONTEXT_MINOR_VERSION, 3,
                EGL_CONTEXT_OPENGL_PROFILE_MASK, EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT,
                EGL_NONE,
            ];
            let mut ctx = (api.create_context)(dpy, config, std::ptr::null_mut(), core.as_ptr());
            if ctx.is_null() {
                let legacy = [EGL_NONE];
                ctx = (api.create_context)(dpy, config, std::ptr::null_mut(), legacy.as_ptr());
            }
            if ctx.is_null() {
                return Err(format!("eglCreateContext: {}", err(api)));
            }
            Ok(Self { api, dpy, config, ctx })
        }
    }

    /// Make this context current on the calling thread, drawing to `surface`.
    pub fn make_current(&self, surface: &EglWindowSurface) -> bool {
        unsafe { (self.api.make_current)(self.dpy, surface.surface, surface.surface, self.ctx) != 0 }
    }

    /// Release whatever is current on the calling thread.
    pub fn release(&self) {
        unsafe {
            (self.api.make_current)(
                self.dpy,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
            );
        }
    }

    /// Applies to the surface current on this thread. The video thread sets
    /// 0: mpv paces frames itself, and a swap that waited for the
    /// compositor's frame callback would stall forever on an occluded
    /// subsurface (plan §3, "Swap interval 0").
    pub fn set_swap_interval(&self, interval: i32) -> bool {
        unsafe { (self.api.swap_interval)(self.dpy, interval) != 0 }
    }

    /// Commit the back buffer to the surface's `wl_surface`. With interval 0
    /// this returns as soon as the buffer is handed over.
    pub fn swap(&self, surface: &EglWindowSurface) -> bool {
        unsafe { (self.api.swap_buffers)(self.dpy, surface.surface) != 0 }
    }
}

impl Drop for EglContext {
    fn drop(&mut self) {
        unsafe {
            (self.api.destroy_context)(self.dpy, self.ctx);
        }
        // No eglTerminate: the display is GDK's too.
    }
}

// ------------------------------------------------------------ window surface

/// A `wl_egl_window` on the video `wl_surface`, and the `EGLSurface` on it.
/// Sizes are buffer pixels (logical × scale).
pub struct EglWindowSurface {
    api: &'static Api,
    wl_egl: &'static WlEglApi,
    dpy: EGLDisplay,
    egl_window: *mut c_void,
    pub surface: EGLSurface,
    pub w: i32,
    pub h: i32,
}

impl EglWindowSurface {
    pub fn new(ctx: &EglContext, wl_surface: *mut c_void, w: i32, h: i32) -> Result<Self, String> {
        let wl_egl = wl_egl_api().ok_or("libwayland-egl is not available")?;
        if wl_surface.is_null() {
            return Err("no wl_surface".into());
        }
        let (w, h) = (w.max(1), h.max(1));
        unsafe {
            let egl_window = (wl_egl.window_create)(wl_surface, w, h);
            if egl_window.is_null() {
                return Err("wl_egl_window_create failed".into());
            }
            let surface = (ctx.api.create_window_surface)(
                ctx.dpy,
                ctx.config,
                egl_window,
                std::ptr::null(),
            );
            if surface.is_null() {
                let e = err(ctx.api);
                (wl_egl.window_destroy)(egl_window);
                return Err(format!("eglCreateWindowSurface: {e}"));
            }
            Ok(Self {
                api: ctx.api,
                wl_egl,
                dpy: ctx.dpy,
                egl_window,
                surface,
                w,
                h,
            })
        }
    }

    /// `wl_egl_window_resize`. Not what the video thread uses: Mesa applies
    /// it only once the already-allocated back buffer has been swapped out,
    /// so a resize between a surface's creation and its first swap, or after
    /// GL activity without a swap, is silently lost and the next swap
    /// attaches a buffer at the old size (see `video_thread::State::win_stale`).
    /// The thread recreates the surface instead. Kept for a caller that can
    /// guarantee a swap since the last validation.
    pub fn resize(&mut self, w: i32, h: i32) {
        let (w, h) = (w.max(1), h.max(1));
        if (w, h) == (self.w, self.h) {
            return;
        }
        unsafe { (self.wl_egl.window_resize)(self.egl_window, w, h, 0, 0) };
        self.w = w;
        self.h = h;
    }
}

impl Drop for EglWindowSurface {
    /// Release the context first if this surface is current on the thread;
    /// EGL defers destruction of a current surface, which would hold the
    /// `wl_egl_window` past the `wl_surface` it sits on.
    fn drop(&mut self) {
        unsafe {
            (self.api.destroy_surface)(self.dpy, self.surface);
            (self.wl_egl.window_destroy)(self.egl_window);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Both libraries load and every entry point resolves. Needs no display.
    #[test]
    fn symbols_resolve() {
        assert!(api().is_some(), "libEGL.so.1");
        assert!(wl_egl_api().is_some(), "libwayland-egl.so.1");
        assert!(available());
    }
}
