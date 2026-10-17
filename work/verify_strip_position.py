#!/usr/bin/env python3
"""Judgement for where the filmstrip lands when the viewer opens somewhere in the middle.

The complaint was "I open picture 28 and the strip is showing pictures 1 to 30". Two things
were wrong and they are the same missing step:

  * `scrollTo` only ever ran from `onChange(of: currentID)`. Opening picture 28 does not
    *change* the id, it arrives with it, so nothing scrolled and the row stayed at offset 0.
  * the chrome is built inside `if chromeVisible`, so every hide-and-reveal destroys the
    ScrollView and a new one starts at the left edge again.

Four cases, all read out of a window snapshot:

  A  open 28 of 60, chrome pinned        -> the current cell sits in the middle
  B  open  1 of 60, chrome pinned        -> the current cell sits at the left (control:
                                            without it, "A passes" could just mean "the
                                            measurement finds a white border anywhere")
  C  open 60 of 60, chrome pinned        -> the row is scrolled to its end, current cell right
  D  open 28 of 60, chrome *not* pinned, hidden by the timer and then revealed by the pointer
                                         -> still in the middle (the rebuild path)

The current cell is the only one drawn at full opacity with a 2 pt white border; every other
cell is at 62 % with a 22 % border. So "which cell is the current one" is a threshold on the
green channel, not an act of recognition.

    ./work/verify_strip_position.py            # BIN=… to test another bundle
"""

import os
import re
import shutil
import subprocess
import time

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
PROBE = os.path.join(HERE, "probe", "hover")
BIN = os.environ.get("BIN", os.path.join(ROOT, "dist/Picnido.app/Contents/MacOS/Picnido"))
OUT = os.environ.get("OUT", "/tmp/picnido-strippos")
LIB = os.path.join(OUT, "library")

COUNT = 60
# The white border is 2 pt and drawn inside the cell, so at 2x it is four pixels wide and
# unmistakable against a 62 %-opacity neighbour. 200 on the green channel separates them by a
# wide margin: the border reads 255, the neighbour's own border reads ~88.
WHITE = 200
# 8 pt of slack. The measured error is half a pixel; this is here so a rounding difference
# between machines does not read as a layout bug.
TOLERANCE_PX = 16

failures = []


def say(ok, label, detail=""):
    print(f"  {'PASS' if ok else 'FAIL'}  {label}" + (f"   {detail}" if detail else ""))
    if not ok:
        failures.append(label)


def fixture():
    """Sixty flat dark photos, 1600x1200.

    Flat so JPEG stores them exactly (no ringing next to the border we are measuring), dark so
    the current cell's white border is the brightest thing in the band, and sixty of them so
    that picture 28 cannot be brought into view without scrolling.
    """
    if os.path.isdir(LIB) and len(os.listdir(LIB)) == COUNT:
        return
    shutil.rmtree(LIB, ignore_errors=True)
    os.makedirs(LIB)
    for i in range(1, COUNT + 1):
        v = 26 + (i % 12) * 4
        Image.new("RGB", (1600, 1200), (v, v + 2, v + 6)).save(
            os.path.join(LIB, f"p-{i:02d}.jpg"), quality=92)


def hover(where, value=None):
    args = [PROBE, "left"]
    if value is None:
        args.append(where)
    else:
        args.extend([f"--{where}", str(value)])
    subprocess.run(args, check=True, capture_output=True)
    return " ".join(args[1:])


def longest_run(columns):
    """(first, last) of the longest run of adjacent column indices."""
    if len(columns) == 0:
        return None
    best = (columns[0], columns[0])
    start = prev = columns[0]
    for c in columns[1:]:
        if c == prev + 1:
            prev = c
            continue
        if prev - start > best[1] - best[0]:
            best = (start, prev)
        start = prev = c
    if prev - start > best[1] - best[0]:
        best = (start, prev)
    return best


