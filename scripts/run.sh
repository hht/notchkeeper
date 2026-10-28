#!/bin/bash
# 编译 → 打包 Notchkeeper.app → 本机临时签名 (ad-hoc) → 启动
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${CONFIG:-release}"
echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Notchkeeper"
APP="build/Notchkeeper.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Notchkeeper"
cp Support/Info.plist "$APP/Contents/Info.plist"
echo "==> codesign (ad-hoc)"
codesign --force --sign - --identifier local.hht.notchkeeper "$APP"
pkill -x Notchkeeper 2>/dev/null && sleep 0.6 || true
open "$APP"
echo "==> launched $(pwd)/$APP"
