// Pieces every music and audiobook page shares: square cards, song rows, the
// song menu (Play Next / Play Later / Start Station / Add to Playlist / Song
// Info), and the playlist pickers. Modelled on the Apple app's
// `MusicComponents.swift`.
import * as api from "../api";
import * as m from "../musicApi";
import * as audio from "../audio";
import { buildStation } from "../stations";
import { smartPlaylistSongs, getSmartPlaylists } from "../smartPlaylists";
import { downloadMusicAction } from "./musicDownloads";
import { el, art, toast, openDialog, attachContextMenu, openActionMenu, type MenuAction, noart } from "../ui";

// ---------- Icons the shared set doesn't have ----------

const S = 'fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"';
const F = 'fill="currentColor"';
export const MI = {
  play: `<path ${F} d="M8 5.9a.8.8 0 0 1 1.22-.68l9.1 5.4a.8.8 0 0 1 0 1.38l-9.1 5.4A.8.8 0 0 1 8 16.72z"/>`,
  pause: `<rect ${F} x="6.5" y="5" width="4" height="14" rx="1.2"/><rect ${F} x="13.5" y="5" width="4" height="14" rx="1.2"/>`,
  next: `<path ${F} d="M4.5 6.2a.7.7 0 0 1 1.07-.6L12 9.8V6.2a.7.7 0 0 1 1.07-.6l7.2 5.8a.7.7 0 0 1 0 1.1l-7.2 5.8A.7.7 0 0 1 12 17.8v-3.6l-6.43 4.2a.7.7 0 0 1-1.07-.6z"/>`,
  prev: `<path ${F} d="M19.5 6.2a.7.7 0 0 0-1.07-.6L12 9.8V6.2a.7.7 0 0 0-1.07-.6l-7.2 5.8a.7.7 0 0 0 0 1.1l7.2 5.8a.7.7 0 0 0 1.07-.6v-3.6l6.43 4.2a.7.7 0 0 0 1.07-.6z"/>`,
  shuffle: `<path ${S} d="M4 6.8h2.1a4.5 4.5 0 0 1 3.7 1.95l4.4 6.5a4.5 4.5 0 0 0 3.7 1.95H20"/><path ${S} d="m17.2 14.4 2.8 2.8-2.8 2.8"/><path ${S} d="M4 17.2h2.1a4.5 4.5 0 0 0 3.7-1.95l.5-.75m3.4-5 .5-.75a4.5 4.5 0 0 1 3.7-1.95H20"/><path ${S} d="M17.2 4 20 6.8l-2.8 2.8"/>`,
  repeat: `<path ${S} d="M17 3.5 20 6.5l-3 3"/><path ${S} d="M4 11.5v-1a4 4 0 0 1 4-4h12"/><path ${S} d="M7 20.5 4 17.5l3-3"/><path ${S} d="M20 12.5v1a4 4 0 0 1-4 4H4"/>`,
  repeatOne: `<path ${S} d="M17 3.5 20 6.5l-3 3"/><path ${S} d="M4 11.5v-1a4 4 0 0 1 4-4h12"/><path ${S} d="M7 20.5 4 17.5l3-3"/><path ${S} d="M20 12.5v1a4 4 0 0 1-4 4H4"/><path ${S} d="M11.2 10.6 12.4 10v4.4"/>`,
  queue: `<path ${S} d="M4 6.5h16M4 12h10M4 17.5h7"/><path ${F} d="M15.5 13.2a.7.7 0 0 1 1.05-.6l5 3.05a.7.7 0 0 1 0 1.2l-5 3.05a.7.7 0 0 1-1.05-.6z"/>`,
  lyrics: `<path ${S} d="M4 6.5A2.5 2.5 0 0 1 6.5 4h11A2.5 2.5 0 0 1 20 6.5v8a2.5 2.5 0 0 1-2.5 2.5h-6.3L7 20.4V17h-.5A2.5 2.5 0 0 1 4 14.5z"/><path ${S} d="M8 8.5h8M8 12h5"/>`,
  station: `<circle ${S} cx="12" cy="12" r="2"/><path ${S} d="M8.2 15.8a5.4 5.4 0 0 1 0-7.6M15.8 8.2a5.4 5.4 0 0 1 0 7.6M5.4 18.6a9.3 9.3 0 0 1 0-13.2M18.6 5.4a9.3 9.3 0 0 1 0 13.2"/>`,
  sleep: `<path ${S} d="M20 14.5A8.2 8.2 0 0 1 9.5 4 8.4 8.4 0 1 0 20 14.5z"/>`,
  info: `<circle ${S} cx="12" cy="12" r="8.5"/><path ${S} d="M12 11v5.5M12 7.8v.3"/>`,
  plus: `<path ${S} stroke-width="2" d="M12 5v14M5 12h14"/>`,
  more: `<circle ${F} cx="6" cy="12" r="1.7"/><circle ${F} cx="12" cy="12" r="1.7"/><circle ${F} cx="18" cy="12" r="1.7"/>`,
  close: `<path ${S} stroke-width="2.1" d="M6.6 6.6l10.8 10.8M17.4 6.6 6.6 17.4"/>`,
  down: `<path ${S} stroke-width="2.2" d="m6 9.5 6 6 6-6"/>`,
  grip: `<path ${S} d="M6 9h12M6 15h12"/>`,
  note: `<path ${S} d="M9 18V5.5l10-2V16"/><circle ${S} cx="6.5" cy="18" r="2.5"/><circle ${S} cx="16.5" cy="16" r="2.5"/>`,
  book: `<path ${S} d="M5 4.5h9.5a3 3 0 0 1 3 3v12H8a3 3 0 0 1-3-3z"/><path ${S} d="M5 16.5a3 3 0 0 1 3-3h9.5"/>`,
  back15: `<path ${S} d="M4.5 12a7.5 7.5 0 1 0 2.3-5.4"/><path ${S} d="M4.5 4v4h4"/><text x="8" y="15.6" font-size="7" font-weight="700" ${F} stroke="none">15</text>`,
  fwd30: `<path ${S} d="M19.5 12a7.5 7.5 0 1 1-2.3-5.4"/><path ${S} d="M19.5 4v4h-4"/><text x="8" y="15.6" font-size="7" font-weight="700" ${F} stroke="none">30</text>`,
  volume: `<path ${F} d="M4 9.5v5h3.5L12 19V5L7.5 9.5H4z"/><path ${S} d="M15.5 9a4.2 4.2 0 0 1 0 6M18 6.5a8 8 0 0 1 0 11"/>`,
  mute: `<path ${F} d="M4 9.5v5h3.5L12 19V5L7.5 9.5H4z"/><path ${S} d="m15.5 10 5 4m0-4-5 4"/>`,
  edit: `<path ${S} d="M4 20h4L19 9l-4-4L4 16z"/><path ${S} d="m13.5 6.5 4 4"/>`,
  mix: `<path ${S} d="M12 4v5m0 6v5M5.5 4v9m0 4v3M18.5 4v3m0 4v9"/><circle ${S} cx="12" cy="12" r="2"/><circle ${S} cx="5.5" cy="15" r="2"/><circle ${S} cx="18.5" cy="9" r="2"/>`,
  smart: `<path ${S} d="M12 3.5l1.9 4.6 4.6 1.9-4.6 1.9L12 16.5l-1.9-4.6L5.5 10l4.6-1.9z"/><path ${S} d="M18 15l.9 2.1 2.1.9-2.1.9L18 21l-.9-2.1-2.1-.9 2.1-.9z"/>`,
};
export type MusicIcon = keyof typeof MI;

