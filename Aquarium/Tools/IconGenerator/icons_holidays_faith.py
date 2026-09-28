"""Seasonal alternate icons for religious and cultural festivals. Each is
offered from 30 days before to 30 days after its holiday (the scheduling lives
in Swift); this module only draws them.

    python3 proof_sheet.py icons_holidays_faith <out-dir> [key ...]

Festival imagery only: lights, lanterns, food, flowers and seasonal things.
No sacred figures, no scripture, and the play triangle stays off every symbol.
"""

import math

from icon_kit import *  # noqa: F401,F403

SHELF = "Seasonal"

# ------------------------------------------------------------------ helpers


def ell(cx, cy, rx, ry, deg=0):
    """An ellipse, optionally turned by `deg`."""
    a = math.radians(deg)
    dx, dy = rx * math.cos(a), rx * math.sin(a)
    p, q = (cx - dx, cy - dy), (cx + dx, cy + dy)
    return (f"M{f(p[0])} {f(p[1])} A{f(rx)} {f(ry)} {f(deg)} 1 0 {f(q[0])} {f(q[1])} "
            f"A{f(rx)} {f(ry)} {f(deg)} 1 0 {f(p[0])} {f(p[1])} Z")


def egg(cx, cy, w, h):
    t, b, m = cy - h / 2, cy + h / 2, cy + h * 0.1
    return (f"M{f(cx)} {f(t)} C{f(cx + w * .3)} {f(t)} {f(cx + w / 2)} {f(cy - h * .22)} {f(cx + w / 2)} {f(m)} "
            f"C{f(cx + w / 2)} {f(cy + h * .36)} {f(cx + w * .28)} {f(b)} {f(cx)} {f(b)} "
            f"C{f(cx - w * .28)} {f(b)} {f(cx - w / 2)} {f(cy + h * .36)} {f(cx - w / 2)} {f(m)} "
            f"C{f(cx - w / 2)} {f(cy - h * .22)} {f(cx - w * .3)} {f(t)} {f(cx)} {f(t)} Z")


def flame(cx, bot, w, h):
    """A teardrop standing on (cx, bot), tip up."""
    t, r = bot - h, w / 2
    return (f"M{f(cx)} {f(t)} C{f(cx + w * .12)} {f(t + h * .3)} {f(cx + r)} {f(t + h * .42)} {f(cx + r)} {f(bot - r)} "
            f"A{f(r)} {f(r)} 0 0 1 {f(cx - r)} {f(bot - r)} "
            f"C{f(cx - r)} {f(t + h * .42)} {f(cx - w * .12)} {f(t + h * .3)} {f(cx)} {f(t)} Z")


def leaf(x0, y0, x1, y1, w, bend=0.0):
    """A pointed leaf from (x0, y0) to (x1, y1), about w wide; `bend` curves it."""
    mx, my = (x0 + x1) / 2, (y0 + y1) / 2
    L = math.hypot(x1 - x0, y1 - y0)
    nx, ny = -(y1 - y0) / L, (x1 - x0) / L
    b = bend * L
    c1 = (mx + nx * (w + b), my + ny * (w + b))
    c2 = (mx - nx * (w - b), my - ny * (w - b))
    return (f"M{f(x0)} {f(y0)} Q{f(c1[0])} {f(c1[1])} {f(x1)} {f(y1)} "
            f"Q{f(c2[0])} {f(c2[1])} {f(x0)} {f(y0)} Z")


def polar(cx, cy, fn, steps=180):
    pts = []
    for i in range(steps):
        t = i / steps * 2 * math.pi
        r = fn(t)
        pts.append((cx + r * math.cos(t), cy + r * math.sin(t)))
    return "M" + " L".join(f"{f(x)} {f(y)}" for x, y in pts) + " Z"


def poly(pts):
    return "M" + " L".join(f"{f(x)} {f(y)}" for x, y in pts) + " Z"


def blossom(cx, cy, r, turn=0):
    """Five round petals: a plum or cherry flower."""
    return "".join(circle(cx + r * .62 * math.cos(math.radians(turn + i * 72 - 90)),
                          cy + r * .62 * math.sin(math.radians(turn + i * 72 - 90)), r * .46) + " "
                   for i in range(5))


def tr(body, x=0, y=0, s=1, r=0):
    return f'<g transform="translate({f(x)} {f(y)}) rotate({f(r)}) scale({s})">{body}</g>'


def stroke(d, color, w, extra=""):
    return f'<path d="{d}" fill="none" stroke="{color}" stroke-width="{f(w)}" stroke-linecap="round" stroke-linejoin="round"{extra}/>'


def twinkles(spots, fill=WHITE):
    return "".join(path(sparkle(x, y, r), fill, f' opacity="{o}"') for x, y, r, o in spots)


def dots(spots, fill=WHITE):
    return "".join(path(circle(x, y, r), fill, f' opacity="{o}"') for x, y, r, o in spots)


# ------------------------------------------------------------------ the icons


