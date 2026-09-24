#!/data/data/com.termux/files/usr/bin/bash
# smoke-probes.sh — 行为探针的**触发条件派生**与失败语义（第 7b 步）。
#
# 为什么单独一个冒烟: 探针本体（三个 .mjs）要真 node + 真被测树，只能由真 case
# 覆盖；但**什么时候触发、触发不了算不算失败**是纯逻辑，而且正是旧体系出过事的
# 地方——审计 H2：探针里写死 marker 串，补丁改名后路线断言跟着新名字走，探针却
# 落到"跳过"分支，行为级覆盖静默消失，只留一句不进 summary 的 note。
# 这里把派生规则与四类结局（取值 / 跳过 / 歧义 / 声明了却缺 marker）全部摊开。
#
# 覆盖:
#   * 按**补丁目标 rel** 派生 marker（不是按补丁文件名、更不是写死串）
#   * 无条件条目才参与派生；只有条件条目 = 跳过（该补丁本就不适用于这类树）
#   * 同一目标多条无条件条目 -> 歧义 = FAIL，不随便挑一条
#   * 目标 lib 不在被测树 -> 跳过（不是失败），原因进 PROBE_SKIPPED
#   * 声明了该目标但 lib 缺 marker -> FAIL（旧体系只 warn）
#   * 探针进程失败 -> FAIL；三个探针全跳过 -> 聚合返回 0
#
# 用法: bash .test-install/tools/smoke-probes.sh

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SMOKE="$REPO/.test-install/state/smoke/probes"
WORK="$SMOKE/prefix/work"
TMPROOT="$SMOKE/tmp"
LOG="$SMOKE/log"
FAILED=0

ok()  { echo "  ok: $*"; }
bad() { echo "  FAIL: $*" >&2; FAILED=$((FAILED + 1)); }
check() { if [ "$2" = "$3" ]; then ok "$1 ($3)"; else bad "$1: 期望 $2, 实得 $3"; fi }

rm -rf "$SMOKE"
mkdir -p "$WORK/node_modules/@deepseek-ai" "$TMPROOT"
: > "$LOG"

# 探针库要求的沙箱钉子（run.sh 在真跑时提供）。
export DSH_CASE_ID="smoke/probes"
export DSH_CASE_CLASS="dry-run"
export DSH_SANDBOX_ROOT="$SMOKE"
export DSH_WORK_DIR="$WORK"
export DSH_RUNTIME_DIR="$SMOKE/prefix"
export HOME="$SMOKE/home"
export TMPDIR="$TMPROOT"
mkdir -p "$HOME"

# 补丁注册表由被 source 的探针库读取（工作区注册表在真跑时由 case source
# scripts/patch-lib.sh 得到）；本冒烟自己造各种形态给它。
export DSH_PATCH_SET=()

# shellcheck source=../lib/state.sh
. "$REPO/.test-install/lib/state.sh"
# shellcheck source=../lib/probes.sh
. "$REPO/.test-install/lib/probes.sh"

# CASE_PASSES/CASE_FAILURES 由被 source 的 lib/state.sh 读写，这里只负责清零。
# shellcheck disable=SC2034
reset_case() { CASE_FAILURES=""; CASE_PASSES=0; PROBE_SKIPPED=""; PROBE_MARKER=""; }

# 造一棵最小被测树: 把 marker 写进指定 lib。
mk_lib() { # $1=rel $2=内容
  mkdir -p "$WORK/node_modules/@deepseek-ai/$(dirname "$1")"
  printf '%s\n' "$2" > "$WORK/node_modules/@deepseek-ai/$1"
}
rm_lib() { rm -rf "${WORK:?}/node_modules/@deepseek-ai/$1"; }

echo "== 场景 1: marker 按补丁目标 rel 派生"
DSH_PATCH_SET=()
probe_marker_for_rel "dsh-fs-local/lib/index.js" >/dev/null 2>&1; rc=$?
check "注册表为空 -> 跳过" 1 "$rc"

DSH_PATCH_SET=("a.patch:dsh-fs-local/lib/index.js:MARK-A")
check "唯一无条件条目 -> marker" "MARK-A" "$(probe_marker_for_rel "dsh-fs-local/lib/index.js")"

DSH_PATCH_SET=(
  "a.patch:dsh-fs-local/lib/index.js:MARK-A"
  "b.patch:dsh-fs-local/lib/index.js:MARK-B"
)
probe_marker_for_rel "dsh-fs-local/lib/index.js" >/dev/null 2>&1; rc=$?
check "同一目标两条无条件条目 -> 歧义" 2 "$rc"

DSH_PATCH_SET=("c.patch:dsh-fs-local/lib/index.js:MARK-C:await internals.fs.link(staged, currentPath)")
probe_marker_for_rel "dsh-fs-local/lib/index.js" >/dev/null 2>&1; rc=$?
check "只有条件条目 -> 跳过（不拿可选 marker 当触发条件）" 1 "$rc"

