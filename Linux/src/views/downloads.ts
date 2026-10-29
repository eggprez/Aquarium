import { invoke, convertFileSrc } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import * as api from "../api";
import {
  playLocal,
  startLocalShuffle,
  syncOfflineProgress,
  getQueuedDownloads,
  cancelQueuedDownload,
  clearDownloadQueue,
  retryDownload,
  retryFailedDownloads,
  getDownloadConcurrency,
  setDownloadConcurrency,
  MAX_DOWNLOAD_CONCURRENCY,
  isDownloadsPaused,
  setDownloadsPaused,
  downloadHoldReason,
  isWaitingForTranscode,
  isTranscodeDownload,
  itemTitle,
  type PendingDownload,
} from "../playback";
import {
  el,
  clear,
  asButton,
  art,
  toast,
  attachContextMenu,
  emptyState,
  icon,
  skeletonGrid,
  openDialog,
  openActionMenu,
  type MenuAction,
} from "../ui";

type Tab = "tv" | "movies" | "queue";

let activeTab: Tab = "tv";
let openSeries: string | null = null;
let openSeason: number | null = null;
let currentRoot: HTMLElement | null = null;
let queueListenerInstalled = false;
let playbackListenerInstalled = false;
let deleteKeyInstalled = false;
/** Guards the self-heal re-render below against stacking up on progress ticks. */
let healingQueueTab = false;
/** Bumped by every `renderDownloads`, so only the latest one paints. */
let renderSeq = 0;

// ---------- Helpers ----------

function isEpisode(dl: any): boolean {
  return dl.type === "Episode" || (!!dl.series && dl.type !== "Movie");
}

function completedSub(dl: any): string {
  const s: string[] = [];
  if (dl.quality) s.push(dl.quality);
  if (dl.size_bytes) s.push(api.bytesToText(dl.size_bytes));
  if (dl.played) s.push("watched");
  else if (dl.position_ticks > 0 && dl.run_time_ticks) {
    s.push(`resume at ${api.ticksToText(dl.position_ticks)}`);
  }
  return s.join(" · ");
}

function dlRow(
  posterPath: string | undefined,
  title: string,
  bodyExtra: (Node | null)[],
  actions: HTMLElement,
  posterExtra: (Node | null)[] = []
): HTMLElement {
  return el("div", { class: "dl-row" }, [
    el("div", { class: "dl-poster" }, [
      posterPath ? art(convertFileSrc(posterPath), title) : null,
      ...posterExtra,
    ]),
    el("div", { class: "dl-body" }, [el("h4", {}, [title]), ...bodyExtra]),
    actions,
  ]);
}

/**
 * How much of a group of episodes has been watched, 0–1. Played episodes
 * count as 1, an in-progress episode as its fraction — so one episode at 66%
 * already puts a strip on the series/season card.
 */
function watchFraction(eps: any[]): number {
  if (!eps.length) return 0;
  let sum = 0;
  for (const e of eps) {
    if (e.played) sum += 1;
    else if (e.position_ticks > 0 && e.run_time_ticks) {
      sum += Math.min(1, e.position_ticks / e.run_time_ticks);
    }
  }
  return sum / eps.length;
}

/** ✓ badge / watch-progress strip for a downloaded item's poster. */
function watchedOverlay(dl: any): (Node | null)[] {
  const pct =
    !dl.played && dl.position_ticks > 0 && dl.run_time_ticks
      ? Math.min(100, (dl.position_ticks / dl.run_time_ticks) * 100)
      : 0;
  return [
    pct > 1 ? el("div", { class: "progress-strip" }, [el("div", { style: `width:${pct}%` })]) : null,
    dl.played ? el("div", { class: "badge played" }, [icon("check")]) : null,
  ];
}

function libCard(opts: {
  posterPath?: string;
  title: string;
  sub: string;
  overlay?: boolean;
  /** ✓ badge (fully watched). */
  played?: boolean;
  /** 0–100 progress strip along the poster bottom. */
  progressPct?: number | null;
  onOpen: () => void;
  onDelete?: () => void;
  /** Renders a shuffle badge on the poster (series cards). */
  onShuffle?: () => void;
  /** Right-click menu contents. */
  actions?: () => MenuAction[];
  /** Title shown at the top of that menu. */
  menuTitle?: string;
  /** What the Delete key removes while this card is selected. */
  deletes?: { ids: string[]; what: string };
}): HTMLElement {
  const pct = opts.progressPct ?? 0;
  const poster = el("div", { class: "card-poster" }, [
    art(opts.posterPath ? convertFileSrc(opts.posterPath) : null, opts.title),
    pct > 1 ? el("div", { class: "progress-strip" }, [el("div", { style: `width:${pct}%` })]) : null,
    opts.played ? el("div", { class: "badge played" }, [icon("check")]) : null,
    opts.overlay
      ? el("div", { class: "play-overlay" }, [
          el("button", { class: "pbtn", "aria-label": `Play ${opts.title}` }, [icon("play", 20)]),
        ])
      : null,
    opts.onDelete
      ? el("button", {
          class: "dl-del-badge",
          title: "Delete download",
          onClick: (ev: MouseEvent) => {
            ev.stopPropagation();
            opts.onDelete!();
          },
        }, [icon("close", 15)])
      : null,
    opts.onShuffle
      ? el("button", {
          class: "dl-shuffle-badge",
          title: "Shuffle play",
          onClick: (ev: MouseEvent) => {
            ev.stopPropagation();
            opts.onShuffle!();
          },
        }, [icon("shuffle", 14)])
      : null,
  ]);
  const card = el("div", {
    class: "card",
    "aria-label": opts.sub ? `${opts.title} — ${opts.sub}` : opts.title,
    onClick: opts.onOpen,
    ...asButton(opts.onOpen),
  }, [
    poster,
    el("div", { class: "card-title" }, [opts.title]),
    el("div", { class: "card-sub" }, [opts.sub]),
  ]);
  if (opts.actions) {
    attachContextMenu(card, opts.menuTitle ?? opts.title, opts.actions);
  }
  if (opts.deletes) markDeletable(card, opts.deletes.ids, opts.deletes.what);
  return card;
}

