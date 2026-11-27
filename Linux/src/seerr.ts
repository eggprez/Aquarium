// Seerr: asking for films and shows the library doesn't have.
//
// Seerr (the request manager that Jellyseerr and Overseerr became) sits beside
// a Jellyfin server and takes requests for it. Nothing here talks to the
// network or holds a credential: every call is handed to the Rust side
// (`seerr.rs`), which signs in with the Jellyfin account already in use, keeps
// Seerr's session in the keyring and adds it to requests there. This file has
// what a view needs: whether a Seerr server is connected, the API calls as
// functions, and the reading of what Seerr answers, so a card's badge, the
// request page's button and the Requests list never disagree.
//
// Seerr describes titles by their TMDB ids, not Jellyfin's, and says of each
// whether it is in the library, asked for, or neither. Every field is treated
// as optional: the API has grown across three projects and a missing key is
// never worth a failed page.
import { invoke } from "@tauri-apps/api/core";

// ---------- The connection ----------

/** What `/settings/public` says, cut down in Rust to the keys read here. */
export interface SeerrPublicSettings {
  initialized?: boolean;
  applicationTitle?: string;
  /** 1 Plex, 2 Jellyfin, 3 Emby, 4 not set up. */
  mediaServerType?: number;
  movie4kEnabled?: boolean;
  series4kEnabled?: boolean;
  /** Whether a show can be asked for a season at a time. */
  partialRequestsEnabled?: boolean;
  cacheImages?: boolean;
  mediaServerLogin?: boolean;
}

/** What the webview is told about the connection. Never the session. */
export interface SeerrStatus {
  connected: boolean;
  /** Scheme, host and any base path; no trailing slash. */
  server?: string;
  /** The address without its scheme, for a line in Settings. */
  host?: string;
  secure?: boolean;
  user_id?: number;
  user_name?: string;
  permissions?: number;
  settings?: SeerrPublicSettings | null;
  /** The session ran out and could not be renewed without the user. */
  needs_reconnect?: boolean;
  /** Where the session is kept: "keyring", or "file" with no keyring. */
  storage?: string;
}

/** What an address turned out to be, before anything is sent to it. */
export interface SeerrProbe {
  server: string;
  secure: boolean;
  /** https was tried first and nothing answered there. */
  fell_back: boolean;
  name: string;
  settings: SeerrPublicSettings;
}

export type SeerrErrorKind = "notconnected" | "unreachable" | "quickconnect" | "reconnect" | "refused" | "message";

/** An error from the Rust side, with the kind it was sent under. */
export class SeerrError extends Error {
  kind: SeerrErrorKind;
  constructor(kind: SeerrErrorKind, message: string) {
    super(message);
    this.name = "SeerrError";
    this.kind = kind;
  }
}

const KINDS: SeerrErrorKind[] = ["notconnected", "unreachable", "quickconnect", "reconnect", "refused", "message"];

/** Rust sends `"<kind>|<message>"`; anything else is a plain message. */
export function seerrError(e: any): SeerrError {
  if (e instanceof SeerrError) return e;
  const raw = typeof e === "string" ? e : e?.message ?? String(e);
  const i = raw.indexOf("|");
  const kind = i > 0 ? raw.slice(0, i) : "";
  if ((KINDS as string[]).includes(kind)) return new SeerrError(kind as SeerrErrorKind, raw.slice(i + 1));
  return new SeerrError("message", raw);
}

let status: SeerrStatus = { connected: false };

/** Fired on `document` whenever the connection changes (connected, gone,
 *  run out, renewed): the sidebar and any Seerr page redraw from it. */
export const SEERR_CHANGED = "aquarium-seerr-changed";
/** Fired on `document` whenever a request is made or withdrawn. */
export const SEERR_REQUESTS_CHANGED = "aquarium-seerr-requests-changed";

function setStatus(next: SeerrStatus | null | undefined): SeerrStatus {
  const clean: SeerrStatus = next && typeof next === "object" && next.connected ? next : { connected: false };
  const changed = JSON.stringify(clean) !== JSON.stringify(status);
  status = clean;
  if (changed) document.dispatchEvent(new CustomEvent(SEERR_CHANGED));
  return status;
}

export function getStatus(): SeerrStatus {
  return status;
}

/** Whether the app should show anything of Seerr's at all. */
export function isConnected(): boolean {
  return status.connected && !status.needs_reconnect;
}

export function needsReconnect(): boolean {
  return status.connected && !!status.needs_reconnect;
}

/** Ask Rust what it holds for the account in use. Never throws: no answer is
 *  "not connected". */
