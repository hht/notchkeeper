# 防火墙（断网保护）

状态：需求已定（用户定），还没实现。第 6 节的实测项做完、恢复脚本验证通过之后，才写 block 规则。

## 1. 要做什么

只有一个开关：**开启时全部防护生效，关闭时全部不生效**。没有分项开关，也不针对哪个 App。

- **开启**：除局域网外，所有不走 Clash 隧道（utun）的出站流量一律丢弃，IPv4 和 IPv6 都包括。Clash 一断，整台机器就断网，流量漏不出去。
- **关闭**：完全不拦截。出口守卫照常监测和提示（`docs/egress-guard.md`）。
- **每个改变状态的动作都要输管理员密码**：开启、保留、关闭，每次都弹系统密码框。本机任何进程（包括编码 agent）都不能悄悄改变防护。
- **不杀任何进程**，不针对 Claude 或任何别的 App。

## 2. 状态机

只有三种状态，记在 root 所有的状态文件里，只有 root 能改。LaunchDaemon 和脚本都照它办事。

| 状态 | 规则 | 怎么进入 | 怎么离开 |
|---|---|---|---|
| `off` | 不加载 | 安装后的初始状态；关闭（要密码）；试运行到期；开机时发现是 `trial` | 开启（要密码）→ `trial` |
| `trial(截止时间)` | 已加载 | 开启（要密码） | 保留（要密码）→ `on`；到截止时间 → `off`；开机 → `off`；关闭（要密码）→ `off` |
| `on` | 已加载 | 试运行期间点「保留」 | 关闭（要密码）；恢复脚本（直接卸掉全部） |

不变量：

- **只有 `trial` 和 `on` 会加载规则。** LaunchDaemon 每一轮都看状态文件，状态是 `off` 就卸掉规则，绝不重新加载。所以自动回滚一旦把状态改成 `off`，规则不会被装回来。
- **开机时 `trial` 一律当成 `off`。** 试运行期间重启，开机后不会带着没确认过的规则上线。
- **试运行到期由 root 的 LaunchDaemon 执行**，不靠 App，也不靠 osascript 的子进程。App 退出之后，到点照样回滚。LaunchDaemon 的 `StartInterval` 设为 10 秒，每轮幂等，回滚最多晚 10 秒左右。
- **截止时间按单调时钟算，不按墙上时间。** 试运行期间系统时间被往回调（手动改，或者 NTP 校时），也不能把回滚往后推。
- **App 只信新鲜的状态摘要。** 摘要带 `checkedAt`。超过 30 秒（3 个 `StartInterval`）没更新，就判「异常」，不能显示「已保护」。LaunchDaemon 被卸掉、崩溃，或者恢复脚本刚跑过，都会落到这种情况。
- **改变状态没有免密通道。** 如果 App 能以普通用户身份写一个文件去触发 root 动作，编码 agent 也能写同一个文件。

## 3. 安全底线：先能恢复，再谈拦截

防火墙写错会让整机断网，所以必须先有恢复手段（用户定）。下面三条任何一条没做到，就不写拦截规则。

1. **恢复脚本先行。** `scripts/firewall-rescue.sh` 是第一个交付物，比任何 block 规则都早。它按顺序做：
   1. `launchctl bootout system/<label>`。这一步必须最先做，否则 LaunchDaemon 会把规则装回去。
   2. `pfctl -a com.apple/300.Notchkeeper -F rules`，清空本防火墙的 anchor。
   3. 状态文件里记了 pf 启用 token 的，执行 `pfctl -X <token>` 释放。pf 已经停了时会报错，忽略即可。
   4. 删掉 LaunchDaemon 的 plist、特权脚本、状态文件和状态摘要。这一步等于卸载，想再用就重新安装。
   5. 打印 `pfctl -a com.apple/300.Notchkeeper -sr`（应为空）和 LaunchDaemon 的状态，供人核对。

   脚本本身的要求：
   - 不依赖网络、App 和已安装的防火墙脚本，自己就能跑。只用系统自带的 `launchctl`、`pfctl`，由用户在终端里 `sudo` 执行。
   - 可以重复执行；什么都没装时执行，也不报错、不改任何东西。
   - **默认不执行 `pfctl -d`。** 它会强制停掉整个 pf，连带作废别人的启用引用（互联网共享、AirDrop、应用防火墙、OrbStack 等，见第 6 节）。只有带 `--disable-pf` 时才执行，作为最后手段。

   **先验证再往下做**：在本机装一个只放行、不拦截的测试 anchor 和 LaunchDaemon，执行恢复脚本，确认两样都清掉了，开机也不会回来。过程记进第 7 节。通过之后才开始写 block 规则。
