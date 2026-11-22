// src/stations.ts: how a station is gathered, scored and dealt out, the
// listener's mix points, and which mix (Aquarium's or Jellyfin's) is used.
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { jfPaths, mockJellyfin, signIn, invokeCalls } from "../helpers/tauri";

type St = typeof import("../../src/stations");
let st: St;

beforeEach(async () => {
  vi.resetModules();
  st = await import("../../src/stations");
});

afterEach(() => {
  vi.restoreAllMocks();
});

/** No luck in the order, so results are deterministic. */
const STEADY = { artist: 5, genre: 6, era: 3, favorites: 2, mostPlayed: 2, discovery: 0, surprise: 0 };

interface SongOpts {
  artist?: string;
  artistId?: string;
  album?: string;
  year?: number;
  genres?: string[];
  plays?: number;
  fav?: boolean;
  type?: string;
}

function song(id: string, o: SongOpts = {}): any {
  const artist = o.artist ?? "Someone";
  return {
    Id: id,
    Name: `Song ${id}`,
    Type: o.type ?? "Audio",
    AlbumArtist: artist,
    AlbumArtists: [{ Id: o.artistId ?? `ar-${artist}`, Name: artist }],
    ArtistItems: [{ Id: o.artistId ?? `ar-${artist}`, Name: artist }],
    AlbumId: o.album ?? `al-${id}`,
    ProductionYear: o.year,
    Genres: o.genres ?? [],
    UserData: { PlayCount: o.plays ?? 0, IsFavorite: !!o.fav },
  };
}

function pts(over: Partial<Record<string, number>> = {}): any {
  return st._internal.points({ ...STEADY, ...over });
}

// ---------- The listener's points ----------

describe("mix points", () => {
  it("every dial has a label and help text", () => {
    expect(st.DIALS).toHaveLength(7);
    for (const d of st.DIALS) {
      expect(st.DIAL_INFO[d].label).toBeTruthy();
      expect(st.DIAL_INFO[d].help).toBeTruthy();
    }
  });

  it("points rounds, floors at 0, and spends the budget in the dials' own order", () => {
    const p = st._internal.points({ artist: 15.6, genre: 10, era: -3, favorites: Number.NaN as any, surprise: 4 } as any);
    expect(p).toEqual({ artist: 16, genre: 4, era: 0, favorites: 0, mostPlayed: 0, discovery: 0, surprise: 0 });
    expect(st.remaining(p)).toBe(0);
  });

  it("points fills missing dials with 0 and accepts numeric strings", () => {
    expect(st._internal.points({ genre: "3" as any })).toEqual({
      artist: 0, genre: 3, era: 0, favorites: 0, mostPlayed: 0, discovery: 0, surprise: 0,
    });
  });

  it("the presets each fit the budget and have distinct names", () => {
    for (const p of st.PRESETS) expect(st.remaining(p.points)).toBeGreaterThanOrEqual(0);
    expect(st.PRESETS.map((p) => p.name)).toEqual(["Balanced", "Familiar", "Discovery"]);
    expect(st.remaining(st.PRESETS[0]!.points)).toBe(0);
  });

  it("presetName recognises a preset and calls anything else Custom", () => {
    expect(st.presetName({ ...st.PRESETS[1]!.points })).toBe("Familiar");
    expect(st.presetName(pts())).toBe("Custom");
  });

  it("getMixPoints is Balanced by default and the stored allocation, clamped, otherwise", async () => {
    expect(st.getMixPoints()).toEqual(st.PRESETS[0]!.points); // no config at all
    await signIn({});
    const def = st.getMixPoints();
    expect(def).toEqual(st.PRESETS[0]!.points);
    def.artist = 0; // a copy, not the preset itself
    expect(st.PRESETS[0]!.points.artist).toBe(5);
    await signIn({ music_mix: { artist: 30 } });
    expect(st.getMixPoints().artist).toBe(20);
    await signIn({ music_mix: "nonsense" });
    expect(st.getMixPoints()).toEqual(st.PRESETS[0]!.points);
  });

  it("saveMixPoints writes the clamped allocation to music_mix", async () => {
    await signIn({});
    await st.saveMixPoints({ ...pts(), surprise: 50 });
    expect(invokeCalls("config_save").at(-1)!.args.cfg).toEqual({ music_mix: { ...STEADY, surprise: 2 } });
  });

  it("withDial takes no more than the budget has left, rounds, and never goes below 0", () => {
    const p = pts(); // 18 spent, 2 left
    expect(st.withDial(p, "discovery", 10).discovery).toBe(2);
    expect(st.withDial(p, "artist", 6.6).artist).toBe(7);
    expect(st.withDial(p, "artist", -5).artist).toBe(0);
    expect(st.withDial(p, "artist", 0).artist).toBe(0);
    expect(p.artist).toBe(5); // not changed in place
  });
});

