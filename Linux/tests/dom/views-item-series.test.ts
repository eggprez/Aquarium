// The detail page for a series (src/views/item.ts): what plays next, the
// season tabs and episode rows, and the series/season/episode download menus.
// Films, single episodes and the caching rules are in views-item.test.ts.
import { beforeEach, describe, expect, it, vi, type Mock } from "vitest";
import { flush, invokeCalls, jfPaths, waitFor } from "../helpers/tauri";
import {
  $,
  $$,
  MINUTE,
  button,
  deferred,
  episode,
  hasButton,
  key,
  menu,
  menuLabels,
  mount,
  rightClick,
  season,
  series,
  toasts,
  type ServerCfg,
} from "../helpers/views-core-item";

// See views-item.test.ts: the real playItem starts libmpv and the real
// download calls run the download queue, which the playback tests cover. This
// page's contract is what it hands them.
vi.mock("../../src/playback", async (importOriginal) => {
  const real = await importOriginal<typeof import("../../src/playback")>();
  return {
    ...real,
    playItem: vi.fn(async () => {}),
    startDownload: vi.fn(async () => {}),
    downloadSeason: vi.fn(async () => ({ queued: 0, skipped: 0, cancelled: false })),
    downloadSeries: vi.fn(async () => ({ queued: 0, skipped: 0, cancelled: false, seasons: 0 })),
    queueNext: vi.fn(async (items: any[]) => items.length),
    queueLater: vi.fn(async (items: any[]) => items.length),
  };
});

beforeEach(() => {
  vi.resetModules();
  // The playback spies above survive resetModules: start each test with none of
  // the last test's calls on them.
  vi.clearAllMocks();
});

const s1eps = (): any[] => [
  episode(1, 1, {
    Name: "Pilot",
    Overview: "It begins.",
    PremiereDate: "2020-03-05T12:00:00.0000000Z",
    UserData: { Played: true },
    MediaSources: [{ Size: 1_000_000_000 }],
  }),
  episode(1, 2, {
    Name: "Second",
    UserData: { PlaybackPositionTicks: 15 * MINUTE },
    MediaSources: [{ Size: 1_000_000_000 }],
  }),
];
const s2eps = (): any[] => [episode(2, 1, { Name: "Return" })];

/** A two-season show; Next Up is S1E2 unless overridden. */
const show = (over: ServerCfg = {}): ServerCfg => ({
  item: series(),
  seasons: [season(1), season(2)],
  nextUp: s1eps()[1],
  episodes: { se1: s1eps(), se2: s2eps() },
  ...over,
});

const rows = (root: HTMLElement): HTMLElement[] => $$(".ep-row:not(.skeleton)", root);
const rowTitles = (root: HTMLElement): string[] => rows(root).map((r) => $("h4", r)!.textContent ?? "");
const tabs = (root: HTMLElement): HTMLButtonElement[] => $$<HTMLButtonElement>(".season-tabs .btn", root);

async function open(cfg: ServerCfg) {
  const m = await mount(cfg);
  await m.view.renderItem(m.root, "s1");
  return m;
}

/** Open a series page and wait for the first season's episode rows. */
async function openWithRows(cfg: ServerCfg = show()) {
  const m = await open(cfg);
  await waitFor(() => rows(m.root).length > 0);
  return m;
}

