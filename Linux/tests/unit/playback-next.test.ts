// src/playback.ts: what plays next — the user's Up Next queue, the next
// episode (server and downloaded), autoplay at the end of a file, shuffle,
// the in-player episode and quality menus, the uosc message bridge, and the
// per-series audio/subtitle memory.
import { afterEach, describe, expect, it, vi } from "vitest";
import { emitEvent, invokeCalls, jfPaths, onInvoke } from "../helpers/tauri";
import {
  boot,
  download,
  episode,
  errorToasts,
  lastPlay,
  mockServer,
  movie,
  playbackInfos,
  plays,
  recordEvents,
  settle,
  status,
  teardown,
  toasts,
} from "../helpers/playback";

afterEach(teardown);

const played = (): string[] => plays().map((r) => r.ctx.item_id);
const mpv = (): any[][] => invokeCalls("player_mpv_command").map((c) => c.args.cmd);
const menus = (): any[] =>
  mpv()
    .filter((c) => c[0] === "script-message-to" && c[2] === "open-menu")
    .map((c) => JSON.parse(c[3]));
const message = (...args: any[]): void => emitEvent("player-message", args);
const end = (fields: Record<string, any> = {}): void =>
  status({ active: false, ended: true, position: 1000, duration: 1000, ...fields });

const SHOW = {
  show: {
    s1: [episode("e1", 1), episode("e2", 2)],
    s2: [episode("e3", 1, { SeasonId: "s2", ParentIndexNumber: 2 })],
  },
};

describe("the user's Up Next queue", () => {
  it("a queue started while nothing is playing starts at once", async () => {
    const { pb } = await boot();
    mockServer();
    const seen = recordEvents("aquarium-queue-changed");
    expect(await pb.queueNext([movie("a"), movie("b")])).toBe(2);
    await settle();
    expect(played()).toEqual(["a"]);
    expect(pb.getUserQueue().map((q) => q.Id)).toEqual(["b"]);
    expect(seen.length).toBeGreaterThanOrEqual(2);
  });

  it("while something plays, Play Next goes in front and Play Later goes behind, moving a title already queued", async () => {
    const { pb } = await boot();
    mockServer();
    status({ position: 1, duration: 100 });
    await pb.queueLater([movie("a"), movie("b")]);
    await pb.queueNext([movie("c"), movie("b")]);
    expect(pb.getUserQueue().map((q) => q.Id)).toEqual(["c", "b", "a"]);
    await pb.queueLater([movie("c")]);
    expect(pb.getUserQueue().map((q) => q.Id)).toEqual(["b", "a", "c"]);
    expect(played()).toEqual([]);
  });

  it("a season queues its episodes; series, folders and failed seasons add nothing", async () => {
    const { pb } = await boot();
    mockServer({ shows: SHOW });
    status({ position: 1, duration: 100 });
    expect(await pb.queueLater([{ Type: "Season", Id: "s1", SeriesId: "show" }])).toBe(2);
    expect(pb.getUserQueue().map((q) => q.Id)).toEqual(["e1", "e2"]);
    const seen = recordEvents("aquarium-queue-changed");
    expect(await pb.queueNext([{ Type: "Series", Id: "show" }, { Type: "BoxSet", Id: "x" }])).toBe(0);
    expect(await pb.queueLater([{ Type: "Season", Id: "s1" }])).toBe(0);
    onInvoke("jf_request", () => ({ status: 500, body: null }));
    expect(await pb.queueLater([{ Type: "Season", Id: "s2", SeriesId: "show" }])).toBe(0);
    expect(seen).toEqual([]);
    expect(await pb.queueLater([{ Type: "Video", Id: "v" }, { Type: "MusicVideo", Id: "mv" }, episode("e9", 9)])).toBe(3);
  });

  it("removeFromQueue and clearQueue (which says nothing when already empty)", async () => {
    const { pb } = await boot();
    status({ position: 1, duration: 100 });
    await pb.queueLater([movie("a"), movie("b")]);
    pb.removeFromQueue("a");
    expect(pb.getUserQueue().map((q) => q.Id)).toEqual(["b"]);
    const seen = recordEvents("aquarium-queue-changed");
    pb.clearQueue();
    pb.clearQueue();
    expect(pb.getUserQueue()).toEqual([]);
    expect(seen).toHaveLength(1);
  });

  it("playQueued plays one now, passing over those ahead of it, and carries the stream's bitrate", async () => {
    const { pb } = await boot();
    mockServer();
    await pb.playItem(movie("now"), { maxBitrate: 5_000_000 });
    status({ position: 1, duration: 100 });
    await pb.queueLater([movie("a"), movie("b"), movie("c")]);
    const seen = recordEvents("aquarium-player-started");
    await pb.playQueued("b");
    expect(played()).toEqual(["now", "b"]);
    expect(pb.getUserQueue().map((q) => q.Id)).toEqual(["c"]);
    expect(playbackInfos().at(-1)!.body.MaxStreamingBitrate).toBe(5_000_000);
    expect(seen[0]!.detail).toEqual({ inherited: true, continuation: true });
    await pb.playQueued("zzz");
    expect(played()).toHaveLength(2);
  });

  it("playQueued after a downloaded file carries no bitrate and is not inherited", async () => {
    const { pb } = await boot();
    mockServer();
    await pb.playLocal(download("d1"));
    status({ position: 1, duration: 100 });
    await pb.queueLater([movie("a")]);
    const seen = recordEvents("aquarium-player-started");
    await pb.playQueued("a");
    expect(seen[0]!.detail).toEqual({ inherited: false, continuation: true });
  });

  it("is what the Up Next card names, ahead of the series", async () => {
    const { pb } = await boot();
    mockServer({ shows: SHOW });
    await pb.playItem(episode("e1", 1));
    status({ position: 1, duration: 100 });
    await pb.queueLater([movie("film")]);
    expect((await pb.peekNextEpisode()).Id).toBe("film");
  });

  it("plays ahead of the next episode at the end, quietly, as a continuation, even after a film or live TV", async () => {
    const { pb } = await boot();
    mockServer();
    await pb.playItem(movie("ch"), { live: true });
    status({ position: 1 });
    await pb.queueLater([movie("a")]);
    const seen = recordEvents("aquarium-player-started");
    end({ position: 5, duration: 0 });
    expect(pb.isAutoplayPending()).toBe(true);
    await settle();
    expect(played()).toEqual(["ch", "a"]);
    expect(toasts()).toContain("Up next: Film a");
    expect(seen[0]!.detail.continuation).toBe(true);
    expect(pb.isAutoplayPending()).toBe(false);
  });
});

