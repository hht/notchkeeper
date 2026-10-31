# CLAUDE.md — Notchkeeper（刘海出口守卫 + 防火墙 + 任务完成卡片）

> 本轮用户输入优先于任何文档。通用 MUST NOT 与收工分档见全局 Contract（`~/.agents/AGENTS.md`）；本文件管本仓的准则、SSOT 与流程。

## 这是什么

Haitao 本机自用的 macOS 刘海应用。SwiftPM 构建，SwiftUI + AppKit，macOS 14+，简体中文和 English，没有菜单栏图标。它做四件事：

1. **出口守卫（只监测）**：后台的用户级 LaunchAgent `guardd` 检查 Clash、utun 路由和出口 IPv4，结果写进 `guard-state.json`。App 监听这个文件，在刘海上显示状态。
2. **防火墙（一键开关）**：开启后，除局域网外凡是不走 Clash 隧道的出站流量一律丢弃；关闭后完全不拦。
3. **任务完成卡片**：Claude Code 的顶层回合结束时，在刘海弹卡。
4. **盾盾**：原创吉祥物，放在刘海左耳、面板和卡片里，用表情告诉你现在是什么状态。

现状与待办见 `HANDOFF.md`，运行与安装见 `README.md`。

## 最高准则

1. **删除优先。** 每行代码都要答得出「删掉会坏什么」。答不出，先查来历；查清了仍答不出，就删，前提是可读性不降。只转发、只换名字、只有一个调用方的函数、类型、文件，一律内联。不为没出现的需求写代码（测试、重构不算）。同样的行为，代码越少越好；200 行能写成 50 行就重写。
2. **一个模块一个问题。** target 和文件按问题划分：一个问题就是一个会独立变化的设计决定，例如「出口健不健康」「回合结束了没有」「盾盾此刻做什么动作」「卡片怎么排队」。不按 View / Model / Manager 切。
   - 接口比实现小得多。类型注释第一句写它回答哪个问题、不该知道什么。
   - 宁深勿碎，依赖单向无环。核心 target（`GuardCore`、`AgentCore`、`MascotCore`、`NotchCore`）不 import SwiftUI / AppKit，也不提外围的名字。
   - 计算与副作用分开：核心是输入数据、输出数据的纯值类型；文件监听、探针、pf、画界面放在外层。
3. **算法精妙。** 先想清本质，先定数据结构、状态机与不变量，再写分支。同一件事只有一个 owner，禁止特例瀑布。规模小（几个进程、几十个会话、一只吉祥物），就用最直接的算法；要调速，先测量。精妙指本质对、分支少，不是炫技。
4. **逻辑清晰可测试，测试先行（TDD）。** 新行为、新规则、修 bug，都先写一个会失败的测试，亲眼看它失败，再改到绿。时间、随机数、文件系统、网络探针、进程表都从参数注入，测试可以快进时间、重放事件序列。纯逻辑测不了的部分（窗口、动效、权限弹窗、pf），在提交说明里写实机步骤和结果。
5. **信任边界。** 外部数据在边界解析成精确类型，之后内部直接用。外部数据包括：sessions 文件、`config.json`、`guard-state.json`、防火墙状态文件、探针响应、`proc_pidpath` 结果。
   - 非法状态尽量用类型排除。
   - **「未知」是一个值**，既不是 healthy 也不是 violated：断网、探针超时、状态文件过期都是 unknown。
   - 兜底与默认值只给真会发生的情况；内部不变量坏了就 `preconditionFailure`。
   - 解析不了的外部数据，计数并降级，不崩溃，也不覆盖原文件。
6. **从根源解决。** 改在产生问题的地方：先复现，再拿出根因证据，再改。禁止症状补丁，包括特例 if、`asyncAfter` 延时掩盖、`try?` 吞错误、改文案遮问题。根因在设计文档里，就同步改文档。找不到根因就停下报告。
7. **照一手资料。** 本文件与 `docs/` 没定的，先查成熟实现与原始出处：Apple 官方文档、WWDC、各 agent 的会话格式、开源同类产品的源码。共识照做；有争议的，列出各方交用户定，定了写进 `HANDOFF.md`。
   - 设计类改动整套照搬一个成熟实现的完整做法，只写平台逼出来的偏差；说不出照的是谁，就停下报告。
   - 依赖外部行为的代码，先按实际用的版本读文档或实测，代码里用 `// @see` 指向出处，实测经过写进提交说明。
8. **照社区惯例。** 风格、命名、目录、错误处理照 Swift 与 Apple 平台的通行做法（见「风格与命名」），禁止自创平行惯例；与本仓 SSOT 冲突时先指出，由用户定。

**决策序：** 正确性 > 可验证性 > 极简 > 性能 > 复用 > 速度。

## 本仓硬规则

