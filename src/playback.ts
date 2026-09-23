// Glue between the Jellyfin API and the Rust/mpv player backend.
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import * as api from "./api";
import { openDialog, toast } from "./ui";

// ---------- Audio level ----------
// mpv starts every session at 100% and forgets what came before, so the level
// is remembered here and handed to each new process on its command line — a
// session you turned down at 1am must not come back up at full volume.

const VOLUME_KEY = "aquarium.volume";
export const MAX_VOLUME = 130;

function loadVolume(): number {
  const v = parseFloat(localStorage.getItem(VOLUME_KEY) ?? "");
  return isFinite(v) && v >= 0 && v <= MAX_VOLUME ? v : 100;
}

let volume = loadVolume();

/** Last known audio level (0–130), for a new mpv session's `--volume`. */
export function getVolume(): number {
  return volume;
}

function rememberVolume(v: number): void {
  volume = Math.max(0, Math.min(MAX_VOLUME, Math.round(v)));
  try {
    localStorage.setItem(VOLUME_KEY, String(volume));
  } catch {
    // Quota exceeded — the level just won't survive a restart.
  }
}

/** mpv changed the level behind our back (its own keys, or the uosc overlay);
 *  keep the remembered value in step so the next session opens where this one
 *  left off. */
export function noteVolume(v: number): void {
  if (isFinite(v) && Math.round(v) !== volume) rememberVolume(v);
}

export interface StreamOptions {
  /** undefined = direct play; number = force transcode at this bitrate */
  maxBitrate?: number;
  resume?: boolean;
  live?: boolean;
  /** explicit start position, overrides resume */
  startSeconds?: number;
}

/**
 * How a stream came to be started, for the things that care about the
 * difference. Kept out of StreamOptions because it describes the *call*, not
 * the stream: it must not survive into the next one (nowPlaying.opts is spread
 * into quality switches).
 */
export interface StartMeta {
  /** The bitrate wasn't a fresh choice by the user — it was carried over from
   *  the last stream (an automatic quality change, the next episode, an episode
   *  picked from the in-player queue). Adaptive quality keeps its ceiling
   *  across these, so one bad stretch of network doesn't permanently pin a
   *  whole binge to 2.5 Mbps. */
  inherited?: boolean;
  /** Skip the "Starting…" toast because the caller says something better. */
  quiet?: boolean;
  /** The stream follows on from the one before it — the next episode, a
   *  quality switch, an episode from the in-player menu — rather than being
   *  something picked from the page. The player keeps its mode across a
   *  continuation (fullscreen stays fullscreen) and starts windowed otherwise. */
  continuation?: boolean;
}

// What's currently playing, for the in-player quality/episode menus.
let nowPlaying: {
  item: any;
  opts: StreamOptions;
  isLocal: boolean;
  queue: any[] | null;
} | null = null;
let lastPosition = 0;
// Set synchronously when a finished playback is about to autoplay its next
// episode, so the player bar/fullscreen stay up instead of tearing down.
let autoplayPending = false;

export function isAutoplayPending(): boolean {
  return autoplayPending;
}

/** Set when the user dismisses the Up Next card: this episode ends and stops
 *  there. Cleared whenever something new starts playing. */
let autoplayCancelled = false;

export function cancelAutoplay(): void {
  autoplayCancelled = true;
  document.dispatchEvent(new CustomEvent("aquarium-upnext-changed"));
}

export function isAutoplayCancelled(): boolean {
  return autoplayCancelled;
}

/** Undo a "stop after this one" — the sleep panel can turn it back off. */
export function resumeAutoplay(): void {
  autoplayCancelled = false;
  document.dispatchEvent(new CustomEvent("aquarium-upnext-changed"));
}

// ---------- Picture adjustments ----------
//
// The same three controls every television has had since they were furniture.
// They matter more here than on a TV, because the panel's own picture settings
// are calibrated for broadcast, not for a film graded three stops darker than
// anything else you watch.

export interface PictureControl {
  /** Key in config.json. */
  key: string;
  /** mpv property, for applying the change to what's on screen right now. */
  prop: string;
  label: string;
}

export const PICTURE_CONTROLS: PictureControl[] = [
  { key: "pic_brightness", prop: "brightness", label: "Brightness" },
  { key: "pic_contrast", prop: "contrast", label: "Contrast" },
  { key: "pic_saturation", prop: "saturation", label: "Saturation" },
  { key: "pic_gamma", prop: "gamma", label: "Gamma" },
];

/** Writing config.json is a file write with an fsync; a slider being dragged
 *  would issue one per pixel. The value on screen is already live — only the
 *  persisted copy is worth waiting for. */
const CONFIG_DEBOUNCE_MS = 300;
let configPending: Record<string, any> = {};
let configTimer = 0;

/** Save config keys, coalescing everything that arrives in the same moment. */
export function saveConfigSoon(patch: Record<string, any>): void {
  Object.assign(configPending, patch);
  clearTimeout(configTimer);
  configTimer = window.setTimeout(() => {
    const batch = configPending;
    configPending = {};
    configTimer = 0;
    void api.saveConfig(batch).catch(() => toast("Couldn't save that setting", "error"));
  }, CONFIG_DEBOUNCE_MS);
}

/**
 * Push a playback setting to the running player and to config.json at once.
 * The live half fails silently when nothing is playing, which is the common
 * case for a setting changed from the Settings page.
 */
export function setLiveSetting(cfgKey: string, prop: string, value: unknown): void {
  void playerCtl.setProp(prop, value).catch(() => {});
  saveConfigSoon({ [cfgKey]: value });
}

// ---------- Sleep timer ----------
//
// Falling asleep to something is the normal way a media client gets used at
// night, and the two things anyone wants from it are "stop when this episode
// ends" and "stop in an hour". The first is autoplay cancellation, which
// already exists for the Up Next card; the second is a timer that stops
// playback outright. Both release the screen-wake inhibitor as a side effect of
// playback ending, so the machine can actually sleep afterwards.

let sleepAt: number | null = null;
let sleepTimer = 0;

/** When the sleep timer will fire, as a timestamp, or null if it isn't set. */
export function sleepDeadline(): number | null {
  return sleepAt;
}

export function cancelSleepTimer(): void {
  clearTimeout(sleepTimer);
  sleepTimer = 0;
  sleepAt = null;
  document.dispatchEvent(new CustomEvent("aquarium-sleep-changed"));
}

/** Stop playback in `minutes`. Replaces any timer already running. */
export function setSleepTimer(minutes: number): void {
  clearTimeout(sleepTimer);
  const ms = Math.max(1, minutes) * 60_000;
  sleepAt = Date.now() + ms;
  sleepTimer = window.setTimeout(() => {
    sleepTimer = 0;
    sleepAt = null;
    // Cancel autoplay first: stopping alone would end the file, and a natural
    // end is exactly what starts the next episode.
    cancelAutoplay();
    void playerCtl.stop().catch(() => {});
    toast("Sleep timer — playback stopped", "ok");
    document.dispatchEvent(new CustomEvent("aquarium-sleep-changed"));
  }, ms);
  document.dispatchEvent(new CustomEvent("aquarium-sleep-changed"));
}

// ---------- Remembered audio and subtitle tracks ----------
//
// The default-language settings decide what a *new* show opens with. This is
// the other half: when you override them for one series — the dub is bad, this
// one show needs subtitles — the next episode should already be set that way.
// Kept per series rather than globally, because that's the granularity the
// decision is actually made at.

