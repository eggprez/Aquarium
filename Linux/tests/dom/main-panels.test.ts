// src/main.ts: the panels that open inside the player bar (the only surface
// the embedded video leaves), each opened from its button.
import { afterEach, describe, expect, it, vi } from "vitest";
import { emitEvent, flush, invokeCalls, onInvoke } from "../helpers/tauri";
import {
  bootPlayer,
  buttonNamed,
  CHANNEL,
  click,
  EP1,
  EP3,
  EPISODE,
  fakeTimers,
  MOVIE,
  panel,
  propSets,
  sendTracks,
  settle,
  startPlaying,
  teardownShell,
  toasts,
} from "../helpers/main-shell";

afterEach(teardownShell);

const $ = (id: string): HTMLElement => document.getElementById(id)!;

function open(btn: string): HTMLElement {
  click($(btn));
  return panel()!;
}

function pick(label: string): void {
  click(buttonNamed(label, panel()!));
}

function notes(): string[] {
  return [...(panel()?.querySelectorAll(".pb-panel-note") ?? [])].map((n) => n.textContent ?? "");
}

function primaries(): string[] {
  return [...(panel()?.querySelectorAll("button.primary") ?? [])].map((b) => b.textContent ?? "");
}

describe("panel frame", () => {
  it("opens one panel at a time inside the bar, with its label and a Close", async () => {
    await startPlaying();
    const p = open("pb-subs");
    expect(p.parentElement).toBe($("player-bar"));
    expect(p.dataset.panel).toBe("subs");
    expect(p.querySelector(".pb-panel-label")!.textContent).toBe("Subtitles");
    open("pb-audio");
    expect(document.querySelectorAll(".pb-panel")).toHaveLength(1);
    expect(panel()!.dataset.panel).toBe("audio");
    // The same button again closes it.
    click($("pb-audio"));
    expect(panel()).toBeNull();
    open("pb-audio");
    click(panel()!.querySelector(".pb-panel-close")!);
    expect(panel()).toBeNull();
  });
});

describe("audio and subtitle tracks", () => {
  it("lists each audio track by title, language or number, the playing one lit, and switches", async () => {
    await startPlaying();
    sendTracks([
      { id: 1, type: "audio", lang: "eng", selected: true },
      { id: 2, type: "audio", lang: "jpn", title: "Commentary" },
      { id: 3, type: "audio" },
      { id: 4, type: "audio", lang: "xx" },
      { id: 5, type: "audio", lang: "123" },
      { id: 6, type: "audio", lang: "und" },
    ]);
    open("pb-audio");
    const labels = [...panel()!.querySelectorAll("button:not(.pb-panel-close)")].map((b) => b.textContent);
    // A tag Intl can't name (or "und", which names nothing) is shown as it
    // came; a track with no tag at all gets its number.
    expect(labels).toEqual(["English", "Commentary", "Track 3", "xx", "123", "und"]);
    expect(primaries()).toEqual(["English"]);
    pick("Commentary");
    expect(panel()).toBeNull();
    expect(invokeCalls("player_set_track").at(-1)!.args).toEqual({ kind: "audio", track: 2 });
  });

  it("says when no audio tracks have been reported", async () => {
    await startPlaying();
    open("pb-audio");
    expect(notes()).toEqual(["No audio tracks reported yet"]);
  });

  it("toasts a failed switch", async () => {
    await startPlaying();
    sendTracks([{ id: 1, type: "audio", lang: "eng" }, { id: 3, type: "sub", lang: "eng" }]);
    onInvoke("player_set_track", () => Promise.reject("no player"));
    open("pb-audio");
    pick("English");
    open("pb-subs");
    pick("English");
    open("pb-subs");
    pick("Off");
    await flush();
    expect(toasts()).toEqual(["no player", "no player", "no player"]);
  });

  it("lists subtitles with Off first, lit when none is on", async () => {
    await startPlaying();
    sendTracks([{ id: 3, type: "sub", lang: "fre" }, { id: 4, type: "sub", title: "Signs" }]);
    open("pb-subs");
    expect(primaries()).toEqual(["Off"]);
    pick("Signs");
    expect(invokeCalls("player_set_track").at(-1)!.args).toEqual({ kind: "sub", track: 4 });
    sendTracks([{ id: 3, type: "sub", lang: "fre", selected: true }]);
    open("pb-subs");
    expect(primaries()).toEqual(["French"]);
    pick("Off");
    expect(invokeCalls("player_set_track").at(-1)!.args).toEqual({ kind: "sub", track: "no" });
  });

  it("says when the file has no subtitles, still offering Off", async () => {
    await startPlaying();
    open("pb-subs");
    expect(notes()).toEqual(["No subtitles for this file"]);
    expect(primaries()).toEqual(["Off"]);
  });
});