def measure(path):
    """Locate the current cell in a window snapshot.

    Returns a dict with the cell's left/right/centre in pixels, the window width, and how many
    separate white runs were found (one means exactly one cell claims to be current).
    """
    a = np.asarray(Image.open(path).convert("RGB"))
    h, w, _ = a.shape
    # FilmstripView.height is 10 + 78 + 22 + 4 = 114 pt; at 2x that is the bottom 228 px. The
    # cell itself is the upper 78 pt of that band, which is the only place the border is drawn.
    band = a[max(0, h - 208):h - 52, :, :]
    white = band[:, :, 1] >= WHITE
    columns = np.where(white.any(axis=0))[0]

    runs = 0
    if len(columns):
        runs = 1 + int(np.sum(np.diff(columns) > 1))
    run = longest_run(columns)
    if not run:
        return {"runs": 0, "left": None, "right": None, "centre": None, "width": w}
    return {"runs": runs, "left": int(run[0]), "right": int(run[1]),
            "centre": (run[0] + run[1]) / 2.0, "width": w}


def run(name, extra_env, action=None, action_at=0.0, shot_at=9.0, wait_after=3.0):
    shots = os.path.join(OUT, name)
    shutil.rmtree(shots, ignore_errors=True)
    os.makedirs(shots)
    # A leftover instance would take the pointer and the snapshot's window numbers.
    subprocess.run(["pkill", "-f", "MacOS/Picnido"], capture_output=True)
    time.sleep(1)

    env = dict(os.environ)
    env.update({
        "PICNIDO_SCREEN": "left",
        "PICNIDO_ROOTS": LIB,
        "PICNIDO_MIN_BYTES": "0",
        "PICNIDO_CHROME_PIN": "1",
        "PICNIDO_INDEX_DIR": os.path.join(shots, "index"),
        "PICNIDO_THUMB_DIR": os.path.join(shots, "thumbs"),
        "PICNIDO_SNAPSHOT": os.path.join(shots, "s"),
        "PICNIDO_SNAPSHOT_DELAY": str(shot_at),
    })
    env.update(extra_env)
    # A hook set to None means "off", and off has to mean off in both places it can come from:
    # `DevHook` falls through to `/tmp/picnido-hook/<name>` whenever the variable is empty, so a
    # stale file left by an earlier run would silently pin the chrome that case D needs to lose.
    for key, value in extra_env.items():
        if value is None:
            env.pop(key, None)
            try:
                os.remove(os.path.join("/tmp/picnido-hook", key))
            except OSError:
                pass
    p = subprocess.Popen([BIN], env=env, stdout=open(os.path.join(shots, "log"), "w"),
                         stderr=subprocess.STDOUT)
    try:
        # Park the pointer away from the strip before anything else. It is one physical pointer
        # shared by every case, and the previous case left it inside the band, where the chrome
        # is deliberately held open — case D would then measure a strip that never went away.
        time.sleep(0.6)
        hover("middle")
        if action:
            time.sleep(action_at)
            action()
        # Stay alive past the snapshot: terminating before it is taken leaves the shot missing,
        # and a missing shot reads as "the app crashed" rather than "the harness was impatient".
        time.sleep(max(0.0, shot_at - (action_at if action else 0)) + wait_after)
    finally:
        p.terminate()
        try:
            p.wait(timeout=10)
        except subprocess.TimeoutExpired:
            p.kill()
    log = open(os.path.join(shots, "log"), errors="replace").read()
    shots_list = os.path.join(shots, "s.list")
    png = None
    if os.path.exists(shots_list):
        for line in open(shots_list, errors="replace"):
            parts = line.split("\t")
            if len(parts) >= 4 and "win" in parts[3]:
                png = parts[3].strip()
    return log, png


