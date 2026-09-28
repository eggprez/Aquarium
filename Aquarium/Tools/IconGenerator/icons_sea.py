"""Twenty more alternates: sea creatures for the Under the Sea shelf, night
scenes for After Dark, and odds and ends for Wildcards. Drawn with the same
kit and rules as app_icons.py: flat SVG layers, Liquid Glass does the depth.

    python3 proof_sheet.py icons_sea <out-dir> [key ...]
"""

import math

from icon_kit import *  # noqa: F401,F403

SEA, DARK, WILD = "Under the Sea", "After Dark", "Wildcards"

# ------------------------------------------------------------------ helpers


def ell(cx, cy, rx, ry):
    return (f"M{f(cx - rx)} {f(cy)} A{f(rx)} {f(ry)} 0 1 0 {f(cx + rx)} {f(cy)} "
            f"A{f(rx)} {f(ry)} 0 1 0 {f(cx - rx)} {f(cy)} Z")


def line(d, ink, w, extra=""):
    return (f'<path d="{d}" fill="none" stroke="{ink}" stroke-width="{f(w)}" '
            f'stroke-linecap="round" stroke-linejoin="round"{extra}/>')


def rot(deg, cx, cy, body):
    return f'<g transform="rotate({f(deg)} {f(cx)} {f(cy)})">{body}</g>'


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
    body = ("M244 540 C244 420 360 362 470 372 C560 380 620 448 636 540 "
            "C620 632 560 700 470 708 C360 718 244 660 244 540 Z")
    tail = ("M600 540 C640 470 690 386 776 352 C792 428 776 492 740 540 "
            "C776 588 792 652 776 728 C690 694 640 610 600 540 Z")
    dorsal = "M392 392 C410 286 520 262 590 330 C600 360 590 400 560 412 Z"
    fins = svg(path(union(tail, dorsal), "#FFD36B"))
    belly = f'<clipPath id="bb"><path d="{body}"/></clipPath>'
    body_l = svg(path(body, "#FF8A1F") + f'<g clip-path="url(#bb)">{path(ell(470, 690, 250, 110), "#FFB347")}</g>', belly)
    face = (path(circle(342, 500, 50), WHITE) + eye(350, 504, 26)
            + path("M440 560 C480 600 520 610 548 590 C520 640 470 650 440 620 Z", "#FFD36B")
            + smile(286, 580, 36, "#8A3A00", 12, 14) + cheeks([(382, 572)], 22))
    return Icon("goldfish", "Goldfish", "Forgets how it ends",
                ("#8BEFF5", "#1A8FD0"), ("#0B3452", "#020A16"),
                [Group(Layer("face", svg(face)), shadow=0.3), Group(Layer("body", body_l)),
                 Group(Layer("fins", fins))], shelf=SEA, asset="Goldfish")


def octopus():
    head = "M330 470 C318 300 410 214 512 214 C614 214 706 300 694 470 C688 552 626 596 512 596 C398 596 336 552 330 470 Z"
    arms = [
        "M384 548 C312 596 238 632 250 716 C258 772 326 772 318 724",
        "M436 580 C414 660 364 736 392 818 C410 866 466 850 446 806",
        "M494 590 C494 690 470 770 504 862 C522 904 572 882 552 846",
        "M548 590 C560 680 590 760 562 842",
        "M596 578 C620 660 668 730 636 812 C618 858 566 846 584 804",
        "M644 546 C712 590 772 626 760 704 C752 756 690 758 698 716",
    ]
    tent = svg("".join(line(a, "#F0564A", 50) for a in arms))
    suckers = "".join(path(circle(x, y, 9), "#FFC2B8") for x, y in
                      [(258, 690), (380, 780), (494, 820), (646, 780), (756, 680), (566, 800)])
    head_l = svg(path(head, "#FF6F5E") + path(ell(448, 300, 44, 30), "#FF9C8C"))
    face = (path(ell(444, 430, 50, 56), WHITE) + path(ell(580, 430, 50, 56), WHITE)
            + eye(452, 440, 26) + eye(588, 440, 26)
            + smile(512, 512, 56, "#5A1418", 14) + cheeks([(390, 506), (634, 506)], 24, "#C8203A", ".45"))
    # the arm on the right holds up the remote's best button
    button = path(circle(706, 268, 58), WHITE) + path(play(706, 268, 54, 60, 10), "#F0564A")
    grip = line("M660 520 C720 470 740 380 712 330", "#F0564A", 44)
    return Icon("octopus", "Octopus", "Eight arms, one remote",
                ("#5FE6C0", "#0E8C8C"), ("#0B3A3C", "#021112"),
                [Group(Layer("face", svg(face + suckers)), shadow=0.3),
                 Group(Layer("button", svg(button))),
                 Group(Layer("head", head_l)),
                 Group(Layer("arms", tent), Layer("grip", svg(grip)))], shelf=SEA, asset="Octopus")


