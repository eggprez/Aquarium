// api.ts against the live QA server: playback sources. PlaybackInfo with the
// app's mpv device profile, the direct-stream and transcode addresses it
// builds, what the server does with track indexes, a Live TV channel, the
// bandwidth probe, and the download addresses.
//
// No player starts. A transcode's master playlist is asked for (which starts
// no encode) and every play session opened here has its encodes stopped and
// any live stream closed afterwards. Nothing about the account changes:
// PlaybackInfo writes no user data.
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { qa } from "../helpers/qa";
import { authHeader, bridgeCalls, expectCleanBridgeCalls, fx, qaApiFull, stopEncodes } from "../helpers/api-qa";

const opened: { playSessionId?: string; liveStreamId?: string }[] = [];

beforeEach(() => {
  vi.resetModules();
});

afterEach(async () => {
  for (const o of opened.splice(0)) {
    await stopEncodes(o.playSessionId);
    if (o.liveStreamId) await qa!.request(`/LiveStreams/Close?liveStreamId=${encodeURIComponent(o.liveStreamId)}`, "POST");
  }
});

/** Resolve and remember the session so afterEach can close it. */
async function resolve(api: Awaited<ReturnType<typeof qaApiFull>>, id: string, opts: Parameters<typeof api.resolvePlayback>[1] = {}) {
  const src = await api.resolvePlayback(id, opts);
  opened.push({ playSessionId: src.playSessionId, liveStreamId: src.mediaSource?.LiveStreamId });
  return src;
}

/** The first `n` bytes of a stream, asked for the way mpv does: token in the header. */
async function head(url: string, n = 1024): Promise<Response> {
  return fetch(url, { headers: { Authorization: authHeader(), Range: `bytes=0-${n - 1}` } });
}

function query(url: string): URLSearchParams {
  return new URL(url).searchParams;
}