export function mi(name: MusicIcon, px?: number): HTMLElement {
  const span = el("span", { class: "ico", "aria-hidden": "true", html: `<svg viewBox="0 0 24 24">${MI[name]}</svg>` });
  if (px != null) span.style.cssText = `width:${px}px;height:${px}px`;
  return span;
}

export function iconButton(name: MusicIcon, title: string, onClick: (ev: MouseEvent) => void, cls = ""): HTMLButtonElement {
  const b = el("button", { class: `btn icon mu-ibtn ${cls}`.trim(), title, "aria-label": title, onClick }, [mi(name)]);
  return b as HTMLButtonElement;
}

// ---------- Routes ----------

export function routeFor(item: any): string | null {
  switch (item?.Type) {
    case "MusicAlbum": return `#/music/album/${item.Id}`;
    case "MusicArtist": return `#/music/artist/${item.Id}`;
    case "MusicGenre":
    case "Genre": return `#/music/genre/${item.Id}`;
    case "Playlist": return `#/music/playlist/${item.Id}`;
    case "SmartPlaylist": return `#/music/smart/${item.Id}`;
    case "AudioBook": return `#/books/book/${item.Id}`;
    case "Audio": return item.AlbumId ? `#/music/album/${item.AlbumId}` : null;
    default: return null;
  }
}

