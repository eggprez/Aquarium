// The music half of the API: artists, albums, songs, genres, playlists,
// audiobooks, and the mixes the server builds from any of them. Modelled on
// the Apple app's `JellyfinClient+Music.swift`; kept apart from `api.ts`
// because the questions are a different shape — a film library is browsed by
// title, a music library by the people who made it.
//
// Same rules as the rest: every request through `api()` (Rust `jf_request`),
// `userId=` query routes only.
import { api, getSession, imageUrl } from "./api";

/** What a list of songs, albums or artists needs. `MediaSources` is left out
 *  on purpose: a song's carries every stream in the file, and three thousand
 *  of them is megabytes nobody reads until one is played. */
export const MUSIC_FIELDS =
  "PrimaryImageAspectRatio,Genres,UserData,ChildCount,ProductionYear,RunTimeTicks,DateCreated,ParentId,SortName,AlbumArtists,ArtistItems,MediaType";

/** The above plus what one page draws: a biography, the file, chapters. */
export const MUSIC_DETAIL_FIELDS = `${MUSIC_FIELDS},Overview,MediaSources,Chapters,GenreItems,Studios,Path`;

/** How a list is ordered; the key is what the server is sent. */
export interface MusicSort {
  key: string;
  label: string;
  descending: boolean;
}

export const SORTS: Record<string, MusicSort> = {
  name: { key: "SortName", label: "Title", descending: false },
  artist: { key: "AlbumArtist,SortName", label: "Artist", descending: false },
  added: { key: "DateCreated,SortName", label: "Recently added", descending: true },
  year: { key: "ProductionYear,SortName", label: "Year", descending: true },
  played: { key: "DatePlayed,SortName", label: "Recently played", descending: true },
  plays: { key: "PlayCount,SortName", label: "Most played", descending: true },
  random: { key: "Random", label: "Random", descending: false },
};

export interface MusicQuery {
  types: string;
  parentId?: string;
  sort?: keyof typeof SORTS;
  descending?: boolean;
  startIndex?: number;
  limit?: number;
  albumArtistIds?: string[];
  artistIds?: string[];
  genreIds?: string[];
  genres?: string[];
  favorites?: boolean;
  played?: boolean;
  searchTerm?: string;
  years?: number[];
  fields?: string;
  recursive?: boolean;
  excludeIds?: string[];
}

function sess() {
  const s = getSession();
  if (!s) throw new Error("Not signed in");
  return s;
}

/** One query for most of it. */
export async function music(q: MusicQuery): Promise<{ Items: any[]; TotalRecordCount: number }> {
  const s = sess();
  const sort = SORTS[q.sort ?? "name"];
  const p = new URLSearchParams({
    userId: s.userId,
    IncludeItemTypes: q.types,
    Recursive: q.recursive === false ? "false" : "true",
    SortBy: sort.key,
    SortOrder: (q.descending ?? sort.descending) ? "Descending" : "Ascending",
    Fields: q.fields ?? MUSIC_FIELDS,
    StartIndex: String(q.startIndex ?? 0),
    Limit: String(q.limit ?? 100),
    EnableImageTypes: "Primary,Backdrop",
    ImageTypeLimit: "1",
  });
  if (q.parentId) p.set("ParentId", q.parentId);
  if (q.albumArtistIds?.length) p.set("AlbumArtistIds", q.albumArtistIds.join(","));
  if (q.artistIds?.length) p.set("ArtistIds", q.artistIds.join(","));
  if (q.genreIds?.length) p.set("GenreIds", q.genreIds.join(","));
  if (q.genres?.length) p.set("Genres", q.genres.join("|"));
  if (q.years?.length) p.set("Years", q.years.join(","));
  if (q.excludeIds?.length) p.set("ExcludeItemIds", q.excludeIds.join(","));
  const filters: string[] = [];
  if (q.favorites) filters.push("IsFavorite");
  if (q.played === true) filters.push("IsPlayed");
  if (q.played === false) filters.push("IsUnplayed");
  if (filters.length) p.set("Filters", filters.join(","));
  if (q.searchTerm) p.set("SearchTerm", q.searchTerm);
  const r = await api(`/Items?${p}`);
  return { Items: r?.Items ?? [], TotalRecordCount: r?.TotalRecordCount ?? (r?.Items?.length ?? 0) };
}

