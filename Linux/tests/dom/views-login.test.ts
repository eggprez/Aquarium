// The sign-in screen (src/views/login.ts), drawn into jsdom with the Tauri
// bridge mocked. The real src/api.ts and src/ui.ts sit behind it; nothing is
// vi.mock'ed. Every credential here is a dummy string for the mock bridge.
import { beforeEach, describe, expect, it, vi } from "vitest";
import { flush, invokeCalls, onInvoke, signIn } from "../helpers/tauri";
// Loaded once here, before any vi.resetModules(): the mock in tests/setup.ts
// is built on first import, and it has to be built around the same
// helpers/tauri instance this file registers its handlers with.
import "@tauri-apps/api/core";
import type { LoginOptions } from "../../src/views/login";

const SECURE = "https://jf.test";
const PLAIN = "http://192.168.1.10:8096";

const secureProbe = { server: SECURE, server_name: "Reef", version: "10.10.3", secure: true };
const plainProbe = { server: PLAIN, server_name: "Attic", version: "10.9.0", secure: false };

interface World {
  /** What `config_load` answers before anybody has signed in. */
  config?: Record<string, any>;
  /** Answer to `jf_probe`: a value, or a function of the typed address. */
  probe?: any;
  /** Body of `/Users/Public`. */
  users?: any;
  /** Body of `/QuickConnect/Enabled`. */
  qc?: boolean;
  accounts?: any;
  discovered?: any;
  /** Everything else asked through `jf_public` (the Quick Connect exchange). */
  quick?: (args: { server: string; path: string; method: string }) => any;
  /** Use `signIn()` first: the Add Account flow starts from a live session. */
  signedIn?: boolean;
}

