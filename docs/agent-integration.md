# agent 状态：从哪读、什么时候提醒

Notchkeeper 只关心 Claude Code 的三件事：**工作中、已停止、需要你介入**，外加**回合怎么结束的**：做完、出错，还是被你取消。只接 Claude Code（用户 10-29）：Grok Bot 的对话在服务器上，本机只有 `desktop-status.json`（pid、是否登录）和 `~/.grokbot/local-exec-daemon.json`（`inflightCount`），分不出会话和状态；Grok CLI（`~/.grok/active_sessions.json`）也不接。本文定从哪读、怎么判、什么时候响声音。判定由 `AgentCore` 负责，配固定测试；读文件、监听目录、查进程在 App 外层。

## 两个来源（用户 10-30）

| 来源 | 谁写 | 管什么 |
|---|---|---|
| `~/.claude/sessions/<pid>.json` | Claude Code 自己 | 有哪些会话、此刻忙不忙、要不要你介入、进程在不在、`sessionId` |
| `~/Library/Application Support/Notchkeeper/turns/<sessionId>.json` | Notchkeeper 自带的 Claude Code mod（见「Notchkeeper mod」） | 最近一次结束的主回合：为什么结束、结束时还剩几个后台 agent、什么时候结束的 |

两边按 `sessionId` 对上。**回合结束只看 mod**；sessions 文件只管此刻的状态。

为什么要 mod（10-30 对了一天的 App 日志和会话转录，见「实测」7）：sessions 文件只有 `busy` / `idle` / `waiting`，回合因为 API 出错、你按 Esc、你在批准框拒绝而停下，都只是变成 `idle`；后台 agent 完成、排队的消息开始执行时，状态还会闪一下 `idle`。只看它分不出这些，完成卡会乱弹。

- 不用 settings.json 的 hooks（用户 10-29 起就不要）：每个事件起一个进程，`Stop` 在 Esc 打断时不触发，要拼 `Stop`、`StopFailure`、`SubagentStop` 好几个。
- 用官方的 mod（用户 10-30 定）：进程内的 JS 模块，`turn.complete` 直接带结束原因。代价：要装（在 `~/.claude/settings.json` 的 `enabledPlugins` 加一项，App 设置页一键装、卸）；mod 的 API 随 Claude Code 版本变化，升级后要重测。<https://code.claude.com/docs/en/plugins/mods/overview>
- 没装 mod、或某个会话里 mod 没加载（工作区没信任、`--bare`、`--safe-mode`、组织策略拦了）：这个会话照常显示忙闲和介入，**不弹完成卡、出错卡**，不退回按 `idle` 猜。
- **sessions 文件、mod 文件都不做兼容**（用户 10-29）：格式变了就直接改代码，不做多版本兼容。解析不了的照 CLAUDE.md 准则 5 计数、跳过、不崩。
- 官方从外部读会话状态的受支持方式是 `claude agents --json`（<https://code.claude.com/docs/en/agent-view>），和 sessions 文件一样粗，而且每次调用要 0.4s，不用。

### sessions 文件只取这些字段

| 字段 | 用来做什么 |
|---|---|
| `pid` | 进程还在不在、进程退出通知 |
| `procStart` | 和 `pid` 一起认进程，防 pid 复用 |
| `sessionId` | 和 mod 写的回合文件对上。会拼进要删的文件路径，不是 UUID 的整份文件按解不开处理 |
| `kind`、`entrypoint` | 只看 `kind: interactive` 并且 `entrypoint: cli` 的会话，也就是终端里开的 `claude`；`claude -p`（`sdk-cli`）、SDK、VS Code、Desktop 等都不算（用户 10-29，依据见「实测」1） |
| `status` | 三个状态；还没有这个字段的是刚起来的会话，先不看（「实测」5） |
| `waitingFor` | 需要你介入时，区分等你回答和等你批准 |
| `statusUpdatedAt` | 这个状态从什么时候开始 |
| `cwd` | 面板会话行显示完整路径（用户 10-29，`docs/ui.md`「面板布局」）；跳转 Ghostty 时找窗口 |
| `name` | **只用来在 Ghostty 里认窗口**（用户 10-30，见「跳转到 Ghostty」）：只在内存里和窗口标题比对，不显示、不进日志 |

`name` 可能是从对话推出来的（自动起名写 `derived`；不带参数的 `/rename` 也拿对话让模型起名，同样写 `user`，10-29 实测）。所以它算对话内容，除了认窗口不做别的用（CLAUDE.md「只读元数据，不读对话内容」的例外，用户 10-30）。其余字段不读。

## 状态

