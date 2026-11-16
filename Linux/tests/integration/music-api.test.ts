// musicApi.ts against the live QA server: artists, albums and their tracks,
// genres, playlists (read, and one made, changed and deleted), mixes,
// lyrics, audiobooks, search, and the stream and cover addresses.
//
// Expectations come from fixtures.json → fixtures.music (FIXTURES.md, Music).
//
// Server state changed, and how it is put back: one private playlist named
// "suite-linux vitest <time>" is created, changed and deleted in the same
// test (deleted again in a finally if the test fails part way). Nothing else
// is written.
import { beforeEach, describe, expect, it, vi } from "vitest";
import { qa, qaWritable } from "../helpers/qa";
import { authHeader, expectCleanBridgeCalls, fxSet, qaApiFull } from "../helpers/api-qa";

beforeEach(() => {
  vi.resetModules();
});

/** The music API, signed in to the live server. */
async function musicApi() {
  await qaApiFull();
  return import("../../src/musicApi");
}

function album(name: string): any {
  const a = qa!.fixtures.fixtures.music.albums.find((x: any) => x.name === name);
  if (!a) throw new Error(`album ${name} is not in fixtures.json`);
  return a;
}

function track(name: string): any {
  for (const a of qa!.fixtures.fixtures.music.albums) {
    const t = a.tracks.find((x: any) => x.name === name);
    if (t) return t;
  }
  throw new Error(`track ${name} is not in fixtures.json`);
}

const MUSIC_LIB = (): string => qa!.fixtures.fixtures.music.libraryId;

