// src/main.ts: the player's keyboard, mouse and remote input — the Up Next
// card, volume, playback keys, mpv's own input relayed from the picture
// (`aquarium-player-input`) and the in-picture menu.
import { afterEach, describe, expect, it, vi } from "vitest";
import { emitEvent, flush, invokeCalls, onInvoke } from "../helpers/tauri";
import {
  bootPlayer,
  CHANNEL,
  click,
  EP3,
  EPISODE,
  fakeTimers,
  key,
  MOVIE,
  mpvCommands,
  propSets,
  sendTracks,
  settle,
  startPlaying,
  teardownShell,
  toasts,
  win,
} from "../helpers/main-shell";

afterEach(teardownShell);

const $ = (id: string): HTMLElement => document.getElementById(id)!;
const text = (id: string): string => $(id).textContent ?? "";

function input(name: string, arg: string, rest?: string[]): void {
  document.dispatchEvent(new CustomEvent("aquarium-player-input", { detail: { name, arg, rest } }));
}

const TRACKS = [
  { id: 1, type: "audio", lang: "eng", selected: true },
  { id: 2, type: "audio", lang: "jpn", title: "Japanese 5.1" },
  { id: 3, type: "sub", lang: "eng", selected: true },
  { id: 4, type: "sub", lang: "fre" },
];

