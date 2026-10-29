import "../music.css";
// Music: Listen Now (Discover), the Library (playlists, artists, albums, songs,
// genres), and the album, artist, genre and playlist pages. The Apple app's
// iPhone/iPad Music tab, laid out for a window with a sidebar and a mouse.
//
// Routes (all under #/music/):
//   discover · library/<tab> · album/<id> · artist/<id> · genre/<id>
//   playlist/<id> · smart/<id> · smart-edit/<id|new> · songs/<recent|top>
//   search/<term>
import * as api from "../api";
import * as m from "../musicApi";
import * as audio from "../audio";
import { getCached, setCached, itemSignature } from "../cache";
import { el, clear, toast, emptyState, errorState, openDialog, skeletonRow, spinner, openActionMenu } from "../ui";
import { buildSurprise, DIALS, DIAL_INFO, PRESETS, BUDGET, getMixPoints, saveMixPoints, withDial, remaining, presetName, type MixPoints } from "../stations";
import {
  getSmartPlaylists, saveSmartPlaylist, deleteSmartPlaylist, smartPlaylistSongs, asItem, describe, blankSmartPlaylist, type SmartPlaylist,
} from "../smartPlaylists";
import {
  mi, musicCard, shelf, grid, songList, songRow, pageHeader, playButtons, link, askName, newPlaylistWith,
  playlistsChanged, startStation, primePlaylists, markPlaying, iconButton, musicActions,
} from "./musicCommon";
import { renderDownloaded } from "./musicDownloads";

function report(e: any): void {
  toast(e?.message ?? String(e), "error");
}

/** Keep the "now playing" row mark current while a page is open. */
function trackPlaying(root: HTMLElement): void {
  const off = audio.onChange(() => {
    if (!root.isConnected) return off();
    markPlaying(root);
  });
}

export async function renderMusic(content: HTMLElement, arg: string): Promise<void> {
  const [page, ...rest] = (arg || "discover").split("/");
  const id = decodeURIComponent(rest.join("/"));
  clear(content);
  // A wrapper rather than a class on #content, which every page shares.
  const root = el("div", { class: "mu-page" });
  content.append(root);
  void primePlaylists();
  switch (page) {
    case "library": return renderLibrary(root, id || "albums");
    case "album": return renderAlbum(root, id);
    case "artist": return renderArtist(root, id);
    case "genre": return renderGenre(root, id);
    case "playlist": return renderPlaylist(root, id);
    case "smart": return renderSmart(root, id);
    case "smart-edit": return renderSmartEditor(root, id);
    case "songs": return renderSongChart(root, id);
    case "search": return renderMusicSearch(root, id);
    case "downloaded": return renderDownloaded(root, musicTabs("downloaded"));
    default: return renderDiscover(root);
  }
}

// ---------- Discover ----------

interface DiscoverData {
  recent: any[];
  top: any[];
  added: any[];
  favAlbums: any[];
  favArtists: any[];
  random: any[];
  stations: { title: string; sub: string; seed: any }[];
}

function discoverSig(d: DiscoverData): string {
  return [d.recent, d.top, d.added, d.favAlbums, d.favArtists].map(itemSignature).join("#") +
    d.stations.map((s) => s.seed.Id).join(",");
}

let genreIndex: Map<string, any> | null = null;
async function genreByName(name: string): Promise<any | null> {
  if (!genreIndex) {
    const all = await m.musicGenres().catch(() => []);
    genreIndex = new Map(all.map((g) => [String(g.Name).toLowerCase(), g]));
  }
  return genreIndex.get(name.toLowerCase()) ?? null;
}

async function fetchDiscover(): Promise<DiscoverData> {
  const none = { Items: [] as any[], TotalRecordCount: 0 };
  const [recentSongs, top, added, favAlbums, favArtists, random] = await Promise.all([
    m.recentlyPlayedSongs(60).catch(() => []),
    m.mostPlayedSongs(40).catch(() => []),
    m.music({ types: "MusicAlbum", sort: "added", limit: 24 }).catch(() => none),
    m.music({ types: "MusicAlbum", sort: "name", favorites: true, limit: 24 }).catch(() => none),
    m.artists({ favorites: true, limit: 24 }).catch(() => none),
    m.music({ types: "MusicAlbum", sort: "random", limit: 16 }).catch(() => none),
  ]);
  // Stations from the artists and genres played most: what the Apple app's
  // "Your Stations" row is built from.
  const artistCount = new Map<string, { n: number; a: any }>();
  const genreCount = new Map<string, number>();
  for (const s of [...top, ...recentSongs]) {
    const a = s.AlbumArtists?.[0] ?? s.ArtistItems?.[0];
    if (a?.Id) artistCount.set(a.Id, { n: (artistCount.get(a.Id)?.n ?? 0) + 1, a });
    for (const g of s.Genres ?? []) genreCount.set(g, (genreCount.get(g) ?? 0) + 1);
  }
  const stations: DiscoverData["stations"] = [];
  // A compilation's billing isn't an artist to build a station from.
  const notAnArtist = /^(various( artists)?|va|unknown artist|soundtrack)$/i;
  for (const { a } of [...artistCount.values()].filter(({ a }) => !notAnArtist.test(String(a.Name ?? "").trim())).sort((x, y) => y.n - x.n).slice(0, 4)) {
    stations.push({ title: `${a.Name} Station`, sub: "Built from an artist you play", seed: { Id: a.Id, Name: a.Name, Type: "MusicArtist", ImageTags: {} } });
  }
  for (const [name] of [...genreCount.entries()].sort((x, y) => y[1] - x[1]).slice(0, 3)) {
    const g = await genreByName(name);
    if (g) stations.push({ title: `${g.Name} Station`, sub: "Built from a genre you play", seed: g });
  }
  return {
    recent: m.albumsInOrder(recentSongs).slice(0, 20),
    top: top.slice(0, 15),
    added: added.Items,
    favAlbums: favAlbums.Items,
    favArtists: favArtists.Items,
    random: random.Items,
    stations,
  };
}

