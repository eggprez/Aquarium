// src/main.ts: boot, the hash router, the back trail, scroll memory and the
// last-route restore. The page renderers are recording stand-ins here (see
// helpers/main-shell.ts), so what is asserted is the shell's own behaviour.
import { afterEach, describe, expect, it, vi } from "vitest";
import { emitEvent, invokeCalls, listen, listenerCount, onInvoke } from "../helpers/tauri";
import { bootShell, click, hidden, key, page, settle, teardownShell, toasts } from "../helpers/main-shell";

afterEach(teardownShell);

const $ = (id: string): HTMLElement => document.getElementById(id)!;
const shown = (id: string): boolean => !$(id).classList.contains("hidden");

describe("boot", () => {
  it("shows the sign-in screen when nothing is saved, and never probes a server", async () => {
    await bootShell({ signedIn: false });
    expect(shown("login-root")).toBe(true);
    expect(shown("shell")).toBe(false);
    expect($("login-root").textContent).toContain("Connect to Jellyfin");
    expect(invokeCalls("jf_ping")).toHaveLength(0);
    expect(invokeCalls("jf_request")).toHaveLength(0);
  });

  it("opens the shell on Home for a saved session", async () => {
    const shell = await bootShell();
    expect(shown("shell")).toBe(true);
    expect(shown("login-root")).toBe(false);
    expect(page()).toBe("home");
    expect(shell.views.home).toHaveBeenCalledTimes(1);
    expect(invokeCalls("jf_ping")).toHaveLength(1);
    // The player bar is built, and stays out of sight until something plays.
    expect($("player-bar").classList.contains("hidden")).toBe(true);
    expect(document.getElementById("pb-playpause")).not.toBeNull();
    expect($("offline-pill").hasAttribute("hidden")).toBe(true);
  });

  it("writes the signed-in user's name and initial in the top bar", async () => {
    await bootShell({ config: { user_name: "scott" } });
    expect($("topbar-user").querySelector("span")!.textContent).toBe("scott");
    expect($("topbar-user").querySelector(".avatar")!.textContent).toBe("S");
  });

  it("starts the music player, the offline-progress sync and the download queue once the shell is up", async () => {
    const shell = await bootShell({ pending: 2 });
    expect(shell.views.musicPlayer).toHaveBeenCalledTimes(1);
    await settle();
    // syncOfflineProgress(false): two items waiting, so they are pushed.
    expect(invokeCalls("progress_sync")).toHaveLength(1);
  });

  it("still reaches the sign-in screen when the config cannot be read", async () => {
    const err = vi.spyOn(console, "error").mockImplementation(() => {});
    await bootShell({ signedIn: false, invokes: { config_load: () => Promise.reject(new Error("disk")) } });
    expect(shown("login-root")).toBe(true);
    expect(err).toHaveBeenCalledWith("config load failed:", expect.any(Error));
    err.mockRestore();
  });

  it("carries on booting when the player bridge or adaptive quality cannot register", async () => {
    const err = vi.spyOn(console, "error").mockImplementation(() => {});
    const real = listen.getMockImplementation()!;
    // playback.ts registers player-tracks, adaptive.ts registers player-stall
    // first: fail each of those once.
    const failed = new Set<string>();
    listen.mockImplementation(async (event: string, cb: any) => {
      if ((event === "player-tracks" || event === "player-stall") && !failed.has(event)) {
        failed.add(event);
        throw new Error(`cannot listen to ${event}`);
      }
      return real(event, cb);
    });
    try {
      await bootShell();
    } finally {
      listen.mockImplementation(real);
    }
    expect(err).toHaveBeenCalledWith("player bridge failed:", expect.any(Error));
    expect(err).toHaveBeenCalledWith("adaptive quality failed:", expect.any(Error));
    expect(shown("shell")).toBe(true);
    expect(page()).toBe("home");
    err.mockRestore();
  });

  it("listens for every backend event the shell reacts to", async () => {
    await bootShell();
    for (const ev of [
      "player-status",
      "player-stall",
      "player-pip",
      "player-mouse",
      "player-message",
      "quit-requested",
      "network-changed",
      "progress-queue-changed",
      "download-progress",
      "mpris-next",
    ]) {
      expect(listenerCount(ev), ev).toBeGreaterThan(0);
    }
  });

  it("marks the body idle while the window is hidden", async () => {
    await bootShell();
    hidden(true);
    document.dispatchEvent(new Event("visibilitychange"));
    expect(document.body.classList.contains("bg-idle")).toBe(true);
    hidden(false);
    document.dispatchEvent(new Event("visibilitychange"));
    expect(document.body.classList.contains("bg-idle")).toBe(false);
  });
});