function deferred<T = any>(): { promise: Promise<T>; resolve: (v: T) => void; reject: (e: any) => void } {
  let resolve!: (v: T) => void;
  let reject!: (e: any) => void;
  const promise = new Promise<T>((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}

/** Let every chained await behind a click settle (works under fake timers). */
const settle = (): Promise<void> => flush(60);

let root: HTMLElement;
let onSuccess: ReturnType<typeof vi.fn>;

async function mount(world: World = {}, opts: LoginOptions = {}): Promise<HTMLElement> {
  if (world.signedIn) {
    await signIn(world.config ?? {});
  } else {
    onInvoke("config_load", () => ({ ...(world.config ?? {}) }));
    const api = await import("../../src/api");
    await api.loadConfig();
  }
  onInvoke("jf_probe", (a: { server: string }) =>
    typeof world.probe === "function" ? world.probe(a.server) : world.probe ?? secureProbe
  );
  onInvoke("accounts_list", () => world.accounts ?? []);
  onInvoke("jf_discover", () => world.discovered ?? []);
  onInvoke("jf_public", (a: { server: string; path: string; method: string }) => {
    if (a.path === "/Users/Public") return { status: 200, body: world.users ?? [] };
    if (a.path === "/QuickConnect/Enabled") return { status: 200, body: world.qc ?? false };
    if (world.quick) return world.quick(a);
    return { status: 404, body: null };
  });
  const { renderLogin } = await import("../../src/views/login");
  root = document.createElement("div");
  const toasts = document.createElement("div");
  toasts.id = "toasts";
  document.body.append(root, toasts);
  onSuccess = vi.fn();
  renderLogin(root, onSuccess, opts);
  await settle();
  return root.querySelector(".login-card") as HTMLElement;
}

const $ = <T extends HTMLElement = HTMLElement>(sel: string): T | null => root.querySelector<T>(sel);
const $$ = (sel: string): HTMLElement[] => Array.from(root.querySelectorAll<HTMLElement>(sel));
const texts = (sel: string): string[] => $$(sel).map((n) => n.textContent ?? "");

function button(label: string): HTMLButtonElement {
  const b = $$("button").find((n) => n.textContent === label);
  if (!b) throw new Error(`no button "${label}"; have: ${texts("button").join(" | ")}`);
  return b as HTMLButtonElement;
}
const hasButton = (label: string): boolean => $$("button").some((n) => n.textContent === label);

function type(input: HTMLInputElement, value: string): void {
  input.value = value;
  input.dispatchEvent(new Event("input", { bubbles: true }));
}

const addressInput = (): HTMLInputElement => $<HTMLInputElement>('input[placeholder="jellyfin.example.com"]')!;
const userInput = (): HTMLInputElement => $<HTMLInputElement>('input[placeholder="Username"]')!;
const passInput = (): HTMLInputElement => $<HTMLInputElement>('input[type="password"]')!;
const submitButton = (): HTMLButtonElement => $<HTMLButtonElement>('button[type="submit"]')!;
const errorText = (): string => $(".login-form > .login-error")?.textContent ?? "";

/** Type an address and press Connect. */
async function connect(address: string): Promise<void> {
  addressInput().value = address;
  submitButton().click();
  await settle();
}

/** Straight to step 2 on a server that needs no warning. */
async function toCredentials(world: World = {}, opts: LoginOptions = {}): Promise<HTMLElement> {
  const card = await mount({ probe: secureProbe, ...world }, opts);
  await connect("jf.test");
  return card;
}

const publicCalls = (prefix: string): any[] =>
  invokeCalls("jf_public").filter((c) => String(c.args.path).startsWith(prefix));
const pollCalls = (): any[] => publicCalls("/QuickConnect/Connect");
const polledSecrets = (): string[] =>
  pollCalls().map((c) => decodeURIComponent(String(c.args.path).split("secret=")[1]!));

/** A Quick Connect server: hands the codes out in order, answers polls with `state`. */
function quickServer(
  codes: { Secret: string; Code: string }[],
  state: (secret: string) => any = () => ({ status: 200, body: { Authenticated: false } })
): World["quick"] {
  let n = 0;
  return (a) => {
    if (a.path === "/QuickConnect/Initiate") {
      return { status: 200, body: codes[Math.min(n++, codes.length - 1)] };
    }
    if (a.path.startsWith("/QuickConnect/Connect?secret=")) {
      return state(decodeURIComponent(a.path.split("secret=")[1]!));
    }
    return { status: 404, body: null };
  };
}

const CODE_A = { Secret: "secret-a", Code: "123456" };
const CODE_B = { Secret: "secret-b", Code: "654321" };

const account = (over: Record<string, any> = {}): Record<string, any> => ({
  key: "k1",
  server: SECURE,
  server_name: "Reef",
  user_id: "u1",
  user_name: "ada",
  current: false,
  ...over,
});

beforeEach(() => {
  vi.resetModules();
});

// ---------------------------------------------------------------- step 1

describe("login: the server address step", () => {
  it("asks for a server, with the field empty and focused on a first run", async () => {
    const card = await mount();
    expect(card.querySelector("h1")!.textContent).toBe("Connect to Jellyfin");
    expect(addressInput().value).toBe("");
    expect(document.activeElement).toBe(addressInput());
    expect(submitButton().textContent).toBe("Connect");
    expect(hasButton("Cancel")).toBe(false);
    const mark = card.querySelector(".login-brand .wordmark")!;
    expect(mark.getAttribute("aria-label")).toBe("Aquarium");
    expect(mark.getAttribute("role")).toBe("img");
    expect(mark.textContent).toBe("aquar\u0131um");
    expect(mark.querySelector(".wm-i")!.getAttribute("aria-hidden")).toBe("true");
    expect(card.classList.contains("wide")).toBe(false);
  });

  it("prefills the server last signed in to, and leaves focus alone", async () => {
    await mount({ config: { server: PLAIN } });
    expect(addressInput().value).toBe(PLAIN);
    expect(document.activeElement).not.toBe(addressInput());
  });

  it("replaces whatever was in the root before", async () => {
    await mount();
    const { renderLogin } = await import("../../src/views/login");
    renderLogin(root, onSuccess);
    expect($$(".login-card")).toHaveLength(1);
  });

  it("refuses an empty address without asking the backend", async () => {
    await mount();
    await connect("   ");
    expect(errorText()).toBe("Enter your server address.");
    expect(invokeCalls("jf_probe")).toHaveLength(0);
  });

  it("probes the trimmed address, and shows Connecting… with the button off meanwhile", async () => {
    const probe = deferred();
    await mount({ probe: () => probe.promise });
    await connect("  jf.test  ");
    expect(invokeCalls("jf_probe").map((c) => c.args)).toEqual([{ server: "jf.test" }]);
    expect(submitButton().textContent).toBe("Connecting…");
    expect(submitButton().disabled).toBe(true);
    probe.reject("offline|Couldn't reach jf.test");
    await settle();
    // The error kind prefix from Rust is not shown to the user.
    expect(errorText()).toBe("Couldn't reach jf.test");
    expect(submitButton().textContent).toBe("Connect");
    expect(submitButton().disabled).toBe(false);
    expect(publicCalls("/")).toHaveLength(0);
  });

  it("clears the last error when Connect is pressed again", async () => {
    let fail = true;
    const probe = deferred();
    await mount({
      probe: () => {
        if (fail) throw new Error("server|No Jellyfin there");
        return probe.promise;
      },
    });
    await connect("jf.test");
    expect(errorText()).toBe("No Jellyfin there");
    fail = false;
    await connect("jf.test");
    expect(errorText()).toBe("");
  });

  it("goes straight on to the sign-in step for an encrypted server", async () => {
    await toCredentials();
    expect($(".login-warning")).toBeNull();
    expect(userInput()).not.toBeNull();
    expect(publicCalls("/Users/Public").map((c) => c.args.server)).toEqual([SECURE]);
  });

  it("does not move on when the probe answers after the screen was redrawn (stale probe)", async () => {
    const probe = deferred();
    await mount({ probe: () => probe.promise });
    await connect("jf.test");
    const { renderLogin } = await import("../../src/views/login");
    renderLogin(root, onSuccess); // the old card is gone
    probe.resolve(secureProbe);
    await settle();
    expect(publicCalls("/")).toHaveLength(0);
    expect(userInput()).toBeNull();
    expect(addressInput()).not.toBeNull();
  });
});

describe("login: the unencrypted-server warning", () => {
  it("stops at a warning before anything is sent to a plain-HTTP server", async () => {
    await mount({ probe: plainProbe });
    const warning = $(".login-warning")!;
    expect(warning.hasAttribute("hidden")).toBe(true);
    await connect("192.168.1.10:8096");
    expect(warning.hasAttribute("hidden")).toBe(false);
    expect(warning.querySelector("strong")!.textContent).toBe("This server isn't encrypted.");
    expect(warning.textContent).toContain(`${PLAIN} answered over plain HTTP`);
    expect(submitButton().textContent).toBe("Connect anyway");
    expect(submitButton().disabled).toBe(false);
    // Nothing has been asked of the server itself yet.
    expect(publicCalls("/")).toHaveLength(0);
    expect(userInput()).toBeNull();
  });

  it("carries on once Connect anyway is pressed", async () => {
    await mount({ probe: plainProbe });
    await connect("192.168.1.10:8096");
    submitButton().click();
    await settle();
    expect(invokeCalls("jf_probe")).toHaveLength(2);
    expect(userInput()).not.toBeNull();
    expect($(".sync-pill")!.textContent).toBe("Not encrypted");
  });

  it("withdraws the agreement when the address is edited, even to the same server", async () => {
    // Two spellings of one address: the probe resolves both to the same URL.
    const probe = deferred();
    let calls = 0;
    await mount({ probe: () => (++calls === 2 ? probe.promise : plainProbe) });
    await connect("192.168.1.10:8096");
    expect(submitButton().textContent).toBe("Connect anyway");
    addressInput().value = PLAIN;
    submitButton().click();
    await settle();
    // While the edited address is being probed the old warning is put away.
    expect($(".login-warning")!.hasAttribute("hidden")).toBe(true);
    expect(submitButton().textContent).toBe("Connecting…");
    probe.resolve(plainProbe);
    await settle();
    // Warned again rather than signed in on the strength of the earlier click.
    expect($(".login-warning")!.hasAttribute("hidden")).toBe(false);
    expect(submitButton().textContent).toBe("Connect anyway");
    expect(userInput()).toBeNull();
    expect(publicCalls("/")).toHaveLength(0);
  });

  it("warns afresh for a different unencrypted server", async () => {
    const other = { ...plainProbe, server: "http://10.0.0.2:8096" };
    await mount({ probe: (typed: string) => (typed === "a" ? plainProbe : other) });
    await connect("a");
    await connect("b");
    expect($(".login-warning")!.textContent).toContain("http://10.0.0.2:8096 answered over plain HTTP");
    expect(userInput()).toBeNull();
  });

  it("keeps offering Connect anyway when the second probe fails", async () => {
    let calls = 0;
    await mount({
      probe: () => {
        if (++calls === 2) throw new Error("offline|Gone quiet");
        return plainProbe;
      },
    });
    await connect("192.168.1.10:8096");
    submitButton().click();
    await settle();
    expect(errorText()).toBe("Gone quiet");
    expect(submitButton().textContent).toBe("Connect anyway");
    expect(submitButton().disabled).toBe(false);
  });
});

describe("login: accounts already on this device", () => {
  it("hides the section when there are none", async () => {
    await mount();
    const box = $(".login-card > .login-section")!;
    expect(box.hasAttribute("hidden")).toBe(true);
    expect(box.children).toHaveLength(0);
  });

  it("hides the section when the backend cannot list them", async () => {
    await mount();
    onInvoke("accounts_list", () => {
      throw new Error("keyring locked");
    });
    const { renderLogin } = await import("../../src/views/login");
    renderLogin(root, onSuccess);
    await settle();
    expect($(".login-card > .login-section")!.hasAttribute("hidden")).toBe(true);
  });

  it("lists every saved account with its name, server and picture", async () => {
    await mount({
      accounts: [
        account({ current: true }),
        account({ key: "k2", user_id: "u2", user_name: "", server: PLAIN, server_name: null }),
      ],
    });
    const box = $(".login-card > .login-section")!;
    expect(box.hasAttribute("hidden")).toBe(false);
    expect(box.querySelector(".login-section-title")!.textContent).toBe("Accounts on this device");
    const rows = Array.from(box.querySelectorAll<HTMLButtonElement>(".login-row"));
    expect(rows.map((r) => r.querySelector(".login-row-name")!.textContent)).toEqual(["ada", "Unnamed user"]);
    // The server's name, or its address without the scheme when it has none.
    expect(rows.map((r) => r.querySelector(".login-row-detail")!.textContent)).toEqual(["Reef", "192.168.1.10:8096"]);
    expect(rows.map((r) => r.title)).toEqual([SECURE, PLAIN]);
    // Initial behind the picture; "?" for a user with no name.
    const avatars = rows.map((r) => r.querySelector(".login-avatar")!);
    expect(avatars.map((a) => a.firstChild!.textContent)).toEqual(["A", "?"]);
    expect(avatars[0]!.querySelector("img")!.getAttribute("src")).toBe(
      `${SECURE}/UserImage?userId=u1&maxWidth=56&quality=90`
    );
    expect((avatars[0] as HTMLElement).style.width).toBe("28px");
  });

  it("drops the picture and keeps the initial when the server has none (404)", async () => {
    await mount({ accounts: [account()] });
    const avatar = $(".login-avatar")!;
    avatar.querySelector("img")!.dispatchEvent(new Event("error"));
    expect(avatar.querySelector("img")).toBeNull();
    expect(avatar.textContent).toBe("A");
  });

  it("continues as an account on a click, with no password", async () => {
    const switched = deferred();
    await mount({ accounts: [account()] });
    onInvoke("account_switch", () => switched.promise);
    // After the switch the backend's config is the new account's.
    onInvoke("config_load", () => ({ server: SECURE, has_token: true, user_id: "u1", user_name: "ada", device_id: "d" }));
    const row = $<HTMLButtonElement>(".login-row")!;
    row.click();
    await settle();
    expect(invokeCalls("account_switch").map((c) => c.args)).toEqual([{ key: "k1" }]);
    expect(row.disabled).toBe(true);
    expect(onSuccess).not.toHaveBeenCalled();
    switched.resolve(null);
    await settle();
    expect(onSuccess).toHaveBeenCalledTimes(1);
    const api = await import("../../src/api");
    expect(api.getSession()?.userId).toBe("u1");
  });

  it("says why and re-enables the row when the account cannot be opened", async () => {
    await mount({ accounts: [account()] });
    onInvoke("account_switch", () => {
      throw new Error("auth|That account's sign-in has expired");
    });
    const row = $<HTMLButtonElement>(".login-row")!;
    row.click();
    await settle();
    expect(errorText()).toBe("That account's sign-in has expired");
    expect(row.disabled).toBe(false);
    expect(onSuccess).not.toHaveBeenCalled();
  });

  it("does not draw accounts that arrive after the step was left (stale list)", async () => {
    const list = deferred<any[]>();
    await mount();
    onInvoke("accounts_list", () => list.promise);
    const { renderLogin } = await import("../../src/views/login");
    renderLogin(root, onSuccess);
    const oldBox = $(".login-card > .login-section")!;
    renderLogin(root, onSuccess); // redrawn before the list came back
    list.resolve([account()]);
    await settle();
    expect(oldBox.hasAttribute("hidden")).toBe(true);
    expect(oldBox.children).toHaveLength(0);
  });
});

describe("login: adding an account while one is in use", () => {
  it("says so, offers Cancel, and leaves out the account in use", async () => {
    const onCancel = vi.fn();
    const card = await mount(
      {
        signedIn: true,
        accounts: [account({ current: true }), account({ key: "k2", user_id: "u2", user_name: "grace" })],
      },
      { adding: true, onCancel }
    );
    expect(card.querySelector("h1")!.textContent).toBe("Add an Account");
    expect(card.querySelector(".login-hint.center")!.textContent).toContain("without signing this one out");
    expect(texts(".login-card > .login-section .login-row-name")).toEqual(["grace"]);
    button("Cancel").click();
    expect(onCancel).toHaveBeenCalledTimes(1);
  });

  it("hides the accounts section when the only account is the one in use", async () => {
    await mount({ signedIn: true, accounts: [account({ current: true })] }, { adding: true });
    expect($(".login-card > .login-section")!.hasAttribute("hidden")).toBe(true);
  });

  it("starts from the current server's address", async () => {
    await mount({ signedIn: true }, { adding: true });
    expect(addressInput().value).toBe("http://jf.test:8096");
  });

  it("Cancel without an onCancel does nothing", async () => {
    await mount({ signedIn: true }, { adding: true });
    expect(() => button("Cancel").click()).not.toThrow();
  });

  it("keeps Cancel on the sign-in step", async () => {
    const onCancel = vi.fn();
    await mount({ signedIn: true, probe: secureProbe }, { adding: true, onCancel });
    await connect("jf.test");
    expect(userInput()).not.toBeNull();
    button("Cancel").click();
    expect(onCancel).toHaveBeenCalledTimes(1);
  });
});

describe("login: servers to pick from", () => {
  const serverRows = (): HTMLButtonElement[] => $$(".login-form .login-section .login-row") as HTMLButtonElement[];
  const titles = (): string[] => texts(".login-form .login-section .login-section-title");

  it("lists servers signed in to before, named or by address", async () => {
    await mount({
      config: {
        known_servers: [{ server: SECURE, name: "Reef" }, { server: PLAIN }, { name: "no address" }],
      },
    });
    expect(titles()).toEqual(["Signed in to before"]);
    expect(serverRows().map((r) => r.querySelector(".login-row-name")!.textContent)).toEqual(["Reef", "192.168.1.10:8096"]);
    expect(serverRows().map((r) => r.querySelector(".login-row-detail")!.textContent)).toEqual(["jf.test", "192.168.1.10:8096"]);
    expect(serverRows().map((r) => r.title)).toEqual([SECURE, PLAIN]);
  });

  it("puts a picked server in the field and connects", async () => {
    await mount({ config: { known_servers: [{ server: SECURE, name: "Reef" }] } });
    serverRows()[0]!.click();
    await settle();
    expect(invokeCalls("jf_probe").map((c) => c.args)).toEqual([{ server: SECURE }]);
    expect(userInput()).not.toBeNull();
  });

  it("says it is looking until the broadcast has been answered, then lists what it found", async () => {
    const found = deferred<any[]>();
    await mount();
    onInvoke("jf_discover", () => found.promise);
    const { renderLogin } = await import("../../src/views/login");
    renderLogin(root, onSuccess);
    await settle();
    expect(texts(".login-form .login-section .login-hint")).toEqual(["Looking on your network…"]);
    expect(serverRows()).toHaveLength(0);
    found.resolve([{ id: "s1", name: "Den", address: "http://192.168.1.20:8096" }]);
    await settle();
    expect(titles()).toEqual(["On your network"]);
    expect(serverRows().map((r) => r.querySelector(".login-row-name")!.textContent)).toEqual(["Den"]);
    expect(serverRows().map((r) => r.querySelector(".login-row-detail")!.textContent)).toEqual(["192.168.1.20:8096"]);
    expect(texts(".login-form .login-section .login-hint")).toEqual([]);
  });

  it("connects to a discovered server on a click", async () => {
    await mount({ discovered: [{ id: "s1", name: "Den", address: "http://192.168.1.20:8096" }], probe: secureProbe });
    serverRows()[0]!.click();
    await settle();
    expect(addressInput()).toBeNull(); // moved on
    expect(invokeCalls("jf_probe")[0]!.args).toEqual({ server: "http://192.168.1.20:8096" });
  });

  it("does not list a discovered server twice when it was signed in to before", async () => {
    await mount({
      config: { known_servers: [{ server: PLAIN, name: "Attic" }] },
      discovered: [
        { id: "s0", name: "Attic", address: PLAIN },
        { id: "s1", name: "Den", address: "http://192.168.1.20:8096" },
      ],
    });
    expect(titles()).toEqual(["Signed in to before", "On your network"]);
    expect(serverRows().map((r) => r.title)).toEqual([PLAIN, "http://192.168.1.20:8096"]);
  });

  it("just stops looking when discovery fails or finds nothing", async () => {
    await mount();
    onInvoke("jf_discover", () => {
      throw new Error("no socket");
    });
    const { renderLogin } = await import("../../src/views/login");
    renderLogin(root, onSuccess);
    await settle();
    expect($(".login-form .login-section")!.children).toHaveLength(0);
  });

  it("does not redraw the list when the answer comes after the step was left (stale discovery)", async () => {
    const found = deferred<any[]>();
    await mount({ probe: secureProbe });
    onInvoke("jf_discover", () => found.promise);
    const { renderLogin } = await import("../../src/views/login");
    renderLogin(root, onSuccess);
    await settle();
    const oldBox = $(".login-form .login-section")!;
    await connect("jf.test"); // on to step 2
    expect(userInput()).not.toBeNull();
    found.resolve([{ id: "s1", name: "Den", address: "http://192.168.1.20:8096" }]);
    await settle();
    expect(oldBox.textContent).toBe("Looking on your network…");
    expect(root.textContent).not.toContain("On your network");
  });
});

// ---------------------------------------------------------------- step 2

describe("login: who is signing in", () => {
  it("shows which server answered and that it is encrypted", async () => {
    const card = await toCredentials();
    expect($(".login-banner-name strong")!.textContent).toBe("Reef");
    const pill = $(".sync-pill")!;
    expect(pill.textContent).toBe("Encrypted");
    expect(pill.classList.contains("ok")).toBe(true);
    expect(texts(".login-banner .login-hint")).toEqual([`Jellyfin 10.10.3 · ${SECURE}`]);
    expect(document.activeElement).toBe(userInput());
    // No Quick Connect on this server: one column, no panel.
    expect(card.classList.contains("wide")).toBe(false);
    expect($(".login-qc")).toBeNull();
    expect(publicCalls("/QuickConnect/Initiate")).toHaveLength(0);
  });

  it("flags an unencrypted server on the banner too", async () => {
    await mount({ probe: { server: PLAIN, secure: false } });
    await connect("x");
    submitButton().click();
    await settle();
    // No name and no version from the probe: the address stands in for both.
    expect($(".login-banner-name strong")!.textContent).toBe("192.168.1.10:8096");
    expect($(".sync-pill")!.classList.contains("warn")).toBe(true);
    expect(texts(".login-banner .login-hint")[0]).toBe(PLAIN);
    expect($(".login-banner .login-hint.warn")!.textContent).toContain("This connection isn't encrypted");
  });

  it("offers the server's public users, in name order", async () => {
    await toCredentials({
      users: [
        { Id: "u2", Name: "grace", HasPassword: false },
        { Id: "u1", Name: "Ada", HasPassword: true },
        { Id: "", Name: "nobody" },
      ],
    });
    expect(texts(".login-people .login-section-title")).toEqual(["Who's signing in?"]);
    const chips = $$(".login-chip");
    expect(chips.map((c) => c.querySelector("span:not(.login-avatar):not(.login-row-detail)")!.textContent)).toEqual(["Ada", "grace"]);
    expect(chips[0]!.querySelector(".login-row-detail")).toBeNull();
    expect(chips[1]!.querySelector(".login-row-detail")!.textContent).toBe("No password");
    expect(chips[0]!.querySelector(".login-avatar img")!.getAttribute("src")).toBe(
      `${SECURE}/UserImage?userId=u1&maxWidth=48&quality=90`
    );
  });

  it("shows no list at all when the administrator hides every user", async () => {
    await toCredentials({ users: [] });
    expect($(".login-people")!.children).toHaveLength(0);
    type(userInput(), "ada");
    expect($(".login-people")!.children).toHaveLength(0);
  });

  it("does not offer people who are already signed in here, only on this server", async () => {
    await toCredentials({
      users: [{ Id: "u1", Name: "Ada" }, { Id: "u2", Name: "Grace" }, { Id: "u3", Name: "Linus" }],
      accounts: [
        account({ user_id: "u1", server: SECURE }),
        // The same id on another server is somebody else.
        account({ key: "k9", user_id: "u2", server: PLAIN }),
      ],
    });
    expect($$(".login-chip").map((c) => c.lastElementChild!.textContent)).toEqual(["Grace", "Linus"]);
  });

  it("narrows the list as a name is typed and marks an exact match", async () => {
    await toCredentials({ users: [{ Id: "u1", Name: "Ada" }, { Id: "u2", Name: "Adam" }, { Id: "u3", Name: "Grace" }] });
    type(userInput(), " AD ");
    expect($$(".login-chip").map((c) => c.lastElementChild!.textContent)).toEqual(["Ada", "Adam"]);
    expect($$(".login-chip.on")).toHaveLength(0);
    type(userInput(), "ada");
    expect($$(".login-chip.on").map((c) => c.lastElementChild!.textContent)).toEqual(["Ada"]);
    type(userInput(), "zz");
    expect($$(".login-chip")).toHaveLength(0);
    expect(texts(".login-people .login-section-title")).toEqual(["Who's signing in?"]);
  });

  it("fills the name in and moves to the password when a person is clicked", async () => {
    await toCredentials({ users: [{ Id: "u1", Name: "Ada" }, { Id: "u3", Name: "Grace" }] });
    submitButton().click(); // leaves "Enter your username." behind
    await settle();
    passInput().value = "left over";
    $$(".login-chip")[1]!.click();
    expect(userInput().value).toBe("Grace");
    expect(passInput().value).toBe("");
    expect(errorText()).toBe("");
    expect(document.activeElement).toBe(passInput());
    expect($$(".login-chip.on").map((c) => c.lastElementChild!.textContent)).toEqual(["Grace"]);
  });

  it("asks for a username before sending anything", async () => {
    await toCredentials();
    type(userInput(), "   ");
    submitButton().click();
    await settle();
    expect(errorText()).toBe("Enter your username.");
    expect(document.activeElement).toBe(userInput());
    expect(invokeCalls("jf_login")).toHaveLength(0);
  });

  it("signs in with the probed server, the trimmed name and the password", async () => {
    const login = deferred();
    await toCredentials();
    onInvoke("jf_login", () => login.promise);
    onInvoke("config_load", () => ({ server: SECURE, has_token: true, user_id: "u1", user_name: "ada", device_id: "d" }));
    type(userInput(), " ada ");
    passInput().value = "pw";
    submitButton().click();
    await settle();
    expect(invokeCalls("jf_login").map((c) => c.args)).toEqual([{ server: SECURE, username: "ada", password: "pw" }]);
    expect(submitButton().textContent).toBe("Signing in…");
    expect(submitButton().disabled).toBe(true);
    expect(onSuccess).not.toHaveBeenCalled();
    login.resolve({ server: SECURE, user_id: "u1", user_name: "ada", device_id: "d", secure: true });
    await settle();
    expect(onSuccess).toHaveBeenCalledTimes(1);
    expect(submitButton().textContent).toBe("Sign in");
    expect(submitButton().disabled).toBe(false);
    const api = await import("../../src/api");
    expect(api.getSession()).toMatchObject({ server: SECURE, userId: "u1", secure: true });
  });

  it("does not leave the password in the page once signed in (regression: password kept in the DOM)", async () => {
    await toCredentials();
    onInvoke("jf_login", () => ({ server: SECURE, user_id: "u1", user_name: "ada", device_id: "d", secure: true }));
    type(userInput(), "ada");
    passInput().value = "pw";
    submitButton().click();
    await settle();
    expect(onSuccess).toHaveBeenCalledTimes(1);
    expect(passInput().value).toBe("");
  });

  it("shows the server's reason when sign-in is refused, and lets the user try again", async () => {
    await toCredentials();
    onInvoke("jf_login", () => {
      throw new Error("auth|Wrong username or password");
    });
    type(userInput(), "ada");
    passInput().value = "pw";
    submitButton().click();
    await settle();
    expect(errorText()).toBe("Wrong username or password");
    expect(onSuccess).not.toHaveBeenCalled();
    expect(submitButton().textContent).toBe("Sign in");
    expect(submitButton().disabled).toBe(false);
    // The next attempt starts clean.
    const login = deferred();
    onInvoke("jf_login", () => login.promise);
    submitButton().click();
    await settle();
    expect(errorText()).toBe("");
  });

  it("goes back to the address step, with this server filled in", async () => {
    await toCredentials({ qc: true, quick: quickServer([CODE_A]) });
    const card = $(".login-card")!;
    expect(card.classList.contains("wide")).toBe(true);
    button("Use a Different Server…").click();
    expect(addressInput().value).toBe(SECURE);
    expect(card.classList.contains("wide")).toBe(false);
    expect(userInput()).toBeNull();
    expect($(".login-qc")).toBeNull();
  });
});

// ---------------------------------------------------------------- Quick Connect

describe("login: Quick Connect", () => {
  const approved = {
    server: SECURE,
    user_id: "u7",
    user_name: "grace",
    device_id: "d",
    secure: true,
  };

  async function toQuickConnect(quick: World["quick"], world: World = {}): Promise<HTMLElement> {
    vi.useFakeTimers();
    await toCredentials({ qc: true, quick, ...world });
    return $(".login-qc")!;
  }

  const codeBox = (): HTMLElement => $(".login-qc-code")!;
  const advance = async (ms: number): Promise<void> => {
    await vi.advanceTimersByTimeAsync(ms);
    await settle();
  };

  it("widens the card and shows a code beside the password form, split for reading out", async () => {
    const panel = await toQuickConnect(quickServer([CODE_A]));
    expect($(".login-card")!.classList.contains("wide")).toBe(true);
    expect($(".login-columns")!.children).toHaveLength(2);
    expect(panel.querySelector(".login-section-title")!.textContent).toBe("Quick Connect");
    expect(codeBox().textContent).toBe("123 456");
    expect(codeBox().getAttribute("aria-label")).toBe("Quick Connect code 1 2 3 4 5 6");
    expect(codeBox().classList.contains("expired")).toBe(false);
    const hints = texts(".login-qc .login-hint");
    expect(hints[0]).toBe("Waiting for the code to be approved…");
    expect(hints[1]).toMatch(/^Expires around .+\.$/);
    expect(hints[2]).toContain("already signed in to Reef");
    expect(hasButton("Copy Code")).toBe(true);
    expect(button("Get New Code").disabled).toBe(false);
    // Asked for with a POST, of the probed server.
    expect(publicCalls("/QuickConnect/Initiate").map((c) => c.args)).toEqual([
      { server: SECURE, path: "/QuickConnect/Initiate", method: "POST" },
    ]);
  });

  it("shows a code that is not six digits as it came", async () => {
    await toQuickConnect(quickServer([{ Secret: "s", Code: "12345678" }]));
    expect(codeBox().textContent).toBe("12345678");
  });

  it("names the server generically when it has no name", async () => {
    await toQuickConnect(quickServer([CODE_A]), { probe: { server: SECURE, secure: true } });
    expect(texts(".login-qc .login-hint").pop()).toContain("already signed in to this server");
  });

  it("says it is getting a code, with Get New Code off, until the server answers", async () => {
    const start = deferred();
    const panel = await toQuickConnect((a) =>
      a.path === "/QuickConnect/Initiate" ? start.promise : { status: 200, body: { Authenticated: false } }
    );
    expect(codeBox().textContent).toBe("Getting a code…");
    expect(codeBox().classList.contains("pending")).toBe(true);
    expect(button("Get New Code").disabled).toBe(true);
    expect(hasButton("Copy Code")).toBe(false);
    // A second press while one request is out does not start another.
    button("Get New Code").disabled = false;
    button("Get New Code").click();
    await settle();
    expect(publicCalls("/QuickConnect/Initiate")).toHaveLength(1);
    start.resolve({ status: 200, body: CODE_A });
    await settle();
    expect(panel.querySelector(".login-qc-code")!.textContent).toBe("123 456");
  });

  it("falls back to GET for a server older than 10.9 (405 to the POST)", async () => {
    await toQuickConnect((a) => {
      if (a.path !== "/QuickConnect/Initiate") return { status: 200, body: { Authenticated: false } };
      return a.method === "POST" ? { status: 405, body: null } : { status: 200, body: CODE_A };
    });
    expect(publicCalls("/QuickConnect/Initiate").map((c) => c.args.method)).toEqual(["POST", "GET"]);
    expect(codeBox().textContent).toBe("123 456");
  });

  it("says so when the server will not hand out a code, and tries again on Get New Code", async () => {
    let off = true;
    await toQuickConnect((a) => {
      if (a.path === "/QuickConnect/Initiate") return off ? { status: 401, body: null } : { status: 200, body: CODE_A };
      return { status: 200, body: { Authenticated: false } };
    });
    expect(codeBox().textContent).toBe("—");
    expect(texts(".login-qc .login-error")).toEqual(["Quick Connect is turned off on this server"]);
    expect(hasButton("Copy Code")).toBe(false);
    await advance(10_000);
    expect(pollCalls()).toHaveLength(0);
    off = false;
    button("Get New Code").click();
    await settle();
    expect(texts(".login-qc .login-error")).toEqual([]);
    expect(codeBox().textContent).toBe("123 456");
  });

  it("asks every 3 seconds whether the code has been approved", async () => {
    await toQuickConnect(quickServer([CODE_A]));
    await advance(2_999);
    expect(pollCalls()).toHaveLength(0);
    await advance(1);
    expect(polledSecrets()).toEqual(["secret-a"]);
    expect(pollCalls()[0]!.args.server).toBe(SECURE);
    await advance(6_000);
    expect(polledSecrets()).toEqual(["secret-a", "secret-a", "secret-a"]);
    expect(onSuccess).not.toHaveBeenCalled();
    expect(invokeCalls("jf_login_quick_connect")).toHaveLength(0);
  });

  it("signs in by itself the moment the code is approved, and stops asking", async () => {
    let ok = false;
    await toQuickConnect(quickServer([CODE_A], () => ({ status: 200, body: { Authenticated: ok } })));
    onInvoke("jf_login_quick_connect", () => approved);
    onInvoke("config_load", () => ({ server: SECURE, has_token: true, user_id: "u7", user_name: "grace", device_id: "d" }));
    await advance(3_000);
    expect(onSuccess).not.toHaveBeenCalled();
    ok = true;
    await advance(3_000);
    expect(invokeCalls("jf_login_quick_connect").map((c) => c.args)).toEqual([{ server: SECURE, secret: "secret-a" }]);
    expect(onSuccess).toHaveBeenCalledTimes(1);
    const api = await import("../../src/api");
    expect(api.getSession()?.userId).toBe("u7");
    const polls = pollCalls().length;
    await advance(30_000);
    expect(pollCalls()).toHaveLength(polls);
    expect(onSuccess).toHaveBeenCalledTimes(1);
  });

  it("keeps asking after one poll fails (regression: one failed poll is not the end of the request)", async () => {
    let n = 0;
    await toQuickConnect(
      quickServer([CODE_A], () => {
        n++;
        if (n === 1) throw new Error("offline|blip");
        if (n === 2) return { status: 500, body: null };
        return { status: 200, body: { Authenticated: true } };
      })
    );
    onInvoke("jf_login_quick_connect", () => approved);
    await advance(6_000);
    expect(codeBox().classList.contains("expired")).toBe(false);
    expect(texts(".login-qc .login-error")).toEqual([]);
    await advance(3_000);
    expect(onSuccess).toHaveBeenCalledTimes(1);
  });

  it("marks the code expired when the server has forgotten it (404), and stops asking", async () => {
    await toQuickConnect(quickServer([CODE_A], () => ({ status: 404, body: null })));
    await advance(3_000);
    expect(codeBox().classList.contains("expired")).toBe(true);
    expect(codeBox().textContent).toBe("123 456");
    expect(texts(".login-qc .login-hint.warn")).toEqual(["That code has expired."]);
    expect(hasButton("Copy Code")).toBe(false);
    expect(root.textContent).not.toContain("Waiting for the code to be approved");
    await advance(30_000);
    expect(pollCalls()).toHaveLength(1);
    expect(onSuccess).not.toHaveBeenCalled();
  });

  it("gives up on a code ten minutes old even while the server still answers for it", async () => {
    await toQuickConnect(quickServer([CODE_A]));
    await advance(10 * 60_000 + 30_000);
    expect(codeBox().classList.contains("expired")).toBe(false);
    await advance(3_000);
    expect(codeBox().classList.contains("expired")).toBe(true);
    const polls = pollCalls().length;
    await advance(30_000);
    expect(pollCalls()).toHaveLength(polls);
  });

  it("gets a new code on request and polls only for that one", async () => {
    await toQuickConnect(quickServer([CODE_A, CODE_B]));
    await advance(3_000);
    expect(polledSecrets()).toEqual(["secret-a"]);
    // Replaced mid-wait: the first code's poll is sleeping at this point.
    await advance(1_000);
    button("Get New Code").click();
    await settle();
    expect(codeBox().textContent).toBe("654 321");
    await advance(9_000);
    expect(polledSecrets().slice(1).every((s) => s === "secret-b")).toBe(true);
    // One poller, not two: 3 polls in the 9 seconds after the new code.
    expect(polledSecrets()).toEqual(["secret-a", "secret-b", "secret-b", "secret-b"]);
  });

  it("revives an expired code's panel with Get New Code", async () => {
    let gone = true;
    await toQuickConnect(
      quickServer([CODE_A, CODE_B], () => (gone ? { status: 404, body: null } : { status: 200, body: { Authenticated: false } }))
    );
    await advance(3_000);
    expect(codeBox().classList.contains("expired")).toBe(true);
    gone = false;
    button("Get New Code").click();
    await settle();
    expect(codeBox().classList.contains("expired")).toBe(false);
    expect(codeBox().textContent).toBe("654 321");
    expect(hasButton("Copy Code")).toBe(true);
    await advance(3_000);
    expect(polledSecrets()).toEqual(["secret-a", "secret-b"]);
  });

  it("asks for a new code when an approved one cannot be turned into a session", async () => {
    await toQuickConnect(quickServer([CODE_A], () => ({ status: 200, body: { Authenticated: true } })));
    onInvoke("jf_login_quick_connect", () => {
      throw new Error("auth|The server refused the code");
    });
    await advance(3_000);
    expect(onSuccess).not.toHaveBeenCalled();
    expect(texts(".login-qc .login-error")).toEqual(["The server refused the code"]);
    // An approved code is spent: it is shown as expired and not offered for copying.
    expect(codeBox().classList.contains("expired")).toBe(true);
    expect(hasButton("Copy Code")).toBe(false);
    await advance(30_000);
    expect(pollCalls()).toHaveLength(1);
  });

  it("copies the code, without the space, and says so", async () => {
    const writeText = vi.fn(async (_: string) => {});
    Object.defineProperty(navigator, "clipboard", { value: { writeText }, configurable: true });
    await toQuickConnect(quickServer([CODE_A]));
    button("Copy Code").click();
    await settle();
    expect(writeText).toHaveBeenCalledWith("123456");
    expect(Array.from(document.querySelectorAll("#toasts .toast")).map((t) => t.textContent)).toEqual(["Code copied"]);
  });

  it("says so when the clipboard refuses", async () => {
    const writeText = vi.fn(async (_: string) => {
      throw new Error("denied");
    });
    Object.defineProperty(navigator, "clipboard", { value: { writeText }, configurable: true });
    await toQuickConnect(quickServer([CODE_A]));
    button("Copy Code").click();
    await settle();
    const toast = document.querySelector("#toasts .toast")!;
    expect(toast.textContent).toBe("Couldn't copy the code");
    expect(toast.classList.contains("error")).toBe(true);
  });

  it("stops polling when the user goes back to pick another server", async () => {
    await toQuickConnect(quickServer([CODE_A]));
    await advance(3_000);
    button("Use a Different Server…").click();
    await advance(30_000);
    expect(pollCalls()).toHaveLength(1);
  });

  it("stops polling when the sign-in screen is taken off the page", async () => {
    await toQuickConnect(quickServer([CODE_A]));
    await advance(3_000);
    root.remove();
    await advance(30_000);
    expect(pollCalls()).toHaveLength(1);
    expect(invokeCalls("jf_login_quick_connect")).toHaveLength(0);
  });

  it("stops polling once the password form has signed in", async () => {
    await toQuickConnect(quickServer([CODE_A]));
    onInvoke("jf_login", () => ({ server: SECURE, user_id: "u1", user_name: "ada", device_id: "d", secure: true }));
    type(userInput(), "ada");
    passInput().value = "pw";
    submitButton().click();
    await settle();
    expect(onSuccess).toHaveBeenCalledTimes(1);
    await advance(30_000);
    expect(pollCalls()).toHaveLength(0);
    expect(invokeCalls("jf_login_quick_connect")).toHaveLength(0);
    expect(onSuccess).toHaveBeenCalledTimes(1);
  });

  it("does not sign in on an approval that arrives after the screen was left (stale poll)", async () => {
    const answer = deferred();
    await toQuickConnect(quickServer([CODE_A], () => answer.promise));
    onInvoke("jf_login_quick_connect", () => approved);
    await advance(3_000);
    expect(pollCalls()).toHaveLength(1);
    button("Use a Different Server…").click();
    answer.resolve({ status: 200, body: { Authenticated: true } });
    await advance(10_000);
    expect(invokeCalls("jf_login_quick_connect")).toHaveLength(0);
    expect(onSuccess).not.toHaveBeenCalled();
  });

  it("does not start polling for a code that arrives after the screen was left", async () => {
    const start = deferred();
    await toQuickConnect((a) =>
      a.path === "/QuickConnect/Initiate" ? start.promise : { status: 200, body: { Authenticated: false } }
    );
    button("Use a Different Server…").click();
    start.resolve({ status: 200, body: CODE_A });
    await advance(30_000);
    expect(pollCalls()).toHaveLength(0);
  });
});
