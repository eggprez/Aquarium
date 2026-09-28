"""Alternate app icons: the "Throwbacks" and "At the Movies" shelves.

Drawn with icon_kit like app_icons.py: flat SVG layers, Liquid Glass supplies
the depth. Every one is the Aquarium mark first — the squircle ring with the
play button in its hole — and the theme is built around it: the ring becomes
the cassette's window, the record's label, the slate, the drive-in screen.
Proof with

    python3 proof_sheet.py icons_retro <out-dir> [key ...]
"""

import math

from icon_kit import *  # noqa: F401,F403

THROWBACKS, MOVIES = "Throwbacks", "At the Movies"

HOLE_D = squircle(294, 294, 436, 436, 4.0)


def poly(pts):
    return "M" + " L".join(f"{f(x)} {f(y)}" for x, y in pts) + " Z"


def tilt(deg, cx, cy):
    return f'<g transform="rotate({deg} {cx} {cy})">', "</g>"


def at(s, cx=512, cy=512, deg=0):
    """A `wrap` for mark_parts(): the mark scaled by s, centred on (cx, cy)."""
    r = f" rotate({deg})" if deg else ""
    return f'<g transform="translate({cx} {cy}){r} scale({s}) translate(-512 -512)">', "</g>"


def wrap(w, body):
    return w[0] + body + w[1]


def hole(w, fill):
    """The ring's hole, filled — for a mark sitting on an object, where the
    hole would otherwise show the object instead of reading as a hole."""
    return svg(wrap(w, path(HOLE_D, fill)))


def hole_d(s, cx, cy):
    """The hole's outline at the mark's scale, for cutting it out of a shape."""
    return squircle(cx - 218 * s, cy - 218 * s, 436 * s, 436 * s, 4.0)


def squircle_pts(cx, cy, a, n, count):
    out = []
    for i in range(count):
        t = i / count * 2 * math.pi
        ct, st = math.cos(t), math.sin(t)
        out.append((cx + a * math.copysign(abs(ct) ** (2 / n), ct),
                    cy + a * math.copysign(abs(st) ** (2 / n), st)))
    return out


def hub(cx, cy, r, hole_r, teeth=6):
    """A spool hub: a disc with a toothed hole (fill it even-odd)."""
    return circle(cx, cy, r) + " " + star(cx, cy, hole_r, hole_r * 0.62, teeth)


# ------------------------------------------------------------------ Throwbacks


def vhs():
    # The tape's front: the mark is the window, a tape reel peeks out each side.
    T = tilt(-6, 512, 540)
    W = at(.62, 512, 560, -6)
    body = lambda c: svg(wrap(T, path(rr(140, 290, 744, 500, 44), c)))
    ring, tri = mark_parts("#FBF7F0", "#FF7A2F", wrap=W)
    ring_m = mark_parts(WHITE, WHITE, wrap=W)[0]
    label = svg(wrap(T, path(rr(196, 312, 632, 40, 20), "#FBF7F0") + path(rr(196, 330, 632, 10, 5), "#FF7A2F")))
    reels = svg(wrap(T, path(circle(226, 560, 60) + " " + circle(798, 560, 60), "#4A2A1E")
                     + path(hub(226, 560, 30, 15) + " " + hub(798, 560, 30, 15), "#E8E2D6", EO)))
    return Icon("vhs", "VHS", "Be kind, rewind",
                ("#FFA24C", "#F2542D"), ("#3A1706", "#120602"),
                [Group(Layer("play", tri), shadow=0.5),
                 Group(Layer("ring", ring, mono=ring_m), Layer("label", label), Layer("reels", reels), shadow=0.4),
                 Group(Layer("body", body("#1D1C24"), body("#34333F"), mono=body("#8C8A99")))],
                shelf=THROWBACKS, asset="VHS")