describe("route restore on launch", () => {
  it("reopens the page the last session left off on", async () => {
    localStorage.setItem("aquarium.last-route", "#/settings");
    const shell = await bootShell();
    expect(location.hash).toBe("#/settings");
    expect(page()).toBe("settings");
    expect(shell.views.home).not.toHaveBeenCalled();
  });

  it("restores a library with its id", async () => {
    localStorage.setItem("aquarium.last-route", "#/lib/lib-shows");
    await bootShell();
    expect(page()).toBe("library:lib-shows");
  });

  it("lets a hash already in the URL win over the remembered route", async () => {
    localStorage.setItem("aquarium.last-route", "#/settings");
    await bootShell({ hash: "#/favorites" });
    expect(location.hash).toBe("#/favorites");
    expect(page()).toBe("favorites");
  });

  it("ignores a remembered value that is not a route", async () => {
    localStorage.setItem("aquarium.last-route", "javascript:alert(1)");
    await bootShell();
    expect(location.hash).toBe("");
    expect(page()).toBe("home");
  });

  it("opens on Home when storage cannot be read", async () => {
    const get = vi.spyOn(Storage.prototype, "getItem").mockImplementation((k: string) => {
      if (k === "aquarium.last-route") throw new Error("denied");
      return null;
    });
    try {
      await bootShell();
      expect(page()).toBe("home");
    } finally {
      get.mockRestore();
    }
  });

  it("remembers resumable pages as they are visited, and nothing else", async () => {
    const shell = await bootShell();
    await shell.go("#/lib/lib-movies");
    expect(localStorage.getItem("aquarium.last-route")).toBe("#/lib/lib-movies");
    // A detail page may have been deleted by next launch; a search is stale.
    await shell.go("#/item/abc");
    expect(localStorage.getItem("aquarium.last-route")).toBe("#/lib/lib-movies");
    await shell.go("#/search/heat");
    expect(localStorage.getItem("aquarium.last-route")).toBe("#/lib/lib-movies");
    await shell.go("#/music/library");
    expect(localStorage.getItem("aquarium.last-route")).toBe("#/lib/lib-movies");
    for (const r of ["#/favorites", "#/livetv", "#/downloads", "#/settings", "#/home"]) {
      await shell.go(r);
      expect(localStorage.getItem("aquarium.last-route")).toBe(r);
    }
  });

  it("keeps navigating when the route cannot be stored", async () => {
    const shell = await bootShell();
    const set = vi.spyOn(Storage.prototype, "setItem").mockImplementation(() => {
      throw new Error("quota");
    });
    try {
      await shell.go("#/settings");
      expect(page()).toBe("settings");
    } finally {
      set.mockRestore();
    }
  });

  it("lands on Downloads, not a dead Home, when the server is unreachable at launch", async () => {
    await bootShell({ ping: false });
    expect(location.hash).toBe("#/downloads");
    expect(page()).toBe("downloads");
    expect($("offline-pill").hasAttribute("hidden")).toBe(false);
  });

  it("goes to Downloads from an explicit #/home too while offline", async () => {
    await bootShell({ ping: false, hash: "#/home" });
    await settle();
    expect(location.hash).toBe("#/downloads");
    expect(page()).toBe("downloads");
  });

  it("keeps a remembered server page while offline, drawn as the offline screen", async () => {
    localStorage.setItem("aquarium.last-route", "#/lib/lib-movies");
    const shell = await bootShell({ ping: false });
    expect(location.hash).toBe("#/lib/lib-movies");
    expect($("content").querySelector(".offline-screen h1")!.textContent).toBe("Server offline");
    expect(shell.views.library).not.toHaveBeenCalled();
  });
});

