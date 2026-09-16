#!/usr/bin/env bash
# update/shipped-updater — 契约: **发布物内置**的更新器能把那份发布物自己升上来
# （映射表 A.6 的 R5.1–R5.12）。
#
# 这条是 Option A 用户的真实路径：设备上只有 tarball 里带的 scripts/update-dsh.sh
# 与 patches/。发布打包缺更新器/缺补丁、或内置更新器与捆绑 lib 不自洽，**只有这里
# 会红**——所以"缺件"必须响亮失败，不许降级成 note。
#
# 期望值一律派生:
#   * 种子身份 / 项目 VERSION —— 从种子事实源与 tarball 读；
#   * 补丁清单与 marker —— 从**发布物自带**的 patch-lib.sh 逐条解析（lib/patchset.sh，
#     只读文本：那是别人发布出来的任何历史形态，两/三/四段式都可能）；
#   * wrapper 钩子能力 —— 从真正生成 wrapper 的那份 common.sh 派生；
#   * 目标版本 —— 本轮冻结的 npm 输入（default-target），不写死版本号。
#
# 与 update/workspace-updater 的分工: 那条的执行物是仓库 checkout 里的更新器 +
# 工作区 patches/；这条的执行物**全部来自发布物**。按 ADR-009，工作区结论不得外推
# 为 shipped 已验证，所以两条都要在。

set -uo pipefail

. "$DSH_TI_DIR/lib/state.sh"
. "$DSH_TI_DIR/lib/receipt.sh"
. "$DSH_TI_DIR/lib/seed.sh"
. "$DSH_TI_DIR/lib/patchset.sh"
. "$DSH_TI_DIR/lib/probes.sh"
. "$DSH_HARNESS_ROOT/scripts/common.sh"

case_begin

EVID="$(dirname "$DSH_RESULTS")/evidence-${DSH_CASE_ID//\//-}.txt"
mkdir -p "$(dirname "$EVID")" || case_error "无法创建证据目录 $(dirname "$EVID")"
: > "$EVID" || case_error "无法写证据文件 $EVID"
say() { printf '%s\n' "$*" | tee -a "$EVID" >&2; }

WORK="$DSH_WORK_DIR"
NODE="$DSH_RUNTIME_DIR/node/bin/node"
WRAP="$WORK/dsh"
RT="$DSH_RUNTIME_DIR"
TMP="$DSH_SANDBOX_ROOT/tmp"
mkdir -p "$TMP" || case_error "无法创建沙箱 tmp: $TMP"   # Termux 禁访系统 /tmp

# 注入用的"假旧项目 VERSION"（见 R5.4）：它必须绝不等于任何真实版本，否则
# "判定落后 / 刷新真的换了身份"可能悄悄不成立。它是注入物，不是期望值。
FAKE_OLD_PROJECT_VERSION="0.0.0-probe"

# --- 0. 前置 ------------------------------------------------------------------
# registry 里这条 case 的 requires 只写了 seed/device/network:npm/tool:git，而
# R5.4 的 shipped `--self` 要从 GitHub 拉补丁集资产。缺 GitHub 是"世界没配合" -> UNMET，
# 不许把它变成产品失败的红（A.9 第 3 条要求 registry 补 network:github）。
gh_msg="$(state_check_require network:github)"; gh_rc=$?
case "$gh_rc" in
  0) ;;
  1) case_unmet "shipped 更新链需要 GitHub: $gh_msg（防御性复判；registry 已声明 network:github）" ;;
  *) case_error "network:github 前置判定配置错误: $gh_msg" ;;
esac
for t in patchelf readelf; do
  command -v "$t" >/dev/null 2>&1 \
    || case_unmet "更新器需要 $t（glibc-runner；registry 未声明 host:glibc）"
done
# glibc loader 是 node 解释器断言与被测更新器自身的前置：缺了它本轮得不出结论，
# 所以在动手之前判定（放在更新之后判定会让 case_unmet 盖掉已经收集的断言）。
LOADER="$(ls "$(glibc_prefix)"/lib/ld-linux-*.so.* 2>/dev/null | head -1 || true)"
[ -n "$LOADER" ] || case_unmet "本机没有 glibc loader（$(glibc_prefix)/lib），无法断言 node 解释器"
LOADER_NAME="$(basename "$LOADER")"
[ -n "${DSH_NPM_TARGET_FILE:-}" ] \
  || case_unmet "本轮没有冻结的 npm 目标（未解析或解析失败）"
