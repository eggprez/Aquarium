#!/usr/bin/env python3
"""Seasonal alternate icons for the civic and cultural holidays: each is
offered from 30 days before to 30 days after its day (the schedule lives in
Swift). Drawn with icon_kit the same way as app_icons.py — flat SVG layers,
Liquid Glass supplies the depth, dark authored per icon.

Every one of them is the Aquarium mark — the squircle ring with the play
button in its hole — dressed for the day: the ring recoloured or patterned,
and things set on, behind or around it. The mark stays the thing you see.

    python3 proof_sheet.py icons_holidays_civic <out-dir> [key ...]
"""

import math

from icon_kit import *  # noqa: F401,F403

SHELF = "Seasonal"

# ------------------------------------------------------------------ helpers


def poly(pts):
    return "M" + " L".join(f"{f(x)} {f(y)}" for x, y in pts) + " Z"


def ellipse(cx, cy, rx, ry):
    return (f"M{f(cx - rx)} {f(cy)} A{f(rx)} {f(ry)} 0 1 0 {f(cx + rx)} {f(cy)} "
            f"A{f(rx)} {f(ry)} 0 1 0 {f(cx - rx)} {f(cy)} Z")


def rect(x, y, w, h):
    return f"M{f(x)} {f(y)} H{f(x + w)} V{f(y + h)} H{f(x)} Z"


def heart(cx, cy, s):
    """A heart 2s wide, point down, centred on (cx, cy)."""
    k = [(-.2, .7, -1, .25, -1, -.25), (-1, -.75, -.35, -.95, 0, -.45),
         (.35, -.95, 1, -.75, 1, -.25), (1, .25, .2, .7, 0, .95)]
    d = f"M{f(cx)} {f(cy + s * .95)} "
    for a, b, c, e, g_, h in k:
        d += (f"C{f(cx + a * s)} {f(cy + b * s)} {f(cx + c * s)} {f(cy + e * s)} "
              f"{f(cx + g_ * s)} {f(cy + h * s)} ")
    return d + "Z"


def burst(cx, cy, r0, r1, n, ink, w, rot=0, dots=True):
    """A firework: n rays with round caps, and a spark beyond each."""
    out = []
    for i in range(n):
        a = math.radians(rot + i * 360 / n)
        c, s = math.cos(a), math.sin(a)
        out.append(f'<line x1="{f(cx + c * r0)}" y1="{f(cy + s * r0)}" x2="{f(cx + c * r1)}" '
                   f'y2="{f(cy + s * r1)}"/>')
    rays = f'<g stroke="{ink}" stroke-width="{w}" stroke-linecap="round">{"".join(out)}</g>'
    if dots:
        for i in range(n):
            a = math.radians(rot + (i + .5) * 360 / n)
            rays += path(circle(cx + math.cos(a) * r1 * .82, cy + math.sin(a) * r1 * .82, w * .42), ink)
    return rays


def g(body, t):
    return f'<g transform="{t}">{body}</g>'


def flat(*layers, **kw):
    """A group that sits under the glass as print: no shadow, no translucency."""
    return Group(*layers, shadow=0, translucency=0, **kw)


# The Canadian maple leaf (the flag's, public domain), about 3720 x 4030 around 0 0.
MAPLE = ("m-90 2030 45-863a95 95 0 0 0-111-98l-859 151 116-320a65 65 0 0 0-20-73l-941-762 212-99a65 65 0 0 0 "
         "34-79l-186-572 542 115a65 65 0 0 0 73-38l105-247 423 454a65 65 0 0 0 111-57l-204-1052 327 189a65 65 0 0 0 "
         "91-27l332-652 332 652a65 65 0 0 0 91 27l327-189-204 1052a65 65 0 0 0 111 57l423-454 105 247a65 65 0 0 0 "
         "73 38l542-115-186 572a65 65 0 0 0 34 79l212 99-941 762a65 65 0 0 0-20 73l116 320-859-151a95 95 0 0 0-111 "
         "98l45 863z")

# ------------------------------------------------------------------ the mark, dressed

HOLE_D = squircle(294, 294, 436, 436, 4.0)
BAND_D = squircle(242, 242, 540, 540, 4.1)   # the centre line of the ring


def at(s, cx=512, cy=512):
    """A `wrap` for mark_parts: the mark scaled by s about its centre and moved to (cx, cy)."""
    return (f'<g transform="translate({f(cx)} {f(cy)}) scale({s}) translate(-512 -512)">', "</g>")


def band_point(t, s=1.0, cx=512, cy=512):
    """A point on the ring's centre line, t in degrees (0 = right, 90 = down), on the canvas."""
    a = math.radians(t)
    c, sn = math.cos(a), math.sin(a)
    x = 512 + 270 * math.copysign(abs(c) ** (2 / 4.1), c)
    y = 512 + 270 * math.copysign(abs(sn) ** (2 / 4.1), sn)
    return cx + (x - 512) * s, cy + (y - 512) * s


def ring(wrap, base, bands=(), defs="", extra=""):
    """The ring in `base`, with patterns laid over it: each band is
    (fill, [shape paths in mark space], opacity), drawn as the ring clipped to
    those shapes — a clip path's own even-odd rule is ignored by the renderer,
    an even-odd fill inside a clip isn't. `extra` goes on top, inside the wrap."""
    clips, body = "", path(RING_D, base, EO)
    for i, (fill, shapes, op) in enumerate(bands):
        clips += f'<clipPath id="p{i}">' + "".join(path(d, "#000") for d in shapes) + "</clipPath>"
        o = f' opacity="{op}"' if op < 1 else ""
        body += f'<g clip-path="url(#p{i})"{o}>{path(RING_D, fill, EO)}</g>'
    return svg(wrap[0] + body + extra + wrap[1], clips + defs)


