// api.ts: the bridge call itself, errors, connectivity, config, sign-in and
// sign-out, Quick Connect, discovery and saved accounts.
import { beforeEach, describe, expect, it } from "vitest";
import { capture, flush, fresh, invokeCalls, jfCalls, onInvoke, signIn, signedInConfig } from "../helpers/api";

type Api = typeof import("../../src/api");

beforeEach(fresh);

/** The api module with nobody signed in. */
async function signedOut(config: Record<string, any> = {}): Promise<Api> {
  onInvoke("config_load", () => ({ ...config }));
  const api = await import("../../src/api");
  await api.loadConfig();
  return api;
}

function ok(body: any = {}): { status: number; body: any } {
  return { status: 200, body };
}

describe("api(): the request handed to the bridge", () => {
  it("sends the path with GET and a null body by default", async () => {
    const api = await signIn();
    onInvoke("jf_request", ok({ hello: 1 }));
    await expect(api.api("/System/Info")).resolves.toEqual({ hello: 1 });
    expect(jfCalls()).toEqual([{ path: "/System/Info", method: "GET", body: null }]);
  });

  it("passes the method and body through untouched", async () => {
    const api = await signIn();
    onInvoke("jf_request", ok(null));
    await api.api("/Thing", { method: "POST", body: { a: [1, 2] } });
    expect(jfCalls()).toEqual([{ path: "/Thing", method: "POST", body: { a: [1, 2] } }]);
  });

  it("never carries a token or an auth header: the bridge adds the credential", async () => {
    const api = await signIn();
    onInvoke("jf_request", ok({}));
    await api.api("/Items?userId=user-1");
    const args = invokeCalls("jf_request")[0]!.args;
    expect(Object.keys(args).sort()).toEqual(["body", "method", "path"]);
    expect(JSON.stringify(args)).not.toMatch(/token|api_key|X-Emby/i);
  });

  it("returns the body of any 2xx, including an empty 204", async () => {
    const api = await signIn();
    onInvoke("jf_request", { status: 204, body: null });
    await expect(api.api("/x", { method: "DELETE" })).resolves.toBeNull();
  });

  it("turns another status into an error naming the route without its query", async () => {
    const api = await signIn();
    onInvoke("jf_request", { status: 500, body: null });
    await expect(api.api("/Items?userId=user-1&Limit=3")).rejects.toThrow("Server error 500 on /Items");
    onInvoke("jf_request", { status: 199, body: null });
    await expect(api.api("/Low")).rejects.toThrow("Server error 199 on /Low");
    onInvoke("jf_request", { status: 300, body: null });
    await expect(api.api("/High")).rejects.toThrow("Server error 300 on /High");
  });
});

describe("errors from Rust arrive as kind|message", () => {
  it.each([
    ["auth|No saved sign-in", "No saved sign-in"],
    ["config|Could not read the settings file", "Could not read the settings file"],
    ["server|Bad gateway | upstream", "Bad gateway | upstream"],
    ["offline|Server unreachable", "Server unreachable"],
    ["identity|This is a different server", "This is a different server"],
  ])("strips the kind from %s", async (raw, message) => {
    const api = await signIn();
    onInvoke("jf_ping", true);
    onInvoke("jf_request", () => {
      throw raw;
    });
    await expect(api.api("/x")).rejects.toThrow(new Error(message));
  });

  it("keeps the whole text when the prefix is not a known kind", async () => {
    const api = await signIn();
    onInvoke("jf_request", () => {
      throw "weird|thing happened";
    });
    await expect(api.api("/x")).rejects.toThrow(new Error("weird|thing happened"));
  });

  it("keeps the whole text when it starts with the separator or has none", async () => {
    const api = await signIn();
    onInvoke("jf_request", () => {
      throw "|odd";
    });
    await expect(api.api("/x")).rejects.toThrow(new Error("|odd"));
    onInvoke("jf_request", () => {
      throw "plain failure";
    });
    await expect(api.api("/x")).rejects.toThrow(new Error("plain failure"));
  });

  it("reads an Error object's message and a non-string value alike", async () => {
    const api = await signIn();
    onInvoke("jf_request", () => {
      throw new Error("auth|Token missing");
    });
    await expect(api.api("/x")).rejects.toThrow(new Error("Token missing"));
    onInvoke("jf_request", () => {
      throw 42;
    });
    await expect(api.api("/x")).rejects.toThrow(new Error("42"));
  });

  it("does not treat an ordinary failure as offline or as an identity change", async () => {
    const api = await signIn();
    const identity = capture("aquarium-server-identity");
    onInvoke("jf_request", () => {
      throw "server|Bad gateway";
    });
    await expect(api.api("/x")).rejects.toThrow("Bad gateway");
    await flush();
    expect(invokeCalls("jf_ping")).toHaveLength(0);
    expect(api.isOffline()).toBe(false);
    expect(identity).toEqual([]);
  });
});