/** Every song a thing stands for, in the order "Play" should play them. */
export async function songsOf(item: any): Promise<any[]> {
  switch (item.Type) {
    case "Audio":
    case "AudioBook":
      return [item];
    case "MusicAlbum":
      return m.albumTracks(item.Id);
    case "MusicArtist":
      return m.allSongs(item.Id);
    case "MusicGenre":
    case "Genre":
      return m.genreSongs(item.Id);
    case "Playlist":
      return m.playlistItems(item.Id);
    case "SmartPlaylist": {
      const sp = getSmartPlaylists().find((p) => p.id === item.Id);
      return sp ? smartPlaylistSongs(sp) : [];
    }
    default:
      return [];
  }
}

function report(e: any): void {
  toast(e?.message ?? String(e), "error");
}

export async function playThing(item: any, opts: { shuffle?: boolean } = {}): Promise<void> {
  try {
    const songs = await songsOf(item);
    if (!songs.length) {
      toast("Nothing to play there", "info");
      return;
    }
    await audio.play(songs, 0, { title: item.Name ?? "", shuffle: opts.shuffle });
  } catch (e) {
    report(e);
  }
}

export async function startStation(item: any): Promise<void> {
  try {
    toast(`Starting a station from ${item.Name ?? "that"}…`);
    const { source, first } = await buildStation(item);
    await audio.play(first, 0, { title: source.title, source });
  } catch (e) {
    report(e);
  }
}

// ---------- Playlists ----------

/** Ask for a name. Resolves null on cancel. */
export function askName(title: string, initial = "", action = "Save"): Promise<string | null> {
  return new Promise((resolve) => {
    const input = el("input", { class: "mu-input", type: "text", value: initial, "aria-label": "Name" }) as HTMLInputElement;
    let done = false;
    const finish = (v: string | null) => {
      if (done) return;
      done = true;
      resolve(v);
    };
    const close = openDialog({
      title,
      body: [input],
      actions: [
        { label: "Cancel", run: () => finish(null) },
        { label: action, primary: true, run: () => finish(input.value.trim() || null) },
      ],
      onDismiss: () => finish(null),
    });
    input.addEventListener("keydown", (ev) => {
      if (ev.key === "Enter") {
        ev.preventDefault();
        finish(input.value.trim() || null);
        close();
      }
    });
    setTimeout(() => {
      input.focus();
      input.select();
    }, 0);
  });
}

/** Called after any playlist change, so open pages can refresh. */
export const playlistsChanged = new EventTarget();

export async function newPlaylistWith(songs: any[], suggested = ""): Promise<void> {
  const name = await askName("New Playlist", suggested, "Create");
  if (!name) return;
  try {
    const id = await m.createPlaylist(name, songs.map((s) => s.Id));
    toast(`Made “${name}”`, "ok");
    playlistsChanged.dispatchEvent(new Event("change"));
    if (!songs.length) location.hash = `#/music/playlist/${id}`;
  } catch (e) {
    report(e);
  }
}

