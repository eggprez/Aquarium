// The Music pages (src/views/music.ts): Listen Now, the library tabs, the
// album, artist, genre and playlist pages, smart playlists and their editor,
// music search, the station-mix dialog. Real api / musicApi / cache / ui /
// stations / smartPlaylists under the mocked Tauri bridge; audio.ts is the
// stand-in from helpers/views-media-music.
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { flush, invokeCalls, jfPaths, onInvoke, signIn, type JfArgs } from "../helpers/tauri";
import {
  byText,
  click,
  dialogButtons,
  dialogEl,
  dialogTitle,
  key,
  lastToast,
  menuLabels,
  menuTitle,
  mountShell,
  pickDialog,
  pickMenu,
  rightClick,
  settle,
  texts,
  toasts,
} from "../helpers/views-media";
import {
  album,
  artist,
  foreverAnimated,
  musicServer,
  playlist,
  query,
  song,
  TICKS_PER_SEC,
  type FakeAudio,
} from "../helpers/views-media-music";

vi.mock("../../src/audio", async () => (await import("../helpers/views-media-music")).fakeAudioModule());

type Music = typeof import("../../src/views/music");

let music: Music;
let audio: FakeAudio;
let cache: typeof import("../../src/cache");
let content: HTMLElement;

beforeEach(() => {
  vi.resetModules();
  vi.clearAllMocks();
});

afterEach(() => {
  location.hash = "";
});

type Items = (q: URLSearchParams, a: JfArgs) => any;

async function boot(items: Items = () => [], extra: [string | RegExp, any][] = [], cfg: Record<string, any> = {}): Promise<void> {
  content = mountShell();
  musicServer({ items, extra, item: (id) => itemById[id] ?? { __status: 404 } });
  onInvoke("downloads_list", []);
  await signIn(cfg);
  audio = (await import("../../src/audio")) as any;
  audio.__reset();
  cache = await import("../../src/cache");
  music = await import("../../src/views/music");
}

/** What `/Items/<id>?` answers, per test. */
let itemById: Record<string, any> = {};
beforeEach(() => {
  itemById = {};
});

const page = () => content.querySelector<HTMLElement>(".mu-page")!;
const paths = (re: RegExp) => jfPaths().filter((p) => re.test(p));

// ---------- Routing ----------

describe("renderMusic", () => {
  it("renders each page into its own wrapper, replacing what #content held, and fetches the playlists for menus (regression: 32f1e9f music pages classed #content; playlists prefetched for Add to Playlist)", async () => {
    await boot();
    content.append(document.createElement("aside"));
    await music.renderMusic(content, "");
    expect(content.children).toHaveLength(1);
    expect(content.classList.contains("mu-page")).toBe(false);
    expect(page().querySelector("h1")!.textContent).toBe("Listen Now");
    expect(paths(/IncludeItemTypes=Playlist/)).toHaveLength(1);
  });

  it("routes library, songs, search and downloaded", async () => {
    await boot();
    await music.renderMusic(content, "library");
    expect(page().querySelector(".mu-tab.active")!.textContent).toBe("Albums");
    await music.renderMusic(content, "songs/top");
    expect(page().querySelector("h1")!.textContent).toBe("Most Played");
    await music.renderMusic(content, "search");
    expect(page().querySelector("h1")!.textContent).toBe("Search Music");
    await music.renderMusic(content, "downloaded");
    expect(page().querySelector("h1")!.textContent).toBe("Downloaded Music & Books");
    expect(page().querySelector(".mu-tab.active")!.textContent).toBe("Downloaded");
    expect(page().querySelector(".mu-tab.active")!.getAttribute("aria-current")).toBe("page");
    expect(texts(page(), ".mu-tab")).toEqual(["Listen Now", "Playlists", "Artists", "Albums", "Songs", "Genres", "Search", "Downloaded"]);
  });
});

// ---------- Listen Now ----------

interface Disc {
  recent?: any[];
  top?: any[];
  added?: any[];
  favAlbums?: any[];
  favArtists?: any[];
  random?: any[];
  genres?: any[];
  fail?: boolean;
}

function discoverServer(d: Disc): [Items, [string | RegExp, any][]] {
  const items: Items = (q) => {
    if (d.fail) return { __status: 500 };
    const type = q.get("IncludeItemTypes");
    const sort = q.get("SortBy");
    if (type === "Audio" && sort?.startsWith("DatePlayed")) return d.recent ?? [];
    if (type === "Audio" && sort?.startsWith("PlayCount")) return d.top ?? [];
    if (type === "MusicAlbum" && sort?.startsWith("DateCreated")) return d.added ?? [];
    if (type === "MusicAlbum" && q.get("Filters") === "IsFavorite") return d.favAlbums ?? [];
    if (type === "MusicAlbum" && sort === "Random") return d.random ?? [];
    return [];
  };
  return [
    items,
    [
      [/^\/Artists\/AlbumArtists\?/, () => (d.fail ? { __status: 500 } : { Items: d.favArtists ?? [], TotalRecordCount: 0 })],
      [/^\/MusicGenres\?/, () => (d.fail ? { __status: 500 } : { Items: d.genres ?? [] })],
    ],
  ];
}

