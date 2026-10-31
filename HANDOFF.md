# HANDOFF

最后更新：2026-10-31（插件化第 2 刀之后）。只放接下来要做的和没解决的；做完的看 `git log`，规则看 `CLAUDE.md` 和 `docs/*`。开工前 `git log --oneline -5` 核对，工作区应是干净的。实机验证的技巧见 `docs/dev-notes.md`。

## 接下来

**新会话从这里开始**：插件化做到第 2 刀（卡片模型和内容块、点击动作和按钮都已提交，见 `git log`）。下一刀是第 3 刀。规则已经写进 CLAUDE.md「硬规则·插件」和 `docs/ui.md`「卡片」，设计全文在本机 `~/.claude/plans/agile-swimming-origami.md`（不在仓库里，下面是要点）。用户的偏好：文档尽量少、先做代码；每刀做完先汇报、等用户说「提交」。

**插件化**（用户 10-31 定方向并批准设计）：App 变成「刘海 + Pip + 卡片队列 + 面板」外壳，三类插件挂上去、产出同一种 `Card`（`Sources/NotchCore/Card.swift`）。

- 内置插件：出口守卫、Claude Code。能在设置里关；来源和判定仍在 `GuardCore` / `AgentCore`（mod 拿不到忙闲和介入、也没有原子写，所以 Claude Code 不改写通用格式）。只有守卫能用红、绿和 danger；外部卡在红卡挂着时排着（`CardQueue.Notice.coversAlert`）。
- 外部插件：脚本写收件箱，App 监听。第一个是「终端命令结束」。

剩下的切片，每刀 TDD → 零警告 + 全绿 → reviewer → 用户说了再提交：

3. **收件箱 + `PluginCore` + `nk`**
   - 目录 `~/Library/Application Support/Notchkeeper/inbox/{tmp,new}`（0700），照 Maildir：写 `tmp/` 再 rename 到 `new/`，App 读完即删。插件按 `plugins/<id>/manifest.json`（`{id, name, symbol}`）登记，没登记的丢。
   - 新 target `PluginCore`（纯值）：解析 v1 消息（只有 card）`v`、`plugin`、`id`、`at`、`group`、`title`、`subtitle`、`value`、`outcome`（done / failed / attention / info）、`block`、`action`、`buttons`、`staleAt`；字段名照 Adaptive Cards（`TextBlock` 的 text / fontType monospace、`FactSet` 的 facts{title,value}、`Action.OpenUrl` 的 url；activate、focusTerminal、进度、勾叉列表是扩展）；正文在边界按 `isNewline` 切成行；按插件限流（注入时间）；过期丢；解析不了的计数、删文件、不原样进日志（scheme 等外部字符串记之前截短）。
   - `CardQueue.Key` 加 `.group(String)`，同组替换（照 terminal-notifier `-group`）。
   - `AgentWatcher.swift` 里私有的 `Directory`（目录 + 每份 json 的 DispatchSource）提出来，给收件箱复用。
   - 新 executable target `nk`：`nk notify --plugin terminal --title … --value … --outcome done --fact 退出码=0 … --tty $TTY --pid $$`，用 `PluginCore` 编码校验，写 tmp 再 rename；装到 `bin/nk`（和 guardd 同目录）。
4. **终端命令插件**
   - 仓库里 `Resources/plugins/terminal/`：manifest + `notchkeeper.zsh`。设置页「安装」拷进 `plugins/terminal/`，显示一行 `source …` 让用户自己加进 `~/.zshrc`（硬规则：不改 zshrc），带拷贝按钮。
   - zsh 照 zsh-auto-notify / ntfy shell-integration：`add-zsh-hook preexec` 记 `EPOCHREALTIME` 和命令名（第一个词，去掉 sudo、env 赋值）；`precmd` 第一行取 `$?`（10-31 实测：每个 precmd 钩子读到的都是命令本身的退出码）；耗时 ≥ 10s、不在忽略表（vim nvim less man ssh top htop watch tmux …）才后台调 `nk`。只传命令名（用户定），参数不出 shell。卡：标题「<命令> 跑完了 / 失败了」，右侧耗时，facts（退出码、目录），点了跳回这个终端。
   - Ghostty 1.3.1 自带 `notify-on-command-finish`，但只进系统通知或响铃、交不出来，所以要自己做。前台正看着那个终端不弹（照它的 `unfocused`）：App 收到时 Ghostty 在前台且焦点终端就是这个 tty（复用 `Ghostty.swift` 的标记法）就不弹。
   - `TerminalRef` 加 tty；shell 没有启动时刻，改按「pid 的 tty == 消息里的 tty」校验。测试里用 `zsh -fi` + 假 `nk` 验退出码、阈值、忽略表、只传命令名。
