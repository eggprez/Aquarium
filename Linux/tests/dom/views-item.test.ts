// The detail page for a film or a single episode (src/views/item.ts): what the
// hero shows, what each control does, the cache-first paint and the guards
// against painting a page the user has already left. Series pages are in
// views-item-series.test.ts.
import { beforeEach, describe, expect, it, vi, type Mock } from "vitest";
import { flush, jfPaths, invokeCalls, waitFor } from "../helpers/tauri";
import {
  $,
  $$,
  HOUR,
  MINUTE,
  button,
  deferred,
  episode,
  hasButton,
  key,
  menu,
  menuLabels,
  mount,
  movie,
  rightClick,
  series,
  season,
  toasts,
} from "../helpers/views-core-item";

// The real playItem negotiates a stream and starts libmpv, and the real
// download calls run the whole download queue (disk-space prompt, pump,
// backend transfer): both belong to the playback tests. What this page owes
// them is the item and the options it hands over, so those four entry points
// (and the Up Next queue, which for a season fetches its episodes) are spies.
// Everything else in playback.ts, QUALITY_CHOICES included, is the real thing.
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

const itemRequests = (): string[] => jfPaths().filter((p) => /^\/Items\/[^/?]+\?/.test(p));
const similarRequests = (): string[] => jfPaths().filter((p) => p.includes("/Similar"));

describe("fetchItemData", () => {
  it("fetches a film in one request, with the detail fields, and caches it under its id", async () => {
    const m = movie();
    const { view, cache } = await mount({ item: m });
    const data = await view.fetchItemData("m1");
    expect(data).toEqual({ item: m, seasons: [], playTarget: null });
    expect(itemRequests()).toHaveLength(1);
    expect(itemRequests()[0]).toMatch(/^\/Items\/m1\?userId=user-1&Fields=.*People/);
    expect(jfPaths().some((p) => p.startsWith("/Shows/"))).toBe(false);
    expect(cache.getCached("item:m1")).toEqual(data);
  });

  it("fetches a series' seasons and Next Up episode along with it", async () => {
    const next = episode(2, 3);
    const { view } = await mount({ item: series(), seasons: [season(1), season(2)], nextUp: next });
    const data = await view.fetchItemData("s1");
    expect(data.seasons.map((s: any) => s.Id)).toEqual(["se1", "se2"]);
    expect(data.playTarget).toEqual(next);
    // Next Up answered, so no episode list is needed to pick a play target.
    expect(jfPaths().some((p) => p.includes("/Episodes"))).toBe(false);
  });

  it("falls back to the first unwatched episode of the first season when Next Up is empty", async () => {
    const eps = [episode(1, 1, { UserData: { Played: true } }), episode(1, 2), episode(1, 3)];
    const { view } = await mount({ item: series(), seasons: [season(1), season(2)], nextUp: null, episodes: { se1: eps } });
    const data = await view.fetchItemData("s1");
    expect(data.playTarget.Id).toBe("e1-2");
    expect(jfPaths().filter((p) => p.includes("/Episodes"))).toEqual([
      expect.stringContaining("/Shows/s1/Episodes?userId=user-1&seasonId=se1"),
    ]);
  });

  it("falls back to the season opener when every episode has been watched", async () => {
    const eps = [episode(1, 1, { UserData: { Played: true } }), episode(1, 2, { UserData: { Played: true } })];
    const { view } = await mount({ item: series(), seasons: [season(1)], episodes: { se1: eps } });
    expect((await view.fetchItemData("s1")).playTarget.Id).toBe("e1-1");
  });

  it("has no play target for a series with no seasons, or whose first season is empty or fails to load", async () => {
    let m = await mount({ item: series(), seasons: [] });
    expect((await m.view.fetchItemData("s1")).playTarget).toBeNull();
    vi.resetModules();
    m = await mount({ item: series(), seasons: [season(1)], episodes: { se1: [] } });
    expect((await m.view.fetchItemData("s1")).playTarget).toBeNull();
    vi.resetModules();
    m = await mount({ item: series(), seasons: [season(1)], episodes: { se1: { __status: 500 } } });
    expect((await m.view.fetchItemData("s1")).playTarget).toBeNull();
  });

  it("still resolves a series when the seasons and Next Up requests both fail", async () => {
    const { view } = await mount({ item: series(), seasons: { __status: 500 }, nextUp: { __status: 500 } });
    const data = await view.fetchItemData("s1");
    expect(data.seasons).toEqual([]);
    expect(data.playTarget).toBeNull();
  });

  it("shares one request between a prefetch and the page's own load of the same id", async () => {
    const gate = deferred();
    const { view } = await mount({ item: () => gate.promise });
    const a = view.fetchItemData("m1");
    const b = view.fetchItemData("m1");
    expect(b).toBe(a);
    gate.resolve(movie());
    await a;
    expect(itemRequests()).toHaveLength(1);
    // Once it has landed the next call asks the server again.
    await view.fetchItemData("m1");
    expect(itemRequests()).toHaveLength(2);
  });

  it("does not share requests between different ids", async () => {
    const { view } = await mount({ item: (a: any) => movie({ Id: /Items\/([^?]+)/.exec(a.path)![1] }) });
    const [a, b] = await Promise.all([view.fetchItemData("m1"), view.fetchItemData("m2")]);
    expect([a.item.Id, b.item.Id]).toEqual(["m1", "m2"]);
    expect(itemRequests()).toHaveLength(2);
  });

  it("rejects when the item cannot be loaded, caches nothing, and lets the next call retry", async () => {
    let fail = true;
    const { view, cache } = await mount({ item: () => (fail ? { __status: 500 } : movie()) });
    await expect(view.fetchItemData("m1")).rejects.toThrow("Server error 500 on /Items/m1");
    expect(cache.getCached("item:m1")).toBeUndefined();
    fail = false;
    expect((await view.fetchItemData("m1")).item.Id).toBe("m1");
  });
});

