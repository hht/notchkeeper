# HANDOFF

最后更新：2026-10-29。本文只放接下来要做的事和还没写进文档的决定；做完的看 `git log`，已定的规则看 `CLAUDE.md` 和 `docs/*`。换会话或开工前先读本文，再读 `CLAUDE.md`。

**新会话从这里开始**：
1. `git log --oneline -5` 核对最近的提交。
2. **第 4 步（App 外壳重写）**，内容见下表。第 3 步留给它的：
   - `AgentWatcher` 的事件（回合结束、需要你介入）现在只记日志，卡片和声音（Glass / Ping）在这一步接；每个会话的状态用 `AgentBoard.sessions`（App 里是 `AppState.sessions`）。
   - `AppState.look` 是临时的优先级合成（守卫 > agent > 空闲），晕和完整优先级进 `NotchCore` 的 MascotResolver。
   - 设置页「状态测试」的盾盾已经用 `state.look`（可能是 agent 造型），旁边文案还是 `presentation.title`，对不上。
3. 空闲 CPU 还没在无人操作时测到干净的数，方法见「待办」。

## 还没写进文档的决定

用户新定的事先记在这里，写进 `CLAUDE.md` 或 `docs/*` 后删掉。

- **告警时 agent 照样报告**（用户 10-29）：即使处在告警 / 危险状态（红卡、danger 等守卫造型），agent 状态一变（回合结束、需要你介入）也要照常报告：弹对应的卡、响对应的声音（Glass / Ping），停留一小会儿（用户举例 5 秒）后回到网络状态继续显示，直到恢复。
  - 细节由 agent 定（用户 10-29 授权）。依据：仓里现有的「常驻红卡 + 临时卡插在上面、放完回到红卡」（`Notch.swift` 的 `pendingAlert`），也是 HIG Live Activities 的做法——提醒「light up the screen and by default play the notification sound」，多个活动时常驻的那个不被挤掉（<https://developer.apple.com/design/human-interface-guidelines/live-activities>）。统一成一个模型，不为告警另写规则：
    - **两层**：底层是「持续的状况」，同一时刻只显示最高的一张：红卡（违规还在、没被关掉）> 介入卡（有会话在需要你介入、这一次没被关掉）> 无。几个会话同时在等你：approval > question（同 `docs/mascot.md` §2），同级取最早进入的。上层是「临时卡队列」：完成卡、恢复卡，以及进入需要你介入时那一次的介入提醒。
    1. **临时卡怎么放**：所有临时卡（不只是告警时）进同一个先进先出队列，一次放一张，每张按「卡片停留」设置倒计时（默认 6 秒，2–10 秒，鼠标停在卡上暂停；恢复卡保留现有的固定 4 秒例外，`NotchCard.recoveredSeconds`）；队列放空就回到底层那张。理由：一个设置管所有临时卡，用户想要 5 秒就拨到 5；平时两个会话同时结束也不会一张顶掉另一张。
    2. **同一个会话只留最新**：队列里还没放的、同一个会话的旧事件被它后来的事件替换（例如还没轮到「需要你介入」就已经回合结束，只放回合结束）。理由：只有最新状态有用，队列不会无限变长。
    3. **声音跟着卡响**：卡放出来那一刻才响它的声音，不在事件到达时响。理由：Basso、Glass、Ping 永远不叠在一起，听到的和看到的一一对应。
    4. **需要你介入**：进入时先作为临时卡放一次（响 Ping）；之后只要还在需要你介入、上面又没有更高的底层卡，就作为底层卡留着（不再响）。红卡在时它让位，违规恢复或红卡被关掉后，如果会话还在等你，介入卡回来。介入卡被手动关掉，照红卡的 `dismissedViolationSince` 按会话记「关掉的是哪一次」（pid + 进入需要你介入的时刻），同一次不再回来，下一次进入需要你介入照常提醒。理由：漏网是持续的安全问题，不能被一张等你回答的卡长期盖住；但等你的事也不能因为恢复了就丢。
    5. **违规开始插到最前**：新违规开始（红卡 + Basso）时，正在放的临时卡立刻让位，回到队列最前，之后从头再放、不再响（声音已经响过）；红卡先完整展示一次「卡片停留」的时间，再继续放队列。理由：违规刚发生的那一刻最要紧，被打断的提醒也不丢。
    6. **恢复卡排队**：违规恢复时，恢复卡照普通临时卡进队列，不顶掉正在放的 agent 卡。
    7. **盾盾**：卡片上的盾盾画这张卡自己的造型（agent 卡画 finished / question / approval，红卡画 danger）。收起态的优先级不变，仍是守卫 > agent（`docs/mascot.md` §2）：插队时刘海是卡片形态，耳朵本来就看不见。防火墙守住（shielded）时同样适用。
  - 第 4 步做 `NotchCore` 的卡片队列时写进文档，要改：CLAUDE.md 硬规则「红卡显示与否，只看当前状态和 `dismissedViolationSince`」（卡片队列成了第三个输入，**改硬规则要用户明确确认**）、CLAUDE.md 界面准则「红卡一直留到恢复」、`docs/egress-guard.md` 红卡规则、`docs/agent-integration.md`「提醒」。
