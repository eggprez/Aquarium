// src/main.ts: the player bar. Something is started through the real
// playback.ts (see helpers/main-shell.ts), mpv's status ticks are emitted as
// the backend would, and what is asserted is the bar's drawing and the
// commands its buttons, keys and panels send.
import { afterEach, describe, expect, it, vi } from "vitest";
import { emitEvent, flush, invokeCalls, onInvoke } from "../helpers/tauri";
import {
  bootShell,
  buttonNamed,
  CHANNEL,
  click,
  EPISODE,
  fakeTimers,
  key,
  mouseLeave,
  MOVIE,
  mpvCommands,
  panel,
  propSets,
  settle,
  teardownShell,
  toasts,
  bootPlayer,
  startPlaying,
  sendTracks,
  EP1,
  EP3,
  SEASON,
} from "../helpers/main-shell";

afterEach(teardownShell);

const $ = (id: string): HTMLElement => document.getElementById(id)!;
const text = (id: string): string => $(id).textContent ?? "";

const boot = bootPlayer;
const playing = startPlaying;
const tracks = sendTracks;

const SUBS = [
  { id: 1, type: "audio", lang: "eng", selected: true },
  { id: 2, type: "audio", lang: "jpn", title: "Japanese 5.1" },
  { id: 3, type: "sub", lang: "eng", selected: false },
  { id: 4, type: "sub", lang: "und" },
];

function pick(label: string): void {
  click(buttonNamed(label, panel()!));
}

describe("bar lifecycle", () => {
  it("comes up on the first active status with the show and its number above the episode's name, and goes on stop", async () => {
    const shell = await playing();
    const bar = $("player-bar");
    expect(bar.classList.contains("hidden")).toBe(false);
    expect($("content").classList.contains("has-player")).toBe(true);
    // The episode's own name is the bold line; the show and where this falls
    // in it are the kicker, drawn above it (`kicker-first` reorders the two).
    expect(text("pb-title")).toBe("The Second One");
    expect(text("pb-subtitle")).toBe("Archer · S1 E2");
    expect($("pb-title").parentElement!.classList.contains("kicker-first")).toBe(true);
    // The whole one-line title lives in the tooltip.
    expect($("pb-title").title).toBe("Archer Season 1, Episode 2 · The Second One");
    expect($("pb-subtitle").title).toBe("Archer · S1 E2");
    expect(document.body.classList.contains("video-covered")).toBe(true);
    shell.stop();
    await settle();
    expect(bar.classList.contains("hidden")).toBe(true);
    expect($("content").classList.contains("has-player")).toBe(false);
    expect(document.body.classList.contains("video-covered")).toBe(false);
  });

  it("names a film by itself, an episode without numbers under its show alone, and one without a name by its show", async () => {
    const shell = await playing({}, {}, MOVIE);
    expect(text("pb-title")).toBe("Heat");
    expect(text("pb-subtitle")).toBe("");
    expect($("pb-title").parentElement!.classList.contains("kicker-first")).toBe(false);
    shell.stop();
    await shell.play({ ...EPISODE, ParentIndexNumber: undefined });
    expect(text("pb-title")).toBe("The Second One");
    expect(text("pb-subtitle")).toBe("Archer");
    expect($("pb-title").parentElement!.classList.contains("kicker-first")).toBe(true);
    shell.stop();
    // Nothing to put under a kicker: the show is the title, its number below.
    await shell.play({ ...EPISODE, Name: undefined });
    expect(text("pb-title")).toBe("Archer");
    expect(text("pb-subtitle")).toBe("S1 E2");
    expect($("pb-title").parentElement!.classList.contains("kicker-first")).toBe(false);
  });

  it("spells a downloaded episode's lower-case record the same way (regression: the bold line showed mpv's one-line title)", async () => {
    const shell = await boot();
    await shell.playLocal({ item_id: "dl-1", path: "/v/a.mkv", series: "Archer", season: 9, episode: 7, name: "Fugue", title: "Archer S09E07 · Fugue" });
    expect(text("pb-title")).toBe("Fugue");
    expect(text("pb-subtitle")).toBe("Archer · S9 E7");
    expect($("pb-title").parentElement!.classList.contains("kicker-first")).toBe(true);
    shell.stop();
    await shell.playLocal({ item_id: "dl-2", path: "/v/b.mkv", series: "Archer", name: "Special", title: "x" });
    expect(text("pb-title")).toBe("Special");
    expect(text("pb-subtitle")).toBe("Archer");
    shell.stop();
    await shell.playLocal({ item_id: "dl-3", path: "/v/c.mkv", type: "Movie", series: "Saga", name: "Heat", title: "Heat (1995)" });
    expect(text("pb-title")).toBe("Heat");
    shell.stop();
    await shell.playLocal({ item_id: "dl-4", path: "/v/d.mkv", title: "" }, { title: "" });
    expect(text("pb-title")).toBe("Playing");
  });

  it("names a channel and what is on it", async () => {
    const shell = await boot();
    await shell.playChannel(CHANNEL);
    expect(text("pb-title")).toContain("News One");
    expect($("player-bar").classList.contains("live")).toBe(true);
    expect(text("pb-dur")).toBe("live");
  });

  it("does not cover the page while mpv plays in a window of its own, and hides fullscreen and PiP then", async () => {
    await playing({}, { embedded: false });
    expect(document.body.classList.contains("video-covered")).toBe(false);
    expect($("pb-fullscreen").style.display).toBe("none");
    expect($("pb-pip").style.display).toBe("none");
  });

  it("keeps the bar up while the next episode is being fetched", async () => {
    let release: (v: any) => void = () => {};
    const hang = new Promise((r) => (release = r));
    const shell = await playing({ episodes: () => hang });
    emitEvent("player-status", { active: false, ended: true, position: 1490, duration: 1500, item_id: "ep-2" });
    await flush();
    expect($("player-bar").classList.contains("hidden")).toBe(false);
    expect(text("pb-state")).toBe("Loading next episode…");
    release({ Items: [] });
    await settle();
    // Autoplay found nothing: the bar is torn down by aquarium-autoplay-none.
    expect($("player-bar").classList.contains("hidden")).toBe(true);
    void shell;
  });

  it("redraws on aquarium-bar-refresh without waiting for a tick (regression: bc28e10 channel switch title)", async () => {
    await playing();
    $("pb-title").textContent = "stale";
    document.dispatchEvent(new CustomEvent("aquarium-bar-refresh"));
    expect(text("pb-title")).toBe("The Second One");
  });

  it("ignores aquarium-bar-refresh with nothing playing", async () => {
    await boot();
    document.dispatchEvent(new CustomEvent("aquarium-bar-refresh"));
    expect($("player-bar").classList.contains("hidden")).toBe(true);
  });
});