[ -f "$DSH_NPM_TARGET_FILE" ] || case_error "冻结文件不存在: $DSH_NPM_TARGET_FILE"
[ -n "${DSH_NPM_VERSION:-}" ] || case_error "冻结输入缺 version —— 断言'升到哪一版'无从谈起"

# --- 1. R5.1/R5.2 种子 = 发布物本身；内置更新器必须在场 -----------------------
seed_name="$(seed_default_name)"
seed_load_require "$seed_name"
say "== 种子"
say "   tag  $SEED_TAG"
say "   dsh  $SEED_DSH_VERSION"
say "   更新目标 $DSH_NPM_VERSION（本轮冻结的 default-target）"
# 发布物输入实例（ADR-011）：本 case 认证的对象是**种子这一份发布物**，实例身份
# 由种子事实源给出（SEED_TAG）。`DSH_RELEASE_TAG` 只在选中的 case 消费
# release-assets 时才解析，这里按空值容错、不拿它当身份。
say "   发布物实例: $SEED_TAG（来自种子事实源；DSH_RELEASE_TAG=${DSH_RELEASE_TAG:-<未解析/不适用>}）"

TARBALL="$(seed_asset_by_name dsh-termux-runtime.tar.gz)" \
  || case_error "种子事实源没有 dsh-termux-runtime.tar.gz（发布约定缺件）"
if ! tar -xzf "$TARBALL" -C "$RT" >>"$EVID" 2>&1; then
  assert_fail "种子 tarball 解包失败（详见证据文件）"
  case_finish
fi
[ -x "$NODE" ] && assert_pass "种子 node 就位" \
  || { assert_fail "种子 node 缺失: $NODE"; case_finish; }

PKGJSON="$WORK/node_modules/@deepseek-ai/dsh/package.json"
BEFORE="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$PKGJSON" | head -1)"
[ -n "$BEFORE" ] || { assert_fail "无法读取种子 dsh 版本（package.json）"; case_finish; }
say "   种子 dsh $BEFORE"

UPDATER="$RT/scripts/update-dsh.sh"
if [ -f "$UPDATER" ]; then
  assert_pass "发布物内置 scripts/update-dsh.sh（Option A 用户真实路径）"
else
  assert_fail "发布物未内置 scripts/update-dsh.sh —— 打包回归，该红（用户拿不到 Option A 路径）"
  case_finish
fi

# --- 2. R5.3 shipped 补丁文件齐全 + ≥1 条 + 生成器钩子能力 ---------------------
SHIPPED_LIB="$RT/scripts/patch-lib.sh"
[ -f "$SHIPPED_LIB" ] && assert_pass "发布物内置 scripts/patch-lib.sh" \
  || { assert_fail "发布物缺 scripts/patch-lib.sh（打包回归）"; case_finish; }
mapfile -t SEED_ENTRIES < <(patchset_entries "$SHIPPED_LIB")
n_seed_entries="${#SEED_ENTRIES[@]}"
[ "$n_seed_entries" -ge 1 ] \
  && assert_pass "shipped 注册表声明了 $n_seed_entries 条补丁" \
  || assert_fail "shipped 注册表没有 DSH_PATCH_SET 条目（打包回归）"
missing_patch=""
for entry in "${SEED_ENTRIES[@]}"; do
  pfile="$(patchset_patch "$entry")"
  [ -f "$RT/patches/$pfile" ] || missing_patch+="${missing_patch:+, }$pfile"
done
[ -z "$missing_patch" ] \
  && assert_pass "shipped 注册表声明的补丁文件都在发布物里" \
  || assert_fail "发布物缺注册表声明的补丁文件（打包回归）: $missing_patch"
EXPECT_SEED="$(wrapper_hook_expected "$RT/scripts/common.sh")"
say "   shipped 生成器钩子能力期望=$EXPECT_SEED"