async function surprise(btn: HTMLButtonElement): Promise<void> {
  btn.disabled = true;
  try {
    const { source, first } = await buildSurprise();
    await audio.play(first, 0, { title: source.title, source });
  } catch (e) {
    report(e);
  } finally {
    btn.disabled = false;
  }
}

function stationTile(s: { title: string; sub: string; seed: any }): HTMLElement {
  return el("button", { class: "mu-station", onClick: () => void startStation(s.seed) }, [
    el("div", { class: "mu-station-art" }, [mi("station", 34)]),
    el("div", { class: "mu-card-title" }, [s.title]),
    el("div", { class: "mu-card-sub" }, [s.sub]),
  ]);
}

function musicTabs(active: string): HTMLElement {
  const tabs: [string, string][] = [
    ["discover", "Listen Now"],
    ["library/playlists", "Playlists"],
    ["library/artists", "Artists"],
    ["library/albums", "Albums"],
    ["library/songs", "Songs"],
    ["library/genres", "Genres"],
    ["search", "Search"],
    ["downloaded", "Downloaded"],
  ];
  return el("nav", { class: "mu-tabs", "aria-label": "Music" }, tabs.map(([r, label]) =>
    el("a", { class: `mu-tab${r === active ? " active" : ""}`, href: `#/music/${r}`, "aria-current": r === active ? "page" : null }, [label])
  ));
}

async function renderDiscover(root: HTMLElement): Promise<void> {
  const surpriseBtn = el("button", { class: "btn primary", onClick: () => void surprise(surpriseBtn) }, [mi("shuffle"), " Surprise Me"]) as HTMLButtonElement;
  const head = el("div", { class: "mu-page-head" }, [
    el("h1", { class: "page-title" }, ["Listen Now"]),
    el("div", { class: "mu-head-buttons" }, [
      surpriseBtn,
      el("button", { class: "btn", onClick: openMixDialog }, [mi("mix"), " Station Mix…"]),
    ]),
  ]);
  const body = el("div", { class: "mu-discover" });
  root.append(head, musicTabs("discover"), body);

  const paint = (d: DiscoverData) => {
    clear(body);
    const bare = !d.recent.length && !d.added.length && !d.favAlbums.length && !d.random.length;
    if (bare) {
      body.append(emptyState({
        icon: "library",
        title: "Nothing to suggest yet",
        body: "Once your music library has been scanned, and once you've played a few things, this page fills in with what to play next.",
      }));
      return;
    }
    const topList = songList(d.top, { lead: "art", title: "Top Songs", showAlbum: false });
    topList.classList.add("columns");
    const parts = [
      shelf("Recently Played", d.recent.map((a) => musicCard(a)), () => void (location.hash = "#/music/songs/recent")),
      d.stations.length ? shelf("Your Stations", d.stations.map(stationTile), undefined, "Built from what you play") : null,
      d.top.length
        ? el("section", { class: "mu-shelf" }, [
            el("div", { class: "section-head" }, [
              el("h2", {}, ["Your Top Songs"]),
              el("a", { class: "see-all", onClick: () => void (location.hash = "#/music/songs/top") }, ["See all"]),
            ]),
            topList,
          ])
        : null,
      shelf("New in Your Library", d.added.map((a) => musicCard(a)), () => void (location.hash = "#/music/library/albums?sort=added")),
      shelf("Favorite Albums", d.favAlbums.map((a) => musicCard(a))),
      shelf("Favorite Artists", d.favArtists.map((a) => musicCard(a))),
      shelf("Something Different", d.random.map((a) => musicCard(a)), undefined, "A random draw from the shelves"),
    ];
    body.append(...parts.filter(Boolean) as HTMLElement[]);
    trackPlaying(body);
  };

  const cached = getCached<DiscoverData>("music:discover");
  if (cached) paint(cached);
  else body.append(skeletonRow(7), skeletonRow(7));
  const fresh = await fetchDiscover();
  if (!root.isConnected) return;
  if (!cached || discoverSig(cached) !== discoverSig(fresh)) paint(fresh);
  setCached("music:discover", fresh);
}

/** "Recently Played" and "Most Played" as full lists. */
async function renderSongChart(root: HTMLElement, kind: string): Promise<void> {
  const top = kind === "top";
  const title = top ? "Most Played" : "Recently Played";
  root.append(el("h1", { class: "page-title" }, [title]));
  const body = el("div");
  root.append(body);
  const key = `music:chart:${kind}`;
  const paint = (songs: any[]) => {
    clear(body);
    if (!songs.length) return body.append(emptyState({ title: "Nothing played yet" }));
    body.append(el("div", { class: "mu-head-buttons" }, [
      el("button", { class: "btn primary", onClick: () => void audio.play(songs, 0, { title }) }, [mi("play"), " Play"]),
      el("button", { class: "btn", onClick: () => void audio.play(songs, 0, { title, shuffle: true }) }, [mi("shuffle"), " Shuffle"]),
    ]), songList(songs, { lead: top ? "rank" : "art", showAlbum: true, title }));
    trackPlaying(body);
  };
  const cached = getCached<any[]>(key);
  if (cached) paint(cached);
  else body.append(spinner());
  const fresh = top ? await m.mostPlayedSongs(200) : await m.recentlyPlayedSongs(200);
  if (!cached || itemSignature(cached) !== itemSignature(fresh)) paint(fresh);
  setCached(key, fresh);
}

