// The Settings page (src/views/settings.ts), drawn into jsdom with the real
// api.ts and ui.ts behind it on the mock bridge. What a setting does once
// saved belongs to other modules, so those edges are spies: the playback
// controls (setLiveSetting, setProp, adaptive quality, the download queue),
// the Live TV line-up and source cache, and the theme.
import { beforeEach, describe, expect, it, vi } from "vitest";
import { flush, invokeCalls, onInvoke, onInvokes, signIn } from "../helpers/tauri";

vi.mock("../../src/playback", async (importOriginal) => {
  const real: any = await importOriginal();
  return {
    ...real,
    isAdaptiveEnabled: vi.fn(() => true),
    setAdaptiveEnabled: vi.fn(),
    setLiveSetting: vi.fn(),
    downloadPrefsChanged: vi.fn(),
    playerCtl: { ...real.playerCtl, setProp: vi.fn(async () => {}) },
  };
});

vi.mock("../../src/lineup", () => ({
  cachedLineup: vi.fn(() => undefined),
  loadLineup: vi.fn(async () => []),
  refreshNow: vi.fn(async () => []),
}));

vi.mock("../../src/iptv", async (importOriginal) => {
  const real: any = await importOriginal();
  return {
    ...real,
    isCustom: vi.fn(() => false),
    lastRead: vi.fn(() => null),
    describe: vi.fn(async () => ({ channels: 0, matched: 0, programs: 0 })),
    invalidate: vi.fn(),
  };
});

vi.mock("../../src/theme", () => ({
  getThemePref: vi.fn(() => "dark"),
  setThemePref: vi.fn(async () => {}),
}));

import * as playback from "../../src/playback";
import * as lineup from "../../src/lineup";
import * as iptv from "../../src/iptv";
import * as theme from "../../src/theme";
import { renderSettings } from "../../src/views/settings";

const pb = vi.mocked(playback);
const ln = vi.mocked(lineup);
const tv = vi.mocked(iptv);
const th = vi.mocked(theme);

const settle = (): Promise<void> => flush(60);

let root: HTMLElement;
let onLogout: ReturnType<typeof vi.fn>;

interface World {
  config?: Record<string, any>;
  info?: Record<string, any>;
  accounts?: any[] | (() => any);
  devices?: any[] | (() => any);
}

async function mount(world: World = {}): Promise<HTMLElement> {
  const api = await signIn(world.config ?? {});
  // api.ts keeps its offline flag across tests; start every page online.
  onInvoke("jf_ping", true);
  await api.checkOnline();
  onInvokes({
    app_info: () => world.info ?? { version: "1.2.3", mpv: "mpv 0.41.0", downloads_dir: "/home/u/Videos/Aquarium" },
    accounts_list: () => (typeof world.accounts === "function" ? world.accounts() : world.accounts ?? []),
    audio_devices: () => (typeof world.devices === "function" ? world.devices() : world.devices ?? []),
  });
  root = document.createElement("div");
  root.id = "content";
  document.body.append(root);
  onLogout = vi.fn();
  await renderSettings(root, onLogout);
  await settle();
  return root;
}

function block(title: string): HTMLElement {
  const b = [...root.querySelectorAll<HTMLElement>(".settings-block")].find((x) => x.querySelector("h3")?.textContent === title);
  if (!b) throw new Error(`no block "${title}"`);
  return b;
}

/** The row whose label is `label`, anywhere on the page (or in `within`). */
function rowNamed(label: string, within: ParentNode = root): HTMLElement {
  const lbl = [...within.querySelectorAll<HTMLElement>(".settings-row .lbl")].find((l) => l.textContent === label);
  if (!lbl) throw new Error(`no row "${label}"`);
  return lbl.closest(".settings-row") as HTMLElement;
}

function selectIn(label: string): HTMLSelectElement {
  return rowNamed(label).querySelector("select")!;
}

function pick(select: HTMLSelectElement, value: string): void {
  select.value = value;
  select.dispatchEvent(new Event("change", { bubbles: true }));
}

function button(text: string, within: ParentNode = root): HTMLButtonElement {
  const b = [...within.querySelectorAll<HTMLButtonElement>("button")].find((x) => x.textContent === text);
  if (!b) throw new Error(`no button "${text}"`);
  return b;
}

function dialogButton(text: string): HTMLButtonElement {
  return button(text, document.querySelector(".dialog")!);
}

function toasts(): string[] {
  return [...document.querySelectorAll("#toasts > *")].map((t) => t.textContent ?? "");
}

/** The config patches saved through `config_save`, in order. */
function saved(): Record<string, any>[] {
  return invokeCalls("config_save").map((c) => c.args.cfg);
}

function deferred<T = any>(): { promise: Promise<T>; resolve: (v: T) => void } {
  let resolve!: (v: T) => void;
  const promise = new Promise<T>((r) => (resolve = r));
  return { promise, resolve };
}

beforeEach(() => {
  vi.clearAllMocks();
  document.body.innerHTML = '<div id="toasts"></div>';
  pb.isAdaptiveEnabled.mockReturnValue(true);
  tv.isCustom.mockReturnValue(false);
  tv.lastRead.mockReturnValue(null);
  ln.cachedLineup.mockReturnValue(undefined);
  th.getThemePref.mockReturnValue("dark");
});