def whale():
    body = ("M196 606 C196 470 312 404 446 408 C560 412 626 470 660 530 "
            "C676 490 682 450 680 410 L716 404 C732 480 722 576 684 636 "
            "C630 716 530 740 410 740 C272 740 196 700 196 606 Z")
    flukes = ("M700 420 C684 360 646 332 604 318 C660 300 696 326 706 356 "
              "C720 322 750 298 792 306 C756 330 726 362 700 420 Z")
    clip = f'<clipPath id="wb"><path d="{body}"/></clipPath>'
    belly = (f'<g clip-path="url(#wb)">{path(ell(400, 760, 250, 130), "#DDF3FF")}'
             + "".join(line(f"M{x} 660 q20 40 10 90", "#A8D8F5", 10) for x in (300, 350, 400, 450, 500))
             + "</g>")
    body_l = svg(path(union(body, flukes), "#5BB4FF") + belly, clip)
    face = eye(300, 574, 20) + smile(262, 628, 90, "#1E3A78", 12, 22) + cheeks([(336, 624)], 22, "#FF7BA8", ".55")
    spout = (line("M372 396 C360 330 330 290 290 276", "#C8F2FF", 26)
             + line("M380 396 C386 330 420 280 470 262", "#C8F2FF", 26)
             + path(teardrop(376, 258, 26, 52), "#C8F2FF")
             + path(circle(270, 340, 13), "#C8F2FF") + path(circle(492, 330, 13), "#C8F2FF"))
    return Icon("whale", "Whale", "Big screen energy",
                ("#7C88FF", "#2B2CA8"), ("#15165A", "#04041A"),
                [Group(Layer("face", svg(face)), shadow=0.3), Group(Layer("spout", svg(spout))),
                 Group(Layer("body", body_l))], shelf=SEA, asset="Whale")


def puffer():
    cx, cy = 500, 552
    spikes = svg(path(star(cx, cy, 262, 198, 18, rot=-80), "#F29A16"))
    clip = f'<clipPath id="pb"><path d="{circle(cx, cy, 206)}"/></clipPath>'
    body = svg(path(circle(cx, cy, 206), "#FFD23F")
               + f'<g clip-path="url(#pb)">{path(ell(cx, cy + 190, 250, 130), "#FFF0B0")}</g>'
               + "".join(path(circle(x, y, r), "#E08A10", ' opacity=".55"') for x, y, r in
                         [(560, 400, 16), (620, 450, 12), (500, 380, 12), (640, 520, 14)]), clip)
    fins = svg(path("M700 552 C740 500 770 480 786 470 C780 530 780 574 786 634 C770 624 740 604 700 552 Z", "#FFB020")
               + path("M560 600 C600 590 640 620 650 660 C610 670 570 650 560 600 Z", "#FFB020"))
    face = (path(circle(392, 486, 58), WHITE) + eye(380, 494, 32, look=(-4, 0))
            + path(circle(530, 486, 50), WHITE) + eye(520, 494, 28, look=(-4, 0))
            + path(ell(420, 604, 26, 30), "#7A2A10") + path(ell(420, 612, 12, 12), "#FF7A6B")
            + cheeks([(340, 568), (520, 568)], 24, "#FF6B6B", ".5"))
    return Icon("puffer", "Pufferfish", "Prickly about spoilers",
                ("#FFB8C4", "#EE5C7E"), ("#4A0F24", "#14030A"),
                [Group(Layer("face", svg(face)), shadow=0.3), Group(Layer("body", body)),
                 Group(Layer("spikes", spikes), Layer("fins", fins))], shelf=SEA, asset="Pufferfish")