describe.skipIf(!qa)("QA server: resolvePlayback", () => {
  it("direct-streams an H.264/AAC MP4, and the server serves the address it built", async () => {
    const api = await qaApiFull();
    const f = fx("film.long_direct");
    const src = await resolve(api, f.id);
    expect(src.playMethod).toBe("DirectStream");
    expect(src.mediaSourceId).toBe(f.mediaSources[0].id);
    expect(src.playSessionId).toMatch(/^[0-9a-f]{32}$/);
    expect(src.url.startsWith(`${qa!.server}/Videos/${f.id}/stream.`)).toBe(true);
    expect(query(src.url).get("static")).toBe("true");
    expect(query(src.url).get("deviceId")).toBe(qa!.deviceId);
    expect(src.url).not.toMatch(/api_?key|token/i);
    const res = await head(src.url);
    expect(res.status).toBe(206);
    expect(res.headers.get("content-range")).toBe(`bytes 0-1023/${f.mediaSources[0].sizeBytes}`);
    expectCleanBridgeCalls();
  });

  it("direct-plays every fixture film the mpv profile can open (FIXTURES.md mpv column)", async () => {
    const api = await qaApiFull();
    const keys = Object.keys(qa!.fixtures.fixtures).filter((k) => k.startsWith("film."));
    for (const key of keys) {
      const f = fx(key);
      const want = f.mediaSources[0].playback?.mpv?.outcome;
      // film.sidecar_subs is the expected failure below.
      if (want !== "DirectPlay" || key === "film.sidecar_subs") continue;
      const src = await resolve(api, f.id);
      expect(src.playMethod, key).toBe("DirectStream");
      expect(src.mediaSource?.SupportsDirectPlay || src.mediaSource?.SupportsDirectStream, key).toBe(true);
    }
  });

  it("serves the original of every container it direct-streams, MPEG-TS and MKV included", async () => {
    const api = await qaApiFull();
    for (const key of ["film.h264_ts", "film.long_multitrack", "film.pcm_mov"]) {
      const f = fx(key);
      const src = await resolve(api, f.id);
      const res = await head(src.url, 16);
      expect(res.status, `${key} ${src.url}`).toBe(206);
      expect(res.headers.get("content-range"), key).toBe(`bytes 0-15/${f.mediaSources[0].sizeBytes}`);
    }
  });

  it("keeps every audio and subtitle track of a many-track file, so mpv can switch between them (regression: track index needs the source id)", async () => {
    // The Apple app asks the server for a track, and Jellyfin ignores the
    // index without MediaSourceId. The Linux app asks for none: it plays the
    // original and switches tracks in mpv, which needs them all delivered.
    const api = await qaApiFull();
    const f = fx("film.long_multitrack");
    const src = await resolve(api, f.id);
    expect(src.playMethod).toBe("DirectStream");
    const streams = src.mediaSource.MediaStreams;
    const want = f.mediaSources[0].streams;
    expect(streams.filter((s: any) => s.Type === "Audio").map((s: any) => s.Index)).toEqual(
      want.filter((s: any) => s.type === "Audio").map((s: any) => s.index)
    );
    expect(streams.filter((s: any) => s.Type === "Subtitle").map((s: any) => s.Index)).toEqual(
      want.filter((s: any) => s.type === "Subtitle").map((s: any) => s.index)
    );
    // And it never sends an index of its own for the server to drop.
    const body = bridgeCalls().find((c) => c.path.endsWith("/PlaybackInfo"))!.body;
    expect(body).not.toHaveProperty("AudioStreamIndex");
    expect(body).not.toHaveProperty("SubtitleStreamIndex");
  });

  it("is right that a PlaybackInfo track index needs MediaSourceId: without it the server keeps the default", async () => {
    // The server rule behind the Apple regression, checked on the server the
    // suites share, with the Linux transcode profile.
    const api = await qaApiFull();
    const f = fx("film.long_multitrack");
    const forced = await resolve(api, f.id, { forceTranscode: true });
    const profile = bridgeCalls().at(-1)!.body.DeviceProfile;
    const ask = async (extra: Record<string, any>): Promise<string | null> => {
      const r = await qa!.request(`/Items/${f.id}/PlaybackInfo`, "POST", {
        UserId: qa!.userId,
        IsPlayback: true,
        DeviceProfile: profile,
        EnableDirectPlay: false,
        EnableDirectStream: false,
        EnableTranscoding: true,
        ...extra,
      });
      expect(r.status).toBe(200);
      opened.push({ playSessionId: r.body.PlaySessionId });
      return new URL(qa!.server + r.body.MediaSources[0].TranscodingUrl).searchParams.get("AudioStreamIndex");
    };
    expect(query(forced.url).get("AudioStreamIndex")).toBe("1");
    expect(await ask({ AudioStreamIndex: 3 })).toBe("1");
    expect(await ask({ AudioStreamIndex: 3, MediaSourceId: f.mediaSources[0].id })).toBe("3");
  });

  it("transcodes to HLS in TS segments when told to (regression: fMP4 HLS put WebVTT cues 10 s late)", async () => {
    const api = await qaApiFull();
    const f = fx("film.long_multitrack");
    const src = await resolve(api, f.id, { forceTranscode: true, maxBitrate: 4_000_000 });
    expect(src.playMethod).toBe("Transcode");
    const u = new URL(src.url);
    expect(u.origin).toBe(qa!.server);
    expect(u.pathname.toLowerCase()).toMatch(/\/master\.m3u8$/);
    const q = u.searchParams;
    expect(q.get("SegmentContainer")).toBe("ts");
    expect(q.get("VideoCodec")).toBe("h264");
    expect(q.get("MediaSourceId")).toBe(f.mediaSources[0].id);
    expect(q.get("PlaySessionId")).toBe(src.playSessionId);
    expect(Number(q.get("VideoBitrate"))).toBeLessThanOrEqual(4_000_000);
    // The master playlist only describes the stream; asking for it starts no encode.
    const m3u8 = await fetch(src.url, { headers: { Authorization: authHeader() } });
    expect(m3u8.status).toBe(200);
    expect(await m3u8.text()).toMatch(/^#EXTM3U/);
  });

  it("transcodes the first version of a multi-version film when forced", async () => {
    const api = await qaApiFull();
    const src = await resolve(api, fx("film.versions").id, { forceTranscode: true, maxBitrate: 2_000_000 });
    expect(src.playMethod).toBe("Transcode");
    expect(src.mediaSource.TranscodingUrl).toBeTruthy();
  });

  // BUG: the token reaches the webview. api.ts:3-8 says the access token is
  // never in the frontend ("a script that gets into the webview has no
  // credential to steal"), and resolvePlayback strips api_key from the
  // direct-stream address for the same reason (api.ts:1373). But a transcode
  // hands back the server's TranscodingUrl as is (api.ts:1363-1370), and
  // Jellyfin 12.2 puts `ApiKey=<the session's access token>` in it. The token
  // is then in PlaybackSource.url and mediaSource.TranscodingUrl in the
  // webview, in mpv's command line and log, and in the server's access log.
  it.fails("hands the webview no access token in a transcode address", async () => {
    const api = await qaApiFull();
    const src = await resolve(api, fx("film.long_multitrack").id, { forceTranscode: true });
    expect(src.url).not.toContain(qa!.token);
    expect(JSON.stringify(src.mediaSource)).not.toContain(qa!.token);
    expect(query(src.url).has("ApiKey")).toBe(false);
  });

  // BUG: the device profile (api.ts:1327-1335) offers every subtitle format
  // only as "Embed". An HLS transcode cannot embed one, so Jellyfin 12.2
  // falls back to burning the default text track into the picture
  // (`SubtitleMethod=Encode&SubtitleStreamIndex=7`). On any forced transcode
  // ("Try a smaller stream", the quality menu, a slow-link starting rung) the
  // subtitles can then be neither turned off nor changed in mpv.
  it.fails("leaves a text subtitle switchable on a transcode instead of burning it in", async () => {
    const api = await qaApiFull();
    const src = await resolve(api, fx("film.long_multitrack").id, { forceTranscode: true });
    expect(query(src.url).get("SubtitleMethod")).not.toBe("Encode");
  });

  // BUG: the device profile (api.ts:1327-1335) has no "External" subtitle
  // method, so a file that mpv plays as it is but has subtitle files beside it
  // (Film.en.srt, the commonest way subtitles arrive) is transcoded by the
  // server with TranscodeReasons=SubtitleCodecNotSupported and the default
  // sidecar burnt in. With External methods added the same request
  // direct-plays (checked against this server, 2026-11-12).
  it.fails("direct-plays a file with sidecar subtitle files (FIXTURES.md: mpv DirectPlay)", async () => {
    const api = await qaApiFull();
    const f = fx("film.sidecar_subs");
    expect(f.mediaSources[0].playback.mpv.outcome).toBe("DirectPlay");
    const src = await resolve(api, f.id);
    expect(src.playMethod).toBe("DirectStream");
  });

  it("opens a Live TV channel through its stream, marked live, and the server serves it", async () => {
    const api = await qaApiFull();
    const channels = await api.getChannels();
    const ch = channels.find((c) => c.Name === qa!.fixtures.existing.liveTv.channels[0].name)!;
    const src = await resolve(api, ch.Id, { live: true });
    expect(src.live).toBe(true);
    expect(src.url.startsWith(qa!.server)).toBe(true);
    if (src.mediaSource?.LiveStreamId && src.playMethod === "DirectStream") {
      expect(query(src.url).get("liveStreamId")).toBe(src.mediaSource.LiveStreamId);
    }
  });

  it("measures bandwidth through the server's own test payload", async () => {
    const api = await qaApiFull();
    const bps = await api.probeBandwidth(500_000);
    expect(bps).not.toBeNull();
    expect(bps!).toBeGreaterThan(1_000_000);
  });

  it("says when the server has no such item", async () => {
    const api = await qaApiFull();
    await expect(api.resolvePlayback("ffffffffffffffffffffffffffffffff")).rejects.toThrow(/Server error 404/);
  });
});

describe.skipIf(!qa)("QA server: download addresses", () => {
  it("downloads an original byte for byte from /Items/{id}/Download, token in the header only", async () => {
    const api = await qaApiFull();
    const f = fx("film.rated_g");
    const item = await api.getItem(f.id);
    const d = api.buildDownload(item, api.DOWNLOAD_QUALITIES[0]!);
    expect(d.url).toBe(`${qa!.server}/Items/${f.id}/Download`);
    // Jellyfin names an MP4's container "mov,mp4,m4a,..."; the first entry is the extension.
    expect(d.fileName).toBe(`${f.name}.${String(item.MediaSources[0].Container).split(",")[0]}`);
    const res = await head(d.url, 64);
    expect(res.status).toBe(206);
    expect(res.headers.get("content-range")).toBe(`bytes 0-63/${f.mediaSources[0].sizeBytes}`);
    expect((await fetch(d.url, { headers: { Range: "bytes=0-1" } })).status).toBe(401);
  });

  it("keeps the original when the transcode would be no smaller, on real sizes", async () => {
    const api = await qaApiFull();
    // A 20 s, 2 MB film: every transcode rung is bigger than the file.
    const item = await api.getItem(fx("film.rated_g").id);
    for (const q of api.DOWNLOAD_QUALITIES.slice(1)) {
      expect(api.effectiveDownloadQuality(item, q).original, q.label).toBe(true);
    }
    // A 20 min, 155 MB film (about 1 Mbps): even the 480p rung would be bigger.
    const long = await api.getItem(fx("film.long_direct").id);
    const q480 = api.DOWNLOAD_QUALITIES.find((q) => q.name === "480p")!;
    expect(api.estimateDownloadSize(long, q480)!).toBeGreaterThan(fx("film.long_direct").mediaSources[0].sizeBytes);
    expect(api.effectiveDownloadQuality(long, q480).original).toBe(true);
    // The 12 min, 257 MB many-track MKV (about 2.9 Mbps) at 480p is smaller, so the transcode stands.
    const multi = await api.getItem(fx("film.long_multitrack").id);
    expect(api.effectiveDownloadQuality(multi, q480)).toBe(q480);
  });

  it("builds a transcode download the server accepts as a stream address", async () => {
    const api = await qaApiFull();
    const item = await api.getItem(fx("film.long_direct").id);
    const q480 = api.DOWNLOAD_QUALITIES.find((q) => q.name === "480p")!;
    const d = api.buildDownload(item, q480);
    expect(d.fileName).toBe(`${item.Name} (480p).mkv`);
    expect(d.url).not.toMatch(/api_?key|token/i);
    // Not fetched: that would start an encode. The route is the one the
    // server's own Download-as-transcode uses.
    expect(new URL(d.url).pathname).toBe(`/Videos/${item.Id}/stream.mkv`);
  });
});
