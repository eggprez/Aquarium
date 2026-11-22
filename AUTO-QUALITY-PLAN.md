# Auto quality: one policy for every device

Written 2026-11-01. Both apps get the same behaviour, the same numbers and the same ladder. They still share no code: each keeps its own copy, and points back here.

## Where things stand

| | iPhone / iPad / Mac | Apple TV | Linux | Watch, Music |
|---|---|---|---|---|
| Auto exists | Yes, on by default (`Preferences.adaptiveQuality`) | **No.** `adaptsQuality` is hard-wired `false`; Settings shows one fixed rung | Yes, on by default (`isAdaptiveEnabled`) | No: fixed audio caps (Watch 320k, Music 384k on cellular only) |
| Opening rung | **Original**, unless the off-by-default Speed check is on, and that skips any server on the home network | The fixed rung from Settings | Speed probe on every fresh start, home included | n/a |
| Probe | 8 MB, stopped after 1.5 s, timed from the first byte (`measureThroughput`) | — | **Fixed 1 MB**, timed as a whole (`server.rs` `bitrate_test`). On a fast link this mostly measures the connection ramping up, so it reads low | — |
| Probe fails | Original | — | Original | — |
| Speed memory | Next episode only, 4 h, same interface type (`SpeedMemory`) | — | None. Autoplay inherits the last rung | — |
| Signals during playback | Stalls, stall length, dropped frames, buffer runway; observed throughput is read only to size a step down, and only with Speed check on | — | Stalls, stall length, dropped frames, buffer runway. Throughput not read | — |
| Step down | 2 stalls in 60 s, one 8 s stall, or 120 dropped frames in 20 s; one rung, or straight to the rung the speed fits (Speed check only) | — | Same rules; one rung, skipping rungs no lighter than the source | — |
| Step up | 5 min with ≥12 s buffered; one rung at a time, except Original rungs are skipped in one go | — | Same; always one rung | — |
| Failed climb | Ceiling pinned for the session | — | Same | — |
| Device limits | Heat and Low Power Mode cap the rung (`powerRung`) | — | None | — |
| Ladder | Original, 36 · 4K, 20 · 1440p, 16 · 1080p, 10 · 1080p, 5 · 720p, 2.5 · 480p, **with width/height caps** | Same ladder | Original, 35 · 4K, 18 · 1440p, 10 · 1080p, 5 · 720p, 2.5 · 480p, **no size caps** (so the server can send 1080p at 2.5 Mbps) | — |
| Slow server vs slow network | Can't tell | — | Can't tell | — |

What goes wrong as a result:

1. **Apple devices open at Original** and have to stall their way down. With the default settings that's every start.
2. **Linux reads the speed low** on fast links and opens too low, then waits 5 minutes for each rung up.
3. **The climb back is slow everywhere**: 5 minutes per rung, and one rung at a time on Linux.
4. **An overloaded transcoder looks like a bad network.** Auto drops a rung, the transcode restarts, and things get worse.
5. **The Apple TV has no Auto at all.** A fixed rung that's too high just stalls.
6. **The ladders differ**, and Linux's has no size caps.

## The shared policy

### The ladder (both apps)

Use the Apple ladder in both apps, with its size caps:

| Rung | Total cap | Max size |
|---|---|---|
| Original | — | — |
| 4K | 36 Mbps | 3840×2160 |
| 1440p | 20 Mbps | 2560×1440 |
| 1080p·16 | 16 Mbps | 1920×1080 |
| 1080p·10 | 10 Mbps | 1920×1080 |
| 720p | 5 Mbps | 1280×720 |
| 480p | 2.5 Mbps | 854×480 |

Linux has to add the width/height profile conditions that `DeviceProfile.build` already sends on Apple. Saved Linux bitrates (35, 18) are snapped up to the nearest rung, the way `Quality.snapped` does it.

### The opening rung

Used for any fresh start in Auto that nobody picked a quality for: not live TV, not a downloaded copy, not autoplay (that inherits the last rung, as now). The first answer that applies wins:

1. **Speed memory for this network.** Key: server + interface kind (Wi-Fi, Ethernet, cellular, other). Good for 2 hours. Each stream saves its final slow estimate (see below) when it ends, so most starts skip the probe.
2. **The probe.** Run it on every network, home included. It downloads up to 8 MB (2 MB on cellular) from `/Playback/BitrateTest`, stops after 1.5 s, times from the first byte to the last, and counts whole chunks. That is Apple's current method, which Linux switches to. Before trusting a low reading, take the higher of it and any memory older than 2 hours, since a slow first second is common.
3. **Neither available:** open at **1080p·10**, never Original.

Fitting the speed to a rung stays as it is in both apps today:
- Budget is 0.7 × speed.
- Original if the file's own bitrate fits the budget.
- Otherwise the best rung that fits, and 480p if none does.

The Apple **Speed check** setting goes away: in Auto it is always on. A fixed rung never probes.

### While playing

**Running estimate.** Keep two moving averages of download speed: a fast one (about a 3 s half-life) and a slow one (about 10 s). The estimate is the lower of the two. Feed it only real downloading, not an idle full buffer:
- AVPlayer: each new access-log event's `observedBitrate`.
- mpv: `cache-speed`, sampled only while the cache is below its read-ahead target.

