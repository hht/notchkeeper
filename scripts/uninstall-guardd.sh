#!/bin/bash
# 撤销 scripts/install-guardd.sh：launchctl bootout → 删 plist 和二进制。
# 默认保留 guardd.log 和 guard-state.json；--purge 才一起删。永远不碰 App 的 config.json 和 notchkeeper.log。
# 安装时留下的备份（backup/ 目录）永远保留、不自动还原：里面只会是本脚本上一版装的 plist / guardd，
# 还原它等于重新装回旧版。要还原请手动 cp 回去再跑 launchctl bootstrap（见 docs/slice5-install.md §3）。
# 不要 root、不用 sudo；以 root 运行直接拒绝。--dry-run 只打印每一步。
# 不碰：Clash、网络设置、DNS、路由、pf、~/.zshrc、任何 LaunchDaemon。
set -euo pipefail

usage() { echo "用法: $0 [--dry-run] [--purge]" >&2; exit 64; }
DRY_RUN=0
PURGE=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --purge) PURGE=1 ;;
    *) usage ;;
  esac
done
if [ "$(id -u)" -eq 0 ]; then
  echo "拒绝以 root 运行：guardd 是每用户 LaunchAgent，请用普通用户身份运行（不要 sudo）" >&2
  exit 1
fi

LABEL="com.notchkeeper.guardd"
DOMAIN="gui/$(id -u)"
SUPPORT="$HOME/Library/Application Support/Notchkeeper"
BIN_DIR="$SUPPORT/bin"
LOG="$HOME/Library/Logs/Notchkeeper/guardd.log" # 同目录还有 App 的 notchkeeper.log，不删目录
STATE="$SUPPORT/guard-state.json"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

run() {
  printf '+'; printf ' %q' "$@"; printf '\n'
  if [ "$DRY_RUN" -eq 0 ]; then "$@"; fi
}

[ "$DRY_RUN" -eq 1 ] && echo "== dry-run：只打印，不改任何东西"
# 先停进程再删文件；等它从域里消失，免得 --purge 删完状态文件后最后一轮又写回来
if [ "$DRY_RUN" -eq 1 ]; then
  echo "+ （如果已加载）launchctl bootout ${DOMAIN}/${LABEL}，并等它退出（最多 10 秒）"
elif launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
  run launchctl bootout "$DOMAIN/$LABEL" || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || break
    sleep 1
  done
  if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
    echo "卸载中止：${LABEL} 10 秒内没退出，什么文件都没删" >&2
    exit 1
  fi
fi
run rm -f "$PLIST"
run rm -f "$BIN_DIR/guardd"
if [ "$DRY_RUN" -eq 1 ]; then
  echo "+ （如果空了）rmdir $BIN_DIR"
else
  rmdir "$BIN_DIR" 2>/dev/null || true
fi
if [ "$PURGE" -eq 1 ]; then
  run rm -f "$LOG"
  run rm -f "$STATE"
fi
echo "== 保留：安装备份（${SUPPORT}/backup）$([ "$PURGE" -eq 1 ] || echo "、日志、状态文件")"
