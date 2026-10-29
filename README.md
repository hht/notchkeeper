# Notchkeeper

Haitao 本机自用的刘海应用（SwiftPM，macOS 14+），没有菜单栏图标。本机开发、ad-hoc 临时签名，不需要付费开发者账号。

现在能做的：

- **出口守卫红卡**：后台进程 `guardd` 每 5 秒检查 Clash、utun 路由和出口 IP，结果写进 `guard-state.json`；App 读这个文件，出口违规时在刘海亮红卡，恢复后弹绿色恢复卡。**只提示，还不拦截**（不杀进程、不断网）。
- **会话列表**：悬停刘海展开，显示出口 IP 和最近 30 分钟的 Claude Code / Codex 会话（只读文件元数据）。
- **盾盾**：刘海、卡片和设置页里的吉祥物，表情跟着守卫状态变；打开「盾盾感知 Mac 状态」后也跟着 CPU、温度、内存、电池变。基于 Coucou（MIT），仅自用。

还没做：

- **agent 完成卡没接真实事件**。现在只有 `scripts/demo.sh done` 能触发；`AgentCore` / `AgentWatch` 已写好并有测试，App 还没接。
- 拦截（杀进程或 killswitch）待 Haitao 定，见 `docs/killswitch-integration.md`。

## 运行

```bash
./scripts/run.sh            # release 编译、打包 build/Notchkeeper.app、ad-hoc 签名，结束旧实例后启动
./scripts/demo.sh done      # 演示：绿色完成卡
./scripts/demo.sh alert     # 演示：红卡
build/Notchkeeper.app/Contents/MacOS/Notchkeeper --selftest              # 自检，在临时 HOME 里跑，exit 0 才算过
build/Notchkeeper.app/Contents/MacOS/Notchkeeper --login-item status     # 开机启动状态（enable / disable 可切换）
```

- 只会有一个实例：第二个实例启动后直接退出，不画界面。界面卡住时用 `pkill -x Notchkeeper`。
- 入口：悬停或点击刘海展开；刘海上右键是「设置… / 拷贝出口 IP / 退出 Notchkeeper」；App 已在运行时再打开一次也会打开设置；⌘, 设置，⌘Q 退出。
- 设置页分为：通用、刘海与外观、出口守卫、拦截与防火墙、通知、Agent、盾盾、关于。
- 配置：`~/Library/Application Support/Notchkeeper/config.json`，改了自动热加载，缺的字段用默认值。**允许列表默认是空的**，这时守卫只能判 unknown，要先在设置页「出口守卫」里加上出口 IP（如 `198.51.100.7`）。
- App 日志：`~/Library/Logs/Notchkeeper/notchkeeper.log`，本地时间，不记 IP，不记对话内容。

## 出口守卫 guardd

guardd 是**当前用户的 LaunchAgent**（`com.notchkeeper.guardd`，在 `gui/<uid>` 域），登录后自动启动，和 App 是两个独立进程：App 没开，它照样每 5 秒检查一次。不要 sudo，以 root 运行脚本会被拒绝；不碰 Clash、网络设置、DNS、路由、pf、`~/.zshrc`，也不碰任何 LaunchDaemon。

```bash
bash scripts/install-guardd.sh --dry-run      # 只打印每一步和要写的 plist，什么都不改
bash scripts/install-guardd.sh                # 编译 release、安装并加载；可以重复跑，会覆盖的旧文件先带时间戳备份
bash scripts/uninstall-guardd.sh --dry-run    # 只打印
bash scripts/uninstall-guardd.sh              # 卸载，删 plist 和 bin/guardd，保留日志和状态文件
bash scripts/uninstall-guardd.sh --purge      # 同时删 guardd.log 和 guard-state.json
```

装完检查：`launchctl print gui/$(id -u)/com.notchkeeper.guardd`。

| 文件 | 说明 |
|---|---|
| `~/Library/Application Support/Notchkeeper/bin/guardd` | release 二进制 |
| `~/Library/LaunchAgents/com.notchkeeper.guardd.plist` | LaunchAgent（模板在 `Resources/guardd/`） |
| `~/Library/Application Support/Notchkeeper/guard-state.json` | 每轮写一次，权限 0600 |
| `~/Library/Logs/Notchkeeper/guardd.log` | stdout / stderr，不含 IP |
| `~/Library/Application Support/Notchkeeper/backup/` | 重装时旧文件的备份，卸载也保留 |

- guardd 只读 `config.json` 里的 `allowlist`，每轮重读，改了下一轮生效。
- verdict 变化时 guardd 发分布式通知 `com.notchkeeper.guard-state-changed`。App 通过 `GuardStateReader`（在 `GuardCore` 里）读 `guard-state.json`：启动时读一次，收到通知时重读，另外每 5 秒重读一次。App 自己不再探测出口。
- 调试：`swift run guardd --once` 跑一轮就退出，打印一行结果，不含 IP。

verdict 的意思：

| verdict | 什么时候 | 刘海 |
|---|---|---|
| `healthy` | Clash 在跑、去公网的路由走 utun、出口 IP 都在允许列表 | 绿色 |
| `egressMismatch` | 出口 IP 不在允许列表 | 琥珀色，不拦截 |
| `unknown` | 拿不到结论：断网、探针失败、Clash 不在、允许列表为空 | 灰色空心环 |
| `violated` | 去公网的路由不走 utun | 红卡；只有一轮完整的 healthy 才解除 |

guardd 停了，`guard-state.json` 超过 15 秒没更新就算过期：上次是 violated 就保留红卡，否则显示 unknown。

## 模块

| target | 做什么 |
|---|---|
| `Notchkeeper`（`Sources/Notchkeeper/`） | App：刘海、卡片、设置页、会话列表、盾盾（`Mascot/`），依赖 `GuardCore` |
| `GuardCore` | 出口判定、`guard-state.json` 格式、`GuardStateReader`；纯逻辑，不做 I/O |
| `GuardProbes` | 路由、Clash 进程、出口 IP、网络路径这几路观测，只做 I/O，不判定 |
| `guardd` | 后台进程：每轮跑探针、判定、写状态文件、发通知 |
| `AgentCore` / `AgentWatch` | Claude Code 会话的回合状态，只读会话文件尾部；**App 还没接** |

## 测试

```bash
swift build                 # 必须零警告
swift test                  # 全部单元测试
NOTCHKEEPER_LIVE_PROBES=1 swift test --filter LiveProbes   # 真机只读冒烟，不打印 IP
NOTCHKEEPER_LIVE_AGENTS=1 swift test --filter LiveAgents   # 真机只读，只打印各状态的个数
```

验收：`swift build` 零警告、`swift test` 全过、`--selftest` 通过。

## 文档

- `docs/egress-guard.md`：守卫的信号、判定规则、`guard-state.json` 字段、App 怎么读和怎么画
- `docs/slice5-install.md`：guardd 安装和卸载的细节
- `docs/agent-integration.md`：Claude Code 会话怎么读、什么时候算完成
- `docs/killswitch-integration.md`：killswitch 接入评估（未实施）
- `AGENTS.md`：本仓规则
