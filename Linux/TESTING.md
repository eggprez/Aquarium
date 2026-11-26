# Testing the Linux app

Every path here is relative to `Linux/`. Four layers:

| Layer | Where | Runs on | Command |
|---|---|---|---|
| TypeScript unit | `tests/unit/` | any OS (Node 20+) | `npm run test:unit` (with `tests/dom`) |
| TypeScript DOM | `tests/dom/` | any OS | `npm run test:unit` |
| TypeScript integration | `tests/integration/` | any OS, needs the QA Jellyfin server (and, for `seerr.test.ts`, the stand-in Seerr) | `npm run test:integration` |
| Rust, platform-neutral modules | in-module `#[cfg(test)]` | any Unix | `cargo test --manifest-path src-tauri/portable-tests/Cargo.toml` |
| Rust, whole crate | in-module `#[cfg(test)]` | Linux only (GTK, WebKitGTK, libmpv, D-Bus) | `npm run build && cd src-tauri && cargo test` |
| End-to-end smoke | `.github/workflows/linux-tests.yml` job `smoke` | ubuntu CI under Xvfb | CI only |
| Manual | the checklist below | a real GNOME/Wayland desktop | by hand |

`npm test` runs all three TypeScript layers; `npm run coverage` adds a v8 coverage report in
`coverage/`. CI (`.github/workflows/linux-tests.yml`, on pushes and PRs touching `Linux/**`) runs
the TypeScript suites with coverage, the whole Rust crate under Xvfb, the portable crate, and the
best-effort smoke run.

## How the harness works

- **Tauri bridge.** `tests/setup.ts` replaces `@tauri-apps/api/core` and `/event` with the
  in-memory bridge in `tests/helpers/tauri.ts` (`onInvoke`, `mockJellyfin`, `emitEvent`,
  `invokeCalls`, `signIn`, ...). An `invoke` nobody answered rejects with
  `unmocked invoke: <cmd>`, so no test reaches a backend by accident. The mock factories return the
  setup file's own instance of the bridge, so handlers survive `vi.resetModules()`.
- **jsdom.** Everything runs in jsdom with `fake-indexeddb`; layout, canvas and media queries are
  stubbed. Nothing here proves how WebKitGTK draws.
