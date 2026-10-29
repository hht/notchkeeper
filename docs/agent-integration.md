# agent 状态：从哪读、什么时候提醒

Notchkeeper 只关心 Claude Code 的三件事：**工作中、已停止、需要你介入**。本文定从哪读、怎么判、什么时候响声音。判定由 `AgentCore`（第 3 步新建）负责，配固定测试；读文件、监听目录、查进程在 App 外层。

## 来源：`~/.claude/sessions/<pid>.json`

每个 Claude Code 进程写一份 `~/.claude/sessions/<pid>.json`，状态一变就重写。本机 Claude Code 2.1.296 实测（10-29，只看元数据）。

- 官方从外部读会话状态的受支持方式是 `claude agents --json`（<https://code.claude.com/docs/en/agent-view>），直接读文件不在稳定接口里。用户选了直接读文件：监听目录几乎不花 CPU；每 2 秒调一次 CLI 单次要 0.4s，CPU 验收过不了。
- **不做兼容**（用户 10-29）：不退回会话 JSONL，不做多版本兼容，不为格式变化预留兜底。格式变了由用户改代码。解析不了的文件按 CLAUDE.md 准则 5 计数、跳过、不崩，到此为止。
- 零 hook：不改任何 agent 的配置。

### 只取这些字段

| 字段 | 用来做什么 |
|---|---|
| `pid` | 进程还在不在（`kill(pid, 0)`） |
| `procStart` | 和 `pid` 一起防 pid 复用 |
| `sessionId` | 会话的身份 |
| `kind` | 只看交互式会话（见「待实测」） |
| `status` | 三个状态 |
| `waitingFor` | 需要你介入时，区分等你回答和等你批准 |
| `statusUpdatedAt` | 这个状态从什么时候开始 |
| `cwd` | 只取最后一段当项目名 |

**不取 `name`**：它可能是从对话推出来的，算对话内容（CLAUDE.md「只读元数据，不读对话内容」）。其余字段也不读。

## 状态

| `status` | 状态 | 造型（`docs/mascot.md` §2） |
|---|---|---|
| `busy`、`shell` | 工作中 | working；干了很久（见下）变 longTurn |
| `idle` | 已停止 | 回合结束时 finished，5.2s 后按优先级回落 |
| `waiting` | 需要你介入 | `waitingFor` 是 `permission prompt` 或 `sandbox request` → approval；其余（`input needed` 等）→ question |

- **回合**（turn）：从已停止进入工作中起，到再次变成已停止止。中间的 `busy` / `shell` 来回切、经过「需要你介入」再回到工作中，都还在同一个回合里。
- **回合结束**（turn end）：回合中（工作中或需要你介入）变成已停止。从需要你介入直接变成已停止（例如你在批准时选了停下）也算。
- **干了很久**：处于工作中，并且离回合开始超过 10 分钟（中间等你的时间也算进去）。
- **中途接手**（App 启动时、或第一次看到某个文件时，它已经在工作中或需要你介入）：照常算一个回合，以文件里的 `statusUpdatedAt` 作为回合开始，结束时照常提醒。已经在需要你介入的，显示介入卡，但不补响 `Ping`（用户 10-29）。
- 出错、被打断在这个来源里看不出来，都归「已停止」。对应的造型暂不接线（用户 10-29）。
- 子 agent 在同一个进程里跑，推断不会单独写 sessions 文件，所以只会看到顶层回合（待实测）。

### 进程没了

- 文件在、进程不在（`kill` 返回 `ESRCH`），或者进程在但 `procStart` 对不上（pid 被复用）：会话已经没了，从列表里去掉，不算「已停止」，不提醒。
- 判不出来（例如 `kill` 返回别的错误）：这个会话算 unknown，不提醒，不进造型优先级。

## 提醒

| 事件 | 卡片 | 声音 |
|---|---|---|
| 回合结束 | 完成卡，按设置自动收回 | `Glass` |
| 进入需要你介入 | 介入卡，留到状态离开需要你介入才收回，也可以手动关 | `Ping` |
| 进入工作中 | 无 | 无：是你自己开的头 |

- 声音只用系统音效（`NSSound(named:)`），不用别家的音效。设置里沿用一个「提示音」总开关（`config.json` 的 `soundEnabled`）。
- 出口 violated 响 `Basso`；防火墙守住时不响（`docs/egress-guard.md`、`docs/firewall.md`）。
- 用户 10-29 定。

## 待实测（第 3 步开工时先做，结果写回本文）

1. `kind` 有哪些取值。`claude -p`、SDK 起的进程会不会也写文件？要不要只看 `interactive`？10-29 本机只见到 3 份文件，`kind` 都是 `interactive`，`entrypoint` 都是 `cli`。
2. 子 agent 会不会单独写 sessions 文件。
3. `waitingFor` 的完整取值。
4. 进程被 `kill -9` 后文件是否留下。