describe("series page: what plays next", () => {
  it("names the Next Up episode and plays it from the start", async () => {
    const next = episode(1, 2, { Name: "Second" });
    const { root, playback } = await open(show({ nextUp: next }));
    expect($(".detail-nextup", root)!.textContent).toBe("Next up · S1E2 · Second");
    const play = $<HTMLButtonElement>(".detail-actions .btn.primary", root)!;
    expect(play.textContent).toBe("Play S1E2");
    play.click();
    expect(playback.playItem).toHaveBeenCalledWith(next, { resume: false });
    expect(hasButton("Play from start", $(".detail-actions", root)!)).toBe(false);
  });

  it("offers Resume with the time left, and Play from start, when that episode is part-watched", async () => {
    const next = s1eps()[1];
    const { root, playback } = await open(show({ nextUp: next }));
    expect($(".detail-nextup", root)!.textContent).toBe("Resume · S1E2 · Second — 30m left");
    const actions = $(".detail-actions", root)!;
    const resume = $<HTMLButtonElement>(".btn.primary", actions)!;
    expect(resume.textContent).toBe("Resume S1E2");
    resume.click();
    expect(playback.playItem).toHaveBeenLastCalledWith(next, { resume: true });
    button("Play from start", actions).click();
    expect(playback.playItem).toHaveBeenLastCalledWith(next, { resume: false });
  });

  it('leaves the time out of the caption when the episode has no runtime (regression: "( left)", a963a95)', async () => {
    const next = episode(1, 2, { Name: "Second", RunTimeTicks: undefined, UserData: { PlaybackPositionTicks: MINUTE } });
    const { root } = await open(show({ nextUp: next }));
    expect($(".detail-nextup", root)!.textContent).toBe("Resume · S1E2 · Second");
  });

  it("drops the episode code from the caption and the buttons when the episode is not numbered", async () => {
    const plain = episode(1, 2, { Name: "Special", ParentIndexNumber: undefined });
    let m = await open(show({ nextUp: plain }));
    expect($(".detail-nextup", m.root)!.textContent).toBe("Next up · Special");
    expect($(".detail-actions .btn.primary", m.root)!.textContent).toBe("Play");

    vi.resetModules();
    m = await open(show({ nextUp: { ...plain, UserData: { PlaybackPositionTicks: MINUTE } } }));
    expect($(".detail-actions .btn.primary", m.root)!.textContent).toBe("Resume");
  });

  it("has no caption and no play button when there is nothing to play, but still offers Add to Next Up", async () => {
    const { root } = await open({ item: series(), seasons: [] });
    expect($(".detail-nextup", root)).toBeNull();
    const actions = $(".detail-actions", root)!;
    expect($$("button", actions).map((b) => b.textContent)).toEqual(["Add to Next Up…"]);
  });

  it("does not get the film's quality, download and watched bar", async () => {
    const { root } = await open(show());
    const actions = $(".detail-actions", root)!;
    for (const label of ["Quality", "Up Next", "Mark watched"]) expect(hasButton(label, actions)).toBe(false);
  });

  it("Add to Next Up asks where to pick the show up, and adds it on the server from the choice made", async () => {
    const { root, api } = await open(show());
    const added = vi.spyOn(api, "addToNextUp").mockResolvedValue(episode(1, 2));
    button("Add to Next Up", $(".detail-actions", root)!).click();
    const dialog = $(".dialog")!;
    expect($("h2", dialog)!.textContent).toBe("Add The Show to Next Up");
    button("Add from Last Watched Episode", dialog).click();
    expect($(".dialog")).toBeNull();
    await waitFor(() => toasts().length > 0);
    expect(added).toHaveBeenCalledWith("s1", "last");
  });

  it("right-clicking the hero offers the series menu", async () => {
    const { root } = await open(show());
    rightClick($(".detail-hero", root)!);
    const labels = menuLabels();
    expect(labels).toEqual(expect.arrayContaining(["Download series", "Mark watched", "Add to Next Up…"]));
    // A series is not itself playable.
    expect(labels).not.toContain("Play");
  });

  it("marking the series watched from the hero menu does not fail for want of a watched button", async () => {
    const { root } = await open(show());
    rightClick($(".detail-hero", root)!);
    button("Mark watched", menu()).click();
    await waitFor(() => toasts().length > 0);
    expect(toasts()).toEqual(["Marked watched"]);
  });
});

