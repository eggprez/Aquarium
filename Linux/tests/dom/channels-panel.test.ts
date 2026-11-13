// src/channels-panel.ts: Live TV inside the player — the title lines, channel
// switching and stepping, and the Channels panel strip.
import { beforeEach, describe, expect, it, vi } from "vitest";
import { flush, mockJellyfin, signIn } from "../helpers/tauri";
import { deferred, isoIn } from "../helpers/small-modules";

const pb = vi.hoisted(() => ({
  playItem: vi.fn(async (..._a: any[]) => {}),
  playChannelUrl: vi.fn(async (..._a: any[]) => {}),
  getNowPlaying: vi.fn((): any => null),
  startDownload: vi.fn(),
  downloadSeries: vi.fn(),
  queueNext: vi.fn(),
  queueLater: vi.fn(),
}));
vi.mock("../../src/playback", () => pb);

type P = typeof import("../../src/channels-panel");
let panelMod: P;
let lineup: typeof import("../../src/lineup");

const T0 = Date.UTC(2026, 10, 12, 20, 0, 0);

beforeEach(async () => {
  vi.clearAllMocks();
  pb.getNowPlaying.mockReturnValue(null);
  vi.useFakeTimers({ toFake: ["Date"] });
  vi.setSystemTime(T0);
  vi.resetModules();
  panelMod = await import("../../src/channels-panel");
  lineup = await import("../../src/lineup");
});

function ch(id: string, extra: any = {}): any {
  return { Id: id, Name: `Ch ${id}`, Type: "TvChannel", ChannelNumber: id, ...extra };
}

function prog(chId: string, s: number, e: number, name: string, extra: any = {}): any {
  return { Id: `${chId}-${s}`, ChannelId: chId, Name: name, StartDate: isoIn(s, T0), EndDate: isoIn(e, T0), ...extra };
}

const clock = (min: number): string =>
  new Date(T0 + min * 60_000).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });

function jellyfin(channels: any[], programs: any[] = []): void {
  mockJellyfin([
    ["/LiveTv/Channels", () => ({ Items: channels })],
    ["/LiveTv/Programs", () => ({ Items: programs })],
  ]);
}

/** Make the schedule known, so the synchronous now/next has it. */
async function withSchedule(channels: any[], programs: any[]): Promise<void> {
  await signIn();
  jellyfin(channels, programs);
  await lineup.loadLineup();
  await lineup.nearSchedule();
}

function barRefreshes(): { count: () => number } {
  let n = 0;
  document.addEventListener("aquarium-bar-refresh", () => n++);
  return { count: () => n };
}

describe("liveTitleLines", () => {
  it("is null for anything that isn't a channel", () => {
    expect(panelMod.liveTitleLines({ Type: "Movie", Name: "Film" })).toBeNull();
    expect(panelMod.liveTitleLines(null)).toBeNull();
  });

  it("names the channel (with its number) and says what's on and what's coming up", async () => {
    const c = ch("7", { Name: "News" });
    await withSchedule([c], [prog("7", -10, 20, "Headlines", { EpisodeTitle: "Late" }), prog("7", 20, 50, "Weather")]);
    const t = panelMod.liveTitleLines(c)!;
    expect(t.line1).toBe("7 · News");
    expect(t.line2).toBe(`Headlines · Coming up ${clock(20)} Weather`);
    expect(t.tip).toBe(
      ["7 · News", `On now: Headlines — Late (${clock(-10)} – ${clock(20)})`, `Coming up: Weather at ${clock(20)}`].join("\n")
    );
  });

  it("a channel with no number or name, and no schedule, is just 'Channel'", async () => {
    await withSchedule([], []);
    const t = panelMod.liveTitleLines({ Id: "x", Custom: true })!;
    expect(t).toEqual({ line1: "Channel", line2: "", tip: "Channel" });
  });

  it("a programme with no name reads 'On now'", async () => {
    const c = ch("1");
    await withSchedule([c], [prog("1", -5, 5, undefined as any)]);
    expect(panelMod.liveTitleLines(c)!.line2).toBe("On now");
  });
});

