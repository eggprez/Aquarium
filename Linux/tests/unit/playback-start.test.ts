// src/playback.ts: starting things — playItem (and its bandwidth probe and
// the downloaded-copy shortcut), playChannelUrl, playLocal — the early
// stream for the next title, the "This didn't play" card, quality switches
// and what the player reports about what is on screen.
import { afterEach, describe, expect, it, vi } from "vitest";
import { emitEvent, invokeCalls, jfPaths, onInvoke } from "../helpers/tauri";
import {
  SERVER,
  boot,
  clickDialog,
  dialog,
  dialogButtons,
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
  transcodeUrl,
} from "../helpers/playback";

afterEach(teardown);

const uiLogs = (): string[] => invokeCalls("ui_log").map((c) => c.args.msg);

describe("playItem", () => {
  it("refuses when signed out", async () => {
    const { pb } = await boot({ signedIn: false });
    await expect(pb.playItem(movie())).rejects.toThrow("Not logged in");
  });

  it("direct-plays by default and hands mpv everything it needs to report playback", async () => {
    const { pb } = await boot();
    mockServer();
    const seen = recordEvents("aquarium-player-started");
    await pb.playItem(movie("m1"));
    const req = lastPlay();
    expect(req.url).toMatch(new RegExp(`^${SERVER}/Videos/m1/stream\\.mkv\\?`));
    expect(req.url).not.toContain("api_key");
    expect(req).toMatchObject({
      title: "Film m1",
      start_seconds: null,
      volume: 100,
      ctx: {
        item_id: "m1",
        media_source_id: "ms-m1",
        play_session_id: "ps-m1",
        play_method: "DirectStream",
        server_url: SERVER,
        user_id: "user-1",
        device_id: "device-1",
        is_local: false,
        live: false,
      },
    });
    expect(playbackInfos()[0]!.body).toMatchObject({ EnableDirectPlay: true, StartTimeTicks: 0, UserId: "user-1" });
    expect(toasts()).toEqual(["Starting “Film m1”…"]);
    expect(seen.map((e) => e.detail)).toEqual([{ inherited: false, continuation: false }]);
    expect(pb.getNowPlaying()).toEqual({ item: movie("m1"), isLocal: false });
  });

  it("remembers how the server is sending it, for the stream info panel", async () => {
    const { pb } = await boot();
    mockServer();
    await pb.playItem(movie("m1"), { maxBitrate: 5_000_000 });
    expect(pb.getStreamSource()).toMatchObject({ playMethod: "Transcode", mediaSourceId: "ms-m1" });
  });

  it("sends the media source id with the stream, so the server reports and tracks the right source (cf. the Apple app's track-index bug)", async () => {
    const { pb } = await boot();
    mockServer({ mediaSource: () => ({ Id: "source-B", Container: "mp4", SupportsDirectPlay: true }) });
    await pb.playItem(movie("m1"));
    expect(lastPlay().ctx.media_source_id).toBe("source-B");
    expect(lastPlay().url).toContain("mediaSourceId=source-B");
    expect(lastPlay().url).toContain("/stream.mp4?");
  });

  it("hands mpv the subtitle files the server sends beside the stream, and none when there are none", async () => {
    const { pb } = await boot();
    mockServer();
    await pb.playItem(movie("m0"));
    expect(lastPlay()).not.toHaveProperty("subtitles");
    mockServer({
      mediaSource: (id) => ({
        Id: `ms-${id}`,
        Container: "mp4",
        SupportsDirectPlay: true,
        SupportsDirectStream: true,
        MediaStreams: [
          { Type: "Subtitle", DeliveryMethod: "External", DeliveryUrl: `/Videos/${id}/ms-${id}/Subtitles/1/0/Stream.srt`, Language: "eng", IsDefault: true },
        ],
      }),
    });
    await pb.playItem(movie("m1"));
    expect(lastPlay().subtitles).toEqual([
      { url: `${SERVER}/Videos/m1/ms-m1/Subtitles/1/0/Stream.srt`, lang: "eng", title: "", default: true, forced: false },
    ]);
  });

  it("asks for MPEG-TS HLS segments, which keep subtitle cues in time (cf. the Apple app's fMP4 + WebVTT offset)", async () => {
    const { pb } = await boot();
    mockServer();
    await pb.playItem(movie("m1"), { maxBitrate: 5_000_000 });
    const profile = playbackInfos()[0]!.body.DeviceProfile;
    expect(profile.TranscodingProfiles[0]).toMatchObject({ Container: "ts", Protocol: "hls", Type: "Video" });
    // No HLS subtitle playlists (the WebVTT that went late on fMP4) and no burning in.
    expect(profile.SubtitleProfiles.every((p: any) => p.Method === "Embed" || p.Method === "External")).toBe(true);
  });

  it("resumes from the server's position when asked to", async () => {
    const { pb } = await boot();
    mockServer();
    await pb.playItem(movie("m1", { UserData: { PlaybackPositionTicks: 600_000_000 } }), { resume: true });
    expect(lastPlay().start_seconds).toBe(60);
    expect(playbackInfos()[0]!.body.StartTimeTicks).toBe(600_000_000);
  });

  it("starts at the beginning when the server says the title is played with no position (cf. the QA server's short-title rule)", async () => {
    const { pb } = await boot();
    mockServer();
    await pb.playItem(movie("m1", { UserData: { Played: true, PlaybackPositionTicks: 0 } }), { resume: true });
    expect(lastPlay().start_seconds).toBeNull();
  });

  it("ignores the saved position when resume is turned off in Settings, or when not asked to resume", async () => {
    const { pb } = await boot({ config: { resume_playback: false } });
    mockServer();
    const item = movie("m1", { UserData: { PlaybackPositionTicks: 600_000_000 } });
    await pb.playItem(item, { resume: true });
    expect(lastPlay().start_seconds).toBeNull();
    const on = await boot();
    mockServer();
    await on.pb.playItem(item);
    expect(lastPlay().start_seconds).toBeNull();
  });

  it("an explicit start position wins over resume, and never goes below zero", async () => {
    const { pb } = await boot();
    mockServer();
    const item = movie("m1", { UserData: { PlaybackPositionTicks: 600_000_000 } });
    await pb.playItem(item, { resume: true, startSeconds: 12.5 });
    expect(lastPlay().start_seconds).toBe(12.5);
    await pb.playItem(item, { startSeconds: -4 });
    expect(lastPlay().start_seconds).toBeNull();
  });

  it("a hand-picked bitrate forces a transcode at that cap", async () => {
    const { pb } = await boot();
    mockServer();
    await pb.playItem(movie("m1"), { maxBitrate: 5_000_000 });
    expect(playbackInfos()[0]!.body).toMatchObject({ EnableDirectPlay: false, MaxStreamingBitrate: 5_000_000 });
    expect(lastPlay().url).toBe(SERVER + transcodeUrl("m1", 5_000_000));
    expect(lastPlay().ctx.play_method).toBe("Transcode");
    expect(pb.getNowPlayingFull()).toMatchObject({ maxBitrate: 5_000_000, live: false, isLocal: false });
  });

  it("quiet starts say nothing", async () => {
    const { pb } = await boot();
    mockServer();
    await pb.playItem(movie("m1"), {}, { quiet: true });
    expect(toasts()).toEqual([]);
  });

  it("passes inherited and continuation on to the started event", async () => {
    const { pb } = await boot();
    mockServer();
    const seen = recordEvents("aquarium-player-started");
    await pb.playItem(movie("m1"), { maxBitrate: 5_000_000 }, { inherited: true, continuation: true });
    expect(seen[0]!.detail).toEqual({ inherited: true, continuation: true });
  });

  it("ends a shuffle", async () => {
    const { pb, state } = await boot();
    mockServer();
    state.downloads = [download("e1", { type: "Episode", series: "S" })];
    await pb.startLocalShuffle(state.downloads);
    expect(pb.isShuffling()).toBe(true);
    await pb.playItem(movie("m1"));
    expect(pb.isShuffling()).toBe(false);
  });

  describe("a finished download beats any stream", () => {
    it("plays the file instead, at the resume point, keeping the server item", async () => {
      const { pb, state } = await boot();
      mockServer();
      state.downloads = [download("m1", { quality: "720p · 4.5 Mbps" })];
      const item = movie("m1", { UserData: { PlaybackPositionTicks: 300_000_000 } });
      await pb.playItem(item, { resume: true });
      expect(playbackInfos()).toEqual([]);
      expect(lastPlay()).toMatchObject({ url: "/downloads/m1.mkv", start_seconds: 30, ctx: { is_local: true } });
      expect(toasts()).toEqual(["Starting “Film m1” from downloads…"]);
      expect(pb.getNowPlayingFull()).toMatchObject({ isLocal: true, serverItem: item });
      expect(pb.getQualityState()).toEqual({
        current: undefined,
        isLocal: true,
        live: false,
        sourceBitrate: undefined,
        download: "720p · 4.5 Mbps",
      });
    });

    it("unless the user picked a stream by hand", async () => {
      const { pb, state } = await boot();
      mockServer();
      state.downloads = [download("m1")];
      await pb.playItem(movie("m1"), { maxBitrate: 5_000_000 }, { stream: true });
      expect(playbackInfos()).toHaveLength(1);
      expect(lastPlay().ctx.is_local).toBe(false);
      expect(pb.getQualityState()?.download).toBe("Original quality");
    });

    it("a download that is unfinished, or has no file, does not count", async () => {
      const { pb, state } = await boot();
      mockServer();
      state.downloads = [download("m1", { status: "downloading" }), download("m1", { path: null })];
      await pb.playItem(movie("m1"));
      expect(lastPlay().ctx.is_local).toBe(false);
    });

    it("a failing downloads list just streams", async () => {
      const { pb } = await boot();
      mockServer();
      onInvoke("downloads_list", () => {
        throw "disk";
      });
      await pb.playItem(movie("m1"));
      expect(lastPlay().ctx.is_local).toBe(false);
    });

    it("live TV never looks for one", async () => {
      const { pb } = await boot();
      mockServer();
      await pb.playItem(movie("ch1", { Type: "TvChannel" }), { live: true });
      expect(invokeCalls("downloads_list")).toHaveLength(0);
      expect(lastPlay().ctx.live).toBe(true);
    });
  });

  describe("the starting-bitrate probe", () => {
    it("direct-plays when the connection comfortably covers the source's own bitrate", async () => {
      const { pb } = await boot({ probe: 100_000_000 });
      mockServer();
      await pb.playItem(movie("m1", { MediaSources: [{ Bitrate: 20_000_000 }] }));
      expect(invokeCalls("jf_bitrate_test")[0]!.args).toEqual({ size: 1_000_000 });
      expect(playbackInfos()[0]!.body.EnableDirectPlay).toBe(true);
    });

    it("plans on 70% of the measurement and takes the best rung that fits it", async () => {
      // 20 Mbps measured -> 14 Mbps budget: under the 18 Mbps rung, over the 10.
      const { pb } = await boot({ probe: 20_000_000 });
      mockServer();
      await pb.playItem(movie("m1", { MediaSources: [{ Bitrate: 15_000_000 }] }));
      expect(playbackInfos()[0]!.body).toMatchObject({ EnableDirectPlay: false, MaxStreamingBitrate: 10_000_000 });
      expect(pb.getQualityState()?.current).toBe(10_000_000);
      expect(pb.getQualityState()?.sourceBitrate).toBe(15_000_000);
    });

    it("falls to the smallest rung when even that does not fit", async () => {
      const { pb } = await boot({ probe: 1_000_000 });
      mockServer();
      await pb.playItem(movie("m1", { MediaSources: [{ Bitrate: 8_000_000 }] }));
      expect(playbackInfos()[0]!.body.MaxStreamingBitrate).toBe(2_500_000);
    });

    it("direct-plays when the probe fails", async () => {
      const { pb } = await boot({ probe: null });
      mockServer();
      await pb.playItem(movie("m1", { MediaSources: [{ Bitrate: 8_000_000 }] }));
      expect(playbackInfos()[0]!.body.EnableDirectPlay).toBe(true);
    });

    it("direct-plays an item that carries no bitrate of its own, whatever the probe measures", async () => {
      const { pb } = await boot({ probe: 1_000_000_000 });
      mockServer();
      await pb.playItem(movie("m1"));
      expect(playbackInfos()[0]!.body.EnableDirectPlay).toBe(true);
    });

    it("is skipped for an inherited bitrate, a stream picked by hand, a set bitrate and live TV", async () => {
      const { pb } = await boot({ probe: 1_000_000 });
      mockServer();
      await pb.playItem(movie("a"), {}, { inherited: true });
      await pb.playItem(movie("b"), {}, { stream: true });
      await pb.playItem(movie("c"), { maxBitrate: 5_000_000 });
      await pb.playItem(movie("d"), { live: true });
      expect(invokeCalls("jf_bitrate_test")).toHaveLength(0);
    });

    it("shows the Starting toast before the probe has answered", async () => {
      const { pb } = await boot();
      mockServer();
      let answer!: (v: number) => void;
      onInvoke("jf_bitrate_test", () => new Promise<number>((r) => (answer = r)));
      const p = pb.playItem(movie("m1"));
      await settle();
      expect(toasts()).toEqual(["Starting “Film m1”…"]);
      expect(plays()).toEqual([]);
      answer(500_000_000);
      await p;
      expect(plays()).toHaveLength(1);
    });

    it("a second press while the first is still probing is not overwritten by the first (regression: fast double-press clobbered nowPlaying)", async () => {
      const { pb } = await boot();
      mockServer();
      let answer!: (v: number) => void;
      onInvoke("jf_bitrate_test", () => new Promise<number>((r) => (answer = r)));
      const first = pb.playItem(movie("m1", { MediaSources: [{ Bitrate: 50_000_000 }] }));
      await settle();
      await pb.playItem(movie("m2"), { maxBitrate: 5_000_000 });
      answer(10_000_000);
      await first;
      expect(pb.getNowPlaying()?.item.Id).toBe("m2");
      expect(pb.getNowPlayingFull()?.maxBitrate).toBe(5_000_000);
      expect(lastPlay().ctx.item_id).toBe("m1");
    });
  });

  describe("when it fails", () => {
    it("offers Try Again, a smaller stream and Close, and rethrows", async () => {
      const { pb } = await boot();
      mockServer({ playbackInfoStatus: 500 });
      await expect(pb.playItem(movie("m1"))).rejects.toThrow("Server error 500");
      expect(dialog()?.textContent).toContain("This didn't play");
      expect(dialog()?.textContent).toContain("Server error 500 on /Items/m1/PlaybackInfo");
      expect(dialogButtons()).toEqual(["Try Again", "Try a Smaller Stream", "Close"]);
    });

    it("rethrows, logs and tells the user", async () => {
      const { pb } = await boot();
      mockServer({ playbackInfoStatus: 500 });
      await expect(pb.playItem(movie("m1"))).rejects.toThrow("Server error 500");
      expect(uiLogs().some((m) => m.startsWith("playItem FAILED"))).toBe(true);
      expect(toasts().length + (dialog() ? 1 : 0)).toBeGreaterThan(1);
    });

    it("a failure after something else has started only says so in a toast", async () => {
      const { pb } = await boot();
      let fail!: (e: any) => void;
      mockServer();
      onInvoke("player_play", (a: any) =>
        a.req.ctx.item_id === "m1" ? new Promise((_r, j) => (fail = j)) : null
      );
      const first = pb.playItem(movie("m1"));
      await settle();
      await pb.playItem(movie("m2"));
      fail(new Error("mpv gave up"));
      await expect(first).rejects.toThrow("mpv gave up");
      expect(dialog()).toBeNull();
      expect(errorToasts()).toEqual(["Playback failed: mpv gave up"]);
    });
  });
});