2. **试运行，到时自动回滚。** 每次开启都先进入 `trial`，App 显示倒计时和「保留」按钮；2 分钟内没点「保留」就回到 `off`（同网络设备的 commit confirmed：新规则把网弄断了，什么都不做也会自己恢复）。
3. **README 里写明逃生步骤**，并把恢复脚本的路径放在最前面。断网时没法上网查资料，必须本地就能看到。

**逃生办法**（规则把网弄坏时，按顺序试）：

1. 什么都不做：试运行期间，到截止时间会自动回滚。
2. 在 App 里关掉开关。这是本地操作，断网时也能用。
3. 终端执行 `sudo scripts/firewall-rescue.sh`。
4. 最后手段：`sudo scripts/firewall-rescue.sh --disable-pf`。

已经保留（状态为 `on`）之后，重启不能用来逃生：开机会重新加载规则，要先跑恢复脚本。

## 4. 设计

照搬 Mullvad VPN 的 macOS pf 防火墙（talpid-core `firewall/macos.rs`，提交 `33a63e2`），只写平台逼出来的偏差：

| | Mullvad | 我们 | 原因 |
|---|---|---|---|
| anchor 怎么挂上 | 私有 ioctl `DIOCINSERTRULE`，把顶层 anchor `mullvad` 插进主规则集 | `pfctl -a com.apple/300.Notchkeeper -f <file>`，挂在 `/etc/pf.conf` 已声明的 `anchor "com.apple/*"` 下 | shell 脚本做不到 ioctl。`com.apple/*` 按字母序求值，`300` 排在 Apple 的 `200.AirDrop`、`250.ApplicationFirewall` 之后 |
| 启用 pf | `DIOCSTART`，并记下原来是否已启用 | `pfctl -E` 拿 token 并落盘，关闭时 `pfctl -X <token>` 释放 | 用引用计数，不影响别人对 pf 的使用 |
| 放行隧道 | 按隧道接口放行 | 写死网卡名，默认 `utun1024`，可配置 | XNU 的 pf 没有接口组，`on utun` 什么都匹配不到 |
| 放行 relay | 只对 relay 地址放行 `user root` | 放行所有 `user root` 的 TCP/UDP | 不读 Clash 配置，拿不到节点地址 |
| 状态表 | 放行规则都 keep state | 回环和隧道两条 `no state`，其余照旧 | pf 状态表上限 10000 条（本机 `pfctl -sm`），只能在 `/etc/pf.conf` 里改；Clash 的每条连接同时走 utun 和 lo0，记状态会翻倍占用。这两条两个方向全放行，记不记状态结果一样 |
| DNS | 先拦 53 端口 | 同样拦：隧道以外、非 root 的 53 端口一律拦，局域网 DNS 也不放行 | 用户定：只用代理配置的 DNS |

规则草稿（上线前先用 `pfctl -nf <file>` 检查语法）：

```pf
tun  = "utun1024"
lan4 = "{ 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16 }"
mc4  = "{ 255.255.255.255, 224.0.0.0/24, 239.0.0.0/8 }"
lan6 = "{ fe80::/10, fc00::/7 }"
mc6  = "{ ff01::/16, ff02::/16, ff03::/16, ff04::/16, ff05::/16 }"
pass quick on lo0 no state
pass quick on $tun no state
pass out quick inet6 proto icmp6 icmp6-type { 133, 135, 136 }
pass in  quick inet6 proto icmp6 icmp6-type { 134, 135, 136, 137 }
pass out quick inet proto udp from any port 68 to 255.255.255.255 port 67
pass in  quick inet proto udp from any port 67 to any port 68
pass out quick proto { tcp, udp } all user root
block return out quick proto { tcp, udp } to any port 53
pass out quick to $lan4
pass in  quick from $lan4
pass out quick to $lan6
pass in  quick from $lan6
pass out quick to { $mc4, $mc6 }
block return out quick all
block drop   in  quick all
```

