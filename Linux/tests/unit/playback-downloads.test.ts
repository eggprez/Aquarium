// src/playback.ts: the download queue — single items and seasons, the disk
// space check, the parallel limit, retries (the user's and the app's own),
// Pause, the metered-connection hold, one transcode at a time, and the queue
// restored from the last run.
import { afterEach, describe, expect, it, vi } from "vitest";
import { emitEvent, invokeCalls, onInvoke } from "../helpers/tauri";
import {
  SERVER,
  boot,
  clickDialog,
  dialog,
  dialogButtons,
  download,
  episode,
  errorToasts,
  mockServer,
  recordEvents,
  settle,
  teardown,
  toasts,
} from "../helpers/playback";

afterEach(teardown);

const HOUR = 36_000_000_000;
const GiB = 1 << 30;

/** A one-hour film whose original is far bigger than any transcode. */
const film = (id: string, extra: Record<string, any> = {}): any => ({
  Id: id,
  Type: "Movie",
  Name: `Film ${id}`,
  RunTimeTicks: HOUR,
  MediaSources: [{ Size: 20e9, Container: "mkv" }],
  ...extra,
});

const starts = (): string[] => invokeCalls("download_start").map((c) => c.args.req.item_id);
const retries = (): any[] => invokeCalls("download_retry").map((c) => c.args);
const progress = (item_id: string, state: string, extra: Record<string, any> = {}): void =>
  emitEvent("download-progress", { item_id, state, ...extra });
const queued = (pb: any): string[] => pb.getQueuedDownloads().map((p: any) => p.id);

async function booted(opts: Parameters<typeof boot>[0] = {}) {
  const b = await boot(opts);
  mockServer();
  const Q = Object.fromEntries(b.api.DOWNLOAD_QUALITIES.map((q) => [q.name ?? "original", q]));
  return { ...b, Q };
}

