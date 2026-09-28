"""Twenty more alternates: sea creatures for the Under the Sea shelf, night
scenes for After Dark, and odds and ends for Wildcards. Drawn with the same
kit and rules as app_icons.py: flat SVG layers, Liquid Glass does the depth.

Every one of them is the Aquarium mark first — the squircle ring with the play
button in its hole, never smaller than about 0.6 — and the theme is built
around it, the way rabbit_ears() turns the ring into a TV: the octopus hugs
it, the turtle wears it as a shell, the submarine looks out through it.

    python3 proof_sheet.py icons_sea <out-dir> [key ...]
"""

import math

from icon_kit import *  # noqa: F401,F403

SEA, DARK, WILD = "Under the Sea", "After Dark", "Wildcards"

# ------------------------------------------------------------------ helpers

HOLE_D = squircle(294, 294, 436, 436, 4.0)


def at(k, cx=512, cy=512, deg=0):
    """A `wrap` for mark_parts(): the mark scaled by k about its centre, moved
    to (cx, cy) and turned by deg."""
    r = f" rotate({f(deg)})" if deg else ""
    return (f'<g transform="translate({f(cx)} {f(cy)}){r} scale({k}) translate(-512 -512)">', "</g>")


def hole(fill, w):
    """The ring's hole filled in, for a screen or a porthole behind the play."""
    return svg(w[0] + path(HOLE_D, fill) + w[1])


def rim(t, half, cx, cy, n=4.2):
    """A point on a squircle of half-width `half` about (cx, cy), at angle t."""
    ct, st = math.cos(t), math.sin(t)
    return (cx + half * math.copysign(abs(ct) ** (2 / n), ct),
            cy + half * math.copysign(abs(st) ** (2 / n), st))


def place(k, fx, fy, tx, ty, body, deg=0):
    """Art drawn around (fx, fy), scaled by k and moved to (tx, ty)."""
    r = f" rotate({f(deg)})" if deg else ""
    return (f'<g transform="translate({f(tx)} {f(ty)}){r} scale({k}) translate({f(-fx)} {f(-fy)})">'
            f'{body}</g>')


def ell(cx, cy, rx, ry):
    return (f"M{f(cx - rx)} {f(cy)} A{f(rx)} {f(ry)} 0 1 0 {f(cx + rx)} {f(cy)} "
            f"A{f(rx)} {f(ry)} 0 1 0 {f(cx - rx)} {f(cy)} Z")


def line(d, ink, w, extra=""):
    return (f'<path d="{d}" fill="none" stroke="{ink}" stroke-width="{f(w)}" '
            f'stroke-linecap="round" stroke-linejoin="round"{extra}/>')


def rot(deg, cx, cy, body):
    return f'<g transform="rotate({f(deg)} {f(cx)} {f(cy)})">{body}</g>'


def mirror(body):
    return f'<g transform="translate(1024 0) scale(-1 1)">{body}</g>'


def eye(cx, cy, r, ink="#20142A", look=(0, 0)):
    """A round cartoon eye: the pupil and a catch-light."""
    x, y = cx + look[0], cy + look[1]
    return path(circle(x, y, r), ink) + path(circle(x - r * .32, y - r * .34, r * .34), WHITE)


def smile(cx, cy, w, ink, sw=14, depth=None):
    d = depth if depth is not None else w * .45
    return line(f"M{f(cx - w / 2)} {f(cy)} q{f(w / 2)} {f(d)} {f(w)} 0", ink, sw)


def cheeks(pts, r, ink="#FF4F9A", o=".5"):
    return "".join(path(circle(x, y, r), ink, f' opacity="{o}"') for x, y in pts)


def teardrop(cx, cy, r, h):
    """A raindrop: round at the bottom, pointed h above its centre."""
    return (f"M{f(cx)} {f(cy - h)} C{f(cx + r * .4)} {f(cy - h * .5)} {f(cx + r)} {f(cy - r * .3)} {f(cx + r)} {f(cy)} "
            f"A{f(r)} {f(r)} 0 0 1 {f(cx - r)} {f(cy)} C{f(cx - r)} {f(cy - r * .3)} {f(cx - r * .4)} {f(cy - h * .5)} {f(cx)} {f(cy - h)} Z")


def union(*ds):
    return " ".join(ds)


# ------------------------------------------------------------------ Under the Sea


def goldfish():
    """The goldfish swims over the top of the ring, nose down towards the play."""
    w = at(.72, 470, 590)
    ring, tri = mark_parts("#FFF6DE", "#FF7A1A", wrap=w)
    body = ("M244 540 C244 420 360 362 470 372 C560 380 620 448 636 540 "
            "C620 632 560 700 470 708 C360 718 244 660 244 540 Z")
    tail = ("M600 540 C640 470 690 386 776 352 C792 428 776 492 740 540 "
            "C776 588 792 652 776 728 C690 694 640 610 600 540 Z")
    dorsal = "M392 392 C410 286 520 262 590 330 C600 360 590 400 560 412 Z"
    clip = f'<clipPath id="bb"><path d="{body}"/></clipPath>'
    fish = (path(union(tail, dorsal), "#FFD36B") + path(body, "#FF8A1F")
            + f'<g clip-path="url(#bb)">{path(ell(470, 690, 250, 110), "#FFB347")}</g>')
    face = (path(circle(342, 500, 50), WHITE) + eye(350, 504, 26)
            + rot(28, 492, 596, path(ell(492, 596, 54, 28), "#FFD36B"))
            + smile(286, 580, 36, "#8A3A00", 12, 14) + cheeks([(382, 572)], 22))
    k, fx, fy, tx, ty, d = .64, 510, 540, 668, 300, -16
    return Icon("goldfish", "Goldfish", "Forgets how it ends",
                ("#8BEFF5", "#1A8FD0"), ("#0B3452", "#020A16"),
                [Group(Layer("face", svg(place(k, fx, fy, tx, ty, face, d))),
                       Layer("fish", svg(place(k, fx, fy, tx, ty, fish, d), clip)), shadow=0.4),
                 Group(Layer("play", tri), shadow=0.5),
                 Group(Layer("ring", ring))], shelf=SEA, asset="Goldfish")