- **守卫只监测，判定止于 GuardCore。** 四种 verdict：
  - `violated`：去往公网（局域网以外）的路由不走 utun（Haitao 2026-10-28：除局域网外全部流量必须走代理）。只有一轮完整的 healthy 才能解除；断网、探针超时、守卫停了，都不会把它降级。
  - `egressMismatch`：出口 IP 不在允许列表，只显示琥珀色。
  - `unknown`：不弹卡；状态点是灰色空心环，收起时右耳照盾盾造型显示（`docs/mascot.md` §2）。
  - `healthy`。

  红卡该不该挂着，只看当前状态和 `dismissedViolationSince`；挂着时，临时卡（完成、介入、恢复）可以暂时盖在上面，放完回到红卡（Haitao 2026-10-29，`docs/ui.md`「卡片」）。从任何路径进入 healthy 都要撤掉红卡。完整规则见 `docs/egress-guard.md`。
- **防火墙一键开关，安全第一**（Haitao 2026-10-29）：
  - **先能恢复，再谈拦截。** 恢复脚本 `scripts/firewall-rescue.sh` 要先写好，并在本机实测过，然后才能写任何 block 规则。恢复脚本不依赖网络、App 和已安装的防火墙脚本。每次开启防火墙都先试运行，2 分钟内没确认就自动回滚。
  - **范围**：只用自己的 pf anchor。不改 `/etc/pf.conf`，不读写 Clash 配置，不用 Network Extension，不碰 sudoers。
  - **开、关都要管理员密码。** App 不常驻特权代码；特权部分只有安装好的脚本和 LaunchDaemon。安装和任何规则改动，都先给用户看 diff 并备份，由用户自己执行。
  - **不杀进程**，不针对任何 App。
  - 细节见 `docs/firewall.md`。
- **只提醒顶层回合的结束（做完、出错）和需要你介入。** agent 状态只由 `AgentCore` 判定，配固定测试；来源是 `~/.claude/sessions/<pid>.json` 和 Notchkeeper 自带的 Claude Code mod 写的回合文件，规则见 `docs/agent-integration.md`。不用 settings.json 的 hooks。改 Claude Code 的配置只有一处：用户在设置页点「安装」时，由 `claude plugin` 命令写 `enabledPlugins` / `extraKnownMarketplaces`；卸载同理（Haitao 2026-10-30）。
- **sessions 文件、mod 的 API 不做兼容**（Haitao 2026-10-29、10-30）：格式变了就直接改代码，不退回会话 JSONL，不做多版本兼容。解析不了的照准则 5 计数、跳过。
- **只读元数据，不读对话内容。** 会话文件只取判定需要的字段；日志和界面不出现消息正文、工具参数和输出。mod 看得到正文，只写出元数据。唯一的例外：跳转 Ghostty 时读到的终端标题（Claude Code 起的会话标题）只在内存里找标记、原样写回，不显示、不进日志（Haitao 2026-10-30）。
- **除防火墙外不碰网络与 shell 环境。** 不改 `~/.zshrc`，不改系统网络设置。「打开 Clash」只是打开 App。出口探测只请求第三方服务（如 ipinfo.io），不碰 Claude / Anthropic 的域名。guardd 是用户级 LaunchAgent，不要 sudo。
- **密钥不打印，日志不记 IP。** 界面上完整显示出口 IP（Haitao 2026-10-28）。测试与文档里的 IP 用 `198.51.100.x`。
- **品牌**：盾盾是原创角色（Haitao 2026-10-29），造型与动效以 `docs/mascot.md` 为准。盾盾不用 Grok、Codex、Coucou、Mochi 等别家的名字、形象和音效；面板会话行可以用 agent 厂商自己的标志标明是哪家的会话（Haitao 2026-10-29）。过渡期：现有从 Coucou（MIT）移植来的代码，在第 4 步重写删掉之前，保留原 MIT 声明和设置页致谢。
- **看不见就不调度。** 窗口收起、被遮挡、熄屏、锁屏时，停掉所有动画和计时器。性能验收数字以 `docs/mascot.md` 为准。

## 界面准则

- **动效**：高级而克制，节奏活泼。用弹簧和正弦缓动，进场稍慢、退场稍快；开了「减弱动态效果」就只做淡入淡出。常驻动画用 Core Animation 交给系统合成，不在主线程逐帧重画。
- **默认不打扰**：空闲时收进刘海，悬停或点击才展开；完成卡、介入卡按设置自动收回；红卡一直挂到恢复，临时卡放完就回到它。
- **状态 = 颜色 + 图标 + 文案**：绿 = healthy，琥珀 = egressMismatch，灰 = unknown，红 = violated。
- **点击范围**：只有看得见的形状接收点击，透明区域一律穿透，不挡菜单栏。
- **亮暗**：贴着刘海的部分（耳朵、面板、卡片）永远黑底白字，只有设置窗口跟随系统亮暗。细节见 `docs/ui.md`。
- **文案**：源语言是简体中文，一句话说清；按钮写动作本身（「重新检测」）。所有界面文案走 String Catalog，同时给 English 译文（`docs/ui.md`「多语言」）。
- **截图**：改了 UI 要附截图，张数见 `docs/ui.md`「截图」。

## 文档