// ---------- Names ----------

describe("genreKey", () => {
  it.each([
    ["Rock", "rock"],
    ["Rock Music", "rock"],
    ["  Rock   Music ", "rock"],
    ["Hip Hop", "hip-hop"],
    ["hip-hop", "hip-hop"],
    ["Hip_Hop", "hip-hop"],
    ["R&B", "r&b"],
    ["RnB", "r&b"],
    ["R and B", "r&b"],
    ["Électronique", "electronique"],
    ["Drum-and-Bass", "drum and bass"],
    ["Rock/Pop", "rock pop"],
    ["Musique", "musique"], // only a suffix: keep the word rather than nothing
    ["Weltmusik", "weltmusik"],
    ["World Musik", "world"],
    ["Metal Genre", "metal"],
  ])("%j -> %j", (raw, key) => {
    expect(st.genreKey(raw)).toBe(key);
  });
});

describe("sameAct", () => {
  it.each([
    ["tom petty", "tom petty and the heartbreakers", true],
    ["tom petty and the heartbreakers", "tom petty", true],
    ["tom petty", "tom petty", false], // the same name is not a longer billing
    ["tom petty", "tom pettyson", false], // a letter follows: another name
    ["abba", "abba gold", false], // too short to be a name of its own
    ["prince charles", "prince charles & the city beat band", true],
    ["the beatles", "beatles", false],
  ])("%j / %j -> %j", (a, b, want) => {
    expect(st._internal.sameAct(a, b)).toBe(want);
  });
});

// ---------- The seed ----------

describe("profileOf", () => {
  it("a genre seed is about the genre only, with no era", () => {
    const p = st._internal.profileOf({ Type: "MusicGenre", Id: "g", Name: "Rock Music", ProductionYear: 1990 });
    expect([...p.genres.keys()]).toEqual(["rock"]);
    expect(p.artists.size).toBe(0);
    expect(p.year).toBeNull();
  });

  it("'Genre' is treated as a genre seed too", () => {
    const p = st._internal.profileOf({ Type: "Genre", Name: "Jazz" });
    expect([...p.genres.keys()]).toEqual(["jazz"]);
  });

  it("an artist seed is that artist, by id and name, with the members' genres and no era", () => {
    const members = [song("1", { artist: "Other", genres: ["Blues"], year: 1970 })];
    const p = st._internal.profileOf({ Type: "MusicArtist", Id: "ar1", Name: "Muddy" }, members);
    expect(p.artistStation).toBe(true);
    expect([...p.artists].sort()).toEqual(["id:ar1", "name:muddy"]);
    expect([...p.genres.keys()]).toEqual(["blues"]);
    expect(p.year).toBeNull();
  });

  it("an album seed takes the album's year and the members' artists and genres", () => {
    const members = [song("1", { artist: "A", genres: ["Rock"] }), song("2", { artist: "A", genres: ["Rock", "Pop"] })];
    const p = st._internal.profileOf({ Type: "MusicAlbum", Id: "al", ProductionYear: 1985 }, members);
    expect(p.albumId).toBe("al");
    expect(p.year).toBe(1985);
    expect(p.artists.has("name:a")).toBe(true);
    expect(p.genres.get("rock")).toBe(2);
    expect(p.genres.get("pop")).toBe(1);
  });

  it("a song seed is its own member, and remembers its id and album", () => {
    const s = song("s", { artist: "A", genres: ["Soul"], year: 1972, album: "al" });
    const p = st._internal.profileOf(s);
    expect(p.songId).toBe("s");
    expect(p.albumId).toBe("al");
    expect(p.year).toBe(1972);
    expect(p.artists.has("id:ar-A")).toBe(true);
    expect([...p.genres.keys()]).toEqual(["soul"]);
  });

  it("the year is the members' median when the seed has none of its own", () => {
    const members = [1960, 1990, 1970, undefined].map((y, i) => song(String(i), { year: y }));
    const p = st._internal.profileOf({ Type: "Playlist", Id: "pl" }, members);
    expect(p.year).toBe(1970);
  });

  it("a seed with no members describes itself (artists, genres and year from the seed)", () => {
    const p = st._internal.profileOf({ Type: "Playlist", Id: "pl", AlbumArtist: "X", Genres: ["Funk"], ProductionYear: 1977 });
    expect(p.artists.has("name:x")).toBe(true);
    expect([...p.genres.keys()]).toEqual(["funk"]);
    expect(p.year).toBe(1977);
  });

  it("genres can come from GenreItems when Genres is absent; artist names from Artists", () => {
    const s = { Id: "s", Type: "Audio", GenreItems: [{ Name: "Ska" }, { Name: "" }], Artists: ["Madness"] };
    const p = st._internal.profileOf(s);
    expect([...p.genres.keys()]).toEqual(["ska"]);
    expect(p.artists.has("name:madness")).toBe(true);
  });
});

