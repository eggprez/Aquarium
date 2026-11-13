// Home (src/views/home.ts): the spotlight and its rotation, the rows in the
// account's home-screen order, the library chips and On Now, and the
// cache-first paint. Real api / cache / ui / lineup / livetv under the mocked
// Tauri bridge; playItem (which would start libmpv) is a spy.
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { invokeCalls, jfPaths, mockJellyfin, signIn, type JfArgs } from "../helpers/tauri";
import { byText, click, key, menuTitle, mountShell, rightClick, settle, texts } from "../helpers/views-media";
import { foreverAnimated } from "../helpers/views-media-music";

vi.mock("../../src/playback", async (importOriginal) => {
  const real = await importOriginal<typeof import("../../src/playback")>();
  return {
    ...real,
    playItem: vi.fn(async () => {}),
    playChannelUrl: vi.fn(async () => {}),
    getNowPlaying: vi.fn(() => null),
  };
});

type Home = typeof import("../../src/views/home");

const T = 10_000_000;
let home: Home;
let playItem: any;
let cache: typeof import("../../src/cache");
let root: HTMLElement;

interface Srv {
  resume?: any[];
  nextUp?: any[];
  views?: any[];
  favorites?: any[];
  prefs?: any;
  latest?: Record<string, any[]>;
  channels?: any[];
  programs?: any[];
  fail?: boolean;
}
let srv: Srv;

beforeEach(() => {
  vi.resetModules();
  vi.clearAllMocks();
  srv = {};
});
afterEach(() => {
  location.hash = "";
});

function route(): void {
  const fail = () => srv.fail;
  const list = (v: any) => (fail() ? { __status: 500 } : { Items: v ?? [], TotalRecordCount: (v ?? []).length });
  mockJellyfin([
    [/^\/UserItems\/Resume\?/, () => list(srv.resume)],
    [/^\/Shows\/NextUp\?/, () => list(srv.nextUp)],
    [/^\/UserViews\?/, () => list(srv.views)],
    [/^\/Items\?.*Filters=IsFavorite/, () => list(srv.favorites)],
    [/^\/DisplayPreferences\/usersettings\?/, () => (fail() || !srv.prefs ? { __status: 404 } : srv.prefs)],
    [/^\/Items\/Latest\?/, (a: JfArgs) => (fail() ? { __status: 500 } : srv.latest?.[/parentId=([^&]+)/.exec(a.path)![1]!] ?? [])],
    [/^\/LiveTv\/Channels\?/, () => list(srv.channels)],
    [/^\/LiveTv\/Programs\?/, () => list(srv.programs)],
  ]);
}

async function boot(cfg: Record<string, any> = {}): Promise<void> {
  root = mountShell();
  route();
  await signIn(cfg);
  playItem = (await import("../../src/playback")).playItem;
  cache = await import("../../src/cache");
  home = await import("../../src/views/home");
}

const ep = (id: string, extra: any = {}) => ({
  Id: id,
  Type: "Episode",
  Name: `Ep ${id}`,
  SeriesName: "The Show",
  SeriesId: "ser1",
  ParentIndexNumber: 1,
  IndexNumber: 2,
  RunTimeTicks: 3000 * T,
  ParentBackdropItemId: "ser1",
  ParentBackdropImageTags: ["sb"],
  ImageTags: { Primary: "p" },
  UserData: {},
  ...extra,
});
const film = (id: string, extra: any = {}) => ({
  Id: id,
  Type: "Movie",
  Name: `Film ${id}`,
  ProductionYear: 2001,
  RunTimeTicks: 6000 * T,
  OfficialRating: "PG",
  CommunityRating: 7.25,
  BackdropImageTags: [`b-${id}`],
  ImageTags: { Primary: "p" },
  Overview: "About it.",
  UserData: {},
  ...extra,
});
const movies = { Id: "lib-m", Name: "Films", CollectionType: "movies" };
const shows = { Id: "lib-s", Name: "Shows", CollectionType: "tvshows" };
const music = { Id: "lib-mu", Name: "Music", CollectionType: "music" };
const live = { Id: "lib-tv", Name: "Live TV", CollectionType: "livetv" };

const sectionTitles = () => texts(root, ".section > .section-head h2");

