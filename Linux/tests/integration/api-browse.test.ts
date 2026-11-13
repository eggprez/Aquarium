// api.ts against the live QA server: reading. Views, library paging and
// filters, item detail fields, seasons and episodes, search, Continue
// Watching and Next Up as read, the home layout, Latest, favourites, batches
// by id, trickplay, media segments, Live TV, images, the public calls made
// before sign-in, and how a real 401 and 404 come back.
//
// Read-only for the account, apart from one Quick Connect code approved by
// it (the code is never redeemed, and the server forgets it in ten minutes).
//
// Expectations come from fixtures.json (FIXTURES.md says what each fixture
// is for) or from asking the server directly, never from hard-coded ids.
import { beforeEach, describe, expect, it, onTestFinished, vi } from "vitest";
import { qa, qaWritable } from "../helpers/qa";
import {
  authHeader,
  bridgeCalls,
  expectCleanBridgeCalls,
  fx,
  fxEpisodes,
  fxLibrary,
  qaApiFull,
} from "../helpers/api-qa";
import { onInvoke } from "../helpers/tauri";

const SEC = 10_000_000;

beforeEach(() => {
  vi.resetModules();
});

/** A raw read with the suite's token, for comparing against what api.ts did. */
async function raw(path: string): Promise<any> {
  const r = await qa!.request(path);
  expect(r.status, path).toBe(200);
  return r.body;
}

/**
 * Two reads of the account's state that should agree, read again (up to five
 * times) until they do. Other suites, and this suite's own write tests in a
 * parallel worker, change the same account between the two reads; a real
 * disagreement survives every try.
 */
async function agreed<T>(read: () => Promise<[T, T]>): Promise<[T, T]> {
  let pair = await read();
  for (let i = 0; i < 4 && JSON.stringify(pair[0]) !== JSON.stringify(pair[1]); i++) pair = await read();
  return pair;
}

