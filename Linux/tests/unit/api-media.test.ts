// api.ts: images, the bandwidth probe, playback source resolution, the
// download URL builders and size estimates, the media summary line, and the
// formatting helpers.
//
// No URL built here may carry a token: images are fetched by the webview
// without one, and stream and download URLs are authenticated by the backend
// with an Authorization header (player.rs, downloads.rs).
import { beforeEach, describe, expect, it } from "vitest";
import { fresh, invokeCalls, jfCalls, onInvoke, parsePath, signIn } from "../helpers/api";

beforeEach(fresh);

const SERVER = "http://jf.test:8096";

/** `src/api` with no session at all (nothing signed in). */
async function signedOut(): Promise<typeof import("../../src/api")> {
  onInvoke("config_load", () => ({}));
  const api = await import("../../src/api");
  await api.loadConfig();
  return api;
}

describe("imageUrl", () => {
  it("is null with nobody signed in", async () => {
    const api = await signedOut();
    expect(api.imageUrl({ Id: "a", ImageTags: { Primary: "t" } })).toBeNull();
  });

  it("uses the item's own tag for the type asked for, at the width asked for", async () => {
    const api = await signIn();
    expect(api.imageUrl({ Id: "a", ImageTags: { Primary: "t1", Thumb: "t2" } })).toBe(
      `${SERVER}/Items/a/Images/Primary?maxWidth=400&tag=t1&quality=90`
    );
    expect(api.imageUrl({ Id: "a", ImageTags: { Thumb: "t2" } }, "Thumb", 640)).toBe(
      `${SERVER}/Items/a/Images/Thumb?maxWidth=640&tag=t2&quality=90`
    );
  });

  it("falls back to the series poster for an episode with no Primary of its own", async () => {
    const api = await signIn();
    const ep = { Id: "ep", SeriesId: "ser", SeriesPrimaryImageTag: "st" };
    expect(api.imageUrl(ep)).toBe(`${SERVER}/Items/ser/Images/Primary?maxWidth=400&tag=st&quality=90`);
  });

  it("prefers the item's own Primary over its series poster", async () => {
    const api = await signIn();
    const ep = { Id: "ep", ImageTags: { Primary: "own" }, SeriesId: "ser", SeriesPrimaryImageTag: "st" };
    expect(api.imageUrl(ep)).toContain("/Items/ep/Images/Primary?maxWidth=400&tag=own");
  });

  it("uses PrimaryImageTag on the item itself when there is no series tag", async () => {
    const api = await signIn();
    expect(api.imageUrl({ Id: "x", PrimaryImageTag: "p" })).toBe(
      `${SERVER}/Items/x/Images/Primary?maxWidth=400&tag=p&quality=90`
    );
    // A series tag without a series id is not usable.
    expect(api.imageUrl({ Id: "x", SeriesPrimaryImageTag: "st", PrimaryImageTag: "p" })).toContain("/Items/x/");
  });

  it("takes the first backdrop for Backdrop", async () => {
    const api = await signIn();
    expect(api.imageUrl({ Id: "m", BackdropImageTags: ["b1", "b2"] }, "Backdrop", 1280)).toBe(
      `${SERVER}/Items/m/Images/Backdrop?maxWidth=1280&tag=b1&quality=90`
    );
    expect(api.imageUrl({ Id: "m", BackdropImageTags: [] }, "Backdrop")).toBeNull();
  });

  it("is null when no tag resolves, and never invents one for other types", async () => {
    const api = await signIn();
    expect(api.imageUrl({ Id: "m" })).toBeNull();
    expect(api.imageUrl({ Id: "m", SeriesId: "s", SeriesPrimaryImageTag: "st" }, "Thumb")).toBeNull();
  });

  it("carries no token", async () => {
    const api = await signIn();
    expect(api.imageUrl({ Id: "a", ImageTags: { Primary: "t" } })).not.toMatch(/api_key|token/i);
  });
});

