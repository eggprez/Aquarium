// src/main.ts: fullscreen playback (the bar that slides up over the video and
// hides again), picture-in-picture, and the quit prompt that has to get the
// picture out of its way.
//
// The pointer tests are the Linux/CLAUDE.md invariant: pointer-driven UI over
// the video ignores out-of-window and repeated mousemoves (`fsPointerMoved`),
// because WebKitGTK turns enter/leave crossings into mousemoves and taking
// them as motion was a reveal/hide loop.
import { afterEach, describe, expect, it, vi } from "vitest";
import { emitEvent, flush, invokeCalls, onInvoke } from "../helpers/tauri";
import {
  bootPlayer,
  click,
  EPISODE,
  fakeTimers,
  key,
  mouseLeave,
  mouseMove,
  propSets,
  settle,
  startPlaying,
  teardownShell,
  toasts,
  win,
  type PlayWorld,
  type Shell,
} from "../helpers/main-shell";

afterEach(teardownShell);

const $ = (id: string): HTMLElement => document.getElementById(id)!;
const bar = (): HTMLElement => $("player-bar");
const revealed = (): boolean => bar().classList.contains("revealed");
const viewports = (): any[] => invokeCalls("player_set_viewport").map((c) => c.args);

/** Playing, in fullscreen, with fake timers; the entry flash already shown. */
async function fullscreen(w: PlayWorld = {}): Promise<Shell> {
  const shell = await startPlaying(w, { position: 10, duration: 1500 });
  fakeTimers();
  key("f");
  await flush();
  return shell;
}

function videoMouse(x?: number, y?: number): void {
  emitEvent("player-mouse", x === undefined ? null : { x, y, hover: true });
}

describe("entering and leaving", () => {
  it("f takes the video and the window fullscreen, paints the app black behind it, and flashes the controls", async () => {
    await fullscreen();
    expect(document.body.classList.contains("video-fs")).toBe(true);
    expect(bar().classList.contains("fs")).toBe(true);
    expect(win.setFullscreen).toHaveBeenCalledWith(true);
    expect(viewports()).toEqual([
      { full: true, bar: false },
      { full: true, bar: true },
    ]);
    expect(revealed()).toBe(true);
    // Subtitles are lifted clear of the bar while it is up.
    expect(propSets("sub-pos")).toEqual([93]);
  });

  it("hides the controls after the time in Settings, and puts the subtitles back", async () => {
    await fullscreen({ config: { player_hide_after: 4 } });
    vi.advanceTimersByTime(3999);
    expect(revealed()).toBe(true);
    vi.advanceTimersByTime(1);
    expect(revealed()).toBe(false);
    expect(viewports().at(-1)).toEqual({ full: true, bar: false });
    expect(propSets("sub-pos")).toEqual([93, 100]);
  });

  it("lifts subtitles no lower than Settings put them, and returns them there (regression: a963a95 sub-pos)", async () => {
    await fullscreen({ config: { sub_pos: 80 } });
    vi.advanceTimersByTime(2000);
    expect(propSets("sub-pos")).toEqual([80, 80]);
  });

  it("reads a damaged subtitle position as the bottom edge", async () => {
    await fullscreen({ config: { sub_pos: "low" } });
    expect(propSets("sub-pos")).toEqual([93]);
  });

  it("leaving mid-reveal puts the subtitles back instead of stranding them lifted", async () => {
    await fullscreen({ config: { sub_pos: 95 } });
    key("f");
    await flush();
    expect(document.body.classList.contains("video-fs")).toBe(false);
    expect(bar().classList.contains("fs")).toBe(false);
    expect(propSets("sub-pos")).toEqual([93, 95]);
    expect(win.setFullscreen).toHaveBeenLastCalledWith(false);
    // The timer that would have hidden the bar is gone with fullscreen.
    vi.advanceTimersByTime(5000);
    expect(viewports().at(-1)).toEqual({ full: false, bar: false });
  });

  it("Escape, the button, the exit button and the toggle events all leave or toggle it", async () => {
    const shell = await fullscreen();
    key("Escape");
    await flush();
    expect(document.body.classList.contains("video-fs")).toBe(false);
    click($("pb-fullscreen"));
    await flush();
    expect(document.body.classList.contains("video-fs")).toBe(true);
    document.dispatchEvent(new CustomEvent("aquarium-fullscreen-exit"));
    await flush();
    expect(document.body.classList.contains("video-fs")).toBe(false);
    document.dispatchEvent(new CustomEvent("aquarium-fullscreen-exit"));
    document.dispatchEvent(new CustomEvent("aquarium-fullscreen-toggle"));
    await flush();
    expect(document.body.classList.contains("video-fs")).toBe(true);
    click($("pb-exit"));
    await flush();
    expect(document.body.classList.contains("video-fs")).toBe(false);
    expect(invokeCalls("player_stop")).toHaveLength(1);
    void shell;
  });

  it("does not toggle without an embedded video", async () => {
    await startPlaying({}, { embedded: false });
    key("f");
    document.dispatchEvent(new CustomEvent("aquarium-fullscreen-toggle"));
    await flush();
    expect(document.body.classList.contains("video-fs")).toBe(false);
  });

  it("carries on when the window or the backend refuses", async () => {
    await startPlaying();
    win.setFullscreen.mockRejectedValueOnce(new Error("not allowed"));
    onInvoke("player_set_viewport", () => Promise.reject(new Error("no surface")));
    key("f");
    await flush();
    expect(document.body.classList.contains("video-fs")).toBe(true);
    expect(revealed()).toBe(true);
  });

  it("leaves fullscreen when playback ends for good", async () => {
    const shell = await fullscreen();
    shell.stop();
    await flush();
    expect(document.body.classList.contains("video-fs")).toBe(false);
  });

  it("starts what was picked from the page windowed, and keeps a continuation fullscreen", async () => {
    const shell = await fullscreen();
    document.dispatchEvent(new CustomEvent("aquarium-player-started", { detail: { continuation: true } }));
    await flush();
    expect(document.body.classList.contains("video-fs")).toBe(true);
    // Re-asserted, since the backend reset its viewport for the new file.
    expect(viewports().filter((v) => v.full && !v.bar).length).toBe(2);
    document.dispatchEvent(new CustomEvent("aquarium-player-started", { detail: {} }));
    await flush();
    expect(document.body.classList.contains("video-fs")).toBe(false);
    // Windowed already: nothing to decide.
    const n = viewports().length;
    document.dispatchEvent(new CustomEvent("aquarium-player-started"));
    await flush();
    expect(viewports().length).toBe(n);
    void shell;
  });
});