def lunar_new_year():
    def lantern(cx, cy, w, h):
        rx, ry = w / 2, h / 2
        body = path(ell(cx, cy, rx, ry), "#FF5536")
        ribs = (stroke(ell(cx, cy, rx * .52, ry - 4), "#D8202A", w * .026)
                + stroke(f"M{f(cx)} {f(cy - ry + 4)} V{f(cy + ry - 4)}", "#D8202A", w * .026))
        cw, ch = w * .56, h * .15
        gold = (path(rr(cx - cw / 2, cy - ry - ch * .55, cw, ch, ch * .35), "#FFD35A")
                + path(rr(cx - cw / 2, cy + ry - ch * .45, cw, ch, ch * .35), "#FFD35A")
                + path(rr(cx - w * .025, cy + ry + ch * .5, w * .05, h * .12, w * .02), "#FFD35A")
                + path(rounded_poly([(cx - w * .07, cy + ry + h * .24), (cx + w * .07, cy + ry + h * .24),
                                     (cx + w * .11, cy + ry + h * .52), (cx - w * .11, cy + ry + h * .52)], w * .025),
                       "#FFD35A"))
        cord = path(rr(cx - 4, 0, 8, cy - ry - ch * .5, 4), "#FFD35A")
        return body + ribs, gold + cord

    b1, g1 = lantern(480, 560, 440, 350)
    b2, g2 = lantern(690, 250, 180, 150)
    bodies = svg(b1 + b2)
    gold = svg(g1 + g2)
    branch = stroke("M40 1000 C120 900 200 880 300 800 M190 880 C210 820 200 790 180 760", "#5A1A12", 18)
    flowers = (path(blossom(300, 790, 64, 10), "#FFC2D4") + path(blossom(180, 752, 52, 40), "#FFC2D4")
               + path(blossom(110, 900, 44, 0), "#FFC2D4")
               + dots([(300, 790, 13, 1), (180, 752, 11, 1), (110, 900, 9, 1)], "#FFD35A"))
    blossoms = svg(branch + flowers)
    return Icon("lunarnewyear", "Lunar New Year", "Happy Lunar New Year",
                ("#D7263D", "#8E0B1E"), ("#48091A", "#140206"),
                [Group(Layer("gold", gold), shadow=0.4),
                 Group(Layer("blossom", blossoms), shadow=0.4),
                 Group(Layer("lanterns", bodies), shadow=0.6)],
                shelf=SHELF, asset="LunarNewYear")


def purim():
    mask_d = ("M512 380 C566 330 668 296 752 312 C764 392 730 478 664 506 C612 528 556 506 512 468 "
              "C468 506 412 528 360 506 C294 478 260 392 272 312 C356 296 458 330 512 380 Z "
              + ell(410, 418, 62, 38, 14) + " " + ell(614, 418, 62, 38, -14))
    feathers = (path(leaf(712, 320, 700, 120, 34, .05), "#FF5FA8")
                + path(leaf(724, 320, 790, 160, 30, -.04), "#3FD9C8")
                + path(leaf(700, 324, 612, 150, 30, .05), "#FFE066"))
    trim = dots([(512, 408, 12, 1), (340, 470, 9, 1), (684, 470, 9, 1), (300, 350, 8, 1), (724, 350, 8, 1)], "#FF5FA8")
    mask = svg(tr(feathers + path(mask_d, "#FFC83D", EO) + trim, -40, -30, 1.08))

    def cookie(cx, cy, s, turn):
        pts = [(cx + s * math.cos(math.radians(turn - 90 + i * 120)),
                cy + s * math.sin(math.radians(turn - 90 + i * 120))) for i in range(3)]
        return rounded_poly(pts, s * .42)
    dough = svg(path(cookie(390, 740, 170, -8), "#F4C27A") + path(cookie(640, 770, 140, 12), "#F4C27A"))
    filling = svg(path(circle(390, 752, 44), "#A31D4C") + path(circle(640, 780, 36), "#E8742A"))
    return Icon("purim", "Purim", "Chag Purim sameach",
                ("#8A4FFF", "#4B1FB0"), ("#241048", "#0A0418"),
                [Group(Layer("mask", mask), shadow=0.5),
                 Group(Layer("filling", filling), shadow=0.3),
                 Group(Layer("dough", dough), shadow=0.5)],
                diagonal=True, shelf=SHELF, asset="Purim")


def nowruz():
    blades = []
    n = 21
    for i in range(n):
        t = i / (n - 1) * 2 - 1                      # -1 .. 1
        bx = 500 + t * 170
        tx = 500 + t * 300 + (18 if i % 2 else -18)
        ty = 330 + abs(t) ** 1.6 * 170 + (0 if i % 2 else 36)
        blades.append(leaf(bx, 790, tx, ty, 26, .06 * t))
    grass = svg(path(" ".join(blades), "#5CC73A"))
    bowl = svg(path("M284 770 H716 C706 868 620 906 500 906 C380 906 294 868 284 770 Z", "#1E9E9A")
               + path(rr(268, 752, 464, 36, 18), "#FFD166"))
    ribbon = (path(rr(376, 650, 248, 44, 16), "#E63946")
              + path(leaf(500, 672, 404, 600, 40, .1), "#E63946") + path(leaf(500, 672, 596, 600, 40, -.1), "#E63946")
              + path(circle(500, 672, 26), "#C62839"))
    eggs = (path(egg(222, 842, 116, 150), "#FF8FAB") + path(rr(166, 846, 112, 26, 13), "#FFE066")
            + path(egg(340, 892, 100, 128), "#FFE066") + path(rr(292, 894, 96, 22, 11), "#6C63FF"))
    flowers = (stroke("M800 60 C740 120 700 170 610 200", "#8A5A44", 14)
               + path(blossom(610, 200, 60, 0), "#FF9EC4") + path(blossom(712, 142, 50, 30), "#FFFFFF")
               + dots([(610, 200, 12, 1), (712, 142, 10, 1)], "#FFD166"))
    return Icon("nowruz", "Nowruz", "Nowruz mobarak",
                ("#A8E4FF", "#4FA6E8"), ("#0E2A4A", "#03101F"),
                [Group(Layer("sprigs", svg(ribbon + eggs + flowers)), shadow=0.5),
                 Group(Layer("sabzeh", grass), shadow=0.4),
                 Group(Layer("bowl", bowl), shadow=0.5)],
                bubbles=("#1D5FA8", None), shelf=SHELF, asset="Nowruz")


