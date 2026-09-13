import * as api from "../api";
import {
  el,
  clear,
  emptyState,
  errorState,
  icon,
  itemCard,
  skeletonCards,
  skeletonGrid,
  type IconName,
} from "../ui";
import { getCached, setCached, itemSignature } from "../cache";

const PAGE = 60;
/** Placeholder cards to show while the first page of results is in flight. */
const SKELETONS = 18;

const SORTS: [string, string][] = [
  ["SortName|Ascending", "A – Z"],
  ["SortName|Descending", "Z – A"],
  ["DateCreated|Descending", "Recently added"],
  ["PremiereDate|Descending", "Release date"],
  ["CommunityRating|Descending", "Rating"],
  ["Random|Ascending", "Shuffle"],
];

/** Per-library view settings. Coming back to a library you sorted by
 *  "Recently added" and re-sorting it A–Z every time is pure friction. */
interface LibPrefs {
  sort: string;
  unwatched: boolean;
  favorites: boolean;
  genre: string;
}

const prefsKey = (libId: string): string => `fellyjin.lib.${libId}`;

function loadPrefs(libId: string): LibPrefs {
  const fallback: LibPrefs = { sort: "SortName|Ascending", unwatched: false, favorites: false, genre: "" };
  try {
    const raw = JSON.parse(localStorage.getItem(prefsKey(libId)) ?? "{}");
    return {
      sort: SORTS.some(([v]) => v === raw.sort) ? raw.sort : fallback.sort,
      unwatched: !!raw.unwatched,
      favorites: !!raw.favorites,
      genre: typeof raw.genre === "string" ? raw.genre : "",
    };
  } catch {
    return fallback;
  }
}

function savePrefs(libId: string, prefs: LibPrefs): void {
  try {
    localStorage.setItem(prefsKey(libId), JSON.stringify(prefs));
  } catch {
    // Quota exceeded — settings just won't survive a restart.
  }
}

/** A filter that reads as on/off at a glance, rather than a checkbox. */
function toggleChip(
  label: string,
  active: boolean,
  onToggle: (next: boolean) => void,
  glyph?: IconName
): HTMLElement {
  const btn = el("button", { class: `btn small${active ? " active" : ""}` }, [
    glyph ? icon(glyph) : null,
    label,
  ]);
  btn.addEventListener("click", () => {
    active = !active;
    btn.classList.toggle("active", active);
    onToggle(active);
  });
  return btn;
}

