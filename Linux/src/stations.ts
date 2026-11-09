// Stations: how one is gathered, scored and dealt out. A port of the Apple
// app's `StationEngine.swift` and `Stations.swift`.
//
// A station starts from a seed (a song, album, artist, genre or playlist),
// gathers a pool of candidates — Jellyfin's Instant Mix of the seed and of its
// artist, songs by the artists the server calls similar, and songs from the
// seed's main genres — then scores each against the seed and deals them out in
// an order that doesn't put one artist or one album back to back.
//
// How much each kind of likeness counts is the listener's: twenty points spent
// across seven dials (`MixPoints`), kept in the Linux config.
import * as api from "./api";
import * as m from "./musicApi";
import type { QueueSource } from "./audio";

// ---------- The listener's points ----------

export const DIALS = ["artist", "genre", "era", "favorites", "mostPlayed", "discovery", "surprise"] as const;
export type Dial = (typeof DIALS)[number];
export type MixPoints = Record<Dial, number>;

export const DIAL_INFO: Record<Dial, { label: string; help: string }> = {
  artist: { label: "Same artist", help: "Songs by the artist the station started from" },
  genre: { label: "Genre", help: "Songs that share the seed's genres" },
  era: { label: "Era", help: "Songs from around the same years" },
  favorites: { label: "Favorites", help: "Songs you've starred" },
  mostPlayed: { label: "Most played", help: "Songs you play often" },
  discovery: { label: "Discovery", help: "Songs you've never played" },
  surprise: { label: "Surprise", help: "A little luck in the order" },
};

/** What one point is worth in the score. Set so `balanced` comes to the
 *  weights stations had before there were points to spend. */
const UNIT: Record<Dial, number> = {
  artist: 3 / 5,
  genre: 4 / 6,
  era: 1.5 / 3,
  favorites: 0.6 / 2,
  mostPlayed: 0.6 / 2,
  discovery: 0.4,
  surprise: 1.2 / 2,
};

export const BUDGET = 20;

function points(p: Partial<MixPoints>): MixPoints {
  const out = {} as MixPoints;
  let left = BUDGET;
  // In the dials' own order, so an allocation over the budget loses the same
  // points wherever it is read.
  for (const d of DIALS) {
    const v = Math.max(0, Math.min(Math.round(Number(p[d] ?? 0)) || 0, left));
    out[d] = v;
    left -= v;
  }
  return out;
}

export const PRESETS: { name: string; points: MixPoints }[] = [
  { name: "Balanced", points: points({ artist: 5, genre: 6, era: 3, favorites: 2, mostPlayed: 2, surprise: 2 }) },
  { name: "Familiar", points: points({ artist: 5, genre: 4, era: 1, favorites: 5, mostPlayed: 5 }) },
  { name: "Discovery", points: points({ artist: 2, genre: 5, era: 2, discovery: 8, surprise: 3 }) },
];

export function remaining(p: MixPoints): number {
  return BUDGET - DIALS.reduce((n, d) => n + p[d], 0);
}

export function presetName(p: MixPoints): string {
  return PRESETS.find((x) => DIALS.every((d) => x.points[d] === p[d]))?.name ?? "Custom";
}

export function getMixPoints(): MixPoints {
  const stored = api.getConfig()?.music_mix;
  return stored && typeof stored === "object" ? points(stored) : { ...PRESETS[0].points };
}

export async function saveMixPoints(p: MixPoints): Promise<void> {
  await api.saveConfig({ music_mix: points(p) });
}

/** Set one dial, taking no more than the budget has left. */
export function withDial(p: MixPoints, dial: Dial, value: number): MixPoints {
  const out = { ...p };
  out[dial] = Math.max(0, Math.min(Math.round(value), p[dial] + remaining(p)));
  return out;
}

function weight(p: MixPoints, d: Dial): number {
  return p[d] * UNIT[d];
}

// ---------- Names ----------

const SUFFIXES = new Set(["music", "musik", "musique", "musica", "muziek", "musikk", "muzyka", "genre"]);
const FILLER = new Set(["music", "and", "the", "of", "&"]);

/** One key per genre however the tag spells it: lowercased, accents folded,
 *  "music"/"musik" dropped, hyphens and slashes as spaces. */
