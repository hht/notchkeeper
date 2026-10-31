#!/bin/bash
# 恢复脚本的演练：在真实路径装一套只放行、什么都不拦的假防火墙，再用 scripts/firewall-rescue.sh 卸掉它。docs/firewall.md §3、§7 第 1 步。
# 用法：sudo scripts/firewall-drill.sh；--dry-run 不要 root，只打印会写的文件和步骤。
# 装的东西：LaunchDaemon 每 10 秒看一次本 anchor，空了就装回一条永远匹配不到的规则（去 198.51.100.1:9 的 TCP），
#   模拟真守护进程「被清掉的规则会被装回去」；再 pfctl -E 拿一个启用引用，token 记进防火墙状态文件。
#   这条规则不放行也不拦截任何真实流量。pf 原来是停着的，pfctl -E 会把它打开，系统 com.apple/* 下已有的
#   规则（AirDrop、应用防火墙）随之生效；恢复脚本释放 token 后 pf 回到原状。
# 顺带打印 docs/firewall.md §6 要 root 实测的几项：pfctl -E 的输出、-s References、anchor 的 Evaluations 会不会涨、pf 原来是否启用。
# 撤销：sudo scripts/firewall-rescue.sh。已经装了任何防火墙文件时拒绝运行，不覆盖。
# 路径和名字必须和 firewall-rescue.sh 一致。
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

LABEL="com.notchkeeper.firewall"
ANCHOR="com.apple/300.Notchkeeper"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"
HELPER="/Library/PrivilegedHelperTools/notchkeeper-firewall"
SUPPORT="/Library/Application Support/Notchkeeper"
STATE="${SUPPORT}/firewall.state"
RULES="${SUPPORT}/firewall.pf"
RESCUE="$(cd "$(dirname "$0")" && pwd)/firewall-rescue.sh"

usage() { echo "用法: sudo $0  或  $0 --dry-run" >&2; exit 64; }
DRY_RUN=0
for arg in "$@"; do
  case "${arg}" in
    --dry-run) DRY_RUN=1 ;;
    *) usage ;;
  esac
done
if [ "${DRY_RUN}" -eq 0 ] && [ "$(id -u)" -ne 0 ]; then
  echo "要用 root 运行：sudo $0" >&2
  exit 1
fi

RULES_CONTENT='# Notchkeeper 恢复演练：永远匹配不到的规则，只为让 anchor 非空、看 Evaluations
pass out quick inet proto tcp from any to 198.51.100.1 port 9 no state'

