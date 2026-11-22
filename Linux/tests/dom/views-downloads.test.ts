// The Downloads page (src/views/downloads.ts), rendered into jsdom with the
// real api.ts / playback.ts / ui.ts behind the mocked Tauri bridge.
import { beforeEach, describe, expect, it, vi } from "vitest";
import {
  emitEvent,
  flush,
  invokeCalls,
  jfPaths,
  mockJellyfin,
  onInvoke,
  onInvokes,
  signIn,
} from "../helpers/tauri";
import {
  byText,
  click,
  clearToasts,
  dialogButtons,
  dialogEl,
  dialogTitle,
  key,
  lastToast,
  menuLabels,
  menuTitle,
  mountShell,
  openMenuEl,
  pickDialog,
  pickMenu,
  rightClick,
  settle,
  texts,
  toasts,
} from "../helpers/views-media";

type Downloads = typeof import("../../src/views/downloads");
type Playback = typeof import("../../src/playback");
type Api = typeof import("../../src/api");

const GiB = 1 << 30;
const MIN = 600_000_000; // one minute in ticks

let view: Downloads;
let playback: Playback;
let api: Api;
let root: HTMLElement;
/** What `downloads_list` answers. Tests mutate it; `download_delete` removes from it. */
let list: any[];
/** What `/Items?userId=` answers (watch-state and details refresh). */
let serverItems: any[];
let pendingIds: string[];
let pendingCount: number;

function ep(id: string, series: string, season: number | null, episode: number, extra: any = {}): any {
  return {
    item_id: id,
    type: "Episode",
    status: "complete",
    path: `/dl/${id}.mkv`,
    series,
    season,
    episode,
    name: `Part ${episode}`,
    title: `${series} S${season}E${episode}`,
    size_bytes: GiB,
    quality: "720p · 4.5 Mbps",
    run_time_ticks: 30 * MIN,
    position_ticks: 0,
    played: false,
    poster_path: `/dl/${id}.jpg`,
    ...extra,
  };
}

function movie(id: string, title: string, extra: any = {}): any {
  return {
    item_id: id,
    type: "Movie",
    status: "complete",
    path: `/dl/${id}.mkv`,
    title,
    name: title,
    year: 2021,
    size_bytes: 2 * GiB,
    quality: "Original quality",
    run_time_ticks: 100 * MIN,
    position_ticks: 0,
    played: false,
    poster_path: `/dl/${id}.jpg`,
    ...extra,
  };
}

function deferred<T>(): { promise: Promise<T>; resolve: (v: T) => void } {
  let resolve!: (v: T) => void;
  const promise = new Promise<T>((r) => (resolve = r));
  return { promise, resolve };
}

/** Sign in, load the modules fresh and answer every command the page uses. */
async function boot(cfg: Record<string, any> = {}, opts: { signedIn?: boolean } = {}): Promise<void> {
  onInvokes({
    downloads_list: () => list,
    progress_pending: () => pendingCount,
    progress_pending_ids: () => pendingIds,
    progress_sync: () => ({ synced: pendingCount, failed: 0 }),
    progress_store_local: null,
    download_delete: ({ itemId }: any) => {
      list = list.filter((d) => d.item_id !== itemId);
      return null;
    },
    download_cancel: null,
    download_pause: null,
    download_retry: null,
    download_set_watch_state: null,
    download_update_details: null,
    download_fetch_subtitles: null,
    downloads_reveal: null,
    downloads_sync_keep_awake: null,
    network_metered: false,
    player_play: null,
  });
  mockJellyfin([[/^\/Items\?userId=/, () => ({ Items: serverItems })]]);
  if (opts.signedIn === false) {
    api = await import("../../src/api");
  } else {
    api = await signIn(cfg);
  }
  playback = await import("../../src/playback");
  view = await import("../../src/views/downloads");
}

async function open(opts: { keepTab?: boolean } = {}): Promise<void> {
  await view.renderDownloads(root, opts);
  await settle();
}

function tab(label: string): HTMLElement {
  const b = byText(root, ".dl-tabs .btn", label);
  if (!b) throw new Error(`no ${label} tab`);
  return b;
}

function card(title: string): HTMLElement {
  const c = Array.from(root.querySelectorAll<HTMLElement>(".card")).find(
    (n) => n.querySelector(".card-title")?.textContent === title
  );
  if (!c) throw new Error(`no card titled ${title}`);
  return c;
}

function row(title: string): HTMLElement {
  const r = Array.from(root.querySelectorAll<HTMLElement>(".dl-row")).find((n) =>
    (n.querySelector("h4")?.textContent ?? "").includes(title)
  );
  if (!r) throw new Error(`no row titled ${title}`);
  return r;
}

function button(scope: ParentNode, label: string | RegExp): HTMLButtonElement {
  const b = byText<HTMLButtonElement>(scope, "button", label);
  if (!b) throw new Error(`no button ${label}`);
  return b;
}

function played(): any[] {
  return invokeCalls("player_play").map((c) => c.args.req);
}

function deleted(): string[] {
  return invokeCalls("download_delete").map((c) => c.args.itemId);
}

/** Put entries in the in-memory queue the way a restart does. */
async function restoreQueue(entries: any[]): Promise<void> {
  localStorage.setItem("aquarium-dl-queue", JSON.stringify(entries));
  await playback.restoreDownloadQueue();
  await flush(30);
}

const Q720 = { label: "720p · 4.5 Mbps", name: "720p", videoBitrate: 4_500_000, audioBitrate: 192_000, maxWidth: 1280 };
const QORIG = { label: "Original quality", original: true };

beforeEach(async () => {
  vi.resetModules();
  root = mountShell();
  list = [];
  serverItems = [];
  pendingIds = [];
  pendingCount = 0;
  location.hash = "";
});

// ---------------------------------------------------------------------------

describe("first paint and the header", () => {
  it("shows a skeleton only until the first list arrives, then the page", async () => {
    await boot();
    const gate = deferred<any[]>();
    onInvoke("downloads_list", () => gate.promise);
    const p = view.renderDownloads(root);
    expect(root.querySelector(".dl-tabs")).toBeNull();
    expect(root.children.length).toBe(1); // the skeleton grid
    gate.resolve([]);
    await p;
    expect(root.querySelector("h1.page-title")?.textContent).toBe("Downloads");
    expect(texts(root, ".dl-tabs .btn")).toEqual(["TV", "Movies", "Queue"]);
    expect(tab("TV").classList.contains("active")).toBe(true);
  });

  it("keeps the current page on screen while a refresh loads, instead of flashing a skeleton", async () => {
    list = [movie("m1", "Arrival")];
    await boot();
    await open();
    click(tab("Movies"));
    const before = card("Arrival");
    const gate = deferred<any[]>();
    onInvoke("downloads_list", () => gate.promise);
    const p = view.renderDownloads(root, { keepTab: true });
    expect(document.contains(before)).toBe(true);
    expect(root.querySelector(".dl-tabs")).not.toBeNull();
    gate.resolve([movie("m1", "Arrival"), movie("m2", "Brazil")]);
    await p;
    expect(texts(root, ".card-title")).toEqual(["Arrival", "Brazil"]);
    expect(tab("Movies").classList.contains("active")).toBe(true);
  });

  it("counts each tab, and leaves the count off an empty one", async () => {
    list = [
      ep("e1", "Alpha", 1, 1),
      ep("e2", "Alpha", 1, 2),
      movie("m1", "Arrival"),
      { item_id: "x1", status: "error", title: "Broken", error: "boom" },
    ];
    await boot();
    await open();
    expect(tab("TV").querySelector(".dl-tab-count")?.textContent).toBe("2");
    expect(tab("Movies").querySelector(".dl-tab-count")?.textContent).toBe("1");
    expect(tab("Queue").querySelector(".dl-tab-count")?.textContent).toBe("1");
    list = [];
    await open({ keepTab: true });
    expect(root.querySelectorAll(".dl-tab-count").length).toBe(0);
  });

  it("says whether watch state is waiting to sync, and Sync now pushes it and repaints", async () => {
    pendingCount = 2;
    await boot();
    await open();
    expect(root.querySelector(".sync-pill")?.textContent).toBe("2 watch state(s) waiting to sync");
    let queueEvents = 0;
    const onQueue = (): void => void queueEvents++;
    document.addEventListener("aquarium-progress-queue", onQueue);
    onInvoke("progress_sync", () => {
      pendingCount = 0;
      return { synced: 2, failed: 0 };
    });
    click(button(root, "Sync now"));
    await settle();
    document.removeEventListener("aquarium-progress-queue", onQueue);
    expect(invokeCalls("progress_sync").length).toBe(1);
    expect(toasts()).toContain("Synced 2 item(s) to Jellyfin");
    expect(queueEvents).toBe(1);
    expect(root.querySelector(".sync-pill")?.textContent).toBe("Watch state in sync");
  });

  it("opens on TV at the top level unless told to keep the tab", async () => {
    list = [ep("e1", "Alpha", 1, 1), movie("m1", "Arrival")];
    await boot();
    await open();
    click(tab("Movies"));
    await open({ keepTab: true });
    expect(tab("Movies").classList.contains("active")).toBe(true);
    await open();
    expect(tab("TV").classList.contains("active")).toBe(true);
    expect(texts(root, ".card-title")).toEqual(["Alpha"]);
  });

  it("the parallel selector lists 1 to the maximum, shows the current limit and changes it", async () => {
    localStorage.setItem("aquarium-dl-concurrency", "3");
    await boot();
    await open();
    const select = root.querySelector<HTMLSelectElement>(".dl-concurrency-wrap select")!;
    expect(Array.from(select.options).map((o) => o.textContent)).toEqual([
      "1 at a time", "2 at a time", "3 at a time", "4 at a time", "5 at a time", "6 at a time",
    ]);
    expect(select.options.length).toBe(playback.MAX_DOWNLOAD_CONCURRENCY);
    expect(select.value).toBe("3");
    select.value = "1";
    select.dispatchEvent(new Event("change"));
    expect(playback.getDownloadConcurrency()).toBe(1);
    expect(lastToast()).toBe("Downloading one at a time");
    select.value = "4";
    select.dispatchEvent(new Event("change"));
    expect(playback.getDownloadConcurrency()).toBe(4);
    expect(lastToast()).toBe("Downloading up to 4 at a time");
  });
});

describe("stale-page guards (regression: a963a95)", () => {
  it("does not draw over a page the user has already navigated away to", async () => {
    await boot();
    const gate = deferred<any[]>();
    onInvoke("downloads_list", () => gate.promise);
    const p = view.renderDownloads(root);
    // The router replaced the content while the list was loading.
    root.innerHTML = "<h1>Settings</h1>";
    gate.resolve([movie("m1", "Arrival")]);
    await p;
    await settle();
    expect(root.innerHTML).toBe("<h1>Settings</h1>");
  });

  it("only the latest of two overlapping renders paints", async () => {
    await boot();
    const first = deferred<any[]>();
    const second = deferred<any[]>();
    const gates = [first, second];
    onInvoke("downloads_list", () => gates.shift()!.promise);
    const a = view.renderDownloads(root);
    const b = view.renderDownloads(root, { keepTab: true });
    second.resolve([movie("m2", "Newer")]);
    await b;
    first.resolve([movie("m1", "Older")]);
    await a;
    click(tab("Movies"));
    expect(texts(root, ".card-title")).toEqual(["Newer"]);
  });
});

