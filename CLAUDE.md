# CLAUDE.md — Notchkeeper（刘海出口守卫 + 防火墙 + 任务完成卡片）

> 本轮用户输入优先于任何文档。通用 MUST NOT 与收工分档见全局 Contract（`~/.agents/AGENTS.md`）。

## 这是什么

Haitao 本机自用的 macOS 刘海应用。SwiftPM 构建，SwiftUI + AppKit，macOS 14+，简体中文和 English，没有菜单栏图标。它做四件事：

1. **出口守卫（只监测）**：用户级 LaunchAgent `guardd` 检查 Clash、utun 路由和出口 IPv4，写进 `guard-state.json`；App 监听这个文件，在刘海上显示。
2. **防火墙（一键开关）**：开启后，除局域网外不走 Clash 隧道的出站流量一律丢弃；关闭后完全不拦。
3. **任务完成卡片**：Claude Code 的顶层回合结束或需要你介入时，在刘海弹卡。
4. **Pip**：原创吉祥物，在左耳、面板和卡片里用表情说现在是什么状态。

现状与待办见 `HANDOFF.md`，运行与安装见 `README.md`，每个 target 的职责见 `Package.swift` 的注释。

## 最高准则

1. **删除优先。** 每行代码都要答得出「删掉会坏什么」，答不出就删（可读性不降的前提下）。只转发、只换名字、只有一个调用方的函数和类型一律内联。不为没出现的需求写代码。同样的行为，代码越少越好。
2. **一个模块一个问题。** target 和文件按会独立变化的设计决定划分（「出口健不健康」「回合结束了没有」「卡片怎么排队」），不按 View / Model / Manager 切。
   - 类型注释第一句写它回答哪个问题、不该知道什么。
   - 依赖单向无环。核心 target（`GuardCore`、`AgentCore`、`MascotCore`、`NotchCore`）是纯值类型，不 import SwiftUI / AppKit；文件监听、探针、pf、画界面放外层。
3. **本质对、分支少。** 先定数据结构、状态机与不变量，再写分支。同一件事只有一个 owner。规模小，就用最直接的算法；要调速先测量。
4. **测试先行（TDD）。** 新行为、新规则、修 bug，先写一个会失败的测试，亲眼看它红，再改到绿。时间、随机数、文件系统、探针、进程表都从参数注入。测不了的部分（窗口、动效、权限弹窗、pf）在提交说明里写实机步骤和结果。
5. **信任边界。** 外部数据（sessions 文件、`config.json`、`guard-state.json`、防火墙状态、探针响应、`proc_pidpath`）在边界解析成精确类型。
   - **「未知」是一个值**：断网、探针超时、状态文件过期都是 unknown，不是 healthy 也不是 violated。
   - 解析不了的外部数据计数并降级，不崩溃，不覆盖原文件；内部不变量坏了就 `preconditionFailure`。
6. **从根源解决。** 先复现，拿出根因证据，再改在产生问题的地方。特例 if、`asyncAfter` 延时、`try?` 吞错误、改文案都是症状补丁。找不到根因就停下报告。
7. **先查一手资料和成熟实现。** Apple 文档、WWDC、agent 的会话格式、开源同类产品是起点；界面效果凭感觉调参之前先看别人怎么做（流星改了八九版才过的教训）。在此之上可以自己设计。依赖外部行为的代码，按实际版本读文档或实测，用 `// @see` 指向出处。
8. **照 Swift 与 Apple 平台的社区惯例**（见「风格与命名」）。

**决策序：** 正确性 > 可验证性 > 极简 > 性能 > 复用 > 速度。

## 本仓硬规则

- **守卫只监测，判定止于 GuardCore。** verdict 有四种：`violated`（去公网的路由不走 utun；只有一轮完整的 healthy 才能解除）、`egressMismatch`（出口 IP 不在允许列表，琥珀）、`unknown`（不弹卡）、`healthy`。红卡挂不挂由 `NotchCore` 的 `ViolationAlert` 定；从任何路径进入 healthy 都撤红卡。规则见 `docs/egress-guard.md`。
- **防火墙安全第一**，细节见 `docs/firewall.md`：
  - **先能恢复，再谈拦截。** 恢复脚本 `scripts/firewall-rescue.sh` 先写好并在本机实测，才能写任何 block 规则；它不依赖网络、App 和已安装的防火墙脚本。每次开启先试运行，2 分钟内没确认就自动回滚。
  - 只用自己的 pf anchor。不改 `/etc/pf.conf`，不读写 Clash 配置，不用 Network Extension，不碰 sudoers。
  - 开、关都要管理员密码。App 不常驻特权代码；安装和规则改动先给用户看 diff 并备份，由用户自己执行。
  - 不杀进程，不针对任何 App。
