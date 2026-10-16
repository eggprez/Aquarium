# Player overhaul: one player for iPhone, iPad, Mac and Apple TV

Written 2026-10-16. A plan, not a record: nothing below has shipped. Paths are
relative to `Aquarium/`.

## Why

The Apple app has two players and neither is the one we want.

- **iPhone and iPad** play through `AVPlayerViewController`. Its transport is
  Apple's and cannot be changed, so every control of our own (quality, sleep
  timer, autoplay, fill, resync, languages, tracks, the queue) is a pill
  planted inside AVKit's private view tree by `Player/TransportBarExtras.swift`
  (631 lines of finding a view by class name and hanging subviews off it) or,
  when that fails, floated over a corner. Picture controls do not exist.
  Audio delay is an `AVMutableComposition` rebuild and only reaches direct
  play. Matroska is remuxed by the server; PGS and ASS subtitles cost a full
  video re-encode on the server because AVFoundation cannot draw them.
- **Mac** plays through `AVPlayerView` with its floating panel, plus a row of
  our own buttons that has to guess where the panel is.
- **Apple TV** already has the player we want underneath: libmpv (MPVKit),
  the original file direct, VideoToolbox decode, controls drawn entirely by
  us (`Player/TV/`). But it is a second `PlayerModel` (1,652 lines) that
  re-implements the Jellyfin half of the first one (4,626 lines): progress
  reports, track memory, segments, Up Next, sleep timer. The two have already
  drifted (the queue and prefetch exist only on the AVPlayer side).

The goal is one player: one Jellyfin-side model, one set of controls styled
per platform, and engines that can be swapped behind a protocol, chosen per
stream for the best picture at the least power.

## Where the battery actually goes

This decides the engine policy, so it comes first.

- AVPlayer is the floor. Hardware decode, frames handed straight to the
  system compositor, no shader pass, the audio unit shared with the system.
  Nothing we write beats it on a file it can play.
- mpv on Apple hardware decodes through VideoToolbox too (`hwdec=videotoolbox`,
  zero-copy into Vulkan via MoltenVK, which the tvOS engine already does),
  but then draws every frame through libplacebo's shader chain into a
  `CAMetalLayer`. With mpv's defaults that chain is spline scaling, dithering,
  debanding and 16-bit float intermediates at the panel's full size. The
  Linux app measured this and ships an `[aquarium-battery]` profile
  (`Linux/src-tauri/mpv-config/mpv.conf`) that turns it all off; on a phone
  it is on by default from day one.
- A server remux is free on the device. An MKV with H.264 or HEVC and AAC,
  AC-3 or E-AC-3 arrives as HLS with the same bitstream; AVPlayer decodes it
  in hardware. Direct-playing the same MKV in mpv saves the server a remux
  and costs the phone a shader pass. So "direct play everything" is the
  wrong default for battery, which is the opposite of what the Apple TV (on
  mains, with a hot GPU to spare) wants.
- Software decode on the device is the worst case by far: VP9, and AV1 on
  anything before A17 Pro / M3. Those go to the server to transcode, in
  either engine.
- Where mpv wins outright: PGS and ASS subtitles (the alternative is the
  server burning them in, a full re-encode and a quality loss), DTS and TrueHD
  (mpv decodes to PCM; AVFoundation makes the server re-encode the audio),
  picture adjustments, zoom and aspect override, exact audio delay on any
  stream including HLS and live, and night-mode dynamic range compression.
  None of those is cheaper than AVPlayer; they are things AVPlayer cannot do.

Hence the policy: **AVPlayer by default on iPhone, iPad and Mac; mpv when the
file or the viewer asks for something AVPlayer cannot give; mpv always on
Apple TV.** Measured, not assumed: phase 0 below is the measurement.

## Architecture

