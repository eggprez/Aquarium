#!/usr/bin/env python3
"""A contact sheet for one icon collection, rendered through Icon Composer's
own renderer: one row per icon, one column per look.

    python3 proof_sheet.py icons_sea <out-dir> [key ...]

Writes <out-dir>/<Name>.icon for each icon and <out-dir>/<module>-proof.png.
"""

import importlib
import os
import sys

from PIL import Image, ImageDraw

from app_icons import render

LOOKS = ["Default", "Dark", "TintedDark", "ClearLight"]
SIZE = 200

if __name__ == "__main__":
    module, out, only = sys.argv[1], sys.argv[2], sys.argv[3:]
    os.makedirs(out, exist_ok=True)
    icons = [i for i in importlib.import_module(module).ICONS if not only or i.key in only]
    sheet = Image.new("RGB", (160 + SIZE * len(LOOKS), SIZE * len(icons)), "#808080")
    draw = ImageDraw.Draw(sheet)
    for row, icon in enumerate(icons):
        p = icon.write(out)
        draw.text((8, row * SIZE + SIZE // 2 - 6), f"{icon.key}\n{icon.title}", fill="white")
        for col, look in enumerate(LOOKS):
            png = os.path.join(out, f"_{icon.key}-{look}.png")
            render(p, look, png, SIZE)
            img = Image.open(png).convert("RGBA")
            sheet.paste(img, (160 + col * SIZE, row * SIZE), img)
            os.remove(png)
    dest = os.path.join(out, f"{module}-proof.png")
    sheet.save(dest)
    print(dest)
