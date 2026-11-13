// The live QA Jellyfin server, for the integration tests.
//
// Nothing about the server is in the repository. The address and accounts are
// read at run time:
//
//   AQUARIUM_QA_SERVER     default http://127.0.0.1:8196
//   AQUARIUM_QA_DIR        default ~/Library/Application Support/AquariumQA
//                          (or $XDG_DATA_HOME/AquariumQA elsewhere)
//   AQUARIUM_QA_USER / AQUARIUM_QA_PASSWORD
//                          the account to sign in as; overrides the files below
//   AQUARIUM_QA_WRITE=1    says the env account may have its watch state,
//                          favourites and playlists changed
//
// Without the env account, `suite-linux` from `suite-accounts.txt` is used;
// failing that, `fixtures.json` in the QA folder is asked for a
// Linux account (any account whose name contains "linux"), then
// `device-accounts.txt` (`name=password` lines). An account whose name
// contains "linux" is the Linux suite's own, and the only kind the tests will
// write with. Any other account is used read-only, and the write tests skip.
//
// When the server does not answer, `qa` is null and every integration suite
// skips: `describe.skipIf(!qa)`.
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { afterAll } from "vitest";
import { onInvokes } from "./tauri";

export interface QaAccount {
  name: string;
  password: string;
  /** Tests may change this account's state (and must put it back). */
  writable: boolean;
}

export interface Qa {
  server: string;
  serverId: string;
  version: string;
  account: QaAccount;
  token: string;
  userId: string;
  deviceId: string;
  /** Parsed fixtures.json from the QA folder, or null when there is none. */
  fixtures: any | null;
  /** A raw authenticated request, as server.rs `request` makes it. */
  request(path: string, method?: string, body?: any): Promise<{ status: number; body: any }>;
  /** Point the mocked Tauri bridge at the live server. Call in beforeEach. */
  install(): void;
}

const SERVER = (process.env.AQUARIUM_QA_SERVER ?? "http://127.0.0.1:8196").replace(/\/+$/, "");
// A device id of its own for each test file that signs in. Jellyfin revokes
// every other token a device id holds for the account when that id signs in
// again, so files run in parallel (or two runs at once) sharing one id signed
// each other out mid-run. Each file signs its session out when it finishes
// (below), so the ids leave no device behind on the server.
const DEVICE_ID = `aquarium-linux-vitest-${process.pid}-${Math.random().toString(36).slice(2, 8)}`;

function qaDir(): string {
  if (process.env.AQUARIUM_QA_DIR) return process.env.AQUARIUM_QA_DIR;
  const mac = path.join(os.homedir(), "Library", "Application Support", "AquariumQA");
  if (fs.existsSync(mac)) return mac;
  return path.join(process.env.XDG_DATA_HOME ?? path.join(os.homedir(), ".local", "share"), "AquariumQA");
}

function readFixtures(): any | null {
  try {
    return JSON.parse(fs.readFileSync(path.join(qaDir(), "fixtures.json"), "utf8"));
  } catch {
    return null;
  }
}

/** Every `{name, password}`-shaped object anywhere in the manifest. */
function accountsIn(node: any, out: QaAccount[] = [], key = ""): QaAccount[] {
  if (!node || typeof node !== "object") return out;
  const name = node.name ?? node.username ?? node.user ?? node.Name ?? (typeof node.password === "string" ? key : undefined);
  const password = node.password ?? node.pass ?? node.Password;
  if (typeof name === "string" && typeof password === "string") {
    out.push({ name, password, writable: /linux/i.test(name) });
  }
  for (const [k, v] of Object.entries(node)) {
    if (typeof v === "string" && /linux/i.test(k) && !/[/\\ ]/.test(v) && Array.isArray(node) === false && k !== "name") {
      // `{ "qa-linux": "password" }` maps
      if (!("name" in node) && !("password" in node)) out.push({ name: k, password: v, writable: true });
    } else {
      accountsIn(v, out, k);
    }
  }
  return out;
}

function readAccountFile(file: string): QaAccount[] {
  try {
    return fs
      .readFileSync(path.join(qaDir(), file), "utf8")
      .split("\n")
      .map((l) => l.trim())
      .filter((l) => l && !l.startsWith("#") && l.includes("="))
      .map((l) => {
        const i = l.indexOf("=");
        const name = l.slice(0, i).trim();
        return { name, password: l.slice(i + 1).trim(), writable: /linux/i.test(name) };
      });
  } catch {
    return [];
  }
}