describe("series page: seasons", () => {
  it("says so when the server has the series but no seasons, and stops there", async () => {
    const { root } = await open({ item: series(), seasons: [] });
    const state = $(".state", root)!;
    expect($("h3", state)!.textContent).toBe("No seasons for this show");
    expect($("p", state)!.textContent).toContain("library scan");
    expect($(".season-tabs", root)).toBeNull();
    expect($(".season-actions", root)).toBeNull();
    await flush(30);
    expect(jfPaths().some((p) => p.includes("/Similar"))).toBe(false);
  });

  it("makes a tab per season, named by the server or by number", async () => {
    const { root } = await openWithRows(show({ seasons: [season(1), season(2, { Name: undefined })] }));
    expect(tabs(root).map((b) => b.textContent)).toEqual(["Season 1", "Season 2"]);
    expect(tabs(root).every((b) => b.classList.contains("has-ctx"))).toBe(true);
  });

  it("opens on the season the play button would start from", async () => {
    const { root } = await openWithRows(show({ nextUp: episode(2, 1, { Name: "Return" }) }));
    expect(tabs(root).map((b) => b.classList.contains("active"))).toEqual([false, true]);
    expect(rowTitles(root)).toEqual(["1. Return"]);
    // Only the open season's episodes were asked for.
    expect(jfPaths().filter((p) => p.includes("/Episodes")).map((p) => /seasonId=([^&]+)/.exec(p)![1])).toEqual(["se2"]);
  });

  it("opens on the first season when the play target belongs to none of them", async () => {
    const { root } = await openWithRows(show({ nextUp: episode(9, 1, { SeasonId: "gone" }) }));
    expect(tabs(root).map((b) => b.classList.contains("active"))).toEqual([true, false]);
    expect(rowTitles(root)).toEqual(["1. Pilot", "2. Second"]);
  });

  it("shows placeholder rows while a season loads", async () => {
    const gate = deferred();
    const { root } = await open(show({ episodes: { se1: () => gate.promise } }));
    expect($$(".ep-row.skeleton", root)).toHaveLength(5);
    gate.resolve(s1eps());
    await waitFor(() => rows(root).length === 2);
    expect($$(".ep-row.skeleton", root)).toHaveLength(0);
  });

  it("switches season on a tab click", async () => {
    const { root } = await openWithRows();
    tabs(root)[1]!.click();
    await waitFor(() => rowTitles(root)[0] === "1. Return");
    expect(tabs(root).map((b) => b.classList.contains("active"))).toEqual([false, true]);
    expect(rowTitles(root)).toEqual(["1. Return"]);
    expect($(".season-actions .btn", $(".season-tabs", root)!.nextElementSibling!)!.textContent).toBe(
      "Download season · 1 ep"
    );
  });

  it("a slow season that answers after another tab was clicked does not replace the newer list", async () => {
    const gate = deferred();
    const { root } = await open(show({ episodes: { se1: () => gate.promise, se2: s2eps() } }));
    tabs(root)[1]!.click();
    await waitFor(() => rows(root).length === 1);
    gate.resolve(s1eps());
    await flush(30);
    expect(rowTitles(root)).toEqual(["1. Return"]);
    expect(tabs(root).map((b) => b.classList.contains("active"))).toEqual([false, true]);
  });

  it("says a season is empty, by name, when it has no episodes or they fail to load", async () => {
    let m = await open(show({ episodes: { se1: [] } }));
    await waitFor(() => !!$(".state", m.root));
    expect($(".state h3", m.root)!.textContent).toBe("This season is empty");
    expect($(".state p", m.root)!.textContent).toBe("Jellyfin lists Season 1 but has no episodes in it yet.");
    expect($$(".season-actions", m.root)).toHaveLength(1); // the series bar only

    vi.resetModules();
    m = await open(show({ seasons: [season(1, { Name: undefined })], episodes: { se1: { __status: 500 } } }));
    await waitFor(() => !!$(".state", m.root));
    expect($(".state p", m.root)!.textContent).toBe("Jellyfin lists this season but has no episodes in it yet.");
  });

  it("right-clicking a season tab queues the whole season, next or later", async () => {
    // Seasons as some servers send them, without a SeriesId: the page fills it in.
    const bare = [season(1, { SeriesId: undefined }), season(2)];
    const { root, playback } = await openWithRows(show({ seasons: bare }));
    rightClick(tabs(root)[0]!);
    expect($(".menu-label", menu())!.textContent).toBe("Season 1");
    expect(menuLabels()).toEqual(["Play Season Next", "Play Season Later"]);
    button("Play Season Next", menu()).click();
    await waitFor(() => toasts().length === 1);
    expect(playback.queueNext).toHaveBeenCalledWith([expect.objectContaining({ Id: "se1", Type: "Season", SeriesId: "s1" })]);

    rightClick(tabs(root)[1]!);
    button("Play Season Later", menu()).click();
    await waitFor(() => toasts().length === 2);
    expect(playback.queueLater).toHaveBeenCalledWith([expect.objectContaining({ Id: "se2", SeriesId: "s1" })]);
  });

  it("puts cast and recommendations below the episodes", async () => {
    const cast = [{ Id: "a1", Name: "Ann Actor", Type: "Actor" }];
    const { root } = await openWithRows(show({ item: series({ People: cast }), similar: [series({ Id: "s2", Name: "Other Show" })] }));
    await waitFor(() => $$(".card:not(.skeleton)", root).length === 1);
    const order = Array.from(root.firstElementChild!.children).map((c) => c.classList[0] || "episodes");
    expect(order).toEqual(["detail-hero", "season-actions", "season-tabs", "episodes", "section", "section"]);
    expect($$(".section h2", root).map((h) => h.textContent)).toEqual(["Cast", "More like this"]);
  });
});