describe("peekNextEpisode", () => {
  it("is null with nothing playing, and for a film", async () => {
    const { pb } = await boot();
    mockServer();
    expect(await pb.peekNextEpisode()).toBeNull();
    await pb.playItem(movie("m1"));
    expect(await pb.peekNextEpisode()).toBeNull();
  });

  it("finds the next episode in the season, then the first of the next season, then nothing", async () => {
    const { pb } = await boot();
    mockServer({ shows: SHOW });
    await pb.playItem(episode("e1", 1));
    expect((await pb.peekNextEpisode()).Id).toBe("e2");
    await pb.playItem(SHOW.show.s1[1]);
    expect((await pb.peekNextEpisode()).Id).toBe("e3");
    await pb.playItem(SHOW.show.s2[0]);
    expect(await pb.peekNextEpisode()).toBeNull();
  });

  it("is looked up once per file, not on every status tick", async () => {
    const { pb } = await boot();
    mockServer({ shows: SHOW });
    await pb.playItem(episode("e1", 1));
    await pb.peekNextEpisode();
    const n = jfPaths().length;
    await pb.peekNextEpisode();
    await pb.peekNextEpisode();
    expect(jfPaths()).toHaveLength(n);
  });

  it("an episode missing from its season's list, in a season the series does not list, has no next", async () => {
    const { pb } = await boot();
    mockServer({ shows: SHOW });
    await pb.playItem(episode("lost", 7, { SeasonId: "nowhere" }));
    expect(await pb.peekNextEpisode()).toBeNull();
  });

  it("a server that fails the lookup means no next episode", async () => {
    const { pb } = await boot();
    mockServer();
    await pb.playItem(episode("e1", 1));
    onInvoke("jf_request", () => ({ status: 500, body: null }));
    expect(await pb.peekNextEpisode()).toBeNull();
  });

  it("names nothing while a shuffle runs (the next draw is not decided yet)", async () => {
    const { pb, state } = await boot();
    state.downloads = [download("d1", { type: "Episode", series: "S" }), download("d2", { type: "Episode", series: "S" })];
    await pb.startLocalShuffle(state.downloads);
    expect(await pb.peekNextEpisode()).toBeNull();
  });

  it("for a file from the Downloads view, finds the next downloaded episode in season and episode order", async () => {
    const { pb, state } = await boot();
    state.downloads = [
      download("b", { type: "Episode", series_id: "S", season: 1, episode: 3 }),
      download("a", { type: "Episode", series_id: "S", season: 1, episode: 1 }),
      download("x", { type: "Episode", series_id: "OTHER", season: 1, episode: 2 }),
      download("c", { type: "Episode", series_id: "S", season: 2, episode: 1 }),
      download("p", { type: "Episode", series_id: "S", season: 1, episode: 2, status: "downloading" }),
    ];
    await pb.playLocal(state.downloads[1]);
    expect((await pb.peekNextEpisode()).item_id).toBe("b");
    await pb.playLocal(state.downloads[0]);
    expect((await pb.peekNextEpisode()).item_id).toBe("c");
    await pb.playLocal(state.downloads[3]);
    expect(await pb.peekNextEpisode()).toBeNull();
  });

  it("matches downloads saved before series_id by the series name, and tells episodes from films the Downloads view's way", async () => {
    const { pb, state } = await boot();
    state.downloads = [
      download("a", { type: "Video", series: "Old Show", season: 1, episode: 1 }),
      download("b", { type: "Video", series: "Old Show", season: 1, episode: 2 }),
      download("m", { type: "Movie", series: "Old Show", season: 1, episode: 3 }),
    ];
    await pb.playLocal(state.downloads[0]);
    expect((await pb.peekNextEpisode()).item_id).toBe("b");
    await pb.playLocal(state.downloads[1]);
    expect(await pb.peekNextEpisode()).toBeNull();
    await pb.playLocal(download("lone", { type: "Movie" }));
    expect(await pb.peekNextEpisode()).toBeNull();
    await pb.playLocal(download("n", { type: "Video" }));
    expect(await pb.peekNextEpisode()).toBeNull();
    await pb.playLocal({ path: "/p" });
    expect(await pb.peekNextEpisode()).toBeNull();
  });

  it("a downloaded file started from a server page walks the server's episode list", async () => {
    const { pb, state } = await boot();
    mockServer({ shows: SHOW });
    state.downloads = [download("e1", { type: "Episode" })];
    await pb.playItem(episode("e1", 1));
    expect(lastPlay().ctx.is_local).toBe(true);
    expect((await pb.peekNextEpisode()).Id).toBe("e2");
  });
});

