#!/bin/bash
# 安装防火墙（docs/firewall.md §4「特权部分」）：辅助程序、LaunchDaemon、它们的目录。装完是 off，什么都不拦；开启要另外 sudo … enable。
# 用法：
#   scripts/install-firewall.sh [--tunnel <网卡名>] --dry-run          不要 root：编译，只打印会装什么
#   sudo scripts/install-firewall.sh [--tunnel <网卡名>]               编译，打印同样的内容，输入 yes 才装
#   … --helper <辅助程序> --expect-sha256 <哈希> [--yes]               不编译，装这一份现成的；哈希对不上就停。
#                                                                       --yes 不问：App 里用户已经在确认框里点了安装、在管理员密码框输了密码
#   … --test-rules --test-address <IPv4>                               测试规则：block 只拦去测试地址的流量，测试时不真的断网（§7）
# 编译总是用普通用户（root 编译会在仓库里留下 root 的文件）：sudo 运行时降回调用 sudo 的那个用户；没有 sudo 的用户（App 经 osascript 提权）就必须给 --helper 和哈希。
# 默认装正式规则（整机拦截）。装完是 off，开启时才第一次加载，有 2 分钟试运行。
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
# App 里跑的是拷到临时目录的这份脚本，仓库路径对不上：两种卸法都写
RESCUE_HINT="设置 › 防火墙「卸载」，或在仓库里 sudo scripts/firewall-rescue.sh"

usage() { echo "用法: sudo $0 [--tunnel <网卡名>] [--helper <辅助程序> --expect-sha256 <哈希> [--yes]] [--test-rules --test-address <IPv4>]  或  加 --dry-run 只打印" >&2; exit 64; }
die() { echo "安装中止：$1" >&2; exit 1; }
ARGS="$*"
DRY_RUN=0
TEST_RULES=0
TEST_ADDRESS=""
TUNNEL="utun1024"
HELPER_SOURCE=""
EXPECT_SHA256=""
YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --test-rules) TEST_RULES=1 ;;
    --test-address) [ $# -ge 2 ] || usage; TEST_ADDRESS="$2"; shift ;;
    --tunnel) [ $# -ge 2 ] || usage; TUNNEL="$2"; shift ;;
    --helper) [ $# -ge 2 ] || usage; HELPER_SOURCE="$2"; shift ;;
    --expect-sha256) [ $# -ge 2 ] || usage; EXPECT_SHA256="$2"; shift ;;
    --yes) YES=1 ;;
    *) usage ;;
  esac
  shift
