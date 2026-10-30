# agent 状态：从哪读、什么时候提醒

Notchkeeper 只关心 Claude Code 的三件事：**工作中、已停止、需要你介入**。只接 Claude Code（用户 10-29）：Grok Bot 的对话在服务器上，本机只有 `desktop-status.json`（pid、是否登录）和 `~/.grokbot/local-exec-daemon.json`（`inflightCount`），分不出会话和状态；Grok CLI（`~/.grok/active_sessions.json`）也不接。本文定从哪读、怎么判、什么时候响声音。判定由 `AgentCore`（第 3 步新建）负责，配固定测试；读文件、监听目录、查进程在 App 外层。

## 来源：`~/.claude/sessions/<pid>.json`

每个 Claude Code 进程写一份 `~/.claude/sessions/<pid>.json`，状态一变就重写。本机 Claude Code 2.1.296 实测（10-29，只看元数据）。

- 官方从外部读会话状态的受支持方式是 `claude agents --json`（<https://code.claude.com/docs/en/agent-view>），直接读文件不在稳定接口里。用户选了直接读文件：监听目录几乎不花 CPU；每 2 秒调一次 CLI 单次要 0.4s，CPU 验收过不了。
- **不做兼容**（用户 10-29）：不退回会话 JSONL，不做多版本兼容，不为格式变化预留兜底。格式变了由用户改代码。解析不了的文件按 CLAUDE.md 准则 5 计数、跳过、不崩，到此为止。
- 零 hook：不改任何 agent 的配置。

### 只取这些字段

| 字段 | 用来做什么 |
|---|---|
| `pid` | 进程还在不在、进程退出通知 |
| `procStart` | 和 `pid` 一起认进程，防 pid 复用 |
| `kind`、`entrypoint` | 只看 `kind: interactive` 并且 `entrypoint: cli` 的会话，也就是终端里开的 `claude`；`claude -p`（`sdk-cli`）、SDK、VS Code、Desktop 等都不算（用户 10-29，依据见「实测」1） |
| `status` | 三个状态；还没有这个字段的是刚起来的会话，先不看（「实测」5） |
| `waitingFor` | 需要你介入时，区分等你回答和等你批准 |
| `statusUpdatedAt` | 这个状态从什么时候开始 |
| `cwd` | 面板会话行显示完整路径（用户 10-29，`docs/ui.md`「面板布局」） |

**不取 `name`**：它可能是从对话推出来的，算对话内容（CLAUDE.md「只读元数据，不读对话内容」）。`nameSource` 也分不出来：自动起的写 `derived`，`claude -n <名字>`、`/rename <名字>` 写 `user`，但不带参数的 `/rename` 会拿对话让模型起名，同样写 `user`（10-29 实测，二进制里两条路径调用同一个写入函数）。所以名字一律不取（用户 10-29）。其余字段也不读。

## 状态

| `status` | 状态 | 造型（`docs/mascot.md` §2） |
|---|---|---|
| `busy` | 工作中 | working；干了很久（见下）变 longTurn |
| `idle`、`shell` | 已停止 | 回合结束时 finished，5.2s 后按优先级回落 |
| `waiting` | 需要你介入 | 照 Claude Code 自己的归类表（「实测」3）：`permission prompt`、`sandbox request`、`worker request`、`goal proposal` → approval；`input needed`、`dialog open` 和没见过的取值 → question（用户 10-29） |

- `shell` 是「空闲，但后台挂着 shell 命令」（例如 dev server），见「实测」6。10-29 版当成工作中，挂着 dev server 的会话回合永远不结束。
- **回合**（turn）：从已停止进入工作中起，到再次变成已停止止。中间经过「需要你介入」再回到工作中，都还在同一个回合里。
- **回合结束**（turn end）：回合中（工作中或需要你介入）变成已停止。从需要你介入直接变成已停止（例如你在批准时选了停下）也算。
- **干了很久**：处于工作中，并且离回合开始满 10 分钟（中间等你的时间也算进去）。
- **中途接手**（App 启动时、或第一次看到某个文件时，它已经在工作中或需要你介入）：照常算一个回合，以文件里的 `statusUpdatedAt` 作为回合开始，结束时照常提醒。已经在需要你介入的，不补弹介入卡、不补响 `Ping`：卡片只跟着事件走（`docs/ui.md`「卡片」），靠盾盾造型提示。
- 出错、被打断在这个来源里看不出来，都归「已停止」。对应的造型暂不接线（用户 10-29）。
- 子 agent 在同一个进程里跑，不单独写 sessions 文件（10-29 实测），所以只会看到顶层回合。
- 只看得到每次读到的快照：两次读之间「工作中 → 已停止 → 工作中」（例如回合结束后马上自动提交排队的消息）会看成同一个回合，不提醒回合结束，干了很久也从旧回合算起（推断，未实测）。

### 进程没了

