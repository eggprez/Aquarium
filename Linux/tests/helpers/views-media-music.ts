// Shared pieces for the music and audiobook page tests (views-music*,
// views-books): a stand-in for src/audio.ts, a router for the music queries
// the real src/musicApi.ts makes, item fixtures, and the CSS check for
// animations that never stop.
//
// The stand-in for audio.ts exists because the real one drives mpv through the
// backend; what these pages owe it is the right list, index and options, and
// they read its state (current song, queue, status) to draw. Each test file
// mocks the module with `fakeAudioModule()` and reaches the state through
// `(await import("../../src/audio")).__st`, which is the copy the views use.
import { vi } from "vitest";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { mockJellyfin, type JfArgs } from "./tauri";

export const TICKS_PER_SEC = 10_000_000;

export interface FakeAudioState {
  status: {
    active: boolean;
    paused: boolean;
    position: number;
    duration: number;
    item_id: string;
    volume: number;
    mute: boolean;
    speed: number;
    buffering: boolean;
  };
  q: {
    items: any[];
    original: any[] | null;
    index: number;
    title: string;
    repeat: "off" | "all" | "one";
    source: any;
    book: boolean;
    offlineMix: boolean;
  };
  chapter: { name: string; index: number; start: number; end: number } | null;
  sleep: { mode: "off" | "time" | "track"; at: number };
  speed: number;
  soundCheck: boolean;
}

function freshState(): FakeAudioState {
  return {
    status: { active: false, paused: false, position: 0, duration: 0, item_id: "", volume: 100, mute: false, speed: 1, buffering: false },
    q: { items: [], original: null, index: -1, title: "", repeat: "off", source: null, book: false, offlineMix: false },
    chapter: null,
    sleep: { mode: "off", at: 0 },
    speed: 1,
    soundCheck: false,
  };
}

/** A module shaped like src/audio.ts whose commands are spies and whose
 *  reads come from `__st`. */
export function fakeAudioModule() {
  const listeners = new Set<() => void>();
  const st: FakeAudioState = freshState();
  const emit = (): void => {
    for (const fn of [...listeners]) fn();
  };
  const cmd = () => vi.fn(async (..._a: any[]): Promise<any> => {});
  const mod = {
    __st: st,
    __listeners: listeners,
    /** Back to nothing playing, with no listeners and no calls recorded. */
    __reset(): void {
      Object.assign(st, freshState());
      listeners.clear();
    },
    /** Make `items[index]` the playing song and tell the listeners. */
    __playing(items: any[], index = 0, extra: Partial<FakeAudioState["q"]> = {}, status: Partial<FakeAudioState["status"]> = {}): void {
      Object.assign(st.q, { items, index, ...extra });
      Object.assign(st.status, { active: true, item_id: items[index]?.Id ?? "", ...status });
      emit();
    },
    __emit: emit,
    onChange: vi.fn((fn: () => void) => {
      listeners.add(fn);
      return () => listeners.delete(fn);
    }),
    getStatus: () => st.status,
    isActive: () => st.status.active && st.q.index >= 0,
    current: () => st.q.items[st.q.index] ?? null,
    queueState: () => st.q,
    upNext: () => st.q.items.slice(st.q.index + 1),
    isShuffled: () => st.q.original != null,
    currentChapter: () => st.chapter,
    play: cmd(),
    replaceUpNext: cmd(),
    playNext: cmd(),
    playLater: cmd(),
    next: cmd(),
    previous: cmd(),
    jump: cmd(),
    stop: cmd(),
    removeAt: cmd(),
    move: cmd(),
    clearUpNext: cmd(),
    setShuffle: cmd(),
    cycleRepeat: cmd(),
    togglePause: cmd(),
    seek: cmd(),
    skip: cmd(),
    setVolume: cmd(),
    setMute: cmd(),
    BOOK_SPEEDS: [0.75, 1, 1.1, 1.25, 1.5, 1.75, 2],
    bookSpeed: () => st.speed,
    setSpeed: vi.fn(async (s: number) => {
      st.speed = s;
    }),
    setSoundCheck: vi.fn(async (on: boolean) => {
      st.soundCheck = on;
    }),
    soundCheckOn: () => st.soundCheck,
    sleepState: () => st.sleep,
    setSleep: cmd(),
    wireAudio: cmd(),
  };
  return mod;
}

export type FakeAudio = ReturnType<typeof fakeAudioModule>;

// ---------- Fixtures ----------

export function song(id: string, extra: Record<string, any> = {}): any {
  return {
    Id: id,
    Type: "Audio",
    Name: `Song ${id}`,
    Album: "The Album",
    AlbumId: "al1",
    AlbumArtist: "The Band",
    AlbumArtists: [{ Id: "ar1", Name: "The Band" }],
    ArtistItems: [{ Id: "ar1", Name: "The Band" }],
    RunTimeTicks: 200 * TICKS_PER_SEC,
    IndexNumber: 1,
    Genres: ["Rock"],
    ImageTags: {},
    UserData: {},
    ...extra,
  };
}