export function genreKey(raw: string): string {
  const folded = raw
    .normalize("NFD")
    .replace(/\p{M}/gu, "")
    .toLowerCase()
    .replace(/[-_/]+/g, " ")
    .replace(/\s+/g, " ")
    .trim()
    .replace(/^hip hop$/, "hip-hop")
    .replace(/^rnb$|^r&b$|^r and b$/, "r&b");
  const trimmed = folded.split(" ").filter((w) => !SUFFIXES.has(w)).join(" ");
  return trimmed || folded;
}

function words(genre: string): string[] {
  return genre.split(/[^\p{L}\p{N}]+/u).filter((w) => w.length > 1 && !FILLER.has(w));
}

function artistKeys(song: any): Set<string> {
  const out = new Set<string>();
  const add = (id?: string, name?: string) => {
    if (id) out.add(`id:${id}`);
    if (name) out.add(`name:${name.toLowerCase()}`);
  };
  add(undefined, song.AlbumArtist);
  for (const a of [...(song.ArtistItems ?? []), ...(song.AlbumArtists ?? [])]) add(a?.Id, a?.Name);
  for (const n of song.Artists ?? []) add(undefined, n);
  return out;
}

function lead(song: any): string {
  return String(song.AlbumArtist ?? song.AlbumArtists?.[0]?.Name ?? song.ArtistItems?.[0]?.Name ?? m.artistLine(song))
    .toLowerCase()
    .trim();
}

function genresOf(song: any): string[] {
  const raw: string[] = song.Genres ?? (song.GenreItems ?? []).map((g: any) => g.Name);
  return [...new Set(raw.filter(Boolean).map(genreKey))];
}

// ---------- The seed ----------

interface Profile {
  artists: Set<string>;
  genres: Map<string, number>;
  words: Map<string, number>;
  year: number | null;
  albumId: string | null;
  songId: string | null;
  open: boolean;
  surprise: boolean;
  artistStation: boolean;
}

function emptyProfile(open: boolean, surprise = false): Profile {
  return { artists: new Set(), genres: new Map(), words: new Map(), year: null, albumId: null, songId: null, open, surprise, artistStation: false };
}

function addGenres(p: Profile, keys: string[]): void {
  for (const k of keys) {
    p.genres.set(k, (p.genres.get(k) ?? 0) + 1);
    for (const w of words(k)) p.words.set(w, (p.words.get(w) ?? 0) + 1);
  }
}

function profileOf(seed: any, members: any[] = []): Profile {
  const p = emptyProfile(false);
  let mem = members;
  if (seed.Type === "MusicGenre" || seed.Type === "Genre") {
    addGenres(p, [genreKey(seed.Name ?? "")]);
  } else if (seed.Type === "MusicArtist") {
    p.artistStation = true;
    p.artists.add(`id:${seed.Id}`);
    if (seed.Name) p.artists.add(`name:${seed.Name.toLowerCase()}`);
  } else if (seed.Type === "MusicAlbum") {
    p.albumId = seed.Id;
    p.year = seed.ProductionYear ?? null;
  } else if (seed.Type === "Audio") {
    p.songId = seed.Id;
    p.albumId = seed.AlbumId ?? null;
    if (!mem.length) mem = [seed];
  }
  for (const s of mem) {
    if (seed.Type !== "MusicArtist") for (const k of artistKeys(s)) p.artists.add(k);
    addGenres(p, genresOf(s));
  }
  if (!mem.length && seed.Type !== "MusicGenre") {
    for (const k of artistKeys(seed)) p.artists.add(k);
    addGenres(p, genresOf(seed));
  }
  if (p.year == null) {
    const years = mem.map((s) => s.ProductionYear).filter((y) => typeof y === "number").sort((a, b) => a - b);
    p.year = years.length ? years[Math.floor(years.length / 2)] : seed.ProductionYear ?? null;
  }
  // An artist's station is about their sound, not their decade.
  if (seed.Type === "MusicArtist" || seed.Type === "MusicGenre") p.year = null;
  return p;
}