describe("startDownload", () => {
  it("starts at once with nothing in the way, and sends everything the Downloads view needs offline", async () => {
    const { pb, Q } = await booted();
    const ep = episode("e1", 3, {
      RunTimeTicks: HOUR,
      MediaSources: [{ Size: 20e9 }],
      ProductionYear: 2001,
      Overview: "Things happen.",
      ImageTags: { Primary: "tagE" },
      SeriesPrimaryImageTag: "tagS",
      UserData: { PlaybackPositionTicks: 5, Played: true },
    });
    await pb.startDownload(ep, Q["1080p"]);
    const req = invokeCalls("download_start")[0]!.args.req;
    expect(req.item_id).toBe("e1");
    expect(req.url).toMatch(new RegExp(`^${SERVER}/Videos/e1/stream\\.mkv\\?`));
    expect(req.url).not.toContain("api_key");
    expect(req.file_name).toBe("Episode 3 (1080p).mkv");
    expect(req.image_url).toContain("/Items/e1/Images/Primary?maxWidth=500&tag=tagE");
    expect(req.series_image_url).toContain("/Items/show/Images/Primary?maxWidth=500&tag=tagS");
    expect(req.season_image_url).toContain("/Items/s1/Images/Primary?maxWidth=500");
    expect(req.estimated_bytes).toBe(Math.round(((9_000_000 + 256_000) / 8) * 3600 * 1.02));
    expect(req.meta).toEqual({
      name: "Episode 3",
      title: "The Show Season 1, Episode 3 · Episode 3",
      type: "Episode",
      series: "The Show",
      series_id: "show",
      season: 1,
      season_id: "s1",
      episode: 3,
      year: 2001,
      run_time_ticks: HOUR,
      overview: "Things happen.",
      image_tag: "tagE",
      series_image_tag: "tagS",
      quality: "1080p · 9 Mbps",
      position_ticks: 5,
      played: true,
    });
    expect(toasts()).toEqual(["Download started: Episode 3 (1080p · 9 Mbps)"]);
  });

  it("a film has no series or season images, and its missing fields are null", async () => {
    const { pb, Q } = await booted();
    await pb.startDownload({ Id: "bare", Type: "Movie", Name: "Bare" }, Q.original);
    const req = invokeCalls("download_start")[0]!.args.req;
    expect(req).toMatchObject({ url: `${SERVER}/Items/bare/Download`, series_image_url: null, season_image_url: null, estimated_bytes: null });
    expect(req.meta).toMatchObject({ series: null, series_id: null, season: null, episode: null, year: null, position_ticks: 0, played: false, quality: "Original quality" });
  });

  it("takes the original file when a transcode would be bigger (and the original never drifts at encode restarts)", async () => {
    const { pb, Q } = await booted();
    await pb.startDownload(film("small", { MediaSources: [{ Size: 1e9, Container: "mp4" }] }), Q["4K"]);
    const req = invokeCalls("download_start")[0]!.args.req;
    expect(req.url).toBe(`${SERVER}/Items/small/Download`);
    expect(req.file_name).toBe("Film small.mp4");
    expect(req.meta.quality).toBe("Original quality");
    expect(toasts()).toEqual(["Download started: Film small (original file — smaller than a 4K · 32 Mbps transcode)"]);
  });

  it("will not queue the same item twice", async () => {
    const { pb, Q } = await booted();
    await pb.startDownload(film("a"), Q["720p"]);
    await pb.startDownload(film("a"), Q["720p"]);
    expect(starts()).toEqual(["a"]);
    expect(toasts()).toContain("“Film a” is already in the download queue");
    await pb.startDownload(film("b"), Q["720p"]);
    await pb.startDownload(film("b"), Q["720p"]);
    expect(toasts().filter((t) => t.includes("already"))).toHaveLength(2);
  });

  it("with the parallel limit reached, waits its turn and says so", async () => {
    const { pb, Q } = await booted();
    await pb.startDownload(film("a"), Q["720p"]);
    await pb.startDownload(film("b"), Q["720p"]);
    expect(starts()).toEqual(["a"]);
    expect(toasts()).toContain("Queued: Film b");
    expect(pb.getQueuedDownloads()).toEqual([
      { id: "b", title: "Film b", series: null, season: null, episode: null, quality: "720p · 4.5 Mbps", transcode: true },
    ]);
    progress("a", "complete");
    await settle();
    expect(starts()).toEqual(["a", "b"]);
    expect(queued(pb)).toEqual([]);
  });

  it("names the hold when downloads are paused", async () => {
    const { pb, Q } = await booted({ config: { downloads_paused: true } });
    await pb.startDownload(film("a"), Q["720p"]);
    expect(starts()).toEqual([]);
    expect(toasts()).toEqual(["Queued: Film a · downloads are paused"]);
  });

  it("tells the Downloads view only after the backend has written meta.json (regression: the item vanished from both Up next and Downloading)", async () => {
    const { pb, Q } = await booted();
    let finish!: () => void;
    onInvoke("download_start", () => new Promise<void>((r) => (finish = r)));
    const seen = recordEvents("aquarium-download-queue");
    const p = pb.startDownload(film("a"), Q["720p"]);
    await settle();
    expect(queued(pb)).toEqual([]);
    const before = seen.length;
    finish();
    await p;
    expect(seen.length).toBe(before + 1);
  });

  it("a transfer that will not start is reported and the queue moves on", async () => {
    const { pb, Q } = await booted();
    onInvoke("download_start", (a: any) => {
      if (a.req.item_id === "a") throw "already in progress";
      return null;
    });
    pb.setDownloadConcurrency(1);
    await pb.downloadSeason([film("a"), film("b")], Q["720p"]);
    await settle();
    expect(errorToasts()).toEqual(["Couldn't start Film a: already in progress"]);
    expect(starts()).toEqual(["a", "b"]);
  });
});

describe("the disk space check", () => {
  const free = (bytes: number | null) => onInvoke("disk_free", bytes);

  it("goes ahead when it fits with a gigabyte to spare, or when either number is unknown", async () => {
    const { pb, Q } = await booted();
    free(10 * GiB);
    await pb.startDownload(film("a"), Q["1080p"]);
    free(null);
    await pb.startDownload(film("b"), Q["1080p"]);
    free(0);
    await pb.startDownload(film("c"), Q["1080p"]);
    free(1);
    await pb.startDownload({ Id: "d", Type: "Movie", Name: "No size" }, Q["1080p"]);
    onInvoke("disk_free", () => {
      throw "statvfs failed";
    });
    await pb.startDownload(film("e"), Q["1080p"]);
    expect(dialog()).toBeNull();
    pb.setDownloadConcurrency(6);
    await settle();
    expect(starts().sort()).toEqual(["a", "b", "c", "d", "e"]);
  });

  it("offers the smaller rungs that fit, Download anyway and Cancel", async () => {
    const { pb, api, Q } = await booted();
    free(3.5 * GiB);
    const p = pb.startDownload(film("a"), Q["1080p"]);
    await settle();
    const size = (q: any) => api.bytesToText(api.estimateDownloadSize(film("a"), q)!);
    expect(dialog()?.textContent).toContain("Not enough disk space");
    expect(dialog()?.textContent).toContain(
      `Film a at 1080p · 9 Mbps needs about ${size(Q["1080p"])}, and there is 3.50 GiB free where downloads are kept.`
    );
    expect(dialogButtons()).toEqual([
      `Use 720p · 4.5 Mbps (~${size(Q["720p"])})`,
      `Use 480p · 2 Mbps (~${size(Q["480p"])})`,
      "Download anyway",
      "Cancel",
    ]);
    expect(document.querySelector(".dialog .btn.primary")?.textContent).toMatch(/^Use 720p/);
    clickDialog(/^Use 480p/);
    await p;
    expect(invokeCalls("download_start")[0]!.args.req.meta.quality).toBe("480p · 2 Mbps");
  });

  it("Download anyway keeps the quality asked for", async () => {
    const { pb, Q } = await booted();
    free(3.5 * GiB);
    const p = pb.startDownload(film("a"), Q["1080p"]);
    await settle();
    clickDialog("Download anyway");
    await p;
    expect(invokeCalls("download_start")[0]!.args.req.meta.quality).toBe("1080p · 9 Mbps");
  });

  it("Cancel, Escape or a click outside queue nothing", async () => {
    const { pb, Q } = await booted();
    free(3.5 * GiB);
    let p = pb.startDownload(film("a"), Q["1080p"]);
    await settle();
    clickDialog("Cancel");
    await p;
    p = pb.startDownload(film("a"), Q["1080p"]);
    await settle();
    document.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape" }));
    await p;
    p = pb.startDownload(film("a"), Q["1080p"]);
    await settle();
    (document.querySelector(".dialog-scrim") as HTMLElement).click();
    await p;
    expect(starts()).toEqual([]);
    expect(queued(pb)).toEqual([]);
  });

  it("with nothing that fits, offers only Download anyway and Cancel", async () => {
    const { pb, Q } = await booted();
    free(0.5 * GiB);
    void pb.startDownload(film("a"), Q["1080p"]);
    await settle();
    expect(dialogButtons()).toEqual(["Download anyway", "Cancel"]);
  });
});

