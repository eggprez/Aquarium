// Downloads of songs, albums and audiobooks: always the original file, through
// the same throttled queue video uses (`downloadSeason` in playback.ts, which
// takes any list of items despite its name), so nothing in downloads.rs had to
// change. What the download's meta.json doesn't carry — album, artists, cover,
// chapters — is kept beside it here, keyed by item id, so a downloaded album
// can be listed and played with no server at all.
//
// Played offline, a book's position is queued by the backend (progress.rs, as
// for video) and synced when the server is back.
//
// The same metadata is what the on-device library is built from: the
// Downloaded page's artists and albums, and the album and artist pages under
// #/music/downloaded/, none of which ask the server anything.
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import * as api from "../api";
import * as m from "../musicApi";
import * as audio from "../audio";
import { downloadSeason, getQueuedDownloads } from "../playback";
import { el, clear, toast, emptyState, openActionMenu, type MenuAction } from "../ui";
import { songList, grid, musicCard, shelf, pageHeader, link, markPlaying, iconButton, mi } from "./musicCommon";

const META_KEY = "aquarium.music-downloads";

/** The fields a song or book needs to be drawn and played offline. */
function slim(item: any): any {
  const keep = [
    "Id", "Name", "Type", "Album", "AlbumId", "AlbumArtist", "AlbumArtists", "ArtistItems", "Artists",
    "RunTimeTicks", "IndexNumber", "ParentIndexNumber", "ProductionYear", "Chapters", "ImageTags",
    "AlbumPrimaryImageTag", "Genres", "SortName",
  ];
  const out: any = {};
  for (const k of keep) if (item[k] != null) out[k] = item[k];
  return out;
}

function readMeta(): Record<string, any> {
  try {
    return JSON.parse(localStorage.getItem(META_KEY) ?? "{}") ?? {};
  } catch {
    return {};
  }
}

function writeMeta(all: Record<string, any>): void {
  try {
    localStorage.setItem(META_KEY, JSON.stringify(all));
  } catch {
    // Storage full: the file still downloads, it just lists by file name.
  }
}

function originalQuality(): api.DownloadQuality {
  return api.DOWNLOAD_QUALITIES.find((q) => q.original) ?? api.DOWNLOAD_QUALITIES[0];
}

// ---------- What is downloaded, for marks and menus ----------

/** Fired on `document` when a song, album or book starts or stops being
 *  downloaded, so an open Downloaded page can redraw. */
export const DOWNLOADS_CHANGED = "aquarium-music-downloads";

type DlState = "done" | "busy";
let itemState = new Map<string, DlState>();
/** Album id → how many of its songs are here. */
let albumHave = new Map<string, number>();
let albumBusy = new Set<string>();
let stateSig = "";
let watching = false;

/** Read the downloads again and, when anything moved, redraw the marks on
 *  the page. Rows and menus read the result synchronously in between. */
export async function refreshDownloadState(): Promise<void> {
  const list = await invoke<any[]>("downloads_list").catch(() => [] as any[]);
  const meta = readMeta();
  const items = new Map<string, DlState>();
  const have = new Map<string, number>();
  const busy = new Set<string>();
  const note = (id: string, st: DlState) => {
    items.set(id, st);
    const album = meta[id]?.AlbumId;
    if (!album) return;
    if (st === "done") have.set(album, (have.get(album) ?? 0) + 1);
    else busy.add(album);
  };
  for (const d of list) {
    const type = d.type ?? meta[d.item_id]?.Type;
    if (type !== "Audio" && type !== "AudioBook") continue;
    if (d.status === "complete" && d.path) note(d.item_id, "done");
    else if (d.status === "downloading") note(d.item_id, "busy");
  }
  // Files still waiting their turn exist only in the queue's memory.
  for (const p of getQueuedDownloads()) {
    if (meta[p.id] && !items.has(p.id)) note(p.id, "busy");
  }
  const sig = [...items].map(([id, st]) => `${id}:${st}`).sort().join(",");
  if (sig === stateSig) return;
  stateSig = sig;
  itemState = items;
  albumHave = have;
  albumBusy = busy;
  paintDownloadMarks(document);
  document.dispatchEvent(new CustomEvent(DOWNLOADS_CHANGED));
}

