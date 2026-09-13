// Jellyfin API client.
//
// Nothing here talks to the network. Every request is handed to the Rust side
// (`server.rs`), which adds the access token, checks the server is still the
// one we signed in to, and hands back a status and a body. The token has never
// been in this file since; a script that gets into the webview has no
// credential to steal and no way to reach an outside host anyway — the window
// holds no HTTP permission and the CSP forbids it.
import { invoke } from "@tauri-apps/api/core";

export const CLIENT_VERSION = "0.1.0";

export interface Session {
  server: string;
  userId: string;
  userName: string;
  deviceId: string;
  /** Whether the connection to the server is encrypted. */
  secure: boolean;
}

/** What a server said about itself when probed, before any sign-in. */
export interface ServerProbe {
  server: string;
  secure: boolean;
  server_id: string | null;
  server_name: string | null;
  version: string | null;
}

let session: Session | null = null;
let appConfig: any = {};
let offline = false;

export function getSession(): Session | null {
  return session;
}

// Errors from Rust arrive as "<kind>|<message>" so the difference between "the
// network is down" and "that is not the server you signed in to" survives the
// trip across the IPC boundary.
interface ApiError {
  kind: "offline" | "identity" | "auth" | "config" | "server";
  message: string;
}

function splitError(e: any): ApiError {
  const raw = typeof e === "string" ? e : e?.message ?? String(e);
  const i = raw.indexOf("|");
  const kind = i > 0 ? raw.slice(0, i) : "";
  if (["offline", "identity", "auth", "config", "server"].includes(kind)) {
    return { kind: kind as ApiError["kind"], message: raw.slice(i + 1) };
  }
  return { kind: "server", message: raw };
}

/**
 * The address we have saved is answering as a different Jellyfin install than
 * the one the session belongs to. That is either a moved server or someone
 * editing config.json to point the client — and its token — somewhere else, so
 * it stops the app rather than degrading to offline mode.
 */
function announceIdentityChange(message: string): void {
  document.dispatchEvent(
    new CustomEvent("fellyjin-server-identity", { detail: { message } })
  );
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
  if (!session) return false;
  try {
    const ok = await invoke<boolean>("jf_ping");
    setOffline(!ok);
    return ok;
  } catch (e) {
    const { kind, message } = splitError(e);
    if (kind === "identity") {
      announceIdentityChange(message);
      return false;
    }
    setOffline(true);
    return false;
  }
}

/**
 * A failed request says the server *may* be unreachable; one probe decides.
 * The request itself is not enough: a resolver with no network under it yet —
 * the seconds after a wake, a Wi-Fi hand-off — fails instantly, and taking
 * that as the verdict put the app in offline mode on the strength of a single
 * failure it never re-checked. The probe (`ping` in server.rs) retries a fast
 * failure before answering, and the burst of requests a page makes shares one
 * probe rather than each starting its own.
 */
let offlineProbe: Promise<boolean> | null = null;

async function confirmOffline(): Promise<void> {
  if (offline || !session) return;
  if (!offlineProbe) {
    offlineProbe = checkOnline().finally(() => {
      offlineProbe = null;
    });
  }
  await offlineProbe;
}

export function getConfig(): any {
  return appConfig;
}

export async function loadConfig(): Promise<any> {
  appConfig = await invoke("config_load");
  // `has_token` rather than the token itself: the config the frontend sees no
  // longer carries the credential, only the fact that one is stored.
  if (appConfig.server && appConfig.has_token && appConfig.user_id) {
    session = {
      server: appConfig.server,
      userId: appConfig.user_id,
      userName: appConfig.user_name ?? "",
      deviceId: appConfig.device_id,
      secure: String(appConfig.server).startsWith("https://"),
    };
  } else {
    session = null;
  }
  return appConfig;
}

export async function saveConfig(patch: Record<string, any>): Promise<void> {
  appConfig = { ...appConfig, ...patch };
  await invoke("config_save", { cfg: appConfig });
}