describe("downloadSeason and downloadSeries", () => {
  it("queues what is not already downloaded or queued, and reports the counts", async () => {
    const { pb, state, Q } = await booted();
    state.downloads = [download("e1")];
    const eps = [film("e1"), film("e2"), film("e3")];
    expect(await pb.downloadSeason(eps, Q["720p"])).toEqual({ queued: 2, skipped: 1 });
    await settle();
    expect(starts()).toEqual(["e2"]);
    expect(queued(pb)).toEqual(["e3"]);
    expect(await pb.downloadSeason(eps, Q["720p"])).toEqual({ queued: 0, skipped: 3 });
  });

  it("sizes the check against what will actually be queued, and a declined check is 'cancelled'", async () => {
    const { pb, state, Q } = await booted();
    state.downloads = [download("e1")];
    onInvoke("disk_free", 4 * GiB);
    const p = pb.downloadSeason([film("e1"), film("e2"), film("e3")], Q["1080p"]);
    await settle();
    expect(dialog()?.textContent).toContain("2 episodes at 1080p · 9 Mbps");
    clickDialog("Cancel");
    expect(await p).toEqual({ queued: 0, skipped: 1, cancelled: true });
    const one = pb.downloadSeason([film("e2")], Q["1080p"]);
    await settle();
    expect(dialog()?.textContent).toContain("1 episode at");
    clickDialog(/^Use 720p/);
    expect(await one).toEqual({ queued: 1, skipped: 0 });
    await settle();
    expect(invokeCalls("download_start")[0]!.args.req.meta.quality).toBe("720p · 4.5 Mbps");
  });

  it("a failing downloads list is treated as nothing downloaded", async () => {
    const { pb, Q } = await booted();
    onInvoke("downloads_list", () => {
      throw "io";
    });
    expect(await pb.downloadSeason([film("e1")], Q["720p"])).toEqual({ queued: 1, skipped: 0 });
  });

  it("downloadSeries walks every season, fetching them unless the caller has them", async () => {
    const b = await boot();
    mockServer({
      shows: {
        show: {
          s1: [episode("e1", 1), episode("e2", 2)],
          s2: [episode("e3", 1, { SeasonId: "s2" })],
        },
      },
    });
    const q = b.api.DOWNLOAD_QUALITIES[4]!;
    expect(await b.pb.downloadSeries("show", q)).toEqual({ queued: 3, skipped: 0, seasons: 2 });
    expect(await b.pb.downloadSeries("show", q, [{ Id: "s2" }])).toEqual({ queued: 0, skipped: 1, seasons: 1 });
  });

  it("downloadSeries fails plainly for a series with no episodes, and skips a season that will not load", async () => {
    const b = await boot();
    mockServer({ shows: { show: { s1: [] } } });
    const q = b.api.DOWNLOAD_QUALITIES[4]!;
    await expect(b.pb.downloadSeries("show", q)).rejects.toThrow("No episodes found for this series");
    onInvoke("jf_request", (a: any) =>
      a.path.includes("seasonId=bad") ? { status: 500, body: null } : { status: 200, body: { Items: [episode("ok", 1)] } }
    );
    expect(await b.pb.downloadSeries("show", q, [{ Id: "bad" }, { Id: "good" }])).toEqual({ queued: 1, skipped: 0, seasons: 2 });
  });
});