def cassette():
    # A mixtape: the mark is its window, the spools either side of it.
    T = tilt(5, 512, 520)
    W = at(.6, 512, 496, 5)
    shell = (path(rr(132, 280, 760, 500, 46), "#FF5C8A")
             + path(rounded_poly([(318, 780), (360, 706), (664, 706), (706, 780)], 16), "#E23A6E"))
    shell += "".join(path(circle(x, y, 13), "#E23A6E") for x, y in ((170, 318), (854, 318), (170, 742), (854, 742)))
    body = svg(wrap(T, shell))
    ring, tri = mark_parts("#FFF4DC", "#FFD23F", wrap=W)
    window = hole(W, "#2B1B3D")
    spools = svg(wrap(T, path(hub(232, 496, 52, 22) + " " + hub(792, 496, 52, 22), WHITE, EO)
                      + path(rr(170, 612, 124, 14, 7) + " " + rr(730, 612, 124, 14, 7), "#FFD23F")))
    return Icon("cassette", "Cassette", "Rewind with a pencil",
                ("#C3B1FF", "#7E5CF2"), ("#241845", "#0B0716"),
                [Group(Layer("play", tri), shadow=0.45),
                 Group(Layer("ring", ring), Layer("window", window), Layer("spools", spools), shadow=0.4),
                 Group(Layer("shell", body))],
                shelf=THROWBACKS, asset="Cassette")


def vinyl():
    # A record whose centre label is the mark.
    cx, cy, R = 496, 540, 340
    W = at(.6, cx, cy)
    disc = lambda c: svg(path(circle(cx, cy, R), c))
    grooves = "".join(f'<circle cx="{cx}" cy="{cy}" r="{r}" fill="none" stroke="#FFFFFF" stroke-width="3" opacity=".12"/>'
                      for r in range(246, R - 10, 16))

    def wedge(a0, a1, r0, r1):
        p = lambda a, r: (cx + r * math.cos(math.radians(a)), cy + r * math.sin(math.radians(a)))
        (x0, y0), (x1, y1), (x2, y2), (x3, y3) = p(a0, r1), p(a1, r1), p(a1, r0), p(a0, r0)
        return (f"M{f(x0)} {f(y0)} A{r1} {r1} 0 0 1 {f(x1)} {f(y1)} L{f(x2)} {f(y2)} "
                f"A{r0} {r0} 0 0 0 {f(x3)} {f(y3)} Z")
    sheen = svg(grooves + path(wedge(200, 232, 240, R - 8) + " " + wedge(20, 52, 240, R - 8), WHITE, ' opacity=".13"'))
    ring, tri = mark_parts("#FF5A36", WHITE, wrap=W)
    arm_d = ('<path d="M846 150 L820 380 L740 468" fill="none" stroke="{c}" stroke-width="24" '
             'stroke-linecap="round" stroke-linejoin="round"/>')
    arm = lambda c: svg(arm_d.format(c=c) + path(circle(846, 150, 50), c)
                        + f'<g transform="rotate(42 728 484)">{path(rr(700, 448, 56, 80, 14), c)}</g>')
    return Icon("vinyl", "Vinyl", "Drop the needle",
                ("#FFE45E", "#FFB020"), ("#3A2A00", "#120C00"),
                [Group(Layer("play", tri), Layer("ring", ring), shadow=0.45),
                 Group(Layer("arm", arm("#F4F1EA")), shadow=0.6),
                 Group(Layer("sheen", sheen, glass=False),
                       Layer("disc", disc("#18181D"), disc("#2C2C34"), mono=disc("#9A9AA6")))],
                bubbles=("#8A5A00", "#FFE45E"), shelf=THROWBACKS, asset="Vinyl")