describe("the hidden bar does no work", () => {
  it("skips drawing ticks while out of sight, and catches up as it comes back", async () => {
    const shell = await fullscreen();
    vi.advanceTimersByTime(2000);
    expect(revealed()).toBe(false);
    shell.status({ position: 600 });
    expect($("pb-pos").textContent).toBe("0:10");
    mouseMove(100, 100);
    expect(revealed()).toBe(true);
    expect($("pb-pos").textContent).toBe("10:00");
  });

  it("draws every tick again once back in a window", async () => {
    const shell = await fullscreen();
    vi.advanceTimersByTime(2000);
    shell.status({ position: 700 });
    key("Escape");
    await flush();
    expect($("pb-pos").textContent).toBe("11:40");
  });
});

describe("pointer over the video (regression: WebKitGTK crossing mousemoves caused a reveal/hide loop)", () => {
  it("a real move reveals the hidden bar", async () => {
    await fullscreen();
    vi.advanceTimersByTime(2000);
    expect(revealed()).toBe(false);
    mouseMove(300, 200);
    expect(revealed()).toBe(true);
  });

  it("ignores a move at the position the pointer already had", async () => {
    await fullscreen();
    mouseMove(300, 200);
    vi.advanceTimersByTime(2000);
    expect(revealed()).toBe(false);
    // The bar hid and the video grew back under a still pointer; WebKit
    // re-hit-tests and reports a move to the same coordinates.
    mouseMove(300, 200);
    expect(revealed()).toBe(false);
  });

  it("ignores moves reported outside the window, and does not take them as the new baseline", async () => {
    await fullscreen();
    mouseMove(300, 200);
    vi.advanceTimersByTime(2000);
    for (const [x, y] of [
      [-1, 200],
      [300, -1],
      [window.innerWidth, 200],
      [300, window.innerHeight],
    ]) {
      mouseMove(x!, y!);
      expect(revealed(), `${x},${y}`).toBe(false);
    }
    // Back to where it was before the crossing: still not a move.
    mouseMove(300, 200);
    expect(revealed()).toBe(false);
    mouseMove(301, 200);
    expect(revealed()).toBe(true);
  });

  it("a move outside fullscreen reveals nothing", async () => {
    await startPlaying();
    mouseMove(10, 10);
    expect(revealed()).toBe(false);
    expect(viewports()).toEqual([]);
  });

  it("each real move restarts the hide clock", async () => {
    await fullscreen();
    vi.advanceTimersByTime(1500);
    mouseMove(5, 5);
    vi.advanceTimersByTime(1500);
    expect(revealed()).toBe(true);
    vi.advanceTimersByTime(500);
    expect(revealed()).toBe(false);
  });

  it("mpv's pointer reports reveal the bar, but not a repeat of the same position", async () => {
    await fullscreen();
    videoMouse(500, 400);
    vi.advanceTimersByTime(2000);
    expect(revealed()).toBe(false);
    // Re-emitted because the widget changed size: geometry, not motion.
    videoMouse(500, 400);
    expect(revealed()).toBe(false);
    videoMouse(501, 400);
    expect(revealed()).toBe(true);
    // A report without coordinates counts once.
    vi.advanceTimersByTime(2000);
    videoMouse();
    expect(revealed()).toBe(true);
    vi.advanceTimersByTime(2000);
    videoMouse();
    expect(revealed()).toBe(false);
  });
});

