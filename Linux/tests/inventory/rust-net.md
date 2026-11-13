| Function | Source | Test file | Kind | Status |
|---|---|---|---|---|
| `PROBE_TIMEOUT` (const) | src-tauri/src/server.rs:22 | src-tauri/src/server.rs `tests` | unit | untested: a 5 s timeout; no test waits that long |
| `err` | src-tauri/src/server.rs:24 | src-tauri/src/server.rs `tests` | unit | tested via every error-kind prefix assertion (request, probe, login, ping) |
| `offline_err` | src-tauri/src/server.rs:29 | src-tauri/src/server.rs `tests` | unit | tested via probe_of_an_address_nobody_answers_is_offline_and_logged |
| `normalize` | src-tauri/src/server.rs:40 | src-tauri/src/server.rs `tests` | unit | tested |
| `is_secure` | src-tauri/src/server.rs:81 | src-tauri/src/server.rs `tests` | unit | tested |
| `public_info` | src-tauri/src/server.rs:87 | src-tauri/src/server.rs `tests` | unit | tested via probe / verify |
| `str_field` | src-tauri/src/server.rs:108 | src-tauri/src/server.rs `tests` | unit | tested |
| `probe` | src-tauri/src/server.rs:121 | src-tauri/src/server.rs `tests`, `qa_tests` | unit | tested; one case expected failure (bug): probe_refuses_a_typed_non_http_scheme_as_a_config_error |
| `probe` (live server) | src-tauri/src/server.rs:121 | src-tauri/src/server.rs `qa_tests` | integration (QA server) | tested |
| `VERIFIED` (static) | src-tauri/src/server.rs:154 | src-tauri/src/server.rs `tests` | unit | tested via the_identity_is_checked_once_per_session |
| `reset_for_tests` | src-tauri/src/server.rs:158 | src-tauri/src/test_support.rs | unit | tested via sandbox() in every test |
| `ensure_verified` | src-tauri/src/server.rs:169 | src-tauri/src/server.rs `tests` | unit | tested |
| `verify` | src-tauri/src/server.rs:176 | src-tauri/src/server.rs `tests` | unit | tested via ensure_verified / request / ping (pinning, mismatch, no id, cache) |
| `forget_verification` | src-tauri/src/server.rs:209 | src-tauri/src/server.rs `tests` | unit | tested via switching_accounts_moves_the_token_and_rechecks_the_identity, logout_revokes_the_token_and_clears_everything_local |
| `configured_server` | src-tauri/src/server.rs:214 | src-tauri/src/server.rs `tests` | unit | tested via request_without_a_server_is_a_config_error, a_tampered_server_address_in_the_config_is_refused |
| `origin` | src-tauri/src/server.rs:227 | src-tauri/src/server.rs `tests` | unit | tested via same_origin |
| `same_origin` | src-tauri/src/server.rs:242 | src-tauri/src/server.rs `tests` | unit | tested |
| `is_session_origin` | src-tauri/src/server.rs:249 | src-tauri/src/server.rs `tests`; src-tauri/src/downloads.rs `tests` | unit | tested |
| `request` | src-tauri/src/server.rs:256 | src-tauri/src/server.rs `tests` | unit | tested |
| `request` (live server) | src-tauri/src/server.rs:256 | src-tauri/src/server.rs `qa_tests` | integration (QA server) | tested |
| `get_bytes` | src-tauri/src/server.rs:289 | src-tauri/src/server.rs `tests`, `qa_tests` | unit | tested |
| `base64` | src-tauri/src/server.rs:311 | src-tauri/src/server.rs `tests` | unit | tested |
| `image` | src-tauri/src/server.rs:333 | src-tauri/src/server.rs `tests` | unit | tested |
| `image` (live trickplay tile) | src-tauri/src/server.rs:333 | src-tauri/src/server.rs `qa_tests` | integration (QA server) | tested |
| `BITRATE_TEST_TIMEOUT` (const) | src-tauri/src/server.rs:381 | src-tauri/src/server.rs `tests` | unit | untested: a 4 s timeout; no test waits that long |
| `bitrate_test` | src-tauri/src/server.rs:399 | src-tauri/src/server.rs `tests`, `qa_tests` | unit | tested |
| `warm` | src-tauri/src/server.rs:438 | src-tauri/src/server.rs `tests`, `qa_tests` | unit | tested |
| `ping` | src-tauri/src/server.rs:491 | src-tauri/src/server.rs `tests`, `qa_tests` | unit | tested (fast-failure retry, slow failure not repeated, no cache, identity) |
| `login` | src-tauri/src/server.rs:527 | src-tauri/src/server.rs `tests` | unit | tested |
| `login` (live server) | src-tauri/src/server.rs:527 | src-tauri/src/server.rs `qa_tests` | integration (QA server) | tested |
| `login_quick_connect` | src-tauri/src/server.rs:559 | src-tauri/src/server.rs `tests` | unit | tested |
| `install` | src-tauri/src/server.rs:587 | src-tauri/src/server.rs `tests` | unit | tested via login / login_quick_connect |
| `account_key` | src-tauri/src/server.rs:646 | src-tauri/src/server.rs `tests` | unit | tested |
| `current_key` | src-tauri/src/server.rs:652 | src-tauri/src/server.rs `tests` | unit | tested via an_install_from_before_accounts_gets_a_key_and_shows_on_the_list |
| `stash_current` | src-tauri/src/server.rs:665 | src-tauri/src/server.rs `tests` | unit | tested via a_second_sign_in_keeps_the_first_accounts_token_in_its_own_slot |
| `remember_server` | src-tauri/src/server.rs:686 | src-tauri/src/server.rs `tests` | unit | tested |
| `accounts` | src-tauri/src/server.rs:703 | src-tauri/src/server.rs `tests` | unit | tested |
| `switch_account` | src-tauri/src/server.rs:730 | src-tauri/src/server.rs `tests` | unit | tested |
| `forget_account` | src-tauri/src/server.rs:764 | src-tauri/src/server.rs `tests` | unit | tested |
| `public_request` | src-tauri/src/server.rs:789 | src-tauri/src/server.rs `tests`, `qa_tests` | unit | tested |
| `revoke` | src-tauri/src/server.rs:818 | src-tauri/src/server.rs `tests` | unit | tested via logout / forget_account / retry_pending_revocation |
| `logout` | src-tauri/src/server.rs:842 | src-tauri/src/server.rs `tests` | unit | tested |
| `logout` (live revocation) | src-tauri/src/server.rs:842 | src-tauri/src/server.rs `qa_tests` | integration (QA server) | tested |
| `retry_pending_revocation` | src-tauri/src/server.rs:879 | src-tauri/src/server.rs `tests` | unit | tested |
| `revocation_pending` | src-tauri/src/server.rs:895 | src-tauri/src/server.rs `tests` | unit | tested |
| `DownloadRequest` (struct, serde defaults) | src-tauri/src/downloads.rs:13 | src-tauri/src/downloads.rs `tests` | unit | tested via every transfer test; its IPC deserialisation is not exercised |
| `RUN` / `CANCEL` / `PAUSE` (consts) | src-tauri/src/downloads.rs:34 | src-tauri/src/downloads.rs `tests` | unit | tested via cancelling_throws_away_what_arrived, pausing_keeps_the_part_and_carrying_on_asks_for_the_rest_with_range |
| `DlManager` (struct) | src-tauri/src/downloads.rs:41 | src-tauri/src/downloads.rs `tests` | unit | tested |
| `MAX_AUTO_RETRIES` / `RETRY_DELAYS` / `PROGRESS_WORTH_RESETTING` (consts) | src-tauri/src/downloads.rs:55 | src-tauri/src/downloads.rs `tests` | unit | tested via failures_back_off_then_stop, a_failure_says_whether_and_when_it_will_be_tried_again |
| `STALL_POLL` (const) | src-tauri/src/downloads.rs:61 | src-tauri/src/downloads.rs `tests` | unit | tested via pausing_keeps_the_part_and_carrying_on_asks_for_the_rest_with_range (pause seen on the next poll) |
| `STALL_TIMEOUT` (const) | src-tauri/src/downloads.rs:63 | src-tauri/src/downloads.rs `tests` | unit | untested: the stall branch needs 90 s of server silence and has no hook; its message is covered by only_trouble_that_can_pass_is_retried_unasked |
| `item_dir` | src-tauri/src/downloads.rs:72 | src-tauri/src/downloads.rs `tests` | unit | tested |
| `RESERVED_FILE_NAMES` (const) | src-tauri/src/downloads.rs:86 | src-tauri/src/downloads.rs `tests` | unit | tested via file_names_cannot_replace_the_apps_own_files |
| `COMPUTED_PATHS` (const) | src-tauri/src/downloads.rs:91 | src-tauri/src/downloads.rs `tests` | unit | tested via stored_paths_are_ignored |
| `check_file_name` | src-tauri/src/downloads.rs:97 | src-tauri/src/downloads.rs `tests` | unit | tested |
| `read_meta` | src-tauri/src/downloads.rs:112 | src-tauri/src/downloads.rs `tests` | unit | tested |
| `refresh_paths` | src-tauri/src/downloads.rs:120 | src-tauri/src/downloads.rs `tests` | unit | tested |
| `free_space` | src-tauri/src/downloads.rs:153 | src-tauri/src/downloads.rs `tests` | unit | tested |
| `write_meta` | src-tauri/src/downloads.rs:177 | src-tauri/src/downloads.rs `tests` | unit | tested via start / the terminal states |
| `emit` | src-tauri/src/downloads.rs:185 | src-tauri/src/downloads.rs `tests` | unit | tested via the download-progress payload assertions |
| `DlManager::cancel` | src-tauri/src/downloads.rs:190 | src-tauri/src/downloads.rs `tests` | unit | tested |
| `DlManager::pause` | src-tauri/src/downloads.rs:199 | src-tauri/src/downloads.rs `tests` | unit | tested |
| `DlManager::sync_keep_awake` | src-tauri/src/downloads.rs:208 | src-tauri/src/downloads.rs `tests` | unit | tested (inhibitor refused on this host; taking a real one needs real Linux with a session bus) |
| `DlManager::is_active` | src-tauri/src/downloads.rs:225 | src-tauri/src/downloads.rs `tests` | unit | tested |
| `DlManager::active_count` | src-tauri/src/downloads.rs:231 | src-tauri/src/downloads.rs `tests` | unit | tested |
| `DlManager::start` | src-tauri/src/downloads.rs:235 | src-tauri/src/downloads.rs `tests`, `qa_tests` | unit | tested |
| `DlManager::start` (live static and transcoded download) | src-tauri/src/downloads.rs:235 | src-tauri/src/downloads.rs `qa_tests` | integration (QA server) | tested |
| `is_original_url` | src-tauri/src/downloads.rs:370 | src-tauri/src/downloads.rs `tests` | unit | tested |
| `is_short` | src-tauri/src/downloads.rs:378 | src-tauri/src/downloads.rs `tests` | unit | tested |
| `is_retryable` | src-tauri/src/downloads.rs:385 | src-tauri/src/downloads.rs `tests` | unit | tested |
| `after_failure` | src-tauri/src/downloads.rs:396 | src-tauri/src/downloads.rs `tests` | unit | tested |
| `mkv_duration_secs` | src-tauri/src/downloads.rs:426 | src-tauri/src/downloads.rs `tests`, `qa_tests` | unit | tested |
| `mkv_duration_from` | src-tauri/src/downloads.rs:444 | src-tauri/src/downloads.rs `tests` | unit | tested |
| `find_all` | src-tauri/src/downloads.rs:468 | src-tauri/src/downloads.rs `tests` | unit | tested |
| `read_vint` | src-tauri/src/downloads.rs:473 | src-tauri/src/downloads.rs `tests` | unit | tested |
| `read_uint_element` | src-tauri/src/downloads.rs:488 | src-tauri/src/downloads.rs `tests` | unit | tested |
| `strip_api_key` | src-tauri/src/downloads.rs:500 | src-tauri/src/downloads.rs `tests` | unit | tested |
| `auth_header_now` | src-tauri/src/downloads.rs:519 | src-tauri/src/downloads.rs `tests` | unit | tested via a_static_download_is_fetched_whole_with_the_header_and_its_posters, without_a_token_the_request_goes_out_with_no_credentials |
| `fetch_image` | src-tauri/src/downloads.rs:530 | src-tauri/src/downloads.rs `tests` | unit | tested via posters_already_on_disk_are_not_fetched_again_and_a_missing_one_is_no_failure |
| `run_download` | src-tauri/src/downloads.rs:543 | src-tauri/src/downloads.rs `tests`, `qa_tests` | unit | tested via start / restart (Range resume, restart over, integrity, errors, cancel, pause, progress); the 90 s stall branch untested |
| `restart` | src-tauri/src/downloads.rs:716 | src-tauri/src/downloads.rs `tests` | unit | tested |
| `resume_interrupted` | src-tauri/src/downloads.rs:749 | src-tauri/src/downloads.rs `tests` | unit | tested |
| `list` | src-tauri/src/downloads.rs:783 | src-tauri/src/downloads.rs `tests`, `qa_tests` | unit | tested |
| `set_watch_state` | src-tauri/src/downloads.rs:823 | src-tauri/src/downloads.rs `tests` | unit | tested |
| `delete` | src-tauri/src/downloads.rs:838 | src-tauri/src/downloads.rs `tests`, `qa_tests` | unit | tested |
