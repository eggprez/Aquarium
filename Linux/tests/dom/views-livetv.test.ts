// Live TV (src/views/livetv.ts): the guide (window, ruler, lanes, the
// keyboard selection, filtering, moving in time), the plain channel list for a
// source with no guide, the tuning screen, and Home's On Now cards. Real api /
// iptv / lineup / cache / ui under the mocked Tauri bridge; the two calls that
// would start libmpv (playItem, playChannelUrl) and getNowPlaying are spies.
//
// Time is frozen: the guide is laid out against Date.now(), so every test runs
// at 20:10 local time on 1 June 2026 unless it moves the clock itself.
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { emitEvent, flush, invokeCalls, jfPaths, listenerCount, mockJellyfin, onInvoke, signIn, type JfArgs } from "../helpers/tauri";
import { byText, click, dialogButtons, dialogEl, dialogTitle, key, mountShell, pickDialog, texts } from "../helpers/views-media";
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

type LiveTv = typeof import("../../src/views/livetv");

const NOW = new Date(2026, 5, 1, 20, 10, 0).getTime();
const SLOT = 30 * 60_000;
const H = 60 * 60_000;
const START = Math.floor(NOW / SLOT) * SLOT; // 20:00

let tv: LiveTv;
let playback: any;
let cache: typeof import("../../src/cache");
let root: HTMLElement;
let channels: any;
let programs: (q: URLSearchParams) => any;
let docListeners: [string, any][];

beforeEach(() => {
  vi.resetModules();
  vi.clearAllMocks();
  vi.useFakeTimers({ toFake: ["setInterval", "clearInterval", "Date"] });
  vi.setSystemTime(NOW);
  channels = [ch("c1", "Alpha", "1"), ch("c2", "Beta", "2"), ch("c3", "Gamma", "3")];
  programs = () => ({ Items: defaultPrograms() });
  docListeners = [];
});
afterEach(() => {
  // A dialog left open keeps a capturing Escape handler on the document.
  while (document.querySelector(".dialog-scrim")) key(document, "Escape");
  for (const [t, fn] of docListeners) document.removeEventListener(t, fn);
  document.body.classList.remove("video-covered");
  location.hash = "";
});

function ch(id: string, name: string, num?: string, extra: any = {}): any {
  return { Id: id, Name: name, ChannelNumber: num, Type: "TvChannel", ImageTags: {}, ...extra };
}
function prog(id: string, chId: string, startMs: number, endMs: number, extra: any = {}): any {
  return { Id: id, ChannelId: chId, Name: `Show ${id}`, StartDate: new Date(startMs).toISOString(), EndDate: new Date(endMs).toISOString(), ...extra };
}
/** Alpha: 19:30–20:30, 20:30–21:30, 21:30–03:00. Beta: 20:00–22:00. Gamma: nothing. */
function defaultPrograms(): any[] {
  return [
    prog("a2", "c1", START + SLOT, START + 3 * SLOT),
    prog("a1", "c1", START - SLOT, START + SLOT, { EpisodeTitle: "Pilot" }),
    prog("a3", "c1", START + 3 * SLOT, START + 7 * H),
    prog("b1", "c2", START, START + 2 * H),
    prog("bad", "c2", START + H, START + H),
  ];
}

async function boot(cfg: Record<string, any> = {}): Promise<void> {
  root = mountShell();
  mockJellyfin([
    [/^\/LiveTv\/Channels\?/, () => (Array.isArray(channels) ? { Items: channels } : channels)],
    [/^\/LiveTv\/Programs\?/, (a: JfArgs) => programs(new URLSearchParams(a.path.split("?")[1]))],
  ]);
  await signIn(cfg);
  playback = await import("../../src/playback");
  cache = await import("../../src/cache");
  tv = await import("../../src/views/livetv");
}

/** Render, keeping track of the document listeners the guide adds. */
async function open(): Promise<void> {
  const add = document.addEventListener.bind(document);
  const spy = vi.spyOn(document, "addEventListener").mockImplementation((t: any, fn: any, o?: any) => {
    docListeners.push([t, fn]);
    add(t, fn, o);
  });
  try {
    await tv.renderLiveTv(root);
    await flush(40);
  } finally {
    spy.mockRestore();
  }
}

const grid = () => root.querySelector<HTMLElement>(".guide-scroll")!;
const rowNames = () => texts(root, ".guide-row .guide-ch-name");
const selectedTitle = () => root.querySelector(".guide-prog.selected .guide-prog-title")?.textContent ?? null;
const selectedChannel = () => root.querySelector(".guide-ch.selected .guide-ch-name")?.textContent ?? null;
const toolbarBtn = (label: string) =>
  Array.from(root.querySelectorAll<HTMLButtonElement>(".guide-toolbar button")).find(
    (b) => b.getAttribute("aria-label") === label || b.textContent!.trim() === label
  )!;
const range = () => root.querySelector(".guide-range")!.textContent;

describe("dayLabel", () => {
  it("says Today, Tomorrow and Yesterday, and the date otherwise", async () => {
    await boot();
    expect(tv.dayLabel(new Date(NOW))).toBe("Today");
    expect(tv.dayLabel(new Date(NOW + 24 * H))).toBe("Tomorrow");
    expect(tv.dayLabel(new Date(NOW - 24 * H))).toBe("Yesterday");
    const later = new Date(NOW + 3 * 24 * H);
    expect(tv.dayLabel(later)).toBe(later.toLocaleDateString([], { weekday: "short", day: "numeric", month: "short" }));
  });
});

