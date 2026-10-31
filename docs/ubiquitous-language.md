# 词表

同一个概念只有一个名字：代码用英文列，界面和文档用中文列。只收容易起歧义的词。

| 英文 | 中文 | 含义 |
|---|---|---|
| egress | 出口 | 本机访问公网时对方看到的 IPv4 |
| verdict | 结论 | 守卫一轮的判定：`healthy` / `egressMismatch` / `unknown` / `violated` |
| unknown reason | 未知原因 | guardd 写的：offline 断网、probeFailed 探针没结果 |
| stale | 守卫没响应 | App 读状态文件时判的：不存在、读不了、过期或时钟跳变 |
| session | 会话 | 一个 Claude Code 进程，对应 `~/.claude/sessions/<pid>.json` |
| agent state | agent 状态 | working 工作中 / stopped 已停止 / needsYou 需要你介入 |
| need | 介入类型 | question 等你回答 / approval 等你批准 |
| turn | 回合 | Claude 回应一条消息的全过程，由 mod 的 `turn.start` / `turn.complete` 界定；子 agent 的不算 |
| turn end | 回合结束 | 一个回合结束了（做完、出错、取消）。不是 mod 事件名 `turn.complete` |
| needs-you end | 介入结束 | 会话不再需要你介入（回到工作中、变成已停止、进程没了）。不是「已停止」 |
| turn outcome | 结局 | done 做完 / failed 出错 / canceled 取消 |
| long turn | 干了很久 | 工作中满 10 分钟 |
| agent activity | agent 动态 | 所有会话合起来 agent 这一档该画什么 |
| mod | mod | Claude Code 官方插件里的 JS 模块，源码在 `ClaudeMod/`。不叫「hook」「插件脚本」 |
| mascot | Pip | 吉祥物（用户 10-31 定名，原名盾盾）。代码前缀统一 `Mascot`（用户定），「Pip」只用在界面和文档 |
| look | 造型 | Pip 此刻的样子：渐变、眼形、朝向、装饰、右耳指示 |
| motion | 动作 | 叠在造型上的一段关键帧，例如完成跳转 |
| mood / sign | 心情装饰 / 告示 | 心情装饰是角色的一部分，收起时留在左耳；告示表示出了什么事，收起时挪到右耳 |
| ear indicator | 右耳指示 | 收起时右耳的点、告示图标或灰色空心环 |
| card | 卡片 | 刘海下弹出的提示：完成卡、出错卡、介入卡、红卡、恢复卡 |
| meteor | 流星 | 卡片弹出时沿边扫一趟的两道光。不叫「流光」「进度条」 |
