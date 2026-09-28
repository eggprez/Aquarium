"""Two shelves of alternate icons: "Finishes" (the Aquarium mark in a new
material) and "Colourful" (the mark in a new palette or print treatment).

Drawn with icon_kit, the same way as app_icons.py: flat SVG layers, Liquid
Glass supplies the depth, dark authored with bg_dark and `dark=` art, and
`mono=` art for layers drawn dark on a light ground.

    python3 proof_sheet.py icons_finishes <out-dir> [key ...]
"""

import math

from icon_kit import *  # noqa: F401,F403

RING_OUT = squircle(190, 190, 644, 644, 4.2)
RING_IN = squircle(294, 294, 436, 436, 4.0)


def grad(id_, stops, x1=0, y1=0, x2=0, y2=1, units=""):
    """A linear gradient with any number of (offset, colour) stops."""
    u = f' gradientUnits="{units}"' if units else ""
    s = "".join(f'<stop offset="{o}" stop-color="{c}"/>' for o, c in stops)
    return f'<linearGradient id="{id_}" x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}"{u}>{s}</linearGradient>'


def ring(fill, extra=""):
    return path(RING_D, fill, EO + extra)


def tri(fill, extra=""):
    return path(PLAY_D, fill, extra)


def poly(pts):
    return "M" + " L".join(f"{f(x)} {f(y)}" for x, y in pts) + " Z"


# ================================================================== Finishes


def chrome():
    # A polished-chrome horizon: sky above, a hard dark line, ground below.
    stops = [(0, "#FFFFFF"), (.34, "#D5DBE4"), (.49, "#7A8594"), (.51, "#262C36"),
             (.64, "#5D6878"), (.85, "#C9D1DC"), (1, "#F4F6F9")]
    defs = grad("cr", stops) + grad("cp", [(0, "#F4F6F9"), (.44, "#B7C0CC"), (.5, "#3A424E"),
                                   (.62, "#8994A3"), (1, "#FFFFFF")])
    r, t = svg(ring("url(#cr)"), defs), svg(tri("url(#cp)"), defs)
    return Icon("chrome", "Chrome", "Buffed to a mirror shine",
                ("#4A5260", "#14171C"), ("#23272E", "#050608"),
                [Group(Layer("play", t), shadow=0.6), Group(Layer("ring", r), shadow=0.6)],
                diagonal=True, shelf="Finishes", asset="Chrome")


def rosegold():
    defs = (grad("rg", [(0, "#FFE3D6"), (.45, "#E9A58F"), (1, "#A35E4E")], 0, 0, 1, 1)
            + grad("rp", [(0, "#F7C2AE"), (1, "#9A5243")], 0, 0, 1, 1))
    r, t = svg(ring("url(#rg)"), defs), svg(tri("url(#rp)"), defs)
    return Icon("rosegold", "Rose Gold", "Engraved for the occasion",
                ("#FFF3EE", "#F3D5CB"), ("#3A2226", "#120809"),
                [Group(Layer("play", t, mono=svg(tri(WHITE))), shadow=0.5),
                 Group(Layer("ring", r, mono=svg(ring(WHITE))), shadow=0.5)],
                diagonal=True, bubbles=("#B36B5A", "#F7C6B5"), shelf="Finishes", asset="RoseGold")


def onyx():
    # Polished black stone, banded in the grain, on warm grey slate.
    bands = [(0, "#6A6A74"), (.16, "#1A1A1F"), (.3, "#3C3C44"), (.42, "#0B0B0D"),
             (.58, "#2E2E35"), (.72, "#08080A"), (.86, "#34343B"), (1, "#050506")]
    defs = grad("ox", bands, 0, 0, 1, 1) + grad("oxp", bands[::-1], 0, 0, 1, 1)
    lit = [(0, "#8A8A96"), (.16, "#2A2A31"), (.3, "#56565F"), (.42, "#18181C"),
           (.58, "#474750"), (.72, "#141418"), (.86, "#4E4E57"), (1, "#101013")]
    defs_d = grad("ox", lit, 0, 0, 1, 1) + grad("oxp", lit[::-1], 0, 0, 1, 1)
    r, t = svg(ring("url(#ox)"), defs), svg(tri("url(#oxp)"), defs)
    rd, td = svg(ring("url(#ox)"), defs_d), svg(tri("url(#oxp)"), defs_d)
    return Icon("onyx", "Onyx", "Black tie, black stone",
                ("#A7A29B", "#5E5A55"), ("#26262B", "#000000"),
                [Group(Layer("play", t, td, mono=svg(tri(WHITE))), shadow=0.7),
                 Group(Layer("ring", r, rd, mono=svg(ring(WHITE))), shadow=0.7)],
                diagonal=True, shelf="Finishes", asset="Onyx")