describe("page", () => {
  it("draws every block in order", async () => {
    await mount();
    expect(root.querySelector("h1")!.textContent).toBe("Settings");
    expect([...root.querySelectorAll(".settings-block > h3")].map((h) => h.textContent)).toEqual([
      "Server",
      "Accounts",
      "Requests",
      "Quick Connect",
      "Appearance",
      "Next Up",
      "Playback",
      "Live TV",
      "Languages",
      "Subtitles",
      "Audio",
      "Music",
      "Picture",
      "Downloads",
      "Storage",
      "About",
    ]);
    expect(rowNamed("Downloads folder").textContent).toContain("/home/u/Videos/Aquarium");
    expect(root.querySelector(".about-version")!.textContent).toBe("v1.2.3");
    expect(rowNamed("mpv").textContent).toContain("Running mpv 0.41.0");
  });

  it("still draws when the backend cannot say anything about itself", async () => {
    onInvoke("app_info", () => Promise.reject(new Error("no backend")));
    await signIn();
    root = document.createElement("div");
    document.body.append(root);
    onInvokes({ accounts_list: [], audio_devices: () => Promise.reject(new Error("no mpv")) });
    await renderSettings(root, vi.fn());
    expect(root.querySelector(".about-version")!.textContent).toBe("");
    expect(rowNamed("mpv").textContent).toContain("Running libmpv2");
    expect(rowNamed("Output").textContent).toContain("couldn't be asked for the list of outputs");
    expect([...selectIn("Output").options].map((o) => o.textContent)).toEqual(["Automatic"]);
  });
});

describe("stale-page guards (regression: a963a95 Settings stops after its awaits if the page moved on)", () => {
  async function overtakenAt(cmd: "app_info" | "accounts_list" | "audio_devices"): Promise<HTMLElement> {
    await signIn();
    onInvokes({ app_info: {}, accounts_list: [], audio_devices: [] });
    const gate = deferred<any>();
    onInvoke(cmd, () => gate.promise);
    const page = document.createElement("div");
    document.body.append(page);
    const render = renderSettings(page, vi.fn());
    await settle();
    // The user navigated away: another page now owns the container.
    page.innerHTML = '<div class="other-page">Home</div>';
    gate.resolve(cmd === "app_info" ? {} : []);
    await render;
    return page;
  }

  it("draws nothing once the page has moved on during the first request", async () => {
    const page = await overtakenAt("app_info");
    expect(page.innerHTML).toBe('<div class="other-page">Home</div>');
  });

  it("draws nothing more once the page has moved on while accounts load", async () => {
    const page = await overtakenAt("accounts_list");
    expect(page.innerHTML).toBe('<div class="other-page">Home</div>');
  });

  it("draws nothing more once the page has moved on while audio outputs load", async () => {
    const page = await overtakenAt("audio_devices");
    expect(page.innerHTML).toBe('<div class="other-page">Home</div>');
  });
});

describe("server", () => {
  it("names the server and the account, and says the link is encrypted, pinned and in the keyring", async () => {
    await mount({ info: { server_secure: true, server_pinned: true, token_storage: "keyring" } });
    const server = block("Server");
    expect(server.textContent).toContain("http://jf.test:8096");
    expect(server.textContent).toContain("Signed in as tester");
    expect(rowNamed("Connection").querySelector(".sync-pill")!.className).toBe("sync-pill ok");
    expect(rowNamed("Connection").textContent).toContain("HTTPS");
    expect(rowNamed("Server identity").textContent).toContain("Pinned");
    expect(rowNamed("Access token").textContent).toContain("Keyring");
    expect(server.textContent).not.toContain("Unfinished sign-out");
  });

  it("warns about plain HTTP, an unpinned server, a token in the config file and an unfinished sign-out", async () => {
    await mount({ info: { revocation_pending: true } });
    expect(rowNamed("Connection").querySelector(".sync-pill")!.className).toBe("sync-pill warn");
    expect(rowNamed("Connection").textContent).toContain("Unencrypted (HTTP)");
    expect(rowNamed("Server identity").textContent).toContain("Unpinned");
    expect(rowNamed("Access token").textContent).toContain("Config file");
    expect(rowNamed("Unfinished sign-out").textContent).toContain("Pending");
  });

  it("says Not connected with no session", async () => {
    onInvoke("config_load", { device_id: "d" });
    const api = await import("../../src/api");
    await api.loadConfig();
    onInvokes({ app_info: {}, accounts_list: [], audio_devices: [] });
    root = document.createElement("div");
    document.body.append(root);
    await renderSettings(root, vi.fn());
    expect(block("Server").textContent).toContain("Not connected");
  });

  it("signs out and returns to the sign-in screen when the server confirms", async () => {
    await mount();
    onInvoke("jf_logout", { revoked: true });
    const out = button("Sign out");
    out.click();
    expect(out.disabled).toBe(true);
    expect(out.textContent).toBe("Signing out…");
    await settle();
    expect(onLogout).toHaveBeenCalledTimes(1);
    expect(toasts()).toEqual([]);
  });

  it("says when the server could not be told, and whether it will keep trying", async () => {
    await mount();
    onInvoke("jf_logout", { revoked: false, pending: true });
    button("Sign out").click();
    await settle();
    expect(toasts().at(-1)).toContain("Aquarium will keep retrying");
    expect(onLogout).toHaveBeenCalledTimes(1);

    await mount();
    onInvoke("jf_logout", { revoked: false, pending: false });
    button("Sign out").click();
    await settle();
    expect(toasts().at(-1)).toContain("Revoke this device in Jellyfin");
  });

  it("still leaves when signing out fails outright", async () => {
    await mount();
    onInvoke("jf_logout", () => Promise.reject("io|disk"));
    button("Sign out").click();
    await settle();
    expect(toasts().at(-1)).toBe("Sign out failed");
    expect(onLogout).toHaveBeenCalledTimes(1);
  });
});