def tri(wrap, fill, defs=""):
    return svg(wrap[0] + path(PLAY_D, fill) + wrap[1], defs)


def diamonds(w, h, odd):
    """A lattice of diamonds w x h over the mark; odd picks the offset lattice."""
    out = []
    o = .5 if odd else 0
    for j in range(-1, int(1024 / h) + 2):
        for i in range(-1, int(1024 / w) + 2):
            x, y = 190 + (i + o) * w, 190 + (j + o) * h
            out.append((i + j, poly([(x, y - h / 2), (x + w / 2, y), (x, y + h / 2), (x - w / 2, y)])))
    return out


# ------------------------------------------------------------------ the icons


def newyear():
    """A gold ring, and two flutes clinking over it in a spray of confetti."""
    wrap = at(.74, 512, 614)
    gold = lin("au", "#FFF0B8", "#E0A21A", 0, 0, 1, 1)
    bowl = "M-76 -330 L76 -330 C76 -150 50 -14 0 0 C-50 -14 -76 -150 -76 -330 Z"
    clip = f'<clipPath id="bw">{path(bowl, "#000")}</clipPath>'

    def both(body):
        return (g(body, "translate(426 314) rotate(16) scale(.7)") + g(body, "translate(598 314) rotate(-16) scale(.7)"))
    glass = both(path(bowl, WHITE, ' opacity=".4"') + path(rr(-12, -6, 24, 150, 12), WHITE)
                 + path(ellipse(0, 150, 70, 17), WHITE))
    fizz = "".join(path(circle(x, y, r), "#FFF6D0") for x, y, r in ((-22, -140, 9), (16, -190, 7), (-4, -80, 8)))
    liquid = both(f'<g clip-path="url(#bw)"><rect x="-90" y="-250" width="180" height="260" fill="url(#ch)"/>'
                  f'{fizz}</g>')
    confetti = [(150, 520, "#FF6FB5", 30), (120, 700, "#4FE0D0", -25), (200, 880, "#FFD166", 60),
                (330, 60, "#FF6FB5", -50), (700, 70, "#4FE0D0", 20), (760, 200, "#FFD166", -30),
                (620, 960, "#FF6FB5", 45), (400, 970, "#4FE0D0", -15), (230, 420, "#FFD166", 70)]
    spray = "".join(g(path(rr(-22, -10, 44, 20, 6), c), f"translate({x} {y}) rotate({a})") for x, y, c, a in confetti)
    spray += path(sparkle(512, 92, 40), "#FFF3C4")
    toast = svg(liquid + glass + spray, clip + lin("ch", "#FFE9A0", "#F2B230"))
    ring_l, play_l = mark_parts("url(#au)", WHITE, gold, wrap=wrap)
    return Icon("newyear", "New Year", "Cheers to the next season",
                ("#4A2366", "#150A24"), ("#221033", "#06020C"),
                [Group(Layer("toast", toast), shadow=0.4),
                 Group(Layer("play", play_l), shadow=0.6),
                 Group(Layer("ring", ring_l))],
                bubbles=("#FFF3C4", None), shelf=SHELF, asset="NewYear")


def burns():
    """A tartan ring on the saltire."""
    wrap = at(.9, 512, 530)
    wide = [rect(p - 46, 0, 92, 1024) for p in (296, 512, 728)]
    wide_h = [rect(0, p - 46, 1024, 92) for p in (296, 512, 728)]
    red = [rect(p - 7, 0, 14, 1024) for p in (404, 620)] + [rect(0, p - 7, 1024, 14) for p in (404, 620)]
    fine = [rect(p - 4, 0, 8, 1024) for p in (220, 804)] + [rect(0, p - 4, 1024, 8) for p in (220, 804)]
    tartan = ring(wrap, "#D42A36", [("#0F5B3A", wide, .6), ("#0F5B3A", wide_h, .6),
                                    ("#10203F", red, 1), ("#FFD95A", fine, 1)])
    saltire = svg('<g stroke="#FFFFFF" stroke-width="150" opacity=".13">'
                  '<line x1="-40" y1="-40" x2="1064" y2="1064"/><line x1="1064" y1="-40" x2="-40" y2="1064"/></g>')
    return Icon("burns", "Burns Night", "A wee dram, a double bill",
                ("#2A5DA8", "#15356E"), ("#12264A", "#050B18"),
                [Group(Layer("play", tri(wrap, WHITE)), shadow=0.6),
                 Group(Layer("tartan", tartan, mono=mark_parts(WHITE, WHITE, wrap=wrap)[0])),
                 flat(Layer("saltire", saltire, glass=False))],
                shelf=SHELF, asset="BurnsNight")