describe("loading the line-up", () => {
  it("shows a skeleton until the channels arrive", async () => {
    await boot();
    const p = tv.renderLiveTv(root);
    expect(root.querySelector("h1.page-title")!.textContent).toBe("Live TV");
    expect(root.querySelector(".channel-row")).not.toBeNull();
    await p;
    expect(root.querySelector(".guide")).not.toBeNull();
    expect(cache.getCached<any[]>("livetv:jellyfin")!.map((c) => c.Id)).toEqual(["c1", "c2", "c3"]);
    expect(jfPaths().every((p) => /userId=user-1/.test(p))).toBe(true);
  });

  it("says when the server has a Live TV library but no channels, with Reload", async () => {
    channels = [];
    await boot();
    await open();
    expect(root.querySelector(".state h3")!.textContent).toBe("No Live TV channels");
    expect(root.querySelector(".state p")!.textContent).toMatch(/Jellyfin dashboard/);
    channels = [ch("c1", "Alpha")];
    click(byText(root, ".state button", "Reload"));
    await flush(40);
    expect(rowNames()).toEqual(["Alpha"]);
  });

  it("shows why it couldn't load, with Try again", async () => {
    channels = { __status: 500 };
    await boot();
    await open();
    expect(root.querySelector(".state h3")!.textContent).toBe("Couldn't load Live TV");
    expect(root.querySelector(".state p")!.textContent).toMatch(/Server error 500/);
    channels = [ch("c1", "Alpha")];
    click(byText(root, ".state button", "Try again"));
    await flush(40);
    expect(rowNames()).toEqual(["Alpha"]);
  });

  it("paints the cached line-up at once and keeps it when the reload fails", async () => {
    await boot();
    cache.setCached("livetv:jellyfin", channels);
    channels = { __status: 500 };
    const p = tv.renderLiveTv(root);
    expect(root.querySelector(".guide")).not.toBeNull();
    await p;
    await flush(40);
    expect(root.querySelector(".state h3")?.textContent).not.toBe("Couldn't load Live TV");
    expect(rowNames()).toEqual(["Alpha", "Beta", "Gamma"]);
  });

  it("keeps the cached guide when the line-up came back the same, and redraws when it changed", async () => {
    await boot();
    cache.setCached("livetv:jellyfin", channels);
    await open();
    const guide = root.querySelector(".guide");
    await tv.renderLiveTv(root);
    await flush(40);
    expect(root.querySelector(".guide")).not.toBe(guide); // a fresh visit builds its own page
    const same = root.querySelector(".guide");
    channels = [ch("c1", "Alpha"), ch("c9", "New")];
    await tv.renderLiveTv(root);
    await flush(40);
    expect(rowNames()).toEqual(["Alpha", "New"]);
    expect(root.querySelectorAll(".guide")).toHaveLength(1);
    expect(same).not.toBe(root.querySelector(".guide"));
  });

  it("stops if the page moved on while the line-up loaded", async () => {
    let release!: (v: any) => void;
    channels = new Promise((r) => (release = r));
    await boot();
    const p = tv.renderLiveTv(root);
    root.textContent = "";
    release({ Items: [ch("c1", "Alpha")] });
    await p;
    expect(root.children).toHaveLength(0);
  });

  it("redraws when the line-up is read again while the page is showing, and not after", async () => {
    await boot();
    await open();
    channels = [ch("c5", "Fresh")];
    document.dispatchEvent(new CustomEvent("aquarium-lineup-changed"));
    await flush(60);
    expect(rowNames()).toEqual(["Fresh"]);
    root.textContent = "";
    channels = [ch("c6", "Later")];
    document.dispatchEvent(new CustomEvent("aquarium-lineup-changed"));
    await flush(60);
    expect(root.children).toHaveLength(0);
  });
});

describe("a custom M3U source", () => {
  const cfg = { livetv_source: "custom", livetv_m3u: "http://lists.test/tv.m3u" };

  it("lists the playlist's channels with the custom note when there is no XMLTV guide, and plays them by URL", async () => {
    await boot(cfg);
    onInvoke("fetch_source", () => '#EXTM3U\n#EXTINF:-1 tvg-chno="7",Seven\nhttp://s.test/7.ts\n');
    await open();
    expect(root.querySelector(".guide-note")!.textContent).toMatch(/No XMLTV guide is set/);
    expect(texts(root, ".channel-row h4")).toEqual(["7 · Seven"]);
    expect(root.querySelector(".channel-row p")!.textContent).toBe("No guide data");
    click(byText(root, ".channel-row button", "Watch"));
    await flush(20);
    expect(playback.playChannelUrl).toHaveBeenCalledWith(expect.objectContaining({ Name: "Seven" }), { quiet: true, continuation: undefined });
    expect(jfPaths()).toEqual([]);
  });

  it("says the playlist couldn't be loaded, and why", async () => {
    await boot(cfg);
    onInvoke("fetch_source", () => {
      throw new Error("host not found");
    });
    await open();
    expect(root.querySelector(".state h3")!.textContent).toBe("Couldn't load your playlist");
    expect(root.querySelector(".state p")!.textContent).toBe("host not found");
  });

  it("says an empty playlist has no channels in it", async () => {
    await boot(cfg);
    onInvoke("fetch_source", () => "#EXTM3U\n");
    await open();
    expect(root.querySelector(".state p")!.textContent).toBe("That playlist has no channels in it");
  });
});

