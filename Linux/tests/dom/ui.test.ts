// src/ui.ts: the DOM helpers and shared components every view builds from.
// playback.ts is replaced with spies (what a menu entry starts is playback's
// business, tested there), and so are the four server writes api.ts makes on
// a menu's behalf; everything else in api.ts is real, signed in to the mock
// bridge so image URLs resolve.
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import { signIn } from "../helpers/tauri";

vi.mock("../../src/playback", () => ({
  playItem: vi.fn(async () => {}),
  startDownload: vi.fn(async () => {}),
  downloadSeries: vi.fn(async () => ({ queued: 0, skipped: 0, seasons: 0, cancelled: false })),
  queueNext: vi.fn(async () => 1),
  queueLater: vi.fn(async () => 1),
}));

vi.mock("../../src/blurhash", () => ({
  blurhashUrl: (hash: string | null | undefined) => (hash ? `data:image/png;base64,${hash}` : null),
}));

vi.mock("../../src/api", async (importOriginal) => {
  const real: any = await importOriginal();
  return {
    ...real,
    addToNextUp: vi.fn(async () => null),
    removeFromNextUp: vi.fn(async () => {}),
    markPlayed: vi.fn(async () => {}),
    setFavorite: vi.fn(async () => {}),
    deleteItem: vi.fn(async () => {}),
    getItem: vi.fn(async () => null),
  };
});

// Seerr's part in Delete from Server is decided in seerr.ts and tested there;
// here it says whatever a test tells it to.
vi.mock("../../src/seerr", async (importOriginal) => {
  const real: any = await importOriginal();
  return {
    ...real,
    mightRemove: vi.fn(() => false),
    removal: vi.fn(async () => null),
    remove: vi.fn(async () => {}),
  };
});

import * as ui from "../../src/ui";
import * as playback from "../../src/playback";
import * as api from "../../src/api";
import * as seerrModule from "../../src/seerr";

const pb = vi.mocked(playback);
const mapi = vi.mocked(api);
const mseerr = vi.mocked(seerrModule);

const settle = async (turns = 20): Promise<void> => {
  for (let i = 0; i < turns; i++) await Promise.resolve();
};

function toasts(): string[] {
  return [...document.querySelectorAll("#toasts > *")].map((t) => t.textContent ?? "");
}

function keydown(target: EventTarget, key: string, init: KeyboardEventInit = {}): KeyboardEvent {
  const ev = new KeyboardEvent("keydown", { key, bubbles: true, cancelable: true, ...init });
  target.dispatchEvent(ev);
  return ev;
}

function menuButtons(): HTMLButtonElement[] {
  return [...document.querySelectorAll<HTMLButtonElement>(".menu button")];
}

function menuButton(label: string): HTMLButtonElement {
  const b = menuButtons().find((x) => x.textContent?.trim() === label);
  if (!b) throw new Error(`no menu entry "${label}" in ${menuButtons().map((x) => x.textContent).join(" | ")}`);
  return b;
}

function rect(r: Partial<DOMRect>): DOMRect {
  const top = r.top ?? 0;
  const left = r.left ?? 0;
  const width = r.width ?? 0;
  const height = r.height ?? 0;
  return {
    top,
    left,
    width,
    height,
    right: r.right ?? left + width,
    bottom: r.bottom ?? top + height,
    x: left,
    y: top,
    toJSON() {},
  } as DOMRect;
}

beforeAll(async () => {
  await signIn();
});

beforeEach(async () => {
  vi.clearAllMocks();
  // signIn's config is reset with the bridge before every test; sign in again.
  await signIn();
  document.body.innerHTML = '<div id="toasts"></div>';
  Object.defineProperty(window, "innerWidth", { configurable: true, value: 1200 });
  Object.defineProperty(window, "innerHeight", { configurable: true, value: 800 });
});

afterEach(() => {
  ui.closeMenus();
  // A dialog a test left open keeps its capture-phase key listener; Escape
  // dismisses every one of them.
  keydown(document, "Escape");
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
});

describe("el and clear", () => {
  it("builds an element with classes, attributes, html, listeners and children", () => {
    const onClick = vi.fn();
    const node = ui.el("div", { class: "a b", id: "x", "data-k": 3, skipped: null, gone: undefined, onClick }, [
      "text",
      null,
      undefined,
      ui.el("span", {}, ["child"]),
    ]);
    expect(node.className).toBe("a b");
    expect(node.id).toBe("x");
    expect(node.getAttribute("data-k")).toBe("3");
    expect(node.hasAttribute("skipped")).toBe(false);
    expect(node.hasAttribute("gone")).toBe(false);
    expect(node.textContent).toBe("textchild");
    node.click();
    expect(onClick).toHaveBeenCalledTimes(1);
    // An on* attribute that is not a function is just an attribute.
    expect(ui.el("div", { onclick: "x()" }).getAttribute("onclick")).toBe("x()");
    expect(ui.el("p", { html: "<b>bold</b>" }).querySelector("b")!.textContent).toBe("bold");
  });

  it("clear empties a node", () => {
    const n = ui.el("div", {}, ["a", ui.el("span")]);
    ui.clear(n);
    expect(n.childNodes).toHaveLength(0);
  });
});

describe("asButton", () => {
  it("makes an element a keyboard button: Enter and Space run it, other keys and inner targets do not", () => {
    const run = vi.fn();
    const inner = ui.el("button");
    const card = ui.el("div", { ...ui.asButton(run) }, [inner]);
    document.body.append(card);
    expect(card.getAttribute("role")).toBe("button");
    expect(card.getAttribute("tabindex")).toBe("0");
    expect(keydown(card, "Enter").defaultPrevented).toBe(true);
    expect(keydown(card, " ").defaultPrevented).toBe(true);
    expect(run).toHaveBeenCalledTimes(2);
    keydown(card, "a");
    keydown(inner, "Enter");
    expect(run).toHaveBeenCalledTimes(2);
  });
});

describe("placeholders", () => {
  it("spinner, letter tiles and icon tiles", () => {
    expect(ui.spinner().className).toBe("spinner");
    expect(ui.noart("  heat").textContent).toBe("H");
    expect(ui.noart("").textContent).toBe("?");
    expect(ui.noart(undefined as any).textContent).toBe("?");
    const tile = ui.noartIcon("play", 40);
    expect(tile.className).toBe("noart");
    expect(tile.querySelector<HTMLElement>(".ico")!.style.width).toBe("40px");
  });
});

describe("art", () => {
  it("draws the placeholder when there is no source", () => {
    const n = ui.art(null, "Heat") as HTMLElement;
    expect(n.className).toBe("noart");
    expect(n.textContent).toBe("H");
    const custom = ui.art(undefined, () => ui.el("i", { class: "mine" })) as HTMLElement;
    expect(custom.className).toBe("mine");
  });

  it("tries the fallback source when the first is missing", () => {
    const img = ui.art(null, "x", { fallbackSrc: "http://jf.test/b.jpg" }) as HTMLImageElement;
    expect(img.tagName).toBe("IMG");
    expect(img.getAttribute("src")).toBe("http://jf.test/b.jpg");
  });

  it("is lazy by default, eager on request, and decodes off the main thread", () => {
    const lazy = ui.art("http://jf.test/a.jpg", "x") as HTMLImageElement;
    expect(lazy.getAttribute("loading")).toBe("lazy");
    expect(lazy.getAttribute("decoding")).toBe("async");
    expect(lazy.getAttribute("alt")).toBe("");
    const eager = ui.art("http://jf.test/a.jpg", "x", { lazy: false }) as HTMLImageElement;
    expect(eager.hasAttribute("loading")).toBe(false);
  });

  it("paints the BlurHash under the image while it loads", () => {
    const img = ui.art("http://jf.test/a.jpg", "x", { hash: "LEHV6nWB2yk8" }) as HTMLImageElement;
    expect(img.classList.contains("has-ph")).toBe(true);
    expect(img.style.backgroundImage).toContain("data:image/png;base64,LEHV6nWB2yk8");
    const plain = ui.art("http://jf.test/a.jpg", "x") as HTMLImageElement;
    expect(plain.classList.contains("has-ph")).toBe(false);
    expect(plain.style.backgroundImage).toBe("");
  });

  it("fades in once loaded", () => {
    const img = ui.art("http://jf.test/a.jpg", "x") as HTMLImageElement;
    expect(img.classList.contains("loaded")).toBe(false);
    img.dispatchEvent(new Event("load"));
    expect(img.classList.contains("loaded")).toBe(true);
  });

  it("is loaded at once when the image was already decoded from cache", () => {
    const proto = HTMLImageElement.prototype;
    const complete = Object.getOwnPropertyDescriptor(proto, "complete")!;
    const natural = Object.getOwnPropertyDescriptor(proto, "naturalWidth")!;
    Object.defineProperty(proto, "complete", { configurable: true, get: () => true });
    Object.defineProperty(proto, "naturalWidth", { configurable: true, get: () => 300 });
    try {
      const img = ui.art("http://jf.test/a.jpg", "x") as HTMLImageElement;
      expect(img.classList.contains("loaded")).toBe(true);
    } finally {
      Object.defineProperty(proto, "complete", complete);
      Object.defineProperty(proto, "naturalWidth", natural);
    }
  });

  it("replaces a dead image with the placeholder, or with the second picture first", () => {
    const host = ui.el("div");
    const img = ui.art("http://jf.test/dead.jpg", "Heat") as HTMLImageElement;
    host.append(img);
    img.dispatchEvent(new Event("error"));
    expect(host.firstElementChild!.className).toBe("noart");

    const host2 = ui.el("div");
    const img2 = ui.art("http://jf.test/season.jpg", "Heat", { fallbackSrc: "http://jf.test/series.jpg", hash: "LEHV6nWB2yk8" }) as HTMLImageElement;
    host2.append(img2);
    img2.dispatchEvent(new Event("error"));
    const second = host2.firstElementChild as HTMLImageElement;
    expect(second.getAttribute("src")).toBe("http://jf.test/series.jpg");
    // The hash belonged to the first picture, so the second goes without.
    expect(second.classList.contains("has-ph")).toBe(false);
    second.dispatchEvent(new Event("error"));
    expect(host2.firstElementChild!.className).toBe("noart");
  });
});

/** `new Image()` stand-in that records what it was asked to load. */
function stubImage(): HTMLImageElement[] {
  const made: HTMLImageElement[] = [];
  vi.stubGlobal(
    "Image",
    function FakeImage() {
      const img = document.createElement("img");
      made.push(img);
      return img;
    } as any
  );
  return made;
}

