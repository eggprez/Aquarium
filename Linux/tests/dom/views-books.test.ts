// Audiobooks (src/views/books.ts): Listen Now, All Books, an author's books, a
// book's page with its chapters, and the books search; and how a book is
// played and resumed. Real api / musicApi / cache / ui under the mocked Tauri
// bridge; audio.ts is the stand-in from helpers/views-media-music.
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { flush, jfPaths, mockJellyfin, onInvoke, signIn, type JfArgs } from "../helpers/tauri";
import { byText, click, dblclick, key, lastToast, menuLabels, menuTitle, mountShell, pickMenu, rightClick, settle, texts } from "../helpers/views-media";
import { book, query, TICKS_PER_SEC, type FakeAudio } from "../helpers/views-media-music";

vi.mock("../../src/audio", async () => (await import("../helpers/views-media-music")).fakeAudioModule());
vi.mock("../../src/playback", async (importOriginal) => {
  const real = await importOriginal<typeof import("../../src/playback")>();
  return { ...real, downloadSeason: vi.fn(async () => ({ queued: 1, skipped: 0, cancelled: false })) };
});

type Books = typeof import("../../src/views/books");

let books: Books;
let audio: FakeAudio;
let cache: typeof import("../../src/cache");
let content: HTMLElement;

const MIN = 60 * TICKS_PER_SEC;

interface Srv {
  resume?: any;
  added?: any;
  all?: any;
  byTitle?: (term: string) => any;
  parts?: Record<string, any>;
  item?: Record<string, any>;
  played?: any;
}
let srv: Srv;
let writes: string[];

beforeEach(() => {
  vi.resetModules();
  vi.clearAllMocks();
  srv = {};
  writes = [];
});
afterEach(() => {
  location.hash = "";
});