export async function api(
  path: string,
  opts: { method?: string; body?: any } = {}
): Promise<any> {
  let res: { status: number; body: any };
  try {
    res = await invoke("jf_request", {
      path,
      method: opts.method ?? "GET",
      body: opts.body ?? null,
    });
  } catch (e) {
    const { kind, message } = splitError(e);
    if (kind === "offline") {
      void confirmOffline();
      throw new Error(message);
    }
    if (kind === "identity") {
      announceIdentityChange(message);
      throw new Error(message);
    }
    throw new Error(message);
  }
  setOffline(false);
  // A revoked or expired token answers 401 on every endpoint, so without this
  // branch the whole app reads as broken — each page failing with its own
  // "Server error 401" and no route back to the sign-in screen.
  if (res.status === 401 && session) {
    await expireSession();
    throw new Error("Your session has expired — please sign in again");
  }
  if (res.status < 200 || res.status >= 300) {
    throw new Error(`Server error ${res.status} on ${path.split("?")[0]}`);
  }
  return res.body;
}

// ---------- Auth ----------

/**
 * Find out what is at an address, before any credential is sent to it. A bare
 * hostname is tried over https first — see `server.rs`. The returned `secure`
 * flag is what the sign-in screen warns on.
 */
export async function probeServer(server: string): Promise<ServerProbe> {
  try {
    return await invoke<ServerProbe>("jf_probe", { server });
  } catch (e) {
    throw new Error(splitError(e).message);
  }
}

/**
 * Sign in. The password goes straight to Rust and the access token never comes
 * back out — it is written to the keyring there, and every later request is
 * made on this session's behalf by the backend.
 */
export async function login(
  server: string,
  username: string,
  password: string
): Promise<Session> {
  let res: any;
  try {
    res = await invoke("jf_login", { server, username, password });
  } catch (e) {
    throw new Error(splitError(e).message);
  }
  await loadConfig();
  session = {
    server: res.server,
    userId: res.user_id,
    userName: res.user_name ?? "",
    deviceId: res.device_id,
    secure: !!res.secure,
  };
  setOffline(false);
  return session;
}

/**
 * Sign out. Resolves to whether the server actually confirmed the token was
 * revoked; when it didn't, the backend keeps retrying and the caller should
 * say so rather than let the user believe the session is dead.
 */
export async function logout(): Promise<{ revoked: boolean; pending: boolean }> {
  let res: any = { revoked: false, pending: false };
  try {
    res = await invoke("jf_logout");
  } catch (e) {
    throw new Error(splitError(e).message);
  } finally {
    session = null;
    await loadConfig().catch(() => {});
  }
  return { revoked: !!res.revoked, pending: !!res.pending };
}

/**
 * Drop a session the server has stopped honouring. Same teardown as `logout`
 * minus the Logout call (the token it would authenticate with is exactly the
 * one that just failed), plus a broadcast so the shell can show the login
 * screen instead of leaving the user on a page that can no longer load.
 *
 * Guarded against re-entry: a page load fires several requests at once and they
 * would otherwise each announce the expiry.
 */
let expiring = false;

async function expireSession(): Promise<void> {
  if (expiring || !session) return;
  expiring = true;
  session = null;
  try {
    // Same teardown as a sign-out, which also clears the stored token. The
    // revocation call it makes answers 401 for an already-dead token, which
    // the backend counts as revoked — so nothing is left behind or retried.
    await invoke("jf_logout");
    await loadConfig();
  } catch {
    /* the sign-in screen is the important part */
  }
  document.dispatchEvent(new CustomEvent("fellyjin-auth-expired"));
  expiring = false;
}

// ---------- Browse ----------
//
// Every user-scoped request names the user with a `userId=` query parameter
// on the plain route (`/Items?userId=…`, `/UserViews?userId=…`) rather than
// the older `/Users/{userId}/…` form. Jellyfin marked the old routes obsolete
// in 10.9 and still answers them in 12.0, but only "for backwards
// compatibility", and 12.0 is the release that dropped the rest of its legacy
// API surface — so these are the routes with a future. Nothing here works on a
// server older than 10.9.

