# AGENTS.md — Notchkeeper（菜单栏出口守卫 + 刘海卡片）

> 本轮用户输入优先于任何文档。通用 MUST NOT 与收工分档见全局 Contract（`~/.agents/AGENTS.md`）；本文件管本仓的准则、SSOT 与流程。

## 这是什么

Haitao 本机自用的 macOS 菜单栏 / 刘海应用（SwiftUI + AppKit，SwiftPM，macOS 14+），两件事：

1. **出口守卫**：检查 Clash 内核、utun 路由、出口 IPv4；不在允许列表时刘海亮红卡，并拦截 Claude（桌面端、`claude` CLI、浏览器 claude.ai 标签）。
2. **任务完成卡片**：编码 agent 的**顶层**回合结束时在刘海弹卡，用来替代 Vibe Island 的提示；目前接 Claude Code 和 Grok Bot app。

进度与范围见 `README.md`。

## 最高准则

1. **删除优先。** 每一行都要答得出「删掉会坏什么」。答不出先查来历，查清了还答不出就删，可读性不能降。只转发、只换名字、只有一个调用方的函数、类型、文件都内联。不为没出现的需求写代码（测试、重构不算）。同样的行为，代码越少越好。
2. **一个模块一个问题。** 按会独立变化的设计决定划分文件或 target，比如「出口健不健康」「回合结束了没有」「要拦哪些进程」「卡片怎么排队」，不按 View / Model / Manager 这类层次切。
   - 类型注释第一句写它回答哪个问题、不该知道什么。
   - 依赖单向无环：判定逻辑不 import SwiftUI / AppKit。
   - 计算与副作用分开：核心是输入数据、输出数据的纯函数（健康判定、事件过滤去重、拦截决策）；文件监听、网络探测、杀进程、画界面放在外层。
3. **本质对，分支少。** 先定数据结构、状态机和不变量，再写分支；同一件事只有一个 owner，禁止特例瀑布。规模小（几个进程、几十个会话），用最直接的算法；要调速先测量。
4. **可测试，测试先行。** 新判定规则或修 bug，先写一个会失败的测试，亲眼看它失败，再改到绿。时间、随机数、文件系统、网络探针、进程表都从参数注入，测试可以快进时间、重放事件序列。纯逻辑测不了的（窗口、动效、权限弹窗），在提交说明里写实机步骤和结果。
5. **信任边界。** 以下数据在边界解析成精确类型，之后内部直接用：
   - 外部输入：会话 jsonl、hook 的 stdin、`config.json`、分布式通知 userInfo、探针响应、`ps` / `proc_pidpath` 结果。
   - **「未知」是一个状态，不是「正常」也不是「异常」**：探针超时、断网都是 unknown，不能当作 healthy，也不能当作 violated。
   - 兜底和默认值只给真会发生的情况；内部不变量坏了就 `preconditionFailure`。
   - 解析不了的外部数据计数并降级处理，不能崩。
6. **从根源解决。** 改在产生问题的地方：先复现，再拿出根因证据，再改。禁止症状补丁：特例 if、`DispatchQueue.main.asyncAfter` 等延时掩盖、吞错误、改文案遮问题。找不到根因就停下报告。
7. **照一手资料。** 依赖外部行为的代码，先按实际用的版本读官方文档、源码或实测，代码里用 `// @see` 指向出处，实测经过写进提交说明。外部行为包括 macOS API、各 agent 的会话格式和 hook 协议。设计照搬一个成熟实现的完整做法，只写平台逼出来的偏差。说不出照的是谁，就停下报告。
8. **照社区惯例。** 照 Swift API Design Guidelines 和 Apple 平台的通行做法，禁止自创平行惯例。

**决策序：** 正确性 > 可验证性 > 极简 > 性能 > 复用 > 速度。

## 本仓硬规则

- **每个 agent 最多 1 个「回合结束」hook，优先零 hook 的被动文件监听。** 改任何 agent 的配置之前：
  - 先给用户看 diff 并备份。
  - 条目带可识别的标记，方便卸载。
  - 已有的值（比如 Codex 的 `notify`）串联保留，不覆盖。
  - hook 程序永远 exit 0、不往 stdout 写东西，不能阻塞或改变 agent 的行为。
- **子 agent 完成绝不提醒。** 只有顶层回合结束才弹卡。过滤规则（`subagents/`、`isSidechain`、`session_meta.source.subagent`、`stop_hook_active`、中断）集中在一处，并有固定测试。
- **只读被动监听，不读对话内容。** 会话文件只取判定需要的字段，Grok Bot app 的持久化目录只看文件元数据（静默超时），日志和界面都不出现消息正文。
- **拦截只在明确异常时触发。** 明确异常指拿到不在允许列表的出口 IP，或去往公网（局域网以外）的路由不走 utun（Haitao 2026-10-28 确认：除局域网外全部流量必须走代理）。unknown 时只拒绝新启动、显示琥珀色，不杀进程。进程按 bundle id 或真实可执行路径识别，不按名字 grep。
  - 已经判 violated 后，只有一轮完整的 healthy 才能解除；断网或探针超时不会把 violated 降成 unknown，以免放过已经拦下的 Claude（Haitao 2026-10-28 确认）。
- **不碰网络与 shell 环境。** 不改 `~/.zshrc` 等 shell 配置，不读写 Clash 配置（「打开 Clash」只能是打开 App），不用 pf 和 Network Extension，不改系统网络设置。出口探测只请求第三方服务（如 ipinfo.io），不碰 Claude / Anthropic 的域名。
- **不打印密钥，日志不记 IP。** 界面上完整显示出口 IP（Haitao 2026-10-28 确认）。
- **不用别家品牌形象。** 不用 Grok、Codex、Coucou、Mochi 等的名字、形象和音效。吉祥物原创，只通过 `Mascot.swift` 的 `MascotRenderable` 接入。
  - 例外（Haitao 2026-10-28 确认）：吉祥物可在 Coucou（MIT）角色基础上小改并保留其全部状态，仅供 Haitao 本人使用；仓库必须保持私有，不得公开或分发，相关素材只放 `MascotRenderable` 及其资源目录。