# --- 3. R5.4 shipped `--self` 全链路（按 tarball 是否携带 VERSION 条件触发） ---
# `--self` 是补丁集跨项目 release 演进的通道：优先下载 ~40KB 的补丁集资产，无该
# 资产时回退完整 tarball 提取同内容。VERSION 是 1.2.1 起才随发布物走的身份文件，
# 旧发布物没有它 -> 这条子链不适用（记录为覆盖率缺口，不是 PASS）。
#
# 清单先读进内存再匹配：`tar tzf ... | grep -q` 在 pipefail 下会因 grep 提前退出、
# tar 收 SIGPIPE(141) 而误判（release.yml 记录过同一个坑）。
TAR_LIST="$(tar -tzf "$TARBALL" 2>/dev/null || true)"
SELF_APPLICABLE=no
grep -qx 'VERSION' <<<"$TAR_LIST" && SELF_APPLICABLE=yes
VSHIPPED=""
if [ "$SELF_APPLICABLE" = yes ]; then
  VSHIPPED="$(tar xzOf "$TARBALL" VERSION 2>/dev/null | tr -d '[:space:]')"
  say "== shipped --self 全链路（种子项目 VERSION=$VSHIPPED）"
  # 用假的项目 VERSION 播种，让 --self 有"落后"可修。假值是**注入物**，不是期望值；
  # 刻意取一个不可能与任何真实版本相等的值，"刷新确实发生了"才不会被巧合掩盖。
  printf '%s\n' "$FAKE_OLD_PROJECT_VERSION" > "$RT/VERSION"
  SELFLOG="$TMP/shipped-self.log"
  if ! bash "$UPDATER" --self -v "$DSH_NPM_VERSION" -y >"$SELFLOG" 2>&1; then
    { echo "--- --self 日志（tail 120） ---"; tail -n 120 "$SELFLOG"; } >>"$EVID"
    assert_fail "shipped --self 链路退出非零（日志见证据文件）"
  else
    assert_pass "shipped --self 退出 0"
    { echo "--- --self 日志（tail 120） ---"; tail -n 120 "$SELFLOG"; } >>"$EVID"
    grep -qF 'Applying the refreshed patch set' "$SELFLOG" \
      && assert_pass "--self 真的应用了刷新后的补丁集（不是只换了机件）" \
      || assert_fail "--self 日志缺少应用补丁集这一步"
    VSELF="$(tr -d '[:space:]' < "$RT/VERSION")"
    say "   --self 后项目 VERSION=$VSELF（种子=$VSHIPPED）"
    # "刷新装了哪一版"只能对着**同一次 latest 解析**断言。种子就是 latest 时，
    # 刷新结果必须与 tarball 里那一版逐字相同（旧 r5 的断言）；旧种子落后 latest
    # 时该等式按设计不成立（ADR-004 保留旧种子），退化为：身份确实被换掉了。
    latest_tag="$(resolve_release_tag latest 2>/dev/null || true)"
    if [ -n "$latest_tag" ] && [ "$latest_tag" = "$SEED_TAG" ]; then
      [ "$VSELF" = "$VSHIPPED" ] \
        && assert_pass "--self 后 VERSION == 发布物 VERSION（$VSELF）" \
        || assert_fail "--self 后 VERSION($VSELF) != 发布物 VERSION($VSHIPPED)"
    else
      say "   note: 种子 pin($SEED_TAG) 落后于 latest(${latest_tag:-<解析失败>})："
      say "         --self 装的是 latest 那一版，因此不与种子 VERSION 逐字比对（记 case-facts）"
      [ -n "$VSELF" ] && [ "$VSELF" != "$FAKE_OLD_PROJECT_VERSION" ] \
        && assert_pass "--self 把项目身份从注入的假值换成了真实版本（$VSELF）" \
        || assert_fail "--self 之后 VERSION 仍是假值/空（$VSELF）"
    fi
    # 刷新后重新解析补丁声明：只换机件不换/少换补丁是打包回归。
    n_self_entries="$(patchset_entries "$RT/scripts/patch-lib.sh" | grep -c . || true)"
    [ "${n_self_entries:-0}" -ge "$n_seed_entries" ] \
      && assert_pass "--self 后补丁声明不缩水（$n_self_entries >= $n_seed_entries）" \
      || assert_fail "--self 后补丁声明变少（$n_self_entries < $n_seed_entries）"
  fi
else
  # 覆盖率缺口必须显式留下：不适用 ≠ 已验证。
  say "   覆盖率缺口: 种子 tarball 无 VERSION（pre-1.2.1 发布物），shipped --self 子链未覆盖"