describe("Listen Now", () => {
  it("shows a skeleton, then says there's nothing to suggest for an empty library", async () => {
    await boot(...discoverServer({}));
    const done = music.renderMusic(content, "discover");
    expect(page().querySelector(".mu-discover .skeleton, .mu-discover .sk-box")).not.toBeNull();
    await done;
    expect(page().querySelector(".state h3")!.textContent).toBe("Nothing to suggest yet");
  });

  it("still draws when every request fails", async () => {
    await boot(...discoverServer({ fail: true }));
    await music.renderMusic(content, "discover");
    expect(page().querySelector(".state h3")!.textContent).toBe("Nothing to suggest yet");
  });

  it("lays out every shelf, with stations from the artists and genres played most (regression: 32f1e9f compilations aren't station seeds)", async () => {
    const va = { Id: "va", Name: "Various Artists" };
    const a1 = { Id: "a1", Name: "Ann" };
    const a2 = { Id: "a2", Name: "Bob" };
    const recent = [
      song("r1", { AlbumId: "x1", Album: "X1", AlbumArtists: [a1], Genres: ["Jazz"] }),
      song("r2", { AlbumId: "x1", Album: "X1", AlbumArtists: [a1], Genres: ["Jazz"] }),
      song("r3", { AlbumId: "x2", Album: "X2", AlbumArtists: [va], ArtistItems: [], Genres: ["Pop", "Jazz"] }),
      song("r4", { AlbumId: undefined, AlbumArtists: undefined, ArtistItems: [a2], Genres: undefined }),
    ];
    const top = [song("t1", { AlbumArtists: [a2], Genres: ["Unknown genre"] })];
    await boot(...discoverServer({
      recent,
      top,
      added: [album("n1")],
      favAlbums: [album("f1")],
      favArtists: [artist("fa1")],
      random: [album("z1")],
      genres: [{ Id: "gj", Name: "jazz", Type: "MusicGenre" }, { Id: "gp", Name: "Pop", Type: "MusicGenre" }],
    }));
    await music.renderMusic(content, "discover");
    const heads = texts(page(), ".mu-shelf h2");
    expect(heads).toEqual([
      "Recently Played", "Your Stations", "Your Top Songs", "New in Your Library", "Favorite Albums", "Favorite Artists", "Something Different",
    ]);
    // Recently played songs, as their albums, once each.
    const recentShelf = byText(page(), ".mu-shelf", "Recently Played")!;
    expect(texts(recentShelf, ".mu-card-title")).toEqual(["X1", "X2"]);
    // Bob (2 plays) before Ann (2 plays) is a tie; the compilation is no station.
    const stationTitles = texts(page(), ".mu-station .mu-card-title");
    expect(stationTitles).toEqual(expect.arrayContaining(["Ann Station", "Bob Station", "jazz Station", "Pop Station"]));
    expect(stationTitles).not.toContain("Various Artists Station");
    expect(stationTitles).toHaveLength(4);
    expect(byText(page(), ".mu-shelf", "Your Top Songs")!.querySelector(".mu-songs.columns")).not.toBeNull();
    expect(paths(/^\/MusicGenres\?userId=user-1/)).toHaveLength(1);
    // See all.
    click(byText(recentShelf, ".see-all", "See all"));
    expect(location.hash).toBe("#/music/songs/recent");
    click(byText(byText(page(), ".mu-shelf", "Your Top Songs")!, ".see-all", "See all"));
    expect(location.hash).toBe("#/music/songs/top");
    click(byText(byText(page(), ".mu-shelf", "New in Your Library")!, ".see-all", "See all"));
    expect(location.hash).toBe("#/music/library/albums?sort=added");
  });

  it("starts a station from its tile", async () => {
    await boot(...discoverServer({ recent: [song("r1", { AlbumArtists: [{ Id: "a1", Name: "Ann" }] })] }));
    await music.renderMusic(content, "discover");
    click(page().querySelector(".mu-station"));
    await settle();
    expect(toasts()).toContain("Starting a mix from Ann…");
  });

  it("paints the cached page at once and leaves it alone when nothing changed (Linux/CLAUDE.md: cache with a signature compare)", async () => {
    const d: Disc = { added: [album("n1")], random: [album("z1")] };
    await boot(...discoverServer(d));
    await music.renderMusic(content, "discover");
    const first = page().querySelector(".mu-discover")!.firstElementChild;
    // A second visit: painted before the fetch returns, and the same nodes stay.
    d.random = [album("z2")];
    const p = music.renderMusic(content, "discover");
    const painted = page().querySelector(".mu-discover .mu-card-title")!.textContent;
    expect(painted).toBe("n1".replace(/^/, "Album "));
    expect(page().querySelector(".mu-discover .skeleton")).toBeNull();
    const before = page().querySelector(".mu-discover")!.firstElementChild;
    await p;
    // A new random draw alone is not a change worth a repaint.
    expect(page().querySelector(".mu-discover")!.firstElementChild).toBe(before);
    expect(first).not.toBe(before);
    expect(cache.getCached<any>("music:discover").random[0].Id).toBe("z2");
  });

  it("repaints when the server's answer changed", async () => {
    const d: Disc = { added: [album("n1")] };
    await boot(...discoverServer(d));
    await music.renderMusic(content, "discover");
    d.added = [album("n2")];
    await music.renderMusic(content, "discover");
    expect(texts(byText(page(), ".mu-shelf", "New in Your Library")!, ".mu-card-title")).toEqual(["Album n2"]);
  });

  it("doesn't paint a page the user has left", async () => {
    await boot(...discoverServer({ added: [album("n1")] }));
    const p = music.renderMusic(content, "discover");
    content.textContent = "";
    await p;
    expect(content.querySelector(".mu-card")).toBeNull();
  });

  it("Shuffle All is disabled while it works, and Station Mix… opens the mix dialog (regression: 77b0f7c Shuffle All replaces Surprise Me)", async () => {
    await boot(...discoverServer({}));
    await music.renderMusic(content, "discover");
    const btn = byText<HTMLButtonElement>(page(), "button", "Shuffle All")!;
    click(btn);
    expect(btn.disabled).toBe(true);
    await settle();
    expect(btn.disabled).toBe(false);
    expect(lastToast()).toBe("There's nothing in your music library to shuffle yet");
    click(byText(page(), "button", "Station Mix…"));
    expect(dialogTitle()).toBe("Station Mix");
  });

  it("re-enables Shuffle All even when the shuffle throws", async () => {
    await boot(...discoverServer({}));
    await music.renderMusic(content, "discover");
    musicServer({ items: () => [song("a")] });
    vi.mocked(audio.play).mockRejectedValueOnce(new Error("mpv"));
    const btn = byText<HTMLButtonElement>(page(), "button", "Shuffle All")!;
    click(btn);
    await settle();
    expect(btn.disabled).toBe(false);
    expect(lastToast()).toBe("mpv");
  });

  it("keeps the playing mark current while the page is open, and stops listening once it's gone", async () => {
    await boot(...discoverServer({ top: [song("t1"), song("t2")], added: [album("n1")] }));
    await music.renderMusic(content, "discover");
    expect(audio.__listeners.size).toBe(1);
    audio.__playing([song("t2")]);
    expect(Array.from(page().querySelectorAll<HTMLElement>(".mu-song.playing")).map((r) => r.dataset.id)).toEqual(["t2"]);
    content.textContent = "";
    audio.__emit();
    expect(audio.__listeners.size).toBe(0);
  });
});

// ---------- Song charts ----------

describe("Most Played and Recently Played", () => {
  it("lists the most played songs by rank with Play and Shuffle", async () => {
    const songs = [song("a"), song("b")];
    let q: URLSearchParams | null = null;
    await boot((x) => (x.get("SortBy")?.startsWith("PlayCount") ? ((q = x), songs) : []));
    await music.renderMusic(content, "songs/top");
    expect(q!.get("Limit")).toBe("200");
    expect(texts(page(), ".mu-song-num")).toEqual(["1", "2"]);
    click(byText(page(), ".mu-head-buttons button", "Play"));
    click(byText(page(), ".mu-head-buttons button", "Shuffle"));
    const calls = (audio.play as any).mock.calls;
    expect(calls[0][2]).toEqual({ title: "Most Played" });
    expect(calls[1][2]).toEqual({ title: "Most Played", shuffle: true });
  });

  it("lists recent plays with covers, and says when nothing has been played", async () => {
    await boot((x) => (x.get("SortBy")?.startsWith("DatePlayed") ? [song("a")] : []));
    await music.renderMusic(content, "songs/recent");
    expect(page().querySelector("h1")!.textContent).toBe("Recently Played");
    expect(page().querySelector(".mu-song-art")).not.toBeNull();
    await music.renderMusic(content, "songs/top");
    expect(page().querySelector(".state h3")!.textContent).toBe("Nothing played yet");
  });

  it("paints from the cache and repaints only on change", async () => {
    let songs = [song("a")];
    await boot((x) => (x.get("SortBy")?.startsWith("PlayCount") ? songs : []));
    await music.renderMusic(content, "songs/top");
    const p = music.renderMusic(content, "songs/top");
    const row = page().querySelector(".mu-song");
    expect(row).not.toBeNull();
    expect(page().querySelector(".spinner")).toBeNull();
    await p;
    expect(page().querySelector(".mu-song")).toBe(row);
    songs = [song("b")];
    await music.renderMusic(content, "songs/top");
    expect((page().querySelector(".mu-song") as HTMLElement).dataset.id).toBe("b");
  });
});

// ---------- Station mix ----------

describe("openMixDialog", () => {
  it("shows the points left and the preset, moves with the dials within the budget, and saves", async () => {
    await boot();
    music.openMixDialog();
    const dlg = dialogEl()!;
    expect(dlg.classList.contains("wide")).toBe(true);
    expect(dlg.querySelector(".mu-mix-intro")!.textContent).toMatch(/0 left · Balanced$/);
    expect(dlg.querySelector(".mu-mix-presets .btn.active")!.textContent).toBe("Balanced");
    const ranges = Array.from(dlg.querySelectorAll<HTMLInputElement>("input[type=range]"));
    expect(ranges.map((r) => r.getAttribute("aria-label"))).toHaveLength(7);
    // The budget is spent: a dial can't take more than it has.
    const before = ranges[0]!.value;
    ranges[0]!.value = "20";
    ranges[0]!.dispatchEvent(new Event("input"));
    expect(ranges[0]!.value).toBe(before);
    // Freeing points makes it Custom.
    ranges[0]!.value = "0";
    ranges[0]!.dispatchEvent(new Event("input"));
    expect(dlg.querySelector(".mu-mix-intro")!.textContent).toMatch(/left · Custom$/);
    expect(dlg.querySelector(".mu-mix-val")!.textContent).toBe("0");
    expect(dlg.querySelector(".mu-mix-presets .btn.active")).toBeNull();
    // A preset puts the dials back.
    click(byText(dlg, ".mu-mix-presets .btn", "Discovery"));
    expect(dialogEl()!.querySelector(".mu-mix-presets .btn.active")!.textContent).toBe("Discovery");
    await pickDialog("Save");
    await settle();
    const saved = invokeCalls("config_save").at(-1)!.args.cfg.music_mix;
    expect(saved).toEqual(expect.objectContaining({ discovery: 8 }));
    expect(lastToast()).toBe("Station mix saved");
  });

  it("starts from the saved mix, and reports a save that failed", async () => {
    await boot(() => [], [], { music_mix: { artist: 20 } });
    onInvoke("config_save", () => {
      throw new Error("disk full");
    });
    music.openMixDialog();
    expect(dialogEl()!.querySelector(".mu-mix-val")!.textContent).toBe("20");
    expect(dialogButtons()).toEqual(["Cancel", "Save"]);
    await pickDialog("Save");
    await settle();
    expect(lastToast()).toBe("disk full");
  });
});

