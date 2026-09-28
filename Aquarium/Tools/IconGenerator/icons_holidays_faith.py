"""Seasonal alternate icons for religious and cultural festivals. Each is
offered from 30 days before to 30 days after its holiday (the scheduling lives
in Swift); this module only draws them.

    python3 proof_sheet.py icons_holidays_faith <out-dir> [key ...]

Every icon is the Aquarium mark (ring and play button, at least 0.66 of full
size) with festival imagery around it: lights, lanterns, food, flowers and
seasonal things. No sacred figures, no scripture, and the mark is never set on,
merged into or made to form a sacred symbol.
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


def at(cx, cy, s):
    """A wrap that sets the mark down at (cx, cy), scaled by s."""
    return (f'<g transform="translate({f(cx)} {f(cy)}) scale({s}) translate(-512 -512)">', "</g>")


def mark(w, ring_fill, play_fill, defs=""):
    return mark_parts(ring_fill, play_fill, defs, w)


def on_ring(id_, clip_d, fill):
    """Paint on the ring: `fill` only where both the ring and `clip_d` are.
    The clip's own fill rule is ignored, so the hole comes from the even-odd
    ring inside it. Mark coordinates (the unscaled 1024 mark)."""
    return (f'<clipPath id="{id_}"><path d="{clip_d}"/></clipPath>',
            f'<g clip-path="url(#{id_})">{path(RING_D, fill, EO)}</g>')


def sq_point(cx, cy, a, t, n=4.1):
    ct, st = math.cos(t), math.sin(t)
    return (cx + a * math.copysign(abs(ct) ** (2 / n), ct), cy + a * math.copysign(abs(st) ** (2 / n), st))


# ------------------------------------------------------------------ the icons
#
# Every one is the Aquarium mark first — the ring with the play button in its
# hole, at least 0.66 of full size — with the festival around it: hung from
# it, set in front of it, growing up to it. The mark is never made into, set
# on, or put inside a sacred symbol.


def lunar_new_year():
    w = at(512, 440, .74)
    defs = lin("au", "#FFF0B8", "#E8A91C", 0, 0, 1, 1)
    ring, tri = mark(w, "url(#au)", "url(#au)", defs)

    def lantern(cx, cy, wd, h, cord_top):
        rx, ry = wd / 2, h / 2
        body = path(ell(cx, cy, rx, ry), "#FF5536")
        ribs = (stroke(ell(cx, cy, rx * .52, ry - 4), "#C81E28", wd * .03)
                + stroke(f"M{f(cx)} {f(cy - ry + 4)} V{f(cy + ry - 4)}", "#C81E28", wd * .03))
        cw, ch = wd * .56, h * .16
        gold = (path(rr(cx - cw / 2, cy - ry - ch * .55, cw, ch, ch * .35), "#FFD35A")
                + path(rr(cx - cw / 2, cy + ry - ch * .45, cw, ch, ch * .35), "#FFD35A")
                + path(rr(cx - wd * .03, cy + ry + ch * .5, wd * .06, h * .12, wd * .02), "#FFD35A")
                + path(rounded_poly([(cx - wd * .08, cy + ry + h * .24), (cx + wd * .08, cy + ry + h * .24),
                                     (cx + wd * .12, cy + ry + h * .5), (cx - wd * .12, cy + ry + h * .5)], wd * .03),
                       "#FFD35A")
                + path(rr(cx - 4, cord_top, 8, cy - ry - ch * .5 - cord_top, 4), "#FFD35A"))
        return body + ribs, gold
    b1, g1 = lantern(364, 796, 184, 146, 650)
    b2, g2 = lantern(652, 778, 150, 120, 650)
    branch = stroke("M1000 40 C900 80 820 150 700 200 M840 132 C880 180 900 210 930 250", "#5A1A12", 16)
    flowers = (path(blossom(700, 206, 52, 10) + " " + blossom(820, 142, 44, 40) + " " + blossom(920, 250, 36, 0),
                    "#FFC2D4")
               + dots([(700, 206, 11, 1), (820, 142, 9, 1), (920, 250, 8, 1)], "#FFD35A"))
    return Icon("lunarnewyear", "Lunar New Year", "Happy Lunar New Year",
                ("#D7263D", "#8E0B1E"), ("#48091A", "#140206"),
                [Group(Layer("gold", svg(g1 + g2)), Layer("lanterns", svg(b1 + b2)), shadow=0.5),
                 Group(Layer("blossom", svg(branch + flowers)), shadow=0.4),
                 Group(Layer("play", tri), shadow=0.6),
                 Group(Layer("ring", ring))],
                shelf=SHELF, asset="LunarNewYear")


def purim():
    w = at(548, 520, .72)
    ring, tri = mark(w, "#FFD23F", "#FF5FA8")
    mask_d = ("M512 380 C566 330 668 296 752 312 C764 392 730 478 664 506 C612 528 556 506 512 468 "
              "C468 506 412 528 360 506 C294 478 260 392 272 312 C356 296 458 330 512 380 Z "
              + ell(410, 418, 62, 38, 14) + " " + ell(614, 418, 62, 38, -14))
    feathers = (path(leaf(712, 320, 700, 120, 34, .05), "#FF5FA8")
                + path(leaf(724, 320, 790, 160, 30, -.04), "#FFFFFF")
                + path(leaf(700, 324, 612, 150, 30, .05), "#FFE066"))
    trim = dots([(512, 408, 12, 1), (340, 470, 9, 1), (684, 470, 9, 1), (300, 350, 8, 1), (724, 350, 8, 1)], "#FF5FA8")
    # Tipped onto the ring's top-left corner, the way you'd wear one.
    mask = svg('<g transform="translate(380 306) rotate(-22) scale(.66) translate(-512 -410)">'
               + feathers + path(mask_d, "#3FD9C8", EO) + trim + "</g>")

    def cookie(cx, cy, s, turn):
        pts = [(cx + s * math.cos(math.radians(turn - 90 + i * 120)),
                cy + s * math.sin(math.radians(turn - 90 + i * 120))) for i in range(3)]
        return rounded_poly(pts, s * .42)
    cookies = svg(path(cookie(230, 800, 120, -8), "#F4C27A") + path(cookie(410, 890, 96, 14), "#F4C27A")
                  + path(circle(230, 810, 32), "#A31D4C") + path(circle(410, 898, 26), "#E8742A"))
    confetti = svg(dots([(120, 560, 12, .9), (200, 440, 8, .8), (860, 250, 11, .9), (720, 120, 9, .8),
                         (460, 130, 10, .8), (560, 960, 9, .7)], "#FFE066")
                   + dots([(90, 700, 9, .8), (610, 80, 8, .8), (930, 150, 8, .7), (300, 150, 7, .7)], "#3FD9C8"))
    return Icon("purim", "Purim", "Chag Purim sameach",
                ("#8A4FFF", "#4B1FB0"), ("#241048", "#0A0418"),
                [Group(Layer("mask", mask), Layer("hamantaschen", cookies), shadow=0.5),
                 Group(Layer("play", tri), shadow=0.6),
                 Group(Layer("ring", ring)),
                 Group(Layer("confetti", confetti, glass=False), shadow=0, translucency=0)],
                diagonal=True, shelf=SHELF, asset="Purim")


def nowruz():
    w = at(512, 430, .72)
    ring, tri = mark(w, "#E63946", "#E63946")
    # The sabzeh: sprouts from a dish at the ring's foot, up over its lower edge.
    blades = []
    n = 25
    for i in range(n):
        t = i / (n - 1) * 2 - 1
        bx = 512 + t * 190
        tx = 512 + t * 250 + (14 if i % 2 else -14)
        ty = 640 + abs(t) ** 1.4 * 70 + (0 if i % 2 else 34)
        blades.append(leaf(bx, 800, tx, ty, 20, .05 * t))
    grass = svg(path(" ".join(blades), "#5CC73A"))
    dish = (path("M306 790 H718 C708 880 628 912 512 912 C396 912 316 880 306 790 Z", "#1E9E9A")
            + path(rr(290, 774, 444, 34, 17), "#FFD166"))
    eggs = (path(egg(170, 860, 104, 136), "#FF8FAB") + path(rr(120, 864, 100, 24, 12), "#FFE066"))
    sprig = (stroke("M1010 40 C940 90 880 120 800 150", "#8A5A44", 12)
             + path(blossom(800, 150, 50, 0), "#FF9EC4") + path(blossom(900, 96, 40, 30), WHITE)
             + dots([(800, 150, 10, 1), (900, 96, 8, 1)], "#FFD166"))
    return Icon("nowruz", "Nowruz", "Nowruz mobarak",
                ("#A8E4FF", "#4FA6E8"), ("#0E2A4A", "#03101F"),
                [Group(Layer("dish", svg(dish + eggs + sprig)), shadow=0.5),
                 Group(Layer("sabzeh", grass), shadow=0.4),
                 Group(Layer("play", tri), shadow=0.6),
                 Group(Layer("ring", ring))],
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
    w = at(584, 548, .7)
    defs = lin("au", "#FFF0B8", "#E0A21A", 0, 0, 1, 1)
    ring, tri = mark(w, "url(#au)", "#FFF3C4", defs)
    fr, gl = fanous("#F5C451", "#FFE9A8")
    x, y, s = 212, 560, .62
    chain = path(rr(x - 4, 0, 8, y - 288 * s + 4, 4), "#F5C451")
    frame = svg(chain + tr(fr, x, y, s))
    glow = svg(tr(gl, x, y, s))
    # The moon is up in the sky, well clear of the mark.
    moon = path(crescent((770, 172), 100, (818, 136), 84), "#FFF3C4")
    stars = twinkles([(560, 120, 20, .9), (420, 210, 12, .7), (950, 300, 12, .6), (380, 930, 14, .6),
                      (120, 860, 16, .7), (640, 960, 10, .5)])
    return Icon("ramadan", "Ramadan", "Ramadan kareem",
                ("#2A3F99", "#0C1438"), ("#0E1640", "#02040E"),
                [Group(Layer("frame", frame), Layer("glow", glow), shadow=0.5),
                 Group(Layer("play", tri), shadow=0.6),
                 Group(Layer("ring", ring)),
                 Group(Layer("moon", svg(moon)), Layer("stars", svg(stars), glass=False), shadow=0.4)],
                shelf=SHELF, asset="Ramadan")


def eid_al_fitr():
    w = at(512, 470, .72)
    ring, tri = mark(w, "#FFF6DC", "#FFD86B")
    # A string of lights draped over the top of the ring.
    p0, c, p1 = (70, 160), (512, 370), (954, 160)
    wire = stroke(f"M{p0[0]} {p0[1]} Q{c[0]} {c[1]} {p1[0]} {p1[1]}", "#E9FFF4", 6, ' opacity=".85"')
    bulbs = []
    colors = ["#FF6B6B", "#FFD86B", "#6BC5FF", "#FF9FE0", "#FFB347", "#B8F28A"]
    for i in range(10):
        t = (i + .5) / 10
        bx = (1 - t) ** 2 * p0[0] + 2 * (1 - t) * t * c[0] + t * t * p1[0]
        by = (1 - t) ** 2 * p0[1] + 2 * (1 - t) * t * c[1] + t * t * p1[1]
        bulbs.append(path(rr(bx - 9, by - 4, 18, 16, 5), "#E9FFF4") + path(ell(bx, by + 34, 20, 28), colors[i % 6]))
    lights = svg(wire + "".join(bulbs))
    plate = path(ell(440, 900, 230, 44), WHITE)
    sweets = "".join(path(f"M{x - r} {y} A{r} {r * .9} 0 0 1 {x + r} {y} Z", col)
                     for x, y, r, col in [(330, 896, 66, "#F2C37A"), (440, 880, 76, "#E8A95C"), (550, 896, 66, "#F2C37A")])
    dates = path(ell(410, 800, 26, 15, -12) + " " + ell(470, 798, 26, 15, 10), "#7A3B1E")
    return Icon("eidalfitr", "Eid al-Fitr", "Eid Mubarak",
                ("#20C08A", "#0A6B4A"), ("#07402C", "#02120C"),
                [Group(Layer("lights", lights), Layer("sweets", svg(plate + sweets + dates)), shadow=0.5),
                 Group(Layer("play", tri), shadow=0.6),
                 Group(Layer("ring", ring))],
                shelf=SHELF, asset="EidAlFitr")


def holi():
    import random
    rnd = random.Random(7)
    w = at(512, 512, .74)
    defs = lin("hp", "#FF2E88", "#FF8A1A", 0, 0, 1, 1)
    ring, tri = mark(w, "url(#hp)", "#1FA8F0", defs)

    def burst(cx, cy, R):
        puffs = [circle(cx, cy, R * .72)]
        for i in range(9):
            a = i / 9 * 2 * math.pi + rnd.uniform(-.25, .25)
            d = R * rnd.uniform(.42, .62)
            puffs.append(circle(cx + d * math.cos(a), cy + d * math.sin(a), R * rnd.uniform(.3, .46)))
        return " ".join(puffs)

    def spray(cx, cy, R, n=7):
        base = math.atan2(cy - 512, cx - 512)
        out = []
        for i in range(n):
            a = base + rnd.uniform(-1.0, 1.0)
            d = R * rnd.uniform(1.1, 1.45)
            out.append(circle(cx + d * math.cos(a), cy + d * math.sin(a), R * rnd.uniform(.06, .12)))
        return " ".join(out)
    clouds = svg("".join(path(burst(x, y, R) + " " + spray(x, y, R), col) for x, y, R, col in
                         [(770, 250, 150, "#FFD21F"), (250, 790, 150, "#35D06B"),
                          (250, 250, 118, "#8E44FF"), (760, 770, 110, "#2EC4FF")]))
    # Powder that landed on the ring.
    splash = svg(dots([(300, 380, 16, 1), (322, 350, 9, 1), (286, 420, 7, 1)], "#FFD21F")
                 + dots([(720, 650, 17, 1), (700, 690, 9, 1), (742, 624, 7, 1)], "#35D06B")
                 + dots([(610, 300, 13, 1), (640, 290, 7, 1)], "#2EC4FF")
                 + dots([(380, 720, 14, 1), (410, 736, 7, 1)], "#8E44FF"))
    return Icon("holi", "Holi", "Happy Holi",
                ("#FFF8EC", "#FFE2C4"), ("#2A1034", "#0A0410"),
                [Group(Layer("splash", splash), Layer("play", tri), shadow=0.5),
                 Group(Layer("ring", ring)),
                 Group(Layer("powder", clouds), shadow=0.3)],
                bubbles=("#B0206A", WHITE), shelf=SHELF, asset="Holi")


def passover():
    w = at(512, 420, .72)
    ring, tri = mark(w, "#E9EEF7", "#C21D45")

    def matzah(x, y, s, turn, tone, hole):
        d = rr(x, y, s, s, 22) + "".join(" " + circle(x + s * (c + 1) / 6, y + s * (r + 1) / 6, 7)
                                          for r in range(5) for c in range(5))
        toast = "".join(f'<rect x="{f(x + s * (c + 1) / 6 - 3)}" y="{f(y + 16)}" width="6" height="{f(s - 32)}" '
                        f'rx="3" fill="{hole}" opacity=".6"/>' for c in range(5))
        return f'<g transform="rotate({turn} {f(x + s / 2)} {f(y + s / 2)})">{path(d, tone, EO)}{toast}</g>'
    back = svg(matzah(210, 630, 250, 12, "#E2BE82", "#C99A58"))
    front = svg(matzah(160, 680, 260, -8, "#F6E3BC", "#D9A55E"))
    cx, T = 690, 640
    cup = (f"M{cx - 66} {T} H{cx + 66} C{cx + 66} {T + 110} {cx + 40} {T + 160} {cx} {T + 166} "
           f"C{cx - 40} {T + 160} {cx - 66} {T + 110} {cx - 66} {T} Z "
           + rr(cx - 8, T + 160, 16, 100, 6) + " "
           + f"M{cx - 64} {T + 296} C{cx - 60} {T + 266} {cx - 26} {T + 254} {cx} {T + 254} "
             f"C{cx + 26} {T + 254} {cx + 60} {T + 266} {cx + 64} {T + 296} Z")
    wine_defs = (f'<clipPath id="wl"><rect x="0" y="{T + 44}" width="1024" height="200"/></clipPath>'
                 f'<clipPath id="wb"><path d="M{cx - 56} {T} H{cx + 56} C{cx + 56} {T + 104} {cx + 32} {T + 150} '
                 f'{cx} {T + 154} C{cx - 32} {T + 150} {cx - 56} {T + 104} {cx - 56} {T} Z"/></clipPath>')
    wine = svg(f'<g clip-path="url(#wl)"><g clip-path="url(#wb)"><rect width="1024" height="1024" fill="#B3163C"/></g></g>',
               wine_defs)
    return Icon("passover", "Passover", "Chag Pesach sameach",
                ("#4A7CE8", "#1B3A8C"), ("#10204C", "#03081A"),
                [Group(Layer("wine", wine), Layer("cup", svg(path(cup, "#E9EEF7"))), shadow=0.5),
                 Group(Layer("matzah", front), Layer("matzah-back", back), shadow=0.5),
                 Group(Layer("play", tri, mono=mark(w, WHITE, WHITE)[1]), shadow=0.6),
                 Group(Layer("ring", ring))],
                shelf=SHELF, asset="Passover")


def easter():
    W = at(512, 470, .74)
    # The ring painted like an egg: zigzag bands and dots, in mark coordinates.
    def zig(y, amp, h, step=46):
        top = [(x, y + (-amp if (x // step) % 2 else amp)) for x in range(150, 900, step)]
        pts = [(x, yy - h) for x, yy in top] + [(x, yy + h) for x, yy in reversed(top)]
        return poly(pts)
    spots = " ".join(circle(x, y, 17) for y in (378, 646) for x in (242, 782)) + " " + \
        " ".join(circle(x, y, 15) for y in (242, 782) for x in (330, 694))
    c1, g1 = on_ring("z1", zig(250, 16, 20) + " " + zig(774, 16, 20), WHITE)
    c2, g2 = on_ring("z2", zig(512, 16, 22), "#FFE066")
    c3, g3 = on_ring("sp", spots, "#7FD6FF")
    paint = svg(W[0] + g1 + g2 + g3 + W[1], c1 + c2 + c3)
    ring, tri = mark(W, "#FF7FB0", "#7A5AF0")
    tri_w = mark(W, WHITE, WHITE)[1]
    grass = []
    for i in range(18):
        x = 20 + i * 26
        y = 1024 - 150 * math.sqrt(max(0, 1 - ((x - 230) / 300) ** 2)) + 18
        h = 60 + (i * 53) % 50
        grass.append(leaf(x, y, x + ((i * 31) % 40 - 20), y - h, 14))
    meadow = (path(" ".join(grass) + " " + ell(230, 1024, 300, 150), "#58C26A")
              + path(blossom(130, 850, 42) + " " + blossom(330, 890, 36, 20), WHITE)
              + path(blossom(230, 800, 34, 10), "#FFB3D1")
              + dots([(130, 850, 10, 1), (330, 890, 9, 1), (230, 800, 8, 1)], "#FFD21F")
              + path(blossom(800, 170, 40, 0) + " " + blossom(890, 250, 30, 20), WHITE)
              + dots([(800, 170, 9, 1), (890, 250, 7, 1)], "#FFD21F"))
    return Icon("easter", "Easter", "Happy Easter",
                ("#D9C8FF", "#A58AF0"), ("#2B1E52", "#0C0718"),
                [Group(Layer("flowers", svg(meadow)), shadow=0.4),
                 Group(Layer("play", tri, tri_w, mono=tri_w), shadow=0.5),
                 Group(Layer("paint", paint), Layer("ring", ring))],
                bubbles=("#5B3FB8", WHITE), shelf=SHELF, asset="Easter")


def vaisakhi():
    w = at(512, 430, .72)
    ring, tri = mark(w, "#FF9933", "#FFF1B8")
    heads, stalks = [], []
    tie = (512, 842)
    for side in (-1, 1):
        for k, ang in enumerate((52, 64, 76)):
            th = math.radians(ang) * side
            ux, uy = math.sin(th), -math.cos(th)
            L = 220 - k * 10
            top = (tie[0] + ux * L, tie[1] + uy * L)
            stalks.append(stroke(f"M{f(tie[0] - ux * 60)} {f(tie[1] - uy * 60)} L{f(top[0])} {f(top[1])}", "#FFD66B", 17))
            px, py = -uy, ux
            for j in range(5):
                d = j * 28
                gx, gy = top[0] + ux * d, top[1] + uy * d
                for sd in (-1, 1):
                    ex, ey = gx + px * sd * 20 + ux * 36, gy + py * sd * 20 + uy * 36
                    heads.append(ell((gx + ex) / 2, (gy + ey) / 2, 26, 15, math.degrees(math.atan2(ey - gy, ex - gx))))
            heads.append(ell(top[0] + ux * 150, top[1] + uy * 150, 22, 12, math.degrees(math.atan2(uy, ux))))
            tx, ty = top[0] + ux * 164, top[1] + uy * 164
            heads.append(leaf(tx, ty, tx + ux * 44, ty + uy * 44, 4))
    band = path(rr(462, 816, 100, 50, 20), "#1E3A8A")
    return Icon("vaisakhi", "Vaisakhi", "Vaisakhi diyan vadhaiyan",
                ("#3057C7", "#152A70"), ("#0C1638", "#030612"),
                [Group(Layer("grain", svg(path(" ".join(heads), "#FFF1B8") + band)), shadow=0.5),
                 Group(Layer("stalks", svg("".join(stalks))), shadow=0.4),
                 Group(Layer("play", tri), shadow=0.6),
                 Group(Layer("ring", ring))],
                shelf=SHELF, asset="Vaisakhi")


def vesak():
    w = at(512, 500, .7)
    ring, tri = mark(w, "#FFD86B", WHITE)

    def lantern(cx, cy, r, col):
        return (path(rr(cx - 3, 0, 6, cy - r, 3), "#FFE9B0") + path(circle(cx, cy, r), col)
                + path(rr(cx - r * .45, cy - r - 10, r * .9, 18, 7), "#FFE9B0")
                + path(rr(cx - r * .45, cy + r - 8, r * .9, 18, 7), "#FFE9B0"))
    lanterns = svg(lantern(340, 150, 54, "#FFB347") + lantern(512, 110, 58, "#FF8FB1") + lantern(690, 150, 54, "#9FD8FF"))

    def lotus(cx, base, s):
        front = " ".join([leaf(cx, base, cx, base - 330 * s, 84 * s),
                          leaf(cx - 10 * s, base, cx - 180 * s, base - 250 * s, 74 * s, .05),
                          leaf(cx + 10 * s, base, cx + 180 * s, base - 250 * s, 74 * s, -.05)])
        back = " ".join([leaf(cx - 20 * s, base, cx - 100 * s, base - 320 * s, 74 * s, .02),
                         leaf(cx + 20 * s, base, cx + 100 * s, base - 320 * s, 74 * s, -.02),
                         leaf(cx - 30 * s, base, cx - 260 * s, base - 140 * s, 64 * s, .08),
                         leaf(cx + 30 * s, base, cx + 260 * s, base - 140 * s, 64 * s, -.08)])
        return front, back, ell(cx, base + 20 * s, 240 * s, 46 * s)
    # Two blooms at the foot, off to either side — decoration, not a seat.
    f1, b1, p1 = lotus(214, 900, .5)
    f2, b2, p2 = lotus(690, 930, .38)
    flowers = svg(path(p1 + " " + p2, "#2FB67E") + path(b1 + " " + b2, "#FF6FA8") + path(f1 + " " + f2, "#FFB3D1"))
    return Icon("vesak", "Vesak", "Happy Vesak",
                ("#4B3AA8", "#171253"), ("#16103E", "#05030F"),
                [Group(Layer("lanterns", lanterns), Layer("lotus", flowers), shadow=0.5),
                 Group(Layer("play", tri), shadow=0.6),
                 Group(Layer("ring", ring))],
                shelf=SHELF, asset="Vesak")


def eid_al_adha():
    W = at(512, 570, .72)
    # The ring inlaid with eight-point stars, like a tiled lattice.
    stars = []
    for j, y in enumerate(range(200, 860, 78)):
        for x in range(200 + (39 if j % 2 else 0), 860, 78):
            stars.append(star(x, y, 30, 18, points=8, rot=-90 + 22.5))
    cdef, inlay = on_ring("st", " ".join(stars), "#FFF1C9")
    defs = lin("au", "#F9D98A", "#D9962A", 0, 0, 1, 1)
    ring, tri = mark(W, "url(#au)", "#FFF4D6", defs)
    pattern = svg(W[0] + inlay + W[1], cdef)

    def lamp(x, top, s):
        body = rounded_poly([(x - 34 * s, top + 40 * s), (x + 34 * s, top + 40 * s), (x + 46 * s, top + 100 * s),
                             (x + 24 * s, top + 150 * s), (x - 24 * s, top + 150 * s), (x - 46 * s, top + 100 * s)], 8 * s)
        cap = f"M{f(x - 30 * s)} {f(top + 40 * s)} Q{f(x)} {f(top - 10 * s)} {f(x + 30 * s)} {f(top + 40 * s)} Z"
        tip = rounded_poly([(x - 18 * s, top + 150 * s), (x + 18 * s, top + 150 * s), (x, top + 190 * s)], 4 * s)
        return (path(rr(x - 3, 0, 6, top, 3), "#F4C66A") + path(body, "#FFB547")
                + path(cap + " " + tip, "#F4C66A"))
    lamps = svg(lamp(330, 90, .95) + lamp(512, 40, .85) + lamp(700, 90, .95))
    specks = dots([(150, 620, 10, .7), (880, 300, 8, .6), (130, 460, 7, .5), (300, 950, 8, .5), (640, 970, 7, .5)], "#F4C66A")
    return Icon("eidaladha", "Eid al-Adha", "Eid al-Adha Mubarak",
                ("#9A2F74", "#43103A"), ("#300A28", "#0E020B"),
                [Group(Layer("lamps", lamps), shadow=0.5),
                 Group(Layer("play", tri), shadow=0.6),
                 Group(Layer("pattern", pattern), Layer("ring", ring)),
                 Group(Layer("specks", svg(specks), glass=False), shadow=0, translucency=0)],
                shelf=SHELF, asset="EidAlAdha")


def rosh_hashanah():
    w = at(512, 420, .72)
    ring, tri = mark(w, "#C0183A", "#C0183A")
    ring_d, tri_d = mark(w, "#E8475F", "#E8475F")
    ring_m, tri_m = mark(w, WHITE, WHITE)
    apple = ("M-66 -150 C-150 -190 -270 -150 -270 0 C-270 150 -170 260 -70 260 C-40 260 -24 248 0 248 "
             "C24 248 40 260 70 260 C170 260 270 150 270 0 C270 -150 150 -190 66 -150 C36 -134 -36 -134 -66 -150 Z")
    fruit = tr(path(apple, "#E3262E") + path(ell(-170, -30, 34, 70, 20), WHITE, ' opacity=".4"')
               + stroke("M-8 -140 C-10 -200 4 -240 36 -268", "#6B3A1E", 22)
               + path(leaf(20, -236, 170, -300, 44, .05), "#58B947"), 320, 800, .46)
    jx, jw, jt = 560, 160, 700
    jar = rr(jx, jt + 34, jw, 196, 44) + " " + rr(jx + 14, jt, jw - 28, 44, 14)
    honey = rr(jx + 12, jt + 84, jw - 24, 136, 34)
    lid = (f"M{jx - 10} {jt} Q{jx + jw / 2} {jt - 46} {jx + jw + 10} {jt} "
           f"L{jx + jw} {jt + 38} Q{jx + jw / 2} {jt + 20} {jx} {jt + 38} Z")
    drip = (f"M{jx + 36} {jt + 30} C{jx + 36} {jt + 66} {jx + 50} {jt + 80} {jx + 50} {jt + 96} "
            f"A14 14 0 0 1 {jx + 22} {jt + 96} C{jx + 22} {jt + 80} {jx + 36} {jt + 66} {jx + 36} {jt + 30} Z")
    jar_l = svg(path(jar, "#FFF4DA", ' opacity=".92"'))
    honey_l = svg(path(honey, "#F2A516") + path(lid, "#D9482B") + path(drip, "#F2A516"))
    return Icon("roshhashanah", "Rosh Hashanah", "Shana tova",
                ("#FFE7A3", "#F5B83A"), ("#3A2208", "#120A02"),
                [Group(Layer("apple", svg(fruit)), Layer("honey", honey_l), Layer("jar", jar_l), shadow=0.5),
                 Group(Layer("play", tri, tri_d, mono=tri_m), shadow=0.5),
                 Group(Layer("ring", ring, ring_d, mono=ring_m), translucency=0.2)],
                bubbles=("#9A5A0A", "#FFD27A"), shelf=SHELF, asset="RoshHashanah")


def mid_autumn():
    w = at(512, 440, .72)
    ring, tri = mark(w, "#E0283A", "#E0283A")
    # The full moon behind the ring, glowing round it and through its window.
    moon = svg(path(circle(526, 426, 292), "#FFE9A8"))
    # Tinted and Clear read luminance: a full-strength disc would swallow the ring.
    moon_m = svg(path(circle(526, 426, 292), WHITE, ' opacity=".35"'))
    stars = twinkles([(140, 560, 16, .8), (240, 420, 10, .6), (930, 700, 12, .5), (120, 700, 10, .5)])

    def mooncake(cx, cy, R):
        return (path(polar(cx, cy, lambda t: R * (1 + .05 * math.cos(12 * t))), "#D98E3A")
                + stroke(circle(cx, cy, R * .7), "#F2B866", R * .07)
                + path(blossom(cx, cy, R * .46), "#F2B866") + path(circle(cx, cy, R * .12), "#D98E3A"))
    cakes = mooncake(600, 880, 100) + mooncake(460, 930, 70)
    rabbit = (path(ell(0, 0, 110, 78), WHITE) + path(ell(-96, -36, 44, 38), WHITE)
              + path(leaf(-90, -64, -70, -190, 30, -.05), WHITE)
              + path(leaf(-110, -64, -150, -180, 28, .05), WHITE)
              + path(circle(-108, -44, 9), "#E0283A") + path(leaf(-84, -80, -72, -160, 10), "#FF8FA8")
              + path(ell(10, 0, 44, 20), "#FF8FA8")
              + stroke("M60 -60 Q90 -150 130 -200", "#8A5A2B", 10)
              + path(circle(-40, 88, 24), "#E0283A") + path(circle(60, 88, 24), "#E0283A"))
    return Icon("midautumn", "Mid-Autumn", "Happy Mid-Autumn Festival",
                ("#2A4A92", "#0C1840"), ("#0C1638", "#02050F"),
                [Group(Layer("rabbit", svg(tr(rabbit, 250, 830, .72))), Layer("cakes", svg(cakes)), shadow=0.5),
                 Group(Layer("play", tri), shadow=0.6),
                 Group(Layer("ring", ring), translucency=0.1),
                 Group(Layer("moon", moon, mono=moon_m), Layer("stars", svg(stars), glass=False),
                       glass_shadow="layer-color", shadow=0.4)],
                shelf=SHELF, asset="MidAutumn")


def dia_de_muertos():
    cx, cy, s = 512, 470, .72
    w = at(cx, cy, s)
    ring, tri = mark(w, "#FFF8EE", "#2EC4B6")

    def marigold(x, y, r):
        return polar(x, y, lambda t: r * (1 + .12 * math.cos(14 * t)))
    # A garland of marigolds slung around the lower half of the ring.
    outer, inner, leaves = [], [], []
    n = 11
    for i in range(n):
        t = math.radians(-8 + i * 196 / (n - 1))
        x, y = sq_point(cx, cy, 266, t)
        r = 50 if i % 2 else 42
        outer.append(marigold(x, y, r))
        inner.append(marigold(x, y, r * .52))
        if i % 3 == 1:
            lx, ly = sq_point(cx, cy, 300, t + .12)
            leaves.append(leaf(x, y, lx, ly, 14))
    garland = (path(" ".join(leaves), "#2FA84F") + path(" ".join(outer), "#FF8A00")
               + path(" ".join(inner), "#FFC21F"))
    flags = []
    cols = ["#FF8A00", "#8E44FF", "#FFD21F", "#2EC4B6"]
    for i, col in enumerate(cols):
        x0 = 330 + i * 116
        hem = " ".join(f"L{f(x0 + 104 - k * 13)} {f(190 + (10 if k % 2 else 0))}" for k in range(9))
        d = f"M{x0} 50 H{x0 + 104} V190 {hem} Z " + blossom(x0 + 52, 116, 40, 0)
        flags.append(path(d, col, EO))
    picado = svg(stroke("M300 50 H790", WHITE, 6) + "".join(flags))
    return Icon("diademuertos", "Día de Muertos", "Feliz Día de Muertos",
                ("#FF4FA3", "#B5176B"), ("#4A0A30", "#16020E"),
                [Group(Layer("garland", svg(garland)), shadow=0.5),
                 Group(Layer("play", tri), shadow=0.6),
                 Group(Layer("ring", ring)),
                 Group(Layer("picado", picado), shadow=0.4)],
                shelf=SHELF, asset="DiaDeMuertos")


def diwali():
    W = at(512, 450, .72)
    ring, tri = mark(W, "#FF4F9A", "#FFD84A")
    # Rangoli on the ring: two chalk lines round it and a row of dots.
    lines = (stroke(squircle(512 - 300, 512 - 300, 600, 600, 4.1), "#FFB12E", 9)
             + stroke(squircle(512 - 240, 512 - 240, 480, 480, 4.0), "#FFB12E", 9))
    pts = [sq_point(512, 512, 270, i / 28 * 2 * math.pi) for i in range(28)]
    beads = (path(" ".join(circle(x, y, 17) for i, (x, y) in enumerate(pts) if i % 2 == 0), "#2EC4B6")
             + path(" ".join(circle(x, y, 9) for i, (x, y) in enumerate(pts) if i % 2), WHITE))
    rangoli = svg(W[0] + lines + beads + W[1])

    def diya(x, y, wd):
        return (f"M{f(x - wd / 2)} {f(y)} Q{f(x)} {f(y + 24 * wd / 320)} {f(x + wd / 2)} {f(y)} "
                f"C{f(x + wd * .42)} {f(y + wd * .38)} {f(x - wd * .42)} {f(y + wd * .38)} {f(x - wd / 2)} {f(y)} Z")
    spots = [(512, 820, 230), (250, 870, 150), (720, 890, 130)]
    lamps = svg(path(" ".join(diya(x, y, wd) for x, y, wd in spots), "#D9642B")
                + path(" ".join(rr(x - wd * .26, y - 8, wd * .52, 16, 8) for x, y, wd in spots), "#FFB86B"))
    flames = svg(path(" ".join(flame(x, y + 2, wd * .2, wd * .46) for x, y, wd in spots), "#FFD84A"))
    return Icon("diwali", "Diwali", "Happy Diwali",
                ("#6A1FA0", "#2A0A4A"), ("#240A3C", "#08020F"),
                [Group(Layer("flames", flames), glass_shadow="layer-color", shadow=0.8),
                 Group(Layer("diyas", lamps), Layer("play", tri), shadow=0.5),
                 Group(Layer("rangoli", rangoli), Layer("ring", ring))],
                shelf=SHELF, asset="Diwali")


def hanukkah():
    W = at(560, 450, .72)
    defs = lin("ag", "#FFFFFF", "#B6CBEF", 0, 0, 1, 1)
    ring, tri = mark(W, "url(#ag)", "url(#ag)", defs)
    stripe = svg(W[0] + stroke(squircle(512 - 270, 512 - 270, 540, 540, 4.1), "#2A5FD0", 16) + W[1])
    # A dreidel spinning beside the mark, and a little gelt.
    body = (rr(-14, -176, 28, 76, 10) + " " + rr(-88, -110, 176, 160, 26) + " "
            + rounded_poly([(-88, 30), (88, 30), (0, 150)], 18))
    dreidel = tr(path(body, "#F5C84C") + path(rr(-88, -44, 176, 30, 6), "#2A5FD0"), 200, 780, .95, -14)
    gelt = (path(circle(380, 900, 52) + " " + circle(478, 936, 42), "#F5C84C")
            + stroke(circle(380, 900, 38) + " " + circle(478, 936, 30), "#D9A21E", 6))
    glints = twinkles([(120, 520, 20, .9), (250, 380, 12, .7), (930, 180, 16, .8), (620, 960, 12, .6)])
    return Icon("hanukkah", "Hanukkah", "Happy Hanukkah",
                ("#3A78E6", "#153A8F"), ("#0B1A45", "#02061A"),
                [Group(Layer("dreidel", svg(dreidel + gelt)), shadow=0.5),
                 Group(Layer("play", tri), shadow=0.6),
                 Group(Layer("stripe", stripe), Layer("ring", ring)),
                 Group(Layer("glints", svg(glints), glass=False), shadow=0, translucency=0)],
                shelf=SHELF, asset="Hanukkah")


def kwanzaa():
    W = at(596, 400, .66)
    bands = [(190, 405, "#D62828"), (405, 619, "#1A1A1A"), (619, 840, "#1F9D4B")]
    clips = "".join(f'<clipPath id="k{i}"><rect x="0" y="{a}" width="1024" height="{b - a + 1}"/></clipPath>'
                    for i, (a, b, _) in enumerate(bands))
    ring = svg(W[0] + "".join(f'<g clip-path="url(#k{i})">{path(RING_D, c, EO)}</g>'
                              for i, (a, b, c) in enumerate(bands)) + W[1], clips)
    _, tri = mark(W, WHITE, "#D62828")
    ring_m, tri_m = mark(W, WHITE, WHITE)
    # The kinara stands beside the mark, down to the left.
    cols = ["#D62828", "#D62828", "#D62828", "#1A1A1A", "#1F9D4B", "#1F9D4B", "#1F9D4B"]
    ccx, gap = 300, 52
    candles, flames = [], []
    for i, c in enumerate(cols):
        x = ccx + (i - 3) * gap
        top = 640 if i == 3 else 670 + abs(i - 3) * 10
        candles.append((rr(x - 16, top, 32, 810 - top, 8), c))
        flames.append(flame(x, top - 6, 24, 56))
    cand = svg("".join(path(d, c) for d, c in candles))
    cand_m = svg(path(" ".join(d for d, _ in candles), WHITE))
    wood = (f"M{ccx - 196} 806 H{ccx + 196} Q{ccx + 208} 806 {ccx + 205} 818 L{ccx + 194} 862 Q{ccx + 191} 874 {ccx + 179} 874 "
            f"H{ccx - 179} Q{ccx - 191} 874 {ccx - 194} 862 L{ccx - 205} 818 Q{ccx - 208} 806 {ccx - 196} 806 Z "
            + rr(ccx - 130, 874, 260, 40, 14) + " " + rr(ccx - 170, 914, 340, 38, 16))
    stripe = "".join(path(rr(ccx - 170 + i * 58, 830, 42, 16, 6), c) for i, c in enumerate(
        ["#D62828", "#1A1A1A", "#1F9D4B", "#D62828", "#1A1A1A", "#1F9D4B"]))
    kinara = svg(path(wood, "#7A4A22") + stripe)
    kinara_m = svg(path(wood, WHITE))
    return Icon("kwanzaa", "Kwanzaa", "Happy Kwanzaa",
                ("#FFC857", "#E0861E"), ("#3A220C", "#120902"),
                [Group(Layer("flames", svg(path(" ".join(flames), "#FF6A1A"))), glass_shadow="layer-color", shadow=0.8),
                 Group(Layer("candles", cand, mono=cand_m), Layer("kinara", kinara, mono=kinara_m), shadow=0.5),
                 Group(Layer("play", tri, mono=tri_m), shadow=0.6),
                 Group(Layer("ring", ring, mono=ring_m))],
                bubbles=("#7A4A22", WHITE), shelf=SHELF, asset="Kwanzaa")


ICONS = [lunar_new_year(), purim(), nowruz(), ramadan(), eid_al_fitr(), holi(), passover(), easter(),
         vaisakhi(), vesak(), eid_al_adha(), rosh_hashanah(), mid_autumn(), dia_de_muertos(), diwali(),
         hanukkah(), kwanzaa()]