/** Artists with an album to their name — what a music library means by
 *  "Artists". `all` is everyone credited anywhere, for search. */
export async function artists(
  opts: { all?: boolean; startIndex?: number; limit?: number; favorites?: boolean; searchTerm?: string; sort?: keyof typeof SORTS } = {}
): Promise<{ Items: any[]; TotalRecordCount: number }> {
  const s = sess();
  const sort = SORTS[opts.sort ?? "name"];
  const p = new URLSearchParams({
    userId: s.userId,
    SortBy: sort.key,
    SortOrder: sort.descending ? "Descending" : "Ascending",
    Fields: MUSIC_FIELDS,
    StartIndex: String(opts.startIndex ?? 0),
    Limit: String(opts.limit ?? 200),
    EnableImageTypes: "Primary,Backdrop",
    ImageTypeLimit: "1",
  });
  if (opts.favorites) p.set("IsFavorite", "true");
  if (opts.searchTerm) p.set("SearchTerm", opts.searchTerm);
  const r = await api(`${opts.all ? "/Artists" : "/Artists/AlbumArtists"}?${p}`);
  return { Items: r?.Items ?? [], TotalRecordCount: r?.TotalRecordCount ?? 0 };
}

export async function musicItem(id: string): Promise<any> {
  const s = sess();
  return api(`/Items/${id}?userId=${s.userId}&Fields=${MUSIC_DETAIL_FIELDS}`);
}

/** Disc, then track, then name — the order a sleeve lists them in. */
export function sortedByTrack(items: any[]): any[] {
  return [...items].sort((a, b) => {
    const da = a.ParentIndexNumber ?? 1, db = b.ParentIndexNumber ?? 1;
    if (da !== db) return da - db;
    const ta = a.IndexNumber ?? Number.MAX_SAFE_INTEGER, tb = b.IndexNumber ?? Number.MAX_SAFE_INTEGER;
    if (ta !== tb) return ta - tb;
    return String(a.Name ?? "").localeCompare(String(b.Name ?? ""));
  });
}

export async function albumTracks(albumId: string): Promise<any[]> {
  const r = await music({ types: "Audio", parentId: albumId, limit: 500 });
  return sortedByTrack(r.Items);
}

export async function topSongs(artistId: string, limit = 10): Promise<any[]> {
  return (await music({ types: "Audio", sort: "plays", artistIds: [artistId], limit })).Items;
}

export async function allSongs(artistId: string): Promise<any[]> {
  return (await music({ types: "Audio", sort: "artist", artistIds: [artistId], limit: 2000 })).Items;
}

export async function albumsBy(artistId: string): Promise<any[]> {
  return (await music({ types: "MusicAlbum", sort: "year", albumArtistIds: [artistId], limit: 200 })).Items;
}

/** Albums the artist is on without being the album artist. */
export async function appearsOn(artistId: string): Promise<any[]> {
  const r = await music({ types: "MusicAlbum", sort: "year", artistIds: [artistId], limit: 200 });
  return r.Items.filter((a) => !(a.AlbumArtists ?? []).some((x: any) => x.Id === artistId));
}

export async function genreSongs(genreId: string, limit = 500): Promise<any[]> {
  return (await music({ types: "Audio", sort: "random", genreIds: [genreId], limit })).Items;
}

export async function musicGenres(): Promise<any[]> {
  const s = sess();
  const p = new URLSearchParams({
    userId: s.userId,
    SortBy: "SortName",
    SortOrder: "Ascending",
    Limit: "2000",
    EnableImageTypes: "Primary",
    ImageTypeLimit: "1",
    IncludeItemTypes: "Audio,MusicAlbum",
  });
  const r = await api(`/MusicGenres?${p}`);
  return r?.Items ?? [];
}

// ---------- Playlists ----------

export async function audioPlaylists(): Promise<any[]> {
  const r = await music({ types: "Playlist", limit: 500 });
  return r.Items.filter((p) => (p.MediaType ?? "Audio") === "Audio");
}