describe("imageHash", () => {
  it("is the BlurHash filed under the same tag imageUrl resolved", async () => {
    const api = await signIn();
    const item = {
      Id: "m",
      BackdropImageTags: ["b1", "b2"],
      ImageBlurHashes: { Backdrop: { b2: "LxOtherxxx", b1: "LKO2?U%2Tw=w" } },
    };
    expect(api.imageHash(item, "Backdrop")).toBe("LKO2?U%2Tw=w");
  });

  it("follows an episode to its series poster's hash (regression: placeholder from other artwork)", async () => {
    const api = await signIn();
    const ep = {
      Id: "ep",
      SeriesId: "ser",
      SeriesPrimaryImageTag: "st",
      ImageBlurHashes: { Primary: { st: "LEHV6nWB2yk8", other: "LotherHash1" } },
    };
    expect(api.imageHash(ep)).toBe("LEHV6nWB2yk8");
  });

  it("is null when the hash is missing, too short to be one, or no tag resolves", async () => {
    const api = await signIn();
    expect(api.imageHash({ Id: "a", ImageTags: { Primary: "t" } })).toBeNull();
    expect(api.imageHash({ Id: "a", ImageTags: { Primary: "t" }, ImageBlurHashes: { Primary: { t: "abc" } } })).toBeNull();
    expect(api.imageHash({ Id: "a", ImageTags: { Primary: "t" }, ImageBlurHashes: { Primary: { t: 42 } } })).toBeNull();
    expect(api.imageHash({ Id: "a", ImageBlurHashes: { Primary: { t: "LEHV6nWB2yk8" } } })).toBeNull();
  });

  it("needs no session: it reads only the item", async () => {
    const api = await signedOut();
    expect(api.imageHash({ Id: "a", ImageTags: { Primary: "t" }, ImageBlurHashes: { Primary: { t: "LEHV6nWB2yk8" } } })).toBe(
      "LEHV6nWB2yk8"
    );
  });
});

describe("logoUrl", () => {
  it("uses the item's own logo", async () => {
    const api = await signIn();
    expect(api.logoUrl({ Id: "m", ImageTags: { Logo: "l" } })).toBe(
      `${SERVER}/Items/m/Images/Logo?maxWidth=640&tag=l&quality=90`
    );
    expect(api.logoUrl({ Id: "m", ImageTags: { Logo: "l" } }, 300)).toContain("maxWidth=300");
  });

  it("gives an episode its series' wordmark through the Parent* tags", async () => {
    const api = await signIn();
    expect(api.logoUrl({ Id: "ep", ParentLogoItemId: "ser", ParentLogoImageTag: "pl" })).toBe(
      `${SERVER}/Items/ser/Images/Logo?maxWidth=640&tag=pl&quality=90`
    );
  });

  it("is null with no logo, half a parent logo, or no session", async () => {
    const api = await signIn();
    expect(api.logoUrl({ Id: "m" })).toBeNull();
    expect(api.logoUrl({ Id: "m", ParentLogoItemId: "ser" })).toBeNull();
    expect(api.logoUrl({ ImageTags: { Logo: "l" } })).toBeNull();
    const out = await (fresh(), signedOut());
    expect(out.logoUrl({ Id: "m", ImageTags: { Logo: "l" } })).toBeNull();
  });
});

describe("seriesPosterUrl and seasonPosterUrl", () => {
  it("builds the series poster from SeriesId and its tag", async () => {
    const api = await signIn();
    expect(api.seriesPosterUrl({ Id: "ep", SeriesId: "ser", SeriesPrimaryImageTag: "st" })).toBe(
      `${SERVER}/Items/ser/Images/Primary?maxWidth=400&tag=st&quality=90`
    );
    expect(api.seriesPosterUrl({ Id: "ep", SeriesId: "ser", SeriesPrimaryImageTag: "st" }, 200)).toContain("maxWidth=200");
  });

  it("is null for something that is not an episode of a tagged series", async () => {
    const api = await signIn();
    expect(api.seriesPosterUrl({ Id: "m" })).toBeNull();
    expect(api.seriesPosterUrl({ Id: "ep", SeriesId: "ser" })).toBeNull();
  });

  it("builds an untagged season poster from SeasonId", async () => {
    const api = await signIn();
    expect(api.seasonPosterUrl({ Id: "ep", SeasonId: "sea" })).toBe(
      `${SERVER}/Items/sea/Images/Primary?maxWidth=400&quality=90`
    );
    expect(api.seasonPosterUrl({ Id: "ep" })).toBeNull();
  });

  it("is null with no session", async () => {
    const api = await signedOut();
    expect(api.seriesPosterUrl({ Id: "ep", SeriesId: "ser", SeriesPrimaryImageTag: "st" })).toBeNull();
    expect(api.seasonPosterUrl({ Id: "ep", SeasonId: "sea" })).toBeNull();
  });
});

