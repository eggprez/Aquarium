// Boots the real app shell (src/main.ts, which runs on import) inside jsdom.
//
//   const shell = await bootShell();            // signed in, server reachable
//   await shell.go("#/settings");
//   await shell.play(EPISODE);                  // nowPlaying + an active status
//   shell.status({ position: 30 });             // the next player-status tick
//   key(" "); expect(invokeCalls("player_pause_toggle")).toHaveLength(1);
//
// main.ts registers listeners on `document` and `window` that would outlive the
// test (jsdom keeps one document per file), so everything it registers while a
// shell is up is recorded and removed again by `teardownShell()`, which every
// main-*.test.ts calls from `afterEach`.
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { vi } from "vitest";
import { IDBFactory } from "fake-indexeddb";
import {
  coreModule,
  eventModule,
  emitEvent,
  flush,
  invokeCalls,
  invokeHandler,
  mockJellyfin,
  onAnyInvoke,
  onInvoke,
  onInvokes,
  signedInConfig,
  waitFor,
} from "./tauri";

const INDEX_HTML = readFileSync(resolve(__dirname, "../../index.html"), "utf8");

/** The `<body>` of index.html, without its script tag. */
export function indexBody(): string {
  const body = /<body>([\s\S]*)<\/body>/.exec(INDEX_HTML)?.[1] ?? "";
  return body.replace(/<script[\s\S]*?<\/script>/g, "");
}

/** The stand-in for `getCurrentWindow()` (the Tauri window API). */
export const win = {
  fullscreen: false,
  setFullscreen: vi.fn(async (on: boolean) => {
    win.fullscreen = on;
  }),
  isFullscreen: vi.fn(async () => win.fullscreen),
};

interface Registered {
  target: EventTarget;
  type: string;
  fn: any;
  opts: any;
}

let registered: Registered[] = [];
let originalAdd: Array<[EventTarget, any]> = [];
let timers: { timeouts: Set<any>; intervals: Set<any> } | null = null;
let realTimers: { setTimeout: any; setInterval: any } | null = null;

function trackListeners(): void {
  for (const target of [document, window] as EventTarget[]) {
    const add = target.addEventListener;
    originalAdd.push([target, add]);
    (target as any).addEventListener = function (type: string, fn: any, opts: any) {
      registered.push({ target, type, fn, opts });
      return add.call(target, type, fn, opts);
    };
  }
}

function trackTimers(): void {
  const st = window.setTimeout;
  const si = window.setInterval;
  realTimers = { setTimeout: st, setInterval: si };
  const mine = { timeouts: new Set<any>(), intervals: new Set<any>() };
  timers = mine;
  const wrappedTimeout: any = (fn: any, ms?: number, ...rest: any[]) => {
    const id = st(fn, ms, ...rest);
    mine.timeouts.add(id);
    return id;
  };
  const wrappedInterval: any = (fn: any, ms?: number, ...rest: any[]) => {
    const id = si(fn, ms, ...rest);
    mine.intervals.add(id);
    return id;
  };
  window.setTimeout = wrappedTimeout;
  window.setInterval = wrappedInterval;
  globalThis.setTimeout = wrappedTimeout;
  globalThis.setInterval = wrappedInterval;
}

/** Undo everything a booted shell left on the shared document and window. */
export function teardownShell(): void {
  vi.useRealTimers();
  for (const r of registered) r.target.removeEventListener(r.type, r.fn, r.opts);
  registered = [];
  for (const [target, add] of originalAdd) (target as any).addEventListener = add;
  originalAdd = [];
  if (timers && realTimers) {
    for (const id of timers.timeouts) clearTimeout(id);
    for (const id of timers.intervals) clearInterval(id);
    window.setTimeout = realTimers.setTimeout;
    window.setInterval = realTimers.setInterval;
    globalThis.setTimeout = realTimers.setTimeout;
    globalThis.setInterval = realTimers.setInterval;
  }
  timers = null;
  realTimers = null;
  document.body.className = "";
  history.replaceState(null, "", "/");
  vi.doUnmock("@tauri-apps/api/window");
  for (const path of VIEW_MODULES) vi.doUnmock(path);
  hidden(false);
}

