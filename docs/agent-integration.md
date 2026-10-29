# 编码 agent 会话接入（Claude Code CLI）

> 状态：纯逻辑与只读 I/O 已完成并有测试（`AgentCore` / `AgentWatch`）；App UI 尚未接入。
> 零 hook：不装任何 Claude Code hook，不改 `~/.claude` 下任何设置，只读会话文件。

## 1. 读什么

Claude Code 2.1.x 把每个会话写成一个 JSONL 文件：

| 路径 | 含义 | 处理 |
|---|---|---|
| `~/.claude/projects/<编码后的项目路径>/<会话 id>.jsonl` | 主会话 | 读 |
| `~/.claude/projects/<编码后的项目路径>/<会话 id>/subagents/*.jsonl` | 子 agent | **永不读** |

- 只列两层目录，所以根本进不到 `subagents/`；`ClaudeSubagentFilter.isSubagentFile` 再兜一层：路径里任何一层目录叫 `subagents` 都丢掉。
- 只看最近 30 分钟写过的、最新的 16 个文件（`ClaudeSessionFiles` 可配）。
- 每个文件只读**尾部 64KB**，丢掉开头被截断的半行；窗口里没有一条能参与判定的主会话记录时（典型情况：最后一条记录超过 64KB，窗口里只剩残片），放大到 1MB 再读一次；1MB 里仍然没有，这次扫描就不报这个会话。**从不读整个文件。**

## 2. 信号表

逐行解码，每行只取元数据；缺字段、字段类型不对都容忍，整行解析失败就跳过（计入 `malformedLines`，只用来观察格式有没有变）。

| 记录 | 条件 | 信号 |
|---|---|---|
| `type: "user"` | 正文（字符串，或某个 `text` 块）**整串等于** `[Request interrupted by user]` 或 `[Request interrupted by user for tool use]` | 中断 |
| `type: "user"` | `isMeta` 或 `isCompactSummary` 为真（系统注入、压缩摘要） | 忽略 |
| `type: "user"` | 其他（提问、工具结果） | 进行中 |
| `type: "assistant"` | `isApiErrorMessage: true`，且 `error == "rate_limit"` 或 `apiErrorStatus == 429` | 出错（限流） |
| `type: "assistant"` | `isApiErrorMessage: true`，其他 | 出错（API） |
| `type: "assistant"` | 顶层 `stop_hook_active: true`（stop hook 让它接着干） | 进行中（即使 stop_reason 是 end_turn） |
| `type: "assistant"` | `message.stop_reason` 是 `end_turn` / `stop_sequence` / `max_tokens` / `refusal` | 回合结束 |
| `type: "assistant"` | `tool_use` / `pause_turn` / null / 不认识的值 | 进行中 |
| 其他 `type`（system、ai-title、attachment、file-history-snapshot …） | — | 忽略 |
| 任意 | `isSidechain: true` | 丢掉（子 agent） |
| 任意 | `session_meta.source.subagent` 或顶层 `source.subagent` 存在且不为 null | 整个会话丢掉（子 agent 会话，不显示、不提醒） |
| 任意 | 没有 `timestamp` | 忽略 |

「子 agent 完成绝不提醒」的五个信号（`subagents/` 路径、`isSidechain`、`session_meta.source.subagent`、`stop_hook_active`、中断）集中写在 `ClaudeSubagentFilter` 的注释里，固定测试是 `Tests/AgentCoreTests/SubagentFilterTests.swift` 的 `NoNotificationSignals`：每个信号一条，外加一条对照组证明普通 end_turn 确实会提醒。

按顺序折叠，最后一条参与判定的记录决定状态：

- `working`：最后是「进行中」。
- `finished`：最后是「回合结束」。
- `error(.api / .rateLimit)`：最后是 API 错误。
- `interrupted`：最后是中断标记。
- `stale`：见第 4 节。

依据：
- stop_reason 取值：<https://platform.claude.com/docs/en/api/messages>
- 429 = rate_limit_error：<https://platform.claude.com/docs/en/api/errors>
- `SDKAssistantMessageError` 里的 `rate_limit`：<https://code.claude.com/docs/en/agent-sdk/typescript>

## 3. 隐私保证

- 解码结构里**没有任何文本字段**。中断标记只在解码时做一次整串比较，结果是一个 Bool；对话正文、工具输入输出、错误信息文字都不保存、不打印、不写日志。
- 项目名只取 `cwd` 的最后一段；会话 id 是文件名。
- 错误只区分 `api` / `rateLimit` 两类，从 `error` 枚举值和 HTTP 状态码判断，**不看错误信息文字**。
- 测试全部用合成数据；有一条测试把整个解码结果 `dump` 出来，断言合成正文里的标记串从不出现。
- 实机检查 `NOTCHKEEPER_LIVE_AGENTS=1 swift test --filter LiveAgents` 只打印各状态的个数。

## 4. 90 秒兜底

进程被杀、终端被关时，文件停在「进行中」，不会再有结束记录。所以 `working` 状态下，如果 `now − max(文件 mtime, 最后一条记录时间) > 90 秒`，就降成 `stale`：

