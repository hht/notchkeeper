# 出口守卫：信号分工与防误杀方案

状态：方案（2026-10-28，Jason）。断网/拦截方式另见 `docs/interception.md`（甲乙丙丁，和本文的 A/B 不是一套编号）。第 1 节已实现；第 2 节等 Haitao 拍板后再改 `GuardCore`。

依据：Haitao 2026-10-28 确认「除局域网外全部流量必须走代理」（`AGENTS.md:44`）。

## 1. 两路信号，证据强度不同

| 信号 | 怎么拿 | 证明什么 | 能不能单独触发拦截 |
|---|---|---|---|
| 路由 | `RouteProbe`：`route -n get` 查 `160.79.104.10`（Anthropic 入站网段 `160.79.104.0/23`，@see https://docs.anthropic.com/en/api/ip-addresses）、`1.1.1.1`、`8.8.8.8` | 内核把去 Claude 和去公网的流量交给哪个网卡 | 能。任何一个不走 `utun` 立即 violated |
| 出口 IP | `EgressProbe`：问 ipify / ipinfo / ifconfig.me | 这三个回显服务那条连接从哪个节点出去 | 见第 2 节 |

局域网豁免：探测目标只有上面三个公网地址，从不查私有网段（10/8、172.16/12、192.168/16、169.254/16），所以局域网直连的路由不会被判成异常。`ProbeTests` 里有测试钉住「探测目标全是公网地址」。

路由是直接证据：Haitao 的规则本身就是「非局域网都走代理」，而路由表正好回答「走没走 utun」。它不依赖 Clash 的分流规则，不会误杀。

## 2. 出口 IP 的误杀风险

**问题**：路由只能证明流量进了 Clash，证明不了 Clash 把它交给了哪个节点。回显服务和 Claude 即使都走代理，也可能被分到不同的策略组或节点（规则分流、url-test、负载均衡），回显服务就会报出一个不在允许列表里的 IP。按现在的规则，连续 2 轮这样就判 violated，第 4 片接上后会误杀正在正常工作的 Claude。

**排除掉的做法**

- 读 Clash 控制接口（`/connections`、`/proxies`）看 Claude 的连接走哪个节点：需要控制接口密钥，也违反「不读写 Clash 配置」。
- 看 Claude 进程的 TCP 对端：TUN 模式下对端是 fake-ip（198.18.x），看不出节点。
- 通过 Anthropic 的域名回显 IP：违反「出口探测不碰 Claude / Anthropic 域名」。

**方案（推荐）：出口 IP 分两档，默认只观察**

1. 配置里新增 `egressEnforcement`，取值 `observe`（默认）或 `enforce`。
   - `enforce`：保持现在的规则，连续 2 轮不在允许列表才判 violated。
   - `observe` 下拿到不在允许列表的 IP 怎么办，请 Haitao 二选一（`AGENTS.md:44` 规定只有明确异常才拦截，拒绝新启动也算拦截）：
     - **A. 只显示**：琥珀色提示，什么都不拦。violated 只由路由触发。代价：Claude 真的换到不允许的节点时，新启动也放行，只靠路由兜底。
     - **B. 拦新启动**：琥珀色，拒绝新启动，不杀已在跑的。代价：回显服务被分到别的节点时，Claude 会被误拦、启动不了；而且要把「`observe` 下坏 IP 拒绝新启动」写进 `AGENTS.md:44` 的修改稿。
2. 切到 `enforce` 之前，Haitao 需要在 Clash 里**亲手**做好一件事（我们不碰 Clash）：把 `ipify.org`、`ipinfo.io`、`ifconfig.me` 三个域名放进 Claude 所在的同一个策略组；并且这个组要么只有一个节点，要么组内每个节点的出口 IP 都在允许列表里。做到之后，回显服务看到的 IP 就等于 Claude 的出口 IP，`enforce` 不会误杀。
3. 设置页「出口守卫」显示最近几轮去重后的出口 IP（完整显示，Haitao 2026-10-28 确认），方便 Haitao 对照允许列表、决定什么时候切 `enforce`。这些 IP 不写日志；落盘的只有 `guard-state.json` 里本轮的 `egressIP`（文件权限 0600）。

**代价**：在 `observe` 档，如果 Clash 把 Claude 自己切到了一个不在允许列表的节点，已经在跑的 Claude 拦不住（选 A 时新启动也拦不住）。要堵住这个口子，就切 `enforce`，前提是第 2 步已经做好。

**要改的地方（拍板后）**