export async function loadStatus(): Promise<SeerrStatus> {
  try {
    return setStatus(await invoke<SeerrStatus>("seerr_status"));
  } catch {
    return setStatus(null);
  }
}

/** The Jellyfin account was signed out or changed: nothing of Seerr's shows
 *  until the next `loadStatus`. */
export function forgetStatus(): void {
  setStatus(null);
}

export async function probe(address: string): Promise<SeerrProbe> {
  try {
    return await invoke<SeerrProbe>("seerr_probe", { address });
  } catch (e) {
    throw seerrError(e);
  }
}

/** Sign in with Quick Connect, as the Jellyfin account in use. A
 *  `quickconnect` error means the password form is next. */
export async function connect(server: string): Promise<SeerrStatus> {
  try {
    return setStatus(await invoke<SeerrStatus>("seerr_connect", { server }));
  } catch (e) {
    throw seerrError(e);
  }
}

/** The fallback: the Jellyfin user name and password, sent to Seerr once and
 *  kept nowhere, here or in Rust. */
export async function connectWithPassword(server: string, username: string, password: string): Promise<SeerrStatus> {
  try {
    return setStatus(await invoke<SeerrStatus>("seerr_connect_password", { server, username, password }));
  } catch (e) {
    throw seerrError(e);
  }
}

export async function reconnect(): Promise<SeerrStatus> {
  try {
    return setStatus(await invoke<SeerrStatus>("seerr_reconnect"));
  } catch (e) {
    throw seerrError(e);
  }
}

/** Sign out of Seerr and forget it on this device. */
export async function disconnect(): Promise<void> {
  try {
    setStatus(await invoke<SeerrStatus>("seerr_disconnect"));
  } catch {
    await loadStatus();
  }
}

/** Bring the remembered permissions and server settings up to date. Quiet. */
export async function refreshAccount(): Promise<void> {
  if (!status.connected) return;
  const wasOn = status.settings?.cacheImages === true;
  try {
    setStatus(await invoke<SeerrStatus>("seerr_refresh"));
  } catch {
    /* what is remembered stands */
  }
  if (!wasOn && status.connected && status.settings?.cacheImages === true) posterEpoch += 1;
}

/** Bumped when Seerr's Cache Images comes on. Poster addresses carry it, so
 *  the webview asks again for pictures it was refused (and may remember
 *  refusing) instead of leaving them blank. Seerr's proxy ignores the query. */
let posterEpoch = 0;

/** One Seerr API call. `path` is below `/api/v1` and already query-encoded. */
async function call(path: string, method = "GET", body: any = null): Promise<{ status: number; body: any }> {
  try {
    return await invoke<{ status: number; body: any }>("seerr_request", { path, method, body });
  } catch (e) {
    const err = seerrError(e);
    if (err.kind === "reconnect" && status.connected && !status.needs_reconnect) {
      setStatus({ ...status, needs_reconnect: true });
    } else if (err.kind === "notconnected" && status.connected) {
      setStatus(null);
    }
    throw err;
  }
}

async function get(path: string): Promise<any> {
  const res = await call(path);
  if (res.body == null || typeof res.body !== "object") {
    throw new SeerrError("message", "Seerr sent something this app couldn't read");
  }
  return res.body;
}

// ---------- What Seerr says ----------

export type SeerrMediaKind = "movie" | "tv";

export const KIND_NOUN: Record<SeerrMediaKind, string> = { movie: "film", tv: "show" };

export interface SeerrSeasonState {
  seasonNumber?: number;
  status?: number;
}

export interface SeerrUser {
  id?: number;
  displayName?: string;
}

/** One request: who asked, for what, and how far it has got. */
export interface SeerrRequest {
  id: number;
  /** 1 pending, 2 approved, 3 declined, 4 failed, 5 completed. */
  status?: number;
  createdAt?: string;
  type?: string;
  is4k?: boolean;
  media?: SeerrMediaInfo | null;
  seasons?: SeerrSeasonState[];
  requestedBy?: SeerrUser | null;
}

/** What Seerr knows about a title it has met. */
export interface SeerrMediaInfo {
  id?: number;
  mediaType?: string;
  tmdbId?: number;
  /** 1 unknown, 2 pending, 3 processing, 4 partially available, 5 available. */
  status?: number;
  status4k?: number;
  /** The title's id on the Jellyfin server, once it is there. */
  jellyfinMediaId?: string;
  jellyfinMediaId4k?: string;
  /** Which of Seerr's Radarr or Sonarr servers holds the title, and its id
   *  there. Absent for a title Seerr only knows from the Jellyfin library. */
  serviceId?: number | null;
  serviceId4k?: number | null;
  externalServiceId?: number | null;
  externalServiceId4k?: number | null;
  seasons?: SeerrSeasonState[];
  requests?: SeerrRequest[];
}

