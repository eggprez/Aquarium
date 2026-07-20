#!/usr/bin/env bash
# Downloads and extracts the -dev packages Tauri needs into a local root,
# so the project builds without sudo. Re-runnable; skips completed work.
set -euo pipefail

DEPS_DIR="$(cd "$(dirname "$0")" && pwd)"
DEBS="$DEPS_DIR/debs"
ROOT="$DEPS_DIR/root"
mkdir -p "$DEBS" "$ROOT"

echo "==> Resolving package URIs via apt"
mapfile -t URIS < <(apt-get install --print-uris -qq \
  libwebkit2gtk-4.1-dev libgtk-3-dev librsvg2-dev libssl-dev libdbus-1-dev \
  | sed -E "s/^'([^']+)'.*/\1/")

echo "==> Downloading ${#URIS[@]} packages"
for uri in "${URIS[@]}"; do
  f="$DEBS/$(basename "$uri" | sed 's/%2b/+/g;s/%3a/:/g')"
  [ -s "$f" ] || curl -fsSL -o "$f" "$uri"
done

echo "==> Extracting"
for deb in "$DEBS"/*.deb; do
  dpkg-deb -x "$deb" "$ROOT"
done

echo "==> Rewriting pkg-config prefixes to $ROOT"
find "$ROOT" -name '*.pc' -print0 | xargs -0 sed -i "s|=/usr|=$ROOT/usr|g; s|-I/usr|-I$ROOT/usr|g; s|-L/usr|-L$ROOT/usr|g"

echo "==> Fixing .so symlinks that point at libs installed system-wide"
find "$ROOT" -name '*.so' -type l | while read -r link; do
  tgt="$(readlink "$link")"
  # Resolve relative targets against the link's own directory inside ROOT
  case "$tgt" in
    /*) resolved="$ROOT$tgt" ;;
    *)  resolved="$(dirname "$link")/$tgt" ;;
  esac
  if [ ! -e "$resolved" ]; then
    sys="/usr/lib/x86_64-linux-gnu/$(basename "$tgt")"
    if [ -e "$sys" ]; then
      ln -sf "$sys" "$link"
    fi
  fi
done

cat > "$DEPS_DIR/env.sh" <<EOF
export PKG_CONFIG_PATH="$ROOT/usr/lib/x86_64-linux-gnu/pkgconfig:$ROOT/usr/lib/pkgconfig:$ROOT/usr/share/pkgconfig\${PKG_CONFIG_PATH:+:\$PKG_CONFIG_PATH}"
export CPATH="$ROOT/usr/include\${CPATH:+:\$CPATH}"
export LIBRARY_PATH="$ROOT/usr/lib/x86_64-linux-gnu\${LIBRARY_PATH:+:\$LIBRARY_PATH}"
EOF

echo "==> Done. Source $DEPS_DIR/env.sh before building."
