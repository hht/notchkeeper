# egress-guard killswitch 接入 Notchkeeper：可行性与设计

状态：评估稿，只写文档，不改代码、不装任何东西（Jason，2026-10-28）。
评估对象：VPS管理员 的 `~/.guardian-check/pf/egress-guard.sh` v3（已过 Vera 两轮审）；回滚状态按 VPS管理员 后续的 v4 拆分对齐。

## 结论

**可行，而且不需要开发者账号。** 但不走 SMAppService + XPC，改走更简单的路：

1. 脚本和一个普通 LaunchDaemon 由 Haitao 输一次管理员密码装好（root 所有）。之后开机、定时重新加载规则全归 LaunchDaemon，Notchkeeper 不常驻任何特权代码。
2. Notchkeeper **读状态不需要权限**：只看几个文件存不存在（见「状态怎么读」）。
3. Notchkeeper **开、关都弹系统管理员密码框**（`osascript … with administrator privileges` 调已装好的 `/usr/local/sbin/egress-guard apply|off`）。唯一不要密码的动作是「确认保留」，它只会让防护更强。
4. 采纳 killswitch 后，**乙（Anthropic 网段窄规则）不再做**；甲（杀进程）只在 killswitch 没生效时兜底。

一句话原则：**加强防护的动作可以不要密码，减弱防护的动作必须要密码。** Claude Code 以 ava 身份运行，任何 ava 能写的开关，Claude 都能拿来关掉防护。

## 1. 特权方案

### 为什么不走 SMAppService + XPC

- `SMAppService.daemon` 要求 App 有稳定的代码签名。临时签名（ad-hoc）每次构建 cdhash 都变，系统的后台项目审批会失效或要重新批准，实际体验不可靠。
- XPC 服务端的意义在于校验调用方的签名要求（Team ID）。没有 Team ID，只能校验 cdhash，每次构建都会变，等于不校验；放宽了就是任何 ava 进程都能让 root 执行命令。
- 将来买了开发者账号，可以迁到 SMAppService + XPC，但现在不值得。

### 为什么不用「LaunchDaemon 监听 ava 可写的命令文件 / socket」

能做，但只能放行加强防护的命令。如果允许通过它执行 `off` 或 `resume`，Claude Code（ava 身份）自己就能写文件关掉防护。`apply` 也不能放行：手动 `apply` 会清掉暂停标记，并启动 5 分钟不确认就自动关闭的计时，ava 进程发起 `apply` 然后不确认，结果就是防护被关掉。所以这个通道最多只剩 `confirm`，而脚本已经用 `confirm` 文件做到了。结论：不加新通道。

### 定时重新加载归谁

归 LaunchDaemon 调脚本：开机调 `apply --boot`，之后每 60 秒调 `apply --interval`（两者的区别见下一节）。理由：系统事件（例如开关「互联网共享」）可能重载 pf 规则；这件事和 Notchkeeper 开没开、崩没崩无关。两种调用遇到暂停标记都直接退出，和 UI 的开关语义一致。

### 自动回滚和故意关闭是两种状态（Vera 必须改 ①）

现行 v3 的自动回滚直接调 `off`，会写持久的暂停标记，等于把「忘了点保留」当成「Haitao 故意关掉」，重启后也不再开。两者要分开：

| | 故意关闭 `off` | 自动回滚（测试模式没确认） |
|---|---|---|
| 标记 | `/var/db/egressguard.paused`（持久） | `/var/run/egressguard/rollback`（瞬态，重启即清） |
| 每 60 秒的定时重装 | 不重装 | 不重装 |
| 开机 RunAtLoad | 不重装 | **重装**（不认这个标记） |
| 过期 | 不过期，只有 `apply` / `resume` 清除 | 1800 秒后过期，定时重装恢复（与 VPS管理员 v4 一致） |

VPS管理员 的 v4 已按下面拆分；本文不动脚本：
- 自动回滚调新的内部动作（例如 `rollback`）：卸规则、释放 token、写瞬态标记，**不写**暂停标记。
- LaunchDaemon 区分两种调用：RunAtLoad 调 `apply --boot`（只认暂停标记），StartInterval 调 `apply --interval`（认暂停标记，也认未过期的回滚标记）。launchd 本身不区分这两种触发，需要用两个 plist，或者由脚本根据系统开机时间判断，具体由 VPS管理员 定。
- 手动 `apply` 同时清掉两种标记。
- App 的状态表多一种：**已自动回滚**（标记存在、未过期），文案是「上次没点保留，已自动关闭；重启或 30 分钟后自动恢复」，旁边放一个「重新打开」按钮（要密码）。

## 2. 状态怎么读（不要 root）

脚本的状态目录是 `711`，ava 不能列目录，但可以检查已知文件名是否存在：

