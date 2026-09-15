#!/usr/bin/env bash
# update/support-floor — 契约: 低于支持下限（`dsh >= 0.1.5-alpha.1`）的 npm 目标，在
# **两个入口**（工作区 `scripts/update-dsh.sh` 与 `scripts/02-install-dsh.sh`）上都被
# 在 npm 改写安装树**之前**拒绝，拒绝时安装树原封不动，且消息给出理由与可用的替代路径。
#
# 为什么必须有这条 case（11c）：11b 删掉原生件机件之后，npm 路径装 dsh 0.1.3/0.1.4 会
# 得到"装得上、起不来"的树（那两代需要 `fs_ext.node`）。在这个门禁存在之前，那是一次
# **静默降级**——用户拿到的是一个更新"成功"了的坏 runtime。
#
# 与其它 update case 的分工（同一结果不得计两份覆盖）:
#   * update/workspace-updater —— 窗口内的目标**真的装成功**（正向路径）；
#   * update/failure-recovery  —— 失败/中断后的树与用户数据；
#   * 本 case 只证明"该拒绝的被拒绝、且没有副作用"。
#
# 范围限定（写进 case-facts，不进交付结论之外）: 更新器那两次运行带 `DSH_SELF_DONE=1`，
# 即**跳过自动机件刷新分支**（那条分支会先换掉更新器本身再 re-exec；它的行为归
# `update/refresh-machinery`）。门禁位于目标解析处，刷新分支在它之前，但两者都只改
# **本项目自己的脚本**、不碰 npm 树——被断言的对象（安装树）与顺序无关。
#
# 触发下限的是**工作区**的版本策略，所以这里 source 工作区 `scripts/common.sh` 是
# 正当的（对比：`release-install/shipped-release` 曾用工作区注册表去判 **shipped**
# 产物，那条断言已被 11b 删除）。

set -uo pipefail

. "$DSH_TI_DIR/lib/state.sh"
. "$DSH_TI_DIR/lib/receipt.sh"
. "$DSH_TI_DIR/lib/seed.sh"
# 被测策略本身：版本比较与拒绝文案都在这里（不在 case 里复制一份）。
# shellcheck source=../../scripts/common.sh
. "$DSH_HARNESS_ROOT/scripts/common.sh"

case_begin

EVID="$(dirname "$DSH_RESULTS")/evidence-${DSH_CASE_ID//\//-}.txt"
mkdir -p "$(dirname "$EVID")" || case_error "无法创建证据目录 $(dirname "$EVID")"
: > "$EVID" || case_error "无法写证据文件 $EVID"
say() { printf '%s\n' "$*" | tee -a "$EVID" >&2; }

REPO="$DSH_HARNESS_ROOT"
WORK="$DSH_WORK_DIR"
NODE="$DSH_RUNTIME_DIR/node/bin/node"
NPM_REAL="$DSH_RUNTIME_DIR/node/lib/node_modules/npm/bin/npm-cli.js"
TMP="$DSH_SANDBOX_ROOT/tmp"
mkdir -p "$TMP" || case_error "无法创建沙箱 tmp: $TMP"   # Termux 禁访系统 /tmp
NPM_LOG="$TMP/npm-calls.log"
: > "$NPM_LOG"

# --- 0. 前置 ------------------------------------------------------------------
for t in patchelf readelf; do
  command -v "$t" >/dev/null 2>&1 \
    || case_unmet "需要 $t（glibc-runner：configure_glibc_node 与 node 解释器）"
done
LOADER="$(ls "$(glibc_prefix)"/lib/ld-linux-*.so.* 2>/dev/null | head -1 || true)"
[ -n "$LOADER" ] || case_unmet "本机没有 glibc loader（$(glibc_prefix)/lib）"

