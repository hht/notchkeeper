# HANDOFF

最后更新：2026-10-31（第 4 步做完，等实机验收）。只放接下来要做的和没解决的；做完的看 `git log`，规则看 `CLAUDE.md` 和 `docs/*`。开工前 `git log --oneline -5` 核对。实机验证的技巧见 `docs/dev-notes.md`。

## 接下来

**新会话从这里开始**：插件化和第 4 步（App 外壳重写）都做完了，见 `git log`。用户的偏好：文档尽量少、先做代码；整步做完再统一审、分批提交（10-31）。下一步：先补完下面「第 4 步实机验收」里要用户动手的几项，再做第 5 步防火墙。

**插件化**：App 是「刘海 + Pip + 卡片队列 + 面板」外壳，插件产出同一种 `Card`，各报一个 `PluginStatus`（紧急程度），面板里各占一段（`PanelRow`）。内置插件是出口守卫、Claude Code（id 见 `NotchCore/PluginID.swift`，外部插件不能用）。外部插件写收件箱（`nk notify`、`nk activity`），`InboxWatcher` 读，`InboxGate` 收，活动归 `ActivityBoard`；插件开没开只在 App 主线程的收件箱回调里判。

**快捷指令（App Intents）：用户 10-31 定先不做**。当时的调研：纯 `swift build` 产不出 `Metadata.appintents`；给 swiftc 加 `-emit-const-values` 和 `-Xfrontend -const-gather-protocols-file <协议清单>`（协议清单抄自 swift-build `SWBCore`），再在 `run.sh` 里手工跑 `xcrun appintentsmetadataprocessor`，/tmp 实测能生成含 intent 和 AppShortcut 的元数据。代价：参数和协议清单都没有文档、Xcode 升级可能坏；要装完整 Xcode；注册进快捷指令要用户在快捷指令 App 里看。出处：swift-build `Sources/SWBCore/SpecImplementations/Tools/SwiftCompiler.swift`、`Sources/SWBApplePlatform/Specs/AppIntentsMetadata.xcspec`。

插件化 10-31 实机验证过：设置 › 插件页（开关、面板顺序和行数、常驻插件、链接白名单的显示）；活动卡原地刷新；红卡挂着时外部卡排着、每个插件只补放最新 3 张、排着的活动卡被刷新；红卡挂着时关守卫红卡立刻撤；插件全关时面板的占位和纯黑刘海。还没试的：
- 面板「打开插件设置」按钮跳到插件页；设置页上移、下移、行数步进、白名单添加和报错（10-31 模拟的键盘输入落到了 Ghostty，之后不再在用户机器上模拟键盘和点击，要用户自己点）。
- 违规中关守卫的确认框：要真违规（`demo.sh alert` 不算违规，不弹确认）。
- 设置页往下滚时窗口标题叠在内容上（推断各页都有，原有样式）。
- 终端插件在 Ghostty 里的两件事：点卡片跳回 shell 所在的终端（按 tty 认）；焦点正停在跑命令的那个终端上时不弹（用户 10-31 定：只按那一个终端算，同窗口别的标签、分屏、别的窗口都照常弹；日志「正看着要跳回的终端」；同目录只开一个终端时才认得出）。10-31 用 AppleScript 在 Ghostty 里开新窗口试时，窗口在命令跑完前没了、原因没查；`script` 伪终端里跑的端到端已通。
- demo 卡上「看 Swift 文档」（https）按钮。

**第 4 步实机验收**（10-31 已实机看过：悬停展开和收起、完成卡和内容块卡、卡片放完收起、英文界面的面板和卡片、带 `-NSRequiresAquaSystemAppearance YES` 启动时刘海仍是黑的（这个参数对 App 生没生效，要打开设置页才看得出）；`AppState` 换成 Observation 后收起空闲 60 秒 `NotchRoot.body` 从 23 次降到 7 次，用户当时在用机器、不是干净的数）。要用户动手的：
- 点面板左上的 Pip：晕 1.6 秒，再点从头算；收起时点刘海仍是展开、卡片上点仍是打开卡片。
- 设置页亮色 × 中英截图（Pip 的黑底舞台、状态点、配置解不开的横幅）。只改这个 App 不动系统：`open build/Notchkeeper.app --args -AppleLanguages '(en)' -NSRequiresAquaSystemAppearance YES`；打开设置要用户点。
- 设置 › 通用「在系统设置中更改语言…」跳到「语言与地区」；在「App」里给 Notchkeeper 选 English 生不生效。
- 减弱动态效果时黑色形状不回弹（要切系统设置，先问用户）。
- 悬停：10-31 第一次试时停 0.9 秒没展开，之后 7 次都在 0.5 秒内展开；推断那次用户正在动鼠标。再遇到记下当时鼠标在哪。

