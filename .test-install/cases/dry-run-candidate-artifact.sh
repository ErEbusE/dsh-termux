#!/usr/bin/env bash
# dry-run/candidate-artifact — 契约: **分支候选产物**装上工作区补丁集之后能启动、行为正确。
#
# 与 `release-install/candidate-artifact` 的分工（ADR-005）：那条验"按发布物方式安装"
# （走产物自带的 install.sh），这条验"装上之后带工作区补丁集的行为"。同一结果不得
# 重复计为两份覆盖——所以这里**不**重复安装断言。
#
# 产物布局：第 9 项（ADR-006 的分支候选产物 workflow）尚未落地，`release.yml` /
# `pre-release.yml` 目前都**没有**把 runtime 作为 workflow artifact 上传（pre-release
# 只上传 natives）。因此本条 case 现在必然 `case_unmet` —— 那是**正确行为**，不是缺陷。
# 本 case 声明的布局契约（与 pre-release staging 的产物三件套一致）：
#
#     <DSH_CANDIDATE_ARTIFACT>/            （目录，gh run download 的形态）
#       或 <DSH_CANDIDATE_ARTIFACT>        （归档文件，gh api .../zip 或手工 curl 的形态）
#          ├── dsh-termux-runtime.tar.gz
#          ├── install.sh
#          └── VERSION
#
# 资格必须绑定主体（ADR-009）：产物自身的 VERSION 与内容摘要都进 case-facts。

set -uo pipefail

. "$DSH_TI_DIR/lib/state.sh"
. "$DSH_TI_DIR/lib/receipt.sh"
. "$DSH_TI_DIR/lib/patchset.sh"
. "$DSH_TI_DIR/lib/probes.sh"
. "$DSH_HARNESS_ROOT/scripts/common.sh"

case_begin

EVID="$(dirname "$DSH_RESULTS")/evidence-${DSH_CASE_ID//\//-}.txt"
mkdir -p "$(dirname "$EVID")" || case_error "无法创建证据目录"
: > "$EVID" || case_error "无法写证据文件"
say() { printf '%s\n' "$*" | tee -a "$EVID" >&2; }

NODE="$DSH_RUNTIME_DIR/node/bin/node"
TMPD="$DSH_SANDBOX_ROOT/tmp"
mkdir -p "$TMPD" || case_error "无法创建沙箱 tmp"

# --- 1. 物化候选产物（目录或归档；布局契约见文件头） --------------------------
ART="${DSH_CANDIDATE_ARTIFACT:-}"
[ -n "$ART" ] || case_unmet "未提供分支候选产物（DSH_CANDIDATE_ARTIFACT 为空）"
[ -e "$ART" ] || case_unmet "候选产物不存在: $ART"
say "== 候选产物"
say "   来源 $ART"

STAGE="$TMPD/candidate"
rm -rf "$STAGE"; mkdir -p "$STAGE" || case_error "无法创建暂存目录"
ART_ID=""
if [ -d "$ART" ]; then
  ART_KIND="directory"
  ART_ID="$(receipt_tree_id "$ART")"
  cp -R "$ART"/. "$STAGE"/ || { assert_fail "无法复制候选产物目录"; case_finish; }
elif [ -f "$ART" ]; then
  ART_KIND="archive"
  ART_ID="$(sha256sum "$ART" | cut -d' ' -f1)"
  if ! tar -xf "$ART" -C "$STAGE" >>"$EVID" 2>&1; then
    # 归档可能是 zip（gh 的 artifact zip）；只认 tar 是不够的，如实说清楚
    if command -v unzip >/dev/null 2>&1 && unzip -q "$ART" -d "$STAGE" >>"$EVID" 2>&1; then
      :
    else
      assert_fail "无法解开的候选产物归档（既不是 tar 也不是可解的 zip）: $ART"
      case_finish
    fi
  fi
else
  case_unmet "候选产物既不是文件也不是目录: $ART"
fi
say "   kind=$ART_KIND id=$ART_ID"

