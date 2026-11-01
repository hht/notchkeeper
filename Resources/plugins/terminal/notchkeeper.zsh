# Pip 终端插件：命令跑了 10 秒以上，结束时在刘海上弹一张卡（跑完了 / 失败了），点了跳回这个终端。
# 在 ~/.zshrc 里 source 这个文件（Pip 设置 › 终端「安装」后会给出这一行）。不改 shell 的其他行为。
# 只把命令名（第一个词）交出 shell，参数不出去；目录和退出码作为卡上的键值。
# 照 zsh-auto-notify、ntfy shell-integration：preexec 记开始时刻和命令名，precmd 第一行取 $?。
# @see https://zsh.sourceforge.io/Doc/Release/Functions.html#Hook-Functions
#
# 可以在 source 之前改：
#   notchkeeper_min_seconds  至少跑多久才弹（默认 10）
#   notchkeeper_ignore       不弹的命令名（全屏的、交互式的）

[[ -o interactive ]] || return 0
zmodload zsh/datetime || return 0
autoload -Uz add-zsh-hook

typeset -g notchkeeper_min_seconds=${notchkeeper_min_seconds:-10}
(( ${+notchkeeper_ignore} )) || typeset -ga notchkeeper_ignore=(
  vim nvim vi nano emacs less more man ssh mosh top htop btop watch tmux screen claude lazygit tig fzf k9s yazi ranger
)
# 这个文件在 <Notchkeeper>/plugins/terminal/，pipctl 在 <Notchkeeper>/bin/
typeset -g _notchkeeper_pipctl=${${(%):-%x}:A:h:h:h}/bin/pipctl
typeset -g _notchkeeper_started _notchkeeper_command

_notchkeeper_preexec() {
  emulate -L zsh  # 不受用户 shell 选项影响（shwordsplit、ksharrays 之类）
  local word opts valued= skip=0 i
  _notchkeeper_command=
  # 跳过环境变量赋值、括号和 sudo 这类前缀，以及它们的选项；带值的选项连值一起跳过（值也是参数，不能交出去）
  for word in ${(z)1}; do
    if (( skip )); then skip=0; continue; fi
    case $word in
      *=*|'('|'{'|'!') continue ;;
      command|builtin|noglob|nocorrect|time|nohup) valued=; continue ;;
      exec) valued=a; continue ;;
      sudo) valued=ughpCDrtTU; continue ;;
      env) valued=uSPC; continue ;;
      nice) valued=n; continue ;;
      -*)
        # 合写的选项（-iu）：第一个带值的字母在最后，值是下一个词；不在最后，值贴在后面（-ualice）
        opts=${word#-}
        for (( i = 1; i <= $#opts; i++ )); do
          [[ $valued == *"${opts[i]}"* ]] || continue
          (( i == $#opts )) && skip=1
          break
        done
        continue ;;
    esac
    _notchkeeper_command=${word:t}
    break
  done
  _notchkeeper_started=$EPOCHREALTIME
}

_notchkeeper_precmd() {
  local exit_code=$?  # 必须是第一行：之后的任何命令（包括下一行）都会改 $?
  emulate -L zsh
  [[ -n $_notchkeeper_started && -n $_notchkeeper_command ]] || return 0
  local -F elapsed=$(( EPOCHREALTIME - _notchkeeper_started ))
  local command=$_notchkeeper_command
  _notchkeeper_started= _notchkeeper_command=
  (( elapsed >= notchkeeper_min_seconds )) || return 0
  (( ${notchkeeper_ignore[(Ie)$command]} )) && return 0
  [[ -x $_notchkeeper_pipctl ]] || return 0

  local -i seconds=$(( elapsed ))  # 整数变量赋值时截断小数
  local took
  if (( seconds >= 3600 )); then took="$(( seconds / 3600 )) 小时 $(( seconds % 3600 / 60 )) 分"
  elif (( seconds >= 60 )); then took="$(( seconds / 60 )) 分 $(( seconds % 60 )) 秒"
  else took="$seconds 秒"
  fi
  local title=$command outcome
  if (( exit_code == 0 )); then title+=" 跑完了"; outcome=done
  else title+=" 失败了"; outcome=failed
  fi
  local -a args=(notify --plugin terminal --title $title --value $took --outcome $outcome
                 --fact "退出码=$exit_code" --fact "目录=${(%):-%~}")
  # 同一个终端只留最新一张；点了跳回这个终端。不是 macOS 伪终端（/dev/ttysN）时只弹卡：pipctl 不收别的 tty
  [[ $TTY == /dev/ttys<-> ]] && args+=(--group "tty:$TTY" --tty $TTY --pid $$ --cwd $PWD)
  # 后台跑、不进作业表，不拖慢提示符
  "$_notchkeeper_pipctl" $args &>/dev/null &!
}

add-zsh-hook preexec _notchkeeper_preexec
add-zsh-hook precmd _notchkeeper_precmd
