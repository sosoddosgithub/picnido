#!/usr/bin/env python3
"""Judgement for the two filmstrip gestures added in 1.3.5.

1. Wheel over the strip band walks the row one picture per notch — the same step the right
   arrow key makes — and stops at both ends instead of wrapping.
2. Arriving at either end (or being refused by it) makes the strip beat: the cell at that end
   swells 12 % and the row shoves 7 pt outward, then springs back.

Both are checked from outside the process:

* the wheel is posted as a real `CGEvent` through the window server (`work/probe/wheel`), so
  the thing under test is the app's *routing* of the wheel as much as the arithmetic;
* the beat is measured in pixels — the extra 12 % is visible in a window snapshot, and
  `PICNIDO_STRIP_BEAT_PIN` holds the extreme pose so the measurement can be aimed at it.

The fixture is three flat-colour photos on purpose: the current cell is the only white thing
in the strip band, so "how big is that cell" is a threshold on one channel rather than an
image-recognition problem.

    ./work/verify_strip_wheel.py            # BIN=… to test another bundle
"""

import os
import re
import shutil
import subprocess
import sys
import time

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
PROBE = os.path.join(HERE, "probe", "wheel")
BIN = os.environ.get("BIN", os.path.join(ROOT, "dist/Picnido.app/Contents/MacOS/Picnido"))
OUT = os.environ.get("OUT", "/tmp/picnido-stripwheel")
LIB = os.path.join(OUT, "library")

failures = []


def say(ok, label, detail=""):
    print(f"  {'PASS' if ok else 'FAIL'}  {label}" + (f"   {detail}" if detail else ""))
    if not ok:
        failures.append(label)


def fixture():
    """Three flat photos, 1600×1200. Same corner as the demo library, different reason: here the
    images must be featureless so the current cell's white border is the only bright pixel in
    the band."""
    os.makedirs(LIB, exist_ok=True)
    for i, colour in enumerate([(46, 47, 52), (52, 44, 46), (44, 52, 48)]):
        Image.new("RGB", (1600, 1200), colour).save(f"{LIB}/flat-{i + 1}.jpg", quality=90)


def run(name, script, extra_env=None, wait=7):
    """Start the viewer, run `script()` against it, stop it. Returns (log, zoom lines, shots dir)."""
    shots = os.path.join(OUT, name)
    shutil.rmtree(shots, ignore_errors=True)
    os.makedirs(shots)
    # A leftover instance from the previous case would sit under the pointer and take the wheel.
    subprocess.run(["pkill", "-f", "MacOS/Picnido"], capture_output=True)
    time.sleep(1)
    zoom = os.path.join(shots, "zoom.log")
    shot_at = (extra_env or {}).get("_shot_at", 0)
    env = dict(os.environ)
    env.update({
        "PICNIDO_SCREEN": "left",
        "PICNIDO_ROOTS": LIB,
        "PICNIDO_MIN_BYTES": "0",
        "PICNIDO_VIEW": "1",
        "PICNIDO_CHROME_PIN": "1",
        "PICNIDO_STRIP_WHEEL": "1",
        "PICNIDO_ZOOM_LOG": zoom,
        "PICNIDO_INDEX_DIR": os.path.join(shots, "index"),
        "PICNIDO_THUMB_DIR": os.path.join(shots, "thumbs"),
        "PICNIDO_SNAPSHOT": os.path.join(shots, "s"),
        "PICNIDO_SNAPSHOT_DELAY": str(shot_at or 30),
    })
    if extra_env:
        extra_env.pop("_shot_at", None)
        env.update(extra_env)
    p = subprocess.Popen([BIN], env=env, stdout=open(os.path.join(shots, "log"), "w"),
                         stderr=subprocess.STDOUT)
    try:
        time.sleep(wait)
        script()
        # Stay alive past the snapshot: terminating before it is taken leaves the shot missing,
        # and a missing shot reads as "the app crashed" rather than "the harness was impatient".
        time.sleep(max(3, shot_at + 2 - wait) if shot_at else 3)
    finally:
        p.terminate()
        try:
            p.wait(timeout=10)
        except subprocess.TimeoutExpired:
            p.kill()
    log = open(os.path.join(shots, "log"), errors="replace").read()
    zl = open(zoom, errors="replace").read() if os.path.exists(zoom) else ""
    return log, zl, shots


def wheel(ticks, bottom=60, up=False):
    cmd = [PROBE, "left", "--bottom", str(bottom), str(ticks)] + (["--up"] if up else [])
    subprocess.run(cmd, check=True, capture_output=True)