- `AGENTS.md:44` 的「明确异常」改为：路由不走 utun；或在 `enforce` 档下出口 IP 不在允许列表（选 B 时再加一句「`observe` 下坏 IP 拒绝新启动」）。这条改的是硬规则，要 Haitao 确认。
- `EgressGuard.observe` 增加档位参数，补测试：`observe` 下坏 IP 永远不 violated、路由异常照样立即 violated；`enforce` 下保持现有 15 条测试。
- `Config.swift` 增加字段，默认 `observe`。

## 3. 第 4 片接线注意（Vera 审查第 7 条）

- `RouteProbe.lookup` 是同步启动子进程，不能在主线程跑，`guardd` 里放到后台队列。
- HTTP 超时 6 秒、轮询 5 秒：上一轮没结束不开下一轮。

## 4. Slice 4 实现说明（guardd，Jason 2026-10-28）

状态：已提交（`7e5c871`），已作为 LaunchAgent 安装（2026-10-28），App 已改为读 `guard-state.json`（`93286d3`）。

**进程与文件**

- 新 target `guardd`（`Sources/guardd/`），依赖 `GuardCore` + `GuardProbes`；`swift run guardd` 一直轮询，`swift run guardd --once` 跑一轮就退出。其他参数打印用法、exit 64。
- 每轮写 `~/Library/Application Support/Notchkeeper/guard-state.json`：同目录临时文件（`O_EXCL`，0600）+ `rename`，App 不会读到半截；写失败只记一行 stderr，下一轮重试。
- 格式只在 `GuardCore/GuardState.swift` 定义一次（ISO 8601 时间，键名排序）：

  | 字段 | 类型 | 含义 |
  |---|---|---|
  | `schemaVersion` | Int | 现在是 1 |
  | `verdict` | String | `healthy` / `egressMismatch` / `unknown` / `violated`（粘性规则照旧在 `EgressGuard`） |
  | `checkedAt` | ISO 8601 | 这一轮结束的时间 |
  | `clashRunning` / `routeOnTunnel` / `egressMatches` | Bool，可缺省 | 每一路信号的摘要；缺省 = 这一轮没拿到（未知） |
  | `egressFailures` | {String: Int} | 出口探针失败按类型计数：`timeout`、`transport`、`badStatus`、`unparseable` |
  | `unknownReason` | String，可缺省 | 只在 verdict 是 `unknown` 时有：`offline`（没有满足的非 utun 物理网卡，或没有默认路由）/ `probeFailed`（网通着但探针没给出结果，或没拿到网络快照）。断网优先。其他 verdict 永远不写这个键 |
  | `violatedSince` | ISO 8601，可缺省 | 只在 verdict 是 `violated` 时有：这次违规开始的那一轮（进入 violated 时设上，粘住期间不变，被 healthy 解除时去掉；之后再违规是新的值）。重启接续时沿用原值 |
  | `egressIP` | String，可缺省 | 这一轮观测到的出口 IPv4，完整点分地址（打不打码是 App 显示层的事，guardd 不打码）。来源是这一轮出口探针（`EgressProbe`，三个回显服务）拿到的 IP：有不在允许列表的就只从这些里挑，多个说法不一时取出现次数最多的、一样多取数值最小的（`Observation.shownEgressIP`，和返回先后无关）。**跟这一轮绑定**：没拿到出口（断网、探针全失败或没赶上截止）就不写这个键，绝不沿用上一轮；粘住的 violated 期间照写这一轮的观测；verdict 是 unknown 但确实拿到了 IP（如 Clash 不在、允许列表为空）也照写。重启接续不碰它 |

  IP 只允许出现在 `egressIP` 这一个字段（Haitao 2026-10-28 定：面板显示 IP；文件是本地的、0600，不是日志）。不存网卡名。有测试钉住：`egressIP` 以外的任何字段都没有点分 IP，stderr 日志和 `--once` 输出也没有（`EgressIPInStateFile.onlyEgressIPCarriesAnIP`、`RoundMerge.summaryAndVerdictLogNeverContainIPs`）。