describe("backdropLayer", () => {
  it("is nothing without a URL", () => {
    expect(ui.backdropLayer(null, "hero-bg")).toBeNull();
    expect(ui.backdropLayer("", "hero-bg")).toBeNull();
  });

  it("stays transparent until the picture has decoded, then shows it", () => {
    const made = stubImage();
    const layer = ui.backdropLayer("http://jf.test/bd.jpg", "hero-bg")!;
    expect(layer.className).toBe("hero-bg");
    expect(layer.style.backgroundImage).toBe("");
    expect(made[0]!.getAttribute("src")).toBe("http://jf.test/bd.jpg");
    made[0]!.dispatchEvent(new Event("load"));
    expect(layer.style.backgroundImage).toContain("http://jf.test/bd.jpg");
    expect(layer.classList.contains("loaded")).toBe(true);
  });
});

describe("heroTitle", () => {
  it("is plain text when the item has no logo", () => {
    const h = ui.heroTitle({ Id: "m1" }, "Heat", "hero-title");
    expect(h.className).toBe("hero-title");
    expect(h.querySelector(".title-text")!.textContent).toBe("Heat");
    expect(h.querySelector("img")).toBeNull();
  });

  it("switches to the logo only once it has decoded, and drops a broken one", () => {
    const h = ui.heroTitle({ Id: "m1", ImageTags: { Logo: "t1" } }, "Heat", "hero-title");
    const img = h.querySelector<HTMLImageElement>("img.title-logo")!;
    expect(img.getAttribute("src")).toContain("/Items/m1/Images/Logo");
    expect(img.getAttribute("alt")).toBe("Heat");
    expect(h.firstElementChild).toBe(img);
    expect(h.classList.contains("has-logo")).toBe(false);
    // A load that decoded nothing is not a logo.
    img.dispatchEvent(new Event("load"));
    expect(h.classList.contains("has-logo")).toBe(false);

    const h2 = ui.heroTitle({ Id: "m1", ImageTags: { Logo: "t1" } }, "Heat", "hero-title");
    const img2 = h2.querySelector<HTMLImageElement>("img")!;
    Object.defineProperty(img2, "naturalWidth", { value: 640 });
    img2.dispatchEvent(new Event("load"));
    expect(h2.classList.contains("has-logo")).toBe(true);

    const h3 = ui.heroTitle({ Id: "m1", ImageTags: { Logo: "t1" } }, "Heat", "hero-title");
    h3.querySelector("img")!.dispatchEvent(new Event("error"));
    expect(h3.querySelector("img")).toBeNull();
    expect(h3.querySelector(".title-text")!.textContent).toBe("Heat");
  });

  it("shows an already-decoded logo straight away", () => {
    const proto = HTMLImageElement.prototype;
    const complete = Object.getOwnPropertyDescriptor(proto, "complete")!;
    const natural = Object.getOwnPropertyDescriptor(proto, "naturalWidth")!;
    Object.defineProperty(proto, "complete", { configurable: true, get: () => true });
    Object.defineProperty(proto, "naturalWidth", { configurable: true, get: () => 640 });
    try {
      const h = ui.heroTitle({ Id: "e1", ParentLogoItemId: "s1", ParentLogoImageTag: "t" }, "Archer", "c");
      expect(h.classList.contains("has-logo")).toBe(true);
      expect(h.querySelector("img")!.getAttribute("src")).toContain("/Items/s1/Images/Logo");
    } finally {
      Object.defineProperty(proto, "complete", complete);
      Object.defineProperty(proto, "naturalWidth", natural);
    }
  });
});

describe("ambientTint", () => {
  function fakeCanvas(pixels: number[][] | (() => never) | null): void {
    vi.spyOn(HTMLCanvasElement.prototype, "getContext").mockImplementation((() => {
      if (pixels === null) return null;
      return {
        drawImage: () => {},
        getImageData: () => {
          if (typeof pixels === "function") pixels();
          const data = new Uint8ClampedArray(16 * 16 * 4);
          for (let i = 0; i < 256; i++) {
            const p = (pixels as number[][])[i % (pixels as number[][]).length]!;
            data.set([p[0]!, p[1]!, p[2]!, 255], i * 4);
          }
          return { data };
        },
      };
    }) as any);
  }

  async function tint(target: HTMLElement, made: HTMLImageElement[], outcome: "load" | "error"): Promise<void> {
    ui.ambientTint(target, "http://jf.test/bd.jpg");
    expect(made.at(-1)!.crossOrigin).toBe("anonymous");
    made.at(-1)!.dispatchEvent(new Event(outcome));
    await settle();
  }

  it("does nothing without a URL", () => {
    const made = stubImage();
    ui.ambientTint(document.body, null);
    expect(made).toHaveLength(0);
  });

  it("lights the target with the artwork's saturated colour, lifted to a steady brightness", async () => {
    const made = stubImage();
    // Black bars and blown highlights say nothing about the picture.
    fakeCanvas([[200, 40, 40], [0, 0, 0], [250, 250, 250]]);
    const target = ui.el("div");
    document.body.append(target);
    await tint(target, made, "load");
    expect(target.classList.contains("has-tint")).toBe(true);
    // Only the red pixel counts; pushed from grey and lifted so its brightest
    // channel is 195.
    expect(target.style.getPropertyValue("--tint")).toBe("rgb(195, 13, 13)");
    expect(target.style.getPropertyValue("--tint-soft")).toBe("rgba(195, 13, 13, 0.5)");
    expect(target.style.getPropertyValue("--tint-faint")).toBe("rgba(195, 13, 13, 0.18)");
  });

  it("goes without when nothing in the picture counts", async () => {
    const made = stubImage();
    fakeCanvas([[0, 0, 0], [255, 255, 255]]);
    const target = ui.el("div");
    document.body.append(target);
    await tint(target, made, "load");
    expect(target.classList.contains("has-tint")).toBe(false);
  });

  it("goes without when the image fails, the canvas is tainted or there is no 2D context", async () => {
    const target = ui.el("div");
    document.body.append(target);
    let made = stubImage();
    await tint(target, made, "error");
    expect(target.classList.contains("has-tint")).toBe(false);

    made = stubImage();
    fakeCanvas(() => {
      throw new Error("tainted");
    });
    await tint(target, made, "load");
    expect(target.classList.contains("has-tint")).toBe(false);

    vi.restoreAllMocks();
    made = stubImage();
    fakeCanvas(null);
    await tint(target, made, "load");
    expect(target.classList.contains("has-tint")).toBe(false);
  });

  it("leaves a target that left the page alone", async () => {
    const made = stubImage();
    fakeCanvas([[200, 40, 40]]);
    const target = ui.el("div");
    await tint(target, made, "load");
    expect(target.classList.contains("has-tint")).toBe(false);
  });
});

describe("skeletons", () => {
  it("builds placeholder cards, rows, grids, list rows and a detail hero from the real classes", () => {
    const cards = ui.skeletonCards(3, { wide: true });
    expect(cards).toHaveLength(3);
    expect(cards[0]!.className).toBe("card skeleton wide");
    expect(cards[0]!.querySelector(".card-poster.sk-box")).not.toBeNull();
    expect(ui.skeletonCards(1)[0]!.className).toBe("card skeleton");

    const row = ui.skeletonRow();
    expect(row.className).toBe("card-row");
    expect(row.children).toHaveLength(6);
    expect(ui.skeletonRow(2, { wide: true }).children[0]!.classList.contains("wide")).toBe(true);

    const grid = ui.skeletonGrid();
    expect(grid.className).toBe("card-grid");
    expect(grid.children).toHaveLength(18);
    expect(ui.skeletonGrid(4).children).toHaveLength(4);

    const rows = ui.skeletonRows(2, "ep-row", "ep-thumb");
    expect(rows.children).toHaveLength(2);
    expect(rows.children[0]!.className).toBe("ep-row skeleton");
    expect(rows.querySelector(".ep-thumb.sk-box")).not.toBeNull();

    const detail = ui.skeletonDetail();
    expect(detail.className).toBe("detail-hero skeleton");
    expect(detail.querySelectorAll(".sk-btn")).toHaveLength(2);
    expect(detail.querySelectorAll(".sk-para")).toHaveLength(3);
  });
});

describe("empty and error states", () => {
  it("draws an icon, a title, an optional sentence and an optional action", () => {
    const run = vi.fn();
    const s = ui.emptyState({ title: "Nothing here", body: "Add a library.", action: { label: "Open", run } });
    expect(s.className).toBe("state");
    expect(s.querySelector(".state-icon svg")).not.toBeNull();
    expect(s.querySelector("h3")!.textContent).toBe("Nothing here");
    expect(s.querySelector("p")!.textContent).toBe("Add a library.");
    s.querySelector("button")!.click();
    expect(run).toHaveBeenCalled();

    const bare = ui.emptyState({ title: "Empty", icon: "download" });
    expect(bare.querySelector("p")).toBeNull();
    expect(bare.querySelector("button")).toBeNull();
  });

  it("errorState is the red variant with the error's message, and Try again only with a retry", () => {
    const retry = vi.fn();
    const s = ui.errorState("Didn't load", new Error("Server error 500"), retry);
    expect(s.className).toBe("state state-error");
    expect(s.querySelector("p")!.textContent).toBe("Server error 500");
    expect(s.querySelector("button")!.textContent).toBe("Try again");
    s.querySelector("button")!.click();
    expect(retry).toHaveBeenCalled();
    const noRetry = ui.errorState("Didn't load", "plain string");
    expect(noRetry.querySelector("p")!.textContent).toBe("plain string");
    expect(noRetry.querySelector("button")).toBeNull();
  });
});

