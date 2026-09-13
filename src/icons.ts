/**
 * The app's icons, in one place.
 *
 * The UI used to draw icons two ways: hand-cut inline SVG for the sidebar, the
 * player bar and the empty states, and Unicode characters (▶ ⬇ ✓ ★ ▸ ←) for
 * everything else. Inter ships none of those codepoints, so on a stock Linux
 * desktop they fell through to whatever symbol font was installed — a different
 * weight, a different optical size, and a baseline that didn't line up with the
 * label beside it. Every one of them now comes from here instead.
 *
 * All paths are drawn in a 24×24 box in the stroke style the nav already used:
 * 1.8px, round caps and joins. The two that read better solid at 16px — the
 * play triangle and the filled star — say so themselves.
 */

const STROKE = 'fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"';
const SOLID = 'fill="currentColor" stroke="currentColor" stroke-width="1.1" stroke-linejoin="round"';

const STAR_PATH = "m12 3.7 2.55 5.17 5.7.83-4.13 4.02.98 5.68L12 16.72l-5.1 2.68.98-5.68L3.75 9.7l5.7-.83z";

// Deliberately un-annotated: the inferred key literals are what make
// `IconName` a closed union, so a typo in a call site is a type error.
const PATHS = {
  // ---- Actions ----
  play: `<path ${SOLID} d="M8 5.9a.8.8 0 0 1 1.22-.68l9.1 5.4a.8.8 0 0 1 0 1.38l-9.1 5.4A.8.8 0 0 1 8 16.72z"/>`,
  download: `<path ${STROKE} d="M12 3.5v10m0 0 3.8-3.8M12 13.5 8.2 9.7"/><path ${STROKE} d="M4.5 16.5v2a2 2 0 0 0 2 2h11a2 2 0 0 0 2-2v-2"/>`,
  check: `<path ${STROKE} stroke-width="2.2" d="m5 12.4 4.8 4.8L19 7"/>`,
  star: `<path ${SOLID} d="${STAR_PATH}"/>`,
  "star-outline": `<path ${STROKE} d="${STAR_PATH}"/>`,
  close: `<path ${STROKE} stroke-width="2.1" d="M6.6 6.6l10.8 10.8M17.4 6.6 6.6 17.4"/>`,
  trash: `<path ${STROKE} d="M4 6.8h16M9.2 6.8V5.4A1.4 1.4 0 0 1 10.6 4h2.8a1.4 1.4 0 0 1 1.4 1.4v1.4"/><path ${STROKE} d="m6.6 6.8.85 11.4A2 2 0 0 0 9.45 20h5.1a2 2 0 0 0 2-1.8l.85-11.4"/><path ${STROKE} d="M10.4 10.6v5.6m3.2-5.6v5.6"/>`,
  shuffle: `<path ${STROKE} d="M4 6.8h2.1a4.5 4.5 0 0 1 3.7 1.95l4.4 6.5a4.5 4.5 0 0 0 3.7 1.95H20"/><path ${STROKE} d="m17.2 14.4 2.8 2.8-2.8 2.8"/><path ${STROKE} d="M4 17.2h2.1a4.5 4.5 0 0 0 3.7-1.95l.5-.75m3.4-5 .5-.75a4.5 4.5 0 0 1 3.7-1.95H20"/><path ${STROKE} d="M17.2 4 20 6.8l-2.8 2.8"/>`,

  // ---- Direction ----
  "chevron-left": `<path ${STROKE} stroke-width="2.2" d="m15 18-6-6 6-6"/>`,
  "chevron-right": `<path ${STROKE} stroke-width="2.2" d="m9 6 6 6-6 6"/>`,
  "chevron-down": `<path ${STROKE} stroke-width="2.2" d="m6 9.5 6 6 6-6"/>`,
  "arrow-left": `<path ${STROKE} d="M19.5 12H5m0 0 6.2-6.2M5 12l6.2 6.2"/>`,

  // ---- Empty and error states (larger, and drawn a touch lighter) ----
  search: `<circle ${STROKE} stroke-width="1.6" cx="10.5" cy="10.5" r="6.5"/><path ${STROKE} stroke-width="1.6" d="m15.5 15.5 4.5 4.5"/>`,
  library: `<rect ${STROKE} stroke-width="1.6" x="3" y="4" width="5" height="16" rx="1.5"/><rect ${STROKE} stroke-width="1.6" x="10" y="4" width="5" height="16" rx="1.5"/><path ${STROKE} stroke-width="1.6" d="m17.5 5.5 3.5 1-3 14-3.5-1z"/>`,
  tv: `<rect ${STROKE} stroke-width="1.6" x="3" y="7" width="18" height="13" rx="2"/><path ${STROKE} stroke-width="1.6" d="m8 3 4 4 4-4"/>`,
  episodes: `<rect ${STROKE} stroke-width="1.6" x="3" y="4.5" width="13" height="9" rx="2"/><path ${STROKE} stroke-width="1.6" d="M20 8v9a2 2 0 0 1-2 2H6"/>`,
  people: `<circle ${STROKE} stroke-width="1.6" cx="12" cy="8.5" r="3.8"/><path ${STROKE} stroke-width="1.6" d="M4.8 20a7.2 7.2 0 0 1 14.4 0"/>`,
  error: `<circle ${STROKE} stroke-width="1.6" cx="12" cy="12" r="8.5"/><path ${STROKE} stroke-width="1.6" d="M12 7.5v5.5M12 16.2v.3"/>`,
  disk: `<path ${STROKE} stroke-width="1.6" d="M4 8.5c0-1.9 3.6-3.5 8-3.5s8 1.6 8 3.5-3.6 3.5-8 3.5-8-1.6-8-3.5z"/><path ${STROKE} stroke-width="1.6" d="M4 8.5v7c0 1.9 3.6 3.5 8 3.5s8-1.6 8-3.5v-7"/>`,
};

export type IconName = keyof typeof PATHS;

/** The raw `<svg>` markup, for the few places that need a string. */
export function iconSvg(name: IconName): string {
  return `<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false">${PATHS[name] ?? PATHS.error}</svg>`;
}

/**
 * An icon sized to the text it sits beside. Pass `px` for the handful of places
 * that aren't next to a label — poster overlays, badges — where the surrounding
 * font size is the wrong thing to inherit.
 */
export function icon(name: IconName, px?: number): HTMLElement {
  const span = document.createElement("span");
  span.className = "ico";
  span.setAttribute("aria-hidden", "true");
  if (px != null) span.style.cssText = `width:${px}px;height:${px}px`;
  span.innerHTML = iconSvg(name);
  return span;
}