def valentine():
    """A red ring with a heart stuck on its corner."""
    wrap = at(.86, 492, 548)
    hearts = svg(path(heart(786, 262, 118), "#FF5C86")
                 + path(heart(212, 850, 50), WHITE) + path(heart(318, 930, 26), "#FF5C86"))
    hearts_m = svg(path(heart(786, 262, 118), "#9A9A9A")
                   + path(heart(212, 850, 50), WHITE) + path(heart(318, 930, 26), "#9A9A9A"))
    ring_l, play_l = mark_parts("#E8163F", WHITE, wrap=wrap)
    ring_m, _ = mark_parts(WHITE, WHITE, wrap=wrap)
    return Icon("valentine", "Valentine's", "Be mine, one more episode",
                ("#FFC6D6", "#FF86A8"), ("#4C0C24", "#16030B"),
                [Group(Layer("heart", hearts, mono=hearts_m), shadow=0.5),
                 Group(Layer("play", play_l), shadow=0.5),
                 Group(Layer("ring", ring_l, mono=ring_m))],
                shelf=SHELF, asset="Valentine")


def mardigras():
    """A harlequin ring in purple, green and gold, plumes behind, beads over it."""
    wrap = at(.84, 500, 556)
    lat = diamonds(108, 150, False)
    purple = [d for k, d in lat if k % 2 == 0]
    green = [d for k, d in lat if k % 2]
    harlequin = ring(wrap, "#FFC940", [("#A04FE0", purple, 1), ("#27B865", green, 1)])
    plumes = []
    for ang, col, L in ((-128, "#3DD67F", 300), (-100, "#FFE08A", 330), (-74, "#C77DFF", 310), (-50, "#3DD67F", 260)):
        a = math.radians(ang)
        bx, by = 730, 330
        tx, ty = bx + math.cos(a) * L, by + math.sin(a) * L
        px, py = -math.sin(a) * 58, math.cos(a) * 58
        mx, my = bx + math.cos(a) * L * .6, by + math.sin(a) * L * .6
        plumes.append(path(f"M{f(bx)} {f(by)} Q{f(mx + px)} {f(my + py)} {f(tx)} {f(ty)} "
                           f"Q{f(mx - px)} {f(my - py)} {f(bx)} {f(by)} Z", col))
    beads = []
    for k, (col, sag) in enumerate((("#FFC940", 170), ("#3DD67F", 120))):
        for i in range(15):
            t = i / 14
            x = 250 + t * 420
            y = 700 + k * 26 + sag * 4 * t * (1 - t) - t * 70
            beads.append(path(circle(x, y, 17), col))
    return Icon("mardigras", "Mardi Gras", "Let the good times roll",
                ("#7B2CBF", "#3C096C"), ("#2A0A45", "#0B0214"),
                [Group(Layer("beads", svg("".join(beads))), Layer("play", tri(wrap, "#FFE08A")), shadow=0.6),
                 Group(Layer("harlequin", harlequin, mono=mark_parts(WHITE, WHITE, wrap=wrap)[0])),
                 Group(Layer("plumes", svg("".join(plumes))), shadow=0.3)],
                shelf=SHELF, asset="MardiGras")


def stpatrick():
    """A clover-green ring with shamrocks sprouting from behind it."""
    wrap = at(.82, 478, 568)

    def shamrock(cx, cy, s, rot, ink):
        leaves = "".join(g(path(heart(0, 0, 70), ink), f"rotate({a}) translate(0 -64)")
                         for a in (0, 120, 240))
        return g(leaves, f"translate({cx} {cy}) rotate({rot}) scale({s})")
    stems = ('<g fill="none" stroke="#D6FFB0" stroke-width="26" stroke-linecap="round">'
             '<path d="M640 360 C700 300 740 260 790 214"/><path d="M360 360 C330 300 300 250 250 214"/></g>')
    clover = svg(stems + shamrock(794, 206, 1.25, 20, "#D6FFB0") + shamrock(248, 206, .8, -25, "#B6F08A"))
    shine = svg(path(sparkle(840, 440, 34), "#FFE27A") + path(sparkle(120, 560, 24), "#FFE27A"))
    ring_l, play_l = mark_parts("#E6FFD2", "#FFD34D", wrap=wrap)
    return Icon("stpatrick", "St. Patrick's", "Sláinte!",
                ("#34C27A", "#0B6E3E"), ("#0D3A24", "#03120A"),
                [Group(Layer("play", play_l), Layer("shine", shine), shadow=0.6),
                 Group(Layer("ring", ring_l)),
                 Group(Layer("shamrocks", clover), shadow=0.4)],
                shelf=SHELF, asset="StPatrick")