describe("openDialog", () => {
  it("opens a modal with its title and body, focused on the primary action", () => {
    ui.openDialog({
      title: "Quit?",
      body: ["Some text", ui.el("p", {}, ["para"])],
      actions: [{ label: "Quit", danger: true }, { label: "Stay", primary: true }],
      wide: true,
    });
    const card = document.querySelector<HTMLElement>(".dialog-scrim .dialog")!;
    expect(card.classList.contains("wide")).toBe(true);
    expect(card.getAttribute("role")).toBe("dialog");
    expect(card.getAttribute("aria-modal")).toBe("true");
    expect(card.getAttribute("aria-label")).toBe("Quit?");
    expect(card.querySelector("h2")!.textContent).toBe("Quit?");
    expect(card.textContent).toContain("Some text");
    // Focus lands on the safe choice, so Enter never destroys anything.
    expect((document.activeElement as HTMLElement).textContent).toBe("Stay");
    expect(card.querySelector(".btn.danger")!.textContent).toBe("Quit");
  });

  it("focuses the first button when none is primary, and nothing when there are none", () => {
    ui.openDialog({ title: "A", actions: [{ label: "One" }, { label: "Two" }] });
    expect((document.activeElement as HTMLElement).textContent).toBe("One");
    document.querySelector(".dialog-scrim")!.remove();
    const close = ui.openDialog({ title: "B" });
    expect(document.querySelector(".dialog-actions")).toBeNull();
    close();
  });

  it("runs an action and closes without counting as a dismissal", () => {
    const run = vi.fn();
    const onDismiss = vi.fn();
    ui.openDialog({ title: "Q", actions: [{ label: "Go", run }, { label: "No" }], onDismiss });
    [...document.querySelectorAll<HTMLButtonElement>(".dialog button")].find((b) => b.textContent === "Go")!.click();
    expect(run).toHaveBeenCalledTimes(1);
    expect(onDismiss).not.toHaveBeenCalled();
    expect(document.querySelector(".dialog-scrim")).toBeNull();

    // An action with no run just closes.
    ui.openDialog({ title: "Q", actions: [{ label: "OK" }] });
    document.querySelector<HTMLButtonElement>(".dialog button")!.click();
    expect(document.querySelector(".dialog-scrim")).toBeNull();
  });

  it("Escape and a click on the scrim dismiss it; a click inside the card does not", () => {
    const onDismiss = vi.fn();
    ui.openDialog({ title: "Q", actions: [{ label: "OK" }], onDismiss });
    document.querySelector<HTMLElement>(".dialog")!.click();
    expect(document.querySelector(".dialog-scrim")).not.toBeNull();
    const esc = keydown(document, "Escape");
    expect(esc.defaultPrevented).toBe(true);
    expect(onDismiss).toHaveBeenCalledTimes(1);
    expect(document.querySelector(".dialog-scrim")).toBeNull();
    // A later Escape no longer reaches it.
    keydown(document, "Escape");
    expect(onDismiss).toHaveBeenCalledTimes(1);

    ui.openDialog({ title: "Q", onDismiss });
    document.querySelector<HTMLElement>(".dialog-scrim")!.click();
    expect(onDismiss).toHaveBeenCalledTimes(2);
    expect(document.querySelector(".dialog-scrim")).toBeNull();
  });

  it("keeps Tab inside the dialog, both ways, skipping disabled controls", () => {
    ui.openDialog({
      title: "Q",
      body: [ui.el("button", { disabled: "" }, ["Off"]), ui.el("input", { type: "text" })],
      actions: [{ label: "A" }, { label: "B", primary: true }],
    });
    const input = document.querySelector<HTMLInputElement>(".dialog input")!;
    const [, a, b] = [...document.querySelectorAll<HTMLButtonElement>(".dialog button")];
    b!.focus();
    expect(keydown(document, "Tab").defaultPrevented).toBe(true);
    expect(document.activeElement).toBe(input);
    expect(keydown(document, "Tab", { shiftKey: true }).defaultPrevented).toBe(true);
    expect(document.activeElement).toBe(b);
    // In the middle, Tab is left to the browser.
    a!.focus();
    expect(keydown(document, "Tab").defaultPrevented).toBe(false);
    // Any other key is not the dialog's business.
    expect(keydown(document, "x").defaultPrevented).toBe(false);
  });

  it("ignores Tab in a dialog with nothing to focus", () => {
    ui.openDialog({ title: "Q", body: ["text"] });
    expect(keydown(document, "Tab").defaultPrevented).toBe(false);
  });

  it("gives focus back to whatever opened it, and the returned close is idempotent", () => {
    const opener = ui.el("button", {}, ["open"]);
    document.body.append(opener);
    opener.focus();
    const onDismiss = vi.fn();
    const close = ui.openDialog({ title: "Q", actions: [{ label: "OK" }], onDismiss });
    expect(document.activeElement).not.toBe(opener);
    close();
    expect(document.activeElement).toBe(opener);
    expect(onDismiss).not.toHaveBeenCalled();
    close();
    expect(document.querySelector(".dialog-scrim")).toBeNull();
  });
});

describe("toast", () => {
  it("shows a message of a kind and takes it away after a few seconds", () => {
    vi.useFakeTimers();
    ui.toast("Saved", "ok");
    ui.toast("Plain");
    ui.toast("Broke", "error");
    const all = [...document.querySelectorAll<HTMLElement>("#toasts .toast")];
    expect(all.map((t) => t.className)).toEqual(["toast ok", "toast ", "toast error"]);
    expect(toasts()).toEqual(["Saved", "Plain", "Broke"]);
    vi.advanceTimersByTime(4200);
    expect(all[0]!.style.opacity).toBe("0");
    expect(toasts()).toHaveLength(3);
    vi.advanceTimersByTime(350);
    expect(toasts()).toHaveLength(0);
  });
});

describe("recent searches", () => {
  it("records committed terms newest first, without case duplicates, up to eight", () => {
    expect(ui.recentSearches()).toEqual([]);
    ui.rememberSearch("  heat ");
    ui.rememberSearch("");
    ui.rememberSearch("   ");
    ui.rememberSearch("Archer");
    ui.rememberSearch("HEAT");
    expect(ui.recentSearches()).toEqual(["HEAT", "Archer"]);
    for (let i = 0; i < 10; i++) ui.rememberSearch(`t${i}`);
    expect(ui.recentSearches()).toHaveLength(8);
    expect(ui.recentSearches()[0]).toBe("t9");
    ui.clearRecentSearches();
    expect(ui.recentSearches()).toEqual([]);
  });

  it("reads damaged storage as an empty or filtered list", () => {
    localStorage.setItem("aquarium.recent-searches", "{not json");
    expect(ui.recentSearches()).toEqual([]);
    localStorage.setItem("aquarium.recent-searches", '{"a":1}');
    expect(ui.recentSearches()).toEqual([]);
    localStorage.setItem("aquarium.recent-searches", '["ok", 3, null, "fine"]');
    expect(ui.recentSearches()).toEqual(["ok", "fine"]);
  });

  it("carries on when storage refuses", () => {
    const set = vi.spyOn(Storage.prototype, "setItem").mockImplementation(() => {
      throw new Error("quota");
    });
    expect(() => ui.rememberSearch("x")).not.toThrow();
    set.mockRestore();
    const rm = vi.spyOn(Storage.prototype, "removeItem").mockImplementation(() => {
      throw new Error("denied");
    });
    expect(() => ui.clearRecentSearches()).not.toThrow();
    rm.mockRestore();
  });
});

describe("openMenu (anchored)", () => {
  function anchored(): { wrap: HTMLElement; btn: HTMLButtonElement } {
    const btn = ui.el("button", {}, ["⋯"]) as HTMLButtonElement;
    const wrap = ui.el("div", { class: "menu-wrap" }, [btn]);
    document.body.append(wrap);
    btn.focus();
    return { wrap, btn };
  }

  it("hangs the menu inside the anchor's wrapper, focused on the first entry", () => {
    const { wrap } = anchored();
    ui.openMenu(wrap.querySelector("button")!, (m) => m.append(ui.el("button", {}, ["One"]), ui.el("button", {}, ["Two"])));
    const menu = wrap.querySelector<HTMLElement>(".menu")!;
    expect(menu.getAttribute("role")).toBe("menu");
    expect(menu.classList.contains("menu-fixed")).toBe(false);
    expect(document.activeElement!.textContent).toBe("One");
  });

  it("flips left and up when the default placement would run off the window", () => {
    const { btn } = anchored();
    const spy = vi.spyOn(HTMLElement.prototype, "getBoundingClientRect").mockImplementation(function (this: HTMLElement) {
      return this.classList.contains("menu") ? rect({ top: 700, left: 1100, width: 200, height: 200 }) : rect({});
    });
    ui.openMenu(btn, (m) => m.append(ui.el("button", {}, ["One"])));
    const menu = document.querySelector<HTMLElement>(".menu")!;
    expect(menu.style.left).toBe("auto");
    expect(menu.style.right).toBe("0px");
    expect(menu.style.top).toBe("auto");
    expect(menu.style.bottom).toBe("calc(100% + 6px)");
    spy.mockRestore();
  });

  it("pins below with a capped height when flipping up would run off the top", () => {
    const { btn } = anchored();
    let calls = 0;
    const spy = vi.spyOn(HTMLElement.prototype, "getBoundingClientRect").mockImplementation(function (this: HTMLElement) {
      if (!this.classList.contains("menu")) return rect({});
      calls++;
      return calls === 1 ? rect({ top: 300, left: 10, width: 100, height: 600 }) : rect({ top: -100, left: 10, width: 100, height: 600 });
    });
    ui.openMenu(btn, (m) => m.append(ui.el("button", {}, ["One"])));
    const menu = document.querySelector<HTMLElement>(".menu")!;
    expect(menu.style.bottom).toBe("auto");
    expect(menu.style.top).toBe("calc(100% + 6px)");
    expect(menu.style.maxHeight).toBe("492px");
    spy.mockRestore();
  });

  it("closes on a click outside, once the opening click has passed", async () => {
    const { btn } = anchored();
    ui.openMenu(btn, (m) => m.append(ui.el("button", {}, ["One"])));
    // The click that opened it is still in flight: nothing is listening yet.
    document.body.click();
    expect(document.querySelector(".menu")).not.toBeNull();
    await new Promise((r) => setTimeout(r, 0));
    document.querySelector<HTMLElement>(".menu")!.click();
    expect(document.querySelector(".menu")).not.toBeNull();
    document.body.click();
    expect(document.querySelector(".menu")).toBeNull();
  });

  it("keeps clicks and right-clicks on its entries from reaching the card underneath", () => {
    const { btn, wrap } = anchored();
    const card = vi.fn();
    wrap.addEventListener("click", card);
    wrap.addEventListener("contextmenu", card);
    ui.openMenu(btn, (m) => m.append(ui.el("button", {}, ["One"])));
    const entry = document.querySelector<HTMLElement>(".menu button")!;
    entry.click();
    entry.dispatchEvent(new MouseEvent("contextmenu", { bubbles: true }));
    expect(card).not.toHaveBeenCalled();
  });

  it("walks its entries with the arrows, Home and End, and Escape closes it back to the opener", () => {
    const { btn } = anchored();
    ui.openMenu(btn, (m) => m.append(...["A", "B", "C"].map((t) => ui.el("button", {}, [t]))));
    const menu = document.querySelector<HTMLElement>(".menu")!;
    const at = () => document.activeElement!.textContent;
    expect(at()).toBe("A");
    keydown(menu, "ArrowDown");
    expect(at()).toBe("B");
    keydown(menu, "ArrowUp");
    keydown(menu, "ArrowUp");
    expect(at()).toBe("C");
    keydown(menu, "Home");
    expect(at()).toBe("A");
    keydown(menu, "End");
    expect(at()).toBe("C");
    keydown(menu, "x");
    expect(at()).toBe("C");
    const esc = keydown(menu, "Escape");
    expect(esc.defaultPrevented).toBe(true);
    expect(document.querySelector(".menu")).toBeNull();
    expect(document.activeElement).toBe(btn);
  });

  it("Tab dismisses it rather than leaving it hanging", () => {
    const { btn } = anchored();
    ui.openMenu(btn, (m) => m.append(ui.el("button", {}, ["A"])));
    keydown(document.querySelector(".menu")!, "Tab");
    expect(document.querySelector(".menu")).toBeNull();
  });

  it("does nothing with keys when it has no entries", () => {
    const { btn } = anchored();
    ui.openMenu(btn, (m) => m.append(ui.el("div", {}, ["note"])));
    keydown(document.querySelector(".menu")!, "Escape");
    expect(document.querySelector(".menu")).not.toBeNull();
  });

  it("opening another menu closes the first, and closeMenus closes everything", () => {
    const { btn } = anchored();
    ui.openMenu(btn, (m) => m.append(ui.el("button", {}, ["First"])));
    ui.openMenu({ x: 5, y: 5 }, (m) => m.append(ui.el("button", {}, ["Second"])));
    expect(document.querySelectorAll(".menu")).toHaveLength(1);
    expect(document.querySelector(".menu")!.textContent).toBe("Second");
    // A stray .menu that nothing registered is swept up too.
    document.body.append(ui.el("div", { class: "menu" }));
    ui.closeMenus();
    expect(document.querySelectorAll(".menu")).toHaveLength(0);
  });

  it("does not pull focus back when it was closed by a click elsewhere", async () => {
    const { btn } = anchored();
    const other = ui.el("button", {}, ["other"]);
    document.body.append(other);
    ui.openMenu(btn, (m) => m.append(ui.el("button", {}, ["A"])));
    await new Promise((r) => setTimeout(r, 0));
    other.focus();
    other.click();
    expect(document.querySelector(".menu")).toBeNull();
    expect(document.activeElement).toBe(other);
  });
});

