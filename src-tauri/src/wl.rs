//! Hand-written FFI over libwayland-client: the handful of requests the video
//! subsurface needs. No `wayland-client` crate and no generated code —
//! WAYLAND-SUBSURFACE-PLAN.md §4 Phase 0 weighed the crate against ~150
//! lines of FFI over a foreign display, and the spike settled on the FFI.
//!
//! Same discipline as `gl.rs`: `libwayland-client.so.0` is opened at runtime
//! and every entry point resolved by hand, so a build needs neither headers
//! nor the `.so` symlink, and a machine without the library (an X11 session
//! on a box without Wayland at all) gets `available() == false` rather than
//! a load failure.
//!
//! # Queues and threads
//!
//! Everything created here lives on its own `wl_event_queue`, so GDK's main
//! loop never dispatches events for objects it did not create and the video
//! thread never dispatches GDK's (plan §3, "Event queue"). Requests may be
//! issued from any thread — libwayland serialises marshalling on the
//! display's lock — so the GTK thread positions the subsurface while the
//! video thread commits frames to it. The one rule, enforced by the API
//! shape rather than by comment: surface *state* (scale, opaque region,
//! crop) is set from the thread that commits, because it is applied by that
//! thread's next commit and must match the buffer it carries.
//!
//! The `wl_*_interface` descriptors come from libwayland-client itself;
//! `wp_viewporter` is not in the core library, so its two interfaces are
//! spelled out here exactly as wayland-scanner would emit them.
#![allow(non_camel_case_types, dead_code)]

use std::ffi::{c_char, c_int, c_void, CStr};
use std::ptr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::OnceLock;

#[repr(C)]
pub struct wl_proxy {
    _private: [u8; 0],
}
#[repr(C)]
pub struct wl_display {
    _private: [u8; 0],
}
#[repr(C)]
pub struct wl_event_queue {
    _private: [u8; 0],
}

#[repr(C)]
pub struct wl_message {
    pub name: *const c_char,
    pub signature: *const c_char,
    pub types: *const *const wl_interface,
}

#[repr(C)]
pub struct wl_interface {
    pub name: *const c_char,
    pub version: c_int,
    pub method_count: c_int,
    pub methods: *const wl_message,
    pub event_count: c_int,
    pub events: *const wl_message,
}

// Immutable protocol descriptors; the raw pointers in them point at other
// immutable statics.
unsafe impl Sync for wl_message {}
unsafe impl Sync for wl_interface {}

const WL_MARSHAL_FLAG_DESTROY: u32 = 1;

// Request opcodes, from wayland-client-protocol.h and viewporter.xml.
const WL_DISPLAY_GET_REGISTRY: u32 = 1;
const WL_REGISTRY_BIND: u32 = 0;
const WL_COMPOSITOR_CREATE_SURFACE: u32 = 0;
const WL_COMPOSITOR_CREATE_REGION: u32 = 1;
const WL_SURFACE_DESTROY: u32 = 0;
const WL_SURFACE_ATTACH: u32 = 1;
const WL_SURFACE_SET_OPAQUE_REGION: u32 = 4;
const WL_SURFACE_SET_INPUT_REGION: u32 = 5;
const WL_SURFACE_COMMIT: u32 = 6;
const WL_SURFACE_SET_BUFFER_SCALE: u32 = 8;
const WL_REGION_DESTROY: u32 = 0;
const WL_REGION_ADD: u32 = 1;
const WL_SUBCOMPOSITOR_GET_SUBSURFACE: u32 = 1;
const WL_SUBSURFACE_DESTROY: u32 = 0;
const WL_SUBSURFACE_SET_POSITION: u32 = 1;
const WL_SUBSURFACE_PLACE_ABOVE: u32 = 2;
const WL_SUBSURFACE_SET_SYNC: u32 = 4;
const WL_SUBSURFACE_SET_DESYNC: u32 = 5;
const WP_VIEWPORTER_GET_VIEWPORT: u32 = 1;
const WP_VIEWPORT_DESTROY: u32 = 0;
const WP_VIEWPORT_SET_SOURCE: u32 = 1;
const WP_VIEWPORT_SET_DESTINATION: u32 = 2;