seed_name="$(seed_default_name)"
seed_rc=0
seed_load "$seed_name" || seed_rc=$?
case "$seed_rc" in
  0) ;;
  1) assert_fail "种子不可用（缺件或资产哈希与事实源不符，见上文原因）"; case_finish ;;
  *) if [ -f "$(seed_env_path "$seed_name")" ]; then
       case_error "种子事实源自身损坏（生成/配置故障，见上文原因）"
     else
       case_unmet "缺少种子事实源 seeds/$seed_name.env（run.sh seed set 生成）"
     fi ;;
esac
say "== 种子 $SEED_TAG（dsh $SEED_DSH_VERSION）"
TARBALL="$(seed_asset_by_name dsh-termux-runtime.tar.gz)" \
  || case_error "种子事实源没有 dsh-termux-runtime.tar.gz（发布约定缺件）"
tar -xzf "$TARBALL" -C "$DSH_RUNTIME_DIR" >>"$EVID" 2>&1 \
  || { assert_fail "种子 tarball 解包失败（详见证据文件）"; case_finish; }
# 先解包再查 npm：这两个路径都在 tarball 里，解包前查只会得到一句假 UNMET。
[ -f "$NPM_REAL" ] || case_unmet "种子 runtime 里没有 npm（$NPM_REAL）——无法建立调用记录"
[ -x "$NODE" ] || { assert_fail "种子 node 缺失: $NODE"; case_finish; }
configure_glibc_node "$NODE" >>"$EVID" 2>&1 \
  || { assert_fail "configure_glibc_node 失败（种子 node 无法直连运行）"; case_finish; }
assert_pass "种子 runtime 解包并就位（含 npm）"

# --- 1. 下限判定本身（纯函数，边界表） ----------------------------------------
# 边界：窗口外的一律拒绝；阈值本身、其后的一切 prerelease 与正式版放行。
# 0.1.5-alpha.0 < 0.1.5-alpha.1 < 0.1.5-alpha.10 < 0.1.5-beta < 0.1.5-rc.1 < 0.1.5。
say "== 下限边界表（阈值 $DSH_NPM_SUPPORT_FLOOR）"
floor_case() { # <期望 0=拒绝/1=放行/3=不可判定> <版本>
  local want="$1" v="$2" got=0
  dsh_version_below_floor "$v" || got=$?
  case "$want:$got" in
    0:0) assert_pass "拒绝窗口外目标 $v" ;;
    1:1) assert_pass "放行窗口内目标 $v" ;;
    3:3) assert_pass "不可解析的目标按拒绝处理 $v" ;;
    *)   assert_fail "下限判定错误: $v -> $got（期望 $want）" ;;
  esac
}
for v in 0.1.0-rc.8 0.1.2 0.1.3-alpha.2 0.1.4 0.1.5-alpha.0; do floor_case 0 "$v"; done
for v in 0.1.5-alpha.1 0.1.5-alpha.2 0.1.5-alpha.10 0.1.5-beta 0.1.5-rc.1 0.1.5 0.1.6-alpha.1; do
  floor_case 1 "$v"
done
for v in latest "" 0.1 0.1.5.6 0.1.x 1.2.3-; do floor_case 3 "$v"; done

cmp_case() { # <a> <b> <期望 1=a>b / 2=a<b / 0=相等>
  local got=0; dsh_version_cmp "$1" "$2" || got=$?
  [ "$got" = "$3" ] && assert_pass "semver 优先级 $1 vs $2 = $got" \
    || assert_fail "semver 优先级错误: $1 vs $2 -> $got（期望 $3）"
}
cmp_case 0.1.5-alpha.2 0.1.5-alpha.10 2     # 数字段按数值比，不按字典序
cmp_case 0.1.5-rc.1 0.1.5 2                 # 有 prerelease < 无 prerelease
cmp_case 0.1.5+build 0.1.5 0                # 构建元数据不参与优先级