describe("the player reporting a failure", () => {
  it("shows the card with mpv's error, and announces that nothing comes next", async () => {
    const { pb } = await boot();
    mockServer();
    await pb.playItem(movie("m1"), { maxBitrate: 10_000_000 });
    status({ position: 30, duration: 600 });
    const seen = recordEvents("aquarium-autoplay-none");
    status({ active: false, ended: true, error: "loading failed", position: 30, duration: 600 });
    expect(dialog()?.textContent).toContain("loading failed");
    expect(seen).toHaveLength(1);
    // Try Again picks up at the last position mpv reported.
    clickDialog("Try Again");
    await settle();
    expect(lastPlay().start_seconds).toBe(30);
  });

  it("offers a smaller stream one rung below the bitrate that failed", async () => {
    const { pb } = await boot();
    mockServer();
    await pb.playItem(movie("m1"), { maxBitrate: 10_000_000 });
    status({ position: 40, duration: 600 });
    status({ active: false, ended: true, error: "too slow", position: 40, duration: 600 });
    expect(dialogButtons()).toEqual(["Try Again", "Try a Smaller Stream", "Close"]);
    clickDialog("Try a Smaller Stream");
    await settle();
    expect(playbackInfos().at(-1)!.body.MaxStreamingBitrate).toBe(5_000_000);
    expect(lastPlay().start_seconds).toBe(40);
  });

  it("from Direct Play the smaller stream is the 18 Mbps rung (it passes over the 35 Mbps transcode)", async () => {
    const { pb } = await boot();
    mockServer();
    await pb.playItem(movie("m1"));
    status({ active: false, ended: true, error: "x" });
    clickDialog("Try a Smaller Stream");
    await settle();
    expect(playbackInfos().at(-1)!.body.MaxStreamingBitrate).toBe(18_000_000);
  });

  it("at the smallest rung there is nothing smaller to offer, and Try Again is the default", async () => {
    const { pb } = await boot();
    mockServer();
    await pb.playItem(movie("m1"), { maxBitrate: 2_500_000 });
    status({ active: false, ended: true, error: "x" });
    expect(dialogButtons()).toEqual(["Try Again", "Close"]);
    expect(document.querySelector(".dialog .btn.primary")?.textContent).toBe("Try Again");
  });

  it("live TV from the server gets Try Again but no smaller stream, and starts from the live edge", async () => {
    const { pb } = await boot();
    mockServer();
    await pb.playItem(movie("ch", { Type: "TvChannel" }), { live: true });
    status({ position: 500 });
    status({ active: false, ended: true, error: "x" });
    expect(dialogButtons()).toEqual(["Try Again", "Close"]);
    clickDialog("Try Again");
    await settle();
    expect(lastPlay()).toMatchObject({ start_seconds: null, ctx: { live: true } });
  });

  it("a fallback to reading the address as a playlist reads as a failure too", async () => {
    const { pb } = await boot();
    mockServer();
    await pb.playItem(movie("m1"));
    status({ active: false, ended: true, reason: "redirect" });
    expect(dialog()?.textContent).toContain("The stream couldn't be opened.");
  });

  it("an error in the last 2% is just the end of the file", async () => {
    const { pb } = await boot();
    mockServer();
    await pb.playItem(movie("m1"));
    status({ active: false, ended: true, error: "eof glitch", position: 99, duration: 100 });
    expect(dialog()).toBeNull();
  });

  it("a stop the user asked for is never an error", async () => {
    const { pb } = await boot();
    mockServer();
    await pb.playItem(movie("m1"));
    status({ active: false, ended: true, requested_stop: true, error: "interrupted" });
    expect(dialog()).toBeNull();
  });

  it("with nothing known about what was playing, only Close is offered", async () => {
    await boot();
    status({ active: false, ended: true, error: "boom" });
    expect(dialogButtons()).toEqual(["Close"]);
  });

  it("Try Again on a downloaded file plays the file again from the last position", async () => {
    const { pb } = await boot();
    await pb.playLocal(download("d1"));
    status({ position: 75, duration: 1000 });
    status({ active: false, ended: true, error: "read error", position: 75, duration: 1000 });
    expect(dialogButtons()).toEqual(["Try Again", "Close"]);
    clickDialog("Try Again");
    await settle();
    expect(lastPlay()).toMatchObject({ url: "/downloads/d1.mkv", start_seconds: 75 });
  });

  it("Try Again on a playlist channel tunes it again", async () => {
    const { pb } = await boot();
    onInvoke("resolve_stream", (a: any) => a.url + "#resolved");
    await pb.playChannelUrl({ Id: "c1", Name: "News", StreamUrl: "http://iptv/1" });
    status({ active: false, ended: true, error: "dead" });
    clickDialog("Try Again");
    await settle();
    expect(invokeCalls("resolve_stream")).toHaveLength(2);
    expect(plays()).toHaveLength(2);
  });
});

