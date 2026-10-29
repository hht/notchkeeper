# HANDOFF

最后更新：2026-10-29。换会话或开工前先读本文，再读 `CLAUDE.md`。

## 已定决策

| 日期 | 决策 |
|---|---|
| 10-28 | 规则：除局域网外，全部流量必须走代理 |
| 10-28 | 守卫判定：violated = 去往公网的路由不走 utun，弹红卡、粘住，只有一轮完整的 healthy 才解除；egressMismatch 只显示琥珀色；unknown 显示灰色空心环，不弹卡 |
| 10-28 | 界面上完整显示出口 IP；日志不记 IP |
| 10-29 | 重新开始：之前多个 agent 留下的文档和原型全部删除，App 层和盾盾动画重写；GuardCore、GuardProbes、guardd、GuardWatch、AgentCore、AgentWatch 保留，只修 bug |
| 10-29 | 不做「拦截 Claude」，不杀进程。改做一个统一的防火墙，只有一个开关，全开或全关。开启后，除局域网外，凡是不走 Clash 隧道的出站流量（IPv4 和 IPv6）一律丢弃 |
| 10-29 | 防火墙安全底线：先写恢复脚本 `scripts/firewall-rescue.sh` 并在本机实测通过，才能写 block 规则；每次开启都先试运行，2 分钟内没点「保留」就自动回滚；开启、保留、关闭都要输管理员密码（见 `docs/firewall.md`） |
| 10-29 | 防火墙 DNS：只用代理配置的 DNS。隧道以外、非 root 的 53 端口一律拦，局域网 DNS 也不放行（本机系统 DNS 本来就走 utun） |
| 10-29 | 防火墙开着、守卫判 violated、防火墙核对通过时：仍弹红卡，但图标换成锁，文案「代理断开，防火墙已拦住外网 · 没有泄漏」，不响 Basso |
| 10-29 | 盾盾是原创角色，删掉 Coucou 例外；移植自 Coucou 的旧代码在阶段 2、3 删除之前，保留其 MIT 声明。动画要高级、活泼，空闲时有小动作，加回呼吸，眼睛和身体跟随鼠标（见 `docs/dundun.md`） |
| 10-29 | 守卫没有响应时，盾盾用沙漏造型；断网或探针没结果时，盾盾造型不变。两种情况右耳都显示灰色空心环，收起态不会被看成正常 |
| 10-29 | 删掉 `--selftest`，纯逻辑测试全部改用 `swift test`；验收只看 `swift build` 零警告和 `swift test` 全绿 |
| 10-29 | 每批改动派只读的 reviewer 子 agent 审查（`.claude/agents/reviewer.md`），至多两轮；commit 仍要用户明示同意 |
| 10-29 | 汇报、提交说明、文档、注释一律用中文 |

## 阶段与进度

| 阶段 | 内容 | 状态 |
|---|---|---|
| 0 | 文档重置：CLAUDE.md、README、本文件、`docs/dundun.md`、`docs/firewall.md`；删除旧文档和 `prototype/` | 已完成 |
| 1 | 后端：删除没人用的拦截接缝（`onVerdictChange`、`Verdict.intercepts`）；guardd 读上一份状态时不再用 `try?` 吞错误 | 进行中 |
| 2 | 盾盾新动画（见下方「接手要点」） | 下一步 |
| 3 | App 外壳重写：<br>• 新增 `NotchCore`：GuardPresentation、CardQueue、HoverMachine、MascotResolver、配置解码（同时修 P0）<br>• 刘海视图只订阅 `presentation`，不订阅含 `checkedAt` 的 `display`：Watcher 每轮都发是为了设置页的「上次检查」，不是 bug，但不该让整棵视图每 5 秒重算<br>• 接上 AgentWatch 的完成卡<br>• 精简设置页<br>• 删除 `AgentEvents.swift`、`Sessions.swift`、SelfTest<br>• `demo.sh` 的通知只在 DEBUG 构建里监听 | 待做 |
| 4 | 防火墙：资料已查（`docs/firewall.md` 第 6 节）。顺序：root 实测 → 恢复脚本并实测 → 试运行和自动回滚 → 规则、LaunchDaemon、安装脚本、App 开关 | 待做 |

## 阶段 2 接手要点：盾盾新动画

**依据**：`docs/dundun.md`。造型数据见第 1–4 节，动效表和性能验收见第 5 节。设计取舍记录在本机的 `~/.claude/plans/drifting-stirring-cloud.md`，有就读，没有不影响接手。

**先测旧版的基线。** 删旧代码之前，在刘海机型上测：

- 用 `./scripts/run.sh` 启动当前版本；
- 用 `top -l 70 -s 1 -pid <pid>` 测两种场景：收起空闲 60 秒、鼠标持续移动 60 秒；
- 数字记下来，提交时和新版对照。

旧版一删就没法再测了。

**结构**：