describe("pointer over the bar", () => {
  it("never hides under the pointer, and hides once it leaves", async () => {
    await fullscreen();
    mouseMove(10, 700, bar());
    vi.advanceTimersByTime(10_000);
    expect(revealed()).toBe(true);
    mouseLeave(bar());
    vi.advanceTimersByTime(2000);
    expect(revealed()).toBe(false);
  });

  it("does not latch hovered when the bar slides up under a still pointer (regression: the bar stayed up for good)", async () => {
    await fullscreen();
    mouseMove(10, 700);
    vi.advanceTimersByTime(2000);
    expect(revealed()).toBe(false);
    videoMouse(1, 1);
    expect(revealed()).toBe(true);
    // The bar arrived under the cursor; WebKit reports that as a move at the
    // coordinates the pointer already had.
    mouseMove(10, 700, bar());
    vi.advanceTimersByTime(2000);
    expect(revealed()).toBe(false);
  });

  it("a leave restarts the clock but never reveals (regression: a hide, a leave, a reveal, round and round)", async () => {
    await fullscreen();
    vi.advanceTimersByTime(2000);
    expect(revealed()).toBe(false);
    mouseLeave(bar());
    expect(revealed()).toBe(false);
    vi.advanceTimersByTime(5000);
    expect(revealed()).toBe(false);
  });

  it("a leave while shown hides it a full interval later, not at the old deadline", async () => {
    await fullscreen();
    vi.advanceTimersByTime(1500);
    mouseLeave(bar());
    vi.advanceTimersByTime(1000);
    expect(revealed()).toBe(true);
    vi.advanceTimersByTime(1000);
    expect(revealed()).toBe(false);
  });

  it("the pointer on the video clears a stuck hover", async () => {
    await fullscreen();
    mouseMove(10, 700, bar());
    videoMouse(200, 200);
    vi.advanceTimersByTime(2000);
    expect(revealed()).toBe(false);
  });

  it("leaving the window clears it too", async () => {
    await fullscreen();
    mouseMove(10, 700, bar());
    window.dispatchEvent(new Event("blur"));
    vi.advanceTimersByTime(2000);
    expect(revealed()).toBe(false);
  });

  it("re-entering fullscreen starts with no hover carried over", async () => {
    await fullscreen();
    mouseMove(10, 700, bar());
    key("f");
    await flush();
    key("f");
    await flush();
    vi.advanceTimersByTime(2000);
    expect(revealed()).toBe(false);
  });

  it("stays up while a strip is open in the bar", async () => {
    await fullscreen();
    click($("pb-episodes"));
    expect(document.querySelector("#player-bar .pb-panel")).not.toBeNull();
    vi.advanceTimersByTime(6000);
    expect(revealed()).toBe(true);
    click($("pb-episodes"));
    vi.advanceTimersByTime(2000);
    expect(revealed()).toBe(false);
  });

  it("comes up for a card opened from a pill, and stays up while it is open", async () => {
    await fullscreen();
    vi.advanceTimersByTime(2000);
    expect(revealed()).toBe(false);
    // The band the card is drawn in is cut above the bar, so the bar must be up.
    click($("pb-audio"));
    expect(document.querySelector("#player-cards .pb-card")).not.toBeNull();
    expect(revealed()).toBe(true);
    vi.advanceTimersByTime(6000);
    expect(revealed()).toBe(true);
    click($("pb-audio"));
    vi.advanceTimersByTime(2000);
    expect(revealed()).toBe(false);
  });

  it("a hover outside fullscreen means nothing", async () => {
    await startPlaying();
    mouseMove(10, 700, bar());
    mouseLeave(bar());
    expect(revealed()).toBe(false);
  });
});

