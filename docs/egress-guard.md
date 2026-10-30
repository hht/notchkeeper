# 出口守卫

出口守卫只负责**监测**：看流量有没有全部走 Clash 隧道，结果显示在刘海上，不拦任何东西。真正拦截流量的是防火墙，见 `docs/firewall.md`。

规则：除局域网外，全部流量必须走代理（Haitao 2026-10-28）。

## 1. 三路观测和判定

| 观测 | 怎么拿 | 证明什么 |
|---|---|---|
| Clash 内核 | `ClashProbe`：进程表里有没有可执行文件名正好是 `verge-mihomo` 的进程（2026-10-28 实测，换内核要按实测加） | 流量有没有可能经过 Clash |
| 路由 | `RouteProbe`：用 `route -n get` 查 `160.79.104.10`（Anthropic 入站网段，@see https://docs.anthropic.com/en/api/ip-addresses）、`1.1.1.1`、`8.8.8.8` | 内核把去公网的流量交给哪个网卡 |
| 出口 IP | `EgressProbe`：问 ipify、ipinfo、ifconfig.me | 回显服务那条连接从哪个节点出去 |

判定规则在 `EgressGuard`，按下面的顺序取第一个成立的：

| 条件 | verdict |
|---|---|
| 任何一个路由不走 `utun` | `violated` |
| 拿到了不在允许列表里的出口 IP | `egressMismatch` |
| Clash 在、路由都走 utun、出口 IP 都在允许列表，三个条件同时成立 | `healthy` |
| 其余情况（Clash 不在、读不到路由、探针全失败、允许列表为空） | `unknown` |

这一轮的结果，再交给第 2 节的粘性规则处理。

- **局域网豁免**：探测目标只有上面三个公网地址，从不查私有网段。`ProbeTests` 钉住了「探测目标全是公网地址」。
- **出口 IP 只是间接证据**。路由能证明流量进了 Clash，但证明不了 Clash 把它交给了哪个节点。回显服务和别的 App 可能被分到不同节点，所以出口 IP 不符只提示，不当成违规。
- 以下做法都排除了，因为都违反本仓规则：
  - 读 Clash 控制接口；
  - 看进程的 TCP 对端（TUN 模式下是 fake-ip）；
  - 走 Anthropic 域名回显 IP。

## 2. guardd

用户级 LaunchAgent `com.notchkeeper.guardd`，安装见 README。

- `swift run guardd` 一直轮询；`swift run guardd --once` 跑一轮就退出，stdout 打一行摘要，不含 IP。
- **调度**：下一轮开始时间 = `max(上一轮开始 + 5 秒, 上一轮结束)`（`PollSchedule.nextRoundStart`），不重叠、不补跑，用单调时钟。
- **每轮总截止 8 秒**（`PollSchedule.roundDeadline`）。三路信号并发：路由加 Clash、出口 IP 的 HTTP、网络路径快照。哪一路没赶上，就算「没有结果」，绝不算「好」（`Guardd.merge`）：
  - 本地探针没赶上：落到 unknown，不会判 violated，因为没有证据说明路由不在隧道上；
  - 出口没赶上：每个回显服务记一次 timeout；
  - 网络快照没赶上：unknown 的原因记 probeFailed。
- **网络路径快照**（`NetworkPathProbe`）：一个常驻的 `NWPathMonitor`，排除 utun 和回环，只读，不发包。它只用来区分 unknown 的两种原因：断网（offline）和探针没拿到结果（probeFailed）。
- **粘性**（`EgressGuard`）：进入 violated 后，只有一轮完整的 healthy 才能解除。断网、探针超时、出口不符，都不会把它降级。
  - 启动时先读上一份状态文件（`Guardd.resumedGuard`）；如果是 violated，就从 violated 接着算，`violatedSince` 沿用原值。
- **允许列表**：每轮开头重读 `config.json` 的 `allowlist` 键（`AllowlistFile`）：
  - 文件不存在或读不了：按空列表处理，记一行日志；
  - 有不合法的条目：丢掉它们，日志只报条数；
  - 空列表：判不了出口，结果是 unknown。
- **SIGTERM / SIGINT**：被打断的那一轮不写文件，然后 exit 0。plist 设的是 `KeepAlive.SuccessfulExit=false`，所以手动 kill 之后 launchd 不会把它拉起来。

## 3. `guard-state.json`

- 路径：`~/Library/Application Support/Notchkeeper/guard-state.json`，权限 0600。
- 每轮写一次：先写同目录的临时文件，再 rename 过去。
- 格式只在 `GuardCore/GuardState.swift` 定义一次，时间用 ISO 8601，键名排序。

