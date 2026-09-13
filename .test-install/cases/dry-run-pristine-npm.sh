#!/usr/bin/env bash
# dry-run/pristine-npm — 契约: 工作区补丁与机件应用到一棵**干净**的 dsh 上,
# 结果在 arm64 上可运行。
#
# 这一条 case 的性质（按 ADR-009 的"现在做"分档）:
#   * 走**真实入口** —— 01 装工具链、02 从 npm 装、03 打工作区补丁，不自己重写一遍；
#   * 装完**先做完整性闭环再打补丁**：不一致就停在这里，不进补丁、不进启动、不许 PASS；
#   * 记录**实际装出来的对象**（lockfile 摘要、补丁前/后树身份、实测 node 版本）,
#     而不是把"顶层包版本"当成整个 runtime 的身份；
#   * 适用/跳过的补丁逐条记录：**"不适用"不偿还正例债务**——跳过是覆盖率缺口，
#     不是"已验证"。
#
# 证据写两处: 运行目录里的详细台账（人要读）, 以及 receipts/case-facts.tsv
# （耐久、只追加——`run.sh clean` 删运行目录也删不掉结论的事实基础）。
# 耐久证据写失败 = 本次结论不成立 -> ERROR。

set -uo pipefail

. "$DSH_TI_DIR/lib/state.sh"
. "$DSH_TI_DIR/lib/receipt.sh"
. "$DSH_TI_DIR/lib/probes.sh"
# common.sh 提供 run_glibc_node / glibc_prefix: 不许在 case 里复制一份
# glibc 前缀的知识，那正是"两份事实源迟早漂移"的经典写法。
. "$DSH_HARNESS_ROOT/scripts/common.sh"

case_begin

EVID="$(dirname "$DSH_RESULTS")/evidence-${DSH_CASE_ID//\//-}.txt"
mkdir -p "$(dirname "$EVID")" || case_error "无法创建证据目录 $(dirname "$EVID")"
: > "$EVID" || case_error "无法写证据文件 $EVID"
say() { printf '%s\n' "$*" | tee -a "$EVID" >&2; }
# 对象身份用库里的 receipt_tree_id（同样被冒烟脚本断言着: 换路径/换时间戳不变、
# 内容变了要变）。case 里不再各写一份。
tree_id() { receipt_tree_id "$1"; }

# --- 1. 具名输入必须已冻结（否则本轮没有可测目标） ---------------------------
[ -n "${DSH_NPM_TARGET_FILE:-}" ] || case_unmet "本轮没有冻结的 npm 目标（未解析或解析失败）"
[ -f "$DSH_NPM_TARGET_FILE" ] || case_error "冻结文件不存在: $DSH_NPM_TARGET_FILE"
say "== 冻结输入"
say "   spec      ${DSH_NPM_SPEC:-<空>}"
say "   integrity ${DSH_NPM_INTEGRITY:-<空>}"
say "   tarball   ${DSH_NPM_TARBALL:-<空>}"
say "   registry  ${DSH_NPM_REGISTRY:-<空>}"
case "${DSH_NPM_SPEC:-}" in
  *"@${DSH_NPM_VERSION:-}") assert_pass "目标是精确完整 spec（不是 dist-tag）" ;;
  *) assert_fail "spec 不是精确版本: ${DSH_NPM_SPEC:-<空>} vs ${DSH_NPM_VERSION:-<空>}" ;;
esac
[ -n "${DSH_NPM_INTEGRITY:-}" ] && assert_pass "冻结输入带 SRI" \
  || assert_fail "冻结输入没有 SRI —— 无法建立完整性闭环"