describe("offline detection", () => {
  it("starts online", async () => {
    const api = await signIn();
    expect(api.isOffline()).toBe(false);
  });

  it("a failed request alone does not flip to offline; one probe decides (regression: a wake or Wi-Fi hand-off put the app offline on a single failure)", async () => {
    const api = await signIn();
    const seen = capture("aquarium-connectivity");
    onInvoke("jf_ping", true);
    onInvoke("jf_request", () => {
      throw "offline|Server unreachable";
    });
    await expect(api.api("/x")).rejects.toThrow("Server unreachable");
    await flush();
    expect(invokeCalls("jf_ping")).toHaveLength(1);
    expect(api.isOffline()).toBe(false);
    expect(seen).toEqual([]);
  });

  it("goes offline, and says so once, when the probe fails too", async () => {
    const api = await signIn();
    const seen = capture("aquarium-connectivity");
    onInvoke("jf_ping", false);
    onInvoke("jf_request", () => {
      throw "offline|Server unreachable";
    });
    await expect(api.api("/x")).rejects.toThrow("Server unreachable");
    await flush();
    expect(api.isOffline()).toBe(true);
    expect(seen).toEqual([{ offline: true }]);
  });

  it("a burst of failing requests shares a single probe", async () => {
    const api = await signIn();
    const seen = capture("aquarium-connectivity");
    let release!: (v: boolean) => void;
    onInvoke("jf_ping", () => new Promise<boolean>((r) => (release = r)));
    onInvoke("jf_request", () => {
      throw "offline|Server unreachable";
    });
    const results = await Promise.allSettled([api.api("/a"), api.api("/b"), api.api("/c"), api.api("/d")]);
    expect(results.every((r) => r.status === "rejected")).toBe(true);
    await flush();
    expect(invokeCalls("jf_ping")).toHaveLength(1);
    // The verdict waits for the probe.
    expect(api.isOffline()).toBe(false);
    release(false);
    await flush();
    expect(api.isOffline()).toBe(true);
    expect(seen).toEqual([{ offline: true }]);
  });

  it("starts a fresh probe for a failure after the last probe finished", async () => {
    const api = await signIn();
    onInvoke("jf_ping", true);
    onInvoke("jf_request", () => {
      throw "offline|Server unreachable";
    });
    await api.api("/a").catch(() => {});
    await flush();
    await api.api("/b").catch(() => {});
    await flush();
    expect(invokeCalls("jf_ping")).toHaveLength(2);
  });

  it("does not probe again while already offline", async () => {
    const api = await signIn();
    onInvoke("jf_ping", false);
    onInvoke("jf_request", () => {
      throw "offline|Server unreachable";
    });
    await api.api("/a").catch(() => {});
    await flush();
    expect(api.isOffline()).toBe(true);
    await api.api("/b").catch(() => {});
    await flush();
    expect(invokeCalls("jf_ping")).toHaveLength(1);
  });

  it("does not probe when nobody is signed in", async () => {
    const api = await signedOut();
    onInvoke("jf_request", () => {
      throw "offline|Server unreachable";
    });
    await expect(api.api("/x")).rejects.toThrow("Server unreachable");
    await flush();
    expect(invokeCalls("jf_ping")).toHaveLength(0);
    expect(api.isOffline()).toBe(false);
  });

  it("any answered request, even an error status, brings the app back online", async () => {
    const api = await signIn();
    const seen = capture("aquarium-connectivity");
    onInvoke("jf_ping", false);
    onInvoke("jf_request", () => {
      throw "offline|Server unreachable";
    });
    await api.api("/a").catch(() => {});
    await flush();
    onInvoke("jf_request", { status: 500, body: null });
    await api.api("/b").catch(() => {});
    expect(api.isOffline()).toBe(false);
    expect(seen).toEqual([{ offline: true }, { offline: false }]);
  });

  it("a probe that throws counts as offline", async () => {
    const api = await signIn();
    onInvoke("jf_ping", () => {
      throw "offline|no route";
    });
    await expect(api.checkOnline()).resolves.toBe(false);
    expect(api.isOffline()).toBe(true);
  });
});