- 用 `proc_pidinfo` 的 `PROC_PIDTBSDINFO` 查进程启动时刻：查不到（进程不在，或判不出来），或者和 `procStart` 对不上（pid 被复用），会话都算没了，从列表里去掉，不算「已停止」，不提醒，不进造型优先级。
- `kill -9` 后文件留着、目录不变（「实测」4），所以每个会话的 pid 挂一个进程退出通知（`DispatchSource.makeProcessSource(identifier:eventMask: .exit)`，即 kqueue `EVFILT_PROC` / `NOTE_EXIT`），进程一退出就去掉，不轮询（用户 10-29）。
- `procStart` 在边界解析成时刻（UTC、精确到秒）再比。解析不了的文件照准则 5 计数、跳过，上一次读到的状态留着。

## 提醒

| 事件 | 卡片 | 声音 |
|---|---|---|
| 回合结束 | 完成卡，按设置自动收回 | `Glass` |
| 进入需要你介入 | 介入卡，按设置自动收回（用户 10-29），也可以手动关 | `Ping` |
| 不再需要你介入：回到工作中、进程没了、不在回合里时变成已停止 | 撤掉这个会话的介入卡（排着的、正在放的都撤，`docs/ui.md`「卡片」2） | 无 |
| 进入工作中 | 无 | 无：是你自己开的头 |

- 卡片什么时候放、和红卡怎么让，见 `docs/ui.md`「卡片」：所有临时卡排一个队，声音在卡放出来时才响。
- 声音只用系统音效（`NSSound(named:)`），不用别家的音效。设置里沿用一个「提示音」总开关（`config.json` 的 `soundEnabled`）。
- 出口 violated 响 `Basso`；防火墙守住时不响（`docs/egress-guard.md`、`docs/firewall.md`）。
- 用户 10-29 定。

## 实测（10-29，Claude Code 2.1.296）

方法：在 tmux 里起交互式 `claude`、跑 `claude -p`、派子 agent，每 0.1s 只记 `pid`、`kind`、`entrypoint`、`status`、`waitingFor`、`statusUpdatedAt`；再在本机二进制里查写文件的代码（`strings` 搜 `waitingFor`、`procStart`、`CLAUDE_CODE_SESSION_KIND`）。

1. **`kind` 不分 `-p`**：取值是环境变量 `CLAUDE_CODE_SESSION_KIND`（`bg`、`daemon`、`daemon-worker`），没设就是 `interactive`。`claude -p` 实测也写文件，`kind: interactive`、`entrypoint: sdk-cli`，开始就是 `busy`，退出时删文件，不经过 `idle`。区分要看 `entrypoint`，二进制里见到的取值：`cli`、`sdk-cli`、`sdk-ts`、`sdk-py`、`claude-vscode`、`claude-desktop`、`claude-in-teams`、`local-agent`、`remote`、`ssh-remote`、`bench`。
2. **子 agent 不单独写文件**：派一个子 agent 跑 10s，目录没有任何变化。
3. **`waitingFor` 六个取值**：`permission prompt`（工具权限，代码里没配的对话框也默认归它）、`sandbox request`（沙箱要联网）、`worker request`、`goal proposal`（Claude 提议会话目标）、`input needed`（AskUserQuestion、MCP 要你输入等）、`dialog open`（其他对话框，例如模型回退、设置变更确认）。Claude Code 自己的归类表：前四个 → permission，`input needed` → question，`dialog open` → 不归类。实测：要批准 Bash → `waiting` + `permission prompt`；AskUserQuestion → `waiting` + `input needed`；在批准框按 Esc → 直接 `idle`。
4. **`kill -9` 后文件留下**，内容停在死前的状态（实测停在 `waiting`）；Claude Code 自己下次列会话时才删掉。正常退出（SIGTERM、`/exit`）会删掉 `.json` 和 `.key`。所以进程退出时目录**不一定**有变化，要另外知道进程没了。
5. 其他：
   - `statusUpdatedAt`、`startedAt`、`updatedAt` 是 epoch 毫秒；新会话起来先写 `idle`。
   - `procStart` 是 `LC_ALL=C TZ=UTC ps -o lstart= -p <pid>` 的输出，例如 `Thu Oct 29 17:54:44 2026`（UTC，精确到秒，日期个位数时前面补空格）。Claude Code 自己也是用 `kill(pid, 0)` 加比对这个串来判断进程还在不在。
   - 工作区还没点「信任」时只有 `.key`，没有 `.json`。
   - 会话刚起来第一次写的文件没有 `status`、`statusUpdatedAt`（和 `updatedAt`），之后原地补上。
   - 状态变化是**原地重写**同一个文件（inode 不变，目录的 mtime 也不变），只监听目录收不到；所以每份文件也要单独监听。
   - 代码里 `status` 在「主回合在跑」或「后台任务（delegated work）在跑」时都是 `busy`（推断，未实测）：回合结束的提醒会等后台任务也跑完。
   - 每份 `.json` 旁边有一份 `<pid>.<64 位十六进制>.key`（权限 600），是对等通信的凭据，不读。
6. **`shell`**（10-30 查二进制）：`status === "idle" && 有后台 shell ? "shell" : status`，是空闲的一种。