describe("film page: the hero", () => {
  it("shows a skeleton until the item arrives, then the hero", async () => {
    const gate = deferred();
    const { view, root } = await mount({ item: () => gate.promise });
    const done = view.renderItem(root, "m1");
    expect($(".detail-hero.skeleton", root)).not.toBeNull();
    expect($(".detail-title", root)).toBeNull();
    gate.resolve(movie());
    await done;
    expect($(".detail-hero.skeleton", root)).toBeNull();
    expect($(".detail-title .title-text", root)!.textContent).toBe("Big Film");
  });

  it("replaces whatever the root held before", async () => {
    const { view, root } = await mount({ item: movie() });
    root.append(document.createElement("aside"));
    await view.renderItem(root, "m1");
    expect($("aside", root)).toBeNull();
    expect(root.children).toHaveLength(1);
  });

  it("lists year, runtime, rating, score and at most four genres", async () => {
    const { view, root } = await mount({ item: movie() });
    await view.renderItem(root, "m1");
    const meta = $(".detail-inner .detail-meta:not(.clickable)", root)!;
    expect($$(":scope > span", meta).map((s) => s.textContent)).toEqual([
      "1999", "2h 0m", "PG", "7.5", "Drama", "Comedy", "Crime", "Mystery",
    ]);
    expect($(".meta-rating svg", meta)).not.toBeNull();
    expect($$(".chip", meta).map((s) => s.textContent)).toEqual(["PG", "Drama", "Comedy", "Crime", "Mystery"]);
  });

  it("leaves out every meta chip the item has no data for", async () => {
    const bare = { Id: "m1", Type: "Movie", Name: "Bare" };
    const { view, root } = await mount({ item: bare });
    await view.renderItem(root, "m1");
    expect($(".detail-meta", root)!.children).toHaveLength(0);
    expect($(".detail-overview", root)).toBeNull();
    expect($(".detail-crew", root)).toBeNull();
    expect($(".detail-source", root)).toBeNull();
    expect($(".detail-backdrop-clip", root)).toBeNull();
    // No artwork: the poster is a letter tile.
    expect($(".detail-poster .noart", root)!.textContent).toBe("B");
  });

  it("shows the overview, the crew line and what the file on the server is", async () => {
    const m = movie({
      People: [
        { Name: "D1", Type: "Director" },
        { Name: "W1", Type: "Writer" },
        { Name: "W2", Type: "Writer" },
        { Name: "W3", Type: "Writer" },
        { Name: "W4", Type: "Writer" },
        { Type: "Writer" },
      ],
    });
    const { view, root, api } = await mount({ item: m });
    await view.renderItem(root, "m1");
    expect($(".detail-overview", root)!.textContent).toBe("A film about a test.");
    // Three names per credit at most; a credit with no name is skipped.
    expect($(".detail-crew", root)!.textContent).toBe("Directed by D1  ·  Written by W1, W2, W3");
    const source = $(".detail-source", root)!.textContent!;
    expect(source).toBe(api.mediaSummary(m).join(" · "));
    expect(source).toContain("HEVC");
    expect(source).toContain("EAC3");
  });

  it("shows only the credits that exist", async () => {
    const { view, root } = await mount({ item: movie({ People: [{ Name: "W1", Type: "Writer" }] }) });
    await view.renderItem(root, "m1");
    expect($(".detail-crew", root)!.textContent).toBe("Written by W1");
  });

  it("loads the poster eagerly and puts the backdrop in its own clipping frame", async () => {
    const { view, root } = await mount({ item: movie() });
    await view.renderItem(root, "m1");
    const poster = $<HTMLImageElement>(".detail-poster img", root)!;
    expect(poster.getAttribute("src")).toBe("http://jf.test:8096/Items/m1/Images/Primary?maxWidth=500&tag=p1&quality=90");
    expect(poster.hasAttribute("loading")).toBe(false);
    // The clip is on a wrapper, not the hero: the hero's dropdowns open inside it.
    expect($(".detail-hero > .detail-backdrop-clip > .detail-backdrop", root)).not.toBeNull();
  });

  it("sets the title in the studio's logo art when the film has one, keeping the text underneath", async () => {
    const { view, root } = await mount({ item: movie({ ImageTags: { Primary: "p1", Logo: "l1" } }) });
    await view.renderItem(root, "m1");
    const logo = $<HTMLImageElement>("h1.detail-title img.title-logo", root)!;
    expect(logo.getAttribute("src")).toContain("/Items/m1/Images/Logo");
    expect(logo.alt).toBe("Big Film");
    expect($("h1.detail-title .title-text", root)!.textContent).toBe("Big Film");
  });
});

