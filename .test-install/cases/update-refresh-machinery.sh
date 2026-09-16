#!/usr/bin/env bash
# update/refresh-machinery — 契约: **自动刷新分支**判定正确，且它留下的两个哨兵
# (`DSH_SELF_RAN` / `DSH_PATCHES_CHANGED`) 在答 n 时中止干净（映射表 A.5 的 R4.10
# ＋ A.7 的 R6.H1/H2）。
#
# 两个来源拼在一条 case 里，切法如下（两条的**对象是同一段代码**，只是入口不同）:
#   * §8（旧 r4 第 8 步；需要种子 + GitHub + npm）—— 种入假旧项目 VERSION，让普通
#     update 判定"落后" → 下载补丁集资产 → re-exec 进新鲜更新器 → 继续 npm 并完成。
#     期望值从**刷新后** runtime 自带的注册表派生（那一份才是实际被打上去的）。
#   * Part H1/H2（旧 r6；离线白盒）—— 直接给更新器进程两个哨兵，走"刷新过、但用户在
#     提示符上答 n"的结局。它必须跑**工作区**那份 update-dsh.sh（先把工作区机件装进
#     runtime 再跑），否则测的是发布物里的旧副本而不是本分支代码。
#   缺种子/网络时对应的那一半走 case_unmet（缺结论），不把整条 case 判红；本 case 的
#   registry 已声明 seed:stable + network:github + network:npm，run.sh 会在跑之前就
#   把缺件记成 UNMET，case 内的判定只是防御性的第二道。
#
# 为什么这条必须存在: 自动刷新是补丁集跨 release 演进的唯一通道（`--self` 之外），
# 而它在"种子身份恰好等于 latest"时天然不触发——不主动注入就永远没人测到。
# 旧体系里它只在 r4 的最后一个 echo 段里活着（R4.10），是审计点名的覆盖空洞。

set -uo pipefail

. "$DSH_TI_DIR/lib/state.sh"
. "$DSH_TI_DIR/lib/receipt.sh"
. "$DSH_TI_DIR/lib/seed.sh"
. "$DSH_TI_DIR/lib/patchset.sh"
. "$DSH_HARNESS_ROOT/scripts/common.sh"

case_begin

EVID="$(dirname "$DSH_RESULTS")/evidence-${DSH_CASE_ID//\//-}.txt"
mkdir -p "$(dirname "$EVID")" || case_error "无法创建证据目录 $(dirname "$EVID")"
: > "$EVID" || case_error "无法写证据文件 $EVID"
say() { printf '%s\n' "$*" | tee -a "$EVID" >&2; }

REPO="$DSH_HARNESS_ROOT"
WORK="$DSH_WORK_DIR"
RT="$DSH_RUNTIME_DIR"
NODE="$RT/node/bin/node"
WRAP="$WORK/dsh"
TMP="$DSH_SANDBOX_ROOT/tmp"
mkdir -p "$TMP" || case_error "无法创建沙箱 tmp: $TMP"   # Termux 禁访系统 /tmp

# 注入用的"假旧项目 VERSION"。刻意不用看起来像真版本号的值：它必须**绝不等于**
# 任何一次真实比较的另一侧（否则"判定落后"这一步可能悄悄不触发，Part H/§8 就变成
# 空转）。它是注入物，不是期望值——期望值一律从被测产物派生。
FAKE_OLD_PROJECT_VERSION="0.0.0-probe"

# --- 0. 前置 ------------------------------------------------------------------
# case 内的网络判定是**防御性**的（registry 已声明 network:github/npm，run.sh 先判）：
# 跑到一半网络断了时，结论应当是"缺结论"而不是产品失败。
for k in network:github network:npm; do
  msg="$(state_check_require "$k")"; src=$?
  case "$src" in
    0) ;;
    1) case_unmet "$k 不满足: $msg" ;;
    *) case_error "$k 前置判定配置错误: $msg" ;;
  esac
