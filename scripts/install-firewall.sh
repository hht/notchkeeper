#!/bin/bash
# 安装防火墙（docs/firewall.md §4「特权部分」）：辅助程序、LaunchDaemon、它们的目录。装完是 off，什么都不拦；开启要另外 sudo … enable。
# 用法：
#   scripts/install-firewall.sh --test-rules --test-address <IPv4> [--tunnel <网卡名>] --dry-run   不要 root：编译，只打印会装什么
#   sudo scripts/install-firewall.sh --test-rules --test-address <IPv4> [--tunnel <网卡名>]        编译，打印同样的内容，输入 yes 才装
# 编译总是用普通用户（root 编译会在仓库里留下 root 的文件）：sudo 运行时降回调用 sudo 的那个用户。
# 现在只装测试规则（block 只拦去测试地址的流量，测试时不真的断网，§7）；正式规则等用户拍板后再开放。
# 测试地址写进测试表 test.table，要选一个境外、不在 Clash 节点里的地址（在国内段或 <clash> 里就会被先放行，测不出拦截）。
# 已经装了任何防火墙文件时拒绝运行：不覆盖，也就没有要备份的。升级先跑 sudo scripts/firewall-rescue.sh 再装。
# 不碰：/etc/pf.conf、别人的 anchor 和 token、Clash、网络设置、sudoers、任何进程；pfctl 只用 -n 检查语法，不改 pf。
# 撤销：sudo scripts/firewall-rescue.sh。路径和名字必须和 firewall-rescue.sh 一致（RescueScriptTests 逐行比）。
# 整个脚本包在花括号里：bash 先读完整个文件再执行，root 跑到一半时脚本文件被改也不影响这一次
{
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

LABEL="com.notchkeeper.firewall"
ANCHOR="com.apple/300.Notchkeeper"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"
HELPER="/Library/PrivilegedHelperTools/notchkeeper-firewall"
SUPPORT="/Library/Application Support/Notchkeeper"
STATE="${SUPPORT}/firewall.state"
# 辅助程序还会写锁文件、两张放行表和它们固定名字的临时文件（写到一半崩了才会留下）；测试表是安装脚本写的
FILES=("${PLIST}" "${HELPER}" "${STATE}" "${SUPPORT}/firewall-status.json" "${SUPPORT}/firewall.pf" "${SUPPORT}/firewall.lock"
  "${SUPPORT}/.firewall.state.tmp" "${SUPPORT}/.firewall-status.json.tmp" "${SUPPORT}/clash.table" "${SUPPORT}/cn.table"
  "${SUPPORT}/.clash.table.tmp" "${SUPPORT}/.cn.table.tmp" "${SUPPORT}/test.table")
REPO="$(cd "$(dirname "$0")/.." && pwd)"
BUILT="${REPO}/.build/release/firewalld"
RESCUE="${REPO}/scripts/firewall-rescue.sh"

usage() { echo "用法: sudo $0 --test-rules --test-address <IPv4> [--tunnel <网卡名>]  或  加 --dry-run 只打印" >&2; exit 64; }
die() { echo "安装中止：$1" >&2; exit 1; }
ARGS="$*"
DRY_RUN=0
TEST_RULES=0
TEST_ADDRESS=""
TUNNEL="utun1024"
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --test-rules) TEST_RULES=1 ;;
    --test-address) [ $# -ge 2 ] || usage; TEST_ADDRESS="$2"; shift ;;
    --tunnel) [ $# -ge 2 ] || usage; TUNNEL="$2"; shift ;;
    *) usage ;;
  esac
  shift