interface TrackChoice {
  /** Language tag of the chosen audio track, if any. */
  audio?: string;
  /** Language tag of the chosen subtitle track, or "off" for none. */
  sub?: string;
}

/** Cleared when a new file starts: the first track list of a file is mpv's own
 *  choice, and it's the only one worth overriding rather than recording. */
let tracksApplied = false;

/** The current file's tracks, straight off mpv's own `track-list` — same
 *  shape as the IPC property (id, type, lang, title, selected, ...). What the
 *  player bar's audio/subtitle panels read to show the language in one click
 *  rather than opening uosc's own overlay. */
let lastTracks: any[] = [];

export function getTracks(): any[] {
  return lastTracks;
}

function seriesTrackKey(): string | null {
  const np = nowPlaying;
  // Server episodes only. A downloaded file has been transcoded down to a
  // single audio track, and a film has no "next one" to carry a choice to.
  if (!np || np.isLocal || !np.item?.SeriesId) return null;
  return `aquarium.tracks.${np.item.SeriesId}`;
}

function readTrackChoice(key: string): TrackChoice | null {
  try {
    const raw = localStorage.getItem(key);
    const v = raw ? JSON.parse(raw) : null;
    return v && typeof v === "object" ? (v as TrackChoice) : null;
  } catch {
    return null;
  }
}

function writeTrackChoice(key: string, choice: TrackChoice): void {
  try {
    localStorage.setItem(key, JSON.stringify(choice));
  } catch {
    // Quota exceeded — the choice just won't carry to the next episode.
  }
}

/**
 * mpv reported the file's tracks. On the first report, re-apply whatever was
 * chosen for this series last time; on later ones, record what's selected now
 * (which is how a change made from the player's own track menus is captured —
 * those never go through this app).
 */
function onTrackList(tracks: any[]): void {
  lastTracks = Array.isArray(tracks) ? tracks : [];
  const key = seriesTrackKey();
  if (!key || !Array.isArray(tracks) || !tracks.length) return;
  const selected = (type: string): any => tracks.find((t) => t.type === type && t.selected);

  if (!tracksApplied) {
    tracksApplied = true;
    const saved = readTrackChoice(key);
    if (saved) {
      let touched = false;
      if (saved.audio) {
        const want = tracks.find((t) => t.type === "audio" && t.lang === saved.audio);
        if (want && !want.selected) {
          void playerCtl.setTrack("audio", want.id).catch(() => {});
          touched = true;
        }
      }
      if (saved.sub === "off") {
        if (selected("sub")) {
          void playerCtl.setTrack("sub", "no").catch(() => {});
          touched = true;
        }
      } else if (saved.sub) {
        const want = tracks.find((t) => t.type === "sub" && t.lang === saved.sub);
        if (want && !want.selected) {
          void playerCtl.setTrack("sub", want.id).catch(() => {});
          touched = true;
        }
      }
      // The changes above produce another track list; that one is what gets
      // recorded, so there's nothing to write here.
      if (touched) return;
    }
  }

  const audio = selected("audio")?.lang;
  const sub = selected("sub");
  writeTrackChoice(key, {
    ...(audio ? { audio } : {}),
    sub: sub ? (sub.lang ?? "und") : "off",
  });
}

/** What's on screen, for the Up Next card and the segment lookups. */
export function getNowPlaying(): { item: any; isLocal: boolean } | null {
  return nowPlaying ? { item: nowPlaying.item, isLocal: nowPlaying.isLocal } : null;
}

// The episode that would follow the current one, resolved once and kept until
// playback moves on. Finding it costs one or two requests, and the Up Next card
// asks on every status tick.
let nextPeek: { forId: string; item: any | null } | null = null;

/**
 * The next episode, without starting it — what the Up Next card names. Null
 * when there isn't one, when the item isn't an episode, or while a shuffle is
 * running (the next draw isn't decided until the current episode ends, and
 * naming one early would be a lie).
 */
export async function peekNextEpisode(): Promise<any | null> {
  const np = nowPlaying;
  if (!np || isShuffling()) return null;
  const id = np.isLocal ? np.item.item_id : np.item.Id;
  if (!id) return null;
  const cached = nextPeek;
  if (cached && cached.forId === id) return cached.item;
  const isEpisode = np.isLocal ? isLocalEpisode(np.item) : np.item.Type === "Episode" && np.item.SeriesId;
  if (!isEpisode) {
    nextPeek = { forId: id, item: null };
    return null;
  }
  const found = np.isLocal
    ? await findNextLocalEpisode(np.item).catch(() => null)
    : await findNextEpisode(np.item).catch(() => null);
  nextPeek = { forId: id, item: found };
  return found;
}

/** Start the next episode now rather than waiting for this one to run out. */
export async function playNextNow(): Promise<boolean> {
  const np = nowPlaying;
  if (!np || autoplayPending) return false;
  autoplayPending = true;
  try {
    return await autoplayNext(np);
  } finally {
    autoplayPending = false;
  }
}

function itemTitle(item: any): string {
  if (item.Type === "Episode" && item.SeriesName) {
    const s = item.ParentIndexNumber, e = item.IndexNumber;
    const code = s != null && e != null ? ` Season ${s}, Episode ${e}` : "";
    return `${item.SeriesName}${code} · ${item.Name}`;
  }
  return item.Name ?? "Aquarium";
}

/** Bytes fetched for the pre-flight bandwidth probe: enough that connection
 *  setup and raw round-trip latency don't dominate the measurement, small
 *  enough that even a slow link doesn't spend long on it — and its own
 *  timeout (server.rs) bounds the worst case regardless. */
const BITRATE_PROBE_BYTES = 1_000_000;
/** How much of the measured throughput to actually plan around. A number
 *  measured once, over Wi-Fi, on a link other things may also be using, is
 *  optimistic almost by definition — planning against all of it is exactly
 *  how a probe like this ends up causing the stall it was meant to avoid. */
const BITRATE_PROBE_SAFETY = 0.7;

/**
 * Pick a starting rung from a fresh bandwidth measurement: Direct Play when
 * the connection comfortably covers what the source is actually encoded at
 * (the one number Direct Play can't be capped by), else the best transcode
 * the measurement can plausibly hold. Undefined — Direct Play, unconditionally
 * — whenever there's nothing to go on: the probe failed, or the item carries
 * no bitrate of its own to compare against.
 *
 * This only ever sets the *opening* rung. Whatever it picks, playback is
 * still watched live from there by adaptive.ts, which reacts to how the
 * stream actually behaves rather than to one measurement taken before it
 * started.
 */
async function pickStartingBitrate(item: any): Promise<number | undefined> {
  const measured = await api.probeBandwidth(BITRATE_PROBE_BYTES);
  if (!measured) return undefined;
  const budget = measured * BITRATE_PROBE_SAFETY;
  const source = item?.MediaSources?.[0]?.Bitrate;
  if (typeof source === "number" && source > 0 && source <= budget) return undefined;
  // QUALITY_CHOICES runs best-first after Direct Play (index 0), so the first
  // rung whose cap fits the budget is the best one that does.
  const rung = QUALITY_CHOICES.slice(1).find((q) => (q.maxBitrate ?? 0) <= budget);
  return (rung ?? QUALITY_CHOICES[QUALITY_CHOICES.length - 1]).maxBitrate;
}