def octopus():
    """The octopus sits on the ring and hugs it, two arms down its sides."""
    w = at(.7, 512, 596)          # ring x 287-737, y 371-821
    ring, tri = mark_parts("#FFF3E6", "#FF6F5E", wrap=w)
    head = path(ell(512, 262, 186, 164), "#FF6F5E") + path(ell(430, 172, 46, 30), "#FF9C8C")
    back = "".join(line(d, "#E8503F", 46) for d in [
        "M390 380 C300 372 230 330 206 268 C192 226 226 206 246 232",
        "M634 380 C724 372 794 330 818 268 C832 226 798 206 778 232"])
    face = (path(ell(444, 262, 46, 52), WHITE) + path(ell(580, 262, 46, 52), WHITE)
            + eye(452, 272, 24) + eye(588, 272, 24)
            + smile(512, 334, 52, "#5A1418", 13) + cheeks([(388, 330), (636, 330)], 24, "#C8203A", ".45"))
    left = "M404 392 C330 404 300 470 314 560 C328 660 312 770 262 812 C222 846 180 818 204 786"
    arms = line(left, "#FF6F5E", 50) + mirror(line(left, "#FF6F5E", 50))
    suckers = "".join(path(circle(x, y, 9), "#FFC2B8") for x, y in
                      [(300, 470), (296, 560), (300, 650), (290, 740), (236, 812)])
    arms += suckers + mirror(suckers)
    return Icon("octopus", "Octopus", "Eight arms, one remote",
                ("#5FE6C0", "#0E8C8C"), ("#0B3A3C", "#021112"),
                [Group(Layer("arms", svg(arms)), Layer("play", tri), shadow=0.4),
                 Group(Layer("ring", ring)),
                 Group(Layer("face", svg(face)), Layer("head", svg(head + back)))], shelf=SEA, asset="Octopus")


def whale():
    """A whale cruises behind the ring — head out one side, tail the other —
    and spouts over the top."""
    w = at(.72, 540, 604)         # ring x 308-772, y 372-836
    ring, tri = mark_parts("#F2FAFF", "#3E6BF0", wrap=w)
    body = ("M92 352 C92 262 196 212 336 212 C480 212 612 240 712 292 C768 320 808 332 850 326 "
            "L856 362 C800 402 704 432 596 442 L320 446 C168 446 92 424 92 352 Z")
    flukes = ("M838 350 C846 290 876 238 928 212 C942 262 924 306 888 336 "
              "C934 324 976 338 1000 368 C956 388 896 384 838 362 Z")
    clip = f'<clipPath id="wb"><path d="{body}"/></clipPath>'
    whale_ = (path(union(body, flukes), "#5BB4FF")
              + f'<g clip-path="url(#wb)">{path(ell(360, 480, 300, 92), "#DDF3FF")}</g>')
    face = eye(206, 318, 20) + smile(170, 378, 110, "#1E3A78", 12, 22) + cheeks([(254, 366)], 20, "#FF7BA8", ".55")
    spout = (line("M386 208 C376 160 346 132 306 124", "#C8F2FF", 24)
             + line("M394 208 C404 160 436 128 480 118", "#C8F2FF", 24)
             + path(teardrop(390, 104, 22, 44), "#C8F2FF")
             + path(circle(290, 176, 12), "#C8F2FF") + path(circle(500, 170, 12), "#C8F2FF"))
    return Icon("whale", "Whale", "Big screen energy",
                ("#7C88FF", "#2B2CA8"), ("#15165A", "#04041A"),
                [Group(Layer("play", tri), shadow=0.5),
                 Group(Layer("ring", ring)),
                 Group(Layer("face", svg(face)), Layer("spout", svg(spout)), Layer("whale", svg(whale_, clip)))],
                shelf=SEA, asset="Whale")