// ---------- Station mix ----------

export function openMixDialog(): void {
  let pts: MixPoints = getMixPoints();
  const box = el("div", { class: "mu-mix" });
  const draw = () => {
    clear(box);
    box.append(
      el("p", { class: "mu-mix-intro" }, [
        `Twenty points to spend on what stations favour. A dial can only take what's left, so more of one is less of another. ${remaining(pts)} left · ${presetName(pts)}`,
      ]),
      el("div", { class: "mu-mix-presets" }, PRESETS.map((p) =>
        el("button", {
          class: `btn small${presetName(pts) === p.name ? " active" : ""}`,
          onClick: () => {
            pts = { ...p.points };
            draw();
          },
        }, [p.name])
      )),
      ...DIALS.map((d) => {
        const range = el("input", { type: "range", min: "0", max: String(BUDGET), step: "1", value: String(pts[d]), "aria-label": DIAL_INFO[d].label }) as HTMLInputElement;
        const val = el("span", { class: "mu-mix-val" }, [String(pts[d])]);
        range.addEventListener("input", () => {
          pts = withDial(pts, d, Number(range.value));
          range.value = String(pts[d]);
          val.textContent = String(pts[d]);
          const intro = box.querySelector(".mu-mix-intro");
          if (intro) intro.textContent = `Twenty points to spend on what stations favour. A dial can only take what's left, so more of one is less of another. ${remaining(pts)} left · ${presetName(pts)}`;
          box.querySelectorAll<HTMLButtonElement>(".mu-mix-presets .btn").forEach((b) => b.classList.toggle("active", b.textContent === presetName(pts)));
        });
        return el("label", { class: "mu-mix-row" }, [
          el("div", {}, [el("div", { class: "mu-mix-name" }, [DIAL_INFO[d].label]), el("div", { class: "mu-mix-help" }, [DIAL_INFO[d].help])]),
          range,
          val,
        ]);
      })
    );
  };
  draw();
  openDialog({
    title: "Station Mix",
    body: [box],
    wide: true,
    actions: [
      { label: "Cancel" },
      { label: "Save", primary: true, run: () => void saveMixPoints(pts).then(() => toast("Station mix saved", "ok")).catch(report) },
    ],
  });
}

// ---------- Library ----------

const LIB_SORTS: Record<string, (keyof typeof m.SORTS)[]> = {
  albums: ["name", "artist", "added", "year", "played", "random"],
  artists: ["name", "added", "random"],
  songs: ["name", "artist", "added", "plays", "played", "random"],
};

function libPrefs(tab: string): { sort: keyof typeof m.SORTS } {
  try {
    const raw = JSON.parse(localStorage.getItem(`aquarium.music-lib.${tab}`) ?? "{}");
    if (raw.sort && LIB_SORTS[tab]?.includes(raw.sort)) return raw;
  } catch {
    // Default below.
  }
  return { sort: "name" };
}

function saveLibPrefs(tab: string, p: { sort: string }): void {
  try {
    localStorage.setItem(`aquarium.music-lib.${tab}`, JSON.stringify(p));
  } catch {
    // Just for this session then.
  }
}

