# HANDOFF

最后更新：2026-10-31。只放接下来要做的和没解决的；做完的看 `git log`，规则看 `CLAUDE.md` 和 `docs/*`。开工前 `git log --oneline -5` 核对，工作区应是干净的。实机验证的技巧见 `docs/dev-notes.md`。

## 接下来

**插件化（用户 10-31 定方向，设计还没出）**：App 接收外部消息，功能做成插件。已定：
- 外部脚本把消息写进只给当前用户的收件箱目录，App 监听；不开本地端口，不用 URL scheme、分布式通知。
- 第一个新场景：终端里的命令结束了提醒。
- 点击动作只有「打开 URL」「切换到 App」（含切到 Ghostty 里某个终端窗口）；消息不能带要执行的命令。
- Claude Code 也走插件通道；出口守卫和红卡也做成可配置的插件。插件要支持一次性卡片和有生命周期的活动（开始、更新、结束）两种。
- 快捷指令（App Intents）放第二步。
- 终端命令卡片只显示命令名（不带参数），日志不记命令（用户 10-31）。
- Claude Code 和出口守卫做成**内置插件**：设置里能开关、配置，产出和外部插件同一种卡片 / 活动；来源和判定仍在 `AgentCore` / `GuardCore`（用户 10-31，因为 mod 拿不到忙闲和介入、也没有原子写）。
- 打开 URL：默认只放行 `https`，用户可在设置里加白名单 scheme（用户 10-31）。
- 卡片内容丰富化（用户 10-31）：照灵动岛展开态分区，固定一行「Pip + 标题 / 副标题 + 右侧短值」，底部区由插件选一种内容块——正文（≤3 行，Markdown 子集）、进度（随活动更新原地刷新）、键值（≤4 对）、列表或日志尾巴（≤3 行）；最多两个按钮，动作只有打开 URL / 切换 App。图标只收 SF Symbols 名、颜色只收语义色，不收图片路径和原始色值；总高度有上限，超出截断。
设计时要先改 CLAUDE.md、交用户定的：守卫插件能关掉，但硬规则说 violated 只有一轮完整 healthy 才解除、守卫停了不降级——违规时关掉守卫红卡撤不撤；收件箱同一用户的任何进程都能写，和「`demo.sh` 的分布式通知因为本机任何进程都能发才只在 DEBUG 监听」、reviewer 必须修的「本机任意进程能触发 UI」冲突，要写明外部插件卡片的信任级别。并讲清：外部消息不能伪造或撤掉红卡；收件箱同一用户的任何进程都能写，信任级别等同本机进程；打开 URL 默认只允许 `https`（自定义 scheme 能拉起别的 App 执行动作）。
下一步：照成熟实现（terminal-notifier、ntfy、SwiftBar、Raycast Script Commands、ActivityKit）出消息格式、插件目录和切片，给用户看过再做；第 4 步重写要给这套接口留位置。

**第 4 步：App 外壳重写**（每一刀：TDD → 零警告 + 全绿 → reviewer → 用户明示后提交）。已做：`NotchCore` 的 `CardQueue`、`GuardPresentation`、`ViolationAlert`。剩下：

- `NotchCore`：悬停状态机（HoverMachine）、MascotResolver（守卫 > agent > 空闲，叠上晕和犯困；现在是 `AppState.look` 临时合成）、布局几何、配置解码（`Tests/NotchkeeperTests` 的测试跟着挪）。
- 接上「点一下晕」。`MascotDirector` 的时钟决策（醒来、恢复、推迟小动作）抽成值类型测试；从 Coucou 搬来的代码重写掉，删 MIT 声明。
- 亮色、多语言基础设施：所有文案走 String Catalog；设置窗口去掉强制暗色，刘海窗口设 `.darkAqua`（现在没设），加「在系统设置中更改语言…」。
- 减弱动态效果时黑色形状的弹簧还没收紧（HIG Accessibility，`docs/ui.md`「灵动岛规范」12）。
- 精简设置页。「状态测试」的 Pip 用 `state.look`，旁边文案还是 `presentation.title`，对不上。
- `demo.sh` 的通知只在 DEBUG 构建里监听。刘海视图只订阅 `presentation`。
- `NotchController.collapse()` 用 `asyncAfter(0.5)` 等收起动画；`NKConfig` 去前缀；`ConfigStore` 每秒轮询、看不见时也在跑。
- `config.json` 的 `launchAtLogin`、`suppressWhenHostFrontmost`、`agents` 没有消费者，下次存盘会被去掉。
- `Notch.swift` 里「Emily 规格」几处出处说法确认后改掉。
- 删 `MascotView` 的 small 尺寸（App 里已不用，只剩测试；单独一个 refactor 提交）。
- 验收：亮暗 × 中英截图，空闲 CPU（见下）。