describe.skipIf(!qa)("QA server: api.ts browsing", () => {
  it("lists the account's libraries by userId= and sends no credential of its own (Linux/CLAUDE.md invariant)", async () => {
    const api = await qaApiFull();
    const views = await api.getViews();
    const names = views.map((v) => v.Name);
    for (const lib of ["Fixture Films", "Fixture Shows", "Fixture Music", "Movies", "Shows"]) expect(names).toContain(lib);
    expect(views.find((v) => v.Name === "Fixture Films")!.Id).toBe(fxLibrary("Fixture Films"));
    expect(bridgeCalls()[0]!.path).toBe(`/UserViews?userId=${qa!.userId}`);
    expectCleanBridgeCalls();
  });

  it("is right not to send X-Emby-Token: Jellyfin 12 answers it 401, and the MediaBrowser header 200", async () => {
    const legacy = await fetch(`${qa!.server}/UserViews?userId=${qa!.userId}`, { headers: { "X-Emby-Token": qa!.token } });
    expect(legacy.status).toBe(401);
    const current = await fetch(`${qa!.server}/UserViews?userId=${qa!.userId}`, { headers: { Authorization: authHeader() } });
    expect(current.status).toBe(200);
  });

  it("pages a library: pages are disjoint, in sort order, and agree on the total", async () => {
    const api = await qaApiFull();
    const lib = fxLibrary("Fixture Films");
    // As the library page asks for a films library (views/library.ts).
    const all = await api.getLibraryItems(lib, { limit: 200, includeTypes: "Movie" });
    const films = Object.keys(qa!.fixtures.fixtures).filter((k) => k.startsWith("film."));
    expect(all.TotalRecordCount).toBe(films.length);
    expect(all.Items.map((i) => i.Name)).toEqual(expect.arrayContaining(films.map((k) => fx(k).name)));
    const p1 = await api.getLibraryItems(lib, { limit: 5, includeTypes: "Movie" });
    const p2 = await api.getLibraryItems(lib, { startIndex: 5, limit: 5, includeTypes: "Movie" });
    expect(p1.TotalRecordCount).toBe(all.TotalRecordCount);
    expect(p2.TotalRecordCount).toBe(all.TotalRecordCount);
    expect([...p1.Items, ...p2.Items].map((i) => i.Id)).toEqual(all.Items.slice(0, 10).map((i) => i.Id));
    // The grid fields came back with every item.
    for (const i of p1.Items) {
      expect(i.UserData, i.Name).toBeDefined();
      expect(i.RunTimeTicks, i.Name).toBeGreaterThan(0);
      expect(i.MediaSources, i.Name).toBeDefined();
    }
    const desc = await api.getLibraryItems(lib, { limit: 200, includeTypes: "Movie", sortOrder: "Descending" });
    expect(desc.Items.map((i) => i.Id)).toEqual([...all.Items].reverse().map((i) => i.Id));
    expectCleanBridgeCalls();
  });

  it("filters a library by unwatched, favourite and genre the way the server counts them", async () => {
    const api = await qaApiFull();
    const lib = fxLibrary("Fixture Films");
    const [unwatched, unplayed] = await agreed(async () => {
      const all = (await api.getLibraryItems(lib, { limit: 200 })).Items;
      const u = await api.getLibraryItems(lib, { limit: 200, unwatched: true });
      expect(u.Items.every((i) => !i.UserData?.Played)).toBe(true);
      return [u.Items.map((i) => i.Id).sort(), all.filter((i) => !i.UserData?.Played).map((i) => i.Id).sort()];
    });
    expect(unwatched).toEqual(unplayed);
    const [favs, starred] = await agreed(async () => {
      const all = (await api.getLibraryItems(lib, { limit: 200 })).Items;
      const f = await api.getLibraryItems(lib, { limit: 200, favorites: true });
      return [f.Items.map((i) => i.Id).sort(), all.filter((i) => i.UserData?.IsFavorite).map((i) => i.Id).sort()];
    });
    expect(favs).toEqual(starred);
    const ratings = await api.getLibraryItems(lib, { limit: 200, genre: "Ratings" });
    expect(ratings.Items.map((i) => i.Name)).toEqual(
      expect.arrayContaining(["FX Rated G", "FX Rated PG-13", "FX Rated R", "FX Rated NC-17", "FX Unrated"])
    );
    expect(ratings.Items.every((i) => i.Genres.includes("Ratings"))).toBe(true);
    // Only the type asked for, when one is.
    const shows = await api.getLibraryItems(fxLibrary("Fixture Shows"), { includeTypes: "Series" });
    expect(shows.Items.map((i) => i.Name).sort()).toEqual([fx("show.long").name, fx("show.short").name].sort());
  });

  it("keeps songs, books and photos out of a library listing by default", async () => {
    const api = await qaApiFull();
    const photos = await api.getLibraryItems(fxLibrary("Fixture Photos"), { limit: 200 });
    expect(photos.Items.every((i) => api.isVideoItem(i))).toBe(true);
    expect(photos.Items.map((i) => i.Name)).toContain("FX Home Clip");
  });

  it("lists a library's genres, sorted", async () => {
    const api = await qaApiFull();
    const genres = await api.getGenres(fxLibrary("Fixture Films"), "Movie");
    expect(genres).toEqual(expect.arrayContaining(["Test Pattern", "Long Form", "Languages", "Ratings", "Subtitles"]));
    expect(genres).toEqual([...genres].sort((a, b) => a.localeCompare(b)));
  });

  it("reads a film's detail fields: people, studios, taglines, media sources", async () => {
    const api = await qaApiFull();
    const f = fx("film.long_direct");
    const item = await api.getItem(f.id);
    expect(item.Name).toBe(f.name);
    expect(item.ProductionYear).toBe(f.year);
    expect(item.OfficialRating).toBe(f.officialRating);
    expect(item.Genres).toEqual(expect.arrayContaining(f.genres));
    expect(item.Studios.map((s: any) => s.Name)).toEqual(f.studios);
    expect(item.Taglines).toEqual(f.taglines);
    expect(item.People.map((p: any) => p.Name)).toEqual(expect.arrayContaining(f.people.map((p: any) => p.name)));
    expect(Math.round(item.RunTimeTicks / SEC)).toBe(Math.round(f.durationSeconds));
    expect(item.MediaSources[0].Size).toBe(f.mediaSources[0].sizeBytes);
    const summary = api.mediaSummary(item);
    expect(summary).toEqual(expect.arrayContaining(["H264", "AAC", api.bytesToText(f.mediaSources[0].sizeBytes)]));
    expect(api.estimateDownloadSize(item, api.DOWNLOAD_QUALITIES[0]!)).toBe(f.mediaSources[0].sizeBytes);
  });

  it("counts the subtitle tracks of a many-track file", async () => {
    const api = await qaApiFull();
    const item = await api.getItem(fx("film.long_multitrack").id);
    const summary = api.mediaSummary(item);
    expect(summary.slice(0, 3)).toEqual(["720p", "H264", "AAC"]);
    expect(summary).toContain("9 subtitle tracks");
  });

  it("names a stereo track 'Stereo', as the server's own layout name comes lower-case", async () => {
    const api = await qaApiFull();
    const item = await api.getItem(fx("film.long_multitrack").id);
    expect(item.MediaSources[0].MediaStreams.find((s: any) => s.Type === "Audio").ChannelLayout).toBe("stereo");
    expect(api.mediaSummary(item)).toContain("Stereo");
  });

  it("answers More Like This with video only", async () => {
    const api = await qaApiFull();
    const similar = await api.getSimilar(fx("film.long_direct").id);
    expect(Array.isArray(similar)).toBe(true);
    expect(similar.every((i) => api.isVideoItem(i))).toBe(true);
  });

  it("lists a show's seasons, specials first, and a season's episodes in order", async () => {
    const api = await qaApiFull();
    const show = fx("show.long");
    const seasons = await api.getSeasons(show.id);
    expect(seasons.map((s) => s.Name)).toEqual(show.seasons.map((s: any) => s.name));
    const s1 = show.seasons.find((s: any) => s.index === 1);
    const eps = await api.getEpisodes(show.id, s1.id);
    expect(eps.map((e) => e.Name)).toEqual(s1.episodes.map((e: any) => e.name));
    expect(eps.every((e) => e.SeriesId === show.id && e.UserData)).toBe(true);
  });

  it("keeps a double episode as one item, and has no invented E07", async () => {
    const api = await qaApiFull();
    const show = fx("show.short");
    const s1 = show.seasons.find((s: any) => s.index === 1);
    const eps = await api.getEpisodes(show.id, s1.id);
    expect(eps.map((e) => e.IndexNumber)).toEqual([1, 2, 3, 4, 5, 8]);
    expect(eps.find((e) => e.IndexNumber === 5)!.IndexNumberEnd).toBe(6);
  });

  it("finds titles by search, films and shows and episodes only, and pages them", async () => {
    const api = await qaApiFull();
    const r = await api.search("FX Long");
    const names = r.Items.map((i) => i.Name);
    expect(names).toEqual(expect.arrayContaining(["FX Long Direct Play", "FX Long Remux Multitrack", "FX Long Show"]));
    // FX Long Tracks is an album: not this search's business.
    expect(names).not.toContain("FX Long Tracks");
    expect(r.Items.every((i) => ["Movie", "Series", "Episode"].includes(i.Type))).toBe(true);
    const page = await api.search("FX Long", { startIndex: 1, limit: 1 });
    expect(page.Items).toHaveLength(1);
    expect(page.Items[0]!.Id).toBe(r.Items[1]!.Id);
    const uni = await api.search("Unicode");
    expect(uni.Items.map((i) => i.Name)).toContain(fx("film.unicode_title").name);
    expect((await api.search("zzz-no-such-title-zzz")).Items).toEqual([]);
  });

  it("reads Continue Watching as the server has it, video only", async () => {
    const api = await qaApiFull();
    let resume: any[] = [];
    const [ours, theirs] = await agreed(async () => {
      resume = await api.getResume();
      const server = await raw(`/UserItems/Resume?userId=${qa!.userId}&Limit=16&MediaTypes=Video`);
      return [resume.map((i) => i.Id), server.Items.map((i: any) => i.Id)];
    });
    expect(ours).toEqual(theirs);
    for (const i of resume) {
      expect(i.MediaType, i.Name).toBe("Video");
      expect(i.UserData.PlaybackPositionTicks, i.Name).toBeGreaterThan(0);
    }
    // The audiobook in progress is the music side's.
    expect(resume.map((i) => i.Type)).not.toContain("AudioBook");
  });

  it("reads Next Up in the server's order when nothing was started over", async () => {
    const api = await qaApiFull();
    let row: any[] = [];
    const [ours, theirs] = await agreed(async () => {
      row = await api.getNextUp();
      const server = await raw(`/Shows/NextUp?userId=${qa!.userId}&Limit=100&enableResumable=true&enableRewatching=false`);
      return [row.map((i) => i.Id), api.newStartsFirst(server.Items).slice(0, 16).map((i: any) => i.Id)];
    });
    expect(ours).toEqual(theirs);
    expect(row.every((i) => i.Type === "Episode")).toBe(true);
  });

  it("offers a series' next episode the way the server's Next Up does", async () => {
    const api = await qaApiFull();
    for (const key of ["show.long", "show.short"]) {
      const show = fx(key);
      const [ours, theirs] = await agreed(async () => [
        (await api.getSeriesNextUp(show.id))?.Id ?? null,
        (await raw(`/Shows/NextUp?userId=${qa!.userId}&seriesId=${show.id}&Limit=1`)).Items[0]?.Id ?? null,
      ]);
      expect(ours, key).toBe(theirs);
    }
  });

  it("agrees with the server about which episode Next Up offers (nextUpTarget)", async () => {
    const api = await qaApiFull();
    const show = fx("show.short");
    const [ours, theirs] = await agreed(async () => [
      api.nextUpTarget((await raw(`/Shows/${show.id}/Episodes?userId=${qa!.userId}`)).Items)?.Id ?? null,
      (await raw(`/Shows/NextUp?userId=${qa!.userId}&seriesId=${show.id}&Limit=1&enableResumable=true`)).Items[0]?.Id ?? null,
    ]);
    expect(ours).toBe(theirs);
  });

  it("reads the home layout from the account's display preferences", async () => {
    const api = await qaApiFull();
    const sections = await api.getHomeSections();
    const prefs = await raw(`/DisplayPreferences/usersettings?userId=${qa!.userId}&client=emby`);
    const custom = Object.keys(prefs?.CustomPrefs ?? {}).filter((k) => /^homesection\d$/i.test(k));
    if (!custom.length) expect(sections).toEqual(api.HOME_FALLBACK);
    expect(sections.length).toBeGreaterThan(0);
    expect(new Set(sections).size).toBe(sections.length);
  });

  it("folds new episodes into their series on a Latest row", async () => {
    const api = await qaApiFull();
    const shows = await api.getLatest(fxLibrary("Fixture Shows"));
    expect(shows.length).toBeGreaterThan(0);
    expect(shows.every((i) => i.Type === "Series")).toBe(true);
    expect(new Set(shows.map((i) => i.Id)).size).toBe(shows.length);
    const films = await api.getLatest(fxLibrary("Fixture Films"), 5);
    expect(films.length).toBeGreaterThan(0);
    expect(films.length).toBeLessThanOrEqual(5);
    expect(films.every((i) => api.isVideoItem(i))).toBe(true);
  });

  it("lists favourites across libraries, films, shows and episodes only", async () => {
    const api = await qaApiFull();
    let favs: { Items: any[]; TotalRecordCount: number } = { Items: [], TotalRecordCount: 0 };
    const [ours, theirs] = await agreed(async () => {
      favs = await api.getFavorites();
      const server = await raw(
        `/Items?userId=${qa!.userId}&Recursive=true&Filters=IsFavorite&IncludeItemTypes=Movie,Series,Episode&Limit=200`
      );
      return [
        [favs.TotalRecordCount, favs.Items.map((i) => i.Id).sort()],
        [server.TotalRecordCount, server.Items.map((i: any) => i.Id).sort()],
      ];
    });
    expect(ours).toEqual(theirs);
    expect(favs.Items.every((i) => i.UserData?.IsFavorite)).toBe(true);
    const films = await api.getFavorites({ includeTypes: "Movie" });
    expect(films.Items.every((i) => i.Type === "Movie")).toBe(true);
  });

  it("fetches items by id in batches of 50, and their user data", async () => {
    const api = await qaApiFull();
    const ids = [
      ...Object.keys(qa!.fixtures.fixtures).filter((k) => k.startsWith("film.")).map((k) => fx(k).id),
      ...fxEpisodes("show.long").map((e) => e.id),
      ...fxEpisodes("show.short").map((e) => e.id),
      ...qa!.fixtures.fixtures.music.albums.flatMap((a: any) => a.tracks.map((t: any) => t.id)),
    ];
    expect(ids.length).toBeGreaterThan(50);
    const items = await api.getItemsByIds(ids);
    expect(items.map((i) => i.Id).sort()).toEqual([...ids].sort());
    expect(bridgeCalls().filter((c) => c.path.startsWith("/Items?")).length).toBe(Math.ceil(ids.length / 50));
    const ud = await api.getUserDataByIds(ids.slice(0, 3));
    expect([...ud.keys()].sort()).toEqual(ids.slice(0, 3).sort());
    for (const v of ud.values()) expect(typeof v.Played).toBe("boolean");
    const withFields = await api.getItemsByIds([fx("film.long_direct").id], "Overview");
    expect(typeof withFields[0].Overview).toBe("string");
  });

  it("describes a film's trickplay tiles and fetches one through the backend", async () => {
    const api = await qaApiFull();
    const f = fx("film.long_direct");
    const info = await api.getTrickplay(f.id);
    expect(info).not.toBeNull();
    expect(info!.width).toBe(f.trickplayWidths[0]);
    expect(info!.interval).toBeGreaterThan(0);
    expect(info!.thumbnailCount).toBeGreaterThan(0);
    expect(info!.mediaSourceId).toBe(f.mediaSources[0].id);
    const tile = await api.trickplayTile(info!, 0);
    expect(tile).toMatch(/^data:image\/(jpeg|webp|png);base64,/);
    expect(tile.length).toBeGreaterThan(1000);
  });

  it("takes trickplay tiles from the version that plays (regression: a963a95 multi-version tiles)", async () => {
    const api = await qaApiFull();
    const f = fx("film.versions");
    const info = await api.getTrickplay(f.id);
    expect(info).not.toBeNull();
    const item = await raw(`/Items/${f.id}?userId=${qa!.userId}&Fields=MediaSources`);
    expect(info!.mediaSourceId).toBe(item.MediaSources[0].Id);
    const tile = await api.trickplayTile(info!, 0);
    expect(tile).toMatch(/^data:image\//);
  });

  it("finds no trickplay for an item that has none", async () => {
    const api = await qaApiFull();
    expect(await api.getTrickplay(fx("show.long").id)).toBeNull();
  });

  it("reads the intro marker, and no recap, commercial or preview", async () => {
    const api = await qaApiFull();
    const f = fx("film.long_direct");
    const segs = await api.getMediaSegments(f.id);
    const intro = f.segments.find((s: any) => s.type === "Intro");
    expect(segs.find((s) => s.type === "Intro")).toEqual({ type: "Intro", start: intro.startSeconds, end: intro.endSeconds });
    expect(segs.map((s) => s.type).filter((t) => t !== "Intro" && t !== "Outro")).toEqual([]);
  });

  // BUG: getMediaSegments (src/api.ts:1057) sends
  // `includeSegmentTypes=Intro,Outro`. Jellyfin 12.2 reads that as the single
  // type "Intro" (it wants the parameter repeated:
  // `includeSegmentTypes=Intro&includeSegmentTypes=Outro`), so Outro segments
  // never arrive and "Skip credits" (main.ts:1769) never appears.
  it.fails("reads intro and credits markers, and only those", async () => {
    const api = await qaApiFull();
    const f = fx("film.long_direct");
    const segs = await api.getMediaSegments(f.id);
    const want = f.segments.filter((s: any) => s.type === "Intro" || s.type === "Outro");
    expect(segs.map((s) => s.type)).toEqual(want.map((s: any) => s.type));
    segs.forEach((s, i) => {
      expect(s.start).toBeCloseTo(want[i].startSeconds, 1);
      expect(s.end).toBeCloseTo(want[i].endSeconds, 1);
    });
    expect(await api.getMediaSegments(fx("film.rated_g").id)).toEqual([]);
  });

  it("serves every image URL it builds without a token", async () => {
    const api = await qaApiFull();
    const film = await api.getItem(fx("film.long_direct").id);
    const urls = [api.imageUrl(film), api.imageUrl(film, "Backdrop", 1280), api.logoUrl(film)];
    const ep = (await api.getEpisodes(fx("show.long").id, fx("show.long").seasons.find((s: any) => s.index === 1).id))[0];
    urls.push(api.imageUrl(ep), api.seriesPosterUrl(ep), api.seasonPosterUrl(ep));
    for (const url of urls) {
      expect(url).toBeTruthy();
      expect(url!).not.toMatch(/api_key|token/i);
      const res = await fetch(url!);
      expect(res.status, url!).toBe(200);
      expect(res.headers.get("content-type"), url!).toMatch(/^image\//);
    }
    expect(api.imageHash(film)).toMatch(/^.{6,}$/);
  });

  it("lists QA Channel 1 and 2 and a guide that catches the programme already on", async () => {
    const api = await qaApiFull();
    const channels = await api.getChannels();
    const want = qa!.fixtures.existing.liveTv.channels;
    expect(channels.map((c) => c.Name)).toEqual(expect.arrayContaining(want.map((c: any) => c.name)));
    const from = new Date();
    const to = new Date(from.getTime() + 6 * 3600_000);
    const programs = await api.getPrograms(channels.map((c) => c.Id), from, to);
    expect(programs.length).toBeGreaterThanOrEqual(10);
    for (const p of programs) {
      expect(Date.parse(p.EndDate)).toBeGreaterThan(from.getTime() - 1000);
      expect(Date.parse(p.StartDate)).toBeLessThan(to.getTime() + 1000);
    }
    // minEndDate rather than a start-date range: the one on now started earlier.
    expect(programs.some((p) => Date.parse(p.StartDate) < from.getTime())).toBe(true);
  });

  it("turns a missing item into a plain server error", async () => {
    const api = await qaApiFull();
    await expect(api.getItem("ffffffffffffffffffffffffffffffff")).rejects.toThrow(
      "Server error 404 on /Items/ffffffffffffffffffffffffffffffff"
    );
  });

  it("drops the session and announces it when the server answers 401 (a revoked token)", async () => {
    const api = await qaApiFull();
    // The same server, asked with a token it has never issued.
    onInvoke("jf_request", async (a: { path: string; method?: string }) => {
      const res = await fetch(qa!.server + a.path, {
        method: a.method ?? "GET",
        headers: { Authorization: authHeader().replace(qa!.token, "0".repeat(32)) },
      });
      return { status: res.status, body: null };
    });
    // As the backend does on sign-out: the stored token goes, so the config
    // read after it has none.
    onInvoke("jf_logout", () => {
      onInvoke("config_load", { server: qa!.server, has_token: false });
      return { revoked: true, pending: false };
    });
    let expired = 0;
    document.addEventListener("aquarium-auth-expired", () => expired++, { once: true });
    await expect(api.getViews()).rejects.toThrow("Your session has expired");
    expect(expired).toBe(1);
    expect(api.getSession()).toBeNull();
  });

  it("checks the server is reachable", async () => {
    const api = await qaApiFull();
    expect(await api.checkOnline()).toBe(true);
    expect(api.isOffline()).toBe(false);
  });
});

describe.skipIf(!qa)("QA server: before sign-in", () => {
  it("probes the server's identity", async () => {
    const api = await qaApiFull();
    const probe = await api.probeServer(qa!.server);
    expect(probe.server_id).toBe(qa!.serverId);
    expect(probe.version).toBe(qa!.version);
    expect(probe.secure).toBe(false);
  });

  it("lists exactly the public users, sorted", async () => {
    const api = await qaApiFull();
    const users = await api.publicUsers(qa!.server);
    expect(users.map((u) => u.Name)).toEqual([...qa!.fixtures.publicUsers].sort());
  });

  it("sees Quick Connect turned on", async () => {
    const api = await qaApiFull();
    expect(await api.quickConnectEnabled(qa!.server)).toBe(true);
  });

  it.skipIf(!qaWritable)("asks for a code, and sees it approved once this signed-in account authorises it", async () => {
    const api = await qaApiFull();
    // The asking side must be another device: approving a code issues a
    // token for the device that asked, and Jellyfin revokes any other token
    // that device id holds for the account, which would be the suite's own.
    const otherDevice = `MediaBrowser Client="Aquarium", Device="Linux", DeviceId="aquarium-linux-vitest-qc", Version="0.0.0-test"`;
    onInvoke("jf_public", async (a: { path: string; method?: string }) => {
      const res = await fetch(qa!.server + a.path, { method: a.method ?? "GET", headers: { Authorization: otherDevice } });
      const text = await res.text();
      return { status: res.status, body: text.trim() ? JSON.parse(text) : null };
    });
    const start = await api.quickConnectInitiate(qa!.server);
    onTestFinished(async () => {
      // Redeem the approved code and sign that session straight out, so no
      // device is left signed in to the account.
      const auth = await fetch(`${qa!.server}/Users/AuthenticateWithQuickConnect`, {
        method: "POST",
        headers: { Authorization: otherDevice, "Content-Type": "application/json" },
        body: JSON.stringify({ Secret: start.secret }),
      });
      if (auth.ok) {
        const token = (await auth.json()).AccessToken;
        await fetch(`${qa!.server}/Sessions/Logout`, {
          method: "POST",
          headers: { Authorization: `${otherDevice}, Token="${token}"` },
        });
      }
    });
    expect(start.code).toMatch(/^\d{6}$/);
    expect(start.secret.length).toBeGreaterThan(10);
    expect(await api.quickConnectState(qa!.server, start.secret)).toBe(false);
    // Spaces typed by a person are ignored.
    expect(await api.authorizeQuickConnect(start.code.replace(/(\d{3})/, "$1 "))).toBe(true);
    expect(await api.quickConnectState(qa!.server, start.secret)).toBe(true);
    expect(await api.quickConnectState(qa!.server, "no-such-secret")).toBeNull();
  });

  it("does not approve a code nobody asked for", async () => {
    const api = await qaApiFull();
    expect(await api.authorizeQuickConnect("000000")).toBe(false);
    expect(await api.authorizeQuickConnect("no digits")).toBe(false);
  });

  it("builds a user picture address the server answers without a token", async () => {
    const api = await qaApiFull();
    const res = await fetch(api.avatarUrl(qa!.server, qa!.userId));
    // An account with no picture is a 404, never a 401.
    expect([200, 404]).toContain(res.status);
  });
});