| 什么时候 | 读哪份 |
|---|---|
| 开工前、换会话 | `HANDOFF.md`（接下来的步骤、还没写进文档的决定、待办）、`README.md`（运行、安装、模块） |
| 守卫信号、判定、`guard-state.json`、怎么画 | `docs/egress-guard.md` |
| 会话怎么读、什么时候算回合结束、什么时候响声音 | `docs/agent-integration.md` |
| 防火墙规则、开关、恢复 | `docs/firewall.md` |
| 盾盾的造型数据、动效、性能验收 | `docs/mascot.md` |
| 亮暗、多语言、面板布局、截图 | `docs/ui.md` |
| 起名字 | `docs/ubiquitous-language.md` |

结论与文档冲突时，明确指出；改已定的决策，先改文档并经用户确认。

## 命令

- **验收**：`swift build` 零警告，并且 `swift test` 全绿，两项都过才算完成。
- `./scripts/run.sh`：release 编译、打包 `build/Notchkeeper.app`、ad-hoc 签名并启动；会先结束正在运行的实例。
- `./scripts/demo.sh done|failed|question|approval|alert`：手动触发卡片，在实机上验 UI。它靠分布式通知，本机任何进程都能发，所以第 4 步起只在 DEBUG 构建里监听。
- guardd 的单轮调试、真机只读冒烟、安装和卸载见 `README.md`。
- 新增 lint / format 工具或依赖，要用户明示同意。

## 风格与命名

- **Swift**：照 [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/)。
  - 类型 UpperCamelCase，其余 lowerCamelCase；缩写大小写一致（`IP`、`URL`、`ID`）。
  - 优先值类型和 `enum` 状态机；错误用 `throws` 带具体错误类型。
  - UI 状态只在 `@MainActor` 上改；后台工作用专用队列或 actor。
  - 外部数据不强制解包。
- **领域词**：同一概念只有一个名字，以 `docs/ubiquitous-language.md` 为准，例如 turn end、egress、verdict、look、motion；新词先进词表。盾盾在代码里统一用 `Mascot` 前缀（Haitao 2026-10-29）。
- **配置与状态文件**：JSON 字段 lowerCamelCase；缺失字段用默认值，未知字段忽略；时间用 ISO 8601。
- **注释**：写为什么，不写做了什么。依赖外部行为的地方标 `@see`；规格里的数字注明出自哪份文档。
- **不写包 README**：每个 target 的职责写在 `Package.swift` 的注释和类型注释里；细节已经在 `docs/` 的，只链接、不重复。

## 提交

- commit / push 要用户本轮明示。amend、force-push、改 git 配置都不做。只暂存本次改动涉及的文件，不用 `git add` 整个目录。
- **删除优先审查**：提交前对 diff 逐行问「删掉会坏什么」，答不出的删掉或内联。汇报时列出删了什么、改了什么、有争议但保留的行及理由。
- 每次提交前更新 `HANDOFF.md`，随同一提交：做完的删掉（历史看 `git log`），只留接下来要做的和待办。
- **独立审查**：派一个新的 [`reviewer`](.claude/agents/reviewer.md) 子 agent（不用 fork，只读），给它改动和相关文档，让它审这次的 diff。必须修的问题包括：结论错、丢数据、永远卡住、安全问题、违反硬规则、可能断网。修完再审一轮，至多两轮；仍有问题就停下，交用户定。
- 一个提交只做一件能独立看懂的事，相关测试放在同一个提交里；重构与功能、修复分开。
- 格式（Conventional Commits）：

  ```
  <type>: <一句话说明改了什么>

  - 具体改动
  ```

  type 用 `feat` `fix` `refactor` `test` `docs` `build` `chore`；正文用中文列表。

## 汇报

- 一律用中文：对话里的汇报、提交说明、文档、代码注释都用中文；代码标识符和引用的原文除外。
- 先说结论，用白话；再给建议的下一步。
- 每个结论带依据（`文件:行`、官方文档链接或实测）；推断标「推断 / 未证实」。前提错了直接指出。
- 动到防火墙、LaunchDaemon / LaunchAgent 的改动，按全局 Contract 的「高影响」档收工；其余按全局 Contract 分档。

## Agent skills

| 意图 | skill | 结论落盘 |
|---|---|---|
| 磨方案、疑点讨论 | `grilling` | `HANDOFF.md` 或本文件 |
| 查 API / pf / agent 格式等事实 | `research` | 代码 `@see` 或 `docs/` |
| 验证状态模型或界面草稿 | `prototype` | 用完即删，结论写进 `docs/` |
| 按切片实现 | `tdd`（接口词汇见 `codebase-design`） | 代码 + 测试 |
| 界面布局、动效、评审 | `ui-ux-pro-max` | `docs/ui.md`、`docs/mascot.md` 或代码 |
| 难 bug、性能回退 | `diagnosing-bugs` | 根因写入提交说明 |
| 起名字、记决策 | `domain-modeling` | `docs/ubiquitous-language.md` |
| 改本文件 / skill | `writing-for-agents` | — |
| 换会话接手 | `handoff` | `HANDOFF.md` |