**特权部分**：
- 一个 root 所有的辅助程序 `/Library/PrivilegedHelperTools/notchkeeper-firewall`，Swift 编译（用户定，10-31）：状态机放纯值 target `FirewallCore` 用 `swift test` 测，`firewalld` 只做 I/O。截止时间用 `clock_gettime(CLOCK_MONOTONIC_RAW)`：man page 写明它「不受频率和时间调整影响」、睡眠也走（`CLOCK_MONOTONIC` 没这么写），开机归零，开机本来就把 `trial` 当 `off`。没选 shell 里的 `sysctl kern.monotonicclock_usecs`：XNU 注释说它只增不减、改不了（[clock.c](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/clock.c)），但没有文档。恢复脚本仍是纯 bash，不依赖它；
- 一个 LaunchDaemon（`RunAtLoad`，`StartInterval` 10），启动参数里写隧道网卡名，测试时加 `--test-rules`（§7）；
- 开启、保留、关闭三条命令只改状态文件，再 `launchctl kickstart` 让守护进程马上跑一轮：对 pf 做什么只在一轮里决定；
- 目录 `/Library/Application Support/Notchkeeper/`，所有者 root，权限 0755。普通用户进程不能在里面写文件，也就伪造不了状态摘要。
  - 状态文件 `firewall.state`，root 0600，JSON。恢复脚本从里面读 `token`（数字串）和 `bootSession`（`kern.bootsessionuuid`，每次开机都换；不用 `kern.boottime`，因为改系统时间时内核会跟着调它（推断），会被误判成重启）。读不出来时按 `off` 办、不覆盖，开启和保留被拒，要先跑恢复脚本；
  - 状态摘要 `firewall-status.json`，root 0644，记录模式、装的是正式规则还是测试规则、截止时间、核对结果、做失败的动作、`checkedAt`。只有正式规则才能显示「已保护」；
  - 锁文件 `firewall.lock`，root 0600：一轮和命令互斥。普通用户打不开它，也就锁不住、卡不死守护进程（锁目录本身不行：普通用户也能对 root 0755 的目录 `flock`，审查时实测）。每条子命令最多 5 秒，一轮总会结束。

LaunchDaemon 每一轮做这几件事：
1. 读 `pfctl -s References`：我们的 token 不在列表里（有人 `pfctl -d`，或者重启过），就当没有引用。读不出列表时照旧，不 `-E`、不释放。
2. 开机标识和状态文件里的不一样（重启过）：`trial` 改成 `off`。引用还在不在照第 1 步判，所以开机标识读错一次也不会多 `-E` 一个引用。
3. `mode` 不是 `off`：
   - 规则变了（换了隧道网卡名）或者 anchor 被清空了才加载：每次加载都换上一批新规则，Evaluations 从 0 数起，「在增长」就核对不了；
   - 没有引用就 `pfctl -E`，拿到 token 立刻落盘。这一轮状态文件写不进去时不 `-E`，否则记不下 token，下一轮又 `-E`；
   - 核对：pf 开着、主规则集里还有 `anchor "com.apple/*"`、本 anchor 有规则、Evaluations 在增长、TUN 网卡存在。
4. `mode` 是 `trial` 且已过截止时间：按 `off` 办。
5. `mode` 是 `off`：先清规则，再释放 pf 里还在的那个 token。
6. 写状态摘要 `firewall-status.json`，带上本轮的 `checkedAt`，给 App 显示。

**App**：
- 设置页只有一个开关、一行状态文字；试运行期间多一个「保留」按钮。
- 开启、保留、关闭都用 `osascript … with administrator privileges` 调用已安装的辅助程序（`enable` / `keep` / `disable`）。
- App 只读状态摘要，不常驻任何特权代码。

**为什么不用 SMAppService + XPC**：App 只有 ad-hoc 签名，每次构建 cdhash 都会变。系统的后台项目审批会失效，XPC 也没法可靠地校验调用方。以后有了开发者账号再迁过去。

## 5. 已知局限和待定