describe("first visit", () => {
  it("shows a skeleton shaped like the page, then says there is nothing to watch with a way to Settings", async () => {
    await boot();
    const p = home.renderHome(root);
    expect(root.querySelector(".home-hero.skeleton")).not.toBeNull();
    expect(sectionTitles()).toEqual(["Continue Watching", "Latest"]);
    await p;
    expect(root.querySelector("h1.page-title")!.textContent).toBe("Home");
    expect(root.querySelector(".state h3")!.textContent).toBe("Nothing to watch yet");
    click(byText(root, ".state button", "Open Settings"));
    expect(location.hash).toBe("#/settings");
  });

  it("still draws when every request fails", async () => {
    srv.fail = true;
    await boot();
    await home.renderHome(root);
    expect(root.querySelector(".state h3")!.textContent).toBe("Nothing to watch yet");
  });

  it("asks only the userId= routes, and never puts a token in an address (Linux/CLAUDE.md)", async () => {
    srv = { views: [movies], resume: [film("r")], latest: { "lib-m": [film("l")] } };
    await boot();
    await home.renderHome(root);
    const ps = jfPaths();
    expect(ps.length).toBeGreaterThan(4);
    for (const p of ps) {
      expect(p).toMatch(/userId=user-1/);
      expect(p).not.toMatch(/api_key|X-Emby-Token/i);
    }
    for (const c of invokeCalls("jf_request")) expect(Object.keys(c.args).sort()).toEqual(["body", "method", "path"]);
  });
});

describe("the spotlight", () => {
  it("is Next Up, with the show's backdrop for an episode, its numbers, and Resume with the time left", async () => {
    srv = { nextUp: [ep("e1", { UserData: { PlaybackPositionTicks: 1500 * T } })] };
    await boot();
    await home.renderHome(root);
    const hero = root.querySelector(".home-hero")!;
    expect(hero.querySelector(".hero-eyebrow")!.textContent).toBe("Next up");
    expect(hero.querySelector(".hero-title .title-text")!.textContent).toBe("The Show");
    expect(hero.querySelector(".hero-sub")!.textContent).toBe("S1:E2 · Ep e1");
    expect(hero.querySelector<HTMLElement>(".hero-progress div")!.style.width).toBe("50%");
    const play = byText<HTMLButtonElement>(hero, ".hero-actions button", "Resume")!;
    expect(play.textContent).toMatch(/^Resume · .+ left$/);
    click(play);
    expect(playItem).toHaveBeenCalledWith(expect.objectContaining({ Id: "e1" }), { resume: true });
    click(byText(hero, ".hero-actions button", "Details"));
    expect(location.hash).toBe("#/item/e1");
    rightClick(hero);
    expect(menuTitle()).toBe("Ep e1");
  });

  it("falls back to Continue Watching, showing a film's year, length, rating and score", async () => {
    srv = { resume: [film("f1")] };
    await boot();
    await home.renderHome(root);
    const hero = root.querySelector(".home-hero")!;
    expect(hero.querySelector(".hero-eyebrow")!.textContent).toBe("Continue watching");
    expect(hero.querySelector(".hero-sub")).toBeNull();
    expect(hero.querySelector(".hero-meta")!.textContent).toMatch(/^2001 {2}· {2}.+ {2}· {2}PG {2}· {2}7\.3$/);
    expect(hero.querySelector(".hero-overview")!.textContent).toBe("About it.");
    expect(hero.querySelector(".hero-progress")).toBeNull();
    const play = byText(hero, ".hero-actions button", "Play")!;
    click(play);
    expect(playItem).toHaveBeenCalledWith(expect.objectContaining({ Id: "f1" }), { resume: false });
  });

  it("has no hero for an item with no artwork, and says Resume with no time when the length is unknown (regression: a963a95 \"Resume ( left)\" is just \"Resume\")", async () => {
    srv = { resume: [{ Id: "x", Type: "Movie", Name: "Bare", UserData: {} }] };
    await boot();
    await home.renderHome(root);
    expect(root.querySelector(".home-hero")).toBeNull();
    expect(root.querySelector("h1.page-title")!.textContent).toBe("Home");
    vi.resetModules();
    srv = { resume: [{ Id: "y", Type: "Movie", Name: "Short", BackdropImageTags: ["b"], UserData: { PlaybackPositionTicks: 10 } }] };
    await boot();
    await home.renderHome(root);
    expect(byText(root, ".hero-actions button", "Resume")!.textContent).toBe("Resume");
    expect(root.querySelector(".hero-meta")).toBeNull();
  });

  it("shows only the rating when there's nothing else to say, and an episode with no numbers by name", async () => {
    srv = { nextUp: [ep("e1", { ParentIndexNumber: undefined, RunTimeTicks: undefined, CommunityRating: 8 })] };
    await boot();
    await home.renderHome(root);
    expect(root.querySelector(".hero-sub")!.textContent).toBe("Ep e1");
    expect(root.querySelector(".hero-meta")!.textContent).toBe("8.0");
  });

  it("uses the episode's own backdrop when it has one, and the bare item when it has no parent backdrop", async () => {
    srv = { nextUp: [ep("e1", { BackdropImageTags: ["own"] }), ep("e2", { ParentBackdropItemId: undefined, BackdropImageTags: [] })] };
    await boot();
    await home.renderHome(root);
    // e2 has no art at all: one slide, so no rotator.
    expect(root.querySelector(".hero-stage")).toBeNull();
    expect(root.querySelector(".home-hero .hero-title .title-text")!.textContent).toBe("The Show");
  });
});