// ---------------------------------------------------------------------------

describe("TV tab", () => {
  it("says what to do when nothing is downloaded, and the button goes Home", async () => {
    await boot();
    await open();
    expect(root.querySelector(".state h3")?.textContent).toBe("No TV downloads yet");
    click(button(root, "Browse shows"));
    expect(location.hash).toBe("#/home");
  });

  it("groups episodes by series, alphabetically, with counts and watched totals", async () => {
    list = [
      ep("z1", "Zeta", 1, 1),
      ep("a1", "Alpha", 1, 1, { played: true }),
      ep("a2", "Alpha", 1, 2),
      ep("a3", "Alpha", 2, 1),
    ];
    await boot();
    await open();
    expect(texts(root, ".card-title")).toEqual(["Alpha", "Zeta"]);
    expect(card("Alpha").querySelector(".card-sub")?.textContent).toBe("3 episodes · 1 watched");
    expect(card("Zeta").querySelector(".card-sub")?.textContent).toBe("1 episode");
    expect(card("Alpha").getAttribute("aria-label")).toBe("Alpha — 3 episodes · 1 watched");
  });

  it("treats an untyped download with a series as an episode, and a Movie with one as a film", async () => {
    list = [
      { ...ep("e1", "Alpha", 1, 1), type: undefined },
      { ...movie("m1", "Spin-off Film"), series: "Alpha" },
    ];
    await boot();
    await open();
    expect(texts(root, ".card-title")).toEqual(["Alpha"]);
    expect(card("Alpha").querySelector(".card-sub")?.textContent).toBe("1 episode");
    click(tab("Movies"));
    expect(texts(root, ".card-title")).toEqual(["Spin-off Film"]);
  });

  it("puts a tick on a fully watched series and a strip on a partly watched one", async () => {
    list = [
      ep("a1", "Alpha", 1, 1, { played: true }),
      ep("a2", "Alpha", 1, 2, { played: true }),
      // One episode two thirds through, the other untouched: a third overall.
      ep("b1", "Beta", 1, 1, { position_ticks: 20 * MIN }),
      ep("b2", "Beta", 1, 2),
      ep("c1", "Gamma", 1, 1),
    ];
    await boot();
    await open();
    expect(card("Alpha").querySelector(".badge.played")).not.toBeNull();
    expect(card("Alpha").querySelector(".progress-strip")).toBeNull();
    const strip = card("Beta").querySelector<HTMLElement>(".progress-strip > div")!;
    expect(parseFloat(strip.style.width)).toBeCloseTo(33.33, 1);
    expect(card("Beta").querySelector(".badge.played")).toBeNull();
    expect(card("Gamma").querySelector(".progress-strip")).toBeNull();
    expect(card("Gamma").querySelector(".badge.played")).toBeNull();
  });

  it("uses the series poster on a series card, falling back to an episode still, then a letter", async () => {
    list = [
      ep("a1", "Alpha", 1, 1, { series_poster_path: "/dl/alpha-series.jpg" }),
      ep("b1", "Beta", 1, 1),
      ep("c1", "Gamma", 1, 1, { poster_path: undefined }),
    ];
    await boot();
    await open();
    expect(card("Alpha").querySelector("img")?.getAttribute("src")).toContain(encodeURIComponent("/dl/alpha-series.jpg"));
    expect(card("Beta").querySelector("img")?.getAttribute("src")).toContain(encodeURIComponent("/dl/b1.jpg"));
    expect(card("Gamma").querySelector("img")).toBeNull();
    expect(card("Gamma").querySelector(".noart")?.textContent).toBe("G");
  });

  it("drills from series to seasons to episodes and back by the breadcrumb", async () => {
    list = [
      ep("a2", "Alpha", 1, 2),
      ep("a1", "Alpha", 1, 1, { overview: "It begins." }),
      ep("a3", "Alpha", 2, 1),
      ep("a4", "Alpha", null, 9),
    ];
    await boot();
    await open();
    click(card("Alpha"));
    expect(texts(root, ".card-title")).toEqual(["Episodes", "Season 1", "Season 2"]);
    expect(root.querySelector(".lib-crumb")?.textContent).toContain("All shows");
    expect(card("Season 1").querySelector(".card-sub")?.textContent).toBe("2 episodes");

    click(card("Season 1"));
    expect(texts(root, ".dl-row h4")).toEqual(["1. Part 1", "2. Part 2"]);
    expect(root.querySelector(".lib-crumb > span")?.textContent).toBe("Alpha · Season 1");
    expect(row("1. Part 1").querySelector(".dl-overview")?.textContent).toBe("It begins.");
    expect(row("2. Part 2").querySelector(".dl-overview")).toBeNull();

    click(byText(root, ".lib-crumb a", "Seasons"));
    expect(texts(root, ".card-title")).toEqual(["Episodes", "Season 1", "Season 2"]);
    click(byText(root, ".lib-crumb a", "All shows"));
    expect(texts(root, ".card-title")).toEqual(["Alpha"]);
  });

  it("cards and breadcrumbs work from the keyboard: Enter and Space open, Tab reaches them (regression: a963a95)", async () => {
    list = [ep("a1", "Alpha", 1, 1), ep("a2", "Alpha", 2, 1)];
    await boot();
    await open();
    const series = card("Alpha");
    expect(series.getAttribute("role")).toBe("button");
    expect(series.getAttribute("tabindex")).toBe("0");
    expect(key(series, "Enter").defaultPrevented).toBe(true);
    expect(texts(root, ".card-title")).toEqual(["Season 1", "Season 2"]);
    key(card("Season 2"), " ");
    expect(texts(root, ".dl-row h4")).toEqual(["1. Part 1"]);
    const up = byText(root, ".lib-crumb a", "Seasons")!;
    expect(up.getAttribute("role")).toBe("button");
    expect(up.getAttribute("tabindex")).toBe("0");
    key(up, "Enter");
    expect(texts(root, ".card-title")).toEqual(["Season 1", "Season 2"]);
    key(byText(root, ".lib-crumb a", "All shows"), " ");
    expect(texts(root, ".card-title")).toEqual(["Alpha"]);
    // Any other key leaves the card alone.
    expect(key(card("Alpha"), "a").defaultPrevented).toBe(false);
    expect(texts(root, ".card-title")).toEqual(["Alpha"]);
  });

  it("a key pressed on a button inside a card does not also open the card", async () => {
    list = [ep("a1", "Alpha", 1, 1)];
    await boot();
    await open();
    key(card("Alpha").querySelector(".dl-shuffle-badge"), "Enter");
    expect(texts(root, ".card-title")).toEqual(["Alpha"]);
  });

  it("an episode row says quality, size and where it was left", async () => {
    list = [
      ep("a1", "Alpha", 1, 1, { played: true }),
      ep("a2", "Alpha", 1, 2, { position_ticks: 12 * MIN }),
      ep("a3", "Alpha", 1, 3, { quality: undefined, size_bytes: 0 }),
      ep("a4", "Alpha", 1, 4, { position_ticks: 5 * MIN, run_time_ticks: 0 }),
    ];
    await boot();
    await open();
    click(card("Alpha"));
    click(card("Season 1"));
    expect(row("1. Part 1").querySelector(".dl-sub")?.textContent).toBe("720p · 4.5 Mbps · 1.00 GiB · watched");
    expect(row("2. Part 2").querySelector(".dl-sub")?.textContent).toBe("720p · 4.5 Mbps · 1.00 GiB · resume at 12m");
    expect(row("3. Part 3").querySelector(".dl-sub")?.textContent).toBe("");
    // No runtime: no resume point can be claimed.
    expect(row("4. Part 4").querySelector(".dl-sub")?.textContent).toBe("720p · 4.5 Mbps · 1.00 GiB");
    expect(row("1. Part 1").querySelector(".badge.played")).not.toBeNull();
    expect(row("1. Part 1").querySelector(".progress-strip")).toBeNull();
    expect(row("2. Part 2").querySelector<HTMLElement>(".progress-strip > div")!.style.width).toBe("40%");
    expect(row("3. Part 3").querySelector(".progress-strip")).toBeNull();
  });

  it("Play on an episode row starts the file where it was left", async () => {
    list = [ep("a1", "Alpha", 1, 1, { position_ticks: 12 * MIN })];
    await boot();
    await open();
    click(card("Alpha"));
    click(card("Season 1"));
    click(button(row("Part 1"), "Play"));
    await flush();
    expect(played()).toHaveLength(1);
    expect(played()[0].url).toBe("/dl/a1.mkv");
    expect(played()[0].start_seconds).toBe(12 * 60);
    expect(played()[0].ctx).toMatchObject({ item_id: "a1", is_local: true, live: false });
  });

  it("an episode with no file yet has no Play button", async () => {
    list = [ep("a1", "Alpha", 1, 1, { path: null })];
    await boot();
    await open();
    click(card("Alpha"));
    click(card("Season 1"));
    expect(byText(row("Part 1"), "button", "Play")).toBeNull();
    expect(byText(row("Part 1"), "button", "Delete")).not.toBeNull();
  });

  it("deleting an episode removes it and stays in the season being looked at", async () => {
    list = [ep("a1", "Alpha", 1, 1), ep("a2", "Alpha", 1, 2)];
    await boot();
    await open();
    click(card("Alpha"));
    click(card("Season 1"));
    click(button(row("Part 1"), "Delete"));
    await settle();
    expect(deleted()).toEqual(["a1"]);
    expect(toasts()).toContain("Download deleted");
    expect(texts(root, ".dl-row h4")).toEqual(["2. Part 2"]);
  });

  it("climbs back up when the season, then the series, being looked at is gone", async () => {
    list = [ep("a1", "Alpha", 1, 1), ep("a2", "Alpha", 2, 1), ep("b1", "Beta", 1, 1)];
    await boot();
    await open();
    click(card("Alpha"));
    click(card("Season 1"));
    click(button(row("Part 1"), "Delete"));
    await settle();
    // Season 1 is empty now: back at Alpha's seasons.
    expect(texts(root, ".card-title")).toEqual(["Season 2"]);
    list = list.filter((d) => d.series !== "Alpha");
    await open({ keepTab: true });
    expect(texts(root, ".card-title")).toEqual(["Beta"]);
  });

  it("switching tabs and back returns to the series grid", async () => {
    list = [ep("a1", "Alpha", 1, 1), movie("m1", "Arrival")];
    await boot();
    await open();
    click(card("Alpha"));
    click(tab("TV")); // the same tab: stay where we are
    expect(texts(root, ".card-title")).toEqual(["Season 1"]);
    click(tab("Movies"));
    click(tab("TV"));
    expect(texts(root, ".card-title")).toEqual(["Alpha"]);
  });
});