def fanous(frame_fill, glow_fill):
    """A fanous lantern in local coordinates, about 560 tall, centred on 0."""
    outer = [(-90, -132), (90, -132), (122, -20), (90, 112), (-90, 112), (-122, -20)]
    left = [(-72, -112), (-9, -112), (-9, 92), (-72, 92), (-98, -20)]
    right = [(-x, y) for x, y in left]
    frame = " ".join([
        circle(0, -262, 26), circle(0, -262, 12),
        "M-78 -150 C-78 -206 -30 -226 0 -238 C30 -226 78 -206 78 -150 Z",
        rr(-104, -162, 208, 30, 12),
        poly(outer), poly(left), poly(right),
        rr(-84, 110, 168, 28, 12),
        rounded_poly([(-70, 134), (70, 134), (0, 214)], 12),
        circle(0, 236, 16),
    ])
    glow = poly([(-86, -128), (86, -128), (116, -20), (86, 108), (-86, 108), (-116, -20)])
    return path(frame, frame_fill, EO), path(glow, glow_fill)


def ramadan():
    fr, gl = fanous("#F5C451", "#FFE9A8")
    x, y, s = 648, 470, 1.22
    chain = path(rr(x - 4, 0, 8, y - 290 * s, 4), "#F5C451")
    frame = svg(chain + tr(fr, x, y, s))
    glow = svg(tr(gl, x, y, s))
    moon = path(crescent((360, 540), 220, (448, 470), 186), "#FFF3C4")
    stars = twinkles([(260, 720, 26, .9), (470, 830, 18, .8), (560, 130, 16, .8), (410, 250, 12, .6),
                      (160, 560, 12, .6), (700, 900, 12, .5)])
    return Icon("ramadan", "Ramadan", "Ramadan kareem",
                ("#2A3F99", "#0C1438"), ("#0E1640", "#02040E"),
                [Group(Layer("frame", frame), shadow=0.5),
                 Group(Layer("glow", glow), glass_shadow="layer-color", shadow=0.6, translucency=0.2),
                 Group(Layer("moon", svg(moon)), Layer("stars", svg(stars), glass=False), shadow=0.5)],
                shelf=SHELF, asset="Ramadan")


def eid_al_fitr():
    moon = path(crescent((450, 470), 210, (540, 420), 178), "#FFD86B")
    star_d = path(star(640, 440, 62, 27), "#FFD86B")
    # A string of lights sagging across the top.
    wire = stroke("M330 70 Q540 300 780 120", "#0A3D2B", 7, ' opacity=".7"')
    bulbs = []
    colors = ["#FF6B6B", "#FFD86B", "#6BC5FF", "#FF9FE0", "#FFFFFF", "#FFB347"]
    for i in range(6):
        t = (i + .5) / 6
        bx = (1 - t) ** 2 * 330 + 2 * (1 - t) * t * 540 + t * t * 780
        by = (1 - t) ** 2 * 70 + 2 * (1 - t) * t * 300 + t * t * 120
        bulbs.append(path(ell(bx, by + 26, 17, 24), colors[i]))
    lights = svg(wire + "".join(bulbs))
    plate = path(ell(470, 850, 280, 54), "#FFFFFF")
    sweets = "".join(path(f"M{x - r} {y} A{r} {r * .9} 0 0 1 {x + r} {y} Z", c)
                     for x, y, r, c in [(360, 850, 74, "#F2C37A"), (470, 832, 80, "#E8A95C"), (582, 850, 74, "#F2C37A")])
    dates = path(ell(470, 744, 36, 20, -10), "#7A3B1E")
    food = svg(plate + sweets + dates)
    return Icon("eidalfitr", "Eid al-Fitr", "Eid Mubarak",
                ("#20C08A", "#0A6B4A"), ("#07402C", "#02120C"),
                [Group(Layer("moon", svg(moon + star_d)), shadow=0.5),
                 Group(Layer("lights", lights), glass_shadow="layer-color", shadow=0.6),
                 Group(Layer("sweets", food), shadow=0.5)],
                shelf=SHELF, asset="EidAlFitr")


