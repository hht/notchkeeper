# HANDOFF

最后更新：2026-10-29（帧率上限、全仓删除一轮、P0 修复已提交；阶段 2b 原型定稿，文档还没改）。换会话或开工前先读本文，再读 `CLAUDE.md`。

**新会话从这里开始**：
1. 按「开发计划」走第 0 步剩下的部分（原型挪到单独分支，要用户同意）和第 1 步（文档定稿）。

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
| 10-29 | 盾盾是原创角色，删掉 Coucou 例外；移植自 Coucou 的旧代码在阶段 2、3 删除之前，保留其 MIT 声明。动画要高级、活泼，空闲时有小动作，加回呼吸，眼睛和身体跟随鼠标（见 `docs/mascot.md`） |
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
| 10-29 | 每个造型都有常驻节奏：身体呼吸、睁眼的造型眨眼、头的小动作、装饰循环（睡着的 zZZ 依次上浮等）。数字以原型为准（见下方「阶段 2b 接手要点」） |
| 10-29 | 新增 4 个造型：干了很久（longTurn）、等你批准（approval）、断网（offline）、防火墙守住（shielded）。共 16 个 |
| 10-29 | 收起态：**上面一排**（空闲、睡着、思考、工作、干了很久、等你回答、等你批准、完成）的装饰是角色的一部分，留在左耳盾盾身上；**下面一排**（出错、断网、出口不符、守卫没响应、危险、防火墙守住）的装饰是告示，挪到右耳当图标（和 40pt 装饰同尺寸、同动画，约 14pt），左耳只留脸。展开后面板里的 40pt 盾盾照常带装饰 |
| 10-29 | 右耳只有一个位置：照造型优先级，左右耳显示同一个状态（方案 A），不拆成网络 / agent 两条通道 |
| 10-29 | 展开时右耳图标不飞到面板：右耳淡出，面板里的装饰弹出。**但盾盾本身要从左耳缓动（位置 + 大小，弹簧）到面板里的位置**，它是同一个角色 |
| 10-29 | **支持亮色模式**（用户 10-29）。推翻 CLAUDE.md「只做暗色」，CLAUDE.md 还没改，见待办第一条 |
| 10-29 | **支持多语言**：默认随系统语言，设置里可以改（用户 10-29）。方案见「开发计划 · 多语言」 |
| 10-29 | CLAUDE.md 硬规则「子 agent 五个信号只由 AgentCore / AgentWatch 负责」改为「判定 agent 状态将由第 3 步新建的 `AgentCore` 负责并配固定测试，来源 sessions 文件」（用户确认）。具体过滤规则第 3 步实测后写进新的 `docs/agent-integration.md` |
| 10-29 | 删除 `AgentCore` / `AgentWatch` 及其测试、`docs/agent-integration.md`（用户 10-29「删除所有无用的内容」）：App 从没接入，JSONL 路线已弃。第 3 步按 sessions 文件新建 `AgentCore`，文档第 1 步重写 |
| 10-29 | agent 状态改从 `~/.claude/sessions/<pid>.json` 读（用户允许），直接监听文件（方案 A），**不写降级路径**：本机自用，格式变了用户自己改。只需要三个事件：**工作中、已停止、需要你介入（问问题 / 等批准）**，并且要有声音提示。细节和待核实项见「agent 状态新来源」 |

## 开发计划（agent 制定，10-29）

**原则**：先文档后代码；底层（MascotCore、AgentCore）先于 App 外壳；横切的需求（亮色、多语言）在重写 App 外壳时**从第一行就按规范写**，不先写死中文和黑色再返工。每一步都是：TDD → `swift build` 零警告 + `swift test` 全绿 → reviewer 至多两轮 → 用户明示后提交，同时更新本文件。

