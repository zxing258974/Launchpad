#!/usr/bin/env bash
# 打发布包:通用二进制、ad-hoc 签名,输出 dist/ 下的 dmg、zip 和 SHA256SUMS.txt。
# 不用个人开发证书签名(证书名里带 Apple ID 邮箱);开发证书本来也无法公证,
# 所以用户首次打开都要在「隐私与安全性」里点「仍要打开」,两种签法对用户没有区别。
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
NAME="Launchpad-$VERSION"

SIGN_IDENTITY=- scripts/build-app.sh --universal

rm -rf dist
mkdir -p dist
ditto -c -k --keepParent build/Launchpad.app "dist/$NAME.zip"

# dmg 里放一个「应用程序」快捷方式,打开后直接拖进去即可安装
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R build/Launchpad.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "启动台 $VERSION" -srcfolder "$STAGE" -ov -format UDZO "dist/$NAME.dmg"

(cd dist && shasum -a 256 "$NAME.dmg" "$NAME.zip" > SHA256SUMS.txt)
cat dist/SHA256SUMS.txt