export function album(id: string, extra: Record<string, any> = {}): any {
  return {
    Id: id,
    Type: "MusicAlbum",
    Name: `Album ${id}`,
    AlbumArtist: "The Band",
    AlbumArtists: [{ Id: "ar1", Name: "The Band" }],
    ProductionYear: 2001,
    Genres: ["Rock"],
    ImageTags: { Primary: `t-${id}` },
    UserData: {},
    ...extra,
  };
}

export function artist(id: string, extra: Record<string, any> = {}): any {
  return { Id: id, Type: "MusicArtist", Name: `Artist ${id}`, ImageTags: {}, UserData: {}, ...extra };
}

export function playlist(id: string, extra: Record<string, any> = {}): any {
  return { Id: id, Type: "Playlist", Name: `List ${id}`, MediaType: "Audio", ChildCount: 2, ImageTags: {}, UserData: {}, ...extra };
}

export function book(id: string, extra: Record<string, any> = {}): any {
  return {
    Id: id,
    Type: "AudioBook",
    Name: `Book ${id}`,
    AlbumArtist: "Ann Author",
    AlbumArtists: [{ Id: "au1", Name: "Ann Author" }],
    RunTimeTicks: 3600 * TICKS_PER_SEC,
    ImageTags: {},
    UserData: {},
    ...extra,
  };
}

// ---------- The server ----------

/** The query of a request, as a map. */
export function query(path: string): URLSearchParams {
  return new URLSearchParams(path.split("?")[1] ?? "");
}

type Route = [string | RegExp, any];

/**
 * Route the music queries. `items(q, args)` answers `/Items?…` (the list
 * query musicApi's `music()` makes) with a list or a `{ Items,
 * TotalRecordCount }`; anything else goes through `extra` first.
 */
export function musicServer(opts: {
  items?: (q: URLSearchParams, a: JfArgs) => any;
  item?: (id: string, a: JfArgs) => any;
  extra?: Route[];
}): void {
  const wrap = (v: any): any => (Array.isArray(v) ? { Items: v, TotalRecordCount: v.length } : v);
  mockJellyfin([
    ...(opts.extra ?? []),
    [/^\/Items\?/, (a: JfArgs) => wrap(opts.items ? opts.items(query(a.path), a) : [])],
    [
      /^\/Items\/[^/?]+\?/,
      (a: JfArgs) => {
        const id = /^\/Items\/([^/?]+)/.exec(a.path)![1]!;
        return opts.item ? opts.item(id, a) : { __status: 404 };
      },
    ],
  ]);
}

// ---------- CSS ----------

/** Every selector that the app's stylesheets give an animation repeating
 *  forever (`infinite`), so a test can check none of them is on screen. */
export function infiniteAnimationSelectors(): string[] {
  const out: string[] = [];
  for (const file of ["src/styles.css", "src/music.css"]) {
    const css = readFileSync(resolve(__dirname, "../..", file), "utf8").replace(/\/\*[\s\S]*?\*\//g, "");
    const rule = /([^{}]+)\{([^{}]*)\}/g;
    let m: RegExpExecArray | null;
    while ((m = rule.exec(css))) {
      const decls = m[2]!;
      if (/animation(-iteration-count)?\s*:[^;]*\binfinite\b/.test(decls)) {
        out.push(...m[1]!.split(",").map((s) => s.trim()).filter(Boolean));
      }
    }
  }
  return out;
}

/** Elements under `root` that one of those selectors matches. */
export function foreverAnimated(root: ParentNode): Element[] {
  const hits: Element[] = [];
  for (const sel of infiniteAnimationSelectors()) {
    // At-rule fragments (`@media …`) are not selectors.
    if (sel.startsWith("@")) continue;
    try {
      hits.push(...Array.from(root.querySelectorAll(sel.replace(/::?[a-z-]+(\([^)]*\))?$/i, ""))));
    } catch {
      // A selector jsdom can't parse is not one these views can match.
    }
  }
  return hits;
}

/** The only animated classes these views may put up while they wait: the
 *  spinner and the skeleton sweep, each of which the stylesheet runs a fixed
 *  number of times. */
export function finiteIterations(selector: ".spinner" | ".sk-box"): number | null {
  const css = readFileSync(resolve(__dirname, "../../src/styles.css"), "utf8").replace(/\/\*[\s\S]*?\*\//g, "");
  const re = new RegExp(`(^|\\})\\s*${selector.replace(".", "\\.")}[^{]*\\{([^}]*)\\}`, "m");
  const m = re.exec(css);
  const anim = m ? /animation\s*:([^;]+);/.exec(m[2]!)?.[1] : undefined;
  if (!anim) return null;
  const n = /\s(\d+)\s*$/.exec(anim.trim());
  return n ? Number(n[1]) : null;
}
