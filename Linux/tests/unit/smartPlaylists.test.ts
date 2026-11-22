// src/smartPlaylists.ts: rule-based playlists kept in config.json and answered
// from the library each time they are opened.
import { beforeEach, describe, expect, it, vi } from "vitest";
import { invokeCalls, jfPaths, mockJellyfin, signIn } from "../helpers/tauri";

type S = typeof import("../../src/smartPlaylists");
let sp: S;

beforeEach(async () => {
  vi.resetModules();
  sp = await import("../../src/smartPlaylists");
});

const NOW = Date.UTC(2026, 10, 12, 12, 0, 0);
const DAY = 86_400_000;

function rule(over: Partial<import("../../src/smartPlaylists").SmartPlaylist> = {}) {
  return { ...sp.blankSmartPlaylist(), id: "smart-1", name: "Mine", ...over };
}

function query(): URLSearchParams {
  const p = jfPaths().at(-1)!;
  return new URL(`http://x${p}`).searchParams;
}

describe("blankSmartPlaylist", () => {
  it("is 'any song, random, up to 100' with a fresh smart- id", () => {
    const a = sp.blankSmartPlaylist();
    const b = sp.blankSmartPlaylist();
    expect(a).toMatchObject({
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
    });
    expect(a.id).toMatch(/^smart-[0-9a-z]+$/);
    expect(a.id).not.toBe(b.id);
  });
});

describe("stored in config.json under music_smart_playlists", () => {
  it("answers none when the key is missing or not a list", async () => {
    expect(sp.getSmartPlaylists()).toEqual([]); // no config at all yet
    await signIn({});
    expect(sp.getSmartPlaylists()).toEqual([]);
    await signIn({ music_smart_playlists: { not: "a list" } });
    expect(sp.getSmartPlaylists()).toEqual([]);
  });

  it("drops entries with no string id and fills missing fields from the blank rule (older configs)", async () => {
    await signIn({ music_smart_playlists: [null, { name: "no id" }, { id: 4 }, { id: "smart-x", name: "Old", genres: ["Jazz"] }] });
    const all = sp.getSmartPlaylists();
    expect(all).toHaveLength(1);
    expect(all[0]).toMatchObject({ id: "smart-x", name: "Old", genres: ["Jazz"], limit: 100, order: "random", played: "any" });
  });

  it("saveSmartPlaylist adds a new one and replaces one with the same id", async () => {
    await signIn({ music_smart_playlists: [] });
    await sp.saveSmartPlaylist(rule({ id: "a", name: "A" }));
    await sp.saveSmartPlaylist(rule({ id: "b", name: "B" }));
    await sp.saveSmartPlaylist(rule({ id: "a", name: "A2" }));
    expect(sp.getSmartPlaylists().map((p) => `${p.id}:${p.name}`)).toEqual(["a:A2", "b:B"]);
    // Only the one key is sent; the backend merges.
    expect(Object.keys(invokeCalls("config_save").at(-1)!.args.cfg)).toEqual(["music_smart_playlists"]);
  });

  it("deleteSmartPlaylist removes by id and leaves the rest", async () => {
    await signIn({ music_smart_playlists: [rule({ id: "a" }), rule({ id: "b" })] });
    await sp.deleteSmartPlaylist("a");
    expect(sp.getSmartPlaylists().map((p) => p.id)).toEqual(["b"]);
    await sp.deleteSmartPlaylist("nope");
    expect(sp.getSmartPlaylists().map((p) => p.id)).toEqual(["b"]);
  });
});

describe("asItem", () => {
  it("is a card-shaped item of type SmartPlaylist with no art", () => {
    expect(sp.asItem(rule({ id: "s", name: "N" }))).toEqual({ Id: "s", Name: "N", Type: "SmartPlaylist", ImageTags: {} });
  });
});

describe("describe", () => {
  it("an empty rule is 'Any song'", () => {
    expect(sp.describe(rule())).toBe("Any song · Random · up to 100");
  });

  it("says every rule in order", () => {
    const text = sp.describe(
      rule({
        genres: ["Rock", "Blues"],
        artists: [{ id: "1", name: "A" }, { id: "2", name: "B" }],
        yearFrom: 1970,
        yearTo: 1979,
        addedWithinDays: 30,
        played: "played",
        minPlays: 3,
        favoritesOnly: true,
        order: "added",
        limit: 50,
      })
    );
    expect(text).toBe(
      "Rock or Blues, by A or B, 1970–1979, added in the last 30 days, played before, played 3+ times, favorites only · Recently added · up to 50"
    );
  });

  it.each([
    [{ yearFrom: 1990 }, "from 1990"],
    [{ yearTo: 2000 }, "up to 2000"],
    [{ played: "unplayed" as const }, "never played"],
  ])("%j says %j", (over, phrase) => {
    expect(sp.describe(rule(over))).toContain(phrase);
  });

  it("an unknown order reads as Random", () => {
    expect(sp.describe(rule({ order: "bogus" as any }))).toBe("Any song · Random · up to 100");
  });
});

