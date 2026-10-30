# HANDOFF

最后更新：2026-10-29。本文只放接下来要做的事和还没写进文档的决定；做完的看 `git log`，已定的规则看 `CLAUDE.md` 和 `docs/*`。换会话或开工前先读本文，再读 `CLAUDE.md`。

**新会话从这里开始**：
1. `git log --oneline -5` 核对最近的提交。
2. **第 4 步（App 外壳重写）**，内容见下表。第 3 步留给它的：
   - `AppState.look` 是临时的优先级合成（守卫 > agent > 空闲），晕和完整优先级进 `NotchCore` 的 MascotResolver。
   - 设置页「状态测试」的盾盾已经用 `state.look`（可能是 agent 造型），旁边文案还是 `presentation.title`，对不上。
3. 空闲 CPU 还没在无人操作时测到干净的数，方法见「待办」。

## 还没写进文档的决定

用户新定的事先记在这里，写进 `CLAUDE.md` 或 `docs/*` 后删掉。

- **只接 Claude Code**（用户 10-29）：Grok Bot 不做（对话在服务器上，本机只有 `desktop-status.json` 的 pid / signedIn 和 `~/.grokbot/local-exec-daemon.json` 的 `inflightCount`，分不出会话和状态）；Grok CLI（`~/.grok/active_sessions.json`）也不做。

## 开发计划（agent 制定，10-29）

**原则**：先文档后代码；底层（MascotCore、AgentCore）先于 App 外壳；横切的需求（亮色、多语言）在重写 App 外壳时**从第一行就按规范写**，不先写死中文和黑色再返工。每一步都是：TDD → `swift build` 零警告 + `swift test` 全绿 → reviewer 至多两轮 → 用户明示后提交，同时更新本文件。

| 步 | 内容 | 产出 / 验收 | 状态 |
|---|---|---|---|
| 4 | **App 外壳重写**：<br>• `NotchCore`（已有 CardQueue）：GuardPresentation、HoverMachine、MascotResolver、配置解码（`Tests/NotchkeeperTests` 里的测试跟着挪）<br>• 接上「晕」<br>• 亮色模式、多语言的基础设施，所有新文案走 String Catalog<br>• 精简设置页（加「在系统设置中更改语言…」按钮；设置窗口去掉强制暗色）<br>• `demo.sh` 的通知只在 DEBUG 构建里监听<br>• 刘海视图只订阅 `presentation` | 测试；亮暗 × 中英截图；CPU 验收 | 待做 |
| 5 | **防火墙**：root 实测 → 恢复脚本并实测 → 试运行和自动回滚 → 规则、LaunchDaemon、安装脚本、App 开关；shielded 造型接线 | 按全局 Contract「高影响」档收工 | 待做 |

## 面板还没实测的

版式已定（`docs/ui.md`「面板布局」），下面几处只在代码里推过、没在实机上看：

