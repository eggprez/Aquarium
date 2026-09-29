# Aquarium

Jellyfin client in two independent apps that share behaviour but not code:

- `Aquarium/`: the Apple app (SwiftUI; iPhone, iPad, Apple TV, Mac, Watch).
- `Linux/`: the Linux app (Tauri 2 + libmpv, shipped as a `.deb`). Its build, test hooks and invariants are in `Linux/CLAUDE.md`, and every path there is relative to `Linux/`.

Both apps live on `main`. `PRIVACY.md` stays at the root because the App Store listing links to it. `.github/workflows/linux-release.yml` builds the Linux `.deb` on `v*` tags.
