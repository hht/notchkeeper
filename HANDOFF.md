# HANDOFF

最后更新：2026-10-31（插件化做完）。只放接下来要做的和没解决的；做完的看 `git log`，规则看 `CLAUDE.md` 和 `docs/*`。开工前 `git log --oneline -5` 核对。实机验证的技巧见 `docs/dev-notes.md`。

## 接下来

**新会话从这里开始**：插件化做完了（第 1–6 刀都已提交，见 `git log`）。规则在 CLAUDE.md「硬规则·插件」和 `docs/ui.md`「面板布局」「卡片」。用户的偏好：文档尽量少、先做代码；做完先汇报、等用户说「提交」。下一步是第 4 步（App 外壳重写，见下）。

**插件化**：App 是「刘海 + Pip + 卡片队列 + 面板」外壳，插件产出同一种 `Card`，各报一个 `PluginStatus`（紧急程度），面板里各占一段（`PanelRow`）。内置插件是出口守卫、Claude Code（id 见 `NotchCore/PluginID.swift`，外部插件不能用）。外部插件写收件箱（`nk notify`、`nk activity`），`InboxWatcher` 读，`InboxGate` 收，活动归 `ActivityBoard`；插件开没开只在 App 主线程的收件箱回调里判。

**快捷指令（App Intents）：用户 10-31 定先不做**。当时的调研：纯 `swift build` 产不出 `Metadata.appintents`；给 swiftc 加 `-emit-const-values` 和 `-Xfrontend -const-gather-protocols-file <协议清单>`（协议清单抄自 swift-build `SWBCore`），再在 `run.sh` 里手工跑 `xcrun appintentsmetadataprocessor`，/tmp 实测能生成含 intent 和 AppShortcut 的元数据。代价：参数和协议清单都没有文档、Xcode 升级可能坏；要装完整 Xcode；注册进快捷指令要用户在快捷指令 App 里看。出处：swift-build `Sources/SWBCore/SpecImplementations/Tools/SwiftCompiler.swift`、`Sources/SWBApplePlatform/Specs/AppIntentsMetadata.xcspec`。

插件化 10-31 实机验证过：设置 › 插件页（开关、面板顺序和行数、常驻插件、链接白名单的显示）；活动卡原地刷新；红卡挂着时外部卡排着、每个插件只补放最新 3 张、排着的活动卡被刷新；红卡挂着时关守卫红卡立刻撤；插件全关时面板的占位和纯黑刘海。还没试的：
- 面板「打开插件设置」按钮跳到插件页；设置页上移、下移、行数步进、白名单添加和报错（10-31 模拟的键盘输入落到了 Ghostty，之后不再在用户机器上模拟键盘和点击，要用户自己点）。
- 违规中关守卫的确认框：要真违规（`demo.sh alert` 不算违规，不弹确认）。
- 设置页往下滚时窗口标题叠在内容上（推断各页都有，原有样式）。
- 终端插件在 Ghostty 里的两件事：点卡片跳回 shell 所在的终端（按 tty 认）；焦点正停在跑命令的那个终端上时不弹（用户 10-31 定：只按那一个终端算，同窗口别的标签、分屏、别的窗口都照常弹；日志「正看着要跳回的终端」；同目录只开一个终端时才认得出）。10-31 用 AppleScript 在 Ghostty 里开新窗口试时，窗口在命令跑完前没了、原因没查；`script` 伪终端里跑的端到端已通。
- demo 卡上「看 Swift 文档」（https）按钮；`demo.sh blocks` 现在 release 构建也能触发（随第 4 步的 DEBUG 监听一起处理，到时要有 DEBUG 版的运行方式）。

**第 4 步：App 外壳重写**（排在插件化之后；用户 10-31 定插件化先做）。已做：`NotchCore` 的 `CardQueue`、`GuardPresentation`、`ViolationAlert`、`Card`。剩下：

- `NotchCore`：悬停状态机（HoverMachine）、布局几何（`NotchLayout`、`PanelShape`）、配置解码（`Tests/NotchkeeperTests` 的测试跟着挪）。Pip 画谁已经由 `PluginStatus.lead` 定，晕、睡着还在 App 里叠。
- 接上「点一下晕」。`MascotDirector` 的时钟决策（醒来、恢复、推迟小动作）抽成值类型测试；从 Coucou 搬来的代码重写掉，删 MIT 声明。
- 亮色、多语言基础设施：所有文案走 String Catalog；设置窗口去掉强制暗色，刘海窗口设 `.darkAqua`（现在没设），加「在系统设置中更改语言…」。
- 减弱动态效果时黑色形状的弹簧还没收紧（HIG Accessibility，`docs/ui.md`「灵动岛规范」12）。
- 精简设置页。「状态测试」的 Pip 用 `state.look`，旁边文案还是 `presentation.title`，对不上。
- `demo.sh` 的通知只在 DEBUG 构建里监听。刘海视图只订阅 `presentation`。
- `NotchController.collapse()` 用 `asyncAfter(0.5)` 等收起动画；`Config` 去前缀；`ConfigStore` 每秒轮询、看不见时也在跑。
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

## 建议用的 skill

- `tdd`：每一刀先写会失败的测试、亲眼看红；纯值逻辑在临时副本里改坏几处确认会红（`docs/dev-notes.md`）。
- `research`：第 3、4 刀动手前核实 Adaptive Cards 字段（`gh api repos/microsoft/AdaptiveCards/contents/schemas/src`）、zsh 钩子、Ghostty 行为。
- `run`：打包启动、`demo.sh` 弹卡、截图。
- `ui-ux-pro-max`：第 5、6 刀的设置页和面板分段。
- `domain-modeling`：活动、状态、常驻插件这些新词进 `docs/ubiquitous-language.md`。
- `writing-for-agents`：改 CLAUDE.md 时用。
- `handoff`：换会话时更新本文件（就是 `HANDOFF.md`，不另写 `handoff.md`）。