**第 5 步：防火墙**：root 实测 → 恢复脚本并实测 → 试运行和自动回滚 → 规则、LaunchDaemon、安装脚本、App 开关；shielded 造型接线。按全局 Contract「高影响」档收工。IPv6 一起处理。

## 等实机验证

- **Ghostty 跳转**：同目录开两个 Claude；Claude 套在 tmux 里（应退回按目录认）；工作中的会话多点几次，看转圈字符会不会盖掉标记（推断）。有一次脚本连点两行第二下没切过去、没复现：用户再遇到时记下哪一行、面板开着没有。
- **mod**：开着的会话装上后 `/reload-plugins` 应该开始写（没实测）；后台 agent 崩溃时会不会发带 `agentId` 的 `turn.complete`（不发的话该会话的完成卡被压住到 `/clear`）；后台 agent 在跑时 `/reload-plugins` 可能提前弹完成卡（推断）。`Funk` 出错音没人耳听过。
- **Claude Code 升级后**：重跑 `ClaudeMod/plugins/notchkeeper` 的 `claude plugin test`，在 tmux 里按 `docs/agent-integration.md`「实测」8 重测。
- **卡片流星**：介入卡、出错卡、恢复卡、红卡的颜色（`demo.sh question|approval|failed|alert`）；常驻红卡和减弱动态效果时的淡细边；悬停时流星停住、移开接着走；队列里下一张卡接上时流星从头扫一趟；流星每次 `layout` 重挂动画的 CPU。
- **面板**：减弱动态效果时 Pip 和徽章原地淡入淡出（要切系统设置，先问用户）；finished 的星、sleeping 的 Z 可能顶出面板上沿被裁（推断）；已停止的会话行；左耳 Pip 可能总低着头（推断）；设置页预览可能不跟鼠标（推断）。
- **多语言**（第 4 步做完后）：系统设置「按 App 设语言」的列表里有没有 Notchkeeper、选了生不生效；设置页跳转按钮的 URL 对不对。
- **灵动岛规范**（`docs/ui.md`）：IP 换值时数字滚动、徽章图标替换、VoiceOver 弹卡播报。
- **设置页**：`config.json` 解不开时的横幅（要临时改坏真实配置，先备份；横幅的黄和琥珀容易混）；亮色截图（要切系统外观，先问用户）。
- **空闲 CPU**：没测到干净的数（10-29 有人操作时 2.62%）。方法：`run.sh` 后取 pid；循环读 `ioreg -c IOHIDSystem` 的 `HIDIdleTime`，≥ 30s 无人操作才用 `top -l 2 -s 1 -pid <pid> -stats pid,cpu` 取样，采样后仍无人操作才留，攒 60 个求平均。App 和 WindowServer 都量（disc 栅格化的代价算在哪边没核实），最坏用 working 造型；Instruments 的 Core Animation 工具看 disc 有没有命中缓存。验收数字见 `docs/mascot.md`「性能验收」。

## 已知问题

- **用户定：先不管**：关掉「自动弹红卡」后恢复卡可能在违规期间放出；从等你回答换成等你批准不换卡；Mac 系统灵动岛会和我们抢位置（等 HIG 和 ActivityKit 在 macOS 上开放再定，当时的调研见 `git show f4792ab:docs/research/dynamic-island.md`）。
- 看不见时换了 A→B→A 回到原造型，也会重播进场。
- 滚出可视区的会话行，三蓝点循环照跑（量小）。
- 守卫只查 IPv4，IPv6 直连泄漏看不见；任何 utun 都算在隧道上，开着别的 VPN 时可能看漏；每 5 秒请求 3 个回显服务可能被限流（都是推断）。
- mod 写完盘才 `next(e)`，本地写盘挂住会拖住回合（认为不现实，没改）。
