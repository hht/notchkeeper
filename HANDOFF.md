# HANDOFF

最后更新：2026-10-29。本文只放接下来要做的事和还没写进文档的决定；做完的看 `git log`，已定的规则看 `CLAUDE.md` 和 `docs/*`。换会话或开工前先读本文，再读 `CLAUDE.md`。

**新会话从这里开始**：
1. `git log --oneline -5` 核对：最新是 `c69254f feat(盾盾): 2b …`，工作区应当干净。
2. **第 3 步（agent 状态新来源）**，规格全在 `docs/agent-integration.md`：
   - 先做文末「待实测」4 条（`kind` 取值、子 agent 会不会单独写文件、`waitingFor` 全部取值、`kill -9` 后文件是否留下），只读元数据、不读 `name` 和对话内容，结果写回该文档、交用户看。10-29 本机只见到 3 份文件，都是 `kind: interactive`、`entrypoint: cli`、`status: busy`。
   - 再 TDD 新建核心 target `AgentCore`（纯值：解析 sessions 文件 → 状态、回合、回合结束、干了很久、中途接手、进程没了），外层读目录、`kill(pid, 0)` 放 App。`Package.swift` 加 target 和测试 target。
   - 接到盾盾：工作中 → working / longTurn，需要你介入 → question / approval（按 `waitingFor`），回合结束 → finished 5.2s。卡片和声音是第 4 步。
3. 空闲 CPU 还没在无人操作时测到干净的数，方法见「待办」。

## 还没写进文档的决定

（目前没有。用户新定的事先记在这里，写进 `CLAUDE.md` 或 `docs/*` 后删掉。）

## 开发计划（agent 制定，10-29）

**原则**：先文档后代码；底层（MascotCore、AgentCore）先于 App 外壳；横切的需求（亮色、多语言）在重写 App 外壳时**从第一行就按规范写**，不先写死中文和黑色再返工。每一步都是：TDD → `swift build` 零警告 + `swift test` 全绿 → reviewer 至多两轮 → 用户明示后提交，同时更新本文件。

| 步 | 内容 | 产出 / 验收 | 状态 |
|---|---|---|---|
| 3 | **agent 状态新来源**：先实测 `kind` 取值、子 agent 会不会写文件；新建 `AgentCore` 读 sessions 文件，三个事件 | 测试；实机只读冒烟 | 待做 |
| 4 | **App 外壳重写**：<br>• `NotchCore`：GuardPresentation、CardQueue、HoverMachine、MascotResolver、配置解码（`Tests/NotchkeeperTests` 里的测试跟着挪）<br>• 面板网格重排（`docs/ui.md`「面板布局」，先出草稿）、展开时盾盾从左耳缓动到面板、删「进程 claude 0」、接上「晕」<br>• 接上完成卡、需要介入卡和声音<br>• 亮色模式、多语言的基础设施，所有新文案走 String Catalog<br>• 精简设置页（加「在系统设置中更改语言…」按钮；设置窗口去掉强制暗色）<br>• 删除 `Sessions.swift`（旧的 `SessionScanner`、`ProcessCounts`、App 版 `AgentSession` / `AgentKind`）<br>• `demo.sh` 的通知只在 DEBUG 构建里监听<br>• 刘海视图只订阅 `presentation` | 测试；亮暗 × 中英截图；CPU 验收 | 待做 |
| 5 | **防火墙**：root 实测 → 恢复脚本并实测 → 试运行和自动回滚 → 规则、LaunchDaemon、安装脚本、App 开关；shielded 造型接线 | 按全局 Contract「高影响」档收工 | 待做 |

## 面板布局的现状（第 4 步改，规则见 `docs/ui.md`）

用户 10-29 原话：「展开的时候，我们的盾盾需要缓动到正确位置；现在这个布局两侧都没对齐。」代码在 `Sources/Notchkeeper/Notch.swift` 的 `NotchDashboard`、`SessionRow`、`StatePill`、`NotchGearButton`。原因：

- 盾盾的图层画布 80 × 68pt 含右上装饰区，身体圆左缘离画布左边 16pt，而 HStack 按画布排。
- 标题文字起点 = 画布宽 80 + 间距 10，会话行文字起点 = 图标 22 + 间距 10，两列不在一条线上；会话图标 22pt 和盾盾身体 40pt 的中心对不上。
- 盾盾的 ▲ 装饰顶到面板上沿。
- 齿轮单独在右上角，右缘和时间列不齐；时间列只有 `minWidth: 58`，「23分47秒前」更宽，把状态胶囊往左推。
- 运行中显示时长「13秒」，空闲显示距今「3分48秒前」，格式混用。
- 盾盾缓动的实现可以考虑把它提到 NotchRoot 这一层作为唯一一只，按展开进度插值位置和缩放，或者用 `matchedGeometryEffect`。它是 CA 图层视图，补间时不要重建图层。

## 工作方法备忘