async function renderLibrary(root: HTMLElement, tabArg: string): Promise<void> {
  const [tab, query] = tabArg.split("?");
  const params = new URLSearchParams(query ?? "");
  root.append(
    el("div", { class: "mu-page-head" }, [el("h1", { class: "page-title" }, ["Library"])]),
    musicTabs(`library/${tab}`)
  );
  const bar = el("div", { class: "filter-bar mu-filter" });
  const body = el("div", { class: "mu-lib-body" });
  root.append(bar, body);

  if (tab === "playlists") return renderPlaylistsTab(bar, body);
  if (tab === "genres") return renderGenresTab(bar, body);

  const prefs = libPrefs(tab);
  const fromParam = params.get("sort");
  if (fromParam && LIB_SORTS[tab]?.includes(fromParam as any)) prefs.sort = fromParam as any;
  const filter = el("input", { type: "search", class: "mu-input mu-filter-input", placeholder: `Filter ${tab}`, "aria-label": `Filter ${tab}` }) as HTMLInputElement;
  const sortSel = el("select", { class: "mu-select", "aria-label": "Sort" }, (LIB_SORTS[tab] ?? ["name"]).map((k) =>
    el("option", { value: k, selected: k === prefs.sort ? "" : null }, [m.SORTS[k].label])
  )) as HTMLSelectElement;
  const favBtn = el("button", { class: "btn small" }, [mi("note"), " Favorites"]) as HTMLButtonElement;
  const count = el("span", { class: "lib-count" });
  bar.append(filter, sortSel, favBtn, count);
  let favorites = false;

  const PAGE = 100;
  let start = 0;
  let total = Infinity;
  let gen = 0;
  let loading = false;
  let container: HTMLElement;
  let songsSoFar: any[] = [];
  /** The first page of an unfiltered list is kept, to paint at once next time. */
  let cacheKey: string | null = null;
  const sentinel = el("div", { class: "mu-sentinel" });

  const fetchPage = async (from: number) => {
    const term = filter.value.trim() || undefined;
    if (tab === "artists") return m.artists({ startIndex: from, limit: PAGE, sort: prefs.sort, searchTerm: term, favorites });
    return m.music({
      types: tab === "songs" ? "Audio" : "MusicAlbum",
      sort: prefs.sort,
      startIndex: from,
      limit: PAGE,
      searchTerm: term,
      favorites,
    });
  };

  const append = (items: any[]) => {
    if (tab === "songs") {
      const base = songsSoFar.length;
      songsSoFar.push(...items);
      for (const [i, s] of items.entries()) {
        container.append(songRow(s, {
          lead: "art",
          showAlbum: true,
          onPlay: () => void audio.play(songsSoFar, base + i, { title: "Songs" }),
        }));
      }
      markPlaying(container);
    } else {
      container.append(...items.map((i) => musicCard(i)));
    }
  };

  const more = async () => {
    if (loading || start >= total) return;
    loading = true;
    const my = gen;
    try {
      const from = start;
      const r = await fetchPage(from);
      if (my !== gen) return;
      if (from === 0 && cacheKey) setCached(cacheKey, r);
      total = r.TotalRecordCount;
      count.textContent = `${total.toLocaleString()} ${tab}`;
      start += r.Items.length;
      if (!r.Items.length) total = start;
      append(r.Items);
    } catch (e) {
      if (my === gen) body.append(errorState("Couldn't load the library", e, () => void reset()));
    } finally {
      loading = false;
    }
  };

  const reset = async () => {
    gen++;
    start = 0;
    total = Infinity;
    songsSoFar = [];
    clear(body);
    container = tab === "songs" ? el("div", { class: "mu-songs" }) : el("div", { class: "mu-grid" });
    body.append(container, sentinel);
    const key = `music:lib:${tab}:${prefs.sort}:${favorites}`;
    cacheKey = !filter.value && prefs.sort !== "random" ? key : null;
    const cached = cacheKey ? getCached<any>(key) : undefined;
    if (cached) {
      append(cached.Items);
      start = cached.Items.length;
      total = cached.TotalRecordCount;
      count.textContent = `${total.toLocaleString()} ${tab}`;
      // Check the first page behind the paint; repaint only on change.
      const my = gen;
      void fetchPage(0).then((r) => {
        if (my !== gen) return;
        setCached(key, r);
        if (itemSignature(r.Items) !== itemSignature(cached.Items)) void reset();
      }).catch(() => {});
      return;
    }
    await more();
  };

  const io = new IntersectionObserver((entries) => {
    if (!root.isConnected) return io.disconnect();
    if (entries.some((e) => e.isIntersecting)) void more();
  }, { root: document.getElementById("content"), rootMargin: "800px" });
  io.observe(sentinel);

  let debounce = 0;
  filter.addEventListener("input", () => {
    clearTimeout(debounce);
    debounce = window.setTimeout(() => void reset(), 300);
  });
  sortSel.addEventListener("change", () => {
    prefs.sort = sortSel.value as any;
    saveLibPrefs(tab, prefs);
    void reset();
  });
  favBtn.addEventListener("click", () => {
    favorites = !favorites;
    favBtn.classList.toggle("active", favorites);
    void reset();
  });
  if (tab === "songs") trackPlaying(body);
  await reset();
}

async function renderGenresTab(bar: HTMLElement, body: HTMLElement): Promise<void> {
  const filter = el("input", { type: "search", class: "mu-input mu-filter-input", placeholder: "Filter genres", "aria-label": "Filter genres" }) as HTMLInputElement;
  bar.append(filter);
  let all: any[] = getCached<any[]>("music:genres") ?? [];
  const paint = () => {
    clear(body);
    const term = filter.value.trim().toLowerCase();
    const shown = all.filter((g) => !term || String(g.Name).toLowerCase().includes(term));
    if (!shown.length) return body.append(emptyState({ title: all.length ? "No genres match" : "No genres" }));
    body.append(el("div", { class: "mu-genres" }, shown.map((g) =>
      el("a", { class: "mu-genre", href: `#/music/genre/${g.Id}` }, [g.Name])
    )));
  };
  if (all.length) paint();
  else body.append(spinner());
  filter.addEventListener("input", paint);
  const fresh = await m.musicGenres();
  if (itemSignature(fresh) !== itemSignature(all)) {
    all = fresh;
    paint();
  }
  setCached("music:genres", fresh);
}

async function renderPlaylistsTab(bar: HTMLElement, body: HTMLElement): Promise<void> {
  const filter = el("input", { type: "search", class: "mu-input mu-filter-input", placeholder: "Filter playlists", "aria-label": "Filter playlists" }) as HTMLInputElement;
  bar.append(
    filter,
    el("button", { class: "btn small primary", onClick: () => void newPlaylistWith([]) }, [mi("plus"), " New Playlist"]),
    el("button", { class: "btn small", onClick: () => void (location.hash = "#/music/smart-edit/new") }, [mi("smart"), " New Smart Playlist"]),
  );
  let lists: any[] = getCached<any[]>("music:playlists") ?? [];
  const paint = () => {
    clear(body);
    const term = filter.value.trim().toLowerCase();
    const smart = getSmartPlaylists().filter((p) => !term || p.name.toLowerCase().includes(term));
    const server = lists.filter((p) => !term || String(p.Name).toLowerCase().includes(term));
    if (smart.length) {
      body.append(el("h2", { class: "mu-sub-head" }, ["Smart Playlists"]),
        grid(smart.map((p) => musicCard(asItem(p), { sub: describe(p) }))));
    }
    body.append(el("h2", { class: "mu-sub-head" }, ["Playlists"]));
    body.append(server.length ? grid(server.map((p) => musicCard(p))) : emptyState({ title: "No playlists yet", body: "Make one here, or from any song's menu with Add to Playlist → New Playlist…" }));
  };
  paint();
  filter.addEventListener("input", paint);
  const refresh = async () => {
    const fresh = await m.audioPlaylists();
    if (itemSignature(fresh) !== itemSignature(lists) || fresh.map((p) => p.Name + p.ChildCount).join() !== lists.map((p) => p.Name + p.ChildCount).join()) {
      lists = fresh;
      if (body.isConnected) paint();
    }
    setCached("music:playlists", fresh);
  };
  const onChange = () => (body.isConnected ? void refresh() : playlistsChanged.removeEventListener("change", onChange));
  playlistsChanged.addEventListener("change", onChange);
  await refresh();
}