fi

# --- 4. R5.5 内置更新器执行普通更新 -------------------------------------------
say "== shipped update-dsh.sh -v $DSH_NPM_VERSION -y"
UPLOG="$TMP/shipped-update.log"
if ! bash "$UPDATER" -v "$DSH_NPM_VERSION" -y >"$UPLOG" 2>&1; then
  { echo "--- 更新器日志（tail 200） ---"; tail -n 200 "$UPLOG"; } >>"$EVID"
  assert_fail "shipped update-dsh.sh 退出非零（日志见证据文件）"
  case_finish
fi
assert_pass "shipped update-dsh.sh 退出 0"
{ echo "--- 更新器日志（tail 200） ---"; tail -n 200 "$UPLOG"; } >>"$EVID"

# --- 5. R5.6 node 补丁仍在 + 可直连 -------------------------------------------
if readelf -l "$NODE" 2>/dev/null | grep -q "$LOADER_NAME"; then
  assert_pass "node 解释器 == glibc loader ($LOADER_NAME)"
else
  assert_fail "node 解释器不是 glibc loader（期望 $LOADER_NAME）"
fi
NODE_VER="$(run_glibc_node "$NODE" --version 2>/dev/null | tr -d '\r\n')"
[ -n "$NODE_VER" ] && assert_pass "补丁后的 node 可直连运行 ($NODE_VER)" \
  || assert_fail "补丁后的 node 无法运行"

# --- 6. R5.7 更新后版本（经重写的 wrapper） -----------------------------------
[ -x "$WRAP" ] && assert_pass "更新后 wrapper 在位" \
  || assert_fail "更新后 wrapper 缺失: $WRAP"
WVER="$(PATH="$DSH_BIN_DIR:$PATH" "$WRAP" --version 2>/dev/null)"; wrc=$?
say "   wrapper --version (exit=$wrc): ${WVER//$'\n'/ | }"
[ "$wrc" = 0 ] && assert_pass "重写后的 wrapper 能跑（dsh 真的启动了一次）" \
  || assert_fail "重写后的 wrapper 退出非零 ($wrc)"
AFTER="$(printf '%s\n' "$WVER" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?' | head -1)"
if [ -z "$AFTER" ]; then
  assert_fail "无法从 wrapper 输出解析版本: ${WVER:-<空>}"
elif [ "$AFTER" = "$DSH_NPM_VERSION" ]; then
  assert_pass "更新后版本 == 本轮冻结的目标 ($AFTER)"
else
  assert_fail "更新后版本($AFTER) != 冻结目标($DSH_NPM_VERSION)"
fi
if [ "$BEFORE" != "$AFTER" ]; then
  say "   版本变化: $BEFORE -> ${AFTER:-?}"
else
  say "   note: 版本未变 (${AFTER:-?} == 种子)；重装+重打补丁+wrapper 重写机制仍按下面断言验证"
fi

# --- 7. R5.8 shipped 注册表 marker（precondition 感知，只读文本） -------------
# 用**更新后** runtime 里那一份注册表（--self 可能已经把它换成新版资产；普通更新
# 用的也是它），因此这里既覆盖"发布物自带的补丁集"，也覆盖刷新后的那一份。
say "== shipped 补丁 marker"
mapfile -t DSH_PATCH_SET < <(patchset_entries "$RT/scripts/patch-lib.sh")
n_entries="${#DSH_PATCH_SET[@]}"
[ "$n_entries" -ge 1 ] && assert_pass "更新后注册表声明了 $n_entries 条补丁" \
  || assert_fail "更新后注册表没有 DSH_PATCH_SET 条目（打包回归）"
n_applied=0; n_skipped=0
if [ "$n_entries" -ge 1 ]; then
  pm="$(patchset_verify_markers "$RT/scripts/patch-lib.sh" "$WORK" 2>&1)"; prc=$?
  printf '%s\n' "$pm" >>"$EVID"
  n_skipped="$(printf '%s\n' "$pm" | grep -c '^skip ' || true)"
  n_applied=$((n_entries - n_skipped))
  [ "$prc" = 0 ] && assert_pass "shipped 注册表里 $n_applied 条适用补丁的 marker 都在" \
    || assert_fail "shipped 注册表里有适用补丁缺 marker（详见证据文件）"