describe("playNextNow", () => {
  it("is false with nothing playing, and when there is no next episode", async () => {
    const { pb } = await boot();
    mockServer({ shows: SHOW });
    expect(await pb.playNextNow()).toBe(false);
    await pb.playItem(SHOW.show.s2[0]);
    expect(await pb.playNextNow()).toBe(false);
    expect(pb.isAutoplayPending()).toBe(false);
  });

  it("starts the next episode now, with the current bitrate, and is ignored while one is starting", async () => {
    const { pb } = await boot();
    mockServer({ shows: SHOW });
    await pb.playItem(episode("e1", 1), { maxBitrate: 10_000_000 });
    const first = pb.playNextNow();
    expect(pb.isAutoplayPending()).toBe(true);
    expect(await pb.playNextNow()).toBe(false);
    expect(await first).toBe(true);
    expect(played()).toEqual(["e1", "e2"]);
    expect(playbackInfos().at(-1)!.body.MaxStreamingBitrate).toBe(10_000_000);
    expect(toasts()).toContain("Up next: The Show Season 1, Episode 2 · Episode 2");
    expect(pb.isAutoplayPending()).toBe(false);
  });

  it("is what the media keys' Next does", async () => {
    const { pb } = await boot();
    mockServer({ shows: SHOW });
    await pb.playItem(episode("e1", 1));
    emitEvent("mpris-next", null);
    await settle();
    expect(played()).toEqual(["e1", "e2"]);
  });
});

