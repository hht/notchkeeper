#!/bin/bash
# 把 guardd 装成当前用户的 LaunchAgent：检查前提 → 编译 release → 备份旧文件 → 拷二进制 → 写 plist → launchctl bootstrap。
# 不要 root、不用 sudo、不弹管理员密码框；以 root 运行直接拒绝。--dry-run 只打印每一步和将写入的 plist 原文，什么都不做。
# 不碰：Clash、网络设置、DNS、路由、pf（不调 pfctl、不加 anchor）、~/.zshrc、config.json、任何 LaunchDaemon。
# 可以重复跑：已加载就先 bootout，再换二进制和 plist；被覆盖的旧文件都先带时间戳备份。
# 撤销：scripts/uninstall-guardd.sh。说明见 docs/slice5-install.md。
set -euo pipefail

usage() { echo "用法: $0 [--dry-run]" >&2; exit 64; }
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    *) usage ;;
  esac
done
if [ "$(id -u)" -eq 0 ]; then
  echo "拒绝以 root 运行：guardd 是每用户 LaunchAgent，请用普通用户身份运行（不要 sudo）" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LABEL="com.notchkeeper.guardd"
DOMAIN="gui/$(id -u)"
SUPPORT="$HOME/Library/Application Support/Notchkeeper"
BIN_DIR="$SUPPORT/bin"
BIN="$BIN_DIR/guardd"
BACKUP_DIR="$SUPPORT/backup"
LOG_DIR="$HOME/Library/Logs/Notchkeeper"
LOG="$LOG_DIR/guardd.log"
AGENTS="$HOME/Library/LaunchAgents"
PLIST="$AGENTS/$LABEL.plist"
TEMPLATE="$ROOT/Resources/guardd/$LABEL.plist"
BUILT="$ROOT/.build/release/guardd"
STAMP="$(date +%Y%m%d-%H%M%S)"

die() { echo "安装中止：$1" >&2; exit 1; }

# 打印一步，dry-run 时只打印
run() {
  printf '+'; printf ' %q' "$@"; printf '\n'
  if [ "$DRY_RUN" -eq 0 ]; then "$@"; fi
}

# 前提不全就什么都不做。只用 command -v 查工具在不在，不调用它们（dry-run 也查）
[ "$(uname -s)" = "Darwin" ] || die "只支持 macOS"
[ -f "$TEMPLATE" ] || die "找不到 plist 模板 ${TEMPLATE}"
for tool in swift launchctl plutil; do
  command -v "$tool" >/dev/null 2>&1 || die "找不到 ${tool}"
done
if [ "$DRY_RUN" -eq 0 ] && ! launchctl print "$DOMAIN" >/dev/null 2>&1; then
  die "没有 ${DOMAIN} 域：请在 Haitao 已登录的图形会话里的终端运行（不要用 ssh / sudo）"
fi

xml_escape() { local s="${1//&/&amp;}"; s="${s//</&lt;}"; printf '%s' "${s//>/&gt;}"; }

# 替换串里的 & 在 bash 5.2+ 默认代表匹配到的文本，关掉；macOS 自带的 bash 3.2 没有这个选项
shopt -u patsub_replacement 2>/dev/null || true
BIN_XML="$(xml_escape "$BIN")"
LOG_XML="$(xml_escape "$LOG")"
CONTENT="$(<"$TEMPLATE")"
CONTENT="${CONTENT//__GUARDD_PATH__/$BIN_XML}"
CONTENT="${CONTENT//__LOG_PATH__/$LOG_XML}"
# 渲染结果先校验（plutil 读 stdin，不写任何文件）；dry-run 也校验
printf '%s\n' "$CONTENT" | plutil -lint - >/dev/null || die "渲染出的 plist 不合法"

[ "$DRY_RUN" -eq 1 ] && echo "== dry-run：只打印，不改任何东西"
run swift build -c release --product guardd --package-path "$ROOT"
if [ "$DRY_RUN" -eq 0 ] && [ ! -x "$BUILT" ]; then die "编译后没有 ${BUILT}"; fi
run mkdir -p "$BIN_DIR" "$LOG_DIR" "$AGENTS"

# 会被覆盖的旧文件先带时间戳备份（只有已存在时才有这一步）
if [ -e "$PLIST" ] || [ -e "$BIN" ]; then run mkdir -p "$BACKUP_DIR"; fi
if [ -e "$PLIST" ]; then run cp -p "$PLIST" "$BACKUP_DIR/$LABEL.plist.$STAMP"; fi
if [ -e "$BIN" ]; then run cp -p "$BIN" "$BACKUP_DIR/guardd.$STAMP"; fi

# 已加载就先停掉，等它真的从域里消失，再换二进制和 plist（紧接着 bootstrap 会报 5: Input/output error）
if [ "$DRY_RUN" -eq 1 ]; then
  echo "+ （如果已加载）launchctl bootout ${DOMAIN}/${LABEL}，并等它退出（最多 10 秒）"
elif launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
  run launchctl bootout "$DOMAIN/$LABEL" || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || break
    sleep 1
  done
  if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then die "旧的 $LABEL 10 秒内没退出，没有换文件"; fi
fi

run cp "$BUILT" "$BIN.new"
run chmod 755 "$BIN.new"
run mv -f "$BIN.new" "$BIN"

echo "+ 写入 ${PLIST}（0644）："
echo "----- plist -----"
printf '%s\n' "$CONTENT"
echo "----- end plist -----"
if [ "$DRY_RUN" -eq 0 ]; then
  printf '%s\n' "$CONTENT" > "$PLIST.new"
  plutil -lint "$PLIST.new" >/dev/null
  chmod 644 "$PLIST.new"
  mv -f "$PLIST.new" "$PLIST"
fi

run launchctl bootstrap "$DOMAIN" "$PLIST"

echo "== 完成后检查：launchctl print $DOMAIN/$LABEL ；tail -f \"$LOG\""