// ---------- Library ----------

describe("Library: albums, artists, songs", () => {
  let observers: { cb: IntersectionObserverCallback; disconnected: boolean }[];
  const RealIO = (globalThis as any).IntersectionObserver;
  beforeEach(() => {
    observers = [];
    (globalThis as any).IntersectionObserver = class {
      rec: { cb: IntersectionObserverCallback; disconnected: boolean };
      constructor(cb: IntersectionObserverCallback) {
        this.rec = { cb, disconnected: false };
        observers.push(this.rec);
      }
      observe() {}
      disconnect() {
        this.rec.disconnected = true;
      }
    };
  });
  afterEach(() => {
    (globalThis as any).IntersectionObserver = RealIO;
  });
  const scrolledToEnd = async () => {
    observers.at(-1)!.cb([{ isIntersecting: true } as any], null as any);
    await settle();
  };

  it("lists albums by title, pages on scroll and counts them", async () => {
    const all = Array.from({ length: 150 }, (_, i) => album(`a${i}`));
    const seen: URLSearchParams[] = [];
    await boot((q) => {
      if (q.get("IncludeItemTypes") !== "MusicAlbum") return [];
      seen.push(q);
      const from = Number(q.get("StartIndex"));
      return { Items: all.slice(from, from + Number(q.get("Limit"))), TotalRecordCount: 1500 };
    });
    await music.renderMusic(content, "library/albums");
    expect(page().querySelector(".lib-count")!.textContent).toBe(`${(1500).toLocaleString()} albums`);
    expect(page().querySelectorAll(".mu-grid .mu-card")).toHaveLength(100);
    expect(seen[0]!.get("SortBy")).toBe("SortName");
    await scrolledToEnd();
    expect(seen[1]!.get("StartIndex")).toBe("100");
    expect(page().querySelectorAll(".mu-grid .mu-card")).toHaveLength(150);
    // A page that came back empty marks the end: no more requests.
    await scrolledToEnd();
    await scrolledToEnd();
    expect(seen).toHaveLength(3);
    // Not intersecting: nothing.
    observers.at(-1)!.cb([{ isIntersecting: false } as any], null as any);
    // Once the page is gone the observer lets go.
    content.textContent = "";
    observers.at(-1)!.cb([{ isIntersecting: true } as any], null as any);
    expect(observers.at(-1)!.disconnected).toBe(true);
  });

  it("lists album artists from their own route", async () => {
    await boot(() => [], [[/^\/Artists\/AlbumArtists\?/, (a: JfArgs) => ({ Items: [artist("x")], TotalRecordCount: 1, q: a.path })]]);
    await music.renderMusic(content, "library/artists");
    expect(page().querySelector(".mu-card.artist")).not.toBeNull();
    expect(page().querySelector(".lib-count")!.textContent).toBe("1 artists");
    expect(texts(page(), ".mu-select option")).toEqual(["Title", "Recently added", "Random"]);
  });

  it("lists songs as rows that play the whole loaded list from the row", async () => {
    const all = Array.from({ length: 120 }, (_, i) => song(`s${i}`));
    await boot((q) => {
      if (q.get("IncludeItemTypes") !== "Audio") return [];
      const from = Number(q.get("StartIndex"));
      return { Items: all.slice(from, from + 100), TotalRecordCount: 120 };
    });
    await music.renderMusic(content, "library/songs");
    await scrolledToEnd();
    const rows = page().querySelectorAll(".mu-songs .mu-song");
    expect(rows).toHaveLength(120);
    rows[110]!.dispatchEvent(new MouseEvent("dblclick", { bubbles: true }));
    const [list, i, opts] = (audio.play as any).mock.calls[0];
    expect(list).toHaveLength(120);
    expect(i).toBe(110);
    expect(opts).toEqual({ title: "Songs" });
    // Songs keeps the playing mark current.
    audio.__playing([song("s3")]);
    expect(page().querySelector(".mu-song.playing")!.getAttribute("data-id")).toBe("s3");
  });

  it("remembers the sort per tab, takes one from the address, and ignores ones the tab doesn't have", async () => {
    const sorts: string[] = [];
    await boot((q) => (q.get("IncludeItemTypes") === "MusicAlbum" ? (sorts.push(q.get("SortBy")!), []) : []));
    await music.renderMusic(content, "library/albums?sort=added");
    expect(sorts.at(-1)).toBe("DateCreated,SortName");
    const sel = page().querySelector<HTMLSelectElement>(".mu-select")!;
    expect(sel.value).toBe("added");
    sel.value = "year";
    sel.dispatchEvent(new Event("change"));
    await settle();
    expect(sorts.at(-1)).toBe("ProductionYear,SortName");
    expect(JSON.parse(localStorage.getItem("aquarium.music-lib.albums")!)).toEqual({ sort: "year" });
    await music.renderMusic(content, "library/albums?sort=plays");
    expect(sorts.at(-1)).toBe("ProductionYear,SortName");
    localStorage.setItem("aquarium.music-lib.albums", "{bad");
    await music.renderMusic(content, "library/albums");
    expect(sorts.at(-1)).toBe("SortName");
    localStorage.setItem("aquarium.music-lib.albums", JSON.stringify({ sort: "plays" }));
    await music.renderMusic(content, "library/albums");
    expect(sorts.at(-1)).toBe("SortName");
  });

  it("filters by text after a pause, and by favourites at a click", async () => {
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
    const qs: URLSearchParams[] = [];
    await boot((q) => (q.get("IncludeItemTypes") === "MusicAlbum" ? (qs.push(q), []) : []));
    await music.renderMusic(content, "library/albums");
    const input = page().querySelector<HTMLInputElement>(".mu-filter-input")!;
    input.value = "bl";
    input.dispatchEvent(new Event("input"));
    input.value = "blue";
    input.dispatchEvent(new Event("input"));
    vi.advanceTimersByTime(299);
    expect(qs).toHaveLength(1);
    vi.advanceTimersByTime(1);
    await flush(30);
    expect(qs).toHaveLength(2);
    expect(qs[1]!.get("SearchTerm")).toBe("blue");
    const fav = byText<HTMLButtonElement>(page(), ".mu-filter button", "Favorites")!;
    click(fav);
    await flush(30);
    expect(fav.classList.contains("active")).toBe(true);
    expect(qs.at(-1)!.get("Filters")).toBe("IsFavorite");
    vi.useRealTimers();
  });

  it("paints the first page from the cache, checks it behind, and reloads only if it changed", async () => {
    let names = [album("a1")];
    let calls = 0;
    await boot((q) => (q.get("IncludeItemTypes") === "MusicAlbum" ? (calls++, { Items: names, TotalRecordCount: 1 }) : []));
    await music.renderMusic(content, "library/albums");
    expect(calls).toBe(1);
    const p = music.renderMusic(content, "library/albums");
    // Painted from the cache before any request.
    const card = page().querySelector(".mu-card");
    expect(card).not.toBeNull();
    await p;
    await settle();
    expect(calls).toBe(2);
    expect(page().querySelector(".mu-card")).toBe(card);
    names = [album("a2")];
    await music.renderMusic(content, "library/albums");
    await settle();
    expect(texts(page(), ".mu-card-title")).toEqual(["Album a2"]);
  });

  it("never caches a random order or a filtered list", async () => {
    await boot((q) => (q.get("IncludeItemTypes") === "MusicAlbum" ? [album("a1")] : []));
    await music.renderMusic(content, "library/albums?sort=random");
    expect(cache.getCached("music:lib:albums:random:false")).toBeUndefined();
    await music.renderMusic(content, "library/albums?sort=name");
    expect(cache.getCached("music:lib:albums:name:false")).toBeTruthy();
  });

  it("drops a revalidation that a newer load overtook", async () => {
    let gate: ((v: any) => void) | null = null;
    let n = 0;
    await boot((q) => {
      if (q.get("IncludeItemTypes") !== "MusicAlbum") return [];
      n++;
      if (n === 2) return new Promise((r) => (gate = r));
      return { Items: [album(`a${n}`)], TotalRecordCount: 1 };
    });
    await music.renderMusic(content, "library/albums");
    await music.renderMusic(content, "library/albums");
    // The check behind the cached paint is in flight; a sort change overtakes it.
    const sel = page().querySelector<HTMLSelectElement>(".mu-select")!;
    sel.value = "artist";
    sel.dispatchEvent(new Event("change"));
    await settle();
    gate!({ Items: [album("stale")], TotalRecordCount: 1 });
    await settle();
    expect(texts(page(), ".mu-card-title")).toEqual(["Album a3"]);
  });

  it("shows the new list when a filter changes while a page is still loading (drops the stale page)", async () => {
    let gate: ((v: any) => void) | null = null;
    let n = 0;
    await boot((q) => {
      if (q.get("IncludeItemTypes") !== "MusicAlbum") return [];
      n++;
      if (n === 1) return new Promise((r) => (gate = r));
      return { Items: [album("fresh")], TotalRecordCount: 1 };
    });
    void music.renderMusic(content, "library/albums?sort=random");
    await settle();
    const fav = byText(page(), ".mu-filter button", "Favorites")!;
    click(fav);
    await settle();
    gate!({ Items: [album("stale")], TotalRecordCount: 1 });
    await settle();
    expect(texts(page(), ".mu-card-title")).toEqual(["Album fresh"]);
  });

  it("shows an error with Try again when the library won't load", async () => {
    let fail = true;
    await boot((q) => (q.get("IncludeItemTypes") === "MusicAlbum" ? (fail ? { __status: 500 } : [album("a1")]) : []));
    await music.renderMusic(content, "library/albums");
    expect(page().querySelector(".state h3")!.textContent).toBe("Couldn't load the library");
    fail = false;
    click(byText(page(), ".state button", "Try again"));
    await settle();
    expect(texts(page(), ".mu-card-title")).toEqual(["Album a1"]);
  });
});