done
if [ "${TEST_RULES}" -eq 1 ]; then
  [[ "${TEST_ADDRESS}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || die "--test-rules 要用 --test-address 给一个 IPv4 测试地址"
else
  [ -z "${TEST_ADDRESS}" ] || die "--test-address 只和 --test-rules 一起用"
fi
[ -z "${EXPECT_SHA256}" ] || [[ "${EXPECT_SHA256}" =~ ^[0-9a-f]{64}$ ]] || die "--expect-sha256 要是 64 位小写十六进制"
{ [ -z "${HELPER_SOURCE}" ] && [ -z "${EXPECT_SHA256}" ]; } || { [ -n "${HELPER_SOURCE}" ] && [ -n "${EXPECT_SHA256}" ]; } \
  || die "--helper 和 --expect-sha256 要一起给"
[ "${YES}" -eq 0 ] || [ -n "${EXPECT_SHA256}" ] || die "--yes 只在给了 --helper 和 --expect-sha256 时可用：不问 yes，就得钉住装的是哪一份"
if [ "${DRY_RUN}" -eq 0 ] && [ "$(id -u)" -ne 0 ]; then
  echo "要用 root 运行：sudo $0 ${ARGS}；先看会装什么：$0 ${ARGS} --dry-run" >&2
  exit 1
fi

# 仓库和编译目录普通用户写得了：编译、读二进制、跑 rules 都降回调用 sudo 的那个用户。
# 在输入 yes 之前，root 不执行、不跟随（符号链接）任何普通用户写得了的东西（脚本本身见开头的花括号）；编译也不在仓库里留下 root 的文件。
# 没有 sudo 的用户（App 经 osascript 提权）：root 只读 --helper 那一份，拷进自己的目录、哈希对上了才执行
if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
  as_user() { sudo -u "${SUDO_USER}" -H "$@"; }
elif [ "$(id -u)" -eq 0 ]; then
  [ -n "${HELPER_SOURCE}" ] || die "没有调用 sudo 的用户时不能编译：要给 --helper 和 --expect-sha256"
  as_user() { "$@"; }
else
  as_user() { "$@"; }
fi

if [ -n "${HELPER_SOURCE}" ]; then
  BUILT="${HELPER_SOURCE}"
else
  # 每次都编译，不比文件时间：内容没变时 swift build 不重新链接，二进制的时间不会更新。
  # 先进仓库：swift build 要读得出当前目录，调用 sudo 时所在的目录那个用户不一定进得去
  echo "== 编译 firewalld（release）"
  cd "${REPO}"
  as_user swift build -c release --product firewalld --package-path "${REPO}" || die "编译失败"
fi

# 读一份快照进只有自己能写的临时目录：给人看的哈希、规则和最后装上的，都是这一份，编译目录里的文件之后再被换掉也无关。
# 放在有粘滞位的 /private/tmp：$TMPDIR 可能是用户目录，用户能把 root 建的临时目录整个换掉。
# 目录 0711、快照 0755：调用的用户能执行快照（跑 rules），改不了它。
# 哈希核对之前快照只有 root 读得了（umask 077）：--helper 指向别的文件时，root 读到的东西不给别人看见
SNAPSHOT_DIR="$(mktemp -d /private/tmp/notchkeeper-firewall-install.XXXXXX)"
trap 'rm -rf "${SNAPSHOT_DIR}"' EXIT
chmod 0711 "${SNAPSHOT_DIR}"
SNAPSHOT="${SNAPSHOT_DIR}/notchkeeper-firewall"
# 只读普通文件、至多 64 MB：root 读 --helper 时不跟符号链接、不在 FIFO 上一直等
{ [ -f "${BUILT}" ] && [ ! -L "${BUILT}" ]; } || die "${BUILT} 不是普通文件"
( umask 077; as_user head -c 67108864 "${BUILT}" > "${SNAPSHOT}" ) || die "读不了 ${BUILT}"
SHA256="$(shasum -a 256 "${SNAPSHOT}" | cut -d ' ' -f 1)"
# 对不上时不打出读到的哈希：那可能是别的文件的
[ -z "${EXPECT_SHA256}" ] || [ "${SHA256}" = "${EXPECT_SHA256}" ] || die "辅助程序的哈希和调用方钉住的 ${EXPECT_SHA256} 对不上：拷出来之后被换过"
chmod 0755 "${SNAPSHOT}"
rc=0
TEST_FLAG=()
[ "${TEST_RULES}" -eq 0 ] || TEST_FLAG=(--test-rules)
# bash 3.2 下 set -u 时空数组展开会报 unbound：用 ${a[@]+…} 的写法
RULES="$(as_user "${SNAPSHOT}" rules --tunnel "${TUNNEL}" ${TEST_FLAG[@]+"${TEST_FLAG[@]}"})" || rc=$?
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
TEST_PLIST_ARG=""
[ "${TEST_RULES}" -eq 0 ] || TEST_PLIST_ARG="
        <string>--test-rules</string>"
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
        <string>${TUNNEL}</string>${TEST_PLIST_ARG}
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

# check_syntax <规则全文> <临时目录>：pfctl -n 只解析不加载。规则引用的表文件开启时才有，换成临时目录里的空表。
# 跑在 macOS 自带的 bash 3.2 上（RescueScriptTests 用 /bin/bash 跑这个函数）
check_syntax() {
  local t
  for t in clash.table cn.table test.table; do : > "$2/${t}"; done
  # 替换部分不加引号：bash 3.2 会把引号原样留进结果里（bash 5.2 起不加引号时 & 有特殊含义，shebang 是 /bin/bash，碰不到）
  printf '%s\n' "${1//"${SUPPORT}"/$2}" > "$2/rules.pf"
  pfctl -q -a "${ANCHOR}" -nf "$2/rules.pf"
}

show() { echo "----- $1 -----"; printf '%s\n' "$2"; echo "----- end -----"; }
[ "${DRY_RUN}" -eq 1 ] && echo "== dry-run：只打印，不改任何东西"
echo "== 要装的东西（全是新文件；已经装了任何一样就拒绝）"
echo "辅助程序 ${HELPER}（root:wheel 0755），来自 ${BUILT}"
echo "  sha256 ${SHA256}"
echo "目录 ${SUPPORT}（root:wheel 0755）：辅助程序在里面写防火墙状态文件、状态摘要、锁文件和开启时拍的两张放行表"
[ "${TEST_RULES}" -eq 0 ] || echo "测试表 ${SUPPORT}/test.table（root:wheel 0644）：${TEST_ADDRESS}"
echo "LaunchDaemon ${PLIST}（root:wheel 0644）："; show "${PLIST}" "${PLIST_CONTENT}"
if [ "${TEST_RULES}" -eq 1 ]; then
  echo "开启后（trial / on）每一轮装进 anchor ${ANCHOR} 的测试规则（装完是 off，不装）："; show "规则" "${RULES}"
else
  echo "开启后（trial / on）每一轮装进 anchor ${ANCHOR} 的正式规则：不走隧道的流量除局域网、Clash 直连的地址和国内段外一律拦（装完是 off，不装）："; show "规则" "${RULES}"
fi

# 语法检查不要 root，dry-run 也做：不等到真装才发现规则装不上
echo "（pfctl -n 只检查语法、不加载；它打出的「could result in flushing of rules」「No ALTQ support」是固定提示，不是错误）"
check_syntax "${RULES}" "${SNAPSHOT_DIR}" || die "pfctl 认为规则有语法错误（见上面）"
echo "== 规则语法正确"

if [ "${DRY_RUN}" -eq 1 ]; then
  echo "+ 检查：${LABEL} 没加载、上面的文件都不存在"
  [ "${YES}" -eq 1 ] && echo "+ 不问（--yes）" || echo "+ 问一次「输入 yes 继续」"
  echo "+ 写辅助程序和 plist，launchctl bootstrap system ${PLIST}，等第一份状态摘要"
  exit 0
fi

for f in "${FILES[@]}"; do
  if [ -e "${f}" ] || [ -L "${f}" ]; then die "已经有 ${f}：要重装先卸载（${RESCUE_HINT}）"; fi
done
if launchctl print "system/${LABEL}" >/dev/null 2>&1; then die "${LABEL} 已加载：要重装先卸载（${RESCUE_HINT}）"; fi
echo "== 检查通过：没装过"

if [ "${YES}" -eq 1 ]; then
  echo "== --yes：用户已经在调用方确认过，辅助程序哈希对得上"
else
  read -r -p "确认安装？输入 yes 继续：" answer
  [ "${answer}" = "yes" ] || { echo "没装，什么都没改"; exit 1; }
fi

trap 'echo "!! 安装中途失败：卸载（${RESCUE_HINT}）清掉已经装上的部分" >&2' ERR
install -d -o root -g wheel -m 0755 "${SUPPORT}"
install -o root -g wheel -m 0755 "${SNAPSHOT}" "${HELPER}"
if [ "${TEST_RULES}" -eq 1 ]; then
  printf '%s\n' "${TEST_ADDRESS}" > "${SNAPSHOT_DIR}/test-address"
  install -o root -g wheel -m 0644 "${SNAPSHOT_DIR}/test-address" "${SUPPORT}/test.table"
fi
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
echo "卸载：${RESCUE_HINT}"
exit
}