# --- 2. 调用记录器（仪器自检） -------------------------------------------------
# 把 sandbox 里的 npm-cli.js 换成"先记账、再委派真 npm"的壳。这样"拒绝时没有调用
# npm"就从推断变成**可观测事实**，而不是只看退出码。
mv "$NPM_REAL" "${NPM_REAL%.js}.real.js" || case_error "无法为 npm 装记录壳（mv 失败）"
cat >"$NPM_REAL" <<'JS'
// 测试仪器：记录调用参数后委派真正的 npm（update/support-floor）。
const fs = require("fs"), path = require("path");
const log = process.env.DSH_NPM_CALL_LOG;
if (log) fs.appendFileSync(log, process.argv.slice(2).join(" ") + "\n");
require(path.join(__dirname, "npm-cli.real.js"));
JS
DSH_NPM_CALL_LOG="$NPM_LOG" run_glibc_node "$NODE" "$NPM_REAL" --version >>"$EVID" 2>&1 \
  || case_error "记录壳自身跑不起来（仪器故障，结论无效）"
if grep -q '^--version$' "$NPM_LOG"; then
  assert_pass "调用记录器有效（直接调用被记下）"
else
  assert_fail "调用记录器没记下直接调用 —— 后续'没调用 npm'的断言不成立"
  case_finish
fi
: >"$NPM_LOG"

# 安装树的基线（在 configure_glibc_node 之后取，node 二进制不在 work/ 里）。
TREE_BEFORE="$(receipt_tree_id "$WORK")"
say "   安装树基线 $TREE_BEFORE"

# --- 3. 入口 A：工作区更新器 --------------------------------------------------
# DSH_SELF_DONE=1 = 跳过自动机件刷新（那条分支归 update/refresh-machinery），
# 让本次运行专注于"目标被拒绝"这一段。
say "== 入口 A: scripts/update-dsh.sh -v 0.1.4"
LOG_A="$TMP/updater-refusal.log"
rc_a=0
DSH_SELF_DONE=1 bash "$REPO/scripts/update-dsh.sh" -v 0.1.4 -y >"$LOG_A" 2>&1 || rc_a=$?
{ echo "--- 入口 A 日志 ---"; cat "$LOG_A"; } >>"$EVID"
[ "$rc_a" != 0 ] && assert_pass "低于下限的更新目标被拒绝（exit=$rc_a）" \
  || assert_fail "低于下限的更新目标被接受了（exit=0）"
if grep -q '^install ' "$NPM_LOG"; then
  assert_fail "拒绝时仍然调用了 npm install: $(grep '^install ' "$NPM_LOG" | head -1)"
else
  assert_pass "拒绝发生在 npm install 之前（调用记录里没有 install）"
fi
grep -qF "$DSH_NPM_SUPPORT_FLOOR" "$LOG_A" \
  && assert_pass "拒绝消息点明了下限（$DSH_NPM_SUPPORT_FLOOR）" \
  || assert_fail "拒绝消息没有给出下限版本"
grep -qiF 'fs-ext' "$LOG_A" \
  && assert_pass "拒绝消息给出了理由（缺少的原生件）" \
  || assert_fail "拒绝消息没有说明为什么不能装"
grep -qF 'install.sh -p' "$LOG_A" && grep -qF 'DSH_RELEASE=' "$LOG_A" \
  && assert_pass "拒绝消息给出了可用的替代路径（tarball 入口）" \
  || assert_fail "拒绝消息没有给出可照做的替代路径"
grep -qF "$DSH_REPO/releases" "$LOG_A" \
  && assert_pass "替代路径带上了「先确认存在对应 release」的条件" \
  || assert_fail "替代路径没有说明「npm 有版本 != 有对应 release」"

TREE_AFTER_A="$(receipt_tree_id "$WORK")"
[ "$TREE_AFTER_A" = "$TREE_BEFORE" ] \
  && assert_pass "拒绝后安装树逐字未变" \
  || assert_fail "拒绝却改动了安装树: $TREE_BEFORE -> $TREE_AFTER_A"

