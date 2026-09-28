"""Shared drawing kit for the Icon Composer app icons: geometry, the SVG and
icon.json writers, the Aquarium mark and bubbles. app_icons.py and the icon
collections (icons_*.py) all draw with it."""

import json
import math
import os
import shutil

# ------------------------------------------------------------------ geometry


def f(v):
    return f"{v:.1f}".rstrip("0").rstrip(".")


def squircle(x, y, w, h, n=4.2, steps=240):
    a, b, cx, cy = w / 2, h / 2, x + w / 2, y + h / 2
    pts = []
    for i in range(steps):
        t = i / steps * 2 * math.pi
        ct, st = math.cos(t), math.sin(t)
        pts.append((cx + a * math.copysign(abs(ct) ** (2 / n), ct),
                    cy + b * math.copysign(abs(st) ** (2 / n), st)))
    return "M" + " L".join(f"{f(px)} {f(py)}" for px, py in pts) + " Z"


def rounded_poly(pts, r):
    """A closed polygon with every corner rounded by a quadratic of reach r."""
    out = []
    n = len(pts)
    for i in range(n):
        p0, p1, p2 = pts[i - 1], pts[i], pts[(i + 1) % n]

        def toward(a, b, d):
            dx, dy = b[0] - a[0], b[1] - a[1]
            L = math.hypot(dx, dy)
            return (a[0] + dx / L * d, a[1] + dy / L * d)
        s, e = toward(p1, p0, r), toward(p1, p2, r)
        out.append(("L" if out else "M") + f"{f(s[0])} {f(s[1])}")
        out.append(f"Q{f(p1[0])} {f(p1[1])} {f(e[0])} {f(e[1])}")
    return " ".join(out) + " Z"


def play(cx, cy, w, h, r=None):
    """The play triangle, nudged right the way brand.swift does for optical centre."""
    r = r if r is not None else w * 0.15
    x = cx + w * 0.06
    return rounded_poly([(x - w * .45, cy - h / 2), (x + w * .55, cy), (x - w * .45, cy + h / 2)], r)


def rr(x, y, w, h, r):
    return (f"M{f(x + r)} {f(y)} H{f(x + w - r)} A{f(r)} {f(r)} 0 0 1 {f(x + w)} {f(y + r)} "
            f"V{f(y + h - r)} A{f(r)} {f(r)} 0 0 1 {f(x + w - r)} {f(y + h)} H{f(x + r)} "
            f"A{f(r)} {f(r)} 0 0 1 {f(x)} {f(y + h - r)} V{f(y + r)} A{f(r)} {f(r)} 0 0 1 {f(x + r)} {f(y)} Z")


def circle(cx, cy, r):
    return (f"M{f(cx - r)} {f(cy)} A{f(r)} {f(r)} 0 1 0 {f(cx + r)} {f(cy)} "
            f"A{f(r)} {f(r)} 0 1 0 {f(cx - r)} {f(cy)} Z")


def star(cx, cy, R, r, points=5, rot=-90):
    pts = []
    for i in range(points * 2):
        a = math.radians(rot + i * 180 / points)
        rad = R if i % 2 == 0 else r
        pts.append((cx + rad * math.cos(a), cy + rad * math.sin(a)))
    return rounded_poly(pts, R * 0.06)


def sparkle(cx, cy, R):
    """A four-point twinkle."""
    k = R * 0.22
    return (f"M{f(cx)} {f(cy - R)} Q{f(cx + k)} {f(cy - k)} {f(cx + R)} {f(cy)} "
            f"Q{f(cx + k)} {f(cy + k)} {f(cx)} {f(cy + R)} Q{f(cx - k)} {f(cy + k)} {f(cx - R)} {f(cy)} "
            f"Q{f(cx - k)} {f(cy - k)} {f(cx)} {f(cy - R)} Z")