| 步 | 内容 | 产出 / 验收 | 状态 |
|---|---|---|---|
| 0 | 收尾：提交帧率上限、删除一轮（都已过 reviewer）；修 P0；原型提交到单独分支 `prototype/dundun-3d`，从 main 工作区删掉 | 提交（要用户同意） | 两个提交、P0 已做；原型分支待做 |
| 1 | **文档一轮定稿**（一次给用户确认）：<br>• CLAUDE.md（用 `writing-for-agents`）：亮暗都支持、多语言、截图规则、agent 状态来源改成 sessions 文件、子 agent 过滤规则跟着改、「不写降级路径」<br>• `docs/mascot.md` §1–§5（见「阶段 2b 接手要点」）<br>• `docs/agent-integration.md`：sessions 文件、三个事件、声音<br>• 新建 `docs/ubiquitous-language.md`<br>• 新建 `docs/ui.md`：面板网格、亮色范围、多语言方案（见下） | 用户确认的文档 | 待做 |
| 2 | **盾盾 2b**：MascotCore 加 4 个造型、眼形多边形和对齐、球面朝向、新编排；App 侧照原型 (a) 搭图层树、右耳告示 | 测试；实机截图（亮暗各一）；CPU 重测（120Hz、不限帧） | 待做 |
| 3 | **agent 状态新来源**：先实测 `kind` 取值、子 agent 会不会写文件；新建 `AgentCore` 读 sessions 文件，三个事件 | 测试；实机只读冒烟 | 待做 |
| 4 | **App 外壳重写**（原阶段 3）：<br>• `NotchCore`：GuardPresentation、CardQueue、HoverMachine、MascotResolver、配置解码（P0 的测试 `Tests/NotchkeeperTests` 跟着挪）<br>• 面板网格重排、展开时盾盾从左耳缓动到面板<br>• 接上完成卡、需要介入卡和声音<br>• 亮色模式、多语言的基础设施，所有新文案走 String Catalog<br>• 精简设置页（加「语言」「声音」）<br>• 删除 `Sessions.swift`（旧的 `SessionScanner`、`ProcessCounts`、App 版 `AgentSession` / `AgentKind`）<br>• `demo.sh` 的通知只在 DEBUG 构建里监听<br>• 刘海视图只订阅 `presentation` | 测试；亮暗 × 中英截图；CPU 验收（2a 没过的那条） | 待做 |
| 5 | **防火墙**（原阶段 4）：root 实测 → 恢复脚本并实测 → 试运行和自动回滚 → 规则、LaunchDaemon、安装脚本、App 开关；shielded 造型接线 | 按全局 Contract「高影响」档收工 | 待做 |

已完成：阶段 0（文档重置）、1（后端清理）、2a（盾盾改用 Core Animation；CPU 验收因旧会话扫描没过，第 4 步删掉后重测）。

### 多语言（用户 10-29：默认随系统语言，可以在设置里改）

开工前要查清并交用户定的（第 1 步写进 `docs/ui.md`）：
- **支持哪些语言**：agent 建议简体中文（源语言）+ English，要问。
- **怎么做（照 Apple 的做法，先 `research` 查一手资料）**：
  - 用 String Catalog（`.xcstrings`）。`Package.swift` 加 `defaultLocalization` 和资源。
  - `scripts/run.sh` 目前只拷二进制和 Info.plist，SwiftPM 的资源 bundle 要一起打进 .app，`Bundle.module` 在 .app 里能不能找到要实测。
  - Info.plist 要声明支持的语言（`CFBundleLocalizations`）。
- **「可以设置」怎么实现**：macOS 13 起系统设置里有「按 App 设语言」。App 内设置常见两种做法：写 `AppleLanguages` 后重启 App；或者自己按选中的语言取 bundle。哪种是 Apple 推荐的、能不能即时生效，要查，查完给用户选。
- **范围**：界面文案、卡片、设置页、通知声音的说明文字。日志、文档、注释、提交说明仍是中文（CLAUDE.md「汇报」一节不变）。出口 IP、项目名不翻译。
- **测试**：文案键齐全（每个键每种语言都有译文），用测试守住；实机截图中、英各一。

### 亮色模式

见「待办与已知问题」第一条：建议贴着刘海的部分永远纯黑，亮色只作用于设置窗口等；第 1 步查 HIG 后和用户确认范围。

## 未提交的改动

- **原型** `prototype/dundun-3d/`（未跟踪）：`main.swift` + `run.sh`。运行 `./prototype/dundun-3d/run.sh`。按 prototype skill 的规矩，用完要提交到一个单独分支（例如 `prototype/dundun-3d`），不进 main；这也要用户同意。写完文档后从 main 的工作区删掉。