export async function playItem(
  item: any,
  opts: StreamOptions = {},
  meta: StartMeta = {}
): Promise<void> {
  const s = api.getSession();
  if (!s) throw new Error("Not logged in");
  // Shuffle only ever covers downloaded files; streaming anything ends it.
  shuffleState = null;
  const startTicks =
    opts.startSeconds != null
      ? Math.max(0, Math.floor(opts.startSeconds * 10_000_000))
      : opts.resume
        ? item.UserData?.PlaybackPositionTicks ?? 0
        : 0;
  // Keep the episode queue when switching quality or hopping episodes
  // within the same series.
  const keepQueue =
    nowPlaying?.queue && nowPlaying.item?.SeriesId === item.SeriesId
      ? nowPlaying.queue
      : null;
  nowPlaying = { item, opts, isLocal: false, queue: keepQueue };
  // Captured before the probe below, which is the only await between here and
  // using it: a later call — a fast double-press of Play, a quality switch —
  // would replace `nowPlaying` with its own object while this one is still in
  // flight, and the check further down is what stops this call clobbering it
  // on the way back.
  const startedPlaying = nowPlaying;
  autoplayCancelled = false;
  nextPeek = null;
  tracksApplied = false;
  if (!meta.quiet) toast(`Starting “${item.Name}”…`);
  // A fresh start with no quality already decided — by hand, or inherited
  // from the episode before it — gets a quick bandwidth check first, so a
  // slow remote connection doesn't have to buffer its way down from Direct
  // Play before landing on a bitrate it can actually hold. Run after the
  // toast above, not before it: "Starting…" shouldn't wait on a network round
  // trip of its own. Autoplay, a hand-picked quality, and live TV all already
  // know what they want and skip it.
  const maxBitrate =
    opts.maxBitrate === undefined && !meta.inherited && !opts.live
      ? await pickStartingBitrate(item)
      : opts.maxBitrate;
  if (nowPlaying === startedPlaying) nowPlaying = { ...nowPlaying, opts: { ...opts, maxBitrate } };
  try {
    const src = await api.resolvePlayback(item.Id, {
      maxBitrate,
      forceTranscode: maxBitrate !== undefined,
      live: opts.live,
      startTicks,
    });
    invoke("ui_log", { msg: `playItem ${item.Id} method=${src.playMethod} startTicks=${startTicks} maxBitrate=${maxBitrate}` }).catch(() => {});
    await invoke("player_play", {
      req: {
        url: src.url,
        title: itemTitle(item),
        start_seconds: startTicks > 0 ? startTicks / 10_000_000 : null,
        volume,
        ctx: {
          item_id: item.Id,
          media_source_id: src.mediaSourceId,
          play_session_id: src.playSessionId,
          play_method: src.playMethod,
          server_url: s.server,
          user_id: s.userId,
          device_id: s.deviceId,
          is_local: false,
          live: !!opts.live,
        },
      },
    });
    document.dispatchEvent(
      new CustomEvent("aquarium-player-started", {
        detail: { inherited: !!meta.inherited, continuation: !!meta.continuation },
      })
    );
  } catch (e: any) {
    invoke("ui_log", { msg: `playItem FAILED: ${e?.message ?? e}` }).catch(() => {});
    toast(`Playback failed: ${e.message ?? e}`, "error");
    throw e;
  }
}

/**
 * Play a channel from a custom M3U playlist: mpv is pointed straight at the
 * provider's URL with no server in between.
 *
 * The context carries no `server_url`, which is what keeps the Jellyfin token
 * out of the request (see `http_auth_header` in player.rs) and stops playback
 * being reported to a server that has never heard of this channel. `live` still
 * has to be set, so the player bar shows Live rather than a scrubber.
 */
export async function playChannelUrl(ch: any): Promise<void> {
  shuffleState = null;
  nowPlaying = { item: ch, opts: { live: true }, isLocal: false, queue: null };
  autoplayCancelled = false;
  nextPeek = null;
  tracksApplied = false;
  toast(`Starting “${ch.Name}”…`);
  // A channel is a session on the far end more often than it is a file, and
  // a cold one can take a good while to come up. The backend waits for it —
  // and retries, since the server has been seen answering a request made
  // while it was still starting with a 500 — so mpv only ever opens a
  // running stream. The second toast is there because the first has faded
  // by the time a slow one arrives, and silence reads as a failure.
  const slow = window.setTimeout(
    () => toast(`Still waiting for “${ch.Name}” to start…`),
    5000
  );
  try {
    invoke("ui_log", { msg: `playChannelUrl ${ch.Id}` }).catch(() => {});
    const url = await invoke<string>("resolve_stream", { url: ch.StreamUrl }).finally(
      () => clearTimeout(slow)
    );
    // The user moved on to something else while the channel was starting.
    if (nowPlaying?.item !== ch) return;
    await invoke("player_play", {
      req: {
        url,
        title: ch.Name ?? "Live TV",
        start_seconds: null,
        volume,
        ctx: {
          item_id: ch.Id,
          is_local: false,
          live: true,
        },
      },
    });
    document.dispatchEvent(new CustomEvent("aquarium-player-started", { detail: {} }));
  } catch (e: any) {
    clearTimeout(slow);
    invoke("ui_log", { msg: `playChannelUrl FAILED: ${e?.message ?? e}` }).catch(() => {});
    toast(`Playback failed: ${e?.message ?? e}`, "error");
    throw e;
  }
}

export async function playLocal(
  dl: any,
  /** `continuation`: see StartMeta — the next episode of a binge, not a click. */
  opts: { keepShuffle?: boolean; continuation?: boolean } = {}
): Promise<void> {
  // Deliberately playing one item ends an in-progress shuffle; only the
  // shuffle's own draws (and its first episode) keep it alive.
  if (!opts.keepShuffle) shuffleState = null;
  const s = api.getSession();
  const resumeTicks = dl.position_ticks ?? 0;
  nowPlaying = { item: dl, opts: {}, isLocal: true, queue: null };
  autoplayCancelled = false;
  nextPeek = null;
  tracksApplied = false;
  try {
    await invoke("player_play", {
      req: {
        url: dl.path,
        title: dl.title ?? dl.name ?? "Downloaded item",
        start_seconds: resumeTicks > 0 ? resumeTicks / 10_000_000 : null,
        // Transcoded downloads have no duration in the container (saved from
        // a live mux), so give the player the real runtime from metadata.
        known_duration_seconds: dl.run_time_ticks > 0 ? dl.run_time_ticks / 10_000_000 : null,
        volume,
        ctx: {
          item_id: dl.item_id,
          is_local: true,
          live: false,
          // Enough for the backend to opportunistically sync progress if we
          // happen to be online; it reads the token from the keyring itself.
          server_url: s?.server ?? null,
          user_id: s?.userId ?? null,
          device_id: s?.deviceId ?? null,
        },
      },
    });
    document.dispatchEvent(
      new CustomEvent("aquarium-player-started", {
        detail: { continuation: !!opts.continuation },
      })
    );
  } catch (e: any) {
    toast(`Playback failed: ${e.message ?? e}`, "error");
  }
}

// ---------- Autoplay next episode ----------

/** Same heuristic the Downloads view uses to tell episodes from movies. */
function isLocalEpisode(dl: any): boolean {
  return dl.type === "Episode" || (!!dl.series && dl.type !== "Movie");
}

