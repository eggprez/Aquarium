// src/main.ts: the shell around the pages — the sidebar and its footer,
// going offline and probing for the server's return, accounts, an expired
// session, a server whose identity changed, search, the shortcut sheet and
// arrow-key navigation between tiles.
import { afterEach, describe, expect, it, vi } from "vitest";
import { emitEvent, flush, invokeCalls, onInvoke } from "../helpers/tauri";
import {
  bootShell,
  click,
  fakeTimers,
  hidden,
  key,
  page,
  settle,
  startPlaying,
  teardownShell,
  toasts,
} from "../helpers/main-shell";

afterEach(teardownShell);

const $ = (id: string): HTMLElement => document.getElementById(id)!;
const shown = (id: string): boolean => !$(id).classList.contains("hidden");

function navEntries(): string[] {
  return [...$("nav").children].map((n) =>
    n.classList.contains("nav-sep") ? `— ${n.textContent}` : `${n.textContent} ${n.getAttribute("data-route")}`
  );
}

function footer(): { version: string; line: string; cls: string } {
  const line = $("sidebar-footer").querySelector(".foot-line")!;
  return {
    version: $("sidebar-footer").querySelector(".foot-version")!.textContent ?? "",
    line: line.textContent ?? "",
    cls: line.className,
  };
}

describe("sidebar", () => {
  it("lists the video libraries, then music, books, the app's own pages and Live TV where there is one", async () => {
    await bootShell({
      libraries: [
        { Id: "m", Name: "Films", CollectionType: "movies" },
        { Id: "t", Name: "Shows", CollectionType: "tvshows" },
        { Id: "h", Name: "Home videos", CollectionType: "homevideos" },
        { Id: "f", Name: "Mixed" },
        { Id: "p", Name: "Photos", CollectionType: "photos" },
        { Id: "mu", Name: "Music", CollectionType: "music" },
        { Id: "b", Name: "Books", CollectionType: "audiobooks" },
        { Id: "bs", Name: "Collections", CollectionType: "boxsets" },
        { Id: "l", Name: "Live", CollectionType: "livetv" },
      ],
    });
    expect(navEntries()).toEqual([
      "Home #/home",
      "— Libraries",
      "Films #/lib/m",
      "Shows #/lib/t",
      "Home videos #/lib/h",
      "Mixed #/lib/f",
      "— Music",
      "Listen Now #/music/discover",
      "Library #/music/library",
      "Audiobooks #/books",
      "— Aquarium",
      "Favorites #/favorites",
      // regression: 56a1825 — Jellyfin's box sets get an entry of their own.
      "Collections #/lib/bs",
      "Live TV #/livetv",
      "Downloads #/downloads",
      "Settings #/settings",
    ]);
  });

  it("gives books a heading of their own without music, and Live TV to a custom playlist", async () => {
    await bootShell({ libraries: [{ Id: "b", Name: "Books", CollectionType: "books" }], config: { livetv_source: "custom" } });
    expect(navEntries()).toContain("— Listening");
    expect(navEntries()).toContain("Live TV #/livetv");
  });

  it("draws only what needs no server when the library list cannot be had", async () => {
    await bootShell({
      libraries: () => {
        throw new Error("500");
      },
    });
    expect(navEntries()).toEqual([
      "Home #/home",
      "— Aquarium",
      "Favorites #/favorites",
      "Downloads #/downloads",
      "Settings #/settings",
    ]);
  });

  it("paints the last known list at once on the next launch, and redraws only when it changed", async () => {
    await bootShell({ libraries: [{ Id: "m", Name: "Films", CollectionType: "movies" }] });
    teardownShell();
    let release: (v: any) => void = () => {};
    const shell = await bootShell({ keepCache: true, libraries: () => new Promise((r) => (release = r)) as any });
    expect(navEntries()).toContain("Films #/lib/m");
    const films = $("nav").querySelector('[data-route="#/lib/m"]');
    release([{ Id: "m", Name: "Films", CollectionType: "movies" }]);
    await settle();
    // Same list: the very same button is still there.
    expect($("nav").querySelector('[data-route="#/lib/m"]')).toBe(films);
    void shell;
  });

  it("redraws when a refreshed list differs from the cached one", async () => {
    await bootShell({ libraries: [{ Id: "m", Name: "Films", CollectionType: "movies" }] });
    teardownShell();
    await bootShell({ keepCache: true, libraries: [{ Id: "m", Name: "Movies", CollectionType: "movies" }] });
    await settle();
    expect(navEntries()).toContain("Movies #/lib/m");
    expect(navEntries()).not.toContain("Films #/lib/m");
  });

  it("keeps the cached list when the fresh one fails", async () => {
    await bootShell({ libraries: [{ Id: "m", Name: "Films", CollectionType: "movies" }] });
    teardownShell();
    await bootShell({
      keepCache: true,
      libraries: () => {
        throw new Error("500");
      },
    });
    await settle();
    expect(navEntries()).toContain("Films #/lib/m");
  });

  it("marks where you are, in words for a screen reader too, and navigates on click", async () => {
    const shell = await bootShell();
    const home = $("nav").querySelector<HTMLElement>('[data-route="#/home"]')!;
    expect(home.classList.contains("active")).toBe(true);
    expect(home.getAttribute("aria-current")).toBe("page");
    click($("nav").querySelector('[data-route="#/lib/lib-movies"]')!);
    await settle();
    expect(location.hash).toBe("#/lib/lib-movies");
    const films = $("nav").querySelector<HTMLElement>('[data-route="#/lib/lib-movies"]')!;
    expect(films.classList.contains("active")).toBe(true);
    expect(home.hasAttribute("aria-current")).toBe(false);
    // A page under a route keeps its entry lit.
    await shell.go("#/music/library/albums");
    await shell.go("#/settings");
    expect($("nav").querySelector('[data-route="#/settings"]')!.classList.contains("active")).toBe(true);
  });

  it("rebuilds when asked (the Live TV source changed in Settings)", async () => {
    const shell = await bootShell();
    expect(navEntries()).not.toContain("Live TV #/livetv");
    shell.api.getConfig().livetv_source = "custom";
    document.dispatchEvent(new CustomEvent("aquarium-nav-refresh"));
    await settle();
    expect(navEntries()).toContain("Live TV #/livetv");
  });
});