describe("Play Next", () => {
  it("plays the first episode not watched to the end, in watching order, resuming one part-way through", async () => {
    list = [
      ep("s2e1", "Alpha", 2, 1),
      ep("s1e2", "Alpha", 1, 2, { position_ticks: 10 * MIN }),
      ep("s1e1", "Alpha", 1, 1, { played: true }),
    ];
    await boot();
    await open();
    click(card("Alpha"));
    const btn = button(root.querySelector(".lib-crumb")!, "Play Next");
    expect(btn.title).toBe("Play the Next Unwatched Episode");
    click(btn);
    await flush();
    expect(played()[0].url).toBe("/dl/s1e2.mkv");
    expect(played()[0].start_seconds).toBe(600);
  });

  it("skips an unwatched episode that has no file yet", async () => {
    list = [
      ep("e1", "Alpha", 1, 1, { path: null }),
      ep("e2", "Alpha", 1, 2),
    ];
    await boot();
    await open();
    click(card("Alpha"));
    click(button(root.querySelector(".lib-crumb")!, "Play Next"));
    await flush();
    expect(played()[0].url).toBe("/dl/e2.mkv");
  });

  it("becomes Play, from the start of the first episode, once everything is watched", async () => {
    list = [
      ep("e2", "Alpha", 1, 2, { played: true }),
      ep("e1", "Alpha", 1, 1, { played: true, position_ticks: 29 * MIN }),
    ];
    await boot();
    await open();
    click(card("Alpha"));
    click(card("Season 1"));
    const crumb = root.querySelector(".lib-crumb")!;
    expect(byText(crumb, "button", "Play Next")).toBeNull();
    const btn = button(crumb, "Play");
    expect(btn.title).toBe("Play from the Start");
    click(btn);
    await flush();
    expect(played()[0].url).toBe("/dl/e1.mkv");
    expect(played()[0].start_seconds).toBeNull();
  });

  it("is not offered when nothing in the group can be played", async () => {
    list = [ep("e1", "Alpha", 1, 1, { path: null })];
    await boot();
    await open();
    click(card("Alpha"));
    const crumb = root.querySelector(".lib-crumb")!;
    expect(byText(crumb, "button", "Play Next")).toBeNull();
    expect(byText(crumb, "button", /^Play$/)).toBeNull();
    rightClick(card("Season 1"));
    expect(menuLabels()).toEqual(["Mark season watched", "Delete season"]);
  });

  it("the menu entry names the episode it will play", async () => {
    list = [ep("e1", "Alpha", 1, 1, { played: true }), ep("e2", "Alpha", 1, 2), ep("e3", "Alpha", 1, 3, { episode: null })];
    await boot();
    await open();
    rightClick(card("Alpha"));
    // The episode with no number sorts first and is the next one up.
    expect(menuLabels()[0]).toBe("Play Next");
    list = list.filter((d) => d.item_id !== "e3");
    await open({ keepTab: true });
    rightClick(card("Alpha"));
    expect(menuLabels()[0]).toBe("Play Next (E2)");
    await pickMenu("Play Next (E2)");
    expect(played()[0].url).toBe("/dl/e2.mkv");
  });
});

describe("series and season actions", () => {
  beforeEach(async () => {
    list = [
      ep("e1", "Alpha", 1, 1, { played: true }),
      ep("e2", "Alpha", 1, 2),
      ep("e3", "Alpha", 2, 1),
    ];
    await boot();
    await open();
  });

  it("the shuffle badge starts a shuffle without opening the series", async () => {
    vi.spyOn(Math, "random").mockReturnValue(0.5);
    click(card("Alpha").querySelector(".dl-shuffle-badge"));
    await flush();
    expect(texts(root, ".card-title")).toEqual(["Alpha"]);
    expect(played()).toHaveLength(1);
    expect(played()[0].url).toBe("/dl/e2.mkv");
    expect(toasts()).toContain("Shuffling Alpha · 3 episodes");
    expect(playback.isShuffling()).toBe(true);
    vi.restoreAllMocks();
  });

  it("Shuffle on the series page draws from every episode; on a season, from that season", async () => {
    click(card("Alpha"));
    const shuffleAll = button(root.querySelector(".lib-crumb")!, "Shuffle 3 episodes");
    vi.spyOn(Math, "random").mockReturnValue(0.99);
    click(shuffleAll);
    await flush();
    expect(played()[0].url).toBe("/dl/e3.mkv");
    click(card("Season 1"));
    click(button(root.querySelector(".lib-crumb")!, "Shuffle this season"));
    await flush();
    expect(played()[1].url).toBe("/dl/e2.mkv");
    expect(toasts()).toContain("Shuffling Alpha · 2 episodes");
    vi.restoreAllMocks();
  });

  it("a shuffled episode that was already watched starts from the top", async () => {
    vi.spyOn(Math, "random").mockReturnValue(0);
    list[0].position_ticks = 29 * MIN;
    click(card("Alpha").querySelector(".dl-shuffle-badge"));
    await flush();
    expect(played()[0].url).toBe("/dl/e1.mkv");
    expect(played()[0].start_seconds).toBeNull();
    vi.restoreAllMocks();
  });

  it("Show in Files hands the group's downloads to the file manager, and says so when it can't", async () => {
    click(card("Alpha"));
    click(button(root.querySelector(".lib-crumb")!, "Show in Files"));
    await flush();
    expect(invokeCalls("downloads_reveal")[0]!.args).toEqual({ itemIds: ["e1", "e2", "e3"] });
    click(card("Season 2"));
    onInvoke("downloads_reveal", () => {
      throw new Error("no file manager");
    });
    click(button(root.querySelector(".lib-crumb")!, "Show in Files"));
    await flush();
    expect(invokeCalls("downloads_reveal")[1]!.args).toEqual({ itemIds: ["e3"] });
    expect(lastToast()).toBe("Couldn't show that in Files: Error: no file manager");
  });

  it("Delete series asks first on the button itself, forgets after four seconds, and deletes on the second click", async () => {
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
    click(card("Alpha"));
    const btn = button(root.querySelector(".lib-crumb")!, "Delete series");
    click(btn);
    expect(btn.textContent).toBe("Delete 3 episodes?");
    expect(deleted()).toEqual([]);
    vi.advanceTimersByTime(3999);
    expect(btn.textContent).toBe("Delete 3 episodes?");
    vi.advanceTimersByTime(1);
    expect(btn.textContent).toBe("Delete series");
    // Armed again, then confirmed.
    click(btn);
    click(btn);
    expect(btn.textContent).toBe("Working…");
    expect(btn.disabled).toBe(true);
    await flush(60);
    expect(deleted()).toEqual(["e1", "e2", "e3"]);
    expect(toasts()).toContain("Deleted 3 downloads");
    // The timer that would have disarmed it was cancelled.
    vi.advanceTimersByTime(5000);
    expect(btn.textContent).toBe("Working…");
  });

  it("Delete season counts one episode in the singular", async () => {
    click(card("Alpha"));
    click(card("Season 2"));
    const btn = button(root.querySelector(".lib-crumb")!, "Delete season");
    click(btn);
    expect(btn.textContent).toBe("Delete 1 episode?");
    click(btn);
    await settle();
    expect(deleted()).toEqual(["e3"]);
    expect(toasts()).toContain("Deleted 1 download");
  });

  it("a series card's menu: play next, shuffle, files, mark, delete watched, delete", async () => {
    rightClick(card("Alpha"));
    expect(menuTitle()).toBe("Alpha");
    expect(menuLabels()).toEqual([
      "Play Next (E2)",
      "Shuffle",
      "Show in Files",
      "Mark series watched",
      "Delete watched episodes (1)",
      "Delete series",
    ]);
  });

  it("a season card's menu is titled with the series and says season", async () => {
    click(card("Alpha"));
    rightClick(card("Season 1"));
    expect(menuTitle()).toBe("Alpha · Season 1");
    expect(menuLabels()).toEqual([
      "Play Next (E2)",
      "Shuffle this season",
      "Show in Files",
      "Mark season watched",
      "Delete watched episodes (1)",
      "Delete season",
    ]);
    await pickMenu("Shuffle this season");
    expect(["/dl/e1.mkv", "/dl/e2.mkv"]).toContain(played()[0].url);
    rightClick(card("Season 1"));
    await pickMenu("Show in Files");
    expect(invokeCalls("downloads_reveal")[0]!.args).toEqual({ itemIds: ["e1", "e2"] });
  });

  it("Mark series watched writes every episode locally, queues the sync and repaints", async () => {
    let queueEvents = 0;
    const onQueue = (): void => void queueEvents++;
    document.addEventListener("aquarium-progress-queue", onQueue);
    rightClick(card("Alpha"));
    await pickMenu("Mark series watched");
    await settle();
    document.removeEventListener("aquarium-progress-queue", onQueue);
    expect(invokeCalls("progress_store_local").map((c) => c.args)).toEqual([
      { itemId: "e1", positionTicks: 0, played: true },
      { itemId: "e2", positionTicks: 0, played: true },
      { itemId: "e3", positionTicks: 0, played: true },
    ]);
    expect(queueEvents).toBe(1);
    expect(toasts()).toContain("Marked 3 episodes watched");
    expect(card("Alpha").querySelector(".card-sub")?.textContent).toBe("3 episodes · 3 watched");
    // Everything watched: the toggle flips, and "delete watched" would be the
    // same as deleting the series, so it's gone.
    rightClick(card("Alpha"));
    expect(menuLabels()).toEqual([
      "Play from the Start",
      "Shuffle",
      "Show in Files",
      "Mark series unwatched",
      "Delete series",
    ]);
    await pickMenu("Mark series unwatched");
    await settle();
    expect(invokeCalls("progress_store_local").at(-1)!.args).toEqual({ itemId: "e3", positionTicks: 0, played: false });
    expect(toasts()).toContain("Marked 3 episodes unwatched");
    expect(card("Alpha").querySelector(".card-sub")?.textContent).toBe("3 episodes");
  });

  it("Delete watched episodes asks with the count and size, and Cancel keeps them", async () => {
    rightClick(card("Alpha"));
    await pickMenu("Delete watched episodes (1)");
    expect(dialogTitle()).toBe("Delete the watched episodes of this series?");
    expect(dialogEl()!.querySelector("p")?.textContent).toBe("1 item · 1.00 GiB");
    expect(dialogButtons()).toEqual(["Cancel", "Delete 1 Download"]);
    await pickDialog("Cancel");
    expect(deleted()).toEqual([]);
    rightClick(card("Alpha"));
    await pickMenu("Delete watched episodes (1)");
    await pickDialog("Delete 1 Download");
    await settle();
    expect(deleted()).toEqual(["e1"]);
    expect(card("Alpha").querySelector(".card-sub")?.textContent).toBe("2 episodes");
  });

  it("says so when the watched episodes were unmarked while the menu was open", async () => {
    rightClick(card("Alpha"));
    list[0].played = false; // e.g. the server's watch state landed
    await pickMenu("Delete watched episodes (1)");
    expect(dialogEl()).toBeNull();
    expect(lastToast()).toBe("Nothing watched to delete");
  });

  it("Delete series from the menu deletes at once, skipping an episode the backend refuses", async () => {
    onInvoke("download_delete", ({ itemId }: any) => {
      if (itemId === "e2") throw new Error("busy");
      list = list.filter((d) => d.item_id !== itemId);
      return null;
    });
    rightClick(card("Alpha"));
    await pickMenu("Delete series");
    await settle();
    expect(deleted()).toEqual(["e1", "e2", "e3"]);
    expect(toasts()).toContain("Deleted 3 downloads");
    expect(card("Alpha").querySelector(".card-sub")?.textContent).toBe("1 episode");
  });
});