describe("checkOnline", () => {
  it("answers false without asking when nobody is signed in", async () => {
    const api = await signedOut();
    await expect(api.checkOnline()).resolves.toBe(false);
    expect(invokeCalls("jf_ping")).toHaveLength(0);
    expect(api.isOffline()).toBe(false);
  });

  it("reports the probe's answer and updates the flag both ways", async () => {
    const api = await signIn();
    const seen = capture("aquarium-connectivity");
    onInvoke("jf_ping", false);
    await expect(api.checkOnline()).resolves.toBe(false);
    expect(api.isOffline()).toBe(true);
    onInvoke("jf_ping", true);
    await expect(api.checkOnline()).resolves.toBe(true);
    expect(api.isOffline()).toBe(false);
    expect(seen).toEqual([{ offline: true }, { offline: false }]);
  });

  it("does not repeat the announcement when the state has not changed", async () => {
    const api = await signIn();
    const seen = capture("aquarium-connectivity");
    onInvoke("jf_ping", false);
    await api.checkOnline();
    await api.checkOnline();
    expect(seen).toEqual([{ offline: true }]);
  });

  it("announces a changed server identity instead of going offline", async () => {
    const api = await signIn();
    const identity = capture("aquarium-server-identity");
    const conn = capture("aquarium-connectivity");
    onInvoke("jf_ping", () => {
      throw "identity|The saved address now answers as another server";
    });
    await expect(api.checkOnline()).resolves.toBe(false);
    expect(identity).toEqual([{ message: "The saved address now answers as another server" }]);
    expect(api.isOffline()).toBe(false);
    expect(conn).toEqual([]);
  });
});

describe("server identity change on a request", () => {
  it("announces it, fails the request, and does not degrade to offline mode", async () => {
    const api = await signIn();
    const identity = capture("aquarium-server-identity");
    onInvoke("jf_request", () => {
      throw "identity|That is not the server you signed in to";
    });
    await expect(api.api("/x")).rejects.toThrow("That is not the server you signed in to");
    await flush();
    expect(identity).toEqual([{ message: "That is not the server you signed in to" }]);
    expect(invokeCalls("jf_ping")).toHaveLength(0);
    expect(api.isOffline()).toBe(false);
  });
});

describe("401: the session has expired", () => {
  /** Sign in with a bridge whose sign-out really signs the config out. */
  async function expiring(): Promise<Api> {
    const api = await signIn();
    let out = false;
    onInvoke("config_load", () => (out ? {} : signedInConfig()));
    onInvoke("jf_logout", () => {
      out = true;
      return { revoked: true, pending: false };
    });
    return api;
  }

  it("tears the session down, announces it and fails with a sign-in message (regression: every page failed with its own Server error 401)", async () => {
    const api = await expiring();
    const expired = capture("aquarium-auth-expired");
    onInvoke("jf_request", { status: 401, body: null });
    await expect(api.api("/UserViews?userId=user-1")).rejects.toThrow(
      "Your session has expired — please sign in again"
    );
    expect(invokeCalls("jf_logout")).toHaveLength(1);
    expect(api.getSession()).toBeNull();
    expect(expired).toHaveLength(1);
  });

  it("announces once for a page's worth of simultaneous 401s", async () => {
    const api = await expiring();
    const expired = capture("aquarium-auth-expired");
    onInvoke("jf_request", { status: 401, body: null });
    const results = await Promise.allSettled([api.api("/a"), api.api("/b"), api.api("/c")]);
    expect(results.every((r) => r.status === "rejected")).toBe(true);
    await flush();
    expect(expired).toHaveLength(1);
    expect(invokeCalls("jf_logout")).toHaveLength(1);
  });

  it("still shows the sign-in route when the teardown itself fails", async () => {
    const api = await signIn();
    const expired = capture("aquarium-auth-expired");
    onInvoke("jf_logout", () => {
      throw "offline|gone";
    });
    onInvoke("jf_request", { status: 401, body: null });
    await expect(api.api("/a")).rejects.toThrow("session has expired");
    expect(expired).toHaveLength(1);
    expect(api.getSession()).toBeNull();
  });

  it("can expire again after a new sign-in", async () => {
    const api = await expiring();
    const expired = capture("aquarium-auth-expired");
    onInvoke("jf_request", { status: 401, body: null });
    await api.api("/a").catch(() => {});
    onInvoke("config_load", () => signedInConfig());
    await api.loadConfig();
    await expect(api.api("/b")).rejects.toThrow("session has expired");
    expect(expired).toHaveLength(2);
  });

  it("is an ordinary server error when nobody is signed in", async () => {
    const api = await signedOut();
    const expired = capture("aquarium-auth-expired");
    onInvoke("jf_request", { status: 401, body: null });
    await expect(api.api("/Users/Me?x=1")).rejects.toThrow("Server error 401 on /Users/Me");
    expect(expired).toEqual([]);
    expect(invokeCalls("jf_logout")).toHaveLength(0);
  });
});