describe("router", () => {
  it("hands each route to its page with the rest of the hash as the argument", async () => {
    const shell = await bootShell();
    const cases: Array<[string, string]> = [
      ["#/lib/lib-movies", "library:lib-movies"],
      ["#/item/abc123", "item:abc123"],
      ["#/favorites", "favorites"],
      ["#/livetv", "livetv"],
      ["#/downloads", "downloads"],
      ["#/settings", "settings"],
      ["#/search/two%20words", "search:two words"],
      ["#/music/library/albums", "music:library/albums"],
      ["#/books/series/9", "books:series/9"],
      ["#/home", "home"],
    ];
    for (const [hash, want] of cases) {
      await shell.go(hash);
      expect(page(), hash).toBe(want);
    }
    expect(shell.views.item).toHaveBeenCalledWith($("content"), "abc123");
  });

  it("draws Home for a route it does not know", async () => {
    const shell = await bootShell();
    await shell.go("#/settings");
    await shell.go("#/nonsense/1");
    expect(page()).toBe("home");
  });

  it("gives Settings the way back to the sign-in screen", async () => {
    const shell = await bootShell();
    await shell.go("#/settings");
    const onLogout = shell.views.settings.mock.calls[0]![1] as () => void;
    onLogout();
    expect(shown("login-root")).toBe(true);
    expect(shown("shell")).toBe(false);
  });

  it("shows an error with Try again when a page throws, and Try again re-renders it", async () => {
    const shell = await bootShell();
    shell.views.favorites.mockRejectedValueOnce(new Error("Server error 500 on /Items"));
    await shell.go("#/favorites");
    const content = $("content");
    expect(content.textContent).toContain("This page didn't load");
    expect(content.textContent).toContain("Server error 500 on /Items");
    click([...content.querySelectorAll("button")].find((b) => b.textContent === "Try again")!);
    await settle();
    expect(page()).toBe("favorites");
    expect(shell.views.favorites).toHaveBeenCalledTimes(2);
  });

  it("restarts the page-in animation class on every route", async () => {
    const shell = await bootShell();
    expect($("content").classList.contains("view-in")).toBe(true);
    $("content").classList.remove("view-in");
    await shell.go("#/settings");
    expect($("content").classList.contains("view-in")).toBe(true);
  });

  it("closes any open menu when the route changes", async () => {
    const shell = await bootShell();
    const menu = document.createElement("div");
    menu.className = "menu";
    document.body.append(menu);
    await shell.go("#/settings");
    expect(document.querySelector(".menu")).toBeNull();
  });

  it("redraws Home when Next Up changed on the server, but not another page and not under a playing video", async () => {
    const shell = await bootShell();
    document.dispatchEvent(new CustomEvent("aquarium-next-up-changed"));
    await settle();
    expect(shell.views.home).toHaveBeenCalledTimes(2);

    await shell.go("#/settings");
    document.dispatchEvent(new CustomEvent("aquarium-next-up-changed"));
    await settle();
    expect(shell.views.home).toHaveBeenCalledTimes(2);
    expect(shell.views.settings).toHaveBeenCalledTimes(1);

    await shell.go("#/home");
    expect(shell.views.home).toHaveBeenCalledTimes(3);
    shell.status();
    document.dispatchEvent(new CustomEvent("aquarium-next-up-changed"));
    await settle();
    expect(shell.views.home).toHaveBeenCalledTimes(3);
  });
});

describe("offline pages", () => {
  it("replaces every page that needs the server with the offline screen", async () => {
    const shell = await bootShell({ ping: false });
    for (const hash of ["#/home", "#/lib/x", "#/item/y", "#/livetv", "#/search/q", "#/favorites", "#/music/library", "#/books"]) {
      await shell.go(hash);
      expect($("content").querySelector(".offline-screen"), hash).not.toBeNull();
    }
    for (const v of ["home", "library", "item", "livetv", "search", "favorites", "music", "books"] as const) {
      expect(shell.views[v], v).not.toHaveBeenCalled();
    }
  });

  it("still opens Downloads, Settings and downloaded music with no server", async () => {
    const shell = await bootShell({ ping: false });
    await shell.go("#/settings");
    expect(page()).toBe("settings");
    await shell.go("#/music/downloaded");
    expect(page()).toBe("music:downloaded");
    await shell.go("#/downloads");
    expect(page()).toBe("downloads");
  });

  it("offers Downloads from the offline screen", async () => {
    const shell = await bootShell({ ping: false });
    await shell.go("#/favorites");
    click([...$("content").querySelectorAll("button")].find((b) => b.textContent === "Go to Downloads")!);
    await settle();
    expect(location.hash).toBe("#/downloads");
    expect(page()).toBe("downloads");
  });

  it("Retry connection says so when the server is still away, and draws the page when it is back", async () => {
    let up = false;
    const shell = await bootShell({ ping: () => up });
    await shell.go("#/favorites");
    const retry = [...$("content").querySelectorAll("button")].find((b) => b.textContent === "Retry connection") as HTMLButtonElement;
    click(retry);
    expect(retry.disabled).toBe(true);
    expect(retry.textContent).toBe("Checking…");
    await settle();
    expect(retry.disabled).toBe(false);
    expect(retry.textContent).toBe("Retry connection");
    expect(toasts()).toContain("Still offline — server unreachable");
    expect(shell.views.favorites).not.toHaveBeenCalled();

    up = true;
    click(retry);
    await settle();
    expect(page()).toBe("favorites");
    expect(toasts()).toContain("Back online");
  });
});