const VIEW_MODULES = [
  "../../src/views/home",
  "../../src/views/library",
  "../../src/views/favorites",
  "../../src/views/item",
  "../../src/views/livetv",
  "../../src/views/downloads",
  "../../src/views/settings",
  "../../src/views/requests",
  "../../src/views/music",
  "../../src/views/books",
  "../../src/views/musicPlayer",
];

/** The page renderers, replaced by recording stand-ins (see `realViews`). */
export interface ViewStubs {
  home: ReturnType<typeof vi.fn>;
  library: ReturnType<typeof vi.fn>;
  search: ReturnType<typeof vi.fn>;
  favorites: ReturnType<typeof vi.fn>;
  item: ReturnType<typeof vi.fn>;
  livetv: ReturnType<typeof vi.fn>;
  downloads: ReturnType<typeof vi.fn>;
  downloadProgress: ReturnType<typeof vi.fn>;
  settings: ReturnType<typeof vi.fn>;
  music: ReturnType<typeof vi.fn>;
  books: ReturnType<typeof vi.fn>;
  requests: ReturnType<typeof vi.fn>;
  request: ReturnType<typeof vi.fn>;
  musicPlayer: ReturnType<typeof vi.fn>;
}

/** Each stand-in draws `<div data-view="name" data-arg="arg">` into the page. */
function stubViews(): ViewStubs {
  const page = (name: string) =>
    vi.fn(async (root: HTMLElement, arg?: unknown) => {
      root.innerHTML = "";
      const div = document.createElement("div");
      div.dataset.view = name;
      div.dataset.arg = typeof arg === "string" ? arg : "";
      root.append(div);
    });
  const stubs: ViewStubs = {
    home: page("home"),
    library: page("library"),
    search: page("search"),
    favorites: page("favorites"),
    item: page("item"),
    livetv: page("livetv"),
    downloads: page("downloads"),
    downloadProgress: vi.fn(),
    settings: page("settings"),
    music: page("music"),
    books: page("books"),
    requests: page("requests"),
    request: page("request"),
    musicPlayer: vi.fn(async () => {}),
  };
  vi.doMock("../../src/views/home", () => ({ renderHome: stubs.home }));
  vi.doMock("../../src/views/library", () => ({ renderLibrary: stubs.library, renderSearch: stubs.search }));
  vi.doMock("../../src/views/favorites", () => ({ renderFavorites: stubs.favorites }));
  vi.doMock("../../src/views/item", () => ({ renderItem: stubs.item, fetchItemData: vi.fn(async () => null) }));
  vi.doMock("../../src/views/livetv", () => ({ renderLiveTv: stubs.livetv }));
  vi.doMock("../../src/views/downloads", () => ({
    renderDownloads: stubs.downloads,
    updateDownloadProgress: stubs.downloadProgress,
  }));
  vi.doMock("../../src/views/settings", () => ({ renderSettings: stubs.settings }));
  vi.doMock("../../src/views/music", () => ({ renderMusic: stubs.music }));
  vi.doMock("../../src/views/books", () => ({ renderBooks: stubs.books }));
  vi.doMock("../../src/views/requests", () => ({ renderRequests: stubs.requests, renderRequestTitle: stubs.request }));
  vi.doMock("../../src/views/musicPlayer", () => ({ wireMusicPlayer: stubs.musicPlayer }));
  return stubs;
}

/** The page the router last drew, as "name" or "name:arg" (stubbed views). */
export function page(): string {
  const div = document.querySelector<HTMLElement>("#content [data-view]");
  if (!div) return "";
  return div.dataset.arg ? `${div.dataset.view}:${div.dataset.arg}` : String(div.dataset.view);
}

/** Make `document.hidden` say `value` (jsdom has no window manager). */
export function hidden(value: boolean): void {
  Object.defineProperty(document, "hidden", { configurable: true, get: () => value });
}

/** Fake the clock and timers, leaving promises and IndexedDB alone. */
export function fakeTimers(): void {
  vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout", "setInterval", "clearInterval", "Date"] });
}

