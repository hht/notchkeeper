#!/bin/bash
# 从命令行触发刘海卡片（本机分布式通知），在实机上验卡片 UI
# 用法: scripts/demo.sh done|alert ["标题"] ["详情"]
KIND="${1:-done}"; TITLE="${2:-}"; DETAIL="${3:-}"
JS=$(cat <<'JSEOF'
ObjC.import('Foundation');
function run(argv) {
  var info = $.NSMutableDictionary.dictionary;
  if (argv[1]) info.setObjectForKey($(argv[1]), $('title'));
  if (argv[2]) info.setObjectForKey($(argv[2]), $('detail'));
  $.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately('local.hht.notchkeeper.card', argv[0], info, true);
  return 'posted ' + argv[0];
}
JSEOF
)
osascript -l JavaScript -e "$JS" "$KIND" "$TITLE" "$DETAIL"
