| Function | Source | Test file | Kind | Status |
|---|---|---|---|---|
| `config::FILE_MODE` / `DIR_MODE` | src-tauri/src/config.rs:12 | src-tauri/src/config.rs (mod tests) | unit | tested |
| `config::config_dir` | src-tauri/src/config.rs:15 | src-tauri/src/config.rs (mod tests) | unit | tested |
| `config::data_dir` | src-tauri/src/config.rs:21 | src-tauri/src/config.rs (mod tests) | unit | tested |
| `config::migrate_legacy_dirs` (FellyJin invariant) | src-tauri/src/config.rs:33 | src-tauri/src/config.rs (mod tests) | unit | tested |
| `config::downloads_dir` | src-tauri/src/config.rs:53 | src-tauri/src/config.rs (mod tests) | unit | tested |
| `config::config_path` | src-tauri/src/config.rs:57 | src-tauri/src/config.rs (mod tests) | unit | tested |
| `config::harden` | src-tauri/src/config.rs:64 | src-tauri/src/config.rs (mod tests) | unit | tested via load, save, harden_data_dir |
| `config::harden_data_dir` | src-tauri/src/config.rs:75 | src-tauri/src/config.rs (mod tests) | unit | tested |
| `config::load` | src-tauri/src/config.rs:79 | src-tauri/src/config.rs (mod tests) | unit | tested |
| `config::SAVE_BLOCKED` | src-tauri/src/config.rs:111 | src-tauri/src/config.rs (mod tests) | unit | tested via quarantine, save |
| `config::reset_for_tests` (cfg test) | src-tauri/src/config.rs:115 | src-tauri/src/config.rs (mod tests) | unit | tested |
| `config::quarantine` | src-tauri/src/config.rs:128 | src-tauri/src/config.rs (mod tests) | unit | tested via load (rename, copy-blocked and refuse-to-save paths) |
| `config::save` | src-tauri/src/config.rs:156 | src-tauri/src/config.rs (mod tests) | unit | tested |
| `config::merge` | src-tauri/src/config.rs:186 | src-tauri/src/config.rs (mod tests) | unit | tested |
| `config::device_id` | src-tauri/src/config.rs:205 | src-tauri/src/config.rs (mod tests) | unit | tested (the "aquarium" fallback is unreachable: load always supplies an id) |
| `config::accounts` | src-tauri/src/config.rs:216 | src-tauri/src/config.rs (mod tests) | unit | tested |
| `config::save_accounts` | src-tauri/src/config.rs:224 | src-tauri/src/config.rs (mod tests) | unit | tested |
| `config::upsert_account` | src-tauri/src/config.rs:230 | src-tauri/src/config.rs (mod tests) | unit | tested |
| `config::remove_account` | src-tauri/src/config.rs:249 | src-tauri/src/config.rs (mod tests) | unit | tested |
| `config::set_account_field` | src-tauri/src/config.rs:258 | src-tauri/src/config.rs (mod tests) | unit | tested |
| `prefs::BatteryRender` | src-tauri/src/prefs.rs:21 | src-tauri/src/prefs.rs (mod tests) | unit | tested |
| `prefs::BATTERY_PROFILE` | src-tauri/src/prefs.rs:34 | src-tauri/src/prefs.rs (mod tests) | unit | tested (checked against src-tauri/mpv-config/mpv.conf) |
| `prefs::Prefs::load` | src-tauri/src/prefs.rs:42 | src-tauri/src/prefs.rs (mod tests) | unit | tested |
| `prefs::Prefs::text` | src-tauri/src/prefs.rs:48 | src-tauri/src/prefs.rs (mod tests) | unit | tested via args |
| `prefs::Prefs::flag` | src-tauri/src/prefs.rs:57 | src-tauri/src/prefs.rs (mod tests) | unit | tested via args |
| `prefs::Prefs::battery_render` | src-tauri/src/prefs.rs:63 | src-tauri/src/prefs.rs (mod tests) | unit | tested |
| `prefs::Prefs::number` | src-tauri/src/prefs.rs:73 | src-tauri/src/prefs.rs (mod tests) | unit | tested via args |
| `prefs::Prefs::args` | src-tauri/src/prefs.rs:84 | src-tauri/src/prefs.rs (mod tests) | unit | tested |
| `progress::queue_path` | src-tauri/src/progress.rs:5 | src-tauri/src/progress.rs (mod tests) | unit | tested |
| `progress::read_queue` | src-tauri/src/progress.rs:9 | src-tauri/src/progress.rs (mod tests) | unit | tested |
| `progress::write_queue` | src-tauri/src/progress.rs:16 | src-tauri/src/progress.rs (mod tests) | unit | tested |
| `progress::current_owner` | src-tauri/src/progress.rs:24 | src-tauri/src/progress.rs (mod tests) | unit | tested |
| `progress::is_owned` | src-tauri/src/progress.rs:37 | src-tauri/src/progress.rs (mod tests) | unit | tested |
| `progress::store_local` | src-tauri/src/progress.rs:48 | src-tauri/src/progress.rs (mod tests) | unit | tested |
| `progress::owned_entries` | src-tauri/src/progress.rs:95 | src-tauri/src/progress.rs (mod tests) | unit | tested via pending_count, pending_item_ids |
| `progress::pending_count` | src-tauri/src/progress.rs:102 | src-tauri/src/progress.rs (mod tests) | unit | tested |
| `progress::pending_item_ids` | src-tauri/src/progress.rs:109 | src-tauri/src/progress.rs (mod tests) | unit | tested |
| `progress::sync` | src-tauri/src/progress.rs:119 | src-tauri/src/progress.rs (mod tests) | unit | tested (FakeServer) |
| `progress::sync` against Jellyfin 12 | src-tauri/src/progress.rs:119 | src-tauri/src/progress.rs (qa_server_takes_offline_progress) | integration (QA server) | tested |
| `progress::mark_played` | src-tauri/src/progress.rs:172 | src-tauri/src/progress.rs (mod tests) | unit | tested via sync |
| `discovery::QUESTION` / `PORT` | src-tauri/src/discovery.rs:18 | src-tauri/src/discovery.rs (mod tests) | unit | tested via find_from (PORT itself only via find) |
| `discovery::MAX_SERVERS` | src-tauri/src/discovery.rs:22 | src-tauri/src/discovery.rs (mod tests) | unit | tested |
| `discovery::find` | src-tauri/src/discovery.rs:26 | src-tauri/src/discovery.rs (mod tests) | unit | tested via find_from (find itself would broadcast on the real network, not run) |
| `discovery::find_from` (extracted for tests) | src-tauri/src/discovery.rs:32 | src-tauri/src/discovery.rs (mod tests) | unit | tested (UDP responder on 127.0.0.1) |
| `discovery::parse_reply` | src-tauri/src/discovery.rs:78 | src-tauri/src/discovery.rs (mod tests) | unit | tested |
| `discovery::broadcast_targets` | src-tauri/src/discovery.rs:101 | src-tauri/src/discovery.rs (mod tests) | unit | tested (BSD `ifa_dstaddr` branch on macOS; Linux `ifa_ifu` branch CI only) |
| `download_extras::SUB_INDEX` / `SUB_MAX_ATTEMPTS` | src-tauri/src/download_extras.rs:19 | src-tauri/src/download_extras.rs (mod tests) | unit | tested |
| `download_extras::read_json` | src-tauri/src/download_extras.rs:25 | src-tauri/src/download_extras.rs (mod tests) | unit | tested via local_subtitles, update_details |
| `download_extras::sub_format` | src-tauri/src/download_extras.rs:31 | src-tauri/src/download_extras.rs (mod tests) | unit | tested |
| `download_extras::sub_file_name` | src-tauri/src/download_extras.rs:40 | src-tauri/src/download_extras.rs (mod tests) | unit | tested |
| `download_extras::fetch_subtitles` | src-tauri/src/download_extras.rs:55 | src-tauri/src/download_extras.rs (mod tests) | unit | tested (FakeServer) |
| `download_extras::fetch_subtitles` against Jellyfin 12 | src-tauri/src/download_extras.rs:55 | src-tauri/src/download_extras.rs (qa_server_sidecar_subtitles_are_saved) | integration (QA server) | tested |
| `download_extras::local_subtitles` | src-tauri/src/download_extras.rs:134 | src-tauri/src/download_extras.rs (mod tests) | unit | tested |
| `download_extras::subtitles_for` | src-tauri/src/download_extras.rs:152 | src-tauri/src/download_extras.rs (mod tests) | unit | tested |
| `download_extras::sub_add_commands` | src-tauri/src/download_extras.rs:168 | src-tauri/src/download_extras.rs (mod tests) | unit | tested |
| `download_extras::subtitles_settled` | src-tauri/src/download_extras.rs:194 | src-tauri/src/download_extras.rs (mod tests) | unit | tested |
| `download_extras::DETAIL_KEYS` | src-tauri/src/download_extras.rs:202 | src-tauri/src/download_extras.rs (mod tests) | unit | tested |
| `download_extras::update_details` | src-tauri/src/download_extras.rs:210 | src-tauri/src/download_extras.rs (mod tests) | unit | tested |
| `download_extras::replace_image` | src-tauri/src/download_extras.rs:244 | src-tauri/src/download_extras.rs (mod tests) | unit | tested via update_details |
| `download_extras::file_uri` | src-tauri/src/download_extras.rs:265 | src-tauri/src/download_extras.rs (mod tests) | unit | tested |
| `download_extras::reveal_targets` | src-tauri/src/download_extras.rs:281 | src-tauri/src/download_extras.rs (mod tests) | unit | tested |
| `download_extras::reveal` (empty and xdg-open fallback) | src-tauri/src/download_extras.rs:299 | src-tauri/src/download_extras.rs (mod tests) | unit | tested (fallback test macOS only; skipped where xdg-open exists) |
| `download_extras::reveal` (FileManager1 ShowItems over D-Bus) | src-tauri/src/download_extras.rs:305 | none | needs real Linux | untested: needs a session bus and a file manager; would open a window |
| `jellyfin::CLIENT_NAME` / `CLIENT_VERSION` | src-tauri/src/jellyfin.rs:4 | src-tauri/src/jellyfin.rs (mod tests) | unit | tested |
| `jellyfin::http` | src-tauri/src/jellyfin.rs:9 | src-tauri/src/jellyfin.rs (mod tests) | unit | tested (shared client, User-Agent) |
| `jellyfin::auth_header_anon` | src-tauri/src/jellyfin.rs:21 | src-tauri/src/jellyfin.rs (mod tests) | unit | tested |
| `jellyfin::auth_header` | src-tauri/src/jellyfin.rs:28 | src-tauri/src/jellyfin.rs (mod tests) | unit | tested |
| `jellyfin::post` | src-tauri/src/jellyfin.rs:33 | src-tauri/src/jellyfin.rs (mod tests) | unit | tested |
| `secret::SERVICE` / `ACCOUNT` / `PENDING_ACCOUNT` / `TARGET` / `APPLICATION` | src-tauri/src/secret.rs:37 | src-tauri/src/secret.rs (mod tests) | needs real Linux | CI only (not run on macOS) |
| `secret::LEGACY_SERVICE` (FellyJin invariant) | src-tauri/src/secret.rs:40 | src-tauri/src/secret.rs (mod tests) | needs real Linux | CI only (not run on macOS) |
| `secret::State` / `STATE` | src-tauri/src/secret.rs:53 | src-tauri/src/secret.rs (mod tests) | needs real Linux | CI only (not run on macOS); cache behaviour via token, backend_name, pending_revocation |
| `secret::reset_for_tests` (cfg test) | src-tauri/src/secret.rs:80 | src-tauri/src/test_support.rs (sandbox) | needs real Linux | CI only (not run on macOS) |
| `secret::state` | src-tauri/src/secret.rs:90 | src-tauri/src/secret.rs (mod tests) | needs real Linux | CI only (not run on macOS); via every public function |
| `secret::attrs` | src-tauri/src/secret.rs:100 | src-tauri/src/secret.rs (mod tests) | needs real Linux | CI only (not run on macOS) |
| `secret::search_attrs` | src-tauri/src/secret.rs:112 | src-tauri/src/secret.rs (mod tests) | needs real Linux | CI only (not run on macOS) |
| `secret::search_attrs_in` | src-tauri/src/secret.rs:116 | src-tauri/src/secret.rs (mod tests) | needs real Linux | CI only (not run on macOS) |
| `secret::label` | src-tauri/src/secret.rs:120 | src-tauri/src/secret.rs (mod tests) | needs real Linux | CI only (not run on macOS) |
| `secret::CONN` / `conn` | src-tauri/src/secret.rs:143 | src-tauri/src/secret.rs (mod tests) | needs real Linux | CI only (not run on macOS); via with_collection |
| `secret::with_collection` (connect failure) | src-tauri/src/secret.rs:156 | src-tauri/src/secret.rs (mod tests) | needs real Linux | CI only (not run on macOS); dead-bus path via every public function |
| `secret::with_collection` (stale-connection retry) | src-tauri/src/secret.rs:171 | none | needs real Linux | untested: needs a keyring daemon restarted mid-session |
| `secret::read` / `read_in` | src-tauri/src/secret.rs:184 | src-tauri/src/secret.rs (mod tests) | needs real Linux | CI only (dead bus); success path `#[ignore]`, opt-in AQUARIUM_TEST_REAL_DBUS=1 |
| `secret::write` | src-tauri/src/secret.rs:205 | src-tauri/src/secret.rs (writing_twice_overwrites_in_place) | needs real Linux | CI only (dead bus); overwrite-in-place `#[ignore]`, opt-in AQUARIUM_TEST_REAL_DBUS=1 |
| `secret::wipe` / `wipe_in` | src-tauri/src/secret.rs:229 | src-tauri/src/secret.rs (mod tests) | needs real Linux | CI only (dead bus); success path `#[ignore]`, opt-in AQUARIUM_TEST_REAL_DBUS=1 |
| `secret::cached_token` | src-tauri/src/secret.rs:251 | src-tauri/src/secret.rs (mod tests) | needs real Linux | CI only (not run on macOS); failed-lookup caching tested; keyring-hit and adopt-on-miss branches untested (would read the user's real token item) |
| `secret::adopt_legacy` (FellyJin invariant) | src-tauri/src/secret.rs:277 | src-tauri/src/secret.rs (a_fellyjin_item_is_adopted_and_the_old_one_removed) | needs real Linux | CI only (dead bus returns None); adoption itself `#[ignore]`, opt-in AQUARIUM_TEST_REAL_DBUS=1 |
| `secret::keyring_get` | src-tauri/src/secret.rs:288 | src-tauri/src/secret.rs (mod tests) | needs real Linux | CI only (not run on macOS); via token |
| `secret::keyring_set` | src-tauri/src/secret.rs:292 | src-tauri/src/secret.rs (mod tests) | needs real Linux | CI only (failure path via store, hydrate); success path untested (would write the user's real token item) |
| `secret::keyring_clear` | src-tauri/src/secret.rs:307 | src-tauri/src/secret.rs (mod tests) | needs real Linux | CI only (not run on macOS); via clear |
| `secret::hydrate` | src-tauri/src/secret.rs:320 | src-tauri/src/secret.rs (mod tests) | needs real Linux | CI only (no-keyring paths); migration into a real keyring untested |
| `secret::dehydrate` | src-tauri/src/secret.rs:367 | src-tauri/src/secret.rs (mod tests) | needs real Linux | CI only (not run on macOS) |
| `secret::redact_accounts` | src-tauri/src/secret.rs:381 | src-tauri/src/secret.rs (mod tests) | needs real Linux | CI only (not run on macOS); via hydrate |
| `secret::token` | src-tauri/src/secret.rs:393 | src-tauri/src/secret.rs (mod tests) | needs real Linux | CI only (not run on macOS) |
| `secret::store` | src-tauri/src/secret.rs:405 | src-tauri/src/secret.rs (mod tests) | needs real Linux | CI only (config.json fallback) |
| `secret::clear` | src-tauri/src/secret.rs:419 | src-tauri/src/secret.rs (mod tests) | needs real Linux | CI only (not run on macOS) |
| `secret::park_pending_revocation` | src-tauri/src/secret.rs:433 | src-tauri/src/secret.rs (mod tests) | needs real Linux | CI only (failure path); success untested |
| `secret::pending_revocation` | src-tauri/src/secret.rs:443 | src-tauri/src/secret.rs (mod tests) | needs real Linux | CI only (failed lookup cached) |
| `secret::clear_pending_revocation` | src-tauri/src/secret.rs:459 | src-tauri/src/secret.rs (mod tests) | needs real Linux | CI only (failed wipe) |
| `secret::backend_name` | src-tauri/src/secret.rs:472 | src-tauri/src/secret.rs (mod tests) | needs real Linux | CI only (not run on macOS) |
| `secret::slot` | src-tauri/src/secret.rs:490 | src-tauri/src/secret.rs (mod tests) | needs real Linux | CI only (not run on macOS) |
| `secret::store_account` | src-tauri/src/secret.rs:497 | src-tauri/src/secret.rs (mod tests) | needs real Linux | CI only (config.json fallback) |
| `secret::account_token` | src-tauri/src/secret.rs:513 | src-tauri/src/secret.rs (mod tests) | needs real Linux | CI only (config.json fallback) |
| `secret::clear_account` | src-tauri/src/secret.rs:527 | src-tauri/src/secret.rs (mod tests) | needs real Linux | CI only (config.json fallback) |
| `idle::BUS` / `PATH` / `TIMEOUT` / `GSM_*` | src-tauri/src/idle.rs:19 | src-tauri/src/idle.rs (mod tests) | needs real Linux | CI only (not run on macOS) |
| `idle::IdleInhibitor::new` | src-tauri/src/idle.rs:29 | src-tauri/src/idle.rs (mod tests) | needs real Linux | CI only (dead bus fails cleanly); round trip `#[ignore]`, opt-in AQUARIUM_TEST_REAL_DBUS=1 |
| `idle::IdleInhibitor::drop` | src-tauri/src/idle.rs:39 | src-tauri/src/idle.rs (inhibitor_cycles) | needs real Linux | `#[ignore]`, opt-in AQUARIUM_TEST_REAL_DBUS=1 |
| `idle::SuspendInhibitor::new` | src-tauri/src/idle.rs:65 | src-tauri/src/idle.rs (mod tests) | needs real Linux | CI only (dead bus fails cleanly); GNOME round trip `#[ignore]`; logind branch untested |
| `idle::SuspendInhibitor::drop` | src-tauri/src/idle.rs:90 | src-tauri/src/idle.rs (suspend_inhibitor_round_trip) | needs real Linux | `#[ignore]`, opt-in AQUARIUM_TEST_REAL_DBUS=1 |
| `config_load` (Tauri command: secret::hydrate(config::load())) | src-tauri/src/lib.rs:67 | none | needs real Linux | untested: lib.rs is Linux-only; both functions it calls are tested |
| `config_save` (Tauri command: config::merge(secret::dehydrate(cfg))) | src-tauri/src/lib.rs:75 | none | needs real Linux | untested: lib.rs is Linux-only; both functions it calls are tested |
| `app_info` (Tauri command: config::load, config::downloads_dir, secret::backend_name, jellyfin::CLIENT_VERSION) | src-tauri/src/lib.rs:168 | none | needs real Linux | untested: lib.rs is Linux-only; the functions it calls are tested |
| `jf_discover` (Tauri command: discovery::find, 1600 ms) | src-tauri/src/lib.rs:215 | none | needs real Linux | untested: lib.rs is Linux-only; find_from is tested |
| `download_fetch_subtitles` (Tauri command: download_extras::fetch_subtitles) | src-tauri/src/lib.rs:741 | none | needs real Linux | untested: lib.rs is Linux-only; fetch_subtitles is tested |
| `download_update_details` (Tauri command: download_extras::update_details) | src-tauri/src/lib.rs:752 | none | needs real Linux | untested: lib.rs is Linux-only; update_details is tested |
| `downloads_reveal` (Tauri command: download_extras::reveal) | src-tauri/src/lib.rs:763 | none | needs real Linux | untested: lib.rs is Linux-only |
| `progress_sync` (Tauri command: config::load, secret::token, config::device_id, progress::sync) | src-tauri/src/lib.rs:794 | none | needs real Linux | untested: lib.rs is Linux-only; the functions it calls are tested |
| `progress_store_local` (Tauri command: progress::store_local) | src-tauri/src/lib.rs:815 | none | needs real Linux | untested: lib.rs is Linux-only; store_local is tested |
| `progress_pending` (Tauri command: progress::pending_count) | src-tauri/src/lib.rs:820 | none | needs real Linux | untested: lib.rs is Linux-only; pending_count is tested |
| `progress_pending_ids` (Tauri command: progress::pending_item_ids) | src-tauri/src/lib.rs:825 | none | needs real Linux | untested: lib.rs is Linux-only; pending_item_ids is tested |
| `run` (startup: config::migrate_legacy_dirs, config::harden_data_dir) | src-tauri/src/lib.rs:830 | none | needs real Linux | untested: lib.rs is Linux-only; both functions are tested |