describe("autoplay at the end of a file", () => {
  async function watching(opts: { config?: any; maxBitrate?: number } = {}) {
    const b = await boot({ config: opts.config });
    mockServer({ shows: SHOW });
    await b.pb.playItem(episode("e1", 1), { maxBitrate: opts.maxBitrate });
    return b;
  }

  it("starts the next episode at a natural end, at the same bitrate, and keeps the player up while it does", async () => {
    const { pb } = await watching({ maxBitrate: 5_000_000 });
    const seen = recordEvents("aquarium-player-started", "aquarium-autoplay-none");
    end({ item_id: "e1", position: 950 });
    expect(pb.isAutoplayPending()).toBe(true);
    await settle();
    expect(played()).toEqual(["e1", "e2"]);
    expect(playbackInfos().at(-1)!.body.MaxStreamingBitrate).toBe(5_000_000);
    expect(seen.map((e) => [e.type, e.detail])).toEqual([
      ["aquarium-player-started", { inherited: true, continuation: true }],
    ]);
    expect(pb.isAutoplayPending()).toBe(false);
  });

  it("resumes the next episode from its saved position", async () => {
    const b = await boot();
    mockServer({
      shows: { show: { s1: [episode("e1", 1), episode("e2", 2, { UserData: { PlaybackPositionTicks: 100_000_000 } })] } },
    });
    await b.pb.playItem(episode("e1", 1));
    end();
    await settle();
    expect(lastPlay().start_seconds).toBe(10);
  });

  it("with no next episode, announces that so the player can close", async () => {
    const { pb } = await boot();
    mockServer({ shows: SHOW });
    await pb.playItem(SHOW.show.s2[0]);
    const seen = recordEvents("aquarium-autoplay-none");
    end();
    await settle();
    expect(seen).toHaveLength(1);
    expect(played()).toHaveLength(1);
  });

  it.each([
    ["stopped before 90%", { position: 899 }],
    ["stopped by the user", { requested_stop: true }],
    ["not ended", { ended: false }],
    ["no duration", { duration: 0 }],
    ["another file's end", { item_id: "other" }],
  ])("does nothing when %s", async (_n, fields) => {
    const { pb } = await watching();
    const seen = recordEvents("aquarium-autoplay-none");
    end(fields);
    await settle();
    expect(played()).toEqual(["e1"]);
    expect(seen).toEqual([]);
    expect(pb.isAutoplayPending()).toBe(false);
  });

  it("does nothing after Up Next was dismissed (stop after this one), or when autoplay is off in Settings", async () => {
    const a = await watching();
    a.pb.cancelAutoplay();
    end();
    await settle();
    expect(played()).toEqual(["e1"]);
    // A second app start; the call log runs on from the first.
    await watching({ config: { autoplay_next: false } });
    end();
    await settle();
    expect(played()).toEqual(["e1", "e1"]);
  });

  it("does nothing for a film or a live channel", async () => {
    const { pb } = await boot();
    mockServer();
    await pb.playItem(movie("m1"));
    end();
    await pb.playItem(movie("ch"), { live: true });
    end();
    await settle();
    expect(played()).toEqual(["m1", "ch"]);
  });

  it("a next episode that fails to start is logged and the player is let go", async () => {
    const { pb } = await watching();
    onInvoke("player_play", () => {
      throw new Error("mpv crashed");
    });
    const seen = recordEvents("aquarium-autoplay-none");
    end();
    await settle();
    expect(invokeCalls("ui_log").some((c) => String(c.args.msg).startsWith("autoplay failed"))).toBe(true);
    expect(seen).toHaveLength(1);
    expect(pb.isAutoplayPending()).toBe(false);
  });

  it("a second end while autoplay is starting is ignored", async () => {
    const { pb } = await watching();
    end();
    end();
    await settle();
    expect(played()).toEqual(["e1", "e2"]);
    expect(pb.isAutoplayPending()).toBe(false);
  });

  it("after a downloaded episode from a server page, the next one streams with a fresh bandwidth probe", async () => {
    const { pb, state } = await boot({ probe: 1_000_000_000 });
    mockServer({ shows: SHOW });
    state.downloads = [download("e1", { type: "Episode" })];
    await pb.playItem(episode("e1", 1, { MediaSources: [{ Bitrate: 5_000_000 }] }));
    const probes = invokeCalls("jf_bitrate_test").length;
    const seen = recordEvents("aquarium-player-started");
    end({ item_id: "e1" });
    await settle();
    expect(played()).toEqual(["e1", "e2"]);
    expect(invokeCalls("jf_bitrate_test").length).toBe(probes + 1);
    expect(seen[0]!.detail).toEqual({ inherited: false, continuation: true });
  });

  it("a next episode that is downloaded plays from disk", async () => {
    const { pb, state } = await watching();
    state.downloads = [download("e2", { type: "Episode" })];
    end();
    await settle();
    expect(lastPlay()).toMatchObject({ url: "/downloads/e2.mkv", ctx: { is_local: true } });
    expect(pb.getNowPlayingFull()?.serverItem?.Id).toBe("e2");
  });

  it("from the Downloads view, plays the next downloaded episode, from the top when it was already watched", async () => {
    const { pb, state } = await boot();
    state.downloads = [
      download("a", { type: "Episode", series_id: "S", season: 1, episode: 1, title: "Ep A" }),
      download("b", { type: "Episode", series_id: "S", season: 1, episode: 2, title: "Ep B", position_ticks: 950, run_time_ticks: 1000 }),
      download("c", { type: "Episode", series_id: "S", season: 1, episode: 3, played: true, position_ticks: 500, title: undefined, name: "Ep C" }),
      download("d", { type: "Episode", series_id: "S", season: 1, episode: 4, position_ticks: 300_000_000, run_time_ticks: 36_000_000_000, title: undefined }),
    ];
    await pb.playLocal(state.downloads[0]);
    end({ item_id: "a" });
    await settle();
    expect(lastPlay()).toMatchObject({ ctx: { item_id: "b" }, start_seconds: null });
    expect(toasts()).toContain("Up next: Ep B");
    end({ item_id: "b" });
    await settle();
    expect(lastPlay()).toMatchObject({ ctx: { item_id: "c" }, start_seconds: null });
    expect(toasts()).toContain("Up next: Ep C");
    end({ item_id: "c" });
    await settle();
    // Part-watched (under 90%): resumes.
    expect(lastPlay()).toMatchObject({ ctx: { item_id: "d" }, start_seconds: 30 });
  });

  it("names a next download with no title or name 'next episode'", async () => {
    const { pb, state } = await boot();
    state.downloads = [
      download("a", { type: "Episode", series_id: "S", episode: 1 }),
      download("b", { type: "Episode", series_id: "S", episode: 2, title: undefined }),
    ];
    await pb.playLocal(state.downloads[0]);
    end();
    await settle();
    expect(toasts()).toContain("Up next: next episode");
  });
});