def seahorse():
    body = ("M300 352 L404 326 C420 254 478 222 540 228 C612 236 650 300 628 366 "
            "C668 426 694 510 668 596 C648 666 604 708 560 724 "
            "C470 740 404 680 408 590 C410 530 440 500 452 486 "
            "C432 462 420 434 404 404 L300 394 C282 390 282 356 300 352 Z")
    tail = line("M540 716 C504 790 516 866 592 884 C652 898 690 842 660 806 C636 780 600 796 612 826", "#FF9A2E", 58)
    crest = path("M500 236 L520 176 L548 232 Z M556 238 L596 196 L604 256 Z M600 270 L650 250 L630 312 Z", "#FFD36B")
    dorsal = path("M664 470 C730 468 772 530 752 600 C730 610 700 600 676 590 Z", "#FFD36B")
    ridges = "".join(line(f"M{x1} {y1} q24 -6 44 8", "#FFC66B", 12) for x1, y1 in
                     [(440, 560), (438, 606), (446, 650), (468, 690)])
    art = svg(path(body, "#FF9A2E") + tail + ridges)
    fins = svg(crest + dorsal)
    face = eye(530, 318, 26) + cheeks([(560, 376)], 22, "#FF4F7A", ".5") + path(circle(306, 373, 7), "#7A2A10")
    return Icon("seahorse", "Seahorse", "Dad's on night feeds",
                ("#CDA2FF", "#6A3FD8"), ("#2A1560", "#0A0420"),
                [Group(Layer("face", svg(face)), shadow=0.3), Group(Layer("body", art)),
                 Group(Layer("fins", fins))], shelf=SEA, asset="Seahorse")


def coral():
    branch = "".join(line(d, "#FF6FA8", 44) for d in [
        "M372 960 L372 620", "M372 760 C330 720 300 680 300 600", "M372 700 C420 660 440 620 440 560",
        "M300 640 C270 610 260 580 262 540", "M440 610 C470 590 486 560 488 520"])
    fan = "".join(line(d, "#FFA24A", 30) for d in [
        "M560 960 L560 770", "M560 800 C520 760 500 720 504 680", "M560 790 C600 760 620 720 618 680",
        "M560 840 C610 820 650 790 666 750"])
    dome = path("M530 960 C530 820 620 760 700 760 C770 760 790 820 790 960 Z", "#FFD24A")
    grooves = "".join(line(d, "#F2A516", 12) for d in
                      ["M600 900 C620 840 680 820 720 830", "M640 930 C660 880 700 870 740 880", "M596 960 C630 950 700 948 780 960"])
    grass = "".join(line(d, "#3DDC97", 26) for d in
                    ["M240 980 C220 900 250 840 220 780", "M470 980 C490 900 460 860 480 800"])
    fish = (path(rounded_poly([(430, 330), (620, 420), (430, 510)], 34), WHITE)
            + path(rounded_poly([(410, 420), (360, 370), (360, 470)], 12), WHITE))
    fish_face = path(circle(560, 408, 14), "#10306B") + path(circle(640, 330, 11), "#BFE4FF")
    small = path(ell(650, 540, 40, 24), "#FFD24A") + path(rounded_poly([(612, 540), (584, 518), (584, 562)], 6), "#FFD24A") \
        + path(circle(670, 534, 6), "#10306B")
    return Icon("coral", "Coral Reef", "Colour graded by nature",
                ("#34B8FF", "#0B3E9C"), ("#0A2356", "#020818"),
                [Group(Layer("fish", svg(fish)), Layer("eye", svg(fish_face + small), glass=False), shadow=0.5),
                 Group(Layer("dome", svg(dome + grooves))),
                 Group(Layer("branch", svg(branch + fan + grass)))], shelf=SEA, asset="CoralReef")