describe("no guide data", () => {
  it("falls back to the plain channel list with what's on from the line-up", async () => {
    programs = () => ({ Items: [] });
    channels = [ch("c1", "Alpha", "1", { CurrentProgram: { Name: "News", EpisodeTitle: "Late" } }), ch("c2", undefined as any)];
    await boot();
    await open();
    expect(root.querySelector(".guide-note")!.textContent).toMatch(/no guide data/);
    expect(texts(root, ".channel-row h4")).toEqual(["1 · Alpha", "Channel"]);
    expect(texts(root, ".channel-row p")).toEqual(["News — Late", "No guide data"]);
    expect(root.querySelector(".guide")).toBeNull();
  });
});

describe("the guide", () => {
  it("draws a six-hour ruler from the half hour, marking midnight with the day", async () => {
    await boot();
    await open();
    const ticks = Array.from(root.querySelectorAll<HTMLElement>(".guide-tick"));
    expect(ticks).toHaveLength(12);
    expect(ticks[0]!.style.left).toBe("0px");
    expect(ticks[1]!.style.left).toBe("150px");
    expect(ticks[0]!.style.width).toBe("150px");
    const midnight = ticks.filter((t) => t.classList.contains("day"));
    expect(midnight).toHaveLength(1);
    expect(midnight[0]!.textContent).toMatch(/^Tomorrow /);
    expect(range()).toMatch(/^Today · .+ – Tomorrow .+$/);
    expect(root.querySelector<HTMLElement>(".guide-body")!.style.getPropertyValue("--lane-w")).toBe("1800px");
    expect(toolbarBtn("Now").disabled).toBe(true);
    expect(toolbarBtn("Earlier").disabled).toBe(false);
    expect(root.querySelector(".guide")!.classList.contains("busy")).toBe(false);
  });

  it("asks for the window's programmes for every channel, in batches of eighty", async () => {
    const seen: URLSearchParams[] = [];
    programs = (q) => (seen.push(q), { Items: defaultPrograms() });
    channels = Array.from({ length: 81 }, (_, i) => ch(`k${i}`, `K${i}`));
    await boot();
    await open();
    expect(seen).toHaveLength(2);
    expect(seen[0]!.get("channelIds")!.split(",")).toHaveLength(80);
    expect(seen[0]!.get("minEndDate")).toBe(new Date(START).toISOString());
    expect(seen[0]!.get("maxStartDate")).toBe(new Date(START + 6 * H).toISOString());
  });

  it("lays each programme on its lane by time, clipped to the window, marking what's on now", async () => {
    await boot();
    await open();
    expect(rowNames()).toEqual(["Alpha", "Beta", "Gamma"]);
    const alpha = root.querySelectorAll(".guide-lane")[0]!;
    const blocks = Array.from(alpha.querySelectorAll<HTMLElement>(".guide-prog"));
    expect(blocks.map((b) => b.querySelector(".guide-prog-title")!.textContent)).toEqual(["Show a1", "Show a2", "Show a3"]);
    // a1 began before the window: it starts at the left edge.
    expect(blocks.map((b) => [b.style.left, b.style.width])).toEqual([["0px", "150px"], ["150px", "300px"], ["450px", "1350px"]]);
    expect(blocks[0]!.querySelector(".guide-prog-sub")!.textContent).toMatch(/ · Pilot$/);
    expect(blocks.map((b) => b.classList.contains("on-now"))).toEqual([true, false, false]);
    // A programme with no length isn't drawn.
    expect(root.querySelectorAll(".guide-lane")[1]!.querySelectorAll(".guide-prog")).toHaveLength(1);
    expect(root.querySelectorAll(".guide-lane")[2]!.querySelector(".guide-gap")!.textContent).toBe("No guide data");
    expect(root.querySelector<HTMLElement>(".guide-now")!.style.left).toBe("50px");
  });

  it("opens a programme's details on click, and watches from there", async () => {
    programs = () => ({
      Items: [prog("x", "c1", START, START + H, { IsLive: true, IsNew: true, IsRepeat: true, OfficialRating: "TV-PG", EpisodeTitle: "Ep", Overview: "Story." }), prog("y", "c2", START, START + H, { Name: undefined })],
    });
    await boot();
    await open();
    click(root.querySelector(".guide-prog"));
    expect(selectedTitle()).toBe("Show x");
    expect(dialogTitle()).toBe("Show x");
    expect(dialogEl()!.querySelector(".guide-dlg-when")!.textContent).toMatch(/ · 1 · Alpha$/);
    expect(dialogEl()!.querySelector(".guide-dlg-ep")!.textContent).toBe("Ep");
    expect(texts(dialogEl()!, ".guide-badge")).toEqual(["Live", "New", "Repeat", "TV-PG"]);
    expect(dialogButtons()).toEqual(["Close", "Watch Alpha"]);
    await pickDialog("Watch Alpha");
    expect(document.querySelector("#main .tuning")).not.toBeNull();
    click(root.querySelectorAll(".guide-prog")[1]!);
    expect(dialogTitle()).toBe("Programme");
    expect(dialogEl()!.querySelector("p:last-of-type")!.textContent).toBe("No description for this programme.");
    expect(dialogEl()!.querySelector(".guide-dlg-badges")).toBeNull();
  });

  it("tunes from a channel's cell, and hands the keyboard back to the grid after a click", async () => {
    await boot();
    await open();
    click(root.querySelector(".guide-ch"));
    expect(document.querySelector("#main .tuning .tuning-name")!.textContent).toBe("1 · Alpha");
    expect(document.activeElement).toBe(grid());
  });

  it("filters the channels by number, name or group, and says when none match", async () => {
    channels = [ch("c1", "Alpha", "1"), ch("c2", "Beta", "22", { Group: "Sports" })];
    await boot();
    await open();
    const f = root.querySelector<HTMLInputElement>(".guide-filter")!;
    f.value = "sport";
    f.dispatchEvent(new Event("input"));
    expect(rowNames()).toEqual(["Beta"]);
    f.value = "22";
    f.dispatchEvent(new Event("input"));
    expect(rowNames()).toEqual(["Beta"]);
    f.value = "zzz";
    f.dispatchEvent(new Event("input"));
    expect(root.querySelector(".guide-empty")!.textContent).toBe("No channels match “zzz”.");
    // Escape in the field clears it; with nothing in it Escape is left alone.
    expect(key(f, "Escape").defaultPrevented).toBe(true);
    expect(f.value).toBe("");
    expect(rowNames()).toEqual(["Alpha", "Beta"]);
    expect(key(f, "Escape").defaultPrevented).toBe(false);
    key(f, "a");
    // Down goes into the grid, selecting what's on now on the first row.
    expect(key(f, "ArrowDown").defaultPrevented).toBe(true);
    expect(document.activeElement).toBe(grid());
    expect(selectedTitle()).toBe("Show a1");
    // Enter does the same, keeping a selection already made.
    key(grid(), "ArrowDown");
    key(f, "Enter");
    expect(selectedChannel()).toBe("Beta");
  });
});

