// Audiobooks: kept apart from music the way the Apple app keeps them — a book
// never turns up in a music row, list or search, and the other way round.
// Continue Listening with the time left, Recently Added, the authors as a row
// of names (the server's artist pictures are wrong for authors more often than
// not), every book by title, author, date added or last played, and a search
// of its own. A book's page has its chapters, resume point and speed.
//
// Routes (under #/books/): "" · all · author/<name> · book/<id> · search/<term>
import * as api from "../api";
import * as m from "../musicApi";
import * as audio from "../audio";
import { getCached, setCached, itemSignature } from "../cache";
import { el, clear, toast, emptyState, errorState, spinner, skeletonRow, openActionMenu, attachContextMenu } from "../ui";
import { mi, musicCard, shelf, grid, pageHeader, iconButton, link } from "./musicCommon";

function report(e: any): void {
  toast(e?.message ?? String(e), "error");
}

export async function renderBooks(root: HTMLElement, arg: string): Promise<void> {
  const [page, ...rest] = (arg || "").split("/");
  const id = decodeURIComponent(rest.join("/"));
  clear(root);
  root.classList.add("mu-page");
  switch (page) {
    case "all": return renderAll(root);
    case "author": return renderAuthor(root, id);
    case "book": return renderBook(root, id);
    case "search": return renderSearch(root, id);
    default: return renderHome(root);
  }
}

function author(book: any): string {
  return m.artistLine(book) || "Unknown author";
}

function timeLeft(book: any): string {
  const total = m.secondsOf(book.RunTimeTicks);
  const pos = m.secondsOf(book.UserData?.PlaybackPositionTicks);
  if (!total || !pos) return "";
  return `${m.longDuration(Math.max(0, total - pos))} left`;
}

function bookCard(book: any, sub?: string): HTMLElement {
  const card = musicCard(book, { sub: sub ?? author(book) });
  const pct = book.RunTimeTicks && book.UserData?.PlaybackPositionTicks
    ? Math.min(100, (book.UserData.PlaybackPositionTicks / book.RunTimeTicks) * 100)
    : 0;
  if (pct > 0.5) {
    card.querySelector(".mu-cover")?.append(el("div", { class: "progress-strip" }, [el("div", { style: `width:${pct}%` })]));
  }
  // The cover's play button resumes rather than restarting.
  const play = card.querySelector(".mu-cover-play");
  play?.replaceWith(el("button", {
    class: "mu-cover-play",
    title: pct ? "Resume" : "Play",
    onClick: (ev: MouseEvent) => {
      ev.stopPropagation();
      void playBook(book, true);
    },
  }, [mi("play", 18)]));
  attachContextMenu(card, book.Name ?? null, () => bookActions(book));
  return card;
}

function bookActions(book: any): any[] {
  const pos = m.secondsOf(book.UserData?.PlaybackPositionTicks);
  return [
    pos ? { label: `Resume (${timeLeft(book) || m.clock(pos)})`, icon: "play", run: () => void playBook(book, true) } : null,
    { label: pos ? "Play from Start" : "Play", icon: pos ? undefined : "play", run: () => void playBook(book, false) },
    { label: "Play Next", run: () => void detailed(book).then((b) => audio.playNext([b])).catch(report) },
    { label: "Play Later", run: () => void detailed(book).then((b) => audio.playLater([b])).catch(report) },
    {
      label: book.UserData?.Played ? "Mark as Not Finished" : "Mark as Finished",
      icon: "check",
      run: async () => {
        try {
          await api.markPlayed(book.Id, !book.UserData?.Played);
          toast(book.UserData?.Played ? "Marked not finished" : "Marked finished", "ok");
        } catch (e) { report(e); }
      },
    },
    { label: "Go to Author", icon: "people", run: () => void (location.hash = `#/books/author/${encodeURIComponent(author(book))}`) },
  ];
}

/** The book with its chapters (lists leave them out). */
async function detailed(book: any): Promise<any> {
  if (book.Chapters) return book;
  return m.musicItem(book.Id);
}

/** A book's playable files: itself, or its parts when it's a folder of them. */
async function partsOf(book: any): Promise<any[]> {
  if (!book.IsFolder && !book.ChildCount) return [book];
  const r = await m.music({ types: "AudioBook,Audio", parentId: book.Id, limit: 500, fields: m.MUSIC_DETAIL_FIELDS });
  return r.Items.length ? m.sortedByTrack(r.Items) : [book];
}