describe("Library: genres", () => {
  it("lists genres as links, filters them, and says when none match", async () => {
    await boot(() => [], [[/^\/MusicGenres\?/, { Items: [{ Id: "g1", Name: "Jazz" }, { Id: "g2", Name: "Rock" }] }]]);
    await music.renderMusic(content, "library/genres");
    expect(texts(page(), ".mu-genre")).toEqual(["Jazz", "Rock"]);
    expect(page().querySelector(".mu-genre")!.getAttribute("href")).toBe("#/music/genre/g1");
    const f = page().querySelector<HTMLInputElement>(".mu-filter-input")!;
    f.value = "ro";
    f.dispatchEvent(new Event("input"));
    expect(texts(page(), ".mu-genre")).toEqual(["Rock"]);
    f.value = "qq";
    f.dispatchEvent(new Event("input"));
    expect(page().querySelector(".state h3")!.textContent).toBe("No genres match");
    // A revisit paints from the cache.
    const p = music.renderMusic(content, "library/genres");
    expect(texts(page(), ".mu-genre")).toEqual(["Jazz", "Rock"]);
    await p;
  });

  it("says so when there are no genres (the spinner gives way to an empty state)", async () => {
    await boot(() => [], [[/^\/MusicGenres\?/, { Items: [] }]]);
    const p = music.renderMusic(content, "library/genres");
    expect(page().querySelector(".spinner")).not.toBeNull();
    await p;
    expect(page().querySelector(".spinner")).toBeNull();
    await music.renderMusic(content, "library/genres");
    expect(page().querySelector(".state h3")!.textContent).toBe("No genres");
  });
});

describe("Library: playlists", () => {
  const smart = { id: "sp1", name: "Fresh Jazz", genres: ["Jazz"], limit: 50, order: "added" };

  it("lists smart playlists and the server's, filters both, and refreshes on a playlist change", async () => {
    let lists = [playlist("p1", { Name: "Road" }), playlist("p2", { Name: "Gym" })];
    await boot((q) => (q.get("IncludeItemTypes") === "Playlist" ? lists : []), [], { music_smart_playlists: [smart] });
    await music.renderMusic(content, "library/playlists");
    expect(texts(page(), "h2.mu-sub-head")).toEqual(["Smart Playlists", "Playlists"]);
    expect(texts(page(), ".mu-card-title")).toEqual(["Fresh Jazz", "Road", "Gym"]);
    expect(page().querySelector(".mu-card .mu-card-sub")!.textContent).toBe("Jazz · Recently added · up to 50");
    const f = page().querySelector<HTMLInputElement>(".mu-filter-input")!;
    f.value = "gym";
    f.dispatchEvent(new Event("input"));
    expect(texts(page(), ".mu-card-title")).toEqual(["Gym"]);
    f.value = "";
    f.dispatchEvent(new Event("input"));
    lists = [playlist("p1", { Name: "Road", ChildCount: 9 })];
    const mc = await import("../../src/views/musicCommon");
    mc.playlistsChanged.dispatchEvent(new Event("change"));
    await settle();
    expect(texts(page(), ".mu-card-title")).toEqual(["Fresh Jazz", "Road"]);
    expect(texts(page(), ".mu-card-sub")[1]).toBe("9 songs");
  });

  it("says there are none yet, and offers new playlists of both kinds", async () => {
    await boot();
    await music.renderMusic(content, "library/playlists");
    expect(page().querySelector(".state h3")!.textContent).toBe("No playlists yet");
    click(byText(page(), ".mu-filter button", "New Smart Playlist"));
    expect(location.hash).toBe("#/music/smart-edit/new");
    click(byText(page(), ".mu-filter button", "New Playlist"));
    await settle();
    expect(dialogTitle()).toBe("New Playlist");
    await pickDialog("Cancel");
  });

  it("stops listening for playlist changes once the page has gone", async () => {
    await boot((q) => (q.get("IncludeItemTypes") === "Playlist" ? [playlist("p1")] : []));
    await music.renderMusic(content, "library/playlists");
    content.textContent = "";
    const mc = await import("../../src/views/musicCommon");
    const before = paths(/IncludeItemTypes=Playlist/).length;
    mc.playlistsChanged.dispatchEvent(new Event("change"));
    await settle();
    mc.playlistsChanged.dispatchEvent(new Event("change"));
    await settle();
    // Only musicCommon's own prefetch asks, once per change; the page doesn't.
    expect(paths(/IncludeItemTypes=Playlist/).length - before).toBe(2);
  });
});

// ---------- Album ----------