- **agent 只提醒顶层回合的结束（做完、出错）和需要你介入。** 状态只由 `AgentCore` 判定，来源是 `~/.claude/sessions/<pid>.json` 和自带 Claude Code mod 写的回合文件（`docs/agent-integration.md`）。不用 settings.json 的 hooks；改 Claude Code 配置只有一处：设置页「安装 / 卸载」调 `claude plugin`。
- **sessions 文件和 mod API 不做兼容**：格式变了直接改代码，不退回读会话 JSONL（里面是完整对话），不做多版本兼容；解析不了的计数、跳过。
- **只读元数据，不读对话内容。** 会话文件只取判定需要的字段；日志和界面不出现消息正文、工具参数和输出；mod 只写出元数据。唯一例外：跳转 Ghostty 时读到的终端标题只在内存里找标记、原样写回，不显示、不进日志。
- **除防火墙外不碰网络与 shell 环境。** 不改 `~/.zshrc` 和系统网络设置；出口探测只请求第三方服务，不碰 Claude / Anthropic 的域名；guardd 不要 sudo。
- **密钥不打印，日志不记 IP**（界面上完整显示出口 IP）。测试与文档里的 IP 用 `198.51.100.x`。
- **品牌**：Pip 是原创角色，不用 Grok、Codex、Coucou、Mochi 等别家的名字、形象和音效；会话行可以用 agent 厂商的标志。从 Coucou（MIT）移植的代码在第 4 步重写删掉之前，保留 MIT 声明和设置页致谢。
- **看不见就不调度。** 收起、被遮挡、熄屏、锁屏时停掉动画和计时器。性能验收数字见 `docs/mascot.md`。

## 界面

- **动效**克制、节奏活泼：弹簧和正弦缓动，进场稍慢、退场稍快；「减弱动态效果」只淡入淡出；常驻动画交给 Core Animation。
- **默认不打扰**：空闲收进刘海，悬停或点击展开；红卡挂到恢复，临时卡放完回到它。
- **状态 = 颜色 + 图标 + 文案**：绿 healthy、琥珀 egressMismatch、灰 unknown、红 violated。
- 贴刘海的部分永远黑底白字，只有设置窗口跟随亮暗；只有看得见的形状接收点击。
- 文案源语言是简体中文、一句话说清，按钮写动作本身；走 String Catalog，同时给 English。
- 改了 UI 附截图。细节见 `docs/ui.md`。

## 文档

**代码和测试说了算。** 文档只记用户拍板的决定和看代码看不出的原因；不记数字、实现细节和试错历史（历史看 `git log`）。小的设计取舍直接写代码，依据放注释。改用户定过的决定，先问用户。

| 什么时候 | 读哪份 |
|---|---|
| 开工前、换会话 | `HANDOFF.md`、`README.md` |
| 守卫判定、`guard-state.json`、怎么画 | `docs/egress-guard.md` |
| 会话怎么读、回合结束、声音 | `docs/agent-integration.md` |
| 防火墙 | `docs/firewall.md` |
| Pip 造型、动效、性能验收 | `docs/mascot.md` |
| 卡片、面板、亮暗、多语言 | `docs/ui.md` |
| 起名字 | `docs/ubiquitous-language.md` |

## 命令

- **验收**：`swift build` 零警告，并且 `swift test` 全绿。
- `./scripts/run.sh`：release 编译、打包 `build/Notchkeeper.app`、签名并启动（先结束旧实例）。
- `./scripts/demo.sh done|failed|question|approval|alert`：在实机上弹卡验 UI。靠分布式通知，本机任何进程都能发，第 4 步起只在 DEBUG 构建里监听。
- guardd 调试、安装和卸载见 `README.md`。新增 lint / format 工具或依赖要用户明示同意。

## 风格与命名

- 照 [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/)：缩写大小写一致（`IP`、`URL`、`ID`）；优先值类型和 `enum` 状态机；错误用 `throws`；UI 状态只在 `@MainActor` 上改；外部数据不强制解包。
- 同一概念只有一个名字（`docs/ubiquitous-language.md`）；Pip 在代码里用 `Mascot` 前缀。
- 配置与状态文件：JSON 字段 lowerCamelCase，缺失字段用默认值，未知字段忽略，时间用 ISO 8601。
- 注释写为什么，不写做了什么；依赖外部行为的地方标 `@see`。
- 每个 target 的职责写在 `Package.swift` 的注释和类型注释里，不写包 README。

## 提交

- commit / push 要用户本轮明示。amend、force-push、改 git 配置都不做。只暂存本次改动涉及的文件。
- 提交前对 diff 逐行问「删掉会坏什么」；更新 `HANDOFF.md`（做完的删掉，只留接下来要做的），随同一提交。
- **独立审查**：派一个新的 [`reviewer`](.claude/agents/reviewer.md) 子 agent 审 diff。必须修的：结论错、丢数据、永远卡住、安全问题、违反硬规则、可能断网。修完再审，至多两轮；仍有问题交用户定。
- 一个提交只做一件事，测试放同一个提交；重构与功能、修复分开。
- 格式（Conventional Commits，正文用中文列表）：`<type>: <一句话>`，type 用 `feat` `fix` `refactor` `test` `docs` `build` `chore`。

## 汇报

- 一律中文（代码标识符和引用原文除外）。先说结论，用白话；再给建议的下一步。
- 结论带依据（`文件:行`、官方链接或实测）；推断标「推断 / 未证实」。前提错了直接指出。
- 动到防火墙、LaunchDaemon / LaunchAgent 的改动按全局 Contract「高影响」档收工。

## Agent skills

| 意图 | skill |
|---|---|
| 磨方案 | `grilling` |
| 查 API / pf / agent 格式 | `research` |
| 验证状态模型或界面草稿（用完即删） | `prototype` |
| 按切片实现 | `tdd`（接口用语见 `codebase-design`） |
| 界面布局、动效 | `ui-ux-pro-max` |
| 难 bug、性能回退 | `diagnosing-bugs` |
| 起名字 | `domain-modeling` |
| 改本文件 / skill | `writing-for-agents` |
| 换会话 | `handoff`（写进 `HANDOFF.md`） |
