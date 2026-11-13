// src/adaptive.ts: the policy that moves a stream down a rung when it stalls
// or drops frames, and back up after a long clean stretch.
//
// The player half (src/playback.ts) is replaced by a stand-in whose quality
// state the tests set, and whose switchQuality behaves like the real one: the
// stream restarts at the new rung and announces itself as an inherited start.
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { emitEvent } from "../helpers/tauri";

const m = vi.hoisted(() => ({
  q: null as any,
  enabled: true,
  switchQuality: null as any,
  switchToDownload: null as any,
}));

vi.mock("../../src/playback", async (importOriginal) => {
  const real: any = await importOriginal();
  return {
    ...real,
    getQualityState: () => m.q,
    isAdaptiveEnabled: () => m.enabled,
    switchQuality: (...a: any[]) => m.switchQuality(...a),
    switchToDownload: (...a: any[]) => m.switchToDownload(...a),
  };
});

const RUNGS = [undefined, 35_000_000, 18_000_000, 10_000_000, 5_000_000, 2_500_000];

const started = (inherited = false): void => {
  document.dispatchEvent(new CustomEvent("aquarium-player-started", { detail: { inherited } }));
};

let switches: Array<number | undefined>;
let metas: any[];
let toDownload: number;
let pos: number;

beforeEach(async () => {
  vi.resetModules();
  vi.useFakeTimers();
  vi.setSystemTime(10_000_000);
  document.body.innerHTML = '<div id="toasts"></div>';
  m.enabled = true;
  m.q = { current: undefined, isLocal: false, live: false };
  switches = [];
  metas = [];
  toDownload = 0;
  pos = 0;
  m.switchQuality = vi.fn(async (b: number | undefined, meta: any) => {
    switches.push(b);
    metas.push(meta);
    m.q = { ...m.q, current: b };
    started(true);
  });
  m.switchToDownload = vi.fn(async () => {
    toDownload++;
    return false;
  });
});

let registered: Array<(e: Event) => void> = [];
afterEach(() => {
  for (const fn of registered.splice(0)) document.removeEventListener("aquarium-player-started", fn);
});

async function wire(): Promise<void> {
  const spy = vi.spyOn(document, "addEventListener");
  const { registerAdaptiveQuality } = await import("../../src/adaptive");
  await registerAdaptiveQuality();
  for (const c of spy.mock.calls) if (c[0] === "aquarium-player-started") registered.push(c[1] as any);
  spy.mockRestore();
}

/** Start a stream at rung `idx`, as the user (or, with `inherited`, the app) chose it. */
async function start(idx: number, inherited = false): Promise<void> {
  m.q = { ...m.q, current: RUNGS[idx] };
  pos = 0;
  started(inherited);
}

const wait = (ms: number) => vi.advanceTimersByTimeAsync(ms);
const tick = (fields: Record<string, any> = {}): void =>
  emitEvent("player-status", { active: true, position: pos, buffered: pos + 30, paused: false, buffering: false, ...fields });
const stall = (): void => emitEvent("player-stall", {});

/** Play cleanly for `seconds`, one status tick every 10 s. */
async function playFor(seconds: number, fields: Record<string, any> = {}): Promise<void> {
  for (let s = 0; s < seconds; s += 10) {
    await wait(10_000);
    pos += 10;
    tick(fields);
  }
}

const toastTexts = (): string[] => [...document.querySelectorAll("#toasts .toast")].map((t) => t.textContent ?? "");

