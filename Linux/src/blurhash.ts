/**
 * BlurHash decoding.
 *
 * Jellyfin ships a BlurHash next to every image tag it knows about — a ~30 byte
 * string holding a handful of DCT coefficients. Decoded, it's a blurred version
 * of the artwork: not a grey box, not a spinner, but the poster's own colours in
 * roughly the right places, available before a single byte of the real image has
 * been asked for.
 *
 * Everything here runs on the main thread, so it decodes to a deliberately tiny
 * grid (the result is stretched over the card by the browser, and a blur has no
 * detail to lose). A 32×32 decode of a 6×4 hash is about 25k inner iterations —
 * fast enough that a screenful of cards is not worth deferring to a worker.
 */

const DIGITS = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz#$%*+,-.:;=?@[]^_{|}~";

/** Decoded data URLs, keyed by hash. Rows re-render constantly (a menu action
 *  replaces a card, going Back rebuilds a grid) and the same poster must not be
 *  decoded twice. */
const cache = new Map<string, string | null>();
/** Unbounded growth would be a leak on a long browse; a library page is ~100
 *  cards, so this holds several pages' worth and then starts over. */
const CACHE_LIMIT = 400;

function decode83(str: string, start: number, end: number): number {
  let value = 0;
  for (let i = start; i < end; i++) {
    const digit = DIGITS.indexOf(str[i]!);
    if (digit < 0) return NaN;
    value = value * 83 + digit;
  }
  return value;
}

/** sRGB byte to linear light. The DCT is defined on linear values; blending in
 *  sRGB directly is what makes naive implementations come out muddy. */
function toLinear(value: number): number {
  const v = value / 255;
  return v <= 0.04045 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
}

function toSrgb(value: number): number {
  const v = Math.max(0, Math.min(1, value));
  const s = v <= 0.0031308 ? v * 12.92 : 1.055 * Math.pow(v, 1 / 2.4) - 0.055;
  return Math.round(s * 255);
}

function signPow(value: number, exp: number): number {
  return Math.sign(value) * Math.pow(Math.abs(value), exp);
}

/**
 * The hash as a data URL, or null if it isn't a hash we can read. Cached, so
 * callers can ask on every render.
 */
export function blurhashUrl(hash: string | null | undefined, size = 32): string | null {
  if (!hash || hash.length < 6) return null;
  const key = `${size}:${hash}`;
  const hit = cache.get(key);
  if (hit !== undefined) return hit;

  const url = render(hash, size);
  if (cache.size >= CACHE_LIMIT) cache.clear();
  cache.set(key, url);
  return url;
}

function render(hash: string, size: number): string | null {
  const sizeFlag = decode83(hash, 0, 1);
  if (!isFinite(sizeFlag)) return null;
  const numX = (sizeFlag % 9) + 1;
  const numY = Math.floor(sizeFlag / 9) + 1;
  // The length is fully determined by the component counts; anything else means
  // a truncated or corrupt hash, and decoding it would read past the end.
  if (hash.length !== 4 + 2 * numX * numY) return null;

  const quantMax = decode83(hash, 1, 2);
  if (!isFinite(quantMax)) return null;
  const maxValue = (quantMax + 1) / 166;

  const colors: [number, number, number][] = new Array(numX * numY);
  const dc = decode83(hash, 2, 6);
  if (!isFinite(dc)) return null;
  colors[0] = [toLinear(dc >> 16), toLinear((dc >> 8) & 255), toLinear(dc & 255)];
  for (let i = 1; i < numX * numY; i++) {
    const ac = decode83(hash, 4 + i * 2, 6 + i * 2);
    if (!isFinite(ac)) return null;
    colors[i] = [
      signPow((Math.floor(ac / (19 * 19)) - 9) / 9, 2) * maxValue,
      signPow(((Math.floor(ac / 19) % 19) - 9) / 9, 2) * maxValue,
      signPow(((ac % 19) - 9) / 9, 2) * maxValue,
    ];
  }

  const canvas = document.createElement("canvas");
  canvas.width = size;
  canvas.height = size;
  const ctx = canvas.getContext("2d");
  if (!ctx) return null;
  const image = ctx.createImageData(size, size);
  const px = image.data;

  // The cosine terms depend only on the axis, so they're computed once per row
  // and column rather than once per (pixel × component).
  const cosX = new Float32Array(size * numX);
  for (let x = 0; x < size; x++) {
    for (let i = 0; i < numX; i++) cosX[x * numX + i] = Math.cos((Math.PI * x * i) / size);
  }
  const cosY = new Float32Array(size * numY);
  for (let y = 0; y < size; y++) {
    for (let j = 0; j < numY; j++) cosY[y * numY + j] = Math.cos((Math.PI * y * j) / size);
  }

  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      let r = 0, g = 0, b = 0;
      for (let j = 0; j < numY; j++) {
        const cy = cosY[y * numY + j]!;
        for (let i = 0; i < numX; i++) {
          const basis = cosX[x * numX + i]! * cy;
          const c = colors[i + j * numX]!;
          r += c[0] * basis;
          g += c[1] * basis;
          b += c[2] * basis;
        }
      }
      const o = 4 * (x + y * size);
      px[o] = toSrgb(r);
      px[o + 1] = toSrgb(g);
      px[o + 2] = toSrgb(b);
      px[o + 3] = 255;
    }
  }
  ctx.putImageData(image, 0, 0);
  try {
    return canvas.toDataURL("image/png");
  } catch {
    return null;
  }
}
