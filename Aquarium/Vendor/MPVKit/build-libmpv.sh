#!/bin/zsh
# Rebuild the iPhone and iPad slices of Libmpv.xcframework from MPVKit 1.0.0's
# own build scripts, with patch/0004 (vo=avfoundation) added. The other slices
# (Apple TV, Mac, visionOS, Catalyst) are 1.0.0's and are left as they are.
#
#   ./build-libmpv.sh [work-dir]
#
# Takes about an hour: FFmpeg is built from source for the two slices so mpv
# has its headers to build against. Homebrew packages the scripts want
# (meson, ninja, nasm, pkg-config, wget, sdl2) are installed on the way.
set -euo pipefail

here=${0:A:h}
work=${1:-$(mktemp -d)/mpvkit}
tag=1.0.0

if [[ ! -d $work ]]; then
    git clone --depth 1 --branch $tag https://github.com/mpvkit/MPVKit.git $work
fi
cp $here/patch/0004-avfoundation-video-output.patch $work/Sources/BuildScripts/patch/libmpv/

# Turn the output on for every non-Mac platform the scripts build.
main=$work/Sources/BuildScripts/XCFrameworkBuild/main.swift
if ! grep -q vo-avfoundation $main; then
    perl -0pi -e 's/(            array.append\("-Daudiounit=enabled"\)\n)/$1            array.append("-Dvo-avfoundation=enabled")\n/' $main
fi
grep -q vo-avfoundation $main

(cd $work && make build platform=ios,isimulator)

built=$work/dist/release/xcframework/Libmpv.xcframework
for slice in ios-arm64 ios-arm64_x86_64-simulator; do
    nm -gU $built/$slice/Libmpv.framework/Libmpv | grep -q video_out_avfoundation
    cp $built/$slice/Libmpv.framework/Libmpv $here/Libmpv.xcframework/$slice/Libmpv.framework/Libmpv
done
echo "Libmpv.xcframework: iOS slices replaced from $work"