describe("the Up Next card", () => {
  it("comes up over the closing stretch with the next episode, its frame and a countdown", async () => {
    const shell = await startPlaying({}, { position: 100, duration: 1500 });
    const card = $("pb-upnext");
    expect(card.classList.contains("on")).toBe(false);
    // The desktop's next button learns there is a next episode.
    expect(invokeCalls("player_set_next_available").at(-1)!.args).toEqual({ available: true });
    shell.status({ position: 1480 });
    expect(card.classList.contains("on")).toBe(true);
    expect($("player-bar").classList.contains("upnext")).toBe(true);
    expect(text("pb-upnext-when")).toBe("Up next · in 20s");
    expect(text("pb-upnext-title")).toBe("Archer · Season 1: Episode 3 · The Third One");
    const thumb = $("pb-upnext-thumb");
    expect(thumb.classList.contains("on")).toBe(true);
    const img = thumb.querySelector("img")!;
    expect(img.getAttribute("src")).toContain("/Items/ep-3/Images/Primary");
    // Fetched once per episode, not every tick.
    shell.status({ position: 1481 });
    expect(thumb.querySelector("img")).toBe(img);
    // A frame that will not load leaves a play glyph.
    img.dispatchEvent(new Event("error"));
    expect(thumb.querySelector(".ico")).not.toBeNull();
    // Gone once the file has run out.
    shell.status({ position: 1500 });
    expect(card.classList.contains("on")).toBe(false);
  });

  it("only asks, without a countdown, when autoplay is off", async () => {
    const shell = await startPlaying({ config: { autoplay_next: false } }, { position: 1490, duration: 1500 });
    void shell;
    expect(text("pb-upnext-when")).toBe("Up next");
  });

  it("does not appear for a film or the last episode", async () => {
    const shell = await startPlaying({}, { position: 1490, duration: 1500 }, MOVIE);
    expect($("pb-upnext").classList.contains("on")).toBe(false);
    expect(invokeCalls("player_set_next_available").at(-1)!.args).toEqual({ available: false });
    shell.stop();
    await settle();
  });

  it("Not now stops after this episode", async () => {
    const shell = await startPlaying({}, { position: 1480, duration: 1500 });
    click([...$("pb-upnext").querySelectorAll("button")].find((b) => b.textContent === "Not now")!);
    expect($("pb-upnext").classList.contains("on")).toBe(false);
    expect($("player-bar").classList.contains("upnext")).toBe(false);
    expect(shell.playback.isAutoplayCancelled()).toBe(true);
    shell.status({ position: 1485 });
    expect($("pb-upnext").classList.contains("on")).toBe(false);
  });

  it("Play now starts the next episode, once, and says Starting meanwhile", async () => {
    const shell = await startPlaying({}, { position: 1480, duration: 1500 });
    const before = invokeCalls("player_play").length;
    click([...$("pb-upnext").querySelectorAll("button")].find((b) => b.textContent === "Play now")!);
    shell.status({ position: 1481 });
    expect(text("pb-upnext-when")).toBe("Starting…");
    // A second press while it starts is the same press.
    input("aquarium-ctl", "next");
    await settle();
    const plays = invokeCalls("player_play").slice(before);
    expect(plays).toHaveLength(1);
    expect(plays[0]!.args.req.ctx.item_id).toBe("ep-3");
  });

  it("Enter answers yes while the card is up, but not over a focused button", async () => {
    const shell = await startPlaying({}, { position: 1480, duration: 1500 });
    const before = invokeCalls("player_play").length;
    const onButton = key("Enter", {}, $("pb-stop"));
    expect(onButton.defaultPrevented).toBe(false);
    const ev = key("Enter");
    expect(ev.defaultPrevented).toBe(true);
    await settle();
    expect(invokeCalls("player_play").length).toBe(before + 1);
    void shell;
  });

  it("Enter does nothing while the card is down", async () => {
    await startPlaying({}, { position: 10, duration: 1500 });
    expect(key("Enter").defaultPrevented).toBe(false);
  });

  it("says so when the next episode cannot start", async () => {
    const shell = await startPlaying({}, { position: 1480, duration: 1500 });
    onInvoke("player_play", () => Promise.reject(new Error("mpv gone")));
    input("aquarium-ctl", "next");
    await settle();
    expect(toasts()).toContain("Couldn't start the next episode");
    // And it can be asked again.
    shell.status({ position: 1481 });
    expect(text("pb-upnext-when")).toBe("Up next · in 19s");
  });

  it("follows the queue: something queued becomes the next title", async () => {
    const shell = await startPlaying({}, { position: 100, duration: 1500 }, MOVIE);
    expect(invokeCalls("player_set_next_available").at(-1)!.args).toEqual({ available: false });
    await shell.playback.queueNext([{ ...EP3, Id: "q-1", Name: "Queued", SeriesName: undefined }]);
    await settle();
    expect(invokeCalls("player_set_next_available").at(-1)!.args).toEqual({ available: true });
    shell.status({ position: 1490 });
    expect(text("pb-upnext-title")).toBe("Queued");
    expect(text("pb-upnext-when")).toBe("Up next · in 10s");
  });

  it("ignores queue changes with nothing playing", async () => {
    await bootPlayer();
    document.dispatchEvent(new CustomEvent("aquarium-queue-changed"));
    await settle();
    expect(invokeCalls("player_set_next_available")).toHaveLength(0);
  });

  it("spells the coming episode the Apple way, for server items and downloads alike", async () => {
    const shell = await startPlaying({}, { position: 1480, duration: 1500 }, MOVIE);
    const q = async (item: any): Promise<string> => {
      shell.playback.clearQueue();
      await shell.playback.queueNext([item]);
      await settle();
      shell.status({ position: 1480 });
      return text("pb-upnext-title");
    };
    expect(await q({ Type: "Episode", Id: "a", SeriesName: "Archer", ParentIndexNumber: 0, IndexNumber: 2, Name: "Pilot" })).toBe(
      "Archer · Specials: Episode 2 · Pilot"
    );
    expect(await q({ Type: "Episode", Id: "b", SeriesName: "Archer", IndexNumber: 5, Name: "X" })).toBe("Archer · Episode 5 · X");
    expect(await q({ Type: "Episode", Id: "c", SeriesName: "Archer", Name: "Y" })).toBe("Archer · Y");
    expect(await q({ Type: "Movie", Id: "d" })).toBe("Next episode");
  });
});

