#!/usr/bin/env bash
# dry-run/pinned-rebase — 契约: 一棵**发布物后像**的树 rebase 到工作区补丁集之后，
# 仍然行为正确。
#
# 这条 case 的存在理由是一次真机事故（2026-09-08）：逐版本 pristine 矩阵与 CI 全绿，
# 人类一跑 serve.sh 就被拒绝启动 —— 因为当时 serve.sh 会把**工作区那一套**补丁压到
# 「发版时用旧补丁打出来的树」上，而补丁被改写过后既退不掉旧 post-image 又打不上，
# 结论却被报成上游「版本漂移」。旧体系里这条判定只存在于 serve.sh，也就是**只有
# 拿手机的人能发现**。现在它是一条 case，走**同一个实现**
# （`lib/patchset.sh` 的 `patchset_overlay_workspace_patches`）；serve.sh 已按
# ADR-010 改成只启动冻结对象、不再 overlay，所以这条 case 就是该次序的唯一消费者。
#
# 与 `release-install/workspace-installer` 的分工：那条验"安装器接线"，这条验
# "已发布后像 + 工作区补丁集的组合结果与行为"。同一结果不得重复计为两份覆盖。
#
# ADR-005 的硬约束：本 case **不是**在证明新版本兼容性。请求的目标版本与种子实际
# 版本不符时**硬拒绝**，报告必须写明"不证明新版本兼容性"。

set -uo pipefail

. "$DSH_TI_DIR/lib/state.sh"
. "$DSH_TI_DIR/lib/receipt.sh"
. "$DSH_TI_DIR/lib/seed.sh"
. "$DSH_TI_DIR/lib/patchset.sh"
. "$DSH_TI_DIR/lib/probes.sh"
. "$DSH_HARNESS_ROOT/scripts/common.sh"

case_begin

EVID="$(dirname "$DSH_RESULTS")/evidence-${DSH_CASE_ID//\//-}.txt"
mkdir -p "$(dirname "$EVID")" || case_error "无法创建证据目录"
: > "$EVID" || case_error "无法写证据文件"
say() { printf '%s\n' "$*" | tee -a "$EVID" >&2; }

NODE="$DSH_RUNTIME_DIR/node/bin/node"

# --- 1. 种子：这是"发布物后像"的唯一来源 -------------------------------------
if ! seed_load "$(seed_default_name)"; then
  assert_fail "种子不可用（缺件或哈希与事实源不符）—— 见上文原因"
  case_finish
fi
say "== 种子"
say "   tag       $SEED_TAG"
say "   dsh       $SEED_DSH_VERSION"
say "   资产      ${SEED_ASSETS[*]}"

TARBALL="$(seed_asset_by_name dsh-termux-runtime.tar.gz)" \
  || { assert_fail "种子里没有 dsh-termux-runtime.tar.gz"; case_finish; }

# ADR-005：请求的目标与种子不符 = 这条 case 测的不是它声称的东西 -> 硬拒绝。
# `DSH_RELEASE_TAG` 是本轮的发布物输入实例（ADR-011）；未指定时就是种子自己。
WANT_TAG="${DSH_RELEASE_TAG:-$SEED_TAG}"
say "   本轮发布物实例: $WANT_TAG"
if [ "$WANT_TAG" != "$SEED_TAG" ]; then
  assert_fail "请求的发布物实例是 $WANT_TAG，种子是 $SEED_TAG：" \
    "本 case 只证明种子那一版的组合结果，**不证明新版本兼容性**（ADR-005）"
  case_finish
fi

# --- 2. 解出"后像"树 ---------------------------------------------------------
say "== 解出发布物后像"
if ! tar -xzf "$TARBALL" -C "$DSH_RUNTIME_DIR" >>"$EVID" 2>&1; then
  assert_fail "tarball 解包失败（详见证据文件）"
  case_finish
