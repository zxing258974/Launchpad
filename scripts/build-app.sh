#!/usr/bin/env bash
# 编译并组装 build/Launchpad.app(只需命令行工具,不需要 Xcode)。
# 用法:scripts/build-app.sh [--universal] [--install]
#   --universal  同时编 Apple 芯片与 Intel,合成通用二进制(发布用)
#   --install    装到 /Applications 并启动
# 签名身份取 Config/local.env 的 SIGN_IDENTITY;环境变量 SIGN_IDENTITY 优先,- 表示 ad-hoc。
set -euo pipefail
cd "$(dirname "$0")/.."

UNIVERSAL=false
INSTALL=false
for arg in "$@"; do
  case "$arg" in
    --universal) UNIVERSAL=true ;;
    --install) INSTALL=true ;;
    *) echo "未知参数:$arg" >&2; exit 2 ;;
  esac
done

OVERRIDE="${SIGN_IDENTITY:-}"
SIGN_IDENTITY="-"
[[ -f Config/local.env ]] && source Config/local.env
SIGN_IDENTITY="${OVERRIDE:-${SIGN_IDENTITY:--}}"

APP=build/Launchpad.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

if $UNIVERSAL; then
  # swift build 一次编多架构要 Xcode 的 xcbuild,这里分别编再用 lipo 合并
  slices=()
  for arch in arm64 x86_64; do
    swift build -c release --triple "$arch-apple-macosx14.0"
    slices+=(".build/$arch-apple-macosx/release/Launchpad")
  done
  lipo -create "${slices[@]}" -output "$APP/Contents/MacOS/Launchpad"
else
  swift build -c release --arch arm64
  cp "$(swift build -c release --arch arm64 --show-bin-path)/Launchpad" "$APP/Contents/MacOS/Launchpad"
fi

cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp -R Resources/zh-Hans.lproj Resources/en.lproj "$APP/Contents/Resources/"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

codesign --force --options runtime --timestamp=none --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict "$APP"
echo "已生成 $APP(签名:$SIGN_IDENTITY,架构:$(lipo -archs "$APP/Contents/MacOS/Launchpad"))"

if $INSTALL; then
  pkill -x Launchpad 2>/dev/null && sleep 0.5 || true
  rm -rf /Applications/Launchpad.app
  cp -R "$APP" /Applications/
  open /Applications/Launchpad.app
  echo "已安装到 /Applications/Launchpad.app 并启动"
fi
