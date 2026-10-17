#!/usr/bin/env python3
"""Crop a rectangle out of a screenshot and scale it up, so small text can be read.

`sips -c` crops from the *centre* and its `--cropOffset` counts from there, which makes
"the top left corner" an arithmetic puzzle and put me one band too low twice. Pillow takes
the corner directly.

    zoom.py <in.png> <out.png> <x> <y> <w> <h> [scale]

Arguments are in **pixels of the input file**, so a 2x window snapshot needs pixel
coordinates (points times two). Scale defaults to 2.
"""
import sys
from PIL import Image

src, dst, x, y, w, h, *rest = sys.argv[1:]
x, y, w, h = int(x), int(y), int(w), int(h)
scale = float(rest[0]) if rest else 2.0

img = Image.open(src)
box = (x, y, x + w, y + h)
crop = img.crop(box)
crop = crop.resize((int(crop.width * scale), int(crop.height * scale)), Image.LANCZOS)
crop.save(dst)
print(f"{src} {img.size} -> {dst} {crop.size} (box {box})")