const ITEM_FIELDS =
  "PrimaryImageAspectRatio,Overview,Genres,MediaSources,UserData,SeriesPrimaryImage,ChildCount,RecursiveItemCount,ProductionYear,RunTimeTicks,OfficialRating,CommunityRating,ParentId";

/** `ITEM_FIELDS` plus the ones only the detail page draws. `People` is a long
 *  list on a feature film, so it isn't asked for on every grid query. */
const DETAIL_FIELDS = `${ITEM_FIELDS},People,Studios,Taglines`;

export async function getViews(): Promise<any[]> {
  const s = session!;
  const r = await api(`/UserViews?userId=${s.userId}`);
  return r.Items ?? [];
}

export async function getResume(): Promise<any[]> {
  const s = session!;
  const r = await api(
    `/UserItems/Resume?userId=${s.userId}&Limit=16&Fields=${ITEM_FIELDS}&MediaTypes=Video&EnableImageTypes=Primary,Backdrop,Thumb,Logo`
  );
  return r.Items ?? [];
}

export async function getNextUp(): Promise<any[]> {
  const s = session!;
  const r = await api(
    `/Shows/NextUp?userId=${s.userId}&Limit=16&Fields=${ITEM_FIELDS}&EnableImageTypes=Primary,Backdrop,Thumb,Logo`
  );
  return r.Items ?? [];
}

/**
 * The one episode the user should watch next in a series — the in-progress
 * one, else the first unwatched. Null when the server has nothing queued (a
 * finished show, or one that was never started). Used by the series page's
 * play button.
 */
export async function getSeriesNextUp(seriesId: string): Promise<any | null> {
  const s = session!;
  const r = await api(
    `/Shows/NextUp?userId=${s.userId}&seriesId=${seriesId}&Limit=1&Fields=${ITEM_FIELDS}&EnableImageTypes=Primary,Backdrop,Thumb,Logo`
  );
  return r.Items?.[0] ?? null;
}

/**
 * Newest additions to a library.
 *
 * The server's own grouping is half-hearted: several new episodes of a show
 * collapse into the series, but a show with exactly one new episode comes back
 * as the bare episode — so a TV row ends up mixing shows with single episodes.
 * Every episode is folded into its series here, so the row reads as "shows
 * with something new" throughout.
 */
export async function getLatest(parentId: string, limit = 16): Promise<any[]> {
  const s = session!;
  const items: any[] = await api(
    `/Items/Latest?userId=${s.userId}&parentId=${parentId}&Limit=${limit}&Fields=${ITEM_FIELDS}`
  );
  return foldEpisodesIntoSeries(items);
}

/** Replace every episode with its series, keeping the row's order and dropping
 *  the duplicates that leaves behind. */
async function foldEpisodesIntoSeries(items: any[]): Promise<any[]> {
  const episodes = items.filter((i) => i?.Type === "Episode" && i.SeriesId);
  if (!episodes.length) return items;

  // Series already in the row cost nothing; the rest are fetched in one go,
  // deduplicated so two new episodes of the same show are a single lookup.
  const series = new Map<string, any>();
  for (const i of items) if (i?.Type === "Series" && i.Id) series.set(i.Id, i);
  const missing = [...new Set(episodes.map((e) => e.SeriesId))].filter((id) => !series.has(id));
  if (missing.length) {
    // A failed lookup leaves the episode where it was: a row with one odd card
    // is better than a row that quietly lost a title.
    const fetched = await getItemsByIds(missing, ITEM_FIELDS).catch(() => []);
    for (const s of fetched) if (s?.Id) series.set(s.Id, s);
  }

  const seen = new Set<string>();
  const out: any[] = [];
  for (const item of items) {
    const card = (item?.Type === "Episode" ? series.get(item.SeriesId) : null) ?? item;
    if (card?.Id) {
      if (seen.has(card.Id)) continue;
      seen.add(card.Id);
    }
    out.push(card);
  }
  return out;
}

