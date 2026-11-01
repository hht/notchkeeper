# 防火墙（断网保护）

进度见 `HANDOFF.md`。

## 1. 要做什么

只有一个开关：**开启时全部防护生效，关闭时全部不生效**。没有分项开关，也不针对哪个 App。

- **开启**：除局域网、Clash 内核自己直连的地址（节点、它的 DNS 上游）和国内 IP 段外，所有不走 Clash 隧道（utun）的出站流量一律丢弃，IPv4 和 IPv6 都包括。Clash 一断，整台机器就只能连国内，流量漏不到境外。
- **关闭**：完全不拦截。出口守卫照常监测和提示（`docs/egress-guard.md`）。
- **每个改变状态的动作都要输管理员密码**：开启、保留、关闭，每次都弹系统密码框。本机任何进程（包括编码 agent）都不能悄悄改变防护。
- **不杀任何进程**，不针对 Claude 或任何别的 App。

## 2. 状态机

只有三种状态，记在 root 所有的防火墙状态文件里，只有 root 能改。LaunchDaemon 和脚本都照它办事。

| 状态 | 规则 | 怎么进入 | 怎么离开 |
|---|---|---|---|
| `off` | 不加载 | 安装后的初始状态；关闭（要密码）；试运行到期；开机时发现是 `trial` | 开启（要密码）→ `trial` |
| `trial(截止时间)` | 已加载 | 开启（要密码） | 保留（要密码）→ `on`；到截止时间 → `off`；开机 → `off`；关闭（要密码）→ `off` |
| `on` | 已加载 | 试运行期间点「保留」 | 关闭（要密码）；恢复脚本（直接卸掉全部） |

不变量：

- **只有 `trial` 和 `on` 会加载规则。** LaunchDaemon 每一轮都看防火墙状态文件，状态是 `off` 就卸掉规则，绝不重新加载。所以自动回滚一旦把状态改成 `off`，规则不会被装回来。
- **开机时 `trial` 一律当成 `off`。** 试运行期间重启，开机后不会带着没确认过的规则上线。
- **试运行到期由 root 的 LaunchDaemon 执行**，不靠 App，也不靠 osascript 的子进程。App 退出之后，到点照样回滚。守护进程在 `trial` 和 `on` 时每 10 秒跑一轮（每轮幂等，回滚最多晚 10 秒左右），回到 `off` 跑完那一轮就退出，`off` 时什么都不跑（用户定，10-31：不做没必要的轮询）。
- **截止时间按单调时钟算，不按墙上时间。** 试运行期间系统时间被往回调（手动改，或者 NTP 校时），也不能把回滚往后推。
- **App 只信新鲜的状态摘要。** 摘要带 `checkedAt`。说 `trial` / `on` 的摘要超过 30 秒（3 轮）没更新，就判「异常」，不能显示「已保护」。LaunchDaemon 被卸掉、崩溃，或者恢复脚本刚跑过，都会落到这种情况。说 `off` 的摘要不看新不新鲜：`off` 时守护进程本来就不跑。
- **改变状态没有免密通道。** 如果 App 能以普通用户身份写一个文件去触发 root 动作，编码 agent 也能写同一个文件。

## 3. 安全底线：先能恢复，再谈拦截

防火墙写错会让整机断网，所以必须先有恢复手段（用户定）。下面三条任何一条没做到，就不写拦截规则。