describe("likeness", () => {
  const seed = song("seed", { artist: "A", genres: ["Alternative Rock"], year: 1995, album: "al" });
  const profile = () => st._internal.profileOf(seed);

  it("is null for a song with nothing in common", () => {
    expect(st._internal.likeness(profile(), song("x", { artist: "B", genres: ["Polka"] }), pts())).toBeNull();
  });

  it("the same artist counts even with no shared genre", () => {
    const v = st._internal.likeness(profile(), song("x", { artist: "A", genres: ["Polka"] }), pts({ era: 0 }));
    expect(v).toBeCloseTo(5 * (3 / 5));
  });

  it("a whole genre match counts fully; a shared word ('rock') counts half as partial", () => {
    const whole = st._internal.likeness(profile(), song("x", { artist: "B", genres: ["alternative rock"] }), pts({ era: 0 }))!;
    const partial = st._internal.likeness(profile(), song("y", { artist: "B", genres: ["Hard Rock"] }), pts({ era: 0 }))!;
    expect(whole).toBeCloseTo(6 * (4 / 6));
    expect(partial).toBeGreaterThan(0);
    expect(partial).toBeLessThan(whole);
  });

  it("era adds most for the same year and nothing at 15 years apart", () => {
    const p = profile();
    const same = st._internal.likeness(p, song("x", { artist: "A", year: 1995 }), pts())!;
    const near = st._internal.likeness(p, song("x", { artist: "A", year: 2000 }), pts())!;
    const far = st._internal.likeness(p, song("x", { artist: "A", year: 2015 }), pts())!;
    const none = st._internal.likeness(p, song("x", { artist: "A" }), pts())!;
    expect(same).toBeGreaterThan(near);
    expect(near).toBeGreaterThan(far);
    expect(far).toBeCloseTo(none);
  });

  it("the seed's own album adds a little", () => {
    const p = profile();
    const other = st._internal.likeness(p, song("x", { artist: "A", album: "zz" }), pts())!;
    const same = st._internal.likeness(p, song("x", { artist: "A", album: "al" }), pts())!;
    expect(same - other).toBeCloseTo(0.5);
  });

  it("a song with no genres has no genre affinity", () => {
    const p = profile();
    expect(st._internal.likeness(p, song("x", { artist: "Z", genres: [] }), pts())).toBeNull();
  });

  it("a profile with no genres gives no genre affinity", () => {
    const p = st._internal.profileOf({ Type: "MusicArtist", Id: "ar", Name: "N" });
    expect(st._internal.likeness(p, song("x", { artist: "Z", genres: ["Rock"] }), pts())).toBeNull();
  });
});

// ---------- Choosing and ordering ----------

