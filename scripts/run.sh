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
# Claude Code mod（docs/agent-integration.md「Notchkeeper mod」）：设置页安装时从这里拷出去。测试和 Claude Code 生成的类型声明不带
rsync -a --exclude tests --exclude types --exclude tsconfig.json ClaudeMod/ "$APP/Contents/Resources/ClaudeMod/"
# 终端插件（Resources/plugins/terminal）和它调的 nk：设置页安装时从这里拷出去
rsync -a Resources/plugins/ "$APP/Contents/Resources/plugins/"
# String Catalog：swift build 不编译 .xcstrings，在这里编进各语言的 .lproj（docs/ui.md「多语言」）
for catalog in Resources/*.xcstrings; do
  xcrun xcstringstool compile "$catalog" --output-directory "$APP/Contents/Resources"
done
cp "$(dirname "$BIN")/nk" "$APP/Contents/MacOS/nk"
echo "==> codesign (ad-hoc)"
# 包里另一个可执行文件要先签，再签整个包
codesign --force --sign - "$APP/Contents/MacOS/nk"
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