describe("film page: play buttons", () => {
  it("offers Play, from the start, on something not yet started", async () => {
    const m = movie();
    const { view, root, playback } = await mount({ item: m });
    await view.renderItem(root, "m1");
    const actions = $(".detail-actions", root)!;
    expect(hasButton("Resume", actions)).toBe(false);
    expect(hasButton("Play from start", actions)).toBe(false);
    const play = $<HTMLButtonElement>(".btn.primary", actions)!;
    expect(play.textContent).toBe("Play");
    play.click();
    expect(playback.playItem).toHaveBeenCalledTimes(1);
    expect(playback.playItem).toHaveBeenCalledWith(m, { resume: false });
  });

  it("offers Resume with the time left, and Play from start, on something part-watched", async () => {
    const m = movie({ UserData: { PlaybackPositionTicks: HOUR } });
    const { view, root, playback } = await mount({ item: m });
    await view.renderItem(root, "m1");
    const actions = $(".detail-actions", root)!;
    const resume = $<HTMLButtonElement>(".btn.primary", actions)!;
    expect(resume.textContent).toBe("Resume (1h 0m left)");
    resume.click();
    expect(playback.playItem).toHaveBeenLastCalledWith(m, { resume: true });
    button("Play from start", actions).click();
    expect(playback.playItem).toHaveBeenLastCalledWith(m, { resume: false });
    expect(playback.playItem).toHaveBeenCalledTimes(2);
  });

  it('says just "Resume" when the item has no runtime (regression: "Resume ( left)", a963a95)', async () => {
    const m = movie({ RunTimeTicks: undefined, UserData: { PlaybackPositionTicks: 5 * MINUTE } });
    const { view, root } = await mount({ item: m });
    await view.renderItem(root, "m1");
    expect($(".detail-actions .btn.primary", root)!.textContent).toBe("Resume");
  });

  it("queues the film from the Up Next menu: Play Next and Play Later", async () => {
    const m = movie();
    const { view, root, playback } = await mount({ item: m });
    await view.renderItem(root, "m1");
    const up = button("Up Next", root);
    up.click();
    expect(menuLabels()).toEqual(["Play Next", "Play Later"]);
    // The dropdown hangs from the button's own wrapper.
    expect(menu().parentElement).toBe(up.parentElement);
    button("Play Next", menu()).click();
    await waitFor(() => toasts().length === 1);
    expect(playback.queueNext).toHaveBeenCalledWith([m]);
    expect($(".menu")).toBeNull();

    up.click();
    button("Play Later", menu()).click();
    await waitFor(() => toasts().length === 2);
    expect(playback.queueLater).toHaveBeenCalledWith([m]);
  });

  it("has no Up Next button for something that cannot be queued", async () => {
    const { view, root } = await mount({ item: movie({ Type: "Folder" }) });
    await view.renderItem(root, "m1");
    expect(hasButton("Up Next", root)).toBe(false);
    expect(hasButton("Quality", root)).toBe(true);
  });

  it("offers the player's own quality ladder, and streams the chosen rung even if the film is downloaded", async () => {
    const m = movie();
    const { view, root, playback } = await mount({ item: m });
    await view.renderItem(root, "m1");
    button("Quality", root).click();
    expect($(".menu-label", menu())!.textContent).toBe("Stream as");
    // One ladder for the page, the in-player menu and the adaptive policy.
    expect(menuLabels()).toEqual(playback.QUALITY_CHOICES.map((q) => q.label));
    const pick = playback.QUALITY_CHOICES.find((q) => q.maxBitrate != null)!;
    button(pick.label, menu()).click();
    expect(playback.playItem).toHaveBeenCalledTimes(1);
    expect(playback.playItem).toHaveBeenCalledWith(m, { resume: true, maxBitrate: pick.maxBitrate }, { stream: true });
    expect($(".menu")).toBeNull();
  });

  it("passes every rung's own bitrate", async () => {
    const m = movie();
    const { view, root, playback } = await mount({ item: m });
    await view.renderItem(root, "m1");
    for (const q of playback.QUALITY_CHOICES) {
      button("Quality", root).click();
      $$<HTMLButtonElement>("button", menu()).find((b) => b.textContent === q.label)!.click();
      expect(playback.playItem).toHaveBeenLastCalledWith(m, { resume: true, maxBitrate: q.maxBitrate }, { stream: true });
    }
  });
});

