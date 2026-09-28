# Aquarium

**Aquarium** (on the App Store as "Aquarium Media") is a native SwiftUI
Jellyfin client for iPhone, iPad, Apple TV, Mac and Apple Watch. It was
called FellyJin until September 2026. The source is in
[`Aquarium/`](Aquarium/); see its [README](Aquarium/README.md) for features,
architecture and building.

It was written with AI assistance (Anthropic's Claude), directed and tested
by the developer, and is shared as-is.

**Support:** open an issue on this repository. **Privacy policy:**
[PRIVACY.md](PRIVACY.md) — the app collects nothing and talks only to your own
Jellyfin server (plus your own iCloud, if you enable sync).

Aquarium is an independent app and is not affiliated with or endorsed by the
Jellyfin project.

## Server compatibility

Jellyfin **10.9 through 12.x**. The app speaks only the current API: the
`MediaBrowser` scheme in the standard `Authorization` header (never the
Emby-era `X-Emby-Token` / `X-Emby-Authorization` headers or an `api_key=`
query parameter, all of which Jellyfin 12 disables by default), and the
`userId=`-query routes (`/Items`, `/UserViews`, `/UserItems/Resume`,
`/UserPlayedItems`, `/UserFavoriteItems`) that replaced `/Users/{id}/…` in
10.9 — the old ones still answer on 12.0 but are marked obsolete there.

## The Linux client

This project began as a Linux client (Tauri + libmpv, packaged as a `.deb`).
It has been retired; its last version lives on the
[`sync-linux-client-v0.1.30`](../../tree/sync-linux-client-v0.1.30) branch.
