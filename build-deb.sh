#!/usr/bin/env bash
# Full FellyJin .deb build: compile frontend + Rust, bundle, drop the package
# in the project root as felly.deb.
#
# Unlike the AppImage this replaced, the package does not carry mpv or GTK with
# it — `Depends: libmpv2, libwebkit2gtk-4.1-0, libgtk-3-0` pulls them from the
# distro, which is the point of shipping a .deb.
#
# Run ./bump-version.sh first if anything changed since the last build: apt
# compares versions, so a rebuild at the same version installs as a no-op and
# you end up testing the previous binary.
set -euo pipefail

PROJ="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJ"

[ -f "$HOME/.cargo/env" ] && source "$HOME/.cargo/env"

echo "==> Compiling (frontend + Rust, release)"
# Local dev headers (see .build-deps/setup-deps.sh) — only needed when the
# GTK/WebKit dev packages aren't installed system-wide.
if [ -f "$PROJ/.build-deps/env.sh" ]; then
  source "$PROJ/.build-deps/env.sh"
fi
npx tauri build

DEB="$(ls -t "$PROJ/src-tauri/target/release/bundle/deb"/*.deb 2>/dev/null | head -1)"
[ -n "$DEB" ] || { echo "FATAL: no .deb was produced"; exit 1; }

cp "$DEB" "$PROJ/felly.deb"
echo "==> Done: $PROJ/felly.deb"
dpkg-deb -I "$PROJ/felly.deb" | sed -n '3,12p'
ls -lh "$PROJ/felly.deb"
echo
echo "Install with: sudo apt install $PROJ/felly.deb"