describe("series page: episode rows", () => {
  it("shows number and name, the overview, runtime and air date, and marks what has been watched", async () => {
    const { root } = await openWithRows();
    const [pilot, second] = rows(root);
    expect($("h4", pilot!)!.textContent).toBe("1. Pilot");
    expect($("p", pilot!)!.textContent).toBe("It begins.");
    const aired = new Date("2020-03-05T12:00:00.0000000Z").toLocaleDateString(undefined, {
      day: "numeric",
      month: "short",
      year: "numeric",
    });
    expect($(".card-sub", pilot!)!.textContent).toBe(`45m  ·  ${aired}`);
    expect(pilot!.classList.contains("watched")).toBe(true);
    expect($("h4 svg", pilot!)).not.toBeNull();
    expect(pilot!.getAttribute("aria-label")).toBe("Play 1. Pilot");
    expect(pilot!.getAttribute("role")).toBe("button");
    expect(pilot!.getAttribute("tabindex")).toBe("0");

    expect(second!.classList.contains("watched")).toBe(false);
    expect($("h4 svg", second!)).toBeNull();
    expect($("p", second!)!.textContent).toBe("");
    expect($(".card-sub", second!)!.textContent).toBe("45m");
  });

  it("draws a progress strip only on a part-watched episode", async () => {
    const { root } = await openWithRows();
    const [pilot, second] = rows(root);
    expect($(".progress-strip", pilot!)).toBeNull();
    const bar = $<HTMLElement>(".progress-strip div", second!)!;
    expect(parseFloat(bar.style.width)).toBeCloseTo((15 / 45) * 100, 3);
  });

  it("caps the progress strip at the full width, and omits the number an episode does not have", async () => {
    const odd = episode(1, 1, {
      Name: "Extra",
      IndexNumber: undefined,
      ImageTags: {},
      UserData: { PlaybackPositionTicks: 90 * MINUTE },
    });
    const { root } = await openWithRows(show({ episodes: { se1: [odd] } }));
    const row = rows(root)[0]!;
    expect($("h4", row)!.textContent).toBe("Extra");
    expect(row.getAttribute("aria-label")).toBe("Play Extra");
    expect($<HTMLElement>(".progress-strip div", row)!.style.width).toBe("100%");
    // No still: a play icon tile.
    expect($(".ep-thumb .noart svg", row)).not.toBeNull();
  });

  it("plays the episode, resuming, from the thumbnail, the Play button, Enter and Space", async () => {
    const { root, playback } = await openWithRows();
    const row = rows(root)[1]!;
    const ep = expect.objectContaining({ Id: "e1-2" });
    $<HTMLElement>(".ep-thumb", row)!.click();
    expect(playback.playItem).toHaveBeenLastCalledWith(ep, { resume: true });
    button("Play", $(".ep-actions", row)!).click();
    expect(playback.playItem).toHaveBeenLastCalledWith(ep, { resume: true });
    const enter = key(row, "Enter");
    const space = key(row, " ");
    expect(enter.defaultPrevented && space.defaultPrevented).toBe(true);
    expect(playback.playItem).toHaveBeenCalledTimes(4);
    key(row, "x");
    expect(playback.playItem).toHaveBeenCalledTimes(4);
  });

  it("Enter on a button inside the row is that button's key, not the row's", async () => {
    const { root, playback } = await openWithRows();
    const row = rows(root)[0]!;
    const ev = key($(".ep-actions .btn.primary", row)!, "Enter");
    expect(playback.playItem).not.toHaveBeenCalled();
    expect(ev.defaultPrevented).toBe(false);
  });

  it("the row's download button lists the qualities and starts the one picked for that episode", async () => {
    const { root, playback, api, ui } = await openWithRows();
    const row = rows(root)[0]!;
    const dl = $<HTMLButtonElement>('button[aria-label="Download"]', row)!;
    dl.click();
    expect(menu().parentElement).toBe(dl.parentElement);
    expect($(".menu-label", menu())!.textContent).toBe("Download as");
    const pilot = s1eps()[0];
    expect(menuLabels()).toEqual(api.DOWNLOAD_QUALITIES.map((q) => ui.downloadLabel(pilot, q)));
    button("Original quality", menu()).click();
    expect(playback.startDownload).toHaveBeenCalledWith(expect.objectContaining({ Id: "e1-1" }), api.DOWNLOAD_QUALITIES[0]);
    expect($(".menu")).toBeNull();
    // Opening the menu is not a click on the row.
    expect(playback.playItem).not.toHaveBeenCalled();
  });

  it("shows why an episode's download did not start", async () => {
    const { root, playback } = await openWithRows();
    (playback.startDownload as Mock).mockRejectedValueOnce(new Error("no room"));
    $<HTMLButtonElement>('button[aria-label="Download"]', rows(root)[0]!)!.click();
    button("Original quality", menu()).click();
    await waitFor(() => toasts().length > 0);
    expect(toasts()).toEqual(["Error: no room"]);
  });

  it("right-click marks an episode watched on the server and redraws just that row", async () => {
    const { root } = await openWithRows();
    const [pilot, second] = rows(root);
    rightClick(second!);
    expect($(".menu-label", menu())!.textContent).toBe("Second");
    expect(menuLabels()).toEqual(expect.arrayContaining(["Go to series", "Show details", "Add Show to Next Up…"]));
    button("Mark watched", menu()).click();
    await waitFor(() => rows(root)[1]!.classList.contains("watched"));
    expect(invokeCalls("jf_request").some((c) => c.args.method === "POST" && c.args.path.startsWith("/UserPlayedItems/e1-2"))).toBe(true);
    expect(rows(root)[1]).not.toBe(second);
    expect(rows(root)[0]).toBe(pilot);
    expect(rowTitles(root)).toEqual(["1. Pilot", "2. Second"]);
    // Marking watched clears the resume point, and with it the strip.
    expect($(".progress-strip", rows(root)[1]!)).toBeNull();
    // The hero's own menu was not the one that opened (innermost target wins).
    expect($$(".menu")).toHaveLength(0);
  });
});