def crescent(c1, R, c2, r):
    """Circle (c1, R) with circle (c2, r) bitten out of it."""
    (x1, y1), (x2, y2) = c1, c2
    d = math.hypot(x2 - x1, y2 - y1)
    a = (R * R - r * r + d * d) / (2 * d)
    h = math.sqrt(R * R - a * a)
    mx, my = x1 + a * (x2 - x1) / d, y1 + a * (y2 - y1) / d
    p = (mx + h * (y2 - y1) / d, my - h * (x2 - x1) / d)
    q = (mx - h * (y2 - y1) / d, my + h * (x2 - x1) / d)
    return (f"M{f(p[0])} {f(p[1])} A{f(R)} {f(R)} 0 1 0 {f(q[0])} {f(q[1])} "
            f"A{f(r)} {f(r)} 0 0 1 {f(p[0])} {f(p[1])} Z")


def path(d, fill, extra=""):
    return f'<path d="{d}" fill="{fill}"{extra}/>'


def svg(body, defs=""):
    d = f"<defs>{defs}</defs>" if defs else ""
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" '
            f'viewBox="0 0 1024 1024">{d}{body}</svg>\n')


def lin(id_, c1, c2, x1=0, y1=0, x2=0, y2=1):
    return (f'<linearGradient id="{id_}" x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}">'
            f'<stop offset="0" stop-color="{c1}"/><stop offset="1" stop-color="{c2}"/></linearGradient>')


# ------------------------------------------------------------------ icon.json


def color(hexstr, a=1.0):
    h = hexstr.lstrip("#")
    r, g, b = (int(h[i:i + 2], 16) / 255 for i in (0, 2, 4))
    return f"srgb:{r:.5f},{g:.5f},{b:.5f},{a:.5f}"


def gradient_fill(top, bottom, diagonal=False):
    start, stop = ({"x": 0.2, "y": 0}, {"x": 0.8, "y": 1}) if diagonal else ({"x": 0.5, "y": 0}, {"x": 0.5, "y": 1})
    return {"linear-gradient": [color(top), color(bottom)], "orientation": {"start": start, "stop": stop}}


WHITE = "#FFFFFF"

# The Aquarium bubbles: a trail rising up the right of the mark and across its
# corner, and a few breaking away top-left. (cx, cy, r) on the 1024 canvas —
# BUBBLES in brand.swift is the same list, for the tvOS icon and the logo.
BUBBLES = [(834, 852, 86), (914, 698, 48), (846, 584, 31), (914, 480, 21), (862, 398, 13),
           (168, 182, 46), (262, 102, 25), (114, 296, 16)]


def bubble(cx, cy, r, ink):
    """One bubble: a thin film, a rim, and a highlight up and to the left.
    Kept as separate flat shapes so Liquid Glass lights each one."""
    hx, hy = cx - r * 0.38, cy - r * 0.40
    return (f'<circle cx="{f(cx)}" cy="{f(cy)}" r="{f(r)}" fill="{ink}" opacity=".16"/>'
            f'<circle cx="{f(cx)}" cy="{f(cy)}" r="{f(r * 0.94)}" fill="none" stroke="{ink}" '
            f'stroke-width="{f(max(3, r * 0.12))}" opacity=".9"/>'
            f'<ellipse cx="{f(hx)}" cy="{f(hy)}" rx="{f(r * 0.26)}" ry="{f(r * 0.16)}" fill="{ink}" '
            f'transform="rotate(-40 {f(hx)} {f(hy)})"/>')


def bubbles_svg(ink):
    return svg("".join(bubble(x, y, r, ink) for x, y, r in BUBBLES))


class Layer:
    """One vector layer. `dark` swaps the artwork in dark mode; `mono` swaps it
    for Clear and Tinted, which read luminance — dark ink on a light ground
    would otherwise come out as next to nothing."""

    def __init__(self, name, light, dark=None, glass=True, opacity=None, mono=None):
        self.name, self.light, self.dark, self.glass, self.opacity = name, light, dark, glass, opacity
        self.mono = mono


class Group:
    def __init__(self, *layers, glass_shadow="neutral", shadow=0.5, translucency=0.4, lighting="combined"):
        self.layers, self.shadow_kind, self.shadow = layers, glass_shadow, shadow
        self.translucency, self.lighting = translucency, lighting