/** Do two downloaded episodes belong to the same series? Falls back to the
 *  series name for downloads saved before series_id was recorded. */
function sameSeries(ref: any, dl: any): boolean {
  return ref.series_id ? dl.series_id === ref.series_id : !!ref.series && dl.series === ref.series;
}

/** A file that's already been watched through would otherwise "resume" in its
 *  closing seconds — hand back a copy that starts from the top instead. */
function fromStart(dl: any): any {
  const done =
    dl.played || (dl.run_time_ticks > 0 && (dl.position_ticks ?? 0) / dl.run_time_ticks > 0.9);
  return done ? { ...dl, position_ticks: 0 } : dl;
}

/** Next episode on the server: next in season, else first of the next season. */
async function findNextEpisode(item: any): Promise<any | null> {
  const eps = await api.getEpisodes(item.SeriesId, item.SeasonId).catch(() => []);
  const i = eps.findIndex((e: any) => e.Id === item.Id);
  if (i >= 0 && i + 1 < eps.length) return eps[i + 1];
  const seasons = await api.getSeasons(item.SeriesId).catch(() => []);
  const si = seasons.findIndex((s: any) => s.Id === item.SeasonId);
  const nextSeason = si >= 0 ? seasons[si + 1] : null;
  if (!nextSeason) return null;
  const nextEps = await api.getEpisodes(item.SeriesId, nextSeason.Id).catch(() => []);
  return nextEps[0] ?? null;
}

/** Next downloaded episode of the same series, in (season, episode) order. */
async function findNextLocalEpisode(dl: any): Promise<any | null> {
  const items = await invoke<any[]>("downloads_list").catch(() => []);
  const eps = items.filter(
    (d: any) => d.status === "complete" && d.path && isLocalEpisode(d) && sameSeries(dl, d)
  );
  eps.sort(
    (a: any, b: any) =>
      (a.season ?? 0) - (b.season ?? 0) || (a.episode ?? 0) - (b.episode ?? 0)
  );
  const i = eps.findIndex((d: any) => d.item_id === dl.item_id);
  return i >= 0 ? eps[i + 1] ?? null : null;
}

// ---------- Shuffle (downloaded series) ----------

/** An in-progress shuffle over one downloaded series. */
interface ShuffleState {
  /** Any episode of the series, used to match the rest of the pool. */
  ref: any;
  /** Episodes already drawn in this pass. Cleared once every downloaded
   *  episode has played, so nothing repeats until it has to. */
  seen: Set<string>;
}

let shuffleState: ShuffleState | null = null;

/** True while shuffle is driving what plays next. */
export function isShuffling(): boolean {
  return shuffleState !== null;
}

/**
 * Start shuffling a downloaded series: plays a random episode now, and keeps
 * drawing random ones as each finishes (see autoplayNext) until playback is
 * stopped or something else is played. Works on however much of the show is
 * downloaded — there's no completeness requirement.
 */
export async function startLocalShuffle(eps: any[]): Promise<void> {
  const pool = eps.filter((e) => e.status === "complete" && e.path);
  if (!pool.length) {
    toast("Nothing to shuffle — no playable downloads", "error");
    return;
  }
  const first = pool[Math.floor(Math.random() * pool.length)];
  shuffleState = { ref: first, seen: new Set([first.item_id]) };
  toast(`Shuffling ${first.series ?? "series"} · ${pool.length} episode${pool.length === 1 ? "" : "s"}`);
  await playLocal(fromStart(first), { keepShuffle: true });
}

/** Draw the next episode of the shuffled series, or null when it's spent. */
async function nextShuffledEpisode(current: any): Promise<any | null> {
  const st = shuffleState;
  if (!st) return null;
  // Re-read from disk every time so episodes downloaded (or deleted) mid-binge
  // join or leave the shuffle.
  const items = await invoke<any[]>("downloads_list").catch(() => []);
  const pool = items.filter(
    (d: any) => d.status === "complete" && d.path && isLocalEpisode(d) && sameSeries(st.ref, d)
  );
  if (!pool.length) return null;

  let choices = pool.filter((d: any) => !st.seen.has(d.item_id));
  if (!choices.length) {
    // Whole series has played — reshuffle, just never straight back into the
    // episode that only just ended.
    st.seen.clear();
    choices = pool.filter((d: any) => d.item_id !== current.item_id);
    if (!choices.length) return null; // one-episode series: nothing to move to
  }
  const next = choices[Math.floor(Math.random() * choices.length)];
  st.seen.add(next.item_id);
  return next;
}

/** Returns true when a next episode was found and playback started. */
async function autoplayNext(np: NonNullable<typeof nowPlaying>): Promise<boolean> {
  if (np.isLocal) {
    const shuffling = isShuffling();
    const next = shuffling
      ? await nextShuffledEpisode(np.item)
      : await findNextLocalEpisode(np.item);
    if (!next) return false;
    toast(`${shuffling ? "Shuffle" : "Up next"}: ${next.title ?? next.name ?? "next episode"}`);
    // Start over instead of "resuming" at the end of an already-watched file.
    await playLocal(fromStart(next), { keepShuffle: true, continuation: true });
    return true;
  }
  const next = await findNextEpisode(np.item);
  if (!next) return false;
  toast(`Up next: ${itemTitle(next)}`);
  await playItem(next, { resume: true, maxBitrate: np.opts.maxBitrate }, { inherited: true, continuation: true });
  return true;
}

/**
 * Called (synchronously) from the player-status listener when playback ends.
 * Decides whether this end warrants autoplay and, if so, kicks it off.
 */
function maybeAutoplay(st: any): void {
  const np = nowPlaying;
  if (!np || autoplayPending) return;
  // Dismissing the Up Next card means "stop after this one".
  if (autoplayCancelled) {
    if (st.ended || st.requested_stop) shuffleState = null;
    return;
  }
  // Only a natural end-of-file counts: not user stop, not live, not mid-file.
  if (!st.ended || st.requested_stop) {
    // Stopping playback by hand is how you get out of a shuffle.
    if (st.requested_stop) shuffleState = null;
    return;
  }
  if (np.opts.live) return;
  if (!(st.duration > 0) || st.position / st.duration < 0.9) return;
  const playingId = np.isLocal ? np.item.item_id : np.item.Id;
  if (st.item_id && playingId && st.item_id !== playingId) return;
  const isEpisode = np.isLocal ? isLocalEpisode(np.item) : np.item.Type === "Episode" && np.item.SeriesId;
  if (!isEpisode) return;

  autoplayPending = true;
  void (async () => {
    let started = false;
    try {
      started = await autoplayNext(np);
    } catch (e) {
      invoke("ui_log", { msg: `autoplay failed: ${e}` }).catch(() => {});
    }
    autoplayPending = false;
    // Nothing next (or it failed): let the UI tear the player down normally.
    if (!started) {
      shuffleState = null;
      document.dispatchEvent(new CustomEvent("aquarium-autoplay-none"));
    }
  })();
}

// ---------- Disk space ----------

/** Never fill the volume to the last byte: a download that lands on a disk with
 *  nothing left takes the rest of the desktop down with it. */
const SPACE_HEADROOM = 1 << 30; // 1 GiB

/** Free bytes on the downloads volume, or null when the backend can't tell. */
async function freeSpace(): Promise<number | null> {
  const v = await invoke<number | null>("disk_free").catch(() => null);
  return typeof v === "number" && v > 0 ? v : null;
}

