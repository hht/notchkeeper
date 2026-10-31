# agent 状态：从哪读、什么时候提醒

只接 Claude Code（用户定；Grok 本机只有 `desktop-status.json` 的 `inflightCount`，分不出会话）：工作中、已停止、需要你介入，外加回合怎么结束的（做完、出错、被你取消）。判定归 `AgentCore`；读文件、监听、查进程在 App 外层。

## 两个来源

| 来源 | 谁写 | 管什么 |
|---|---|---|
| `~/.claude/sessions/<pid>.json` | Claude Code | 有哪些会话、此刻状态、进程在不在、`sessionId` |
| `~/Library/Application Support/Notchkeeper/turns/<sessionId>.json` | 自带的 mod（「Notchkeeper mod」） | 最近一次结束的主回合 |

按 `sessionId` 对上。**回合结束只看 mod**，sessions 文件只管此刻的状态：它分不出 API 出错、Esc、拒绝批准（都只是变 `idle`），后台 agent 完成、排队消息开始时还会闪一下 `idle`（「实测」7）。

- 用 mod，不用 settings.json 的 hooks（用户定）：hooks 每个事件起一个进程，Esc 打断时 `Stop` 不触发。
- 没装 mod 或这个会话没加载 mod（没信任、`--bare`、`--safe-mode`、组织策略）：照常显示忙闲和介入，**不弹完成卡、出错卡**，不按 `idle` 猜。
- 不用 `claude agents --json`：和 sessions 文件一样粗，每次 0.4s。

### sessions 文件只取这些字段

| 字段 | 用途 |
|---|---|
| `pid`、`procStart` | 认进程，防 pid 复用 |
| `sessionId` | 对上回合文件；会拼进要删的路径，不是 UUID 的整份按解不开处理 |
| `kind`、`entrypoint` | 只看 `interactive` + `cli`，即终端里的 `claude`（用户定，「实测」1） |
| `status` | 状态；还没有这个字段的是刚起来的会话，先不看 |
| `waitingFor` | 等你回答还是等你批准 |
| `statusUpdatedAt` | 状态从什么时候开始 |
| `cwd` | 会话行显示路径；跳转 Ghostty 找窗口 |

`name` 不读：可能是从对话推出来的，也和 Ghostty 标题对不上。

## 状态

| `status` | 状态 | 造型（`docs/mascot.md` §2） |
|---|---|---|
| `busy` | 工作中 | working；满 10 分钟变 longTurn |
| `idle`、`shell` | 已停止（`shell` = 空闲但挂着后台 shell，「实测」6） | — |
| `waiting` | 需要你介入 | 照 Claude Code 自己的归类（「实测」3）：`permission prompt`、`sandbox request`、`worker request`、`goal proposal` → approval；其余和没见过的 → question |

- 主回合结束、后台 agent 还在跑时，`status` 一直是 `busy`。
- **回合**：Claude 回应一条消息（你发的，或后台 agent 完成送进来的通知）的全过程，由 mod 的 `turn.start` / `turn.complete` 界定；带 `agentId` 的是子 agent，不算。
- **干了很久**：从已停止进入工作中起满 10 分钟（中间等你的时间也算），回到已停止清零。
- **中途接手**（App 启动或第一次看到某个文件时已在工作中 / 需要你介入）：以 `statusUpdatedAt` 作为开始；不补弹介入卡、不补响。App 开始看之前就结束的回合（比 `at`）不补弹；之后结束的照常提醒。

### 回合怎么结束的

回合文件里 `turnId` 变了就算一次回合结束：

| `reason` | 最后一步 `stopReason` | 结局 | 提醒 |
|---|---|---|---|
| `answer` | 不是 `tool_use` | 做完 | 后台 agent 数为 0：完成卡 + `Glass`；不为 0：等它们完成后那个回合结束再提醒 |
| `answer` | `tool_use` | 取消（在批准框拒绝） | 无 |
| `aborted` | — | 取消（Esc） | 无 |
| `error`、`refusal` | — | 出错 | 出错卡 + `Funk`，不管后台 agent |

- `reason` 的取值出自 Claude Code 的类型定义 `TurnCompleteReason`。正常回答最后一步一定是 `end_turn` / `max_tokens` / `stop_sequence`；停在 `tool_use` 说明工具结果之后没再请求模型。
- 排队消息：上一回合照常提醒；下一回合开始时 mod 不动回合文件，App 晚一点读也看得到。
- 两次读之间同一会话结束两个回合，只看得到后一个（推断）。
- 回合文件比 sessions 文件先到（`/clear` 后 sessions 还是旧 `sessionId`）：先不记，下次会话对上再算。
- `/clear` 换掉的旧 `sessionId` 的读过记录留着：`--resume <旧 id>` 回来时不补弹。
- 两个终端 `--resume` 同一会话：提醒挂哪个进程不固定（少见，不处理）。

### 进程没了

