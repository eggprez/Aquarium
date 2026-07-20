// Glue between the Jellyfin API and the Rust/mpv player backend.
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import * as api from "./api";
import { toast } from "./ui";

export interface StreamOptions {
  /** undefined = direct play; number = force transcode at this bitrate */
  maxBitrate?: number;
  resume?: boolean;
  live?: boolean;
  /** explicit start position, overrides resume */
  startSeconds?: number;
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

function itemTitle(item: any): string {
  if (item.Type === "Episode" && item.SeriesName) {
    const s = item.ParentIndexNumber, e = item.IndexNumber;
    const code = s != null && e != null ? ` S${String(s).padStart(2, "0")}E${String(e).padStart(2, "0")}` : "";
    return `${item.SeriesName}${code} · ${item.Name}`;
  }
  return item.Name ?? "FellyJin";
}

export async function playItem(item: any, opts: StreamOptions = {}): Promise<void> {
  const s = api.getSession();
  if (!s) throw new Error("Not logged in");
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
  toast(`Starting “${item.Name}”…`);
  try {
    const src = await api.resolvePlayback(item.Id, {
      maxBitrate: opts.maxBitrate,
      forceTranscode: opts.maxBitrate !== undefined,
      live: opts.live,
      startTicks,
    });
    invoke("ui_log", { msg: `playItem ${item.Id} method=${src.playMethod} startTicks=${startTicks} maxBitrate=${opts.maxBitrate}` }).catch(() => {});
    await invoke("player_play", {
      req: {
        url: src.url,
        title: itemTitle(item),
        start_seconds: startTicks > 0 ? startTicks / 10_000_000 : null,
        ctx: {
          item_id: item.Id,
          media_source_id: src.mediaSourceId,
          play_session_id: src.playSessionId,
          play_method: src.playMethod,
          server_url: s.server,
          token: s.token,
          user_id: s.userId,
          device_id: s.deviceId,
          is_local: false,
          live: !!opts.live,
        },
      },
    });
    document.dispatchEvent(new CustomEvent("fellyjin-player-started"));
  } catch (e: any) {
    invoke("ui_log", { msg: `playItem FAILED: ${e?.message ?? e}` }).catch(() => {});
    toast(`Playback failed: ${e.message ?? e}`, "error");
    throw e;
  }
}

export async function playLocal(dl: any): Promise<void> {
  const s = api.getSession();
  const resumeTicks = dl.position_ticks ?? 0;
  nowPlaying = { item: dl, opts: {}, isLocal: true, queue: null };
  try {
    await invoke("player_play", {
      req: {
        url: dl.path,
        title: dl.title ?? dl.name ?? "Downloaded item",
        start_seconds: resumeTicks > 0 ? resumeTicks / 10_000_000 : null,
        // Transcoded downloads have no duration in the container (saved from
        // a live mux), so give the player the real runtime from metadata.
        known_duration_seconds: dl.run_time_ticks > 0 ? dl.run_time_ticks / 10_000_000 : null,
        ctx: {
          item_id: dl.item_id,
          is_local: true,
          live: false,
          // Server credentials let the backend opportunistically sync
          // progress if we happen to be online.
          server_url: s?.server ?? null,
          token: s?.token ?? null,
          user_id: s?.userId ?? null,
          device_id: s?.deviceId ?? null,
        },
      },
    });
    document.dispatchEvent(new CustomEvent("fellyjin-player-started"));
  } catch (e: any) {
    toast(`Playback failed: ${e.message ?? e}`, "error");
  }
}

// ---------- Autoplay next episode ----------

/** Same heuristic the Downloads view uses to tell episodes from movies. */
function isLocalEpisode(dl: any): boolean {
  return dl.type === "Episode" || (!!dl.series && dl.type !== "Movie");
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
    (d: any) =>
      d.status === "complete" &&
      d.path &&
      isLocalEpisode(d) &&
      (dl.series_id ? d.series_id === dl.series_id : !!dl.series && d.series === dl.series)
  );
  eps.sort(
    (a: any, b: any) =>
      (a.season ?? 0) - (b.season ?? 0) || (a.episode ?? 0) - (b.episode ?? 0)
  );
  const i = eps.findIndex((d: any) => d.item_id === dl.item_id);
  return i >= 0 ? eps[i + 1] ?? null : null;
}

