// The pieces every music and audiobook page shares (src/views/musicCommon.ts):
// icons, routes, what "Play" plays, mixes and stations, the playlist pickers,
// the song menu, Song Info, cards, shelves, song rows and their selection.
// Real api / musicApi / cache / ui under the mocked Tauri bridge; audio.ts is
// the stand-in from helpers/views-media-music, and the two things that would
// reach far past this file (the station builder's library crawl and the
// download queue) are spies.
import { beforeEach, describe, expect, it, vi } from "vitest";
import { flush, invokeCalls, jfPaths, onInvoke, signIn, type JfArgs } from "../helpers/tauri";
import {
  click,
  dblclick,
  dialogButtons,
  dialogEl,
  dialogTitle,
  key,
  lastToast,
  menuLabels,
  menuTitle,
  mountShell,
  openMenuEl,
  pickDialog,
  pickMenu,
  rightClick,
  settle,
  texts,
  toasts,
} from "../helpers/views-media";
import {
  album,
  artist,
  book,
  musicServer,
  playlist,
  query,
  song,
  type FakeAudio,
} from "../helpers/views-media-music";

vi.mock("../../src/audio", async () => (await import("../helpers/views-media-music")).fakeAudioModule());
vi.mock("../../src/stations", async (importOriginal) => {
  const real = await importOriginal<typeof import("../../src/stations")>();
  return {
    ...real,
    buildStation: vi.fn(async (seed: any) => ({
      source: { title: `${seed.Name} Station`, more: async () => [] },
      first: [{ Id: "st1", Type: "Audio", Name: "Station One" }],
    })),
    // The real module stays loaded across vi.resetModules (the mock is cached),
    // so anything in it that reads the signed-in config would read the first
    // test's: the Mixes setting and the server's Instant Mix are spies too.
    getMixSource: vi.fn(() => "aquarium"),
    buildInstantMix: vi.fn(async () => [{ Id: "m1", Type: "Audio" }, { Id: "m2", Type: "Audio" }]),
  };
});
vi.mock("../../src/playback", async (importOriginal) => {
  const real = await importOriginal<typeof import("../../src/playback")>();
  return { ...real, downloadSeason: vi.fn(async () => ({ queued: 1, skipped: 0, cancelled: false })) };
});

type MC = typeof import("../../src/views/musicCommon");

let audio: FakeAudio;
let mc: MC;
let api: typeof import("../../src/api");
let root: HTMLElement;

beforeEach(() => {
  vi.resetModules();
  vi.clearAllMocks();
});

async function boot(cfg: Record<string, any> = {}, server: Parameters<typeof musicServer>[0] = {}): Promise<void> {
  root = mountShell();
  musicServer(server);
  onInvoke("downloads_list", []);
  api = await signIn(cfg);
  audio = (await import("../../src/audio")) as any;
  audio.__reset();
  mc = await import("../../src/views/musicCommon");
}

const played = () => (audio.play as any).mock.calls as any[][];

describe("mi and iconButton", () => {
  it("draws an icon as a hidden svg span, sized when asked", async () => {
    await boot();
    const s = mc.mi("play");
    expect(s.className).toBe("ico");
    expect(s.getAttribute("aria-hidden")).toBe("true");
    expect(s.querySelector("svg")!.getAttribute("viewBox")).toBe("0 0 24 24");
    expect(s.style.cssText).toBe("");
    expect(mc.mi("note", 34).style.width).toBe("34px");
  });

  it("makes a labelled icon button that runs its handler", async () => {
    await boot();
    const fn = vi.fn();
    const b = mc.iconButton("more", "More", fn, "extra");
    expect(b.className).toBe("btn icon mu-ibtn extra");
    expect(b.title).toBe("More");
    expect(b.getAttribute("aria-label")).toBe("More");
    click(b);
    expect(fn).toHaveBeenCalledTimes(1);
    expect(mc.iconButton("more", "M", fn).className).toBe("btn icon mu-ibtn");
  });
});

describe("routeFor", () => {
  it("routes each kind of music item to its page", async () => {
    await boot();
    expect(mc.routeFor({ Type: "MusicAlbum", Id: "a" })).toBe("#/music/album/a");
    expect(mc.routeFor({ Type: "MusicArtist", Id: "a" })).toBe("#/music/artist/a");
    expect(mc.routeFor({ Type: "MusicGenre", Id: "g" })).toBe("#/music/genre/g");
    expect(mc.routeFor({ Type: "Genre", Id: "g" })).toBe("#/music/genre/g");
    expect(mc.routeFor({ Type: "Playlist", Id: "p" })).toBe("#/music/playlist/p");
    expect(mc.routeFor({ Type: "SmartPlaylist", Id: "s" })).toBe("#/music/smart/s");
    expect(mc.routeFor({ Type: "AudioBook", Id: "b" })).toBe("#/books/book/b");
    expect(mc.routeFor({ Type: "Audio", Id: "s", AlbumId: "al" })).toBe("#/music/album/al");
    expect(mc.routeFor({ Type: "Audio", Id: "s" })).toBeNull();
    expect(mc.routeFor({ Type: "Movie", Id: "m" })).toBeNull();
    expect(mc.routeFor(null)).toBeNull();
  });
});

describe("songsOf", () => {
  it("is the item itself for a song or a book", async () => {
    await boot();
    const s = song("s1");
    expect(await mc.songsOf(s)).toEqual([s]);
    const b = book("b1");
    expect(await mc.songsOf(b)).toEqual([b]);
    expect(jfPaths()).toEqual([]);
  });

  it("asks the server for an album's tracks in sleeve order, an artist's, a genre's and a playlist's songs", async () => {
    await boot({}, {
      items: (q) => {
        if (q.get("ParentId") === "al1") return [song("t2", { IndexNumber: 2 }), song("t1", { IndexNumber: 1 })];
        if (q.get("ArtistIds") === "ar1") return [song("a1")];
        if (q.get("GenreIds") === "g1") return [song("g1s")];
        return [];
      },
      extra: [[/^\/Playlists\/pl1\/Items/, { Items: [song("p1")] }]],
    });
    expect((await mc.songsOf(album("al1"))).map((s) => s.Id)).toEqual(["t1", "t2"]);
    expect((await mc.songsOf(artist("ar1"))).map((s) => s.Id)).toEqual(["a1"]);
    expect((await mc.songsOf({ Type: "MusicGenre", Id: "g1" })).map((s) => s.Id)).toEqual(["g1s"]);
    expect((await mc.songsOf({ Type: "Genre", Id: "g1" })).map((s) => s.Id)).toEqual(["g1s"]);
    expect((await mc.songsOf(playlist("pl1"))).map((s) => s.Id)).toEqual(["p1"]);
    // userId= routes only (Linux/CLAUDE.md), and never a token in the address.
    for (const p of jfPaths()) {
      expect(p).toMatch(/userId=user-1/);
      expect(p).not.toMatch(/api_key|X-Emby-Token/i);
    }
  });

  it("answers a smart playlist from its rules, and nothing for one that is gone or an unknown type", async () => {
    const rules = { id: "sp1", name: "Rocky", genres: ["Rock"], limit: 10, order: "name" };
    await boot({ music_smart_playlists: [rules] }, { items: (q) => (q.get("Genres") === "Rock" ? [song("r1")] : []) });
    expect((await mc.songsOf({ Type: "SmartPlaylist", Id: "sp1" })).map((s) => s.Id)).toEqual(["r1"]);
    expect(await mc.songsOf({ Type: "SmartPlaylist", Id: "gone" })).toEqual([]);
    expect(await mc.songsOf({ Type: "Photo", Id: "x" })).toEqual([]);
  });
});

