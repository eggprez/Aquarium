// Music and audiobook downloads (src/views/musicDownloads.ts): queueing the
// original files through the shared download queue, the metadata kept beside
// them, the downloaded list the offline pages read, and Library → Downloaded.
import { beforeEach, describe, expect, it, vi } from "vitest";
import { jfPaths, onInvoke, signIn } from "../helpers/tauri";
import { byText, click, lastToast, mountShell, settle, texts } from "../helpers/views-media";
import { album, book, musicServer, song, type FakeAudio } from "../helpers/views-media-music";

vi.mock("../../src/audio", async () => (await import("../helpers/views-media-music")).fakeAudioModule());
vi.mock("../../src/playback", async (importOriginal) => {
  const real = await importOriginal<typeof import("../../src/playback")>();
  return { ...real, downloadSeason: vi.fn(async () => ({ queued: 1, skipped: 0, cancelled: false })) };
});

type MD = typeof import("../../src/views/musicDownloads");
const META_KEY = "aquarium.music-downloads";

let md: MD;
let audio: FakeAudio;
let downloadSeason: any;
let root: HTMLElement;

beforeEach(() => {
  vi.resetModules();
  vi.clearAllMocks();
});

async function boot(server: Parameters<typeof musicServer>[0] = {}, list: any[] = []): Promise<void> {
  root = mountShell();
  musicServer(server);
  onInvoke("downloads_list", () => list);
  await signIn();
  audio = (await import("../../src/audio")) as any;
  audio.__reset();
  downloadSeason = (await import("../../src/playback")).downloadSeason;
  md = await import("../../src/views/musicDownloads");
}

const meta = (): Record<string, any> => JSON.parse(localStorage.getItem(META_KEY) ?? "{}");

describe("downloadMusic", () => {
  it("queues an album's tracks as original files, with the detail fields, and keeps their metadata", async () => {
    let idsQuery = "";
    await boot({
      items: (q) => {
        if (q.get("ParentId") === "al1") return [song("t2", { IndexNumber: 2 }), song("t1", { IndexNumber: 1, Extra: "dropped" })];
        if (q.get("Ids")) {
          idsQuery = q.toString();
          return [{ Id: "t1", MediaSources: [{ Container: "flac", Size: 10 }] }];
        }
        return [];
      },
    });
    downloadSeason.mockResolvedValueOnce({ queued: 1, skipped: 1, cancelled: false });
    await md.downloadMusic(album("al1"));
    const [items, quality] = downloadSeason.mock.calls[0];
    expect(items.map((i: any) => i.Id)).toEqual(["t1", "t2"]);
    expect(items[0].MediaSources[0].Container).toBe("flac");
    expect(quality.original).toBe(true);
    expect(idsQuery).toMatch(/Ids=t1%2Ct2|Ids=t1,t2/);
    expect(idsQuery).toMatch(/MediaSources/);
    // Only what's needed to list and play offline is kept.
    expect(meta().t1).toEqual(expect.objectContaining({ Id: "t1", Type: "Audio", Album: "The Album", IndexNumber: 1 }));
    expect(meta().t1.Extra).toBeUndefined();
    expect(meta().t1.MediaSources).toBeUndefined();
    expect(lastToast()).toBe("Downloading 1 song, 1 already here");
  });

  it("queues a single song or a book as itself, counting files for a book", async () => {
    await boot({ items: () => [] });
    downloadSeason.mockResolvedValueOnce({ queued: 2, skipped: 0, cancelled: false });
    await md.downloadMusic(song("s1"));
    expect(lastToast()).toBe("Downloading 2 songs");
    downloadSeason.mockResolvedValueOnce({ queued: 1, skipped: 0, cancelled: false });
    await md.downloadMusic(book("b1"));
    expect(lastToast()).toBe("Downloading 1 file");
    expect(downloadSeason.mock.calls[1][0].map((i: any) => i.Id)).toEqual(["b1"]);
  });

  it("says when everything is already here, and nothing when the queue was cancelled", async () => {
    await boot({ items: () => [] });
    downloadSeason.mockResolvedValueOnce({ queued: 0, skipped: 1, cancelled: false });
    await md.downloadMusic(song("s1"));
    expect(lastToast()).toBe("Already downloaded");
    expect(document.querySelector("#toasts .toast.error, #toasts .toast.ok")).toBeNull();
    downloadSeason.mockResolvedValueOnce({ queued: 0, skipped: 0, cancelled: true });
    await md.downloadMusic(song("s2"));
    expect(document.querySelectorAll("#toasts .toast")).toHaveLength(1);
  });

  it("does nothing for something that isn't a song, album or book", async () => {
    await boot();
    await md.downloadMusic({ Id: "ar", Type: "MusicArtist" });
    expect(downloadSeason).not.toHaveBeenCalled();
    expect(jfPaths()).toEqual([]);
  });

  it("reports a download that couldn't be queued", async () => {
    await boot({ items: () => ({ __status: 500 }) });
    await md.downloadMusic(album("al1"));
    expect(lastToast()).toMatch(/^Download failed: Server error 500/);
  });

  it("still downloads when the metadata can't be stored", async () => {
    await boot({ items: () => [] });
    const spy = vi.spyOn(Storage.prototype, "setItem").mockImplementation(() => {
      throw new Error("QuotaExceeded");
    });
    try {
      await md.downloadMusic(song("s1"));
    } finally {
      spy.mockRestore();
    }
    expect(downloadSeason).toHaveBeenCalled();
    expect(lastToast()).toBe("Downloading 1 song");
  });
});

