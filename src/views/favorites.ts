// Everything the user has starred, in one place. Favoriting has been possible
// from every context menu for a while, but the state only ever travelled one
// way — into Jellyfin — so there was no screen that could answer "what did I
// star?". This is that screen.
import * as api from "../api";
import { el, clear, emptyState, errorState, itemCard, skeletonCards } from "../ui";
import { getCached, setCached, itemSignature } from "../cache";

const PAGE = 60;
const SKELETONS = 18;

/** Sort orders that make sense across a mixed list of movies, shows and
 *  episodes (no per-library notions like release date within a season). */
const SORTS: [string, string][] = [
  ["SortName|Ascending", "A – Z"],
  ["SortName|Descending", "Z – A"],
  ["DateCreated|Descending", "Recently added"],
  ["CommunityRating|Descending", "Rating"],
  ["Random|Ascending", "Shuffle"],
];

const TYPES: [string, string][] = [
  ["", "All"],
  ["Movie", "Movies"],
  ["Series", "TV Shows"],
  ["Episode", "Episodes"],
];

interface FavPrefs {
  sort: string;
  type: string;
}

const PREFS_KEY = "fellyjin.favorites";

function loadPrefs(): FavPrefs {
  const fallback: FavPrefs = { sort: "SortName|Ascending", type: "" };
  try {
    const raw = JSON.parse(localStorage.getItem(PREFS_KEY) ?? "{}");
    return {
      sort: SORTS.some(([v]) => v === raw.sort) ? raw.sort : fallback.sort,
      type: TYPES.some(([v]) => v === raw.type) ? raw.type : fallback.type,
    };
  } catch {
    return fallback;
  }
}

function savePrefs(prefs: FavPrefs): void {
  try {
    localStorage.setItem(PREFS_KEY, JSON.stringify(prefs));
  } catch {
    // Quota exceeded — the choice just won't survive a restart.
  }
}

