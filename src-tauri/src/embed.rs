// X11 child-window embedding for mpv. We create a child window of the Tauri
// toplevel and hand its id to mpv via --wid, so video renders inside the app.
// Works on X11 and on Wayland via XWayland (the app forces GDK_BACKEND=x11).
use raw_window_handle::{HasWindowHandle, RawWindowHandle};
use std::sync::Mutex;
use x11rb::connection::Connection;
use x11rb::protocol::xproto::{ConfigureWindowAux, ConnectionExt, CreateWindowAux, WindowClass};
use x11rb::rust_connection::RustConnection;

/// CSS height of the bottom player bar; the video surface stops above it.
pub const BAR_HEIGHT_CSS: f64 = 72.0;

pub struct Embed {
    conn: RustConnection,
    parent: u32,
    child: Mutex<Option<u32>>,
}

pub struct EmbedShared(pub Option<std::sync::Arc<Embed>>);

pub fn window_xid(window: &tauri::WebviewWindow) -> Result<u64, String> {
    let handle = window
        .window_handle()
        .map_err(|e| format!("no window handle: {e}"))?;
    match handle.as_raw() {
        RawWindowHandle::Xlib(h) => Ok(h.window as u64),
        RawWindowHandle::Xcb(h) => Ok(h.window.get() as u64),
        _ => Err("window is not X11 (Wayland backend?); falling back to external mpv".into()),
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

impl Embed {
    pub fn new(parent_xid: u64) -> Result<Self, String> {
        let (conn, _) = x11rb::connect(None).map_err(|e| format!("X11 connect: {e}"))?;
        Ok(Self {
            conn,
            parent: parent_xid as u32,
            child: Mutex::new(None),
        })
    }

    pub fn create_surface(&self, x: i16, y: i16, w: u16, h: u16) -> Result<u32, String> {
        self.destroy_surface();
        let id = self.conn.generate_id().map_err(|e| e.to_string())?;
        let aux = CreateWindowAux::new().background_pixel(0x0e0e14);
        self.conn
            .create_window(
                x11rb::COPY_DEPTH_FROM_PARENT,
                id,
                self.parent,
                x,
                y,
                w.max(1),
                h.max(1),
                0,
                WindowClass::INPUT_OUTPUT,
                x11rb::COPY_FROM_PARENT,
                &aux,
            )
            .map_err(|e| e.to_string())?;
        self.conn.map_window(id).map_err(|e| e.to_string())?;
        self.conn.flush().map_err(|e| e.to_string())?;
        *self.child.lock().unwrap() = Some(id);
        Ok(id)
    }

    pub fn resize(&self, x: i16, y: i16, w: u16, h: u16) {
        if let Some(id) = *self.child.lock().unwrap() {
            let aux = ConfigureWindowAux::new()
                .x(x as i32)
                .y(y as i32)
                .width(w.max(1) as u32)
                .height(h.max(1) as u32);
            let _ = self.conn.configure_window(id, &aux);
            let _ = self.conn.flush();
        }
    }

    pub fn destroy_surface(&self) {
        if let Some(id) = self.child.lock().unwrap().take() {
            let _ = self.conn.destroy_window(id);
            let _ = self.conn.flush();
        }
    }

    /// Destroy only if `id` is still the current surface. A finished playback
    /// session must not tear down the surface a newer session just created.
    pub fn destroy_surface_if(&self, id: u32) {
        let mut guard = self.child.lock().unwrap();
        if *guard == Some(id) {
            guard.take();
            let _ = self.conn.destroy_window(id);
            let _ = self.conn.flush();
        }
    }

    pub fn has_surface(&self) -> bool {
        self.child.lock().unwrap().is_some()
    }
}
