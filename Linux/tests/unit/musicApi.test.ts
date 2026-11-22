// src/musicApi.ts: the music half of the API (artists, albums, songs,
// genres, playlists, mixes, lyrics, search) and its drawing helpers.
//
// Every request names the user with `userId=` on a plain route (Linux/CLAUDE.md).
import { beforeEach, describe, expect, it, vi } from "vitest";
import { invokeCalls, jfPaths, mockJellyfin, onInvoke, signIn } from "../helpers/tauri";

type M = typeof import("../../src/musicApi");
let m: M;

beforeEach(async () => {
  vi.resetModules();
  m = await import("../../src/musicApi");
});

/** A request path's route and query. */
function parse(path: string): { route: string; q: URLSearchParams } {
  const u = new URL(`http://x${path}`);
  return { route: u.pathname, q: u.searchParams };
}

function lastCall(): { route: string; q: URLSearchParams; method: string; body: any } {
  const c = invokeCalls("jf_request").at(-1)!;
  return { ...parse(c.args.path), method: c.args.method, body: c.args.body };
}

async function signedIn(routes: Array<[string | RegExp, any]> = [[/.*/, { Items: [], TotalRecordCount: 0 }]]) {
  const api = await signIn();
  mockJellyfin(routes);
  return api;
}

describe("not signed in", () => {
  it.each([
    ["music", () => m.music({ types: "Audio" })],
    ["artists", () => m.artists()],
    ["musicItem", () => m.musicItem("x")],
    ["musicGenres", () => m.musicGenres()],
    ["playlistItems", () => m.playlistItems("p")],
    ["createPlaylist", () => m.createPlaylist("n", [])],
    ["addToPlaylist", () => m.addToPlaylist("p", ["a"])],
    ["instantMix", () => m.instantMix("x")],
    ["similarArtists", () => m.similarArtists("x")],
    ["resumeBooks", () => m.resumeBooks()],
    ["streamUrl", async () => m.streamUrl({ Id: "s" })],
  ])("%s refuses with 'Not signed in' and sends nothing", async (_n, call) => {
    await expect(call()).rejects.toThrow("Not signed in");
    expect(invokeCalls("jf_request")).toHaveLength(0);
  });
});

