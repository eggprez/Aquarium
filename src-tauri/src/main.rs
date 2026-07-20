#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    // X11 (or XWayland) is required for embedding mpv into the window; the
    // AppImage GTK hook forces this too, this covers `tauri dev`.
    if std::env::var_os("GDK_BACKEND").is_none() {
        std::env::set_var("GDK_BACKEND", "x11");
    }
    fellyjin_lib::run()
}
