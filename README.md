# Notchkeeper

菜单栏出口守卫 + 刘海卡片。本机开发、本机临时签名（无需付费开发者账号）。

## 运行

```bash
./scripts/run.sh          # 编译、打包 build/Notchkeeper.app、ad-hoc 签名并启动
./scripts/demo.sh done    # 触发绿色「任务完成」卡片（约 4 秒自动收起）
./scripts/demo.sh alert   # 触发红色「出口异常」卡片（需手动关闭）
```

日志：`~/Library/Logs/Notchkeeper/notchkeeper.log`（不记录 IP）。

## 当前里程碑 M1（仅界面）

- 菜单栏盾牌图标：绿=出口在允许列表，红=不在，灰=未知/获取失败；左键打开面板，右键打开调试菜单。
- 面板：状态 / 允许出口 / 拦截 / 日志，弹簧动效、毛玻璃、页面过渡。
- 刘海卡片：从刘海弹出/收回；红色常驻，绿色自动收起。
- 出口 IPv4 来自 api.ipify.org（备用 ipinfo.io / ifconfig.me），从不访问 Claude/Anthropic 域名。

**尚未实现（占位）**：Clash 内核 / utun 检测、结束 Claude 进程、CLI shim、开机自启、JSON 配置、agent 任务完成 hook。