describe("film page: download", () => {
  it("lists every download quality with its size, and starts the one picked", async () => {
    const m = movie();
    const { view, root, playback, api, ui } = await mount({ item: m });
    await view.renderItem(root, "m1");
    button("Download", $(".detail-actions", root)!).click();
    expect($(".menu-label", menu())!.textContent).toBe("Download as");
    const labels = menuLabels();
    expect(labels).toEqual(api.DOWNLOAD_QUALITIES.map((q) => ui.downloadLabel(m, q)));
    expect(labels[0]).toMatch(/^Original quality · \d/);
    // An estimate, so marked as one.
    expect(labels[labels.length - 1]).toMatch(/^480p · 2 Mbps · ~/);
    const q = api.DOWNLOAD_QUALITIES[api.DOWNLOAD_QUALITIES.length - 1]!;
    button("480p", menu()).click();
    await flush();
    expect(playback.startDownload).toHaveBeenCalledTimes(1);
    expect(playback.startDownload).toHaveBeenCalledWith(m, q);
    expect($(".menu")).toBeNull();
    expect(toasts()).toEqual([]);
  });

  it("says so when the download fails to start", async () => {
    const { view, root, playback } = await mount({ item: movie() });
    (playback.startDownload as Mock).mockRejectedValueOnce(new Error("disk full"));
    await view.renderItem(root, "m1");
    button("Download", $(".detail-actions", root)!).click();
    button("Original quality", menu()).click();
    await waitFor(() => toasts().length > 0);
    expect(toasts()).toEqual(["Download failed to start: disk full"]);
    expect($("#toasts .toast")!.classList.contains("error")).toBe(true);
  });

  it("reports a failure that is not an Error object too", async () => {
    const { view, root, playback } = await mount({ item: movie() });
    (playback.startDownload as Mock).mockRejectedValueOnce("nope");
    await view.renderItem(root, "m1");
    button("Download", $(".detail-actions", root)!).click();
    button("Original quality", menu()).click();
    await waitFor(() => toasts().length > 0);
    expect(toasts()).toEqual(["Download failed to start: nope"]);
  });
});