async function deleteDownload(itemId: string, root: HTMLElement): Promise<void> {
  // A retry still waiting in the queue would otherwise bring it back.
  cancelQueuedDownload(itemId);
  await invoke("download_delete", { itemId });
  toast("Download deleted");
  renderDownloads(root, { keepTab: true });
}

async function deleteMany(eps: any[], root: HTMLElement): Promise<void> {
  for (const ep of eps) {
    cancelQueuedDownload(ep.item_id);
    await invoke("download_delete", { itemId: ep.item_id }).catch(() => {});
  }
  toast(`Deleted ${eps.length} download${eps.length === 1 ? "" : "s"}`);
  renderDownloads(root, { keepTab: true });
}

function plural(n: number, noun: string): string {
  return `${n} ${noun}${n === 1 ? "" : "s"}`;
}

function bytesOf(list: any[]): number {
  return list.reduce((sum, d) => sum + (d.size_bytes ?? 0), 0);
}

/** Ask before deleting, the way the Apple app's Manage menu does: what goes,
 *  how much space it frees, and a button that says exactly what it does. */
function confirmDeletion(opts: {
  title: string;
  message: string;
  confirm: string;
  run: () => void;
}): void {
  const p = document.createElement("p");
  p.textContent = opts.message;
  openDialog({
    title: opts.title,
    body: [p],
    actions: [
      { label: "Cancel", primary: true },
      { label: opts.confirm, danger: true, run: opts.run },
    ],
  });
}

/** Films and episodes that have been watched to the end. */
function watchedDownloads(items: any[]): any[] {
  return items.filter((d) => d.status === "complete" && d.played);
}

function confirmDeleteWatched(items: any[], root: HTMLElement, where = "everything you've watched"): void {
  const watched = watchedDownloads(items);
  if (!watched.length) {
    toast("Nothing watched to delete");
    return;
  }
  confirmDeletion({
    title: `Delete ${where}?`,
    message: `${plural(watched.length, "item")} · ${api.bytesToText(bytesOf(watched))}`,
    confirm: `Delete ${plural(watched.length, "Download")}`,
    run: () => void deleteMany(watched, root),
  });
}

/** Every download, and the queue with it. */
async function deleteEverything(root: HTMLElement): Promise<void> {
  const dropped = clearDownloadQueue();
  const items = await invoke<any[]>("downloads_list").catch(() => [] as any[]);
  for (const d of items.filter((d) => d.status === "downloading")) {
    await invoke("download_cancel", { itemId: d.item_id }).catch(() => {});
  }
  for (const d of items) {
    await invoke("download_delete", { itemId: d.item_id }).catch(() => {});
  }
  toast(
    `Deleted ${plural(items.length, "download")}` + (dropped ? ` · ${dropped} queued dropped` : ""),
    "ok"
  );
  renderDownloads(root, { keepTab: true });
}

/** Show downloads in Files, selected. */
function revealInFiles(ids: string[]): void {
  void invoke("downloads_reveal", { itemIds: ids }).catch((e) =>
    toast(`Couldn't show that in Files: ${e}`, "error")
  );
}

/** Mark a card or row as something the Delete key removes while it has
 *  focus (a click on it focuses it). */
function markDeletable(node: HTMLElement, ids: string[], what: string): void {
  node.dataset.dlIds = ids.join(",");
  node.dataset.dlWhat = what;
  if (!node.hasAttribute("tabindex")) node.tabIndex = 0;
}

/** Delete removes the selected card or row, after asking. Installed once. */
function installDeleteKey(): void {
  if (deleteKeyInstalled) return;
  deleteKeyInstalled = true;
  document.addEventListener("keydown", (ev) => {
    if (ev.key !== "Delete" || ev.defaultPrevented) return;
    const root = currentRoot;
    if (!root || !document.contains(root) || !root.querySelector(".dl-tabs")) return;
    const target = (document.activeElement as HTMLElement | null)?.closest<HTMLElement>("[data-dl-ids]");
    if (!target || !root.contains(target) || document.querySelector(".dialog-scrim")) return;
    ev.preventDefault();
    const ids = (target.dataset.dlIds ?? "").split(",").filter(Boolean);
    if (!ids.length) return;
    const what = target.dataset.dlWhat ?? "this download";
    confirmDeletion({
      title: `Delete ${what}?`,
      message: ids.length === 1 ? "The file is removed from this computer." : `${plural(ids.length, "download")} are removed from this computer.`,
      confirm: ids.length === 1 ? "Delete" : `Delete ${ids.length}`,
      run: () => void deleteMany(ids.map((item_id) => ({ item_id })), root),
    });
  });
}

/** Episodes in watching order. */
function inOrder(eps: any[]): any[] {
  return [...eps].sort(
    (a, b) => (a.season ?? 0) - (b.season ?? 0) || (a.episode ?? 0) - (b.episode ?? 0)
  );
}

/** The episode "Play Next" means: the first one not watched to the end (an
 *  episode part-way through counts, and resumes), or null when all are. */
function nextUnwatched(eps: any[]): any | null {
  return inOrder(eps.filter((e) => e.status === "complete" && e.path)).find((e) => !e.played) ?? null;
}

/** Play Next when something's unwatched, otherwise Play from the start of the
 *  first episode. Null when nothing in the group is playable. */
function playNextAction(eps: any[]): MenuAction | null {
  const next = nextUnwatched(eps);
  if (next) {
    const code = next.episode != null ? ` (E${next.episode})` : "";
    return { label: `Play Next${code}`, icon: "play", run: () => playLocal(next) };
  }
  const first = inOrder(eps.filter((e) => e.status === "complete" && e.path))[0];
  return first
    ? { label: "Play from the Start", icon: "play", run: () => playLocal({ ...first, position_ticks: 0 }) }
    : null;
}

function playNextButton(eps: any[]): HTMLElement | null {
  const a = playNextAction(eps);
  if (!a) return null;
  const next = nextUnwatched(eps);
  return el("button", {
    class: "btn small primary",
    title: next ? "Play the Next Unwatched Episode" : "Play from the Start",
    onClick: () => void a.run?.(),
  }, [icon("play"), next ? "Play Next" : "Play"]);
}

/** Danger button that arms on first click ("Delete N episodes?") and only
 *  deletes on a second click within a few seconds. */
