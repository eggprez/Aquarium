// Shared fixtures and page-driving helpers for the item (detail) page tests.
//
// The page is rendered by the real `src/views/item.ts` on top of the real
// `src/api.ts`, `src/cache.ts` and `src/ui.ts`; only the Tauri bridge is a
// stand-in (and, in the test files, the four playback entry points that would
// otherwise start libmpv or the download queue).
import { mockJellyfin, signIn, type JfArgs } from "./tauri";

/** Jellyfin counts time in 100 ns ticks. */
export const MINUTE = 600_000_000;
export const HOUR = 60 * MINUTE;

export function deferred<T = any>(): {
  promise: Promise<T>;
  resolve: (v: T) => void;
  reject: (e: any) => void;
} {
  let resolve!: (v: T) => void;
  let reject!: (e: any) => void;
  const promise = new Promise<T>((a, b) => {
    resolve = a;
    reject = b;
  });
  return { promise, resolve, reject };
}

export function movie(extra: Record<string, any> = {}): any {
  return {
    Id: "m1",
    Type: "Movie",
    Name: "Big Film",
    ProductionYear: 1999,
    RunTimeTicks: 2 * HOUR,
    OfficialRating: "PG",
    CommunityRating: 7.5,
    Genres: ["Drama", "Comedy", "Crime", "Mystery", "Western"],
    Overview: "A film about a test.",
    ImageTags: { Primary: "p1" },
    BackdropImageTags: ["b1"],
    UserData: {},
    People: [
      { Id: "d1", Name: "Dana Director", Type: "Director" },
      { Id: "w1", Name: "Will Writer", Type: "Writer" },
      { Id: "a1", Name: "Ann Actor", Type: "Actor", Role: "Hero", PrimaryImageTag: "pa1" },
      { Id: "g1", Name: "Guy Guest & Co", Type: "GuestStar" },
    ],
    MediaSources: [
      {
        Size: 8_000_000_000,
        MediaStreams: [
          { Type: "Video", Codec: "hevc", Width: 1920, Height: 1080 },
          { Type: "Audio", Codec: "eac3", Channels: 6 },
        ],
      },
    ],
    ...extra,
  };
}

export function series(extra: Record<string, any> = {}): any {
  return {
    Id: "s1",
    Type: "Series",
    Name: "The Show",
    ProductionYear: 2020,
    ImageTags: { Primary: "sp1" },
    BackdropImageTags: ["sb1"],
    UserData: {},
    People: [],
    ...extra,
  };
}

export function season(n: number, extra: Record<string, any> = {}): any {
  return { Id: `se${n}`, Type: "Season", Name: `Season ${n}`, IndexNumber: n, SeriesId: "s1", ...extra };
}

export function episode(s: number, e: number, extra: Record<string, any> = {}): any {
  return {
    Id: `e${s}-${e}`,
    Type: "Episode",
    Name: `Episode ${s}.${e}`,
    SeriesId: "s1",
    SeriesName: "The Show",
    SeasonId: `se${s}`,
    ParentIndexNumber: s,
    IndexNumber: e,
    RunTimeTicks: 45 * MINUTE,
    ImageTags: { Primary: `ep${s}${e}` },
    UserData: {},
    ...extra,
  };
}

type Answer = any | ((a: JfArgs) => any);

export interface ServerCfg {
  /** `/Items/<id>?…` — a value, or a function of the request. */
  item?: Answer;
  /** `/Items/<id>/Similar` — the list of items. */
  similar?: Answer;
  /** `/Shows/<id>/Seasons` — the list of seasons. */
  seasons?: Answer;
  /** `/Shows/NextUp` — one episode or null. */
  nextUp?: Answer;
  /** `/Shows/<id>/Episodes?seasonId=` — episodes by season id. */
  episodes?: Record<string, Answer>;
  /** POST/DELETE on `/UserPlayedItems` and `/UserFavoriteItems`. */
  userData?: Answer;
}

const answer = async (v: Answer, a: JfArgs): Promise<any> => (typeof v === "function" ? await v(a) : v);
const isStatus = (v: any): boolean => !!v && typeof v === "object" && "__status" in v;
/** Wrap a list as Jellyfin's `{ Items }`, leaving a `{ __status }` answer alone. */
const items = (v: any): any => (isStatus(v) ? v : { Items: v ?? [] });

/** Route `jf_request` the way the detail page asks for things. */
export function server(cfg: ServerCfg): void {
  mockJellyfin([
    [/^\/Items\/[^/?]+\/Similar/, async (a: JfArgs) => items(await answer(cfg.similar ?? [], a))],
    [/^\/Items\/[^/?]+\?/, (a: JfArgs) => answer(cfg.item, a)],
    [
      "/Shows/NextUp",
      async (a: JfArgs) => {
        const v = await answer(cfg.nextUp ?? null, a);
        return isStatus(v) ? v : { Items: v ? [v] : [] };
      },
    ],
    [/^\/Shows\/[^/]+\/Seasons/, async (a: JfArgs) => items(await answer(cfg.seasons ?? [], a))],
    [
      /^\/Shows\/[^/]+\/Episodes/,
      async (a: JfArgs) => {
        const id = /seasonId=([^&]+)/.exec(a.path)?.[1] ?? "";
        return items(await answer(cfg.episodes?.[id] ?? [], a));
      },
    ],
    [/^\/User(Played|Favorite)Items\//, (a: JfArgs) => answer(cfg.userData ?? {}, a)],
  ]);
}

/**
 * A signed-in app shell (`#toasts`, and `#content` holding the view's root),
 * the mock server, and freshly imported modules. Call after
 * `vi.resetModules()` so every test gets its own cache and in-flight map.
 */
export async function mount(cfg: ServerCfg = {}) {
  document.body.innerHTML = `<div id="toasts"></div><div id="content"><div id="root"></div></div>`;
  const api = await signIn();
  server(cfg);
  const view = await import("../../src/views/item");
  const playback = await import("../../src/playback");
  const cache = await import("../../src/cache");
  const ui = await import("../../src/ui");
  const root = document.getElementById("root")!;
  return { api, view, playback, cache, ui, root };
}

export const $ = <T extends HTMLElement = HTMLElement>(sel: string, from: ParentNode = document): T | null =>
  from.querySelector<T>(sel);

export const $$ = <T extends HTMLElement = HTMLElement>(sel: string, from: ParentNode = document): T[] =>
  Array.from(from.querySelectorAll<T>(sel));

/** The first button whose visible text contains `text`. */
export function button(text: string, from: ParentNode = document): HTMLButtonElement {
  const b = $$<HTMLButtonElement>("button", from).find((x) => (x.textContent ?? "").includes(text));
  if (!b) throw new Error(`no button containing "${text}"`);
  return b;
}

export function hasButton(text: string, from: ParentNode = document): boolean {
  return $$("button", from).some((x) => (x.textContent ?? "").includes(text));
}

/** The dropdown that is open now. */
export function menu(): HTMLElement {
  const m = $(".menu");
  if (!m) throw new Error("no menu is open");
  return m;
}

export const menuLabels = (): string[] => $$("button", menu()).map((b) => (b.textContent ?? "").trim());

export function rightClick(target: Element): void {
  target.dispatchEvent(new MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 10, clientY: 10 }));
}

export function key(target: Element, k: string): KeyboardEvent {
  const ev = new KeyboardEvent("keydown", { key: k, bubbles: true, cancelable: true });
  target.dispatchEvent(ev);
  return ev;
}

export const toasts = (): string[] => $$("#toasts .toast").map((t) => t.textContent ?? "");