/** Keep the state current from here on. Called by every music and book page;
 *  the listeners go in once. */
export function watchDownloadState(): void {
  void refreshDownloadState();
  if (watching) return;
  watching = true;
  let t = 0;
  const soon = () => {
    clearTimeout(t);
    t = window.setTimeout(() => void refreshDownloadState(), 300);
  };
  document.addEventListener("aquarium-download-queue", soon);
  void listen("download-progress", (ev) => {
    const state = (ev.payload as any)?.state;
    if (["complete", "error", "canceled", "paused"].includes(state)) soon();
  }).catch(() => {});
}

function stateFor(id: string, kind: string, count: number | null): DlState | null {
  if (kind !== "MusicAlbum") return itemState.get(id) ?? null;
  if (albumBusy.has(id)) return "busy";
  const have = albumHave.get(id) ?? 0;
  // An album is marked only when all of it is here, and only where the list
  // said how many songs that is.
  return have > 0 && count != null && have >= count ? "done" : null;
}

function fillMark(span: HTMLElement): void {
  const count = span.dataset.dlCount ? Number(span.dataset.dlCount) : null;
  const st = stateFor(span.dataset.dl ?? "", span.dataset.dlKind ?? "", count);
  if ((span.dataset.state ?? "") === (st ?? "")) return;
  span.dataset.state = st ?? "";
  clear(span);
  if (!st) {
    span.removeAttribute("title");
    return;
  }
  span.title = st === "done" ? "Downloaded" : "Downloading…";
  span.append(mi("downloaded", 14));
}

/** The small mark a song row or a cover carries while its file is here or
 *  on its way. Empty (and hidden) otherwise, so it can fill in later. */
export function downloadMark(item: any): HTMLElement | null {
  if (!item?.Id || !["Audio", "AudioBook", "MusicAlbum"].includes(item.Type)) return null;
  const span = el("span", {
    class: "mu-dl",
    "data-dl": item.Id,
    "data-dl-kind": item.Type,
    "data-dl-count": item.ChildCount != null ? String(item.ChildCount) : null,
  });
  fillMark(span);
  return span;
}

export function paintDownloadMarks(root: ParentNode): void {
  root.querySelectorAll<HTMLElement>(".mu-dl[data-dl]").forEach(fillMark);
}

/** Queue every file `item` stands for. */
export async function downloadMusic(item: any): Promise<void> {
  try {
    let files: any[];
    if (item.Type === "MusicAlbum") files = await m.albumTracks(item.Id);
    else if (item.Type === "Playlist") files = (await m.playlistItems(item.Id)).filter((f) => f.Type === "Audio");
    else if (item.Type === "Audio" || item.Type === "AudioBook") files = [item];
    else return;
    if (!files.length) {
      toast("Nothing to download there", "info");
      return;
    }
    // The detail shape: MediaSources say the container (so the file gets the
    // right extension) and the size (for the free-space check).
    const detailed = await api.getItemsByIds(files.map((f) => f.Id), m.MUSIC_DETAIL_FIELDS);
    const byId = new Map(detailed.map((d) => [d.Id, d]));
    const full = files.map((f) => ({ ...f, ...(byId.get(f.Id) ?? {}) }));
    const meta = readMeta();
    for (const f of full) meta[f.Id] = slim(f);
    writeMeta(meta);
    const r = await downloadSeason(full, originalQuality());
    if (r.cancelled) return;
    toast(
      r.queued
        ? `Downloading ${r.queued} ${item.Type === "AudioBook" ? "file" : "song"}${r.queued === 1 ? "" : "s"}${r.skipped ? `, ${r.skipped} already here` : ""}`
        : "Already downloaded",
      r.queued ? "ok" : "info"
    );
    void refreshDownloadState();
  } catch (e: any) {
    toast(`Download failed: ${e?.message ?? e}`, "error");
  }
}