describe("one download's menu", () => {
  it("offers Resume and Play from start for a file part-way through", async () => {
    list = [ep("e1", "Alpha", 1, 1, { position_ticks: 12 * MIN })];
    await boot();
    await open();
    click(card("Alpha"));
    click(card("Season 1"));
    rightClick(row("Part 1"));
    expect(menuTitle()).toBe("Part 1");
    expect(menuLabels()).toEqual([
      "Resume (12m in)",
      "Play from start",
      "Mark watched",
      "Show details",
      "Show in Files",
      "Delete download",
    ]);
    await pickMenu("Resume");
    expect(played()[0].start_seconds).toBe(720);
    rightClick(row("Part 1"));
    await pickMenu("Play from start");
    expect(played()[1].start_seconds).toBeNull();
  });

  it("offers plain Play (from the top) for a watched file, and Mark unwatched", async () => {
    list = [ep("e1", "Alpha", 1, 1, { played: true, position_ticks: 29 * MIN })];
    await boot();
    await open();
    click(card("Alpha"));
    click(card("Season 1"));
    rightClick(row("Part 1"));
    expect(menuLabels().slice(0, 2)).toEqual(["Play", "Mark unwatched"]);
    await pickMenu("Play");
    expect(played()[0].start_seconds).toBeNull();
  });

  it("Mark watched clears the resume point, queues the sync and shows the tick", async () => {
    list = [ep("e1", "Alpha", 1, 1, { position_ticks: 12 * MIN })];
    await boot();
    await open();
    click(card("Alpha"));
    click(card("Season 1"));
    let queueEvents = 0;
    const onQueue = (): void => void queueEvents++;
    document.addEventListener("aquarium-progress-queue", onQueue);
    rightClick(row("Part 1"));
    await pickMenu("Mark watched");
    await settle();
    document.removeEventListener("aquarium-progress-queue", onQueue);
    expect(invokeCalls("progress_store_local")[0]!.args).toEqual({ itemId: "e1", positionTicks: 0, played: true });
    expect(queueEvents).toBe(1);
    expect(toasts()).toContain("Marked watched");
    expect(row("Part 1").querySelector(".badge.played")).not.toBeNull();
    expect(row("Part 1").querySelector(".dl-sub")?.textContent).toContain("watched");
    rightClick(row("Part 1"));
    await pickMenu("Mark unwatched");
    await settle();
    expect(invokeCalls("progress_store_local")[1]!.args).toEqual({ itemId: "e1", positionTicks: 0, played: false });
    expect(toasts()).toContain("Marked unwatched");
    expect(row("Part 1").querySelector(".badge.played")).toBeNull();
  });

  it("reports a failed mark and leaves the row as it was", async () => {
    list = [ep("e1", "Alpha", 1, 1)];
    await boot();
    await open();
    click(card("Alpha"));
    click(card("Season 1"));
    onInvoke("progress_store_local", () => {
      throw new Error("disk full");
    });
    rightClick(row("Part 1"));
    await pickMenu("Mark watched");
    await settle();
    expect(lastToast()).toBe("disk full");
    expect(row("Part 1").querySelector(".badge.played")).toBeNull();
  });

  it("Show details goes to the item page; Show in Files and Delete act on that file", async () => {
    list = [ep("e1", "Alpha", 1, 1), ep("e2", "Alpha", 1, 2)];
    await boot();
    await open();
    click(card("Alpha"));
    click(card("Season 1"));
    rightClick(row("Part 1"));
    await pickMenu("Show details");
    expect(location.hash).toBe("#/item/e1");
    rightClick(row("Part 1"));
    await pickMenu("Show in Files");
    expect(invokeCalls("downloads_reveal")[0]!.args).toEqual({ itemIds: ["e1"] });
    rightClick(row("Part 1"));
    await pickMenu("Delete download");
    await settle();
    expect(deleted()).toEqual(["e1"]);
    expect(texts(root, ".dl-row h4")).toEqual(["2. Part 2"]);
  });

  it("with no session there is no details page to show, and a file not on disk has no Play or Show in Files", async () => {
    list = [movie("m1", "Arrival", { path: null })];
    await boot({}, { signedIn: false });
    await open();
    click(tab("Movies"));
    rightClick(card("Arrival"));
    expect(menuLabels()).toEqual(["Mark watched", "Delete download"]);
    // And nothing was asked of a server that isn't there.
    expect(jfPaths()).toEqual([]);
  });
});

describe("Movies tab", () => {
  it("says what to do when there are none", async () => {
    await boot();
    await open();
    click(tab("Movies"));
    expect(root.querySelector(".state h3")?.textContent).toBe("No movie downloads yet");
    click(button(root, "Browse movies"));
    expect(location.hash).toBe("#/home");
  });

  it("lists films by title with year and size, progress and watched marks", async () => {
    list = [
      movie("m2", "Brazil", { played: true, position_ticks: 50 * MIN }),
      movie("m1", "Arrival", { position_ticks: 25 * MIN }),
      movie("m3", "Children of Men", { year: undefined, size_bytes: 0 }),
    ];
    await boot();
    await open();
    click(tab("Movies"));
    expect(texts(root, ".card-title")).toEqual(["Arrival", "Brazil", "Children of Men"]);
    expect(card("Arrival").querySelector(".card-sub")?.textContent).toBe("2021 · 2.00 GiB");
    expect(card("Children of Men").querySelector(".card-sub")?.textContent).toBe("");
    expect(card("Children of Men").getAttribute("aria-label")).toBe("Children of Men");
    expect(card("Arrival").querySelector<HTMLElement>(".progress-strip > div")!.style.width).toBe("25%");
    expect(card("Brazil").querySelector(".badge.played")).not.toBeNull();
    expect(card("Brazil").querySelector(".progress-strip")).toBeNull();
  });

  it("a click plays the film from where it was left; a film with no file does nothing", async () => {
    list = [movie("m1", "Arrival", { position_ticks: 25 * MIN }), movie("m2", "Brazil", { path: null })];
    await boot();
    await open();
    click(tab("Movies"));
    expect(card("Arrival").querySelector(".play-overlay .pbtn")?.getAttribute("aria-label")).toBe("Play Arrival");
    expect(card("Brazil").querySelector(".play-overlay")).toBeNull();
    click(card("Brazil"));
    await flush();
    expect(played()).toHaveLength(0);
    click(card("Arrival"));
    await flush();
    expect(played()[0]).toMatchObject({ url: "/dl/m1.mkv", title: "Arrival", start_seconds: 1500, known_duration_seconds: 6000 });
  });

  it("the delete badge removes the film without also playing it", async () => {
    list = [movie("m1", "Arrival"), movie("m2", "Brazil")];
    await boot();
    await open();
    click(tab("Movies"));
    click(card("Arrival").querySelector(".dl-del-badge"));
    await settle();
    expect(played()).toHaveLength(0);
    expect(deleted()).toEqual(["m1"]);
    expect(texts(root, ".card-title")).toEqual(["Brazil"]);
    expect(tab("Movies").classList.contains("active")).toBe(true);
  });

  it("a film's right-click menu is the single-download menu", async () => {
    list = [movie("m1", "Arrival")];
    await boot();
    await open();
    click(tab("Movies"));
    rightClick(card("Arrival"));
    expect(menuTitle()).toBe("Arrival");
    expect(menuLabels()).toEqual(["Play", "Mark watched", "Show details", "Show in Files", "Delete download"]);
  });

  it("deleting a download also drops a retry of it still waiting, so it can't come back", async () => {
    // The retry is restored while the backend lists nothing for it (a complete
    // download's retry is dropped at restore, by design); the file is on the
    // Movies shelf by the time the page opens.
    await boot({ downloads_paused: true });
    await restoreQueue([{ kind: "retry", id: "m1", title: "Arrival" }]);
    expect(playback.getQueuedDownloads().map((p) => p.id)).toEqual(["m1"]);
    list = [movie("m1", "Arrival")];
    await open();
    click(tab("Movies"));
    click(card("Arrival").querySelector(".dl-del-badge"));
    await settle();
    expect(playback.getQueuedDownloads()).toEqual([]);
    expect(deleted()).toEqual(["m1"]);
  });
});

// ---------------------------------------------------------------------------

describe("the Delete key (f0902f2)", () => {
  beforeEach(async () => {
    list = [ep("e1", "Alpha", 1, 1), ep("e2", "Alpha", 1, 2), ep("b1", "Beta", 1, 1), movie("m1", "Arrival")];
    await boot();
    await open();
  });

  it("asks before deleting the focused series, naming it and how many files go", async () => {
    card("Alpha").focus();
    const ev = key(document.activeElement, "Delete");
    expect(ev.defaultPrevented).toBe(true);
    expect(dialogTitle()).toBe("Delete all 2 episodes of “Alpha”?");
    expect(dialogEl()!.querySelector("p")?.textContent).toBe("2 downloads are removed from this computer.");
    expect(dialogButtons()).toEqual(["Cancel", "Delete 2"]);
    // Focus lands on Cancel, so Enter never destroys anything.
    expect(document.activeElement?.textContent).toBe("Cancel");
    await pickDialog("Delete 2");
    await settle();
    expect(deleted()).toEqual(["e1", "e2"]);
    expect(texts(root, ".card-title")).toEqual(["Beta"]);
  });

  it("words a single episode, a season, an episode row and a film each their own way", async () => {
    card("Beta").focus();
    key(document.activeElement, "Delete");
    expect(dialogTitle()).toBe("Delete the episode of “Beta”?");
    expect(dialogEl()!.querySelector("p")?.textContent).toBe("The file is removed from this computer.");
    expect(dialogButtons()).toEqual(["Cancel", "Delete"]);
    await pickDialog("Cancel");

    click(card("Alpha"));
    card("Season 1").focus();
    key(document.activeElement, "Delete");
    expect(dialogTitle()).toBe("Delete Season 1 of “Alpha”?");
    await pickDialog("Cancel");

    click(card("Season 1"));
    row("Part 2").focus();
    key(document.activeElement, "Delete");
    expect(dialogTitle()).toBe("Delete “Part 2”?");
    await pickDialog("Delete");
    await settle();
    expect(deleted()).toEqual(["e2"]);

    click(tab("Movies"));
    card("Arrival").focus();
    key(document.activeElement, "Delete");
    expect(dialogTitle()).toBe("Delete “Arrival”?");
    await pickDialog("Cancel");
    expect(deleted()).toEqual(["e2"]);
  });

  it("works from a button inside the selected card or row", async () => {
    const badge = card("Alpha").querySelector<HTMLElement>(".dl-shuffle-badge")!;
    badge.focus();
    key(badge, "Delete");
    expect(dialogTitle()).toBe("Delete all 2 episodes of “Alpha”?");
  });

  it("episode rows can take focus so they can be selected", async () => {
    click(card("Alpha"));
    click(card("Season 1"));
    expect(row("Part 1").tabIndex).toBe(0);
    expect(row("Part 1").dataset.dlIds).toBe("e1");
  });

  it("does nothing when focus is not on a download", async () => {
    tab("Movies").focus();
    const ev = key(document.activeElement, "Delete");
    expect(ev.defaultPrevented).toBe(false);
    expect(dialogEl()).toBeNull();
    (document.activeElement as HTMLElement).blur();
    key(document.body, "Delete");
    expect(dialogEl()).toBeNull();
  });

  it("does not stack a second dialog while one is already asking", async () => {
    card("Alpha").focus();
    key(card("Alpha"), "Delete");
    expect(document.querySelectorAll(".dialog-scrim").length).toBe(1);
    card("Alpha").focus();
    key(card("Alpha"), "Delete");
    expect(document.querySelectorAll(".dialog-scrim").length).toBe(1);
  });

  it("leaves a Delete some other handler already used, and other keys, alone", async () => {
    card("Alpha").focus();
    const ev = new KeyboardEvent("keydown", { key: "Delete", bubbles: true, cancelable: true });
    card("Alpha").addEventListener("keydown", (e) => e.preventDefault(), { once: true });
    card("Alpha").dispatchEvent(ev);
    expect(dialogEl()).toBeNull();
    key(card("Alpha"), "Backspace");
    expect(dialogEl()).toBeNull();
  });

  it("is ignored once the Downloads page is no longer the one on screen", async () => {
    const c = card("Alpha");
    c.focus();
    root.querySelector(".dl-tabs")!.remove(); // another view has taken the root
    key(c, "Delete");
    expect(dialogEl()).toBeNull();
    root.remove();
    key(document.body, "Delete");
    expect(dialogEl()).toBeNull();
  });

  it("is installed once, however many times the page renders", async () => {
    await open({ keepTab: true });
    await open({ keepTab: true });
    card("Alpha").focus();
    key(card("Alpha"), "Delete");
    expect(document.querySelectorAll(".dialog-scrim").length).toBe(1);
    await pickDialog("Delete 2");
    await settle();
    expect(deleted()).toEqual(["e1", "e2"]);
  });
});