export interface LibraryQuery {
  startIndex?: number;
  limit?: number;
  includeTypes?: string;
  sortBy?: string;
  sortOrder?: string;
  /** Only items with something left to watch. */
  unwatched?: boolean;
  favorites?: boolean;
  genre?: string;
}

export async function getLibraryItems(
  parentId: string,
  opts: LibraryQuery = {}
): Promise<{ Items: any[]; TotalRecordCount: number }> {
  const s = session!;
  const p = new URLSearchParams({
    userId: s.userId,
    ParentId: parentId,
    Recursive: "true",
    SortBy: opts.sortBy ?? "SortName",
    SortOrder: opts.sortOrder ?? "Ascending",
    Fields: ITEM_FIELDS,
    StartIndex: String(opts.startIndex ?? 0),
    Limit: String(opts.limit ?? 60),
  });
  if (opts.includeTypes) p.set("IncludeItemTypes", opts.includeTypes);
  if (opts.unwatched) p.set("Filters", "IsUnplayed");
  if (opts.favorites) p.set("IsFavorite", "true");
  if (opts.genre) p.set("Genres", opts.genre);
  return api(`/Items?${p}`);
}

/**
 * Everything the user has starred, across every library. `Filters=IsFavorite`
 * with no ParentId is the server-side equivalent of the per-library favorites
 * toggle, so this and the library filter agree on what counts.
 */
export async function getFavorites(
  opts: { startIndex?: number; limit?: number; includeTypes?: string; sortBy?: string; sortOrder?: string } = {}
): Promise<{ Items: any[]; TotalRecordCount: number }> {
  const s = session!;
  const p = new URLSearchParams({
    userId: s.userId,
    Recursive: "true",
    Filters: "IsFavorite",
    IncludeItemTypes: opts.includeTypes || "Movie,Series,Episode",
    SortBy: opts.sortBy ?? "SortName",
    SortOrder: opts.sortOrder ?? "Ascending",
    Fields: ITEM_FIELDS,
    StartIndex: String(opts.startIndex ?? 0),
    Limit: String(opts.limit ?? 60),
  });
  const r = await api(`/Items?${p}`);
  return { Items: r.Items ?? [], TotalRecordCount: r.TotalRecordCount ?? (r.Items?.length ?? 0) };
}

/** Genre names present in one library, for the filter bar. Empty on servers
 *  that don't answer the filters endpoint — the control is then hidden. */
export async function getGenres(parentId: string, includeTypes: string): Promise<string[]> {
  const s = session!;
  const p = new URLSearchParams({ userId: s.userId, parentId });
  if (includeTypes) p.set("IncludeItemTypes", includeTypes);
  const r = await api(`/Items/Filters?${p}`);
  const names: string[] = (r?.Genres ?? []).filter((g: any) => typeof g === "string" && g);
  return names.sort((a, b) => a.localeCompare(b));
}

export async function getItem(itemId: string): Promise<any> {
  const s = session!;
  return api(`/Items/${itemId}?userId=${s.userId}&Fields=${DETAIL_FIELDS}`);
}

/**
 * "More like this" — the server's own recommendation for an item. Purely
 * additive to the detail page, so callers treat a failure as an empty list.
 */