describe("controls that reveal the bar", () => {
  it("a note in the bar, the stream info and a tap all bring it up", async () => {
    await fullscreen();
    vi.advanceTimersByTime(2000);
    key("ArrowRight");
    expect(revealed()).toBe(true);
    vi.advanceTimersByTime(2000);
    key("i");
    expect(revealed()).toBe(true);
    key("i");
    vi.advanceTimersByTime(2000);
    document.dispatchEvent(new CustomEvent("aquarium-player-input", { detail: { name: "aquarium-gesture", arg: "tap" } }));
    expect(revealed()).toBe(true);
  });

  it("the timer does nothing once fullscreen is gone without it being cleared", async () => {
    const shell = await fullscreen();
    // Playback ended mid-reveal: fullscreen is left from the teardown path.
    shell.stop();
    await flush();
    vi.advanceTimersByTime(5000);
    expect(revealed()).toBe(false);
  });
});

describe("picture in picture", () => {
  it("p moves the picture into a corner window and back, and the bar says so", async () => {
    await startPlaying();
    key("p");
    await flush();
    expect(invokeCalls("player_set_pip").at(-1)!.args).toEqual({ on: true });
    const btn = $("pb-pip");
    expect(bar().classList.contains("pip")).toBe(true);
    expect(btn.classList.contains("on")).toBe(true);
    expect(btn.getAttribute("aria-pressed")).toBe("true");
    expect(btn.title).toBe("Bring the video back into the window (p)");
    expect(($("pb-fullscreen") as HTMLButtonElement).disabled).toBe(true);
    // The page is being browsed: nothing is covered.
    expect(document.body.classList.contains("video-covered")).toBe(false);
    // f does nothing over PiP.
    key("f");
    await flush();
    expect(document.body.classList.contains("video-fs")).toBe(false);
    click(btn);
    await flush();
    expect(invokeCalls("player_set_pip").at(-1)!.args).toEqual({ on: false });
    expect(btn.title).toBe("Picture in picture (p)");
    expect(document.body.classList.contains("video-covered")).toBe(true);
  });

  it("leaves fullscreen first", async () => {
    await fullscreen();
    key("p");
    await flush();
    expect(document.body.classList.contains("video-fs")).toBe(false);
    expect(bar().classList.contains("pip")).toBe(true);
  });

  it("says why when the backend refuses, and stays in the window", async () => {
    await startPlaying();
    onInvoke("player_set_pip", () => Promise.reject("No compositor support for PiP"));
    key("p");
    await flush();
    expect(toasts()).toContain("No compositor support for PiP");
    expect(bar().classList.contains("pip")).toBe(false);
  });

  it("does not try without an embedded surface", async () => {
    await startPlaying({}, { embedded: false });
    key("p");
    await flush();
    expect(invokeCalls("player_set_pip")).toHaveLength(0);
  });

  it("follows the floating window being closed from its own title bar", async () => {
    await startPlaying();
    key("p");
    await flush();
    emitEvent("player-pip", { on: false });
    expect(bar().classList.contains("pip")).toBe(false);
    emitEvent("player-pip", null);
    expect(bar().classList.contains("pip")).toBe(false);
  });

  it("closes the floating window when playback is over for good", async () => {
    const shell = await startPlaying();
    key("p");
    await flush();
    shell.stop();
    await flush();
    expect(invokeCalls("player_set_pip").at(-1)!.args).toEqual({ on: false });
  });
});

