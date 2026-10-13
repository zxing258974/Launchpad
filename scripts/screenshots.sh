#!/usr/bin/env bash
# 用演示模式(虚构 App、生成的图标和壁纸)截 README 配图,输出到 docs/screenshots/。
# 不读写真实的排列与设置;截图期间会暂停正在运行的启动台,结束后在后台重新启动它。
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=docs/screenshots
WIDTH=1600
APP=build/Launchpad.app

scripts/build-app.sh >/dev/null

WAS_RUNNING=false
if pgrep -x Launchpad >/dev/null; then
  WAS_RUNNING=true
  pkill -x Launchpad
  sleep 0.5
fi

cleanup() {
  pkill -f "Launchpad.app/Contents/MacOS/Launchpad --demo" 2>/dev/null || true
  defaults delete com.zhangxing.Launchpad.demo >/dev/null 2>&1 || true
  if $WAS_RUNNING; then open /Applications/Launchpad.app --args --background; fi
}
trap cleanup EXIT

rm -rf "$OUT"
mkdir -p "$OUT"
for scene in grid search folder settings; do
  open -n "$APP" --args --demo --demo-scene "$scene"
  # 等启动、展开动画全部落定(文件夹以图标为中心展开,没停稳就截会留一圈亮边)
  sleep 5
  pid="$(pgrep -nf "Launchpad.app/Contents/MacOS/Launchpad --demo")"
  if [[ "$scene" == settings ]]; then
    # 设置窗口带透明阴影,保留 PNG
    screencapture -x -l "$(swift scripts/window-id.swift "$pid" settings)" "$OUT/$scene.png"
  else
    # 全屏画面大半是渐变背景,PNG 太大,转 JPEG
    screencapture -x -o -t jpg -l "$(swift scripts/window-id.swift "$pid" overlay)" "$OUT/$scene.jpg"
    sips --resampleWidth "$WIDTH" -s formatOptions 85 "$OUT/$scene.jpg" >/dev/null
  fi
  kill "$pid"
  sleep 0.8
done
ls -l "$OUT"