// ---------- Album ----------

async function renderAlbum(root: HTMLElement, id: string): Promise<void> {
  const key = `music:album:${id}`;
  const paint = (d: { album: any; tracks: any[]; more: any[] }) => {
    clear(root);
    const { album, tracks } = d;
    const secs = tracks.reduce((n, t) => n + m.secondsOf(t.RunTimeTicks), 0);
    const artist = album.AlbumArtists?.[0];
    root.append(pageHeader({
      item: album,
      cover: m.coverUrl(album, 600),
      eyebrow: "Album",
      title: album.Name ?? "",
      lines: [
        link(m.artistLine(album), artist?.Id ? `#/music/artist/${artist.Id}` : null),
        [album.Genres?.[0], album.ProductionYear, `${tracks.length} song${tracks.length === 1 ? "" : "s"}`, secs ? m.longDuration(secs) : ""].filter(Boolean).join(" · "),
      ],
      buttons: playButtons(album, { songs: async () => tracks }),
    }));
    root.append(songList(tracks, { lead: "number", discs: true, title: album.Name, actions: { hideGoTo: false } }));
    if (d.more.length) {
      root.append(shelf(`More by ${artist?.Name ?? m.artistLine(album)}`, d.more.map((a) => musicCard(a)))!);
    }
    trackPlaying(root);
  };
  const cached = getCached<any>(key);
  if (cached) paint(cached);
  else root.append(spinner());
  const album = await m.musicItem(id);
  const tracks = await m.albumTracks(id);
  const artistId = album.AlbumArtists?.[0]?.Id;
  const more = artistId ? (await m.albumsBy(artistId).catch(() => [])).filter((a) => a.Id !== id) : [];
  const fresh = { album, tracks, more };
  if (!root.isConnected) return;
  if (!cached || itemSignature([cached.album, ...cached.tracks]) !== itemSignature([album, ...tracks])) paint(fresh);
  setCached(key, fresh);
}

// ---------- Artist ----------

async function renderArtist(root: HTMLElement, id: string): Promise<void> {
  const key = `music:artist:${id}`;
  const paint = (d: { artist: any; top: any[]; albums: any[]; appears: any[]; similar: any[] }) => {
    clear(root);
    const a = d.artist;
    const backdrop = api.imageUrl(a, "Backdrop", 1600);
    if (backdrop) root.append(el("div", { class: "mu-artist-backdrop", style: `background-image:url("${backdrop}")` }));
    root.append(pageHeader({
      item: a,
      cover: m.coverUrl(a, 500),
      round: true,
      eyebrow: "Artist",
      title: a.Name ?? "",
      lines: [[d.albums.length ? `${d.albums.length} album${d.albums.length === 1 ? "" : "s"}` : "", a.Genres?.slice(0, 3).join(", ")].filter(Boolean).join(" · ")],
      buttons: playButtons(a),
    }));
    if (d.top.length) {
      root.append(el("section", { class: "mu-shelf" }, [
        el("div", { class: "section-head" }, [el("h2", {}, ["Top Songs"])]),
        (() => {
          const l = songList(d.top, { lead: "art", showAlbum: true, title: `${a.Name} — Top Songs` });
          l.classList.add("columns");
          return l;
        })(),
      ]));
    }
    const albums = shelf("Albums", d.albums.map((x) => musicCard(x, { sub: x.ProductionYear ? String(x.ProductionYear) : "" })));
    if (albums) root.append(albums);
    const appears = shelf("Appears On", d.appears.map((x) => musicCard(x)));
    if (appears) root.append(appears);
    if (a.Overview) {
      root.append(el("section", { class: "mu-shelf" }, [
        el("div", { class: "section-head" }, [el("h2", {}, ["About"])]),
        el("p", { class: "mu-about" }, [a.Overview]),
      ]));
    }
    const similar = shelf("Similar Artists", d.similar.map((x) => musicCard(x)));
    if (similar) root.append(similar);
    trackPlaying(root);
  };
  const cached = getCached<any>(key);
  if (cached) paint(cached);
  else root.append(spinner());
  const [artist, top, albums, appears, similar] = await Promise.all([
    m.musicItem(id),
    m.topSongs(id, 10).catch(() => []),
    m.albumsBy(id).catch(() => []),
    m.appearsOn(id).catch(() => []),
    m.similarArtists(id, 12).catch(() => []),
  ]);
  const fresh = { artist, top, albums, appears, similar };
  if (!root.isConnected) return;
  const sig = (d: any) => itemSignature([d.artist, ...d.top, ...d.albums, ...d.appears]);
  if (!cached || sig(cached) !== sig(fresh)) paint(fresh);
  setCached(key, fresh);
}

// ---------- Genre ----------