describe("score", () => {
  const seed = song("seed", { artist: "A", genres: ["Rock"] });

  it("skips the seed song and anything excluded, and ranks alike songs above unrelated ones", () => {
    const p = st._internal.profileOf(seed);
    const pool = [seed, song("like", { artist: "A" }), song("unrelated", { artist: "Q", genres: ["Polka"] }), song("gone", { artist: "A" })];
    const out = st._internal.score(pool, p, pts(), new Map(), new Set(["gone"]));
    expect(out.map((s: any) => s.song.Id)).toEqual(["like", "unrelated"]);
    expect(out[0].alike).toBe(true);
    expect(out[1].alike).toBe(false);
    expect(out[1].score).toBeLessThan(0);
    expect(out[0].artist).toBe("a");
  });

  it("favourites, play counts and never-played each add their dial's weight", () => {
    const p = st._internal.profileOf(seed);
    const base = song("b", { artist: "A", plays: 1 });
    const fav = song("f", { artist: "A", plays: 1, fav: true });
    const many = song("m", { artist: "A", plays: 15 });
    const fresh = song("n", { artist: "A", plays: 0 });
    const out = st._internal.score([base, fav, many, fresh], p, pts({ discovery: 2, surprise: 0, era: 1 }), new Map(), new Set());
    const by = Object.fromEntries(out.map((s: any) => [s.song.Id, s.score]));
    expect(by.f - by.b).toBeCloseTo(2 * 0.3);
    expect(by.m).toBeGreaterThan(by.b);
    expect(by.n - by.b).toBeCloseTo(2 * 0.4 - 2 * 0.3 * (1 / 4));
  });

  it("surprise adds luck once per song, kept across deals so the order does not reshuffle", () => {
    const rnd = vi.spyOn(Math, "random").mockReturnValueOnce(0.9).mockReturnValueOnce(0.1);
    const p = st._internal.profileOf(seed);
    const luck = new Map<string, number>();
    const pool = [song("x", { artist: "A" }), song("y", { artist: "A" })];
    const first = st._internal.score(pool, p, pts({ surprise: 2 }), luck, new Set());
    expect(first.map((s: any) => s.song.Id)).toEqual(["x", "y"]);
    const again = st._internal.score(pool, p, pts({ surprise: 2 }), luck, new Set());
    expect(again.map((s: any) => s.score)).toEqual(first.map((s: any) => s.score));
    expect(rnd).toHaveBeenCalledTimes(2);
  });

  it("with no surprise points there is no luck at all", () => {
    const rnd = vi.spyOn(Math, "random");
    const p = st._internal.profileOf(seed);
    st._internal.score([song("x", { artist: "A" })], p, pts({ surprise: 0 }), new Map(), new Set());
    expect(rnd).not.toHaveBeenCalled();
  });
});