def holi():
    import random
    rnd = random.Random(7)
    ox, oy = 500, 560   # where the colour is thrown from

    def burst(cx, cy, R):
        harm = [(k, R * rnd.uniform(.05, .12) / k ** .35, rnd.uniform(0, 6.3)) for k in range(2, 8)]
        return polar(cx, cy, lambda t: R + sum(a * math.sin(k * t + p) for k, a, p in harm), 200)

    def spray(cx, cy, R, n=9):
        # Specks flung outward, away from the middle.
        base = math.atan2(cy - oy, cx - ox)
        out = []
        for i in range(n):
            a = base + rnd.uniform(-1.1, 1.1)
            d = R * rnd.uniform(1.12, 1.55)
            out.append(circle(cx + d * math.cos(a), cy + d * math.sin(a), R * rnd.uniform(.04, .10)))
        return " ".join(out)

    def layer(items):
        return svg("".join(path(burst(x, y, R) + " " + spray(x, y, R), col) for x, y, R, col in items))
    top = [(500, 560, 120, "#FF7A1A")]
    mid = [(370, 430, 150, "#FF2E88"), (650, 690, 140, "#2EC4FF")]
    back = [(630, 370, 130, "#FFD21F"), (360, 710, 140, "#35D06B")]
    return Icon("holi", "Holi", "Happy Holi",
                ("#FFF8EC", "#FFE2C4"), ("#2A1034", "#0A0410"),
                [Group(Layer("orange", layer(top)), shadow=0.4),
                 Group(Layer("pinkblue", layer(mid)), shadow=0.4),
                 Group(Layer("yellowgreen", layer(back)), shadow=0.4)],
                bubbles=("#B0206A", WHITE), shelf=SHELF, asset="Holi")


def passover():
    back = svg(f'<g transform="rotate(10 470 690)">{path(rr(290, 510, 360, 360, 26), "#E2BE82")}</g>')
    holes = rr(250, 540, 360, 360, 26) + "".join(" " + circle(250 + 360 * (c + 1) / 6, 540 + 360 * (r + 1) / 6, 8)
                                                  for r in range(5) for c in range(5))
    toast = "".join(f'<rect x="{250 + 360 * (c + 1) / 6 - 3}" y="560" width="6" height="320" rx="3" fill="#D9A55E" opacity=".7"/>'
                    for c in range(5))
    front = svg(f'<g transform="rotate(-8 430 720)">{path(holes, "#F6E3BC", EO)}{toast}</g>')
    cx = 668
    cup = (f"M{cx - 100} 250 H{cx + 100} C{cx + 100} 420 {cx + 60} 500 {cx} 510 "
           f"C{cx - 60} 500 {cx - 100} 420 {cx - 100} 250 Z "
           + rr(cx - 13, 500, 26, 180, 10) + " " + ell(cx, 590, 26, 18) + " "
           + f"M{cx - 96} 740 C{cx - 90} 690 {cx - 40} 676 {cx} 676 C{cx + 40} 676 {cx + 90} 690 {cx + 96} 740 Z")
    wine = (f'<clipPath id="w"><rect x="0" y="312" width="1024" height="400"/></clipPath>'
            f'<clipPath id="bowl"><path d="M{cx - 84} 250 H{cx + 84} C{cx + 84} 410 {cx + 50} 484 {cx} 492 C{cx - 50} 484 {cx - 84} 410 {cx - 84} 250 Z"/></clipPath>')
    wine_l = svg(f'<g clip-path="url(#w)"><g clip-path="url(#bowl)"><rect x="0" y="0" width="1024" height="1024" fill="#B3163C"/></g></g>', wine)
    return Icon("passover", "Passover", "Chag Pesach sameach",
                ("#4A7CE8", "#1B3A8C"), ("#10204C", "#03081A"),
                [Group(Layer("wine", wine_l), Layer("cup", svg(path(cup, "#E9EEF7"))), shadow=0.5),
                 Group(Layer("matzah", front), shadow=0.5),
                 Group(Layer("matzah-back", back), shadow=0.4)],
                shelf=SHELF, asset="Passover")


def easter():
    big, left, right = (490, 520, 300, 400), (292, 710, 190, 250), (668, 728, 180, 236)

    def bands(e, zig, dot_c, turn=0):
        cx, cy, w, h = e
        clip = f'<clipPath id="e{cx}"><path d="{egg(cx, cy, w, h)}"/></clipPath>'
        pts = []
        amp, step = h * .05, w / 6
        for i in range(-4, 11):
            pts.append((cx - w / 2 + i * step / 2, cy + (-amp if i % 2 else amp)))
        top = " L".join(f"{f(x)} {f(y - h * .04)}" for x, y in pts)
        bot = " L".join(f"{f(x)} {f(y + h * .04)}" for x, y in reversed(pts))
        z = f"M{top} L{bot} Z"
        spots = " ".join(circle(cx + dx * w, cy + dy * h, w * .05) for dx, dy in [(-.22, -.22), (0, -.28), (.22, -.22), (-.2, .26), (0, .3), (.2, .26)])
        return clip, f'<g clip-path="url(#e{cx})">{path(z, zig)}{path(spots, dot_c)}</g>'
    defs, deco = "", ""
    for e, z, d in [(big, WHITE, "#FFE066"), (left, "#FF7FB0", WHITE), (right, "#FFE066", WHITE)]:
        c, g = bands(e, z, d)
        defs += c
        deco += g
    eggs = svg(path(egg(*big), "#FF7FB0") + path(egg(*left), "#7FD6FF") + path(egg(*right), "#9C7CFF"))
    grass = []
    for i in range(22):
        x = 150 + i * 28
        y = 900 - 80 * math.sin(math.pi * (x - 60) / 740) + 20
        h = 70 + (i * 53) % 60
        grass.append(leaf(x, y, x + ((i * 31) % 40 - 20), y - h, 16))
    meadow = (path(" ".join(grass), "#58C26A") + path("M60 1024 L60 900 C260 820 560 820 800 900 L800 1024 Z", "#58C26A")
              + path(blossom(200, 850, 44), WHITE) + path(blossom(560, 880, 38, 20), WHITE)
              + dots([(200, 850, 10, 1), (560, 880, 9, 1)], "#FFD21F"))
    return Icon("easter", "Easter", "Happy Easter",
                ("#D9C8FF", "#A58AF0"), ("#2B1E52", "#0C0718"),
                [Group(Layer("paint", svg(deco, defs)), shadow=0.3),
                 Group(Layer("eggs", eggs), shadow=0.5),
                 Group(Layer("meadow", svg(meadow)), shadow=0.4)],
                bubbles=("#5B3FB8", WHITE), shelf=SHELF, asset="Easter")