DSH_PATCH_SET=("old.patch:dsh-session-persistence-jsonl/lib/index.js")
check "两段式旧条目 -> 回退 platformLinkDenied" "platformLinkDenied" \
  "$(probe_marker_for_rel "dsh-session-persistence-jsonl/lib/index.js")"

DSH_PATCH_SET=("a.patch:other/lib/index.js:MARK-A")
probe_marker_for_rel "dsh-fs-local/lib/index.js" >/dev/null 2>&1; rc=$?
check "目标 rel 不匹配 -> 跳过" 1 "$rc"

echo "== 场景 2: 目标 lib 不在被测树 -> 跳过（不是失败）"
reset_case
DSH_PATCH_SET=("a.patch:dsh-fs-local/lib/index.js:MARK-A")
rm_lib "dsh-fs-local/lib/index.js"
_probe_preflight "dsh-fs-local/lib/index.js" "fs-local 探针" 2>>"$LOG"; rc=$?
check "缺 lib -> 返回跳过" 1 "$rc"
case "$PROBE_SKIPPED" in *"不在被测树"*) ok "跳过原因可读: $PROBE_SKIPPED" ;; *) bad "跳过原因不可读: '$PROBE_SKIPPED'" ;; esac
check "跳过不记账为失败" "" "$CASE_FAILURES"

echo "== 场景 3: 声明了目标但 lib 缺 marker -> FAIL"
reset_case
DSH_PATCH_SET=("a.patch:dsh-fs-local/lib/index.js:MARK-A")
mk_lib "dsh-fs-local/lib/index.js" "// 没有 marker 的 lib"
_probe_preflight "dsh-fs-local/lib/index.js" "fs-local 探针" 2>>"$LOG"; rc=$?
check "缺 marker -> 返回失败" 2 "$rc"
case "$CASE_FAILURES" in *"行为级覆盖缺失"*) ok "失败已记账（旧体系这里只 warn）" ;; *) bad "失败未记账: '$CASE_FAILURES'" ;; esac

echo "== 场景 4: marker 在场 -> 可继续，marker 带出来"
reset_case
DSH_PATCH_SET=("a.patch:dsh-fs-local/lib/index.js:MARK-A")
mk_lib "dsh-fs-local/lib/index.js" "// MARK-A 在"
_probe_preflight "dsh-fs-local/lib/index.js" "fs-local 探针" 2>>"$LOG"; rc=$?
check "marker 在场 -> 继续" 0 "$rc"
check "marker 传给探针" "MARK-A" "$PROBE_MARKER"
check "继续时不记账失败" "" "$CASE_FAILURES"

echo "== 场景 5: 探针进程失败 -> FAIL（用 false 冒充 node）"
reset_case
DSH_PATCH_SET=("a.patch:dsh-sandbox-local/lib/index.js:MARK-L")
mk_lib "dsh-sandbox-local/lib/index.js" "// MARK-L 在"
probe_landlock_tmpdir "$WORK" "$(command -v false)" 2>>"$LOG"; rc=$?
check "探针进程非零 -> 返回失败" 1 "$rc"
case "$CASE_FAILURES" in *"行为不符"*) ok "探针失败已记账" ;; *) bad "探针失败未记账: '$CASE_FAILURES'" ;; esac
if ls "$TMPROOT"/probe-landlock.mjs >/dev/null 2>&1; then bad "失败后探针脚本未清理"; else ok "失败后探针脚本已清理"; fi

echo "== 场景 6: 三个探针全跳过 -> 聚合不判失败"
reset_case
unset DSH_PATCH_SET
rm_lib "dsh-sandbox-local/lib/index.js"; rm_lib "dsh-fs-local/lib/index.js"; rm_lib "dsh-attachment-local/lib/index.js"
probe_patch_set_behaviors "$WORK" "$(command -v false)" 2>>"$LOG"; rc=$?
check "全跳过 -> 聚合成功" 0 "$rc"
check "全跳过不记账失败" "" "$CASE_FAILURES"
n="$(printf '%s' "$PROBE_SKIPPED" | tr ';' '\n' | grep -c .)"
check "三个跳过原因都留下" 3 "$n"

echo "== 场景 7: DSH_PATCH_SET 未定义时不炸（set -u 下的空数组展开）"
reset_case
unset DSH_PATCH_SET
probe_marker_for_rel "dsh-fs-local/lib/index.js" >/dev/null 2>&1; rc=$?
check "未定义注册表 -> 跳过而不是报错" 1 "$rc"

echo
if [ "$FAILED" -eq 0 ]; then
  echo "PROBES SMOKE: ALL OK"
else
  echo "PROBES SMOKE: $FAILED 项失败" >&2
  exit 1
fi