/**
 * A playlist's songs, in the playlist's own order. `/Playlists/{id}/Items` is
 * the route made for it and answers 403 for a playlist the account doesn't
 * own; `/Items?ParentId=` is what Jellyfin's web client uses and keeps the
 * order, so it is the fallback when the first fails or comes back empty.
 */
export async function playlistItems(playlistId: string): Promise<any[]> {
  const s = sess();
  const q = `userId=${s.userId}&Fields=${MUSIC_FIELDS}&EnableImageTypes=Primary&ImageTypeLimit=1`;
  let failure: any = null;
  try {
    const r = await api(`/Playlists/${playlistId}/Items?${q}`);
    if (r?.Items?.length) return r.Items;
  } catch (e) {
    failure = e;
  }
  try {
    const r = await api(`/Items?${q}&ParentId=${playlistId}`);
    return r?.Items ?? [];
  } catch (e) {
    throw failure ?? e;
  }
}

export async function createPlaylist(name: string, ids: string[]): Promise<string> {
  const s = sess();
  const r = await api(`/Playlists`, {
    method: "POST",
    body: { Name: name, Ids: ids, UserId: s.userId, MediaType: "Audio" },
  });
  if (!r?.Id) throw new Error("The server made the playlist but didn't say which one it is");
  return r.Id;
}

export async function renamePlaylist(id: string, name: string): Promise<void> {
  await api(`/Playlists/${id}`, { method: "POST", body: { Name: name } });
}

export async function deletePlaylist(id: string): Promise<void> {
  await api(`/Items/${id}`, { method: "DELETE" });
}

export async function addToPlaylist(id: string, itemIds: string[]): Promise<void> {
  const s = sess();
  for (let i = 0; i < itemIds.length; i += 100) {
    const ids = itemIds.slice(i, i + 100).join(",");
    await api(`/Playlists/${id}/Items?ids=${ids}&userId=${s.userId}`, { method: "POST" });
  }
}

/** By entry, not by song: a song can be in a playlist twice. */
export async function removeFromPlaylist(id: string, entryIds: string[]): Promise<void> {
  if (!entryIds.length) return;
  await api(`/Playlists/${id}/Items?entryIds=${entryIds.join(",")}`, { method: "DELETE" });
}

export async function movePlaylistEntry(id: string, entryId: string, to: number): Promise<void> {
  await api(`/Playlists/${id}/Items/${entryId}/Move/${Math.max(0, to)}`, { method: "POST" });
}

// ---------- Mixes ----------

export async function instantMix(itemId: string, limit = 100): Promise<any[]> {
  const s = sess();
  const r = await api(
    `/Items/${itemId}/InstantMix?userId=${s.userId}&Limit=${limit}&Fields=${MUSIC_FIELDS}&EnableImageTypes=Primary&ImageTypeLimit=1`
  );
  return r?.Items ?? [];
}

export async function similarArtists(artistId: string, limit = 12): Promise<any[]> {
  const s = sess();
  const r = await api(`/Items/${artistId}/Similar?userId=${s.userId}&limit=${limit}&Fields=${MUSIC_FIELDS}`);
  return r?.Items ?? [];
}

export async function recentlyPlayedSongs(limit = 40): Promise<any[]> {
  return (await music({ types: "Audio", sort: "played", played: true, limit })).Items;
}

export async function mostPlayedSongs(limit = 40): Promise<any[]> {
  return (await music({ types: "Audio", sort: "plays", played: true, limit })).Items;
}

/** Audiobooks stopped partway through. */
export async function resumeBooks(limit = 24): Promise<any[]> {
  const s = sess();
  const r = await api(
    `/UserItems/Resume?userId=${s.userId}&MediaTypes=Audio&IncludeItemTypes=AudioBook&Limit=${limit}&Fields=${MUSIC_FIELDS}&EnableImageTypes=Primary&ImageTypeLimit=1`
  );
  return r?.Items ?? [];
}

// ---------- Lyrics ----------

export interface LyricLine {
  text: string;
  /** Seconds from the start; null on plain lyrics. */
  start: number | null;
}