export async function playBook(book: any, resume: boolean, at?: number): Promise<void> {
  try {
    const full = await detailed(book);
    const parts = await partsOf(full);
    // A book in parts resumes at the part that was stopped in.
    let start = 0;
    if (resume && parts.length > 1) {
      const i = parts.findIndex((p) => (p.UserData?.PlaybackPositionTicks ?? 0) > 0 && !p.UserData?.Played);
      start = i >= 0 ? i : Math.max(0, parts.findIndex((p) => !p.UserData?.Played));
    }
    const pos = at ?? (resume ? m.secondsOf(parts[start].UserData?.PlaybackPositionTicks) : 0);
    await audio.play(parts, start, { title: full.Name ?? "", book: true, startSeconds: pos || undefined });
  } catch (e) {
    report(e);
  }
}

function booksTabs(active: string): HTMLElement {
  const tabs: [string, string][] = [["", "Listen Now"], ["all", "All Books"], ["search", "Search"]];
  return el("nav", { class: "mu-tabs", "aria-label": "Audiobooks" }, tabs.map(([r, label]) =>
    el("a", { class: `mu-tab${r === active ? " active" : ""}`, href: `#/books${r ? `/${r}` : ""}` }, [label])
  ));
}

// ---------- Listen Now ----------

interface BooksHome {
  resume: any[];
  added: any[];
  authors: string[];
}

async function allBooks(): Promise<any[]> {
  const r = await m.music({ types: "AudioBook", sort: "name", limit: 5000 });
  return r.Items;
}

function authorsOf(books: any[]): string[] {
  const n = new Map<string, number>();
  for (const b of books) {
    const names = (b.AlbumArtists?.length ? b.AlbumArtists.map((a: any) => a.Name) : b.Artists ?? []).filter(Boolean);
    for (const a of names.length ? names : [author(b)]) n.set(a, (n.get(a) ?? 0) + 1);
  }
  return [...n.keys()].sort((a, b) => a.localeCompare(b));
}

async function renderHome(root: HTMLElement): Promise<void> {
  root.append(el("h1", { class: "page-title" }, ["Audiobooks"]), booksTabs(""));
  const body = el("div");
  root.append(body);
  const paint = (d: BooksHome) => {
    clear(body);
    if (!d.resume.length && !d.added.length) {
      body.append(emptyState({ icon: "library", title: "No audiobooks yet", body: "Books appear here once your Jellyfin books library has been scanned." }));
      return;
    }
    const parts = [
      shelf("Continue Listening", d.resume.map((b) => bookCard(b, timeLeft(b) || author(b)))),
      shelf("Recently Added", d.added.map((b) => bookCard(b)), () => void (location.hash = "#/books/all?sort=added")),
      d.authors.length
        ? el("section", { class: "mu-shelf" }, [
            el("div", { class: "section-head" }, [el("h2", {}, ["Authors"])]),
            el("div", { class: "mu-authors" }, d.authors.map((a) =>
              el("a", { class: "mu-author", href: `#/books/author/${encodeURIComponent(a)}` }, [a])
            )),
          ])
        : null,
    ];
    body.append(...parts.filter(Boolean) as HTMLElement[]);
  };
  const sig = (d: BooksHome) => itemSignature(d.resume) + itemSignature(d.added) + d.authors.join("|");
  const cached = getCached<BooksHome>("books:home");
  if (cached) paint(cached);
  else body.append(skeletonRow(7));
  const [resume, added, all] = await Promise.all([
    m.resumeBooks(24).catch(() => []),
    m.music({ types: "AudioBook", sort: "added", limit: 24 }).then((r) => r.Items).catch(() => []),
    allBooks().catch(() => []),
  ]);
  const fresh = { resume, added, authors: authorsOf(all) };
  if (!root.isConnected) return;
  if (!cached || sig(cached) !== sig(fresh)) paint(fresh);
  setCached("books:home", fresh);
  setCached("books:all", all);
}

// ---------- All Books ----------

const BOOK_SORTS: [string, string, (a: any, b: any) => number][] = [
  ["title", "Title", (a, b) => String(a.SortName ?? a.Name).localeCompare(String(b.SortName ?? b.Name))],
  ["author", "Author", (a, b) => author(a).localeCompare(author(b)) || String(a.SortName ?? a.Name).localeCompare(String(b.SortName ?? b.Name))],
  ["added", "Date added", (a, b) => String(b.DateCreated ?? "").localeCompare(String(a.DateCreated ?? ""))],
  ["played", "Last played", (a, b) => String(b.UserData?.LastPlayedDate ?? "").localeCompare(String(a.UserData?.LastPlayedDate ?? ""))],
];

