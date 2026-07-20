// Small DOM helpers and shared components.
import * as api from "./api";
import { playItem } from "./playback";

export function el<K extends keyof HTMLElementTagNameMap>(
  tag: K,
  attrs: Record<string, any> = {},
  children: (Node | string | null | undefined)[] = []
): HTMLElementTagNameMap[K] {
  const node = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (v == null) continue;
    if (k === "class") node.className = v;
    else if (k === "html") node.innerHTML = v;
    else if (k.startsWith("on") && typeof v === "function") {
      node.addEventListener(k.slice(2).toLowerCase(), v);
    } else node.setAttribute(k, String(v));
  }
  for (const c of children) {
    if (c == null) continue;
    node.append(typeof c === "string" ? document.createTextNode(c) : c);
  }
  return node;
}

export function clear(node: HTMLElement): void {
  node.textContent = "";
}

export function spinner(): HTMLElement {
  return el("div", { class: "spinner" });
}

export function toast(msg: string, kind: "info" | "error" | "ok" = "info"): void {
  const root = document.getElementById("toasts")!;
  const t = el("div", { class: `toast ${kind === "info" ? "" : kind}` }, [msg]);
  root.append(t);
  setTimeout(() => {
    t.style.opacity = "0";
    t.style.transition = "opacity 0.3s";
    setTimeout(() => t.remove(), 350);
  }, 4200);
}

/** Close any open dropdown menus. Installed globally by main.ts. */
export function closeMenus(): void {
  document.querySelectorAll(".menu").forEach((m) => m.remove());
}

export function openMenu(
  anchor: HTMLElement,
  build: (menu: HTMLElement) => void
): void {
  closeMenus();
  const menu = el("div", { class: "menu" });
  build(menu);
  anchor.closest(".menu-wrap")?.append(menu);

  // Clamp to the viewport: flip horizontally/vertically when the default
  // below-left placement would run off the window.
  const r = menu.getBoundingClientRect();
  const pad = 8;
  if (r.right > window.innerWidth - pad) {
    menu.style.left = "auto";
    menu.style.right = "0";
  }
  if (r.bottom > window.innerHeight - pad) {
    menu.style.top = "auto";
    menu.style.bottom = "calc(100% + 6px)";
    // If flipping up would push it past the top, pin below and cap height.
    const r2 = menu.getBoundingClientRect();
    if (r2.top < pad) {
      menu.style.bottom = "auto";
      menu.style.top = "calc(100% + 6px)";
      menu.style.maxHeight = `${window.innerHeight - r.top - pad}px`;
    }
  }
  setTimeout(() => {
    const closer = (ev: MouseEvent) => {
      if (!menu.contains(ev.target as Node)) {
        menu.remove();
        document.removeEventListener("click", closer, true);
      }
    };
    document.addEventListener("click", closer, true);
  }, 0);
}

// ---------- Cards ----------

function progressPct(item: any): number | null {
  const ud = item.UserData;
  if (!ud?.PlaybackPositionTicks || !item.RunTimeTicks) return null;
  return Math.min(100, (ud.PlaybackPositionTicks / item.RunTimeTicks) * 100);
}

export function itemCard(item: any, opts: { wide?: boolean } = {}): HTMLElement {
  const wide = opts.wide ?? (item.Type === "Episode");
  const imgType = wide && item.Type === "Episode" ? "Primary" : "Primary";
  let img = api.imageUrl(item, imgType, wide ? 500 : 320);
  if (wide && !img && item.SeriesId) {
    img = api.imageUrl({ Id: item.SeriesId, ImageTags: {} }, "Primary", 320);
  }

  let title = item.Name ?? "";
  let sub = item.ProductionYear ? String(item.ProductionYear) : "";
  if (item.Type === "Episode") {
    title = item.SeriesName ?? item.Name;
    const s = item.ParentIndexNumber, e = item.IndexNumber;
    sub = s != null && e != null ? `S${s}:E${e} · ${item.Name}` : item.Name;
  } else if (item.Type === "Series" && item.UserData?.UnplayedItemCount) {
    sub = `${item.UserData.UnplayedItemCount} unplayed`;
  }

  const pct = progressPct(item);
  const played = item.UserData?.Played;
  const playable = ["Movie", "Episode", "Video", "TvChannel"].includes(item.Type);

  const poster = el("div", { class: "card-poster" }, [
    img
      ? el("img", { src: img, loading: "lazy", alt: "" })
      : el("div", { class: "noart" }, [title.slice(0, 1).toUpperCase() || "?"]),
    pct != null && pct > 1
      ? el("div", { class: "progress-strip" }, [el("div", { style: `width:${pct}%` })])
      : null,
    played ? el("div", { class: "badge played" }, ["✓"]) : null,
    playable
      ? el("div", { class: "play-overlay" }, [
          el("button", {
            class: "pbtn",
            title: "Play",
            onClick: (ev: MouseEvent) => {
              ev.stopPropagation();
              playItem(item, { resume: true });
            },
          }, ["▶"]),
        ])
      : null,
  ]);

  return el(
    "div",
    {
      class: `card${wide ? " wide" : ""}`,
      onClick: () => {
        location.hash = `#/item/${item.Id}`;
      },
    },
    [poster, el("div", { class: "card-title" }, [title]), el("div", { class: "card-sub" }, [sub])]
  );
}

export function cardRow(items: any[], opts: { wide?: boolean } = {}): HTMLElement {
  return el("div", { class: "card-row" }, items.map((i) => itemCard(i, opts)));
}

export function section(title: string, content: HTMLElement, seeAll?: () => void): HTMLElement {
  return el("div", { class: "section" }, [
    el("div", { class: "section-head" }, [
      el("h2", {}, [title]),
      seeAll ? el("a", { class: "see-all", onClick: seeAll }, ["See all"]) : null,
    ]),
    content,
  ]);
}
