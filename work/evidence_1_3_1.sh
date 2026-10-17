#!/bin/bash
# 1.3.1 归档证据：跑**归档里那份 app 本体**（不是 dist），把三语言 + 两个新开关拍下来。
#
# 为什么跑归档那份而不是 dist：归档是用户实际会拿到的东西，证据要对着它。
# 为什么带 PICNIDO_INFO_PANE=0：把信息面板钉死，否则 PICNIDO_ROOTS 自动选中第一张会让面板
# 弹出来，工具行的宽度预算就不是这一张要说明的那一种了（见 CHANGELOG 1.3.1 坑 9）。
set -u
ARC="$HOME/Desktop/Picnido复刻/1.3.1"
BIN="$ARC/Picnido 1.3.1.app/Contents/MacOS/Picnido"
EV="$ARC/evidence"
LIB="${LIB:-$HOME/Pictures}"      # 换成你自己的照片目录
LOG="$EV/archive-run.log"
[ -x "$BIN" ] || { echo "no archived app"; exit 1; }
: > "$LOG"

shot() {   # $1=名字  $2=语言  其余=额外 env
  local name="$1" lang="$2"; shift 2
  PICNIDO_SCREEN=left PICNIDO_INFO_PANE=0 PICNIDO_LANG="$lang" \
  PICNIDO_ROOTS="$LIB" PICNIDO_SNAPSHOT="$EV/$name" PICNIDO_SNAPSHOT_DELAY=14 \
  PICNIDO_MENU_DUMP=1 env "$@" "$BIN" >> "$LOG" 2>&1 &
  local pid=$!
  sleep 20
  kill -TERM "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  echo "$name -> $(ls "$EV/${name}"_*.png 2>/dev/null | wc -l | tr -d ' ') png"
}

# 一个能同时看到两个新开关和胶片状态的尺寸
shot run-1400x900-zh-Hans zh-Hans
shot run-1400x900-ja ja
shot run-1400x900-ko ko
echo done
