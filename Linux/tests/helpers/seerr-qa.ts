// The stand-in Seerr server, for the integration tests.
//
// `Aquarium/Tools/seerr-mock.py` (in the Apple app's folder; one stand-in for
// both apps) answers the parts of Seerr's API the app uses, in the shapes
// Seerr 3.5 gives them, and signs users in through the QA Jellyfin server:
//
//   python3 -I ../Aquarium/Tools/seerr-mock.py     # 127.0.0.1:8197
//
//   AQUARIUM_QA_SEERR      default http://127.0.0.1:8197
//
// This file does, in the test process, what src-tauri/src/seerr.rs does in the
// app: signs in by Quick Connect as the QA account (Seerr asks Jellyfin for a
// code, the account's own Jellyfin session approves it), keeps the session
// cookie on this side, and answers the `seerr_*` commands of the mocked bridge
// with real requests. When the stand-in or the QA server is not there,
// `seerrQa` is null and the suite skips: `describe.skipIf(!seerrQa)`.
import { onInvokes } from "./tauri";
import { qa } from "./qa";

export interface SeerrQa {
  server: string;
  userId: number;
  /** A test control of the stand-in: "reset", "expire", "approve/3", "decline/3". */
  control(path: string): Promise<void>;
  /** Point the mocked bridge's `seerr_*` commands at the stand-in. */
  install(): void;
}

const SERVER = (process.env.AQUARIUM_QA_SEERR ?? "http://127.0.0.1:8197").replace(/\/+$/, "");

/** The refusals the tests meet, worded as `plain_words` in seerr.rs words them. */
function plainWords(status: number, body: any): string {
  const said = String(body?.message ?? body?.error ?? "");
  if (/already exists/i.test(said) || status === 409) return "That has already been requested.";
  if (status === 401 || status === 403) return "This account isn't allowed to do that on Seerr.";
  if (status === 404) return "Seerr doesn't know that title.";
  return said || "Seerr turned that down.";
}

async function raw(
  path: string,
  method = "GET",
  body?: any,
  cookie?: string
): Promise<{ status: number; body: any; cookie: string | null }> {
  const res = await fetch(`${SERVER}/api/v1${path}`, {
    method,
    headers: {
      Accept: "application/json",
      ...(cookie ? { Cookie: `connect.sid=${cookie}` } : {}),
      ...(body != null ? { "Content-Type": "application/json" } : {}),
    },
    body: body != null ? JSON.stringify(body) : undefined,
    redirect: "manual",
  });
  const text = await res.text();
  let parsed: any = null;
  try {
    parsed = text.trim() ? JSON.parse(text) : null;
  } catch {
    parsed = null;
  }
  const set = (res.headers.getSetCookie?.() ?? []).find((c) => c.startsWith("connect.sid="));
  return { status: res.status, body: parsed, cookie: set ? set.split(";")[0]!.slice("connect.sid=".length) : null };
}

async function signIn(): Promise<{ cookie: string; user: any } | null> {
  if (!qa) return null;
  const asked = await raw("/auth/jellyfin/quickconnect/initiate", "POST");
  if (asked.status !== 200 || !asked.body?.code || !asked.body?.secret) return null;
  const approved = await qa.request(`/QuickConnect/Authorize?code=${asked.body.code}`, "POST");
  if (approved.status !== 200 || approved.body !== true) return null;
  const done = await raw("/auth/jellyfin/quickconnect/authenticate", "POST", { secret: asked.body.secret });
  if (done.status !== 200 || !done.cookie) return null;
  return { cookie: done.cookie, user: done.body };
}

async function connect(): Promise<SeerrQa | null> {
  if (!qa || process.env.AQUARIUM_QA_SKIP === "1") return null;
  let settings: any;
  try {
    const res = await fetch(`${SERVER}/api/v1/settings/public`, { signal: AbortSignal.timeout(2500) });
    if (!res.ok) return null;
    settings = await res.json();
  } catch {
    return null;
  }
  let session = await signIn().catch(() => null);
  if (!session) return null;
  const userId: number = session.user?.id ?? 0;

  /** What seerr.rs `call` does: one request with the cookie; on a refusal,
   *  ask who the cookie belongs to, and sign in again if the answer is nobody. */
  const call = async (path: string, method: string, body: any): Promise<{ status: number; body: any }> => {
    let res = await raw(path, method, body ?? undefined, session!.cookie);
    if (res.status === 401 || res.status === 403) {
      const me = await raw("/auth/me", "GET", undefined, session!.cookie);
      if (me.status === 401 || me.status === 403) {
        const fresh = await signIn();
        if (!fresh) throw "reconnect|The connection to Seerr has run out. Reconnect in Settings.";
        session = fresh;
        res = await raw(path, method, body ?? undefined, session.cookie);
      }
    }
    if (res.status < 200 || res.status >= 300) throw `refused|${plainWords(res.status, res.body)}`;
    return { status: res.status, body: res.body };
  };

  const status = (): Record<string, any> => ({
    connected: true,
    server: SERVER,
    host: SERVER.replace(/^https?:\/\//, ""),
    secure: SERVER.startsWith("https://"),
    user_id: userId,
    user_name: session!.user?.displayName ?? qa!.account.name,
    permissions: session!.user?.permissions ?? 0,
    settings,
    needs_reconnect: false,
    storage: "keyring",
  });

  return {
    server: SERVER,
    userId,
    async control(path) {
      await fetch(`${SERVER}/__test/${path}`, { method: "POST" });
    },
    install() {
      onInvokes({
        seerr_status: () => status(),
        seerr_refresh: () => status(),
        seerr_request: (a: { path: string; method?: string; body?: any }) => call(a.path, a.method ?? "GET", a.body),
      });
    },
  };
}

/** The connection, or null when the stand-in Seerr (or the QA Jellyfin it
 *  signs in through) is not there. */
export const seerrQa: SeerrQa | null = await connect();