describe("sidebar footer", () => {
  it("names the build and says Synced when nothing is outstanding", async () => {
    await bootShell();
    expect(footer()).toEqual({ version: "Aquarium v9.9.9", line: "Synced", cls: "foot-line ok" });
  });

  it("counts running downloads, then offline progress waiting to sync", async () => {
    await bootShell({ downloads: [{ status: "downloading" }, { status: "downloading" }, { status: "complete" }] });
    expect(footer().line).toBe("2 downloads running");
    expect(footer().cls).toBe("foot-line busy");
    teardownShell();
    await bootShell({ downloads: [{ status: "downloading" }] });
    expect(footer().line).toBe("1 download running");
    teardownShell();
    await bootShell({ invokes: { progress_pending: 3, progress_sync: { synced: 0 } } });
    expect(footer().line).toBe("Syncing 3 items");
    teardownShell();
    await bootShell({ invokes: { progress_pending: 1, progress_sync: { synced: 0 } } });
    expect(footer().line).toBe("Syncing 1 item");
  });

  it("says Offline, with what is waiting to sync", async () => {
    await bootShell({ ping: false, pending: 2 });
    expect(footer()).toMatchObject({ line: "Offline · 2 to sync", cls: "foot-line warn" });
    teardownShell();
    await bootShell({ ping: false });
    expect(footer().line).toBe("Offline");
  });

  it("re-reads when the progress queue changes, and when a download finishes but not on every byte", async () => {
    let pending = 0;
    await bootShell({ invokes: { progress_pending: () => pending } });
    pending = 4;
    emitEvent("progress-queue-changed");
    await settle();
    expect(footer().line).toBe("Syncing 4 items");
    pending = 0;
    document.dispatchEvent(new CustomEvent("aquarium-progress-queue"));
    await settle();
    expect(footer().line).toBe("Synced");
    pending = 7;
    const reads = invokeCalls("progress_pending").length;
    emitEvent("download-progress", { state: "downloading" });
    emitEvent("download-progress", {});
    await settle();
    expect(invokeCalls("progress_pending").length).toBe(reads);
    emitEvent("download-progress", { state: "complete" });
    await settle();
    expect(footer().line).toBe("Syncing 7 items");
  });
});

