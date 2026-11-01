#!/bin/bash
# 防火墙的恢复脚本：把 Notchkeeper 防火墙装进系统的东西全部卸掉，断网时用。设计见 docs/firewall.md §3。
# 用法：sudo scripts/firewall-rescue.sh [--disable-pf]；--dry-run 不要 root，只打印会做哪几步。
# 不依赖网络、App 和已安装的防火墙脚本，只用系统自带的 launchctl、pfctl、plutil；重复执行、什么都没装时执行都安全。
# 绝不卡住终端：pf 在内核里卡死时（比如 user 规则死锁，docs/firewall.md §5）所有 pfctl 都不返回，
# launchctl bootout 也会等着卡在 pfctl 里的守护进程。所以：
#   1. 先删开机会加载的 plist 和辅助程序：只动文件、不碰 pf，删完重启一定恢复；辅助程序没了，守护进程下一轮也起不来；
#   2. 之后每条 launchctl / pfctl 都限时，超时不再等（卡在内核里的进程杀不掉，留着它），最后告诉人重启。
# 默认不 pfctl -d：它会停掉整个 pf，连带作废别人的启用引用（AirDrop、互联网共享、OrbStack 等）；只有 --disable-pf 才执行。
# 不碰：/etc/pf.conf、别人的 anchor 和 token、Clash、网络设置、任何进程。
# 路径和名字必须和安装脚本一致；改了任何一处，两边一起改。
set -u
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

usage() { echo "用法: sudo $0 [--disable-pf]  或  $0 --dry-run [--disable-pf]" >&2; exit 64; }
DRY_RUN=0
DISABLE_PF=0
for arg in "$@"; do
  case "${arg}" in
    --dry-run) DRY_RUN=1 ;;
    --disable-pf) DISABLE_PF=1 ;;
    *) usage ;;
  esac
done
if [ "${DRY_RUN}" -eq 0 ] && [ "$(id -u)" -ne 0 ]; then
  echo "要用 root 运行：sudo $0" >&2
  exit 1
fi

# 限时执行：最多等 $1 秒，输出写进文件 $2（不走管道：卡住的进程会让 $(…) 一直等它关管道；stdin 也不给终端，免得 sudo 等它）。
# 超时返回 124，不再等它：卡在内核里的进程连 SIGKILL 都杀不掉，等下去终端就跟着卡死
limited() {
  local seconds="$1" out="$2" pid i
  shift 2
  "$@" </dev/null >"${out}" 2>&1 &
  pid=$!
  for ((i = 0; i < seconds * 10; i++)); do
    if ! kill -0 "${pid}" 2>/dev/null; then
      wait "${pid}"
      return $?
    fi
    sleep 0.1
  done
  disown "${pid}" 2>/dev/null # 免得 bash 打出「Killed: 9」，看着像出错
  kill -9 "${pid}" 2>/dev/null
  return 124
}

# 某一步失败也接着做后面的步骤，能卸多少卸多少；最后看核对结果定退出码
hung=0
OUT=""
if [ "${DRY_RUN}" -eq 0 ]; then
  OUT="$(mktemp -d /private/tmp/notchkeeper-rescue.XXXXXX)/out"
  trap 'rm -rf "$(dirname "${OUT}")"' EXIT
fi
# 打印并限时执行，打印它的输出；超时记下 pf 卡住了
run() {
  local rc=0
  printf '+'; printf ' %q' "$@"; printf '\n'
  [ "${DRY_RUN}" -eq 1 ] && return 0
  limited 10 "${OUT}" "$@" || rc=$?
  sed 's/^/   /' "${OUT}"
  if [ "${rc}" -eq 124 ]; then
    hung=1
    echo "!! 10 秒没返回，不再等它" >&2
  fi
  return "${rc}"
}
loaded() { limited 5 /dev/null launchctl print "system/${LABEL}"; }
# 本 anchor 有没有规则，设进 ANCHOR_RULES：yes / no / unknown（pfctl 出错或卡住）。
# 不用 $(…) 返回：子 shell 里记下的 hung 传不回来
check_anchor() {
  local rc=0
  limited 5 "${OUT}" pfctl -a "${ANCHOR}" -sr || rc=$?
  [ "${rc}" -eq 124 ] && hung=1
  if [ "${rc}" -ne 0 ]; then ANCHOR_RULES=unknown
  elif grep -qv -e '^No ALTQ' -e '^ALTQ' "${OUT}"; then ANCHOR_RULES=yes
  else ANCHOR_RULES=no; fi
}

[ "${DRY_RUN}" -eq 1 ] && echo "== dry-run：只打印，不改任何东西"
echo "（pfctl 打出的「No ALTQ support in kernel」「ALTQ related functions disabled」是正常的，不是失败）"

# token 在第 1 步删文件之前读出来：只释放本次开机拿到的 token，重启后旧 token 早已失效，号码还可能和别人的撞上
token=""
session="$(sysctl -n kern.bootsessionuuid 2>/dev/null)"
if [ -n "${session}" ] && [ -r "${STATE}" ] && [ "$(plutil -extract bootSession raw -o - "${STATE}" 2>/dev/null)" = "${session}" ]; then
  token="$(plutil -extract token raw -o - "${STATE}" 2>/dev/null)"
  case "${token}" in ''|*[!0-9]*) token="" ;; esac
