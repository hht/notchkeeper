# 开发备忘

实机验证、截图、驱动 Claude Code 时的技巧和本机的坑。

- 整包编不过时先跑核心测试：把 `Sources/<Core>` 和 `Tests/<Core>Tests` 拷到 `/tmp` 一个临时包里 `swift test`。测试第一次就全绿时，在副本里故意改坏几处，确认会红。
- 驱动 Claude Code 会话：`tmux -L <名字> new-session -d -s x -c <已信任的目录> claude --permission-mode default`，`send-keys` 发提示、`Escape` 拒绝批准；没信任的目录只写 `.key` 不写 `.json`。用完 `kill-server`，`kill -9` 过的会话手动删 `<pid>.json` / `.key`。停在「等你批准」：让它跑 `touch /tmp/<文件>`（`date` 在允许列表里）；「等你回答」：让它用 AskUserQuestion 问是非题。
- 截图：卡片和收起态 `screencapture -x -R 556,0,400,110`（刘海在主屏顶部正中）；看造型在 `/tmp` 搭一次性陈列，`screencapture -l <windowID>` 连拍。几只 Pip 同时扁眼是眨眼。
- 没有 cliclick：在 `/tmp` 写一次性 Swift 脚本，用 `CGEvent` 移动、点击、滚动，完了把鼠标移回原处。
- 崩溃看 `~/Library/Logs/DiagnosticReports/Notchkeeper-*.ips`；日志在 `~/Library/Logs/Notchkeeper/notchkeeper.log`。
- zsh：`for f in $files` 不按空格拆，用 `xargs`；BSD `sed` 不认 `\b`，用 `perl -pi -e`。
- 拆提交不能用 `git add -p`：`git hash-object -w` + `git update-index --cacheinfo` 暂存部分内容，`git checkout-index -a --prefix=/tmp/x/` 导出暂存区单独构建。
- 交接文档就是 `HANDOFF.md`，不另写 `handoff.md`（macOS 不分大小写，会覆盖它）。