describe.skipIf(!qa)("QA server: musicApi", () => {
  it("lists album artists, and everyone credited with all", async () => {
    const m = await musicApi();
    const albumArtists = (await m.artists({ limit: 500 })).Items.map((a) => a.Name);
    expect(albumArtists).toEqual(expect.arrayContaining(["FX Band", "Various Artists"]));
    const everyone = (await m.artists({ all: true, limit: 1000 })).Items.map((a) => a.Name);
    expect(everyone).toEqual(expect.arrayContaining(["FX Band", "FX Duo", "FX Singer"]));
    const found = await m.artists({ all: true, searchTerm: "FX Sing" });
    expect(found.Items.map((a) => a.Name)).toContain("FX Singer");
    expectCleanBridgeCalls();
  });

  it("lists an artist's own albums newest first, and the albums they only appear on", async () => {
    const m = await musicApi();
    const band = (await m.artists({ all: true, searchTerm: "FX Band" })).Items.find((a) => a.Name === "FX Band")!;
    const own = await m.albumsBy(band.Id);
    const want = qa!.fixtures.fixtures.music.albums.filter((a: any) => a.albumArtist === "FX Band");
    expect(own.map((a) => a.Name).sort()).toEqual(want.map((a: any) => a.name).sort());
    expect(own.map((a) => a.ProductionYear)).toEqual([...own.map((a) => a.ProductionYear)].sort((a, b) => b - a));
    // FX Band has a track on the compilation, whose album artist is Various Artists.
    expect((await m.appearsOn(band.Id)).map((a) => a.Name)).toEqual(["FX Compilation"]);
    const singer = (await m.artists({ all: true, searchTerm: "FX Singer" })).Items.find((a) => a.Name === "FX Singer")!;
    expect((await m.albumsBy(singer.Id)).map((a) => a.Name)).toEqual([]);
    expect((await m.appearsOn(singer.Id)).map((a) => a.Name)).toEqual(["FX Compilation"]);
  });

  it("lists an artist's songs, and top songs by plays", async () => {
    const m = await musicApi();
    const duo = (await m.artists({ all: true, searchTerm: "FX Duo" })).Items.find((a) => a.Name === "FX Duo")!;
    const songs = await m.allSongs(duo.Id);
    expect(songs.map((s) => s.Name).sort()).toEqual(["Compilation Four", "Compilation Two"]);
    expect(songs.every((s) => s.Type === "Audio")).toBe(true);
    const top = await m.topSongs(duo.Id, 1);
    expect(top).toHaveLength(1);
  });

  it("orders a two-disc album disc by disc, track by track", async () => {
    const m = await musicApi();
    const a = album("FX Two Discs");
    const tracks = await m.albumTracks(a.id);
    const want = [...a.tracks].sort((x: any, y: any) => (x.disc ?? 1) - (y.disc ?? 1) || x.track - y.track);
    expect(tracks.map((t) => t.Name)).toEqual(want.map((t: any) => t.name));
    expect(tracks.map((t) => t.ParentIndexNumber)).toEqual(want.map((t: any) => t.disc));
  });

  it("names the album artist and the track artists the way the sleeve does", async () => {
    const m = await musicApi();
    const tracks = await m.albumTracks(album("FX Compilation").id);
    const four = tracks.find((t) => t.Name === "Compilation Four")!;
    expect(four.ArtistItems.map((a: any) => a.Name)).toEqual(track("Compilation Four").artists);
    expect(m.artistLine(four)).toBe("Various Artists");
    expect(m.artistLine({ ArtistItems: four.ArtistItems })).toBe("FX Singer, FX Duo");
  });

  it("reads one song's detail fields, and its file through the stream address", async () => {
    const m = await musicApi();
    const t = track("Disc One Opener");
    const item = await m.musicItem(t.id);
    expect(item.Name).toBe(t.name);
    expect(item.MediaSources[0].Container).toBe(t.container);
    expect(Math.round(m.secondsOf(item.RunTimeTicks))).toBe(Math.round(t.durationSeconds));
    const url = m.streamUrl(item);
    expect(url).not.toMatch(/api_?key|token/i);
    const res = await fetch(url, { headers: { Authorization: authHeader(), Range: "bytes=0-3" } });
    expect(res.status).toBe(206);
    expect(Buffer.from(await res.arrayBuffer()).toString("latin1")).toBe("fLaC");
  });

  it("has no cover for a fixture album the server holds no art for", async () => {
    const m = await musicApi();
    // Fixture Music's art is only embedded in the files; the server shows none.
    const a = (await m.music({ types: "MusicAlbum", parentId: MUSIC_LIB() })).Items.find((x) => x.Name === "FX Two Discs")!;
    expect(m.coverUrl(a)).toBeNull();
    expect(m.coverUrl((await m.albumTracks(a.Id))[0])).toBeNull();
  });

  it("serves cover art for an album, and for a song through its album", async () => {
    const m = await musicApi();
    // The older Music library has album art (from AudioDB).
    const lib = qa!.fixtures.libraries.Music.id;
    const a = (await m.music({ types: "MusicAlbum", parentId: lib })).Items.find((x) => x.ImageTags?.Primary)!;
    expect(a).toBeDefined();
    const song = (await m.albumTracks(a.Id))[0];
    for (const url of [m.coverUrl(a), m.coverUrl(song)]) {
      expect(url).toBeTruthy();
      const res = await fetch(url!);
      expect(res.status, url!).toBe(200);
      expect(res.headers.get("content-type")).toMatch(/^image\//);
    }
    const shelf = m.albumsInOrder(await m.albumTracks(a.Id));
    expect(shelf.map((x) => x.Id)).toEqual([a.Id]);
  });

  it("pages and sorts the library's albums and filters songs by year and genre", async () => {
    const m = await musicApi();
    const all = await m.music({ types: "MusicAlbum", parentId: MUSIC_LIB() });
    expect(all.TotalRecordCount).toBe(qa!.fixtures.fixtures.music.albums.length);
    const byYear = await m.music({ types: "MusicAlbum", parentId: MUSIC_LIB(), sort: "year" });
    expect(byYear.Items.map((a) => a.ProductionYear)).toEqual([2023, 2022, 2021, 2020]);
    const page = await m.music({ types: "MusicAlbum", parentId: MUSIC_LIB(), startIndex: 1, limit: 2 });
    expect(page.Items.map((a) => a.Id)).toEqual(all.Items.slice(1, 3).map((a) => a.Id));
    const y2022 = await m.music({ types: "Audio", parentId: MUSIC_LIB(), years: [2022] });
    expect(y2022.Items.map((s) => s.Name).sort()).toEqual(["Six Minutes", "Twelve Minutes"]);
    const ambient = await m.music({ types: "Audio", parentId: MUSIC_LIB(), genres: ["FX Ambient"] });
    expect(ambient.Items.map((s) => s.Name).sort()).toEqual(["Six Minutes", "Twelve Minutes"]);
    const flat = await m.music({ types: "MusicAlbum", parentId: MUSIC_LIB(), recursive: false, excludeIds: [all.Items[0]!.Id] });
    expect(flat.Items.map((a) => a.Id)).not.toContain(all.Items[0]!.Id);
  });

  it("lists music genres and a genre's songs", async () => {
    const m = await musicApi();
    const genres = await m.musicGenres();
    const names = genres.map((g) => g.Name);
    expect(names).toEqual(expect.arrayContaining(["FX Rock", "FX Jazz", "FX Ambient"]));
    const ambient = genres.find((g) => g.Name === "FX Ambient")!;
    expect((await m.genreSongs(ambient.Id)).map((s) => s.Name).sort()).toEqual(
      expect.arrayContaining(["Six Minutes", "Twelve Minutes"])
    );
  });

  it("lists the audio playlists the account can see, video playlists left out", async () => {
    const m = await musicApi();
    const names = (await m.audioPlaylists()).map((p) => p.Name);
    expect(names).toEqual(expect.arrayContaining(["FX Music Playlist", `${qa!.account.name} Playlist`]));
    expect(names).not.toContain("FX Video Playlist");
  });

  it("reads a playlist's songs in the playlist's own order", async () => {
    const m = await musicApi();
    const set = fxSet("FX Music Playlist");
    const items = await m.playlistItems(set.id);
    expect(items.map((i) => i.Name)).toEqual(set.items.map((i: any) => i.name));
  });

  it("reads synced lyrics with times, plain lyrics without, and none as null", async () => {
    const m = await musicApi();
    const synced = await m.lyrics(track("Disc One Opener").id);
    const want = track("Disc One Opener").lyrics;
    expect(synced).toHaveLength(want.lines);
    expect(synced![0]).toEqual({ text: want.first, start: 0 });
    expect(synced!.every((l) => typeof l.start === "number")).toBe(true);
    const plain = await m.lyrics(track("Disc One Middle").id);
    expect(plain!.length).toBeGreaterThan(0);
    expect(plain!.every((l) => l.start === null)).toBe(true);
    expect(await m.lyrics(track("Compilation One").id)).toBeNull();
  });

  it("builds an instant mix and lists similar artists", async () => {
    const m = await musicApi();
    const mix = await m.instantMix(track("Disc One Opener").id, 20);
    expect(mix.length).toBeGreaterThan(0);
    expect(mix.every((s) => s.Type === "Audio")).toBe(true);
    const band = (await m.artists({ all: true, searchTerm: "FX Band" })).Items.find((a) => a.Name === "FX Band")!;
    expect(Array.isArray(await m.similarArtists(band.Id))).toBe(true);
  });

  it("lists recently and most played songs (played songs only), and audiobooks in progress", async () => {
    const m = await musicApi();
    for (const list of [await m.recentlyPlayedSongs(), await m.mostPlayedSongs()]) {
      expect(list.every((s) => s.Type === "Audio" && s.UserData?.Played)).toBe(true);
    }
    const books = await m.resumeBooks();
    const server = await qa!.request(`/UserItems/Resume?userId=${qa!.userId}&MediaTypes=Audio&IncludeItemTypes=AudioBook&Limit=24`);
    expect(books.map((b) => b.Id)).toEqual(server.body.Items.map((b: any) => b.Id));
    expect(books.every((b) => b.Type === "AudioBook")).toBe(true);
  });

  it("finds artists, albums and songs by search", async () => {
    const m = await musicApi();
    const r = await m.searchMusic("FX Two");
    expect(r.albums.map((a) => a.Name)).toContain("FX Two Discs");
    const s = await m.searchMusic("Opener");
    expect(s.songs.map((x) => x.Name)).toContain("Disc One Opener");
    const p = await m.searchMusic("FX Music");
    expect(p.playlists.map((x) => x.Name)).toContain("FX Music Playlist");
  });

  it.skipIf(!qaWritable)("creates, fills, reorders, trims, renames and deletes a playlist of its own", async () => {
    const m = await musicApi();
    const name = `${qa!.account.name} vitest ${Date.now()}`;
    const formats = album("FX Formats").tracks.map((t: any) => t.id);
    let id: string | null = null;
    try {
      id = await m.createPlaylist(name, formats.slice(0, 2));
      expect(id).toMatch(/^[0-9a-f]{32}$/);
      await m.addToPlaylist(id, formats.slice(2, 4));
      let items = await m.playlistItems(id);
      expect(items.map((i) => i.Id)).toEqual(formats.slice(0, 4));
      // Move the last entry to the front.
      await m.movePlaylistEntry(id, items[3].PlaylistItemId, 0);
      items = await m.playlistItems(id);
      expect(items.map((i) => i.Id)).toEqual([formats[3], formats[0], formats[1], formats[2]]);
      // A negative position is taken as the front.
      await m.movePlaylistEntry(id, items[1].PlaylistItemId, -4);
      items = await m.playlistItems(id);
      expect(items[0].Id).toBe(formats[0]);
      // Removing goes by entry, not by song.
      await m.removeFromPlaylist(id, [items[0].PlaylistItemId]);
      await m.removeFromPlaylist(id, []);
      items = await m.playlistItems(id);
      expect(items.map((i) => i.Id)).not.toContain(formats[0]);
      expect(items).toHaveLength(3);
      await m.renamePlaylist(id, `${name} renamed`);
      expect((await m.musicItem(id)).Name).toBe(`${name} renamed`);
      expect((await m.audioPlaylists()).map((p) => p.Id)).toContain(id);
      await m.deletePlaylist(id);
      const gone = id;
      id = null;
      expect((await m.audioPlaylists()).map((p) => p.Id)).not.toContain(gone);
    } finally {
      if (id) await qa!.request(`/Items/${id}`, "DELETE");
    }
  });
});