5. **内置插件开关 + 设置页「插件」页**：守卫（允许列表、自动弹红卡、红卡常驻，从「出口守卫」页挪来）、Claude Code（`ClaudeModSection` 挪来）、终端（安装 + source 行）、其他外部插件开关、URL 白名单 `urlSchemes`（现在只能改 config.json）。`NKConfig` 加 `plugins: [id: {enabled}]`。违规中关守卫弹确认「出口仍不合规，确定关掉提醒？」，确认后撤红卡、Pip 不画守卫造型，guardd 照跑，再打开读一次就恢复。
6. **面板按插件分段 + 外部活动 + 状态与常驻**（和第 4 步的 MascotResolver 一起，用户 10-31 定）：
   - 面板每个开着的插件一段，行用统一模板（图标、标题、可选副标题、状态指示、右侧「距今多久」或短值、点击动作），内容由插件定；Claude 会话列表改走这个模板；用户在设置里管每段的开关、顺序、最多露几行。
   - 外部插件用活动（start / update / end，时间戳取新，照 ActivityKit）往自己那段加行、原地刷新进度（`CardQueue` 要加「原地更新不重放不响」）。
   - 每个插件报一个带紧急程度的状态（平静 / 进行中 / 要你看 / 严重，严重只有守卫能报）；收起时 Pip 和右耳显示最急的那个（照灵动岛 relevanceScore）；都平静时显示用户指定的「常驻插件」（默认守卫，可选不常驻）。
   - 一个插件都不开：只留左耳 Pip、右耳空着，面板只有「还没有开启的插件」和「打开插件设置」；设置里可关掉 Pip 变纯黑刘海（照 boring.notch 的空闲脸选项）。
7. 以后：快捷指令（App Intents，SwiftPM 能不能产出它要的元数据没核实）。

插件化这几刀还没实机试的：demo 卡上「看 Swift 文档」（https）按钮；`demo.sh blocks` 现在 release 构建也能触发（随第 4 步的 DEBUG 监听一起处理，到时要有 DEBUG 版的运行方式）。

**第 4 步：App 外壳重写**（排在插件化之后；用户 10-31 定插件化先做）。已做：`NotchCore` 的 `CardQueue`、`GuardPresentation`、`ViolationAlert`、`Card`。剩下：

- `NotchCore`：悬停状态机（HoverMachine）、MascotResolver（并进插件化第 6 刀；现在是 `AppState.look` 临时合成）、布局几何、配置解码（`Tests/NotchkeeperTests` 的测试跟着挪）。
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

## 建议用的 skill

- `tdd`：每一刀先写会失败的测试、亲眼看红；纯值逻辑在临时副本里改坏几处确认会红（`docs/dev-notes.md`）。
- `research`：第 3、4 刀动手前核实 Adaptive Cards 字段（`gh api repos/microsoft/AdaptiveCards/contents/schemas/src`）、zsh 钩子、Ghostty 行为。
- `run`：打包启动、`demo.sh` 弹卡、截图。
- `ui-ux-pro-max`：第 5、6 刀的设置页和面板分段。
- `domain-modeling`：活动、状态、常驻插件这些新词进 `docs/ubiquitous-language.md`。
- `writing-for-agents`：改 CLAUDE.md 时用。
- `handoff`：换会话时更新本文件（就是 `HANDOFF.md`，不另写 `handoff.md`）。