describe("accounts", () => {
  const ACCOUNTS = [
    { key: "k1", server: "http://jf.test:8096", server_name: "Reef", user_id: "u1", user_name: "tester", current: true },
    { key: "k2", server: "https://other.test", user_id: "u2", user_name: "", current: false },
  ];

  it("lists every account on the device, the one in use marked, and Add Account last", async () => {
    await mount({ accounts: ACCOUNTS });
    const rows = [...block("Accounts").querySelectorAll(".settings-row")];
    expect(rows).toHaveLength(3);
    expect(rows[0]!.textContent).toContain("tester");
    expect(rows[0]!.textContent).toContain("Reef");
    expect(rows[0]!.textContent).toContain("In use");
    expect(rows[1]!.textContent).toContain("Unnamed user");
    expect(rows[1]!.textContent).toContain("other.test");
    expect(rows[2]!.textContent).toContain("Add Account…");
  });

  it("asks the shell to switch, and to add an account", async () => {
    await mount({ accounts: ACCOUNTS });
    const switched = vi.fn();
    const added = vi.fn();
    document.addEventListener("aquarium-account-switch", switched);
    document.addEventListener("aquarium-add-account", added);
    button("Switch").click();
    expect(switched.mock.calls[0]![0].detail).toEqual({ key: "k2" });
    button("Add Account…").click();
    expect(added).toHaveBeenCalledTimes(1);
    document.removeEventListener("aquarium-account-switch", switched);
    document.removeEventListener("aquarium-add-account", added);
  });

  it("signs another account out of the device after asking, and redraws the list", async () => {
    let list = ACCOUNTS;
    await mount({ accounts: () => list });
    onInvoke("account_forget", (a: { key: string }) => {
      list = ACCOUNTS.filter((x) => x.key !== a.key);
      return { revoked: true };
    });
    button("Sign Out of This Device").click();
    expect(document.querySelector(".dialog h2")!.textContent).toBe("Sign  out of this device?");
    expect(document.querySelector(".dialog")!.textContent).toContain("Their session on other.test is ended");
    dialogButton("Sign Out").click();
    await settle();
    expect(invokeCalls("account_forget")[0]!.args).toEqual({ key: "k2" });
    expect(block("Accounts").querySelectorAll(".settings-row")).toHaveLength(2);
    expect(toasts()).toEqual([]);
  });

  it("says when the other account's session could not be ended, or the removal failed", async () => {
    await mount({ accounts: ACCOUNTS });
    onInvoke("account_forget", { revoked: false });
    button("Sign Out of This Device").click();
    dialogButton("Sign Out").click();
    await settle();
    expect(toasts().at(-1)).toBe("Removed here, but the server couldn't be reached to end that session.");

    onInvoke("account_forget", () => Promise.reject("config|Keyring locked"));
    button("Sign Out of This Device").click();
    dialogButton("Sign Out").click();
    await settle();
    expect(toasts().at(-1)).toBe("Keyring locked");
  });

  it("does nothing on Cancel", async () => {
    await mount({ accounts: ACCOUNTS });
    button("Sign Out of This Device").click();
    dialogButton("Cancel").click();
    await settle();
    expect(invokeCalls("account_forget")).toHaveLength(0);
  });

  it("stops redrawing the list once the page is gone", async () => {
    let list = ACCOUNTS;
    await mount({ accounts: () => list });
    const gate = deferred<any[]>();
    onInvoke("account_forget", { revoked: true });
    button("Sign Out of This Device").click();
    onInvoke("accounts_list", () => gate.promise);
    dialogButton("Sign Out").click();
    await settle();
    const block0 = block("Accounts");
    root.remove();
    gate.resolve([]);
    await settle();
    expect(block0.querySelectorAll(".settings-row")).toHaveLength(3);
  });
});