// ------------------------------------------------------------------- loader

static LIB: OnceLock<Option<libloading::Library>> = OnceLock::new();

fn lib() -> Option<&'static libloading::Library> {
    LIB.get_or_init(|| unsafe {
        match libloading::Library::new("libwayland-client.so.0") {
            Ok(l) => Some(l),
            Err(e) => {
                eprintln!("aquarium: libwayland-client.so.0 not loadable: {e}");
                None
            }
        }
    })
    .as_ref()
}

/// The address dlsym returned for `name`: the entry point of a function, or
/// the storage of a data symbol such as `wl_surface_interface`.
fn sym(name: &str) -> *mut c_void {
    let Some(lib) = lib() else {
        return ptr::null_mut();
    };
    let n = format!("{name}\0");
    unsafe {
        match lib.get::<*mut c_void>(n.as_bytes()) {
            // Two `into_raw`s: `Symbol` → the OS symbol → the raw address.
            // Dereferencing the `Symbol` instead would *read* a pointer out
            // of the function's first bytes.
            Ok(s) => s.into_raw().into_raw(),
            Err(_) => ptr::null_mut(),
        }
    }
}

type MarshalFlags = unsafe extern "C" fn(
    *mut wl_proxy,
    u32,
    *const wl_interface,
    u32,
    u32,
    ...
) -> *mut wl_proxy;

pub struct Api {
    marshal_flags: MarshalFlags,
    create_wrapper: unsafe extern "C" fn(*mut c_void) -> *mut c_void,
    wrapper_destroy: unsafe extern "C" fn(*mut c_void),
    set_queue: unsafe extern "C" fn(*mut wl_proxy, *mut wl_event_queue),
    get_version: unsafe extern "C" fn(*mut wl_proxy) -> u32,
    get_id: unsafe extern "C" fn(*mut wl_proxy) -> u32,
    add_listener: unsafe extern "C" fn(*mut wl_proxy, *const c_void, *mut c_void) -> c_int,
    proxy_destroy: unsafe extern "C" fn(*mut wl_proxy),
    create_queue: unsafe extern "C" fn(*mut wl_display) -> *mut wl_event_queue,
    queue_destroy: unsafe extern "C" fn(*mut wl_event_queue),
    roundtrip_queue: unsafe extern "C" fn(*mut wl_display, *mut wl_event_queue) -> c_int,
    dispatch_queue_pending: unsafe extern "C" fn(*mut wl_display, *mut wl_event_queue) -> c_int,
    flush: unsafe extern "C" fn(*mut wl_display) -> c_int,
    registry_iface: *const wl_interface,
    compositor_iface: *const wl_interface,
    subcompositor_iface: *const wl_interface,
    surface_iface: *const wl_interface,
    subsurface_iface: *const wl_interface,
    region_iface: *const wl_interface,
}

// Function pointers and pointers to immutable library data.
unsafe impl Sync for Api {}
unsafe impl Send for Api {}

static API: OnceLock<Option<Api>> = OnceLock::new();

