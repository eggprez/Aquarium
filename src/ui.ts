// Small DOM helpers and shared components.
import * as api from "./api";
import { blurhashUrl } from "./blurhash";
import { icon, iconSvg, type IconName } from "./icons";
import { playItem, startDownload, downloadSeries } from "./playback";

export { icon, type IconName } from "./icons";

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

// ---------- Artwork ----------

/** Letter tile shown wherever artwork is missing or unusable. */
export function noart(text: string): HTMLElement {
  return el("div", { class: "noart" }, [(text ?? "").trim().slice(0, 1).toUpperCase() || "?"]);
}

/** The same tile with an icon instead of a letter, where an initial would be
 *  meaningless (an episode still, a cast headshot). */
export function noartIcon(name: IconName, px = 28): HTMLElement {
  return el("div", { class: "noart" }, [icon(name, px)]);
}

/**
 * An `<img>` that fades in once it has decoded and replaces itself with a
 * placeholder if the source fails. Both halves matter in practice: artwork
 * arrives over the network a beat after the layout, and image URLs go stale
 * routinely (Jellyfin re-tags images on a metadata refresh, and a deleted
 * download can outlive its poster file) — without the error hook a dead URL
 * just leaves an empty grey box.
 */
export function art(
  src: string | null | undefined,
  fallback: string | (() => Node),
  opts: { lazy?: boolean; hash?: string | null } = {}
): Node {
  const placeholder = (): Node => (typeof fallback === "function" ? fallback() : noart(fallback));
  if (!src) return placeholder();
  // The artwork's own colours, decoded from the ~30 byte hash the server sends
  // with the item, painted underneath the real image. An <img> renders nothing
  // until it has decoded, so its own background is what shows through the gap.
  const ph = blurhashUrl(opts.hash);
  const img = el("img", {
    class: `art${ph ? " has-ph" : ""}`,
    src,
    alt: "",
    // Decoding off the main thread: a row of freshly-arrived posters otherwise
    // decodes synchronously during scroll, which is exactly when a dropped
    // frame is most visible.
    decoding: "async",
    ...(opts.lazy === false ? {} : { loading: "lazy" }),
  }) as HTMLImageElement;
  if (ph) img.style.backgroundImage = `url("${ph}")`;
  // A cached image can already be complete before the listener is attached.
  if (img.complete && img.naturalWidth > 0) img.classList.add("loaded");
  else img.addEventListener("load", () => img.classList.add("loaded"), { once: true });
  img.addEventListener("error", () => img.replaceWith(placeholder()), { once: true });
  return img;
}

/**
 * A background-image layer that stays transparent until the artwork has
 * decoded, then fades in. Used behind the home and detail heroes, where a
 * half-painted 1600px still sliding in under the title is the loudest pop-in
 * on the page.
 */
export function backdropLayer(url: string | null | undefined, cls: string): HTMLElement | null {
  if (!url) return null;
  const layer = el("div", { class: cls });
  const pre = new Image();
  pre.addEventListener("load", () => {
    layer.style.backgroundImage = `url("${url}")`;
    layer.classList.add("loaded");
  });
  pre.src = url;
  return layer;
}

/**
 * Title art for a hero: the transparent wordmark the studio ships with the
 * title, in place of typeset text. It's the single loudest "this is a real
 * streaming app" detail — Apple TV, Infuse and Netflix all set the title in the
 * artwork's own lettering — and it costs nothing when the server hasn't got one,
 * because the text stays in the DOM underneath.
 *
 * Which of the two shows is a CSS decision, not a JS one, so flipping the theme
 * doesn't need a re-render: logos are almost always white-on-transparent and
 * would disappear against the light theme's hero.
 */
export function heroTitle(item: any, text: string, cls: string): HTMLElement {
  const h = el("h1", { class: cls }, [el("span", { class: "title-text" }, [text])]);
  const url = api.logoUrl(item, 640);
  if (!url) return h;
  const img = el("img", { class: "title-logo", src: url, alt: text }) as HTMLImageElement;
  // Only switch to the logo once it has actually decoded — a 404 or a broken
  // PNG would otherwise leave the hero with no title at all.
  const show = (): void => {
    if (img.naturalWidth > 0) h.classList.add("has-logo");
  };
  if (img.complete) show();
  else img.addEventListener("load", show, { once: true });
  img.addEventListener("error", () => img.remove(), { once: true });
  h.prepend(img);
  return h;
}

// ---------- Ambient colour ----------