describe("the parallel limit", () => {
  it("is 1 unless set, and is clamped to 1-6", async () => {
    const { pb } = await booted();
    expect(pb.getDownloadConcurrency()).toBe(1);
    expect(pb.MAX_DOWNLOAD_CONCURRENCY).toBe(6);
    pb.setDownloadConcurrency(9);
    expect(pb.getDownloadConcurrency()).toBe(6);
    pb.setDownloadConcurrency(0);
    expect(pb.getDownloadConcurrency()).toBe(1);
    pb.setDownloadConcurrency(2.7);
    expect(pb.getDownloadConcurrency()).toBe(2);
    expect(localStorage.getItem("aquarium-dl-concurrency")).toBe("2");
  });

  it("is read back at start, and a stored value out of range is ignored", async () => {
    localStorage.setItem("aquarium-dl-concurrency", "4");
    expect((await booted()).pb.getDownloadConcurrency()).toBe(4);
    localStorage.setItem("aquarium-dl-concurrency", "12");
    expect((await booted()).pb.getDownloadConcurrency()).toBe(1);
  });

  it("raising it starts the waiting ones at once, the whole batch up to the limit (cf. the Apple app's batch hand-off)", async () => {
    const { pb, Q } = await booted();
    await pb.downloadSeason([film("a"), film("b"), film("c"), film("d")], Q["720p"]);
    await settle();
    expect(starts()).toEqual(["a"]);
    pb.setDownloadConcurrency(3);
    await settle();
    expect(starts()).toEqual(["a", "b", "c"]);
    expect(queued(pb)).toEqual(["d"]);
  });

  it("lowering it only takes effect as running downloads finish", async () => {
    const { pb, Q } = await booted();
    pb.setDownloadConcurrency(3);
    await pb.downloadSeason([film("a"), film("b"), film("c"), film("d")], Q["720p"]);
    await settle();
    pb.setDownloadConcurrency(1);
    await settle();
    progress("a", "complete");
    await settle();
    expect(starts()).toEqual(["a", "b", "c"]);
    progress("b", "complete");
    progress("c", "canceled");
    await settle();
    expect(starts()).toEqual(["a", "b", "c", "d"]);
  });

  it("still applies when localStorage is full", async () => {
    const { pb } = await booted();
    vi.spyOn(Storage.prototype, "setItem").mockImplementation(() => {
      throw new Error("QuotaExceededError");
    });
    pb.setDownloadConcurrency(3);
    expect(pb.getDownloadConcurrency()).toBe(3);
  });
});

describe("queue housekeeping", () => {
  it("cancelQueuedDownload removes a waiting item; an unknown id changes nothing", async () => {
    const { pb, Q } = await booted();
    await pb.downloadSeason([film("a"), film("b"), film("c")], Q["720p"]);
    await settle();
    const seen = recordEvents("aquarium-download-queue");
    pb.cancelQueuedDownload("b");
    pb.cancelQueuedDownload("zzz");
    expect(queued(pb)).toEqual(["c"]);
    expect(seen).toHaveLength(1);
  });

  it("clearDownloadQueue drops every waiting item and says how many", async () => {
    const { pb, Q } = await booted();
    await pb.downloadSeason([film("a"), film("b"), film("c")], Q["720p"]);
    await settle();
    expect(pb.clearDownloadQueue()).toBe(2);
    expect(queued(pb)).toEqual([]);
    // What was running is forgotten too: a new one starts straight away.
    await pb.startDownload(film("x"), Q["720p"]);
    expect(starts()).toEqual(["a", "x"]);
  });

  it("is saved, so closing the app mid-season keeps the episodes not yet started", async () => {
    const { pb, Q } = await booted();
    await pb.downloadSeason([film("a"), film("b")], Q["720p"]);
    await settle();
    const saved = JSON.parse(localStorage.getItem("aquarium-dl-queue")!);
    expect(saved.map((e: any) => e.item.Id)).toEqual(["b"]);
  });

  it("a full localStorage does not stop the queue", async () => {
    const { pb, Q } = await booted();
    vi.spyOn(Storage.prototype, "setItem").mockImplementation(() => {
      throw new Error("QuotaExceededError");
    });
    await pb.downloadSeason([film("a"), film("b")], Q["720p"]);
    await settle();
    expect(queued(pb)).toEqual(["b"]);
  });

  it("names an item without a Name by its title", async () => {
    const { pb, Q } = await booted();
    await pb.downloadSeason([film("a"), { ...episode("e5", 5, { RunTimeTicks: HOUR }), Name: undefined }], Q["720p"]);
    await settle();
    expect(pb.getQueuedDownloads()[0]).toMatchObject({
      title: "The Show Season 1, Episode 5 · undefined",
      series: "The Show",
      season: 1,
      episode: 5,
    });
  });
});

