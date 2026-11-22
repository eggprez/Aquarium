// src/spatial.ts: arrow keys move between tiles by where they are on screen.
//
// jsdom has no layout, so each tile is given a bounding box by hand.
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { wireSpatialNav } from "../../src/spatial";

const installed: EventListener[] = [];

beforeEach(() => {
  const real = document.addEventListener.bind(document);
  vi.spyOn(document, "addEventListener").mockImplementation((type: string, cb: any, opts?: any) => {
    if (type === "keydown") installed.push(cb);
    real(type, cb, opts);
  });
});

afterEach(() => {
  vi.restoreAllMocks();
  for (const cb of installed.splice(0)) document.removeEventListener("keydown", cb);
});

/** A focusable tile at (x, y) of size w x h. */
function tile(name: string, x: number, y: number, w = 100, h = 150, cls = "card", parent: HTMLElement = document.body): HTMLElement {
  const t = document.createElement("div");
  t.className = cls;
  t.tabIndex = 0;
  t.dataset.name = name;
  t.getBoundingClientRect = () =>
    ({ left: x, top: y, right: x + w, bottom: y + h, width: w, height: h, x, y, toJSON() {} }) as DOMRect;
  parent.append(t);
  return t;
}

function press(key: string, init: KeyboardEventInit = {}): KeyboardEvent {
  const ev = new KeyboardEvent("keydown", { key, bubbles: true, cancelable: true, ...init });
  (document.activeElement ?? document.body).dispatchEvent(ev);
  return ev;
}

const focused = (): string | undefined => (document.activeElement as HTMLElement | null)?.dataset?.name;

/** Two shelves: a, b, c on top; d, e below (shorter row). */
function shelves(): Record<string, HTMLElement> {
  return {
    a: tile("a", 0, 0),
    b: tile("b", 120, 0),
    c: tile("c", 240, 0),
    d: tile("d", 0, 200),
    e: tile("e", 120, 200),
  };
}

