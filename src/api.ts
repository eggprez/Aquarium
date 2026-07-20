// Jellyfin API client. All requests go through the Tauri HTTP plugin so we
// aren't subject to webview CORS rules against arbitrary user servers.
import { fetch } from "@tauri-apps/plugin-http";
import { invoke } from "@tauri-apps/api/core";

export const CLIENT_VERSION = "0.1.0";

export interface Session {
  server: string;
  token: string;
  userId: string;
  userName: string;
  deviceId: string;
}

let session: Session | null = null;
let appConfig: any = {};
let offline = false;

export function getSession(): Session | null {
  return session;
}

// ---------- Connectivity ----------
// A saved session with an unreachable server is "offline", not "logged out".
// State flips are broadcast as `fellyjin-connectivity` so the shell can react.

export function isOffline(): boolean {
  return offline;
}

function setOffline(v: boolean): void {
  if (offline === v) return;
  offline = v;
  document.dispatchEvent(new CustomEvent("fellyjin-connectivity", { detail: { offline: v } }));
}

/** Probe the saved server. Updates the offline flag; true when reachable. */
export async function checkOnline(): Promise<boolean> {
  const s = session;
  if (!s) return false;
  try {
    // Any HTTP response at all means the server is reachable.
    await fetch(s.server + "/System/Info/Public", {
      method: "GET",
      connectTimeout: 3000,
    } as any);
    setOffline(false);
    return true;
  } catch {
    setOffline(true);
    return false;
  }
}

export function getConfig(): any {
  return appConfig;
}

export async function loadConfig(): Promise<any> {
  appConfig = await invoke("config_load");
  if (appConfig.server && appConfig.token && appConfig.user_id) {
    session = {
      server: appConfig.server,
      token: appConfig.token,
      userId: appConfig.user_id,
      userName: appConfig.user_name ?? "",
      deviceId: appConfig.device_id,
    };
  }
  return appConfig;
}

export async function saveConfig(patch: Record<string, any>): Promise<void> {
  appConfig = { ...appConfig, ...patch };
  await invoke("config_save", { cfg: appConfig });
}

function authHeader(token?: string): string {
  const deviceId = appConfig.device_id ?? "fellyjin";
  let h = `MediaBrowser Client="FellyJin", Device="Linux", DeviceId="${deviceId}", Version="${CLIENT_VERSION}"`;
  if (token) h += `, Token="${token}"`;
  return h;
}

export async function api(
  path: string,
  opts: { method?: string; body?: any; server?: string; token?: string } = {}
): Promise<any> {
  const server = (opts.server ?? session?.server ?? "").replace(/\/+$/, "");
  if (!server) throw new Error("Not connected to a server");
  const token = opts.token ?? session?.token;
  const headers: Record<string, string> = {
    Authorization: authHeader(token),
  };
  if (opts.body !== undefined) headers["Content-Type"] = "application/json";
  let resp: Response;
  try {
    resp = await fetch(server + path, {
      method: opts.method ?? "GET",
      headers,
      body: opts.body !== undefined ? JSON.stringify(opts.body) : undefined,
    });
  } catch (e) {
    // The request never reached the server — we're offline (or it's down).
    if (session && server === session.server.replace(/\/+$/, "")) setOffline(true);
    throw new Error("Server unreachable — you appear to be offline");
  }
  if (session && server === session.server.replace(/\/+$/, "")) setOffline(false);
  if (!resp.ok) {
    throw new Error(`Server error ${resp.status} on ${path.split("?")[0]}`);
  }
  const text = await resp.text();
  return text ? JSON.parse(text) : null;
}

// ---------- Auth ----------

export async function checkServer(server: string): Promise<any> {
  const resp = await fetch(server.replace(/\/+$/, "") + "/System/Info/Public", {
    method: "GET",
  });
  if (!resp.ok) throw new Error(`Server responded with ${resp.status}`);
  return resp.json();
}

export async function login(
  server: string,
  username: string,
  password: string
): Promise<Session> {
  server = server.replace(/\/+$/, "");
  const resp = await fetch(server + "/Users/AuthenticateByName", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: authHeader(),
    },
    body: JSON.stringify({ Username: username, Pw: password }),
  });
  if (resp.status === 401) throw new Error("Invalid username or password");
  if (!resp.ok) throw new Error(`Login failed (${resp.status})`);
  const data = await resp.json();
  session = {
    server,
    token: data.AccessToken,
    userId: data.User.Id,
    userName: data.User.Name,
    deviceId: appConfig.device_id,
  };
  await saveConfig({
    server,
    token: data.AccessToken,
    user_id: data.User.Id,
    user_name: data.User.Name,
  });
  return session;
}

