# Notchkeeper

菜单栏出口守卫 + 刘海卡片。本机开发、本机临时签名（无需付费开发者账号）。

项目位置：`~/Documents/Projects/notchkeeper`（脚本只用相对路径，可在任意位置运行）。

## 运行

```bash
./scripts/run.sh          # 编译、打包 build/Notchkeeper.app、ad-hoc 签名并启动
./scripts/demo.sh done    # 触发绿色「任务完成」卡片（按设置的秒数自动收起）
./scripts/demo.sh alert   # 触发红色「出口异常」卡片
build/Notchkeeper.app/Contents/MacOS/Notchkeeper --selftest            # 事件过滤自检 + 会话计数
swift test                # GuardCore 单元测试
build/Notchkeeper.app/Contents/MacOS/Notchkeeper --login-item status   # 开机启动状态
```

- 配置：`~/Library/Application Support/Notchkeeper/config.json`（改动自动热加载，字段缺失用默认值）
- 日志：`~/Library/Logs/Notchkeeper/notchkeeper.log`（本地时间，不记录 IP，不记录任何对话内容）

## M2

- 设置页（面板 › 设置）：通用（开机启动 / 菜单栏图标样式 / 面板材质 / 提示音 / 悬停展开）、出口守卫（允许列表 / 检查间隔 / 自动红卡 / 红卡常驻）、通知（自动收起秒数 / 宿主前台不提示 / 各 agent 开关）、关于。
- 悬停刘海展开：鼠标移到刘海 → 弹出“岛”，显示出口 IPv4（颜色表示是否允许）和近 30 分钟的活跃会话（项目名 / agent / 运行中或空闲 / 时长）。不放拦截点击的窗口，只监听鼠标位置。
- 会话发现是被动只读的：Claude Code `~/.claude/projects/*/*.jsonl`（跳过 `subagents/` 和 `isSidechain`），Codex `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`（跳过 `session_meta.source.subagent`），外加 claude / codex 进程计数。
- 事件模型（`AgentEvents.swift`）：每个 agent 1 个“回合结束”钩子 → `AgentEvent` → 子 agent / stop_hook_active / 中断 / 宿主前台过滤 → 去重。**本阶段不安装任何钩子。**

## M3（进行中）

- `GuardCore`（`Sources/GuardCore/`）：出口健康三态判定（healthy / unknown / violated）的纯逻辑，规则见 `EgressGuard.swift` 的类型注释；`swift test` 跑它的测试。还没接到 App 里。

**尚未实现（占位）**：Clash / utun 检测、结束 Claude 进程、CLI shim、钩子安装与完成提示接线、原创吉祥物美术。