| `status` | 状态 | 造型（`docs/mascot.md` §2） |
|---|---|---|
| `busy` | 工作中 | working；干了很久（见下）变 longTurn |
| `idle`、`shell` | 已停止 | — |
| `waiting` | 需要你介入 | 照 Claude Code 自己的归类表（「实测」3）：`permission prompt`、`sandbox request`、`worker request`、`goal proposal` → approval；`input needed`、`dialog open` 和没见过的取值 → question（用户 10-29） |

- `shell` 是「空闲，但后台挂着 shell 命令」（例如 dev server）：二进制里是 `status === "idle" && 有后台 shell ? "shell" : status`（2.1.296，10-30 查）。10-29 版当成工作中，挂着 dev server 的会话就一直「工作中」、回合永远不结束（10-30 实测：一个会话一天结束了 15 个回合，一次没提醒）。
- 主回合结束、但后台 agent 还在跑时，`status` 一直是 `busy`（10-30 实测），显示工作中。
- **回合**（turn）：Claude 回应一条消息（你发的、或后台 agent 完成后自动送进来的通知）的全过程，由 mod 的 `turn.start` / `turn.complete` 界定。子 agent 的回合不算（`turn.complete` 带 `agentId`）。
- **回合结束**（turn end）怎么判，见「回合怎么结束的」。
- **干了很久**：处于工作中，并且离进入工作中满 10 分钟（中间等你的时间也算进去）。这一条只看 sessions 文件：从已停止进入工作中算起，回到已停止清零。
- **中途接手**（App 启动时、或第一次看到某个文件时，它已经在工作中或需要你介入）：以文件里的 `statusUpdatedAt` 作为工作开始。已经在需要你介入的，不补弹介入卡、不补响 `Ping`；回合文件里 App 开始看之前就结束的回合（比 `at`），不补弹完成卡：卡片只跟着事件走（`docs/ui.md`「卡片」），靠盾盾造型提示。App 开始看之后才结束的，第一次看到也照常提醒（新会话、`/clear` 之后的第一个回合）。

### 回合怎么结束的

mod 每个主回合结束时写下 `reason`、最后一步的 `stopReason` 和那一刻还在跑的后台 agent 数，AgentCore 按下表定结局（outcome）。回合文件里结束的回合换了一个（`turnId` 变了）就算一次回合结束：

| `reason` | 最后一步 `stopReason` | 结局 | 提醒 |
|---|---|---|---|
| `answer` | 不是 `tool_use` | 做完（done） | 结束时后台 agent 数为 0：完成卡 + `Glass`；还有后台 agent 在跑：不提醒，等它们完成后送进来的那个回合结束再提醒 |
| `answer` | `tool_use` | 取消（canceled）：你在批准框拒绝，回合停在工具调用上（10-30 实测，`reason` 照样是 `answer`） | 无 |
| `aborted` | — | 取消：你按 Esc 打断 | 无 |
| `error` | — | 出错（failed）：API 出错、重试用完、超出上下文 | 出错卡 + `Funk`，不管后台 agent |
| `refusal` | — | 出错：模型拒答、又没有备用模型 | 同上 |

- `reason` 的四个取值出自 Claude Code 生成的类型定义 `TurnCompleteReason`（2.1.296）；正常的回答最后一步一定是 `end_turn`（或 `max_tokens`、`stop_sequence`），停在 `tool_use` 说明工具结果之后没有再请求模型。
- 排队的消息：上一回合结束、下一回合紧接着开始，上一回合照常提醒（Claude 确实答完了那一条）。下一回合开始时 mod 不动回合文件，所以 App 晚一点读也看得到。
- 两次读之间同一个会话结束了两个回合，只看得到后一个（推断，未实测）。
- 回合文件比 sessions 文件先到（`/clear` 后 sessions 文件还没换成新的 `sessionId`）：先不记，下次重读时会话对上了再算。
- `/clear` 换掉的旧 `sessionId` 读过的记录留着：同一次运行里 `claude --resume <旧 id>` 回来时旧回合文件还在，靠它认出读过了，不补弹。
- 两个终端同时 `--resume` 同一个会话（两个进程一个 `sessionId`）：提醒挂到哪个进程上不固定，其中一个退出就删掉共用的回合文件（少见，不处理）。

### 进程没了

- 用 `proc_pidinfo` 的 `PROC_PIDTBSDINFO` 查进程启动时刻：查不到（进程不在，或判不出来），或者和 `procStart` 对不上（pid 被复用），会话都算没了，从列表里去掉，不算「已停止」，不提醒，不进造型优先级。
- `kill -9` 后文件留着、目录不变（「实测」4），所以每个会话的 pid 挂一个进程退出通知（`DispatchSource.makeProcessSource(identifier:eventMask: .exit)`，即 kqueue `EVFILT_PROC` / `NOTE_EXIT`），进程一退出就去掉，不轮询（用户 10-29）。
- `procStart` 在边界解析成时刻（UTC、精确到秒）再比。解析不了的文件照准则 5 计数、跳过，上一次读到的状态留着。