describe("playThing", () => {
  it("plays what the item stands for, under its name, shuffled when asked", async () => {
    await boot({}, { items: () => [song("t1"), song("t2")] });
    await mc.playThing(album("al1"));
    await mc.playThing(album("al1"), { shuffle: true });
    expect(played()[0]![0].map((s: any) => s.Id)).toEqual(["t1", "t2"]);
    expect(played()[0]!.slice(1)).toEqual([0, { title: "Album al1", shuffle: undefined }]);
    expect(played()[1]![2]).toEqual({ title: "Album al1", shuffle: true });
  });

  it("says so when there is nothing to play, and reports a failure", async () => {
    await boot({}, { items: () => ({ __status: 500 }) });
    await mc.playThing({ Type: "Photo" });
    expect(lastToast()).toBe("Nothing to play there");
    await mc.playThing(album("al1"));
    expect(lastToast()).toMatch(/Server error 500/);
    expect(document.querySelector("#toasts .toast.error")).not.toBeNull();
    expect(audio.play).not.toHaveBeenCalled();
  });
});

describe("startStation and the Mixes setting", () => {
  it("builds the app's own station by default and plays it as a queue that keeps going", async () => {
    await boot();
    await mc.startStation(artist("ar1"));
    expect(toasts()[0]).toBe("Starting a mix from Artist ar1…");
    const [items, start, opts] = played()[0]!;
    expect(items.map((s: any) => s.Id)).toEqual(["st1"]);
    expect(start).toBe(0);
    expect(opts.title).toBe("Artist ar1 Station");
    expect(opts.source).toBeTruthy();
    expect(opts.offlineMix).toBe(false);
  });

  it("uses Jellyfin's Instant Mix when the setting says so, played as the server sent it (regression: 77b0f7c Mixes setting)", async () => {
    await boot();
    const stations = await import("../../src/stations");
    vi.mocked(stations.getMixSource).mockReturnValue("jellyfin");
    await mc.startStation(artist("ar1"));
    const [items, , opts] = played()[0]!;
    expect(items.map((s: any) => s.Id)).toEqual(["m1", "m2"]);
    expect(opts).toEqual({ title: "Artist ar1 Mix", source: null, offlineMix: false });
    expect(vi.mocked(stations.buildInstantMix).mock.calls[0]![0].Id).toBe("ar1");
    expect(stations.buildStation).not.toHaveBeenCalled();
    vi.mocked(stations.getMixSource).mockReturnValue("aquarium");
  });

  it("names an unnamed seed's Jellyfin mix and the toast generically", async () => {
    await boot();
    const stations = await import("../../src/stations");
    vi.mocked(stations.getMixSource).mockReturnValueOnce("jellyfin");
    await mc.startStation({ Id: "x", Type: "Audio" });
    expect(toasts()[0]).toBe("Starting a mix from that…");
    expect(played()[0]![2].title).toBe("Instant Mix");
  });

  it("mixes from downloaded songs when there is no server, and says so (regression: 77b0f7c without a server it is always Aquarium's, from downloads)", async () => {
    await boot();
    onInvoke("downloads_list", [
      { item_id: "d1", type: "Audio", status: "complete", path: "/m/d1.flac", name: "Downloaded" },
      { item_id: "d2", type: "Movie", status: "complete", path: "/m/d2.mkv" },
    ]);
    onInvoke("jf_ping", false);
    await api.checkOnline();
    expect(api.isOffline()).toBe(true);
    await mc.startStation(song("d1", { Name: "Seed" }));
    expect(toasts()).toContain("Offline — mixed from your downloads");
    const [items, , opts] = played()[0]!;
    expect(items.map((s: any) => s.Id)).toEqual(["d1"]);
    expect(opts.offlineMix).toBe(true);
    expect(jfPaths()).toEqual([]);
  });

  it("falls back to downloads when the server goes away while the station is being built", async () => {
    await boot();
    onInvoke("downloads_list", [{ item_id: "d1", type: "Audio", status: "complete", path: "/m/d1.flac" }]);
    const stations = await import("../../src/stations");
    vi.mocked(stations.buildStation).mockImplementationOnce(async () => {
      onInvoke("jf_ping", false);
      await api.checkOnline();
      throw new Error("network gone");
    });
    await mc.startStation(song("s1"));
    expect(played()[0]![2].offlineMix).toBe(true);
  });

  it("reports a station that could not be built while the server is up", async () => {
    await boot();
    const stations = await import("../../src/stations");
    vi.mocked(stations.buildStation).mockRejectedValueOnce(new Error("The server couldn't build a station from that"));
    await mc.startStation(song("s1"));
    expect(lastToast()).toBe("The server couldn't build a station from that");
    expect(audio.play).not.toHaveBeenCalled();
  });
});