describe("openMenu (floating)", () => {
  it("floats at a cursor position and closes on scroll or resize", () => {
    ui.openMenu({ x: 40, y: 50 }, (m) => m.append(ui.el("button", {}, ["A"])));
    const menu = document.querySelector<HTMLElement>(".menu")!;
    expect(menu.classList.contains("menu-fixed")).toBe(true);
    expect(menu.parentElement).toBe(document.body);
    expect(menu.style.top).toBe("56px");
    expect(menu.style.left).toBe("40px");
    window.dispatchEvent(new Event("scroll"));
    expect(document.querySelector(".menu")).toBeNull();

    ui.openMenu({ x: 40, y: 50 }, (m) => m.append(ui.el("button", {}, ["A"])));
    window.dispatchEvent(new Event("resize"));
    expect(document.querySelector(".menu")).toBeNull();
  });

  it("floats from an element when asked to, under its box", () => {
    const anchor = ui.el("button");
    document.body.append(anchor);
    const spy = vi.spyOn(HTMLElement.prototype, "getBoundingClientRect").mockImplementation(function (this: HTMLElement) {
      return this === anchor ? rect({ top: 100, left: 30, width: 20, height: 20 }) : rect({ width: 100, height: 50 });
    });
    ui.openMenu(anchor, (m) => m.append(ui.el("button", {}, ["A"])), { fixed: true });
    const menu = document.querySelector<HTMLElement>(".menu")!;
    expect(menu.style.top).toBe("126px");
    expect(menu.style.left).toBe("30px");
    spy.mockRestore();
  });

  it("is clamped inside the window, and flipped above the anchor when there is room", () => {
    const spy = vi.spyOn(HTMLElement.prototype, "getBoundingClientRect").mockImplementation(function (this: HTMLElement) {
      return rect({ top: 700, left: 1150, width: 200, height: 300 });
    });
    ui.openMenu({ x: 1150, y: 690 }, (m) => m.append(ui.el("button", {}, ["A"])));
    const menu = document.querySelector<HTMLElement>(".menu")!;
    expect(menu.style.left).toBe(`${1200 - 8 - 200}px`);
    expect(menu.style.top).toBe(`${690 - 6 - 300}px`);
    spy.mockRestore();
  });

  it("caps its height when there is no room above either", () => {
    const spy = vi.spyOn(HTMLElement.prototype, "getBoundingClientRect").mockImplementation(function (this: HTMLElement) {
      return rect({ top: 100, left: 10, width: 100, height: 900 });
    });
    ui.openMenu({ x: 10, y: 100 }, (m) => m.append(ui.el("button", {}, ["A"])));
    const menu = document.querySelector<HTMLElement>(".menu")!;
    expect(menu.style.maxHeight).toBe(`${800 - 100 - 6 - 8}px`);
    spy.mockRestore();
  });
});

describe("fillMenu and openActionMenu", () => {
  it("lists actions with icons, indents icon-less entries only beside iconed ones, and runs a pick", async () => {
    const run = vi.fn();
    ui.openActionMenu({ x: 1, y: 1 }, "Heat", [
      { label: "Play", icon: "play", run },
      null,
      { label: "Delete", danger: true },
    ]);
    const menu = document.querySelector<HTMLElement>(".menu")!;
    expect(menu.querySelector(".menu-label")!.textContent).toBe("Heat");
    const [play, del] = menuButtons();
    expect(play!.getAttribute("role")).toBe("menuitem");
    expect(play!.querySelector(".ico")).not.toBeNull();
    expect(del!.className).toBe("danger");
    expect(del!.querySelector(".menu-gutter")).not.toBeNull();
    play!.click();
    expect(run).toHaveBeenCalled();
    expect(document.querySelector(".menu")).toBeNull();
    // An entry with no run just closes the menu.
    ui.openActionMenu({ x: 1, y: 1 }, null, [{ label: "Nothing" }]);
    expect(document.querySelector(".menu-label")).toBeNull();
    expect(document.querySelector(".menu-gutter")).toBeNull();
    menuButton("Nothing").click();
    expect(document.querySelector(".menu")).toBeNull();
  });

  it("steps into a submenu page and back again, keeping focus inside the menu", () => {
    const pick = vi.fn();
    ui.openActionMenu({ x: 1, y: 1 }, "Item", [
      { label: "Download", icon: "download", submenu: { label: "Download as", items: () => [{ label: "720p", run: pick }] } },
    ]);
    const entry = menuButton("Download");
    expect(entry.querySelectorAll(".ico")).toHaveLength(2); // the icon and the chevron
    entry.focus();
    entry.click();
    expect(document.querySelector(".menu-label")!.textContent).toBe("Download as");
    expect(document.activeElement!.textContent).toBe("Back");
    menuButton("Back").click();
    expect(document.querySelector(".menu-label")!.textContent).toBe("Item");
    menuButton("Download").click();
    menuButton("720p").click();
    expect(pick).toHaveBeenCalled();
  });

  it("re-measures a floating menu after a page change", () => {
    const spy = vi.spyOn(HTMLElement.prototype, "getBoundingClientRect");
    ui.openActionMenu({ x: 10, y: 10 }, null, [{ label: "More", submenu: { label: "Sub", items: () => [] } }]);
    const before = spy.mock.calls.length;
    menuButton("More").click();
    expect(spy.mock.calls.length).toBeGreaterThan(before);
  });

  it("fills a menu that is not floating without measuring it", () => {
    const menu = ui.el("div", { class: "menu" });
    document.body.append(menu);
    ui.fillMenu(menu, "T", [{ label: "A" }], () => {});
    expect(menu.querySelector(".menu-back")).not.toBeNull();
  });
});

describe("attachContextMenu", () => {
  it("opens the actions at the pointer on right-click, innermost target first", () => {
    const outer = ui.el("div");
    const inner = ui.el("div");
    outer.append(inner);
    document.body.append(outer);
    const outerActions = vi.fn(() => [{ label: "Outer" }]);
    ui.attachContextMenu(outer, "O", outerActions);
    ui.attachContextMenu(inner, "I", () => [{ label: "Inner" }]);
    expect(inner.classList.contains("has-ctx")).toBe(true);
    const ev = new MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 30, clientY: 40 });
    inner.dispatchEvent(ev);
    expect(ev.defaultPrevented).toBe(true);
    expect(outerActions).not.toHaveBeenCalled();
    expect(menuButtons().map((b) => b.textContent)).toEqual(["Inner"]);
    expect(document.querySelector<HTMLElement>(".menu")!.style.left).toBe("30px");
  });

  it("opens nothing when there is nothing to offer", () => {
    const t = ui.el("div");
    document.body.append(t);
    ui.attachContextMenu(t, null, () => [null]);
    t.dispatchEvent(new MouseEvent("contextmenu", { bubbles: true, cancelable: true }));
    expect(document.querySelector(".menu")).toBeNull();
  });
});

