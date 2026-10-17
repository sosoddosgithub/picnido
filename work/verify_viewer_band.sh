#!/bin/bash
#
# Measures the viewer's vertical band — the two gaps that decide whether a picture sits
# comfortably between the tool bar and the filmstrip, or is jammed against one of them.
#
#   topGap    = window top   -> photo top
#   bottomGap = photo bottom -> window bottom
#
# The picture is *centred in the whole window* today, so topGap == bottomGap always. That
# equality is not the same thing as looking balanced: the filmstrip owns the bottom
# `clearance` points of the window, so at the tall-photo limit (photo height = viewport -
# 2·clearance) the bottom edge of the photo lands exactly on the top edge of the filmstrip —
# bottomGap == clearance means **zero air** — while the top has the tool bar's own height
# subtracted from it, which is less than clearance, leaving visible glass up there. The
# report the user gave ("上面比较宽，和胶片条离得比较近") is that arithmetic.
#
# So the numbers this script pulls out are the ones to compare across a change:
#   photo height, top air (photo top → tool bar bottom), bottom air (photo bottom → strip top)
#
# Usage:  [BIN=/path/to/Picnido] ./verify_viewer_band.sh [out_dir]
#
# Runs the viewer three ways — chrome pinned, chrome hidden, and a wide photo — because the
# question "does the picture stay put when the filmstrip hides?" is only answerable by
# comparing the runs, and the wide case is where the width limit, not the height limit, binds.
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
BIN="${BIN:-$ROOT/.build/release/Picnido}"
OUT="${1:-/tmp/viewer-band}"
# Three sibling fixtures rather than three subdirectories: `PICNIDO_ROOTS` scans recursively, so
# nesting them would have every case load all three sets and report "photos=45" for all of them.
FIX="${FIX:-/tmp/viewer-geom}"
FIX_WIDE="${FIX_WIDE:-/tmp/viewer-geom-wide}"
FIX_FRAMES="${FIX_FRAMES:-/tmp/viewer-geom-frames}"

[ -x "$BIN" ] || { echo "missing $BIN — build first"; exit 1; }

# ---------------------------------------------------------------- fixture
# Two shapes, because the two limits fail differently: a tall photo is capped by height (and
# is therefore the one that ends up flush against the filmstrip), a wide one by width.
mkdir -p "$FIX"
if [ ! -f "$FIX/a-tall.jpg" ]; then
  sips -s format jpeg -Z 2200 /System/Library/CoreServices/DefaultDesktop.heic --out "$FIX/base.jpg" >/dev/null 2>&1
  sips -c 1600 900 "$FIX/base.jpg" --out "$FIX/a-tall.jpg" >/dev/null 2>&1
  for i in $(seq 1 14); do cp "$FIX/a-tall.jpg" "$FIX/b$i.jpg"; done
  rm -f "$FIX/base.jpg"
fi
if [ ! -f "$FIX_WIDE/z-wide.jpg" ]; then
  mkdir -p "$FIX_WIDE"
  sips -s format jpeg -Z 2200 /System/Library/CoreServices/DefaultDesktop.heic --out "$FIX_WIDE/base.jpg" >/dev/null 2>&1
  # A *panorama*, not merely a landscape photo. At 0.82 of a 2048-wide viewport the height cap is
  # 902pt, so anything wider than 1679.36/902 ≈ 1.86:1 is width-limited; 16:9 is not, and a 16:9
  # "wide" case would quietly be testing the height limit a second time while claiming to test the
  # other one. 2000×700 = 2.86:1 leaves no doubt. The run then asserts `boundBy=width` so the
  # fixture cannot silently stop exercising the branch it exists for.
  sips -z 700 2000 "$FIX_WIDE/base.jpg" --out "$FIX_WIDE/z-wide.jpg" >/dev/null 2>&1
  for i in $(seq 1 14); do cp "$FIX_WIDE/z-wide.jpg" "$FIX_WIDE/f$i.jpg"; done
  rm -f "$FIX_WIDE/base.jpg"
fi

# The pixel-check fixture: a black plate with a white frame. The frame is the only thing in it
# that survives the frosted backdrop as a *bright* pixel — the backdrop is the same picture
# blurred, drawn at 46% over the desktop and darkened 14%, which lands its white around 100–140
# — so "a row containing something brighter than 200" is true only inside the picture, and the
# first and last such rows are its top and bottom edges. That is how the geometry report gets
# checked against the screen instead of against itself.
PY="${PYTHON:-/usr/local/bin/python3}"
if [ ! -f "$FIX_FRAMES/a-frame.jpg" ]; then
  mkdir -p "$FIX_FRAMES"
  "$PY" - "$FIX_FRAMES" <<'PYX' || echo "  (no PIL — the pixel case will be skipped)"
import sys
from PIL import Image, ImageDraw
out = sys.argv[1]
im = Image.new("RGB", (900, 1600), (0, 0, 0))
ImageDraw.Draw(im).rectangle([0, 0, 899, 1599], outline=(255, 255, 255), width=24)
im.save(out + "/a-frame.jpg", quality=97)
PYX
  for i in $(seq 1 14); do cp "$FIX_FRAMES/a-frame.jpg" "$FIX_FRAMES/f$i.jpg" 2>/dev/null; done
