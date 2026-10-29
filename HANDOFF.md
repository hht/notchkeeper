# HANDOFF

最后更新：2026-10-29（第 0、1 步做完）。换会话或开工前先读本文，再读 `CLAUDE.md`。

**新会话从这里开始**：
1. 第 2 步（盾盾 2b），见「第 2 步接手要点」。

## 已定决策

| 日期 | 决策 |
|---|---|
| 10-28 | 规则：除局域网外，全部流量必须走代理 |
| 10-28 | 守卫判定：violated = 去往公网的路由不走 utun，弹红卡、粘住，只有一轮完整的 healthy 才解除；egressMismatch 只显示琥珀色；unknown 显示灰色空心环，不弹卡 |
| 10-28 | 界面上完整显示出口 IP；日志不记 IP |
| 10-29 | 重新开始：之前多个 agent 留下的文档和原型全部删除，App 层和盾盾动画重写；GuardCore、GuardProbes、guardd、GuardWatch、~~AgentCore、AgentWatch~~ 保留，只修 bug（AgentCore / AgentWatch 已删，见下方 10-29 删除一行） |
| 10-29 | 不做「拦截 Claude」，不杀进程。改做一个统一的防火墙，只有一个开关，全开或全关。开启后，除局域网外，凡是不走 Clash 隧道的出站流量（IPv4 和 IPv6）一律丢弃 |
| 10-29 | 防火墙安全底线：先写恢复脚本 `scripts/firewall-rescue.sh` 并在本机实测通过，才能写 block 规则；每次开启都先试运行，2 分钟内没点「保留」就自动回滚；开启、保留、关闭都要输管理员密码（见 `docs/firewall.md`） |
| 10-29 | 防火墙 DNS：只用代理配置的 DNS。隧道以外、非 root 的 53 端口一律拦，局域网 DNS 也不放行（本机系统 DNS 本来就走 utun） |
| 10-29 | 防火墙开着、守卫判 violated、防火墙核对通过时：仍弹红卡，但图标换成锁，文案「代理断开，防火墙已拦住外网 · 没有泄漏」，不响 Basso |
| 10-29 | 盾盾是原创角色，删掉 Coucou 例外；移植自 Coucou 的旧代码在第 4 步删除之前，保留其 MIT 声明。动画要高级、活泼，空闲时有小动作，加回呼吸，眼睛和身体跟随鼠标（见 `docs/mascot.md`） |
| 10-29 | ~~守卫没有响应时，盾盾用沙漏造型；断网或探针没结果时，盾盾造型不变~~ → 被下面「断网有自己的造型」部分取代：沙漏造型保留；断网改用 offline 造型；探针没结果（probeFailed）仍不改造型，右耳灰色空心环 |
| 10-29 | 删掉 `--selftest`，纯逻辑测试全部改用 `swift test`；验收只看 `swift build` 零警告和 `swift test` 全绿 |
| 10-29 | 每批改动派只读的 reviewer 子 agent 审查（`.claude/agents/reviewer.md`），至多两轮；commit 仍要用户明示同意 |
| 10-29 | 汇报、提交说明、文档、注释一律用中文 |
| 10-29 | 盾盾动画不设帧率上限，越高越好：不给 `preferredFrameRateRange`。取舍：Apple 建议能低就低以省电，120Hz 下常驻循环的合成功耗记在 WindowServer 上，`top -pid` 量不到；用户选画面优先 |
| 10-29 | 跟随鼠标做成设置开关：设置页「盾盾」→「跟随鼠标」，`config.json` 的 `mascotFollowsMouse`，默认开 |
| 10-29 | 盾盾「二维图形模拟三维」：身体是球，眼睛贴在球面上，所有动作（包括跟随鼠标）都用头的朝向（yaw、pitch、roll）表达；有左右 360° 转圈和上下 360° 翻圈 |
| 10-29 | 伪 3D 用方案 (a) Core Animation 3D：yaw ⊃ pitch ⊃ roll 三层 `CATransformLayer`，眼睛图层 `anchorPointZ = −半径` 贴在球的切面上，`isDoubleSided = false` 藏背面。(b) 纯函数投影原型里和 (a) 画面一致，但每次输入变化都要重采样，弃用 |
| 10-29 | 眼睛放大到 ×1.35（相对 `docs/mascot.md` §3 现有尺寸） |
| 10-29 | 换造型全部补间：眼形逐点变形（所有眼形化成 120 点闭合多边形 + 对齐起点，照 Flubber）、渐变色过渡、头转到新造型的朝向（弹簧）、旧装饰缩小淡出 + 新装饰弹出（照 SF Symbols Replace）。原「眨眼换形」废弃；眨眼也改成眼形补间成一条线再回来 |
| 10-29 | 每个造型都有常驻节奏：身体呼吸、睁眼的造型眨眼、头的小动作、装饰循环（睡着的 zZZ 依次上浮等）。数字见 `docs/mascot.md` §5 |
| 10-29 | 新增 4 个造型：干了很久（longTurn）、等你批准（approval）、断网（offline）、防火墙守住（shielded）。共 16 个 |
| 10-29 | 收起态：**上面一排**（空闲、睡着、思考、工作、干了很久、等你回答、等你批准、完成）的装饰是角色的一部分，留在左耳盾盾身上；**下面一排**（出错、断网、出口不符、守卫没响应、危险、防火墙守住）的装饰是告示，挪到右耳当图标（和 40pt 装饰同尺寸、同动画，约 14pt），左耳只留脸。展开后面板里的 40pt 盾盾照常带装饰 |
| 10-29 | 右耳只有一个位置：照造型优先级，左右耳显示同一个状态（方案 A），不拆成网络 / agent 两条通道 |
| 10-29 | 展开时右耳图标不飞到面板：右耳淡出，面板里的装饰弹出。**但盾盾本身要从左耳缓动（位置 + 大小，弹簧）到面板里的位置**，它是同一个角色 |
| 10-29 | 支持亮色模式。范围：贴着刘海的部分（耳朵、面板、卡片）永远黑底白字，没刘海的外接屏也画黑块；只有设置窗口跟随系统；设置页的盾盾放在黑底圆角舞台上；不加 key line（`docs/ui.md`） |
| 10-29 | 支持多语言：简体中文（源语言）+ English；默认随系统，改语言照 Apple 建议跳系统设置「按 App 设语言」，App 不自己切；中文原文当键；`run.sh` 用 `xcstringstool` 编译 catalog（同意依赖 Xcode 自带工具）（`docs/ui.md`） |
| 10-29 | CLAUDE.md 硬规则「子 agent 五个信号只由 AgentCore / AgentWatch 负责」改为「判定 agent 状态将由第 3 步新建的 `AgentCore` 负责并配固定测试，来源 sessions 文件」（用户确认）。规则见 `docs/agent-integration.md` |
| 10-29 | 删除 `AgentCore` / `AgentWatch` 及其测试、`docs/agent-integration.md`（用户 10-29「删除所有无用的内容」）：App 从没接入，JSONL 路线已弃。第 3 步按 sessions 文件新建 `AgentCore`，`docs/agent-integration.md` 已按 sessions 文件重写 |
| 10-29 | agent 状态改从 `~/.claude/sessions/<pid>.json` 读（用户允许），直接监听文件（方案 A），**不写降级路径**：本机自用，格式变了用户自己改。只需要三个事件：**工作中、已停止、需要你介入（问问题 / 等批准）**，并且要有声音提示。细节见 `docs/agent-integration.md` |
| 10-29 | 思考、出错、被打断三个造型在 sessions 文件里没有信号：照样实现，暂不接线，不进优先级 |
| 10-29 | 需要你介入按 `waitingFor` 分成两个造型：权限类 → 等你批准，其余 → 等你回答 |
| 10-29 | 造型优先级：危险 / 防火墙守住 > 出口不符 > 守卫没响应 > 断网 > 晕 > 等你批准 > 等你回答 > 干了很久（回合 > 10 分钟）> 工作 > 完成 > 睡着 > 空闲 |
| 10-29 | 声音：回合结束 Glass，需要你介入 Ping，工作中不响；沿用一个「提示音」总开关 |
| 10-29 | 装饰两类叫 mood（心情装饰，留在左耳）/ sign（告示，收起时挪到右耳）（`docs/ubiquitous-language.md`） |
| 10-29 | 「晕」第 4 步接上：点一下面板里的盾盾 |
| 10-29 | 盾盾的代码前缀统一用 `Mascot`：target `MascotCore`、文档 `docs/mascot.md`、配置键 `mascotFollowsMouse`（用户的 config.json 里没有旧键，不丢设置）；App 侧图层类第 2 步重写时改名 |
| 10-29 | 删掉面板右上角的「进程 claude 0」 |
| 10-29 | 回合：从已停止进入工作中，到再次变成已停止；回合结束 = 回合中变成已停止；干了很久 = 工作中且离回合开始超过 10 分钟；中途接手的会话以 `statusUpdatedAt` 作回合开始、照常提醒，已在介入的不补响 Ping（`docs/agent-integration.md`） |
| 10-29 | 介入卡留到状态离开需要你介入才收回；面板时间列统一显示「状态变化距今」，用系统相对时间格式 |
| 10-29 | 盾盾动效里原型没有的部分：进 finished 播完成跳转、进 working 点头；眨眼间隔 2.5–6s 随机、15% 连眨；空闲小动作等概率（转圈、翻圈各 5%）；左耳到面板的飞行和形状同一组弹簧；右耳灰环盖过点、告示盖过灰环；finished 5.2s、dizzy 1.6s（`docs/mascot.md`） |

