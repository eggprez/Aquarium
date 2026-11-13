// src/theme.ts (light/dark preference) and public/theme-boot.js (the
// pre-paint script that applies the cached theme and carries the legacy
// `fellyjin` localStorage keys over).
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { emitEvent, invokeCalls, onInvoke, signIn } from "../helpers/tauri";

type Theme = typeof import("../../src/theme");
let theme: Theme;

beforeEach(async () => {
  vi.resetModules();
  delete document.documentElement.dataset.theme;
  theme = await import("../../src/theme");
});

afterEach(() => {
  vi.restoreAllMocks();
});

/** Make matchMedia answer `scheme` and hand back the change listeners. */
function media(scheme: "light" | "dark" | null): { fire: () => void; set: (s: "light" | "dark" | null) => void } {
  let current = scheme;
  const listeners: (() => void)[] = [];
  vi.spyOn(window, "matchMedia").mockImplementation(
    (q: string) =>
      ({
        matches: current !== null && q.includes(current),
        media: q,
        addEventListener: (_: string, cb: () => void) => listeners.push(cb),
        removeEventListener() {},
      }) as any
  );
  return {
    fire: () => listeners.forEach((cb) => cb()),
    set: (s) => (current = s),
  };
}

const html = (): string | undefined => document.documentElement.dataset.theme;

describe("normalizePref", () => {
  it.each([
    ["light", "light"],
    ["dark", "dark"],
    ["auto", "auto"],
    [undefined, "auto"],
    ["Dark", "auto"],
    [3, "auto"],
  ])("%j -> %j", (v, want) => {
    expect(theme.normalizePref(v)).toBe(want);
  });
});

describe("initTheme", () => {
  it("follows the portal's scheme under 'auto', and mirrors it to localStorage for theme-boot.js", async () => {
    await signIn({ theme: "auto" });
    onInvoke("system_color_scheme", "light");
    media("dark");
    await theme.initTheme();
    expect(html()).toBe("light");
    expect(localStorage.getItem("aquarium.theme.resolved")).toBe("light");
    expect(theme.getThemePref()).toBe("auto");
  });

  it("an explicit preference wins over the desktop", async () => {
    await signIn({ theme: "light" });
    onInvoke("system_color_scheme", "dark");
    await theme.initTheme();
    expect(html()).toBe("light");
  });

  it("falls back to matchMedia when the portal is unavailable", async () => {
    await signIn({});
    onInvoke("system_color_scheme", () => {
      throw new Error("no portal");
    });
    media("light");
    await theme.initTheme();
    expect(html()).toBe("light");
  });

  it("falls back to matchMedia when the portal expresses no preference", async () => {
    await signIn({});
    onInvoke("system_color_scheme", "no-preference");
    media("dark");
    await theme.initTheme();
    expect(html()).toBe("dark");
  });

  it("is dark, Aquarium's own default, when nothing says otherwise", async () => {
    await signIn({});
    onInvoke("system_color_scheme", "");
    media(null);
    await theme.initTheme();
    expect(html()).toBe("dark");
  });

  it("follows the desktop flipping light/dark while running, under 'auto' only", async () => {
    await signIn({ theme: "auto" });
    onInvoke("system_color_scheme", "dark");
    await theme.initTheme();
    expect(html()).toBe("dark");
    emitEvent("system-color-scheme", "light");
    expect(html()).toBe("light");

    await theme.setThemePref("dark");
    emitEvent("system-color-scheme", "light");
    expect(html()).toBe("dark");
  });

  it("the matchMedia change fallback applies only under 'auto' with no portal value", async () => {
    await signIn({ theme: "auto" });
    onInvoke("system_color_scheme", () => {
      throw new Error("none");
    });
    const mq = media("dark");
    await theme.initTheme();
    expect(html()).toBe("dark");
    mq.set("light");
    mq.fire();
    expect(html()).toBe("light");

    // Once the portal has spoken, a GTK-theme change no longer decides.
    emitEvent("system-color-scheme", "dark");
    expect(html()).toBe("dark");
    mq.set("light");
    mq.fire();
    expect(html()).toBe("dark");
  });

  it("still applies the theme when localStorage throws (private mode)", async () => {
    await signIn({ theme: "light" });
    onInvoke("system_color_scheme", "dark");
    vi.spyOn(Storage.prototype, "setItem").mockImplementation(() => {
      throw new Error("quota");
    });
    await theme.initTheme();
    expect(html()).toBe("light");
  });
});