describe("stalls", () => {
  it("two stalls within a minute move the stream down one rung, quietly and as an inherited start", async () => {
    await wire();
    await start(0);
    await playFor(20);
    stall();
    await wait(30_000);
    stall();
    await wait(0);
    expect(switches).toEqual([35_000_000]);
    expect(metas).toEqual([{ inherited: true, quiet: true }]);
    expect(toastTexts()).toContain("Buffering — switching to 35 Mbps · 4K");
  });

  it("one stall is a blip", async () => {
    await wire();
    await start(0);
    await playFor(20);
    stall();
    await wait(0);
    expect(switches).toEqual([]);
  });

  it("two stalls more than a minute apart do not add up", async () => {
    await wire();
    await start(0);
    await playFor(20);
    stall();
    await wait(61_000);
    stall();
    await wait(0);
    expect(switches).toEqual([]);
  });

  it("buffering while a stream opens is not evidence (15 s start-up grace)", async () => {
    await wire();
    await start(0);
    await wait(5_000);
    stall();
    stall();
    await wait(0);
    expect(switches).toEqual([]);
  });

  it("after a switch of its own the policy waits 45 s before judging the new stream", async () => {
    await wire();
    await start(3, true);
    await wait(20_000);
    stall();
    stall();
    await wait(0);
    expect(switches).toEqual([]);
    await wait(30_000);
    stall();
    stall();
    await wait(0);
    expect(switches).toEqual([5_000_000]);
  });

  it("a quality the user just picked is watched after the start-up grace, without the 45 s cooldown", async () => {
    await wire();
    await start(3, false);
    await wait(16_000);
    stall();
    stall();
    await wait(0);
    expect(switches).toEqual([5_000_000]);
  });

  it("a single stall that lasts 8 s moves down on its own", async () => {
    await wire();
    await start(1);
    await playFor(20);
    tick({ buffering: true });
    await wait(4_000);
    tick({ buffering: true });
    expect(switches).toEqual([]);
    await wait(4_000);
    tick({ buffering: true });
    await wait(0);
    expect(switches).toEqual([18_000_000]);
  });

  it("a stall that ends before 8 s starts the count again", async () => {
    await wire();
    await start(1);
    await playFor(20);
    tick({ buffering: true });
    await wait(6_000);
    tick({ buffering: false });
    await wait(1_000);
    tick({ buffering: true });
    await wait(6_000);
    tick({ buffering: true });
    await wait(0);
    expect(switches).toEqual([]);
  });

  it("a stall straight after a seek is the seek's doing (12 s grace), whoever seeked", async () => {
    await wire();
    await start(0);
    await playFor(30);
    // Forward: the picture moved 300 s in 1 s of clock.
    await wait(1_000);
    pos += 300;
    tick();
    stall();
    stall();
    await wait(0);
    expect(switches).toEqual([]);
    await wait(13_000);
    pos += 13;
    tick();
    stall();
    stall();
    await wait(0);
    expect(switches).toEqual([35_000_000]);
  });

  it("a backward jump also counts as a seek", async () => {
    await wire();
    await start(0);
    await playFor(60);
    await wait(1_000);
    pos -= 40;
    tick();
    stall();
    stall();
    await wait(0);
    expect(switches).toEqual([]);
  });

  it("a stalled stream standing still while the clock moves is not a seek (regression: elapsed-time seek detection)", async () => {
    await wire();
    await start(0);
    await playFor(20);
    // Position frozen for 30 s of clock: moved - elapsed is very negative but
    // the picture never went backwards.
    await wait(30_000);
    tick({ buffering: true });
    await wait(1_000);
    stall();
    stall();
    await wait(0);
    expect(switches).toEqual([35_000_000]);
  });

  it("a stall while its own switch is still in flight is ignored", async () => {
    await wire();
    await start(0);
    await playFor(20);
    let finish!: () => void;
    m.switchQuality = vi.fn(
      (b: number) =>
        new Promise<void>((r) => {
          switches.push(b);
          finish = r;
        })
    );
    stall();
    stall();
    await wait(0);
    stall();
    stall();
    await wait(0);
    expect(switches).toEqual([35_000_000]);
    finish();
    await wait(0);
  });

  it("says so when the automatic switch fails", async () => {
    await wire();
    await start(0);
    await playFor(20);
    m.switchQuality = vi.fn(async () => {
      throw new Error("server said no");
    });
    stall();
    stall();
    await wait(0);
    expect(toastTexts()).toContain("Couldn't change quality automatically");
  });
});

