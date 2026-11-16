// What Seerr adds to the app: the Requests page, a title's request page, the
// "Not in Your Library" row under Search, and what a show's or a collection's
// own page gains (seasons and films that aren't here yet).
//
// The cards and rows look like the library's own on purpose: a title that
// isn't here yet is still a title. What differs is where the picture comes
// from (TMDB, by way of the Seerr server's own image proxy; `seerr.imageUrl`)
// and the badge that says how far a request has got.
//
// Everything here draws nothing at all when no Seerr server is connected, so
// the app looks exactly as it did for anyone without one.
import * as seerr from "../seerr";
import type { SeerrMediaKind, SeerrQuota, SeerrRequest, SeerrResult, SeerrTitle } from "../seerr";
import {
  el,
  clear,
  art,
  icon,
  toast,
  openDialog,
  scrollRow,
  emptyState,
  errorState,
  skeletonDetail,
  skeletonRow,
} from "../ui";
import { getCached, setCached, invalidateCache } from "../cache";

// ---------- Cards and shelves ----------

/** One title from Seerr: poster, name, year, and a badge once it has been
 *  asked for. */
export function requestCard(result: SeerrResult): HTMLElement {
  const name = seerr.displayTitle(result);
  const kind = seerr.kindOf(result);
  const badge = seerr.STANDING_BADGE[seerr.standingOfMedia(result.mediaInfo)];
  const sub = [seerr.resultYear(result), kind === "tv" ? "Show" : "Film"].filter(Boolean).join(" · ");
  const open = (): void => {
    const hash = seerr.hashFor(result);
    if (hash) location.hash = hash;
  };
  return el(
    "div",
    {
      class: "card request-card",
      role: "button",
      tabindex: "0",
      "aria-label": badge ? `${name} — ${sub} — ${badge}` : `${name} — ${sub}`,
      "data-seerr": seerr.resultKey(result),
      onClick: open,
      onKeydown: (ev: KeyboardEvent) => {
        if (ev.key !== "Enter" && ev.key !== " ") return;
        ev.preventDefault();
        open();
      },
    },
    [
      el("div", { class: "card-poster" }, [
        art(seerr.imageUrl(result.posterPath, "poster"), name),
        badge ? el("div", { class: "badge request-badge" }, [badge]) : null,
      ]),
      el("div", { class: "card-title" }, [name]),
      el("div", { class: "card-sub" }, [sub]),
    ]
  );
}

/** A horizontal shelf of Seerr titles, or `null` when it has none: a shelf
 *  with nothing on it is not drawn. `key` names the row for tests. */
export function requestShelf(
  title: string,
  results: SeerrResult[],
  key: string,
  subtitle?: string
): HTMLElement | null {
  if (!results.length) return null;
  return el("div", { class: "section request-shelf", "data-shelf": key }, [
    el("div", { class: "section-head" }, [
      el("div", {}, [
        el("h2", {}, [title]),
        subtitle ? el("div", { class: "request-shelf-sub" }, [subtitle]) : null,
      ]),
    ]),
    scrollRow(el("div", { class: "card-row" }, results.map(requestCard))),
  ]);
}

// ---------- The Requests page ----------

/** What the page draws, as cached: this account's requests, what each is a
 *  request *for* (Seerr's list names titles only by TMDB id), and the browse
 *  rows. */
interface RequestsData {
  mine: SeerrRequest[];
  names: Record<string, SeerrTitle>;
  rows: Record<string, SeerrResult[]>;
}

const REQUESTS_KEY = "seerr:requests";
const titleKey = (kind: SeerrMediaKind, tmdbId: number): string => `seerr:title:${kind}-${tmdbId}`;
const QUOTA_KEY = "seerr:quota";

/** Only what a row or a card draws, so a refresh that changed nothing on
 *  screen repaints nothing. */
function requestsSignature(d: RequestsData): string {
  const card = (r: SeerrResult): string => `${seerr.resultKey(r)}:${r.mediaInfo?.status ?? 0}:${r.posterPath ?? ""}`;
  return JSON.stringify([
    d.mine.map((r) => [
      r.id,
      r.status ?? 0,
      r.media?.status ?? 0,
      r.is4k ? 1 : 0,
      (r.seasons ?? []).map((s) => s.seasonNumber),
      seerr.displayTitle(d.names[nameKey(r)]),
      d.names[nameKey(r)]?.posterPath ?? "",
    ]),
    seerr.BROWSE_ROWS.map((row) => (d.rows[row.key] ?? []).map(card)),
  ]);
}