fi
[ -x "$NODE" ] && assert_pass "种子 node 就位" || { assert_fail "种子 node 缺失: $NODE"; case_finish; }
[ -d "$DSH_WORK_DIR/node_modules/@deepseek-ai" ] \
  && assert_pass "后像树就位（含 @deepseek-ai 依赖树）" \
  || { assert_fail "后像树不完整: $DSH_WORK_DIR/node_modules/@deepseek-ai 缺失"; case_finish; }

# 后像树自带的注册表与补丁集 —— overlay 的第 1 步要用它们逐条回退
[ -f "$DSH_RUNTIME_DIR/scripts/patch-lib.sh" ] \
  && assert_pass "后像树自带 patch-lib.sh（overlay 回退步的依据）" \
  || assert_fail "后像树缺 scripts/patch-lib.sh —— 无法回退 shipped 集"
SHIPPED_N="$(patchset_entries "$DSH_RUNTIME_DIR/scripts/patch-lib.sh" 2>/dev/null | grep -c . || true)"
[ "${SHIPPED_N:-0}" -ge 1 ] && assert_pass "后像树声明了 $SHIPPED_N 条 shipped 补丁" \
  || assert_fail "后像树的 patch-lib.sh 没有 DSH_PATCH_SET 条目（打包回归）"

# --- 2b. 让发布物的 node 变成"可直连"（这一步不能省） ------------------------
# 发布物 tarball 里的 node 是**未补丁**的：设 glibc interpreter 是安装器
# （`install.sh` → `configure_glibc_node`）与更新器的活。本 case 只解包、不跑安装器
# （安装断言是 `release-install/workspace-installer` 的契约，不在这里重复），所以必须
# 自己做这一步 —— 否则任何"用被测树的 node 跑点东西"都会以
# `env: '…/node': No such file or directory`（exit 127）假红：那不是补丁或 overlay 的
# 问题，是**动态装载器缺失**的经典症状（首跑实测撞到，整条 case 因此全红）。
# 它幂等：已经是 glibc loader 时只打印一句 "already configured"。
say "== 配置 node 直连（发布物未补丁；本 case 不跑安装器）"
if configure_glibc_node "$NODE" >>"$EVID" 2>&1; then
  assert_pass "node 已配成 glibc 直连（configure_glibc_node，与安装器同一实现）"
else
  assert_fail "configure_glibc_node 失败（详见证据文件）—— 后续行为证据都无从谈起"
fi
node_ver="$(run_glibc_node "$NODE" --version 2>&1)"; node_rc=$?
[ "$node_rc" = 0 ] && assert_pass "node 可直连运行 ($node_ver)" \
  || assert_fail "node 无法直连运行 (exit $node_rc): $node_ver"

PRISTINE_TREE="$(receipt_tree_id "$DSH_WORK_DIR")"
say "   overlay 前 tree=$PRISTINE_TREE"
# --- 3. overlay：先退 shipped 集，再打工作区集（生产同一实现） ----------------
say "== 工作区补丁集 overlay"
if patchset_overlay_workspace_patches "$DSH_WORK_DIR" >>"$EVID" 2>&1; then
  assert_pass "工作区补丁集可 overlay 到后像树（install/update/发版构建的同一实现）"
else
  assert_fail "工作区补丁集打不进后像树（详见证据文件）"
fi

PATCHED_TREE="$(receipt_tree_id "$DSH_WORK_DIR")"
# ⚠ 这里**不能**断言"前后树身份必须不同"。工作区补丁集与发布物自带那一套**内容一致**
# 时（常态：发布后没人改补丁），overlay = 先退旧集再打同内容的新集 = **幂等**，最终树
# 与原后像逐字相同 —— 那是好信号，不是"一条都没打上"。真正的判别器是 marker 齐全 +
# 行为探针 + boot：补丁没打上时它们必红。身份变化只在"工作区改写过补丁"时出现，
# 所以这里把它**记成事实**（tree_changed=yes/no）而不是当成断言。
if [ "$PRISTINE_TREE" = "$PATCHED_TREE" ]; then
  TREE_CHANGED=no
  assert_pass "rebase 幂等：工作区集与发布物集内容一致，前后树身份相同（$PRISTINE_TREE）"
