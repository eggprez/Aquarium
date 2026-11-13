// Favorites (src/views/favorites.ts): everything starred, by sort and type,
// paging, the cache-first paint with its freshness check, cards leaving when
// they are unstarred, and Home's Favorites row.
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { mockJellyfin, signIn, type JfArgs } from "../helpers/tauri";
import { byText, click, mountShell, pickMenu, rightClick, settle, texts } from "../helpers/views-media";
import { query } from "../helpers/views-media-music";

vi.mock("../../src/playback", async (importOriginal) => {
  const real = await importOriginal<typeof import("../../src/playback")>();
  return { ...real, playItem: vi.fn(async () => {}) };
});

type Fav = typeof import("../../src/views/favorites");

let fav: Fav;
let cache: typeof import("../../src/cache");
let root: HTMLElement;
let answer: (q: URLSearchParams) => any;
let writes: string[];
let observers: IntersectionObserverCallback[];
const RealIO = (globalThis as any).IntersectionObserver;

beforeEach(() => {
  vi.resetModules();
  vi.clearAllMocks();
  writes = [];
  observers = [];
  (globalThis as any).IntersectionObserver = class {
    constructor(cb: IntersectionObserverCallback) {
      observers.push(cb);
    }
    observe() {}
    disconnect() {}
  };
});
afterEach(() => {
  (globalThis as any).IntersectionObserver = RealIO;
  location.hash = "";
});

const star = (id: string, Type = "Movie") => ({ Id: id, Type, Name: `${Type} ${id}`, ImageTags: {}, UserData: { IsFavorite: true } });
const stars = (n: number, from = 0) => Array.from({ length: n }, (_, i) => star(`s${from + i}`));
const paged = (total: number, seen: URLSearchParams[] = []) => (q: URLSearchParams) => {
  seen.push(q);
  const from = Number(q.get("StartIndex"));
  return { Items: stars(Math.max(0, Math.min(Number(q.get("Limit")), total - from)), from), TotalRecordCount: total };
};