function nameKey(request: SeerrRequest): string {
  return `${seerr.requestKind(request) ?? "?"}-${request.media?.tmdbId ?? 0}`;
}

/** The few fields of a title a request's row draws; the whole page of a
 *  title per row would be a lot to keep. */
function slim(title: SeerrTitle): SeerrTitle {
  return {
    id: title.id,
    title: title.title,
    name: title.name,
    posterPath: title.posterPath,
    releaseDate: title.releaseDate,
    firstAirDate: title.firstAirDate,
  };
}

/** One request in the carousel: its poster with how far it has got on it,
 *  its name, what was asked for, and where it stands. */
function requestTile(request: SeerrRequest, title: SeerrTitle | undefined): HTMLElement {
  const standing = seerr.standingOfRequest(request);
  const tone = standing === "available" ? " ok" : standing === "declined" || standing === "failed" ? " warn" : "";
  const badge = seerr.STANDING_BADGE[standing];
  const name = seerr.displayTitle(title);
  const open = (): void => {
    const hash = seerr.hashForRequest(request);
    if (hash) location.hash = hash;
  };
  return el(
    "div",
    {
      class: "card request-card request-mine-card",
      role: "button",
      tabindex: "0",
      "data-request": String(request.id),
      "aria-label": `${name} — ${seerr.STANDING_LABEL[standing]}`,
      onClick: open,
      onKeydown: (ev: KeyboardEvent) => {
        if (ev.key !== "Enter" && ev.key !== " ") return;
        ev.preventDefault();
        open();
      },
    },
    [
      el("div", { class: "card-poster" }, [
        art(seerr.imageUrl(title?.posterPath, "poster"), name || "?"),
        badge ? el("div", { class: "badge request-badge" }, [badge]) : null,
      ]),
      el("div", { class: "card-title request-row-title" }, [name || " "]),
      el("div", { class: "card-sub request-row-detail" }, [seerr.requestDetail(request, title)]),
      el("div", { class: `card-sub request-row-status${tone}` }, [seerr.STANDING_LABEL[standing]]),
    ]
  );
}

/** Seerr's Cache Images is off, so its image proxy refuses every poster. */
function postersOffNotice(): HTMLElement {
  return el("div", { class: "request-posters-off", role: "note" }, [
    el("div", { class: "request-posters-off-title" }, [seerr.POSTERS_OFF_TITLE]),
    el("div", { class: "request-note" }, [seerr.POSTERS_OFF]),
  ]);
}

function paintRequests(page: HTMLElement, data: RequestsData, mineError: string | null): void {
  clear(page);
  if (seerr.postersOff()) page.append(postersOffNotice());
  const yours = el("div", { class: "section request-mine" }, [
    el("div", { class: "section-head" }, [el("h2", {}, ["Your Requests"])]),
  ]);
  if (data.mine.length) {
    // One carousel, the way the rows under it are drawn.
    yours.append(
      scrollRow(el("div", { class: "card-row" }, data.mine.map((r) => requestTile(r, data.names[nameKey(r)]))))
    );
  } else if (mineError) {
    yours.append(el("p", { class: "request-note request-mine-error" }, [mineError]));
  } else {
    yours.append(
      el("p", { class: "request-note request-mine-empty" }, [
        "Nothing requested yet. Search for a film or a show, or pick one below.",
      ])
    );
  }
  page.append(yours);
  // Trending first (BROWSE_ROWS' order), then the rest.
  for (const row of seerr.BROWSE_ROWS) {
    const shelf = requestShelf(row.title, data.rows[row.key] ?? [], row.key);
    if (shelf) page.append(shelf);
  }
}