# --- 2. 沙箱与"干净树"前提 ---------------------------------------------------
say "== 环境"
say "   sandbox   ${DSH_SANDBOX_ROOT:-<空>}"
say "   HOME      ${HOME:-<空>}"
say "   WORK_DIR  ${DSH_WORK_DIR:-<空>}"
case "$HOME" in "$DSH_SANDBOX_ROOT"/*) assert_pass "HOME 在沙箱内" ;; *) assert_fail "HOME 越界: $HOME" ;; esac
case "${DSH_WORK_DIR:-}" in "$DSH_SANDBOX_ROOT"/*) assert_pass "WORK_DIR 在沙箱内" \
  ;; *) assert_fail "WORK_DIR 越界: ${DSH_WORK_DIR:-<空>}" ;; esac
# 干净 = 不继承任何既有安装。这条不成立的话"工作区补丁适用于干净树"根本无从谈起
# （补丁库有"先撤旧集合"的能力，那会让被污染的输入看起来一切正常）。
if [ -e "$DSH_WORK_DIR/node_modules" ] || [ -f "$DSH_WORK_DIR/package-lock.json" ]; then
  assert_fail "工作区不是干净的（已存在 node_modules 或 package-lock.json）"
else
  assert_pass "工作区干净（无 node_modules、无 lockfile）"
fi

export DSH_ASSUME_YES=1

# --- 3. 工具链: 真实入口 01 --------------------------------------------------
say "== 01-setup-glibc-node.sh"
if ! bash "$DSH_HARNESS_ROOT/scripts/01-setup-glibc-node.sh" >>"$EVID" 2>&1; then
  assert_fail "01-setup-glibc-node.sh 失败（详见证据文件）"
  case_finish
fi
NODE="$DSH_RUNTIME_DIR/node/bin/node"
[ -x "$NODE" ] && assert_pass "glibc node 就位" || { assert_fail "node 缺失: $NODE"; case_finish; }
NODE_VER="$(run_glibc_node "$NODE" --version 2>/dev/null | tr -d '\r\n')"
[ -n "$NODE_VER" ] && assert_pass "node 可执行 ($NODE_VER)" || { assert_fail "node 无法执行"; case_finish; }
NPM_VER="$(run_glibc_node "$NODE" \
  "$DSH_RUNTIME_DIR/node/lib/node_modules/npm/bin/npm-cli.js" --version 2>/dev/null | tr -d '\r\n')"
say "   实测 node=$NODE_VER npm=${NPM_VER:-<未知>}"

# --- 4. 真实安装入口 02（把冻结的精确 spec 交给它） ---------------------------
say "== 02-install-dsh.sh（DSH_VERSION=$DSH_NPM_SPEC）"
if ! DSH_VERSION="$DSH_NPM_SPEC" bash "$DSH_HARNESS_ROOT/scripts/02-install-dsh.sh" >>"$EVID" 2>&1; then
  assert_fail "02-install-dsh.sh 失败（详见证据文件）"
  case_finish
fi

# --- 5. 完整性闭环（**在打补丁之前**） ---------------------------------------
# 证明链: 真实 npm 校验下载字节符合它取到的 metadata integrity; 测试再校验
# npm **实际采用**的那条 integrity 就是冻结的 expected SRI。结论是"错误字节
# 不能获得通过结论", 不是"错误字节从未落盘"（要后者才需要受控下载通道）。
# 不许声称"仅读 lockfile 就独立验证了下载字节" —— lock 是 npm 的执行证据。
say "== 完整性闭环"
LOCK="$DSH_WORK_DIR/package-lock.json"
PKGJSON="$DSH_WORK_DIR/node_modules/@deepseek-ai/dsh/package.json"
[ -f "$LOCK" ] && assert_pass "npm 产出了 package-lock.json" \
  || { assert_fail "没有 package-lock.json —— 无法建立完整性证据链（不接受只看包版本）"; case_finish; }
[ -f "$PKGJSON" ] && assert_pass "已安装 dsh 的 package.json 存在" \
  || { assert_fail "缺少 $PKGJSON"; case_finish; }

parsed="$(python3 -c '
import json, sys
lock = json.load(open(sys.argv[1], encoding="utf-8"))
entry = (lock.get("packages") or {}).get("node_modules/@deepseek-ai/dsh")
if entry is None:
    print("MISSING\t\t"); sys.exit(0)
print("%s\t%s\t%s" % (entry.get("version") or "", entry.get("integrity") or "",
                      entry.get("resolved") or ""))
' "$LOCK")" || { assert_fail "解析 package-lock.json 失败"; case_finish; }
LVER="${parsed%%$'\t'*}"; rest="${parsed#*$'\t'}"; LINT="${rest%%$'\t'*}"; LRES="${rest#*$'\t'}"
say "   lock: version=$LVER"
say "   lock: integrity=${LINT:-<缺>}"
say "   lock: resolved=$LRES"

[ "$LVER" = "$DSH_NPM_VERSION" ] && assert_pass "装上来的版本 == 冻结目标 ($LVER)" \
  || assert_fail "版本不符: 装上 $LVER, 冻结 ${DSH_NPM_VERSION}"
# 缺 integrity 一律失败: **绝不退化成"只看版本"**——那等于把 SRI 闭环整个删掉。
[ -n "$LINT" ] && assert_pass "lock 记录了 integrity" \
  || assert_fail "lock 里没有 integrity —— 拒绝退化为版本检查"
[ "$LINT" = "$DSH_NPM_INTEGRITY" ] && assert_pass "npm 实际采用的 SRI == 冻结的 expected SRI" \
  || assert_fail "SRI 不符: npm 用 $LINT, 冻结 $DSH_NPM_INTEGRITY"
[ "$LRES" = "$DSH_NPM_TARBALL" ] && assert_pass "下载来源 == 冻结的 tarball" \
  || assert_fail "来源不符: 装上 $LRES, 冻结 $DSH_NPM_TARBALL"

pkg_ids="$(python3 -c '
import json, sys
p = json.load(open(sys.argv[1], encoding="utf-8"))
print("%s\t%s" % (p.get("name") or "", p.get("version") or ""))
' "$PKGJSON")" || { assert_fail "解析已安装 package.json 失败"; case_finish; }
PNAME="${pkg_ids%%$'\t'*}"; PVER="${pkg_ids#*$'\t'}"
[ "$PNAME" = "@deepseek-ai/dsh" ] && assert_pass "已安装包名正确" || assert_fail "包名异常: $PNAME"
[ "$PVER" = "$DSH_NPM_VERSION" ] && assert_pass "已安装包版本正确 ($PVER)" \
  || assert_fail "已安装包版本异常: $PVER"

LOCK_ID="$(sha256sum "$LOCK" | cut -d' ' -f1)"
PRISTINE_TREE_ID="$(tree_id "$DSH_WORK_DIR")"
say "   补丁前: lock=$LOCK_ID tree=$PRISTINE_TREE_ID"

# --- 6. 真实补丁入口 03 + 独立复核适用性与 marker ----------------------------
say "== 03-apply-patches.sh"
if ! bash "$DSH_HARNESS_ROOT/scripts/03-apply-patches.sh" >>"$EVID" 2>&1; then
  assert_fail "03-apply-patches.sh 失败（详见证据文件）"
  case_finish
fi
# 独立复核: 不信 03 的自述, 自己按 DSH_PATCH_SET 重算一遍适用性。
# shellcheck source=../../scripts/patch-lib.sh
. "$DSH_HARNESS_ROOT/scripts/patch-lib.sh"
APPLIED=(); SKIPPED=""
n_applied=0; n_skipped=0
for entry in "${DSH_PATCH_SET[@]}"; do
  if dsh_patch_applicable "$DSH_WORK_DIR" "$entry"; then
    APPLIED+=("$entry"); n_applied=$((n_applied + 1))
  else
    n_skipped=$((n_skipped + 1)); SKIPPED+="${entry%%:*},"
  fi
done
say "   适用补丁 $n_applied 条, 跳过 $n_skipped 条"
[ "$n_applied" -gt 0 ] && assert_pass "本目标版本适用 $n_applied 条补丁" \
  || assert_fail "没有任何补丁适用于本版本 —— 目标可能已偏离支持窗口"
if [ "$n_applied" -gt 0 ]; then
  if dsh_verify_patch_markers "$DSH_WORK_DIR" "${APPLIED[@]}" >>"$EVID" 2>&1; then
    assert_pass "全部 $n_applied 条适用补丁的 marker 都在"
  else
    assert_fail "有适用补丁的 marker 缺失（详见证据文件）"
  fi
fi
if [ "$n_skipped" -gt 0 ]; then
  # 覆盖率缺口必须显式留在证据里: "不适用"不是"已验证"。
  say "   覆盖率缺口: $n_skipped 条条件补丁不适用于 $DSH_NPM_VERSION（不适用 ≠ 已验证）: ${SKIPPED%,}"
fi
PATCHED_TREE_ID="$(tree_id "$DSH_WORK_DIR")"
[ "$PRISTINE_TREE_ID" != "$PATCHED_TREE_ID" ] \
  && assert_pass "补丁前后树身份不同（补丁真的落地了）" \
  || assert_fail "补丁前后树身份相同 —— 补丁可能一条都没打上"

# --- 6b. 行为级探针（marker 只证明"文件变过"，这里证明"行为对了"） -------------
# 三个探针的触发 marker 全部从**刚 source 的这份注册表**按补丁目标 rel 派生
# （旧体系审计 H2 的缺陷：探针里写死 marker 串，改名后行为覆盖静默降级成 note）。
# 跳过会进 case-facts —— 跳过不是已验证，覆盖率缺口必须留在证据里。
say "== 行为级探针"
probe_rc=0
probe_patch_set_behaviors "$DSH_WORK_DIR" "$NODE" || probe_rc=1
if [ -n "$PROBE_SKIPPED" ]; then
  say "   跳过的探针（不计为已验证）: $PROBE_SKIPPED"
fi

# --- 7. arm64 启动 -----------------------------------------------------------
say "== boot"
BIN="$DSH_WORK_DIR/node_modules/@deepseek-ai/dsh/lib/bin.js"
boot_out="$(run_glibc_node "$NODE" "$BIN" --version 2>&1)"; boot_rc=$?
say "   exit=$boot_rc out=${boot_out//$'\n'/ | }"
[ "$boot_rc" = 0 ] && assert_pass "打了补丁的 dsh 能启动" \
  || assert_fail "dsh 启动失败 (exit $boot_rc): $boot_out"
case "$boot_out" in
  *"$DSH_NPM_VERSION"*) assert_pass "启动报出的版本与冻结目标一致" ;;
  *) assert_fail "启动报出的版本不含 $DSH_NPM_VERSION: $boot_out" ;;
esac

# --- 8. 耐久证据 -------------------------------------------------------------
FACTS="npm=${DSH_NPM_SPEC} integrity_match=$([ "$LINT" = "$DSH_NPM_INTEGRITY" ] && echo yes || echo no)"
FACTS+=" node=${NODE_VER:-?} npm_cli=${NPM_VER:-?}"
FACTS+=" patches_applied=$n_applied patches_skipped=$n_skipped"
FACTS+=" probes=$([ "$probe_rc" = 0 ] && echo ok || echo failed) probes_skipped=${PROBE_SKIPPED:-none}"
FACTS+=" boot=$boot_rc lock=$LOCK_ID pristine_tree=$PRISTINE_TREE_ID patched_tree=$PATCHED_TREE_ID"
say "== 事实: $FACTS"
receipt_case_facts "$DSH_RUN_ID" "$DSH_CASE_ID" "$FACTS" \
  || case_error "必要证据（case-facts）写不进去 —— 本次结论不成立"

case_finish