describe("downloadActions", () => {
  const labels = (item: any) => md.downloadActions(item).map((a) => a.label);

  it("is Download for a song, book or playlist, Download Album for an album, and nothing otherwise", async () => {
    await boot({ items: () => [] });
    expect(md.downloadActions(song("s"))).toMatchObject([{ label: "Download", icon: "download" }]);
    expect(labels(album("a"))).toEqual(["Download Album"]);
    expect(labels(book("b"))).toEqual(["Download"]);
    expect(labels({ Id: "p", Type: "Playlist" })).toEqual(["Download"]);
    expect(md.downloadActions({ Type: "Movie" })).toEqual([]);
    md.downloadActions(song("s"))[0]!.run!();
    await settle();
    expect(downloadSeason).toHaveBeenCalled();
  });

  it("is Remove Download for a file that is here and Downloading… for one on its way; removing deletes the file and what was kept about it", async () => {
    localStorage.setItem(META_KEY, JSON.stringify({ s1: song("s1"), s2: song("s2", { AlbumId: "al2" }), b1: book("b1") }));
    await boot({ items: () => [] }, [
      { item_id: "s1", status: "complete", path: "/d/s1" },
      { item_id: "s2", status: "downloading" },
      { item_id: "b1", status: "complete", path: "/d/b1" },
      { item_id: "v1", type: "Movie", status: "complete", path: "/v/v1" },
    ]);
    const deleted: string[] = [];
    onInvoke("download_delete", (a: any) => void deleted.push(a.itemId));
    await md.refreshDownloadState();
    expect(md.downloadActions(song("s1"))).toMatchObject([{ label: "Remove Download", icon: "trash", danger: true }]);
    expect(labels(book("b1"))).toEqual(["Remove Download"]);
    expect(labels(song("s2"))).toEqual(["Downloading…"]);
    expect(labels(song("s3"))).toEqual(["Download"]);
    // Downloading… goes to the Downloads page rather than queueing again.
    md.downloadActions(song("s2"))[0]!.run!();
    expect(location.hash).toBe("#/downloads");
    expect(downloadSeason).not.toHaveBeenCalled();
    md.downloadActions(song("s1"))[0]!.run!();
    await settle();
    expect(deleted).toEqual(["s1"]);
    expect(Object.keys(meta()).sort()).toEqual(["b1", "s2"]);
    expect(lastToast()).toBe("Download deleted");
  });

  it("for an album: Download Album until all of it is here, Remove Download once any of it is, Downloading… while any is on its way", async () => {
    localStorage.setItem(META_KEY, JSON.stringify({
      t1: song("t1"), t2: song("t2"),
      u1: song("u1", { AlbumId: "al2" }), u2: song("u2", { AlbumId: "al2" }),
    }));
    await boot({ items: () => [] }, [
      { item_id: "t1", status: "complete", path: "/d/t1" },
      { item_id: "t2", status: "complete", path: "/d/t2" },
      { item_id: "u1", status: "complete", path: "/d/u1" },
      { item_id: "u2", status: "downloading" },
    ]);
    const deleted: string[] = [];
    onInvoke("download_delete", (a: any) => void deleted.push(a.itemId));
    await md.refreshDownloadState();
    expect(labels(album("al1", { ChildCount: 3 }))).toEqual(["Download Album", "Remove Download"]);
    // With no song count the list can't say the album is whole.
    expect(labels(album("al1"))).toEqual(["Download Album", "Remove Download"]);
    expect(labels(album("al1", { ChildCount: 2 }))).toEqual(["Remove Download"]);
    expect(labels(album("al2", { ChildCount: 2 }))).toEqual(["Downloading…"]);
    expect(labels(album("al3", { ChildCount: 2 }))).toEqual(["Download Album"]);
    md.downloadActions(album("al1", { ChildCount: 2 }))[0]!.run!();
    await settle();
    expect(deleted.sort()).toEqual(["t1", "t2"]);
    expect(lastToast()).toBe("2 downloads deleted");
    expect(Object.keys(meta()).sort()).toEqual(["u1", "u2"]);
  });

  it("with no server offers only removal", async () => {
    localStorage.setItem(META_KEY, JSON.stringify({ s1: song("s1") }));
    await boot({ items: () => [] }, [{ item_id: "s1", status: "complete", path: "/d/s1" }]);
    await md.refreshDownloadState();
    onInvoke("jf_ping", false);
    await (await import("../../src/api")).checkOnline();
    expect(labels(song("s1"))).toEqual(["Remove Download"]);
    expect(labels(song("s2"))).toEqual([]);
    expect(labels(book("b"))).toEqual([]);
    expect(labels({ Id: "p", Type: "Playlist" })).toEqual([]);
    expect(labels(album("al1", { ChildCount: 3 }))).toEqual(["Remove Download"]);
    expect(labels(album("al9"))).toEqual([]);
  });
});

