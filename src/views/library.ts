import * as api from "../api";
import { el, clear, spinner, itemCard } from "../ui";

const PAGE = 60;

export async function renderLibrary(root: HTMLElement, libId: string): Promise<void> {
  clear(root);
  root.append(spinner());

  const lib = await api.getItem(libId).catch(() => null);
  const includeTypes =
    lib?.CollectionType === "movies" ? "Movie" :
    lib?.CollectionType === "tvshows" ? "Series" : "";

  let sortBy = "SortName";
  let sortOrder = "Ascending";
  let startIndex = 0;
  let total = 0;

  clear(root);
  const head = el("div", { class: "section-head" }, [
    el("h1", { class: "page-title", style: "margin-bottom:0" }, [lib?.Name ?? "Library"]),
  ]);
  const sortSel = el("select", {}, []) as HTMLSelectElement;
  for (const [v, label] of [
    ["SortName|Ascending", "A – Z"],
    ["SortName|Descending", "Z – A"],
    ["DateCreated|Descending", "Recently added"],
    ["PremiereDate|Descending", "Release date"],
    ["CommunityRating|Descending", "Rating"],
  ]) {
    sortSel.append(el("option", { value: v }, [label]));
  }
  sortSel.style.cssText =
    "background:var(--bg-raised);border:1px solid var(--border);color:var(--text);border-radius:8px;padding:7px 10px;font-size:13px;";
  head.append(sortSel);
  root.append(head);

  const grid = el("div", { class: "card-grid" });
  const moreWrap = el("div", { style: "text-align:center;margin-top:24px" });
  const moreBtn = el("button", { class: "btn" }, ["Load more"]) as HTMLButtonElement;
  moreWrap.append(moreBtn);
  root.append(grid, moreWrap);

  async function loadPage(reset = false): Promise<void> {
    if (reset) {
      startIndex = 0;
      clear(grid);
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
      });
      total = r.TotalRecordCount ?? 0;
      for (const item of r.Items ?? []) grid.append(itemCard(item));
      startIndex += PAGE;
      moreWrap.style.display = startIndex < total ? "" : "none";
    } finally {
      moreBtn.disabled = false;
      moreBtn.textContent = "Load more";
    }
    if (!grid.children.length) {
      grid.append(el("div", { class: "empty" }, ["No items in this library."]));
    }
  }

  sortSel.addEventListener("change", () => {
    [sortBy, sortOrder] = sortSel.value.split("|");
    loadPage(true);
  });
  moreBtn.addEventListener("click", () => loadPage());

  await loadPage(true);
}

export async function renderSearch(root: HTMLElement, term: string): Promise<void> {
  clear(root);
  root.append(spinner());
  const items = await api.search(term).catch(() => []);
  clear(root);
  root.append(el("h1", { class: "page-title" }, [`Search: “${term}”`]));
  if (!items.length) {
    root.append(el("div", { class: "empty" }, ["No results."]));
    return;
  }
  root.append(el("div", { class: "card-grid" }, items.map((i: any) => itemCard(i))));
}