def earthday():
    """The Earth glimpsed through a leaf-green ring, a sprout on top."""
    wrap = at(.84, 512, 560)
    land_d = ("M300 330 C380 300 450 340 440 400 C430 450 380 440 370 500 C360 560 420 590 400 650 "
              "C380 720 330 760 290 740 C250 700 260 620 240 560 C220 500 230 380 300 330 Z "
              "M560 380 C620 350 700 380 740 430 C770 480 720 500 690 490 C650 480 640 530 670 570 "
              "C700 610 690 690 640 720 C600 740 580 690 590 640 C600 590 540 560 540 510 "
              "C540 460 520 410 560 380 Z")

    def globe(ocean, land):
        return svg(wrap[0] + f'<clipPath id="gl">{path(HOLE_D, "#000")}</clipPath>'
                   + path(HOLE_D, ocean) + f'<g clip-path="url(#gl)">{path(land_d, land)}</g>' + wrap[1])
    top = 560 - 322 * .84
    sprout = svg(f'<path d="M512 {f(top + 10)} C512 {f(top - 40)} 516 {f(top - 70)} 530 {f(top - 110)}" fill="none" '
                 'stroke="#2E9E44" stroke-width="22" stroke-linecap="round"/>'
                 + g(path("M0 0 C42 -76 142 -86 182 -66 C162 4 82 44 0 0 Z", "#3CC057")
                     + g(path("M0 0 C42 -76 142 -86 182 -66 C162 4 82 44 0 0 Z", "#3CC057"), "scale(-.8 .8) translate(8 30)"),
                     f"translate(528 {f(top - 104)})"))
    sprout_m = sprout.replace("#2E9E44", WHITE).replace("#3CC057", WHITE)
    ring_l, play_l = mark_parts("#2E9E44", WHITE, wrap=wrap)
    ring_m, _ = mark_parts(WHITE, WHITE, wrap=wrap)
    return Icon("earthday", "Earth Day", "Streaming, sustainably",
                ("#C4ECFF", "#6CBDF2"), ("#0C1E3E", "#020610"),
                [Group(Layer("play", play_l), shadow=0.6),
                 Group(Layer("ring", ring_l, mono=ring_m), Layer("sprout", sprout, mono=sprout_m)),
                 Group(Layer("earth", globe("#1E6FD6", "#5ED16C"), mono=globe("#8A8A8A", "#C8C8C8")), shadow=0.2)],
                bubbles=(WHITE, None), shelf=SHELF, asset="EarthDay")


def kingsday():
    """An orange ring wearing a crown."""
    wrap = at(.8, 512, 590)
    body = rounded_poly([(-150, 90), (-172, -100), (-80, -10), (0, -150), (80, -10), (172, -100), (150, 90)], 22)
    crown = g(path(body, "#FFC83D") + path(circle(-172, -110, 26), "#FFC83D") + path(circle(0, -162, 30), "#FFC83D")
              + path(circle(172, -110, 26), "#FFC83D"), "translate(560 250) rotate(10)")
    gems = g(path(rr(-150, 40, 300, 50, 20), "#FFE9A6") + path(circle(-80, 65, 18), "#E23A48")
             + path(circle(0, 65, 20), "#2B6BD6") + path(circle(80, 65, 18), "#E23A48"), "translate(560 250) rotate(10)")
    ring_l, play_l = mark_parts("#FF8A1F", WHITE, wrap=wrap)
    return Icon("kingsday", "King's Day", "Oranje boven",
                ("#3767C4", "#172F6E"), ("#11234A", "#040A18"),
                [Group(Layer("crown", svg(crown)), Layer("gems", svg(gems)), shadow=0.5),
                 Group(Layer("play", play_l), shadow=0.6),
                 Group(Layer("ring", ring_l))],
                shelf=SHELF, asset="KingsDay")


def mothersday():
    """Flowers bursting from behind a pink ring."""
    wrap = at(.78, 512, 612)

    def bloom(cx, cy, r, petal, heart_):
        s = "".join(path(circle(cx + math.cos(math.radians(a)) * r * .6, cy + math.sin(math.radians(a)) * r * .6,
                                r * .5), petal) for a in range(-90, 270, 72))
        return s + path(circle(cx, cy, r * .34), heart_)
    leaves = (path("M430 380 C370 300 290 290 250 320 C290 380 370 400 430 380 Z", "#4DB86A")
              + path("M600 380 C660 300 740 290 780 320 C740 380 660 400 600 380 Z", "#4DB86A")
              + '<g fill="none" stroke="#4DB86A" stroke-width="18" stroke-linecap="round">'
                '<path d="M512 420 V250"/><path d="M470 420 L372 262"/><path d="M554 420 L660 250"/></g>')
    flowers = (bloom(360, 250, 104, "#FF6FA3", "#FFD65C") + bloom(664, 236, 100, "#FF9F6B", "#FFF1C2")
               + bloom(512, 176, 96, "#FFFFFF", "#FFC23D"))
    posy = svg(leaves + flowers)
    posy_m = svg(leaves.replace("#4DB86A", "#9A9A9A") + flowers.replace("#FF6FA3", "#DDDDDD")
                 .replace("#FF9F6B", "#DDDDDD").replace("#FFD65C", WHITE).replace("#FFF1C2", WHITE).replace("#FFC23D", WHITE))
    ring_l, play_l = mark_parts("#E64C87", WHITE, wrap=wrap)
    ring_m, _ = mark_parts(WHITE, WHITE, wrap=wrap)
    return Icon("mothersday", "Mother's Day", "Picked just for you",
                ("#EEDFFF", "#BFA2FF"), ("#2D1B48", "#0D0718"),
                [Group(Layer("play", play_l), shadow=0.6),
                 Group(Layer("ring", ring_l, mono=ring_m)),
                 Group(Layer("flowers", posy, mono=posy_m), shadow=0.4)],
                bubbles=(WHITE, None), shelf=SHELF, asset="MothersDay")