describe("downloads", () => {
  const q720 = api.DOWNLOAD_QUALITIES.find((q) => q.name === "720p")!;
  const original = api.DOWNLOAD_QUALITIES[0]!;

  it("labels a rung with its estimated size, or just its name when it cannot be estimated", () => {
    expect(ui.downloadLabel({}, q720)).toBe(q720.label);
    const hour = { RunTimeTicks: 36_000_000_000 };
    expect(ui.downloadLabel(hour, q720)).toMatch(/^720p · 4\.5 Mbps · ~\d/);
    // The original is exact, so it carries no "~".
    expect(ui.downloadLabel({ MediaSources: [{ Size: 2_000_000_000 }] }, original)).toMatch(/^Original quality · \d/);
    // A transcode bigger than the source fetches the source, and says so.
    const small = { RunTimeTicks: 36_000_000_000, MediaSources: [{ Size: 100_000_000 }] };
    expect(ui.downloadLabel(small, q720)).toMatch(/^720p · 4\.5 Mbps · \d.* \(original file\)$/);
  });

  it("offers a single download as a page of sized rungs, and starts the one picked", async () => {
    const movie = { Id: "m1", Type: "Movie", Name: "Heat", RunTimeTicks: 36_000_000_000 };
    const action = ui.downloadAction(movie);
    expect(action.label).toBe("Download");
    expect(action.submenu!.label).toBe("Download as");
    const items = action.submenu!.items();
    expect(items).toHaveLength(api.DOWNLOAD_QUALITIES.length);
    expect(items[4]!.label).toBe(ui.downloadLabel(movie, q720));
    await items[4]!.run!();
    expect(pb.startDownload).toHaveBeenCalledWith(movie, q720);
    expect(pb.downloadSeries).not.toHaveBeenCalled();
  });

  it("queues a series' episodes and reports how many", async () => {
    pb.downloadSeries.mockResolvedValueOnce({ queued: 5, skipped: 2, seasons: 2, cancelled: false } as any);
    const series = { Id: "s1", Type: "Series", Name: "Archer" };
    const action = ui.downloadAction(series);
    expect(action.label).toBe("Download series");
    expect(action.submenu!.label).toBe("Download every episode as");
    const items = action.submenu!.items();
    expect(items[4]!.label).toBe(q720.label);
    await items[4]!.run!();
    expect(pb.downloadSeries).toHaveBeenCalledWith("s1", q720);
    expect(toasts()).toEqual(["Collecting episodes…", "Queued 5 episodes from 2 seasons, skipped 2 already downloaded"]);

    pb.downloadSeries.mockResolvedValueOnce({ queued: 1, skipped: 0, seasons: 1, cancelled: false } as any);
    await items[4]!.run!();
    expect(toasts().at(-1)).toBe("Queued 1 episode from 1 season");
  });

  it("queues a season's episodes instead of asking the server for the season as a video (regression: 4fe2d31 season downloads)", async () => {
    pb.downloadSeries.mockResolvedValueOnce({ queued: 3, skipped: 0, seasons: 1, cancelled: false } as any);
    const season = { Id: "season-1", Type: "Season", SeriesId: "s1", Name: "Season 1" };
    const action = ui.downloadAction(season);
    expect(action.label).toBe("Download season");
    await action.submenu!.items()[1]!.run!();
    expect(pb.startDownload).not.toHaveBeenCalled();
    expect(pb.downloadSeries).toHaveBeenCalledWith("s1", api.DOWNLOAD_QUALITIES[1], [season]);
    expect(toasts().at(-1)).toBe("Queued 3 episodes");
    // A season with no series to belong to is just an item.
    expect(ui.downloadAction({ Id: "x", Type: "Season" }).label).toBe("Download");
  });

  it("says when everything was already there, stays quiet when cancelled, and reports a failure", async () => {
    const series = { Id: "s1", Type: "Series" };
    const run = ui.downloadAction(series).submenu!.items()[0]!.run!;
    pb.downloadSeries.mockResolvedValueOnce({ queued: 0, skipped: 4, seasons: 1, cancelled: false } as any);
    await run();
    expect(toasts().at(-1)).toBe("Every episode is already downloaded or queued");
    expect(document.querySelector("#toasts > :last-child")!.className).toBe("toast ");

    document.getElementById("toasts")!.textContent = "";
    pb.downloadSeries.mockResolvedValueOnce({ queued: 0, skipped: 0, seasons: 0, cancelled: true } as any);
    await run();
    expect(toasts()).toEqual(["Collecting episodes…"]);

    pb.downloadSeries.mockRejectedValueOnce(new Error("disk full"));
    await run();
    expect(toasts().at(-1)).toBe("Download failed: disk full");
    pb.startDownload.mockRejectedValueOnce("plain");
    await ui.downloadAction({ Id: "m", Type: "Movie" }).submenu!.items()[0]!.run!();
    expect(toasts().at(-1)).toBe("Download failed: plain");
  });
});

describe("queueActions", () => {
  it("offers nothing for what cannot be queued", () => {
    expect(ui.queueActions({ Type: "Series" })).toEqual([]);
    expect(ui.queueActions({ Type: "Season" })).toEqual([]);
    expect(ui.queueActions({ Type: "Audio" })).toEqual([]);
  });

  it("puts a title next or later on Up Next and says so", async () => {
    const movie = { Id: "m1", Type: "Movie" };
    const [next, later] = ui.queueActions(movie);
    expect(next!.label).toBe("Play Next");
    expect(later!.label).toBe("Play Later");
    await next!.run!();
    expect(pb.queueNext).toHaveBeenCalledWith([movie]);
    expect(toasts().at(-1)).toBe("Playing next");
    await later!.run!();
    expect(pb.queueLater).toHaveBeenCalledWith([movie]);
    expect(toasts().at(-1)).toBe("Added to Up Next");
  });

  it("speaks of a season as a season", async () => {
    const season = { Id: "se", Type: "Season", SeriesId: "s1" };
    const [next, later] = ui.queueActions(season);
    expect(next!.label).toBe("Play Season Next");
    expect(later!.label).toBe("Play Season Later");
    await next!.run!();
    expect(toasts().at(-1)).toBe("Playing the season next");
    await later!.run!();
    expect(toasts().at(-1)).toBe("Added the season to Up Next");
  });

  it("reports an empty result and a failure", async () => {
    pb.queueNext.mockResolvedValueOnce(0);
    await ui.queueActions({ Type: "Episode" })[0]!.run!();
    expect(toasts().at(-1)).toBe("Nothing to queue here yet");
    pb.queueLater.mockRejectedValueOnce(new Error("nope"));
    await ui.queueActions({ Type: "Video" })[1]!.run!();
    expect(toasts().at(-1)).toBe("nope");
    pb.queueLater.mockRejectedValueOnce("raw");
    await ui.queueActions({ Type: "MusicVideo" })[1]!.run!();
    expect(toasts().at(-1)).toBe("raw");
  });
});

describe("askAddToNextUp", () => {
  function dialogButton(label: string): HTMLButtonElement {
    return [...document.querySelectorAll<HTMLButtonElement>(".dialog button")].find((b) => b.textContent === label)!;
  }

  it("asks nothing for an item that is not television", () => {
    ui.askAddToNextUp({ Type: "Movie", Id: "m" });
    ui.askAddToNextUp({ Type: "Episode", Id: "e" }); // no series to add
    expect(document.querySelector(".dialog")).toBeNull();
  });

  it("asks where to pick the show up, with starting over as the red choice", () => {
    ui.askAddToNextUp({ Type: "Series", Id: "s1", Name: "Archer" });
    expect(document.querySelector(".dialog h2")!.textContent).toBe("Add Archer to Next Up");
    expect(dialogButton("Add from First Episode").classList.contains("danger")).toBe(true);
    expect(dialogButton("Add from Last Watched Episode").classList.contains("primary")).toBe(true);
    dialogButton("Cancel").click();
    expect(mapi.addToNextUp).not.toHaveBeenCalled();
  });

  it("adds from the last watched episode, names where, and tells Home", async () => {
    mapi.addToNextUp.mockResolvedValueOnce({ ParentIndexNumber: 2, IndexNumber: 4 });
    const changed = vi.fn();
    document.addEventListener("aquarium-next-up-changed", changed);
    ui.askAddToNextUp({ Type: "Episode", Id: "e", SeriesId: "s1", SeriesName: "Archer" });
    dialogButton("Add from Last Watched Episode").click();
    await settle();
    expect(mapi.addToNextUp).toHaveBeenCalledWith("s1", "last");
    expect(toasts().at(-1)).toBe("Added Archer to Next Up at S2:E4");
    expect(changed).toHaveBeenCalledTimes(1);
    document.removeEventListener("aquarium-next-up-changed", changed);
  });

  it("says a part-watched episode went to Continue Watching when Next Up leaves those out", async () => {
    await signIn({ next_up_in_progress: false });
    mapi.addToNextUp.mockResolvedValueOnce({ ParentIndexNumber: 1, IndexNumber: 3, UserData: { PlaybackPositionTicks: 5 } });
    ui.askAddToNextUp({ Type: "Season", Id: "se", ParentId: "s1", Name: "Season 1" });
    dialogButton("Add from Last Watched Episode").click();
    await settle();
    expect(mapi.addToNextUp).toHaveBeenCalledWith("s1", "last");
    expect(toasts().at(-1)).toBe("Season 1 is partway through at S1:E3, so it's in Continue Watching");
  });

  it("adds from the first episode, without a position when the episode has none", async () => {
    mapi.addToNextUp.mockResolvedValueOnce({ UserData: { PlaybackPositionTicks: 5 } });
    ui.askAddToNextUp({ Type: "Series", Id: "s1" });
    dialogButton("Add from First Episode").click();
    await settle();
    expect(mapi.addToNextUp).toHaveBeenCalledWith("s1", "first");
    expect(toasts().at(-1)).toBe("Added This show to Next Up");
  });

  it("explains an empty answer for each choice", async () => {
    ui.askAddToNextUp({ Type: "Series", Id: "s1", Name: "Archer" });
    dialogButton("Add from Last Watched Episode").click();
    await settle();
    expect(toasts().at(-1)).toBe("Every episode of Archer has been watched — add it from the first episode instead");
    ui.askAddToNextUp({ Type: "Series", Id: "s1", Name: "Archer" });
    dialogButton("Add from First Episode").click();
    await settle();
    expect(toasts().at(-1)).toBe("Archer has no episodes to add");
  });

  it("names an old server as the reason for a 404, and anything else plainly", async () => {
    mapi.addToNextUp.mockRejectedValueOnce(new Error("Server error 404 on /UserItems"));
    ui.askAddToNextUp({ Type: "Series", Id: "s1", Name: "Archer" });
    dialogButton("Add from Last Watched Episode").click();
    await settle();
    expect(toasts().at(-1)).toBe("This server is too old to add shows to Next Up");
    mapi.addToNextUp.mockRejectedValueOnce(new Error("boom"));
    ui.askAddToNextUp({ Type: "Series", Id: "s1", Name: "Archer" });
    dialogButton("Add from Last Watched Episode").click();
    await settle();
    expect(toasts().at(-1)).toBe("Couldn't add Archer to Next Up");
  });
});

