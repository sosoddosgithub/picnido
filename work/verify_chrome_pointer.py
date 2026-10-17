#!/usr/bin/env python3
"""The viewer's auto-hiding chrome, checked from outside the process.

Three claims, one per case. Each is answered by the app's own report lines plus the window list,
never by a screenshot:

  A  pointer resting on the filmstrip   -> the strip is never hidden from under it
  B  pointer somewhere in the middle    -> it hides on its own, and a click that lands in the
                                           strip band afterwards brings it back instead of
                                           closing the viewer
  C  arrow-key paging                   -> the strip comes up for it and goes 1.5 s after the
                                           last step, not 3.5 s

The pointer is moved with `probe/hover`, which posts real mouse-moved events. A warp will not do:
`.onContinuousHover` is fed by events, so a warped pointer that never moves is invisible to the
view — which is exactly the state case A has to get right (a viewer opened with the cursor already
sitting on the strip).

Usage:  ./work/verify_chrome_pointer.py            (needs an already-built dist/Picnido.app)
"""

import os
import re
import signal
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
BIN = os.environ.get("BIN", os.path.join(ROOT, "dist/Picnido.app/Contents/MacOS/Picnido"))
LIB = os.environ.get("LIB", os.path.join(HERE, "demo-library"))
PROBE = os.path.join(HERE, "probe")
OUT = os.environ.get("OUT", "/tmp/picnido-chrome")

for path, why in ((BIN, "build it first: ./build_app.sh release"),
                  (os.path.join(PROBE, "hover"), "swiftc -O work/probe/hover.swift -o work/probe/hover"),
                  (os.path.join(PROBE, "winlist"), "swiftc -O work/probe/winlist.swift -o work/probe/winlist")):
    if not os.path.exists(path):
        sys.exit("missing %s — %s" % (path, why))

FAILS = []


def say(text=""):
    print(text, flush=True)


def check(ok, label, detail=""):
    say("  %-4s %s%s" % ("PASS" if ok else "FAIL", label, ("  — " + detail) if detail else ""))
    if not ok:
        FAILS.append(label)


def hover(where, value=None):
    args = [os.path.join(PROBE, "hover"), "left"]
    if where == "bottom":
        args += ["--bottom", str(value)]
    elif where == "middle":
        pass
    return subprocess.run(args, capture_output=True, text=True).stdout.strip()


def viewer_windows(width, height):
    """Count of on-screen windows of exactly the panel's size. The library window is smaller and
    is faded rather than ordered out in picture mode, so size is the only honest discriminator."""
    out = subprocess.run([os.path.join(PROBE, "winlist"), "picnido"],
                         capture_output=True, text=True).stdout
    want = "%dx%d" % (width, height)
    n = 0
    for line in out.splitlines():
        cols = line.split("\t")
        if len(cols) < 7 or cols[0] == "pid":
            continue
        if cols[3] == "true" and cols[4].endswith(want):
            n += 1
    return n


class Run:
    """One launch. Collects (seconds since launch, line) so the log carries its own clock."""

    def __init__(self, name, extra):
        self.name = name
        self.lines = []
        self.lock = threading.Lock()
        os.makedirs(os.path.join(OUT, name), exist_ok=True)
        env = dict(os.environ)
        env.update({
            "PICNIDO_SCREEN": "left",
            "PICNIDO_ROOTS": LIB,
            "PICNIDO_MIN_BYTES": "0",
            "PICNIDO_VIEW": "1",
            "PICNIDO_GEOM_REPORT": "1",
            "PICNIDO_INDEX_DIR": os.path.join(OUT, name, "index"),
            "PICNIDO_THUMB_DIR": os.path.join(OUT, name, "thumbs"),
        })
        env.update(extra)
        self.p = subprocess.Popen([BIN], env=env, stdout=subprocess.DEVNULL,
                                  stderr=subprocess.PIPE, bufsize=1, text=True)
        self.t0 = time.monotonic()
        threading.Thread(target=self._pump, daemon=True).start()

    def _pump(self):
        for line in self.p.stderr:
            with self.lock:
                self.lines.append((time.monotonic() - self.t0, line.rstrip("\n")))

    def marks(self, pattern):
        rx = re.compile(pattern)
        with self.lock:
            return [(t, ln) for t, ln in self.lines if rx.search(ln)]

    def first(self, pattern, timeout):
        rx = re.compile(pattern)
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            with self.lock:
                for t, ln in self.lines:
                    if rx.search(ln):
                        return t, ln
            if self.p.poll() is not None:
                return None
            time.sleep(0.1)
        return None

    def size(self):
        hit = self.first(r"viewport=\(([\d.]+), ([\d.]+)\)", 15)
        if not hit:
            return None
        m = re.search(r"viewport=\(([\d.]+), ([\d.]+)\)", hit[1])
        return int(float(m.group(1))), int(float(m.group(2)))

    def stop(self):
        if self.p.poll() is None:
            self.p.send_signal(signal.SIGTERM)
            try:
                self.p.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.p.kill()


def dump(run, keep=()):
    with run.lock:
        for t, ln in run.lines:
            if not keep or any(re.search(k, ln) for k in keep):
                say("    %6.2f  %s" % (t, ln))