describe("sequence", () => {
  const seed = song("seed", { artist: "A", genres: ["Rock"] });

  function scored(songs: any[], p = st._internal.profileOf(seed)): any[] {
    return st._internal.score(songs, p, pts(), new Map(), new Set());
  }

  it("deals nothing for a count of 0", () => {
    expect(st._internal.sequence(scored([song("1", { artist: "A" })]), 0, st._internal.profileOf(seed), [])).toEqual([]);
  });

  it("never puts the same artist back to back when another will do", () => {
    const pool = [
      ...["a1", "a2", "a3", "a4"].map((id) => song(id, { artist: "A", genres: ["Rock"] })),
      ...["b1", "b2", "b3", "b4"].map((id) => song(id, { artist: "B", genres: ["Rock"] })),
      ...["c1", "c2", "c3", "c4"].map((id) => song(id, { artist: "C", genres: ["Rock"] })),
    ];
    const out = st._internal.sequence(scored(pool), 9, st._internal.profileOf(seed), []);
    expect(out).toHaveLength(9);
    for (let i = 1; i < out.length; i++) expect(out[i].AlbumArtist).not.toBe(out[i - 1].AlbumArtist);
  });

  it("does not play the same album twice running when something else scores nearly as well", () => {
    const pool = [
      song("x1", { artist: "X", album: "same", genres: ["Rock"] }),
      song("x2", { artist: "Y", album: "same", genres: ["Rock"] }),
      song("z", { artist: "Z", album: "other", genres: ["Rock"] }),
    ];
    const out = st._internal.sequence(scored(pool), 3, st._internal.profileOf(seed), []);
    expect(out.map((s: any) => s.AlbumId)).toEqual(["same", "other", "same"]);
  });

  it("caps any one artist at a quarter of the count (at least 3) on a song station", () => {
    const pool = [
      ...Array.from({ length: 12 }, (_, i) => song(`a${i}`, { artist: "A", genres: ["Rock"] })),
      ...Array.from({ length: 12 }, (_, i) => song(`b${i}`, { artist: "B", genres: ["Rock"] })),
      ...Array.from({ length: 12 }, (_, i) => song(`c${i}`, { artist: "C", genres: ["Rock"] })),
      ...Array.from({ length: 12 }, (_, i) => song(`d${i}`, { artist: "D", genres: ["Rock"] })),
      ...Array.from({ length: 12 }, (_, i) => song(`e${i}`, { artist: "E", genres: ["Rock"] })),
    ];
    const out = st._internal.sequence(scored(pool), 20, st._internal.profileOf(seed), []);
    expect(out).toHaveLength(20);
    const counts: Record<string, number> = {};
    for (const s of out) counts[s.AlbumArtist] = (counts[s.AlbumArtist] ?? 0) + 1;
    for (const n of Object.values(counts)) expect(n).toBeLessThanOrEqual(5);
  });

  it("an artist's own station lets the artist have more of it (two fifths)", () => {
    const art = { Type: "MusicArtist", Id: "ar-A", Name: "A" };
    const p = st._internal.profileOf(art, [song("m", { artist: "A", genres: ["Rock"] })]);
    const pool = [
      ...Array.from({ length: 20 }, (_, i) => song(`a${i}`, { artist: "A", genres: ["Rock"] })),
      ...Array.from({ length: 20 }, (_, i) => song(`b${i}`, { artist: "B", genres: ["Rock"] })),
      ...Array.from({ length: 20 }, (_, i) => song(`c${i}`, { artist: "C", genres: ["Rock"] })),
    ];
    const out = st._internal.sequence(scored(pool, p), 20, p, []);
    const a = out.filter((s: any) => s.AlbumArtist === "A").length;
    expect(a).toBe(8);
  });

  it("tops a thin station up with unrelated songs, and with held-back ones, to reach a floor", () => {
    const pool = [song("a1", { artist: "A" }), song("a2", { artist: "A" }), song("a3", { artist: "A" }), song("a4", { artist: "A" }), song("q", { artist: "Q", genres: ["Polka"] })];
    const out = st._internal.sequence(scored(pool), 5, st._internal.profileOf(seed), []);
    expect(out.map((s: any) => s.Id).sort()).toEqual(["a1", "a2", "a3", "a4", "q"]);
  });

  it("treats two billings of one act as one artist ('Tom Petty' and '... and the Heartbreakers')", () => {
    const pool = [
      song("t1", { artist: "Tom Petty", genres: ["Rock"] }),
      song("t2", { artist: "Tom Petty and the Heartbreakers", genres: ["Rock"] }),
      song("o1", { artist: "Other", genres: ["Rock"] }),
    ];
    const out = st._internal.sequence(scored(pool), 3, st._internal.profileOf(seed), []);
    expect(out.map((s: any) => s.Id)).toEqual(["t1", "o1", "t2"]);
  });

  it("history counts: the last artist played is not dealt first", () => {
    const pool = [song("a", { artist: "A", genres: ["Rock"] }), song("b", { artist: "B", genres: ["Rock"] })];
    const hist = [song("h", { artist: "A", genres: ["Rock"] })];
    const out = st._internal.sequence(scored(pool), 1, st._internal.profileOf(seed), hist);
    expect(out[0].Id).toBe("b");
  });

  it("avoids a jump of decades when something closer scores nearly as well", () => {
    const pool = [song("old", { artist: "B", year: 1950, genres: ["Rock"] }), song("near", { artist: "C", year: 2001, genres: ["Rock"] })];
    const hist = [song("h", { artist: "D", year: 2000 })];
    const out = st._internal.sequence(scored(pool), 1, st._internal.profileOf(seed), hist);
    expect(out[0].Id).toBe("near");
  });
});