export interface BootOptions {
  /** A saved session (default) or the sign-in screen. */
  signedIn?: boolean;
  /** Extra config keys, as `config_load` returns them. */
  config?: Record<string, any>;
  /** What `jf_ping` answers: reachable (default), not, or a thrown error. */
  ping?: boolean | (() => any);
  /** The server's libraries (`/UserViews`); a function may throw. */
  libraries?: any[] | (() => any);
  /** Use the real page renderers instead of the recording stand-ins. */
  realViews?: boolean;
  /** Jellyfin routes tried before the defaults (see `mockJellyfin`). */
  routes?: Array<[string | RegExp, any]>;
  /** `location.hash` at launch ("" is a cold start). */
  hash?: string;
  /** Commands answered before the catch-all. */
  invokes?: Record<string, any>;
  /** Finished and running downloads (`downloads_list`). */
  downloads?: any[];
  /** Watch progress waiting to be pushed (`progress_pending`). */
  pending?: number;
  /** Keep the IndexedDB screen cache the last shell in this test wrote. */
  keepCache?: boolean;
}

export const VIEWS = [
  { Id: "lib-movies", Name: "Films", CollectionType: "movies" },
  { Id: "lib-shows", Name: "Shows", CollectionType: "tvshows" },
];

export interface Shell {
  /** The config object the bridge serves; mutate it to change later loads. */
  cfg: Record<string, any>;
  /** The recording page renderers (absent with `realViews`). */
  views: ViewStubs;
  playback: typeof import("../../src/playback");
  api: typeof import("../../src/api");
  /** Navigate and wait for the router to have drawn the page. */
  go(hash: string): Promise<void>;
  /** Send a player-status tick (merged over the last one sent). */
  status(patch?: Record<string, any>): void;
  /** Start a server item through playback.ts and report it as playing. */
  play(item: any, status?: Record<string, any>, opts?: Record<string, any>): Promise<void>;
  /** Start a downloaded file and report it as playing. */
  playLocal(dl: any, status?: Record<string, any>, serverItem?: any): Promise<void>;
  /** Start a custom-playlist channel and report it as playing. */
  playChannel(ch: any, status?: Record<string, any>): Promise<void>;
  /** Playback ended; the bar tears down. */
  stop(patch?: Record<string, any>): void;
}

/** Let real macrotasks run (IndexedDB, jsdom's hashchange, chained awaits). */
export async function settle(turns = 6): Promise<void> {
  for (let i = 0; i < turns; i++) await new Promise((r) => setTimeout(r, 0));
}

const $ = (id: string): HTMLElement => document.getElementById(id)!;