describe("shuffle", () => {
  const eps = (n: number, extra: Record<string, any> = {}) =>
    Array.from({ length: n }, (_, i) =>
      download(`s${i}`, { type: "Episode", series: "Show", series_id: "S", episode: i + 1, ...extra })
    );

  it("says so when there is nothing playable", async () => {
    const { pb } = await boot();
    await pb.startLocalShuffle([download("x", { status: "error" }), download("y", { path: null })]);
    expect(errorToasts()).toEqual(["Nothing to shuffle — no playable downloads"]);
    expect(pb.isShuffling()).toBe(false);
  });

  it("plays a random episode from the top, and draws a new unseen one at each end", async () => {
    const { pb, state } = await boot();
    state.downloads = eps(3, { played: true });
    vi.spyOn(Math, "random").mockReturnValue(0.5);
    await pb.startLocalShuffle(state.downloads);
    expect(toasts()).toEqual(["Shuffling Show · 3 episodes"]);
    expect(pb.isShuffling()).toBe(true);
    expect(lastPlay()).toMatchObject({ ctx: { item_id: "s1" }, start_seconds: null });
    vi.spyOn(Math, "random").mockReturnValue(0);
    end({ item_id: "s1" });
    await settle();
    expect(played()).toEqual(["s1", "s0"]);
    expect(toasts()).toContain("Shuffle: Download s0");
    end({ item_id: "s0" });
    await settle();
    expect(played()).toEqual(["s1", "s0", "s2"]);
    // Every episode has played: reshuffle, never straight back into s2.
    end({ item_id: "s2" });
    await settle();
    expect(played()).toEqual(["s1", "s0", "s2", "s0"]);
    expect(pb.isShuffling()).toBe(true);
  });

  it("keeps going with autoplay turned off in Settings", async () => {
    const { pb, state } = await boot({ config: { autoplay_next: false } });
    state.downloads = eps(2);
    vi.spyOn(Math, "random").mockReturnValue(0);
    await pb.startLocalShuffle(state.downloads);
    end({ item_id: "s0" });
    await settle();
    expect(played()).toEqual(["s0", "s1"]);
  });

  it("names a one-episode series in the singular, and ends when there is nothing to move to", async () => {
    const { pb, state } = await boot();
    state.downloads = eps(1, { series: undefined });
    await pb.startLocalShuffle(state.downloads);
    expect(toasts()).toEqual(["Shuffling series · 1 episode"]);
    const seen = recordEvents("aquarium-autoplay-none");
    end({ item_id: "s0" });
    await settle();
    expect(seen).toHaveLength(1);
    expect(pb.isShuffling()).toBe(false);
  });

  it("re-reads the downloads at each draw, so episodes deleted mid-binge leave it", async () => {
    const { pb, state } = await boot();
    state.downloads = eps(2);
    vi.spyOn(Math, "random").mockReturnValue(0);
    await pb.startLocalShuffle(state.downloads);
    state.downloads = [];
    const seen = recordEvents("aquarium-autoplay-none");
    end({ item_id: "s0" });
    await settle();
    expect(seen).toHaveLength(1);
  });

  it("ends when the user stops, when Up Next is dismissed, or when something else is played", async () => {
    const a = await boot();
    a.state.downloads = eps(3);
    await a.pb.startLocalShuffle(a.state.downloads);
    status({ active: false, requested_stop: true });
    expect(a.pb.isShuffling()).toBe(false);

    await a.pb.startLocalShuffle(a.state.downloads);
    a.pb.cancelAutoplay();
    end();
    expect(a.pb.isShuffling()).toBe(false);

    await a.pb.startLocalShuffle(a.state.downloads);
    a.pb.cancelAutoplay();
    status({ active: false, requested_stop: true });
    expect(a.pb.isShuffling()).toBe(false);

    await a.pb.startLocalShuffle(a.state.downloads);
    await a.pb.playLocal(download("other"));
    expect(a.pb.isShuffling()).toBe(false);

    onInvoke("resolve_stream", "u");
    await a.pb.startLocalShuffle(a.state.downloads);
    await a.pb.playChannelUrl({ Id: "c", Name: "C", StreamUrl: "u" });
    expect(a.pb.isShuffling()).toBe(false);
  });

  it("an end with autoplay cancelled but not ended (mpv idle) leaves the shuffle alone", async () => {
    const { pb, state } = await boot();
    state.downloads = eps(2);
    await pb.startLocalShuffle(state.downloads);
    pb.cancelAutoplay();
    status({ active: false, ended: false });
    expect(pb.isShuffling()).toBe(true);
  });
});