- `unknownReason` 是新增的可选字段，`schemaVersion` 仍是 1：旧文件没有这个键照样能解（解成「没有原因」），旧 App 读新文件会忽略它。**以后给 `unknownReason` 加新取值必须升 `schemaVersion`**：旧 App 遇到不认识的取值会整份文件解不开（`.unreadable`），升版本后它走 `.newerSchema`，两条路显示一样，但意图清楚。
- `violatedSince` 也是可选字段，`schemaVersion` 仍是 1：旧文件没有它照样能解。
- `egressIP` 同样是可选字段，`schemaVersion` 仍是 1：旧文件没有它解成 `nil`，旧 App 读新文件会忽略它。guardd 每轮都重写文件，IP 变了 App 的目录监听就会读到新值。
- **重启接续粘性**：KeepAlive 会重启 guardd，粘性只放内存的话，重启后第一轮 unknown / 出口不符会把 violated 文件覆盖掉，红卡悄悄消失。所以启动时先读上一份 `guard-state.json`（`Guardd.resumedGuard`）：解得开、`schemaVersion` 和现在一样、verdict 是 `violated`，就从 violated 开始（`EgressGuard(resuming:)`），`violatedSince` 沿用原值（旧 guardd 没写时用那份文件的 `checkedAt`）。**不看新旧**：只有一轮 healthy 能解除，停了多久都一样。其他 verdict、文件不存在、解不开、格式更新，一律从 unknown 从头开始。接续时 stderr 记一行。
- 原因由 `UnknownReason.decide(verdict:path:)` 决定（GuardCore，纯函数），只看 verdict 和这一轮的网络快照：unknown 已经说明探针没给出结果，快照只用来分是不是断网。所以 Clash 没开、允许列表为空这类 unknown，只要网通着就是 `probeFailed`。
- **变化**：verdict 或 `unknownReason` 变化时（包括启动后第一轮），写好文件后记一行日志。不发通知：App 用 `GuardStateWatcher` 监听目录拿到新文件（见下面「不轮询」一节）。拦截接缝 `onVerdictChange` 只在 verdict 变化时调用，原因变化不算。

**调度：不重叠**

- 下一轮开始时间 = `max(上一轮开始 + 5 秒, 上一轮结束)`（`PollSchedule.nextRoundStart`，纯函数，有测试）。单个循环串行跑，上一轮没结束不会开下一轮；慢了也不补跑。用单调时钟 `ContinuousClock`，改系统时间不影响。
- 每轮里路由（`/sbin/route` 子进程）+ Clash（系统调用，放 GCD 后台线程）、出口 IP 的 HTTP、网络路径快照三路并发。
- **网络路径快照**（`GuardProbes/NetworkPathProbe.swift`）：进程启动时建一个常驻的 `NWPathMonitor(prohibitedInterfaceTypes: [.other, .loopback])`，排除 utun（属于 `.other`）和回环，只读，不发包、不改设置。系统在路径变化时回调，记下两个布尔值：`status == .satisfied` 且有 Wi-Fi / 有线 / 蜂窝网卡（名字以 `utun` 开头的一律不算），`gateways` 非空（有默认路由）。每轮直接取最新快照，刚启动还没回调时最多等 2 秒；测试里换成桩（`NetworkPathSource`）。
- **每轮总截止 8 秒**（`PollSchedule.roundDeadline`）。出口探针的 6 秒 `timeoutInterval` 是连接空闲超时，不封顶总时长，所以另加这道截止：本地（路由 + Clash）、出口、网络快照三路各自用 task group 和一个 sleep 赛跑（`guardd/Deadline.swift`）。没赶上的那一路算「没有结果」，绝不算「好」（`Guardd.merge`，纯函数，有测试）：
  - 本地没赶上：`clashRunning` / `routeOnTunnel` 都缺省，verdict 落到 unknown（不会是 violated，因为没有证据说路由不在隧道上）。
  - 出口没赶上：没有 IP，`egressFailures` 里每个回显服务记一次 `timeout`；已拿到的部分 IP 一并丢掉。
  - 网络快照没赶上：当作没拿到，不能断言断网，unknown 的原因记 `probeFailed`；不影响另两路的结果和 verdict。
  - 路由子进程超时被取消时 `Process.terminate`；已取消就不再启动（`RouteProbe.output`，有测试）。
- SIGTERM / SIGINT 取消轮询任务：sleep 和 HTTP 立即醒来，被打断的那一轮不写文件，exit 0（已实测 sleep 中、探测中两种情况）。

**允许列表**：每轮开头重读 App 写的 `~/Library/Application Support/Notchkeeper/config.json`（路径和 App 一样用 `applicationSupportDirectory` 求），只解 `allowlist` 键，其他键忽略（`guardd/AllowlistFile.swift`）。App 设置页改了，下一轮生效，不用重启。

| 情况 | 允许列表 | 记日志 |
|---|---|---|
| 文件不存在 | 默认值（复制自 `NKConfig.allowlist` 的默认值，两边要一致） | 一行 |
| 读不了 / 不是 JSON / `allowlist` 类型不对 | 默认值 | 一行 |
| 没有 `allowlist` 键 | 默认值（和 App 的 `decodeIfPresent` 一样） | 不记 |
| 有不合法的条目 | 丢掉它们，用剩下的 | 一行，只报条数 |
| 空数组 | 空（`egressMatches` 缺省 → unknown，和 App 一致） | 不记 |