| 文件 | 含义 | ava 可读 |
|---|---|---|
| `/usr/local/sbin/egress-guard` 存在且 root 所有 | 已安装 | 是 |
| `/var/db/egressguard.paused` | 已暂停（关） | 是（644） |
| `/var/run/egressguard/token` 存在 | 规则已加载、pf 已启用 | 只能判断存在（600） |
| `/var/run/egressguard/nonce` 存在 | 测试模式中，等确认 | 是（644），倒计时起点用它的修改时间 |
| `/var/run/egressguard/rollback` 存在 | 测试模式没确认、已自动回滚 | 需要 644，过期时间从内容或修改时间算 |

合起来是六种状态：**未安装 / 已暂停 / 已自动回滚 / 测试中（剩 m:ss）/ 已开启 / 异常**（例如既没暂停也没 token：LaunchDaemon 没在跑）。
判定写成 GuardCore 里的纯函数（输入：上面五个布尔值、nonce 修改时间、当前时间），测试先行；读文件放在 GuardProbes。

## 3. UI（请 Emily 定位置和样式）

- 设置页加一组「断网保护」：一个开关，加一行状态文字。建议放在守卫相关的那一页，位置请 @Emily 定。
- **打开**：弹系统密码框 → 执行 `apply` → 状态变「测试中」，刘海展开面板显示「网络正常的话，请在 m:ss 内点『保留』；忘了点会自动关闭防护」，带一个「保留」按钮。按钮以 ava 身份写确认文件，不要密码。没点就由脚本自动回滚（见上文，瞬态，不是暂停）。UI 倒计时比脚本的 300 秒少显示 15 秒，留出写文件和时钟误差的余量；最后 15 秒按钮仍然可点。注意：这个计时只防「规则把本机网络整个弄断」，不是安全开关，忘了点的代价是防护被关掉。
- **关闭**：弹系统密码框 → 执行 `off`（同时写暂停标记，重启后也不会自己开）。
- **未安装**：开关置灰，旁边写「需要先安装，安装前会给你看改动」。安装本身走第 5 节的流程，不在 App 里静默完成。
- **刘海**：killswitch 开着且 Clash 断了，现在本来就显示红点；展开面板的文字从「流量可能泄漏」改成「已断网保护中」。killswitch 的状态不并进 `Verdict`，单独一个信号，免得守卫判定逻辑掺进安装状态。

### Notchkeeper 崩了怎么办

规则在内核里，和 Notchkeeper 进程无关：App 崩溃、退出都不影响防护，也不会让防护失效。需要逃生时（例如 Clash 改了 TUN 网卡名，全机断网）：

1. App 里关开关（本地操作，断网也能用）。
2. 终端：`sudo /usr/local/sbin/egress-guard off`。
3. 最后手段：`sudo pfctl -a com.apple/000.egressguard -F all`，再不行 `sudo pfctl -d`（关掉整个 pf，系统自带规则也会一起停）。

**重启不是逃生办法**：LaunchDaemon 开机会重新加载，除非已经 `off`。这一点要写进 README 和设置页说明。

## 4. 和甲、乙、observe A 的关系

- **乙不再做。** 乙只拦 ava 进程去 Anthropic 网段的非 utun 流量；killswitch 拦 ava 进程的所有非 utun 流量，完全覆盖乙。两套 pf anchor 并存只会增加排错成本。删掉乙，`docs/interception.md` 和 `docs/proposals/agents-md-guard.md` 的乙相关措辞跟着改。
- **甲改成兜底。** killswitch 已开启时，路由不走 utun 也漏不出去，杀进程只会丢掉 Claude 的工作，建议只显示红卡、不杀。killswitch 未安装、已暂停或状态异常时，甲照原计划生效。这条需要 Haitao 拍板。
- **observe A 不变。** 出口 IP 不在允许列表仍只亮琥珀色；killswitch 管不了「Clash 走错节点」，这件事本来就只能提示。
- **killswitch 的已知局限**：放行所有 root 的 inet 流量（因为 mihomo 以 root 运行），root 守护进程仍能直连。对保护 Claude Code（ava 身份）没有影响。另外 TUN 网卡名写死为 `utun1024`，Clash Verge 换了网卡名就会全机断网（安全的那一边出错），状态页要能看出来。

## 5. 和签名公证、和 AGENTS.md 的冲突

