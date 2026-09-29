// Arrow-key navigation between tiles.
//
// Tab order is DOM order, which in a media browser means walking every card in
// a row before reaching the row below, and stepping through each card's play
// button on the way. Living-room interfaces don't work that way: the arrows move
// to whatever is physically in that direction, which is both faster and the only
// model that makes sense when the thing you're looking at is a grid.
//
// The takeover is deliberately narrow — the arrows only mean "move" while a tile
// already has focus. Anywhere else they scroll the page, which is what a desktop
// user expects them to do.

/** Everything the arrows can land on. All of these are focusable already. */
const TILES = ".card, .person-card, .ep-row, .channel-row, .guide-ch, .guide-prog";

type Dir = "up" | "down" | "left" | "right";

interface Box {
  el: HTMLElement;
  cx: number;
  cy: number;
  top: number;
  bottom: number;
  left: number;
  right: number;
}

function boxOf(el: HTMLElement): Box | null {
  const r = el.getBoundingClientRect();
  // Zero-sized means display:none or a collapsed ancestor — not a target.
  if (r.width <= 0 || r.height <= 0) return null;
  return {
    el,
    cx: r.left + r.width / 2,
    cy: r.top + r.height / 2,
    top: r.top,
    bottom: r.bottom,
    left: r.left,
    right: r.right,
  };
}

/**
 * The nearest tile in `dir`. Tiles that share a band with the current one (the
 * rest of its row, going sideways; the column above or below, going up and
 * down) always win over anything diagonal — otherwise the end of a short row
 * throws focus into whatever section happens to be closest on the diagonal.
 */
function pick(from: Box, boxes: Box[], dir: Dir): HTMLElement | null {
  const horizontal = dir === "left" || dir === "right";
  let best: HTMLElement | null = null;
  let bestScore = Infinity;
  let bestAligned = false;

  for (const b of boxes) {
    if (b.el === from.el) continue;
    // Must actually be in the direction asked for.
    const main = horizontal ? b.cx - from.cx : b.cy - from.cy;
    const forward = dir === "right" || dir === "down" ? main > 1 : main < -1;
    if (!forward) continue;

    const aligned = horizontal
      ? b.top < from.bottom - 1 && b.bottom > from.top + 1
      : b.left < from.right - 1 && b.right > from.left + 1;
    const mainDist = Math.abs(main);
    const crossDist = horizontal ? Math.abs(b.cy - from.cy) : Math.abs(b.cx - from.cx);
    // Cross-axis drift is penalised so a step never wanders sideways when
    // something straight ahead would do.
    const score = mainDist + crossDist * 3;

    if (aligned && !bestAligned) {
      best = b.el;
      bestScore = score;
      bestAligned = true;
      continue;
    }
    if (aligned === bestAligned && score < bestScore) {
      best = b.el;
      bestScore = score;
    }
  }
  // Sideways never leaves the row. At the end of a shelf the diagonal fallback
  // would find *something* — a card in the section above, once the row has
  // scrolled far enough that its own cards are all to the left — and throwing
  // focus into another section on a Right press is indefensible. Down is the
  // key that changes sections.
  if (horizontal && !bestAligned) return null;
  return best;
}

function move(current: HTMLElement, dir: Dir): boolean {
  const from = boxOf(current);
  if (!from) return false;
  const boxes: Box[] = [];
  for (const el of Array.from(document.querySelectorAll<HTMLElement>(TILES))) {
    const b = boxOf(el);
    if (b) boxes.push(b);
  }
  const next = pick(from, boxes, dir);
  if (!next) return false;
  // Scrolling is left to the browser: `nearest` moves the row (or the page)
  // by the least amount that brings the tile fully into view, which is what
  // keeps a horizontal row from lurching a full page per keypress.
  next.focus({ preventScroll: true });
  next.scrollIntoView({ block: "nearest", inline: "nearest", behavior: "smooth" });
  return true;
}

const DIRS: Record<string, Dir> = {
  ArrowUp: "up",
  ArrowDown: "down",
  ArrowLeft: "left",
  ArrowRight: "right",
};

/**
 * Install the handler. `isBusy` reports the states where the arrows belong to
 * something else — playback (seek and volume) and open menus, which do their
 * own arrow handling and would otherwise move the page behind them.
 */
export function wireSpatialNav(isBusy: () => boolean): void {
  document.addEventListener("keydown", (ev: KeyboardEvent) => {
    const dir = DIRS[ev.key];
    if (!dir || ev.altKey || ev.ctrlKey || ev.metaKey || ev.shiftKey) return;
    if (isBusy()) return;
    const active = document.activeElement as HTMLElement | null;
    // Only take over when a tile is already focused. From anywhere else the
    // arrows keep their usual meaning.
    if (!active || !active.matches(TILES)) return;
    if (move(active, dir)) ev.preventDefault();
  });
}
