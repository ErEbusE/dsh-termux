#!/data/data/com.termux/files/usr/bin/bash
# pr-merge.sh — 带 Tested-by trailer 的 PR 合并（维护者工具；本地执行，不进 CI、不进发布物）。
#
# 为什么存在：AGENTS.md §6.3 要求把实测凭据写进 merge commit，而 `gh pr merge`
# 不会替你生成 trailer —— 手拼格式是整条流程里最容易出错的一步。本工具把
# 「取 PR head → 等 CI → 生成 trailer → 组合并提交信息 → 合并」串成一次调用。
#
# 用法:
#   bash .test-install/tools/pr-merge.sh <PR号> "<实测范围>" [选项]
#
# 选项:
#   --review         无真机面（纯 CI / 纯工作流）: trailer 标签变 review
#   --summary TEXT   在 trailer 前加一段合并摘要（默认只放 PR 标题）
#   --yes            真正执行合并（默认 dry-run: 只打印将要写入的合并提交信息）
#   --no-wait        CI 未跑完时不等待（默认 gh pr checks --watch 等到全部结束）
#   --sha SHA        覆盖 trailer 的 @哈希（默认取 PR head 对象）
#   -h, --help       本帮助
#
# 前置: gh CLI 已安装并已认证 —— `source ~/.config/dsh-termux/.env` 之后 gh 自动
# 读取 GH_TOKEN（AGENTS.md §2）。设备侧/发布物脚本禁止依赖 gh，本工具只给维护者用。
# 三个内建防呆: PR 必须 OPEN 且无冲突 / CI 全绿才合并 / @哈希自动取 PR head（不手抄）。
set -euo pipefail

usage() { sed -n '/^# 用法:/,/^# 前置:/p' "$0" | sed 's/^# \?//'; }
die() { echo "!! $*" >&2; exit 1; }

PR=""; SCOPE=""; REVIEW=0; YES=0; WAIT=1; SUMMARY=""; SHA=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --review) REVIEW=1; shift ;;
    --yes) YES=1; shift ;;
    --no-wait) WAIT=0; shift ;;
    --summary) SUMMARY="${2:?--summary 需要一段文字}"; shift 2 ;;
    --sha) SHA="${2:?--sha 需要一个 tree-ish}"; shift 2 ;;
    --*) die "未知选项: $1（-h 看用法）" ;;
    *)
      if [ -z "$PR" ]; then PR="$1"
      elif [ -z "$SCOPE" ]; then SCOPE="$1"
      else die "多余的参数: $1"; fi
      shift ;;
  esac
done

[ -n "$PR" ] || { usage >&2; exit 1; }
case "$PR" in *[!0-9]*) die "PR 号必须是数字: $PR" ;; esac
[ -n "$SCOPE" ] || die "缺实测范围（第二个参数，原样进 trailer）—— 见 AGENTS.md §6.3"

command -v gh >/dev/null 2>&1 \
  || die "找不到 gh CLI —— 安装后 source ~/.config/dsh-termux/.env（AGENTS.md §2）"
gh auth status >/dev/null 2>&1 \
  || die "gh 未认证 —— source ~/.config/dsh-termux/.env 后重试（AGENTS.md §2）"

TI="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # .test-install/
REPO="$(cd "$TI/.." && pwd)"

gh pr view "$PR" --json state >/dev/null 2>&1 \
  || die "取不到 PR #$PR（gh pr view 失败: 不存在 / 未认证 / 网络）"

# 一次取齐元数据（@tsv 由 gh 自带 jq 实现，不依赖系统 jq）
IFS=$'\t' read -r state isdraft mergeable head_oid head_ref head_owner title url < <(
  gh pr view "$PR" \
    --json state,isDraft,mergeable,headRefOid,headRefName,headRepositoryOwner,title,url \
    --jq '[.state, .isDraft, .mergeable, .headRefOid, .headRefName, .headRepositoryOwner.login, .title, .url] | @tsv'
)

[ "$state" = "OPEN" ] || die "PR #$PR 状态是 $state（已合并 / 已关闭），不重复合并"
[ "$isdraft" = "false" ] || die "PR #$PR 仍是 draft"
case "$mergeable" in
  CONFLICTING) die "PR #$PR 有冲突（mergeable=CONFLICTING），先解决" ;;
  UNKNOWN) echo "note: GitHub 还在计算 mergeable，按无冲突继续" ;;
esac

echo "==> PR #$PR: $title"
echo "    $url"

if [ "$WAIT" = 1 ]; then
  echo "==> CI 状态（未完成则等到全部结束）…"
  if ! checks="$(gh pr checks "$PR" --watch 2>&1)"; then
    printf '%s\n' "$checks"
    die "CI 未全绿 —— 拒绝合并（--no-wait 只跳过等待，不跳过这项判定）"
  fi
else
  if ! checks="$(gh pr checks "$PR" 2>&1)"; then
    printf '%s\n' "$checks"
    die "CI 未全绿（--no-wait 已指定）—— 拒绝合并"
  fi
fi
printf '%s\n' "$checks"

# trailer 的 @哈希 = 被测树 tip: 默认 PR head（不手抄）；本地没有该对象时
# 从 PR 的 refs/pull/N/head 取回（不落 ref，只写 FETCH_HEAD）。
if [ -z "$SHA" ]; then
  if git -C "$REPO" cat-file -e "${head_oid}^{commit}" 2>/dev/null; then
    SHA="$head_oid"
  else
    echo "==> 本地缺 PR head 对象，取回 refs/pull/$PR/head …"
    git -C "$REPO" fetch -q origin "refs/pull/$PR/head" || die "git fetch refs/pull/$PR/head 失败"
    SHA="FETCH_HEAD"
  fi
fi

tb_args=()
[ "$REVIEW" = 1 ] && tb_args+=(--review)
trailer="$(bash "$TI/tools/tb.sh" ${tb_args[@]+"${tb_args[@]}"} "$SCOPE" "$SHA")" \
  || die "tb.sh 生成 trailer 失败"

subject="Merge pull request #$PR from $head_owner/$head_ref"
body="$title"
[ -n "$SUMMARY" ] && body="$body"$'\n\n'"$SUMMARY"
body="$body"$'\n\n'"$trailer"

echo
echo "=== 合并提交（将写入）==="
echo "subject: $subject"
echo "---"
printf '%s\n' "$body"
echo "========================"

if [ "$YES" != 1 ]; then
  echo "dry-run: 未执行合并。核对无误后加 --yes 执行。"
  exit 0
fi

gh pr merge "$PR" --merge --subject "$subject" --body "$body"