export async function getSimilar(itemId: string, limit = 12): Promise<any[]> {
  const s = session!;
  const r = await api(
    `/Items/${itemId}/Similar?userId=${s.userId}&limit=${limit}&Fields=${ITEM_FIELDS}`
  );
  return r.Items ?? [];
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

// ---------- Trickplay (scrubber previews) ----------

/** One resolution of trickplay tiles, as the server describes them. */
export interface TrickplayInfo {
  /** Item the tiles belong to — not always the item being played. */
  itemId: string;
  /** Pixel size of a single thumbnail. */
  width: number;
  height: number;
  /** Thumbnails per tile sheet. */
  tileWidth: number;
  tileHeight: number;
  /** Milliseconds between thumbnails. */
  interval: number;
  thumbnailCount: number;
}

/**
 * Trickplay metadata for an item, or null when the server has none — which is
 * the common case: tiles are generated by a scheduled task that many installs
 * never run, and by default only for larger libraries. Callers fall back to a
 * plain time readout.
 *
 * `Trickplay` is only populated when it's asked for by name, so this is its own
 * request rather than a field on the item every list already fetches.
 */
export async function getTrickplay(itemId: string): Promise<TrickplayInfo | null> {
  const s = session;
  if (!s) return null;
  const item = await api(`/Items/${itemId}?userId=${s.userId}&Fields=Trickplay`).catch(() => null);
  const byWidth = item?.Trickplay?.[item?.MediaSources?.[0]?.Id] ?? Object.values(item?.Trickplay ?? {})[0];
  if (!byWidth || typeof byWidth !== "object") return null;
  // Several resolutions may exist; the widest still fits in a scrubber bubble.
  const widths = Object.keys(byWidth as object)
    .map(Number)
    .filter((n) => n > 0)
    .sort((a, b) => b - a);
  const info: any = widths.length ? (byWidth as any)[widths[0]!] : null;
  if (!info?.Width || !info?.Interval) return null;
  return {
    itemId,
    width: info.Width,
    height: info.Height ?? Math.round(info.Width * 0.5625),
    tileWidth: info.TileWidth ?? 1,
    tileHeight: info.TileHeight ?? 1,
    interval: info.Interval,
    thumbnailCount: info.ThumbnailCount ?? 0,
  };
}

/**
 * One tile sheet as a data URL. Trickplay images need the access token, which
 * lives in the backend, so unlike every other image in the app these come
 * across the IPC boundary rather than being fetched by the webview.
 */
export async function trickplayTile(info: TrickplayInfo, tileIndex: number): Promise<string> {
  return invoke<string>("jf_image", {
    path: `/Videos/${info.itemId}/Trickplay/${info.width}/${tileIndex}.jpg`,
  });
}

// ---------- Media segments (intros, credits) ----------

export interface MediaSegment {
  type: string;
  start: number;
  end: number;
}

/**
 * Skippable stretches of an item — an opening title sequence, closing credits.
 * Jellyfin 10.10 and up, and only for items some plugin has actually analysed;
 * everything else answers 404 or an empty list, and the skip button never
 * appears.
 */
export async function getMediaSegments(itemId: string): Promise<MediaSegment[]> {
  const r = await api(`/MediaSegments/${itemId}?includeSegmentTypes=Intro,Outro`).catch(() => null);
  const items: any[] = r?.Items ?? [];
  return items
    .map((s) => ({
      type: String(s.Type ?? ""),
      start: (s.StartTicks ?? 0) / 10_000_000,
      end: (s.EndTicks ?? 0) / 10_000_000,
    }))
    .filter((s) => s.end > s.start);
}

export async function search(
  term: string,
  opts: { startIndex?: number; limit?: number } = {}
): Promise<{ Items: any[]; TotalRecordCount: number }> {
  const s = session!;
  const p = new URLSearchParams({
    userId: s.userId,
    searchTerm: term,
    Recursive: "true",
    IncludeItemTypes: "Movie,Series,Episode",
    Fields: ITEM_FIELDS,
    StartIndex: String(opts.startIndex ?? 0),
    Limit: String(opts.limit ?? 48),
  });
  const r = await api(`/Items?${p}`);
  return { Items: r.Items ?? [], TotalRecordCount: r.TotalRecordCount ?? (r.Items?.length ?? 0) };
}

export async function getChannels(): Promise<any[]> {
  const s = session!;
  const r = await api(
    `/LiveTv/Channels?userId=${s.userId}&AddCurrentProgram=true&EnableImageTypes=Primary&Limit=500`
  );
  return r.Items ?? [];
}

/**
 * Guide entries overlapping [from, to) for a set of channels — everything the
 * TV Guide draws. `minEndDate`/`maxStartDate` (rather than a start-date range)
 * is what catches the programme already half-finished when the window opens,
 * which is the one every viewer is actually looking at.
 *
 * Channels go out in batches because the ids are carried in the query string
 * and a 500-channel tuner would otherwise build a URL no server will accept.
 */
export async function getPrograms(
  channelIds: string[],
  from: Date,
  to: Date
): Promise<any[]> {
  const s = session!;
  const out: any[] = [];
  for (let i = 0; i < channelIds.length; i += 80) {
    const p = new URLSearchParams({
      userId: s.userId,
      channelIds: channelIds.slice(i, i + 80).join(","),
      minEndDate: from.toISOString(),
      maxStartDate: to.toISOString(),
      sortBy: "StartDate",
      fields: "Overview",
      enableImages: "false",
      enableUserData: "false",
      enableTotalRecordCount: "false",
      limit: "20000",
    });
    const r = await api(`/LiveTv/Programs?${p}`);
    out.push(...(r.Items ?? []));
  }
  return out;
}

/** Items for a batch of ids, 50 per request. `fields` is left empty by callers
 *  that only want the lean default shape. */
export async function getItemsByIds(ids: string[], fields = ""): Promise<any[]> {
  const s = session!;
  const out: any[] = [];
  for (let i = 0; i < ids.length; i += 50) {
    const r = await api(
      `/Items?userId=${s.userId}&Ids=${ids.slice(i, i + 50).join(",")}` +
        (fields ? `&Fields=${fields}` : "")
    );
    out.push(...(r.Items ?? []));
  }
  return out;
}

/** Server UserData (watched state, resume position) for a batch of item ids. */
export async function getUserDataByIds(ids: string[]): Promise<Map<string, any>> {
  const out = new Map<string, any>();
  for (const it of await getItemsByIds(ids)) out.set(it.Id, it.UserData ?? {});
  return out;
}

export async function markPlayed(itemId: string, played: boolean): Promise<void> {
  const s = session!;
  await api(`/UserPlayedItems/${itemId}?userId=${s.userId}`, {
    method: played ? "POST" : "DELETE",
  });
}

export async function setFavorite(itemId: string, favorite: boolean): Promise<void> {
  const s = session!;
  await api(`/UserFavoriteItems/${itemId}?userId=${s.userId}`, {
    method: favorite ? "POST" : "DELETE",
  });
}

// ---------- Images ----------

/**
 * Which item and which image tag a request for `type` actually resolves to.
 * Split out of `imageUrl` because the BlurHash for an image is filed under the
 * same tag: a placeholder that resolved the tag differently would be the blur
 * of some other artwork.
 */
function resolveImage(item: any, type: string): { id: string; tag: string } | null {
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
  return tag ? { id, tag } : null;
}

export function imageUrl(
  item: any,
  type = "Primary",
  width = 400
): string | null {
  const s = session;
  if (!s) return null;
  const found = resolveImage(item, type);
  if (!found) return null;
  return `${s.server}/Items/${found.id}/Images/${type}?maxWidth=${width}&tag=${found.tag}&quality=90`;
}

/**
 * The BlurHash for the same image `imageUrl` would return — a placeholder to
 * paint while the real artwork is still in flight. Null whenever the server
 * hasn't computed one (older Jellyfin, or an image added since the last scan).
 *
 * Jellyfin files these by image type and then by tag, so an item with several
 * backdrops has a hash per backdrop; matching on the resolved tag is what keeps
 * the placeholder and the picture in step.
 */
export function imageHash(item: any, type = "Primary"): string | null {
  const found = resolveImage(item, type);
  if (!found) return null;
  const byTag = item.ImageBlurHashes?.[type];
  const hash = byTag?.[found.tag];
  return typeof hash === "string" && hash.length > 5 ? hash : null;
}

/**
 * The item's title art — the transparent PNG wordmark studios ship with a film
 * or show ("logo" in Jellyfin's vocabulary). Heroes use it in place of typeset
 * text, which is what Apple TV, Infuse and Netflix all do: the title reads as
 * part of the artwork rather than as a caption on top of it.
 *
 * Episodes and seasons carry their series' logo through the Parent* tags, so a
 * hero for "S2:E4" still gets the show's wordmark. Returns null when the server
 * has no logo for the item, which is common — callers fall back to text.
 */
export function logoUrl(item: any, width = 640): string | null {
  const s = session;
  if (!s) return null;
  let id = item.Id;
  let tag = item.ImageTags?.Logo;
  if (!tag && item.ParentLogoItemId && item.ParentLogoImageTag) {
    id = item.ParentLogoItemId;
    tag = item.ParentLogoImageTag;
  }
  if (!tag || !id) return null;
  return `${s.server}/Items/${id}/Images/Logo?maxWidth=${width}&tag=${tag}&quality=90`;
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

// ---------- Bandwidth ----------

/**
 * Time a download of `size` bytes from the server's own bandwidth-test
 * endpoint, for a starting-bitrate estimate before a stream begins. Runs
 * through Rust, like every other request — the payload itself needs no
 * decoding here, only its timing, which is measured on the other side of the
 * IPC boundary so a slow link's round trip isn't inflated by carrying the
 * bytes across it twice.
 *
 * Returns null on any failure — offline, a server too old to have the
 * endpoint, the probe's own timeout — which the caller treats as "couldn't
 * measure it" rather than an error worth surfacing.
 */
export async function probeBandwidth(size = 1_000_000): Promise<number | null> {
  try {
    return await invoke<number>("jf_bitrate_test", { size });
  } catch {
    return null;
  }
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

  // Direct stream of the original media. No `api_key` here: mpv is given the
  // token as an Authorization header instead (see player.rs), which keeps it
  // out of Jellyfin's access log and out of our own mpv log.
  const container = ms.Container || "mkv";
  const p = new URLSearchParams({
    static: "true",
    mediaSourceId: ms.Id,
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
  audioBitrate?: number;
  maxWidth?: number;
  /** Resolution as people say it ("1080p"), for filenames. `maxWidth` is the
   *  wrong number to put there: nobody calls a 1080p file "1920p". */
  name?: string;
}

/**
 * Download rungs, largest-first. Unlike the streaming ladder these are
 * *video-only* rates — audio is requested separately and added to the estimate —
 * and the resolution is pinned with MaxWidth rather than inferred by the server.
 *
 * Sized for the h264 the download URL asks for, at the point where the re-encode
 * stops being distinguishable from its source on that size of picture. Grain and
 * gradients are what break first if you go lower.
 */
export const DOWNLOAD_QUALITIES: DownloadQuality[] = [
  { label: "Original quality", original: true },
  { label: "4K · 32 Mbps", name: "4K", videoBitrate: 32_000_000, audioBitrate: 384_000, maxWidth: 3840 },
  { label: "1440p · 16 Mbps", name: "1440p", videoBitrate: 16_000_000, audioBitrate: 256_000, maxWidth: 2560 },
  { label: "1080p · 9 Mbps", name: "1080p", videoBitrate: 9_000_000, audioBitrate: 256_000, maxWidth: 1920 },
  { label: "720p · 4.5 Mbps", name: "720p", videoBitrate: 4_500_000, audioBitrate: 192_000, maxWidth: 1280 },
  { label: "480p · 2 Mbps", name: "480p", videoBitrate: 2_000_000, audioBitrate: 192_000, maxWidth: 854 },
];

/** Audio rate for a rung. Defaulted rather than required so a download queued
 *  by an older version, restored from localStorage, still builds a valid URL. */
function audioRate(q: DownloadQuality): number {
  return q.audioBitrate ?? 192_000;
}

// ---------- Source media description ----------

/** Height → the name people actually use for it. */
function resolutionLabel(stream: any): string | null {
  const h = stream?.Height;
  const w = stream?.Width;
  if (!h) return null;
  if (h >= 2000 || w >= 3800) return "4K";
  if (h >= 1000) return "1080p";
  if (h >= 700) return "720p";
  if (h >= 550) return "576p";
  if (h >= 400) return "480p";
  return `${h}p`;
}

function channelLabel(stream: any): string | null {
  const layout = stream?.ChannelLayout;
  if (typeof layout === "string" && layout) return layout === "mono" ? "Mono" : layout;
  switch (stream?.Channels) {
    case 8: return "7.1";
    case 6: return "5.1";
    case 2: return "Stereo";
    case 1: return "Mono";
    default: return null;
  }
}

/**
 * What the file on the server actually is: "1080p · HEVC · 5.1 · 8.4 GB".
 *
 * `MediaSources` was already being fetched for every item — only the download
 * size estimator read it — so the detail page could tell you the choices it was
 * offering but not what it was choosing between. Returns an empty list for
 * anything with no usable media source (a series, a stub).
 */
export function mediaSummary(item: any): string[] {
  const ms = item?.MediaSources?.[0];
  if (!ms) return [];
  const streams: any[] = ms.MediaStreams ?? [];
  const video = streams.find((s) => s.Type === "Video");
  const audio = streams.find((s) => s.Type === "Audio");
  const subs = streams.filter((s) => s.Type === "Subtitle").length;

  const upper = (v: unknown): string | null =>
    typeof v === "string" && v ? v.toUpperCase() : null;

  return [
    resolutionLabel(video),
    upper(video?.Codec),
    upper(audio?.Codec),
    channelLabel(audio),
    subs ? `${subs} subtitle track${subs === 1 ? "" : "s"}` : null,
    typeof ms.Size === "number" && ms.Size > 0 ? bytesToText(ms.Size) : null,
  ].filter((x): x is string => !!x);
}

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
  // Video + audio, ~2% container overhead.
  return Math.round(((q.videoBitrate + audioRate(q)) / 8) * seconds * 1.02);
}

/**
 * The rung a download will actually use, which is not always the one asked for.
 *
 * A transcode that lands bigger than the file it came from is the worst of both
 * outcomes: more bytes on disk *and* a generation of quality thrown away
 * re-encoding. It is not a corner case — an efficiently encoded source (HEVC,
 * AV1, anything from a careful encoder) routinely sits well under the h264 rate
 * it takes to match it, so "4K · 32 Mbps" against a 12 Mbps HEVC remux is the
 * normal case rather than the odd one. Whenever the original is the smaller
 * file, take the original.
 *
 * Substitutes only downwards in size, and only when both numbers are real: with
 * no size reported by the server there is nothing to compare and the transcode
 * stands. The estimate it is compared against is bitrate x runtime, so a VBR
 * encode that comes in under its cap can still lose this bet — but only by the
 * margin between the cap and the average, and always in the safe direction.
 */
export function effectiveDownloadQuality(item: any, q: DownloadQuality): DownloadQuality {
  if (q.original) return q;
  const original = DOWNLOAD_QUALITIES.find((x) => x.original);
  if (!original) return q;
  const originalSize = estimateDownloadSize(item, original);
  const transcoded = estimateDownloadSize(item, q);
  if (originalSize == null || transcoded == null) return q;
  return originalSize <= transcoded ? original : q;
}

/**
 * Download URLs carry no `api_key`. The Rust downloader authenticates with an
 * Authorization header, which matters more here than for playback: the URL is
 * written into the download's meta.json so an interrupted transfer can resume,
 * and a token embedded in it would sit in the downloads folder indefinitely.
 */
export function buildDownload(item: any, q: DownloadQuality): { url: string; fileName: string } {
  const s = session!;
  const safe = (item.Name ?? item.Id).replace(/[^\w\s.\-()\[\]']/g, "_").slice(0, 120);
  if (q.original) {
    const container = item.MediaSources?.[0]?.Container ?? item.Container ?? "mkv";
    return {
      url: `${s.server}/Items/${item.Id}/Download`,
      fileName: `${safe}.${container}`,
    };
  }
  const p = new URLSearchParams({
    static: "false",
    VideoCodec: "h264",
    AudioCodec: "aac",
    VideoBitrate: String(q.videoBitrate),
    AudioBitrate: String(audioRate(q)),
    MaxWidth: String(q.maxWidth),
    deviceId: s.deviceId,
    Context: "Static",
  });
  return {
    url: `${s.server}/Videos/${item.Id}/stream.mkv?${p}`,
    fileName: `${safe} (${q.name ?? `${q.maxWidth}w`}).mkv`,
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
