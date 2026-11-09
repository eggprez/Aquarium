// Smart playlists: rules rather than lists. Jellyfin has no such thing, so they
// live in this app's config (config.json, key `music_smart_playlists`), are
// answered from the library each time they're opened, and can be frozen into a
// real playlist on the server at any moment. As in the Apple app.
import * as api from "./api";
import * as m from "./musicApi";

export interface SmartPlaylist {
  id: string;
  name: string;
  genres: string[];
  /** Artists by id, with names kept for drawing the rule. */
  artists: { id: string; name: string }[];
  yearFrom: number | null;
  yearTo: number | null;
  /** Added to the library in the last so many days; 0 for any time. */
  addedWithinDays: number;
  played: "any" | "played" | "unplayed";
  minPlays: number;
  favoritesOnly: boolean;
  order: keyof typeof m.SORTS;
  limit: number;
}

const KEY = "music_smart_playlists";

export function blankSmartPlaylist(): SmartPlaylist {
  return {
    id: `smart-${Date.now().toString(36)}${Math.random().toString(36).slice(2, 6)}`,
    name: "",
    genres: [],
    artists: [],
    yearFrom: null,
    yearTo: null,
    addedWithinDays: 0,
    played: "any",
    minPlays: 0,
    favoritesOnly: false,
    order: "random",
    limit: 100,
  };
}

export function getSmartPlaylists(): SmartPlaylist[] {
  const raw = api.getConfig()?.[KEY];
  if (!Array.isArray(raw)) return [];
  return raw
    .filter((p: any) => p && typeof p.id === "string")
    .map((p: any) => ({ ...blankSmartPlaylist(), ...p }));
}

export async function saveSmartPlaylist(p: SmartPlaylist): Promise<void> {
  const all = getSmartPlaylists();
  const at = all.findIndex((x) => x.id === p.id);
  if (at >= 0) all[at] = p;
  else all.push(p);
  await api.saveConfig({ [KEY]: all });
}

export async function deleteSmartPlaylist(id: string): Promise<void> {
  await api.saveConfig({ [KEY]: getSmartPlaylists().filter((p) => p.id !== id) });
}

/** As an item the shared cards and menus understand. */
export function asItem(p: SmartPlaylist): any {
  return { Id: p.id, Name: p.name, Type: "SmartPlaylist", ImageTags: {} };
}

/** A sentence for what the rules ask for. */
export function describe(p: SmartPlaylist): string {
  const parts: string[] = [];
  if (p.genres.length) parts.push(p.genres.join(" or "));
  if (p.artists.length) parts.push(`by ${p.artists.map((a) => a.name).join(" or ")}`);
  if (p.yearFrom || p.yearTo) parts.push(p.yearFrom && p.yearTo ? `${p.yearFrom}–${p.yearTo}` : p.yearFrom ? `from ${p.yearFrom}` : `up to ${p.yearTo}`);
  if (p.addedWithinDays) parts.push(`added in the last ${p.addedWithinDays} days`);
  if (p.played === "played") parts.push("played before");
  if (p.played === "unplayed") parts.push("never played");
  if (p.minPlays) parts.push(`played ${p.minPlays}+ times`);
  if (p.favoritesOnly) parts.push("favorites only");
  const what = parts.length ? parts.join(", ") : "Any song";
  return `${what} · ${m.SORTS[p.order]?.label ?? "Random"} · up to ${p.limit}`;
}

/** Answer the rules from the library. What the server can filter it does; the
 *  rest (date added, a play-count floor) is filtered here from a larger draw. */
export async function smartPlaylistSongs(p: SmartPlaylist): Promise<any[]> {
  const years: number[] = [];
  if (p.yearFrom || p.yearTo) {
    const from = p.yearFrom ?? 1900;
    const to = p.yearTo ?? new Date().getFullYear();
    for (let y = Math.min(from, to); y <= Math.max(from, to) && years.length < 200; y++) years.push(y);
  }
  const clientSide = p.addedWithinDays > 0 || p.minPlays > 0;
  const r = await m.music({
    types: "Audio",
    sort: p.order,
    genres: p.genres,
    artistIds: p.artists.map((a) => a.id),
    years,
    favorites: p.favoritesOnly,
    played: p.played === "any" ? (p.minPlays > 0 ? true : undefined) : p.played === "played",
    limit: clientSide ? Math.min(5000, p.limit * 8) : p.limit,
    fields: `${m.MUSIC_FIELDS},DateCreated`,
  });
  let songs = r.Items;
  if (p.addedWithinDays > 0) {
    const since = Date.now() - p.addedWithinDays * 86_400_000;
    songs = songs.filter((s) => s.DateCreated && Date.parse(s.DateCreated) >= since);
  }
  if (p.minPlays > 0) songs = songs.filter((s) => (s.UserData?.PlayCount ?? 0) >= p.minPlays);
  return songs.slice(0, p.limit);
}
