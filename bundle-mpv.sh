#!/usr/bin/env bash
# Injects mpv (and its library dependencies) into the Tauri-built AppDir and
# repacks the AppImage, so FellyJin is fully self-contained on any distro.
# Run after `npm run tauri build`.
set -euo pipefail

PROJ="$(cd "$(dirname "$0")" && pwd)"
BUNDLE_DIR="$PROJ/src-tauri/target/release/bundle/appimage"
APPDIR="$BUNDLE_DIR/FellyJin.AppDir"
LINUXDEPLOY="$HOME/.cache/tauri/linuxdeploy-x86_64.AppImage"
MPV_BIN="${MPV_SOURCE:-/usr/bin/mpv}"

[ -d "$APPDIR" ] || { echo "AppDir not found: $APPDIR (run tauri build first)"; exit 1; }
[ -x "$MPV_BIN" ] || { echo "mpv not found at $MPV_BIN"; exit 1; }
[ -f "$LINUXDEPLOY" ] || { echo "linuxdeploy not cached at $LINUXDEPLOY"; exit 1; }

export APPIMAGE_EXTRACT_AND_RUN=1
export NO_STRIP=1
# linuxdeploy needs these to identify the app; reuse existing desktop/icon.
export LDAI_OUTPUT="$BUNDLE_DIR/FellyJin_repack.AppImage"

echo "==> Deploying mpv + dependencies into AppDir"
"$LINUXDEPLOY" --appdir "$APPDIR" -e "$MPV_BIN" 2>&1 | tail -4

echo "==> Renaming bundled mpv to fellyjin-mpv"
mv "$APPDIR/usr/bin/mpv" "$APPDIR/usr/bin/fellyjin-mpv"

echo "==> Installing mpv config (uosc UI)"
rm -rf "$APPDIR/usr/share/fellyjin/mpv"
mkdir -p "$APPDIR/usr/share/fellyjin"
cp -r "$PROJ/src-tauri/mpv-config" "$APPDIR/usr/share/fellyjin/mpv"

echo "==> Repacking AppImage"
"$LINUXDEPLOY" --appdir "$APPDIR" --output appimage 2>&1 | tail -4

FINAL="$BUNDLE_DIR/FellyJin-x86_64.AppImage"
# linuxdeploy names output from desktop file; normalize.
GEN="$(ls -t "$BUNDLE_DIR"/*.AppImage 2>/dev/null | head -1)"
if [ -n "$GEN" ] && [ "$GEN" != "$FINAL" ]; then
  mv "$GEN" "$FINAL"
fi
echo "==> Done: $FINAL"
ls -lh "$FINAL"