describe("Delete from Server", () => {
  const REMOVAL = { kind: "movie" as const, tmdbId: 949, mediaId: 41, copies: [false], requestIds: [7] };
  const film = (extra: Record<string, any> = {}): any => ({ Id: "m1", Type: "Movie", Name: "Heat", ProviderIds: { Tmdb: "949" }, ...extra });
  const dialogButtons = (): string[] => [...document.querySelectorAll<HTMLButtonElement>(".dialog button")].map((b) => b.textContent ?? "");
  const dialogButton = (label: string): HTMLButtonElement =>
    [...document.querySelectorAll<HTMLButtonElement>(".dialog button")].find((b) => b.textContent === label)!;
  const last = (item: any): ui.MenuAction => ui.itemActions(item).at(-1)!;

  it("is in the menu only when the server allows it or Seerr might, and only for films and television", () => {
    expect(ui.mightDeleteFromServer(film())).toBe(false);
    expect(ui.mightDeleteFromServer(film({ CanDelete: false }))).toBe(false);
    expect(ui.mightDeleteFromServer(film({ CanDelete: true }))).toBe(true);
    for (const Type of ["Series", "Season", "Episode"]) expect(ui.mightDeleteFromServer({ Id: "x", Type, CanDelete: true })).toBe(true);
    for (const Type of ["MusicAlbum", "Audio", "BoxSet", "Playlist"]) expect(ui.mightDeleteFromServer({ Id: "x", Type, CanDelete: true })).toBe(false);
    mseerr.mightRemove.mockReturnValue(true);
    expect(ui.mightDeleteFromServer(film({ CanDelete: false }))).toBe(true);
    mseerr.mightRemove.mockReturnValue(false);
  });

  it("is the last entry, and red", () => {
    const entry = last(film({ CanDelete: true }));
    expect(entry.label).toBe("Delete from Server…");
    expect(entry.danger).toBe(true);
    expect(ui.itemActions(film()).some((a) => a.label === "Delete from Server…")).toBe(false);
  });

  it("offers only Jellyfin when Seerr has no part, and deletes the file on a yes", async () => {
    const heard = vi.fn();
    document.addEventListener("aquarium-item-deleted", heard);
    await ui.askDeleteFromServer(film({ CanDelete: true }));
    expect(document.querySelector(".dialog h2")!.textContent).toBe("Delete Heat?");
    expect(dialogButtons()).toEqual(["Cancel", "Delete from Jellyfin"]);
    expect(document.querySelector(".dialog p")!.textContent).toContain("can't be undone");
    expect(document.querySelector(".dialog p")!.textContent).not.toContain("Seerr");
    expect(mseerr.removal).not.toHaveBeenCalled();
    dialogButton("Delete from Jellyfin").click();
    await settle();
    expect(mapi.deleteItem).toHaveBeenCalledWith("m1");
    expect(toasts()).toContain("Deleted Heat from the server");
    expect(heard).toHaveBeenCalledTimes(1);
    document.removeEventListener("aquarium-item-deleted", heard);
  });

  it("deletes nothing on Cancel", async () => {
    await ui.askDeleteFromServer(film({ CanDelete: true }));
    dialogButton("Cancel").click();
    await settle();
    expect(mapi.deleteItem).not.toHaveBeenCalled();
  });

  it("offers both ways when both are open, and Seerr's removes through Seerr only", async () => {
    mseerr.mightRemove.mockReturnValue(true);
    mseerr.removal.mockResolvedValueOnce(REMOVAL);
    await ui.askDeleteFromServer(film({ CanDelete: true }));
    expect(dialogButtons()).toEqual(["Cancel", "Delete from Both", "Delete from Seerr", "Delete from Jellyfin"]);
    expect(document.querySelector(".dialog p")!.textContent).toContain("Radarr");
    dialogButton("Delete from Seerr").click();
    await settle();
    expect(mseerr.remove).toHaveBeenCalledWith(REMOVAL);
    expect(mapi.deleteItem).not.toHaveBeenCalled();
    expect(toasts().some((t) => t.startsWith("Removed Heat from Radarr"))).toBe(true);
    mseerr.mightRemove.mockReturnValue(false);
  });

  it("Both removes through Seerr, then deletes from Jellyfin", async () => {
    mseerr.mightRemove.mockReturnValue(true);
    mseerr.removal.mockResolvedValueOnce(REMOVAL);
    await ui.askDeleteFromServer(film({ CanDelete: true }));
    dialogButton("Delete from Both").click();
    await settle();
    expect(mseerr.remove).toHaveBeenCalledWith(REMOVAL);
    expect(mapi.deleteItem).toHaveBeenCalledWith("m1");
    expect(toasts()).toContain("Deleted Heat from Jellyfin and Radarr");
    mseerr.mightRemove.mockReturnValue(false);
  });

  it("Both deletes nothing from Jellyfin when Seerr refuses", async () => {
    mseerr.mightRemove.mockReturnValue(true);
    mseerr.removal.mockResolvedValueOnce(REMOVAL);
    mseerr.remove.mockRejectedValueOnce(new Error("No Radarr server configured to delete media files"));
    await ui.askDeleteFromServer(film({ CanDelete: true }));
    dialogButton("Delete from Both").click();
    await settle();
    expect(mapi.deleteItem).not.toHaveBeenCalled();
    expect(toasts().at(-1)).toContain("so nothing was deleted");
    mseerr.mightRemove.mockReturnValue(false);
  });

  it("offers only Seerr to an account Jellyfin won't let delete", async () => {
    mseerr.mightRemove.mockReturnValue(true);
    mseerr.removal.mockResolvedValueOnce(REMOVAL);
    await ui.askDeleteFromServer(film({ CanDelete: false }));
    expect(dialogButtons()).toEqual(["Cancel", "Delete from Seerr"]);
    mseerr.mightRemove.mockReturnValue(false);
  });

  it("asks nothing, and says why, when neither way turns out to be open", async () => {
    mseerr.mightRemove.mockReturnValue(true);
    await ui.askDeleteFromServer(film({ CanDelete: false }));
    expect(document.querySelector(".dialog")).toBeNull();
    expect(toasts().some((t) => t.includes("can't be deleted from here"))).toBe(true);
    mseerr.mightRemove.mockReturnValue(false);
  });

  it("fetches a grid's item whole for its TMDB id before asking Seerr", async () => {
    mseerr.mightRemove.mockReturnValue(true);
    const whole = film({ CanDelete: true });
    mapi.getItem.mockResolvedValueOnce(whole);
    mseerr.removal.mockResolvedValueOnce(REMOVAL);
    await ui.askDeleteFromServer({ Id: "m1", Type: "Movie", Name: "Heat" });
    expect(mapi.getItem).toHaveBeenCalledWith("m1");
    expect(mseerr.removal).toHaveBeenCalledWith(whole);
    expect(dialogButtons()).toContain("Delete from Jellyfin");
    mseerr.mightRemove.mockReturnValue(false);
  });

  it("names an episode with its show, and says Files for a show or a season", async () => {
    await ui.askDeleteFromServer({ Id: "e1", Type: "Episode", Name: "Pilot", SeriesName: "Archer", ParentIndexNumber: 1, IndexNumber: 3, CanDelete: true });
    expect(document.querySelector(".dialog h2")!.textContent).toBe("Delete Archer S1:E3?");
    keydown(document, "Escape");
    await ui.askDeleteFromServer({ Id: "s1", Type: "Series", Name: "Archer", CanDelete: true });
    expect(dialogButtons()).toContain("Delete from Jellyfin");
    expect(document.querySelector(".dialog p")!.textContent).toContain("every episode");
  });

  it("says so when the server refuses, or Seerr does", async () => {
    mapi.deleteItem.mockRejectedValueOnce(new Error("Server error 403 on /Items/m1"));
    await ui.askDeleteFromServer(film({ CanDelete: true }));
    dialogButton("Delete from Jellyfin").click();
    await settle();
    expect(toasts()).toContain("This account isn't allowed to delete Heat");

    mseerr.mightRemove.mockReturnValue(true);
    mseerr.removal.mockResolvedValueOnce(REMOVAL);
    mseerr.remove.mockRejectedValueOnce(new Error("No Radarr server configured to delete media files"));
    const heard = vi.fn();
    document.addEventListener("aquarium-item-deleted", heard);
    await ui.askDeleteFromServer(film());
    dialogButton("Delete from Seerr").click();
    await settle();
    expect(toasts()).toContain("Couldn't remove Heat: No Radarr server configured to delete media files");
    expect(heard).not.toHaveBeenCalled();
    document.removeEventListener("aquarium-item-deleted", heard);
    mseerr.mightRemove.mockReturnValue(false);
  });
});