def main():
    if not os.path.exists(PROBE):
        subprocess.run(["swiftc", "-O", os.path.join(HERE, "probe", "hover.swift"),
                        "-o", PROBE], check=True)
    fixture()
    print(f"binary  {BIN}")
    print(f"fixture {LIB} ({COUNT} photos)\n")

    # ---- A: the reported case -------------------------------------------------------------
    print("A  open 28 of 60, chrome pinned")
    log, png = run("a", {"PICNIDO_VIEWER_INDEX": "28"})
    m = re.search(r"\[hooks\] viewerindex: (\d+) of (\d+) -> (\S+)", log)
    say(m is not None and m.group(1) == "28" and m.group(3) == "p-28.jpg",
        "the viewer opened on the 28th picture", m.group(0) if m else "no hook line")
    r = measure(png)
    centre = r["width"] / 2.0
    say(r["runs"] == 1, "exactly one cell is drawn as current", f"runs={r['runs']}")
    say(r["centre"] is not None and abs(r["centre"] - centre) <= TOLERANCE_PX,
        "the current cell is in the middle of the band",
        f"cell centre {r['centre']} px, band centre {centre:.1f} px"
        if r["centre"] is not None else "no white border found")
    say(r["left"] is not None and 60 < r["left"] < r["width"] - 60,
        "the row is scrolled, not parked at the left edge",
        f"cell at {r['left']}..{r['right']} px")

    # ---- B: control -----------------------------------------------------------------------
    print("\nB  open 1 of 60, chrome pinned (control: the row must NOT be centred)")
    log, png = run("b", {"PICNIDO_VIEWER_INDEX": "1"})
    r = measure(png)
    say(r["left"] is not None and r["left"] < 100,
        "the first picture sits at the left edge", f"left={r['left']} px")
    say(r["centre"] is not None and abs(r["centre"] - r["width"] / 2.0) > 400,
        "and is nowhere near the middle, so A measured position, not presence",
        f"cell centre {r['centre']} px vs {r['width'] / 2.0:.1f}")

    # ---- C: the other end -----------------------------------------------------------------
    print("\nC  open 60 of 60, chrome pinned")
    log, png = run("c", {"PICNIDO_VIEWER_INDEX": "60"})
    r = measure(png)
    say(r["left"] is not None and r["right"] is not None and r["right"] > r["width"] - 140,
        "the last picture is fully visible at the right end",
        f"cell at {r['left']}..{r['right']} px of {r['width']}")
    say(r["centre"] is not None and r["centre"] > r["width"] / 2.0 + 400,
        "and the row is scrolled to its end rather than begging to centre a cell it cannot",
        f"cell centre {r['centre']} px vs {r['width'] / 2.0:.1f}")

    # ---- D: the rebuild -------------------------------------------------------------------
    # No PICNIDO_CHROME_PIN: the chrome hides on its own timer, and the pointer brings it back —
    # which tears the strip down and builds a new one. That is the path the pin skips.
    print("\nD  open 28 of 60, chrome hides by itself and is revealed by the pointer")
    log, png = run("d", {"PICNIDO_VIEWER_INDEX": "28", "PICNIDO_CHROME_PIN": None},
                   action=lambda: hover("bottom", 40), action_at=6.5, shot_at=9.5)
    say("chrome hidden" in log, "the chrome really did hide first",
        "before the reveal" if "chrome hidden" in log else "no hide in the log")
    say("showChrome -> true" in log, "and the pointer brought it back",
        f"{log.count('showChrome -> true')} reveal(s) in the log")
    r = measure(png)
    say(r["runs"] == 1 and r["centre"] is not None
        and abs(r["centre"] - r["width"] / 2.0) <= TOLERANCE_PX,
        "after the rebuild the current cell is still in the middle",
        f"cell centre {r['centre']} px, band centre {r['width'] / 2.0:.1f} px, runs={r['runs']}")

    print()
    if failures:
        print(f"FAILED {len(failures)}:")
        for f in failures:
            print(f"  - {f}")
        return 1
    print("all checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
