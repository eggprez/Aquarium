// src/lineup.ts: the Live TV line-up, the near schedule, now/next, the "On
// Now" list, playing a channel, and the background load at launch.
import { beforeEach, describe, expect, it, vi } from "vitest";
import { flush, invokeCalls, jfPaths, mockJellyfin, onInvoke, signIn } from "../helpers/tauri";
import { deferred, isoIn, serveSources, xmltvStamp } from "../helpers/small-modules";

const pb = vi.hoisted(() => ({
  playItem: vi.fn(async () => {}),
  playChannelUrl: vi.fn(async () => {}),
  getNowPlaying: vi.fn(() => null),
}));
vi.mock("../../src/playback", () => pb);

type L = typeof import("../../src/lineup");
let lineup: L;

const T0 = Date.UTC(2026, 10, 12, 20, 0, 0);
const MIN = 60_000;

beforeEach(async () => {
  vi.clearAllMocks();
  vi.useFakeTimers({ toFake: ["Date", "setTimeout", "clearTimeout", "setInterval", "clearInterval"] });
  vi.setSystemTime(T0);
  vi.resetModules();
  lineup = await import("../../src/lineup");
});

function ch(id: string, extra: any = {}): any {
  return { Id: id, Name: `Ch ${id}`, Type: "TvChannel", ChannelNumber: id, ...extra };
}

function prog(chId: string, startMin: number, endMin: number, name: string): any {
  return { Id: `${chId}-${startMin}`, ChannelId: chId, Name: name, StartDate: isoIn(startMin, T0), EndDate: isoIn(endMin, T0) };
}

/** A Jellyfin server with these channels and programmes. */
function jellyfin(channels: any[], programs: any[]): void {
  mockJellyfin([
    ["/LiveTv/Channels", () => ({ Items: channels })],
    [
      "/LiveTv/Programs",
      (a: any) => {
        const ids = new URL(`http://x${a.path}`).searchParams.get("channelIds")!.split(",");
        return { Items: programs.filter((p) => ids.includes(p.ChannelId)) };
      },
    ],
  ]);
}

const programPaths = (): string[] => jfPaths().filter((p) => p.startsWith("/LiveTv/Programs"));
const channelPaths = (): string[] => jfPaths().filter((p) => p.startsWith("/LiveTv/Channels"));

describe("lineupKey, cachedLineup, isChannel", () => {
  it("one cache key per source, shared with the guide", async () => {
    await signIn({ livetv_source: "jellyfin" });
    expect(lineup.lineupKey()).toBe("livetv:jellyfin");
    await signIn({ livetv_source: "custom" });
    expect(lineup.lineupKey()).toBe("livetv:custom");
  });

  it("cachedLineup reads whatever the guide (or anyone) cached, with no request", async () => {
    await signIn();
    expect(lineup.cachedLineup()).toBeUndefined();
    const cache = await import("../../src/cache");
    cache.setCached("livetv:jellyfin", [ch("1")]);
    expect(lineup.cachedLineup()).toEqual([ch("1")]);
    expect(invokeCalls("jf_request")).toHaveLength(0);
  });

  it.each([
    [{ Type: "TvChannel" }, true],
    [{ Custom: true }, true],
    [{ Custom: "yes" }, false],
    [{ Type: "Movie" }, false],
    [null, false],
    [undefined, false],
  ])("isChannel(%j) = %j", (item, want) => {
    expect(lineup.isChannel(item)).toBe(want);
  });
});