async function renderGenre(root: HTMLElement, id: string): Promise<void> {
  const key = `music:genre:${id}`;
  const paint = (d: { genre: any; albums: any[]; songs: any[] }) => {
    clear(root);
    root.append(pageHeader({
      item: d.genre,
      cover: m.coverUrl(d.genre, 500),
      eyebrow: "Genre",
      title: d.genre.Name ?? "",
      buttons: playButtons({ ...d.genre, Type: "MusicGenre" }),
    }));
    if (d.songs.length) {
      const l = songList(d.songs, { lead: "art", showAlbum: true, title: d.genre.Name });
      l.classList.add("columns");
      root.append(el("section", { class: "mu-shelf" }, [el("div", { class: "section-head" }, [el("h2", {}, ["Popular Songs"])]), l]));
    }
    root.append(el("h2", { class: "mu-sub-head" }, ["Albums"]), grid(d.albums.map((a) => musicCard(a))));
    trackPlaying(root);
  };
  const cached = getCached<any>(key);
  if (cached) paint(cached);
  else root.append(spinner());
  const [genre, albums, songs] = await Promise.all([
    m.musicItem(id),
    m.music({ types: "MusicAlbum", genreIds: [id], sort: "name", limit: 300 }).then((r) => r.Items),
    m.music({ types: "Audio", genreIds: [id], sort: "plays", limit: 12 }).then((r) => r.Items),
  ]);
  const fresh = { genre, albums, songs };
  if (!root.isConnected) return;
  if (!cached || itemSignature(cached.albums) !== itemSignature(albums)) paint(fresh);
  setCached(key, fresh);
}

// ---------- Playlist ----------

async function renderPlaylist(root: HTMLElement, id: string): Promise<void> {
  const key = `music:playlist:${id}`;
  let editing = false;
  let state: { list: any; songs: any[] } | null = getCached<any>(key) ?? null;

  const paint = () => {
    if (!state) return;
    clear(root);
    const { list, songs } = state;
    const secs = songs.reduce((n, t) => n + m.secondsOf(t.RunTimeTicks), 0);
    const editBtn = el("button", { class: `btn${editing ? " primary" : ""}`, onClick: () => { editing = !editing; paint(); } }, [mi("edit"), editing ? " Done" : " Edit"]);
    const more = iconButton("more", "More", () => openActionMenu(more, list.Name ?? null, [
      { label: "Rename…", run: async () => {
        const name = await askName("Rename Playlist", list.Name ?? "");
        if (!name) return;
        try {
          await m.renamePlaylist(id, name);
          list.Name = name;
          playlistsChanged.dispatchEvent(new Event("change"));
          paint();
        } catch (e) { report(e); }
      } },
      { label: "Start Station", run: () => void startStation(list) },
      { label: "Delete Playlist", icon: "trash", danger: true, run: () => {
        openDialog({
          title: `Delete “${list.Name}”?`,
          body: ["The playlist is removed from the server for every device. The songs in it stay in your library."],
          actions: [
            { label: "Cancel", primary: true },
            { label: "Delete", danger: true, run: async () => {
              try {
                await m.deletePlaylist(id);
                playlistsChanged.dispatchEvent(new Event("change"));
                toast("Playlist deleted", "ok");
                location.hash = "#/music/library/playlists";
              } catch (e) { report(e); }
            } },
          ],
        });
      } },
    ], { fixed: true }));
    root.append(pageHeader({
      item: list,
      cover: m.coverUrl(list, 600),
      eyebrow: "Playlist",
      title: list.Name ?? "",
      lines: [`${songs.length} song${songs.length === 1 ? "" : "s"}${secs ? ` · ${m.longDuration(secs)}` : ""}`],
      buttons: [...playButtons(list, { songs: async () => songs }).slice(0, 2), editBtn, more],
    }));
    if (!songs.length) {
      root.append(emptyState({ title: "This playlist is empty", body: "Add songs from any song, album or artist menu with Add to Playlist." }));
      return;
    }
    if (!editing) {
      root.append(songList(songs, {
        lead: "art",
        showAlbum: true,
        title: list.Name,
        actions: {},
      }));
      // Remove from the menu, by entry.
      root.querySelectorAll<HTMLElement>(".mu-song").forEach((row, i) => {
        (row as any).__remove = () => remove(i);
      });
      trackPlaying(root);
      return;
    }
    // Edit mode: drag to reorder, × to remove, each change saved as made.
    const listEl = el("div", { class: "mu-songs editing" });
    songs.forEach((s, i) => {
      const row = el("div", { class: "mu-song mu-edit-row", draggable: "true", "data-index": String(i) }, [
        el("div", { class: "mu-grip", title: "Drag to reorder" }, [mi("grip", 18)]),
        el("div", { class: "mu-song-text" }, [
          el("div", { class: "mu-song-title" }, [s.Name ?? ""]),
          el("div", { class: "mu-song-sub" }, [m.artistLine(s)]),
        ]),
        el("div", { class: "mu-song-time" }, [m.clock(m.secondsOf(s.RunTimeTicks))]),
        iconButton("close", "Remove from playlist", () => void remove(i)),
      ]);
      row.addEventListener("dragstart", (ev) => {
        ev.dataTransfer?.setData("text/plain", String(i));
        row.classList.add("dragging");
      });
      row.addEventListener("dragend", () => row.classList.remove("dragging"));
      row.addEventListener("dragover", (ev) => {
        ev.preventDefault();
        row.classList.add("drop-target");
      });
      row.addEventListener("dragleave", () => row.classList.remove("drop-target"));
      row.addEventListener("drop", (ev) => {
        ev.preventDefault();
        row.classList.remove("drop-target");
        const from = Number(ev.dataTransfer?.getData("text/plain"));
        if (Number.isFinite(from) && from !== i) void moveEntry(from, i);
      });
      listEl.append(row);
    });
    root.append(listEl);
  };

  const remove = async (i: number) => {
    if (!state) return;
    const song = state.songs[i];
    const entry = song?.PlaylistItemId;
    if (!entry) return toast("The server didn't say which entry that is", "error");
    try {
      await m.removeFromPlaylist(id, [entry]);
      state.songs.splice(i, 1);
      playlistsChanged.dispatchEvent(new Event("change"));
      paint();
    } catch (e) { report(e); }
  };
  const moveEntry = async (from: number, to: number) => {
    if (!state) return;
    const song = state.songs[from];
    if (!song?.PlaylistItemId) return;
    try {
      await m.movePlaylistEntry(id, song.PlaylistItemId, to);
      state.songs.splice(from, 1);
      state.songs.splice(to, 0, song);
      paint();
    } catch (e) { report(e); }
  };

  // Songs on a playlist page get "Remove from Playlist" in their menu.
  root.addEventListener("contextmenu", (ev) => {
    const row = (ev.target as HTMLElement).closest(".mu-song") as any;
    if (!row?.__remove || editing) return;
    ev.preventDefault();
    ev.stopPropagation();
    const song = row.__song;
    openActionMenu({ x: ev.clientX, y: ev.clientY }, song?.Name ?? null, musicActions(song, { onRemove: row.__remove }));
  }, true);

  if (state) paint();
  else root.append(spinner());
  const [list, songs] = await Promise.all([m.musicItem(id), m.playlistItems(id)]);
  if (!root.isConnected) return;
  const fresh = { list, songs };
  if (!state || itemSignature(state.songs) !== itemSignature(songs) || state.list.Name !== list.Name) {
    state = fresh;
    if (!editing) paint();
  }
  setCached(key, fresh);
}