def turtle():
    c = (512, 560)
    tilt = -18
    flippers = (path("M376 470 C290 420 230 360 214 330 C290 330 380 380 420 430 Z", "#7ACB6A")
                + path("M648 470 C734 420 794 360 810 330 C734 330 644 380 604 430 Z", "#7ACB6A")
                + path("M400 700 C350 740 330 790 340 820 C390 800 430 760 440 720 Z", "#7ACB6A")
                + path("M624 700 C674 740 694 790 684 820 C634 800 594 760 584 720 Z", "#7ACB6A")
                + path("M490 790 L512 850 L534 790 Z", "#7ACB6A")
                + path(ell(512, 300, 72, 82), "#7ACB6A"))
    shell = path(ell(512, 560, 176, 222), "#2E8F62") + path(ell(512, 560, 142, 186), "#46B27A")
    scute = path(play(512, 560, 150, 164, 26), "#D6F5A8")
    face = eye(484, 292, 14) + eye(540, 292, 14) + smile(512, 330, 34, "#1D4A2A", 10, 12)
    return Icon("turtle", "Sea Turtle", "Slow TV, done right",
                ("#FFE6A8", "#2EC0C2"), ("#0C3A40", "#021214"),
                [Group(Layer("play", svg(rot(tilt, *c, scute + face))), shadow=0.4),
                 Group(Layer("shell", svg(rot(tilt, *c, shell)))),
                 Group(Layer("flippers", svg(rot(tilt, *c, flippers))))],
                bubbles=("#1E8C94", WHITE), shelf=SEA, asset="SeaTurtle")


def submarine():
    hull = path(rr(236, 470, 520, 230, 115), "#FFC93A") + path(rr(420, 372, 180, 120, 40), "#FFC93A")
    scope = line("M560 380 L560 290 L620 290", "#FFB020", 30)
    prop = path(ell(208, 585, 22, 64), "#F29A16") + path(rr(210, 572, 40, 26, 10), "#F29A16")
    ports = "".join(path(circle(x, 585, r + 16), "#FFF4D0") for x, r in ((360, 40), (512, 64), (654, 40)))
    glass = "".join(path(circle(x, 585, r), "#12386E") for x, r in ((360, 40), (512, 64), (654, 40)))
    tri = path(play(512, 585, 60, 66, 10), "#FFE27A") + "".join(
        path(ell(x - r * .3, 585 - r * .35, r * .28, r * .16), WHITE, ' opacity=".7"') for x, r in ((360, 40), (654, 40)))
    rivets = "".join(path(circle(x, 672, 7), "#E0A21A") for x in range(320, 720, 50))
    return Icon("submarine", "Submarine", "Deep dive into season 4",
                ("#2AB8E8", "#0A2F72"), ("#0A1F48", "#01050F"),
                [Group(Layer("porthole", svg(glass + tri)), shadow=0.4),
                 Group(Layer("rims", svg(ports))),
                 Group(Layer("hull", svg(hull + scope + prop + rivets)))], shelf=SEA, asset="Submarine")


# ------------------------------------------------------------------ After Dark


def galaxy():
    cx, cy = 506, 548

    def arm(phase):
        outer, inner = [], []
        n = 60
        for i in range(n + 1):
            t = i / n
            th = phase + t * 3.4
            r = 40 + 250 * t
            w = 18 + 60 * math.sin(math.pi * min(1, t * 1.15)) * (1 - t * .5)
            outer.append((r + w, th))
            inner.append((max(0, r - w * .6), th))
        pts = [(cx + r * math.cos(a), cy + r * math.sin(a) * .62) for r, a in outer + inner[::-1]]
        return "M" + " L".join(f"{f(x)} {f(y)}" for x, y in pts) + " Z"
    defs = lin("ga", "#FF8BD8", "#7CD8FF", 0, 0, 1, 1)
    arms = svg(rot(-24, cx, cy, path(union(arm(0), arm(math.pi)), "url(#ga)")), defs)
    core = svg(path(ell(cx, cy, 96, 80), "#FFF1FA") + path(play(cx, cy, 70, 76, 12), "#7A3CC8"))
    stars = svg(stars_layer([(390, 300, 20, .9), (700, 270, 16, .8), (270, 760, 18, .8),
                             (640, 840, 14, .7), (470, 900, 10, .6), (760, 340, 8, .6)]))
    return Icon("galaxy", "Galaxy", "Binge across the universe",
                ("#4A1A8C", "#0C0430"), ("#1E0A44", "#020008"),
                [Group(Layer("core", core), shadow=0.6), Group(Layer("arms", arms), translucency=0.3),
                 Group(Layer("stars", stars, glass=False), shadow=0, translucency=0)],
                diagonal=True, shelf=DARK, asset="Galaxy")