describe("wireSpatialNav", () => {
  it("Right and Left move along the row, and the key is consumed", () => {
    const t = shelves();
    wireSpatialNav(() => false);
    t.a.focus();
    expect(press("ArrowRight").defaultPrevented).toBe(true);
    expect(focused()).toBe("b");
    press("ArrowRight");
    expect(focused()).toBe("c");
    press("ArrowLeft");
    expect(focused()).toBe("b");
  });

  it("Down and Up move to the tile in the same column", () => {
    const t = shelves();
    wireSpatialNav(() => false);
    t.b.focus();
    press("ArrowDown");
    expect(focused()).toBe("e");
    press("ArrowUp");
    expect(focused()).toBe("b");
  });

  it("sideways never leaves the row: Right at the end of a shelf does nothing and lets the key through", () => {
    const t = shelves();
    // A tile in another section that is to the right and only diagonally near.
    tile("far", 400, 400);
    wireSpatialNav(() => false);
    t.c.focus();
    expect(press("ArrowRight").defaultPrevented).toBe(false);
    expect(focused()).toBe("c");
  });

  it("Down past the end of a short row falls back to the nearest tile diagonally", () => {
    const t = shelves();
    wireSpatialNav(() => false);
    t.c.focus();
    expect(press("ArrowDown").defaultPrevented).toBe(true);
    expect(focused()).toBe("e");
  });

  it("a tile in the same column wins over a nearer one on the diagonal", () => {
    const from = tile("from", 0, 0);
    tile("diag", 105, 160); // just below and to the right; not overlapping the column
    tile("below", 0, 600); // far below but straight down
    wireSpatialNav(() => false);
    from.focus();
    press("ArrowDown");
    expect(focused()).toBe("below");
  });

  it("among aligned tiles, sideways drift is penalised: straight ahead beats a closer but offset one", () => {
    const from = tile("from", 0, 0, 100, 100);
    tile("offset", 0, 120, 100, 100);
    tile("straight", 0, 140, 100, 100);
    // Shift `offset` sideways while keeping it in the column.
    const off = document.querySelector<HTMLElement>('[data-name="offset"]')!;
    off.getBoundingClientRect = () =>
      ({ left: 60, top: 110, right: 160, bottom: 210, width: 100, height: 100 }) as DOMRect;
    wireSpatialNav(() => false);
    from.focus();
    press("ArrowDown");
    expect(focused()).toBe("straight");
  });

  it("of two diagonal candidates, the nearer one wins", () => {
    const from = tile("from", 0, 0, 100, 100);
    tile("near", 200, 300, 100, 100);
    tile("farther", 400, 600, 100, 100);
    wireSpatialNav(() => false);
    from.focus();
    press("ArrowDown");
    expect(focused()).toBe("near");
  });

  it("skips hidden (zero-sized) tiles", () => {
    const t = shelves();
    t.b.getBoundingClientRect = () => ({ left: 0, top: 0, right: 0, bottom: 0, width: 0, height: 0 }) as DOMRect;
    wireSpatialNav(() => false);
    t.a.focus();
    press("ArrowRight");
    expect(focused()).toBe("c");
  });

  it("does nothing from a focused tile that is itself hidden", () => {
    const t = shelves();
    t.a.getBoundingClientRect = () => ({ left: 0, top: 0, right: 0, bottom: 0, width: 0, height: 0 }) as DOMRect;
    wireSpatialNav(() => false);
    t.a.focus();
    expect(press("ArrowRight").defaultPrevented).toBe(false);
    expect(focused()).toBe("a");
  });

  it("focuses without the browser's own scroll jump and scrolls the tile into view by the least amount", () => {
    const t = shelves();
    const focus = vi.spyOn(t.b, "focus");
    const into = vi.spyOn(t.b, "scrollIntoView");
    wireSpatialNav(() => false);
    t.a.focus();
    press("ArrowRight");
    expect(focus).toHaveBeenCalledWith({ preventScroll: true });
    expect(into).toHaveBeenCalledWith({ block: "nearest", inline: "nearest", behavior: "smooth" });
  });

  it.each([".person-card", ".ep-row", ".channel-row", ".guide-ch", ".guide-prog"])("treats %s as a tile", (sel) => {
    const a = tile("a", 0, 0, 100, 100, sel.slice(1));
    tile("b", 120, 0, 100, 100, sel.slice(1));
    wireSpatialNav(() => false);
    a.focus();
    press("ArrowRight");
    expect(focused()).toBe("b");
  });

  it.each([
    ["Shift", { shiftKey: true }],
    ["Ctrl", { ctrlKey: true }],
    ["Alt", { altKey: true }],
    ["Meta", { metaKey: true }],
  ])("leaves %s+arrow alone", (_m, init) => {
    const t = shelves();
    wireSpatialNav(() => false);
    t.a.focus();
    expect(press("ArrowRight", init).defaultPrevented).toBe(false);
    expect(focused()).toBe("a");
  });

  it("ignores keys that are not arrows", () => {
    const t = shelves();
    wireSpatialNav(() => false);
    t.a.focus();
    expect(press("Enter").defaultPrevented).toBe(false);
    expect(focused()).toBe("a");
  });

  it("leaves the arrows to playback and open menus while isBusy says so", () => {
    const t = shelves();
    let busy = true;
    wireSpatialNav(() => busy);
    t.a.focus();
    press("ArrowRight");
    expect(focused()).toBe("a");
    busy = false;
    press("ArrowRight");
    expect(focused()).toBe("b");
  });

  it("keeps the arrows' usual meaning when focus is not on a tile", () => {
    shelves();
    const input = document.createElement("input");
    document.body.append(input);
    wireSpatialNav(() => false);
    input.focus();
    expect(press("ArrowRight").defaultPrevented).toBe(false);
    expect(document.activeElement).toBe(input);
  });

  it("does nothing with nothing focused", () => {
    shelves();
    wireSpatialNav(() => false);
    (document.activeElement as HTMLElement | null)?.blur();
    expect(press("ArrowRight").defaultPrevented).toBe(false);
  });

  it("leaves a grid with its own keyboard model alone (regression: e9a1bc0 data-own-arrows for the TV guide)", () => {
    const grid = document.createElement("div");
    grid.setAttribute("data-own-arrows", "");
    document.body.append(grid);
    const a = tile("a", 0, 0, 100, 100, "guide-prog", grid);
    tile("b", 120, 0, 100, 100, "guide-prog", grid);
    wireSpatialNav(() => false);
    a.focus();
    expect(press("ArrowRight").defaultPrevented).toBe(false);
    expect(focused()).toBe("a");
  });
});