describe("config", () => {
  it("builds the session from a signed-in config", async () => {
    const api = await signIn();
    expect(api.getSession()).toEqual({
      server: "http://jf.test:8096",
      userId: "user-1",
      userName: "tester",
      deviceId: "device-1",
      secure: false,
    });
    expect(api.getConfig()).toMatchObject({ server: "http://jf.test:8096", has_token: true });
  });

  it("marks an https server secure and tolerates a missing user name", async () => {
    const api = await signIn({ server: "https://jf.test", user_name: undefined });
    expect(api.getSession()).toMatchObject({ secure: true, userName: "", server: "https://jf.test" });
  });

  it.each([
    ["no stored token", { has_token: false }],
    ["no server", { server: "" }],
    ["no user id", { user_id: null }],
  ])("has no session with %s", async (_n, patch) => {
    const api = await signIn(patch);
    expect(api.getSession()).toBeNull();
  });

  it("drops the session when a later load says signed out", async () => {
    const api = await signIn();
    onInvoke("config_load", {});
    await api.loadConfig();
    expect(api.getSession()).toBeNull();
  });

  it("returns what the backend loaded", async () => {
    onInvoke("config_load", { theme: "dark" });
    const api = await import("../../src/api");
    await expect(api.loadConfig()).resolves.toEqual({ theme: "dark" });
    expect(api.getConfig()).toEqual({ theme: "dark" });
  });

  it("saves only the patch, never a whole copy (regression: stale server, user and accounts were written back over newer ones)", async () => {
    const api = await signIn({ theme: "light", known_servers: [{ server: "http://a" }] });
    const saved: any[] = [];
    onInvoke("config_save", (a: any) => {
      saved.push(a);
      return null;
    });
    await api.saveConfig({ theme: "dark" });
    expect(saved).toEqual([{ cfg: { theme: "dark" } }]);
    expect(api.getConfig()).toMatchObject({ theme: "dark", server: "http://jf.test:8096" });
  });

  it("applies the patch locally before the save returns", async () => {
    const api = await signIn();
    let finish!: () => void;
    onInvoke("config_save", () => new Promise<null>((r) => (finish = () => r(null))));
    const p = api.saveConfig({ next_up_days: 30 });
    expect(api.getConfig().next_up_days).toBe(30);
    finish();
    await p;
  });
});

describe("probeServer", () => {
  it("asks the bridge about the address and returns its answer", async () => {
    const api = await signedOut();
    const probe = { server: "https://jf.test", secure: true, server_id: "abc", server_name: "Home", version: "12.2.0" };
    onInvoke("jf_probe", probe);
    await expect(api.probeServer("jf.test")).resolves.toEqual(probe);
    expect(invokeCalls("jf_probe")[0]!.args).toEqual({ server: "jf.test" });
  });

  it("fails with the message only", async () => {
    const api = await signedOut();
    onInvoke("jf_probe", () => {
      throw "offline|Nothing answered at that address";
    });
    await expect(api.probeServer("nope")).rejects.toThrow(new Error("Nothing answered at that address"));
  });
});

const LOGIN_RESULT = {
  server: "https://jf.test",
  user_id: "user-9",
  user_name: "ann",
  device_id: "dev-9",
  secure: true,
};