describe("the spotlight rotation", () => {
  async function rotating() {
    vi.useFakeTimers({ toFake: ["setInterval", "clearInterval", "Date"] });
    vi.setSystemTime(new Date("2026-06-01T12:00:00Z"));
    vi.spyOn(document, "hasFocus").mockReturnValue(true);
    srv = { nextUp: [ep("a", { BackdropImageTags: ["a"] }), ep("a"), ep("b", { BackdropImageTags: ["b"], SeriesName: undefined, Name: "Named" }), ep("c", { BackdropImageTags: ["c"], SeriesName: undefined, Name: undefined })] };
    await boot();
    await home.renderHome(root);
    const stage = root.querySelector<HTMLElement>(".hero-stage")!;
    const on = () => Array.from(stage.querySelectorAll(".hero-slide")).findIndex((s) => s.classList.contains("on"));
    const dots = () => Array.from(stage.querySelectorAll<HTMLButtonElement>(".hero-dots button"));
    return { stage, on, dots };
  }
  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("rotates through Next Up once each, every nine seconds, with a dot per slide", async () => {
    const { stage, on, dots } = await rotating();
    expect(stage.querySelectorAll(".hero-slide")).toHaveLength(3);
    expect(dots().map((d) => d.getAttribute("aria-label"))).toEqual(["Show The Show", "Show Named", "Show Item 3"]);
    expect(on()).toBe(0);
    vi.advanceTimersByTime(9000);
    expect(on()).toBe(1);
    expect(dots()[1]!.getAttribute("aria-current")).toBe("true");
    expect(dots()[0]!.classList.contains("on")).toBe(false);
    vi.advanceTimersByTime(9000);
    expect(on()).toBe(2);
    vi.advanceTimersByTime(9000);
    expect(on()).toBe(0);
  });

  it("goes to a slide when its dot is clicked, and restarts the clock", async () => {
    const { on, dots } = await rotating();
    vi.advanceTimersByTime(5000);
    click(dots()[2]);
    expect(on()).toBe(2);
    click(dots()[2]);
    // The click left the pointer over the spotlight; move it off.
    click(document.getElementById("toasts"));
    expect(document.querySelector(".hero-stage")!.matches(":hover")).toBe(false);
    vi.advanceTimersByTime(5000);
    expect(on()).toBe(2);
    vi.advanceTimersByTime(4000);
    expect(on()).toBe(0);
  });

  it("stands still when nobody has touched the window for thirty seconds, and starts again at the next touch", async () => {
    const { on } = await rotating();
    vi.advanceTimersByTime(27_000);
    expect(on()).toBe(0);
    vi.advanceTimersByTime(9000);
    expect(on()).toBe(0);
    window.dispatchEvent(new Event("pointermove"));
    vi.advanceTimersByTime(9000);
    expect(on()).toBe(1);
  });

  it("stands still while the window is unfocused or hidden, under a player, or under the pointer or keyboard", async () => {
    const { stage, on } = await rotating();
    const keepTouching = () => key(window, "Shift");
    vi.mocked(document.hasFocus).mockReturnValue(false);
    vi.advanceTimersByTime(9000);
    expect(on()).toBe(0);
    vi.mocked(document.hasFocus).mockReturnValue(true);
    const hidden = vi.spyOn(document, "hidden", "get").mockReturnValue(true);
    keepTouching();
    vi.advanceTimersByTime(9000);
    expect(on()).toBe(0);
    hidden.mockReturnValue(false);
    document.getElementById("content")!.classList.add("has-player");
    keepTouching();
    vi.advanceTimersByTime(9000);
    expect(on()).toBe(0);
    document.getElementById("content")!.classList.remove("has-player");
    const btn = stage.querySelector<HTMLButtonElement>(".hero-actions button")!;
    btn.focus();
    keepTouching();
    vi.advanceTimersByTime(9000);
    expect(on()).toBe(0);
    btn.blur();
    const hover = vi.spyOn(stage, "matches").mockImplementation((s: string) => s === ":hover");
    keepTouching();
    vi.advanceTimersByTime(9000);
    expect(on()).toBe(0);
    hover.mockRestore();
    keepTouching();
    vi.advanceTimersByTime(9000);
    expect(on()).toBe(1);
  });

  it("stops for good once the page is gone", async () => {
    const { stage } = await rotating();
    const clear = vi.spyOn(window, "clearInterval");
    stage.remove();
    vi.advanceTimersByTime(9000);
    expect(clear).toHaveBeenCalled();
  });
});