## 开发计划（agent 制定，10-29）

**原则**：先文档后代码；底层（MascotCore、AgentCore）先于 App 外壳；横切的需求（亮色、多语言）在重写 App 外壳时**从第一行就按规范写**，不先写死中文和黑色再返工。每一步都是：TDD → `swift build` 零警告 + `swift test` 全绿 → reviewer 至多两轮 → 用户明示后提交，同时更新本文件。

| 步 | 内容 | 产出 / 验收 | 状态 |
|---|---|---|---|
| 0 | 收尾：提交帧率上限、删除一轮；修 P0；原型提交到单独分支 `prototype/dundun-3d`，从 main 工作区删掉 | 提交（要用户同意） | 做完 |
| 1 | **文档一轮定稿**（一次给用户确认）：<br>• CLAUDE.md（用 `writing-for-agents`）：亮暗都支持、多语言、截图规则、agent 状态来源改成 sessions 文件、子 agent 过滤规则跟着改、「不写降级路径」<br>• `docs/mascot.md` §1–§5<br>• `docs/agent-integration.md`：sessions 文件、三个事件、声音<br>• 新建 `docs/ubiquitous-language.md`<br>• 新建 `docs/ui.md`：面板网格、亮色范围、多语言方案（见下） | 用户确认的文档 | 做完（10-29 用户确认） |
| 2 | **盾盾 2b**：MascotCore 加 4 个造型、眼形多边形和对齐、球面朝向、新编排；App 侧照原型 (a) 搭图层树、右耳告示 | 测试；实机截图（亮暗各一）；CPU 重测（120Hz、不限帧） | 待做 |
| 3 | **agent 状态新来源**：先实测 `kind` 取值、子 agent 会不会写文件；新建 `AgentCore` 读 sessions 文件，三个事件 | 测试；实机只读冒烟 | 待做 |
| 4 | **App 外壳重写**（原阶段 3）：<br>• `NotchCore`：GuardPresentation、CardQueue、HoverMachine、MascotResolver、配置解码（P0 的测试 `Tests/NotchkeeperTests` 跟着挪）<br>• 面板网格重排（`docs/ui.md`「面板布局」，先出草稿）、展开时盾盾从左耳缓动到面板、删「进程 claude 0」、接上「晕」<br>• 接上完成卡、需要介入卡和声音<br>• 亮色模式、多语言的基础设施，所有新文案走 String Catalog<br>• 精简设置页（加「在系统设置中更改语言…」按钮；设置窗口去掉强制暗色）<br>• 删除 `Sessions.swift`（旧的 `SessionScanner`、`ProcessCounts`、App 版 `AgentSession` / `AgentKind`）<br>• `demo.sh` 的通知只在 DEBUG 构建里监听<br>• 刘海视图只订阅 `presentation` | 测试；亮暗 × 中英截图；CPU 验收（2a 没过的那条） | 待做 |
| 5 | **防火墙**（原阶段 4）：root 实测 → 恢复脚本并实测 → 试运行和自动回滚 → 规则、LaunchDaemon、安装脚本、App 开关；shielded 造型接线 | 按全局 Contract「高影响」档收工 | 待做 |