describe("dropped frames", () => {
  it("120 frames dropped in 20 s move down, with a message about keeping up", async () => {
    await wire();
    await start(2);
    await playFor(20, { dropped_frames: 0 });
    await wait(20_000);
    pos += 20;
    tick({ dropped_frames: 150 });
    await wait(0);
    expect(switches).toEqual([10_000_000]);
    expect(toastTexts()).toContain("Playback can't keep up — switching to 10 Mbps · 1080p");
  });

  it("a handful over a long time is normal", async () => {
    await wire();
    await start(2);
    await playFor(20, { dropped_frames: 0 });
    let frames = 0;
    for (let i = 0; i < 10; i++) {
      frames += 50;
      await playFor(20, { dropped_frames: frames });
    }
    expect(switches).toEqual([]);
  });

  it("frames counted while paused are ignored, and a tick without a count is skipped", async () => {
    await wire();
    await start(2);
    await playFor(20, { dropped_frames: 0 });
    await wait(20_000);
    tick({ dropped_frames: 500, paused: true });
    tick({});
    await wait(0);
    expect(switches).toEqual([]);
  });
});

describe("the bottom rung", () => {
  it("at the lowest rung it says once that the network is the limit, and does nothing else", async () => {
    await wire();
    await start(5);
    await playFor(20);
    stall();
    stall();
    await wait(1_000);
    stall();
    stall();
    await wait(0);
    expect(switches).toEqual([]);
    expect(toastTexts().filter((t) => t.startsWith("Still struggling"))).toEqual([
      "Still struggling at 2.5 Mbps · 480p — the network or the server is the limit",
    ]);
  });
});

describe("the downloaded copy", () => {
  it("is taken before any lower rung when there is one", async () => {
    await wire();
    m.q = { ...m.q, download: "720p · 4.5 Mbps" };
    m.switchToDownload = vi.fn(async (meta: any) => {
      expect(meta).toEqual({ inherited: true, quiet: true });
      toDownload++;
      return true;
    });
    await start(0);
    await playFor(20);
    stall();
    stall();
    await wait(0);
    expect(toDownload).toBe(1);
    expect(switches).toEqual([]);
    expect(toastTexts()).toContain("Buffering — switching to the downloaded copy");
  });

  it("dropped frames say the same thing their own way", async () => {
    await wire();
    m.q = { ...m.q, download: "Original quality" };
    m.switchToDownload = vi.fn(async () => true);
    await start(0);
    await playFor(20, { dropped_frames: 0 });
    await wait(20_000);
    pos += 20;
    tick({ dropped_frames: 400 });
    await wait(0);
    expect(toastTexts()).toContain("Playback can't keep up — switching to the downloaded copy");
  });

  it("falls through to the ladder when the download has gone, or the switch throws", async () => {
    await wire();
    m.q = { ...m.q, download: "Original quality" };
    await start(0);
    await playFor(20);
    stall();
    stall();
    await wait(0);
    expect(toDownload).toBe(1);
    expect(switches).toEqual([35_000_000]);

    m.switchToDownload = vi.fn(async () => {
      throw new Error("gone");
    });
    await wait(50_000);
    stall();
    stall();
    await wait(0);
    expect(switches).toEqual([35_000_000, 18_000_000]);
  });
});

describe("Direct Play steps down onto a rung that is actually lighter", () => {
  it("skips transcode rungs at or above the source's own bitrate", async () => {
    await wire();
    m.q = { ...m.q, sourceBitrate: 12_000_000 };
    await start(0);
    await playFor(20);
    stall();
    stall();
    await wait(0);
    expect(switches).toEqual([10_000_000]);
  });

  it("lands on the lowest rung when every rung is heavier than the source", async () => {
    await wire();
    m.q = { ...m.q, sourceBitrate: 1_000_000 };
    await start(0);
    await playFor(20);
    stall();
    stall();
    await wait(0);
    expect(switches).toEqual([2_500_000]);
  });

  it("with no source bitrate just takes the next rung", async () => {
    await wire();
    await start(0);
    await playFor(20);
    stall();
    stall();
    await wait(0);
    expect(switches).toEqual([35_000_000]);
  });
});