describe("the in-player episode list", () => {
  it("getEpisodeQueue is null for anything that is not an episode", async () => {
    const { pb } = await boot();
    mockServer();
    expect(await pb.getEpisodeQueue()).toBeNull();
    await pb.playItem(movie("m1"));
    expect(await pb.getEpisodeQueue()).toBeNull();
    await pb.playLocal(download("d1", { type: "Episode" }));
    expect(await pb.getEpisodeQueue()).toBeNull();
  });

  it("fetches the season once and keeps it across a quality switch and a hop within the series", async () => {
    const { pb } = await boot();
    mockServer({ shows: SHOW });
    await pb.playItem(episode("e1", 1));
    const q = await pb.getEpisodeQueue();
    expect(q?.current.Id).toBe("e1");
    expect(q?.episodes.map((e) => e.Id)).toEqual(["e1", "e2"]);
    const episodeCalls = () => jfPaths().filter((p) => p.includes("/Episodes")).length;
    const n = episodeCalls();
    await pb.switchQuality(5_000_000);
    await pb.getEpisodeQueue();
    expect(await pb.playQueuedEpisode("e2")).toBe(true);
    await pb.getEpisodeQueue();
    expect(episodeCalls()).toBe(n);
    expect(played()).toEqual(["e1", "e1", "e2"]);
  });

  it("a different series starts a new list", async () => {
    const { pb } = await boot();
    mockServer({ shows: { ...SHOW, other: { o1: [episode("o1e1", 1, { SeriesId: "other", SeasonId: "o1" })] } } });
    await pb.playItem(episode("e1", 1));
    await pb.getEpisodeQueue();
    await pb.playItem(episode("o1e1", 1, { SeriesId: "other", SeasonId: "o1" }));
    expect((await pb.getEpisodeQueue())?.episodes.map((e) => e.Id)).toEqual(["o1e1"]);
  });

  it("a downloaded episode played from its server page keeps its list across the switch to streaming and back", async () => {
    const { pb, state } = await boot();
    mockServer({ shows: SHOW });
    state.downloads = [download("e1", { type: "Episode" })];
    await pb.playItem(episode("e1", 1));
    expect((await pb.getEpisodeQueue())?.episodes).toHaveLength(2);
    const n = jfPaths().filter((p) => p.includes("/Episodes")).length;
    await pb.switchQuality(5_000_000);
    await pb.switchToDownload();
    await pb.getEpisodeQueue();
    expect(jfPaths().filter((p) => p.includes("/Episodes")).length).toBe(n);
  });

  it("a season that cannot be fetched gives an empty list", async () => {
    const { pb } = await boot();
    mockServer();
    await pb.playItem(episode("e1", 1));
    onInvoke("jf_request", () => ({ status: 500, body: null }));
    expect((await pb.getEpisodeQueue())?.episodes).toEqual([]);
  });

  it("playQueuedEpisode is false for an episode not in the list, or with nothing playing", async () => {
    const { pb } = await boot();
    mockServer({ shows: SHOW });
    expect(await pb.playQueuedEpisode("e2")).toBe(false);
    await pb.playItem(episode("e1", 1));
    expect(await pb.playQueuedEpisode("e2")).toBe(false); // list not fetched yet
    await pb.getEpisodeQueue();
    expect(await pb.playQueuedEpisode("nope")).toBe(false);
  });

  it("playQueuedEpisode from a downloaded file passes no bitrate", async () => {
    const { pb, state } = await boot();
    mockServer({ shows: SHOW });
    state.downloads = [download("e1", { type: "Episode" })];
    await pb.playItem(episode("e1", 1));
    await pb.getEpisodeQueue();
    const seen = recordEvents("aquarium-player-started");
    await pb.playQueuedEpisode("e2");
    expect(seen[0]!.detail).toEqual({ inherited: false, continuation: true });
  });

  it("showEpisodeMenu lists the season in the player's own menu", async () => {
    const { pb } = await boot();
    mockServer({
      shows: {
        show: {
          s1: [
            episode("e1", 1, { UserData: { Played: true } }),
            episode("e2", 2),
            episode("e3", undefined as any, { IndexNumber: undefined, ParentIndexNumber: undefined, Name: "Special" }),
          ],
        },
      },
    });
    await pb.playItem(episode("e1", 1, { SeasonName: "Season 1" }));
    await pb.showEpisodeMenu();
    expect(menus()[0]).toEqual({
      title: "The Show — Season 1",
      items: [
        { title: "1. Episode 1", hint: "S01E01 ✓", active: true, value: "script-message aquarium-episode e1" },
        { title: "2. Episode 2", hint: "S01E02", active: false, value: "script-message aquarium-episode e2" },
        { title: "Special", hint: "S00E00", active: false, value: "script-message aquarium-episode e3" },
      ],
    });
  });

  it("showEpisodeMenu names a missing series and season generically, and says when there is no episode", async () => {
    const { pb } = await boot();
    mockServer({ shows: SHOW });
    await pb.showEpisodeMenu();
    expect(menus()[0]).toEqual({
      title: "Up next",
      items: [{ title: "Not playing an episode", value: "ignore", muted: true }],
    });
    await pb.playItem(episode("e1", 1, { SeriesName: undefined }));
    await pb.showEpisodeMenu();
    expect(menus()[1].title).toBe("Episodes — Season");
  });
});

describe("the in-player quality menu", () => {
  it("has nothing to change with nothing playing or on live TV", async () => {
    const { pb } = await boot();
    mockServer();
    await pb.showQualityMenu();
    await pb.playItem(movie("c"), { live: true });
    await pb.showQualityMenu();
    for (const m of menus()) {
      expect(m).toEqual({ title: "Quality", items: [{ title: "Nothing to change", value: "ignore", muted: true }] });
    }
  });

  it("lists the adaptive toggle, the downloaded copy and the ladder, marking what is playing", async () => {
    const { pb, state } = await boot();
    mockServer();
    state.downloads = [download("m1", { quality: "720p · 4.5 Mbps" })];
    await pb.playItem(movie("m1"), { maxBitrate: 10_000_000 }, { stream: true });
    await pb.showQualityMenu();
    const items = menus()[0].items;
    expect(items[0]).toEqual({
      title: "Adapt to the connection: on",
      hint: "drops a rung when the stream stalls",
      value: "script-message aquarium-adaptive toggle",
    });
    expect(items[1]).toEqual({
      title: "Downloaded · 720p · 4.5 Mbps",
      hint: "plays from disk",
      active: false,
      value: "script-message aquarium-quality download",
    });
    expect(items.slice(2).map((i: any) => [i.value, i.active])).toEqual([
      ["script-message aquarium-quality direct", false],
      ["script-message aquarium-quality 35000000", false],
      ["script-message aquarium-quality 18000000", false],
      ["script-message aquarium-quality 10000000", true],
      ["script-message aquarium-quality 5000000", false],
      ["script-message aquarium-quality 2500000", false],
    ]);
  });

  it("while the file plays, the Downloaded row is the active one, and adaptive off says so", async () => {
    const { pb } = await boot();
    pb.setAdaptiveEnabled(false);
    await pb.playLocal(download("d1"));
    await pb.showQualityMenu();
    const items = menus()[0].items;
    expect(items[0].title).toBe("Adapt to the connection: off");
    expect(items[0].hint).toBe("stays where you put it");
    expect(items[1].active).toBe(true);
    expect(items.slice(2).every((i: any) => !i.active)).toBe(true);
  });
});