帧率上限、全仓删除一轮、P0 已提交（10-29，`refactor: 去掉盾盾动画的帧率上限`、`refactor: 删除没有调用方和从没生效的代码`、`fix: config.json 解不开时不再用默认值覆盖`），删了什么、怎么修的见各自的提交说明。

## 阶段 2b 接手要点

**原型是一手资料**：所有数字都在 `prototype/dundun-3d/main.swift` 里，用户已认可，照抄进文档，不要重新设计。关键位置：

| 内容 | 原型里的位置 |
|---|---|
| 16 个造型的颜色、新增 4 个的装饰形状 | `enum Face`（`gradient`、`decoration`） |
| 眼形（以眼中心为原点、×1.35 前的画布单位） | `eyeDesign` |
| 每个造型的头部朝向 | `headPose` |
| 装饰部件的锚点 | `decoration(_:)` |
| 换造型补间（时长、弹簧） | `Mascot.show` |
| 身体、头、眨眼的常驻节奏 | `Mascot.startLoops` |
| 装饰的常驻节奏、进出场 | `Deco.startLoops`、`Deco.enter` / `exit` |
| 右耳：告示图标、上排的点 | `RightEar`、`Face.isAlert`、`Face.earDots` |
| 刘海预览（收起 / 展开过渡） | `NotchPreview` |
| 11 个动作（转圈、翻圈、东张西望、点头、歪头、摇头、抬头看天、低头看脚、侧身 90°、好奇歪看、完成跳转） | `moves` |
| 跟随鼠标：400pt 内 yaw ±25°、pitch ±20°，取整 0.5°，弹簧 response 0.3 / damping 0.85 | `Controller.mouseMoved`、`Mascot.lookAt` |

**眼形相对 `docs/mascot.md` §3 的改动**：
- 思考：两只眼同向往右上看（看向思考云）。原来的一圆一线用户说怪。
- 工作 / 干了很久：两只眼往下看（看手上的活）。原来的半圆眼像犯困。
- 等你回答：竖长大眼 + 歪头 −10°。
- 出口不符：正圆 O O。
- 守卫没响应：耷拉的半睁眼。
- 危险：圆眼被往鼻梁压下的斜眉切掉内上角（怒眼）。
- 防火墙守住：上沿压平的镇定眼。
- spark 眼形不再使用。

**实现要点**（原型里实测过的外部行为）：
- 翻转视图（geometryFlipped）里：`rotation.y` 正 = 脸朝右，`rotation.x` 正 = 抬头，`rotation.z` 正 = 顺时针。
- 眼睛在球面上偏离正中约 20°，所以静止时宽度是原来的 cos 20° ≈ 0.94，是三维的正常结果，用户没提意见。
- 循环用 `CAKeyframeAnimation` + `timeOffset` 错开相位，起步无缝；动作是 additive，叠在跟随鼠标的模型值上。
- 眼形补间：`CGPath.flattened` → 按弧长重采样到 120 点 → 统一绕向 → 旋转起点让平方距离最小。描边类眼形（闭眼、笑眼、><、螺旋）先化成带圆头的轮廓再采样。

**写文档的顺序**：
1. 改 `docs/mascot.md`：§1 加球面模型和角度；§2 改成 16 个造型，含左右耳归属（上排 / 下排）和新的右耳指示（上排：三蓝点、青点、青柠点 `#B5E04A`；下排：装饰图标；probeFailed：灰环）；§3 新眼形（×1.35）；§4 新增 4 个装饰；§5 补间、常驻节奏、眨眼、动作清单、优先级。给用户确认。
2. 新领域词进 `docs/ubiquitous-language.md`：look 的 16 个名字、上排 / 下排（建议叫 mood decoration / alert sign，先问用户）、Track、Cue、Pose、Part、Gaze、EarIndicator。
3. TDD 改 MascotCore：`Look` 加 4 个 case；眼形多边形和对齐写成纯函数并单测（点数相同、绕向一致、对齐后平方距离最小；转 90° 时眼睛在边缘、宽度约 0，转 180° 不可见）；`Choreography` 按新节奏重写。
4. App 侧图层树照原型的 (a)。

**造型优先级（agent 提议，写文档时请用户确认）**：守卫（danger / shielded > mismatch > stale > offline）> 晕 > agent（等你批准 > 等你回答 > 出错 > 干了很久 > 工作 > 思考 > 完成……）> 睡着 > 空闲。「干了很久」的门槛暂定一个回合超过 10 分钟。

