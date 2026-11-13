// src/scroll.ts: display-paced wheel scrolling.
//
// jsdom has no layout and no animation frames, so the container's scroll
// geometry and requestAnimationFrame are both stood in for here.
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { wireSmoothScroll } from "../../src/scroll";

let frames: Map<number, FrameRequestCallback>;
let nextId: number;
let clock: number;

beforeEach(() => {
  frames = new Map();
  nextId = 1;
  clock = 1000;
  vi.stubGlobal("requestAnimationFrame", (cb: FrameRequestCallback) => {
    const id = nextId++;
    frames.set(id, cb);
    return id;
  });
  vi.stubGlobal("cancelAnimationFrame", (id: number) => frames.delete(id));
  vi.spyOn(performance, "now").mockImplementation(() => clock);
});

afterEach(() => {
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

/** Run one display frame `ms` after the last. */
function frame(ms = 16): void {
  clock += ms;
  const pending = [...frames.entries()];
  frames.clear();
  for (const [, cb] of pending) cb(clock);
}

/** Run frames until the loop stops asking for one; returns how many ran. */
function settle(max = 1000, ms = 16): number {
  let n = 0;
  while (frames.size && n < max) {
    frame(ms);
    n++;
  }
  return n;
}

interface Geometry {
  scrollHeight: number;
  clientHeight: number;
  /** Round written positions to whole pixels, as some engines do. */
  whole?: boolean;
}

function scroller(g: Partial<Geometry> = {}): { el: HTMLElement; geo: Geometry; writes: number[] } {
  const geo: Geometry = { scrollHeight: 3000, clientHeight: 600, ...g };
  const el = document.createElement("div");
  document.body.append(el);
  let top = 0;
  const writes: number[] = [];
  Object.defineProperties(el, {
    scrollHeight: { get: () => geo.scrollHeight },
    clientHeight: { get: () => geo.clientHeight },
    scrollTop: {
      get: () => top,
      set: (v: number) => {
        writes.push(v);
        const max = Math.max(0, geo.scrollHeight - geo.clientHeight);
        top = Math.max(0, Math.min(max, geo.whole ? Math.round(v) : v));
      },
    },
  });
  return { el, geo, writes };
}

function wheel(target: Element, init: WheelEventInit = {}): WheelEvent {
  const ev = new WheelEvent("wheel", { deltaY: 100, bubbles: true, cancelable: true, ...init });
  target.dispatchEvent(ev);
  return ev;
}

describe("wireSmoothScroll: a wheel notch becomes a destination", () => {
  it("eases toward the notch's destination over several frames and lands exactly on it", () => {
    const { el } = scroller();
    wireSmoothScroll(el);
    const ev = wheel(el);
    expect(ev.defaultPrevented).toBe(true);
    expect(el.scrollTop).toBe(0); // nothing jumps on the event itself
    frame();
    const first = el.scrollTop;
    expect(first).toBeGreaterThan(0);
    expect(first).toBeLessThan(100);
    const n = settle();
    expect(n).toBeGreaterThan(3);
    expect(el.scrollTop).toBe(100);
    expect(frames.size).toBe(0);
  });

  it("is framerate-independent: 120 Hz and 60 Hz cover the same distance in the same time", () => {
    const a = scroller();
    const b = scroller();
    wireSmoothScroll(a.el);
    wireSmoothScroll(b.el);
    wheel(a.el, { deltaY: 400 });
    // Drive the two separately so their frames don't interleave.
    const pendingA = [...frames.entries()];
    frames.clear();
    wheel(b.el, { deltaY: 400 });
    const pendingB = [...frames.entries()];
    frames.clear();

    frames = new Map(pendingA);
    for (let i = 0; i < 12; i++) frame(8.33); // ~100 ms at 120 Hz
    frames.clear();
    frames = new Map(pendingB);
    clock = 1000;
    for (let i = 0; i < 6; i++) frame(16.67); // ~100 ms at 60 Hz
    frames.clear();
    expect(Math.abs(a.el.scrollTop - b.el.scrollTop)).toBeLessThan(3);
  });

  it("turns CSS smooth scrolling off while animating and hands it back when done", () => {
    const { el } = scroller();
    el.style.scrollBehavior = "smooth";
    wireSmoothScroll(el);
    wheel(el);
    expect(el.style.scrollBehavior).toBe("auto");
    settle();
    expect(el.style.scrollBehavior).toBe("");
  });

  it("notches during a flick add up from the destination, not from where the page is mid-way", () => {
    const { el } = scroller();
    wireSmoothScroll(el);
    wheel(el);
    frame();
    wheel(el);
    frame();
    wheel(el);
    settle();
    expect(el.scrollTop).toBe(300);
  });

  it("converts line and page deltas to pixels", () => {
    const lines = scroller();
    wireSmoothScroll(lines.el);
    wheel(lines.el, { deltaY: 3, deltaMode: 1 });
    settle();
    expect(lines.el.scrollTop).toBe(48);

    const pages = scroller({ clientHeight: 500 });
    wireSmoothScroll(pages.el);
    wheel(pages.el, { deltaY: 1, deltaMode: 2 });
    settle();
    expect(pages.el.scrollTop).toBe(500);
  });

  it("scrolls up as well as down, and stops at the top", () => {
    const { el } = scroller();
    el.scrollTop = 150;
    wireSmoothScroll(el);
    wheel(el, { deltaY: -100 });
    settle();
    expect(el.scrollTop).toBe(50);
    wheel(el, { deltaY: -100 });
    settle();
    expect(el.scrollTop).toBe(0);
  });

  it("the ceiling is re-read every frame: a page that shrinks mid-flick ends at its new bottom", () => {
    const { el, geo } = scroller({ scrollHeight: 2000, clientHeight: 500 });
    wireSmoothScroll(el);
    wheel(el, { deltaY: 1200 });
    frame();
    geo.scrollHeight = 1100; // max 600
    settle();
    expect(el.scrollTop).toBe(600);
  });

  it("stops asking for frames when the target can't be represented (regression: quantised offsets kept the loop alive forever)", () => {
    const { el } = scroller({ whole: true });
    wireSmoothScroll(el);
    wheel(el, { deltaY: 100.4 });
    const n = settle(1000);
    expect(n).toBeLessThan(1000);
    expect(frames.size).toBe(0);
    expect(el.scrollTop).toBe(100);
  });
});

describe("wireSmoothScroll: events it leaves alone", () => {
  it.each([
    ["Ctrl+wheel (zoom)", { ctrlKey: true }],
    ["Alt+wheel", { altKey: true }],
    ["a mostly horizontal gesture", { deltaX: 200, deltaY: 50 }],
    ["a small trackpad-sized delta", { deltaY: 10 }],
  ])("%s", (_label, init) => {
    const { el } = scroller();
    wireSmoothScroll(el);
    const ev = wheel(el, init);
    expect(ev.defaultPrevented).toBe(false);
    expect(frames.size).toBe(0);
  });

  it("an event something else already handled", () => {
    const { el } = scroller();
    const child = document.createElement("div");
    el.append(child);
    child.addEventListener("wheel", (e) => e.preventDefault());
    wireSmoothScroll(el);
    wheel(child);
    expect(frames.size).toBe(0);
  });

  it("everything, when the desktop asks for reduced motion", () => {
    vi.spyOn(window, "matchMedia").mockImplementation((q: string) => ({ matches: q.includes("reduce"), media: q }) as any);
    const { el } = scroller();
    wireSmoothScroll(el);
    expect(wheel(el).defaultPrevented).toBe(false);
  });

  it("a page with nothing to scroll", () => {
    const { el } = scroller({ scrollHeight: 400, clientHeight: 600 });
    wireSmoothScroll(el);
    expect(wheel(el).defaultPrevented).toBe(false);
  });

  it("a notch against the end, so overscroll can do what it would normally do", () => {
    const { el } = scroller({ scrollHeight: 1000, clientHeight: 600 });
    el.scrollTop = 400;
    wireSmoothScroll(el);
    expect(wheel(el).defaultPrevented).toBe(false);
    expect(wheel(el, { deltaY: -100 }).defaultPrevented).toBe(true);
  });

  it.each([".menu", ".guide-scroll"])("the wheel over an overflowing %s, which scrolls itself", (sel) => {
    const { el } = scroller();
    const nested = document.createElement("div");
    nested.className = sel.slice(1);
    Object.defineProperty(nested, "scrollHeight", { value: 900 });
    Object.defineProperty(nested, "clientHeight", { value: 300 });
    const inner = document.createElement("span");
    nested.append(inner);
    el.append(nested);
    wireSmoothScroll(el);
    expect(wheel(inner).defaultPrevented).toBe(false);
  });

  it("but takes the wheel over a .menu that has nothing to scroll", () => {
    const { el } = scroller();
    const nested = document.createElement("div");
    nested.className = "menu";
    Object.defineProperty(nested, "scrollHeight", { value: 300 });
    Object.defineProperty(nested, "clientHeight", { value: 300 });
    el.append(nested);
    wireSmoothScroll(el);
    expect(wheel(nested).defaultPrevented).toBe(true);
  });

  it("and ignores a .menu ancestor outside the container", () => {
    const outer = document.createElement("div");
    outer.className = "menu";
    Object.defineProperty(outer, "scrollHeight", { value: 9000 });
    Object.defineProperty(outer, "clientHeight", { value: 10 });
    document.body.append(outer);
    const { el } = scroller();
    outer.append(el);
    wireSmoothScroll(el);
    expect(wheel(el).defaultPrevented).toBe(true);
  });
});

describe("wireSmoothScroll: other scrolls and teardown", () => {
  it("a jump from elsewhere (Back, spatial navigation) cancels the animation rather than fighting it", () => {
    const { el } = scroller();
    wireSmoothScroll(el);
    wheel(el, { deltaY: 500 });
    frame();
    frame();
    el.scrollTop = 1500; // someone else's scroll
    el.dispatchEvent(new Event("scroll"));
    expect(frames.size).toBe(0);
    expect(el.style.scrollBehavior).toBe("");
    expect(el.scrollTop).toBe(1500);
  });

  it("its own writes do not cancel it", () => {
    const { el } = scroller();
    wireSmoothScroll(el);
    wheel(el, { deltaY: 500 });
    frame();
    frame();
    el.dispatchEvent(new Event("scroll"));
    expect(frames.size).toBe(1);
  });

  it("a new notch after an outside jump starts from the new position", () => {
    const { el } = scroller();
    wireSmoothScroll(el);
    wheel(el, { deltaY: 500 });
    frame();
    el.scrollTop = 1000;
    el.dispatchEvent(new Event("scroll"));
    wheel(el, { deltaY: 100 });
    settle();
    expect(el.scrollTop).toBe(1100);
  });

  it("the teardown removes both listeners and stops a running animation", () => {
    const { el } = scroller();
    const off = wireSmoothScroll(el);
    wheel(el);
    expect(frames.size).toBe(1);
    off();
    expect(frames.size).toBe(0);
    expect(wheel(el).defaultPrevented).toBe(false);
  });
});