已完成：阶段 0（文档重置）、1（后端清理）、2a（盾盾改用 Core Animation；CPU 验收因旧会话扫描没过，第 4 步删掉后重测）。

## 第 2 步接手要点

数字全在 `docs/mascot.md`；原型是一手资料，在分支 `prototype/dundun-3d`（`git show prototype/dundun-3d:prototype/dundun-3d/main.swift`），和文档冲突时以文档为准并指出。顺序：

1. TDD 改 MascotCore：`Look` 加 4 个 case；眼形多边形和对齐写成纯函数并单测（点数相同、绕向一致、对齐后平方距离最小；转 90° 时眼睛在边缘、宽度约 0，转 180° 不可见）；`Choreography` 按新节奏重写。
2. App 侧图层树照原型的 (a)，类型统一用 `Mascot` 前缀。

## 面板布局的现状（第 4 步改，规则见 `docs/ui.md`）

用户 10-29 原话：「展开的时候，我们的盾盾需要缓动到正确位置；现在这个布局两侧都没对齐。」代码在 `Sources/Notchkeeper/Notch.swift` 的 `NotchDashboard`、`SessionRow`、`StatePill`、`NotchGearButton`。原因：

- 盾盾的图层画布 80 × 68pt 含右上装饰区，身体圆左缘离画布左边 16pt，而 HStack 按画布排。
- 标题文字起点 = 画布宽 80 + 间距 10，会话行文字起点 = 图标 22 + 间距 10，两列不在一条线上；会话图标 22pt 和盾盾身体 40pt 的中心对不上。
- 盾盾的 ▲ 装饰顶到面板上沿。
- 齿轮单独在右上角，右缘和时间列不齐；时间列只有 `minWidth: 58`，「23分47秒前」更宽，把状态胶囊往左推。
- 运行中显示时长「13秒」，空闲显示距今「3分48秒前」，格式混用。
- 盾盾缓动的实现可以考虑把它提到 NotchRoot 这一层作为唯一一只，按展开进度插值位置和缩放，或者用 `matchedGeometryEffect`。它是 CA 图层视图，补间时不要重建图层。