describe("Quick Connect", () => {
  function qc(): { input: HTMLInputElement; approve: HTMLButtonElement; outcome: HTMLElement } {
    const row = rowNamed("Approve a code");
    return {
      input: row.querySelector("input")!,
      approve: button("Approve…", row),
      outcome: row.querySelector<HTMLElement>(".sub[hidden], .qc-outcome")!,
    };
  }

  function type(input: HTMLInputElement, text: string): void {
    input.value = text;
    input.dispatchEvent(new Event("input"));
  }

  it("takes six digits only before Approve can be pressed", async () => {
    await mount();
    const { input, approve } = qc();
    expect(approve.disabled).toBe(true);
    type(input, "12a3");
    expect(input.value).toBe("123");
    expect(approve.disabled).toBe(true);
    type(input, "1234567");
    expect(input.value).toBe("123456");
    expect(approve.disabled).toBe(false);
  });

  it("cannot approve while offline", async () => {
    await mount();
    onInvoke("jf_ping", false);
    const api = await import("../../src/api");
    await api.checkOnline();
    const { input, approve } = qc();
    type(input, "123456");
    expect(approve.disabled).toBe(true);
  });

  it("asks before approving, and says the other device is signing in", async () => {
    await mount();
    const { input, approve, outcome } = qc();
    onInvoke("jf_request", { status: 200, body: true });
    type(input, "123456");
    // Enter with fewer digits does nothing; with six it asks.
    approve.click();
    expect(document.querySelector(".dialog h2")!.textContent).toBe("Sign another device in as tester?");
    dialogButton("Approve 123456").click();
    await settle();
    expect(invokeCalls("jf_request").at(-1)!.args.path).toBe("/QuickConnect/Authorize?code=123456");
    expect(input.value).toBe("");
    expect(outcome.textContent).toBe("The other device is signing in now.");
    expect(outcome.className).toBe("sub qc-outcome ok");
    expect(outcome.hasAttribute("hidden")).toBe(false);
    expect(approve.disabled).toBe(true);
    // Typing again hides the last outcome.
    type(input, "9");
    expect(outcome.hasAttribute("hidden")).toBe(true);
  });

  it("says an unknown code is unknown, and shows a failure", async () => {
    await mount();
    const { input, outcome } = qc();
    type(input, "123456");
    onInvoke("jf_request", { status: 404, body: null });
    input.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter" }));
    dialogButton("Approve 123456").click();
    await settle();
    expect(outcome.className).toBe("sub qc-outcome warn");
    expect(outcome.textContent).toContain("The server doesn't know that code");
    expect(qc().approve.disabled).toBe(false);

    onInvoke("jf_request", { status: 403, body: null });
    input.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter" }));
    dialogButton("Approve 123456").click();
    await settle();
    expect(outcome.className).toBe("sub qc-outcome bad");
    expect(outcome.textContent).toBe("This account isn't allowed to approve Quick Connect requests");
  });

  it("ignores Enter and other keys without six digits", async () => {
    await mount();
    const { input } = qc();
    type(input, "12");
    input.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter" }));
    input.dispatchEvent(new KeyboardEvent("keydown", { key: "a" }));
    expect(document.querySelector(".dialog")).toBeNull();
  });
});

describe("appearance and Next Up", () => {
  it("applies the theme at once, and says when it could not be saved", async () => {
    await mount();
    const theme = selectIn("Theme");
    expect(theme.value).toBe("dark");
    pick(theme, "light");
    await settle();
    expect(th.setThemePref).toHaveBeenCalledWith("light");
    th.setThemePref.mockRejectedValueOnce(new Error("disk"));
    pick(theme, "auto");
    await settle();
    expect(toasts().at(-1)).toBe("Couldn't save appearance setting");
  });

  it("saves a toggle as a boolean the moment it changes", async () => {
    await mount({ config: { hide_continue_watching: true } });
    const sel = selectIn("Continue Watching");
    expect(sel.value).toBe("on");
    expect([...sel.options].map((o) => o.textContent)).toEqual(["Shown", "Hidden — Next Up only"]);
    pick(sel, "off");
    await settle();
    expect(saved().at(-1)).toEqual({ hide_continue_watching: false });
  });

  it("says when a setting could not be saved", async () => {
    await mount();
    onInvoke("config_save", () => Promise.reject(new Error("disk")));
    pick(selectIn("Include shows you're rewatching"), "on");
    pick(selectIn("Skip by"), "30");
    await settle();
    expect(toasts()).toEqual(["Couldn't save that setting", "Couldn't save that setting"]);
  });

  it("lists Next Up's day limits shortest first with Forever last, and treats unset in-progress as on", async () => {
    await mount();
    const days = selectIn("Keep shows on Next Up");
    const values = [...days.options].map((o) => o.value);
    expect(values.at(-1)).toBe("0");
    expect(values.slice(0, -1).map(Number)).toEqual([...values.slice(0, -1).map(Number)].sort((a, b) => a - b));
    expect(days.value).toBe("0");
    pick(days, "30");
    await settle();
    expect(saved().at(-1)).toEqual({ next_up_days: "30" });
    expect(selectIn("Include episodes in progress").value).toBe("on");
    expect(selectIn("Include shows you're rewatching").value).toBe("off");
  });
});