- App 没改完、整包编不过时，想先跑核心测试：把 `Sources/<Core>` 和 `Tests/<Core>Tests` 拷到 `/tmp` 一个只含这两个 target 的临时包里跑 `swift test`。
- 测试第一次就全绿时，在临时副本里故意改坏几处数字，确认测试会红。
- 实机截图：收起态用 `screencapture -x -R <x>,0,400,44`（刘海在主屏顶部正中）；看一批造型或换造型过程，在 `/tmp` 搭一次性陈列（拷 `Sources/Notchkeeper/Mascot/*.swift` + MascotCore，`screencapture -l <windowID>` 连拍），用完删掉。几只盾盾会同时眨眼，截到一帧全是扁眼是眨眼，不是 bug。
- App 崩了看 `~/Library/Logs/DiagnosticReports/Notchkeeper-*.ips`（JSON 第二行起，看 triggered 线程的 frames）。
- 本机 shell 是 zsh：`for f in $files` 不按空格拆，用 `xargs`；BSD `sed` 不认 `\b`，用 `perl -pi -e`。
- 提交要拆分时不能用 `git add -p`：用 `git hash-object -w` + `git update-index --cacheinfo` 暂存某个文件的一部分，再 `git checkout-index -a --prefix=/tmp/x/` 导出暂存区单独构建、测试。

## 建议用的 skill

- `research`：第 3 步开头实测 sessions 文件（`docs/agent-integration.md`「待实测」），结论写回该文档。
- `tdd`：新建 `AgentCore` 的每个纯值类型都先写测试、亲眼看红。接口用语见 `codebase-design`。
- `domain-modeling`：第 3 步若出现新词（会话、回合等已在 `docs/ubiquitous-language.md`），先进词表。
- `diagnosing-bugs`：重测空闲 CPU 仍不达标时用。
- `run`：启动 App、截图。
- `ui-ux-pro-max`：第 4 步面板网格、动效节奏、实机评审。
- `handoff`：换会话时更新本文件（本仓的交接文档就是 `HANDOFF.md`，不另写 `handoff.md`；macOS 不分大小写，会覆盖它）。

## 待办与已知问题

- **配置文件解不开的横幅没实机截图**：P0 修复让设置页在 `config.json` 解不开时顶部显示横幅、禁用改配置的控件。实机验证要临时改坏真实的 `config.json`（先备份）；用户 10-29 定：先不做，第 4 步重写设置页时一起看。另外 reviewer 提过横幅的黄色和琥珀（egressMismatch）容易混，到时一起定。
- **盾盾亮色截图没截**：要切用户的系统外观，先问用户；贴刘海部分永远是黑的，亮色只影响设置窗口（第 4 步改）。
- **空闲 CPU 没测到干净的数**：10-29 测到 60s 平均 2.62%，但当时用户在操作，`sample` 显示 App 侧主要是鼠标事件和旧会话扫描 `SessionScanner`（约 0.7%），盾盾代码几乎看不到。对照：2a 关掉旧会话扫描时收起空闲 0.385%、鼠标持续移动 2.34%。重测方法：`./scripts/run.sh` 启动后取 pid；循环读 `ioreg -c IOHIDSystem` 的 `HIDIdleTime`（纳秒），≥ 30s 无人操作时才用 `top -l 2 -s 1 -pid <pid> -stats pid,cpu` 取一个样本，采样后仍无人操作才留下，攒够 60 个求平均；App 重启过要重新取 pid。`SessionScanner` 第 4 步删掉后再测一次。验收数字见 `docs/mascot.md` §5「性能验收」。
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
  - `NotchController` 里的卡片队列、悬停状态机、布局几何、`GuardPresentation` 的判定进 `NotchCore`；红卡「关掉的是哪一次」现在分在 `AppState.dismissedViolationSince` 和 `NotchController.pendingAlert/violationAlerted` 两处，合成一个 owner；`Notch.swift:366` 用 `asyncAfter(0.5)` 等收起动画；`NKConfig` 去前缀；`ConfigStore` 每秒轮询、`AppState` 每 4 秒扫会话，看不见时也在跑；`Sessions.swift` 还扫 Codex 会话、用 `JSONSerialization` 整行解码（读进了正文）。
  - **删 `--selftest` 丢掉的覆盖，在 `NotchCore` 里用 swift test 补回**（原文 `git show d8a28dd:Sources/Notchkeeper/AgentEvents.swift`，约 50 条）：违规 → unknown → healthy 撤红卡；关掉的同一次违规不再弹、新的一次照弹；stale / clockSkew 且 lastVerdict 是 violated 时保留红卡、不响 Basso；非常驻红卡到时不重弹；恢复卡只在弹过红卡后出现；`GuardPresentation` 各状态的颜色和文案。
  - `config.json` 里的 `launchAtLogin`、`suppressWhenHostFrontmost`、`agents` 三个键下次存盘时会被去掉（没有消费者）。以后要做「按 agent 开关」从默认值重来。
- **Grok Bot**：只能识别「有新回复 / 等你回复」，做不做还没定。