describe("going offline and coming back", () => {
  async function onlineThenOff(): Promise<{ shell: Awaited<ReturnType<typeof bootShell>>; setUp: (v: boolean) => void }> {
    let up = true;
    const shell = await bootShell({ ping: () => up });
    fakeTimers();
    up = false;
    await shell.api.checkOnline();
    await flush();
    return { shell, setUp: (v) => (up = v) };
  }

  it("says so, shows the pill, and redraws the page as the offline screen", async () => {
    const { shell } = await onlineThenOff();
    expect(toasts()).toContain("Server unreachable — offline mode. Downloads still work.");
    expect($("offline-pill").hasAttribute("hidden")).toBe(false);
    expect($("content").querySelector(".offline-screen")).not.toBeNull();
    void shell;
  });

  it("probes again at 15 s, backing off by doubling to five minutes", async () => {
    await onlineThenOff();
    const pings = () => invokeCalls("jf_ping").length;
    const start = pings();
    await vi.advanceTimersByTimeAsync(14_999);
    expect(pings()).toBe(start);
    await vi.advanceTimersByTimeAsync(1);
    expect(pings()).toBe(start + 1);
    await vi.advanceTimersByTimeAsync(29_999);
    expect(pings()).toBe(start + 1);
    await vi.advanceTimersByTimeAsync(1);
    expect(pings()).toBe(start + 2);
    // 60, 120, 240, then the 300 s ceiling.
    await vi.advanceTimersByTimeAsync(60_000 + 120_000 + 240_000);
    expect(pings()).toBe(start + 5);
    await vi.advanceTimersByTimeAsync(299_999);
    expect(pings()).toBe(start + 5);
    await vi.advanceTimersByTimeAsync(1);
    expect(pings()).toBe(start + 6);
  });

  it("comes back: stops probing, says so, rebuilds the sidebar, redraws and pushes offline progress", async () => {
    const { setUp } = await onlineThenOff();
    onInvoke("progress_pending", 1);
    onInvoke("progress_sync", { synced: 1, failed: 0 });
    setUp(true);
    await vi.advanceTimersByTimeAsync(15_000);
    await flush();
    expect(toasts()).toContain("Back online");
    expect($("offline-pill").hasAttribute("hidden")).toBe(true);
    expect(page()).toBe("home");
    expect(invokeCalls("progress_sync").length).toBeGreaterThan(0);
    const pings = invokeCalls("jf_ping").length;
    await vi.advanceTimersByTimeAsync(600_000);
    expect(invokeCalls("jf_ping").length).toBe(pings);
  });

  it("stops probing once signed out", async () => {
    const { shell } = await onlineThenOff();
    onInvoke("jf_logout", () => {
      shell.cfg.has_token = false;
      return { revoked: true };
    });
    await shell.api.logout();
    const pings = invokeCalls("jf_ping").length;
    await vi.advanceTimersByTimeAsync(15_000);
    expect(invokeCalls("jf_ping").length).toBe(pings);
  });

  it("asks again soon after the network comes back, and ignores it going away", async () => {
    await onlineThenOff();
    const pings = () => invokeCalls("jf_ping").length;
    const start = pings();
    emitEvent("network-changed", { available: false });
    emitEvent("network-changed", null);
    await vi.advanceTimersByTimeAsync(1500);
    expect(pings()).toBe(start);
    emitEvent("network-changed", { available: true });
    await vi.advanceTimersByTimeAsync(1499);
    expect(pings()).toBe(start);
    await vi.advanceTimersByTimeAsync(1);
    expect(pings()).toBe(start + 1);
  });

  it("asks at once when the window comes back into view, not while it is hidden", async () => {
    await onlineThenOff();
    const pings = () => invokeCalls("jf_ping").length;
    const start = pings();
    hidden(true);
    document.dispatchEvent(new Event("visibilitychange"));
    await vi.advanceTimersByTimeAsync(0);
    expect(pings()).toBe(start);
    hidden(false);
    document.dispatchEvent(new Event("visibilitychange"));
    await vi.advanceTimersByTimeAsync(0);
    expect(pings()).toBe(start + 1);
  });

  it("network and visibility cues mean nothing while online", async () => {
    await bootShell();
    fakeTimers();
    const n = invokeCalls("jf_ping").length;
    emitEvent("network-changed", { available: true });
    document.dispatchEvent(new Event("visibilitychange"));
    await vi.advanceTimersByTimeAsync(20_000);
    expect(invokeCalls("jf_ping").length).toBe(n);
  });

  it("the pill's Retry says when the server is still away, and starts the backoff over", async () => {
    const { setUp } = await onlineThenOff();
    await vi.advanceTimersByTimeAsync(15_000 + 30_000);
    const before = invokeCalls("jf_ping").length;
    click($("offline-retry"));
    await flush();
    expect(invokeCalls("jf_ping").length).toBe(before + 1);
    expect(toasts().filter((t) => t === "Still offline — server unreachable")).toHaveLength(1);
    // The next automatic probe is 15 s out again, not 60.
    await vi.advanceTimersByTimeAsync(15_000);
    expect(invokeCalls("jf_ping").length).toBe(before + 2);
    setUp(true);
    click($("offline-retry"));
    await flush();
    expect(toasts()).toContain("Back online");
  });

  it("arms the first probe for a session restored while the server is already away", async () => {
    const set = vi.spyOn(window, "setTimeout");
    let up = false;
    await bootShell({ ping: () => up });
    const probe = set.mock.calls.find((c) => c[1] === 15_000);
    set.mockRestore();
    expect(probe).toBeDefined();
    up = true;
    await (probe![0] as () => Promise<void>)();
    await settle();
    expect(toasts()).toContain("Back online");
  });
});