/** Delete these downloaded files and forget what was kept about them. */
export async function removeDownloads(ids: string[]): Promise<void> {
  let n = 0;
  for (const id of ids) {
    await invoke("download_delete", { itemId: id }).then(() => n++).catch(() => {});
  }
  const meta = readMeta();
  for (const id of ids) delete meta[id];
  writeMeta(meta);
  toast(n === 1 ? "Download deleted" : n ? `${n} downloads deleted` : "Nothing was deleted", n ? "ok" : "info");
  await refreshDownloadState();
}

function downloadedIdsOf(item: any): string[] {
  if (item.Type !== "MusicAlbum") return itemState.get(item.Id) === "done" ? [item.Id] : [];
  return Object.values(readMeta())
    .filter((s: any) => s.AlbumId === item.Id && itemState.get(s.Id) === "done")
    .map((s: any) => s.Id);
}

/** The download entries for a menu: Download, Downloading… or Remove
 *  Download, by what is already here. With no server there is nothing to
 *  download from, so only removal is offered. */
export function downloadActions(item: any): MenuAction[] {
  const offline = api.isOffline();
  const remove: MenuAction = { label: "Remove Download", icon: "trash", danger: true, run: () => void removeDownloads(downloadedIdsOf(item)) };
  const busy: MenuAction = { label: "Downloading…", icon: "download", run: () => void (location.hash = "#/downloads") };
  const get = (label: string): MenuAction => ({ label, icon: "download", run: () => void downloadMusic(item) });
  switch (item?.Type) {
    case "Audio":
    case "AudioBook": {
      const st = itemState.get(item.Id);
      if (st === "done") return [remove];
      if (st === "busy") return [busy];
      return offline ? [] : [get("Download")];
    }
    case "MusicAlbum": {
      if (albumBusy.has(item.Id)) return [busy];
      const have = albumHave.get(item.Id) ?? 0;
      const whole = have > 0 && item.ChildCount != null && have >= item.ChildCount;
      const out: MenuAction[] = [];
      if (!offline && !whole) out.push(get("Download Album"));
      if (have) out.push(remove);
      return out;
    }
    case "Playlist":
      return offline ? [] : [get("Download")];
    default:
      return [];
  }
}

/** Downloaded songs and books, as items the music pages can draw, with the
 *  local file each one plays from. */
export async function downloadedItems(): Promise<any[]> {
  const list = await invoke<any[]>("downloads_list").catch(() => []);
  const meta = readMeta();
  const out: any[] = [];
  for (const d of list) {
    if (d.status !== "complete" || !d.path) continue;
    const type = d.type ?? meta[d.item_id]?.Type;
    if (type !== "Audio" && type !== "AudioBook") continue;
    const base = meta[d.item_id] ?? { Id: d.item_id, Name: d.name ?? d.title, Type: type, RunTimeTicks: d.run_time_ticks };
    out.push({
      ...base,
      UserData: { PlaybackPositionTicks: d.position_ticks ?? 0, Played: !!d.played },
      __localPath: d.path,
    });
  }
  return out;
}

const fold = (t: string): string => t.normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase();

function wordsOf(term: string): string[] {
  return fold(term).split(/\s+/).filter(Boolean);
}

/** The downloads whose title, album or artist holds every word of `term`. */
export function matchDownloaded(items: any[], term: string): any[] {
  const words = wordsOf(term);
  if (!words.length) return items;
  return items.filter((i) => {
    const hay = fold([i.Name, i.Album, i.AlbumArtist, ...(i.Artists ?? [])].filter(Boolean).join(" "));
    return words.every((w) => hay.includes(w));
  });
}

// ---------- The on-device library ----------

/** Songs under one heading: an album or an artist made up from what the
 *  downloaded songs say about themselves. */
interface LocalGroup {
  item: any;
  songs: any[];
}

