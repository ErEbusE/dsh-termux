#!/data/data/com.termux/files/usr/bin/bash
# tb.sh — 组装 Tested-by trailer（AGENTS §6.3 的合并留痕格式）。
#
# 用法: bash .test-install/tb.sh [--review] "<覆盖面一句话，如 'r6 + full gate'>" [tree-ish]
#   实测覆盖面  必填，一句描述本次人类验证的范围，原样进入 trailer
#               （如 "r6 + full gate"、"serve.sh checklist"）；
#   tree-ish    可选，被测树（默认 HEAD；通常是待合并分支的 tip）
#   --review    改动**没有真机面**时用（纯 CI / 纯工作流）：把标签从
#               on-device 换成 review。默认 on-device——凡是能落到设备上的
#               改动都必须是真机凭据，绝不允许用 review 蒙混过去。
#               纯文档类**根本不需要 trailer**（AGENTS §6.4：无可实测项），
#               别拿 --review 去给它凑一个。
#
# 输出一行到 stdout，自行粘进合并/末位提交信息；不写任何文件、无副作用。
# 名字取 git config user.name；哈希取 tree-ish 短哈希；时刻取本地时间含时区。
# 时刻用 `date '+%F %R%:z'`、哈希用 `git rev-parse --short`，与 AGENTS §6.3
# 的手拼配方等价——本脚本只是把两步并成一步。
set -euo pipefail

kind="on-device" ; kind_flag=""
if [ "${1:-}" = "--review" ]; then kind="review"; kind_flag="--review "; shift; fi
scope="${1:?用法: bash .test-install/tb.sh [--review] \"<覆盖面一句话，如 'r6 + full gate'>\" [tree-ish]}"
tree="${2:-HEAD}"
# 防呆(#20 实测反馈): 只给一个参数且它长得像 rev(@哈希/哈希)时,几乎可以
# 断定是把哈希塞进了范围位——响亮报错并示范正确用法,而不是输出
# [on-device: @eb6ca2e @eb6ca2e] 式的废话。参数顺序: 范围在前,哈希在后。
if [ $# -eq 1 ] && [[ "$scope" =~ ^@?[0-9a-fA-F]{7,40}$ ]]; then
  echo "!! 第一个参数应是「实测范围的描述文字」（如 'r6 + full gate'），" >&2
  echo "   '$scope' 看起来是 tree-ish 被塞错了位置；哈希位在第二个参数：" >&2
  # 把 --review 原样带回示范命令: 否则照抄这条修正建议的人会静默丢掉自己
  # 刚给过的标签, 拿到一个 on-device trailer——正是本脚本要防的那类误记。
  echo "   bash $0 ${kind_flag}\"<实测覆盖面一句话>\" $scope" >&2
  exit 1
fi
name="$(git config user.name || true)"
[ -n "$name" ] || { echo "!! git config user.name 未设置" >&2; exit 1; }
hash="$(git rev-parse --verify --short "$tree")" || {
  echo "!! tree-ish 无法解析: $tree" >&2
  exit 1
}
printf 'Tested-by: %s [%s: %s @%s, %s]\n' \
  "$name" "$kind" "$scope" "$hash" "$(date '+%F %R%:z')"