describe("loadLineup", () => {
  it("fetches Jellyfin's channels and writes them to the shared cache", async () => {
    await signIn();
    jellyfin([ch("1"), ch("2")], []);
    expect((await lineup.loadLineup()).map((c) => c.Id)).toEqual(["1", "2"]);
    expect(lineup.cachedLineup()!.map((c) => c.Id)).toEqual(["1", "2"]);
    const q = new URL(`http://x${channelPaths()[0]}`).searchParams;
    expect(q.get("userId")).toBe("user-1");
  });

  it("concurrent callers share one request; once it settles the next call asks again", async () => {
    await signIn();
    jellyfin([ch("1")], []);
    const a = lineup.loadLineup();
    const b = lineup.loadLineup();
    expect(b).toBe(a);
    await a;
    await lineup.loadLineup();
    expect(channelPaths()).toHaveLength(2);
  });

  it("force starts a new request even with one in flight", async () => {
    await signIn();
    jellyfin([ch("1")], []);
    const a = lineup.loadLineup();
    const b = lineup.loadLineup(true);
    expect(b).not.toBe(a);
    await Promise.all([a, b]);
    expect(channelPaths()).toHaveLength(2);
  });

  it("a failed request is not cached and is not shared with the next caller", async () => {
    await signIn();
    mockJellyfin([["/LiveTv/Channels", { __status: 500 }]]);
    await expect(lineup.loadLineup()).rejects.toThrow();
    expect(lineup.cachedLineup()).toBeUndefined();
    jellyfin([ch("1")], []);
    expect(await lineup.loadLineup()).toHaveLength(1);
  });

  it("reads a custom source's playlist instead, under the custom key", async () => {
    await signIn({ livetv_source: "custom", livetv_m3u: "http://tv.test/l.m3u" });
    serveSources({ "http://tv.test/l.m3u": '#EXTM3U\n#EXTINF:-1 tvg-id="a",Alpha\nhttp://tv.test/a.m3u8' });
    const chans = await lineup.loadLineup();
    expect(chans.map((c) => c.Name)).toEqual(["Alpha"]);
    expect(lineup.cachedLineup()).toEqual(chans);
    expect(invokeCalls("jf_request")).toHaveLength(0);
  });
});

describe("nearSchedule", () => {
  it("reads the next four hours for every channel in one batched request, sorted per channel", async () => {
    await signIn();
    jellyfin([ch("1"), ch("2")], [prog("1", 30, 60, "Later"), prog("1", -10, 30, "Now"), prog("2", 0, 60, "Two")]);
    const by = await lineup.nearSchedule();
    expect(by.get("1")!.map((p) => p.Name)).toEqual(["Now", "Later"]);
    expect(by.get("2")!.map((p) => p.Name)).toEqual(["Two"]);
    expect(programPaths()).toHaveLength(1);
    const q = new URL(`http://x${programPaths()[0]}`).searchParams;
    expect(q.get("channelIds")).toBe("1,2");
    expect(q.get("minEndDate")).toBe(new Date(T0).toISOString());
    expect(q.get("maxStartDate")).toBe(new Date(T0 + 4 * 60 * MIN).toISOString());
  });

  it("uses the cached line-up rather than asking for channels again", async () => {
    await signIn();
    jellyfin([ch("1")], []);
    await lineup.loadLineup();
    await lineup.nearSchedule();
    expect(channelPaths()).toHaveLength(1);
  });

  it("is kept for an hour, then read again", async () => {
    await signIn();
    jellyfin([ch("1")], []);
    await lineup.nearSchedule();
    vi.setSystemTime(T0 + 59 * MIN);
    await lineup.nearSchedule();
    expect(programPaths()).toHaveLength(1);
    vi.setSystemTime(T0 + 61 * MIN);
    await lineup.nearSchedule();
    expect(programPaths()).toHaveLength(2);
  });

  it("force reads again at once; concurrent reads share one request", async () => {
    await signIn();
    jellyfin([ch("1")], []);
    await lineup.nearSchedule();
    await Promise.all([lineup.nearSchedule(true), lineup.nearSchedule(true)]);
    expect(programPaths()).toHaveLength(2);
  });

  it("is read again when the source changes (another cache key)", async () => {
    await signIn();
    jellyfin([ch("1")], []);
    await lineup.nearSchedule();
    const api = await import("../../src/api");
    await api.saveConfig({ livetv_source: "custom", livetv_m3u: "http://tv.test/l.m3u", livetv_xmltv: "http://tv.test/g.xml" });
    serveSources({
      "http://tv.test/l.m3u": '#EXTM3U\n#EXTINF:-1 tvg-id="a",Alpha\nhttp://tv.test/a.m3u8',
      "http://tv.test/g.xml": `<tv><programme start="${xmltvStamp(T0 - 5 * MIN)}" stop="${xmltvStamp(T0 + 25 * MIN)}" channel="a"><title>News</title></programme></tv>`,
    });
    const by = await lineup.nearSchedule();
    const [list] = [...by.values()];
    expect(list!.map((p) => p.Name)).toEqual(["News"]);
  });
});

