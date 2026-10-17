#!/bin/bash
# 1.3.1 发版前：长文案 Sheet 的三语言复验。
#
# 为什么单独跑：`DuplicatesSheet` 的空态与 `ScanFoldersSheet` 的概览这一轮改了代码
# （空态那句由 `+` 拼接压成单条字面量、状态改走 `StatusNote`、枚举 ForEach 补查表），
# 但一直没截图看过 —— 属于「应该对但没看见」。文案最长的两个 Sheet 就是这两处。
#
# 两个 sheet 不能同时弹（同一个视图上挂两个 `.sheet`，第二个不会出现），所以分开跑。
# 语言由 PICNIDO_LANG 强制；窗口钉在左屏。

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
BIN="$ROOT/dist/Picnido.app/Contents/MacOS/Picnido"
OUT="$ROOT/screenshots"
LIB="${LIB:-$HOME/Pictures}"      # 换成你自己的照片目录
[ -x "$BIN" ] || { echo "no built app"; exit 1; }

run() {          # $1=prefix  $2=lang  $3..=extra env
  local prefix="$1" lang="$2"; shift 2
  PICNIDO_SCREEN=left PICNIDO_WINDOW_SIZE=1400x900 PICNIDO_INFO_PANE=0 \
  PICNIDO_LANG="$lang" PICNIDO_ROOTS="$LIB" \
  PICNIDO_SNAPSHOT="$OUT/$prefix" PICNIDO_SNAPSHOT_DELAY=14 \
  "$@" "$BIN" > "/tmp/$prefix.log" 2>&1 &
  local pid=$!
  sleep 22
  kill -TERM "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  ls "$OUT/${prefix}"_*.png 2>/dev/null
}

for L in zh-Hans ja ko; do
  echo "=== duplicates / $L ==="
  run "sheet-dup-$L" "$L" env PICNIDO_SHOW_DUPLICATES=4
done

for L in zh-Hans ja ko; do
  echo "=== scan folders / $L ==="
  run "sheet-scan-$L" "$L" env PICNIDO_SCAN=1
done
echo done