HELPER_CONTENT="#!/bin/bash
# Notchkeeper 恢复演练用的假守护进程：每 10 秒一轮，anchor 空了就装回演练规则。卸载：sudo scripts/firewall-rescue.sh
# 只在 anchor 空了时装回：每次 -f 都换上一批新规则、Evaluations 从 0 数起
[ -n \"\$(/sbin/pfctl -a '${ANCHOR}' -sr 2>/dev/null)\" ] || exec /sbin/pfctl -q -a '${ANCHOR}' -f '${RULES}'"

PLIST_CONTENT="<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
<plist version=\"1.0\">
<dict>
	<key>Label</key>
	<string>${LABEL}</string>
	<key>ProgramArguments</key>
	<array>
		<string>${HELPER}</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>StartInterval</key>
	<integer>10</integer>
</dict>
</plist>"

show() { echo "----- $1 -----"; printf '%s\n' "$2"; echo "----- end -----"; }

if [ "${DRY_RUN}" -eq 1 ]; then
  echo "== dry-run：只打印，不改任何东西"
  echo "+ 检查：${LABEL} 没加载，下面这些文件都不存在，否则拒绝"
  echo "+ mkdir -p ${SUPPORT}（root:wheel 0755）"
  echo "+ 写 ${RULES}（root:wheel 0644）："; show "${RULES}" "${RULES_CONTENT}"
  echo "+ 写 ${HELPER}（root:wheel 0755）："; show "${HELPER}" "${HELPER_CONTENT}"
  echo "+ 写 ${PLIST}（root:wheel 0644）："; show "${PLIST}" "${PLIST_CONTENT}"
  echo "+ pfctl -E，token 和 kern.bootsessionuuid 写进 ${STATE}（root:wheel 0600）"
  echo "+ launchctl bootstrap system ${PLIST}"
  echo "+ 打印实测结果：不存在的 anchor 上 -sr 的退出码、-s info、-s References、anchor 的 -vsr（隔 10 秒两次）、手动清空后 10 秒内规则被装回"
  exit 0
fi

for f in "${PLIST}" "${HELPER}" "${STATE}" "${SUPPORT}/firewall-status.json" "${RULES}" "${SUPPORT}/firewall.lock" \
  "${SUPPORT}/.firewall.state.tmp" "${SUPPORT}/.firewall-status.json.tmp"; do
  if [ -e "${f}" ] || [ -L "${f}" ]; then echo "已经有 ${f}：先跑 sudo ${RESCUE}" >&2; exit 1; fi
done
if launchctl print "system/${LABEL}" >/dev/null 2>&1; then echo "${LABEL} 已加载：先跑 sudo ${RESCUE}" >&2; exit 1; fi

echo "== 实测：装之前"
pfctl -s info 2>/dev/null | sed -n '1p' || true
rules="$(pfctl -a "${ANCHOR}" -sr 2>/dev/null)" && rc=0 || rc=$?
echo "--- pfctl -a ${ANCHOR} -sr（anchor 还不存在）：退出码 ${rc}，stdout「${rules}」"
echo "--- pfctl -s References（stdout）"; pfctl -s References 2>/dev/null || true

echo "== 写文件"
install -d -o root -g wheel -m 0755 "${SUPPORT}"
tmp="$(mktemp)"
printf '%s\n' "${RULES_CONTENT}" > "${tmp}"; pfctl -qnf "${tmp}"; install -o root -g wheel -m 0644 "${tmp}" "${RULES}"
printf '%s\n' "${HELPER_CONTENT}" > "${tmp}"; install -o root -g wheel -m 0755 "${tmp}" "${HELPER}"
printf '%s\n' "${PLIST_CONTENT}" > "${tmp}"; plutil -lint "${tmp}" >/dev/null; install -o root -g wheel -m 0644 "${tmp}" "${PLIST}"
rm -f "${tmp}"
ls -l "${RULES}" "${HELPER}" "${PLIST}"

echo "== 实测：pfctl -E"
out="$(mktemp)"; err="$(mktemp)"
pfctl -E >"${out}" 2>"${err}" || echo "!! pfctl -E 退出码 $?" >&2
echo "--- stdout"; cat "${out}"
echo "--- stderr"; cat "${err}"
token="$(cat "${out}" "${err}" | sed -n 's/^Token : \([0-9][0-9]*\)$/\1/p')"
rm -f "${out}" "${err}"
if [ -n "${token}" ]; then
  ( umask 077; printf '{"mode":"drill","token":"%s","bootSession":"%s"}\n' "${token}" "$(sysctl -n kern.bootsessionuuid)" > "${STATE}" )
  echo "token 已写进 ${STATE}"
else
  echo "!! 输出里没认出 token（格式和预期的「Token : <数字>」不一样）；把上面的输出发回来，恢复脚本释放不了这个引用" >&2
fi

echo "== 启动假守护进程"
launchctl bootstrap system "${PLIST}"
sleep 2
echo "--- pfctl -a ${ANCHOR} -vsr"; pfctl -a "${ANCHOR}" -vsr 2>/dev/null || true
echo "（等 10 秒看 Evaluations 涨没涨）"; sleep 10
echo "--- pfctl -a ${ANCHOR} -vsr"; pfctl -a "${ANCHOR}" -vsr 2>/dev/null || true
echo "--- pfctl -s info"; pfctl -s info 2>/dev/null | sed -n '1p' || true
echo "--- pfctl -s References"; pfctl -s References 2>/dev/null || true

echo "== 实测：手动清空 anchor，守护进程应在 10 秒内装回（所以恢复脚本必须先 bootout）"
pfctl -q -a "${ANCHOR}" -F rules 2>/dev/null || true
echo "清空后：$(pfctl -a "${ANCHOR}" -sr 2>/dev/null | wc -l | tr -d ' ') 条"
sleep 11
echo "11 秒后：$(pfctl -a "${ANCHOR}" -sr 2>/dev/null | wc -l | tr -d ' ') 条"
launchctl print "system/${LABEL}" | grep -E '^[[:space:]]*(state|runs|last exit code) =' || true

echo "== 装好了。下一步：sudo ${RESCUE} ，确认最后一行是「已全部卸掉」；重启后再跑一次，应每步都是「跳过」"
