#!/usr/bin/env python3
"""Assemble the README demo GIF from in-process snapshots.

Every frame comes from `PICNIDO_SNAPSHOT` (the app photographing its own windows), never
from `screencapture` — that only ever returns the wallpaper on this machine.

Inputs (all 2x, so 2560x1600 for the library and 4096x2304 for the full-screen viewer):

    A_0_*.png              library, 14 photos, nothing selected
    C_2_win.png            viewer, photo 1
    C_click{0..4}_2_win    viewer after clicking filmstrip cells 2..6

The viewer is 16:9 and the library window is 16:10, so the viewer frames are centre-cropped
to 16:10 instead of being letterboxed: the crop costs a sliver of backdrop on each side and
buys a single canvas size for the whole animation.
"""
import glob
import os
import sys

from PIL import Image

ROOT = os.path.dirname(os.path.abspath(__file__))
SHOTS = os.path.join(ROOT, "shots", "gif")
OUT = os.path.join(os.path.dirname(ROOT), "docs", "images", "demo.gif")

W, H = 880, 550          # 16:10 canvas — enough detail for a README without a fat file
HOLD = 1400              # ms per scene
HOLD_FIRST = 2200
HOLD_LAST = 1900
BLEND_STEPS = 5
BLEND_MS = 55


def find(pattern):
    hits = sorted(glob.glob(os.path.join(SHOTS, pattern)))
    if not hits:
        sys.exit(f"missing snapshot: {pattern}")
    return hits[-1]


def fit(path, crop_wide=False):
    im = Image.open(path).convert("RGB")
    if crop_wide:
        target_ratio = W / H
        w, h = im.size
        if w / h > target_ratio:
            new_w = int(h * target_ratio)
            left = (w - new_w) // 2
            im = im.crop((left, 0, left + new_w, h))
    return im.resize((W, H), Image.LANCZOS)


def main():
    scenes = [
        (find("A_0_*.png"), False, HOLD_FIRST),
        (find("C_2_win.png"), True, HOLD),
        (find("C_click0_2_win.png"), True, HOLD - 250),
        (find("C_click1_2_win.png"), True, HOLD - 250),
        (find("C_click2_2_win.png"), True, HOLD - 250),
        (find("C_click3_2_win.png"), True, HOLD - 250),
        (find("C_click4_2_win.png"), True, HOLD),
        (find("A_0_*.png"), False, HOLD_LAST),
    ]

    frames, durations = [], []
    images = [(fit(p, c), d) for p, c, d in scenes]

    for i, (im, hold) in enumerate(images):
        frames.append(im)
        durations.append(hold)
        if i + 1 >= len(images):
            break
        nxt = images[i + 1][0]
        # Photos advance with a cut; entering or leaving the viewer dissolves, because a cut
        # there reads as two unrelated pictures rather than as the same window changing shape.
        crossing_modes = (i == 0) or (i + 2 == len(images))
        if not crossing_modes:
            continue
        for step in range(1, BLEND_STEPS):
            frames.append(Image.blend(im, nxt, step / BLEND_STEPS))
            durations.append(BLEND_MS)

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    frames[0].save(
        OUT,
        save_all=True,
        append_images=frames[1:],
        duration=durations,
        loop=0,
        optimize=True,
        disposal=1,
    )
    size = os.path.getsize(OUT)
    print(f"{OUT}\n  frames={len(frames)} canvas={W}x{H} bytes={size/1024/1024:.2f} MB "
          f"seconds={sum(durations)/1000:.1f}")


if __name__ == "__main__":
    main()