describe("speed and delays", () => {
  it("sets speed, steps subtitle and audio delay, and keeps its readouts in step with mpv", async () => {
    const shell = await startPlaying();
    shell.status({ speed: 1, sub_delay: 0, audio_delay: 0 });
    const p = open("pb-tune");
    expect(p.classList.contains("pb-tune")).toBe(true);
    expect(primaries()).toEqual(["Normal"]);
    pick("1.5×");
    expect(propSets("speed")).toEqual([1.5]);
    shell.status({ speed: 1.5 });
    expect(primaries()).toEqual(["1.5×"]);

    const values = () => [...p.querySelectorAll(".pb-panel-value")].map((v) => v.textContent);
    expect(values()).toEqual(["0.0s", "0 ms"]);
    const minus = [...p.querySelectorAll("button")].filter((b) => b.textContent === "−");
    const plus = [...p.querySelectorAll("button")].filter((b) => b.textContent === "+");
    const resets = [...p.querySelectorAll("button")].filter((b) => b.textContent === "Reset");
    click(plus[0]!);
    click(minus[0]!);
    expect(propSets("sub-delay")).toEqual([0.1, -0.1]);
    click(resets[0]!);
    expect(propSets("sub-delay").at(-1)).toBe(0);
    shell.status({ sub_delay: 0.3 });
    expect(values()[0]).toBe("+0.3s");
    shell.status({ sub_delay: -0.2 });
    expect(values()[0]).toBe("-0.2s");

    // Audio delay: each press a step, the readout follows at once, and the
    // press is quiet (the panel is the readout).
    click(plus[1]!);
    expect(values()[1]).toBe("+50 ms");
    click(plus[1]!);
    expect(values()[1]).toBe("+100 ms");
    click(minus[1]!);
    expect(values()[1]).toBe("+50 ms");
    click(resets[1]!);
    expect(values()[1]).toBe("0 ms");
    expect(propSets("audio-delay")).toEqual([0.05, 0.1, 0.05, 0]);
    expect($("pb-state").textContent).not.toContain("Audio delay");
    shell.status({ audio_delay: -0.25 });
    expect(values()[1]).toBe("-250 ms");
  });
});

describe("picture", () => {
  it("adjusts each control live from where Settings left it, and resets everything", async () => {
    await startPlaying({ config: { pic_brightness: 12, pic_gamma: "junk", video_zoom: 0.15 } });
    const p = open("pb-picture");
    const slider = (label: string) => p.querySelector<HTMLInputElement>(`input[aria-label="${label}"]`)!;
    const valueOf = (label: string) => (slider(label).nextElementSibling as HTMLElement).textContent;
    expect(slider("Brightness").value).toBe("12");
    expect(valueOf("Brightness")).toBe("+12");
    // (12 + 50) / 100 of the track.
    expect(slider("Brightness").style.getPropertyValue("--fill")).toBe("62%");
    expect(slider("Gamma").value).toBe("0");
    expect(slider("Zoom").value).toBe("15");
    expect(valueOf("Zoom")).toBe("15%");

    slider("Contrast").value = "-7";
    slider("Contrast").dispatchEvent(new Event("input"));
    expect(valueOf("Contrast")).toBe("-7");
    expect(propSets("contrast")).toEqual([-7]);
    slider("Zoom").value = "40";
    slider("Zoom").dispatchEvent(new Event("input"));
    expect(propSets("video-zoom")).toEqual([0.4]);
    expect(slider("Zoom").style.getPropertyValue("--fill")).toBe("100%");

    pick("Reset");
    for (const prop of ["brightness", "contrast", "saturation", "gamma"]) expect(propSets(prop).at(-1)).toBe(0);
    expect(propSets("video-zoom").at(-1)).toBe(0);
    expect(slider("Brightness").value).toBe("0");
    expect(valueOf("Brightness")).toBe("0");
    expect(valueOf("Zoom")).toBe("0%");
  });

  it("starts from zero when the zoom in the config is not a number", async () => {
    await startPlaying({ config: { video_zoom: "x" } });
    const p = open("pb-picture");
    expect(p.querySelector<HTMLInputElement>('input[aria-label="Zoom"]')!.value).toBe("0");
  });
});