describe("downloadMark", () => {
  it("marks a song, book or album that is here or on its way, fills in later, and is nothing for anything else", async () => {
    localStorage.setItem(META_KEY, JSON.stringify({ s1: song("s1"), s2: song("s2", { AlbumId: "al2" }) }));
    let list: any[] = [];
    await boot({ items: () => [] });
    onInvoke("downloads_list", () => list);
    expect(md.downloadMark({ Id: "ar", Type: "MusicArtist" })).toBeNull();
    expect(md.downloadMark({ Type: "Audio" })).toBeNull();
    const marks = [song("s1"), song("s2"), song("s3"), album("al1", { ChildCount: 1 }), album("al1", { ChildCount: 2 }), album("al1"), album("al2", { ChildCount: 5 })]
      .map((i) => md.downloadMark(i)!);
    root.append(...marks);
    const drawn = () => marks.map((s) => [s.title, s.children.length]);
    expect(marks.every((s) => s.classList.contains("mu-dl"))).toBe(true);
    expect(drawn()).toEqual(Array(7).fill(["", 0]));
    list = [
      { item_id: "s1", status: "complete", path: "/d/s1" },
      { item_id: "s2", status: "downloading" },
    ];
    let changed = 0;
    document.addEventListener(md.DOWNLOADS_CHANGED, () => changed++);
    await md.refreshDownloadState();
    expect(drawn()).toEqual([
      ["Downloaded", 1], ["Downloading…", 1], ["", 0],
      // An album is marked only when the list says how many songs it has and all are here.
      ["Downloaded", 1], ["", 0], ["", 0],
      ["Downloading…", 1],
    ]);
    expect(changed).toBe(1);
    // Nothing moved: nothing is redrawn or announced.
    await md.refreshDownloadState();
    expect(changed).toBe(1);
    // A mark made now is drawn at once, and one whose file went away empties.
    expect(md.downloadMark(song("s1"))!.title).toBe("Downloaded");
    list = [];
    await md.refreshDownloadState();
    expect(drawn()).toEqual(Array(7).fill(["", 0]));
    expect(marks[0]!.hasAttribute("title")).toBe(false);
  });
});

