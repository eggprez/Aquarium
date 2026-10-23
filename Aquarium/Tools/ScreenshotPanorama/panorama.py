"""App Store screenshots as one continuous picture per platform.

Each set is drawn on one wide canvas — the sea background, the devices, the
headlines — and then cut into the store's own screenshot size, so a person
swiping through the listing sees a single scene that runs from card to card.
Devices that cross a cut are what make the cards read as one picture.

    python3 panorama.py [iphone|watch|duo|tv ...]

Captures come from `captures/` (see README.md for how they were taken) and
the cut screenshots land in `../../AppStore/Screenshots-Panorama/<set>/`,
with `strip.png` (the whole canvas) and `preview.png` (the cards with the
store's gaps between them) beside them for checking the seams.
"""

import math
import os
import random
import sys

from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
CAPTURES = os.path.join(HERE, "captures")
OUT = os.path.normpath(os.path.join(HERE, "..", "..", "AppStore", "Screenshots-Panorama"))
FONT = "/System/Library/Fonts/SFNS.ttf"

WHITE = (255, 255, 255)
ACCENT = (196, 176, 255)        # the lavender of "rium"
PILL = (255, 255, 255, 34)
PILL_EDGE = (255, 255, 255, 70)


def font(size, weight="Bold"):
    f = ImageFont.truetype(FONT, size)
    f.set_variation_by_name(weight)
    return f


def capture(name):
    return Image.open(os.path.join(CAPTURES, name)).convert("RGBA")


# ---------------------------------------------------------------- background

def sea(width, height, seed=3):
    """Deep water lit from above: a gradient, light shafts, one ribbon of
    surface light that snakes through every card, and bubbles. Drawn once
    for the whole strip, so it is continuous across the cuts."""
    rnd = random.Random(seed)
    top, bottom = (54, 30, 120), (8, 10, 34)
    grad = Image.new("RGB", (1, height))
    for y in range(height):
        t = (y / height) ** 0.8
        grad.putpixel((0, y), tuple(int(a + (b - a) * t) for a, b in zip(top, bottom)))
    img = grad.resize((width, height)).convert("RGBA")

    # Soft pools of colour, spaced along the strip.
    glow = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    g = ImageDraw.Draw(glow)
    step = height * 0.9
    x = -step * 0.3
    i = 0
    while x < width + step:
        r = height * rnd.uniform(0.35, 0.6)
        cy = height * rnd.uniform(0.15, 0.75)
        col = [(124, 77, 255, 120), (0, 184, 212, 80), (213, 0, 249, 70)][i % 3]
        g.ellipse([x - r, cy - r, x + r, cy + r], fill=col)
        x += step * rnd.uniform(0.7, 1.1)
        i += 1
    img.alpha_composite(glow.filter(ImageFilter.GaussianBlur(height * 0.12)))

    # Light shafts from the surface, all leaning the same way.
    rays = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    r = ImageDraw.Draw(rays)
    x = -height * 0.5
    while x < width:
        w = height * rnd.uniform(0.03, 0.09)
        lean = height * 0.45
        r.polygon([(x, 0), (x + w, 0), (x + w + lean, height), (x + lean, height)],
                  fill=(200, 190, 255, rnd.randint(10, 22)))
        x += height * rnd.uniform(0.12, 0.3)
    img.alpha_composite(rays.filter(ImageFilter.GaussianBlur(height * 0.012)))

    # The ribbon: two sine waves summed, so it never repeats card to card.
    ribbon = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    d = ImageDraw.Draw(ribbon)
    base = height * 0.62
    amp = height * 0.07
    for k, (alpha, thick) in enumerate([(70, 0.05), (110, 0.012), (60, 0.006)]):
        pts = [(x, base + k * height * 0.03 + amp * math.sin(x / (height * 0.32))
                + amp * 0.5 * math.sin(x / (height * 0.11) + 1.3))
               for x in range(-20, width + 20, 6)]
        d.line(pts, fill=(180, 150, 255, alpha), width=max(2, int(height * thick)))
    img.alpha_composite(ribbon.filter(ImageFilter.GaussianBlur(height * 0.004)))

    # Bubbles, rising in loose columns.
    bubbles = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    b = ImageDraw.Draw(bubbles)
    for _ in range(int(width / height * 40)):
        bx = rnd.uniform(0, width)
        by = rnd.uniform(0, height)
        br = height * rnd.choice([0.002, 0.003, 0.005, 0.008, 0.012])
        b.ellipse([bx - br, by - br, bx + br, by + br], outline=(220, 210, 255, 90),
                  width=max(1, int(br * 0.18)))
        b.ellipse([bx - br * 0.45, by - br * 0.6, bx - br * 0.1, by - br * 0.25],
                  fill=(255, 255, 255, 80))
    img.alpha_composite(bubbles)
    return img