def film_reel():
    # A reel of film with the mark as its hub; the film runs off to the left.
    cx, cy, R = 520, 480, 330
    W = at(.6, cx, cy)
    holes = " ".join(circle(cx + 286 * math.cos(math.radians(-90 + 45 * k)),
                            cy + 286 * math.sin(math.radians(-90 + 45 * k)), 24) for k in range(8))
    reel = svg(path(circle(cx, cy, R) + " " + holes, "#DDE3F0", EO))
    ring, tri = mark_parts("#FFB23F", WHITE, wrap=W)
    core = hole(W, "#1A2038")
    a = 120
    sx, sy = cx + R * math.cos(math.radians(a)), cy + R * math.sin(math.radians(a))
    st = f'<g transform="translate({f(sx)} {f(sy)}) rotate(210) translate(-40 -62)">'
    sprockets = " ".join(rr(x, y, 24, 18, 5) for x in range(-20, 760, 46) for y in (12, 94))
    strip = svg(st + path(rr(-60, 0, 820, 124, 6) + " " + sprockets, "#FFB23F", EO) + "</g>")
    return Icon("filmreel", "Film Reel", "Shot on actual film",
                ("#41507F", "#171E38"), ("#1A2038", "#05070F"),
                [Group(Layer("play", tri), shadow=0.5),
                 Group(Layer("ring", ring), Layer("core", core), shadow=0.5),
                 Group(Layer("reel", reel), Layer("strip", strip), shadow=0.5)],
                shelf=THROWBACKS, asset="FilmReel")


def test_card():
    # The ring painted in colour bars, the play button on the black of the hole.
    W = at(.86)
    cols = ["#EDEDED", "#F5D90A", "#27D6E0", "#2FC24A", "#E23BC4", "#E8323A", "#2E4BE0"]
    x0, w = 190, 644 / 7
    # Each bar is the ring clipped to a band, as prism() does: a clip's own
    # even-odd rule is ignored, but an even-odd fill inside a clip isn't.
    clips, body = "", ""
    for i, c in enumerate(cols):
        clips += f'<clipPath id="v{i}"><rect x="{f(x0 + i * w)}" y="0" width="{f(w + 1)}" height="670"/></clipPath>'
        body += f'<g clip-path="url(#v{i})">{path(RING_D, c, EO)}</g>'
    low = ["#1E2A78", "#F2F2F2", "#4B1C7A", "#141418", "#3A3A44", "#141418"]
    lw = 644 / len(low)
    for i, c in enumerate(low):
        clips += f'<clipPath id="l{i}"><rect x="{f(x0 + i * lw)}" y="670" width="{f(lw + 1)}" height="354"/></clipPath>'
        body += f'<g clip-path="url(#l{i})">{path(RING_D, c, EO)}</g>'
    ring = svg(wrap(W, body), clips)
    _, tri = mark_parts(WHITE, WHITE, wrap=W)
    screen = hole(W, "#141418")
    grid = "".join(f'<line x1="{v}" y1="0" x2="{v}" y2="1024"/><line x1="0" y1="{v}" x2="1024" y2="{v}"/>'
                   for v in range(44, 1024, 78))
    grid = svg(f'<g stroke="#FFFFFF" stroke-width="4" opacity=".14">{grid}</g>')
    return Icon("testcard", "Test Card", "Please stand by",
                ("#4A4A56", "#18181E"), ("#26262E", "#050506"),
                [Group(Layer("play", tri), Layer("screen", screen), shadow=0.5),
                 Group(Layer("ring", ring), translucency=0.2),
                 Group(Layer("grid", grid, glass=False), shadow=0, translucency=0)],
                shelf=THROWBACKS, asset="TestCard")


def polaroid():
    # An instant photo whose picture is the mark.
    T = tilt(-6, 512, 526)
    W = at(.64, 512, 462, -6)
    frame = svg(wrap(T, path(rr(240, 196, 544, 660, 22), "#FBFAF5")))
    scrawl = svg(wrap(T, '<path d="M346 776 q22 -26 44 0 t44 0 t44 0 t44 0 t44 0" fill="none" stroke="#5B8CC9" '
                         'stroke-width="10" stroke-linecap="round" opacity=".75"/>'))
    ring, tri = mark_parts("url(#ph)", "#FFE066", lin("ph", "#7FDBFF", "#2B56C4"), wrap=W)
    photo = hole(W, "#16306E")
    return Icon("polaroid", "Polaroid", "Give it a minute",
                ("#A6F0C6", "#2FB383"), ("#0F3A2A", "#03120C"),
                [Group(Layer("play", tri), shadow=0.5),
                 Group(Layer("ring", ring), Layer("photo", photo), shadow=0.35),
                 Group(Layer("scrawl", scrawl, glass=False), Layer("frame", frame), shadow=0.6)],
                bubbles=(WHITE, None), shelf=THROWBACKS, asset="Polaroid")