- **fail-open**：有人用 `pfctl -f` 换掉主规则集，或者执行了 `pfctl -d`，我们的 anchor 就不再生效，流量会悄悄放行。LaunchDaemon 每轮都核对（见第 4 节）；核对不过时，App 显示异常，不能显示「已保护」。
- **TUN 网卡名写错，或 Clash 改了网卡名**：会把所有流量都拦掉，属于往安全方向出错。状态摘要要能看出「TUN 网卡不存在」。
- **放行了 root 进程**：root 身份的守护进程仍可直连；以普通用户身份运行的 App（包括编码 agent）都会被拦。`user` 规则只匹配 TCP/UDP，ICMP 和转发的包匹配不到。
- **虚拟机**：OrbStack、vmnet 里的虚拟机访问外网时，流量是被拦还是走 utun，未证实。
- **状态表**：pf 状态表上限 10000 条（本机 `pfctl -sm`），只能在 `/etc/pf.conf` 里改。塞满后新连接被丢，表现就是断网。回环和隧道两条已改成 `no state`（§4 偏差表）；平时占多少条，装测试规则后用 `pfctl -si` 量。
- **空闲时 Evaluations 可能不涨**（推断）：已有状态的连接不走规则求值，10 秒内没有新连接时计数不动，App 会闪「异常」。装测试规则后实测。
- **token 号码复用**（推断）：token 像是内核地址变换出来的，我们的引用被 `pfctl -d` 作废后，号码可能分给别人的新引用，第 1 步会把它当成我们的，关闭时释放掉别人的引用。概率很低，没处理。
- **sudo 缓存**：一个终端 sudo 过之后的几分钟内，这个终端里的进程可以免密码执行 `sudo pfctl -d`。建议不在跑 agent 的终端里用 sudo，用完执行 `sudo -k`。
- **DNS**（用户定：只用代理配置的 DNS）：
  - 规则顺序是：先放行隧道，再放行 root，然后拦掉其余所有去 53 端口的流量，最后才放行局域网。
    - 走隧道的 DNS 照常可用，由 Clash 按代理配置解析。
    - Clash 内核以 root 身份解析代理节点的域名，照常可用。
    - 去路由器、去局域网的 53 端口都被拦，查询不会绕过代理泄露给运营商或路由器。
  - 本机现状（`scutil --dns`）：系统 DNS 是公网地址，`route -n get` 显示它走 `utun1024`，所以开启后解析照常。
  - 风险：换到一个用 DHCP 把系统 DNS 设成路由器地址的网络时，防火墙开着就解析不了，表现为「有网但打不开网页」。这是往安全方向出错。状态摘要要检查：系统 DNS 指向局域网地址时，提示「系统 DNS 指向局域网，开着防火墙时无法解析，请在 Clash 里设置系统 DNS」。
  - mDNS（5353 端口）、DHCP 不受影响。
- **防火墙开着时守卫判 violated**（用户定）：
  - 颜色的含义不变：violated 就是红色，不新增颜色，也不借用琥珀色。
  - 前提是防火墙状态摘要新鲜，并且三项核对都通过（见第 4 节）。这时：
    - 红卡的图标从警告换成锁；
    - 文案是「代理断开，防火墙已拦住外网 · 没有泄漏」；
    - 不响 Basso，因为没有泄漏，只是需要你去修 Clash。
  - 摘要不新鲜，或者核对没通过，就照普通 violated 处理：红卡、警告图标、响 Basso。

## 6. 资料和还要实测的