describe("switchChannel", () => {
  it("redraws the player title as soon as the switch starts, and again when it settles (regression: bc28e10)", async () => {
    await signIn();
    const gate = deferred<void>();
    pb.playItem.mockReturnValueOnce(gate.promise);
    const r = barRefreshes();
    panelMod.switchChannel(ch("2", { Name: "Two" }));
    expect(r.count()).toBe(1);
    // While tuning, the title says so instead of the old channel's lines.
    expect(panelMod.liveTitleLines(ch("1"))).toEqual({ line1: "2 · Two", line2: "Tuning…", tip: "2 · Two" });
    gate.resolve();
    await flush();
    expect(r.count()).toBe(2);
    expect(panelMod.liveTitleLines({ Type: "Movie" })).toBeNull();
  });

  it("starts the new channel as a continuation, so a fullscreen player stays fullscreen", () => {
    const c = ch("2");
    panelMod.switchChannel(c);
    expect(pb.playItem).toHaveBeenCalledWith(c, { live: true }, { quiet: true, continuation: true });
  });

  it("counts the seconds once tuning has taken two or more", async () => {
    pb.playItem.mockReturnValueOnce(new Promise(() => {}));
    panelMod.switchChannel(ch("2"));
    vi.setSystemTime(T0 + 1400);
    expect(panelMod.liveTitleLines(null)!.line2).toBe("Tuning…");
    vi.setSystemTime(T0 + 3000);
    expect(panelMod.liveTitleLines(null)!.line2).toBe("Tuning… 3 s");
  });

  it("does nothing for the channel already playing, or the one already being tuned", () => {
    pb.getNowPlaying.mockReturnValue({ item: ch("1"), isLocal: false });
    panelMod.switchChannel(ch("1"));
    expect(pb.playItem).not.toHaveBeenCalled();
    pb.playItem.mockReturnValueOnce(new Promise(() => {}));
    panelMod.switchChannel(ch("2"));
    panelMod.switchChannel(ch("2"));
    expect(pb.playItem).toHaveBeenCalledTimes(1);
  });

  it("a failure is said in the title for ten seconds, since the picture covers any toast", async () => {
    pb.playItem.mockRejectedValueOnce(new Error("no tuner"));
    const c = ch("3", { Name: "Three" });
    panelMod.switchChannel(c);
    await flush();
    expect(panelMod.liveTitleLines(ch("1"))).toEqual({ line1: "3 · Three", line2: "Couldn't tune: no tuner", tip: "no tuner" });
    vi.setSystemTime(T0 + 9_999);
    expect(panelMod.liveTitleLines({ Type: "Movie" })).not.toBeNull();
    vi.setSystemTime(T0 + 10_000);
    expect(panelMod.liveTitleLines({ Type: "Movie" })).toBeNull();
  });

  it("a failure without a message is still said", async () => {
    pb.playItem.mockRejectedValueOnce("plain");
    panelMod.switchChannel(ch("3"));
    await flush();
    expect(panelMod.liveTitleLines(null)!.line2).toBe("Couldn't tune: plain");
  });

  it("a newer switch clears an old failure, and a superseded switch's failure is not shown", async () => {
    const first = deferred<void>();
    pb.playItem.mockReturnValueOnce(first.promise).mockReturnValueOnce(new Promise(() => {}));
    panelMod.switchChannel(ch("2"));
    panelMod.switchChannel(ch("3", { Name: "Three" }));
    first.reject(new Error("late failure"));
    await flush();
    expect(panelMod.liveTitleLines(null)!.line1).toBe("3 · Three");
    expect(panelMod.liveTitleLines(null)!.line2).toBe("Tuning…");
  });
});

describe("stepChannel", () => {
  it("is false when nothing is a channel or there is no line-up", async () => {
    expect(panelMod.stepChannel(1)).toBe(false);
    pb.getNowPlaying.mockReturnValue({ item: ch("1"), isLocal: false });
    expect(panelMod.stepChannel(1)).toBe(false); // no line-up cached
    pb.getNowPlaying.mockReturnValue({ item: { Type: "Movie", Id: "m" }, isLocal: false });
    await withSchedule([ch("1")], []);
    expect(panelMod.stepChannel(1)).toBe(false);
  });

  it("moves up and down the line-up, wrapping at the ends", async () => {
    await withSchedule([ch("1"), ch("2"), ch("3")], []);
    pb.getNowPlaying.mockReturnValue({ item: ch("3"), isLocal: false });
    pb.playItem.mockImplementation(async () => {});
    expect(panelMod.stepChannel(1)).toBe(true);
    expect(pb.playItem.mock.calls[0]![0].Id).toBe("1");
    await flush();
    pb.getNowPlaying.mockReturnValue({ item: ch("1"), isLocal: false });
    panelMod.stepChannel(-1);
    expect(pb.playItem.mock.calls[1]![0].Id).toBe("3");
  });

  it("steps from the channel being tuned, so repeated presses keep going", async () => {
    await withSchedule([ch("1"), ch("2"), ch("3")], []);
    pb.getNowPlaying.mockReturnValue({ item: ch("1"), isLocal: false });
    pb.playItem.mockReturnValue(new Promise(() => {}));
    panelMod.stepChannel(1);
    panelMod.stepChannel(1);
    expect(pb.playItem.mock.calls.map((c) => c[0].Id)).toEqual(["2", "3"]);
  });
});

