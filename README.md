# FellyJin

## iPhone, iPad and Apple TV: Aquarium

The Apple app is called **Aquarium** (on the App Store as "Aquarium Media") —
it was FellyJin until September 2026. It is a native SwiftUI app for iPhone,
iPad, Apple TV and Mac that shares its behaviour with this Linux build but not
its code; the source is in [`Aquarium/`](Aquarium/) (see its
[README](Aquarium/README.md)). It was written with AI assistance (Anthropic's
Claude), directed and tested by the developer, and is shared as-is.
**Support:** open an issue on this repository. **Privacy policy:**
[PRIVACY.md](PRIVACY.md) — the app collects nothing and talks only to your own
Jellyfin server (plus your own iCloud, if you enable sync).

Aquarium is an independent app and is not affiliated with or endorsed by the
Jellyfin project.

## Linux

A lightweight, modern Jellyfin client for Linux, packaged as a Debian package.

> **Note:** This app was built with AI assistance (Claude). It's a personal
> project shared as-is, with no guarantee of ongoing updates, support, or
> maintenance. Use at your own risk — review the code before running it
> against your Jellyfin server.

- **UI**: Tauri 2 (Rust + system WebKitGTK) — tiny footprint compared to Electron.
- **Playback**: [mpv](https://mpv.io)'s libmpv, linked directly into the process
  and driven through its render API rather than run as a separate binary — no
  IPC socket, no external mpv window. Video renders **embedded inside the app
  window** and mpv never owns a window of its own: on Wayland it draws from a
  thread of its own into a `wl_subsurface` of the app window, so the GTK main
  thread does nothing per video frame; on X11 it draws into a `GtkGLArea`
  overlaid on the webview. The app runs as a native client on whichever
  backend GDK picks, with hardware decode intact on both. On-screen controls are provided by a bundled
  [uosc](https://github.com/tomasklaen/uosc) layout: −30s / play-pause / +30s,
  subtitle and audio-track menus, a transcode-quality menu, and an episode
  queue — the last two are app-driven via mpv script-messages. Keyboard: Space
  pause, ←/→ seek, `f` fullscreen, `p` picture-in-picture, Esc exit.
  Picture-in-picture moves the running video widget into a small always-on-top
  window, so the stream never restarts and the player bar goes on driving it
  while you browse.

## Server compatibility

Jellyfin **10.9 through 12.x**. The client speaks only the current API: the
`MediaBrowser` scheme in the standard `Authorization` header (never the
Emby-era `X-Emby-Token` / `X-Emby-Authorization` headers or an `api_key=`
query parameter, all of which Jellyfin 12 disables by default), and the
`userId=`-query routes (`/Items`, `/UserViews`, `/UserItems/Resume`,
`/UserPlayedItems`, `/UserFavoriteItems`) that replaced `/Users/{id}/…` in
10.9 — the old ones still answer on 12.0 but are marked obsolete there.

## Features

- **Direct streaming** — original quality, remux-free `static=true` streams.
- **Transcoded streaming** — pick a bitrate (35/18/10/5/2.5 Mbps); the server is
  asked via `PlaybackInfo` with an HLS h264/aac device profile and mpv plays the
  returned HLS transcode.
- **Adaptive quality** — when a stream keeps stalling for cache, or the machine
  starts dropping frames because it can't decode what it's been sent, the player
  drops a rung by itself and picks up where it left off; after five clean
  minutes with a healthy read-ahead it climbs back, and a rung that fails on the
  way up isn't tried again. It never goes above the quality you chose, never
  touches downloaded files or Live TV, and is switchable per-session from the
  in-player quality menu or for good in Settings → Playback.
- **Downloads** — original-quality direct download or transcoded downloads
  (4K/1440p/1080p/720p/480p) via the progressive transcode endpoint, stored under
  `~/.local/share/fellyjin/downloads`. A transcode that would come out *larger*
  than the source file is silently replaced by the direct download — an
  efficiently encoded original is the smaller file and the better picture, so
  re-encoding it is a loss twice over. Before anything is queued the estimated
  size is checked against the free space on that volume; a season that won't fit
  says so, with the numbers, and offers the quality rungs that would.
- **Detail pages** — cast (each name searches for itself), "More like this" from
  the server's own recommendations, and a line describing what the source file
  actually is (`1080p · HEVC · EAC3 · 5.1 · 8.4 GiB`) beside the quality menu.
- **Offline progress sync** — watching a downloaded item records position/watched
  state locally and syncs it back to Jellyfin (resume points via playback-stopped
  reports, watched flags via the played-items endpoint) whenever the server is
  reachable — automatically at app start, after local playback, or manually from
  the Downloads view.
- **Live TV** — channel list with current-program info; channels play through
  `PlaybackInfo` + `AutoOpenLiveStream` (direct or server-transcoded HLS).
- **Power** — while the video covers the page, the app freezes the page's
  animations and stops GTK repainting the web view underneath, and WebKit is
  told to render to shared memory (see `webkit_defaults` in
  `src-tauri/src/main.rs`). On Wayland the video bypasses GTK's paint path
  altogether (a subsurface, see
  [`WAYLAND-SUBSURFACE-PLAN.md`](WAYLAND-SUBSURFACE-PLAN.md)), which is what
  takes the main thread from half a core to idle during playback.
- **Battery saver rendering** — Settings → Playback swaps mpv's default
  scaler chain for bilinear with 8-bit intermediates, which on a HiDPI panel
  is the difference between the GPU idling and not. Off by default.
- **Light / dark theme** — Settings → Appearance, with an Auto option that
  follows the desktop's colour scheme (read from the XDG desktop portal, so it
  tracks GNOME/KDE's dark-style toggle rather than the GTK theme name) and
  updates live when it changes.
- Home (Continue Watching / Next Up / Latest), library browsing with sorting and
  paging, series → season → episode navigation, search, watched toggles, and
  playback progress reported to the server every 10 s like any first-class client.

## Building

Requirements: Rust (stable), Node 20+, and the GTK3/WebKitGTK 4.1 + libmpv dev
headers (`libmpv-dev`) — mpv is linked in at build time, not just installed
alongside the app. On a machine without root, run `.build-deps/setup-deps.sh`
to fetch and extract the headers locally, then `source .build-deps/env.sh`
before building.

```sh
npm install
./build-deb.sh   # compiles frontend + Rust, bundles, writes ./felly.deb
```

Final artifact: `felly.deb` in the project root (also left at
`src-tauri/target/release/bundle/deb/`). Install it with:

```sh
sudo apt install ./felly.deb
```

The package depends on `libmpv2`, `libwebkit2gtk-4.1-0` and `libgtk-3-0` rather
than carrying them, so apt resolves them from the distro.

## Development

```sh
source .build-deps/env.sh
npm run tauri dev
```

The uosc layout and mpv config install to `/usr/share/fellyjin/mpv`, found at
runtime relative to the executable; `$FELLYJIN_MPV_CONFIG` overrides it.

## Storage

- Config: `~/.config/fellyjin/config.json` (server, token, device id, prefs)
- Downloads + offline progress queue: `~/.local/share/fellyjin/`

## Releases & updating

Pushing a `v*` tag (e.g. `git tag v0.1.0 && git push --tags`) triggers a GitHub
Actions build that publishes `felly.deb` to [Releases](../../releases).

Updating is `sudo apt install ./felly.deb` over the installed version — there is
no self-update mechanism (the AppImage's embedded AppImageUpdate info went away
with it).