describe("now and next", () => {
  it("nowNextSync answers from the channel's own CurrentProgram before the schedule is in, and starts a read", async () => {
    await signIn();
    jellyfin([ch("1")], [prog("1", -5, 25, "From schedule"), prog("1", 25, 60, "After")]);
    const c = ch("1", { CurrentProgram: prog("1", -5, 25, "Airing") });
    const first = lineup.nowNextSync(c);
    expect(first.now?.Name).toBe("Airing");
    expect(first.next).toBeNull();
    await vi.waitFor(() => expect(programPaths()).toHaveLength(1));
    await flush();
    const second = lineup.nowNextSync(c);
    expect(second.now?.Name).toBe("From schedule");
    expect(second.next?.Name).toBe("After");
  });

  it("does not start a second read while one is in flight", async () => {
    await signIn();
    const gate = deferred<any>();
    mockJellyfin([
      ["/LiveTv/Channels", { Items: [ch("1")] }],
      ["/LiveTv/Programs", () => gate.promise],
    ]);
    lineup.nowNextSync(ch("1"));
    await vi.waitFor(() => expect(programPaths()).toHaveLength(1));
    lineup.nowNextSync(ch("1"));
    lineup.nowNextSync(ch("1"));
    gate.resolve({ Items: [] });
    await flush();
    expect(programPaths()).toHaveLength(1);
  });

  it("a CurrentProgram that has already ended is not 'now'", () => {
    const c = ch("1", { CurrentProgram: prog("1", -60, -1, "Over") });
    expect(lineup.nowNextSync(c).now).toBeNull();
  });

  it("a channel whose guide has entries does not fall back to CurrentProgram, even with nothing airing", async () => {
    await signIn();
    jellyfin([ch("1")], [prog("1", 30, 60, "Later")]);
    const r = await lineup.nowNext(ch("1", { CurrentProgram: prog("1", -5, 25, "Stale") }));
    expect(r.now).toBeNull();
    expect(r.next?.Name).toBe("Later");
  });

  it("nowNext picks the airing programme and the first one after it", async () => {
    await signIn();
    jellyfin([ch("1")], [prog("1", -60, -30, "Earlier"), prog("1", -30, 10, "Now"), prog("1", 10, 40, "Next"), prog("1", 40, 90, "After")]);
    const r = await lineup.nowNext(ch("1"));
    expect(r.now?.Name).toBe("Now");
    expect(r.next?.Name).toBe("Next");
  });

  it("nowNext for a channel with no guide entries is nothing", async () => {
    await signIn();
    jellyfin([ch("1")], []);
    expect(await lineup.nowNext(ch("9"))).toEqual({ now: null, next: null });
    expect(await lineup.nowNext(null)).toEqual({ now: null, next: null });
  });
});

describe("onNow", () => {
  it("lists channels with something airing, in line-up order, and leaves out the rest", async () => {
    await signIn();
    jellyfin([ch("1"), ch("2"), ch("3")], [prog("3", -5, 20, "Three"), prog("1", -5, 20, "One"), prog("2", 30, 60, "Later")]);
    const r = await lineup.onNow();
    expect(r.map((e) => [e.channel.Id, e.now.Name])).toEqual([
      ["1", "One"],
      ["3", "Three"],
    ]);
  });

  it("stops at the limit", async () => {
    await signIn();
    const chans = ["1", "2", "3", "4"].map((id) => ch(id));
    jellyfin(chans, chans.map((c) => prog(c.Id, -5, 20, c.Id)));
    expect((await lineup.onNow(2)).map((e) => e.channel.Id)).toEqual(["1", "2"]);
  });

  it("is empty with no guide at all", async () => {
    await signIn();
    jellyfin([ch("1")], []);
    expect(await lineup.onNow()).toEqual([]);
  });
});

