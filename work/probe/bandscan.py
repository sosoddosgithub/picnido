#!/usr/bin/env python3
"""Read two of the viewer's horizontal edges out of one of its own snapshots.

The app's geometry report cannot be the only witness for where the app puts things — the report
*is* part of the thing under test. These two readings come from pixels instead, and the fixtures
are chosen so that each one can be answered by a single, crude rule:

  photo   Where the picture's top and bottom edges really are. The fixture is a black-and-white
          checkerboard: those two values survive downscaling but not the backdrop's blur, so a
          pure black or pure white pixel exists **only** inside the picture. "First and last row
          holding an extreme pixel" is therefore a statement about the picture, not the glass
          behind it. Expected: the air above and below comes out equal, and neither is zero —
          which is exactly what the geometry report claims and could not previously show.

  chrome  Where the tool bar's first row really starts, which is how the menu bar overlap gets
          checked. The row is the only thing in the top strip that draws near-white pixels (the
          capsule border, its label, the file name) over a black scrim; the first row of the image
          containing any is its top edge. If that lands above the menu band the button is under
          the menu bar again, whatever the layout constants say.

Usage:
    bandscan.py photo  <png> <scale> [--col X] [--lo L] [--hi H]
    bandscan.py chrome <png> <scale> [--bright B] [--max-pt N]
"""
import sys
from PIL import Image


def parse(argv):
    """Both `--col 2048` and `--col=2048`, because both get typed."""
    args, opts, i = [], {}, 0
    while i < len(argv):
        a = argv[i]
        if a.startswith("--"):
            if "=" in a:
                k, _, v = a.partition("=")
                opts[k[2:]] = float(v)
            else:
                opts[a[2:]] = float(argv[i + 1])
                i += 1
        else:
            args.append(a)
        i += 1
    return args, opts


def main():
    args, opts = parse(sys.argv[1:])
    if len(args) < 3:
        print(__doc__)
        return 2
    mode, path, scale = args[0], args[1], float(args[2])

    img = Image.open(path).convert("L")
    w, h = img.size
    px = img.load()

    if mode == "photo":
        x = int(opts.get("col", w // 2))
        lo = opts.get("lo", 70.0)
        hi = opts.get("hi", 190.0)
        hot = [y for y in range(h) if px[x, y] <= lo or px[x, y] >= hi]
        if not hot:
            print(f"photo: no extreme pixel in column x={x} — the fixture never reached the screen")
            return 1
        top, bottom = hot[0] / scale, (hot[-1] + 1) / scale
        print(f"photo  column x={x}px   top={top:.1f}pt  bottom={bottom:.1f}pt  "
              f"height={bottom - top:.1f}pt   (image {w}x{h}px, scale {scale:g})")
        return 0

    if mode == "chrome":
        bright = opts.get("bright", 200.0)
        limit = int(opts.get("max_pt", 160.0) * scale)
        for y in range(min(limit, h)):
            for x in range(0, w, 2):
                if px[x, y] >= bright:
                    print(f"chrome first near-white row at y={y / scale:.1f}pt "
                          f"(searched the top {limit / scale:.0f}pt, brightness >= {bright:g})")
                    return 0
        print(f"chrome: nothing brighter than {bright:g} in the top {limit / scale:.0f}pt — "
              f"the row is missing, not merely misplaced")
        return 1

    print(f"unknown mode {mode!r}")
    return 2


if __name__ == "__main__":
    sys.exit(main())