describe("state, clocks and scrubber", () => {
  it("badges Paused and Buffering, and swaps the play/pause glyph", async () => {
    const shell = await playing();
    expect(text("pb-state")).toBe("");
    shell.status({ paused: true });
    expect(text("pb-state")).toBe("Paused");
    const pausedIcon = $("pb-playpause").innerHTML;
    shell.status({ paused: false, buffering: true });
    expect(text("pb-state")).toBe("Buffering…");
    expect($("pb-playpause").innerHTML).not.toBe(pausedIcon);
  });

  it("says a speed other than normal next to the title", async () => {
    const shell = await playing();
    shell.status({ speed: 1.5 });
    expect(text("pb-state")).toBe("1.5× speed");
    shell.status({ paused: true });
    expect(text("pb-state")).toBe("Paused");
  });

  it("shows the position and the length, or the time left once clicked, and remembers the choice", async () => {
    const shell = await playing({}, { position: 65, duration: 1500 });
    expect(text("pb-pos")).toBe("1:05");
    expect(text("pb-dur")).toBe("25:00");
    click($("pb-dur"));
    expect(text("pb-dur")).toBe("−23:55");
    expect(shell.api.getConfig().player_show_remaining).toBe(true);
    shell.status({ position: 1600 });
    expect(text("pb-dur")).toBe("−0:00");
    click($("pb-dur"));
    expect(text("pb-dur")).toBe("25:00");
  });

  it("moves the scrubber with the playhead, and the buffer never behind it", async () => {
    const shell = await playing({}, { position: 750, duration: 1500, buffered: 900 });
    const range = $("pb-range") as HTMLInputElement;
    expect(range.value).toBe("500");
    expect(range.style.getPropertyValue("--fill")).toBe("50%");
    expect(range.style.getPropertyValue("--buffered")).toBe("60%");
    shell.status({ buffered: 10 });
    expect(range.style.getPropertyValue("--buffered")).toBe("50%");
  });

  it("does not fight a drag, and seeks to where the scrubber is let go", async () => {
    const shell = await playing({}, { position: 0, duration: 1000 });
    const range = $("pb-range") as HTMLInputElement;
    range.value = "250";
    range.dispatchEvent(new Event("input"));
    expect(range.style.getPropertyValue("--fill")).toBe("25%");
    shell.status({ position: 10 });
    expect(range.value).toBe("250");
    range.dispatchEvent(new Event("change"));
    expect(invokeCalls("player_seek").at(-1)!.args).toEqual({ seconds: 250, absolute: true });
    shell.status({ position: 10 });
    expect(range.value).toBe("10");
  });

  it("does not seek on a scrubber with no length", async () => {
    await playing({}, { duration: 0 });
    const range = $("pb-range") as HTMLInputElement;
    range.value = "500";
    range.dispatchEvent(new Event("change"));
    expect(invokeCalls("player_seek")).toHaveLength(0);
  });

  it("remembers the decoder mpv settled on, once per change, for Settings", async () => {
    const shell = await playing({}, { hwdec: "vaapi" });
    expect(localStorage.getItem("aquarium.hwdec-last")).toBe("vaapi");
    const set = vi.spyOn(Storage.prototype, "setItem");
    shell.status({ hwdec: "vaapi" });
    expect(set.mock.calls.filter((c) => c[0] === "aquarium.hwdec-last")).toHaveLength(0);
    set.mockImplementation(() => {
      throw new Error("quota");
    });
    expect(() => shell.status({ hwdec: "no" })).not.toThrow();
    set.mockRestore();
  });
});