async function addTo(playlist: any, item: any): Promise<void> {
  try {
    const songs = await songsOf(item);
    await m.addToPlaylist(playlist.Id, songs.map((s) => s.Id));
    toast(`Added to “${playlist.Name}”`, "ok");
    playlistsChanged.dispatchEvent(new Event("change"));
  } catch (e) {
    report(e);
  }
}

let playlistCache: any[] | null = null;
let playlistFetch: Promise<void> | null = null;

/** Fetch the playlist list for the Add to Playlist menus. Menus are built
 *  synchronously, so this runs ahead of them: when a music page opens and
 *  after any playlist change. */
export function primePlaylists(force = false): Promise<void> {
  if (playlistFetch && !force) return playlistFetch;
  playlistFetch = m.audioPlaylists()
    .then((p) => void (playlistCache = p))
    .catch(() => void (playlistFetch = null));
  return playlistFetch;
}
playlistsChanged.addEventListener("change", () => void primePlaylists(true));

/** "Add to Playlist" as a submenu: New Playlist…, then every playlist. Built
 *  from what was last fetched so the menu opens at once; refetched behind. */
export function addToPlaylistAction(item: any, label = "Add to Playlist"): MenuAction {
  void primePlaylists();
  return {
    label,
    icon: "library",
    submenu: {
      label,
      items: () => [
        {
          label: "New Playlist…",
          run: async () => newPlaylistWith(await songsOf(item).catch(() => []), item.Type === "Audio" ? "" : item.Name ?? ""),
        },
        ...(playlistCache ?? []).filter((p) => p.Id !== item.Id).map((p) => ({ label: p.Name, run: () => addTo(p, item) })),
      ],
    },
  };
}

// ---------- The song menu ----------

export interface ActionOpts {
  /** On a playlist page: remove this entry. */
  onRemove?: () => void;
  onChanged?: () => void;
  /** Leave out "Go to Album" on the album's own page, and so on. */
  hideGoTo?: boolean;
}

export function musicActions(item: any, opts: ActionOpts = {}): (MenuAction | null)[] {
  const isSong = item.Type === "Audio";
  const isBook = item.Type === "AudioBook";
  const fav = !!item.UserData?.IsFavorite;
  const out: (MenuAction | null)[] = [
    { label: "Play", icon: "play", run: () => playThing(item) },
    isSong || isBook ? null : { label: "Shuffle", icon: "shuffle", run: () => playThing(item, { shuffle: true }) },
    { label: "Play Next", run: async () => audio.playNext(await songsOf(item)).catch(report) },
    { label: "Play Later", run: async () => audio.playLater(await songsOf(item)).catch(report) },
    isBook ? null : { label: "Start Station", run: () => startStation(item) },
    isBook || item.Type === "SmartPlaylist" ? null : addToPlaylistAction(item),
    item.Type === "SmartPlaylist"
      ? null
      : {
          label: fav ? "Remove from Favorites" : "Add to Favorites",
          icon: fav ? "star" : "star-outline",
          run: async () => {
            try {
              await api.setFavorite(item.Id, !fav);
              item.UserData = { ...(item.UserData ?? {}), IsFavorite: !fav };
              toast(fav ? "Removed from favorites" : "Added to favorites", "ok");
              opts.onChanged?.();
            } catch (e) {
              report(e);
            }
          },
        },
  ];
  if (isSong && !opts.hideGoTo) {
    if (item.AlbumId) out.push({ label: "Go to Album", run: () => void (location.hash = `#/music/album/${item.AlbumId}`) });
    const artist = item.AlbumArtists?.[0] ?? item.ArtistItems?.[0];
    if (artist?.Id) out.push({ label: "Go to Artist", icon: "people", run: () => void (location.hash = `#/music/artist/${artist.Id}`) });
  }
  out.push(downloadMusicAction(item));
  if (isSong) out.push({ label: "Song Info", run: () => void showSongInfo(item) });
  if (opts.onRemove) out.push({ label: "Remove from Playlist", icon: "trash", danger: true, run: opts.onRemove });
  return out;
}

// ---------- Song Info ----------