已查清（macOS 26.5）：
- **接口组**：XNU 的 `pfi_kif_match` 只比较指针，所以没有接口组。kif 按名字绑定，`utun1024` 删除后重建，规则会自动重新挂上（[pf_if.c L224](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/net/pf_if.c#L224)）。
- **`user root`**：IPv4、IPv6 的 TCP/UDP 都能匹配（`man pf.conf`；[pf.c L4136](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/net/pf.c#L4136)）。
- **`com.apple/*`**：本机 `/etc/pf.conf` 是系统默认内容，开机时由 `com.apple.pfctl` 载入。Clash 不使用 pf。本机 pf 平时就是启用的：系统的 `pfd`（`com.apple.pfd`）拿着一个引用，进程早已退出、引用还在（实测，10-31）。
- **token**：引用计数归零时才真正停掉 pf；`pfctl -d` 会强制停掉 pf 并作废所有人的 token；进程退出不会释放 token（上面的 `pfd` 实测）；重启后 token 全部丢失（推断）（[pf_ioctl.c L1615](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/net/pf_ioctl.c#L1615)）。
- **osascript 管理员权限**：以 root 运行（TN2065）。后台子进程在 osascript 返回后能否存活，官方没有说明，所以试运行计时不交给它。
- Mullvad 源码：[talpid-core/src/firewall/macos.rs @ 33a63e2](https://github.com/mullvad/mullvadvpn-app/blob/33a63e2916adf294d3b4332c4274e2aa1cb1f811/talpid-core/src/firewall/macos.rs)

root 实测（`scripts/firewall-drill.sh`，10-31）：
- `pfctl -E`：stdout 为空，token 在 stderr 的一行 `Token : <数字>`；`pfctl -X` 释放后提示还剩几个引用。
- `pfctl -s References`：每行一个引用，列出 PID、进程名、token、拿了多久。
- 子 anchor 里的规则 Evaluations 会涨，规则匹配不到包也照样计数。
- 对还不存在的 anchor 执行 `pfctl -a … -sr`：退出码 0，stdout 为空。
- `pfctl -sm`：`states hard limit 10000`；`pfctl -si` 装测试规则前 `current entries 0`。
- `pfctl -sr`（主规则集）：anchor 点是一行 `anchor "com.apple/*" all`；开着互联网共享时还有 `anchor "com.apple.internet-sharing" all`。
- pfctl 每条命令都往 stderr 打「No ALTQ support in kernel」「ALTQ related functions disabled」，不是错误。

还没测：规则用 `block return` 时，断开 Clash 后浏览器能不能很快报错。

## 7. 实机验收

要等用户自己安装后才能做，按这个顺序：

**测试时不能真的断网（用户定，10-31）**：整机拦截的规则在测试中一次都不加载。真实流量上的验证用「测试规则」：和正式规则只差两处，所有 block 只拦一个测试用户（`nobody`），隧道网卡名换成不存在的名字来模拟 Clash 断开；然后 `sudo -u nobody curl …`、`dig` 看拦没拦，本机其他进程照常上网。不用 `pfctl -d`：它会作废系统 `pfd` 的引用。

**本机不能重启（用户定，10-31）**，凡是要重启的验收都换成「模拟开机」：开机时内核里的 pf 规则和 token 全丢、launchd 按 `/Library/LaunchDaemons` 里现有的 plist 重新加载守护进程（[launchd(8)](https://keith.github.io/xcode-man-pages/launchd.8.html)）。所以模拟时清空本 anchor、`pfctl -X` 释放自己的 token、把状态文件的 `bootSession` 改成别的值，再 `launchctl bootout` + `bootstrap`。真开机时 launchd 会不会加载 `/Library/LaunchDaemons` 里的 plist，只靠 Apple 文档，不实测。

1. **恢复脚本**：装上测试 anchor 和 LaunchDaemon，执行恢复脚本，确认都清掉了；核对开机时会读的地方都没有它（`/etc/pf.conf`、`/etc/pf.anchors/`、`/Library/LaunchDaemons`、launchd 的 `disabled.plist`、后台项目登记 `BackgroundItems-v*.btm`）；什么都没装时再跑一次，每步都是「跳过」。
2. **试运行**：开启后不点「保留」，确认到时间自动关闭、外网恢复；试运行期间模拟开机，之后状态是 `off`。
3. **测试规则下模拟 Clash 断开**：`nobody` 的外网 `curl` 立刻失败（`block return`），局域网照样通，去 53 端口的 `dig` 被拦；用户自己的进程照常上网。隧道网卡名换回 `utun1024` 后，`nobody` 也能走隧道上网。
4. **关闭后**：`nobody` 直连恢复，anchor 为空。
5. **`on` 状态下模拟开机**：之后防护仍在。
6. **fail-open 检测**：不在实机上停 pf；核对逻辑吃 `pfctl` 的输出，用 `swift test` 喂「anchor 点不见了」「计数不涨」「网卡不存在」几种输出来测。

每一步的命令和结果都记在这里。

- 第 1 步（10-31）：`sudo scripts/firewall-drill.sh` 装上假防火墙，手动清空 anchor 后 11 秒内被守护进程装回；`sudo scripts/firewall-rescue.sh` 依次 bootout、清 anchor、`pfctl -X` 释放自己的引用（`pfd` 的引用留着，pf 仍启用）、删文件，核对全过，目录也删掉了。开机会读的地方都没有它：`/etc/pf.conf` 和 `/etc/pf.anchors/com.apple` 只有 Apple 的 anchor，`/Library/LaunchDaemons`、`disabled.plist` 里没有，`BackgroundItems-v16.btm` 在恢复脚本跑完后更新过、只剩 guardd。什么都没装时再跑一次：第 1 到 3 步都是「跳过」，第 4 步没东西可删，核对全过。**第 1 步通过。**