describe("playChannelUrl", () => {
  it("points mpv straight at the provider with the configured User-Agent and no server in the context", async () => {
    const { pb } = await boot({ config: { livetv_user_agent: "TestAgent/1" } });
    onInvoke("resolve_stream", () => "http://iptv/1/live.ts");
    const seen = recordEvents("aquarium-player-started");
    await pb.playChannelUrl({ Id: "c1", Name: "News", StreamUrl: "http://iptv/1" }, { continuation: true });
    expect(invokeCalls("resolve_stream")[0]!.args).toEqual({ url: "http://iptv/1", userAgent: "TestAgent/1" });
    expect(lastPlay()).toEqual({
      url: "http://iptv/1/live.ts",
      title: "News",
      start_seconds: null,
      volume: 100,
      user_agent: "TestAgent/1",
      ctx: { item_id: "c1", is_local: false, live: true },
    });
    expect(seen[0]!.detail).toEqual({ continuation: true });
    expect(toasts()).toEqual(["Starting “News”…"]);
    expect(pb.getQualityState()).toMatchObject({ live: true, isLocal: false });
  });

  it("says it is still waiting after 5 s, and not after the channel has come up", async () => {
    const { pb } = await boot();
    let answer!: (u: string) => void;
    onInvoke("resolve_stream", () => new Promise<string>((r) => (answer = r)));
    const p = pb.playChannelUrl({ Id: "c1", Name: "News", StreamUrl: "u" });
    await vi.advanceTimersByTimeAsync(5_000);
    expect(toasts()).toContain("Still waiting for “News” to start…");
    answer("resolved");
    await p;
    const quick = await boot();
    onInvoke("resolve_stream", "resolved");
    await quick.pb.playChannelUrl({ Id: "c1", Name: "News", StreamUrl: "u" });
    await vi.advanceTimersByTimeAsync(6_000);
    expect(toasts()).not.toContain("Still waiting for “News” to start…");
  });

  it("a quiet caller (the tuning screen) gets no toasts at all", async () => {
    const { pb } = await boot();
    let answer!: (u: string) => void;
    onInvoke("resolve_stream", () => new Promise<string>((r) => (answer = r)));
    const p = pb.playChannelUrl({ Id: "c1", Name: "News", StreamUrl: "u" }, { quiet: true });
    await vi.advanceTimersByTimeAsync(10_000);
    answer("x");
    await p;
    expect(toasts()).toEqual([]);
  });

  it("does not start a channel the user has moved on from while it was coming up", async () => {
    const { pb } = await boot();
    mockServer();
    let answer!: (u: string) => void;
    onInvoke("resolve_stream", () => new Promise<string>((r) => (answer = r)));
    const p = pb.playChannelUrl({ Id: "c1", Name: "News", StreamUrl: "u" });
    await settle();
    await pb.playItem(movie("m1"));
    answer("x");
    await p;
    expect(plays().map((r) => r.ctx.item_id)).toEqual(["m1"]);
  });

  it("reports a channel that will not start, and rethrows", async () => {
    const { pb } = await boot();
    onInvoke("resolve_stream", () => {
      throw new Error("503 from provider");
    });
    await expect(pb.playChannelUrl({ Id: "c1", Name: "News", StreamUrl: "u" })).rejects.toThrow("503");
    expect(errorToasts()).toEqual(["Playback failed: 503 from provider"]);
    await vi.advanceTimersByTimeAsync(6_000);
    expect(toasts()).not.toContain("Still waiting for “News” to start…");
  });

  it("names an unnamed channel Live TV", async () => {
    const { pb } = await boot();
    onInvoke("resolve_stream", "x");
    await pb.playChannelUrl({ Id: "c1", StreamUrl: "u" });
    expect(lastPlay().title).toBe("Live TV");
  });
});

