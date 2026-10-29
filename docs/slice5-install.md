# Slice 5：把 guardd 装成登录后常驻（Jason 2026-10-28）

**状态：已安装（2026-10-28 20:02，Haitao 批准，提交 `4ba3998`）。** guardd 作为 `gui/501` 的 LaunchAgent 在跑。安装前跑过 `--dry-run`、`bash -n`、`plutil -lint` 和 shellcheck 0.11（0 条）。

**不需要管理员密码。** guardd 是每用户 LaunchAgent，不是 LaunchDaemon：安装就是 Haitao 在自己登录的终端里跑 `bash scripts/install-guardd.sh`，不弹密码框、不用 sudo / osascript 提权；两个脚本以 root 运行都会拒绝。

相关文件：

- `Resources/guardd/com.notchkeeper.guardd.plist`：LaunchAgent 模板，二进制路径和日志路径是占位符，由安装脚本换成绝对路径（launchd 不展开 `~`）
- `scripts/install-guardd.sh [--dry-run]`
- `scripts/uninstall-guardd.sh [--dry-run] [--purge]`
- `Tests/guarddTests/LaunchAgentTests.swift`：钉住模板的键，并在临时 HOME 里跑两个脚本的 `--dry-run`。PATH 最前面放了会记账的假 `launchctl` / `swift` / `sudo` / `codesign`，确认 dry-run 一个外部命令都没调、一个文件都没写；旧 plist、旧二进制都先备份再覆盖；输出里不出现 sudo / osascript / pfctl / anchor / networksetup / scutil / route / .zshrc / LaunchDaemons / config.json / Clash

## 1. 会在 Haitao 的 Mac 上改什么

只动 ava 自己的目录，不要 root、不用 sudo；两个脚本以 root 运行都会直接拒绝。

| 路径 | 做什么 |
|---|---|
| `~/Library/Application Support/Notchkeeper/bin/guardd` | 新建：release 版 guardd（先写 `guardd.new`，再 `mv` 换上） |
| `~/Library/LaunchAgents/com.notchkeeper.guardd.plist` | 新建，0644；已经有同名文件就先备份 |
| `~/Library/Application Support/Notchkeeper/backup/com.notchkeeper.guardd.plist.<时间>` | 只有已存在旧 plist 时才有：旧 plist 的备份（`cp -p`） |
| `~/Library/Application Support/Notchkeeper/backup/guardd.<时间>` | 只有已存在旧 `bin/guardd` 时才有：旧二进制的备份（`cp -p`） |
| `~/Library/Logs/Notchkeeper/guardd.log` | guardd 的 stdout / stderr，由 launchd 创建。不含 IP。同目录已有 App 的 `notchkeeper.log`，不动它 |
| `~/Library/Application Support/Notchkeeper/guard-state.json` | guardd 运行后每 5 秒写一次（0600） |
| launchd 的 `gui/501` 域 | `launchctl bootstrap` 加载 `com.notchkeeper.guardd`；以后每次登录自动启动 |

不碰：`config.json`（guardd 只读）、Clash、网络设置、pf、`~/.zshrc`、任何 LaunchDaemon。

脚本动手前先检查前提，缺一样就退出、什么都不改：必须是 macOS；plist 模板在；`swift` / `launchctl` / `plutil` 都在；渲染出的 plist 过 `plutil -lint`（读 stdin，dry-run 也查）；非 dry-run 时还要求 `gui/<uid>` 域存在（即在 Haitao 已登录的图形会话里跑，不能 ssh / sudo）；编译后 `.build/release/guardd` 必须存在。

可以重复跑：已加载就先 `bootout`，等它从 `gui/<uid>` 域里消失（最多 10 秒，超时就中止、不换文件），再换二进制和 plist、重新 `bootstrap`。紧接着 bootout 就 bootstrap 会报 `5: Input/output error`，所以要等。

文件归属：全部由 Haitao 本人（ava:staff）创建。`guard-state.json` 由 guardd 用 `O_CREAT|O_EXCL` 以 0600 新建临时文件再 `rename`（`Sources/guardd/StateFile.swift`，`StateFileTests.writesOwnerOnly` 钉住）；`guardd.log` 由 launchd 以登录用户身份创建，按 umask 一般是 0644，内容不含 IP（`RoundTests.summaryAndVerdictLogNeverContainIPs`、`EgressIPTests` 里的反向断言）。

plist 的要点：

- `RunAtLoad`：加载时（含每次登录）就启动。
- `KeepAlive` 设成 `{SuccessfulExit: false}`：崩溃或非 0 退出才重启。guardd 收到 SIGTERM 后 exit 0，所以 `bootout` 以后不会被拉起来。
- `ThrottleInterval 10`：两次重启至少隔 10 秒，坏了也不会疯狂重启。
- 没有 `UserName`：以登录用户身份跑。

## 2. dry-run 输出（2026-10-28 在 Haitao 的 Mac 上跑的，临时副本 /tmp/nk-guardd）

`bash scripts/install-guardd.sh --dry-run`：

