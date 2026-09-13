/**
 * Adaptive quality: move the stream down a rung when the connection or the
 * machine stops keeping up, and back up when it recovers.
 *
 * The player already had every part of this except the decision. mpv reports
 * when it stalls for cache and how many frames it has thrown away; the backend
 * forwards both; `switchQuality` restarts the stream at another bitrate from
 * the same position. All that was missing was something watching, so a stream
 * that couldn't hold 35 Mbps just stuttered until the user opened the menu and
 * guessed. This is that watcher.
 *
 * It only ever reacts to what has already gone wrong — there's no probing and
 * no prediction. Two rules move it down (repeated stalls, or a long one; and
 * frames being dropped, which buffering can't fix), one rule moves it back up
 * (a long clean stretch with a healthy read-ahead), and a rung that failed on
 * the way up is never tried again for the rest of the session.
 */
import { listen } from "@tauri-apps/api/event";
import { toast } from "./ui";
import {
  getQualityState,
  isAdaptiveEnabled,
  QUALITY_CHOICES,
  switchQuality,
} from "./playback";

// QUALITY_CHOICES runs best-first: index 0 is Direct Play, the last entry is
// the smallest stream on offer. "Down" is therefore towards a higher index.
const LOWEST = QUALITY_CHOICES.length - 1;

/** Stalls this close together mean the stream, not a blip. */
const STALL_WINDOW = 60_000;
const STALLS_TO_DROP = 2;
/** One stall this long is damning on its own — nobody waits it out twice. */
const LONG_STALL = 8_000;
/** Every stream buffers as it opens; that isn't evidence of anything. */
const STARTUP_GRACE = 15_000;
/** After a switch of our own, say nothing until the new stream has settled. */
const SWITCH_COOLDOWN = 45_000;
/** A seek empties the cache, so the stall that follows is our own doing. */
const SEEK_GRACE = 12_000;
/** Position running this far ahead of the clock between two status ticks is a
 *  jump, whoever made it (mpv's own keys and the uosc overlay seek without
 *  telling the frontend). Measured against elapsed time rather than as a bare
 *  delta: a stalled stream stands still while the clock moves, and that must
 *  not read as a seek — it's the very thing being watched for. */
const SEEK_JUMP = 5;
/** Dropped frames are counted per window rather than in total: a handful over
 *  an hour is normal, the same number in twenty seconds is a slideshow. */
const DROP_WINDOW = 20_000;
const DROPS_TO_DROP = 120;
/** Read-ahead that counts as comfortable, in seconds of video. */
const HEALTHY_RUNWAY = 12;
/** How long it has to stay comfortable before trying a better rung. */
const UPSHIFT_AFTER = 5 * 60_000;
/** A stall this soon after moving up means the rung is out of reach. */
const UPSHIFT_PROBATION = 90_000;

/** Best rung the policy may climb back to — the one the user actually asked
 *  for, lowered permanently when a climb turns out to be beyond the line. */
let ceiling = 0;
let streamStartedAt = 0;
let lastSwitchAt = 0;
let lastSeekAt = 0;
let lastPosition = 0;
let lastStatusAt = 0;
let stallTimes: number[] = [];
let stallSince = 0;
let healthySince = 0;
let dropSample: { at: number; frames: number } | null = null;
let lastUpshiftAt = 0;
/** A switch is in flight: its own restart must not trigger another. */
let switching = false;
/** Said "this is as low as it goes" once for this stream. */
let floorNoted = false;

const now = (): number => Date.now();

function rungIndex(maxBitrate?: number): number {
  const i = QUALITY_CHOICES.findIndex((q) => q.maxBitrate === maxBitrate);
  return i >= 0 ? i : 0;
}

/** Everything that belongs to one stream rather than to the session. */
function resetStream(): void {
  stallTimes = [];
  stallSince = 0;
  healthySince = 0;
  dropSample = null;
  lastPosition = 0;
  lastStatusAt = 0;
  lastSeekAt = 0;
  floorNoted = false;
}

/**
 * The rung playing right now, or null when the policy has no business acting:
 * turned off, nothing playing, a downloaded file (no server to ask for another
 * bitrate), or live TV (restarting a live stream costs more than it saves).
 */
function currentRung(): number | null {
  if (!isAdaptiveEnabled()) return null;
  const q = getQualityState();
  if (!q || q.isLocal || q.live) return null;
  return rungIndex(q.current);
}

/** True while anything recent would make a stall someone else's fault. */
function settling(): boolean {
  const t = now();
  return (
    switching ||
    t - streamStartedAt < STARTUP_GRACE ||
    t - lastSwitchAt < SWITCH_COOLDOWN ||
    t - lastSeekAt < SEEK_GRACE
  );
}

/**
 * The next rung to try below `idx`. Ordinarily that's just `idx + 1`, but nothing
 * guarantees the ladder is actually monotonic against what's playing right now:
 * Direct Play sends the source file exactly as encoded, uncapped, and plenty of
 * well-compressed 4K sits well under the "35 Mbps · 4K" transcode rung that
 * immediately follows it in QUALITY_CHOICES. Stepping down onto a rung that
 * isn't actually lighter than what just stalled is worse than doing nothing —
 * it also saddles the server with a transcode it didn't need to do. So this
 * walks forward past any rung whose cap is at or above the source's own
 * bitrate, stopping at the first one that would genuinely ask for less, or at
 * the lowest rung there is if none would.
 */
function nextRungDown(idx: number, sourceBitrate: number | undefined): number {
  let next = idx + 1;
  while (
    sourceBitrate &&
    next < LOWEST &&
    QUALITY_CHOICES[next].maxBitrate != null &&
    QUALITY_CHOICES[next].maxBitrate! >= sourceBitrate
  ) {
    next++;
  }
  return next;
}