def repubblica():
    """A tricolore ring under the Frecce Tricolori's smoke."""
    wrap = at(.8, 512, 596)
    third = 644 / 3
    tricolore = ring(wrap, WHITE, [("#0FA152", [rect(0, 0, 190 + third, 1024)], 1),
                                   ("#D8303C", [rect(190 + 2 * third, 0, 1024, 1024)], 1)])
    tricolore_m, _ = mark_parts(WHITE, WHITE, wrap=wrap)

    def trail(dy, ink):
        return (f'<path d="M-20 {560 + dy} C160 {200 + dy} 520 {70 + dy} 1060 {150 + dy}" fill="none" stroke="{ink}" '
                f'stroke-width="40" stroke-linecap="round"/>')
    smoke = svg(trail(-50, "#0FA152") + trail(0, WHITE) + trail(50, "#D8303C"))
    smoke_m = svg(trail(-50, "#BDBDBD") + trail(0, WHITE) + trail(50, "#BDBDBD"))
    return Icon("repubblica", "Festa della Repubblica", "Buona visione!",
                ("#9BD8FF", "#3F97DE"), ("#0C2442", "#030A15"),
                [Group(Layer("play", tri(wrap, WHITE)), shadow=0.6),
                 Group(Layer("tricolore", tricolore, mono=tricolore_m)),
                 Group(Layer("smoke", smoke, mono=smoke_m), shadow=0.3, translucency=0.3)],
                shelf=SHELF, asset="Repubblica")


def fathersday():
    """A tie hanging from the ring, as if the ring were the collar."""
    wrap = at(.74, 512, 420)
    bottom = 420 + 322 * .74
    blade = rounded_poly([(470, bottom + 36), (554, bottom + 36), (640, 870), (512, 986), (384, 870)], 20)
    knot = rounded_poly([(446, bottom - 52), (578, bottom - 52), (550, bottom + 48), (474, bottom + 48)], 18)
    stripes = "".join(f'<rect x="200" y="{y}" width="700" height="36"/>' for y in range(560, 1100, 96))
    tie = (path(blade, "#FFC62E") + f'<clipPath id="tb">{path(blade, "#000")}</clipPath>'
           f'<g clip-path="url(#tb)"><g fill="#1D3B7C" transform="rotate(-32 512 820)">{stripes}</g></g>'
           + path(knot, "#FFB300"))
    ring_l, play_l = mark_parts(WHITE, "#FFC62E", wrap=wrap)
    return Icon("fathersday", "Father's Day", "Dad's pick tonight",
                ("#62B2F5", "#2461BA"), ("#0F2444", "#040A17"),
                [Group(Layer("tie", svg(tie)), shadow=0.5),
                 Group(Layer("play", play_l), shadow=0.6),
                 Group(Layer("ring", ring_l))],
                shelf=SHELF, asset="FathersDay")


def midsummer():
    """A leafy ring worn as a midsummer wreath, flowers all round, ribbons trailing."""
    s, cx, cy = .84, 512, 520
    wrap = at(s, cx, cy)
    cols = ["#FFFFFF", "#FF7AB8", "#FFE14D", "#B38CFF"]
    blooms = []
    for i, t in enumerate(range(0, 360, 30)):
        x, y = band_point(t + 15, s, cx, cy)
        lx, ly = band_point(t, s, cx, cy)
        blooms.append(g(path(ellipse(0, 0, 30, 13), "#9BE07A"), f"translate({f(lx)} {f(ly)}) rotate({t + 90})"))
        c = cols[i % 4]
        blooms.append("".join(path(circle(x + 22 * math.cos(math.radians(a + t)), y + 22 * math.sin(math.radians(a + t)), 19), c)
                              for a in range(0, 360, 72))
                      + path(circle(x, y, 13), "#FF9F1C" if c == "#FFE14D" else "#FFC400"))
    x0, y0 = band_point(105, s, cx, cy)
    x1, y1 = band_point(75, s, cx, cy)
    ribbons = ('<g fill="none" stroke-width="22" stroke-linecap="round">'
               f'<path d="M{f(x0)} {f(y0)} C{f(x0 - 30)} {f(y0 + 90)} {f(x0 + 30)} {f(y0 + 150)} {f(x0 - 20)} 990" stroke="#FECC02"/>'
               f'<path d="M{f(x1)} {f(y1)} C{f(x1 + 30)} {f(y1 + 90)} {f(x1 - 30)} {f(y1 + 150)} {f(x1 + 20)} 990" stroke="#FF7AB8"/>'
               '</g>')
    wreath = svg(ribbons + "".join(blooms))
    return Icon("midsummer", "Midsummer", "Dance round the maypole",
                ("#4FA8F2", "#0B5CAE"), ("#0A2341", "#030A16"),
                [Group(Layer("flowers", wreath), shadow=0.4),
                 Group(Layer("play", tri(wrap, "#FECC02")), shadow=0.6),
                 Group(Layer("ring", ring(wrap, "#3FAE49")))],
                shelf=SHELF, asset="Midsummer")


def canadaday():
    """A red ring in front of the maple leaf."""
    wrap = at(.8, 512, 548)

    def leaf(ink):
        return svg(f'<g transform="translate(512 500) scale(.225)">{path(MAPLE, ink)}</g>')
    bars = svg(path(rect(0, 0, 110, 1024), "#E3162B") + path(rect(914, 0, 110, 1024), "#E3162B"))
    ring_l, play_l = mark_parts("#E3162B", "#E3162B", wrap=wrap)
    ring_d, play_d = mark_parts("#FF3346", "#FFE9EA", wrap=wrap)
    ring_m, play_m = mark_parts(WHITE, WHITE, wrap=wrap)
    return Icon("canadaday", "Canada Day", "True north, strong stream",
                ("#FFFFFF", "#F2E9E9"), ("#3A0C12", "#120306"),
                [Group(Layer("play", play_l, play_d, mono=play_m), shadow=0.5),
                 Group(Layer("ring", ring_l, ring_d, mono=ring_m)),
                 flat(Layer("leaf", leaf("#FFB8C2"), leaf("#6A1520"), glass=False, mono=leaf("#6A6A6A")),
                      Layer("bars", bars, glass=False, mono=svg(""))) ],
                bubbles=("#E3162B", WHITE), shelf=SHELF, asset="CanadaDay")