export async function renderRequests(root: HTMLElement): Promise<void> {
  clear(root);
  root.append(el("h1", { class: "page-title" }, ["Requests"]));

  if (!seerr.isConnected()) {
    const out = seerr.needsReconnect();
    root.append(
      emptyState({
        icon: "library",
        title: out ? "Reconnect to Seerr" : "Requests aren't set up",
        body: out
          ? "The connection to Seerr has run out. Reconnect in Settings, under Requests."
          : "Connect a Seerr server in Settings, under Requests, to ask for films and shows.",
        action: { label: "Open Settings", run: () => (location.hash = "#/settings") },
      })
    );
    return;
  }

  const page = el("div", { class: "requests-page" });
  root.append(page);
  const cached = getCached<RequestsData>(REQUESTS_KEY);
  if (cached) {
    paintRequests(page, cached, null);
  } else {
    page.append(
      el("div", { class: "section" }, [
        el("div", { class: "section-head" }, [el("h2", {}, ["Your Requests"])]),
      ]),
      skeletonRow(),
      skeletonRow()
    );
  }

  let mine = cached?.mine ?? [];
  let mineError: string | null = null;
  // Picks up Cache Images being turned on (or off) since the last look.
  const wasOff = seerr.postersOff();
  await seerr.refreshAccount();
  try {
    mine = await seerr.myRequests();
  } catch (e: any) {
    mineError = e?.message ?? String(e);
  }
  // Navigated away, or the session ran out and the page was redrawn to say so.
  if (!document.contains(page)) return;

  // Each row's name and poster are looked up, and remembered: a title's page
  // is the same answer the request page caches.
  const names: Record<string, SeerrTitle> = { ...(cached?.names ?? {}) };
  await Promise.all(
    mine.map(async (request) => {
      const kind = seerr.requestKind(request);
      const tmdbId = request.media?.tmdbId;
      if (!kind || typeof tmdbId !== "number" || names[nameKey(request)]) return;
      const known = getCached<SeerrTitle>(titleKey(kind, tmdbId));
      if (known) {
        names[nameKey(request)] = slim(known);
        return;
      }
      try {
        const found = await seerr.title(kind, tmdbId);
        setCached(titleKey(kind, tmdbId), found);
        names[nameKey(request)] = slim(found);
      } catch {
        /* the row is drawn without a name */
      }
    })
  );
  const rows: Record<string, SeerrResult[]> = { ...(cached?.rows ?? {}) };
  await Promise.all(
    seerr.BROWSE_ROWS.map(async (row) => {
      try {
        rows[row.key] = await seerr.browse(row);
      } catch {
        /* the row keeps what it had, or isn't drawn */
      }
    })
  );
  if (!document.contains(page)) return;

  // Only the names still asked for are kept.
  const wanted = new Set(mine.map(nameKey));
  for (const key of Object.keys(names)) if (!wanted.has(key)) delete names[key];
  const data: RequestsData = { mine, names, rows };
  if (!mineError) setCached(REQUESTS_KEY, data);
  if (!cached || mineError || wasOff !== seerr.postersOff() || requestsSignature(cached) !== requestsSignature(data)) {
    paintRequests(page, data, mineError);
  }
}

// ---------- A title's request page ----------

/** `movie/603` → what the page is for, or `null` for anything else. */
export function parseRequestRoute(arg: string): { kind: SeerrMediaKind; tmdbId: number } | null {
  const m = /^(movie|tv)\/(\d{1,12})$/.exec(arg);
  return m ? { kind: m[1] as SeerrMediaKind, tmdbId: Number(m[2]) } : null;
}

/**
 * A title that isn't in the library: what it is, and the button that asks for
 * it. It says where the title stands (not here, asked for, on its way, here),
 * offers the one thing that can be done about it, and for a show lists the
 * seasons so some of them can be asked for without the rest.
 */
