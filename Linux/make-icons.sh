#!/usr/bin/env bash
# Regenerate every app icon and the in-app logo from the vector sources:
#   Aquarium.svg                      — the icon, used at 64 px and up
#   src-tauri/icons/aquarium-small.svg — simplified variant for 32 px
# Each size is rendered straight from the SVG (tauri's resvg), not scaled
# down from a bitmap, so edges stay sharp at every size.
set -euo pipefail
cd "$(dirname "$0")"

npx tauri icon Aquarium.svg

# The small variant replaces the full design at 32 px.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
npx tauri icon src-tauri/icons/aquarium-small.svg -o "$tmp" -p 32 >/dev/null
cp "$tmp/32x32.png" src-tauri/icons/32x32.png

# The webview shows the logo at 30–56 CSS px on HiDPI screens; ship the vector.
cp Aquarium.svg public/aquarium-logo.svg
echo "==> Icons regenerated"