```
PlayerScreen (SwiftUI, shared chrome; #if only around input: touch, pointer, remote)
  ├─ VideoSurface            platform view hosting AVPlayerLayer or MPVMetalLayer
  ├─ PlayerTransport         scrim, title, centre cluster, timeline, times, pills
  ├─ PlayerPanel             Info · Channels · Audio · Subtitles · Quality · Speed · Sync · Picture
  └─ Moment overlays         Skip intro / Skip credits, Up Next, bitrate notice, errors

PlayerModel (one class, all platforms: the Jellyfin side)
  stream request, track preference and per-series memory, progress reports,
  media segments, Up Next / autoplay / queue / prefetch, shuffle, sleep timer,
  Now Playing, Live TV recovery, audio session and route, Handoff, widgets

PlaybackEngine (protocol)                 EngineCapabilities (what to offer honestly)
  ├─ AVEngine    AVPlayer + AVPlayerLayer   PiP, AirPlay, SharePlay, background audio
  └─ MPVEngine   libmpv + CAMetalLayer      direct containers, picture, zoom, delay on
                 (today's Player/TV/MPVEngine.swift, lifted off tvOS)   any stream
```

### The protocol

What the model and the chrome need from an engine, and nothing AVFoundation-
or mpv-shaped:

- `load(url, headers, startAt, audio:, subtitle:, paused:)`, `stop()`
- `play()`, `pause()`, `seek(to:)`, `seek(by:)`, `rate`
- `selectAudio(streamIndex)`, `selectSubtitle(streamIndex?)`,
  `addExternalSubtitle(url, language, title)`
- `audioDelay`, `subtitleStyle`, `framing` (fit / fill / zoom / aspect),
  `picture` (brightness, contrast, saturation, gamma), `nightMode`
- `powerProfile` (`.quality` / `.battery`), `pictureDecode` on/off (the
  background-audio case)
- Events, one `AsyncStream<EngineEvent>`: position, duration, buffering,
  seeking, cachedUntil, tracks, videoSize, frameRate, decoder, dropped frames,
  variant change, fileLoaded, firstFrame, ended(reason), error
- `capabilities: EngineCapabilities` — an option set the chrome reads before
  it draws a button: `.pictureInPicture`, `.airPlay`, `.sharePlay`,
  `.audioDelayOnAnyStream`, `.pictureAdjust`, `.zoom`, `.externalSubtitles`,
  `.nightMode`, `.directContainers([...])`

`MPVEngine` already has most of this surface (`Player/TV/MPVEngine.swift:80`);
`AVEngine` is the AVPlayer-specific two thirds of `Player/PlayerModel.swift`
(install item, observers, hand-over between variants, escalation to
transcode, composition for audio delay, media selection) moved behind the
protocol with the Jellyfin reasoning left in the model.

### Choosing the engine

`EnginePolicy.choose(source:, options:, prefs:) -> Engine` is a pure function
with a unit test, consulted when a stream is requested and again when the
viewer changes something that only the other engine can do:

1. Apple TV: mpv.
2. Setting *Playback engine* = Apple or mpv: that one, always.
3. Automatic (the default):
   - mpv if the chosen subtitle track is PGS, VOBSUB or ASS, or the chosen
     audio is DTS or TrueHD, **and** the video codec is one VideoToolbox
     decodes on this device (H.264, HEVC, ProRes; AV1 on A17 Pro / M3 and
     later). Otherwise the server would transcode the video anyway and
     AVPlayer should take it.
   - mpv if any picture adjustment, zoom or aspect override is in force, or
     the viewer has set an audio delay on an HLS stream.
   - mpv if the item is a download whose container AVFoundation will not
     open from disk (MKV) — this is the one case where there is no server to
     remux.
   - AVPlayer otherwise, including every Live TV and IPTV channel (HLS, long
     sessions, where the system pipeline's idle power is the whole story).
4. Picture in Picture, AirPlay or SharePlay requested on an mpv stream:
   hand over to AVPlayer at the same position through the HLS stream the
   server can make. The model already has a hand-over-without-losing-the-
   picture path (`handOver` in `PlayerModel.swift:1799`); this reuses it with
   the engine as the thing being swapped. The reverse hand-over (back to mpv
   when PiP ends) is phase 4's last item and can slip.

The About row that says `Playback engine: AVFoundation` (`Views/SettingsView.swift:1588`)
starts saying which one is playing.

### The mpv engine on a battery

Everything the tvOS engine sets stays; these are added for iPhone, iPad and
Mac, as mpv profiles the model switches with `apply-profile` /
`profile-restore=copy` exactly as the Linux app does:

- `[aquarium-battery]`: `scale=bilinear cscale=bilinear dscale=bilinear
  dither=no deband=no correct-downscaling=no linear-downscaling=no
  sigmoid-upscaling=no hdr-compute-peak=no fbo-format=rgba8
  interpolation=no video-sync=audio`. On by default on iPhone and iPad; on
  a Mac on battery or in Low Power Mode; always under thermal pressure (the
  `AdaptiveQuality` power observer, `Player/AdaptiveQuality.swift`, already
  knows all three states).
- `[aquarium-quality]` is mpv's defaults plus `video-sync=display-resample`
  on a Mac on mains and on Apple TV, where it is today.
- Background: `vid=no` on `didEnterBackground`, `vid=auto` on return —
  decode and draw stop, the sound carries on through the audio session,
  which is what AVPlayer's `continuesIfPossible` policy does for free today.
- `hwdec-current` is watched: if it ever reports software decode on iPhone
  or iPad, the model reopens on AVPlayer with the server transcoding, and
  logs why. Software decode of a 4K HEVC on a phone is a hand-warmer.
- Demuxer cache: `demuxer-readahead-secs=60`, `demuxer-max-bytes=64MiB` on
  iPhone (150 MiB on tvOS stays). Bigger, less frequent reads let the radio
  sleep between bursts; the memory ceiling is the phone's.
- The handle is created per stream and destroyed at stop, as tvOS does
  (`makeEngine`, `TVPlayerModel.swift:183`): nothing of mpv runs while the
  app browses.
- `CAMetalLayer.presentsWithTransaction=false`, `framebufferOnly=true`
  (already), `maximumDrawableCount=2`. ProMotion: the layer's
  `preferredFrameRateRange` matched to the content's frame rate so a 24 fps
  film does not hold the panel at 120 Hz.

### App size and licence

MPVKit's iOS static archives are 135 MB on disk (unstripped, both LGPL and
GPL variants present); the linker keeps what is referenced. The tvOS build
already ships the LGPL set and is the reference for what that costs after
thinning. Phase 4 measures the iOS and Mac archives before and after and
records the number in the `app-size-levers` note. The app is MIT and
MPVKit's LGPL build is what tvOS ships today, so nothing changes on the
licence side; the pbxproj's `platformFilters = (tvos, )` on the package
product becomes all three platforms.

## The controls

Apple's grammar, this app's palette, one layout that adapts rather than
three layouts.