describe("album page", () => {
  const tracks = [
    song("t1", { IndexNumber: 1, ParentIndexNumber: 1, RunTimeTicks: 1800 * TICKS_PER_SEC }),
    song("t2", { IndexNumber: 1, ParentIndexNumber: 2, RunTimeTicks: 1800 * TICKS_PER_SEC }),
  ];
  function albumServer(more: any = [album("al1"), album("al2")]): Parameters<typeof boot> {
    itemById.al1 = album("al1", { Genres: ["Jazz"] });
    return [(q) => (q.get("ParentId") === "al1" ? tracks : q.get("AlbumArtistIds") === "ar1" ? more : [])];
  }

  it("shows the header, the tracks by disc, and more by the artist without this album", async () => {
    await boot(...albumServer());
    const p = music.renderMusic(content, "album/al1");
    expect(page().querySelector(".spinner")).not.toBeNull();
    await p;
    expect(page().querySelector(".mu-eyebrow")!.textContent).toBe("Album");
    expect(page().querySelector("h1.mu-title")!.textContent).toBe("Album al1");
    const lines = texts(page(), ".mu-head-line");
    expect(lines).toEqual(["The Band", "Jazz · 2001 · 2 songs · 1 hr"]);
    expect(page().querySelector(".mu-head-line a.mu-link")!.getAttribute("href")).toBe("#/music/artist/ar1");
    expect(texts(page(), ".mu-disc")).toEqual(["Disc 1", "Disc 2"]);
    expect(byText(page(), ".mu-shelf h2", "More by The Band")).not.toBeNull();
    expect(texts(page(), ".mu-shelf .mu-card-title")).toEqual(["Album al2"]);
    click(byText(page(), ".mu-head-buttons button", "Play"));
    await settle();
    expect((audio.play as any).mock.calls[0][0]).toEqual(tracks);
  });

  it("leaves out More by when the artist has nothing else or can't be looked up, and an album with no artist", async () => {
    await boot(...albumServer({ __status: 500 }));
    await music.renderMusic(content, "album/al1");
    expect(page().querySelector(".mu-shelf")).toBeNull();
    itemById.al1 = album("al1", { AlbumArtists: [], AlbumArtist: undefined, ProductionYear: undefined, Genres: [] });
    musicServer({ items: (q) => (q.get("ParentId") === "al1" ? [song("t1", { RunTimeTicks: 0 })] : []), item: (id) => itemById[id] });
    await music.renderMusic(content, "album/al1");
    expect(texts(page(), ".mu-head-line")).toEqual(["1 song"]);
    expect(paths(/AlbumArtistIds/)).toHaveLength(1);
  });

  it("paints from the cache, and repaints only when the album or its tracks changed", async () => {
    await boot(...albumServer());
    await music.renderMusic(content, "album/al1");
    const p = music.renderMusic(content, "album/al1");
    const head = page().querySelector(".mu-head");
    expect(head).not.toBeNull();
    await p;
    expect(page().querySelector(".mu-head")).toBe(head);
    itemById.al1 = album("al1", { UserData: { IsFavorite: true } });
    await music.renderMusic(content, "album/al1");
    expect(page().querySelector(".mu-head")).not.toBe(head);
    const p2 = music.renderMusic(content, "album/al1");
    content.textContent = "";
    await p2;
    expect(content.children).toHaveLength(0);
  });
});

// ---------- Artist ----------

describe("artist page", () => {
  it("shows the backdrop, top songs, albums by year, appearances, the biography and similar artists", async () => {
    itemById.ar1 = artist("ar1", { Name: "Ann", BackdropImageTags: ["bd"], Genres: ["Jazz", "Soul", "Funk", "Pop"], Overview: "Born somewhere." });
    await boot((q) => {
      if (q.get("SortBy")?.startsWith("PlayCount") && q.get("ArtistIds") === "ar1") return [song("top1")];
      if (q.get("AlbumArtistIds") === "ar1") return [album("own", { ProductionYear: 1999 }), album("own2", { ProductionYear: undefined })];
      if (q.get("ArtistIds") === "ar1" && q.get("IncludeItemTypes") === "MusicAlbum") {
        return [album("own"), album("guest", { AlbumArtists: [{ Id: "zz", Name: "Other" }] })];
      }
      return [];
    }, [[/^\/Items\/ar1\/Similar\?userId=user-1&limit=12/, { Items: [artist("sim")] }]]);
    await music.renderMusic(content, "artist/ar1");
    expect(page().querySelector<HTMLElement>(".mu-artist-backdrop")!.style.backgroundImage).toMatch(/Images\/Backdrop/);
    expect(page().querySelector(".mu-head-cover.round")).not.toBeNull();
    expect(texts(page(), ".mu-head-line")).toEqual(["2 albums · Jazz, Soul, Funk"]);
    expect(texts(page(), ".mu-shelf h2")).toEqual(["Top Songs", "Albums", "Appears On", "About", "Similar Artists"]);
    expect(texts(byText(page(), ".mu-shelf", "Albums")!, ".mu-card-sub")).toEqual(["1999"]);
    expect(texts(byText(page(), ".mu-shelf", "Appears On")!, ".mu-card-title")).toEqual(["Album guest"]);
    expect(page().querySelector(".mu-about")!.textContent).toBe("Born somewhere.");
  });

  it("draws just the header when everything around the artist fails, and paints from the cache next time", async () => {
    itemById.ar1 = artist("ar1", { Name: "Solo" });
    await boot(() => ({ __status: 500 }), [[/\/Similar/, { __status: 500 }]]);
    await music.renderMusic(content, "artist/ar1");
    expect(page().querySelector(".mu-shelf")).toBeNull();
    expect(page().querySelector(".mu-artist-backdrop")).toBeNull();
    expect(texts(page(), ".mu-head-line")).toEqual([]);
    const p = music.renderMusic(content, "artist/ar1");
    const head = page().querySelector(".mu-head");
    await p;
    expect(page().querySelector(".mu-head")).toBe(head);
    itemById.ar1 = artist("ar1", { Name: "Solo", ImageTags: { Primary: "new" } });
    const p2 = music.renderMusic(content, "artist/ar1");
    content.textContent = "";
    await p2;
    expect(content.children).toHaveLength(0);
  });

  it("counts one album in the singular", async () => {
    itemById.ar1 = artist("ar1");
    await boot((q) => (q.get("AlbumArtistIds") === "ar1" ? [album("x")] : []), [[/\/Similar/, { Items: [] }]]);
    await music.renderMusic(content, "artist/ar1");
    expect(texts(page(), ".mu-head-line")).toEqual(["1 album"]);
  });
});

// ---------- Genre ----------

describe("genre page", () => {
  it("shows the popular songs and the albums, and plays the genre", async () => {
    itemById.g1 = { Id: "g1", Name: "Jazz", Type: "Genre" };
    await boot((q) => {
      if (q.get("GenreIds") !== "g1") return [];
      return q.get("IncludeItemTypes") === "Audio" ? (q.get("SortBy")?.startsWith("PlayCount") ? [song("p1")] : [song("r1")]) : [album("ja")];
    });
    await music.renderMusic(content, "genre/g1");
    expect(page().querySelector(".mu-eyebrow")!.textContent).toBe("Genre");
    expect(texts(page(), ".mu-shelf h2")).toEqual(["Popular Songs"]);
    expect(texts(page(), ".mu-grid .mu-card-title")).toEqual(["Album ja"]);
    click(byText(page(), ".mu-head-buttons button", "Play"));
    await settle();
    // Played as a MusicGenre: the genre's songs, in a random order from the server.
    expect((audio.play as any).mock.calls[0][0].map((s: any) => s.Id)).toEqual(["r1"]);
  });

  it("leaves out Popular Songs when there are none, and repaints from the cache only on change", async () => {
    itemById.g1 = { Id: "g1", Type: "Genre" };
    let albums = [album("a")];
    await boot((q) => (q.get("IncludeItemTypes") === "MusicAlbum" ? albums : []));
    await music.renderMusic(content, "genre/g1");
    expect(page().querySelector(".mu-shelf")).toBeNull();
    expect(page().querySelector("h1.mu-title")!.textContent).toBe("");
    const p = music.renderMusic(content, "genre/g1");
    const grid = page().querySelector(".mu-grid");
    await p;
    expect(page().querySelector(".mu-grid")).toBe(grid);
    albums = [album("b")];
    await music.renderMusic(content, "genre/g1");
    expect(texts(page(), ".mu-grid .mu-card-title")).toEqual(["Album b"]);
    const p2 = music.renderMusic(content, "genre/g1");
    content.textContent = "";
    await p2;
    expect(content.children).toHaveLength(0);
  });
});

// ---------- Playlist ----------