describe("probeBandwidth", () => {
  it("asks the backend to time a download of the size given, 1 MB by default", async () => {
    const api = await signIn();
    onInvoke("jf_bitrate_test", () => 42_000_000);
    expect(await api.probeBandwidth()).toBe(42_000_000);
    expect(await api.probeBandwidth(250_000)).toBe(42_000_000);
    expect(invokeCalls("jf_bitrate_test").map((c) => c.args)).toEqual([{ size: 1_000_000 }, { size: 250_000 }]);
  });

  it("is null on any failure, not an error", async () => {
    const api = await signIn();
    onInvoke("jf_bitrate_test", () => {
      throw "offline|Server unreachable";
    });
    expect(await api.probeBandwidth()).toBeNull();
  });
});

describe("resolvePlayback", () => {
  /** Answer PlaybackInfo with this body. */
  function playbackInfo(body: any): void {
    onInvoke("jf_request", { status: 200, body });
  }

  const direct = {
    PlaySessionId: "ps-1",
    MediaSources: [
      {
        Id: "ms-1",
        Container: "mp4",
        SupportsDirectPlay: true,
        SupportsDirectStream: true,
        ETag: "etag-1",
      },
    ],
  };

  it("posts PlaybackInfo for the item with the user, the start position and the device profile", async () => {
    const api = await signIn();
    playbackInfo(direct);
    await api.resolvePlayback("item-1", { startTicks: 123 });
    const [call] = jfCalls();
    expect(call!.path).toBe("/Items/item-1/PlaybackInfo");
    expect(call!.method).toBe("POST");
    const b = call!.body;
    expect(b).toMatchObject({
      UserId: "user-1",
      StartTimeTicks: 123,
      IsPlayback: true,
      AutoOpenLiveStream: true,
      EnableDirectPlay: true,
      EnableDirectStream: true,
      EnableTranscoding: true,
    });
    expect(b.MaxStreamingBitrate).toBeUndefined();
    expect(b.DeviceProfile.MaxStreamingBitrate).toBe(200_000_000);
    expect(b.DeviceProfile.DirectPlayProfiles.map((p: any) => p.Type)).toEqual(["Video", "Audio"]);
    expect(b.DeviceProfile.DirectPlayProfiles[0].Container.split(",")).toEqual(expect.arrayContaining(["mkv", "mp4", "ts", "webm"]));
    // Every subtitle format can stay embedded, and the text ones can also come
    // as files of their own: an HLS transcode cannot embed one, and with
    // Embed alone the server burns the default track in (checked against the
    // QA server, tests/integration/api-playback.test.ts).
    const methods = (f: string) => b.DeviceProfile.SubtitleProfiles.filter((p: any) => p.Format === f).map((p: any) => p.Method);
    for (const f of ["srt", "ass", "ssa", "vtt", "sub"]) expect(methods(f)).toEqual(["Embed", "External"]);
    for (const f of ["pgssub", "dvdsub"]) expect(methods(f)).toEqual(["Embed"]);
    expect(b.DeviceProfile.SubtitleProfiles.every((p: any) => p.Method === "Embed" || p.Method === "External")).toBe(true);
    expect(b.DeviceProfile.SubtitleProfiles.map((p: any) => p.Format)).toEqual(
      expect.arrayContaining(["srt", "ass", "vtt", "pgssub"])
    );
  });

  it("starts at zero unless told otherwise", async () => {
    const api = await signIn();
    playbackInfo(direct);
    await api.resolvePlayback("item-1");
    expect(jfCalls()[0]!.body.StartTimeTicks).toBe(0);
  });

  it("asks for HLS in TS segments without BreakOnNonKeyFrames (regression: black video after seeks in mpv)", async () => {
    const api = await signIn();
    playbackInfo(direct);
    await api.resolvePlayback("item-1");
    const video = jfCalls()[0]!.body.DeviceProfile.TranscodingProfiles.find((p: any) => p.Type === "Video");
    expect(video).toMatchObject({ Container: "ts", Protocol: "hls", VideoCodec: "h264", Context: "Streaming", MinSegments: 1 });
    expect(video).not.toHaveProperty("BreakOnNonKeyFrames");
    const audio = jfCalls()[0]!.body.DeviceProfile.TranscodingProfiles.find((p: any) => p.Type === "Audio");
    expect(audio).toMatchObject({ Container: "mp3", Protocol: "http" });
  });

  it("passes a bitrate cap both at the top level and in the device profile", async () => {
    const api = await signIn();
    playbackInfo(direct);
    await api.resolvePlayback("item-1", { maxBitrate: 8_000_000 });
    const b = jfCalls()[0]!.body;
    expect(b.MaxStreamingBitrate).toBe(8_000_000);
    expect(b.DeviceProfile.MaxStreamingBitrate).toBe(8_000_000);
  });

  it("direct-streams the original with session, source and tag in the URL and no token", async () => {
    const api = await signIn();
    playbackInfo(direct);
    const src = await api.resolvePlayback("item-1");
    expect(src.playMethod).toBe("DirectStream");
    expect(src.mediaSourceId).toBe("ms-1");
    expect(src.playSessionId).toBe("ps-1");
    expect(src.live).toBe(false);
    const { route, params } = parsePath(src.url.slice(SERVER.length));
    expect(src.url.startsWith(SERVER)).toBe(true);
    expect(route).toBe("/Videos/item-1/stream.mp4");
    expect(params).toEqual({
      static: "true",
      mediaSourceId: "ms-1",
      playSessionId: "ps-1",
      deviceId: "device-1",
      Tag: "etag-1",
    });
    expect(src.url).not.toMatch(/api_key|token/i);
  });

  it("hands back the server's media source (regression: 13ea908 stream info panel)", async () => {
    const api = await signIn();
    playbackInfo(direct);
    expect((await api.resolvePlayback("item-1")).mediaSource).toEqual(direct.MediaSources[0]);
  });

  it("names the open live stream and defaults the container to mkv", async () => {
    const api = await signIn();
    playbackInfo({ PlaySessionId: "ps", MediaSources: [{ Id: "ms", SupportsDirectStream: true, LiveStreamId: "live-9" }] });
    const src = await api.resolvePlayback("ch-1");
    const { route, params } = parsePath(src.url.slice(SERVER.length));
    expect(route).toBe("/Videos/ch-1/stream.mkv");
    expect(params.liveStreamId).toBe("live-9");
    expect(params.Tag).toBeUndefined();
  });

  it("transcodes when the server can neither direct-play nor direct-stream", async () => {
    const api = await signIn();
    const ms = { Id: "ms", SupportsDirectPlay: false, SupportsDirectStream: false, TranscodingUrl: "/videos/x/master.m3u8?a=1" };
    playbackInfo({ PlaySessionId: "ps", MediaSources: [ms] });
    const src = await api.resolvePlayback("x");
    expect(src).toEqual({
      url: `${SERVER}/videos/x/master.m3u8?a=1`,
      playMethod: "Transcode",
      mediaSourceId: "ms",
      playSessionId: "ps",
      live: false,
      mediaSource: ms,
    });
  });

  it("takes the server's ApiKey out of every address it hands on, so the token stays out of the webview and mpv", async () => {
    const api = await signIn();
    playbackInfo({
      PlaySessionId: "ps",
      MediaSources: [
        {
          Id: "ms",
          SupportsDirectPlay: false,
          SupportsDirectStream: false,
          TranscodingUrl: "/videos/x/master.m3u8?a=1&ApiKey=tok&b=2",
          MediaStreams: [{ Type: "Subtitle", DeliveryUrl: "/Videos/x/ms/Subtitles/3/0/Stream.srt?api_key=tok" }, { Type: "Audio" }],
        },
      ],
    });
    const src = await api.resolvePlayback("x");
    expect(src.url).toBe(`${SERVER}/videos/x/master.m3u8?a=1&b=2`);
    expect(JSON.stringify(src)).not.toContain("tok");
    expect(api.withoutApiKey("/a?ApiKey=t")).toBe("/a");
    expect(api.withoutApiKey("/a?x=1&apikey=t")).toBe("/a?x=1");
    expect(api.withoutApiKey("/a")).toBe("/a");
  });

  it("lists the subtitles the server sends as files of their own, for the player to add", async () => {
    const api = await signIn();
    playbackInfo({
      PlaySessionId: "ps",
      MediaSources: [
        {
          Id: "ms",
          SupportsDirectPlay: true,
          SupportsDirectStream: true,
          Container: "mp4",
          MediaStreams: [
            { Type: "Video" },
            { Type: "Subtitle", Index: 2, DeliveryMethod: "Embed" },
            { Type: "Subtitle", Index: 3, DeliveryMethod: "Encode" },
            {
              Type: "Subtitle",
              Index: 4,
              DeliveryMethod: "External",
              DeliveryUrl: "/Videos/x/ms/Subtitles/4/0/Stream.srt?ApiKey=tok",
              Language: "eng",
              DisplayTitle: "English - SUBRIP - External",
              IsDefault: true,
              IsForced: false,
            },
            { Type: "Subtitle", Index: 5, DeliveryMethod: "External", DeliveryUrl: "/Videos/x/ms/Subtitles/5/0/Stream.ass", IsForced: true },
          ],
        },
      ],
    });
    const src = await api.resolvePlayback("x");
    expect(src.subtitles).toEqual([
      { url: `${SERVER}/Videos/x/ms/Subtitles/4/0/Stream.srt`, lang: "eng", title: "English - SUBRIP - External", default: true, forced: false },
      { url: `${SERVER}/Videos/x/ms/Subtitles/5/0/Stream.ass`, lang: "", title: "", default: false, forced: true },
    ]);
    playbackInfo({ PlaySessionId: "ps", MediaSources: [{ Id: "ms", SupportsDirectPlay: true, MediaStreams: [{ Type: "Subtitle", DeliveryMethod: "Embed" }] }] });
    expect((await api.resolvePlayback("x")).subtitles).toBeUndefined();
  });

  it("forced transcode offers no direct-play profiles and takes the transcode URL even when direct play is possible", async () => {
    const api = await signIn();
    playbackInfo({
      PlaySessionId: "ps",
      MediaSources: [{ Id: "ms", SupportsDirectPlay: true, SupportsDirectStream: true, TranscodingUrl: "/t.m3u8" }],
    });
    const src = await api.resolvePlayback("x", { forceTranscode: true });
    const b = jfCalls()[0]!.body;
    expect(b.DeviceProfile.DirectPlayProfiles).toEqual([]);
    expect(b.EnableDirectPlay).toBe(false);
    expect(b.EnableDirectStream).toBe(false);
    expect(b.EnableTranscoding).toBe(true);
    expect(src.playMethod).toBe("Transcode");
    expect(src.url).toBe(`${SERVER}/t.m3u8`);
  });

  it("direct-streams when transcoding is called for but the server gave no transcode URL", async () => {
    const api = await signIn();
    playbackInfo({ PlaySessionId: "ps", MediaSources: [{ Id: "ms", SupportsDirectPlay: false, SupportsDirectStream: false }] });
    const src = await api.resolvePlayback("x", { forceTranscode: true });
    expect(src.playMethod).toBe("DirectStream");
  });

  it("plays a live channel through its open stream path even when it could direct-play", async () => {
    const api = await signIn();
    const ms = { Id: "ms", SupportsDirectPlay: true, SupportsDirectStream: true, TranscodingUrl: "/LiveTv/x.m3u8" };
    playbackInfo({ PlaySessionId: "ps", MediaSources: [ms] });
    const src = await api.resolvePlayback("ch", { live: true });
    expect(src).toEqual({
      url: `${SERVER}/LiveTv/x.m3u8`,
      playMethod: "Transcode",
      mediaSourceId: "ms",
      playSessionId: "ps",
      live: true,
      mediaSource: ms,
    });
  });

  it("marks a live channel that direct-streams as live", async () => {
    const api = await signIn();
    playbackInfo({ PlaySessionId: "ps", MediaSources: [{ Id: "ms", SupportsDirectStream: true }] });
    const src = await api.resolvePlayback("ch", { live: true });
    expect(src.playMethod).toBe("DirectStream");
    expect(src.live).toBe(true);
  });

  it("says so when the server returns no media source", async () => {
    const api = await signIn();
    playbackInfo({ PlaySessionId: "ps", MediaSources: [] });
    await expect(api.resolvePlayback("x")).rejects.toThrow("No playable media source returned by the server");
    playbackInfo({});
    await expect(api.resolvePlayback("x")).rejects.toThrow("No playable media source");
  });

  it("passes a server error through", async () => {
    const api = await signIn();
    onInvoke("jf_request", { status: 500, body: null });
    await expect(api.resolvePlayback("x")).rejects.toThrow("Server error 500 on /Items/x/PlaybackInfo");
  });
});