## Notchkeeper mod

mod 是 Claude Code 官方的插件形式（2.1.287 起默认开启）：插件里的一个 JS 模块，Claude Code 在事件发生时调用它。<https://code.claude.com/docs/en/plugins/mods/overview>

- **源码**：`ClaudeMod/`（一个本地 marketplace：`.claude-plugin/marketplace.json` + `plugins/notchkeeper/`），测试用 `claude plugin test` 离线跑。
- **只报事实，不做判定**：结局怎么算归 AgentCore（上表）。mod 只记 `turnId`、`reason`、最后一步的 `stopReason`、结束时的后台 agent 数和结束时刻。
- **只在主回合结束时写**：子 agent 的回合、回合开始都不写。
- **只写元数据**：mod 看得到提示词、回答、工具参数，一律不写出去。
- **只在交互式会话写**：`session.start` 的 `isInteractive` 为 false（`claude -p`、SDK）不写。
- **后台 agent 怎么数**：`agent.spawn` 时 `background` 为 true 的，记下 `next(e)` 返回的 `agentId`；带这个 `agentId` 的 `turn.complete` 到了就划掉（被 TaskStop 停掉时也会来，10-30 实测）。
- **`/clear`**：会话换一个 `sessionId`，不再触发 `session.start`（类型定义 `SessionEndInput`）；mod 在 `session.end` 清掉正在跑的回合和后台 agent，每次写文件都按当时的 `$.session.id()` 取文件名。
- `session.start` 在 mod 重新加载时也会再触发（<https://code.claude.com/docs/en/plugins/mods/create>），所以开着的会话 `/reload-plugins` 后也会写。
- 内置守卫 `cc-plugin-sec-default` 在组织管理的机器、Team / Enterprise 登录下会跳过用户 mod 的部分事件，不含 `turn.*`、`agent.spawn`、`session.*`（<https://code.claude.com/docs/en/plugins/mods/admin>）。

### 回合文件

`~/Library/Application Support/Notchkeeper/turns/<sessionId>.json`，mod 每个主回合结束时整份覆盖写（`$.fs.write` 会建好上级目录，但不是原子写；读到写了一半的文件按解不开处理，等下一次写）。

```json
{
  "sessionId": "1f324308-f720-447d-ac63-0c87bf340888",
  "ended": {
    "turnId": "7b7f23e6-5bb8-453f-be40-ed55b22236df",
    "reason": "answer",
    "lastStop": "end_turn",
    "backgroundAgents": 0,
    "at": 1793349294486
  }
}
```

- `lastStop`：这一回合主 agent 最后一步的 `stopReason`；一步都没走完是 `null`。
- `backgroundAgents`：回合结束那一刻还在跑的后台 agent。
- `at`：回合结束的时刻，epoch 毫秒（mod 的 `$.clock.now()`）。
- 清理：App 收到进程退出通知时删掉这个会话的回合文件；App 启动时删掉 7 天没写过的（`/clear` 留下的、App 没开时退出的会话留下的；还活着的会话下一个回合结束会重写，删了也不丢提醒）。

### 安装和卸载（用户 10-30）

设置页一个开关，App 替你跑 `claude` 命令，不手改任何配置文件：

1. **装**：把 App 里带的 `ClaudeMod/` 拷到 `~/Library/Application Support/Notchkeeper/ClaudeMod/`，再跑 `claude plugin install notchkeeper --marketplace <这个目录> --json`（`--marketplace` 时插件只写名字）。Claude Code 把 marketplace 记进 `~/.claude/settings.json` 的 `extraKnownMarketplaces`，把 `notchkeeper@notchkeeper` 记进 `enabledPlugins`（用户级）。本地目录 marketplace 里按相对路径列的插件**原地加载**，不拷进缓存（<https://code.claude.com/docs/en/plugins/loading#in-place-and-copied-plugins>）。
2. **卸**：跑 `claude plugin marketplace remove notchkeeper`（连带卸掉插件、去掉 `enabledPlugins` 那一项），再删掉上面那个目录。
3. **更新**：App 启动时，装着的话（目录在）就把 App 里带的 `ClaudeMod/` 拷到临时目录再整体换上去；原地加载的插件下一个会话就用新文件，不用改版本号。
4. 已经开着的会话要 `/reload-plugins` 或重开才加载，设置页写明。
5. 装没装看 `claude plugin list --json`；找 `claude` 只看固定的几个位置（`~/.local/bin/claude`、`/opt/homebrew/bin/claude`、`/usr/local/bin/claude`），不读 shell 配置。找不到就提示，不装。
6. 跑 `claude` 时带 `DISABLE_AUTOUPDATER=1`（不让它起会占着输出管道的子进程），60 秒没跑完就 SIGKILL 并报超时。
7. 10-30 实测：装上后 `settings.json` 多 `enabledPlugins` 一项和 `extraKnownMarketplaces.notchkeeper`（`source: directory`）；卸载后这两项去掉，但 Claude Code 留下一个空的 `"extraKnownMarketplaces": {}`。