/// `None` if the library or any symbol is missing — the caller falls back
/// to the GLArea path rather than dereferencing null.
pub fn api() -> Option<&'static Api> {
    macro_rules! load {
        ($name:literal as $t:ty) => {{
            let p = sym($name);
            if p.is_null() {
                eprintln!(concat!("aquarium: libwayland-client symbol missing: ", $name));
                return None;
            }
            unsafe { std::mem::transmute::<*mut c_void, $t>(p) }
        }};
    }
    API.get_or_init(|| {
        Some(Api {
            marshal_flags: load!("wl_proxy_marshal_flags" as MarshalFlags),
            create_wrapper: load!("wl_proxy_create_wrapper" as unsafe extern "C" fn(*mut c_void) -> *mut c_void),
            wrapper_destroy: load!("wl_proxy_wrapper_destroy" as unsafe extern "C" fn(*mut c_void)),
            set_queue: load!("wl_proxy_set_queue" as unsafe extern "C" fn(*mut wl_proxy, *mut wl_event_queue)),
            get_version: load!("wl_proxy_get_version" as unsafe extern "C" fn(*mut wl_proxy) -> u32),
            get_id: load!("wl_proxy_get_id" as unsafe extern "C" fn(*mut wl_proxy) -> u32),
            add_listener: load!("wl_proxy_add_listener" as unsafe extern "C" fn(*mut wl_proxy, *const c_void, *mut c_void) -> c_int),
            proxy_destroy: load!("wl_proxy_destroy" as unsafe extern "C" fn(*mut wl_proxy)),
            create_queue: load!("wl_display_create_queue" as unsafe extern "C" fn(*mut wl_display) -> *mut wl_event_queue),
            queue_destroy: load!("wl_event_queue_destroy" as unsafe extern "C" fn(*mut wl_event_queue)),
            roundtrip_queue: load!("wl_display_roundtrip_queue" as unsafe extern "C" fn(*mut wl_display, *mut wl_event_queue) -> c_int),
            dispatch_queue_pending: load!("wl_display_dispatch_queue_pending" as unsafe extern "C" fn(*mut wl_display, *mut wl_event_queue) -> c_int),
            flush: load!("wl_display_flush" as unsafe extern "C" fn(*mut wl_display) -> c_int),
            registry_iface: load!("wl_registry_interface" as *const wl_interface),
            compositor_iface: load!("wl_compositor_interface" as *const wl_interface),
            subcompositor_iface: load!("wl_subcompositor_interface" as *const wl_interface),
            surface_iface: load!("wl_surface_interface" as *const wl_interface),
            subsurface_iface: load!("wl_subsurface_interface" as *const wl_interface),
            region_iface: load!("wl_region_interface" as *const wl_interface),
        })
    })
    .as_ref()
}

/// True once libwayland-client loaded and every entry point resolved.
pub fn available() -> bool {
    api().is_some()
}

// ------------------------------------------------------------ wp_viewporter
//
// Only the request side matters: neither interface has events, and libwayland
// consults `types` on the sending side only for the `n` (new_id) argument.

macro_rules! cstr {
    ($s:literal) => {
        concat!($s, "\0").as_ptr() as *const c_char
    };
}

struct Types<const N: usize>([*const wl_interface; N]);
unsafe impl<const N: usize> Sync for Types<N> {}

static NULL_TYPES: Types<4> = Types([ptr::null(); 4]);
static GET_VIEWPORT_TYPES: Types<2> = Types([
    &WP_VIEWPORT_INTERFACE as *const wl_interface,
    // The `o` argument's interface is only checked when demarshalling events,
    // which this interface has none of.
    ptr::null(),
]);

static WP_VIEWPORTER_METHODS: [wl_message; 2] = [
    wl_message {
        name: cstr!("destroy"),
        signature: cstr!(""),
        types: NULL_TYPES.0.as_ptr(),
    },
    wl_message {
        name: cstr!("get_viewport"),
        signature: cstr!("no"),
        types: GET_VIEWPORT_TYPES.0.as_ptr(),
    },
];

static WP_VIEWPORTER_INTERFACE: wl_interface = wl_interface {
    name: cstr!("wp_viewporter"),
    version: 1,
    method_count: 2,
    methods: WP_VIEWPORTER_METHODS.as_ptr(),
    event_count: 0,
    events: ptr::null(),
};