**Layers, bottom to top:** the picture; a scrim (top and bottom gradients,
the tvOS bar's `TVTransportBar` gradient reused, never a full dim); the
chrome; moment overlays (Skip intro, Up Next) which come and go with their
moment, not with the chrome, as they do today.

**Chrome, iPhone and iPad (also the Mac window, pointer-driven):**

- Top row: dismiss (`chevron.down`, a Mac uses the window), title with the
  episode line under it in `Theme.textDim`, LIVE badge in `Theme.danger`,
  then AirPlay (`AVRoutePickerView`), Picture in Picture, and a `…` menu for
  the rare things (Stream Info, Watch Together, Report sync).
- Centre: back 10 · play/pause · forward 10, large, the Apple TV app's
  weights. Buffering replaces the play glyph with the spinner; nothing else
  moves.
- Bottom: the timeline with the played portion in `Theme.accent`, the
  buffered portion in white at 30 %, a trickplay thumbnail riding above the
  thumb while scrubbing (the tvOS `TrickplayStore` reused), chapter ticks,
  elapsed and remaining either side (tap remaining to toggle total). Under
  it a row of pills: **Audio & Subtitles**, **Speed**, **Quality** (showing
  the rung), **Up Next** (queue count), **Fill**. Pills open the panel on
  that tab.
- Material: `glassEffect` on iOS 26 / macOS 26 and later, `.ultraThinMaterial`
  with a hairline `Theme.border` under them (the deployment targets stay at
  iOS 17 / macOS 14). Reduce Transparency gets a solid `Theme.raised` at
  85 %. Reduce Motion drops the ripples and cross-fades instead.
- Gestures: tap toggles the chrome; double-tap left or right skips with the
  TV app's ripple and a running total (the tvOS `skipTotal` logic reused);
  drag on the timeline scrubs, with a vertical pull-away that slows the
  scrub (the Music app's fine scrub); pinch toggles Fit / Fill; long-press
  holds 2× and lets go to the previous speed. A left-edge vertical drag for
  brightness (`UIScreen.main.brightness`) and right-edge for volume
  (`MPVolumeView` slider) are off by default and a Settings toggle, because
  they fight the system's edge gestures on some devices.
- Idle: the chrome hides after 4 s while playing, never while paused or
  while a panel is open. Hover keeps it on a Mac.
- Landscape lock on iPhone when the picture is wider than tall, portrait
  allowed for a phone-shaped video (`Core/Orientation.swift` has the hooks).

**The panel** is one `PlayerPanel` view with the tvOS tabs plus **Picture**:
a sheet with medium and large detents on iPhone, a popover anchored to the
pill on iPad and Mac, the swipe-down panel on Apple TV. Each row says why it
is disabled rather than vanishing: *Picture controls need the mpv engine —
switch for this title?* with a button that does so (hand-over, same
position). The Sync tab is the tvOS one, now everywhere; the measured-by-
iPhone flow stays as it is.

**Mac:** the same chrome in the player window, driven by the pointer: it
fades in on movement and out after 2 s; the `PlayerMacMenus` shortcuts and
the Playback menu keep working against the model, not AVKit; full screen is
the window's; Picture in Picture through `AVPictureInPictureController`
(AppKit has it over an `AVPlayerLayer` since 10.15). `AVPlayerView`'s
magnification and Live Text go; nobody asked for them.

**Apple TV:** keeps `RemoteInput`, the swipe-to-scrub and the edge clicks;
its bar, panel, choice cards and badges become the shared components with
the tvOS metrics (`.padding(.horizontal, 90)` etc. become a platform
metric set), so a change to the Audio tab is one change.

**Subtitles** are drawn by the engine, styled from the one pair of
preferences that exist (`subtitleSize`, `subtitleBackground`): `AVTextStyleRule`
on AVPlayer, `sub-font-size`, `sub-color`, `sub-border-*` and `sub-back-color`
on mpv. The tvOS *raise subtitles above the bar* becomes a shared behaviour.

**Accessibility:** every control has a VoiceOver label and value (the
timeline reports position and is adjustable), titles follow Dynamic Type
up to accessibility sizes, the chrome stays visible while VoiceOver is
running.

**Settings → Playback gains a Player group:** engine (Automatic / Apple /
mpv, with one line each on what that costs), skip interval (10 / 15 / 30 s),
edge gestures, hold-for-2×, hide controls after, show remaining time, battery
saver (Automatic / Always / Never) and the picture sliders with a Reset.
Everything travels over iCloud like the rest of `Preferences`.

## Phases

Each phase ships on its own and leaves the app working. Sizes are relative
(S: a session, M: a few, L: many).

### Phase 0: measure (S)

Before any engine policy is written down as fact. On the physical iPhone
(the simulators cannot report energy) and the Mac:

- A 20-minute HEVC 1080p MKV with E-AC-3 and a PGS track, played four ways:
  today's AVKit player over a server remux; mpv direct with defaults; mpv
  direct with `[aquarium-battery]`; AVKit over a server burn-in transcode.
- iPhone: `xcrun xctrace record --template 'Energy Log'` with the screen at
  a fixed brightness; Mac: `powermetrics --samplers cpu_power,gpu_power`.
- Written up in `qa-<date>/player-energy.md` with the numbers that set the
  thresholds in `EnginePolicy`. If mpv-with-battery-profile lands within
  ~10 % of AVPlayer on the iPhone, Automatic can favour direct play more
  often; if not, the policy above stands.

### Phase 1: the engine seam (L)

No visible change. `Player/Engine/PlaybackEngine.swift`, `AVEngine.swift`
(the AVPlayer two thirds of `PlayerModel.swift` moved out), `MPVEngine.swift`
moved up from `TV/` with its `#if os(tvOS)` narrowed to the UIKit view
class, and one `PlayerModel` built from the two by taking the AVPlayer
model's Jellyfin side (it is the superset: queue, prefetch, shuffle, live
recovery) and the tvOS model's engine-event handling. `TVPlayerModel.swift`
is deleted at the end of this phase, with tvOS running on the shared model.

A unit-test target, `AquariumTests`, for the parts that are pure: engine
policy, track preference resolution (`preferredStreams`), the stream
resolver's choice of direct/remux/transcode, `StartMeta`/`StreamOptions`
handling. The player has no tests today; this refactor is where they pay.

Done when: all three platforms build, the 2026-10-15 QA script's player
section passes on each, and the only `AVFoundation` import outside
`Engine/` is for `AVRoutePickerView`, `AVPictureInPictureController`,
`AVAudioSession` and the SharePlay coordinator.

### Phase 2: the iPhone and iPad chrome (L)

`VideoSurface` becomes a `UIView` hosting an `AVPlayerLayer` (or the mpv
layer, phase 4), `AVPlayerViewController` goes, `TransportBarExtras.swift`
is deleted, and `PlayerTransport`, `PlayerPanel`, `Timeline` (with
trickplay) and the moment overlays are built as shared SwiftUI. PiP through
`AVPictureInPictureController` with `canStartPictureInPictureAutomaticallyFromInline`;
AirPlay through `AVRoutePickerView`; speed moves from AVKit's control into
the Speed tab. The audio-delay menu becomes the Sync tab.

Done when: everything the pills and the `…` menu did is reachable, PiP and
AirPlay work from the new buttons and from swiping home, background audio
still drops the picture and keeps the sound, VoiceOver can run the whole
player, iOS 17 looks right without glass.

### Phase 3: the Mac window (M)

`AVPlayerView` goes; the shared chrome runs pointer-driven in
`PlayerWindow`; `PlayerMacMenus` and `MacCommands` point at the model; PiP
through `AVPictureInPictureController`; the Stream Info inspector stays.

### Phase 4: mpv on iPhone, iPad and Mac (L)

The package product's platform filter opens up; `MPVVideoView` gets an
`NSView` twin; `EnginePolicy` goes live with the Phase 0 thresholds; the
battery profile, background `vid=no`, `hwdec-current` fallback and cache
sizes from above; the Picture tab; the Sync tab on any stream; hand-over to
AVPlayer for PiP, AirPlay and SharePlay. Archive sizes measured before and
after. The README's *What did not carry over* table shrinks to the rows that
are still true (brightness, zoom, night mode and MKV direct play move up to
the features list, with the note that they switch the engine).

### Phase 5: Apple TV on the shared chrome (M)

`TVPlayerScreen` keeps its input layer; `TVTransportBar`, `TVPlayerPanel`
and `TVPlayerParts` are replaced by the shared components with tvOS
metrics. The sync test clips and `DisplayMatch` are untouched.

### Phase 6: polish and the QA pass (M)

Reduce Motion / Transparency, Dynamic Type at accessibility sizes, the
iPad's split-view and Stage Manager sizes, a Mac window at 480×270, the
energy numbers re-taken against Phase 0, and a multi-device pass like
`qa-2026-10-15/`. README and `PRIVACY.md` (nothing new is collected) checked.

## Decisions taken here, open to reversal

- **AVPlayer stays the default on battery-powered devices.** The alternative
  (mpv everywhere, as on tvOS and Linux) is simpler — one engine — and it
  is what "replace the player" most literally means. It costs PiP, AirPlay
  video and SharePlay unless each is re-done by hand-over, and it is never
  cheaper on the battery. Two engines behind one protocol is more code but
  it is the only version where "as battery efficient as possible" and
  "every mpv knob" are both true.
- **Not an FFmpeg + VideoToolbox + `AVSampleBufferDisplayLayer` pipeline of
  our own** (the Infuse shape: demux in FFmpeg, decode and present through
  the system, PiP and background for free). It is the theoretical best of
  both and a year of work: audio decode and A/V sync, seeking, PGS and
  libass rendering, HDR passthrough, every edge case mpv has already met.
  Not for a personal project; noted so nobody re-derives it.
- **Deployment targets stay** at iOS 17 / macOS 14 / tvOS 17, so the glass
  is conditional. Raising them to 26 would delete the fallback branches and
  little else.
- **SharePlay stays an AVPlayer-only feature.** "Watch Together" forces the
  Apple engine for that session rather than teaching mpv to follow an
  `AVDelegatingPlaybackCoordinator`. Can be revisited after phase 4.
- **`DelayedVideoRenderer`** (the held-back picture for HLS audio delay) was
  written for AVPlayer on tvOS, which no longer exists; with mpv taking
  every HLS-delay case it is deleted in phase 1.
- **The Linux app is untouched.** Its player is already what phase 4 brings
  across; the battery profile is copied from it, not shared with it.
