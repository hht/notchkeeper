# HANDOFF

最后更新：2026-10-29（阶段 2a 提交后）。换会话或开工前先读本文，再读 `CLAUDE.md`。

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
| 10-29 | 盾盾动画不设帧率上限，越高越好：不给 `preferredFrameRateRange`。取舍：Apple 建议能低就低以省电，120Hz 下常驻循环的合成功耗记在 WindowServer 上，`top -pid` 量不到；用户选画面优先 |
| 10-29 | 跟随鼠标做成设置开关：设置页「盾盾」→「跟随鼠标」，`config.json` 的 `dundunFollowsMouse`，默认开 |
| 10-29 | 盾盾改为「二维图形模拟三维」：身体是球，眼睛贴在球面上，所有动作（包括跟随鼠标）都用头的朝向（左右 yaw、上下 pitch、侧歪 roll）表达；要有左右 360° 转圈和上下 360° 翻圈；动作再多一些。数字由 agent 定（见「阶段 2b 接手要点」）。放在下一个切片做 |

## 阶段与进度

| 阶段 | 内容 | 状态 |
|---|---|---|
| 0 | 文档重置：CLAUDE.md、README、本文件、`docs/dundun.md`、`docs/firewall.md`；删除旧文档和 `prototype/` | 已完成 |
| 1 | 后端：删除没人用的拦截接缝（`onVerdictChange`、`Verdict.intercepts`）；guardd 读上一份状态时不再用 `try?` 吞错误 | 已完成 |
| 2a | 盾盾改用 Core Animation：DundunCore 重写成纯值（造型、形状、编排、空闲调度、注视），App 侧图层树、全 App 唯一时钟、右耳；删掉旧的逐帧画法、帧预算、跑分、演示、自检；跟随鼠标开关 | 已完成；完整 App 的 CPU 验收还没过，原因是旧会话扫描，阶段 3 删掉后重测（见下方实测表） |
| 2b | 盾盾伪 3D：球面模型 + 朝向，转圈、翻圈，更多动作（见下方「接手要点」） | 下一步 |
| 3 | App 外壳重写：<br>• 新增 `NotchCore`：GuardPresentation、CardQueue、HoverMachine、MascotResolver、配置解码（同时修 P0）<br>• 刘海视图只订阅 `presentation`，不订阅含 `checkedAt` 的 `display`：Watcher 每轮都发是为了设置页的「上次检查」，不是 bug，但不该让整棵视图每 5 秒重算<br>• 接上 AgentWatch 的完成卡<br>• 精简设置页<br>• 删除 `AgentEvents.swift`、`Sessions.swift`、SelfTest<br>• `demo.sh` 的通知只在 DEBUG 构建里监听 | 待做 |
| 4 | 防火墙：资料已查（`docs/firewall.md` 第 6 节）。顺序：root 实测 → 恢复脚本并实测 → 试运行和自动回滚 → 规则、LaunchDaemon、安装脚本、App 开关 | 待做 |

## 阶段 2b 接手要点：盾盾伪 3D

**用户的要求（10-29）**：用二维图形模拟三维模型。2a 的动画是平面的：眼睛直接平移、「歪头」只是整张脸平面旋转，看着别扭。所有动作都要按三维来算。

**模型**：
- 身体是一个球，屏幕上是它的正投影，圆的轮廓永远不变。光从上方来，所以渐变不跟着转。
- 眼睛贴在球面上，各有固定经纬度：左右眼各偏离正中约 20°，即画布里 ±3.5 单位 / 半径 10。
- 状态就是头的朝向（yaw、pitch、roll）。眼睛按朝向投影：
  - 位置沿球面滑动；
  - 沿径向压缩到 cos(偏离角)；
  - 转到背面就看不见。
- 右上装饰不上球，留在角落。
- 跳、压扁、呼吸仍然作用在整个身体上。

**数字（agent 定）**：
- 跟随鼠标：头最多转 yaw ±25°、pitch ±20°，弹簧沿用 response 0.3、damping 0.85。
- 左右转圈、上下翻圈：各 0.9s，正弦缓动。
- 完成时空中转一圈改成 yaw 360°。

**动作改写和新增**：
- 东张西望：左右转头。
- 点头：pitch。
- 歪头：roll。
- 新增：左右 360° 转圈、上下 360° 翻圈。
- 再加几个：抬头看天、低头看脚、摇头、侧身转 90° 再转回来。

最终清单写进 `docs/dundun.md` §5。

**顺序**：
1. 先做用完即删的原型（`prototype` skill），只放一只盾盾和几个按钮，给用户看手感。
2. 用户认可后，先改 `docs/dundun.md` §5：以朝向为核心，写明球面模型和角度。经用户确认。
3. TDD 改 `Choreography`、`Gaze` 和图层。