/** A title in a list: search, the browse rows, a collection, someone's credits. */
export interface SeerrResult {
  /** The TMDB id. */
  id: number;
  mediaType?: string;
  title?: string;
  name?: string;
  overview?: string;
  posterPath?: string | null;
  backdropPath?: string | null;
  releaseDate?: string;
  firstAirDate?: string;
  mediaInfo?: SeerrMediaInfo | null;
}

export interface SeerrSeason {
  seasonNumber: number;
  name?: string;
  episodeCount?: number;
  airDate?: string;
}

/** A film's or a show's own page. One shape for both: the fields a film
 *  lacks (seasons) and the ones a show lacks (runtime) are simply absent. */
export interface SeerrTitle extends SeerrResult {
  tagline?: string;
  runtime?: number;
  genres?: { id?: number; name?: string }[];
  credits?: { cast?: { id?: number; name?: string; character?: string }[] };
  seasons?: SeerrSeason[];
}

export interface SeerrAllowance {
  days?: number;
  limit?: number;
  used?: number;
  remaining?: number;
  restricted?: boolean;
}

export interface SeerrQuota {
  movie?: SeerrAllowance;
  tv?: SeerrAllowance;
}

/** Where a title stands in the library, as Seerr numbers it. */
export type Availability = "unknown" | "pending" | "processing" | "partiallyAvailable" | "available";

const AVAILABILITY: Availability[] = ["unknown", "pending", "processing", "partiallyAvailable", "available"];

export function availability(raw: number | null | undefined): Availability {
  return typeof raw === "number" && Number.isInteger(raw) && raw >= 1 && raw <= 5 ? AVAILABILITY[raw - 1]! : "unknown";
}

type RequestStatus = "pending" | "approved" | "declined" | "failed" | "completed";

const REQUEST_STATUS: RequestStatus[] = ["pending", "approved", "declined", "failed", "completed"];

export function requestStatus(raw: number | null | undefined): RequestStatus {
  return typeof raw === "number" && Number.isInteger(raw) && raw >= 1 && raw <= 5 ? REQUEST_STATUS[raw - 1]! : "pending";
}

/** A film or a show. Seerr's other result kinds (people, collections) are
 *  read as `null` and left out. */
export function kindOf(thing: { mediaType?: string | null } | null | undefined): SeerrMediaKind | null {
  const kind = thing?.mediaType;
  return kind === "movie" || kind === "tv" ? kind : null;
}

export function requestKind(request: SeerrRequest): SeerrMediaKind | null {
  return kindOf({ mediaType: request.type ?? request.media?.mediaType });
}

export function displayTitle(thing: { title?: string; name?: string } | null | undefined): string {
  return thing?.title ?? thing?.name ?? "";
}

/** "2024" from "2024-03-01". */
export function yearOf(date: string | null | undefined): string | null {
  if (!date || date.length < 4) return null;
  const year = date.slice(0, 4);
  return /^\d{4}$/.test(year) ? year : null;
}

export function resultYear(thing: { releaseDate?: string; firstAirDate?: string } | null | undefined): string | null {
  return yearOf(thing?.releaseDate ?? thing?.firstAirDate);
}

/** The title's id on the Jellyfin server, when Seerr knows it. */
export function libraryItemId(media: SeerrMediaInfo | null | undefined): string | null {
  return media?.jellyfinMediaId || media?.jellyfinMediaId4k || null;
}

/** Worth offering among things the library lacks: a film or a show none of
 *  which is here. A show that is partly here is not a stranger; its own
 *  library page says which seasons are missing. */
export function isRequestable(result: SeerrResult): boolean {
  const state = availability(result.mediaInfo?.status);
  return kindOf(result) != null && state !== "available" && state !== "partiallyAvailable";
}

/** One key for a title across lists: "movie-603". */
export function resultKey(result: SeerrResult): string {
  return `${result.mediaType ?? "?"}-${result.id}`;
}

// ---------- What a person sees ----------

/** Where a title stands, in the words the app uses. */
export type Standing =
  | "requestable" // not in the library and not asked for
  | "awaitingApproval" // asked for; an administrator has not said yes yet
  | "onItsWay" // approved and being fetched
  | "partlyAvailable" // a show with some seasons in the library and others not
  | "available"
  | "declined"
  | "failed";

export const STANDING_LABEL: Record<Standing, string> = {
  requestable: "Not in your library",
  awaitingApproval: "Waiting for approval",
  onItsWay: "On its way",
  partlyAvailable: "Some seasons available",
  available: "In your library",
  declined: "Declined",
  failed: "Couldn't be fetched",
};