// ---------------------------------------------------------------------------

describe("Queue tab", () => {
  it("says the queue is empty when it is", async () => {
    await boot();
    await open();
    click(tab("Queue"));
    expect(root.querySelector(".state h3")?.textContent).toBe("The queue is empty");
  });

  it("lists what is running with a bar, and Cancel stops it", async () => {
    list = [
      { item_id: "d1", status: "downloading", title: "Alpha S1E1", quality: "720p · 4.5 Mbps", estimated_bytes: GiB, poster_path: "/dl/d1.jpg" },
      { item_id: "d2", status: "downloading", name: "Unnamed" },
    ];
    await boot();
    await open();
    click(tab("Queue"));
    expect(texts(root, "h3.season-group")).toEqual(["Downloading"]);
    expect(root.querySelector(".lib-crumb > span")?.textContent).toBe("2 downloads in the queue · 2 running");
    const r = row("Alpha S1E1");
    expect(r.querySelector(".dl-sub")?.textContent).toBe("720p · 4.5 Mbps · of ~1.00 GiB");
    expect(r.querySelector<HTMLElement>('.dl-bar[data-item="d1"] > div')!.style.width).toBe("0%");
    expect(row("Unnamed").querySelector(".dl-sub")?.textContent).toBe("");
    click(button(r, "Cancel"));
    await flush();
    expect(invokeCalls("download_cancel")[0]!.args).toEqual({ itemId: "d1" });
    rightClick(row("Unnamed"));
    expect(menuLabels()).toEqual(["Cancel download"]);
    await pickMenu("Cancel download");
    expect(invokeCalls("download_cancel")[1]!.args).toEqual({ itemId: "d2" });
  });

  it("lists what is waiting, in order, with what each is waiting for", async () => {
    list = [{ item_id: "d1", status: "downloading", title: "Running" }];
    await boot();
    await restoreQueue([
      { item: { Id: "w1", Name: "Pilot", SeriesName: "Alpha", ParentIndexNumber: 1, IndexNumber: 2 }, q: Q720 },
      { item: { Id: "w2", Name: "A Film", Type: "Movie" }, q: QORIG },
      { item: { Id: "w3", Name: "Special", SeriesName: "Alpha" }, q: Q720 },
      { kind: "retry", id: "w4", title: "Came back" },
    ]);
    await open();
    click(tab("Queue"));
    expect(tab("Queue").querySelector(".dl-tab-count")?.textContent).toBe("5");
    expect(texts(root, "h3.season-group")).toEqual(["Downloading", "Up next · 4"]);
    expect(root.querySelector(".lib-crumb > span")?.textContent).toBe("5 downloads in the queue · 1 running");
    expect(row("Pilot").querySelector(".dl-sub")?.textContent).toBe("Alpha · S1E2 · Waiting · 720p · 4.5 Mbps");
    expect(row("A Film").querySelector(".dl-sub")?.textContent).toBe("Waiting · Original quality");
    expect(row("Special").querySelector(".dl-sub")?.textContent).toBe("Alpha · Waiting · 720p · 4.5 Mbps");
    // A retry replays the stored request: "Waiting · retrying" read as a stutter.
    expect(row("Came back").querySelector(".dl-sub")?.textContent).toBe("Waiting · retry of a failed download");
    expect(texts(root, ".queue-pos")).toEqual(["#1", "#2", "#3", "#4"]);
    // Waiting rows have no artwork to show.
    expect(row("Pilot").querySelector(".dl-poster")!.children.length).toBe(0);
  });

  it("Remove takes a waiting download out of the queue and the page follows", async () => {
    list = [{ item_id: "d1", status: "downloading", title: "Running" }];
    await boot();
    await restoreQueue([
      { item: { Id: "w1", Name: "Pilot" }, q: Q720 },
      { item: { Id: "w2", Name: "Second" }, q: Q720 },
    ]);
    await open();
    click(tab("Queue"));
    click(button(row("Pilot"), "Remove"));
    await settle();
    expect(playback.getQueuedDownloads().map((p) => p.id)).toEqual(["w2"]);
    expect(texts(root, ".dl-row h4")).toEqual(["Running", "Second"]);
    rightClick(row("Second"));
    expect(menuTitle()).toBe("Second");
    expect(menuLabels()).toEqual(["Remove from queue"]);
    await pickMenu("Remove from queue");
    await settle();
    expect(playback.getQueuedDownloads()).toEqual([]);
    expect(texts(root, ".dl-row h4")).toEqual(["Running"]);
  });

  it("a scheduled retry says why it failed and how long until it goes again", async () => {
    vi.useFakeTimers({ toFake: ["Date"] });
    vi.setSystemTime(new Date("2026-03-10T12:00:00Z"));
    const now = Date.now();
    await boot({ downloads_paused: true });
    await restoreQueue([
      { kind: "retry", id: "r1", title: "Soon", reason: "The connection dropped", retryAt: now + 44_500 },
      { kind: "retry", id: "r2", title: "Later", reason: "The server is busy", retryAt: now + 300_000 },
      { kind: "retry", id: "r3", title: "Due", reason: "The connection dropped", retryAt: now - 1000 },
      { kind: "retry", id: "r4", title: "Held", reason: "Paused" },
      { kind: "retry", id: "r5", title: "Edge", reason: "Stalled", retryAt: now + 90_000 },
    ]);
    await view.renderDownloads(root);
    await flush(40);
    click(tab("Queue"));
    expect(row("Soon").querySelector(".dl-sub")?.textContent).toBe("The connection dropped in 45s");
    expect(row("Later").querySelector(".dl-sub")?.textContent).toBe("The server is busy in 5 min");
    expect(row("Due").querySelector(".dl-sub")?.textContent).toBe("The connection dropped");
    expect(row("Held").querySelector(".dl-sub")?.textContent).toBe("Paused");
    expect(row("Edge").querySelector(".dl-sub")?.textContent).toBe("Stalled in 2 min");
  });

  it("with one transcode at a time, a waiting transcode says it is behind the one running; an original does not", async () => {
    list = [{
      item_id: "d1", status: "downloading", title: "Transcoding now",
      request: { url: "http://jf.test:8096/Videos/d1/stream.mkv?VideoBitrate=4500000" },
    }];
    await boot({ downloads_transcode_serial: true });
    await restoreQueue([
      { item: { Id: "w1", Name: "Next transcode" }, q: Q720 },
      { item: { Id: "w2", Name: "An original" }, q: QORIG },
      { kind: "retry", id: "w3", title: "Retry of a transcode", transcode: true },
    ]);
    await open();
    click(tab("Queue"));
    expect(row("Next transcode").querySelector(".dl-sub")?.textContent).toBe("Waiting for the transcode ahead of it");
    expect(row("An original").querySelector(".dl-sub")?.textContent).toBe("Waiting · Original quality");
    expect(row("Retry of a transcode").querySelector(".dl-sub")?.textContent).toBe("Waiting for the transcode ahead of it");
  });

  it("Clear queue asks on the button, then drops the waiting ones and cancels the running ones", async () => {
    list = [
      { item_id: "d1", status: "downloading", title: "Running" },
      movie("m1", "Arrival"),
    ];
    await boot();
    await restoreQueue([
      { item: { Id: "w1", Name: "Pilot" }, q: Q720 },
      { item: { Id: "w2", Name: "Second" }, q: Q720 },
    ]);
    await open();
    click(tab("Queue"));
    const btn = button(root, "Clear queue");
    click(btn);
    expect(btn.textContent).toBe("Cancel 3 queued downloads?");
    // Something else started since the page was drawn: the list is re-read.
    list = [...list, { item_id: "d2", status: "downloading", title: "Started since" }];
    click(btn);
    await settle();
    expect(invokeCalls("download_cancel").map((c) => c.args.itemId)).toEqual(["d1", "d2"]);
    expect(playback.getQueuedDownloads()).toEqual([]);
    expect(toasts()).toContain("Queue cleared · 2 in progress cancelled · 2 queued items dropped");
    // Finished downloads are left alone.
    expect(deleted()).toEqual([]);
  });

  it("Clear queue words one queued download in the singular and admits when there was nothing left", async () => {
    await boot({ downloads_paused: true });
    await restoreQueue([{ item: { Id: "w1", Name: "Pilot" }, q: Q720 }]);
    await open();
    click(tab("Queue"));
    const btn = button(root, "Clear queue");
    click(btn);
    expect(btn.textContent).toBe("Cancel 1 queued download?");
    click(btn);
    await settle();
    expect(toasts()).toContain("Queue cleared · 1 queued item dropped");

    clearToasts();
    await restoreQueue([{ item: { Id: "w1", Name: "Pilot" }, q: Q720 }]);
    await open({ keepTab: true });
    const again = button(root, "Clear queue");
    click(again);
    // It left the queue by itself in the meantime.
    playback.cancelQueuedDownload("w1");
    click(again);
    await settle();
    expect(toasts()).toContain("Queue was already empty");
  });

  describe("Failed", () => {
    beforeEach(async () => {
      list = [
        { item_id: "f1", status: "error", title: "Broke", error: "connection reset", quality: "720p · 4.5 Mbps" },
        { item_id: "f2", status: "paused", title: "Stopped", quality: "Original quality" },
        { item_id: "f3", status: "error", name: "No reason" },
      ];
    });

    it("lists failed and paused downloads with why and the right verb", async () => {
      await boot();
      await open();
      click(tab("Queue"));
      expect(texts(root, "h3.season-group")).toEqual(["Failed · 3"]);
      expect(row("Broke").querySelector(".dl-sub")?.textContent).toBe("failed: connection reset");
      expect(row("Stopped").querySelector(".dl-sub")?.textContent).toBe("Paused");
      expect(row("No reason").querySelector(".dl-sub")?.textContent).toBe("failed: unknown error");
      expect(byText(row("Broke"), "button", "Retry")).not.toBeNull();
      expect(byText(row("Stopped"), "button", "Resume")).not.toBeNull();
      // Nothing is queued or running, so there is no queue header to clear.
      expect(byText(root, "button", "Clear queue")).toBeNull();
      rightClick(row("Stopped"));
      expect(menuLabels()).toEqual(["Resume download", "Delete"]);
      rightClick(row("Broke"));
      expect(menuLabels()).toEqual(["Retry download", "Delete"]);
    });

    it("Retry goes through the queue, not straight to the backend, so the parallel limit applies", async () => {
      // One download is already running and the limit is 1: the retry waits.
      list.push({ item_id: "d1", status: "downloading", title: "Running" });
      await boot();
      await restoreQueue([]);
      await open();
      click(tab("Queue"));
      click(button(row("Broke"), "Retry"));
      await settle();
      expect(toasts()).toContain("Queued for retry");
      expect(invokeCalls("download_retry")).toEqual([]);
      expect(playback.getQueuedDownloads().map((p) => p.id)).toEqual(["f1"]);
      expect(playback.getQueuedDownloads()[0]).toMatchObject({ retry: true, transcode: true });
    });

    it("a queued retry is shown once, under Up next, not again under Failed with a dead Retry button", async () => {
      list.push({ item_id: "d1", status: "downloading", title: "Running" });
      await boot();
      await restoreQueue([]);
      await open();
      click(tab("Queue"));
      click(button(row("Broke"), "Retry"));
      await settle();
      expect(texts(root, "h3.season-group")).toEqual(["Downloading", "Up next · 1", "Failed · 2"]);
      expect(texts(root, ".dl-row h4")).toEqual(["Running", "Broke", "Stopped", "No reason"]);
      expect(tab("Queue").querySelector(".dl-tab-count")?.textContent).toBe("4");
    });

    it("with the limit free a retry starts at once, as a manual one", async () => {
      await boot();
      await open();
      click(tab("Queue"));
      rightClick(row("Stopped"));
      await pickMenu("Resume download");
      await settle();
      expect(invokeCalls("download_retry").map((c) => c.args)).toEqual([{ itemId: "f2", manual: true }]);
      expect(toasts()).toContain("Queued for retry");
    });

    it("says so when the same failed download is retried twice", async () => {
      await boot({ downloads_paused: true });
      await open();
      click(tab("Queue"));
      const retryStale = button(row("Broke"), "Retry"); // kept from before the repaint
      click(retryStale);
      await settle();
      click(retryStale);
      await settle();
      expect(toasts()).toEqual(expect.arrayContaining(["Queued for retry", "That one is already retrying"]));
      expect(playback.getQueuedDownloads().map((p) => p.id)).toEqual(["f1"]);
    });

    it("Retry all queues every failure in the order listed, and is only offered for more than one", async () => {
      await boot({ downloads_paused: true });
      await open();
      click(tab("Queue"));
      const all = button(root, "Retry all 3");
      click(all);
      await settle();
      expect(toasts()).toContain("Retrying 3 downloads");
      expect(playback.getQueuedDownloads().map((p) => [p.id, p.title, p.transcode])).toEqual([
        ["f1", "Broke", true],
        ["f2", "Stopped", false],
        ["f3", "No reason", true],
      ]);
      expect(texts(root, "h3.season-group")).toEqual(["Up next · 3"]);
      click(all); // the stale button, clicked again
      await settle();
      expect(toasts()).toContain("Those are already retrying");

      playback.clearDownloadQueue();
      list = [list[0]];
      await open({ keepTab: true });
      expect(texts(root, "h3.season-group")).toEqual(["Failed · 1"]);
      expect(byText(root, "button", "Retry all")).toBeNull();
    });

    it("Retry all words a single newly queued download in the singular", async () => {
      await boot({ downloads_paused: true });
      list = list.slice(0, 2);
      await open();
      click(tab("Queue"));
      const all = button(root, "Retry all 2");
      playback.retryDownload("f1", "Broke");
      click(all);
      await settle();
      expect(toasts()).toContain("Retrying 1 download");
    });

    it("Delete removes a failed download", async () => {
      await boot();
      await open();
      click(tab("Queue"));
      click(button(row("Broke"), "Delete"));
      await settle();
      expect(deleted()).toEqual(["f1"]);
      expect(texts(root, "h3.season-group")).toEqual(["Failed · 2"]);
      rightClick(row("Stopped"));
      await pickMenu("Delete");
      await settle();
      expect(deleted()).toEqual(["f1", "f2"]);
    });
  });
});