describe("login", () => {
  it("hands the credentials to the bridge and builds the session from its answer", async () => {
    const api = await signedOut();
    onInvoke("jf_login", LOGIN_RESULT);
    const s = await api.login("jf.test", "ann", "pw");
    expect(invokeCalls("jf_login")[0]!.args).toEqual({ server: "jf.test", username: "ann", password: "pw" });
    expect(s).toEqual({ server: "https://jf.test", userId: "user-9", userName: "ann", deviceId: "dev-9", secure: true });
    expect(api.getSession()).toEqual(s);
  });

  it("reloads the config after signing in", async () => {
    const api = await signedOut();
    onInvoke("jf_login", LOGIN_RESULT);
    onInvoke("config_load", { server: "https://jf.test", known_servers: [{ server: "https://jf.test" }] });
    await api.login("jf.test", "ann", "pw");
    expect(api.knownServers()).toEqual([{ server: "https://jf.test" }]);
  });

  it("never receives or keeps an access token", async () => {
    const api = await signedOut();
    onInvoke("jf_login", LOGIN_RESULT);
    const s = await api.login("jf.test", "ann", "pw");
    expect(Object.keys(s).sort()).toEqual(["deviceId", "secure", "server", "userId", "userName"]);
  });

  it("defaults a missing name and an absent secure flag", async () => {
    const api = await signedOut();
    onInvoke("jf_login", { server: "http://jf.test", user_id: "u", device_id: "d" });
    await expect(api.login("jf.test", "ann", "pw")).resolves.toMatchObject({ userName: "", secure: false });
  });

  it("clears offline mode", async () => {
    const api = await signIn();
    onInvoke("jf_ping", false);
    await api.checkOnline();
    expect(api.isOffline()).toBe(true);
    onInvoke("jf_login", LOGIN_RESULT);
    await api.login("jf.test", "ann", "pw");
    expect(api.isOffline()).toBe(false);
  });

  it("fails with the message and leaves nobody signed in", async () => {
    const api = await signedOut();
    onInvoke("jf_login", () => {
      throw "auth|Wrong user name or password";
    });
    await expect(api.login("jf.test", "ann", "bad")).rejects.toThrow(new Error("Wrong user name or password"));
    expect(api.getSession()).toBeNull();
  });
});

describe("logout", () => {
  it("reports whether the server confirmed the revocation", async () => {
    const api = await signIn();
    onInvoke("jf_logout", { revoked: true, pending: false });
    onInvoke("config_load", {});
    await expect(api.logout()).resolves.toEqual({ revoked: true, pending: false });
    expect(api.getSession()).toBeNull();
  });

  it("says when the revocation is still pending", async () => {
    const api = await signIn();
    onInvoke("jf_logout", { revoked: false, pending: true });
    onInvoke("config_load", {});
    await expect(api.logout()).resolves.toEqual({ revoked: false, pending: true });
  });

  it("treats a bare answer as not revoked", async () => {
    const api = await signIn();
    onInvoke("jf_logout", {});
    onInvoke("config_load", {});
    await expect(api.logout()).resolves.toEqual({ revoked: false, pending: false });
  });

  it("drops the session even when the sign-out fails, and reloads the config", async () => {
    const api = await signIn();
    onInvoke("jf_logout", () => {
      throw "config|Could not clear the keyring";
    });
    let loads = 0;
    onInvoke("config_load", () => {
      loads++;
      return {};
    });
    await expect(api.logout()).rejects.toThrow(new Error("Could not clear the keyring"));
    expect(api.getSession()).toBeNull();
    expect(loads).toBe(1);
  });

  it("survives a config that cannot be reloaded", async () => {
    const api = await signIn();
    onInvoke("jf_logout", { revoked: true });
    onInvoke("config_load", () => {
      throw "config|unreadable";
    });
    await expect(api.logout()).resolves.toEqual({ revoked: true, pending: false });
    expect(api.getSession()).toBeNull();
  });
});

describe("discoverServers", () => {
  it("returns the servers that answered", async () => {
    const api = await signedOut();
    const found = [{ id: "1", name: "Home", address: "http://10.0.0.2:8096" }];
    onInvoke("jf_discover", found);
    await expect(api.discoverServers()).resolves.toEqual(found);
  });

  it("is an empty list when discovery fails", async () => {
    const api = await signedOut();
    onInvoke("jf_discover", () => {
      throw "offline|no socket";
    });
    await expect(api.discoverServers()).resolves.toEqual([]);
  });
});