describe("sleep", () => {
  it("stops at the end of this episode, and can be told not to", async () => {
    const shell = await startPlaying();
    open("pb-sleep");
    expect(primaries()).toEqual([]);
    pick("End of episode");
    expect(shell.playback.isAutoplayCancelled()).toBe(true);
    // The panel is rebuilt to show it.
    expect(primaries()).toEqual(["End of episode"]);
    pick("End of episode");
    expect(shell.playback.isAutoplayCancelled()).toBe(false);
    expect(primaries()).toEqual([]);
  });

  it("sets a timer, says how long is left, and cancels it", async () => {
    const shell = await startPlaying();
    fakeTimers();
    open("pb-sleep");
    pick("15m");
    expect(toasts()).toContain("Playback will stop in 15 minutes");
    expect(notes()).toEqual(["Stopping in 15 minutes"]);
    vi.advanceTimersByTime(14.5 * 60_000);
    click($("pb-sleep"));
    open("pb-sleep");
    expect(notes()).toEqual(["Stopping in under a minute"]);
    pick("Cancel");
    expect(toasts()).toContain("Sleep timer cancelled");
    expect(notes()).toEqual([]);
    expect(shell.playback.sleepDeadline()).toBeNull();
  });
});

describe("chapters", () => {
  it("says when the file has none", async () => {
    await startPlaying();
    open("pb-chapters-btn");
    expect(notes()).toEqual(["This file has no chapters"]);
  });

  it("lists the chapters from the start, lights the one playing, and jumps to one", async () => {
    const shell = await startPlaying({}, { position: 400, duration: 1500, chapters: [{ time: 300, title: "Middle" }, { time: 900, title: "" }] });
    const p = open("pb-chapters-btn");
    const buttons = [...p.querySelectorAll<HTMLButtonElement>("button.pb-chapter")];
    expect(buttons.map((b) => b.textContent)).toEqual(["0:00Chapter 1", "5:00Middle", "15:00Chapter 3"]);
    expect(primaries()).toEqual(["5:00Middle"]);
    // Half a second early still counts as in it.
    shell.status({ position: 899.6 });
    expect(primaries()).toEqual(["15:00Chapter 3"]);
    click(buttons[0]!);
    expect(panel()).toBeNull();
    expect(invokeCalls("player_seek").at(-1)!.args).toEqual({ seconds: 0, absolute: true });
  });
});