def cartridge():
    # A game cartridge; the mark is its label.
    W = at(.62, 512, 586)
    shell_d = rounded_poly([(222, 214), (740, 214), (802, 276), (802, 876), (222, 876)], 28)
    shell = lambda c: svg(path(shell_d, c))
    ridges = svg('<g stroke="#9DA1AE" stroke-width="10" stroke-linecap="round">'
                 + "".join(f'<line x1="290" y1="{y}" x2="650" y2="{y}"/>' for y in (258, 290, 322))
                 + "</g>")
    ring, tri = mark_parts("url(#lb)", WHITE, lin("lb", "#FF5E8A", "#FFB347", 0, 0, 1, 1), wrap=W)
    screen = hole(W, "#23234A")
    return Icon("cartridge", "Cartridge", "Blow on it first",
                ("#4D86FF", "#1E3FC4"), ("#101A45", "#040712"),
                [Group(Layer("play", tri), shadow=0.5),
                 Group(Layer("ring", ring), Layer("screen", screen), shadow=0.4),
                 Group(Layer("ridges", ridges, glass=False), Layer("shell", shell("#D8DAE2"), shell("#B9BCC8")))],
                shelf=THROWBACKS, asset="Cartridge")


def jukebox():
    # The mark is the jukebox's dome, under a neon arch.
    W = at(.64, 512, 470)
    body = svg(path("M204 886 V480 A308 308 0 0 1 820 480 V886 Z", "#6B1D3A") + path(rr(180, 860, 664, 60, 24), "#4E1229"))
    tube = svg('<path d="M244 880 V480 A268 268 0 0 1 780 480 V880" fill="none" stroke="url(#tb)" '
               'stroke-width="30" stroke-linecap="round"/>',
               lin("tb", "#FFE066", "#5CE1E6", 0, 0, 1, 0))
    ring, tri = mark_parts("#FFF1D0", "#FFE066", wrap=W)
    grill = svg(path(rr(330, 718, 364, 128, 20), "#3B0E20")
                + '<g stroke="#A8456C" stroke-width="12" stroke-linecap="round">'
                + "".join(f'<line x1="{x}" y1="744" x2="{x}" y2="820"/>' for x in range(374, 660, 46)) + "</g>")
    return Icon("jukebox", "Jukebox", "Two plays for a quarter",
                ("#FFB199", "#F2667A"), ("#3A0F1C", "#12040A"),
                [Group(Layer("play", tri), shadow=0.45),
                 Group(Layer("ring", ring), Layer("tube", tube), shadow=0.6),
                 Group(Layer("grill", grill), Layer("body", body))],
                shelf=THROWBACKS, asset="Jukebox")


# ------------------------------------------------------------------ At the Movies


def clapper():
    # The ring is the slate; the clapsticks hinge open on top of it.
    W = at(.76, 512, 600)

    def stick(y, clip_id, ink):
        d = rr(262, y, 500, 76, 16)
        stripes = "".join(path(poly([(x, y), (x + 58, y), (x + 20, y + 76), (x - 38, y + 76)]), "#F4F4F4")
                          for x in range(292, 800, 116))
        return (f'<clipPath id="{clip_id}"><path d="{d}"/></clipPath>',
                path(d, ink) + f'<g clip-path="url(#{clip_id})">{stripes}</g>')
    d1, s1 = stick(270, "s1", "#1E1E26")
    d2, s2 = stick(190, "s2", "#1E1E26")
    sticks = svg(s1 + f'<g transform="rotate(-16 266 270)">{s2}</g>', d1 + d2)
    ring, tri = mark_parts("#1E1E26", WHITE, wrap=W)
    ring_d = mark_parts("#3A3A48", WHITE, wrap=W)[0]
    ring_m = mark_parts(WHITE, WHITE, wrap=W)[0]
    return Icon("clapper", "Clapperboard", "Quiet on set",
                ("#45D4F5", "#1289D4"), ("#0A2E45", "#020A12"),
                [Group(Layer("play", tri), shadow=0.4),
                 Group(Layer("sticks", sticks), shadow=0.6),
                 Group(Layer("ring", ring, ring_d, mono=ring_m))],
                shelf=MOVIES, asset="Clapperboard")


