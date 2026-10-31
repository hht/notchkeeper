#!/bin/bash
# 把代码里的界面文案同步进 String Catalog（Resources/Localizable.xcstrings）：新文案加进来，删掉的标成 stale。
# 和 Xcode 一样靠编译器抽字符串（-emit-localized-strings），所以用单独的 scratch path，不动平时的构建。
# 跑完补 English 译文、删掉 stale 的键；swift test 的 LocalizationCoverage 会查。
# @see https://developer.apple.com/documentation/xcode/localizing-and-varying-text-with-a-string-catalog
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
# 抽字符串只在真正编译时发生：先清掉这个 scratch path 里 App 的产物
rm -rf .build/strings
swift build --product Notchkeeper --scratch-path .build/strings \
  -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$OUT"
xcrun xcstringstool sync Resources/Localizable.xcstrings --stringsdata "$OUT"/*.stringsdata
echo "==> 已同步 Resources/Localizable.xcstrings"