/** Total estimated size of a set of items at one quality, or null when none of
 *  them can be estimated (a server that reports no size and no runtime). */
function estimateTotal(items: any[], q: api.DownloadQuality): number | null {
  let sum = 0;
  let known = false;
  for (const item of items) {
    // Per item, because the direct-file rule can substitute the original for
    // some episodes of a season and not others.
    const e = api.estimateDownloadSize(item, api.effectiveDownloadQuality(item, q));
    if (e == null) continue;
    known = true;
    sum += e;
  }
  return known ? sum : null;
}

/**
 * Gate a download on the disk having room for it.
 *
 * Resolves to the quality to go ahead with — the one asked for when it fits,
 * a smaller one if the user picks that instead — or null if they backed out.
 * Anything unknowable (no estimate, no free-space figure) queues as before:
 * this exists to catch the obvious failure, not to become a new way to fail.
 */
async function resolveSpace(
  items: any[],
  q: api.DownloadQuality,
  what: string
): Promise<api.DownloadQuality | null> {
  const need = estimateTotal(items, q);
  const free = await freeSpace();
  if (need == null || free == null || need + SPACE_HEADROOM <= free) return q;

  // Rungs below the chosen one that would actually fit, cheapest fit first.
  const alternatives = api.DOWNLOAD_QUALITIES.filter((alt) => {
    if (alt.label === q.label) return false;
    const n = estimateTotal(items, alt);
    return n != null && n + SPACE_HEADROOM <= free;
  });

  return new Promise((resolve) => {
    let settled = false;
    const done = (v: api.DownloadQuality | null): void => {
      if (settled) return;
      settled = true;
      resolve(v);
    };
    openDialog({
      title: "Not enough disk space",
      body: [
        `${what} at ${q.label} needs about ${api.bytesToText(need)}, and there is ` +
          `${api.bytesToText(free)} free where downloads are kept.`,
      ].map((text) => {
        const p = document.createElement("p");
        p.textContent = text;
        return p;
      }),
      actions: [
        ...alternatives.map((alt) => ({
          label: `Use ${alt.label} (~${api.bytesToText(estimateTotal(items, alt)!)})`,
          primary: alternatives[0] === alt,
          run: () => done(alt),
        })),
        { label: "Download anyway", danger: true, run: () => done(q) },
        { label: "Cancel", run: () => done(null) },
      ],
      onDismiss: () => done(null),
    });
  });
}

export async function startDownload(item: any, q: api.DownloadQuality): Promise<void> {
  const chosen = await resolveSpace([item], q, itemTitle(item));
  if (!chosen) return;
  // Last stop before the request is built, so every path in — a single item, a
  // season, the queue restored from a previous run — gets the original file
  // whenever transcoding would only make it bigger.
  q = api.effectiveDownloadQuality(item, chosen);
  const swapped = q !== chosen;
  const { url, fileName } = api.buildDownload(item, q);
  const img = api.imageUrl(item, "Primary", 500);
  const seriesImg = item.Type === "Episode" ? api.seriesPosterUrl(item, 500) : null;
  const seasonImg = item.Type === "Episode" ? api.seasonPosterUrl(item, 500) : null;
  await invoke("download_start", {
    req: {
      item_id: item.Id,
      url,
      file_name: fileName,
      image_url: img,
      series_image_url: seriesImg,
      season_image_url: seasonImg,
      estimated_bytes: api.estimateDownloadSize(item, q),
      meta: {
        name: item.Name,
        title: itemTitle(item),
        type: item.Type,
        series: item.SeriesName ?? null,
        series_id: item.SeriesId ?? null,
        season: item.ParentIndexNumber ?? null,
        season_id: item.SeasonId ?? null,
        episode: item.IndexNumber ?? null,
        year: item.ProductionYear ?? null,
        run_time_ticks: item.RunTimeTicks ?? null,
        quality: q.label,
        // Seed watch state from the server so an already-watched episode
        // shows its ✓ / resume point immediately; kept fresh afterwards by
        // the Downloads view's online refresh.
        position_ticks: item.UserData?.PlaybackPositionTicks ?? 0,
        played: !!item.UserData?.Played,
      },
    },
  });
  toast(
    swapped
      ? `Download started: ${item.Name} (original file — smaller than a ${chosen.label} transcode)`
      : `Download started: ${item.Name} (${q.label})`,
    "ok"
  );
}

/** Outcome of a batch queue. `cancelled` is the disk-space dialog being turned
 *  down, which is neither "queued nothing" nor "everything was already there" —
 *  callers stay quiet rather than reporting one of those. */
export interface BatchResult {
  queued: number;
  skipped: number;
  cancelled?: boolean;
}

// ---------- Batch (season) downloads ----------
// The backend starts every download_start immediately with no queueing, so a
// whole season fired at once would open N concurrent connections and hammer the
// server's transcoder. We throttle here: at most `dlConcurrency` downloads run
// at a time, advancing when the backend emits a terminal state for one of them.

/**
 * Either a new download, built from a live Jellyfin item, or a retry of one
 * that already failed. A retry can't carry an item: the failed download is
 * replayed by the backend from the `request` it stored in meta.json, which is
 * the only thing that still knows the original URL and quality. Both kinds
 * share the queue so a bulk retry obeys the same concurrency limit — firing
 * twelve stalled downloads at once is what got them stalled.
 */
type QueueEntry =
  | { kind?: "new"; item: any; q: api.DownloadQuality }
  | { kind: "retry"; id: string; title: string };

/** Queue entries predating the retry kind have no discriminant; they're all
 *  new downloads, so absent `kind` reads as "new". */
function isRetry(e: QueueEntry): e is { kind: "retry"; id: string; title: string } {
  return e.kind === "retry";
}

function entryId(e: QueueEntry): string {
  return isRetry(e) ? e.id : e.item?.Id;
}

const dlQueue: QueueEntry[] = [];
const dlActive = new Set<string>();
let dlBridgeReady = false;

// The queue is persisted so closing the app mid-season doesn't silently drop
// the episodes that hadn't started yet (the backend only resumes the one
// download that was actually mid-transfer).
const DL_QUEUE_KEY = "aquarium-dl-queue";
const DL_CONCURRENCY_KEY = "aquarium-dl-concurrency";

export const MAX_DOWNLOAD_CONCURRENCY = 6;

/** How many queued downloads may run at once (user setting, persisted). */
let dlConcurrency = ((): number => {
  const n = parseInt(localStorage.getItem(DL_CONCURRENCY_KEY) ?? "", 10);
  return n >= 1 && n <= MAX_DOWNLOAD_CONCURRENCY ? n : 1;
})();

export function getDownloadConcurrency(): number {
  return dlConcurrency;
}

/** Change the parallel-download limit. Raising it starts more right away;
 *  lowering it only takes effect as running downloads finish. */
export function setDownloadConcurrency(n: number): void {
  dlConcurrency = Math.max(1, Math.min(MAX_DOWNLOAD_CONCURRENCY, Math.floor(n)));
  try {
    localStorage.setItem(DL_CONCURRENCY_KEY, String(dlConcurrency));
  } catch {
    // Quota exceeded — the setting just won't survive a restart.
  }
  void pumpQueue();
}

function saveQueue(): void {
  try {
    localStorage.setItem(DL_QUEUE_KEY, JSON.stringify(dlQueue));
  } catch {
    // Quota exceeded — the queue just won't survive a restart.
  }
}

