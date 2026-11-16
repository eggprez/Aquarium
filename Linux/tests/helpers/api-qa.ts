// Helpers for the api integration suites (tests/integration/api-*.test.ts and
// music-api.test.ts): fixture lookup, the two bridge commands qa.ts doesn't
// forward (`jf_image`, `jf_bitrate_test`), and saving and putting back an
// item's user data so write tests leave the suite account as they found it.
import { expect } from "vitest";
import { qa, qaApi } from "./qa";
import { invokeCalls, onInvoke } from "./tauri";

/** A fixture from fixtures.json → fixtures, by its stable key. */
export function fx(key: string): any {
  const f = qa?.fixtures?.fixtures?.[key];
  if (!f) throw new Error(`fixture ${key} is not in fixtures.json`);
  return f;
}

/** A set (collection or playlist) from fixtures.json → sets, by name. */
export function fxSet(name: string): any {
  const s = qa?.fixtures?.sets?.[name];
  if (!s) throw new Error(`set ${name} is not in fixtures.json`);
  return s;
}

/** A library id from fixtures.json → libraries, by name. */
export function fxLibrary(name: string): string {
  const l = qa?.fixtures?.libraries?.[name];
  if (!l?.id) throw new Error(`library ${name} is not in fixtures.json`);
  return l.id;
}

/** Every episode of a fixture show, specials included, from the manifest. */
export function fxEpisodes(showKey: string): any[] {
  return (fx(showKey).seasons ?? []).flatMap((s: any) => s.episodes ?? []);
}

/** An item looked up by exact name at run time (Recursive, any type given). */
export async function byName(name: string, types: string): Promise<any> {
  const p = new URLSearchParams({ userId: qa!.userId, Recursive: "true", searchTerm: name, IncludeItemTypes: types, Limit: "50" });
  const r = await qa!.request(`/Items?${p}`);
  const hit = (r.body?.Items ?? []).find((i: any) => i.Name === name);
  if (!hit) throw new Error(`no ${types} named ${name} on the QA server`);
  return hit;
}

/** What server.rs `image` does: image paths only, the token in the header,
 *  the bytes back as a data URL. */
async function image(a: { path: string }): Promise<string> {
  const file = a.path.split("?")[0]!.toLowerCase();
  if (!/\.(jpe?g|png|webp)$/.test(file)) throw "config|Not an image path";
  const res = await fetch(qa!.server + a.path, { headers: { Authorization: authHeader() } });
  if (!res.ok) throw `server|Image request failed (${res.status})`;
  const mime = (res.headers.get("content-type") ?? "image/jpeg").split(";")[0]!.trim();
  const bytes = Buffer.from(await res.arrayBuffer());
  return `data:${mime};base64,${bytes.toString("base64")}`;
}

/** What server.rs `bitrate_test` does: time the body of the server's own
 *  bandwidth-test payload; bits per second. */
async function bitrateTest(a: { size: number }): Promise<number> {
  const res = await fetch(`${qa!.server}/Playback/BitrateTest?Size=${a.size}`, { headers: { Authorization: authHeader() } });
  if (!res.ok) throw `server|Bitrate test failed (${res.status})`;
  const started = performance.now();
  const bytes = (await res.arrayBuffer()).byteLength;
  const elapsed = (performance.now() - started) / 1000;
  if (!bytes) throw "server|Bitrate test returned nothing";
  return (bytes * 8) / Math.max(elapsed, 1e-6);
}

/** The header the Rust side sends: the `MediaBrowser` scheme, token inside. */
export function authHeader(): string {
  return `MediaBrowser Client="Aquarium", Device="Linux", DeviceId="${qa!.deviceId}", Version="0.0.0-test", Token="${qa!.token}"`;
}

/** `qaApi()` plus `jf_image` and `jf_bitrate_test` forwarded to the server. */
export async function qaApiFull(): Promise<typeof import("../../src/api")> {
  const api = await qaApi();
  onInvoke("jf_image", image);
  onInvoke("jf_bitrate_test", bitrateTest);
  return api;
}

/** Every bridge call api.ts made, as it made it. */
export function bridgeCalls(): { path: string; method: string; body: any }[] {
  return invokeCalls("jf_request").map((c) => c.args);
}

/**
 * The invariant from Linux/CLAUDE.md, on what api.ts actually handed the
 * bridge: plain `userId=` routes (never `/Users/{id}/...`), and no credential
 * of any kind (no `X-Emby-Token`, no `api_key`, no token) — the backend adds
 * the Authorization header.
 */
