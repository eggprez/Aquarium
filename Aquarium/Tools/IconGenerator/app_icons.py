#!/usr/bin/env python3
"""The iOS app icons as Icon Composer documents: the primary and the ones a
person can pick in Settings → App Icon.

    python3 app_icons.py <out-dir>            # writes <out-dir>/<Name>.icon
    python3 app_icons.py <out-dir> --proof    # and renders proof sheets
    python3 app_icons.py <out-dir> --previews <Assets.xcassets>

In the project: out-dir is Aquarium/App Icons, and the previews go into the
app's asset catalog for Settings → App Icon.

Each icon is a background fill plus up to four groups of flat vector layers,
written the way Icon Composer saves them (icon.json + Assets/*.svg). Nothing is
shaded by hand: Liquid Glass supplies the depth, the specular edge and the
shadow, and the system derives the Clear and Tinted looks from the layers. The
dark look is authored — each icon names its own dark background and, where a
layer needs it, a dark version of that layer.

Xcode compiles a .icon into the Liquid Glass icon for iOS 26 and later, and
flattens it into the default, dark and tinted 1024 images iOS 17–25 use, so
this is the only source the icons have. Geometry is on a 1024 canvas; the
classic mark matches ringMark() in brand.swift.
"""

import json
import os
import shutil
import subprocess
import sys

from icon_kit import *  # noqa: F401,F403  geometry, Icon, Group, Layer, the mark

# ------------------------------------------------------------------ the icons


def classic():
    ring, tri = classic_mark(WHITE, WHITE)
    glow = lin("g", "#E7D4FF", "#9DB8FF", 0, 0, 1, 1)
    ring_d, tri_d = classic_mark("url(#g)", "url(#g)", glow)
    return Icon("classic", "Aquarium", "The original",
                ("#C26BFB", "#2C7EF0"), ("#2A1A52", "#0A0B18"),
                [Group(Layer("play", tri, tri_d), shadow=0.6),
                 Group(Layer("ring", ring, ring_d))], diagonal=True)


def ink():
    ring, tri = classic_mark("#141416", "#141416")
    ring_d, tri_d = classic_mark("#F2F2F5", "#F2F2F5")
    return Icon("ink", "Ink", "Just the mark",
                ("#FFFFFF", "#E6E6EC"), ("#2A2A2E", "#050506"),
                [Group(Layer("play", tri, tri_d, mono=tri_d), shadow=0.4),
                 Group(Layer("ring", ring, ring_d, mono=ring_d))], bubbles=("#141416", "#F2F2F5"))


def gold():
    defs = lin("au", "#FFF0B8", "#E0A21A", 0, 0, 1, 1)
    ring, tri = classic_mark("url(#au)", "url(#au)", defs)
    return Icon("gold", "Gold", "The premiere edition",
                ("#4A0D24", "#16040B"), ("#22060F", "#050102"),
                [Group(Layer("play", tri), shadow=0.6), Group(Layer("ring", ring))], diagonal=True,
                bubbles=("#FFF0B8", None))


def prism():
    colors = ["#E40303", "#FF8C00", "#FFED00", "#008026", "#24408E", "#732982"]
    h = 644 / 6
    # Each stripe is the ring clipped to a band: a clip path's own even-odd
    # rule is ignored by the renderer, but an even-odd fill inside a clip isn't.
    clips = "".join(f'<clipPath id="b{i}"><rect x="0" y="{f(190 + i * h)}" width="1024" height="{f(h + 1)}"/></clipPath>'
                    for i in range(6))
    ring = svg("".join(f'<g clip-path="url(#b{i})">{path(RING_D, c, EO)}</g>' for i, c in enumerate(colors)), clips)
    tri = svg(path(PLAY_D, "#1C1C24"))
    tri_w = svg(path(PLAY_D, WHITE))
    return Icon("prism", "Prism", "Every colour at once",
                ("#FFFFFF", "#ECEBF4"), ("#1E1E2A", "#050508"),
                [Group(Layer("play", tri, tri_w, mono=tri_w), shadow=0.4),
                 Group(Layer("ring", ring), translucency=0.25)], bubbles=("#24408E", WHITE))


def sherbet():
    ring, tri = classic_mark("#5FD4B8", "#FF7F57")
    return Icon("sherbet", "Sherbet", "Three scoops",
                ("#FFD6EA", "#FFB0C6"), ("#3A1A2E", "#140A12"),
                [Group(Layer("play", tri), shadow=0.4), Group(Layer("ring", ring))],
                bubbles=("#5FD4B8", None))


