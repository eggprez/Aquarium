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
    elif kind == "duo":
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


# ---------------------------------------------------------------- the sets

def iphone():
    """6.9" iPhone: Home, the player across cards 2 and 3, Live TV, Music, a series."""
    W, H = 1320, 2868
    c = Canvas(W, H, 6, seed=3)
    head, top = 118, 170
    c.headline(0, ["Your whole library,", "front and centre"], top, head)
    c.headline(1, ["Plays your files", "as they are"], top, head)
    c.headline(2, ["Every control,", "one tap away"], top, head)
    c.headline(3, ["Live TV with", "a real guide"], top, head)
    c.headline(4, ["Your music,", "your stations"], top, head)
    c.headline(5, ["Every series,", "every season"], top, head)

    phone = lambda name, w: framed(capture(name), w, "phone")
    c.place(phone("iphone-home.png", 1040), 0.5 * W, 590)
    # The landscape player straddles the cut between cards 2 and 3.
    c.place(phone("iphone-player.png", 2300), 2.0 * W, 700)
    c.pills(1, ["Direct play", "Skip intro & credits", "Up Next", "Picture in Picture"], 2000, 76)
    c.pills(2, ["Speed", "Sleep timer", "SharePlay", "AirPlay", "Audio & subtitles"], 2000, 76)
    c.place(phone("iphone-livetv.png", 1040), 3.5 * W, 590)
    c.place(phone("iphone-music.png", 860), 4.36 * W, 640, rotate=5)
    c.place(phone("iphone-nowplaying.png", 860), 4.66 * W, 820, rotate=-4)
    c.place(phone("iphone-series.png", 1040), 5.5 * W, 590)
    c.save("iPhone-6.9in", gap_px=60)


def watch():
    """Apple Watch 46 mm: the screens as they are, on one continuous sea; the
    crowns reach toward the next card."""
    W, H = 416, 496
    c = Canvas(W, H, 3, seed=11)
    for i, name in enumerate(["watch-home.png", "watch-album.png", "watch-nowplaying.png"]):
        c.place(framed(capture(name), 300, "watch"), i * W + W * 0.5 + 6, 44)
    c.save("AppleWatch-46mm", gap_px=20)


def duo():
    """iPhone Duo, open: Home, the player across cards 2 and 3 with the words
    either side of it, Live TV, Music, a series."""
    W, H = 2853, 2007
    c = Canvas(W, H, 6, seed=7)
    head, top = 104, 110
    c.headline(0, ["Your whole library, front and centre", "on the big inside screen"], top, head)
    c.headline(3, ["Live TV with a real guide", "every channel at a glance"], top, head)
    c.headline(4, ["Your music, your stations", "built from what you play"], top, head)
    c.headline(5, ["Every series, every season", "carry on where you left off"], top, head)
    duo = lambda name, w: framed(capture(name), w, "duo")
    for i, name in [(0, "duo-home.png"), (3, "duo-livetv.png"), (4, "duo-music.png"), (5, "duo-series.png")]:
        c.place(duo(name, 2380), i * W + W * 0.5, 400)

    # The player hangs across the cut between cards 2 and 3, upright in the
    # middle of the strip; each card keeps the open sea beside it for words.
    player = duo("duo-player.png", 2250)
    c.place(player, 2.0 * W, (H - player.height) / 2)
    left = (W + 190, 2.0 * W - player.width / 2 - W - 330)
    right = (2.0 * W + player.width / 2 + 140, 3 * W - (2.0 * W + player.width / 2) - 330)
    y = c.headline(1, ["Plays your files", "as they are"], 520, 150, align="left", region=left)
    c.pills(1, ["Direct play", "Skip intro & credits", "Up Next", "Picture in Picture"], y + 80, 76,
            align="left", region=left)
    y = c.headline(2, ["Every control,", "one tap away"], 520, 150, align="left", region=right)
    c.pills(2, ["Speed", "Sleep timer", "SharePlay", "AirPlay", "Audio & subtitles"], y + 80, 76,
            align="left", region=right)
    c.save("iPhoneDuo", gap_px=70)


def tv():
    """Apple TV, 1080p: Home, the player and its panel across cards 2 and 3,
    audio sync, Live TV, a series."""
    W, H = 1920, 1080
    c = Canvas(W, H, 6, seed=5)
    head, top = 62, 52
    c.headline(0, ["Your library on the big screen"], top, head)
    c.headline(3, ["Audio sync you set by ear"], top, head)
    c.headline(4, ["Live TV with a real guide"], top, head)
    c.headline(5, ["Every series, every season"], top, head)
    screen = lambda name, w=1560: framed(capture(name), w, "tv")
    for i, name in [(0, "tv-home.png"), (3, "tvp-sync.png"), (4, "tv-livetv.png"), (5, "tv-episodes.png")]:
        c.place(screen(name), i * W + W * 0.5, 170)

    player = screen("tvp-info.png", 1640)
    c.place(player, 2.0 * W, (H - player.height) / 2)
    left = (W + 100, 2.0 * W - player.width / 2 - W - 160)
    right = (2.0 * W + player.width / 2 + 70, 3 * W - (2.0 * W + player.width / 2) - 160)
    y = c.headline(1, ["Plays the file", "as it is"], 290, 80, align="left", region=left)
    c.pills(1, ["Direct play", "MKV, DTS, TrueHD", "Your TV's frame rate"], y + 40, 38,
            align="left", region=left)
    y = c.headline(2, ["Everything,", "one swipe down"], 290, 80, align="left", region=right)
    c.pills(2, ["Info", "Audio", "Subtitles", "Quality", "Speed", "Sync", "Picture"], y + 40, 38,
            align="left", region=right)
    c.save("AppleTV", gap_px=40)


SETS = {"iphone": iphone, "watch": watch, "duo": duo, "tv": tv}

if __name__ == "__main__":
    for key in sys.argv[1:] or SETS:
        SETS[key]()