async function boot(): Promise<void> {
  root = mountShell();
  mockJellyfin([
    [/^\/UserFavoriteItems\//, (a: JfArgs) => (writes.push(`${a.method} ${a.path}`), {})],
    [/^\/Items\?/, (a: JfArgs) => answer(query(a.path))],
  ]);
  await signIn();
  cache = await import("../../src/cache");
  fav = await import("../../src/views/favorites");
}

const cards = () => texts(root, ".card-grid .card .card-title");
const typeBtn = (label: string) => byText<HTMLButtonElement>(root, ".filter-bar .btn", label)!;
const sortSel = () => root.querySelector<HTMLSelectElement>(".filter-bar select")!;

describe("the Favorites page", () => {
  it("lists every starred film, show and episode by title, with a count", async () => {
    const seen: URLSearchParams[] = [];
    answer = paged(2, seen);
    await boot();
    const p = fav.renderFavorites(root);
    expect(root.querySelectorAll(".card-grid > *").length).toBe(18);
    await p;
    expect(root.querySelector("h1.page-title")!.textContent).toBe("Favorites");
    expect(cards()).toEqual(["Movie s0", "Movie s1"]);
    expect(root.querySelector(".lib-count")!.textContent).toBe("2 items");
    const q = seen[0]!;
    expect(q.get("userId")).toBe("user-1");
    expect(q.get("Filters")).toBe("IsFavorite");
    expect(q.get("IncludeItemTypes")).toBe("Movie,Series,Episode");
    expect(q.get("SortBy")).toBe("SortName");
    expect(texts(root, ".filter-bar .btn")).toEqual(["All", "Movies", "TV Shows", "Episodes"]);
    expect(typeBtn("All").classList.contains("active")).toBe(true);
  });

  it("sorts and filters by one type at a time, remembering both", async () => {
    const seen: URLSearchParams[] = [];
    answer = paged(1, seen);
    await boot();
    await fav.renderFavorites(root);
    sortSel().value = "CommunityRating|Descending";
    sortSel().dispatchEvent(new Event("change"));
    await settle();
    expect(seen.at(-1)!.get("SortBy")).toBe("CommunityRating");
    expect(seen.at(-1)!.get("SortOrder")).toBe("Descending");
    click(typeBtn("TV Shows"));
    await settle();
    expect(seen.at(-1)!.get("IncludeItemTypes")).toBe("Series");
    expect(typeBtn("TV Shows").classList.contains("active")).toBe(true);
    expect(typeBtn("All").classList.contains("active")).toBe(false);
    // The type already chosen does nothing.
    const n = seen.length;
    click(typeBtn("TV Shows"));
    await settle();
    expect(seen).toHaveLength(n);
    expect(JSON.parse(localStorage.getItem("aquarium.favorites")!)).toEqual({ sort: "CommunityRating|Descending", type: "Series" });
    await fav.renderFavorites(root);
    expect(sortSel().value).toBe("CommunityRating|Descending");
    expect(typeBtn("TV Shows").classList.contains("active")).toBe(true);
  });

  it("ignores remembered settings it can't read or doesn't know, and works when they can't be saved", async () => {
    const seen: URLSearchParams[] = [];
    answer = paged(1, seen);
    await boot();
    localStorage.setItem("aquarium.favorites", "{nope");
    await fav.renderFavorites(root);
    expect(sortSel().value).toBe("SortName|Ascending");
    localStorage.setItem("aquarium.favorites", JSON.stringify({ sort: "X|Y", type: "Photo" }));
    await fav.renderFavorites(root);
    expect(typeBtn("All").classList.contains("active")).toBe(true);
    const spy = vi.spyOn(Storage.prototype, "setItem").mockImplementation(() => {
      throw new Error("quota");
    });
    try {
      click(typeBtn("Movies"));
      await settle();
    } finally {
      spy.mockRestore();
    }
    expect(seen.at(-1)!.get("IncludeItemTypes")).toBe("Movie");
  });

  it("pages with Load more and on scroll, swallowing extra requests while one is out", async () => {
    const seen: URLSearchParams[] = [];
    answer = paged(130, seen);
    await boot();
    await fav.renderFavorites(root);
    const more = root.querySelector<HTMLButtonElement>(".load-more .btn")!;
    click(more);
    click(more);
    expect(more.textContent).toBe("Loading…");
    await settle();
    observers.at(-1)!([{ isIntersecting: false } as any], null as any);
    observers.at(-1)!([{ isIntersecting: true } as any], null as any);
    await settle();
    observers.at(-1)!([{ isIntersecting: true } as any], null as any);
    await settle();
    expect(seen.map((q) => q.get("StartIndex"))).toEqual(["0", "60", "120"]);
    expect(cards()).toHaveLength(130);
    expect(root.querySelector<HTMLElement>(".load-more")!.style.display).toBe("none");
  });

  it("says nothing is starred yet, with a way to Home", async () => {
    answer = () => ({});
    await boot();
    await fav.renderFavorites(root);
    expect(root.querySelector(".state h3")!.textContent).toBe("Nothing starred yet");
    expect(root.querySelector(".lib-count")!.textContent).toBe("");
    click(byText(root, ".state button", "Browse Home"));
    expect(location.hash).toBe("#/home");
  });

  it("says nothing is starred of a type, and Show all favorites goes back to everything", async () => {
    answer = (q) => (q.get("IncludeItemTypes") === "Episode" ? { Items: [], TotalRecordCount: 0 } : paged(1)(q));
    await boot();
    await fav.renderFavorites(root);
    click(typeBtn("Episodes"));
    await settle();
    expect(root.querySelector(".state h3")!.textContent).toBe("Nothing starred under Episodes");
    click(byText(root, ".state button", "Show all favorites"));
    await settle();
    expect(cards()).toEqual(["Movie s0"]);
    expect(typeBtn("All").classList.contains("active")).toBe(true);
    expect(JSON.parse(localStorage.getItem("aquarium.favorites")!).type).toBe("");
  });

  it("takes a card off the page when it's unstarred, and shows the empty state after the last one", async () => {
    answer = paged(2);
    await boot();
    await fav.renderFavorites(root);
    rightClick(root.querySelector(".card"));
    await pickMenu(/Remove from favorites/i);
    await settle();
    expect(writes).toEqual(["DELETE /UserFavoriteItems/s0?userId=user-1"]);
    expect(cards()).toEqual(["Movie s1"]);
    expect(root.querySelector(".lib-count")!.textContent).toBe("1 item");
    expect(cache.getCached<any>("favorites:SortName|Ascending:").items.map((i: any) => i.Id)).toEqual(["s1"]);
    rightClick(root.querySelector(".card"));
    await pickMenu(/Remove from favorites/i);
    await settle();
    expect(root.querySelector(".state h3")!.textContent).toBe("Nothing starred yet");
  });

  it("leaves a card that is still starred after another menu action", async () => {
    answer = paged(1);
    await boot();
    await fav.renderFavorites(root);
    mockJellyfin([
      [/^\/UserPlayedItems\//, {}],
      [/^\/Items\?/, (a: JfArgs) => answer(query(a.path))],
    ]);
    rightClick(root.querySelector(".card"));
    await pickMenu("Mark watched");
    await settle();
    expect(cards()).toEqual(["Movie s0"]);
  });

  it("shows an error with Try again, and drops what an overtaken load brings back", async () => {
    let fail = true;
    answer = (q) => (fail ? { __status: 500 } : paged(1)(q));
    await boot();
    await fav.renderFavorites(root);
    expect(root.querySelector(".state h3")!.textContent).toBe("Couldn't load favorites");
    expect(root.querySelector<HTMLElement>(".load-more")!.style.display).toBe("none");
    fail = false;
    click(byText(root, ".state button", "Try again"));
    await settle();
    expect(cards()).toEqual(["Movie s0"]);
    let release!: (v: any) => void;
    let reject!: () => void;
    let n = 0;
    answer = (q) => {
      n++;
      if (n === 1) return new Promise((r) => (release = r));
      if (n === 2) return new Promise((_, rej) => (reject = () => rej(new Error("late"))));
      return { Items: [star(`latest-${q.get("IncludeItemTypes")}`)], TotalRecordCount: 1 };
    };
    click(typeBtn("Movies"));
    click(typeBtn("TV Shows"));
    click(typeBtn("Episodes"));
    await settle();
    release({ Items: [star("stale")], TotalRecordCount: 1 });
    reject();
    await settle();
    expect(cards()).toEqual(["Movie latest-Episode"]);
    expect(root.querySelector(".state")).toBeNull();
  });
});

describe("cache-first paint (Linux/CLAUDE.md: getCached/setCached with a signature compare)", () => {
  it("replays what was paged in last time, checks the first page, and leaves an unchanged grid alone", async () => {
    const seen: URLSearchParams[] = [];
    answer = paged(70, seen);
    await boot();
    await fav.renderFavorites(root);
    click(root.querySelector(".load-more .btn"));
    await settle();
    seen.length = 0;
    await fav.renderFavorites(root);
    expect(cards()).toHaveLength(70);
    const first = root.querySelector(".card");
    await settle();
    expect(seen.map((q) => q.get("StartIndex"))).toEqual(["0"]);
    expect(root.querySelector(".card")).toBe(first);
    expect(root.querySelector<HTMLElement>(".load-more")!.style.display).toBe("none");
  });

  it("reloads when the first page changed, and keeps the grid when the check fails", async () => {
    let mode: "a" | "b" | "fail" = "a";
    answer = (q) => (mode === "fail" ? { __status: 500 } : mode === "a" ? paged(1)(q) : { Items: [star("new")], TotalRecordCount: 1 });
    await boot();
    await fav.renderFavorites(root);
    mode = "fail";
    await fav.renderFavorites(root);
    await settle();
    expect(cards()).toEqual(["Movie s0"]);
    mode = "b";
    await fav.renderFavorites(root);
    await settle();
    expect(cards()).toEqual(["Movie new"]);
  });

  it("drops a check that a newer load overtook", async () => {
    let hold = false;
    let release!: (v: any) => void;
    answer = (q) => (hold ? new Promise((r) => (release = r)) : paged(1)(q));
    await boot();
    await fav.renderFavorites(root);
    hold = true;
    await fav.renderFavorites(root);
    const check = release;
    hold = false;
    click(typeBtn("Movies"));
    await settle();
    check({ Items: [star("x"), star("y")], TotalRecordCount: 2 });
    await settle();
    expect(cards()).toEqual(["Movie s0"]);
  });
});

describe("favoritesRow (Home's row)", () => {
  it("is the newest sixteen starred items", async () => {
    let q: URLSearchParams | null = null;
    answer = (x) => ((q = x), { Items: [star("a")] });
    await boot();
    expect((await fav.favoritesRow()).map((i) => i.Id)).toEqual(["a"]);
    expect(q!.get("Limit")).toBe("16");
    expect(q!.get("SortBy")).toBe("DateCreated");
    expect(q!.get("SortOrder")).toBe("Descending");
    await fav.favoritesRow(4);
    expect(q!.get("Limit")).toBe("4");
  });
});