/** Returns true when a next episode was found and playback started. */
async function autoplayNext(np: NonNullable<typeof nowPlaying>): Promise<boolean> {
  if (np.isLocal) {
    const next = await findNextLocalEpisode(np.item);
    if (!next) return false;
    // Start over instead of "resuming" at the end of an already-watched file.
    const watched =
      next.played ||
      (next.run_time_ticks > 0 && (next.position_ticks ?? 0) / next.run_time_ticks > 0.9);
    toast(`Up next: ${next.title ?? next.name ?? "next episode"}`);
    await playLocal(watched ? { ...next, position_ticks: 0 } : next);
    return true;
  }
  const next = await findNextEpisode(np.item);
  if (!next) return false;
  toast(`Up next: ${itemTitle(next)}`);
  await playItem(next, { resume: true, maxBitrate: np.opts.maxBitrate });
  return true;
}

/**
 * Called (synchronously) from the player-status listener when playback ends.
 * Decides whether this end warrants autoplay and, if so, kicks it off.
 */
function maybeAutoplay(st: any): void {
  const np = nowPlaying;
  if (!np || autoplayPending) return;
  // Only a natural end-of-file counts: not user stop, not live, not mid-file.
  if (!st.ended || st.requested_stop) return;
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
    if (!started) document.dispatchEvent(new CustomEvent("fellyjin-autoplay-none"));
  })();
}

export async function startDownload(item: any, q: api.DownloadQuality): Promise<void> {
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
  toast(`Download started: ${item.Name} (${q.label})`, "ok");
}

// ---------- Batch (season) downloads ----------
// The backend starts every download_start immediately with no queueing, so a
// whole season fired at once would open N concurrent connections and hammer the
// server's transcoder. We serialize here: one active download at a time,
// advancing when the backend emits a terminal state for the current item.

interface QueueEntry { item: any; q: api.DownloadQuality; }
const dlQueue: QueueEntry[] = [];
let dlActiveId: string | null = null;
let dlBridgeReady = false;

// The queue is persisted so closing the app mid-season doesn't silently drop
// the episodes that hadn't started yet (the backend only resumes the one
// download that was actually mid-transfer).
const DL_QUEUE_KEY = "fellyjin-dl-queue";

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
}

/**
 * The batch queue lives only in this module's memory, so `downloads_list`
 * (which reads on-disk meta) can't see items still waiting to start. The
 * Downloads view calls this to render the full queue, and listens for
 * `fellyjin-download-queue` to refresh when it changes.
 */
export function getQueuedDownloads(): PendingDownload[] {
  return dlQueue.map((e) => ({
    id: e.item.Id,
    title: e.item.Name ?? itemTitle(e.item),
    series: e.item.SeriesName ?? null,
    season: e.item.ParentIndexNumber ?? null,
    episode: e.item.IndexNumber ?? null,
    quality: e.q.label,
  }));
}

/** Remove a not-yet-started item from the batch queue. */
export function cancelQueuedDownload(id: string): void {
  const i = dlQueue.findIndex((e) => e.item.Id === id);
  if (i >= 0) {
    dlQueue.splice(i, 1);
    notifyQueueChanged();
  }
}

function notifyQueueChanged(): void {
  saveQueue();
  document.dispatchEvent(new CustomEvent("fellyjin-download-queue"));
}

