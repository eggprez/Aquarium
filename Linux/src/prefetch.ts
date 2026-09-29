// Warms the item-detail cache while a card sits under keyboard/spatial focus
// or the pointer, so pressing Enter — or clicking, for a mouse user — usually
// finds the page already in cache and paints instantly instead of waiting on
// a round trip. This is the same idea as a remote-control UI (Apple TV,
// Infuse) prefetching whatever's currently highlighted before you commit to it.
//
// Debounced: arrow-keying quickly across a row would otherwise fire one
// request per card passed over. A card has to hold focus (or the pointer)
// for `DELAY_MS` before anything is fetched, and moving off it before then
// cancels the request outright.
import { fetchItemData } from "./views/item";

const DELAY_MS = 220;

let timer = 0;
let pendingId: string | null = null;

function schedule(id: string): void {
  if (pendingId === id) return;
  pendingId = id;
  if (timer) window.clearTimeout(timer);
  timer = window.setTimeout(() => {
    timer = 0;
    if (pendingId !== id) return;
    void fetchItemData(id).catch(() => {
      // A failed prefetch costs nothing — the page's own load will surface
      // the error normally if it's still wrong by the time it's opened.
    });
  }, DELAY_MS);
}

function cancel(): void {
  pendingId = null;
  if (timer) {
    window.clearTimeout(timer);
    timer = 0;
  }
}

function cardElFrom(target: EventTarget | null): HTMLElement | null {
  return (target as HTMLElement | null)?.closest?.<HTMLElement>("[data-item-id]") ?? null;
}

/**
 * True when focus or the pointer has genuinely left `card` — as opposed to
 * moving to something inside it, like the play-overlay button — so a stray
 * `pointerout`/`focusout` on the way to a child element doesn't cancel a
 * prefetch that's still wanted.
 */
function left(card: HTMLElement, relatedTarget: EventTarget | null): boolean {
  return cardElFrom(relatedTarget) !== card;
}

export function wirePrefetch(): void {
  document.addEventListener("focusin", (ev) => {
    const card = cardElFrom(ev.target);
    if (card?.dataset.itemId) schedule(card.dataset.itemId);
  });
  document.addEventListener("focusout", (ev: FocusEvent) => {
    const card = cardElFrom(ev.target);
    if (card && left(card, ev.relatedTarget) && document.activeElement !== card) cancel();
  });

  // Hover covers mouse users the same way focus covers keyboard/remote nav.
  // `pointerover`/`pointerout` (rather than `mouseenter`/`mouseleave`, which
  // don't bubble) so one delegated pair on `document` covers every card
  // without a listener per row.
  document.addEventListener("pointerover", (ev) => {
    const card = cardElFrom(ev.target);
    if (card?.dataset.itemId) schedule(card.dataset.itemId);
  });
  document.addEventListener("pointerout", (ev: PointerEvent) => {
    const card = cardElFrom(ev.target);
    // A card the keyboard is still sitting on stays warm even after the
    // pointer moves off it.
    if (card && left(card, ev.relatedTarget) && document.activeElement !== card) cancel();
  });
}