/** Push a colour away from grey and up to a consistent brightness, so a muted
 *  average still reads as a glow and a garish one doesn't shout. */
function liftTint(r: number, g: number, b: number): [number, number, number] {
  const mean = (r + g + b) / 3;
  const sat = (v: number): number => Math.max(0, Math.min(255, mean + (v - mean) * 1.45));
  const [sr, sg, sb] = [sat(r), sat(g), sat(b)];
  const k = 195 / (Math.max(sr, sg, sb) || 1);
  return [Math.round(sr * k), Math.round(sg * k), Math.round(sb * k)];
}

/**
 * The artwork's dominant colour, read from a 16×16 downscale — weighted toward
 * saturated mid-tones, because the letterbox bars and blown-out skies that fill
 * a lot of a backdrop say nothing about what the image feels like.
 *
 * Resolves null whenever it can't be read. That includes the case where the
 * server sends no CORS headers and the canvas comes back tainted, which is why
 * the whole read sits in a try: the tint is decoration, and going without it is
 * a valid outcome rather than an error worth surfacing.
 */
function dominantColor(url: string): Promise<[number, number, number] | null> {
  return new Promise((resolve) => {
    const img = new Image();
    img.crossOrigin = "anonymous";
    img.addEventListener("error", () => resolve(null), { once: true });
    img.addEventListener(
      "load",
      () => {
        try {
          const n = 16;
          const canvas = el("canvas", { width: n, height: n }) as HTMLCanvasElement;
          const ctx = canvas.getContext("2d", { willReadFrequently: true });
          if (!ctx) return resolve(null);
          ctx.drawImage(img, 0, 0, n, n);
          const d = ctx.getImageData(0, 0, n, n).data;
          let r = 0, g = 0, b = 0, total = 0;
          for (let i = 0; i < d.length; i += 4) {
            const pr = d[i]!, pg = d[i + 1]!, pb = d[i + 2]!;
            const max = Math.max(pr, pg, pb), min = Math.min(pr, pg, pb);
            if (max < 24 || min > 235) continue; // black bars, blown highlights
            const weight = (max - min) / 255 + 0.06;
            r += pr * weight;
            g += pg * weight;
            b += pb * weight;
            total += weight;
          }
          if (!total) return resolve(null);
          resolve(liftTint(r / total, g / total, b / total));
        } catch {
          resolve(null); // tainted canvas — no CORS headers on the image
        }
      },
      { once: true }
    );
    img.src = url;
  });
}

/**
 * Light the area around a hero with the colour of its own artwork, the way the
 * Apple TV app bleeds a poster's colour into the page behind it. Sets `--tint`
 * on the element and flips `has-tint`; everything visual is in the stylesheet.
 * Silently does nothing when the colour can't be read.
 */
export function ambientTint(target: HTMLElement, url: string | null | undefined): void {
  if (!url) return;
  void dominantColor(url).then((rgb) => {
    if (!rgb || !target.isConnected) return;
    const [r, g, b] = rgb;
    target.style.setProperty("--tint", `rgb(${r}, ${g}, ${b})`);
    target.style.setProperty("--tint-soft", `rgba(${r}, ${g}, ${b}, 0.5)`);
    target.style.setProperty("--tint-faint", `rgba(${r}, ${g}, ${b}, 0.18)`);
    target.classList.add("has-tint");
  });
}

// ---------- Skeletons ----------
// Loading placeholders built from the *real* components' classes, so the box
// sizes match and swapping in the data doesn't move anything on screen.

function times<T>(n: number, make: () => T): T[] {
  return Array.from({ length: n }, make);
}

export function skeletonCards(count: number, opts: { wide?: boolean } = {}): HTMLElement[] {
  return times(count, () =>
    el("div", { class: `card skeleton${opts.wide ? " wide" : ""}` }, [
      el("div", { class: "card-poster sk-box" }),
      el("div", { class: "sk-line sk-title" }),
      el("div", { class: "sk-line sk-sub" }),
    ])
  );
}

/** Horizontally scrolling row of placeholder cards (Home sections). */
export function skeletonRow(count = 6, opts: { wide?: boolean } = {}): HTMLElement {
  return el("div", { class: "card-row" }, skeletonCards(count, opts));
}

/** Grid of placeholder cards (library, search, downloads). */
export function skeletonGrid(count = 18, opts: { wide?: boolean } = {}): HTMLElement {
  return el("div", { class: "card-grid" }, skeletonCards(count, opts));
}

