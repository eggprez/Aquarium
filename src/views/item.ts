import * as api from "../api";
import { playItem, startDownload, downloadSeason } from "../playback";
import { el, clear, spinner, openMenu, toast } from "../ui";

const STREAM_QUALITIES: { label: string; maxBitrate?: number }[] = [
  { label: "Direct Play (original)" },
  { label: "Transcode · 20 Mbps 1080p", maxBitrate: 20_000_000 },
  { label: "Transcode · 10 Mbps 1080p", maxBitrate: 10_000_000 },
  { label: "Transcode · 4 Mbps 720p", maxBitrate: 4_000_000 },
  { label: "Transcode · 1.5 Mbps 480p", maxBitrate: 1_500_000 },
];

function downloadLabel(item: any, q: api.DownloadQuality): string {
  const est = api.estimateDownloadSize(item, q);
  if (est == null) return q.label;
  return `${q.label} · ${q.original ? "" : "~"}${api.bytesToText(est)}`;
}

function metaChips(item: any): HTMLElement {
  const bits: (HTMLElement | string)[] = [];
  if (item.ProductionYear) bits.push(el("span", {}, [String(item.ProductionYear)]));
  if (item.RunTimeTicks) bits.push(el("span", {}, [api.ticksToText(item.RunTimeTicks)]));
  if (item.OfficialRating) bits.push(el("span", { class: "chip" }, [item.OfficialRating]));
  if (item.CommunityRating) bits.push(el("span", {}, [`★ ${item.CommunityRating.toFixed(1)}`]));
  for (const g of (item.Genres ?? []).slice(0, 4)) bits.push(el("span", { class: "chip" }, [g]));
  return el("div", { class: "detail-meta" }, bits);
}

function playButtons(item: any): HTMLElement {
  const actions = el("div", { class: "detail-actions" });
  const resumeTicks = item.UserData?.PlaybackPositionTicks ?? 0;

  if (resumeTicks > 0) {
    actions.append(
      el("button", { class: "btn primary", onClick: () => playItem(item, { resume: true }) }, [
        `▶ Resume (${api.ticksToText(item.RunTimeTicks - resumeTicks)} left)`,
      ]),
      el("button", { class: "btn", onClick: () => playItem(item, { resume: false }) }, ["Play from start"])
    );
  } else {
    actions.append(
      el("button", { class: "btn primary", onClick: () => playItem(item, { resume: false }) }, ["▶ Play"])
    );
  }

  // Stream quality menu
  const qWrap = el("div", { class: "menu-wrap" });
  const qBtn = el("button", { class: "btn" }, ["Quality ▾"]);
  qBtn.addEventListener("click", () =>
    openMenu(qBtn, (menu) => {
      menu.append(el("div", { class: "menu-label" }, ["Stream as"]));
      for (const q of STREAM_QUALITIES) {
        menu.append(
          el("button", {
            onClick: () => {
              menu.remove();
              playItem(item, { resume: true, maxBitrate: q.maxBitrate });
            },
          }, [q.label])
        );
      }
    })
  );
  qWrap.append(qBtn);
  actions.append(qWrap);

  // Download menu
  const dWrap = el("div", { class: "menu-wrap" });
  const dBtn = el("button", { class: "btn" }, ["⬇ Download ▾"]);
  dBtn.addEventListener("click", () =>
    openMenu(dBtn, (menu) => {
      menu.append(el("div", { class: "menu-label" }, ["Download as"]));
      for (const q of api.DOWNLOAD_QUALITIES) {
        menu.append(
          el("button", {
            onClick: async () => {
              menu.remove();
              try {
                await startDownload(item, q);
              } catch (e: any) {
                toast(`Download failed to start: ${e.message ?? e}`, "error");
              }
            },
          }, [downloadLabel(item, q)])
        );
      }
    })
  );
  dWrap.append(dBtn);
  actions.append(dWrap);

  // Watched toggle
  const played = item.UserData?.Played;
  actions.append(
    el("button", {
      class: "btn",
      title: played ? "Mark unwatched" : "Mark watched",
      onClick: async (ev: MouseEvent) => {
        const btn = ev.currentTarget as HTMLButtonElement;
        try {
          await api.markPlayed(item.Id, !item.UserData?.Played);
          item.UserData = item.UserData ?? {};
          item.UserData.Played = !item.UserData.Played;
          btn.textContent = item.UserData.Played ? "✓ Watched" : "Mark watched";
        } catch (e: any) {
          toast(e.message ?? String(e), "error");
        }
      },
    }, [played ? "✓ Watched" : "Mark watched"])
  );

  return actions;
}

function episodeRow(ep: any): HTMLElement {
  const img = api.imageUrl(ep, "Primary", 400);
  const pct =
    ep.UserData?.PlaybackPositionTicks && ep.RunTimeTicks
      ? Math.min(100, (ep.UserData.PlaybackPositionTicks / ep.RunTimeTicks) * 100)
      : 0;
  const code = ep.IndexNumber != null ? `${ep.IndexNumber}. ` : "";

  const dlBtn = el("button", { class: "btn small" }, ["⬇"]);
  const dlWrap = el("div", { class: "menu-wrap" }, [dlBtn]);
  dlBtn.addEventListener("click", (ev) => {
    ev.stopPropagation();
    openMenu(dlBtn, (menu) => {
      menu.append(el("div", { class: "menu-label" }, ["Download as"]));
      for (const q of api.DOWNLOAD_QUALITIES) {
        menu.append(
          el("button", {
            onClick: () => {
              menu.remove();
              startDownload(ep, q).catch((e) => toast(String(e), "error"));
            },
          }, [downloadLabel(ep, q)])
        );
      }
    });
  });

  return el("div", { class: "ep-row" }, [
    el("div", { class: "ep-thumb", onClick: () => playItem(ep, { resume: true }) }, [
      img ? el("img", { src: img, loading: "lazy" }) : el("div", { class: "noart" }, ["▶"]),
      pct > 1
        ? el("div", { class: "progress-strip" }, [el("div", { style: `width:${pct}%` })])
        : null,
      ep.UserData?.Played ? el("div", { class: "badge played" }, ["✓"]) : null,
    ]),
    el("div", { class: "ep-body" }, [
      el("h4", {}, [`${code}${ep.Name}`]),
      el("p", {}, [ep.Overview ?? ""]),
      el("div", { class: "card-sub" }, [api.ticksToText(ep.RunTimeTicks)]),
    ]),
    el("div", { class: "ep-actions" }, [
      el("button", { class: "btn small primary", onClick: () => playItem(ep, { resume: true }) }, ["▶ Play"]),
      dlWrap,
    ]),
  ]);
}

