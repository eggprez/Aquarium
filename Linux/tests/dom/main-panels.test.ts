// src/main.ts: what the player bar's pills open. A card (Info, Audio,
// Subtitles, Quality, More) is drawn in `#player-cards`, the band above the
// bar that the backend clips the video off; a strip (Up Next, Channels,
// Chapters, Picture, the delays) is drawn inside the bar itself.
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
const texts = (root: ParentNode | null, sel: string): string[] => [...(root?.querySelectorAll(sel) ?? [])].map((n) => n.textContent ?? "");

// ---------- Strips, inside the bar ----------

function open(btn: string): HTMLElement {
  click($(btn));
  return panel()!;
}

function pick(label: string): void {
  click(buttonNamed(label, panel()!));
}

function notes(): string[] {
  return texts(panel(), ".pb-panel-note");
}

function primaries(): string[] {
  return texts(panel(), "button.primary");
}

// ---------- Cards, in the band above the bar ----------

function card(): HTMLElement | null {
  return document.querySelector("#player-cards .pb-card");
}

function openCard(btn: string): HTMLElement {
  click($(btn));
  return card()!;
}

/** Every row as [title, detail]. */
function rows(): Array<[string, string]> {
  return [...(card()?.querySelectorAll(".pb-card-row") ?? [])].map((r) => [
    r.querySelector(".pb-card-title")!.textContent ?? "",
    r.querySelector(".pb-card-detail")?.textContent ?? "",
  ]);
}

function rowTitles(): string[] {
  return rows().map((r) => r[0]);
}

function row(title: string): HTMLButtonElement {
  const hit = [...card()!.querySelectorAll<HTMLButtonElement>(".pb-card-row")].find((r) => r.querySelector(".pb-card-title")!.textContent === title);
  if (!hit) throw new Error(`no row titled "${title}"`);
  return hit;
}

function pickRow(title: string): void {
  click(row(title));
}

/** The ticked rows' titles; each carries the tick as well as the class. */
function ticked(): string[] {
  const sel = [...(card()?.querySelectorAll(".pb-card-row.selected") ?? [])];
  for (const r of sel) expect(r.querySelector(".pb-card-tick")).not.toBeNull();
  expect(card()?.querySelectorAll(".pb-card-tick").length ?? 0).toBe(sel.length);
  return sel.map((r) => r.querySelector(".pb-card-title")!.textContent ?? "");
}

function cardNotes(): string[] {
  return texts(card(), ".pb-card-note");
}

function chips(): string[] {
  return texts(card(), ".pb-chip");
}

function chipsOn(): string[] {
  return texts(card(), ".pb-chip.on");
}

function pickChip(label: string): void {
  click(buttonNamed(label, card()!));
}

/** A strip reached through a row of the More card. */
function openFromMore(title: string): HTMLElement {
  openCard("pb-more");
  pickRow(title);
  return panel()!;
}

/** The pills lit as open. */
function litPills(): string[] {
  return [...$("player-bar").querySelectorAll(".pb-pill.on")].map((p) => p.id).filter((id) => id !== "pb-fill");
}