# 归档里可能再套一层目录（workflow 上传的常见形态）；向下找一次三件套所在的层。
ART_ROOT="$STAGE"
if [ ! -f "$ART_ROOT/dsh-termux-runtime.tar.gz" ]; then
  for d in "$STAGE"/*/; do
    [ -d "$d" ] || continue
    if [ -f "${d}dsh-termux-runtime.tar.gz" ]; then ART_ROOT="${d%/}"; break; fi
  done
fi
MISSING=""
for f in dsh-termux-runtime.tar.gz install.sh VERSION; do
  [ -f "$ART_ROOT/$f" ] || MISSING+="$f "
done
if [ -n "$MISSING" ]; then
  assert_fail "候选产物布局不符（缺: ${MISSING% }）—— 本 case 要求的布局是 <artifact>/{dsh-termux-runtime.tar.gz,install.sh,VERSION}；第 9 项落地时请对齐"
  case_finish
fi
assert_pass "候选产物布局符合本 case 声明的三件套"
say "   层: $ART_ROOT"

# 资格绑定主体：产物自称的 VERSION 必须与**本仓库**一致（否则测的不是这个分支的产物）
ART_VER="$(tr -d '[:space:]' < "$ART_ROOT/VERSION")"
REPO_VER="$(tr -d '[:space:]' < "$DSH_HARNESS_ROOT/VERSION")"
say "   产物 VERSION=$ART_VER  仓库 VERSION=$REPO_VER"
[ "$ART_VER" = "$REPO_VER" ] \
  && assert_pass "产物 VERSION 与本仓库一致（$ART_VER）" \
  || assert_fail "产物 VERSION($ART_VER) != 仓库($REPO_VER) —— 测的不是本分支的产物"

# --- 2. 解出 runtime 树 ------------------------------------------------------
say "== 解出候选 runtime"
if ! tar -xzf "$ART_ROOT/dsh-termux-runtime.tar.gz" -C "$DSH_RUNTIME_DIR" >>"$EVID" 2>&1; then
  assert_fail "候选 runtime tarball 解包失败（详见证据文件）"
  case_finish
fi
[ -x "$NODE" ] && assert_pass "候选 runtime 的 node 就位" \
  || { assert_fail "候选 runtime 缺 node: $NODE"; case_finish; }
[ -d "$DSH_WORK_DIR/node_modules/@deepseek-ai" ] \
  && assert_pass "候选 runtime 依赖树就位" \
  || { assert_fail "候选 runtime 不完整（无 @deepseek-ai 依赖树）"; case_finish; }

# 该 runtime 自带 dsh 版本（浮动值：从树里读，不写死）
PKGJSON="$DSH_WORK_DIR/node_modules/@deepseek-ai/dsh/package.json"
TREE_VER="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["version"])' "$PKGJSON" 2>/dev/null)"
say "   候选 runtime 的 dsh 版本: ${TREE_VER:-<读不到>}"

# --- 3. 工作区补丁集 overlay（与 serve/rebase 同一实现） ---------------------
PRISTINE_TREE="$(receipt_tree_id "$DSH_WORK_DIR")"
say "== 工作区补丁集 overlay"
if patchset_overlay_workspace_patches "$DSH_WORK_DIR" >>"$EVID" 2>&1; then
  assert_pass "工作区补丁集可 overlay 到候选产物树"
else
  assert_fail "工作区补丁集打不进候选产物树（详见证据文件）"
fi
PATCHED_TREE="$(receipt_tree_id "$DSH_WORK_DIR")"
# 同 `dry-run/pinned-rebase`：**不能**断言"前后树身份必须不同"。候选产物若是从本分支
# 的 CI 构建出来的，它本来就带着同一套补丁，overlay 于是幂等、最终树逐字相同——
# 那是好信号。判别器是 marker 齐全 + 行为探针 + boot；身份变化只记成事实。
if [ "$PRISTINE_TREE" = "$PATCHED_TREE" ]; then
  TREE_CHANGED=no
  assert_pass "overlay 幂等：候选产物已带同一套补丁，前后树身份相同"
else
  TREE_CHANGED=yes
  assert_pass "候选产物与工作区补丁集不同，overlay 后树身份已变"
fi

# marker：期望值从工作区注册表派生
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
[ "$n_applied" -gt 0 ] && assert_pass "候选树上有 $n_applied 条工作区补丁适用" \
  || assert_fail "没有工作区补丁适用于候选树"
if [ "$n_applied" -gt 0 ]; then
  dsh_verify_patch_markers "$DSH_WORK_DIR" "${APPLIED[@]}" >>"$EVID" 2>&1 \
    && assert_pass "适用补丁的 marker 齐全" || assert_fail "有适用补丁的 marker 缺失"
fi
[ "$n_skipped" -gt 0 ] && say "   覆盖率缺口: $n_skipped 条不适用（不适用 ≠ 已验证）: ${SKIPPED%,}"

# --- 4. 行为级探针 -----------------------------------------------------------
say "== 行为级探针"
probe_rc=0
probe_patch_set_behaviors "$DSH_WORK_DIR" "$NODE" || probe_rc=1
[ -n "$PROBE_SKIPPED" ] && say "   跳过的探针（不计为已验证）: $PROBE_SKIPPED"

# --- 5. boot -----------------------------------------------------------------
say "== boot"
BIN="$DSH_WORK_DIR/node_modules/@deepseek-ai/dsh/lib/bin.js"
boot_out="$(run_glibc_node "$NODE" "$BIN" --version 2>&1)"; boot_rc=$?
say "   exit=$boot_rc out=${boot_out//$'\n'/ | }"
[ "$boot_rc" = 0 ] && assert_pass "候选产物 + 工作区补丁集能启动" \
  || assert_fail "启动失败 (exit $boot_rc): $boot_out"
if [ -n "${TREE_VER:-}" ]; then
  case "$boot_out" in
    *"$TREE_VER"*) assert_pass "启动报出的版本与树里的 package.json 一致" ;;
    *) assert_fail "启动报出的版本不含 $TREE_VER: $boot_out" ;;
  esac
fi

# --- 6. 耐久证据 -------------------------------------------------------------
FACTS="artifact=${ART##*/} kind=$ART_KIND id=$ART_ID version=$ART_VER tree_dsh=${TREE_VER:-?}"
FACTS+=" applied=$n_applied skipped=$n_skipped probes=$([ "$probe_rc" = 0 ] && echo ok || echo failed)"
FACTS+=" probes_skipped=${PROBE_SKIPPED:-none} boot=$boot_rc"
FACTS+=" pristine_tree=$PRISTINE_TREE patched_tree=$PATCHED_TREE tree_changed=$TREE_CHANGED"
say "== 事实: $FACTS"
receipt_case_facts "$DSH_RUN_ID" "$DSH_CASE_ID" "$FACTS" \
  || case_error "必要证据（case-facts）写不进去 —— 本次结论不成立"

case_finish
