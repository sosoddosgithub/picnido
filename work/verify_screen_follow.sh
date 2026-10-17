#!/bin/bash
# 验证「图片在哪块屏被打开，就在哪块屏显示」。
#
# 判据全部取自进程之外：
#   - 打开动作由 work/probe/openfrom.swift 触发 —— 它把真实光标移到指定屏幕，再让
#     LaunchServices 送一次和双击等价的 open 事件；
#   - 落屏由 work/probe/viewscreen.swift 读取 —— 窗口几何来自窗口服务器，不是程序自述。
#
# 两块屏（本机）：LEFT = DELL U2719D（x -2048..0），RIGHT = DELL U2722DX（x 0..2048，主屏）。

set -u
ROOT="$HOME/WorkBuddy/2026-10-12-15-59-00"
NEW="$ROOT/picnido-mac/dist/Picnido.app"
# 1.2.0 是改名之前的版本，文件名里带的是当时的产品名，不是笔误。只用于最后一段
# 「旧 bug 还重现吗」的对照；那个包早就不在桌面上了，缺失时该段直接跳过。
OLD="${OLD:-$HOME/Desktop/1.2.0/Picasa 1.2.0.app}"
LIB="$ROOT/sample-library"
HOOK=/tmp/picnido-hook
LOG=/tmp/picnido-screen-test.log

pass=0; fail=0

reset() {
    pkill -TERM -f "MacOS/Picnido" 2>/dev/null
    sleep 2
    mkdir -p "$HOOK"
    echo "$LOG" > "$HOOK/PICNIDO_REPORT_FILE"
    : > "$LOG"
    rm -f /tmp/picnido-stderr.log
}

# cold <app> <image> <screen>   — 冷启动（LaunchServices 送文件，等价于双击）
cold() {
    /tmp/openfrom "$1" "$2" "$3" >/dev/null 2>&1
    sleep 4
}

# warm <app> <image> <screen>   — 同一实例再打开一张
warm() {
    /tmp/openfrom "$1" "$2" "$3" >/dev/null 2>&1
    sleep 4
}

viewer_display() { /tmp/viewscreen 2>/dev/null | grep -o 'VIEWER_DISPLAY=[A-Z?]*' | cut -d= -f2; }

check() {
    local name="$1" want="$2"
    local got; got=$(viewer_display)
    if [ "$got" = "$want" ]; then
        printf '  \033[32m✓\033[0m %-46s 查看器 = %s\n' "$name" "$got"; pass=$((pass+1))
    else
        printf '  \033[31m✗\033[0m %-46s 查看器 = %s  (期望 %s)\n' "$name" "$got" "$want"; fail=$((fail+1))
    fi
}

echo "================ 1.2.1：跟随「打开来源」那块屏 ================"

echo
echo "T1  冷启动 · 光标在右屏 · 从右屏打开"
reset; cold "$NEW" "$LIB/photo_05.jpg" right
check "图片来自右屏 -> 右屏显示" RIGHT
grep -m1 "open origin" "$LOG" | sed 's/^/       /'

echo
echo "T2  实例已在右屏 · 光标移到左屏 · 再开一张"
warm "$NEW" "$LIB/photo_06.jpg" left
check "图片来自左屏 -> 跨屏搬到左屏" LEFT
grep -m1 "moving to" "$LOG" | sed 's/^/       /'

echo
echo "T3  仍在左屏 · 光标留在左屏 · 再开一张（不该抖）"
: > "$LOG"
warm "$NEW" "$LIB/photo_07.jpg" left
check "同屏重复打开 -> 保持不动" LEFT
if grep -q "moving to" "$LOG"; then
    echo "       ✗ 不应有移动动作"; fail=$((fail+1))
else
    echo "       ✓ 没有触发搬屏（无 moving 记录）"; pass=$((pass+1))
fi

echo
echo "T4  冷启动 · 光标在左屏"
reset; cold "$NEW" "$LIB/photo_08.jpg" left
check "图片来自左屏 -> 左屏显示" LEFT

echo
echo "================ 回归：程序内打开不该看光标 ================"

echo
echo "T5  图库窗口在左屏 · 光标停在右屏 · 从图库打开（PICNIDO_VIEW）"
reset
/tmp/openfrom - - right >/dev/null 2>&1
PICNIDO_VIEW=1 "$NEW/Contents/MacOS/Picnido" >/tmp/picnido-stderr.log 2>&1 &
sleep 8
LIBPOS=$(/tmp/viewscreen 2>/dev/null | grep -o 'window .* 1060x708  ->  [A-Z]*' | head -1 | grep -o '[A-Z]*$')
echo "       库窗口在：$LIBPOS"
check "程序内打开 -> 跟库窗口，不被光标带走" "$LIBPOS"
if grep -q "open origin dropped" "$LOG"; then
    echo "       ✓ 日志确认丢弃了光标来源"; pass=$((pass+1))
else
    echo "       （未记录 dropped —— 可能本轮没有残留值）"
fi

echo
echo "================ 对照：1.2.0 的旧行为（应重现 bug）================"

echo
echo "T6  1.2.0 · 冷启动 · 光标在右屏 · 从右屏打开"
if [ ! -d "$OLD" ]; then
    printf '  \033[33m-\033[0m %-46s 未安装，跳过\n' "1.2.0 对照包"
    OLD=""
fi

[ -n "$OLD" ] || { echo "       （跳过 1.2.0 对照）"; OLDGOT="skip"; LIBPOS="skip"; }
[ -n "$OLD" ] && { reset; cold "$OLD" "$LIB/photo_05.jpg" right; OLDGOT=$(viewer_display); }
LIBPOS=$(/tmp/viewscreen 2>/dev/null | grep -o 'window .* 1060x708  ->  [A-Z]*' | head -1 | grep -o '[A-Z]*$')
echo "       旧版库窗口在：$LIBPOS"
if [ "$OLDGOT" = "LEFT" ] && [ "$LIBPOS" = "LEFT" ]; then
    printf '  \033[33m●\033[0m %-46s 查看器 = %s（跟库窗口，非光标）—— 旧 bug 重现\n' "同一操作在 1.2.0 上" "$OLDGOT"; pass=$((pass+1))
else
    printf '  \033[33m?\033[0m %-46s 查看器 = %s 库窗口 = %s（未能干净重现）\n' "同一操作在 1.2.0 上" "$OLDGOT" "$LIBPOS"
fi

echo
echo "================ 收尾 ================"
reset
echo "结果：$pass 通过 / $fail 失败"
exit $fail