describe("climbing back", () => {
  async function droppedOnce(): Promise<void> {
    await wire();
    await start(0);
    await playFor(20);
    stall();
    stall();
    await wait(0);
    expect(switches).toEqual([35_000_000]);
    pos = 0;
  }

  it("after five clean minutes with a healthy read-ahead it goes back up one rung", async () => {
    await droppedOnce();
    await playFor(290);
    expect(switches).toEqual([35_000_000]);
    await playFor(20);
    expect(switches).toEqual([35_000_000, undefined]);
    expect(metas[1]).toEqual({ inherited: true, quiet: true });
    expect(toastTexts()).toContain("Connection looks steady — back to Direct Play (original)");
  });

  it("never climbs above the rung the user picked", async () => {
    await wire();
    await start(3);
    await playFor(700);
    expect(switches).toEqual([]);
  });

  it("a thin read-ahead, buffering or a pause is not healthy", async () => {
    await droppedOnce();
    await playFor(400, { buffered: 5 });
    await playFor(400, { paused: true });
    expect(switches).toEqual([35_000_000]);
  });

  it("a rung that stalls within 90 s of climbing to it becomes the ceiling for the session", async () => {
    await wire();
    await start(1);
    await playFor(20);
    stall();
    stall();
    await wait(0);
    expect(switches).toEqual([18_000_000]);
    pos = 0;
    await playFor(320);
    expect(switches).toEqual([18_000_000, 35_000_000]);
    // Stalls again inside the probation, past the 45 s cooldown.
    pos = 0;
    await playFor(50);
    stall();
    stall();
    await wait(0);
    expect(switches).toEqual([18_000_000, 35_000_000, 18_000_000]);
    pos = 0;
    await playFor(900);
    expect(switches).toEqual([18_000_000, 35_000_000, 18_000_000]);
  });

  it("a stall long after climbing does not lower the ceiling", async () => {
    await wire();
    await start(1);
    await playFor(20);
    stall();
    stall();
    await wait(0);
    pos = 0;
    await playFor(320);
    expect(switches).toEqual([18_000_000, 35_000_000]);
    pos = 0;
    await playFor(200);
    stall();
    stall();
    await wait(0);
    pos = 0;
    await playFor(320);
    expect(switches).toEqual([18_000_000, 35_000_000, 18_000_000, 35_000_000]);
  });

  it("a failed climb stays put quietly and does not start a probation", async () => {
    await droppedOnce();
    m.switchQuality = vi.fn(async () => {
      throw new Error("nope");
    });
    await playFor(310);
    expect(toastTexts()).not.toContain("Couldn't change quality automatically");
    expect(m.q.current).toBe(35_000_000);
  });

  it("an inherited start never moves the ceiling above what is playing", async () => {
    await wire();
    await start(3);
    // The next episode, inherited, at a better rung than the ceiling: the ceiling stays.
    await start(1, true);
    await playFor(400);
    expect(switches).toEqual([]);
  });
});

describe("when it stays out of the way", () => {
  it.each([
    ["turned off", () => (m.enabled = false)],
    ["nothing playing", () => (m.q = null)],
    ["a downloaded file", () => (m.q = { isLocal: true, live: false })],
    ["live TV", () => (m.q = { live: true, isLocal: false })],
  ])("%s", async (_name, set) => {
    await wire();
    await start(0);
    set();
    await playFor(20, { dropped_frames: 0 });
    stall();
    stall();
    tick({ buffering: true });
    await wait(10_000);
    tick({ buffering: true, dropped_frames: 999 });
    await wait(30_000);
    tick({ dropped_frames: 2000 });
    await wait(0);
    expect(switches).toEqual([]);
    expect(toDownload).toBe(0);
  });

  it("an unknown bitrate reads as the top rung", async () => {
    await wire();
    m.q = { ...m.q, current: 7_777_777 };
    started(false);
    await playFor(20);
    stall();
    stall();
    await wait(0);
    expect(switches).toEqual([35_000_000]);
  });

  it("the end of playback resets the session's ceiling", async () => {
    await wire();
    await start(3);
    emitEvent("player-status", { active: false });
    // An inherited start after the reset may climb to the top again.
    await start(1, true);
    await wait(50_000);
    pos = 0;
    await playFor(320);
    expect(switches).toEqual([undefined]);
  });

  it("a start with no quality state counts as the top rung", async () => {
    await wire();
    m.q = null;
    started(false);
    m.q = { current: 35_000_000, isLocal: false, live: false };
    await playFor(320);
    expect(switches).toEqual([undefined]);
  });
});