def opal():
    # Play-of-colour: pastel fire that shifts across the stone.
    fire = [(0, "#FFD1E8"), (.22, "#C8F3FF"), (.42, "#B9FFD9"), (.6, "#FFF3B8"),
            (.8, "#E2C8FF"), (1, "#A8D8FF")]
    defs = grad("op", fire, 0, 0, 1, 1) + grad("opp", fire[::-1], 0, 1, 1, 0)
    r, t = svg(ring("url(#op)"), defs), svg(tri("url(#opp)"), defs)
    return Icon("opal", "Opal", "Every light, every angle",
                ("#DCD6EE", "#A69ECF"), ("#221F36", "#07060D"),
                [Group(Layer("play", t), shadow=0.4, translucency=0.5),
                 Group(Layer("ring", r), shadow=0.4, translucency=0.5)],
                diagonal=True, bubbles=("#8A7CD0", WHITE), shelf="Finishes", asset="Opal")


def blueprint():
    def lines(ink):
        s = f'<g fill="none" stroke="{ink}" stroke-width="12" stroke-linejoin="round">'
        s += f'<path d="{RING_OUT}"/><path d="{RING_IN}"/><path d="{PLAY_D}"/></g>'
        return svg(s)

    def dims(ink):
        # Centre lines, and two dimensions: centre-to-edge down the left and
        # along the bottom, with architect's slash ticks.
        g = f'<g stroke="{ink}" stroke-linecap="round" fill="none">'
        g += ('<path stroke-width="5" stroke-dasharray="36 14 6 14" '
              'd="M512 330 V760 M330 512 H760"/>')
        g += '<path stroke-width="6" d="M160 512 H226 M160 834 H226 M190 870 V960 M512 870 V960"/>'
        g += '<path stroke-width="7" d="M126 512 V834 M190 918 H512"/>'
        g += ('<path stroke-width="10" d="M108 530 L144 494 M108 852 L144 816 '
              'M172 936 L208 900 M494 936 L530 900"/>')
        return svg(g + "</g>")

    def grid(ink):
        d = " ".join(f"M{v} 0 V1024 M0 {v} H1024" for v in range(32, 1024, 64))
        return svg(f'<path d="{d}" stroke="{ink}" stroke-width="3" fill="none" opacity=".22"/>')

    return Icon("blueprint", "Blueprint", "Drawn to scale",
                ("#2D6FCB", "#123F8C"), ("#0E2549", "#030A18"),
                [Group(Layer("mark", lines(WHITE), lines("#9FD4FF")), shadow=0.5),
                 Group(Layer("dims", dims(WHITE), dims("#9FD4FF"), opacity=0.8), shadow=0.2),
                 Group(Layer("grid", grid(WHITE), grid("#7FB6FF"), glass=False), shadow=0, translucency=0)],
                shelf="Finishes", asset="Blueprint")