static WP_VIEWPORT_METHODS: [wl_message; 3] = [
    wl_message {
        name: cstr!("destroy"),
        signature: cstr!(""),
        types: NULL_TYPES.0.as_ptr(),
    },
    wl_message {
        name: cstr!("set_source"),
        signature: cstr!("ffff"),
        types: NULL_TYPES.0.as_ptr(),
    },
    wl_message {
        name: cstr!("set_destination"),
        signature: cstr!("ii"),
        types: NULL_TYPES.0.as_ptr(),
    },
];

static WP_VIEWPORT_INTERFACE: wl_interface = wl_interface {
    name: cstr!("wp_viewport"),
    version: 1,
    method_count: 3,
    methods: WP_VIEWPORT_METHODS.as_ptr(),
    event_count: 0,
    events: ptr::null(),
};

/// `wl_fixed_t`: 24.8 fixed point.
fn fixed(v: i32) -> i32 {
    v << 8
}

// ------------------------------------------------------------------ registry

#[derive(Default, Debug)]
struct Found {
    compositor: Option<(u32, u32)>,
    subcompositor: Option<(u32, u32)>,
    viewporter: Option<(u32, u32)>,
}

#[repr(C)]
struct RegistryListener {
    global: unsafe extern "C" fn(*mut c_void, *mut wl_proxy, u32, *const c_char, u32),
    global_remove: unsafe extern "C" fn(*mut c_void, *mut wl_proxy, u32),
}

unsafe extern "C" fn on_global(
    data: *mut c_void,
    _registry: *mut wl_proxy,
    name: u32,
    interface: *const c_char,
    version: u32,
) {
    let found = unsafe { &mut *(data as *mut Found) };
    let iface = unsafe { CStr::from_ptr(interface) }.to_bytes();
    match iface {
        b"wl_compositor" => found.compositor = Some((name, version)),
        b"wl_subcompositor" => found.subcompositor = Some((name, version)),
        b"wp_viewporter" => found.viewporter = Some((name, version)),
        _ => {}
    }
}

unsafe extern "C" fn on_global_remove(_data: *mut c_void, _registry: *mut wl_proxy, _name: u32) {}

static REGISTRY_LISTENER: RegistryListener = RegistryListener {
    global: on_global,
    global_remove: on_global_remove,
};

/// The globals the video surface needs, bound from a registry of our own on
/// GDK's display, all on our own event queue. One per process, for the life
/// of the process.
pub struct Globals {
    api: &'static Api,
    pub display: *mut wl_display,
    pub queue: *mut wl_event_queue,
    display_wrapper: *mut wl_proxy,
    registry: *mut wl_proxy,
    /// The registry listener writes here; boxed so the address outlives the
    /// constructor (hotplugged globals keep arriving for as long as the
    /// registry proxy exists, and are dispatched by `dispatch()`).
    _found: Box<Found>,
    compositor: *mut wl_proxy,
    subcompositor: *mut wl_proxy,
    /// Null if the compositor does not offer `wp_viewporter`.
    viewporter: *mut wl_proxy,
}

unsafe impl Send for Globals {}
unsafe impl Sync for Globals {}

