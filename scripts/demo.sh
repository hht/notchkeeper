#!/bin/bash
# 从命令行触发刘海卡片（本机分布式通知），在实机上验卡片 UI
# 用法: scripts/demo.sh done|failed|question|approval|alert|blocks
# agent 的卡挂在最近变过状态的 Claude Code 会话上，和真卡一样（会顶掉这个会话正在放的介入卡）；没有会话就不弹
case "${1:-done}" in done|failed|question|approval|alert|blocks) ;; *) echo "用法: $0 done|failed|question|approval|alert|blocks" >&2; exit 2;; esac
JS=$(cat <<'JSEOF'
ObjC.import('Foundation');
function run(argv) {
  $.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately('local.hht.notchkeeper.card', argv[0], $.NSDictionary.dictionary, true);
  return 'posted ' + argv[0];
}
JSEOF
)
osascript -l JavaScript -e "$JS" "${1:-done}"
