#!/bin/bash
#
# Can this viewer open, zoom and drag a hundred-megapixel photo without freezing?
#
# The report: a folder of ~100 files at ~60 MB each. Opening is slow, and "as soon as I zoom,
# it locks up; the beachball spins for ages; then I drag and it locks up again."
#
# The numbers behind it, measured on the 8736x11648 JPEG this script uses as its fixture:
#
#   * `CIContext.createCGImage` is lazy. The old crop path "returned" in 1 ms and left the
#     rasterisation to the first draw — which happens on the main thread inside a display pass.
#   * Every crop re-decoded the whole file, because the lazy CoreImage graph was discarded with
#     the function's locals. One crop: 1271 ms. The next: 2266 ms. At 1:1 with the pan benchmark:
#     2293 ms.
#   * Zooming from fit to 1:1 in 24 steps took **13.8 s** of wall clock and blocked the main
#     thread for up to **12.4 s** at a time (1.2 fps). After the plane rework: 2.3 s, 139 ms.
#
# So the judges below are about the two things a user feels: how long a single tile costs, and how
# long the main thread is unavailable while it happens.
#
# Usage:  [BIN=/path/to/Picnido] ./verify_bigimage.sh [fixture.jpg] [out_dir]
#         FIXTURE=~/Pictures/huge.jpg ./verify_bigimage.sh
#
# Exit: 0 pass, 1 fail, 2 inconclusive (fixture missing, or the hooks never reported).
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
BIN="${BIN:-$ROOT/dist/Picnido.app/Contents/MacOS/Picnido}"
FIXTURE="${1:-${FIXTURE:-$HOME/Desktop/TG@ioopro (7).jpg}}"
OUT="${2:-/tmp/picnido-big}"
LIB="$OUT/lib"
LOG="$OUT/run.log"
SAMPLES="$OUT/samples.txt"

# Ceilings. Each one is set roughly twice the measured value, so a change of mind about the design
# does not trip them but a return to per-crop decoding does.
TILE_MS=400            # 15 ms measured; the old path measured 1271 / 2266 / 2293
ZOOM_P95_MS=250        # 80 ms measured; the old path measured 12326
ZOOM_MAX_MS=600        # 139 ms measured; the old path measured 12426
PEAK_MB=1800           # settled peak is 1.0 GB; the transient during the full-size plane is two
                       # copies of 388 MB at once (the decode plus the flattened bitmap), which
                       # has been sampled at 1.5 GB. Anything above this is growth, not a spike.
PLANE_BUILDS=4         # per photo: the level asked for, plus the prefetch

[ -x "$BIN" ] || { echo "missing $BIN — build first"; exit 1; }
[ -f "$FIXTURE" ] || { echo "INCONCLUSIVE: fixture $FIXTURE not found"; exit 2; }
command -v footprint >/dev/null || { echo "missing /usr/bin/footprint"; exit 2; }

mkdir -p "$OUT" "$LIB"
rm -f "$SAMPLES" "$LOG"
# One file is enough for the timing judges; a copy is used so the library never points at the
# user's desktop, and so a stale catalogue cannot decide the result.
/bin/cp -f "$FIXTURE" "$LIB/big.jpg"
# `/tmp` is a symlink to `/private/tmp`, and the catalogue stores resolved paths — a hook that
# passes the unresolved one silently fails to find the photo and the viewer never opens.
LIB=$(cd "$LIB" && pwd -P)
SIZE=$(stat -f%z "$LIB/big.jpg")
W=$(/usr/bin/sips -g pixelWidth "$LIB/big.jpg" 2>/dev/null | sed -n 's/.*pixelWidth: //p')
H=$(/usr/bin/sips -g pixelHeight "$LIB/big.jpg" 2>/dev/null | sed -n 's/.*pixelHeight: //p')
DIMS="${W}x${H}"
echo "==> fixture $DIMS  $((SIZE / 1024 / 1024)) MB"

rm -rf "$OUT/index" "$OUT/thumbs"
mkdir -p "$OUT/index" "$OUT/thumbs"

PICNIDO_SCREEN=left \
PICNIDO_ROOTS="$LIB" \
PICNIDO_OPEN="$LIB/big.jpg" \
PICNIDO_MIN_BYTES=0 \
PICNIDO_INDEX_DIR="$OUT/index" \
PICNIDO_THUMB_DIR="$OUT/thumbs" \
PICNIDO_VIEWER_TIMING=1 \
PICNIDO_ZOOM_BENCH=24 \
"$BIN" > /dev/null 2> "$LOG" &
APP=$!
trap 'kill -TERM "$APP" 2>/dev/null' EXIT

read_fp() { footprint -p "$APP" 2>/dev/null | sed -n 's/.*Footprint: \([0-9][0-9]*\) MB.*/\1/p' | head -1; }

# The zoom benchmark starts at 5 s and walks 24 steps at 100 ms, so 12 s covers it with room for
# the plane that the first step triggers.
PEAK=0
for _ in $(seq 1 40); do
  kill -0 "$APP" 2>/dev/null || break
  FP=$(read_fp)
  if [ -n "${FP:-}" ]; then echo "$FP" >> "$SAMPLES"; [ "$FP" -gt "$PEAK" ] && PEAK="$FP"; fi
  grep -q "end zoom benchmark" "$LOG" && break
  sleep 0.5