describe("card and strip frames", () => {
  it("opens one card at a time in the band above the bar, with its title and a Close, and cuts the picture off the band", async () => {
    await startPlaying();
    // jsdom lays nothing out; give the band a height for the backend to cut.
    const rect = vi.spyOn(HTMLElement.prototype, "getBoundingClientRect").mockImplementation(function (this: HTMLElement) {
      const height = this.id === "player-cards" ? 300.2 : 0;
      return { left: 0, top: 0, right: 0, bottom: height, width: 0, height, x: 0, y: 0, toJSON() {} } as DOMRect;
    });
    try {
      const band = () => invokeCalls("player_set_card_band").map((c) => c.args.px);
      const c = openCard("pb-subs");
      // Outside the bar, which clips its content.
      expect(c.parentElement).toBe($("player-cards"));
      expect($("player-cards").parentElement).toBe(document.body);
      expect($("player-bar").contains(c)).toBe(false);
      expect($("player-cards").classList.contains("hidden")).toBe(false);
      expect(c.dataset.card).toBe("subs");
      expect(c.getAttribute("role")).toBe("dialog");
      expect(c.getAttribute("aria-label")).toBe("Subtitles");
      expect(c.querySelector(".pb-card-head h4")!.textContent).toBe("Subtitles");
      expect(litPills()).toEqual(["pb-subs"]);
      expect(band()).toEqual([301]);
      openCard("pb-audio");
      expect(document.querySelectorAll(".pb-card")).toHaveLength(1);
      expect(card()!.dataset.card).toBe("audio");
      expect(litPills()).toEqual(["pb-audio"]);
      // One card for another: the band stays cut.
      expect(band()).toEqual([301]);
      // The same pill again closes it: the picture comes back over the band
      // first, and the card is taken away once it has.
      click($("pb-audio"));
      expect(litPills()).toEqual([]);
      expect(band()).toEqual([301, 0]);
      await flush();
      expect(card()).toBeNull();
      expect($("player-cards").classList.contains("hidden")).toBe(true);
      openCard("pb-audio");
      expect(band()).toEqual([301, 0, 301]);
      click(card()!.querySelector(".pb-card-close")!);
      await flush();
      expect(card()).toBeNull();
      expect(band()).toEqual([301, 0, 301, 0]);
    } finally {
      rect.mockRestore();
    }
  });

  it("opens a strip inside the bar, with its label and a Close, and never a card and a strip together", async () => {
    await startPlaying();
    const p = open("pb-episodes");
    expect(p.parentElement).toBe($("player-bar"));
    expect(p.dataset.panel).toBe("episodes");
    expect(p.querySelector(".pb-panel-label")!.textContent).toBe("Up next");
    expect(litPills()).toEqual(["pb-episodes"]);
    // A card closes the strip.
    openCard("pb-audio");
    expect(panel()).toBeNull();
    expect(litPills()).toEqual(["pb-audio"]);
    // And a strip the card.
    open("pb-episodes");
    expect(litPills()).toEqual(["pb-episodes"]);
    await flush();
    expect(card()).toBeNull();
    expect(document.querySelectorAll(".pb-panel")).toHaveLength(1);
    // The same pill again closes it.
    click($("pb-episodes"));
    expect(panel()).toBeNull();
    open("pb-episodes");
    click(panel()!.querySelector(".pb-panel-close")!);
    expect(panel()).toBeNull();
    expect(litPills()).toEqual([]);
  });

  it("lights the More pill for the strips its card leads to", async () => {
    await startPlaying();
    openCard("pb-more");
    expect(litPills()).toEqual(["pb-more"]);
    pickRow("Picture and zoom");
    expect(panel()!.dataset.panel).toBe("picture");
    expect(litPills()).toEqual(["pb-more"]);
    await flush();
    expect(card()).toBeNull();
    click(panel()!.querySelector(".pb-panel-close")!);
    expect(litPills()).toEqual([]);
  });
});