# ------------------------------------------------------------------ A: pointer on the strip
def case_a():
    say("")
    say("=== A. pointer parked on the filmstrip when the viewer opens ===")
    say("  " + hover("bottom", 40) + "   (40pt above the bottom edge of the left display)")
    r = Run("a-strip", {})
    try:
        size = r.size()
        if not size:
            say("  VOID  no viewer geometry — nothing to judge")
            return
        say("  panel %dx%d" % size)
        # 3.5 s after open is the first moment the chrome would leave on its own; wait past it.
        time.sleep(8.0)
        held = r.marks(r"chrome held by pointer \(filmstrip\)")
        hidden = r.marks(r"chrome hidden")
        check(bool(held), "the strip is held by the pointer",
              "%d report(s), first at %.2fs" % (len(held), held[0][0]) if held else "no hold reported")
        check(not hidden, "the strip was not hidden while the pointer sat on it",
              "hidden at %.2fs" % hidden[0][0] if hidden else "")
        check(viewer_windows(*size) >= 1, "the viewer is still on screen")
        dump(r, (r"chrome ",))
    finally:
        r.stop()


# ------------------------------------------------------- B: hides by itself, strip click is safe
def case_b():
    say("")
    say("=== B. pointer in the middle: hides on its own, then a click in the strip band ===")
    say("  " + hover("middle") + "   (display centre)")
    # The click is fired by the app itself, at 7 s: well past the 3.5 s fuse, so it lands on a
    # strip that is already down. That is the sequence that used to close the viewer.
    r = Run("b-click", {
        "PICNIDO_CLICK_TARGET": "viewer",
        "PICNIDO_CLICK_DELAY": "7",
        "PICNIDO_CLICK": "1024,1100",   # 52pt above the bottom edge of a 1152pt panel
    })
    try:
        size = r.size()
        if not size:
            say("  VOID  no viewer geometry — nothing to judge")
            return
        hidden = r.first(r"chrome hidden", 12)
        check(hidden is not None, "the strip hides on its own",
              "at %.2fs" % hidden[0] if hidden else "never hid in 12 s")
        up_before = viewer_windows(*size)
        # Let the click land and settle.
        time.sleep(12.0)
        clicks = r.marks(r"clicksheet: click 0")
        shown = r.marks(r"showChrome -> true")
        closed = r.marks(r"--- viewer closed|viewer closed")
        up_after = viewer_windows(*size)
        check(bool(clicks), "the click was delivered",
              clicks[0][1] if clicks else "no clicksheet line — the run proves nothing")
        check(bool(shown), "the click went to the strip branch, not the backdrop",
              "showChrome at %.2fs" % shown[0][0] if shown else "no showChrome")
        check(up_before >= 1 and up_after >= 1, "the viewer is still open after the click",
              "windows %d -> %d" % (up_before, up_after))
        dump(r, (r"chrome ", r"clicksheet", r"toggleChrome"))
    finally:
        r.stop()


# ----------------------------------------------------------------- C: paging brings it back
def case_c():
    say("")
    say("=== C. arrow-key paging: up for the press, gone 1.5 s after the last one ===")
    say("  " + hover("middle"))
    # 2.2 s between steps is longer than the 1.5 s fuse, so each step re-shows the strip and the
    # hide that follows can be timed against the show that armed it.
    r = Run("c-paging", {"PICNIDO_VIEWER_STEP": "4", "PICNIDO_VIEWER_STEP_MS": "2200"})
    try:
        size = r.size()
        if not size:
            say("  VOID  no viewer geometry — nothing to judge")
            return
        steps = r.first(r"viewerstep: 4 steps", 25)
        check(steps is not None, "all four steps ran")
        time.sleep(3.0)          # one more fuse, so the last hide has landed
        shown = r.marks(r"chrome shown by arrow key")
        hidden = r.marks(r"chrome hidden")
        check(bool(shown), "paging brings the strip back", "%d show(s)" % len(shown))
        # Every show must be answered by a hide, and answered in about a second and a half.
        gaps = []
        for t_show, _ in shown:
            after = [t for t, _ in hidden if t > t_show]
            if after:
                gaps.append(after[0] - t_show)
        if gaps:
            worst = max(gaps)
            check(1.2 <= min(gaps) and worst <= 2.4,
                  "the hide follows %.2f–%.2fs after the show (want ~1.5, not 3.5)"
                  % (min(gaps), worst))
        else:
            check(False, "no hide was recorded after a paging reveal")
        check(viewer_windows(*size) >= 1, "the viewer is still on screen")
        dump(r, (r"chrome ", r"viewerstep"))
    finally:
        r.stop()


def main():
    if not os.path.isdir(LIB):
        sys.exit("no photo library at %s" % LIB)
    os.makedirs(OUT, exist_ok=True)
    say("binary  %s" % BIN)
    say("library %s" % LIB)
    case_a()
    case_b()
    case_c()
    say("")
    if FAILS:
        say("FAILED: " + "; ".join(FAILS))
        return 1
    say("all chrome-pointer checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