fi

# ---------------------------------------------------------------- one run
run_case() { # run_case <name> <fixture-dir> [extra env…]
  local name="$1" fixture="$2"; shift 2
  local dir="$OUT/$name"
  rm -rf "$dir"; mkdir -p "$dir"

  # `env` rather than `VAR=… cmd`: in zsh an assignment that arrives through "$@" is taken as
  # the command name, and the run dies with "PICNIDO_SHEET=export: command not found".
  env "$@" \
    PICNIDO_SCREEN=left PICNIDO_MIN_BYTES=0 PICNIDO_ROOTS="$fixture" PICNIDO_VIEW=1 \
    PICNIDO_GEOM_REPORT=1 PICNIDO_SNAPSHOT="$dir/shot" PICNIDO_SNAPSHOT_DELAY=3.5 \
    PICNIDO_REPORT_FILE="$dir/report.txt" \
    "$BIN" >"$dir/stdout.txt" 2>&1 &
  local pid=$!
  sleep 11
  kill -TERM $pid 2>/dev/null; wait $pid 2>/dev/null

  # The library's own count, so an empty grid can never be mistaken for a layout result.
  local photos
  photos="$(grep -oE 'photos=[0-9]+' "$dir/report.txt" | head -1 | cut -d= -f2)"
  echo "  photos loaded: ${photos:-?}"
  grep -A11 -- "--- viewer geometry ---" "$dir/report.txt" | sed 's/^/    /'
  grep -A7  -- "--- filmstrip geometry ---" "$dir/report.txt" | grep -E "global|local" | sed 's/^/    /'
}

echo "=== viewer vertical band ==="
echo "binary $BIN"
echo "fixture $FIX"
echo
echo "--- A. tall photo, chrome pinned (the case in the report) ---"
run_case tall-pinned "$FIX" PICNIDO_CHROME_PIN=1
echo
echo "--- B. tall photo, chrome hidden (photo must NOT move between A and B) ---"
run_case tall-hidden "$FIX"
echo
echo "--- C. wide photo, chrome pinned (the width limit binds here, not the height) ---"
run_case wide-pinned "$FIX_WIDE" PICNIDO_CHROME_PIN=1
echo
echo "--- D. the pixel check: where the edges really are, from outside the process ---"
# Everything above reads numbers the binary printed about itself. This one reads the screen.
run_case frame-pinned "$FIX_FRAMES" PICNIDO_CHROME_PIN=1