describe("retries", () => {
  it("retryDownload puts it at the front of the queue and starts it through the queue (regression: Retry ignored the parallel limit)", async () => {
    const { pb, Q } = await booted();
    await pb.downloadSeason([film("a"), film("b")], Q["720p"]);
    await settle();
    expect(pb.retryDownload("f1", "Failed one", true)).toBe(true);
    expect(pb.retryDownload("f1", "Failed one")).toBe(false);
    expect(pb.getQueuedDownloads()[0]).toEqual({
      id: "f1",
      title: "Failed one",
      series: null,
      season: null,
      episode: null,
      quality: "retrying",
      retry: true,
      reason: undefined,
      retryAt: undefined,
      transcode: true,
    });
    expect(retries()).toEqual([]);
    progress("a", "complete");
    await settle();
    expect(retries()).toEqual([{ itemId: "f1", manual: true }]);
    expect(queued(pb)).toEqual(["b"]);
  });

  it("a retry for what is already running is refused", async () => {
    const { pb, Q } = await booted();
    await pb.startDownload(film("a"), Q["720p"]);
    expect(pb.retryDownload("a")).toBe(false);
  });

  it("retryFailedDownloads queues them in the order listed, once each, and runs them one at a time", async () => {
    const { pb } = await booted();
    const n = pb.retryFailedDownloads([
      { item_id: "x", title: "X" },
      { item_id: "y" },
      { item_id: "x" },
      { item_id: "" },
      null as any,
      { item_id: "z", transcode: true },
    ]);
    expect(n).toBe(3);
    await settle();
    expect(retries()).toEqual([{ itemId: "x", manual: true }]);
    expect(queued(pb)).toEqual(["y", "z"]);
    expect(pb.getQueuedDownloads()[0]!.title).toBe("y");
    expect(pb.retryFailedDownloads([{ item_id: "y" }])).toBe(0);
  });

  it("a failure the backend will retry comes back after its wait, at the front, and is not manual", async () => {
    const { pb, Q } = await booted();
    await pb.downloadSeason([film("a"), film("b")], Q["720p"]);
    await settle();
    const t0 = Date.now();
    progress("a", "error", { retry_in: 30, message: "stalled for 90 s — trying again" });
    await settle();
    // The slot it held is free for b meanwhile.
    expect(starts()).toEqual(["a", "b"]);
    expect(pb.getQueuedDownloads()[0]).toMatchObject({
      id: "a",
      title: "Film a",
      retry: true,
      reason: "stalled for 90 s — trying again",
      retryAt: t0 + 30_000,
      transcode: true,
    });
    expect(invokeCalls("ui_log").some((c) => c.args.msg === "download a: retry in 30s (stalled for 90 s — trying again)")).toBe(true);
    progress("b", "complete");
    await settle();
    expect(retries()).toEqual([]);
    await vi.advanceTimersByTimeAsync(30_000 + 50);
    expect(retries()).toEqual([{ itemId: "a", manual: false }]);
  });

  it("pressing Retry on one waiting out its back-off starts it now, as a manual retry", async () => {
    const { pb, Q } = await booted();
    await pb.startDownload(film("a"), Q["720p"]);
    progress("a", "error", { retry_in: 300, message: "dropped" });
    await settle();
    expect(retries()).toEqual([]);
    expect(pb.retryDownload("a")).toBe(true);
    await settle();
    expect(retries()).toEqual([{ itemId: "a", manual: true }]);
  });

  it("a failure the backend gives up on stays in Failed, and the queue moves on", async () => {
    const { pb, Q } = await booted();
    await pb.downloadSeason([film("a"), film("b")], Q["720p"]);
    await settle();
    progress("a", "error", { message: "gone" });
    await settle();
    expect(starts()).toEqual(["a", "b"]);
    expect(queued(pb)).toEqual([]);
  });

  it("an automatic retry for something already queued again is not doubled", async () => {
    const { pb, Q } = await booted();
    await pb.startDownload(film("a"), Q["720p"]);
    pb.retryDownload("zz");
    progress("zz", "error", { retry_in: 5, message: "m" });
    await settle();
    expect(queued(pb).filter((id) => id === "zz")).toHaveLength(1);
  });

  it("progress that is not an ending, and an ending for a download it does not own, start nothing", async () => {
    const { pb, Q } = await booted();
    await pb.downloadSeason([film("a"), film("b")], Q["720p"]);
    await settle();
    progress("a", "downloading");
    progress("stranger", "complete");
    await settle();
    expect(starts()).toEqual(["a"]);
    // A paused event is an ending too.
    progress("a", "paused");
    await settle();
    expect(starts()).toEqual(["a", "b"]);
  });

  it("a retry the backend refuses is reported and dropped", async () => {
    const { pb } = await booted();
    onInvoke("download_retry", () => {
      throw "no meta.json";
    });
    pb.retryDownload("x", "Lost one");
    await settle();
    expect(errorToasts()).toEqual(["Couldn't start Lost one: no meta.json"]);
    expect(pb.retryDownload("x")).toBe(true);
  });
});