describe("volume", () => {
  it("follows mpv's level and mute, unless the slider was just touched or is held", async () => {
    const shell = await startPlaying();
    const slider = $("pb-volume") as HTMLInputElement;
    shell.status({ volume: 40, mute: false });
    expect(slider.value).toBe("40");
    expect(slider.title).toBe("Volume 40% (↑/↓)");
    expect($("pb-mute").title).toBe("Mute (m)");
    shell.status({ mute: true });
    expect($("pb-mute").title).toBe("Unmute (m)");
    expect(slider.classList.contains("muted")).toBe(true);
    slider.focus();
    shell.status({ volume: 90 });
    expect(slider.value).toBe("40");
    slider.blur();
    shell.status({ volume: 90 });
    expect(slider.value).toBe("90");
  });

  it("draws the speaker for silence, a low level and a high one", async () => {
    const shell = await startPlaying();
    shell.status({ volume: 0, mute: false });
    const silent = $("pb-mute").innerHTML;
    shell.status({ volume: 30 });
    const low = $("pb-mute").innerHTML;
    shell.status({ volume: 100 });
    const high = $("pb-mute").innerHTML;
    expect(new Set([silent, low, high]).size).toBe(3);
    shell.status({ volume: 100, mute: true });
    expect($("pb-mute").innerHTML).toBe(silent);
  });

  it("throttles a drag to one command per 60 ms, and always lands the final value", async () => {
    const shell = await startPlaying();
    fakeTimers();
    const slider = $("pb-volume") as HTMLInputElement;
    const drag = (v: number) => {
      slider.value = String(v);
      slider.dispatchEvent(new Event("input"));
    };
    drag(50);
    drag(52);
    drag(54);
    expect(propSets("volume")).toEqual([50]);
    vi.advanceTimersByTime(60);
    drag(56);
    expect(propSets("volume")).toEqual([50, 56]);
    drag(58);
    slider.dispatchEvent(new Event("pointerup"));
    expect(propSets("volume")).toEqual([50, 56, 58]);
    slider.value = "61";
    slider.dispatchEvent(new Event("change"));
    expect(propSets("volume")).toEqual([50, 56, 58, 61]);
    expect(slider.style.getPropertyValue("--fill")).toBe(`${(58 / 130) * 100}%`);
    // The level just set wins over the one in flight from mpv.
    shell.status({ volume: 10 });
    expect(slider.value).toBe("61");
    vi.advanceTimersByTime(601);
    shell.status({ volume: 10 });
    expect(slider.value).toBe("10");
  });

  it("unmutes when the slider is reached for while muted, and the mute button toggles", async () => {
    const shell = await startPlaying();
    shell.status({ mute: true });
    const slider = $("pb-volume") as HTMLInputElement;
    slider.value = "70";
    slider.dispatchEvent(new Event("input"));
    expect(propSets("mute")).toEqual([false]);
    shell.status({ mute: false });
    click($("pb-mute"));
    await flush();
    expect(propSets("mute")).toEqual([false, true]);
  });

  it("steps by five on the arrows, within 0 to 130, and unmutes going up", async () => {
    const shell = await startPlaying();
    shell.status({ volume: 128, mute: true });
    expect(key("ArrowUp").defaultPrevented).toBe(true);
    expect(propSets("volume").at(-1)).toBe(130);
    expect(propSets("mute")).toEqual([false]);
    shell.status({ volume: 3, mute: true });
    // The status above was ignored (touched just now); step from mpv's level
    // once the hold-off has passed.
    fakeTimers();
    vi.advanceTimersByTime(700);
    shell.status({ volume: 3, mute: true });
    key("ArrowDown");
    expect(propSets("volume").at(-1)).toBe(0);
    expect(($("pb-volume") as HTMLInputElement).value).toBe("0");
    // Going down while muted leaves it muted.
    expect(propSets("mute")).toEqual([false]);
  });

  it("m toggles mute", async () => {
    const shell = await startPlaying();
    key("m");
    shell.status({ mute: true });
    key("m");
    expect(propSets("mute")).toEqual([true, false]);
  });
});