describe("accounts", () => {
  it("switches to another saved account and redraws the shell for it, on Home", async () => {
    const shell = await bootShell({
      invokes: {
        account_switch: () => {
          shell.cfg.user_name = "second";
          shell.cfg.user_id = "user-2";
          return null;
        },
      },
    });
    await shell.go("#/settings");
    document.dispatchEvent(new CustomEvent("aquarium-account-switch", { detail: { key: "k2" } }));
    await settle();
    expect(invokeCalls("account_switch")[0]!.args).toEqual({ key: "k2" });
    expect(toasts()).toContain("Signed in as second");
    expect(location.hash).toBe("#/home");
    expect($("topbar-user").textContent).toContain("second");
  });

  it("says why a switch failed, and stays where it was", async () => {
    const shell = await bootShell({ invokes: { account_switch: () => Promise.reject("config|That account's token is gone") } });
    await shell.go("#/settings");
    const renders = shell.views.settings.mock.calls.length;
    document.dispatchEvent(new CustomEvent("aquarium-account-switch", { detail: { key: "k2" } }));
    await settle();
    expect(toasts()).toContain("That account's token is gone");
    expect(location.hash).toBe("#/settings");
    expect(shell.views.settings.mock.calls.length).toBe(renders + 1);
  });

  it("ignores a switch with no account named", async () => {
    await bootShell();
    document.dispatchEvent(new CustomEvent("aquarium-account-switch", { detail: {} }));
    document.dispatchEvent(new CustomEvent("aquarium-account-switch"));
    await settle();
    expect(invokeCalls("account_switch")).toHaveLength(0);
  });

  it("Add Account opens the sign-in screen over the shell, and Cancel goes back untouched", async () => {
    await bootShell();
    document.dispatchEvent(new CustomEvent("aquarium-add-account"));
    await settle();
    expect(shown("login-root")).toBe(true);
    expect(shown("shell")).toBe(false);
    const cancel = [...$("login-root").querySelectorAll("button")].find((b) => /cancel/i.test(b.textContent ?? ""));
    expect(cancel).toBeDefined();
    click(cancel!);
    expect(shown("login-root")).toBe(false);
    expect(shown("shell")).toBe(true);
  });
});