describe("music (the general query)", () => {
  it("sends the defaults: recursive, by name ascending, the list fields, first 100", async () => {
    await signedIn();
    await m.music({ types: "MusicAlbum" });
    const { route, q } = lastCall();
    expect(route).toBe("/Items");
    expect(q.get("userId")).toBe("user-1");
    expect(q.get("IncludeItemTypes")).toBe("MusicAlbum");
    expect(q.get("Recursive")).toBe("true");
    expect(q.get("SortBy")).toBe("SortName");
    expect(q.get("SortOrder")).toBe("Ascending");
    expect(q.get("Fields")).toBe(m.MUSIC_FIELDS);
    expect(q.get("StartIndex")).toBe("0");
    expect(q.get("Limit")).toBe("100");
    expect(q.get("EnableImageTypes")).toBe("Primary,Backdrop");
    expect(q.get("ImageTypeLimit")).toBe("1");
    for (const k of ["ParentId", "AlbumArtistIds", "ArtistIds", "GenreIds", "Genres", "Years", "ExcludeItemIds", "Filters", "SearchTerm"]) {
      expect(q.has(k)).toBe(false);
    }
  });

  it("list fields leave MediaSources out (megabytes nobody reads until one is played)", () => {
    expect(m.MUSIC_FIELDS).not.toContain("MediaSources");
    expect(m.MUSIC_DETAIL_FIELDS).toContain("MediaSources");
    expect(m.MUSIC_DETAIL_FIELDS.startsWith(m.MUSIC_FIELDS)).toBe(true);
  });

  it("passes every filter in the server's own spelling", async () => {
    await signedIn();
    await m.music({
      types: "Audio",
      parentId: "p",
      sort: "added",
      startIndex: 50,
      limit: 25,
      albumArtistIds: ["aa1", "aa2"],
      artistIds: ["a1"],
      genreIds: ["g1", "g2"],
      genres: ["Rock", "Hip-Hop"],
      years: [1990, 1991],
      excludeIds: ["x"],
      favorites: true,
      played: true,
      searchTerm: "love",
      fields: "Name",
      recursive: false,
    });
    const { q } = lastCall();
    expect(q.get("ParentId")).toBe("p");
    expect(q.get("SortBy")).toBe("DateCreated,SortName");
    expect(q.get("SortOrder")).toBe("Descending");
    expect(q.get("StartIndex")).toBe("50");
    expect(q.get("Limit")).toBe("25");
    expect(q.get("AlbumArtistIds")).toBe("aa1,aa2");
    expect(q.get("ArtistIds")).toBe("a1");
    expect(q.get("GenreIds")).toBe("g1,g2");
    expect(q.get("Genres")).toBe("Rock|Hip-Hop");
    expect(q.get("Years")).toBe("1990,1991");
    expect(q.get("ExcludeItemIds")).toBe("x");
    expect(q.get("Filters")).toBe("IsFavorite,IsPlayed");
    expect(q.get("SearchTerm")).toBe("love");
    expect(q.get("Fields")).toBe("Name");
    expect(q.get("Recursive")).toBe("false");
  });

  it("played: false asks for unplayed; descending overrides the sort's own direction", async () => {
    await signedIn();
    await m.music({ types: "Audio", played: false, sort: "year", descending: false });
    const { q } = lastCall();
    expect(q.get("Filters")).toBe("IsUnplayed");
    expect(q.get("SortBy")).toBe("ProductionYear,SortName");
    expect(q.get("SortOrder")).toBe("Ascending");
  });

  it("empty id lists are left out rather than sent empty", async () => {
    await signedIn();
    await m.music({ types: "Audio", artistIds: [], genres: [], years: [] });
    const { q } = lastCall();
    expect(q.has("ArtistIds")).toBe(false);
    expect(q.has("Genres")).toBe(false);
    expect(q.has("Years")).toBe(false);
  });

  it("answers the items and total; a missing total falls back to the item count, a missing body to nothing", async () => {
    await signedIn([[/.*/, { Items: [{ Id: "a" }, { Id: "b" }] }]]);
    expect(await m.music({ types: "Audio" })).toEqual({ Items: [{ Id: "a" }, { Id: "b" }], TotalRecordCount: 2 });
    mockJellyfin([[/.*/, null]]);
    expect(await m.music({ types: "Audio" })).toEqual({ Items: [], TotalRecordCount: 0 });
    mockJellyfin([[/.*/, { Items: [], TotalRecordCount: 77 }]]);
    expect((await m.music({ types: "Audio" })).TotalRecordCount).toBe(77);
  });

  it("every sort maps to a server key and a label", () => {
    for (const [k, s] of Object.entries(m.SORTS)) {
      expect(s.key, k).toBeTruthy();
      expect(s.label, k).toBeTruthy();
    }
    expect(m.SORTS.random.key).toBe("Random");
  });
});

describe("artists", () => {
  it("lists album artists by default, everyone credited with all: true", async () => {
    await signedIn();
    await m.artists();
    let c = lastCall();
    expect(c.route).toBe("/Artists/AlbumArtists");
    expect(c.q.get("userId")).toBe("user-1");
    expect(c.q.get("Limit")).toBe("200");
    expect(c.q.get("SortBy")).toBe("SortName");
    expect(c.q.has("IsFavorite")).toBe(false);
    await m.artists({ all: true, favorites: true, searchTerm: "bo", startIndex: 10, limit: 5, sort: "plays" });
    c = lastCall();
    expect(c.route).toBe("/Artists");
    expect(c.q.get("IsFavorite")).toBe("true");
    expect(c.q.get("SearchTerm")).toBe("bo");
    expect(c.q.get("StartIndex")).toBe("10");
    expect(c.q.get("Limit")).toBe("5");
    expect(c.q.get("SortBy")).toBe("PlayCount,SortName");
    expect(c.q.get("SortOrder")).toBe("Descending");
  });

  it("answers empty for an empty body", async () => {
    await signedIn([[/.*/, null]]);
    expect(await m.artists()).toEqual({ Items: [], TotalRecordCount: 0 });
  });
});