## agent 状态新来源（`~/.claude/sessions/<pid>.json`）

**调研结论**（后台 agent 实测本机 Claude Code 2.1.296，扫了 163 个会话，只看元数据）：
- 会话 JSONL 判断不了「等批准」：弹窗时什么都不写，最后一条就是普通 `tool_use`；等批准和工具在跑的时长大幅重叠（自动放行的 Bash 最长 602s，等批准最短 2s）。
- 每个 Claude Code 进程写 `~/.claude/sessions/<pid>.json`，状态一变就重写。本机实测的字段：`cwd, entrypoint, kind, messagingSocketPath, name, nameSince, nameSource, peerFeatures, peerProtocol, pid, pidDomain, procStart, sessionId, startedAt, status, statusUpdatedAt, updatedAt, version`。
- `status` 取值 `busy` / `shell` / `idle` / `waiting`；`waiting` 时有 `waitingFor`：`permission prompt`、`input needed`、`sandbox request` 等。
- 官方文档：`claude agents --json` 是从外部读会话状态的受支持方式（<https://code.claude.com/docs/en/agent-view>）。直接读文件不在稳定接口里。用户选了直接读文件（监听目录，几乎不花 CPU），没选每 2 秒调 CLI（单次 0.4s，CPU 验收过不了）。
- 拒绝权限后：不带反馈的拒绝会接一条 `[Request interrupted by user for tool use]`；带反馈的会继续跑。

**用户要的三个事件**：工作中、已停止、需要你介入（问问题 / 等批准）。都要有声音提示（具体见下）。

**开工前要核实、并交用户定的**：
1. 映射：`busy` / `shell` → 工作中；`idle` → 已停止；`waiting` → 需要你介入。出错、被打断要不要还从 JSONL 区分？用户只说要三个事件，倾向全部归到「已停止」，造型里的出错 / 被打断是否保留要问。
2. 「等你回答」和「等你批准」在界面上是两个造型，在事件上是同一个「需要你介入」。要不要用 `waitingFor` 区分这两个造型，要问。
3. 只取 `pid`、`sessionId`、`status`、`waitingFor`、`statusUpdatedAt`、`cwd`（项目名只取最后一段）、`kind`、`procStart`。**不取 `name`**：它可能是从对话推出来的，算对话内容。
4. `kind` 有哪些取值？`claude -p`、SDK 进程会不会也写文件？要不要只看 `interactive`？要实测。
5. 子 agent 会不会单独写 sessions 文件（推断不会，因为它在同一进程里跑），要实测。CLAUDE.md 的硬规则已改成「将由第 3 步新建的 AgentCore 负责」（用户 10-29 已确认），实测后把过滤规则写进新的 `docs/agent-integration.md`。
6. 进程被杀时文件可能还在：用 `kill(pid, 0)` 加 `procStart` 防 pid 复用；判不出来就算 unknown，不算已停止。
7. **不写降级路径**（用户 10-29：「选 A 不降级，我自己用，有变化我随时改」）：不退回 JSONL，不做多版本兼容，不为格式变化预留兜底。解析不了的文件按 CLAUDE.md 准则 5 计数、跳过、不崩，就到此为止。
8. ~~现有 AgentCore（读 JSONL）要不要删~~ → 已删（用户 10-29）。丢掉的行为：JSONL 尾部判定（end_turn / stop_sequence / max_tokens / refusal、限流和 API 出错分类、中断）、子 agent 五个信号的过滤、64KB→1MB 尾读。要找回看 git 历史 `d8a28dd`。

**声音**（agent 提议，待用户确认）：
- 已停止、需要你介入两个事件响声音；工作中不响，因为是用户自己开的头。
- 用系统音效（`NSSound(named:)`），不用别家的音效。用哪两个、设置里能不能关，问用户。
- 已有的规则：violated 响 Basso；防火墙守住时不响。

## 面板布局问题（用户 10-29 截图，开发计划第 4 步改）

用户原话：「展开的时候，我们的盾盾需要缓动到正确位置；现在这个布局两侧都没对齐。」代码在 `Sources/Notchkeeper/Notch.swift` 的 `NotchDashboard`、`SessionRow`、`StatePill`、`NotchGearButton`。原因：