/**
 * Placeholder rows for the list-shaped views. `rowClass`/`thumbClass` are the
 * view's own classes so the rows come out exactly the size of the real ones.
 */
export function skeletonRows(count: number, rowClass: string, thumbClass: string): HTMLElement {
  return el(
    "div",
    {},
    times(count, () =>
      el("div", { class: `${rowClass} skeleton` }, [
        el("div", { class: `${thumbClass} sk-box` }),
        el("div", { class: "sk-body" }, [
          el("div", { class: "sk-line sk-title" }),
          el("div", { class: "sk-line sk-sub" }),
        ]),
      ])
    )
  );
}

/** Placeholder for the detail hero (poster + title + overview + buttons). */
export function skeletonDetail(): HTMLElement {
  return el("div", { class: "detail-hero skeleton" }, [
    el("div", { class: "detail-inner" }, [
      el("div", { class: "detail-poster sk-box" }),
      el("div", { class: "detail-info" }, [
        el("div", { class: "sk-line sk-heading" }),
        el("div", { class: "sk-line sk-sub meta" }),
        el("div", { class: "sk-line sk-para" }),
        el("div", { class: "sk-line sk-para" }),
        el("div", { class: "sk-line sk-para short" }),
        el("div", { class: "sk-actions" }, [
          el("div", { class: "sk-btn" }),
          el("div", { class: "sk-btn" }),
        ]),
      ]),
    ]),
  ]);
}

// ---------- Empty and error states ----------

export interface EmptyStateOpts {
  icon?: IconName;
  title: string;
  body?: string;
  action?: { label: string; run: () => void };
  /** Error variant: red icon, for a failure rather than an absence. */
  error?: boolean;
}

/**
 * The standard "there's nothing here" block: an icon, a headline, a sentence of
 * explanation and — where there is one — the action that would fix it. Modelled
 * on the offline screen, which was the only state in the app that already told
 * the user what to do next rather than leaving a grey sentence in the middle of
 * an empty page.
 */
export function emptyState(opts: EmptyStateOpts): HTMLElement {
  const glyph = iconSvg(opts.icon ?? (opts.error ? "error" : "library"));
  return el("div", { class: `state${opts.error ? " state-error" : ""}` }, [
    el("div", { class: "state-icon", html: glyph }),
    el("h3", {}, [opts.title]),
    opts.body ? el("p", {}, [opts.body]) : null,
    opts.action
      ? el("button", { class: "btn primary", onClick: opts.action.run }, [opts.action.label])
      : null,
  ]);
}

/** The same block for a thrown error, with the message as the body text. */
export function errorState(title: string, e: any, retry?: () => void): HTMLElement {
  return emptyState({
    icon: "error",
    error: true,
    title,
    body: e?.message ?? String(e),
    action: retry ? { label: "Try again", run: retry } : undefined,
  });
}

// ---------- Modal dialogs ----------

export interface DialogAction {
  label: string;
  primary?: boolean;
  danger?: boolean;
  run?: () => void;
}

/**
 * A modal over the whole window. Escape and the scrim dismiss it (running
 * `onDismiss`, which is how the quit prompt distinguishes "cancel" from "quit
 * anyway"), Tab is kept inside it, and focus returns where it came from.
 *
 * Note this can't be used while the video is embedded — the X11 child window
 * covers every pixel of HTML above the player bar. It's for shell-level
 * questions (quitting, the shortcut sheet), which is where dialogs belong.
 */