describe("keyboard selection", () => {
  it("walks programmes with the arrows, keeping the time when moving between rows", async () => {
    await boot();
    await open();
    key(grid(), "ArrowDown");
    expect(selectedChannel()).toBe("Alpha");
    expect(selectedTitle()).toBe("Show a1");
    expect(grid().getAttribute("aria-label")).toMatch(/^1 · Alpha: Show a1, /);
    key(grid(), "ArrowRight");
    expect(selectedTitle()).toBe("Show a2");
    key(grid(), "ArrowDown");
    expect(selectedChannel()).toBe("Beta");
    expect(selectedTitle()).toBe("Show b1");
    // An empty lane selects the lane itself.
    key(grid(), "ArrowDown");
    expect(selectedChannel()).toBe("Gamma");
    expect(root.querySelector(".guide-lane.selected")).not.toBeNull();
    expect(selectedTitle()).toBeNull();
    key(grid(), "ArrowDown");
    expect(selectedChannel()).toBe("Gamma");
    key(grid(), "Home");
    expect(selectedChannel()).toBe("Alpha");
    key(grid(), "End");
    expect(selectedChannel()).toBe("Gamma");
    key(grid(), "PageUp");
    expect(selectedChannel()).toBe("Alpha");
    key(grid(), "PageDown");
    expect(selectedChannel()).toBe("Gamma");
    key(grid(), "ArrowUp");
    expect(selectedChannel()).toBe("Beta");
    // Left from the first programme of a lane already at the window's start moves the window back.
    key(grid(), "ArrowLeft");
    await flush(40);
    expect(range()).toMatch(/^Today · /);
    expect(toolbarBtn("Now").disabled).toBe(false);
  });

  it("goes on past the window's end by moving it, landing on the next programme (regression: bc28e10 the selection keeps its row when the window moves)", async () => {
    await boot();
    await open();
    key(grid(), "ArrowDown");
    key(grid(), "ArrowDown");
    expect(selectedChannel()).toBe("Beta");
    key(grid(), "ArrowRight");
    await flush(40);
    expect(selectedChannel()).toBe("Beta");
    expect(toolbarBtn("Now").disabled).toBe(false);
    // From Alpha's long last show, right moves the window two hours on.
    key(grid(), "Home");
    key(grid(), "ArrowRight");
    key(grid(), "ArrowRight");
    expect(selectedTitle()).toBe("Show a3");
    key(grid(), "ArrowRight");
    await flush(40);
    expect(selectedChannel()).toBe("Alpha");
  });

  it("won't go back past the twelve hours a server keeps", async () => {
    programs = () => ({ Items: [] });
    channels = [ch("c1", "Alpha")];
    await boot();
    programs = () => ({ Items: [prog("old", "c1", START - 24 * H, START + 24 * H)] });
    await open();
    for (let i = 0; i < 6; i++) {
      click(toolbarBtn("Earlier"));
      await flush(40);
    }
    expect(toolbarBtn("Earlier").disabled).toBe(true);
    const before = range();
    key(grid(), "ArrowDown");
    key(grid(), "ArrowLeft");
    await flush(40);
    expect(range()).toBe(before);
  });

  it("Enter watches the selected channel, Space opens the programme, Escape lets go", async () => {
    await boot();
    await open();
    expect(key(grid(), "Enter").defaultPrevented).toBe(false);
    expect(key(grid(), " ").defaultPrevented).toBe(false);
    expect(key(grid(), "Escape").defaultPrevented).toBe(false);
    key(grid(), "ArrowDown");
    key(grid(), " ");
    expect(dialogTitle()).toBe("Show a1");
    await pickDialog("Close");
    key(grid(), "Enter");
    expect(document.querySelector("#main .tuning .tuning-name")!.textContent).toBe("1 · Alpha");
    expect(key(grid(), "Escape").defaultPrevented).toBe(true);
    expect(selectedChannel()).toBeNull();
    // Space on an empty lane has nothing to show.
    key(grid(), "End");
    expect(key(grid(), " ").defaultPrevented).toBe(false);
  });

  it("jumps to a channel by its first letters or its number, starting over after a pause", async () => {
    channels = [ch("c1", "Alpha", "1"), ch("c2", "Beta", "2"), ch("c3", "Bravo", "33")];
    await boot();
    await open();
    key(grid(), "b");
    expect(selectedChannel()).toBe("Beta");
    key(grid(), "r");
    expect(selectedChannel()).toBe("Bravo");
    vi.advanceTimersByTime(1500);
    key(grid(), "a");
    expect(selectedChannel()).toBe("Alpha");
    vi.advanceTimersByTime(1500);
    key(grid(), "2");
    expect(selectedChannel()).toBe("Beta");
    key(grid(), "z");
    expect(selectedChannel()).toBe("Beta");
    expect(key(grid(), "F5").defaultPrevented).toBe(false);
  });

  it("leaves the keys alone with a modifier held, or while the video covers the guide", async () => {
    await boot();
    await open();
    expect(key(grid(), "ArrowDown", { altKey: true }).defaultPrevented).toBe(false);
    expect(key(grid(), "ArrowDown", { metaKey: true }).defaultPrevented).toBe(false);
    document.body.classList.add("video-covered");
    expect(key(grid(), "ArrowDown").defaultPrevented).toBe(false);
    expect(selectedChannel()).toBeNull();
  });

  it("selects what's on now on the first row when the grid gets focus by Tab", async () => {
    await boot();
    await open();
    grid().focus();
    await flush();
    expect(selectedTitle()).toBe("Show a1");
    // Not again once something is selected.
    key(grid(), "ArrowDown");
    grid().blur();
    grid().focus();
    await flush();
    expect(selectedChannel()).toBe("Beta");
  });
});