def kraft():
    # A rubber stamp on brown card: the mark in red ink, a touch askew, with
    # dry-brush gaps where the ink didn't take (holes in the same even-odd path).
    def sliver(x, y, L, ang, w=7):
        a = math.radians(ang)
        ux, uy = math.cos(a) * L / 2, math.sin(a) * L / 2
        return (f"M{f(x - ux)} {f(y - uy)} Q{f(x - uy * w / L * 2)} {f(y + ux * w / L * 2)} {f(x + ux)} {f(y + uy)} "
                f"Q{f(x + uy * w / L * 2)} {f(y - ux * w / L * 2)} {f(x - ux)} {f(y - uy)} Z")
    # Dry-brush gaps, each well inside the ring's band so it cuts a hole.
    wear = [(360, 236, 90, -30), (420, 250, 60, -30), (660, 238, 70, -30), (240, 420, 80, -60),
            (250, 640, 60, -60), (780, 470, 70, -60), (770, 700, 90, -60), (560, 786, 80, -30),
            (330, 790, 60, -30)]
    holes = " ".join(sliver(*w) for w in wear)
    tspecks = " ".join(sliver(*w) for w in [(480, 470, 70, -30), (520, 560, 60, -30)])
    wrap = ('<g transform="rotate(-7 512 512)">', "</g>")

    def stamp(ink):
        return (svg(wrap[0] + path(RING_D + " " + holes, ink, EO) + wrap[1]),
                svg(wrap[0] + path(PLAY_D + " " + tspecks, ink, EO) + wrap[1]))
    r, t = stamp("#C3362B")
    rd, td = stamp("#F06A55")
    rm, tm = stamp(WHITE)
    fibres = svg('<g stroke="#6B4A22" stroke-linecap="round" fill="none" opacity=".18" stroke-width="4">'
                 '<path d="M60 380 q80 -12 150 4"/><path d="M700 150 q60 10 120 -6"/>'
                 '<path d="M90 820 q70 14 140 -2"/><path d="M620 960 q90 -10 170 6"/>'
                 '<path d="M380 60 q50 8 110 -4"/><path d="M330 980 q40 -8 90 2"/></g>')
    return Icon("kraft", "Kraft", "Handle with care",
                ("#D2A873", "#A67B47"), ("#4A3520", "#1C130A"),
                [Group(Layer("play", t, td, mono=tm), shadow=0.3, translucency=0.2),
                 Group(Layer("ring", r, rd, mono=rm), shadow=0.3, translucency=0.2),
                 Group(Layer("fibres", fibres, glass=False), shadow=0, translucency=0)],
                bubbles=("#5C3D1C", "#E8C99A"), shelf="Finishes", asset="Kraft")


def marble():
    # Verde marble on Carrara by day; Carrara on nero marquina by night.
    veins = ('<path d="M-20 700 C180 640 260 760 420 690 S700 560 1040 620"/>'
             '<path d="M-20 260 C120 300 300 220 460 300 S760 420 1040 330"/>'
             '<path d="M300 -20 C340 160 260 300 380 470 S520 760 470 1040"/>')

    def bg_veins(ink, op):
        return svg(f'<g fill="none" stroke="{ink}" stroke-linecap="round" opacity="{op}">'
                   f'<g stroke-width="7">{veins}</g></g>')

    # Veins are cut to the ring's band: the outer squircle, then four strips
    # (a clip's own even-odd rule is ignored, so the hole can't be cut out).
    strips = "".join(f'<rect x="{x}" y="{y}" width="{w}" height="{h}"/>' for x, y, w, h in
                     [(180, 180, 664, 114), (180, 730, 664, 114), (180, 180, 114, 664), (730, 180, 114, 664)])
    clip = f'<clipPath id="mo"><path d="{RING_OUT}"/></clipPath><clipPath id="mb">{strips}</clipPath>'

    def stone(vein, grad_stops):
        defs = clip + grad("ms", grad_stops, 0, 0, 1, 1)
        v = (f'<g fill="none" stroke="{vein}" stroke-width="9" stroke-linecap="round" opacity=".6">'
             '<path d="M150 300 C260 380 230 520 250 640 S320 800 520 790 S700 820 880 900"/>'
             '<path d="M300 150 C420 260 560 200 640 250 S760 250 880 180"/>'
             '<path d="M880 420 C760 500 800 600 760 700"/></g>')
        return svg(ring("url(#ms)") + f'<g clip-path="url(#mo)"><g clip-path="url(#mb)">{v}</g></g>', defs)

    green = [(0, "#2F6E5A"), (.5, "#153E33"), (1, "#0B241E")]
    white = [(0, "#FFFFFF"), (.5, "#ECE8E2"), (1, "#D6D1C9")]
    r = stone("#CDE7DC", green)
    rd = stone("#9A958E", white)
    t = svg(tri("#1F5747"))
    td = svg(tri("#F4F1EC"))
    return Icon("marble", "Marble", "Lobby of a grand cinema",
                ("#F7F5F1", "#DCD7CF"), ("#26262A", "#08080A"),
                [Group(Layer("play", t, td, mono=td), shadow=0.5),
                 Group(Layer("ring", r, rd, mono=svg(ring(WHITE))), shadow=0.5),
                 Group(Layer("veins", bg_veins("#8F8A83", .35), bg_veins("#CFCAC2", .3), glass=False),
                       shadow=0, translucency=0)],
                diagonal=True, bubbles=("#6F8F84", WHITE), shelf="Finishes", asset="Marble")