describe("audio and subtitle tracks", () => {
  it("lists each audio track by title, language or number with what it is underneath, the playing one ticked, and switches", async () => {
    await startPlaying();
    sendTracks([
      { id: 1, type: "audio", lang: "eng", selected: true, codec: "eac3", "demux-channel-count": 6, default: true },
      { id: 2, type: "audio", lang: "jpn", title: "Commentary", codec: "aac", "demux-channel-count": 2 },
      { id: 3, type: "audio", "demux-channel-count": 1, external: true },
      { id: 4, type: "audio", lang: "xx", "audio-channels": 8 },
      { id: 5, type: "audio", lang: "123", "demux-channel-count": 3, forced: true },
      { id: 6, type: "audio", lang: "und" },
    ]);
    openCard("pb-audio");
    // A tag Intl can't name (or "und", which names nothing) is shown as it
    // came; a track with no tag at all gets its number. A named track says
    // its language underneath; an unnamed one already has.
    expect(rows()).toEqual([
      ["English", "EAC3 · 5.1 · Default"],
      ["Commentary", "Japanese · AAC · Stereo"],
      ["Track 3", "Mono · External"],
      ["xx", "7.1"],
      ["123", "3 ch · Forced"],
      ["und", ""],
    ]);
    expect(ticked()).toEqual(["English"]);
    pickRow("Commentary");
    expect(invokeCalls("player_set_track").at(-1)!.args).toEqual({ kind: "audio", track: 2 });
    await flush();
    expect(card()).toBeNull();
  });

  it("says when no audio tracks have been reported", async () => {
    await startPlaying();
    openCard("pb-audio");
    expect(cardNotes()).toEqual(["No audio tracks reported yet."]);
    expect(rows()).toEqual([]);
  });

  it("toasts a failed switch", async () => {
    await startPlaying();
    sendTracks([{ id: 1, type: "audio", lang: "eng" }, { id: 3, type: "sub", lang: "eng" }]);
    onInvoke("player_set_track", () => Promise.reject("no player"));
    openCard("pb-audio");
    pickRow("English");
    openCard("pb-subs");
    pickRow("English");
    openCard("pb-subs");
    pickRow("Off");
    await flush();
    expect(toasts()).toEqual(["no player", "no player", "no player"]);
  });

  it("lists subtitles with Off first, ticked when none is on", async () => {
    await startPlaying();
    sendTracks([{ id: 3, type: "sub", lang: "fre", codec: "ass", forced: true }, { id: 4, type: "sub", title: "Signs" }]);
    openCard("pb-subs");
    expect(rows()).toEqual([["Off", ""], ["French", "ASS · Forced"], ["Signs", ""]]);
    expect(ticked()).toEqual(["Off"]);
    pickRow("Signs");
    expect(invokeCalls("player_set_track").at(-1)!.args).toEqual({ kind: "sub", track: 4 });
    sendTracks([{ id: 3, type: "sub", lang: "fre", selected: true }]);
    openCard("pb-subs");
    expect(ticked()).toEqual(["French"]);
    pickRow("Off");
    expect(invokeCalls("player_set_track").at(-1)!.args).toEqual({ kind: "sub", track: "no" });
  });

  it("says when the file has no subtitles, still offering Off", async () => {
    await startPlaying();
    openCard("pb-subs");
    expect(cardNotes()).toEqual(["No subtitles for this file."]);
    expect(rowTitles()).toEqual(["Off"]);
    expect(ticked()).toEqual(["Off"]);
  });
});

describe("the More card", () => {
  it("gathers speed, the sleep timer, stopping after this episode and the ways into the strips", async () => {
    await startPlaying({}, { duration: 1500, chapters: [{ time: 300, title: "Middle" }] });
    const c = openCard("pb-more");
    expect(c.querySelector(".pb-card-head h4")!.textContent).toBe("More");
    expect(texts(c, ".pb-card-section")).toEqual(["Speed", "Sleep timer", "This player"]);
    expect(chips()).toEqual(["0.5×", "0.75×", "Normal", "1.25×", "1.5×", "1.75×", "2×", "15 min", "30 min", "60 min", "90 min"]);
    expect(rows()).toEqual([
      ["Stop after this episode", "Otherwise next: Archer · Season 1: Episode 3 · The Third One"],
      ["Chapters", "2 in this file"],
      ["Picture and zoom", "Brightness, contrast, saturation"],
      ["Subtitle and audio delay", ""],
    ]);
  });

  it("leaves Chapters out for a file with none, and says what stopping means with nothing next", async () => {
    await startPlaying({}, {}, MOVIE);
    openCard("pb-more");
    expect(rows()).toEqual([
      ["Stop after this episode", "Play this one to the end, then stop"],
      ["Picture and zoom", "Brightness, contrast, saturation"],
      ["Subtitle and audio delay", ""],
    ]);
  });

  it("offers a channel the sleep timer, the line-up and the picture, and nothing that needs a timeline", async () => {
    const shell = await bootPlayer();
    await shell.playChannel(CHANNEL);
    const c = openCard("pb-more");
    expect(texts(c, ".pb-card-section")).toEqual(["Sleep timer", "This player"]);
    expect(chips()).toEqual(["15 min", "30 min", "60 min", "90 min"]);
    expect(rows()).toEqual([
      ["Change channel", "Page Up and Page Down step through them"],
      ["Picture and zoom", "Brightness, contrast, saturation"],
    ]);
    pickRow("Change channel");
    expect(panel()!.dataset.panel).toBe("channels");
  });
});