describe("film page: watched and favourite", () => {
  const userDataCalls = (): string[] =>
    invokeCalls("jf_request")
      .filter((c) => /^\/User(Played|Favorite)Items\//.test(c.args.path))
      .map((c) => `${c.args.method} ${c.args.path}`);

  it("marks watched on the server and flips the button, and back again", async () => {
    const { view, root } = await mount({ item: movie() });
    await view.renderItem(root, "m1");
    const btn = button("Mark watched", root);
    expect(btn.title).toBe("Mark watched");
    btn.click();
    await waitFor(() => btn.textContent === "Watched");
    expect(btn.title).toBe("Mark unwatched");
    expect($("svg", btn)).not.toBeNull();
    expect(userDataCalls()).toEqual(["POST /UserPlayedItems/m1?userId=user-1"]);

    btn.click();
    await waitFor(() => btn.textContent === "Mark watched");
    expect(btn.title).toBe("Mark watched");
    expect(userDataCalls()[1]).toBe("DELETE /UserPlayedItems/m1?userId=user-1");
  });

  it("starts out as Watched for something already watched", async () => {
    const { view, root } = await mount({ item: movie({ UserData: { Played: true } }) });
    await view.renderItem(root, "m1");
    expect(button("Watched", root).title).toBe("Mark unwatched");
  });

  it("works on an item that came without any UserData", async () => {
    const { view, root } = await mount({ item: movie({ UserData: undefined }) });
    await view.renderItem(root, "m1");
    const btn = button("Mark watched", root);
    btn.click();
    await waitFor(() => btn.textContent === "Watched");
  });

  it("leaves the button alone and shows the error when the server refuses", async () => {
    const { view, root } = await mount({ item: movie(), userData: { __status: 500 } });
    await view.renderItem(root, "m1");
    const btn = button("Mark watched", root);
    btn.click();
    await waitFor(() => toasts().length > 0);
    expect(toasts()).toEqual(["Server error 500 on /UserPlayedItems/m1"]);
    expect(btn.textContent).toBe("Mark watched");
    expect(btn.title).toBe("Mark watched");
  });

  it("right-clicking the hero opens the card menu; Add to favorites posts to the server", async () => {
    const { view, root } = await mount({ item: movie() });
    await view.renderItem(root, "m1");
    const hero = $(".detail-hero", root)!;
    expect(hero.classList.contains("has-ctx")).toBe(true);
    rightClick(hero);
    expect($(".menu-label", menu())!.textContent).toBe("Big Film");
    const labels = menuLabels();
    expect(labels).toEqual(expect.arrayContaining(["Play", "Play Next", "Download", "Mark watched", "Add to favorites"]));
    // Already on its own page: no "Show details" entry.
    expect(labels).not.toContain("Show details");
    button("Add to favorites", menu()).click();
    await waitFor(() => toasts().length > 0);
    expect(userDataCalls()).toEqual(["POST /UserFavoriteItems/m1?userId=user-1"]);
    // Asked again, the menu reflects the new state.
    rightClick(hero);
    expect(menuLabels()).toContain("Remove from favorites");
  });

  it("keeps the Watched button in step when the hero's menu marks the film watched", async () => {
    const { view, root } = await mount({ item: movie() });
    await view.renderItem(root, "m1");
    const btn = button("Mark watched", $(".detail-actions", root)!);
    rightClick($(".detail-hero", root)!);
    button("Mark watched", menu()).click();
    await waitFor(() => btn.textContent === "Watched");
    expect(btn.title).toBe("Mark unwatched");
    expect(btn.isConnected).toBe(true);
  });
});

describe("film page: cast and More like this", () => {
  it("lists directors and writers, then actors and guest stars, with the part played or the kind of credit", async () => {
    const { view, root } = await mount({ item: movie() });
    await view.renderItem(root, "m1");
    expect($$(".section h2", root).map((h) => h.textContent)).not.toContain("Cast");
    const cast = $$(".section", root).find((s) => $("h2", s)!.textContent === "Cast & Crew")!;
    expect(cast).toBeDefined();
    const cards = $$(".person-card", cast);
    expect(cards.map((c) => $(".person-name", c)!.textContent)).toEqual(["Dana Director", "Will Writer", "Ann Actor", "Guy Guest & Co"]);
    expect(cards.map((c) => $(".person-role", c)!.textContent)).toEqual(["Director", "Writer", "as Hero", "GuestStar"]);
    expect($<HTMLImageElement>(".person-photo img", cards[2]!)!.getAttribute("src")).toContain(
      "/Items/a1/Images/Primary?maxWidth=240&tag=pa1"
    );
    // No headshot: an icon tile, not a letter.
    expect($(".person-photo .noart svg", cards[3]!)).not.toBeNull();
    expect(cards[2]!.getAttribute("role")).toBe("button");
    expect(cards[2]!.getAttribute("tabindex")).toBe("0");
    expect(cards[2]!.getAttribute("aria-label")).toBe("Ann Actor");
  });

  it("calls the section Cast when there are no directors or writers, and lists a person once per kind of credit", async () => {
    const People = [
      { Id: "a1", Name: "Ann Actor", Type: "Actor", Role: "Hero" },
      { Id: "a1", Name: "Ann Actor", Type: "Actor", Role: "Villain" },
      { Id: "g1", Name: "Guy Guest & Co", Type: "GuestStar" },
      { Id: "p1", Name: "Pat Producer", Type: "Producer" },
    ];
    const { view, root } = await mount({ item: movie({ People }) });
    await view.renderItem(root, "m1");
    const cast = $$(".section", root).find((s) => $("h2", s)!.textContent === "Cast")!;
    expect(cast).toBeDefined();
    expect($$(".person-card", cast).map((c) => $(".person-name", c)!.textContent)).toEqual(["Ann Actor", "Guy Guest & Co"]);
    expect($$(".person-role", cast).map((r) => r.textContent)).toEqual(["as Hero", "GuestStar"]);
  });

  it("shows at most 24 cast members, after at most 6 directors and writers", async () => {
    const People = Array.from({ length: 30 }, (_, i) => ({ Id: `a${i}`, Name: `Actor ${i}`, Type: "Actor" }));
    let { view, root } = await mount({ item: movie({ People }) });
    await view.renderItem(root, "m1");
    expect($$(".person-card", root)).toHaveLength(24);

    vi.resetModules();
    const crew = Array.from({ length: 8 }, (_, i) => ({ Id: `d${i}`, Name: `Director ${i}`, Type: "Director" }));
    ({ view, root } = await mount({ item: movie({ People: [...People, ...crew] }) }));
    await view.renderItem(root, "m1");
    const names = $$(".person-card .person-name", root).map((n) => n.textContent);
    expect(names).toHaveLength(30);
    expect(names.slice(0, 6)).toEqual(crew.slice(0, 6).map((p) => p.Name));
    expect(names[6]).toBe("Actor 0");
  });

  it("has no Cast section when nobody is credited as cast or crew; a director alone makes it Cast & Crew", async () => {
    let { view, root } = await mount({ item: movie({ People: [{ Name: "P", Type: "Producer" }] }) });
    await view.renderItem(root, "m1");
    expect($$(".section h2", root).map((h) => h.textContent).filter((t) => /Cast/.test(t ?? ""))).toEqual([]);
    expect($$(".person-card", root)).toHaveLength(0);

    vi.resetModules();
    ({ view, root } = await mount({ item: movie({ People: [{ Name: "D", Type: "Director" }] }) }));
    await view.renderItem(root, "m1");
    expect($$(".section h2", root).map((h) => h.textContent).filter((t) => /Cast/.test(t ?? ""))).toEqual(["Cast & Crew"]);
    expect($$(".person-card .person-name", root).map((n) => n.textContent)).toEqual(["D"]);
  });

  it("a cast member opens their own page, by click, Enter or Space; a credit with no id searches the name", async () => {
    const People = [
      { Id: "a1", Name: "Ann Actor", Type: "Actor", Role: "Hero" },
      { Id: "g1", Name: "Guy Guest & Co", Type: "GuestStar" },
      { Name: "Nora No-Id & Co", Type: "Actor" },
    ];
    const { view, root } = await mount({ item: movie({ People }) });
    await view.renderItem(root, "m1");
    const [ann, guy, nora] = $$(".person-card", root);
    ann!.click();
    expect(location.hash).toBe("#/person/a1");

    const enter = key(guy!, "Enter");
    expect(location.hash).toBe("#/person/g1");
    expect(enter.defaultPrevented).toBe(true);

    location.hash = "";
    const space = key(ann!, " ");
    expect(location.hash).toBe("#/person/a1");
    expect(space.defaultPrevented).toBe(true);

    nora!.click();
    expect(location.hash).toBe("#/search/Nora%20No-Id%20%26%20Co");

    location.hash = "";
    const other = key(ann!, "a");
    expect(location.hash).toBe("");
    expect(other.defaultPrevented).toBe(false);
  });

  it("shows placeholder cards for More like this until the recommendations land", async () => {
    const gate = deferred();
    const { view, root } = await mount({ item: movie(), similar: () => gate.promise });
    await view.renderItem(root, "m1");
    const more = (): HTMLElement | undefined =>
      $$(".section", root).find((s) => $("h2", s)!.textContent === "More like this");
    expect($$(".card.skeleton", more()!)).toHaveLength(7);
    gate.resolve([movie({ Id: "m2", Name: "Other Film" }), { Id: "a9", Type: "Audio", MediaType: "Audio", Name: "A Song" }]);
    await waitFor(() => $$(".card.skeleton", root).length === 0);
    // The recommendation list is for watching: the song is not offered.
    expect($$(".card", more()!).map((c) => $(".card-title", c)!.textContent)).toEqual(["Other Film"]);
    expect(similarRequests()[0]).toMatch(/^\/Items\/m1\/Similar\?userId=user-1&limit=12/);
  });

  it("removes the More like this section when there is nothing to recommend", async () => {
    const { view, root } = await mount({ item: movie(), similar: [] });
    await view.renderItem(root, "m1");
    await waitFor(() => !$$(".section h2", root).some((h) => h.textContent === "More like this"));
    expect($(".card.skeleton", root)).toBeNull();
  });

  it("removes the More like this section when the request fails", async () => {
    const { view, root } = await mount({ item: movie(), similar: { __status: 500 } });
    await view.renderItem(root, "m1");
    await waitFor(() => !$$(".section h2", root).some((h) => h.textContent === "More like this"));
    expect($(".state-error", root)).toBeNull();
  });

  it("drops recommendations that arrive after the page has been replaced", async () => {
    const gate = deferred();
    const { view, root } = await mount({ item: movie(), similar: () => gate.promise });
    await view.renderItem(root, "m1");
    root.textContent = "";
    const other = document.createElement("section");
    root.append(other);
    gate.resolve([movie({ Id: "m2", Name: "Other Film" })]);
    await flush(30);
    expect(root.children).toHaveLength(1);
    expect(root.firstElementChild).toBe(other);
    expect($(".card")).toBeNull();
  });
});

describe("episode page", () => {
  const ep = (extra: Record<string, any> = {}): any =>
    episode(2, 4, {
      Id: "ep1",
      Name: "The One With Tests",
      ParentBackdropItemId: "s1",
      ParentBackdropImageTags: ["sb9"],
      ParentLogoItemId: "s1",
      ParentLogoImageTag: "sl9",
      MediaSources: [{ Size: 1_000_000_000 }],
      ...extra,
    });

  it("names the series, season and episode under the title", async () => {
    const { view, root } = await mount({ item: ep() });
    await view.renderItem(root, "ep1");
    expect($(".detail-meta.clickable", root)!.textContent).toBe("The Show · Season 2, Episode 4");
  });

  it("leaves out the numbering it does not have", async () => {
    const { view, root } = await mount({ item: ep({ ParentIndexNumber: undefined, IndexNumber: undefined }) });
    await view.renderItem(root, "ep1");
    expect($(".detail-meta.clickable", root)!.textContent).toBe("The Show");
  });

  it("the series line opens the series, by click and from the keyboard (regression: a963a95)", async () => {
    const { view, root } = await mount({ item: ep() });
    await view.renderItem(root, "ep1");
    const line = $(".detail-meta.clickable", root)!;
    expect(line.getAttribute("role")).toBe("button");
    expect(line.getAttribute("tabindex")).toBe("0");
    line.click();
    expect(location.hash).toBe("#/item/s1");
    location.hash = "";
    key(line, "Enter");
    expect(location.hash).toBe("#/item/s1");
    location.hash = "";
    key(line, " ");
    expect(location.hash).toBe("#/item/s1");
  });

  it("an episode with no series to open is not offered as a button and goes nowhere", async () => {
    location.hash = "#/item/ep1";
    const { view, root } = await mount({ item: ep({ SeriesId: undefined }) });
    await view.renderItem(root, "ep1");
    const line = $(".detail-meta.clickable", root)!;
    expect(line.hasAttribute("role")).toBe(false);
    expect(line.hasAttribute("tabindex")).toBe(false);
    line.click();
    expect(location.hash).toBe("#/item/ep1");
  });

  it("sets the episode's own name in type, not the series' logo art", async () => {
    const { view, root } = await mount({ item: ep() });
    await view.renderItem(root, "ep1");
    const h1 = $("h1.detail-title", root)!;
    expect(h1.textContent).toBe("The One With Tests");
    expect($("img", h1)).toBeNull();
  });

  it("borrows the series' backdrop when the episode has none of its own", async () => {
    const { view, root } = await mount({ item: ep() });
    await view.renderItem(root, "ep1");
    // The layer only takes its image once it has loaded, which jsdom never
    // does; that the layer exists says a backdrop URL was found.
    expect($(".detail-backdrop", root)).not.toBeNull();
  });

  it("has no backdrop layer when neither the episode nor its series has one", async () => {
    const { view, root } = await mount({
      item: ep({ ParentBackdropItemId: undefined, ParentBackdropImageTags: undefined }),
    });
    await view.renderItem(root, "ep1");
    expect($(".detail-backdrop", root)).toBeNull();
  });

  it("gets the same play, queue, quality, download and watched bar as a film, and offers Go to series", async () => {
    const e = ep();
    const { view, root, playback } = await mount({ item: e });
    await view.renderItem(root, "ep1");
    const actions = $(".detail-actions", root)!;
    for (const label of ["Play", "Up Next", "Quality", "Download", "Mark watched"]) {
      expect(hasButton(label, actions)).toBe(true);
    }
    // "Add to Next Up…" on the bar is the series page's button.
    expect(hasButton("Add to Next Up", actions)).toBe(false);
    $<HTMLButtonElement>(".btn.primary", actions)!.click();
    expect(playback.playItem).toHaveBeenCalledWith(e, { resume: false });
    rightClick($(".detail-hero", root)!);
    button("Go to series", menu()).click();
    expect(location.hash).toBe("#/item/s1");
  });
});

describe("cache-first paint (invariant: paint from the cache, repaint only on change)", () => {
  it("paints a cached page at once, with no skeleton, before the server has answered", async () => {
    const gate = deferred();
    const { view, root, cache } = await mount({ item: () => gate.promise });
    cache.setCached("item:m1", { item: movie(), seasons: [], playTarget: null });
    const done = view.renderItem(root, "m1");
    expect($(".skeleton.detail-hero", root)).toBeNull();
    expect($(".detail-title .title-text", root)!.textContent).toBe("Big Film");
    expect(hasButton("Play", root)).toBe(true);
    gate.resolve(movie());
    await done;
  });

  it("still asks the server behind a cached page", async () => {
    const { view, root, cache } = await mount({ item: movie() });
    cache.setCached("item:m1", { item: movie(), seasons: [], playTarget: null });
    await view.renderItem(root, "m1");
    expect(itemRequests()).toHaveLength(1);
  });

  it("does not rebuild the page when the server returns what the cache already had", async () => {
    const { view, root, cache } = await mount({ item: movie({ Overview: "Fresh words, same state." }) });
    cache.setCached("item:m1", { item: movie(), seasons: [], playTarget: null });
    const done = view.renderItem(root, "m1");
    const hero = $(".detail-hero", root)!;
    const playBtn = $(".detail-actions .btn.primary", root)!;
    await done;
    await flush(30);
    expect($(".detail-hero", root)).toBe(hero);
    expect($(".detail-actions .btn.primary", root)).toBe(playBtn);
    // One paint means one "More like this" request.
    expect(similarRequests()).toHaveLength(1);
  });

  it("rebuilds the page when the resume position changed since the cache was written", async () => {
    const { view, root, cache } = await mount({ item: movie({ UserData: { PlaybackPositionTicks: HOUR } }) });
    cache.setCached("item:m1", { item: movie(), seasons: [], playTarget: null });
    const done = view.renderItem(root, "m1");
    const hero = $(".detail-hero", root)!;
    expect($(".detail-actions .btn.primary", root)!.textContent).toBe("Play");
    await done;
    expect($(".detail-hero", root)).not.toBe(hero);
    expect(hero.isConnected).toBe(false);
    expect($$(".detail-hero", root)).toHaveLength(1);
    expect($(".detail-actions .btn.primary", root)!.textContent).toBe("Resume (1h 0m left)");
  });

  it.each([
    ["watched state", { UserData: { Played: true } }],
    ["favourite", { UserData: { IsFavorite: true } }],
    ["poster", { ImageTags: { Primary: "p2" } }],
  ])("rebuilds the page when the %s changed", async (_what, change) => {
    const { view, root, cache } = await mount({ item: movie(change) });
    cache.setCached("item:m1", { item: movie(), seasons: [], playTarget: null });
    const done = view.renderItem(root, "m1");
    const hero = $(".detail-hero", root)!;
    await done;
    expect($(".detail-hero", root)).not.toBe(hero);
  });

  it("writes the fresh answer back to the cache either way", async () => {
    const fresh = movie({ Overview: "Fresh words, same state." });
    const { view, root, cache } = await mount({ item: fresh });
    cache.setCached("item:m1", { item: movie(), seasons: [], playTarget: null });
    await view.renderItem(root, "m1");
    expect(cache.getCached<any>("item:m1").item.Overview).toBe("Fresh words, same state.");
  });

  it("paints from the cache a second visit, after the first visit filled it", async () => {
    const gate = deferred();
    let first = true;
    const { view, root } = await mount({ item: () => (first ? movie() : gate.promise) });
    await view.renderItem(root, "m1");
    first = false;
    const done = view.renderItem(root, "m1");
    expect($(".detail-title .title-text", root)!.textContent).toBe("Big Film");
    expect($(".detail-hero.skeleton", root)).toBeNull();
    gate.resolve(movie());
    await done;
  });

  it("keeps showing the cached page, without an error, when the refresh fails", async () => {
    const { view, root, cache } = await mount({ item: { __status: 500 } });
    cache.setCached("item:m1", { item: movie(), seasons: [], playTarget: null });
    await view.renderItem(root, "m1");
    expect($(".state-error", root)).toBeNull();
    expect($(".detail-title .title-text", root)!.textContent).toBe("Big Film");
  });
});

describe("load failure", () => {
  it("shows an error with the reason and a Try again that loads the page", async () => {
    let fail = true;
    const { view, root } = await mount({ item: () => (fail ? { __status: 500 } : movie()) });
    await view.renderItem(root, "m1");
    const state = $(".state.state-error", root)!;
    expect($("h3", state)!.textContent).toBe("This page didn't load");
    expect($("p", state)!.textContent).toBe("Server error 500 on /Items/m1");
    expect($(".skeleton", root)).toBeNull();

    fail = false;
    button("Try again", state).click();
    await waitFor(() => !!$(".detail-title", root));
    expect($(".state-error", root)).toBeNull();
    expect(root.children).toHaveLength(1);
  });
});

describe("stale-page guards (a response that arrives after the user moved on must not paint)", () => {
  it("does not paint an item that arrives after the root was given to another page", async () => {
    const gate = deferred();
    const { view, root } = await mount({ item: () => gate.promise });
    const done = view.renderItem(root, "m1");
    // What the router does on navigation: empty the root, hand it on.
    root.textContent = "";
    const other = document.createElement("section");
    root.append(other);
    gate.resolve(movie());
    await done;
    await flush(30);
    expect(root.children).toHaveLength(1);
    expect(root.firstElementChild).toBe(other);
    expect($(".detail-hero")).toBeNull();
    // Painting would have asked for recommendations.
    expect(similarRequests()).toHaveLength(0);
  });

  it("does not put an error on the next page when the load fails after the user moved on", async () => {
    const gate = deferred();
    const { view, root } = await mount({ item: () => gate.promise });
    const done = view.renderItem(root, "m1");
    root.textContent = "";
    const other = document.createElement("section");
    root.append(other);
    gate.resolve({ __status: 500 });
    await done;
    expect(root.children).toHaveLength(1);
    expect($(".state-error")).toBeNull();
  });

  it("the first of two renders into the same root does not overwrite the second", async () => {
    const gates: Record<string, ReturnType<typeof deferred>> = { m1: deferred(), m2: deferred() };
    const { view, root } = await mount({ item: (a: any) => gates[/Items\/([^?]+)/.exec(a.path)![1]!]!.promise });
    const first = view.renderItem(root, "m1");
    const second = view.renderItem(root, "m2");
    gates.m2!.resolve(movie({ Id: "m2", Name: "Second Film" }));
    await second;
    gates.m1!.resolve(movie({ Id: "m1", Name: "First Film" }));
    await first;
    await flush(30);
    expect($$(".detail-title .title-text", root).map((t) => t.textContent)).toEqual(["Second Film"]);
    expect(similarRequests()).toEqual([expect.stringContaining("/Items/m2/Similar")]);
  });
});

describe("backdrop parallax", () => {
  const scrollTo = (y: number): void => {
    const content = document.getElementById("content")!;
    Object.defineProperty(content, "scrollTop", { value: y, configurable: true });
    content.dispatchEvent(new Event("scroll"));
  };

  it("moves the backdrop at 0.4 of the scroll, and no further than the hero is tall", async () => {
    const { view, root } = await mount({ item: movie() });
    await view.renderItem(root, "m1");
    const layer = $(".detail-backdrop", root)!;
    expect(layer.style.transform).toBe("translate3d(0, 0.0px, 0)");
    scrollTo(100);
    expect(layer.style.transform).toBe("translate3d(0, 40.0px, 0)");
    scrollTo(5000);
    expect(layer.style.transform).toBe("translate3d(0, 104.0px, 0)");
  });

  it("stops listening once its hero has left the page", async () => {
    const { view, root } = await mount({ item: movie() });
    await view.renderItem(root, "m1");
    const layer = $(".detail-backdrop", root)!;
    scrollTo(100);
    const content = document.getElementById("content")!;
    const removed = vi.spyOn(content, "removeEventListener");
    root.textContent = "";
    scrollTo(200);
    expect(layer.style.transform).toBe("translate3d(0, 40.0px, 0)");
    expect(removed).toHaveBeenCalledWith("scroll", expect.any(Function));
    scrollTo(250);
    expect(layer.style.transform).toBe("translate3d(0, 40.0px, 0)");
  });

  it("holds the backdrop still when the desktop asks for reduced motion", async () => {
    const { view, root } = await mount({ item: movie() });
    vi.spyOn(window, "matchMedia").mockImplementation(
      (q: string) => ({ matches: q.includes("prefers-reduced-motion"), media: q }) as any
    );
    await view.renderItem(root, "m1");
    const layer = $(".detail-backdrop", root)!;
    scrollTo(100);
    expect(layer.style.transform).toBe("");
    vi.restoreAllMocks();
  });

  it("does nothing on a page with no backdrop, or outside the app shell's scroller", async () => {
    const { view, root } = await mount({ item: movie({ BackdropImageTags: [] }) });
    await view.renderItem(root, "m1");
    expect($(".detail-backdrop", root)).toBeNull();
    scrollTo(100); // nothing listening, nothing thrown

    // No #content at all: the page still renders.
    vi.resetModules();
    const again = await mount({ item: movie() });
    const loose = document.createElement("div");
    document.body.replaceChildren(document.getElementById("toasts")!, loose);
    await again.view.renderItem(loose, "m1");
    expect($(".detail-backdrop", loose)!.style.transform).toBe("");
  });
});