def vaisakhi():
    heads, stalks = [], []
    n = 9
    for i in range(n):
        t = i / (n - 1) * 2 - 1
        base = (512 + t * 60, 880)
        tie = (512 + t * 26, 650)
        top = (512 + t * 230, 400 - (1 - abs(t)) * 110 + abs(t) * 40)
        stalks.append(stroke(f"M{f(base[0])} {f(base[1])} L{f(tie[0])} {f(tie[1])} "
                             f"Q{f(tie[0] + (top[0] - tie[0]) * .3)} {f(tie[1] - 120)} {f(top[0])} {f(top[1])}",
                             "#FFD66B", 16))
        ang = math.atan2(top[1] - tie[1] + 120 * .4, top[0] - tie[0])
        ang = math.atan2(top[1] - (tie[1] - 120), top[0] - (tie[0] + (top[0] - tie[0]) * .3))
        ux, uy = math.cos(ang), math.sin(ang)
        px, py = -uy, ux
        for k in range(5):
            d = 10 + k * 26
            gx, gy = top[0] + ux * d, top[1] + uy * d
            for side in (-1, 1):
                ex, ey = gx + px * side * 16 + ux * 20, gy + py * side * 16 + uy * 20
                heads.append(leaf(gx, gy, ex, ey, 14))
        tip = (top[0] + ux * 150, top[1] + uy * 150)
        heads.append(leaf(top[0] + ux * 8, top[1] + uy * 8, tip[0], tip[1], 20))
    sun = svg(path(circle(512, 470, 215), "#FF9933"))
    wheat = svg("".join(stalks))
    grain = svg(path(" ".join(heads), "#FFF1B8") + path(rr(452, 624, 120, 52, 20), "#1E3A8A"))
    return Icon("vaisakhi", "Vaisakhi", "Vaisakhi diyan vadhaiyan",
                ("#3057C7", "#152A70"), ("#0C1638", "#030612"),
                [Group(Layer("grain", grain), shadow=0.5),
                 Group(Layer("stalks", wheat), shadow=0.4),
                 Group(Layer("sun", sun), shadow=0.3)],
                shelf=SHELF, asset="Vaisakhi")


def vesak():
    def lantern(cx, cy, r, col):
        d = circle(cx, cy, r)
        return (path(rr(cx - 3, 0, 6, cy - r, 3), "#FFE9B0") + path(d, col)
                + path(rr(cx - r * .45, cy - r - 12, r * .9, 20, 8), "#FFE9B0")
                + path(rr(cx - r * .45, cy + r - 8, r * .9, 20, 8), "#FFE9B0"))
    lanterns = svg(lantern(400, 250, 78, "#FFB347") + lantern(580, 180, 66, "#FFD86B") + lantern(730, 290, 62, "#FF8FB1"))
    cx, base = 512, 830
    front = " ".join([leaf(cx, base, cx, 480, 90),
                      leaf(cx - 10, base, cx - 190, 560, 80, .05), leaf(cx + 10, base, cx + 190, 560, 80, -.05)])
    back = " ".join([leaf(cx - 20, base, cx - 110, 500, 80, .02), leaf(cx + 20, base, cx + 110, 500, 80, -.02),
                     leaf(cx - 30, base, cx - 280, 680, 70, .08), leaf(cx + 30, base, cx + 280, 680, 70, -.08)])
    pad = path(ell(cx - 20, 858, 290, 54), "#2FB67E")
    return Icon("vesak", "Vesak", "Happy Vesak",
                ("#4B3AA8", "#171253"), ("#16103E", "#05030F"),
                [Group(Layer("lanterns", lanterns), glass_shadow="layer-color", shadow=0.6),
                 Group(Layer("petals", svg(path(front, "#FFB3D1"))), shadow=0.5),
                 Group(Layer("lotus", svg(pad + path(back, "#FF6FA8"))), shadow=0.5)],
                shelf=SHELF, asset="Vesak")