- 用 `proc_pidinfo(PROC_PIDTBSDINFO)` 查启动时刻：查不到或和 `procStart` 对不上，会话算没了，从列表去掉，不提醒。
- `kill -9` 后文件留着、目录不变（「实测」4），所以每个 pid 挂进程退出通知（`DispatchSource.makeProcessSource(.exit)`），不轮询。

## Notchkeeper mod

Claude Code 官方插件里的 JS 模块（2.1.287 起默认开启），事件发生时被调用。<https://code.claude.com/docs/en/plugins/mods/overview>。源码 `ClaudeMod/`（本地 marketplace），`claude plugin test` 离线测。mod API 随版本变、不做兼容（用户定）：升级 Claude Code 后重跑测试和「实测」8。

- **只报事实**：`turnId`、`reason`、最后一步 `stopReason`、结束时的后台 agent 数、时刻。判定归 AgentCore。
- **只在主回合结束时、只在交互式会话写**（`session.start` 的 `isInteractive`）；**只写元数据**，提示词、回答、工具参数一律不写。
- **后台 agent 怎么数**：`agent.spawn` 时 `background` 为 true 的记下 `next(e)` 返回的 `agentId`；带这个 `agentId` 的 `turn.complete` 到了划掉（TaskStop 停掉也会来）。
- **`/clear`** 换 `sessionId` 但不再触发 `session.start`：在 `session.end` 清掉正在跑的回合和后台 agent，写文件时按当时的 `$.session.id()` 取名。
- `/reload-plugins` 会再触发 `session.start`（<https://code.claude.com/docs/en/plugins/mods/create>）。
- 组织管理的机器上内置守卫 `cc-plugin-sec-default` 会跳过部分事件，不含 `turn.*`、`agent.spawn`、`session.*`（<https://code.claude.com/docs/en/plugins/mods/admin>）。

### 回合文件

每个主回合结束时整份覆盖写。`$.fs.write` 不是原子写：读到半份按解不开处理，等下一次。

```json
{
  "sessionId": "1f324308-f720-447d-ac63-0c87bf340888",
  "ended": { "turnId": "7b7f23e6-5bb8-453f-be40-ed55b22236df", "reason": "answer", "lastStop": "end_turn", "backgroundAgents": 0, "at": 1793349294486 }
}
```

`lastStop` 一步都没走完是 `null`；`at` 是 epoch 毫秒。进程退出时 App 删掉它的回合文件；启动时删掉 7 天没写过的。

### 安装和卸载（用户定）

设置页一个开关，App 跑 `claude` 命令，不手改配置文件：

1. **装**：把 App 带的 `ClaudeMod/` 拷到 `~/Library/Application Support/Notchkeeper/ClaudeMod/`，跑 `claude plugin install notchkeeper --marketplace <该目录> --json`。Claude Code 写 `extraKnownMarketplaces` 和 `enabledPlugins`；本地目录 marketplace 的插件原地加载（<https://code.claude.com/docs/en/plugins/loading#in-place-and-copied-plugins>）。
2. **卸**：`claude plugin marketplace remove notchkeeper`（连带去掉 `enabledPlugins`），再删目录。会留下空的 `"extraKnownMarketplaces": {}`，无害。
3. **更新**：App 启动时目录在就整体换成新的；原地加载，下个会话生效，不用改版本号。开着的会话要 `/reload-plugins` 或重开。
4. `claude` 只在 `~/.local/bin`、`/opt/homebrew/bin`、`/usr/local/bin` 找，不读 shell 配置；带 `DISABLE_AUTOUPDATER=1`（否则子进程占着输出管道），60 秒超时 SIGKILL。

## 跳转到 Ghostty（用户定）

点会话行或卡片（× 以外），切到这个会话所在的 Ghostty 窗口、标签和分屏。

