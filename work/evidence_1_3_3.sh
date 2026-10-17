#!/bin/bash
# 1.3.3 归档证据：查看器底部提示行的四语言对照 + 提示所声称的行为。
#
# 这一版只改了一句提示文字，所以证据也必须只对着这一句说话：
#
#   ① 表里是什么 —— 直接读 app 包里的 .lproj，证明四语言的文字是改过的那四条；
#   ② 屏幕上是什么 —— 四种语言各拍一张钉住 chrome 的查看器，提示行真的显示成那样；
#   ③ 说的和做的对不对 —— 提示说"点击照片外关闭"，那就**真的从窗口外发一次左键**
#      （work/probe/clickat，走 window server，与人的点击同一条路径），看查看器是不是
#      真的关掉；对照组点照片中心，查看器必须还在。
#
# ③ 是这一步的重点。上一版的毛病不是"文案难看"，而是**文案在描述一个不存在的图标**；
# 只把字换掉、不去证明新写的字是真的，等于换一种方式继续说谎。
#
# 用法：[APP=/path/to/Picnido.app] [EV=/out/dir] ./evidence_1_3_3.sh
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${APP:-$ROOT/dist/Picnido.app}"
BIN="$APP/Contents/MacOS/Picnido"
EV="${EV:-/tmp/evidence133}"
LIB="${LIB:-$HOME/WorkBuddy/2026-10-12-15-59-00/sample-library}"
PROBE="$ROOT/work/probe"
LOG="$EV/run.log"
PY="${PY:-/usr/local/bin/python3}"

[ -x "$BIN" ] || { echo "no app at $BIN"; exit 1; }
[ -d "$LIB" ] || { echo "no photo library at $LIB"; exit 1; }
mkdir -p "$EV"
: > "$LOG"

say() { echo "$@" | tee -a "$LOG"; }

# ---------------------------------------------------------------- ① static
say "=== app under test ==="
say "  $APP"
say "  version $(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null)"\
" (build $(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Contents/Info.plist" 2>/dev/null))"
say ""
say "=== ① the tables inside the bundle ==="
for l in zh-Hans ja ko; do
  say "  [$l] $(grep -A1 'Click outside the photo' "$APP/Contents/Resources/$l.lproj/Localizable.strings" | tail -1 | sed 's/^ *//')"
done
say "  [en] (no en.lproj — the literal in the code is the English table)"
say "  new key in the binary: $(strings "$APP/Contents/MacOS/Picnido" | grep -c 'Click outside the photo to close')"
say "  old key in the binary: $(strings "$APP/Contents/MacOS/Picnido" | grep -c 'Click the glass' || true)  (must be 0)"

# ---------------------------------------------------------------- ② shots
shot() {   # shot <name> [extra env…]
  local name="$1"; shift
  PICNIDO_SCREEN=left PICNIDO_MIN_BYTES=0 PICNIDO_INFO_PANE=0 \
  PICNIDO_ROOTS="$LIB" PICNIDO_VIEW=1 PICNIDO_CHROME_PIN=1 \
  PICNIDO_SNAPSHOT="$EV/$name" PICNIDO_SNAPSHOT_DELAY=4 \
  env "$@" "$BIN" >> "$LOG" 2>&1 &
  local pid=$!
  sleep 12
  kill -TERM "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  say "  $name -> $(ls -S "$EV/${name}"_*_win.png 2>/dev/null | head -1 | xargs -n1 basename 2>/dev/null || echo none)"
}

say ""
say "=== ② what the four interfaces actually show (chrome pinned) ==="
shot hint-en     PICNIDO_LANG=en
shot hint-zh     PICNIDO_LANG=zh-Hans
shot hint-ja     PICNIDO_LANG=ja
shot hint-ko     PICNIDO_LANG=ko

# ---------------------------------------------------------------- ③ behaviour
# Times the viewer window is on screen at 2048x1152 — the panel is built on `screen.frame`, so
# that size identifies it; the library window is 1680x1032 and alpha 0 in picture mode.
viewer_up() {
  "$PROBE/winlist" picnido 2>/dev/null \
    | awk -F'\t' '$4=="true" && $5 ~ /2048x1152/ {n++} END {print n+0}'
}

