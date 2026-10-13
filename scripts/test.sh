#!/usr/bin/env bash
# 只装了命令行工具(无 Xcode)时,Swift Testing 框架不在默认搜索路径,这里显式补上。
# 用法:scripts/test.sh [--coverage] [swift test 其余参数]
set -euo pipefail
cd "$(dirname "$0")/.."
DEV="$(xcode-select -p)"
FW="$DEV/Library/Developer/Frameworks"
LIB="$DEV/Library/Developer/usr/lib"
EXTRA=()
if [[ "${1:-}" == "--coverage" ]]; then EXTRA+=(--enable-code-coverage); shift; fi
exec swift test ${EXTRA[@]+"${EXTRA[@]}"} \
  -Xswiftc -F"$FW" -Xlinker -F"$FW" \
  -Xlinker -rpath -Xlinker "$FW" -Xlinker -rpath -Xlinker "$LIB" "$@"
