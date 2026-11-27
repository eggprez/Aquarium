// src/seerr.ts and the Delete from Server dialog against a real Seerr 3.5,
// Radarr and Sonarr (`AquariumQA/arr` on the Mac the Apple app is tested on;
// `up.sh` starts them). Signed in to Seerr as its admin with the session
// `arr/setup` saved (`arr/seerr.cookies`). Skips when the stack is down.
//
// The deleting test runs only with AQUARIUM_ARR_DELETE=1, since it uses up a
// title (`up.sh` puts it back).
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { onInvokes } from "../helpers/tauri";
import { qa } from "../helpers/qa";

const SEERR = "http://127.0.0.1:8194";
const ARR = path.join(process.env.AQUARIUM_QA_DIR ?? path.join(os.homedir(), "Library", "Application Support", "AquariumQA"), "arr");

function readCookie(): string | null {
  try {
    const line = fs.readFileSync(path.join(ARR, "seerr.cookies"), "utf8").split("\n").find((l) => l.includes("connect.sid"));
    return line ? line.split("\t").at(-1)!.trim() : null;
  } catch {
    return null;
  }
}

async function seerrRaw(p: string, method = "GET", body?: any): Promise<{ status: number; body: any }> {
  const res = await fetch(`${SEERR}/api/v1${p}`, {
    method,
    headers: { Accept: "application/json", Cookie: `connect.sid=${cookie}`, ...(body != null ? { "Content-Type": "application/json" } : {}) },
    body: body != null ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  let parsed: any = null;
  try {
    parsed = text.trim() ? JSON.parse(text) : null;
  } catch {
    parsed = null;
  }
  return { status: res.status, body: parsed };
}

async function arrHas(name: "radarr" | "sonarr", field: string, id: number): Promise<boolean | null> {
  try {
    const key = fs.readFileSync(path.join(ARR, `${name}.key`), "utf8").trim();
    const port = name === "radarr" ? 8198 : 8199;
    const res = await fetch(`http://127.0.0.1:${port}/api/v3/${name === "radarr" ? "movie" : "series"}`, { headers: { "X-Api-Key": key } });
    if (!res.ok) return null;
    return ((await res.json()) as any[]).some((t) => t[field] === id);
  } catch {
    return null;
  }
}

const cookie = readCookie();
let me: any = null;
let settings: any = null;
if (cookie && qa) {
  try {
    const who = await seerrRaw("/auth/me");
    if (who.status === 200) {
      me = who.body;
      settings = (await seerrRaw("/settings/public")).body;
    }
  } catch {
    me = null;
  }
}
const live = !!me && (await arrHas("radarr", "tmdbId", 0)) !== null;

/** The Jellyfin item of this name in the Arr libraries, whole. */
async function arrItem(name: string, kind: string): Promise<any> {
  const found = await qa!.request(`/Items?Recursive=true&IncludeItemTypes=${kind}&SearchTerm=${encodeURIComponent(name)}&Fields=Path,ProviderIds,CanDelete&userId=${qa!.userId}`);
  return (found.body?.Items ?? []).find((i: any) => String(i.Path ?? "").includes("/arr/media/"));
}

type Seerr = typeof import("../../src/seerr");
let seerr: Seerr;

describe.skipIf(!live)("real Seerr, Radarr and Sonarr: Delete from Server", () => {
  beforeEach(async () => {
    vi.resetModules();
    qa!.install();
    const status = () => ({
      connected: true, server: SEERR, host: "127.0.0.1:8194", secure: false, user_id: me.id,
      user_name: me.displayName ?? "admin", permissions: me.permissions, settings, needs_reconnect: false, storage: "keyring",
    });
    onInvokes({
      seerr_status: () => status(),
      seerr_refresh: () => status(),
      seerr_request: async (a: { path: string; method?: string; body?: any }) => {
        const res = await seerrRaw(a.path, a.method ?? "GET", a.body);
        if (res.status < 200 || res.status >= 300) throw `refused|${res.body?.message ?? "Seerr turned that down."}`;
        return res;
      },
    });
    seerr = await import("../../src/seerr");
    await seerr.loadStatus();
  });

  it("offers a film on Radarr, with its record and server as Seerr has them", async () => {
    const film = await arrItem("Nosferatu", "Movie");
    expect(film, "Nosferatu in Arr Movies (run arr/up.sh)").toBeTruthy();
    expect(seerr.mightRemove(film)).toBe(true);
    const how = await seerr.removal(film);
    expect(how).toMatchObject({ kind: "movie", tmdbId: 653, copies: [false] });
    expect(typeof how!.mediaId).toBe("number");
  });

  it("offers a show on Sonarr", async () => {
    const show = await arrItem("Fawlty Towers", "Series");
    expect(show).toBeTruthy();
    expect(await seerr.removal(show)).toMatchObject({ kind: "tv", tmdbId: 2207, copies: [false] });
  });

  it("offers nothing for a season or an episode, which Seerr can't remove alone", async () => {
    const show = await arrItem("Fawlty Towers", "Series");
    const seasons = await qa!.request(`/Shows/${show.Id}/Seasons?userId=${qa!.userId}`);
    const season = seasons.body?.Items?.[0];
    expect(seerr.mightRemove(season)).toBe(false);
    expect(await seerr.removal(season)).toBeNull();
  });

  it.skipIf(process.env.AQUARIUM_ARR_DELETE !== "1")("takes a film off Radarr with its file, and clears Seerr's record", async () => {
    const film = await arrItem("Metropolis", "Movie");
    expect(film, "Metropolis in Arr Movies (run arr/up.sh)").toBeTruthy();
    const how = await seerr.removal(film);
    expect(how).not.toBeNull();
    await seerr.remove(how!);
    expect(await arrHas("radarr", "tmdbId", 19)).toBe(false);
    expect(fs.existsSync(path.join(ARR, "media/movies/Metropolis (1927)/Metropolis (1927).mkv"))).toBe(false);
    const after = await seerrRaw("/movie/19");
    expect(after.body?.mediaInfo ?? null).toBeNull();
  });
});