function deleteAllButton(
  label: string,
  count: number,
  onConfirm: () => void,
  noun = "episode",
  verb = "Delete"
): HTMLElement {
  const btn = el("button", { class: "btn small danger" }, [label]);
  let armed = false;
  let timer = 0;
  btn.addEventListener("click", () => {
    if (!armed) {
      armed = true;
      btn.textContent = `${verb} ${count} ${noun}${count === 1 ? "" : "s"}?`;
      timer = window.setTimeout(() => {
        armed = false;
        btn.textContent = label;
      }, 4000);
    } else {
      clearTimeout(timer);
      btn.textContent = "Working…";
      (btn as HTMLButtonElement).disabled = true;
      onConfirm();
    }
  });
  return btn;
}

/**
 * Empty the download queue: drop everything still waiting and cancel whatever
 * is mid-transfer. Files already downloaded are left alone.
 */
async function clearQueue(root: HTMLElement): Promise<void> {
  const dropped = clearDownloadQueue();
  // Re-read rather than trusting the render-time snapshot: the queue may have
  // started another item since this view was painted.
  const items = await invoke<any[]>("downloads_list").catch(() => []);
  const running = items.filter((d) => d.status === "downloading");
  for (const dl of running) {
    await invoke("download_cancel", { itemId: dl.item_id }).catch(() => {});
  }
  const bits = [
    running.length ? `${running.length} in progress cancelled` : null,
    dropped ? `${dropped} queued item${dropped === 1 ? "" : "s"} dropped` : null,
  ].filter(Boolean);
  toast(bits.length ? `Queue cleared · ${bits.join(" · ")}` : "Queue was already empty", "ok");
  renderDownloads(root, { keepTab: true });
}

// ---------- Context menus (downloaded items) ----------

/** Watched/unwatched for a downloaded file: writes meta.json and queues the
 *  change for the next server sync (same path playback progress takes). */
async function setLocalPlayed(dl: any, played: boolean, root: HTMLElement): Promise<void> {
  try {
    // Either way the resume point is cleared — that's what the toggle means.
    await invoke("progress_store_local", { itemId: dl.item_id, positionTicks: 0, played });
    document.dispatchEvent(new CustomEvent("aquarium-progress-queue"));
    dl.played = played;
    dl.position_ticks = 0;
    toast(played ? "Marked watched" : "Marked unwatched", "ok");
    renderDownloads(root, { keepTab: true });
  } catch (e: any) {
    toast(e.message ?? String(e), "error");
  }
}

/** Right-click actions for one downloaded item. */
function localActions(dl: any, root: HTMLElement): MenuAction[] {
  const out: MenuAction[] = [];
  if (dl.path) {
    const resume = !dl.played && dl.position_ticks > 0;
    if (resume) {
      out.push({
        label: `Resume (${api.ticksToText(dl.position_ticks)} in)`,
        icon: "play",
        run: () => playLocal(dl),
      });
      out.push({ label: "Play from start", run: () => playLocal({ ...dl, position_ticks: 0 }) });
    } else {
      out.push({ label: "Play", icon: "play", run: () => playLocal({ ...dl, position_ticks: 0 }) });
    }
  }
  out.push({
    label: dl.played ? "Mark unwatched" : "Mark watched",
    icon: "check",
    run: () => setLocalPlayed(dl, !dl.played, root),
  });
  if (dl.item_id && api.getSession()) {
    out.push({
      label: "Show details",
      icon: "library",
      run: () => {
        location.hash = `#/item/${dl.item_id}`;
      },
    });
  }
  if (dl.path) {
    out.push({ label: "Show in Files", icon: "folder", run: () => revealInFiles([dl.item_id]) });
  }
  out.push({
    label: "Delete download",
    icon: "trash",
    danger: true,
    run: () => deleteDownload(dl.item_id, root),
  });
  return out;
}

/** Right-click actions for a group card (a series or a season). */
function groupActions(eps: any[], label: string, root: HTMLElement): MenuAction[] {
  const playable = eps.filter((e) => e.status === "complete" && e.path);
  const allPlayed = eps.every((e) => e.played);
  const watched = watchedDownloads(eps);
  return [
    playNextAction(eps),
    playable.length
      ? {
          label: label === "season" ? "Shuffle this season" : "Shuffle",
          icon: "shuffle",
          run: () => startLocalShuffle(playable),
        }
      : null,
    playable.length
      ? { label: "Show in Files", icon: "folder", run: () => revealInFiles(playable.map((e) => e.item_id)) }
      : null,
    {
      label: allPlayed ? `Mark ${label} unwatched` : `Mark ${label} watched`,
      icon: "check",
      run: async () => {
        for (const e of eps) {
          await invoke("progress_store_local", {
            itemId: e.item_id,
            positionTicks: 0,
            played: !allPlayed,
          }).catch(() => {});
          e.played = !allPlayed;
          e.position_ticks = 0;
        }
        document.dispatchEvent(new CustomEvent("aquarium-progress-queue"));
        toast(`Marked ${eps.length} episode${eps.length === 1 ? "" : "s"} ${allPlayed ? "unwatched" : "watched"}`, "ok");
        renderDownloads(root, { keepTab: true });
      },
    },
    watched.length && watched.length < eps.length
      ? {
          label: `Delete watched episodes (${watched.length})`,
          icon: "trash",
          danger: true,
          run: () => confirmDeleteWatched(eps, root, `the watched episodes of this ${label}`),
        }
      : null,
    { label: `Delete ${label}`, danger: true, run: () => deleteMany(eps, root) },
  ].filter(Boolean) as MenuAction[];
}

/** How many queued downloads may run at once. */
function concurrencySelector(): HTMLElement {
  const current = getDownloadConcurrency();
  const select = el("select", { class: "control", title: "How many queued downloads run at the same time" });
  for (let n = 1; n <= MAX_DOWNLOAD_CONCURRENCY; n++) {
    select.append(
      el("option", { value: String(n), ...(n === current ? { selected: "selected" } : {}) }, [
        n === 1 ? "1 at a time" : `${n} at a time`,
      ])
    );
  }
  select.addEventListener("change", () => {
    const n = parseInt(select.value, 10);
    setDownloadConcurrency(n);
    toast(n === 1 ? "Downloading one at a time" : `Downloading up to ${n} at a time`, "ok");
  });
  return el("label", { class: "dl-concurrency-wrap" }, [
    el("span", {}, ["Parallel"]),
    select,
  ]);
}

