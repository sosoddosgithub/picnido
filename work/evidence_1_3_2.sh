#!/bin/bash
# 1.3.2 归档证据：跑**归档里那份 app 本体**（不是 dist），把查看器的新留白拍下来。
#
# 为什么跑归档那份而不是 dist：归档是用户实际会拿到的东西，证据要对着它。
# 为什么用真照片而不是夹具：这一版的问题就是"看着不顺眼"，夹具（纯色块 / 棋盘格）看不出观感；
# 用用户自己那张竖版照片，人一眼就能判断 24pt 够不够。
# 为什么每次都带 GEOM_REPORT=1：截图是给人看的，几何报告是给判据读的，两者要能对上。
set -u
ARC="$HOME/Desktop/Picnido复刻/1.3.2"
BIN="$ARC/Picnido 1.3.2.app/Contents/MacOS/Picnido"
EV="$ARC/evidence"
SRC="$HOME/Desktop/李书瑶 周岁宴照片/1、周岁宴照片"
PIX=/tmp/evidence132
LOG="$EV/archive-run.log"
PY=/usr/local/bin/python3

[ -x "$BIN" ] || { echo "no archived app at $BIN"; exit 1; }
mkdir -p "$EV" "$PIX/photos"
: > "$LOG"

# ---------------------------------------------------------------- fixture
# One real portrait photo, repeated. Picked by *display* size (EXIF applied), because
# `sips -g pixelWidth/pixelHeight` reports storage size and will pick the wrong photo —
# see CHANGELOG 1.3.2 「坑」.
"$PY" - "$SRC" "$PIX/photos" <<'PYX' || { echo "fixture failed"; exit 1; }
import sys, os, shutil
from PIL import Image
src, dst = sys.argv[1], sys.argv[2]
best = None
for root, _, files in os.walk(src):
    for f in sorted(files):
        if not f.lower().endswith((".jpg", ".jpeg", ".png")):
            continue
        p = os.path.join(root, f)
        try:
            with Image.open(p) as im:
                w, h = im.size
                if im.getexif().get(274, 1) in (5, 6, 7, 8):
                    w, h = h, w
        except Exception:
            continue
        if w > 0 and h > w * 1.2 and (best is None or h / w > best[1]):
            best = (p, h / w, w, h)
if best is None:
    sys.exit("no portrait photo found")
p, ratio, w, h = best
print(f"portrait: {os.path.basename(p)} shows {w}x{h} ({ratio:.2f}:1 vertical)")
shutil.copy2(p, os.path.join(dst, "a-portrait.jpg"))
for i in range(1, 15):
    shutil.copy2(p, os.path.join(dst, f"c{i:02d}.jpg"))
PYX
echo "fixture: $(ls "$PIX/photos" | wc -l | tr -d ' ') photos in $PIX/photos" | tee -a "$LOG"

# ---------------------------------------------------------------- runs
shot() {   # $1=名字
  local name="$1"; shift
  PICNIDO_SCREEN=left PICNIDO_MIN_BYTES=0 PICNIDO_INFO_PANE=0 \
  PICNIDO_ROOTS="$PIX/photos" PICNIDO_VIEW=1 PICNIDO_CHROME_PIN=1 \
  PICNIDO_GEOM_REPORT=1 PICNIDO_SNAPSHOT="$EV/$name" PICNIDO_SNAPSHOT_DELAY=4 \
  env "$@" "$BIN" >> "$LOG" 2>&1 &
  local pid=$!
  sleep 13
  kill -TERM "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  echo "$name -> $(ls "$EV/${name}"_*.png 2>/dev/null | wc -l | tr -d ' ') png" | tee -a "$LOG"
}

