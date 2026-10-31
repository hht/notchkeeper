# 出口守卫

只**监测**：流量有没有全部走 Clash 隧道，结果画在刘海上，不拦任何东西（拦截见 `docs/firewall.md`）。规则：除局域网外，全部流量必须走代理（用户定）。

## 1. 三路观测和判定

| 观测 | 怎么拿 | 证明什么 |
|---|---|---|
| Clash 内核 | `ClashProbe`：进程表里有没有 `verge-mihomo`（实测的名字，换内核要重测） | 流量有没有可能经过 Clash |
| 路由 | `RouteProbe`：`route -n get` 查几个公网地址 | 内核把去公网的流量交给哪个网卡 |
| 出口 IP | `EgressProbe`：问几个第三方回显服务 | 回显那条连接从哪个节点出去 |

`EgressGuard` 按顺序取第一个成立的：任何路由不走 `utun` → `violated`；拿到不在允许列表的出口 IP → `egressMismatch`；Clash 在、路由都走 utun、出口 IP 都在允许列表 → `healthy`；其余 → `unknown`。

- **局域网豁免**：探测目标只有公网地址，从不查私有网段。
- **出口 IP 只是间接证据**：路由能证明流量进了 Clash，证明不了 Clash 交给哪个节点；回显服务和别的 App 可能分到不同节点，所以不符只提示、不算违规。
- 排除的做法（违反本仓规则）：读 Clash 控制接口、看进程的 TCP 对端（TUN 模式下是 fake-ip）、走 Anthropic 域名回显 IP。

## 2. guardd

用户级 LaunchAgent `com.notchkeeper.guardd`，安装和 `--once` 调试见 README。节奏和截止时间在 `PollSchedule`。

- 每轮三路并发，有总截止。**哪一路没赶上就算「没有结果」，绝不算「好」**（`Guardd.merge`）：本地探针没赶上落到 unknown，不判 violated（没有证据说路由不在隧道上）。
- **网络路径快照**（`NetworkPathProbe`，只读不发包）只用来区分 unknown 的两种原因：断网 offline、探针没结果 probeFailed。
- **粘性**：进入 violated 后，只有一轮完整的 healthy 才能解除；断网、超时、出口不符都不降级。启动时从上一份状态文件接着算，`violatedSince` 沿用。
- **允许列表**每轮重读 `config.json`：读不了按空列表，不合法的条目丢掉；空列表判不了出口，是 unknown。
- **SIGTERM / SIGINT**：被打断的那一轮不写文件，exit 0；plist 设 `KeepAlive.SuccessfulExit=false`，手动 kill 后不会被拉起。

## 3. `guard-state.json`

`~/Library/Application Support/Notchkeeper/guard-state.json`，0600，每轮先写临时文件再 rename。格式只在 `GuardCore/GuardState.swift` 定义。

| 字段 | 含义 |
|---|---|
| `schemaVersion` | 给已有字段加新取值时必须升 |
| `verdict` | 这一轮的结论 |
| `clashRunning` / `routeOnTunnel` / `egressMatches` | 每一路的摘要；缺省 = 这一轮没拿到 |
| `egressFailures` | 出口探针失败按类型计数 |
| `unknownReason` | 只在 unknown 时有：`offline` 优先于 `probeFailed` |
| `violatedSince` | 只在 violated 时有：这次违规开始的那一轮，粘住期间不变 |
| `egressIP` | 这一轮观测到的出口 IPv4；没拿到就不写，绝不沿用上一轮 |

IP 只允许出现在 `egressIP`，日志和 stdout 都不带 IP（有测试钉住）。

## 4. App 怎么读

App 订阅 `GuardStateWatcher`，自己不探测。**监听目录不监听文件**：rename 一次文件 fd 就失效。什么时候读由 `GuardReadSchedule` 定（目录事件合并、到点判过期、兜底重读），出口恢复到红卡撤掉一般 2～3 秒。

`GuardStateReader.display` 是唯一的显示规则：

| 情况 | 显示 | `lastVerdict` | `egressIP` |
|---|---|---|---|
| 文件不存在 / 解不开 / 格式版本不同 | unknown | nil | nil |
| `checkedAt` 太久没更新（stale）或在未来（clockSkew） | unknown | 文件里的 verdict | nil（不显示旧 IP） |
| 新鲜 | 文件里的 verdict | 同 verdict | 文件里的值 |

## 5. 怎么画

判定在 `NotchCore` 的 `GuardPresentation`、`ViolationAlert`，文案和颜色在 App 的 `GuardPresentation.swift`。状态 = 颜色 + 图标 + 文案：

| 显示 | 图形 |
|---|---|
| healthy | 绿 |
| egressMismatch | 琥珀实心 |
| unknown（断网、探针没结果、守卫没响应） | 灰色空心环 |
| violated | 红卡，响 Basso |
| stale / clockSkew 且上次是 violated | 红卡保留，不再响 |
| violated 且防火墙已开、状态摘要新鲜、核对通过（第 5 步，`docs/firewall.md`） | 红卡、锁图标、不响：「代理断开，防火墙已拦住外网」 |

收起时右耳显示什么由盾盾造型决定（`docs/mascot.md` §2）。

- **关掉红卡**：记下这次的 `violatedSince`，之后同一次不再弹，状态点照画（违规红点、守卫不响应灰环）；不同的 `violatedSince` 是新的一次，照弹。只在内存，App 重启后会再弹一次（宁可多提醒）。
- **和临时卡共用刘海**：见 `docs/ui.md`「卡片」。
- **恢复**：弹过红卡的那次违规回到 healthy 才弹恢复卡；中间断网、守卫不响应、关掉红卡都算同一次。任何路径进入 healthy 都撤红卡。