describe("playback", () => {
  it("reads defaults for unset keys", async () => {
    await mount();
    expect(selectIn("Resume where I left off").value).toBe("on");
    expect(selectIn("Play the next episode automatically").value).toBe("on");
    expect(selectIn("Skip by").value).toBe("10");
    expect(selectIn("Hide controls after").value).toBe("2");
    expect(selectIn("Show time remaining").value).toBe("off");
    expect(selectIn("Hardware acceleration").value).toBe("auto");
    expect(selectIn("Smooth motion").value).toBe("off");
    expect(selectIn("Streaming quality").value).toBe("auto");
  });

  it("reflects saved values", async () => {
    pb.isAdaptiveEnabled.mockReturnValue(false);
    await mount({
      config: { resume_playback: false, autoplay_next: false, player_skip_interval: 30, player_hide_after: 6, hwdec: "vaapi" },
    });
    expect(selectIn("Resume where I left off").value).toBe("off");
    expect(selectIn("Play the next episode automatically").value).toBe("off");
    expect(selectIn("Skip by").value).toBe("30");
    expect(selectIn("Hide controls after").value).toBe("6");
    expect(selectIn("Hardware acceleration").value).toBe("vaapi");
    expect(selectIn("Streaming quality").value).toBe("off");
  });

  it("turns adaptive quality on and off without a config write of its own", async () => {
    await mount();
    pick(selectIn("Streaming quality"), "off");
    expect(pb.setAdaptiveEnabled).toHaveBeenLastCalledWith(false);
    pick(selectIn("Streaming quality"), "auto");
    expect(pb.setAdaptiveEnabled).toHaveBeenLastCalledWith(true);
  });

  it("reports the decoder the last stream used", async () => {
    await mount();
    expect(rowNamed("Last decoded with").textContent).toContain("Not measured yet");
    localStorage.setItem("aquarium.hwdec-last", "vaapi");
    await mount();
    const pill = rowNamed("Last decoded with").querySelector(".sync-pill")!;
    expect(pill.textContent).toBe("VAAPI (GPU)");
    expect(pill.className).toBe("sync-pill ok");
    localStorage.setItem("aquarium.hwdec-last", "no");
    await mount();
    expect(rowNamed("Last decoded with").querySelector(".sync-pill")!.className).toBe("sync-pill warn");
    expect(rowNamed("Last decoded with").textContent).toContain("Software (CPU)");
    localStorage.setItem("aquarium.hwdec-last", "d3d11va");
    await mount();
    expect(rowNamed("Last decoded with").querySelector(".sync-pill")!.textContent).toBe("d3d11va");
  });

  it("says not measured when storage cannot be read", async () => {
    const get = vi.spyOn(Storage.prototype, "getItem").mockImplementation(() => {
      throw new Error("denied");
    });
    try {
      await mount();
      expect(rowNamed("Last decoded with").textContent).toContain("Not measured yet");
    } finally {
      get.mockRestore();
    }
  });

  it("reads battery saver from old true/false configs and the newer words", async () => {
    for (const [stored, want] of [
      [undefined, "auto"],
      [true, "on"],
      ["on", "on"],
      [false, "off"],
      ["off", "off"],
      ["auto", "auto"],
    ] as const) {
      await mount({ config: stored === undefined ? {} : { battery_render: stored } });
      expect(selectIn("Battery saver rendering").value, String(stored)).toBe(want);
    }
    pick(selectIn("Battery saver rendering"), "on");
    await settle();
    expect(saved().at(-1)).toEqual({ battery_render: "on" });
  });
});