describe("instantMixFromCurrent", () => {
  it("does nothing with nothing playing, or with a book playing", async () => {
    await boot();
    await mc.instantMixFromCurrent();
    audio.__playing([book("b1")]);
    await mc.instantMixFromCurrent();
    expect(audio.replaceUpNext).not.toHaveBeenCalled();
    expect(toasts()).toEqual([]);
  });

  it("keeps the song playing and replaces Up Next with the mix, without repeating the song (regression: 77b0f7c Instant Mix in the player)", async () => {
    await boot();
    const s = song("s1", { Name: "Hit" });
    audio.__playing([s, song("old")]);
    const stations = await import("../../src/stations");
    vi.mocked(stations.buildStation).mockResolvedValueOnce({
      source: { title: "Hit Station", more: async () => [] },
      first: [s, song("n1"), song("n2")],
    });
    await mc.instantMixFromCurrent();
    const [items, opts] = (audio.replaceUpNext as any).mock.calls[0];
    expect(items.map((x: any) => x.Id)).toEqual(["n1", "n2"]);
    expect(opts.title).toBe("Hit Station");
    expect(opts.offlineMix).toBe(false);
    expect(lastToast()).toBe("Instant Mix from Hit");
  });

  it("uses the whole mix when the song isn't its first entry, and names an unnamed song generically", async () => {
    await boot();
    audio.__playing([song("s1", { Name: undefined })]);
    await mc.instantMixFromCurrent();
    expect((audio.replaceUpNext as any).mock.calls[0][0].map((x: any) => x.Id)).toEqual(["st1"]);
    expect(lastToast()).toBe("Instant Mix from this song");
  });

  it("says so when the mix holds nothing but the song itself", async () => {
    await boot();
    const s = song("s1");
    audio.__playing([s]);
    const stations = await import("../../src/stations");
    vi.mocked(stations.buildStation).mockResolvedValueOnce({ source: { title: "x", more: async () => [] }, first: [s] });
    await mc.instantMixFromCurrent();
    expect(lastToast()).toBe("Nothing to mix with that song");
    expect(audio.replaceUpNext).not.toHaveBeenCalled();
  });

  it("drops the mix when the song changed while it was being built", async () => {
    await boot();
    audio.__playing([song("s1"), song("s2")]);
    const stations = await import("../../src/stations");
    vi.mocked(stations.buildStation).mockImplementationOnce(async () => {
      audio.__st.q.index = 1;
      return { source: { title: "x", more: async () => [] }, first: [song("n1")] };
    });
    await mc.instantMixFromCurrent();
    expect(audio.replaceUpNext).not.toHaveBeenCalled();
  });

  it("offline, mixes from downloads and says it is an offline mix", async () => {
    await boot();
    onInvoke("downloads_list", [
      { item_id: "d1", type: "Audio", status: "complete", path: "/m/d1.flac" },
      { item_id: "d2", type: "Audio", status: "complete", path: "/m/d2.flac" },
    ]);
    onInvoke("jf_ping", false);
    await api.checkOnline();
    audio.__playing([song("d1")]);
    await mc.instantMixFromCurrent();
    const [items, opts] = (audio.replaceUpNext as any).mock.calls[0];
    expect(items.map((x: any) => x.Id)).toEqual(["d2"]);
    expect(opts.offlineMix).toBe(true);
    expect(lastToast()).toBe("Offline — mixed from your downloads");
  });
});

describe("shuffleAll", () => {
  it("shuffles up to 500 random songs from the library", async () => {
    let q: URLSearchParams | null = null;
    await boot({}, { items: (x) => ((q = x), [song("a"), song("b")]) });
    await mc.shuffleAll();
    expect(q!.get("IncludeItemTypes")).toBe("Audio");
    expect(q!.get("SortBy")).toBe("Random");
    expect(q!.get("Limit")).toBe("500");
    expect(played()[0]![2]).toEqual({ title: "Shuffle All", shuffle: true });
  });

  it("says so when the library has no songs, or reports a failure", async () => {
    await boot();
    await mc.shuffleAll();
    expect(lastToast()).toBe("There's nothing in your music library to shuffle yet");
    musicServer({ items: () => ({ __status: 500 }) });
    await mc.shuffleAll();
    expect(lastToast()).toMatch(/Server error 500/);
  });

  it("offline, shuffles every downloaded song, or says there are none", async () => {
    await boot();
    onInvoke("jf_ping", false);
    await api.checkOnline();
    await mc.shuffleAll();
    expect(lastToast()).toBe("No downloaded songs to shuffle");
    onInvoke("downloads_list", [
      { item_id: "d1", type: "Audio", status: "complete", path: "/m/d1.flac" },
      { item_id: "b1", type: "AudioBook", status: "complete", path: "/m/b1.m4b" },
    ]);
    await mc.shuffleAll();
    expect(played()[0]![0].map((s: any) => s.Id)).toEqual(["d1"]);
  });
});

describe("askName", () => {
  it("asks in a dialog with the suggestion filled in and focused, and resolves the trimmed name", async () => {
    await boot();
    const p = mc.askName("New Playlist", "Mix", "Create");
    expect(dialogTitle()).toBe("New Playlist");
    expect(dialogButtons()).toEqual(["Cancel", "Create"]);
    const input = dialogEl()!.querySelector<HTMLInputElement>("input.mu-input")!;
    expect(input.value).toBe("Mix");
    await settle();
    expect(document.activeElement).toBe(input);
    input.value = "  Road Trip  ";
    await pickDialog("Create");
    expect(await p).toBe("Road Trip");
  });

  it("resolves null for Cancel, Escape, and a blank name", async () => {
    await boot();
    let p = mc.askName("Name");
    await pickDialog("Cancel");
    expect(await p).toBeNull();
    p = mc.askName("Name");
    key(document, "Escape");
    expect(await p).toBeNull();
    expect(dialogEl()).toBeNull();
    p = mc.askName("Name", "   ");
    await pickDialog("Save");
    expect(await p).toBeNull();
  });

  it("takes Enter in the field as Save and closes the dialog", async () => {
    await boot();
    const p = mc.askName("Name", "Typed");
    const ev = key(dialogEl()!.querySelector("input"), "Enter");
    expect(ev.defaultPrevented).toBe(true);
    expect(await p).toBe("Typed");
    expect(dialogEl()).toBeNull();
    // Another key is just typing.
    const p2 = mc.askName("Name", "x");
    key(dialogEl()!.querySelector("input"), "a");
    expect(dialogEl()).not.toBeNull();
    await pickDialog("Cancel");
    expect(await p2).toBeNull();
  });
});