function artistOf(song: any): string {
  return song.AlbumArtist || song.AlbumArtists?.[0]?.Name || song.Artists?.[0] || song.ArtistItems?.[0]?.Name || "";
}

/** A song tagged with an album name but no album id still belongs to one. */
function albumKeyOf(song: any): string {
  return song.AlbumId || (song.Album ? `name:${song.Album}` : "");
}

export function localAlbumRoute(song: any): string | null {
  const key = albumKeyOf(song);
  return key ? `#/music/downloaded/album/${encodeURIComponent(key)}` : null;
}

export function localArtistRoute(song: any): string | null {
  const name = artistOf(song);
  return name ? `#/music/downloaded/artist/${encodeURIComponent(name)}` : null;
}

function byName(a: LocalGroup, b: LocalGroup): number {
  return String(a.item.Name).localeCompare(String(b.item.Name));
}

function localAlbums(songs: any[]): LocalGroup[] {
  const groups = new Map<string, LocalGroup>();
  for (const s of songs) {
    const key = albumKeyOf(s);
    if (!key) continue;
    let g = groups.get(key);
    if (!g) {
      g = {
        item: {
          Id: key,
          Name: s.Album ?? "Unknown Album",
          Type: "MusicAlbum",
          AlbumArtist: artistOf(s),
          ProductionYear: s.ProductionYear,
          ImageTags: s.AlbumId && s.AlbumPrimaryImageTag ? { Primary: s.AlbumPrimaryImageTag } : {},
        },
        songs: [],
      };
      groups.set(key, g);
    }
    g.songs.push(s);
  }
  for (const g of groups.values()) g.songs = m.sortedByTrack(g.songs);
  return [...groups.values()].sort(byName);
}

function localArtists(songs: any[]): LocalGroup[] {
  const groups = new Map<string, LocalGroup>();
  for (const s of songs) {
    const name = artistOf(s);
    if (!name) continue;
    const key = fold(name);
    let g = groups.get(key);
    if (!g) {
      g = { item: { Id: s.AlbumArtists?.[0]?.Id ?? `name:${name}`, Name: name, Type: "MusicArtist", ImageTags: {} }, songs: [] };
      groups.set(key, g);
    }
    g.songs.push(s);
  }
  for (const g of groups.values()) g.songs = inLibraryOrder(g.songs);
  return [...groups.values()].sort(byName);
}

/** Artist, then album, then the sleeve's order. */
function inLibraryOrder(songs: any[]): any[] {
  return m.sortedByTrack(songs).sort((a, b) =>
    artistOf(a).localeCompare(artistOf(b)) || String(a.Album ?? "").localeCompare(String(b.Album ?? "")) ||
    (a.ParentIndexNumber ?? 1) - (b.ParentIndexNumber ?? 1) || (a.IndexNumber ?? 0) - (b.IndexNumber ?? 0));
}

const countOf = (n: number): string => `${n} song${n === 1 ? "" : "s"}`;

function localActions(g: LocalGroup): MenuAction[] {
  const title = g.item.Name ?? "";
  return [
    { label: "Play", icon: "play", run: () => void audio.play(g.songs, 0, { title }) },
    { label: "Shuffle", icon: "shuffle", run: () => void audio.play(g.songs, 0, { title, shuffle: true }) },
    { label: "Play Next", run: () => void audio.playNext(g.songs) },
    { label: "Play Later", run: () => void audio.playLater(g.songs) },
    { label: g.songs.length === 1 ? "Remove Download" : `Remove ${g.songs.length} Downloads`, icon: "trash", danger: true, run: () => void removeDownloads(g.songs.map((s) => s.Id)) },
  ];
}

function localCard(g: LocalGroup, sub: string, route: string | null): HTMLElement {
  return musicCard(g.item, {
    sub,
    mark: false,
    onOpen: () => void (route && (location.hash = route)),
    onPlay: () => void audio.play(g.songs, 0, { title: g.item.Name ?? "" }),
    actions: () => localActions(g),
  });
}