describe("Pause all", () => {
  it("sets the running transfers aside at the front of the queue and holds everything", async () => {
    const { pb, Q } = await booted();
    await pb.downloadSeason([film("a"), film("b")], Q["720p"]);
    await settle();
    await pb.setDownloadsPaused(true);
    expect(invokeCalls("config_save").map((c) => c.args.cfg)).toContainEqual({ downloads_paused: true });
    expect(invokeCalls("download_pause").map((c) => c.args)).toEqual([{ itemId: "a" }]);
    expect(pb.isDownloadsPaused()).toBe(true);
    expect(pb.downloadHoldReason()).toBe("Downloads are paused");
    expect(pb.getQueuedDownloads().map((p) => [p.id, p.reason ?? null])).toEqual([
      ["a", "Paused"],
      ["b", null],
    ]);
    expect(pb.getQueuedDownloads()[0]).toMatchObject({ title: "Film a", transcode: true });
    // The backend's paused event frees the slot, but nothing starts.
    progress("a", "paused");
    await settle();
    expect(retries()).toEqual([]);
    expect(starts()).toEqual(["a"]);
  });

  it("resuming clears the Paused reason and carries on from the .part file", async () => {
    const { pb, Q } = await booted();
    await pb.startDownload(film("a"), Q["720p"]);
    await pb.setDownloadsPaused(true);
    progress("a", "paused");
    await settle();
    await pb.setDownloadsPaused(false);
    await settle();
    expect(pb.isDownloadsPaused()).toBe(false);
    expect(pb.downloadHoldReason()).toBeNull();
    expect(retries()).toEqual([{ itemId: "a", manual: false }]);
  });

  it("asking for the state it is already in does nothing", async () => {
    const { pb } = await booted();
    await pb.setDownloadsPaused(false);
    expect(invokeCalls("config_save")).toHaveLength(0);
  });

  it("pausing with nothing running only saves the setting, and a running item already queued is not doubled", async () => {
    const { pb } = await booted();
    await pb.setDownloadsPaused(true);
    expect(invokeCalls("download_pause")).toHaveLength(0);
    await pb.setDownloadsPaused(false);
    pb.retryDownload("r1");
    await settle();
    pb.retryDownload("r1");
    await pb.setDownloadsPaused(true);
    expect(invokeCalls("download_pause")).toHaveLength(1);
    expect(queued(pb)).toEqual(["r1"]);
  });

  it("a pause that fails to reach the backend still holds the queue", async () => {
    const { pb, Q } = await booted();
    onInvoke("download_pause", () => {
      throw "gone";
    });
    await pb.startDownload(film("a"), Q["720p"]);
    await expect(pb.setDownloadsPaused(true)).resolves.toBeUndefined();
    expect(queued(pb)).toEqual(["a"]);
  });
});

describe("only on unmetered connections", () => {
  it("holds the queue on a metered connection and sets running transfers aside", async () => {
    const { pb, Q } = await booted({ config: { downloads_unmetered_only: true } });
    await pb.startDownload(film("a"), Q["720p"]);
    expect(starts()).toEqual(["a"]);
    emitEvent("network-metered", true);
    expect(pb.downloadHoldReason()).toBe("Waiting for an unmetered connection");
    expect(invokeCalls("download_pause").map((c) => c.args)).toEqual([{ itemId: "a" }]);
    expect(pb.getQueuedDownloads()[0]!.reason).toBe("Waiting for an unmetered connection");
    progress("a", "paused");
    await settle();
    expect(retries()).toEqual([]);
    emitEvent("network-metered", false);
    await settle();
    expect(pb.getQueuedDownloads()).toEqual([]);
    expect(retries()).toEqual([{ itemId: "a", manual: false }]);
  });

  it("reads the connection's state when the queue first wakes", async () => {
    const { pb, Q } = await booted({ config: { downloads_unmetered_only: true } });
    onInvoke("network_metered", true);
    await pb.startDownload(film("a"), Q["720p"]);
    await settle();
    expect(pb.downloadHoldReason()).toBe("Waiting for an unmetered connection");
  });

  it("is ignored on a metered connection when the setting is off, and applies at once when it is turned on", async () => {
    const { pb, api, Q } = await booted();
    onInvoke("network_metered", true);
    await pb.startDownload(film("a"), Q["720p"]);
    await settle();
    expect(pb.downloadHoldReason()).toBeNull();
    await api.saveConfig({ downloads_unmetered_only: true });
    pb.downloadPrefsChanged();
    expect(pb.downloadHoldReason()).toBe("Waiting for an unmetered connection");
    expect(invokeCalls("downloads_sync_keep_awake")).toHaveLength(1);
    expect(queued(pb)).toEqual(["a"]);
    await api.saveConfig({ downloads_unmetered_only: false });
    pb.downloadPrefsChanged();
    pb.downloadPrefsChanged();
    await settle();
    expect(pb.getQueuedDownloads()[0]?.reason).toBeUndefined();
  });

  it("a backend that cannot tell is taken as unmetered", async () => {
    const { pb, Q } = await booted({ config: { downloads_unmetered_only: true } });
    onInvoke("network_metered", () => {
      throw "no NetworkManager";
    });
    onInvoke("downloads_sync_keep_awake", () => {
      throw "no logind";
    });
    pb.downloadPrefsChanged();
    await pb.startDownload(film("a"), Q["720p"]);
    expect(starts()).toEqual(["a"]);
  });
});