describe("a session that ended", () => {
  it("returns to the sign-in screen when the server stops honouring the token", async () => {
    await bootShell();
    document.dispatchEvent(new CustomEvent("aquarium-auth-expired"));
    await settle();
    expect(shown("login-root")).toBe(true);
    expect(toasts()).toContain("Your session expired — please sign in again");
  });

  it("stops at the sign-in screen when the server answers as a different one, once", async () => {
    await bootShell();
    document.dispatchEvent(new CustomEvent("aquarium-server-identity", { detail: { message: "This is not Reef" } }));
    await settle();
    expect(shown("login-root")).toBe(true);
    expect(toasts()).toEqual(["This is not Reef"]);
    document.dispatchEvent(new CustomEvent("aquarium-server-identity", { detail: {} }));
    await settle();
    expect(toasts()).toEqual(["This is not Reef"]);
  });

  it("has a message of its own when the backend gave none", async () => {
    await bootShell();
    document.dispatchEvent(new CustomEvent("aquarium-server-identity"));
    await settle();
    expect(toasts()).toEqual(["This address is not the server you signed in to — check it and sign in again"]);
  });
});

describe("search", () => {
  function type(text: string): HTMLInputElement {
    const input = $("search-input") as HTMLInputElement;
    input.value = text;
    input.dispatchEvent(new Event("input"));
    return input;
  }

  it("searches once typing pauses, rewriting the hash in place so Back is one press", async () => {
    const shell = await bootShell();
    await shell.go("#/lib/lib-movies");
    fakeTimers();
    type("he");
    await vi.advanceTimersByTimeAsync(319);
    expect(location.hash).toBe("#/lib/lib-movies");
    type("hea");
    await vi.advanceTimersByTimeAsync(320);
    expect(location.hash).toBe("#/search/hea");
    // jsdom delivers hashchange as a task of its own.
    await vi.advanceTimersByTimeAsync(10);
    expect(page()).toBe("search:hea");
    type("heat");
    await vi.advanceTimersByTimeAsync(330);
    vi.useRealTimers();
    await settle();
    expect(location.hash).toBe("#/search/heat");
    expect(page()).toBe("search:heat");
    click($("back-btn"));
    await settle();
    expect(location.hash).toBe("#/lib/lib-movies");
  });

  it("Enter searches now and remembers the term; an empty Enter does nothing", async () => {
    await bootShell();
    const input = type("  heat ");
    key("Enter", {}, input);
    await settle();
    expect(location.hash).toBe("#/search/heat");
    expect(JSON.parse(localStorage.getItem("aquarium.recent-searches")!)).toEqual(["heat"]);
    // The same search again is not a navigation.
    key("Enter", {}, input);
    await settle();
    type("");
    key("Enter", {}, input);
    await settle();
    expect(location.hash).toBe("#/search/heat");
    expect(JSON.parse(localStorage.getItem("aquarium.recent-searches")!)).toEqual(["heat"]);
  });

  it("offers recent searches on focus of an empty box, and picking one searches it", async () => {
    localStorage.setItem("aquarium.recent-searches", JSON.stringify(["heat", "ronin"]));
    await bootShell();
    const input = $("search-input") as HTMLInputElement;
    const panel = $("search-recent");
    input.dispatchEvent(new Event("focus"));
    expect(panel.hasAttribute("hidden")).toBe(false);
    expect([...panel.querySelectorAll(".sr-item")].map((b) => b.textContent)).toEqual(["heat", "ronin"]);
    click([...panel.querySelectorAll(".sr-item")][1]!);
    await settle();
    expect(input.value).toBe("ronin");
    expect(panel.hasAttribute("hidden")).toBe(true);
    expect(location.hash).toBe("#/search/ronin");
    expect(JSON.parse(localStorage.getItem("aquarium.recent-searches")!)).toEqual(["ronin", "heat"]);
  });

  it("shows the recent list again when the box is emptied, and not over a typed term or with no history", async () => {
    await bootShell();
    const input = $("search-input") as HTMLInputElement;
    input.dispatchEvent(new Event("focus"));
    expect($("search-recent").hasAttribute("hidden")).toBe(true);
    localStorage.setItem("aquarium.recent-searches", JSON.stringify(["heat"]));
    type("x");
    input.dispatchEvent(new Event("focus"));
    expect($("search-recent").hasAttribute("hidden")).toBe(true);
    type("");
    expect($("search-recent").hasAttribute("hidden")).toBe(false);
  });

  it("clears the recent list by click or from the keyboard (regression: a963a95 the Clear link was mouse-only)", async () => {
    localStorage.setItem("aquarium.recent-searches", JSON.stringify(["heat"]));
    await bootShell();
    const input = $("search-input") as HTMLInputElement;
    input.dispatchEvent(new Event("focus"));
    const clearLink = $("search-recent").querySelector<HTMLElement>(".sr-clear")!;
    expect(clearLink.getAttribute("role")).toBe("button");
    expect(clearLink.getAttribute("tabindex")).toBe("0");
    key("Enter", {}, clearLink);
    expect(localStorage.getItem("aquarium.recent-searches")).toBeNull();
    expect($("search-recent").hasAttribute("hidden")).toBe(true);

    localStorage.setItem("aquarium.recent-searches", JSON.stringify(["heat"]));
    input.dispatchEvent(new Event("focus"));
    click($("search-recent").querySelector(".sr-clear")!);
    expect(localStorage.getItem("aquarium.recent-searches")).toBeNull();
  });

  it("Escape and a click elsewhere put the list away", async () => {
    localStorage.setItem("aquarium.recent-searches", JSON.stringify(["heat"]));
    await bootShell();
    const input = $("search-input") as HTMLInputElement;
    input.focus();
    input.dispatchEvent(new Event("focus"));
    key("Escape", {}, input);
    expect($("search-recent").hasAttribute("hidden")).toBe(true);
    expect(document.activeElement).not.toBe(input);
    input.dispatchEvent(new Event("focus"));
    click(input);
    expect($("search-recent").hasAttribute("hidden")).toBe(false);
    click($("search-recent"));
    expect($("search-recent").hasAttribute("hidden")).toBe(false);
    click($("content"));
    expect($("search-recent").hasAttribute("hidden")).toBe(true);
    // Other keys in the box are typing.
    key("a", {}, input);
  });

  it("/ focuses search from anywhere, but not while typing or with a modifier", async () => {
    await bootShell();
    const input = $("search-input") as HTMLInputElement;
    const other = document.createElement("textarea");
    document.body.append(other);
    other.focus();
    expect(key("/", {}, other).defaultPrevented).toBe(false);
    expect(key("/", { ctrlKey: true }).defaultPrevented).toBe(false);
    expect(key("/", { altKey: true }).defaultPrevented).toBe(false);
    expect(key("/", { metaKey: true }).defaultPrevented).toBe(false);
    const ev = key("/");
    expect(ev.defaultPrevented).toBe(true);
    expect(document.activeElement).toBe(input);
    // Something contenteditable is typing too.
    const editable = document.createElement("div");
    editable.contentEditable = "true";
    Object.defineProperty(editable, "isContentEditable", { value: true });
    document.body.append(editable);
    expect(key("/", {}, editable).defaultPrevented).toBe(false);
  });
});