- **减弱动态效果**：盾盾和徽章换形态时应该原地淡出、新位置淡入，不飞（`NotchRoot.corners` 的 `.id(reduceMotion && open)`）。要切系统设置，先问用户。
- **悬停提示**：会话行和齿轮的 `.help` 在 App 不在前台时可能不出现（`NSWindow.allowsToolTipsWhenApplicationIsInactive` 默认 false，推断）。
- **英文时间列**：固定宽 66，英文「12 min. ago」约 75pt，可能被截（推断）。
- 滚出可视区的会话行，三蓝点循环照跑（量小，暂不管）。
- **提醒的声音没人耳验过**：Glass / Ping / Basso 由 `NSSound(named:)` 在卡放出来时播，agent 只看到了卡、日志，听不到。
- **过期的介入卡照样放**（问用户）：`docs/ui.md`「卡片」2 只在同一个会话来新卡时替换还没放的旧卡。两种情况会放出过期的「在等你批准 / 回答」并响 Ping：正在放的介入卡不被同会话的新卡替换（批准或拒绝后照样放完，再放完成卡）；会话从需要你介入回到工作中、或进程退出时不发事件，排着的介入卡没人撤。可选：AgentCore 状态一变就撤掉该会话还没放 / 正在放的介入卡。
- **锁屏、熄屏时卡片照样倒计时、照样响**（早就有，问用户）：字面上违反「看不见就不调度」；离开电脑时连着来的卡会挨个放完、挨个响，没人看到。`CardQueue` 已有 `pause` / `resume`，接上 `MascotDirector` 的锁屏熄屏状态就行。
- **关掉「自动弹红卡」后恢复卡可能在违规期间放出**（少见）：作废恢复卡只在 `CardQueue.raiseAlert` 里做，`autoAlert` 关着时 `guardChanged` 不调它。前提是开着时弹过红卡、之后关掉 `autoAlert`，再遇到违规 → healthy（恢复卡排在别的卡后面）→ 又违规。
- **卡弹到不动的鼠标底下会一直停着**（早就有）：`present` 见鼠标在卡上就暂停倒计时，鼠标不动就不恢复；现在后面的卡都排着等。
- **装饰顶出面板上沿**（推断）：32pt 盾盾上缘离面板顶 8，finished 的大星最高点约在 −0.8pt、闪烁还放大 0.18，sleeping 的 Z 上浮也可能碰到，会被形状裁掉一点。实机看 finished / sleeping。
- **删 small 尺寸**（单独一个 refactor 提交）：左耳改成面板盾盾缩小后，App 里没有 ≤ 24pt 的 `MascotView` 了。`MascotView` 的 `.small` 分支、`Size.small` 和 `decoration(.small)` 的数据只剩测试在用；`NotchLayout` 的 `earCanvas`、`earCanvasInset`、`earBodyCenterY`、`Ears.canvas` 只为算一个 `bodyCenter`。

## 工作方法备忘

- App 没改完、整包编不过时，想先跑核心测试：把 `Sources/<Core>` 和 `Tests/<Core>Tests` 拷到 `/tmp` 一个只含这两个 target 的临时包里跑 `swift test`。
- 测试第一次就全绿时，在临时副本里故意改坏几处数字，确认测试会红。
- 实机驱动 Claude Code 会话：`tmux -L <名字> new-session -d -s x -c <已信任的目录> claude --permission-mode default`，`tmux send-keys` 发提示、`Escape` 拒绝批准；没信任的目录只写 `.key` 不写 `.json`。用完 `kill-server`，`kill -9` 过的会话手动删留下的 `<pid>.json` / `.key`。
- 实机截图：收起态用 `screencapture -x -R <x>,0,400,44`（刘海在主屏顶部正中）；看一批造型或换造型过程，在 `/tmp` 搭一次性陈列（拷 `Sources/Notchkeeper/Mascot/*.swift` + MascotCore，`screencapture -l <windowID>` 连拍），用完删掉。几只盾盾会同时眨眼，截到一帧全是扁眼是眨眼，不是 bug。
- App 崩了看 `~/Library/Logs/DiagnosticReports/Notchkeeper-*.ips`（JSON 第二行起，看 triggered 线程的 frames）。
- 本机 shell 是 zsh：`for f in $files` 不按空格拆，用 `xargs`；BSD `sed` 不认 `\b`，用 `perl -pi -e`。
- 提交要拆分时不能用 `git add -p`：用 `git hash-object -w` + `git update-index --cacheinfo` 暂存某个文件的一部分，再 `git checkout-index -a --prefix=/tmp/x/` 导出暂存区单独构建、测试。

## 建议用的 skill

- `tdd`：`NotchCore` 的每个纯值类型都先写测试、亲眼看红。接口用语见 `codebase-design`。
- `domain-modeling`：新词先进 `docs/ubiquitous-language.md`。
- `diagnosing-bugs`：重测空闲 CPU 仍不达标时用。
- `run`：启动 App、截图。
- `ui-ux-pro-max`：第 4 步面板网格、动效节奏、实机评审。
- `handoff`：换会话时更新本文件（本仓的交接文档就是 `HANDOFF.md`，不另写 `handoff.md`；macOS 不分大小写，会覆盖它）。

## 待办与已知问题

