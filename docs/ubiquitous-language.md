# 词表

同一个概念只有一个名字。代码标识符用英文列，界面和文档用中文列。新词先进这里再用。

## 出口守卫

| 英文 | 中文 | 含义 |
|---|---|---|
| egress | 出口 | 本机访问公网时对方看到的 IPv4 |
| allowlist | 允许列表 | 用户认可的出口 IP，存在 `config.json` |
| verdict | 结论 | 守卫一轮判定的结果：`healthy` / `egressMismatch` / `unknown` / `violated`（`docs/egress-guard.md`） |
| unknown reason | 未知原因 | 状态文件里 unknown 的原因：offline 断网、probeFailed 探针没结果 |
| stale | 守卫没响应 | App 读状态文件时判出的：文件不存在、读不了、过期或时钟跳变（`docs/egress-guard.md`） |
| guardd | 守卫进程 | 用户级 LaunchAgent，写 `guard-state.json` |
| firewall | 防火墙 | 一键开关的 pf anchor（`docs/firewall.md`） |

## agent

| 英文 | 中文 | 含义 |
|---|---|---|
| session | 会话 | 一个 Claude Code 进程，对应一份 `~/.claude/sessions/<pid>.json` |
| agent state | agent 状态 | 工作中 working / 已停止 stopped / 需要你介入 needsYou（`docs/agent-integration.md`） |
| turn | 回合 | 从已停止进入工作中，到再次变成已停止 |
| turn end | 回合结束 | 回合中变成已停止 |
| long turn | 干了很久 | 工作中，并且离回合开始超过 10 分钟 |

## 盾盾（`docs/mascot.md`）

代码前缀统一用 `Mascot`（用户 10-29），角色名「盾盾」只用在界面和文档里。

| 英文 | 中文 | 含义 |
|---|---|---|
| mascot | 盾盾 | 吉祥物本身 |
| look | 造型 | 盾盾此刻的样子：渐变、眼形、朝向、装饰、右耳指示。16 个，名字见 `docs/mascot.md` §2 |
| motion | 动作 | 叠加在造型上的一段关键帧，例如东张西望、完成跳转 |
| mood | 心情装饰 | 角色的一部分的装饰，收起时留在左耳 |
| sign | 告示 | 表示出了什么事的装饰，收起时挪到右耳 |
| head pose | 朝向 | 头的 yaw（左右）、pitch（上下）、roll（侧歪） |
| gaze | 注视 | 跟随鼠标得到的 yaw / pitch |
| eye outline | 眼形轮廓 | 一只眼化成的 120 点闭合多边形，换形时逐点补间（`docs/mascot.md` §3） |
| part | 部件 | 动画作用的图层，例如身体、眼睛、装饰的一块 |
| track | 轨道 | 一个部件的一个属性的一条动画（值 + 时刻 + 缓动） |
| cue | 提示 | 空闲时该眨眼、该做小动作的信号 |
| ear indicator | 右耳指示 | 收起时右耳显示的点、告示图标或灰色空心环 |

## 刘海

| 英文 | 中文 | 含义 |
|---|---|---|
| collapsed | 收起 | 刘海加左右两只耳朵 |
| expanded | 展开 | 悬停或点击后长成的面板 |
| left ear / right ear | 左耳 / 右耳 | 收起时刘海两侧的黑色区域：左耳放盾盾，右耳放指示 |
| card | 卡片 | 刘海下弹出的提示：完成卡、介入卡、红卡（violated）、恢复卡 |