export async function renderLibrary(root: HTMLElement, libId: string): Promise<void> {
  clear(root);

  // The library's name and collection type barely ever change, so a revisit
  // skips straight past the request that would otherwise gate every part of
  // the page behind a skeleton. It's refreshed quietly either way, just
  // without anything on screen waiting on the answer.
  const libMetaKey = `libmeta:${libId}`;
  let lib = getCached<any>(libMetaKey) ?? null;
  if (!lib) {
    const placeholder = skeletonGrid(SKELETONS);
    root.append(placeholder);
    lib = await api.getItem(libId).catch(() => null);
    if (!document.contains(placeholder)) return;
    if (lib) setCached(libMetaKey, lib);
  } else {
    void api.getItem(libId).then((fresh) => setCached(libMetaKey, fresh)).catch(() => {});
  }

  const includeTypes =
    lib?.CollectionType === "movies" ? "Movie" :
    lib?.CollectionType === "tvshows" ? "Series" : "";

  const prefs = loadPrefs(libId);
  let [sortBy, sortOrder] = prefs.sort.split("|");
  let startIndex = 0;
  let total = 0;
  let loading = false;
  let generation = 0;
  // Everything paged in for the current sort/filter combination, mirrored
  // into the cache after every successful load so a revisit can replay the
  // whole thing instead of just the first page.
  let loadedItems: any[] = [];
  const cacheKey = (): string =>
    `lib:${libId}:${sortBy}|${sortOrder}:${prefs.unwatched ? 1 : 0}:${prefs.favorites ? 1 : 0}:${prefs.genre}`;

  clear(root);
  const count = el("span", { class: "lib-count" }, [""]);
  const head = el("div", { class: "section-head" }, [
    el("div", { class: "lib-head" }, [
      el("h1", { class: "page-title" }, [lib?.Name ?? "Library"]),
      count,
    ]),
  ]);
  root.append(head);

  // ---- Filter bar ----
  const bar = el("div", { class: "filter-bar" });

  const sortSel = el("select", { class: "control", title: "Sort order" }) as HTMLSelectElement;
  for (const [value, label] of SORTS) sortSel.append(el("option", { value }, [label]));
  sortSel.value = prefs.sort;
  sortSel.addEventListener("change", () => {
    prefs.sort = sortSel.value;
    [sortBy, sortOrder] = sortSel.value.split("|");
    savePrefs(libId, prefs);
    void loadPage(true);
  });
  bar.append(sortSel);

  bar.append(
    toggleChip("Unwatched", prefs.unwatched, (on) => {
      prefs.unwatched = on;
      savePrefs(libId, prefs);
      void loadPage(true);
    }),
    toggleChip(
      "Favorites",
      prefs.favorites,
      (on) => {
        prefs.favorites = on;
        savePrefs(libId, prefs);
        void loadPage(true);
      },
      "star"
    )
  );

  const genreSel = el("select", { class: "control", title: "Filter by genre", hidden: "" }) as HTMLSelectElement;
  genreSel.addEventListener("change", () => {
    prefs.genre = genreSel.value;
    savePrefs(libId, prefs);
    void loadPage(true);
  });
  bar.append(genreSel);
  root.append(bar);

  // Genres are a nice-to-have: the control only appears once (and if) the
  // server answers, so a failure costs nothing.
  void api
    .getGenres(libId, includeTypes)
    .then((genres) => {
      if (!genres.length || !document.contains(genreSel)) return;
      genreSel.append(el("option", { value: "" }, ["All genres"]));
      for (const g of genres) genreSel.append(el("option", { value: g }, [g]));
      // A remembered genre that no longer exists falls back to "all".
      genreSel.value = genres.includes(prefs.genre) ? prefs.genre : "";
      if (genreSel.value !== prefs.genre) {
        prefs.genre = genreSel.value;
        savePrefs(libId, prefs);
      }
      genreSel.toggleAttribute("hidden", false);
    })
    .catch(() => {});

  /** Reset every filter (not the sort) and reload — the action offered by the
   *  "nothing matches" state, which is otherwise a dead end. */
  function clearFilters(): void {
    prefs.unwatched = false;
    prefs.favorites = false;
    prefs.genre = "";
    savePrefs(libId, prefs);
    genreSel.value = "";
    for (const chip of bar.querySelectorAll(".btn.active")) chip.classList.remove("active");
    void loadPage(true);
  }

  const grid = el("div", { class: "card-grid" });
  const moreWrap = el("div", { class: "load-more" });
  const moreBtn = el("button", { class: "btn" }, ["Load more"]) as HTMLButtonElement;
  moreWrap.append(moreBtn);
  root.append(grid, moreWrap);

  async function loadPage(reset = false): Promise<void> {
    // Infinite scroll can fire this repeatedly, so an in-flight page swallows
    // the extras — but a sort or filter change must never be dropped that way.
    // It supersedes instead: `generation` makes the older reply a no-op.
    if (loading && !reset) return;
    const gen = ++generation;
    loading = true;
    if (reset) {
      startIndex = 0;
      loadedItems = [];
      // Re-filtering swaps the cards for placeholders rather than emptying the
      // grid, so the page keeps its height. Match however many cards are on
      // screen — a fixed count would make a small library visibly grow and
      // then shrink again. Nothing to match on the first load.
      const onScreen = grid.querySelectorAll(".card").length;
      clear(grid);
      grid.append(...skeletonCards(onScreen || SKELETONS));
    }
    moreBtn.disabled = true;
    moreBtn.textContent = "Loading…";
    try {
      const r = await api.getLibraryItems(libId, {
        startIndex,
        limit: PAGE,
        includeTypes,
        sortBy,
        sortOrder,
        unwatched: prefs.unwatched,
        favorites: prefs.favorites,
        genre: prefs.genre || undefined,
      });
      // A newer sort/filter already owns the grid — this reply is stale.
      if (gen !== generation) return;
      if (reset) clear(grid);
      total = r.TotalRecordCount ?? 0;
      const items = r.Items ?? [];
      loadedItems.push(...items);
      for (const item of items) grid.append(itemCard(item));
      startIndex += PAGE;
      count.textContent = total ? `${total} item${total === 1 ? "" : "s"}` : "";
      moreWrap.style.display = startIndex < total ? "" : "none";
      // Kept in step with what's actually on screen, so a revisit — or the
      // freshness check below — always compares against what this session
      // last showed rather than something a page reset already moved past.
      setCached(cacheKey(), { items: loadedItems, total });
    } catch (e: any) {
      // Filters and sorting are driven from here too, where nothing else
      // would catch this.
      if (gen !== generation) return;
      if (reset) clear(grid);
      grid.append(errorState("Couldn't load this library", e, () => void loadPage(reset)));
      moreWrap.style.display = "none";
    } finally {
      // The superseding call owns these; leave them to it.
      if (gen === generation) {
        loading = false;
        moreBtn.disabled = false;
        moreBtn.textContent = "Load more";
      }
    }
    if (!grid.children.length) {
      const filtered = prefs.unwatched || prefs.favorites || prefs.genre;
      grid.append(
        filtered
          ? emptyState({
              icon: "search",
              title: "Nothing matches these filters",
              body: "Try widening the selection — or clear the filters to see the whole library again.",
              action: { label: "Clear filters", run: clearFilters },
            })
          : emptyState({
              icon: "library",
              title: "This library is empty",
              body: "Nothing here yet. Add media to this library in Jellyfin and it will show up after the next scan.",
            })
      );
    }
  }

  /**
   * A cheap check that a cached grid, already painted, is still right: refetch
   * just the first page and compare it against what the cache said page one
   * was. A library that hasn't changed costs one small request and touches
   * nothing on screen; one that has gets a real reload — same as any other
   * filter change, just triggered by the server instead of a click.
   *
   * Runs against `generation` rather than driving its own reset, so a real
   * `loadPage` that starts while this is in flight (a filter change, another
   * revalidation) makes this one a no-op instead of the two racing.
   */
  async function revalidateFirstPage(cachedItems: any[], cachedTotal: number): Promise<void> {
    const gen = generation;
    try {
      const r = await api.getLibraryItems(libId, {
        startIndex: 0,
        limit: PAGE,
        includeTypes,
        sortBy,
        sortOrder,
        unwatched: prefs.unwatched,
        favorites: prefs.favorites,
        genre: prefs.genre || undefined,
      });
      if (gen !== generation) return;
      const changed =
        itemSignature(r.Items ?? []) !== itemSignature(cachedItems.slice(0, PAGE)) ||
        (r.TotalRecordCount ?? 0) !== cachedTotal;
      if (changed) void loadPage(true);
    } catch {
      // Offline, or the server hiccuped — the cached grid stays exactly as
      // it was rather than being torn down over a failed freshness check.
    }
  }

  moreBtn.addEventListener("click", () => void loadPage());

  // Infinite scroll: the button stays as a fallback (and as the "you've
  // reached the end" marker), but scrolling to it is enough to load more.
  if (typeof IntersectionObserver !== "undefined") {
    const io = new IntersectionObserver(
      (entries) => {
        if (!entries.some((e) => e.isIntersecting)) return;
        if (loading || startIndex >= total) return;
        void loadPage();
      },
      { root: document.getElementById("content"), rootMargin: "400px" }
    );
    io.observe(moreWrap);
  }

  // A cached grid paints in full immediately — no skeleton, no network wait —
  // and is checked for freshness quietly behind it. Nothing cached (the first
  // visit this session, or a library seen for the first time) falls back to
  // the normal load, skeleton and all.
  const cachedPage = getCached<{ items: any[]; total: number }>(cacheKey());
  if (cachedPage?.items.length) {
    loadedItems = cachedPage.items.slice();
    total = cachedPage.total;
    startIndex = loadedItems.length;
    for (const item of loadedItems) grid.append(itemCard(item));
    count.textContent = total ? `${total} item${total === 1 ? "" : "s"}` : "";
    moreWrap.style.display = startIndex < total ? "" : "none";
    void revalidateFirstPage(loadedItems, total);
  } else {
    await loadPage(true);
  }
}

