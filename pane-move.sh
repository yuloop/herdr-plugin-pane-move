#!/usr/bin/env bash
set -euo pipefail

BIN="${HERDR_BIN_PATH:-herdr}"

die() {
  echo "错误：$1" >&2
  "$BIN" pane move --help >&2
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
current_pane=$(printf '%s' "$raw_current" | jq -r '.result.pane.pane_id // empty' 2>/dev/null) || true
if [[ -z "${current_pane:-}" ]]; then
  die "无法解析当前窗格 ID，herdr 返回数据异常。"
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
while IFS=$'\t' read -r pid title tab; do
  [[ -z "${pid:-}" ]] && continue
  [[ "$pid" == "$current_pane" ]] && continue
  pids+=("$pid")
  if [[ -z "${tab:-}" || "$tab" == "null" ]]; then
    continue
  fi
  tabs+=("$tab")
  if [[ "${pid%%:*}" == "${current_pane%%:*}" ]]; then
    descs+=("[同Tab] $title ($tab)")
  else
    descs+=("$title ($tab)")
  fi
done < <(printf '%s' "$raw_list" | jq -r '.result.panes[] | [.pane_id, (.terminal_title_stripped // .terminal_title // "(无标题)"), .tab_id] | @tsv' 2>/dev/null) || true

if [[ ${#pids[@]} -eq 0 ]]; then
  die "当前无可移动目标窗格（当前窗格: $current_pane）。"
fi

target_pane=""
target_tab=""
if command -v fzf >/dev/null 2>&1; then
  fzf_lines=()
  for i in "${!pids[@]}"; do
    fzf_lines+=("${pids[$i]}"$'\t'"${tabs[$i]}"$'\t'"${descs[$i]}")
  done
  selected=$(printf '%s\n' "${fzf_lines[@]}" | fzf --delimiter=$'\t' --with-nth=3 --prompt="选择目标窗格> " --no-sort) || true
  [[ -z "$selected" ]] && exit 0
  target_pane=$(printf '%s' "$selected" | cut -f1)
  target_tab=$(printf '%s' "$selected" | cut -f2)
else
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
    target_pane="${pids[$((REPLY-1))]}"
    target_tab="${tabs[$((REPLY-1))]}"
    break
  done
fi

if [[ -z "$target_pane" || -z "$target_tab" ]]; then
  die "未选择目标窗格。"
fi

raw_move=$("$BIN" pane move "$current_pane" --tab "$target_tab" --split right --target-pane "$target_pane" 2>/dev/null) || raw_move=""
if [[ -z "$raw_move" ]]; then
  die "搬移窗格失败（源: $current_pane，目标: $target_pane，标签页: $target_tab）。"
fi

changed=$(printf '%s' "$raw_move" | jq -r '.result.move_result.changed // empty' 2>/dev/null) || true
if [[ "$changed" == "false" ]]; then
  echo "提示：herdr 返回未实际搬移（源: $current_pane，目标: $target_pane，标签页: $target_tab）。同标签页内 herdr 暂不支持窗格搬移，请使用 swap 交换位置。" >&2
  exit 0
fi