## 2a 留下的实现取舍

- 看不见时撤掉全部动画（静止值在模型层上），回来时按共同起点 `DundunDirector.epoch` 重新挂循环，不用 `layer.speed = 0`：这样左耳和面板的相位保持一致。
- 只有睁着眼的造型看鼠标。
- 注视取整的格子 0.25 单位、0.5°：鼠标每换一次目标就是一次事务提交。

**2a 实测**（本机 Mac17,9，内建 120Hz 屏，release，`top -l 70 -s 1`）：

| 场景 | 旧版 `7374a88` | 2a 完整 App | 2a 关掉旧会话扫描 |
|---|---|---|---|
| 收起空闲 60s | 1.23% | 0.77% | 0.385%（无人操作的 33s 约 0.03%） |
| 鼠标持续移动 60s | 3.67% | 约 3.4% | 2.34%（跟随鼠标关掉时 1.99%） |

完整 App 没达标，原因是旧的会话扫描 `SessionScanner`（`AppState.swift:36` 每 4s 一次）。第 4 步删掉它之后应该重测。2b 的常驻节奏更多，也要重测，帧率不设上限（见决策表）。

## 建议用的 skill

- `tdd`：MascotCore 的每个纯值类型都先写测试。接口用语见 `codebase-design`。
- `ui-ux-pro-max`：面板网格、动效节奏、实机评审。
- `research`：第 3 步实测 sessions 文件（`docs/agent-integration.md`「待实测」）。
- `domain-modeling`：新领域词进词表。
- `run`：启动 App、截图。
- `diagnosing-bugs`：CPU 不达标时用。
- `handoff`：换会话时更新本文件（本仓的交接文档就是 `HANDOFF.md`，不另写 `handoff.md`；macOS 不分大小写，会覆盖它）。

## 待办与已知问题

- **配置文件解不开的横幅没实机截图**：P0 修复让设置页在 `config.json` 解不开时顶部显示横幅、禁用改配置的控件。实机验证要临时改坏真实的 `config.json`（先备份）；用户 10-29 定：先不做，第 4 步重写设置页时一起看。另外 reviewer 提过横幅的黄色和琥珀（egressMismatch）容易混，到时一起定。
- **盾盾实机检查**：2b 做完后补 16 个造型的截图（亮、暗各一；有外接屏时补无刘海的）。
- **2a 审查留下的（第 2 步一起改）**：
  - 换造型时 `stopLoops()` 直接撤循环：晕的摆锤、工作的浮动会一下子跳回 0。原型的做法同样会跳，写实现时用补间收尾。
  - 0.09s 内连续换两次造型时，「保持旧眼形」保持的是模型值，不是屏幕上的那个。改成眼形补间后，从呈现层取起点即可。
  - 看不见时 A→B→A 回到原造型，也会重播进场。
  - `DundunDirector` 的时钟决策（醒来时刻、恢复、推迟小动作）还没抽成值类型测试。
