#!/bin/bash
# 界面语言普查：用 `PICNIDO_LANG=en` 跑一遍所有窗口/弹窗。
#
# 为什么用 en 当判据：源码里的英文字面量就是英文表（`CFBundleDevelopmentRegion=en`，没有
# `en.lproj`），所以 `localizedString(_:)` 在 en 下原样返回 key。于是 en 运行里
# **任何中文都是漏网的** —— 要么没进表，要么这条路径根本没读到选择器。这比逐个语言对图好判：
# 不需要认识日文韩文，只找「本不该出现的简体字」。
#
# 用法：./verify_language_sweep.sh [语言]   默认 en
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
BIN="$ROOT/dist/Picnido.app/Contents/MacOS/Picnido"
OUT="$ROOT/screenshots"
LIB="${LIB:-$HOME/Pictures}"      # 换成你自己的照片目录
LANG_="${1:-en}"
[ -x "$BIN" ] || { echo "no built app"; exit 1; }

shot() {   # $1=前缀  $2..=额外 env（VAR=VAL 形式，直接前置）
  local prefix="$1"; shift
  PICNIDO_SCREEN=left PICNIDO_WINDOW_SIZE=1400x900 PICNIDO_INFO_PANE=1 \
  PICNIDO_LANG="$LANG_" PICNIDO_ROOTS="$LIB" \
  PICNIDO_SNAPSHOT="$OUT/ls-$LANG_-$prefix" PICNIDO_SNAPSHOT_DELAY=12 \
  env "$@" "$BIN" > "/tmp/ls-$LANG_-$prefix.log" 2>&1 &
  local pid=$!
  sleep 17
  kill -TERM "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  echo "$prefix: $(ls "$OUT/ls-$LANG_-$prefix"_*.png 2>/dev/null | wc -l | tr -d ' ') png"
}

shot library
for S in export collage movie poster gallery backup print album scan rename date shortcuts duplicates; do
  shot "sheet-$S" PICNIDO_SHEET="$S"
done
shot settings-editing  PICNIDO_SHOW_SETTINGS=3 PICNIDO_SETTINGS_TAB=editing
shot settings-filetypes PICNIDO_SHOW_SETTINGS=3 PICNIDO_SETTINGS_TAB=fileTypes
shot viewer PICNIDO_VIEW=0
echo done