describe("itemActions", () => {
  const labels = (a: ui.MenuAction[]) => a.map((x) => x.label);

  it("offers Resume with the time left and Play from start for a part-watched item", async () => {
    const ep = { Id: "e1", Type: "Episode", SeriesId: "s1", RunTimeTicks: 36_000_000_000, UserData: { PlaybackPositionTicks: 12_000_000_000 } };
    const acts = ui.itemActions(ep);
    expect(labels(acts).slice(0, 2)).toEqual(["Resume (40m left)", "Play from start"]);
    await acts[0]!.run!();
    expect(pb.playItem).toHaveBeenLastCalledWith(ep, { resume: true });
    await acts[1]!.run!();
    expect(pb.playItem).toHaveBeenLastCalledWith(ep, { resume: false });
  });

  it("says just Resume when the item has no runtime (regression: a963a95 \"Resume ( left)\")", () => {
    const acts = ui.itemActions({ Id: "v", Type: "Video", UserData: { PlaybackPositionTicks: 5 } });
    expect(acts[0]!.label).toBe("Resume");
  });

  it("offers Play for an unstarted item, and Play Next Episode for a series or season", async () => {
    const movie = { Id: "m1", Type: "Movie" };
    const acts = ui.itemActions(movie);
    expect(acts[0]!.label).toBe("Play");
    await acts[0]!.run!();
    expect(pb.playItem).toHaveBeenCalledWith(movie, { resume: false });
    expect(labels(acts)).toEqual(["Play", "Play Next", "Play Later", "Download", "Mark watched", "Add to favorites"]);
    expect(labels(ui.itemActions({ Id: "s", Type: "Series" }))).toEqual([
      "Play Next Episode",
      "Download series",
      "Mark watched",
      "Add to favorites",
      "Add to Next Up…",
    ]);
    expect(labels(ui.itemActions({ Id: "se", Type: "Season", SeriesId: "s" })).slice(0, 2)).toEqual([
      "Play Next Episode",
      "Play Season Next",
    ]);
  });

  describe("Play Next Episode", () => {
    const next = (item: any) => ui.itemActions(item).find((a) => a.label === "Play Next Episode")!;
    let nextUp: ReturnType<typeof vi.spyOn>;
    let episodes: ReturnType<typeof vi.spyOn>;
    let seasons: ReturnType<typeof vi.spyOn>;

    beforeEach(() => {
      nextUp = vi.spyOn(api, "getSeriesNextUp").mockResolvedValue(null as any);
      episodes = vi.spyOn(api, "getEpisodes").mockResolvedValue([]);
      seasons = vi.spyOn(api, "getSeasons").mockResolvedValue([]);
    });
    afterEach(() => {
      nextUp.mockRestore();
      episodes.mockRestore();
      seasons.mockRestore();
    });

    it("resumes a show at the episode the server says is next", async () => {
      const ep = { Id: "e7", Type: "Episode" };
      nextUp.mockResolvedValue(ep as any);
      await next({ Id: "s", Type: "Series" }).run!();
      expect(nextUp).toHaveBeenCalledWith("s");
      expect(pb.playItem).toHaveBeenCalledWith(ep, { resume: true });
      expect(seasons).not.toHaveBeenCalled();
    });

    it("starts a show nothing is next in from its first episode, past the specials", async () => {
      seasons.mockResolvedValue([{ Id: "sp", IndexNumber: 0 }, { Id: "se1", IndexNumber: 1 }]);
      const first = { Id: "e1", Type: "Episode" };
      episodes.mockResolvedValue([first, { Id: "e2", Type: "Episode" }]);
      await next({ Id: "s", Type: "Series" }).run!();
      expect(episodes).toHaveBeenCalledWith("s", "se1");
      expect(pb.playItem).toHaveBeenCalledWith(first, { resume: true });
    });

    it("plays a season's first unwatched episode, or its first when all are watched", async () => {
      const eps = [
        { Id: "e1", UserData: { Played: true } },
        { Id: "e2", UserData: { Played: false } },
        { Id: "e3" },
      ];
      episodes.mockResolvedValue(eps);
      await next({ Id: "se", Type: "Season", SeriesId: "s" }).run!();
      expect(episodes).toHaveBeenCalledWith("s", "se");
      expect(nextUp).not.toHaveBeenCalled();
      expect(pb.playItem).toHaveBeenLastCalledWith(eps[1], { resume: true });

      const seen = [{ Id: "e1", UserData: { Played: true } }, { Id: "e2", UserData: { Played: true } }];
      episodes.mockResolvedValue(seen);
      await next({ Id: "se", Type: "Season", SeriesId: "s" }).run!();
      expect(pb.playItem).toHaveBeenLastCalledWith(seen[0], { resume: true });
    });

    it("says so when there is nothing to play, and reports a failure", async () => {
      await next({ Id: "s", Type: "Series" }).run!();
      expect(pb.playItem).not.toHaveBeenCalled();
      expect(toasts().at(-1)).toBe("Nothing to play in it yet");
      nextUp.mockRejectedValue(new Error("server away"));
      await next({ Id: "s", Type: "Series" }).run!();
      expect(toasts().at(-1)).toBe("server away");
    });
  });

  it("marks watched and unwatched, updating the item and telling the caller", async () => {
    const onChanged = vi.fn();
    const item: any = { Id: "m1", Type: "Movie" };
    const mark = ui.itemActions(item, { onChanged }).find((a) => a.label === "Mark watched")!;
    await mark.run!();
    expect(mapi.markPlayed).toHaveBeenCalledWith("m1", true);
    expect(item.UserData).toEqual({ Played: true, PlaybackPositionTicks: 0 });
    expect(toasts().at(-1)).toBe("Marked watched");
    expect(onChanged).toHaveBeenCalledTimes(1);

    const unmark = ui.itemActions(item, { onChanged }).find((a) => a.label === "Mark unwatched")!;
    await unmark.run!();
    expect(mapi.markPlayed).toHaveBeenLastCalledWith("m1", false);
    expect(item.UserData.Played).toBe(false);
    expect(toasts().at(-1)).toBe("Marked unwatched");

    mapi.markPlayed.mockRejectedValueOnce(new Error("offline"));
    await ui.itemActions(item).find((a) => a.label === "Mark watched")!.run!();
    expect(toasts().at(-1)).toBe("offline");
    mapi.markPlayed.mockRejectedValueOnce("raw");
    await ui.itemActions(item).find((a) => a.label === "Mark watched")!.run!();
    expect(toasts().at(-1)).toBe("raw");
  });

  it("adds to and removes from favorites", async () => {
    const onChanged = vi.fn();
    const item: any = { Id: "m1", Type: "Movie" };
    const add = ui.itemActions(item, { onChanged }).find((a) => a.label === "Add to favorites")!;
    expect(add.icon).toBe("star-outline");
    await add.run!();
    expect(mapi.setFavorite).toHaveBeenCalledWith("m1", true);
    expect(item.UserData.IsFavorite).toBe(true);
    expect(toasts().at(-1)).toBe("Added to favorites");
    const remove = ui.itemActions(item, { onChanged }).find((a) => a.label === "Remove from favorites")!;
    expect(remove.icon).toBe("star");
    await remove.run!();
    expect(toasts().at(-1)).toBe("Removed from favorites");
    expect(onChanged).toHaveBeenCalledTimes(2);
    mapi.setFavorite.mockRejectedValueOnce(new Error("no"));
    await ui.itemActions(item).find((a) => a.label === "Add to favorites")!.run!();
    expect(toasts().at(-1)).toBe("no");
    mapi.setFavorite.mockRejectedValueOnce("raw");
    await ui.itemActions(item).find((a) => a.label === "Add to favorites")!.run!();
    expect(toasts().at(-1)).toBe("raw");
  });

  it("offers Add Show to Next Up on an episode, and Go to series", () => {
    const ep = { Id: "e1", Type: "Episode", SeriesId: "s1", SeriesName: "Archer" };
    const acts = ui.itemActions(ep);
    const add = acts.find((a) => a.label === "Add Show to Next Up…")!;
    add.run!();
    expect(document.querySelector(".dialog h2")!.textContent).toBe("Add Archer to Next Up");
    acts.find((a) => a.label === "Go to series")!.run!();
    expect(location.hash).toBe("#/item/s1");
  });

  it("offers Remove from Next Up on the Next Up row, and takes the show off", async () => {
    const changed = vi.fn();
    document.addEventListener("aquarium-next-up-changed", changed);
    const ep = { Id: "e1", Type: "Episode", SeriesId: "s1", SeriesName: "Archer" };
    const acts = ui.itemActions(ep, { nextUp: true });
    expect(acts.some((a) => a.label.startsWith("Add Show"))).toBe(false);
    await acts.find((a) => a.label === "Remove from Next Up")!.run!();
    expect(mapi.removeFromNextUp).toHaveBeenCalledWith("s1");
    expect(toasts().at(-1)).toBe("Removed Archer from Next Up");
    expect(changed).toHaveBeenCalledTimes(1);
    mapi.removeFromNextUp.mockRejectedValueOnce(new Error("x"));
    await acts.find((a) => a.label === "Remove from Next Up")!.run!();
    expect(toasts().at(-1)).toBe("Couldn't remove Archer from Next Up");
    expect(changed).toHaveBeenCalledTimes(1);
    document.removeEventListener("aquarium-next-up-changed", changed);
  });

  it("adds Show details when asked, for an item with an id", () => {
    const acts = ui.itemActions({ Id: "m1", Type: "Movie" }, { includeDetails: true });
    acts.find((a) => a.label === "Show details")!.run!();
    expect(location.hash).toBe("#/item/m1");
    expect(ui.itemActions({ Type: "Movie" }, { includeDetails: true }).some((a) => a.label === "Show details")).toBe(false);
  });
});