describe("playlist page", () => {
  const entries = () => [
    song("s1", { PlaylistItemId: "e1", RunTimeTicks: 60 * TICKS_PER_SEC }),
    song("s2", { PlaylistItemId: "e2" }),
    song("s3", { PlaylistItemId: "e3" }),
  ];
  let songs: any[];
  let writes: string[];

  async function open(list: any = playlist("pl1", { Name: "Road" }), extra: [string | RegExp, any][] = []) {
    songs = entries();
    writes = [];
    itemById.pl1 = list;
    await boot(() => [], [
      ...extra,
      [/^\/Playlists\/pl1\/Items\?entryIds=/, (a: JfArgs) => (writes.push(`${a.method} ${a.path}`), null)],
      [/^\/Playlists\/pl1\/Items\/[^/]+\/Move\//, (a: JfArgs) => (writes.push(`${a.method} ${a.path}`), null)],
      [/^\/Playlists\/pl1\/Items\?userId/, () => ({ Items: songs })],
      [/^\/Playlists\/pl1$/, (a: JfArgs) => (writes.push(`${a.method} ${a.path} ${JSON.stringify(a.body)}`), null)],
      [/^\/Items\/pl1$/, (a: JfArgs) => (writes.push(`${a.method} ${a.path}`), null)],
    ]);
    await music.renderMusic(content, "playlist/pl1");
  }

  it("shows the playlist with its length and plays from it", async () => {
    await open();
    expect(page().querySelector(".mu-eyebrow")!.textContent).toBe("Playlist");
    expect(texts(page(), ".mu-head-line")).toEqual(["3 songs · 8 min"]);
    expect(texts(page(), ".mu-head-buttons > button").map((t) => t.trim())).toEqual(["Play", "Shuffle", "Edit", ""]);
    click(byText(page(), ".mu-head-buttons button", "Shuffle"));
    await settle();
    expect((audio.play as any).mock.calls[0][2]).toEqual({ title: "Road", shuffle: true });
  });

  it("says when it is empty", async () => {
    itemById.pl1 = playlist("pl1");
    await boot(() => [], [[/^\/Playlists\/pl1\/Items/, { Items: [] }]]);
    await music.renderMusic(content, "playlist/pl1");
    expect(page().querySelector(".state h3")!.textContent).toBe("This playlist is empty");
    expect(texts(page(), ".mu-head-line")).toEqual(["0 songs"]);
  });

  it("offers Remove from Playlist on a song's right-click menu, and removes that entry", async () => {
    await open();
    rightClick(page().querySelectorAll(".mu-song")[1]!);
    expect(menuTitle()).toBe("Song s2");
    expect(menuLabels().at(-1)).toBe("Remove from Playlist");
    await pickMenu("Remove from Playlist");
    await settle();
    expect(writes).toEqual(["DELETE /Playlists/pl1/Items?entryIds=e2"]);
    expect(Array.from(page().querySelectorAll<HTMLElement>(".mu-song")).map((r) => r.dataset.id)).toEqual(["s1", "s3"]);
    // A right-click elsewhere on the page isn't the playlist's.
    rightClick(page().querySelector("h1"));
  });

  it("refuses to remove an entry the server didn't number, and reports a failed removal", async () => {
    await open(playlist("pl1"), [[/^\/Playlists\/pl1\/Items\?entryIds=e1/, { __status: 500 }]]);
    songs[1].PlaylistItemId = undefined;
    rightClick(page().querySelectorAll(".mu-song")[1]!);
    await pickMenu("Remove from Playlist");
    expect(lastToast()).toBe("The server didn't say which entry that is");
    rightClick(page().querySelectorAll(".mu-song")[0]!);
    await pickMenu("Remove from Playlist");
    await settle();
    expect(lastToast()).toMatch(/Server error 500/);
  });

  it("edits: × removes, a drop moves an entry, and Done goes back", async () => {
    await open();
    click(byText(page(), ".mu-head-buttons button", "Edit"));
    expect(page().querySelector(".mu-songs.editing")).not.toBeNull();
    expect(byText(page(), ".mu-head-buttons button", "Done")!.classList.contains("primary")).toBe(true);
    // No playlist menu on the edit rows.
    rightClick(page().querySelector(".mu-edit-row"));
    expect(document.querySelector(".menu")).toBeNull();
    click(page().querySelectorAll(".mu-edit-row")[0]!.querySelector("button[title='Remove from playlist']"));
    await settle();
    expect(writes).toEqual(["DELETE /Playlists/pl1/Items?entryIds=e1"]);
    expect(texts(page(), ".mu-edit-row .mu-song-title")).toEqual(["Song s2", "Song s3"]);
    // Drag the last onto the first.
    const rows = () => Array.from(page().querySelectorAll<HTMLElement>(".mu-edit-row"));
    const store = new Map<string, string>();
    const dt = { setData: (k: string, v: string) => store.set(k, v), getData: (k: string) => store.get(k) ?? "" };
    const fire = (n: HTMLElement, type: string) => {
      const ev = new Event(type, { bubbles: true, cancelable: true }) as any;
      ev.dataTransfer = dt;
      n.dispatchEvent(ev);
      return ev;
    };
    fire(rows()[1]!, "dragstart");
    expect(rows()[1]!.classList.contains("dragging")).toBe(true);
    expect(fire(rows()[0]!, "dragover").defaultPrevented).toBe(true);
    expect(rows()[0]!.classList.contains("drop-target")).toBe(true);
    fire(rows()[0]!, "dragleave");
    expect(rows()[0]!.classList.contains("drop-target")).toBe(false);
    fire(rows()[1]!, "dragend");
    expect(rows()[1]!.classList.contains("dragging")).toBe(false);
    fire(rows()[1]!, "dragstart");
    fire(rows()[0]!, "drop");
    await settle();
    expect(writes[1]).toBe("POST /Playlists/pl1/Items/e3/Move/0");
    expect(texts(page(), ".mu-edit-row .mu-song-title")).toEqual(["Song s3", "Song s2"]);
    // Dropping on itself does nothing.
    fire(rows()[0]!, "dragstart");
    fire(rows()[0]!, "drop");
    await settle();
    expect(writes).toHaveLength(2);
    click(byText(page(), ".mu-head-buttons button", "Done"));
    expect(page().querySelector(".mu-songs.editing")).toBeNull();
  });

  it("reports a move that failed, and ignores one of an entry with no number", async () => {
    await open(playlist("pl1"), [[/\/Move\//, { __status: 500 }]]);
    songs[2].PlaylistItemId = undefined;
    click(byText(page(), ".mu-head-buttons button", "Edit"));
    const rows = () => Array.from(page().querySelectorAll<HTMLElement>(".mu-edit-row"));
    const drop = (from: number, to: number) => {
      const ev = new Event("drop", { cancelable: true }) as any;
      ev.dataTransfer = { getData: () => String(from) };
      rows()[to]!.dispatchEvent(ev);
    };
    drop(2, 0);
    await settle();
    expect(toasts()).toEqual([]);
    drop(1, 0);
    await settle();
    expect(lastToast()).toMatch(/Server error 500/);
  });

  it("renames from More, and reports a rename that failed", async () => {
    await open();
    click(page().querySelector(".mu-head-buttons button[title=More]"));
    expect(menuLabels()).toEqual(["Rename…", "Start Station", "Delete Playlist"]);
    await pickMenu("Rename…");
    expect(dialogTitle()).toBe("Rename Playlist");
    dialogEl()!.querySelector<HTMLInputElement>("input")!.value = "Coast";
    await pickDialog("Save");
    await settle();
    expect(writes).toEqual([`POST /Playlists/pl1 {"Name":"Coast"}`]);
    expect(page().querySelector("h1.mu-title")!.textContent).toBe("Coast");
    // Cancelled: nothing sent.
    click(page().querySelector(".mu-head-buttons button[title=More]"));
    await pickMenu("Rename…");
    await pickDialog("Cancel");
    expect(writes).toHaveLength(1);
    musicServer({ extra: [[/^\/Playlists\/pl1$/, { __status: 500 }]] });
    click(page().querySelector(".mu-head-buttons button[title=More]"));
    await pickMenu("Rename…");
    await pickDialog("Save");
    await settle();
    expect(lastToast()).toMatch(/Server error 500/);
  });

  it("starts a station from More, and deletes the playlist after asking", async () => {
    await open();
    click(page().querySelector(".mu-head-buttons button[title=More]"));
    await pickMenu("Start Station");
    await settle();
    expect(toasts()).toContain("Starting a mix from Road…");
    click(page().querySelector(".mu-head-buttons button[title=More]"));
    await pickMenu("Delete Playlist");
    expect(dialogTitle()).toBe("Delete “Road”?");
    expect(dialogButtons()).toEqual(["Cancel", "Delete"]);
    // The safe choice has the focus.
    expect(document.activeElement!.textContent).toBe("Cancel");
    await pickDialog("Delete");
    await settle();
    expect(writes).toEqual(["DELETE /Items/pl1"]);
    expect(lastToast()).toBe("Playlist deleted");
    expect(location.hash).toBe("#/music/library/playlists");
  });

  it("reports a delete that failed", async () => {
    await open(playlist("pl1"), [[/^\/Items\/pl1$/, { __status: 403 }]]);
    click(page().querySelector(".mu-head-buttons button[title=More]"));
    await pickMenu("Delete Playlist");
    await pickDialog("Delete");
    await settle();
    expect(lastToast()).toMatch(/Server error 403/);
  });

  it("paints from the cache, and repaints when the songs or the name changed but not while editing", async () => {
    await open();
    const p = music.renderMusic(content, "playlist/pl1");
    const head = page().querySelector(".mu-head");
    await p;
    expect(page().querySelector(".mu-head")).toBe(head);
    itemById.pl1 = playlist("pl1", { Name: "Renamed" });
    await music.renderMusic(content, "playlist/pl1");
    expect(page().querySelector("h1.mu-title")!.textContent).toBe("Renamed");
    // Leaving before the answer: nothing painted over the next page.
    const p2 = music.renderMusic(content, "playlist/pl1");
    content.textContent = "";
    await p2;
    expect(content.children).toHaveLength(0);
  });

  it("keeps the edit list in place when the server answer arrives mid-edit", async () => {
    await open();
    let release!: (v: any) => void;
    musicServer({
      item: () => new Promise((r) => (release = r)),
      extra: [[/^\/Playlists\/pl1\/Items/, () => ({ Items: [song("new", { PlaylistItemId: "en" })] })]],
    });
    const p = music.renderMusic(content, "playlist/pl1");
    click(byText(page(), ".mu-head-buttons button", "Edit"));
    release(playlist("pl1", { Name: "Road" }));
    await p;
    expect(page().querySelector(".mu-songs.editing")).not.toBeNull();
    expect(texts(page(), ".mu-edit-row .mu-song-title")).toEqual(["Song s1", "Song s2", "Song s3"]);
  });
});

// ---------- Smart playlists ----------

describe("smart playlist page", () => {
  const sp = { id: "sp1", name: "Jazz Hour", genres: ["Jazz"], artists: [], limit: 2, order: "name" };

  it("says when the smart playlist is gone", async () => {
    await boot();
    await music.renderMusic(content, "smart/gone");
    expect(page().querySelector(".state h3")!.textContent).toBe("That smart playlist is gone");
  });

  it("answers the rules every time it's opened, with Edit Rules, Save to Server and Delete", async () => {
    let body: any;
    await boot((q) => (q.get("Genres") === "Jazz" ? [song("j1"), song("j2")] : []), [
      [/^\/Playlists$/, (a: JfArgs) => ((body = a.body), { Id: "frozen" })],
    ], { music_smart_playlists: [sp] });
    await music.renderMusic(content, "smart/sp1");
    expect(page().querySelector(".mu-eyebrow")!.textContent).toBe("Smart Playlist");
    expect(texts(page(), ".mu-head-line")).toEqual(["Jazz · Title · up to 2"]);
    expect(Array.from(page().querySelectorAll<HTMLElement>(".mu-song")).map((r) => r.dataset.id)).toEqual(["j1", "j2"]);
    click(byText(page(), ".mu-head-buttons button", "Play"));
    await settle();
    expect((audio.play as any).mock.calls[0][0].map((s: any) => s.Id)).toEqual(["j1", "j2"]);
    click(byText(page(), ".mu-head-buttons button", "Edit Rules"));
    expect(location.hash).toBe("#/music/smart-edit/sp1");
    click(byText(page(), ".mu-head-buttons button", "Save to Server…"));
    await settle();
    expect(dialogEl()!.querySelector<HTMLInputElement>("input")!.value).toBe("Jazz Hour");
    await pickDialog("Save");
    await settle();
    expect(body.Ids).toEqual(["j1", "j2"]);
    expect(lastToast()).toBe("Saved 2 songs as “Jazz Hour”");
    expect(location.hash).toBe("#/music/playlist/frozen");
  });

  it("sends nothing when Save to Server is cancelled, and reports one that failed", async () => {
    await boot((q) => (q.get("Genres") ? [song("j1")] : []), [[/^\/Playlists$/, { __status: 500 }]], { music_smart_playlists: [sp] });
    await music.renderMusic(content, "smart/sp1");
    click(byText(page(), ".mu-head-buttons button", "Save to Server…"));
    await settle();
    await pickDialog("Cancel");
    expect(paths(/^\/Playlists$/)).toHaveLength(0);
    click(byText(page(), ".mu-head-buttons button", "Save to Server…"));
    await settle();
    await pickDialog("Save");
    await settle();
    expect(lastToast()).toMatch(/Server error 500/);
  });

  it("says when nothing matches, and deletes only the rules", async () => {
    await boot(() => [], [], { music_smart_playlists: [sp, { id: "sp2", name: "Other" }] });
    await music.renderMusic(content, "smart/sp1");
    expect(page().querySelector(".state h3")!.textContent).toBe("Nothing matches these rules yet");
    click(byText(page(), ".mu-head-buttons button", "Delete"));
    expect(dialogTitle()).toBe("Delete “Jazz Hour”?");
    await pickDialog("Delete");
    await settle();
    expect(invokeCalls("config_save").at(-1)!.args.cfg.music_smart_playlists.map((p: any) => p.id)).toEqual(["sp2"]);
    expect(location.hash).toBe("#/music/library/playlists");
  });

  it("still leaves for the list when deleting the rules fails", async () => {
    await boot(() => [], [], { music_smart_playlists: [sp] });
    onInvoke("config_save", () => {
      throw new Error("read-only");
    });
    await music.renderMusic(content, "smart/sp1");
    click(byText(page(), ".mu-head-buttons button", "Delete"));
    await pickDialog("Delete");
    await settle();
    expect(lastToast()).toBe("read-only");
    expect(location.hash).toBe("#/music/library/playlists");
  });
});

describe("smart playlist editor", () => {
  it("makes a new smart playlist from the form and opens it", async () => {
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
    await boot(() => [], [
      [/^\/MusicGenres\?/, { Items: [{ Name: "Jazz" }, { Name: "Rock" }] }],
      [/^\/Artists\/AlbumArtists\?/, (a: JfArgs) => ({ Items: query(a.path).get("SearchTerm") === "ann" ? [artist("a1", { Name: "Ann" }), artist("a2", { Name: "Annie" })] : [] })],
    ]);
    await music.renderMusic(content, "smart-edit/new");
    expect(page().querySelector("h1")!.textContent).toBe("New Smart Playlist");
    const inputs = Array.from(page().querySelectorAll<HTMLInputElement>("input.mu-input"));
    const [name, search, yearFrom, yearTo, added, minPlays, , limit] = inputs;
    name!.value = "  Mine ";
    const genreSel = page().querySelector<HTMLSelectElement>("select[multiple]")!;
    genreSel.options[1]!.selected = true;
    // The artist search waits for a pause, then offers chips.
    search!.value = "ann";
    search!.dispatchEvent(new Event("input"));
    vi.advanceTimersByTime(250);
    await flush(30);
    expect(texts(page(), ".mu-chip.add")).toEqual(["+ Ann", "+ Annie"]);
    click(page().querySelector(".mu-chip.add"));
    expect(texts(page(), ".mu-chips .mu-chip")).toEqual(["Ann ×"]);
    expect(search!.value).toBe("");
    // Adding the same artist twice keeps one.
    search!.value = "ann";
    search!.dispatchEvent(new Event("input"));
    vi.advanceTimersByTime(250);
    await flush(30);
    click(page().querySelector(".mu-chip.add"));
    expect(texts(page(), ".mu-chips .mu-chip")).toEqual(["Ann ×"]);
    // An empty search clears the offers.
    search!.value = " ";
    search!.dispatchEvent(new Event("input"));
    vi.advanceTimersByTime(250);
    await flush(30);
    expect(page().querySelectorAll(".mu-chip.add")).toHaveLength(0);
    yearFrom!.value = "1960";
    yearTo!.value = "";
    added!.value = "-5";
    minPlays!.value = "3";
    limit!.value = "5000";
    const selects = Array.from(page().querySelectorAll<HTMLSelectElement>("select.mu-select:not([multiple])"));
    selects[0]!.value = "unplayed";
    selects[1]!.value = "year";
    page().querySelector<HTMLInputElement>("input[type=checkbox]")!.checked = true;
    vi.useRealTimers();
    click(byText(page(), ".mu-head-buttons button", "Save"));
    await settle();
    const saved = invokeCalls("config_save").at(-1)!.args.cfg.music_smart_playlists[0];
    expect(saved).toMatchObject({
      name: "Mine",
      genres: ["Rock"],
      artists: [{ id: "a1", name: "Ann" }],
      yearFrom: 1960,
      yearTo: null,
      addedWithinDays: 0,
      played: "unplayed",
      minPlays: 3,
      favoritesOnly: true,
      order: "year",
      limit: 1000,
    });
    expect(location.hash).toBe(`#/music/smart/${saved.id}`);
  });

  it("edits an existing one, removes an artist chip, and names a blank one Smart Playlist", async () => {
    const sp = { id: "sp1", name: "Old", genres: ["Jazz"], artists: [{ id: "a1", name: "Ann" }], yearFrom: 1950, yearTo: 1960, addedWithinDays: 30, minPlays: 2, played: "played", favoritesOnly: true, order: "name", limit: 0 };
    await boot(() => [], [[/^\/MusicGenres\?/, { __status: 500 }]], { music_smart_playlists: [sp] });
    await music.renderMusic(content, "smart-edit/sp1");
    expect(page().querySelector("h1")!.textContent).toBe("Edit Smart Playlist");
    // The genres list failed to load: no options, and the save keeps none.
    expect(page().querySelectorAll("select[multiple] option")).toHaveLength(0);
    click(byText(page(), ".mu-chips .mu-chip", "Ann"));
    expect(page().querySelectorAll(".mu-chips .mu-chip")).toHaveLength(0);
    page().querySelector<HTMLInputElement>("input.mu-input")!.value = "";
    click(byText(page(), ".mu-head-buttons button", "Save"));
    await settle();
    const saved = invokeCalls("config_save").at(-1)!.args.cfg.music_smart_playlists[0];
    expect(saved).toMatchObject({ id: "sp1", name: "Smart Playlist", artists: [], yearFrom: 1950, yearTo: 1960, addedWithinDays: 30, played: "played", limit: 100 });
  });

  it("goes back on Cancel, and reports a save that failed", async () => {
    await boot(() => [], [[/^\/MusicGenres\?/, { Items: [] }]]);
    onInvoke("config_save", () => {
      throw new Error("nope");
    });
    const back = vi.spyOn(history, "back").mockImplementation(() => {});
    await music.renderMusic(content, "smart-edit/new");
    click(byText(page(), ".mu-head-buttons button", "Cancel"));
    expect(back).toHaveBeenCalled();
    back.mockRestore();
    click(byText(page(), ".mu-head-buttons button", "Save"));
    await settle();
    expect(lastToast()).toBe("nope");
  });

  it("offers nothing when the artist search fails", async () => {
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
    await boot(() => [], [[/^\/MusicGenres\?/, { Items: [] }], [/^\/Artists\/AlbumArtists\?/, { __status: 500 }]]);
    await music.renderMusic(content, "smart-edit/new");
    const search = page().querySelectorAll<HTMLInputElement>("input.mu-input")[1]!;
    search.value = "x";
    search.dispatchEvent(new Event("input"));
    vi.advanceTimersByTime(250);
    await flush(30);
    expect(page().querySelectorAll(".mu-chip.add")).toHaveLength(0);
    vi.useRealTimers();
  });
});

// ---------- Search ----------

describe("music search", () => {
  function searchServer(fail = false): Parameters<typeof boot> {
    return [
      (q) => {
        if (fail) return { __status: 500 };
        const t = q.get("SearchTerm");
        if (t !== "blue") return [];
        if (q.get("IncludeItemTypes") === "MusicAlbum") return [album("b1")];
        if (q.get("IncludeItemTypes") === "Audio") return [song("bs")];
        if (q.get("IncludeItemTypes") === "Playlist") return [playlist("bp"), playlist("bv", { MediaType: "Video" })];
        return [];
      },
      [[/^\/Artists\?/, (a: JfArgs) => ({ Items: query(a.path).get("SearchTerm") === "blue" ? [artist("ba")] : [] })]],
    ];
  }

  it("searches the term in the address and groups what it finds", async () => {
    await boot(...searchServer());
    await music.renderMusic(content, "search/blue");
    expect(page().querySelector<HTMLInputElement>("input.mu-search")!.value).toBe("blue");
    expect(texts(page(), ".mu-shelf h2")).toEqual(["Artists", "Albums", "Songs", "Playlists"]);
    expect(texts(byText(page(), ".mu-shelf", "Playlists")!, ".mu-card-title")).toEqual(["List bp"]);
    await settle();
    expect(document.activeElement).toBe(page().querySelector("input.mu-search"));
  });

  it("says when nothing matches, shows nothing for no term, and an error when the search fails", async () => {
    await boot(...searchServer());
    await music.renderMusic(content, "search/zzz");
    expect(page().querySelector(".state h3")!.textContent).toBe("Nothing in your music for “zzz”");
    await music.renderMusic(content, "search");
    expect(page().querySelector(".state")).toBeNull();
    expect(jfPaths().filter((p) => /SearchTerm=$/.test(p))).toEqual([]);
    musicServer({ items: searchServer(true)[0] });
    await music.renderMusic(content, "search/blue");
    expect(page().querySelector(".state h3")!.textContent).toBe("Search failed");
  });

  it("searches again a moment after typing stops, and keeps the address in step", async () => {
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
    await boot(...searchServer());
    await music.renderMusic(content, "search");
    const replace = vi.spyOn(history, "replaceState");
    const input = page().querySelector<HTMLInputElement>("input.mu-search")!;
    input.value = "blu";
    input.dispatchEvent(new Event("input"));
    input.value = "blue ";
    input.dispatchEvent(new Event("input"));
    vi.advanceTimersByTime(300);
    await flush(40);
    expect(replace).toHaveBeenCalledTimes(1);
    expect(replace.mock.calls[0]![2]).toBe("#/music/search/blue");
    expect(texts(page(), ".mu-shelf h2")).toContain("Songs");
    replace.mockRestore();
    vi.useRealTimers();
  });
});

describe("animation (Linux/CLAUDE.md: no infinite animations on screens that stay visible)", () => {
  it("puts nothing on the music pages that the stylesheets animate forever", async () => {
    itemById.al1 = album("al1");
    await boot((q) => (q.get("ParentId") === "al1" ? [song("t1")] : []));
    audio.__playing([song("t1")]);
    await music.renderMusic(content, "album/al1");
    expect(page().querySelector(".mu-song.playing")).not.toBeNull();
    expect(foreverAnimated(document)).toEqual([]);
  });
});