def neon():
    tube = squircle(242, 242, 540, 540, 4.1)
    ring = svg(f'<path d="{tube}" fill="none" stroke="#FF4FD8" stroke-width="40"/>')
    tri = svg(f'<path d="{play(512, 512, 230, 250, 30)}" fill="none" stroke="#3DF5FF" '
              f'stroke-width="34" stroke-linejoin="round"/>')
    return Icon("neon", "Neon", "Open all night",
                ("#2A1452", "#0C0620"), ("#140A2C", "#030108"),
                [Group(Layer("play", tri), glass_shadow="layer-color", shadow=1.0),
                 Group(Layer("ring", ring), glass_shadow="layer-color", shadow=1.0)],
                bubbles=("#3DF5FF", None))


def glitch():
    def slices(fill, dx=0):
        # The top copy is cut into bands and two of them slip sideways.
        cuts = [(0, 400, 0), (400, 448, 30), (448, 620, 0), (620, 656, -24), (656, 1024, 0)]
        defs = "".join(f'<clipPath id="k{i}"><rect x="0" y="{a}" width="1024" height="{b - a}"/></clipPath>'
                       for i, (a, b, _) in enumerate(cuts))
        body = "".join(f'<g clip-path="url(#k{i})" transform="translate({s + dx} 0)">'
                       f'{path(RING_D, fill, EO)}{path(PLAY_D, fill)}</g>'
                       for i, (a, b, s) in enumerate(cuts))
        return svg(body, defs)
    split = svg(f'<g opacity=".9"><g transform="translate(-16 0)">{path(RING_D, "#00E1FF", EO)}{path(PLAY_D, "#00E1FF")}</g>'
                f'<g transform="translate(16 0)">{path(RING_D, "#FF2BD6", EO)}{path(PLAY_D, "#FF2BD6")}</g></g>')
    lines = svg("".join(f'<rect x="0" y="{y}" width="1024" height="4" fill="#000000" opacity=".06"/>'
                        for y in range(0, 1024, 16)))
    top, top_d = slices("#15151C"), slices("#F4F4F8")
    return Icon("glitch", "Glitch", "Signal lost, show found",
                ("#FFFFFF", "#E4E4EC"), ("#16161F", "#050508"),
                [Group(Layer("mark", top, top_d, mono=top_d), shadow=0.3),
                 Group(Layer("split", split, glass=False), shadow=0, translucency=0),
                 Group(Layer("scanlines", lines, glass=False), shadow=0, translucency=0)],
                bubbles=("#15151C", "#F4F4F8"))


def rabbit_ears():
    wrap = ('<g transform="translate(512 580) scale(.82) translate(-512 -512)">', "</g>")
    ring, tri = mark_parts("#FF8A3D", WHITE, wrap=wrap)
    ears = svg('<g stroke="#26233F" stroke-width="22" stroke-linecap="round">'
               '<line x1="512" y1="330" x2="386" y2="150"/><line x1="512" y1="330" x2="650" y2="164"/></g>'
               + path(circle(386, 150, 30), "#FF5A5F") + path(circle(650, 164, 30), "#FF5A5F")
               + path(rr(330, 836, 64, 70, 22), "#C2410C") + path(rr(630, 836, 64, 70, 22), "#C2410C"))
    screen = svg(wrap[0] + path(squircle(294, 294, 436, 436, 4.0), "#221D4B") + wrap[1])
    return Icon("ears", "Rabbit Ears", "Don't touch that dial",
                ("#5EE0D0", "#2379A0"), ("#0C2E36", "#03100F"),
                [Group(Layer("play", tri), shadow=0.5),
                 Group(Layer("ring", ring), Layer("screen", screen)),
                 Group(Layer("antennas", ears))])


def midnight():
    stars = stars_layer([(130, 880, 26, .9), (560, 110, 14, .7), (110, 520, 16, .7),
                         (520, 920, 12, .6), (330, 70, 10, .6)])
    ring, tri = classic_mark("#FFE9A6", WHITE)
    moon = svg(path(crescent((790, 230), 110, (840, 190), 92), "#FFF6D6"))
    return Icon("midnight", "Midnight", "For the 2 a.m. episode",
                ("#2B3A8F", "#0A0F2E"), ("#10153A", "#010208"),
                [Group(Layer("moon", moon), shadow=0.5), Group(Layer("play", tri), shadow=0.6),
                 Group(Layer("ring", ring)),
                 Group(Layer("stars", svg(stars), glass=False), shadow=0, translucency=0)])


