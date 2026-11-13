// Shared set-up for the playback, adaptive-quality and download-queue tests.
//
// `boot()` gives a fresh copy of src/playback.ts (it keeps a great deal of
// module-level state), signed in against the mocked bridge, with every player
// and download command answered and a toast root in the page. Time is faked,
// so nothing in these tests waits on the wall clock.
import { vi } from "vitest";
// Loaded here, before any `vi.resetModules()`, so the mocked bridge the app
// modules get is built from the same copy of helpers/tauri.ts the tests hold.
import "@tauri-apps/api/core";
import "@tauri-apps/api/event";
import { emitEvent, invokeCalls, mockJellyfin, onInvokes, signIn, type JfArgs } from "./tauri";

export type Playback = typeof import("../../src/playback");
export type Api = typeof import("../../src/api");

export const SERVER = "http://jf.test:8096";

export interface BootOptions {
  /** Extra config.json keys (playback and download preferences). */
  config?: Record<string, any>;
  /** What `downloads_list` answers; the returned `state.downloads` can be changed later. */
  downloads?: any[];
  /** False leaves the app signed out. */
  signedIn?: boolean;
  /** False skips `registerPlayerBridge()`. */
  bridge?: boolean;
  /** What the bandwidth probe measures, in bits per second; null = the probe fails. */
  probe?: number | null;
}

export interface Booted {
  pb: Playback;
  api: Api;
  state: { downloads: any[]; probe: number | null };
}

const added: Array<[string, EventListenerOrEventListenerObject, any]> = [];
let spy: { mockRestore(): void } | null = null;

/**
 * Modules under test hang listeners on `document`, and a module instance from
 * an earlier test would otherwise keep answering events in a later one. They
 * are recorded here and taken off again by `teardown()`.
 */
function trackDocumentListeners(): void {
  if (spy) return;
  const original = document.addEventListener.bind(document);
  spy = vi.spyOn(document, "addEventListener").mockImplementation((type: any, fn: any, opts?: any) => {
    added.push([type, fn, opts]);
    original(type, fn, opts);
  });
}

/** Call from `afterEach`. */
export function teardown(): void {
  for (const [type, fn, opts] of added.splice(0)) document.removeEventListener(type, fn, opts);
  spy?.mockRestore();
  spy = null;
  vi.restoreAllMocks();
}

export async function boot(opts: BootOptions = {}): Promise<Booted> {
  vi.resetModules();
  vi.useFakeTimers();
  trackDocumentListeners();
  document.body.innerHTML = '<div id="toasts"></div>';
  const state = { downloads: opts.downloads ?? [], probe: opts.probe ?? null };
  onInvokes({
    player_play: null,
    player_stop: null,
    player_warm: null,
    player_seek: null,
    player_set_track: null,
    player_pause_toggle: null,
    player_mpv_command: null,
    downloads_list: () => state.downloads,
    download_start: null,
    download_retry: null,
    download_pause: null,
    downloads_sync_keep_awake: null,
    network_metered: false,
    disk_free: null,
    jf_ping: true,
    jf_bitrate_test: () => {
      if (state.probe == null) throw "server|no bitrate test";
      return state.probe;
    },
  });
  let api: Api;
  if (opts.signedIn === false) {
    onInvokes({ config_load: () => ({ ...(opts.config ?? {}) }), config_save: null });
    api = await import("../../src/api");
    await api.loadConfig();
  } else {
    api = await signIn(opts.config ?? {});
  }
  const pb = await import("../../src/playback");
  if (opts.bridge !== false) await pb.registerPlayerBridge();
  return { pb, api, state };
}

// ---------- Jellyfin answers ----------

export interface ServerOptions {
  /** Series id -> season id -> episodes. Seasons are listed in insertion order. */
  shows?: Record<string, Record<string, any[]>>;
  /** Item id -> full item, for `/Items/{id}`. */
  items?: Record<string, any>;
  /** Status for PlaybackInfo, to make a start fail. */
  playbackInfoStatus?: number;
  /** Overrides the single MediaSource PlaybackInfo answers with. */
  mediaSource?: (itemId: string, body: any) => any;
}

/** The transcode address the mock server hands out for an item at a bitrate. */
export function transcodeUrl(itemId: string, bitrate: number): string {
  return `/videos/${itemId}/master.m3u8?VideoBitrate=${bitrate}&SegmentContainer=ts`;
}

/**
 * A small Jellyfin: PlaybackInfo (a direct-playable source, with a transcode
 * address when direct play was switched off), seasons, episodes and items.
 */