describe("mediaSummary", () => {
  function item(streams: any[], extra: Record<string, any> = {}): any {
    return { MediaSources: [{ MediaStreams: streams, ...extra }] };
  }

  it("reads resolution, codecs, channels, subtitle count and size, in that order", async () => {
    const api = await signIn();
    const size = Math.round(8.4 * 2 ** 30);
    expect(
      api.mediaSummary(
        item(
          [
            { Type: "Video", Height: 1080, Width: 1920, Codec: "hevc" },
            { Type: "Audio", Codec: "eac3", Channels: 6 },
            { Type: "Audio", Codec: "aac", Channels: 2 },
            { Type: "Subtitle" },
            { Type: "Subtitle" },
          ],
          { Size: size }
        )
      )
    ).toEqual(["1080p", "HEVC", "EAC3", "5.1", "2 subtitle tracks", "8.40 GiB"]);
  });

  it("names resolutions the way people say them", async () => {
    const api = await signIn();
    const res = (Height: number, Width = 0): string | undefined =>
      api.mediaSummary(item([{ Type: "Video", Height, Width }]))[0];
    expect(res(2160, 3840)).toBe("4K");
    // A scope film: wide enough for 4K though not tall enough.
    expect(res(1600, 3840)).toBe("4K");
    expect(res(1080)).toBe("1080p");
    expect(res(800)).toBe("720p");
    expect(res(720)).toBe("720p");
    expect(res(576)).toBe("576p");
    expect(res(480)).toBe("480p");
    expect(res(360)).toBe("360p");
    expect(api.mediaSummary(item([{ Type: "Video", Codec: "h264" }]))).toEqual(["H264"]);
  });

  it("names channel layouts, preferring the server's own layout name", async () => {
    const api = await signIn();
    const ch = (a: any): string[] => api.mediaSummary(item([{ Type: "Audio", ...a }]));
    expect(ch({ ChannelLayout: "mono" })).toEqual(["Mono"]);
    expect(ch({ ChannelLayout: "stereo", Channels: 2 })).toEqual(["Stereo"]);
    expect(ch({ ChannelLayout: "5.1(side)", Channels: 6 })).toEqual(["5.1(side)"]);
    expect(ch({ Channels: 8 })).toEqual(["7.1"]);
    expect(ch({ Channels: 6 })).toEqual(["5.1"]);
    expect(ch({ Channels: 2 })).toEqual(["Stereo"]);
    expect(ch({ Channels: 1 })).toEqual(["Mono"]);
    expect(ch({ Channels: 4 })).toEqual([]);
    expect(ch({ ChannelLayout: "", Channels: 2 })).toEqual(["Stereo"]);
  });

  it("says one subtitle track in the singular and leaves out a zero or missing size", async () => {
    const api = await signIn();
    expect(api.mediaSummary(item([{ Type: "Subtitle" }], { Size: 0 }))).toEqual(["1 subtitle track"]);
    expect(api.mediaSummary(item([], { Size: "big" }))).toEqual([]);
    expect(api.mediaSummary(item([], { Size: 2048 }))).toEqual(["2 KiB"]);
  });

  it("is empty for anything with no media source, or no streams", async () => {
    const api = await signIn();
    expect(api.mediaSummary({ Type: "Series" })).toEqual([]);
    expect(api.mediaSummary(null)).toEqual([]);
    expect(api.mediaSummary({ MediaSources: [{}] })).toEqual([]);
  });
});