done
[ "${TEST_RULES}" -eq 1 ] || die "现在只能装测试规则，要加 --test-rules（正式规则等用户拍板）"
[[ "${TEST_ADDRESS}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || die "要用 --test-address 给一个 IPv4 测试地址"
if [ "${DRY_RUN}" -eq 0 ] && [ "$(id -u)" -ne 0 ]; then
  echo "要用 root 运行：sudo $0 ${ARGS}；先看会装什么：$0 ${ARGS} --dry-run" >&2
  exit 1
fi

# 仓库和编译目录普通用户写得了：编译、读二进制、跑 rules 都降回调用 sudo 的那个用户。
# 在输入 yes 之前，root 不执行、不跟随（符号链接）任何普通用户写得了的东西（脚本本身见开头的花括号）；编译也不在仓库里留下 root 的文件
if [ "$(id -u)" -eq 0 ]; then
  { [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; } || die "要从普通用户用 sudo 运行：编译和读仓库要降回那个用户"
  as_user() { sudo -u "${SUDO_USER}" -H "$@"; }
else
  as_user() { "$@"; }
fi

# 每次都编译，不比文件时间：内容没变时 swift build 不重新链接，二进制的时间不会更新。
# 先进仓库：swift build 要读得出当前目录，调用 sudo 时所在的目录那个用户不一定进得去
echo "== 编译 firewalld（release）"
cd "${REPO}"
as_user swift build -c release --product firewalld --package-path "${REPO}" || die "编译失败"

# 读一份快照进只有自己能写的临时目录：给人看的哈希、规则和最后装上的，都是这一份，编译目录里的文件之后再被换掉也无关。
# 放在有粘滞位的 /private/tmp：$TMPDIR 可能是用户目录，用户能把 root 建的临时目录整个换掉。
# 目录 0711、快照 0755：调用的用户能执行快照（跑 rules），改不了它
SNAPSHOT_DIR="$(mktemp -d /private/tmp/notchkeeper-firewall-install.XXXXXX)"
trap 'rm -rf "${SNAPSHOT_DIR}"' EXIT
chmod 0711 "${SNAPSHOT_DIR}"
SNAPSHOT="${SNAPSHOT_DIR}/notchkeeper-firewall"
as_user cat "${BUILT}" > "${SNAPSHOT}" || die "读不了 ${BUILT}"
chmod 0755 "${SNAPSHOT}"
rc=0
RULES="$(as_user "${SNAPSHOT}" rules --tunnel "${TUNNEL}" --test-rules)" || rc=$?
case "${rc}" in
  0) ;;
  64) die "网卡名不合法：${TUNNEL}" ;;
  *) die "辅助程序跑不起来（退出码 ${rc}）" ;;
esac

# 网卡名已被辅助程序校验过（只有字母和数字），直接放进 XML 是安全的。
# 没有 StartInterval：辅助程序自己在 trial / on 时每 10 秒跑一轮，回到 off 就正常退出，off 时不轮询（docs/firewall.md §2）。
# KeepAlive 只在非正常退出（崩溃、被杀）时拉起，试运行照样到期回滚；正常退出不拉起。
# ThrottleInterval 1：launchd 默认同一个服务 10 秒内只启动一次，开启 / 保留 / 关闭时的 kickstart 就要等（实测 8～9 秒）。
# @see https://keith.github.io/xcode-man-pages/launchd.plist.5.html（KeepAlive SuccessfulExit、ThrottleInterval）
PLIST_CONTENT="<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
<plist version=\"1.0\">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${HELPER}</string>
        <string>round</string>
        <string>--tunnel</string>
        <string>${TUNNEL}</string>
        <string>--test-rules</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>ThrottleInterval</key>
    <integer>1</integer>
</dict>
</plist>"
printf '%s\n' "${PLIST_CONTENT}" | plutil -lint - >/dev/null || die "plist 不合法"

show() { echo "----- $1 -----"; printf '%s\n' "$2"; echo "----- end -----"; }
[ "${DRY_RUN}" -eq 1 ] && echo "== dry-run：只打印，不改任何东西"
echo "== 要装的东西（全是新文件；已经装了任何一样就拒绝）"
echo "辅助程序 ${HELPER}（root:wheel 0755），来自 ${BUILT}"
echo "  sha256 $(shasum -a 256 "${SNAPSHOT}" | cut -d ' ' -f 1)"
echo "目录 ${SUPPORT}（root:wheel 0755）：辅助程序在里面写防火墙状态文件、状态摘要、锁文件和开启时拍的两张放行表"
echo "测试表 ${SUPPORT}/test.table（root:wheel 0644）：${TEST_ADDRESS}"
echo "LaunchDaemon ${PLIST}（root:wheel 0644）："; show "${PLIST}" "${PLIST_CONTENT}"
echo "开启后（trial / on）每一轮装进 anchor ${ANCHOR} 的测试规则（装完是 off，不装）："; show "规则" "${RULES}"