export async function logout(): Promise<void> {
  try {
    await api("/Sessions/Logout", { method: "POST" });
  } catch {
    /* best effort */
  }
  session = null;
  await saveConfig({ server: appConfig.server, token: null, user_id: null, user_name: null });
}

// ---------- Browse ----------

const ITEM_FIELDS =
  "PrimaryImageAspectRatio,Overview,Genres,MediaSources,UserData,SeriesPrimaryImage,ChildCount,RecursiveItemCount,ProductionYear,RunTimeTicks,OfficialRating,CommunityRating,ParentId";

export async function getViews(): Promise<any[]> {
  const s = session!;
  const r = await api(`/Users/${s.userId}/Views`);
  return r.Items ?? [];
}

export async function getResume(): Promise<any[]> {
  const s = session!;
  const r = await api(
    `/Users/${s.userId}/Items/Resume?Limit=16&Fields=${ITEM_FIELDS}&MediaTypes=Video&EnableImageTypes=Primary,Backdrop,Thumb`
  );
  return r.Items ?? [];
}

export async function getNextUp(): Promise<any[]> {
  const s = session!;
  const r = await api(
    `/Shows/NextUp?userId=${s.userId}&Limit=16&Fields=${ITEM_FIELDS}&EnableImageTypes=Primary,Backdrop,Thumb`
  );
  return r.Items ?? [];
}

export async function getLatest(parentId: string, limit = 16): Promise<any[]> {
  const s = session!;
  return api(
    `/Users/${s.userId}/Items/Latest?parentId=${parentId}&Limit=${limit}&Fields=${ITEM_FIELDS}`
  );
}

export async function getLibraryItems(
  parentId: string,
  opts: { startIndex?: number; limit?: number; includeTypes?: string; sortBy?: string; sortOrder?: string } = {}
): Promise<{ Items: any[]; TotalRecordCount: number }> {
  const s = session!;
  const p = new URLSearchParams({
    ParentId: parentId,
    Recursive: "true",
    SortBy: opts.sortBy ?? "SortName",
    SortOrder: opts.sortOrder ?? "Ascending",
    Fields: ITEM_FIELDS,
    StartIndex: String(opts.startIndex ?? 0),
    Limit: String(opts.limit ?? 60),
  });
  if (opts.includeTypes) p.set("IncludeItemTypes", opts.includeTypes);
  return api(`/Users/${s.userId}/Items?${p}`);
}

export async function getItem(itemId: string): Promise<any> {
  const s = session!;
  return api(`/Users/${s.userId}/Items/${itemId}`);
}

export async function getSeasons(seriesId: string): Promise<any[]> {
  const s = session!;
  const r = await api(`/Shows/${seriesId}/Seasons?userId=${s.userId}&Fields=${ITEM_FIELDS}`);
  return r.Items ?? [];
}

export async function getEpisodes(seriesId: string, seasonId: string): Promise<any[]> {
  const s = session!;
  const r = await api(
    `/Shows/${seriesId}/Episodes?userId=${s.userId}&seasonId=${seasonId}&Fields=${ITEM_FIELDS}`
  );
  return r.Items ?? [];
}

export async function search(term: string): Promise<any[]> {
  const s = session!;
  const p = new URLSearchParams({
    searchTerm: term,
    Recursive: "true",
    IncludeItemTypes: "Movie,Series,Episode",
    Fields: ITEM_FIELDS,
    Limit: "40",
  });
  const r = await api(`/Users/${s.userId}/Items?${p}`);
  return r.Items ?? [];
}

export async function getChannels(): Promise<any[]> {
  const s = session!;
  const r = await api(
    `/LiveTv/Channels?userId=${s.userId}&AddCurrentProgram=true&EnableImageTypes=Primary&Limit=500`
  );
  return r.Items ?? [];
}

/** Server UserData (watched state, resume position) for a batch of item ids. */
export async function getUserDataByIds(ids: string[]): Promise<Map<string, any>> {
  const s = session!;
  const out = new Map<string, any>();
  for (let i = 0; i < ids.length; i += 50) {
    const r = await api(`/Users/${s.userId}/Items?Ids=${ids.slice(i, i + 50).join(",")}`);
    for (const it of r.Items ?? []) out.set(it.Id, it.UserData ?? {});
  }
  return out;
}

export async function markPlayed(itemId: string, played: boolean): Promise<void> {
  const s = session!;
  await api(`/Users/${s.userId}/PlayedItems/${itemId}`, {
    method: played ? "POST" : "DELETE",
  });
}

// ---------- Images ----------