describe("downloadedItems", () => {
  it("lists finished song and book files, with the stored metadata, position and the local path (regression: 32f1e9f a downloaded song plays from disk wherever it is started)", async () => {
    localStorage.setItem(META_KEY, JSON.stringify({ s1: { Id: "s1", Name: "Kept name", Type: "Audio", Album: "A" } }));
    await boot({}, [
      { item_id: "s1", status: "complete", path: "/m/s1.flac", position_ticks: 5, played: true },
      { item_id: "b1", type: "AudioBook", status: "complete", path: "/m/b1.m4b", title: "Book title", run_time_ticks: 99 },
      { item_id: "x1", type: "Audio", status: "downloading", path: "/m/x1.flac" },
      { item_id: "x2", type: "Audio", status: "complete" },
      { item_id: "v1", type: "Movie", status: "complete", path: "/v/v1.mkv" },
      { item_id: "u1", status: "complete", path: "/m/u1" },
    ]);
    const items = await md.downloadedItems();
    expect(items).toEqual([
      { Id: "s1", Name: "Kept name", Type: "Audio", Album: "A", UserData: { PlaybackPositionTicks: 5, Played: true }, __localPath: "/m/s1.flac" },
      { Id: "b1", Name: "Book title", Type: "AudioBook", RunTimeTicks: 99, UserData: { PlaybackPositionTicks: 0, Played: false }, __localPath: "/m/b1.m4b" },
    ]);
  });

  it("is empty when the backend can't list downloads, and survives unreadable metadata", async () => {
    localStorage.setItem(META_KEY, "{not json");
    await boot();
    onInvoke("downloads_list", () => {
      throw new Error("backend down");
    });
    expect(await md.downloadedItems()).toEqual([]);
    onInvoke("downloads_list", [{ item_id: "s", type: "Audio", status: "complete", path: "/s", name: "N" }]);
    expect((await md.downloadedItems())[0].Name).toBe("N");
  });
});