| 字段 | 类型 | 含义 |
|---|---|---|
| `schemaVersion` | Int | 现在是 1；给已有字段加新取值时必须升版本 |
| `verdict` | String | `healthy` / `egressMismatch` / `unknown` / `violated` |
| `checkedAt` | ISO 8601 | 这一轮结束的时间 |
| `clashRunning` / `routeOnTunnel` / `egressMatches` | Bool，可缺省 | 每一路信号的摘要；缺省表示这一轮没拿到 |
| `egressFailures` | {String: Int} | 出口探针失败按类型计数：`timeout`、`transport`、`badStatus`、`unparseable` |
| `unknownReason` | String，可缺省 | 只在 unknown 时有：`offline` 或 `probeFailed`（断网优先） |
| `violatedSince` | ISO 8601，可缺省 | 只在 violated 时有：这次违规开始的那一轮；粘住期间不变 |
| `egressIP` | String，可缺省 | 这一轮观测到的出口 IPv4，完整地址。没拿到就不写，绝不沿用上一轮 |

IP 只允许出现在 `egressIP` 这一个字段里，日志和 stdout 都不能带 IP。有测试钉住：`EgressIPInStateFile.onlyEgressIPCarriesAnIP`、`RoundMerge.summaryAndVerdictLogNeverContainIPs`。

## 4. App 怎么读

App 订阅 `GuardStateWatcher(directory:).displays()`（GuardWatch），自己不探测出口。显示规则只写在 `GuardStateReader.display` 一处。

- **监听目录，不监听文件**：guardd 用 rename 替换文件，文件的 fd 换一次就失效了。
- **什么时候读**由 `GuardReadSchedule` 决定，取以下三者中最早的：
  - 目录事件后 100ms（窗口内的事件合并成一次读）；
  - 上次 `checkedAt` + 15 秒：到这时就判过期，guardd 停了也能看出来；
  - 距上次读 30 秒兜底。
- **延迟**：出口恢复到红卡撤掉，一般 2～3 秒，最坏约 16 秒。

| 情况 | `reason` | 显示的 verdict | `lastVerdict` | `egressIP` |
|---|---|---|---|---|
| 文件不存在 / 解不开或格式版本不同 | `.missing` / `.unreadable` | unknown | nil | nil |
| `checkedAt` 超过 15 秒没更新 | `.stale` | unknown | 文件里的 verdict | nil（不显示旧 IP） |
| `checkedAt` 在未来超过 5 秒（改过系统时间） | `.clockSkew` | unknown | 文件里的 verdict | nil |
| 新鲜 | `.fresh` | 文件里的 verdict（unknown 缺 unknownReason 的按 probeFailed） | 同 verdict | 文件里的值（不是合法 IPv4 时为 nil） |

刚好 15 秒算新鲜，超过才算过期。

## 5. 怎么画

由 `GuardPresentation` 决定。状态 = 颜色 + 图标 + 文案。

| 显示 | 图形 | 文案 |
|---|---|---|
| healthy | 绿 | 出口正常 |
| egressMismatch | 琥珀实心 `#FFB020` | 出口 IP 和预期不一致 |
| unknown + offline | 灰色空心环 `#8E8E93` | 网络不通，暂时没法检查出口 |
| unknown + probeFailed | 灰色空心环 | 暂时查不到出口 |
| unknown，其余原因 | 灰色空心环 | 守卫没有响应 |
| violated | 红卡 `#FF453A`，响 Basso | 出口不合规 · 有流量没走 utun 隧道 |
| stale 或 clockSkew，且 `lastVerdict == violated` | 红卡保留，不再响 | 出口不合规 · 守卫没有响应，无法确认出口是否恢复 |
| violated，且防火墙已开、状态摘要新鲜、核对通过（第 5 步） | 红卡，锁图标，不响 | 代理断开，防火墙已拦住外网 · 没有泄漏 |

表里的「图形」是状态点（面板、设置页）。收起时右耳显示什么由盾盾的造型决定（`docs/mascot.md` §2）：断网和守卫没响应在右耳显示告示图标，探针没结果显示灰色空心环。

- **用户关掉红卡**：App 在内存里记下 `dismissedViolationSince = violatedSince`。只要之后读到的 `violatedSince` 还是这个值，就不再弹卡，但状态点仍按当前状态画：
  - violated 时画红点；
  - 守卫不响应时画灰环。
  
  读到不同的 `violatedSince` 算新的一次违规，照常弹卡。这个记录不落盘，App 重启后红卡会再出现一次。
- **和临时卡共用刘海**：红卡挂着时，完成卡、介入卡、恢复卡可以暂时盖在上面，放完回到红卡；新违规开始时红卡插到最前（`docs/ui.md`「卡片」）。
- **恢复**：只有弹过红卡的那次违规回到 healthy，才弹绿色恢复卡。中间断网、守卫不响应、用户关掉红卡，都算同一次违规。任何路径进入 healthy 都要撤掉红卡。