describe("stream info", () => {
  const PROPS = {
    "file-format": "mkv",
    "video-format": "hevc",
    "container-fps": "23.976000",
    "audio-codec-name": "eac3",
    "audio-params/channel-count": "6",
    "audio-params/samplerate": "48000",
    "video-params/w": "1920",
    "video-params/h": "1080",
    "video-bitrate": "7000000",
    "audio-bitrate": "640000",
    "hwdec-current": "vaapi",
    "current-vo": "libmpv",
    "demuxer-cache-duration": "41.6",
    "cache-speed": "2500000",
  };

  function cells(): Record<string, string> {
    const out: Record<string, string> = {};
    for (const c of panel()!.querySelectorAll(".pb-info-cell")) {
      out[c.querySelector(".pb-info-label")!.textContent!] = c.querySelector(".pb-info-value")!.textContent!;
    }
    return out;
  }

  async function infoFor(props: Record<string, any>, status: Record<string, any> = {}): Promise<Record<string, string>> {
    await startPlaying({ invokes: { player_get_properties: props } }, status);
    open("pb-info");
    await settle();
    return cells();
  }

  it("lists what the stream is and how it is going", async () => {
    const c = await infoFor(PROPS, { dropped_frames: 3 });
    expect(c).toMatchObject({
      Container: "mkv",
      Video: "HEVC · 23.976 fps",
      Audio: "EAC3 · 6 ch · 48 kHz",
      Resolution: "1920×1080",
      Bitrate: "7.6 Mbps · arriving at 20.0 Mbps",
      Engine: "mpv 0.41 · vo=libmpv",
      Decoder: "Hardware (vaapi)",
      Buffer: "42 s ahead",
      Stalls: "0",
      "Dropped frames": "3",
    });
  });

  it("counts stalls in this file, and refreshes its live values with the status", async () => {
    let props: Record<string, any> = PROPS;
    const shell = await startPlaying({ invokes: { player_get_properties: () => props } });
    emitEvent("player-stall", {});
    emitEvent("player-stall", {});
    open("pb-info");
    await settle();
    expect(cells().Stalls).toBe("2");
    props = { ...PROPS, "hwdec-current": "no" };
    shell.status({ dropped_frames: 9 });
    await settle();
    expect(cells().Decoder).toBe("Software (CPU)");
    expect(cells()["Dropped frames"]).toBe("9");
  });

  it("fills dashes for what mpv could not say, and reads the codec name when there is no format", async () => {
    const c = await infoFor({});
    expect(c.Video).toBe("–");
    expect(c.Audio).toBe("–");
    expect(c.Resolution).toBe("–");
    expect(c.Bitrate).toBe("–");
    expect(c.Decoder).toBe("–");
    expect(c.Buffer).toBe("–");
    teardownShell();
    const c2 = await infoFor({ "video-codec": "h264 (High)", "video-bitrate": "500000", "cache-speed": "0" });
    expect(c2.Video).toBe("h264");
    expect(c2.Bitrate).toBe("500 kbps");
  });

  it("says what mpv is when the backend cannot", async () => {
    const shell = await startPlaying({ invokes: { player_get_properties: () => Promise.reject(new Error("no player")), app_info: {} } });
    void shell;
    open("pb-info");
    await settle();
    expect(cells().Engine).toBe("mpv");
  });

  // BUG: playItem (src/playback.ts:716) replaces `nowPlaying` with a copy
  // when it settles the bitrate, so the identity check at playback.ts:726
  // never matches and the resolved source is never recorded. getStreamSource()
  // is therefore always null for a server stream: the info panel's Delivery
  // reads "–" and "On the server" and the Container fallback are blank.
  it.fails("names direct play and the source's own bitrate", async () => {
    const c = await infoFor({});
    expect(c.Delivery).toBe("Direct play");
    expect(c["On the server"]).toBe("8.0 Mbps source");
    expect(c.Container).toBe("mkv");
  });

  // BUG: as above (src/playback.ts:716/726) — the transcode's reasons and cap
  // never reach the panel.
  it.fails("names a transcode, its cap and the server's reasons, and a remux", async () => {
    const tx = (reasons: string) => ({
      PlaySessionId: "ps",
      MediaSources: [
        {
          Id: "ep-2",
          Container: "mkv",
          SupportsDirectPlay: false,
          SupportsDirectStream: false,
          TranscodingUrl: `/videos/ep-2/master.m3u8?TranscodeReasons=${reasons}`,
        },
      ],
    });
    let reasons = "VideoCodecNotSupported,AudioCodecNotSupported";
    const shell = await bootPlayer({ routes: [[/\/PlaybackInfo/, () => tx(reasons)]] });
    await shell.play(EPISODE, {}, { maxBitrate: 5_000_000 });
    open("pb-info");
    await settle();
    expect(cells().Delivery).toBe("Transcode · capped at 5.0 Mbps (VideoCodecNotSupported, AudioCodecNotSupported)");
    reasons = "ContainerNotSupported";
    await shell.play(EPISODE);
    click($("pb-info"));
    open("pb-info");
    await settle();
    expect(cells().Delivery).toBe("Remux (ContainerNotSupported)");
  });

  it("says a download plays from this device", async () => {
    const shell = await bootPlayer();
    await shell.playLocal({ item_id: "dl-1", path: "/v/a.mkv", title: "A" });
    open("pb-info");
    await settle();
    expect(cells().Delivery).toBe("Playing from this device");
    expect(cells()["On the server"]).toBe("Downloaded file");
  });

  it("has nothing to say about delivery between files", async () => {
    const shell = await startPlaying();
    // The status that ends one file and the bar's own next draw.
    emitEvent("player-status", { active: false, requested_stop: true });
    await settle();
    void shell;
    expect(document.querySelector(".pb-panel")).toBeNull();
  });

  it("says a custom channel comes straight from the playlist", async () => {
    onInvoke("player_get_properties", {});
    const shell = await bootPlayer();
    await shell.playChannel(CHANNEL);
    open("pb-info");
    await settle();
    expect(cells().Delivery).toBe("Live, straight from the playlist");
  });

  it("counts stalls per file", async () => {
    onInvoke("player_get_properties", {});
    const shell = await startPlaying();
    emitEvent("player-stall", {});
    await shell.play(MOVIE);
    open("pb-info");
    await settle();
    expect(cells().Stalls).toBe("0");
  });

  it("stops refreshing once the panel is closed", async () => {
    onInvoke("player_get_properties", {});
    const shell = await startPlaying();
    const p = open("pb-info");
    await settle();
    const n = invokeCalls("player_get_properties").length;
    click($("pb-info"));
    (p as any).sync?.({});
    shell.status();
    await settle();
    expect(invokeCalls("player_get_properties").length).toBe(n);
  });
});