describe("the shortcut sheet", () => {
  it("? opens and closes it, and Escape dismisses it", async () => {
    await bootShell();
    expect(key("?").defaultPrevented).toBe(true);
    const dialog = document.querySelector(".dialog")!;
    expect(dialog.querySelector("h2")!.textContent).toBe("Keyboard shortcuts");
    expect([...dialog.querySelectorAll("h4")].map((h) => h.textContent)).toEqual(["Anywhere", "Playback", "On the picture", "Browsing"]);
    expect(dialog.querySelector(".shortcut-row kbd")!.textContent).toBe("/");
    key("?");
    expect(document.querySelector(".dialog")).toBeNull();
    key("?");
    key("Escape");
    expect(document.querySelector(".dialog")).toBeNull();
  });

  // BUG: the sheet's Close button closes the dialog without running its
  // onDismiss (src/ui.ts openDialog runs onDismiss only for Escape and the
  // scrim), and toggleShortcuts (src/main.ts:2686) keeps `shortcutsOpen` set,
  // so the next "?" only clears that stale closer and opens nothing: the
  // sheet takes two presses to come back after Close.
  it.fails("opens again on the first ? after being closed with its Close button", async () => {
    await bootShell();
    key("?");
    click([...document.querySelectorAll<HTMLButtonElement>(".dialog button")].find((b) => b.textContent === "Close")!);
    expect(document.querySelector(".dialog")).toBeNull();
    key("?");
    expect(document.querySelector(".dialog")).not.toBeNull();
  });

  it("is not opened while typing, or with Ctrl", async () => {
    await bootShell();
    const field = document.createElement("input");
    document.body.append(field);
    key("?", {}, field);
    key("?", { ctrlKey: true });
    expect(document.querySelector(".dialog")).toBeNull();
  });
});