echo
echo "=== snapshots ==="
for d in "$OUT"/*/; do
  f="$(ls -S "$d"shot*.png 2>/dev/null | head -1)"
  [ -n "$f" ] && printf "  %-24s %s\n" "$(basename "$d")" "$(basename "$f") $(sips -g pixelWidth -g pixelHeight "$f" 2>/dev/null | awk '/pixel/{printf "%s ", $2}')"
done

# ---------------------------------------------------------------- verdict
#
# Every number below is read back out of the runs' own reports, so a change to the geometry that
# quietly stops reporting is a failure rather than a pass. The reference values are the
# `ViewerGeometry.breath` the binary printed, not a number written down here.

field() { # field <report> <key> — first "<key>=<number>" as a number
  # The leading group is load-bearing: keys printed at the start of a line (`topBand=88.0 …`
  # heads the air line) have no character before them, and a bare `[^A-Za-z_]` quietly missed
  # exactly that one — which turned the "expected top edge" of the pixel check into 0+breath.
  grep -oE "(^|[^A-Za-z_])$2=[-0-9.]+" "$1" 2>/dev/null | head -1 | sed -E "s/.*$2=//"
}
near() { awk -v a="$1" -v b="$2" -v t="$3" 'BEGIN{d=a-b; if(d<0)d=-d; exit !(d<=t)}'; }
atleast() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a+0 >= b+0 - 0.5)}'; }

PASS=0; FAIL=0
check() { if [ "$2" = 1 ]; then printf "  PASS  %s\n" "$1"; PASS=$((PASS+1));
          else printf "  FAIL  %s\n" "$1"; FAIL=$((FAIL+1)); fi; }

echo
echo "=== verdict ==="
for case in tall-pinned tall-hidden wide-pinned frame-pinned; do
  R="$OUT/$case/report.txt"
  n="$(grep -oE 'photos=[0-9]+' "$R" | head -1 | cut -d= -f2)"
  check "$case: a photo was actually on screen (photos=${n:-none})" \
        "$([ -n "$n" ] && [ "$n" -gt 0 ] && echo 1 || echo 0)"
done

P="$OUT/tall-pinned/report.txt"
H="$OUT/tall-hidden/report.txt"
W="$OUT/wide-pinned/report.txt"

breath="$(field "$P" breath)"
airTop="$(field "$P" airTop)"
airBottom="$(field "$P" airBottom)"
echo "  breath=$breath airTop=$airTop airBottom=$airBottom"

check "tall: air above (${airTop}pt) clears the tool bar by at least one breath" \
      "$(atleast "$airTop" "$breath" && echo 1 || echo 0)"
check "tall: air below (${airBottom}pt) keeps the picture off the filmstrip" \
      "$(atleast "$airBottom" "$breath" && echo 1 || echo 0)"
check "tall: the two airs are equal (the picture is balanced, not just centred)" \
      "$(near "$airTop" "$airBottom" 1 && echo 1 || echo 0)"

airTopW="$(field "$W" airTop)"
airBottomW="$(field "$W" airBottom)"
boundT="$(grep -oE 'boundBy=[a-z]+' "$P" | head -1 | cut -d= -f2)"
boundW="$(grep -oE 'boundBy=[a-z]+' "$W" | head -1 | cut -d= -f2)"
echo "  tall: boundBy=$boundT   wide: airTop=$airTopW airBottom=$airBottomW boundBy=$boundW"
# Without this line the "wide" case is a claim, not a test: a 16:9 fixture is *also* capped by
# height on this display, so it would repeat the tall case under a different name and pass no
# matter what the width branch did.
check "tall: the height limit is the one binding there" \
      "$([ "$boundT" = height ] && echo 1 || echo 0)"
check "wide: the width limit really is the binding one (the fixture is a panorama)" \
      "$([ "$boundW" = width ] && echo 1 || echo 0)"
check "wide: the same balance holds when the width limit binds" \
      "$(near "$airTopW" "$airBottomW" 1 && echo 1 || echo 0)"
check "wide: air below is at least one breath" \
      "$(atleast "$airBottomW" "$breath" && echo 1 || echo 0)"

menuBand="$(grep -oE 'menuBand=[-0-9.]+' "$P" | head -1 | cut -d= -f2)"
chromeTopPad="$(grep -oE 'chromeTopPad=[-0-9.]+' "$P" | head -1 | cut -d= -f2)"
echo "  menuBand=$menuBand chromeTopPad=$chromeTopPad"
check "the tool bar's row starts below the menu bar ($chromeTopPad >= $menuBand)" \
      "$(atleast "$chromeTopPad" "$menuBand" && echo 1 || echo 0)"

rectP="$(grep -oE 'photoRect=\([^)]*\)' "$P" | head -1)"
rectH="$(grep -oE 'photoRect=\([^)]*\)' "$H" | head -1)"
echo "  pinned  $rectP"
echo "  hidden  $rectH"
check "hiding the chrome does not move or resize the picture" \
      "$([ -n "$rectP" ] && [ "$rectP" = "$rectH" ] && echo 1 || echo 0)"

# ---- The same geometry again, but read off the screen. The report above is the thing under
# test; this is the only line in the file that is not.
F="$OUT/frame-pinned/report.txt"
SNAP="$(ls -S "$OUT/frame-pinned"/shot*.png 2>/dev/null | head -1)"
if [ -n "$SNAP" ] && [ -x "$PY" ]; then
  out="$("$PY" "$ROOT/work/probe/bandscan.py" photo "$SNAP" 2 --lo=-1 --hi=200 --col 2048)"
  ptop="$(printf '%s' "$out"   | sed -nE 's/.*top=([0-9.]+)pt.*/\1/p')"
  pbottom="$(printf '%s' "$out" | sed -nE 's/.*bottom=([0-9.]+)pt.*/\1/p')"
  crow="$("$PY" "$ROOT/work/probe/bandscan.py" chrome "$SNAP" 2 | sed -nE 's/.*y=([0-9.]+)pt.*/\1/p')"

  topBand="$(field "$F" topBand)"
  clearance="$(field "$F" clearance)"
  viewportH="$(grep -oE 'viewport=\([0-9.]+, [0-9.]+\)' "$F" | head -1 | sed 's/.*, //; s/)//')"
  wantTop="$(awk -v a="$topBand" -v b="$breath" 'BEGIN{print a+b}')"
  wantBottom="$(awk -v v="$viewportH" -v c="$clearance" -v b="$breath" 'BEGIN{print v-c-b}')"
  echo "  pixels  top=$ptop (want $wantTop)  bottom=$pbottom (want $wantBottom)  chrome=$crow"

  check "pixels: the picture's top edge lands one breath below the tool bar" \
        "$([ -n "$ptop" ] && near "$ptop" "$wantTop" 3 && echo 1 || echo 0)"
  check "pixels: the picture's bottom edge lands one breath above the filmstrip" \
        "$([ -n "$pbottom" ] && near "$pbottom" "$wantBottom" 3 && echo 1 || echo 0)"
  check "pixels: the tool bar's first bright row clears the menu bar ($crow >= $menuBand)" \
        "$([ -n "$crow" ] && atleast "$crow" "$menuBand" && echo 1 || echo 0)"
else
  check "pixels: bandscan ran (needs Pillow at \$PYTHON)" 0
fi

echo
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]