export async function renderRequestTitle(root: HTMLElement, arg: string): Promise<void> {
  clear(root);
  const route = parseRequestRoute(arg);
  if (!route) {
    root.append(emptyState({ icon: "error", error: true, title: "That isn't a title", body: "The link to this page is broken." }));
    return;
  }
  if (!seerr.isConnected()) {
    await renderRequests(root);
    return;
  }
  const { kind, tmdbId } = route;
  const page = el("div", { class: "request-page", "data-title": `${kind}-${tmdbId}` });
  root.append(page);

  let shown: SeerrTitle | null = getCached<SeerrTitle>(titleKey(kind, tmdbId)) ?? null;
  let quota: SeerrQuota | null = getCached<SeerrQuota>(QUOTA_KEY) ?? null;
  /** The seasons ticked for the request. Starts as every season that can
   *  still be asked for. */
  let chosen = new Set<number>();
  let wants4K = false;
  let sending = false;

  const paint = (): void => {
    clear(page);
    if (!shown) return;
    const found = shown;
    const status = seerr.getStatus();
    const rights = status.permissions ?? 0;
    const name = seerr.displayTitle(found);
    const standing = seerr.standingOfMedia(found.mediaInfo);
    const open = seerr.requestableSeasons(found);
    const canAsk = kind === "movie" ? standing === "requestable" : open.length > 0;
    const allowance = kind === "movie" ? quota?.movie : quota?.tv;
    const outOfQuota = allowance?.restricted === true;
    const mayAsk = seerr.canRequest(rights, kind);
    const offers4K =
      (kind === "movie" ? status.settings?.movie4kEnabled : status.settings?.series4kEnabled) === true &&
      seerr.canRequest4K(rights, kind);
    // Whether seasons can be ticked one at a time: Seerr's administrator can
    // turn that off, and then a show is asked for whole.
    const picksSeasons = status.settings?.partialRequestsEnabled !== false;
    const mine = seerr.myPendingRequest(found, status.user_id);

    const actions = el("div", { class: "detail-actions request-actions" });
    const notes: (HTMLElement | null)[] = [];
    let askButton: HTMLButtonElement | null = null;
    const syncAsk = (): void => {
      if (!askButton) return;
      askButton.disabled = sending || outOfQuota || (kind === "tv" && chosen.size === 0);
      askButton.lastChild!.textContent = seerr.requestLabel(found, kind, chosen.size);
    };

    const libraryId = seerr.libraryItemId(found.mediaInfo);
    const avail = seerr.availability(found.mediaInfo?.status);
    if (libraryId && (avail === "available" || avail === "partiallyAvailable")) {
      actions.append(
        el("button", {
          class: `btn request-open${canAsk ? "" : " primary"}`,
          onClick: () => (location.hash = `#/item/${libraryId}`),
        }, [icon("play"), "Open in Library"])
      );
    }
    if (canAsk) {
      if (!mayAsk) {
        notes.push(
          el("p", { class: "request-note request-not-allowed" }, [
            `This account can't request ${seerr.KIND_NOUN[kind]}s. Ask whoever runs the server.`,
          ])
        );
      } else {
        askButton = el("button", { class: "btn primary request-ask", onClick: () => void send() }, [
          icon("download"),
          seerr.requestLabel(found, kind, chosen.size),
        ]) as HTMLButtonElement;
        actions.append(askButton);
        if (offers4K) {
          const box = el("input", { type: "checkbox", class: "request-4k-box" }) as HTMLInputElement;
          box.checked = wants4K;
          box.addEventListener("change", () => {
            wants4K = box.checked;
          });
          notes.push(el("label", { class: "request-4k" }, [box, "Ask for the 4K version"]));
        }
        const summary = seerr.quotaSummary(allowance);
        if (summary) notes.push(el("p", { class: `request-note request-quota${outOfQuota ? " warn" : ""}` }, [summary]));
        syncAsk();
      }
    }
    if (mine) {
      const cancelButton = el("button", {
        class: "btn danger request-cancel",
        onClick: () =>
          openDialog({
            title: "Cancel this request?",
            actions: [
              { label: "Keep It", primary: true },
              { label: "Cancel Request", danger: true, run: () => void cancelMine(mine) },
            ],
          }),
      }, [icon("close"), "Cancel Request"]) as HTMLButtonElement;
      cancelButton.disabled = sending;
      actions.append(cancelButton);
    }

    page.append(
      el("div", { class: "detail-hero request-hero" }, [
        el("div", { class: "detail-inner" }, [
          el("div", { class: "detail-poster" }, [
            art(seerr.imageUrl(found.posterPath, "posterLarge"), name || "?", { lazy: false }),
          ]),
          el("div", { class: "detail-info" }, [
            el("h1", { class: "detail-title" }, [name]),
            el("div", { class: "detail-meta" }, [seerr.titleFacts(found, kind)]),
            found.tagline ? el("p", { class: "request-tagline" }, [found.tagline]) : null,
            el("div", { class: `request-standing${standing === "available" ? " ok" : ""}` }, [
              seerr.STANDING_LABEL[standing],
            ]),
            found.overview ? el("p", { class: "detail-overview" }, [found.overview]) : null,
            actions.children.length ? actions : null,
            ...notes,
          ]),
        ]),
      ])
    );

    if (kind === "tv") {
      const all = seerr.realSeasons(found);
      if (all.length) {
        const list = el("div", { class: "section request-seasons" }, [
          el("div", { class: "section-head" }, [el("h2", {}, ["Seasons"])]),
        ]);
        for (const season of all) {
          const n = season.seasonNumber;
          const seasonStanding = seerr.standingOfSeason(found, n);
          const isOpen = seasonStanding === "requestable";
          const line = [
            season.episodeCount && season.episodeCount > 0
              ? `${season.episodeCount} episode${season.episodeCount === 1 ? "" : "s"}`
              : null,
            seerr.yearOf(season.airDate),
            isOpen ? null : seerr.STANDING_LABEL[seasonStanding],
          ].filter(Boolean).join(" · ");
          const tick = el("span", { class: "request-season-tick", "aria-hidden": "true" });
          const row = el("button", {
            class: "request-season",
            type: "button",
            "data-season": String(n),
          }, [
            tick,
            el("span", { class: "request-season-body" }, [
              el("span", { class: "request-season-name" }, [season.name ?? `Season ${n}`]),
              el("span", { class: "request-season-line" }, [line]),
            ]),
          ]) as HTMLButtonElement;
          const syncTick = (): void => {
            const on = isOpen && chosen.has(n);
            row.classList.toggle("chosen", on);
            if (isOpen) row.setAttribute("aria-pressed", on ? "true" : "false");
            clear(tick);
            if (on || seasonStanding === "available") tick.append(icon("check"));
          };
          syncTick();
          row.disabled = !isOpen || !picksSeasons || !mayAsk;
          row.addEventListener("click", () => {
            if (!isOpen || !picksSeasons) return;
            if (chosen.has(n)) chosen.delete(n);
            else chosen.add(n);
            syncTick();
            syncAsk();
          });
          list.append(row);
        }
        page.append(list);
      }
    }

    const cast = (found.credits?.cast ?? []).map((c) => c?.name).filter((c): c is string => !!c).slice(0, 8);
    if (cast.length) {
      page.append(
        el("div", { class: "section request-cast" }, [
          el("div", { class: "section-head" }, [el("h2", {}, ["Cast"])]),
          el("p", { class: "detail-overview" }, [cast.join(", ")]),
        ])
      );
    }
  };

  /** Always asked again on the way in: the page exists to say where the
   *  title stands now, not where it stood when a list was drawn. */
  const load = async (): Promise<void> => {
    let found: SeerrTitle | null = null;
    let failure: any = null;
    try {
      found = await seerr.title(kind, tmdbId);
    } catch (e) {
      failure = e;
    }
    if (!document.contains(page)) return;
    if (!found) {
      if (!shown) {
        clear(page);
        page.append(errorState("This title didn't load", failure, () => void renderRequestTitle(root, arg)));
      }
      return;
    }
    setCached(titleKey(kind, tmdbId), found);
    // Permissions change, and so does whether 4K is on offer; the allowance
    // is used up as requests are made.
    const [freshQuota] = await Promise.all([seerr.quota().catch(() => null), seerr.refreshAccount()]);
    if (!document.contains(page)) return;
    if (freshQuota) {
      quota = freshQuota;
      setCached(QUOTA_KEY, freshQuota);
    }
    shown = found;
    chosen = new Set(seerr.requestableSeasons(found).map((s) => s.seasonNumber));
    paint();
  };

  const send = async (): Promise<void> => {
    if (sending || !shown) return;
    const name = seerr.displayTitle(shown);
    sending = true;
    paint();
    try {
      const made = await seerr.request(kind, tmdbId, {
        seasons: kind === "tv" ? [...chosen].sort((a, b) => a - b) : undefined,
        is4k: wants4K,
      });
      const approved = seerr.requestStatus(made.status) === "approved";
      toast(
        approved ? `Requested ${name}. It's on its way.` : `Requested ${name}. It's waiting for approval.`,
        "ok"
      );
    } catch (e: any) {
      toast(e?.message ?? String(e), "error");
    }
    sending = false;
    invalidateCache(REQUESTS_KEY);
    if (!document.contains(page)) return;
    await load();
  };

  const cancelMine = async (mine: SeerrRequest): Promise<void> => {
    if (sending) return;
    sending = true;
    paint();
    try {
      await seerr.cancel(mine);
      toast("Request cancelled");
    } catch (e: any) {
      toast(e?.message ?? String(e), "error");
    }
    sending = false;
    invalidateCache(REQUESTS_KEY);
    if (!document.contains(page)) return;
    await load();
  };

  if (shown) {
    chosen = new Set(seerr.requestableSeasons(shown).map((s) => s.seasonNumber));
    paint();
  } else {
    page.append(skeletonDetail());
  }
  await load();
}