describe("newPlaylistWith", () => {
  it("creates the playlist with the songs, says so and tells open pages", async () => {
    let body: any = null;
    await boot({}, { extra: [[/^\/Playlists$/, (a: JfArgs) => ((body = a.body), { Id: "new1" })]] });
    const changed = vi.fn();
    mc.playlistsChanged.addEventListener("change", changed);
    location.hash = "#/somewhere";
    const p = mc.newPlaylistWith([song("a"), song("b")], "Mix");
    await flush();
    dialogEl()!.querySelector<HTMLInputElement>("input")!.value = "Mine";
    await pickDialog("Create");
    await p;
    expect(body).toEqual({ Name: "Mine", Ids: ["a", "b"], UserId: "user-1", MediaType: "Audio" });
    expect(invokeCalls("jf_request").find((c) => c.args.path === "/Playlists")!.args.method).toBe("POST");
    expect(lastToast()).toBe("Made “Mine”");
    expect(changed).toHaveBeenCalledTimes(1);
    // With songs in it, the page stays where it is.
    expect(location.hash).toBe("#/somewhere");
  });

  it("opens an empty new playlist's page", async () => {
    await boot({}, { extra: [[/^\/Playlists$/, { Id: "new2" }]] });
    const p = mc.newPlaylistWith([]);
    dialogEl()!.querySelector<HTMLInputElement>("input")!.value = "Empty";
    await pickDialog("Create");
    await p;
    expect(location.hash).toBe("#/music/playlist/new2");
  });

  it("sends nothing when cancelled, and reports a server that didn't say which playlist it made", async () => {
    await boot({}, { extra: [[/^\/Playlists$/, {}]] });
    let p = mc.newPlaylistWith([song("a")]);
    await pickDialog("Cancel");
    await p;
    expect(jfPaths()).toEqual([]);
    p = mc.newPlaylistWith([song("a")], "X");
    await pickDialog("Create");
    await p;
    expect(lastToast()).toBe("The server made the playlist but didn't say which one it is");
  });
});

describe("primePlaylists and Add to Playlist", () => {
  const lists = () => [playlist("p1", { Name: "Road" }), playlist("p2", { Name: "Gym" }), playlist("v1", { MediaType: "Video" })];

  it("fetches the audio playlists once for every menu, and again when forced", async () => {
    await boot({}, { items: (q) => (q.get("IncludeItemTypes") === "Playlist" ? lists() : []) });
    const a = mc.primePlaylists();
    expect(mc.primePlaylists()).toBe(a);
    await a;
    expect(jfPaths().length).toBe(1);
    await mc.primePlaylists(true);
    expect(jfPaths().length).toBe(2);
  });

  it("refetches after any playlist change", async () => {
    await boot({}, { items: () => lists() });
    await mc.primePlaylists();
    mc.playlistsChanged.dispatchEvent(new Event("change"));
    await settle();
    expect(jfPaths().length).toBe(2);
  });

  it("lets the next menu try again after a failed fetch", async () => {
    let fail = true;
    await boot({}, { items: () => (fail ? { __status: 500 } : lists()) });
    await mc.primePlaylists();
    fail = false;
    await mc.primePlaylists();
    expect(jfPaths().length).toBe(2);
  });

  it("offers New Playlist… then every audio playlist except the item itself, and adds to the one picked", async () => {
    const added: string[] = [];
    await boot({}, {
      items: (q) => (q.get("IncludeItemTypes") === "Playlist" ? lists() : []),
      extra: [[/^\/Playlists\/p\d\/Items\?ids=/, (a: JfArgs) => (added.push(a.path), null)]],
    });
    await mc.primePlaylists();
    const action = mc.addToPlaylistAction(playlist("p2"));
    expect(action.label).toBe("Add to Playlist");
    expect(action.submenu!.items().map((a) => a.label)).toEqual(["New Playlist…", "Road"]);
    const s = song("s1");
    await mc.addToPlaylistAction(s, "Add").submenu!.items()[1]!.run!();
    expect(added).toEqual(["/Playlists/p1/Items?ids=s1&userId=user-1"]);
    expect(lastToast()).toBe("Added to “Road”");
  });

  it("reports a failed add", async () => {
    await boot({}, {
      items: (q) => (q.get("IncludeItemTypes") === "Playlist" ? lists() : []),
      extra: [[/^\/Playlists\/p1\/Items/, { __status: 403 }]],
    });
    await mc.primePlaylists();
    await mc.addToPlaylistAction(song("s1")).submenu!.items()[1]!.run!();
    expect(lastToast()).toMatch(/Server error 403/);
  });

  it("New Playlist… suggests the album's name, nothing for a song, and still asks when the songs fail to load", async () => {
    await boot({}, { items: (q) => (q.get("ParentId") ? { __status: 500 } : []) });
    void mc.addToPlaylistAction(album("al1", { Name: "Blue" })).submenu!.items()[0]!.run!();
    await settle();
    expect(dialogEl()!.querySelector<HTMLInputElement>("input")!.value).toBe("Blue");
    await pickDialog("Cancel");
    void mc.addToPlaylistAction(song("s1")).submenu!.items()[0]!.run!();
    await settle();
    expect(dialogEl()!.querySelector<HTMLInputElement>("input")!.value).toBe("");
    await pickDialog("Cancel");
    void mc.addToPlaylistAction({ Id: "x", Type: "Playlist" }).submenu!.items()[0]!.run!();
    await settle();
    expect(dialogEl()!.querySelector<HTMLInputElement>("input")!.value).toBe("");
    await pickDialog("Cancel");
  });
});