- Ghostty 的 AppleScript（1.3 起）：`terminal` 有 `id`、`working directory`、`name`（标题），`focus` 拉到前面；**没有 tty、pid**。第一次用系统会问权限（`NSAppleEventsUsageDescription`）。
- **认窗口靠 tty 标记**（照 [kovoor/claude-code-notifier](https://github.com/kovoor/claude-code-notifier)，改用 AppleScript 查标题）：
  1. `sysctl(KERN_PROC_PID)` 查会话的控制终端和父进程链。不用 `proc_pidinfo`：Ghostty 的直接子进程是 setuid root 的 `login`，读它会 EPERM。
  2. 往 tty 非阻塞写一次 OSC 2，标题设成 `notchkeeper-<UUID>`。
  3. AppleScript 找标题等于它的 terminal，最多等 1 秒。
  4. 把原标题（第 3 步前读的，去掉控制字符）写回去。必须写回：Claude Code 只在标题变了时才重写。
  - 只在 claude 直接跑在 Ghostty 终端里时写（父进程链到得了 Ghostty，且 `login` 和 claude 同一个 tty）。tmux、nvim `:terminal` 会吃掉 OSC 2，写了会盖掉它们的标题。
  - 写之前按启动时刻核对进程还是这个会话：卡片存的是快照。
  - 标题可能从对话推出来：只在内存里找标记、原样写回，不显示、不进日志。
  - 已知小风险（推断）：OSC 插进一帧中间会花一帧；读到写回之间 Claude 换了状态字符，写回旧字符；Ghostty 卡 1 秒以上，标题停在标记上直到 Claude 下次改。
- **退路**：没写标记或没等到，按 `working directory` 等于 `cwd` 找，唯一才算；还认不出就只把 Ghostty 拉到前面。会话不在 Ghostty 里也只打开 Ghostty，不报错。
- Apple Event 只在点击时发，在专用队列上，每个 `with timeout` 3 秒，不挡主线程。terminal id 拼进脚本前按 UUID 校验。

## 提醒

| 事件 | 卡片 | 声音 |
|---|---|---|
| 回合做完（后台 agent 都完成了） | 完成卡 | `Glass` |
| 回合出错 | 出错卡 | `Funk` |
| 回合被取消、进入工作中 | 无 | 无 |
| 进入需要你介入 | 介入卡（自动收回，用户定） | `Ping` |
| 不再需要你介入 | 撤掉这个会话的介入卡（`docs/ui.md`「卡片」2） | 无 |

卡片怎么排队、和红卡怎么让见 `docs/ui.md`「卡片」。只用系统音效（`NSSound(named:)`），总开关 `soundEnabled`。出口 violated 响 `Basso`，防火墙守住时不响（`docs/firewall.md`）。

## 实测（Claude Code 2.1.296）

方法：tmux 里起交互式 `claude`、跑 `claude -p`、派子 agent，每 0.1s 记元数据字段；再 `strings` 查二进制里写文件的代码。升级 Claude Code 后按这里重测。

1. **`kind` 不分 `-p`**：取自 `CLAUDE_CODE_SESSION_KIND`，没设就是 `interactive`。`claude -p` 也写文件，`entrypoint: sdk-cli`，退出时删文件。`entrypoint` 见过：`cli`、`sdk-cli`、`sdk-ts`、`sdk-py`、`claude-vscode`、`claude-desktop`、`claude-in-teams`、`local-agent`、`remote`、`ssh-remote`、`bench`。
2. **子 agent 不单独写文件。**
3. **`waitingFor` 六个取值**：`permission prompt`（未配置的对话框也默认归它）、`sandbox request`、`worker request`、`goal proposal`、`input needed`（AskUserQuestion、MCP 输入）、`dialog open`（模型回退、设置确认等）。Claude Code 归类：前四个 → permission，`input needed` → question，`dialog open` 不归类。批准框按 Esc 直接 `idle`。
4. **`kill -9` 后文件留下**，停在死前状态；Claude Code 下次列会话才删。正常退出删 `.json` 和 `.key`。
5. 其他：
   - 时间字段是 epoch 毫秒；新会话先写 `idle`；第一次写没有 `status`、`statusUpdatedAt`，之后原地补。
   - `procStart` 是 `LC_ALL=C TZ=UTC ps -o lstart= -p <pid>` 的输出，如 `Thu Oct 29 17:54:44 2026`（日期个位数前补空格）。
   - 工作区没信任时只有 `.key` 没有 `.json`。
   - 状态变化**原地重写**（inode、目录 mtime 都不变）：每份文件要单独监听。
   - `<pid>.<hex>.key`（600）是对等通信凭据，不读。
6. **`shell`**：二进制里是 `status === "idle" && 有后台 shell ? "shell" : status`，是空闲的一种。
7. **sessions 文件分不出回合怎么结束**：API 出错、Esc、拒绝批准都只变 `idle`；回合结束时还有后台 agent 则一直 `busy`，后台 agent 完成、送进通知那一刻闪 `idle`；排队消息开始时也闪 `idle`。
8. **mod 事件**（`claude --plugin-dir <临时 mod>`）：
   - 正常回答：`reason: "answer"`，最后一步 `end_turn`。
   - 生成中 Esc：`reason: "aborted"`。
   - 批准框 Esc：`reason: "answer"`，最后一步 `tool_use`，工具结果 `isError: true`。
   - `ANTHROPIC_BASE_URL` 指向不存在的端口：`reason: "error"`。
   - 后台子 agent：`agent.spawn` 带 `background`；主回合 `turn.complete` 先到，子 agent 的带 `agentId`，接着一个通知主回合开始、结束。`turn.start` 只在主回合触发。TaskStop 停掉同样来带 `agentId` 的 `turn.complete`。
9. **装上 mod 端到端**：正常回答 → 做完；Esc → 无；拒绝批准 → 只有介入卡和介入结束；后台 agent → 只在最后弹一次；坏 `ANTHROPIC_BASE_URL` → 出错卡。