describe("holds: paused, and waiting for an unmetered connection (d352047)", () => {
  it("Pause all is offered while there is a queue, pauses, and becomes Resume all", async () => {
    list = [{ item_id: "d1", status: "downloading", title: "Running" }];
    await boot();
    await restoreQueue([]);
    await open();
    const pause = button(root.querySelector(".head-tools")!, "Pause all");
    expect(pause.classList.contains("primary")).toBe(false);
    click(pause);
    await settle();
    expect(invokeCalls("config_save").at(-1)!.args).toEqual({ cfg: { downloads_paused: true } });
    expect(toasts()).toContain("Downloads paused");
    // The running transfer was set aside, keeping its partial file.
    expect(invokeCalls("download_pause").map((c) => c.args)).toEqual([{ itemId: "d1" }]);
    const resume = button(root.querySelector(".head-tools")!, "Resume all");
    expect(resume.classList.contains("primary")).toBe(true);
    expect(resume.title).toBe("Carry on with every download");
    click(resume);
    await settle();
    expect(invokeCalls("config_save").at(-1)!.args).toEqual({ cfg: { downloads_paused: false } });
    expect(toasts()).toContain("Downloads resumed");
    expect(playback.isDownloadsPaused()).toBe(false);
  });

  it("has no pause button with nothing to pause, but always shows the way out while paused", async () => {
    await boot();
    await open();
    expect(byText(root.querySelector(".head-tools")!, "button", /Pause all|Resume all/)).toBeNull();
    vi.resetModules();
    root = mountShell();
    await boot({ downloads_paused: true });
    await open();
    expect(byText(root.querySelector(".head-tools")!, "button", "Resume all")).not.toBeNull();
  });

  it("the Queue tab says downloads are paused, with Resume all on the banner", async () => {
    await boot({ downloads_paused: true });
    await restoreQueue([{ item: { Id: "w1", Name: "Pilot" }, q: QORIG }]);
    await open();
    click(tab("Queue"));
    const banner = root.querySelector(".dl-hold")!;
    expect(banner.querySelector("span")?.textContent).toBe("Downloads are paused");
    click(button(banner, "Resume all"));
    await settle();
    expect(playback.isDownloadsPaused()).toBe(false);
    expect(root.querySelector(".dl-hold")).toBeNull();
  });

  it("no hold banner over a queue that only has failures in it", async () => {
    list = [{ item_id: "f1", status: "error", title: "Broke", error: "x" }];
    await boot({ downloads_paused: true });
    await open();
    click(tab("Queue"));
    expect(root.querySelector(".dl-hold")).toBeNull();
    expect(texts(root, "h3.season-group")).toEqual(["Failed · 1"]);
  });

  it("on a metered connection with unmetered-only on, says what the queue waits for, and carries on when it clears", async () => {
    onInvoke("network_metered", true);
    await boot({ downloads_unmetered_only: true });
    onInvoke("network_metered", true);
    await restoreQueue([{ kind: "retry", id: "r1", title: "Held back", reason: "Waiting for an unmetered connection" }]);
    await open();
    click(tab("Queue"));
    const banner = root.querySelector(".dl-hold")!;
    expect(banner.querySelector("span")?.textContent).toBe(
      "Waiting for an unmetered connection — downloads wait until there is one"
    );
    // Pause is the user's own; a metered hold has no button to press.
    expect(banner.querySelector("button")).toBeNull();
    expect(row("Held back").querySelector(".dl-sub")?.textContent).toBe("Waiting for an unmetered connection");
    expect(invokeCalls("download_retry")).toEqual([]);

    emitEvent("network-metered", false);
    await settle();
    expect(invokeCalls("download_retry").map((c) => c.args.itemId)).toEqual(["r1"]);
    expect(root.querySelector(".dl-hold")).toBeNull();
  });

  it("a metered connection holds nothing when the setting is off", async () => {
    onInvoke("network_metered", true);
    await boot();
    onInvoke("network_metered", true);
    list = [{ item_id: "d1", status: "downloading", title: "Running" }];
    await restoreQueue([]);
    await open();
    click(tab("Queue"));
    expect(root.querySelector(".dl-hold")).toBeNull();
  });
});

// ---------------------------------------------------------------------------