def july4():
    """A stars-and-stripes ring with fireworks going off behind it."""
    s, cx, cy = .82, 512, 566
    wrap = at(s, cx, cy)
    h = 644 / 13
    red = [rect(0, 190 + i * h, 1024, h) for i in range(0, 13, 2)]
    canton = rect(0, 0, 486, 190 + 7 * h)
    stars = "".join(path(star(x, y, 20, 8), WHITE) for x, y in
                    ((220, 222), (270, 222), (320, 222), (370, 222), (420, 222), (245, 262), (295, 262),
                     (345, 262), (395, 262), (220, 302), (270, 302), (320, 302), (370, 302), (420, 302),
                     (245, 342), (220, 382), (245, 422), (220, 462), (245, 502)))
    clip_stars = f'<clipPath id="st">{path(RING_D, "#000")}</clipPath>'
    flag = ring(wrap, WHITE, [("#E23143", red, 1), ("#2F5BD3", [canton], 1)],
                defs=clip_stars, extra=f'<g clip-path="url(#st)">{stars}</g>')
    sky = svg(burst(820, 190, 56, 170, 14, "#FF4A5C", 22) + path(star(820, 190, 36, 16), WHITE)
              + burst(180, 470, 40, 120, 12, WHITE, 18) + burst(520, 120, 30, 96, 10, "#6FA0FF", 16)
              + "".join(path(star(x, y, r, r * .42), WHITE) for x, y, r in ((640, 70, 16), (330, 90, 12), (90, 860, 16))))
    return Icon("july4", "Fourth of July", "Land of the free trial",
                ("#1F3A8A", "#0B1A4A"), ("#0C1638", "#030712"),
                [Group(Layer("play", tri(wrap, WHITE)), shadow=0.6),
                 Group(Layer("flag", flag)),
                 Group(Layer("fireworks", sky), glass_shadow="layer-color", shadow=0.5)],
                shelf=SHELF, asset="FourthOfJuly")


def bastille():
    """A bleu-blanc-rouge ring under the fireworks over Paris."""
    s, cx, cy = .84, 512, 560
    wrap = at(s, cx, cy)
    third = 644 / 3
    tricolore = ring(wrap, WHITE, [("#3A6BFF", [rect(0, 0, 190 + third, 1024)], 1),
                                   ("#EF3340", [rect(190 + 2 * third, 0, 1024, 1024)], 1)])
    lights = svg(burst(800, 170, 44, 140, 12, "#FF5A6A", 20) + burst(240, 900, 36, 110, 10, "#6FA0FF", 18)
                 + burst(520, 96, 24, 78, 10, WHITE, 14) + burst(96, 520, 26, 78, 8, "#FF5A6A", 14))
    sparks = svg(path(sparkle(660, 960, 22), WHITE) + path(sparkle(340, 80, 18), "#FFE3A0")
                 + path(sparkle(960, 330, 16), WHITE))
    return Icon("bastille", "Bastille Day", "Liberté, égalité, streamé",
                ("#26206A", "#0B0826"), ("#141034", "#04030C"),
                [Group(Layer("play", tri(wrap, WHITE)), shadow=0.6),
                 Group(Layer("tricolore", tricolore, mono=mark_parts(WHITE, WHITE, wrap=wrap)[0])),
                 Group(Layer("fireworks", lights), Layer("sparks", sparks, glass=False),
                       glass_shadow="layer-color", shadow=0.5)],
                bubbles=(WHITE, None), shelf=SHELF, asset="BastilleDay")


def mexico():
    """A magenta ring under a string of papel picado."""
    wrap = at(.78, 512, 610)

    def flag(x, y, w, h, fill, motif):
        k = 4
        r = w / k / 2
        outer = f"M{f(x)} {f(y)} H{f(x + w)} V{f(y + h)} " + f"a{f(r)} {f(r * .8)} 0 0 1 {f(-2 * r)} 0 " * k + "Z"
        cx = x + w / 2
        holes = [motif(cx, y + h * .5)]
        holes += [poly([(px, y + 18), (px + 7, y + 27), (px, y + 36), (px - 7, y + 27)]) for px in (x + 20, x + w - 20)]
        return path(outer + " " + " ".join(holes), fill, EO)

    def flower(cx, cy):
        return star(cx, cy, 30, 13, points=6)

    def heart_(cx, cy):
        return heart(cx, cy, 26)
    w, h = 128, 164
    spots = [(78, 150, "#0A8A4E", flower, -8), (258, 188, WHITE, heart_, -3), (446, 200, "#1FA9C9", flower, 0),
             (634, 188, "#D7263D", heart_, 3), (814, 150, "#7B3FBF", flower, 8)]

    def row(mono):
        out = []
        for x, y, c, m, a in spots:
            fill = (WHITE if c == WHITE else "#D4D4D4") if mono else c
            out.append(g(flag(-w / 2, 0, w, h, fill, m), f"translate({x + w / 2} {y}) rotate({a})"))
        return svg("".join(out))
    string = svg('<path d="M-10 130 Q512 260 1034 130" fill="none" stroke="#5A2A0A" stroke-width="8"/>')
    string_d = string.replace("#5A2A0A", "#E8C9A0")
    ring_l, play_l = mark_parts("#E4007C", WHITE, wrap=wrap)
    ring_m, _ = mark_parts(WHITE, WHITE, wrap=wrap)
    return Icon("mexico", "Viva México", "¡Que viva la función!",
                ("#FFD35C", "#F38A1B"), ("#3A1A06", "#110703"),
                [Group(Layer("picado", row(False), mono=row(True)), Layer("string", string, string_d, glass=False,
                                                                         mono=string_d), shadow=0.4),
                 Group(Layer("play", play_l), shadow=0.6),
                 Group(Layer("ring", ring_l, mono=ring_m))],
                shelf=SHELF, asset="VivaMexico")


