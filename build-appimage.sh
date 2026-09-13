#!/usr/bin/env bash
# Full FellyJin AppImage build: compile, bundle, inject mpv.
set -euo pipefail

PROJ="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJ"

[ -f "$HOME/.cargo/env" ] && source "$HOME/.cargo/env"
export APPIMAGE_EXTRACT_AND_RUN=1
export NO_STRIP=1

echo "==> Compiling (frontend + Rust, release)"
# Local dev headers (see .build-deps/setup-deps.sh) — only needed when the
# GTK/WebKit dev packages aren't installed system-wide.
if [ -f "$PROJ/.build-deps/env.sh" ]; then
  source "$PROJ/.build-deps/env.sh"
fi
npx tauri build --no-bundle

echo "==> Bundling base AppImage"
# The linuxdeploy GTK plugin locates *runtime* GTK modules through pkg-config,
# so it must see the original /usr-prefixed .pc files, not the rewritten ones.
if [ -d "$PROJ/.build-deps/bundle-pc" ]; then
  export PKG_CONFIG_PATH="$PROJ/.build-deps/bundle-pc"
fi
npx tauri bundle

echo "==> Injecting mpv"
"$PROJ/bundle-mpv.sh"
