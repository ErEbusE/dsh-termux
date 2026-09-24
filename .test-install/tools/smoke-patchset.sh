#!/data/data/com.termux/files/usr/bin/bash
# smoke-patchset.sh — **产物内**注册表解析与 wrapper 钩子派生（第 7c 步，映射表 L8/L9）。
#
# 为什么单独一个冒烟: 这两件事都是"期望值必须从消费的那份注册表派生，绝不写死"
# 的落点，而它们要面对的输入是**别人发布出来的**历史形态——两段式 / 三段式 /
# 带前置条件的四段式混在一起。写死任何一个串都会让某代发布物误红，或者让覆盖
# 悄悄消失（旧体系审计 H1/H2 都是这一类）。
#
# overlay（L10，"先退 shipped 集再打工作区集"）不在这里：它需要真的 git 树 + 真的
# 补丁文件，由 CI 的 `.github/scripts/patch-matrix.sh` 用真实发布资产覆盖（秒级）；
# 本文件只覆盖不依赖被测树的那部分——它正是"改了注册表忘了同步"的放大器。
#
# 用法: bash .test-install/tools/smoke-patchset.sh

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SMOKE="$REPO/.test-install/state/smoke/patchset"
FAILED=0

ok()  { echo "  ok: $*"; }
bad() { echo "  FAIL: $*" >&2; FAILED=$((FAILED + 1)); }
check() { if [ "$2" = "$3" ]; then ok "$1 ($3)"; else bad "$1: 期望 $2, 实得 $3"; fi }

rm -rf "$SMOKE"
mkdir -p "$SMOKE/prefix/work/node_modules/@deepseek-ai/dsh-lib-a" \
         "$SMOKE/prefix/work/node_modules/@deepseek-ai/dsh-lib-b"
# shellcheck source=../lib/patchset.sh
. "$REPO/.test-install/lib/patchset.sh"

echo "== 场景 1: 条目文本解析（两/三/四段式混排 + 注释与空行）"
cat > "$SMOKE/patch-lib.sh" <<'EOF'
DSH_PATCH_SET=(
  # 两段式（pre-marker 时代）
  "old.patch:dsh-lib-a/lib/index.js"
  # 三段式
  "mid.patch:dsh-lib-b/lib/index.js:dsh-termux-mid"
  "cond.patch:dsh-lib-a/lib/index.js:dsh-termux-cond:await link(temporary, target)"
)
EOF
n="$(patchset_entries "$SMOKE/patch-lib.sh" | grep -c .)"
check "解析出 3 条条目（注释与空行不算）" 3 "$n"
check "两段式回退 platformLinkDenied" \
  "$(patchset_marker "$(patchset_entries "$SMOKE/patch-lib.sh" | sed -n 1p)")" platformLinkDenied
check "三段式取第三段" \
  "$(patchset_marker "$(patchset_entries "$SMOKE/patch-lib.sh" | sed -n 2p)")" dsh-termux-mid
check "四段式的 marker 只有第三段" \
  "$(patchset_marker "$(patchset_entries "$SMOKE/patch-lib.sh" | sed -n 3p)")" dsh-termux-cond
check "四段式的前置条件" \
  "$(patchset_precondition "$(patchset_entries "$SMOKE/patch-lib.sh" | sed -n 3p)")" \
  "await link(temporary, target)"
check "两段式的前置条件为空" \
  "$(patchset_precondition "$(patchset_entries "$SMOKE/patch-lib.sh" | sed -n 1p)")" ""
check "按补丁文件名反查 marker" \
  "$(patchset_marker_for_patch "$SMOKE/patch-lib.sh" mid.patch)" dsh-termux-mid
patchset_marker_for_patch "$SMOKE/patch-lib.sh" nope.patch >/dev/null 2>&1; rc=$?
check "无该补丁文件 -> 返回 1" 1 "$rc"
patchset_entries "$SMOKE/nonexistent.sh" >/dev/null 2>&1; rc=$?
check "注册表文件不存在 -> 返回 1，不报错" 1 "$rc"

