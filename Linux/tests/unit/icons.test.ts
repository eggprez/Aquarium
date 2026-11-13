// src/icons.ts: the app's SVG icon set.
import { describe, expect, it } from "vitest";
import { icon, iconSvg, type IconName } from "../../src/icons";

const ALL: IconName[] = [
  "play", "download", "check", "star", "star-outline", "close", "trash", "pause", "folder", "shuffle",
  "chevron-left", "chevron-right", "chevron-down", "arrow-left",
  "search", "library", "tv", "episodes", "people", "error", "disk",
];

describe("iconSvg", () => {
  it.each(ALL)("%s is a 24x24, decorative, non-focusable SVG with drawing in it", (name) => {
    const host = document.createElement("div");
    host.innerHTML = iconSvg(name);
    const svg = host.querySelector("svg")!;
    expect(svg).not.toBeNull();
    expect(svg.getAttribute("viewBox")).toBe("0 0 24 24");
    expect(svg.getAttribute("aria-hidden")).toBe("true");
    expect(svg.getAttribute("focusable")).toBe("false");
    expect(svg.querySelectorAll("path, circle, rect").length).toBeGreaterThan(0);
    // Every shape draws in the text colour, so icons follow the theme.
    for (const shape of svg.querySelectorAll("path, circle, rect")) {
      expect(shape.outerHTML).toContain("currentColor");
    }
  });

  it("the play triangle and the filled star are solid; the outline star is not", () => {
    expect(iconSvg("play")).toContain('fill="currentColor"');
    expect(iconSvg("star")).toContain('fill="currentColor"');
    expect(iconSvg("star-outline")).toContain('fill="none"');
  });

  it("the filled and outline stars share one shape", () => {
    const d = (s: string) => /d="([^"]+)"/.exec(s)![1];
    expect(d(iconSvg("star"))).toBe(d(iconSvg("star-outline")));
  });

  it("the Downloads view's pause and folder icons exist (regression: f0902f2 added them for Pause all and Show in Files)", () => {
    expect(iconSvg("pause")).toContain("<path");
    expect(iconSvg("folder")).toContain("<path");
  });

  // BUG: STROKE already carries stroke-width="1.8", and the icons that ask for
  // their own weight append a second stroke-width attribute after it. The HTML
  // parser keeps the FIRST of two duplicate attributes, so every per-icon
  // weight (2.2 check and chevrons, 2.1 close, 1.6 for the lighter empty-state
  // icons the comment describes) is dropped and all of them draw at 1.8.
  // src/icons.ts:16 (STROKE) with :27, :30, :33, :37-39, :43-49.
  it.fails.each([
    ["check", "2.2"],
    ["close", "2.1"],
    ["chevron-right", "2.2"],
    ["search", "1.6"],
    ["error", "1.6"],
  ] as [IconName, string][])("%s draws at its own stroke width %s", (name, width) => {
    const host = document.createElement("div");
    host.innerHTML = iconSvg(name);
    const shape = host.querySelector("svg > *")!;
    expect(shape.getAttribute("stroke-width")).toBe(width);
  });

  it("an unknown name (from untyped code) draws the error icon rather than nothing", () => {
    expect(iconSvg("no-such-icon" as IconName)).toBe(iconSvg("error"));
  });

  it("no icon is a Unicode glyph (they fell back to whatever symbol font was installed)", () => {
    for (const n of ALL) expect(iconSvg(n)).not.toMatch(/[▶⬇✓★▸←]/);
  });
});

describe("icon", () => {
  it("wraps the SVG in a hidden .ico span sized by the text around it", () => {
    const s = icon("check");
    expect(s.tagName).toBe("SPAN");
    expect(s.className).toBe("ico");
    expect(s.getAttribute("aria-hidden")).toBe("true");
    expect(s.style.cssText).toBe("");
    const parsed = document.createElement("div");
    parsed.innerHTML = iconSvg("check");
    expect(s.innerHTML).toBe(parsed.innerHTML);
  });

  it("takes an explicit pixel size for places with no label beside them", () => {
    const s = icon("play", 18);
    expect(s.style.width).toBe("18px");
    expect(s.style.height).toBe("18px");
  });

  it("a size of 0 is still applied (only null/undefined mean inherit)", () => {
    expect(icon("play", 0).style.width).toBe("0px");
  });
});
