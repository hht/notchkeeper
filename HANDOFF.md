# HANDOFF

最后更新：2026-10-31（第 5 步：状态机和辅助程序写完、复审结论改完，下一刀安装脚本）。只放接下来要做的和没解决的；做完的看 `git log`，规则看 `CLAUDE.md` 和 `docs/*`。开工前 `git log --oneline -5` 核对。实机验证的技巧见 `docs/dev-notes.md`。

## 接下来

**新会话从这里开始**：正在做第 5 步防火墙，先看下面「第 5 步」。插件化和第 4 步都做完了（见 `git log`），第 4 步的实机验收用户 10-31 全过。

**和用户协作的规矩（10-31）**：
- 测试时**不能真的断网**、**不能重启这台 Mac**（`docs/firewall.md` §7 开头）。
- 要 root 的命令都由用户在没跑 agent 的终端里自己 `sudo` 执行，执行完 `sudo -k`；agent 不跑 sudo。请用户跑的命令单独放进代码块、写明只读与否：夹在长段落里用户会看不到。
- 不在用户机器上模拟键盘和点击；`demo.sh settings` 会抢焦点，用户在用机器时别用。
- 用户偏好：文档尽量少、先做代码。

**插件化**：App 是「刘海 + Pip + 卡片队列 + 面板」外壳，插件产出同一种 `Card`，各报一个 `PluginStatus`（紧急程度），面板里各占一段（`PanelRow`）。内置插件是出口守卫、Claude Code（id 见 `NotchCore/PluginID.swift`，外部插件不能用）。外部插件写收件箱（`nk notify`、`nk activity`），`InboxWatcher` 读，`InboxGate` 收，活动归 `ActivityBoard`；插件开没开只在 App 主线程的收件箱回调里判。

**快捷指令（App Intents）：用户 10-31 定先不做**。当时的调研：纯 `swift build` 产不出 `Metadata.appintents`；给 swiftc 加 `-emit-const-values` 和 `-Xfrontend -const-gather-protocols-file <协议清单>`（协议清单抄自 swift-build `SWBCore`），再在 `run.sh` 里手工跑 `xcrun appintentsmetadataprocessor`，/tmp 实测能生成含 intent 和 AppShortcut 的元数据。代价：参数和协议清单都没有文档、Xcode 升级可能坏；要装完整 Xcode；注册进快捷指令要用户在快捷指令 App 里看。出处：swift-build `Sources/SWBCore/SpecImplementations/Tools/SwiftCompiler.swift`、`Sources/SWBApplePlatform/Specs/AppIntentsMetadata.xcspec`。

插件化 10-31 实机验证过：设置 › 插件页（开关、面板顺序和行数、常驻插件、链接白名单的显示）；活动卡原地刷新；红卡挂着时外部卡排着、每个插件只补放最新 3 张、排着的活动卡被刷新；红卡挂着时关守卫红卡立刻撤；插件全关时面板的占位和纯黑刘海。还没试的：
- 面板「打开插件设置」按钮跳到插件页；设置页上移、下移、行数步进、白名单添加和报错（10-31 模拟的键盘输入落到了 Ghostty，之后不再在用户机器上模拟键盘和点击，要用户自己点）。
- 违规中关守卫的确认框：要真违规（`demo.sh alert` 不算违规，不弹确认）。
- 终端插件在 Ghostty 里的两件事：点卡片跳回 shell 所在的终端（按 tty 认）；焦点正停在跑命令的那个终端上时不弹（用户 10-31 定：只按那一个终端算，同窗口别的标签、分屏、别的窗口都照常弹；日志「正看着要跳回的终端」；同目录只开一个终端时才认得出）。10-31 用 AppleScript 在 Ghostty 里开新窗口试时，窗口在命令跑完前没了、原因没查；`script` 伪终端里跑的端到端已通。
- demo 卡上「看 Swift 文档」（https）按钮。

**第 5 步：防火墙**：root 实测 → 恢复脚本并实测 → 试运行和自动回滚 → 规则、LaunchDaemon、安装脚本、App 开关；shielded 造型接线。按全局 Contract「高影响」档收工。IPv6 一起处理。
- 恢复脚本 `scripts/firewall-rescue.sh` 实测通过（§7 第 1 步）。本机不能重启，重启类验收改成 §7 开头的「模拟开机」；测试时不能真的断网，用测试规则（只拦 `nobody`，§7）。
- 已写：`FirewallCore`（状态机、规则、核对、两个 JSON）和 `firewalld`（辅助程序，`round --tunnel <网卡> [--test-rules]` / `enable` / `keep` / `disable`），全在 `swift test` 里测，还没以 root 跑过。
- 下一刀：安装脚本 `scripts/install-firewall.sh`（编译、给用户看 plist、备份、用户自己 sudo；先只装 `--test-rules`），然后按 §7 第 2～6 步实机测：用 `--tunnel utun9999` 模拟 Clash 断开，`sudo -u nobody curl` / `dig` 看拦没拦；同时用 `pfctl -si` 量状态表占用、看空闲时 Evaluations 涨不涨（§5）。之后才接 App 开关和 shielded 造型。
- 还没定：Evaluations 空闲不涨时怎么处理（等实测）；正式规则什么时候装（要用户拍板）。
- 实测时顺带看：`pfctl -E` 之后 `pfctl -s References` 里我们那一行的进程名是什么。是 `notchkeeper-firewall` 的话，核对 token 时可以连进程名一起比，降低 `docs/firewall.md` §5「token 号码复用」误释放别人引用的概率（复审建议，10-31）。