describe("moving in time", () => {
  it("steps two hours with Earlier and Later, comes back with Now, and keeps the selection's row", async () => {
    const asked: string[] = [];
    programs = (q) => (asked.push(q.get("minEndDate")!), { Items: defaultPrograms() });
    await boot();
    await open();
    key(grid(), "ArrowDown");
    key(grid(), "ArrowDown");
    click(toolbarBtn("Later"));
    await flush(40);
    expect(asked.at(-1)).toBe(new Date(START + 2 * H).toISOString());
    expect(selectedChannel()).toBe("Beta");
    click(toolbarBtn("Earlier"));
    click(toolbarBtn("Earlier"));
    await flush(80);
    expect(asked.at(-1)).toBe(new Date(START - 2 * H).toISOString());
    click(toolbarBtn("Now"));
    await flush(40);
    expect(asked.at(-1)).toBe(new Date(START).toISOString());
    expect(toolbarBtn("Now").disabled).toBe(true);
    expect(selectedChannel()).toBe("Beta");
    // Now when already there just scrolls back to the start.
    const scrollTo = vi.spyOn(grid(), "scrollTo");
    toolbarBtn("Now").disabled = false;
    click(toolbarBtn("Now"));
    expect(scrollTo).toHaveBeenCalledWith({ left: 0, behavior: "smooth" });
  });

  it("adds six hours at a time with More hours, up to a day", async () => {
    const asked: string[] = [];
    programs = (q) => (asked.push(q.get("maxStartDate")!), { Items: defaultPrograms() });
    await boot();
    await open();
    const more = root.querySelector<HTMLButtonElement>(".guide-more")!;
    for (let i = 0; i < 3; i++) {
      click(more);
      await flush(40);
    }
    expect(asked.at(-1)).toBe(new Date(START + 24 * H).toISOString());
    expect(more.disabled).toBe(true);
    expect(more.title).toBe("The guide holds a day at most");
    expect(root.querySelectorAll(".guide-tick")).toHaveLength(48);
    more.disabled = false;
    click(more);
    await flush(40);
    expect(asked).toHaveLength(4);
    // Moving resets the window to six hours.
    click(toolbarBtn("Later"));
    await flush(40);
    expect(root.querySelectorAll(".guide-tick")).toHaveLength(12);
  });

  it("jumps to a day and time from the picker, at the half hour before it", async () => {
    const asked: string[] = [];
    programs = (q) => (asked.push(q.get("minEndDate")!), { Items: defaultPrograms() });
    await boot();
    await open();
    const jump = root.querySelector<HTMLInputElement>(".guide-jump")!;
    expect(jump.value).toBe("2026-06-01T20:00");
    expect(jump.min).toBe("2026-06-01T08:00");
    expect(jump.max).toBe("2026-06-15T20:10");
    jump.value = "2026-06-03T09:45";
    jump.dispatchEvent(new Event("change"));
    await flush(40);
    expect(asked.at(-1)).toBe(new Date(2026, 5, 3, 9, 30).toISOString());
    expect(range()).toMatch(/^Wed/);
    jump.value = "";
    jump.dispatchEvent(new Event("change"));
    // The same start again changes nothing.
    jump.value = "2026-06-03T09:31";
    jump.dispatchEvent(new Event("change"));
    await flush(40);
    expect(asked).toHaveLength(2);
  });

  it("moves with Ctrl+←, Ctrl+→ and Ctrl+T from anywhere but a text field or under the video", async () => {
    const asked: string[] = [];
    programs = (q) => (asked.push(q.get("minEndDate")!), { Items: defaultPrograms() });
    await boot();
    await open();
    expect(key(document.body, "ArrowRight", { ctrlKey: true }).defaultPrevented).toBe(true);
    await flush(40);
    key(document.body, "ArrowLeft", { ctrlKey: true });
    await flush(40);
    key(document.body, "ArrowRight", { ctrlKey: true });
    await flush(40);
    key(document.body, "T", { ctrlKey: true });
    await flush(40);
    expect(asked.slice(1)).toEqual([START + 2 * H, START, START + 2 * H, START].map((t) => new Date(t).toISOString()));
    const f = root.querySelector<HTMLInputElement>(".guide-filter")!;
    expect(key(f, "ArrowRight", { ctrlKey: true }).defaultPrevented).toBe(false);
    expect(key(document.body, "ArrowRight", { ctrlKey: true, shiftKey: true }).defaultPrevented).toBe(false);
    expect(key(document.body, "x", { ctrlKey: true }).defaultPrevented).toBe(false);
    expect(key(document.body, "ArrowRight").defaultPrevented).toBe(false);
    document.body.classList.add("video-covered");
    expect(key(document.body, "t", { ctrlKey: true }).defaultPrevented).toBe(false);
    document.body.classList.remove("video-covered");
    // The grid ignores Ctrl itself; the page handler has it.
    expect(key(grid(), "ArrowDown", { ctrlKey: true }).defaultPrevented).toBe(false);
    // Once the guide is gone the handler takes itself off.
    root.textContent = "";
    key(document.body, "ArrowRight", { ctrlKey: true });
    await flush(40);
    expect(asked).toHaveLength(5);
  });

  it("asks again after a load already in flight, rather than overlapping", async () => {
    const asked: string[] = [];
    let release: (() => void) | null = null;
    programs = (q) => {
      asked.push(q.get("minEndDate")!);
      if (asked.length === 2) return new Promise((r) => (release = () => r({ Items: defaultPrograms() })));
      return { Items: defaultPrograms() };
    };
    await boot();
    await open();
    click(toolbarBtn("Later"));
    await flush(10);
    click(toolbarBtn("Later"));
    await flush(10);
    expect(asked).toHaveLength(2);
    release!();
    await flush(60);
    expect(asked).toHaveLength(3);
    expect(asked[2]).toBe(new Date(START + 4 * H).toISOString());
  });

  it("shows an error in the grid when the schedule fails, with Try again", async () => {
    let fail = false;
    programs = () => (fail ? { __status: 502 } : { Items: defaultPrograms() });
    await boot();
    await open();
    fail = true;
    click(toolbarBtn("Later"));
    await flush(40);
    expect(root.querySelector(".guide-rows .state h3")!.textContent).toBe("Couldn't load the guide");
    fail = false;
    click(byText(root, ".guide-rows .state button", "Try again"));
    await flush(40);
    expect(rowNames()).toEqual(["Alpha", "Beta", "Gamma"]);
  });

  it("an empty later window is drawn as empty lanes, not as no guide", async () => {
    programs = (q) => (q.get("minEndDate") === new Date(START).toISOString() ? { Items: defaultPrograms() } : { Items: [] });
    await boot();
    await open();
    click(toolbarBtn("Later"));
    await flush(40);
    expect(root.querySelector(".guide")).not.toBeNull();
    expect(root.querySelectorAll(".guide-gap")).toHaveLength(3);
  });

  it("drops a schedule that arrives after the page has gone", async () => {
    let release!: (v: any) => void;
    let n = 0;
    programs = () => (++n === 2 ? new Promise((r) => (release = r)) : { Items: defaultPrograms() });
    await boot();
    await open();
    click(toolbarBtn("Later"));
    const guide = root.querySelector(".guide")!;
    root.textContent = "";
    release({ Items: [] });
    await flush(40);
    expect(root.children).toHaveLength(0);
    expect(guide.querySelector(".guide-rows")!.children.length).toBeGreaterThan(0);
  });

  it("moves the now line every thirty seconds, and stops with the page", async () => {
    await boot();
    await open();
    const line = root.querySelector<HTMLElement>(".guide-now")!;
    expect(line.style.left).toBe("50px");
    vi.advanceTimersByTime(30_000);
    expect(line.style.left).toBe("52.5px");
    // Off the window: hidden.
    click(toolbarBtn("Later"));
    await flush(40);
    expect(line.style.display).toBe("none");
    const clear = vi.spyOn(window, "clearInterval");
    root.textContent = "";
    vi.advanceTimersByTime(30_000);
    expect(clear).toHaveBeenCalled();
  });
});