describe("messages from the player (uosc bridge)", () => {
  it("opens the quality and episode menus", async () => {
    const { pb } = await boot();
    mockServer({ shows: SHOW });
    await pb.playItem(episode("e1", 1));
    message("aquarium-menu", "quality");
    message("aquarium-menu", "episodes");
    message("aquarium-menu", "other");
    await settle();
    expect(menus().map((m) => m.title)).toEqual(["Quality", "The Show — Season"]);
  });

  it("switches quality: a rung, Direct Play, and the downloaded copy", async () => {
    const { pb, state } = await boot();
    mockServer();
    state.downloads = [download("m1")];
    await pb.playItem(movie("m1"), {}, { stream: true });
    message("aquarium-quality", "5000000");
    await settle();
    expect(playbackInfos().at(-1)!.body.MaxStreamingBitrate).toBe(5_000_000);
    message("aquarium-quality", "direct");
    await settle();
    expect(playbackInfos().at(-1)!.body.EnableDirectPlay).toBe(true);
    message("aquarium-quality", "download");
    await settle();
    expect(lastPlay().ctx.is_local).toBe(true);
    // Already on the file: nothing to do.
    const n = plays().length;
    message("aquarium-quality", "download");
    await settle();
    expect(plays()).toHaveLength(n);
  });

  it("says so when the download asked for is not there any more", async () => {
    const { pb } = await boot();
    mockServer();
    await pb.playItem(movie("m1"));
    message("aquarium-quality", "download");
    await settle();
    expect(errorToasts()).toEqual(["The download isn't there anymore"]);
  });

  it("toggles adaptive quality and says which way", async () => {
    const { pb } = await boot();
    message("aquarium-adaptive", "toggle");
    await settle();
    expect(pb.isAdaptiveEnabled()).toBe(false);
    message("aquarium-adaptive", "toggle");
    await settle();
    expect(pb.isAdaptiveEnabled()).toBe(true);
    expect(toasts()).toEqual(["Quality stays where you set it", "Quality will adapt when the connection can't keep up"]);
  });

  it("plays an episode from the list, and a title from the Up Next queue", async () => {
    const { pb } = await boot();
    mockServer({ shows: SHOW });
    await pb.playItem(episode("e1", 1));
    await pb.getEpisodeQueue();
    message("aquarium-episode", "e2");
    await settle();
    status({ position: 1, duration: 100 });
    await pb.queueLater([movie("q1")]);
    message("aquarium-queue-play", "q1");
    await settle();
    expect(played()).toEqual(["e1", "e2", "q1"]);
  });

  it("passes fullscreen, keys, gestures, context clicks and controls on to the player bar", async () => {
    await boot();
    const seen = recordEvents("aquarium-fullscreen-toggle", "aquarium-fullscreen-exit", "aquarium-player-input");
    message("aquarium-fullscreen");
    message("aquarium-fullscreen-exit");
    message("aquarium-key", "RIGHT", "x", "y");
    message("aquarium-gesture", "swipe");
    message("aquarium-context", "100", "200");
    message("aquarium-ctl", "pause");
    message("something-else", "ignored");
    await settle();
    expect(seen.map((e) => [e.type, e.detail])).toEqual([
      ["aquarium-fullscreen-toggle", null],
      ["aquarium-fullscreen-exit", null],
      ["aquarium-player-input", { name: "aquarium-key", arg: "RIGHT", rest: ["x", "y"] }],
      ["aquarium-player-input", { name: "aquarium-gesture", arg: "swipe", rest: [] }],
      ["aquarium-player-input", { name: "aquarium-context", arg: "100", rest: ["200"] }],
      ["aquarium-player-input", { name: "aquarium-ctl", arg: "pause" }],
    ]);
  });

  it("jumps to a chapter", async () => {
    await boot();
    message("aquarium-chapter", "123.5");
    await settle();
    expect(invokeCalls("player_seek")[0]!.args).toEqual({ seconds: 123.5, absolute: true });
  });

  it("the play-local diagnostic hook plays a finished download by id, and ignores one with no file", async () => {
    const { state } = await boot();
    state.downloads = [download("d1"), download("d2", { path: null })];
    emitEvent("player-message", ["aquarium-play-local", "d1"]);
    emitEvent("player-message", ["aquarium-play-local", "d2"]);
    emitEvent("player-message", ["aquarium-play-local", "d3"]);
    await settle();
    expect(played()).toEqual(["d1"]);
  });

  it("a message that is not a list is ignored, and a handler that fails is shown as an error", async () => {
    const { pb } = await boot();
    emitEvent("player-message", "not-a-list");
    mockServer();
    await pb.playItem(movie("m1"));
    onInvoke("jf_request", () => ({ status: 500, body: null }));
    message("aquarium-quality", "5000000");
    await settle();
    expect(errorToasts().some((t) => t.includes("Server error 500"))).toBe(true);
  });
});