done
command -v patchelf >/dev/null 2>&1 \
  || case_unmet "更新器需要 patchelf（glibc-runner；registry 未声明 host:glibc）"
[ -n "$(ls "$(glibc_prefix)"/lib/ld-linux-*.so.* 2>/dev/null | head -1 || true)" ] \
  || case_unmet "本机没有 glibc loader（$(glibc_prefix)/lib）"

seed_name="$(seed_default_name)"
seed_load_require "$seed_name"
TARBALL="$(seed_asset_by_name dsh-termux-runtime.tar.gz)" \
  || case_error "种子事实源没有 dsh-termux-runtime.tar.gz（发布约定缺件）"
say "== 种子 $SEED_TAG（dsh $SEED_DSH_VERSION）"

if ! tar -xzf "$TARBALL" -C "$RT" >>"$EVID" 2>&1; then
  assert_fail "种子 tarball 解包失败（详见证据文件）"
  case_finish
fi
[ -x "$NODE" ] && assert_pass "种子 node 就位" \
  || { assert_fail "种子 node 缺失: $NODE"; case_finish; }
[ -d "$WORK/node_modules/@deepseek-ai/dsh" ] \
  || { assert_fail "种子缺已装的 dsh 树（自动刷新是 npm 更新的一部分）"; case_finish; }

# --- 1. 离线白盒 Part H：工作区更新器必须先被装进 runtime --------------------
# 用工作区代码覆盖 runtime 的机件（与旧 r6 Part H 同一做法）：这组哨兵只在**本分支**
# 的 `update-dsh.sh` 里，跑发布物里的旧副本等于什么都没测。
mkdir -p "$RT/scripts/patches"
cp "$REPO/scripts/update-dsh.sh" "$REPO/scripts/common.sh" "$REPO/scripts/patch-lib.sh" "$RT/scripts/" \
  || case_error "无法把工作区机件装进 runtime"