if [ "${DRY_RUN}" -eq 1 ]; then
  echo "+ 检查：${LABEL} 没加载、上面的文件都不存在；pfctl -n 检查规则语法"
  echo "+ 问一次「输入 yes 继续」"
  echo "+ 写辅助程序和 plist，launchctl bootstrap system ${PLIST}，等第一份状态摘要"
  exit 0
fi

for f in "${FILES[@]}"; do
  if [ -e "${f}" ] || [ -L "${f}" ]; then die "已经有 ${f}：要重装先跑 sudo ${RESCUE}"; fi
done
if launchctl print "system/${LABEL}" >/dev/null 2>&1; then die "${LABEL} 已加载：要重装先跑 sudo ${RESCUE}"; fi
# 规则引用的表文件开启时才有：语法检查换成临时目录里的空表
for t in clash.table cn.table test.table; do : > "${SNAPSHOT_DIR}/${t}"; done
printf '%s\n' "${RULES//"${SUPPORT}"/"${SNAPSHOT_DIR}"}" > "${SNAPSHOT_DIR}/rules.pf"
echo "（pfctl -n 只检查语法、不加载；它打出的「could result in flushing of rules」「No ALTQ support」是固定提示，不是错误）"
pfctl -q -a "${ANCHOR}" -nf "${SNAPSHOT_DIR}/rules.pf" || die "pfctl 认为规则有语法错误（见上面）"
echo "== 检查通过：没装过，规则语法正确"

read -r -p "确认安装？输入 yes 继续：" answer
[ "${answer}" = "yes" ] || { echo "没装，什么都没改"; exit 1; }

trap 'echo "!! 安装中途失败：跑 sudo ${RESCUE} 清掉已经装上的部分" >&2' ERR
install -d -o root -g wheel -m 0755 "${SUPPORT}"
install -o root -g wheel -m 0755 "${SNAPSHOT}" "${HELPER}"
printf '%s\n' "${TEST_ADDRESS}" > "${SNAPSHOT_DIR}/test-address"
install -o root -g wheel -m 0644 "${SNAPSHOT_DIR}/test-address" "${SUPPORT}/test.table"
printf '%s\n' "${PLIST_CONTENT}" > "${SNAPSHOT_DIR}/plist"
install -o root -g wheel -m 0644 "${SNAPSHOT_DIR}/plist" "${PLIST}"
launchctl bootstrap system "${PLIST}"
trap - ERR
ls -l "${HELPER}" "${PLIST}"

STATUS="${SUPPORT}/firewall-status.json"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ -e "${STATUS}" ] && break
  sleep 1
done
if [ -e "${STATUS}" ]; then
  echo "--- 第一份状态摘要（mode 应为 off）"; cat "${STATUS}"; echo
else
  echo "!! 10 秒内没有状态摘要；看日志：log show --last 5m --predicate 'subsystem == \"${LABEL}\"'" >&2
fi
launchctl print "system/${LABEL}" | grep -E '^[[:space:]]*(state|runs|last exit code) =' || true

echo "== 装好了，现在是 off，什么都不拦。"
echo "开启试运行（2 分钟不保留自动回滚；开启时读一次 Clash Verge 的配置拍放行表）："
echo "  sudo ${HELPER} enable --clash \"\$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev\""
echo "保留 / 关闭：sudo ${HELPER} keep | disable"
echo "看状态：cat \"${STATUS}\"；看日志：log show --last 5m --predicate 'subsystem == \"${LABEL}\"'"
echo "卸载：sudo ${RESCUE}"
exit
}
