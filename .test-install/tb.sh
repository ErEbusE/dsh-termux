#!/data/data/com.termux/files/usr/bin/bash
# tb.sh — 组装 Tested-by trailer（AGENTS §6.3 的合并留痕格式）。
#
# 用法: bash .test-install/tb.sh "<范围>" [tree-ish]
#   范围      必填，人类实测覆盖面（如 "r6 + full gate"、"serve.sh checklist"）
#   tree-ish  可选，被测树（默认 HEAD；通常是待合并分支的 tip）
#
# 输出一行到 stdout，自行粘进合并/末位提交信息；不写任何文件、无副作用。
# 名字取 git config user.name；哈希取 tree-ish 短哈希；时刻取本地时间含时区。
# 时刻用 `date '+%F %R%:z'`、哈希用 `git rev-parse --short`，与 AGENTS §6.3
# 的手拼配方等价——本脚本只是把两步并成一步。
set -euo pipefail

scope="${1:?用法: bash .test-install/tb.sh \"<范围>\" [tree-ish]}"
tree="${2:-HEAD}"
name="$(git config user.name || true)"
[ -n "$name" ] || { echo "!! git config user.name 未设置" >&2; exit 1; }
hash="$(git rev-parse --verify --short "$tree")" || {
  echo "!! tree-ish 无法解析: $tree" >&2
  exit 1
}
printf 'Tested-by: %s [on-device: %s @%s, %s]\n' \
  "$name" "$scope" "$hash" "$(date '+%F %R%:z')"