cp "$REPO"/patches/*.patch "$RT/patches/" 2>/dev/null || true
WS_VERSION="$(tr -d '[:space:]' < "$REPO/VERSION" 2>/dev/null || true)"
[ -n "$WS_VERSION" ] || case_error "仓库 VERSION 为空"
printf '%s\n' "$WS_VERSION" > "$RT/VERSION"
RT_UPDATER="$RT/scripts/update-dsh.sh"
[ -f "$RT_UPDATER" ] && assert_pass "runtime 内置更新器 = 工作区版本（Part H 的被测对象）" \
  || { assert_fail "机件安装失败: $RT_UPDATER"; case_finish; }

# H1: DSH_PATCHES_CHANGED=1 -> 明示 + 停止提示 + 答 n 中止 + "补丁未应用" NOTE。
# 哨兵是 exec 会带过去的环境变量，等价于"刚刷新过机件"的进程状态；DSH_SELF_DONE=1
# 让它跳过自动刷新判定（本组测的是判定之后的结局，不重复 §8）。
say "== Part H1: DSH_PATCHES_CHANGED=1 -> 答 n 中止 + 补丁未应用 NOTE"
H1LOG="$TMP/refresh-h1.log"
export DSH_SELF_DONE=1 DSH_SELF_RAN=1 DSH_PATCHES_CHANGED=1
printf 'n\n' | bash "$RT_UPDATER" -v "$SEED_DSH_VERSION" >"$H1LOG" 2>&1; h1_rc=$?
{ echo "--- H1 日志（tail 80） ---"; tail -n 80 "$H1LOG"; } >>"$EVID"
[ "$h1_rc" != 0 ] && assert_pass "H1: 答 n 真的中止（exit $h1_rc）" \
  || assert_fail "H1: 答 n 却退出了 0（应中止）"
grep -qF 'continuing into the dsh update' "$H1LOG" \
  && assert_pass "H1: 明示了'刷新后继续进入 dsh 更新'" \
  || assert_fail "H1: 缺少继续进入 dsh 更新的明示"
grep -qF "answer 'n' at the 'Update dsh to ...?' prompt" "$H1LOG" \
  && assert_pass "H1: 给出了在哪里可以停下来的提示" \
  || assert_fail "H1: 缺少停止提示"
grep -qF 'Aborted.' "$H1LOG" \
  && assert_pass "H1: 明确报出 Aborted." \
  || assert_fail "H1: 缺少 Aborted."
# 这一条是哨兵的全部意义：机件换过、补丁还没打上去，用户必须被告知。
grep -qF 'NOT applied to the installed' "$H1LOG" \
  && assert_pass "H1: 提示了新补丁尚未应用到已装 dsh" \
  || assert_fail "H1: 缺少'补丁未应用'的 NOTE"

# H2: 没有 DSH_PATCHES_CHANGED -> 中止干净、无 NOTE。
say "== Part H2: 无 DSH_PATCHES_CHANGED -> 中止干净"
H2LOG="$TMP/refresh-h2.log"
unset DSH_PATCHES_CHANGED
printf 'n\n' | bash "$RT_UPDATER" -v "$SEED_DSH_VERSION" >"$H2LOG" 2>&1; h2_rc=$?
{ echo "--- H2 日志（tail 80） ---"; tail -n 80 "$H2LOG"; } >>"$EVID"
[ "$h2_rc" != 0 ] && assert_pass "H2: 答 n 中止（exit $h2_rc）" \
  || assert_fail "H2: 答 n 却退出了 0（应中止）"
grep -qF 'Aborted.' "$H2LOG" \
  && assert_pass "H2: 明确报出 Aborted." \
  || assert_fail "H2: 缺少 Aborted."
if grep -qF 'NOT applied to the installed' "$H2LOG"; then
  assert_fail "H2: 补丁集未变化时不该出现'补丁未应用'的 NOTE"
else
  assert_pass "H2: 补丁集未变化时中止干净（无 NOTE）"
fi
unset DSH_SELF_DONE DSH_SELF_RAN

# --- 2. §8 自动刷新分支：判定落后 -> 下载补丁集 -> re-exec -> 继续 npm 并完成 --
# 判定"落后"的注入物：假旧项目 VERSION。刷新之后 runtime 的 scripts/patches 来自
# **发布物资产**（不是工作区），所以 marker 期望值必须从刷新后的注册表派生。
say "== §8: 自动刷新分支（注入假旧项目 VERSION=$FAKE_OLD_PROJECT_VERSION）"
printf '%s\n' "$FAKE_OLD_PROJECT_VERSION" > "$RT/VERSION"
AUTOLOG="$TMP/refresh-auto.log"
# 目标用 dist-tag：本 case 的 registry 没声明 npm-spec 具名输入（也就没有冻结的精确
# 版本可派生），断言全部与具体版本无关——它们读的是流程与**刷新后**的注册表。
# **这是有意的**：§8 验的是"刷新判定 + 哨兵结局"，不是目标解析；给 check 档加一次
# npm 解析只会让默认快集平白联网（旧 r4 第 8 步同样用 dist-tag）。
if ! bash "$REPO/scripts/update-dsh.sh" -t latest -y >"$AUTOLOG" 2>&1; then
  { echo "--- 自动刷新日志（tail 200） ---"; tail -n 200 "$AUTOLOG"; } >>"$EVID"
  assert_fail "自动刷新分支：更新器退出非零（日志见证据文件）"
else
  assert_pass "自动刷新分支：更新器退出 0"
fi
{ echo "--- 自动刷新日志（tail 200） ---"; tail -n 200 "$AUTOLOG"; } >>"$EVID"
grep -qF 'patch-set freshness' "$AUTOLOG" \
  && assert_pass "§8: 出现了新鲜度判定" \
  || assert_fail "§8: 缺少新鲜度判定输出"
grep -qF "project VERSION: $FAKE_OLD_PROJECT_VERSION ->" "$AUTOLOG" \
  && assert_pass "§8: 判定落后并刷新了项目 VERSION" \
  || assert_fail "§8: 缺少'旧->新 项目版本'（刷新可能没触发）"
grep -qF 'continuing into the dsh update' "$AUTOLOG" \
  && assert_pass "§8: re-exec 后明示继续进入 dsh 更新" \
  || assert_fail "§8: 缺少 re-exec 后继续的明示"
grep -qF 'Done. dsh is now' "$AUTOLOG" \
  && assert_pass "§8: 继续走完了 npm 更新" \
  || assert_fail "§8: 未继续完成 npm 更新"
RT_VER="$(tr -d '[:space:]' < "$RT/VERSION" 2>/dev/null || true)"
[ -n "$RT_VER" ] && [ "$RT_VER" != "$FAKE_OLD_PROJECT_VERSION" ] \
  && assert_pass "§8: 刷新后 runtime 的项目 VERSION 是真实版本（$RT_VER）" \
  || assert_fail "§8: 刷新后 runtime 的项目 VERSION 仍是注入值（$RT_VER）"

# marker：从**刷新后** runtime 自带的注册表派生（只读文本；那是发布物那一份）。
say "== §8 补丁 marker（注册表=runtime 内置，刷新后的那一份）"
mapfile -t DSH_PATCH_SET < <(patchset_entries "$RT/scripts/patch-lib.sh")
n_entries="${#DSH_PATCH_SET[@]}"
[ "$n_entries" -ge 1 ] && assert_pass "§8: 刷新后的注册表声明了 $n_entries 条补丁" \
  || assert_fail "§8: 刷新后的注册表没有 DSH_PATCH_SET 条目（发布资产回归）"
n_applied=0; n_skipped=0
if [ "$n_entries" -ge 1 ]; then
  pm="$(patchset_verify_markers "$RT/scripts/patch-lib.sh" "$WORK" 2>&1)"; prc=$?
  printf '%s\n' "$pm" >>"$EVID"
  n_skipped="$(printf '%s\n' "$pm" | grep -c '^skip ' || true)"
  n_applied=$((n_entries - n_skipped))
  [ "$prc" = 0 ] && assert_pass "§8: 刷新后 $n_applied 条适用补丁的 marker 都在" \
    || assert_fail "§8: 刷新后有适用补丁缺 marker（详见证据文件）"
fi
[ "$n_skipped" -gt 0 ] && \
  say "   覆盖率缺口: $n_skipped 条条件补丁不适用于该 dsh 版本（不适用 ≠ 已验证）"

# wrapper 钩子：最终写下它的是刷新后的生成器（runtime 里的 common.sh）。
EXPECT_NOW="$(wrapper_hook_expected "$RT/scripts/common.sh")"
if patchset_wrapper_hook_check "$WRAP" "$EXPECT_NOW"; then
  assert_pass "§8: 刷新后 wrapper 的 update 钩子符合其生成器能力（期望 $EXPECT_NOW）"
else
  assert_fail "§8: 刷新后 wrapper 的 update 钩子与生成器能力不符（详见上文差异）"
fi

# --- 3. 耐久证据 -------------------------------------------------------------
FACTS="seed=$SEED_TAG seed_dsh=$SEED_DSH_VERSION workspace_version=$WS_VERSION"
FACTS+=" fake_old=$FAKE_OLD_PROJECT_VERSION refreshed_version=${RT_VER:-?}"
FACTS+=" h1_exit=$h1_rc h2_exit=$h2_rc applied=$n_applied skipped=$n_skipped"
FACTS+=" generator_expect=$EXPECT_NOW registry_verified=$RT/scripts/patch-lib.sh"
say "== 事实: $FACTS"
receipt_case_facts "$DSH_RUN_ID" "$DSH_CASE_ID" "$FACTS" \
  || case_error "必要证据（case-facts）写不进去 —— 本次结论不成立"

case_finish