1. **恢复脚本先行。** `scripts/firewall-rescue.sh` 是第一个交付物，比任何 block 规则都早。它按顺序做：
   1. 删掉 LaunchDaemon 的 plist 和辅助程序。只动文件、不碰 pf：pf 在内核里卡死时（§5）后面每一步都可能卡住，做完这一步，重启一定恢复；辅助程序没了，守护进程也起不来、装不回规则。
   2. `launchctl bootout system/<label>`，停掉还在跑的守护进程。
   3. `pfctl -a com.apple/300.Notchkeeper -F rules`，清空本防火墙的 anchor（放行表不带 `persist`，跟着规则一起没了）。
   4. 防火墙状态文件里记了本次开机的 pf 启用 token 的，执行 `pfctl -X <token>` 释放。pf 已经停了时会报错，忽略即可。
   5. 删掉其余文件（防火墙状态文件、状态摘要、锁、放行表）。这一步等于卸载，想再用就重新安装。最后打印 anchor 规则（应为空）和 LaunchDaemon 的状态，供人核对。

   每条 `launchctl` / `pfctl` 都限时（输出写进文件、超时不再等它）：卡住时不卡终端，跳过后面的 pf 步骤，提示重启。

   脚本本身的要求：
   - 不依赖网络、App 和已安装的防火墙脚本，自己就能跑。只用系统自带的 `launchctl`、`pfctl`。设置 › 防火墙的「卸载」跑的就是它（经管理员密码框），App 打不开时在终端里 `sudo` 执行同一份。
   - 可以重复执行；什么都没装时执行，也不报错、不改任何东西。
   - **默认不执行 `pfctl -d`。** 它会强制停掉整个 pf，连带作废别人的启用引用（互联网共享、AirDrop、应用防火墙、OrbStack 等，见第 6 节）。只有带 `--disable-pf` 时才执行，作为最后手段。

   **先验证再往下做**：在本机装一个只放行、不拦截的测试 anchor 和 LaunchDaemon，执行恢复脚本，确认两样都清掉了，开机也不会回来。过程记进第 7 节。通过之后才开始写 block 规则。
2. **试运行，到时自动回滚。** 每次开启都先进入 `trial`，App 显示倒计时和「保留」按钮；2 分钟内没点「保留」就回到 `off`（同网络设备的 commit confirmed：新规则把网弄断了，什么都不做也会自己恢复）。
3. **README 里写明逃生步骤**，并把恢复脚本的路径放在最前面。断网时没法上网查资料，必须本地就能看到。

**逃生办法**（规则把网弄坏时，按顺序试）：

1. 什么都不做：试运行期间，到截止时间会自动回滚。
2. 在 App 里关掉开关，或者「卸载」。这是本地操作，断网时也能用。
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
| 放行 relay | 只对 relay 地址放行 `user root` | 按目的地址放行表 `<clash>`：节点和 mihomo 的 DNS 上游，不带 `user` | `user` / `group` 会让 pf 内核死锁（§5），只能按地址认 |
| 直连 | 没有 | 放行表 `<cn>`：国内 IP 段 | mihomo 的 DIRECT（`GEOIP,CN,DIRECT` 等）从物理网卡直连任意地址，不放行国内段就全不通；这些地址开着 Clash 时本来就直连（用户定，10-31） |
| 状态表 | 放行规则都 keep state | 回环和隧道两条 `no state`，其余照旧 | pf 状态表上限 10000 条（本机 `pfctl -sm`），只能在 `/etc/pf.conf` 里改；Clash 的每条连接同时走 utun 和 lo0，记状态会翻倍占用。这两条两个方向全放行，记不记状态结果一样 |
| DNS | 先拦 53 端口 | 同样拦：隧道以外、不去 `<clash>` 的 53 端口一律拦，局域网和国内 DNS 也不放行 | 用户定：只用代理配置的 DNS |

规则草稿（上线前先用 `pfctl -nf <file>` 检查语法）：

