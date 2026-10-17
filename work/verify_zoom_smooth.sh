#!/bin/zsh
# verify_zoom_smooth.sh — "zooming a hundred-megapixel photo has to feel like glass".
#
# The complaint this answers was phrased by feel ("放大的时候比较卡顿，有时候像掉帧"), so it
# needs a number, and the number has to be about *frames that were due*. A canvas that simply
# had nothing new to draw is idle, not stuttering; windows sit still for a second at a time
# while a sharper tile decodes and that must not be counted.
#
# Two measurements, because the two gestures fail in different places:
#
#   1. Wheel burst — 130 real scroll events through the window server, over the photo. This
#      catches anything the *zoom* path does per notch: re-laying out the canvas, re-decoding a
#      plane, handing CoreAnimation a fresh multi-megabyte bitmap.
#   2. Pan benchmark — a synthetic drag at 400% of the original, which is where the crop path
#      decides whether to re-tile at all. Zooming out is cheap; dragging a magnified crop is
#      what re-decodes fifty times if the coverage test is wrong.
#
# Judged, per gesture: p95 of the frame interval, plus how many frames were more than 100 ms
# late (i.e. frames nobody could call anything but dropped). The absolute frame count is
# asserted too, so a run that rendered nothing cannot pass by being fast at it.
#
# Measured on the 1.3.7 build the wheel burst already looks fine (p95 14.6 ms) — the drag is
# where it fell over: mean lateness 14.9 ms, p95 38.0 ms. Anything that regresses either one
# fails here.

set -u
cd "$(dirname "$0")/.." || exit 1
ROOT=$PWD
APP=${APP:-$ROOT/dist/Picnido.app/Contents/MacOS/Picnido}
PROBE=$ROOT/work/probe
LIB=/tmp/picnido-smooth
OUT=/tmp/picnido-smooth-out
mkdir -p "$LIB" "$OUT"

# A hundred megapixels, generated here so the criterion does not depend on a file on anybody's
# desktop. 8736x11648 is the same size the reports were made on: big enough that a full plane is
# 388 MB and ImageIO's 1/8 fast path is the only cheap decimation.
if [[ ! -f $LIB/big.jpg ]]; then
  echo "==> building a 101-megapixel fixture (8736x11648)"
  sips -z 11648 8736 "$ROOT/work/demo-library/sample-01.jpg" --out "$LIB/big.jpg" >/dev/null || exit 1
fi
SIZE=$(sips -g pixelWidth -g pixelHeight "$LIB/big.jpg" | awk '/pixel/{printf "%s ", $2}')
echo "==> fixture $LIB/big.jpg ($SIZE)"

fail=0
note() { print -r -- "$@"; }
check() { # check <label> <actual> <op> <limit>
  local label=$1 actual=$2 op=$3 limit=$4 ok=1
  case $op in
    "<=") (( actual <= limit )) || ok=0 ;;
    ">=") (( actual >= limit )) || ok=0 ;;
    "==") (( actual == limit )) || ok=0 ;;
  esac
  if (( ok )); then note "  PASS  $label = $actual (want $op $limit)"
  else note "  FAIL  $label = $actual (want $op $limit)"; fail=1; fi
}
num() { # pull the first number out of "key ... 12.3 ms" style lines
  print -r -- "$1" | grep -oE '[0-9]+(\.[0-9]+)?' | head -1
}

run_once() { # run_once <tag> <env...>
  local tag=$1; shift
  env "$@" "$APP" >"$OUT/$tag.log" 2>&1 &
  local pid=$!
  print -r -- $pid
}

# ---------------------------------------------------------------- 1. wheel burst
# The pointer must not be parked over the filmstrip: that band reads the wheel as "next photo",
# and a run that steps pictures instead of zooming would pass this test by doing nothing.
"$PROBE/hover" left middle >/dev/null 2>&1
PID=$(run_once wheel PICNIDO_SCREEN=left PICNIDO_ROOTS="$LIB" PICNIDO_MIN_BYTES=0 \
        PICNIDO_VIEW=viewer PICNIDO_VIEWER_INDEX=1 PICNIDO_FPS_REPORT=12 \
        PICNIDO_FPS_GAPS=1 PICNIDO_LOG_TIME=1)
sleep 4
# --bottom 600 puts the cursor over the picture on a 1152-point-tall panel; wheel-up zooms in.
"$PROBE/wheel" left --bottom 600 130 --up --gap 9 >/dev/null 2>&1
sleep 9
kill -TERM "$PID" 2>/dev/null; wait "$PID" 2>/dev/null

W=$OUT/wheel.log
GEST=$(grep -E '^gesture ' "$W" | tail -1)
GESTX=$(grep -E '^gesture-x' "$W" | tail -1)
note "==> wheel burst (130 notches, 9 ms apart)"
[[ -n $GEST ]] || { note "  FAIL  no fps report — the run never rendered"; exit 1; }
P95=$(print -r -- "$GEST" | sed -E 's/.*p95 ([0-9.]+) ms.*/\1/')
MAX=$(print -r -- "$GEST" | sed -E 's/.*max ([0-9.]+) ms.*/\1/')
OVER100=$(print -r -- "$GESTX" | sed -E 's/.*>100ms ([0-9]+).*/\1/')
FRAMES=$(print -r -- "$GESTX" | sed -E 's/.*of ([0-9]+).*/\1/')
check "p95 frame interval (ms)" "$P95" "<=" 20
check "frames over 100 ms during the gesture" "$OVER100" "==" 0
check "gesture frames rendered" "$FRAMES" ">=" 80
note "  note  worst frame in the burst: $MAX ms"

# ---------------------------------------------------------------- 2. drag at 400%
"$PROBE/hover" left middle >/dev/null 2>&1
PID=$(run_once pan PICNIDO_SCREEN=left PICNIDO_ROOTS="$LIB" PICNIDO_MIN_BYTES=0 \
        PICNIDO_VIEW=viewer PICNIDO_VIEWER_INDEX=1 PICNIDO_PAN_BENCH=150 \
        PICNIDO_PAN_BENCH_AT=400 PICNIDO_VIEWER_TIMING=1)
sleep 16
kill -TERM "$PID" 2>/dev/null; wait "$PID" 2>/dev/null

P=$OUT/pan.log
note "==> drag at 400% of the original (150 steps at 125 Hz)"
LAT=$(grep -E '^lateness' "$P" | tail -1)
REDO=$(grep -E '^re-decodes' "$P" | tail -1)
[[ -n $LAT ]] || { note "  FAIL  no pan benchmark"; exit 1; }
MEAN=$(print -r -- "$LAT" | sed -E 's/.*mean ([0-9.]+) ms.*/\1/')
P95P=$(print -r -- "$LAT" | sed -E 's/.*p95 ([0-9.]+) ms.*/\1/')
TILES=$(print -r -- "$REDO" | grep -oE '[0-9]+' | head -1); TILES=${TILES:-0}
check "mean lateness (ms)" "$MEAN" "<=" 12
check "p95 lateness (ms)" "$P95P" "<=" 30
check "tiles re-rendered during the drag" "$TILES" ">=" 40
note "  note  a run that renders no tiles is frozen, not smooth — hence the floor above"

print -r -- ""
if (( fail )); then print -r -- "RESULT: FAIL"; exit 1; fi
print -r -- "RESULT: PASS"
