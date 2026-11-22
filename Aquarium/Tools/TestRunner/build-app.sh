#!/bin/zsh
# Builds "Aquarium Tests.app", the window onto Tools/run-tests.sh and the
# Linux app's tests.
#
#   Tools/TestRunner/build-app.sh            build "Aquarium Tests.app" in the repository's top folder
#   Tools/TestRunner/build-app.sh --open     build, then open it
#   Tools/TestRunner/build-app.sh --install  build, copy to /Applications, open that
#
# The app is a thin shell: what it can run is suites.json (read from this
# checkout each time it opens), and the tests it lists come from scanning the
# test folders. Only a change to Sources/ needs a rebuild.

set -eo pipefail
HERE=${0:A:h}
REPO=${HERE:h:h:h}
cd "$HERE"

swift build -c release 2>&1 | tail -3
APP="$REPO/Aquarium Tests.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/AquariumTestRunner "$APP/Contents/MacOS/AquariumTestRunner"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>scottai.FellyJin.TestRunner</string>
  <key>CFBundleName</key><string>Aquarium Tests</string>
  <key>CFBundleExecutable</key><string>AquariumTestRunner</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>AquariumRepoRoot</key><string>$REPO</string>
</dict></plist>
EOF
codesign --force --sign - "$APP" 2>/dev/null
echo "built $APP"

case ${1:-} in
  --open) open "$APP";;
  --install)
    rm -rf "/Applications/Aquarium Tests.app"
    cp -R "$APP" "/Applications/Aquarium Tests.app"
    echo "installed /Applications/Aquarium Tests.app"
    open "/Applications/Aquarium Tests.app";;
esac
