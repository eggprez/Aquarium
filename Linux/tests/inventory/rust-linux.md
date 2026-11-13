| Function | Source | Test file | Kind | Status |
|---|---|---|---|---|
| resolve_mpv_config_dir | src-tauri/src/mpv.rs:40 | src-tauri/src/mpv.rs (mod tests) | unit | tested via config_dir_from (thin env wrapper) |
| config_dir_from | src-tauri/src/mpv.rs:46 | src-tauri/src/mpv.rs (mod tests) | unit | CI only (not run on macOS); compiled and run on macOS in scratch against the real source |
| remove_logs | src-tauri/src/mpv.rs:66 | src-tauri/src/mpv.rs (mod tests) | unit | CI only (not run on macOS); compiled and run on macOS in scratch against the real source |
| mpv_log_path | src-tauri/src/mpv.rs:77 | src-tauri/src/mpv.rs (mod tests) | unit | CI only (not run on macOS); compiled and run on macOS in scratch against the real source (off-by-default branch) |
| new_log_in | src-tauri/src/mpv.rs:88 | src-tauri/src/mpv.rs (mod tests) | unit | CI only (not run on macOS); compiled and run on macOS in scratch against the real source |
| runtime_version | src-tauri/src/mpv.rs:127 | src-tauri/src/mpv.rs (mod tests) | unit | CI only (not run on macOS); compiled on macOS in scratch, needs real libmpv to pass |
| audio_devices | src-tauri/src/mpv.rs:149 | src-tauri/src/mpv.rs (mod tests) | unit | CI only (not run on macOS); compiled on macOS in scratch, needs real libmpv to pass |
| devices_from | src-tauri/src/mpv.rs:178 | src-tauri/src/mpv.rs (mod tests) | unit | CI only (not run on macOS); compiled and run on macOS in scratch against the real source |
| check | src-tauri/src/mpv.rs:594 | src-tauri/src/mpv.rs (mod tests) | unit | CI only (not run on macOS); compiled and run on macOS in scratch against the real source (stub error string on macOS) |
| empty_node | src-tauri/src/mpv.rs:663 | src-tauri/src/mpv.rs (mod tests) | unit | CI only (not run on macOS); compiled and run on macOS in scratch against the real source |
| cstr | src-tauri/src/mpv.rs:670 | src-tauri/src/mpv.rs (mod tests) | unit | CI only (not run on macOS); compiled and run on macOS in scratch against the real source |
| node_to_json | src-tauri/src/mpv.rs:680 | src-tauri/src/mpv.rs (mod tests) | unit | CI only (not run on macOS); compiled and run on macOS in scratch against the real source |
| Session::start | src-tauri/src/mpv.rs:244 | src-tauri/src/mpv.rs (mod tests) | unit | CI only (not run on macOS); compiled on macOS in scratch, needs real libmpv to pass |
| Session::handle | src-tauri/src/mpv.rs:419 | src-tauri/src/mpv.rs (mod tests) | unit | CI only (not run on macOS); compiled on macOS in scratch, needs real libmpv to pass |
| Session::ensure_ui | src-tauri/src/mpv.rs:432 | src-tauri/src/mpv.rs (mod tests) | unit | CI only (not run on macOS); compiled on macOS in scratch, needs real libmpv to pass (uosc branch skipped when no bundled config) |
| Session::command (set_property -> mpv_set_property invariant) | src-tauri/src/mpv.rs:458 | src-tauri/src/mpv.rs (mod tests) | unit | CI only (not run on macOS); compiled on macOS in scratch, needs real libmpv to pass |
| Session::get_string | src-tauri/src/mpv.rs:565 | src-tauri/src/mpv.rs (mod tests) | unit | CI only (not run on macOS); compiled on macOS in scratch, needs real libmpv to pass |
| Session::run_node | src-tauri/src/mpv.rs:581 | src-tauri/src/mpv.rs (mod tests) | unit | CI only (not run on macOS); compiled on macOS in scratch, needs real libmpv to pass |
| pump_events | src-tauri/src/mpv.rs:610 | src-tauri/src/mpv.rs (mod tests) | unit | CI only (not run on macOS); compiled on macOS in scratch, needs real libmpv to pass; via Session tests |
| Arena::cstring | src-tauri/src/mpv.rs:741 | src-tauri/src/mpv.rs (mod tests) | unit | CI only (not run on macOS); compiled and run on macOS in scratch against the real source |
| Arena::node | src-tauri/src/mpv.rs:754 | src-tauri/src/mpv.rs (mod tests) | unit | CI only (not run on macOS); compiled and run on macOS in scratch against the real source |
| Arena::list | src-tauri/src/mpv.rs:807 | src-tauri/src/mpv.rs (mod tests) | unit | CI only (not run on macOS); compiled and run on macOS in scratch against the real source |
| Options (struct) | src-tauri/src/mpv.rs:206 | src-tauri/src/mpv.rs (mod tests) | unit | CI only (not run on macOS); compiled on macOS in scratch, needs real libmpv to pass; via Session::start |
| AudioPlayer::default | src-tauri/src/audio.rs:142 | src-tauri/src/audio.rs (mod tests) | unit | CI only (not run on macOS); compiled and run on macOS in scratch against the real source |
| AudioPlayer::new | src-tauri/src/audio.rs:148 | src-tauri/src/audio.rs (mod tests) | unit | CI only (not run on macOS); compiled and run on macOS in scratch against the real source |
| AudioPlayer::is_active | src-tauri/src/audio.rs:163 | src-tauri/src/audio.rs (mod tests) | unit | CI only (not run on macOS); compiled and run on macOS in scratch against the real source |
| AudioPlayer::status | src-tauri/src/audio.rs:167 | src-tauri/src/audio.rs (mod tests) | unit | CI only (not run on macOS); compiled and run on macOS in scratch against the real source |
| AudioPlayer::current | src-tauri/src/audio.rs:171 | src-tauri/src/audio.rs (mod tests) | unit | CI only (not run on macOS); compiled and run on macOS in scratch against the real source |
| AudioPlayer::queue | src-tauri/src/audio.rs:175 | src-tauri/src/audio.rs (mod tests) | unit | CI only (not run on macOS); compiled and run on macOS in scratch against the real source |
| AudioPlayer::can_next | src-tauri/src/audio.rs:179 | src-tauri/src/audio.rs (mod tests) | unit | CI only (not run on macOS); compiled and run on macOS in scratch against the real source |
| AudioPlayer::can_prev | src-tauri/src/audio.rs:183 | src-tauri/src/audio.rs (mod tests) | unit | CI only (not run on macOS); compiled and run on macOS in scratch against the real source |
| AudioPlayer::set_for_tests | src-tauri/src/audio.rs:189 | src-tauri/src/audio.rs (mod tests) | unit | test hook (cfg(test)) |
| AudioPlayer::set_queue | src-tauri/src/audio.rs:194 | src-tauri/src/audio.rs (mod tests) | unit | CI only (not run on macOS); compiled and run on macOS in scratch against the real source |
| AudioPlayer::send | src-tauri/src/audio.rs:201 | src-tauri/src/audio.rs (mod tests) | unit | CI only (not run on macOS); compiled and run on macOS in scratch against the real source (no-core branch) |
| AudioPlayer::play | src-tauri/src/audio.rs:212 | — | needs real Linux | untested: takes AppHandle<Wry> and a live core; manual checklist (music playback) |
| AudioPlayer::set_next | src-tauri/src/audio.rs:307 | src-tauri/src/audio.rs (mod tests) | unit | CI only (not run on macOS); compiled and run on macOS in scratch against the real source (no-core branch; with-core needs mpv) |
| AudioPlayer::stop | src-tauri/src/audio.rs:335 | — | needs real Linux | untested: takes &AppHandle<Wry>; manual checklist |
| AudioPlayer::stop_sync | src-tauri/src/audio.rs:359 | src-tauri/src/audio.rs (mod tests) | unit | CI only (not run on macOS); compiled and run on macOS in scratch against the real source (report path; no core) |
| AudioPlayer::unique | src-tauri/src/audio.rs:382 | src-tauri/src/audio.rs (mod tests) | unit | CI only (not run on macOS); compiled and run on macOS in scratch against the real source |
| AudioPlayer::start_core | src-tauri/src/audio.rs:391 | — | needs real Linux | untested: needs AppHandle<Wry> and libmpv audio output; manual checklist |
| spawn_supervisor | src-tauri/src/audio.rs:469 | — | needs real Linux | untested: needs AppHandle<Wry> and a live core (gapless end-file handling); manual checklist |
| apply_property | src-tauri/src/audio.rs:596 | src-tauri/src/audio.rs (mod tests) | unit | CI only (not run on macOS); compiled and run on macOS in scratch against the real source |
| status_payload | src-tauri/src/audio.rs:634 | src-tauri/src/audio.rs (mod tests) | unit | CI only (not run on macOS); compiled and run on macOS in scratch against the real source |
| emit_status | src-tauri/src/audio.rs:638 | src-tauri/src/audio.rs (mod tests) | unit | CI only (not run on macOS); compiled and run on macOS in scratch against the real source |
| report_body | src-tauri/src/audio.rs:646 | src-tauri/src/audio.rs (mod tests) | unit | CI only (not run on macOS); compiled and run on macOS in scratch against the real source |
| creds | src-tauri/src/audio.rs:657 | src-tauri/src/audio.rs (mod tests) | unit | CI only (not run on macOS); compiled and run on macOS in scratch against the real source |
| report_start | src-tauri/src/audio.rs:665 | src-tauri/src/audio.rs (mod tests) | unit | CI only (not run on macOS); compiled and run on macOS in scratch against the real source |
| report_progress | src-tauri/src/audio.rs:674 | src-tauri/src/audio.rs (mod tests) | unit | CI only (not run on macOS); compiled and run on macOS in scratch against the real source |
| report_stopped | src-tauri/src/audio.rs:687 | src-tauri/src/audio.rs (mod tests) | unit | CI only (not run on macOS); compiled and run on macOS in scratch against the real source |
| PlayRequest (deserialize) | src-tauri/src/audio.rs:61 | src-tauri/src/audio.rs (mod tests) | unit | CI only (not run on macOS); compiled and run on macOS in scratch against the real source (serde defaults) |
| power_changed | src-tauri/src/player.rs:159 | — | needs real Linux | untested: takes AppHandle<Wry>; sync_battery_profile needs a live core; manual checklist |
| check_play_target | src-tauri/src/player.rs:180 | src-tauri/src/player.rs (mod tests) | unit | CI only (not run on macOS); compiled and run on macOS in scratch against the real source |
| play_target_allowed | src-tauri/src/player.rs:188 | src-tauri/src/player.rs (mod tests) | unit | CI only (not run on macOS); compiled and run on macOS in scratch against the real source (existing play_target_tests) |
| http_auth_header | src-tauri/src/player.rs:210 | src-tauri/src/player.rs (mod tests) | unit | CI only (not run on macOS); compiled and run on macOS in scratch against the real source |
| Player::new | src-tauri/src/player.rs:221 | src-tauri/src/player.rs (mod tests) | unit | CI only (not run on macOS); compiled and run on macOS in scratch against the real source |
| Player::is_active | src-tauri/src/player.rs:260 | src-tauri/src/player.rs (mod tests) | unit | CI only (not run on macOS); compiled and run on macOS in scratch against the real source |
| Player::next_available | src-tauri/src/player.rs:264 | src-tauri/src/player.rs (mod tests) | unit | CI only (not run on macOS); compiled and run on macOS in scratch against the real source |
| Player::set_next_available | src-tauri/src/player.rs:268 | src-tauri/src/player.rs (mod tests) | unit | CI only (not run on macOS); compiled and run on macOS in scratch against the real source |
| Player::status | src-tauri/src/player.rs:272 | src-tauri/src/player.rs (mod tests) | unit | CI only (not run on macOS); compiled and run on macOS in scratch against the real source |
| Player::set_status_for_tests | src-tauri/src/player.rs:278 | src-tauri/src/player.rs (mod tests) | unit | test hook (cfg(test)) |
| Player::properties | src-tauri/src/player.rs:284 | src-tauri/src/player.rs (mod tests) | unit | CI only (not run on macOS); compiled and run on macOS in scratch against the real source (no-session branch) |
| Player::send | src-tauri/src/player.rs:297 | src-tauri/src/player.rs (mod tests) | unit | CI only (not run on macOS); compiled and run on macOS in scratch against the real source (no-session branch) |
| Player::sync_idle_inhibit | src-tauri/src/player.rs:315 | src-tauri/src/player.rs (mod tests) | unit | CI only (not run on macOS); compiled and run on macOS in scratch against the real source (inhibitor fails on the dead test bus) |
| Player::stop | src-tauri/src/player.rs:337 | src-tauri/src/player.rs (mod tests) | unit | CI only (not run on macOS); compiled and run on macOS in scratch against the real source (no session) |
| Player::stop_session | src-tauri/src/player.rs:344 | src-tauri/src/player.rs (mod tests) | unit | tested via Player::stop |
| Player::stop_sync | src-tauri/src/player.rs:377 | src-tauri/src/player.rs (mod tests) | unit | CI only (not run on macOS); compiled and run on macOS in scratch against the real source (no session) |
| Player::sync_battery_profile | src-tauri/src/player.rs:240 | — | needs real Linux | untested: needs a live core and power state; manual checklist |
| Player::play | src-tauri/src/player.rs:387 | — | needs real Linux | untested: needs the video surface, a window and libmpv; manual checklist |
| wake_ui_for | src-tauri/src/player.rs:779 | — | needs real Linux | untested: needs a core with the bundled uosc and AppHandle<Wry>; manual checklist |
| track_position | src-tauri/src/player.rs:800 | src-tauri/src/player.rs (mod tests) | unit | CI only (not run on macOS); compiled and run on macOS in scratch against the real source |
| apply_event | src-tauri/src/player.rs:822 | src-tauri/src/player.rs (mod tests) | unit | CI only (not run on macOS); compiled and run on macOS in scratch against the real source |
| emit_status | src-tauri/src/player.rs:980 | src-tauri/src/player.rs (mod tests) | unit | CI only (not run on macOS); compiled and run on macOS in scratch against the real source |
| status_payload | src-tauri/src/player.rs:991 | src-tauri/src/player.rs (mod tests) | unit | CI only (not run on macOS); compiled and run on macOS in scratch against the real source |
| report_body | src-tauri/src/player.rs:1016 | src-tauri/src/player.rs (mod tests) | unit | CI only (not run on macOS); compiled and run on macOS in scratch against the real source |
| server_creds | src-tauri/src/player.rs:1036 | src-tauri/src/player.rs (mod tests) | unit | CI only (not run on macOS); compiled and run on macOS in scratch against the real source |
| report_start | src-tauri/src/player.rs:1046 | src-tauri/src/player.rs (mod tests) | unit | CI only (not run on macOS); compiled and run on macOS in scratch against the real source |
| report_progress | src-tauri/src/player.rs:1057 | src-tauri/src/player.rs (mod tests) | unit | CI only (not run on macOS); compiled and run on macOS in scratch against the real source |
| report_stopped | src-tauri/src/player.rs:1078 | src-tauri/src/player.rs (mod tests) | unit | CI only (not run on macOS); compiled and run on macOS in scratch against the real source |
| PlayRequest / PlayContext (deserialize) | src-tauri/src/player.rs:90 | src-tauri/src/player.rs (mod tests) | unit | CI only (not run on macOS); compiled and run on macOS in scratch against the real source (serde defaults) |
| debug_enabled | src-tauri/src/surface.rs:89 | src-tauri/src/surface.rs (mod tests) | unit | CI only (not run on macOS) |
| dump_tree | src-tauri/src/surface.rs:99 | — | needs real Linux | untested: walks a realized GTK widget tree |
| geometry | src-tauri/src/surface.rs:123 | src-tauri/src/surface.rs (mod tests) | unit | CI only (not run on macOS); copy run on macOS in scratch |
| Offscreen::ensure | src-tauri/src/surface.rs:156 | — | needs real Linux | untested: GL framebuffer objects need a GL context |
| Offscreen::destroy | src-tauri/src/surface.rs:193 | — | needs real Linux | untested: needs a GL context |
| Video::release_gl | src-tauri/src/surface.rs:227 | — | needs real Linux | untested: needs a GL context |
| Layout::want | src-tauri/src/surface.rs:266 | src-tauri/src/surface.rs (mod tests) | unit | CI only (not run on macOS); copy run on macOS in scratch |
| Layout::apply | src-tauri/src/surface.rs:273 | — | needs real Linux | untested: queues a GTK size request (arithmetic tested via Layout::want) |
| with_ui | src-tauri/src/surface.rs:337 | — | needs real Linux | untested: runs on the GTK main thread via AppHandle |
| Ui::release_gl | src-tauri/src/surface.rs:351 | — | needs real Linux | untested: needs a GL context |
| Ui::ensure_render_ctx | src-tauri/src/surface.rs:369 | — | needs real Linux | untested: needs a GLArea |
| Ui::wl | src-tauri/src/surface.rs:380 | — | needs real Linux | untested: needs the Wayland backend |
| Ui::wl_ensure_subsurface | src-tauri/src/surface.rs:392 | — | needs real Linux | untested: needs a compositor |
| Ui::wl_push_geometry | src-tauri/src/surface.rs:436 | — | needs real Linux | untested: needs GTK widgets (arithmetic tested via intended_rect) |
| toplevel_wl_surface | src-tauri/src/surface.rs:462 | — | needs real Linux | untested: needs a Wayland toplevel |
| wl_geometry_changed | src-tauri/src/surface.rs:484 | — | needs real Linux | untested: needs a compositor and GTK widgets |
| Geom::trims | src-tauri/src/surface.rs:561 | src-tauri/src/surface.rs (mod tests) | unit | CI only (not run on macOS); copy run on macOS in scratch |
| Geom::hides_cursor | src-tauri/src/surface.rs:567 | src-tauri/src/surface.rs (mod tests) | unit | CI only (not run on macOS); copy run on macOS in scratch |
| choose_backend | src-tauri/src/surface.rs:586 | — | needs real Linux | untested: needs a GDK display; manual checklist (backend choice) |
| Surface::new | src-tauri/src/surface.rs:615 | — | needs real Linux | untested: Surface needs AppHandle<Wry>, GTK and a compositor; manual checklist |
| Surface::attach | src-tauri/src/surface.rs:853 | — | needs real Linux | untested: Surface needs AppHandle<Wry>, GTK and a compositor; manual checklist |
| Surface::detach | src-tauri/src/surface.rs:906 | — | needs real Linux | untested: Surface needs AppHandle<Wry>, GTK and a compositor; manual checklist |
| Surface::show | src-tauri/src/surface.rs:920 | — | needs real Linux | untested: Surface needs AppHandle<Wry>, GTK and a compositor; manual checklist |
| Surface::resize | src-tauri/src/surface.rs:952 | — | needs real Linux | untested: Surface needs AppHandle<Wry>, GTK and a compositor; manual checklist |
| Surface::set_bottom_clip | src-tauri/src/surface.rs:972 | — | needs real Linux | untested: Surface needs AppHandle<Wry>, GTK and a compositor; manual checklist |
| Surface::hide_if | src-tauri/src/surface.rs:996 | — | needs real Linux | untested: Surface needs AppHandle<Wry>, GTK and a compositor; manual checklist |
| Surface::hide | src-tauri/src/surface.rs:1008 | — | needs real Linux | untested: Surface needs AppHandle<Wry>, GTK and a compositor; manual checklist |
| Surface::hide_now | src-tauri/src/surface.rs:1013 | — | needs real Linux | untested: Surface needs AppHandle<Wry>, GTK and a compositor; manual checklist |
| Surface::window_inner_h | src-tauri/src/surface.rs:1028 | — | needs real Linux | untested: Surface needs AppHandle<Wry>, GTK and a compositor; manual checklist |
| Surface::has_surface | src-tauri/src/surface.rs:1037 | — | needs real Linux | untested: Surface needs AppHandle<Wry>, GTK and a compositor; manual checklist |
| Surface::is_pip | src-tauri/src/surface.rs:1043 | — | needs real Linux | untested: Surface needs AppHandle<Wry>, GTK and a compositor; manual checklist |
| Surface::enter_pip | src-tauri/src/surface.rs:1057 | — | needs real Linux | untested: Surface needs AppHandle<Wry>, GTK and a compositor; manual checklist |
| Surface::leave_pip | src-tauri/src/surface.rs:1128 | — | needs real Linux | untested: Surface needs AppHandle<Wry>, GTK and a compositor; manual checklist |
| Surface::watch_pip | src-tauri/src/surface.rs:1142 | — | needs real Linux | untested: Surface needs AppHandle<Wry>, GTK and a compositor; manual checklist |
| video_covers | src-tauri/src/surface.rs:1149 | — | needs real Linux | untested: GTK widgets/GL/libmpv input on a real desktop; manual checklist |
| sync_webview_clip | src-tauri/src/surface.rs:1172 | — | needs real Linux | untested: GTK widgets/GL/libmpv input on a real desktop; manual checklist |
| connect_gl_backend | src-tauri/src/surface.rs:1206 | — | needs real Linux | untested: GTK widgets/GL/libmpv input on a real desktop; manual checklist |
| connect_wl_backend | src-tauri/src/surface.rs:1330 | — | needs real Linux | untested: GTK widgets/GL/libmpv input on a real desktop; manual checklist |
| apply_geom | src-tauri/src/surface.rs:1380 | — | needs real Linux | untested: GTK widgets/GL/libmpv input on a real desktop; manual checklist |
| set_video_cursor | src-tauri/src/surface.rs:1415 | — | needs real Linux | untested: GTK widgets/GL/libmpv input on a real desktop; manual checklist |
| restore_from_pip | src-tauri/src/surface.rs:1431 | — | needs real Linux | untested: GTK widgets/GL/libmpv input on a real desktop; manual checklist |
| leave_pip_on_main | src-tauri/src/surface.rs:1454 | — | needs real Linux | untested: GTK widgets/GL/libmpv input on a real desktop; manual checklist |
| connect_render | src-tauri/src/surface.rs:1473 | — | needs real Linux | untested: GTK widgets/GL/libmpv input on a real desktop; manual checklist |
| build_render_ctx | src-tauri/src/surface.rs:1571 | — | needs real Linux | untested: GTK widgets/GL/libmpv input on a real desktop; manual checklist |
| make_render_ctx | src-tauri/src/surface.rs:1594 | — | needs real Linux | untested: GTK widgets/GL/libmpv input on a real desktop; manual checklist |
| send_input | src-tauri/src/surface.rs:1666 | — | needs real Linux | untested: GTK widgets/GL/libmpv input on a real desktop; manual checklist |
| connect_input | src-tauri/src/surface.rs:1776 | — | needs real Linux | untested: GTK widgets/GL/libmpv input on a real desktop; manual checklist |
| connect_touch_gestures | src-tauri/src/surface.rs:1931 | — | needs real Linux | untested: GTK widgets/GL/libmpv input on a real desktop; manual checklist |
| intended_alloc | src-tauri/src/surface.rs:1307 | src-tauri/src/surface.rs (mod tests) | needs real Linux | tested via intended_rect (GTK half untested) |
| intended_rect | src-tauri/src/surface.rs:1323 | src-tauri/src/surface.rs (mod tests) | unit | CI only (not run on macOS); copy run on macOS in scratch |
| mbtn_name | src-tauri/src/surface.rs:1682 | src-tauri/src/surface.rs (mod tests) | unit | CI only (not run on macOS); copy run on macOS in scratch |
| mpv_key_name | src-tauri/src/surface.rs:1700 | src-tauri/src/surface.rs (mod tests) | unit | CI only (not run on macOS) (gdk keyval API; not compiled on macOS) |
| build_key_command | src-tauri/src/surface.rs:1755 | src-tauri/src/surface.rs (mod tests) | unit | CI only (not run on macOS) (gdk keyval API; not compiled on macOS) |
| wheel_steps | src-tauri/src/surface.rs:1875 | src-tauri/src/surface.rs (mod tests) | unit | CI only (not run on macOS); copy run on macOS in scratch |
| tap_side | src-tauri/src/surface.rs:1898 | src-tauri/src/surface.rs (mod tests) | unit | CI only (not run on macOS); copy run on macOS in scratch |
| pinch_gesture | src-tauri/src/surface.rs:1909 | src-tauri/src/surface.rs (mod tests) | unit | CI only (not run on macOS); copy run on macOS in scratch |
| Handle::spawn | src-tauri/src/video_thread.rs:106 | — | needs real Linux | untested: needs Wayland globals and EGL |
| Handle::send | src-tauri/src/video_thread.rs:129 | — | needs real Linux | untested: needs a running video thread |
| buffer_dims_of | src-tauri/src/video_thread.rs:193 | src-tauri/src/video_thread.rs (mod tests) | unit | CI only (not run on macOS); compiled and run on macOS in scratch against the real source |
| clipped | src-tauri/src/video_thread.rs:202 | src-tauri/src/video_thread.rs (mod tests) | unit | CI only (not run on macOS); compiled and run on macOS in scratch against the real source |
| earliest | src-tauri/src/video_thread.rs:208 | src-tauri/src/video_thread.rs (mod tests) | unit | CI only (not run on macOS); compiled and run on macOS in scratch against the real source |
| State::debug | src-tauri/src/video_thread.rs:221 | src-tauri/src/video_thread.rs (mod tests) | unit | tested via surface::debug_enabled |
| State::buffer_dims | src-tauri/src/video_thread.rs:225 | src-tauri/src/video_thread.rs (mod tests) | unit | tested via buffer_dims_of |
| State::recreate_win | src-tauri/src/video_thread.rs:233 | — | needs real Linux | untested: State owns an EGL context and Wayland subsurface; manual checklist |
| State::set_surface | src-tauri/src/video_thread.rs:264 | — | needs real Linux | untested: State owns an EGL context and Wayland subsurface; manual checklist |
| State::try_attach | src-tauri/src/video_thread.rs:299 | — | needs real Linux | untested: State owns an EGL context and Wayland subsurface; manual checklist |
| State::detach | src-tauri/src/video_thread.rs:341 | — | needs real Linux | untested: State owns an EGL context and Wayland subsurface; manual checklist |
| State::resize | src-tauri/src/video_thread.rs:351 | — | needs real Linux | untested: State owns an EGL context and Wayland subsurface; manual checklist |
| State::schedule_redraw | src-tauri/src/video_thread.rs:398 | — | needs real Linux | untested: State owns an EGL context and Wayland subsurface; manual checklist |
| State::can_draw | src-tauri/src/video_thread.rs:405 | — | needs real Linux | untested: State owns an EGL context and Wayland subsurface; manual checklist |
| State::draw | src-tauri/src/video_thread.rs:409 | — | needs real Linux | untested: State owns an EGL context and Wayland subsurface; manual checklist |
| State::hide | src-tauri/src/video_thread.rs:521 | — | needs real Linux | untested: State owns an EGL context and Wayland subsurface; manual checklist |
| State::clip | src-tauri/src/video_thread.rs:391 | src-tauri/src/video_thread.rs (mod tests) | needs real Linux | tested via clipped (State half needs EGL) |
| run | src-tauri/src/video_thread.rs:533 | — | needs real Linux | untested: the video thread's loop; manual checklist |
| get_proc_address | src-tauri/src/render.rs:20 | src-tauri/src/render.rs (mod tests) | unit | CI only (not run on macOS); compiled and run on macOS in scratch against the real source |
| update_thunk | src-tauri/src/render.rs:27 | src-tauri/src/render.rs (mod tests) | unit | CI only (not run on macOS); compiled and run on macOS in scratch against the real source |
| RenderCtx::new | src-tauri/src/render.rs:59 | — | needs real Linux | untested: mpv_render_context needs a current GL context (libepoxy aborts without one) |
| RenderCtx::set_update_callback | src-tauri/src/render.rs:116 | — | needs real Linux | untested: mpv_render_context needs a current GL context (libepoxy aborts without one) |
| RenderCtx::update | src-tauri/src/render.rs:143 | — | needs real Linux | untested: mpv_render_context needs a current GL context (libepoxy aborts without one) |
| RenderCtx::render | src-tauri/src/render.rs:147 | — | needs real Linux | untested: mpv_render_context needs a current GL context (libepoxy aborts without one) |
| RenderCtx::render_skip | src-tauri/src/render.rs:183 | — | needs real Linux | untested: mpv_render_context needs a current GL context (libepoxy aborts without one) |
| RenderCtx::report_swap | src-tauri/src/render.rs:205 | — | needs real Linux | untested: mpv_render_context needs a current GL context (libepoxy aborts without one) |
| RenderCtx::drop | src-tauri/src/render.rs:213 | — | needs real Linux | untested: mpv_render_context needs a current GL context (libepoxy aborts without one) |
| RenderCtx::UPDATE_FRAME (const) | src-tauri/src/render.rs:136 | src-tauri/src/render.rs (mod tests) | unit | CI only (not run on macOS); compiled and run on macOS in scratch against the real source |
| lib | src-tauri/src/gl.rs:21 | src-tauri/src/gl.rs (mod tests) | unit | CI only (not run on macOS); compiled and run on macOS in scratch against the real source (skips without libepoxy) |
| proc_addr | src-tauri/src/gl.rs:34 | src-tauri/src/gl.rs (mod tests) | unit | CI only (not run on macOS); compiled and run on macOS in scratch against the real source |
| available | src-tauri/src/gl.rs:57 | src-tauri/src/gl.rs (mod tests) | unit | CI only (not run on macOS); compiled and run on macOS in scratch against the real source (skips without libepoxy) |
| api | src-tauri/src/gl.rs:82 | src-tauri/src/gl.rs (mod tests) | unit | CI only (not run on macOS); compiled and run on macOS in scratch against the real source (skips without libepoxy) |
| drain_errors | src-tauri/src/gl.rs:124 | — | needs real Linux | untested: calls glGetError, needs a current context |
| load_lib | src-tauri/src/egl.rs:57 | src-tauri/src/egl.rs (mod tests) | unit | CI only (not run on macOS) |
| sym | src-tauri/src/egl.rs:74 | src-tauri/src/egl.rs (mod tests) | unit | CI only (not run on macOS) |
| api / wl_egl_api (macro) | src-tauri/src/egl.rs:109 | src-tauri/src/egl.rs (mod tests) | unit | CI only (not run on macOS) (existing symbols_resolve) |
| available | src-tauri/src/egl.rs:134 | src-tauri/src/egl.rs (mod tests) | unit | CI only (not run on macOS) |
| err | src-tauri/src/egl.rs:138 | — | needs real Linux | untested: only meaningful after a failed EGL call on a display |
| EglDisplay::new | src-tauri/src/egl.rs:151 | src-tauri/src/egl.rs (mod tests) | unit | CI only (not run on macOS); compiled and run on macOS in scratch against the real source (null display branch) |
| EglDisplay::describe | src-tauri/src/egl.rs:171 | — | needs real Linux | untested: needs an EGL display |
| EglContext::new | src-tauri/src/egl.rs:196 | — | needs real Linux | untested: needs a Wayland display and EGL |
| EglContext::make_current | src-tauri/src/egl.rs:239 | — | needs real Linux | untested: needs a Wayland display and EGL |
| EglContext::release | src-tauri/src/egl.rs:244 | — | needs real Linux | untested: needs a Wayland display and EGL |
| EglContext::set_swap_interval | src-tauri/src/egl.rs:259 | — | needs real Linux | untested: needs a Wayland display and EGL |
| EglContext::swap | src-tauri/src/egl.rs:265 | — | needs real Linux | untested: needs a Wayland display and EGL |
| EglContext::drop | src-tauri/src/egl.rs:271 | — | needs real Linux | untested: needs EGL |
| EglWindowSurface::new | src-tauri/src/egl.rs:294 | — | needs real Linux | untested: needs a wl_surface |
| EglWindowSurface::resize | src-tauri/src/egl.rs:335 | — | needs real Linux | untested: needs a wl_egl_window |
| EglWindowSurface::drop | src-tauri/src/egl.rs:350 | — | needs real Linux | untested: needs EGL |
| lib | src-tauri/src/wl.rs:103 | src-tauri/src/wl.rs (mod tests) | unit | CI only (not run on macOS) |
| sym | src-tauri/src/wl.rs:118 | src-tauri/src/wl.rs (mod tests) | unit | CI only (not run on macOS) |
| api | src-tauri/src/wl.rs:174 | src-tauri/src/wl.rs (mod tests) | unit | CI only (not run on macOS) (existing symbols_resolve) |
| available | src-tauri/src/wl.rs:213 | src-tauri/src/wl.rs (mod tests) | unit | CI only (not run on macOS); compiled and run on macOS in scratch against the real source |
| presentation_stats | src-tauri/src/wl.rs:363 | src-tauri/src/wl.rs (mod tests) | unit | CI only (not run on macOS); compiled and run on macOS in scratch against the real source |
| on_sync_output | src-tauri/src/wl.rs:378 | — | unit | untested: no-op callback |
| on_presented | src-tauri/src/wl.rs:381 | — | needs real Linux | untested: destroys a real wl_proxy; needs a compositor |
| on_discarded | src-tauri/src/wl.rs:401 | — | needs real Linux | untested: destroys a real wl_proxy; needs a compositor |
| FrameClock::new | src-tauri/src/wl.rs:443 | src-tauri/src/wl.rs (mod tests) | unit | CI only (not run on macOS); compiled and run on macOS in scratch against the real source |
| FrameClock::pending | src-tauri/src/wl.rs:452 | src-tauri/src/wl.rs (mod tests) | unit | CI only (not run on macOS); compiled and run on macOS in scratch against the real source |
| FrameClock::overdue | src-tauri/src/wl.rs:458 | src-tauri/src/wl.rs (mod tests) | unit | CI only (not run on macOS); compiled and run on macOS in scratch against the real source |
| FrameClock::abandon | src-tauri/src/wl.rs:466 | src-tauri/src/wl.rs (mod tests) | unit | CI only (not run on macOS); compiled and run on macOS in scratch against the real source |
| on_frame_done | src-tauri/src/wl.rs:483 | src-tauri/src/wl.rs (mod tests) | unit | tested via a_stale_answer_changes_nothing (generation check; proxy destroy needs a compositor) |
| fixed | src-tauri/src/wl.rs:500 | src-tauri/src/wl.rs (mod tests) | unit | CI only (not run on macOS); compiled and run on macOS in scratch against the real source |
| on_global | src-tauri/src/wl.rs:520 | src-tauri/src/wl.rs (mod tests) | unit | CI only (not run on macOS); compiled and run on macOS in scratch against the real source |
| on_global_remove | src-tauri/src/wl.rs:538 | src-tauri/src/wl.rs (mod tests) | unit | CI only (not run on macOS); compiled and run on macOS in scratch against the real source |
| Globals::new | src-tauri/src/wl.rs:574 | src-tauri/src/wl.rs (mod tests) | unit | CI only (not run on macOS); compiled and run on macOS in scratch against the real source (null display branch) |
| Globals::has_viewporter | src-tauri/src/wl.rs:664 | — | needs real Linux | untested: needs a compositor |
| Globals::dispatch | src-tauri/src/wl.rs:672 | — | needs real Linux | untested: needs a compositor |
| Globals::flush | src-tauri/src/wl.rs:679 | — | needs real Linux | untested: needs a compositor |
| Subsurface::new | src-tauri/src/wl.rs:722 | — | needs real Linux | untested: Subsurface needs a compositor; manual checklist |
| Subsurface::ids | src-tauri/src/wl.rs:794 | — | needs real Linux | untested: Subsurface needs a compositor; manual checklist |
| Subsurface::has_viewport | src-tauri/src/wl.rs:798 | — | needs real Linux | untested: Subsurface needs a compositor; manual checklist |
| Subsurface::region | src-tauri/src/wl.rs:802 | — | needs real Linux | untested: Subsurface needs a compositor; manual checklist |
| Subsurface::destroy_region | src-tauri/src/wl.rs:819 | — | needs real Linux | untested: Subsurface needs a compositor; manual checklist |
| Subsurface::surface_request | src-tauri/src/wl.rs:828 | — | needs real Linux | untested: Subsurface needs a compositor; manual checklist |
| Subsurface::set_input_region_empty | src-tauri/src/wl.rs:844 | — | needs real Linux | untested: Subsurface needs a compositor; manual checklist |
| Subsurface::set_size | src-tauri/src/wl.rs:863 | — | needs real Linux | untested: Subsurface needs a compositor; manual checklist |
| Subsurface::set_position | src-tauri/src/wl.rs:890 | — | needs real Linux | untested: Subsurface needs a compositor; manual checklist |
| Subsurface::subsurface_request | src-tauri/src/wl.rs:904 | — | needs real Linux | untested: Subsurface needs a compositor; manual checklist |
| Subsurface::set_sync | src-tauri/src/wl.rs:918 | — | needs real Linux | untested: Subsurface needs a compositor; manual checklist |
| Subsurface::set_desync | src-tauri/src/wl.rs:923 | — | needs real Linux | untested: Subsurface needs a compositor; manual checklist |
| Subsurface::set_crop | src-tauri/src/wl.rs:930 | — | needs real Linux | untested: Subsurface needs a compositor; manual checklist |
| Subsurface::clear_crop | src-tauri/src/wl.rs:958 | — | needs real Linux | untested: Subsurface needs a compositor; manual checklist |
| Subsurface::unmap | src-tauri/src/wl.rs:990 | — | needs real Linux | untested: Subsurface needs a compositor; manual checklist |
| Subsurface::commit | src-tauri/src/wl.rs:1006 | — | needs real Linux | untested: Subsurface needs a compositor; manual checklist |
| Subsurface::request_frame | src-tauri/src/wl.rs:1014 | — | needs real Linux | untested: Subsurface needs a compositor; manual checklist |
| Subsurface::request_presentation_feedback | src-tauri/src/wl.rs:1046 | — | needs real Linux | untested: Subsurface needs a compositor; manual checklist |
| Subsurface::surface_request_noarg | src-tauri/src/wl.rs:1070 | — | needs real Linux | untested: Subsurface needs a compositor; manual checklist |
| Subsurface::destroy | src-tauri/src/wl.rs:1084 | — | needs real Linux | untested: Subsurface needs a compositor; manual checklist |
| Subsurface::drop | src-tauri/src/wl.rs:1117 | — | needs real Linux | untested: Subsurface needs a compositor; manual checklist |
| hand-written protocol descriptors (statics) | src-tauri/src/wl.rs:252 | src-tauri/src/wl.rs (mod tests) | unit | CI only (not run on macOS) (descriptor consistency) |
| music | src-tauri/src/mpris.rs:50 | src-tauri/src/mpris.rs (mod tests) | unit | CI only (not run on macOS) |
| start | src-tauri/src/mpris.rs:69 | — | needs real Linux | untested: needs a session bus; manual checklist |
| dispatch | src-tauri/src/mpris.rs:82 | — | needs real Linux | untested: spawns onto AppHandle<Wry> with a live player; manual checklist |
| status_of | src-tauri/src/mpris.rs:95 | src-tauri/src/mpris.rs (mod tests) | unit | CI only (not run on macOS) |
| playback_status_of | src-tauri/src/mpris.rs:116 | src-tauri/src/mpris.rs (mod tests) | unit | CI only (not run on macOS); copy run on macOS in scratch |
| playback_status | src-tauri/src/mpris.rs:127 | src-tauri/src/mpris.rs (mod tests) | unit | CI only (not run on macOS) |
| next_available | src-tauri/src/mpris.rs:131 | src-tauri/src/mpris.rs (mod tests) | unit | CI only (not run on macOS) |
| notify | src-tauri/src/mpris.rs:146 | src-tauri/src/mpris.rs (mod tests) | unit | CI only (not run on macOS) |
| announce | src-tauri/src/mpris.rs:161 | src-tauri/src/mpris.rs (mod tests) | needs real Linux | tested via changed_keys (signal sending needs a session bus) |
| changed_keys | src-tauri/src/mpris.rs:235 | src-tauri/src/mpris.rs (mod tests) | unit | CI only (not run on macOS); copy run on macOS in scratch |
| park | src-tauri/src/mpris.rs:263 | src-tauri/src/mpris.rs (mod tests) | unit | CI only (not run on macOS) |
| track_path | src-tauri/src/mpris.rs:287 | src-tauri/src/mpris.rs (mod tests) | unit | CI only (not run on macOS) |
| queue_path | src-tauri/src/mpris.rs:302 | src-tauri/src/mpris.rs (mod tests) | unit | CI only (not run on macOS) |
| track_ids | src-tauri/src/mpris.rs:307 | src-tauri/src/mpris.rs (mod tests) | unit | CI only (not run on macOS) |
| track_metadata | src-tauri/src/mpris.rs:321 | src-tauri/src/mpris.rs (mod tests) | unit | CI only (not run on macOS) |
| metadata | src-tauri/src/mpris.rs:347 | src-tauri/src/mpris.rs (mod tests) | unit | CI only (not run on macOS) |
| own_name | src-tauri/src/mpris.rs:382 | src-tauri/src/mpris.rs (mod tests) | unit | CI only (not run on macOS); copy run on macOS in scratch |
| serve | src-tauri/src/mpris.rs:392 | — | needs real Linux | untested: the D-Bus object (methods, properties, TrackList); manual checklist |
| low_power | src-tauri/src/power.rs:34 | src-tauri/src/power.rs (mod tests) | unit | CI only (not run on macOS) |
| watch | src-tauri/src/power.rs:40 | — | needs real Linux | untested: needs a system bus with UPower; manual checklist |
| read_initial | src-tauri/src/power.rs:84 | — | needs real Linux | untested: needs a system bus with UPower |
| apply | src-tauri/src/power.rs:96 | src-tauri/src/power.rs (mod tests) | unit | CI only (not run on macOS) |
| is_metered | src-tauri/src/network.rs:18 | src-tauri/src/network.rs (mod tests) | unit | CI only (not run on macOS) |
| watch | src-tauri/src/network.rs:23 | — | needs real Linux | untested: GNetworkMonitor on the main context; manual checklist |
| label | src-tauri/src/theme.rs:25 | src-tauri/src/theme.rs (mod tests) | unit | CI only (not run on macOS); copy run on macOS in scratch |
| read | src-tauri/src/theme.rs:33 | — | needs real Linux | untested: needs the desktop portal |
| system_color_scheme | src-tauri/src/theme.rs:50 | src-tauri/src/theme.rs (mod tests) | unit | CI only (not run on macOS) (no-bus branch); portal branch on the manual checklist |
| watch | src-tauri/src/theme.rs:62 | — | needs real Linux | untested: needs the desktop portal; manual checklist |
| main | src-tauri/src/main.rs:3 | — | needs real Linux | untested: starts the app |
| gdk_backend_override | src-tauri/src/main.rs:16 | src-tauri/src/main.rs (mod tests) | unit | CI only (not run on macOS); copy run on macOS in scratch |
| webkit_defaults | src-tauri/src/main.rs:30 | src-tauri/src/main.rs (mod tests) | unit | CI only (not run on macOS); copy run on macOS in scratch |
| debug_log_line | src-tauri/src/lib.rs:33 | src-tauri/src/lib.rs (mod tests) | unit | CI only (not run on macOS) |
| now_ms | src-tauri/src/lib.rs:51 | src-tauri/src/lib.rs (mod tests) | unit | CI only (not run on macOS) |
| ui_log | src-tauri/src/lib.rs:59 | src-tauri/src/lib.rs (mod tests) | unit | CI only (not run on macOS) |
| config_load | src-tauri/src/lib.rs:67 | src-tauri/src/lib.rs (mod tests) | unit | CI only (not run on macOS) |
| config_save | src-tauri/src/lib.rs:75 | src-tauri/src/lib.rs (mod tests) | unit | CI only (not run on macOS) |
| with_user_agent | src-tauri/src/lib.rs:81 | src-tauri/src/lib.rs (mod tests) | unit | CI only (not run on macOS); copy run on macOS in scratch |
| fetch_source | src-tauri/src/lib.rs:96 | src-tauri/src/lib.rs (mod tests) | unit | CI only (not run on macOS); copy run on macOS in scratch |
| app_info | src-tauri/src/lib.rs:168 | src-tauri/src/lib.rs (mod tests) | unit | CI only (not run on macOS) |
| jf_probe | src-tauri/src/lib.rs:187 | src-tauri/src/server.rs | unit | tested via server::probe (thin Tauri wrapper; that module's own tests) |
| jf_login | src-tauri/src/lib.rs:192 | src-tauri/src/server.rs | unit | tested via server::login (thin Tauri wrapper; that module's own tests) |
| jf_logout | src-tauri/src/lib.rs:197 | src-tauri/src/server.rs | unit | tested via server::logout (thin Tauri wrapper; that module's own tests) |
| jf_login_quick_connect | src-tauri/src/lib.rs:202 | src-tauri/src/server.rs | unit | tested via server::login_quick_connect (thin Tauri wrapper; that module's own tests) |
| jf_public | src-tauri/src/lib.rs:209 | src-tauri/src/server.rs | unit | tested via server::public_request (thin Tauri wrapper; that module's own tests) |
| jf_discover | src-tauri/src/lib.rs:215 | src-tauri/src/discovery.rs | unit | tested via discovery::find (thin Tauri wrapper; that module's own tests) |
| player_get_properties | src-tauri/src/lib.rs:223 | src-tauri/src/lib.rs (mod tests) | unit | CI only (not run on macOS) (no session) |
| player_warm | src-tauri/src/lib.rs:232 | src-tauri/src/server.rs | unit | tested via server::warm (thin Tauri wrapper; that module's own tests) |
| accounts_list | src-tauri/src/lib.rs:237 | src-tauri/src/lib.rs (mod tests) | unit | CI only (not run on macOS) |
| account_switch | src-tauri/src/lib.rs:242 | src-tauri/src/lib.rs (mod tests) | unit | CI only (not run on macOS) (unknown key) |
| account_forget | src-tauri/src/lib.rs:247 | src-tauri/src/server.rs | unit | tested via server::forget_account (thin Tauri wrapper; that module's own tests) |
| jf_request | src-tauri/src/lib.rs:252 | src-tauri/src/server.rs | unit | tested via server::request (thin Tauri wrapper; that module's own tests) |
| jf_image | src-tauri/src/lib.rs:261 | src-tauri/src/server.rs | unit | tested via server::image (thin Tauri wrapper; that module's own tests) |
| jf_ping | src-tauri/src/lib.rs:266 | src-tauri/src/server.rs | unit | tested via server::ping (thin Tauri wrapper; that module's own tests) |
| jf_bitrate_test | src-tauri/src/lib.rs:271 | src-tauri/src/server.rs | unit | tested via server::bitrate_test (thin Tauri wrapper; that module's own tests) |
| resolve_stream | src-tauri/src/lib.rs:291 | src-tauri/src/lib.rs (mod tests) | unit | CI only (not run on macOS); copy run on macOS in scratch |
| player_play | src-tauri/src/lib.rs:371 | — | needs real Linux | untested: takes AppHandle<Wry> and needs the video surface; manual checklist |
| audio_play | src-tauri/src/lib.rs:388 | — | needs real Linux | untested: takes AppHandle<Wry>; manual checklist |
| audio_set_next | src-tauri/src/lib.rs:393 | src-tauri/src/lib.rs (mod tests) | unit | CI only (not run on macOS) (no core) |
| audio_command | src-tauri/src/lib.rs:398 | src-tauri/src/lib.rs (mod tests) | unit | CI only (not run on macOS) (no core) |
| audio_stop | src-tauri/src/lib.rs:403 | — | needs real Linux | untested: takes AppHandle<Wry>; manual checklist |
| audio_status | src-tauri/src/lib.rs:409 | src-tauri/src/lib.rs (mod tests) | unit | CI only (not run on macOS) |
| audio_set_queue | src-tauri/src/lib.rs:415 | src-tauri/src/lib.rs (mod tests) | unit | CI only (not run on macOS) |
| player_stop | src-tauri/src/lib.rs:426 | src-tauri/src/lib.rs (mod tests) | unit | CI only (not run on macOS) (no session) |
| player_pause_toggle | src-tauri/src/lib.rs:433 | src-tauri/src/lib.rs (mod tests) | unit | CI only (not run on macOS) (no session) |
| player_seek | src-tauri/src/lib.rs:440 | src-tauri/src/lib.rs (mod tests) | unit | CI only (not run on macOS) (no session) |
| player_set_track | src-tauri/src/lib.rs:452 | src-tauri/src/lib.rs (mod tests) | unit | CI only (not run on macOS) (no session) |
| track_property | src-tauri/src/lib.rs:462 | src-tauri/src/lib.rs (mod tests) | unit | CI only (not run on macOS); copy run on macOS in scratch |
| player_status | src-tauri/src/lib.rs:471 | src-tauri/src/lib.rs (mod tests) | unit | CI only (not run on macOS) |
| player_set_next_available | src-tauri/src/lib.rs:479 | src-tauri/src/lib.rs (mod tests) | unit | CI only (not run on macOS) |
| audio_devices | src-tauri/src/lib.rs:488 | src-tauri/src/lib.rs (mod tests) | unit | CI only (not run on macOS) |
| player_mpv_command | src-tauri/src/lib.rs:497 | src-tauri/src/lib.rs (mod tests) | unit | CI only (not run on macOS) (no session) |
| player_set_viewport | src-tauri/src/lib.rs:513 | — | needs real Linux | untested: takes AppHandle<Wry>; geometry tested via video_layout; manual checklist (fullscreen) |
| player_set_pip | src-tauri/src/lib.rs:534 | — | needs real Linux | untested: takes AppHandle<Wry> and needs the surface; manual checklist (PiP) |
| resize_video_surface | src-tauri/src/lib.rs:553 | src-tauri/src/lib.rs (mod tests) | needs real Linux | tested via video_layout (window and surface half needs a desktop) |
| video_layout | src-tauri/src/lib.rs:591 | src-tauri/src/lib.rs (mod tests) | unit | CI only (not run on macOS); copy run on macOS in scratch |
| window_size_path | src-tauri/src/lib.rs:636 | src-tauri/src/lib.rs (mod tests) | unit | CI only (not run on macOS) |
| save_window_size | src-tauri/src/lib.rs:652 | — | needs real Linux | untested: needs a GTK window; manual checklist |
| restore_window_size | src-tauri/src/lib.rs:674 | src-tauri/src/lib.rs (mod tests) | needs real Linux | tested via clamp_window_size (GTK half needs a window); manual checklist |
| clamp_window_size | src-tauri/src/lib.rs:699 | src-tauri/src/lib.rs (mod tests) | unit | CI only (not run on macOS); copy run on macOS in scratch |
| quit_confirm | src-tauri/src/lib.rs:720 | — | needs real Linux | untested: takes AppHandle<Wry> and a window; manual checklist (quit with downloads) |
| download_start | src-tauri/src/lib.rs:731 | src-tauri/src/DlManager.rs | unit | tested via DlManager::start (thin Tauri wrapper; that module's own tests) |
| download_cancel | src-tauri/src/lib.rs:740 | src-tauri/src/lib.rs (mod tests) | unit | CI only (not run on macOS) (unknown id) |
| download_retry | src-tauri/src/lib.rs:745 | src-tauri/src/downloads.rs | unit | tested via downloads::restart (thin Tauri wrapper; that module's own tests) |
| download_pause | src-tauri/src/lib.rs:757 | src-tauri/src/lib.rs (mod tests) | unit | CI only (not run on macOS) (unknown id) |
| downloads_sync_keep_awake | src-tauri/src/lib.rs:763 | src-tauri/src/DlManager.rs | unit | tested via DlManager::sync_keep_awake (thin Tauri wrapper; that module's own tests) |
| network_metered | src-tauri/src/lib.rs:768 | src-tauri/src/lib.rs (mod tests) | unit | CI only (not run on macOS) |
| download_fetch_subtitles | src-tauri/src/lib.rs:773 | src-tauri/src/download_extras.rs | unit | tested via download_extras::fetch_subtitles (thin Tauri wrapper; that module's own tests) |
| download_update_details | src-tauri/src/lib.rs:784 | src-tauri/src/download_extras.rs | unit | tested via download_extras::update_details (thin Tauri wrapper; that module's own tests) |
| downloads_reveal | src-tauri/src/lib.rs:795 | src-tauri/src/download_extras.rs | unit | tested via download_extras::reveal (thin Tauri wrapper; that module's own tests) |
| download_delete | src-tauri/src/lib.rs:802 | src-tauri/src/lib.rs (mod tests) | unit | CI only (not run on macOS) (invalid id) |
| downloads_list | src-tauri/src/lib.rs:807 | src-tauri/src/lib.rs (mod tests) | unit | CI only (not run on macOS) (empty) |
| disk_free | src-tauri/src/lib.rs:814 | src-tauri/src/lib.rs (mod tests) | unit | CI only (not run on macOS) |
| download_set_watch_state | src-tauri/src/lib.rs:819 | src-tauri/src/downloads.rs | unit | tested via downloads::set_watch_state (thin Tauri wrapper; that module's own tests) |
| progress_sync | src-tauri/src/lib.rs:826 | src-tauri/src/lib.rs (mod tests) | unit | CI only (not run on macOS) (error branches) |
| progress_store_local | src-tauri/src/lib.rs:847 | src-tauri/src/lib.rs (mod tests) | unit | CI only (not run on macOS) |
| progress_pending | src-tauri/src/lib.rs:852 | src-tauri/src/lib.rs (mod tests) | unit | CI only (not run on macOS) |
| progress_pending_ids | src-tauri/src/lib.rs:857 | src-tauri/src/lib.rs (mod tests) | unit | CI only (not run on macOS) |
| replay_target | src-tauri/src/lib.rs:864 | src-tauri/src/lib.rs (mod tests) | unit | CI only (not run on macOS); copy run on macOS in scratch |
| test_sequence | src-tauri/src/lib.rs:875 | src-tauri/src/lib.rs (mod tests) | unit | CI only (not run on macOS); copy run on macOS in scratch |
| run | src-tauri/src/lib.rs:888 | — | needs real Linux | untested: builds the app; test hooks parsed by test_sequence/replay_target; manual checklist |
| MIN_WIDTH_CSS / MIN_HEIGHT_CSS (consts) | src-tauri/src/lib.rs:611 | src-tauri/src/lib.rs (mod tests) | unit | CI only (not run on macOS) (matches tauri.conf.json) |