describe("Manage menu (f0902f2)", () => {
  function manage(): HTMLElement {
    return root.querySelector<HTMLElement>('button[title="Manage Downloads"]')!;
  }

  it("has nothing to offer on an empty page", async () => {
    await boot();
    await open();
    expect(manage().getAttribute("aria-haspopup")).toBe("menu");
    click(manage());
    expect(menuLabels()).toEqual([]);
  });

  it("offers only what applies, each with its count", async () => {
    list = [
      ep("e1", "Alpha", 1, 1, { played: true }),
      movie("m1", "Arrival", { played: true }),
      movie("m2", "Brazil"),
      { item_id: "d1", status: "downloading", title: "Running" },
      { item_id: "f1", status: "error", title: "Broke", error: "x" },
    ];
    await boot();
    await restoreQueue([{ item: { Id: "w1", Name: "Pilot" }, q: Q720 }]);
    await open();
    click(manage());
    expect(menuLabels()).toEqual([
      "Retry All Failed (1)",
      "Clear Queue…",
      "Delete Watched Downloads… (2)",
      "Delete All Downloads…",
    ]);
    // The menu hangs off the button's own wrapper.
    expect(manage().closest(".menu-wrap")!.contains(openMenuEl())).toBe(true);
  });

  it("Retry All Failed queues them and says how many", async () => {
    list = [
      { item_id: "f1", status: "error", title: "Broke", error: "x" },
      { item_id: "f2", status: "error", title: "Also broke", error: "y" },
    ];
    await boot({ downloads_paused: true });
    await open();
    click(manage());
    await pickMenu("Retry All Failed (2)");
    await settle();
    expect(toasts()).toContain("Retrying 2 downloads");
    expect(playback.getQueuedDownloads().map((p) => p.id)).toEqual(["f1", "f2"]);
    // Both are waiting now; the menu no longer lists them as failed.
    click(manage());
    expect(menuLabels()).toEqual(["Clear Queue…", "Delete All Downloads…"]);
  });

  it("Retry All Failed from a stale menu says they are already retrying", async () => {
    list = [{ item_id: "f1", status: "error", title: "Broke", error: "x" }];
    await boot({ downloads_paused: true });
    await open();
    click(manage());
    playback.retryDownload("f1", "Broke");
    await pickMenu("Retry All Failed (1)");
    expect(toasts()).toContain("Those are already retrying");
  });

  it("Clear Queue… asks, saying nothing on disk is touched, then clears", async () => {
    list = [{ item_id: "d1", status: "downloading", title: "Running" }, movie("m1", "Arrival")];
    await boot();
    await restoreQueue([{ item: { Id: "w1", Name: "Pilot" }, q: Q720 }]);
    await open();
    click(manage());
    await pickMenu("Clear Queue…");
    expect(dialogTitle()).toBe("Clear the queue?");
    expect(dialogEl()!.querySelector("p")?.textContent).toBe(
      "2 waiting downloads will be removed. Nothing already on this computer is affected."
    );
    expect(dialogButtons()).toEqual(["Cancel", "Clear Queue"]);
    await pickDialog("Cancel");
    expect(invokeCalls("download_cancel")).toEqual([]);
    click(manage());
    await pickMenu("Clear Queue…");
    await pickDialog("Clear Queue");
    await settle();
    expect(invokeCalls("download_cancel").map((c) => c.args.itemId)).toEqual(["d1"]);
    expect(playback.getQueuedDownloads()).toEqual([]);
    expect(deleted()).toEqual([]);
    expect(toasts()).toContain("Queue cleared · 1 in progress cancelled · 1 queued item dropped");
  });

  it("Delete Watched Downloads… asks with the count and the space it frees, then deletes only those", async () => {
    list = [
      ep("e1", "Alpha", 1, 1, { played: true }),
      movie("m1", "Arrival", { played: true }),
      movie("m2", "Brazil"),
      // Marked played in its meta but not finished downloading: not "watched".
      { item_id: "x1", status: "error", title: "Half", played: true, size_bytes: 5 * GiB },
    ];
    await boot();
    await open();
    click(manage());
    await pickMenu("Delete Watched Downloads… (2)");
    expect(dialogTitle()).toBe("Delete everything you've watched?");
    expect(dialogEl()!.querySelector("p")?.textContent).toBe("2 items · 3.00 GiB");
    expect(dialogButtons()).toEqual(["Cancel", "Delete 2 Downloads"]);
    await pickDialog("Delete 2 Downloads");
    await settle();
    expect(deleted()).toEqual(["e1", "m1"]);
    expect(toasts()).toContain("Deleted 2 downloads");
  });

  it("Delete All Downloads… asks, then cancels what is running, deletes everything and drops the queue", async () => {
    list = [
      ep("e1", "Alpha", 1, 1),
      movie("m1", "Arrival"),
      { item_id: "d1", status: "downloading", title: "Running" },
    ];
    await boot();
    await restoreQueue([{ item: { Id: "w1", Name: "Pilot" }, q: Q720 }]);
    await open();
    click(manage());
    await pickMenu("Delete All Downloads…");
    expect(dialogTitle()).toBe("Delete every download?");
    expect(dialogEl()!.querySelector("p")?.textContent).toBe(
      "3 items · 3.00 GiB will be removed from this computer, and anything still queued is cancelled."
    );
    expect(dialogButtons()).toEqual(["Cancel", "Delete Everything"]);
    await pickDialog("Delete Everything");
    await settle();
    expect(invokeCalls("download_cancel").map((c) => c.args.itemId)).toEqual(["d1"]);
    expect(deleted()).toEqual(["e1", "m1", "d1"]);
    expect(playback.getQueuedDownloads()).toEqual([]);
    expect(toasts()).toContain("Deleted 3 downloads · 1 queued dropped");
    expect(root.querySelector(".state h3")?.textContent).toBe("No TV downloads yet");
  });

  it("Delete All with nothing queued does not mention the queue, and survives a list that will not load", async () => {
    list = [movie("m1", "Arrival")];
    await boot();
    await open();
    click(manage());
    await pickMenu("Delete All Downloads…");
    expect(dialogEl()!.querySelector("p")?.textContent).toContain("1 item · 2.00 GiB");
    await pickDialog("Delete Everything");
    await settle();
    expect(toasts()).toContain("Deleted 1 download");
  });
});

// ---------------------------------------------------------------------------

describe("watch state from the server", () => {
  it("pulls watched and resume state into the local copies and repaints", async () => {
    list = [ep("e1", "Alpha", 1, 1), ep("e2", "Alpha", 1, 2, { position_ticks: 5 * MIN })];
    serverItems = [
      { Id: "e1", UserData: { Played: true, PlaybackPositionTicks: 3 * MIN } },
      { Id: "e2", UserData: { Played: false, PlaybackPositionTicks: 20 * MIN } },
    ];
    await boot();
    await open();
    // Played always means "no resume point".
    expect(invokeCalls("download_set_watch_state").map((c) => c.args)).toEqual([
      { itemId: "e1", positionTicks: 0, played: true },
      { itemId: "e2", positionTicks: 20 * MIN, played: false },
    ]);
    expect(card("Alpha").querySelector(".card-sub")?.textContent).toBe("2 episodes · 1 watched");
    expect(jfPaths()[0]).toContain("/Items?userId=user-1&Ids=e1,e2");
  });

  it("local progress still waiting to sync wins over the server", async () => {
    list = [ep("e1", "Alpha", 1, 1, { position_ticks: 5 * MIN }), ep("e2", "Alpha", 1, 2)];
    pendingIds = ["e1"];
    serverItems = [
      { Id: "e1", UserData: { Played: true } },
      { Id: "e2", UserData: { Played: true } },
    ];
    await boot();
    await open();
    expect(invokeCalls("download_set_watch_state").map((c) => c.args.itemId)).toEqual(["e2"]);
    expect(jfPaths().some((p) => p.includes("Ids=e2") && !p.includes("e1"))).toBe(true);
  });

  it("asks nothing when every download has pending local progress", async () => {
    list = [ep("e1", "Alpha", 1, 1)];
    pendingIds = ["e1"];
    localStorage.setItem("aquarium-dl-details-at", String(Date.now()));
    await boot();
    await open();
    expect(jfPaths()).toEqual([]);
  });

  it("keeps local state for an item the server no longer has, and writes nothing when they already agree", async () => {
    list = [ep("e1", "Alpha", 1, 1, { played: true }), ep("e2", "Alpha", 1, 2, { position_ticks: 7 * MIN })];
    serverItems = [{ Id: "e2", UserData: { PlaybackPositionTicks: 7 * MIN } }];
    await boot();
    await open();
    expect(invokeCalls("download_set_watch_state")).toEqual([]);
    expect(card("Alpha").querySelector(".card-sub")?.textContent).toBe("2 episodes · 1 watched");
  });

  it("is skipped offline", async () => {
    list = [ep("e1", "Alpha", 1, 1)];
    serverItems = [{ Id: "e1", UserData: { Played: true } }];
    await boot();
    onInvoke("jf_ping", false);
    await api.checkOnline();
    expect(api.isOffline()).toBe(true);
    await open();
    expect(jfPaths()).toEqual([]);
    expect(invokeCalls("download_set_watch_state")).toEqual([]);
    expect(invokeCalls("progress_pending_ids")).toEqual([]);
  });

  it("a server error leaves the page as it was", async () => {
    list = [ep("e1", "Alpha", 1, 1)];
    await boot();
    mockJellyfin([], { fallbackStatus: 500 });
    await open();
    expect(texts(root, ".card-title")).toEqual(["Alpha"]);
  });
});

describe("details refresh (f0902f2)", () => {
  const T0 = new Date("2026-03-10T12:00:00Z").getTime();

  it("brings names, overview and numbering up to date and repaints", async () => {
    list = [ep("e1", "Alpha", 1, 1, { image_tag: "t1", series_image_tag: "s1", series_poster_path: "/dl/s.jpg" })];
    serverItems = [{
      Id: "e1", Type: "Episode", Name: "Renamed", SeriesName: "Alpha", ParentIndexNumber: 1, IndexNumber: 1,
      Overview: "Now with words.", RunTimeTicks: 30 * MIN, ImageTags: { Primary: "t1" }, SeriesPrimaryImageTag: "s1",
      UserData: {},
    }];
    await boot();
    onInvoke("download_update_details", ({ itemId, patch }: any) => {
      list = list.map((d) => (d.item_id === itemId ? { ...d, ...patch } : d));
      return null;
    });
    await open();
    const call = invokeCalls("download_update_details")[0]!.args;
    expect(call.itemId).toBe("e1");
    expect(call.patch).toMatchObject({
      name: "Renamed",
      overview: "Now with words.",
      series: "Alpha",
      season: 1,
      episode: 1,
      year: null,
      run_time_ticks: 30 * MIN,
      image_tag: "t1",
      series_image_tag: "s1",
    });
    // Artwork on disk with an unchanged tag is not fetched again.
    expect(call.posterUrl).toBeNull();
    expect(call.seriesPosterUrl).toBeNull();
    expect(jfPaths().some((p) => p.includes("Fields=Overview,ProductionYear"))).toBe(true);
    click(card("Alpha"));
    click(card("Season 1"));
    expect(texts(root, ".dl-row h4")).toEqual(["1. Renamed"]);
    expect(row("Renamed").querySelector(".dl-overview")?.textContent).toBe("Now with words.");
  });

  it("fetches artwork only when the server's tag moved or there is none on disk", async () => {
    list = [
      movie("m1", "Arrival", { image_tag: "old", overview: null }),
      movie("m2", "Brazil", { poster_path: null, overview: null }),
      // From before tags were kept: has a poster, no recorded tag. Not refetched.
      movie("m3", "Children of Men", { overview: null }),
    ];
    serverItems = [
      { Id: "m1", Type: "Movie", Name: "Arrival", ProductionYear: 2021, RunTimeTicks: 100 * MIN, ImageTags: { Primary: "new" }, UserData: {} },
      { Id: "m2", Type: "Movie", Name: "Brazil", ProductionYear: 2021, RunTimeTicks: 100 * MIN, ImageTags: { Primary: "b" }, UserData: {} },
      { Id: "m3", Type: "Movie", Name: "Children of Men", ProductionYear: 2021, RunTimeTicks: 100 * MIN, ImageTags: { Primary: "c" }, UserData: {} },
    ];
    await boot();
    await open();
    const calls = invokeCalls("download_update_details").map((c) => c.args);
    expect(calls.map((c) => c.itemId)).toEqual(["m1", "m2", "m3"]);
    expect(calls[0]!.posterUrl).toBe("http://jf.test:8096/Items/m1/Images/Primary?maxWidth=500&tag=new&quality=90");
    expect(calls[1]!.posterUrl).toContain("/Items/m2/Images/Primary");
    // m3 differs only in that its tag gets noted.
    expect(calls[2]!.posterUrl).toBeNull();
    expect(calls[2]!.patch.image_tag).toBe("c");
    // Films have no series poster.
    expect(calls.every((c) => c.seriesPosterUrl === null)).toBe(true);
  });

  it("fetches an episode's series poster when it has none or the series tag moved", async () => {
    list = [
      ep("e1", "Alpha", 1, 1, { image_tag: "t" }),
      ep("e2", "Alpha", 1, 2, { image_tag: "t", series_poster_path: "/dl/s.jpg", series_image_tag: "old" }),
    ];
    const base = { Type: "Episode", SeriesName: "Alpha", SeriesId: "ser1", ParentIndexNumber: 1, RunTimeTicks: 30 * MIN, ImageTags: { Primary: "t" }, SeriesPrimaryImageTag: "new", UserData: {} };
    serverItems = [
      { ...base, Id: "e1", Name: "Part 1", IndexNumber: 1 },
      { ...base, Id: "e2", Name: "Part 2", IndexNumber: 2 },
    ];
    await boot();
    await open();
    const calls = invokeCalls("download_update_details").map((c) => c.args);
    expect(calls.map((c) => c.itemId)).toEqual(["e1", "e2"]);
    expect(calls[0]!.seriesPosterUrl).toContain("/Items/ser1/Images/Primary");
    expect(calls[1]!.seriesPosterUrl).toContain("tag=new");
    expect(calls.every((c) => c.posterUrl === null)).toBe(true);
  });

  it("writes nothing for a download that already matches, or that the server no longer has", async () => {
    list = [
      movie("m1", "Arrival", { image_tag: "a", overview: "Same.", series: null, season: null, episode: null }),
      movie("gone", "Deleted upstream"),
    ];
    serverItems = [{
      Id: "m1", Type: "Movie", Name: "Arrival", Overview: "Same.", ProductionYear: 2021, RunTimeTicks: 100 * MIN,
      ImageTags: { Primary: "a" }, UserData: {},
    }];
    await boot();
    await open();
    expect(invokeCalls("download_update_details")).toEqual([]);
  });

  it("runs at most once every six hours", async () => {
    vi.useFakeTimers({ toFake: ["Date"] });
    vi.setSystemTime(T0);
    list = [movie("m1", "Arrival")];
    await boot();
    const detailCalls = (): number => jfPaths().filter((p) => p.includes("Fields=Overview")).length;
    await view.renderDownloads(root);
    await flush(60);
    expect(detailCalls()).toBe(1);
    expect(localStorage.getItem("aquarium-dl-details-at")).toBe(String(T0));

    vi.setSystemTime(T0 + 6 * 3600_000 - 1);
    await view.renderDownloads(root, { keepTab: true });
    await flush(60);
    expect(detailCalls()).toBe(1);

    vi.setSystemTime(T0 + 6 * 3600_000);
    await view.renderDownloads(root, { keepTab: true });
    await flush(60);
    expect(detailCalls()).toBe(2);
  });

  it("notes the time before asking, so a server that fails is not asked again on every render", async () => {
    list = [movie("m1", "Arrival")];
    await boot();
    mockJellyfin([], { fallbackStatus: 500 });
    await open();
    await open({ keepTab: true });
    await open({ keepTab: true });
    expect(jfPaths().filter((p) => p.includes("Fields=Overview")).length).toBe(1);
  });

  it("fetches subtitles for downloads saved before they were kept, and only those", async () => {
    list = [
      movie("m1", "Arrival", { subtitles_settled: false }),
      movie("m2", "Brazil", { subtitles_settled: true }),
      movie("m3", "Children of Men"),
    ];
    await boot();
    await open();
    expect(invokeCalls("download_fetch_subtitles").map((c) => c.args)).toEqual([{ itemId: "m1" }]);
    expect(invokeCalls("ui_log").map((c) => c.args.msg)).toContain("downloads: details refreshed (3 items, changed=false)");
  });

  it("is skipped offline and when nothing is downloaded", async () => {
    await boot();
    await open();
    expect(jfPaths()).toEqual([]);
    expect(localStorage.getItem("aquarium-dl-details-at")).toBeNull();
    list = [movie("m1", "Arrival", { subtitles_settled: false })];
    onInvoke("jf_ping", false);
    await api.checkOnline();
    await open({ keepTab: true });
    expect(jfPaths()).toEqual([]);
    expect(invokeCalls("download_fetch_subtitles")).toEqual([]);
  });
});