def puffer():
    """The ring puffed up: spines all round it, eyes along the top."""
    cx, cy, k = 500, 548, .72
    w = at(k, cx, cy)             # ring x 268-732, y 316-780
    ring, tri = mark_parts("#FFD23F", "#FFF6D2", wrap=w)
    spikes = []
    n = 26
    for i in range(n):
        t = 2 * math.pi * i / n + .06
        a, b = rim(t - .09, 322 * k - 16, cx, cy), rim(t + .09, 322 * k - 16, cx, cy)
        tip = rim(t, 322 * k + 64, cx, cy)
        spikes.append(rounded_poly([a, tip, b], 8))
    spines = path(union(*spikes), "#F29A16")
    tail = path("M720 548 C770 490 820 466 850 456 C840 520 840 576 850 640 C820 630 770 606 720 548 Z", "#F29A16")
    face = (path(circle(400, 352, 44), WHITE) + eye(392, 358, 24, look=(-4, 0))
            + path(circle(506, 352, 38), WHITE) + eye(498, 358, 20, look=(-4, 0))
            + path(ell(304, 590, 24, 28), "#7A2A10") + path(ell(304, 598, 11, 11), "#FF7A6B")
            + cheeks([(316, 420), (590, 356)], 18, "#FF6B6B", ".55")
            + path("M300 690 C330 700 350 730 346 770 C316 760 296 730 300 690 Z", "#FFB020"))
    return Icon("puffer", "Pufferfish", "Prickly about spoilers",
                ("#FFB8C4", "#EE5C7E"), ("#4A0F24", "#14030A"),
                [Group(Layer("face", svg(face)), Layer("play", tri), shadow=0.4),
                 Group(Layer("ring", ring)),
                 Group(Layer("spines", svg(spines + tail)))], shelf=SEA, asset="Pufferfish")


def seahorse():
    """A seahorse leans on the ring, its tail curled round the corner."""
    w = at(.7, 606, 548)          # ring x 381-831, y 323-773
    ring, tri = mark_parts("#FFF0FA", "#8A4FF0", wrap=w)
    body = ("M300 352 L404 326 C420 254 478 222 540 228 C612 236 650 300 628 366 "
            "C668 426 694 510 668 596 C648 666 604 708 560 724 "
            "C470 740 404 680 408 590 C410 530 440 500 452 486 "
            "C432 462 420 434 404 404 L300 394 C282 390 282 356 300 352 Z")
    tail = line("M540 716 C504 790 516 866 592 884 C652 898 700 842 670 800 C646 770 606 786 618 818", "#FF9A2E", 58)
    crest = path("M500 236 L520 176 L548 232 Z M556 238 L596 196 L604 256 Z M600 270 L650 250 L630 312 Z", "#FFD36B")
    dorsal = path("M664 470 C730 468 772 530 752 600 C730 610 700 600 676 590 Z", "#FFD36B")
    ridges = "".join(line(f"M{x1} {y1} q24 -6 44 8", "#FFC66B", 12) for x1, y1 in
                     [(440, 560), (438, 606), (446, 650), (468, 690)])
    face = eye(530, 318, 26) + cheeks([(560, 376)], 22, "#FF4F7A", ".5") + path(circle(306, 373, 7), "#7A2A10")
    pl = (.74, 540, 480, 286, 498)
    return Icon("seahorse", "Seahorse", "Dad's on night feeds",
                ("#CDA2FF", "#6A3FD8"), ("#2A1560", "#0A0420"),
                [Group(Layer("face", svg(place(*pl, face))), Layer("seahorse", svg(place(*pl, path(body, "#FF9A2E") + tail + ridges))),
                       Layer("fins", svg(place(*pl, crest + dorsal))), shadow=0.4),
                 Group(Layer("play", tri), shadow=0.5),
                 Group(Layer("ring", ring))], shelf=SEA, asset="Seahorse")


def coral():
    """The ring sits in the reef, coral growing up round its feet."""
    w = at(.68, 512, 440)         # ring x 293-731, y 221-659
    ring, tri = mark_parts("#FFF4F8", "#FF5C9A", wrap=w)
    # A branch coral up the left of the ring and a sea fan up the right, both
    # reaching over its lower corners.
    branch = "".join(line(d, "#FF6FA8", 50) for d in [
        "M250 960 L250 560", "M250 820 C180 780 150 730 150 620", "M150 720 C120 690 112 650 114 590",
        "M250 700 C310 660 330 610 330 540", "M250 600 C220 560 210 520 212 470",
        "M330 620 C366 600 380 580 382 560"])
    fan = "".join(line(d, "#FF9A3C", 30) for d in [
        "M770 960 L770 560", "M770 840 C710 810 690 760 692 640", "M770 800 C830 770 860 720 858 600",
        "M692 720 C660 700 650 670 650 620", "M858 690 C890 672 900 640 898 600", "M770 640 C750 600 740 560 744 500",
        "M770 660 C800 620 812 580 810 520"])
    dome = path("M400 960 C400 830 450 780 512 780 C574 780 624 830 624 960 Z", "#FFD24A")
    grooves = "".join(line(d, "#F2A516", 11) for d in
                      ["M440 900 C448 850 480 822 520 826", "M470 940 C480 900 520 882 560 894"])
    grass = "".join(line(d, "#3DDC97", 22) for d in
                    ["M340 970 C320 900 350 860 326 800", "M670 970 C690 910 660 870 680 820",
                     "M880 970 C900 900 870 860 890 810"])
    sand = path("M40 1024 L40 940 C240 900 420 910 560 930 C700 950 820 936 990 952 L990 1024 Z", "#F7D596")
    fish = (path(ell(180, 420, 64, 40), "#FF7A2E") + path(rounded_poly([(230, 420), (280, 386), (280, 454)], 12), "#FF7A2E")
            + f'<g clip-path="url(#cf)"><rect x="150" y="370" width="20" height="100" fill="{WHITE}"/>'
            + f'<rect x="200" y="370" width="18" height="100" fill="{WHITE}"/></g>'
            + eye(144, 412, 10))
    clip = f'<clipPath id="cf"><path d="{ell(180, 420, 64, 40)}"/></clipPath>'
    return Icon("coral", "Coral Reef", "Colour graded by nature",
                ("#34B8FF", "#0B3E9C"), ("#0A2356", "#020818"),
                [Group(Layer("coral", svg(branch + fan + grass)), Layer("fish", svg(fish, clip)), shadow=0.4),
                 Group(Layer("play", tri), Layer("ring", ring)),
                 Group(Layer("dome", svg(dome + grooves)), Layer("sand", svg(sand)), shadow=0.2)],
                shelf=SEA, asset="CoralReef")