describe("remembered audio and subtitle tracks", () => {
  const tracks = (audio: string, sub: string | null, subLang?: string | null) => [
    { id: 1, type: "video", selected: true },
    { id: 1, type: "audio", lang: "eng", selected: audio === "eng" },
    { id: 2, type: "audio", lang: "jpn", selected: audio === "jpn" },
    { id: 1, type: "sub", lang: subLang === undefined ? "eng" : subLang, selected: sub === "eng" },
    { id: 2, type: "sub", lang: "fra", selected: sub === "fra" },
  ];
  const sendTracks = (t: any) => emitEvent("player-tracks", t);
  const saved = () => JSON.parse(localStorage.getItem("aquarium.tracks.show") ?? "null");
  const setTracks = () => invokeCalls("player_set_track").map((c) => c.args);

  async function episodeOne() {
    const b = await boot();
    mockServer({ shows: SHOW });
    await b.pb.playItem(episode("e1", 1));
    return b;
  }

  it("keeps the latest track list for the player bar's panels", async () => {
    const { pb } = await episodeOne();
    sendTracks(tracks("eng", null));
    expect(pb.getTracks()).toHaveLength(5);
    sendTracks("nonsense");
    expect(pb.getTracks()).toEqual([]);
  });

  it("records the choice per series, with subtitles off when none is selected", async () => {
    await episodeOne();
    sendTracks(tracks("eng", null));
    expect(saved()).toEqual({ audio: "eng", sub: "off" });
    sendTracks(tracks("jpn", "fra"));
    expect(saved()).toEqual({ audio: "jpn", sub: "fra" });
  });

  it("re-applies the series' choice to the next episode, then records what that produces", async () => {
    const { pb } = await episodeOne();
    localStorage.setItem("aquarium.tracks.show", JSON.stringify({ audio: "jpn", sub: "fra" }));
    sendTracks(tracks("eng", null));
    expect(setTracks()).toEqual([
      { kind: "audio", track: 2 },
      { kind: "sub", track: 2 },
    ]);
    expect(saved()).toEqual({ audio: "jpn", sub: "fra" });
    // mpv's next list reflects the change; that one is recorded as is.
    sendTracks(tracks("jpn", "fra"));
    expect(setTracks()).toHaveLength(2);
    expect(saved()).toEqual({ audio: "jpn", sub: "fra" });
    // A new file applies again.
    await pb.playItem(episode("e2", 2));
    sendTracks(tracks("eng", "eng"));
    expect(setTracks()).toHaveLength(4);
  });

  it("turns subtitles off when the series was watched without them", async () => {
    await episodeOne();
    localStorage.setItem("aquarium.tracks.show", JSON.stringify({ sub: "off" }));
    sendTracks(tracks("eng", "eng"));
    expect(setTracks()).toEqual([{ kind: "sub", track: "no" }]);
  });

  it("changes nothing that already matches, and records straight away", async () => {
    await episodeOne();
    localStorage.setItem("aquarium.tracks.show", JSON.stringify({ audio: "eng", sub: "off" }));
    sendTracks(tracks("eng", null));
    expect(setTracks()).toEqual([]);
    localStorage.setItem("aquarium.tracks.show", "{}");
    sendTracks(tracks("jpn", "eng"));
    expect(saved()).toEqual({ audio: "jpn", sub: "eng" });
  });

  it("a remembered language the file does not have is left alone", async () => {
    await episodeOne();
    localStorage.setItem("aquarium.tracks.show", JSON.stringify({ audio: "deu", sub: "spa" }));
    sendTracks(tracks("eng", null));
    expect(setTracks()).toEqual([]);
    expect(saved()).toEqual({ audio: "eng", sub: "off" });
  });

  it("a subtitle with no language is recorded as und", async () => {
    await episodeOne();
    sendTracks(tracks("eng", "eng", null));
    expect(saved()).toEqual({ audio: "eng", sub: "und" });
  });

  it("a corrupt saved choice is treated as none", async () => {
    await episodeOne();
    localStorage.setItem("aquarium.tracks.show", "{not json");
    sendTracks(tracks("eng", null));
    expect(saved()).toEqual({ audio: "eng", sub: "off" });
    localStorage.setItem("aquarium.tracks.show", "42");
    sendTracks(tracks("jpn", null));
  });

  it("is not kept for films, downloaded files, or an empty list", async () => {
    const { pb } = await boot();
    mockServer();
    await pb.playItem(movie("m1"));
    sendTracks(tracks("eng", null));
    await pb.playLocal(download("d1", { type: "Episode", series_id: "show" }));
    sendTracks(tracks("eng", null));
    await pb.playItem(episode("e1", 1));
    sendTracks([]);
    expect(Object.keys(localStorage).filter((k) => k.startsWith("aquarium.tracks."))).toEqual([]);
  });

  it("a full localStorage only loses the memory", async () => {
    await episodeOne();
    vi.spyOn(Storage.prototype, "setItem").mockImplementation(() => {
      throw new Error("QuotaExceededError");
    });
    expect(() => sendTracks(tracks("eng", null))).not.toThrow();
  });

  it("a malformed track list never breaks playback", async () => {
    await episodeOne();
    expect(() => sendTracks([null, { type: "audio" }])).not.toThrow();
  });

  it("the list is forgotten when playback ends", async () => {
    const { pb } = await episodeOne();
    sendTracks(tracks("eng", null));
    status({ active: false, requested_stop: true });
    expect(pb.getTracks()).toEqual([]);
  });
});