// ---------------------------------------------------------------------------

describe("staying current", () => {
  it("repaints when the queue changes, but only while the page is on screen", async () => {
    await boot({ downloads_paused: true });
    await open();
    const before = invokeCalls("downloads_list").length;
    document.dispatchEvent(new CustomEvent("aquarium-download-queue"));
    await settle();
    expect(invokeCalls("downloads_list").length).toBe(before + 1);

    root.innerHTML = "<h1>Home</h1>";
    document.dispatchEvent(new CustomEvent("aquarium-download-queue"));
    await settle();
    expect(invokeCalls("downloads_list").length).toBe(before + 1);
    expect(root.innerHTML).toBe("<h1>Home</h1>");

    root.remove();
    document.dispatchEvent(new CustomEvent("aquarium-download-queue"));
    await settle();
    expect(invokeCalls("downloads_list").length).toBe(before + 1);
  });

  it("repaints when playback ends, so what was just watched shows its tick (and not on every idle status)", async () => {
    list = [movie("m1", "Arrival")];
    await boot();
    await open();
    click(tab("Movies"));
    const before = invokeCalls("downloads_list").length;
    // Idle statuses with nothing having played change nothing.
    emitEvent("player-status", { active: false });
    await settle();
    expect(invokeCalls("downloads_list").length).toBe(before);

    emitEvent("player-status", { active: true, position: 10 });
    emitEvent("player-status", { active: true, position: 20 });
    list = [movie("m1", "Arrival", { played: true })];
    emitEvent("player-status", { active: false });
    await settle();
    expect(invokeCalls("downloads_list").length).toBe(before + 1);
    expect(card("Arrival").querySelector(".badge.played")).not.toBeNull();
    // Once per playback, not once per idle tick after it.
    emitEvent("player-status", { active: false });
    await settle();
    expect(invokeCalls("downloads_list").length).toBe(before + 1);
  });

  it("does not repaint after playback when another page is showing", async () => {
    await boot();
    await open();
    const before = invokeCalls("downloads_list").length;
    root.innerHTML = "";
    emitEvent("player-status", { active: true });
    emitEvent("player-status", { active: false });
    await settle();
    expect(invokeCalls("downloads_list").length).toBe(before);
  });
});

describe("updateDownloadProgress", () => {
  beforeEach(async () => {
    list = [{ item_id: "d1", status: "downloading", title: "Running", quality: "720p · 4.5 Mbps" }];
    await boot();
    await restoreQueue([]);
    await open();
    click(tab("Queue"));
  });

  function bar(): HTMLElement {
    return root.querySelector<HTMLElement>('.dl-bar[data-item="d1"] > div')!;
  }
  function sub(): string {
    return root.querySelector('[data-sub="d1"]')!.textContent ?? "";
  }

  it("fills the bar and says percent, bytes, speed and time left", () => {
    view.updateDownloadProgress(
      { item_id: "d1", state: "downloading", received: GiB / 2, total: GiB, speed_bps: 1 << 20, estimated: true },
      root
    );
    expect(bar().style.width).toBe("50%");
    expect(sub()).toBe("50% · 512.0 MiB of ~1.00 GiB · 1.0 MiB/s · 8m 32s left");
  });

  it("words the time left in seconds, minutes or hours, and leaves it off with no speed", () => {
    const tick = (received: number, speed: number): string => {
      view.updateDownloadProgress({ item_id: "d1", state: "downloading", received, total: 10 * GiB, speed_bps: speed }, root);
      return sub().split(" · ").at(-1)!;
    };
    expect(tick(10 * GiB - 30 * 1024, 1024)).toBe("30s left");
    expect(tick(10 * GiB - 90 * 1024, 1024)).toBe("1m 30s left");
    expect(tick(10 * GiB - 3 * 3600 * 1024 - 5 * 60 * 1024, 1024)).toBe("3h 5m left");
    view.updateDownloadProgress({ item_id: "d1", state: "downloading", received: GiB, total: 10 * GiB, speed_bps: 0 }, root);
    expect(sub()).toBe("10% · 1.00 GiB of 10.00 GiB");
    // Finished to the byte: nothing is left to count down.
    view.updateDownloadProgress({ item_id: "d1", state: "downloading", received: GiB, total: GiB, speed_bps: 1024 }, root);
    expect(sub()).toBe("100% · 1.00 GiB of 1.00 GiB · 1 KiB/s");
  });

  it("never draws past the end when more arrives than was estimated", () => {
    view.updateDownloadProgress({ item_id: "d1", state: "downloading", received: 2 * GiB, total: GiB, speed_bps: 0 }, root);
    expect(bar().style.width).toBe("100%");
    expect(sub()).toMatch(/^100% · /);
  });

  it("with no size at all shows a dimmed full bar and what has arrived", () => {
    view.updateDownloadProgress({ item_id: "d1", state: "downloading", received: 3 << 20, total: 0, speed_bps: 2048 }, root);
    expect(bar().style.width).toBe("100%");
    expect(bar().style.opacity).toBe("0.35");
    expect(sub()).toBe("3.0 MiB downloaded · 2 KiB/s");
    view.updateDownloadProgress({ item_id: "d1", state: "downloading", received: 4 << 20 }, root);
    expect(sub()).toBe("4.0 MiB downloaded");
  });

  it("repaints the page when a download finishes, fails or is cancelled", async () => {
    for (const state of ["complete", "error", "canceled"]) {
      const before = invokeCalls("downloads_list").length;
      view.updateDownloadProgress({ item_id: "d1", state }, root);
      await settle();
      expect(invokeCalls("downloads_list").length).toBe(before + 1);
    }
  });

  it("a finished download moves from the queue to its tab", async () => {
    list = [movie("d1", "Running")];
    view.updateDownloadProgress({ item_id: "d1", state: "complete" }, root);
    await settle();
    expect(root.querySelector(".state h3")?.textContent).toBe("The queue is empty");
    expect(tab("Movies").querySelector(".dl-tab-count")?.textContent).toBe("1");
  });

  it("does nothing for a terminal event while another page is showing", async () => {
    root.innerHTML = "<h1>Home</h1>";
    const before = invokeCalls("downloads_list").length;
    view.updateDownloadProgress({ item_id: "d1", state: "complete" }, root);
    view.updateDownloadProgress({ item_id: "d1", state: "downloading", received: 1, total: 2 }, root);
    await settle();
    expect(invokeCalls("downloads_list").length).toBe(before);
    expect(root.innerHTML).toBe("<h1>Home</h1>");
  });

  it("draws the row for a download that started after the Queue tab was painted, once, not once per tick", async () => {
    // d2's meta.json did not exist when the page was drawn.
    list = [...list, { item_id: "d2", status: "downloading", title: "Late starter" }];
    const before = invokeCalls("downloads_list").length;
    const tick = { item_id: "d2", state: "downloading", received: 1 << 20, total: 4 << 20, speed_bps: 0 };
    view.updateDownloadProgress(tick, root);
    view.updateDownloadProgress(tick, root);
    view.updateDownloadProgress(tick, root);
    await settle();
    expect(invokeCalls("downloads_list").length).toBe(before + 1);
    expect(texts(root, ".dl-row h4")).toEqual(["Running", "Late starter"]);
    // The row exists now, so the next tick fills its bar.
    view.updateDownloadProgress(tick, root);
    expect(root.querySelector<HTMLElement>('.dl-bar[data-item="d2"] > div')!.style.width).toBe("25%");
    expect(invokeCalls("downloads_list").length).toBe(before + 1);
  });

  it("can heal again later for another late download", async () => {
    list = [...list, { item_id: "d2", status: "downloading", title: "Late starter" }];
    view.updateDownloadProgress({ item_id: "d2", state: "downloading", received: 1, total: 2 }, root);
    await settle();
    list = [...list, { item_id: "d3", status: "downloading", title: "Later still" }];
    view.updateDownloadProgress({ item_id: "d3", state: "downloading", received: 1, total: 2 }, root);
    await settle();
    expect(texts(root, ".dl-row h4")).toEqual(["Running", "Late starter", "Later still"]);
  });

  it("ignores progress for an unseen download on the other tabs", async () => {
    click(tab("TV"));
    const before = invokeCalls("downloads_list").length;
    view.updateDownloadProgress({ item_id: "d9", state: "downloading", received: 1, total: 2 }, root);
    await settle();
    expect(invokeCalls("downloads_list").length).toBe(before);
  });
});