describe("arrow keys between tiles", () => {
  function tiles(): [HTMLElement, HTMLElement] {
    const mk = (left: number): HTMLElement => {
      const card = document.createElement("div");
      card.className = "card";
      card.tabIndex = 0;
      card.getBoundingClientRect = () =>
        ({ left, top: 0, width: 100, height: 150, right: left + 100, bottom: 150, x: left, y: 0, toJSON() {} }) as DOMRect;
      return card;
    };
    const a = mk(0);
    const b = mk(120);
    $("content").append(a, b);
    a.focus();
    return [a, b];
  }

  it("move focus between cards while browsing", async () => {
    await bootShell();
    const [, b] = tiles();
    expect(key("ArrowRight", {}, document.activeElement!).defaultPrevented).toBe(true);
    expect(document.activeElement).toBe(b);
  });

  it("belong to the player, an open menu or a dialog instead", async () => {
    const shell = await startPlaying();
    const [a] = tiles();
    key("ArrowRight", {}, a);
    expect(document.activeElement).toBe(a);
    shell.stop();
    await settle();
    const menu = document.createElement("div");
    menu.className = "menu";
    document.body.append(menu);
    key("ArrowRight", {}, a);
    expect(document.activeElement).toBe(a);
    menu.remove();
    const scrim = document.createElement("div");
    scrim.className = "dialog-scrim";
    document.body.append(scrim);
    key("ArrowRight", {}, a);
    expect(document.activeElement).toBe(a);
  });
});

describe("signing in from the shell's sign-in screen", () => {
  // Dummy values for the mock bridge only.
  const LOGIN = { server: "https://jf.test", user_id: "u9", user_name: "ada", device_id: "device-1", secure: true };

  async function signInThrough(root: HTMLElement): Promise<void> {
    const q = <T extends HTMLElement>(sel: string) => root.querySelector<T>(sel)!;
    q<HTMLInputElement>('input[placeholder="jellyfin.example.com"]').value = "jf.test";
    q<HTMLButtonElement>('button[type="submit"]').click();
    await settle();
    const user = q<HTMLInputElement>('input[placeholder="Username"]');
    user.value = "ada";
    user.dispatchEvent(new Event("input", { bubbles: true }));
    q<HTMLInputElement>('input[type="password"]').value = "pw";
    q<HTMLButtonElement>('button[type="submit"]').click();
    await settle(12);
  }

  const probe = { server: "https://jf.test", server_name: "Reef", version: "10.10.3", secure: true };

  it("opens the shell on a first sign-in", async () => {
    const shell = await bootShell({
      signedIn: false,
      invokes: {
        jf_probe: probe,
        jf_public: { status: 404, body: null },
        jf_login: () => {
          Object.assign(shell.cfg, { server: LOGIN.server, has_token: true, user_id: "u9", user_name: "ada" });
          return LOGIN;
        },
      },
    });
    await signInThrough($("login-root"));
    expect(shown("shell")).toBe(true);
    expect($("topbar-user").textContent).toContain("ada");
    expect(page()).toBe("home");
  });

  it("Add Account signs the new account in and makes it the one in use", async () => {
    const shell = await bootShell({
      invokes: {
        jf_probe: probe,
        jf_public: { status: 404, body: null },
        jf_login: () => {
          Object.assign(shell.cfg, { server: LOGIN.server, user_id: "u9", user_name: "ada" });
          return LOGIN;
        },
      },
    });
    await shell.go("#/settings");
    document.dispatchEvent(new CustomEvent("aquarium-add-account"));
    await settle();
    await signInThrough($("login-root"));
    expect(shown("shell")).toBe(true);
    expect(toasts()).toContain("Signed in as ada");
    expect(location.hash).toBe("#/home");
  });
});