describe("the rows", () => {
  const full = (): Srv => ({
    resume: [film("r1")],
    nextUp: [ep("n1")],
    favorites: [film("fav1")],
    views: [movies, shows, music, live],
    latest: { "lib-m": [film("l1")], "lib-s": [] },
    channels: [{ Id: "ch1", Name: "News", ChannelNumber: "5", Type: "TvChannel" }],
    programs: [
      { Id: "pr1", ChannelId: "ch1", Name: "Evening News", StartDate: new Date(Date.now() - 600_000).toISOString(), EndDate: new Date(Date.now() + 600_000).toISOString() },
    ],
  });

  it("follows Jellyfin's default order when the account has none: libraries, Continue Watching, On Now, Next Up, Favorites, Latest", async () => {
    srv = full();
    await boot();
    await home.renderHome(root);
    expect(texts(root, ".home-chip")).toEqual(["Films", "Shows", "Live TV"]);
    expect(sectionTitles()).toEqual(["Continue Watching", "On Now", "Next Up", "Favorites", "Latest in Films"]);
    // Continue Watching is stills; Next Up is portrait season posters.
    expect(byText(root, ".section", "Continue Watching")!.querySelector(".card.wide")).not.toBeNull();
    expect(byText(root, ".section", "Next Up")!.querySelector(".card.wide")).toBeNull();
    expect(texts(byText(root, ".section", "On Now")!, ".card-title")).toEqual(["Evening News"]);
  });

  it("follows the account's own home-screen order, placing Favorites before Latest when there is no Next Up row", async () => {
    srv = { ...full(), prefs: { CustomPrefs: { homesection0: "latestmedia", HomeSection1: "resume", homesection2: "none", homesection3: "nextup", homesection4: "latestmedia", homesection5: 7 } } };
    await boot();
    await home.renderHome(root);
    expect(sectionTitles()).toEqual(["Favorites", "Latest in Films", "Continue Watching", "Next Up"]);
    expect(root.querySelector(".home-chips")).toBeNull();
  });

  it("puts Favorites at the end when the order has neither Next Up nor Latest", async () => {
    srv = { ...full(), prefs: { CustomPrefs: { homesection0: "resume", homesection1: "none", homesection2: "none", homesection3: "none", homesection4: "none", homesection5: "none", homesection6: "none" } } };
    await boot();
    await home.renderHome(root);
    expect(sectionTitles()).toEqual(["Continue Watching", "Favorites"]);
  });

  it("hides Continue Watching when Settings says so (regression: 849e879 hide Continue Watching)", async () => {
    srv = full();
    await boot({ hide_continue_watching: true });
    await home.renderHome(root);
    expect(sectionTitles()).not.toContain("Continue Watching");
    expect(sectionTitles()).toContain("Next Up");
  });

  it("shows Next Up as portrait season posters that open the show (regression: 849e879 season posters on Next Up)", async () => {
    srv = { nextUp: [ep("n1", { SeasonId: "se1", SeriesPrimaryImageTag: "sp" })] };
    await boot();
    await home.renderHome(root);
    const card = byText(root, ".section", "Next Up")!.querySelector<HTMLElement>(".card")!;
    expect(card.getAttribute("data-item-id")).toBe("ser1");
    expect(texts(card, ".card-sub")).toEqual(["Season 1: Episode 2", "Ep n1"]);
  });

  it("opens a library from its chip, Live TV from its own, and the See all links", async () => {
    srv = full();
    await boot();
    await home.renderHome(root);
    click(byText(root, ".home-chip", "Films"));
    expect(location.hash).toBe("#/lib/lib-m");
    click(byText(root, ".home-chip", "Live TV"));
    expect(location.hash).toBe("#/livetv");
    location.hash = "";
    click(byText(byText(root, ".section", "Favorites")!, ".see-all", "See all"));
    expect(location.hash).toBe("#/favorites");
    click(byText(byText(root, ".section", "Latest in Films")!, ".see-all", "See all"));
    expect(location.hash).toBe("#/lib/lib-m");
    location.hash = "";
    click(byText(byText(root, ".section", "On Now")!, ".see-all", "See all"));
    expect(location.hash).toBe("#/livetv");
  });

  it("tunes a channel from On Now through the guide's tuning screen (regression: 2dbaa46 On Now row tunes through the tuning screen)", async () => {
    srv = full();
    await boot();
    await home.renderHome(root);
    click(byText(root, ".section", "On Now")!.querySelector(".onnow-card"));
    expect(document.querySelector("#main .tuning")).not.toBeNull();
    await settle();
    expect(playItem).toHaveBeenCalledWith(expect.objectContaining({ Id: "ch1" }), { live: true }, { quiet: true, continuation: undefined });
  });

  it("has no On Now row without Live TV, or when the guide has nothing on (regression: dd655ac On Now reads the shared lineup)", async () => {
    srv = { ...full(), views: [movies] };
    await boot();
    await home.renderHome(root);
    expect(sectionTitles()).not.toContain("On Now");
    expect(jfPaths().some((p) => p.startsWith("/LiveTv/"))).toBe(false);
    vi.resetModules();
    srv = { ...full(), programs: [] };
    await boot();
    // The lineup the app loaded at launch is what On Now reads.
    const lineup = await import("../../src/lineup");
    cache.setCached(lineup.lineupKey(), srv.channels);
    await home.renderHome(root);
    expect(sectionTitles()).not.toContain("On Now");
    expect(jfPaths().filter((p) => p.startsWith("/LiveTv/Channels"))).toHaveLength(0);
  });

  it("falls back to the media libraries for chips, and to Jellyfin's order, when painting a Home cached without them", async () => {
    srv = { views: [movies], resume: [film("r")] };
    await boot();
    await home.renderHome(root);
    expect(texts(root, ".home-chip")).toEqual(["Films"]);
    // A Home cached by an older version had no library list.
    const data = cache.getCached<any>("home");
    cache.setCached("home", { ...data, libraries: undefined, sections: undefined });
    const p = home.renderHome(root);
    expect(texts(root, ".home-chip")).toEqual(["Films"]);
    await p;
  });

  it("names a library with no name", async () => {
    srv = { views: [{ Id: "x", CollectionType: "movies" }], resume: [film("r")] };
    await boot();
    await home.renderHome(root);
    expect(texts(root, ".home-chip")).toEqual(["Library"]);
  });
});