function pickAccount(fixtures: any | null): QaAccount | null {
  if (process.env.AQUARIUM_QA_USER) {
    return {
      name: process.env.AQUARIUM_QA_USER,
      password: process.env.AQUARIUM_QA_PASSWORD ?? "",
      writable: process.env.AQUARIUM_QA_WRITE === "1" || /linux/i.test(process.env.AQUARIUM_QA_USER),
    };
  }
  // suite-accounts.txt holds one account per test suite; `suite-linux` is
  // this one's, and the only one it writes with.
  const suite = readAccountFile("suite-accounts.txt").map((a) => ({ ...a, writable: a.name === "suite-linux" }));
  const own = suite.find((a) => a.writable);
  if (own) return own;
  const all = [...accountsIn(fixtures), ...readAccountFile("device-accounts.txt")];
  // The suite's own account first; otherwise a plain (not parental-limited)
  // device account, read-only.
  return (
    all.find((a) => a.writable) ??
    all.find((a) => a.name === "qa-se") ??
    all.find((a) => !/kid/i.test(a.name)) ??
    null
  );
}

function authHeader(token?: string): string {
  const base = `MediaBrowser Client="Aquarium", Device="Linux", DeviceId="${DEVICE_ID}", Version="0.0.0-test"`;
  return token ? `${base}, Token="${token}"` : base;
}

async function raw(
  p: string,
  method = "GET",
  body?: any,
  token?: string
): Promise<{ status: number; body: any }> {
  const res = await fetch(SERVER + p, {
    method,
    headers: {
      Authorization: authHeader(token),
      ...(body != null ? { "Content-Type": "application/json" } : {}),
    },
    body: body != null ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  let parsed: any = null;
  if (text.trim()) {
    try {
      parsed = JSON.parse(text);
    } catch {
      parsed = null;
    }
  }
  return { status: res.status, body: parsed };
}

async function connect(): Promise<Qa | null> {
  if (process.env.AQUARIUM_QA_SKIP === "1") return null;
  let info: any;
  try {
    const res = await fetch(SERVER + "/System/Info/Public", { signal: AbortSignal.timeout(2500) });
    if (!res.ok) return null;
    info = await res.json();
  } catch {
    return null;
  }
  const fixtures = readFixtures();
  const account = pickAccount(fixtures);
  if (!account) return null;
  let auth: { status: number; body: any };
  try {
    auth = await raw("/Users/AuthenticateByName", "POST", { Username: account.name, Pw: account.password });
  } catch {
    return null;
  }
  if (auth.status !== 200 || !auth.body?.AccessToken) return null;
  const token: string = auth.body.AccessToken;
  const userId: string = auth.body.User.Id;

  const qa: Qa = {
    server: SERVER,
    serverId: info.Id,
    version: info.Version,
    account,
    token,
    userId,
    deviceId: DEVICE_ID,
    fixtures,
    request: (p, method, body) => raw(p, method, body, token),
    install() {
      const cfg: Record<string, any> = {
        server: SERVER,
        has_token: true,
        user_id: userId,
        user_name: account.name,
        device_id: DEVICE_ID,
        server_id: info.Id,
      };
      onInvokes({
        config_load: () => ({ ...cfg }),
        config_save: (a: { cfg: Record<string, any> }) => {
          Object.assign(cfg, a.cfg);
          return null;
        },
        // What server.rs `request` does: add the token, hand back status and
        // parsed body, and fail only when no response came back at all.
        jf_request: async (a: { path: string; method?: string; body?: any }) => {
          try {
            return await raw(a.path, a.method ?? "GET", a.body ?? undefined, token);
          } catch {
            throw "offline|Server unreachable — you appear to be offline";
          }
        },
        jf_public: async (a: { server: string; path: string; method?: string }) =>
          raw(a.path, a.method ?? "GET"),
        jf_ping: async () => (await raw("/System/Info/Public")).status === 200,
        jf_probe: async () => ({
          server: SERVER,
          secure: SERVER.startsWith("https://"),
          server_id: info.Id ?? null,
          server_name: info.ServerName ?? null,
          version: info.Version ?? null,
        }),
      });
    },
  };
  return qa;
}

/** The connection, or null when the QA server is unreachable or no account is known. */
export const qa: Qa | null = await connect();

if (qa) {
  try {
    afterAll(async () => {
      await qa.request("/Sessions/Logout", "POST").catch(() => {});
    });
  } catch {
    /* imported outside a test file: nothing to sign out at the end of */
  }
}

/** True when the tests may change server state with the signed-in account. */
export const qaWritable = !!qa?.account.writable;

/** Sign the api module in to the live server through the mocked bridge. */
export async function qaApi(): Promise<typeof import("../../src/api")> {
  if (!qa) throw new Error("QA server not available");
  qa.install();
  const api = await import("../../src/api");
  await api.loadConfig();
  return api;
}