- **UI 达到或超过 Coucou 的水准。** 弹簧动效、毛玻璃、页面过渡，尊重系统的「减弱动态效果」。透明区域不能挡菜单栏点击。

## 文档

| 什么时候 | 读哪份 |
|---|---|
| 开工前、换会话 | `README.md`（运行方式、当前里程碑、未实现项）；`HANDOFF.md` 建立后以它为准 |
| 事件模型、过滤规则 | `Sources/Notchkeeper/AgentEvents.swift` 的类型注释 |
| 起名字 | `docs/ubiquitous-language.md`（写第一个新领域概念时建立） |

结论与文档冲突时明确指出。改已定的决策，先改文档并经用户确认。

## 命令

- `swift build`：编译，必须零警告。
- `./scripts/run.sh`：编译、打包 `build/Notchkeeper.app`、ad-hoc 签名并启动，会先结束正在运行的 Notchkeeper。
- `build/Notchkeeper.app/Contents/MacOS/Notchkeeper --selftest`：事件过滤自检，exit 0 才算通过。
- `./scripts/demo.sh done|alert`：手动触发卡片，用来实机验 UI。
- `swift test`：GuardCore 的单元测试（swift-testing），必须全绿。
- 验收入口：`swift build` 零警告 + `swift test` 全绿 + `--selftest` 通过。新增 lint / format 工具或依赖要用户明示。

## 界面准则

- 下限是 Coucou：弹簧动效（response≈0.35，damping≈0.8），毛玻璃叠黑底，内容从刘海"长"出来；开了"减弱动态效果"就换成淡入淡出。
- 默认不打扰：空闲时收进刘海，悬停才展开；完成卡 6～8 秒自动收回；红卡一直留到恢复。
- 状态 = 颜色 + 图标 + 文案，不能只靠颜色：绿是正常，琥珀是 unknown，红是 violated。
- 只有看得见的形状才接收点击，透明区域一律穿透，不能挡住菜单栏。
- 出口 IP 在界面上完整显示（如 `198.51.100.7`）；文案以中文为主，一句话说清楚，按钮写动作本身（"重新检测"）。
- 吉祥物只放在 `Mascot.swift` 的 `MascotRenderable`；默认原创，Coucou 例外见上方硬规则。
- 改了 UI 要附截图：暗色 + 刘海机型（Haitao 只用暗色，亮色暂不做）；有外接屏时补一张无刘海外接屏。

## 风格与命名

- **Swift：** 照 [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/)。
  - 类型 UpperCamelCase，其余 lowerCamelCase；缩写大小写一致（`IP`、`URL`、`ID`）。
  - 优先值类型和 `enum` 状态机，用类型排除非法状态。
  - 错误用 `throws` 带具体错误类型，不用 `try?` 吞掉。
  - UI 状态只在 `@MainActor` 上改；后台工作用专用队列或 actor。
  - 不用强制解包处理外部数据。
- **命名：** 同一概念只有一个名字。「顶层回合结束」统一叫 turn end，「出口」统一叫 egress，三态统一叫 healthy / unknown / violated。
- **配置：** `config.json` 字段用 lowerCamelCase，缺失字段用默认值，未知字段忽略。
- **注释：** 写为什么，不写做了什么；依赖外部行为的地方标 `@see`。
- **不写包 README。** 类型和文件的职责、取舍写在类型注释里。

## 提交

- commit / push 要用户本轮明示；amend、force-push、改 git 配置都不做。只暂存本次改动涉及的文件，不用 `git add` 整个目录。
- **删除优先审查**：提交前对 diff 逐行问「删掉会坏什么」。汇报时列出删了什么、改了什么、有争议但保留的行及理由。
- 每次提交前更新 `README.md` 的里程碑和未实现项（`HANDOFF.md` 建立后改为更新它），随同一提交。
- 一个提交只做一件能独立看懂的事，相关测试放在同一个提交里；重构与功能、修复分开。
- 多人协作（Jason 架构、Emily 设计、S1m0nE 前端、VPS管理员负责网络和出口）：同一时间只有一个人改同一组文件，别人有未提交的改动时不动。
- 格式（Conventional Commits）：

  ```
  <type>: <一句话说明改了什么>

  - 具体改动
  ```

  type 用 `feat` `fix` `refactor` `test` `docs` `build` `chore`，正文用中文列表。

## 汇报

- 先说结论，用白话，再给建议的下一步。
- 每个结论带依据（`文件:行`、官方文档链接或实测）；推断标「推断 / 未证实」。前提错了直接指出。
- 动到 agent 配置、杀进程逻辑的改动，按全局 Contract 的「高影响」档收工。

## Agent skills

| 意图 | skill | 结论落盘 |
|---|---|---|
| 磨方案、疑点讨论 | `grill-with-docs` | 本文件或 `docs/` |
| 查 API / agent 格式 / 协议事实 | `research` | 代码 `@see` 或 `docs/` |
| 按切片实现 | `tdd`（接口词汇见 `codebase-design`） | 代码 + 测试 |
| 界面布局、交互、评审 | `ui-ux-pro-max` | Emily 的设计规范 |
| 难 bug | `diagnosing-bugs` | 根因写入提交说明 |
| 改本文件 / skill | `writing-for-agents` | — |
| 换会话接手 | `handoff` | `HANDOFF.md` |