describe("setThemePref", () => {
  it("applies at once and saves only the theme key to config.json", async () => {
    await signIn({});
    onInvoke("system_color_scheme", "dark");
    await theme.initTheme();
    await theme.setThemePref("light");
    expect(html()).toBe("light");
    expect(theme.getThemePref()).toBe("light");
    expect(invokeCalls("config_save").at(-1)!.args).toEqual({ cfg: { theme: "light" } });
  });

  it("normalises a bad value to 'auto' before saving it", async () => {
    await signIn({});
    await theme.setThemePref("purple" as any);
    expect(theme.getThemePref()).toBe("auto");
    expect(invokeCalls("config_save").at(-1)!.args).toEqual({ cfg: { theme: "auto" } });
  });
});

describe("public/theme-boot.js", () => {
  const src = readFileSync(resolve(__dirname, "../../public/theme-boot.js"), "utf8");
  const boot = (): void => {
    // Run as the classic script it is, in the page's global scope.
    new Function(src)();
  };

  it("applies the cached light theme before first paint", () => {
    localStorage.setItem("aquarium.theme.resolved", "light");
    boot();
    expect(html()).toBe("light");
  });

  it.each([null, "dark", "nonsense"])("is dark for a cached value of %j", (v) => {
    if (v !== null) localStorage.setItem("aquarium.theme.resolved", v);
    boot();
    expect(html()).toBe("dark");
  });

  it("is dark when localStorage cannot be read", () => {
    vi.spyOn(Storage.prototype, "getItem").mockImplementation(() => {
      throw new Error("denied");
    });
    vi.spyOn(Storage.prototype, "key").mockImplementation(() => {
      throw new Error("denied");
    });
    boot();
    expect(html()).toBe("dark");
  });

  describe("legacy fellyjin carry-over (invariant: keeps existing installs' preferences)", () => {
    it("renames every fellyjin* key to aquarium* and removes the old one", () => {
      localStorage.setItem("fellyjin.theme.resolved", "light");
      localStorage.setItem("fellyjin.lastRoute", "#/home");
      localStorage.setItem("fellyjinX", "1");
      localStorage.setItem("other.key", "kept");
      boot();
      expect(localStorage.getItem("aquarium.theme.resolved")).toBe("light");
      expect(localStorage.getItem("aquarium.lastRoute")).toBe("#/home");
      expect(localStorage.getItem("aquariumX")).toBe("1");
      expect(localStorage.getItem("fellyjin.theme.resolved")).toBeNull();
      expect(localStorage.getItem("fellyjin.lastRoute")).toBeNull();
      expect(localStorage.getItem("other.key")).toBe("kept");
      // The carried-over theme is the one applied, in the same run.
      expect(html()).toBe("light");
    });

    it("never overwrites a key the new name already has", () => {
      localStorage.setItem("fellyjin.theme.resolved", "light");
      localStorage.setItem("aquarium.theme.resolved", "dark");
      boot();
      expect(localStorage.getItem("aquarium.theme.resolved")).toBe("dark");
      expect(localStorage.getItem("fellyjin.theme.resolved")).toBeNull();
      expect(html()).toBe("dark");
    });

    it("only matches keys that start with fellyjin", () => {
      localStorage.setItem("my.fellyjin.key", "x");
      boot();
      expect(localStorage.getItem("my.fellyjin.key")).toBe("x");
      expect(localStorage.length).toBe(1);
    });

    it("is idempotent: a second run changes nothing", () => {
      localStorage.setItem("fellyjin.a", "1");
      boot();
      boot();
      expect(localStorage.getItem("aquarium.a")).toBe("1");
      expect(localStorage.length).toBe(1);
    });
  });
});