describe("progressOf and fmtClock", () => {
  it.each([
    [prog("1", -15, 15, "x"), 0.5],
    [prog("1", 5, 15, "x"), 0],
    [prog("1", -30, -10, "x"), 1],
    [prog("1", 10, 10, "x"), 0],
    [{ StartDate: "bad", EndDate: "bad" }, 0],
    [null, 0],
  ])("progressOf(%j) = %j", (p, want) => {
    expect(lineup.progressOf(p)).toBeCloseTo(want);
  });

  it("fmtClock is the local time in hours and minutes", () => {
    const iso = new Date(T0).toISOString();
    expect(lineup.fmtClock(iso)).toBe(new Date(T0).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" }));
  });
});

describe("playChannel", () => {
  it("plays a Jellyfin channel as a live item, quietly", async () => {
    const c = ch("1");
    await lineup.playChannel(c, { continuation: true });
    expect(pb.playItem).toHaveBeenCalledWith(c, { live: true }, { quiet: true, continuation: true });
    expect(pb.playChannelUrl).not.toHaveBeenCalled();
  });

  it("plays a custom channel by its URL, quietly", async () => {
    const c = { Id: "c", Custom: true };
    await lineup.playChannel(c);
    expect(pb.playChannelUrl).toHaveBeenCalledWith(c, { quiet: true, continuation: undefined });
    expect(pb.playItem).not.toHaveBeenCalled();
  });
});

describe("preloadLineup and refreshNow", () => {
  it("does nothing when signed out", async () => {
    lineup.preloadLineup();
    await vi.advanceTimersByTimeAsync(10 * 60_000);
    expect(invokeCalls()).toHaveLength(0);
  });

  it("does nothing for a custom source with no playlist address", async () => {
    await signIn({ livetv_source: "custom", livetv_m3u: "" });
    lineup.preloadLineup();
    await vi.advanceTimersByTimeAsync(10 * 60_000);
    expect(invokeCalls("fetch_source")).toHaveLength(0);
  });

  it("does nothing while offline", async () => {
    const api = await signIn();
    onInvoke("jf_ping", false);
    await api.checkOnline();
    jellyfin([ch("1")], []);
    lineup.preloadLineup();
    await vi.advanceTimersByTimeAsync(10 * 60_000);
    expect(channelPaths()).toHaveLength(0);
  });

  it("loads the line-up and its schedule 2.5 s after launch, after Home's own requests", async () => {
    await signIn();
    jellyfin([ch("1")], [prog("1", -5, 20, "Now")]);
    lineup.preloadLineup();
    await vi.advanceTimersByTimeAsync(2400);
    expect(channelPaths()).toHaveLength(0);
    await vi.advanceTimersByTimeAsync(200);
    await vi.waitFor(() => expect(programPaths()).toHaveLength(1));
    expect(lineup.cachedLineup()).toHaveLength(1);
  });

  it("skips the schedule when there are no channels", async () => {
    await signIn();
    jellyfin([], []);
    lineup.preloadLineup();
    await vi.advanceTimersByTimeAsync(3000);
    await flush();
    expect(channelPaths()).toHaveLength(1);
    expect(programPaths()).toHaveLength(0);
  });

  it("is quiet on failure: a log line, no toast", async () => {
    await signIn();
    mockJellyfin([["/LiveTv/Channels", { __status: 500 }]]);
    lineup.preloadLineup();
    await vi.advanceTimersByTimeAsync(3000);
    await vi.waitFor(() => expect(invokeCalls("ui_log")).toHaveLength(1));
    expect(invokeCalls("ui_log")[0]!.args.msg).toMatch(/^lineup: preload failed: Server error 500/);
  });

  it("a custom source is re-read when its refresh interval has passed, and open views are told", async () => {
    await signIn({ livetv_source: "custom", livetv_m3u: "http://tv.test/l.m3u", livetv_refresh_min: 30 });
    const seen = serveSources({ "http://tv.test/l.m3u": '#EXTM3U\n#EXTINF:-1,Alpha\nhttp://tv.test/a.m3u8' });
    const changed = vi.fn();
    document.addEventListener("aquarium-lineup-changed", changed);
    lineup.preloadLineup();
    lineup.preloadLineup(); // a second call does not start a second timer
    await vi.advanceTimersByTimeAsync(3000);
    expect(seen.urls).toHaveLength(1);
    await vi.advanceTimersByTimeAsync(25 * 60_000); // not due yet at ~25 min
    expect(seen.urls).toHaveLength(1);
    expect(changed).not.toHaveBeenCalled();
    await vi.advanceTimersByTimeAsync(10 * 60_000); // due by the 35-minute check
    await vi.waitFor(() => expect(changed).toHaveBeenCalledTimes(1));
    expect(seen.urls).toHaveLength(2);
    document.removeEventListener("aquarium-lineup-changed", changed);
  });

  it("the refresh check waits while the window is hidden", async () => {
    await signIn({ livetv_source: "custom", livetv_m3u: "http://tv.test/l.m3u", livetv_refresh_min: 30 });
    const seen = serveSources({ "http://tv.test/l.m3u": '#EXTM3U\n#EXTINF:-1,Alpha\nhttp://tv.test/a.m3u8' });
    Object.defineProperty(document, "hidden", { configurable: true, get: () => true });
    try {
      lineup.preloadLineup();
      await vi.advanceTimersByTimeAsync(60 * 60_000);
      expect(seen.urls).toHaveLength(1); // only the launch read
    } finally {
      delete (document as any).hidden;
    }
  });

  it("the refresh check skips a Jellyfin source", async () => {
    await signIn();
    jellyfin([ch("1")], []);
    const changed = vi.fn();
    document.addEventListener("aquarium-lineup-changed", changed);
    lineup.preloadLineup();
    await vi.advanceTimersByTimeAsync(60 * 60_000);
    expect(changed).not.toHaveBeenCalled();
    document.removeEventListener("aquarium-lineup-changed", changed);
  });

  it("refreshNow re-reads the line-up and schedule, and announces the change", async () => {
    await signIn();
    jellyfin([ch("1")], []);
    await lineup.nearSchedule();
    const changed = vi.fn();
    document.addEventListener("aquarium-lineup-changed", changed);
    const r = await lineup.refreshNow();
    expect(r.map((c) => c.Id)).toEqual(["1"]);
    expect(channelPaths()).toHaveLength(2);
    expect(programPaths()).toHaveLength(2);
    expect(changed).toHaveBeenCalledTimes(1);
    document.removeEventListener("aquarium-lineup-changed", changed);
  });

  it("refreshNow for a custom source drops the parsed playlist first, so it is fetched again", async () => {
    await signIn({ livetv_source: "custom", livetv_m3u: "http://tv.test/l.m3u" });
    const seen = serveSources({ "http://tv.test/l.m3u": '#EXTM3U\n#EXTINF:-1,Alpha\nhttp://tv.test/a.m3u8' });
    await lineup.loadLineup();
    await lineup.refreshNow();
    expect(seen.urls.length).toBeGreaterThanOrEqual(2);
  });

  it("refreshNow still announces when the schedule read fails", async () => {
    await signIn();
    mockJellyfin([
      ["/LiveTv/Channels", { Items: [ch("1")] }],
      ["/LiveTv/Programs", { __status: 500 }],
    ]);
    const changed = vi.fn();
    document.addEventListener("aquarium-lineup-changed", changed);
    await lineup.refreshNow();
    expect(changed).toHaveBeenCalledTimes(1);
    document.removeEventListener("aquarium-lineup-changed", changed);
  });
});