describe("publicUsers", () => {
  it("asks the named server without a session and sorts names ignoring case", async () => {
    const api = await signedOut();
    onInvoke("jf_public", {
      status: 200,
      body: [
        { Id: "3", Name: "zed" },
        { Id: "1", Name: "Bob", HasPassword: true },
        { Id: "2", Name: "alice" },
      ],
    });
    const users = await api.publicUsers("http://jf.test");
    expect(invokeCalls("jf_public")[0]!.args).toEqual({ server: "http://jf.test", path: "/Users/Public", method: "GET" });
    expect(users.map((u) => u.Name)).toEqual(["alice", "Bob", "zed"]);
    expect(users[1]!.HasPassword).toBe(true);
  });

  it("drops entries without an id or a name", async () => {
    const api = await signedOut();
    onInvoke("jf_public", { status: 200, body: [null, { Id: "1" }, { Name: "x" }, { Id: "2", Name: "ok" }] });
    await expect(api.publicUsers("s")).resolves.toEqual([{ Id: "2", Name: "ok" }]);
  });

  it.each([
    ["another status", { status: 403, body: [] }],
    ["a body that is not a list", { status: 200, body: { Items: [] } }],
  ])("is empty for %s", async (_n, answer) => {
    const api = await signedOut();
    onInvoke("jf_public", answer);
    await expect(api.publicUsers("s")).resolves.toEqual([]);
  });

  it("is empty when the server cannot be reached", async () => {
    const api = await signedOut();
    onInvoke("jf_public", () => {
      throw "offline|down";
    });
    await expect(api.publicUsers("s")).resolves.toEqual([]);
  });
});