describe("series page: Download series", () => {
  const bar = (root: HTMLElement): HTMLButtonElement =>
    $<HTMLButtonElement>(".detail-hero + .season-actions .btn", root)!;

  it("counts the seasons on the button", async () => {
    let m = await openWithRows();
    expect(bar(m.root).textContent).toBe("Download series · 2 seasons");
    vi.resetModules();
    m = await openWithRows(show({ seasons: [season(1)] }));
    expect(bar(m.root).textContent).toBe("Download series · 1 season");
  });

  it("asks for no episode lists until a quality is picked", async () => {
    const { root } = await openWithRows();
    bar(root).click();
    expect($(".menu-label", menu())!.textContent).toBe("Download every episode as");
    // Only the open season's list has been fetched, by the tab.
    expect(jfPaths().filter((p) => p.includes("/Episodes"))).toHaveLength(1);
  });

  it("lists the plain qualities and queues the whole show with the seasons already loaded", async () => {
    const { root, playback, api } = await openWithRows();
    const gate = deferred();
    (playback.downloadSeries as Mock).mockReturnValueOnce(gate.promise);
    const btn = bar(root);
    btn.click();
    expect(menuLabels()).toEqual(api.DOWNLOAD_QUALITIES.map((q) => q.label));
    button("720p", menu()).click();
    expect($(".menu")).toBeNull();
    expect(playback.downloadSeries).toHaveBeenCalledWith(
      "s1",
      api.DOWNLOAD_QUALITIES.find((q) => q.name === "720p"),
      [expect.objectContaining({ Id: "se1" }), expect.objectContaining({ Id: "se2" })]
    );
    // Busy while the episode lists are collected.
    expect(btn.disabled).toBe(true);
    expect(btn.textContent).toBe("Collecting episodes…");
    gate.resolve({ queued: 3, skipped: 1, cancelled: false, seasons: 2 });
    await waitFor(() => !btn.disabled);
    expect(btn.textContent).toBe("Download series · 2 seasons");
    expect($("svg", btn)).not.toBeNull();
    expect(toasts()).toEqual(["Queued 3 episodes from 2 seasons, skipped 1 already downloaded"]);
    expect($("#toasts .toast")!.classList.contains("ok")).toBe(true);
  });

  const pick = async (root: HTMLElement): Promise<void> => {
    const btn = bar(root);
    btn.click();
    button("Original quality", menu()).click();
    expect(btn.disabled).toBe(true);
    await waitFor(() => !btn.disabled);
  };

  it("uses the singular for one episode and one season", async () => {
    const { root, playback } = await openWithRows(show({ seasons: [season(1)] }));
    (playback.downloadSeries as Mock).mockResolvedValueOnce({ queued: 1, skipped: 0, cancelled: false, seasons: 1 });
    await pick(root);
    expect(toasts()).toEqual(["Queued 1 episode from 1 season"]);
  });

  it("says when there was nothing left to queue", async () => {
    const { root, playback } = await openWithRows();
    (playback.downloadSeries as Mock).mockResolvedValueOnce({ queued: 0, skipped: 3, cancelled: false, seasons: 2 });
    await pick(root);
    expect(toasts()).toEqual(["Every episode is already downloaded or queued"]);
  });

  it("says nothing when the user cancelled at the disk-space prompt, and gives the button back", async () => {
    const { root, playback } = await openWithRows();
    (playback.downloadSeries as Mock).mockResolvedValueOnce({ queued: 0, skipped: 0, cancelled: true, seasons: 2 });
    await pick(root);
    expect(toasts()).toEqual([]);
    expect(bar(root).textContent).toBe("Download series · 2 seasons");
  });

  it("reports a failure and gives the button back", async () => {
    const { root, playback } = await openWithRows();
    (playback.downloadSeries as Mock).mockRejectedValueOnce(new Error("No episodes found for this series"));
    await pick(root);
    expect(toasts()).toEqual(["Series download failed: No episodes found for this series"]);
    expect(bar(root).disabled).toBe(false);
    expect(bar(root).textContent).toBe("Download series · 2 seasons");
  });
});