def turtle():
    """The ring is the turtle's shell."""
    c, tilt = (512, 548), -14
    w = at(.7, *c, deg=tilt)
    ring, tri = mark_parts("#2E8F62", "#2E8F62", wrap=w)
    ring_m, tri_m = mark_parts(WHITE, WHITE, wrap=w)
    shell = hole("#C8F09E", w)
    fl = "#7ACB6A"
    flip = (path("M340 420 C260 380 190 300 170 228 C262 228 352 290 392 364 Z", fl)
            + path("M346 690 C284 730 252 790 262 846 C324 832 376 776 388 724 Z", fl))
    limbs = (flip + mirror(flip) + path("M488 780 L512 860 L536 780 Z", fl) + path(ell(512, 250, 72, 80), fl))
    face = eye(486, 236, 14) + eye(538, 236, 14) + smile(512, 276, 34, "#1D4A2A", 10, 12)
    return Icon("turtle", "Sea Turtle", "Slow TV, done right",
                ("#FFE6A8", "#2EC0C2"), ("#0C3A40", "#021214"),
                [Group(Layer("play", tri, mono=tri_m), shadow=0.4),
                 Group(Layer("ring", ring, mono=ring_m), Layer("shell", shell, mono=hole("#3A3A3A", w))),
                 Group(Layer("face", svg(rot(tilt, *c, face))), Layer("limbs", svg(rot(tilt, *c, limbs))))],
                bubbles=("#1E8C94", WHITE), shelf=SEA, asset="SeaTurtle")


def submarine():
    """The ring is the submarine's big porthole."""
    w = at(.62, 486, 600)         # ring x 286-686, y 400-800
    ring, tri = mark_parts("#FFF4E0", "#FFD84D", wrap=w)
    glass = hole("#0F2F66", w)
    hull = (path(rr(124, 372, 800, 456, 228), "#FF6B4A") + path(rr(380, 236, 230, 170, 50), "#FF6B4A")
            + line("M560 244 L560 150 L636 150", "#E24A30", 28)
            + path(ell(96, 600, 26, 80), "#E24A30") + path(rr(96, 584, 46, 32, 12), "#E24A30")
            + "".join(path(circle(x, 800, 8), "#E24A30") for x in range(260, 800, 60))
            + path(circle(800, 560, 42), "#FFF4E0") + path(circle(800, 560, 28), "#0F2F66"))
    return Icon("submarine", "Submarine", "Deep dive into season 4",
                ("#2AB8E8", "#0A2F72"), ("#0A1F48", "#01050F"),
                [Group(Layer("play", tri), shadow=0.5),
                 Group(Layer("ring", ring), Layer("glass", glass)),
                 Group(Layer("hull", svg(hull)))], shelf=SEA, asset="Submarine")


# ------------------------------------------------------------------ After Dark


def galaxy():
    """A spiral galaxy wheeling round the ring."""
    cx, cy = 512, 530
    w = at(.72, cx, cy)
    defs = lin("gr", "#FFF1FA", "#CDEBFF", 0, 0, 1, 1)
    ring, tri = mark_parts("url(#gr)", "#FF6FD0", defs, wrap=w)

    def arm(phase):
        outer, inner = [], []
        n = 60
        for i in range(n + 1):
            t = i / n
            th = phase + t * 3.4
            r = 250 + 210 * t
            wd = 12 + 70 * math.sin(math.pi * t ** .8) * (1 - t * .3)
            outer.append((r + wd, th))
            inner.append((max(0, r - wd * .6), th))
        pts = [(cx + r * math.cos(a), cy + r * math.sin(a) * .7) for r, a in outer + inner[::-1]]
        return "M" + " L".join(f"{f(x)} {f(y)}" for x, y in pts) + " Z"
    adefs = lin("ga", "#FF8BD8", "#7CD8FF", 0, 0, 1, 1)
    arms = svg(rot(-24, cx, cy, path(union(arm(0), arm(math.pi)), "url(#ga)")), adefs)
    halo = rot(-24, cx, cy, path(ell(cx, cy, 440, 300), "#B48CFF", ' opacity=".18"'))
    stars = svg(halo + stars_layer([(380, 150, 18, .9), (730, 170, 14, .8), (150, 820, 16, .8),
                                    (640, 930, 14, .7), (420, 950, 10, .6), (930, 250, 10, .6)]))
    return Icon("galaxy", "Galaxy", "Binge across the universe",
                ("#4A1A8C", "#0C0430"), ("#1E0A44", "#020008"),
                [Group(Layer("play", tri), shadow=0.6), Group(Layer("ring", ring), glass_shadow="layer-color", shadow=0.6),
                 Group(Layer("arms", arms), Layer("stars", stars, glass=False), translucency=0.3)],
                diagonal=True, shelf=DARK, asset="Galaxy")