done
sleep 1
kill -TERM "$APP" 2>/dev/null
wait "$APP" 2>/dev/null

if ! grep -q "end zoom benchmark" "$LOG"; then
  echo "INCONCLUSIVE: the zoom benchmark never finished (see $LOG)"
  exit 2
fi

FIRST=$(grep -oE "\[viewer\] first paint [0-9]+ ms" "$LOG" | head -1 | grep -oE "[0-9]+")
PLANES=$(grep -c "\[engine\] plane" "$LOG")
ZP95=$(sed -n 's/.*lateness *mean [0-9.]* ms *p95 \([0-9.]*\) ms.*/\1/p' "$LOG" | tail -1)
ZMAX=$(sed -n 's/.*p95 [0-9.]* ms *max \([0-9.]*\) ms.*/\1/p' "$LOG" | tail -1)
ZOVER=$(sed -n 's/.*max [0-9.]* ms *over250 \([0-9]*\).*/\1/p' "$LOG" | tail -1)
ZTILES=$(sed -n 's/.*tiles *\([0-9]*\) rendered during the walk.*/\1/p' "$LOG" | tail -1)
ZFPS=$(sed -n 's/.*rendered *[0-9]* frames *-> \([0-9.]*\) fps.*/\1/p' "$LOG" | tail -1)

# Tile times. A tile that arrives right after a plane build is allowed the decode that plane just
# paid for — measured, not guessed: the budget is `that decode + TILE_MS`. Every other tile must be
# a crop, and that distinction is the whole point: a crop that costs a second means the file is
# being decoded again. (Under Rosetta the full-size decode measures 1.7 s instead of 0.8 s, which
# is why the allowance is relative rather than a constant.)
WORST_TILE=0
WORST_OVER=0        # how far the worst tile went past its own budget
TILE_COUNT=0
PLANE_MS=0
AFTER_DECODE=0
while IFS= read -r line; do
  case "$line" in
    "[engine] plane"*)
      PLANE_MS=$(echo "$line" | sed -n 's/.* in \([0-9]*\) ms.*/\1/p')
      [ -z "$PLANE_MS" ] && PLANE_MS=0
      AFTER_DECODE=1 ;;
    "[viewer] tile"*)
      MS=$(echo "$line" | sed -n 's/.* in \([0-9]*\) ms.*/\1/p')
      [ -z "$MS" ] && continue
      TILE_COUNT=$((TILE_COUNT + 1))
      if [ "$AFTER_DECODE" -eq 1 ]; then
        OVER=$((MS - PLANE_MS - TILE_MS)); AFTER_DECODE=0
      else
        OVER=$((MS - TILE_MS))
        [ "$MS" -gt "$WORST_TILE" ] && WORST_TILE=$MS
      fi
      [ "$OVER" -gt "$WORST_OVER" ] && WORST_OVER=$OVER ;;
  esac
done < "$LOG"

ZP95="${ZP95:-0}"; ZMAX="${ZMAX:-0}"; ZOVER="${ZOVER:-0}"; ZTILES="${ZTILES:-0}"

echo
echo "--- big image ---"
echo "fixture     $DIMS   first paint ${FIRST:-?} ms   planes built ${PLANES:-?}"
echo "tiles       $TILE_COUNT rendered, worst crop ${WORST_TILE} ms (ceiling ${TILE_MS}), worst overrun ${WORST_OVER} ms"
echo "zoom walk   ${ZTILES:-?} tiles, ${ZFPS:-?} fps, lateness p95 ${ZP95:-?} ms max ${ZMAX:-?} ms, over250 ${ZOVER:-?}"
echo "footprint   peak ${PEAK} MB (ceiling ${PEAK_MB})"

STATUS=0
fail() { echo "result      FAIL — $1"; STATUS=1; }

[ -n "${FIRST:-}" ] || fail "no first-paint report"
[ -n "${FIRST:-}" ] && [ "$FIRST" -gt 900 ] && fail "first paint ${FIRST} ms — a plate took longer than the whole open used to"
[ "${WORST_TILE:-0}" -gt "$TILE_MS" ] && fail "a crop took ${WORST_TILE} ms (ceiling ${TILE_MS}) — that is a decode, not a crop"
[ "${WORST_OVER:-0}" -gt 0 ] && fail "a tile overran its budget by ${WORST_OVER} ms — everything after the decode must be a crop"
[ "${ZP95%.*}" -gt "$ZOOM_P95_MS" ] && fail "zoom lateness p95 ${ZP95} ms"
[ "${ZMAX%.*}" -gt "$ZOOM_MAX_MS" ] && fail "the main thread was blocked for ${ZMAX} ms at the worst step"
[ "${ZOVER:-0}" -gt 0 ] && fail "$ZOVER zoom steps blocked the main thread for a quarter second or more"
[ "${ZTILES:-0}" -lt 6 ] && fail "only ${ZTILES} tiles during the walk — the drag was riding a plate, not rendering"
[ "${PLANES:-0}" -gt "$PLANE_BUILDS" ] && fail "${PLANES} plane builds for one photo — crops are decoding again"
[ "$PEAK" -gt "$PEAK_MB" ] && fail "peak footprint ${PEAK} MB over ${PEAK_MB} MB"

[ "$STATUS" -eq 0 ] && echo "result      PASS"
exit "$STATUS"