describe("Quick Connect, before sign-in", () => {
  it("quickConnectEnabled is true only for a 200 carrying true", async () => {
    const api = await signedOut();
    onInvoke("jf_public", { status: 200, body: true });
    await expect(api.quickConnectEnabled("s")).resolves.toBe(true);
    expect(invokeCalls("jf_public")[0]!.args).toEqual({ server: "s", path: "/QuickConnect/Enabled", method: "GET" });
    onInvoke("jf_public", { status: 200, body: false });
    await expect(api.quickConnectEnabled("s")).resolves.toBe(false);
    onInvoke("jf_public", { status: 200, body: "true" });
    await expect(api.quickConnectEnabled("s")).resolves.toBe(false);
    onInvoke("jf_public", { status: 404, body: true });
    await expect(api.quickConnectEnabled("s")).resolves.toBe(false);
    onInvoke("jf_public", () => {
      throw "offline|down";
    });
    await expect(api.quickConnectEnabled("s")).resolves.toBe(false);
  });

  it("asks for a code with a POST", async () => {
    const api = await signedOut();
    onInvoke("jf_public", { status: 200, body: { Secret: "sec", Code: "123456" } });
    await expect(api.quickConnectInitiate("s")).resolves.toEqual({ secret: "sec", code: "123456" });
    expect(invokeCalls("jf_public").map((c) => c.args)).toEqual([
      { server: "s", path: "/QuickConnect/Initiate", method: "POST" },
    ]);
  });

  it.each([405, 404])("falls back to a GET for a server that answers %i to the POST", async (status) => {
    const api = await signedOut();
    onInvoke("jf_public", (a: any) =>
      a.method === "POST" ? { status, body: null } : { status: 200, body: { Secret: "old", Code: "654321" } }
    );
    await expect(api.quickConnectInitiate("s")).resolves.toEqual({ secret: "old", code: "654321" });
    expect(invokeCalls("jf_public").map((c) => c.args.method)).toEqual(["POST", "GET"]);
  });

  it("explains a 401 as Quick Connect being off", async () => {
    const api = await signedOut();
    onInvoke("jf_public", { status: 401, body: null });
    await expect(api.quickConnectInitiate("s")).rejects.toThrow("Quick Connect is turned off on this server");
  });

  it("reports another failure with its status", async () => {
    const api = await signedOut();
    onInvoke("jf_public", { status: 500, body: null });
    await expect(api.quickConnectInitiate("s")).rejects.toThrow("Quick Connect failed (500)");
  });

  it("fails when the answer has no code or no secret", async () => {
    const api = await signedOut();
    onInvoke("jf_public", { status: 200, body: { Secret: "sec" } });
    await expect(api.quickConnectInitiate("s")).rejects.toThrow("didn't hand out a Quick Connect code");
    onInvoke("jf_public", { status: 200, body: null });
    await expect(api.quickConnectInitiate("s")).rejects.toThrow("didn't hand out a Quick Connect code");
  });

  it("fails with the bridge's message when the server cannot be reached", async () => {
    const api = await signedOut();
    onInvoke("jf_public", () => {
      throw "offline|Nothing answered";
    });
    await expect(api.quickConnectInitiate("s")).rejects.toThrow(new Error("Nothing answered"));
  });

  it("polls the state with the secret escaped", async () => {
    const api = await signedOut();
    onInvoke("jf_public", { status: 200, body: { Authenticated: false } });
    await expect(api.quickConnectState("s", "a b&c=d")).resolves.toBe(false);
    expect(invokeCalls("jf_public")[0]!.args).toEqual({
      server: "s",
      path: "/QuickConnect/Connect?secret=a%20b%26c%3Dd",
      method: "GET",
    });
    onInvoke("jf_public", { status: 200, body: { Authenticated: true } });
    await expect(api.quickConnectState("s", "x")).resolves.toBe(true);
  });

  it("answers null once the server has forgotten the code", async () => {
    const api = await signedOut();
    onInvoke("jf_public", { status: 404, body: null });
    await expect(api.quickConnectState("s", "x")).resolves.toBeNull();
  });

  it("fails on any other status", async () => {
    const api = await signedOut();
    onInvoke("jf_public", { status: 503, body: null });
    await expect(api.quickConnectState("s", "x")).rejects.toThrow("Quick Connect failed (503)");
  });

  it("turns an approved code into a session", async () => {
    const api = await signedOut();
    onInvoke("jf_login_quick_connect", LOGIN_RESULT);
    const s = await api.loginWithQuickConnect("jf.test", "sec");
    expect(invokeCalls("jf_login_quick_connect")[0]!.args).toEqual({ server: "jf.test", secret: "sec" });
    expect(s).toEqual({ server: "https://jf.test", userId: "user-9", userName: "ann", deviceId: "dev-9", secure: true });
    expect(api.getSession()).toEqual(s);
    expect(api.isOffline()).toBe(false);
  });

  it("defaults a missing name on a Quick Connect sign-in", async () => {
    const api = await signedOut();
    onInvoke("jf_login_quick_connect", { server: "http://jf.test", user_id: "u", device_id: "d" });
    await expect(api.loginWithQuickConnect("jf.test", "sec")).resolves.toMatchObject({ userName: "", secure: false });
  });

  it("fails a Quick Connect sign-in with the message only", async () => {
    const api = await signedOut();
    onInvoke("jf_login_quick_connect", () => {
      throw "auth|That code was not approved";
    });
    await expect(api.loginWithQuickConnect("jf.test", "sec")).rejects.toThrow(new Error("That code was not approved"));
    expect(api.getSession()).toBeNull();
  });
});

describe("authorizeQuickConnect: approving another device's code", () => {
  it("posts the digits only", async () => {
    const api = await signIn();
    onInvoke("jf_request", { status: 200, body: true });
    await expect(api.authorizeQuickConnect(" 12-34 56 ")).resolves.toBe(true);
    expect(jfCalls()).toEqual([{ path: "/QuickConnect/Authorize?code=123456", method: "POST", body: null }]);
  });

  it("answers false without asking when there are no digits", async () => {
    const api = await signIn();
    await expect(api.authorizeQuickConnect("abc")).resolves.toBe(false);
    expect(jfCalls()).toEqual([]);
  });

  it.each([404, 400])("answers false for an unknown code (%i)", async (status) => {
    const api = await signIn();
    onInvoke("jf_request", { status, body: null });
    await expect(api.authorizeQuickConnect("111111")).resolves.toBe(false);
  });

  it("answers false when the server says anything but true", async () => {
    const api = await signIn();
    onInvoke("jf_request", { status: 200, body: false });
    await expect(api.authorizeQuickConnect("111111")).resolves.toBe(false);
  });

  it("explains a 403 and a 401, and does not sign the user out for the 401", async () => {
    const api = await signIn();
    const expired = capture("aquarium-auth-expired");
    onInvoke("jf_request", { status: 403, body: null });
    await expect(api.authorizeQuickConnect("111111")).rejects.toThrow("isn't allowed to approve Quick Connect");
    onInvoke("jf_request", { status: 401, body: null });
    await expect(api.authorizeQuickConnect("111111")).rejects.toThrow("Quick Connect is turned off on this server");
    expect(expired).toEqual([]);
    expect(api.getSession()).not.toBeNull();
  });

  it("reports another status, and a bridge failure by its message", async () => {
    const api = await signIn();
    onInvoke("jf_request", { status: 500, body: null });
    await expect(api.authorizeQuickConnect("111111")).rejects.toThrow(new Error("Server error 500"));
    onInvoke("jf_request", () => {
      throw "offline|Server unreachable";
    });
    await expect(api.authorizeQuickConnect("111111")).rejects.toThrow(new Error("Server unreachable"));
  });
});