日志只在问题出现或变化时记一行，恢复时再记一行，不带 IP。

**`--once`**：跑一轮、写文件、记一行 verdict 变化日志（第一轮必然算变化），stdout 打一行 `verdict=… clashRunning=… routeOnTunnel=… egressMatches=… egressFailures=… unknownReason=…`，没有 IP。写文件失败 exit 1。

**这一片没做的**

- **拦截**：只留一个接缝 `Guardd.onVerdictChange`（写好文件、verdict 变化时调用），现在是空实现。甲（杀进程）和 killswitch 的取舍待 Haitao 定；killswitch 是否取代乙也待 Haitao 拍板，见 `docs/killswitch-integration.md`。
- **常驻**：Slice 5 的 LaunchAgent 模板和安装 / 卸载脚本已在仓库里，2026-10-28 已安装（见 `docs/slice5-install.md`）。
- **App 接线**：已完成（`93286d3`），App 用 GuardCore 的 `GuardStateReader` 读文件；`ceac9f6` 起改为订阅 `GuardStateWatcher`，不再 5 秒重读（见下面「不轮询」一节）。

**App 怎么读（给 S1m0nE）**

纯函数在 `Sources/GuardCore/GuardStateReader.swift`，App target 依赖 `GuardCore`（`93286d3` 已在 `Package.swift` 里加上）。

```swift
import GuardCore

// 文件路径和 guardd 用的是同一个定义
let data = try? Data(contentsOf: GuardPaths.stateFile)
let shown = GuardStateReader.display(data: data, now: Date())   // interval 默认 5 秒
// shown.verdict：要显示的四态；shown.reason：为什么；shown.checkedAt：上次检查时间（读得出时才有）
// shown.unknownReason：guardd 给的 unknown 原因，只在 reason == .fresh 且 verdict == .unknown 时有
// shown.lastVerdict：文件里最后写的 verdict（解得开就有；新鲜时等于 verdict）
// shown.violatedSince：这次违规的开始时间，只在 lastVerdict == .violated 时有
// shown.egressIP：guardd 这一轮观测到的出口 IP，只在 reason == .fresh 时有，否则 nil（界面显示「—」）
```

| 情况 | `reason` | 显示的 `verdict` | `unknownReason` | `lastVerdict` | `violatedSince` | `egressIP` |
|---|---|---|---|---|---|---|
| 文件不存在 | `.missing` | unknown | `nil` | `nil` | `nil` | `nil` |
| 解不开（不是 JSON、缺字段、verdict 或 unknownReason 名字不认识） | `.unreadable` | unknown | `nil` | `nil` | `nil` | `nil` |
| `schemaVersion` 比 App 支持的新 | `.newerSchema` | unknown | `nil` | `nil` | `nil` | `nil` |
| `checkedAt` 早于现在超过 3 个间隔（15 秒） | `.stale` | unknown（violated 也一样：粘性归 guardd；红卡是否保留看 `lastVerdict`，见下） | `nil` | 文件里的 verdict | 文件里是 violated 时的值，否则 `nil` | `nil`（不显示旧 IP） |
| `checkedAt` 晚于现在超过 1 个间隔（改过系统时间） | `.clockSkew` | unknown | `nil` | 文件里的 verdict | 同上 | `nil` |
| 新鲜，verdict 是 unknown，带 `unknownReason` | `.fresh` | unknown | 文件里的值（`.offline` / `.probeFailed`） | unknown | `nil` | 文件里的值（通常没有） |
| 新鲜，verdict 是 unknown，**没有** `unknownReason`（旧 guardd 写的） | `.fresh` | unknown | `.probeFailed` | unknown | `nil` | 文件里的值 |
| 新鲜，violated | `.fresh` | violated | `nil` | violated | 文件里的值 | 文件里的值 |
| 新鲜，healthy / egressMismatch | `.fresh` | 文件里的 verdict 原样 | `nil`（文件里就算带了也丢掉） | 同 verdict | `nil`（带了也丢掉） | 文件里的值 |

`egressIP` 只在新鲜时给，文件里的值不是合法 IPv4 时也给 `nil`（文件是外部数据）。和 `lastVerdict` 故意不同：guardd 不响应时红卡可以靠 `lastVerdict` 保留，但旧 IP 不能当成现在的出口显示，界面显示「—」。