## 跳转到 Ghostty（用户 10-30）

点面板里的会话行、或点卡片（× 以外的地方），打开 Ghostty 并切到这个会话所在的窗口、标签和分屏。

- 用 Ghostty 的 AppleScript（1.3 起，`Ghostty.sdef`）：`terminal` 有 `working directory` 和 `name`（标题），`focus` 命令把它所在的窗口拉到前面。第一次用时系统会问一次「允许 Notchkeeper 控制 Ghostty」（Info.plist 写 `NSAppleEventsUsageDescription`）。
- 认窗口：先按 `working directory` 等于会话的 `cwd` 找；只有一个就是它。同一个目录开了好几个时，再拿会话的 `name` 和标题比（Claude Code 把会话名写进标题，前面带一个状态字符，如 `✳ `、`◐ `）。还是认不出来就只把 Ghostty 拉到前面。
- Ghostty 没开、或者会话不在 Ghostty 里：只打开 Ghostty，不报错。
- 只在用户点击时发 Apple Event，不轮询；Apple Event 都在一条专用队列上发，每个最多等 3 秒（`with timeout`），第一次问权限、Ghostty 卡住时都不挡刘海的主线程。
- Ghostty 给的 terminal id 拼进脚本前按 UUID 校验，拼原样的字符串。

## 提醒

| 事件 | 卡片 | 声音 |
|---|---|---|
| 回合做完（后台 agent 都完成了） | 完成卡，按设置自动收回 | `Glass` |
| 回合出错 | 出错卡，按设置自动收回 | `Funk` |
| 回合被你取消 | 无 | 无 |
| 进入需要你介入 | 介入卡，按设置自动收回（用户 10-29），也可以手动关 | `Ping` |
| 不再需要你介入：回到工作中、变成已停止、进程没了 | 撤掉这个会话的介入卡（排着的、正在放的都撤，`docs/ui.md`「卡片」2） | 无 |
| 进入工作中 | 无 | 无：是你自己开的头 |

- 卡片什么时候放、和红卡怎么让，见 `docs/ui.md`「卡片」：所有临时卡排一个队，声音在卡放出来时才响。
- 声音只用系统音效（`NSSound(named:)`），不用别家的音效。设置里沿用一个「提示音」总开关（`config.json` 的 `soundEnabled`）。
- 出口 violated 响 `Basso`；防火墙守住时不响（`docs/egress-guard.md`、`docs/firewall.md`）。
- 用户 10-29 定，10-30 加出错卡、去掉取消的提醒。

## 实测（10-29、10-30，Claude Code 2.1.296）

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
7. **sessions 文件分不出回合怎么结束**（10-30，对 App 日志和会话转录逐条对时间）：API 出错（转录里 `isApiErrorMessage`）、按 Esc、在批准框拒绝，都只是变成 `idle`；主回合结束时还有后台 agent（转录 `turn_duration` 的 `pendingBackgroundAgentCount: 1`）状态一直是 `busy`，后台 agent 完成、送进通知回合的那一刻闪一下 `idle`；排队的消息开始执行时也闪一下 `idle`。10-29 版把这些都当成回合结束弹完成卡。
8. **mod 事件**（10-30，tmux 里起交互式 `claude --plugin-dir <临时 mod>`，mod 只记事件名和元数据）：
   - 正常回答：`turn.complete` 的 `reason: "answer"`，最后一步 `stopReason: "end_turn"`。
   - 生成中按 Esc：`reason: "aborted"`、`isAborted: true`。
   - 在批准框按 Esc 拒绝：`reason: "answer"`，最后一步 `stopReason: "tool_use"`，工具调用的结果 `isError: true`。
   - `ANTHROPIC_BASE_URL` 指向不存在的端口（连接被拒）：`reason: "error"`。
   - 后台子 agent：`agent.spawn` 带 `background`；主回合的 `turn.complete` 先到，子 agent 的 `turn.complete` 带 `agentId`，紧接着一个新的主回合（通知）开始、结束。`turn.start` 只在主回合触发。
   - 后台子 agent 被 TaskStop 停掉：同样来一个带它 `agentId` 的 `turn.complete`。
9. **装上 mod 后端到端**（10-30，tmux 里的 `claude`，看 App 日志）：正常回答 → 回合做完；Esc → 无；在批准框拒绝 → 只有介入卡和介入结束；后台 agent → 只在最后弹一次；`ANTHROPIC_BASE_URL` 指向不存在的端口 → 回合出错，出错卡实机截图看过。