describe("saved accounts", () => {
  const account = {
    key: "k1",
    server: "http://jf.test:8096",
    user_id: "user-2",
    user_name: "bea",
    current: false,
  };

  it("lists them, and is empty when the list cannot be read", async () => {
    const api = await signIn();
    onInvoke("accounts_list", [account]);
    await expect(api.listAccounts()).resolves.toEqual([account]);
    onInvoke("accounts_list", () => {
      throw "config|unreadable";
    });
    await expect(api.listAccounts()).resolves.toEqual([]);
  });

  it("knownServers returns the entries with an address, in the saved order", async () => {
    const api = await signIn({
      known_servers: [{ server: "http://b", name: "B" }, { name: "no address" }, null, { server: 5 }, { server: "http://a" }],
    });
    expect(api.knownServers()).toEqual([{ server: "http://b", name: "B" }, { server: "http://a" }]);
  });

  it("knownServers is empty when the config has none or something else there", async () => {
    const api = await signIn();
    expect(api.knownServers()).toEqual([]);
    const other = await signIn({ known_servers: "http://a" });
    expect(other.knownServers()).toEqual([]);
  });

  it("switching becomes the account the reloaded config names", async () => {
    const api = await signIn();
    onInvoke("account_switch", null);
    onInvoke("config_load", signedInConfig({ user_id: "user-2", user_name: "bea", server: "https://other.test" }));
    const s = await api.switchAccount("k1");
    expect(invokeCalls("account_switch")[0]!.args).toEqual({ key: "k1" });
    expect(s).toMatchObject({ userId: "user-2", userName: "bea", server: "https://other.test", secure: true });
    expect(api.getSession()).toEqual(s);
  });

  it("switching clears offline mode", async () => {
    const api = await signIn();
    onInvoke("jf_ping", false);
    await api.checkOnline();
    onInvoke("account_switch", null);
    await api.switchAccount("k1");
    expect(api.isOffline()).toBe(false);
  });

  it("switching fails when the backend refuses, keeping the current session", async () => {
    const api = await signIn();
    onInvoke("account_switch", () => {
      throw "auth|That account has no saved sign-in";
    });
    await expect(api.switchAccount("k1")).rejects.toThrow(new Error("That account has no saved sign-in"));
    expect(api.getSession()?.userId).toBe("user-1");
  });

  it("switching fails when the config afterwards holds no session", async () => {
    const api = await signIn();
    onInvoke("account_switch", null);
    onInvoke("config_load", {});
    await expect(api.switchAccount("k1")).rejects.toThrow("That account couldn't be opened");
  });

  it("forgetting reports whether the token was revoked", async () => {
    const api = await signIn();
    onInvoke("account_forget", { revoked: true });
    await expect(api.forgetAccount("k1")).resolves.toEqual({ revoked: true });
    expect(invokeCalls("account_forget")[0]!.args).toEqual({ key: "k1" });
    onInvoke("account_forget", null);
    await expect(api.forgetAccount("k1")).resolves.toEqual({ revoked: false });
    onInvoke("account_forget", () => {
      throw "config|No such account";
    });
    await expect(api.forgetAccount("k1")).rejects.toThrow(new Error("No such account"));
  });

  it("avatarUrl needs no token and defaults to 96 px", async () => {
    const api = await signedOut();
    expect(api.avatarUrl("http://jf.test", "u1")).toBe("http://jf.test/UserImage?userId=u1&maxWidth=96&quality=90");
    expect(api.avatarUrl("http://jf.test", "u1", 200)).toBe("http://jf.test/UserImage?userId=u1&maxWidth=200&quality=90");
  });
});