export async function renderFavorites(root: HTMLElement): Promise<void> {
  clear(root);

  const prefs = loadPrefs();
  let [sortBy, sortOrder] = prefs.sort.split("|");
  let startIndex = 0;
  let total = 0;
  let loading = false;
  let generation = 0;
  let loadedItems: any[] = [];
  const cacheKey = (): string => `favorites:${sortBy}|${sortOrder}:${prefs.type}`;

  const count = el("span", { class: "lib-count" }, [""]);
  root.append(
    el("div", { class: "section-head" }, [
      el("div", { class: "lib-head" }, [
        el("h1", { class: "page-title" }, ["Favorites"]),
        count,
      ]),
    ])
  );

  // ---- Filter bar ----
  const bar = el("div", { class: "filter-bar" });

  const sortSel = el("select", { class: "control", title: "Sort order" }) as HTMLSelectElement;
  for (const [value, label] of SORTS) sortSel.append(el("option", { value }, [label]));
  sortSel.value = prefs.sort;
  sortSel.addEventListener("change", () => {
    prefs.sort = sortSel.value;
    [sortBy, sortOrder] = sortSel.value.split("|");
    savePrefs(prefs);
    void loadPage(true);
  });
  bar.append(sortSel);

  // Type is one-of, so these are radio-style rather than the library's
  // independent on/off chips.
  const typeBtns = TYPES.map(([value, label]) => {
    const btn = el("button", {
      class: `btn small${value === prefs.type ? " active" : ""}`,
      onClick: () => {
        if (prefs.type === value) return;
        prefs.type = value;
        savePrefs(prefs);
        for (const b of typeBtns) b.classList.toggle("active", b === btn);
        void loadPage(true);
      },
    }, [label]) as HTMLButtonElement;
    return btn;
  });
  bar.append(...typeBtns);
  root.append(bar);

  const grid = el("div", { class: "card-grid" });
  const moreWrap = el("div", { class: "load-more" });
  const moreBtn = el("button", { class: "btn" }, ["Load more"]) as HTMLButtonElement;
  moreWrap.append(moreBtn);
  root.append(grid, moreWrap);

  function setCount(): void {
    count.textContent = total ? `${total} item${total === 1 ? "" : "s"}` : "";
  }

  /** A card whose star was just removed no longer belongs on this page — the
   *  query wouldn't return it, so leaving it there would be a lie until the
   *  next visit. */
  function onCardChanged(item: any, card: HTMLElement): void {
    if (item.UserData?.IsFavorite) return;
    card.remove();
    total = Math.max(0, total - 1);
    loadedItems = loadedItems.filter((i) => i.Id !== item.Id);
    setCached(cacheKey(), { items: loadedItems, total });
    setCount();
    if (!grid.children.length) showEmpty();
  }

  function showEmpty(): void {
    clear(grid);
    const typeName = TYPES.find(([v]) => v === prefs.type)?.[1] ?? "this type";
    grid.append(
      prefs.type
        ? emptyState({
            icon: "star",
            title: `Nothing starred under ${typeName}`,
            body: "You have favorites of other kinds — switch the filter to see them.",
            action: {
              label: "Show all favorites",
              run: () => {
                prefs.type = "";
                savePrefs(prefs);
                void renderFavorites(root);
              },
            },
          })
        : emptyState({
            icon: "star",
            title: "Nothing starred yet",
            body: "Right-click any poster (or press the Menu key on a focused card) and choose “Add to favorites”. Starred items collect here.",
            action: { label: "Browse Home", run: () => (location.hash = "#/home") },
          })
    );
  }

  async function loadPage(reset = false): Promise<void> {
    // Infinite scroll fires this repeatedly, so an in-flight page swallows the
    // extras — but a sort or filter change must never be dropped that way. It
    // supersedes instead: `generation` makes the older reply a no-op.
    if (loading && !reset) return;
    const gen = ++generation;
    loading = true;
    if (reset) {
      startIndex = 0;
      loadedItems = [];
      // Swap cards for placeholders rather than emptying the grid, so the page
      // keeps its height instead of collapsing and springing back.
      const onScreen = grid.querySelectorAll(".card").length;
      clear(grid);
      grid.append(...skeletonCards(onScreen || SKELETONS));
    }
    moreBtn.disabled = true;
    moreBtn.textContent = "Loading…";
    try {
      const r = await api.getFavorites({
        startIndex,
        limit: PAGE,
        includeTypes: prefs.type,
        sortBy,
        sortOrder,
      });
      // A newer sort/filter already owns the grid — this reply is stale.
      if (gen !== generation) return;
      if (reset) clear(grid);
      total = r.TotalRecordCount;
      loadedItems.push(...r.Items);
      for (const item of r.Items) grid.append(itemCard(item, { onChanged: onCardChanged }));
      startIndex += PAGE;
      setCount();
      moreWrap.style.display = startIndex < total ? "" : "none";
      setCached(cacheKey(), { items: loadedItems, total });
    } catch (e: any) {
      if (gen !== generation) return;
      if (reset) clear(grid);
      grid.append(errorState("Couldn't load favorites", e, () => void loadPage(reset)));
      moreWrap.style.display = "none";
    } finally {
      // The superseding call owns these; leave them to it.
      if (gen === generation) {
        loading = false;
        moreBtn.disabled = false;
        moreBtn.textContent = "Load more";
      }
    }
    if (!grid.children.length) showEmpty();
  }

  /** Cheap freshness check for a cached, already-painted grid: refetch just
   *  the first page and compare it to what the cache said page one was. See
   *  the same helper in library.ts for the full reasoning. */
  async function revalidateFirstPage(cachedItems: any[], cachedTotal: number): Promise<void> {
    const gen = generation;
    try {
      const r = await api.getFavorites({ startIndex: 0, limit: PAGE, includeTypes: prefs.type, sortBy, sortOrder });
      if (gen !== generation) return;
      const changed =
        itemSignature(r.Items) !== itemSignature(cachedItems.slice(0, PAGE)) ||
        (r.TotalRecordCount ?? 0) !== cachedTotal;
      if (changed) void loadPage(true);
    } catch {
      // Offline, or the server hiccuped — the cached grid stays as it was.
    }
  }

  moreBtn.addEventListener("click", () => void loadPage());

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

  const cachedPage = getCached<{ items: any[]; total: number }>(cacheKey());
  if (cachedPage?.items.length) {
    loadedItems = cachedPage.items.slice();
    total = cachedPage.total;
    startIndex = loadedItems.length;
    for (const item of loadedItems) grid.append(itemCard(item, { onChanged: onCardChanged }));
    setCount();
    moreWrap.style.display = startIndex < total ? "" : "none";
    void revalidateFirstPage(loadedItems, total);
  } else {
    await loadPage(true);
  }
}

/** Home's Favorites row. Returns null when nothing is starred, so Home simply
 *  doesn't grow an empty section. */
export async function favoritesRow(limit = 16): Promise<any[]> {
  const r = await api.getFavorites({ limit, sortBy: "DateCreated", sortOrder: "Descending" });
  return r.Items;
}