// ---------- Gathering and building ----------

/** Answer the station's requests from a description of the library. */
function library(lib: {
  mix?: Record<string, any[]>;
  similar?: Record<string, any[]>;
  byArtist?: Record<string, any[]>;
  byParent?: Record<string, any[]>;
  byGenreId?: Record<string, any[]>;
  byGenre?: any[];
  fail?: RegExp;
}): void {
  mockJellyfin([
    [
      /.*/,
      (a: any) => {
        if (lib.fail?.test(a.path)) return { __status: 500 };
        const u = new URL(`http://x${a.path}`);
        const mixM = /^\/Items\/([^/]+)\/InstantMix$/.exec(u.pathname);
        if (mixM) return { Items: lib.mix?.[mixM[1]!] ?? [] };
        const simM = /^\/Items\/([^/]+)\/Similar$/.exec(u.pathname);
        if (simM) return { Items: lib.similar?.[simM[1]!] ?? [] };
        const q = u.searchParams;
        if (q.get("ArtistIds")) return { Items: q.get("ArtistIds")!.split(",").flatMap((id) => lib.byArtist?.[id] ?? []) };
        if (q.get("ParentId")) return { Items: lib.byParent?.[q.get("ParentId")!] ?? [] };
        if (q.get("GenreIds")) return { Items: lib.byGenreId?.[q.get("GenreIds")!] ?? [] };
        if (q.get("Genres")) return { Items: lib.byGenre ?? [] };
        return { Items: [] };
      },
    ],
  ]);
}

