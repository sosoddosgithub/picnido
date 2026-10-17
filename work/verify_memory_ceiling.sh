#!/bin/bash
#
# Does looking at pictures cost memory that never comes back?
#
# The bug this guards against: every `NSCache` in the image path was filled with
# `setObject(_:forKey:)`, which defaults the cost to zero — and an entry with zero cost is
# invisible to `totalCostLimit`. The only ceiling left was `countLimit` (20 000), so each photo
# opened left a viewer-sized bitmap behind for the life of the process. A user reported 80.49 GB
# resident after a few weeks of browsing; the synthetic run below, 60 photos at 3400x3400, walked
# to 2.4 GB and never gave a byte back.
#
# The rule: peak footprint over the run must stay under a fixed ceiling, and must not keep
# climbing while more photos are opened. Both halves matter — a count-limited cache can plateau
# at 2.4 GB, which the ceiling catches, and a per-photo leak keeps growing, which the trend
# catches.
#
# The fixture is deliberately large (26 to 38 MB uncompressed TIFFs): with a 1024-pixel JPEG the
# per-photo retention is a few hundred kilobytes and the bug hides inside normal noise.
#
# Usage:  [BIN=/path/to/Picnido] ./verify_memory_ceiling.sh [out_dir] [photos]
#         CEILING=800 ./verify_memory_ceiling.sh          # MB, default 1280
#
# Exit: 0 pass, 1 fail, 2 inconclusive (the hook never ran, or `footprint` is missing).
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
BIN="${BIN:-$ROOT/.build/release/Picnido}"
OUT="${1:-/tmp/picnido-mem}"
COUNT="${2:-60}"
CEILING="${CEILING:-1280}"
LIB="$OUT/lib"
GAP=250
STEPS=$((COUNT * 2))

[ -x "$BIN" ] || { echo "missing $BIN — build first"; exit 1; }
command -v footprint >/dev/null || { echo "missing /usr/bin/footprint"; exit 2; }

mkdir -p "$OUT" "$LIB"
HAVE=$(ls "$LIB"/*.tif 2>/dev/null | wc -l | tr -d ' ')
if [ "$HAVE" -lt "$COUNT" ]; then
  echo "==> fixture: generating $COUNT TIFFs in $LIB"
  python3 - "$LIB" "$COUNT" <<'PY' || { echo "fixture generation failed (needs PIL + numpy)"; exit 2; }
import sys, numpy as np
from PIL import Image
out, count = sys.argv[1], int(sys.argv[2])
rng = np.random.default_rng(7)
sizes = [3000, 3100, 3200, 3400, 3500, 3600]
for i in range(count):
    s = sizes[i % len(sizes)]
    # Low base noise plus three wide bands: enough structure to look like a photograph, and
    # nothing a TIFF encoder can compress, so the file size is the pixel size.
    base = rng.integers(0, 40, (s, s, 3), dtype=np.uint8)
    img = np.clip(base + rng.integers(0, 200, 3, dtype=np.uint8), 0, 255).astype(np.uint8)
    Image.fromarray(img, "RGB").save(f"{out}/MEM_{i:03d}.tif", compression="raw")
PY
fi

rm -rf "$OUT/index" "$OUT/thumbs"
mkdir -p "$OUT/index" "$OUT/thumbs"

echo "==> running $STEPS steps over $COUNT photos (${GAP} ms apart)"
PICNIDO_SCREEN=left \
PICNIDO_ROOTS="$LIB" \
PICNIDO_MIN_BYTES=0 \
PICNIDO_INDEX_DIR="$OUT/index" \
PICNIDO_THUMB_DIR="$OUT/thumbs" \
PICNIDO_VIEWER_STEP="$STEPS" \
PICNIDO_VIEWER_STEP_MS="$GAP" \
"$BIN" > "$OUT/run.log" 2>&1 &
APP=$!

trap 'kill -TERM "$APP" 2>/dev/null' EXIT

read_fp() {
  footprint -p "$APP" 2>/dev/null \
    | sed -n 's/.*Footprint: \([0-9][0-9]*\) MB.*/\1/p' | head -1
}

LOG_SAMPLES="$OUT/samples.txt"
: > "$LOG_SAMPLES"

# Three seconds is enough for the window to exist and the scan to be under way. Sampling starts
# here rather than after a fixed long sleep: a baseline taken *after* the steps have begun is not
# a baseline, it is the bug under test.
sleep 3
START=$(read_fp)
[ -n "${START:-}" ] && echo "$START" >> "$LOG_SAMPLES"

while kill -0 "$APP" 2>/dev/null; do
  FP=$(read_fp)
  [ -n "${FP:-}" ] && echo "$FP" >> "$LOG_SAMPLES"
  # The hook reports once, after the last step. Stopping there keeps the "end" number from being
  # a sample of the window being torn down.
  grep -q "viewerstep:" "$OUT/run.log" && break
  sleep 1
done

sleep 4
END=$(read_fp)
[ -n "${END:-}" ] && echo "$END" >> "$LOG_SAMPLES"

PEAK=$(sort -n "$LOG_SAMPLES" | tail -1)
N=$(wc -l < "$LOG_SAMPLES" | tr -d ' ')
THIRD=$(( N / 3 )); [ "$THIRD" -lt 1 ] && THIRD=1
EARLY=$(head -"$THIRD" "$LOG_SAMPLES" | sort -n | tail -1)
LATE=$(tail -"$THIRD" "$LOG_SAMPLES" | sort -n | tail -1)
TREND=$(( LATE - EARLY ))

kill -TERM "$APP" 2>/dev/null
wait "$APP" 2>/dev/null

if ! grep -q "viewerstep:" "$OUT/run.log"; then
  echo "INCONCLUSIVE: the viewer never stepped (see $OUT/run.log)"
  exit 2
fi

PER=$(( PEAK / COUNT ))
echo
echo "--- memory ceiling ---"
echo "photos      $COUNT  (3000-3600 px TIFF, 26-38 MB each)"
echo "steps       $STEPS"
echo "footprint   start ${START:-?} MB   peak $PEAK MB   end ${END:-?} MB   samples $N"
echo "trend       first third max ${EARLY:-?} MB -> last third max ${LATE:-?} MB"
echo "per photo   $PER MB of peak footprint per photo in the library"
echo "ceiling     $CEILING MB"

STATUS=0
if [ "$PEAK" -gt "$CEILING" ]; then
  echo "result      FAIL — peak $PEAK MB over ceiling $CEILING MB"
  STATUS=1
fi
if [ "$TREND" -gt 128 ]; then
  echo "result      FAIL — still climbing at the end (+$TREND MB between the first and last third)"
  STATUS=1
fi
[ "$STATUS" -eq 0 ] && echo "result      PASS"
exit "$STATUS"
