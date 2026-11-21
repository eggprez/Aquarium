#!/usr/bin/env bash
# Regenerate every app icon and the in-app logo from the vector sources:
#   Aquarium.svg                      — the icon, used at 64 px and up
#   src-tauri/icons/aquarium-small.svg — simplified variant for 32 px
# Each size is rendered straight from the SVG (tauri's resvg), not scaled
# down from a bitmap, so edges stay sharp at every size.
set -euo pipefail
cd "$(dirname "$0")"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# GNOME draws its running-app dot under the icon, and a tile that fills its
# square hides it: the app icons carry the artwork at 86% with a transparent
# margin. The in-app logo below stays full-bleed.
pad() { sed 's|<g id="art">|<g id="art" transform="translate(71.68 71.68) scale(0.86)">|' "$1" > "$2"; }
pad Aquarium.svg "$tmp/icon.svg"
pad src-tauri/icons/aquarium-small.svg "$tmp/small.svg"

npx tauri icon "$tmp/icon.svg"

# The small variant replaces the full design at 32 px.
npx tauri icon "$tmp/small.svg" -o "$tmp/out" -p 32 >/dev/null
cp "$tmp/out/32x32.png" src-tauri/icons/32x32.png

# The webview shows the logo at 30–56 CSS px on HiDPI screens; ship the vector.
cp Aquarium.svg public/aquarium-logo.svg
echo "==> Icons regenerated"