**实现要先实测二选一**：
- (a) Core Animation 3D 变换：用 `CATransformLayer` 搭层级，眼睛图层放在球的切面上（`anchorPointZ` = −半径），`isDoubleSided = false` 让转到背面的眼睛消失。插值在渲染服务里做，弹簧可以直接作用在 `transform.rotation.y` 上。
- (b) DundunCore 的纯函数把「朝向 → 每只眼的二维位置、压缩、可见性」算好，采样成关键帧交给 CA。

两种都要在实机上比顺滑度和 CPU。无论选哪种，投影公式都写成 DundunCore 的纯函数并单测，例如转 90° 时眼睛在边缘、宽度约 0，转 180° 时不可见。

**多宠物**：用户问过架构能否「只换图形」接入别的宠物，还没定做不做（答复见本次会话汇报）。2b 设计骨架时把「每个宠物的美术数据」收在一个值里，不把盾盾的名字写进骨架。

**2a 的实现取舍**（文档没写死、我定的）：
- 看不见时撤掉全部动画（静止值在模型层上），回来时按共同起点 `DundunDirector.epoch` 重新挂循环，不用 `layer.speed = 0`：这样左耳和面板的相位保持一致。
- 出错的「一缩」保持在姿态里，不回弹。
- 只有睁着眼的造型看鼠标。
- 注视取整的格子 0.25 单位、0.5°：鼠标每换一次目标就是一次事务提交。

**2a 实测**（本机 Mac17,9，内建 120Hz 屏，release，`top -l 70 -s 1`）：

| 场景 | 旧版 `7374a88` | 2a 完整 App | 2a 关掉旧会话扫描 |
|---|---|---|---|
| 收起空闲 60s | 1.23% | 0.77% | 0.385%（无人操作的 33s 约 0.03%） |
| 鼠标持续移动 60s | 3.67% | 约 3.4% | 2.34%（跟随鼠标关掉时 1.99%） |

完整 App 没达标，原因是旧的会话扫描 `SessionScanner`（`AppState.swift:36` 每 4s 一次）。它每次读会话文件尾部再逐行 split，会话文件越大越慢，开销随时间上涨，所以每轮读数都会漂。阶段 3 删掉它之后应该重测。

## 建议用的 skill

- `tdd`：DundunCore 的每个纯值类型都先写测试。接口用语见 `codebase-design`。
- `ui-ux-pro-max`：调动效节奏、做实机评审。
- `research`：查 Core Animation 的帧率 API、Core Animation 在 macOS 上的行为。
- `run`：启动 App、截图。
- `diagnosing-bugs`：CPU 不达标时用。

## 待办与已知问题

- **盾盾实机检查**：12 个造型和各个动作还没逐个截图，用户说自己看。2b 做完后一起补暗色截图。
- **2a 审查留下的（2b 一起改）**：
  - 换造型时 `stopLoops()` 直接撤循环：晕的摆锤、工作的浮动会一下子跳回 0。
  - 0.09s 内连续换两次造型时，「保持旧眼形」保持的是模型值，不是屏幕上的那个。
  - 看不见时 A→B→A 回到原造型，也会重播进场。
  - `DundunDirector` 的时钟决策（醒来时刻、恢复、推迟小动作）还没抽成值类型测试。
  - 新领域词（Track、Cue、Pose、Part、Gaze、EarIndicator）还没进 `docs/ubiquitous-language.md`。
- **设置页预览可能不跟鼠标**（推断）：Notchkeeper 在前台时，全局鼠标监听收不到本 App 窗口里的事件。阶段 3 处理。
- **MIT 声明**：`DundunDirector.swift`、`EarView.swift` 里从旧 `DundunView.swift` 搬来的代码保留了 Coucou 的 MIT 声明，阶段 3 重写时一起删掉。
- **P0**：`config.json` 有语法错误时，启动会用默认值覆盖整份文件，允许列表被清空（`Sources/Notchkeeper/Config.swift:67-77`）。阶段 3 修。
- **IPv6**：守卫只查 IPv4，IPv6 直连泄漏看不见（推断，待实测 `route -n get -inet6`）。防火墙会同时封 IPv6，阶段 4 一起处理。
- **完成判定**：AgentCore 只靠 `stop_reason` 判断回合结束，真实会话里可能永远判不出完成（推断）。阶段 3 接线前用 `NOTCHKEEPER_LIVE_AGENTS=1` 实测。
- **utun 判定过宽**：任何 utun 都算「在隧道上」，开着别的 VPN 时可能看漏（推断）。
- **出口探测频率**：每 5 秒请求 3 个回显服务，可能被限流（推断）。
- **旧注释**：后端和 DundunCore 的已改完。App target 里（`Mascot.swift`、`DundunTypes.swift`、`Notch.swift`、`Settings.swift` 等）还有指向 `AGENTS.md`、`prototype/`、已删文档的注释，阶段 3 重写时一起去掉。
- **审查**：第 2 轮 reviewer 查出的两条必须修（防火墙状态摘要的新鲜度和存放位置；guardd 里过时的拦截注释）已经改好，但没有再审一轮。
- **Grok Bot**：只能识别「有新回复 / 等你回复」，做不做还没定。