export function expectCleanBridgeCalls(): void {
  const calls = bridgeCalls();
  expect(calls.length).toBeGreaterThan(0);
  for (const c of calls) {
    expect(Object.keys(c).sort(), c.path).toEqual(["body", "method", "path"]);
    expect(c.path, c.path).not.toMatch(/^\/Users\//);
    expect(c.path, c.path).not.toMatch(/api_?key|x-emby|token/i);
    expect(c.path, c.path).not.toContain(qa!.token);
    expect(JSON.stringify(c.body ?? null)).not.toContain(qa!.token);
  }
}

/** The parts of an item's UserData a test may change. */
export interface SavedUserData {
  id: string;
  Played: boolean;
  PlayCount: number;
  PlaybackPositionTicks: number;
  IsFavorite: boolean;
  LastPlayedDate: string | null;
}

export async function userData(id: string): Promise<SavedUserData> {
  const r = await qa!.request(`/Items/${id}?userId=${qa!.userId}`);
  if (r.status !== 200) throw new Error(`reading ${id}: ${r.status}`);
  const u = r.body.UserData ?? {};
  return {
    id,
    Played: !!u.Played,
    PlayCount: u.PlayCount ?? 0,
    PlaybackPositionTicks: u.PlaybackPositionTicks ?? 0,
    IsFavorite: !!u.IsFavorite,
    LastPlayedDate: u.LastPlayedDate ?? null,
  };
}

export async function saveUserData(ids: string[]): Promise<SavedUserData[]> {
  const out: SavedUserData[] = [];
  for (const id of ids) out.push(await userData(id));
  return out;
}

/**
 * Put saved user data back, whole: the full state goes with the date, because
 * a date sent alone is written over whatever the server last cached
 * (jellyfin-next-up-rules). Played is set through its own route first so the
 * server's played bookkeeping agrees.
 */
export async function restoreUserData(saved: SavedUserData[]): Promise<void> {
  const ok = (r: { status: number }, what: string): void => {
    if (r.status >= 300) throw new Error(`restoring ${what}: ${r.status}`);
  };
  for (const s of saved) {
    // Untouched items are left alone: another suite may share the account.
    if (same(await userData(s.id), s)) continue;
    const played = `/UserPlayedItems/${s.id}?userId=${qa!.userId}`;
    if (!s.LastPlayedDate) {
      // An item that had no date: marking it unplayed is the one call that
      // clears the date entirely (with played, count and position). Writing
      // Jellyfin's earliest date instead would leave a visible
      // "0001-01-01" behind, and a null date is ignored.
      ok(await qa!.request(played, "DELETE"), s.id);
      if (s.Played || s.PlayCount || s.PlaybackPositionTicks) {
        ok(
          await qa!.request(`/UserItems/${s.id}/UserData?userId=${qa!.userId}`, "POST", {
            Played: s.Played,
            PlayCount: s.PlayCount,
            PlaybackPositionTicks: s.PlaybackPositionTicks,
          }),
          s.id
        );
      }
    } else {
      const now = await userData(s.id);
      if (now.Played !== s.Played) ok(await qa!.request(played, s.Played ? "POST" : "DELETE"), s.id);
      ok(
        await qa!.request(`/UserItems/${s.id}/UserData?userId=${qa!.userId}`, "POST", {
          Played: s.Played,
          PlayCount: s.PlayCount,
          PlaybackPositionTicks: s.PlaybackPositionTicks,
          LastPlayedDate: s.LastPlayedDate,
        }),
        s.id
      );
    }
    if ((await userData(s.id)).IsFavorite !== s.IsFavorite) {
      ok(await qa!.request(`/UserFavoriteItems/${s.id}?userId=${qa!.userId}`, s.IsFavorite ? "POST" : "DELETE"), s.id);
    }
  }
}

function same(a: SavedUserData, b: SavedUserData): boolean {
  return JSON.stringify({ ...a, LastPlayedDate: day(a.LastPlayedDate) }) === JSON.stringify({ ...b, LastPlayedDate: day(b.LastPlayedDate) });
}

/** Fail loudly if anything saved did not come back exactly. */
export async function expectRestored(saved: SavedUserData[]): Promise<void> {
  for (const s of saved) {
    const now = await userData(s.id);
    expect({ ...now, LastPlayedDate: day(now.LastPlayedDate) }, s.id).toEqual({ ...s, LastPlayedDate: day(s.LastPlayedDate) });
  }
}

/** Dates compared to the second: the server rounds what it stores. A
 *  leftover "never" date is kept distinct from no date. */
function day(d: string | null): string | null {
  if (!d) return null;
  const t = Date.parse(d);
  if (!isFinite(t)) return d;
  return new Date(t).getUTCFullYear() > 1 ? new Date(Math.floor(t / 1000) * 1000).toISOString() : "0001";
}

/** Stop any encode a PlaybackInfo call may have prepared for this session. */
export async function stopEncodes(playSessionId: string | undefined): Promise<void> {
  if (!playSessionId) return;
  await qa!.request(`/Videos/ActiveEncodings?deviceId=${qa!.deviceId}&playSessionId=${playSessionId}`, "DELETE");
}