def ticket_d(x, y, w, h, r, n):
    cy = y + h / 2
    return (f"M{f(x + r)} {f(y)} H{f(x + w - r)} A{r} {r} 0 0 1 {f(x + w)} {f(y + r)} V{f(cy - n)} "
            f"A{n} {n} 0 0 0 {f(x + w)} {f(cy + n)} V{f(y + h - r)} A{r} {r} 0 0 1 {f(x + w - r)} {f(y + h)} "
            f"H{f(x + r)} A{r} {r} 0 0 1 {f(x)} {f(y + h - r)} V{f(cy + n)} A{n} {n} 0 0 0 {f(x)} {f(cy - n)} "
            f"V{f(y + r)} A{r} {r} 0 0 1 {f(x + r)} {f(y)} Z")


def ticket():
    # A ticket punched with the mark: the hole is cut clean through.
    T = tilt(-8, 512, 540)
    s, mx, my = .62, 430, 540
    W = at(s, mx, my, -8)
    x, y, w, h = 140, 310, 744, 460
    front = svg(wrap(T, path(ticket_d(x, y, w, h, 28, 44) + " " + hole_d(s, mx, my), "#F0413A", EO)))
    ring, tri = mark_parts(WHITE, "#F0413A", wrap=W)
    stub = 700
    marks = svg(wrap(T, path(star(794, 540, 50, 21), WHITE)
                     + "".join(path(circle(stub, yy, 8), "#FFD2C4") for yy in range(y + 30, y + h - 10, 32))))
    return Icon("ticket", "Ticket", "Admit one, plus snacks",
                ("#FFF3D6", "#FFD08A"), ("#3A1F14", "#140906"),
                [Group(Layer("play", tri), shadow=0.35),
                 Group(Layer("ring", ring), Layer("marks", marks), shadow=0.4),
                 Group(Layer("front", front), shadow=0.6)],
                bubbles=("#E0452F", "#FFD08A"), shelf=MOVIES, asset="Ticket")


def glasses_3d():
    # The mark leaps off the screen in red and cyan, the way a 3D film looks
    # without the glasses.
    W = at(.8, 512, 512)
    Wr, Wc = at(.8, 476, 512), at(.8, 548, 512)
    ring, tri = mark_parts(WHITE, WHITE, wrap=W)
    ghost = svg(wrap(Wr, path(RING_D, "#FF3355", EO) + path(PLAY_D, "#FF3355"))
                + wrap(Wc, path(RING_D, "#18D6E8", EO) + path(PLAY_D, "#18D6E8")))
    return Icon("glasses3d", "3D", "It's coming right at you",
                ("#7A2FD0", "#2E0B6B"), ("#1E0A3A", "#07020F"),
                [Group(Layer("play", tri), Layer("ring", ring), shadow=0.5),
                 Group(Layer("ghost", ghost, glass=False), shadow=0, translucency=0)],
                shelf=MOVIES, asset="ThreeD")