function bitrateText(bps?: number): string {
  return bps ? `${Math.round(bps / 1000)} kbps` : "";
}

export async function showSongInfo(song: any): Promise<void> {
  let full = song;
  try {
    full = await m.musicItem(song.Id);
  } catch {
    // The list's copy is enough to say something.
  }
  const src = full.MediaSources?.[0];
  const stream = (src?.MediaStreams ?? []).find((s: any) => s.Type === "Audio");
  const rows: [string, string][] = [];
  const missing: string[] = [];
  const add = (k: string, v: any, required = false) => {
    const text = v == null ? "" : String(v).trim();
    if (text) rows.push([k, text]);
    else if (required) missing.push(k.toLowerCase());
  };
  add("Title", full.Name);
  add("Artist", m.artistLine(full), true);
  add("Album", full.Album);
  add("Album artist", full.AlbumArtist);
  add("Genre", (full.Genres ?? []).join(", "), true);
  add("Year", full.ProductionYear, true);
  add("Track", full.IndexNumber != null ? `${full.IndexNumber}${full.ParentIndexNumber ? ` (disc ${full.ParentIndexNumber})` : ""}` : "");
  add("Length", full.RunTimeTicks ? m.clock(m.secondsOf(full.RunTimeTicks)) : "");
  const ud = full.UserData ?? {};
  add("Plays", String(ud.PlayCount ?? 0));
  if (ud.LastPlayedDate) add("Last played", new Date(ud.LastPlayedDate).toLocaleString());
  add("Favorite", ud.IsFavorite ? "Yes" : "No");
  add("Format", [src?.Container?.toUpperCase(), stream?.Codec?.toUpperCase()].filter(Boolean).join(" · "));
  add("Bitrate", bitrateText(stream?.BitRate ?? src?.Bitrate));
  if (stream?.SampleRate) add("Sample rate", `${(stream.SampleRate / 1000).toFixed(1)} kHz${stream.BitDepth ? ` · ${stream.BitDepth}-bit` : ""}`);
  if (stream?.Channels) add("Channels", stream.Channels === 2 ? "Stereo" : stream.Channels === 1 ? "Mono" : String(stream.Channels));
  if (src?.Size) add("Size", api.bytesToText(src.Size));
  if (full.DateCreated) add("Added", new Date(full.DateCreated).toLocaleDateString());
  add("File", full.Path ?? src?.Path);

  const body: (string | Node)[] = [];
  if (missing.length) {
    body.push(el("p", { class: "mu-info-missing" }, [`Missing ${missing.join(", ")} — stations can't place this song by ${missing.length > 1 ? "those" : "that"}.`]));
  }
  body.push(
    el("dl", { class: "mu-info" }, rows.flatMap(([k, v]) => [el("dt", {}, [k]), el("dd", {}, [v])]))
  );
  openDialog({ title: "Song Info", body, actions: [{ label: "Done", primary: true }], wide: true });
}

// ---------- Cards ----------