describe("quit while downloading", () => {
  function dialogButton(label: string): HTMLButtonElement {
    return [...document.querySelectorAll<HTMLButtonElement>(".dialog button")].find((b) => b.textContent === label)!;
  }

  it("asks, and Quit anyway confirms the close", async () => {
    await bootPlayer();
    emitEvent("quit-requested", { downloads: 2 });
    await settle();
    expect(document.querySelector(".dialog h2")!.textContent).toBe("2 downloads are still running");
    expect(document.querySelector(".dialog p")!.textContent).toContain("Quitting now stops those transfers");
    dialogButton("Quit anyway").click();
    expect(invokeCalls("quit_confirm")[0]!.args).toEqual({ quit: true });
    expect(document.querySelector(".dialog")).toBeNull();
  });

  it("speaks of one download in the singular", async () => {
    await bootPlayer();
    emitEvent("quit-requested", { downloads: 1 });
    await settle();
    expect(document.querySelector(".dialog h2")!.textContent).toBe("1 download is still running");
    expect(document.querySelector(".dialog p")!.textContent).toContain("Quitting now stops the transfer");
  });

  it("a second close while it is up is the same question, not another dialog (regression: a963a95)", async () => {
    await bootPlayer();
    emitEvent("quit-requested", { downloads: 2 });
    await settle();
    emitEvent("quit-requested", { downloads: 2 });
    await settle();
    expect(document.querySelectorAll(".dialog")).toHaveLength(1);
    dialogButton("Keep downloading").click();
    emitEvent("quit-requested", {});
    await settle();
    expect(document.querySelector(".dialog h2")!.textContent).toBe("0 downloads are still running");
  });

  it("moves an embedded picture into PiP so the prompt can be seen, and back on Keep downloading (regression: a963a95 prompt under the video)", async () => {
    await startPlaying();
    emitEvent("quit-requested", { downloads: 1 });
    await settle();
    expect(invokeCalls("player_set_pip").map((c) => c.args.on)).toEqual([true]);
    expect(document.querySelector(".dialog")).not.toBeNull();
    dialogButton("Keep downloading").click();
    await flush();
    expect(invokeCalls("player_set_pip").map((c) => c.args.on)).toEqual([true, false]);
  });

  it("comes back from PiP when the prompt is dismissed, too", async () => {
    await startPlaying();
    emitEvent("quit-requested", { downloads: 1 });
    await settle();
    key("Escape", {}, document.body);
    await flush();
    expect(invokeCalls("player_set_pip").map((c) => c.args.on)).toEqual([true, false]);
  });

  it("stops the picture when PiP is refused, rather than ask under it", async () => {
    await startPlaying();
    onInvoke("player_set_pip", () => Promise.reject("no PiP"));
    emitEvent("quit-requested", { downloads: 1 });
    await settle();
    expect(invokeCalls("player_stop")).toHaveLength(1);
    expect(document.querySelector(".dialog")).not.toBeNull();
    dialogButton("Keep downloading").click();
    await flush();
    expect(invokeCalls("player_set_pip")).toHaveLength(1);
  });

  it("leaves a picture already in PiP where it is", async () => {
    await startPlaying();
    key("p");
    await flush();
    emitEvent("quit-requested", { downloads: 1 });
    await settle();
    dialogButton("Keep downloading").click();
    await flush();
    expect(invokeCalls("player_set_pip").map((c) => c.args.on)).toEqual([true]);
  });
});

describe("the player stops when the account changes", () => {
  it("stops what was playing before switching", async () => {
    const shell = await startPlaying({ invokes: { account_switch: null } });
    document.dispatchEvent(new CustomEvent("aquarium-account-switch", { detail: { key: "k2" } }));
    await settle();
    expect(invokeCalls("player_stop")).toHaveLength(1);
    void shell;
    void EPISODE;
  });
});

describe("test hooks visible from the frontend", () => {
  it("a stream the backend started by itself (AQUARIUM_TEST_PLAY) gets a bar titled from mpv's own title", async () => {
    await bootPlayer();
    emitEvent("player-status", { active: true, embedded: true, title: "Aquarium test playback", position: 3, duration: 60 });
    expect($("player-bar").classList.contains("hidden")).toBe(false);
    expect($("pb-title").textContent).toBe("Aquarium test playback");
    expect($("pb-pos").textContent).toBe("0:03");
  });

  it("AQUARIUM_TEST_SEQUENCE's pip/nopip steps, reported back as player-pip, are reflected in the bar", async () => {
    await startPlaying();
    emitEvent("player-pip", { on: true });
    expect(bar().classList.contains("pip")).toBe(true);
    emitEvent("player-pip", { on: false });
    expect(bar().classList.contains("pip")).toBe(false);
  });

  it("mpv's own fullscreen messages (its key bindings and uosc) toggle and leave fullscreen", async () => {
    await startPlaying();
    emitEvent("player-message", ["aquarium-fullscreen"]);
    await flush();
    expect(document.body.classList.contains("video-fs")).toBe(true);
    emitEvent("player-message", ["aquarium-fullscreen-exit"]);
    await flush();
    expect(document.body.classList.contains("video-fs")).toBe(false);
    // Exit never enters.
    emitEvent("player-message", ["aquarium-fullscreen-exit"]);
    await flush();
    expect(document.body.classList.contains("video-fs")).toBe(false);
  });

  it("mpv's key messages reach the bar through player-message", async () => {
    await startPlaying();
    emitEvent("player-message", ["aquarium-key", "forward"]);
    emitEvent("player-message", ["aquarium-gesture", "doubletap", "left"]);
    await flush();
    expect(invokeCalls("player_seek").map((c) => c.args.seconds)).toEqual([10, -10]);
  });
});