describe("renderDownloaded (Library → Downloaded)", () => {
  it("says nothing is downloaded yet, under the tabs it was given", async () => {
    await boot();
    const tabs = document.createElement("nav");
    await md.renderDownloaded(root, tabs);
    expect(root.querySelector("h1")!.textContent).toBe("Downloaded Music & Books");
    expect(root.children[1]).toBe(tabs);
    expect(root.querySelector(".state h3")!.textContent).toBe("Nothing downloaded yet");
  });

  it("lists books, then artists, albums and songs by artist, album, disc and track, and plays them from disk", async () => {
    const m: Record<string, any> = {
      s1: song("s1", { AlbumArtist: "Zed", Album: "Z", AlbumId: "alZ", IndexNumber: 1 }),
      s2: song("s2", { AlbumArtist: "Abe", Album: "B", AlbumId: "alB", IndexNumber: 2 }),
      s3: song("s3", { AlbumArtist: "Abe", Album: "B", AlbumId: "alB", IndexNumber: 1 }),
      s4: song("s4", { AlbumArtist: "Abe", Album: "A", AlbumId: "alA", ParentIndexNumber: 2, IndexNumber: 1 }),
      s5: song("s5", { AlbumArtist: "Abe", Album: "A", AlbumId: "alA", ParentIndexNumber: 1, IndexNumber: 9 }),
      // No album artist: filed under the first artist credited ("The Band").
      s6: song("s6", { AlbumArtist: undefined, Album: undefined, AlbumId: undefined, IndexNumber: undefined, ParentIndexNumber: undefined }),
      b1: book("b1", { Name: "Novel" }),
    };
    localStorage.setItem(META_KEY, JSON.stringify(m));
    await boot({}, [...Object.keys(m).map((id) => ({ item_id: id, status: "complete", path: `/d/${id}`, position_ticks: id === "b1" ? 600_000_000 : 0 }))]);
    await md.renderDownloaded(root);
    expect(texts(root, "h2.mu-sub-head")).toEqual(["Audiobooks", "Songs (6)"]);
    expect(texts(root, ".mu-shelf h2")).toEqual(["Artists", "Albums"]);
    const shelfCards = (title: string) =>
      Array.from(byText(root, ".mu-shelf h2", title)!.closest(".mu-shelf")!.querySelectorAll(".mu-card")).map((c) => [
        c.querySelector(".mu-card-title")!.textContent,
        c.querySelector(".mu-card-sub")?.textContent ?? "",
      ]);
    expect(shelfCards("Artists")).toEqual([["Abe", "4 songs"], ["The Band", "1 song"], ["Zed", "1 song"]]);
    expect(shelfCards("Albums")).toEqual([["A", "Abe"], ["B", "Abe"], ["Z", "Zed"]]);
    expect(Array.from(root.querySelectorAll<HTMLElement>(".mu-song")).map((r) => r.dataset.id)).toEqual(["s5", "s4", "s3", "s2", "s6", "s1"]);
    const bookCard = root.querySelector(".mu-grid .mu-card")!;
    expect(bookCard.querySelector(".mu-card-sub")!.textContent).toBe("Ann Author");
    // The card opens the book's page; its play button plays the file.
    click(bookCard);
    expect(location.hash).toBe("#/books/book/b1");
    expect(audio.play).not.toHaveBeenCalled();
    click(bookCard.querySelector(".mu-cover-play"));
    const [items, start, opts] = (audio.play as any).mock.calls[0];
    expect(items.map((i: any) => i.Id)).toEqual(["b1"]);
    expect(start).toBe(0);
    expect(opts).toEqual({ book: true, title: "Novel", startSeconds: 60 });
    expect(items[0].__localPath).toBe("/d/b1");
    click(byText(root, ".mu-head-buttons button", "Play"));
    click(byText(root, ".mu-head-buttons button", "Shuffle"));
    const calls = (audio.play as any).mock.calls;
    expect(calls[1][0].map((s: any) => s.Id)).toEqual(["s5", "s4", "s3", "s2", "s6", "s1"]);
    expect(calls[1][2]).toEqual({ title: "Downloaded" });
    expect(calls[2][2]).toEqual({ title: "Downloaded", shuffle: true });
  });

  it("starts an unstarted book from the beginning, and a list of books alone has no Songs section", async () => {
    localStorage.setItem(META_KEY, JSON.stringify({ b1: book("b1") }));
    await boot({}, [{ item_id: "b1", status: "complete", path: "/d/b1" }]);
    await md.renderDownloaded(root);
    expect(texts(root, "h2.mu-sub-head")).toEqual(["Audiobooks"]);
    click(root.querySelector(".mu-card .mu-cover-play"));
    expect((audio.play as any).mock.calls[0][2].startSeconds).toBeUndefined();
  });
});