/** A square cover card: album, playlist, genre, book. Artists are round. */
export function musicCard(item: any, opts: { sub?: string; onOpen?: () => void } = {}): HTMLElement {
  const round = item.Type === "MusicArtist";
  const target = routeFor(item);
  const open = opts.onOpen ?? (() => target && (location.hash = target));
  const sub =
    opts.sub ??
    (item.Type === "MusicAlbum"
      ? [m.artistLine(item), item.ProductionYear].filter(Boolean).join(" · ")
      : item.Type === "Playlist"
        ? item.ChildCount != null ? `${item.ChildCount} song${item.ChildCount === 1 ? "" : "s"}` : "Playlist"
        : item.Type === "AudioBook"
          ? m.artistLine(item)
          : "");
  const cover = el("div", { class: `mu-cover${round ? " round" : ""}` }, [
    art(m.coverUrl(item, 360), () => item.Type === "MusicArtist" ? noart(item.Name ?? "?") : el("div", { class: "noart" }, [mi(item.Type === "AudioBook" ? "book" : "note", 34)]), { hash: api.imageHash(item) }),
    item.Type === "MusicArtist" || item.Type === "MusicGenre"
      ? null
      : el("button", {
          class: "mu-cover-play",
          title: "Play",
          "aria-label": `Play ${item.Name ?? ""}`,
          onClick: (ev: MouseEvent) => {
            ev.stopPropagation();
            void playThing(item);
          },
        }, [mi("play", 18)]),
  ]);
  const card = el("div", {
    class: `mu-card${round ? " artist" : ""}`,
    role: "button",
    tabindex: "0",
    "aria-label": sub ? `${item.Name} — ${sub}` : item.Name,
    onClick: open,
    onKeydown: (ev: KeyboardEvent) => {
      if ((ev.key === "Enter" || ev.key === " ") && ev.target === ev.currentTarget) {
        ev.preventDefault();
        open();
      }
    },
  }, [
    cover,
    el("div", { class: "mu-card-title" }, [item.Name ?? ""]),
    sub ? el("div", { class: "mu-card-sub" }, [sub]) : null,
  ]);
  if (item.Type !== "MusicGenre") attachContextMenu(card, item.Name ?? null, () => musicActions(item));
  return card;
}

export function shelf(title: string, items: HTMLElement[], seeAll?: () => void, subtitle?: string): HTMLElement | null {
  if (!items.length) return null;
  const row = el("div", { class: "mu-shelf-row" }, items);
  return el("section", { class: "mu-shelf" }, [
    el("div", { class: "section-head" }, [
      el("div", {}, [el("h2", {}, [title]), subtitle ? el("div", { class: "mu-shelf-sub" }, [subtitle]) : null]),
      seeAll ? el("a", { class: "see-all", role: "button", tabindex: "0", onClick: seeAll }, ["See all"]) : null,
    ]),
    row,
  ]);
}

export function grid(items: HTMLElement[]): HTMLElement {
  return el("div", { class: "mu-grid" }, items);
}

// ---------- Song rows ----------

export interface SongRowOpts {
  /** What the leading column shows: the track number, the cover, or a rank. */
  lead?: "number" | "art" | "rank";
  rank?: number;
  showAlbum?: boolean;
  showArtist?: boolean;
  /** Play from this row. Defaults to the song alone. */
  onPlay?: () => void;
  actions?: ActionOpts;
}

/** Keeps the "now playing" mark on whichever row is the current song. Static
 *  styling only — no animated equaliser, which would cost a full repaint a
 *  frame (see the power notes in Linux/CLAUDE.md). */
export function markPlaying(root: ParentNode): void {
  const id = audio.isActive() ? audio.current()?.Id : null;
  root.querySelectorAll<HTMLElement>(".mu-song").forEach((r) => r.classList.toggle("playing", !!id && r.dataset.id === id));
}