/** The short form, for a badge on a poster. `null` draws none. */
export const STANDING_BADGE: Record<Standing, string | null> = {
  requestable: null,
  awaitingApproval: "Requested",
  onItsWay: "On its way",
  partlyAvailable: "Partly here",
  available: "In library",
  declined: "Declined",
  failed: "Failed",
};

/** From what Seerr says about the title as a whole. */
export function standingOfMedia(media: SeerrMediaInfo | null | undefined): Standing {
  switch (availability(media?.status)) {
    case "available": return "available";
    case "partiallyAvailable": return "partlyAvailable";
    case "processing": return "onItsWay";
    case "pending": return "awaitingApproval";
    default: return "requestable";
  }
}

/** From one request, which knows more than its title does: a declined
 *  request leaves the title "unknown". */
export function standingOfRequest(request: SeerrRequest): Standing {
  switch (requestStatus(request.status)) {
    case "declined": return "declined";
    case "failed": return "failed";
    case "pending": return "awaitingApproval";
    case "completed": return "available";
    default:
      switch (availability(request.media?.status)) {
        case "available": return "available";
        case "partiallyAvailable": return "partlyAvailable";
        default: return "onItsWay";
      }
  }
}

/** The numbered seasons. Season 0 is "Specials", which Seerr's own page
 *  leaves out unless an administrator turns it on. */
export function realSeasons(title: SeerrTitle): SeerrSeason[] {
  return (title.seasons ?? []).filter((s) => typeof s?.seasonNumber === "number" && s.seasonNumber > 0);
}

/** The seasons that can still be asked for: not in the library, and not
 *  already covered by a request that is pending or approved. */
export function requestableSeasons(title: SeerrTitle): SeerrSeason[] {
  const taken = new Set<number>();
  for (const season of title.mediaInfo?.seasons ?? []) {
    if (availability(season.status) !== "unknown" && typeof season.seasonNumber === "number") taken.add(season.seasonNumber);
  }
  for (const request of title.mediaInfo?.requests ?? []) {
    const st = requestStatus(request.status);
    if (st !== "pending" && st !== "approved") continue;
    for (const season of request.seasons ?? []) {
      if (typeof season.seasonNumber === "number") taken.add(season.seasonNumber);
    }
  }
  return realSeasons(title).filter((s) => !taken.has(s.seasonNumber));
}

/** What one season's row says. */
export function standingOfSeason(title: SeerrTitle, number: number): Standing {
  const state = (title.mediaInfo?.seasons ?? []).find((s) => s.seasonNumber === number);
  if (state) {
    switch (availability(state.status)) {
      case "available": return "available";
      case "partiallyAvailable": return "partlyAvailable";
      case "processing": return "onItsWay";
      case "pending": return "awaitingApproval";
      default: break;
    }
  }
  for (const request of title.mediaInfo?.requests ?? []) {
    if (!(request.seasons ?? []).some((s) => s.seasonNumber === number)) continue;
    const st = requestStatus(request.status);
    if (st === "pending") return "awaitingApproval";
    if (st === "approved") return "onItsWay";
  }
  return "requestable";
}

// What a Seerr account may do: a bit mask, the way Seerr stores it.
export const PERMISSION = {
  admin: 2,
  manageRequests: 16,
  request: 32,
  autoApprove: 128,
  request4K: 1024,
  request4KMovie: 2048,
  request4KTV: 4096,
  requestMovie: 262_144,
  requestTV: 524_288,
} as const;

export function canRequest(permissions: number | null | undefined, kind: SeerrMediaKind): boolean {
  const p = permissions ?? 0;
  if (p & PERMISSION.admin || p & PERMISSION.request) return true;
  return !!(p & (kind === "movie" ? PERMISSION.requestMovie : PERMISSION.requestTV));
}

export function canRequest4K(permissions: number | null | undefined, kind: SeerrMediaKind): boolean {
  const p = permissions ?? 0;
  if (p & PERMISSION.admin || p & PERMISSION.request4K) return true;
  return !!(p & (kind === "movie" ? PERMISSION.request4KMovie : PERMISSION.request4KTV));
}

/** "2 of 5 requests left this week", or null when there is no limit. */
export function quotaSummary(allowance: SeerrAllowance | null | undefined): string | null {
  const limit = allowance?.limit;
  const remaining = allowance?.remaining;
  if (typeof limit !== "number" || limit <= 0 || typeof remaining !== "number") return null;
  const days = allowance?.days ?? 0;
  const span = days === 1 ? "today" : days === 7 ? "this week" : days > 1 ? `in ${days} days` : "";
  const left = Math.max(0, remaining);
  return `${left} of ${limit} request${limit === 1 ? "" : "s"} left ${span}`.trim();
}