```
== dry-run：只打印，不改任何东西
+ swift build -c release --product guardd --package-path /tmp/nk-guardd
+ mkdir -p /Users/ava/Library/Application\ Support/Notchkeeper/bin /Users/ava/Library/Logs/Notchkeeper /Users/ava/Library/LaunchAgents
+ （如果已加载）launchctl bootout gui/501/com.notchkeeper.guardd，并等它退出（最多 10 秒）
+ cp /tmp/nk-guardd/.build/release/guardd /Users/ava/Library/Application\ Support/Notchkeeper/bin/guardd.new
+ chmod 755 /Users/ava/Library/Application\ Support/Notchkeeper/bin/guardd.new
+ mv -f /Users/ava/Library/Application\ Support/Notchkeeper/bin/guardd.new /Users/ava/Library/Application\ Support/Notchkeeper/bin/guardd
+ 写入 /Users/ava/Library/LaunchAgents/com.notchkeeper.guardd.plist（0644）：
----- plist -----
（模板原文，两个占位符换成：）
		<string>/Users/ava/Library/Application Support/Notchkeeper/bin/guardd</string>
	<string>/Users/ava/Library/Logs/Notchkeeper/guardd.log</string>   ← StandardOutPath 和 StandardErrorPath
----- end plist -----
+ launchctl bootstrap gui/501 /Users/ava/Library/LaunchAgents/com.notchkeeper.guardd.plist
== 完成后检查：launchctl print gui/501/com.notchkeeper.guardd ；tail -f "/Users/ava/Library/Logs/Notchkeeper/guardd.log"
```

当时 `~/Library/LaunchAgents` 里没有旧的 guardd plist、`bin/` 里也没有旧 guardd，所以没有备份那几步；有的话会在 `bootout` 之前多打 `+ mkdir -p …/backup` 和 `+ cp -p … backup/com.notchkeeper.guardd.plist.<时间>` / `+ cp -p … backup/guardd.<时间>`。2026-10-28 19:25 在 /tmp/nk-slice5 重跑，输出同上（路径换成 /tmp/nk-slice5）。dry-run 完整打印 plist 原文，上面为了篇幅只摘了被替换的两行。从仓库跑时，路径里的 `/tmp/nk-guardd` 换成仓库路径。

## 3. 怎么撤销

```
bash scripts/uninstall-guardd.sh --dry-run    # 先看会做什么
bash scripts/uninstall-guardd.sh              # launchctl bootout，删 plist 和 bin/guardd
bash scripts/uninstall-guardd.sh --purge      # 另外删 guardd.log 和 guard-state.json
```

`uninstall-guardd.sh --dry-run --purge` 的输出：

```
== dry-run：只打印，不改任何东西
+ （如果已加载）launchctl bootout gui/501/com.notchkeeper.guardd，并等它退出（最多 10 秒）
+ rm -f /Users/ava/Library/LaunchAgents/com.notchkeeper.guardd.plist
+ rm -f /Users/ava/Library/Application\ Support/Notchkeeper/bin/guardd
+ （如果空了）rmdir /Users/ava/Library/Application Support/Notchkeeper/bin
+ rm -f /Users/ava/Library/Logs/Notchkeeper/guardd.log
+ rm -f /Users/ava/Library/Application\ Support/Notchkeeper/guard-state.json
== 保留：安装备份（/Users/ava/Library/Application Support/Notchkeeper/backup）
```

不加 `--purge` 就没有最后两个 `rm`，日志和状态文件留着。卸载先等 guardd 真的退出（最多 10 秒，超时就中止、一个文件都不删），免得 `--purge` 删掉状态文件后最后一轮又写回来。

`backup/` 里的备份永远保留、不自动还原：里面只会是上一次安装的 plist / guardd，自动还原等于卸载时又装回旧版。要回到旧版就手动：`cp -p backup/com.notchkeeper.guardd.plist.<时间> ~/Library/LaunchAgents/com.notchkeeper.guardd.plist`、`cp -p backup/guardd.<时间> bin/guardd`，再 `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.notchkeeper.guardd.plist`。`config.json` 和 App 的 `notchkeeper.log` 永远不删。脚本出问题时也可以手动撤销：`launchctl bootout gui/$(id -u)/com.notchkeeper.guardd`，再删上表里的文件。

guardd 被卸载以后，`guard-state.json` 不再更新，App 在 15 秒内把它判为过期（stale）：如果最后一次 verdict 是 violated，红卡继续保留；否则显示灰色的 unknown 状态（见 `docs/egress-guard.md` §4「App 怎么读」）。

## 4. 为什么是 LaunchAgent，不是 SMAppService

- `SMAppService` 登录项和后台项目的审批绑定 App 的代码签名。我们现在只有临时签名（ad-hoc，见 `scripts/run.sh`），每次构建 cdhash 都变，系统里的审批会失效或要重新批准，实际体验不可靠。详见 `docs/killswitch-integration.md` §1。
- 每用户 LaunchAgent 不需要签名审批，也不要 root，装上卸掉都只是 `~/Library` 下的几个文件，可以完整撤销。
- 以后有了开发者账号、能稳定签名，可以把 guardd 打进 App bundle，改用 `SMAppService.agent(plistName:)`，由 App 注册和注销。

## 5. App 不用开着

guardd 由 launchd 在登录时启动，和 Notchkeeper.app 是两个独立的进程：App 没开、崩了、被退出，guardd 照样每 5 秒检查并写 `guard-state.json`。App 只是显示：启动时读一次文件，之后靠 `GuardStateWatcher` 监听文件所在目录，文件一变就重读。反过来，guardd 没在跑时，`guard-state.json` 不再更新，App 在 15 秒内判为过期（stale）；如果最后一次 verdict 是 violated，红卡继续保留，否则显示灰色 unknown。