// ---------- Tabs ----------

function renderTvTab(pane: HTMLElement, tv: any[], root: HTMLElement): void {
  clear(pane);
  if (!tv.length) {
    pane.append(
      emptyState({
        icon: "download",
        title: "No TV downloads yet",
        body: "Right-click an episode, a season or a whole series and pick “Download” — anything saved here plays without the server.",
        action: { label: "Browse shows", run: () => (location.hash = "#/home") },
      })
    );
    return;
  }

  // Group episodes by series name.
  const groups = new Map<string, any[]>();
  for (const dl of tv) {
    const key = dl.series ?? dl.title ?? dl.name ?? dl.item_id;
    (groups.get(key) ?? groups.set(key, []).get(key)!).push(dl);
  }

  if (openSeries && !groups.has(openSeries)) {
    openSeries = null;
    openSeason = null;
  }

  if (!openSeries) {
    // Series grid.
    const grid = el("div", { class: "card-grid" });
    for (const [series, eps] of [...groups].sort((a, b) => a[0].localeCompare(b[0]))) {
      // Prefer the portrait series poster; fall back to an episode still.
      const poster =
        eps.find((e) => e.series_poster_path)?.series_poster_path ??
        eps.find((e) => e.poster_path)?.poster_path;
      const watched = eps.filter((e) => e.played).length;
      const frac = watchFraction(eps);
      grid.append(
        libCard({
          posterPath: poster,
          title: series,
          sub:
            `${eps.length} episode${eps.length === 1 ? "" : "s"}` +
            (watched ? ` · ${watched} watched` : ""),
          played: watched === eps.length,
          progressPct: frac > 0 && frac < 1 ? frac * 100 : null,
          onOpen: () => {
            openSeries = series;
            openSeason = null;
            renderTvTab(pane, tv, root);
          },
          onShuffle: () => startLocalShuffle(eps),
          actions: () => groupActions(eps, "series", root),
          deletes: {
            ids: eps.map((e) => e.item_id),
            what: eps.length === 1 ? `the episode of “${series}”` : `all ${eps.length} episodes of “${series}”`,
          },
        })
      );
    }
    pane.append(grid);
    return;
  }

  const eps = groups.get(openSeries)!;
  const bySeason = new Map<number, any[]>();
  for (const ep of eps) {
    const s = typeof ep.season === "number" ? ep.season : -1;
    (bySeason.get(s) ?? bySeason.set(s, []).get(s)!).push(ep);
  }
  for (const list of bySeason.values()) {
    list.sort((a, b) => (a.episode ?? 0) - (b.episode ?? 0));
  }
  if (openSeason != null && !bySeason.has(openSeason)) openSeason = null;

  const seasonTitle = (n: number) => (n >= 0 ? `Season ${n}` : "Episodes");
  // The breadcrumb links back up a level.
  const toAllShows = (): void => {
    openSeries = null;
    renderTvTab(pane, tv, root);
  };
  const toSeasons = (): void => {
    openSeason = null;
    renderTvTab(pane, tv, root);
  };

  if (openSeason == null) {
    // One series: a grid of its downloaded seasons.
    pane.append(
      el("div", { class: "lib-crumb" }, [
        el("a", {
          onClick: toAllShows,
          ...asButton(toAllShows),
        }, [icon("arrow-left"), "All shows"]),
        el("span", {}, [openSeries]),
        el("span", { class: "row-actions" }, [
          playNextButton(eps),
          el("button", {
            class: "btn small",
            title: "Play every downloaded episode in random order",
            onClick: () => startLocalShuffle(eps),
          }, [icon("shuffle"), `Shuffle ${eps.length} episode${eps.length === 1 ? "" : "s"}`]),
          el("button", {
            class: "btn small",
            title: "Show these downloads in Files",
            onClick: () => revealInFiles(eps.map((e) => e.item_id)),
          }, [icon("folder"), "Show in Files"]),
          deleteAllButton("Delete series", eps.length, () => deleteMany(eps, root)),
        ]),
      ])
    );
    const grid = el("div", { class: "card-grid" });
    for (const [season, list] of [...bySeason].sort((a, b) => a[0] - b[0])) {
      const poster =
        list.find((e) => e.season_poster_path)?.season_poster_path ??
        list.find((e) => e.series_poster_path)?.series_poster_path ??
        list.find((e) => e.poster_path)?.poster_path;
      const watched = list.filter((e) => e.played).length;
      const frac = watchFraction(list);
      grid.append(
        libCard({
          posterPath: poster,
          title: seasonTitle(season),
          sub:
            `${list.length} episode${list.length === 1 ? "" : "s"}` +
            (watched ? ` · ${watched} watched` : ""),
          played: watched === list.length,
          progressPct: frac > 0 && frac < 1 ? frac * 100 : null,
          onOpen: () => {
            openSeason = season;
            renderTvTab(pane, tv, root);
          },
          actions: () => groupActions(list, "season", root),
          menuTitle: `${openSeries} · ${seasonTitle(season)}`,
          deletes: { ids: list.map((e) => e.item_id), what: `${seasonTitle(season)} of “${openSeries}”` },
        })
      );
    }
    pane.append(grid);
    return;
  }

  // One season: its episode list.
  const list = bySeason.get(openSeason)!;
  pane.append(
    el("div", { class: "lib-crumb" }, [
      el("a", {
        onClick: toSeasons,
        ...asButton(toSeasons),
      }, [icon("arrow-left"), "Seasons"]),
      el("span", {}, [`${openSeries} · ${seasonTitle(openSeason)}`]),
      el("span", { class: "row-actions" }, [
        playNextButton(list),
        el("button", {
          class: "btn small",
          title: "Play this season's episodes in random order",
          onClick: () => startLocalShuffle(list),
        }, [icon("shuffle"), "Shuffle this season"]),
        el("button", {
          class: "btn small",
          title: "Show this season in Files",
          onClick: () => revealInFiles(list.map((e) => e.item_id)),
        }, [icon("folder"), "Show in Files"]),
        deleteAllButton("Delete season", list.length, () => deleteMany(list, root)),
      ]),
    ])
  );
  for (const ep of list) {
    const code = ep.episode != null ? `${ep.episode}. ` : "";
    const actions = el("div", { class: "dl-actions" }, [
      ep.path
        ? el("button", { class: "btn small primary", onClick: () => playLocal(ep) }, [
            icon("play"),
            "Play",
          ])
        : null,
      el("button", { class: "btn small danger", onClick: () => deleteDownload(ep.item_id, root) }, ["Delete"]),
    ]);
    const row = dlRow(
      ep.poster_path,
      `${code}${ep.name ?? ep.title ?? ep.item_id}`,
      [
        el("div", { class: "dl-sub" }, [completedSub(ep)]),
        ep.overview ? el("div", { class: "dl-overview" }, [ep.overview]) : null,
      ],
      actions,
      watchedOverlay(ep)
    );
    attachContextMenu(row, ep.name ?? ep.title ?? null, () => localActions(ep, root));
    markDeletable(row, [ep.item_id], `“${ep.name ?? ep.title ?? "this episode"}”`);
    pane.append(row);
  }
}