**不轮询，订阅 `GuardStateWatcher`（Jason 2026-10-28）**

App 不再每 5 秒读一次文件，改为依赖 `GuardWatch` target，订阅一个流；显示规则仍只有 `GuardStateReader.display` 一处：

```swift
import GuardCore
import GuardWatch

for await shown in GuardStateWatcher(directory: GuardPaths.directory).displays() {
    // shown 就是上面表里的 GuardDisplay；开始时马上来一次，之后只在结果变了时来
}
```

- 监听的是目录（`DispatchSource` + `O_EVTONLY`），不是文件：guardd 用临时文件 + rename 替换，文件 fd 第一次替换后就失效。同目录的 `config.json` 变了会多读一次，结果没变不发。目录被删或改名时关掉旧 fd，之后每次读前重开。
- 什么时候读归 GuardCore 的纯状态机 `GuardReadSchedule`，取三者最早：目录事件后 100ms（窗口内的事件合并成一次读）；上次 `checkedAt` + 3 个间隔（15 秒，reader 开始判 stale 的时刻，加 0.1 秒余量），guardd 死了不写文件也能变成 stale，红卡照旧靠 `lastVerdict` 保留；距上次读 30 秒兜底。
- 目录必须由调用方传入，测试一律传临时目录。
- 延迟：出口恢复后，guardd 下一轮写出 healthy 到红卡撤掉只剩 100ms 合并窗口。最坏约 16 秒（恢复正好落在一轮刚探测完：这一轮最多 8 秒、下一轮最多 8 秒），一般 2～3 秒。恢复后第一轮又遇到 unknown 时，violated 照设计多粘一轮。

`lastVerdict` 选「新鲜时等于 `verdict`」而不是新鲜时 `nil`：它的意思始终是「文件里写的是什么」，只看能不能信这份文件，App 不用分新鲜 / 过期两种写法。

**怎么画（颜色已定）**：所有 unknown 都是**同一个灰色空心环 `#8E8E93`**，原因只决定文字，不改颜色。琥珀色实心只给 egressMismatch，红色卡片只给 violated。

| 显示 | 图形 | 文字 |
|---|---|---|
| unknown + `unknownReason == .offline` | 灰色空心环 `#8E8E93` | 「网络不通，暂时没法检查出口」 |
| unknown + `unknownReason == .probeFailed`（含旧 guardd 没写原因） | 灰色空心环 `#8E8E93` | 「暂时查不到出口」 |
| unknown + `reason` 是 `.stale` / `.missing` / `.clockSkew`（`.unreadable`、`.newerSchema` 同样；`.stale` / `.clockSkew` 且 `lastVerdict == .violated` 见下面红卡那行） | 灰色空心环 `#8E8E93` | 「守卫没有响应」 |
| egressMismatch | 琥珀色实心 | 照旧 |
| violated | 红色卡片 | 照旧 |
| unknown + `reason` 是 `.stale` 或 `.clockSkew` + `lastVerdict == .violated` | **红色卡片保留** | 副标题「守卫没有响应，无法确认出口是否恢复」 |
| healthy | 正常 | 照旧 |

选文字的顺序：先看 `unknownReason`（只有新鲜的 unknown 才有），没有再看 `reason`。

**guardd 不响应时的红卡（Emily 定稿；`.clockSkew` 同样适用，Grok Bot 定稿）**：`reason` 是 `.stale` 或 `.clockSkew`、且 `lastVerdict == .violated` 时，App 继续显示红卡，副标题「守卫没有响应，无法确认出口是否恢复」，不再响 Basso。只按这一次读到的结果判断，不靠内存里的历史（App 重启后照样成立）。改过系统时间也一样：这时没法确认文件新不新，宁可保留红卡。用户关掉的规则同下，按 `violatedSince` 记。

**用户关掉红卡**：App 在内存里记 `dismissedViolationSince = shown.violatedSince`。之后每次读到的 `violatedSince` 等于它，就不再弹红卡、只画灰色空心环（违规还在，只是用户知道了）；读到的值不同（新的一次违规）照常弹。读到新鲜 healthy 时清掉 `dismissedViolationSince`，并按恢复规则出绿色恢复卡。`violatedSince` 只在旧 guardd 写的文件里会是 `nil`；那时关掉的记录也是 `nil`，同样一直有效到 healthy。这个值不落盘：App 重启后已关掉的红卡会再出现一次，宁可多提醒。

刚好 15 秒算新鲜，超过才算过期。App 怎么拿到最新结果见上面「不轮询」一节；App 自己不再探测出口。