describe("playLocal", () => {
  it("plays the file with its saved position, its real runtime and enough context to sync progress", async () => {
    const { pb } = await boot();
    const seen = recordEvents("aquarium-player-started");
    await pb.playLocal(download("d1", { position_ticks: 450_000_000, run_time_ticks: 36_000_000_000 }));
    expect(lastPlay()).toEqual({
      url: "/downloads/d1.mkv",
      title: "Download d1",
      start_seconds: 45,
      known_duration_seconds: 3600,
      volume: 100,
      ctx: {
        item_id: "d1",
        is_local: true,
        live: false,
        server_url: SERVER,
        user_id: "user-1",
        device_id: "device-1",
      },
    });
    expect(seen[0]!.detail).toEqual({ inherited: false, continuation: false });
    expect(pb.getQualityState()).toMatchObject({ isLocal: true, current: undefined, download: "Original quality" });
  });

  it("gives a transcoded download (no duration in the container) its runtime, and leaves it out when unknown", async () => {
    const { pb } = await boot();
    await pb.playLocal(download("d1", { run_time_ticks: 0 }));
    expect(lastPlay().known_duration_seconds).toBeNull();
  });

  it("an explicit start overrides the saved position", async () => {
    const { pb } = await boot();
    await pb.playLocal(download("d1", { position_ticks: 450_000_000 }), { startSeconds: 0 });
    expect(lastPlay().start_seconds).toBeNull();
  });

  it("works signed out (offline), with no server in the context", async () => {
    const { pb } = await boot({ signedIn: false });
    await pb.playLocal(download("d1", { name: "Named", title: undefined }));
    expect(lastPlay().ctx).toMatchObject({ server_url: null, user_id: null, device_id: null });
    expect(lastPlay().title).toBe("Named");
  });

  it("falls back to a generic title", async () => {
    const { pb } = await boot();
    await pb.playLocal({ item_id: "x", path: "/p" });
    expect(lastPlay().title).toBe("Downloaded item");
  });

  it("a player that will not start is reported, not thrown", async () => {
    const { pb } = await boot();
    onInvoke("player_play", () => {
      throw new Error("no mpv");
    });
    await expect(pb.playLocal(download("d1"))).resolves.toBeUndefined();
    expect(errorToasts()).toEqual(["Playback failed: no mpv"]);
  });
});