def drive_in():
    # The mark is the drive-in's screen, a car parked in front.
    W = at(.68, 512, 404)
    ring, tri = mark_parts("#FF6B6B", "#1B5563", wrap=W)
    screen = hole(W, "#FFF4D6")
    ground = path("M0 792 Q512 724 1024 792 V1024 H0 Z", "#082128")
    posts = path(rr(360, 600, 28, 170, 6), "#082128") + path(rr(636, 600, 28, 170, 6), "#082128")
    stars = "".join(path(sparkle(sx, sy, r), WHITE, f' opacity="{o}"')
                    for sx, sy, r, o in [(880, 150, 22, .9), (84, 520, 12, .7), (900, 420, 14, .8),
                                         (760, 70, 11, .6), (400, 64, 9, .5)])
    scene = svg(ground + posts + stars)
    car_d = ("M246 852 V818 Q246 794 278 791 L344 786 Q372 728 440 724 H540 Q592 727 624 784 "
             "L684 792 Q716 798 716 828 V852 Z")
    car = svg(path(car_d, "#FFD166")
              + path("M374 784 Q394 744 438 742 H480 V784 Z M496 784 V742 H536 Q574 745 598 784 Z", "#0B2A33")
              + path(rr(690, 806, 26, 18, 9), WHITE) + path(rr(246, 832, 470, 20, 10), "#FFF1D0")
              + path(circle(334, 858, 40) + " " + circle(626, 858, 40), "#0B1216")
              + path(circle(334, 858, 15) + " " + circle(626, 858, 15), "#C9D2D6"))
    return Icon("drivein", "Drive-In", "Honk if you love sequels",
                ("#1B5563", "#07202A"), ("#0A242C", "#010608"),
                [Group(Layer("car", car), Layer("play", tri), shadow=0.6),
                 Group(Layer("ring", ring), Layer("screen", screen), shadow=0.5),
                 Group(Layer("scene", scene, glass=False), shadow=0, translucency=0)],
                shelf=MOVIES, asset="DriveIn")


def marquee():
    # The ring is the marquee, studded with bulbs, a star on top.
    s, cx, cy = .82, 512, 560
    W = at(s, cx, cy)
    ring, tri = mark_parts("#D7263D", "#D7263D", wrap=W)
    sign = hole(W, "#FFF4D6")
    pts = squircle_pts(cx, cy, 270 * s, 4.1, 28)
    bulbs = svg(path(" ".join(circle(px, py, 14) for px, py in pts), "#FFD166")
                + path(star(512, 200, 70, 30), "#FFD166"))
    return Icon("marquee", "Marquee", "Now showing: everything",
                ("#1E8C62", "#0A3E2B"), ("#0A2E20", "#020D08"),
                [Group(Layer("bulbs", bulbs), glass_shadow="layer-color", shadow=0.8),
                 Group(Layer("play", tri), Layer("sign", sign), shadow=0.4),
                 Group(Layer("ring", ring), shadow=0.6)],
                bubbles=(WHITE, None), shelf=MOVIES, asset="Marquee")


def spotlight():
    # A stage light picks out the mark.
    W = at(.66, 470, 590)
    beam = svg(path("M600 262 L716 300 L730 810 A262 64 0 0 1 206 810 Z", "url(#bm)", ' opacity=".4"')
               + path("M206 810 A262 64 0 0 0 730 810 A262 64 0 0 0 206 810 Z", "#FFE9B0", ' opacity=".5"'),
               lin("bm", "#FFF6D8", "#FFE9B0", 0, 0, 0, 1))
    lamp = svg('<line x1="690" y1="200" x2="690" y2="-10" stroke="#D9D4CC" stroke-width="18"/>'
               '<g transform="translate(690 200) rotate(110)">'
               + path(rr(-100, -66, 150, 132, 24), "#D9D4CC") + path(rr(44, -80, 38, 160, 14), "#F4F0E8")
               + "</g>")
    ring, tri = mark_parts(WHITE, WHITE, wrap=W)
    return Icon("spotlight", "Spotlight", "Hold for applause",
                ("#8E1E44", "#2C0614"), ("#3A0A1C", "#0A0105"),
                [Group(Layer("play", tri), Layer("ring", ring), shadow=0.6),
                 Group(Layer("lamp", lamp), shadow=0.5),
                 Group(Layer("beam", beam, glass=False), shadow=0, translucency=0)],
                shelf=MOVIES, asset="Spotlight")


ICONS = [vhs(), cassette(), vinyl(), film_reel(), test_card(), polaroid(), cartridge(), jukebox(),
         clapper(), ticket(), glasses_3d(), drive_in(), marquee(), spotlight()]
