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

> **Shipped 2026-10-16** on `player-overhaul` (uncommitted at the time of
> writing). `Player/Engine/PlaybackEngine.swift` (protocol, `EngineCapabilities`,
> `EngineEvent`, `EngineTrack`, `EngineLoadRequest`), `Engine/EnginePolicy.swift`
> (`EnginePolicy.choose` and the resolver's `StreamPlan.decide`, both pure),
> `Engine/AVEngine.swift` (the AVPlayer two thirds of the old model: install,
> observers, hand-over, composition, media selection, failure classification),
> `Engine/MPVEngine.swift` moved up from `TV/` and conforming, gated on
> `canImport(Libmpv)` with only `MPVVideoView` behind `canImport(UIKit)`;
> `Engine/DisplayMatch.swift` moved with it. One `PlayerModel` for all four
> platforms, split across `PlayerModel.swift` (state, engine wiring, the one
> event stream, transport, finish) and `+Session`, `+Events`, `+Tracks`,
> `+Extras`, `+PlaybackApple`, `+PlaybackTV`. `TVPlayerModel.swift` deleted
> (`DelayedVideoRenderer` turned out to exist only as references inside dead
> `#if os(tvOS)` blocks of the non-tvOS model; nothing to delete). `Player/
> TrackPreference.swift` holds `preferredStreams` as a pure function.
> `AdaptiveQuality.sample` takes engine signals instead of an `AVPlayerItem`.
> `AquariumTests` added to the project and the shared scheme, hosted by the
> app, with tests for `EnginePolicy.choose`, `TrackPreference.preferredStreams`,
> `StreamPlan.decide` and `DeviceProfile.canDirectPlay`.
>
> **Left for later phases.** The engine is still chosen by platform (AVEngine
> everywhere but tvOS, MPVEngine there): `EnginePolicy.choose` is written and
> tested but not consulted by the model until phase 4 links MPVKit for iOS and
> Mac, and `JellyfinClient.resolvePlayback` still picks the device profile by
> `#if os(tvOS)` rather than by engine (it should call `StreamPlan.decide`;
> Core was out of scope here). The two platforms keep their own `play` paths
> (`+PlaybackApple`, `+PlaybackTV`) and track-menu shapes (`PlayerTrack` lists
> vs `EngineTrack`), each lifted from its original so behaviour is unchanged;
> phases 4 and 5 fold them together. AVPlayer's `player` is reached by the
> AVKit surfaces and SharePlay as `(engine as? AVEngine)?.player` until phase 2
> replaces the surfaces. `AVFoundation` is still imported outside `Engine/` by
> `MusicPlayer`, `DeviceProfile`, `Downloads`, `WatchLink`, `WatchRemote` and
> `SyncMeasureView`, all pre-existing and out of this phase's scope; within the
> player it is only `AVAudioSession` (`+Session`, `+PlaybackTV`). The model's
> state setters are now module-internal rather than `private(set)` so the
> extension files can write them. The tvOS mpv engine is still reused for the
> life of the app rather than made per stream. The 2026-10-15 QA script's
> player section has not been re-run on the result.

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

> **Shipped 2026-10-16** on `player-overhaul` (uncommitted at the time of
> writing). `AVPlayerViewController` is gone from iOS and `Player/
> TransportBarExtras.swift` is deleted. `Player/Chrome/VideoSurface.swift`
> is a `UIView` (`VideoLayerHostView`) that gives its bounds to one `CALayer`,
> an `AVPlayerLayer` today and the mpv `CAMetalLayer` in phase 4;
> `Chrome/PictureInPicture.swift` runs `AVPictureInPictureController` over it
> with `canStartPictureInPictureAutomaticallyFromInline`, and AirPlay is an
> `AVRoutePickerView` in the title row. The shared chrome under
> `Player/Chrome/`: `PlayerChrome` (the state — visibility, panel, scrub,
> skip run, hold, edge level — and the composition), `PlayerTransport`
> (scrims with `TVTransportBar`'s stops, title row with dismiss / LIVE /
> AirPlay / PiP / `…`, centre cluster with the spinner in the play glyph's
> place, times with tap-to-toggle total, the pill row), `PlayerTimeline`
> (played in `Theme.accent`, buffered white 30 %, segments, chapter ticks,
> trickplay above the thumb, drag with a vertical pull-away that slows it,
> adjustable for VoiceOver), `PlayerPanel` (Info · Channels · Audio ·
> Subtitles · Quality · Speed · Sync, `.picture` reserved; sheet with medium
> and large detents on a phone, popover off the pill on an iPad; rows that
> cannot be honoured say why), `PlayerGestures` (tap, double-tap skip with
> ripple and the lifted `skipTotal`, pinch Fit/Fill, hold 2×, edge drags
> behind the Settings toggle), `PlayerOverlays` (the moment overlays, now
> structs the Mac window also uses), `PlayerChromeStyle` (`glassEffect` on
> 26, `.ultraThinMaterial` + `Theme.border` hairline before, `Theme.raised`
> at 85 % under Reduce Transparency; `PlayerMetrics` per platform) and
> `PlayerParts` (`PlayerTime`, `TrickplayStore` on ImageIO, `ChannelSchedule`,
> `InfoArtwork`, `SkipBadge`, `playerGlass`, lifted out of `TV/` for every
> platform; `PlayerTab` likewise). `PlayerModel+Chrome.swift` gives the
> non-tvOS model `currentChannel` / `channelLineup` / `playChannel`,
> `panelTabs`, `offersQuality` and the "why not" strings. Everything the old
> pills and gear menu offered is reachable: quality rungs (Quality tab and
> pill), the file's audio and subtitle tracks and the preferred languages
> (Audio and Subtitles tabs), sleep timer and stop-after-this (`…` menu and
> Info tab), resync and re-encode for sync (Sync tab, also `…` → Audio Sync),
> the queue (Up Next pill), Watch Together (`…`), Fill (pill and pinch),
> Stream Info (`…` → Info tab, which lists `PlayerStreamRows`, now compiled
> for iOS). Speed left AVKit's control for the Speed tab and the hold
> gesture; the audio offset is set from the Sync tab with the Mac popover's
> settle-then-rebuild, and `PlayerModel.audioDelay` is no longer pinned to
> zero on iOS. Settings → Video gained the Player group on iPhone and Mac
> (skip 10/15/30 s, hide after 2/4/6/10 s, show remaining, hold for 2×, edge
> drags), in `Preferences` and `CloudSync.syncedKeys`. Debug builds take
> `-AquariumPlayURL <url>` (and `-AquariumPlayTitle`, `-AquariumPlayPaused
> YES`) on every platform now, which is how the simulator screenshots in
> `qa-2026-10-16/player-phase-2/` were taken with no server to sign in to.
> iOS, macOS and tvOS build; `AquariumTests` (31) pass.
>
> **Left for later phases.** The Mac window still draws `AVPlayerView` and
> its own row (phase 3), tvOS its own bar and panel (phase 5); the chrome
> files are `#if !os(tvOS)` as whole files because the model still has two
> shapes (`isLocal`, `queue`, `chapters`, `bitrateNotice` exist only off
> tvOS), which is phase 4/5's fold, not a chrome `#if`. `PlayerTransport`'s
> AirPlay and `PlayerGestures`' brightness/volume setters are the only
> platform-split input mechanics. Landscape lock for a wide picture and
> portrait for a phone-shaped one is not done (`allowsLandscape` as before).
> Hover-to-show on a Mac waits for phase 3. The Picture tab exists but is
> never listed. The iOS 17 fallback branches compile and the material falls
> back by `#available`, but no iOS 17 simulator runtime is installed on this
> Mac (27.0 and 27.1 only), so it was not seen. PiP, AirPlay, swipe-home and
> background audio were not exercised: the iPhone simulator reports Picture
> in Picture as not possible (the iPad simulator shows the button), and
> background audio relies on `AVEngine`'s `continuesIfPossible` policy, which
> is unchanged. Edge drags, hold-for-2× and pinch were not driven by hand on
> a device. The 2026-10-15 QA script's player section has not been re-run.

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

> **Shipped 2026-10-16** on `player-overhaul` (uncommitted at the time of
> writing). `AVPlayerView` is gone: `Chrome/VideoSurface.swift` now has an
> `NSView` twin of the iOS host view (`VideoLayerHostView`, layer-backed,
> `hitTest` nil so every click and hover goes to the chrome, the layer given
> the window's backing scale for phase 4's Metal layer), and Fit / Fill is
> the `AVPlayerLayer`'s `videoGravity` as before. `PlayerScreen` is one body
> for iPhone, iPad and Mac — `VideoSurface` + `PlayerChrome` — with `#if`
> only around the status bar and orientation on iOS and the right-click menu
> and pointer adapter on macOS; the Mac's own overlay row (quality button,
> gear menu, hover state) and its `AVPlayerView` coordinator are deleted. The
> chrome is pointer-driven through a small adapter rather than a fork:
> `PlayerMacState.noteActivity` / `pointerLeft` is the clock (fed by
> `onContinuousHover`; the interval is Settings → Video → Hide controls
> after, the same row a phone reads), `PlayerChrome.showsControls` reads it
> in place of the chrome's own timer on macOS, and
> `PlayerChromeState.pointerOnControls` — set by `onHover` on the title row,
> cluster and bottom band — keeps the controls up while the pointer is on
> them; paused, a panel, a scrub and an error keep them up as on iOS.
> `Chrome/PlayerPointer.swift` carries the scroll wheel (vertical is volume,
> sideways is a scrub, left alone over the controls so the pill row can
> scroll); a double-click on the picture is full screen (`PlayerGestureLayer`,
> one `#if`), a single click only counts as pointer movement. The panel is
> the popover off the pill, as on iPad; `compact` on a Mac now means a
> window narrower than 640 pt (`PlayerMetrics.narrowWindow`) and picks the
> smaller glyphs and insets (a Mac set, a step under the iPad's at either
> size) while `usesSheet` stays false; the title row is inset 58 pt from the
> leading edge while the window's traffic lights are over the picture and
> not in full screen (`PlayerMacState.isFullScreen`, from the window's
> notifications). `PlayerMacMenus`: `PlayerMacState` lost `showsAudioDelay`
> and gained `panelRequest` / `togglePanelRequest` (the chrome opens the tab
> off its pill, or the "…" button for Info, Sync and Channels), a weak
> `pictureInPicture`, and `isFullScreen`; `PlayerMenuItems` gained a Speed
> submenu (picker, plus Slower/Faster as before) and every submenu ends in
> "Show … Panel"; Adjust Audio Delay… opens the Sync tab and
> `AudioDelayOverlay.swift` (the stepper popover) is deleted; the AVKit
> action-button `NSMenu` (`PlayerActionMenu`) is deleted, the right-click
> menu being the SwiftUI `PlayerContextMenu` over the same `PlayerMenuItems`,
> now with Picture in Picture and Enter / Exit Full Screen. The Playback menu
> gained Show Panel (⌘K), Picture in Picture (P) and the full-screen item's
> state; Space, arrows, [ ], ⌥[ ⌥] ⌥0, M, S, C, F, ⌘I, ⌘. are unchanged and
> act on the model. Picture in Picture is `AVPictureInPictureController` over
> the layer through the shared `PictureInPicture` class, which on macOS puts
> the window away on start (not in full screen) and brings it back on stop or
> on the floating window's return button — the delegate behaviour
> `AVPlayerView` had. `StreamInfoInspector` stays as ⌘I; the Info tab lists
> `PlayerStreamRows` as on iOS. The overlays lost their Mac-only material
> and dismiss glyph (the AVKit panel they matched is gone) and the styling
> helpers moved from `PlayerScreen` into `PlayerOverlays`. Every control
> keeps its VoiceOver label; the chrome's buttons are ordinary SwiftUI
> buttons, which Full Keyboard Access tabs through. `AVPlayerView`'s
> magnification and Live Text are not carried over, as decided. Debug builds
> also take `-AquariumPlayPanel <tab>` and `-AquariumPlayFullScreen YES`
> beside `-AquariumPlayURL`. The only AVKit left in the Mac player is
> `AVPictureInPictureController` (`Chrome/PictureInPicture.swift`) and
> `AVRoutePickerView` (`Chrome/PlayerTransport.swift`). iOS, macOS and tvOS
> build; `AquariumTests` pass.
>
> **Left for later phases.** The `qa-2026-10-16/player-phase-3/` screenshots were
> not taken: the Mac's screen was locked for the whole session, which
> refuses both screen control and `screencapture`; the four shots (chrome
> up, panel open, chrome hidden, full screen at 900×506) are one run of
> `qa-2026-10-16/player-phase-3/take-screenshots.sh` on an unlocked screen. Not seen running:
> Picture in Picture's window-away-and-back, AirPlay, the scroll-wheel
> scrub, a right-click on the picture, the Sync tab from the menu, and Tab
> through the chrome with Full Keyboard Access — all compile-checked only.
> The hide interval on a Mac is the Settings value (default 4 s) rather than
> the plan's 2 s, so the Settings row means what it says on both platforms;
> drop the default to 2 if the Mac wants it. The player window's title
> reads "Stream Info" in the Window menu (the inspector's `navigationTitle`
> wins over the window's; pre-existing). The chrome has no volume slider —
> ↑ / ↓, the scroll wheel and M are the Mac's volume — and no Fill via pinch
> was checked on a trackpad. The `Preferences.fillScreen` toggle in the
> menus now calls `applyFraming`, which the old AVKit path did not need.

`AVPlayerView` goes; the shared chrome runs pointer-driven in
`PlayerWindow`; `PlayerMacMenus` and `MacCommands` point at the model; PiP
through `AVPictureInPictureController`; the Stream Info inspector stays.

### Phase 4: mpv on iPhone, iPad and Mac (L)

> **Shipped 2026-10-16** on `player-overhaul` (uncommitted at the time of
> writing). The MPVKit product's `platformFilters` is `(ios, macos, tvos)` and
> `OTHER_LDFLAGS` links AVKit on every platform; the stub-stripping script
> phase is unchanged and runs on all three. `Engine/MPVEngine.swift` compiles
> everywhere: `MPVMetalLayer` sets `framebufferOnly`, `maximumDrawableCount = 2`
> and `presentsWithTransaction = false` itself, `MPVVideoView` has its
> `NSView` twin (layer-backed, the Metal layer as its backing layer, scale
> from the window), and on an iPhone or iPad the model's own `mpvLayer` is
> hosted by `VideoSurface`'s host view in the `AVPlayerLayer`'s slot (given
> the trait collection's scale on iOS). The handle is made per session by
> `PlayerModel.makeEngine(.mpv)` and destroyed in `finish` (`tearDownMPV`) on
> every platform, tvOS included; it is reused across the reopens of one
> session so a title reopened for a track or a quality still plays on until
> the new file is in. One event task per engine, since an `AsyncStream` ends
> with the task reading it, and `handle` ignores an engine that isn't the
> one playing. The battery profile is a real mpv profile: `[aquarium-battery]`
> (the plan's list, `profile-restore=copy`) and `[aquarium-quality]`
> (`video-sync=display-resample`) are written to Caches/mpv at launch and
> handed to the handle with `include`; `powerProfile` restores the one on
> and applies the other with `apply-profile`. `EnginePolicy.powerProfile`
> (tested) picks it: thermal `.serious`/`.critical` → battery everywhere,
> then the Battery saver setting, then Automatic = battery on iPhone and
> iPad, on a Mac on battery (IOKit `PowerSource`, with a run-loop source
> posting `PowerSource.changed`) or in Low Power Mode, quality on a Mac on
> mains and on Apple TV; `refreshPowerProfile` runs when an engine is made
> and on every power notification. `vid=no` on `didEnterBackground` and
> `vid=auto` on return on iOS (the sound carries on; only tvOS still pauses).
> `hwdec-current` is watched in `onDecoder`: `no` on an iPhone or iPad with a
> server item behind the stream reopens on AVEngine with `forceTranscode`,
> once per stream, logged; a download or a bare URL just logs it. Demuxer
> cache 64 MiB / 60 s on iPhone and iPad (`MPVEngine.Tuning.handheld`),
> 150 MiB / 20 s on Mac and Apple TV. ProMotion: `hintContentFrameRate` keeps
> a `CADisplayLink` with `preferredFrameRateRange` at the content's rate
> while mpv draws, invalidated at shutdown. `EnginePolicy.choose` is live:
> `PlayerModel+Engine.swift` builds the request (preference, picture,
> framing, audio delay, AV1, SharePlay, `engineOverride`) for an item, a
> download (`fileContainer` from the file name) or a bare URL (`isExternalFile`
> with the extension, so `.mkv` and `.ts` addresses go to mpv and `.m3u8`
> stays on AVPlayer), and `requiresApple` (PiP, AirPlay, SharePlay) beats the
> setting. `JellyfinClient.resolvePlayback` takes `engine:` and asks
> `StreamPlan.decide` with the engine's profile and `engineCanOpen`; the
> `#if os(tvOS)` there is gone. Prefetch resolves the next title with its own
> engine choice and is only taken if the choice still matches. Settings →
> Video gained Playback engine, Battery saver (Player group) and the Picture
> sliders, zoom, aspect and Reset (`PictureAdjustRows`, Picture group) on
> iPhone and Mac, in `Preferences` (`picture_*`, `player_engine`,
> `player_battery_saver`) and `CloudSync.syncedKeys`; the About row and the
> Mac About panel say which engine is playing (`engineDescription`). The
> Picture tab is in `panelTabs` everywhere the shared panel runs: sliders
> over the live picture on mpv, on AVEngine the note *Picture controls need
> the mpv engine — switch for this title?* with the `EngineSwitchRow`, which
> `switchEngine(to:reason:)` answers by reopening at the same position with
> the pause state kept and `engineOverride = .mpv` for the title. The Sync
> tab offers the same row on an HLS stream under AVEngine, and
> `setAudioDelay` switches instead of refusing. Subtitle styling on mpv is the
> existing `applySubtitleStyle` (`sub-scale`, `sub-color`, `sub-outline-*`,
> `sub-back-color`), applied to every engine as it becomes the one playing.
> Hand-over: the PiP button stays on mpv and calls
> `handOverForPictureInPicture`, which reopens on AVEngine and starts the
> picture through `PictureInPicture.startWhenPossible` as soon as the new
> layer plays; the AirPlay picker stays and its delegate hands over as the
> picker opens (`PlayerAirPlayDelegate`, both platforms; on a Mac the picker
> always has `appleEngine.player`); Watch Together calls `prepareForSharePlay`
> first, and `SharePlayCoordinator.adopt` does the same for a session joined
> from elsewhere. The reverse hand-over is in: `pictureInPictureEnded` reopens
> on mpv when the stream was handed over for the picture. The Info tab's
> "Playing" rows gained an Engine row with the decoder. README: *The mpv
> engine* replaces *The Apple TV player*, the four rows moved up to the
> features list, and the *What did not carry over* table keeps only the
> system and television rows. Tests: `EnginePolicyTests` covers the external
> file rule, `requiresApple`, the Mac default and `powerProfile`
> (38 tests pass). iOS, macOS and tvOS build. Seen on the iPhone 18 Pro
> simulator with `-AquariumPlayURL`: an MKV opens on mpv (`hwdec-current`
> reports `no` — the simulator has no VideoToolbox, and the log says *mpv is
> decoding in software and there is no server to ask for a transcode*), the
> same clip as MP4 opens on AVFoundation, the Picture tab's saturation slider
> changes the live picture under mpv, and the switch row reopens the MP4 on
> mpv at 3.4 s. Screenshots in `qa-2026-10-16/player-phase-4/`. Size, in
> the shape of the `app-size-levers` note (Release `build` for
> `generic/platform=iOS` and `macOS`, unsigned, so unstripped; the stripped
> column is `strip -x` on a copy and is what an archive ships): the iOS
> executable went from 33.5 MB to 67.2 MB raw and 11.6 MB to 40.8 MB
> stripped, +29 MB for one device slice; the Mac executable (universal,
> arm64 + x86_64) from 47.2 MB to 124.1 MB raw and 17.2 MB to 84.5 MB
> stripped, +67 MB, about +34 MB per architecture. Nothing else in either
> bundle changed (Assets.car is still 394 MB on iOS, the stub-stripping
> phase removed 27 empty frameworks on each), so the whole cost of mpv on a
> phone is the ~29 MB of static FFmpeg, libplacebo, MoltenVK, libass and
> mpv the linker kept; it is the same LGPL set tvOS already shipped.
>
> **Left for later phases.** The Mac's screen was locked for the whole
> session: the Mac run was checked from its log only and no Mac screenshots
> were taken. Not seen running: the PiP hand-over and its return (the iPhone
> simulator reports PiP as not possible, so the button on mpv would reopen on
> AVEngine and then wait), AirPlay's hand-over from the picker, Watch
> Together, background `vid=no`, the thermal and Mac-on-battery paths, the
> software-decode fallback on a server item, and the ProMotion hint — all
> compile-checked and unit-tested where pure, none on hardware. Phase 0's
> energy measurement has still not been run, so the thresholds are the plan's
> defaults. The Apple TV's own panel (`TVPlayerPanel`) has no Picture tab:
> the shared panel reaches tvOS in phase 5, and the tvOS Settings page has
> no engine or picture rows (Apple TV is always mpv). mpv logs `osc=no` and
> `ytdl=no` as unknown options on iOS and Mac (MPVKit builds without them
> there); harmless. A bare MPEG-TS address now opens on mpv rather than
> failing with the "raw MPEG-TS" card, which is a change of behaviour for
> IPTV not in the plan. The `[aquarium-quality]` profile only sets
> `video-sync`; the Linux app's cursor and OSD lines have no meaning here.
> Night mode has no control yet (the engine knob exists; no row calls it).
> Debug builds also take `-AquariumShowSettings YES` (Settings with no
> server, `RootView`), added for the Settings screenshots before it turned
> out that a signed Debug build reads the simulator's keychain session and
> an unsigned one (`CODE_SIGNING_ALLOWED=NO`) shows the login screen. Once,
> on the first open of Settings → Video after that install, the app went
> away with no crash report and nothing in its log; the second open and
> everything after worked, and it was not seen again — worth a look if it
> recurs.

The package product's platform filter opens up; `MPVVideoView` gets an
`NSView` twin; `EnginePolicy` goes live with the Phase 0 thresholds; the
battery profile, background `vid=no`, `hwdec-current` fallback and cache
sizes from above; the Picture tab; the Sync tab on any stream; hand-over to
AVPlayer for PiP, AirPlay and SharePlay. Archive sizes measured before and
after. The README's *What did not carry over* table shrinks to the rows that
are still true (brightness, zoom, night mode and MKV direct play move up to
the features list, with the note that they switch the engine).

### Phase 5: Apple TV on the shared chrome (M)

> **Shipped 2026-10-17** on `player-overhaul` (uncommitted at the time of
> writing). The model has one shape: `isLocal` (always false on the Apple
> TV, which has no downloads), `queue`, `chapters`, `bitrateNotice`,
> `externalChannel`, the live stall watchdog, the stream recoveries and the
> `PlayerTrack` lists exist on every platform, and `pictureIsStale` (the
> black cover over the last title's final frame) does too, cleared by the
> first frame or the first tick of playing. `PlayerModel+PlaybackApple` and
> `+PlaybackTV` are one `PlayerModel+Playback`: the Apple path as the base,
> with the Apple TV's pieces folded in — the display asked to match the
> film's frame rate before the file opens (`matchDisplay`, the one
> `#if os(tvOS)` of the play path, since only a television can switch), the
> opening and seek watchdogs that restart a stalled audio output (gated on
> `.restartsAudioOutput` rather than on the platform), `playSyncTest` (shared,
> waiting on the mpv layer being hosted rather than on a view of its own),
> the engine told to stop and the picture covered when a different title
> opens on an engine that would play on (`coverOutgoingPicture`), and the
> ended episode reported finished before the next starts. `awaitingLoad`
> now covers every non-hand-over open, and `isOpening` is true for every
> load (it was only for a resume), with `isPaused` set to what the load
> asked for, since mpv's pause flag doesn't change across a replace. The
> tvOS model's `videoView` is gone: `mpvLayer` is one `MPVMetalLayer` on
> every platform, hosted by `VideoSurface`'s `UIView` on tvOS as on iOS. One
> track shape (`+Tracks`): `PlayerTrack` lists from `EngineTrack` on either
> engine, `applyWantedTracks` putting on the server indices the stream was
> asked for by `fileIndex` (trusted on a transcode only from AVPlayer, whose
> numbering is the hints') before the language fallbacks, sidecar subtitles
> matched by URL and fetched through `addExternalSubtitle` on an engine with
> `.externalSubtitles`, and the audio offset per frame rate on tvOS
> (`audioDelayScope` says which) and one for everything elsewhere, with
> `audioDelayReach` from the engine. `DelayRate` is shared. The chrome files
> compile everywhere: `PlayerMetrics.television` picks the layout, and the
> `#if os(tvOS)` left are the finger drag and pointer hover (absent), the
> popover (absent), the menu pickers for the preferred language (no menu
> picker on tvOS; the rows are in Settings), the remote's hint line, the
> focus-driven tab strip and the error card's focus. `PlayerTransport` on a
> television is the old band: heading (kicker, LIVE, Paused, title) above
> the 12-point timeline inside the 90-point gutters, the gradient reaching
> 180 points above it, the hint line under; no centre cluster and no pill
> row — the remote's clicks and the swipe-down panel are those — and only
> the timeline while the panel is down. `PlayerTimeline` draws the ringed
> knob while scrubbing, the return-point mark, and the 400-point preview.
> `PlayerPanel` on a television is the swipe-down card (`TelevisionPanelBody`:
> the focus logic of the old `TVPlayerPanel`, Menu from a card back to its
> tab, from the tabs away, the swipe up from the tabs via
> `PlayerChromeState.panelTabsFocused`), its rows cards in `PanelRows`
> (sideways, or sharing the width for Quality and Speed), the Info tab in
> columns with the stream in one line and the sleep timer as cards, the
> Picture tab's sliders as steppers (`PanelSlider`, since tvOS has no slider
> a remote can drive) in two columns with the aspect ratios as a row of
> cards. Every card, tab, step and overlay button has `PlayerFocusStyle`:
> the accent behind it and its shadow under it, lifted 6 % unless Reduce
> Motion, never the system's platter; the labels read `isFocused`.
> `PlayerOverlays` on a television: the Up Next card with the still and
> "Click to play now · Menu to stop here", the skip pill drawn as the
> focused thing it stands for, the error card taking focus on its buttons.
> `TV/TVPlayerScreen.swift` is `PlayerRemoteDriver`, a modifier the chrome
> applies on tvOS: `RemoteInput` behind the chrome, the exit and play/pause
> commands on it, and the old state machine (edge clicks counting into
> `chrome.countSkip`, the paused swipe scrub into `chrome.scrub`, the return
> point into `chrome.returnPoint`, Menu stepping back, the channel edges,
> the swipe-down panel). `TVTransportBar`, `TVPlayerPanel` and
> `TVPlayerParts` are deleted; `RemoteInput`, `RemoteDebugHook`,
> `SyncCodeOverlay` (drawn by the shared `PlayerScreen` on tvOS), the sync
> clips and `DisplayMatch` are as they were. The Info tab's "Playing" rows
> gained a Display row on tvOS. Settings → Video on the Apple TV gained
> Brightness, Contrast, Saturation, Gamma (−100…100 in tens, plus the value
> set), Zoom (1…2 in tenths), Aspect ratio and Reset picture, applied live;
> no engine row and no Battery saver there. `NowPlaying` lost its tvOS
> branch. iOS, macOS and tvOS build; `AquariumTests` (38) pass. Driven on the
> Apple TV 4K simulator with `-AquariumPlayURL` on the bipbop HLS stream,
> through the remote debug hook and a UI-test runner pressing real buttons
> (`XCUIRemote`, the memory note's probe): bar up on an edge click with the
> running "+30 s" total, the bar hiding after the interval, paused swipe
> scrub with the knob and time pill, click to jump with the return-point
> mark and "Menu to go back to 0:58", Menu going back there (position
> 58.8 in the log), swipe down opening Info with the Info tab focused,
> Right moving the focus and the tab to Audio, Down into the cards and Up
> back to the tab, Menu from a card back to its tab and from the tabs away,
> the Picture tab's "+" on gamma lifting the live picture to +20 (and
> Settings → Video then reading Gamma +20), the Sync tab's −5 stepping, the
> 24 fps sync clip playing through the shared screen with its QR code and a
> press down opening the panel on Sync with "24 fps delay · 23.976 fps".
> Screenshots in `qa-2026-10-17/player-phase-5/`.
>
> **Left for later phases.** The scrub thumbnail was not seen: a bare URL
> has no trickplay, and the simulator is signed in to no server, so only
> the time pill rode above the knob; the trickplay code is the shared
> `TrickplayStore` phase 2 lifted from tvOS, unchanged. The display match
> did nothing on the simulator (no `AVDisplayManager` criteria matching
> there), so Match Frame Rate is compile-checked and its call sites moved,
> not seen switching. Live TV on the Apple TV — the channel edge clicks, the
> Channels tab, the live timeline — was not driven (no server); the paths
> are the shared ones iOS ran in phase 2. Not seen: an episode's Up Next
> card and Skip intro on tvOS (no server item), the Audio and Subtitles
> cards actually reopening a stream, a sidecar subtitle. The remote reaches
> the panel's rows and tabs only; there is no pill row or title-row button
> on a television by design, so "focus order across the title row and the
> pills" is the panel's tabs and cards. From the Picture tab, Down lands on
> whichever stepper the focus engine finds nearest the tab (Gamma's −, under
> the Picture tab), not Brightness. The hide interval on tvOS is now the
> Settings value (4 s default; it was 5 s), and the skip is the Settings skip
> interval (10 s default; it was fixed at 10). The tvOS panel has no
> language pickers (Settings has the rows). `isOpening` being true for every
> load is a change for iOS too: the loading card and `maybeReport` now wait
> for the first frame on a from-the-top open as they did for a resume.
> `adaptiveQuality` is now consulted on the Apple TV as on iOS (it defaults
> on; the tvOS Settings page has no toggle for it, and mpv's variant events
> only come on HLS). The QR code of a sync clip sits under the panel's
> right end while the panel is down, as the old panel also covered it.

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