describe("Live TV", () => {
  it("hides the playlist rows for Jellyfin's Live TV and shows them for a custom source", async () => {
    await mount();
    const custom = block("Live TV").querySelector<HTMLElement>(".settings-sub")!;
    expect(custom.style.display).toBe("none");
    const nav = vi.fn();
    document.addEventListener("aquarium-nav-refresh", nav);
    pick(selectIn("Source"), "custom");
    await settle();
    expect(custom.style.display).toBe("");
    expect(saved().at(-1)).toEqual({ livetv_source: "custom" });
    expect(tv.invalidate).toHaveBeenCalled();
    // The sidebar's Live TV entry depends on the source.
    expect(nav).toHaveBeenCalledTimes(1);
    document.removeEventListener("aquarium-nav-refresh", nav);
  });

  it("opens with the custom rows shown when the source is custom", async () => {
    await mount({ config: { livetv_source: "custom", livetv_m3u: "http://tv.test/a.m3u", livetv_xmltv: "http://tv.test/g.xml", livetv_user_agent: "Kodi" } });
    expect(block("Live TV").querySelector<HTMLElement>(".settings-sub")!.style.display).toBe("");
    expect(rowNamed("M3U playlist").querySelector("input")!.value).toBe("http://tv.test/a.m3u");
    expect(rowNamed("XMLTV guide").querySelector("input")!.value).toBe("http://tv.test/g.xml");
    expect(rowNamed("User agent").querySelector("input")!.value).toBe("Kodi");
    expect(rowNamed("User agent").querySelector("input")!.placeholder).toBe(iptv.DEFAULT_USER_AGENT);
  });

  it("saves the user agent (empty as unset) and drops the cached line-up", async () => {
    await mount();
    const ua = rowNamed("User agent").querySelector("input")!;
    ua.value = "  Kodi/20 ";
    ua.dispatchEvent(new Event("change"));
    await settle();
    expect(saved().at(-1)).toEqual({ livetv_user_agent: "Kodi/20" });
    expect(tv.invalidate).toHaveBeenCalledTimes(1);
    ua.value = "  ";
    ua.dispatchEvent(new Event("change"));
    await settle();
    expect(saved().at(-1)).toEqual({ livetv_user_agent: null });
    onInvoke("config_save", () => Promise.reject(new Error("disk")));
    ua.dispatchEvent(new Event("change"));
    await settle();
    expect(toasts().at(-1)).toBe("Couldn't save that setting");
  });

  it("offers guide refresh intervals with the current one chosen", async () => {
    await mount({ config: { livetv_refresh_min: 60 } });
    const sel = selectIn("Refresh the guide");
    expect(sel.value).toBe("60");
    expect(sel.options).toHaveLength(8);
  });

  it("says how many channels came from the server, or nothing before they have", async () => {
    await mount();
    const line = () => rowNamed("Channel list and guide").querySelectorAll(".sub")[1]!.textContent;
    expect(line()).toBe("");
    ln.cachedLineup.mockReturnValue([{}, {}]);
    await mount();
    expect(line()).toBe("2 channels from the server.");
    ln.cachedLineup.mockReturnValue([{}]);
    await mount();
    expect(line()).toBe("1 channel from the server.");
  });

  it("describes the last read of a custom playlist, artwork included", async () => {
    tv.isCustom.mockReturnValue(true);
    await mount();
    const line = () => rowNamed("Channel list and guide").querySelectorAll(".sub")[1]!.textContent!;
    expect(line()).toBe("Not read yet this session — open Live TV, or Refresh now.");

    const at = new Date(2026, 10, 12, 14, 14).getTime();
    tv.lastRead.mockReturnValue({ at, channels: 124, withLogos: 98, matched: 100, programs: 3410 });
    await mount();
    expect(line()).toMatch(/^Last read: 124 channels · 98 with artwork · 3,410 programmes in the guide · .+\.$/);

    tv.lastRead.mockReturnValue({ at, channels: 1, withLogos: 1, matched: 1, programs: 1 });
    await mount();
    expect(line()).toMatch(/^Last read: 1 channel · all with artwork · 1 programme in the guide/);

    tv.lastRead.mockReturnValue({ at, channels: 3, withLogos: 0, matched: 0, programs: 0 });
    await mount();
    expect(line()).toContain("no channel artwork — the playlist has no tvg-logo and the guide no <icon>");
  });

  it("Refresh now reads the line-up again and says so, or shows what went wrong", async () => {
    await mount();
    const btn = button("Refresh now");
    const gate = deferred<any[]>();
    ln.refreshNow.mockReturnValueOnce(gate.promise);
    btn.click();
    expect(btn.disabled).toBe(true);
    expect(btn.textContent).toBe("Refreshing…");
    ln.cachedLineup.mockReturnValue([{}, {}, {}]);
    gate.resolve([]);
    await settle();
    expect(btn.disabled).toBe(false);
    expect(btn.textContent).toBe("Refresh now");
    expect(toasts().at(-1)).toBe("Live TV refreshed");
    expect(rowNamed("Channel list and guide").textContent).toContain("3 channels from the server.");

    ln.refreshNow.mockRejectedValueOnce(new Error("guide 500"));
    btn.click();
    await settle();
    expect(toasts().at(-1)).toBe("Couldn't refresh Live TV");
    expect(rowNamed("Channel list and guide").textContent).toContain("guide 500");
    ln.refreshNow.mockRejectedValueOnce("plain");
    btn.click();
    await settle();
    expect(rowNamed("Channel list and guide").textContent).toContain("plain");
  });

  it("Load sources saves both addresses, loads them and reports what came back", async () => {
    await mount({ config: { livetv_source: "custom" } });
    rowNamed("M3U playlist").querySelector("input")!.value = " http://tv.test/a.m3u ";
    rowNamed("XMLTV guide").querySelector("input")!.value = "";
    tv.describe.mockResolvedValueOnce({ channels: 12, matched: 9, programs: 2400 });
    const btn = button("Load sources");
    btn.click();
    expect(btn.textContent).toBe("Checking…");
    await settle();
    expect(saved().at(-1)).toEqual({ livetv_m3u: "http://tv.test/a.m3u", livetv_xmltv: null });
    expect(tv.invalidate).toHaveBeenCalled();
    expect(ln.refreshNow).toHaveBeenCalled();
    const status = rowNamed("Check and load").querySelector(".sub")!;
    expect(status.textContent).toBe("12 channels · 2,400 programmes across 9 of them.");
    expect(toasts().at(-1)).toBe("Live TV source loaded");
    expect(btn.textContent).toBe("Load sources");
    expect(btn.disabled).toBe(false);

    tv.describe.mockResolvedValueOnce({ channels: 3, matched: 0, programs: 0 });
    ln.refreshNow.mockRejectedValueOnce(new Error("ignored"));
    btn.click();
    await settle();
    expect(status.textContent).toBe("3 channels · no guide data matched.");

    tv.describe.mockRejectedValueOnce(new Error("404 on the playlist"));
    btn.click();
    await settle();
    expect(status.textContent).toBe("404 on the playlist");
    expect(toasts().at(-1)).toBe("Couldn't load that source");
    tv.describe.mockRejectedValueOnce("plain");
    btn.click();
    await settle();
    expect(status.textContent).toBe("plain");
  });

  describe("Check artwork", () => {
    function stubImages(): HTMLImageElement[] {
      const made: HTMLImageElement[] = [];
      vi.stubGlobal("Image", function FakeImage() {
        const img = document.createElement("img");
        made.push(img);
        return img;
      } as any);
      return made;
    }

    it("loads every logo and counts loaded, unnamed and failing ones", async () => {
      await mount({ config: { livetv_source: "custom" } });
      const made = stubImages();
      ln.loadLineup.mockResolvedValueOnce([
        { Name: "One", LogoUrl: "http://logo.test/1.png" },
        { Name: "Two", LogoUrl: "http://logo.test/2.png" },
        { Name: "Three" },
        { Id: "c4", ImageTags: { Primary: "t" } },
        { Name: "Five", LogoUrl: "http://logo.test/5.png" },
        { Name: "Six", LogoUrl: "http://logo.test/6.png" },
        { Name: "Seven", LogoUrl: "http://logo.test/7.png" },
      ]);
      const btn = button("Check artwork");
      btn.click();
      expect(btn.textContent).toBe("Checking…");
      await settle();
      expect(made.map((i) => i.getAttribute("src"))).toEqual([
        "http://logo.test/1.png",
        "http://logo.test/2.png",
        expect.stringContaining("/Items/c4/Images/Primary?maxWidth=160"),
        "http://logo.test/5.png",
        "http://logo.test/6.png",
        "http://logo.test/7.png",
      ]);
      Object.defineProperty(made[0]!, "naturalWidth", { value: 64 });
      made[0]!.dispatchEvent(new Event("load"));
      // A load that decoded nothing is a failure.
      made[1]!.dispatchEvent(new Event("load"));
      made[2]!.dispatchEvent(new Event("error"));
      for (const img of made.slice(3)) img.dispatchEvent(new Event("error"));
      await settle();
      const status = rowNamed("Channel artwork").querySelectorAll(".sub")[1]!;
      expect(status.textContent).toBe("1 of 7 channel logos loaded · 1 name no logo · 5 wouldn't load (Two, Channel 4, Five, …).");
      expect(btn.textContent).toBe("Check artwork");
      expect(btn.disabled).toBe(false);
    });

    it("gives up on a logo whose host never answers", async () => {
      vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
      await mount({ config: { livetv_source: "custom" } });
      const made = stubImages();
      ln.loadLineup.mockResolvedValueOnce([{ Name: "Slow", LogoUrl: "http://slow.test/1.png" }]);
      button("Check artwork").click();
      await settle();
      expect(rowNamed("Channel artwork").querySelectorAll(".sub")[1]!.textContent).toBe("");
      vi.advanceTimersByTime(8000);
      await settle();
      expect(made).toHaveLength(1);
      expect(rowNamed("Channel artwork").querySelectorAll(".sub")[1]!.textContent).toBe(
        "0 of 1 channel logos loaded · 1 wouldn't load (Slow)."
      );
    });

    it("reports progress while checking, and a failure to load the line-up", async () => {
      await mount({ config: { livetv_source: "custom" } });
      const made = stubImages();
      ln.loadLineup.mockResolvedValueOnce([{ Name: "A", LogoUrl: "http://l/a" }, { Name: "B", LogoUrl: "http://l/b" }]);
      button("Check artwork").click();
      await settle();
      Object.defineProperty(made[0]!, "naturalWidth", { value: 1 });
      made[0]!.dispatchEvent(new Event("load"));
      await settle();
      const status = rowNamed("Channel artwork").querySelectorAll(".sub")[1]!;
      expect(status.textContent).toBe("Checking 1 of 2…");
      Object.defineProperty(made[1]!, "naturalWidth", { value: 1 });
      made[1]!.dispatchEvent(new Event("load"));
      await settle();
      expect(status.textContent).toBe("2 of 2 channel logos loaded.");

      ln.loadLineup.mockRejectedValueOnce(new Error("no playlist"));
      button("Check artwork").click();
      await settle();
      expect(status.textContent).toBe("no playlist");
      ln.loadLineup.mockRejectedValueOnce("plain");
      button("Check artwork").click();
      await settle();
      expect(status.textContent).toBe("plain");
    });
  });
});