- **QA server.** `tests/helpers/qa.ts` (TypeScript) and `src-tauri/src/test_support.rs` (Rust) find
  the QA Jellyfin server (`AQUARIUM_QA_SERVER`, default `http://127.0.0.1:8196`) and sign in as
  `suite-linux` from `suite-accounts.txt` in the QA folder (`AQUARIUM_QA_DIR`, default
  `~/Library/Application Support/AquariumQA` or `$XDG_DATA_HOME/AquariumQA`). No credential is in
  the repository. When the server is unreachable, or `AQUARIUM_QA_SKIP=1`, every integration suite
  skips. Only the `suite-linux` account is ever written to; tests restore what they change. After a
  run, `python3 -I suite-reset.py suite-linux` in the QA folder puts the account back on its
  baseline exactly (a few things, such as last-played dates, can't be restored through the API).
- **Stand-in Seerr.** The requests features talk to a Seerr server, and the QA folder has none, so
  the tests use `../Aquarium/Tools/seerr-mock.py` (one stand-in for both apps, built from Seerr
  3.5.0's source). Start it with `python3 -I ../Aquarium/Tools/seerr-mock.py`: it listens on
  `127.0.0.1:8197` and signs users in through the QA Jellyfin on 8196, by Quick Connect, the way
  Seerr does. `AQUARIUM_QA_SEERR` names another address. `tests/helpers/seerr-qa.ts` (TypeScript)
  signs in to it as `suite-linux` and answers the `seerr_*` bridge commands with real requests;
  `seerr.rs`'s `qa_tests` (Rust) drive the real back end against it. Both skip when it, or the QA
  Jellyfin, is not running, and both `POST /__test/reset` before and after, so run them one at a
  time. The DOM and unit tests need neither: they answer `seerr_request` in memory.
- **Rust sandbox.** `test_support.rs` points `HOME` and the XDG folders at a temporary folder before
  any test runs and points D-Bus at a socket that does not exist, so no test can touch the real
  config, downloads or keyring. `sandbox()` serialises the tests that use them. `FakeServer` is a
  scripted local Jellyfin. Tests that need a real session bus are `#[ignore]` and run with
  `AQUARIUM_TEST_REAL_DBUS=1 cargo test -- --ignored <name>`.
- **portable-tests.** `src-tauri/portable-tests/` compiles config, discovery, download_extras,
  downloads, jellyfin, prefs, progress, seerr, server and test_support from the app's own source files
  (by `#[path]`), so their tests run on a Mac. On macOS `secret` and `idle` are in-memory doubles
  (`portable-tests/stubs.rs`); the real ones are tested on Linux.

## Expected failures (known bugs)

Each is a test asserting the correct behaviour, marked `it.fails` or `#[ignore = "bug: ..."]` with a
`BUG:` comment. When a bug is fixed the test starts failing as "expected to fail but passed":
remove the marker then.

None at the moment. The 17 the suite found when it was written were fixed on 2026-11-13 and their
tests now pass as normal ones; `git log --grep "Linux:"` has one commit per fix. Two of them changed
behaviour that only the manual checklist can confirm (items 23 and 24).

## TypeScript coverage

From `npx vitest run --coverage` (all layers, QA server reachable):

| File | Lines % | Functions % | Branches % |
|---|---|---|---|
| src/adaptive.ts | 100 | 100 | 96.46 |
| src/api.ts | 100 | 100 | 99.39 |
| src/audio.ts | 100 | 100 | 97.68 |
| src/blurhash.ts | 100 | 100 | 100 |
| src/cache.ts | 100 | 94.44 | 100 |
| src/channels-panel.ts | 100 | 100 | 93.93 |
| src/icons.ts | 100 | 100 | 100 |
| src/iptv.ts | 100 | 100 | 97.98 |
| src/lineup.ts | 100 | 100 | 99.07 |
| src/main.ts | 99.87 | 100 | 94.38 |
| src/musicApi.ts | 100 | 100 | 99.08 |
| src/playback.ts | 100 | 100 | 97.2 |
| src/prefetch.ts | 100 | 100 | 96.42 |
| src/scroll.ts | 100 | 100 | 95.55 |
| src/smartPlaylists.ts | 100 | 100 | 100 |
| src/spatial.ts | 100 | 100 | 100 |
| src/stations.ts | 100 | 100 | 96.51 |
| src/theme.ts | 100 | 100 | 100 |
| src/ui.ts | 100 | 100 | 99.41 |
| src/views/books.ts | 100 | 100 | 95.6 |
| src/views/downloads.ts | 99.81 | 100 | 93.87 |
| src/views/favorites.ts | 100 | 100 | 96.47 |
| src/views/home.ts | 100 | 100 | 98.3 |
| src/views/item.ts | 100 | 100 | 95.54 |
| src/views/library.ts | 100 | 100 | 98.13 |
| src/views/livetv.ts | 100 | 100 | 95.2 |
| src/views/login.ts | 100 | 100 | 95.75 |
| src/views/music.ts | 99.88 | 100 | 95.64 |
| src/views/musicCommon.ts | 100 | 100 | 96.45 |
| src/views/musicDownloads.ts | 100 | 100 | 90.69 |
| src/views/musicPlayer.ts | 100 | 100 | 96.71 |
| src/views/settings.ts | 100 | 100 | 97.84 |
| **all** | 99.96 | 99.91 | 96.62 |

`src/seerr.ts`, `src/views/requests.ts` and `src/views/seerrSettings.ts` (the Seerr requests
features, added 2026-11-16) are not in the table: they and their tests were written on a machine
with no Node or Cargo and have not been run or measured yet. The same goes for the Rust counts
below for `seerr` and the three new `secret` tests. Run the suites and bring both tables up to date.

`public/theme-boot.js` (the legacy `fellyjin` localStorage carry-over) is tested by evaluating the
real file in `tests/unit/theme.test.ts`; v8 coverage does not see it.

## Rust

Test functions per module (`#[test]`/`#[tokio::test]`). "Portable" modules run on any Unix through
`portable-tests`; the rest compile only on Linux and run only in CI.

| Module | Tests | Runs |
|---|---|---|
| config, discovery, download_extras, downloads, jellyfin, prefs, progress, seerr, server, test_support | 267 (1 ignored) | portable and CI |
| secret, idle | 21 (the real-keyring ones opt-in) | CI only |
| mpv, audio, player, surface, video_thread, render, gl, egl, wl, mpris, power, network, theme, lib, main | 167 | CI only |

Rust line coverage is not measured yet. The GTK/libmpv modules' pure logic was extracted into small
functions (geometry, argument building, status mapping, test-hook parsing) that the tests drive; the
rest needs a compositor, a GPU or a session bus and is on the manual checklist.

## Manual checklist (real desktop only)

Run the release binary (`./build-deb.sh`, or `npx tauri build`) by absolute path, with
`AQUARIUM_MPV_CONFIG=<copy of src-tauri/mpv-config with mute=yes added>`. A test instance takes the
MPRIS name `org.mpris.MediaPlayer2.aquarium.instance<pid>`, so the user's own instance is left
alone; end it with `kill <pid>`, never MPRIS Quit. Look in `~/.local/share/aquarium/debug.log`.

1. **Wayland subsurface video.** `AQUARIUM_SURFACE_TEST=1 AQUARIUM_TEST_PLAY=<file>`. stderr says
   "video thread up, EGL ..." and "EGL window on wl_surface#...". The picture sits above the 72 css
   player bar, never over it; the UI stays smooth (GTK's frame clock never freezes).
2. **Fullscreen and bar reveal.** Add `AQUARIUM_TEST_SEQUENCE="7:fs,11:bar,15:nobar,18:nofs"`, three
   runs. At `fs` the video covers the window and the pointer hides; at `bar` the bottom 72 css is
   cropped without the picture moving, and the bar is clickable, every run; at `nofs` back to
   windowed with the bar reserved. Moving the pointer in and out of the window does not loop the
   reveal/hide.
3. **Session hand-off.** `"5:fs,8:stop,10:play"`: the new session starts windowed, no full-window
   frame over the bar.
4. **Out of sight.** `"6:min,14:unmin"` with `AQUARIUM_SURFACE_TEST=1`: "surface out of sight,
   skipping rendering", then "back in sight after N skipped frames"; no frozen picture.
5. **Picture in picture.** `"8:pip,15:nopip"`: a 480x270 window "Aquarium — Picture in Picture",
   playback continues at the same position, returning restores the geometry. Closing the PiP window
   from its title bar brings the picture back.
6. **GLArea and X11.** `AQUARIUM_VIDEO_BACKEND=gl`, and separately an X11 session: playback works and
   quitting mid-playback does not abort with an epoxy assertion.
7. **Hardware decode and HDR.** Hardware decoding on; play H.264, HEVC and an HDR10 file:
   "player: hwdec-current=vaapi", "player: vo-configured=true", Stream info agrees; HDR is
   tone-mapped, not black or washed out.
8. **Replay.** `AQUARIUM_TEST_REPLAY=1`: restarts at +5 s, one audio stream, no black window.
9. **Battery rendering.** Automatic, then `powerprofilesctl set power-saver` mid-playback:
   "power: low-power true", "player: battery rendering on"; back again gives "off".
10. **MPRIS.** `playerctl -l` lists aquarium. Episode metadata reads artist "Series S01E02", title the
    episode; play/pause key toggles; `playerctl position 30` seeks; volume maps to the app's.
    Music: album, art, lock-screen controls, Next moves the queue. The GNOME media widget shows it.
11. **Idle and suspend inhibit.** While playing, `gnome-session-inhibit --list` shows an inhibitor;
    pause releases it within about 2 s; resume takes it again; the end of the file releases it.
    Downloading with "Keep the laptop awake" shows a logind inhibitor in `systemd-inhibit --list`.
    Suspend and resume mid-playback: the app comes back online without a false "offline".
12. **Secret Service.** After sign-in the token is in the keyring (Seahorse) and not in
    `~/.config/aquarium/config.json`. With the keyring locked, launch prompts once; sidebar
    refreshes don't prompt again. An item stored by the old FellyJin build is adopted and the user
    stays signed in. Sign-out removes the token and `mpv-logs/`.
13. **Theme.** Appearance Auto: toggling GNOME's dark style flips the app live.
14. **Metered network.** Marking the Wi-Fi metered holds downloads ("network: metered=true");
    unmarking resumes them.
15. **.deb install and upgrade.** `./bump-version.sh && ./build-deb.sh`, then the user runs
    `./reinstall.sh --no-build` (needs sudo). `/usr/bin/aquarium` runs, the icon shows in the shell
    and in MPRIS, uosc loads on the first menu. Upgrading over the previous version keeps sign-in,
    downloads, settings and window size. `apt remove` leaves the user's config.
16. **Touch.** Tap shows the controls; double-tap the left or right third skips; pinch switches
    Fill/Fit; hold plays at 2x until release. The first tap must not panic (also
    `AQUARIUM_TEST_INPUT=1`).
17. **Keyboard and mouse over video.** Arrows and Shift+arrows, wheel volume, sideways wheel and
    touchpad scrub, back/forward mouse buttons, right-click menu.
18. **Window size.** Set 1300x850, quit and relaunch five times: the size holds. Quit in
    fullscreen playback: the next launch is not fullscreen.
19. **Quit with downloads running.** The prompt appears over the video; Cancel keeps the window,
    Quit closes it.
20. **Music and audiobooks.** Albums play gaplessly and play counts reach the server; quitting
    mid-audiobook saves the resume point on the server.
21. **Live TV custom playlist with a User-Agent.** Plays after `resolve_stream`; no Authorization
    header reaches the provider host.
22. **Power use.** On a screen that stays visible (Home, Music, the player bar), `top` shows the
    WebKit web process near idle: no infinite CSS animation repaints the window.
23. **Server subtitle files.** A file with sidecar subtitles (the QA server's FX Sidecar Subs)
    direct-plays and its subtitles are in mpv's list, the default one showing; a forced transcode of
    FX Long Remux Multitrack ("Try a smaller stream", the quality menu) has no subtitle burnt in and
    its text subtitles can be switched and turned off. debug.log has no "player: sub-add failed",
    and playback does not stall while they load.
24. **Smaller stream keeps the audio track.** On FX Long Remux Multitrack pick the French track,
    then a lower quality: the transcode plays French (the stream address says
    `AudioStreamIndex=3`).
25. **Seerr: connecting.** With `python3 -I ../Aquarium/Tools/seerr-mock.py` running (or a real
    Seerr 3.4+ beside the Jellyfin server): Settings → Requests → Connect to Seerr…, type
    `127.0.0.1:8197`. The dialog stops at "This connection isn't encrypted" (the stand-in is plain
    http); Connect Anyway signs in with no password typed, a toast says where Requests is, and the
    sidebar gains Requests. In Seahorse there is an item `seerr-session:<account>` for
    `dev.aquarium.app`; `~/.config/aquarium/config.json` has no `connect.sid` value in it, and
    `debug.log` has none either. Against an https Seerr the warning step is skipped. Against an
    https address with a certificate the system does not trust (a self-signed one), a bare host
    name is refused with "That server's certificate couldn't be verified…" and is not retried
    over http. With Quick Connect turned off in Jellyfin's dashboard, the dialog asks for the
    Jellyfin user name and password instead and connects with them.
26. **Seerr: requesting.** The sidebar entry and the page are called Seerr. `curl -X POST
    '127.0.0.1:8197/__test/discover/slow?seconds=8'`, clear the cache, open it: Your Requests
    arrives first and every row below stands as a placeholder under its heading until it lands;
    the foot credits Seerr and TMDB (`…/slow?seconds=0` after). The page shows Your Requests as one carousel of posters, then
    Trending and the other rows of posters (they load through `<seerr>/imageproxy/…`; nothing is
    fetched from `image.tmdb.org`: check with `ss -tp` or the stand-in's `GET /__test/state`
    call list). Seerr serves them only with its Cache Images setting on: `curl -X POST
    127.0.0.1:8197/__test/images/off`, reopen Requests: the "No posters from Seerr" notice, and
    Settings → Requests says Posters Off; `…/images/on`, reopen: the notice goes and every poster
    loads. Open The Matrix: Request, the toast,
    "Waiting for approval", Cancel Request and its confirmation. Open a show: untick a season, the
    button counts the rest, the request names only those. `curl -X POST
    127.0.0.1:8197/__test/approve/1`, reopen the page: "On its way". `curl -X POST
    127.0.0.1:8197/__test/expire`, then open any title: it loads (one quiet Quick Connect in the
    stand-in's call list) and Settings still says the session is in the keyring. Stop the QA
    Jellyfin's Quick Connect, expire again: Settings → Requests shows Session "Run out" and
    Reconnect, and the sidebar entry goes.
27. **Seerr: in the library.** A film's, a show's and an episode's page end with "Like This,
    Not in Your Library" under "More like this" (an episode's is its show's). Search for a title the library lacks: "Not in Your Library"
    appears under "No results" about half a second after typing stops, and typing on never
    flickers a stale row. A show with fewer seasons here than exist (the QA library has some)
    has the "N more seasons exist" banner under its hero, and Request… opens its request page. A
    collection with a TMDB id whose films aren't all here has "Missing From This Collection"
    under its grid. With Seerr disconnected none of these are drawn and the pages look as before.
28. **Seerr: leaving.** Disconnect from Seerr… asks first; afterwards the keyring item is gone,
    the sidebar entry is gone, and the stand-in's `/__test/state` shows one session fewer.
    Connect again, then sign out of Jellyfin (Settings → Server → Sign out): the keyring item is
    gone and the stand-in was sent `POST /api/v1/auth/logout`. With two accounts on the device,
    each has its own Seerr connection or none, and switching accounts switches Requests with it.
    None of the Seerr screens runs a CSS animation that never ends (item 22).
29. **Wordmark.** The sidebar, the sign-in card and Settings → About show "aquarium" in heavy
    lowercase with a purple bubble where the i's dot would be, sitting just above the stem. On a
    desktop with no rounded font it is Inter; the bubble should still clear the r and u. Orca reads
    "Aquarium" once.
30. **Delete from Server.** Needs an account that may delete on Jellyfin, a real Seerr with Radarr
    and Sonarr, and titles to lose. Right-click a film Radarr looks after: "Delete from Server…" is
    last, in red; the dialog offers "Remove from Radarr with Seerr" and "Delete File from Jellyfin".
    Seerr's way takes the film out of Radarr with its file and clears its request; Jellyfin's
    deletes the file and the page is drawn again without the film. A show offers Sonarr; a season
    or an episode only Jellyfin. With Seerr disconnected, no Manage Requests, or a title Seerr
    never sent to Radarr/Sonarr, only Jellyfin is offered; with no right on either, no entry.

## Function inventory

One row per function, method, Tauri command and constant with logic. Kind: `unit`, `dom`,
`integration (QA server)`, `needs real Linux`. Status: `tested`, `tested via <caller>`,
`expected failure (bug)`, `CI only (not run on macOS)`, or `untested: <reason>`.

### src/api.ts

| Function | Source | Test file | Kind | Status |
|---|---|---|---|---|
| CLIENT_VERSION | src/api.ts:11 | tests/unit/api-media.test.ts | unit | tested |
| getSession | src/api.ts:35 | tests/unit/api-session.test.ts; tests/integration/smoke.test.ts | unit, integration (QA server) | tested |
| splitError | src/api.ts:47 | tests/unit/api-session.test.ts | unit | tested via api, probeServer, login |
| announceIdentityChange | src/api.ts:63 | tests/unit/api-session.test.ts | unit | tested via api, checkOnline |
| isOffline | src/api.ts:73 | tests/unit/api-session.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested |
| setOffline | src/api.ts:77 | tests/unit/api-session.test.ts | unit | tested via api, checkOnline |
| checkOnline | src/api.ts:84 | tests/unit/api-session.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested |
| confirmOffline | src/api.ts:112 | tests/unit/api-session.test.ts | unit | tested via api |
| getConfig | src/api.ts:122 | tests/unit/api-session.test.ts | unit | tested |
| loadConfig | src/api.ts:126 | tests/unit/api-session.test.ts; all integration suites (qaApi) | unit, integration (QA server) | tested |
| saveConfig | src/api.ts:144 | tests/unit/api-session.test.ts; tests/integration/api-state.test.ts | unit, integration (QA server) | tested |
| api | src/api.ts:152 | tests/unit/api-session.test.ts; tests/integration/api-browse.test.ts (real 401 and 404) | unit, integration (QA server) | tested |
| probeServer | src/api.ts:196 | tests/unit/api-session.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested |
| login | src/api.ts:209 | tests/unit/api-session.test.ts | unit | tested (sign-in itself is server.rs, Rust suites) |
| logout | src/api.ts:237 | tests/unit/api-session.test.ts | unit | tested |
| discoverServers | src/api.ts:260 | tests/unit/api-session.test.ts | unit | tested (LAN discovery is off on the QA server) |
| publicCall | src/api.ts:268 | tests/unit/api-session.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested via publicUsers, quickConnect* |
| publicUsers | src/api.ts:287 | tests/unit/api-session.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested |
| quickConnectEnabled | src/api.ts:299 | tests/unit/api-session.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested |
| quickConnectInitiate | src/api.ts:319 | tests/unit/api-session.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested |
| quickConnectState | src/api.ts:334 | tests/unit/api-session.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested |
| loginWithQuickConnect | src/api.ts:342 | tests/unit/api-session.test.ts | unit | tested (the exchange is server.rs) |
| authorizeQuickConnect | src/api.ts:366 | tests/unit/api-session.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested |
| listAccounts | src/api.ts:396 | tests/unit/api-session.test.ts | unit | tested |
| knownServers | src/api.ts:405 | tests/unit/api-session.test.ts | unit | tested |
| switchAccount | src/api.ts:415 | tests/unit/api-session.test.ts | unit | tested |
| forgetAccount | src/api.ts:428 | tests/unit/api-session.test.ts | unit | tested |
| avatarUrl | src/api.ts:438 | tests/unit/api-session.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested |
| expireSession | src/api.ts:453 | tests/unit/api-session.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested via api (401) |
| ITEM_FIELDS | src/api.ts:480 | tests/unit/api-browse.test.ts | unit | tested via every grid query |
| DETAIL_FIELDS | src/api.ts:485 | tests/unit/api-browse.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested via getItem |
| VIDEO_COLLECTION_TYPES | src/api.ts:495 | tests/unit/api-browse.test.ts | unit | tested |
| NON_VIDEO_ITEM_TYPES | src/api.ts:500 | tests/unit/api-browse.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested via isVideoItem, getLibraryItems |
| isVideoItem | src/api.ts:503 | tests/unit/api-browse.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested |
| getViews | src/api.ts:509 | tests/unit/api-browse.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested |
| getResume | src/api.ts:515 | tests/unit/api-browse.test.ts; tests/integration/api-browse.test.ts; tests/integration/api-state.test.ts | unit, integration (QA server) | tested |
| NEXT_UP_DAY_CHOICES | src/api.ts:534 | tests/unit/api-browse.test.ts | unit | tested |
| nextUpDaysLabel | src/api.ts:536 | tests/unit/api-browse.test.ts | unit | tested |
| nextUpDays | src/api.ts:547 | tests/unit/api-browse.test.ts; tests/integration/api-state.test.ts | unit, integration (QA server) | tested via getNextUp |
| nextUpInProgress | src/api.ts:553 | tests/unit/api-browse.test.ts; tests/integration/api-state.test.ts | unit, integration (QA server) | tested via getNextUp |
| nextUpRewatching | src/api.ts:557 | tests/unit/api-browse.test.ts | unit | tested via getNextUp |
| nextUpQuery | src/api.ts:561 | tests/unit/api-browse.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested via getNextUp |
| NOT_PLAYED_DATE | src/api.ts:582 | tests/unit/api-browse.test.ts | unit | tested |
| hasPlayedDate | src/api.ts:585 | tests/unit/api-browse.test.ts; tests/integration/api-state.test.ts | unit, integration (QA server) | tested |
| newStartsFirst | src/api.ts:600 | tests/unit/api-browse.test.ts; tests/integration/api-browse.test.ts; tests/integration/api-state.test.ts | unit, integration (QA server) | tested |
| expiredFromNextUp | src/api.ts:613 | tests/unit/api-browse.test.ts | unit | tested |
| reportExpired | src/api.ts:626 | tests/unit/api-browse.test.ts; tests/integration/api-state.test.ts | unit, integration (QA server) | tested via getNextUp (day limit) |
| getNextUp | src/api.ts:642 | tests/unit/api-browse.test.ts; tests/integration/api-browse.test.ts; tests/integration/api-state.test.ts | unit, integration (QA server) | tested |
| seriesEpisodesWithUserData | src/api.ts:656 | tests/unit/api-browse.test.ts; tests/integration/api-state.test.ts | unit, integration (QA server) | tested via removeFromNextUp, addToNextUp |
| walked | src/api.ts:664 | tests/unit/api-browse.test.ts | unit | tested via nextUpTarget, addToNextUp |
| nextUpTarget | src/api.ts:671 | tests/unit/api-browse.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested |
| removeFromNextUp | src/api.ts:687 | tests/unit/api-browse.test.ts; tests/integration/api-state.test.ts | unit, integration (QA server) | tested |
| addToNextUp | src/api.ts:713 | tests/unit/api-browse.test.ts; tests/integration/api-state.test.ts | unit, integration (QA server) | tested ("last" and "first") |
| homeSectionFor | src/api.ts:746 | tests/unit/api-browse.test.ts | unit | tested via getHomeSections |
| jellyfinDefaultSection | src/api.ts:769 | tests/unit/api-browse.test.ts | unit | tested via HOME_FALLBACK, getHomeSections |
| HOME_FALLBACK | src/api.ts:773 | tests/unit/api-browse.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested |
| getHomeSections | src/api.ts:783 | tests/unit/api-browse.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested |
| getSeriesNextUp | src/api.ts:809 | tests/unit/api-browse.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested |
| getLatest | src/api.ts:826 | tests/unit/api-browse.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested |
| foldEpisodesIntoSeries | src/api.ts:836 | tests/unit/api-browse.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested via getLatest |
| getLibraryItems | src/api.ts:877 | tests/unit/api-browse.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested |
| getFavorites | src/api.ts:905 | tests/unit/api-browse.test.ts; tests/integration/api-browse.test.ts; tests/integration/api-state.test.ts | unit, integration (QA server) | tested |
| getGenres | src/api.ts:926 | tests/unit/api-browse.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested |
| getItem | src/api.ts:935 | tests/unit/api-browse.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested |
| getSimilar | src/api.ts:944 | tests/unit/api-browse.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested |
| getSeasons | src/api.ts:952 | tests/unit/api-browse.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested |
| getEpisodes | src/api.ts:958 | tests/unit/api-browse.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested |
| getTrickplay | src/api.ts:996 | tests/unit/api-browse.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested |
| trickplayTile | src/api.ts:1034 | tests/unit/api-browse.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested (jf_image forwarded by tests/helpers/api-qa.ts) |
| getMediaSegments | src/api.ts:1058 | tests/unit/api-browse.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested (Intro and Outro) |
| search | src/api.ts:1070 | tests/unit/api-browse.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested |
| getChannels | src/api.ts:1088 | tests/unit/api-browse.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested |
| getPrograms | src/api.ts:1105 | tests/unit/api-browse.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested |
| getItemsByIds | src/api.ts:1133 | tests/unit/api-browse.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested |
| getUserDataByIds | src/api.ts:1147 | tests/unit/api-browse.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested |
| markPlayed | src/api.ts:1153 | tests/unit/api-browse.test.ts; tests/integration/api-state.test.ts | unit, integration (QA server) | tested |
| setFavorite | src/api.ts:1160 | tests/unit/api-browse.test.ts; tests/integration/api-state.test.ts | unit, integration (QA server) | tested |
| resolveImage | src/api.ts:1175 | tests/unit/api-media.test.ts | unit | tested via imageUrl, imageHash |
| imageUrl | src/api.ts:1192 | tests/unit/api-media.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested |
| imageHash | src/api.ts:1213 | tests/unit/api-media.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested |
| logoUrl | src/api.ts:1231 | tests/unit/api-media.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested |
| seriesPosterUrl | src/api.ts:1249 | tests/unit/api-media.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested |
| seasonPosterUrl | src/api.ts:1260 | tests/unit/api-media.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested |
| probeBandwidth | src/api.ts:1280 | tests/unit/api-media.test.ts; tests/integration/api-playback.test.ts | unit, integration (QA server) | tested (jf_bitrate_test forwarded by tests/helpers/api-qa.ts) |
| deviceProfile | src/api.ts:1300 | tests/unit/api-media.test.ts; tests/integration/api-playback.test.ts | unit, integration (QA server) | tested via resolvePlayback (Embed, and External for text formats) |
| resolvePlayback | src/api.ts:1341 | tests/unit/api-media.test.ts; tests/integration/api-playback.test.ts; tests/integration/api-state.test.ts | unit, integration (QA server) | tested (no access token in any address; External subtitles listed; audio track on a transcode) |
| externalSubtitles | src/api.ts:1327 | tests/unit/api-media.test.ts; tests/integration/api-playback.test.ts | unit, integration (QA server) | tested via resolvePlayback |
| withoutApiKey | src/api.ts:1398 | tests/unit/api-media.test.ts; tests/integration/api-playback.test.ts | unit, integration (QA server) | tested |
| sourceWithoutApiKey | src/api.ts:1409 | tests/unit/api-media.test.ts; tests/integration/api-playback.test.ts | unit, integration (QA server) | tested via resolvePlayback |
| DOWNLOAD_QUALITIES | src/api.ts:1426 | tests/unit/api-media.test.ts; tests/integration/api-playback.test.ts | unit, integration (QA server) | tested |
| audioRate | src/api.ts:1437 | tests/unit/api-media.test.ts | unit | tested via estimateDownloadSize, buildDownload |
| resolutionLabel | src/api.ts:1444 | tests/unit/api-media.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested via mediaSummary |
| channelLabel | src/api.ts:1456 | tests/unit/api-media.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested via mediaSummary |
| mediaSummary | src/api.ts:1476 | tests/unit/api-media.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested |
| estimateDownloadSize | src/api.ts:1499 | tests/unit/api-media.test.ts; tests/integration/api-browse.test.ts; tests/integration/api-playback.test.ts | unit, integration (QA server) | tested |
| effectiveDownloadQuality | src/api.ts:1528 | tests/unit/api-media.test.ts; tests/integration/api-playback.test.ts | unit, integration (QA server) | tested |
| buildDownload | src/api.ts:1544 | tests/unit/api-media.test.ts; tests/integration/api-playback.test.ts | unit, integration (QA server) | tested (the transcode download address is built, not fetched: it would start an encode) |
| ticksToText | src/api.ts:1578 | tests/unit/api-media.test.ts | unit | tested |
| remainingText | src/api.ts:1591 | tests/unit/api-media.test.ts; tests/integration/api-state.test.ts | unit, integration (QA server) | tested |
| secondsToClock | src/api.ts:1597 | tests/unit/api-media.test.ts | unit | tested |
| bytesToText | src/api.ts:1607 | tests/unit/api-media.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested |

### src/playback.ts, src/adaptive.ts, src/prefetch.ts

| Function | Source | Test file | Kind | Status |
| --- | --- | --- | --- | --- |
| MAX_VOLUME | src/playback.ts:14 | tests/unit/playback-prefs.test.ts | unit | tested |
| loadVolume | src/playback.ts:16 | tests/unit/playback-prefs.test.ts | unit | tested via getVolume |
| getVolume | src/playback.ts:24 | tests/unit/playback-prefs.test.ts | unit | tested |
| rememberVolume | src/playback.ts:28 | tests/unit/playback-prefs.test.ts | unit | tested via playerCtl.setVolume, noteVolume |
| noteVolume | src/playback.ts:40 | tests/unit/playback-prefs.test.ts | unit | tested |
| isAutoplayPending | src/playback.ts:102 | tests/unit/playback-next.test.ts | unit | tested |
| cancelAutoplay | src/playback.ts:110 | tests/unit/playback-prefs.test.ts | unit | tested |
| isAutoplayCancelled | src/playback.ts:115 | tests/unit/playback-prefs.test.ts | unit | tested |
| resumeAutoplay | src/playback.ts:120 | tests/unit/playback-prefs.test.ts | unit | tested |
| SKIP_INTERVALS | src/playback.ts:130 | tests/unit/playback-prefs.test.ts | unit | tested |
| skipInterval | src/playback.ts:132 | tests/unit/playback-prefs.test.ts | unit | tested |
| HIDE_AFTER_CHOICES | src/playback.ts:138 | tests/unit/playback-prefs.test.ts | unit | tested |
| hideControlsAfter | src/playback.ts:140 | tests/unit/playback-prefs.test.ts | unit | tested |
| showsRemaining | src/playback.ts:146 | tests/unit/playback-prefs.test.ts | unit | tested |
| setShowsRemaining | src/playback.ts:150 | tests/unit/playback-prefs.test.ts | unit | tested |
| autoplayNextEnabled | src/playback.ts:156 | tests/unit/playback-prefs.test.ts | unit | tested |
| resumeEnabled | src/playback.ts:161 | tests/unit/playback-prefs.test.ts | unit | tested |
| getUserQueue | src/playback.ts:176 | tests/unit/playback-next.test.ts | unit | tested |
| queueChanged | src/playback.ts:180 | tests/unit/playback-next.test.ts | unit | tested via queueNext, removeFromQueue, clearQueue |
| queueable | src/playback.ts:186 | tests/unit/playback-next.test.ts | unit | tested via queueNext, queueLater |
| queueNext | src/playback.ts:198 | tests/unit/playback-next.test.ts | unit | tested |
| queueLater | src/playback.ts:207 | tests/unit/playback-next.test.ts | unit | tested |
| removeFromQueue | src/playback.ts:216 | tests/unit/playback-next.test.ts | unit | tested |
| clearQueue | src/playback.ts:221 | tests/unit/playback-next.test.ts | unit | tested |
| playQueued | src/playback.ts:228 | tests/unit/playback-next.test.ts | unit | tested |
| startQueueIfIdle | src/playback.ts:242 | tests/unit/playback-next.test.ts | unit | tested via queueNext |
| maybePrefetch | src/playback.ts:271 | tests/unit/playback-start.test.ts | unit | tested via registerPlayerBridge (player-status) |
| takePrefetched | src/playback.ts:304 | tests/unit/playback-start.test.ts | unit | tested via playItem |
| showPlaybackError | src/playback.ts:317 | tests/unit/playback-start.test.ts | unit | tested via registerPlayerBridge (player-status) and playItem |
| smallerStream | src/playback.ts:351 | tests/unit/playback-start.test.ts | unit | tested via showPlaybackError |
| PICTURE_CONTROLS | src/playback.ts:373 | tests/unit/playback-prefs.test.ts | unit | tested |
| saveConfigSoon | src/playback.ts:388 | tests/unit/playback-prefs.test.ts | unit | tested |
| setLiveSetting | src/playback.ts:404 | tests/unit/playback-prefs.test.ts | unit | tested |
| sleepDeadline | src/playback.ts:422 | tests/unit/playback-prefs.test.ts | unit | tested |
| cancelSleepTimer | src/playback.ts:426 | tests/unit/playback-prefs.test.ts | unit | tested |
| setSleepTimer | src/playback.ts:434 | tests/unit/playback-prefs.test.ts | unit | tested |
| getTracks | src/playback.ts:476 | tests/unit/playback-next.test.ts | unit | tested |
| seriesTrackKey | src/playback.ts:480 | tests/unit/playback-next.test.ts | unit | tested via onTrackList |
| readTrackChoice | src/playback.ts:488 | tests/unit/playback-next.test.ts | unit | tested via onTrackList |
| writeTrackChoice | src/playback.ts:498 | tests/unit/playback-next.test.ts | unit | tested via onTrackList |
| onTrackList | src/playback.ts:512 | tests/unit/playback-next.test.ts | unit | tested via registerPlayerBridge (player-tracks) |
| getNowPlaying | src/playback.ts:557 | tests/unit/playback-start.test.ts | unit | tested |
| peekNextEpisode | src/playback.ts:572 | tests/unit/playback-next.test.ts | unit | tested |
| playNextNow | src/playback.ts:596 | tests/unit/playback-next.test.ts | unit | tested |
| itemTitle | src/playback.ts:607 | tests/unit/playback-prefs.test.ts | unit | tested |
| findDownload | src/playback.ts:617 | tests/unit/playback-start.test.ts | unit | tested via playItem, switchToDownload |
| pickStartingBitrate | src/playback.ts:647 | tests/unit/playback-start.test.ts | unit | tested |
| playItem | src/playback.ts:659 | tests/unit/playback-start.test.ts | unit | tested |
| playChannelUrl | src/playback.ts:769 | tests/unit/playback-start.test.ts | unit | tested |
| playLocal | src/playback.ts:824 | tests/unit/playback-start.test.ts | unit | tested |
| isLocalEpisode | src/playback.ts:891 | tests/unit/playback-next.test.ts | unit | tested via peekNextEpisode, maybeAutoplay |
| sameSeries | src/playback.ts:897 | tests/unit/playback-next.test.ts | unit | tested via peekNextEpisode |
| fromStart | src/playback.ts:903 | tests/unit/playback-next.test.ts | unit | tested via autoplayNext, startLocalShuffle |
| findNextEpisode | src/playback.ts:910 | tests/unit/playback-next.test.ts | unit | tested via peekNextEpisode, autoplayNext |
| findNextLocalEpisode | src/playback.ts:923 | tests/unit/playback-next.test.ts | unit | tested via peekNextEpisode, autoplayNext |
| isShuffling | src/playback.ts:950 | tests/unit/playback-next.test.ts | unit | tested |
| startLocalShuffle | src/playback.ts:960 | tests/unit/playback-next.test.ts | unit | tested |
| nextShuffledEpisode | src/playback.ts:973 | tests/unit/playback-next.test.ts | unit | tested via autoplayNext |
| nextFromServer | src/playback.ts:1004 | tests/unit/playback-next.test.ts | unit | tested via peekNextEpisode, autoplayNext |
| autoplayNext | src/playback.ts:1010 | tests/unit/playback-next.test.ts | unit | tested via maybeAutoplay, playNextNow |
| maybeAutoplay | src/playback.ts:1052 | tests/unit/playback-next.test.ts | unit | tested via registerPlayerBridge (player-status) |
| SPACE_HEADROOM | src/playback.ts:1099 | tests/unit/playback-downloads.test.ts | unit | tested via resolveSpace |
| freeSpace | src/playback.ts:1102 | tests/unit/playback-downloads.test.ts | unit | tested via resolveSpace |
| estimateTotal | src/playback.ts:1109 | tests/unit/playback-downloads.test.ts | unit | tested via resolveSpace |
| resolveSpace | src/playback.ts:1131 | tests/unit/playback-downloads.test.ts | unit | tested via startDownload, downloadSeason |
| startDownload | src/playback.ts:1183 | tests/unit/playback-downloads.test.ts | unit | tested |
| beginDownload | src/playback.ts:1201 | tests/unit/playback-downloads.test.ts | unit | tested via pumpQueue |
| isRetry | src/playback.ts:1304 | tests/unit/playback-downloads.test.ts | unit | tested via getQueuedDownloads, pumpQueue |
| isTranscodeEntry | src/playback.ts:1309 | tests/unit/playback-downloads.test.ts | unit | tested via getQueuedDownloads, nextStartable |
| isTranscodeDownload | src/playback.ts:1314 | tests/unit/playback-downloads.test.ts | unit | tested |
| entryId | src/playback.ts:1320 | tests/unit/playback-downloads.test.ts | unit | tested via cancelQueuedDownload, startDownload |
| isDownloadsPaused | src/playback.ts:1338 | tests/unit/playback-downloads.test.ts | unit | tested |
| unmeteredOnly | src/playback.ts:1342 | tests/unit/playback-downloads.test.ts | unit | tested via downloadHoldReason |
| transcodeSerial | src/playback.ts:1346 | tests/unit/playback-downloads.test.ts | unit | tested via nextStartable, isWaitingForTranscode |
| downloadHoldReason | src/playback.ts:1354 | tests/unit/playback-downloads.test.ts | unit | tested |
| setAsideRunning | src/playback.ts:1365 | tests/unit/playback-downloads.test.ts | unit | tested via setDownloadsPaused, applyMeteredHold, restoreDownloadQueue |
| setDownloadsPaused | src/playback.ts:1388 | tests/unit/playback-downloads.test.ts | unit | tested |
| downloadPrefsChanged | src/playback.ts:1408 | tests/unit/playback-downloads.test.ts | unit | tested |
| applyMeteredHold | src/playback.ts:1415 | tests/unit/playback-downloads.test.ts | unit | tested via downloadPrefsChanged, network-metered event |
| MAX_DOWNLOAD_CONCURRENCY | src/playback.ts:1438 | tests/unit/playback-downloads.test.ts | unit | tested |
| dlConcurrency initialiser | src/playback.ts:1441 | tests/unit/playback-downloads.test.ts | unit | tested via getDownloadConcurrency |
| getDownloadConcurrency | src/playback.ts:1446 | tests/unit/playback-downloads.test.ts | unit | tested |
| setDownloadConcurrency | src/playback.ts:1452 | tests/unit/playback-downloads.test.ts | unit | tested |
| saveQueue | src/playback.ts:1462 | tests/unit/playback-downloads.test.ts | unit | tested via notifyQueueChanged |
| getQueuedDownloads | src/playback.ts:1495 | tests/unit/playback-downloads.test.ts | unit | tested |
| cancelQueuedDownload | src/playback.ts:1523 | tests/unit/playback-downloads.test.ts | unit | tested |
| queueRetriesFirst | src/playback.ts:1544 | tests/unit/playback-downloads.test.ts | unit | tested via retryDownload, retryFailedDownloads |
| retryDownload | src/playback.ts:1582 | tests/unit/playback-downloads.test.ts | unit | tested |
| retryFailedDownloads | src/playback.ts:1605 | tests/unit/playback-downloads.test.ts | unit | tested |
| clearDownloadQueue | src/playback.ts:1614 | tests/unit/playback-downloads.test.ts | unit | tested |
| notifyQueueChanged | src/playback.ts:1623 | tests/unit/playback-downloads.test.ts | unit | tested via startDownload, cancelQueuedDownload |
| ensureQueueBridge | src/playback.ts:1628 | tests/unit/playback-downloads.test.ts | unit | tested via download-progress, network-metered and aquarium-connectivity events |
| scheduleAutomaticRetry | src/playback.ts:1666 | tests/unit/playback-downloads.test.ts | unit | tested via download-progress event |
| armRetryWake | src/playback.ts:1687 | tests/unit/playback-downloads.test.ts | unit | tested via pumpQueue |
| nextStartable | src/playback.ts:1703 | tests/unit/playback-downloads.test.ts | unit | tested via pumpQueue |
| isWaitingForTranscode | src/playback.ts:1715 | tests/unit/playback-downloads.test.ts | unit | tested |
| pumpQueue | src/playback.ts:1719 | tests/unit/playback-downloads.test.ts | unit | tested via startDownload, downloadSeason, retries |
| downloadSeason | src/playback.ts:1764 | tests/unit/playback-downloads.test.ts | unit | tested |
| downloadSeries | src/playback.ts:1806 | tests/unit/playback-downloads.test.ts | unit | tested |
| restoreDownloadQueue | src/playback.ts:1828 | tests/unit/playback-downloads.test.ts | unit | tested |
| QUALITY_CHOICES | src/playback.ts:1911 | tests/unit/playback-start.test.ts | unit | tested |
| getQualityState | src/playback.ts:1921 | tests/unit/playback-start.test.ts | unit | tested |
| downloadedLabel | src/playback.ts:1947 | tests/unit/playback-prefs.test.ts | unit | tested |
| switchQuality | src/playback.ts:1956 | tests/unit/playback-start.test.ts | unit | tested |
| playingAudio | src/playback.ts:1996 | tests/unit/playback-start.test.ts | unit | tested via switchQuality |
| switchToDownload | src/playback.ts:1984 | tests/unit/playback-start.test.ts | unit | tested |
| isAdaptiveEnabled | src/playback.ts:2016 | tests/unit/playback-prefs.test.ts | unit | tested |
| setAdaptiveEnabled | src/playback.ts:2020 | tests/unit/playback-prefs.test.ts | unit | tested |
| mpvCommand | src/playback.ts:2029 | tests/unit/playback-prefs.test.ts | unit | tested via playerCtl.setProp |
| openUoscMenu | src/playback.ts:2033 | tests/unit/playback-next.test.ts | unit | tested via showQualityMenu, showEpisodeMenu |
| showQualityMenu | src/playback.ts:2037 | tests/unit/playback-next.test.ts | unit | tested |
| getEpisodeQueue | src/playback.ts:2079 | tests/unit/playback-next.test.ts | unit | tested |
| playQueuedEpisode | src/playback.ts:2095 | tests/unit/playback-next.test.ts | unit | tested |
| showEpisodeMenu | src/playback.ts:2107 | tests/unit/playback-next.test.ts | unit | tested |
| handlePlayerMessage | src/playback.ts:2128 | tests/unit/playback-next.test.ts | unit | tested via registerPlayerBridge (player-message) |
| registerPlayerBridge | src/playback.ts:2194 | tests/unit/playback-start.test.ts, tests/unit/playback-next.test.ts | unit | tested |
| SPEEDS | src/playback.ts:2246 | tests/unit/playback-prefs.test.ts | unit | tested |
| SUB_DELAY_STEP | src/playback.ts:2250 | tests/unit/playback-prefs.test.ts | unit | tested |
| playerCtl.pauseToggle | src/playback.ts:2253 | tests/unit/playback-prefs.test.ts | unit | tested |
| playerCtl.setProp | src/playback.ts:2261 | tests/unit/playback-prefs.test.ts | unit | tested |
| playerCtl.stop | src/playback.ts:2262 | tests/unit/playback-prefs.test.ts | unit | tested |
| playerCtl.seek | src/playback.ts:2263 | tests/unit/playback-prefs.test.ts | unit | tested |
| playerCtl.setTrack | src/playback.ts:2264 | tests/unit/playback-prefs.test.ts | unit | tested |
| playerCtl.setVolume | src/playback.ts:2267 | tests/unit/playback-prefs.test.ts | unit | tested |
| playerCtl.setMute | src/playback.ts:2271 | tests/unit/playback-prefs.test.ts | unit | tested |
| playerCtl.setSpeed | src/playback.ts:2272 | tests/unit/playback-prefs.test.ts | unit | tested |
| playerCtl.setSubDelay | src/playback.ts:2274 | tests/unit/playback-prefs.test.ts | unit | tested |
| playerCtl.setAudioDelay | src/playback.ts:2279 | tests/unit/playback-prefs.test.ts | unit | tested |
| AUDIO_DELAY_STEP | src/playback.ts:2288 | tests/unit/playback-prefs.test.ts | unit | tested |
| getStreamSource | src/playback.ts:2291 | tests/unit/playback-start.test.ts; tests/dom/main-panels.test.ts | unit, dom | tested |
| getNowPlayingFull | src/playback.ts:2295 | tests/unit/playback-start.test.ts | unit | tested |
| syncOfflineProgress | src/playback.ts:2300 | tests/unit/playback-prefs.test.ts | unit | tested |
| now | src/adaptive.ts:78 | tests/unit/adaptive.test.ts | unit | tested via onStall, onStatus |
| rungIndex | src/adaptive.ts:80 | tests/unit/adaptive.test.ts | unit | tested via currentRung, onStarted |
| resetStream | src/adaptive.ts:86 | tests/unit/adaptive.test.ts | unit | tested via onStarted, onStatus |
| currentRung | src/adaptive.ts:102 | tests/unit/adaptive.test.ts | unit | tested via onStall, onStatus |
| settling | src/adaptive.ts:110 | tests/unit/adaptive.test.ts | unit | tested via onStall, onStatus |
| nextRungDown | src/adaptive.ts:132 | tests/unit/adaptive.test.ts | unit | tested via stepDown |
| stepDown | src/adaptive.ts:145 | tests/unit/adaptive.test.ts | unit | tested via onStall, onStatus |
| stepUp | src/adaptive.ts:203 | tests/unit/adaptive.test.ts | unit | tested via onStatus |
| onStall | src/adaptive.ts:224 | tests/unit/adaptive.test.ts | unit | tested via player-stall event |
| onStatus | src/adaptive.ts:235 | tests/unit/adaptive.test.ts | unit | tested via player-status event |
| onStarted | src/adaptive.ts:297 | tests/unit/adaptive.test.ts | unit | tested via aquarium-player-started event |
| registerAdaptiveQuality | src/adaptive.ts:313 | tests/unit/adaptive.test.ts | unit | tested |
| schedule | src/prefetch.ts:18 | tests/unit/prefetch.test.ts | unit | tested via wirePrefetch |
| cancel | src/prefetch.ts:32 | tests/unit/prefetch.test.ts | unit | tested via wirePrefetch |
| cardElFrom | src/prefetch.ts:40 | tests/unit/prefetch.test.ts | unit | tested via wirePrefetch |
| left | src/prefetch.ts:50 | tests/unit/prefetch.test.ts | unit | tested via wirePrefetch |
| wirePrefetch | src/prefetch.ts:54 | tests/unit/prefetch.test.ts | unit | tested |

### the small modules, audio.ts, iptv.ts, public/theme-boot.js

| Function | Source | Test file | Kind | Status |
|---|---|---|---|---|
| decode83 | src/blurhash.ts:26 | tests/unit/blurhash.test.ts | unit | tested via blurhashUrl |
| toLinear | src/blurhash.ts:38 | tests/unit/blurhash.test.ts | unit | tested via blurhashUrl |
| toSrgb | src/blurhash.ts:43 | tests/unit/blurhash.test.ts | unit | tested via blurhashUrl |
| signPow | src/blurhash.ts:49 | tests/unit/blurhash.test.ts | unit | tested via blurhashUrl |
| blurhashUrl | src/blurhash.ts:57 | tests/unit/blurhash.test.ts | unit | tested |
| render | src/blurhash.ts:69 | tests/unit/blurhash.test.ts | unit | tested via blurhashUrl |
| openDb | src/cache.ts:50 | tests/unit/cache.test.ts | unit | tested via hydrateCache |
| promisify | src/cache.ts:80 | tests/unit/cache.test.ts | unit | tested via hydrateCache |
| enqueue | src/cache.ts:91 | tests/unit/cache.test.ts | unit | tested via setCached |
| persist | src/cache.ts:104 | tests/unit/cache.test.ts | unit | tested via setCached |
| unpersist | src/cache.ts:117 | tests/unit/cache.test.ts | unit | tested via invalidateCache |
| getCached | src/cache.ts:126 | tests/unit/cache.test.ts | unit | tested |
| setCached | src/cache.ts:130 | tests/unit/cache.test.ts | unit | tested |
| invalidateCache | src/cache.ts:135 | tests/unit/cache.test.ts | unit | tested |
| clearCache | src/cache.ts:140 | tests/unit/cache.test.ts | unit | tested |
| hydrateCache | src/cache.ts:157 | tests/unit/cache.test.ts | unit | tested |
| itemSignature | src/cache.ts:192 | tests/unit/cache.test.ts | unit | tested |
| channelLabel | src/channels-panel.ts:23 | tests/dom/channels-panel.test.ts | dom | tested via liveTitleLines |
| logo | src/channels-panel.ts:26 | tests/dom/channels-panel.test.ts | dom | tested via fillChannelsPanel |
| liveTitleLines | src/channels-panel.ts:46 | tests/dom/channels-panel.test.ts | dom | tested |
| switchChannel | src/channels-panel.ts:77 | tests/dom/channels-panel.test.ts | dom | tested |
| switchChannel redraw | src/channels-panel.ts:84 | tests/dom/channels-panel.test.ts | dom | tested via switchChannel |
| stepChannel | src/channels-panel.ts:97 | tests/dom/channels-panel.test.ts | dom | tested |
| fillChannelsPanel | src/channels-panel.ts:112 | tests/dom/channels-panel.test.ts | dom | tested |
| draw | src/channels-panel.ts:137 | tests/dom/channels-panel.test.ts | dom | tested via fillChannelsPanel |
| lineupKey | src/lineup.ts:17 | tests/unit/lineup.test.ts | unit | tested |
| cachedLineup | src/lineup.ts:22 | tests/unit/lineup.test.ts | unit | tested |
| isChannel | src/lineup.ts:27 | tests/unit/lineup.test.ts | unit | tested |
| loadLineup | src/lineup.ts:38 | tests/unit/lineup.test.ts | unit | tested |
| readSchedule | src/lineup.ts:74 | tests/unit/lineup.test.ts | unit | tested via nearSchedule |
| scheduleStale | src/lineup.ts:93 | tests/unit/lineup.test.ts | unit | tested via nearSchedule |
| nearSchedule | src/lineup.ts:99 | tests/unit/lineup.test.ts | unit | tested |
| nowNextSync | src/lineup.ts:121 | tests/unit/lineup.test.ts | unit | tested |
| pickNowNext | src/lineup.ts:127 | tests/unit/lineup.test.ts | unit | tested via nowNext |
| nowNext | src/lineup.ts:148 | tests/unit/lineup.test.ts | unit | tested |
| onNow | src/lineup.ts:158 | tests/unit/lineup.test.ts | unit | tested |
| progressOf | src/lineup.ts:171 | tests/unit/lineup.test.ts | unit | tested |
| fmtClock | src/lineup.ts:177 | tests/unit/lineup.test.ts | unit | tested |
| playChannel | src/lineup.ts:188 | tests/unit/lineup.test.ts | unit | tested |
| preloadLineup | src/lineup.ts:211 | tests/unit/lineup.test.ts | unit | tested |
| refreshNow | src/lineup.ts:230 | tests/unit/lineup.test.ts | unit | tested |
| reducedMotion | src/scroll.ts:32 | tests/unit/scroll.test.ts | unit | tested via wireSmoothScroll |
| deltaPixels | src/scroll.ts:37 | tests/unit/scroll.test.ts | unit | tested via wireSmoothScroll |
| overNestedScroller | src/scroll.ts:67 | tests/unit/scroll.test.ts | unit | tested via wireSmoothScroll |
| wireSmoothScroll | src/scroll.ts:79 | tests/unit/scroll.test.ts | unit | tested |
| maxScroll | src/scroll.ts:88 | tests/unit/scroll.test.ts | unit | tested via wireSmoothScroll |
| stop | src/scroll.ts:90 | tests/unit/scroll.test.ts | unit | tested via wireSmoothScroll |
| frame | src/scroll.ts:100 | tests/unit/scroll.test.ts | unit | tested via wireSmoothScroll |
| onWheel | src/scroll.ts:136 | tests/unit/scroll.test.ts | unit | tested via wireSmoothScroll |
| onScroll | src/scroll.ts:167 | tests/unit/scroll.test.ts | unit | tested via wireSmoothScroll |
| blankSmartPlaylist | src/smartPlaylists.ts:27 | tests/unit/smartPlaylists.test.ts | unit | tested |
| getSmartPlaylists | src/smartPlaylists.ts:44 | tests/unit/smartPlaylists.test.ts | unit | tested |
| saveSmartPlaylist | src/smartPlaylists.ts:52 | tests/unit/smartPlaylists.test.ts | unit | tested |
| deleteSmartPlaylist | src/smartPlaylists.ts:60 | tests/unit/smartPlaylists.test.ts | unit | tested |
| asItem | src/smartPlaylists.ts:65 | tests/unit/smartPlaylists.test.ts | unit | tested |
| describe | src/smartPlaylists.ts:70 | tests/unit/smartPlaylists.test.ts | unit | tested |
| smartPlaylistSongs | src/smartPlaylists.ts:86 | tests/unit/smartPlaylists.test.ts | unit | tested |
| boxOf | src/spatial.ts:28 | tests/unit/spatial.test.ts | unit | tested via wireSpatialNav |
| pick | src/spatial.ts:49 | tests/unit/spatial.test.ts | unit | tested via wireSpatialNav |
| move | src/spatial.ts:91 | tests/unit/spatial.test.ts | unit | tested via wireSpatialNav |
| wireSpatialNav | src/spatial.ts:121 | tests/unit/spatial.test.ts | unit | tested |
| DIALS | src/stations.ts:18 | tests/unit/stations.test.ts | unit | tested |
| DIAL_INFO | src/stations.ts:22 | tests/unit/stations.test.ts | unit | tested |
| BUDGET | src/stations.ts:44 | tests/unit/stations.test.ts | unit | tested via remaining |
| points | src/stations.ts:46 | tests/unit/stations.test.ts | unit | tested |
| PRESETS | src/stations.ts:59 | tests/unit/stations.test.ts | unit | tested |
| remaining | src/stations.ts:65 | tests/unit/stations.test.ts | unit | tested |
| presetName | src/stations.ts:69 | tests/unit/stations.test.ts | unit | tested |
| getMixPoints | src/stations.ts:73 | tests/unit/stations.test.ts | unit | tested |
| saveMixPoints | src/stations.ts:78 | tests/unit/stations.test.ts | unit | tested |
| withDial | src/stations.ts:83 | tests/unit/stations.test.ts | unit | tested |
| weight | src/stations.ts:89 | tests/unit/stations.test.ts | unit | tested via likeness |
| genreKey | src/stations.ts:100 | tests/unit/stations.test.ts | unit | tested |
| words | src/stations.ts:114 | tests/unit/stations.test.ts | unit | tested via likeness |
| artistKeys | src/stations.ts:118 | tests/unit/stations.test.ts | unit | tested via profileOf |
| artistKeys add | src/stations.ts:120 | tests/unit/stations.test.ts | unit | tested via profileOf |
| lead | src/stations.ts:130 | tests/unit/stations.test.ts | unit | tested via score |
| genresOf | src/stations.ts:136 | tests/unit/stations.test.ts | unit | tested via profileOf |
| emptyProfile | src/stations.ts:153 | tests/unit/stations.test.ts | unit | tested via profileOf |
| addGenres | src/stations.ts:157 | tests/unit/stations.test.ts | unit | tested via profileOf |
| profileOf | src/stations.ts:164 | tests/unit/stations.test.ts | unit | tested |
| genreAffinity | src/stations.ts:198 | tests/unit/stations.test.ts | unit | tested via likeness |
| likeness | src/stations.ts:213 | tests/unit/stations.test.ts | unit | tested |
| sameAct | src/stations.ts:238 | tests/unit/stations.test.ts | unit | tested |
| actGrouper | src/stations.ts:244 | tests/unit/stations.test.ts | unit | tested via sequence |
| score | src/stations.ts:259 | tests/unit/stations.test.ts | unit | tested |
| sequence | src/stations.ts:282 | tests/unit/stations.test.ts | unit | tested |
| safe | src/stations.ts:344 | tests/unit/stations.test.ts | unit | tested via buildStation |
| similarArtistSongs | src/stations.ts:352 | tests/unit/stations.test.ts | unit | tested via buildStation |
| gather | src/stations.ts:359 | tests/unit/stations.test.ts | unit | tested via buildStation |
| dedupe | src/stations.ts:398 | tests/unit/stations.test.ts | unit | tested via buildStation |
| Station.more | src/stations.ts:409 | tests/unit/stations.test.ts | unit | tested via buildStation |
| Station.first | src/stations.ts:415 | tests/unit/stations.test.ts | unit | tested via buildStation |
| buildStation | src/stations.ts:424 | tests/unit/stations.test.ts | unit | tested |
| getMixSource | src/stations.ts:438 | tests/unit/stations.test.ts | unit | tested |
| buildInstantMix | src/stations.ts:443 | tests/unit/stations.test.ts | unit | tested |
| buildOfflineMix | src/stations.ts:451 | tests/unit/stations.test.ts | unit | tested |
| _internal | src/stations.ts:465 | tests/unit/stations.test.ts | unit | tested |
| normalizePref | src/theme.ts:26 | tests/unit/theme.test.ts | unit | tested |
| fromMediaQuery | src/theme.ts:30 | tests/unit/theme.test.ts | unit | tested via initTheme |
| resolved | src/theme.ts:36 | tests/unit/theme.test.ts | unit | tested via initTheme |
| apply | src/theme.ts:41 | tests/unit/theme.test.ts | unit | tested via initTheme |
| setSystem | src/theme.ts:51 | tests/unit/theme.test.ts | unit | tested via initTheme |
| getThemePref | src/theme.ts:55 | tests/unit/theme.test.ts | unit | tested |
| setThemePref | src/theme.ts:60 | tests/unit/theme.test.ts | unit | tested |
| initTheme | src/theme.ts:66 | tests/unit/theme.test.ts | unit | tested |
| legacy fellyjin localStorage carry-over | public/theme-boot.js:10 | tests/unit/theme.test.ts | unit | tested |
| pre-paint theme apply | public/theme-boot.js:21 | tests/unit/theme.test.ts | unit | tested |
| MUSIC_FIELDS | src/musicApi.ts:14 | tests/unit/musicApi.test.ts | unit | tested |
| MUSIC_DETAIL_FIELDS | src/musicApi.ts:18 | tests/unit/musicApi.test.ts | unit | tested |
| SORTS | src/musicApi.ts:27 | tests/unit/musicApi.test.ts | unit | tested |
| sess | src/musicApi.ts:57 | tests/unit/musicApi.test.ts | unit | tested via music |
| music | src/musicApi.ts:64 | tests/unit/musicApi.test.ts | unit | tested |
| artists | src/musicApi.ts:98 | tests/unit/musicApi.test.ts | unit | tested |
| musicItem | src/musicApi.ts:119 | tests/unit/musicApi.test.ts | unit | tested |
| sortedByTrack | src/musicApi.ts:125 | tests/unit/musicApi.test.ts | unit | tested |
| albumTracks | src/musicApi.ts:135 | tests/unit/musicApi.test.ts | unit | tested |
| topSongs | src/musicApi.ts:140 | tests/unit/musicApi.test.ts | unit | tested |
| allSongs | src/musicApi.ts:144 | tests/unit/musicApi.test.ts | unit | tested |
| albumsBy | src/musicApi.ts:148 | tests/unit/musicApi.test.ts | unit | tested |
| appearsOn | src/musicApi.ts:153 | tests/unit/musicApi.test.ts | unit | tested |
| genreSongs | src/musicApi.ts:158 | tests/unit/musicApi.test.ts | unit | tested |
| musicGenres | src/musicApi.ts:162 | tests/unit/musicApi.test.ts | unit | tested |
| audioPlaylists | src/musicApi.ts:179 | tests/unit/musicApi.test.ts | unit | tested |
| playlistItems | src/musicApi.ts:190 | tests/unit/musicApi.test.ts | unit | tested |
| createPlaylist | src/musicApi.ts:208 | tests/unit/musicApi.test.ts | unit | tested |
| renamePlaylist | src/musicApi.ts:218 | tests/unit/musicApi.test.ts | unit | tested |
| deletePlaylist | src/musicApi.ts:222 | tests/unit/musicApi.test.ts | unit | tested |
| addToPlaylist | src/musicApi.ts:226 | tests/unit/musicApi.test.ts | unit | tested |
| removeFromPlaylist | src/musicApi.ts:235 | tests/unit/musicApi.test.ts | unit | tested |
| movePlaylistEntry | src/musicApi.ts:240 | tests/unit/musicApi.test.ts | unit | tested |
| instantMix | src/musicApi.ts:246 | tests/unit/musicApi.test.ts | unit | tested |
| similarArtists | src/musicApi.ts:254 | tests/unit/musicApi.test.ts | unit | tested |
| recentlyPlayedSongs | src/musicApi.ts:260 | tests/unit/musicApi.test.ts | unit | tested |
| mostPlayedSongs | src/musicApi.ts:264 | tests/unit/musicApi.test.ts | unit | tested |
| resumeBooks | src/musicApi.ts:269 | tests/unit/musicApi.test.ts | unit | tested |
| lyrics | src/musicApi.ts:287 | tests/unit/musicApi.test.ts | unit | tested |
| searchMusic | src/musicApi.ts:302 | tests/unit/musicApi.test.ts | unit | tested |
| artistLine | src/musicApi.ts:320 | tests/unit/musicApi.test.ts | unit | tested |
| coverUrl | src/musicApi.ts:331 | tests/unit/musicApi.test.ts | unit | tested |
| albumsInOrder | src/musicApi.ts:343 | tests/unit/musicApi.test.ts | unit | tested |
| streamUrl | src/musicApi.ts:364 | tests/unit/musicApi.test.ts | unit | tested |
| secondsOf | src/musicApi.ts:369 | tests/unit/musicApi.test.ts | unit | tested |
| clock | src/musicApi.ts:373 | tests/unit/musicApi.test.ts | unit | tested |
| longDuration | src/musicApi.ts:382 | tests/unit/musicApi.test.ts | unit | tested |
| iconSvg | src/icons.ts:55 | tests/unit/icons.test.ts | unit | tested |
| iconSvg per-icon stroke widths | src/icons.ts:16 | tests/unit/icons.test.ts | unit | tested |
| icon | src/icons.ts:64 | tests/unit/icons.test.ts | unit | tested |
| readNumber | src/audio.ts:67 | tests/unit/audio.test.ts | unit | tested via bookSpeed |
| writeValue | src/audio.ts:75 | tests/unit/audio.test.ts | unit | tested via setSpeed |
| onChange | src/audio.ts:92 | tests/unit/audio.test.ts | unit | tested |
| changed | src/audio.ts:97 | tests/unit/audio.test.ts | unit | tested via onChange |
| getStatus | src/audio.ts:107 | tests/unit/audio.test.ts | unit | tested |
| isActive | src/audio.ts:111 | tests/unit/audio.test.ts | unit | tested |
| current | src/audio.ts:115 | tests/unit/audio.test.ts | unit | tested |
| queueState | src/audio.ts:119 | tests/unit/audio.test.ts | unit | tested |
| upNext | src/audio.ts:124 | tests/unit/audio.test.ts | unit | tested |
| isShuffled | src/audio.ts:128 | tests/unit/audio.test.ts | unit | tested |
| currentChapter | src/audio.ts:133 | tests/unit/audio.test.ts | unit | tested |
| trackOf | src/audio.ts:149 | tests/unit/audio.test.ts | unit | tested via play |
| followingIndex | src/audio.ts:165 | tests/unit/audio.test.ts | unit | tested via play |
| soundCheck | src/audio.ts:171 | tests/unit/audio.test.ts | unit | tested via setSoundCheck |
| publishQueue | src/audio.ts:175 | tests/unit/audio.test.ts | unit | tested via play |
| startAt | src/audio.ts:189 | tests/unit/audio.test.ts | unit | tested via play |
| handDownNext | src/audio.ts:224 | tests/unit/audio.test.ts | unit | tested via play |
| topUp | src/audio.ts:234 | tests/unit/audio.test.ts | unit | tested via play |
| attachLocal | src/audio.ts:260 | tests/unit/audio.test.ts | unit | tested via play |
| play | src/audio.ts:283 | tests/unit/audio.test.ts | unit | tested |
| replaceUpNext | src/audio.ts:308 | tests/unit/audio.test.ts | unit | tested |
| playNext | src/audio.ts:324 | tests/unit/audio.test.ts | unit | tested |
| playLater | src/audio.ts:335 | tests/unit/audio.test.ts | unit | tested |
| next | src/audio.ts:345 | tests/unit/audio.test.ts | unit | tested |
| previous | src/audio.ts:357 | tests/unit/audio.test.ts | unit | tested |
| jump | src/audio.ts:365 | tests/unit/audio.test.ts | unit | tested |
| stop | src/audio.ts:369 | tests/unit/audio.test.ts | unit | tested |
| removeAt | src/audio.ts:385 | tests/unit/audio.test.ts | unit | tested |
| move | src/audio.ts:398 | tests/unit/audio.test.ts | unit | tested |
| clearUpNext | src/audio.ts:407 | tests/unit/audio.test.ts | unit | tested |
| shuffled | src/audio.ts:417 | tests/unit/audio.test.ts | unit | tested via setShuffle |
| setShuffle | src/audio.ts:426 | tests/unit/audio.test.ts | unit | tested |
| cycleRepeat | src/audio.ts:444 | tests/unit/audio.test.ts | unit | tested |
| togglePause | src/audio.ts:456 | tests/unit/audio.test.ts | unit | tested |
| seek | src/audio.ts:461 | tests/unit/audio.test.ts | unit | tested |
| skip | src/audio.ts:468 | tests/unit/audio.test.ts | unit | tested |
| setVolume | src/audio.ts:472 | tests/unit/audio.test.ts | unit | tested |
| setMute | src/audio.ts:479 | tests/unit/audio.test.ts | unit | tested |
| BOOK_SPEEDS | src/audio.ts:483 | tests/unit/audio.test.ts | unit | tested |
| bookSpeed | src/audio.ts:485 | tests/unit/audio.test.ts | unit | tested |
| setSpeed | src/audio.ts:489 | tests/unit/audio.test.ts | unit | tested |
| setSoundCheck | src/audio.ts:494 | tests/unit/audio.test.ts | unit | tested |
| soundCheckOn | src/audio.ts:499 | tests/unit/audio.test.ts | unit | tested |
| sleepState | src/audio.ts:509 | tests/unit/audio.test.ts | unit | tested |
| cancelSleep | src/audio.ts:513 | tests/unit/audio.test.ts | unit | tested via setSleep |
| setSleep | src/audio.ts:521 | tests/unit/audio.test.ts | unit | tested |
| pauseForSleep | src/audio.ts:542 | tests/unit/audio.test.ts | unit | tested via setSleep |
| wireAudio | src/audio.ts:553 | tests/unit/audio.test.ts | unit | tested |
| isCustom | src/iptv.ts:38 | tests/unit/iptv.test.ts | unit | tested |
| sourceUrls | src/iptv.ts:42 | tests/unit/iptv.test.ts | unit | tested |
| DEFAULT_USER_AGENT | src/iptv.ts:57 | tests/unit/iptv.test.ts | unit | tested |
| iptvUserAgent | src/iptv.ts:60 | tests/unit/iptv.test.ts | unit | tested |
| DEFAULT_REFRESH_MIN | src/iptv.ts:66 | tests/unit/iptv.test.ts | unit | tested |
| refreshMinutes | src/iptv.ts:68 | tests/unit/iptv.test.ts | unit | tested |
| attrs | src/iptv.ts:78 | tests/unit/iptv.test.ts | unit | tested via parseM3u |
| parseM3u | src/iptv.ts:100 | tests/unit/iptv.test.ts | unit | tested |
| nameComma | src/iptv.ts:103 | tests/unit/iptv.test.ts | unit | tested via parseM3u |
| xmltvTime | src/iptv.ts:152 | tests/unit/iptv.test.ts | unit | tested |
| textOf | src/iptv.ts:166 | tests/unit/iptv.test.ts | unit | tested via parseXmltv |
| parseXmltv | src/iptv.ts:175 | tests/unit/iptv.test.ts | unit | tested |
| aged | src/iptv.ts:236 | tests/unit/iptv.test.ts | unit | tested via isDue |
| norm | src/iptv.ts:241 | tests/unit/iptv.test.ts | unit | tested via load |
| join | src/iptv.ts:243 | tests/unit/iptv.test.ts | unit | tested via load |
| fetchText | src/iptv.ts:276 | tests/unit/iptv.test.ts | unit | tested via load |
| loadFresh | src/iptv.ts:280 | tests/unit/iptv.test.ts | unit | tested via load |
| load | src/iptv.ts:305 | tests/unit/iptv.test.ts | unit | tested |
| invalidate | src/iptv.ts:326 | tests/unit/iptv.test.ts | unit | tested |
| isDue | src/iptv.ts:331 | tests/unit/iptv.test.ts | unit | tested |
| lastRead | src/iptv.ts:339 | tests/unit/iptv.test.ts | unit | tested |
| getChannels | src/iptv.ts:358 | tests/unit/iptv.test.ts | unit | tested |
| getPrograms | src/iptv.ts:364 | tests/unit/iptv.test.ts | unit | tested |
| describe | src/iptv.ts:378 | tests/unit/iptv.test.ts | unit | tested |

### src/main.ts, src/ui.ts, src/views/settings.ts

| Function | Source | Test file | Kind | Status |
| --- | --- | --- | --- | --- |
| ICONS (sidebar glyphs) | src/main.ts:88 | tests/dom/main-shell.test.ts | dom | tested via paintNav |
| fsSetBar | src/main.ts:160 | tests/dom/main-fullscreen.test.ts | dom | tested via fsPokeControls/fsArmHide |
| userSubPos | src/main.ts:178 | tests/dom/main-fullscreen.test.ts | dom | tested via fsSetBar (sub_pos lift and restore, damaged value) |
| fsPokeControls | src/main.ts:185 | tests/dom/main-fullscreen.test.ts | dom | tested via document mousemove, player-mouse, notes, tap |
| fsArmHide | src/main.ts:197 | tests/dom/main-fullscreen.test.ts | dom | tested (hide after Settings interval, hover and open panel keep it up) |
| fsPointerMoved | src/main.ts:221 | tests/dom/main-fullscreen.test.ts | dom | tested (Linux/CLAUDE.md invariant: out-of-window and repeated mousemoves ignored) |
| setVideoFullscreen | src/main.ts:233 | tests/dom/main-fullscreen.test.ts | dom | tested via f, button, Escape, events, gestures |
| setVideoPip | src/main.ts:287 | tests/dom/main-fullscreen.test.ts | dom | tested via p, button, ctl pip, quit prompt |
| reflectCoverage | src/main.ts:312 | tests/dom/main-player.test.ts | dom | tested via updatePlayerBar and PiP (body.video-covered) |
| reflectPip | src/main.ts:316 | tests/dom/main-fullscreen.test.ts | dom | tested via setVideoPip and player-pip |
| hashOf | src/main.ts:341 | tests/dom/main-boot.test.ts | dom | tested via hashchange back trail |
| goBack | src/main.ts:352 | tests/dom/main-boot.test.ts | dom | tested via Back button, Alt+Left, mouse button 3 |
| atHome | src/main.ts:363 | tests/dom/main-boot.test.ts | dom | tested via back trail and next-up-changed |
| updateBackButton | src/main.ts:368 | tests/dom/main-boot.test.ts | dom | tested via back trail |
| SERVER_PAGES | src/main.ts:371 | tests/dom/main-boot.test.ts | dom | tested via route (offline pages) |
| renderOffline | src/main.ts:376 | tests/dom/main-boot.test.ts | dom | tested (Go to Downloads, Retry connection) |
| highlightNav | src/main.ts:410 | tests/dom/main-shell.test.ts | dom | tested (active entry, aria-current) |
| settleScroll | src/main.ts:428 | tests/dom/main-boot.test.ts | dom | tested via scroll memory |
| route | src/main.ts:441 | tests/dom/main-boot.test.ts | dom | tested |
| VIEWS_CACHE_KEY | src/main.ts:494 | tests/dom/main-shell.test.ts | dom | tested via buildNav (cache across launches) |
| viewsSignature | src/main.ts:498 | tests/dom/main-shell.test.ts | dom | tested via buildNav (redraw only on change) |
| buildNav | src/main.ts:502 | tests/dom/main-shell.test.ts | dom | tested (cached paint, failure, refresh) |
| paintNav | src/main.ts:531 | tests/dom/main-shell.test.ts | dom | tested (libraries, music, books, Collections, Live TV) |
| updateSidebarFooter | src/main.ts:602 | tests/dom/main-shell.test.ts | dom | tested |
| updateOfflinePill | src/main.ts:637 | tests/dom/main-shell.test.ts | dom | tested via aquarium-connectivity |
| cacheOwner | src/main.ts:643 | tests/dom/main-shell.test.ts | dom | tested via showShell/boot |
| showShell | src/main.ts:648 | tests/dom/main-boot.test.ts | dom | tested (boot; first sign-in in main-shell.test.ts) |
| showLogin | src/main.ts:682 | tests/dom/main-boot.test.ts | dom | tested (boot, Settings sign-out, auth expired, identity change) |
| showAddAccount | src/main.ts:699 | tests/dom/main-shell.test.ts | dom | tested (Cancel, sign-in) |
| enterAccount | src/main.ts:716 | tests/dom/main-shell.test.ts | dom | tested via switch and Add Account; player stop in main-fullscreen.test.ts |
| switchToAccount | src/main.ts:726 | tests/dom/main-shell.test.ts | dom | tested (success, failure) |
| PB_ICONS | src/main.ts:740 | tests/dom/main-player.test.ts | dom | tested via play/pause, volume and skip glyphs |
| skipIcon | src/main.ts:796 | tests/dom/main-player.test.ts | dom | tested via syncSkipButtons |
| syncSkipButtons | src/main.ts:803 | tests/dom/main-player.test.ts | dom | tested (interval from Settings, live change) |
| pbButton | src/main.ts:819 | tests/dom/main-player.test.ts | dom | tested (click and error logged to ui_log) |
| chapterNameAt | src/main.ts:857 | tests/dom/main-player.test.ts | dom | tested via scrubber readout |
| renderChapters | src/main.ts:868 | tests/dom/main-player.test.ts | dom | tested |
| closeBarPanel | src/main.ts:898 | tests/dom/main-panels.test.ts | dom | tested |
| toggleBarPanel | src/main.ts:902 | tests/dom/main-panels.test.ts | dom | tested |
| toggleQualityPicker | src/main.ts:925 | tests/dom/main-panels.test.ts | dom | tested |
| languageName | src/main.ts:990 | tests/dom/main-panels.test.ts | dom | tested via trackLabel |
| trackLabel | src/main.ts:1003 | tests/dom/main-panels.test.ts | dom | tested |
| toggleAudioPanel | src/main.ts:1010 | tests/dom/main-panels.test.ts | dom | tested |
| toggleSubtitlePanel | src/main.ts:1031 | tests/dom/main-panels.test.ts | dom | tested |
| togglePlaybackPanel | src/main.ts:1064 | tests/dom/main-panels.test.ts | dom | tested |
| togglePicturePanel | src/main.ts:1132 | tests/dom/main-panels.test.ts | dom | tested |
| toggleEpisodePanel | src/main.ts:1232 | tests/dom/main-panels.test.ts | dom | tested (its .catch at 1330 is unreachable: getEpisodeQueue never rejects) |
| toggleChannelsPanel | src/main.ts:1353 | tests/dom/main-panels.test.ts | dom | tested |
| toggleSleepPanel | src/main.ts:1357 | tests/dom/main-panels.test.ts | dom | tested |
| toggleChapterPanel | src/main.ts:1417 | tests/dom/main-panels.test.ts | dom | tested |
| mbps | src/main.ts:1459 | tests/dom/main-panels.test.ts | dom | tested via stream info Bitrate |
| deliveryLabel | src/main.ts:1465 | tests/dom/main-panels.test.ts | dom | tested (server-stream, local and live branches) |
| toggleInfoPanel | src/main.ts:1483 | tests/dom/main-panels.test.ts | dom | tested |
| queueTiles | src/main.ts:1539 | tests/dom/main-panels.test.ts | dom | tested (play, right-click remove) |
| VOLUME_THROTTLE_MS | src/main.ts:1575 | tests/dom/main-controls.test.ts | dom | tested via buildVolume throttle |
| setRangeFill | src/main.ts:1582 | tests/dom/main-player.test.ts | dom | tested via scrubber, volume and picture sliders |
| volumeIcon | src/main.ts:1586 | tests/dom/main-controls.test.ts | dom | tested |
| buildVolume | src/main.ts:1591 | tests/dom/main-controls.test.ts | dom | tested (throttle, change, pointerup, unmute) |
| bumpVolume | src/main.ts:1640 | tests/dom/main-controls.test.ts | dom | tested via ArrowUp/ArrowDown |
| stepSpeed | src/main.ts:1657 | tests/dom/main-controls.test.ts | dom | tested via [ and ] |
| resetMediaExtras | src/main.ts:1682 | tests/dom/main-player.test.ts | dom | tested via new item (segments, trickplay, next available, stalls reset) |
| trickplayTile | src/main.ts:1714 | tests/dom/main-player.test.ts | dom | tested (fetched once, failure not retried) |
| showScrubPreview | src/main.ts:1732 | tests/dom/main-player.test.ts | dom | tested |
| hideScrubPreview | src/main.ts:1764 | tests/dom/main-player.test.ts | dom | tested |
| segmentAt | src/main.ts:1769 | tests/dom/main-player.test.ts | dom | tested via skip button |
| syncSkipButton | src/main.ts:1777 | tests/dom/main-player.test.ts | dom | tested |
| UPNEXT_LEAD | src/main.ts:1793 | tests/dom/main-controls.test.ts | dom | tested via syncUpNext |
| syncUpNext | src/main.ts:1795 | tests/dom/main-controls.test.ts | dom | tested |
| upNextKey | src/main.ts:1833 | tests/dom/main-controls.test.ts | dom | tested via thumbnail fetched once |
| upNextTitle | src/main.ts:1842 | tests/dom/main-controls.test.ts | dom | tested |
| dismissUpNext | src/main.ts:1854 | tests/dom/main-controls.test.ts | dom | tested (Not now) |
| upNextShowing | src/main.ts:1861 | tests/dom/main-controls.test.ts | dom | tested via Enter |
| startUpNext | src/main.ts:1865 | tests/dom/main-controls.test.ts | dom | tested (once, failure toast) |
| playerTitleLines | src/main.ts:1882 | tests/dom/main-player.test.ts | dom | tested (episode, film, download record, channel) |
| buildPlayerBar | src/main.ts:1908 | tests/dom/main-player.test.ts | dom | tested (every control; pointer handlers in main-fullscreen.test.ts) |
| barNoteShowing | src/main.ts:2116 | tests/dom/main-controls.test.ts | dom | tested |
| flashBarNote | src/main.ts:2120 | tests/dom/main-controls.test.ts | dom | tested |
| toggleSubtitles | src/main.ts:2131 | tests/dom/main-controls.test.ts | dom | tested |
| skipSegment | src/main.ts:2153 | tests/dom/main-player.test.ts | dom | tested via s and ctl skip |
| skipBy | src/main.ts:2161 | tests/dom/main-controls.test.ts | dom | tested (not on live) |
| nudgeAudioDelay | src/main.ts:2168 | tests/dom/main-controls.test.ts | dom | tested (keys, picture input, tune panel) |
| openInfo | src/main.ts:2179 | tests/dom/main-controls.test.ts | dom | tested |
| openPictureMenu | src/main.ts:2191 | tests/dom/main-controls.test.ts | dom | tested |
| onPlayerInput | src/main.ts:2253 | tests/dom/main-controls.test.ts | dom | tested (keys, ctl, gestures, context) |
| barOutOfSight | src/main.ts:2336 | tests/dom/main-fullscreen.test.ts | dom | tested |
| updatePlayerBar | src/main.ts:2340 | tests/dom/main-player.test.ts | dom | tested |
| syncAudioState | src/main.ts:2449 | tests/dom/main-controls.test.ts | dom | tested |
| SEARCH_DEBOUNCE_MS | src/main.ts:2482 | tests/dom/main-shell.test.ts | dom | tested via wireSearch |
| gotoSearch | src/main.ts:2489 | tests/dom/main-shell.test.ts | dom | tested (push once, then replace) |
| wireSearch | src/main.ts:2500 | tests/dom/main-shell.test.ts | dom | tested |
| isTyping | src/main.ts:2590 | tests/dom/main-shell.test.ts | dom | tested via /, ? and spatial nav |
| wireGlobalKeys | src/main.ts:2597 | tests/dom/main-shell.test.ts | dom | tested (? sheet; Alt+Left in main-boot.test.ts) |
| SHORTCUTS | src/main.ts:2621 | tests/dom/main-shell.test.ts | dom | tested via toggleShortcuts |
| toggleShortcuts | src/main.ts:2675 | tests/dom/main-shell.test.ts | dom | tested (open/close/Escape, reopening after its Close button) |
| askBeforeQuit | src/main.ts:2721 | tests/dom/main-fullscreen.test.ts | dom | tested |
| LAST_ROUTE_KEY / RESUMABLE | src/main.ts:2762 | tests/dom/main-boot.test.ts | dom | tested via rememberRoute/lastRoute |
| rememberRoute | src/main.ts:2767 | tests/dom/main-boot.test.ts | dom | tested |
| lastRoute | src/main.ts:2778 | tests/dom/main-boot.test.ts | dom | tested |
| boot | src/main.ts:2789 | tests/dom/main-boot.test.ts | dom | tested (every listener exercised across the main-*.test.ts files) |
| stopServerRetry (in boot) | src/main.ts:2963 | tests/dom/main-shell.test.ts | dom | tested |
| scheduleServerRetry (in boot) | src/main.ts:2971 | tests/dom/main-shell.test.ts | dom | tested (15 s, doubling, 5 min cap, network and visibility cues) |
| row | src/views/settings.ts:22 | tests/dom/views-settings.test.ts | dom | tested via renderSettings |
| choice | src/views/settings.ts:33 | tests/dom/views-settings.test.ts | dom | tested (save, save failure, onPicked) |
| batteryRenderChoice | src/views/settings.ts:56 | tests/dom/views-settings.test.ts | dom | tested (old true/false configs) |
| toggle | src/views/settings.ts:68 | tests/dom/views-settings.test.ts | dom | tested |
| slider | src/views/settings.ts:93 | tests/dom/views-settings.test.ts | dom | tested (live apply, reset, scale) |
| LANGUAGES | src/views/settings.ts:143 | tests/dom/views-settings.test.ts | dom | tested |
| lastDecoder | src/views/settings.ts:173 | tests/dom/views-settings.test.ts | dom | tested (storage failure) |
| DECODER_NAMES | src/views/settings.ts:181 | tests/dom/views-settings.test.ts | dom | tested |
| downloadsBlock | src/views/settings.ts:193 | tests/dom/views-settings.test.ts | dom | tested |
| renderSettings | src/views/settings.ts:221 | tests/dom/views-settings.test.ts | dom | tested (every block; stale-page guards) |
| drawAccounts (in renderSettings) | src/views/settings.ts:337 | tests/dom/views-settings.test.ts | dom | tested |
| qcSay / qcConfirm (in renderSettings) | src/views/settings.ts:417 | tests/dom/views-settings.test.ts | dom | tested |
| syncLastRead (in renderSettings) | src/views/settings.ts:703 | tests/dom/views-settings.test.ts | dom | tested |
| refreshNow (in renderSettings) | src/views/settings.ts:726 | tests/dom/views-settings.test.ts | dom | tested |
| checkArtwork (in renderSettings) | src/views/settings.ts:746 | tests/dom/views-settings.test.ts | dom | tested |
| syncLiveRows (in renderSettings) | src/views/settings.ts:771 | tests/dom/views-settings.test.ts | dom | tested |
| checkSources (in renderSettings) | src/views/settings.ts:793 | tests/dom/views-settings.test.ts | dom | tested |
| probeArtwork | src/views/settings.ts:1132 | tests/dom/views-settings.test.ts | dom | tested via Check artwork (timeout, unnamed, failures) |
| el | src/ui.ts:9 | tests/dom/ui.test.ts | dom | tested |
| clear | src/ui.ts:30 | tests/dom/ui.test.ts | dom | tested |
| asButton | src/ui.ts:41 | tests/dom/ui.test.ts | dom | tested |
| spinner | src/ui.ts:54 | tests/dom/ui.test.ts | dom | tested |
| noart | src/ui.ts:61 | tests/dom/ui.test.ts | dom | tested |
| noartIcon | src/ui.ts:67 | tests/dom/ui.test.ts | dom | tested |
| art | src/ui.ts:79 | tests/dom/ui.test.ts | dom | tested |
| backdropLayer | src/ui.ts:127 | tests/dom/ui.test.ts | dom | tested |
| heroTitle | src/ui.ts:150 | tests/dom/ui.test.ts | dom | tested |
| liftTint | src/ui.ts:171 | tests/dom/ui.test.ts | dom | tested via ambientTint |
| dominantColor | src/ui.ts:189 | tests/dom/ui.test.ts | dom | tested via ambientTint (canvas stubbed: jsdom has no 2D context) |
| ambientTint | src/ui.ts:233 | tests/dom/ui.test.ts | dom | tested |
| times | src/ui.ts:249 | tests/dom/ui.test.ts | dom | tested via skeletons |
| skeletonCards | src/ui.ts:253 | tests/dom/ui.test.ts | dom | tested |
| skeletonRow | src/ui.ts:264 | tests/dom/ui.test.ts | dom | tested |
| skeletonGrid | src/ui.ts:269 | tests/dom/ui.test.ts | dom | tested |
| skeletonRows | src/ui.ts:277 | tests/dom/ui.test.ts | dom | tested |
| skeletonDetail | src/ui.ts:294 | tests/dom/ui.test.ts | dom | tested |
| emptyState | src/ui.ts:331 | tests/dom/ui.test.ts | dom | tested |
| errorState | src/ui.ts:344 | tests/dom/ui.test.ts | dom | tested |
| openDialog | src/ui.ts:374 | tests/dom/ui.test.ts | dom | tested |
| toast | src/ui.ts:456 | tests/dom/ui.test.ts | dom | tested |
| RECENT_KEY / RECENT_MAX | src/ui.ts:469 | tests/dom/ui.test.ts | dom | tested via recentSearches |
| recentSearches | src/ui.ts:472 | tests/dom/ui.test.ts | dom | tested |
| rememberSearch | src/ui.ts:483 | tests/dom/ui.test.ts | dom | tested |
| clearRecentSearches | src/ui.ts:495 | tests/dom/ui.test.ts | dom | tested |
| closeMenus | src/ui.ts:507 | tests/dom/ui.test.ts | dom | tested |
| rectOf | src/ui.ts:521 | tests/dom/ui.test.ts | dom | tested via openMenu |
| positionFixed | src/ui.ts:535 | tests/dom/ui.test.ts | dom | tested (clamp, flip, cap) |
| wireMenuKeys | src/ui.ts:557 | tests/dom/ui.test.ts | dom | tested |
| openMenu | src/ui.ts:596 | tests/dom/ui.test.ts | dom | tested |
| fillMenu | src/ui.ts:696 | tests/dom/ui.test.ts | dom | tested |
| openActionMenu | src/ui.ts:747 | tests/dom/ui.test.ts | dom | tested |
| attachContextMenu | src/ui.ts:762 | tests/dom/ui.test.ts | dom | tested |
| downloadLabel | src/ui.ts:783 | tests/dom/ui.test.ts | dom | tested |
| downloadAction | src/ui.ts:792 | tests/dom/ui.test.ts | dom | tested (regression 4fe2d31 season downloads) |
| queueActions | src/ui.ts:839 | tests/dom/ui.test.ts | dom | tested |
| showIdOf | src/ui.ts:866 | tests/dom/ui.test.ts | dom | tested via itemActions/askAddToNextUp |
| showNameOf | src/ui.ts:872 | tests/dom/ui.test.ts | dom | tested via askAddToNextUp |
| nextUpChanged | src/ui.ts:877 | tests/dom/ui.test.ts | dom | tested |
| askAddToNextUp | src/ui.ts:886 | tests/dom/ui.test.ts | dom | tested |
| removeShowFromNextUp | src/ui.ts:923 | tests/dom/ui.test.ts | dom | tested via itemActions nextUp |
| itemActions | src/ui.ts:934 | tests/dom/ui.test.ts | dom | tested (regression a963a95 Resume label) |
| progressPct | src/ui.ts:1036 | tests/dom/ui.test.ts | dom | tested via itemCard |
| itemCard | src/ui.ts:1042 | tests/dom/ui.test.ts | dom | tested (regression 56a1825 BoxSet opens a grid) |
| ROW_CHEVRON | src/ui.ts:1193 | tests/dom/ui.test.ts | dom | tested via scrollRow |
| scrollRow | src/ui.ts:1204 | tests/dom/ui.test.ts | dom | tested |
| cardRow | src/ui.ts:1237 | tests/dom/ui.test.ts | dom | tested |
| section | src/ui.ts:1244 | tests/dom/ui.test.ts | dom | tested (regression a963a95 See all from the keyboard) |

### src/views/*.ts except settings

| Function | Source | Test file | Kind | Status |
| --- | --- | --- | --- | --- |
| report | src/views/books.ts:17 | tests/dom/views-books.test.ts | dom | tested via renderBooks |
| renderBooks | src/views/books.ts:21 | tests/dom/views-books.test.ts | dom | tested |
| author | src/views/books.ts:36 | tests/dom/views-books.test.ts | dom | tested via renderBooks |
| timeLeft | src/views/books.ts:40 | tests/dom/views-books.test.ts | dom | tested via renderBooks |
| bookCard | src/views/books.ts:47 | tests/dom/views-books.test.ts | dom | tested via renderBooks |
| bookActions | src/views/books.ts:69 | tests/dom/views-books.test.ts | dom | tested via renderBooks |
| detailed | src/views/books.ts:92 | tests/dom/views-books.test.ts | dom | tested via renderBooks |
| partsOf | src/views/books.ts:98 | tests/dom/views-books.test.ts | dom | tested via renderBooks |
| playBook | src/views/books.ts:104 | tests/dom/views-books.test.ts | dom | tested |
| booksTabs | src/views/books.ts:121 | tests/dom/views-books.test.ts | dom | tested via renderBooks |
| allBooks | src/views/books.ts:136 | tests/dom/views-books.test.ts | dom | tested via renderBooks |
| authorsOf | src/views/books.ts:141 | tests/dom/views-books.test.ts | dom | tested via renderBooks |
| names (inner) | src/views/books.ts:144 | tests/dom/views-books.test.ts | dom | tested via renderBooks |
| renderHome | src/views/books.ts:150 | tests/dom/views-books.test.ts | dom | tested via renderBooks |
| paint (inner) | src/views/books.ts:154 | tests/dom/views-books.test.ts | dom | tested via renderBooks |
| sig (inner) | src/views/books.ts:174 | tests/dom/views-books.test.ts | dom | tested via renderBooks |
| fresh (inner) | src/views/books.ts:183 | tests/dom/views-books.test.ts | dom | tested via renderBooks |
| renderAll | src/views/books.ts:199 | tests/dom/views-books.test.ts | dom | tested via renderBooks |
| sort (inner) | src/views/books.ts:201 | tests/dom/views-books.test.ts | dom | tested via renderBooks |
| paint (inner) | src/views/books.ts:213 | tests/dom/views-books.test.ts | dom | tested via renderBooks |
| renderAuthor | src/views/books.ts:240 | tests/dom/views-books.test.ts | dom | tested via renderBooks |
| paint (inner) | src/views/books.ts:244 | tests/dom/views-books.test.ts | dom | tested via renderBooks |
| renderBook | src/views/books.ts:263 | tests/dom/views-books.test.ts | dom | tested via renderBooks |
| paint (inner) | src/views/books.ts:265 | tests/dom/views-books.test.ts | dom | tested via renderBooks |
| renderSearch | src/views/books.ts:338 | tests/dom/views-books.test.ts | dom | tested via renderBooks |
| run (inner) | src/views/books.ts:342 | tests/dom/views-books.test.ts | dom | tested via renderBooks |
| loadPrefs | src/views/favorites.ts:36 | tests/dom/views-favorites.test.ts | dom | tested via renderFavorites |
| savePrefs | src/views/favorites.ts:49 | tests/dom/views-favorites.test.ts | dom | tested via renderFavorites |
| renderFavorites | src/views/favorites.ts:57 | tests/dom/views-favorites.test.ts | dom | tested |
| cacheKey (inner) | src/views/favorites.ts:67 | tests/dom/views-favorites.test.ts | dom | tested via renderFavorites |
| setCount (inner) | src/views/favorites.ts:117 | tests/dom/views-favorites.test.ts | dom | tested via renderFavorites |
| onCardChanged (inner) | src/views/favorites.ts:124 | tests/dom/views-favorites.test.ts | dom | tested via renderFavorites |
| showEmpty (inner) | src/views/favorites.ts:134 | tests/dom/views-favorites.test.ts | dom | tested via renderFavorites |
| loadPage (inner) | src/views/favorites.ts:161 | tests/dom/views-favorites.test.ts | dom | tested via renderFavorites |
| revalidateFirstPage (inner) | src/views/favorites.ts:216 | tests/dom/views-favorites.test.ts | dom | tested via renderFavorites |
| favoritesRow | src/views/favorites.ts:260 | tests/dom/views-favorites.test.ts | dom | tested |
| continueWatchingHidden | src/views/home.ts:41 | tests/dom/views-home.test.ts | dom | tested via renderHome |
| homeSignature | src/views/home.ts:45 | tests/dom/views-home.test.ts | dom | tested via renderHome |
| fetchHomeData | src/views/home.ts:60 | tests/dom/views-home.test.ts | dom | tested via renderHome |
| libraryChips | src/views/home.ts:86 | tests/dom/views-home.test.ts | dom | tested via renderHome |
| homeHero | src/views/home.ts:104 | tests/dom/views-home.test.ts | dom | tested via renderHome |
| wireInputClock | src/views/home.ts:195 | tests/dom/views-home.test.ts | dom | tested via renderHome |
| touch (inner) | src/views/home.ts:198 | tests/dom/views-home.test.ts | dom | tested via renderHome |
| heroRotator | src/views/home.ts:217 | tests/dom/views-home.test.ts | dom | tested via renderHome |
| show (inner) | src/views/home.ts:237 | tests/dom/views-home.test.ts | dom | tested via renderHome |
| stop (inner) | src/views/home.ts:266 | tests/dom/views-home.test.ts | dom | tested via renderHome |
| unseen (inner) | src/views/home.ts:281 | tests/dom/views-home.test.ts | dom | tested via renderHome |
| restart (inner) | src/views/home.ts:287 | tests/dom/views-home.test.ts | dom | tested via renderHome |
| paintHome | src/views/home.ts:305 | tests/dom/views-home.test.ts | dom | tested via renderHome |
| picks (inner) | src/views/home.ts:316 | tests/dom/views-home.test.ts | dom | tested via renderHome |
| placeFavorites (inner) | src/views/home.ts:328 | tests/dom/views-home.test.ts | dom | tested via renderHome |
| renderHome | src/views/home.ts:406 | tests/dom/views-home.test.ts | dom | tested |
| prefsKey | src/views/library.ts:38 | tests/dom/views-library.test.ts | dom | tested via renderLibrary |
| loadPrefs | src/views/library.ts:40 | tests/dom/views-library.test.ts | dom | tested via renderLibrary |
| savePrefs | src/views/library.ts:55 | tests/dom/views-library.test.ts | dom | tested via renderLibrary |
| toggleChip | src/views/library.ts:64 | tests/dom/views-library.test.ts | dom | tested via renderLibrary |
| renderLibrary | src/views/library.ts:82 | tests/dom/views-library.test.ts | dom | tested |
| cacheKey (inner) | src/views/library.ts:120 | tests/dom/views-library.test.ts | dom | tested via renderLibrary |
| clearFilters (inner) | src/views/library.ts:194 | tests/dom/views-library.test.ts | dom | tested via renderLibrary |
| loadPage (inner) | src/views/library.ts:216 | tests/dom/views-library.test.ts | dom | tested via renderLibrary |
| revalidateFirstPage (inner) | src/views/library.ts:306 | tests/dom/views-library.test.ts | dom | tested via renderLibrary |
| renderSearch | src/views/library.ts:374 | tests/dom/views-library.test.ts | dom | tested |
| paint (inner) | src/views/library.ts:402 | tests/dom/views-library.test.ts | dom | tested via renderSearch |
| loadPage (inner) | src/views/library.ts:432 | tests/dom/views-library.test.ts | dom | tested via renderSearch |
| firstFrame | src/views/livetv.ts:68 | tests/dom/views-livetv.test.ts | dom | tested via tune (player-status, 15 s cap) |
| endTuning | src/views/livetv.ts:81 | tests/dom/views-livetv.test.ts | dom | tested via tune |
| tune | src/views/livetv.ts:88 | tests/dom/views-livetv.test.ts | dom | tested via renderLiveTv, tuneChannel |
| t (inner) | src/views/livetv.ts:104 | tests/dom/views-livetv.test.ts | dom | tested via renderLiveTv |
| cancel (inner) | src/views/livetv.ts:114 | tests/dom/views-livetv.test.ts | dom | tested via tune (Cancel button) |
| fmtTime | src/views/livetv.ts:156 | tests/dom/views-livetv.test.ts | dom | tested via renderLiveTv, showProgram |
| fmtDay | src/views/livetv.ts:159 | tests/dom/views-livetv.test.ts | dom | tested via dayLabel, showProgram |
| startOfDay | src/views/livetv.ts:162 | tests/dom/views-livetv.test.ts | dom | tested via dayLabel |
| dayLabel | src/views/livetv.ts:169 | tests/dom/views-livetv.test.ts | dom | tested |
| localInputValue | src/views/livetv.ts:178 | tests/dom/views-livetv.test.ts | dom | tested via renderLiveTv |
| p (inner) | src/views/livetv.ts:180 | tests/dom/views-livetv.test.ts | dom | tested via renderLiveTv |
| floorToSlot | src/views/livetv.ts:185 | tests/dom/views-livetv.test.ts | dom | tested via renderLiveTv |
| channelLabel | src/views/livetv.ts:190 | tests/dom/views-livetv.test.ts | dom | tested via renderLiveTv |
| channelCell | src/views/livetv.ts:194 | tests/dom/views-livetv.test.ts | dom | tested via renderLiveTv |
| showProgram | src/views/livetv.ts:215 | tests/dom/views-livetv.test.ts | dom | tested via renderLiveTv |
| channelList | src/views/livetv.ts:245 | tests/dom/views-livetv.test.ts | dom | tested via renderLiveTv |
| channelSignature | src/views/livetv.ts:275 | tests/dom/views-livetv.test.ts | dom | tested via renderLiveTv |
| renderLiveTv | src/views/livetv.ts:281 | tests/dom/views-livetv.test.ts | dom | tested |
| onChanged (inner) | src/views/livetv.ts:303 | tests/dom/views-livetv.test.ts | dom | tested via renderLiveTv |
| paintLiveTv | src/views/livetv.ts:357 | tests/dom/views-livetv.test.ts | dom | tested via renderLiveTv |
| watch (inner) | src/views/livetv.ts:358 | tests/dom/views-livetv.test.ts | dom | tested via renderLiveTv |
| earliest (inner) | src/views/livetv.ts:431 | tests/dom/views-livetv.test.ts | dom | tested via renderLiveTv |
| windowEnd (inner) | src/views/livetv.ts:432 | tests/dom/views-livetv.test.ts | dom | tested via renderLiveTv |
| offsetPx (inner) | src/views/livetv.ts:434 | tests/dom/views-livetv.test.ts | dom | tested via renderLiveTv |
| laneWidth (inner) | src/views/livetv.ts:435 | tests/dom/views-livetv.test.ts | dom | tested via renderLiveTv |
| visibleChannels (inner) | src/views/livetv.ts:443 | tests/dom/views-livetv.test.ts | dom | tested via renderLiveTv |
| renderHead (inner) | src/views/livetv.ts:451 | tests/dom/views-livetv.test.ts | dom | tested via renderLiveTv |
| syncNow (inner) | src/views/livetv.ts:485 | tests/dom/views-livetv.test.ts | dom | tested via renderLiveTv |
| renderRows (inner) | src/views/livetv.ts:496 | tests/dom/views-livetv.test.ts | dom | tested via renderLiveTv |
| progs (inner) | src/views/livetv.ts:514 | tests/dom/views-livetv.test.ts | dom | tested via renderLiveTv |
| blockAt (inner) | src/views/livetv.ts:559 | tests/dom/views-livetv.test.ts | dom | tested via renderLiveTv |
| selectAt (inner) | src/views/livetv.ts:574 | tests/dom/views-livetv.test.ts | dom | tested via renderLiveTv |
| select (inner) | src/views/livetv.ts:581 | tests/dom/views-livetv.test.ts | dom | tested via renderLiveTv |
| paintSelection (inner) | src/views/livetv.ts:586 | tests/dom/views-livetv.test.ts | dom | tested via renderLiveTv |
| rowIndex (inner) | src/views/livetv.ts:602 | tests/dom/views-livetv.test.ts | dom | tested via renderLiveTv |
| anchor (inner) | src/views/livetv.ts:605 | tests/dom/views-livetv.test.ts | dom | tested via renderLiveTv |
| moveSel (inner) | src/views/livetv.ts:613 | tests/dom/views-livetv.test.ts | dom | tested via renderLiveTv |
| selectedChannel (inner) | src/views/livetv.ts:639 | tests/dom/views-livetv.test.ts | dom | tested via renderLiveTv |
| typeSelect (inner) | src/views/livetv.ts:647 | tests/dom/views-livetv.test.ts | dom | tested via renderLiveTv |
| load (inner) | src/views/livetv.ts:710 | tests/dom/views-livetv.test.ts | dom | tested via renderLiveTv |
| jumpTo (inner) | src/views/livetv.ts:761 | tests/dom/views-livetv.test.ts | dom | tested via renderLiveTv |
| shift (inner) | src/views/livetv.ts:777 | tests/dom/views-livetv.test.ts | dom | tested via renderLiveTv |
| toNow (inner) | src/views/livetv.ts:778 | tests/dom/views-livetv.test.ts | dom | tested via renderLiveTv |
| onKey (inner) | src/views/livetv.ts:819 | tests/dom/views-livetv.test.ts | dom | tested via renderLiveTv |
| tuneChannel | src/views/livetv.ts:854 | tests/dom/views-livetv.test.ts | dom | tested |
| onNow | src/views/livetv.ts:863 | tests/dom/views-livetv.test.ts | dom | tested |
| onNowCard | src/views/livetv.ts:869 | tests/dom/views-livetv.test.ts | dom | tested |
| report | src/views/music.ts:25 | tests/dom/views-music.test.ts | dom | tested via renderMusic |
| trackPlaying | src/views/music.ts:30 | tests/dom/views-music.test.ts | dom | tested via renderMusic |
| renderMusic | src/views/music.ts:37 | tests/dom/views-music.test.ts | dom | tested |
| discoverSig | src/views/music.ts:72 | tests/dom/views-music.test.ts | dom | tested via renderMusic |
| genreByName | src/views/music.ts:78 | tests/dom/views-music.test.ts | dom | tested via renderMusic |
| fetchDiscover | src/views/music.ts:86 | tests/dom/views-music.test.ts | dom | tested via renderMusic |
| none (inner) | src/views/music.ts:87 | tests/dom/views-music.test.ts | dom | tested via renderMusic |
| shuffleAllFrom | src/views/music.ts:126 | tests/dom/views-music.test.ts | dom | tested via renderMusic |
| stationTile | src/views/music.ts:135 | tests/dom/views-music.test.ts | dom | tested via renderMusic |
| musicTabs | src/views/music.ts:143 | tests/dom/views-music.test.ts | dom | tested via renderMusic |
| renderDiscover | src/views/music.ts:159 | tests/dom/views-music.test.ts | dom | tested via renderMusic |
| paint (inner) | src/views/music.ts:171 | tests/dom/views-music.test.ts | dom | tested via renderMusic |
| renderSongChart | src/views/music.ts:215 | tests/dom/views-music.test.ts | dom | tested via renderMusic |
| paint (inner) | src/views/music.ts:222 | tests/dom/views-music.test.ts | dom | tested via renderMusic |
| openMixDialog | src/views/music.ts:241 | tests/dom/views-music.test.ts | dom | tested |
| draw (inner) | src/views/music.ts:244 | tests/dom/views-music.test.ts | dom | tested via renderMusic |
| libPrefs | src/views/music.ts:298 | tests/dom/views-music.test.ts | dom | tested via renderMusic |
| saveLibPrefs | src/views/music.ts:308 | tests/dom/views-music.test.ts | dom | tested via renderMusic |
| renderLibrary | src/views/music.ts:316 | tests/dom/views-music.test.ts | dom | tested via renderMusic |
| fromParam (inner) | src/views/music.ts:331 | tests/dom/views-music.test.ts | dom | tested via renderMusic |
| fetchPage (inner) | src/views/music.ts:353 | tests/dom/views-music.test.ts | dom | tested via renderMusic |
| append (inner) | src/views/music.ts:366 | tests/dom/views-music.test.ts | dom | tested via renderMusic |
| more (inner) | src/views/music.ts:383 | tests/dom/views-music.test.ts | dom | tested |
| reset (inner) | src/views/music.ts:404 | tests/dom/views-music.test.ts | dom | tested via renderMusic |
| renderGenresTab | src/views/music.ts:457 | tests/dom/views-music.test.ts | dom | tested |
| paint (inner) | src/views/music.ts:461 | tests/dom/views-music.test.ts | dom | tested via renderMusic |
| renderPlaylistsTab | src/views/music.ts:481 | tests/dom/views-music.test.ts | dom | tested via renderMusic |
| paint (inner) | src/views/music.ts:489 | tests/dom/views-music.test.ts | dom | tested via renderMusic |
| refresh (inner) | src/views/music.ts:503 | tests/dom/views-music.test.ts | dom | tested via renderMusic |
| onChange (inner) | src/views/music.ts:511 | tests/dom/views-music.test.ts | dom | tested via renderMusic |
| renderAlbum | src/views/music.ts:518 | tests/dom/views-music.test.ts | dom | tested via renderMusic |
| paint (inner) | src/views/music.ts:520 | tests/dom/views-music.test.ts | dom | tested via renderMusic |
| fresh (inner) | src/views/music.ts:549 | tests/dom/views-music.test.ts | dom | tested via renderMusic |
| renderArtist | src/views/music.ts:557 | tests/dom/views-music.test.ts | dom | tested via renderMusic |
| paint (inner) | src/views/music.ts:559 | tests/dom/views-music.test.ts | dom | tested via renderMusic |
| fresh (inner) | src/views/music.ts:607 | tests/dom/views-music.test.ts | dom | tested via renderMusic |
| sig (inner) | src/views/music.ts:609 | tests/dom/views-music.test.ts | dom | tested via renderMusic |
| renderGenre | src/views/music.ts:616 | tests/dom/views-music.test.ts | dom | tested via renderMusic |
| paint (inner) | src/views/music.ts:618 | tests/dom/views-music.test.ts | dom | tested via renderMusic |
| fresh (inner) | src/views/music.ts:643 | tests/dom/views-music.test.ts | dom | tested via renderMusic |
| renderPlaylist | src/views/music.ts:651 | tests/dom/views-music.test.ts | dom | tested via renderMusic |
| paint (inner) | src/views/music.ts:656 | tests/dom/views-music.test.ts | dom | tested via renderMusic |
| remove (inner) | src/views/music.ts:751 | tests/dom/views-music.test.ts | dom | tested via renderMusic |
| moveEntry (inner) | src/views/music.ts:763 | tests/dom/views-music.test.ts | dom | tested via renderMusic |
| row (inner) | src/views/music.ts:777 | tests/dom/views-music.test.ts | dom | tested via renderMusic |
| fresh (inner) | src/views/music.ts:789 | tests/dom/views-music.test.ts | dom | tested via renderMusic |
| renderSmart | src/views/music.ts:799 | tests/dom/views-music.test.ts | dom | tested via renderMusic |
| renderSmartEditor | src/views/music.ts:854 | tests/dom/views-music.test.ts | dom | tested via renderMusic |
| field (inner) | src/views/music.ts:860 | tests/dom/views-music.test.ts | dom | tested via renderMusic |
| input (inner) | src/views/music.ts:862 | tests/dom/views-music.test.ts | dom | tested via renderMusic |
| drawArtists (inner) | src/views/music.ts:871 | tests/dom/views-music.test.ts | dom | tested via renderMusic |
| renderMusicSearch | src/views/music.ts:950 | tests/dom/views-music.test.ts | dom | tested via renderMusic |
| run (inner) | src/views/music.ts:954 | tests/dom/views-music.test.ts | dom | tested via renderMusic |
| MI (icon set) | src/views/musicCommon.ts:17 | tests/dom/views-musicCommon.test.ts | dom | tested |
| mi | src/views/musicCommon.ts:47 | tests/dom/views-musicCommon.test.ts | dom | tested |
| iconButton | src/views/musicCommon.ts:53 | tests/dom/views-musicCommon.test.ts | dom | tested |
| routeFor | src/views/musicCommon.ts:60 | tests/dom/views-musicCommon.test.ts | dom | tested |
| songsOf | src/views/musicCommon.ts:75 | tests/dom/views-musicCommon.test.ts | dom | tested |
| report | src/views/musicCommon.ts:98 | tests/dom/views-musicCommon.test.ts | dom | tested via playThing, startStation, musicActions, songRow |
| playThing | src/views/musicCommon.ts:102 | tests/dom/views-musicCommon.test.ts | dom | tested |
| offlineMix | src/views/musicCommon.ts:126 | tests/dom/views-musicCommon.test.ts | dom | tested via startStation, instantMixFromCurrent (offline) |
| songs (inner) | src/views/musicCommon.ts:127 | tests/dom/views-musicCommon.test.ts | dom | tested via offlineMix |
| buildMix | src/views/musicCommon.ts:135 | tests/dom/views-musicCommon.test.ts | dom | tested via startStation, instantMixFromCurrent |
| startStation | src/views/musicCommon.ts:151 | tests/dom/views-musicCommon.test.ts | dom | tested |
| instantMixFromCurrent | src/views/musicCommon.ts:164 | tests/dom/views-musicCommon.test.ts | dom | tested |
| shuffleAll | src/views/musicCommon.ts:181 | tests/dom/views-musicCommon.test.ts | dom | tested |
| askName | src/views/musicCommon.ts:202 | tests/dom/views-musicCommon.test.ts | dom | tested |
| finish (inner) | src/views/musicCommon.ts:206 | tests/dom/views-musicCommon.test.ts | dom | tested via askName |
| playlistsChanged | src/views/musicCommon.ts:235 | tests/dom/views-musicCommon.test.ts | dom | tested |
| newPlaylistWith | src/views/musicCommon.ts:237 | tests/dom/views-musicCommon.test.ts | dom | tested |
| addTo | src/views/musicCommon.ts:250 | tests/dom/views-musicCommon.test.ts | dom | tested via addToPlaylistAction |
| primePlaylists | src/views/musicCommon.ts:267 | tests/dom/views-musicCommon.test.ts | dom | tested |
| addToPlaylistAction | src/views/musicCommon.ts:278 | tests/dom/views-musicCommon.test.ts | dom | tested |
| musicActions | src/views/musicCommon.ts:306 | tests/dom/views-musicCommon.test.ts | dom | tested |
| bitrateText | src/views/musicCommon.ts:347 | tests/dom/views-musicCommon.test.ts | dom | tested via showSongInfo |
| showSongInfo | src/views/musicCommon.ts:351 | tests/dom/views-musicCommon.test.ts | dom | tested |
| stream (inner) | src/views/musicCommon.ts:359 | tests/dom/views-musicCommon.test.ts | dom | tested via showSongInfo |
| add (inner) | src/views/musicCommon.ts:362 | tests/dom/views-musicCommon.test.ts | dom | tested via showSongInfo |
| musicCard | src/views/musicCommon.ts:400 | tests/dom/views-musicCommon.test.ts | dom | tested |
| shelf | src/views/musicCommon.ts:448 | tests/dom/views-musicCommon.test.ts | dom | tested |
| grid | src/views/musicCommon.ts:460 | tests/dom/views-musicCommon.test.ts | dom | tested |
| markPlaying | src/views/musicCommon.ts:480 | tests/dom/views-musicCommon.test.ts | dom | tested |
| songRow | src/views/musicCommon.ts:485 | tests/dom/views-musicCommon.test.ts | dom | tested |
| songList | src/views/musicCommon.ts:539 | tests/dom/views-musicCommon.test.ts | dom | tested |
| rowsIn | src/views/musicCommon.ts:558 | tests/dom/views-musicCommon.test.ts | dom | tested via songRow click, contextmenu |
| selectRow | src/views/musicCommon.ts:563 | tests/dom/views-musicCommon.test.ts | dom | tested via songRow click (plain, Ctrl/Meta, Shift) |
| selectedSongs | src/views/musicCommon.ts:579 | tests/dom/views-musicCommon.test.ts | dom | tested via songRow contextmenu, selection bar |
| selectionActions | src/views/musicCommon.ts:583 | tests/dom/views-musicCommon.test.ts | dom | tested via songRow contextmenu on a selection, selection bar |
| updateSelectionBar | src/views/musicCommon.ts:613 | tests/dom/views-musicCommon.test.ts | dom | tested via songRow click |
| pageHeader | src/views/musicCommon.ts:642 | tests/dom/views-musicCommon.test.ts | dom | tested |
| playButtons | src/views/musicCommon.ts:664 | tests/dom/views-musicCommon.test.ts | dom | tested |
| go (inner) | src/views/musicCommon.ts:666 | tests/dom/views-musicCommon.test.ts | dom | tested via playButtons |
| link | src/views/musicCommon.ts:685 | tests/dom/views-musicCommon.test.ts | dom | tested |
| slim | src/views/musicDownloads.ts:21 | tests/dom/views-musicDownloads.test.ts | dom | tested via downloadMusic |
| readMeta | src/views/musicDownloads.ts:32 | tests/dom/views-musicDownloads.test.ts | dom | tested via downloadMusic, downloadedItems |
| writeMeta | src/views/musicDownloads.ts:40 | tests/dom/views-musicDownloads.test.ts | dom | tested via downloadMusic |
| originalQuality | src/views/musicDownloads.ts:48 | tests/dom/views-musicDownloads.test.ts | dom | tested via downloadMusic |
| downloadMusic | src/views/musicDownloads.ts:53 | tests/dom/views-musicDownloads.test.ts | dom | tested |
| downloadMusicAction | src/views/musicDownloads.ts:80 | tests/dom/views-musicDownloads.test.ts | dom | tested |
| downloadBookAction | src/views/musicDownloads.ts:89 | tests/dom/views-musicDownloads.test.ts | dom | tested |
| downloadedItems | src/views/musicDownloads.ts:93 | tests/dom/views-musicDownloads.test.ts | dom | tested |
| renderDownloaded | src/views/musicDownloads.ts:112 | tests/dom/views-musicDownloads.test.ts | dom | tested |
| report | src/views/musicPlayer.ts:18 | tests/dom/views-musicPlayer.test.ts | dom | tested via wireMusicPlayer/openNowPlaying |
| subtitleOf | src/views/musicPlayer.ts:22 | tests/dom/views-musicPlayer.test.ts | dom | tested via wireMusicPlayer/openNowPlaying |
| swapIcon | src/views/musicPlayer.ts:31 | tests/dom/views-musicPlayer.test.ts | dom | tested via wireMusicPlayer/openNowPlaying |
| scrubber | src/views/musicPlayer.ts:40 | tests/dom/views-musicPlayer.test.ts | dom | tested via wireMusicPlayer/openNowPlaying |
| sleepActions | src/views/musicPlayer.ts:64 | tests/dom/views-musicPlayer.test.ts | dom | tested via wireMusicPlayer/openNowPlaying |
| speedActions | src/views/musicPlayer.ts:75 | tests/dom/views-musicPlayer.test.ts | dom | tested via wireMusicPlayer/openNowPlaying |
| volumeControl | src/views/musicPlayer.ts:80 | tests/dom/views-musicPlayer.test.ts | dom | tested via wireMusicPlayer/openNowPlaying |
| sync (inner) | src/views/musicPlayer.ts:90 | tests/dom/views-musicPlayer.test.ts | dom | tested via wireMusicPlayer/openNowPlaying |
| buildBar | src/views/musicPlayer.ts:103 | tests/dom/views-musicPlayer.test.ts | dom | tested via wireMusicPlayer/openNowPlaying |
| openNowPlaying | src/views/musicPlayer.ts:167 | tests/dom/views-musicPlayer.test.ts | dom | tested |
| closeNowPlaying | src/views/musicPlayer.ts:183 | tests/dom/views-musicPlayer.test.ts | dom | tested via wireMusicPlayer/openNowPlaying |
| buildNowPlaying | src/views/musicPlayer.ts:187 | tests/dom/views-musicPlayer.test.ts | dom | tested via wireMusicPlayer/openNowPlaying |
| drawPanel (inner) | src/views/musicPlayer.ts:246 | tests/dom/views-musicPlayer.test.ts | dom | tested via wireMusicPlayer/openNowPlaying |
| highlight (inner) | src/views/musicPlayer.ts:272 | tests/dom/views-musicPlayer.test.ts | dom | tested via wireMusicPlayer/openNowPlaying |
| upNextList | src/views/musicPlayer.ts:360 | tests/dom/views-musicPlayer.test.ts | dom | tested via wireMusicPlayer/openNowPlaying |
| lyricsView | src/views/musicPlayer.ts:421 | tests/dom/views-musicPlayer.test.ts | dom | tested via wireMusicPlayer/openNowPlaying |
| chaptersView | src/views/musicPlayer.ts:441 | tests/dom/views-musicPlayer.test.ts | dom | tested via wireMusicPlayer/openNowPlaying |
| sync | src/views/musicPlayer.ts:461 | tests/dom/views-musicPlayer.test.ts | dom | tested via wireMusicPlayer/openNowPlaying |
| isTyping | src/views/musicPlayer.ts:466 | tests/dom/views-musicPlayer.test.ts | dom | tested via wireMusicPlayer/openNowPlaying |
| wireMusicPlayer | src/views/musicPlayer.ts:472 | tests/dom/views-musicPlayer.test.ts | dom | tested |
| spaced | src/views/login.ts:12 | tests/dom/views-login.test.ts | dom | tested via renderLogin |
| hostLabel | src/views/login.ts:16 | tests/dom/views-login.test.ts | dom | tested via renderLogin |
| avatar | src/views/login.ts:22 | tests/dom/views-login.test.ts | dom | tested via renderLogin |
| renderLogin | src/views/login.ts:32 | tests/dom/views-login.test.ts | dom | tested |
| live (inner) | src/views/login.ts:38 | tests/dom/views-login.test.ts | dom | tested via renderLogin |
| brand (inner) | src/views/login.ts:43 | tests/dom/views-login.test.ts | dom | tested via renderLogin |
| hint (inner) | src/views/login.ts:49 | tests/dom/views-login.test.ts | dom | tested via renderLogin |
| addressStep (inner) | src/views/login.ts:56 | tests/dom/views-login.test.ts | dom | tested via renderLogin |
| drawServers (inner) | src/views/login.ts:147 | tests/dom/views-login.test.ts | dom | tested via renderLogin |
| pick (inner) | src/views/login.ts:149 | tests/dom/views-login.test.ts | dom | tested via renderLogin |
| row (inner) | src/views/login.ts:153 | tests/dom/views-login.test.ts | dom | tested via renderLogin |
| credentialsStep (inner) | src/views/login.ts:234 | tests/dom/views-login.test.ts | dom | tested via renderLogin |
| drawPeople (inner) | src/views/login.ts:268 | tests/dom/views-login.test.ts | dom | tested via renderLogin |
| quickConnectPanel (inner) | src/views/login.ts:360 | tests/dom/views-login.test.ts | dom | tested via renderLogin |
| draw (inner) | src/views/login.ts:368 | tests/dom/views-login.test.ts | dom | tested via renderLogin |
| start (inner) | src/views/login.ts:409 | tests/dom/views-login.test.ts | dom | tested via renderLogin |
| poll (inner) | src/views/login.ts:430 | tests/dom/views-login.test.ts | dom | tested via renderLogin |
| itemCacheKey | src/views/item.ts:46 | tests/dom/views-item.test.ts | dom | tested via renderItem |
| fetchItemData | src/views/item.ts:59 | tests/dom/views-item.test.ts | dom | tested |
| p (inner) | src/views/item.ts:62 | tests/dom/views-item.test.ts | dom | tested via renderItem |
| itemDataSignature | src/views/item.ts:87 | tests/dom/views-item.test.ts | dom | tested via renderItem |
| metaChips | src/views/item.ts:93 | tests/dom/views-item.test.ts | dom | tested via renderItem |
| sourceLine | src/views/item.ts:110 | tests/dom/views-item.test.ts | dom | tested via renderItem |
| crewLine | src/views/item.ts:116 | tests/dom/views-item.test.ts | dom | tested via renderItem |
| names (inner) | src/views/item.ts:117 | tests/dom/views-item.test.ts | dom | tested via renderItem |
| personCard | src/views/item.ts:127 | tests/dom/views-item.test.ts | dom | tested via renderItem |
| detailExtras | src/views/item.ts:163 | tests/dom/views-item.test.ts | dom | tested via renderItem |
| cast (inner) | src/views/item.ts:164 | tests/dom/views-item.test.ts | dom | tested via renderItem |
| playButtons | src/views/item.ts:187 | tests/dom/views-item.test.ts; tests/dom/views-item-series.test.ts | dom | tested via renderItem |
| syncWatchBtn (inner) | src/views/item.ts:283 | tests/dom/views-item.test.ts | dom | tested via renderItem |
| attachParallax | src/views/item.ts:306 | tests/dom/views-item.test.ts | dom | tested via renderItem |
| onScroll (inner) | src/views/item.ts:310 | tests/dom/views-item.test.ts | dom | tested via renderItem |
| epCode | src/views/item.ts:325 | tests/dom/views-item-series.test.ts | dom | tested via renderItem |
| firstUnplayedEpisode | src/views/item.ts:335 | tests/dom/views-item-series.test.ts | dom | tested via renderItem |
| seriesHeroActions | src/views/item.ts:347 | tests/dom/views-item-series.test.ts | dom | tested via renderItem |
| episodeRow | src/views/item.ts:382 | tests/dom/views-item-series.test.ts | dom | tested via renderItem |
| play (inner) | src/views/item.ts:424 | tests/dom/views-item.test.ts | dom | tested via renderItem |
| seasonDownloadBar | src/views/item.ts:468 | tests/dom/views-item-series.test.ts | dom | tested via renderItem |
| seriesDownloadBar | src/views/item.ts:515 | tests/dom/views-item-series.test.ts | dom | tested via renderItem |
| queueWholeSeries (inner) | src/views/item.ts:519 | tests/dom/views-item-series.test.ts | dom | tested via renderItem |
| paintItem | src/views/item.ts:564 | tests/dom/views-item.test.ts; tests/dom/views-item-series.test.ts | dom | tested via renderItem |
| toSeries (inner) | src/views/item.ts:601 | tests/dom/views-item.test.ts | dom | tested via renderItem |
| showSeason (inner) | src/views/item.ts:664 | tests/dom/views-item.test.ts | dom | tested via renderItem |
| renderItem | src/views/item.ts:707 | tests/dom/views-item.test.ts; tests/dom/views-item-series.test.ts | dom | tested |
| isEpisode | src/views/downloads.ts:55 | tests/dom/views-downloads.test.ts | dom | tested via renderDownloads |
| completedSub | src/views/downloads.ts:59 | tests/dom/views-downloads.test.ts | dom | tested via renderDownloads |
| dlRow | src/views/downloads.ts:70 | tests/dom/views-downloads.test.ts | dom | tested via renderDownloads |
| watchFraction | src/views/downloads.ts:92 | tests/dom/views-downloads.test.ts | dom | tested via renderDownloads |
| watchedOverlay | src/views/downloads.ts:105 | tests/dom/views-downloads.test.ts | dom | tested via renderDownloads |
| libCard | src/views/downloads.ts:116 | tests/dom/views-downloads.test.ts | dom | tested via renderDownloads |
| deleteDownload | src/views/downloads.ts:184 | tests/dom/views-downloads.test.ts | dom | tested via renderDownloads |
| deleteMany | src/views/downloads.ts:192 | tests/dom/views-downloads.test.ts | dom | tested via renderDownloads |
| plural | src/views/downloads.ts:201 | tests/dom/views-downloads.test.ts | dom | tested via renderDownloads |
| bytesOf | src/views/downloads.ts:205 | tests/dom/views-downloads.test.ts | dom | tested via renderDownloads |
| confirmDeletion | src/views/downloads.ts:211 | tests/dom/views-downloads.test.ts | dom | tested via renderDownloads |
| watchedDownloads | src/views/downloads.ts:230 | tests/dom/views-downloads.test.ts | dom | tested via renderDownloads |
| confirmDeleteWatched | src/views/downloads.ts:234 | tests/dom/views-downloads.test.ts | dom | tested via renderDownloads |
| deleteEverything | src/views/downloads.ts:249 | tests/dom/views-downloads.test.ts | dom | tested via renderDownloads |
| revealInFiles | src/views/downloads.ts:266 | tests/dom/views-downloads.test.ts | dom | tested via renderDownloads |
| markDeletable | src/views/downloads.ts:274 | tests/dom/views-downloads.test.ts | dom | tested via renderDownloads |
| installDeleteKey | src/views/downloads.ts:281 | tests/dom/views-downloads.test.ts | dom | tested via renderDownloads |
| target (inner) | src/views/downloads.ts:288 | tests/dom/views-downloads.test.ts | dom | tested via renderDownloads |
| ids (inner) | src/views/downloads.ts:291 | tests/dom/views-downloads.test.ts | dom | tested via renderDownloads |
| inOrder | src/views/downloads.ts:304 | tests/dom/views-downloads.test.ts | dom | tested via renderDownloads |
| nextUnwatched | src/views/downloads.ts:312 | tests/dom/views-downloads.test.ts | dom | tested via renderDownloads |
| playNextAction | src/views/downloads.ts:318 | tests/dom/views-downloads.test.ts | dom | tested via renderDownloads |
| playNextButton | src/views/downloads.ts:330 | tests/dom/views-downloads.test.ts | dom | tested via renderDownloads |
| deleteAllButton | src/views/downloads.ts:343 | tests/dom/views-downloads.test.ts | dom | tested via renderDownloads |
| clearQueue | src/views/downloads.ts:375 | tests/dom/views-downloads.test.ts | dom | tested via renderDownloads |
| setLocalPlayed | src/views/downloads.ts:396 | tests/dom/views-downloads.test.ts | dom | tested via renderDownloads |
| localActions | src/views/downloads.ts:411 | tests/dom/views-downloads.test.ts | dom | tested via renderDownloads |
| groupActions | src/views/downloads.ts:453 | tests/dom/views-downloads.test.ts | dom | tested via renderDownloads |
| concurrencySelector | src/views/downloads.ts:500 | tests/dom/views-downloads.test.ts | dom | tested via renderDownloads |
| renderTvTab | src/views/downloads.ts:523 | tests/dom/views-downloads.test.ts | dom | tested via renderDownloads |
| seasonTitle (inner) | src/views/downloads.ts:597 | tests/dom/views-downloads.test.ts | dom | tested via renderDownloads |
| toAllShows (inner) | src/views/downloads.ts:599 | tests/dom/views-downloads.test.ts | dom | tested via renderDownloads |
| toSeasons (inner) | src/views/downloads.ts:603 | tests/dom/views-downloads.test.ts | dom | tested via renderDownloads |
| renderMoviesTab | src/views/downloads.ts:716 | tests/dom/views-downloads.test.ts | dom | tested via renderDownloads |
| renderQueueTab | src/views/downloads.ts:756 | tests/dom/views-downloads.test.ts | dom | tested via renderDownloads |
| retry (inner) | src/views/downloads.ts:902 | tests/dom/views-downloads.test.ts | dom | tested via renderDownloads |
| refreshWatchState | src/views/downloads.ts:939 | tests/dom/views-downloads.test.ts | dom | tested via renderDownloads |
| refreshDetails | src/views/downloads.ts:976 | tests/dom/views-downloads.test.ts | dom | tested via renderDownloads |
| pauseButton | src/views/downloads.ts:1049 | tests/dom/views-downloads.test.ts | dom | tested via renderDownloads |
| manageButton | src/views/downloads.ts:1066 | tests/dom/views-downloads.test.ts | dom | tested via renderDownloads |
| renderDownloads | src/views/downloads.ts:1130 | tests/dom/views-downloads.test.ts | dom | tested |
| paint (inner) | src/views/downloads.ts:1207 | tests/dom/views-downloads.test.ts | dom | tested via renderDownloads |
| etaText | src/views/downloads.ts:1281 | tests/dom/views-downloads.test.ts | dom | tested via renderDownloads |
| updateDownloadProgress | src/views/downloads.ts:1290 | tests/dom/views-downloads.test.ts | dom | tested |

### config, prefs, progress, discovery, download_extras, jellyfin, secret, idle

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
| `download_extras::stream_subtitles` | src-tauri/src/download_extras.rs:166 | src-tauri/src/download_extras.rs (mod tests) | unit | tested (the player.rs call that uses it is CI only) |
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
| `secret::State` / `STATE` | src-tauri/src/secret.rs:56 | src-tauri/src/secret.rs (mod tests) | needs real Linux | CI only (not run on macOS); cache behaviour via token, backend_name, pending_revocation |
| `secret::reset_for_tests` (cfg test) | src-tauri/src/secret.rs:87 | src-tauri/src/test_support.rs (sandbox) | needs real Linux | CI only (not run on macOS) |
| `secret::state` | src-tauri/src/secret.rs:98 | src-tauri/src/secret.rs (mod tests) | needs real Linux | CI only (not run on macOS); via every public function |
| `secret::attrs` | src-tauri/src/secret.rs:108 | src-tauri/src/secret.rs (mod tests) | needs real Linux | CI only (not run on macOS) |
| `secret::search_attrs` | src-tauri/src/secret.rs:120 | src-tauri/src/secret.rs (mod tests) | needs real Linux | CI only (not run on macOS) |
| `secret::search_attrs_in` | src-tauri/src/secret.rs:124 | src-tauri/src/secret.rs (mod tests) | needs real Linux | CI only (not run on macOS) |
| `secret::label` | src-tauri/src/secret.rs:128 | src-tauri/src/secret.rs (mod tests) | needs real Linux | CI only (not run on macOS) |
| `secret::CONN` / `conn` | src-tauri/src/secret.rs:151 | src-tauri/src/secret.rs (mod tests) | needs real Linux | CI only (not run on macOS); via with_collection |
| `secret::with_collection` (connect failure) | src-tauri/src/secret.rs:164 | src-tauri/src/secret.rs (mod tests) | needs real Linux | CI only (not run on macOS); dead-bus path via every public function |
| `secret::with_collection` (stale-connection retry) | src-tauri/src/secret.rs:179 | none | needs real Linux | untested: needs a keyring daemon restarted mid-session |
| `secret::read` / `read_in` | src-tauri/src/secret.rs:192 | src-tauri/src/secret.rs (mod tests) | needs real Linux | CI only (dead bus); success path `#[ignore]`, opt-in AQUARIUM_TEST_REAL_DBUS=1 |
| `secret::write` | src-tauri/src/secret.rs:213 | src-tauri/src/secret.rs (writing_twice_overwrites_in_place) | needs real Linux | CI only (dead bus); overwrite-in-place `#[ignore]`, opt-in AQUARIUM_TEST_REAL_DBUS=1 |
| `secret::wipe` / `wipe_in` | src-tauri/src/secret.rs:237 | src-tauri/src/secret.rs (mod tests) | needs real Linux | CI only (dead bus); success path `#[ignore]`, opt-in AQUARIUM_TEST_REAL_DBUS=1 |
| `secret::cached_token` | src-tauri/src/secret.rs:259 | src-tauri/src/secret.rs (mod tests) | needs real Linux | CI only (not run on macOS); failed-lookup caching tested; keyring-hit and adopt-on-miss branches untested (would read the user's real token item) |
| `secret::adopt_legacy` (FellyJin invariant) | src-tauri/src/secret.rs:285 | src-tauri/src/secret.rs (a_fellyjin_item_is_adopted_and_the_old_one_removed) | needs real Linux | CI only (dead bus returns None); adoption itself `#[ignore]`, opt-in AQUARIUM_TEST_REAL_DBUS=1 |
| `secret::keyring_get` | src-tauri/src/secret.rs:296 | src-tauri/src/secret.rs (mod tests) | needs real Linux | CI only (not run on macOS); via token |
| `secret::keyring_set` | src-tauri/src/secret.rs:300 | src-tauri/src/secret.rs (mod tests) | needs real Linux | CI only (failure path via store, hydrate); success path untested (would write the user's real token item) |
| `secret::keyring_clear` | src-tauri/src/secret.rs:315 | src-tauri/src/secret.rs (mod tests) | needs real Linux | CI only (not run on macOS); via clear |
| `secret::hydrate` | src-tauri/src/secret.rs:328 | src-tauri/src/secret.rs (mod tests) | needs real Linux | CI only (no-keyring paths); migration into a real keyring untested |
| `secret::dehydrate` | src-tauri/src/secret.rs:375 | src-tauri/src/secret.rs (mod tests) | needs real Linux | CI only (not run on macOS) |
| `secret::redact_accounts` | src-tauri/src/secret.rs:389 | src-tauri/src/secret.rs (mod tests) | needs real Linux | CI only (not run on macOS); via hydrate |
| `secret::token` | src-tauri/src/secret.rs:403 | src-tauri/src/secret.rs (mod tests) | needs real Linux | CI only (not run on macOS) |
| `secret::store` | src-tauri/src/secret.rs:415 | src-tauri/src/secret.rs (mod tests) | needs real Linux | CI only (config.json fallback) |
| `secret::clear` | src-tauri/src/secret.rs:429 | src-tauri/src/secret.rs (mod tests) | needs real Linux | CI only (not run on macOS) |
| `secret::park_pending_revocation` | src-tauri/src/secret.rs:443 | src-tauri/src/secret.rs (mod tests) | needs real Linux | CI only (failure path); success untested |
| `secret::pending_revocation` | src-tauri/src/secret.rs:453 | src-tauri/src/secret.rs (mod tests) | needs real Linux | CI only (failed lookup cached) |
| `secret::clear_pending_revocation` | src-tauri/src/secret.rs:469 | src-tauri/src/secret.rs (mod tests) | needs real Linux | CI only (failed wipe) |
| `secret::backend_name` | src-tauri/src/secret.rs:482 | src-tauri/src/secret.rs (mod tests) | needs real Linux | CI only (not run on macOS) |
| `secret::slot` | src-tauri/src/secret.rs:500 | src-tauri/src/secret.rs (mod tests) | needs real Linux | CI only (not run on macOS) |
| `secret::store_account` | src-tauri/src/secret.rs:507 | src-tauri/src/secret.rs (mod tests) | needs real Linux | CI only (config.json fallback) |
| `secret::account_token` | src-tauri/src/secret.rs:523 | src-tauri/src/secret.rs (mod tests) | needs real Linux | CI only (config.json fallback) |
| `secret::clear_account` | src-tauri/src/secret.rs:537 | src-tauri/src/secret.rs (mod tests) | needs real Linux | CI only (config.json fallback) |
| `idle::BUS` / `PATH` / `TIMEOUT` / `GSM_*` | src-tauri/src/idle.rs:19 | src-tauri/src/idle.rs (mod tests) | needs real Linux | CI only (not run on macOS) |
| `idle::IdleInhibitor::new` | src-tauri/src/idle.rs:29 | src-tauri/src/idle.rs (mod tests) | needs real Linux | CI only (dead bus fails cleanly); round trip `#[ignore]`, opt-in AQUARIUM_TEST_REAL_DBUS=1 |
| `idle::IdleInhibitor::drop` | src-tauri/src/idle.rs:39 | src-tauri/src/idle.rs (inhibitor_cycles) | needs real Linux | `#[ignore]`, opt-in AQUARIUM_TEST_REAL_DBUS=1 |
| `idle::SuspendInhibitor::new` | src-tauri/src/idle.rs:65 | src-tauri/src/idle.rs (mod tests) | needs real Linux | CI only (dead bus fails cleanly); GNOME round trip `#[ignore]`; logind branch untested |
| `idle::SuspendInhibitor::drop` | src-tauri/src/idle.rs:90 | src-tauri/src/idle.rs (suspend_inhibitor_round_trip) | needs real Linux | `#[ignore]`, opt-in AQUARIUM_TEST_REAL_DBUS=1 |
| `config_load` (Tauri command: secret::hydrate(config::load())) | src-tauri/src/lib.rs:68 | none | needs real Linux | untested: lib.rs is Linux-only; both functions it calls are tested |
| `config_save` (Tauri command: config::merge(secret::dehydrate(cfg))) | src-tauri/src/lib.rs:76 | none | needs real Linux | untested: lib.rs is Linux-only; both functions it calls are tested |
| `app_info` (Tauri command: config::load, config::downloads_dir, secret::backend_name, jellyfin::CLIENT_VERSION) | src-tauri/src/lib.rs:169 | none | needs real Linux | untested: lib.rs is Linux-only; the functions it calls are tested |
| `jf_discover` (Tauri command: discovery::find, 1600 ms) | src-tauri/src/lib.rs:216 | none | needs real Linux | untested: lib.rs is Linux-only; find_from is tested |
| `download_fetch_subtitles` (Tauri command: download_extras::fetch_subtitles) | src-tauri/src/lib.rs:796 | none | needs real Linux | untested: lib.rs is Linux-only; fetch_subtitles is tested |
| `download_update_details` (Tauri command: download_extras::update_details) | src-tauri/src/lib.rs:807 | none | needs real Linux | untested: lib.rs is Linux-only; update_details is tested |
| `downloads_reveal` (Tauri command: download_extras::reveal) | src-tauri/src/lib.rs:818 | none | needs real Linux | untested: lib.rs is Linux-only |
| `progress_sync` (Tauri command: config::load, secret::token, config::device_id, progress::sync) | src-tauri/src/lib.rs:849 | none | needs real Linux | untested: lib.rs is Linux-only; the functions it calls are tested |
| `progress_store_local` (Tauri command: progress::store_local) | src-tauri/src/lib.rs:870 | none | needs real Linux | untested: lib.rs is Linux-only; store_local is tested |
| `progress_pending` (Tauri command: progress::pending_count) | src-tauri/src/lib.rs:875 | none | needs real Linux | untested: lib.rs is Linux-only; pending_count is tested |
| `progress_pending_ids` (Tauri command: progress::pending_item_ids) | src-tauri/src/lib.rs:880 | none | needs real Linux | untested: lib.rs is Linux-only; pending_item_ids is tested |
| `run` (startup: config::migrate_legacy_dirs, config::harden_data_dir) | src-tauri/src/lib.rs:885 | none | needs real Linux | untested: lib.rs is Linux-only; both functions are tested |

### server.rs, downloads.rs

| Function | Source | Test file | Kind | Status |
|---|---|---|---|---|
| `PROBE_TIMEOUT` (const) | src-tauri/src/server.rs:22 | src-tauri/src/server.rs `tests` | unit | untested: a 5 s timeout; no test waits that long |
| `err` | src-tauri/src/server.rs:24 | src-tauri/src/server.rs `tests` | unit | tested via every error-kind prefix assertion (request, probe, login, ping) |
| `offline_err` | src-tauri/src/server.rs:29 | src-tauri/src/server.rs `tests` | unit | tested via probe_of_an_address_nobody_answers_is_offline_and_logged |
| `normalize` | src-tauri/src/server.rs:40 | src-tauri/src/server.rs `tests` | unit | tested |
| `is_secure` | src-tauri/src/server.rs:81 | src-tauri/src/server.rs `tests` | unit | tested |
| `public_info` | src-tauri/src/server.rs:87 | src-tauri/src/server.rs `tests` | unit | tested via probe / verify |
| `str_field` | src-tauri/src/server.rs:108 | src-tauri/src/server.rs `tests` | unit | tested |
| `probe` | src-tauri/src/server.rs:121 | src-tauri/src/server.rs `tests`, `qa_tests` | unit | tested |
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
| `without_token` | src-tauri/src/server.rs:296 | src-tauri/src/server.rs `tests` | unit | tested, and via request |
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
| `forget_account` | src-tauri/src/server.rs:775 | src-tauri/src/server.rs `tests` | unit | tested |
| `public_request` | src-tauri/src/server.rs:800 | src-tauri/src/server.rs `tests`, `qa_tests` | unit | tested |
| `revoke` | src-tauri/src/server.rs:831 | src-tauri/src/server.rs `tests` | unit | tested via logout / forget_account / retry_pending_revocation |
| `logout` | src-tauri/src/server.rs:855 | src-tauri/src/server.rs `tests` | unit | tested |
| `logout` (live revocation) | src-tauri/src/server.rs:855 | src-tauri/src/server.rs `qa_tests` | integration (QA server) | tested |
| `retry_pending_revocation` | src-tauri/src/server.rs:892 | src-tauri/src/server.rs `tests` | unit | tested |
| `revocation_pending` | src-tauri/src/server.rs:914 | src-tauri/src/server.rs `tests` | unit | tested |
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

### the GTK/libmpv/Wayland/D-Bus modules, lib.rs, main.rs

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
| debug_log_line | src-tauri/src/lib.rs:34 | src-tauri/src/lib.rs (mod tests) | unit | CI only (not run on macOS) |
| now_ms | src-tauri/src/lib.rs:52 | src-tauri/src/lib.rs (mod tests) | unit | CI only (not run on macOS) |
| ui_log | src-tauri/src/lib.rs:60 | src-tauri/src/lib.rs (mod tests) | unit | CI only (not run on macOS) |
| config_load | src-tauri/src/lib.rs:68 | src-tauri/src/lib.rs (mod tests) | unit | CI only (not run on macOS) |
| config_save | src-tauri/src/lib.rs:76 | src-tauri/src/lib.rs (mod tests) | unit | CI only (not run on macOS) |
| with_user_agent | src-tauri/src/lib.rs:82 | src-tauri/src/lib.rs (mod tests) | unit | CI only (not run on macOS); copy run on macOS in scratch |
| fetch_source | src-tauri/src/lib.rs:97 | src-tauri/src/lib.rs (mod tests) | unit | CI only (not run on macOS); copy run on macOS in scratch |
| app_info | src-tauri/src/lib.rs:169 | src-tauri/src/lib.rs (mod tests) | unit | CI only (not run on macOS) |
| jf_probe | src-tauri/src/lib.rs:188 | src-tauri/src/server.rs | unit | tested via server::probe (thin Tauri wrapper; that module's own tests) |
| jf_login | src-tauri/src/lib.rs:193 | src-tauri/src/server.rs | unit | tested via server::login (thin Tauri wrapper; that module's own tests) |
| jf_logout | src-tauri/src/lib.rs:198 | src-tauri/src/server.rs | unit | tested via server::logout (thin Tauri wrapper; that module's own tests) |
| jf_login_quick_connect | src-tauri/src/lib.rs:203 | src-tauri/src/server.rs | unit | tested via server::login_quick_connect (thin Tauri wrapper; that module's own tests) |
| jf_public | src-tauri/src/lib.rs:210 | src-tauri/src/server.rs | unit | tested via server::public_request (thin Tauri wrapper; that module's own tests) |
| jf_discover | src-tauri/src/lib.rs:216 | src-tauri/src/discovery.rs | unit | tested via discovery::find (thin Tauri wrapper; that module's own tests) |
| player_get_properties | src-tauri/src/lib.rs:224 | src-tauri/src/lib.rs (mod tests) | unit | CI only (not run on macOS) (no session) |
| player_warm | src-tauri/src/lib.rs:233 | src-tauri/src/server.rs | unit | tested via server::warm (thin Tauri wrapper; that module's own tests) |
| accounts_list | src-tauri/src/lib.rs:238 | src-tauri/src/lib.rs (mod tests) | unit | CI only (not run on macOS) |
| account_switch | src-tauri/src/lib.rs:243 | src-tauri/src/lib.rs (mod tests) | unit | CI only (not run on macOS) (unknown key) |
| account_forget | src-tauri/src/lib.rs:248 | src-tauri/src/server.rs | unit | tested via server::forget_account (thin Tauri wrapper; that module's own tests) |
| jf_request | src-tauri/src/lib.rs:253 | src-tauri/src/server.rs | unit | tested via server::request (thin Tauri wrapper; that module's own tests) |
| jf_image | src-tauri/src/lib.rs:262 | src-tauri/src/server.rs | unit | tested via server::image (thin Tauri wrapper; that module's own tests) |
| jf_ping | src-tauri/src/lib.rs:267 | src-tauri/src/server.rs | unit | tested via server::ping (thin Tauri wrapper; that module's own tests) |
| jf_bitrate_test | src-tauri/src/lib.rs:272 | src-tauri/src/server.rs | unit | tested via server::bitrate_test (thin Tauri wrapper; that module's own tests) |
| resolve_stream | src-tauri/src/lib.rs:346 | src-tauri/src/lib.rs (mod tests) | unit | CI only (not run on macOS); copy run on macOS in scratch |
| player_play | src-tauri/src/lib.rs:426 | — | needs real Linux | untested: takes AppHandle<Wry> and needs the video surface; manual checklist |
| audio_play | src-tauri/src/lib.rs:443 | — | needs real Linux | untested: takes AppHandle<Wry>; manual checklist |
| audio_set_next | src-tauri/src/lib.rs:448 | src-tauri/src/lib.rs (mod tests) | unit | CI only (not run on macOS) (no core) |
| audio_command | src-tauri/src/lib.rs:453 | src-tauri/src/lib.rs (mod tests) | unit | CI only (not run on macOS) (no core) |
| audio_stop | src-tauri/src/lib.rs:458 | — | needs real Linux | untested: takes AppHandle<Wry>; manual checklist |
| audio_status | src-tauri/src/lib.rs:464 | src-tauri/src/lib.rs (mod tests) | unit | CI only (not run on macOS) |
| audio_set_queue | src-tauri/src/lib.rs:470 | src-tauri/src/lib.rs (mod tests) | unit | CI only (not run on macOS) |
| player_stop | src-tauri/src/lib.rs:481 | src-tauri/src/lib.rs (mod tests) | unit | CI only (not run on macOS) (no session) |
| player_pause_toggle | src-tauri/src/lib.rs:488 | src-tauri/src/lib.rs (mod tests) | unit | CI only (not run on macOS) (no session) |
| player_seek | src-tauri/src/lib.rs:495 | src-tauri/src/lib.rs (mod tests) | unit | CI only (not run on macOS) (no session) |
| player_set_track | src-tauri/src/lib.rs:507 | src-tauri/src/lib.rs (mod tests) | unit | CI only (not run on macOS) (no session) |
| track_property | src-tauri/src/lib.rs:517 | src-tauri/src/lib.rs (mod tests) | unit | CI only (not run on macOS); copy run on macOS in scratch |
| player_status | src-tauri/src/lib.rs:526 | src-tauri/src/lib.rs (mod tests) | unit | CI only (not run on macOS) |
| player_set_next_available | src-tauri/src/lib.rs:534 | src-tauri/src/lib.rs (mod tests) | unit | CI only (not run on macOS) |
| audio_devices | src-tauri/src/lib.rs:543 | src-tauri/src/lib.rs (mod tests) | unit | CI only (not run on macOS) |
| player_mpv_command | src-tauri/src/lib.rs:552 | src-tauri/src/lib.rs (mod tests) | unit | CI only (not run on macOS) (no session) |
| player_set_viewport | src-tauri/src/lib.rs:568 | — | needs real Linux | untested: takes AppHandle<Wry>; geometry tested via video_layout; manual checklist (fullscreen) |
| player_set_pip | src-tauri/src/lib.rs:589 | — | needs real Linux | untested: takes AppHandle<Wry> and needs the surface; manual checklist (PiP) |
| resize_video_surface | src-tauri/src/lib.rs:608 | src-tauri/src/lib.rs (mod tests) | needs real Linux | tested via video_layout (window and surface half needs a desktop) |
| video_layout | src-tauri/src/lib.rs:646 | src-tauri/src/lib.rs (mod tests) | unit | CI only (not run on macOS); copy run on macOS in scratch |
| window_size_path | src-tauri/src/lib.rs:691 | src-tauri/src/lib.rs (mod tests) | unit | CI only (not run on macOS) |
| save_window_size | src-tauri/src/lib.rs:707 | — | needs real Linux | untested: needs a GTK window; manual checklist |
| restore_window_size | src-tauri/src/lib.rs:729 | src-tauri/src/lib.rs (mod tests) | needs real Linux | tested via clamp_window_size (GTK half needs a window); manual checklist |
| clamp_window_size | src-tauri/src/lib.rs:754 | src-tauri/src/lib.rs (mod tests) | unit | CI only (not run on macOS); copy run on macOS in scratch |
| quit_confirm | src-tauri/src/lib.rs:775 | — | needs real Linux | untested: takes AppHandle<Wry> and a window; manual checklist (quit with downloads) |
| download_start | src-tauri/src/lib.rs:786 | src-tauri/src/DlManager.rs | unit | tested via DlManager::start (thin Tauri wrapper; that module's own tests) |
| download_cancel | src-tauri/src/lib.rs:795 | src-tauri/src/lib.rs (mod tests) | unit | CI only (not run on macOS) (unknown id) |
| download_retry | src-tauri/src/lib.rs:800 | src-tauri/src/downloads.rs | unit | tested via downloads::restart (thin Tauri wrapper; that module's own tests) |
| download_pause | src-tauri/src/lib.rs:812 | src-tauri/src/lib.rs (mod tests) | unit | CI only (not run on macOS) (unknown id) |
| downloads_sync_keep_awake | src-tauri/src/lib.rs:818 | src-tauri/src/DlManager.rs | unit | tested via DlManager::sync_keep_awake (thin Tauri wrapper; that module's own tests) |
| network_metered | src-tauri/src/lib.rs:823 | src-tauri/src/lib.rs (mod tests) | unit | CI only (not run on macOS) |
| download_fetch_subtitles | src-tauri/src/lib.rs:828 | src-tauri/src/download_extras.rs | unit | tested via download_extras::fetch_subtitles (thin Tauri wrapper; that module's own tests) |
| download_update_details | src-tauri/src/lib.rs:839 | src-tauri/src/download_extras.rs | unit | tested via download_extras::update_details (thin Tauri wrapper; that module's own tests) |
| downloads_reveal | src-tauri/src/lib.rs:850 | src-tauri/src/download_extras.rs | unit | tested via download_extras::reveal (thin Tauri wrapper; that module's own tests) |
| download_delete | src-tauri/src/lib.rs:857 | src-tauri/src/lib.rs (mod tests) | unit | CI only (not run on macOS) (invalid id) |
| downloads_list | src-tauri/src/lib.rs:862 | src-tauri/src/lib.rs (mod tests) | unit | CI only (not run on macOS) (empty) |
| disk_free | src-tauri/src/lib.rs:869 | src-tauri/src/lib.rs (mod tests) | unit | CI only (not run on macOS) |
| download_set_watch_state | src-tauri/src/lib.rs:874 | src-tauri/src/downloads.rs | unit | tested via downloads::set_watch_state (thin Tauri wrapper; that module's own tests) |
| progress_sync | src-tauri/src/lib.rs:881 | src-tauri/src/lib.rs (mod tests) | unit | CI only (not run on macOS) (error branches) |
| progress_store_local | src-tauri/src/lib.rs:902 | src-tauri/src/lib.rs (mod tests) | unit | CI only (not run on macOS) |
| progress_pending | src-tauri/src/lib.rs:907 | src-tauri/src/lib.rs (mod tests) | unit | CI only (not run on macOS) |
| progress_pending_ids | src-tauri/src/lib.rs:912 | src-tauri/src/lib.rs (mod tests) | unit | CI only (not run on macOS) |
| replay_target | src-tauri/src/lib.rs:919 | src-tauri/src/lib.rs (mod tests) | unit | CI only (not run on macOS); copy run on macOS in scratch |
| test_sequence | src-tauri/src/lib.rs:930 | src-tauri/src/lib.rs (mod tests) | unit | CI only (not run on macOS); copy run on macOS in scratch |
| run | src-tauri/src/lib.rs:943 | — | needs real Linux | untested: builds the app; test hooks parsed by test_sequence/replay_target; manual checklist |
| MIN_WIDTH_CSS / MIN_HEIGHT_CSS (consts) | src-tauri/src/lib.rs:666 | src-tauri/src/lib.rs (mod tests) | unit | CI only (not run on macOS) (matches tauri.conf.json) |

### Seerr: src/seerr.ts, src/views/requests.ts, src/views/seerrSettings.ts

| Function | Source | Test file | Kind | Status |
|---|---|---|---|---|
| SeerrError | src/seerr.ts:65 | tests/unit/seerr.test.ts | unit | tested |
| KINDS | src/seerr.ts:74 | tests/unit/seerr.test.ts | unit | tested via seerrError |
| seerrError | src/seerr.ts:77 | tests/unit/seerr.test.ts | unit | tested |
| SEERR_CHANGED | src/seerr.ts:90 | tests/unit/seerr.test.ts | unit | tested |
| SEERR_REQUESTS_CHANGED | src/seerr.ts:92 | tests/unit/seerr.test.ts | unit | tested |
| setStatus | src/seerr.ts:94 | tests/unit/seerr.test.ts | unit | tested via loadStatus, connect, disconnect |
| getStatus | src/seerr.ts:102 | tests/unit/seerr.test.ts | unit | tested |
| isConnected | src/seerr.ts:107 | tests/unit/seerr.test.ts | unit | tested |
| needsReconnect | src/seerr.ts:111 | tests/unit/seerr.test.ts | unit | tested |
| loadStatus | src/seerr.ts:117 | tests/unit/seerr.test.ts; tests/integration/seerr.test.ts | unit, integration (stand-in Seerr) | tested |
| forgetStatus | src/seerr.ts:127 | tests/unit/seerr.test.ts | unit | tested |
| probe | src/seerr.ts:131 | tests/unit/seerr.test.ts | unit | tested |
| connect | src/seerr.ts:141 | tests/unit/seerr.test.ts | unit | tested |
| connectWithPassword | src/seerr.ts:151 | tests/unit/seerr.test.ts | unit | tested |
| reconnect | src/seerr.ts:159 | tests/unit/seerr.test.ts | unit | tested |
| disconnect | src/seerr.ts:168 | tests/unit/seerr.test.ts | unit | tested |
| refreshAccount | src/seerr.ts:177 | tests/unit/seerr.test.ts | unit | tested |
| call | src/seerr.ts:187 | tests/unit/seerr.test.ts | unit | tested via title, request, cancel |
| get | src/seerr.ts:201 | tests/unit/seerr.test.ts | unit | tested via search, title |
| KIND_NOUN | src/seerr.ts:213 | tests/unit/seerr.test.ts | unit | tested |
| AVAILABILITY | src/seerr.ts:301 | tests/unit/seerr.test.ts | unit | tested via availability |
| availability | src/seerr.ts:303 | tests/unit/seerr.test.ts | unit | tested |
| REQUEST_STATUS | src/seerr.ts:309 | tests/unit/seerr.test.ts | unit | tested via requestStatus |
| requestStatus | src/seerr.ts:311 | tests/unit/seerr.test.ts | unit | tested |
| kindOf | src/seerr.ts:317 | tests/unit/seerr.test.ts | unit | tested |
| requestKind | src/seerr.ts:322 | tests/unit/seerr.test.ts | unit | tested |
| displayTitle | src/seerr.ts:326 | tests/unit/seerr.test.ts | unit | tested |
| yearOf | src/seerr.ts:331 | tests/unit/seerr.test.ts | unit | tested |
| resultYear | src/seerr.ts:337 | tests/unit/seerr.test.ts | unit | tested |
| libraryItemId | src/seerr.ts:342 | tests/unit/seerr.test.ts | unit | tested |
| isRequestable | src/seerr.ts:347 | tests/unit/seerr.test.ts | unit | tested |
| resultKey | src/seerr.ts:352 | tests/unit/seerr.test.ts | unit | tested |
| STANDING_LABEL | src/seerr.ts:368 | tests/unit/seerr.test.ts | unit | tested |
| STANDING_BADGE | src/seerr.ts:379 | tests/unit/seerr.test.ts | unit | tested |
| standingOfMedia | src/seerr.ts:390 | tests/unit/seerr.test.ts; tests/integration/seerr.test.ts | unit, integration (stand-in Seerr) | tested |
| standingOfRequest | src/seerr.ts:402 | tests/unit/seerr.test.ts; tests/integration/seerr.test.ts | unit, integration (stand-in Seerr) | tested |
| realSeasons | src/seerr.ts:419 | tests/unit/seerr.test.ts | unit | tested |
| requestableSeasons | src/seerr.ts:425 | tests/unit/seerr.test.ts; tests/integration/seerr.test.ts | unit, integration (stand-in Seerr) | tested |
| standingOfSeason | src/seerr.ts:441 | tests/unit/seerr.test.ts; tests/integration/seerr.test.ts | unit, integration (stand-in Seerr) | tested |
| state (inner) | src/seerr.ts:442 | tests/unit/seerr.test.ts | unit | tested |
| PERMISSION | src/seerr.ts:462 | tests/unit/seerr.test.ts | unit | tested |
| canRequest | src/seerr.ts:474 | tests/unit/seerr.test.ts | unit | tested |
| canRequest4K | src/seerr.ts:480 | tests/unit/seerr.test.ts | unit | tested |
| quotaSummary | src/seerr.ts:487 | tests/unit/seerr.test.ts | unit | tested |
| seasonList | src/seerr.ts:498 | tests/unit/seerr.test.ts | unit | tested |
| titleFacts | src/seerr.ts:506 | tests/unit/seerr.test.ts | unit | tested |
| genres (inner) | src/seerr.ts:519 | tests/unit/seerr.test.ts | unit | tested |
| requestLabel | src/seerr.ts:525 | tests/unit/seerr.test.ts | unit | tested |
| requestDetail | src/seerr.ts:533 | tests/unit/seerr.test.ts | unit | tested |
| myPendingRequest | src/seerr.ts:551 | tests/unit/seerr.test.ts | unit | tested |
| tmdbIdOf | src/seerr.ts:561 | tests/unit/seerr.test.ts; tests/integration/seerr.test.ts | unit, integration (stand-in Seerr) | tested |
| encodeQuery | src/seerr.ts:574 | tests/unit/seerr.test.ts | unit | tested |
| results | src/seerr.ts:580 | tests/unit/seerr.test.ts | unit | tested via search, browse |
| search | src/seerr.ts:586 | tests/unit/seerr.test.ts; tests/integration/seerr.test.ts | unit, integration (stand-in Seerr) | tested |
| notInLibrary | src/seerr.ts:592 | tests/unit/seerr.test.ts; tests/integration/seerr.test.ts | unit, integration (stand-in Seerr) | tested |
| BROWSE_ROWS | src/seerr.ts:605 | tests/unit/seerr.test.ts | unit | tested |
| withKind | src/seerr.ts:614 | tests/unit/seerr.test.ts | unit | tested |
| browse | src/seerr.ts:620 | tests/unit/seerr.test.ts; tests/integration/seerr.test.ts | unit, integration (stand-in Seerr) | tested |
| title | src/seerr.ts:625 | tests/unit/seerr.test.ts; tests/integration/seerr.test.ts | unit, integration (stand-in Seerr) | tested |
| collection | src/seerr.ts:632 | tests/unit/seerr.test.ts; tests/integration/seerr.test.ts | unit, integration (stand-in Seerr) | tested |
| sortCredits | src/seerr.ts:639 | tests/unit/seerr.test.ts | unit | tested |
| date (inner) | src/seerr.ts:641 | tests/unit/seerr.test.ts | unit | tested |
| credits | src/seerr.ts:651 | tests/unit/seerr.test.ts; tests/integration/seerr.test.ts | unit, integration (stand-in Seerr) | tested |
| list (inner) | src/seerr.ts:653 | tests/unit/seerr.test.ts | unit | tested |
| requestsChanged | src/seerr.ts:659 | tests/unit/seerr.test.ts | unit | tested via request, cancel |
| request | src/seerr.ts:664 | tests/unit/seerr.test.ts; tests/integration/seerr.test.ts | unit, integration (stand-in Seerr) | tested |
| myRequests | src/seerr.ts:685 | tests/unit/seerr.test.ts; tests/integration/seerr.test.ts | unit, integration (stand-in Seerr) | tested |
| cancel | src/seerr.ts:693 | tests/unit/seerr.test.ts; tests/integration/seerr.test.ts | unit, integration (stand-in Seerr) | tested |
| quota | src/seerr.ts:698 | tests/unit/seerr.test.ts; tests/integration/seerr.test.ts | unit, integration (stand-in Seerr) | tested |
| IMAGE_SIZE | src/seerr.ts:705 | tests/unit/seerr.test.ts | unit | tested |
| imageUrl | src/seerr.ts:719 | tests/unit/seerr.test.ts; tests/integration/seerr.test.ts | unit, integration (stand-in Seerr) | tested |
| hashFor | src/seerr.ts:727 | tests/unit/seerr.test.ts | unit | tested |
| hashForRequest | src/seerr.ts:736 | tests/unit/seerr.test.ts | unit | tested |
| COPY | src/seerr.ts:747 | tests/unit/seerr.test.ts | unit | tested |
| requestCard | src/views/requests.ts:34 | tests/dom/views-requests.test.ts | dom | tested via requestShelf, renderRequests |
| open (inner) | src/views/requests.ts:39 | tests/dom/views-requests.test.ts | dom | tested via renderRequestTitle |
| requestShelf | src/views/requests.ts:71 | tests/dom/views-requests.test.ts | dom | tested |
| REQUESTS_KEY | src/views/requests.ts:100 | tests/dom/views-requests.test.ts | dom | tested via renderRequests |
| titleKey | src/views/requests.ts:101 | tests/dom/views-requests.test.ts | dom | tested via renderRequests, seerrItemHooks |
| QUOTA_KEY | src/views/requests.ts:102 | tests/dom/views-requests.test.ts | dom | tested via renderRequestTitle |
| requestsSignature | src/views/requests.ts:106 | tests/dom/views-requests.test.ts | dom | tested via renderRequests (no repaint when unchanged) |
| card (inner) | src/views/requests.ts:107 | tests/dom/views-requests.test.ts | dom | tested via renderRequestTitle |
| nameKey | src/views/requests.ts:122 | tests/dom/views-requests.test.ts | dom | tested via renderRequests |
| slim | src/views/requests.ts:128 | tests/dom/views-requests.test.ts | dom | tested via renderRequests |
| requestRow | src/views/requests.ts:140 | tests/dom/views-requests.test.ts | dom | tested via renderRequests |
| open (inner) | src/views/requests.ts:144 | tests/dom/views-requests.test.ts | dom | tested via renderRequestTitle |
| paintRequests | src/views/requests.ts:175 | tests/dom/views-requests.test.ts | dom | tested via renderRequests |
| renderRequests | src/views/requests.ts:198 | tests/dom/views-requests.test.ts | dom | tested |
| parseRequestRoute | src/views/requests.ts:289 | tests/dom/views-requests.test.ts | dom | tested |
| renderRequestTitle | src/views/requests.ts:300 | tests/dom/views-requests.test.ts | dom | tested |
| paint (inner) | src/views/requests.ts:323 | tests/dom/views-requests.test.ts | dom | tested via renderRequestTitle |
| load (inner) | src/views/requests.ts:490 | tests/dom/views-requests.test.ts | dom | tested via renderRequestTitle |
| send (inner) | src/views/requests.ts:520 | tests/dom/views-requests.test.ts | dom | tested via renderRequestTitle |
| cancelMine (inner) | src/views/requests.ts:544 | tests/dom/views-requests.test.ts | dom | tested via renderRequestTitle |
| SEERR_SEARCH_DEBOUNCE_MS | src/views/requests.ts:572 | tests/dom/views-requests.test.ts | dom | tested via seerrSearchSection (nothing asked before it has passed) |
| seerrSearchSection | src/views/requests.ts:584 | tests/dom/views-requests.test.ts | dom | tested |
| collectionKey | src/views/requests.ts:606 | tests/dom/views-requests.test.ts | dom | tested via seerrItemHooks |
| moreSeasons | src/views/requests.ts:609 | tests/dom/views-requests.test.ts | dom | tested via seerrItemHooks |
| seerrItemHooks | src/views/requests.ts:632 | tests/dom/views-requests.test.ts | dom | tested |
| draw (inner) | src/views/requests.ts:657 | tests/dom/views-requests.test.ts | dom | tested via renderRequestTitle |
| row | src/views/seerrSettings.ts:13 | tests/dom/views-requests.test.ts | dom | tested via seerrSettingsBlock |
| openSeerrConnect | src/views/seerrSettings.ts:30 | tests/dom/views-requests.test.ts | dom | tested |
| say (inner) | src/views/seerrSettings.ts:38 | tests/dom/views-requests.test.ts | dom | tested via openSeerrConnect |
| buttons (inner) | src/views/seerrSettings.ts:46 | tests/dom/views-requests.test.ts | dom | tested via openSeerrConnect |
| finish (inner) | src/views/seerrSettings.ts:56 | tests/dom/views-requests.test.ts | dom | tested via openSeerrConnect |
| signIn (inner) | src/views/seerrSettings.ts:64 | tests/dom/views-requests.test.ts | dom | tested via openSeerrConnect |
| look (inner) | src/views/seerrSettings.ts:79 | tests/dom/views-requests.test.ts | dom | tested via openSeerrConnect |
| signInAnyway (inner) | src/views/seerrSettings.ts:103 | tests/dom/views-requests.test.ts | dom | tested via openSeerrConnect |
| draw (inner) | src/views/seerrSettings.ts:110 | tests/dom/views-requests.test.ts | dom | tested via openSeerrConnect |
| seerrSettingsBlock | src/views/seerrSettings.ts:218 | tests/dom/views-requests.test.ts | dom | tested |
| draw (inner) | src/views/seerrSettings.ts:223 | tests/dom/views-requests.test.ts | dom | tested via seerrSettingsBlock |
| route: `requests`, `request` cases; `ICONS.requests`; the Requests entry in paintNav | src/main.ts | tests/dom/main-requests.test.ts | dom | tested |
| `aquarium-seerr-changed` / `aquarium-seerr-requests-changed` listeners (boot) | src/main.ts | tests/dom/main-requests.test.ts | dom | tested |
| showShell → seerr.loadStatus; showLogin / enterAccount → seerr.forgetStatus | src/main.ts | tests/dom/main-requests.test.ts | dom | tested (enterAccount's call untested: it needs a second account) |
| renderSearch → seerrSearchSection | src/views/library.ts | tests/dom/views-requests.test.ts | dom | tested |
| renderLibrary → seerrItemHooks (a collection's grid) | src/views/library.ts | none | dom | untested: seerrItemHooks itself is tested with a BoxSet; the call from the grid page is on the manual checklist (item 27) |
| paintItem → seerrItemHooks; itemDataSignature (TMDB id) | src/views/item.ts | tests/dom/views-requests.test.ts | dom | tested |
| renderSettings → seerrSettingsBlock | src/views/settings.ts | tests/dom/views-settings.test.ts | dom | tested via "draws every block in order" |

### Seerr: src-tauri/src/seerr.rs and what it added to secret.rs, server.rs, lib.rs

| Function | Source | Test file | Kind | Status |
|---|---|---|---|---|
| `REQUEST_TIMEOUT` | src-tauri/src/seerr.rs:42 | src-tauri/src/seerr.rs `tests` | unit | untested: a 20 s timeout; no test waits that long |
| `PROBE_TIMEOUT` | src-tauri/src/seerr.rs:43 | src-tauri/src/seerr.rs `tests` | unit | untested: a 5 s timeout |
| `LOGOUT_TIMEOUT` | src-tauri/src/seerr.rs:45 | src-tauri/src/seerr.rs `tests` | unit | untested: a 5 s timeout |
| `QUICK_CONNECT_UNAVAILABLE` | src-tauri/src/seerr.rs:47 | src-tauri/src/seerr.rs `tests` | unit | tested via an_older_seerr_falls_back_to_the_password_which_is_not_kept |
| `NEEDS_RECONNECT` | src-tauri/src/seerr.rs:49 | src-tauri/src/seerr.rs `tests` | unit | tested via when_renewal_fails_settings_is_told_to_reconnect |
| `err` | src-tauri/src/seerr.rs:51 | src-tauri/src/seerr.rs `tests` | unit | tested via every error-kind assertion |
| `account` | src-tauri/src/seerr.rs:83 | src-tauri/src/seerr.rs `tests` | unit | tested via connecting_needs_a_jellyfin_session |
| `read` | src-tauri/src/seerr.rs:88 | src-tauri/src/seerr.rs `tests` | unit | tested via status, request |
| `current` | src-tauri/src/seerr.rs:92 | src-tauri/src/seerr.rs `tests` | unit | tested via connecting_needs_a_jellyfin_session |
| `store` | src-tauri/src/seerr.rs:98 | src-tauri/src/seerr.rs `tests` | unit | tested via a_seerr_that_cannot_be_reached_says_where |
| `RECONNECT` | src-tauri/src/seerr.rs:117 | src-tauri/src/seerr.rs `tests` | unit | tested via when_renewal_fails_settings_is_told_to_reconnect |
| `needs_reconnect` | src-tauri/src/seerr.rs:119 | src-tauri/src/seerr.rs `tests` | unit | tested via status |
| `set_needs_reconnect` | src-tauri/src/seerr.rs:123 | src-tauri/src/seerr.rs `tests` | unit | tested via when_renewal_fails_settings_is_told_to_reconnect |
| `reset_for_tests` | src-tauri/src/seerr.rs:134 | src-tauri/src/seerr.rs `tests` | unit | tested via sandbox() in every test |
| `host` | src-tauri/src/seerr.rs:140 | src-tauri/src/seerr.rs `tests` | unit | tested via quick_connect_signs_in_without_a_password |
| `status` | src-tauri/src/seerr.rs:146 | src-tauri/src/seerr.rs `tests` | unit | tested |
| `HTTP` | src-tauri/src/seerr.rs:165 | src-tauri/src/seerr.rs `tests` | unit | tested via http |
| `same_origin` | src-tauri/src/seerr.rs:167 | src-tauri/src/seerr.rs `tests` | unit | tested |
| `http` | src-tauri/src/seerr.rs:175 | src-tauri/src/seerr.rs `tests` | unit | tested via a_redirect_to_another_origin_is_not_followed |
| `CSRF` | src-tauri/src/seerr.rs:206 | src-tauri/src/seerr.rs `tests` | unit | tested via a_csrf_token_is_echoed_on_writes |
| `csrf_for` | src-tauri/src/seerr.rs:208 | src-tauri/src/seerr.rs `tests` | unit | tested via a_csrf_token_is_echoed_on_writes |
| `remember_csrf` | src-tauri/src/seerr.rs:216 | src-tauri/src/seerr.rs `tests` | unit | tested via a_csrf_token_is_echoed_on_writes |
| `forget_csrf` | src-tauri/src/seerr.rs:236 | src-tauri/src/seerr.rs `tests` | unit | tested via disconnect_tells_seerr_and_forgets |
| `cookie_pair` | src-tauri/src/seerr.rs:241 | src-tauri/src/seerr.rs `tests` | unit | tested |
| `percent_decode` | src-tauri/src/seerr.rs:252 | src-tauri/src/seerr.rs `tests` | unit | tested |
| `hex` | src-tauri/src/seerr.rs:253 | src-tauri/src/seerr.rs `tests` | unit | tested via percent_decode |
| `names_a_certificate` | src-tauri/src/seerr.rs:281 | src-tauri/src/seerr.rs `tests` | unit | tested |
| `is_certificate_failure` | src-tauri/src/seerr.rs:285 | src-tauri/src/seerr.rs `tests` | unit | untested: needs a TLS server with a bad certificate (manual checklist item 25); names_a_certificate, which decides, is tested |
| `json` | src-tauri/src/seerr.rs:303 | src-tauri/src/seerr.rs `tests` | unit | tested via request |
| `cookie` | src-tauri/src/seerr.rs:310 | src-tauri/src/seerr.rs `tests` | unit | tested via connect |
| `send` | src-tauri/src/seerr.rs:325 | src-tauri/src/seerr.rs `tests` | unit | tested via probe, connect, request |
| `plain_words` | src-tauri/src/seerr.rs:396 | src-tauri/src/seerr.rs `tests` | unit | tested |
| `unreachable` | src-tauri/src/seerr.rs:428 | src-tauri/src/seerr.rs `tests` | unit | tested via a_seerr_that_cannot_be_reached_says_where |
| `session_is_gone` | src-tauri/src/seerr.rs:433 | src-tauri/src/seerr.rs `tests` | unit | tested via a_real_refusal_is_not_mistaken_for_a_dead_session |
| `call` | src-tauri/src/seerr.rs:443 | src-tauri/src/seerr.rs `tests` | unit | tested via request (renewal, refusal, unreachable) |
| `allowed` | src-tauri/src/seerr.rs:467 | src-tauri/src/seerr.rs `tests` | unit | tested |
| `id` | src-tauri/src/seerr.rs:468 | src-tauri/src/seerr.rs `tests` | unit | tested via allowed |
| `request` | src-tauri/src/seerr.rs:493 | src-tauri/src/seerr.rs `tests` | unit | tested; stand-in Seerr in `qa_tests` |
| `candidates` | src-tauri/src/seerr.rs:506 | src-tauri/src/seerr.rs `tests` | unit | tested |
| `public_settings` | src-tauri/src/seerr.rs:523 | src-tauri/src/seerr.rs `tests` | unit | tested |
| `probe` | src-tauri/src/seerr.rs:546 | src-tauri/src/seerr.rs `tests` | unit | tested; stand-in Seerr in `qa_tests` |
| `bare` | src-tauri/src/seerr.rs:608 | src-tauri/src/seerr.rs `tests` | unit | tested |
| `user_name` | src-tauri/src/seerr.rs:613 | src-tauri/src/seerr.rs `tests` | unit | tested |
| `connection_from` | src-tauri/src/seerr.rs:623 | src-tauri/src/seerr.rs `tests` | unit | tested via connect, connect_with_password |
| `quick_connect` | src-tauri/src/seerr.rs:671 | src-tauri/src/seerr.rs `tests` | unit | tested via connect, renew |
| `keep` | src-tauri/src/seerr.rs:720 | src-tauri/src/seerr.rs `tests` | unit | tested via connect (the failure branch needs a keyring that refuses a write and no saved account: untested) |
| `signed_in` | src-tauri/src/seerr.rs:731 | src-tauri/src/seerr.rs `tests` | unit | tested via connecting_needs_a_jellyfin_session |
| `usable` | src-tauri/src/seerr.rs:735 | src-tauri/src/seerr.rs `tests` | unit | tested via connect |
| `jellyfin_quick_connect_on` | src-tauri/src/seerr.rs:741 | src-tauri/src/seerr.rs `tests` | unit | tested via quick_connect_turned_off_in_jellyfin_goes_to_the_password_without_asking_seerr |
| `connect` | src-tauri/src/seerr.rs:750 | src-tauri/src/seerr.rs `tests` | unit | tested; stand-in Seerr in `qa_tests` |
| `connect_with_password` | src-tauri/src/seerr.rs:763 | src-tauri/src/seerr.rs `tests` | unit | tested |
| `RENEWALS` | src-tauri/src/seerr.rs:786 | src-tauri/src/seerr.rs `tests` | unit | tested via requests_that_find_the_session_gone_together_share_one_renewal |
| `renewal_lock` | src-tauri/src/seerr.rs:788 | src-tauri/src/seerr.rs `tests` | unit | tested via requests_that_find_the_session_gone_together_share_one_renewal |
| `renew` | src-tauri/src/seerr.rs:795 | src-tauri/src/seerr.rs `tests` | unit | tested |
| `reconnect` | src-tauri/src/seerr.rs:818 | src-tauri/src/seerr.rs `tests` | unit | tested |
| `refresh` | src-tauri/src/seerr.rs:828 | src-tauri/src/seerr.rs `tests` | unit | tested |
| `forget` | src-tauri/src/seerr.rs:866 | src-tauri/src/seerr.rs `tests` | unit | tested via disconnect, sign_out |
| `sign_out` | src-tauri/src/seerr.rs:876 | src-tauri/src/seerr.rs `tests` | unit | tested via disconnect, server::logout |
| `disconnect` | src-tauri/src/seerr.rs:884 | src-tauri/src/seerr.rs `tests` | unit | tested; stand-in Seerr in `qa_tests` |
| `SEERR_ACCOUNT` | src-tauri/src/secret.rs:47 | src-tauri/src/secret.rs `tests` | unit | tested via items_keep_the_attributes_the_keyring_crate_wrote |
| `seerr_slot` | src-tauri/src/secret.rs:556 | src-tauri/src/secret.rs `tests` | unit | tested |
| `remember_seerr` | src-tauri/src/secret.rs:560 | src-tauri/src/secret.rs `tests` | unit | tested via a_seerr_lookup_is_made_once_per_account |
| `seerr_in_file` | src-tauri/src/secret.rs:565 | src-tauri/src/secret.rs `tests` | unit | tested via a_seerr_session_falls_back_to_its_accounts_config_entry |
| `store_seerr` | src-tauri/src/secret.rs:576 | src-tauri/src/secret.rs `tests` | unit | CI only (not run on macOS): the config.json fallback; the keyring path is on the manual checklist (item 25) |
| `seerr_session` | src-tauri/src/secret.rs:604 | src-tauri/src/secret.rs `tests` | unit | CI only (not run on macOS) |
| `clear_seerr` | src-tauri/src/secret.rs:621 | src-tauri/src/secret.rs `tests` | unit | CI only (not run on macOS) |
| `current_account` | src-tauri/src/server.rs:755 | src-tauri/src/seerr.rs `tests` | unit | tested via the_session_stays_on_this_side_of_the_ipc_boundary |
| `logout`, `forget_account` → seerr::sign_out; `accounts` strips `seerr` | src-tauri/src/server.rs | src-tauri/src/seerr.rs `tests` | unit | tested via signing_out_of_jellyfin_takes_the_seerr_session_with_it, the_session_stays_on_this_side_of_the_ipc_boundary (forget_account's call untested) |
| `seerr_status` (Tauri command: seerr::status) | src-tauri/src/lib.rs:283 | none | needs real Linux | untested: lib.rs is Linux-only; seerr::status is tested |
| `seerr_probe` (Tauri command: seerr::probe) | src-tauri/src/lib.rs:288 | none | needs real Linux | untested: lib.rs is Linux-only; seerr::probe is tested |
| `seerr_connect` (Tauri command: seerr::connect) | src-tauri/src/lib.rs:294 | none | needs real Linux | untested: lib.rs is Linux-only; seerr::connect is tested |
| `seerr_connect_password` (Tauri command: seerr::connect_with_password) | src-tauri/src/lib.rs:301 | none | needs real Linux | untested: lib.rs is Linux-only; seerr::connect_with_password is tested |
| `seerr_reconnect` (Tauri command: seerr::reconnect) | src-tauri/src/lib.rs:306 | none | needs real Linux | untested: lib.rs is Linux-only; seerr::reconnect is tested |
| `seerr_disconnect` (Tauri command: seerr::disconnect) | src-tauri/src/lib.rs:311 | none | needs real Linux | untested: lib.rs is Linux-only; seerr::disconnect is tested |
| `seerr_refresh` (Tauri command: seerr::refresh) | src-tauri/src/lib.rs:317 | none | needs real Linux | untested: lib.rs is Linux-only; seerr::refresh is tested |
| `seerr_request` (Tauri command: seerr::request) | src-tauri/src/lib.rs:322 | none | needs real Linux | untested: lib.rs is Linux-only; seerr::request is tested |


### Delete from Server (added 2026-11-26)

| Function | Source | Test file | Kind | Status |
|---|---|---|---|---|
| deleteItem | src/api.ts | tests/unit/api-browse.test.ts | unit | tested |
| canManageRequests, removalKind, mightRemove, serviceName | src/seerr.ts | tests/unit/seerr.test.ts | unit | tested |
| removal | src/seerr.ts | tests/unit/seerr.test.ts | unit | tested |
| remove | src/seerr.ts | tests/unit/seerr.test.ts | unit | tested |
| mightDeleteFromServer, askDeleteFromServer, the menu entry in itemActions | src/ui.ts | tests/dom/ui.test.ts | DOM | tested |
| `aquarium-item-deleted` listener (redraws the page) | src/main.ts | none | DOM | untested: one line calling route(); manual checklist item 30 |
| allowed: `/service/radarr`, `/service/sonarr`, `DELETE /media/{id}/file`, `DELETE /media/{id}` | src-tauri/src/seerr.rs | seerr.rs tests | Rust unit | written 2026-11-26, not yet run: the Mac it was written on has no Cargo |