def eid_al_adha():
    cx, cy = 512, 600
    outer = star(cx, cy, 270, 222, points=8, rot=-90 + 22.5)
    inner = star(cx, cy, 214, 176, points=8, rot=-90 + 22.5)
    medallion = svg(path(outer + " " + inner, "#F4C66A", EO))
    moon = svg(path(crescent((cx - 20, cy), 130, (cx + 36, cy - 30), 112), "#FFF4D6")
               + path(star(cx + 70, cy - 30, 34, 15), "#FFF4D6"))

    def lamp(x, top, s):
        body = rounded_poly([(x - 34 * s, top + 40 * s), (x + 34 * s, top + 40 * s), (x + 46 * s, top + 100 * s),
                             (x + 24 * s, top + 150 * s), (x - 24 * s, top + 150 * s), (x - 46 * s, top + 100 * s)], 8 * s)
        cap = f"M{f(x - 30 * s)} {f(top + 40 * s)} Q{f(x)} {f(top - 10 * s)} {f(x + 30 * s)} {f(top + 40 * s)} Z"
        tip = rounded_poly([(x - 18 * s, top + 150 * s), (x + 18 * s, top + 150 * s), (x, top + 190 * s)], 4 * s)
        return (path(rr(x - 3, 0, 6, top, 3), "#F4C66A") + path(body, "#FFB547")
                + path(cap + " " + tip, "#F4C66A"))
    lamps = svg(lamp(380, 150, 1.0) + lamp(648, 70, 1.15))
    dots_ = dots([(200, 620, 10, .7), (824, 280, 8, .6), (180, 440, 7, .5), (300, 900, 8, .5), (700, 950, 7, .5)], "#F4C66A")
    return Icon("eidaladha", "Eid al-Adha", "Eid al-Adha Mubarak",
                ("#9A2F74", "#43103A"), ("#300A28", "#0E020B"),
                [Group(Layer("moon", moon), shadow=0.5),
                 Group(Layer("lamps", lamps), shadow=0.5),
                 Group(Layer("medallion", medallion), Layer("dots", svg(dots_), glass=False), shadow=0.5)],
                shelf=SHELF, asset="EidAlAdha")


def rosh_hashanah():
    def apple_d(cx, cy, s):
        pts = ("M-66 -150 C-150 -190 -270 -150 -270 0 C-270 150 -170 260 -70 260 C-40 260 -24 248 0 248 "
               "C24 248 40 260 70 260 C170 260 270 150 270 0 C270 -150 150 -190 66 -150 C36 -134 -36 -134 -66 -150 Z")
        return f'<g transform="translate({cx} {cy}) scale({s})">{{}}</g>', pts
    g, apple = apple_d(360, 560, .74)
    fruit = svg(g.format(path(apple, "#E3262E") + path(ell(-170, -30, 34, 70, 20), WHITE, ' opacity=".4"')
                         + stroke("M-8 -140 C-10 -200 4 -240 36 -268", "#6B3A1E", 22)
                         + path(leaf(20, -236, 170, -300, 44, .05), "#58B947")))
    jx, jw = 560, 190
    jar = rr(jx, 460, jw, 320, 56) + " " + rr(jx + 16, 420, jw - 32, 52, 16)
    honey = rr(jx + 16, 540, jw - 32, 224, 44)
    lid = f"M{jx - 12} 420 Q{jx + jw / 2} 364 {jx + jw + 12} 420 L{jx + jw} 468 Q{jx + jw / 2} 446 {jx} 468 Z"
    drip = f"M{jx + 40} 456 C{jx + 40} 500 {jx + 58} 520 {jx + 58} 540 A18 18 0 0 1 {jx + 22} 540 C{jx + 22} 520 {jx + 40} 500 {jx + 40} 456 Z"
    pcx, pcy, pr = 500, 820, 92
    pom = (circle(pcx, pcy, pr) + " "
           + rounded_poly([(pcx - 34, pcy - pr + 14), (pcx + 34, pcy - pr + 14), (pcx + 52, pcy - pr - 34),
                           (pcx + 16, pcy - pr - 14), (pcx, pcy - pr - 44), (pcx - 16, pcy - pr - 14),
                           (pcx - 52, pcy - pr - 34)], 6))
    jar_l = svg(path(jar, "#FFF4DA", ' opacity=".9"'))
    honey_l = svg(path(honey, "#F2A516") + path(lid, "#D9482B") + path(drip, "#F2A516"))
    pom_l = svg(path(pom, "#B8123E") + path(ell(pcx - 40, pcy - 24, 16, 30, 25), WHITE, ' opacity=".35"'))
    return Icon("roshhashanah", "Rosh Hashanah", "Shana tova",
                ("#FFE7A3", "#F5B83A"), ("#3A2208", "#120A02"),
                [Group(Layer("pomegranate", pom_l), shadow=0.5),
                 Group(Layer("apple", fruit), Layer("honey", honey_l), shadow=0.5),
                 Group(Layer("jar", jar_l), shadow=0.4)],
                bubbles=("#9A5A0A", "#FFD27A"), shelf=SHELF, asset="RoshHashanah")