fi
[ "$n_skipped" -gt 0 ] && \
  say "   覆盖率缺口: $n_skipped 条条件补丁不适用于该 dsh 版本（不适用 ≠ 已验证）"

# --- 8. R5.9 行为级探针（触发 marker 按补丁目标 rel 从注册表派生） ------------
say "== 行为级探针"
probe_rc=0
probe_patch_set_behaviors "$WORK" "$NODE" || probe_rc=1
if [ -n "$PROBE_SKIPPED" ]; then
  say "   跳过的探针（不计为已验证）: $PROBE_SKIPPED"
fi

# --- 9. R5.10 opener / symlink 被重写且可用 -----------------------------------
OPENER="$WORK/dsh-termux-open"
[ -x "$OPENER" ] && assert_pass "opener 被重写" || assert_fail "opener 缺失: $OPENER"
"$OPENER" </dev/null >/dev/null 2>&1; op_rc=$?
[ "$op_rc" = 2 ] && assert_pass "opener 无参退出码 2" \
  || assert_fail "opener 无参退出码 != 2 (实得 $op_rc)"
[ -L "$DSH_BIN_DIR/dsh" ] && assert_pass "bin 里的 dsh 是 symlink" \
  || assert_fail "symlink 缺失: $DSH_BIN_DIR/dsh"
[ "$(readlink "$DSH_BIN_DIR/dsh" 2>/dev/null)" = "$WRAP" ] \
  && assert_pass "symlink 指向更新后的 wrapper" \
  || assert_fail "symlink 目标不对: $(readlink "$DSH_BIN_DIR/dsh" 2>/dev/null || echo '<无>')"
"$DSH_BIN_DIR/dsh" --version >/dev/null 2>&1 \
  && assert_pass "经 symlink 调用的 dsh 能跑" \
  || assert_fail "经 symlink 调用的 dsh 不能跑"

# --- 10. R5.11 钩子符合 shipped 生成器能力 ------------------------------------
# 从**当前** runtime 里的 common.sh 派生：那正是写下这个 wrapper 的生成器
# （--self 刷新后就不是种子那份了，用种子的期望值会得出错误结论）。
EXPECT_NOW="$(wrapper_hook_expected "$RT/scripts/common.sh")"
[ "$EXPECT_NOW" = "$EXPECT_SEED" ] \
  || say "   note: shipped 生成器钩子能力被 --self 刷新改变: $EXPECT_SEED -> $EXPECT_NOW"
if patchset_wrapper_hook_check "$WRAP" "$EXPECT_NOW"; then
  assert_pass "wrapper 的 update 钩子符合 shipped 生成器能力（期望 $EXPECT_NOW）"
else
  assert_fail "wrapper 的 update 钩子与 shipped 生成器能力不符（详见上文差异）"
fi

# --- 11. 耐久证据 -------------------------------------------------------------
# R5.12 的 live_sentinel 没有在这里重写：整棵线上 runtime 的运行前后全路径签名守卫由
# 框架在每条 case 外统一做（lib/sandbox.sh + run.sh），比旧路线那条只查 node 四元组
# 的断言更强，不重复实现。
FACTS="seed=$SEED_TAG seed_dsh=$SEED_DSH_VERSION update_target=$DSH_NPM_VERSION"
FACTS+=" before=$BEFORE after=${AFTER:-?} wrapper_exit=$wrc node=${NODE_VER:-?}"
FACTS+=" release_instance=$SEED_TAG self_chain=$SELF_APPLICABLE self_fake_old=$FAKE_OLD_PROJECT_VERSION"
FACTS+=" self_version=${VSELF:-n/a} shipped_version=${VSHIPPED:-n/a}"
FACTS+=" shipped_entries=$n_seed_entries applied=$n_applied skipped=$n_skipped"
FACTS+=" probes=$([ "$probe_rc" = 0 ] && echo ok || echo failed) probes_skipped=${PROBE_SKIPPED:-none}"
say "== 事实: $FACTS"
receipt_case_facts "$DSH_RUN_ID" "$DSH_CASE_ID" "$FACTS" \
  || case_error "必要证据（case-facts）写不进去 —— 本次结论不成立"

case_finish