async function stepDown(reason: "stall" | "drops"): Promise<void> {
  const idx = currentRung();
  if (idx === null || settling()) return;

  if (idx >= LOWEST) {
    // Nothing left to give. Say so once — a picture that keeps stopping with
    // no explanation reads as a broken app rather than a struggling network.
    if (!floorNoted) {
      floorNoted = true;
      toast(
        `Still struggling at ${QUALITY_CHOICES[idx].label} — the network or the server is the limit`,
        "error"
      );
    }
    return;
  }

  const next = nextRungDown(idx, getQualityState()?.sourceBitrate);
  // A stall straight after climbing means that rung is beyond this connection.
  // Pin the ceiling here so the policy doesn't spend the evening rediscovering
  // it every five minutes.
  if (lastUpshiftAt && now() - lastUpshiftAt < UPSHIFT_PROBATION) ceiling = next;
  lastUpshiftAt = 0;

  const label = QUALITY_CHOICES[next].label;
  toast(
    reason === "drops"
      ? `Playback can't keep up — switching to ${label}`
      : `Buffering — switching to ${label}`
  );
  switching = true;
  try {
    await switchQuality(QUALITY_CHOICES[next].maxBitrate, { inherited: true, quiet: true });
  } catch {
    toast("Couldn't change quality automatically", "error");
  } finally {
    switching = false;
  }
}

async function stepUp(): Promise<void> {
  const idx = currentRung();
  if (idx === null || switching) return;
  const next = idx - 1;
  if (next < ceiling) return;

  const label = QUALITY_CHOICES[next].label;
  toast(`Connection looks steady — back to ${label}`);
  switching = true;
  lastUpshiftAt = now();
  try {
    await switchQuality(QUALITY_CHOICES[next].maxBitrate, { inherited: true, quiet: true });
  } catch {
    // Staying put is a perfectly good outcome for a switch nobody asked for.
    lastUpshiftAt = 0;
  } finally {
    switching = false;
  }
}

/** mpv stopped the picture to refill its cache. */
function onStall(): void {
  if (currentRung() === null || settling()) return;
  const t = now();
  stallTimes = stallTimes.filter((s) => t - s < STALL_WINDOW);
  stallTimes.push(t);
  if (stallTimes.length >= STALLS_TO_DROP) {
    stallTimes = [];
    void stepDown("stall");
  }
}

function onStatus(st: any): void {
  if (!st.active) {
    resetStream();
    ceiling = 0;
    lastUpshiftAt = 0;
    return;
  }
  const idx = currentRung();
  if (idx === null) return;
  const t = now();

  // Seeks: both the frontend's and mpv's, spotted the same way. Forward, the
  // picture outruns the clock; backward, it goes somewhere no amount of waiting
  // takes it. Everything in between — paused, stalled, playing — is not a seek.
  const pos = st.position ?? 0;
  const elapsed = lastStatusAt ? (t - lastStatusAt) / 1000 : 0;
  const moved = pos - lastPosition;
  if (lastStatusAt && (moved - elapsed > SEEK_JUMP || moved < -1)) lastSeekAt = t;
  lastPosition = pos;
  lastStatusAt = t;

  // A single stall that never ends counts on its own — waiting for a second
  // one means waiting for this one to finish, and it may not.
  if (st.buffering) {
    if (!stallSince) stallSince = t;
    else if (t - stallSince >= LONG_STALL && !settling()) {
      stallSince = 0;
      stallTimes = [];
      void stepDown("stall");
    }
  } else {
    stallSince = 0;
  }

  // Frames given up on. Sampled as a rate: this is the machine failing to
  // decode what it's been sent, which a smaller stream fixes and a bigger
  // buffer does not.
  const frames = typeof st.dropped_frames === "number" ? st.dropped_frames : null;
  if (frames !== null && !st.paused) {
    if (!dropSample) dropSample = { at: t, frames };
    else if (t - dropSample.at >= DROP_WINDOW) {
      const delta = frames - dropSample.frames;
      dropSample = { at: t, frames };
      if (delta >= DROPS_TO_DROP && !settling()) void stepDown("drops");
    }
  }

  // Health, for the climb back. Paused doesn't count: a cache that fills while
  // nothing is playing says nothing about whether it can be kept full.
  const runway = (st.buffered ?? 0) - pos;
  const healthy = !st.paused && !st.buffering && runway >= HEALTHY_RUNWAY;
  if (!healthy) {
    healthySince = 0;
    return;
  }
  if (!healthySince) healthySince = t;
  if (t - healthySince >= UPSHIFT_AFTER && idx > ceiling && !settling()) {
    healthySince = 0;
    void stepUp();
  }
}

function onStarted(ev: Event): void {
  const inherited = !!(ev as CustomEvent).detail?.inherited;
  const q = getQualityState();
  const idx = q ? rungIndex(q.current) : 0;
  resetStream();
  streamStartedAt = now();
  // Only our own switches earn the cooldown; a user who just picked a quality
  // shouldn't have to wait 45 seconds for the policy to start watching it.
  lastSwitchAt = inherited ? streamStartedAt : 0;
  // Picking a quality by hand is the user redrawing the line the policy climbs
  // back to. Anything inherited keeps the line where it was, but can't leave it
  // below what's actually playing.
  ceiling = inherited ? Math.min(ceiling, idx) : idx;
}

/** Wire the policy to the player. Called once at boot. */
export async function registerAdaptiveQuality(): Promise<void> {
  document.addEventListener("fellyjin-player-started", onStarted);
  await listen("player-stall", () => onStall());
  await listen("player-status", (ev) => onStatus(ev.payload as any));
}