describe("download sizes and rungs", () => {
  const hour = 3600 * 10_000_000;

  it("lists the rungs largest first, starting with the original", async () => {
    const api = await signIn();
    expect(api.DOWNLOAD_QUALITIES[0]).toEqual({ label: "Original quality", original: true });
    const widths = api.DOWNLOAD_QUALITIES.slice(1).map((q) => q.maxWidth!);
    expect([...widths].sort((a, b) => b - a)).toEqual(widths);
    for (const q of api.DOWNLOAD_QUALITIES.slice(1)) {
      expect(q.videoBitrate).toBeGreaterThan(0);
      expect(q.name).toBeTruthy();
    }
  });

  it("estimates the original exactly from the server's file size", async () => {
    const api = await signIn();
    const orig = api.DOWNLOAD_QUALITIES[0]!;
    expect(api.estimateDownloadSize({ MediaSources: [{ Size: 1234 }], Size: 99 }, orig)).toBe(1234);
    expect(api.estimateDownloadSize({ Size: 99 }, orig)).toBe(99);
    expect(api.estimateDownloadSize({ MediaSources: [{ Size: 0 }] }, orig)).toBeNull();
    expect(api.estimateDownloadSize({}, orig)).toBeNull();
  });

  it("estimates a transcode as video plus audio over the runtime, with 2% overhead", async () => {
    const api = await signIn();
    const q1080 = api.DOWNLOAD_QUALITIES.find((q) => q.name === "1080p")!;
    expect(api.estimateDownloadSize({ RunTimeTicks: hour }, q1080)).toBe(
      Math.round(((9_000_000 + 256_000) / 8) * 3600 * 1.02)
    );
    expect(api.estimateDownloadSize({}, q1080)).toBeNull();
    expect(api.estimateDownloadSize({ RunTimeTicks: hour }, { label: "odd" })).toBeNull();
  });

  it("defaults the audio rate for a rung saved by an older version (regression: restored downloads still build)", async () => {
    const api = await signIn();
    const old = { label: "old", videoBitrate: 1_000_000, maxWidth: 640 };
    expect(api.estimateDownloadSize({ RunTimeTicks: hour }, old)).toBe(Math.round(((1_000_000 + 192_000) / 8) * 3600 * 1.02));
    const url = new URL(api.buildDownload({ Id: "i", Name: "N" }, old).url);
    expect(url.searchParams.get("AudioBitrate")).toBe("192000");
  });

  it("takes the original instead whenever the transcode would be no smaller", async () => {
    const api = await signIn();
    const [orig, q4k] = [api.DOWNLOAD_QUALITIES[0]!, api.DOWNLOAD_QUALITIES[1]!];
    const transcoded = api.estimateDownloadSize({ RunTimeTicks: hour }, q4k)!;
    // A 12 Mbps HEVC remux against the 32 Mbps h264 rung.
    expect(api.effectiveDownloadQuality({ RunTimeTicks: hour, MediaSources: [{ Size: transcoded / 3 }] }, q4k)).toBe(orig);
    expect(api.effectiveDownloadQuality({ RunTimeTicks: hour, MediaSources: [{ Size: transcoded }] }, q4k)).toBe(orig);
    expect(api.effectiveDownloadQuality({ RunTimeTicks: hour, MediaSources: [{ Size: transcoded * 2 }] }, q4k)).toBe(q4k);
  });

  it("keeps the rung asked for when either size is unknown, or when the original was asked for", async () => {
    const api = await signIn();
    const [orig, q720] = [api.DOWNLOAD_QUALITIES[0]!, api.DOWNLOAD_QUALITIES.find((q) => q.name === "720p")!];
    expect(api.effectiveDownloadQuality({ RunTimeTicks: hour }, q720)).toBe(q720);
    expect(api.effectiveDownloadQuality({ MediaSources: [{ Size: 1 }] }, q720)).toBe(q720);
    expect(api.effectiveDownloadQuality({ MediaSources: [{ Size: 1 }] }, orig)).toBe(orig);
  });
});