# ---------------------------------------------------------------- devices

def rounded_mask(size, radius):
    m = Image.new("L", size, 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, size[0] - 1, size[1] - 1], radius=radius, fill=255)
    return m


def framed(screen, width, kind):
    """The screen inside a drawn device, at `width` px of screen."""
    scale = width / screen.width
    sw, sh = width, round(screen.height * scale)
    shot = screen.resize((sw, sh), Image.LANCZOS)
    short = min(sw, sh)
    if kind == "phone":
        bezel, radius = round(short * 0.032), round(short * 0.14)
    elif kind in ("duo", "ipad"):
        bezel, radius = round(short * 0.022), round(short * 0.055)
    elif kind == "watch":
        bezel, radius = round(short * 0.07), round(short * 0.24)
    else:  # tv
        bezel, radius = round(short * 0.012), round(short * 0.018)
    W, H = sw + 2 * bezel, sh + 2 * bezel
    dev = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(dev)
    outer = radius + bezel
    d.rounded_rectangle([0, 0, W - 1, H - 1], radius=outer, fill=(16, 16, 20, 255))
    rim = max(2, round(bezel * 0.22))
    d.rounded_rectangle([0, 0, W - 1, H - 1], radius=outer, outline=(120, 116, 140, 255), width=rim)
    d.rounded_rectangle([rim, rim, W - 1 - rim, H - 1 - rim], radius=outer - rim,
                        outline=(40, 38, 52, 255), width=rim)
    dev.paste(shot, (bezel, bezel), rounded_mask((sw, sh), radius))
    if kind == "phone":
        # The Dynamic Island: on the short edge the status bar sits on.
        if sh > sw:
            iw, ih = round(sw * 0.29), round(sw * 0.085)
            x0, y0 = bezel + (sw - iw) // 2, bezel + round(sw * 0.028)
        else:
            iw, ih = round(sh * 0.085), round(sh * 0.29)
            x0, y0 = bezel + round(sh * 0.028), bezel + (sh - ih) // 2
        d.rounded_rectangle([x0, y0, x0 + iw, y0 + ih], radius=min(iw, ih) // 2, fill=(0, 0, 0, 255))
    if kind == "duo":
        # The fold: a faint crease down the middle of the open screen.
        cx = bezel + sw // 2
        crease = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        ImageDraw.Draw(crease).line([(cx, bezel), (cx, bezel + sh)], fill=(255, 255, 255, 26),
                                    width=max(2, round(sw * 0.003)))
        dev.alpha_composite(crease)
    if kind == "watch":
        # Digital Crown and side button, standing proud of the right edge.
        cw, ch = round(bezel * 0.9), round(H * 0.16)
        body = Image.new("RGBA", (W + cw, H), (0, 0, 0, 0))
        bd = ImageDraw.Draw(body)
        bd.rounded_rectangle([W - cw, H * 0.24, W + cw - 1, H * 0.24 + ch], radius=cw // 2,
                             fill=(70, 68, 84, 255), outline=(140, 136, 160, 255), width=2)
        bd.rounded_rectangle([W - cw * 0.6, H * 0.52, W + cw * 0.4, H * 0.52 + ch * 1.1],
                             radius=cw // 3, fill=(50, 48, 62, 255))
        body.alpha_composite(dev)
        dev = body
    return dev


class Canvas:
    def __init__(self, card_w, card_h, cards, seed=3):
        self.card_w, self.card_h, self.cards = card_w, card_h, cards
        self.img = sea(card_w * cards, card_h, seed)

    def place(self, device, cx, top, rotate=0.0, shadow=True):
        dev = device.rotate(rotate, resample=Image.BICUBIC, expand=True) if rotate else device
        x, y = round(cx - dev.width / 2), round(top)
        if shadow:
            sh = Image.new("RGBA", dev.size, (0, 0, 0, 0))
            sh.putalpha(dev.getchannel("A").point(lambda v: int(v * 0.6)))
            pad = round(self.card_h * 0.03)
            big = Image.new("RGBA", (dev.width + 2 * pad, dev.height + 2 * pad), (0, 0, 0, 0))
            big.alpha_composite(sh, (pad, pad))
            big = big.filter(ImageFilter.GaussianBlur(pad * 0.5))
            self.img.alpha_composite(big, (x - pad, y - pad + round(pad * 0.6))) if x - pad >= 0 \
                else self._composite(big, x - pad, y - pad + round(pad * 0.6))
        self._composite(dev, x, y)

    def _composite(self, layer, x, y):
        """alpha_composite that tolerates a layer hanging off any edge."""
        W, H = self.img.size
        sx, sy = max(0, -x), max(0, -y)
        ex, ey = min(layer.width, W - x), min(layer.height, H - y)
        if ex <= sx or ey <= sy:
            return
        self.img.alpha_composite(layer.crop((sx, sy, ex, ey)), (x + sx, y + sy))

    def _span(self, card, region):
        """Where text goes: the card, or `region` = (x, width) in strip px."""
        return region if region else (card * self.card_w, self.card_w)

    def headline(self, card, lines, top, size, align="center", region=None):
        d = ImageDraw.Draw(self.img)
        f = font(size)
        x0, width = self._span(card, region)
        y = top
        for i, text in enumerate(lines):
            w = d.textlength(text, font=f)
            x = x0 + (width - w) / 2 if align == "center" else x0
            d.text((x, y), text, font=f, fill=WHITE if i == 0 else ACCENT)
            y += size * 1.12
        return y

    def pills(self, card, labels, top, size, gap=None, align="center", region=None):
        """Feature chips in rows that fit the card (or the region)."""
        f = font(size, "Semibold")
        layer = Image.new("RGBA", self.img.size, (0, 0, 0, 0))
        d = ImageDraw.Draw(layer)
        padx, h = size * 0.9, size * 2.0
        gap = gap or size * 0.5
        x0, span = self._span(card, region)
        limit = span * 0.86 if region is None else span
        rows, row, width = [], [], 0
        for label in labels:
            w = d.textlength(label, font=f) + 2 * padx
            if row and width + gap + w > limit:
                rows.append((row, width))
                row, width = [], 0
            width += (gap if row else 0) + w
            row.append((label, w))
        rows.append((row, width))
        y = top
        for row, width in rows:
            x = x0 + (span - width) / 2 if align == "center" else x0
            for label, w in row:
                d.rounded_rectangle([x, y, x + w, y + h], radius=h / 2, fill=PILL, outline=PILL_EDGE,
                                    width=max(2, size // 18))
                d.text((x + w / 2, y + h / 2), label, font=f, fill=WHITE, anchor="mm")
                x += w + gap
            y += h + gap
        self.img.alpha_composite(layer)

    def save(self, name, gap_px):
        out = os.path.join(OUT, name)
        os.makedirs(out, exist_ok=True)
        flat = self.img.convert("RGB")
        flat.save(os.path.join(out, "strip.png"))
        cards = [flat.crop((i * self.card_w, 0, (i + 1) * self.card_w, self.card_h)) for i in range(self.cards)]
        for i, c in enumerate(cards):
            c.save(os.path.join(out, f"{i + 1}.png"))
        prev = Image.new("RGB", (self.cards * self.card_w + (self.cards - 1) * gap_px, self.card_h), (242, 242, 247))
        for i, c in enumerate(cards):
            prev.paste(c, (i * (self.card_w + gap_px), 0))
        scale = 1600 / prev.height if prev.height > 1600 else 1
        prev.resize((round(prev.width * scale / 2), round(prev.height * scale / 2)), Image.LANCZOS) \
            .save(os.path.join(out, "preview.png"))
        print(f"{name}: {self.cards} x {self.card_w}x{self.card_h} -> {out}")

    def save_resized(self, name, size):
        """The same cards at another store size: scaled to cover it, then
        trimmed top and bottom (or a pixel at the sides), card by card."""
        out = os.path.join(OUT, name)
        os.makedirs(out, exist_ok=True)
        tw, th = size
        flat = self.img.convert("RGB")
        s = max(tw / self.card_w, th / self.card_h)
        for i in range(self.cards):
            card = flat.crop((i * self.card_w, 0, (i + 1) * self.card_w, self.card_h))
            card = card.resize((round(self.card_w * s), round(self.card_h * s)), Image.LANCZOS)
            x, y = (card.width - tw) // 2, (card.height - th) // 2
            card.crop((x, y, x + tw, y + th)).save(os.path.join(out, f"{i + 1}.png"))
        print(f"{name}: {self.cards} x {tw}x{th} -> {out}")


# ---------------------------------------------------------------- the sets

def iphone():
    """6.9" iPhone, three cards: Home; the landscape player across the first
    cut with Live TV above it; Now Playing across the second cut; a series."""
    W, H = 1320, 2868
    c = Canvas(W, H, 3, seed=3)
    head, top = 112, 170
    c.headline(0, ["Your whole library,", "front and centre"], top, head)
    c.headline(1, ["Plays your files,", "Live TV with a guide"], top, head)
    c.headline(2, ["Your music,", "every series"], top, head)
    phone = lambda name, w: framed(capture(name), w, "phone")
    c.place(phone("iphone-home.png", 880), 0.45 * W, 520)
    c.place(phone("iphone-livetv.png", 880), 1.55 * W, 520)
    c.place(phone("iphone-series.png", 880), 2.6 * W, 520)
    # In front, low: the player across the first cut, Now Playing across the second.
    c.place(phone("iphone-player.png", 1560), 1.0 * W, 1990, rotate=2)
    c.place(phone("iphone-nowplaying.png", 780), 2.02 * W, 1180, rotate=-5)
    c.save("iPhone-6.9in", gap_px=60)
    # The other portrait sizes App Store Connect takes for iPhone.
    for name, size in [("iPhone-6.9in-1290x2796", (1290, 2796)), ("iPhone-6.5in-1284x2778", (1284, 2778)),
                       ("iPhone-6.5in-1242x2688", (1242, 2688)), ("iPhone-6.3in-1206x2622", (1206, 2622))]:
        c.save_resized(name, size)


def ipad():
    """13" iPad, portrait, three cards: Home, Live TV and Music behind; the
    player across the first cut and a series across the second."""
    W, H = 2064, 2752
    c = Canvas(W, H, 3, seed=9)
    head, top = 118, 150
    c.headline(0, ["Your whole library,", "front and centre"], top, head)
    c.headline(1, ["Plays your files,", "Live TV with a guide"], top, head)
    c.headline(2, ["Your music,", "every series"], top, head)
    pad = lambda name, w: framed(capture(name), w, "ipad")
    c.place(pad("ipad-home.png", 1500), 0.42 * W, 470)
    c.place(pad("ipad-livetv.png", 1500), 1.58 * W, 470)
    c.place(pad("ipad-music.png", 1500), 2.58 * W, 470)
    # In front, lower: the player across the first cut, the series across the second.
    c.place(pad("ipad-player.png", 1180), 1.0 * W, 1150, rotate=2)
    c.place(pad("ipad-series.png", 1180), 2.0 * W, 1150, rotate=-2)
    c.save("iPad-13in", gap_px=60)
    c.save_resized("iPad-12.9in-2048x2732", (2048, 2732))


def watch():
    """Apple Watch 46 mm: the screens as they are, on one continuous sea; the
    crowns reach toward the next card."""
    W, H = 416, 496
    c = Canvas(W, H, 3, seed=11)
    for i, name in enumerate(["watch-home.png", "watch-album.png", "watch-nowplaying.png"]):
        c.place(framed(capture(name), 300, "watch"), i * W + W * 0.5 + 6, 44)
    c.save("AppleWatch-46mm", gap_px=20)


def cascade(c, shots, kind, heads, head_size):
    """Five screens across three landscape cards, alternating high and low so
    every other one crosses a cut: high ones in the middle of a card, low
    ones over the cuts and in front."""
    W, H = c.card_w, c.card_h
    for i, text in enumerate(heads):
        c.headline(i, [text], H * 0.045, head_size)
    aspect = capture(shots[0]).height / capture(shots[0]).width
    if W / H > 1.9:
        # A wide card has no room for two rows: one row, each screen as tall
        # as the card allows, every other one sitting over a cut.
        top = H * 0.135
        width = min(W * 0.58, (H * 0.975 - top) / aspect)
        for i, name in enumerate(shots):
            c.place(framed(capture(name), round(width), kind), (0.3 + 0.6 * i) * W, top,
                    rotate=1.5 if i % 2 else -1.5)
        return
    high_top, low_top = H * 0.15, H * 0.33
    width = min(W * 0.64, (H * 0.985 - low_top) / aspect / 1.05)
    spots = [(0.35, high_top), (1.0, low_top), (1.55, high_top), (2.08, low_top), (2.65, high_top)]
    for i in [0, 2, 4, 1, 3]:
        cx, top = spots[i]
        c.place(framed(capture(shots[i]), round(width), kind), cx * W, top,
                rotate=(-2 if i == 1 else 2) if top == low_top else 0)


def duo():
    """iPhone Duo, open, at the inner display's landscape size (the store's
    "iPhone Duo" entry takes 2853x2007): Home, the player, Live TV, Music, a
    series."""
    c = Canvas(2853, 2007, 3, seed=7)
    cascade(c, ["duo-home.png", "duo-player.png", "duo-livetv.png", "duo-music.png", "duo-series.png"], "duo",
            ["Your whole library, front and centre", "Plays your files, Live TV with a guide",
             "Your music, every series"], 98)
    c.save("iPhoneDuo-inner", gap_px=70)


def duo_outer():
    """iPhone Duo, closed: the outer display's landscape size (2034x1398, the
    store's other "iPhone Duo" size). Five upright phones across three cards,
    every other one over a cut."""
    W, H = 2034, 1398
    c = Canvas(W, H, 3, seed=13)
    for i, text in enumerate(["Closed, it's a phone", "Plays your files, Live TV too",
                              "Your music, every series"]):
        c.headline(i, [text], H * 0.05, 82)
    shots = ["duo-out-home.png", "duo-out-player.png", "duo-out-livetv.png", "duo-out-music.png",
             "duo-out-series.png"]
    width = 780
    for i in [0, 2, 4, 1, 3]:
        top = H * 0.155 if i % 2 == 0 else H * 0.235
        c.place(framed(capture(shots[i]), width, "ipad"), (0.3 + 0.6 * i) * W, top,
                rotate=0 if i % 2 == 0 else (4 if i == 1 else -4))
    c.save("iPhoneDuo-outer", gap_px=50)


def tv():
    """Apple TV, 1080p: Home, the player and its panel, Live TV, audio sync,
    a series."""
    c = Canvas(1920, 1080, 3, seed=5)
    cascade(c, ["tv-home.png", "tvp-info.png", "tv-livetv.png", "tvp-sync.png", "tv-episodes.png"], "tv",
            ["Your library on the big screen", "Plays the file as it is, Live TV too",
             "Sync by ear, every series"], 58)
    c.save("AppleTV", gap_px=40)


SETS = {"iphone": iphone, "ipad": ipad, "watch": watch, "duo": duo, "duo_outer": duo_outer, "tv": tv}

if __name__ == "__main__":
    for key in sys.argv[1:] or SETS:
        SETS[key]()