function renderMoviesTab(pane: HTMLElement, movies: any[], root: HTMLElement): void {
  clear(pane);
  if (!movies.length) {
    pane.append(
      emptyState({
        icon: "download",
        title: "No movie downloads yet",
        body: "Right-click any film and pick “Download” to keep a copy on this machine — useful before a flight, or when the server is unreachable.",
        action: { label: "Browse movies", run: () => (location.hash = "#/home") },
      })
    );
    return;
  }
  const grid = el("div", { class: "card-grid" });
  for (const dl of [...movies].sort((a, b) => (a.title ?? "").localeCompare(b.title ?? ""))) {
    const sub = [dl.year, dl.size_bytes ? api.bytesToText(dl.size_bytes) : null].filter(Boolean).join(" · ");
    const pct =
      !dl.played && dl.position_ticks > 0 && dl.run_time_ticks
        ? Math.min(100, (dl.position_ticks / dl.run_time_ticks) * 100)
        : null;
    grid.append(
      libCard({
        posterPath: dl.poster_path,
        title: dl.title ?? dl.name ?? dl.item_id,
        sub,
        played: !!dl.played,
        progressPct: pct,
        overlay: !!dl.path,
        onOpen: () => {
          if (dl.path) playLocal(dl);
        },
        onDelete: () => deleteDownload(dl.item_id, root),
        actions: () => localActions(dl, root),
        deletes: { ids: [dl.item_id], what: `“${dl.title ?? dl.name ?? "this film"}”` },
      })
    );
  }
  pane.append(grid);
}

function renderQueueTab(
  pane: HTMLElement,
  active: any[],
  errored: any[],
  waiting: PendingDownload[],
  root: HTMLElement
): void {
  clear(pane);
  if (!active.length && !errored.length && !waiting.length) {
    pane.append(
      emptyState({
        icon: "download",
        title: "The queue is empty",
        body: "Nothing is transferring right now. Downloads you start appear here with their progress, and resume automatically if they're interrupted.",
      })
    );
    return;
  }

  const held = downloadHoldReason();
  if (held && (active.length || waiting.length)) {
    pane.append(
      el("div", { class: "lib-crumb dl-hold" }, [
        el("span", {}, [held === "Downloads are paused" ? "Downloads are paused" : `${held} — downloads wait until there is one`]),
        isDownloadsPaused()
          ? el("span", { class: "row-actions" }, [
              el("button", { class: "btn small primary", onClick: () => void setDownloadsPaused(false) }, [
                icon("play"),
                "Resume all",
              ]),
            ])
          : null,
      ])
    );
  }

  const queued = active.length + waiting.length;
  if (queued) {
    pane.append(
      el("div", { class: "lib-crumb" }, [
        el("span", {}, [
          `${queued} download${queued === 1 ? "" : "s"} in the queue` +
            (active.length ? ` · ${active.length} running` : ""),
        ]),
        el("span", { class: "row-actions" }, [
          deleteAllButton("Clear queue", queued, () => clearQueue(root), "queued download", "Cancel"),
        ]),
      ])
    );
  }

  if (active.length) {
    pane.append(el("h3", { class: "season-group" }, ["Downloading"]));
    for (const dl of active) {
      const sub: string[] = [];
      if (dl.quality) sub.push(dl.quality);
      if (dl.estimated_bytes) sub.push(`of ~${api.bytesToText(dl.estimated_bytes)}`);
      const bar = el("div", { class: "dl-bar", "data-item": dl.item_id }, [el("div", { style: "width:0%" })]);
      const actions = el("div", { class: "dl-actions" }, [
        el("button", {
          class: "btn small danger",
          onClick: () => invoke("download_cancel", { itemId: dl.item_id }),
        }, ["Cancel"]),
      ]);
      const row = dlRow(
        dl.poster_path,
        dl.title ?? dl.name ?? dl.item_id,
        [el("div", { class: "dl-sub", "data-sub": dl.item_id }, [sub.join(" · ")]), bar],
        actions
      );
      attachContextMenu(row, dl.title ?? dl.name ?? null, () => [
        {
          label: "Cancel download",
          danger: true,
          run: () => void invoke("download_cancel", { itemId: dl.item_id }),
        },
      ]);
      pane.append(row);
    }
  }

  if (waiting.length) {
    pane.append(el("h3", { class: "season-group" }, [`Up next · ${waiting.length}`]));
    waiting.forEach((p, i) => {
      const parts: string[] = [];
      if (p.series && p.season != null && p.episode != null) parts.push(`${p.series} · S${p.season}E${p.episode}`);
      else if (p.series) parts.push(p.series);
      // A retry replays the stored request, so its quality isn't known here —
      // saying "Waiting · retrying" reads as a stutter. Name what it is.
      if (p.reason) {
        const secs = p.retryAt ? Math.ceil((p.retryAt - Date.now()) / 1000) : 0;
        parts.push(secs > 0 ? `${p.reason} in ${secs < 90 ? `${secs}s` : `${Math.round(secs / 60)} min`}` : p.reason);
      } else if (isWaitingForTranscode(p)) {
        parts.push("Waiting for the transcode ahead of it");
      } else {
        parts.push(p.retry ? "Waiting · retry of a failed download" : `Waiting · ${p.quality}`);
      }
      const actions = el("div", { class: "dl-actions" }, [
        el("span", { class: "queue-pos" }, [`#${i + 1}`]),
        el("button", { class: "btn small danger", onClick: () => cancelQueuedDownload(p.id) }, ["Remove"]),
      ]);
      const row = dlRow(undefined, p.title, [el("div", { class: "dl-sub" }, [parts.join(" · ")])], actions);
      attachContextMenu(row, p.title, () => [
        { label: "Remove from queue", danger: true, run: () => cancelQueuedDownload(p.id) },
      ]);
      pane.append(row);
    });
  }

  if (errored.length) {
    const head = el("div", { class: "dl-group-head" }, [
      el("h3", { class: "season-group" }, [`Failed · ${errored.length}`]),
    ]);
    // One click to restart everything a network drop knocked out, instead of
    // one click per episode. Queued rather than fired at once, so the parallel
    // limit still applies.
    if (errored.length > 1) {
      head.append(
        el(
          "button",
          {
            class: "btn small",
            onClick: async () => {
              const n = retryFailedDownloads(
                errored.map((d) => ({
                  item_id: d.item_id,
                  title: d.title ?? d.name,
                  transcode: isTranscodeDownload(d),
                }))
              );
              toast(
                n ? `Retrying ${n} download${n === 1 ? "" : "s"}` : "Those are already retrying",
                n ? "ok" : "error"
              );
              renderDownloads(root, { keepTab: true });
            },
          },
          [`Retry all ${errored.length}`]
        )
      );
    }
    pane.append(head);
    for (const dl of errored) {
      // Queued, not started: the parallel limit applies to a retry the same as
      // to a fresh download. It goes to the front of the queue, so with the
      // limit free it still starts immediately.
      const retry = (): void => {
        const queued = retryDownload(dl.item_id, dl.title ?? dl.name, isTranscodeDownload(dl));
        toast(
          queued ? "Queued for retry" : "That one is already retrying",
          queued ? "ok" : "error"
        );
        renderDownloads(root, { keepTab: true });
      };
      const actions = el("div", { class: "dl-actions" }, [
        el("button", { class: "btn small", onClick: retry }, [dl.status === "paused" ? "Resume" : "Retry"]),
        el("button", { class: "btn small danger", onClick: () => deleteDownload(dl.item_id, root) }, ["Delete"]),
      ]);
      const row = dlRow(
        dl.poster_path,
        dl.title ?? dl.name ?? dl.item_id,
        [el("div", { class: "dl-sub" }, [
          dl.status === "paused" ? "Paused" : `failed: ${dl.error ?? "unknown error"}`,
        ])],
        actions
      );
      attachContextMenu(row, dl.title ?? dl.name ?? null, () => [
        { label: dl.status === "paused" ? "Resume download" : "Retry download", run: retry },
        { label: "Delete", danger: true, run: () => deleteDownload(dl.item_id, root) },
      ]);
      pane.append(row);
    }
  }
}