export function imageUrl(
  item: any,
  type = "Primary",
  width = 400
): string | null {
  const s = session;
  if (!s) return null;
  let id = item.Id;
  let tag = item.ImageTags?.[type];
  if (!tag && type === "Primary") {
    if (item.SeriesPrimaryImageTag && item.SeriesId) {
      id = item.SeriesId;
      tag = item.SeriesPrimaryImageTag;
    } else if (item.PrimaryImageTag) {
      tag = item.PrimaryImageTag;
    }
  }
  if (!tag && type === "Backdrop" && item.BackdropImageTags?.length) {
    tag = item.BackdropImageTags[0];
  }
  if (!tag) return null;
  return `${s.server}/Items/${id}/Images/${type}?maxWidth=${width}&tag=${tag}&quality=90`;
}

/**
 * The portrait series poster for an episode (its own Primary image is the
 * 16:9 episode still, which looks wrong on a show card). Returns null when the
 * item isn't an episode or the series poster tag is unavailable.
 */
export function seriesPosterUrl(item: any, width = 400): string | null {
  const s = session;
  if (!s || !item.SeriesId || !item.SeriesPrimaryImageTag) return null;
  return `${s.server}/Items/${item.SeriesId}/Images/Primary?maxWidth=${width}&tag=${item.SeriesPrimaryImageTag}&quality=90`;
}

/**
 * The portrait season poster for an episode. Episode DTOs carry no season
 * image tag, so this is untagged — the server 404s when the season has no
 * poster and the fetch is simply skipped.
 */
export function seasonPosterUrl(item: any, width = 400): string | null {
  const s = session;
  if (!s || !item.SeasonId) return null;
  return `${s.server}/Items/${item.SeasonId}/Images/Primary?maxWidth=${width}&quality=90`;
}

// ---------- Playback source resolution ----------

export interface PlaybackSource {
  url: string;
  playMethod: "DirectStream" | "Transcode";
  mediaSourceId: string;
  playSessionId: string;
  live: boolean;
}

function deviceProfile(forceTranscode: boolean, maxBitrate?: number): any {
  return {
    Name: "FellyJin mpv",
    MaxStreamingBitrate: maxBitrate ?? 200_000_000,
    DirectPlayProfiles: forceTranscode
      ? []
      : [
          {
            Container: "mp4,mkv,avi,mov,wmv,asf,ts,m2ts,webm,flv,ogv,mpg,mpeg,3gp,m4v",
            Type: "Video",
          },
          { Container: "mp3,flac,aac,ogg,wav,m4a,opus", Type: "Audio" },
        ],
    TranscodingProfiles: [
      {
        // No BreakOnNonKeyFrames: mpv needs every HLS segment to start on a
        // keyframe, or video can stay black after seeks while audio plays.
        Container: "ts",
        Type: "Video",
        Protocol: "hls",
        VideoCodec: "h264",
        AudioCodec: "aac,mp3,ac3",
        Context: "Streaming",
        MaxAudioChannels: "6",
        MinSegments: 1,
      },
      { Container: "mp3", Type: "Audio", Protocol: "http", AudioCodec: "mp3", Context: "Streaming" },
    ],
    CodecProfiles: [],
    SubtitleProfiles: [
      { Format: "srt", Method: "Embed" },
      { Format: "ass", Method: "Embed" },
      { Format: "ssa", Method: "Embed" },
      { Format: "vtt", Method: "Embed" },
      { Format: "sub", Method: "Embed" },
      { Format: "pgssub", Method: "Embed" },
      { Format: "dvdsub", Method: "Embed" },
    ],
  };
}