echo "== 场景 2: 按产物自己声明的 marker 逐条核对"
WORK="$SMOKE/prefix/work"
mkdir -p "$WORK/node_modules/@deepseek-ai/dsh-lib-b/lib" "$WORK/node_modules/@deepseek-ai/dsh-lib-a/lib"
printf '// dsh-termux-mid 在\n' > "$WORK/node_modules/@deepseek-ai/dsh-lib-b/lib/index.js"
printf '// 没有 marker\n' > "$WORK/node_modules/@deepseek-ai/dsh-lib-a/lib/index.js"
patchset_verify_markers "$SMOKE/patch-lib.sh" "$WORK" >/dev/null 2>&1; rc=$?
check "有缺失 marker -> 返回 1" 1 "$rc"
# 条件条目的前置串不在目标里 = 该版本不适用 -> 跳过，不算缺失；
# 但同一目标上那条两段式无条件条目的 marker（platformLinkDenied）必须在场。
printf '// platformLinkDenied\n// 没有 marker\n' > "$WORK/node_modules/@deepseek-ai/dsh-lib-a/lib/index.js"
patchset_verify_markers "$SMOKE/patch-lib.sh" "$WORK" >/dev/null 2>&1; rc=$?
check "条件条目不适用则跳过（其余满足）-> 返回 0" 0 "$rc"
printf '// 没有 marker\n' > "$WORK/node_modules/@deepseek-ai/dsh-lib-b/lib/index.js"
patchset_verify_markers "$SMOKE/patch-lib.sh" "$WORK" >/dev/null 2>&1; rc=$?
check "无条件条目缺 marker -> 返回 1" 1 "$rc"

echo "== 场景 3: wrapper update 钩子的能力派生"
cat > "$SMOKE/common-with-hook.sh" <<'EOF'
write_dsh_wrapper() {
  local updater="${4:-}"
}
EOF
cat > "$SMOKE/common-without-hook.sh" <<'EOF'
write_dsh_wrapper() {
  local target="$1"
}
EOF
check "生成器带第四参 -> 期望 1" 1 "$(wrapper_hook_expected "$SMOKE/common-with-hook.sh")"
check "生成器不带第四参 -> 期望 0" 0 "$(wrapper_hook_expected "$SMOKE/common-without-hook.sh")"
# 产物侧锚点是 common.sh 生成文本里的 `= "update"`，这里用同样的形态伪造
printf 'if [ "$1" = "update" ]; then exec "$updater"; fi\n' > "$SMOKE/wrap-with-hook"
printf 'exec "$node" "$dsh" "$@"\n' > "$SMOKE/wrap-without-hook"
patchset_wrapper_hook_check "$SMOKE/wrap-with-hook" 1 && ok "产物有钩子 + 期望 1 -> 相符" \
  || bad "产物有钩子却被判不符"
patchset_wrapper_hook_check "$SMOKE/wrap-with-hook" 0 >/dev/null 2>&1; rc=$?
check "产物有钩子但期望 0 -> 不符" 1 "$rc"
patchset_wrapper_hook_check "$SMOKE/wrap-without-hook" 1 >/dev/null 2>&1; rc=$?
check "产物无钩子但期望 1 -> 不符" 1 "$rc"
patchset_wrapper_hook_check "$SMOKE/wrap-without-hook" 0 && ok "产物无钩子 + 期望 0 -> 相符" \
  || bad "产物无钩子却被判不符"

echo "== 场景 4: 真注册表（工作区）也要能被文本解析器读懂"
n="$(patchset_entries "$REPO/scripts/patch-lib.sh" | grep -c .)"
[ "$n" -ge 1 ] && ok "工作区注册表解析出 $n 条" || bad "工作区注册表解析失败"
# 反证：文本解析得到的 marker 必须与生产 source 出来的 getter 一致（两条实现不许分叉）
# shellcheck source=../../scripts/patch-lib.sh
. "$REPO/scripts/patch-lib.sh"
mismatch=0
while IFS= read -r entry; do
  [ -n "$entry" ] || continue
  p="$(patchset_patch "$entry")"
  want="$(dsh_patch_marker "$p" 2>/dev/null || true)"
  got="$(patchset_marker "$entry")"
  [ "$want" = "$got" ] || { bad "marker 分叉: $p 文本=$got 生产=$want"; mismatch=1; }
done < <(patchset_entries "$REPO/scripts/patch-lib.sh")
[ "$mismatch" = 0 ] && ok "文本解析与生产 getter 的 marker 逐条一致（${#DSH_PATCH_SET[@]} 条）"

echo
if [ "$FAILED" -eq 0 ]; then
  echo "PATCHSET SMOKE: ALL OK"
else
  echo "PATCHSET SMOKE: $FAILED 项失败" >&2
  exit 1
fi