def moves(log):
    """(from, to) for every accepted step, in order."""
    return [(int(a), int(b)) for a, b in re.findall(r"\[strip\] moved (\d+) -> (\d+)", log)]


def refused(log):
    return re.findall(r"\[strip\] refused at (first|last)", log)


def beats(log, edge=None, via=None):
    out = []
    for e, v in re.findall(r"\[strip\] beat edge=(\w+) .* via=(\w+)", log):
        if (edge is None or e == edge) and (via is None or v == via):
            out.append((e, v))
    return out


def current_cell(shot):
    """Outer box of the only pure-white rectangle in the strip band, in points."""
    im = Image.open(shot).convert("L")
    w, h = im.size
    px = im.load()
    xs, ys = [], []
    for y in range(h - 400, h):
        for x in range(w):
            if px[x, y] >= 200:
                xs.append(x)
                ys.append(y)
    if not xs:
        return None
    return ((max(xs) - min(xs) + 1) / 2, (max(ys) - min(ys) + 1) / 2, min(xs) / 2)


def main():
    if not os.path.exists(PROBE):
        print(f"missing probe {PROBE} — build it with:\n  swiftc -O work/probe/wheel.swift -o work/probe/wheel")
        return 2
    shutil.rmtree(OUT, ignore_errors=True)
    os.makedirs(OUT)
    fixture()

    print("=== A. wheel over the strip walks the row, and stops at the last picture ===")
    log, zoom, _ = run("a", lambda: (wheel(1), time.sleep(0.4), wheel(1), time.sleep(0.4), wheel(1)))
    print("      steps   ", moves(log))
    print("      refused ", refused(log))
    say(moves(log) == [(0, 1), (1, 2)], "three notches from the first photo moved 0→1→2")
    say(refused(log) == ["last"], "the third notch was refused at the last photo, not wrapped",
        f"{len(refused(log))} refusals")
    say(("last", "wheel") in beats(log), "the refusal beat the strip (edge=last, via=wheel)")
    say(("last", "arrival") in beats(log), "landing on the last photo beat it (via=arrival)")
    say(zoom.strip() == "", "the wheel over the strip did not zoom the photo")

    print()
    print("=== B. backwards: same walk, refused at the first picture ===")
    log, _, _ = run("b", lambda: (wheel(4, up=True),))
    print("      steps   ", moves(log))
    say(moves(log) == [], "nothing to walk back to: the first notch was already at the first photo")
    say(refused(log) and set(refused(log)) == {"first"}, "refused at the first photo",
        f"{len(refused(log))} of 4 notches")
    say(("first", "wheel") in beats(log), "the refusal beat the strip (edge=first, via=wheel)")

    print()
    print("=== C. the same wheel one band up still zooms ===")
    log, zoom, _ = run("c", lambda: (wheel(2, bottom=600),))
    print("      zoom    ", zoom.strip().replace("\n", " | ")[:120])
    say(len(zoom.strip().splitlines()) >= 1, "wheel over the photo produced zoom events")
    say(moves(log) == [], "wheel over the photo did not step the strip")

    print()
    print("=== D. the beat is a real, measurable swell ===")
    _, _, rest_shots = run("d_rest", lambda: (wheel(2),), {"_shot_at": 14})
    _, _, peak_shots = run("d_peak", lambda: (wheel(2),),
                           {"PICNIDO_STRIP_BEAT_PIN": "1", "_shot_at": 14})
    rest = current_cell(os.path.join(rest_shots, "s_2_win.png"))
    peak = current_cell(os.path.join(peak_shots, "s_2_win.png"))
    if not rest or not peak:
        say(False, "could not find the current cell in the snapshots")
    else:
        ratio = peak[0] / rest[0]
        print(f"      resting cell {rest[0]:.1f} × {rest[1]:.1f} pt at x={rest[2]:.1f}")
        print(f"      beat pose    {peak[0]:.1f} × {peak[1]:.1f} pt at x={peak[2]:.1f}   ratio {ratio:.3f}")
        say(abs(rest[0] - rest[1]) < 1, "the resting cell measured square (the fixture is doing its job)")
        say(1.10 <= ratio <= 1.14, "the beat pose is 10–14 % larger than the resting cell")
        # edge=last ⇒ the row shoves outward to the right of the picture, i.e. leftward here,
        # and the cell also grows half a swell on each side, so the left edge moves by both.
        say(peak[2] < rest[2], "the beat pose pushed the cell outward, away from the row")

    print()
    if failures:
        print(f"FAILED — {len(failures)}: " + "; ".join(failures))
        return 1
    print("all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