describe("itemCard", () => {
  it("draws a movie card that opens its page by click, Enter or Space", () => {
    const movie = { Id: "m1", Type: "Movie", Name: "Heat", ProductionYear: 1995, ImageTags: { Primary: "p" } };
    const card = ui.itemCard(movie);
    document.body.append(card);
    expect(card.classList.contains("wide")).toBe(false);
    expect(card.classList.contains("has-ctx")).toBe(true);
    expect(card.getAttribute("role")).toBe("button");
    expect(card.getAttribute("aria-label")).toBe("Heat — 1995");
    expect(card.dataset.itemId).toBe("m1");
    expect(card.querySelector(".card-title")!.textContent).toBe("Heat");
    expect(card.querySelector(".card-sub")!.textContent).toBe("1995");
    expect(card.querySelector("img")!.getAttribute("src")).toContain("/Items/m1/Images/Primary?maxWidth=320");
    card.click();
    expect(location.hash).toBe("#/item/m1");
    location.hash = "";
    expect(keydown(card, " ").defaultPrevented).toBe(true);
    expect(location.hash).toBe("#/item/m1");
    location.hash = "";
    keydown(card, "Enter");
    expect(location.hash).toBe("#/item/m1");
    location.hash = "";
    keydown(card, "x");
    keydown(card.querySelector(".pbtn")!, "Enter");
    expect(location.hash).toBe("");
  });

  it("plays from the overlay button without opening the page", () => {
    const movie = { Id: "m1", Type: "Movie", Name: "Heat" };
    const card = ui.itemCard(movie);
    document.body.append(card);
    location.hash = "";
    const btn = card.querySelector<HTMLButtonElement>(".pbtn")!;
    expect(btn.getAttribute("aria-label")).toBe("Play Heat");
    btn.click();
    expect(pb.playItem).toHaveBeenCalledWith(movie, { resume: true });
    expect(location.hash).toBe("");
  });

  it("opens a collection as a grid of what is in it (regression: 56a1825 collections)", () => {
    const card = ui.itemCard({ Id: "bs1", Type: "BoxSet", Name: "Trilogy" });
    card.click();
    expect(location.hash).toBe("#/lib/bs1");
    expect(card.querySelector(".play-overlay")).toBeNull();
  });

  it("shows progress, the time left and the watched badge", () => {
    const ep = {
      Id: "e1",
      Type: "Episode",
      Name: "Pilot",
      SeriesName: "Archer",
      ParentIndexNumber: 1,
      IndexNumber: 2,
      RunTimeTicks: 36_000_000_000,
      UserData: { PlaybackPositionTicks: 12_000_000_000, Played: true },
    };
    const card = ui.itemCard(ep);
    expect(card.classList.contains("wide")).toBe(true);
    expect(card.querySelector(".card-title")!.textContent).toBe("Archer");
    expect(card.querySelector(".card-sub")!.textContent).toBe("S1:E2 · Pilot");
    expect(card.querySelector(".time-left")!.textContent).toBe("40m left");
    expect(card.querySelector<HTMLElement>(".progress-strip > div")!.style.width).toMatch(/^33\.3/);
    expect(card.querySelector(".card-scrim")).not.toBeNull();
    expect(card.querySelector(".badge.played")).not.toBeNull();
    // Almost finished: the strip stays, the time-left pill goes.
    const nearly = ui.itemCard({ ...ep, UserData: { PlaybackPositionTicks: 35_900_000_000 } });
    expect(nearly.querySelector(".time-left")).toBeNull();
    expect(nearly.querySelector(".progress-strip")).not.toBeNull();
    // No runtime: no progress at all.
    const noRuntime = ui.itemCard({ ...ep, RunTimeTicks: 0 });
    expect(noRuntime.querySelector(".progress-strip")).toBeNull();
  });

  it("falls back to the series still for an episode without one, and names a numberless episode by itself", () => {
    const card = ui.itemCard({ Id: "e1", Type: "Episode", Name: "Special", SeriesId: "s1", SeriesName: "Archer" });
    // The series id has no tag to ask for, so the letter tile stands in.
    expect(card.querySelector("img")).toBeNull();
    expect(card.querySelector(".noart")!.textContent).toBe("A");
    expect(card.querySelector(".card-sub")!.textContent).toBe("Special");
    const withSeries = ui.itemCard({ Id: "e1", Type: "Episode", Name: "Special", SeriesId: "s1" }, { wide: true });
    expect(withSeries.querySelector(".card-title")!.textContent).toBe("Special");
  });

  it("counts a series' unplayed episodes in a badge on the poster, under its year and score", () => {
    const card = ui.itemCard({
      Id: "s1",
      Type: "Series",
      Name: "Archer",
      ProductionYear: 2009,
      CommunityRating: 8.64,
      RunTimeTicks: 13_200_000_000,
      UserData: { UnplayedItemCount: 4 },
    });
    const badge = card.querySelector(".card-poster .badge.unplayed")!;
    expect(badge.textContent).toBe("4");
    expect(badge.getAttribute("title")).toBe("4 to watch");
    // A show's line is its year and score; only a film has a length.
    expect(card.querySelector(".card-sub")!.textContent).toBe("2009 · ★ 8.6");
    expect(card.querySelector(".play-overlay")).toBeNull();

    // No badge for a show with nothing left, nor for anything that is not a show.
    expect(ui.itemCard({ Id: "s2", Type: "Series", Name: "Done", UserData: { UnplayedItemCount: 0 } }).querySelector(".badge.unplayed")).toBeNull();
    expect(ui.itemCard({ Id: "b1", Type: "BoxSet", Name: "Set", UserData: { UnplayedItemCount: 3 } }).querySelector(".badge.unplayed")).toBeNull();
  });

  it("draws a Next Up card with the season poster, two spelled-out lines, opening the show", () => {
    const ep = {
      Id: "e1",
      Type: "Episode",
      Name: "Pilot",
      SeriesName: "Archer",
      SeriesId: "s1",
      SeasonId: "se1",
      SeriesPrimaryImageTag: "sp",
      ParentIndexNumber: 2,
      IndexNumber: 4,
      ImageBlurHashes: { Primary: { sp: "LEHV6nWB2yk8" } },
    };
    const card = ui.itemCard(ep, { art: "season" });
    expect(card.classList.contains("wide")).toBe(false);
    const subs = [...card.querySelectorAll(".card-sub")].map((n) => n.textContent);
    expect(subs).toEqual(["Season 2: Episode 4", "Pilot"]);
    const img = card.querySelector("img")!;
    expect(img.getAttribute("src")).toContain("/Items/se1/Images/Primary");
    // The item's own BlurHash is of a different picture.
    expect(img.classList.contains("has-ph")).toBe(false);
    img.dispatchEvent(new Event("error"));
    expect(card.querySelector("img")!.getAttribute("src")).toContain("/Items/s1/Images/Primary");
    card.click();
    expect(location.hash).toBe("#/item/s1");

    const special = ui.itemCard({ ...ep, ParentIndexNumber: 0 }, { art: "season" });
    expect(special.querySelector(".card-sub")!.textContent).toBe("Specials: Episode 4");
    const noSeason = ui.itemCard({ ...ep, ParentIndexNumber: undefined }, { art: "season" });
    expect(noSeason.querySelector(".card-sub")!.textContent).toBe("Episode 4");
    const noNumber = ui.itemCard({ ...ep, IndexNumber: undefined }, { art: "season" });
    expect([...noNumber.querySelectorAll(".card-sub")].map((n) => n.textContent)).toEqual(["Pilot"]);
    // Season art is only for episodes.
    const movie = ui.itemCard({ Id: "m", Type: "Movie", Name: "Heat" }, { art: "season" });
    movie.click();
    expect(location.hash).toBe("#/item/m");
  });

  it("redraws itself after a menu action and tells the view", async () => {
    const onChanged = vi.fn();
    const item: any = { Id: "m1", Type: "Movie", Name: "Heat" };
    const card = ui.itemCard(item, { onChanged });
    document.body.append(card);
    card.dispatchEvent(new MouseEvent("contextmenu", { bubbles: true, cancelable: true }));
    expect(menuButtons().map((b) => b.textContent)).toContain("Show details");
    menuButton("Mark watched").click();
    await settle();
    expect(onChanged).toHaveBeenCalledTimes(1);
    const [changedItem, next] = onChanged.mock.calls[0]!;
    expect(changedItem).toBe(item);
    expect(card.isConnected).toBe(false);
    expect((next as HTMLElement).isConnected).toBe(true);
    expect((next as HTMLElement).querySelector(".badge.played")).not.toBeNull();
  });

  it("offers Remove from Next Up on a Next Up card's menu", () => {
    const card = ui.itemCard({ Id: "e1", Type: "Episode", SeriesId: "s1", Name: "x" }, { nextUp: true });
    document.body.append(card);
    card.dispatchEvent(new MouseEvent("contextmenu", { bubbles: true, cancelable: true }));
    expect(menuButtons().map((b) => b.textContent)).toContain("Remove from Next Up");
  });

  it("gives a channel card no menu", () => {
    const card = ui.itemCard({ Id: "c1", Type: "TvChannel", Name: "News" });
    expect(card.classList.contains("has-ctx")).toBe(false);
    expect(card.querySelector(".play-overlay")).not.toBeNull();
    expect(card.getAttribute("aria-label")).toBe("News");
  });
});

describe("scrollRow, cardRow and section", () => {
  function sized(row: HTMLElement, scrollWidth: number, clientWidth: number): void {
    Object.defineProperty(row, "scrollWidth", { configurable: true, value: scrollWidth });
    Object.defineProperty(row, "clientWidth", { configurable: true, value: clientWidth });
  }

  it("shows the arrow and fade only for a direction that has more, and pages by most of a width", async () => {
    const row = ui.el("div", { class: "card-row" });
    sized(row, 1000, 400);
    const wrap = ui.scrollRow(row);
    const prev = wrap.querySelector<HTMLButtonElement>(".row-nav.prev")!;
    const next = wrap.querySelector<HTMLButtonElement>(".row-nav.next")!;
    await new Promise((r) => setTimeout(r, 0));
    expect(wrap.classList.contains("can-prev")).toBe(false);
    expect(wrap.classList.contains("can-next")).toBe(true);
    expect(prev.disabled).toBe(true);
    expect(next.disabled).toBe(false);

    const by = vi.fn();
    (row as any).scrollBy = by;
    next.click();
    expect(by).toHaveBeenLastCalledWith({ left: 320, behavior: "smooth" });

    row.scrollLeft = 600;
    row.dispatchEvent(new Event("scroll"));
    expect(wrap.classList.contains("can-prev")).toBe(true);
    expect(wrap.classList.contains("can-next")).toBe(false);
    expect(next.disabled).toBe(true);
    prev.click();
    expect(by).toHaveBeenLastCalledWith({ left: -320, behavior: "smooth" });
  });

  it("offers no arrows for a row that fits", async () => {
    const row = ui.el("div");
    sized(row, 400, 400);
    const wrap = ui.scrollRow(row);
    await new Promise((r) => setTimeout(r, 0));
    expect(wrap.classList.contains("can-next")).toBe(false);
  });

  it("cardRow wraps a card per item", () => {
    const wrap = ui.cardRow([{ Id: "a", Type: "Movie" }, { Id: "b", Type: "Movie" }], { wide: true });
    expect(wrap.className).toBe("row-wrap");
    expect(wrap.querySelectorAll(".card-row > .card.wide")).toHaveLength(2);
  });

  it("section has a heading and, when asked, a See all that works from the keyboard (regression: a963a95 keyboard reach)", () => {
    const seeAll = vi.fn();
    const s = ui.section("Recently added", ui.el("div", { class: "x" }), seeAll);
    expect(s.querySelector("h2")!.textContent).toBe("Recently added");
    const link = s.querySelector<HTMLElement>(".see-all")!;
    expect(link.getAttribute("tabindex")).toBe("0");
    link.click();
    keydown(link, "Enter");
    expect(seeAll).toHaveBeenCalledTimes(2);
    expect(ui.section("Plain", ui.el("div")).querySelector(".see-all")).toBeNull();
  });
});

describe("wordmark", () => {
  it("is one word to a screen reader, drawn as lowercase with a bubble for the i's dot", () => {
    const mark = ui.wordmark();
    expect(mark.className).toBe("wordmark");
    expect(mark.getAttribute("role")).toBe("img");
    expect(mark.getAttribute("aria-label")).toBe("Aquarium");
    // The dotless i carries the bubble; a dotted one would show both.
    expect(mark.textContent).toBe("aquarıum");
    const i = mark.querySelector(".wm-i")!;
    expect(i.textContent).toBe("ı");
    expect(i.getAttribute("aria-hidden")).toBe("true");
    // Regression: the FellyJin-era split ("Aqua" + bold "rium") is gone.
    expect(mark.querySelector("b")).toBeNull();
  });

  it("matches the static one in the sidebar of index.html", async () => {
    const { readFileSync } = await import("node:fs");
    const { resolve } = await import("node:path");
    const html = readFileSync(resolve(__dirname, "../../index.html"), "utf8");
    const doc = new DOMParser().parseFromString(html, "text/html");
    const side = doc.querySelector(".brand .wordmark")!;
    expect(side.getAttribute("aria-label")).toBe("Aquarium");
    expect(side.textContent).toBe(ui.wordmark().textContent);
    expect(side.querySelector(".wm-i")).not.toBeNull();
  });
});