def mid_autumn():
    moon = svg(path(circle(560, 360, 220), "#FFE9A8"))
    # Mooncake: a scalloped round with an embossed flower on top.
    mc = polar(380, 780, lambda t: 150 * (1 + .05 * math.cos(12 * t)))
    emboss = circle(380, 780, 104) + " " + blossom(380, 780, 70) + " " + circle(380, 780, 18)
    cake = svg(path(mc, "#D98E3A") + stroke(circle(380, 780, 104), "#F2B866", 10)
               + path(blossom(380, 780, 70), "#F2B866") + path(circle(380, 780, 18), "#D98E3A"))
    rx, ry = 640, 770
    rabbit = (path(ell(rx, ry, 110, 78), WHITE) + path(ell(rx - 96, ry - 36, 44, 38), WHITE)
              + path(leaf(rx - 90, ry - 64, rx - 70, ry - 190, 30, -.05), WHITE)
              + path(leaf(rx - 110, ry - 64, rx - 150, ry - 180, 28, .05), WHITE))
    marks = (path(circle(rx - 108, ry - 44, 9), "#E0283A") + path(leaf(rx - 84, ry - 80, rx - 72, ry - 160, 10), "#FF8FA8")
             + path(ell(rx + 10, ry, 44, 20), "#FF8FA8") + stroke(f"M{rx + 100} {ry - 70} Q{rx + 40} {ry - 190} {rx - 10} {ry - 250}", "#8A5A2B", 10)
             + path(circle(rx - 40, ry + 88, 24), "#E0283A") + path(circle(rx + 60, ry + 88, 24), "#E0283A"))
    stars = twinkles([(230, 470, 18, .8), (300, 600, 12, .6), (840, 180, 14, .6), (700, 620, 10, .5)])
    return Icon("midautumn", "Mid-Autumn", "Happy Mid-Autumn Festival",
                ("#2A4A92", "#0C1840"), ("#0C1638", "#02050F"),
                [Group(Layer("marks", svg(marks)), shadow=0.3),
                 Group(Layer("rabbit", svg(rabbit)), Layer("cake", cake), shadow=0.5),
                 Group(Layer("moon", moon), Layer("stars", svg(stars), glass=False),
                       glass_shadow="layer-color", shadow=0.5)],
                shelf=SHELF, asset="MidAutumn")


def dia_de_muertos():
    cx = 512
    skull = circle(cx, 500, 220) + " " + rr(cx - 128, 560, 256, 200, 70)
    eyes = " ".join(blossom(x, 520, 84, 0) for x in (cx - 90, cx + 90))
    features = (path(eyes, "#2EC4B6") + path(circle(cx - 90, 520, 34), "#3B1250") + path(circle(cx + 90, 520, 34), "#3B1250")
                + path(f"M{cx} 590 C{cx - 30} 590 {cx - 34} 640 {cx} 650 C{cx + 34} 640 {cx + 30} 590 {cx} 590 Z", "#3B1250")
                + stroke(f"M{cx - 90} 700 Q{cx} 730 {cx + 90} 700", "#3B1250", 12)
                + "".join(stroke(f"M{cx + d} 690 V740", "#3B1250", 8) for d in (-60, -20, 20, 60))
                + path(blossom(cx, 360, 70, 0), "#FF5A8A") + path(circle(cx, 360, 16), "#FFD21F"))
    # Papel picado: four flags on a string, each with a cut-out and a scalloped hem.
    flags = []
    cols = ["#FF8A00", "#8E44FF", "#FFD21F", "#2EC4B6"]
    for i, c in enumerate(cols):
        x0 = 330 + i * 116
        hem = " ".join(f"L{f(x0 + 104 - k * 13)} {f(210 + (10 if k % 2 else 0))}" for k in range(9))
        d = f"M{x0} 60 H{x0 + 104} V210 {hem} Z " + star(x0 + 52, 132, 30, 14) + " " + circle(x0 + 52, 132, 44)
        d = f"M{x0} 60 H{x0 + 104} V210 {hem} Z " + blossom(x0 + 52, 130, 44, 0)
        flags.append(path(d, c, EO))
    string = stroke("M300 60 H790", "#FFFFFF", 6)

    def marigold(x, y, r):
        return polar(x, y, lambda t: r * (1 + .12 * math.cos(14 * t)))
    marigolds = (path(marigold(230, 830, 92), "#FF8A00") + path(marigold(230, 830, 50), "#FFB300")
                 + path(marigold(720, 900, 70), "#FF8A00") + path(marigold(720, 900, 38), "#FFB300"))
    return Icon("diademuertos", "Día de Muertos", "Feliz Día de Muertos",
                ("#FF4FA3", "#B5176B"), ("#4A0A30", "#16020E"),
                [Group(Layer("features", svg(features)), shadow=0.3),
                 Group(Layer("skull", svg(path(skull, "#FFF8EE"))), shadow=0.5),
                 Group(Layer("picado", svg(string + "".join(flags) + marigolds)), shadow=0.4)],
                shelf=SHELF, asset="DiaDeMuertos")