describe("languages, subtitles, audio and music", () => {
  it("offers the language lists, both ISO codes where two are in use", async () => {
    await mount({ config: { audio_lang: "fre,fra", sub_lang: "off" } });
    const audio = selectIn("Audio");
    expect(audio.value).toBe("fre,fra");
    expect(audio.options[0]!.textContent).toBe("Whatever the file lists first");
    const subs = selectIn("Subtitles");
    expect(subs.value).toBe("off");
    expect([...subs.options].slice(0, 2).map((o) => o.value)).toEqual(["", "off"]);
    pick(audio, "jpn");
    await settle();
    expect(saved().at(-1)).toEqual({ audio_lang: "jpn" });
    expect(selectIn("Forced subtitles").value).toBe("off");
  });

  it("applies the subtitle size and position as they are dragged", async () => {
    await mount({ config: { sub_pos: 90 } });
    const size = rowNamed("Size").querySelector("input")!;
    expect(size.value).toBe("38");
    expect(rowNamed("Size").querySelector(".settings-value")!.textContent).toBe("38");
    size.value = "50";
    size.dispatchEvent(new Event("input"));
    expect(pb.setLiveSetting).toHaveBeenLastCalledWith("sub_font_size", "sub-font-size", 50);
    expect(size.style.getPropertyValue("--fill")).toBe("50%");
    expect(rowNamed("Size").querySelector(".settings-value")!.textContent).toBe("50");

    const pos = rowNamed("Position");
    expect(pos.querySelector("input")!.value).toBe("90");
    expect(pos.querySelector(".settings-value")!.textContent).toBe("10 up");
    pos.querySelector("input")!.value = "100";
    pos.querySelector("input")!.dispatchEvent(new Event("input"));
    expect(pos.querySelector(".settings-value")!.textContent).toBe("Bottom");
  });

  it("mirrors the subtitle background onto a running player", async () => {
    await mount();
    const bg = selectIn("Background");
    expect(bg.value).toBe("outline");
    pick(bg, "box");
    await settle();
    expect(saved().at(-1)).toEqual({ sub_bg: "box" });
    expect(pb.playerCtl.setProp).toHaveBeenCalledWith("sub-back-color", "#C0000000");
    expect(pb.playerCtl.setProp).toHaveBeenCalledWith("sub-border-size", "0");
    expect(pb.playerCtl.setProp).toHaveBeenCalledWith("sub-shadow-offset", "0");
    vi.mocked(pb.playerCtl.setProp).mockClear();
    vi.mocked(pb.playerCtl.setProp).mockRejectedValue(new Error("nothing playing"));
    pick(bg, "shadow");
    await settle();
    expect(pb.playerCtl.setProp).toHaveBeenCalledWith("sub-border-size", "1.5");
    expect(pb.playerCtl.setProp).toHaveBeenCalledWith("sub-shadow-offset", "2");
    // An unknown value falls back to the outline.
    vi.mocked(pb.playerCtl.setProp).mockClear();
    const opt = document.createElement("option");
    opt.value = "weird";
    bg.append(opt);
    pick(bg, "weird");
    expect(pb.playerCtl.setProp).toHaveBeenCalledWith("sub-border-size", "3");
    vi.mocked(pb.playerCtl.setProp).mockResolvedValue(undefined as any);
  });

  it("lists the audio outputs mpv reports, without its own auto entry", async () => {
    await mount({
      devices: [
        { name: "auto", description: "Autoselect" },
        { name: "pulse/hdmi", description: "HDMI" },
        { name: "pulse/usb" },
        { description: "nameless" },
        null,
      ],
      config: { audio_device: "pulse/hdmi" },
    });
    const out = selectIn("Output");
    expect([...out.options].map((o) => [o.value, o.textContent])).toEqual([
      ["", "Automatic"],
      ["pulse/hdmi", "HDMI"],
      ["pulse/usb", "pulse/usb"],
    ]);
    expect(out.value).toBe("pulse/hdmi");
    expect(rowNamed("Output").textContent).toContain("headphones rather than the television");
    expect(selectIn("Night mode").value).toBe("off");
    expect(selectIn("Downmix to stereo").value).toBe("off");
  });

  it("picks who builds a music mix", async () => {
    await mount();
    const mixes = selectIn("Mixes");
    expect(mixes.value).toBe("aquarium");
    pick(mixes, "jellyfin");
    await settle();
    expect(saved().at(-1)).toEqual({ music_mix_source: "jellyfin" });
  });
});