async function renderAll(root: HTMLElement): Promise<void> {
  const params = new URLSearchParams(location.hash.split("?")[1] ?? "");
  let sort = params.get("sort") ?? (() => {
    try { return localStorage.getItem("aquarium.books-sort") ?? "title"; } catch { return "title"; }
  })();
  const sel = el("select", { class: "mu-select", "aria-label": "Sort" }, BOOK_SORTS.map(([k, label]) =>
    el("option", { value: k, selected: k === sort ? "" : null }, [label])
  )) as HTMLSelectElement;
  const filter = el("input", { type: "search", class: "mu-input mu-filter-input", placeholder: "Filter books", "aria-label": "Filter books" }) as HTMLInputElement;
  const count = el("span", { class: "lib-count" });
  root.append(el("h1", { class: "page-title" }, ["All Books"]), booksTabs("all"), el("div", { class: "filter-bar mu-filter" }, [filter, sel, count]));
  const body = el("div");
  root.append(body);
  let books: any[] = getCached<any[]>("books:all") ?? [];
  const paint = () => {
    clear(body);
    const term = filter.value.trim().toLowerCase();
    const cmp = BOOK_SORTS.find(([k]) => k === sort)?.[2] ?? BOOK_SORTS[0][2];
    const shown = books.filter((b) => !term || String(b.Name).toLowerCase().includes(term) || author(b).toLowerCase().includes(term)).sort(cmp);
    count.textContent = `${shown.length} book${shown.length === 1 ? "" : "s"}`;
    body.append(shown.length ? grid(shown.map((b) => bookCard(b))) : emptyState({ title: books.length ? "No books match" : "No audiobooks yet" }));
  };
  if (books.length) paint();
  else body.append(spinner());
  sel.addEventListener("change", () => {
    sort = sel.value;
    try { localStorage.setItem("aquarium.books-sort", sort); } catch { /* session only */ }
    paint();
  });
  filter.addEventListener("input", paint);
  const fresh = await allBooks();
  if (!root.isConnected) return;
  if (itemSignature(fresh) !== itemSignature(books) || !books.length) {
    books = fresh;
    paint();
  }
  setCached("books:all", fresh);
}

// ---------- Author ----------

async function renderAuthor(root: HTMLElement, name: string): Promise<void> {
  root.append(el("div", { class: "mu-eyebrow" }, ["Author"]), el("h1", { class: "page-title" }, [name]));
  const body = el("div");
  root.append(body);
  const paint = (books: any[]) => {
    clear(body);
    const mine = books.filter((b) => {
      const names = [...(b.AlbumArtists ?? []).map((a: any) => a.Name), ...(b.Artists ?? [])];
      return names.length ? names.includes(name) : author(b) === name;
    });
    body.append(mine.length ? grid(mine.map((b) => bookCard(b, b.ProductionYear ? String(b.ProductionYear) : ""))) : emptyState({ title: "No books by this author" }));
  };
  const cached = getCached<any[]>("books:all");
  if (cached) paint(cached);
  else body.append(spinner());
  const fresh = await allBooks();
  if (!root.isConnected) return;
  if (!cached || itemSignature(cached) !== itemSignature(fresh)) paint(fresh);
  setCached("books:all", fresh);
}

// ---------- A book ----------