function ensureQueueBridge(): void {
  if (dlBridgeReady) return;
  dlBridgeReady = true;
  listen("download-progress", (ev) => {
    const p = ev.payload as any;
    if (!dlActiveId || p.item_id !== dlActiveId) return;
    if (p.state === "complete" || p.state === "error" || p.state === "canceled") {
      dlActiveId = null;
      void pumpQueue();
    }
  });
  // A queue restored while offline waits here until the server is back.
  document.addEventListener("fellyjin-connectivity", (ev) => {
    if (!(ev as CustomEvent).detail?.offline) void pumpQueue();
  });
}

async function pumpQueue(): Promise<void> {
  if (dlActiveId) return;
  // Download URLs are built against the live session; offline they'd all just
  // error out one after another and drain the queue. The connectivity listener
  // in ensureQueueBridge re-pumps when the server comes back.
  if (api.isOffline()) return;
  const next = dlQueue.shift();
  if (!next) return;
  dlActiveId = next.item.Id;
  notifyQueueChanged();
  try {
    await startDownload(next.item, next.q);
  } catch {
    // Couldn't start (e.g. already in progress) — skip and continue.
    dlActiveId = null;
    void pumpQueue();
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
): Promise<{ queued: number; skipped: number }> {
  ensureQueueBridge();
  const existing = await invoke<any[]>("downloads_list").catch(() => []);
  const existingIds = new Set(existing.map((d: any) => d.item_id));
  let queued = 0;
  let skipped = 0;
  for (const ep of episodes) {
    const dup =
      existingIds.has(ep.Id) ||
      ep.Id === dlActiveId ||
      dlQueue.some((e) => e.item.Id === ep.Id);
    if (dup) {
      skipped++;
      continue;
    }
    dlQueue.push({ item: ep, q });
    queued++;
  }
  if (queued) notifyQueueChanged();
  void pumpQueue();
  return { queued, skipped };
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
    if (e?.item?.Id && !done.has(e.item.Id) && !dlQueue.some((x) => x.item.Id === e.item.Id)) {
      dlQueue.push(e);
    }
  }
  notifyQueueChanged();

  // resume_interrupted (backend) restarts whatever was mid-transfer at the
  // last exit. Adopt it as our active download so the bridge advances the
  // queue when it finishes; only pump directly when nothing is running.
  const active = existing.find((d: any) => d.status === "downloading");
  if (!active) {
    void pumpQueue();
    return;
  }
  dlActiveId = active.item_id;
  // Its terminal event could slip past before our listener was registered,
  // which would stall the queue for good — recheck once shortly after.
  window.setTimeout(async () => {
    if (dlActiveId !== active.item_id) return;
    const now = await invoke<any[]>("downloads_list").catch(() => null);
    if (now && !now.some((d: any) => d.item_id === active.item_id && d.status === "downloading")) {
      dlActiveId = null;
      void pumpQueue();
    }
  }, 5000);
}

// ---------- In-player menus (uosc bridge) ----------

export interface QualityChoice {
  label: string;
  maxBitrate?: number;
}

export const QUALITY_CHOICES: QualityChoice[] = [
  { label: "Direct Play (original)" },
  { label: "20 Mbps · 1080p", maxBitrate: 20_000_000 },
  { label: "10 Mbps · 1080p", maxBitrate: 10_000_000 },
  { label: "4 Mbps · 720p", maxBitrate: 4_000_000 },
  { label: "1.5 Mbps · 480p", maxBitrate: 1_500_000 },
];

/** Quality of the current stream, for menus. Null when nothing is playing. */
export function getQualityState(): { current?: number; isLocal: boolean } | null {
  if (!nowPlaying) return null;
  return { current: nowPlaying.opts.maxBitrate, isLocal: nowPlaying.isLocal };
}