export function songRow(song: any, opts: SongRowOpts = {}): HTMLElement {
  const lead = opts.lead ?? "number";
  const leadCell =
    lead === "art"
      ? el("div", { class: "mu-song-art" }, [art(m.coverUrl(song, 96), () => el("div", { class: "noart" }, [mi("note", 16)]))])
      : el("div", { class: "mu-song-num" }, [
          lead === "rank" ? String(opts.rank ?? "") : song.IndexNumber != null ? String(song.IndexNumber) : "",
        ]);
  const play = opts.onPlay ?? (() => void audio.play([song]).catch(report));
  const sub: string[] = [];
  if (opts.showArtist !== false && lead !== "number") sub.push(m.artistLine(song));
  if (opts.showAlbum && song.Album) sub.push(song.Album);
  const more = iconButton("more", "More", (ev) => {
    ev.stopPropagation();
    openActionMenu(more, song.Name ?? null, musicActions(song, opts.actions), { fixed: true });
  }, "mu-song-more");
  const row = el("div", {
    class: "mu-song",
    role: "button",
    tabindex: "0",
    "data-id": song.Id,
    onDblclick: play,
    onKeydown: (ev: KeyboardEvent) => {
      if (ev.key === "Enter" && ev.target === ev.currentTarget) {
        ev.preventDefault();
        play();
      }
    },
  }, [
    leadCell,
    el("button", { class: "mu-song-play", title: "Play", "aria-label": `Play ${song.Name ?? ""}`, onClick: (ev: MouseEvent) => { ev.stopPropagation(); play(); } }, [mi("play", 14)]),
    el("div", { class: "mu-song-text" }, [
      el("div", { class: "mu-song-title" }, [
        song.Name ?? "",
        song.UserData?.IsFavorite ? el("span", { class: "mu-fav", title: "Favorite" }, ["★"]) : null,
      ]),
      sub.length ? el("div", { class: "mu-song-sub" }, [sub.join(" · ")]) : null,
    ]),
    el("div", { class: "mu-song-time" }, [song.RunTimeTicks ? m.clock(m.secondsOf(song.RunTimeTicks)) : ""]),
    more,
  ]);
  // Single click selects, the desktop convention for a track list; the play
  // button and double-click play. Ctrl/Shift extend the selection.
  row.addEventListener("click", (ev) => selectRow(row, ev));
  attachContextMenu(row, song.Name ?? null, () => {
    const sel = selectedSongs(row);
    if (sel.length > 1 && row.classList.contains("selected")) return selectionActions(sel);
    return musicActions(song, opts.actions);
  });
  (row as any).__song = song;
  return row;
}

/** A list of song rows that plays from the clicked row onward. */
export function songList(songs: any[], opts: Omit<SongRowOpts, "onPlay"> & { title?: string; discs?: boolean } = {}): HTMLElement {
  const list = el("div", { class: "mu-songs" });
  const multiDisc = opts.discs && new Set(songs.map((s) => s.ParentIndexNumber ?? 1)).size > 1;
  let disc: number | null = null;
  songs.forEach((s, i) => {
    if (multiDisc && (s.ParentIndexNumber ?? 1) !== disc) {
      disc = s.ParentIndexNumber ?? 1;
      list.append(el("div", { class: "mu-disc" }, [`Disc ${disc}`]));
    }
    list.append(songRow(s, { ...opts, rank: i + 1, onPlay: () => void audio.play(songs, i, { title: opts.title ?? "" }).catch(report) }));
  });
  markPlaying(list);
  return list;
}

// ---------- Selection (for New Playlist… from a selection) ----------

let anchor: HTMLElement | null = null;

function rowsIn(row: HTMLElement): HTMLElement[] {
  const list = row.closest(".mu-songs");
  return list ? Array.from(list.querySelectorAll<HTMLElement>(".mu-song")) : [row];
}

function selectRow(row: HTMLElement, ev: MouseEvent): void {
  const rows = rowsIn(row);
  if (ev.shiftKey && anchor && rows.includes(anchor)) {
    const a = rows.indexOf(anchor), b = rows.indexOf(row);
    const [lo, hi] = a < b ? [a, b] : [b, a];
    rows.forEach((r, i) => r.classList.toggle("selected", i >= lo && i <= hi));
  } else if (ev.ctrlKey || ev.metaKey) {
    row.classList.toggle("selected");
    anchor = row;
  } else {
    rows.forEach((r) => r.classList.toggle("selected", r === row));
    anchor = row;
  }
  updateSelectionBar(row);
}

function selectedSongs(row: HTMLElement): any[] {
  return rowsIn(row).filter((r) => r.classList.contains("selected")).map((r) => (r as any).__song).filter(Boolean);
}

function selectionActions(songs: any[]): MenuAction[] {
  return [
    { label: `Play ${songs.length} Songs`, icon: "play", run: () => void audio.play(songs).catch(report) },
    { label: "Play Next", run: () => void audio.playNext(songs).catch(report) },
    { label: "Play Later", run: () => void audio.playLater(songs).catch(report) },
    {
      label: "Add to Playlist",
      icon: "library",
      submenu: {
        label: "Add to Playlist",
        items: () => [
          { label: "New Playlist…", run: () => newPlaylistWith(songs) },
          ...(playlistCache ?? []).map((p) => ({
            label: p.Name,
            run: async () => {
              try {
                await m.addToPlaylist(p.Id, songs.map((s) => s.Id));
                toast(`Added ${songs.length} songs to “${p.Name}”`, "ok");
                playlistsChanged.dispatchEvent(new Event("change"));
              } catch (e) {
                report(e);
              }
            },
          })),
        ],
      },
    },
  ];
}