- **左耳盾盾可能总低着头**（reviewer 推断）：跟随鼠标超过 400pt 停在最大角度，左耳在屏幕最顶上，鼠标多在下方，收起时大多 pitch −20°，working 再叠 −10°。第 2 步实机留意。
- **设置页预览可能不跟鼠标**（推断）：Notchkeeper 在前台时，全局鼠标监听收不到本 App 窗口里的事件。第 4 步 处理。
- **MIT 声明**：`DundunDirector.swift`、`EarView.swift` 里从旧 `DundunView.swift` 搬来的代码保留了 Coucou 的 MIT 声明，第 4 步 重写时一起删掉。
- **IPv6**：守卫只查 IPv4，IPv6 直连泄漏看不见（推断，待实测 `route -n get -inet6`）。第 5 步 一起处理。
- **utun 判定过宽**：任何 utun 都算「在隧道上」，开着别的 VPN 时可能看漏（推断）。
- **出口探测频率**：每 5 秒请求 3 个回显服务，可能被限流（推断）。
- **旧注释**：指向已删文档的已改完；剩下「Emily 规格」「Emily 2026-10-28」几处出处说法（`Notch.swift`），第 4 步 重写时确认后改成 docs 出处。
- **审查发现、留给重写的**（10-29 两个只读审查 agent，删除之外的部分）：
  - 第 2 步：`DundunState` / `Look` / `DundunTestState` 三套枚举描述同一件事，只留 `Look`；`DundunConst` + `CGColor.hex`（Generic RGB）和 `RGB.cg`（sRGB）同一个 hex 两种色彩空间；`Choreography.Property` 的 rawValue 是 CA 键路径、`Look` 的参数叫 `guardUnknown`，核心知道了外层的名字；`DundunDirector` 犯困 / 回正 / 推迟小动作的时钟决策抽成纯值；`Dundun` / `Mascot` 两套前缀统一成 `Mascot`（用户 10-29）。
  - `DundunView.interactive` 全仓没人传 `true`：第 2 步先删这个死参数，第 4 步按新面板接上「点一下晕」（用户 10-29）。
  - 第 4 步：`NotchController` 里的卡片队列、悬停状态机、布局几何、`GuardPresentation` 的判定进 `NotchCore`；红卡「关掉的是哪一次」现在分在 `AppState.dismissedViolationSince` 和 `NotchController.pendingAlert/violationAlerted` 两处，合成一个 owner；`Notch.swift:366` 用 `asyncAfter(0.5)` 等收起动画；`Common.swift` 的 `enum Motion` 和领域词 motion 撞名；`NKConfig` 去前缀；`ConfigStore` 每秒轮询、`AppState` 每 4 秒扫会话，看不见时也在跑；`Sessions.swift` 还扫 Codex 会话、用 `JSONSerialization` 整行解码（读进了正文）。
  - **删 `--selftest` 丢掉的覆盖，第 4 步在 `NotchCore` 里用 swift test 补回**（reviewer 10-29；原文 `git show d8a28dd:Sources/Notchkeeper/AgentEvents.swift`，约 50 条）：违规 → unknown → healthy 撤红卡；关掉的同一次违规不再弹、新的一次照弹；stale / clockSkew 且 lastVerdict 是 violated 时保留红卡、不响 Basso；非常驻红卡到时不重弹；恢复卡只在弹过红卡后出现；`GuardPresentation` 各状态的颜色和文案。
  - `config.json` 里的 `launchAtLogin`、`suppressWhenHostFrontmost`、`agents` 三个键下次存盘时会被去掉（没有消费者）。以后要做「按 agent 开关」从默认值重来。
- **审查**：2a 之前第 2 轮 reviewer 查出的两条必须修已经改好，但没有再审一轮。
- **Grok Bot**：只能识别「有新回复 / 等你回复」，做不做还没定。