describe("quality switches", () => {
  it("switchQuality restarts the stream at the new bitrate from the last reported position, as a continuation", async () => {
    const { pb } = await boot();
    mockServer();
    await pb.playItem(movie("m1"));
    status({ position: 120.5, duration: 6000 });
    const seen = recordEvents("aquarium-player-started");
    const probes = invokeCalls("jf_bitrate_test").length;
    await pb.switchQuality(5_000_000);
    expect(playbackInfos().at(-1)!.body).toMatchObject({ MaxStreamingBitrate: 5_000_000, StartTimeTicks: 1_205_000_000 });
    expect(lastPlay().start_seconds).toBe(120.5);
    expect(seen[0]!.detail).toEqual({ inherited: false, continuation: true });
    expect(invokeCalls("jf_bitrate_test")).toHaveLength(probes);
  });

  it("a smaller stream keeps the audio track mpv was playing (regression: the transcode carried the file's default)", async () => {
    const { pb } = await boot();
    const streams = [
      { Index: 0, Type: "Video" },
      { Index: 1, Type: "Audio", Language: "eng" },
      { Index: 3, Type: "Audio", Language: "fra" },
    ];
    mockServer({
      mediaSource: (id, body) => ({
        Id: `ms-${id}`,
        Container: "mkv",
        SupportsDirectPlay: true,
        SupportsDirectStream: true,
        MediaStreams: streams,
        ...(body.EnableDirectPlay === false ? { TranscodingUrl: transcodeUrl(id, body.MaxStreamingBitrate) } : {}),
      }),
    });
    await pb.playItem(movie("m1"), {}, { stream: true });
    expect(playbackInfos()[0]!.body).not.toHaveProperty("AudioStreamIndex");
    emitEvent("player-tracks", [
      { id: 1, type: "audio", lang: "eng", "ff-index": 1, selected: false },
      { id: 2, type: "audio", lang: "fra", "ff-index": 3, selected: true },
    ]);
    await pb.switchQuality(5_000_000);
    expect(playbackInfos().at(-1)!.body).toMatchObject({ MediaSourceId: "ms-m1", AudioStreamIndex: 3 });
    // On the transcode mpv sees one track; the choice made before it stands.
    emitEvent("player-tracks", [{ id: 1, type: "audio", lang: "fra", "ff-index": 1, selected: true }]);
    await pb.switchQuality(2_000_000);
    expect(playbackInfos().at(-1)!.body).toMatchObject({ MediaSourceId: "ms-m1", AudioStreamIndex: 3 });
    // Direct play gets every track; nothing is asked for.
    await pb.switchQuality(undefined);
    expect(playbackInfos().at(-1)!.body).not.toHaveProperty("AudioStreamIndex");
  });

  it("asks for no audio track when mpv's pick does not match the source's streams", async () => {
    const { pb } = await boot();
    mockServer({
      mediaSource: (id, body) => ({
        Id: `ms-${id}`,
        SupportsDirectPlay: true,
        SupportsDirectStream: true,
        MediaStreams: [{ Index: 1, Type: "Audio", Language: "eng" }, { Index: 2, Type: "Subtitle" }],
        ...(body.EnableDirectPlay === false ? { TranscodingUrl: transcodeUrl(id, body.MaxStreamingBitrate) } : {}),
      }),
    });
    await pb.playItem(movie("m1"), {}, { stream: true });
    emitEvent("player-tracks", [{ id: 1, type: "audio", lang: "fra", "ff-index": 1, selected: true }]);
    await pb.switchQuality(5_000_000);
    expect(playbackInfos().at(-1)!.body).not.toHaveProperty("AudioStreamIndex");
    emitEvent("player-tracks", [{ id: 1, type: "audio", "ff-index": 2, selected: true }]);
    await pb.switchQuality(undefined);
    await pb.switchQuality(5_000_000);
    expect(playbackInfos().at(-1)!.body).not.toHaveProperty("AudioStreamIndex");
  });

  it("switching to Direct Play passes no bitrate", async () => {
    const { pb } = await boot();
    mockServer();
    await pb.playItem(movie("m1"), { maxBitrate: 5_000_000 });
    await pb.switchQuality(undefined);
    expect(playbackInfos().at(-1)!.body.EnableDirectPlay).toBe(true);
  });

  it("streams even when a download exists (the user asked for a stream)", async () => {
    const { pb, state } = await boot();
    mockServer();
    state.downloads = [download("m1")];
    await pb.playItem(movie("m1"));
    expect(lastPlay().ctx.is_local).toBe(true);
    status({ position: 50, duration: 6000 });
    await pb.switchQuality(10_000_000);
    expect(lastPlay()).toMatchObject({ start_seconds: 50, ctx: { is_local: false } });
  });

  it("from a file started on the Downloads page, fetches its server item first", async () => {
    const { pb } = await boot();
    mockServer({ items: { d1: movie("d1", { Name: "Fetched" }) } });
    await pb.playLocal(download("d1"));
    status({ position: 10, duration: 100 });
    await pb.switchQuality(5_000_000);
    expect(jfPaths().some((p) => p.startsWith("/Items/d1?userId=user-1"))).toBe(true);
    expect(lastPlay()).toMatchObject({ title: "Fetched", start_seconds: 10, ctx: { is_local: false } });
  });

  it("from a file, gives up if something else started while the item was being fetched", async () => {
    const { pb } = await boot();
    let answer!: (v: any) => void;
    mockServer();
    onInvoke("jf_request", (a: any) =>
      a.path.startsWith("/Items/d1?") ? new Promise((r) => (answer = r)) : { status: 200, body: {} }
    );
    await pb.playLocal(download("d1"));
    const p = pb.switchQuality(5_000_000);
    await settle();
    await pb.playLocal(download("d2"));
    answer({ status: 200, body: movie("d1") });
    await p;
    expect(plays().map((r) => r.ctx.item_id)).toEqual(["d1", "d2"]);
  });

  it("live TV switches without a start position", async () => {
    const { pb } = await boot();
    mockServer();
    await pb.playItem(movie("ch", { Type: "TvChannel" }), { live: true });
    status({ position: 300 });
    await pb.switchQuality(5_000_000);
    expect(lastPlay().start_seconds).toBeNull();
  });

  it("does nothing when nothing is playing", async () => {
    const { pb } = await boot();
    await pb.switchQuality(5_000_000);
    expect(plays()).toEqual([]);
  });

  it("switchToDownload goes back to the file at the same position", async () => {
    const { pb, state } = await boot();
    mockServer();
    state.downloads = [download("m1")];
    const item = movie("m1");
    await pb.playItem(item, { maxBitrate: 5_000_000 }, { stream: true });
    status({ position: 200, duration: 6000 });
    const seen = recordEvents("aquarium-player-started");
    expect(await pb.switchToDownload({ inherited: true })).toBe(true);
    expect(lastPlay()).toMatchObject({ url: "/downloads/m1.mkv", start_seconds: 200 });
    expect(seen[0]!.detail).toEqual({ inherited: true, continuation: true });
    expect(pb.getNowPlayingFull()?.serverItem).toBe(item);
    expect(uiLogs().some((m) => m.startsWith("quality-switch to download m1"))).toBe(true);
  });

  it("switchToDownload is false, and forgets the download, when it has been deleted since", async () => {
    const { pb, state } = await boot();
    mockServer();
    state.downloads = [download("m1")];
    await pb.playItem(movie("m1"), {}, { stream: true });
    state.downloads = [];
    expect(await pb.switchToDownload()).toBe(false);
    expect(pb.getQualityState()?.download).toBeUndefined();
  });

  it("switchToDownload is false with no download, for a file, for live TV and with nothing playing", async () => {
    const { pb } = await boot();
    mockServer();
    expect(await pb.switchToDownload()).toBe(false);
    await pb.playItem(movie("m1"));
    expect(await pb.switchToDownload()).toBe(false);
    await pb.playLocal(download("d1"));
    expect(await pb.switchToDownload()).toBe(false);
    await pb.playItem(movie("c"), { live: true });
    expect(await pb.switchToDownload()).toBe(false);
  });

  it("switchToDownload gives up if something else started meanwhile", async () => {
    const { pb, state } = await boot();
    mockServer();
    state.downloads = [download("m1")];
    await pb.playItem(movie("m1"), {}, { stream: true });
    let answer!: (v: any) => void;
    onInvoke("downloads_list", () => new Promise((r) => (answer = r)));
    const p = pb.switchToDownload();
    await settle();
    await pb.playLocal(download("other"));
    answer([download("m1")]);
    expect(await p).toBe(false);
  });
});

