#!/usr/bin/env bash
# Build (unless --no-build) and reinstall Aquarium over the installed copy.
#
# `apt install ./aquarium.deb` is a no-op when the version in the package equals
# the version already installed — which is always, since we never bump 0.1.0
# between local builds. `dpkg -i` unpacks unconditionally, and the follow-up
# `apt-get -f install` settles any dependency the package pulled in.
set -euo pipefail

PROJ="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJ"

if [ "${1:-}" = "--no-build" ]; then
  [ -f "$PROJ/aquarium.deb" ] || { echo "FATAL: no aquarium.deb to install; drop --no-build"; exit 1; }
  echo "==> Skipping build, reusing $(ls -lh aquarium.deb | awk '{print $5, $6, $7, $8}')"
else
  "$PROJ/build-deb.sh"
fi

# The running instance holds /usr/bin/aquarium open (mpv runs in-process, no
# separate child any more); replacing the binary under it leaves a zombie
# window. -x (not -f) so this script's own command line isn't a match.
if pgrep -x aquarium >/dev/null; then
  echo "==> Closing the running Aquarium"
  pkill -x aquarium || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -x aquarium >/dev/null || break
    sleep 0.3
  done
  pgrep -x aquarium >/dev/null && pkill -9 -x aquarium || true
fi

echo "==> Reinstalling (sudo)"
sudo dpkg -i "$PROJ/aquarium.deb"
sudo apt-get -f install -y

echo
dpkg -l aquarium | tail -1
echo "==> Installed. Launch with: aquarium"