/** A season download waiting its turn (the backend runs one at a time). */
export interface PendingDownload {
  id: string;
  title: string;
  series: string | null;
  season: number | null;
  episode: number | null;
  quality: string;
  /** A re-run of a failed download rather than a first attempt. Its quality
   *  and episode numbering live in the stored meta, not here. */
  retry?: boolean;
}

/**
 * The batch queue lives only in this module's memory, so `downloads_list`
 * (which reads on-disk meta) can't see items still waiting to start. The
 * Downloads view calls this to render the full queue, and listens for
 * `aquarium-download-queue` to refresh when it changes.
 */
export function getQueuedDownloads(): PendingDownload[] {
  return dlQueue.map((e) =>
    isRetry(e)
      ? {
          id: e.id,
          title: e.title,
          series: null,
          season: null,
          episode: null,
          quality: "retrying",
          retry: true,
        }
      : {
          id: e.item.Id,
          title: e.item.Name ?? itemTitle(e.item),
          series: e.item.SeriesName ?? null,
          season: e.item.ParentIndexNumber ?? null,
          episode: e.item.IndexNumber ?? null,
          quality: e.q.label,
        }
  );
}

/** Remove a not-yet-started item from the batch queue. */
export function cancelQueuedDownload(id: string): void {
  const i = dlQueue.findIndex((e) => entryId(e) === id);
  if (i >= 0) {
    dlQueue.splice(i, 1);
    notifyQueueChanged();
  }
}

/**
 * Put retries at the *front* of the queue, and return the ids actually queued.
 *
 * Front rather than back because a retry is something the user already asked
 * for and watched fail — making it wait behind an untouched season is the
 * wrong order. But it does wait: `pumpQueue` is still the only thing that
 * starts a download, so the concurrency limit applies to retries exactly like
 * anything else. Retrying three stalled episodes with the limit set to 1 runs
 * them one at a time.
 *
 * Anything already running or already queued is skipped, so a double-click
 * can't queue the same download twice.
 */
function queueRetriesFirst(entries: { item_id: string; title?: string }[]): string[] {
  const fresh: QueueEntry[] = [];
  const queued: string[] = [];
  for (const d of entries) {
    if (!d?.item_id) continue;
    if (dlActive.has(d.item_id) || dlQueue.some((e) => entryId(e) === d.item_id)) continue;
    if (fresh.some((e) => entryId(e) === d.item_id)) continue;
    fresh.push({ kind: "retry", id: d.item_id, title: d.title ?? d.item_id });
    queued.push(d.item_id);
  }
  if (fresh.length) {
    // Spliced in as one block so a bulk retry keeps the order it was listed in
    // rather than coming out reversed.
    dlQueue.unshift(...fresh);
    notifyQueueChanged();
    void pumpQueue();
  }
  return queued;
}

/**
 * Queue a retry for a single failed download. Returns false if it was already
 * running or already waiting.
 *
 * This used to call `download_retry` directly from the Downloads view, which
 * started the transfer there and then and ignored the concurrency limit
 * entirely — clicking Retry on three failed episodes with the limit set to 1
 * opened three connections, which is generally what had stalled them in the
 * first place.
 */
export function retryDownload(itemId: string, title?: string): boolean {
  ensureQueueBridge();
  return queueRetriesFirst([{ item_id: itemId, title }]).length > 0;
}

/**
 * Queue a retry for every download that stopped with an error.
 *
 * A download that stalls for STALL_TIMEOUT (90s) gives up and lands in the
 * Failed group, so a network drop mid-season leaves a row of them that would
 * otherwise need clicking one at a time. These go through the same queue as
 * everything else: retrying a dozen at once would open a dozen connections and
 * strand them exactly as before. Returns how many were queued.
 */
export function retryFailedDownloads(failed: { item_id: string; title?: string }[]): number {
  ensureQueueBridge();
  return queueRetriesFirst(failed).length;
}

/** Drop every not-yet-started item. Returns how many were removed. Running
 *  downloads are the backend's business — the caller cancels those. */
export function clearDownloadQueue(): number {
  const n = dlQueue.length;
  dlQueue.length = 0;
  dlActive.clear();
  notifyQueueChanged();
  return n;
}

function notifyQueueChanged(): void {
  saveQueue();
  document.dispatchEvent(new CustomEvent("aquarium-download-queue"));
}

function ensureQueueBridge(): void {
  if (dlBridgeReady) return;
  dlBridgeReady = true;
  listen("download-progress", (ev) => {
    const p = ev.payload as any;
    if (!dlActive.has(p.item_id)) return;
    if (p.state === "complete" || p.state === "error" || p.state === "canceled") {
      dlActive.delete(p.item_id);
      void pumpQueue();
    }
  });
  // A queue restored while offline waits here until the server is back.
  document.addEventListener("aquarium-connectivity", (ev) => {
    if (!(ev as CustomEvent).detail?.offline) void pumpQueue();
  });
}

async function pumpQueue(): Promise<void> {
  // Download URLs are built against the live session; offline they'd all just
  // error out one after another and drain the queue. The connectivity listener
  // in ensureQueueBridge re-pumps when the server comes back.
  if (api.isOffline()) return;
  while (dlActive.size < dlConcurrency) {
    const next = dlQueue.shift();
    if (!next) return;
    const id = entryId(next);
    dlActive.add(id);
    try {
      if (isRetry(next)) {
        // The backend rebuilds the request from meta.json and resumes from the
        // .part file a stalled run left behind.
        await invoke("download_retry", { itemId: next.id });
      } else {
        await startDownload(next.item, next.q);
      }
    } catch (e) {
      // Couldn't start (e.g. already in progress) — skip and continue, but say
      // so: silently dropping an episode looks exactly like a stalled queue.
      dlActive.delete(id);
      toast(`Couldn't start ${isRetry(next) ? next.title : itemTitle(next.item)}: ${e}`, "error");
    }
    // Notify only once the backend has written meta.json. Any earlier and the
    // Downloads view re-reads `downloads_list` before this item exists on
    // disk — it has already been shifted off dlQueue, so it renders in neither
    // "Up next" nor "Downloading", and the progress ticks that follow only
    // patch a bar that was never drawn. The queue then looks dead until the
    // next terminal event, minutes later.
    notifyQueueChanged();
  }
}

/**
 * Queue a batch of items (a season's episodes) to download one at a time.
 * Skips anything already downloaded or already queued. Returns how many were
 * newly queued vs. skipped so the caller can report it.
 */
export async function downloadSeason(
  episodes: any[],
  q: api.DownloadQuality
): Promise<BatchResult> {
  ensureQueueBridge();
  const existing = await invoke<any[]>("downloads_list").catch(() => []);
  const existingIds = new Set(existing.map((d: any) => d.item_id));
  const fresh: any[] = [];
  let skipped = 0;
  for (const ep of episodes) {
    const dup =
      existingIds.has(ep.Id) ||
      dlActive.has(ep.Id) ||
      dlQueue.some((e) => entryId(e) === ep.Id);
    if (dup) skipped++;
    else fresh.push(ep);
  }

  // Sized against what will actually be queued, not what was asked for — half
  // an already-downloaded season shouldn't count towards the total.
  if (fresh.length) {
    const chosen = await resolveSpace(
      fresh,
      q,
      `${fresh.length} episode${fresh.length === 1 ? "" : "s"}`
    );
    if (!chosen) return { queued: 0, skipped, cancelled: true };
    q = chosen;
  }

  for (const ep of fresh) dlQueue.push({ item: ep, q });
  const queued = fresh.length;
  if (queued) notifyQueueChanged();
  void pumpQueue();
  return { queued, skipped };
}