describe("speed and delays", () => {
  it("sets speed from the More card's chips, the one in force lit, in step with mpv", async () => {
    const shell = await startPlaying();
    shell.status({ speed: 1 });
    openCard("pb-more");
    expect(chipsOn()).toEqual(["Normal"]);
    pickChip("1.5×");
    expect(propSets("speed")).toEqual([1.5]);
    // A chip leaves the card open, and follows what mpv says.
    expect(card()!.dataset.card).toBe("more");
    shell.status({ speed: 1.5 });
    expect(chipsOn()).toEqual(["1.5×"]);
  });

  it("sets speed, steps subtitle and audio delay, and keeps its readouts in step with mpv", async () => {
    const shell = await startPlaying();
    shell.status({ speed: 1, sub_delay: 0, audio_delay: 0 });
    const p = openFromMore("Subtitle and audio delay");
    expect(p.dataset.panel).toBe("tune");
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
    const p = openFromMore("Picture and zoom");
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
    const p = openFromMore("Picture and zoom");
    expect(p.querySelector<HTMLInputElement>('input[aria-label="Zoom"]')!.value).toBe("0");
  });
});

describe("sleep", () => {
  it("stops at the end of this episode, and can be told not to", async () => {
    const shell = await startPlaying();
    openCard("pb-more");
    expect(ticked()).toEqual([]);
    pickRow("Stop after this episode");
    expect(shell.playback.isAutoplayCancelled()).toBe(true);
    // The card stays, redrawn to show it.
    expect(card()!.dataset.card).toBe("more");
    expect(ticked()).toEqual(["Stop after this episode"]);
    pickRow("Stop after this episode");
    expect(shell.playback.isAutoplayCancelled()).toBe(false);
    expect(ticked()).toEqual([]);
    await flush();
    expect(card()!.dataset.card).toBe("more");
  });

  it("sets a timer, says how long is left, and cancels it", async () => {
    const shell = await startPlaying();
    fakeTimers();
    openCard("pb-more");
    pickChip("15 min");
    expect(shell.playback.sleepDeadline()).not.toBeNull();
    // Said in the bar: a toast would be on the page, under the picture.
    expect($("pb-state").textContent).toBe("Stopping in 15 min");
    expect(toasts()).toEqual([]);
    // The card stays, the durations giving way to the timer that is running.
    expect(rows()[0]).toEqual(["Stopping in 15 min", "Click to cancel"]);
    expect(ticked()).toEqual(["Stopping in 15 min"]);
    expect(chips()).not.toContain("15 min");
    vi.advanceTimersByTime(14.5 * 60_000);
    click($("pb-more"));
    openCard("pb-more");
    expect(rows()[0]).toEqual(["Stopping in under a minute", "Click to cancel"]);
    pickRow("Stopping in under a minute");
    expect(shell.playback.sleepDeadline()).toBeNull();
    expect(card()!.dataset.card).toBe("more");
    expect(ticked()).toEqual([]);
    expect(chips().slice(-4)).toEqual(["15 min", "30 min", "60 min", "90 min"]);
  });
});