describe("back trail", () => {
  it("shows Back once there is somewhere to go back to, and walks the trail", async () => {
    const shell = await bootShell();
    const back = $("back-btn");
    expect(back.hasAttribute("hidden")).toBe(true);

    await shell.go("#/lib/lib-movies");
    expect(back.hasAttribute("hidden")).toBe(false);
    await shell.go("#/item/abc");

    click(back);
    await settle();
    expect(location.hash).toBe("#/lib/lib-movies");
    expect(page()).toBe("library:lib-movies");
    expect(back.hasAttribute("hidden")).toBe(false);

    click(back);
    await settle();
    expect(location.hash).toBe("#/home");
    expect(page()).toBe("home");
    expect(back.hasAttribute("hidden")).toBe(true);
  });

  it("does not push the page a Back came from", async () => {
    const shell = await bootShell();
    await shell.go("#/lib/lib-movies");
    await shell.go("#/item/abc");
    click($("back-btn"));
    await settle();
    // One more Back reaches Home; a re-pushed #/item/abc would go there instead.
    click($("back-btn"));
    await settle();
    expect(location.hash).toBe("#/home");
  });

  it("ends the trail at Home: arriving there leaves no Back", async () => {
    const shell = await bootShell();
    await shell.go("#/lib/lib-movies");
    await shell.go("#/item/abc");
    await shell.go("#/home");
    expect($("back-btn").hasAttribute("hidden")).toBe(true);
    // And Back with an empty trail goes nowhere.
    click($("back-btn"));
    await settle();
    expect(location.hash).toBe("#/home");
  });

  it("goes back on Alt+Left and on the mouse's back button", async () => {
    const shell = await bootShell();
    await shell.go("#/lib/lib-movies");
    await shell.go("#/item/abc");
    const ev = key("ArrowLeft", { altKey: true });
    expect(ev.defaultPrevented).toBe(true);
    await settle();
    expect(location.hash).toBe("#/lib/lib-movies");

    await shell.go("#/item/def");
    const up = new MouseEvent("mouseup", { button: 3, bubbles: true, cancelable: true });
    window.dispatchEvent(up);
    expect(up.defaultPrevented).toBe(true);
    await settle();
    expect(location.hash).toBe("#/lib/lib-movies");

    // Any other button is not a navigation.
    window.dispatchEvent(new MouseEvent("mouseup", { button: 0, bubbles: true }));
    await settle();
    expect(location.hash).toBe("#/lib/lib-movies");
  });

  it("leaves other Alt combinations alone", async () => {
    const shell = await bootShell();
    await shell.go("#/lib/lib-movies");
    const ev = key("ArrowRight", { altKey: true });
    await settle();
    expect(ev.defaultPrevented).toBe(false);
    expect(location.hash).toBe("#/lib/lib-movies");
  });
});

describe("scroll memory", () => {
  it("returns to where a page was scrolled on Back, and starts a picked route at the top", async () => {
    const shell = await bootShell();
    const content = $("content");
    await shell.go("#/lib/lib-movies");
    content.scrollTop = 300;
    content.dispatchEvent(new Event("scroll"));
    expect($("topbar").classList.contains("scrolled")).toBe(true);

    await shell.go("#/item/abc");
    expect(content.scrollTop).toBe(0);
    expect($("topbar").classList.contains("scrolled")).toBe(false);

    click($("back-btn"));
    await settle();
    expect(content.scrollTop).toBe(300);
    expect($("topbar").classList.contains("scrolled")).toBe(true);

    // Picking the same library again is a fresh visit.
    await shell.go("#/item/abc");
    await shell.go("#/lib/lib-movies");
    expect(content.scrollTop).toBe(0);
  });

  it("frosts the top bar only once the page has scrolled under it", async () => {
    await bootShell();
    const content = $("content");
    content.scrollTop = 4;
    content.dispatchEvent(new Event("scroll"));
    expect($("topbar").classList.contains("scrolled")).toBe(false);
    content.scrollTop = 5;
    content.dispatchEvent(new Event("scroll"));
    expect($("topbar").classList.contains("scrolled")).toBe(true);
  });

  it("leaves the content's own scroll behaviour as it found it after landing", async () => {
    const shell = await bootShell();
    $("content").style.scrollBehavior = "smooth";
    await shell.go("#/settings");
    expect($("content").style.scrollBehavior).toBe("smooth");
  });
});

describe("events that reach the page renderers", () => {
  it("passes download progress to the Downloads view", async () => {
    const shell = await bootShell();
    const payload = { item_id: "x", state: "downloading", received: 10, total: 100 };
    emitEvent("download-progress", payload);
    expect(shell.views.downloadProgress).toHaveBeenCalledWith(payload, $("content"));
  });

  it("answers an unmocked command without breaking the shell", async () => {
    onInvoke("app_info", () => Promise.reject(new Error("no backend")));
    await bootShell({ invokes: { app_info: () => Promise.reject(new Error("no backend")) } });
    await settle();
    // The footer still draws, with no version.
    expect($("sidebar-footer").querySelector(".foot-version")!.textContent).toBe("Aquarium");
  });
});