export async function bootShell(opts: BootOptions = {}): Promise<Shell> {
  vi.resetModules();
  win.fullscreen = false;
  win.setFullscreen.mockClear();
  win.isFullscreen.mockClear();
  vi.doMock("@tauri-apps/api/window", () => ({ getCurrentWindow: () => win }));
  // After `resetModules` the setup file's mock factory would import a second
  // copy of helpers/tauri.ts; pin the bridge to the copy the tests hold.
  vi.doMock("@tauri-apps/api/core", () => coreModule);
  vi.doMock("@tauri-apps/api/event", () => eventModule);

  const views = opts.realViews ? null : stubViews();
  // Each shell starts with nothing on disk unless the test asks to keep it.
  if (!opts.keepCache) (globalThis as any).indexedDB = new IDBFactory();

  document.body.innerHTML = indexBody();
  history.replaceState(null, "", "/" + (opts.hash ?? ""));
  trackListeners();
  trackTimers();

  const signedIn = opts.signedIn ?? true;
  const cfg: Record<string, any> = signedIn
    ? signedInConfig(opts.config ?? {})
    : { device_id: "device-1", ...(opts.config ?? {}) };

  // Anything not named answers null, and is still recorded for `invokeCalls`.
  onAnyInvoke(() => null);
  onInvokes({
    config_load: () => ({ ...cfg }),
    config_save: (a: { cfg: Record<string, any> }) => {
      Object.assign(cfg, a.cfg);
      return null;
    },
    jf_ping: () => {
      const p = opts.ping ?? true;
      return typeof p === "function" ? p() : p;
    },
    app_info: { version: "9.9.9", mpv: "mpv 0.41" },
    progress_pending: () => opts.pending ?? 0,
    downloads_list: () => opts.downloads ?? [],
    accounts_list: [],
    system_color_scheme: "dark",
    network_metered: false,
    disk_free: 500_000_000_000,
    player_set_pip: (a: { on: boolean }) => a.on,
    player_get_properties: {},
    jf_discover: [],
    jf_bitrate_test: null,
    ...(opts.invokes ?? {}),
  });
  mockJellyfin([
    ...(opts.routes ?? []),
    [
      "/UserViews",
      () => {
        const l = opts.libraries ?? VIEWS;
        return { Items: typeof l === "function" ? l() : l };
      },
    ],
    [/.*/, { Items: [], TotalRecordCount: 0 }],
  ]);
  // An unreachable server fails requests too, as server.rs reports it: any
  // request that succeeded would (rightly) flip the app back online.
  {
    const routed = invokeHandler("jf_request");
    onInvoke("jf_request", async (a: any) => {
      const p = opts.ping ?? true;
      let up: any;
      try {
        up = typeof p === "function" ? await p() : p;
      } catch {
        up = false;
      }
      if (up === false) throw new Error("offline|Can't reach the server");
      return routed!(a, "jf_request");
    });
  }

  await import("../../src/main");
  const want = signedIn ? "shell" : "login-root";
  await waitFor(() => !$(want).classList.contains("hidden"), 5000);
  await settle();

  const playback = await import("../../src/playback");
  const api = await import("../../src/api");

  let last: Record<string, any> = {};
  const shell: Shell = {
    cfg,
    views: views as ViewStubs,
    playback,
    api,
    async go(hash) {
      location.hash = hash;
      await settle();
    },
    status(patch = {}) {
      last = { active: true, embedded: true, paused: false, position: 0, duration: 0, title: "", ...last, ...patch };
      emitEvent("player-status", { ...last });
    },
    async play(item, status = {}, playOpts = { maxBitrate: undefined }) {
      // `stream: true` skips the bandwidth probe; the source is PlaybackInfo's.
      await playback.playItem(item, playOpts, { stream: true, quiet: true });
      last = {};
      shell.status({ item_id: item.Id, title: playback.itemTitle(item), duration: 1500, ...status });
      await flush();
    },
    async playLocal(dl, status = {}, serverItem) {
      await playback.playLocal(dl, serverItem ? { serverItem } : {});
      last = {};
      shell.status({ item_id: dl.item_id, title: dl.title ?? dl.name ?? "", duration: 1500, ...status });
      await flush();
    },
    async playChannel(ch, status = {}) {
      onInvoke("resolve_stream", (a: { url: string }) => a.url);
      await playback.playChannelUrl(ch, { quiet: true });
      last = {};
      shell.status({ item_id: ch.Id, title: ch.Name, duration: 0, ...status });
      await flush();
    },
    stop(patch = {}) {
      last = {};
      emitEvent("player-status", { active: false, ended: false, requested_stop: true, ...patch });
    },
  };
  return shell;
}

/** A PlaybackInfo answer that direct-plays `id`. */
export function playbackInfo(id: string, extra: Record<string, any> = {}): any {
  return {
    PlaySessionId: "ps-1",
    MediaSources: [
      { Id: id, Container: "mkv", SupportsDirectPlay: true, SupportsDirectStream: true, Bitrate: 8_000_000, ...extra },
    ],
  };
}

export const EPISODE = {
  Id: "ep-2",
  Type: "Episode",
  Name: "The Second One",
  SeriesName: "Archer",
  SeriesId: "series-1",
  SeasonId: "season-1",
  SeasonName: "Season 1",
  ParentIndexNumber: 1,
  IndexNumber: 2,
  RunTimeTicks: 15_000_000_000,
};

export const MOVIE = { Id: "movie-1", Type: "Movie", Name: "Heat", RunTimeTicks: 60_000_000_000 };

export const CHANNEL = { Id: "ch-1", Type: "TvChannel", Name: "News One", ChannelNumber: "5", StreamUrl: "http://tv.test/5.m3u8" };

// ---------- DOM drivers ----------

export function click(target: Element | string, init: MouseEventInit = {}): void {
  const node = typeof target === "string" ? document.querySelector(target) : target;
  if (!node) throw new Error(`click: nothing matches ${String(target)}`);
  node.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true, detail: 1, ...init }));
}

/** A key press on `target` (the document body unless told otherwise). */
export function key(k: string, init: KeyboardEventInit = {}, target: Element | Document = document.body): KeyboardEvent {
  const ev = new KeyboardEvent("keydown", { key: k, bubbles: true, cancelable: true, ...init });
  target.dispatchEvent(ev);
  return ev;
}