- **展开面板布局**：agent 出了三版草稿（10-29，`/tmp/nk-proto/abc.png` 和渲染脚本 `panel.swift`，ImageRenderer 渲染；用户选定前别删，重启丢了就照下面的网格重新渲染），等用户选：A 现结构按网格对齐；B 灵动岛四区，状态居中；C 灵动岛四区，左盾盾、右「状态短名胶囊 + 齿轮」（跟着右耳）、刘海下一行出口详情。agent 推荐 C（HIG：expanded 是 compact 的放大版，元素相对位置不变；盾盾从左耳几乎原地长大；最矮）。三版共用网格：外边距 16pt，会话图标 28pt 圆角 10（和面板底角 26 同心），图标中心对盾盾身体中心，齿轮右缘对时间列右缘。选定后写进 `docs/ui.md`「面板布局」。

## 开发计划（agent 制定，10-29）

**原则**：先文档后代码；底层（MascotCore、AgentCore）先于 App 外壳；横切的需求（亮色、多语言）在重写 App 外壳时**从第一行就按规范写**，不先写死中文和黑色再返工。每一步都是：TDD → `swift build` 零警告 + `swift test` 全绿 → reviewer 至多两轮 → 用户明示后提交，同时更新本文件。

| 步 | 内容 | 产出 / 验收 | 状态 |
|---|---|---|---|
| 4 | **App 外壳重写**：<br>• `NotchCore`：GuardPresentation、CardQueue、HoverMachine、MascotResolver、配置解码（`Tests/NotchkeeperTests` 里的测试跟着挪）<br>• 面板网格重排（`docs/ui.md`「面板布局」，先出草稿）、展开时盾盾从左耳缓动到面板、接上「晕」<br>• 接上完成卡、需要介入卡和声音<br>• 亮色模式、多语言的基础设施，所有新文案走 String Catalog<br>• 精简设置页（加「在系统设置中更改语言…」按钮；设置窗口去掉强制暗色）<br>• `demo.sh` 的通知只在 DEBUG 构建里监听<br>• 刘海视图只订阅 `presentation` | 测试；亮暗 × 中英截图；CPU 验收 | 待做 |
| 5 | **防火墙**：root 实测 → 恢复脚本并实测 → 试运行和自动回滚 → 规则、LaunchDaemon、安装脚本、App 开关；shielded 造型接线 | 按全局 Contract「高影响」档收工 | 待做 |

## 面板布局的现状（第 4 步改，规则见 `docs/ui.md`）

用户 10-29 原话：「展开的时候，我们的盾盾需要缓动到正确位置；现在这个布局两侧都没对齐。」代码在 `Sources/Notchkeeper/Notch.swift` 的 `NotchDashboard`、`SessionRow`、`StatePill`、`NotchGearButton`。原因：

- 盾盾的图层画布 80 × 68pt 含右上装饰区，身体圆左缘离画布左边 16pt，而 HStack 按画布排。
- 标题文字起点 = 画布宽 80 + 间距 10，会话行文字起点 = 图标 22 + 间距 10，两列不在一条线上；会话图标 22pt 和盾盾身体 40pt 的中心对不上。
- 盾盾的 ▲ 装饰顶到面板上沿。
- 齿轮单独在右上角，右缘和时间列不齐；时间列只有 `minWidth: 58`，不是固定宽，英文「12 min. ago」约 75pt，会把胶囊往左推。
- 行首图标的 `.help` 悬停提示在 App 不在前台时可能不出现（`NSWindow.allowsToolTipsWhenApplicationIsInactive` 默认 false，推断，未实测）；齿轮的 `.help("设置")` 同理。
- 盾盾缓动的实现可以考虑把它提到 NotchRoot 这一层作为唯一一只，按展开进度插值位置和缩放，或者用 `matchedGeometryEffect`。它是 CA 图层视图，补间时不要重建图层。

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
  - `NotchController` 里的卡片队列、悬停状态机、布局几何、`GuardPresentation` 的判定进 `NotchCore`；红卡「关掉的是哪一次」现在分在 `AppState.dismissedViolationSince` 和 `NotchController.pendingAlert/violationAlerted` 两处，合成一个 owner；`Notch.swift:366` 用 `asyncAfter(0.5)` 等收起动画；`NKConfig` 去前缀；`ConfigStore` 每秒轮询，看不见时也在跑。
  - **删 `--selftest` 丢掉的覆盖，在 `NotchCore` 里用 swift test 补回**（原文 `git show d8a28dd:Sources/Notchkeeper/AgentEvents.swift`，约 50 条）：违规 → unknown → healthy 撤红卡；关掉的同一次违规不再弹、新的一次照弹；stale / clockSkew 且 lastVerdict 是 violated 时保留红卡、不响 Basso；非常驻红卡到时不重弹；恢复卡只在弹过红卡后出现；`GuardPresentation` 各状态的颜色和文案。
  - `config.json` 里的 `launchAtLogin`、`suppressWhenHostFrontmost`、`agents` 三个键下次存盘时会被去掉（没有消费者）。以后要做「按 agent 开关」从默认值重来。
- **Grok Bot**：只能识别「有新回复 / 等你回复」，做不做还没定。