- `stale` 不算在跑，UI 不该显示转圈，也不提醒。
- 时钟由外部注入（`resolved(now:lastWrite:)`、`ClaudeSessionWatcher(clock:)`），测试不靠真实时间。
- **刻意的偏离**：`stale → finished/error` 仍然会产生事件。一次跑 3 分钟、中途没有新记录的构建会先被降成 stale；如果这时不提醒，长任务就永远收不到完成通知，而长任务恰恰最需要通知。

## 5. 事件（什么时候弹卡）

`SessionEvent.diff(old:new:)` 比较前后两次扫描，按会话 id 对齐：

- 只有前一次是 `working` 或 `stale`、这一次是 `finished` / `error` 时才产生事件。
- `interrupted` 永不提醒（用户自己按的 Esc）。
- 第一次看到的会话不提醒：App 启动时不重放历史。
- 子 agent 在源头就被丢掉，永远产生不了事件。
- **不合并**：三个会话同时完成就是三个事件。合并、节流是 UI 的事（参考 `prototype/agent-cards.md`）。
- 用时 = 结束记录时间 − 回合起点。尾部窗口滑过了起点时，取前后两次看到的起点里更早的那个。

## 6. 给 S1m0nE 的接口

```swift
import AgentCore
import AgentWatch

public enum AgentKind: String, Sendable, Codable { case claudeCode }   // Grok Bot 以后再加
public enum AgentErrorKind: String, Sendable { case api, rateLimit }
public enum AgentState: Sendable, Equatable { case working, finished, error(AgentErrorKind), interrupted, stale }

public struct AgentSession: Sendable, Equatable, Identifiable {
    var id: String            // sessionId（= 会话文件名）
    var kind: AgentKind
    var project: String       // cwd 最后一段；拿不到时是空串
    var state: AgentState
    var turnStartedAt: Date?  // 当前/刚结束回合的起点；不知道时为 nil
    var updatedAt: Date       // 最后一条参与判定的记录时间
}

public enum SessionEvent: Sendable, Equatable {
    case finished(sessionID: String, kind: AgentKind, project: String, duration: Duration)
    case error(sessionID: String, kind: AgentKind, project: String, errorKind: AgentErrorKind)
}

@MainActor public final class ClaudeSessionWatcher {
    init(files: ClaudeSessionFiles = .init(), interval: Duration = .seconds(2), clock: @escaping @Sendable () -> Date = { Date() })
    var onUpdate: (([AgentSession], [SessionEvent]) -> Void)?   // 每次扫描后在主线程调用
    func start()   // 立刻扫一次，之后每 2 秒一次；重复调用无副作用
    func stop()    // 之后不再回调，正在跑的那次扫描结果丢掉
}
```

- App 进程内直接跑，不经过 guardd。
- 扫描在后台线程，扫描之间不重叠，回调在主线程。
- `onUpdate` 每次都给出全部主会话（新的在前）。事件多数时候是空数组。
- **命名冲突**：`Sources/Notchkeeper/Sessions.swift` 现在也有 `AgentSession` / `AgentKind`。App 里模块内的同名类型会遮住导入的类型，接入时需要用新的替换旧的，或者写 `AgentCore.AgentSession`。另外旧 `AgentKind` 有 `allCases`（`Config.swift` 在用），新的没有 `CaseIterable`。

## 7. Grok Bot App

`roster.last-roster` 只提供 `unreadCount` / `awaitingUserResponse`，没有回合开始、结束、出错的信号。所以 Grok Bot 最多只能做「有新回复 / 等你回复」，做不了「完成 · 用时」「出错」。

**待 Haitao 决定，未实现**：要不要做这一档弱提示。

## 8. 「点卡片跳到终端」目前不可靠

会话文件只有 `cwd`，没有终端、窗口、tab 的标识。同一目录可能开着多个终端，也可能终端已经关了。在找到可靠的映射之前，卡片只做提示，不承诺跳转。

## 9. 已知局限

- **斜杠命令**（实测 5 例）：用户输入后只跟一条 `system/local_command` 记录。会显示约 90 秒「进行中」，然后静默变 stale，不误报完成。没有加 idle 判定，是怕回合中途排队的命令导致漏报真正的完成。
- **等权限确认**超过 90 秒会变 stale；确认后继续跑，结束时照常提醒（见第 4 节）。
- **限流的真实格式没验证过**：`error == "rate_limit"` / `apiErrorStatus == 429` 来自 API 文档和 Agent SDK 类型定义（见第 2 节「依据」），本机会话文件里还没见过一条真实的限流记录。格式不同的话会落到「出错（API）」，不会漏报，只是分类不对。
- **`stop_hook_active`、`session_meta.source.subagent`** 在 Claude Code 2.1.x 的会话文件里也没见过，是防御性解码：字段没有、为 null、类型不对都当作不存在。标记是会话级的：尾部窗口里任一条记录带标记，整个会话都不算主会话。标记若只写在文件第一行、而文件大到尾部窗口读不到第一行，就认不出来，只能靠其余四个信号。
- **最后一条记录超过 1MB**：两次尾部读取都只拿到残片，这个会话在这次扫描里不显示，也不提醒；下一条正常大小的记录写入后恢复。
- **轮询间隙**：一个回合在两次扫描（2 秒）之间开始又结束，看不到 working，就不提醒。两个回合落在同一次轮询里时，用时可能从前一个回合的起点算。