- **配置文件解不开的横幅没实机截图**：P0 修复让设置页在 `config.json` 解不开时顶部显示横幅、禁用改配置的控件。实机验证要临时改坏真实的 `config.json`（先备份）；用户 10-29 定：先不做，第 4 步重写设置页时一起看。另外 reviewer 提过横幅的黄色和琥珀（egressMismatch）容易混，到时一起定。
- **盾盾亮色截图没截**：要切用户的系统外观，先问用户；贴刘海部分永远是黑的，亮色只影响设置窗口（第 4 步改）。
- **空闲 CPU 没测到干净的数**：10-29 测到 60s 平均 2.62%，但当时用户在操作，`sample` 显示 App 侧主要是鼠标事件和旧会话扫描 `SessionScanner`（约 0.7%，10-29 已删，换成事件驱动的 `AgentWatcher`），盾盾代码几乎看不到。对照：2a 关掉旧会话扫描时收起空闲 0.385%、鼠标持续移动 2.34%。重测方法：`./scripts/run.sh` 启动后取 pid；循环读 `ioreg -c IOHIDSystem` 的 `HIDIdleTime`（纳秒），≥ 30s 无人操作时才用 `top -l 2 -s 1 -pid <pid> -stats pid,cpu` 取一个样本，采样后仍无人操作才留下，攒够 60 个求平均；App 重启过要重新取 pid。旧扫描删掉后还没重测。验收数字见 `docs/mascot.md` §5「性能验收」。
- 看不见时换了 A→B→A 回到原造型，也会重播进场。
- `MascotDirector` 的时钟决策（醒来时刻、恢复、推迟小动作）还没抽成值类型测试（第 4 步）。
- **左耳盾盾可能总低着头**（推断）：跟随鼠标超过 400pt 停在最大角度，左耳在屏幕最顶上，鼠标多在下方，收起时大多 pitch −20°，working 再叠 −10°。第 4 步做面板时用户实际看一下。
- **设置页预览可能不跟鼠标**（推断）：Notchkeeper 在前台时，全局鼠标监听收不到本 App 窗口里的事件。第 4 步 处理。
- **MIT 声明**：`MascotDirector.swift` 里从旧 `DundunView.swift` 搬来的代码（犯困、熄屏锁屏）保留了 Coucou 的 MIT 声明，第 4 步重写时一起删掉。
- **IPv6**：守卫只查 IPv4，IPv6 直连泄漏看不见（推断，待实测 `route -n get -inet6`）。第 5 步 一起处理。
- **utun 判定过宽**：任何 utun 都算「在隧道上」，开着别的 VPN 时可能看漏（推断）。
- **出口探测频率**：每 5 秒请求 3 个回显服务，可能被限流（推断）。
- **旧注释**：指向已删文档的已改完；剩下「Emily 规格」「Emily 2026-10-28」几处出处说法（`Notch.swift`），第 4 步 重写时确认后改成 docs 出处。
- **留给第 4 步重写的**：
  - 按新面板接上「点一下晕」。
  - `NotchController` 里的卡片队列、悬停状态机、布局几何、`GuardPresentation` 的判定进 `NotchCore`；红卡「关掉的是哪一次」现在分在 `AppState.dismissedViolationSince` 和 `NotchController.violationAlerted` 两处，合成一个 owner；`NotchController.collapse()` 用 `asyncAfter(0.5)` 等收起动画；`NKConfig` 去前缀；`ConfigStore` 每秒轮询，看不见时也在跑。
  - **删 `--selftest` 丢掉的覆盖，在 `NotchCore` 里用 swift test 补回**（原文 `git show d8a28dd:Sources/Notchkeeper/AgentEvents.swift`，约 50 条）：违规 → unknown → healthy 撤红卡；关掉的同一次违规不再弹、新的一次照弹；stale / clockSkew 且 lastVerdict 是 violated 时保留红卡、不响 Basso；非常驻红卡到时不重弹；恢复卡只在弹过红卡后出现；`GuardPresentation` 各状态的颜色和文案。
  - `config.json` 里的 `launchAtLogin`、`suppressWhenHostFrontmost`、`agents` 三个键下次存盘时会被去掉（没有消费者）。以后要做「按 agent 开关」从默认值重来。