describe("transport buttons", () => {
  it("skips by the interval from Settings, with the number drawn in the glyph", async () => {
    const shell = await playing({ config: { player_skip_interval: 30 } });
    expect($("pb-back").title).toBe("Back 30s (←)");
    expect($("pb-fwd").innerHTML).toContain(">30</text>");
    click($("pb-back"));
    click($("pb-fwd"));
    await flush();
    expect(invokeCalls("player_seek").map((c) => c.args)).toEqual([
      { seconds: -30, absolute: false },
      { seconds: 30, absolute: false },
    ]);
    // A change in Settings applies on the next tick.
    shell.api.getConfig().player_skip_interval = 15;
    shell.status();
    expect($("pb-fwd").title).toBe("Forward 15s (→)");
    expect($("pb-back").innerHTML).toContain(">15</text>");
  });

  it("pauses, stops and leaves", async () => {
    await playing();
    click($("pb-playpause"));
    click($("pb-stop"));
    click($("pb-exit"));
    await flush();
    expect(invokeCalls("player_pause_toggle")).toHaveLength(1);
    expect(invokeCalls("player_stop")).toHaveLength(2);
  });

  it("logs every click, and a failing one, to the debug log", async () => {
    await playing();
    onInvoke("player_stop", () => Promise.reject(new Error("no player")));
    click($("pb-stop"));
    await flush();
    const msgs = invokeCalls("ui_log").map((c) => c.args.msg);
    expect(msgs).toContain("click pb-stop");
    expect(msgs).toContain("click pb-stop error: Error: no player");
  });

  it("lets go of a button after a pointer click, but not after a keyboard one (regression: 849e879 focus ring on the last button pressed)", async () => {
    await playing();
    const btn = $("pb-playpause") as HTMLButtonElement;
    btn.focus();
    click(btn, { detail: 0 });
    expect(document.activeElement).toBe(btn);
    click(btn, { detail: 1 });
    expect(document.activeElement).not.toBe(btn);
    // A click on the bar itself, not a button, changes nothing.
    click($("pb-title"));
  });

  it("jumps to the end of an intro or credits from the skip button, and only inside one", async () => {
    const shell = await playing({
      segments: [
        { Type: "Intro", StartTicks: 100_000_000, EndTicks: 900_000_000 },
        { Type: "Outro", StartTicks: 13_000_000_000, EndTicks: 14_000_000_000 },
        { Type: "Intro", StartTicks: 50, EndTicks: 50 },
      ],
    });
    const skip = $("pb-skip");
    shell.status({ position: 5, duration: 1500 });
    expect(skip.classList.contains("on")).toBe(false);
    shell.status({ position: 30 });
    expect(skip.classList.contains("on")).toBe(true);
    expect(skip.textContent).toBe("Skip intro");
    click(skip);
    expect(invokeCalls("player_seek").at(-1)!.args).toEqual({ seconds: 90, absolute: true });
    // Not in the last second of the segment.
    shell.status({ position: 89.5 });
    expect(skip.classList.contains("on")).toBe(false);
    shell.status({ position: 1350 });
    expect(skip.textContent).toBe("Skip credits");
    // `s` does the same, and says so in the badge.
    key("s");
    expect(invokeCalls("player_seek").at(-1)!.args).toEqual({ seconds: 1400, absolute: true });
    expect(text("pb-state")).toBe("Skip credits");
    // Credits that run to the end of the file have nothing to skip to.
    shell.status({ duration: 1400.5 });
    expect(skip.classList.contains("on")).toBe(false);
    key("S");
    expect(invokeCalls("player_seek")).toHaveLength(2);
  });
});