describe("one transcode at a time", () => {
  it("holds a second transcode while one runs, and lets originals run alongside", async () => {
    const { pb, Q } = await booted({ config: { downloads_transcode_serial: true } });
    pb.setDownloadConcurrency(3);
    await pb.downloadSeason(
      [film("t1"), film("t2"), film("o1", { MediaSources: [{ Size: 1e8 }] })],
      Q["720p"]
    );
    await settle();
    expect(starts()).toEqual(["t1", "o1"]);
    const waiting = pb.getQueuedDownloads();
    expect(waiting.map((p) => p.id)).toEqual(["t2"]);
    expect(pb.isWaitingForTranscode(waiting[0]!)).toBe(true);
    progress("t1", "complete");
    await settle();
    expect(starts()).toEqual(["t1", "o1", "t2"]);
  });

  it("isWaitingForTranscode is false with the setting off, for an original, and with no transcode running", async () => {
    const { pb } = await booted();
    const p = { id: "x", title: "x", series: null, season: null, episode: null, quality: "q", transcode: true };
    expect(pb.isWaitingForTranscode(p)).toBe(false);
    const on = await booted({ config: { downloads_transcode_serial: true } });
    expect(on.pb.isWaitingForTranscode(p)).toBe(false);
    expect(on.pb.isWaitingForTranscode({ ...p, transcode: false })).toBe(false);
  });

  it("a retry counts as a transcode when it was one", async () => {
    const { pb, Q } = await booted({ config: { downloads_transcode_serial: true } });
    pb.setDownloadConcurrency(3);
    await pb.startDownload(film("t1"), Q["720p"]);
    pb.retryFailedDownloads([{ item_id: "r1", transcode: true }, { item_id: "r2", transcode: false }]);
    await settle();
    expect(retries().map((r) => r.itemId)).toEqual(["r2"]);
  });
});

describe("isTranscodeDownload", () => {
  it("reads the stored request, or failing that the quality label", async () => {
    const { pb } = await booted();
    expect(pb.isTranscodeDownload({ request: { url: `${SERVER}/Items/a/Download` } })).toBe(false);
    expect(pb.isTranscodeDownload({ request: { url: `${SERVER}/Items/a/Download?x=1` } })).toBe(false);
    expect(pb.isTranscodeDownload({ request: { url: `${SERVER}/Videos/a/stream.mkv?static=false` } })).toBe(true);
    expect(pb.isTranscodeDownload({ quality: "Original quality" })).toBe(false);
    expect(pb.isTranscodeDownload({ quality: "720p · 4.5 Mbps" })).toBe(true);
    expect(pb.isTranscodeDownload(null)).toBe(true);
  });
});

describe("offline", () => {
  it("holds the queue while the server is unreachable, and carries on when it is back", async () => {
    const { pb, api, Q } = await booted();
    onInvoke("jf_ping", false);
    await api.checkOnline();
    expect(api.isOffline()).toBe(true);
    await pb.downloadSeason([film("a")], Q["720p"]);
    await settle();
    expect(starts()).toEqual([]);
    onInvoke("jf_ping", true);
    await api.checkOnline();
    await settle();
    expect(starts()).toEqual(["a"]);
  });
});

