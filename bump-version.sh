#!/usr/bin/env bash
# Bump the app version everywhere it is declared, so an installed .deb is
# actually superseded by the next one — apt compares versions and will not
# reinstall the same one.
#
#   ./bump-version.sh            # patch: 0.1.0 -> 0.1.1
#   ./bump-version.sh minor      # 0.1.3 -> 0.2.0
#   ./bump-version.sh major      # 0.2.4 -> 1.0.0
#   ./bump-version.sh 0.4.2      # exact
#
# The version lives in four files: tauri.conf.json is what the .deb is stamped
# with, and the other three would drift out of sync with it silently.
set -euo pipefail

PROJ="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJ"

CUR="$(sed -n 's/^  "version": "\(.*\)",$/\1/p' src-tauri/tauri.conf.json | head -1)"
[ -n "$CUR" ] || { echo "FATAL: no version found in src-tauri/tauri.conf.json"; exit 1; }

IFS=. read -r MA MI PA <<<"$CUR"
case "${1:-patch}" in
  patch) NEW="$MA.$MI.$((PA + 1))" ;;
  minor) NEW="$MA.$((MI + 1)).0" ;;
  major) NEW="$((MA + 1)).0.0" ;;
  [0-9]*.[0-9]*.[0-9]*) NEW="$1" ;;
  *) echo "usage: $0 [patch|minor|major|X.Y.Z]"; exit 1 ;;
esac

# Anchored to each file's own line shape rather than a blanket replace: the
# version string is short enough to collide with unrelated numbers.
sed -i "s/^  \"version\": \"$CUR\",$/  \"version\": \"$NEW\",/" src-tauri/tauri.conf.json
sed -i "0,/^  \"version\": \"$CUR\",$/s//  \"version\": \"$NEW\",/" package.json
sed -i "0,/^version = \"$CUR\"$/s//version = \"$NEW\"/" src-tauri/Cargo.toml
# The lock's own entry for this crate, found by its name line rather than by
# position — every dependency in the file has a `version =` line too.
sed -i "/^name = \"aquarium\"$/{n;s/^version = \".*\"$/version = \"$NEW\"/}" src-tauri/Cargo.lock

echo "$CUR -> $NEW"
grep -Hn "\"version\": \"$NEW\"\|^version = \"$NEW\"" \
  src-tauri/tauri.conf.json package.json src-tauri/Cargo.toml src-tauri/Cargo.lock