def sunset():
    defs = lin("sun", "#FFE66D", "#FF4F8B")
    bands = [(0, 600), (618, 660), (680, 712), (734, 760), (784, 804), (826, 840)]
    clip = "".join(f'<rect x="0" y="{a}" width="1024" height="{b - a}"/>' for a, b in bands)
    defs += f'<clipPath id="c">{clip}</clipPath>'
    ring = svg(f'<g clip-path="url(#c)">{path(RING_D, "url(#sun)", EO)}</g>', defs)
    grid = []
    for x in range(-600, 1700, 170):
        grid.append(f'<line x1="512" y1="760" x2="{x}" y2="1024"/>')
    for y in (780, 810, 856, 920, 1000):
        grid.append(f'<line x1="0" y1="{y}" x2="1024" y2="{y}"/>')
    grid = svg(f'<g stroke="#FF5CE1" stroke-width="9" opacity=".8" stroke-linecap="round">{"".join(grid)}</g>')
    tri = svg(path(PLAY_D, "#FFE66D"))
    return Icon("sunset", "Sunset Drive", "Outrun the end credits",
                ("#3A0F75", "#D6246E"), ("#1A0638", "#4A0730"),
                [Group(Layer("play", tri), shadow=0.4), Group(Layer("ring", ring)),
                 Group(Layer("grid", grid, glass=False), shadow=0, translucency=0)])


def eight_bit():
    px = 46
    cells = []
    a1, a2 = 300, 200
    for gy in range(-8, 9):
        for gx in range(-8, 9):
            x, y = gx * px, gy * px
            outer = abs(x / a1) ** 4.2 + abs(y / a1) ** 4.2 <= 1
            inner = abs(x / a2) ** 4.0 + abs(y / a2) ** 4.0 <= 1
            if outer and not inner:
                cells.append((512 + x - px / 2, 512 + y - px / 2))
    heights = [7, 7, 5, 5, 3, 3, 1]
    tp, tx = 38, 512 - 7 * 38 / 2 + 12

    def pixels(fill, dx=0, dy=0):
        # One path, not a rect per pixel: the glass edges every separate
        # shape, which draws a grid of seams across the ring.
        d = []
        for y in sorted({y for _, y in cells}):
            xs = sorted(x for x, cy in cells if cy == y)
            start = prev = xs[0]
            for x in xs[1:] + [None]:
                if x is not None and x - prev <= px + 0.5:
                    prev = x
                    continue
                d.append(f"M{f(start + dx)} {f(y + dy)} H{f(prev + px + dx)} V{f(y + px + 1 + dy)} H{f(start + dx)} Z")
                if x is not None:
                    start = prev = x
        steps = [(tx + i * tp, 512 - h * tp / 2) for i, h in enumerate(heights)]
        top = " ".join(f"L{f(x + dx)} {f(y + dy)} L{f(x + tp + dx)} {f(y + dy)}" for x, y in steps)
        bottom = " ".join(f"L{f(x + tp + dx)} {f(1024 - y + dy)} L{f(x + dx)} {f(1024 - y + dy)}" for x, y in reversed(steps))
        d.append("M" + top[1:] + " " + bottom + " Z")
        return svg(path(" ".join(d), fill))
    return Icon("8bit", "8-Bit", "Press start",
                ("#A8C81A", "#7FA00C"), ("#12300F", "#051405"),
                [Group(Layer("mark", pixels("#0F380F"), pixels("#B6D53C"), mono=pixels(WHITE)), shadow=0.4),
                 Group(Layer("shade", pixels("#306230", 18, 18), glass=False), shadow=0, translucency=0)],
                bubbles=("#0F380F", "#B6D53C"))


# The two that aren't the mark.

def popcorn():
    top, bot = (292, 732, 470), (372, 652, 890)
    bands = []
    for i in range(6):
        t0, t1 = i / 6, (i + 1) / 6
        xs = lambda e, t: e[0] + (e[1] - e[0]) * t
        pts = [(xs(top, t0), top[2]), (xs(top, t1), top[2]), (xs(bot, t1), bot[2]), (xs(bot, t0), bot[2])]
        bands.append(path("M" + " L".join(f"{f(x)} {f(y)}" for x, y in pts) + " Z",
                          WHITE if i % 2 == 0 else "#FF4757"))
    bucket = svg("".join(bands) + path(rr(274, 446, 476, 48, 24), WHITE))
    puffs = [(372, 440, 80, "#FFF3C9"), (470, 380, 92, "#FFF3C9"), (580, 372, 96, "#FFF3C9"),
             (672, 436, 78, "#FFF3C9"), (512, 280, 76, "#FFE08A"), (400, 300, 66, "#FFF3C9"),
             (628, 290, 64, "#FFE08A"), (520, 450, 70, "#FFE08A")]
    corn = svg("".join(path(circle(x, y, r), c) for x, y, r, c in puffs))
    label = svg(path(circle(512, 690, 104), WHITE) + path(play(512, 690, 104, 112, 16), "#E8283A"))
    return Icon("popcorn", "Popcorn", "Extra butter",
                ("#FF6B6B", "#C81D32"), ("#3D0A12", "#110306"),
                [Group(Layer("label", label), shadow=0.5), Group(Layer("popcorn", corn)),
                 Group(Layer("bucket", bucket))])