// ---------- Smart playlists ----------

async function renderSmart(root: HTMLElement, id: string): Promise<void> {
  const sp = getSmartPlaylists().find((p) => p.id === id);
  if (!sp) {
    root.append(emptyState({ title: "That smart playlist is gone" }));
    return;
  }
  const item = asItem(sp);
  const body = el("div");
  root.append(pageHeader({
    cover: null,
    eyebrow: "Smart Playlist",
    title: sp.name,
    lines: [describe(sp)],
    buttons: [
      ...playButtons(item, { songs: () => smartPlaylistSongs(sp) }).slice(0, 2),
      el("button", { class: "btn", onClick: () => void (location.hash = `#/music/smart-edit/${sp.id}`) }, [mi("edit"), " Edit Rules"]),
      el("button", {
        class: "btn",
        title: "Freeze what the rules find now into a real playlist on the server",
        onClick: async () => {
          const name = await askName("Save to Server", sp.name, "Save");
          if (!name) return;
          try {
            const songs = await smartPlaylistSongs(sp);
            const pid = await m.createPlaylist(name, songs.map((s) => s.Id));
            playlistsChanged.dispatchEvent(new Event("change"));
            toast(`Saved ${songs.length} songs as “${name}”`, "ok");
            location.hash = `#/music/playlist/${pid}`;
          } catch (e) { report(e); }
        },
      }, ["Save to Server…"]),
      el("button", {
        class: "btn danger",
        onClick: () => openDialog({
          title: `Delete “${sp.name}”?`,
          body: ["Only the rules are deleted; no songs are touched."],
          actions: [
            { label: "Cancel", primary: true },
            { label: "Delete", danger: true, run: async () => {
              await deleteSmartPlaylist(sp.id).catch(report);
              location.hash = "#/music/library/playlists";
            } },
          ],
        }),
      }, ["Delete"]),
    ],
  }), body);
  body.append(spinner());
  // Rebuilt every time it's opened: the rules are the playlist.
  const songs = await smartPlaylistSongs(sp);
  clear(body);
  body.append(songs.length ? songList(songs, { lead: "art", showAlbum: true, title: sp.name }) : emptyState({ title: "Nothing matches these rules yet" }));
  trackPlaying(body);
}