def eclipse():
    c = (494, 540)
    defs = lin("sun", "#FFF2B0", "#FF8A3D", 0, 0, 1, 1)
    corona = svg(path(star(*c, 290, 236, 24, rot=-90), "#FFB547", ' opacity=".55"'))
    sun = svg(path(circle(*c, 222), "url(#sun)"), defs)
    moon = svg(path(circle(c[0] - 14, c[1] - 14, 208), "#101230") + path(play(c[0] - 14, c[1] - 14, 120, 130, 18), "#22264E"))
    ring = svg(path(sparkle(c[0] - 150, c[1] - 170, 64), WHITE))
    return Icon("eclipse", "Eclipse", "Totality worth the wait",
                ("#2E2A66", "#07061A"), ("#14122E", "#000000"),
                [Group(Layer("diamond", ring), Layer("moon", moon, mono=svg(path(play(c[0] - 14, c[1] - 14, 120, 130, 18), "#3A3A50"))), shadow=0.6),
                 Group(Layer("sun", sun), glass_shadow="layer-color", shadow=0.8),
                 Group(Layer("corona", corona, glass=False), shadow=0, translucency=0)],
                diagonal=True, shelf=DARK, asset="Eclipse")


def lighthouse():
    tower_d = "M440 440 L584 440 L624 860 L400 860 Z"
    clip = f'<clipPath id="lt"><path d="{tower_d}"/></clipPath>'
    bands = "".join(f'<rect x="380" y="{y}" width="264" height="70" fill="#FF4D5E"/>' for y in (500, 640, 780))
    tower = svg(path(tower_d, "#FFF4E6") + f'<g clip-path="url(#lt)">{bands}</g>'
                + path(rr(488, 790, 48, 70, 24), "#3A2A4A") + path(rr(404, 420, 216, 34, 17), "#2E3A66"), clip)
    lamp = svg(path(rr(456, 318, 112, 104, 20), "#FFE066")
               + path("M438 322 L512 250 L586 322 Z", "#FF4D5E") + path(circle(512, 244, 16), "#FF4D5E")
               + path(play(512, 370, 44, 50, 8), "#FF8A3D"))
    beams = svg(path("M512 370 L850 250 L850 470 Z", "#FFF2A8", ' opacity=".35"')
                + path("M512 370 L330 330 L330 420 Z", "#FFF2A8", ' opacity=".3"'))
    rocks = svg(path("M300 900 C320 840 380 820 420 850 C460 820 560 820 620 850 C660 830 720 850 740 900 L740 1024 L300 1024 Z", "#1D2B4F")
                + line("M180 930 q40 -24 80 0 t80 0", "#6FB8FF", 12) + line("M620 960 q30 -20 60 0 t60 0", "#6FB8FF", 12))
    stars = stars_layer([(360, 150, 14, .8), (700, 150, 18, .9), (620, 620, 10, .6)])
    return Icon("lighthouse", "Lighthouse", "Keeps a light on for you",
                ("#23508A", "#0A1A38"), ("#0E2242", "#010610"),
                [Group(Layer("lamp", lamp), glass_shadow="layer-color", shadow=0.7),
                 Group(Layer("tower", tower)),
                 Group(Layer("rocks", rocks)),
                 Group(Layer("beams", beams, glass=False), Layer("stars", svg(stars), glass=False), shadow=0, translucency=0)],
                shelf=DARK, asset="Lighthouse")


def campfire():
    outer = ("M512 260 C560 350 668 440 648 600 C634 704 572 748 512 748 C436 748 372 700 374 600 "
             "C376 520 430 492 446 420 C476 456 490 480 490 500 C510 440 520 360 512 260 Z")
    inner = ("M516 470 C548 530 598 580 586 650 C578 704 548 724 512 724 C470 724 440 698 440 648 "
             "C440 600 476 590 488 540 C500 560 506 572 506 580 C516 548 522 510 516 470 Z")
    logs = svg(rot(16, 512, 790, path(rr(290, 756, 444, 72, 36), "#9A5B34"))
               + rot(-16, 512, 790, path(rr(290, 756, 444, 72, 36), "#B8703F"))
               + rot(-16, 512, 790, path(ell(706, 792, 22, 26), "#E3A36B")))
    stones = svg("".join(path(ell(x, 870, 46, 30), "#4E5A6E") for x in (340, 430, 520, 610, 700)))
    sparks = svg(stars_layer([(640, 300, 16, .9), (400, 340, 12, .8), (700, 420, 10, .7), (560, 190, 12, .7)]).replace(WHITE, "#FFD34D")
                 + stars_layer([(300, 470, 12, .6), (760, 250, 10, .6)]))
    return Icon("campfire", "Campfire", "Tell me a story",
                ("#1F5248", "#081A18"), ("#0E2A26", "#010605"),
                [Group(Layer("flame", svg(path(inner, "#FFD84D"))), glass_shadow="layer-color", shadow=0.8),
                 Group(Layer("fire", svg(path(outer, "#FF6A3D"))), glass_shadow="layer-color", shadow=0.8),
                 Group(Layer("logs", logs), Layer("stones", stones)),
                 Group(Layer("sparks", sparks, glass=False), shadow=0, translucency=0)],
                shelf=DARK, asset="Campfire")


