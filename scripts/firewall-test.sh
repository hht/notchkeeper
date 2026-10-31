#!/bin/bash
# 防火墙实机验收（docs/firewall.md §7 第 2～5 步），只用测试规则：所有拦截只针对去测试地址的流量，去别处的照常，不真的断网。
# 规则里没有 user / group（会让 pf 内核死锁，§5）。会动 pf：跑之前先给用户看、拿到当轮同意（§7）。
# 用法：sudo scripts/firewall-test.sh <测试地址>（从普通用户 sudo：重装时编译要降回那个用户，开启要读那个用户的 Clash Verge 目录）。
# 测试地址要是境外、同时开着 443 和 53 端口的 IPv4（比如公共 DNS），不在国内段和 Clash 节点里。约 6 分钟，每项打印 PASS / FAIL。
# 顺序：恢复脚本清场 → 装测试规则、隧道网卡名用不存在的 utun9999（模拟 Clash 断开）
#   1. 试运行：测试地址的 443、53 端口被拦，别处照常；记下状态表、空闲时 Evaluations、引用列表；到期自动回滚
#   2. 试运行中模拟开机 → off
#   3. 开启并保留 → on；on 时模拟开机 → 规则和引用回来；关闭 → 全清
#   4. 重装成 utun1024：测试地址走隧道能连上；关闭
# 结束时留着 utun1024 的测试规则安装、状态 off（什么都不拦）。卸载：sudo scripts/firewall-rescue.sh
# 模拟开机照 §7 开头：bootout、清 anchor、释放自己的 token、改掉防火墙状态文件里的开机标识、bootstrap。
# 输出不打印 IP（CLAUDE.md）。不用 pfctl -d，不碰 /etc/pf.conf。
# 整个脚本包在花括号里：bash 先读完整个文件再执行，root 跑到一半时脚本文件被改也不影响这一次
{
set -uo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

LABEL="com.notchkeeper.firewall"
ANCHOR="com.apple/300.Notchkeeper"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"
HELPER="/Library/PrivilegedHelperTools/notchkeeper-firewall"
SUPPORT="/Library/Application Support/Notchkeeper"
STATE="${SUPPORT}/firewall.state"
STATUS="${SUPPORT}/firewall-status.json"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
WEB="https://www.apple.com/library/test/success.html"
ADDR="${1:-}"

[ "$(id -u)" -eq 0 ] || { echo "要用 root 运行：sudo $0 <测试地址>" >&2; exit 1; }
{ [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; } || { echo "要从普通用户用 sudo 运行" >&2; exit 1; }
[[ "${ADDR}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || { echo "用法：sudo $0 <测试地址（IPv4）>" >&2; exit 64; }
# 测试规则拦去测试地址 53 端口的所有查询：它要是系统 DNS，测试期间整机解析全断
if scutil --dns | awk '/nameserver\[[0-9]+\]/ { print $3 }' | grep -qxF "${ADDR}"; then
  echo "测试地址是系统 DNS，测试时会断掉整机解析，换一个" >&2; exit 64
fi
USER_HOME="$(dscl . -read "/Users/${SUDO_USER}" NFSHomeDirectory | awk '{ print $2 }')"
CLASH="${USER_HOME}/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev"

passed=0
failed=0
started=$(date +%s)
log() { printf '[%4ss] %s\n' "$(( $(date +%s) - started ))" "$*"; }
ok() { log "PASS $*"; passed=$((passed + 1)); }
bad() { log "FAIL $*"; failed=$((failed + 1)); }
expect() { # expect <描述> <期望> <实际>
  if [ "$2" = "$3" ]; then ok "$1：$3"; else bad "$1：期望 $2，实际 $3"; fi
}

status() { plutil -extract "$1" raw -o - "${STATUS}" 2>/dev/null || echo "-"; }
token() { plutil -extract token raw -o - "${STATE}" 2>/dev/null || echo ""; }
rule_count() { pfctl -a "${ANCHOR}" -sr 2>/dev/null | grep -c . ; }
evaluations() { pfctl -a "${ANCHOR}" -vsr 2>/dev/null | awk '/Evaluations:/ { s += $3 } END { print s + 0 }'; }
states() { pfctl -si 2>/dev/null | awk '/current entries/ { print $3 }'; }
listed() { # 引用列表里有没有这个 token
  if [ -n "$1" ] && pfctl -s References 2>/dev/null | awk 'NF >= 5 { print $(NF-3) }' | grep -qx "$1"; then echo yes; else echo no; fi
}
wait_mode() { # wait_mode <mode> <最多几秒>：等状态摘要变成这个模式，打印等了多久
  local i
  for ((i = 0; i < $2; i++)); do
    [ "$(status mode)" = "$1" ] && { echo "${i}"; return 0; }
    sleep 1
  done
  echo "超时"
  return 1
}

# 探测：打印 ok 或「失败(退出码)」，附上耗时：block return 应该立刻失败，超时说明包被丢了。都以调用 sudo 的用户身份跑
probe() { # probe <命令…>
  local t0 rc
  t0=$(date +%s)
  sudo -u "${SUDO_USER}" "$@" >/dev/null 2>&1
  rc=$?
  if [ "${rc}" -eq 0 ]; then echo "ok"; else echo "失败(${rc},$(( $(date +%s) - t0 ))s)"; fi
}
target() { probe nc -z -G 8 "${ADDR}" 443; }      # 测试地址的 443 端口
target_dns() { probe dig +time=3 +tries=1 "@${ADDR}" www.apple.com; }
web() { probe curl -sS -m 8 -o /dev/null "${WEB}"; } # 别处
blocked() { case "$1" in ok) echo "没拦住" ;; *) echo "拦住" ;; esac; }
# 测试地址落在放行表里就会被先放行，测不出拦截
in_table() { pfctl -q -a "${ANCHOR}" -t "$1" -T test "${ADDR}" >/dev/null 2>&1 && echo yes || echo no; }

# 模拟开机（§7 开头）：守护进程先停，再清掉开机会丢的东西，改开机标识，再按 plist 重新加载
simulate_boot() {
  local t
  t="$(token)"
  launchctl bootout "system/${LABEL}" 2>/dev/null
  for _ in 1 2 3 4 5 6 7 8 9 10; do launchctl print "system/${LABEL}" >/dev/null 2>&1 || break; sleep 1; done
  pfctl -q -a "${ANCHOR}" -F rules 2>/dev/null
  [ -n "${t}" ] && [ "$(listed "${t}")" = yes ] && pfctl -q -X "${t}" 2>/dev/null
  sed -i '' 's/"bootSession":"[^"]*"/"bootSession":"SIMULATED-BOOT"/' "${STATE}"
  launchctl bootstrap system "${PLIST}"
  sleep 3
}

helper() { "${HELPER}" "$@" || bad "notchkeeper-firewall $1 退出码 $?"; }
enable() { helper enable --clash "${CLASH}"; }

install_rules() { # install_rules <网卡名>；失败时把安装脚本的输出原样附上
  local out
  "${REPO}/scripts/firewall-rescue.sh" >/dev/null 2>&1
  if ! out="$(echo yes | "${REPO}/scripts/install-firewall.sh" --test-rules --test-address "${ADDR}" --tunnel "$1" 2>&1)"; then
    printf '%s\n' "${out}" | sed 's/^/    | /'
    bad "安装 --tunnel $1 失败（输出见上）"
    return 1
  fi
  wait_mode off 15 >/dev/null || { bad "装完 15 秒内没有状态摘要"; return 1; }
  expect "装完 --tunnel $1：模式" off "$(status mode)"
  expect "装完：anchor 规则数" 0 "$(rule_count)"
}

log "== 0. 准备：恢复脚本清场，装测试规则 --tunnel utun9999"
log "开始前 pf：$(pfctl -s info 2>/dev/null | sed -n 's/^Status: \([A-Za-z]*\).*/\1/p')，状态表 $(states) 条，上限 $(pfctl -sm 2>/dev/null | awk '$1 == "states" { print $4 }')"
install_rules utun9999 || { log "装不上，停止"; exit 1; }
expect "关着时连测试地址（基线）" ok "$(target)"
expect "关着时上别处（基线）" ok "$(web)"

log "== 1. 试运行：测试地址被拦、别处照常、到期自动回滚"
enable
enabled_at=$(date +%s)
log "进入 trial 等了 $(wait_mode trial 15) 秒"
expect "开启后：模式" trial "$(status mode)"
expect "开启后：规则种类" testTable "$(status scope)"
expect "测试地址不在国内段里" no "$(in_table cn)"
expect "测试地址不在 <clash> 里" no "$(in_table clash)"
if [ "$(in_table cn)" = yes ] || [ "$(in_table clash)" = yes ]; then helper disable; log "换一个测试地址再跑，停止"; exit 1; fi
expect "开启后：anchor 有规则" yes "$([ "$(rule_count)" -gt 0 ] && echo yes || echo no)"
t="$(token)"
expect "开启后：防火墙状态文件里有 token" yes "$([ -n "${t}" ] && echo yes || echo no)"
expect "开启后：token 在引用列表里" yes "$(listed "${t}")"
log "INFO 引用列表里我们那一行：$(pfctl -s References 2>/dev/null | awk -v t="${t}" 'NF >= 5 && $(NF-3) == t { $1 = ""; print }')"
r="$(target)"; expect "连测试地址（隧道网卡不存在，应拦住）" 拦住 "$(blocked "${r}")"; log "INFO nc：${r}"
r="$(target_dns)"; expect "测试地址的 53 端口" 拦住 "$(blocked "${r}")"; log "INFO dig：${r}"
expect "上别处（不受影响）" ok "$(web)"
expect "核对：pf 开着" true "$(status check.pfEnabled)"
expect "核对：anchor 点在" true "$(status check.anchorPointPresent)"
expect "核对：隧道网卡在（utun9999 不存在，应为 false）" false "$(status check.tunnelPresent)"
e1="$(evaluations)"; s1="$(states)"; sleep 20; e2="$(evaluations)"
log "INFO 空闲 20 秒 Evaluations：${e1} → ${e2}（§5：空闲时涨不涨）；状态摘要 evaluationsGrowing=$(status check.evaluationsGrowing)"
log "INFO 状态表：${s1} 条（§5：平时占多少）"
log "等试运行到期（开启后 120 秒）……"
wait_mode off 150 >/dev/null
expect "到期自动回滚：模式" off "$(status mode)"
log "INFO 开启到回到 off 共 $(( $(date +%s) - enabled_at )) 秒（应在 120～135 秒）"
expect "回滚后：anchor 规则数" 0 "$(rule_count)"
expect "回滚后：token 已释放" no "$(listed "${t}")"
expect "回滚后：连测试地址" ok "$(target)"

log "== 2. 试运行中模拟开机 → off"
enable
wait_mode trial 15 >/dev/null
simulate_boot
wait_mode off 15 >/dev/null
expect "模拟开机后：模式" off "$(status mode)"
expect "模拟开机后：anchor 规则数" 0 "$(rule_count)"
expect "模拟开机后：没有重新拿引用" "" "$(token)"
expect "模拟开机后：连测试地址" ok "$(target)"

log "== 3. 开启并保留 → on；on 时模拟开机；关闭"
enable
wait_mode trial 15 >/dev/null
helper keep
expect "保留后：模式" on "$(wait_mode on 15 >/dev/null; status mode)"
r="$(target)"; expect "on：连测试地址" 拦住 "$(blocked "${r}")"
simulate_boot
sleep 8
expect "on 时模拟开机后：模式" on "$(status mode)"
expect "on 时模拟开机后：规则装回来了" yes "$([ "$(rule_count)" -gt 0 ] && echo yes || echo no)"
t="$(token)"
expect "on 时模拟开机后：重新拿到引用" yes "$(listed "${t}")"
r="$(target)"; expect "on 时模拟开机后：连测试地址" 拦住 "$(blocked "${r}")"
expect "on 时模拟开机后：上别处" ok "$(web)"
helper disable
wait_mode off 15 >/dev/null
expect "关闭后：模式" off "$(status mode)"
expect "关闭后：anchor 规则数" 0 "$(rule_count)"
expect "关闭后：token 已释放" no "$(listed "${t}")"
expect "关闭后：连测试地址" ok "$(target)"
sleep 2; expect "关闭后：守护进程退出了（off 时不轮询）" no "$(launchctl print "system/${LABEL}" 2>/dev/null | grep -q 'state = running' && echo yes || echo no)"

log "== 4. 重装成 utun1024：测试地址走隧道能连上"
install_rules utun1024
enable
wait_mode trial 15 >/dev/null
expect "utun1024：连测试地址（走隧道放行）" ok "$(target)"
expect "utun1024：核对 隧道网卡在" true "$(status check.tunnelPresent)"
r="$(target_dns)"; expect "utun1024：测试地址的 53 端口（走隧道放行）" ok "${r}"
helper disable
wait_mode off 15 >/dev/null
expect "关闭后：模式" off "$(status mode)"
expect "关闭后：anchor 规则数" 0 "$(rule_count)"

log "== 结束：PASS ${passed}，FAIL ${failed}。留着 utun1024 的测试规则安装，状态 off。卸载：sudo ${REPO}/scripts/firewall-rescue.sh"
log "引用列表（核对没有残留我们的引用）："; pfctl -s References 2>/dev/null
[ "${failed}" -eq 0 ]
exit
}
