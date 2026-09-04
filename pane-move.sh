#!/usr/bin/env bash
set -euo pipefail

BIN="${HERDR_BIN_PATH:-herdr}"

if ! command -v jq >/dev/null 2>&1; then
  echo "错误：缺少 jq 命令，请安装 jq 后重试。" >&2
  exit 1
fi

die() {
  echo "错误：$1" >&2
  exit 1
}

# 检查 herdr 是否可用
if ! command -v "$BIN" >/dev/null 2>&1; then
  die "未找到 herdr 命令（HERDR_BIN_PATH=${HERDR_BIN_PATH:-herdr}）。"
fi

# 获取当前窗格 ID
raw_current=$("$BIN" pane current 2>/dev/null) || true
if [[ -z "$raw_current" ]]; then
  die "无法获取当前窗格，请确认 herdr 正在运行。"
fi
current_pane=$(printf '%s' "$raw_current" | jq -r '.result.pane.pane_id // empty' 2>/dev/null) || die "解析失败: jq 错误"
if [[ -z "${current_pane:-}" ]]; then
  die "无法解析当前窗格 ID，herdr 返回数据异常。"
fi
current_tab=$(printf '%s' "$raw_current" | jq -r '.result.pane.tab_id // empty' 2>/dev/null) || die "解析失败: jq 错误"
if [[ -z "${current_tab:-}" ]]; then
  die "无法解析当前标签页 ID，herdr 返回数据异常。"
fi

# 获取所有窗格并解析
raw_list=$("$BIN" pane list 2>/dev/null) || true
if [[ -z "$raw_list" ]]; then
  die "无法获取窗格列表，请确认 herdr 正在运行。"
fi
if ! printf '%s' "$raw_list" | jq -e '.result.panes' >/dev/null 2>&1; then
  die "herdr 返回的窗格列表格式异常。"
fi

pids=()
tabs=()
descs=()
jq_output=$(printf '%s' "$raw_list" | jq -r '.result.panes[] | [.pane_id, (.terminal_title_stripped // .terminal_title // "(无标题)"), .tab_id] | @tsv' 2>/dev/null) || die "解析失败: jq 错误"
while IFS=$'\t' read -r pid title tab; do
  [[ -z "${pid:-}" ]] && continue
  [[ "$pid" == "$current_pane" ]] && continue
  if [[ -z "${tab:-}" || "$tab" == "null" ]]; then
    continue
  fi
  pids+=("$pid")
  tabs+=("$tab")
  if [[ "$tab" == "$current_tab" ]]; then
    descs+=("[同Tab] $title ($tab)")
  else
    descs+=("$title ($tab)")
  fi
done <<< "$jq_output"

if [[ ${#pids[@]} -eq 0 ]]; then
  die "当前无可移动目标窗格（当前窗格: $current_pane）。"
fi

target_pane=""
target_tab=""
if command -v fzf >/dev/null 2>&1 && [ -t 0 ]; then
  fzf_lines=()
  for i in "${!pids[@]}"; do
    fzf_lines+=("${pids[$i]}"$'\t'"${tabs[$i]}"$'\t'"${descs[$i]}")
  done
  selected=$(printf '%s\n' "${fzf_lines[@]}" | fzf --delimiter=$'\t' --with-nth=3 --prompt="选择目标窗格> " --no-sort) || true
  [[ -z "$selected" ]] && exit 0
  target_pane=$(printf '%s' "$selected" | cut -f1)
  target_tab=$(printf '%s' "$selected" | cut -f2)
elif [ -t 0 ]; then
  PS3="选择目标窗格 (当前: $current_pane, 0 取消): "
  select opt in "${descs[@]}"; do
    if [[ "$REPLY" == "0" ]]; then
      exit 0
    elif ! [[ "$REPLY" =~ ^[0-9]+$ ]]; then
      printf '请输入数字序号\n' >&2
      continue
    elif [[ -z "$opt" || "$REPLY" -lt 1 || "$REPLY" -gt ${#descs[@]} ]]; then
      printf '无效选择，请输入 0-%d 之间的序号。\n' "${#descs[@]}" >&2
      continue
    fi
    target_pane="${pids[$((10#$REPLY-1))]}"
    target_tab="${tabs[$((10#$REPLY-1))]}"
    break
  done
else
  printf '非交互终端，请选择目标窗格编号（当前: %s）：\n' "$current_pane" >&2
  for i in "${!pids[@]}"; do
    printf '%d) %s\n' "$((i+1))" "${descs[$i]}" >&2
  done
  printf '0) 取消\n' >&2
  if ! read -r REPLY; then
    die "非交互终端无法读取选择，请通过交互式界面运行。"
  fi
  if [[ "$REPLY" == "0" ]]; then
    exit 0
  elif ! [[ "$REPLY" =~ ^[0-9]+$ ]] || [[ -z "${pids[$((10#$REPLY-1))]:-}" ]]; then
    die "无效选择，请输入 0-${#descs[@]} 之间的序号。"
  fi
  target_pane="${pids[$((10#$REPLY-1))]}"
  target_tab="${tabs[$((10#$REPLY-1))]}"
fi

if [[ -z "$target_pane" || -z "$target_tab" ]]; then
  die "未选择目标窗格。"
fi

move_err=$(mktemp)
trap 'rm -f "$move_err"' EXIT
raw_move=$("$BIN" pane move "$current_pane" --tab "$target_tab" --split right --target-pane "$target_pane" 2>"$move_err") && move_ok=0 || move_ok=$?
if [[ $move_ok -ne 0 ]]; then
  err_msg=$(<"$move_err")
  die "搬移窗格失败（源: $current_pane，目标: $target_pane，标签页: $target_tab）。herdr 报错: $err_msg"
fi

changed=$(printf '%s' "$raw_move" | jq -r 'if .result.move_result.changed == null then empty elif .result.move_result.changed then "true" else "false" end' 2>/dev/null) || die "解析失败: jq 错误"
if [[ "$changed" == "false" ]]; then
  echo "提示：herdr 返回未实际搬移（源: $current_pane，目标: $target_pane，标签页: $target_tab）。" >&2
  printf 'herdr 原始响应: %s\n' "$raw_move" >&2
  exit 0
elif [[ -z "$changed" && -n "$raw_move" ]]; then
  echo "提示：herdr 返回结果格式异常，无法确认搬移状态，请手动检查。" >&2
fi