## 等实机验证

- **Ghostty 跳转**：同目录开两个 Claude；Claude 套在 tmux 里（应退回按目录认）；工作中的会话多点几次，看转圈字符会不会盖掉标记（推断）。有一次脚本连点两行第二下没切过去、没复现：用户再遇到时记下哪一行、面板开着没有。
- **mod**：开着的会话装上后 `/reload-plugins` 应该开始写（没实测）；后台 agent 崩溃时会不会发带 `agentId` 的 `turn.complete`（不发的话该会话的完成卡被压住到 `/clear`）；后台 agent 在跑时 `/reload-plugins` 可能提前弹完成卡（推断）。`Funk` 出错音没人耳听过。
- **Claude Code 升级后**：重跑 `ClaudeMod/plugins/notchkeeper` 的 `claude plugin test`，在 tmux 里按 `docs/agent-integration.md`「实测」8 重测。
- **卡片流星**：介入卡、出错卡、恢复卡、红卡的颜色（`demo.sh question|approval|failed|alert`）；常驻红卡和减弱动态效果时的淡细边；悬停时流星停住、移开接着走；队列里下一张卡接上时流星从头扫一趟；流星每次 `layout` 重挂动画的 CPU。
- **面板**：减弱动态效果时 Pip 和徽章原地淡入淡出（要切系统设置，先问用户）；finished 的星、sleeping 的 Z 可能顶出面板上沿被裁（推断）；已停止的会话行；左耳 Pip 可能总低着头（推断）；设置页预览可能不跟鼠标（推断）。
- **灵动岛规范**（`docs/ui.md`）：IP 换值时数字滚动、徽章图标替换、VoiceOver 弹卡播报。
- **设置页**：`config.json` 解不开时的横幅（要临时改坏真实配置，先备份）。
- **空闲 CPU**：App 这边 10-31 测过、达标（数在那次提交说明里）。还没做的：WindowServer 那边算不出多少是我们的（disc 栅格化的代价算在哪边没核实），最坏的 working 造型没单独测；Instruments 的 Core Animation 工具看 disc 有没有命中缓存。方法：`run.sh` 后取 pid；循环读 `ioreg -c IOHIDSystem` 的 `HIDIdleTime`，≥ 30s 无人操作才用 `top -l 2 -s 1 -pid <pid> -stats pid,cpu` 取样，采样后仍无人操作才留，攒 60 个求平均，App 和 WindowServer 都量。验收数字见 `docs/mascot.md`「性能验收」。

## 已知问题

- **用户定：先不管**：关掉「自动弹红卡」后恢复卡可能在违规期间放出；从等你回答换成等你批准不换卡；Mac 系统灵动岛会和我们抢位置（等 HIG 和 ActivityKit 在 macOS 上开放再定，当时的调研见 `git show f4792ab:docs/research/dynamic-island.md`）。
- 看不见时换了 A→B→A 回到原造型，也会重播进场。
- 滚出可视区的会话行，三蓝点循环照跑（量小）。
- 守卫只查 IPv4，IPv6 直连泄漏看不见；任何 utun 都算在隧道上，开着别的 VPN 时可能看漏；每 5 秒请求 3 个回显服务可能被限流（都是推断）。
- `TerminalPluginTests` 在机器很忙时（紧跟一次全新编译）失败过一次，重跑都绿；推断是真 zsh 子进程的时序，没查。
- mod 写完盘才 `next(e)`，本地写盘挂住会拖住回合（认为不现实，没改）。
- 测试里当普通地址用的 `1.2.3.4`（`GuardCoreTests` 的 EgressGuard、GuardState、StickyVerdictRegression、ViolationContinuity，`guarddTests/AllowlistTests`，`GuardProbesTests/ProbeTests`，后者还有 `1.1.1.1`）不合 CLAUDE.md「测试里的 IP 用 198.51.100.x」；测解析边界的非法地址、特殊地址不算。

## 建议用的 skill

- `tdd`：每一刀先写会失败的测试、亲眼看红，再在临时副本里改坏实现确认测试会红（本会话每条新行为都这么做过）。
- `research`：动 pf / launchd 行为前先查一手资料（XNU 源码、man page、Mullvad `talpid-core/src/firewall/macos.rs`），结论写进 `docs/firewall.md` §6。
- `diagnosing-bugs`：实机测试规则时行为和预期不符就用它，先复现再改。
- `ui-ux-pro-max`：接 App 开关、试运行倒计时、shielded 造型时用。
- `domain-modeling`：防火墙的新词已进 `docs/ubiquitous-language.md`，再起名先查它。
- `run`：打包启动、`demo.sh` 弹卡、截图。
- `writing-for-agents`：改 CLAUDE.md 时用。
- `handoff`：换会话时更新本文件（就是 `HANDOFF.md`，不另写 `handoff.md`）。