describe("cache-first paint (Linux/CLAUDE.md: getCached/setCached with a signature compare)", () => {
  it("paints the last Home at once and leaves it alone when nothing changed", async () => {
    srv = { resume: [film("r1")], views: [movies], latest: { "lib-m": [film("l1")] } };
    await boot();
    await home.renderHome(root);
    const p = home.renderHome(root);
    const first = root.querySelector(".section");
    expect(first).not.toBeNull();
    expect(root.querySelector(".skeleton")).toBeNull();
    await p;
    expect(root.querySelector(".section")).toBe(first);
    expect(cache.getCached<any>("home").resume[0].Id).toBe("r1");
  });

  it("repaints when the server's answer changed", async () => {
    srv = { resume: [film("r1")] };
    await boot();
    await home.renderHome(root);
    srv.resume = [film("r1", { UserData: { PlaybackPositionTicks: 3000 * T } })];
    await home.renderHome(root);
    expect(root.querySelector(".hero-progress")).not.toBeNull();
  });

  it("repaints when Continue Watching was switched off, though the server's answer is the same (regression: a setting that changes the page has to count as a change)", async () => {
    srv = { resume: [film("r1")], nextUp: [ep("n1")] };
    await boot();
    await home.renderHome(root);
    expect(sectionTitles()).toContain("Continue Watching");
    const api = await import("../../src/api");
    api.getConfig().hide_continue_watching = true;
    await home.renderHome(root);
    expect(sectionTitles()).not.toContain("Continue Watching");
  });

  it("doesn't paint over a page the user has moved to", async () => {
    srv = { resume: [film("r1")] };
    await boot();
    const p = home.renderHome(root);
    root.textContent = "";
    await p;
    expect(root.children).toHaveLength(0);
    expect(cache.getCached("home")).toBeUndefined();
  });

  it("puts nothing on Home that the stylesheets animate forever", async () => {
    srv = { resume: [film("r1"), film("r2")], nextUp: [ep("n1", { BackdropImageTags: ["x"] }), ep("n2", { BackdropImageTags: ["y"] })], views: [movies] };
    await boot();
    await home.renderHome(root);
    expect(foreverAnimated(document)).toEqual([]);
  });
});