describe("playback keys", () => {
  it("Space pauses, and the arrows skip by the interval with a note in the bar", async () => {
    await startPlaying({ config: { player_skip_interval: 15 } });
    expect(key(" ").defaultPrevented).toBe(true);
    expect(invokeCalls("player_pause_toggle")).toHaveLength(1);
    key("ArrowLeft");
    expect(text("pb-state")).toBe("−15 s");
    key("ArrowRight");
    expect(text("pb-state")).toBe("+15 s");
    expect(invokeCalls("player_seek").map((c) => c.args.seconds)).toEqual([-15, 15]);
  });

  it("keeps the note up over the next tick, then lets the state badge back", async () => {
    const shell = await startPlaying();
    fakeTimers();
    key("ArrowRight");
    shell.status({ paused: true });
    expect(text("pb-state")).toBe("+10 s");
    vi.advanceTimersByTime(1801);
    shell.status({ paused: true });
    expect(text("pb-state")).toBe("Paused");
  });

  it("does not seek a live channel", async () => {
    const shell = await bootPlayer();
    await shell.playChannel(CHANNEL);
    key("ArrowLeft");
    key("ArrowRight");
    expect(invokeCalls("player_seek")).toHaveLength(0);
  });

  it("[ and ] step through the preset speeds, stopping at the ends", async () => {
    const shell = await startPlaying();
    key("]");
    expect(propSets("speed")).toEqual([1.25]);
    shell.status({ speed: 2 });
    key("]");
    expect(propSets("speed")).toEqual([1.25, 2]);
    shell.status({ speed: 0.5 });
    key("[");
    expect(propSets("speed")).toEqual([1.25, 2, 0.5]);
    // From an odd speed, step from Normal.
    shell.status({ speed: 1.1 });
    key("[");
    expect(propSets("speed").at(-1)).toBe(0.75);
  });

  it("z and Z shift subtitles by a tenth of a second from mpv's value", async () => {
    const shell = await startPlaying();
    shell.status({ sub_delay: 0.3 });
    key("z");
    key("Z");
    expect(propSets("sub-delay")).toEqual([0.2, 0.4]);
  });

  it("Ctrl+= / Ctrl+- / Ctrl+0 step the audio delay, each press a step (regression: 2dbaa46 audio delay steps reliably)", async () => {
    const shell = await startPlaying();
    expect(key("=", { ctrlKey: true }).defaultPrevented).toBe(true);
    key("+", { ctrlKey: true });
    expect(propSets("audio-delay")).toEqual([0.05, 0.1]);
    expect(text("pb-state")).toBe("Audio delay +100 ms");
    key("-", { ctrlKey: true });
    expect(text("pb-state")).toBe("Audio delay +50 ms");
    key("0", { ctrlKey: true });
    expect(propSets("audio-delay").at(-1)).toBe(0);
    expect(text("pb-state")).toBe("Audio delay 0 ms");
    key("-", { ctrlKey: true });
    expect(text("pb-state")).toBe("Audio delay -50 ms");
    // Any other Ctrl key is not the player's.
    expect(key("s", { ctrlKey: true }).defaultPrevented).toBe(false);
    expect(shell.api.getConfig().audio_delay).toBe(-0.05);
  });

  it("i and Ctrl+I open the Info card", async () => {
    await startPlaying();
    key("i");
    expect(document.querySelector("#player-cards .pb-card")!.getAttribute("data-card")).toBe("info");
    expect($("pb-info").classList.contains("on")).toBe(true);
    key("I", { ctrlKey: true });
    // The pill goes dark at once; the card leaves once the picture is back over its band.
    await flush();
    expect(document.querySelector(".pb-card")).toBeNull();
    expect($("pb-info").classList.contains("on")).toBe(false);
    key("i", { ctrlKey: true });
    expect(document.querySelector("#player-cards .pb-card[data-card=info]")).not.toBeNull();
  });

  it("c turns subtitles off, then back on with the same track", async () => {
    const shell = await startPlaying();
    sendTracks(TRACKS);
    key("c");
    expect(invokeCalls("player_set_track").at(-1)!.args).toEqual({ kind: "sub", track: "no" });
    expect(text("pb-state")).toBe("Subtitles off");
    sendTracks(TRACKS.map((t) => (t.type === "sub" ? { ...t, selected: false } : t)));
    key("C");
    expect(invokeCalls("player_set_track").at(-1)!.args).toEqual({ kind: "sub", track: 3 });
    expect(text("pb-state")).toBe("Subtitles: English");
    void shell;
  });

  it("c brings back a track of the same language when the ids changed, or the first one", async () => {
    await startPlaying();
    sendTracks(TRACKS);
    key("c");
    sendTracks([{ id: 7, type: "sub", lang: "fre" }, { id: 8, type: "sub", lang: "eng" }]);
    key("c");
    expect(invokeCalls("player_set_track").at(-1)!.args).toEqual({ kind: "sub", track: 8 });
    sendTracks([{ id: 9, type: "sub", lang: "fre", selected: true }]);
    key("c");
    sendTracks([{ id: 10, type: "sub", lang: "spa", title: "Español" }]);
    key("c");
    expect(invokeCalls("player_set_track").at(-1)!.args).toEqual({ kind: "sub", track: 10 });
    expect(text("pb-state")).toBe("Subtitles: Español");
  });

  it("c says so when the file has no subtitles", async () => {
    await startPlaying();
    sendTracks([{ id: 1, type: "audio", lang: "eng", selected: true }]);
    key("c");
    expect(text("pb-state")).toBe("No subtitles for this file");
    expect(invokeCalls("player_set_track")).toHaveLength(0);
  });

  it("Page Up and Page Down change channel while one plays, and do nothing otherwise", async () => {
    const shell = await bootPlayer();
    await shell.playChannel(CHANNEL);
    const cache = await import("../../src/cache");
    cache.setCached("livetv:jellyfin", [CHANNEL, { ...CHANNEL, Id: "ch-2", Name: "Two", StreamUrl: undefined }]);
    const ev = key("PageDown");
    expect(ev.defaultPrevented).toBe(true);
    await settle();
    expect(invokeCalls("player_play").at(-1)!.args.req.ctx.item_id).toBe("ch-2");
    shell.stop();
    await settle();
    await shell.play(EPISODE);
    expect(key("PageUp").defaultPrevented).toBe(false);
  });

  it("leaves keys alone while typing, with Alt or Meta, and with nothing playing", async () => {
    const shell = await startPlaying();
    const field = document.createElement("input");
    document.body.append(field);
    key(" ", {}, field);
    key(" ", { altKey: true });
    key(" ", { metaKey: true });
    expect(invokeCalls("player_pause_toggle")).toHaveLength(0);
    shell.stop();
    await settle();
    key(" ");
    expect(invokeCalls("player_pause_toggle")).toHaveLength(0);
  });

  it("Escape gets the window out of a fullscreen no video owns", async () => {
    await startPlaying();
    win.fullscreen = true;
    key("Escape");
    await flush();
    expect(win.setFullscreen).toHaveBeenCalledWith(false);
    win.setFullscreen.mockClear();
    key("Escape");
    await flush();
    expect(win.setFullscreen).not.toHaveBeenCalled();
    win.isFullscreen.mockRejectedValueOnce(new Error("no window"));
    expect(() => key("Escape")).not.toThrow();
  });
});