describe("buildDownload", () => {
  const orig = { label: "Original quality", original: true };

  it("downloads the original from /Items/{id}/Download with no token", async () => {
    const api = await signIn();
    const d = api.buildDownload({ Id: "i1", Name: "Film", MediaSources: [{ Container: "mp4" }] }, orig);
    expect(d).toEqual({ url: `${SERVER}/Items/i1/Download`, fileName: "Film.mp4" });
  });

  it("takes the first entry of a container list as the extension (regression: f1e01de server text in file names)", async () => {
    const api = await signIn();
    expect(api.buildDownload({ Id: "i", Name: "F", MediaSources: [{ Container: "mov,mp4,m4a" }] }, orig).fileName).toBe("F.mov");
    expect(api.buildDownload({ Id: "i", Name: "F", MediaSources: [{ Container: " MKV " }] }, orig).fileName).toBe("F.mkv");
    expect(api.buildDownload({ Id: "i", Name: "F", Container: "avi" }, orig).fileName).toBe("F.avi");
  });

  it("falls back to mkv for a container that is not a plain extension (regression: f1e01de)", async () => {
    const api = await signIn();
    for (const c of ["../../etc/passwd", "a/b", "toolongext", "", "m p4"]) {
      expect(api.buildDownload({ Id: "i", Name: "F", MediaSources: [{ Container: c }] }, orig).fileName, c).toBe("F.mkv");
    }
    expect(api.buildDownload({ Id: "i", Name: "F" }, orig).fileName).toBe("F.mkv");
  });

  it("makes the title safe for a file name and caps its length", async () => {
    const api = await signIn();
    expect(api.buildDownload({ Id: "i", Name: "A/B: C? (2020) [x] it's", Container: "mkv" }, orig).fileName).toBe(
      "A_B_ C_ (2020) [x] it's.mkv"
    );
    expect(api.buildDownload({ Id: "abc", Container: "mkv" }, orig).fileName).toBe("abc.mkv");
    const long = api.buildDownload({ Id: "i", Name: "x".repeat(300), Container: "mkv" }, orig).fileName;
    expect(long).toBe(`${"x".repeat(120)}.mkv`);
  });

  it("builds a static h264/aac transcode at the rung's rates and width, with no token", async () => {
    const api = await signIn();
    const q = api.DOWNLOAD_QUALITIES.find((x) => x.name === "1080p")!;
    const d = api.buildDownload({ Id: "i1", Name: "Film" }, q);
    expect(d.fileName).toBe("Film (1080p).mkv");
    const { route, params } = parsePath(d.url.slice(SERVER.length));
    expect(d.url.startsWith(SERVER)).toBe(true);
    expect(route).toBe("/Videos/i1/stream.mkv");
    expect(params).toEqual({
      static: "false",
      VideoCodec: "h264",
      AudioCodec: "aac",
      VideoBitrate: "9000000",
      AudioBitrate: "256000",
      MaxWidth: "1920",
      deviceId: "device-1",
      Context: "Static",
    });
    expect(d.url).not.toMatch(/api_key|token/i);
  });

  it("names an unnamed rung by its width", async () => {
    const api = await signIn();
    expect(api.buildDownload({ Id: "i", Name: "F" }, { label: "x", videoBitrate: 1, maxWidth: 640 }).fileName).toBe("F (640w).mkv");
  });
});