impl Globals {
    /// `display` is GDK's `wl_display` (`gdk_wayland_display_get_wl_display`).
    /// Does one round trip on the private queue; safe from any thread. (From
    /// the GTK thread the round trip reads the socket itself; from another
    /// it waits for GDK's poll loop to do the read — either way it returns.)
    pub fn new(display: *mut c_void) -> Result<Self, String> {
        let api = api().ok_or("libwayland-client is not available")?;
        let display = display as *mut wl_display;
        if display.is_null() {
            return Err("no wl_display".into());
        }
        unsafe {
            let queue = (api.create_queue)(display);
            if queue.is_null() {
                return Err("wl_display_create_queue failed".into());
            }
            // A wrapper is how a request on the display object itself is made
            // to create its new object on a chosen queue.
            let display_wrapper = (api.create_wrapper)(display as *mut c_void) as *mut wl_proxy;
            if display_wrapper.is_null() {
                (api.queue_destroy)(queue);
                return Err("wl_proxy_create_wrapper failed".into());
            }
            (api.set_queue)(display_wrapper, queue);
            let registry = (api.marshal_flags)(
                display_wrapper,
                WL_DISPLAY_GET_REGISTRY,
                api.registry_iface,
                (api.get_version)(display_wrapper),
                0,
                ptr::null_mut::<c_void>(),
            );
            if registry.is_null() {
                (api.wrapper_destroy)(display_wrapper as *mut c_void);
                (api.queue_destroy)(queue);
                return Err("wl_display.get_registry failed".into());
            }
            let mut found = Box::new(Found::default());
            (api.add_listener)(
                registry,
                &REGISTRY_LISTENER as *const RegistryListener as *const c_void,
                &mut *found as *mut Found as *mut c_void,
            );
            if (api.roundtrip_queue)(display, queue) < 0 {
                return Err("wl_display_roundtrip_queue failed".into());
            }

            let bind = |name: u32, iface: *const wl_interface, version: u32| -> *mut wl_proxy {
                (api.marshal_flags)(
                    registry,
                    WL_REGISTRY_BIND,
                    iface,
                    version,
                    0,
                    name,
                    (*iface).name,
                    version,
                    ptr::null_mut::<c_void>(),
                )
            };
            let Some((name, v)) = found.compositor else {
                return Err("compositor offers no wl_compositor".into());
            };
            // v3 for set_buffer_scale; ask for no more than is used.
            let compositor = bind(name, api.compositor_iface, v.min(4));
            let Some((name, v)) = found.subcompositor else {
                return Err("compositor offers no wl_subcompositor".into());
            };
            let subcompositor = bind(name, api.subcompositor_iface, v.min(1));
            let viewporter = match found.viewporter {
                Some((name, v)) => bind(name, &WP_VIEWPORTER_INTERFACE, v.min(1)),
                None => ptr::null_mut(),
            };
            if compositor.is_null() || subcompositor.is_null() {
                return Err("wl_registry.bind failed".into());
            }
            Ok(Self {
                api,
                display,
                queue,
                display_wrapper,
                registry,
                _found: found,
                compositor,
                subcompositor,
                viewporter,
            })
        }
    }

    pub fn has_viewporter(&self) -> bool {
        !self.viewporter.is_null()
    }

    /// Dispatch whatever has already been read for our queue. Never blocks,
    /// never reads the socket. The video thread calls this after each swap;
    /// events for our objects (surface enter/leave, preferred scale) are
    /// otherwise left to pile up.
    pub fn dispatch(&self) -> c_int {
        unsafe { (self.api.dispatch_queue_pending)(self.display, self.queue) }
    }

    /// Push queued requests to the compositor now rather than at the next
    /// commit. Needed after an `unmap` or `destroy`, which nothing else
    /// follows.
    pub fn flush(&self) {
        unsafe {
            (self.api.flush)(self.display);
        }
    }
}

// ---------------------------------------------------------------- subsurface

/// The video `wl_surface`, attached as a subsurface of a parent we do not own
/// (GDK's toplevel surface).
///
/// Created with an empty input region (the pointer falls through to the GTK
/// surface underneath, where the placeholder widget receives it), desync (our
/// commits present without waiting for GTK's), placed above the parent, and
/// unmapped until the first buffer is committed to it. Shared between the
/// GTK thread, which positions it, and the video thread, which sizes it and
/// commits to it through EGL.
pub struct Subsurface {
    api: &'static Api,
    pub surface: *mut wl_proxy,
    pub subsurface: *mut wl_proxy,
    /// The toplevel `wl_surface` this hangs off. Geometry is only meaningful
    /// against it: a `Resize` measured in another toplevel is not ours.
    pub parent: *mut wl_proxy,
    /// Null without `wp_viewporter`.
    viewport: *mut wl_proxy,
    compositor: *mut wl_proxy,
    destroyed: AtomicBool,
}