describe("series page: Download season", () => {
  const bar = (root: HTMLElement): HTMLButtonElement =>
    $<HTMLButtonElement>(".season-tabs + div .season-actions .btn", root)!;

  it("counts the season's episodes on the button", async () => {
    const { root } = await openWithRows();
    expect(bar(root).textContent).toBe("Download season · 2 ep");
  });

  it("totals the size of the season for each quality", async () => {
    const { root, api } = await openWithRows();
    bar(root).click();
    expect($(".menu-label", menu())!.textContent).toBe("Download all episodes as");
    const labels = menuLabels();
    expect(labels).toHaveLength(api.DOWNLOAD_QUALITIES.length);
    // Two files of 1 GB each, exactly.
    expect(labels[0]).toBe(`Original quality · ${api.bytesToText(2_000_000_000)}`);
    // An estimate for a transcode, both episodes added together.
    const q480 = api.DOWNLOAD_QUALITIES.find((q) => q.name === "480p")!;
    const each = api.estimateDownloadSize(s1eps()[0], q480)!;
    expect(each).toBeLessThan(1_000_000_000);
    expect(labels[labels.length - 1]).toBe(`480p · 2 Mbps · ~${api.bytesToText(each * 2)}`);
  });

  it("shows the bare quality names when no episode's size can be estimated", async () => {
    const eps = [episode(1, 1, { RunTimeTicks: undefined }), episode(1, 2, { RunTimeTicks: undefined })];
    const { root, api } = await openWithRows(show({ episodes: { se1: eps } }));
    bar(root).click();
    expect(menuLabels()).toEqual(api.DOWNLOAD_QUALITIES.map((q) => q.label));
  });

  const pick = async (root: HTMLElement, label = "Original quality"): Promise<void> => {
    bar(root).click();
    button(label, menu()).click();
    expect($(".menu")).toBeNull();
    await flush(30);
  };

  it("queues exactly the season's episodes at the quality picked", async () => {
    const { root, playback, api } = await openWithRows();
    (playback.downloadSeason as Mock).mockResolvedValueOnce({ queued: 2, skipped: 0, cancelled: false });
    await pick(root, "1080p");
    const [eps, q] = (playback.downloadSeason as Mock).mock.calls[0]!;
    expect(eps.map((e: any) => e.Id)).toEqual(["e1-1", "e1-2"]);
    expect(q).toBe(api.DOWNLOAD_QUALITIES.find((x) => x.name === "1080p"));
    expect(toasts()).toEqual(["Queued 2 episodes"]);
  });

  it("mentions what was skipped, and uses the singular for one", async () => {
    const { root, playback } = await openWithRows();
    (playback.downloadSeason as Mock).mockResolvedValueOnce({ queued: 1, skipped: 1, cancelled: false });
    await pick(root);
    expect(toasts()).toEqual(["Queued 1 episode, skipped 1 already downloaded"]);
  });

  it("says when every episode was already downloaded or queued", async () => {
    const { root, playback } = await openWithRows();
    (playback.downloadSeason as Mock).mockResolvedValueOnce({ queued: 0, skipped: 2, cancelled: false });
    await pick(root);
    expect(toasts()).toEqual(["All episodes are already downloaded or queued"]);
  });

  it("says nothing when the user cancelled", async () => {
    const { root, playback } = await openWithRows();
    (playback.downloadSeason as Mock).mockResolvedValueOnce({ queued: 0, skipped: 0, cancelled: true });
    await pick(root);
    expect(toasts()).toEqual([]);
  });

  it("reports a failure", async () => {
    const { root, playback } = await openWithRows();
    (playback.downloadSeason as Mock).mockRejectedValueOnce(new Error("offline"));
    await pick(root);
    expect(toasts()).toEqual(["Season download failed: offline"]);
  });
});