def diwali():
    cx, cy = 512, 500

    def ring(R, n, w, turn=0):
        return " ".join(leaf(cx + R * .35 * math.cos(math.radians(turn + i * 360 / n)),
                             cy + R * .35 * math.sin(math.radians(turn + i * 360 / n)),
                             cx + R * math.cos(math.radians(turn + i * 360 / n)),
                             cy + R * math.sin(math.radians(turn + i * 360 / n)), w) for i in range(n))
    rangoli = (path(ring(280, 8, 90, 22.5), "#FF4F9A") + path(ring(190, 8, 70), "#FFB12E")
               + path(circle(cx, cy, 70), "#2EC4B6"))

    def diya(x, y, w):
        return (f"M{f(x - w / 2)} {f(y)} Q{f(x)} {f(y + 24 * w / 320)} {f(x + w / 2)} {f(y)} "
                f"C{f(x + w * .42)} {f(y + w * .38)} {f(x - w * .42)} {f(y + w * .38)} {f(x - w / 2)} {f(y)} Z")
    lamps = svg(path(diya(512, 700, 360) + " " + diya(210, 860, 170) + " " + diya(690, 880, 150), "#D9642B")
                + path(rr(420, 690, 184, 22, 11) + " " + rr(165, 853, 90, 14, 7) + " " + rr(650, 873, 80, 12, 6), "#FFB86B"))
    flames = svg(path(flame(512, 704, 72, 170) + " " + flame(210, 860, 38, 90) + " " + flame(690, 880, 34, 80), "#FFD84A"))
    return Icon("diwali", "Diwali", "Happy Diwali",
                ("#6A1FA0", "#2A0A4A"), ("#240A3C", "#08020F"),
                [Group(Layer("flames", flames), glass_shadow="layer-color", shadow=0.8),
                 Group(Layer("diyas", lamps), shadow=0.5),
                 Group(Layer("rangoli", svg(rangoli)), shadow=0.4)],
                shelf=SHELF, asset="Diwali")


def hanukkah():
    cx, bar, gap = 512, 520, 62
    arms = []
    for k in range(1, 5):
        r = k * gap
        arms.append(stroke(f"M{cx - r} {bar} A{r} {r * .9} 0 0 0 {cx + r} {bar}", "#F5C84C", 18))
    stem = path(rr(cx - 12, 380, 24, 440, 10), "#F5C84C")
    base = path(rounded_poly([(cx - 120, 850), (cx + 120, 850), (cx + 60, 800), (cx - 60, 800)], 14), "#F5C84C")
    xs = [cx + i * gap for i in range(-4, 5)]
    cups, candles, flames = [], [], []
    for i, x in enumerate(xs):
        top = 380 if i == 4 else bar
        cups.append(rr(x - 26, top - 20, 52, 26, 10))
        h = 110
        candles.append(rr(x - 13, top - 20 - h, 26, h, 8))
        flames.append(flame(x, top - 20 - h - 6, 30, 66))
    menorah = svg("".join(arms) + stem + base + path(" ".join(cups), "#F5C84C"))
    return Icon("hanukkah", "Hanukkah", "Happy Hanukkah",
                ("#3A78E6", "#153A8F"), ("#0B1A45", "#02061A"),
                [Group(Layer("flames", svg(path(" ".join(flames), "#FFD84A"))), glass_shadow="layer-color", shadow=0.8),
                 Group(Layer("candles", svg(path(" ".join(candles), "#F2F6FF"))), shadow=0.4),
                 Group(Layer("menorah", menorah), shadow=0.5)],
                shelf=SHELF, asset="Hanukkah")


def kwanzaa():
    cx, gap = 512, 76
    cols = ["#D62828", "#D62828", "#D62828", "#1A1A1A", "#1F9D4B", "#1F9D4B", "#1F9D4B"]
    candles, flames = [], []
    for i, c in enumerate(cols):
        x = cx + (i - 3) * gap
        top = 320 if i == 3 else 360 + abs(i - 3) * 14
        candles.append(path(rr(x - 22, top, 44, 600 - top, 10), c))
        flames.append(flame(x, top - 8, 32, 74))
    wood = ("M220 600 H804 Q820 600 816 616 L800 680 Q796 696 780 696 H244 Q228 696 224 680 L208 616 Q204 600 220 600 Z "
            + rr(320, 696, 384, 60, 20) + " " + rr(260, 756, 504, 54, 24))
    stripe = "".join(path(rr(250 + i * 90, 634, 60, 22, 8), c) for i, c in enumerate(
        ["#D62828", "#1A1A1A", "#1F9D4B", "#D62828", "#1A1A1A", "#1F9D4B"]))
    return Icon("kwanzaa", "Kwanzaa", "Happy Kwanzaa",
                ("#FFC857", "#E0861E"), ("#3A220C", "#120902"),
                [Group(Layer("flames", svg(path(" ".join(flames), "#FFF1A8"))), glass_shadow="layer-color", shadow=0.8),
                 Group(Layer("candles", svg("".join(candles))), shadow=0.5),
                 Group(Layer("kinara", svg(path(wood, "#7A4A22") + stripe)), shadow=0.5)],
                bubbles=("#7A4A22", WHITE), shelf=SHELF, asset="Kwanzaa")


ICONS = [lunar_new_year(), purim(), nowruz(), ramadan(), eid_al_fitr(), holi(), passover(), easter(),
         vaisakhi(), vesak(), eid_al_adha(), rosh_hashanah(), mid_autumn(), dia_de_muertos(), diwali(),
         hanukkah(), kwanzaa()]
