#!/bin/bash
# 防火墙的恢复脚本：把 Notchkeeper 防火墙装进系统的东西全部卸掉，断网时用。设计见 docs/firewall.md §3。
# 用法：sudo scripts/firewall-rescue.sh [--disable-pf]；--dry-run 不要 root，只打印会做哪几步。
# 不依赖网络、App 和已安装的防火墙脚本，只用系统自带的 launchctl、pfctl、plutil；重复执行、什么都没装时执行都安全。
# 顺序不能换：守护进程每 10 秒把规则装回去，所以先 bootout 再清 anchor。
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
FILES=("${PLIST}" "${HELPER}" "${STATE}" "${SUPPORT}/firewall-status.json" "${SUPPORT}/firewall.pf")

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

# 某一步失败也接着做后面的步骤，能卸多少卸多少；最后看核对结果定退出码
run() {
  printf '+'; printf ' %q' "$@"; printf '\n'
  if [ "${DRY_RUN}" -eq 0 ]; then "$@"; fi
}
loaded() { launchctl print "system/${LABEL}" >/dev/null 2>&1; }

[ "${DRY_RUN}" -eq 1 ] && echo "== dry-run：只打印，不改任何东西"
echo "（pfctl 打出的「No ALTQ support in kernel」「ALTQ related functions disabled」是正常的，不是失败）"

echo "== 1/5 停掉守护进程"
if [ "${DRY_RUN}" -eq 1 ]; then
  echo "+ （如果已加载）launchctl bootout system/${LABEL}，并等它退出（最多 10 秒）"
elif loaded; then
  run launchctl bootout "system/${LABEL}"
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    loaded || break
    sleep 1
  done
  # 没停下来也接着做：下面删掉 plist 至少保证重启后不会再起来
  loaded && echo "!! ${LABEL} 10 秒内没退出，继续清规则；它可能还会把规则装回去，做完后再跑一次本脚本" >&2
else
  echo "   没有加载，跳过"
fi

echo "== 2/5 清空 anchor ${ANCHOR}"
if [ "${DRY_RUN}" -eq 1 ]; then
  echo "+ （如果有规则）pfctl -a ${ANCHOR} -F rules"
# -sr 读不出来（pfctl 出错）时也照样清，宁可多清一次
elif rules="$(pfctl -a "${ANCHOR}" -sr 2>/dev/null)" && [ -z "${rules}" ]; then
  echo "   没有规则，跳过"
else
  run pfctl -a "${ANCHOR}" -F rules
fi

echo "== 3/5 释放本防火墙的 pf 启用引用"
# 只释放本次开机拿到的 token：重启后旧 token 早已失效，号码还可能和别人的撞上
token=""
session="$(sysctl -n kern.bootsessionuuid 2>/dev/null)"
if [ -n "${session}" ] && [ -r "${STATE}" ] && [ "$(plutil -extract bootSession raw -o - "${STATE}" 2>/dev/null)" = "${session}" ]; then
  token="$(plutil -extract token raw -o - "${STATE}" 2>/dev/null)"
  case "${token}" in ''|*[!0-9]*) token="" ;; esac
fi
if [ "${DRY_RUN}" -eq 1 ]; then
  echo "+ （如果状态文件里有本次开机的 token）pfctl -X <token>"
elif [ -n "${token}" ]; then
  # pf 已经停了时 pfctl -X 会报错，忽略
  run pfctl -X "${token}" || true
else
  echo "   状态文件里没有本次开机的 token，跳过"
fi

echo "== 4/5 删除已安装的文件（等于卸载，想再用就重新安装）"
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
  run pfctl -d || true
fi

[ "${DRY_RUN}" -eq 1 ] && exit 0

echo "== 5/5 核对"
ok=1
# anchor 清空后会被 pf 回收，-sr 可能报「不存在」；只看 stdout 有没有规则
rules="$(pfctl -a "${ANCHOR}" -sr 2>/dev/null)"
if [ -z "${rules}" ]; then
  echo "   anchor ${ANCHOR}：空"
else
  ok=0; echo "!! anchor ${ANCHOR} 还有规则：" >&2; printf '%s\n' "${rules}" >&2
fi
if loaded; then ok=0; echo "!! ${LABEL} 还在 launchd 里" >&2; else echo "   ${LABEL}：没有加载"; fi
for f in "${FILES[@]}"; do
  if [ -e "${f}" ] || [ -L "${f}" ]; then ok=0; echo "!! 还在：${f}" >&2; fi
done
echo "   pf：$(pfctl -s info 2>/dev/null | sed -n 's/^Status: \([A-Za-z]*\).*/\1/p')（Enabled 不代表有问题：系统和别的 App 也会启用 pf）"

if [ "${ok}" -eq 1 ]; then
  echo "== 完成：Notchkeeper 防火墙已全部卸掉"
else
  echo "== 没清干净，见上面的 !!；可以再跑一次，仍不行就 sudo $0 --disable-pf" >&2
  exit 1
fi