describe("single items and track lists", () => {
  it("musicItem asks for the detail fields", async () => {
    await signedIn([[/.*/, { Id: "al" }]]);
    expect(await m.musicItem("al")).toEqual({ Id: "al" });
    const c = lastCall();
    expect(c.route).toBe("/Items/al");
    expect(c.q.get("userId")).toBe("user-1");
    expect(c.q.get("Fields")).toBe(m.MUSIC_DETAIL_FIELDS);
  });

  it("sortedByTrack orders by disc, then track, then name, missing numbers last; it does not sort in place", () => {
    const items = [
      { Name: "b", ParentIndexNumber: 2, IndexNumber: 1 },
      { Name: "z", IndexNumber: 2 },
      { Name: "y" },
      { Name: "x" },
      { Name: "a", ParentIndexNumber: 1, IndexNumber: 1 },
      {},
    ];
    const copy = [...items];
    expect(m.sortedByTrack(items).map((i: any) => i.Name ?? "")).toEqual(["a", "z", "", "x", "y", "b"]);
    expect(items).toEqual(copy);
  });

  it("albumTracks asks for the album's songs and answers them in sleeve order", async () => {
    await signedIn([[/.*/, { Items: [{ Id: "2", IndexNumber: 2 }, { Id: "1", IndexNumber: 1 }] }]]);
    expect((await m.albumTracks("al")).map((i) => i.Id)).toEqual(["1", "2"]);
    const { q } = lastCall();
    expect(q.get("ParentId")).toBe("al");
    expect(q.get("IncludeItemTypes")).toBe("Audio");
    expect(q.get("Limit")).toBe("500");
  });

  it.each([
    ["topSongs", () => m.topSongs("ar"), { IncludeItemTypes: "Audio", SortBy: "PlayCount,SortName", ArtistIds: "ar", Limit: "10" }],
    ["allSongs", () => m.allSongs("ar"), { IncludeItemTypes: "Audio", SortBy: "AlbumArtist,SortName", ArtistIds: "ar", Limit: "2000" }],
    ["albumsBy", () => m.albumsBy("ar"), { IncludeItemTypes: "MusicAlbum", SortBy: "ProductionYear,SortName", AlbumArtistIds: "ar", Limit: "500" }],
    ["genreSongs", () => m.genreSongs("g"), { IncludeItemTypes: "Audio", SortBy: "Random", GenreIds: "g", Limit: "500" }],
    ["recentlyPlayedSongs", () => m.recentlyPlayedSongs(), { SortBy: "DatePlayed,SortName", Filters: "IsPlayed", Limit: "40" }],
    ["mostPlayedSongs", () => m.mostPlayedSongs(7), { SortBy: "PlayCount,SortName", Filters: "IsPlayed", Limit: "7" }],
  ] as const)("%s asks the right question", async (_n, call, want) => {
    await signedIn([[/.*/, { Items: [{ Id: "s" }] }]]);
    expect(await call()).toEqual([{ Id: "s" }]);
    const { route, q } = lastCall();
    expect(route).toBe("/Items");
    for (const [k, v] of Object.entries(want)) expect(q.get(k), k).toBe(v);
  });

  it("appearsOn leaves out albums where the artist is the album artist", async () => {
    await signedIn([
      [
        /.*/,
        {
          Items: [
            { Id: "own", AlbumArtists: [{ Id: "ar" }] },
            { Id: "guest", AlbumArtists: [{ Id: "other" }] },
            { Id: "comp" },
          ],
        },
      ],
    ]);
    expect((await m.appearsOn("ar")).map((a) => a.Id)).toEqual(["guest", "comp"]);
    const { q } = lastCall();
    expect(q.get("ArtistIds")).toBe("ar");
    expect(q.get("IncludeItemTypes")).toBe("MusicAlbum");
  });

  it("musicGenres lists genres of songs and albums", async () => {
    await signedIn([["/MusicGenres", { Items: [{ Name: "Rock" }] }]]);
    expect(await m.musicGenres()).toEqual([{ Name: "Rock" }]);
    const { route, q } = lastCall();
    expect(route).toBe("/MusicGenres");
    expect(q.get("userId")).toBe("user-1");
    expect(q.get("IncludeItemTypes")).toBe("Audio,MusicAlbum");
    mockJellyfin([[/.*/, null]]);
    expect(await m.musicGenres()).toEqual([]);
  });
});