class Icon:
    """`bubbles` is the ink of the Aquarium bubble trail every icon carries, as
    (light, dark); a dark ink on a light ground also gets a white mono copy."""

    def __init__(self, key, title, blurb, bg, bg_dark, groups, diagonal=False, bubbles=(WHITE, None),
                 shelf=None, asset=None):
        self.key, self.title, self.blurb = key, title, blurb
        self.shelf, self._asset = shelf, asset
        self.bg, self.bg_dark, self.diagonal = bg, bg_dark, diagonal
        ink, ink_dark = bubbles
        dark = bubbles_svg(ink_dark) if ink_dark else None
        mono = bubbles_svg(WHITE) if ink != WHITE else None
        layer = Layer("bubbles", bubbles_svg(ink), dark, mono=mono)
        groups = list(groups)
        if len(groups) >= 4:
            # Icon Composer takes four groups at most; share the top one.
            top = groups[0]
            groups[0] = Group(layer, *top.layers, glass_shadow=top.shadow_kind, shadow=top.shadow,
                              translucency=top.translucency, lighting=top.lighting)
            self.groups = groups
        else:
            self.groups = [Group(layer, shadow=0.35, translucency=0.5)] + groups

    @property
    def asset(self):
        if self._asset:
            return f"AppIcon-{self._asset}"
        return "AppIcon" if self.key == "classic" else f"AppIcon-{self.title.replace(' ', '').replace('-', '')}"

    def write(self, out):
        root = os.path.join(out, f"{self.asset}.icon")
        shutil.rmtree(root, ignore_errors=True)
        os.makedirs(os.path.join(root, "Assets"))
        groups = []
        for g in self.groups:  # listed top-most first, as Icon Composer saves them
            layers = []
            for L in g.layers:
                fn = f"{L.name}.svg"
                open(os.path.join(root, "Assets", fn), "w").write(L.light)
                entry = {"image-name": fn, "name": L.name, "glass": L.glass}
                variants = [(a, art) for a, art in (("dark", L.dark), ("tinted", L.mono)) if art]
                if variants:
                    # A specialised property is saved as a list whose first,
                    # appearance-less entry is the default; a plain key beside
                    # it would win and the other entries would never be read.
                    del entry["image-name"]
                    entry["image-name-specializations"] = [{"value": fn}]
                    for appearance, art in variants:
                        vfn = f"{L.name}-{appearance}.svg"
                        open(os.path.join(root, "Assets", vfn), "w").write(art)
                        entry["image-name-specializations"].append({"appearance": appearance, "value": vfn})
                if L.opacity is not None:
                    entry["opacity"] = L.opacity
                layers.append(entry)
            groups.append({
                "layers": layers,
                "lighting": g.lighting,
                "shadow": {"kind": g.shadow_kind, "opacity": g.shadow},
                "translucency": {"enabled": g.translucency > 0, "value": g.translucency},
            })
        doc = {
            "fill-specializations": [
                {"value": gradient_fill(*self.bg, diagonal=self.diagonal)},
                {"appearance": "dark", "value": gradient_fill(*self.bg_dark, diagonal=self.diagonal)},
            ],
            "groups": groups,
            "supported-platforms": {"circles": ["watchOS"], "squares": "shared"},
        }
        json.dump(doc, open(os.path.join(root, "icon.json"), "w"), indent=2)
        return root


# ------------------------------------------------------------------ the icons


RING_D = squircle(190, 190, 644, 644, 4.2) + " " + squircle(294, 294, 436, 436, 4.0)
EO = ' fill-rule="evenodd"'
PLAY_D = play(512, 512, 248, 268, 36)


def mark_parts(ring_fill, play_fill, defs="", wrap=("", "")):
    """The mark as two layers: the ring (filled even-odd) and the play button.
    `wrap` puts each inside a group, for a transform or a clip."""
    a, b = wrap
    return (svg(a + path(RING_D, ring_fill, ' fill-rule="evenodd"') + b, defs),
            svg(a + path(PLAY_D, play_fill) + b, defs))


def classic_mark(ring_fill, play_fill, defs=""):
    return mark_parts(ring_fill, play_fill, defs)


def stars_layer(spots):
    s = "".join(path(sparkle(x, y, r), WHITE, f' opacity="{o}"') for x, y, r, o in spots)
    return s