unsafe impl Send for Subsurface {}
unsafe impl Sync for Subsurface {}

impl Subsurface {
    /// `parent` is the toplevel's `wl_surface` from
    /// `gdk_wayland_window_get_wl_surface` — the *toplevel's*: on a child
    /// `GdkWindow` that call returns the same surface, and positions are in
    /// its coordinates either way.
    pub fn new(g: &Globals, parent: *mut c_void) -> Result<Self, String> {
        let api = g.api;
        let parent = parent as *mut wl_proxy;
        if parent.is_null() {
            return Err("parent wl_surface is null".into());
        }
        unsafe {
            let surface = (api.marshal_flags)(
                g.compositor,
                WL_COMPOSITOR_CREATE_SURFACE,
                api.surface_iface,
                (api.get_version)(g.compositor),
                0,
                ptr::null_mut::<c_void>(),
            );
            if surface.is_null() {
                return Err("wl_compositor.create_surface failed".into());
            }
            let subsurface = (api.marshal_flags)(
                g.subcompositor,
                WL_SUBCOMPOSITOR_GET_SUBSURFACE,
                api.subsurface_iface,
                (api.get_version)(g.subcompositor),
                0,
                ptr::null_mut::<c_void>(),
                surface,
                parent,
            );
            if subsurface.is_null() {
                (api.marshal_flags)(surface, WL_SURFACE_DESTROY, ptr::null(), 1, WL_MARSHAL_FLAG_DESTROY);
                return Err("wl_subcompositor.get_subsurface failed".into());
            }
            let viewport = if g.viewporter.is_null() {
                ptr::null_mut()
            } else {
                (api.marshal_flags)(
                    g.viewporter,
                    WP_VIEWPORTER_GET_VIEWPORT,
                    &WP_VIEWPORT_INTERFACE,
                    (api.get_version)(g.viewporter),
                    0,
                    ptr::null_mut::<c_void>(),
                    surface,
                )
            };
            let me = Self {
                api,
                surface,
                subsurface,
                parent,
                viewport,
                compositor: g.compositor,
                destroyed: AtomicBool::new(false),
            };
            me.set_input_region_empty();
            (api.marshal_flags)(
                subsurface,
                WL_SUBSURFACE_PLACE_ABOVE,
                ptr::null(),
                (api.get_version)(subsurface),
                0,
                parent,
            );
            me.set_desync();
            Ok(me)
        }
    }

    /// Protocol ids, for matching against `WAYLAND_DEBUG=1` output
    /// (`wl_surface#N`).
    pub fn ids(&self) -> (u32, u32) {
        unsafe { ((self.api.get_id)(self.surface), (self.api.get_id)(self.subsurface)) }
    }

    pub fn has_viewport(&self) -> bool {
        !self.viewport.is_null()
    }

    fn region(&self, rect: Option<(i32, i32, i32, i32)>) -> *mut wl_proxy {
        unsafe {
            let r = (self.api.marshal_flags)(
                self.compositor,
                WL_COMPOSITOR_CREATE_REGION,
                self.api.region_iface,
                (self.api.get_version)(self.compositor),
                0,
                ptr::null_mut::<c_void>(),
            );
            if let (false, Some((x, y, w, h))) = (r.is_null(), rect) {
                (self.api.marshal_flags)(r, WL_REGION_ADD, ptr::null(), 1, 0, x, y, w, h);
            }
            r
        }
    }

    fn destroy_region(&self, r: *mut wl_proxy) {
        if r.is_null() {
            return;
        }
        unsafe {
            (self.api.marshal_flags)(r, WL_REGION_DESTROY, ptr::null(), 1, WL_MARSHAL_FLAG_DESTROY);
        }
    }

    fn surface_request(&self, opcode: u32, region: *mut wl_proxy) {
        unsafe {
            (self.api.marshal_flags)(
                self.surface,
                opcode,
                ptr::null(),
                (self.api.get_version)(self.surface),
                0,
                region,
            );
        }
    }