// ---------- Search, carried on past the library ----------

/** Longer than the library's own debounce: this one leaves the house. */
export const SEERR_SEARCH_DEBOUNCE_MS = 450;

/**
 * What Seerr knows by the same name that isn't here yet. Drawn under the
 * library's own results, and under "No results" when the library has none,
 * which is the case it exists for: a search that finds nothing now ends in a
 * title that can be asked for.
 *
 * `null` when no Seerr server is connected or the term is too short to send.
 * Otherwise an empty box that fills itself once the search has been still
 * for a moment; a box that has left the page by then never asks.
 */
export function seerrSearchSection(term: string): HTMLElement | null {
  const query = term.trim();
  if (!seerr.isConnected() || query.length < 2) return null;
  const box = el("div", { class: "seerr-search" });
  window.setTimeout(() => {
    if (!document.contains(box)) return;
    // Each search reads Seerr's Cache Images again, beside the search itself,
    // so posters it refused before it was turned on are asked for again.
    void Promise.all([seerr.search(query), seerr.refreshAccount()])
      .then(([found]) => {
        if (!document.contains(box)) return;
        const shelf = requestShelf("Not in Your Library", seerr.notInLibrary(found), "search", "Open one to request it.");
        if (shelf) box.append(shelf);
      })
      .catch(() => {
        /* Search stands on the library's own results */
      });
  }, SEERR_SEARCH_DEBOUNCE_MS);
  return box;
}