def sapphire():
    # The ring cut into eight facets around the centre; the play a three-facet
    # pyramid lit from the top left.
    tones = ["#9CC3FF", "#5E93F5", "#2E62D9", "#1A43B0", "#0E2C86", "#1B49BD", "#3C74E6", "#78A8FF"]
    clips, body = "", ""
    for i, c in enumerate(tones):
        a0 = math.radians(-112.5 + i * 45)
        a1 = a0 + math.radians(45.6)
        pts = [(512, 512), (512 + 900 * math.cos(a0), 512 + 900 * math.sin(a0)),
               (512 + 900 * math.cos(a1), 512 + 900 * math.sin(a1))]
        clips += f'<clipPath id="s{i}"><path d="{poly(pts)}"/></clipPath>'
        body += f'<g clip-path="url(#s{i})">{ring(c)}</g>'
    r = svg(body, clips)
    # Facets of the play: apex points from its rounded outline to the centroid.
    x = 512 + 248 * 0.06
    A, B, C = (x - 248 * .45, 512 - 134), (x + 248 * .55, 512), (x - 248 * .45, 512 + 134)
    G = ((A[0] + B[0] + C[0]) / 3 + 6, 512)
    tclip = f'<clipPath id="tp"><path d="{PLAY_D}"/></clipPath>'
    facets = "".join(path(poly([p, q, G]), c) for p, q, c in
                     [(A, B, "#EAF3FF"), (B, C, "#7FB0FF"), (C, A, "#B9D5FF")])
    t = svg(f'<g clip-path="url(#tp)">{facets}</g>', tclip)
    return Icon("sapphire", "Sapphire", "Cut for the big screen",
                ("#1A3C9E", "#06103F"), ("#0A1740", "#010311"),
                [Group(Layer("play", t), shadow=0.6), Group(Layer("ring", r), shadow=0.6, translucency=0.5)],
                diagonal=True, bubbles=("#BFD8FF", None), shelf="Finishes", asset="Sapphire")


# ================================================================== Colourful


def citrus():
    leaf = ("M676 214 C700 130 790 96 872 108 C850 190 780 236 676 214 Z")
    rib = '<path d="M690 206 C740 170 800 140 852 118" fill="none" stroke="#2E8B2E" stroke-width="8" stroke-linecap="round"/>'
    stem = '<path d="M660 226 C662 200 670 180 690 160" fill="none" stroke="#3A6B1E" stroke-width="14" stroke-linecap="round"/>'
    return Icon("citrus", "Citrus", "Freshly squeezed",
                ("#FFC43D", "#FF7A1A"), ("#4A2508", "#170A02"),
                [Group(Layer("leaf", svg(stem + path(leaf, "#5BC236") + rib)), shadow=0.5),
                 Group(Layer("play", svg(tri("#7ED957"))), shadow=0.5),
                 Group(Layer("ring", svg(ring("#FFF06A"))), shadow=0.5)],
                diagonal=True, shelf="Colourful", asset="Citrus")


