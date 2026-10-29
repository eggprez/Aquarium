/**
 * The Live TV channel line-up and what's on it now, for everything that isn't
 * the guide page itself: the player's Channels panel and title, an "On Now"
 * row on Home, and the background load at launch that makes both of those
 * (and the guide) open without a wait.
 *
 * The guide and this module share one cache entry per source, so a line-up
 * read here is the one the guide paints from, and the other way round.
 */
import * as api from "./api";
import * as iptv from "./iptv";
import { getCached, setCached } from "./cache";
import { playItem, playChannelUrl } from "./playback";
import { invoke } from "@tauri-apps/api/core";

/** The cache key the guide and this module both use for the line-up. */
export function lineupKey(): string {
  return `livetv:${iptv.isCustom() ? "custom" : "jellyfin"}`;
}

/** Whatever line-up was last read, with no request. */
export function cachedLineup(): any[] | undefined {
  return getCached<any[]>(lineupKey());
}

/** Whether an item is a Live TV channel from either source. */
export function isChannel(item: any): boolean {
  return !!item && (item.Type === "TvChannel" || item.Custom === true);
}

let inflight: Promise<any[]> | null = null;

/**
 * The line-up, fetched and written to the cache. Concurrent callers share one
 * request. For a custom source the in-memory playlist and guide are reused
 * until the refresh interval says otherwise, unless `force`.
 */
export function loadLineup(force = false): Promise<any[]> {
  if (inflight && !force) return inflight;
  const key = lineupKey();
  const p = (iptv.isCustom() ? iptv.getChannels(force) : api.getChannels())
    .then((channels) => {
      setCached(key, channels);
      return channels;
    })
    .finally(() => {
      if (inflight === p) inflight = null;
    });
  inflight = p;
  return p;
}

// ---------- What's on ----------

/** The schedule from now to a few hours on, by channel. Enough for "now" and
 *  "next" on every channel from one request, which on Jellyfin is a single
 *  batched `/LiveTv/Programs` call rather than one per channel. */
interface Schedule {
  key: string;
  from: number;
  to: number;
  byChannel: Map<string, any[]>;
}

const SCHEDULE_SPAN_MS = 4 * 60 * 60_000;
/** Re-read when the window has run this far down. Now and next are picked
 *  from the list at the time they're asked for, so this only has to keep the
 *  list long enough, not fresh to the minute. */
const SCHEDULE_REFRESH_MS = 60 * 60_000;

let schedule: Schedule | null = null;
let scheduleLoading: Promise<Schedule> | null = null;

async function readSchedule(channels: any[]): Promise<Schedule> {
  const key = lineupKey();
  const from = Date.now();
  const to = from + SCHEDULE_SPAN_MS;
  const progs = iptv.isCustom()
    ? await iptv.getPrograms(new Date(from), new Date(to))
    : await api.getPrograms(channels.map((c) => c.Id), new Date(from), new Date(to));
  const byChannel = new Map<string, any[]>();
  for (const p of progs) {
    const list = byChannel.get(p.ChannelId);
    if (list) list.push(p);
    else byChannel.set(p.ChannelId, [p]);
  }
  for (const list of byChannel.values()) {
    list.sort((a, b) => Date.parse(a.StartDate) - Date.parse(b.StartDate));
  }
  return { key, from, to, byChannel };
}

function scheduleStale(): boolean {
  return !schedule || schedule.key !== lineupKey() || Date.now() - schedule.from > SCHEDULE_REFRESH_MS;
}

/** The near schedule, read again only when it has run down or the source
 *  changed. */
export async function nearSchedule(force = false): Promise<Map<string, any[]>> {
  if (!force && !scheduleStale()) return schedule!.byChannel;
  if (!scheduleLoading) {
    scheduleLoading = (async () => {
      const channels = cachedLineup() ?? (await loadLineup());
      return readSchedule(channels);
    })()
      .then((s) => {
        schedule = s;
        return s;
      })
      .finally(() => {
        scheduleLoading = null;
      });
  }
  return (await scheduleLoading).byChannel;
}

/** The programme on now and the one after it, from whatever schedule is
 *  already in hand. Synchronous, for the player bar that redraws on every
 *  status tick; kicks off a read in the background when there's nothing
 *  usable, and the next tick has the answer. */
export function nowNextSync(ch: any): { now: any | null; next: any | null } {
  if (scheduleStale() && !scheduleLoading) void nearSchedule().catch(() => {});
  const list = schedule?.key === lineupKey() ? schedule.byChannel.get(ch?.Id) : undefined;
  return pickNowNext(list ?? [], ch);
}