describe("restoreDownloadQueue", () => {
  const save = (entries: any[]) => localStorage.setItem("aquarium-dl-queue", JSON.stringify(entries));

  it("does nothing signed out", async () => {
    const { pb } = await boot({ signedIn: false });
    save([{ item: film("a"), q: { label: "720p" } }]);
    await pb.restoreDownloadQueue();
    expect(queued(pb)).toEqual([]);
    expect(invokeCalls("downloads_list")).toHaveLength(0);
  });

  it("brings back what was waiting, minus what has finished since, and starts it", async () => {
    const { pb, state, Q } = await booted();
    state.downloads = [download("done")];
    save([
      { item: film("done"), q: Q["720p"] },
      { item: film("a"), q: Q["720p"] },
      { item: film("a"), q: Q["720p"] },
      { kind: "retry", id: "r", title: "R" },
      null,
      { item: {} , q: Q["720p"] },
    ]);
    await pb.restoreDownloadQueue();
    await settle();
    expect(starts()).toEqual(["a"]);
    expect(queued(pb)).toEqual(["r"]);
  });

  it("a corrupt or odd saved queue is dropped, and the bridge still starts", async () => {
    const { pb } = await booted();
    localStorage.setItem("aquarium-dl-queue", "{oops");
    await pb.restoreDownloadQueue();
    expect(queued(pb)).toEqual([]);
    localStorage.setItem("aquarium-dl-queue", '{"not":"a list"}');
    await pb.restoreDownloadQueue();
    expect(queued(pb)).toEqual([]);
    // The bridge is listening: an automatic retry is picked up.
    progress("x", "error", { retry_in: 1, message: "m" });
    expect(queued(pb)).toEqual(["x"]);
  });

  it("adopts what the backend resumed at launch, instead of starting a second transfer beside it", async () => {
    const { pb, state, Q } = await booted();
    state.downloads = [
      download("live", { status: "downloading", title: "Live one", request: { url: `${SERVER}/Videos/live/stream.mkv` } }),
    ];
    save([{ item: film("a"), q: Q["720p"] }]);
    await pb.restoreDownloadQueue();
    await settle();
    expect(starts()).toEqual([]);
    progress("live", "complete");
    await settle();
    expect(starts()).toEqual(["a"]);
  });

  it("rechecks after 5 s in case the resumed transfer ended before the listener was there (regression: queue stalled for good)", async () => {
    const { pb, state, Q } = await booted();
    state.downloads = [download("live", { status: "downloading" })];
    save([{ item: film("a"), q: Q["720p"] }]);
    await pb.restoreDownloadQueue();
    state.downloads = [download("live", { status: "complete" })];
    await vi.advanceTimersByTimeAsync(4_999);
    expect(starts()).toEqual([]);
    await vi.advanceTimersByTimeAsync(1);
    await settle();
    expect(starts()).toEqual(["a"]);
  });

  it("the recheck leaves a transfer that is still running alone, and survives a failing list", async () => {
    const { pb, state, Q } = await booted();
    state.downloads = [download("live", { status: "downloading" }), download("gone", { status: "downloading" })];
    save([{ item: film("a"), q: Q["720p"] }]);
    await pb.restoreDownloadQueue();
    progress("gone", "complete");
    await settle();
    await vi.advanceTimersByTimeAsync(5_000);
    await settle();
    expect(starts()).toEqual([]);

    const b = await booted();
    b.state.downloads = [download("live", { status: "downloading" })];
    await b.pb.restoreDownloadQueue();
    onInvoke("downloads_list", () => {
      throw "io";
    });
    await vi.advanceTimersByTimeAsync(5_000);
    expect(errorToasts()).toEqual([]);
  });

  it("sets aside a transfer the backend resumed while downloads are paused", async () => {
    const { pb, state } = await booted({ config: { downloads_paused: true } });
    state.downloads = [download("live", { status: "downloading", name: "Named", title: undefined, quality: "Original quality" })];
    await pb.restoreDownloadQueue();
    expect(invokeCalls("download_pause").map((c) => c.args)).toEqual([{ itemId: "live" }]);
    expect(pb.getQueuedDownloads()[0]).toMatchObject({ id: "live", title: "Named", reason: "Paused", transcode: false });
  });

  it("or while on a metered connection with the setting on", async () => {
    const { pb, state } = await booted({ config: { downloads_unmetered_only: true } });
    onInvoke("network_metered", true);
    state.downloads = [download("live", { status: "downloading", title: undefined, quality: "720p · 4.5 Mbps" })];
    // The bridge (and the metered reading) is already up from an earlier call.
    pb.downloadPrefsChanged();
    await settle();
    await pb.restoreDownloadQueue();
    expect(pb.getQueuedDownloads()[0]).toMatchObject({
      id: "live",
      title: "live",
      reason: "Waiting for an unmetered connection",
      transcode: true,
    });
  });

  it("a failing downloads list restores everything that was saved", async () => {
    const { pb, Q } = await booted({ config: { downloads_paused: true } });
    onInvoke("downloads_list", () => {
      throw "io";
    });
    save([{ item: film("a"), q: Q["720p"] }]);
    await pb.restoreDownloadQueue();
    expect(queued(pb)).toEqual(["a"]);
  });
});