# --- 4. 入口 A：解析不了的目标 / 指向窗口外的 tag（tag 路径） -------------------
say "== 入口 A: 解析失败与 tag 路径"
LOG_T="$TMP/updater-unknown-tag.log"
rc_t=0
DSH_SELF_DONE=1 bash "$REPO/scripts/update-dsh.sh" -t definitely-not-a-dist-tag -y \
  >"$LOG_T" 2>&1 || rc_t=$?
{ echo "--- 未知 tag 日志 ---"; cat "$LOG_T"; } >>"$EVID"
[ "$rc_t" != 0 ] && assert_pass "解析不了的目标被拒绝（exit=$rc_t）" \
  || assert_fail "解析不了的目标被交给了 npm（exit=0）"
grep -qF 'Cannot resolve' "$LOG_T" \
  && assert_pass "解析失败给出明确原因" || assert_fail "解析失败没有给出原因"
if grep -q '^install ' "$NPM_LOG"; then
  assert_fail "解析失败的路径仍然调用了 npm install"
else
  assert_pass "解析失败发生在 npm install 之前"
fi

# tag→版本→下限这条路：用假 dist-tags blob 走同一个 resolver（真 registry 此刻
# 没有指向上限以下的 tag，所以这一步是单元级证据，不冒充端到端）。
resolved="$(dsh_resolve_target_version '@deepseek-ai/dsh@oldstable' \
  "$NODE" "$NPM_REAL" "{ oldstable: '0.1.4' }" || true)"
[ "$resolved" = "0.1.4" ] \
  && assert_pass "tag 被解析成精确版本（oldstable -> $resolved）" \
  || assert_fail "tag 未解析成精确版本（得到 '$resolved'）"
below=0; dsh_version_below_floor "$resolved" || below=$?
[ "$below" = 0 ] \
  && assert_pass "该 tag 指向的版本会被同一条下限判定拒绝" \
  || assert_fail "指向 0.1.4 的 tag 没有被判为窗口外（$below）"

# 窗口内的 tag：解析必须落到**精确版本**，并把它（而不是原 tag）交给 npm。
LOG_OK="$TMP/updater-in-window-tag.log"
rc_ok=0
printf 'n\n' | DSH_SELF_DONE=1 DSH_ASSUME_YES=0 bash "$REPO/scripts/update-dsh.sh" -t alpha \
  >"$LOG_OK" 2>&1 || rc_ok=$?
{ echo "--- 窗口内 tag（已谢绝安装）日志 ---"; cat "$LOG_OK"; } >>"$EVID"
[ "$rc_ok" != 0 ] && assert_pass "在确认提示上答 n 后干净退出（exit=$rc_ok）" \
  || assert_fail "答 n 之后仍然退出 0（应答没有生效）"
grep -qE '^==> Target: @deepseek-ai/dsh@[0-9]+\.[0-9]+\.[0-9]+' "$LOG_OK" \
  && assert_pass "窗口内 tag 被换成精确版本再交给 npm" \
  || assert_fail "窗口内 tag 没有落到精确版本: $(grep -m1 'Target:' "$LOG_OK" || echo '<无 Target 行>')"
if grep -q '^install ' "$NPM_LOG"; then
  assert_fail "谢绝之后仍然调用了 npm install（应答没有生效）"
else
  assert_pass "谢绝安装后没有调用 npm install"
fi
tree_after_tag="$(receipt_tree_id "$WORK")"
[ "$tree_after_tag" = "$TREE_BEFORE" ] \
  && assert_pass "tag 路径同样没有改动安装树" \
  || assert_fail "tag 路径改动了安装树: $TREE_BEFORE -> $tree_after_tag"

# --- 5. 入口 B：02-install-dsh.sh ---------------------------------------------
say "== 入口 B: DSH_VERSION=@deepseek-ai/dsh@0.1.4 scripts/02-install-dsh.sh"
LOG_B="$TMP/02-refusal.log"
: >"$NPM_LOG"
rc_b=0
DSH_VERSION='@deepseek-ai/dsh@0.1.4' bash "$REPO/scripts/02-install-dsh.sh" \
  >"$LOG_B" 2>&1 || rc_b=$?
{ echo "--- 入口 B 日志 ---"; cat "$LOG_B"; } >>"$EVID"
[ "$rc_b" != 0 ] && assert_pass "setup 入口同样拒绝低于下限的目标（exit=$rc_b）" \
  || assert_fail "setup 入口接受了低于下限的目标（exit=0）"