/**
 * Queue every episode of a series. Seasons are fetched here unless the caller
 * already has them (the series page does). Returns the queue counts plus how
 * many seasons were walked, for the confirmation toast.
 */
export async function downloadSeries(
  seriesId: string,
  q: api.DownloadQuality,
  knownSeasons?: any[]
): Promise<BatchResult & { seasons: number }> {
  const seasons = knownSeasons ?? (await api.getSeasons(seriesId));
  const all: any[] = [];
  for (const season of seasons) {
    const eps = await api.getEpisodes(seriesId, season.Id).catch(() => []);
    all.push(...eps);
  }
  if (!all.length) throw new Error("No episodes found for this series");
  const res = await downloadSeason(all, q);
  return { ...res, seasons: seasons.length };
}

/**
 * Bring back the batch queue saved by a previous run. Called once at boot
 * (after the session is loaded): items that finished in the meantime are
 * dropped, and if the backend is already resuming an interrupted download we
 * wait for it instead of starting a second concurrent transfer.
 */
export async function restoreDownloadQueue(): Promise<void> {
  if (!api.getSession()) return;
  let saved: QueueEntry[] = [];
  try {
    saved = JSON.parse(localStorage.getItem(DL_QUEUE_KEY) ?? "[]");
  } catch {
    // Corrupted entry — drop it.
  }
  if (!Array.isArray(saved) || !saved.length) return;
  ensureQueueBridge();

  const existing = await invoke<any[]>("downloads_list").catch(() => []);
  const done = new Set(
    existing.filter((d: any) => d.status === "complete").map((d: any) => d.item_id)
  );
  for (const e of saved) {
    const id = e && entryId(e);
    if (id && !done.has(id) && !dlQueue.some((x) => entryId(x) === id)) {
      dlQueue.push(e);
    }
  }
  notifyQueueChanged();

  // resume_interrupted (backend) restarts whatever was mid-transfer at the
  // last exit. Adopt those as our active downloads so the bridge advances the
  // queue when they finish; only pump directly when nothing is running.
  const active = existing.filter((d: any) => d.status === "downloading");
  if (!active.length) {
    void pumpQueue();
    return;
  }
  for (const d of active) dlActive.add(d.item_id);
  // A terminal event could slip past before our listener was registered,
  // which would stall the queue for good — recheck once shortly after.
  window.setTimeout(async () => {
    const now = await invoke<any[]>("downloads_list").catch(() => null);
    if (!now) return;
    let freed = false;
    for (const d of active) {
      if (!dlActive.has(d.item_id)) continue;
      if (!now.some((x: any) => x.item_id === d.item_id && x.status === "downloading")) {
        dlActive.delete(d.item_id);
        freed = true;
      }
    }
    if (freed) void pumpQueue();
  }, 5000);
}

// ---------- In-player menus (uosc bridge) ----------

export interface QualityChoice {
  label: string;
  maxBitrate?: number;
}

/**
 * The transcode ladder, best-first.
 *
 * Every rung is a *total* stream cap — Jellyfin fits video, audio and container
 * inside it — sized for the h264 the transcoding profile asks for at the point
 * where a careful viewer stops being able to fault it: roughly 2 Mbps of video
 * at 480p rising to 32 at 4K, plus audio. Going higher on h264 buys nothing
 * visible, which is why the old 20 Mbps 1080p rung is gone; the headroom now
 * pays for the 4K and 1440p rungs that weren't there at all.
 *
 * Jellyfin picks the resolution itself from the cap, so the resolution in each
 * label is a description of what comes back rather than something we ask for.
 * Rungs are spaced about 2x apart because the adaptive policy steps one at a
 * time — closer together and a struggling connection takes all evening to
 * reach a bitrate it can actually hold.
 */
export const QUALITY_CHOICES: QualityChoice[] = [
  { label: "Direct Play (original)" },
  { label: "35 Mbps · 4K", maxBitrate: 35_000_000 },
  { label: "18 Mbps · 1440p", maxBitrate: 18_000_000 },
  { label: "10 Mbps · 1080p", maxBitrate: 10_000_000 },
  { label: "5 Mbps · 720p", maxBitrate: 5_000_000 },
  { label: "2.5 Mbps · 480p", maxBitrate: 2_500_000 },
];

/** Quality of the current stream, for menus. Null when nothing is playing. */
export function getQualityState(): {
  current?: number;
  isLocal: boolean;
  live: boolean;
  /** What the source file itself is encoded at, when the server reports one.
   *  Direct Play sends this over the network uncapped — the adaptive policy
   *  uses it so a step down from Direct Play never lands on a transcode rung
   *  whose cap is no lighter than the original already was. */
  sourceBitrate?: number;
} | null {
  if (!nowPlaying) return null;
  const bitrate = nowPlaying.item?.MediaSources?.[0]?.Bitrate;
  return {
    current: nowPlaying.opts.maxBitrate,
    isLocal: nowPlaying.isLocal,
    live: !!nowPlaying.opts.live,
    sourceBitrate: typeof bitrate === "number" && bitrate > 0 ? bitrate : undefined,
  };
}

/** Restart the current stream at a new bitrate, keeping the position. */
export async function switchQuality(maxBitrate?: number, meta: StartMeta = {}): Promise<void> {
  const np = nowPlaying;
  invoke("ui_log", { msg: `quality-switch maxBitrate=${maxBitrate} np=${!!np} lastPosition=${lastPosition}` }).catch(() => {});
  if (!np || np.isLocal) return;
  await playItem(
    np.item,
    {
      ...np.opts,
      maxBitrate,
      startSeconds: np.opts.live ? undefined : lastPosition,
    },
    { ...meta, continuation: true }
  );
}

// ---------- Adaptive quality (preference) ----------
// The policy itself lives in adaptive.ts; the setting lives here so that both
// the in-player menu and the Settings page can read it without either of them
// importing the policy.

const ADAPTIVE_KEY = "aquarium.adaptive";

/**
 * May the player change transcode quality by itself when a stream stops
 * keeping up? On unless turned off: the thing it reacts to — a picture that
 * stops every few seconds to buffer — is worse than the switch it makes.
 */
export function isAdaptiveEnabled(): boolean {
  return localStorage.getItem(ADAPTIVE_KEY) !== "off";
}

export function setAdaptiveEnabled(on: boolean): void {
  try {
    localStorage.setItem(ADAPTIVE_KEY, on ? "on" : "off");
  } catch {
    // Quota exceeded — the setting just won't survive a restart.
  }
  document.dispatchEvent(new CustomEvent("aquarium-adaptive-changed"));
}

function mpvCommand(cmd: any[]): Promise<void> {
  return invoke("player_mpv_command", { cmd });
}

function openUoscMenu(menu: any): Promise<void> {
  return mpvCommand(["script-message-to", "uosc", "open-menu", JSON.stringify(menu)]);
}