export function openDialog(opts: {
  title: string;
  body?: (string | Node)[];
  actions?: DialogAction[];
  onDismiss?: () => void;
  wide?: boolean;
}): () => void {
  const opener = document.activeElement as HTMLElement | null;
  const card = el("div", {
    class: `dialog${opts.wide ? " wide" : ""}`,
    role: "dialog",
    "aria-modal": "true",
    "aria-label": opts.title,
  }, [el("h2", {}, [opts.title]), ...(opts.body ?? [])]);

  let closed = false;
  const close = (dismissed: boolean): void => {
    if (closed) return;
    closed = true;
    document.removeEventListener("keydown", onKey, true);
    scrim.remove();
    if (opener?.isConnected) opener.focus();
    if (dismissed) opts.onDismiss?.();
  };

  if (opts.actions?.length) {
    card.append(
      el(
        "div",
        { class: "dialog-actions" },
        opts.actions.map((a) =>
          el("button", {
            class: `btn${a.primary ? " primary" : ""}${a.danger ? " danger" : ""}`,
            onClick: () => {
              close(false);
              a.run?.();
            },
          }, [a.label])
        )
      )
    );
  }

  const scrim = el("div", {
    class: "dialog-scrim",
    onClick: (ev: MouseEvent) => {
      if (ev.target === scrim) close(true);
    },
  }, [card]);

  const onKey = (ev: KeyboardEvent): void => {
    if (ev.key === "Escape") {
      ev.preventDefault();
      ev.stopPropagation();
      close(true);
      return;
    }
    if (ev.key !== "Tab") return;
    const items = Array.from(
      card.querySelectorAll<HTMLElement>("button, [href], input, select, textarea, [tabindex]")
    ).filter((n) => !n.hasAttribute("disabled"));
    if (!items.length) return;
    const first = items[0]!;
    const last = items[items.length - 1]!;
    if (ev.shiftKey && document.activeElement === first) {
      ev.preventDefault();
      last.focus();
    } else if (!ev.shiftKey && document.activeElement === last) {
      ev.preventDefault();
      first.focus();
    }
  };
  document.addEventListener("keydown", onKey, true);

  document.body.append(scrim);
  // Focus lands on the safe choice, so Enter never destroys anything.
  const first = (card.querySelector(".btn.primary") ??
    card.querySelector("button")) as HTMLElement | null;
  first?.focus();
  return () => close(false);
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

// ---------- Recent searches ----------

const RECENT_KEY = "fellyjin.recent-searches";
const RECENT_MAX = 8;

export function recentSearches(): string[] {
  try {
    const raw = JSON.parse(localStorage.getItem(RECENT_KEY) ?? "[]");
    return Array.isArray(raw) ? raw.filter((t) => typeof t === "string").slice(0, RECENT_MAX) : [];
  } catch {
    return [];
  }
}

/** Record a term the user actually committed to (Enter, or picked from the
 *  list) — search-as-you-type would otherwise store every prefix. */
export function rememberSearch(term: string): void {
  const t = term.trim();
  if (!t) return;
  const next = [t, ...recentSearches().filter((x) => x.toLowerCase() !== t.toLowerCase())]
    .slice(0, RECENT_MAX);
  try {
    localStorage.setItem(RECENT_KEY, JSON.stringify(next));
  } catch {
    // Quota exceeded — history just won't persist.
  }
}

export function clearRecentSearches(): void {
  try {
    localStorage.removeItem(RECENT_KEY);
  } catch {
    /* nothing to do */
  }
}

/** Teardowns for the menu that's currently open (scroll/resize/click hooks). */
let menuCleanups: (() => void)[] = [];

/** Close any open dropdown menus. Installed globally by main.ts. */
export function closeMenus(): void {
  document.querySelectorAll(".menu").forEach((m) => m.remove());
  const fns = menuCleanups;
  menuCleanups = [];
  for (const fn of fns) fn();
}

/** Where a floating menu hangs from: an element's box, or a cursor position. */
interface AnchorRect {
  top: number;
  bottom: number;
  left: number;
}

function rectOf(anchor: HTMLElement | { x: number; y: number }): AnchorRect {
  if (anchor instanceof HTMLElement) {
    const r = anchor.getBoundingClientRect();
    return { top: r.top, bottom: r.bottom, left: r.left };
  }
  return { top: anchor.y, bottom: anchor.y, left: anchor.x };
}

/**
 * Place a fixed-position menu just under its anchor (or the mouse), flipping
 * and clamping so it stays on screen. Used for card menus, which sit inside
 * overflow-hidden posters and horizontally scrolling rows — an absolutely
 * positioned dropdown would be clipped by both.
 */
function positionFixed(menu: HTMLElement, a: AnchorRect): void {
  const pad = 8;
  menu.style.maxHeight = "";
  menu.style.top = `${a.bottom + 6}px`;
  menu.style.left = `${a.left}px`;
  const m = menu.getBoundingClientRect();
  if (m.right > window.innerWidth - pad) {
    menu.style.left = `${Math.max(pad, window.innerWidth - pad - m.width)}px`;
  }
  if (m.bottom > window.innerHeight - pad) {
    const above = a.top - 6 - m.height;
    if (above >= pad) menu.style.top = `${above}px`;
    else menu.style.maxHeight = `${window.innerHeight - a.bottom - 6 - pad}px`;
  }
}

/**
 * Keyboard handling for an open dropdown: Escape closes, Up/Down walk the
 * entries, Home/End jump to the ends, Tab is contained. Without it a menu is a
 * pointer-only control — it can be opened from the keyboard (the Menu key fires
 * `contextmenu`) and then not used.
 */
function wireMenuKeys(menu: HTMLElement, close: () => void): void {
  const entries = (): HTMLButtonElement[] =>
    Array.from(menu.querySelectorAll("button")) as HTMLButtonElement[];

  menu.addEventListener("keydown", (ev: KeyboardEvent) => {
    const items = entries();
    if (!items.length) return;
    const at = items.indexOf(document.activeElement as HTMLButtonElement);
    const focus = (i: number): void => {
      ev.preventDefault();
      items[(i + items.length) % items.length]?.focus();
    };
    switch (ev.key) {
      case "Escape":
        ev.preventDefault();
        ev.stopPropagation();
        close();
        break;
      case "ArrowDown":
        focus(at + 1);
        break;
      case "ArrowUp":
        focus(at - 1);
        break;
      case "Home":
        focus(0);
        break;
      case "End":
        focus(items.length - 1);
        break;
      case "Tab":
        // Tabbing out of a dropdown should dismiss it, not leave it hanging
        // over the page with focus somewhere behind it.
        close();
        break;
    }
  });
}

export function openMenu(
  anchor: HTMLElement | { x: number; y: number },
  build: (menu: HTMLElement) => void,
  opts: { fixed?: boolean } = {}
): void {
  closeMenus();
  // Where focus goes when the menu closes: back to whatever opened it.
  const opener = document.activeElement as HTMLElement | null;
  const menu = el("div", { class: "menu", role: "menu", tabindex: "-1" });
  build(menu);
  // Menus open inside clickable cards and rows — a click on an entry must not
  // also trigger the parent's "open details" handler.
  menu.addEventListener("click", (ev) => ev.stopPropagation());
  menu.addEventListener("contextmenu", (ev) => ev.stopPropagation());

  const cleanup: (() => void)[] = [];
  let closed = false;
  const close = (): void => {
    if (closed) return;
    closed = true;
    // Only pull focus back if it's still inside the menu we're removing —
    // otherwise a click elsewhere would be yanked back to the old anchor.
    const restore = menu.contains(document.activeElement);
    menu.remove();
    for (const fn of cleanup) fn();
    if (restore && opener?.isConnected) opener.focus();
  };
  menuCleanups.push(close);
  wireMenuKeys(menu, close);

  const floating = opts.fixed || !(anchor instanceof HTMLElement);
  if (floating) {
    menu.classList.add("menu-fixed");
    document.body.append(menu);
    // Remembered so nested submenu pages can re-measure after a rebuild.
    (menu as any).__anchor = anchor;
    positionFixed(menu, rectOf(anchor));
    // Scrolling would leave the menu floating away from its anchor.
    const onScroll = () => close();
    window.addEventListener("scroll", onScroll, true);
    window.addEventListener("resize", onScroll);
    cleanup.push(() => {
      window.removeEventListener("scroll", onScroll, true);
      window.removeEventListener("resize", onScroll);
    });
  } else {
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
  }

  // Focus the first entry so the arrow keys have somewhere to start. Invisible
  // to mouse users: programmatic focus doesn't paint a :focus-visible ring
  // unless the last input was a key.
  (menu.querySelector("button") as HTMLElement | null)?.focus({ preventScroll: true });

  setTimeout(() => {
    const closer = (ev: MouseEvent) => {
      if (!menu.contains(ev.target as Node)) {
        close();
        document.removeEventListener("click", closer, true);
      }
    };
    document.addEventListener("click", closer, true);
    cleanup.push(() => document.removeEventListener("click", closer, true));
  }, 0);
}

// ---------- Context menus ----------
// One dropdown shape reused everywhere (cards, episode rows, detail pages),
// modelled on the Jellyfin web client's "⋯" menu.

export interface MenuAction {
  label: string;
  /** Leading glyph. Entries without one keep the same text indent. */
  icon?: IconName;
  danger?: boolean;
  /** Renders a nested page inside the same dropdown (e.g. quality lists). */
  submenu?: { label: string; items: () => MenuAction[] };
  run?: () => void | Promise<void>;
}

/** Render a list of actions into an open menu, handling nested pages. */
export function fillMenu(
  menu: HTMLElement,
  title: string | null,
  actions: (MenuAction | null)[],
  back?: () => void
): void {
  menu.textContent = "";
  if (back) {
    menu.append(
      el("button", { class: "menu-back", onClick: back }, [
        icon("arrow-left"),
        el("span", { class: "menu-text" }, ["Back"]),
      ])
    );
  }
  if (title) menu.append(el("div", { class: "menu-label" }, [title]));
  // Only indent for a missing icon once some entry in the page has one —
  // a quality list, where none do, shouldn't carry a blank gutter.
  const anyIcons = actions.some((a) => a?.icon);
  for (const a of actions) {
    if (!a) continue;
    menu.append(
      el("button", {
        class: a.danger ? "danger" : null,
        role: "menuitem",
        onClick: () => {
          if (a.submenu) {
            const here = () => fillMenu(menu, title, actions, back);
            fillMenu(menu, a.submenu.label, a.submenu.items(), here);
            return;
          }
          menu.remove();
          void a.run?.();
        },
      }, [
        a.icon ? icon(a.icon) : anyIcons ? el("span", { class: "menu-gutter" }) : null,
        el("span", { class: "menu-text" }, [a.label]),
        a.submenu ? icon("chevron-right") : null,
      ])
    );
  }
  // A rebuilt page changes the menu's size; floating menus must re-measure.
  const anchor = (menu as any).__anchor as HTMLElement | { x: number; y: number } | undefined;
  if (anchor && menu.classList.contains("menu-fixed")) positionFixed(menu, rectOf(anchor));
  // Stepping into a submenu replaced every button, taking focus with it.
  if (menu.contains(document.activeElement) || document.activeElement === document.body) {
    (menu.querySelector("button") as HTMLElement | null)?.focus({ preventScroll: true });
  }
}

/** Open an action dropdown anchored to an element or a cursor position. */
export function openActionMenu(
  anchor: HTMLElement | { x: number; y: number },
  title: string | null,
  actions: (MenuAction | null)[],
  opts: { fixed?: boolean } = {}
): void {
  openMenu(anchor, (menu) => fillMenu(menu, title, actions), opts);
}

/**
 * Right-click context menu, opened at the pointer. Actions are built on
 * demand so they always reflect current state (watched, favorite, …).
 * The menu floats above everything, so it works from inside clipped posters
 * and horizontally scrolling card rows alike.
 */
export function attachContextMenu(
  target: HTMLElement,
  title: string | null,
  actions: () => (MenuAction | null)[]
): void {
  target.classList.add("has-ctx");
  target.addEventListener("contextmenu", (ev: MouseEvent) => {
    ev.preventDefault();
    // Nested targets (an episode row inside a season list) — innermost wins.
    ev.stopPropagation();
    const list = actions();
    if (list.some(Boolean)) openActionMenu({ x: ev.clientX, y: ev.clientY }, title, list);
  });
}

/**
 * "720p · 4.5 Mbps · ~1.2 GB" — quality plus its estimated on-disk size.
 *
 * Shows the size of what will actually be fetched, so a rung the direct-file
 * rule is going to override says so before it's clicked rather than after.
 */
export function downloadLabel(item: any, q: api.DownloadQuality): string {
  const eff = api.effectiveDownloadQuality(item, q);
  const est = api.estimateDownloadSize(item, eff);
  if (est == null) return q.label;
  const size = `${eff.original ? "" : "~"}${api.bytesToText(est)}`;
  return eff === q ? `${q.label} · ${size}` : `${q.label} · ${size} (original file)`;
}

/** Download entry for a context menu: a nested page of quality choices. */
export function downloadAction(item: any): MenuAction {
  const isSeries = item.Type === "Series";
  return {
    label: isSeries ? "Download series" : "Download",
    icon: "download",
    submenu: {
      label: isSeries ? "Download every episode as" : "Download as",
      items: () =>
        api.DOWNLOAD_QUALITIES.map((q) => ({
          label: isSeries ? q.label : downloadLabel(item, q),
          run: async () => {
            try {
              if (!isSeries) {
                await startDownload(item, q);
                return;
              }
              toast("Collecting episodes…");
              const { queued, skipped, seasons, cancelled } = await downloadSeries(item.Id, q);
              if (cancelled) return;
              toast(
                queued
                  ? `Queued ${queued} episode${queued === 1 ? "" : "s"} from ${seasons} season${seasons === 1 ? "" : "s"}` +
                      (skipped ? `, skipped ${skipped} already downloaded` : "")
                  : "Every episode is already downloaded or queued",
                queued ? "ok" : "info"
              );
            } catch (e: any) {
              toast(`Download failed: ${e.message ?? e}`, "error");
            }
          },
        })),
    },
  };
}

/**
 * Standard actions for a *server* item (movie, episode, series), shared by the
 * card grids, episode lists and the detail page. `onChanged` runs after
 * anything that alters state the caller is drawing (watched, favorite).
 */
export function itemActions(
  item: any,
  opts: { onChanged?: () => void; includeDetails?: boolean } = {}
): MenuAction[] {
  const isSeries = item.Type === "Series";
  const playable = !isSeries;
  const resumeTicks = item.UserData?.PlaybackPositionTicks ?? 0;
  const played = !!item.UserData?.Played;
  const favorite = !!item.UserData?.IsFavorite;
  const out: MenuAction[] = [];

  if (playable) {
    if (resumeTicks > 0) {
      out.push({
        label: `Resume (${api.ticksToText(item.RunTimeTicks - resumeTicks)} left)`,
        icon: "play",
        run: () => playItem(item, { resume: true }),
      });
      out.push({ label: "Play from start", run: () => playItem(item, { resume: false }) });
    } else {
      out.push({ label: "Play", icon: "play", run: () => playItem(item, { resume: false }) });
    }
  }

  out.push(downloadAction(item));

  out.push({
    label: played ? "Mark unwatched" : "Mark watched",
    icon: "check",
    run: async () => {
      try {
        await api.markPlayed(item.Id, !played);
        item.UserData = item.UserData ?? {};
        item.UserData.Played = !played;
        if (!played) item.UserData.PlaybackPositionTicks = 0;
        toast(played ? "Marked unwatched" : "Marked watched", "ok");
        opts.onChanged?.();
      } catch (e: any) {
        toast(e.message ?? String(e), "error");
      }
    },
  });

  out.push({
    label: favorite ? "Remove from favorites" : "Add to favorites",
    icon: favorite ? "star" : "star-outline",
    run: async () => {
      try {
        await api.setFavorite(item.Id, !favorite);
        item.UserData = item.UserData ?? {};
        item.UserData.IsFavorite = !favorite;
        toast(favorite ? "Removed from favorites" : "Added to favorites", "ok");
        opts.onChanged?.();
      } catch (e: any) {
        toast(e.message ?? String(e), "error");
      }
    },
  });

  if (item.Type === "Episode" && item.SeriesId) {
    out.push({
      label: "Go to series",
      icon: "episodes",
      run: () => {
        location.hash = `#/item/${item.SeriesId}`;
      },
    });
  }
  if (opts.includeDetails && item.Id) {
    out.push({
      label: "Show details",
      icon: "library",
      run: () => {
        location.hash = `#/item/${item.Id}`;
      },
    });
  }
  return out;
}

// ---------- Cards ----------

function progressPct(item: any): number | null {
  const ud = item.UserData;
  if (!ud?.PlaybackPositionTicks || !item.RunTimeTicks) return null;
  return Math.min(100, (ud.PlaybackPositionTicks / item.RunTimeTicks) * 100);
}

export function itemCard(
  item: any,
  opts: {
    wide?: boolean;
    /**
     * Ran after a menu action changed the item's state, with the card that
     * replaced this one. Views whose contents depend on that state use it to
     * stay honest — un-starring something in Favorites has to remove it from
     * the grid, not leave a card the query would no longer return.
     */
    onChanged?: (item: any, card: HTMLElement) => void;
  } = {}
): HTMLElement {
  const wide = opts.wide ?? (item.Type === "Episode");
  let img = api.imageUrl(item, "Primary", wide ? 500 : 320);
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

  // Redrawn in place after a menu action changes watched/favorite state.
  const refresh = (): void => {
    const next = itemCard(item, opts);
    card.replaceWith(next);
    opts.onChanged?.(item, next);
  };

  // "24m left" on anything part-watched. Infuse and the Apple TV app both put
  // the remaining time on the card, and it's the one number that decides
  // whether you start something now — a bare progress bar only says "some".
  const left =
    pct != null && pct > 1 && pct < 98
      ? api.ticksToText(item.RunTimeTicks - item.UserData.PlaybackPositionTicks)
      : "";

  const poster = el("div", { class: "card-poster" }, [
    art(img, title, { hash: api.imageHash(item, "Primary") }),
    // A scrim under the bottom furniture: the strip and the time pill have to
    // stay legible over a poster that happens to be white down there.
    pct != null && pct > 1 ? el("div", { class: "card-scrim" }) : null,
    left ? el("div", { class: "time-left" }, [`${left} left`]) : null,
    pct != null && pct > 1
      ? el("div", { class: "progress-strip" }, [el("div", { style: `width:${pct}%` })])
      : null,
    played ? el("div", { class: "badge played" }, [icon("check")]) : null,
    playable
      ? el("div", { class: "play-overlay" }, [
          el("button", {
            class: "pbtn",
            title: "Play",
            "aria-label": `Play ${title}`,
            onClick: (ev: MouseEvent) => {
              ev.stopPropagation();
              playItem(item, { resume: true });
            },
          }, [icon("play", 20)]),
        ])
      : null,
  ]);

  // A card behaves like a button, so it has to say so and be reachable by Tab.
  // It can't *be* a <button>: it contains one (the play overlay), which nesting
  // rules forbid.
  const card = el(
    "div",
    {
      class: `card${wide ? " wide" : ""}`,
      role: "button",
      tabindex: "0",
      "aria-label": sub ? `${title} — ${sub}` : title,
      // Read by prefetch.ts to warm the detail page while the card sits under
      // focus or the pointer, before Enter or a click ever asks for it.
      "data-item-id": item.Id,
      onClick: () => {
        location.hash = `#/item/${item.Id}`;
      },
      onKeydown: (ev: KeyboardEvent) => {
        // Space scrolls the page by default; a card that looks like a button
        // has to answer both keys a button would.
        if (ev.key !== "Enter" && ev.key !== " ") return;
        if (ev.target !== ev.currentTarget) return; // the overlay button's own key
        ev.preventDefault();
        location.hash = `#/item/${item.Id}`;
      },
    },
    [poster, el("div", { class: "card-title" }, [title]), el("div", { class: "card-sub" }, [sub])]
  );
  if (item.Type !== "TvChannel") {
    attachContextMenu(card, item.Name ?? null, () =>
      itemActions(item, { onChanged: refresh, includeDetails: true })
    );
  }
  return card;
}

const ROW_CHEVRON = (dir: "left" | "right"): string =>
  `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="${
    dir === "left" ? "M15 18l-6-6 6-6" : "M9 6l6 6-6 6"
  }"/></svg>`;

/**
 * Wrap a horizontally scrolling row with affordances: arrow buttons on hover
 * and a fade at whichever edge still has content. A bare `overflow-x` row
 * gives no hint that anything is off screen, so the cards past the right edge
 * may as well not exist.
 */
export function scrollRow(row: HTMLElement): HTMLElement {
  const prev = el("button", { class: "row-nav prev", "aria-label": "Scroll left", html: ROW_CHEVRON("left") });
  const next = el("button", { class: "row-nav next", "aria-label": "Scroll right", html: ROW_CHEVRON("right") });
  const wrap = el("div", { class: "row-wrap" }, [row, prev, next]);

  const update = (): void => {
    const max = row.scrollWidth - row.clientWidth;
    // The row's `scroll-padding` puts the resting position at exactly 0, so
    // this only has to absorb fractional layout at odd zoom levels — anything
    // larger would claim there's content to the left of an unscrolled row.
    const canPrev = row.scrollLeft > 2;
    const canNext = max > 2 && row.scrollLeft < max - 2;
    wrap.classList.toggle("can-prev", canPrev);
    wrap.classList.toggle("can-next", canNext);
    // An arrow for a direction that can't move isn't just invisible: it must
    // also drop out of the tab order and stop swallowing the click meant for
    // the card underneath it.
    prev.disabled = !canPrev;
    next.disabled = !canNext;
  };
  const page = (dir: number): void =>
    row.scrollBy({ left: dir * row.clientWidth * 0.8, behavior: "smooth" });

  prev.addEventListener("click", () => page(-1));
  next.addEventListener("click", () => page(1));
  row.addEventListener("scroll", update, { passive: true });
  // Widths aren't known until the row has been laid out, and they change when
  // the window (or sidebar) resizes.
  if (typeof ResizeObserver !== "undefined") new ResizeObserver(update).observe(row);
  setTimeout(update, 0);
  return wrap;
}

export function cardRow(items: any[], opts: { wide?: boolean } = {}): HTMLElement {
  return scrollRow(el("div", { class: "card-row" }, items.map((i) => itemCard(i, opts))));
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