def aurora():
    def curtains(c1, c2, op):
        # Two ribbons, bright along their top edge and fading to nothing below.
        defs = (f'<linearGradient id="ga" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{c1}"/>'
                f'<stop offset="1" stop-color="{c1}" stop-opacity="0"/></linearGradient>'
                f'<linearGradient id="gb" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{c2}"/>'
                f'<stop offset="1" stop-color="{c2}" stop-opacity="0"/></linearGradient>')
        g1 = ("M-20 330 C160 150 360 110 540 190 S860 150 1044 40 L1044 380 "
              "C860 470 700 420 540 470 S200 640 -20 700 Z")
        g2 = ("M-20 560 C200 440 420 520 620 420 S900 300 1044 330 L1044 700 "
              "C860 660 700 760 520 780 S180 860 -20 900 Z")
        return svg(f'<g opacity="{op}">{path(g2, "url(#gb)")}{path(g1, "url(#ga)")}</g>', defs)
    stars = stars_layer([(420, 80, 12, .8), (640, 64, 9, .6), (80, 460, 10, .6), (930, 250, 12, .8)])
    defs = grad("am", [(0, "#E6FFF4"), (.55, "#9AF7D2"), (1, "#D8B8FF")], 0, 0, 1, 1)
    r = svg(ring("url(#am)"), defs)
    return Icon("aurora", "Aurora", "Lights out, lights up",
                ("#123058", "#030816"), ("#081A33", "#010308"),
                [Group(Layer("play", svg(tri(WHITE))), shadow=0.5),
                 Group(Layer("ring", r), shadow=0.5),
                 Group(Layer("curtains", curtains("#3DFFA8", "#C070FF", .8),
                             curtains("#2BD58A", "#9A50F0", .65), glass=False),
                       Layer("stars", svg(stars), glass=False), shadow=0, translucency=0)],
                shelf="Colourful", asset="Aurora")


def tropic():
    def frond(x0, y0, x1, y1, bend, n=9, reach=150):
        # A palm frond: a curved rib, slender leaflets both sides, one path.
        # Every leaflet is wound the same way, so the nonzero fill unions them.
        def at(t):
            mx, my = (x0 + x1) / 2 + bend[0], (y0 + y1) / 2 + bend[1]
            x = (1 - t) ** 2 * x0 + 2 * (1 - t) * t * mx + t * t * x1
            y = (1 - t) ** 2 * y0 + 2 * (1 - t) * t * my + t * t * y1
            dx = 2 * (1 - t) * (mx - x0) + 2 * t * (x1 - mx)
            dy = 2 * (1 - t) * (my - y0) + 2 * t * (y1 - my)
            L = math.hypot(dx, dy)
            return x, y, dx / L, dy / L
        d = []
        # the rib
        pts_l, pts_r = [], []
        for i in range(21):
            x, y, ux, uy = at(i / 20)
            w = 9 * (1 - i / 20) + 2
            pts_l.append((x - uy * w, y + ux * w))
            pts_r.append((x + uy * w, y - ux * w))
        d.append(poly(pts_l + pts_r[::-1]))
        for i in range(1, n + 1):
            t = 0.12 + 0.84 * i / n
            x, y, ux, uy = at(t)
            ln = reach * math.sin(math.pi * (0.2 + 0.75 * t)) + 30
            for side in (1, -1):
                # leaflet swept forward along the rib
                vx, vy = ux * 0.55 - side * uy, uy * 0.55 + side * ux
                L = math.hypot(vx, vy)
                vx, vy = vx / L, vy / L
                tx, ty = x + vx * ln, y + vy * ln
                nx, ny = -vy * 24, vx * 24
                c1 = (x + vx * ln * .5 + nx, y + vy * ln * .5 + ny)
                c2 = (x + vx * ln * .5 - nx, y + vy * ln * .5 - ny)
                a, b = (c1, c2) if side == 1 else (c2, c1)
                d.append(f"M{f(x)} {f(y)} Q{f(a[0])} {f(a[1])} {f(tx)} {f(ty)} "
                         f"Q{f(b[0])} {f(b[1])} {f(x)} {f(y)} Z")
        return " ".join(d)
    f1 = frond(-30, 1060, 330, 640, (-40, -60))
    f2 = frond(1060, -40, 690, 250, (60, 40), n=7, reach=120)
    leaves = svg(path(f1, "#119C63") + path(f2, "#119C63"))
    leaves_d = svg(path(f1, "#1F8A5A") + path(f2, "#1F8A5A"))
    return Icon("tropic", "Tropic", "Binge on the beach",
                ("#FFB36B", "#FF4F7B"), ("#3A0F2A", "#12040C"),
                [Group(Layer("play", svg(tri(WHITE))), shadow=0.5),
                 Group(Layer("ring", svg(ring("#FFE45C"))), shadow=0.5),
                 Group(Layer("leaves", leaves, leaves_d), shadow=0.3)],
                diagonal=True, shelf="Colourful", asset="Tropic")