function playShuffle(songs: any[], title: string): HTMLElement[] {
  return [
    el("button", { class: "btn primary", onClick: () => void audio.play(songs, 0, { title }) }, [mi("play"), " Play"]),
    el("button", { class: "btn", onClick: () => void audio.play(songs, 0, { title, shuffle: true }) }, [mi("shuffle"), " Shuffle"]),
  ];
}

/** Downloads as page sections: books, then artists, albums and songs. With a
 *  `query`, only what matches it, under the same headings. Empty when nothing
 *  does. */
export function downloadedSections(items: any[], query = "", title = "Downloaded"): HTMLElement[] {
  const words = wordsOf(query);
  const holds = (...text: (string | undefined)[]) => {
    const hay = fold(text.filter(Boolean).join(" "));
    return words.every((w) => hay.includes(w));
  };
  const allSongs = items.filter((i) => i.Type === "Audio");
  const songs = inLibraryOrder(matchDownloaded(allSongs, query));
  const books = matchDownloaded(items.filter((i) => i.Type === "AudioBook"), query);
  const artists = localArtists(allSongs).filter((g) => holds(g.item.Name));
  const albums = localAlbums(allSongs).filter((g) => holds(g.item.Name, g.item.AlbumArtist));
  const out: HTMLElement[] = [];
  if (books.length) {
    out.push(el("h2", { class: "mu-sub-head" }, ["Audiobooks"]), grid(books.map((b) => musicCard(b, {
      sub: m.artistLine(b),
      mark: false,
      onPlay: () => void audio.play([b], 0, { book: true, title: b.Name, startSeconds: m.secondsOf(b.UserData?.PlaybackPositionTicks) || undefined }),
    }))));
  }
  const artistShelf = shelf("Artists", artists.map((g) => localCard(g, countOf(g.songs.length), localArtistRoute(g.songs[0]))));
  if (artistShelf) out.push(artistShelf);
  const albumShelf = shelf("Albums", albums.map((g) => localCard(g, g.item.AlbumArtist, localAlbumRoute(g.songs[0]))));
  if (albumShelf) out.push(albumShelf);
  if (songs.length) {
    out.push(
      el("div", { class: "mu-page-head" }, [
        el("h2", { class: "mu-sub-head" }, [`Songs (${songs.length})`]),
        el("div", { class: "mu-head-buttons" }, playShuffle(songs, title)),
      ]),
      songList(songs, { lead: "art", showAlbum: true, title })
    );
  }
  return out;
}

/** Redraw with `load` whenever the downloads change, for as long as the page
 *  is the one showing. */
function redrawOnChange(root: HTMLElement, load: () => void): void {
  const onChange = () => {
    if (!root.isConnected) return document.removeEventListener(DOWNLOADS_CHANGED, onChange);
    load();
  };
  document.addEventListener(DOWNLOADS_CHANGED, onChange);
  const off = audio.onChange(() => {
    if (!root.isConnected) return off();
    markPlaying(root);
  });
}

/** Library → Downloaded: what plays with no server. Its field searches the
 *  downloads alone, online or not. Under it, `album/<key>` and
 *  `artist/<name>` are the on-device pages. */
export async function renderDownloaded(root: HTMLElement, tabs?: HTMLElement, sub = ""): Promise<void> {
  const [kind, ...rest] = sub.split("/");
  if (kind === "album" || kind === "artist") return renderLocalCollection(root, kind, rest.join("/"));
  root.append(el("h1", { class: "page-title" }, ["Downloaded Music & Books"]));
  if (tabs) root.append(tabs);
  if (api.isOffline()) root.append(el("p", { class: "mu-search-note mu-offline-note" }, ["The server can't be reached. Everything here plays from this device."]));
  const field = el("input", { type: "search", class: "mu-input mu-search", placeholder: "Search downloads", "aria-label": "Search downloads" }) as HTMLInputElement;
  const body = el("div");
  root.append(field, body);
  let items = await downloadedItems();
  const paint = () => {
    clear(body);
    field.hidden = !items.length;
    if (!items.length) {
      body.append(emptyState({ icon: "disk", title: "Nothing downloaded yet", body: "Download songs, albums and audiobooks from their menus. They play from here with no server." }));
      return;
    }
    const q = field.value.trim();
    const parts = downloadedSections(items, q, q ? `Downloaded: ${q}` : "Downloaded");
    if (!parts.length) body.append(emptyState({ icon: "search", title: `Nothing downloaded for “${q}”` }));
    else body.append(...parts);
  };
  field.addEventListener("input", paint);
  paint();
  redrawOnChange(root, () => void downloadedItems().then((fresh) => {
    items = fresh;
    paint();
  }));
}