describe("smartPlaylistSongs", () => {
  beforeEach(() => {
    vi.useFakeTimers({ toFake: ["Date"] });
    vi.setSystemTime(NOW);
  });

  it("asks the server for audio with the rule's server-side filters", async () => {
    await signIn();
    mockJellyfin([["/Items", { Items: [{ Id: "1" }] }]]);
    const songs = await sp.smartPlaylistSongs(
      rule({ genres: ["Rock"], artists: [{ id: "ar", name: "A" }], favoritesOnly: true, order: "plays", limit: 30 })
    );
    expect(songs).toEqual([{ Id: "1" }]);
    const q = query();
    expect(q.get("IncludeItemTypes")).toBe("Audio");
    expect(q.get("Genres")).toBe("Rock");
    expect(q.get("ArtistIds")).toBe("ar");
    expect(q.get("Filters")).toBe("IsFavorite");
    expect(q.get("SortBy")).toBe("PlayCount,SortName");
    expect(q.get("Limit")).toBe("30");
    expect(q.get("Fields")).toBe(`${(await import("../../src/musicApi")).MUSIC_FIELDS},DateCreated`);
    expect(q.has("Years")).toBe(false);
  });

  it.each([
    ["played", "IsPlayed"],
    ["unplayed", "IsUnplayed"],
  ] as const)("played: %s filters on the server with %s", async (played, filter) => {
    await signIn();
    mockJellyfin([["/Items", { Items: [] }]]);
    await sp.smartPlaylistSongs(rule({ played }));
    expect(query().get("Filters")).toBe(filter);
  });

  it("turns a year range into the list of years, either way round", async () => {
    await signIn();
    mockJellyfin([["/Items", { Items: [] }]]);
    await sp.smartPlaylistSongs(rule({ yearFrom: 1999, yearTo: 1997 }));
    expect(query().get("Years")).toBe("1997,1998,1999");
  });

  it("an open-ended range runs from 1900 or to this year, capped at 200 years", async () => {
    await signIn();
    mockJellyfin([["/Items", { Items: [] }]]);
    await sp.smartPlaylistSongs(rule({ yearFrom: 2024 }));
    expect(query().get("Years")).toBe("2024,2025,2026");
    await sp.smartPlaylistSongs(rule({ yearTo: 1902 }));
    expect(query().get("Years")).toBe("1900,1901,1902");
    await sp.smartPlaylistSongs(rule({ yearFrom: 1500, yearTo: 2026 }));
    const years = query().get("Years")!.split(",");
    expect(years).toHaveLength(200);
    expect(years[0]).toBe("1500");
  });

  it("filters 'added in the last N days' here, from a larger draw", async () => {
    await signIn();
    mockJellyfin([
      [
        "/Items",
        {
          Items: [
            { Id: "new", DateCreated: new Date(NOW - 2 * DAY).toISOString() },
            { Id: "old", DateCreated: new Date(NOW - 40 * DAY).toISOString() },
            { Id: "undated" },
          ],
        },
      ],
    ]);
    const songs = await sp.smartPlaylistSongs(rule({ addedWithinDays: 30, limit: 10 }));
    expect(songs.map((s) => s.Id)).toEqual(["new"]);
    expect(query().get("Limit")).toBe("80"); // limit x 8
  });

  it("a play-count floor asks for played songs and filters the count here", async () => {
    await signIn();
    mockJellyfin([
      ["/Items", { Items: [{ Id: "a", UserData: { PlayCount: 5 } }, { Id: "b", UserData: { PlayCount: 1 } }, { Id: "c" }] }],
    ]);
    const songs = await sp.smartPlaylistSongs(rule({ minPlays: 3 }));
    expect(songs.map((s) => s.Id)).toEqual(["a"]);
    expect(query().get("Filters")).toBe("IsPlayed");
  });

  it("the larger draw is capped at 5000, and the answer is cut to the rule's limit", async () => {
    await signIn();
    mockJellyfin([["/Items", { Items: Array.from({ length: 12 }, (_, i) => ({ Id: `s${i}`, UserData: { PlayCount: 9 } })) }]]);
    const songs = await sp.smartPlaylistSongs(rule({ minPlays: 1, limit: 1000 }));
    expect(query().get("Limit")).toBe("5000");
    expect(songs).toHaveLength(12);
    const few = await sp.smartPlaylistSongs(rule({ minPlays: 1, limit: 5 }));
    expect(few).toHaveLength(5);
  });
});