describe("playlists", () => {
  it("audioPlaylists keeps audio playlists (and those with no media type) only", async () => {
    await signedIn([[/.*/, { Items: [{ Id: "a", MediaType: "Audio" }, { Id: "v", MediaType: "Video" }, { Id: "n" }] }]]);
    expect((await m.audioPlaylists()).map((p) => p.Id)).toEqual(["a", "n"]);
    expect(lastCall().q.get("IncludeItemTypes")).toBe("Playlist");
  });

  it("playlistItems uses the playlist route when it answers", async () => {
    await signedIn([["/Playlists/p/Items", { Items: [{ Id: "1" }] }]]);
    expect(await m.playlistItems("p")).toEqual([{ Id: "1" }]);
    expect(jfPaths()).toHaveLength(1);
    expect(parse(jfPaths()[0]!).q.get("userId")).toBe("user-1");
  });

  it("falls back to /Items?ParentId= when the playlist route answers 403 (a playlist this account doesn't own)", async () => {
    await signedIn([
      ["/Playlists/p/Items", { __status: 403 }],
      ["/Items", { Items: [{ Id: "2" }] }],
    ]);
    expect(await m.playlistItems("p")).toEqual([{ Id: "2" }]);
    const second = parse(jfPaths()[1]!);
    expect(second.route).toBe("/Items");
    expect(second.q.get("ParentId")).toBe("p");
    expect(second.q.get("userId")).toBe("user-1");
  });

  it("falls back when the playlist route comes back empty", async () => {
    await signedIn([
      ["/Playlists/p/Items", { Items: [] }],
      ["/Items", { Items: [{ Id: "3" }] }],
    ]);
    expect(await m.playlistItems("p")).toEqual([{ Id: "3" }]);
  });

  it("answers empty when the fallback has no body", async () => {
    await signedIn([
      ["/Playlists/p/Items", null],
      ["/Items", null],
    ]);
    expect(await m.playlistItems("p")).toEqual([]);
  });

  it("when both fail, reports the first failure (the playlist route's)", async () => {
    await signedIn([
      ["/Playlists/p/Items", { __status: 403 }],
      ["/Items", { __status: 500 }],
    ]);
    await expect(m.playlistItems("p")).rejects.toThrow("Server error 403");
  });

  it("when only the fallback fails, reports its failure", async () => {
    await signedIn([
      ["/Playlists/p/Items", { Items: [] }],
      ["/Items", { __status: 500 }],
    ]);
    await expect(m.playlistItems("p")).rejects.toThrow("Server error 500");
  });

  it("createPlaylist posts an audio playlist for this user and answers its id", async () => {
    await signedIn([["/Playlists", { Id: "new" }]]);
    expect(await m.createPlaylist("Mix", ["a", "b"])).toBe("new");
    const c = lastCall();
    expect(c.route).toBe("/Playlists");
    expect(c.method).toBe("POST");
    expect(c.body).toEqual({ Name: "Mix", Ids: ["a", "b"], UserId: "user-1", MediaType: "Audio" });
  });

  it("createPlaylist fails clearly when the server does not say which playlist it made", async () => {
    await signedIn([["/Playlists", {}]]);
    await expect(m.createPlaylist("Mix", [])).rejects.toThrow(/didn't say which one/);
  });

  it("renamePlaylist and deletePlaylist", async () => {
    await signedIn([[/.*/, null]]);
    await m.renamePlaylist("p", "New");
    expect(lastCall()).toMatchObject({ route: "/Playlists/p", method: "POST", body: { Name: "New" } });
    await m.deletePlaylist("p");
    expect(lastCall()).toMatchObject({ route: "/Items/p", method: "DELETE" });
  });

  it("addToPlaylist sends ids in batches of 100", async () => {
    await signedIn([[/.*/, null]]);
    const ids = Array.from({ length: 250 }, (_, i) => `s${i}`);
    await m.addToPlaylist("p", ids);
    const calls = invokeCalls("jf_request").map((c) => ({ ...parse(c.args.path), method: c.args.method }));
    expect(calls).toHaveLength(3);
    expect(calls.map((c) => c.q.get("ids")!.split(",").length)).toEqual([100, 100, 50]);
    expect(calls[2]!.q.get("ids")!.split(",")[0]).toBe("s200");
    for (const c of calls) {
      expect(c.route).toBe("/Playlists/p/Items");
      expect(c.method).toBe("POST");
      expect(c.q.get("userId")).toBe("user-1");
    }
  });

  it("addToPlaylist with nothing sends nothing", async () => {
    await signedIn();
    await m.addToPlaylist("p", []);
    expect(jfPaths()).toHaveLength(0);
  });

  it("removeFromPlaylist removes by entry id, and sends nothing for none", async () => {
    await signedIn([[/.*/, null]]);
    await m.removeFromPlaylist("p", []);
    expect(jfPaths()).toHaveLength(0);
    await m.removeFromPlaylist("p", ["e1", "e2"]);
    expect(lastCall()).toMatchObject({ route: "/Playlists/p/Items", method: "DELETE" });
    expect(lastCall().q.get("entryIds")).toBe("e1,e2");
  });

  it("movePlaylistEntry posts the new index, never below 0", async () => {
    await signedIn([[/.*/, null]]);
    await m.movePlaylistEntry("p", "e", 3);
    expect(lastCall()).toMatchObject({ route: "/Playlists/p/Items/e/Move/3", method: "POST" });
    await m.movePlaylistEntry("p", "e", -2);
    expect(lastCall().route).toBe("/Playlists/p/Items/e/Move/0");
  });
});

describe("mixes and books", () => {
  it("instantMix", async () => {
    await signedIn([[/.*/, { Items: [{ Id: "m" }] }]]);
    expect(await m.instantMix("seed")).toEqual([{ Id: "m" }]);
    const { route, q } = lastCall();
    expect(route).toBe("/Items/seed/InstantMix");
    expect(q.get("userId")).toBe("user-1");
    expect(q.get("Limit")).toBe("100");
    await m.instantMix("seed", 7);
    expect(lastCall().q.get("Limit")).toBe("7");
    mockJellyfin([[/.*/, null]]);
    expect(await m.instantMix("seed")).toEqual([]);
  });

  it("similarArtists", async () => {
    await signedIn([[/.*/, { Items: [{ Id: "s" }] }]]);
    expect(await m.similarArtists("ar")).toEqual([{ Id: "s" }]);
    const { route, q } = lastCall();
    expect(route).toBe("/Items/ar/Similar");
    expect(q.get("userId")).toBe("user-1");
    expect(q.get("limit")).toBe("12");
    mockJellyfin([[/.*/, null]]);
    expect(await m.similarArtists("ar")).toEqual([]);
  });

  it("resumeBooks uses the userId= resume route for audiobooks", async () => {
    await signedIn([[/.*/, { Items: [{ Id: "b" }] }]]);
    expect(await m.resumeBooks(5)).toEqual([{ Id: "b" }]);
    const { route, q } = lastCall();
    expect(route).toBe("/UserItems/Resume");
    expect(q.get("userId")).toBe("user-1");
    expect(q.get("IncludeItemTypes")).toBe("AudioBook");
    expect(q.get("MediaTypes")).toBe("Audio");
    expect(q.get("Limit")).toBe("5");
    mockJellyfin([[/.*/, null]]);
    expect(await m.resumeBooks()).toEqual([]);
  });
});

describe("lyrics", () => {
  it("converts timed lines from ticks to seconds", async () => {
    await signedIn([["/Audio/s/Lyrics", { Lyrics: [{ Text: "one", Start: 12_500_000 }, { Text: "two", Start: 0 }] }]]);
    expect(await m.lyrics("s")).toEqual([
      { text: "one", start: 1.25 },
      { text: "two", start: 0 },
    ]);
  });

  it("plain lyrics have no start times; a missing text is an empty line", async () => {
    await signedIn([["/Audio/s/Lyrics", { Lyrics: [{ Text: "la" }, {}, null] }]]);
    expect(await m.lyrics("s")).toEqual([
      { text: "la", start: null },
      { text: "", start: null },
      { text: "", start: null },
    ]);
  });

  it("answers null for a song with none: a 404 (the common case) or an empty list", async () => {
    await signedIn([["/Audio/s/Lyrics", { __status: 404 }]]);
    expect(await m.lyrics("s")).toBeNull();
    mockJellyfin([["/Audio/s/Lyrics", { Lyrics: [] }]]);
    expect(await m.lyrics("s")).toBeNull();
    mockJellyfin([["/Audio/s/Lyrics", null]]);
    expect(await m.lyrics("s")).toBeNull();
  });
});

describe("searchMusic", () => {
  it("searches artists, albums, songs and playlists at once and keeps audio playlists only", async () => {
    await signedIn([
      ["/Artists", { Items: [{ Id: "ar" }] }],
      [
        /^\/Items/,
        (a: any) => {
          const t = parse(a.path).q.get("IncludeItemTypes");
          if (t === "MusicAlbum") return { Items: [{ Id: "al" }] };
          if (t === "Audio") return { Items: [{ Id: "so" }] };
          return { Items: [{ Id: "pl", MediaType: "Audio" }, { Id: "vid", MediaType: "Video" }] };
        },
      ],
    ]);
    const r = await m.searchMusic("q", 9);
    expect(r).toEqual({
      artists: [{ Id: "ar" }],
      albums: [{ Id: "al" }],
      songs: [{ Id: "so" }],
      playlists: [{ Id: "pl", MediaType: "Audio" }],
    });
    const artistCall = parse(jfPaths().find((p) => p.startsWith("/Artists"))!);
    expect(artistCall.route).toBe("/Artists");
    expect(artistCall.q.get("SearchTerm")).toBe("q");
    expect(artistCall.q.get("Limit")).toBe("9");
  });

  it("a failing artist or playlist search costs only that section", async () => {
    await signedIn([
      ["/Artists", { __status: 500 }],
      [
        /^\/Items/,
        (a: any) => {
          const t = parse(a.path).q.get("IncludeItemTypes");
          if (t === "Playlist") return { __status: 500 };
          return { Items: [{ Id: t }] };
        },
      ],
    ]);
    expect(await m.searchMusic("q")).toEqual({
      artists: [],
      albums: [{ Id: "MusicAlbum" }],
      songs: [{ Id: "Audio" }],
      playlists: [],
    });
  });

  it("a failing song search fails the whole search", async () => {
    await signedIn([
      [/IncludeItemTypes=Audio&/, { __status: 500 }],
      [/.*/, { Items: [] }],
    ]);
    await expect(m.searchMusic("q")).rejects.toThrow("Server error 500");
  });
});

describe("drawing helpers", () => {
  it.each([
    [{ AlbumArtist: "AA", Artists: ["x"] }, "AA"],
    [{ AlbumArtists: [{ Name: "A" }, { Name: "" }, { Name: "B" }] }, "A, B"],
    [{ Artists: ["X", "Y"] }, "X, Y"],
    [{ ArtistItems: [{ Name: "I" }, {}] }, "I"],
    [{ AlbumArtists: [], Artists: [], ArtistItems: [] }, ""],
    [{}, ""],
  ])("artistLine(%j) = %j", (item, want) => {
    expect(m.artistLine(item)).toBe(want);
  });

  it("coverUrl uses the item's own art, then a song's album art, else null", async () => {
    expect(m.coverUrl({ Id: "s", AlbumId: "al", AlbumPrimaryImageTag: "t" })).toBeNull(); // no session
    await signIn();
    expect(m.coverUrl({ Id: "s", ImageTags: { Primary: "own" } }, 200)).toBe(
      "http://jf.test:8096/Items/s/Images/Primary?maxWidth=200&tag=own&quality=90"
    );
    expect(m.coverUrl({ Id: "s", AlbumId: "al", AlbumPrimaryImageTag: "t" })).toBe(
      "http://jf.test:8096/Items/al/Images/Primary?maxWidth=400&tag=t&quality=90"
    );
    expect(m.coverUrl({ Id: "s", AlbumId: "al" })).toBeNull();
    expect(m.coverUrl({ Id: "s" })).toBeNull();
  });

  it("albumsInOrder: each album once, in the songs' order, as an album item", () => {
    const songs = [
      { AlbumId: "a1", Album: "One", AlbumArtist: "X", AlbumArtists: [{ Name: "X" }], ProductionYear: 1999, AlbumPrimaryImageTag: "t1" },
      { AlbumId: "a2", Album: "Two" },
      { AlbumId: "a1", Album: "One again" },
      { Album: "no id" },
    ];
    expect(m.albumsInOrder(songs)).toEqual([
      { Id: "a1", Name: "One", Type: "MusicAlbum", AlbumArtist: "X", AlbumArtists: [{ Name: "X" }], ProductionYear: 1999, ImageTags: { Primary: "t1" } },
      { Id: "a2", Name: "Two", Type: "MusicAlbum", AlbumArtist: undefined, AlbumArtists: undefined, ProductionYear: undefined, ImageTags: {} },
    ]);
  });

  it("streamUrl asks for the original file with the device id encoded", async () => {
    await signIn({ device_id: "dev 1/2" });
    expect(m.streamUrl({ Id: "s" })).toBe(
      "http://jf.test:8096/Audio/s/stream?static=true&MediaSourceId=s&DeviceId=dev%201%2F2"
    );
    // No token in the address: the backend adds the credential.
    expect(m.streamUrl({ Id: "s" })).not.toMatch(/api_key|token/i);
  });

  it.each([
    [undefined, 0],
    [null, 0],
    [0, 0],
    [25_000_000, 2.5],
  ])("secondsOf(%j) = %j", (t, s) => {
    expect(m.secondsOf(t as any)).toBe(s);
  });

  it.each([
    [0, "0:00"],
    [5.9, "0:05"],
    [65, "1:05"],
    [3599, "59:59"],
    [3600, "1:00:00"],
    [3725, "1:02:05"],
    [-3, "0:00"],
    [NaN, "0:00"],
    [Infinity, "0:00"],
  ])("clock(%j) = %j", (sec, want) => {
    expect(m.clock(sec)).toBe(want);
  });

  it.each([
    [0, "0 min"],
    [59 * 60, "59 min"],
    [3600, "1 hr"],
    [3600 + 12 * 60, "1 hr 12 min"],
    [2 * 3600 + 29, "2 hr"],
  ])("longDuration(%j) = %j", (sec, want) => {
    expect(m.longDuration(sec)).toBe(want);
  });
});

it("every request in this module uses userId= routes and never a /Users/{id}/ path (invariant)", async () => {
  await signedIn([[/.*/, { Items: [], Id: "x" }]]);
  onInvoke("config_save", null);
  await Promise.allSettled([
    m.music({ types: "Audio" }),
    m.artists(),
    m.musicItem("i"),
    m.musicGenres(),
    m.playlistItems("p"),
    m.instantMix("i"),
    m.similarArtists("i"),
    m.resumeBooks(),
    m.lyrics("i"),
  ]);
  for (const p of jfPaths()) {
    expect(p).not.toMatch(/\/Users\//);
    expect(p).not.toMatch(/api_key|X-Emby-Token/i);
  }
});
