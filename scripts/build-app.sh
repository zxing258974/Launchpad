#!/usr/bin/env bash
# 编译并组装 build/Launchpad.app(只需命令行工具,不需要 Xcode)。
# 用法:scripts/build-app.sh [--install]   --install 会装到 /Applications 并重启
set -euo pipefail
cd "$(dirname "$0")/.."

SIGN_IDENTITY="-"
[[ -f Config/local.env ]] && source Config/local.env
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/Launchpad"

APP=build/Launchpad.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Launchpad"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp -R Resources/zh-Hans.lproj Resources/en.lproj "$APP/Contents/Resources/"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

codesign --force --options runtime --timestamp=none --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict "$APP"
echo "已生成 $APP(签名:$SIGN_IDENTITY)"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x Launchpad 2>/dev/null && sleep 0.5 || true
  rm -rf /Applications/Launchpad.app
  cp -R "$APP" /Applications/
  open /Applications/Launchpad.app
  echo "已安装到 /Applications/Launchpad.app 并启动"
fi