/** A pointer move at client coordinates, on `target` (bubbles to document). */
export function mouseMove(x: number, y: number, target: Element | Document = document.body): void {
  target.dispatchEvent(new MouseEvent("mousemove", { bubbles: true, clientX: x, clientY: y }));
}

/** mouseenter/mouseleave do not bubble; dispatch on the element itself. */
export function mouseLeave(target: Element): void {
  target.dispatchEvent(new MouseEvent("mouseleave", { bubbles: false }));
}

/** The bar button whose label is `text`, inside the open panel (or `root`). */
export function buttonNamed(text: string, root: ParentNode = document): HTMLButtonElement {
  const hit = [...root.querySelectorAll("button")].find((b) => b.textContent?.trim() === text);
  if (!hit) throw new Error(`no button named "${text}"`);
  return hit as HTMLButtonElement;
}

export function panel(): HTMLElement | null {
  return document.querySelector("#player-bar .pb-panel");
}

/** Every toast on screen, as text. */
export function toasts(): string[] {
  return [...document.querySelectorAll("#toasts > *")].map((t) => t.textContent ?? "");
}

/** `player_mpv_command` calls as their `cmd` arrays. */
export function mpvCommands(): any[][] {
  return invokeCalls("player_mpv_command").map((c) => c.args.cmd);
}

/** The values a property was set to through `player_mpv_command`. */
export function propSets(name: string): any[] {
  return mpvCommands()
    .filter((c) => c[0] === "set_property" && c[1] === name)
    .map((c) => c[2]);
}

// ---------- A world with something to play ----------

export const EP1 = { ...EPISODE, Id: "ep-1", Name: "The First One", IndexNumber: 1, UserData: { Played: true } };
export const EP3 = {
  ...EPISODE,
  Id: "ep-3",
  Name: "The Third One",
  IndexNumber: 3,
  RunTimeTicks: 13_200_000_000,
  ImageTags: { Primary: "p3" },
};
export const EP4 = { ...EPISODE, Id: "ep-4", Name: undefined, IndexNumber: undefined, RunTimeTicks: 0 };
/** Season 1 of series-1, with EPISODE second. */
export const SEASON = [EP1, EPISODE, EP3, EP4];

export interface PlayWorld extends BootOptions {
  /** Episodes of series-1 season-1 (a function may throw or hang). */
  episodes?: any[] | (() => any);
  /** MediaSegments answer. */
  segments?: any[];
  /** The Trickplay answer for the playing item. */
  trickplay?: any;
}

/** The Jellyfin routes a playing episode needs: PlaybackInfo for any item,
 *  its season, its segments and its trickplay. */
export function playRoutes(w: PlayWorld): Array<[string | RegExp, any]> {
  return [
    ...(w.routes ?? []),
    [/\/Items\/([^/]+)\/PlaybackInfo/, (a: any) => playbackInfo(/\/Items\/([^/]+)\//.exec(a.path)![1]!)],
    [
      /\/Shows\/series-1\/Episodes/,
      () => {
        const e = w.episodes ?? SEASON;
        return { Items: typeof e === "function" ? e() : e };
      },
    ],
    [/\/Shows\/series-1\/Seasons/, { Items: [{ Id: "season-1" }] }],
    [/\/MediaSegments\//, { Items: w.segments ?? [] }],
    [/\/Items\/[^/?]+\?.*Trickplay/, w.trickplay ?? {}],
  ];
}

/** A shell whose server can play SEASON. */
export async function bootPlayer(w: PlayWorld = {}): Promise<Shell> {
  return bootShell({ ...w, routes: playRoutes(w) });
}

/** A shell with `item` (EPISODE by default) playing, two status ticks in:
 *  the second arrives after the item's extras (segments, the next episode)
 *  have been looked up, as it would a second later in the app. */
export async function startPlaying(w: PlayWorld = {}, status: Record<string, any> = {}, item: any = EPISODE): Promise<Shell> {
  const shell = await bootPlayer(w);
  await shell.play(item, status);
  await settle();
  shell.status();
  return shell;
}

/** mpv's track list, as `player-tracks` delivers it. */
export function sendTracks(list: any[]): void {
  emitEvent("player-tracks", list);
}