fi

echo "== 1/5 删掉开机会加载的东西（只动文件，不碰 pf：做完这步，重启一定恢复）"
for f in "${PLIST}" "${HELPER}"; do
  if [ "${DRY_RUN}" -eq 1 ]; then echo "+ （如果存在）rm -f ${f}"
  elif [ -e "${f}" ] || [ -L "${f}" ]; then run rm -f "${f}"
  else echo "   没有 ${f}，跳过"; fi
done

echo "== 2/5 停掉守护进程"
if [ "${DRY_RUN}" -eq 1 ]; then
  echo "+ （如果已加载）launchctl bootout system/${LABEL}（最多等 10 秒）"
elif loaded; then
  run launchctl bootout "system/${LABEL}" || true
else
  echo "   没有加载，跳过"
fi

echo "== 3/5 清空 anchor ${ANCHOR}"
if [ "${DRY_RUN}" -eq 1 ]; then
  echo "+ （如果有规则）pfctl -a ${ANCHOR} -F rules（最多等 10 秒）"
elif [ "${hung}" -eq 1 ]; then
  echo "   pf 已经卡住，跳过"
else
  check_anchor
  if [ "${ANCHOR_RULES}" = no ]; then echo "   没有规则，跳过"
  elif [ "${hung}" -eq 1 ]; then echo "   读规则 5 秒没返回，pf 卡住了，跳过"
  # 读不出来（出错）时也照样清，宁可多清一次
  else run pfctl -a "${ANCHOR}" -F rules || true; fi
fi

echo "== 4/5 释放本防火墙的 pf 启用引用"
if [ "${DRY_RUN}" -eq 1 ]; then
  echo "+ （如果防火墙状态文件里有本次开机的 token）pfctl -X <token>（最多等 10 秒）"
elif [ "${hung}" -eq 1 ]; then
  echo "   pf 已经卡住，跳过"
elif [ -n "${token}" ]; then
  # pf 已经停了时 pfctl -X 会报错，忽略
  run pfctl -X "${token}" || true
else
  echo "   防火墙状态文件里没有本次开机的 token，跳过"
fi

echo "== 5/5 删除其余文件（等于卸载，想再用就重新安装）"
for f in "${FILES[@]}"; do
  if [ "${DRY_RUN}" -eq 1 ]; then echo "+ （如果存在）rm -f ${f}"
  elif [ -e "${f}" ] || [ -L "${f}" ]; then run rm -f "${f}"; fi
done
if [ -d "${SUPPORT}" ]; then
  # 目录里还有别的文件就留着，不 rm -r
  if [ "${DRY_RUN}" -eq 1 ]; then echo "+ （如果空了）rmdir ${SUPPORT}"; else rmdir "${SUPPORT}" 2>/dev/null || true; fi
fi

if [ "${DISABLE_PF}" -eq 1 ]; then
  echo "== 最后手段：停掉整个 pf（别人的启用引用一并作废）"
  if [ "${DRY_RUN}" -eq 0 ] && [ "${hung}" -eq 1 ]; then echo "   pf 已经卡住，pfctl -d 也会卡住，跳过"; else run pfctl -d || true; fi
fi

[ "${DRY_RUN}" -eq 1 ] && exit 0

echo "== 核对"
ok=1
for f in "${FILES[@]}"; do
  if [ -e "${f}" ] || [ -L "${f}" ]; then ok=0; echo "!! 还在：${f}" >&2; fi
done
if loaded; then ok=0; echo "!! ${LABEL} 还在 launchd 里" >&2; else echo "   ${LABEL}：没有加载"; fi
if [ "${hung}" -eq 0 ]; then
  check_anchor
  case "${ANCHOR_RULES}" in
    no) echo "   anchor ${ANCHOR}：空" ;;
    yes) ok=0; echo "!! anchor ${ANCHOR} 还有规则：" >&2; sed 's/^/   /' "${OUT}" >&2 ;;
    *) ok=0; echo "!! 读不出 anchor ${ANCHOR}" >&2 ;;
  esac
fi
if [ "${hung}" -eq 0 ] && limited 5 "${OUT}" pfctl -s info; then
  echo "   pf：$(sed -n 's/^Status: \([A-Za-z]*\).*/\1/p' "${OUT}")（Enabled 不代表有问题：系统和别的 App 也会启用 pf）"
fi

if [ "${hung}" -eq 1 ]; then
  echo "== pf 在内核里卡住了，不重启解不开（pfctl -d 也一样卡）。开机会加载的东西已经删掉：现在重启电脑，网络就会恢复，不用再跑本脚本" >&2
  exit 2
elif [ "${ok}" -eq 1 ]; then
  echo "== 完成：Notchkeeper 防火墙已全部卸掉"
else
  echo "== 没清干净，见上面的 !!；可以再跑一次，仍不行就 sudo $0 --disable-pf" >&2
  exit 1
fi