def eclipse():
    """The ring is the moon in front of the sun: the corona blazes round it and
    the sun burns through its hole."""
    cx, cy, k = 506, 536, .72
    w = at(k, cx, cy)
    ring, tri = mark_parts("#14123A", "#14123A", wrap=w)
    ring_m, tri_m = mark_parts(WHITE, WHITE, wrap=w)
    defs = lin("sun", "#FFF6C8", "#FFB547", 0, 0, 1, 1)
    sun = svg(w[0] + path(HOLE_D, "url(#sun)") + w[1], defs)
    rays = []
    n = 16
    for i in range(n):
        t = 2 * math.pi * i / n
        a, b = rim(t - .16, 322 * k - 10, cx, cy), rim(t + .16, 322 * k - 10, cx, cy)
        rays.append(rounded_poly([a, rim(t, 322 * k + (110 if i % 2 else 70), cx, cy), b], 10))
    corona = svg(path(union(*rays), "#FFB547", ' opacity=".35"')
                 + path(squircle(cx - 322 * k - 40, cy - 322 * k - 40, 644 * k + 80, 644 * k + 80, 4.2), "#FFC56B", ' opacity=".3"')
                 + path(squircle(cx - 322 * k - 18, cy - 322 * k - 18, 644 * k + 36, 644 * k + 36, 4.2), "#FFE9A6", ' opacity=".6"'))
    diamond = svg(path(sparkle(cx - 214, cy - 214, 78), WHITE))
    stars = stars_layer([(880, 150, 14, .8), (130, 880, 14, .7), (900, 920, 10, .6)])
    return Icon("eclipse", "Eclipse", "Totality worth the wait",
                ("#2E2A66", "#07061A"), ("#14122E", "#000000"),
                [Group(Layer("diamond", diamond), Layer("play", tri, mono=tri_m), shadow=0.6),
                 Group(Layer("ring", ring, mono=ring_m), Layer("sun", sun, mono=hole("#3A3A3A", w))),
                 Group(Layer("corona", corona, glass=False), Layer("stars", svg(stars), glass=False),
                       shadow=0, translucency=0)],
                diagonal=True, shelf=DARK, asset="Eclipse")


def lighthouse():
    """The ring is the lighthouse's lamp, its beams sweeping out either side."""
    w = at(.6, 512, 392)          # ring x 319-705, y 199-585
    ring, tri = mark_parts("#FFE066", "#FF8A3D", wrap=w)
    tower_d = "M404 598 L620 598 L672 1040 L352 1040 Z"
    clip = f'<clipPath id="lt"><path d="{tower_d}"/></clipPath>'
    bands = "".join(f'<rect x="330" y="{y}" width="364" height="80" fill="#FF4D5E"/>' for y in (660, 820, 980))
    tower = (path(tower_d, "#FFF4E6") + f'<g clip-path="url(#lt)">{bands}</g>'
             + path(rr(484, 900, 56, 90, 28), "#3A2A4A") + path(rr(330, 580, 364, 36, 18), "#2E3A66")
             + path("M352 206 L512 104 L672 206 Z", "#FF4D5E") + path(circle(512, 96, 18), "#FF4D5E"))
    beams = (path("M340 330 L0 220 L0 470 L340 450 Z", "#FFE27A", ' opacity=".4"')
             + path("M684 330 L1024 220 L1024 470 L684 450 Z", "#FFE27A", ' opacity=".4"'))
    stars = stars_layer([(360, 110, 12, .7), (760, 110, 16, .9), (170, 620, 10, .6)])
    waves = line("M60 960 q40 -24 80 0 t80 0 t80 0", "#6FB8FF", 12) + line("M720 960 q40 -24 80 0 t80 0 t80 0", "#6FB8FF", 12)
    return Icon("lighthouse", "Lighthouse", "Keeps a light on for you",
                ("#23508A", "#0A1A38"), ("#0E2242", "#010610"),
                [Group(Layer("play", tri), shadow=0.6),
                 Group(Layer("ring", ring), glass_shadow="layer-color", shadow=0.7),
                 Group(Layer("tower", svg(tower, clip)),
                       Layer("beams", svg(beams + stars + waves), glass=False))],
                shelf=DARK, asset="Lighthouse")


def campfire():
    """A campfire burning at the foot of the glowing ring."""
    w = at(.7, 512, 420)          # ring x 287-737, y 195-645
    ring, tri = mark_parts("#FFC65C", "#FF5A2E", wrap=w)
    outer = ("M512 260 C560 350 668 440 648 600 C634 704 572 748 512 748 C436 748 372 700 374 600 "
             "C376 520 430 492 446 420 C476 456 490 480 490 500 C510 440 520 360 512 260 Z")
    inner = ("M516 470 C548 530 598 580 586 650 C578 704 548 724 512 724 C470 724 440 698 440 648 "
             "C440 600 476 590 488 540 C500 560 506 572 506 580 C516 548 522 510 516 470 Z")
    fire = place(.6, 512, 748, 512, 868, path(outer, "#FF6A3D") + path(inner, "#FFD84D"))
    logs = (rot(14, 512, 880, path(rr(300, 848, 424, 64, 32), "#9A5B34"))
            + rot(-14, 512, 880, path(rr(300, 848, 424, 64, 32), "#B8703F")))
    stones = "".join(path(ell(x, 950, 44, 28), "#4E5A6E") for x in (330, 420, 512, 604, 694))
    glow = "".join(path(squircle(512 - h, 420 - h, 2 * h, 2 * h, 4.2), "#FF9A3D", ' opacity=".12"')
                   for h in (270, 300, 336))
    sparks = (stars_layer([(760, 700, 16, .9), (250, 720, 12, .8), (800, 170, 10, .7)]).replace(WHITE, "#FFD34D")
              + stars_layer([(170, 520, 10, .6), (880, 560, 8, .6)]))
    return Icon("campfire", "Campfire", "Tell me a story",
                ("#1F5248", "#081A18"), ("#0E2A26", "#010605"),
                [Group(Layer("fire", svg(fire)), glass_shadow="layer-color", shadow=0.8),
                 Group(Layer("play", tri), Layer("ring", ring), glass_shadow="layer-color", shadow=0.7),
                 Group(Layer("logs", svg(logs + stones)), Layer("glow", svg(glow + sparks), glass=False))],
                shelf=DARK, asset="Campfire")


