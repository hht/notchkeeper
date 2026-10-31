#!/bin/bash
# 把代码里的界面文案同步进 String Catalog（Resources/Localizable.xcstrings）：新文案加进来，删掉的标成 stale。
# 和 Xcode 一样靠编译器抽字符串（-emit-localized-strings），所以用单独的 scratch path，不动平时的构建。
# 跑完补 English 译文、删掉 stale 的键；swift test 的 LocalizationCoverage 会查。
# --check：只看要不要同步，不改文件（catalog 里没有的新文案，LocalizationCoverage 看不见）
# @see https://developer.apple.com/documentation/xcode/localizing-and-varying-text-with-a-string-catalog
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
# 抽字符串只在真正编译时发生：先清掉这个 scratch path 里 App 的产物
rm -rf .build/strings
swift build --product Notchkeeper --scratch-path .build/strings \
  -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$OUT"
CATALOG=Resources/Localizable.xcstrings
if [[ "${1:-}" == --check ]]; then
  # 副本要同名：sync 按文件名（表名）对字符串，换了名字就全成了 stale。比内容不比字节：sync 会改排版
  mkdir "$OUT/check" && cp "$CATALOG" "$OUT/check/"
  xcrun xcstringstool sync "$OUT/check/Localizable.xcstrings" --stringsdata "$OUT"/*.stringsdata
  if ! python3 -c 'import json,sys; sys.exit(json.load(open(sys.argv[1])) != json.load(open(sys.argv[2])))' \
       "$CATALOG" "$OUT/check/Localizable.xcstrings"; then
    echo "==> $CATALOG 和代码对不上：跑 scripts/strings.sh 同步，再补英文、删 stale" >&2
    exit 1
  fi
  echo "==> $CATALOG 和代码一致"
  exit 0
fi
xcrun xcstringstool sync "$CATALOG" --stringsdata "$OUT"/*.stringsdata
echo "==> 已同步 $CATALOG"