async function renderSmartEditor(root: HTMLElement, id: string): Promise<void> {
  const existing = getSmartPlaylists().find((p) => p.id === id);
  const sp: SmartPlaylist = existing ? { ...existing } : blankSmartPlaylist();
  root.append(el("h1", { class: "page-title" }, [existing ? "Edit Smart Playlist" : "New Smart Playlist"]));
  const genres = await m.musicGenres().catch(() => []);
  const form = el("div", { class: "mu-form" });
  const field = (label: string, control: Node, help?: string) =>
    el("label", { class: "mu-field" }, [el("span", { class: "mu-field-label" }, [label]), control, help ? el("span", { class: "mu-field-help" }, [help]) : null]);
  const input = (attrs: Record<string, any>) => el("input", { class: "mu-input", ...attrs }) as HTMLInputElement;

  const name = input({ type: "text", value: sp.name, placeholder: "Name" });
  const genreSel = el("select", { class: "mu-select", multiple: "", size: "8" }, genres.map((g) =>
    el("option", { value: g.Name, selected: sp.genres.includes(g.Name) ? "" : null }, [g.Name])
  )) as HTMLSelectElement;
  const artistBox = el("div", { class: "mu-chips" });
  const artistSearch = input({ type: "search", placeholder: "Add an artist…" });
  const artistResults = el("div", { class: "mu-chip-results" });
  const drawArtists = () => {
    clear(artistBox);
    for (const a of sp.artists) {
      artistBox.append(el("button", { class: "mu-chip", title: "Remove", onClick: () => { sp.artists = sp.artists.filter((x) => x.id !== a.id); drawArtists(); } }, [a.name, " ×"]));
    }
  };
  drawArtists();
  let t = 0;
  artistSearch.addEventListener("input", () => {
    clearTimeout(t);
    t = window.setTimeout(async () => {
      clear(artistResults);
      const term = artistSearch.value.trim();
      if (!term) return;
      const r = await m.artists({ searchTerm: term, limit: 8 }).catch(() => ({ Items: [] as any[] }));
      for (const a of r.Items) {
        artistResults.append(el("button", { class: "mu-chip add", onClick: () => {
          if (!sp.artists.some((x) => x.id === a.Id)) sp.artists.push({ id: a.Id, name: a.Name });
          artistSearch.value = "";
          clear(artistResults);
          drawArtists();
        } }, ["+ ", a.Name]));
      }
    }, 250);
  });
  const yearFrom = input({ type: "number", min: "1900", max: "2100", value: sp.yearFrom ?? "", placeholder: "From" });
  const yearTo = input({ type: "number", min: "1900", max: "2100", value: sp.yearTo ?? "", placeholder: "To" });
  const added = input({ type: "number", min: "0", value: String(sp.addedWithinDays || ""), placeholder: "Any time" });
  const played = el("select", { class: "mu-select" }, [
    ["any", "Played or not"], ["played", "Played before"], ["unplayed", "Never played"],
  ].map(([v, l]) => el("option", { value: v, selected: sp.played === v ? "" : null }, [l]))) as HTMLSelectElement;
  const minPlays = input({ type: "number", min: "0", value: String(sp.minPlays || ""), placeholder: "0" });
  const fav = input({ type: "checkbox" });
  fav.checked = sp.favoritesOnly;
  const order = el("select", { class: "mu-select" }, (Object.keys(m.SORTS) as (keyof typeof m.SORTS)[]).map((k) =>
    el("option", { value: k, selected: sp.order === k ? "" : null }, [m.SORTS[k].label])
  )) as HTMLSelectElement;
  const limit = input({ type: "number", min: "1", max: "1000", value: String(sp.limit) });

  form.append(
    field("Name", name),
    field("Genres", genreSel, "Ctrl-click for more than one. None means any genre."),
    field("Artists", el("div", {}, [artistBox, artistSearch, artistResults])),
    field("Years", el("div", { class: "mu-pair" }, [yearFrom, el("span", {}, ["–"]), yearTo])),
    field("Added in the last (days)", added),
    field("Played", played),
    field("Played at least (times)", minPlays),
    el("label", { class: "mu-field mu-check" }, [fav, el("span", {}, ["Favorites only"])]),
    field("Order", order),
    field("Limit", limit),
    el("div", { class: "mu-head-buttons" }, [
      el("button", { class: "btn", onClick: () => history.back() }, ["Cancel"]),
      el("button", {
        class: "btn primary",
        onClick: async () => {
          sp.name = name.value.trim() || "Smart Playlist";
          sp.genres = Array.from(genreSel.selectedOptions).map((o) => o.value);
          const yf = Number(yearFrom.value), yt = Number(yearTo.value);
          sp.yearFrom = yf > 0 ? yf : null;
          sp.yearTo = yt > 0 ? yt : null;
          sp.addedWithinDays = Math.max(0, Number(added.value) || 0);
          sp.played = played.value as any;
          sp.minPlays = Math.max(0, Number(minPlays.value) || 0);
          sp.favoritesOnly = fav.checked;
          sp.order = order.value as any;
          sp.limit = Math.max(1, Math.min(1000, Number(limit.value) || 100));
          try {
            await saveSmartPlaylist(sp);
            location.hash = `#/music/smart/${sp.id}`;
          } catch (e) { report(e); }
        },
      }, ["Save"]),
    ])
  );
  root.append(form);
}

// ---------- Search ----------

async function renderMusicSearch(root: HTMLElement, term: string): Promise<void> {
  const input = el("input", { type: "search", class: "mu-input mu-search", placeholder: "Artists, albums, songs, playlists", value: term, "aria-label": "Search music" }) as HTMLInputElement;
  const body = el("div");
  root.append(el("h1", { class: "page-title" }, ["Search Music"]), musicTabs("search"), input, body);
  const run = async (q: string) => {
    clear(body);
    if (!q) return;
    body.append(spinner());
    try {
      const r = await m.searchMusic(q);
      clear(body);
      if (!r.artists.length && !r.albums.length && !r.songs.length && !r.playlists.length) {
        body.append(emptyState({ icon: "search", title: `Nothing in your music for “${q}”` }));
        return;
      }
      const parts = [
        shelf("Artists", r.artists.map((a: any) => musicCard(a))),
        shelf("Albums", r.albums.map((a: any) => musicCard(a))),
        r.songs.length ? el("section", { class: "mu-shelf" }, [el("div", { class: "section-head" }, [el("h2", {}, ["Songs"])]), songList(r.songs, { lead: "art", showAlbum: true })]) : null,
        shelf("Playlists", r.playlists.map((a: any) => musicCard(a))),
      ];
      body.append(...parts.filter(Boolean) as HTMLElement[]);
      trackPlaying(body);
    } catch (e) {
      clear(body);
      body.append(errorState("Search failed", e));
    }
  };
  let t = 0;
  input.addEventListener("input", () => {
    clearTimeout(t);
    t = window.setTimeout(() => {
      history.replaceState(null, "", `#/music/search/${encodeURIComponent(input.value.trim())}`);
      void run(input.value.trim());
    }, 300);
  });
  setTimeout(() => input.focus(), 0);
  await run(term);
}