async function renderBook(root: HTMLElement, id: string): Promise<void> {
  const key = `books:book:${id}`;
  const paint = (book: any) => {
    clear(root);
    const total = m.secondsOf(book.RunTimeTicks);
    const pos = m.secondsOf(book.UserData?.PlaybackPositionTicks);
    const pct = total && pos ? Math.min(100, (pos / total) * 100) : 0;
    const speedBtn = el("button", { class: "btn", title: "Playback speed", onClick: (ev: MouseEvent) => openActionMenu(ev.currentTarget as HTMLElement, "Speed", audio.BOOK_SPEEDS.map((s) => ({
      label: `${s}×${s === audio.bookSpeed() ? "  ✓" : ""}`,
      run: () => {
        void audio.setSpeed(s);
        speedBtn.textContent = `${s}×`;
      },
    })), { fixed: true }) }, [`${audio.bookSpeed()}×`]);
    const more = iconButton("more", "More", () => openActionMenu(more, book.Name ?? null, bookActions(book), { fixed: true }));
    root.append(pageHeader({
      item: book,
      cover: m.coverUrl(book, 600),
      eyebrow: "Audiobook",
      title: book.Name ?? "",
      lines: [
        link(author(book), `#/books/author/${encodeURIComponent(author(book))}`),
        [book.ProductionYear, total ? m.longDuration(total) : "", book.UserData?.Played ? "Finished" : timeLeft(book)].filter(Boolean).join(" · "),
        pct ? el("div", { class: "mu-book-progress" }, [el("div", { style: `width:${pct}%` })]) : null,
      ],
      buttons: [
        el("button", { class: "btn primary", onClick: () => void playBook(book, true) }, [mi("play"), pos ? ` Resume at ${m.clock(pos)}` : " Play"]),
        pos ? el("button", { class: "btn", onClick: () => void playBook(book, false) }, ["Play from Start"]) : null,
        speedBtn,
        more,
      ],
    }));
    if (book.Overview) root.append(el("p", { class: "mu-about" }, [book.Overview.replace(/<[^>]+>/g, "")]));
    const chapters: any[] = book.Chapters ?? [];
    if (chapters.length) {
      const list = el("div", { class: "mu-songs" });
      chapters.forEach((c, i) => {
        const start = m.secondsOf(c.StartPositionTicks);
        const end = i + 1 < chapters.length ? m.secondsOf(chapters[i + 1].StartPositionTicks) : total;
        const row = el("div", {
          class: `mu-song${pos >= start && pos < end ? " playing" : ""}`,
          role: "button",
          tabindex: "0",
          onDblclick: () => void playBook(book, false, start),
          onKeydown: (ev: KeyboardEvent) => { if (ev.key === "Enter") void playBook(book, false, start); },
        }, [
          el("div", { class: "mu-song-num" }, [String(i + 1)]),
          el("button", { class: "mu-song-play", title: "Play from here", onClick: () => void playBook(book, false, start) }, [mi("play", 14)]),
          el("div", { class: "mu-song-text" }, [el("div", { class: "mu-song-title" }, [c.Name || `Chapter ${i + 1}`])]),
          el("div", { class: "mu-song-time" }, [m.clock(start)]),
          el("div", { class: "mu-song-time" }, [end > start ? m.clock(end - start) : ""]),
        ]);
        list.append(row);
      });
      root.append(el("section", { class: "mu-shelf" }, [el("div", { class: "section-head" }, [el("h2", {}, [`Chapters (${chapters.length})`])]), list]));
    }
  };
  const cached = getCached<any>(key);
  if (cached) paint(cached);
  else root.append(spinner());
  try {
    const book = await m.musicItem(id);
    if (!root.isConnected) return;
    if (!cached || itemSignature([cached]) !== itemSignature([book])) paint(book);
    setCached(key, book);
  } catch (e) {
    if (!cached) {
      clear(root);
      root.append(errorState("This book didn't load", e));
    }
  }
}

// ---------- Search ----------

async function renderSearch(root: HTMLElement, term: string): Promise<void> {
  const input = el("input", { type: "search", class: "mu-input mu-search", placeholder: "Titles and authors", value: term, "aria-label": "Search audiobooks" }) as HTMLInputElement;
  const body = el("div");
  root.append(el("h1", { class: "page-title" }, ["Search Audiobooks"]), booksTabs("search"), input, body);
  const run = async (q: string) => {
    clear(body);
    if (!q) return;
    body.append(spinner());
    try {
      // Titles from the server; authors matched here, since a book's author
      // is a tag the server's search doesn't look at.
      const [byTitle, all] = await Promise.all([
        m.music({ types: "AudioBook", searchTerm: q, limit: 60 }).then((r) => r.Items),
        getCached<any[]>("books:all") ? Promise.resolve(getCached<any[]>("books:all")!) : allBooks(),
      ]);
      const lower = q.toLowerCase();
      const byAuthor = all.filter((b) => author(b).toLowerCase().includes(lower) && !byTitle.some((t) => t.Id === b.Id));
      clear(body);
      const results = [...byTitle, ...byAuthor];
      body.append(results.length ? grid(results.map((b) => bookCard(b))) : emptyState({ icon: "search", title: `No audiobooks match “${q}”` }));
    } catch (e) {
      clear(body);
      body.append(errorState("Search failed", e));
    }
  };
  let t = 0;
  input.addEventListener("input", () => {
    clearTimeout(t);
    t = window.setTimeout(() => {
      history.replaceState(null, "", `#/books/search/${encodeURIComponent(input.value.trim())}`);
      void run(input.value.trim());
    }, 300);
  });
  setTimeout(() => input.focus(), 0);
  await run(term);
}
