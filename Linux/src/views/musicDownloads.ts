// Downloads of songs, albums and audiobooks: always the original file, through
// the same throttled queue video uses (`downloadSeason` in playback.ts, which
// takes any list of items despite its name), so nothing in downloads.rs had to
// change. What the download's meta.json doesn't carry — album, artists, cover,
// chapters — is kept beside it here, keyed by item id, so a downloaded album
// can be listed and played with no server at all.
//
// Played offline, a book's position is queued by the backend (progress.rs, as
// for video) and synced when the server is back.
import { invoke } from "@tauri-apps/api/core";
import * as api from "../api";
import * as m from "../musicApi";
import * as audio from "../audio";
import { downloadSeason } from "../playback";
import { el, clear, toast, emptyState, type MenuAction } from "../ui";
import { songList, grid, musicCard, mi } from "./musicCommon";

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

/** Queue every file `item` stands for. */
export async function downloadMusic(item: any): Promise<void> {
  try {
    let files: any[];
    if (item.Type === "MusicAlbum") files = await m.albumTracks(item.Id);
    else if (item.Type === "Audio" || item.Type === "AudioBook") files = [item];
    else return;
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
  } catch (e: any) {
    toast(`Download failed: ${e?.message ?? e}`, "error");
  }
}

export function downloadMusicAction(item: any): MenuAction | null {
  if (!["Audio", "MusicAlbum", "AudioBook"].includes(item.Type)) return null;
  return {
    label: item.Type === "MusicAlbum" ? "Download Album" : "Download",
    icon: "download",
    run: () => void downloadMusic(item),
  };
}

export const downloadBookAction = (book: any): MenuAction | null => downloadMusicAction(book);

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

/** Library → Downloaded: what plays with no server. */
export async function renderDownloaded(root: HTMLElement, tabs?: HTMLElement): Promise<void> {
  root.append(el("h1", { class: "page-title" }, ["Downloaded Music & Books"]));
  if (tabs) root.append(tabs);
  // The other tabs need the server; this one is the offline page.
  const body = el("div");
  root.append(body);
  const items = await downloadedItems();
  clear(body);
  const songs = m.sortedByTrack(items.filter((i) => i.Type === "Audio"))
    .sort((a, b) => String(a.AlbumArtist ?? "").localeCompare(String(b.AlbumArtist ?? "")) || String(a.Album ?? "").localeCompare(String(b.Album ?? "")) || (a.ParentIndexNumber ?? 1) - (b.ParentIndexNumber ?? 1) || (a.IndexNumber ?? 0) - (b.IndexNumber ?? 0));
  const books = items.filter((i) => i.Type === "AudioBook");
  if (!songs.length && !books.length) {
    body.append(emptyState({ icon: "disk", title: "Nothing downloaded yet", body: "Download songs, albums and audiobooks from their menus. They play from here with no server." }));
    return;
  }
  if (books.length) {
    body.append(el("h2", { class: "mu-sub-head" }, ["Audiobooks"]), grid(books.map((b) => musicCard(b, {
      sub: m.artistLine(b),
      onOpen: () => void audio.play([b], 0, { book: true, title: b.Name, startSeconds: m.secondsOf(b.UserData?.PlaybackPositionTicks) || undefined }),
    }))));
  }
  if (songs.length) {
    body.append(
      el("div", { class: "mu-page-head" }, [
        el("h2", { class: "mu-sub-head" }, [`Songs (${songs.length})`]),
        el("div", { class: "mu-head-buttons" }, [
          el("button", { class: "btn primary", onClick: () => void audio.play(songs, 0, { title: "Downloaded" }) }, [mi("play"), " Play"]),
          el("button", { class: "btn", onClick: () => void audio.play(songs, 0, { title: "Downloaded", shuffle: true }) }, [mi("shuffle"), " Shuffle"]),
        ]),
      ]),
      songList(songs, { lead: "art", showAlbum: true, title: "Downloaded" })
    );
  }
}