def rainyday():
    """A little rain cloud parked over the ring."""
    w = at(.7, 512, 612)          # ring x 287-737, y 387-837
    ring, tri = mark_parts("#9FDDFF", WHITE, wrap=w)
    cloud = "".join(path(d, "#EEF2FF") for d in
                    (circle(400, 250, 92), circle(520, 196, 124), circle(640, 256, 86), rr(300, 250, 430, 110, 55)))
    face = (line("M452 272 q20 16 40 0", "#44507A", 11) + line("M552 272 q20 16 40 0", "#44507A", 11)
            + smile(522, 306, 28, "#44507A", 10, 11))
    drops = "".join(path(teardrop(x, y, 15, 36), "#7FD8FF") for x, y in
                    [(360, 408), (452, 392), (576, 400), (668, 410), (200, 520), (170, 700), (230, 820),
                     (800, 300)])
    puddle = line("M250 930 q66 -26 132 0 t132 0 t132 0 t132 0", "#7FD8FF", 12)
    return Icon("rainyday", "Rainy Day", "Perfect weather for it",
                ("#6F8BC0", "#26345E"), ("#1C2744", "#05080F"),
                [Group(Layer("face", svg(face)), Layer("cloud", svg(cloud)), shadow=0.3),
                 Group(Layer("play", tri), shadow=0.5),
                 Group(Layer("ring", ring), Layer("rain", svg(drops + puddle)))],
                shelf=DARK, asset="RainyDay")