describe("input relayed from the picture", () => {
  it("does nothing with nothing playing", async () => {
    await bootPlayer();
    input("aquarium-key", "forward");
    input("aquarium-context", "");
    expect(invokeCalls("player_seek")).toHaveLength(0);
    expect(mpvCommands()).toHaveLength(0);
  });

  it("maps mpv's keys to the same actions as the page's", async () => {
    const shell = await startPlaying();
    sendTracks(TRACKS);
    input("aquarium-key", "back");
    input("aquarium-key", "forward");
    expect(invokeCalls("player_seek").map((c) => c.args.seconds)).toEqual([-10, 10]);
    input("aquarium-key", "subtitles");
    expect(text("pb-state")).toBe("Subtitles off");
    input("aquarium-key", "audio-later");
    input("aquarium-key", "audio-earlier");
    input("aquarium-key", "audio-later");
    input("aquarium-key", "audio-reset");
    expect(propSets("audio-delay")).toEqual([0.05, 0, 0.05, 0]);
    input("aquarium-key", "info");
    expect(document.querySelector("#player-cards .pb-card[data-card=info]")).not.toBeNull();
    input("aquarium-key", "shortcuts");
    expect(document.querySelector(".dialog h2")!.textContent).toBe("Keyboard shortcuts");
    input("aquarium-key", "shortcuts");
    expect(document.querySelector(".dialog")).toBeNull();
    input("aquarium-key", "skip");
    input("aquarium-key", "unknown");
    void shell;
  });

  it("maps touch gestures: tap, double-taps, pinch and hold", async () => {
    const shell = await startPlaying();
    input("aquarium-gesture", "doubletap", ["left"]);
    input("aquarium-gesture", "doubletap", ["right"]);
    expect(invokeCalls("player_seek").map((c) => c.args.seconds)).toEqual([-10, 10]);
    input("aquarium-gesture", "pinch-out");
    expect(text("pb-state")).toBe("Fill");
    input("aquarium-gesture", "pinch-in");
    expect(text("pb-state")).toBe("Fit");
    expect(propSets("panscan")).toEqual([1, 0]);
    shell.status({ speed: 1.25 });
    input("aquarium-gesture", "hold-start");
    input("aquarium-gesture", "hold-start");
    expect(text("pb-state")).toBe("2× speed");
    input("aquarium-gesture", "hold-end");
    expect(propSets("speed")).toEqual([2, 2, 1.25]);
    // A release with no hold is nothing.
    input("aquarium-gesture", "hold-end");
    expect(propSets("speed")).toHaveLength(3);
    // A tap outside fullscreen changes nothing.
    input("aquarium-gesture", "tap");
    expect($("player-bar").classList.contains("revealed")).toBe(false);
    // A double-tap in the middle toggles fullscreen.
    input("aquarium-gesture", "doubletap");
    await flush();
    expect(document.body.classList.contains("video-fs")).toBe(true);
    input("aquarium-gesture", "tap");
    expect($("player-bar").classList.contains("revealed")).toBe(true);
    input("aquarium-gesture", "doubletap", ["middle"]);
    await flush();
    expect(document.body.classList.contains("video-fs")).toBe(false);
  });

  it("runs the in-picture menu's commands", async () => {
    await startPlaying({ segments: [{ Type: "Intro", StartTicks: 0, EndTicks: 900_000_000 }] }, { position: 10, duration: 1500 });
    input("aquarium-ctl", "skip");
    expect(invokeCalls("player_seek").at(-1)!.args).toEqual({ seconds: 90, absolute: true });
    input("aquarium-ctl", "info");
    expect(document.querySelector("#player-cards .pb-card[data-card=info]")).not.toBeNull();
    // The entries that open a card or a strip open the bar's own.
    input("aquarium-ctl", "quality");
    expect(document.querySelector("#player-cards .pb-card")!.getAttribute("data-card")).toBe("quality");
    input("aquarium-ctl", "more");
    expect(document.querySelector("#player-cards .pb-card")!.getAttribute("data-card")).toBe("more");
    input("aquarium-ctl", "upnext");
    expect(document.querySelector("#player-bar .pb-panel")!.getAttribute("data-panel")).toBe("episodes");
    input("aquarium-ctl", "upnext");
    input("aquarium-ctl", "stop-after");
    expect(text("pb-state")).toBe("Stopping after this episode");
    input("aquarium-ctl", "stop-after");
    expect(text("pb-state")).toBe("Autoplay back on");
    input("aquarium-ctl", "fill");
    input("aquarium-ctl", "fill");
    expect(propSets("panscan")).toEqual([1, 0]);
    input("aquarium-ctl", "fullscreen");
    await flush();
    expect(document.body.classList.contains("video-fs")).toBe(true);
    input("aquarium-ctl", "stop");
    await flush();
    expect(document.body.classList.contains("video-fs")).toBe(false);
    expect(invokeCalls("player_stop")).toHaveLength(1);
    input("aquarium-ctl", "pip");
    await flush();
    expect(invokeCalls("player_set_pip").at(-1)!.args).toEqual({ on: true });
    // Fullscreen is not offered over PiP.
    input("aquarium-ctl", "fullscreen");
    input("aquarium-gesture", "doubletap");
    await flush();
    expect(document.body.classList.contains("video-fs")).toBe(false);
    input("aquarium-ctl", "stop");
    await flush();
    expect(invokeCalls("player_stop")).toHaveLength(2);
    input("aquarium-ctl", "nonsense");
  });

  it("opens the player's controls as a menu on the picture, reflecting what is playing", async () => {
    const shell = await startPlaying(
      { segments: [{ Type: "Intro", StartTicks: 0, EndTicks: 900_000_000 }] },
      { position: 10, duration: 1500, chapters: [{ time: 60, title: "" }], speed: 1.5 }
    );
    sendTracks(TRACKS);
    await settle();
    input("aquarium-context", "");
    const cmd = mpvCommands().at(-1)!;
    expect(cmd.slice(0, 3)).toEqual(["script-message-to", "uosc", "open-menu"]);
    const menu = JSON.parse(cmd[3]);
    expect(menu.type).toBe("aquarium-player");
    const titles = menu.items.map((i: any) => i.title);
    expect(titles).toEqual([
      "Pause",
      "Back 10 seconds",
      "Forward 10 seconds",
      "Skip intro",
      "Play next",
      "Subtitles",
      "Audio",
      "Speed",
      "Chapters",
      "Quality",
      "Up Next",
      "Sleep timer",
      "Stop after this episode",
      "Fill screen",
      "Info",
      "Fullscreen",
      "Picture in picture",
      "Stop",
    ]);
    const subs = menu.items.find((i: any) => i.title === "Subtitles");
    expect(subs.items.map((i: any) => [i.title, i.active, i.value])).toEqual([
      ["Off", false, "set sid no"],
      ["English", true, "set sid 3"],
      ["French", false, "set sid 4"],
    ]);
    expect(menu.items.find((i: any) => i.title === "Speed").hint).toBe("1.5×");
    expect(menu.items.find((i: any) => i.title === "Chapters").items.map((i: any) => i.title)).toEqual(["Chapter 1", "Chapter 2"]);
    expect(menu.items.find((i: any) => i.title === "Play next").hint).toBe("Archer · Season 1: Episode 3 · The Third One");
    const entry = (title: string) => menu.items.find((i: any) => i.title === title);
    // What the Quality pill says, and how many episodes follow this one.
    expect([entry("Quality").hint, entry("Quality").value]).toEqual(["Auto", "script-message aquarium-ctl quality"]);
    expect([entry("Up Next").hint, entry("Up Next").value]).toEqual(["2", "script-message aquarium-ctl upnext"]);
    expect([entry("Sleep timer").hint, entry("Sleep timer").value]).toEqual(["", "script-message aquarium-ctl more"]);
    expect([entry("Stop after this episode").active, entry("Stop after this episode").value]).toEqual([false, "script-message aquarium-ctl stop-after"]);
    expect([entry("Fill screen").active, entry("Fill screen").value]).toEqual([false, "script-message aquarium-ctl fill"]);
    expect([entry("Info").hint, entry("Info").value]).toEqual(["i", "script-message aquarium-ctl info"]);

    // Paused, one audio track, no chapters, no segment, in fullscreen.
    shell.status({ paused: true, position: 200, chapters: [], speed: 1 });
    sendTracks([{ id: 1, type: "audio", selected: true }]);
    input("aquarium-gesture", "doubletap");
    await flush();
    input("aquarium-context", "");
    const menu2 = JSON.parse(mpvCommands().at(-1)![3]);
    const t2 = menu2.items.map((i: any) => i.title);
    expect(t2[0]).toBe("Play");
    expect(t2).not.toContain("Audio");
    expect(t2).not.toContain("Chapters");
    expect(t2).not.toContain("Skip intro");
    expect(t2).toContain("Leave fullscreen");
    expect(menu2.items.find((i: any) => i.title === "Speed").hint).toBe("Normal");
    expect(menu2.items.find((i: any) => i.title === "Subtitles").items[0].active).toBe(true);
  });

  it("leaves the seek entries out for a live channel, and says Back into the window in PiP", async () => {
    const shell = await bootPlayer();
    await shell.playChannel(CHANNEL);
    input("aquarium-ctl", "pip");
    await flush();
    input("aquarium-context", "");
    const menu = JSON.parse(mpvCommands().at(-1)![3]);
    const titles = menu.items.map((i: any) => i.title);
    expect(titles).not.toContain("Back 10 seconds");
    expect(titles).toContain("Back into the window");
  });

  it("opens no menu before the first status", async () => {
    const shell = await bootPlayer();
    await shell.playback.playItem(EPISODE, {}, { stream: true, quiet: true });
    emitEvent("player-status", { active: false });
    input("aquarium-context", "");
    expect(mpvCommands().filter((c) => c[0] === "script-message-to")).toHaveLength(0);
  });
});