function pickNowNext(list: any[], ch: any): { now: any | null; next: any | null } {
  const t = Date.now();
  let now: any | null = null;
  let next: any | null = null;
  for (const p of list) {
    const s = Date.parse(p.StartDate), e = Date.parse(p.EndDate);
    if (s <= t && e > t) now = p;
    else if (s > t) {
      next = p;
      break;
    }
  }
  // Jellyfin's channel list carries the airing programme itself; good enough
  // before the schedule has been read.
  if (!now && !list.length && ch?.CurrentProgram) {
    const p = ch.CurrentProgram;
    if (Date.parse(p.StartDate) <= t && Date.parse(p.EndDate) > t) now = p;
  }
  return { now, next };
}

export async function nowNext(ch: any): Promise<{ now: any | null; next: any | null }> {
  const by = await nearSchedule();
  return pickNowNext(by.get(ch?.Id) ?? [], ch);
}

/**
 * What's on now across the line-up, for an "On Now" row: one entry per
 * channel that has a programme airing, in line-up order. Channels with no
 * guide data are left out; with no guide at all the result is empty.
 */
export async function onNow(limit = 24): Promise<{ channel: any; now: any; next: any | null }[]> {
  const channels = cachedLineup() ?? (await loadLineup());
  const by = await nearSchedule();
  const out: { channel: any; now: any; next: any | null }[] = [];
  for (const ch of channels) {
    const { now, next } = pickNowNext(by.get(ch.Id) ?? [], ch);
    if (now) out.push({ channel: ch, now, next });
    if (out.length >= limit) break;
  }
  return out;
}

/** How far through a programme we are, 0–1. */
export function progressOf(p: any): number {
  const s = Date.parse(p?.StartDate), e = Date.parse(p?.EndDate);
  if (!(e > s)) return 0;
  return Math.max(0, Math.min(1, (Date.now() - s) / (e - s)));
}

export const fmtClock = (iso: string): string =>
  new Date(iso).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });

// ---------- Playing ----------

/**
 * Start a channel from either source. Quiet: the caller shows the tuning
 * state its own way (the guide's tuning screen, the player bar's title).
 * `continuation` keeps the player in the mode it's in — a channel changed from
 * inside a fullscreen player stays fullscreen.
 */
export function playChannel(ch: any, opts: { continuation?: boolean } = {}): Promise<void> {
  return ch?.Custom
    ? playChannelUrl(ch, { quiet: true, continuation: opts.continuation })
    : playItem(ch, { live: true }, { quiet: true, continuation: opts.continuation });
}

// ---------- At launch ----------

/** Long enough after launch that Home's own requests have gone out first. */
const PRELOAD_DELAY_MS = 2500;
/** How often a custom source checks its refresh interval while the app runs. */
const REFRESH_CHECK_MS = 5 * 60_000;
let refreshTimer = 0;

/**
 * Read the line-up (and its near schedule) in the background, so Live TV and
 * any "On Now" row open with it already there. Quiet on failure: a server
 * with no tuner answers with nothing, and that is not worth a toast.
 *
 * Also starts the custom source's refresh check, which re-reads the playlist
 * and guide once the interval in Settings has passed, and tells any open view
 * with `aquarium-lineup-changed`.
 */
export function preloadLineup(): void {
  const hasSource = iptv.isCustom() ? !!iptv.sourceUrls().m3u : true;
  if (!hasSource || !api.getSession() || api.isOffline()) return;
  window.setTimeout(() => {
    void loadLineup()
      .then((channels) => (channels.length ? nearSchedule(true) : null))
      .catch((e) => {
        void invoke("ui_log", { msg: `lineup: preload failed: ${e?.message ?? e}` }).catch(() => {});
      });
  }, PRELOAD_DELAY_MS);

  if (refreshTimer) return;
  refreshTimer = window.setInterval(() => {
    if (!iptv.isCustom() || !iptv.isDue() || document.hidden || api.isOffline()) return;
    void refreshNow().catch(() => {});
  }, REFRESH_CHECK_MS);
}

/** Re-read the source now (Settings' Refresh now, the interval timer). */
export async function refreshNow(): Promise<any[]> {
  if (iptv.isCustom()) iptv.invalidate();
  const channels = await loadLineup(true);
  schedule = null;
  await nearSchedule(true).catch(() => {});
  document.dispatchEvent(new CustomEvent("aquarium-lineup-changed"));
  return channels;
}