describe("picture", () => {
  it("applies each picture slider live and resets them all, with the aspect ratio", async () => {
    await mount({ config: { pic_brightness: 10, pic_contrast: "x", video_zoom: 20, video_aspect: "4:3" } });
    const bright = rowNamed("Brightness");
    expect(bright.querySelector("input")!.value).toBe("10");
    expect(bright.querySelector(".settings-value")!.textContent).toBe("+10");
    // A value that is not a number starts at the default.
    expect(rowNamed("Contrast").querySelector("input")!.value).toBe("0");
    expect(rowNamed("Contrast").querySelector(".settings-value")!.textContent).toBe("0");
    const zoom = rowNamed("Zoom").querySelector("input")!;
    expect(zoom.value).toBe("20");
    expect(rowNamed("Zoom").querySelector(".settings-value")!.textContent).toBe("20%");
    zoom.value = "40";
    zoom.dispatchEvent(new Event("input"));
    // The slider is in percent; mpv's zoom is a fraction.
    expect(pb.setLiveSetting).toHaveBeenLastCalledWith("video_zoom", "video-zoom", 0.4);
    const sat = rowNamed("Saturation").querySelector("input")!;
    sat.value = "-20";
    sat.dispatchEvent(new Event("input"));
    expect(pb.setLiveSetting).toHaveBeenLastCalledWith("pic_saturation", "saturation", -20);
    expect(rowNamed("Saturation").querySelector(".settings-value")!.textContent).toBe("-20");
    expect(selectIn("Aspect ratio").value).toBe("4:3");

    pb.setLiveSetting.mockClear();
    button("Reset picture").click();
    await settle();
    for (const c of playback.PICTURE_CONTROLS) expect(pb.setLiveSetting).toHaveBeenCalledWith(c.key, c.prop, 0);
    expect(pb.setLiveSetting).toHaveBeenCalledWith("video_zoom", "video-zoom", 0);
    expect(bright.querySelector("input")!.value).toBe("0");
    expect(zoom.value).toBe("0");
    expect(saved().at(-1)).toEqual({ video_aspect: "" });
    expect(toasts().at(-1)).toBe("Picture reset");
  });
});

describe("downloads", () => {
  it("saves each download setting and tells the queue, reading keep-awake as on unless turned off", async () => {
    await mount({ config: { downloads_unmetered_only: true } });
    expect(selectIn("Only download on unmetered connections").value).toBe("on");
    expect(selectIn("Transcode one at a time").value).toBe("off");
    expect(selectIn("Keep the laptop awake while downloading").value).toBe("on");
    pick(selectIn("Keep the laptop awake while downloading"), "off");
    pick(selectIn("Transcode one at a time"), "on");
    await settle();
    expect(saved().slice(-2)).toEqual([{ downloads_keep_awake: false }, { downloads_transcode_serial: true }]);
    expect(pb.downloadPrefsChanged).toHaveBeenCalledTimes(2);

    await mount({ config: { downloads_keep_awake: false } });
    expect(selectIn("Keep the laptop awake while downloading").value).toBe("off");
  });
});
