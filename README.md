# FellyJin

## iPhone, iPad and Apple TV

FellyJin is also on the App Store for iPhone, iPad and Apple TV, as a native
SwiftUI app that shares its behaviour with this Linux build but not its code.
It was written with AI assistance (Anthropic's Claude), directed and tested by
the developer, and is shared as-is. **Support:** open an issue on this
repository. **Privacy policy:** [PRIVACY.md](PRIVACY.md) — the app collects
nothing and talks only to your own Jellyfin server.


A lightweight, modern Jellyfin client for Linux, packaged as an AppImage.

> **Note:** This app was built with AI assistance (Claude). It's a personal
> project shared as-is, with no guarantee of ongoing updates, support, or
> maintenance. Use at your own risk — review the code before running it
> against your Jellyfin server.

- **UI**: Tauri 2 (Rust + system WebKitGTK) — tiny footprint compared to Electron.
- **Playback**: [mpv](https://mpv.io), bundled inside the AppImage and controlled
  over its JSON IPC socket. Video renders **embedded inside the app window**
  (X11 child-window embedding via `--wid`; on Wayland sessions mpv is forced
  onto XWayland by stripping `WAYLAND_DISPLAY`, since mpv's Wayland backend
  ignores `--wid`). On-screen controls are provided by a bundled
  [uosc](https://github.com/tomasklaen/uosc) layout: −30s / play-pause / +30s,
  subtitle and audio-track menus, a transcode-quality menu, and an episode
  queue — the last two are app-driven via mpv script-messages over IPC.
  Keyboard: Space pause, ←/→ seek, `f` fullscreen, Esc exit. If X11 embedding
  is unavailable, playback falls back to a separate mpv window automatically.

## Features

- **Direct streaming** — original quality, remux-free `static=true` streams.
- **Transcoded streaming** — pick a bitrate (20/10/4/1.5 Mbps); the server is
  asked via `PlaybackInfo` with an HLS h264/aac device profile and mpv plays the
  returned HLS transcode.
- **Downloads** — original-quality direct download or transcoded downloads
  (1080p/720p/480p) via the progressive transcode endpoint, stored under
  `~/.local/share/fellyjin/downloads`.
- **Offline progress sync** — watching a downloaded item records position/watched
  state locally and syncs it back to Jellyfin (resume points via playback-stopped
  reports, watched flags via the played-items endpoint) whenever the server is
  reachable — automatically at app start, after local playback, or manually from
  the Downloads view.
- **Live TV** — channel list with current-program info; channels play through
  `PlaybackInfo` + `AutoOpenLiveStream` (direct or server-transcoded HLS).
- Home (Continue Watching / Next Up / Latest), library browsing with sorting and
  paging, series → season → episode navigation, search, watched toggles, and
  playback progress reported to the server every 10 s like any first-class client.

## Building

Requirements: Rust (stable), Node 20+, mpv installed on the build machine, and
the GTK3/WebKitGTK 4.1 dev headers. On a machine without root, run
`.build-deps/setup-deps.sh` to fetch and extract the headers locally, then
`source .build-deps/env.sh` before building.

```sh
npm install
./build-appimage.sh   # compiles, bundles, injects mpv — the whole pipeline
```

Final artifact: `src-tauri/target/release/bundle/appimage/FellyJin-x86_64.AppImage`

Note: the base bundle step must see the *original* `/usr`-prefixed .pc files
(in `.build-deps/bundle-pc`) so linuxdeploy's GTK plugin can find runtime GTK
modules — `build-appimage.sh` handles switching `PKG_CONFIG_PATH` between the
compile and bundle phases.

## Development

```sh
source .build-deps/env.sh
npm run tauri dev
```

mpv resolution order at runtime: `mpv_path` in Settings → `$FELLYJIN_MPV` →
bundled `fellyjin-mpv` next to the executable → `mpv` on `$PATH`.

## Storage

- Config: `~/.config/fellyjin/config.json` (server, token, device id, prefs)
- Downloads + offline progress queue: `~/.local/share/fellyjin/`

## Releases & updating

Pushing a `v*` tag (e.g. `git tag v0.1.0 && git push --tags`) triggers a GitHub
Actions build that publishes `FellyJin-x86_64.AppImage` to
[Releases](../../releases). The AppImage has update info embedded, so
[AppImageUpdate](https://github.com/AppImage/AppImageUpdate) (or
`./FellyJin-x86_64.AppImage --appimage-update` if updated in place) can check
and update it against this repo's latest release without a manual redownload.