def oktoberfest():
    """A ring in Bavarian lozenges, with a pretzel perched on top."""
    wrap = at(.82, 496, 590)
    blue = [d for _, d in diamonds(92, 124, False)]
    lozenge = ring(wrap, WHITE, [("#2E8FE6", blue, 1)])
    pretzel = ("M-95 60 C-60 20 -10 -20 20 -60 C50 -100 110 -130 140 -80 C175 -20 140 70 60 90 "
               "C20 100 -20 100 -60 90 C-140 70 -175 -20 -140 -80 C-110 -130 -50 -100 -20 -60 "
               "C10 -20 60 20 95 60")
    salt = "".join(g(path(rr(-7, -5, 14, 10, 3), WHITE), f"translate({x} {y}) rotate({a})")
                   for x, y, a in ((-150, -40, 30), (-100, -110, -20), (120, -110, 40), (150, -30, -10),
                                   (0, 92, 20), (-60, 88, -30), (60, 88, 10), (0, -40, 45)))
    pz = svg(g(f'<path d="{pretzel}" fill="none" stroke="#B8622A" stroke-width="48" stroke-linecap="round" '
               f'stroke-linejoin="round"/>' + salt, "translate(690 240) rotate(14) scale(.95)"))
    return Icon("oktoberfest", "Oktoberfest", "O'zapft is!",
                ("#1F74C8", "#0A3C7A"), ("#0B2442", "#030A15"),
                [Group(Layer("pretzel", pz), shadow=0.5),
                 Group(Layer("play", tri(wrap, WHITE)), shadow=0.6),
                 Group(Layer("lozenges", lozenge))],
                shelf=SHELF, asset="Oktoberfest")


def halloween():
    """A pumpkin-orange ring carved into a jack-o'-lantern, glowing through."""
    wrap = at(.86, 512, 566)
    eyes = [rounded_poly([(348, 280), (452, 280), (400, 206)], 8), rounded_poly([(572, 280), (676, 280), (624, 206)], 8)]
    mouth = rounded_poly([(356, 748), (668, 748), (636, 812), (598, 786), (560, 818), (512, 788), (464, 818),
                          (426, 786), (388, 812)], 6)
    carved = svg(wrap[0] + path(RING_D + " " + " ".join(eyes) + " " + mouth, "#FF8A26", EO) + wrap[1])
    carved_m = carved.replace("#FF8A26", WHITE)
    glow = svg(wrap[0] + "".join(path(d, "#FFE45C") for d in eyes + [mouth]) + wrap[1]
               + path(crescent((850, 150), 84, (890, 120), 72), "#FFF3C4"))
    top = 566 - 322 * .86
    stem = svg(path(rounded_poly([(492, top + 14), (500, top - 60), (546, top - 92), (556, top - 64),
                                  (530, top - 46), (530, top + 14)], 12), "#4E8A2A"))
    return Icon("halloween", "Halloween", "Trick or stream",
                ("#50307F", "#1D0F36"), ("#1B0E30", "#06030E"),
                [Group(Layer("play", tri(wrap, "#FFE45C")), Layer("stem", stem),
                       glass_shadow="layer-color", shadow=0.7),
                 Group(Layer("pumpkin", carved, mono=carved_m)),
                 Group(Layer("glow", glow), glass_shadow="layer-color", shadow=0.6)],
                shelf=SHELF, asset="Halloween")


def bonfire():
    """A ring lit warm by the bonfire blazing in front of it."""
    wrap = at(.78, 512, 440)

    def flame(s, fill, dy=0):
        pts = ("M0 0 C-150 0 -180 -150 -120 -250 C-100 -190 -80 -180 -64 -196 C-84 -290 -40 -370 20 -430 "
               "C14 -340 50 -300 76 -312 C84 -350 96 -370 116 -382 C170 -260 180 -130 110 -50 C80 -14 44 0 0 0 Z")
        return g(path(pts, fill), f"translate(500 {900 + dy}) scale({s})")
    fire = (flame(.66, "#FF5A1F") + flame(.44, "#FFA41F", -6) + flame(.24, "#FFE36B", -8)
            + g(path(rr(-170, -22, 340, 44, 22), "#8A4B22"), "translate(512 918) rotate(-12)")
            + g(path(rr(-170, -22, 340, 44, 22), "#A65B2A"), "translate(512 918) rotate(12)"))
    sparks = ("".join(path(circle(x, y, r), "#FFC04D") for x, y, r in ((360, 690, 8), (660, 700, 7), (300, 760, 6),
                                                                       (720, 780, 7), (420, 620, 5)))
              + path(sparkle(210, 620, 22), "#FFF1B8") + path(sparkle(800, 560, 18), "#FFF1B8"))
    warm = lin("fw", "#FFE2A8", "#FF7A2E")
    ring_l, play_l = mark_parts("url(#fw)", "#FFF4DE", warm, wrap=wrap)
    return Icon("bonfire", "Bonfire Night", "Remember, remember",
                ("#262A63", "#0B0C26"), ("#10122E", "#03030A"),
                [Group(Layer("fire", svg(fire + sparks)), glass_shadow="layer-color", shadow=0.7),
                 Group(Layer("play", play_l), shadow=0.6),
                 Group(Layer("ring", ring_l), glass_shadow="layer-color", shadow=0.6)],
                shelf=SHELF, asset="BonfireNight")