- **左侧没对齐**：
  - 盾盾的图层画布是 80 × 68pt，包含右上装饰区。身体圆只占其中一块，左缘离画布左边 16pt，而 HStack 按画布排。
  - 标题文字的起点是画布宽 80 + 间距 10，会话行的文字起点是图标 22 + 间距 10，两列文字不在一条线上。
  - 会话图标 22pt，盾盾身体 40pt，左缘和中心都对不上。
  - 盾盾的 ▲ 装饰顶到面板上沿，和刘海挤在一起。
- **右侧没对齐**：
  - 齿轮按钮单独放在右上角，右缘和「进程 claude 0」、会话行时间列的右缘不在一条线上。
  - 时间列只有 `minWidth: 58`，「23分47秒前」比它宽，会把状态胶囊往左推，胶囊列就不齐。
- **时间文案**：运行中显示「13秒」，空闲显示「3分48秒前」，一个是时长、一个是距今，格式混用。

**建议的改法**（agent 提议，先给用户看草稿）：
- 定一套网格：左侧用一条共同的前导线，盾盾按**身体圆**对齐（装饰允许溢出到右上，不参与对齐），会话图标和盾盾身体的中心对齐；标题和会话名用同一条文字起点。
- 右侧一条共同的尾随线：齿轮、进程数、时间列都对齐它；时间列固定宽度（按最长格式「59分59秒前」算），胶囊列固定在它左边。
- 「进程 claude 0」按删除优先问一句还要不要。
- 照 ui-ux-pro-max 出一版，附暗色截图。

**展开时盾盾缓动**：收起态左耳的 20pt 盾盾和面板里的 40pt 盾盾，要表现成同一个角色，从左耳的位置和大小用弹簧移动、放大到面板里的位置；收起时反向，退场稍快。实现可以考虑把盾盾提到 NotchRoot 这一层，作为唯一一只，按展开进度插值位置和缩放；或者用 SwiftUI 的 `matchedGeometryEffect`。注意它是 CA 图层视图，补间时不要重建图层（重建会重播进场、断掉循环相位）。右耳图标照旧淡出，不飞。

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
- `research`：sessions 文件的 `kind` 取值、子 agent 行为。
- `domain-modeling`：新领域词进词表。
- `run`：启动 App、截图。
- `diagnosing-bugs`：CPU 不达标时用。
- `writing-for-agents`：第 1 步改 CLAUDE.md（亮色、多语言、截图规则）。
- `prototype`：第 0 步把 `prototype/dundun-3d` 提交到单独分支的规矩。
- `handoff`：换会话时更新本文件（本仓的交接文档就是 `HANDOFF.md`，不另写 `handoff.md`；macOS 不分大小写，会覆盖它）。

## 待办与已知问题

- **亮色模式（先做文档）**：
  - 用 `writing-for-agents` 改 CLAUDE.md：「只做暗色」改成亮暗都支持；界面准则里「截图：附暗色截图」改成亮、暗各一张。
  - 范围要和用户确认。agent 的建议：贴着刘海的部分（收起的耳朵、展开面板、完成卡、红卡）在亮色模式下**仍是纯黑**。刘海是硬件，灵动岛在亮色模式下也是黑的（推断，写文档前查 Apple HIG 的 Live Activities / Dynamic Island 一节）。亮色模式只作用于设置窗口这类不贴刘海的界面。
  - 盾盾的配色和装饰色是按黑底设计的，例如睡着的 Z 是 `#B9C3F0`。放在亮底的设置页预览里，要逐个检查对比度，必要时给装饰加亮色模式下的变体。
  - 菜单栏本身随壁纸变亮变暗，但刘海区域永远是黑的，耳朵不受影响。
