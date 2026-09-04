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
descs=()
while IFS=$'\t' read -r pid title tab; do
  [[ -z "${pid:-}" ]] && continue
  [[ "$pid" == "$current_pane" ]] && continue
  pids+=("$pid")
  if [[ "${pid%%:*}" == "${current_pane%%:*}" ]]; then
    descs+=("[同Tab] $title ($tab)")
  else
    descs+=("$title ($tab)")
  fi
done < <(printf '%s' "$raw_list" | jq -r '.result.panes[] | [.pane_id, (.terminal_title_stripped // .terminal_title // "(无标题)"), .tab_id] | @tsv' 2>/dev/null) || true

if [[ ${#pids[@]} -eq 0 ]]; then
  die "当前无可移动目标窗格（当前窗格: $current_pane）。"
fi

target=""
if command -v fzf >/dev/null 2>&1; then
  fzf_lines=()
  for i in "${!pids[@]}"; do
    fzf_lines+=("${pids[$i]}"$'\t'"${descs[$i]}")
  done
  target=$(printf '%s\n' "${fzf_lines[@]}" | fzf --delimiter=$'\t' --with-nth=2 --prompt="选择目标窗格> " --no-sort) || true
  [[ -z "$target" ]] && exit 0
  target=$(printf '%s' "$target" | cut -f1)
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
    target="${pids[$((REPLY-1))]}"
    break
  done
fi

if ! "$BIN" pane move "$current_pane" --target-pane "$target"; then
  die "搬移窗格失败（源: $current_pane，目标: $target）。"
fi