function genreAffinity(p: Profile, candidate: string[]): number {
  const total = [...p.genres.values()].reduce((a, b) => a + b, 0);
  if (!total || !candidate.length) return 0;
  const keys = new Set(candidate);
  let whole = 0;
  for (const k of keys) whole += p.genres.get(k) ?? 0;
  whole /= total;
  const wordTotal = [...p.words.values()].reduce((a, b) => a + b, 0);
  let shared = 0;
  for (const w of new Set([...keys].flatMap(words))) shared += p.words.get(w) ?? 0;
  const partial = wordTotal ? (0.5 * shared) / wordTotal : 0;
  return Math.min(1, Math.max(whole, partial));
}

/** How like the seed a song is. Null: nothing in common at all. */
function likeness(p: Profile, song: any, pts: MixPoints): number | null {
  if (p.open) return 1;
  const keys = artistKeys(song);
  const sameArtist = [...keys].some((k) => p.artists.has(k));
  const genre = genreAffinity(p, genresOf(song));
  if (!sameArtist && genre <= 0) return null;
  let score = (sameArtist ? weight(pts, "artist") : 0) + weight(pts, "genre") * genre;
  if (p.year != null && song.ProductionYear) {
    score += weight(pts, "era") * Math.max(0, 1 - Math.abs(p.year - song.ProductionYear) / 15);
  }
  if (p.albumId && song.AlbumId === p.albumId) score += 0.5;
  return score;
}

// ---------- Choosing and ordering ----------

interface Scored {
  song: any;
  score: number;
  alike: boolean;
  artist: string;
}

/** Two billings are one act when one name is where the other begins
 *  ("Tom Petty" / "Tom Petty and the Heartbreakers"), long enough to be a name
 *  of its own. */
function sameAct(a: string, b: string): boolean {
  const [short, long] = a.length <= b.length ? [a, b] : [b, a];
  if (short.length < 8 || long.length <= short.length || !long.startsWith(short)) return false;
  return !/[\p{L}\p{N}]/u.test(long[short.length]);
}

function actGrouper(): (song: any) => string {
  const groupOf = new Map<string, string>();
  const names: string[] = [];
  return (song) => {
    const name = lead(song);
    const known = groupOf.get(name);
    if (known) return known;
    const match = names.find((n) => sameAct(name, n));
    const group = match ?? name;
    groupOf.set(name, group);
    if (!match) names.push(group);
    return group;
  };
}

function score(pool: any[], p: Profile, pts: MixPoints, luck: Map<string, number>, exclude: Set<string>): Scored[] {
  const jitter = p.surprise ? Math.max(weight(pts, "surprise"), 5) : weight(pts, "surprise");
  const familiar = p.surprise ? 0.3 : 1;
  const out: Scored[] = [];
  for (const song of pool) {
    if (exclude.has(song.Id) || song.Id === p.songId) continue;
    const like = likeness(p, song, pts);
    let s = like ?? -4;
    const plays = song.UserData?.PlayCount ?? 0;
    if (song.UserData?.IsFavorite) s += familiar * weight(pts, "favorites");
    s += familiar * weight(pts, "mostPlayed") * Math.min(1, Math.log2(1 + plays) / 4);
    if (plays === 0) s += weight(pts, "discovery");
    if (jitter > 0) {
      if (!luck.has(song.Id)) luck.set(song.Id, Math.random());
      s += jitter * luck.get(song.Id)!;
    }
    out.push({ song, score: s, alike: like != null, artist: lead(song) });
  }
  return out.sort((a, b) => b.score - a.score);
}

/** The best `count`, dealt so no artist comes back within three songs, no
 *  album twice running, and no jump of decades when something closer scores
 *  nearly as well. */