describe("what is on screen", () => {
  it("everything is null before anything plays", async () => {
    const { pb } = await boot();
    expect(pb.getQualityState()).toBeNull();
    expect(pb.getNowPlaying()).toBeNull();
    expect(pb.getNowPlayingFull()).toBeNull();
    expect(pb.getStreamSource()).toBeNull();
    expect(pb.getTracks()).toEqual([]);
    expect(pb.isAutoplayPending()).toBe(false);
  });

  it("getQualityState reports the source bitrate of the server item, and ignores a nonsense one", async () => {
    const { pb } = await boot();
    mockServer();
    await pb.playItem(movie("m1", { MediaSources: [{ Bitrate: 0 }] }), { maxBitrate: 5_000_000 });
    expect(pb.getQualityState()).toEqual({
      current: 5_000_000,
      isLocal: false,
      live: false,
      sourceBitrate: undefined,
      download: undefined,
    });
  });

  it("the quality ladder runs best-first, about 2x apart", async () => {
    const { pb } = await boot();
    expect(pb.QUALITY_CHOICES.map((q) => q.maxBitrate)).toEqual([
      undefined,
      35_000_000,
      18_000_000,
      10_000_000,
      5_000_000,
      2_500_000,
    ]);
  });
});

describe("opening the next stream early", () => {
  const show = { show: { s1: [episode("e1", 1), episode("e2", 2)] } };

  async function nearTheEnd(opts: { maxBitrate?: number } = {}) {
    const b = await boot();
    mockServer({ shows: show });
    await b.pb.playItem(episode("e1", 1), opts, { inherited: true });
    return b;
  }

  it("about 90 s before the end, resolves the next episode and opens its stream on the server", async () => {
    const { pb } = await nearTheEnd({ maxBitrate: 10_000_000 });
    status({ position: 920, duration: 1000 });
    await settle();
    expect(playbackInfos().map((p) => p.itemId)).toEqual(["e1", "e2"]);
    expect(playbackInfos()[1]!.body.MaxStreamingBitrate).toBe(10_000_000);
    expect(invokeCalls("player_warm")[0]!.args).toEqual({ url: SERVER + transcodeUrl("e2", 10_000_000) });
    // Autoplay reaches it: the source is reused rather than asked for again.
    status({ active: false, ended: true, position: 1000, duration: 1000 });
    await settle();
    expect(playbackInfos().map((p) => p.itemId)).toEqual(["e1", "e2"]);
    expect(lastPlay()).toMatchObject({ url: SERVER + transcodeUrl("e2", 10_000_000), ctx: { item_id: "e2" } });
  });

  it("is tried once per file, and not before 90 s or in the last 5 s", async () => {
    const { pb } = await nearTheEnd();
    status({ position: 800, duration: 1000 });
    status({ position: 996, duration: 1000 });
    await settle();
    expect(invokeCalls("player_warm")).toHaveLength(0);
    status({ position: 950, duration: 1000 });
    status({ position: 960, duration: 1000 });
    await settle();
    expect(invokeCalls("player_warm")).toHaveLength(1);
    expect(pb.getNowPlaying()?.item.Id).toBe("e1");
  });

  it("is not reused when the next start asks for something different", async () => {
    const { pb } = await nearTheEnd({ maxBitrate: 10_000_000 });
    status({ position: 950, duration: 1000 });
    await settle();
    await pb.playItem(episode("e2", 2), { maxBitrate: 5_000_000 });
    expect(playbackInfos().map((p) => p.itemId)).toEqual(["e1", "e2", "e2"]);
  });

  it("is asked for again when older than ten minutes", async () => {
    const { pb } = await nearTheEnd();
    status({ position: 950, duration: 1000 });
    await settle();
    await vi.advanceTimersByTimeAsync(10 * 60_000 + 1);
    await pb.playItem(episode("e2", 2), {}, { inherited: true });
    expect(playbackInfos().map((p) => p.itemId)).toEqual(["e1", "e2", "e2"]);
  });

  it("is skipped when the next episode is downloaded, autoplay is cancelled, for live TV, or with no duration", async () => {
    const a = await nearTheEnd();
    a.state.downloads = [download("e2")];
    status({ position: 950, duration: 1000 });
    await settle();
    expect(invokeCalls("player_warm")).toHaveLength(0);

    const b = await nearTheEnd();
    b.pb.cancelAutoplay();
    status({ position: 950, duration: 1000 });
    await settle();
    expect(invokeCalls("player_warm")).toHaveLength(0);

    const c = await boot();
    mockServer();
    await c.pb.playItem(movie("ch"), { live: true });
    status({ position: 950, duration: 1000 });
    status({ position: 950 });
    await settle();
    expect(invokeCalls("player_warm")).toHaveLength(0);
  });

  it("a failed resolve or a failed warm-up is logged and nothing else", async () => {
    const { pb } = await nearTheEnd();
    onInvoke("player_warm", () => {
      throw "warm refused";
    });
    status({ position: 950, duration: 1000 });
    await settle();
    expect(uiLogs()).toContain("prefetch warm failed: warm refused");

    const b = await boot();
    mockServer({ shows: show, playbackInfoStatus: 500 });
    onInvoke("jf_request", (a: any) =>
      /PlaybackInfo/.test(a.path) && a.path.includes("/e2/")
        ? { status: 500, body: null }
        : a.path.includes("/Episodes")
          ? { status: 200, body: { Items: show.show.s1 } }
          : { status: 200, body: { PlaySessionId: "p", MediaSources: [{ Id: "ms", SupportsDirectPlay: true }] } }
    );
    await b.pb.playItem(episode("e1", 1), {}, { inherited: true });
    status({ position: 950, duration: 1000 });
    await settle();
    expect(uiLogs().some((m) => m.startsWith("prefetch failed:"))).toBe(true);
    expect(dialog()).toBeNull();
  });

  it("a fresh file after the end may be prefetched again", async () => {
    const { pb } = await nearTheEnd();
    status({ position: 950, duration: 1000 });
    await settle();
    status({ active: false, requested_stop: true });
    await pb.playItem(episode("e1", 1), {}, { inherited: true });
    status({ position: 950, duration: 1000 });
    await settle();
    expect(invokeCalls("player_warm")).toHaveLength(2);
  });

  it("the result is dropped if playback moved on while it was being resolved", async () => {
    const { pb } = await nearTheEnd();
    let answer!: (v: any) => void;
    const inner = (a: any) =>
      a.path.includes("/e2/PlaybackInfo")
        ? new Promise((r) => (answer = r))
        : a.path.includes("/Episodes")
          ? { status: 200, body: { Items: show.show.s1 } }
          : { status: 200, body: { PlaySessionId: "p", MediaSources: [{ Id: "ms-x", SupportsDirectPlay: true }] } };
    onInvoke("jf_request", inner);
    status({ position: 950, duration: 1000 });
    await settle();
    await pb.playItem(movie("m9"), {}, { inherited: true });
    answer({ status: 200, body: { PlaySessionId: "p", MediaSources: [{ Id: "ms-e2", SupportsDirectPlay: true }] } });
    await settle();
    expect(invokeCalls("player_warm")).toHaveLength(0);
  });
});