# The library window too: this version only touched the viewer, so a shot of the grid is the
# regression evidence for everything behind it.
lib_shot() {
  PICNIDO_SCREEN=left PICNIDO_MIN_BYTES=0 PICNIDO_INFO_PANE=0 PICNIDO_ROOTS="$PIX/photos" \
  PICNIDO_SNAPSHOT="$EV/library-zh" PICNIDO_SNAPSHOT_DELAY=4 \
  env "$@" "$BIN" >> "$LOG" 2>&1 &
  local pid=$!
  sleep 12
  kill -TERM "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  echo "library-zh -> $(ls "$EV"/library-zh_*.png 2>/dev/null | wc -l | tr -d ' ') png" | tee -a "$LOG"
}

shot viewer-tall-zh PICNIDO_LANG=zh-Hans
shot viewer-tall-ja PICNIDO_LANG=ja
shot viewer-tall-ko PICNIDO_LANG=ko
lib_shot PICNIDO_LANG=zh-Hans

# ---------------------------------------------------------------- the pixel cross-check
# Everything in the log above is the binary reporting on itself. This part reads the screen.
#
# The scan can only locate an edge it can see, so it needs the *frame* fixture — a black plate
# with a white border is the one thing whose edge survives the frosted backdrop as a bright
# pixel. Pointed at the real portrait above it happily reports the brightest thing inside the
# photo instead (386pt rather than 112pt), which is a true statement about the wrong object.
PROBE="${PROBE:-$HOME/WorkBuddy/2026-10-12-15-59-00/picnido-mac/work/probe}"
FRAMES="$PIX/frames"
mkdir -p "$FRAMES"
"$PY" - "$FRAMES" <<'PYX' 2>/dev/null || echo "no Pillow — pixel case skipped"
import sys
from PIL import Image, ImageDraw
out = sys.argv[1]
im = Image.new("RGB", (900, 1600), (0, 0, 0))
ImageDraw.Draw(im).rectangle([0, 0, 899, 1599], outline=(255, 255, 255), width=24)
im.save(out + "/a-frame.jpg", quality=97)
for i in range(1, 15):
    Image.open(out + "/a-frame.jpg").save(out + f"/f{i:02d}.jpg", quality=97)
PYX

if [ -f "$FRAMES/a-frame.jpg" ]; then
  PICNIDO_SCREEN=left PICNIDO_MIN_BYTES=0 PICNIDO_INFO_PANE=0 \
  PICNIDO_ROOTS="$FRAMES" PICNIDO_VIEW=1 PICNIDO_CHROME_PIN=1 \
  PICNIDO_GEOM_REPORT=1 PICNIDO_SNAPSHOT="$EV/viewer-frame" PICNIDO_SNAPSHOT_DELAY=4 \
  "$BIN" >> "$LOG" 2>&1 &
  pid=$!
  sleep 13
  kill -TERM "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  echo "viewer-frame -> $(ls "$EV"/viewer-frame_*.png 2>/dev/null | wc -l | tr -d ' ') png" | tee -a "$LOG"
fi

SNAP="$(ls -S "$EV"/viewer-frame_*_win.png 2>/dev/null | head -1)"
REAL="$(ls -S "$EV"/viewer-tall-zh_*_win.png 2>/dev/null | head -1)"
if [ -n "$SNAP" ] && [ -x "$PY" ] && [ -f "$PROBE/bandscan.py" ]; then
  {
    echo
    echo "=== independent pixel scan ==="
    echo "-- $(basename "$SNAP") (black plate + white frame: the scan can see these edges)"
    echo "   expected: photo top = topBand(88) + breath(24) = 112pt, bottom = 1038 - 24 = 1014pt"
    "$PY" "$PROBE/bandscan.py" chrome "$SNAP" 2
    "$PY" "$PROBE/bandscan.py" photo "$SNAP" 2 --lo=-1 --hi=200 --col 2048
    echo
    echo "-- $(basename "$REAL") (the real photo: only the chrome check is meaningful here)"
    "$PY" "$PROBE/bandscan.py" chrome "$REAL" 2
  } >> "$LOG" 2>&1
  echo "pixel scan appended" | tee -a "$LOG"
else
  echo "pixel scan skipped (no snapshot / no Pillow)" | tee -a "$LOG"
fi
echo done