// ---------- What a library page gains ----------

const collectionKey = (tmdbId: number): string => `seerr:collection:${tmdbId}`;

/** "1 more season exists" / "Seasons 3 and 4 aren't in your library." */
function moreSeasons(tmdbId: number, missing: number[]): HTMLElement {
  return el("div", { class: "seerr-more-seasons" }, [
    el("div", { class: "seerr-more-text" }, [
      el("div", { class: "seerr-more-title" }, [
        missing.length === 1 ? "1 more season exists" : `${missing.length} more seasons exist`,
      ]),
      el("div", { class: "seerr-more-sub" }, [
        `${seerr.seasonList(missing)}${missing.length === 1 ? " isn't" : " aren't"} in your library.`,
      ]),
    ]),
    el("button", { class: "btn small seerr-more-button", onClick: () => (location.hash = `#/request/tv/${tmdbId}`) }, [
      "Request…",
    ]),
  ]);
}

/**
 * Under a show or a collection: the seasons of a show that aren't here, the
 * films of a collection that aren't. `null` when Seerr isn't connected or the
 * item has no TMDB id; otherwise a box that stays empty until there is
 * something to say. What was found last time is drawn at once and checked
 * behind itself.
 */
export function seerrItemHooks(item: any): HTMLElement | null {
  const tmdbId = seerr.tmdbIdOf(item);
  if (!seerr.isConnected() || tmdbId == null) return null;
  if (item?.Type !== "Series" && item?.Type !== "BoxSet") return null;
  const box = el("div", { class: "seerr-hooks" });

  if (item.Type === "Series") {
    const draw = (title: SeerrTitle | undefined): string => {
      const missing = title ? seerr.requestableSeasons(title).map((s) => s.seasonNumber) : [];
      clear(box);
      if (missing.length) box.append(moreSeasons(tmdbId, missing));
      return missing.join(",");
    };
    const before = draw(getCached<SeerrTitle>(titleKey("tv", tmdbId)));
    void seerr
      .title("tv", tmdbId)
      .then((found) => {
        setCached(titleKey("tv", tmdbId), found);
        const now = seerr.requestableSeasons(found).map((s) => s.seasonNumber).join(",");
        if (now !== before) draw(found);
      })
      .catch(() => {});
    return box;
  }

  const draw = (parts: SeerrResult[] | undefined): string => {
    const missing = (parts ?? []).filter(seerr.isRequestable);
    clear(box);
    const shelf = requestShelf("Missing From This Collection", missing, "collection", "Open one to request it.");
    if (shelf) box.append(shelf);
    return missing.map((r) => `${r.id}:${r.mediaInfo?.status ?? 0}`).join(",");
  };
  const before = draw(getCached<SeerrResult[]>(collectionKey(tmdbId)));
  void seerr
    .collection(tmdbId)
    .then((parts) => {
      setCached(collectionKey(tmdbId), parts);
      const now = parts.filter(seerr.isRequestable).map((r) => `${r.id}:${r.mediaInfo?.status ?? 0}`).join(",");
      if (now !== before) draw(parts);
    })
    .catch(() => {});
  return box;
}