describe("formatting helpers", () => {
  it("ticksToText", async () => {
    const api = await signIn();
    const min = 600_000_000;
    expect(api.ticksToText()).toBe("");
    expect(api.ticksToText(0)).toBe("");
    expect(api.ticksToText(45 * min)).toBe("45m");
    expect(api.ticksToText(90 * min)).toBe("1h 30m");
    expect(api.ticksToText(120 * min)).toBe("2h 0m");
    expect(api.ticksToText(44.6 * min)).toBe("45m");
  });

  it("remainingText says what is left, or nothing (regression: a963a95 'Resume ( left)')", async () => {
    const api = await signIn();
    const min = 600_000_000;
    expect(api.remainingText(60 * min, 36 * min)).toBe("24m");
    expect(api.remainingText(60 * min)).toBe("1h 0m");
    expect(api.remainingText(undefined, 10 * min)).toBe("");
    expect(api.remainingText(NaN, 10 * min)).toBe("");
    expect(api.remainingText(Infinity, 10 * min)).toBe("");
    expect(api.remainingText(60 * min, 60 * min)).toBe("");
    expect(api.remainingText(60 * min, 70 * min)).toBe("");
  });

  it("secondsToClock", async () => {
    const api = await signIn();
    expect(api.secondsToClock(0)).toBe("0:00");
    expect(api.secondsToClock(59.9)).toBe("0:59");
    expect(api.secondsToClock(65)).toBe("1:05");
    expect(api.secondsToClock(3725)).toBe("1:02:05");
    expect(api.secondsToClock(-5)).toBe("0:00");
    expect(api.secondsToClock(NaN)).toBe("0:00");
    expect(api.secondsToClock(Infinity)).toBe("0:00");
  });

  it("bytesToText", async () => {
    const api = await signIn();
    expect(api.bytesToText(512)).toBe("512 B");
    expect(api.bytesToText(2048)).toBe("2 KiB");
    expect(api.bytesToText(1 << 20)).toBe("1.0 MiB");
    expect(api.bytesToText(1.5 * (1 << 20))).toBe("1.5 MiB");
    expect(api.bytesToText(1 << 30)).toBe("1.00 GiB");
  });

  it("CLIENT_VERSION is a semantic version", async () => {
    const api = await signIn();
    expect(api.CLIENT_VERSION).toMatch(/^\d+\.\d+\.\d+$/);
  });
});
