// src/blurhash.ts: BlurHash placeholders decoded to a data URL.
//
// jsdom has no canvas, so each test that needs a decode installs a small fake
// 2D context that keeps the pixels written to it.
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { base83, fakeCanvas } from "../helpers/small-modules";

type Mod = typeof import("../../src/blurhash");
let bh: Mod;

beforeEach(async () => {
  vi.resetModules();
  bh = await import("../../src/blurhash");
});

afterEach(() => {
  vi.restoreAllMocks();
});

/** A one-component hash (a single flat colour). */
function flat(r: number, g: number, b: number): string {
  return "0" + "0" + base83((r << 16) | (g << 8) | b, 4);
}

describe("blurhashUrl", () => {
  it.each([null, undefined, "", "abc", "LEHV6"])("answers null for %j, which is too short to be a hash", (h) => {
    const canvas = fakeCanvas();
    expect(bh.blurhashUrl(h as any)).toBeNull();
    expect(canvas.renders).toBe(0);
  });

  it("answers null for a hash whose length does not match its component counts (truncated or corrupt)", () => {
    const canvas = fakeCanvas();
    // Size flag 'L' asks for 4x3 components, so 28 characters; this is 10.
    expect(bh.blurhashUrl("LEHV6nWB2y")).toBeNull();
    expect(canvas.renders).toBe(0);
  });

  it.each([
    ["an invalid size flag", "é00AAAA"],
    ["an invalid quantisation digit", "0éAAAA"],
    ["an invalid DC digit", "00AAéA"],
  ])("answers null for %s", (_label, hash) => {
    fakeCanvas();
    expect(bh.blurhashUrl(hash)).toBeNull();
  });

  it("answers null for an invalid AC digit", () => {
    fakeCanvas();
    // Size flag 1: numX 2, numY 1, so 4 + 4 = 8 characters, the last pair AC.
    expect(bh.blurhashUrl("10" + base83(0x808080, 4) + "0é")).toBeNull();
  });

  it("decodes a one-component hash to a flat image of that colour", () => {
    const canvas = fakeCanvas();
    const url = bh.blurhashUrl(flat(200, 100, 50), 4);
    expect(url).toBe("data:image/png;fake-1");
    const px = canvas.last!;
    expect(px.length).toBe(4 * 4 * 4);
    for (let o = 0; o < px.length; o += 4) {
      expect([px[o], px[o + 1], px[o + 2], px[o + 3]]).toEqual([200, 100, 50, 255]);
    }
  });

  it("round-trips black and white through linear light without drifting", () => {
    const canvas = fakeCanvas();
    bh.blurhashUrl(flat(0, 0, 0), 2);
    expect(Array.from(canvas.last!.slice(0, 4))).toEqual([0, 0, 0, 255]);
    bh.blurhashUrl(flat(255, 255, 255), 2);
    expect(Array.from(canvas.last!.slice(0, 4))).toEqual([255, 255, 255, 255]);
  });

  it("an AC component makes a horizontal gradient: one side brighter than the other", () => {
    const canvas = fakeCanvas();
    // numX 2, numY 1. AC value 18*19*19 + 18*19 + 18 is the largest positive
    // coefficient on every channel; quantMax 82 makes it large.
    const ac = 18 * 19 * 19 + 18 * 19 + 18;
    const url = bh.blurhashUrl("1" + base83(82, 1) + base83(0x808080, 4) + base83(ac, 2), 8);
    expect(url).not.toBeNull();
    const px = canvas.last!;
    const left = px[0]!;
    const right = px[4 * 7]!;
    expect(left).toBeGreaterThan(right);
    // Every value is clamped into a byte.
    for (const v of px) expect(v).toBeGreaterThanOrEqual(0);
    for (const v of px) expect(v).toBeLessThanOrEqual(255);
  });

  it("decodes a real 4x3 hash from Jellyfin into a full image", () => {
    const canvas = fakeCanvas();
    const url = bh.blurhashUrl("LEHV6nWB2yk8pyo0adR*.7kCMdnj");
    expect(url).toMatch(/^data:image\/png/);
    expect(canvas.last!.length).toBe(32 * 32 * 4);
    expect(canvas.size).toBe(32);
  });

  it("decodes each hash once per size, so a re-render asks nothing of the canvas (cache)", () => {
    const canvas = fakeCanvas();
    const h = flat(10, 20, 30);
    const a = bh.blurhashUrl(h);
    const b = bh.blurhashUrl(h);
    expect(a).toBe(b);
    expect(canvas.renders).toBe(1);
    bh.blurhashUrl(h, 16);
    expect(canvas.renders).toBe(2);
  });

  it("remembers a hash that could not be decoded, too", () => {
    const canvas = fakeCanvas({ toDataURLThrows: true });
    const h = flat(1, 2, 3);
    expect(bh.blurhashUrl(h)).toBeNull();
    expect(bh.blurhashUrl(h)).toBeNull();
    expect(canvas.renders).toBe(1);
  });

  it("starts the cache over after 400 entries rather than growing without bound", () => {
    const canvas = fakeCanvas();
    const first = flat(0, 0, 1);
    bh.blurhashUrl(first, 1);
    for (let i = 2; i <= 400; i++) bh.blurhashUrl(flat(0, i >> 8, i & 255), 1);
    expect(canvas.renders).toBe(400);
    bh.blurhashUrl(first, 1);
    expect(canvas.renders).toBe(400); // still cached: 400 entries, at the limit
    bh.blurhashUrl(flat(1, 0, 0), 1); // the 401st clears the map
    bh.blurhashUrl(first, 1);
    expect(canvas.renders).toBe(402);
  });

  it("answers null when the canvas has no 2D context", () => {
    vi.spyOn(HTMLCanvasElement.prototype, "getContext").mockReturnValue(null);
    expect(bh.blurhashUrl(flat(5, 5, 5))).toBeNull();
  });

  it("answers null when the canvas refuses to export (a tainted or failed canvas)", () => {
    fakeCanvas({ toDataURLThrows: true });
    expect(bh.blurhashUrl(flat(9, 9, 9))).toBeNull();
  });
});