def skyline():
    """The ring is a neon billboard up on a downtown roof."""
    w = at(.64, 512, 404)         # ring x 306-718, y 198-610
    ring, tri = mark_parts("#FF5CA8", "#FFD86B", wrap=w)
    screen = hole("#241C5C", w)
    blds = [(40, 560, 120), (170, 440, 110), (740, 470, 110), (860, 600, 130), (300, 700, 424)]
    b_d = union(*[rr(x, y, bw, 1100 - y, 10) for x, y, bw in blds]) + " " + rr(206, 380, 12, 70, 6)
    posts = rr(400, 600, 26, 110, 6) + " " + rr(598, 600, 26, 110, 6)
    wins = []
    lit = [1, 0, 1, 1, 0, 1, 1, 1, 0, 1, 1, 0, 0, 1, 1, 1, 0, 1]
    k = 0
    for x, y, bw in blds:
        cols = max(2, int((bw - 20) // 34))
        for row in range(7):
            wy = y + 40 + row * 56
            if wy > 960:
                break
            for col in range(cols):
                wx = x + (bw - cols * 34 + 12) / 2 + col * 34
                if lit[k % len(lit)]:
                    wins.append(rr(wx, wy, 20, 30, 5))
                k += 1
    windows = path(union(*wins), "#FFD86B")
    city = path(b_d + " " + posts, "#1B1646")
    city_m = path(b_d + " " + posts, "#77779A")
    return Icon("skyline", "City Lights", "Downtown, after hours",
                ("#2B1F78", "#E0567A"), ("#120C3A", "#4A1236"),
                [Group(Layer("play", tri), glass_shadow="layer-color", shadow=0.6),
                 Group(Layer("ring", ring), Layer("screen", screen), glass_shadow="layer-color", shadow=0.7),
                 Group(Layer("windows", svg(windows)), Layer("city", svg(city), mono=svg(city_m)))],
                shelf=DARK, asset="CityLights")


# ------------------------------------------------------------------ Wildcards


def couch():
    """The couch potato, on the sofa, hugging the ring like a TV."""
    w = at(.62, 512, 560)         # ring x 312-712, y 360-760
    ring, tri = mark_parts(WHITE, "#FF4F8B", wrap=w)
    screen = hole("#2A2150", w)
    sofa = (path(rr(150, 560, 724, 260, 80), "#3E7BFA")
            + path(rr(110, 680, 150, 220, 60), "#2F62D8") + path(rr(764, 680, 150, 220, 60), "#2F62D8")
            + path(rr(200, 800, 624, 130, 50), "#5A93FF")
            + path(rr(190, 920, 40, 60, 14), "#1D3C8C") + path(rr(794, 920, 40, 60, 14), "#1D3C8C"))
    potato = path("M500 180 C590 170 668 220 682 310 C692 380 700 460 700 560 L324 560 "
                  "C324 460 330 380 340 300 C354 220 420 186 500 180 Z", "#DDA464")
    spots = "".join(line(f"M{x - 12} {y} q12 -8 24 0", "#A8703A", 8) for x, y in
                    [(420, 230), (620, 250), (650, 330), (372, 320)])
    face = (line("M442 282 q22 18 44 0", "#4A2C14", 13) + line("M540 282 q22 18 44 0", "#4A2C14", 13)
            + smile(514, 324, 44, "#4A2C14", 12, 18) + cheeks([(420, 330), (608, 330)], 20, "#FF7A6B", ".55"))
    hands = path(ell(318, 540, 34, 40), "#E6B173") + path(ell(706, 540, 34, 40), "#E6B173")
    return Icon("couch", "Couch Potato", "Just one more episode",
                ("#FFB8D2", "#F0608C"), ("#4A1026", "#12030A"),
                [Group(Layer("hands", svg(hands)), Layer("play", tri), shadow=0.4),
                 Group(Layer("ring", ring), Layer("screen", screen)),
                 Group(Layer("face", svg(face + spots)), Layer("potato", svg(potato)), Layer("sofa", svg(sofa)))],
                shelf=WILD, asset="CouchPotato")


def remote():
    """The ring is the TV, and the remote's pointed right at it."""
    w = at(.7, 566, 420)          # ring x 341-791, y 195-645
    ring, tri = mark_parts(WHITE, "#FFD84D", wrap=w)
    screen = hole("#221D4B", w)
    feet = path(rr(400, 640, 60, 60, 20), "#D9D4FF") + path(rr(672, 640, 60, 60, 20), "#D9D4FF")
    c, t = (226, 806), 40
    body = rot(t, *c, path(rr(172, 600, 136, 380, 64), "#2A2640"))
    buttons = rot(t, *c, path(circle(240, 670, 26), "#FF5A5F")
                  + path(circle(240, 770, 40), "#5A5680") + path(circle(240, 770, 16), "#2A2640")
                  + "".join(path(circle(x, y, 16), "#5A5680") for x in (212, 268) for y in (860, 920)))
    body_m = rot(t, *c, path(rr(172, 600, 136, 380, 64), "#B8B8C8"))
    # Signal arcs spreading from the remote's tip towards the screen.
    tip = (c[0] + 190 * math.sin(math.radians(t)), c[1] - 190 * math.cos(math.radians(t)))
    head = math.radians(t - 90)
    arcs = []
    for r in (38, 68, 98):
        a, b = head - .55, head + .55
        p, q = (tip[0] + r * math.cos(a), tip[1] + r * math.sin(a)), (tip[0] + r * math.cos(b), tip[1] + r * math.sin(b))
        arcs.append(f"M{f(p[0])} {f(p[1])} A{r} {r} 0 0 1 {f(q[0])} {f(q[1])}")
    waves = "".join(line(d, WHITE, 16, ' opacity=".85"') for d in arcs)
    return Icon("remote", "Remote", "Guard it with your life",
                ("#8C6CFF", "#3B22C8"), ("#1E1250", "#060214"),
                [Group(Layer("buttons", svg(buttons)), Layer("remote", svg(body), mono=svg(body_m)),
                       Layer("signal", svg(waves)), shadow=0.5),
                 Group(Layer("play", tri), shadow=0.5),
                 Group(Layer("ring", ring), Layer("screen", screen), Layer("feet", svg(feet)))],
                diagonal=True, shelf=WILD, asset="Remote")


def headphones():
    """The ring with its headphones on."""
    w = at(.7, 512, 590)          # ring x 287-737, y 365-815
    ring, tri = mark_parts("#FF4F8B", WHITE, wrap=w)
    band = line("M262 560 C262 300 380 216 512 216 C644 216 762 300 762 560", "#3A2A66", 50)
    cups = path(rr(222, 480, 120, 210, 56), "#3A2A66") + path(rr(682, 480, 120, 210, 56), "#3A2A66")
    pads = path(rr(252, 512, 60, 146, 30), "#8C7BE0") + path(rr(712, 512, 60, 146, 30), "#8C7BE0")
    note = (path(ell(812, 176, 30, 23), "#3A2A66") + path(ell(900, 156, 30, 23), "#3A2A66")
            + path("M830 176 L830 70 L920 50 L920 156 L906 156 L906 80 L844 94 L844 176 Z", "#3A2A66"))

    def light(s):
        return s.replace("#3A2A66", "#D8CCFF").replace("#8C7BE0", "#7A68D0")
    return Icon("headphones", "Headphones", "Volume up, world down",
                ("#FFEA70", "#FFA800"), ("#3E2A04", "#100A00"),
                [Group(Layer("cups", svg(pads + cups), svg(light(pads + cups)), mono=svg(light(pads + cups))), shadow=0.5),
                 Group(Layer("play", tri), Layer("ring", ring)),
                 Group(Layer("band", svg(band + note), svg(light(band + note)), mono=svg(light(band + note))))],
                bubbles=("#B36B00", WHITE), shelf=WILD, asset="Headphones")


def pizza():
    """The ring as a pizza, fresh out of its box."""
    cx, cy, k = 512, 600, .66
    w = at(k, cx, cy)             # ring x 299-725, y 387-813
    ring, tri = mark_parts("#FFD24A", "#E8453C", wrap=w)
    crust = svg(w[0] + path(squircle(190, 190, 644, 644, 4.2), "none", ' stroke="#E39A4B" stroke-width="34"') + w[1])
    pep = []
    for i in range(10):
        t = 2 * math.pi * i / 10 + .3
        x, y = rim(t, 270 * k, cx, cy)
        pep.append(path(circle(x, y, 22), "#E8453C"))
    basil = "".join(rot(a, x, y, path(ell(x, y, 20, 10), "#3DAA5C")) for x, y, a in
                    [(*rim(1.0, 270 * k, cx, cy), 30), (*rim(3.6, 270 * k, cx, cy), -40), (*rim(5.4, 270 * k, cx, cy), 60)])
    def box_art(rim_, inner, lid, lid_in):
        return (path(rr(222, 334, 580, 560, 34), rim_) + path(rr(254, 366, 516, 496, 22), inner)
                + path("M236 334 L286 132 L738 132 L788 334 Z", lid)
                + path("M274 312 L312 158 L712 158 L750 312 Z", lid_in))
    box = box_art("#D9A864", "#B98147", "#E0B878", "#C99A55")
    box_m = box_art("#5A5A5A", "#3A3A3A", "#5A5A5A", "#4A4A4A")
    return Icon("pizza", "Pizza Night", "Pause for the delivery",
                ("#5ADB94", "#138A60"), ("#0C3A28", "#02100A"),
                [Group(Layer("toppings", svg("".join(pep) + basil)), Layer("play", tri), shadow=0.4),
                 Group(Layer("crust", crust), Layer("cheese", ring)),
                 Group(Layer("box", svg(box), mono=svg(box_m)))], shelf=WILD, asset="PizzaNight")


def rocket():
    """A rocket that's just flown through the ring, its trail looping through the hole."""
    w = at(.7, 468, 590)          # ring x 243-693, y 365-815
    ring, tri = mark_parts("#F6F6FF", "#FF4D6D", wrap=w)
    body = "M512 220 C600 280 620 400 620 530 L620 680 L404 680 L404 530 C404 400 424 280 512 220 Z"
    clip = f'<clipPath id="rn"><path d="{body}"/></clipPath>'
    fins = (path(rounded_poly([(410, 540), (318, 660), (318, 740), (410, 700)], 20), "#2EC4B6")
            + path(rounded_poly([(614, 540), (706, 660), (706, 740), (614, 700)], 20), "#2EC4B6"))
    hull = (path(body, "#FFFFFF") + f'<g clip-path="url(#rn)"><rect x="380" y="200" width="260" height="120" fill="#FF4D6D"/></g>'
            + path(circle(512, 450, 58), "#23307A") + path(circle(512, 450, 58), "none", ' stroke="#C9D2FF" stroke-width="16"'))
    flame = (path("M440 690 L584 690 C584 780 548 850 512 910 C476 850 440 780 440 690 Z", "#FF8A3D")
             + path("M470 690 L554 690 C554 760 534 800 512 850 C490 800 470 760 470 690 Z", "#FFE066"))
    pl = (.54, 512, 560, 780, 236)
    ship = place(*pl, fins + hull + flame, 42)
    trail = line("M40 610 C160 530 300 470 468 466 C600 462 670 420 706 360", WHITE, 18, ' stroke-dasharray="2 40" opacity=".9"')
    stars = stars_layer([(360, 200, 16, .9), (130, 330, 10, .6), (620, 900, 14, .8), (150, 900, 12, .7)])
    return Icon("rocket", "Rocket", "Skip intro, blast off",
                ("#FFB36B", "#FF4F7E"), ("#3E1030", "#10030C"),
                [Group(Layer("rocket", svg(ship, clip)), shadow=0.5),
                 Group(Layer("play", tri), Layer("ring", ring)),
                 Group(Layer("trail", svg(trail + stars), glass=False), shadow=0, translucency=0)],
                diagonal=True, shelf=WILD, asset="Rocket")


def robot():
    """The ring is the robot's head, the play glowing on its face screen."""
    w = at(.72, 512, 440)         # ring x 280-744, y 208-672
    ring, tri = mark_parts("#EEF2F8", "#5CF2FF", wrap=w)
    screen = hole("#1C2340", w)
    parts = (path(rr(236, 380, 50, 120, 22), "#C3CAD8") + path(rr(738, 380, 50, 120, 22), "#C3CAD8")
             + line("M512 212 L512 120", "#C3CAD8", 20) + path(circle(512, 104, 32), "#FF5A5F"))
    body = (path(rr(470, 664, 84, 50, 12), "#C3CAD8") + path(rr(330, 704, 364, 340, 90), "#EEF2F8")
            + path(rr(400, 770, 224, 120, 30), "#C3CAD8")
            + path(circle(460, 830, 22), "#FF5A5F") + path(circle(530, 830, 22), "#FFD84D")
            + path(circle(596, 830, 22), "#5CF2FF"))
    return Icon("robot", "Robot", "Beep boop, press play",
                ("#A8F7CF", "#1EAE85"), ("#0B3A2C", "#02100C"),
                [Group(Layer("play", tri), glass_shadow="layer-color", shadow=0.6),
                 Group(Layer("ring", ring), Layer("screen", screen), Layer("parts", svg(parts))),
                 Group(Layer("body", svg(body)))],
                shelf=WILD, asset="Robot")


ICONS = [goldfish(), octopus(), whale(), puffer(), seahorse(), coral(), turtle(), submarine(),
         galaxy(), eclipse(), lighthouse(), campfire(), rainyday(), skyline(),
         couch(), remote(), headphones(), pizza(), rocket(), robot()]