- **`DundunCore`**：整体重写，只依赖 CoreGraphics，纯值。
  - `Look`、`Palette`、`EyeShape`：眼形直接是 CGPath 数据，不再解析 SVG。
  - `Choreography`：给一个造型和一个动作，输出 `[Track]`。每个 Track 包含 keyPath、keyTimes、values、缓动、时长、重复次数、帧率范围。
  - `IdleDirector`：决定空闲时什么时候眨眼、做哪个小动作。随机数和时间都从参数注入。
  - `Gaze`：鼠标位移进来，眼睛偏移和身体倾角出去，带死区和上限。
- **App 侧**：
  - `DundunLayerView` 是一个 layer-backed 的 NSView，用 `NSViewRepresentable` 嵌进 SwiftUI。身体用 `CAGradientLayer` 加圆形遮罩，眼睛和装饰用 `CAShapeLayer`。
  - 写一个小的 `apply([Track])`，把 Track 翻译成 `CAKeyframeAnimation` / `CASpringAnimation`。
- **全 App 只有一个时钟**：左耳和面板里的盾盾同步动作。删掉每只盾盾各自的 Task 和 10Hz 鼠标 Timer；鼠标位置复用 `NotchController` 已有的全局 mouseMoved 监听。
- **看不见就停**：沿用 `Sources/Notchkeeper/Mascot/DundunView.swift` 现有的逻辑——`ScreenAnchorView` 读窗口遮挡状态，`DundunDirector` 处理熄屏和锁屏。停的时候设 `layer.speed = 0`，同时暂停时钟。
- **接口不变**：App 继续通过 `Mascot.swift` 的 `MascotRenderable` 和 `DundunState` 使用盾盾，阶段 3 之前 App 照样能编译。
- **要删的旧代码**：
  - `DundunPlayer`（帧预算）、`DundunTransition`、`DundunRender`、`DundunFrames`、`DundunEar` 的阶梯脉冲；
  - `Mascot/DundunArt.swift`、`CpuBench.swift`、`MascotDemo.swift`、`DundunSelfTest.swift`；
  - `Tests/DundunCoreTests/*`，按新接口重写。

  MIT 声明随移植代码一起删掉。设置页「关于」里的 Coucou 致谢留到阶段 3。
- **要先查清**：`CAAnimation.preferredFrameRateRange` 在 macOS 上能不能用。能用就把循环动作限在 30–60fps，查不到就不设。
- **和 ui-ux-pro-max 的偏差**：它的 SwiftUI 建议是用 `.animation`，不用 CABasicAnimation。常驻小部件按 WWDC23「Explore SwiftUI animation」改用 Core Animation，代码注释里写 `@see`。
- **验收**：
  - `swift test` 覆盖：减弱动态效果时没有位移类 Track、呼吸参数、`IdleDirector` 注入种子后可复现且不连续重复同一动作、`Gaze` 的死区和上限。
  - 实机逐个过 12 个造型、所有小动作、跟随鼠标、减弱动态效果，附暗色刘海截图。
  - 和基线对照：收起空闲 CPU 平均低于 0.5%，鼠标持续移动低于 3%。

## 建议用的 skill

- `tdd`：DundunCore 的每个纯值类型都先写测试。接口用语见 `codebase-design`。
- `ui-ux-pro-max`：调动效节奏、做实机评审。
- `research`：查 Core Animation 的帧率 API、Core Animation 在 macOS 上的行为。
- `run`：启动 App、截图。
- `diagnosing-bugs`：CPU 不达标时用。

## 待办与已知问题

- **P0**：`config.json` 有语法错误时，启动会用默认值覆盖整份文件，允许列表被清空（`Sources/Notchkeeper/Config.swift:67-77`）。阶段 3 修。
- **IPv6**：守卫只查 IPv4，IPv6 直连泄漏看不见（推断，待实测 `route -n get -inet6`）。防火墙会同时封 IPv6，阶段 4 一起处理。
- **完成判定**：AgentCore 只靠 `stop_reason` 判断回合结束，真实会话里可能永远判不出完成（推断）。阶段 3 接线前用 `NOTCHKEEPER_LIVE_AGENTS=1` 实测。
- **utun 判定过宽**：任何 utun 都算「在隧道上」，开着别的 VPN 时可能看漏（推断）。
- **出口探测频率**：每 5 秒请求 3 个回显服务，可能被限流（推断）。
- **旧注释**：后端的已改完。App target 和 DundunCore 里还有指向 `AGENTS.md`、`prototype/`、已删文档的注释，阶段 2、3 重写时一起去掉。
- **审查**：第 2 轮 reviewer 查出的两条必须修（防火墙状态摘要的新鲜度和存放位置；guardd 里过时的拦截注释）已经改好，但没有再审一轮。
- **Grok Bot**：只能识别「有新回复 / 等你回复」，做不做还没定。
