// A library grid and the search results page (src/views/library.ts): what each
// library lists, the sort and filter bar and its memory, paging, the
// cache-first paint with its freshness check, and the states for nothing
// found and for failure. Real api / cache / ui under the mocked Tauri bridge.
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { jfPaths, mockJellyfin, signIn, type JfArgs } from "../helpers/tauri";
import { byText, click, mountShell, settle, texts } from "../helpers/views-media";
import { query } from "../helpers/views-media-music";

vi.mock("../../src/playback", async (importOriginal) => {
  const real = await importOriginal<typeof import("../../src/playback")>();
  return { ...real, playItem: vi.fn(async () => {}) };
});

type Lib = typeof import("../../src/views/library");

let lib: Lib;
let cache: typeof import("../../src/cache");
let root: HTMLElement;

interface Srv {
  meta?: any;
  items?: (q: URLSearchParams) => any;
  genres?: any;
  search?: (q: URLSearchParams) => any;
}
let srv: Srv;

let observers: IntersectionObserverCallback[];
const RealIO = (globalThis as any).IntersectionObserver;

beforeEach(() => {
  vi.resetModules();
  vi.clearAllMocks();
  srv = {};
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

function route(): void {
  mockJellyfin([
    [/^\/Items\/Filters\?/, () => srv.genres ?? { Genres: [] }],
    [/^\/Items\/lib1\?/, () => srv.meta ?? { Id: "lib1", Name: "Films", CollectionType: "movies" }],
    [
      /^\/Items\?/,
      (a: JfArgs) => {
        const q = query(a.path);
        if (q.get("searchTerm") != null) return srv.search ? srv.search(q) : { Items: [], TotalRecordCount: 0 };
        return srv.items ? srv.items(q) : { Items: [], TotalRecordCount: 0 };
      },
    ],
  ]);
}

async function boot(): Promise<void> {
  root = mountShell();
  route();
  await signIn();
  cache = await import("../../src/cache");
  lib = await import("../../src/views/library");
}

const film = (id: string, extra: any = {}) => ({ Id: id, Type: "Movie", Name: `Film ${id}`, ImageTags: {}, UserData: {}, ...extra });
const films = (n: number, from = 0) => Array.from({ length: n }, (_, i) => film(`f${from + i}`));
/** A server library of `total` films, paged as asked. */
const paged = (total: number, seen: URLSearchParams[] = []) => (q: URLSearchParams) => {
  seen.push(q);
  const from = Number(q.get("StartIndex"));
  return { Items: films(Math.max(0, Math.min(Number(q.get("Limit")), total - from)), from), TotalRecordCount: total };
};
const cards = () => texts(root, ".card-grid .card .card-title");
const chip = (label: string) => byText<HTMLButtonElement>(root, ".filter-bar .btn", label)!;
const selects = () => Array.from(root.querySelectorAll<HTMLSelectElement>(".filter-bar select"));

describe("a library", () => {
  it("shows a skeleton while it learns what the library is, then its films by title with a count", async () => {
    const seen: URLSearchParams[] = [];
    srv.items = paged(2, seen);
    await boot();
    const p = lib.renderLibrary(root, "lib1");
    expect(root.querySelector(".card-grid .skeleton, .skeleton")).not.toBeNull();
    await p;
    expect(root.querySelector("h1.page-title")!.textContent).toBe("Films");
    expect(cards()).toEqual(["Film f0", "Film f1"]);
    expect(root.querySelector(".lib-count")!.textContent).toBe("2 films");
    const q = seen[0]!;
    expect(q.get("userId")).toBe("user-1");
    expect(q.get("ParentId")).toBe("lib1");
    expect(q.get("IncludeItemTypes")).toBe("Movie");
    expect(q.get("SortBy")).toBe("SortName");
    expect(q.get("SortOrder")).toBe("Ascending");
    expect(q.get("Limit")).toBe("60");
    expect(root.querySelector<HTMLElement>(".load-more")!.style.display).toBe("none");
    expect(cache.getCached<any>("libmeta:lib1").Name).toBe("Films");
  });

  it("lists shows for a TV library, collections for the Collections view, and a collection's films and shows (regression: 56a1825 Collections)", async () => {
    const types: (string | null)[] = [];
    srv.items = (q) => (types.push(q.get("IncludeItemTypes") ?? `exclude:${q.get("ExcludeItemTypes")}`), { Items: [{ Id: "bs1", Type: "BoxSet", Name: "Trilogy", ImageTags: {} }], TotalRecordCount: 1 });
    await boot();
    for (const meta of [
      { Id: "lib1", CollectionType: "tvshows" },
      { Id: "lib1", CollectionType: "boxsets" },
      { Id: "lib1", Type: "BoxSet" },
      { Id: "lib1", CollectionType: "homevideos" },
    ]) {
      cache.invalidateCache("libmeta:lib1");
      srv.meta = meta;
      await lib.renderLibrary(root, "lib1");
    }
    expect(types.slice(0, 3)).toEqual(["Series", "BoxSet", "Movie,Series,Video,MusicVideo"]);
    expect(types[3]).toMatch(/^exclude:.*AudioBook/);
    // A collection's card opens the collection as a grid, not a detail page.
    click(root.querySelector(".card"));
    expect(location.hash).toBe("#/lib/bs1");
  });

  it("is still a page when the library itself can't be looked up", async () => {
    srv.meta = { __status: 500 };
    srv.items = paged(1);
    await boot();
    await lib.renderLibrary(root, "lib1");
    expect(root.querySelector("h1.page-title")!.textContent).toBe("Library");
    expect(cards()).toEqual(["Film f0"]);
    expect(cache.getCached("libmeta:lib1")).toBeUndefined();
  });

  it("stops if the page moved on while the library was looked up", async () => {
    let release!: (v: any) => void;
    srv.meta = new Promise((r) => (release = r));
    await boot();
    const p = lib.renderLibrary(root, "lib1");
    root.textContent = "";
    release({ Id: "lib1", Name: "Films", CollectionType: "movies" });
    await p;
    expect(root.children).toHaveLength(0);
    expect(jfPaths().some((x) => x.startsWith("/Items?"))).toBe(false);
  });

  it("uses the remembered name at once and refreshes it quietly", async () => {
    srv.items = paged(1);
    await boot();
    cache.setCached("libmeta:lib1", { Id: "lib1", Name: "Old name", CollectionType: "movies" });
    srv.meta = { Id: "lib1", Name: "New name", CollectionType: "movies" };
    await lib.renderLibrary(root, "lib1");
    expect(root.querySelector("h1.page-title")!.textContent).toBe("Old name");
    await settle();
    expect(cache.getCached<any>("libmeta:lib1").Name).toBe("New name");
    // A failed refresh keeps what's there.
    srv.meta = { __status: 500 };
    await lib.renderLibrary(root, "lib1");
    await settle();
    expect(cache.getCached<any>("libmeta:lib1").Name).toBe("New name");
  });

  it("pages with Load more and on scroll, and hides Load more at the end", async () => {
    const seen: URLSearchParams[] = [];
    srv.items = paged(130, seen);
    await boot();
    await lib.renderLibrary(root, "lib1");
    const more = root.querySelector<HTMLButtonElement>(".load-more .btn")!;
    expect(root.querySelector<HTMLElement>(".load-more")!.style.display).toBe("");
    click(more);
    // An extra request while one is in flight is swallowed.
    click(more);
    expect(more.disabled).toBe(true);
    expect(more.textContent).toBe("Loading…");
    await settle();
    expect(more.textContent).toBe("Load more");
    expect(seen.map((q) => q.get("StartIndex"))).toEqual(["0", "60"]);
    observers.at(-1)!([{ isIntersecting: false } as any], null as any);
    observers.at(-1)!([{ isIntersecting: true } as any], null as any);
    await settle();
    expect(cards()).toHaveLength(130);
    expect(root.querySelector<HTMLElement>(".load-more")!.style.display).toBe("none");
    observers.at(-1)!([{ isIntersecting: true } as any], null as any);
    await settle();
    expect(seen).toHaveLength(3);
    expect(root.querySelector(".lib-count")!.textContent).toBe("130 films");
  });

  it("counts in the library's own noun (films, shows, else items), one in the singular, and none as nothing", async () => {
    srv.items = paged(1);
    await boot();
    await lib.renderLibrary(root, "lib1");
    expect(root.querySelector(".lib-count")!.textContent).toBe("1 film");
    for (const [type, n, label] of [["tvshows", 1, "1 show"], ["tvshows", 2, "2 shows"], ["homevideos", 1, "1 item"], ["homevideos", 2, "2 items"]] as const) {
      srv.items = paged(n);
      srv.meta = { Id: "lib1", Name: "Lib", CollectionType: type };
      cache.clearCache();
      await lib.renderLibrary(root, "lib1");
      expect(root.querySelector(".lib-count")!.textContent).toBe(label);
    }
    srv.meta = undefined;
    srv.items = () => ({});
    cache.clearCache();
    await lib.renderLibrary(root, "lib1");
    expect(root.querySelector(".lib-count")!.textContent).toBe("");
    expect(root.querySelector(".state h3")!.textContent).toBe("This library is empty");
  });
});

describe("the filter bar", () => {
  it("sorts, and remembers the sort and filters for the library", async () => {
    const seen: URLSearchParams[] = [];
    srv.items = paged(3, seen);
    await boot();
    await lib.renderLibrary(root, "lib1");
    const sort = selects()[0]!;
    expect(Array.from(sort.options).map((o) => o.textContent)).toEqual(["A – Z", "Z – A", "Recently added", "Release date", "Rating", "Runtime", "Shuffle"]);
    sort.value = "DateCreated|Descending";
    sort.dispatchEvent(new Event("change"));
    await settle();
    expect(seen.at(-1)!.get("SortBy")).toBe("DateCreated");
    expect(seen.at(-1)!.get("SortOrder")).toBe("Descending");
    click(chip("Unwatched"));
    await settle();
    expect(chip("Unwatched").classList.contains("active")).toBe(true);
    expect(seen.at(-1)!.get("Filters")).toBe("IsUnplayed");
    click(chip("Favorites"));
    await settle();
    expect(seen.at(-1)!.get("IsFavorite")).toBe("true");
    expect(JSON.parse(localStorage.getItem("aquarium.lib.lib1")!)).toEqual({ sort: "DateCreated|Descending", unwatched: true, favorites: true, genre: "", reverse: false });
    // Reverse flips whichever order the sort has, and is remembered with the rest.
    click(chip("Reverse"));
    await settle();
    expect(seen.at(-1)!.get("SortBy")).toBe("DateCreated");
    expect(seen.at(-1)!.get("SortOrder")).toBe("Ascending");
    expect(JSON.parse(localStorage.getItem("aquarium.lib.lib1")!).reverse).toBe(true);
    click(chip("Reverse"));
    await settle();
    expect(seen.at(-1)!.get("SortOrder")).toBe("Descending");
    // Next visit opens the same way.
    await lib.renderLibrary(root, "lib1");
    expect(selects()[0]!.value).toBe("DateCreated|Descending");
    expect(chip("Unwatched").classList.contains("active")).toBe(true);
    click(chip("Unwatched"));
    await settle();
    expect(seen.at(-1)!.get("Filters")).toBeNull();
  });

  it("ignores remembered settings it can't read or doesn't know", async () => {
    const seen: URLSearchParams[] = [];
    srv.items = paged(1, seen);
    await boot();
    localStorage.setItem("aquarium.lib.lib1", "{oops");
    await lib.renderLibrary(root, "lib1");
    expect(seen.at(-1)!.get("SortBy")).toBe("SortName");
    localStorage.setItem("aquarium.lib.lib1", JSON.stringify({ sort: "Bogus|Up", genre: 5 }));
    await lib.renderLibrary(root, "lib1");
    expect(selects()[0]!.value).toBe("SortName|Ascending");
  });

  it("keeps working when the settings can't be saved", async () => {
    srv.items = paged(1);
    await boot();
    await lib.renderLibrary(root, "lib1");
    const spy = vi.spyOn(Storage.prototype, "setItem").mockImplementation(() => {
      throw new Error("quota");
    });
    try {
      click(chip("Unwatched"));
      await settle();
    } finally {
      spy.mockRestore();
    }
    expect(chip("Unwatched").classList.contains("active")).toBe(true);
  });

  it("offers the library's genres once the server names them, forgetting a remembered one that's gone", async () => {
    const seen: URLSearchParams[] = [];
    srv.items = paged(1, seen);
    srv.genres = { Genres: ["Western", "Drama", "", 7] };
    localStorage.setItem("aquarium.lib.lib1", JSON.stringify({ genre: "Noir" }));
    await boot();
    await lib.renderLibrary(root, "lib1");
    await settle();
    const genre = selects()[1]!;
    expect(genre.hidden).toBe(false);
    expect(Array.from(genre.options).map((o) => o.textContent)).toEqual(["All genres", "Drama", "Western"]);
    expect(genre.value).toBe("");
    expect(JSON.parse(localStorage.getItem("aquarium.lib.lib1")!).genre).toBe("");
    const fq = query(jfPaths().find((p) => p.startsWith("/Items/Filters"))!);
    expect(fq.get("parentId")).toBe("lib1");
    expect(fq.get("IncludeItemTypes")).toBe("Movie");
    genre.value = "Drama";
    genre.dispatchEvent(new Event("change"));
    await settle();
    expect(seen.at(-1)!.get("Genres")).toBe("Drama");
    // Remembered and still there.
    await lib.renderLibrary(root, "lib1");
    await settle();
    expect(selects()[1]!.value).toBe("Drama");
  });

  it("keeps the genre control hidden when the server has none or doesn't answer, or the page has gone", async () => {
    srv.items = paged(1);
    srv.genres = { __status: 404 };
    await boot();
    await lib.renderLibrary(root, "lib1");
    await settle();
    expect(selects()[1]!.hidden).toBe(true);
    srv.genres = {};
    await lib.renderLibrary(root, "lib1");
    await settle();
    expect(selects()[1]!.hidden).toBe(true);
    srv.genres = { Genres: ["Drama"] };
    const p = lib.renderLibrary(root, "lib1");
    const sel = selects()[1]!;
    root.textContent = "";
    await p;
    await settle();
    expect(sel.options).toHaveLength(0);
  });

  it("says when nothing matches the filters, and Clear filters puts everything back", async () => {
    const seen: URLSearchParams[] = [];
    srv.items = (q) => (seen.push(q), q.get("Filters") ? { Items: [], TotalRecordCount: 0 } : { Items: films(2), TotalRecordCount: 2 });
    srv.genres = { Genres: ["Drama"] };
    await boot();
    await lib.renderLibrary(root, "lib1");
    await settle();
    click(chip("Unwatched"));
    await settle();
    expect(root.querySelector(".state h3")!.textContent).toBe("Nothing matches these filters");
    click(byText(root, ".state button", "Clear filters"));
    await settle();
    expect(cards()).toEqual(["Film f0", "Film f1"]);
    expect(chip("Unwatched").classList.contains("active")).toBe(false);
    expect(selects()[1]!.value).toBe("");
    expect(JSON.parse(localStorage.getItem("aquarium.lib.lib1")!)).toMatchObject({ unwatched: false, favorites: false, genre: "" });
  });

  it("keeps the grid's height on a re-sort: as many placeholders as there were cards", async () => {
    let release!: () => void;
    let gate: Promise<void> | null = null;
    srv.items = async (q) => {
      if (gate) await gate;
      return paged(5)(q);
    };
    await boot();
    await lib.renderLibrary(root, "lib1");
    gate = new Promise((r) => (release = r));
    const sort = selects()[0]!;
    sort.value = "SortName|Descending";
    sort.dispatchEvent(new Event("change"));
    expect(root.querySelectorAll(".card-grid > *")).toHaveLength(5);
    expect(root.querySelector(".card-grid .card-title")).toBeNull();
    release();
    await settle();
    expect(cards()).toHaveLength(5);
  });

  it("a sort change made while a page is loading wins over that page", async () => {
    let release!: (v: any) => void;
    let n = 0;
    srv.items = (q) => {
      n++;
      if (n === 2) return new Promise((r) => (release = r));
      return { Items: [film(`sorted-${q.get("SortOrder")}`)], TotalRecordCount: 1 };
    };
    await boot();
    await lib.renderLibrary(root, "lib1");
    const sort = selects()[0]!;
    sort.value = "Random|Ascending";
    sort.dispatchEvent(new Event("change"));
    sort.value = "SortName|Descending";
    sort.dispatchEvent(new Event("change"));
    await settle();
    release({ Items: [film("stale")], TotalRecordCount: 1 });
    await settle();
    expect(cards()).toEqual(["Film sorted-Descending"]);
    const more = root.querySelector<HTMLButtonElement>(".load-more .btn")!;
    expect(more.disabled).toBe(false);
  });

  it("shows an error with Try again, and drops a failure from a load that was overtaken", async () => {
    let fail = true;
    srv.items = (q) => (fail ? { __status: 500 } : paged(1)(q));
    await boot();
    await lib.renderLibrary(root, "lib1");
    expect(root.querySelector(".state h3")!.textContent).toBe("Couldn't load this library");
    expect(root.querySelector<HTMLElement>(".load-more")!.style.display).toBe("none");
    fail = false;
    click(byText(root, ".state button", "Try again"));
    await settle();
    expect(cards()).toEqual(["Film f0"]);
    // A failure that loses the race to a newer load is not shown.
    let reject!: () => void;
    let n = 0;
    srv.items = (q) => (++n === 1 ? new Promise((_, rej) => (reject = () => rej(new Error("late")))) : paged(1)(q));
    click(chip("Favorites"));
    click(chip("Favorites"));
    await settle();
    reject();
    await settle();
    expect(root.querySelector(".state")).toBeNull();
    expect(cards()).toEqual(["Film f0"]);
  });

  it("an error on a later page keeps the cards already shown", async () => {
    let n = 0;
    srv.items = (q) => (++n === 2 ? { __status: 503 } : paged(100)(q));
    await boot();
    await lib.renderLibrary(root, "lib1");
    click(root.querySelector(".load-more .btn"));
    await settle();
    expect(cards()).toHaveLength(60);
    expect(root.querySelector(".card-grid .state h3")!.textContent).toBe("Couldn't load this library");
  });
});

describe("cache-first paint (Linux/CLAUDE.md: getCached/setCached with a signature compare)", () => {
  it("replays everything paged in last time at once, then checks the first page and leaves the grid alone if it's the same", async () => {
    const seen: URLSearchParams[] = [];
    srv.items = paged(130, seen);
    await boot();
    await lib.renderLibrary(root, "lib1");
    click(root.querySelector(".load-more .btn"));
    await settle();
    seen.length = 0;
    await lib.renderLibrary(root, "lib1");
    expect(cards()).toHaveLength(120);
    const first = root.querySelector(".card");
    await settle();
    expect(seen.map((q) => q.get("StartIndex"))).toEqual(["0"]);
    expect(root.querySelector(".card")).toBe(first);
    // Paging carries on from where the cache left off.
    click(root.querySelector(".load-more .btn"));
    await settle();
    expect(seen.at(-1)!.get("StartIndex")).toBe("120");
  });

  it("reloads when the first page or the total changed", async () => {
    let total = 2;
    srv.items = (q) => paged(total)(q);
    await boot();
    await lib.renderLibrary(root, "lib1");
    total = 3;
    await lib.renderLibrary(root, "lib1");
    expect(cards()).toHaveLength(2);
    await settle();
    expect(cards()).toHaveLength(3);
    expect(root.querySelector(".lib-count")!.textContent).toBe("3 films");
  });

  it("keeps the cached grid when the check fails, and drops a check that a newer load overtook", async () => {
    let mode: "ok" | "fail" | "hold" = "ok";
    let release!: (v: any) => void;
    srv.items = (q) => (mode === "fail" ? { __status: 500 } : mode === "hold" ? new Promise((r) => (release = r)) : paged(2)(q));
    await boot();
    await lib.renderLibrary(root, "lib1");
    mode = "fail";
    await lib.renderLibrary(root, "lib1");
    await settle();
    expect(cards()).toHaveLength(2);
    expect(root.querySelector(".state")).toBeNull();
    mode = "hold";
    await lib.renderLibrary(root, "lib1");
    const hold = release;
    mode = "ok";
    click(chip("Favorites"));
    await settle();
    hold({ Items: films(9), TotalRecordCount: 9 });
    await settle();
    expect(cards()).toHaveLength(2);
  });
});

describe("search", () => {
  const item = (id: string, Type: string) => ({ Id: id, Type, Name: `${Type} ${id}`, ImageTags: {}, UserData: {} });

  it("groups what it finds into Movies, TV Shows, Episodes and Other, and puts the term in the box", async () => {
    let q: URLSearchParams | null = null;
    srv.search = (x) => ((q = x), { Items: [item("1", "Movie"), item("2", "Series"), item("3", "Episode"), item("4", "BoxSet")], TotalRecordCount: 4 });
    await boot();
    const input = document.createElement("input");
    input.id = "search-input";
    document.body.append(input);
    const p = lib.renderSearch(root, "blue");
    expect(input.value).toBe("blue");
    expect(root.querySelector("h1.page-title")!.textContent).toBe("Search: “blue”");
    expect(root.querySelector(".skeleton, .sk-box")).not.toBeNull();
    await p;
    expect(q!.get("searchTerm")).toBe("blue");
    expect(q!.get("userId")).toBe("user-1");
    expect(q!.get("Limit")).toBe("48");
    expect(texts(root, ".section h2")).toEqual(["Movies · 1", "TV Shows · 1", "Episodes · 1", "Other"]);
    expect(byText(root, ".section", "Episodes")!.querySelector(".card.wide")).not.toBeNull();
    expect(root.querySelector(".lib-count")!.textContent).toBe("4 results");
  });

  it("leaves the box alone when it already says the term", async () => {
    await boot();
    const input = document.createElement("input");
    input.id = "search-input";
    input.value = " blue ";
    document.body.append(input);
    await lib.renderSearch(root, "blue");
    expect(input.value).toBe(" blue ");
  });

  it("loads more results on request", async () => {
    srv.search = (q) => {
      const from = Number(q.get("StartIndex"));
      return { Items: from ? [item("b", "Movie")] : [item("a", "Movie")], TotalRecordCount: 49 };
    };
    await boot();
    await lib.renderSearch(root, "x");
    expect(root.querySelector(".lib-count")!.textContent).toBe("49 results");
    expect(root.querySelector<HTMLElement>(".load-more")!.style.display).toBe("");
    click(root.querySelector(".load-more .btn"));
    await settle();
    expect(texts(root, ".card-title")).toEqual(["Movie a", "Movie b"]);
    expect(root.querySelector<HTMLElement>(".load-more")!.style.display).toBe("none");
  });

  it("says there are no results with a way back, counting one in the singular elsewhere", async () => {
    await boot();
    const input = document.createElement("input");
    input.id = "search-input";
    document.body.append(input);
    await lib.renderSearch(root, "zzz");
    expect(root.querySelector(".state h3")!.textContent).toBe("No results for “zzz”");
    click(byText(root, ".state button", "Clear search"));
    expect(input.value).toBe("");
    expect(location.hash).toBe("#/home");
    srv.search = () => ({ Items: [item("1", "Movie")], TotalRecordCount: 1 });
    await lib.renderSearch(root, "one");
    expect(root.querySelector(".lib-count")!.textContent).toBe("1 result");
    input.remove();
    await lib.renderSearch(root, "zzz2");
    srv.search = () => ({ Items: [] });
    await lib.renderSearch(root, "none");
    click(byText(root, ".state button", "Clear search"));
    expect(location.hash).toBe("#/home");
  });

  it("shows a failed search as an error with Try again, not as no results (regression: a963a95)", async () => {
    let fail = true;
    srv.search = () => (fail ? { __status: 500 } : { Items: [item("1", "Movie")], TotalRecordCount: 1 });
    await boot();
    await lib.renderSearch(root, "blue");
    expect(root.querySelector(".state h3")!.textContent).toBe("Search didn't go through");
    fail = false;
    click(byText(root, ".state button", "Try again"));
    await settle();
    expect(texts(root, ".card-title")).toEqual(["Movie 1"]);
  });

  it("draws nothing when a newer search has taken the page", async () => {
    let release!: (v: any) => void;
    srv.search = () => new Promise((r) => (release = r));
    await boot();
    const p = lib.renderSearch(root, "a");
    root.textContent = "";
    release({ Items: [item("1", "Movie")], TotalRecordCount: 1 });
    await p;
    expect(root.children).toHaveLength(0);
  });
});