describe("buildStation", () => {
  it("from a song: leads with the seed, gathers its mix, its artist's mix, similar artists and its genres", async () => {
    await signIn({ music_mix: STEADY });
    const seed = song("seed", { artist: "A", artistId: "arA", genres: ["Rock"] });
    library({
      mix: { seed: [song("m1", { artist: "A", artistId: "arA", genres: ["Rock"] })], arA: [song("m2", { artist: "B", genres: ["Rock"] })] },
      similar: { arA: [{ Id: "arC" }] },
      byArtist: { arC: [song("c1", { artist: "C", genres: ["Rock"] })] },
      byGenre: [song("g1", { artist: "D", genres: ["Rock"] })],
    });
    const { source, first } = await st.buildStation(seed);
    expect(first[0].Id).toBe("seed");
    expect(first.map((s: any) => s.Id).sort()).toEqual(["c1", "g1", "m1", "m2", "seed"]);
    expect(source.title).toBe("Song seed Station");
    const paths = jfPaths();
    expect(paths.some((p) => p.startsWith("/Items/seed/InstantMix") && p.includes("Limit=150"))).toBe(true);
    expect(paths.some((p) => p.startsWith("/Items/arA/InstantMix") && p.includes("Limit=80"))).toBe(true);
    expect(paths.some((p) => p.startsWith("/Items/arA/Similar"))).toBe(true);
    // Genres are asked for in the tag's own spelling.
    const g = paths.find((p) => p.includes("Genres="))!;
    expect(new URL(`http://x${g}`).searchParams.get("Genres")).toBe("Rock");
  });

  it("drops duplicates and anything that is not a song from the pool", async () => {
    await signIn({ music_mix: STEADY });
    const seed = song("seed", { artist: "A", genres: ["Rock"] });
    library({
      mix: {
        seed: [song("m1", { artist: "A" }), song("m1", { artist: "A" }), song("v", { artist: "A", type: "Video" }), { Type: "Audio" }],
      },
    });
    const { first } = await st.buildStation(seed);
    expect(first.map((s: any) => s.Id)).toEqual(["seed", "m1"]);
  });

  it("from a genre: random songs of the genre plus the genre's mix", async () => {
    await signIn({ music_mix: STEADY });
    library({
      byGenreId: { g: [song("r1", { artist: "A", genres: ["Jazz"] })] },
      mix: { g: [song("r2", { artist: "B", genres: ["Jazz"] })] },
    });
    const { first, source } = await st.buildStation({ Type: "MusicGenre", Id: "g", Name: "Jazz" });
    expect(first.map((s: any) => s.Id).sort()).toEqual(["r1", "r2"]);
    expect(source.title).toBe("Jazz Station");
    expect(jfPaths().some((p) => p.includes("GenreIds=g") && p.includes("Limit=250"))).toBe(true);
  });

  it("from an album: the album's songs describe it, and the album artist's mix joins the pool", async () => {
    await signIn({ music_mix: STEADY });
    const album = { Type: "MusicAlbum", Id: "al", Name: "LP", AlbumArtists: [{ Id: "arA", Name: "A" }], ProductionYear: 1990 };
    library({
      byParent: { al: [song("t1", { artist: "A", artistId: "arA", album: "al", genres: ["Pop"] })] },
      mix: { al: [song("x", { artist: "A", artistId: "arA", genres: ["Pop"] })] },
    });
    const { first } = await st.buildStation(album);
    expect(first.map((s: any) => s.Id)).toContain("x");
    expect(first[0].Id).not.toBe("al"); // an album seed is not itself played
    expect(jfPaths().some((p) => p.includes("ParentId=al") && p.includes("Limit=40"))).toBe(true);
    expect(jfPaths().some((p) => p.startsWith("/Items/arA/InstantMix"))).toBe(true);
  });

  it("from an artist: their songs describe it, and the artist's mix is not asked for twice", async () => {
    await signIn({ music_mix: STEADY });
    library({
      byArtist: { arA: [song("a1", { artist: "A", artistId: "arA", genres: ["Rock"] })] },
      mix: { arA: [song("a2", { artist: "A", artistId: "arA", genres: ["Rock"] })] },
    });
    const { first } = await st.buildStation({ Type: "MusicArtist", Id: "arA", Name: "A" });
    // The members describe the station; the pool is what was mixed.
    expect(first.map((s: any) => s.Id)).toEqual(["a2"]);
    expect(jfPaths().some((p) => p.includes("ArtistIds=arA") && p.includes("Limit=40"))).toBe(true);
    expect(jfPaths().filter((p) => p.startsWith("/Items/arA/InstantMix"))).toHaveLength(1);
  });

  it("from a playlist: what the server mixed from it describes it", async () => {
    await signIn({ music_mix: STEADY });
    library({
      mix: { pl: [song("p1", { artist: "A", genres: ["Folk"] }), song("p2", { artist: "B", genres: ["Folk"] })] },
      byGenre: [song("f1", { artist: "C", genres: ["Folk"] })],
    });
    const { first } = await st.buildStation({ Type: "Playlist", Id: "pl", Name: "Mine" });
    expect(first.map((s: any) => s.Id).sort()).toEqual(["f1", "p1", "p2"]);
    expect(jfPaths().some((p) => p.includes("Genres=Folk"))).toBe(true);
  });

  it("a failing request costs only its part of the pool", async () => {
    await signIn({ music_mix: STEADY });
    const seed = song("seed", { artist: "A", artistId: "arA", genres: ["Rock"] });
    library({ mix: { seed: [song("m1", { artist: "B", genres: ["Rock"] })] }, fail: /Similar|arA\/InstantMix|Genres=/ });
    const { first } = await st.buildStation(seed);
    expect(first.map((s: any) => s.Id)).toEqual(["seed", "m1"]);
  });

  it("a genre station whose requests all fail says the server couldn't build it", async () => {
    await signIn({ music_mix: STEADY });
    library({ fail: /.*/ });
    await expect(st.buildStation({ Type: "MusicGenre", Id: "g", Name: "X" })).rejects.toThrow("The server couldn't build a station from that");
  });

  it("an untitled seed is called Station Station", async () => {
    await signIn({ music_mix: STEADY });
    library({ byGenreId: { g: [song("1", { genres: ["X"] })] } });
    const { source } = await st.buildStation({ Type: "Genre", Id: "g" });
    expect(source.title).toBe("Station Station");
  });

  it("more() deals further songs, never one already played", async () => {
    await signIn({ music_mix: STEADY });
    const pool = Array.from({ length: 30 }, (_, i) => song(`s${i}`, { artist: `Art${i % 6}`, genres: ["Rock"] }));
    library({ byGenreId: { g: pool } });
    const { source, first } = await st.buildStation({ Type: "MusicGenre", Id: "g", Name: "Rock" });
    expect(first).toHaveLength(25);
    const more = await source.more!(first, 10);
    expect(more).toHaveLength(5);
    const played = new Set(first.map((s: any) => s.Id));
    for (const s of more) expect(played.has(s.Id)).toBe(false);
  });
});