**第 5 步：防火墙**：root 实测 → 恢复脚本并实测 → 试运行和自动回滚 → 规则、LaunchDaemon、安装脚本、App 开关；shielded 造型接线。按全局 Contract「高影响」档收工。IPv6 一起处理。

## 等实机验证

- **Ghostty 跳转**：同目录开两个 Claude；Claude 套在 tmux 里（应退回按目录认）；工作中的会话多点几次，看转圈字符会不会盖掉标记（推断）。有一次脚本连点两行第二下没切过去、没复现：用户再遇到时记下哪一行、面板开着没有。
- **mod**：开着的会话装上后 `/reload-plugins` 应该开始写（没实测）；后台 agent 崩溃时会不会发带 `agentId` 的 `turn.complete`（不发的话该会话的完成卡被压住到 `/clear`）；后台 agent 在跑时 `/reload-plugins` 可能提前弹完成卡（推断）。`Funk` 出错音没人耳听过。
- **Claude Code 升级后**：重跑 `ClaudeMod/plugins/notchkeeper` 的 `claude plugin test`，在 tmux 里按 `docs/agent-integration.md`「实测」8 重测。
- **卡片流星**：介入卡、出错卡、恢复卡、红卡的颜色（`demo.sh question|approval|failed|alert`）；常驻红卡和减弱动态效果时的淡细边；悬停时流星停住、移开接着走；队列里下一张卡接上时流星从头扫一趟；流星每次 `layout` 重挂动画的 CPU。
- **面板**：减弱动态效果时 Pip 和徽章原地淡入淡出（要切系统设置，先问用户）；finished 的星、sleeping 的 Z 可能顶出面板上沿被裁（推断）；已停止的会话行；左耳 Pip 可能总低着头（推断）；设置页预览可能不跟鼠标（推断）。
- **灵动岛规范**（`docs/ui.md`）：IP 换值时数字滚动、徽章图标替换、VoiceOver 弹卡播报。
- **设置页**：`config.json` 解不开时的横幅（要临时改坏真实配置，先备份；横幅的黄和琥珀容易混）；亮色截图（要切系统外观，先问用户）。
- **空闲 CPU**：App 这边 10-31 测过、达标（数在那次提交说明里）。还没做的：WindowServer 那边算不出多少是我们的（disc 栅格化的代价算在哪边没核实），最坏的 working 造型没单独测；Instruments 的 Core Animation 工具看 disc 有没有命中缓存。方法：`run.sh` 后取 pid；循环读 `ioreg -c IOHIDSystem` 的 `HIDIdleTime`，≥ 30s 无人操作才用 `top -l 2 -s 1 -pid <pid> -stats pid,cpu` 取样，采样后仍无人操作才留，攒 60 个求平均，App 和 WindowServer 都量。验收数字见 `docs/mascot.md`「性能验收」。

## 已知问题

- **用户定：先不管**：关掉「自动弹红卡」后恢复卡可能在违规期间放出；从等你回答换成等你批准不换卡；Mac 系统灵动岛会和我们抢位置（等 HIG 和 ActivityKit 在 macOS 上开放再定，当时的调研见 `git show f4792ab:docs/research/dynamic-island.md`）。
- 看不见时换了 A→B→A 回到原造型，也会重播进场。
- 滚出可视区的会话行，三蓝点循环照跑（量小）。
- 守卫只查 IPv4，IPv6 直连泄漏看不见；任何 utun 都算在隧道上，开着别的 VPN 时可能看漏；每 5 秒请求 3 个回显服务可能被限流（都是推断）。
- mod 写完盘才 `next(e)`，本地写盘挂住会拖住回合（认为不现实，没改）。
- 测试里当普通地址用的 `1.2.3.4`（`GuardCoreTests` 的 EgressGuard、GuardState、StickyVerdictRegression、ViolationContinuity，`guarddTests/AllowlistTests`，`GuardProbesTests/ProbeTests`，后者还有 `1.1.1.1`）不合 CLAUDE.md「测试里的 IP 用 198.51.100.x」；测解析边界的非法地址、特殊地址不算。

## 建议用的 skill

- `tdd`：每一刀先写会失败的测试、亲眼看红；纯值逻辑在临时副本里改坏几处确认会红（`docs/dev-notes.md`）。
- `research`：第 3、4 刀动手前核实 Adaptive Cards 字段（`gh api repos/microsoft/AdaptiveCards/contents/schemas/src`）、zsh 钩子、Ghostty 行为。
- `run`：打包启动、`demo.sh` 弹卡、截图。
- `ui-ux-pro-max`：第 5、6 刀的设置页和面板分段。
- `domain-modeling`：活动、状态、常驻插件这些新词进 `docs/ubiquitous-language.md`。
- `writing-for-agents`：改 CLAUDE.md 时用。
- `handoff`：换会话时更新本文件（就是 `HANDOFF.md`，不另写 `handoff.md`）。