// ---------- Search ----------

const SEARCH_PAGE = 48;

const GROUPS: { type: string; label: string; wide?: boolean }[] = [
  { type: "Movie", label: "Movies" },
  { type: "Series", label: "TV Shows" },
  { type: "Episode", label: "Episodes", wide: true },
];

export async function renderSearch(root: HTMLElement, term: string): Promise<void> {
  clear(root);
  // Landing here from a link, a recent search or the Back button leaves the
  // box empty otherwise — the results would claim a query the UI doesn't show.
  const input = document.getElementById("search-input") as HTMLInputElement | null;
  if (input && input.value.trim() !== term) input.value = term;

  const count = el("span", { class: "lib-count" }, [""]);
  const heading = el("div", { class: "section-head" }, [
    el("div", { class: "lib-head" }, [
      el("h1", { class: "page-title" }, [`Search: “${term}”`]),
      count,
    ]),
  ]);
  const placeholder = skeletonGrid(12);
  root.append(heading, placeholder);

  let startIndex = 0;
  let total = 0;
  const found: any[] = [];

  const results = el("div", {});
  const moreWrap = el("div", { class: "load-more" });
  const moreBtn = el("button", { class: "btn" }, ["Load more"]) as HTMLButtonElement;
  moreWrap.append(moreBtn);

  /** Redraw grouped by type — a flat mixed grid makes you hunt for the show
   *  among forty episodes of it. */
  function paint(): void {
    clear(results);
    for (const g of GROUPS) {
      const items = found.filter((i) => i.Type === g.type);
      if (!items.length) continue;
      results.append(
        el("div", { class: "section" }, [
          el("div", { class: "section-head" }, [
            el("h2", {}, [`${g.label} · ${items.length}`]),
          ]),
          el("div", { class: "card-grid" }, items.map((i) => itemCard(i, { wide: g.wide }))),
        ])
      );
    }
    // Anything the server returned that isn't one of the three known types.
    const rest = found.filter((i) => !GROUPS.some((g) => g.type === i.Type));
    if (rest.length) {
      results.append(
        el("div", { class: "section" }, [
          el("div", { class: "section-head" }, [el("h2", {}, ["Other"])]),
          el("div", { class: "card-grid" }, rest.map((i) => itemCard(i))),
        ])
      );
    }
  }

  async function loadPage(): Promise<void> {
    moreBtn.disabled = true;
    moreBtn.textContent = "Loading…";
    try {
      const r = await api.search(term, { startIndex, limit: SEARCH_PAGE });
      found.push(...r.Items);
      total = r.TotalRecordCount;
      startIndex += SEARCH_PAGE;
    } catch {
      total = found.length;
    } finally {
      moreBtn.disabled = false;
      moreBtn.textContent = "Load more";
    }
    count.textContent = total ? `${total} result${total === 1 ? "" : "s"}` : "";
    moreWrap.style.display = startIndex < total ? "" : "none";
    paint();
  }

  await loadPage();
  // A newer keystroke already owns the page.
  if (!document.contains(placeholder)) return;
  placeholder.remove();

  if (!found.length) {
    root.append(
      emptyState({
        icon: "search",
        title: `No results for “${term}”`,
        body: "Check the spelling, or try a shorter search — FellyJin matches titles across movies, shows and episodes.",
        action: {
          label: "Clear search",
          run: () => {
            const input = document.getElementById("search-input") as HTMLInputElement | null;
            if (input) input.value = "";
            location.hash = "#/home";
          },
        },
      })
    );
    return;
  }
  root.append(results, moreWrap);
  moreBtn.addEventListener("click", () => void loadPage());
}