export async function showQualityMenu(): Promise<void> {
  if (!nowPlaying || nowPlaying.isLocal) {
    return openUoscMenu({
      title: "Quality",
      items: [{ title: "Playing a downloaded file", value: "ignore", muted: true }],
    });
  }
  const current = nowPlaying.opts.maxBitrate;
  const auto = isAdaptiveEnabled();
  await openUoscMenu({
    title: "Quality",
    items: [
      {
        title: `Adapt to the connection: ${auto ? "on" : "off"}`,
        hint: auto ? "drops a rung when the stream stalls" : "stays where you put it",
        value: "script-message aquarium-adaptive toggle",
      },
      ...QUALITY_CHOICES.map((q) => ({
        title: q.label,
        active: q.maxBitrate === current,
        value: `script-message aquarium-quality ${q.maxBitrate ?? "direct"}`,
      })),
    ],
  });
}

export async function showEpisodeMenu(): Promise<void> {
  const np = nowPlaying;
  if (!np || np.isLocal || np.item.Type !== "Episode" || !np.item.SeriesId) {
    return openUoscMenu({
      title: "Episode queue",
      items: [{ title: "Not playing an episode", value: "ignore", muted: true }],
    });
  }
  if (!np.queue) {
    try {
      np.queue = await api.getEpisodes(np.item.SeriesId, np.item.SeasonId);
    } catch {
      np.queue = [];
    }
  }
  const pad = (n: any) => String(n ?? 0).padStart(2, "0");
  await openUoscMenu({
    title: `${np.item.SeriesName ?? "Episodes"} — ${np.item.SeasonName ?? "Season"}`,
    items: (np.queue ?? []).map((ep: any) => ({
      title: `${ep.IndexNumber != null ? ep.IndexNumber + ". " : ""}${ep.Name}`,
      hint: `S${pad(ep.ParentIndexNumber)}E${pad(ep.IndexNumber)}${ep.UserData?.Played ? " ✓" : ""}`,
      active: ep.Id === np.item.Id,
      value: `script-message aquarium-episode ${ep.Id}`,
    })),
  });
}

async function handlePlayerMessage(args: any[]): Promise<void> {
  const [name, arg] = args;
  switch (name) {
    case "aquarium-menu":
      if (arg === "quality") await showQualityMenu();
      else if (arg === "episodes") await showEpisodeMenu();
      break;
    case "aquarium-quality":
      await switchQuality(arg === "direct" ? undefined : parseInt(arg, 10));
      break;
    case "aquarium-adaptive": {
      const on = !isAdaptiveEnabled();
      setAdaptiveEnabled(on);
      toast(
        on
          ? "Quality will adapt when the connection can't keep up"
          : "Quality stays where you set it",
        "ok"
      );
      break;
    }
    case "aquarium-episode": {
      const np = nowPlaying;
      const ep = np?.queue?.find((e: any) => e.Id === arg);
      if (ep) await playItem(ep, { resume: true, maxBitrate: np!.opts.maxBitrate }, { inherited: true, continuation: true });
      break;
    }
    case "aquarium-fullscreen":
      document.dispatchEvent(new CustomEvent("aquarium-fullscreen-toggle"));
      break;
    case "aquarium-fullscreen-exit":
      // ESC pressed inside mpv (it can hold keyboard focus after a
      // WM-level fullscreen) — exit fullscreen but never enter it.
      document.dispatchEvent(new CustomEvent("aquarium-fullscreen-exit"));
      break;
    case "aquarium-play-local": {
      // Diagnostic hook (see AQUARIUM_TEST_PLAY in lib.rs): starts a
      // downloaded item through the real frontend path — unlike TEST_PLAY it
      // sets nowPlaying, so quality/episode menus and autoplay are exercised.
      const items = await invoke<any[]>("downloads_list").catch(() => []);
      const dl = items.find((d: any) => d.item_id === arg);
      if (dl?.path) await playLocal(dl);
      break;
    }
  }
}

/** Wire up player events; called once at boot. */
export async function registerPlayerBridge(): Promise<void> {
  await listen("player-status", (ev) => {
    const st = ev.payload as any;
    if (st.active && typeof st.position === "number") lastPosition = st.position;
    if (!st.active) {
      // mpv couldn't open what it was given. Without this the player simply
      // vanishes, which for a live channel looks like nothing happened at
      // all. ("redirect" is mpv having fallen back to reading the address as
      // a playlist after the real demuxer refused it.)
      if (st.ended && !st.requested_stop && (st.error || st.reason === "redirect")) {
        toast(`Playback failed: ${st.error ?? "the stream couldn't be opened"}`, "error");
      }
      // Runs before main.ts's status listener (registered first), so the
      // pending flag is visible when the player bar decides to tear down.
      maybeAutoplay(st);
      lastPosition = 0;
      lastTracks = [];
    }
  });
  await listen("player-message", (ev) => {
    const args = ev.payload as any[];
    if (Array.isArray(args)) {
      handlePlayerMessage(args).catch((e) => toast(String(e), "error"));
    }
  });
  // The file's audio and subtitle tracks, whenever mpv's list changes.
  await listen("player-tracks", (ev) => {
    try {
      onTrackList(ev.payload as any[]);
    } catch {
      // Never let a malformed track list break playback.
    }
  });
  // A media key, or the shell's own next button (see mpris.rs).
  await listen("mpris-next", () => {
    void playNextNow();
  });
}

export const SPEEDS = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2];

/** How far one press of the subtitle-timing buttons shifts things, in seconds
 *  (mpv's own `z`/`Z` bindings use the same step). */
export const SUB_DELAY_STEP = 0.1;

export const playerCtl = {
  pauseToggle: () => invoke("player_pause_toggle"),
  /**
   * Set an mpv property on the running player. Used by the settings that have
   * a visible effect you'd want to judge against the picture in front of you —
   * subtitle size, brightness — so they take hold mid-episode instead of at the
   * next one. Rejects when nothing is playing; callers there simply don't care,
   * because the value is on its way to config.json either way.
   */
  setProp: (name: string, value: unknown) => mpvCommand(["set_property", name, value]),
  stop: () => invoke("player_stop"),
  seek: (seconds: number, absolute: boolean) => invoke("player_seek", { seconds, absolute }),
  setTrack: (kind: "audio" | "sub", track: number | string) =>
    invoke("player_set_track", { kind, track }),
  /** Set the audio level (0–130). Remembered for the next session. */
  setVolume: (v: number) => {
    rememberVolume(v);
    return mpvCommand(["set_property", "volume", volume]);
  },
  setMute: (m: boolean) => mpvCommand(["set_property", "mute", m]),
  setSpeed: (s: number) => mpvCommand(["set_property", "speed", Math.max(0.25, Math.min(4, s))]),
  /** Shift subtitles in time; negative shows them earlier. */
  setSubDelay: (seconds: number) =>
    mpvCommand(["set_property", "sub-delay", Math.round(seconds * 100) / 100]),
};

export async function syncOfflineProgress(showToast = false): Promise<void> {
  const s = api.getSession();
  if (!s) return;
  const pending = await invoke<number>("progress_pending");
  if (pending === 0) {
    if (showToast) toast("Nothing to sync — all progress is up to date", "ok");
    return;
  }
  try {
    // No arguments: the backend takes the server and user from the config and
    // the token from the keyring.
    const res: any = await invoke("progress_sync");
    if (showToast || res.synced > 0) {
      toast(`Synced ${res.synced} item(s) to Jellyfin${res.failed ? `, ${res.failed} failed` : ""}`,
        res.failed ? "error" : "ok");
    }
  } catch {
    if (showToast) toast("Sync failed — server unreachable?", "error");
  }
}