describe("fillChannelsPanel", () => {
  function panelEl(): HTMLElement {
    const p = document.createElement("div");
    p.className = "pb-panel";
    document.body.append(p);
    return p;
  }

  it("says it is loading, then draws a tile per channel with what's on and how far through", async () => {
    await signIn();
    const gate = deferred<any>();
    mockJellyfin([
      ["/LiveTv/Channels", () => gate.promise],
      ["/LiveTv/Programs", { Items: [prog("1", -15, 15, "Show")] }],
    ]);
    const p = panelEl();
    panelMod.fillChannelsPanel(p, () => {});
    expect(p.classList.contains("pb-queue")).toBe(true);
    expect(p.classList.contains("pb-channels")).toBe(true);
    expect(p.querySelector(".pb-panel-note")!.textContent).toBe("Loading channels…");
    gate.resolve({ Items: [ch("1", { Name: "One" }), ch("2", { Name: "Two", ChannelNumber: undefined })] });
    await vi.waitFor(() => expect(p.querySelectorAll(".pb-ch-tile")).toHaveLength(2));
    expect(p.querySelector(".pb-panel-note")).toBeNull();
    const [one, two] = [...p.querySelectorAll<HTMLElement>(".pb-ch-tile")];
    expect(one!.querySelector(".pb-ch-num")!.textContent).toBe("1");
    expect(one!.querySelector(".pb-queue-status")!.textContent).toBe("Show");
    expect((one!.querySelector(".pb-ch-progress > span") as HTMLElement).style.width).toBe("50%");
    expect(one!.title).toBe(`1 · One\nOn now: Show (until ${clock(15)})`);
    expect(two!.querySelector(".pb-ch-num")).toBeNull();
    expect(two!.querySelector(".pb-ch-progress")).toBeNull();
    expect(two!.title).toBe("Two");
  });

  it("paints the cached line-up at once, before any request answers", async () => {
    await withSchedule([ch("1"), ch("2")], []);
    mockJellyfin([["/LiveTv/Channels", () => new Promise(() => {})]]);
    const p = panelEl();
    panelMod.fillChannelsPanel(p, () => {});
    expect(p.querySelectorAll(".pb-ch-tile")).toHaveLength(2);
    expect(p.querySelector(".pb-panel-note")).toBeNull();
  });

  it("marks the playing channel and scrolls it into view", async () => {
    await withSchedule([ch("1"), ch("2")], []);
    pb.getNowPlaying.mockReturnValue({ item: ch("2"), isLocal: false });
    const p = panelEl();
    panelMod.fillChannelsPanel(p, () => {});
    const tiles = [...p.querySelectorAll<HTMLElement>(".pb-ch-tile")];
    expect(tiles[1]!.classList.contains("playing")).toBe(true);
    expect(tiles[1]!.getAttribute("aria-current")).toBe("true");
    expect(tiles[0]!.hasAttribute("aria-current")).toBe(false);
    expect(tiles[1]!.querySelector(".pb-queue-status")!.textContent).toBe("Watching");
    expect(tiles[1]!.querySelector(".pb-queue-status")!.classList.contains("live")).toBe(true);
    const strip = p.querySelector<HTMLElement>(".pb-queue-strip")!;
    expect(strip.style.scrollBehavior).toBe("");
  });

  it("puts the strip before the close button, and redraws in place rather than adding a second strip", async () => {
    await withSchedule([ch("1")], []);
    const p = panelEl();
    const close = document.createElement("button");
    close.className = "pb-panel-close";
    p.append(close);
    panelMod.fillChannelsPanel(p, () => {});
    await vi.waitFor(() => expect(p.querySelectorAll(".pb-queue-strip")).toHaveLength(1));
    await flush();
    expect(p.querySelectorAll(".pb-queue-strip")).toHaveLength(1);
    expect(p.lastElementChild).toBe(close);
    expect(p.firstElementChild!.classList.contains("pb-queue-strip")).toBe(true);
  });

  it("a tile click closes the panel and switches channel", async () => {
    await withSchedule([ch("1"), ch("2")], []);
    const closed = vi.fn();
    const p = panelEl();
    panelMod.fillChannelsPanel(p, closed);
    p.querySelectorAll<HTMLElement>(".pb-ch-tile")[1]!.click();
    expect(closed).toHaveBeenCalledTimes(1);
    expect(pb.playItem.mock.calls[0]![0].Id).toBe("2");
  });

  it("a vertical wheel scrolls the strip sideways; a sideways one is left alone", async () => {
    await withSchedule([ch("1")], []);
    const p = panelEl();
    panelMod.fillChannelsPanel(p, () => {});
    const strip = p.querySelector<HTMLElement>(".pb-queue-strip")!;
    let left = 0;
    Object.defineProperty(strip, "scrollLeft", { get: () => left, set: (v) => (left = v), configurable: true });
    const down = new WheelEvent("wheel", { deltaY: 120, cancelable: true });
    strip.dispatchEvent(down);
    expect(down.defaultPrevented).toBe(true);
    expect(left).toBe(120);
    const side = new WheelEvent("wheel", { deltaX: 50, deltaY: 10, cancelable: true });
    strip.dispatchEvent(side);
    expect(side.defaultPrevented).toBe(false);
    expect(left).toBe(120);
  });

  it("says No channels for an empty line-up", async () => {
    await signIn();
    jellyfin([]);
    const p = panelEl();
    panelMod.fillChannelsPanel(p, () => {});
    await vi.waitFor(() => expect(p.textContent).toBe("No channels"));
  });

  it("says why when the line-up can't be read", async () => {
    await signIn();
    mockJellyfin([["/LiveTv/Channels", { __status: 500 }]]);
    const p = panelEl();
    panelMod.fillChannelsPanel(p, () => {});
    await vi.waitFor(() => expect(p.textContent).toMatch(/^Couldn't load channels: Server error 500/));
  });

  it("draws the channels even when the schedule can't be read", async () => {
    await signIn();
    mockJellyfin([
      ["/LiveTv/Channels", { Items: [ch("1")] }],
      ["/LiveTv/Programs", { __status: 500 }],
    ]);
    const p = panelEl();
    panelMod.fillChannelsPanel(p, () => {});
    await vi.waitFor(() => expect(p.querySelectorAll(".pb-ch-tile")).toHaveLength(1));
  });

  it.each(["success", "failure"])("touches nothing once the panel has been closed (on %s)", async (how) => {
    await signIn();
    const gate = deferred<any>();
    mockJellyfin([
      ["/LiveTv/Channels", () => gate.promise],
      ["/LiveTv/Programs", { Items: [] }],
    ]);
    const p = panelEl();
    panelMod.fillChannelsPanel(p, () => {});
    p.remove();
    if (how === "success") gate.resolve({ Items: [ch("1")] });
    else gate.resolve({ __status: 500 });
    await flush(30);
    expect(p.textContent).toBe("Loading channels…");
    expect(p.querySelector(".pb-ch-tile")).toBeNull();
  });

  it("stops if the panel closes while the schedule is being read", async () => {
    await signIn();
    const sched = deferred<any>();
    mockJellyfin([
      ["/LiveTv/Channels", { Items: [ch("1")] }],
      ["/LiveTv/Programs", () => sched.promise],
    ]);
    const p = panelEl();
    panelMod.fillChannelsPanel(p, () => {});
    await flush(30);
    p.remove();
    sched.resolve({ Items: [] });
    await flush(30);
    expect(p.querySelector(".pb-ch-tile")).toBeNull();
  });

  it("uses the channel's logo, or its number as a stand-in", async () => {
    await withSchedule([ch("1", { LogoUrl: "http://tv.test/1.png" }), ch("22", { Name: "Twenty-two" })], []);
    const p = panelEl();
    panelMod.fillChannelsPanel(p, () => {});
    const logos = [...p.querySelectorAll(".pb-ch-logo")];
    expect(logos[0]!.querySelector("img")!.getAttribute("src")).toBe("http://tv.test/1.png");
    expect(logos[0]!.querySelector("img")!.hasAttribute("loading")).toBe(false); // not lazy
    expect(logos[1]!.textContent).toContain("22");
  });
});