describe("chapters", () => {
  it("is not offered for a file that has none", async () => {
    await startPlaying();
    openCard("pb-more");
    expect(rowTitles()).not.toContain("Chapters");
  });

  it("lists the chapters from the start, lights the one playing, and jumps to one", async () => {
    const shell = await startPlaying({}, { position: 400, duration: 1500, chapters: [{ time: 300, title: "Middle" }, { time: 900, title: "" }] });
    const p = openFromMore("Chapters");
    expect(p.dataset.panel).toBe("chapters");
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
    for (const label of card()!.querySelectorAll(".pb-info-grid .pb-info-label")) {
      const value = label.nextElementSibling!;
      expect(value.classList.contains("pb-info-value")).toBe(true);
      out[label.textContent!] = value.textContent!;
    }
    return out;
  }

  async function infoFor(props: Record<string, any>, status: Record<string, any> = {}): Promise<Record<string, string>> {
    await startPlaying({ invokes: { player_get_properties: props } }, status);
    openCard("pb-info");
    await settle();
    return cells();
  }

  it("lists how it is coming down, what is on the server and how it is playing", async () => {
    const c = await infoFor(PROPS, { dropped_frames: 3, position: 100, duration: 1500, chapters: [{ time: 60, title: "Act one" }] });
    expect(card()!.classList.contains("wide")).toBe(true);
    expect(texts(card(), ".pb-card-section")).toEqual(["Coming down", "On the server", "Playing"]);
    expect(Object.keys(c)).toEqual([
      "Delivery", "Bitrate", "Buffer",
      "Source", "Container",
      "Video", "Audio", "Resolution", "Decoder", "Engine", "Stalls", "Dropped frames", "Position", "Chapter", "Sleep timer",
    ]);
    expect(c).toMatchObject({
      Position: "1:40 · 23:20 left",
      Chapter: "Act one",
      "Sleep timer": "Off",
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
    openCard("pb-info");
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
    openCard("pb-info");
    await settle();
    expect(cells().Engine).toBe("mpv");
  });

  it("leads with what is playing: the episode under its show, and its facts", async () => {
    const item = { ...EPISODE, ProductionYear: 2009, OfficialRating: "TV-MA", CommunityRating: 8.64, Genres: ["Comedy", "Action", "Spy", "Animation"], Overview: "Archer goes rogue." };
    await startPlaying({ invokes: { player_get_properties: {} } }, {}, item);
    const c = openCard("pb-info");
    expect(c.querySelector(".pb-info-top h3")!.textContent).toBe("The Second One");
    expect(c.querySelector(".pb-info-kicker")!.textContent).toBe("Archer · S1 E2");
    expect(c.querySelector(".pb-info-facts")!.textContent).toBe("2009 · 25 min · TV-MA · ★ 8.6 · Comedy, Action, Spy");
    expect(c.querySelector(".pb-info-overview")!.textContent).toBe("Archer goes rogue.");
  });

  it("says what the sleep timer is doing", async () => {
    const shell = await startPlaying({ invokes: { player_get_properties: {} } });
    shell.playback.cancelAutoplay();
    openCard("pb-info");
    await settle();
    expect(cells()["Sleep timer"]).toBe("Stopping after this episode");
    shell.playback.setSleepTimer(30);
    shell.status();
    await settle();
    expect(cells()["Sleep timer"]).toBe("Stopping in 30 min");
    shell.playback.cancelSleepTimer();
  });

  it("names direct play and the source's own bitrate", async () => {
    const c = await infoFor({});
    expect(c.Delivery).toBe("Direct play");
    expect(c.Source).toBe("8.0 Mbps");
    expect(c.Container).toBe("mkv");
  });

  it("names a transcode, its cap and the server's reasons, and a remux", async () => {
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
    openCard("pb-info");
    await settle();
    expect(cells().Delivery).toBe("Transcode · capped at 5.0 Mbps (VideoCodecNotSupported, AudioCodecNotSupported)");
    reasons = "ContainerNotSupported";
    await shell.play(EPISODE);
    click($("pb-info"));
    openCard("pb-info");
    await settle();
    expect(cells().Delivery).toBe("Remux (ContainerNotSupported)");
  });

  it("says a download plays from this device", async () => {
    const shell = await bootPlayer();
    await shell.playLocal({ item_id: "dl-1", path: "/v/a.mkv", title: "A" });
    openCard("pb-info");
    await settle();
    expect(cells().Delivery).toBe("Playing from this device");
    expect(cells().Source).toBe("Downloaded file");
  });

  it("has nothing to say about delivery between files: the card goes with the bar", async () => {
    onInvoke("player_get_properties", {});
    const shell = await startPlaying();
    openCard("pb-info");
    await settle();
    // The status that ends one file and the bar's own next draw.
    emitEvent("player-status", { active: false, requested_stop: true });
    await settle();
    void shell;
    expect(document.querySelector(".pb-panel")).toBeNull();
    expect(card()).toBeNull();
  });

  it("says a custom channel comes straight from the playlist", async () => {
    onInvoke("player_get_properties", {});
    const shell = await bootPlayer();
    await shell.playChannel(CHANNEL);
    openCard("pb-info");
    await settle();
    expect(cells().Delivery).toBe("Live, straight from the playlist");
  });

  it("counts stalls per file", async () => {
    onInvoke("player_get_properties", {});
    const shell = await startPlaying();
    emitEvent("player-stall", {});
    await shell.play(MOVIE);
    openCard("pb-info");
    await settle();
    expect(cells().Stalls).toBe("0");
  });

  it("stops refreshing once the card is closed", async () => {
    onInvoke("player_get_properties", {});
    const shell = await startPlaying();
    openCard("pb-info");
    await settle();
    // Open, it asks again with every status.
    const first = invokeCalls("player_get_properties").length;
    shell.status();
    await settle();
    const n = invokeCalls("player_get_properties").length;
    expect(n).toBe(first + 1);
    click($("pb-info"));
    shell.status();
    await settle();
    expect(invokeCalls("player_get_properties").length).toBe(n);
  });
});

describe("quality", () => {
  const pill = (): string => $("pb-quality").querySelector(".pb-pill-label")!.textContent ?? "";

  it("lists Auto, then Direct and the rungs, with what is playing said and ticked, and switches to a capped stream", async () => {
    const shell = await startPlaying();
    openCard("pb-quality");
    // Adapting is on to begin with: Auto holds the tick, and says what it
    // is playing; the rung itself says so too, unticked.
    expect(rows()).toEqual([
      ["Auto", "Playing now · Direct Play (original)"],
      ["Direct (original)", "Playing now"],
      ["35 Mbps · 4K", ""],
      ["18 Mbps · 1440p", ""],
      ["10 Mbps · 1080p", ""],
      ["5 Mbps · 720p", ""],
      ["2.5 Mbps · 480p", ""],
    ]);
    expect(ticked()).toEqual(["Auto"]);
    expect(cardNotes()).toHaveLength(1);
    expect(cardNotes()[0]).toMatch(/^Auto drops to a smaller stream/);
    expect(pill()).toBe("Auto");
    const before = invokeCalls("player_play").length;
    pickRow("5 Mbps · 720p");
    await settle();
    expect(card()).toBeNull();
    expect(invokeCalls("player_play").length).toBe(before + 1);
    expect(shell.playback.getQualityState()!.current).toBe(5_000_000);
    // A rung picked by hand is a choice to stay on it.
    expect(shell.playback.isAdaptiveEnabled()).toBe(false);
    shell.status();
    expect(pill()).toBe("720p");
    openCard("pb-quality");
    expect(ticked()).toEqual(["5 Mbps · 720p"]);
    expect(rows().filter((r) => r[1])).toEqual([
      ["Auto", "Moves between the rungs as the connection allows"],
      ["5 Mbps · 720p", "Playing now · transcoding"],
    ]);
  });

  it("turns adapting off for a rung picked by hand, and back on from Auto", async () => {
    const shell = await startPlaying();
    expect(shell.playback.isAdaptiveEnabled()).toBe(true);
    openCard("pb-quality");
    // The rung already playing: nothing restarts, it just stays there now.
    const n = invokeCalls("player_play").length;
    pickRow("Direct (original)");
    await settle();
    expect(shell.playback.isAdaptiveEnabled()).toBe(false);
    expect(invokeCalls("player_play").length).toBe(n);
    shell.status();
    expect(pill()).toBe("Direct");
    openCard("pb-quality");
    expect(ticked()).toEqual(["Direct (original)"]);
    pickRow("Auto");
    expect(shell.playback.isAdaptiveEnabled()).toBe(true);
    // Said in the bar: a toast would be on the page, under the picture.
    expect($("pb-state").textContent).toBe("Quality: Auto");
    expect(toasts()).toEqual([]);
    expect(invokeCalls("player_play").length).toBe(n);
    openCard("pb-quality");
    expect(ticked()).toEqual(["Auto"]);
  });

  it("says a live channel's quality is the channel's", async () => {
    const shell = await bootPlayer();
    await shell.playChannel(CHANNEL);
    openCard("pb-quality");
    expect(cardNotes()).toEqual(["Live TV — quality is set by the channel."]);
    expect(rows()).toEqual([]);
  });

  it("toasts a stream that would not start", async () => {
    await startPlaying();
    onInvoke("player_play", () => Promise.reject(new Error("mpv gone")));
    openCard("pb-quality");
    pickRow("5 Mbps · 720p");
    await settle();
    expect(toasts().some((t) => t.startsWith("Couldn't start the stream: mpv gone"))).toBe(true);
  });

  describe("with a download of what is playing", () => {
    const DL = { item_id: "ep-2", status: "complete", path: "/v/ep2.mkv", quality: "720p · 4.5 Mbps", title: "Archer" };

    it("offers the download as a row of its own under Auto, and goes back to it", async () => {
      const shell = await startPlaying({ downloads: [DL] });
      // A server item with a finished download plays from disk by default;
      // this one was started as a stream.
      openCard("pb-quality");
      expect(rows().slice(0, 3)).toEqual([
        ["Auto", "Playing now · Direct Play (original)"],
        ["Downloaded", "720p · 4.5 Mbps"],
        ["Direct (original)", "Playing now"],
      ]);
      expect(ticked()).toEqual(["Auto"]);
      pickRow("Downloaded");
      await settle();
      expect(invokeCalls("player_play").at(-1)!.args.req.url).toBe("/v/ep2.mkv");
      expect(shell.playback.getQualityState()!.isLocal).toBe(true);
      shell.status();
      expect(pill()).toBe("Downloaded");
      // A download plays as it was saved: its card holds the one row.
      openCard("pb-quality");
      expect(rows()).toEqual([["Downloaded", "720p · 4.5 Mbps"]]);
      expect(ticked()).toEqual(["Downloaded"]);
      expect(cardNotes()).toEqual([]);
      // Picking it while on it does nothing more.
      const n = invokeCalls("player_play").length;
      pickRow("Downloaded");
      await settle();
      expect(invokeCalls("player_play").length).toBe(n);
    });

    it("says when the download has gone, or failed to start", async () => {
      const downloads = [DL];
      const shell = await startPlaying({ invokes: { downloads_list: () => downloads } });
      void shell;
      downloads.length = 0;
      openCard("pb-quality");
      // The row was offered from what was known at the start.
      pickRow("Downloaded");
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
      openCard("pb-quality");
      pickRow("Downloaded");
      await settle();
      expect(toasts().some((t) => t.includes("bad file"))).toBe(true);
    });

    it("offers no streams from a download, online or off", async () => {
      let up = true;
      const shell = await bootPlayer({ ping: () => up, downloads: [DL] });
      await shell.playLocal(DL);
      openCard("pb-quality");
      expect(rows()).toEqual([["Downloaded", "720p · 4.5 Mbps"]]);
      expect(ticked()).toEqual(["Downloaded"]);
      click($("pb-quality"));
      up = false;
      await shell.api.checkOnline();
      openCard("pb-quality");
      expect(rows()).toEqual([["Downloaded", "720p · 4.5 Mbps"]]);
      expect(cardNotes()).toEqual([]);
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