describe("the tuning screen (regression: 9a86b79)", () => {
  async function tuneAlpha() {
    await boot();
    await open();
    click(root.querySelector(".guide-ch"));
    await flush(20);
    return document.querySelector<HTMLElement>("#main .tuning")!;
  }

  it("covers the player area with the channel and a once-a-second counter, not an animation", async () => {
    const t = await tuneAlpha();
    expect(t.getAttribute("role")).toBe("status");
    expect(t.querySelector(".tuning-status")!.textContent).toBe("Tuning…");
    vi.advanceTimersByTime(1000);
    expect(t.querySelector(".tuning-status")!.textContent).toBe("Tuning… 1 s");
    vi.advanceTimersByTime(5000);
    expect(t.querySelector(".tuning-status")!.textContent).toMatch(/^Still tuning… 6 s — a channel nobody's watching/);
    expect(t.querySelector(".tuning-logo")!.textContent).toBe("1");
    expect(t.querySelector(".spinner")).toBeNull();
    expect(foreverAnimated(document)).toEqual([]);
    expect(playback.playItem).toHaveBeenCalledWith(expect.objectContaining({ Id: "c1" }), { live: true }, { quiet: true, continuation: undefined });
  });

  it("ignores another click on the channel already tuning, and replaces it for a different one", async () => {
    await tuneAlpha();
    click(root.querySelector(".guide-ch"));
    expect(playback.playItem).toHaveBeenCalledTimes(1);
    expect(document.querySelectorAll(".tuning")).toHaveLength(1);
    click(root.querySelectorAll(".guide-ch")[1]!);
    expect(document.querySelectorAll(".tuning")).toHaveLength(1);
    expect(document.querySelector(".tuning-name")!.textContent).toBe("2 · Beta");
  });

  it("stays up until mpv reports a moving clock, not just an open stream", async () => {
    const t = await tuneAlpha();
    expect(listenerCount("player-status")).toBe(1);
    emitEvent("player-status", { active: true, position: 0, buffering: false });
    await flush(20);
    expect(t.isConnected).toBe(true);
    emitEvent("player-status", { active: true, position: 1.2, buffering: true });
    await flush(20);
    expect(t.isConnected).toBe(true);
    emitEvent("player-status", { active: true, position: 1.4, buffering: false });
    await flush(20);
    expect(t.isConnected).toBe(false);
    expect(listenerCount("player-status")).toBe(0);
  });

  it("goes when the player stops", async () => {
    const t = await tuneAlpha();
    emitEvent("player-status", { active: false });
    await flush(20);
    expect(t.isConnected).toBe(false);
  });

  it("goes after fifteen seconds at most when no picture comes", async () => {
    // Faking setTimeout too needs a fresh install.
    vi.useRealTimers();
    vi.useFakeTimers({ toFake: ["setInterval", "clearInterval", "setTimeout", "clearTimeout", "Date"] });
    vi.setSystemTime(NOW);
    const t = await tuneAlpha();
    expect(listenerCount("player-status")).toBe(1);
    vi.advanceTimersByTime(14_000);
    await flush(20);
    expect(t.isConnected).toBe(true);
    vi.advanceTimersByTime(1_000);
    await flush(40);
    expect(t.isConnected).toBe(false);
  });

  it("Cancel takes it down, and stops a stream mpv had already opened", async () => {
    let t = await tuneAlpha();
    onInvoke("player_stop", null);
    const c1 = channels[0];
    vi.mocked(playback.getNowPlaying).mockReturnValue({ item: c1, isLocal: false });
    click(byText(t, "button", "Cancel"));
    expect(t.isConnected).toBe(false);
    expect(invokeCalls("player_stop")).toHaveLength(1);
    vi.mocked(playback.getNowPlaying).mockReturnValue(null);
    // Cancelled while still asking for the stream: nothing to stop yet...
    let release!: () => void;
    vi.mocked(playback.playItem).mockImplementationOnce(() => new Promise<void>((r) => (release = r)));
    click(root.querySelectorAll(".guide-ch")[1]!);
    t = document.querySelector<HTMLElement>(".tuning")!;
    click(byText(t, "button", "Cancel"));
    expect(t.isConnected).toBe(false);
    expect(invokeCalls("player_stop")).toHaveLength(1);
    // ...but if it opened anyway, it is stopped once it does.
    vi.mocked(playback.getNowPlaying).mockReturnValue({ item: channels[1], isLocal: false });
    release();
    await flush(20);
    expect(invokeCalls("player_stop")).toHaveLength(2);
    // The first channel's wait for a picture ends with the player's next word.
    emitEvent("player-status", { active: false });
    await flush(20);
    expect(listenerCount("player-status")).toBe(0);
  });

  it("cancelling a request that then opens nothing stops nothing, and a stop that fails is ignored", async () => {
    await boot();
    await open();
    onInvoke("player_stop", () => {
      throw new Error("no player");
    });
    let release!: () => void;
    vi.mocked(playback.playItem).mockImplementationOnce(() => new Promise<void>((r) => (release = r)));
    click(root.querySelector(".guide-ch"));
    click(byText(document.querySelector(".tuning")!, "button", "Cancel"));
    release();
    await flush(20);
    expect(invokeCalls("player_stop")).toHaveLength(0);
    // Opened, then cancelled, with a stop that fails.
    click(root.querySelector(".guide-ch"));
    await flush(20);
    vi.mocked(playback.getNowPlaying).mockReturnValue({ item: channels[0], isLocal: false });
    click(byText(document.querySelector(".tuning")!, "button", "Cancel"));
    await flush(20);
    expect(invokeCalls("player_stop")).toHaveLength(1);
    // A cancel for a channel that isn't the one now playing stops nothing.
    vi.mocked(playback.getNowPlaying).mockReturnValue({ item: channels[1], isLocal: false });
    click(root.querySelector(".guide-ch"));
    await flush(20);
    click(byText(document.querySelector(".tuning")!, "button", "Cancel"));
    expect(invokeCalls("player_stop")).toHaveLength(1);
  });

  it("goes when the channel fails to start (the player has already said why)", async () => {
    await boot();
    await open();
    vi.mocked(playback.playItem).mockRejectedValueOnce(new Error("tuner busy"));
    click(root.querySelector(".guide-ch"));
    await flush(20);
    expect(document.querySelector(".tuning")).toBeNull();
  });

  it("shows the channel's own logo, or a name when it has neither logo nor number", async () => {
    await boot();
    tv.tuneChannel(ch("z", "Zed", undefined, { LogoUrl: "http://logo.test/z.png" }));
    expect(document.querySelector(".tuning-logo img")!.getAttribute("src")).toBe("http://logo.test/z.png");
    expect(document.querySelector(".tuning-name")!.textContent).toBe("Zed");
    tv.tuneChannel({ Id: "n", ImageTags: {} });
    expect(document.querySelector(".tuning-logo")!.textContent).toBe("?");
    expect(document.querySelector(".tuning-name")!.textContent).toBe("Channel");
  });

  it("tunes through the custom source's player when Live TV is set to a playlist", async () => {
    await boot({ livetv_source: "custom" });
    tv.tuneChannel({ Id: "iptv:0", Name: "Seven", Custom: true, StreamUrl: "http://s/7" });
    await flush(20);
    expect(playback.playChannelUrl).toHaveBeenCalled();
    expect(playback.playItem).not.toHaveBeenCalled();
  });
});

describe("On Now (Home's row)", () => {
  it("is what's airing on each channel, from the shared line-up", async () => {
    programs = () => ({ Items: [prog("p1", "c1", START, START + H), prog("p2", "c2", START + H, START + 2 * H)] });
    await boot();
    const rows = await tv.onNow();
    expect(rows.map((r) => [r.channel.Id, r.program.Id])).toEqual([["c1", "p1"]]);
  });

  it("draws a card with the programme over its channel, how far in it is, and until when", async () => {
    await boot();
    const card = tv.onNowCard(ch("c1", "Alpha", "1"), prog("p1", "c1", NOW - 15 * 60_000, NOW + 45 * 60_000, { ImageTags: { Primary: "pt" } }));
    root.append(card);
    expect(card.querySelector(".card-title")!.textContent).toBe("Show p1");
    expect(card.querySelector(".card-sub")!.textContent).toMatch(/^1 · Alpha · until /);
    expect(card.querySelector<HTMLElement>(".progress-strip div")!.style.width).toBe("25%");
    expect(card.querySelector("img")!.getAttribute("src")).toMatch(/\/Items\/p1\/Images\/Primary/);
    expect(card.querySelector(".onnow-live")!.textContent).toBe("Live");
    expect(card.title).toBe("1 · Alpha — Show p1");
    click(card);
    expect(document.querySelector(".tuning")).not.toBeNull();
  });

  it("falls back to the channel's logo or picture, its name for a title, and no times for a bad schedule", async () => {
    await boot();
    const a = tv.onNowCard(ch("c1", "Alpha", undefined, { LogoUrl: "http://l/a.png" }), { Name: undefined, StartDate: "x", EndDate: "y" });
    expect(a.querySelector("img")!.getAttribute("src")).toBe("http://l/a.png");
    expect(a.querySelector(".card-title")!.textContent).toBe("Alpha");
    expect(a.querySelector(".card-sub")!.textContent).toBe("Alpha");
    expect(a.querySelector<HTMLElement>(".progress-strip div")!.style.width).toBe("0%");
    const b = tv.onNowCard(ch("c2", "Beta", "2", { ImageTags: { Primary: "ct" } }), prog("p", "c2", NOW, NOW + H));
    expect(b.querySelector("img")!.getAttribute("src")).toMatch(/\/Items\/c2\/Images\/Primary/);
    const c = tv.onNowCard({ Id: "c3", ImageTags: {} }, {});
    expect(c.querySelector(".card-poster")!.textContent).toMatch(/^\?/);
  });

  it("tunes from the keyboard with Enter or Space", async () => {
    await boot();
    const card = tv.onNowCard(ch("c1", "Alpha", "1"), prog("p1", "c1", NOW, NOW + H));
    root.append(card);
    expect(key(card, "x").defaultPrevented).toBe(false);
    expect(document.querySelector(".tuning")).toBeNull();
    expect(key(card, "Enter").defaultPrevented).toBe(true);
    expect(document.querySelector(".tuning")).not.toBeNull();
    document.querySelector(".tuning")!.remove();
    const card2 = tv.onNowCard(ch("c2", "Beta", "2"), prog("p2", "c2", NOW, NOW + H));
    root.append(card2);
    key(card2, " ");
    expect(document.querySelector(".tuning-name")!.textContent).toBe("2 · Beta");
  });
});