describe("chapters and the scrubber readout", () => {
  const CHAPTERS = [
    { time: 0, title: "Cold open" },
    { time: 300, title: "" },
    { time: 900, title: "Finale" },
    { time: 2000, title: "Past the end" },
  ];

  function scrubAt(frac: number, width = 500): void {
    const scrub = document.querySelector<HTMLElement>(".pb-scrub")!;
    scrub.getBoundingClientRect = () => ({ left: 0, width, top: 0, height: 10, right: width, bottom: 10, x: 0, y: 0, toJSON() {} }) as DOMRect;
    scrub.dispatchEvent(new MouseEvent("mousemove", { bubbles: true, clientX: frac * width }));
  }

  it("marks the chapters on the scrubber, redraws only when the list changes, and offers their list under More only when there are any", async () => {
    const shell = await playing({}, { duration: 1500, chapters: CHAPTERS });
    const marks = [...$("pb-chapters").querySelectorAll<HTMLElement>("i")];
    expect(marks.map((m) => m.style.left)).toEqual(["0%", "20%", "60%"]);
    expect(marks.map((m) => m.title)).toEqual(["Cold open", "5:00", "Finale"]);
    // The chapter list has no pill of its own: it is a row of the More card.
    const moreRows = (): string[] => {
      click($("pb-more"));
      const rows = [...document.querySelectorAll("#player-cards .pb-card-row")].map((r) => r.textContent ?? "");
      click($("pb-more"));
      return rows;
    };
    // The four mpv reported, and the stretch before the first.
    expect(moreRows()).toContain("Chapters5 in this file");
    marks[0]!.remove();
    shell.status({ position: 1 });
    expect($("pb-chapters").querySelectorAll("i")).toHaveLength(2);
    shell.status({ chapters: [] });
    expect($("pb-chapters").querySelectorAll("i")).toHaveLength(0);
    expect(moreRows().some((r) => r.startsWith("Chapters"))).toBe(false);
  });

  it("names the chapter and the time under the pointer, clamped to the bar", async () => {
    await playing({}, { duration: 1500, chapters: CHAPTERS });
    const tip = $("pb-tip");
    scrubAt(0.1);
    expect(tip.querySelector("b")!.textContent).toBe("Cold open");
    expect(tip.textContent).toBe("Cold open2:30");
    expect(tip.style.left).toBe("50px");
    // An untitled chapter names nothing.
    scrubAt(0.5);
    expect(tip.querySelector("b")).toBeNull();
    expect(tip.textContent).toBe("12:30");
    scrubAt(0.7);
    expect(tip.querySelector("b")!.textContent).toBe("Finale");
    // The bubble cannot hang off either end.
    scrubAt(0);
    expect(tip.style.left).toBe("26px");
    scrubAt(1.2);
    expect(tip.style.left).toBe("474px");
    expect(tip.textContent).toBe("Finale25:00");
  });

  it("hides the readout over a scrubber with no length", async () => {
    await playing({}, { duration: 0 });
    scrubAt(0.5);
    expect($("pb-tip").style.opacity).toBe("0");
    scrubAt(0.5, 0);
    expect($("pb-tip").style.opacity).toBe("0");
  });

  it("previews the frame under the pointer from the trickplay sheets, fetching each sheet once", async () => {
    const trickplay = {
      MediaSources: [{ Id: "src-1" }],
      Trickplay: { "src-1": { "320": { Width: 320, Height: 180, TileWidth: 10, TileHeight: 10, Interval: 10_000, ThumbnailCount: 150 } } },
    };
    onInvoke("jf_image", "data:image/jpeg;base64,AAAA");
    await playing({ trickplay }, { duration: 1500 });
    const box = $("pb-preview");
    const img = $("pb-preview-img");
    // 750 s is thumbnail 75: sheet 0, column 5, row 7.
    scrubAt(0.5);
    expect(box.classList.contains("on")).toBe(true);
    expect(text("pb-preview-time")).toBe("12:30");
    expect(img.style.backgroundImage).toBe("");
    await flush();
    scrubAt(0.5);
    expect(invokeCalls("jf_image")).toHaveLength(1);
    expect(invokeCalls("jf_image")[0]!.args.path).toBe("/Videos/ep-2/Trickplay/320/0.jpg?mediaSourceId=src-1");
    expect(img.style.backgroundImage).toBe('url("data:image/jpeg;base64,AAAA")');
    expect(img.style.width).toBe("100px");
    expect(img.style.height).toBe("56px");
    expect(img.style.backgroundSize).toBe("1000px 560px");
    expect(img.style.backgroundPosition).toBe("-500px -392px");
    // A sheet that failed is not asked for again on every move.
    onInvoke("jf_image", () => Promise.reject(new Error("404")));
    scrubAt(0.9);
    await flush();
    scrubAt(0.9);
    expect(invokeCalls("jf_image")).toHaveLength(2);
    mouseLeave(document.querySelector(".pb-scrub")!);
    expect(box.classList.contains("on")).toBe(false);
  });

  it("shows no preview without trickplay", async () => {
    await playing({}, { duration: 1500 });
    scrubAt(0.5);
    expect($("pb-preview").classList.contains("on")).toBe(false);
  });
});
