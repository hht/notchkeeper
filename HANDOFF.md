# HANDOFF

最后更新：2026-10-31。只放接下来要做的和没解决的；做完的看 `git log`，规则看 `CLAUDE.md` 和 `docs/*`。开工前 `git log --oneline -5` 核对，工作区应是干净的。

## 接下来

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

## 工作方法备忘

- 整包编不过时先跑核心测试：把 `Sources/<Core>` 和 `Tests/<Core>Tests` 拷到 `/tmp` 一个临时包里 `swift test`。测试第一次就全绿时，在副本里故意改坏几处，确认会红。
- 驱动 Claude Code 会话：`tmux -L <名字> new-session -d -s x -c <已信任的目录> claude --permission-mode default`，`send-keys` 发提示、`Escape` 拒绝批准；没信任的目录只写 `.key` 不写 `.json`。用完 `kill-server`，`kill -9` 过的会话手动删 `<pid>.json` / `.key`。停在「等你批准」：让它跑 `touch /tmp/<文件>`（`date` 在允许列表里）；「等你回答」：让它用 AskUserQuestion 问是非题。
- 截图：卡片和收起态 `screencapture -x -R 556,0,400,110`（刘海在主屏顶部正中）；看造型在 `/tmp` 搭一次性陈列，`screencapture -l <windowID>` 连拍。几只 Pip 同时扁眼是眨眼。
- 没有 cliclick：在 `/tmp` 写一次性 Swift 脚本，用 `CGEvent` 移动、点击、滚动，完了把鼠标移回原处。
- 崩溃看 `~/Library/Logs/DiagnosticReports/Notchkeeper-*.ips`；日志在 `~/Library/Logs/Notchkeeper/notchkeeper.log`。
- zsh：`for f in $files` 不按空格拆，用 `xargs`；BSD `sed` 不认 `\b`，用 `perl -pi -e`。
- 拆提交不能用 `git add -p`：`git hash-object -w` + `git update-index --cacheinfo` 暂存部分内容，`git checkout-index -a --prefix=/tmp/x/` 导出暂存区单独构建。
- 交接文档就是本文件，不另写 `handoff.md`（macOS 不分大小写，会覆盖它）。
