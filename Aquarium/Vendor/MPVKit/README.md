# MPVKit, vendored

[MPVKit](https://github.com/mpvkit/MPVKit) 1.0.0, LGPL product only, with one
library changed: `Libmpv.xcframework` is checked in here, and its iPhone and
iPad slices (`ios-arm64`, `ios-arm64_x86_64-simulator`) are rebuilt with
`patch/0004-avfoundation-video-output.patch`. Every other library, and every
other Libmpv slice, is the 1.0.0 release's; `Package.swift` fetches them by
URL and checksum as MPVKit's own manifest does.

## Why

Picture in Picture shows only an `AVPlayerLayer` or an
`AVSampleBufferDisplayLayer`. mpv normally draws through Vulkan into a
`CAMetalLayer`, so on mpv the app had to reopen the stream on AVPlayer to
float it. The patch adds `vo=avfoundation`, which hands VideoToolbox frames
(or software frames copied into pixel buffers) to an
`AVSampleBufferDisplayLayer`, with subtitles composited into each frame
(`--avfoundation-composite-osd`). `MPVEngine` draws into that layer on iOS
by default and switches to gpu-next on the running stream when a shader is
needed.

## The patch

`video/out/vo_avfoundation.m` is from
[streamyfin/MPVKit](https://github.com/streamyfin/MPVKit) (Alex Kim), under
the LGPL 2.1+ header mpv's own files carry. That fork ships only GPL
binaries for mpv 0.40, so it isn't used directly. Changes here:

- rebased onto mpv 0.41.0 (the driver is listed after gpu-next and gpu, so
  it is never picked unless asked for);
- subtitle compositing renders at no more than 1080 lines rather than the
  screen's native height (~2900 on a Pro Max), which made every subtitled
  frame a 4K half-float render.

## Rebuilding

```
./build-libmpv.sh
```

Clones MPVKit 1.0.0, adds the patch and `-Dvo-avfoundation=enabled`, builds
the two iOS slices (about an hour) and copies them in. Moving to a newer
MPVKit means changing `tag` in the script, re-copying its `Package.swift`
binary targets and the other Libmpv slices, and checking the patch still
applies.