describe("quality", () => {
  it("lists the rungs with the playing one lit, and switches to a capped stream", async () => {
    const shell = await startPlaying();
    open("pb-quality");
    expect(primaries()).toEqual(["Direct Play (original)", "Auto"]);
    const before = invokeCalls("player_play").length;
    pick("5 Mbps · 720p");
    expect(panel()).toBeNull();
    await settle();
    expect(invokeCalls("player_play").length).toBe(before + 1);
    expect(shell.playback.getQualityState()!.current).toBe(5_000_000);
    open("pb-quality");
    expect(primaries()).toEqual(["5 Mbps · 720p", "Auto"]);
  });

  it("toggles adapting to the connection", async () => {
    const shell = await startPlaying();
    open("pb-quality");
    pick("Auto");
    expect(shell.playback.isAdaptiveEnabled()).toBe(false);
    expect(toasts()).toContain("Quality stays where you set it");
    expect(primaries()).toEqual(["Direct Play (original)"]);
    pick("Auto");
    expect(shell.playback.isAdaptiveEnabled()).toBe(true);
    expect(toasts()).toContain("Quality will adapt to the connection");
  });

  it("says a live channel's quality is the channel's", async () => {
    const shell = await bootPlayer();
    await shell.playChannel(CHANNEL);
    open("pb-quality");
    expect(notes()).toEqual(["Live TV — quality is set by the channel"]);
  });

  it("toasts a stream that would not start", async () => {
    await startPlaying();
    onInvoke("player_play", () => Promise.reject(new Error("mpv gone")));
    open("pb-quality");
    pick("5 Mbps · 720p");
    await settle();
    expect(toasts().some((t) => t.startsWith("Couldn't start the stream: mpv gone"))).toBe(true);
  });

  describe("with a download of what is playing", () => {
    const DL = { item_id: "ep-2", status: "complete", path: "/v/ep2.mkv", quality: "720p · 4.5 Mbps", title: "Archer" };

    it("offers the download as a rung of its own, and goes back to it", async () => {
      const shell = await startPlaying({ downloads: [DL] });
      // A server item with a finished download plays from disk by default;
      // this one was started as a stream.
      open("pb-quality");
      const rung = buttonNamed("Downloaded · 720p · 4.5 Mbps", panel()!);
      expect(rung.classList.contains("primary")).toBe(false);
      click(rung);
      await settle();
      expect(invokeCalls("player_play").at(-1)!.args.req.url).toBe("/v/ep2.mkv");
      expect(shell.playback.getQualityState()!.isLocal).toBe(true);
      shell.status();
      open("pb-quality");
      expect(primaries()[0]).toBe("Downloaded · 720p · 4.5 Mbps");
      // Picking it while on it does nothing more.
      const n = invokeCalls("player_play").length;
      pick("Downloaded · 720p · 4.5 Mbps");
      await settle();
      expect(invokeCalls("player_play").length).toBe(n);
    });

    it("says when the download has gone, or failed to start", async () => {
      const downloads = [DL];
      const shell = await startPlaying({ invokes: { downloads_list: () => downloads } });
      void shell;
      downloads.length = 0;
      open("pb-quality");
      // The rung was offered from what was known at the start.
      pick("Downloaded · 720p · 4.5 Mbps");
      await settle();
      expect(toasts()).toContain("The download isn't there anymore");
    });

    it("toasts a failure to look the download up", async () => {
      let calls = 0;
      const shell = await startPlaying({
        invokes: {
          downloads_list: () => {
            calls++;
            return [DL];
          },
        },
      });
      void calls;
      vi.spyOn(shell.playback, "switchToDownload");
      onInvoke("player_play", () => Promise.reject(new Error("bad file")));
      open("pb-quality");
      pick("Downloaded · 720p · 4.5 Mbps");
      await settle();
      expect(toasts().some((t) => t.includes("bad file"))).toBe(true);
    });

    it("offers no streams from a download while offline", async () => {
      let up = true;
      const shell = await bootPlayer({ ping: () => up, downloads: [DL] });
      await shell.playLocal(DL);
      up = false;
      await shell.api.checkOnline();
      open("pb-quality");
      expect(notes()).toEqual(["Offline — streaming unavailable"]);
    });
  });
});