    /// No pointer or keyboard focus ever: the one guarantee that keeps GDK
    /// from seeing events for a surface it did not create (plan §6). Set at
    /// construction; public so a caller can re-assert it.
    pub fn set_input_region_empty(&self) {
        let r = self.region(None);
        if r.is_null() {
            return;
        }
        self.surface_request(WL_SURFACE_SET_INPUT_REGION, r);
        self.destroy_region(r);
    }

    /// Everything a resize changes on the surface, in one place so it is
    /// applied by one commit: buffer scale, opaque region, and the
    /// `wp_viewport` crop that hides the bottom `full_h - vis_h` logical
    /// pixels (the fullscreen control strip) without mpv re-fitting.
    ///
    /// **Video-thread only**, immediately after resizing the EGL window and
    /// before the swap that carries the first buffer at the new size: these
    /// are double-buffered surface state applied by that commit, and a
    /// committed buffer whose size is not a multiple of `scale` is a protocol
    /// error, which the compositor answers by disconnecting the client.
    pub fn set_size(&self, w_css: i32, full_h_css: i32, vis_h_css: i32, scale: i32) {
        unsafe {
            (self.api.marshal_flags)(
                self.surface,
                WL_SURFACE_SET_BUFFER_SCALE,
                ptr::null(),
                (self.api.get_version)(self.surface),
                0,
                scale.max(1),
            );
        }
        let r = self.region(Some((0, 0, w_css, full_h_css)));
        if !r.is_null() {
            self.surface_request(WL_SURFACE_SET_OPAQUE_REGION, r);
            self.destroy_region(r);
        }
        if vis_h_css < full_h_css {
            self.set_crop(w_css, vis_h_css);
        } else {
            self.clear_crop();
        }
    }

    /// Parent-surface coordinates (logical). Takes effect at the *parent's*
    /// next commit, i.e. when GTK next paints its toplevel — the caller
    /// queues a redraw of the placeholder widget to make that happen.
    /// GTK-thread use is fine (and expected).
    pub fn set_position(&self, x: i32, y: i32) {
        unsafe {
            (self.api.marshal_flags)(
                self.subsurface,
                WL_SUBSURFACE_SET_POSITION,
                ptr::null(),
                (self.api.get_version)(self.subsurface),
                0,
                x,
                y,
            );
        }
    }

    fn subsurface_request(&self, opcode: u32) {
        unsafe {
            (self.api.marshal_flags)(
                self.subsurface,
                opcode,
                ptr::null(),
                (self.api.get_version)(self.subsurface),
                0,
            );
        }
    }

    /// Our commits are held until the parent commits. The switch to flip if a
    /// resize ever shows a frame of disagreement with GTK's surface.
    pub fn set_sync(&self) {
        self.subsurface_request(WL_SUBSURFACE_SET_SYNC);
    }

    /// Our commits present on their own (the default here).
    pub fn set_desync(&self) {
        self.subsurface_request(WL_SUBSURFACE_SET_DESYNC);
    }

    /// Crop to the top `w`×`h` logical pixels of the buffer. No-op without
    /// `wp_viewporter`; `has_viewport()` says whether the caller must fall
    /// back to blitting.
    fn set_crop(&self, w: i32, h: i32) {
        if self.viewport.is_null() {
            return;
        }
        unsafe {
            (self.api.marshal_flags)(
                self.viewport,
                WP_VIEWPORT_SET_SOURCE,
                ptr::null(),
                1,
                0,
                fixed(0),
                fixed(0),
                fixed(w),
                fixed(h),
            );
            (self.api.marshal_flags)(
                self.viewport,
                WP_VIEWPORT_SET_DESTINATION,
                ptr::null(),
                1,
                0,
                w,
                h,
            );
        }
    }