grep -qF "$DSH_NPM_SUPPORT_FLOOR" "$LOG_B" && grep -qF 'install.sh -p' "$LOG_B" \
  && assert_pass "setup 入口的拒绝消息同样带理由与替代路径" \
  || assert_fail "setup 入口的拒绝消息不完整"
if grep -q '^install ' "$NPM_LOG"; then
  assert_fail "setup 入口在拒绝前调用了 npm install"
else
  assert_pass "setup 入口也在 npm install 之前拒绝"
fi
tree_after_b="$(receipt_tree_id "$WORK")"
[ "$tree_after_b" = "$TREE_BEFORE" ] \
  && assert_pass "setup 入口拒绝后安装树逐字未变" \
  || assert_fail "setup 入口拒绝却改动了安装树: $TREE_BEFORE -> $tree_after_b"

# 解析不了/不支持的 spec 必须拒绝，而不是原样交给 npm。
LOG_B2="$TMP/02-bad-spec.log"
: >"$NPM_LOG"
rc_b2=0
DSH_VERSION='@deepseek-ai/dsh@^0.1.0' bash "$REPO/scripts/02-install-dsh.sh" \
  >"$LOG_B2" 2>&1 || rc_b2=$?
{ echo "--- 入口 B（范围 spec）日志 ---"; cat "$LOG_B2"; } >>"$EVID"
[ "$rc_b2" != 0 ] && assert_pass "范围型 spec 被拒绝（exit=$rc_b2，不静默降级）" \
  || assert_fail "范围型 spec 被交给了 npm"
if grep -q '^install ' "$NPM_LOG"; then
  assert_fail "范围型 spec 在拒绝前调用了 npm install"
else
  assert_pass "范围型 spec 同样在 npm install 之前被拒"
fi

# --- 6. 帮助文本：不联网、且与哨兵块一致 ---------------------------------------
say "== 帮助哨兵"
HELP_OUT="$TMP/updater-help.txt"
HELP_BLOCK="$TMP/updater-help-block.txt"
bash "$REPO/scripts/update-dsh.sh" -h >"$HELP_OUT" 2>&1 || true
sed -n '/^# help-begin/,/^# help-end/{//!p;}' "$REPO/scripts/update-dsh.sh" >"$HELP_BLOCK"
if diff -q "$HELP_OUT" "$HELP_BLOCK" >/dev/null 2>&1; then
  assert_pass "-h 输出与 help-begin/help-end 块一致（CI 同款契约）"
else
  assert_fail "-h 输出与帮助块不一致（见证据文件）"
  { echo "--- help diff ---"; diff "$HELP_BLOCK" "$HELP_OUT" || true; } >>"$EVID"
fi
if grep -qF '0.1.0-rc.8' "$HELP_OUT"; then
  assert_fail "帮助里仍在举例一个窗口外的版本（会被自己的门禁拒绝）"
else
  assert_pass "帮助里的示例版本都在支持窗口内"
fi

# --- 7. 事实 ------------------------------------------------------------------
FACTS="floor=$DSH_NPM_SUPPORT_FLOOR seed=$SEED_TAG tree=$TREE_BEFORE"
FACTS+=" npm_calls_install=$(grep -c '^install ' "$NPM_LOG" || true)"
FACTS+=" self_done=1 (auto-refresh branch skipped; see the case header)"
say "== 事实: $FACTS"
receipt_case_facts "$DSH_RUN_ID" "$DSH_CASE_ID" "$FACTS" \
  || case_error "必要证据（case-facts）写不进去 —— 本次结论不成立"

case_finish
