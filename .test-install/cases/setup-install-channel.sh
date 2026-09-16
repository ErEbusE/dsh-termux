#!/usr/bin/env bash
# setup-install/channel — 契约: **明确请求的 npm 渠道**能装上，并按契约表现。
#
# 为什么这条必须走 02+03，而不是更新器：`update-dsh.sh` 的补丁集**永远来自最新稳定
# release**（self_update 会拉那个 release 的 patches/ 覆盖 runtime 再 re-exec），于是
# `-t alpha` 的实际含义变成"拿稳定版的补丁去打 alpha 的 lib"——补丁一漂移必红
# （2026-09-08 实测坐实）。渠道测试要的是**两条独立输入**：装哪个渠道、打哪套补丁，
# 各自由自己决定。`02-install-dsh.sh` + `03-apply-patches.sh` 正是这条路。
#
# 由这条 case 暴露的失败（补丁打不上 alpha 的 lib）**应当红**，不许 case_na 掉：
# 那正是"稳定渠道落后于上游"时最该被看见的信号。
#
# 与 `dry-run/pristine-npm` 的分工：那条验"干净树 + 工作区补丁 + SRI 闭环"，渠道是
# 固定的默认目标；这条验"**明确请求的渠道**装上后的表现"。SRI 闭环不在本 case 重复
# 主张（同一结果不得计两份覆盖）。

set -uo pipefail

. "$DSH_TI_DIR/lib/state.sh"
. "$DSH_TI_DIR/lib/receipt.sh"
. "$DSH_HARNESS_ROOT/scripts/common.sh"

case_begin

EVID="$(dirname "$DSH_RESULTS")/evidence-${DSH_CASE_ID//\//-}.txt"
mkdir -p "$(dirname "$EVID")" || case_error "无法创建证据目录"
: > "$EVID" || case_error "无法写证据文件"
say() { printf '%s\n' "$*" | tee -a "$EVID" >&2; }

# --- 1. 请求的渠道（冻结输入） -----------------------------------------------
[ -n "${DSH_NPM_TARGET_FILE:-}" ] || case_unmet "本轮没有冻结的 npm 目标（未解析或解析失败）"
say "== 冻结输入"
say "   spec      ${DSH_NPM_SPEC:-<空>}"
say "   version   ${DSH_NPM_VERSION:-<空>}"
say "   integrity ${DSH_NPM_INTEGRITY:-<空>}"
say "   tarball   ${DSH_NPM_TARBALL:-<空>}"
[ -n "${DSH_NPM_VERSION:-}" ] || case_error "冻结输入缺 version —— 无法断言'装的正是请求的那个'"
case "${DSH_NPM_SPEC:-}" in
  *"@${DSH_NPM_VERSION}") assert_pass "请求的是精确完整 spec（渠道已在解析阶段定型）" ;;
  *) assert_fail "spec 不是精确版本: ${DSH_NPM_SPEC:-<空>} vs ${DSH_NPM_VERSION:-<空>}" ;;
esac

export DSH_ASSUME_YES=1

# --- 2. 工具链: 真实入口 01（渠道 case 也需要一台能跑的 node） ----------------
say "== 01-setup-glibc-node.sh"
if ! bash "$DSH_HARNESS_ROOT/scripts/01-setup-glibc-node.sh" >>"$EVID" 2>&1; then
  assert_fail "01-setup-glibc-node.sh 失败（详见证据文件）"
  case_finish
fi
NODE="$DSH_RUNTIME_DIR/node/bin/node"
[ -x "$NODE" ] && assert_pass "glibc node 就位" || { assert_fail "node 缺失: $NODE"; case_finish; }
NODE_VER="$(run_glibc_node "$NODE" --version 2>/dev/null | tr -d '\r\n')"
[ -n "$NODE_VER" ] && assert_pass "node 可执行 ($NODE_VER)" || { assert_fail "node 无法执行"; case_finish; }

# --- 3. [02] 按请求的渠道装 --------------------------------------------------
say "== 02-install-dsh.sh（DSH_VERSION=$DSH_NPM_SPEC）"
if ! DSH_VERSION="$DSH_NPM_SPEC" bash "$DSH_HARNESS_ROOT/scripts/02-install-dsh.sh" >>"$EVID" 2>&1; then
  assert_fail "02-install-dsh.sh 失败（详见证据文件）"
  case_finish
fi
PKGJSON="$DSH_WORK_DIR/node_modules/@deepseek-ai/dsh/package.json"
[ -f "$PKGJSON" ] || { assert_fail "缺少 $PKGJSON"; case_finish; }
INST_VER="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["version"])' "$PKGJSON" 2>/dev/null)" \
  || { assert_fail "解析已安装 package.json 失败"; case_finish; }
say "   装上来的版本: $INST_VER（请求的渠道定型为 ${DSH_NPM_VERSION}）"
[ "$INST_VER" = "$DSH_NPM_VERSION" ] \
  && assert_pass "装上的版本 == 请求渠道定型出的精确版本 ($INST_VER)" \
  || assert_fail "版本不符: 装上 $INST_VER, 请求渠道定型为 $DSH_NPM_VERSION"