// ---------- Server watch-state refresh ----------

/**
 * When online, pull each downloaded item's watched/resume state from Jellyfin
 * into its local meta so the Downloads view matches the server. Items with
 * local progress still waiting to sync are skipped — local wins until pushed.
 * Returns true when anything changed (the caller re-renders).
 */
async function refreshWatchState(completed: any[]): Promise<boolean> {
  if (api.isOffline() || !api.getSession() || !completed.length) return false;
  const pending = new Set(await invoke<string[]>("progress_pending_ids").catch(() => []));
  const candidates = completed.filter((d) => !pending.has(d.item_id));
  if (!candidates.length) return false;
  const fresh = await api.getUserDataByIds(candidates.map((d) => d.item_id));
  let changed = false;
  for (const d of candidates) {
    const ud = fresh.get(d.item_id);
    if (!ud) continue; // item deleted on the server — keep local state
    const played = !!ud.Played;
    const pos = played ? 0 : ud.PlaybackPositionTicks ?? 0;
    if (played === !!d.played && pos === (d.position_ticks ?? 0)) continue;
    d.played = played;
    d.position_ticks = pos;
    changed = true;
    invoke("download_set_watch_state", {
      itemId: d.item_id,
      positionTicks: pos,
      played,
    }).catch(() => {});
  }
  return changed;
}

// ---------- Details refresh ----------

const DETAILS_AT_KEY = "aquarium-dl-details-at";
const DETAILS_EVERY_MS = 6 * 60 * 60 * 1000;

/**
 * Bring each download's name, overview and artwork up to date with the
 * server — a renamed episode, a better poster picked in the dashboard, an
 * overview the metadata agent filled in after the file was saved — at most
 * once every six hours. Also fetches subtitles for downloads saved before
 * they were kept. Returns true when anything changed.
 */