/** Restart the current stream at a new bitrate, keeping the position. */
export async function switchQuality(maxBitrate?: number): Promise<void> {
  const np = nowPlaying;
  invoke("ui_log", { msg: `quality-switch maxBitrate=${maxBitrate} np=${!!np} lastPosition=${lastPosition}` }).catch(() => {});
  if (!np || np.isLocal) return;
  await playItem(np.item, {
    ...np.opts,
    maxBitrate,
    startSeconds: np.opts.live ? undefined : lastPosition,
  });
}

function mpvCommand(cmd: any[]): Promise<void> {
  return invoke("player_mpv_command", { cmd });
}

function openUoscMenu(menu: any): Promise<void> {
  return mpvCommand(["script-message-to", "uosc", "open-menu", JSON.stringify(menu)]);
}

/** Open one of uosc's built-in menus (subtitles, audio, …) over the video. */
export function openUoscBinding(name: string): Promise<void> {
  return mpvCommand(["script-binding", `uosc/${name}`]);
}

export async function showQualityMenu(): Promise<void> {
  if (!nowPlaying || nowPlaying.isLocal) {
    return openUoscMenu({
      title: "Quality",
      items: [{ title: "Playing a downloaded file", value: "ignore", muted: true }],
    });
  }
  const current = nowPlaying.opts.maxBitrate;
  await openUoscMenu({
    title: "Quality",
    items: QUALITY_CHOICES.map((q) => ({
      title: q.label,
      active: q.maxBitrate === current,
      value: `script-message fellyjin-quality ${q.maxBitrate ?? "direct"}`,
    })),
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
      value: `script-message fellyjin-episode ${ep.Id}`,
    })),
  });
}

async function handlePlayerMessage(args: any[]): Promise<void> {
  const [name, arg] = args;
  switch (name) {
    case "fellyjin-menu":
      if (arg === "quality") await showQualityMenu();
      else if (arg === "episodes") await showEpisodeMenu();
      break;
    case "fellyjin-quality":
      await switchQuality(arg === "direct" ? undefined : parseInt(arg, 10));
      break;
    case "fellyjin-episode": {
      const np = nowPlaying;
      const ep = np?.queue?.find((e: any) => e.Id === arg);
      if (ep) await playItem(ep, { resume: true, maxBitrate: np!.opts.maxBitrate });
      break;
    }
    case "fellyjin-fullscreen":
      document.dispatchEvent(new CustomEvent("fellyjin-fullscreen-toggle"));
      break;
    case "fellyjin-fullscreen-exit":
      // ESC pressed inside mpv (it can hold keyboard focus after a
      // WM-level fullscreen) — exit fullscreen but never enter it.
      document.dispatchEvent(new CustomEvent("fellyjin-fullscreen-exit"));
      break;
    case "fellyjin-play-local": {
      // Diagnostic hook (see FELLYJIN_TEST_PLAY in lib.rs): starts a
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
      // Runs before main.ts's status listener (registered first), so the
      // pending flag is visible when the player bar decides to tear down.
      maybeAutoplay(st);
      lastPosition = 0;
    }
  });
  await listen("player-message", (ev) => {
    const args = ev.payload as any[];
    if (Array.isArray(args)) {
      handlePlayerMessage(args).catch((e) => toast(String(e), "error"));
    }
  });
}

export const playerCtl = {
  pauseToggle: () => invoke("player_pause_toggle"),
  stop: () => invoke("player_stop"),
  seek: (seconds: number, absolute: boolean) => invoke("player_seek", { seconds, absolute }),
  setTrack: (kind: "audio" | "sub", track: number | string) =>
    invoke("player_set_track", { kind, track }),
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
    const res: any = await invoke("progress_sync", {
      server: s.server,
      token: s.token,
      deviceId: s.deviceId,
      userId: s.userId,
    });
    if (showToast || res.synced > 0) {
      toast(`Synced ${res.synced} item(s) to Jellyfin${res.failed ? `, ${res.failed} failed` : ""}`,
        res.failed ? "error" : "ok");
    }
  } catch {
    if (showToast) toast("Sync failed — server unreachable?", "error");
  }
}