function sequence(scored: Scored[], count: number, p: Profile, history: any[]): any[] {
  if (count <= 0) return [];
  const floor = Math.min(count, 20);
  let candidates = scored.filter((c) => c.alike);
  if (candidates.length < floor) candidates = candidates.concat(scored.filter((c) => !c.alike).slice(0, floor - candidates.length));

  const groupOf = actGrouper();
  const group = new Map<string, string>();
  for (const c of candidates) group.set(c.song.Id, groupOf(c.song));
  for (const s of history) group.set(s.Id, groupOf(s));

  const cap = p.artistStation ? Math.max(4, Math.floor((count * 2) / 5)) : Math.max(3, Math.floor(count / 4));
  const perArtist = new Map<string, number>();
  let pool: Scored[] = [];
  const held: Scored[] = [];
  for (const c of candidates) {
    if (pool.length >= count * 2) break;
    const act = group.get(c.song.Id) ?? c.artist;
    if ((perArtist.get(act) ?? 0) < cap) {
      perArtist.set(act, (perArtist.get(act) ?? 0) + 1);
      pool.push(c);
    } else held.push(c);
  }
  if (pool.length < floor) pool = pool.concat(held.slice(0, floor - pool.length));

  const recent = history.slice(-3).map((s) => group.get(s.Id) ?? lead(s));
  const last = history[history.length - 1];
  let lastAlbum = last?.AlbumId;
  let lastYear: number | undefined = last?.ProductionYear;
  let lastGenres = new Set<string>(last ? genresOf(last) : []);
  const out: any[] = [];
  while (out.length < count && pool.length) {
    let best = 0;
    let bestValue = -Infinity;
    for (let i = 0; i < Math.min(8, pool.length); i++) {
      const c = pool[i];
      const act = group.get(c.song.Id) ?? c.artist;
      let v = c.score;
      const at = recent.lastIndexOf(act);
      if (at >= 0) v -= [6, 3, 1.5][Math.min(2, recent.length - 1 - at)];
      if (c.song.AlbumId && c.song.AlbumId === lastAlbum) v -= 2;
      const y = c.song.ProductionYear;
      if (lastYear && y && Math.abs(lastYear - y) > 20) v -= 0.8 * Math.min(1, (Math.abs(lastYear - y) - 20) / 20);
      if (genresOf(c.song).some((g) => lastGenres.has(g))) v += 0.3;
      if (v > bestValue) {
        bestValue = v;
        best = i;
      }
    }
    const [pick] = pool.splice(best, 1);
    out.push(pick.song);
    recent.push(group.get(pick.song.Id) ?? pick.artist);
    if (recent.length > 3) recent.shift();
    lastAlbum = pick.song.AlbumId;
    lastYear = pick.song.ProductionYear ?? lastYear;
    lastGenres = new Set(genresOf(pick.song));
  }
  return out;
}

// ---------- Gathering ----------

async function safe<T>(p: Promise<T>, fallback: T): Promise<T> {
  try {
    return await p;
  } catch {
    return fallback;
  }
}

async function similarArtistSongs(artistId: string | undefined): Promise<any[]> {
  if (!artistId) return [];
  const similar = await safe(m.similarArtists(artistId, 8), []);
  if (!similar.length) return [];
  return (await safe(m.music({ types: "Audio", sort: "random", artistIds: similar.map((a) => a.Id), limit: 100 }), { Items: [], TotalRecordCount: 0 })).Items;
}

async function gather(seed: any): Promise<{ pool: any[]; profile: Profile }> {
  const none = { Items: [] as any[], TotalRecordCount: 0 };
  if (seed.Type === "MusicGenre" || seed.Type === "Genre") {
    const [songs, mix] = await Promise.all([
      safe(m.music({ types: "Audio", sort: "random", genreIds: [seed.Id], limit: 250 }), none),
      safe(m.instantMix(seed.Id, 100), []),
    ]);
    return { pool: [...songs.Items, ...mix], profile: profileOf(seed) };
  }
  const artistId: string | undefined =
    seed.Type === "MusicArtist" ? seed.Id : (seed.AlbumArtists?.[0] ?? seed.ArtistItems?.[0])?.Id;
  const [own, ofArtist, similar, members] = await Promise.all([
    safe(m.instantMix(seed.Id, 150), []),
    seed.Type === "MusicArtist" || !artistId ? Promise.resolve([]) : safe(m.instantMix(artistId, 80), []),
    similarArtistSongs(artistId),
    seed.Type === "MusicAlbum"
      ? safe(m.music({ types: "Audio", sort: "random", parentId: seed.Id, limit: 40 }), none).then((r) => r.Items)
      : seed.Type === "MusicArtist"
        ? safe(m.music({ types: "Audio", sort: "random", artistIds: [seed.Id], limit: 40 }), none).then((r) => r.Items)
        : Promise.resolve([] as any[]),
  ]);
  let profile = profileOf(seed, members);
  // A playlist says nothing about itself: what the server mixed from it is the
  // best account of what it sounds like.
  if (!profile.artists.size && !profile.genres.size) profile = profileOf(seed, own.slice(0, 30));
  const pool = [...own, ...ofArtist, ...similar];
  const topGenres = [...profile.genres.entries()].sort((a, b) => b[1] - a[1]).slice(0, 2).map(([k]) => k);
  // The server matches genres as spelled, so ask by the tags' own spellings.
  const spelled = new Set<string>();
  for (const s of [seed, ...members, ...own.slice(0, 30)]) {
    for (const g of s.Genres ?? []) if (topGenres.includes(genreKey(g))) spelled.add(g);
  }
  if (spelled.size) {
    const byGenre = await safe(m.music({ types: "Audio", sort: "random", genres: [...spelled], limit: 120 }), none);
    pool.push(...byGenre.Items);
  }
  return { pool, profile };
}