describe("musicActions (the song menu)", () => {
  const labels = (acts: any[]) => acts.filter(Boolean).map((a) => a.label);

  it("offers a song everything, Go to Album and Artist, Download and Song Info", async () => {
    await boot();
    expect(labels(mc.musicActions(song("s1")))).toEqual([
      "Play", "Play Next", "Play Later", "Start Station", "Add to Playlist", "Add to Favorites",
      "Go to Album", "Go to Artist", "Download", "Song Info",
    ]);
  });

  it("adds Shuffle for a collection, and leaves out what a book or smart playlist can't do", async () => {
    await boot();
    expect(labels(mc.musicActions(album("al1")))).toEqual([
      "Play", "Shuffle", "Play Next", "Play Later", "Start Station", "Add to Playlist", "Add to Favorites", "Download Album",
    ]);
    expect(labels(mc.musicActions(book("b1")))).toEqual(["Play", "Play Next", "Play Later", "Add to Favorites", "Download"]);
    expect(labels(mc.musicActions({ Id: "sp", Type: "SmartPlaylist" }))).toEqual(["Play", "Shuffle", "Play Next", "Play Later", "Start Station"]);
  });

  it("leaves out Go to on the song's own pages, and adds Remove from Playlist on a playlist page", async () => {
    await boot();
    const onRemove = vi.fn();
    const acts = mc.musicActions(song("s1", { AlbumId: undefined, AlbumArtists: [], ArtistItems: [{ Name: "No id" }] }), { onRemove });
    expect(labels(acts)).not.toContain("Go to Album");
    expect(labels(acts)).not.toContain("Go to Artist");
    expect(labels(acts).at(-1)).toBe("Remove from Playlist");
    expect(acts.at(-1)!.danger).toBe(true);
    acts.at(-1)!.run!();
    expect(onRemove).toHaveBeenCalled();
    expect(labels(mc.musicActions(song("s1"), { hideGoTo: true }))).not.toContain("Go to Album");
  });

  it("runs Play, Shuffle, Play Next, Play Later and Start Station", async () => {
    await boot({}, { items: () => [song("t1")] });
    const acts = mc.musicActions(album("al1")).filter(Boolean) as any[];
    const run = async (l: string) => {
      await acts.find((a) => a.label === l).run();
      await flush();
    };
    await run("Play");
    await run("Shuffle");
    await run("Play Next");
    await run("Play Later");
    await run("Start Station");
    expect(played().map((c) => c[2].shuffle)).toEqual([undefined, true, undefined]);
    expect((audio.playNext as any).mock.calls[0][0].map((s: any) => s.Id)).toEqual(["t1"]);
    expect((audio.playLater as any).mock.calls[0][0].map((s: any) => s.Id)).toEqual(["t1"]);
  });

  it("reports a Play Next that fails", async () => {
    await boot();
    vi.mocked(audio.playNext).mockRejectedValueOnce(new Error("queue full"));
    await (mc.musicActions(song("s1"))[2] as any).run();
    await flush();
    expect(lastToast()).toBe("queue full");
  });

  it("stars and unstars on the server, updates the item and calls back", async () => {
    const calls: string[] = [];
    await boot({}, { extra: [[/^\/UserFavoriteItems\//, (a: JfArgs) => (calls.push(`${a.method} ${a.path}`), {})]] });
    const s = song("s1");
    const onChanged = vi.fn();
    await (mc.musicActions(s, { onChanged }).find((a) => a?.label === "Add to Favorites") as any).run();
    expect(s.UserData.IsFavorite).toBe(true);
    expect(lastToast()).toBe("Added to favorites");
    const un = mc.musicActions(s).find((a) => a?.label === "Remove from Favorites") as any;
    expect(un.icon).toBe("star");
    await un.run();
    expect(s.UserData.IsFavorite).toBe(false);
    expect(lastToast()).toBe("Removed from favorites");
    expect(calls).toEqual(["POST /UserFavoriteItems/s1?userId=user-1", "DELETE /UserFavoriteItems/s1?userId=user-1"]);
    expect(onChanged).toHaveBeenCalledTimes(1);
  });

  it("reports a favourite that didn't save, leaving the item as it was", async () => {
    await boot({}, { extra: [[/^\/UserFavoriteItems\//, { __status: 500 }]] });
    const s = song("s1", { UserData: undefined });
    await (mc.musicActions(s).find((a) => a?.label === "Add to Favorites") as any).run();
    expect(s.UserData).toBeUndefined();
    expect(lastToast()).toMatch(/Server error 500/);
  });

  it("goes to the album and the artist, and opens Song Info", async () => {
    await boot({}, { item: () => song("s1") });
    const acts = mc.musicActions(song("s1", { AlbumArtists: undefined })).filter(Boolean) as any[];
    acts.find((a) => a.label === "Go to Album").run();
    expect(location.hash).toBe("#/music/album/al1");
    acts.find((a) => a.label === "Go to Artist").run();
    expect(location.hash).toBe("#/music/artist/ar1");
    acts.find((a) => a.label === "Song Info").run();
    await settle();
    expect(dialogTitle()).toBe("Song Info");
  });

  it("queues the download through the shared queue", async () => {
    await boot({}, { extra: [[/^\/Items\?userId=user-1&Ids=/, { Items: [] }]] });
    await (mc.musicActions(song("s1")).find((a) => a?.label === "Download") as any).run();
    await settle();
    const playback = await import("../../src/playback");
    expect(playback.downloadSeason).toHaveBeenCalled();
  });
});

describe("showSongInfo", () => {
  it("lists what the server says about the file", async () => {
    const full = song("s1", {
      Name: "Long Song",
      Genres: ["Rock", "Blues"],
      ProductionYear: 1977,
      IndexNumber: 3,
      ParentIndexNumber: 2,
      RunTimeTicks: 3725 * 10_000_000,
      UserData: { PlayCount: 4, LastPlayedDate: "2026-01-02T03:04:05Z", IsFavorite: true },
      DateCreated: "2025-05-06T00:00:00Z",
      Path: "/music/long.flac",
      MediaSources: [{ Container: "flac", Size: 50_000_000, MediaStreams: [{ Type: "Audio", Codec: "flac", BitRate: 1_000_000, SampleRate: 44100, BitDepth: 16, Channels: 2 }] }],
    });
    await boot({}, { item: () => full });
    await mc.showSongInfo(song("s1"));
    expect(dialogEl()!.classList.contains("wide")).toBe(true);
    const dts = texts(dialogEl()!, "dt");
    const dds = texts(dialogEl()!, "dd");
    const info = Object.fromEntries(dts.map((k, i) => [k, dds[i]]));
    expect(info).toMatchObject({
      Title: "Long Song",
      Artist: "The Band",
      Album: "The Album",
      "Album artist": "The Band",
      Genre: "Rock, Blues",
      Year: "1977",
      Track: "3 (disc 2)",
      Length: "1:02:05",
      Plays: "4",
      Favorite: "Yes",
      Format: "FLAC · FLAC",
      Bitrate: "1000 kbps",
      "Sample rate": "44.1 kHz · 16-bit",
      Channels: "Stereo",
      File: "/music/long.flac",
    });
    expect(info["Last played"]).toBeTruthy();
    expect(info.Size).toBeTruthy();
    expect(info.Added).toBeTruthy();
    expect(dialogEl()!.querySelector(".mu-info-missing")).toBeNull();
    expect(dialogButtons()).toEqual(["Done"]);
  });

  it("says which station fields are missing, and makes do with the list's copy when the item won't load", async () => {
    await boot({}, { item: () => ({ __status: 500 }) });
    await mc.showSongInfo({ Id: "s9", Type: "Audio", Name: "Bare", Genres: [], MediaSources: [{ Bitrate: 320_000, Path: "/x.mp3", MediaStreams: [{ Type: "Audio", Channels: 1 }] }] });
    expect(dialogEl()!.querySelector(".mu-info-missing")!.textContent).toBe(
      "Missing artist, genre, year — stations can't place this song by those."
    );
    const info = Object.fromEntries(texts(dialogEl()!, "dt").map((k, i) => [k, texts(dialogEl()!, "dd")[i]]));
    expect(info).toMatchObject({ Title: "Bare", Plays: "0", Favorite: "No", Bitrate: "320 kbps", Channels: "Mono", File: "/x.mp3" });
    expect(info.Track).toBeUndefined();
    expect(info.Length).toBeUndefined();
  });

  it("uses the singular for one missing field and shows other channel counts as numbers", async () => {
    await boot({}, { item: () => song("s1", { ProductionYear: undefined, MediaSources: [{ MediaStreams: [{ Type: "Audio", Channels: 6, SampleRate: 48000 }] }] }) });
    await mc.showSongInfo(song("s1"));
    expect(dialogEl()!.querySelector(".mu-info-missing")!.textContent).toMatch(/Missing year — .* by that\./);
    const info = Object.fromEntries(texts(dialogEl()!, "dt").map((k, i) => [k, texts(dialogEl()!, "dd")[i]]));
    expect(info.Channels).toBe("6");
    expect(info["Sample rate"]).toBe("48.0 kHz");
    expect(info.Track).toBe("1");
  });
});

describe("musicCard", () => {
  it("draws an album with its artist and year, opens it on click, Enter and Space", async () => {
    await boot();
    const card = mc.musicCard(album("al1"));
    root.append(card);
    expect(card.querySelector(".mu-card-title")!.textContent).toBe("Album al1");
    expect(card.querySelector(".mu-card-sub")!.textContent).toBe("The Band · 2001");
    expect(card.getAttribute("aria-label")).toBe("Album al1 — The Band · 2001");
    expect(card.querySelector("img.art")!.getAttribute("src")).toMatch(/\/Items\/al1\/Images\/Primary\?maxWidth=360/);
    click(card);
    expect(location.hash).toBe("#/music/album/al1");
    location.hash = "";
    expect(key(card, "Enter").defaultPrevented).toBe(true);
    expect(location.hash).toBe("#/music/album/al1");
    location.hash = "";
    key(card, " ");
    expect(location.hash).toBe("#/music/album/al1");
    location.hash = "";
    // A key on a button inside the card is that button's.
    key(card.querySelector(".mu-cover-play"), "Enter");
    key(card, "x");
    expect(location.hash).toBe("");
  });

  it("plays from the cover button without opening the album", async () => {
    await boot({}, { items: () => [song("t1")] });
    const card = mc.musicCard(album("al1"));
    root.append(card);
    location.hash = "";
    const btn = card.querySelector(".mu-cover-play")!;
    expect(btn.getAttribute("aria-label")).toBe("Play Album al1");
    click(btn);
    await settle();
    expect(audio.play).toHaveBeenCalled();
    expect(location.hash).toBe("");
  });

  it("draws an artist round, with a letter tile and no play button, and a genre with no menu", async () => {
    await boot();
    const a = mc.musicCard(artist("ar1", { Name: "zed" }));
    expect(a.classList.contains("artist")).toBe(true);
    expect(a.querySelector(".mu-cover.round")).not.toBeNull();
    expect(a.querySelector(".mu-cover-play")).toBeNull();
    expect(a.querySelector(".noart")!.textContent).toBe("Z");
    expect(a.querySelector(".mu-card-sub")).toBeNull();
    expect(a.getAttribute("aria-label")).toBe("zed");
    const g = mc.musicCard({ Id: "g1", Type: "MusicGenre", Name: "Jazz" });
    expect(g.querySelector(".mu-cover-play")).toBeNull();
    expect(g.classList.contains("has-ctx")).toBe(false);
    expect(a.classList.contains("has-ctx")).toBe(true);
  });

  it("counts a playlist's songs, names a book's author, and draws an icon where there is no art", async () => {
    await boot();
    expect(mc.musicCard(playlist("p1", { ChildCount: 1 })).querySelector(".mu-card-sub")!.textContent).toBe("1 song");
    expect(mc.musicCard(playlist("p1", { ChildCount: 7 })).querySelector(".mu-card-sub")!.textContent).toBe("7 songs");
    expect(mc.musicCard(playlist("p1", { ChildCount: undefined })).querySelector(".mu-card-sub")!.textContent).toBe("Playlist");
    const b = mc.musicCard(book("b1"));
    expect(b.querySelector(".mu-card-sub")!.textContent).toBe("Ann Author");
    expect(b.querySelector(".noart svg")).not.toBeNull();
    const nameless = mc.musicCard({ Id: "u", Type: "Audio" });
    expect(nameless.querySelector(".mu-card-title")!.textContent).toBe("");
    location.hash = "";
    click(nameless);
    expect(location.hash).toBe("");
  });

  it("takes a caller's subtitle and open handler, and opens the song menu on right-click", async () => {
    await boot();
    const onOpen = vi.fn();
    const card = mc.musicCard(album("al1"), { sub: "Custom", onOpen });
    root.append(card);
    expect(card.querySelector(".mu-card-sub")!.textContent).toBe("Custom");
    click(card);
    expect(onOpen).toHaveBeenCalled();
    rightClick(card);
    expect(menuTitle()).toBe("Album al1");
    expect(menuLabels()).toContain("Shuffle");
  });
});

describe("shelf, grid, pageHeader, link", () => {
  it("draws nothing for an empty shelf, and a titled row with See all and a subtitle otherwise", async () => {
    await boot();
    expect(mc.shelf("Empty", [])).toBeNull();
    const seeAll = vi.fn();
    const s = mc.shelf("Albums", [document.createElement("div")], seeAll, "A note")!;
    expect(s.querySelector("h2")!.textContent).toBe("Albums");
    expect(s.querySelector(".mu-shelf-sub")!.textContent).toBe("A note");
    click(s.querySelector(".see-all"));
    expect(seeAll).toHaveBeenCalled();
    const plain = mc.shelf("Plain", [document.createElement("div")])!;
    expect(plain.querySelector(".see-all")).toBeNull();
    expect(plain.querySelector(".mu-shelf-sub")).toBeNull();
    expect(mc.grid([document.createElement("i")]).className).toBe("mu-grid");
  });

  it("puts the cover, eyebrow, title, the lines that have text, and the buttons in a page header", async () => {
    await boot();
    const h = mc.pageHeader({
      item: album("al1"),
      cover: "http://x/c.jpg",
      round: true,
      eyebrow: "Album",
      title: "Title",
      lines: ["one", null, document.createTextNode("two")],
      buttons: [document.createElement("button"), null],
    });
    expect(h.querySelector(".mu-head-cover.round img")!.getAttribute("src")).toBe("http://x/c.jpg");
    expect(h.querySelector(".mu-eyebrow")!.textContent).toBe("Album");
    expect(h.querySelector("h1.mu-title")!.textContent).toBe("Title");
    expect(texts(h, ".mu-head-line")).toEqual(["one", "two"]);
    expect(h.querySelectorAll(".mu-head-buttons button")).toHaveLength(1);
    const bare = mc.pageHeader({ title: "T" });
    expect(bare.querySelector(".mu-eyebrow")).toBeNull();
    expect(bare.querySelector(".noart")).not.toBeNull();
  });

  it("links text only when there is somewhere to go", async () => {
    await boot();
    expect(mc.link("Plain", null)).toBe("Plain");
    const a = mc.link("Go", "#/x") as HTMLAnchorElement;
    expect(a.getAttribute("href")).toBe("#/x");
    expect(a.className).toBe("mu-link");
  });
});

describe("playButtons", () => {
  it("plays, shuffles, starts a station and opens the menu without Go to", async () => {
    await boot({}, { items: () => [song("t1")] });
    const btns = mc.playButtons(song("s1"));
    root.append(...btns);
    expect(btns.map((b) => b.textContent!.trim())).toEqual(["Play", "Shuffle", "Station", ""]);
    click(btns[0]);
    click(btns[1]);
    await settle();
    expect(played().map((c) => c[2])).toEqual([{ title: "Song s1", shuffle: false }, { title: "Song s1", shuffle: true }]);
    click(btns[2]);
    await settle();
    expect(toasts()).toContain("Starting a mix from Song s1…");
    click(btns[3]);
    expect(menuTitle()).toBe("Song s1");
    expect(menuLabels()).not.toContain("Go to Album");
  });

  it("leaves out Station when asked, says when there's nothing to play, and reports a failure", async () => {
    await boot();
    let fail = false;
    const btns = mc.playButtons({ Id: "x", Type: "Playlist" }, { station: false, songs: async () => {
      if (fail) throw new Error("no list");
      return [];
    } });
    expect(btns).toHaveLength(3);
    click(btns[0]);
    await settle();
    expect(lastToast()).toBe("Nothing to play there");
    fail = true;
    click(btns[0]);
    await settle();
    expect(lastToast()).toBe("no list");
  });
});

describe("song rows", () => {
  it("shows the track number, title, favourite star and length; the play button and double-click play", async () => {
    await boot();
    const r = mc.songRow(song("s1", { IndexNumber: 4, UserData: { IsFavorite: true } }));
    root.append(r);
    expect(r.dataset.id).toBe("s1");
    expect(r.querySelector(".mu-song-num")!.textContent).toBe("4");
    expect(r.querySelector(".mu-song-title")!.textContent).toBe("Song s1★");
    expect(r.querySelector(".mu-song-sub")).toBeNull();
    expect(r.querySelector(".mu-song-time")!.textContent).toBe("3:20");
    click(r.querySelector(".mu-song-play"));
    dblclick(r);
    expect(played().map((c) => c[0].map((s: any) => s.Id))).toEqual([["s1"], ["s1"]]);
  });

  it("draws the cover or a rank in front, with the artist and album underneath", async () => {
    await boot();
    const a = mc.songRow(song("s1", { RunTimeTicks: 0 }), { lead: "art", showAlbum: true });
    expect(a.querySelector(".mu-song-art")).not.toBeNull();
    expect(a.querySelector(".mu-song-sub")!.textContent).toBe("The Band · The Album");
    expect(a.querySelector(".mu-song-time")!.textContent).toBe("");
    const r = mc.songRow(song("s2"), { lead: "rank", rank: 7, showArtist: false });
    expect(r.querySelector(".mu-song-num")!.textContent).toBe("7");
    expect(r.querySelector(".mu-song-sub")).toBeNull();
    expect(mc.songRow(song("s3", { IndexNumber: undefined })).querySelector(".mu-song-num")!.textContent).toBe("");
    expect(mc.songRow(song("s4"), { lead: "rank" }).querySelector(".mu-song-num")!.textContent).toBe("");
  });

  it("plays on Enter on the row only, and opens the menu from More", async () => {
    await boot();
    const onPlay = vi.fn();
    const r = mc.songRow(song("s1"), { onPlay });
    root.append(r);
    expect(key(r, "Enter").defaultPrevented).toBe(true);
    key(r.querySelector(".mu-song-play"), "Enter");
    key(r, "a");
    expect(onPlay).toHaveBeenCalledTimes(1);
    click(r.querySelector(".mu-song-more"));
    expect(menuTitle()).toBe("Song s1");
    expect(menuLabels()[0]).toBe("Play");
  });

  it("reports a play that fails", async () => {
    await boot();
    vi.mocked(audio.play).mockRejectedValueOnce(new Error("mpv gone"));
    const r = mc.songRow(song("s1"));
    root.append(r);
    dblclick(r);
    await flush();
    expect(lastToast()).toBe("mpv gone");
  });
});

describe("songList", () => {
  it("plays the list from the row played, under its title", async () => {
    await boot();
    const songs = [song("a"), song("b"), song("c")];
    const list = mc.songList(songs, { title: "Album" });
    root.append(list);
    dblclick(list.querySelectorAll(".mu-song")[1]!);
    expect(played()[0]![0]).toBe(songs);
    expect(played()[0]!.slice(1)).toEqual([1, { title: "Album" }]);
    expect(texts(list, ".mu-song-num")).toEqual(["1", "1", "1"]);
    mc.songList(songs, { lead: "rank" }).querySelectorAll(".mu-song").forEach((r, i) => {
      expect(r.querySelector(".mu-song-num")!.textContent).toBe(String(i + 1));
    });
    const untitled = mc.songList(songs);
    root.append(untitled);
    dblclick(untitled.querySelector(".mu-song"));
    expect(played()[1]![2]).toEqual({ title: "" });
  });

  it("reports a failed play from a list", async () => {
    await boot();
    vi.mocked(audio.play).mockRejectedValueOnce(new Error("nope"));
    const list = mc.songList([song("a")]);
    root.append(list);
    dblclick(list.querySelector(".mu-song"));
    await flush();
    expect(lastToast()).toBe("nope");
  });

  it("heads each disc of a multi-disc album, and not a single-disc one", async () => {
    await boot();
    const two = mc.songList([song("a", { ParentIndexNumber: 1 }), song("b", { ParentIndexNumber: 2 }), song("c")], { discs: true });
    expect(texts(two, ".mu-disc")).toEqual(["Disc 1", "Disc 2", "Disc 1"]);
    expect(mc.songList([song("a"), song("b")], { discs: true }).querySelector(".mu-disc")).toBeNull();
  });

  it("marks the row of the song that's playing, with a static class and no animation", async () => {
    await boot();
    const list = mc.songList([song("a"), song("b")]);
    root.append(list);
    expect(list.querySelector(".playing")).toBeNull();
    audio.__playing([song("b")]);
    mc.markPlaying(list);
    expect(Array.from(list.querySelectorAll(".mu-song.playing")).map((r) => (r as HTMLElement).dataset.id)).toEqual(["b"]);
    audio.__st.status.active = false;
    mc.markPlaying(list);
    expect(list.querySelector(".playing")).toBeNull();
    const { foreverAnimated } = await import("../helpers/views-media-music");
    expect(foreverAnimated(document)).toEqual([]);
  });
});

describe("selecting rows", () => {
  async function three() {
    await boot();
    const songs = [song("a"), song("b"), song("c")];
    const list = mc.songList(songs);
    root.append(list);
    const rows = () => Array.from(list.querySelectorAll<HTMLElement>(".mu-song"));
    const selected = () => rows().filter((r) => r.classList.contains("selected")).map((r) => r.dataset.id);
    return { list, rows, selected, songs };
  }

  it("selects one row on click, toggles with Ctrl, and extends a range with Shift", async () => {
    const { list, rows, selected } = await three();
    click(rows()[0]);
    expect(selected()).toEqual(["a"]);
    expect(list.querySelector(".mu-selbar")).toBeNull();
    click(rows()[2], { shiftKey: true });
    expect(selected()).toEqual(["a", "b", "c"]);
    expect(list.querySelector(".mu-selbar span")!.textContent).toBe("3 selected");
    click(rows()[1], { ctrlKey: true });
    expect(selected()).toEqual(["a", "c"]);
    click(rows()[0], { shiftKey: true });
    expect(selected()).toEqual(["a", "b"]);
    click(rows()[2]);
    expect(selected()).toEqual(["c"]);
    expect(list.querySelector(".mu-selbar")).toBeNull();
  });

  it("works the selection bar: Play, Play Next, Add to Playlist and Clear", async () => {
    const { list, rows, selected } = await three();
    click(rows()[0]);
    click(rows()[1], { metaKey: true });
    const bar = list.querySelector(".mu-selbar")!;
    const btn = (t: string) => Array.from(bar.querySelectorAll("button")).find((b) => b.textContent === t)!;
    click(btn("Play"));
    click(btn("Play Next"));
    expect(played()[0]![0].map((s: any) => s.Id)).toEqual(["a", "b"]);
    expect((audio.playNext as any).mock.calls[0][0].map((s: any) => s.Id)).toEqual(["a", "b"]);
    click(btn("Add to Playlist"));
    expect(menuLabels()).toEqual(["Add to Playlist"]);
    click(btn("Clear"));
    expect(selected()).toEqual([]);
    expect(list.querySelector(".mu-selbar")).toBeNull();
  });

  it("New Playlist… from the bar makes a playlist of the selection", async () => {
    let body: any;
    const { list, rows } = await three();
    musicServer({ extra: [[/^\/Playlists$/, (a: JfArgs) => ((body = a.body), { Id: "n" })]] });
    click(rows()[0]);
    click(rows()[2], { ctrlKey: true });
    click(Array.from(list.querySelectorAll(".mu-selbar button")).find((b) => b.textContent === "New Playlist…"));
    await settle();
    dialogEl()!.querySelector<HTMLInputElement>("input")!.value = "Two";
    await pickDialog("Create");
    expect(body.Ids).toEqual(["a", "c"]);
  });

  it("right-clicking a selected row offers the selection's menu, and adds them all to a playlist", async () => {
    const added: string[] = [];
    const { rows } = await three();
    musicServer({
      items: () => [playlist("p1", { Name: "Road" })],
      extra: [[/^\/Playlists\/p1\/Items/, (a: JfArgs) => (added.push(a.path), null)]],
    });
    await mc.primePlaylists(true);
    click(rows()[0]);
    click(rows()[1], { ctrlKey: true });
    rightClick(rows()[0]);
    expect(menuLabels()).toEqual(["Play 2 Songs", "Play Next", "Play Later", "Add to Playlist"]);
    await pickMenu("Play Later");
    expect((audio.playLater as any).mock.calls[0][0].map((s: any) => s.Id)).toEqual(["a", "b"]);
    rightClick(rows()[0]);
    await pickMenu("Play 2 Songs");
    expect(played()[0]![0].map((s: any) => s.Id)).toEqual(["a", "b"]);
    rightClick(rows()[1]);
    await pickMenu("Play Next");
    rightClick(rows()[1]);
    await pickMenu("Add to Playlist");
    expect(menuLabels()).toEqual(["New Playlist…", "Road"]);
    await pickMenu("Road");
    await settle();
    expect(added).toEqual(["/Playlists/p1/Items?ids=a,b&userId=user-1"]);
    expect(lastToast()).toBe("Added 2 songs to “Road”");
    // An unselected row still gets its own song's menu.
    rightClick(rows()[2]);
    expect(menuTitle()).toBe("Song c");
    expect(menuLabels()[0]).toBe("Play");
  });

  it("reports a selection add that fails, and offers New Playlist… for the selection", async () => {
    const { rows } = await three();
    musicServer({ items: () => [playlist("p1", { Name: "Road" })], extra: [[/^\/Playlists\/p1\/Items/, { __status: 500 }]] });
    await mc.primePlaylists(true);
    click(rows()[0]);
    click(rows()[1], { shiftKey: true });
    rightClick(rows()[1]);
    await pickMenu("Add to Playlist");
    await pickMenu("Road");
    await settle();
    expect(lastToast()).toMatch(/Server error 500/);
    rightClick(rows()[1]);
    await pickMenu("Add to Playlist");
    await pickMenu("New Playlist…");
    await settle();
    expect(dialogTitle()).toBe("New Playlist");
    await pickDialog("Cancel");
  });

  it("a row outside a list selects alone and grows no selection bar", async () => {
    await boot();
    const r = mc.songRow(song("solo"));
    root.append(r);
    click(r);
    expect(r.classList.contains("selected")).toBe(true);
    expect(document.querySelector(".mu-selbar")).toBeNull();
    rightClick(r);
    expect(menuTitle()).toBe("Song solo");
    expect(openMenuEl()).not.toBeNull();
  });
});
