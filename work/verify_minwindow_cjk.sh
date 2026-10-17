#!/bin/bash
# 1.3.1 发版前必做：最小窗口 1060×680 下的 CJK 版面复验。
#
# 为什么要这一条：工具行（`Dates … Sort … 两个新开关 … 放大滑块`）是英文最短、
# CJK 最长。中文/日文/韩文下如果挤破行，只有最小宽度才看得出来。这一版工具行
# 又新加了「瀑布流」和「显示文件夹路径」两个开关，所以必须重验。
#
# 判据：程序自绘快照（`CGWindowListCreateImage` 抓本进程自己的窗口，不需要任何权限）；
#       窗口位置由 PICNIDO_SCREEN=left 钉在左屏（用户要求调试都在左显示器）。
#       语言由 PICNIDO_LANG 强制，不依赖已存偏好。
#
# 注意：应用不会自己退出（PICNIDO_SNAPSHOT 只截图），必须 sleep 后 kill。

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
BIN="$ROOT/dist/Picnido.app/Contents/MacOS/Picnido"
OUT="$ROOT/screenshots"
LIB="${LIB:-$HOME/Pictures}"      # 换成你自己的照片目录
[ -x "$BIN" ] || { echo "no built app at $BIN"; exit 1; }
[ -d "$LIB" ] || { echo "no sample library at $LIB"; exit 1; }

mkdir -p "$OUT"
# PICNIDO_INFO_PANE=0 pins the information pane shut: it costs 268 of the 1060 points, and the
# width budget for the toolbar row is completely different with and without it. First argument of
# the script selects the state so both can be measured — `./verify_minwindow_cjk.sh 1` is the
# over-subscribed case.
PANE="${1:-0}"
for L in en zh-Hans ja ko; do
  PREFIX="$OUT/mw$PANE-$L"
  LOG="/tmp/mw$PANE-$L.log"
  echo "=== $L (info pane ${PANE}) ==="
  PICNIDO_SCREEN=left \
  PICNIDO_WINDOW_SIZE=1060x680 \
  PICNIDO_INFO_PANE="$PANE" \
  PICNIDO_LANG="$L" \
  PICNIDO_ROOTS="$LIB" \
  PICNIDO_SNAPSHOT="$PREFIX" \
  PICNIDO_SNAPSHOT_DELAY=18 \
    "$BIN" > "$LOG" 2>&1 &
  PID=$!
  sleep 26
  kill -TERM "$PID" 2>/dev/null
  wait "$PID" 2>/dev/null
  grep -E "\[screen\]|\[roots\]" "$LOG" | head -3
  ls "${PREFIX}"_*.png 2>/dev/null
done
echo "done"