/** "Season 3", "Seasons 3 and 4", "Seasons 3, 4 and 5". */
export function seasonList(numbers: number[]): string {
  const n = numbers.map(String);
  if (!n.length) return "";
  if (n.length === 1) return `Season ${n[0]}`;
  return `Seasons ${n.slice(0, -1).join(", ")} and ${n[n.length - 1]}`;
}

/** "1999 · Film · 2 h 16 min · Drama, Action". */
export function titleFacts(title: SeerrTitle, kind: SeerrMediaKind): string {
  const parts: string[] = [];
  const year = resultYear(title);
  if (year) parts.push(year);
  parts.push(kind === "movie" ? "Film" : "Show");
  if (kind === "movie" && typeof title.runtime === "number" && title.runtime > 0) {
    const m = title.runtime;
    parts.push(m >= 60 ? `${Math.floor(m / 60)} h ${m % 60} min` : `${m} min`);
  }
  if (kind === "tv") {
    const count = realSeasons(title).length;
    if (count > 0) parts.push(`${count} season${count === 1 ? "" : "s"}`);
  }
  const genres = (title.genres ?? []).map((g) => g?.name).filter((g): g is string => !!g).slice(0, 3);
  if (genres.length) parts.push(genres.join(", "));
  return parts.join(" · ");
}

/** What the request button says. `chosen` is how many seasons are ticked. */
export function requestLabel(title: SeerrTitle, kind: SeerrMediaKind, chosen: number): string {
  if (kind !== "tv") return "Request";
  const open = requestableSeasons(title).length;
  if (chosen === open && open === realSeasons(title).length) return "Request All Seasons";
  return `Request ${chosen} Season${chosen === 1 ? "" : "s"}`;
}

/** One request's line under its title: "Show · 2016 · Seasons 2, 3 · 4K". */
export function requestDetail(request: SeerrRequest, title: SeerrTitle | null | undefined): string {
  const kind = requestKind(request);
  const parts: string[] = [kind === "tv" ? "Show" : "Film"];
  const year = resultYear(title);
  if (year) parts.push(year);
  if (kind === "tv") {
    const numbers = (request.seasons ?? [])
      .map((s) => s.seasonNumber)
      .filter((n): n is number => typeof n === "number")
      .sort((a, b) => a - b);
    if (numbers.length) parts.push(`Season${numbers.length === 1 ? "" : "s"} ${numbers.join(", ")}`);
  }
  if (request.is4k === true) parts.push("4K");
  return parts.join(" · ");
}

/** This account's own request for the title that is still waiting, which is
 *  the one Seerr lets it take back. */
export function myPendingRequest(title: SeerrTitle, userId: number | null | undefined): SeerrRequest | null {
  if (userId == null) return null;
  return (
    (title.mediaInfo?.requests ?? []).find(
      (r) => r.requestedBy?.id === userId && requestStatus(r.status) === "pending"
    ) ?? null
  );
}

/** A Jellyfin item's TMDB id, whatever case the server wrote the key in. */
export function tmdbIdOf(item: any): number | null {
  const ids = item?.ProviderIds;
  if (!ids || typeof ids !== "object") return null;
  for (const [k, v] of Object.entries(ids)) {
    if (k.toLowerCase() !== "tmdb") continue;
    const text = String(v ?? "");
    return /^\d+$/.test(text) ? Number(text) : null;
  }
  return null;
}

/** A search term escaped down to unreserved characters; Seerr refuses
 *  anything looser (`encodeURIComponent` leaves `!'()*` alone). */