describe("series page: cache-first paint", () => {
  const cached = (over: Record<string, any> = {}): any => ({
    item: series(),
    seasons: [season(1), season(2)],
    playTarget: s1eps()[1],
    ...over,
  });

  it("paints the cached series, tabs and play button at once, and leaves them alone when nothing changed", async () => {
    const gate = deferred();
    const m = await mount(show({ item: () => gate.promise }));
    m.cache.setCached("item:s1", cached());
    const done = m.view.renderItem(m.root, "s1");
    expect($(".detail-nextup", m.root)!.textContent).toContain("S1E2 · Second");
    expect(tabs(m.root)).toHaveLength(2);
    const hero = $(".detail-hero", m.root)!;
    const firstTab = tabs(m.root)[0]!;
    gate.resolve(series());
    await done;
    await waitFor(() => rows(m.root).length === 2);
    expect($(".detail-hero", m.root)).toBe(hero);
    expect(tabs(m.root)[0]).toBe(firstTab);
    // The season's episodes were fetched once: there was no second paint.
    expect(jfPaths().filter((p) => p.includes("/Episodes"))).toHaveLength(1);
  });

  it("repaints when the episode to play next has moved on", async () => {
    const m = await mount(show({ nextUp: episode(2, 1, { Name: "Return" }) }));
    m.cache.setCached("item:s1", cached());
    const done = m.view.renderItem(m.root, "s1");
    const hero = $(".detail-hero", m.root)!;
    await done;
    expect($(".detail-hero", m.root)).not.toBe(hero);
    expect($(".detail-nextup", m.root)!.textContent).toBe("Next up · S2E1 · Return");
    expect(tabs(m.root).map((b) => b.classList.contains("active"))).toEqual([false, true]);
  });

  it("repaints when a new season has appeared", async () => {
    const m = await mount(show({ seasons: [season(1), season(2), season(3)] }));
    m.cache.setCached("item:s1", cached());
    const done = m.view.renderItem(m.root, "s1");
    expect(tabs(m.root)).toHaveLength(2);
    await done;
    expect(tabs(m.root).map((b) => b.textContent)).toEqual(["Season 1", "Season 2", "Season 3"]);
  });
});