describe("Up next strip", () => {
  it("shows the season with the playing episode marked, what follows it, and what was watched", async () => {
    await startPlaying();
    const p = open("pb-episodes");
    expect(p.classList.contains("pb-queue")).toBe(true);
    expect(notes()).toEqual(["Loading episodes…"]);
    await settle();
    expect(p.querySelector(".pb-panel-label")!.textContent).toBe("Archer · Season 1");
    const tiles = [...p.querySelectorAll<HTMLButtonElement>(".pb-queue-tile")];
    expect(tiles.map((t) => t.title)).toEqual(["1. The First One", "2. The Second One", "3. The Third One", ""]);
    expect(tiles.map((t) => t.querySelector(".pb-queue-status")!.textContent)).toEqual(["Watched", "Playing", "Up next", ""]);
    expect(tiles[0]!.classList.contains("watched")).toBe(true);
    expect(tiles[0]!.querySelector(".pb-queue-status .ico")).not.toBeNull();
    expect(tiles[1]!.classList.contains("playing")).toBe(true);
    expect(tiles[1]!.getAttribute("aria-current")).toBe("true");
    expect(tiles[1]!.querySelector(".pb-queue-now")).not.toBeNull();
    expect(tiles[2]!.querySelector(".pb-queue-status")!.classList.contains("live")).toBe(true);
    // The playing tile closes the panel; another starts that episode.
    click(tiles[1]!);
    expect(panel()).toBeNull();
    open("pb-episodes");
    await settle();
    click(panel()!.querySelectorAll<HTMLButtonElement>(".pb-queue-tile")[2]!);
    await settle();
    expect(invokeCalls("player_play").at(-1)!.args.req.ctx.item_id).toBe("ep-3");
  });

  it("shows minutes for an unwatched episode that is not next", async () => {
    const shell = await startPlaying({}, {}, EP1);
    void shell;
    open("pb-episodes");
    await settle();
    const tiles = [...panel()!.querySelectorAll(".pb-queue-tile")];
    expect(tiles.map((t) => t.querySelector(".pb-queue-status")!.textContent)).toEqual(["Playing", "Up next", "22 min", ""]);
  });

  it("scrolls the strip sideways on a vertical wheel, and leaves a sideways one alone", async () => {
    await startPlaying();
    open("pb-episodes");
    await settle();
    const strip = panel()!.querySelector<HTMLElement>(".pb-queue-strip")!;
    strip.scrollLeft = 0;
    const down = new WheelEvent("wheel", { deltaY: 120, cancelable: true });
    strip.dispatchEvent(down);
    expect(down.defaultPrevented).toBe(true);
    expect(strip.scrollLeft).toBe(120);
    const side = new WheelEvent("wheel", { deltaX: 50, deltaY: 10, cancelable: true });
    strip.dispatchEvent(side);
    expect(side.defaultPrevented).toBe(false);
  });

  it("says so for something that is not an episode, or a season with nothing else", async () => {
    const shell = await startPlaying({}, {}, MOVIE);
    open("pb-episodes");
    await settle();
    expect(notes()).toEqual(["Not playing an episode"]);
    click($("pb-episodes"));
    await shell.play({ ...EPISODE, SeasonId: "season-1" });
    const empty = await startPlaying({ episodes: [] });
    void empty;
    open("pb-episodes");
    await settle();
    expect(notes()).toEqual(["No other episodes in this season"]);
  });

  it("says the queue needs the server while offline", async () => {
    let up = true;
    const shell = await startPlaying({ ping: () => up, episodes: () => Promise.reject(new Error("x")) });
    up = false;
    await shell.api.checkOnline();
    open("pb-episodes");
    await settle();
    expect(notes()).toEqual(["Offline — the queue needs the server"]);
  });

  it("leads with titles queued by hand, which play, come off on right-click, and clear together", async () => {
    const shell = await startPlaying();
    await shell.playback.queueNext([{ Id: "q-1", Type: "Movie", Name: "Heat" }, { Id: "q-2", Type: "Episode", SeriesName: "Other", Name: "Pilot" }]);
    open("pb-episodes");
    await settle();
    const tiles = () => [...panel()!.querySelectorAll<HTMLButtonElement>(".pb-queue-tile")];
    expect(tiles().slice(0, 2).map((t) => t.querySelector(".pb-queue-name")!.textContent)).toEqual(["Heat", "Other · Pilot"]);
    expect(tiles().slice(0, 2).map((t) => t.querySelector(".pb-queue-status")!.textContent)).toEqual(["Up next · queued", "Queued"]);
    // With a queue, the series' next episode is no longer "Up next".
    expect(tiles()[4]!.querySelector(".pb-queue-status")!.textContent).toBe("22 min");

    const ctx = new MouseEvent("contextmenu", { bubbles: true, cancelable: true });
    tiles()[1]!.dispatchEvent(ctx);
    expect(ctx.defaultPrevented).toBe(true);
    expect(shell.playback.getUserQueue().map((i) => i.Id)).toEqual(["q-1"]);
    await settle();
    expect(tiles().filter((t) => t.classList.contains("queued"))).toHaveLength(1);

    click(tiles()[0]!);
    await settle();
    expect(invokeCalls("player_play").at(-1)!.args.req.ctx.item_id).toBe("q-1");

    await shell.playback.queueNext([{ Id: "q-3", Type: "Movie", Name: "Ronin" }]);
    open("pb-episodes");
    pick("Clear Up Next");
    expect(shell.playback.getUserQueue()).toEqual([]);
    expect(toasts()).toContain("Up Next cleared");
    expect(panel()).toBeNull();
  });

  it("shows just the queue for something that is not an episode", async () => {
    const shell = await startPlaying({}, {}, MOVIE);
    await shell.playback.queueNext([{ Id: "q-1", Type: "Movie", Name: "Ronin" }]);
    open("pb-episodes");
    await settle();
    expect(notes()).toEqual([]);
    expect(panel()!.querySelectorAll(".pb-queue-strip .pb-queue-tile.queued")).toHaveLength(1);
  });

  it("toasts a queued title or an episode that would not start", async () => {
    const shell = await startPlaying();
    await shell.playback.queueNext([{ Id: "q-1", Type: "Movie", Name: "Heat" }]);
    onInvoke("player_play", () => Promise.reject(new Error("mpv gone")));
    open("pb-episodes");
    await settle();
    click(panel()!.querySelector<HTMLButtonElement>(".pb-queue-tile.queued")!);
    await settle();
    expect(toasts().some((t) => t.includes("mpv gone"))).toBe(true);
  });

  it("draws nothing into a panel that was closed while the season loaded", async () => {
    let release: (v: any) => void = () => {};
    await startPlaying({ episodes: () => new Promise((r) => (release = r)) });
    const p = open("pb-episodes");
    click($("pb-episodes"));
    release(EP3 ? [EP1, EPISODE] : []);
    await settle();
    expect(p.querySelector(".pb-queue-strip")).toBeNull();
  });
});

describe("channels", () => {
  it("opens the line-up inside the bar while a channel plays", async () => {
    const shell = await bootPlayer();
    await shell.playChannel(CHANNEL);
    const p = open("pb-channels");
    expect(p.dataset.panel).toBe("channels");
    expect(p.classList.contains("pb-channels")).toBe(true);
  });
});