export function mockServer(opts: ServerOptions = {}): void {
  mockJellyfin([
    [
      /^\/Items\/[^/]+\/PlaybackInfo/,
      (a: JfArgs) => {
        if (opts.playbackInfoStatus) return { __status: opts.playbackInfoStatus, body: null };
        const itemId = a.path.split("/")[2]!;
        const direct = a.body.EnableDirectPlay !== false;
        const ms = opts.mediaSource
          ? opts.mediaSource(itemId, a.body)
          : {
              Id: `ms-${itemId}`,
              Container: "mkv",
              SupportsDirectPlay: true,
              SupportsDirectStream: true,
              ...(direct ? {} : { TranscodingUrl: transcodeUrl(itemId, a.body.MaxStreamingBitrate) }),
            };
        return { PlaySessionId: `ps-${itemId}`, MediaSources: [ms] };
      },
    ],
    [
      /^\/Shows\/[^/]+\/Seasons/,
      (a: JfArgs) => {
        const series = a.path.split("/")[2]!;
        return { Items: Object.keys(opts.shows?.[series] ?? {}).map((Id) => ({ Id, Type: "Season", SeriesId: series })) };
      },
    ],
    [
      /^\/Shows\/[^/]+\/Episodes/,
      (a: JfArgs) => {
        const series = a.path.split("/")[2]!;
        const season = new URLSearchParams(a.path.split("?")[1]).get("seasonId") ?? "";
        return { Items: opts.shows?.[series]?.[season] ?? [] };
      },
    ],
    [
      /^\/Items\/[^/?]+\?/,
      (a: JfArgs) => {
        const id = a.path.split("/")[2]!.split("?")[0]!;
        return opts.items?.[id] ?? { __status: 404 };
      },
    ],
  ]);
}

// ---------- Things to play ----------

export function movie(id = "m1", extra: Record<string, any> = {}): any {
  return { Id: id, Type: "Movie", Name: `Film ${id}`, ...extra };
}

export function episode(id: string, n: number, extra: Record<string, any> = {}): any {
  return {
    Id: id,
    Type: "Episode",
    Name: `Episode ${n}`,
    SeriesId: "show",
    SeriesName: "The Show",
    SeasonId: "s1",
    ParentIndexNumber: 1,
    IndexNumber: n,
    ...extra,
  };
}

/** A finished download's meta.json record. */
export function download(itemId: string, extra: Record<string, any> = {}): any {
  return {
    item_id: itemId,
    status: "complete",
    path: `/downloads/${itemId}.mkv`,
    title: `Download ${itemId}`,
    type: "Movie",
    ...extra,
  };
}

// ---------- Reading what happened ----------

export function toasts(): string[] {
  return [...document.querySelectorAll("#toasts .toast")].map((t) => t.textContent ?? "");
}

export function errorToasts(): string[] {
  return [...document.querySelectorAll("#toasts .toast.error")].map((t) => t.textContent ?? "");
}

export function dialog(): HTMLElement | null {
  return document.querySelector<HTMLElement>(".dialog");
}

export function dialogButtons(): string[] {
  return [...document.querySelectorAll(".dialog .dialog-actions button")].map((b) => b.textContent ?? "");
}

export function clickDialog(label: string | RegExp): void {
  const b = [...document.querySelectorAll<HTMLButtonElement>(".dialog .dialog-actions button")].find((x) =>
    typeof label === "string" ? x.textContent === label : label.test(x.textContent ?? "")
  );
  if (!b) throw new Error(`no dialog button ${label}; have ${dialogButtons().join(" | ")}`);
  b.click();
}

/** Every `player_play` request so far. */
export function plays(): any[] {
  return invokeCalls("player_play").map((c) => c.args.req);
}

export function lastPlay(): any {
  const all = plays();
  return all[all.length - 1];
}

/** Every PlaybackInfo request body so far, with the item it was for. */
export function playbackInfos(): Array<{ itemId: string; body: any }> {
  return invokeCalls("jf_request")
    .filter((c) => /\/PlaybackInfo/.test(c.args.path))
    .map((c) => ({ itemId: c.args.path.split("/")[2], body: c.args.body }));
}

/** Names of the document events dispatched while `fn` runs (and after, until read). */
export function recordEvents(...names: string[]): Array<{ type: string; detail: any }> {
  const seen: Array<{ type: string; detail: any }> = [];
  for (const n of names) {
    document.addEventListener(n, (ev) => seen.push({ type: n, detail: (ev as CustomEvent).detail }));
  }
  return seen;
}

/** A `player-status` tick, as player.rs emits it. */
export function status(fields: Record<string, any>): void {
  emitEvent("player-status", { active: true, ...fields });
}

/** Let promise chains settle without moving the clock. */
export async function settle(): Promise<void> {
  await vi.advanceTimersByTimeAsync(0);
  for (let i = 0; i < 20; i++) await Promise.resolve();
}