def rainyday():
    cloud = union(circle(420, 420, 110), circle(548, 356, 146), circle(668, 432, 100), rr(310, 420, 460, 126, 63))
    drops = "".join(path(rot(14, x, y, teardrop(x, y, 20, 46)), "#7FD8FF") for x, y in
                    [(360, 640), (480, 610), (600, 640), (720, 620), (420, 760), (540, 740), (660, 770), (360, 880), (590, 880)])
    puddle = line("M300 950 q60 -26 120 0 t120 0 t120 0", "#7FD8FF", 12)
    face = (line("M470 470 q24 20 48 0", "#44507A", 12) + line("M590 470 q24 20 48 0", "#44507A", 12)
            + smile(556, 510, 30, "#44507A", 10, 12))
    return Icon("rainyday", "Rainy Day", "Perfect weather for it",
                ("#6F8BC0", "#26345E"), ("#1C2744", "#05080F"),
                [Group(Layer("face", svg(face)), shadow=0.2),
                 Group(Layer("cloud", svg(path(cloud, "#EEF2FF")))),
                 Group(Layer("rain", svg(drops + puddle)))],
                shelf=DARK, asset="RainyDay")


def skyline():
    blds = [(150, 640, 110), (270, 520, 100), (380, 600, 90), (478, 430, 120), (606, 560, 80), (694, 480, 96)]
    b_d = union(*[rr(x, y, w, 1100 - y, 10) for x, y, w in blds]) + " " + rr(490, 380, 12, 60, 6)
    wins = []
    lit = [1, 0, 1, 1, 0, 1, 1, 1, 0, 1, 1, 0, 0, 1, 1, 1, 0, 1]
    k = 0
    for x, y, w in blds:
        cols = max(2, int((w - 20) // 34))
        for row in range(6):
            wy = y + 40 + row * 56
            if wy > 960:
                break
            for col in range(cols):
                wx = x + (w - cols * 34 + 12) / 2 + col * 34
                if lit[k % len(lit)]:
                    wins.append(rr(wx, wy, 20, 30, 5))
                k += 1
    windows = svg(path(union(*wins), "#FFD86B"))
    board = svg(path(rr(470, 250, 136, 104, 18), "#FF5CA8") + path(play(538, 302, 44, 50, 8), WHITE)
                + path(rr(532, 350, 12, 40, 4), "#FF5CA8"))
    moon = svg(path(crescent((676, 216), 70, (716, 186), 60), "#FFF1C4"))
    city = svg(path(b_d, "#1B1646"))
    return Icon("skyline", "City Lights", "Downtown, after hours",
                ("#2B1F78", "#E0567A"), ("#120C3A", "#4A1236"),
                [Group(Layer("board", board), Layer("moon", moon), glass_shadow="layer-color", shadow=0.6),
                 Group(Layer("windows", windows), glass_shadow="layer-color", shadow=0.6),
                 Group(Layer("city", city, mono=svg(path(b_d, "#77779A"))))],
                shelf=DARK, asset="CityLights")


# ------------------------------------------------------------------ Wildcards


def couch():
    sofa = (path(rr(252, 440, 520, 230, 70), "#3E7BFA")
            + path(rr(206, 560, 130, 240, 60), "#2F62D8") + path(rr(688, 560, 100, 240, 50), "#2F62D8")
            + path(rr(290, 800, 40, 60, 14), "#1D3C8C") + path(rr(694, 800, 40, 60, 14), "#1D3C8C"))
    seat = path(rr(300, 660, 400, 150, 48), "#5A93FF")
    potato = path("M372 610 C340 520 390 420 500 410 C620 400 690 470 680 570 C672 650 610 700 520 700 C440 700 392 670 372 610 Z", "#D9A066")
    spots = "".join(path(ell(x, y, rx, ry), "#B97D45") for x, y, rx, ry in
                    [(430, 470, 16, 11), (620, 520, 12, 9), (600, 640, 14, 10), (420, 640, 10, 8)])
    face = (line("M468 540 q20 16 40 0", "#4A2C14", 12) + line("M560 540 q20 16 40 0", "#4A2C14", 12)
            + smile(534, 590, 44, "#4A2C14", 12, 18) + cheeks([(460, 586), (618, 586)], 20, "#FF7A6B", ".55"))
    remote = rot(-30, 640, 720, path(rr(610, 640, 60, 150, 24), "#26243A") + path(circle(640, 680, 14), "#FF5A5F"))
    return Icon("couch", "Couch Potato", "Just one more episode",
                ("#FFB8D2", "#F0608C"), ("#4A1026", "#12030A"),
                [Group(Layer("face", svg(face + spots)), Layer("remote", svg(remote), mono=svg(rot(-30, 640, 720, path(rr(610, 640, 60, 150, 24), "#C0C0D0")))), shadow=0.3),
                 Group(Layer("potato", svg(potato))),
                 Group(Layer("seat", svg(seat))),
                 Group(Layer("sofa", svg(sofa)))],
                shelf=WILD, asset="CouchPotato")


def remote():
    c = (500, 540)
    t = -16
    body = svg(rot(t, *c, path(rr(372, 190, 256, 700, 120), "#F6F6FB")))
    pad = svg(rot(t, *c, path(circle(500, 380, 84), "#CBCDE0") + path(circle(500, 380, 34), "#F6F6FB")
                  + path(circle(420, 250, 18), "#FF5A5F")
                  + "".join(path(circle(x, y, 22), "#CBCDE0") for x in (440, 560) for y in (720, 790))))
    btn = svg(rot(t, *c, path(circle(500, 570, 78), "#FF5A5F") + path(play(500, 570, 66, 72, 12), WHITE)))
    return Icon("remote", "Remote", "Guard it with your life",
                ("#8C6CFF", "#3B22C8"), ("#1E1250", "#060214"),
                [Group(Layer("play", btn), shadow=0.6), Group(Layer("buttons", pad)),
                 Group(Layer("body", body))], diagonal=True, shelf=WILD, asset="Remote")


def headphones():
    band = line("M300 600 C300 340 400 262 512 262 C624 262 724 340 724 600", "#FF4F8B", 54)
    cups = path(rr(236, 530, 136, 250, 62), "#FF4F8B") + path(rr(652, 530, 136, 250, 62), "#FF4F8B")
    pads = path(rr(356, 556, 44, 198, 22), "#FFE1EC") + path(rr(624, 556, 44, 198, 22), "#FFE1EC")
    marks = path(play(304, 655, 56, 62, 10), WHITE) + path(play(720, 655, 56, 62, 10), WHITE)
    note = (path(ell(470, 520, 34, 26), "#2B2140") + path(ell(574, 500, 34, 26), "#2B2140")
            + path("M492 520 L492 390 L596 366 L596 500 L582 500 L582 396 L506 414 L506 520 Z", "#2B2140"))
    note_w = note.replace("#2B2140", WHITE)
    return Icon("headphones", "Headphones", "Volume up, world down",
                ("#FFEA70", "#FFA800"), ("#3E2A04", "#100A00"),
                [Group(Layer("marks", svg(marks)), Layer("note", svg(note), svg(note_w), mono=svg(note_w)), shadow=0.4),
                 Group(Layer("pads", svg(pads))),
                 Group(Layer("phones", svg(band + cups)))],
                bubbles=("#B36B00", WHITE), shelf=WILD, asset="Headphones")


def pizza():
    tri = rounded_poly([(330, 300), (772, 560), (330, 820)], 40)
    cheese = svg(path(tri, "#FFD24A") + path(rr(560, 590, 34, 90, 17), "#FFD24A") + path(rr(430, 660, 34, 130, 17), "#FFD24A"))
    crust = svg(path(rr(262, 280, 96, 560, 48), "#E39A4B"))
    pep = svg("".join(path(circle(x, y, r), "#E8453C") for x, y, r in
                      [(430, 440, 46), (560, 540, 40), (420, 640, 40), (660, 560, 24)])
              + path(ell(500, 720, 22, 12), "#3DAA5C") + path(rot(-30, 500, 400, ell(500, 400, 22, 12)), "#3DAA5C"))
    return Icon("pizza", "Pizza Night", "Pause for the delivery",
                ("#5ADB94", "#138A60"), ("#0C3A28", "#02100A"),
                [Group(Layer("toppings", pep), shadow=0.4), Group(Layer("cheese", cheese)),
                 Group(Layer("crust", crust))], shelf=WILD, asset="PizzaNight")


def rocket():
    c = (512, 560)
    t = 40
    body = "M512 220 C600 280 620 400 620 530 L620 680 L404 680 L404 530 C404 400 424 280 512 220 Z"
    nose = f'<clipPath id="rn"><path d="{body}"/></clipPath>'
    fins = (path(rounded_poly([(410, 540), (318, 660), (318, 740), (410, 700)], 20), "#2EC4B6")
            + path(rounded_poly([(614, 540), (706, 660), (706, 740), (614, 700)], 20), "#2EC4B6")
            + path(rr(492, 600, 40, 150, 20), "#2EC4B6"))
    hull = path(body, "#F6F6FF") + f'<g clip-path="url(#rn)"><rect x="380" y="200" width="260" height="120" fill="#FF4D6D"/></g>'
    window = path(circle(512, 440, 72), "#C9D2FF") + path(circle(512, 440, 52), "#23307A") + path(play(512, 440, 44, 50, 8), "#FFD84D")
    flame = (path("M440 690 L584 690 C584 780 548 850 512 910 C476 850 440 780 440 690 Z", "#FF8A3D")
             + path("M470 690 L554 690 C554 760 534 800 512 850 C490 800 470 760 470 690 Z", "#FFE066"))
    stars = svg(stars_layer([(380, 250, 16, .9), (250, 520, 12, .7), (640, 880, 14, .8), (720, 200, 10, .6)]))
    return Icon("rocket", "Rocket", "Skip intro, blast off",
                ("#FFB36B", "#FF4F7E"), ("#3E1030", "#10030C"),
                [Group(Layer("window", svg(rot(t, *c, window))), shadow=0.5),
                 Group(Layer("hull", svg(rot(t, *c, hull), nose))),
                 Group(Layer("fins", svg(rot(t, *c, fins))), Layer("flame", svg(rot(t, *c, flame)))),
                 Group(Layer("stars", stars, glass=False), shadow=0, translucency=0)],
                diagonal=True, shelf=WILD, asset="Rocket")


def robot():
    head = path(rr(292, 330, 440, 360, 100), "#EEF2F8") + path(rr(470, 710, 84, 40, 12), "#C3CAD8")
    ears = path(rr(250, 450, 54, 120, 24), "#C3CAD8") + path(rr(720, 450, 54, 120, 24), "#C3CAD8")
    ant = line("M512 330 L512 250", "#C3CAD8", 20) + path(circle(512, 236, 32), "#FF5A5F")
    chest = path(rr(360, 740, 304, 260, 70), "#EEF2F8")
    screen = path(rr(342, 390, 340, 230, 70), "#1C2340")
    glow = (path(ell(440, 490, 34, 42), "#5CF2FF") + path(ell(584, 490, 34, 42), "#5CF2FF")
            + smile(512, 560, 70, "#5CF2FF", 14, 26))
    btn = path(circle(512, 850, 58), "#FF5A5F") + path(play(512, 850, 50, 56, 9), WHITE)
    return Icon("robot", "Robot", "Beep boop, press play",
                ("#A8F7CF", "#1EAE85"), ("#0B3A2C", "#02100C"),
                [Group(Layer("glow", svg(glow + btn)), glass_shadow="layer-color", shadow=0.5),
                 Group(Layer("screen", svg(screen), mono=svg(path(rr(342, 390, 340, 230, 70), "#50566A")))),
                 Group(Layer("head", svg(head + chest)), Layer("parts", svg(ears + ant)))],
                shelf=WILD, asset="Robot")


ICONS = [goldfish(), octopus(), whale(), puffer(), seahorse(), coral(), turtle(), submarine(),
         galaxy(), eclipse(), lighthouse(), campfire(), rainyday(), skyline(),
         couch(), remote(), headphones(), pizza(), rocket(), robot()]
