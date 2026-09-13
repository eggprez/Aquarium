/**
 * Display-paced scrolling.
 *
 * A wheel notch is a single discrete event carrying a fixed number of pixels.
 * Left to the browser it becomes one jump per notch, so the motion you see is
 * paced by how fast the wheel is turning — which is nothing like the refresh
 * rate of the screen. On a 120Hz panel that's the same handful of jumps a 60Hz
 * panel gets, with the extra frames spent showing a still image.
 *
 * So the notch is treated as a *destination* instead: the wheel moves a target,
 * and a rAF loop eases the real scroll position toward it, painting a new
 * position on every frame the display can show. The easing is expressed per
 * millisecond rather than per frame, so 120Hz and 60Hz take the same amount of
 * time to arrive — the faster display just draws more steps along the way.
 *
 * Trackpads are left alone. Their events already arrive as a fine-grained
 * stream at the gesture's own rate, and smoothing an already-smooth input only
 * adds a lag between the fingers and the page.
 */

/** Fraction of the remaining distance covered per millisecond. Tuned so a
 *  single notch resolves in roughly 180ms: long enough to read as motion rather
 *  than a jump, short enough that a fast flick doesn't feel like it's swimming. */
const EASE_PER_MS = 0.018;
/** Below this the animation has arrived; chasing the last fraction of a pixel
 *  keeps the loop alive forever for no visible benefit. */
const SETTLE_PX = 0.5;
/** Wheel deltas smaller than this look like a trackpad or a high-resolution
 *  wheel, both of which already deliver a smooth stream of their own. */
const MIN_WHEEL_PX = 18;

function reducedMotion(): boolean {
  return window.matchMedia?.("(prefers-reduced-motion: reduce)").matches ?? false;
}

/** A wheel event's vertical intent in pixels, whatever units it arrived in. */
function deltaPixels(ev: WheelEvent, viewportHeight: number): number {
  switch (ev.deltaMode) {
    case 1: // lines
      return ev.deltaY * 16;
    case 2: // pages
      return ev.deltaY * viewportHeight;
    default:
      return ev.deltaY;
  }
}

/**
 * Is the wheel over something that scrolls for itself? An open dropdown menu
 * and the Live TV guide grid handle their own vertical overflow inside
 * `#content`, and stealing the event from them would make the page move
 * instead of the thing under the pointer.
 *
 * This used to walk every ancestor up to `container` calling
 * `getComputedStyle` and reading `scrollHeight`/`clientHeight` on each one —
 * both force a synchronous layout, so a fast wheel gesture (spinning a mouse
 * wheel back and forth, which fires a wheel event every few milliseconds) was
 * forcing a full layout pass per ancestor per event on top of the easing loop's
 * own per-frame reads, which is what made scrolling the card-heavy Home page
 * stutter and, on a big enough page, lock up the tab. `closest()` against the
 * known selectors costs nothing layout-wise — it's the same engine as CSS
 * selector matching — and only the one match it finds, if any, ever touches
 * `scrollHeight`.
 */
const NESTED_SCROLLERS = ".menu, .guide-scroll";

function overNestedScroller(target: EventTarget | null, container: HTMLElement): boolean {
  const node = (target as HTMLElement | null)?.closest?.<HTMLElement>(NESTED_SCROLLERS);
  if (!node || !container.contains(node)) return false;
  return node.scrollHeight > node.clientHeight + 1;
}

/**
 * Take over wheel scrolling for `container`. Returns a teardown; the app never
 * calls it (the container lives as long as the window does), but a listener on
 * a long-lived element that can't be removed is the kind of thing that makes
 * the next feature harder.
 */
export function wireSmoothScroll(container: HTMLElement): () => void {
  let target = container.scrollTop;
  let raf = 0;
  let lastFrame = 0;
  /** The scroll position we last wrote, so a scroll from anywhere else (a
   *  restored position, a card scrolled into view) can be told apart from our
   *  own and takes over the target. */
  let ours = -1;

  const maxScroll = (): number => Math.max(0, container.scrollHeight - container.clientHeight);

  const stop = (): void => {
    if (raf) cancelAnimationFrame(raf);
    raf = 0;
    ours = -1;
    // Handed back to CSS: `scroll-behavior: smooth` is still what a
    // programmatic jump (Back to a remembered position, spatial navigation)
    // should use.
    container.style.scrollBehavior = "";
  };

  const frame = (now: number): void => {
    const dt = Math.min(64, now - lastFrame || 16);
    lastFrame = now;
    // The page can grow underneath the animation — infinite scroll appends a
    // row mid-flick — so the ceiling is re-read every frame rather than closed
    // over at the start.
    target = Math.max(0, Math.min(target, maxScroll()));
    const current = container.scrollTop;
    const remaining = target - current;
    if (Math.abs(remaining) < SETTLE_PX) {
      container.scrollTop = target;
      stop();
      return;
    }
    // Framerate-independent exponential ease: the same proportion of the
    // remaining distance per unit of *time*, not per frame.
    const step = remaining * (1 - Math.pow(1 - EASE_PER_MS, dt));
    container.scrollTop = current + step;
    const applied = container.scrollTop;
    // Scroll offsets are quantised — to device pixels, and to whole pixels in
    // some engines — so a target that falls between two representable
    // positions can never be reached exactly. Without this the loop keeps
    // asking for a frame forever, a few tenths of a pixel short of arriving,
    // and a laptop pays for it in battery for the rest of the session.
    if (Math.abs(applied - current) < 0.05) {
      // One last write to close whatever gap is left. It lands when the target
      // is representable and is a no-op when it isn't, which is exactly the
      // case that brought us here.
      container.scrollTop = target;
      stop();
      return;
    }
    ours = applied;
    raf = requestAnimationFrame(frame);
  };

  const onWheel = (ev: WheelEvent): void => {
    // Ctrl+wheel is zoom, and a horizontal-intent event belongs to whatever
    // handles sideways scrolling.
    if (ev.ctrlKey || ev.altKey || ev.defaultPrevented) return;
    if (Math.abs(ev.deltaX) > Math.abs(ev.deltaY)) return;
    if (reducedMotion()) return;
    const delta = deltaPixels(ev, container.clientHeight);
    if (Math.abs(delta) < MIN_WHEEL_PX) return;
    if (overNestedScroller(ev.target, container)) return;

    const limit = maxScroll();
    if (limit <= 0) return;
    const from = raf && Math.abs(container.scrollTop - ours) < 1 ? target : container.scrollTop;
    const next = Math.max(0, Math.min(limit, from + delta));
    // Already against the end: let the event through so the gesture can do
    // whatever it would normally do (overscroll, or nothing).
    if (next === container.scrollTop && next === from) return;

    ev.preventDefault();
    target = next;
    if (!raf) {
      // CSS smooth scrolling would interpolate every one of our per-frame
      // writes a second time, turning the animation into a lagging chase.
      container.style.scrollBehavior = "auto";
      lastFrame = performance.now();
      raf = requestAnimationFrame(frame);
    }
  };

  // A jump from anywhere else (Back, spatial navigation, a dialog closing)
  // cancels the animation rather than fighting it.
  const onScroll = (): void => {
    if (raf && Math.abs(container.scrollTop - ours) > 2) stop();
  };

  container.addEventListener("wheel", onWheel, { passive: false });
  container.addEventListener("scroll", onScroll, { passive: true });
  return () => {
    container.removeEventListener("wheel", onWheel);
    container.removeEventListener("scroll", onScroll);
    stop();
  };
}