def bubblegum():
    # A glossy gum-pink mark with a big shine along the top-left of the ring.
    shine = ("M244 420 C244 300 300 244 420 244 L560 244 C580 244 590 262 574 272 "
             "C520 276 420 280 360 300 C300 320 276 380 272 520 C264 540 244 532 244 510 Z")
    return Icon("bubblegum", "Bubblegum", "Pop goes the season",
                ("#8FE3FF", "#3E9BFF"), ("#10244D", "#050A1C"),
                [Group(Layer("shine", svg(path(shine, WHITE, ' opacity=".85"'))), shadow=0),
                 Group(Layer("play", svg(tri("#FF3D98"))), shadow=0.5),
                 Group(Layer("ring", svg(ring("#FF7EC0"))), shadow=0.5)],
                diagonal=True, shelf="Colourful", asset="Bubblegum")


def mint():
    # Mint choc chip: a chocolate mark on mint, with a few shaved chips.
    chips = [(150, 560, 36, 10), (400, 910, 32, -20), (640, 104, 32, 30),
             (112, 800, 28, -35), (600, 930, 24, 70)]

    def chip(x, y, s, rot, ink):
        pts = [(x - s, y - s * .5), (x - s * .1, y - s * .95), (x + s, y - s * .35),
               (x + s * .7, y + s * .8), (x - s * .6, y + s * .75)]
        return f'<g transform="rotate({rot} {x} {y})">{path(rounded_poly(pts, s * .3), ink)}</g>'

    def chips_art(ink):
        return svg("".join(chip(*c, ink) for c in chips))
    choc, mintc = "#4A2C1E", "#9FF0CC"
    return Icon("mint", "Mint", "Mint choc chip, two scoops",
                ("#C8F7E1", "#79DDB5"), ("#123A2E", "#04130E"),
                [Group(Layer("play", svg(tri(choc)), svg(tri(mintc)), mono=svg(tri(WHITE))), shadow=0.5),
                 Group(Layer("ring", svg(ring(choc)), svg(ring(mintc)), mono=svg(ring(WHITE))), shadow=0.5),
                 Group(Layer("chips", chips_art(choc), chips_art("#6B4430"), mono=chips_art(WHITE)), shadow=0.3)],
                bubbles=(choc, mintc), shelf="Colourful", asset="Mint")


def lavender():
    # A sprig laid across the ring's bottom-left corner: a stem, then a spike
    # of whorls that tightens and shrinks towards the tip, buds as one path.
    x0, y0, x1, y1 = 60, 1020, 410, 540
    L = math.hypot(x1 - x0, y1 - y0)
    ux, uy = (x1 - x0) / L, (y1 - y0) / L
    px_, py_ = -uy, ux
    buds = []
    n = 7
    for i in range(n):
        t = 0.38 + 0.62 * i / (n - 1)
        x, y = x0 + (x1 - x0) * t, y0 + (y1 - y0) * t
        s = 46 - 18 * i / (n - 1)
        # a whorl: two buds flared either side, one riding the stem
        for side in (-1, 1):
            buds.append(circle(x + px_ * side * s * .75 + ux * s * .3, y + py_ * side * s * .75 + uy * s * .3, s * .62))
        buds.append(circle(x + ux * s * .55, y + uy * s * .55, s * .6))
    buds.append(circle(x1 + ux * 34, y1 + uy * 34, 17))
    buds_d = " ".join(buds)
    stem = f'<path d="M{x0} {y0} L{x0 + (x1 - x0) * .5} {y0 + (y1 - y0) * .5}" stroke="#5E8C4A" stroke-width="14" stroke-linecap="round" fill="none"/>'
    leaf = "M150 905 Q64 890 36 786 Q128 812 150 905 Z"
    sprig = svg(stem + path(leaf, "#5E8C4A") + path(buds_d, "#4B25A8"))
    sprig_d = svg(stem.replace("#5E8C4A", "#7FAF68") + path(leaf, "#7FAF68") + path(buds_d, "#C9A8FF"))
    sprig_m = svg(stem.replace("#5E8C4A", WHITE) + path(leaf, WHITE) + path(buds_d, WHITE))
    return Icon("lavender", "Lavender", "Calm, then credits",
                ("#E8DDFF", "#B79CF5"), ("#241638", "#0A0612"),
                [Group(Layer("sprig", sprig, sprig_d, mono=sprig_m), shadow=0.5),
                 Group(Layer("play", svg(tri(WHITE)), svg(tri("#F1E8FF"))), shadow=0.5),
                 Group(Layer("ring", svg(ring("#9E7FEE")), svg(ring("#6E4BC4")), mono=svg(ring(WHITE))),
                       shadow=0.5)],
                diagonal=True, bubbles=("#5B35B0", "#D9C8FF"), shelf="Colourful", asset="Lavender")


