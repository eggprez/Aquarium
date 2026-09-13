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
# linuxdeploy exits non-zero on warnings even when it actually succeeds. A
# plain `| tail || true` should swallow that under set -e/pipefail, but that
# hasn't held up reliably in CI, so capture the exit code explicitly instead
# of trusting pipe/subshell status propagation at all.
set +e
"$LINUXDEPLOY" --appdir "$APPDIR" -e "$MPV_BIN" > /tmp/ld1.log 2>&1
LD1_EXIT=$?
set -e
tail -30 /tmp/ld1.log
echo "(linuxdeploy exit code: $LD1_EXIT — non-zero here is expected/benign)"

echo "==> Renaming bundled mpv to fellyjin-mpv"
mv "$APPDIR/usr/bin/mpv" "$APPDIR/usr/bin/fellyjin-mpv"

echo "==> Installing mpv config (uosc UI)"
rm -rf "$APPDIR/usr/share/fellyjin/mpv"
mkdir -p "$APPDIR/usr/share/fellyjin"
cp -r "$PROJ/src-tauri/mpv-config" "$APPDIR/usr/share/fellyjin/mpv"

echo "==> Repacking AppImage"
set +e
"$LINUXDEPLOY" --appdir "$APPDIR" --output appimage > /tmp/ld2.log 2>&1
LD2_EXIT=$?
set -e
tail -30 /tmp/ld2.log
echo "(linuxdeploy exit code: $LD2_EXIT — non-zero here is expected/benign)"

FINAL="$BUNDLE_DIR/FellyJin-x86_64.AppImage"
# linuxdeploy names output from desktop file; normalize.
GEN="$(ls -t "$BUNDLE_DIR"/*.AppImage 2>/dev/null | head -1)"
# The .zsync sidecar appimagetool writes doesn't necessarily share GEN's exact
# basename, so find it by newest-mtime *.zsync rather than assuming "$GEN.zsync".
GEN_ZSYNC="$(ls -t "$BUNDLE_DIR"/*.zsync 2>/dev/null | head -1)"
if [ -n "$GEN" ] && [ "$GEN" != "$FINAL" ]; then
  mv "$GEN" "$FINAL"
fi
if [ -n "$GEN_ZSYNC" ] && [ "$GEN_ZSYNC" != "$FINAL.zsync" ]; then
  mv "$GEN_ZSYNC" "$FINAL.zsync"
fi
# Genuine failure check: the linuxdeploy warning-exit-code quirk is fine to
# swallow, but if the final AppImage genuinely wasn't produced, stop here.
[ -f "$FINAL" ] || { echo "FATAL: $FINAL was not produced"; exit 1; }
echo "==> Done: $FINAL"
ls -lh "$FINAL" "$FINAL.zsync" 2>/dev/null || ls -lh "$FINAL"