The plumbing exists on Apple (`EngineStreamFacts.observedBitrate`). Linux needs `cache-speed` added to the observed properties in `player.rs` and to the `player-status` event.

**Step down** (rules unchanged, now on every device):
- 2 stalls in 60 s, or one stall of 8 s → step to the rung the estimate fits, at least one rung lower. Apple does this today only with Speed check on. Linux gets it new.
- 120 dropped frames in 20 s → one rung, ignoring the estimate (the device is the limit, not the network).
- **New, early drop:** for 20 s straight, the estimate is below the current rung's cap and the buffer is shrinking under 10 s → step down before the stall.

**Step up** (replaces the fixed 5 minutes):
- For 60 s straight, the buffer holds 12 s or more and 0.7 × the slow estimate covers the next better rung → climb straight to the best rung the estimate fits, up to the ceiling.
- At most one climb every 3 minutes, since each climb restarts the transcode.
- Keep the 90 s probation and the ceiling pin after a failed climb.
- If no estimate is available (Direct Play over a link that's never been measured), fall back to today's 5-minute rule.

Unchanged: the grace periods (15 s after opening, 45 s after our own switch, 90 s after a manual pick, 12 s after a seek), the step to the downloaded copy first, and the "lowest quality" notice.

### Slow server vs slow network

When a stall happens during a transcode, first ask the server how the encode is doing: `GET /Sessions?deviceId=<ours>`, then `TranscodingInfo.Framerate` and `CompletionPercentage`. Check these field names against 10.9 and 12.x before building on them.

- **Encoder slower than real time** (`Framerate` below the source's frame rate for 2 checks in a row): this is the server. Don't drop the rung. Instead:
  - try a cheaper transcode: no burned-in subtitles, or copy the video and convert only the audio, when the profile allows it;
  - if that isn't possible, try Original when the speed estimate covers the file;
  - otherwise show "The server can't convert this fast enough" once.
- **Encoder keeping up:** it's the network. Step down as above.

Poll only while stalling or while the buffer is shrinking during a transcode, at most every 10 s.

### Device limits

- **Apple:** keep the heat and Low Power Mode caps as they are.
- **Linux:** no equivalent in this plan. Reading battery state through UPower could come later.

### Apple TV

Give tvOS Auto using the same policy; mpv already supplies every signal it needs. The reason it was turned off was that the synced `adaptive` setting let the iPhone's Auto overrule the TV's chosen rung. The fix:
- Stop syncing `adaptive` through iCloud. Quality is already a per-device choice (`defaultBitrate` isn't synced).
- Add Auto to the top of the TV's Video › Quality list.
- Make Auto the default for new installs. Existing TVs keep their chosen rung.

### Out of scope

The Watch and Music use fixed audio caps of 320 kbps or less. At those rates there's nothing for Auto to adjust.

## Shared numbers

Each app keeps these as named constants, with a comment pointing here. Change them in both apps or in neither.

| Constant | Value |
|---|---|
| Headroom | 0.7 |
| Probe size, time limit | 8 MB (2 MB on cellular), 1.5 s |
| Memory lifetime | 2 h, per server + interface kind |
| No-measurement opening | 1080p·10 |
| Fast / slow half-life | 3 s / 10 s |
| Stall rule | 2 in 60 s, or one of 8 s |
| Drop rule | 120 frames in 20 s |
| Early drop | estimate under rung for 20 s and buffer < 10 s and falling |
| Climb | buffer ≥ 12 s and estimate covers next rung for 60 s; ≤ 1 climb / 3 min |
| Climb with no estimate | 5 min |
| Probation after climb | 90 s |
| Grace: open / own switch / manual / seek | 15 / 45 / 90 / 12 s |

## Phases

Each phase lands in both apps before the next one starts.

1. **Opening rung.**
   - Apple: Speed check always on in Auto (setting removed); no home-network skip; network memory replaces next-episode memory; fallback 1080p·10.
   - Linux: time-limited probe in `bitrate_test`; network memory; fallback 1080p·10; the shared ladder with size caps.
   - This phase fixes the most common complaint.
2. **Running estimate and estimate-based switching.** The two averages, a sized step down, the early drop and the faster climb. Linux gets `cache-speed`.
3. **Server vs network check** through `/Sessions`.
4. **Apple TV Auto**, plus un-syncing the `adaptive` setting.

## Testing

- **Unit tests:**
  - Apple: extend `AdaptiveQualityTests` with the estimate rules, the early drop, the climb and the 3-minute limit, plus the memory and fallback in the opening rung.
  - Linux: there's no TypeScript test runner. Either move the decision logic into a pure function and add `vitest`, or move it into Rust and use `cargo test`.
- **Throttled local server**, as in the download QA setup. Cap the link at 3, 8, 25 Mbps and unthrottled. For each, on iPhone, iPad, Mac, Apple TV and Linux, record:
  - time to first frame;
  - stalls in the first 5 minutes;
  - rung after 5 minutes;
  - switches per hour.
  - Also drop the cap from 25 to 3 Mbps mid-film, then raise it again.
- **Slow-encoder case:** force a software transcode with burned-in subtitles of a 4K HEVC source on a fast link. Auto must not step down; it should try the cheaper transcode.
- **Logging:** each app writes one line per decision: rung, reason, both averages, buffer, encoder speed. That way runs on different devices can be compared.