def popart():
    # Ben-Day dots on yellow, a comic burst behind the corner, a thick-lined mark.
    dots = []
    for row, y in enumerate(range(0, 1060, 40)):
        for x in range(-20 if row % 2 else 0, 1060, 40):
            r = 4 + 9 * (1 - y / 1024) * (x / 1024)
            dots.append(circle(x, y, max(3, r)))
    dots_d = " ".join(dots)
    burst = star(650, 250, 250, 170, points=12, rot=-80)

    def art(ring_c, play_c, line):
        s = f' stroke="{line}" stroke-width="22" stroke-linejoin="round"'
        return svg(ring(ring_c, s)), svg(tri(play_c, s))
    r, t = art("#00A8F0", WHITE, "#111111")
    rd, td = art("#00C2FF", "#FFE500", "#000000")
    return Icon("popart", "Pop Art", "Wham! Season finale!",
                ("#FFE94D", "#FFC400"), ("#2A0E3D", "#0E0418"),
                [Group(Layer("play", t, td), shadow=0.4),
                 Group(Layer("ring", r, rd), shadow=0.4),
                 Group(Layer("burst", svg(path(burst, "#FF2E4D", ' stroke="#111111" stroke-width="16" stroke-linejoin="round"')),
                             svg(path(burst, "#FF2E88", ' stroke="#000000" stroke-width="16" stroke-linejoin="round"'))),
                       shadow=0.3),
                 Group(Layer("dots", svg(path(dots_d, "#FF4D6D", ' opacity=".55"')),
                             svg(path(dots_d, "#FF3DA5", ' opacity=".45"')), glass=False),
                       shadow=0, translucency=0)],
                bubbles=("#111111", WHITE), shelf="Colourful", asset="PopArt")


def duotone():
    # The ground split on the diagonal; the mark swaps ink as it crosses.
    A, B = "#FF4D8D", "#2B2FD9"
    Ad, Bd = "#B8285E", "#16178A"
    tl = poly([(-10, -10), (1034, -10), (-10, 1034)])
    br = poly([(1034, -10), (1034, 1034), (-10, 1034)])
    defs = f'<clipPath id="tl"><path d="{tl}"/></clipPath><clipPath id="br"><path d="{br}"/></clipPath>'

    def two(d, a, b, rule=""):
        return svg(f'<g clip-path="url(#tl)">{path(d, b, rule)}</g><g clip-path="url(#br)">{path(d, a, rule)}</g>',
                   defs)
    half = svg(path(br, B))
    half_d = svg(path(br, Bd))
    return Icon("duotone", "Duotone", "Two tones, one show",
                (A, "#FF7AA8"), (Ad, "#7A1640"),
                [Group(Layer("play", two(PLAY_D, A, B), two(PLAY_D, "#FF7AA8", "#6E72FF"),
                             mono=svg(tri(WHITE))), shadow=0.5),
                 Group(Layer("ring", two(RING_D, A, B, EO), two(RING_D, "#FF7AA8", "#6E72FF", EO),
                             mono=svg(ring(WHITE))), shadow=0.5),
                 Group(Layer("half", half, half_d, glass=False), shadow=0, translucency=0)],
                diagonal=True, shelf="Colourful", asset="Duotone")


ICONS = [chrome(), rosegold(), onyx(), opal(), blueprint(), kraft(), marble(), sapphire(),
         citrus(), aurora(), tropic(), bubblegum(), mint(), lavender(), popart(), duotone()]