async function surprisePool(): Promise<any[]> {
  const none = { Items: [] as any[], TotalRecordCount: 0 };
  const [starred, top, recent, anywhere] = await Promise.all([
    safe(m.music({ types: "Audio", sort: "random", favorites: true, limit: 150 }), none),
    safe(m.mostPlayedSongs(100), []),
    safe(m.recentlyPlayedSongs(60), []),
    safe(m.music({ types: "Audio", sort: "random", limit: 50 }), none),
  ]);
  const known = [...starred.Items, ...top, ...recent];
  const artistIds: string[] = [];
  for (const s of [...known].sort(() => Math.random() - 0.5)) {
    if (artistIds.length >= 25) break;
    const id = (s.AlbumArtists?.[0] ?? s.ArtistItems?.[0])?.Id;
    if (id && !artistIds.includes(id)) artistIds.push(id);
  }
  const byArtists = artistIds.length
    ? (await safe(m.music({ types: "Audio", sort: "random", artistIds, limit: 250 }), none)).Items
    : [];
  return [...known, ...byArtists, ...anywhere.Items];
}

function dedupe(songs: any[]): any[] {
  const seen = new Set<string>();
  return songs.filter((s) => s?.Id && s.Type === "Audio" && !seen.has(s.Id) && (seen.add(s.Id), true));
}

/** A station as a queue source: the pool is gathered once and dealt from as
 *  the queue runs low. */
class Station implements QueueSource {
  private luck = new Map<string, number>();
  constructor(public title: string, private pool: any[], private profile: Profile) {}

  async more(history: any[], count: number): Promise<any[]> {
    const played = new Set(history.map((h) => h.Id));
    const pts = getMixPoints();
    return sequence(score(this.pool, this.profile, pts, this.luck, played), count, this.profile, history.slice(-5));
  }

  first(seed: any | null, count: number): any[] {
    const pts = getMixPoints();
    const lead = seed?.Type === "Audio" ? [seed] : [];
    const dealt = sequence(score(this.pool, this.profile, pts, this.luck, new Set()), count, this.profile, lead);
    return [...lead, ...dealt];
  }
}

/** Build a station from a song, album, artist, genre or playlist. */
export async function buildStation(seed: any): Promise<{ source: QueueSource; first: any[] }> {
  const { pool, profile } = await gather(seed);
  const station = new Station(`${seed.Name ?? "Station"} Station`, dedupe(pool), profile);
  const first = station.first(seed, 25);
  if (!first.length) throw new Error("The server couldn't build a station from that");
  return { source: station, first };
}

/** Surprise Me: a shuffle of what this account plays, with some from anywhere. */
export async function buildSurprise(): Promise<{ source: QueueSource; first: any[] }> {
  const pool = dedupe(await surprisePool());
  const station = new Station("Surprise Mix", pool, emptyProfile(true, true));
  const first = station.first(null, 25);
  if (!first.length) throw new Error("There's nothing in your music library to shuffle yet");
  return { source: station, first };
}

/** For tests: the ranker without the network. */
export const _internal = { profileOf, score, sequence, likeness, points, sameAct };