```pf
tun  = "utun1024"
lan4 = "{ 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16 }"
mc4  = "{ 255.255.255.255, 224.0.0.0/24, 239.0.0.0/8 }"
lan6 = "{ fe80::/10, fc00::/7 }"
mc6  = "{ ff01::/16, ff02::/16, ff03::/16, ff04::/16, ff05::/16 }"
table <clash> file "/Library/Application Support/Notchkeeper/clash.table"
table <cn> file "/Library/Application Support/Notchkeeper/cn.table"
pass quick on lo0 no state
pass quick on $tun no state
pass out quick inet6 proto icmp6 icmp6-type { 133, 135, 136 }
pass in  quick inet6 proto icmp6 icmp6-type { 134, 135, 136, 137 }
pass out quick inet proto udp from any port 68 to 255.255.255.255 port 67
pass in  quick inet proto udp from any port 67 to any port 68
pass out quick to <clash>
block return out quick proto { tcp, udp } to any port 53
pass out quick to <cn>
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
- 一个 LaunchDaemon（`RunAtLoad`，`KeepAlive` 只在非正常退出时拉起，`ThrottleInterval` 1），启动参数里写隧道网卡名，测试时加 `--test-rules`（§7）。没有 `StartInterval`：守护进程自己循环，`trial` / `on` 时每 10 秒一轮，`off` 跑完一轮就正常退出；崩了由 launchd 拉起接着跑（试运行照样到期回滚）。launchd 默认同一个服务 10 秒内只启动一次，不调小的话开启时的 `kickstart` 要等到 10 秒后（实测 8～9 秒）；
- 开启、保留、关闭三条命令只改文件，还拿着锁时 `launchctl kickstart -k` 重启守护进程（这时它不可能在一轮当中，杀掉不会断在 `pfctl -E` 和落盘之间），新起的那个等到锁马上跑一轮：对 pf 做什么只在一轮里决定。回到 `off` 那一轮清规则或释放引用失败时守护进程不退出，下一轮重做，免得没人再清；
- **开启时拍放行表的快照**（用户定，10-31）：`clash-verge.yaml` 和 `Country.mmdb` 在用户目录里，任何以用户身份运行的进程都改得了；守护进程每轮直接读它们，改文件就等于免密打开防火墙。所以只有开启命令（要密码）读一次 Clash Verge 的运行时配置（mihomo 用 `-f` 加载的 `clash-verge.yaml`），算出两张表写进 root 目录，守护进程只装这两个文件，从不读用户目录：
  - `<clash>`：节点的 `server`（域名用系统的 `dig` 问 `proxy-server-nameserver` 里写成 IP 的明文 UDP 上游，就是 mihomo 自己查节点走的那条路；本机它指向 mihomo 的 DNS 监听口，`hosts` 换名由 mihomo 做。查不到、或答案落在 `fake-ip-range` 里就拒绝开启），加上 mihomo 直连的 DNS 上游（`default-nameserver`、`nameserver`、`fallback`、`proxy-server-nameserver`、`direct-nameserver`）里写成 IP 的那些；写成域名的 DoH / DoT 上游只有落在国内段里才通；
  - `<cn>`：mihomo 的 GEOIP 数据 `Country.mmdb` 里 `country.iso_code` 是 `CN` 的全部网段（mihomo 默认 `geodata-mode: false` 就用它判 `GEOIP,CN`）；一段都没有就拒绝开启；
  - 用户目录里的文件是外部数据：不跟符号链接、只读普通文件、有大小上限；解 mmdb 的解码量不超过文件大小，构造过的库（节点成环、指针套指针、很多记录指向同一个大值）报错而不是卡住；域名节点有个数上限，没回应的 DNS 上游问一次就不再问；
  - 两张表合计有项数上限：pf 的表项是全系统共用的，超了装不上，也给开启的内存和耗时封顶；
  - 国内段要像一个国家：合起来不超过 IPv4 的 1/8、IPv6 的 2^-14，否则拒绝开启（库被改成大半个互联网都算 CN 时，正式规则等于不拦）；
  - 节点 IP 变了、订阅换了，Clash 会连不上（往安全方向出错），关掉再开一次就重拍快照。不定时重新解析（用户定，10-31：不做没必要的轮询）；
- 目录 `/Library/Application Support/Notchkeeper/`，所有者 root，权限 0755。普通用户进程不能在里面写文件，也就伪造不了状态摘要。
  - 防火墙状态文件 `firewall.state`，root 0600，JSON。恢复脚本从里面读 `token`（数字串）和 `bootSession`（`kern.bootsessionuuid`，每次开机都换；不用 `kern.boottime`，因为改系统时间时内核会跟着调它（推断），会被误判成重启；不知道是哪次开机的就不写这个字段，恢复脚本读不到就不释放）。读不出来时按 `off` 办、不覆盖，开启和保留被拒，要先跑恢复脚本；
  - 状态摘要 `firewall-status.json`，root 0644，记录模式、装的是正式规则还是测试规则、截止时间、核对结果、做失败的动作、`checkedAt`。只有正式规则才能显示「已保护」；
  - 两张放行表 `clash.table`、`cn.table`，root 0644，每行一个地址或网段，规则用 `table <…> file` 引用，装规则时一起装进 pf；不带 `persist`，清规则时表跟着没；
  - 锁文件 `firewall.lock`，root 0600：一轮和命令互斥。普通用户打不开它，也就锁不住、卡不死守护进程（锁目录本身不行：普通用户也能对 root 0755 的目录 `flock`，审查时实测）。每条子命令最多 5 秒，一轮总会结束。

LaunchDaemon 每一轮做这几件事：
1. 读 `pfctl -s References`：我们的 token 不在列表里（有人 `pfctl -d`，或者重启过），就当没有引用。读不出列表时照旧，不 `-E`、不释放；开机标识变了的那一轮例外，见第 2 步。
2. 开机标识和防火墙状态文件里的不一样（重启过）：`trial` 改成 `off`。引用只有第 1 步的列表读得出、并且里面有我们的 token 才留，所以开机标识读错一次也不会多 `-E` 一个引用；列表读不出就当没有：旧 token 不能配上新开机标识落盘，恢复脚本会把它当成本次开机的去释放。开启、保留两条命令不读列表，开机后旧 token 一律作废。读不出开机标识时不知道换没换开机：`trial` 照样改成 `off`，引用和记下的开机标识不动，开启、保留直接报错。
3. `mode` 不是 `off`：
   - 规则变了（换了隧道网卡名）或者 anchor 被清空了才加载：每次加载都换上一批新规则，Evaluations 从 0 数起，「在增长」就核对不了；
   - 没有引用就 `pfctl -E`，拿到 token 立刻落盘。这一轮防火墙状态文件写不进去时不 `-E`，否则记不下 token，下一轮又 `-E`；
   - 核对：pf 开着、主规则集里还有 `anchor "com.apple/*"`、本 anchor 有规则、Evaluations 在增长、TUN 网卡存在。
4. `mode` 是 `trial` 且已过截止时间：按 `off` 办。
5. `mode` 是 `off`：先清规则，再释放 pf 里还在的那个 token。
6. 写状态摘要 `firewall-status.json`，带上本轮的 `checkedAt`，给 App 显示。

**App**：
- 安装、卸载在设置 › 防火墙，装的是正式规则。用户是普通用户，看不懂哈希、plist 和 pf 规则，所以不给人看 dry-run：确认框用一句话说清会发生什么，点了经管理员密码框以 root 跑。包里带一份辅助程序和两份脚本，拷到 `/private/tmp`（提权进程读不了 `~/Documents`）；root 先把脚本拷进自己的临时目录、核对拷出来时的哈希，安装脚本再核对辅助程序的哈希：拷出来之后被换过就停。卸载就是跑恢复脚本，和断网时在终端里跑的同一份。App 包本身在用户目录里、同一个用户改得了，哈希只防「拷出来之后被换」，防不了包被改过。安装脚本的 `--dry-run` 留给开发时在终端里看会装什么。
- 设置页只有一个开关、一行状态文字（`FirewallReading`）；试运行期间多一行倒计时和「保留」按钮。试运行出了问题（网卡不在、核对没过、规则没装上）时「保留」不能点：这时保留就是把断网锁成重启也在，什么都不做等它到期回滚才对。设置窗口看得见时每 2 秒重读状态摘要，被遮挡、最小化、关掉时不读。
- 开启、保留、关闭都用 `osascript … with administrator privileges` 调用已安装的辅助程序（`enable` / `keep` / `disable`）。
- App 只读状态摘要，不常驻任何特权代码。

**为什么不用 SMAppService + XPC**：App 只有 ad-hoc 签名，每次构建 cdhash 都会变。系统的后台项目审批会失效，XPC 也没法可靠地校验调用方。以后有了开发者账号再迁过去。

## 5. 已知局限和待定

- **fail-open**：有人用 `pfctl -f` 换掉主规则集，或者执行了 `pfctl -d`，我们的 anchor 就不再生效，流量会悄悄放行。LaunchDaemon 每轮都核对（见第 4 节）；核对不过时，App 显示异常，不能显示「已保护」。
- **TUN 网卡名写错，或 Clash 改了网卡名**：会把所有流量都拦掉，属于往安全方向出错。状态摘要要能看出「TUN 网卡不存在」。网卡名只收 `utun` 加数字：写成 `en0` 这类真实存在的物理网卡时，放行隧道那一条会把物理网卡上的流量全放行，核对照样过（第一轮审查指出）。写成别的 VPN 或系统服务正在用的 utun 时，走那块网卡的流量也放行（推断，没处理）。
- **`user` / `group` 规则会让 pf 内核死锁，只能重启**（10-31 实机出过事故，§7）：带 `user` / `group` 的规则让 pf 在持有 `pf_lock` 时调 `pf_socket_lookup` 去拿 PCB 表锁，与 TCP 栈的锁序相反；死锁后所有包和所有 pf ioctl 都卡在 `pf_lock` 上，用户态没有任何办法恢复。所以规则里永远不写 `user` / `group`（`RulesTests` 守着）；pf 一直响应，恢复脚本（App 里的「卸载」跑的就是它）就总能完全恢复。
- **放行了国内段和 Clash 直连的地址**：Clash 断了以后，任何进程都还能直连国内 IP 和 `<clash>` 里的地址。这些地址开着 Clash 时本来就是直连；按域名走 DIRECT、目的地址又不在国内的连接，开着防火墙时不通。快照是开启时的样子：之后有人改了 `Country.mmdb`，要关掉再开才生效，反过来开启前就被改过的 mmdb 也会照单全收（开启时打印两张表各多少条，供人核对）。
- **虚拟机**：OrbStack、vmnet 里的虚拟机访问外网时，流量是被拦还是走 utun，未证实。
- **状态表**：pf 状态表上限 10000 条（本机 `pfctl -sm`），只能在 `/etc/pf.conf` 里改。塞满后新连接被丢，表现就是断网。回环和隧道两条已改成 `no state`（§4 偏差表）；装测试规则实测（10-31）：开着时占 91 条。
- **token 号码复用**（推断）：token 像是内核地址变换出来的，我们的引用被 `pfctl -d` 作废后，号码可能分给别人的新引用，第 1 步会把它当成我们的，关闭时释放掉别人的引用。概率很低，没处理。
- **认不出号码的引用释放不了**：`pfctl -E` 给的号码认不出，或者紧接着读的引用列表里没有它（两边格式对不上），就不再记号码，免得每轮多拿一个引用。这个引用一轮和恢复脚本都释放不了，pf 会一直多一个我们的引用，直到重启或有人 `pfctl -d`；状态摘要里看不出来。
- **sudo 缓存**：一个终端 sudo 过之后的几分钟内，这个终端里的进程可以免密码执行 `sudo pfctl -d`。建议不在跑 agent 的终端里用 sudo，用完执行 `sudo -k`。
- **DNS**（用户定：只用代理配置的 DNS）：
  - 规则顺序是：先放行隧道，再放行 `<clash>`，然后拦掉其余所有去 53 端口的流量，最后才放行国内段和局域网。
    - 走隧道的 DNS 照常可用，由 Clash 按代理配置解析。
    - mihomo 直连自己的 DNS 上游（`<clash>` 里的 IP 上游；DoH、DoT 上游走 443 / 853，在国内段里就通），照常可用。
    - 去路由器、去局域网、去其余国内 DNS 的 53 端口都被拦，查询不会绕过代理泄露给运营商或路由器。
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
- **`user` / `group` 的死锁**（锁边都在 XNU 源码核实，完整死锁环是推断；xnu-12377.1.9）：规则匹配到 `user` / `group` 那一项时调 `pf_socket_lookup`，进站、出站都去 `in_pcblookup_hash_exists` 查 PCB 表（[pf.c L4136](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/net/pf.c#L4136)、L5327），此时持有 `pf_lock`；TCP 定时器持有 PCB 表锁再发包进 pf（`tcp_timer.c:2988`、`tcp_output.c:3665`）。外部证据：[PIA desktop PR #107](https://github.com/pia-foss/desktop/pull/107)（macOS 上 `group` 规则同一个锁环，要断电重启）、[FreeBSD pf.conf(5) BUGS](https://man.freebsd.org/cgi/man.cgi?query=pf.conf&sektion=5&manpath=FreeBSD+6.0-RELEASE)。
- **`block return` 和表查找不碰 PCB 锁**：回 RST 的 `pf_send_tcp` 在持有 `pf_lock` 时直接 `ip_output`，再进 pf 时 `pf_af_hook` 靠 `NET_THREAD_HELD_PF` 标记不重复加锁（[pf_ioctl.c L4628](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/net/pf_ioctl.c#L4628)）；表是 pf 自己的 radix 树。
- **mihomo**（Clash Verge 自带的 v1.19.21）：GEOIP 不开 `geodata-mode` 时查 `Country.mmdb`，GeoLite2 类型的库取 `country.iso_code` 转小写比较（[component/mmdb/reader.go](https://github.com/MetaCubeX/mihomo/blob/Meta/component/mmdb/reader.go)）；`/proxies` API 不含节点地址（[adapter/outbound/base.go](https://github.com/MetaCubeX/mihomo/blob/Meta/adapter/outbound/base.go)），所以读配置不走 API。本机实测（10-31）：订阅已经展开在 `clash-verge.yaml` 的 `proxies` 里（没有 `proxy-providers`），节点都写域名，`hosts` 把它们映射到别的域名；向 `dns.listen` 查节点域名拿到的是真地址，不是 fake-ip。
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

装测试规则实测（`scripts/firewall-test.sh`，10-31）：
- `pfctl -s References` 里我们那一行的进程名是 `pfctl`（执行 `-E` 的进程），不是辅助程序：进程名认不出哪个引用是我们的。
- 本 anchor 的 Evaluations 空闲时也在涨（20 秒从 1.7 万涨到 7.6 万）：Clash 的 utun 上一直有新包，核对不会因为「计数不涨」误报。
- `block return` 拦住走 utun 的 TCP 时，`curl` 等满超时（8 秒）才失败，不是立刻报错（推断：回的 RST 进了 Clash 的 TUN 网卡）。直连 DNS 的 `dig` 3 秒超时。

## 7. 实机验收

要等用户自己安装后才能做，按这个顺序：

**测试时不能真的断网（用户定，10-31）**：整机拦截的规则在测试中一次都不加载。真实流量上的验证用「测试规则」：和正式规则只差两处，所有 block 只拦去测试表 `<test>`（一个境外测试地址）的流量，隧道网卡名换成不存在的名字来模拟 Clash 断开；然后 `curl`、`dig` 这个地址看拦没拦，去别处的流量走 anchor 末尾、照常上网。不再用「只拦 `nobody`」：`user` 规则会让 pf 死锁（§5）。不用 `pfctl -d`：它会作废系统 `pfd` 的引用。

**会动 pf 的实机测试，先把要做的事给用户看、拿到当轮同意**（10-31 事故后）。

**本机不能重启（用户定，10-31）**，凡是要重启的验收都换成「模拟开机」：开机时内核里的 pf 规则和 token 全丢、launchd 按 `/Library/LaunchDaemons` 里现有的 plist 重新加载守护进程（[launchd(8)](https://keith.github.io/xcode-man-pages/launchd.8.html)）。所以模拟时清空本 anchor、`pfctl -X` 释放自己的 token、把防火墙状态文件的 `bootSession` 改成别的值，再 `launchctl bootout` + `bootstrap`。真开机时 launchd 会不会加载 `/Library/LaunchDaemons` 里的 plist，只靠 Apple 文档，不实测。

1. **恢复脚本**：装上测试 anchor 和 LaunchDaemon，执行恢复脚本，确认都清掉了；核对开机时会读的地方都没有它（`/etc/pf.conf`、`/etc/pf.anchors/`、`/Library/LaunchDaemons`、launchd 的 `disabled.plist`、后台项目登记 `BackgroundItems-v*.btm`）；什么都没装时再跑一次，每步都是「跳过」。
2. **试运行**：开启后不点「保留」，确认到时间自动关闭、外网恢复；试运行期间模拟开机，之后状态是 `off`。
3. **测试规则下模拟 Clash 断开**：测试地址连不上（`block return` 下 TCP 也要等满超时，§6），`dig @<测试地址>` 被拦；去别处的流量照常。隧道网卡名换回 `utun1024` 后，测试地址也能走隧道连上。
4. **关闭后**：测试地址恢复，anchor 为空。
5. **`on` 状态下模拟开机**：之后防护仍在。
6. **fail-open 检测**：不在实机上停 pf；核对逻辑吃 `pfctl` 的输出，用 `swift test` 喂「anchor 点不见了」「计数不涨」「网卡不存在」几种输出来测。

每一步的命令和结果都记在这里。第 2～5 步由 `sudo scripts/firewall-test.sh` 一次跑完（第 3 步的「换回 utun1024」是重装）。

- 第 1 步（10-31）：`sudo scripts/firewall-drill.sh` 装上假防火墙，手动清空 anchor 后 11 秒内被守护进程装回；`sudo scripts/firewall-rescue.sh` 依次 bootout、清 anchor、`pfctl -X` 释放自己的引用（`pfd` 的引用留着，pf 仍启用）、删文件，核对全过，目录也删掉了。开机会读的地方都没有它：`/etc/pf.conf` 和 `/etc/pf.anchors/com.apple` 只有 Apple 的 anchor，`/Library/LaunchDaemons`、`disabled.plist` 里没有，`BackgroundItems-v16.btm` 在恢复脚本跑完后更新过、只剩 guardd。什么都没装时再跑一次：第 1 到 3 步都是「跳过」，第 4 步没东西可删，核对全过。**第 1 步通过。**
- 第 2～5 步（10-31，`scripts/firewall-test.sh`，测试规则）：41 项通过。试运行开启后 125 秒自动回到 off，规则清空、引用释放、`nobody` 恢复上网；隧道网卡名为不存在的 `utun9999` 时 `nobody` 的外网和直连 DNS 被拦，本用户、局域网照常；试运行中模拟开机后是 off、不再拿引用；`on` 时模拟开机后规则和引用都回来；关闭后 anchor 为空、引用释放；重装成 `utun1024` 后 `nobody` 走隧道能上网。没过的：开启、保留、关闭里的 `kickstart` 每次都超过 5 秒被结束、命令报错（状态已写进去，守护进程几秒内自己跑了那一轮），原因是 launchd 的启动节流，plist 加 `ThrottleInterval` 1 后复测通过（见下面重做的那条）。
- 第 1 步重做（10-31 晚，事故后的新版恢复脚本：先删开机会加载的文件、每条命令限时）：用户当轮明确让 agent 执行（「你来帮我执行」），agent 用 osascript 提权、用户输密码，`firewall-drill.sh` 装假防火墙后紧接着跑 `firewall-rescue.sh`。演练：pf 原来就开着（只有 `pfd` 的引用），`-E` 拿到引用，anchor 的 Evaluations 10 秒从 295 涨到 5468，手动清空后 11 秒内被装回。恢复脚本依次删 plist 和辅助程序、bootout、清 anchor、`-X` 释放自己的引用（`pfd` 的留着）、删其余文件，核对全过，退出码 0，目录也删了，网络照常。什么都没装时再跑一次：每步都是「跳过」，退出码 0。**新版第 1 步通过。**
- 第 2～5 步重做（10-31 晚，新测试规则：只拦去测试表的流量，测试地址用境外公共 DNS；用户当轮明确让 agent 执行，agent 用 osascript 提权、`SUDO_USER` 指向用户）：**44 项全过**。开启时 root 读得了用户的 Clash Verge 目录、拍快照成功，测试地址不在 `<cn>` / `<clash>` 里；隧道网卡不存在时测试地址的 443 被拦（`block return` 下 `nc` 等满 8 秒）、53 被拦，去别处照常；试运行 121 秒后自动回到 off、规则清空、引用释放；试运行中模拟开机后是 off；`on` 时模拟开机后规则和引用都回来；关闭后守护进程退出（off 时不轮询）；重装成 `utun1024` 后测试地址走隧道能连上。开启、保留、关闭的 `kickstart` 没再超时（`ThrottleInterval` 1 起作用）。空闲 20 秒 Evaluations 从 6.5 万涨到 13.8 万；状态表 39 条。跑完用恢复脚本卸干净，网络全程正常。第一次跑时安装脚本的语法检查在 bash 3.2 下把表文件路径拼坏、装之前就停了（什么都没改），已修并加测试。还没实测：真开机（只模拟过）、守护进程崩溃后被 `KeepAlive` 拉起、`-F rules` 后表是否跟着消失（`pfctl -s Tables`）。
- App 的提权路径（10-31 晚，用户当轮让 agent 执行，osascript 提权、用户输密码；命令照 `FirewallInstaller` 逐字拼）：包里的辅助程序和两份脚本拷到 `/private/tmp`，以 root、干净环境、核对哈希跑。先用恢复脚本卸掉用户 17:16 在 App 里装的正式规则（关着），装测试规则（测试地址用文档保留段，隧道 `utun1024`）→ 开启（试运行，`<clash>` 6 条、`<cn>` 8928 段，核对全过）→ 保留（on，Evaluations 在涨）→ 关闭（off，守护进程退出）→ 恢复脚本卸干净（anchor 空，引用已在关闭那一轮释放）→ 照 App 的路径装回正式规则（off）。每一步外网都正常。没有 `SUDO_USER` 时用 `--helper` 的那条路、`--yes`、`env -i` 都在真的 root 下跑通。没测：密码框点取消（`-128`）、设置页的按钮本身、正式规则开启。
- **10-31 事故**：agent 用 osascript 提权跑 `firewall-test.sh`（当时的测试规则用 `user nobody`），「`on` 时模拟开机」之后约 3 分钟整机断网：所有 `pfctl`（连只读的 `-sr`）都不返回，Clash 内核 IPC 超时，恢复脚本卡在第 2 步，只能重启。重启后 `on` 把规则装了回来（网络正常），用恢复脚本卸干净。根因是 `user` 规则的内核死锁（§5、§6）。之后：规则里不再有 `user` / `group`；恢复脚本先删开机会加载的文件、每条 `launchctl` / `pfctl` 都限时，pf 卡死时不卡终端、提示重启。第 1 步和第 2～5 步已用新版脚本和新测试规则重做，见上。