# --- 4. [03] 补丁集：适用性与 marker 都不许写死 ------------------------------
say "== 03-apply-patches.sh"
if ! bash "$DSH_HARNESS_ROOT/scripts/03-apply-patches.sh" >>"$EVID" 2>&1; then
  assert_fail "03-apply-patches.sh 失败（渠道与工作区补丁集不兼容？这正是本 case 要红的场景）"
  case_finish
fi
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
[ "$n_applied" -gt 0 ] && assert_pass "该渠道上有 $n_applied 条补丁适用" \
  || assert_fail "没有任何补丁适用于该渠道 —— 目标可能已偏离支持窗口"
if [ "$n_applied" -gt 0 ]; then
  if dsh_verify_patch_markers "$DSH_WORK_DIR" "${APPLIED[@]}" >>"$EVID" 2>&1; then
    assert_pass "全部 $n_applied 条适用补丁的 marker 都在"
  else
    assert_fail "有适用补丁的 marker 缺失（详见证据文件）"
  fi
fi
if [ "$n_skipped" -gt 0 ]; then
  # 覆盖率缺口必须显式留在证据里：不适用 ≠ 已验证。
  say "   覆盖率缺口: $n_skipped 条条件补丁不适用于 $INST_VER（不适用 ≠ 已验证）: ${SKIPPED%,}"
fi

# --- 5. [04] 接线（stdin 答 y,n：装 PATH、**不**启动 web） -------------------
# ⚠ `DSH_ASSUME_YES` 必须显式关掉再喂 stdin：01/02/03 需要它自动应答，但 04 的最后
# 一问是"现在启动 dsh web 吗"——带着 auto-yes 进去就会**忽略 stdin** 直接 `exec dsh web`
# （首跑实测：它去抢 3080，撞上本机正在用的 GUI，04 以 EADDRINUSE 失败）。自动层不启动
# Web：那是人类实测的事（serve.sh + 人工清单）。旧 r3 之所以没踩到，是因为它的沙箱把
# `DSH_ASSUME_YES` 清掉了，而本 case 为了前三步必须自己 export 它。
say "== 04-run-web.sh（答 y,n：接线要做，web 不在自动层启动）"
if ! printf 'y\nn\n' | DSH_ASSUME_YES=0 bash "$DSH_HARNESS_ROOT/scripts/04-run-web.sh" >>"$EVID" 2>&1; then
  assert_fail "04-run-web.sh 失败（详见证据文件）"
  case_finish
fi
WRAP="$DSH_WORK_DIR/dsh"
OPENER="$DSH_WORK_DIR/dsh-termux-open"
[ -x "$WRAP" ] && assert_pass "wrapper 就位" || assert_fail "wrapper 缺失: $WRAP"
[ -x "$OPENER" ] && assert_pass "opener 就位" || assert_fail "opener 缺失: $OPENER"
[ -L "$DSH_BIN_DIR/dsh" ] && assert_pass "bin 里的 dsh 是 symlink" \
  || assert_fail "symlink 缺失: $DSH_BIN_DIR/dsh"
[ "$(readlink "$DSH_BIN_DIR/dsh" 2>/dev/null)" = "$WRAP" ] \
  && assert_pass "symlink 指向 wrapper" || assert_fail "symlink 目标不对"
grep -q '# dsh-termux' "$HOME/.bashrc" 2>/dev/null && assert_pass ".bashrc 打了 tag" \
  || assert_fail ".bashrc 缺 dsh-termux tag"
grep -qF "export PATH=\"$DSH_BIN_DIR:\$PATH\"" "$HOME/.bashrc" 2>/dev/null \
  && assert_pass ".bashrc 里的 PATH 行正确" || assert_fail ".bashrc 缺 PATH 行"
"$OPENER" </dev/null >/dev/null 2>&1
[ $? -eq 2 ] && assert_pass "opener 无参退出 2" || assert_fail "opener 无参退出码 != 2"

# --- 6. boot：装了补丁的渠道产物真的能启动 -----------------------------------
say "== boot"
BIN="$DSH_WORK_DIR/node_modules/@deepseek-ai/dsh/lib/bin.js"
boot_out="$(run_glibc_node "$NODE" "$BIN" --version 2>&1)"; boot_rc=$?
say "   exit=$boot_rc out=${boot_out//$'\n'/ | }"
[ "$boot_rc" = 0 ] && assert_pass "该渠道 + 工作区补丁集的 dsh 能启动" \
  || assert_fail "dsh 启动失败 (exit $boot_rc): $boot_out"
case "$boot_out" in
  *"$INST_VER"*) assert_pass "启动报出的版本与装上的版本一致" ;;
  *) assert_fail "启动报出的版本不含 $INST_VER: $boot_out" ;;
esac

# --- 7. 耐久证据 -------------------------------------------------------------
FACTS="channel_spec=${DSH_NPM_SPEC} installed=$INST_VER"
FACTS+=" node=${NODE_VER:-?} patches_applied=$n_applied patches_skipped=$n_skipped"
FACTS+=" skipped=${SKIPPED%,} boot=$boot_rc"
say "== 事实: $FACTS"
receipt_case_facts "$DSH_RUN_ID" "$DSH_CASE_ID" "$FACTS" \
  || case_error "必要证据（case-facts）写不进去 —— 本次结论不成立"

case_finish