behaviour() {   # behaviour <name> <x> <y> <expect up|gone>   (x,y are window-local, top-left origin)
  local name="$1" x="$2" y="$3" expect="$4"
  local log="$EV/$name.log"; : > "$log"
  # The click is fired by the app itself (`PICNIDO_CLICK_TARGET=viewer`), 8s after its photo scan
  # settles; the two `viewer_up` reads straddle that moment.
  PICNIDO_SCREEN=left PICNIDO_MIN_BYTES=0 PICNIDO_INFO_PANE=0 \
  PICNIDO_ROOTS="$LIB" PICNIDO_VIEW=1 PICNIDO_CHROME_PIN=1 \
  PICNIDO_CLICK_TARGET=viewer PICNIDO_CLICK_DELAY=8 PICNIDO_CLICK="$x,$y" \
  PICNIDO_GEOM_REPORT=1 "$BIN" > "$log" 2>&1 &
  local pid=$!
  sleep 7
  local up1 up2 toggles
  up1="$(viewer_up)"
  sleep 6
  up2="$(viewer_up)"
  # Positive control. "the viewer is still there after a click in the middle" is satisfied just
  # as well by a click that never arrived, so the inside case also has to show that the panel
  # *processed* something: a single tap on the picture calls `onToggleChrome`, which reports.
  toggles="$(grep -c 'toggleChrome ->' "$log" || true)"

  local verdict="FAIL" want
  case "$expect" in
    gone) want=0 ;;
    up)   want=1 ;;
    *)    want=-1 ;;
  esac
  if [ "$up1" != "1" ]; then
    verdict="VOID"        # nothing on screen to click — the run proves nothing either way
  elif [ "$expect" = "gone" ]; then
    [ "$up2" = "0" ] && verdict="PASS"
  else
    [ "$up2" = "1" ] && [ "${toggles:-0}" -ge 1 ] && verdict="PASS"
  fi
  say "  $verdict  $name: viewer windows $up1 -> $up2 (want $want), toggleChrome seen ${toggles:-0}x — $(grep 'clicksheet: window=' "$log" | tail -1)"
  kill -TERM "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
}

say ""
say "=== ③ the hint's claim, checked against the same hit-testing the app uses ==="
say "  window-local points on the 2048x1152 panel (top-left origin):"
say "  (60, 576)   — at least (2048-1679)/2 = 184pt of backdrop to the left of any picture,"
say "                so this point is outside it for every photo shape"
say "  (1024, 576) — the window centre, inside every picture"
say "  The click is delivered by the app's own PICNIDO_CLICK hook rather than posted through the"
say "  window server: this machine has not granted the Accessibility permission, so"
say "  CGPreflightPostEventAccess() reads false and a posted leftMouseDown is dropped silently"
say "  (work/probe/clickat is the real-click tool, kept for a machine that has the permission)."
say "  The inside case also has to show a processed tap (a reported toggleChrome), or its PASS"
say "  would mean nothing — 'still open' is equally true of a click that never arrived."
behaviour outside-point   60 576 gone
behaviour inside-point  1024 576 up

# ---------------------------------------------------------------- crop
say ""
say "=== crop of the hint line ==="
if [ -x "$PY" ] && [ -f "$PROBE/zoom.py" ]; then
  for n in hint-en hint-zh hint-ja hint-ko; do
    SNAP="$(ls -S "$EV/${n}"_*_win.png 2>/dev/null | head -1)"
    [ -n "$SNAP" ] || continue
    # 2x window snapshot, so these are pixels: the status line rides directly above the 114pt
    # filmstrip and is *centred* in the window (it is a plain `HStack` inside a `VStack`, and a
    # `VStack` centres by default) — cropping the left edge gets you the backdrop and nothing
    # else. 1148..2948px straddles the window's mid-line at 2048 and covers every language.
    "$PY" "$PROBE/zoom.py" "$SNAP" "$EV/${n}-crop.png" 1148 1980 1800 120 1.6 >> "$LOG" 2>&1
    say "  ${n}-crop.png  $(ls -la "$EV/${n}-crop.png" 2>/dev/null | awk '{print $5" bytes"}')"
  done
else
  say "  skipped (no Pillow / no zoom.py)"
fi
say done