async function refreshDetails(completed: any[]): Promise<boolean> {
  if (api.isOffline() || !api.getSession() || !completed.length) return false;
  let last = 0;
  try {
    last = Number(localStorage.getItem(DETAILS_AT_KEY) ?? 0);
  } catch {
    // Unreadable: refresh.
  }
  if (Date.now() - last < DETAILS_EVERY_MS) return false;
  try {
    // Before the fetch, so a server that fails it isn't asked on every render.
    localStorage.setItem(DETAILS_AT_KEY, String(Date.now()));
  } catch {
    // Quota exceeded — the next render tries again.
  }

  const fresh = await api.getItemsByIds(
    completed.map((d) => d.item_id),
    "Overview,ProductionYear"
  );
  const byId = new Map(fresh.map((it: any) => [it.Id, it]));
  let changed = false;
  for (const d of completed) {
    const it = byId.get(d.item_id);
    if (!it) continue; // gone from the server: keep what's on disk
    const patch: Record<string, any> = {
      name: it.Name ?? d.name,
      title: itemTitle(it),
      overview: it.Overview ?? null,
      series: it.SeriesName ?? d.series ?? null,
      season: it.ParentIndexNumber ?? d.season ?? null,
      episode: it.IndexNumber ?? d.episode ?? null,
      year: it.ProductionYear ?? d.year ?? null,
      run_time_ticks: it.RunTimeTicks ?? d.run_time_ticks ?? null,
      image_tag: it.ImageTags?.Primary ?? null,
      series_image_tag: it.SeriesPrimaryImageTag ?? null,
    };
    const differs = Object.keys(patch).some((k) => (d[k] ?? null) !== patch[k]);
    // Artwork only when the server's tag moved (or there's none on disk). A
    // download from before tags were kept has none recorded: note it now.
    const posterUrl =
      !d.poster_path || (d.image_tag && d.image_tag !== patch.image_tag)
        ? api.imageUrl(it, "Primary", 500)
        : null;
    const seriesUrl =
      it.Type === "Episode" &&
      (!d.series_poster_path || (d.series_image_tag && d.series_image_tag !== patch.series_image_tag))
        ? api.seriesPosterUrl(it, 500)
        : null;
    if (!differs && !posterUrl && !seriesUrl) continue;
    await invoke("download_update_details", {
      itemId: d.item_id,
      patch,
      posterUrl,
      seriesPosterUrl: seriesUrl,
    }).catch(() => {});
    changed = true;
  }
  // Subtitles for anything saved before they were kept, or whose fetch had
  // gaps. One at a time: this is housekeeping, not something to wait on.
  for (const d of completed) {
    if (d.subtitles_settled === false) {
      await invoke("download_fetch_subtitles", { itemId: d.item_id }).catch(() => {});
    }
  }
  invoke("ui_log", { msg: `downloads: details refreshed (${completed.length} items, changed=${changed})` }).catch(() => {});
  return changed;
}

// ---------- Header controls ----------

/** Pause or resume every download. Shown while there's a queue to hold, and
 *  while paused (so the way out is always on the page). */
function pauseButton(hasQueue: boolean): HTMLElement | null {
  const paused = isDownloadsPaused();
  if (!paused && !hasQueue) return null;
  return el("button", {
    class: `btn small${paused ? " primary" : ""}`,
    title: paused
      ? "Carry on with every download"
      : "Stop every download where it is; each picks up from there when resumed",
    onClick: async () => {
      await setDownloadsPaused(!paused);
      toast(paused ? "Downloads resumed" : "Downloads paused", "ok");
      if (currentRoot) renderDownloads(currentRoot, { keepTab: true });
    },
  }, [icon(paused ? "play" : "pause"), paused ? "Resume all" : "Pause all"]);
}

/** The Manage menu: the bulk actions, each asking first where it deletes. */
function manageButton(
  items: any[],
  waitingCount: number,
  errored: any[],
  root: HTMLElement
): HTMLElement {
  const btn = el("button", { class: "btn small", title: "Manage Downloads", "aria-haspopup": "menu" }, [
    "Manage",
    icon("chevron-down"),
  ]);
  btn.addEventListener("click", () => {
    const watched = watchedDownloads(items);
    const running = items.filter((d) => d.status === "downloading").length;
    const queued = waitingCount + running;
    openActionMenu(btn, null, [
      errored.length
        ? {
            label: `Retry All Failed (${errored.length})`,
            run: () => {
              const n = retryFailedDownloads(
                errored.map((d) => ({ item_id: d.item_id, title: d.title ?? d.name, transcode: isTranscodeDownload(d) }))
              );
              toast(n ? `Retrying ${plural(n, "download")}` : "Those are already retrying", n ? "ok" : "error");
            },
          }
        : null,
      queued
        ? {
            label: "Clear Queue…",
            run: () =>
              confirmDeletion({
                title: "Clear the queue?",
                message: `${plural(queued, "waiting download")} will be removed. Nothing already on this computer is affected.`,
                confirm: "Clear Queue",
                run: () => void clearQueue(root),
              }),
          }
        : null,
      watched.length
        ? { label: `Delete Watched Downloads… (${watched.length})`, icon: "trash", run: () => confirmDeleteWatched(items, root) }
        : null,
      items.length
        ? {
            label: "Delete All Downloads…",
            icon: "trash",
            danger: true,
            run: () =>
              confirmDeletion({
                title: "Delete every download?",
                message:
                  `${plural(items.length, "item")} · ${api.bytesToText(bytesOf(items))} will be removed from this computer, ` +
                  "and anything still queued is cancelled.",
                confirm: "Delete Everything",
                run: () => void deleteEverything(root),
              }),
          }
        : null,
    ]);
  });
  return el("span", { class: "menu-wrap" }, [btn]);
}

// ---------- Entry point ----------