function seasonDownloadBar(season: any, eps: any[]): HTMLElement {
  const btn = el("button", { class: "btn small" }, [`⬇ Download season · ${eps.length} ep`]);
  btn.addEventListener("click", () =>
    openMenu(btn, (menu) => {
      menu.append(el("div", { class: "menu-label" }, ["Download all episodes as"]));
      for (const q of api.DOWNLOAD_QUALITIES) {
        const total = eps.reduce((sum, ep) => {
          const e = api.estimateDownloadSize(ep, q);
          return e == null ? sum : sum + e;
        }, 0);
        const label = total > 0 ? `${q.label} · ${q.original ? "" : "~"}${api.bytesToText(total)}` : q.label;
        menu.append(
          el("button", {
            onClick: async () => {
              menu.remove();
              try {
                const { queued, skipped } = await downloadSeason(eps, q);
                if (queued) {
                  toast(
                    `Queued ${queued} episode${queued === 1 ? "" : "s"}` +
                      (skipped ? `, skipped ${skipped} already downloaded` : ""),
                    "ok"
                  );
                } else {
                  toast("All episodes are already downloaded or queued");
                }
              } catch (e: any) {
                toast(`Season download failed: ${e.message ?? e}`, "error");
              }
            },
          }, [label])
        );
      }
    })
  );
  return el("div", { class: "season-actions" }, [
    el("div", { class: "menu-wrap" }, [btn]),
  ]);
}

export async function renderItem(root: HTMLElement, itemId: string): Promise<void> {
  clear(root);
  root.append(spinner());
  const item = await api.getItem(itemId);
  clear(root);

  // Episodes get their series' backdrop for a nicer hero.
  const backdropSource =
    item.BackdropImageTags?.length ? item :
    item.ParentBackdropItemId
      ? { Id: item.ParentBackdropItemId, BackdropImageTags: item.ParentBackdropImageTags ?? [] }
      : item;
  const backdrop = api.imageUrl(backdropSource, "Backdrop", 1600);
  const poster = api.imageUrl(item, "Primary", 500);

  let title = item.Name;
  let subtitle = "";
  if (item.Type === "Episode") {
    title = item.Name;
    const s = item.ParentIndexNumber, e = item.IndexNumber;
    subtitle = `${item.SeriesName ?? ""}${s != null ? ` · Season ${s}` : ""}${e != null ? `, Episode ${e}` : ""}`;
  }

  const hero = el("div", {
    class: "detail-hero",
    style: backdrop ? `background-image:url("${backdrop}")` : "",
  }, [
    el("div", { class: "detail-inner" }, [
      el("div", { class: "detail-poster" }, [
        poster ? el("img", { src: poster }) : el("div", { class: "noart" }, [title?.slice(0, 1) ?? "?"]),
      ]),
      el("div", { class: "detail-info" }, [
        el("h1", {}, [title ?? ""]),
        subtitle
          ? el("div", {
              class: "detail-meta",
              style: "cursor:pointer",
              onClick: () => { if (item.SeriesId) location.hash = `#/item/${item.SeriesId}`; },
            }, [subtitle])
          : null,
        metaChips(item),
        item.Overview ? el("p", { class: "detail-overview" }, [item.Overview]) : null,
        item.Type !== "Series" ? playButtons(item) : el("div", { class: "detail-actions" }),
      ]),
    ]),
  ]);
  root.append(hero);

  if (item.Type === "Series") {
    const seasons = await api.getSeasons(item.Id).catch(() => []);
    if (!seasons.length) {
      root.append(el("div", { class: "empty" }, ["No seasons found."]));
      return;
    }
    const tabs = el("div", { class: "season-tabs" });
    const epList = el("div", {});
    root.append(tabs, epList);

    async function showSeason(season: any, btn: HTMLElement): Promise<void> {
      tabs.querySelectorAll(".btn").forEach((b) => b.classList.remove("active"));
      btn.classList.add("active");
      clear(epList);
      epList.append(spinner());
      const eps = await api.getEpisodes(item.Id, season.Id).catch(() => []);
      clear(epList);
      if (!eps.length) {
        epList.append(el("div", { class: "empty" }, ["No episodes."]));
        return;
      }
      epList.append(seasonDownloadBar(season, eps));
      for (const ep of eps) epList.append(episodeRow(ep));
    }

    seasons.forEach((season: any, idx: number) => {
      const btn = el("button", { class: "btn small" }, [season.Name ?? `Season ${season.IndexNumber}`]);
      btn.addEventListener("click", () => showSeason(season, btn));
      tabs.append(btn);
      if (idx === 0) showSeason(season, btn);
    });
  }
}