function route(): void {
  mockJellyfin([
    [/^\/UserItems\/Resume\?/, () => (srv.resume?.__status ? srv.resume : { Items: srv.resume ?? [] })],
    [/^\/UserPlayedItems\//, (a: JfArgs) => (writes.push(`${a.method} ${a.path}`), srv.played ?? {})],
    [
      /^\/Items\?/,
      (a: JfArgs) => {
        const q = query(a.path);
        const wrap = (v: any) => (v?.__status ? v : { Items: v ?? [], TotalRecordCount: (v ?? []).length });
        if (q.get("ParentId")) return wrap(srv.parts?.[q.get("ParentId")!] ?? []);
        if (q.get("SearchTerm")) return wrap(srv.byTitle ? srv.byTitle(q.get("SearchTerm")!) : []);
        if (q.get("SortBy")?.startsWith("DateCreated")) return wrap(srv.added);
        return wrap(srv.all);
      },
    ],
    [/^\/Items\/[^/?]+\?/, (a: JfArgs) => srv.item?.[/^\/Items\/([^/?]+)/.exec(a.path)![1]!] ?? { __status: 404 }],
  ]);
}

async function boot(): Promise<void> {
  content = mountShell();
  route();
  onInvoke("downloads_list", []);
  await signIn();
  audio = (await import("../../src/audio")) as any;
  audio.__reset();
  cache = await import("../../src/cache");
  books = await import("../../src/views/books");
}

const page = () => content.querySelector<HTMLElement>(".mu-page")!;
const played = () => vi.mocked(audio.play).mock.calls as any[][];

const halfway = (id: string, extra: any = {}) =>
  book(id, { RunTimeTicks: 120 * MIN, UserData: { PlaybackPositionTicks: 30 * MIN }, ...extra });

describe("renderBooks", () => {
  it("renders into its own wrapper and routes to each page", async () => {
    await boot();
    content.append(document.createElement("aside"));
    await books.renderBooks(content, "");
    expect(content.children).toHaveLength(1);
    expect(page().querySelector("h1")!.textContent).toBe("Audiobooks");
    await books.renderBooks(content, "all");
    expect(page().querySelector("h1")!.textContent).toBe("All Books");
    await books.renderBooks(content, "author/Ann%20Author");
    expect(page().querySelector("h1")!.textContent).toBe("Ann Author");
    await books.renderBooks(content, "search");
    expect(page().querySelector("h1")!.textContent).toBe("Search Audiobooks");
    expect(texts(page(), ".mu-tab")).toEqual(["Listen Now", "All Books", "Search"]);
    expect(page().querySelector(".mu-tab.active")!.getAttribute("href")).toBe("#/books/search");
  });
});

describe("Listen Now", () => {
  it("shows a skeleton, then says there are no audiobooks yet", async () => {
    await boot();
    const p = books.renderBooks(content, "");
    expect(page().querySelector(".sk-box, .skeleton")).not.toBeNull();
    await p;
    expect(page().querySelector(".state h3")!.textContent).toBe("No audiobooks yet");
  });

  it("still draws when every request fails", async () => {
    srv = { resume: { __status: 500 }, added: { __status: 500 }, all: { __status: 500 } };
    await boot();
    await books.renderBooks(content, "");
    expect(page().querySelector(".state h3")!.textContent).toBe("No audiobooks yet");
  });

  it("shows Continue Listening with the time left, Recently Added and the authors by name", async () => {
    srv = {
      resume: [halfway("r1")],
      added: [book("n1")],
      all: [
        book("a", { AlbumArtists: [{ Name: "Zoe" }] }),
        book("b", { AlbumArtists: [], Artists: ["Bea", "Ann Author"] }),
        book("c", { AlbumArtist: undefined, AlbumArtists: [], Artists: [] }),
      ],
    };
    await boot();
    await books.renderBooks(content, "");
    expect(texts(page(), ".mu-shelf h2")).toEqual(["Continue Listening", "Recently Added", "Authors"]);
    expect(byText(page(), ".mu-shelf", "Continue Listening")!.querySelector(".mu-card-sub")!.textContent).toBe("1 hr 30 min left");
    expect(byText(page(), ".mu-shelf", "Recently Added")!.querySelector(".mu-card-sub")!.textContent).toBe("Ann Author");
    expect(texts(page(), ".mu-author")).toEqual(["Ann Author", "Bea", "Unknown author", "Zoe"]);
    expect(page().querySelector(".mu-author")!.getAttribute("href")).toBe("#/books/author/Ann%20Author");
    click(byText(page(), ".see-all", "See all"));
    expect(location.hash).toBe("#/books/all?sort=added");
    // The whole list is cached for All Books and search.
    expect(cache.getCached<any[]>("books:all")!.map((b) => b.Id)).toEqual(["a", "b", "c"]);
    // Only books: the query never asks for songs.
    for (const p of jfPaths()) expect(p).toMatch(/userId=user-1/);
  });

  it("paints the cached page at once and repaints only when it changed", async () => {
    srv = { added: [book("n1")] };
    await boot();
    await books.renderBooks(content, "");
    const p = books.renderBooks(content, "");
    const shelf = page().querySelector(".mu-shelf");
    expect(shelf).not.toBeNull();
    await p;
    expect(page().querySelector(".mu-shelf")).toBe(shelf);
    srv.added = [book("n2")];
    await books.renderBooks(content, "");
    expect(texts(page(), ".mu-card-title")).toEqual(["Book n2"]);
    const p2 = books.renderBooks(content, "");
    content.textContent = "";
    await p2;
    expect(content.children).toHaveLength(0);
  });

  it("marks how far a book has got, and its cover button resumes", async () => {
    srv = { resume: [halfway("r1")], item: { r1: halfway("r1", { Chapters: [] }) } };
    await boot();
    await books.renderBooks(content, "");
    const card = page().querySelector(".mu-card")!;
    expect(card.querySelector<HTMLElement>(".progress-strip div")!.style.width).toBe("25%");
    const play = card.querySelector<HTMLButtonElement>(".mu-cover-play")!;
    expect(play.title).toBe("Resume");
    location.hash = "";
    click(play);
    await settle();
    expect(location.hash).toBe("");
    const [items, start, opts] = played()[0]!;
    expect(items.map((b: any) => b.Id)).toEqual(["r1"]);
    expect(start).toBe(0);
    expect(opts).toEqual({ title: "Book r1", book: true, startSeconds: 1800 });
  });
});

describe("a book's menu", () => {
  async function menuFor(b: any) {
    srv = { all: [b], item: { [b.Id]: { ...b, Chapters: [{ Name: "c" }] } } };
    await boot();
    await books.renderBooks(content, "all");
    rightClick(page().querySelector(".mu-card"));
  }

  it("offers Resume with the time left, Play from Start, the queue, Mark as Finished, Download and Go to Author", async () => {
    await menuFor(halfway("b1"));
    expect(menuTitle()).toBe("Book b1");
    expect(menuLabels()).toEqual([
      "Resume (1 hr 30 min left)", "Play from Start", "Play Next", "Play Later", "Mark as Finished", "Download", "Go to Author",
    ]);
    await pickMenu("Play from Start");
    await settle();
    expect(played()[0]![2]).toEqual({ title: "Book b1", book: true, startSeconds: undefined });
    rightClick(page().querySelector(".mu-card"));
    await pickMenu("Resume");
    await settle();
    expect(played()[1]![2].startSeconds).toBe(1800);
  });

  it("says Play for a book not started, and the clock for one with no length", async () => {
    await menuFor(book("b1"));
    expect(menuLabels()[0]).toBe("Play");
    vi.resetModules();
    await menuFor(book("b2", { RunTimeTicks: 0, UserData: { PlaybackPositionTicks: 90 * TICKS_PER_SEC } }));
    expect(menuLabels()[0]).toBe("Resume (1:30)");
  });

  it("queues the book with its chapters, fetching them when the list left them out", async () => {
    await menuFor(book("b1"));
    await pickMenu("Play Next");
    await settle();
    expect(vi.mocked(audio.playNext).mock.calls[0]![0][0].Chapters).toEqual([{ Name: "c" }]);
    rightClick(page().querySelector(".mu-card"));
    await pickMenu("Play Later");
    await settle();
    expect(vi.mocked(audio.playLater).mock.calls[0]![0][0].Id).toBe("b1");
    expect(jfPaths().filter((p) => p.startsWith("/Items/b1?"))).toHaveLength(2);
  });

  it("reports a queue add that couldn't fetch the book", async () => {
    srv = { all: [book("b1")] };
    await boot();
    await books.renderBooks(content, "all");
    rightClick(page().querySelector(".mu-card"));
    await pickMenu("Play Later");
    await settle();
    expect(lastToast()).toMatch(/Server error 404/);
    rightClick(page().querySelector(".mu-card"));
    await pickMenu("Play Next");
    await settle();
    expect(lastToast()).toMatch(/Server error 404/);
  });

  it("marks a book finished and not finished on the server", async () => {
    await menuFor(book("b1"));
    await pickMenu("Mark as Finished");
    await settle();
    expect(lastToast()).toBe("Marked finished");
    vi.resetModules();
    await menuFor(book("b1", { UserData: { Played: true } }));
    await pickMenu("Mark as Not Finished");
    await settle();
    expect(lastToast()).toBe("Marked not finished");
    expect(writes).toEqual(["POST /UserPlayedItems/b1?userId=user-1", "DELETE /UserPlayedItems/b1?userId=user-1"]);
  });

  it("reports a mark that failed, downloads, and goes to the author", async () => {
    await menuFor(book("b1", { AlbumArtists: [], AlbumArtist: undefined, Artists: ["Ann & Co"] }));
    srv.played = { __status: 500 };
    await pickMenu("Mark as Finished");
    await settle();
    expect(lastToast()).toMatch(/Server error 500/);
    rightClick(page().querySelector(".mu-card"));
    await pickMenu("Download");
    await settle();
    expect((await import("../../src/playback")).downloadSeason).toHaveBeenCalled();
    rightClick(page().querySelector(".mu-card"));
    await pickMenu("Go to Author");
    expect(location.hash).toBe("#/books/author/Ann%20%26%20Co");
  });
});

describe("playBook", () => {
  it("plays a book in parts in track order and resumes at the part that was stopped in", async () => {
    const parts = [
      book("p2", { Type: "Audio", IndexNumber: 2, UserData: { PlaybackPositionTicks: 5 * MIN } }),
      book("p1", { Type: "Audio", IndexNumber: 1, UserData: { Played: true } }),
      book("p3", { Type: "Audio", IndexNumber: 3 }),
    ];
    srv = { parts: { f1: parts } };
    await boot();
    await books.playBook(book("f1", { IsFolder: true, Chapters: [] }), true);
    const [items, start, opts] = played()[0]!;
    expect(items.map((p: any) => p.Id)).toEqual(["p1", "p2", "p3"]);
    expect(start).toBe(1);
    expect(opts).toEqual({ title: "Book f1", book: true, startSeconds: 300 });
    const q = query(jfPaths().find((p) => p.includes("ParentId=f1"))!);
    expect(q.get("IncludeItemTypes")).toBe("AudioBook,Audio");
    expect(q.get("Fields")).toMatch(/Chapters/);
  });

  it("resumes a book in parts at the first unfinished part when none is in progress, and the start when all are", async () => {
    srv = {
      parts: {
        f1: [book("p1", { IndexNumber: 1, UserData: { Played: true } }), book("p2", { IndexNumber: 2 })],
        f2: [book("q1", { IndexNumber: 1, UserData: { Played: true } }), book("q2", { IndexNumber: 2, UserData: { Played: true } })],
      },
    };
    await boot();
    await books.playBook(book("f1", { ChildCount: 2, Chapters: [] }), true);
    expect(played()[0]![1]).toBe(1);
    await books.playBook(book("f2", { ChildCount: 2, Chapters: [] }), true);
    expect(played()[1]![1]).toBe(0);
  });

  it("plays a folder with no parts as itself, from a given time, or from the start", async () => {
    srv = { parts: { f1: [] } };
    await boot();
    const b = book("f1", { IsFolder: true, Chapters: [], UserData: { PlaybackPositionTicks: 10 * MIN } });
    await books.playBook(b, false, 42);
    expect(played()[0]![0]).toEqual([b]);
    expect(played()[0]![2].startSeconds).toBe(42);
    await books.playBook(b, false);
    expect(played()[1]![2].startSeconds).toBeUndefined();
  });

  it("reports a book that won't load", async () => {
    await boot();
    await books.playBook(book("gone"), true);
    expect(lastToast()).toMatch(/Server error 404/);
    expect(audio.play).not.toHaveBeenCalled();
  });
});

describe("All Books", () => {
  const all = () => [
    book("t1", { Name: "Beta", SortName: "beta", AlbumArtist: "Cid", DateCreated: "2024-01-01", UserData: { LastPlayedDate: "2025-03-01" } }),
    book("t2", { Name: "Alpha", AlbumArtist: "Zed", DateCreated: "2025-01-01", UserData: { LastPlayedDate: "2025-01-01" } }),
    book("t3", { Name: "Gamma", AlbumArtist: "Cid", DateCreated: undefined, UserData: {} }),
  ];
  const titles = () => texts(page(), ".mu-card-title");
  const sortTo = (v: string) => {
    const sel = page().querySelector<HTMLSelectElement>(".mu-select")!;
    sel.value = v;
    sel.dispatchEvent(new Event("change"));
  };

  it("lists every book by title, and by author, date added or last played, remembering the choice", async () => {
    srv = { all: all() };
    await boot();
    const p = books.renderBooks(content, "all");
    expect(page().querySelector(".spinner")).not.toBeNull();
    await p;
    expect(titles()).toEqual(["Alpha", "Beta", "Gamma"]);
    expect(page().querySelector(".lib-count")!.textContent).toBe("3 books");
    sortTo("author");
    expect(titles()).toEqual(["Beta", "Gamma", "Alpha"]);
    sortTo("added");
    expect(titles()).toEqual(["Alpha", "Beta", "Gamma"]);
    sortTo("played");
    expect(titles()).toEqual(["Beta", "Alpha", "Gamma"]);
    expect(localStorage.getItem("aquarium.books-sort")).toBe("played");
    await books.renderBooks(content, "all");
    expect(page().querySelector<HTMLSelectElement>(".mu-select")!.value).toBe("played");
    expect(titles()).toEqual(["Beta", "Alpha", "Gamma"]);
  });

  it("takes the sort from the address, and falls back to title for one it doesn't know", async () => {
    srv = { all: all() };
    await boot();
    location.hash = "#/books/all?sort=added";
    await books.renderBooks(content, "all");
    expect(page().querySelector<HTMLSelectElement>(".mu-select")!.value).toBe("added");
    location.hash = "#/books/all?sort=bogus";
    await books.renderBooks(content, "all");
    expect(titles()).toEqual(["Alpha", "Beta", "Gamma"]);
  });

  it("filters by title or author, counting what's shown", async () => {
    srv = { all: all() };
    await boot();
    await books.renderBooks(content, "all");
    const f = page().querySelector<HTMLInputElement>(".mu-filter-input")!;
    f.value = "zed";
    f.dispatchEvent(new Event("input"));
    expect(titles()).toEqual(["Alpha"]);
    expect(page().querySelector(".lib-count")!.textContent).toBe("1 book");
    f.value = "nothing";
    f.dispatchEvent(new Event("input"));
    expect(page().querySelector(".state h3")!.textContent).toBe("No books match");
  });

  it("says there are no audiobooks, and still works with no storage", async () => {
    await boot();
    const get = vi.spyOn(Storage.prototype, "getItem").mockImplementation(() => {
      throw new Error("denied");
    });
    const set = vi.spyOn(Storage.prototype, "setItem").mockImplementation(() => {
      throw new Error("denied");
    });
    try {
      await books.renderBooks(content, "all");
      expect(page().querySelector(".state h3")!.textContent).toBe("No audiobooks yet");
      sortTo("author");
      expect(page().querySelector(".state h3")!.textContent).toBe("No audiobooks yet");
    } finally {
      get.mockRestore();
      set.mockRestore();
    }
  });

  it("paints from the cached list, repaints when it changed, and not on a page that's gone", async () => {
    srv = { all: all() };
    await boot();
    await books.renderBooks(content, "all");
    const p = books.renderBooks(content, "all");
    const grid = page().querySelector(".mu-grid");
    expect(grid).not.toBeNull();
    await p;
    expect(page().querySelector(".mu-grid")).toBe(grid);
    srv.all = [book("new", { Name: "New" })];
    await books.renderBooks(content, "all");
    expect(titles()).toEqual(["New"]);
    const p2 = books.renderBooks(content, "all");
    content.textContent = "";
    await p2;
    expect(content.children).toHaveLength(0);
  });
});

describe("an author's books", () => {
  it("lists the books credited to the author, with their year", async () => {
    srv = {
      all: [
        book("a", { ProductionYear: 2001 }),
        book("b", { AlbumArtists: [], Artists: ["Ann Author"] }),
        book("c", { AlbumArtists: [{ Name: "Other" }] }),
        book("d", { AlbumArtists: [], AlbumArtist: "Ann Author", Artists: undefined }),
      ],
    };
    await boot();
    const p = books.renderBooks(content, "author/Ann%20Author");
    expect(page().querySelector(".mu-eyebrow")!.textContent).toBe("Author");
    expect(page().querySelector(".spinner")).not.toBeNull();
    await p;
    expect(texts(page(), ".mu-card-title")).toEqual(["Book a", "Book b", "Book d"]);
    expect(texts(page(), ".mu-card-sub")[0]).toBe("2001");
    // From the cache next time, and only repainted on change.
    const p2 = books.renderBooks(content, "author/Ann%20Author");
    const grid = page().querySelector(".mu-grid");
    await p2;
    expect(page().querySelector(".mu-grid")).toBe(grid);
    srv.all = [];
    await books.renderBooks(content, "author/Ann%20Author");
    expect(page().querySelector(".state h3")!.textContent).toBe("No books by this author");
    const p3 = books.renderBooks(content, "author/X");
    content.textContent = "";
    await p3;
    expect(content.children).toHaveLength(0);
  });
});

describe("a book's page", () => {
  const chaptered = (extra: any = {}) =>
    book("b1", {
      RunTimeTicks: 30 * MIN,
      ProductionYear: 2010,
      Overview: "<p>A <b>long</b> story.</p>",
      UserData: { PlaybackPositionTicks: 12 * MIN },
      Chapters: [
        { Name: "Opening", StartPositionTicks: 0 },
        { Name: "", StartPositionTicks: 10 * MIN },
        { Name: "End", StartPositionTicks: 20 * MIN },
      ],
      ...extra,
    });

  it("shows the header with the time left and progress, the description and the chapters, marking the one reached", async () => {
    srv = { item: { b1: chaptered() } };
    await boot();
    const p = books.renderBooks(content, "book/b1");
    expect(page().querySelector(".spinner")).not.toBeNull();
    await p;
    expect(page().querySelector(".mu-eyebrow")!.textContent).toBe("Audiobook");
    const lines = texts(page(), ".mu-head-line");
    expect(lines.slice(0, 2)).toEqual(["Ann Author", "2010 · 30 min · 18 min left"]);
    expect(page().querySelector(".mu-head-line a")!.getAttribute("href")).toBe("#/books/author/Ann%20Author");
    expect(page().querySelector<HTMLElement>(".mu-book-progress div")!.style.width).toBe("40%");
    expect(page().querySelector(".mu-about")!.textContent).toBe("A long story.");
    expect(byText(page(), ".mu-shelf h2", "Chapters (3)")).not.toBeNull();
    expect(texts(page(), ".mu-song-title")).toEqual(["Opening", "Chapter 2", "End"]);
    expect(texts(page(), ".mu-song .mu-song-time")).toEqual(["0:00", "10:00", "10:00", "10:00", "20:00", "10:00"]);
    expect(Array.from(page().querySelectorAll(".mu-song")).map((r) => r.classList.contains("playing"))).toEqual([false, true, false]);
    expect(texts(page(), ".mu-head-buttons > button").map((t) => t.trim()).slice(0, 3)).toEqual(["Resume at 12:00", "Play from Start", "1×"]);
  });

  it("plays from the header buttons and from a chapter", async () => {
    srv = { item: { b1: chaptered() } };
    await boot();
    await books.renderBooks(content, "book/b1");
    click(byText(page(), ".mu-head-buttons button", "Resume at"));
    await settle();
    expect(played()[0]![2].startSeconds).toBe(720);
    click(byText(page(), ".mu-head-buttons button", "Play from Start"));
    await settle();
    expect(played()[1]![2].startSeconds).toBeUndefined();
    const rows = page().querySelectorAll<HTMLElement>(".mu-song");
    dblclick(rows[1]);
    key(rows[2], "Enter");
    key(rows[2], "a");
    click(rows[0]!.querySelector(".mu-song-play"));
    await settle();
    expect(played().slice(2).map((c) => c[2].startSeconds)).toEqual([600, 1200, undefined]);
  });

  it("sets the speed from its menu, and opens the book's menu from More", async () => {
    srv = { item: { b1: chaptered() } };
    await boot();
    await books.renderBooks(content, "book/b1");
    const speed = page().querySelector<HTMLButtonElement>(".mu-head-buttons button[title='Playback speed']")!;
    click(speed);
    expect(menuTitle()).toBe("Speed");
    expect(menuLabels()).toContain("1×  ✓");
    await pickMenu("1.25×");
    expect(vi.mocked(audio.setSpeed).mock.calls[0]![0]).toBe(1.25);
    expect(speed.textContent).toBe("1.25×");
    click(page().querySelector(".mu-head-buttons button[title=More]"));
    expect(menuLabels()[0]).toMatch(/^Resume \(/);
  });

  it("says Finished for a finished book, and Play for one not started, with no chapters", async () => {
    srv = { item: { b1: book("b1", { UserData: { Played: true } }), b2: book("b2", { RunTimeTicks: 0 }) } };
    await boot();
    await books.renderBooks(content, "book/b1");
    expect(texts(page(), ".mu-head-line")[1]).toBe("1 hr · Finished");
    expect(page().querySelector(".mu-book-progress")).toBeNull();
    expect(page().querySelector(".mu-shelf")).toBeNull();
    expect(page().querySelector(".mu-about")).toBeNull();
    await books.renderBooks(content, "book/b2");
    expect(texts(page(), ".mu-head-buttons > button").map((t) => t.trim())[0]).toBe("Play");
    expect(byText(page(), ".mu-head-buttons button", "Play from Start")).toBeNull();
  });

  it("gives the last chapter the rest of the book, and nothing for a book shorter than its last mark", async () => {
    srv = { item: { b1: book("b1", { RunTimeTicks: 5 * MIN, Chapters: [{ StartPositionTicks: 0 }, { StartPositionTicks: 6 * MIN }] }) } };
    await boot();
    await books.renderBooks(content, "book/b1");
    expect(texts(page(), ".mu-song .mu-song-time")).toEqual(["0:00", "6:00", "6:00", ""]);
  });

  it("shows an error when the book won't load, but keeps a cached page", async () => {
    srv = { item: { b1: chaptered() } };
    await boot();
    await books.renderBooks(content, "book/b1");
    srv.item = {};
    await books.renderBooks(content, "book/b1");
    expect(page().querySelector(".mu-head")).not.toBeNull();
    expect(page().querySelector(".state")).toBeNull();
    await books.renderBooks(content, "book/other");
    expect(page().querySelector(".state h3")!.textContent).toBe("This book didn't load");
  });

  it("paints from the cache and repaints only on change, and not on a page that's gone", async () => {
    srv = { item: { b1: chaptered() } };
    await boot();
    await books.renderBooks(content, "book/b1");
    const p = books.renderBooks(content, "book/b1");
    const head = page().querySelector(".mu-head");
    await p;
    expect(page().querySelector(".mu-head")).toBe(head);
    srv.item = { b1: chaptered({ UserData: { PlaybackPositionTicks: 25 * MIN } }) };
    await books.renderBooks(content, "book/b1");
    expect(page().querySelector(".mu-head")).not.toBe(head);
    const p2 = books.renderBooks(content, "book/b1");
    content.textContent = "";
    await p2;
    expect(content.children).toHaveLength(0);
  });
});

describe("books search", () => {
  it("finds books by title on the server and by author from the full list, without repeats", async () => {
    srv = {
      byTitle: (t) => (t === "ann" ? [book("t1", { Name: "Anna's Story", AlbumArtist: "Ann Author" })] : []),
      all: [book("t1", { AlbumArtist: "Ann Author" }), book("t2", { AlbumArtist: "Annie" }), book("t3", { AlbumArtist: "Bob", AlbumArtists: [] })],
    };
    await boot();
    await books.renderBooks(content, "search/ann");
    expect(page().querySelector<HTMLInputElement>("input.mu-search")!.value).toBe("ann");
    expect(texts(page(), ".mu-card-title")).toEqual(["Anna's Story", "Book t2"]);
    await settle();
    expect(document.activeElement).toBe(page().querySelector("input.mu-search"));
  });

  it("uses the cached full list when there is one", async () => {
    srv = { all: [book("t2", { AlbumArtist: "Annie" })] };
    await boot();
    cache.setCached("books:all", [book("c1", { AlbumArtist: "Annie" })]);
    await books.renderBooks(content, "search/annie");
    expect(texts(page(), ".mu-card-title")).toEqual(["Book c1"]);
  });

  it("says when nothing matches, shows nothing without a term, and an error when the search fails", async () => {
    await boot();
    await books.renderBooks(content, "search/zzz");
    expect(page().querySelector(".state h3")!.textContent).toBe("No audiobooks match “zzz”");
    await books.renderBooks(content, "search");
    expect(page().querySelector(".state")).toBeNull();
    srv.byTitle = () => ({ __status: 500 });
    await books.renderBooks(content, "search/x");
    expect(page().querySelector(".state h3")!.textContent).toBe("Search failed");
  });

  it("searches a moment after typing stops and keeps the address in step", async () => {
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
    srv = { byTitle: (t) => (t === "x" ? [book("x1")] : []) };
    await boot();
    await books.renderBooks(content, "search");
    const replace = vi.spyOn(history, "replaceState");
    const input = page().querySelector<HTMLInputElement>("input.mu-search")!;
    input.value = " x ";
    input.dispatchEvent(new Event("input"));
    vi.advanceTimersByTime(300);
    await flush(40);
    expect(replace.mock.calls[0]![2]).toBe("#/books/search/x");
    expect(texts(page(), ".mu-card-title")).toEqual(["Book x1"]);
    replace.mockRestore();
    vi.useRealTimers();
  });
});