else
  TREE_CHANGED=yes
  assert_pass "工作区集与发布物集不同（补丁被改写过），rebase 后树身份已变"
fi

# --- 4. 工作区注册表的 marker（适用性独立复核） ------------------------------
say "== 工作区注册表 marker"
# shellcheck source=../../scripts/patch-lib.sh
. "$DSH_HARNESS_ROOT/scripts/patch-lib.sh"
APPLIED=(); n_applied=0; n_skipped=0; SKIPPED=""
for entry in "${DSH_PATCH_SET[@]}"; do
  if dsh_patch_applicable "$DSH_WORK_DIR" "$entry"; then
    APPLIED+=("$entry"); n_applied=$((n_applied + 1))
  else
    n_skipped=$((n_skipped + 1)); SKIPPED+="${entry%%:*},"
  fi
done
say "   适用 $n_applied 条, 跳过 $n_skipped 条"
[ "$n_applied" -gt 0 ] && assert_pass "rebase 后适用 $n_applied 条工作区补丁" \
  || assert_fail "没有任何工作区补丁适用于这棵树 —— 组合结果无从谈起"
if [ "$n_applied" -gt 0 ]; then
  if dsh_verify_patch_markers "$DSH_WORK_DIR" "${APPLIED[@]}" >>"$EVID" 2>&1; then
    assert_pass "全部 $n_applied 条适用补丁的 marker 都在"
  else
    assert_fail "有适用补丁的 marker 缺失（详见证据文件）"
  fi
fi
if [ "$n_skipped" -gt 0 ]; then
  say "   覆盖率缺口: $n_skipped 条不适用于 $SEED_DSH_VERSION（不适用 ≠ 已验证）: ${SKIPPED%,}"
fi

# --- 5. 行为级证据 -----------------------------------------------------------
say "== 行为级探针"
probe_rc=0
probe_patch_set_behaviors "$DSH_WORK_DIR" "$NODE" || probe_rc=1
if [ -n "$PROBE_SKIPPED" ]; then
  say "   跳过的探针（不计为已验证）: $PROBE_SKIPPED"
fi

# --- 6. boot -----------------------------------------------------------------
say "== boot"
BIN="$DSH_WORK_DIR/node_modules/@deepseek-ai/dsh/lib/bin.js"
boot_out="$(run_glibc_node "$NODE" "$BIN" --version 2>&1)"; boot_rc=$?
say "   exit=$boot_rc out=${boot_out//$'\n'/ | }"
[ "$boot_rc" = 0 ] && assert_pass "rebase 后的 dsh 能启动" \
  || assert_fail "rebase 后的 dsh 启动失败 (exit $boot_rc): $boot_out"
case "$boot_out" in
  *"$SEED_DSH_VERSION"*) assert_pass "启动报出的版本与种子一致（$SEED_DSH_VERSION）" ;;
  *) assert_fail "启动报出的版本不含 $SEED_DSH_VERSION: $boot_out" ;;
esac

# --- 7. 耐久证据 -------------------------------------------------------------
FACTS="seed=${SEED_TAG} dsh=${SEED_DSH_VERSION} shipped_patches=${SHIPPED_N:-0}"
FACTS+=" applied=$n_applied skipped=$n_skipped"
FACTS+=" probes=$([ "$probe_rc" = 0 ] && echo ok || echo failed) probes_skipped=${PROBE_SKIPPED:-none}"
FACTS+=" boot=$boot_rc pristine_tree=$PRISTINE_TREE patched_tree=$PATCHED_TREE tree_changed=$TREE_CHANGED"
FACTS+=" release_instance=${WANT_TAG}"
say "== 事实: $FACTS"
receipt_case_facts "$DSH_RUN_ID" "$DSH_CASE_ID" "$FACTS" \
  || case_error "必要证据（case-facts）写不进去 —— 本次结论不成立"

case_finish