describe("which mix", () => {
  it("getMixSource is Aquarium's own unless Jellyfin's is chosen", async () => {
    expect(st.getMixSource()).toBe("aquarium");
    await signIn({ music_mix_source: "jellyfin" });
    expect(st.getMixSource()).toBe("jellyfin");
    await signIn({ music_mix_source: "other" });
    expect(st.getMixSource()).toBe("aquarium");
  });

  it("buildInstantMix answers the server's mix in its own order, songs only, once each", async () => {
    await signIn();
    library({ mix: { s: [song("2"), song("1"), song("2"), song("v", { type: "MusicVideo" })] } });
    expect((await st.buildInstantMix({ Id: "s" })).map((x) => x.Id)).toEqual(["2", "1"]);
    expect(jfPaths()[0]).toMatch(/Limit=200/);
  });

  it("buildInstantMix says so when the server has none", async () => {
    await signIn();
    library({});
    await expect(st.buildInstantMix({ Id: "s" })).rejects.toThrow("The server had no Instant Mix for that");
  });
});

describe("buildOfflineMix", () => {
  const dl = [
    song("a1", { artist: "A", artistId: "arA", album: "alA", genres: ["Rock"], year: 1990 }),
    song("a2", { artist: "A", artistId: "arA", album: "alA", genres: ["Rock"], year: 1990 }),
    song("b1", { artist: "B", artistId: "arB", album: "alB", genres: ["Rock"], year: 1992 }),
    song("c1", { artist: "C", artistId: "arC", album: "alC", genres: ["Polka"] }),
  ];

  it("mixes from downloaded songs only, with no request", async () => {
    await signIn({ music_mix: STEADY });
    const { source, first } = st.buildOfflineMix(dl[0], dl);
    expect(first[0].Id).toBe("a1");
    expect(new Set(first.map((s: any) => s.Id))).toEqual(new Set(["a1", "a2", "b1", "c1"]));
    expect(source.title).toBe("Song a1 Mix");
    expect(invokeCalls("jf_request")).toHaveLength(0);
  });

  it("an album seed is described by its downloaded songs", async () => {
    await signIn({ music_mix: STEADY });
    const { first, source } = st.buildOfflineMix({ Type: "MusicAlbum", Id: "alA", Name: "LP" }, dl);
    expect(first.length).toBeGreaterThan(0);
    expect(source.title).toBe("LP Mix");
    // Rock songs (alike) come before the unrelated polka song.
    expect(first.at(-1).Id).toBe("c1");
  });

  it("an artist seed is described by that artist's downloaded songs", async () => {
    await signIn({ music_mix: STEADY });
    const { first } = st.buildOfflineMix({ Type: "MusicArtist", Id: "arB" }, dl);
    expect(first[0].AlbumArtist === "B" || first[0].Genres.includes("Rock")).toBe(true);
    expect(first.at(-1).Id).toBe("c1");
  });

  it("an unnamed seed is a Downloads Mix", async () => {
    await signIn({ music_mix: STEADY });
    expect(st.buildOfflineMix({ Type: "Playlist", Id: "p" }, dl).source.title).toBe("Downloads Mix");
  });

  it("fails clearly with no downloaded songs", () => {
    expect(() => st.buildOfflineMix({ Type: "Audio", Id: "x" }, [])).toThrow("No downloaded songs to mix from");
    expect(() => st.buildOfflineMix({ Type: "Audio", Id: "x" }, [{ Id: "v", Type: "Video" }])).toThrow("No downloaded songs to mix from");
  });

  it("an album seed with a single downloaded song still deals that song", () => {
    const only = song("x", { genres: ["Rock"] });
    // An album seed leads with nothing; its only song is dealt, so this works.
    expect(st.buildOfflineMix({ Type: "MusicAlbum", Id: only.AlbumId }, [only]).first).toHaveLength(1);
  });
});