def thanksgiving():
    """A turkey-feather fan spread behind a chestnut ring."""
    s, cx, cy = .74, 512, 610
    wrap = at(s, cx, cy)
    cols = ["#D8452B", "#F28C28", "#F9C23C", "#8C4A1F", "#D8452B", "#F28C28", "#F9C23C", "#8C4A1F", "#D8452B"]
    fan = []
    for i, c in enumerate(cols):
        ang = -170 + i * 20
        a = math.radians(ang)
        x, y = cx + math.cos(a) * 390, cy + math.sin(a) * 390
        fan.append(g(path(ellipse(0, 0, 76, 170), c), f"translate({f(x)} {f(y)}) rotate({ang + 90})"))
    feathers = svg("".join(fan))
    feathers_m = feathers
    for c, m in (("#D8452B", "#D6D6D6"), ("#F28C28", "#EAEAEA"), ("#F9C23C", WHITE), ("#8C4A1F", "#BDBDBD")):
        feathers_m = feathers_m.replace(c, m)
    ring_l, play_l = mark_parts("#7A3A17", "#D8452B", wrap=wrap)
    ring_d, play_d = mark_parts("#C77A3E", "#FFB45C", wrap=wrap)
    ring_m, play_m = mark_parts(WHITE, WHITE, wrap=wrap)
    return Icon("thanksgiving", "Thanksgiving", "Seconds, anyone?",
                ("#FFE7BC", "#F7B864"), ("#3A1E0A", "#140902"),
                [Group(Layer("play", play_l, play_d, mono=play_m), shadow=0.5),
                 Group(Layer("ring", ring_l, ring_d, mono=ring_m), translucency=0.1),
                 Group(Layer("feathers", feathers, mono=feathers_m), shadow=0.3)],
                bubbles=("#B0561E", "#FFE7BC"), shelf=SHELF, asset="Thanksgiving")


def christmas():
    """A green ring in a Santa hat, with a string of lights across it."""
    s, cx, cy = .8, 492, 574
    wrap = at(s, cx, cy)
    hat = g(path("M-150 0 C-120 -140 -40 -250 90 -270 C170 -280 230 -230 250 -170 C200 -200 150 -200 120 -150 "
                  "C100 -110 110 -50 130 0 Z", "#E8283A")
            + path(rr(-176, -34, 336, 76, 38), WHITE) + path(circle(252, -168, 42), WHITE),
            "translate(686 334) rotate(18) scale(.86)")
    bulbs = []
    cols = ["#FFD54A", "#4FC3FF", "#FF6F61", "#FFFFFF", "#FFD54A", "#FF6F61", "#4FC3FF"]
    pts = [band_point(t, s, cx, cy) for t in (150, 135, 118, 100, 82, 64, 46)]
    wire = "M" + " Q".join(
        (f"{f(x)} {f(y)}" if i == 0 else f"{f((pts[i - 1][0] + x) / 2)} {f((pts[i - 1][1] + y) / 2 + 40)} {f(x)} {f(y)}")
        for i, (x, y) in enumerate(pts))
    for (x, y), c in zip(pts, cols):
        bulbs.append(path(ellipse(x, y + 26, 17, 24), c) + path(rr(x - 10, y + 2, 20, 12, 3), "#2A5A34"))
    lights = f'<path d="{wire}" fill="none" stroke="#0F5A2E" stroke-width="7"/>' + "".join(bulbs)
    snow = svg("".join(path(circle(x, y, r), WHITE, ' opacity=".8"') for x, y, r in
                       ((620, 110, 9), (440, 150, 7), (330, 60, 6), (80, 620, 8), (120, 470, 6),
                        (60, 800, 7), (950, 300, 6), (980, 150, 5), (400, 980, 7))))
    return Icon("christmas", "Christmas", "Home for the holidays",
                ("#D7263D", "#8C1022"), ("#3C0A14", "#12030A"),
                [Group(Layer("hat", svg(hat + lights)), shadow=0.5),
                 Group(Layer("play", tri(wrap, WHITE)), shadow=0.6),
                 Group(Layer("ring", ring(wrap, "#1FA35F"), mono=mark_parts(WHITE, WHITE, wrap=wrap)[0])),
                 flat(Layer("snow", snow, glass=False))],
                shelf=SHELF, asset="Christmas")


ICONS = [newyear(), burns(), valentine(), mardigras(), stpatrick(), earthday(), kingsday(), mothersday(),
         repubblica(), fathersday(), midsummer(), canadaday(), july4(), bastille(), mexico(), oktoberfest(),
         halloween(), bonfire(), thanksgiving(), christmas()]