def jelly():
    bell = "M272 560 C272 250 752 250 752 560 " + "".join("a60 44 0 0 1 -120 0 " for _ in range(4)) + "Z"
    tents = []
    for i, x in enumerate((332, 422, 512, 602, 692)):
        amp = 26 if i % 2 else -26
        tents.append(f'<path d="M{x} 560 c{amp} 60 {-amp} 110 0 170 s{amp} 110 0 170" '
                     f'fill="none" stroke="#FFB3DA" stroke-width="32" stroke-linecap="round"/>')
    face = (path(f"M{430 - 24} 470 a24 32 0 1 0 48 0 a24 32 0 1 0 -48 0 Z", "#3B0F35")
            + path(f"M{594 - 24} 470 a24 32 0 1 0 48 0 a24 32 0 1 0 -48 0 Z", "#3B0F35")
            + '<path d="M478 526 q34 34 68 0" fill="none" stroke="#3B0F35" stroke-width="16" stroke-linecap="round"/>'
            + path(circle(372, 522, 26), "#FF4F9A", ' opacity=".55"') + path(circle(652, 522, 26), "#FF4F9A", ' opacity=".55"'))
    return Icon("jelly", "Jelly", "Say hi to the locals",
                ("#72D6FF", "#2463C7"), ("#0A2748", "#020814"),
                [Group(Layer("face", svg(face)), shadow=0.2), Group(Layer("bell", svg(path(bell, "#FF86C4")))),
                 Group(Layer("tentacles", svg("".join(tents))))])



ICONS = [classic(), ink(), gold(), prism(), sherbet(), neon(), rabbit_ears(), glitch(), eight_bit(),
         midnight(), sunset(), jelly(), popcorn()]

# ------------------------------------------------------------------ proofing

ICTOOL = "/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
RENDITIONS = ["Default", "Dark", "ClearLight", "ClearDark", "TintedLight", "TintedDark"]


def render(icon_path, rendition, out_png, size):
    subprocess.run([ICTOOL, icon_path, "--export-image", "--output-file", out_png, "--platform", "iOS",
                    "--rendition", rendition, "--width", str(size), "--height", str(size), "--scale", "1"],
                   check=True, stdout=subprocess.DEVNULL)


def write_previews(icon, icon_path, catalog):
    """The picker's tiles: the icon as the system draws it, light and dark,
    since an app icon in the catalog can't be loaded as an image by name."""
    folder = os.path.join(catalog, "App Icon Previews")
    os.makedirs(folder, exist_ok=True)
    folder_json = os.path.join(folder, "Contents.json")
    if not os.path.exists(folder_json):
        json.dump({"info": {"author": "xcode", "version": 1}}, open(folder_json, "w"), indent=2)
    name = icon.asset.replace("AppIcon", "IconPreview", 1)
    root = os.path.join(folder, f"{name}.imageset")
    shutil.rmtree(root, ignore_errors=True)
    os.makedirs(root)
    images = []
    for rendition, suffix, appearance in (("Default", "", None), ("Dark", "-dark", "dark")):
        fn = f"{icon.key}{suffix}.png"
        render(icon_path, rendition, os.path.join(root, fn), 192)
        entry = {"filename": fn, "idiom": "universal", "scale": "3x"}
        if appearance:
            entry["appearances"] = [{"appearance": "luminosity", "value": appearance}]
        images.append(entry)
    json.dump({"images": images, "info": {"author": "xcode", "version": 1}}, open(os.path.join(root, "Contents.json"), "w"), indent=2)


if __name__ == "__main__":
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    args = sys.argv[2:]
    if "--previews" in args:
        del args[args.index("--previews"):args.index("--previews") + 2]
    only = [a for a in args if not a.startswith("--")]
    for icon in ICONS:
        if only and icon.key not in only:
            continue
        p = icon.write(out)
        print(p)
        if "--previews" in sys.argv:
            write_previews(icon, p, sys.argv[sys.argv.index("--previews") + 1])
        if "--proof" in sys.argv:
            proof = os.path.join(out, "proof")
            os.makedirs(proof, exist_ok=True)
            for r in RENDITIONS:
                render(p, r, os.path.join(proof, f"{icon.key}-{r}.png"), 256)
    if "--manifest" in sys.argv:
        print(json.dumps([{"asset": i.asset, "key": i.key, "title": i.title, "blurb": i.blurb} for i in ICONS], indent=1))