- **配置文件解不开的横幅没实机截图**：P0 修复让设置页在 `config.json` 解不开时顶部显示横幅、禁用改配置的控件。实机验证要临时改坏真实的 `config.json`（先备份）；用户 10-29 定：先不做，第 4 步重写设置页时一起看。另外 reviewer 提过横幅的黄色和琥珀（egressMismatch）容易混，到时一起定。
- **盾盾实机检查**：2b 做完后补 16 个造型的暗色截图（刘海机型一张；有外接屏时补无刘海的）。
- **2a 审查留下的（第 2 步一起改）**：
  - 换造型时 `stopLoops()` 直接撤循环：晕的摆锤、工作的浮动会一下子跳回 0。原型的做法同样会跳，写实现时用补间收尾。
  - 0.09s 内连续换两次造型时，「保持旧眼形」保持的是模型值，不是屏幕上的那个。改成眼形补间后，从呈现层取起点即可。
  - 看不见时 A→B→A 回到原造型，也会重播进场。
  - `DundunDirector` 的时钟决策（醒来时刻、恢复、推迟小动作）还没抽成值类型测试。
- **设置页预览可能不跟鼠标**（推断）：Notchkeeper 在前台时，全局鼠标监听收不到本 App 窗口里的事件。第 4 步 处理。
- **MIT 声明**：`DundunDirector.swift`、`EarView.swift` 里从旧 `DundunView.swift` 搬来的代码保留了 Coucou 的 MIT 声明，第 4 步 重写时一起删掉。
- **IPv6**：守卫只查 IPv4，IPv6 直连泄漏看不见（推断，待实测 `route -n get -inet6`）。第 5 步 一起处理。
- **utun 判定过宽**：任何 utun 都算「在隧道上」，开着别的 VPN 时可能看漏（推断）。
- **出口探测频率**：每 5 秒请求 3 个回显服务，可能被限流（推断）。
- **旧注释**：指向已删文档的已改完；剩下「Emily 规格」「Emily 2026-10-28」几处出处说法（`Notch.swift`），第 4 步 重写时确认后改成 docs 出处。
- **审查发现、留给重写的**（10-29 两个只读审查 agent，删除之外的部分）：
  - 第 2 步：`DundunState` / `Look` / `DundunTestState` 三套枚举描述同一件事，只留 `Look`；`DundunConst` + `CGColor.hex`（Generic RGB）和 `RGB.cg`（sRGB）同一个 hex 两种色彩空间；`Choreography.Property` 的 rawValue 是 CA 键路径、`Look` 的参数叫 `guardUnknown`，核心知道了外层的名字；`DundunDirector` 犯困 / 回正 / 推迟小动作的时钟决策抽成纯值；`Dundun` / `Mascot` 两套前缀统一成 `Dundun`（审查建议，待用户定）。
  - 第 2 步待用户定：`DundunView.interactive` 全仓没人传 `true`，`docs/mascot.md` 写的「点一下晕」永远不触发——接上还是连 `dizzy` 一起删。
  - 第 4 步：`NotchController` 里的卡片队列、悬停状态机、布局几何、`GuardPresentation` 的判定进 `NotchCore`；红卡「关掉的是哪一次」现在分在 `AppState.dismissedViolationSince` 和 `NotchController.pendingAlert/violationAlerted` 两处，合成一个 owner；`Notch.swift:366` 用 `asyncAfter(0.5)` 等收起动画；`Common.swift` 的 `enum Motion` 和领域词 motion 撞名；`NKConfig` 去前缀；`ConfigStore` 每秒轮询、`AppState` 每 4 秒扫会话，看不见时也在跑；`Sessions.swift` 还扫 Codex 会话、用 `JSONSerialization` 整行解码（读进了正文）。
  - **删 `--selftest` 丢掉的覆盖，第 4 步在 `NotchCore` 里用 swift test 补回**（reviewer 10-29；原文 `git show d8a28dd:Sources/Notchkeeper/AgentEvents.swift`，约 50 条）：违规 → unknown → healthy 撤红卡；关掉的同一次违规不再弹、新的一次照弹；stale / clockSkew 且 lastVerdict 是 violated 时保留红卡、不响 Basso；非常驻红卡到时不重弹；恢复卡只在弹过红卡后出现；`GuardPresentation` 各状态的颜色和文案。
  - `config.json` 里的 `launchAtLogin`、`suppressWhenHostFrontmost`、`agents` 三个键下次存盘时会被去掉（没有消费者）。以后要做「按 agent 开关」从默认值重来。
- **审查**：2a 之前第 2 轮 reviewer 查出的两条必须修已经改好，但没有再审一轮。
- **Grok Bot**：只能识别「有新回复 / 等你回复」，做不做还没定。