- **签名、公证：不冲突。** 这个方案不用 SMAppService、XPC、entitlement，脚本和 plist 由管理员密码装进 `/usr/local/sbin` 和 `/Library/LaunchDaemons`，跟 App 怎么签名无关。本地构建本来也不需要公证。
- **AGENTS.md：冲突，必须先改硬规则。** 第 46 行「不用 pf……不改系统网络设置」与此直接冲突。Haitao 这次明确要求把它做进来，建议 Grok Bot 把 `docs/proposals/agents-md-guard.md` 里的乙例外换成：
  > 唯一允许的 pf 用法是 egress-guard：独立 anchor `com.apple/000.egressguard`，不改 `/etc/pf.conf`，不读写 Clash 配置。安装、打开、关闭都需要 Haitao 输入管理员密码；安装和任何规则改动之前先给 diff 并备份。App 不常驻特权代码。
  
  同时第 9 行「拦截」的描述也要补一句 killswitch。规则改完、Haitao 确认之前，App 侧不写这部分代码。
- 脚本当前在 `ensure_main` 里，主规则集为空时会加载 Apple 默认的 `/etc/pf.conf`（只读、不修改文件）。这会改变内核里的 pf 状态，要在 diff 说明里写明。

## 6. 落地顺序（都等 Haitao 醒来批）

1. Haitao 确认：采纳 killswitch、删乙、甲改成兜底，以及新的 AGENTS.md 措辞。
2. 脚本的来源：在 VPS管理员 的 P1–P3 实测（含重启）通过之前，以 Mac 上 `~/.guardian-check/pf/` 的版本为准。实测通过后，再把脚本搬进本仓 `Resources/egress-guard/`（连同 LaunchDaemon plist 和安装说明），以后只改这一份。
3. 安装：给 Haitao 看 diff（脚本、LaunchDaemon plist、以及权限；不含 sudoers，见第 6.5 节）→ 他输密码安装 → `status` 验证。
4. App：先做纯函数（状态判定）和测试，再做 GuardProbes 读文件，再做设置页开关和刘海文案（Emily 定样式，S1m0nE 做 UI）。
5. 每块照旧先给 Vera 审，再请 Haitao 批提交。

## 6.5 sudo 缓存：Haitao 已定，不做全局设置

**结论（Haitao 拍板）：** sudo 全部照旧，不加任何 sudoers 规则（全局和只针对 egress-guard 的都不加），保留 macOS 默认的 sudo 缓存（同一个终端里 5 分钟内免密）。

**剩下的风险：** Haitao 在某个终端里 `sudo` 过之后 5 分钟内，同一终端里的进程（包括在里面跑的 Claude Code）可以不输密码执行任意 sudo，比如 `sudo pfctl -d`、删掉 anchor、卸载 LaunchDaemon，这样 killswitch 就被关掉了。「减弱防护必须当场输密码」这个前提，在这段窗口里不成立。
- macOS 的缓存默认按终端（tty）分开计。Claude Code 起的子进程能不能用上那个终端的缓存，没有实测；Haitao 接受这项风险，不做 `claude` 启动包装，也不做实测。
- 检测上也有缺口：App 只看状态文件，`pfctl -d` 不会改那些文件，所以 pf 被关掉时 App 现在看不出来。以后可以让 guardd 每轮只读地查一下 anchor 是否还在（不需要 root 的办法待查），这件事单独排期。

**推荐习惯：**
1. 不在跑 Claude Code 的终端里用 sudo。要 sudo 就新开一个终端窗口（新窗口就是新的 tty，缓存不共用），用完关掉。
2. 用完 sudo 顺手执行 `sudo -k`，立刻作废这个终端的缓存。
3. Claude Code 弹出的权限确认里，只要命令带 `sudo`、`pfctl`、`launchctl` 或 `egress-guard off`，一律拒绝。
4. Notchkeeper 自己不用 sudo：开关走 `osascript … with administrator privileges`，每次都弹系统密码框，不受这个缓存影响。

**「只对 egress-guard 设 timestamp_timeout=0」：不采用（Haitao 已定）。**
- 它只能堵住一条路：借缓存执行 `sudo egress-guard off`。`sudo pfctl -d`、删 anchor、`launchctl bootout` 这些照样免密，防护还是会被绕过。
- Notchkeeper 本来就不走 sudo，这条规则对 App 没有作用。
- 代价是安装 diff 里多一个 sudoers 文件，Haitao 要多审一份系统配置；而且容易让人以为 sudo 缓存问题已经解决了。
- 不采用，仅留作记录：写法是 `Defaults!/usr/local/sbin/egress-guard timestamp_timeout=0`（`/etc/sudoers.d/egressguard`）。安装 diff 里不包含任何 sudoers 改动。

## 7. 待 VPS管理员 确认的两点

- 已有的「测试中」计时是 `nohup bash -c "sleep …"`。如果由 `osascript … with administrator privileges` 调用，要实测这个后台进程能不能活过 osascript 返回（stdout/stderr 已重定向，应该可以）。
- `sudo` 的凭据缓存：见第 6.5 节。
