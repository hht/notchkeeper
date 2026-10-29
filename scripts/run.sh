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
pkill -x Notchkeeper 2>/dev/null || true
# 等旧实例真正退出（每 0.1s 查一次，最多 5s），新实例的单实例检查才不会因为它还在而退出
for _ in $(seq 50); do
  pgrep -x Notchkeeper >/dev/null || break
  sleep 0.1
done
if pgrep -x Notchkeeper >/dev/null; then
  echo "run.sh: 警告：旧的 Notchkeeper 5 秒后仍未退出，照常启动新实例" >&2
fi
open "$APP"
echo "==> launched $(pwd)/$APP"