export async function resolvePlayback(
  itemId: string,
  opts: { maxBitrate?: number; forceTranscode?: boolean; live?: boolean; startTicks?: number } = {}
): Promise<PlaybackSource> {
  const s = session!;
  const force = !!opts.forceTranscode;
  const body: any = {
    UserId: s.userId,
    StartTimeTicks: opts.startTicks ?? 0,
    IsPlayback: true,
    AutoOpenLiveStream: true,
    DeviceProfile: deviceProfile(force, opts.maxBitrate),
    EnableDirectPlay: !force,
    EnableDirectStream: !force,
    EnableTranscoding: true,
  };
  if (opts.maxBitrate) body.MaxStreamingBitrate = opts.maxBitrate;

  const info = await api(`/Items/${itemId}/PlaybackInfo`, { method: "POST", body });
  const ms = info.MediaSources?.[0];
  if (!ms) throw new Error("No playable media source returned by the server");
  const playSessionId = info.PlaySessionId;

  if (ms.TranscodingUrl && (force || (!ms.SupportsDirectPlay && !ms.SupportsDirectStream))) {
    return {
      url: s.server + ms.TranscodingUrl,
      playMethod: "Transcode",
      mediaSourceId: ms.Id,
      playSessionId,
      live: !!opts.live,
    };
  }

  // Direct stream of the original media.
  const container = ms.Container || "mkv";
  const p = new URLSearchParams({
    static: "true",
    mediaSourceId: ms.Id,
    api_key: s.token,
    playSessionId,
    deviceId: s.deviceId,
  });
  if (ms.LiveStreamId) p.set("liveStreamId", ms.LiveStreamId);
  if (ms.ETag) p.set("Tag", ms.ETag);
  let url = `${s.server}/Videos/${itemId}/stream.${container}?${p}`;

  // Live channels that direct-play expose an open stream path instead.
  if (opts.live && ms.TranscodingUrl) {
    url = s.server + ms.TranscodingUrl;
    return { url, playMethod: "Transcode", mediaSourceId: ms.Id, playSessionId, live: true };
  }
  return {
    url,
    playMethod: "DirectStream",
    mediaSourceId: ms.Id,
    playSessionId,
    live: !!opts.live,
  };
}

// ---------- Download URL builders ----------

export interface DownloadQuality {
  label: string;
  original?: boolean;
  videoBitrate?: number;
  maxWidth?: number;
}

export const DOWNLOAD_QUALITIES: DownloadQuality[] = [
  { label: "Original quality", original: true },
  { label: "1080p · 10 Mbps (transcoded)", videoBitrate: 10_000_000, maxWidth: 1920 },
  { label: "720p · 4 Mbps (transcoded)", videoBitrate: 4_000_000, maxWidth: 1280 },
  { label: "480p · 1.5 Mbps (transcoded)", videoBitrate: 1_500_000, maxWidth: 854 },
];

/// Estimated on-disk size for a download choice. Exact for originals (server
/// reports file size), bitrate × runtime for transcodes.
export function estimateDownloadSize(item: any, q: DownloadQuality): number | null {
  if (q.original) {
    const size = item.MediaSources?.[0]?.Size ?? item.Size;
    return typeof size === "number" && size > 0 ? size : null;
  }
  const ticks = item.RunTimeTicks;
  if (!ticks || !q.videoBitrate) return null;
  const seconds = ticks / 10_000_000;
  // Video + 192 kbps audio, ~2% container overhead.
  return Math.round(((q.videoBitrate + 192_000) / 8) * seconds * 1.02);
}

export function buildDownload(item: any, q: DownloadQuality): { url: string; fileName: string } {
  const s = session!;
  const safe = (item.Name ?? item.Id).replace(/[^\w\s.\-()\[\]']/g, "_").slice(0, 120);
  if (q.original) {
    const container = item.MediaSources?.[0]?.Container ?? item.Container ?? "mkv";
    return {
      url: `${s.server}/Items/${item.Id}/Download?api_key=${s.token}`,
      fileName: `${safe}.${container}`,
    };
  }
  const p = new URLSearchParams({
    api_key: s.token,
    static: "false",
    VideoCodec: "h264",
    AudioCodec: "aac",
    VideoBitrate: String(q.videoBitrate),
    AudioBitrate: "192000",
    MaxWidth: String(q.maxWidth),
    deviceId: s.deviceId,
    Context: "Static",
  });
  return {
    url: `${s.server}/Videos/${item.Id}/stream.mkv?${p}`,
    fileName: `${safe} (${q.maxWidth}p).mkv`,
  };
}

// ---------- Formatting helpers ----------

export function ticksToText(ticks?: number): string {
  if (!ticks) return "";
  const totalMin = Math.round(ticks / 600_000_000);
  const h = Math.floor(totalMin / 60);
  const m = totalMin % 60;
  return h > 0 ? `${h}h ${m}m` : `${m}m`;
}

export function secondsToClock(sec: number): string {
  if (!isFinite(sec) || sec < 0) sec = 0;
  const s = Math.floor(sec % 60);
  const m = Math.floor((sec / 60) % 60);
  const h = Math.floor(sec / 3600);
  const mm = String(m).padStart(2, "0");
  const ss = String(s).padStart(2, "0");
  return h > 0 ? `${h}:${mm}:${ss}` : `${m}:${ss}`;
}

export function bytesToText(n: number): string {
  if (n >= 1 << 30) return (n / (1 << 30)).toFixed(2) + " GiB";
  if (n >= 1 << 20) return (n / (1 << 20)).toFixed(1) + " MiB";
  if (n >= 1 << 10) return (n / (1 << 10)).toFixed(0) + " KiB";
  return n + " B";
}
