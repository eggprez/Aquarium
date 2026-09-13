//! Minimal GL entry-point loader.
//!
//! The `epoxy` crate is unusable: it depends on gl_generator 0.9, which pins a
//! yanked xml-rs, so `cargo fetch` refuses to resolve it. Loading the handful
//! of calls we need by hand is ~60 lines and no dependency.
//!
//! libepoxy exports every GL and EGL entry point as a *data* symbol named
//! `epoxy_<name>` holding a dispatch pointer (the plain `glFoo` names are
//! preprocessor macros in epoxy.h, so `dlsym(lib, "glClear")` returns null).
//! Dereferencing the pointer gives a callable thunk that resolves itself
//! against whatever context is current on first call — exactly what mpv wants
//! from `get_proc_address`.
//!
//! Getting either of those wrong segfaults inside `epoxy_glGetString` with a
//! context current, which reads like a GTK bug and is not one.
use std::ffi::c_void;
use std::sync::OnceLock;

static LIB: OnceLock<Option<libloading::Library>> = OnceLock::new();

fn lib() -> Option<&'static libloading::Library> {
    LIB.get_or_init(|| unsafe {
        match libloading::Library::new("libepoxy.so.0") {
            Ok(l) => Some(l),
            Err(e) => {
                eprintln!("fellyjin: libepoxy.so.0 not loadable: {e}");
                None
            }
        }
    })
    .as_ref()
}

pub fn proc_addr(name: &str) -> *mut c_void {
    let Some(lib) = lib() else { return std::ptr::null_mut() };
    let sym = format!("epoxy_{name}\0");
    unsafe {
        // libloading's `Symbol` deref hands back the address dlsym returned, so
        // for a *data* symbol that is the address of the pointer variable, not
        // the entry point it holds. One more indirection gets the thunk.
        match lib.get::<*mut c_void>(sym.as_bytes()) {
            Ok(s) => {
                let slot = *s as *const *mut c_void;
                if slot.is_null() {
                    std::ptr::null_mut()
                } else {
                    *slot
                }
            }
            Err(_) => std::ptr::null_mut(),
        }
    }
}

/// True once every entry point below resolved. Checked before the first GL
/// call so a machine without libepoxy reports a message instead of crashing.
pub fn available() -> bool {
    api().is_some()
}

pub const DRAW_FRAMEBUFFER_BINDING: u32 = 0x8CA6;
pub const FRAMEBUFFER: u32 = 0x8D40;
pub const READ_FRAMEBUFFER: u32 = 0x8CA8;
pub const DRAW_FRAMEBUFFER: u32 = 0x8CA9;
pub const FRAMEBUFFER_COMPLETE: u32 = 0x8CD5;
pub const COLOR_ATTACHMENT0: u32 = 0x8CE0;
pub const TEXTURE_2D: u32 = 0x0DE1;
pub const RGBA8: u32 = 0x8058;
pub const RGBA: u32 = 0x1908;
pub const UNSIGNED_BYTE: u32 = 0x1401;
pub const NEAREST: i32 = 0x2600;
pub const TEXTURE_MIN_FILTER: u32 = 0x2801;
pub const TEXTURE_MAG_FILTER: u32 = 0x2800;
pub const COLOR_BUFFER_BIT: u32 = 0x4000;

macro_rules! gl_api {
    ($( $field:ident : $c_name:literal , fn($($a:ty),*) $(-> $r:ty)? ; )*) => {
        pub struct Api { $( pub $field: unsafe extern "C" fn($($a),*) $(-> $r)? , )* }
        static API: OnceLock<Option<Api>> = OnceLock::new();
        /// `None` if any entry point is missing, which means no usable GL at
        /// all — the caller falls back rather than dereferencing null.
        pub fn api() -> Option<&'static Api> {
            API.get_or_init(|| {
                $( let $field = proc_addr($c_name);
                   if $field.is_null() {
                       eprintln!(concat!("fellyjin: GL entry point missing: ", $c_name));
                       return None;
                   } )*
                Some(Api {
                    $( $field: unsafe {
                        std::mem::transmute::<*mut c_void, unsafe extern "C" fn($($a),*) $(-> $r)?>($field)
                    }, )*
                })
            })
            .as_ref()
        }
    };
}

gl_api! {
    get_integerv:      "glGetIntegerv",           fn(u32, *mut i32);
    gen_framebuffers:  "glGenFramebuffers",       fn(i32, *mut u32);
    del_framebuffers:  "glDeleteFramebuffers",    fn(i32, *const u32);
    bind_framebuffer:  "glBindFramebuffer",       fn(u32, u32);
    fb_texture_2d:     "glFramebufferTexture2D",  fn(u32, u32, u32, u32, i32);
    check_fb_status:   "glCheckFramebufferStatus",fn(u32) -> u32;
    blit_framebuffer:  "glBlitFramebuffer",       fn(i32,i32,i32,i32,i32,i32,i32,i32,u32,u32);
    gen_textures:      "glGenTextures",           fn(i32, *mut u32);
    del_textures:      "glDeleteTextures",        fn(i32, *const u32);
    bind_texture:      "glBindTexture",           fn(u32, u32);
    tex_image_2d:      "glTexImage2D",            fn(u32,i32,i32,i32,i32,i32,i32,u32,*const c_void);
    tex_parameteri:    "glTexParameteri",         fn(u32, u32, i32);
    viewport:          "glViewport",              fn(i32,i32,i32,i32);
    clear_color:       "glClearColor",            fn(f32,f32,f32,f32);
    clear:             "glClear",                 fn(u32);
    get_string:        "glGetString",             fn(u32) -> *const u8;
    get_error:         "glGetError",              fn() -> u32;
}

/// GTK leaves an error pending on the first frame; mpv reads it back as its
/// own and warns (`after creating texture: OpenGL error
/// INVALID_FRAMEBUFFER_OPERATION`). Drain it so mpv's diagnostics mean
/// something.
pub fn drain_errors(g: &Api) {
    for _ in 0..8 {
        if unsafe { (g.get_error)() } == 0 {
            return;
        }
    }
}