export async function renderDownloads(
  root: HTMLElement,
  opts: { keepTab?: boolean } = {}
): Promise<void> {
  currentRoot = root;
  if (!opts.keepTab) {
    activeTab = "tv";
    openSeries = null;
    openSeason = null;
  }

  // This view re-renders constantly — on every finished download, every queue
  // change, and after playback. Only the first paint gets a placeholder; a
  // refresh keeps the current content on screen until the new one is ready,
  // instead of flashing the whole page.
  let marker: Element | null = root.querySelector(".dl-tabs");
  if (!marker) {
    clear(root);
    marker = skeletonGrid(10);
    root.append(marker);
  }
  const seq = ++renderSeq;

  const [items, pending] = await Promise.all([
    invoke<any[]>("downloads_list"),
    invoke<number>("progress_pending"),
  ]);
  // Navigated away while loading (the page that was here is gone), or a newer
  // refresh has started and will paint fresher data: either way, not ours to
  // draw over.
  if (seq !== renderSeq || !document.contains(marker)) return;
  const waiting = getQueuedDownloads();

  const completed = items.filter((d) => d.status === "complete");
  const tv = completed.filter(isEpisode);
  const movies = completed.filter((d) => !isEpisode(d));
  const active = items.filter((d) => d.status === "downloading");
  // A queued retry keeps `status: "error"` in meta.json until it actually
  // starts, so without this it renders twice — once under "Up next" and again
  // under "Failed", the second with a Retry button that does nothing because
  // it's already queued.
  const waitingIds = new Set(waiting.map((p) => p.id));
  const errored = items.filter(
    (d) => (d.status === "error" || d.status === "paused") && !waitingIds.has(d.item_id)
  );

  clear(root);
  root.append(
    el("div", { class: "section-head" }, [
      el("h1", { class: "page-title" }, ["Downloads"]),
      el("div", { class: "head-tools" }, [
        pauseButton(active.length + waiting.length > 0),
        concurrencySelector(),
        el("span", { class: "sync-pill" }, [
          pending > 0 ? `${pending} watch state(s) waiting to sync` : "Watch state in sync",
        ]),
        el("button", {
          class: "btn small",
          onClick: async () => {
            await syncOfflineProgress(true);
            renderDownloads(root, { keepTab: true });
          },
        }, ["Sync now"]),
        manageButton(items, waiting.length, errored, root),
      ]),
    ])
  );

  const pane = el("div", { class: "dl-pane" });
  const queueCount = active.length + waiting.length + errored.length;

  const tabs: { id: Tab; label: string; count: number }[] = [
    { id: "tv", label: "TV", count: tv.length },
    { id: "movies", label: "Movies", count: movies.length },
    { id: "queue", label: "Queue", count: queueCount },
  ];

  function paint(): void {
    if (activeTab === "tv") renderTvTab(pane, tv, root);
    else if (activeTab === "movies") renderMoviesTab(pane, movies, root);
    else renderQueueTab(pane, active, errored, waiting, root);
  }

  const tabBar = el("div", { class: "dl-tabs" });
  for (const t of tabs) {
    const btn = el("button", { class: `btn small${t.id === activeTab ? " active" : ""}` }, [
      t.label,
      t.count ? el("span", { class: "dl-tab-count" }, [String(t.count)]) : null,
    ]);
    btn.addEventListener("click", () => {
      if (activeTab !== t.id) {
        openSeries = null;
        openSeason = null;
      }
      activeTab = t.id;
      tabBar.querySelectorAll(".btn").forEach((b) => b.classList.remove("active"));
      btn.classList.add("active");
      paint();
    });
    tabBar.append(btn);
  }
  root.append(tabBar, pane);
  paint();

  // Reconcile watched state with the server in the background; repaint when
  // something actually changed and this view is still on screen.
  void refreshWatchState(completed)
    .then((changed) => {
      if (changed && document.contains(pane)) paint();
    })
    .catch(() => {});
  // Names, overviews and artwork, at most every six hours.
  void refreshDetails(completed)
    .then((changed) => {
      if (changed && document.contains(pane)) renderDownloads(root, { keepTab: true });
    })
    .catch(() => {});
  installDeleteKey();

  // Refresh the view when the in-memory batch queue changes (installed once).
  if (!queueListenerInstalled) {
    queueListenerInstalled = true;
    document.addEventListener("aquarium-download-queue", () => {
      if (currentRoot && document.contains(currentRoot) && currentRoot.querySelector(".dl-tabs")) {
        renderDownloads(currentRoot, { keepTab: true });
      }
    });
  }

  // Re-render when playback ends (installed once): watching a download
  // updates its meta.json, but this view was rendered before playback began —
  // without this, the ✓ / progress just watched never appears until the user
  // navigates away and back.
  if (!playbackListenerInstalled) {
    playbackListenerInstalled = true;
    let wasActive = false;
    void listen("player-status", (ev) => {
      const st = ev.payload as any;
      if (st.active) {
        wasActive = true;
        return;
      }
      if (!wasActive) return;
      wasActive = false;
      if (currentRoot && document.contains(currentRoot) && currentRoot.querySelector(".dl-tabs")) {
        renderDownloads(currentRoot, { keepTab: true });
      }
    });
  }
}

function etaText(seconds: number): string {
  if (!isFinite(seconds) || seconds <= 0) return "";
  if (seconds < 60) return `${Math.round(seconds)}s left`;
  const m = Math.floor(seconds / 60);
  if (m < 60) return `${m}m ${Math.round(seconds % 60)}s left`;
  return `${Math.floor(m / 60)}h ${m % 60}m left`;
}

/** Called from main.ts on download-progress events to update visible bars. */
export function updateDownloadProgress(payload: any, root: HTMLElement): void {
  if (payload.state === "complete" || payload.state === "error" || payload.state === "canceled") {
    // A download finished: re-render so it moves into the right tab and the
    // next queued item appears. Only if the Downloads view is mounted.
    if (root.querySelector(".dl-tabs")) renderDownloads(root, { keepTab: true });
    return;
  }
  const bar = root.querySelector<HTMLElement>(`.dl-bar[data-item="${payload.item_id}"] > div`);
  const sub = root.querySelector<HTMLElement>(`[data-sub="${payload.item_id}"]`);

  // Progress for a download the Queue tab never drew a row for: the view was
  // rendered before this item's meta.json existed. Re-render once so it shows
  // up, instead of leaving the tab looking like the queue died.
  if (!bar && activeTab === "queue" && !healingQueueTab && root.querySelector(".dl-tabs")) {
    healingQueueTab = true;
    void renderDownloads(root, { keepTab: true }).finally(() => {
      healingQueueTab = false;
    });
    return;
  }
  const approx = payload.estimated ? "~" : "";
  const speed = payload.speed_bps ? `${api.bytesToText(payload.speed_bps)}/s` : "";

  if (payload.total) {
    const pct = Math.min(100, (payload.received / payload.total) * 100);
    if (bar) bar.style.width = `${pct}%`;
    if (sub) {
      const remaining =
        payload.speed_bps > 0 ? (payload.total - payload.received) / payload.speed_bps : NaN;
      sub.textContent = [
        `${pct.toFixed(0)}%`,
        `${api.bytesToText(payload.received)} of ${approx}${api.bytesToText(payload.total)}`,
        speed,
        etaText(remaining),
      ]
        .filter(Boolean)
        .join(" · ");
    }
  } else {
    // No size information at all — show an indeterminate shimmer.
    if (bar) {
      bar.style.width = "100%";
      bar.style.opacity = "0.35";
    }
    if (sub) {
      sub.textContent = [`${api.bytesToText(payload.received)} downloaded`, speed]
        .filter(Boolean)
        .join(" · ");
    }
  }
}