/** The words, timed where the server has an LRC or embedded sync. Null when
 *  the song has none (a 404, which is the common case). */
export async function lyrics(itemId: string): Promise<LyricLine[] | null> {
  try {
    const r = await api(`/Audio/${itemId}/Lyrics`);
    const lines: LyricLine[] = (r?.Lyrics ?? []).map((l: any) => ({
      text: String(l?.Text ?? ""),
      start: typeof l?.Start === "number" ? l.Start / 10_000_000 : null,
    }));
    return lines.length ? lines : null;
  } catch {
    return null;
  }
}

// ---------- Search ----------

export async function searchMusic(term: string, limit = 24) {
  const [artistsR, albums, songs, playlists] = await Promise.all([
    artists({ all: true, searchTerm: term, limit }).catch(() => ({ Items: [] as any[] })),
    music({ types: "MusicAlbum", searchTerm: term, limit }),
    music({ types: "Audio", searchTerm: term, limit }),
    music({ types: "Playlist", searchTerm: term, limit }).catch(() => ({ Items: [] as any[] })),
  ]);
  return {
    artists: artistsR.Items,
    albums: albums.Items,
    songs: songs.Items,
    playlists: playlists.Items.filter((p: any) => (p.MediaType ?? "Audio") === "Audio"),
  };
}

// ---------- Helpers for drawing ----------

/** "Artist" line for a song or album. */
export function artistLine(item: any): string {
  return (
    item.AlbumArtist ||
    (item.AlbumArtists ?? []).map((a: any) => a.Name).filter(Boolean).join(", ") ||
    (item.Artists ?? []).join(", ") ||
    (item.ArtistItems ?? []).map((a: any) => a.Name).filter(Boolean).join(", ") ||
    ""
  );
}

/** Cover art for a song, album, artist or book; songs fall back to their album. */
export function coverUrl(item: any, width = 400): string | null {
  const own = imageUrl(item, "Primary", width);
  if (own) return own;
  const s = getSession();
  if (s && item.AlbumId && item.AlbumPrimaryImageTag) {
    return `${s.server}/Items/${item.AlbumId}/Images/Primary?maxWidth=${width}&tag=${item.AlbumPrimaryImageTag}&quality=90`;
  }
  return null;
}

/** Albums the given songs belong to, once each, in the songs' order. What
 *  turns "recently played songs" into a shelf of covers. */
export function albumsInOrder(songs: any[]): any[] {
  const seen = new Set<string>();
  const out: any[] = [];
  for (const s of songs) {
    if (!s.AlbumId || seen.has(s.AlbumId)) continue;
    seen.add(s.AlbumId);
    out.push({
      Id: s.AlbumId,
      Name: s.Album,
      Type: "MusicAlbum",
      AlbumArtist: s.AlbumArtist,
      AlbumArtists: s.AlbumArtists,
      ProductionYear: s.ProductionYear,
      ImageTags: s.AlbumPrimaryImageTag ? { Primary: s.AlbumPrimaryImageTag } : {},
    });
  }
  return out;
}

/** The address mpv streams a song from: the original file, as the Apple app
 *  does whenever the device can read it — and mpv reads everything. */
export function streamUrl(item: any): string {
  const s = sess();
  return `${s.server}/Audio/${item.Id}/stream?static=true&MediaSourceId=${item.Id}&DeviceId=${encodeURIComponent(s.deviceId)}`;
}

export function secondsOf(ticks?: number | null): number {
  return ticks ? ticks / 10_000_000 : 0;
}

export function clock(sec: number): string {
  if (!isFinite(sec) || sec < 0) sec = 0;
  const h = Math.floor(sec / 3600);
  const m = Math.floor((sec % 3600) / 60);
  const s = Math.floor(sec % 60);
  return h ? `${h}:${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}` : `${m}:${String(s).padStart(2, "0")}`;
}

/** "1 hr 12 min" for an album or a book. */
export function longDuration(sec: number): string {
  const h = Math.floor(sec / 3600);
  const m = Math.round((sec % 3600) / 60);
  if (h) return m ? `${h} hr ${m} min` : `${h} hr`;
  return `${m} min`;
}