/** An album or an artist, from the downloaded songs alone. */
async function renderLocalCollection(root: HTMLElement, kind: "album" | "artist", key: string): Promise<void> {
  const isAlbum = kind === "album";
  const load = async () => {
    const all = (await downloadedItems()).filter((i) => i.Type === "Audio");
    if (!root.isConnected) return;
    const g = isAlbum
      ? localAlbums(all).find((x) => x.item.Id === key)
      : localArtists(all).find((x) => fold(x.item.Name) === fold(key));
    clear(root);
    if (!g) {
      // Reached two ways: with no server, and from Downloaded with one, where
      // "out of reach" would be untrue.
      const offline = api.isOffline();
      root.append(emptyState({
        icon: "disk",
        title: "Not on this device",
        body: offline
          ? "None of this has been downloaded, and the server is out of reach. It opens as usual once you're back online."
          : "None of this is downloaded any more. It is still in the library.",
        action: { label: "Downloaded", run: () => void (location.hash = "#/music/downloaded") },
      }));
      return;
    }
    const title = g.item.Name ?? "";
    const albums = isAlbum ? [] : localAlbums(g.songs);
    const secs = g.songs.reduce((n, s) => n + m.secondsOf(s.RunTimeTicks), 0);
    // The server's page for the same thing, where there is one to go to.
    const onServer = api.isOffline() || String(g.item.Id).startsWith("name:")
      ? null
      : `#/music/${isAlbum ? "album" : "artist"}/${g.item.Id}`;
    const more = iconButton("more", "More", () => openActionMenu(more, title, localActions(g), { fixed: true }));
    root.append(pageHeader({
      item: g.item,
      cover: m.coverUrl(g.item, 600),
      round: !isAlbum,
      eyebrow: isAlbum ? "Album · Downloaded" : "Artist · Downloaded",
      title,
      lines: isAlbum
        ? [link(g.item.AlbumArtist ?? "", localArtistRoute(g.songs[0])), [g.item.ProductionYear, countOf(g.songs.length)].filter(Boolean).join(" · ")]
        : [[albums.length ? `${albums.length} album${albums.length === 1 ? "" : "s"}` : "", countOf(g.songs.length)].filter(Boolean).join(" · ")],
      buttons: [
        ...playShuffle(g.songs, title),
        onServer ? el("a", { class: "btn", href: onServer }, ["Open in Library"]) : null,
        more,
      ],
    }));
    if (isAlbum) {
      root.append(songList(g.songs, { lead: "number", discs: true, title }));
    } else {
      // Every album on the device, wrapping, the way the online artist page
      // lays its albums out.
      if (albums.length) {
        root.append(el("section", { class: "mu-shelf" }, [
          el("div", { class: "section-head" }, [el("h2", {}, ["Albums"])]),
          grid(albums.map((a) => localCard(a, a.item.ProductionYear ? String(a.item.ProductionYear) : "", localAlbumRoute(a.songs[0])))),
        ]));
        root.append(el("h2", { class: "mu-sub-head" }, ["Songs"]));
      }
      root.append(songList(g.songs, { lead: "art", showAlbum: true, showArtist: false, title }));
    }
    root.append(el("p", { class: "mu-footnote" }, [`${countOf(g.songs.length)} on this device${secs ? `, ${m.longDuration(secs)}` : ""}`]));
  };
  await load();
  redrawOnChange(root, () => void load());
}