    fn clear_crop(&self) {
        if self.viewport.is_null() {
            return;
        }
        unsafe {
            (self.api.marshal_flags)(
                self.viewport,
                WP_VIEWPORT_SET_SOURCE,
                ptr::null(),
                1,
                0,
                fixed(-1),
                fixed(-1),
                fixed(-1),
                fixed(-1),
            );
            (self.api.marshal_flags)(
                self.viewport,
                WP_VIEWPORT_SET_DESTINATION,
                ptr::null(),
                1,
                0,
                -1,
                -1,
            );
        }
    }

    /// Detach the buffer and commit, which unmaps the subsurface (the video
    /// disappears; the placeholder shows through). The next swap maps it
    /// again. Video-thread only, like every commit. Follow with
    /// `Globals::flush`.
    pub fn unmap(&self) {
        unsafe {
            (self.api.marshal_flags)(
                self.surface,
                WL_SURFACE_ATTACH,
                ptr::null(),
                (self.api.get_version)(self.surface),
                0,
                ptr::null_mut::<c_void>(),
                0i32,
                0i32,
            );
        }
        self.commit();
    }

    pub fn commit(&self) {
        self.surface_request_noarg(WL_SURFACE_COMMIT);
    }

    fn surface_request_noarg(&self, opcode: u32) {
        unsafe {
            (self.api.marshal_flags)(
                self.surface,
                opcode,
                ptr::null(),
                (self.api.get_version)(self.surface),
                0,
            );
        }
    }

    /// Tear down the protocol objects. Idempotent. Must run after the EGL
    /// window on this surface is gone, from the thread that owned it.
    pub fn destroy(&self) {
        if self.destroyed.swap(true, Ordering::SeqCst) {
            return;
        }
        unsafe {
            if !self.viewport.is_null() {
                (self.api.marshal_flags)(
                    self.viewport,
                    WP_VIEWPORT_DESTROY,
                    ptr::null(),
                    1,
                    WL_MARSHAL_FLAG_DESTROY,
                );
            }
            (self.api.marshal_flags)(
                self.subsurface,
                WL_SUBSURFACE_DESTROY,
                ptr::null(),
                (self.api.get_version)(self.subsurface),
                WL_MARSHAL_FLAG_DESTROY,
            );
            (self.api.marshal_flags)(
                self.surface,
                WL_SURFACE_DESTROY,
                ptr::null(),
                (self.api.get_version)(self.surface),
                WL_MARSHAL_FLAG_DESTROY,
            );
        }
    }
}

impl Drop for Subsurface {
    fn drop(&mut self) {
        self.destroy();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Every entry point and interface descriptor resolves out of the
    /// installed libwayland-client. Needs no display.
    #[test]
    fn symbols_resolve() {
        let api = api().expect("libwayland-client loads");
        unsafe {
            let name = CStr::from_ptr((*api.surface_iface).name).to_str().unwrap();
            assert_eq!(name, "wl_surface");
            assert!((*api.surface_iface).version >= 3, "wl_surface v3 for set_buffer_scale");
            let name = CStr::from_ptr((*api.subsurface_iface).name).to_str().unwrap();
            assert_eq!(name, "wl_subsurface");
        }
    }

    #[test]
    fn viewporter_descriptors_are_well_formed() {
        unsafe {
            assert_eq!(CStr::from_ptr(WP_VIEWPORTER_INTERFACE.name).to_str().unwrap(), "wp_viewporter");
            let get_viewport = &*WP_VIEWPORTER_INTERFACE.methods.add(1);
            assert_eq!(CStr::from_ptr(get_viewport.signature).to_str().unwrap(), "no");
            assert_eq!(*get_viewport.types, &WP_VIEWPORT_INTERFACE as *const _);
            let set_source = &*WP_VIEWPORT_INTERFACE.methods.add(1);
            assert_eq!(CStr::from_ptr(set_source.signature).to_str().unwrap(), "ffff");
        }
        assert_eq!(fixed(1), 256);
        assert_eq!(fixed(-1), -256);
    }
}