function updateSelectionBar(row: HTMLElement): void {
  const list = row.closest(".mu-songs") as HTMLElement | null;
  if (!list) return;
  void primePlaylists();
  list.querySelector(".mu-selbar")?.remove();
  const songs = selectedSongs(row);
  if (songs.length < 2) return;
  const bar = el("div", { class: "mu-selbar" }, [
    el("span", {}, [`${songs.length} selected`]),
    el("button", { class: "btn small", onClick: () => void audio.play(songs).catch(report) }, ["Play"]),
    el("button", { class: "btn small", onClick: () => void audio.playNext(songs).catch(report) }, ["Play Next"]),
    el("button", { class: "btn small primary", onClick: () => void newPlaylistWith(songs) }, ["New Playlist…"]),
    el("button", {
      class: "btn small",
      onClick: (ev: MouseEvent) => openActionMenu(ev.currentTarget as HTMLElement, null, selectionActions(songs).slice(3), { fixed: true }),
    }, ["Add to Playlist"]),
    el("button", {
      class: "btn small",
      onClick: () => {
        list.querySelectorAll(".mu-song.selected").forEach((r) => r.classList.remove("selected"));
        bar.remove();
      },
    }, ["Clear"]),
  ]);
  list.prepend(bar);
}

// ---------- Page header ----------

export function pageHeader(opts: {
  item?: any;
  cover?: string | null;
  round?: boolean;
  eyebrow?: string;
  title: string;
  lines?: (string | Node | null)[];
  buttons?: (HTMLElement | null)[];
}): HTMLElement {
  return el("header", { class: "mu-head" }, [
    el("div", { class: `mu-head-cover${opts.round ? " round" : ""}` }, [
      art(opts.cover ?? null, () => el("div", { class: "noart" }, [mi("note", 48)]), { lazy: false, hash: opts.item ? api.imageHash(opts.item) : null }),
    ]),
    el("div", { class: "mu-head-text" }, [
      opts.eyebrow ? el("div", { class: "mu-eyebrow" }, [opts.eyebrow]) : null,
      el("h1", { class: "mu-title" }, [opts.title]),
      ...(opts.lines ?? []).filter(Boolean).map((l) => el("div", { class: "mu-head-line" }, [l as any])),
      el("div", { class: "mu-head-buttons" }, (opts.buttons ?? []).filter(Boolean) as HTMLElement[]),
    ]),
  ]);
}

export function playButtons(item: any, opts: { station?: boolean; songs?: () => Promise<any[]> } = {}): HTMLElement[] {
  const songs = opts.songs ?? (() => songsOf(item));
  const go = async (shuffle: boolean) => {
    try {
      const list = await songs();
      if (!list.length) return toast("Nothing to play there");
      await audio.play(list, 0, { title: item.Name ?? "", shuffle });
    } catch (e) {
      report(e);
    }
  };
  const out: HTMLElement[] = [
    el("button", { class: "btn primary", onClick: () => void go(false) }, [mi("play"), " Play"]),
    el("button", { class: "btn", onClick: () => void go(true) }, [mi("shuffle"), " Shuffle"]),
  ];
  if (opts.station !== false) out.push(el("button", { class: "btn", onClick: () => void startStation(item) }, [mi("station"), " Station"]));
  const more = iconButton("more", "More", () => openActionMenu(more, item.Name ?? null, musicActions(item, { hideGoTo: true }), { fixed: true }));
  out.push(more);
  return out;
}

export function link(text: string, hash: string | null): HTMLElement | string {
  if (!hash) return text;
  return el("a", { class: "mu-link", href: hash }, [text]);
}