export function encodeQuery(term: string): string {
  return encodeURIComponent(term).replace(/[!'()*]/g, (c) => `%${c.charCodeAt(0).toString(16).toUpperCase()}`);
}

// ---------- Titles ----------

function results(body: any): SeerrResult[] {
  return Array.isArray(body?.results) ? body.results.filter((r: any) => r && typeof r.id === "number") : [];
}

/** Seerr's search: films, shows, and (left in for the caller to drop) people
 *  and collections. */
export async function search(term: string, page = 1): Promise<SeerrResult[]> {
  return results(await get(`/search?query=${encodeQuery(term)}&page=${page}`));
}

/** What Search offers under the library's own results: films and shows by
 *  that name that are not already here. */
export function notInLibrary(found: SeerrResult[]): SeerrResult[] {
  return found.filter(isRequestable);
}

export interface BrowseRow {
  key: string;
  title: string;
  path: string;
  /** The discover lists for one kind leave `mediaType` off each entry. */
  kind: SeerrMediaKind | null;
}

/** The rows of the Requests page, in the order drawn. */
export const BROWSE_ROWS: BrowseRow[] = [
  { key: "trending", title: "Trending", path: "/discover/trending", kind: null },
  { key: "popularMovies", title: "Popular Films", path: "/discover/movies", kind: "movie" },
  { key: "popularTV", title: "Popular Shows", path: "/discover/tv", kind: "tv" },
  { key: "upcomingMovies", title: "Upcoming Films", path: "/discover/movies/upcoming", kind: "movie" },
  { key: "upcomingTV", title: "Upcoming Shows", path: "/discover/tv/upcoming", kind: "tv" },
];

/** Give the entries of a one-kind list the kind they were left without. */
export function withKind(list: SeerrResult[], kind: SeerrMediaKind | null): SeerrResult[] {
  if (!kind) return list;
  return list.map((r) => (r.mediaType == null ? { ...r, mediaType: kind } : r));
}

/** One browse row: films and shows only. */
export async function browse(row: BrowseRow, page = 1): Promise<SeerrResult[]> {
  const list = withKind(results(await get(`${row.path}?page=${page}`)), row.kind);
  return list.filter((r) => kindOf(r) != null);
}

export async function title(kind: SeerrMediaKind, tmdbId: number): Promise<SeerrTitle> {
  const body = await get(`/${kind}/${tmdbId}`);
  if (typeof body.id !== "number") throw new SeerrError("message", "Seerr sent something this app couldn't read");
  return body as SeerrTitle;
}

/** A collection's films, each given the kind the list leaves off. */
export async function collection(tmdbId: number): Promise<SeerrResult[]> {
  const body = await get(`/collection/${tmdbId}`);
  const parts: SeerrResult[] = Array.isArray(body.parts) ? body.parts.filter((p: any) => p && typeof p.id === "number") : [];
  return withKind(parts, "movie");
}

/** Seerr's recommendations for a title, or its similar titles when it has
 *  none (TMDB has none for many smaller titles), each given its kind. */
export async function likeThis(kind: SeerrMediaKind, tmdbId: number): Promise<SeerrResult[]> {
  const list = async (which: string): Promise<SeerrResult[]> => {
    const body = await get(`/${kind}/${tmdbId}/${which}?page=1`);
    const results: SeerrResult[] = Array.isArray(body.results) ? body.results.filter((r: any) => r && typeof r.id === "number") : [];
    return withKind(results, kind);
  };
  const recommended = await list("recommendations");
  return recommended.length ? recommended : list("similar");
}

/** What a library item is, as Seerr knows titles: a film or a show is
 *  itself; a season or an episode is its show (`seriesId`), since Jellyfin's
 *  TMDB id on those is their own. `null` for anything else. */
export function likeThisSubject(item: any): { kind: SeerrMediaKind; seriesId: string | null } | null {
  switch (item?.Type) {
    case "Movie":
      return { kind: "movie", seriesId: null };
    case "Series":
      return { kind: "tv", seriesId: null };
    case "Season":
    case "Episode":
      return item.SeriesId ? { kind: "tv", seriesId: String(item.SeriesId) } : null;
    default:
      return null;
  }
}

/** Everything someone has been in or made, newest first, each title once. */
export function sortCredits(cast: SeerrResult[], crew: SeerrResult[]): SeerrResult[] {
  const seen = new Set<string>();
  const date = (r: SeerrResult): string => r.releaseDate ?? r.firstAirDate ?? "";
  return [...cast, ...crew]
    .filter((r) => {
      if (kindOf(r) == null || seen.has(resultKey(r))) return false;
      seen.add(resultKey(r));
      return true;
    })
    .sort((a, b) => (date(a) < date(b) ? 1 : date(a) > date(b) ? -1 : 0));
}

export async function credits(personTmdbId: number): Promise<SeerrResult[]> {
  const body = await get(`/person/${personTmdbId}/combined_credits`);
  const list = (v: any): SeerrResult[] => (Array.isArray(v) ? v.filter((r: any) => r && typeof r.id === "number") : []);
  return sortCredits(list(body.cast), list(body.crew));
}

// ---------- Requests ----------

function requestsChanged(): void {
  document.dispatchEvent(new CustomEvent(SEERR_REQUESTS_CHANGED));
}

/** Ask for a film, or for seasons of a show. */
export async function request(
  kind: SeerrMediaKind,
  tmdbId: number,
  opts: { seasons?: number[]; is4k?: boolean } = {}
): Promise<SeerrRequest> {
  const body: Record<string, any> = { mediaType: kind, mediaId: tmdbId, is4k: !!opts.is4k };
  if (kind === "tv" && opts.seasons) body.seasons = opts.seasons;
  // Made or refused, what the lists say about this title is out of date.
  const res = await call("/request", "POST", body).finally(requestsChanged);
  // Seerr answers 202 with a message, not a request, when every season asked
  // for turned out to be taken already.
  if (res.status === 202) {
    throw new SeerrError("refused", "Every season of that is already in the library or requested.");
  }
  if (!res.body || typeof res.body.id !== "number") {
    throw new SeerrError("message", "Seerr took the request but sent back something this app couldn't read");
  }
  return res.body as SeerrRequest;
}

/** This account's requests, newest first. */
export async function myRequests(take = 40, skip = 0): Promise<SeerrRequest[]> {
  if (!status.connected || status.user_id == null) throw new SeerrError("notconnected", "Requests aren't set up");
  const body = await get(`/request?take=${take}&skip=${skip}&sort=added&requestedBy=${status.user_id}`);
  return Array.isArray(body.results) ? body.results.filter((r: any) => r && typeof r.id === "number") : [];
}

/** Withdraw a request. Seerr lets an account remove its own while they are
 *  still waiting for approval. */
export async function cancel(request: SeerrRequest): Promise<void> {
  await call(`/request/${request.id}`, "DELETE");
  requestsChanged();
}

// ---------- Removing a title ----------
// Delete from Server's second way: out of Radarr (a film) or Sonarr (a show),
// which deletes the files there, then the requests and Seerr's own record, so
// the title can be asked for again. Whole titles only.

/** Taking a title out through Seerr; only made when all of it can be done. */
export interface SeerrRemoval {
  kind: SeerrMediaKind;
  tmdbId: number;
  /** Seerr's own id for the title, which its media routes are addressed by. */
  mediaId: number;
  /** The copies to remove: `false` the ordinary one, `true` the 4K one. */
  copies: boolean[];
  requestIds: number[];
}

export function serviceName(kind: SeerrMediaKind): string {
  return kind === "movie" ? "Radarr" : "Sonarr";
}

export function canManageRequests(permissions: number | null | undefined): boolean {
  const p = permissions ?? 0;
  return !!(p & PERMISSION.admin || p & PERMISSION.manageRequests);
}

/** What a library item is to Radarr or Sonarr: a film or a whole show. */
export function removalKind(item: any): SeerrMediaKind | null {
  return item?.Type === "Movie" ? "movie" : item?.Type === "Series" ? "tv" : null;
}

/** Worth looking into, from what is already known. Asks nothing. */
export function mightRemove(item: any): boolean {
  return isConnected() && canManageRequests(status.permissions) && removalKind(item) != null;
}

/**
 * Which copies of a title Seerr can take out: `false` the ordinary one, `true`
 * the 4K one. Seerr's own rule (`DELETE /media/{id}/file`): it finds the title
 * on Radarr or Sonarr by its TMDB or TVDB id, on its default server of that
 * kind or the one its record names, so the record needs no link to a server.
 * A title put on Radarr by hand, known to Seerr only from the Jellyfin
 * library, can be removed too.
 */
export function removableCopies(media: any, servers: any[]): boolean[] {
  const offered = (fourK: boolean): boolean => {
    const service = fourK ? media.serviceId4k : media.serviceId;
    const linked = service != null || (fourK ? media.externalServiceId4k : media.externalServiceId) != null;
    const status = (fourK ? media.status4k : media.status) ?? 1;
    if (!linked && !(status >= 3 && status <= 5)) return false;
    return servers.some((s: any) => (s?.is4k === true) === fourK && (s?.isDefault === true || (service != null && s?.id === service)));
  };
  return [false, true].filter(offered);
}

/**
 * Whether this title can be taken out through Seerr, and how. Null unless the
 * account may manage requests, Seerr has a Radarr (film) or Sonarr (show)
 * server it would use, and a record of the title as on one or in the library. `item` needs
 * its TMDB id (the detail fields).
 */
export async function removal(item: any): Promise<SeerrRemoval | null> {
  const kind = removalKind(item);
  const tmdbId = tmdbIdOf(item);
  if (!mightRemove(item) || !kind || tmdbId == null) return null;
  try {
    const servers = await get(`/service/${kind === "movie" ? "radarr" : "sonarr"}`);
    if (!Array.isArray(servers) || !servers.length) return null;
    const media = (await title(kind, tmdbId)).mediaInfo;
    if (!media || typeof media.id !== "number") return null;
    const copies = removableCopies(media, servers);
    if (!copies.length) return null;
    const requestIds = (media.requests ?? []).map((r) => r?.id).filter((id): id is number => typeof id === "number");
    return { kind, tmdbId, mediaId: media.id, copies, requestIds };
  } catch {
    return null;
  }
}

/** Do it. Only the first step's failure stops the rest; a request already
 *  gone is not a failure. */
export async function remove(what: SeerrRemoval): Promise<void> {
  try {
    for (const is4k of what.copies) await call(`/media/${what.mediaId}/file?is4k=${is4k}`, "DELETE");
    for (const id of what.requestIds) await call(`/request/${id}`, "DELETE").catch(() => undefined);
    await call(`/media/${what.mediaId}`, "DELETE");
  } finally {
    requestsChanged();
  }
}

export async function quota(): Promise<SeerrQuota> {
  if (!status.connected || status.user_id == null) throw new SeerrError("notconnected", "Requests aren't set up");
  return (await get(`/user/${status.user_id}/quota`)) as SeerrQuota;
}

// ---------- Pictures ----------

export const IMAGE_SIZE = { poster: "w342", posterLarge: "w500", backdrop: "w1280", face: "w185" } as const;

/**
 * Where a TMDB picture is fetched from: always through the Seerr server
 * itself (its `/imageproxy`, which it serves to anyone and without a cookie),
 * never from TMDB's own image host. Seerr's web pages send a browser to TMDB
 * unless image caching is turned on; this app doesn't, so that nothing outside
 * the user's own servers ever sees the device. With no Seerr connection there
 * is no picture address at all.
 *
 * The webview loads it with a plain `<img>`, the way it loads Jellyfin's
 * posters: the session cookie lives in Rust and never in the webview, so the
 * request carries none.
 */
/** The page's name: the server it shows, as its makers name it. */
export const PAGE_TITLE = "Seerr";
/** Seerr's titles are TMDB's; TMDB's terms ask apps showing its data to say
 *  so, and that it doesn't endorse them. Same words as the Apple app. */
export const CREDIT =
  "Requests and suggestions come from Seerr, the open-source request manager (docs.seerr.dev). Film and show details and posters are from TMDB. Aquarium isn't made, endorsed or certified by Seerr or TMDB.";
export const POSTERS_OFF_TITLE = "No posters from Seerr";
export const POSTERS_OFF =
  "Seerr only shares posters when Cache Images is on. An admin can turn it on in Seerr's Settings, under General. Aquarium doesn't fetch them from the film database directly.";

/** The server says Cache Images is off, so its `/imageproxy` answers 404 to
 *  every poster (Seerr's default). Only a definite `false` counts. */
export function postersOff(): boolean {
  return status.connected === true && status.settings?.cacheImages === false;
}

export function imageUrl(path: string | null | undefined, size: keyof typeof IMAGE_SIZE = "poster"): string | null {
  if (!path || !path.startsWith("/") || !status.connected || !status.server) return null;
  const url = `${status.server}/imageproxy/tmdb/t/p/${IMAGE_SIZE[size]}${path}`;
  return posterEpoch ? `${url}?r=${posterEpoch}` : url;
}

/** Where a title Seerr named opens: the library's own page when it is already
 *  here, its request page when it isn't. `null` for what is neither a film
 *  nor a show. */
export function hashFor(result: SeerrResult): string | null {
  const kind = kindOf(result);
  if (!kind) return null;
  const here = libraryItemId(result.mediaInfo);
  if (availability(result.mediaInfo?.status) === "available" && here) return `#/item/${here}`;
  return `#/request/${kind}/${result.id}`;
}

/** Where a row of the Requests list opens. */
export function hashForRequest(request: SeerrRequest): string | null {
  const kind = requestKind(request);
  const tmdbId = request.media?.tmdbId;
  if (!kind || typeof tmdbId !== "number") return null;
  const here = libraryItemId(request.media);
  if (standingOfRequest(request) === "available" && here) return `#/item/${here}`;
  return `#/request/${kind}/${tmdbId}`;
}

// ---------- The sentences Settings says ----------

export const COPY = {
  offer:
    "Seerr takes requests for films and shows the library doesn't have yet. Connect one and they can be asked for from Search and from a Requests page.",
  kept: "Aquarium signed in to Seerr with your Jellyfin account. Only Seerr's session is kept, in the keyring beside your Jellyfin sign-in; no password is stored.",
  keptInFile:
    "Aquarium signed in to Seerr with your Jellyfin account. Only Seerr's session is kept; your desktop keyring is unavailable, so it is in ~/.config/aquarium/config.json beside your Jellyfin sign-in. No password is stored.",
};
