// src/main.ts: the shell around the pages — the sidebar, the account control
// at its foot and the menu behind it, going offline and probing for the server's return, accounts, an expired
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

/** The account control at the foot of the sidebar. */
function account(): { name: string; server: string; initial: string } {
  const btn = $("account-btn");
  return {
    name: btn.querySelector(".account-name")!.textContent ?? "",
    server: btn.querySelector(".account-server")!.textContent ?? "",
    initial: btn.querySelector(".avatar")!.textContent ?? "",
  };
}

/** Open the account menu and return its entries' labels. */
async function accountMenu(): Promise<string[]> {
  click($("account-btn"));
  await settle();
  return [...document.querySelectorAll(".account-menu > *")].map((n) =>
    n.classList.contains("menu-rule") ? "—" : n.classList.contains("menu-label") ? `[${n.textContent}]` : n.textContent ?? ""
  );
}

function menuItem(label: string): HTMLElement {
  const hit = [...document.querySelectorAll<HTMLElement>('.account-menu [role="menuitem"]')].find((b) => b.textContent === label);
  if (!hit) throw new Error(`no menu item "${label}"`);
  return hit;
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
  it("groups Home, the libraries with collections, music and books among them, Live, then what is yours", async () => {
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
      // regression: 56a1825 — Jellyfin's box sets get an entry of their own.
      "Collections #/lib/bs",
      "Listen Now #/music/discover",
      "Library #/music/library",
      "Audiobooks #/books",
      "— Live",
      "Live TV #/livetv",
      "— You",
      "Favorites #/favorites",
      "Downloads #/downloads",
    ]);
    // Settings is reached from the account control, not from a row.
    expect($("nav").querySelector('[data-route="#/settings"]')).toBeNull();
  });

  it("puts audiobooks among the libraries without music, and gives Live TV to a custom playlist", async () => {
    await bootShell({ libraries: [{ Id: "b", Name: "Books", CollectionType: "books" }], config: { livetv_source: "custom" } });
    expect(navEntries()).toEqual([
      "Home #/home",
      "— Libraries",
      "Audiobooks #/books",
      "— Live",
      "Live TV #/livetv",
      "— You",
      "Favorites #/favorites",
      "Downloads #/downloads",
    ]);
  });

  it("names each row in a tooltip, with its Ctrl+number for the first nine", async () => {
    await bootShell({
      libraries: ["a", "b", "c", "d", "e", "f", "g"].map((id) => ({ Id: id, Name: `Lib ${id}`, CollectionType: "movies" })),
    });
    const tips = [...$("nav").querySelectorAll(".nav-item")].map((n) => n.getAttribute("title"));
    expect(tips).toEqual([
      "Home (Ctrl+1)",
      "Lib a (Ctrl+2)",
      "Lib b (Ctrl+3)",
      "Lib c (Ctrl+4)",
      "Lib d (Ctrl+5)",
      "Lib e (Ctrl+6)",
      "Lib f (Ctrl+7)",
      "Lib g (Ctrl+8)",
      "Favorites (Ctrl+9)",
      "Downloads",
    ]);
  });

  it("adds the Seerr page under You only while a Seerr server is connected", async () => {
    await bootShell({ invokes: { seerr_status: { connected: true, host: "seerr.test", user_name: "tester" } } });
    await settle();
    expect(navEntries()).toEqual([
      "Home #/home",
      "— Libraries",
      "Films #/lib/lib-movies",
      "Shows #/lib/lib-shows",
      "— You",
      "Favorites #/favorites",
      "Seerr #/requests",
      "Downloads #/downloads",
    ]);
    teardownShell();
    // A connection whose session has run out shows nothing until it is renewed.
    await bootShell({ invokes: { seerr_status: { connected: true, needs_reconnect: true } } });
    await settle();
    expect(navEntries()).not.toContain("Seerr #/requests");
  });

  it("draws only what needs no server when the library list cannot be had", async () => {
    await bootShell({
      libraries: () => {
        throw new Error("500");
      },
    });
    expect(navEntries()).toEqual(["Home #/home", "— You", "Favorites #/favorites", "Downloads #/downloads"]);
  });

  it("keeps Favorites and Downloads when Seerr connects with no library list (regression: the sidebar fell back to Home alone)", async () => {
    await bootShell({
      libraries: () => {
        throw new Error("500");
      },
    });
    await settle();
    expect(navEntries()).toEqual(["Home #/home", "— You", "Favorites #/favorites", "Downloads #/downloads"]);
    // The Seerr answer arrives after the sidebar was drawn from no list.
    const seerr = await import("../../src/seerr");
    onInvoke("seerr_status", { connected: true, host: "seerr.test", user_name: "tester" });
    await seerr.loadStatus();
    await settle();
    expect(navEntries()).toEqual([
      "Home #/home",
      "— You",
      "Favorites #/favorites",
      "Seerr #/requests",
      "Downloads #/downloads",
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
    await shell.go("#/lib/lib-movies/genre/x");
    expect(films.classList.contains("active")).toBe(true);
    expect(films.getAttribute("aria-current")).toBe("page");
    // Settings has no row: the account control takes the selected fill instead.
    expect($("account-btn").classList.contains("active")).toBe(false);
    await shell.go("#/settings");
    expect($("nav").querySelector(".nav-item.active")).toBeNull();
    expect($("nav").querySelector("[aria-current]")).toBeNull();
    expect($("account-btn").classList.contains("active")).toBe(true);
    await shell.go("#/settings/video");
    expect($("account-btn").classList.contains("active")).toBe(true);
    await shell.go("#/home");
    expect($("account-btn").classList.contains("active")).toBe(false);
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

describe("account control", () => {
  it("names who is signed in and to which server, with their initial", async () => {
    await bootShell({ config: { user_name: "scott" } });
    expect(account()).toEqual({ name: "scott", server: "jf.test:8096", initial: "S" });
    expect($("account-btn").getAttribute("aria-haspopup")).toBe("menu");
  });

  it("opens a menu of Add Account, Settings and Sign Out, and a second click closes it", async () => {
    await bootShell();
    expect(await accountMenu()).toEqual(["Add Account…", "—", "Settings…", "—", "Sign Out…"]);
    expect(menuItem("Sign Out…").classList.contains("danger")).toBe(true);
    // The menu's own outside-click handler closes it on the way down; the
    // click that follows must not open it again.
    $("account-btn").dispatchEvent(new Event("pointerdown", { bubbles: true }));
    document.dispatchEvent(new MouseEvent("mousedown", { bubbles: true }));
    click($("account-btn"));
    await settle();
    expect(document.querySelector(".account-menu")).toBeNull();
  });

  it("Settings… opens Settings, and Sign Out… its Account pane, where signing out is confirmed", async () => {
    const shell = await bootShell();
    await accountMenu();
    click(menuItem("Settings…"));
    await settle();
    expect(document.querySelector(".account-menu")).toBeNull();
    expect(location.hash).toBe("#/settings");
    expect(page()).toBe("settings");
    await accountMenu();
    click(menuItem("Sign Out…"));
    await settle();
    expect(location.hash).toBe("#/settings/account");
    expect(shell.views.settings).toHaveBeenCalledTimes(2);
    // Nothing is signed out from the menu itself.
    expect(invokeCalls("jf_logout")).toHaveLength(0);
  });

  it("lists the other saved accounts to switch to, and Add Account opens the sign-in screen", async () => {
    const shell = await bootShell({
      invokes: {
        accounts_list: [
          { key: "k1", server: "http://jf.test:8096", user_name: "tester", current: true },
          { key: "k2", server: "https://other.test", user_name: "second", current: false },
        ],
        account_switch: () => {
          shell.cfg.user_name = "second";
          return null;
        },
      },
    });
    expect(await accountMenu()).toEqual(["[Switch Account]", "second — other.test", "Add Account…", "—", "Settings…", "—", "Sign Out…"]);
    click(menuItem("second — other.test"));
    await settle();
    expect(invokeCalls("account_switch")[0]!.args).toEqual({ key: "k2" });
    expect(account().name).toBe("second");
    await accountMenu();
    click(menuItem("Add Account…"));
    await settle();
    expect(shown("login-root")).toBe(true);
    expect(shown("shell")).toBe(false);
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

  it("says so, shows the strip above the page, and redraws the page as the offline screen", async () => {
    const { shell } = await onlineThenOff();
    expect(toasts()).toContain("Server unreachable — offline mode. Downloads still work.");
    expect($("offline-strip").hasAttribute("hidden")).toBe(false);
    expect($("offline-status").textContent).toBe("Your server can't be reached");
    expect(($("offline-retry") as HTMLButtonElement).disabled).toBe(false);
    expect($("offline-retry").textContent).toBe("Retry");
    expect($("content").querySelector(".offline-screen")).not.toBeNull();
    void shell;
  });

  it("reduces the sidebar to what works with no server, and puts the rest back on return", async () => {
    let up = true;
    const shell = await bootShell({
      ping: () => up,
      libraries: [
        { Id: "m", Name: "Films", CollectionType: "movies" },
        { Id: "mu", Name: "Music", CollectionType: "music" },
        { Id: "b", Name: "Books", CollectionType: "audiobooks" },
        { Id: "l", Name: "Live", CollectionType: "livetv" },
      ],
    });
    const whole = navEntries();
    expect(whole).toContain("Films #/lib/m");
    up = false;
    await shell.api.checkOnline();
    await settle();
    // Downloads, and the two sections whose pages show downloaded content.
    expect(navEntries()).toEqual([
      "Downloads #/downloads",
      "— Libraries",
      "Listen Now #/music/discover",
      "Library #/music/library",
      "Audiobooks #/books",
    ]);
    up = true;
    await shell.api.checkOnline();
    await settle();
    expect(navEntries()).toEqual(whole);
  });

  it("draws only Downloads for a launch with no server and no remembered libraries", async () => {
    await bootShell({ ping: false });
    expect(navEntries()).toEqual(["Downloads #/downloads"]);
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
    expect($("offline-strip").hasAttribute("hidden")).toBe(true);
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

  it("the strip's Retry says it is looking, then that the server is still away, and starts the backoff over", async () => {
    const { setUp } = await onlineThenOff();
    await vi.advanceTimersByTimeAsync(15_000 + 30_000);
    const before = invokeCalls("jf_ping").length;
    const retry = $("offline-retry") as HTMLButtonElement;
    click(retry);
    expect(retry.disabled).toBe(true);
    expect(retry.textContent).toBe("Checking…");
    expect($("offline-status").textContent).toBe("Looking for your server…");
    await flush();
    expect(retry.disabled).toBe(false);
    expect(retry.textContent).toBe("Retry");
    expect($("offline-status").textContent).toBe("Your server can't be reached");
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
    expect(account().name).toBe("second");
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
    expect([...dialog.querySelectorAll("h4")].map((h) => h.textContent)).toEqual([
      "Anywhere",
      "Go to",
      "Playback",
      "On the picture",
      "Browsing",
    ]);
    expect(dialog.querySelector(".shortcut-row kbd")!.textContent).toBe("/");
    key("?");
    expect(document.querySelector(".dialog")).toBeNull();
    key("?");
    key("Escape");
    expect(document.querySelector(".dialog")).toBeNull();
  });

  it("opens again on the first ? after being closed with its Close button", async () => {
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
    expect(account()).toEqual({ name: "ada", server: "jf.test", initial: "A" });
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
