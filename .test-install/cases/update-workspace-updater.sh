#!/usr/bin/env bash
# update/workspace-updater — 契约: **工作区更新器**把一棵种子 runtime 升到本轮冻结
# 的目标版本，并把补丁集重新打上（映射表 A.5 的 R4.1–R4.9、R4.12）。
#
# 与其它 update case 的分工（同一结果不得计两份覆盖）:
#   * update/shipped-updater   —— 发布物**内置**的更新器（Option A 用户真实路径）；
#   * update/self-patch-set    —— `--self`/`--patch-set` 只刷机件、不碰 npm；
#   * update/refresh-machinery —— 自动刷新分支本身（本 case 只在日志里记账它有没有
#     被触发，断言归那条 case）；
#   * update/wrapper-entry     —— `dsh update` 的 argv 转发。
#
# 目标版本一律取自**本轮冻结的 npm 输入**（run.sh 解析 default-target 时冻结）：
# 旧路线的 `DSH_UPDATE_TAG`/`DSH_R4_TAG` 旋钮已按 A.8/L14 改判为具名输入，旧 env
# 名不继承。这里用 `-v <精确版本>` 而不是 `-t latest`，是为了让"同一个目标"在一轮
# 里只解析一次——两次解析可能拿到两个版本，那样结论就绑不住被测对象了（ADR-009）。
#
# 唯一被有意条件化的断言（见下方 == 补丁集 一节）: 当运行时身份**落后于 latest**
# 时，更新器的设计就是"先刷新机件、re-exec 进发布物自带的更新器再用它打补丁"，
# 此时生效的是**发布物那一套**补丁，而不是工作区那一套。旧种子不因发版而淘汰
# （ADR-004），所以这种落后是**预期状态**；照旧路线无条件拿工作区注册表验 marker
# 会让它误红。这条分支被明确记账（registry_verified / auto_refresh 进 case-facts），
# 不是静默降级。

set -uo pipefail

. "$DSH_TI_DIR/lib/state.sh"
. "$DSH_TI_DIR/lib/receipt.sh"
. "$DSH_TI_DIR/lib/seed.sh"
. "$DSH_TI_DIR/lib/patchset.sh"
. "$DSH_TI_DIR/lib/probes.sh"
# common.sh 提供 run_glibc_node / glibc_prefix：不在 case 里复制 glibc 知识。
. "$DSH_HARNESS_ROOT/scripts/common.sh"

case_begin

EVID="$(dirname "$DSH_RESULTS")/evidence-${DSH_CASE_ID//\//-}.txt"
mkdir -p "$(dirname "$EVID")" || case_error "无法创建证据目录 $(dirname "$EVID")"
: > "$EVID" || case_error "无法写证据文件 $EVID"
say() { printf '%s\n' "$*" | tee -a "$EVID" >&2; }

REPO="$DSH_HARNESS_ROOT"
WORK="$DSH_WORK_DIR"
NODE="$DSH_RUNTIME_DIR/node/bin/node"
WRAP="$WORK/dsh"
TMP="$DSH_SANDBOX_ROOT/tmp"
mkdir -p "$TMP" || case_error "无法创建沙箱 tmp: $TMP"   # Termux 禁访系统 /tmp

# --- 0. 前置（先判"这轮能不能得出结论"，再动任何东西） -----------------------
# 更新器的前置在 registry 里只声明了 seed/device/network/tool:git，而它实际还要
# glibc 工具链（configure_glibc_node 要 patchelf，node 解释器断言要 readelf）。
# 缺工具是"世界没配合"，不是产品失败 -> UNMET，不许伪装成红。
for t in patchelf readelf; do
  command -v "$t" >/dev/null 2>&1 \
    || case_unmet "更新器需要 $t（glibc-runner；registry 未声明 host:glibc）"
done
# glibc loader 与 node 解释器断言都在用它：缺了它本轮得不出结论（而更新器自己也会
# 在 configure_glibc_node 里失败），所以放在动手之前判定。
LOADER="$(ls "$(glibc_prefix)"/lib/ld-linux-*.so.* 2>/dev/null | head -1 || true)"
[ -n "$LOADER" ] || case_unmet "本机没有 glibc loader（$(glibc_prefix)/lib），无法断言 node 解释器"
LOADER_NAME="$(basename "$LOADER")"
[ -n "${DSH_NPM_TARGET_FILE:-}" ] \
  || case_unmet "本轮没有冻结的 npm 目标（未解析或解析失败）"
[ -f "$DSH_NPM_TARGET_FILE" ] || case_error "冻结文件不存在: $DSH_NPM_TARGET_FILE"
[ -n "${DSH_NPM_VERSION:-}" ] || case_error "冻结输入缺 version —— 断言'升到哪一版'无从谈起"

# --- 1. R4.1 种子旧 runtime --------------------------------------------------
# 归类的 switch 只有一份实现（lib/seed.sh 的 seed_load_require）：它自己拿真实
# 返回码区分 FAIL(1) / ERROR(2) / UNMET(3)，别在这里再写一遍。
seed_name="$(seed_default_name)"
seed_load_require "$seed_name"
say "== 种子"
say "   tag  $SEED_TAG"
say "   dsh  $SEED_DSH_VERSION"
say "   目标 $DSH_NPM_VERSION（本轮冻结的 default-target）"
TARBALL="$(seed_asset_by_name dsh-termux-runtime.tar.gz)" \
  || case_error "种子事实源没有 dsh-termux-runtime.tar.gz（发布约定缺件）"

if ! tar -xzf "$TARBALL" -C "$DSH_RUNTIME_DIR" >>"$EVID" 2>&1; then
  assert_fail "种子 tarball 解包失败（详见证据文件）"
  case_finish
fi
[ -x "$NODE" ] && assert_pass "种子 node 就位" \
  || { assert_fail "种子 node 缺失: $NODE"; case_finish; }
PKGJSON="$WORK/node_modules/@deepseek-ai/dsh/package.json"
BEFORE="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$PKGJSON" | head -1)"
[ -n "$BEFORE" ] || { assert_fail "无法读取种子 dsh 版本（package.json）"; case_finish; }
say "   种子 dsh $BEFORE；node 解释器（更新前）= $(patchelf --print-interpreter "$NODE" 2>/dev/null || echo '<读不到>')"
assert_pass "种子 runtime 就位（dsh $BEFORE）"

# --- 2. R4.2/R4.12 真实入口：工作区 scripts/update-dsh.sh ---------------------
say "== 工作区 update-dsh.sh -v $DSH_NPM_VERSION -y"
LOG="$TMP/update-ws.log"
if ! bash "$REPO/scripts/update-dsh.sh" -v "$DSH_NPM_VERSION" -y >"$LOG" 2>&1; then
  { echo "--- 更新器日志（tail 200） ---"; tail -n 200 "$LOG"; } >>"$EVID"
  assert_fail "工作区 update-dsh.sh 退出非零（日志见证据文件）"
  case_finish
fi
assert_pass "工作区 update-dsh.sh 退出 0"
{ echo "--- 更新器日志（tail 200） ---"; tail -n 200 "$LOG"; } >>"$EVID"

# 自动刷新分支只在"运行时身份落后 latest"时触发；那是 ADR-004 允许的旧种子状态，
# 不是失败。这里只记账：后面要据此决定"实际生效的是哪一份注册表"。
AUTO_REFRESH=no
grep -qF 'continuing into the dsh update' "$LOG" && AUTO_REFRESH=yes
say "   自动刷新分支被触发: $AUTO_REFRESH（断言归 update/refresh-machinery）"

# --- 3. R4.3 node 补丁仍在 + 可直连 -------------------------------------------
if readelf -l "$NODE" 2>/dev/null | grep -q "$LOADER_NAME"; then
  assert_pass "node 解释器 == glibc loader ($LOADER_NAME)"
else
  assert_fail "node 解释器不是 glibc loader（期望 $LOADER_NAME）"
fi
NODE_VER="$(run_glibc_node "$NODE" --version 2>/dev/null | tr -d '\r\n')"
[ -n "$NODE_VER" ] && assert_pass "补丁后的 node 可直连运行 ($NODE_VER)" \
  || assert_fail "补丁后的 node 无法运行"

# --- 4. R4.4 经**重写后的 wrapper** 取版本 ------------------------------------
# 版本从产品自己吐出来的东西读，不读 package.json：后者证明不了 wrapper 被重写过。
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
  # 旧路线的 note 分支：种子恰好已是目标版本时 npm 仍执行了重装+重打+重写，
  # 机制本身由下面几条断言证明。未变是**记账**，不是一条断言。
  say "   note: 版本未变 (${AFTER:-?} == 种子)；重装+重打补丁+wrapper 重写机制仍按下面断言验证"
fi

# --- 5. R4.5 注册表 marker（工作区全集 / precondition 感知） -------------------
# 实际生效的是哪一份注册表由第 2 步的自动刷新决定：没有刷新 = 工作区那一套被打了；
# 刷新过 = 由发布物自带的更新器 re-exec 后打的是发布物那一套。用错注册表会把
# "旧的 pin + 新的工作区补丁"这种正常状态误判成红。
say "== 补丁 marker"
n_applied=0; n_skipped=0; SKIPPED=""
if [ "$AUTO_REFRESH" = yes ]; then
  REGISTRY_VERIFIED="$DSH_RUNTIME_DIR/scripts/patch-lib.sh"
  say "   注册表: $REGISTRY_VERIFIED（刷新后由它打补丁）"
  [ -f "$REGISTRY_VERIFIED" ] \
    || assert_fail "刷新后 runtime 缺 scripts/patch-lib.sh（打包回归）"
  # 产物内注册表**只读文本**：它是别人发布出来的任何历史形态，不许 source。
  mapfile -t DSH_PATCH_SET < <(patchset_entries "$REGISTRY_VERIFIED")
  n_entries="${#DSH_PATCH_SET[@]}"
  [ "$n_entries" -ge 1 ] \
    && assert_pass "刷新后的注册表声明了 $n_entries 条补丁" \
    || assert_fail "刷新后的注册表没有 DSH_PATCH_SET 条目（打包回归）"
  if [ "$n_entries" -ge 1 ]; then
    pm="$(patchset_verify_markers "$REGISTRY_VERIFIED" "$WORK" 2>&1)"; prc=$?
    printf '%s\n' "$pm" >>"$EVID"
    n_skipped="$(printf '%s\n' "$pm" | grep -c '^skip ' || true)"
    n_applied=$((n_entries - n_skipped))
    [ "$prc" = 0 ] && assert_pass "刷新后 $n_applied 条适用补丁的 marker 都在" \
      || assert_fail "刷新后有适用补丁缺 marker（详见证据文件）"
  fi
else
  REGISTRY_VERIFIED="$REPO/scripts/patch-lib.sh"
  say "   注册表: $REGISTRY_VERIFIED（工作区补丁集实际被打上）"
  # shellcheck source=../../scripts/patch-lib.sh
  . "$REPO/scripts/patch-lib.sh"
  APPLIED=()
  for entry in "${DSH_PATCH_SET[@]}"; do
    if dsh_patch_applicable "$WORK" "$entry"; then
      APPLIED+=("$entry"); n_applied=$((n_applied + 1))
    else
      n_skipped=$((n_skipped + 1)); SKIPPED+="${entry%%:*},"
    fi
  done
  [ "$n_applied" -gt 0 ] && assert_pass "更新后适用 $n_applied 条工作区补丁" \
    || assert_fail "没有任何工作区补丁适用于更新后的树 —— 补丁集重打无从谈起"
  if [ "$n_applied" -gt 0 ]; then
    if dsh_verify_patch_markers "$WORK" "${APPLIED[@]}" >>"$EVID" 2>&1; then
      assert_pass "全部 $n_applied 条适用补丁的 marker 都在"
    else
      assert_fail "有适用补丁的 marker 缺失（详见证据文件）"
    fi
  fi
fi
if [ "$n_skipped" -gt 0 ]; then
  # 覆盖率缺口必须显式留下：不适用 ≠ 已验证。
  say "   覆盖率缺口: $n_skipped 条条件补丁不适用于该 dsh 版本（不适用 ≠ 已验证）${SKIPPED:+: ${SKIPPED%,}}"
fi

# --- 6. R4.6 行为级探针（marker 只证明"文件变过"） ----------------------------
say "== 行为级探针"
probe_rc=0
probe_patch_set_behaviors "$WORK" "$NODE" || probe_rc=1
if [ -n "$PROBE_SKIPPED" ]; then
  say "   跳过的探针（不计为已验证）: $PROBE_SKIPPED"
fi

# --- 7. R4.7 opener / symlink 被重写且可用 ------------------------------------
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

# --- 8. R4.8 钩子符合**真正生成了它的那份生成器**的能力 -----------------------
# 期望值从生成器派生（生成器去掉该特性时测试自动跟随，不留神秘红灯），但必须取
# "谁写了这个 wrapper"那一份：没刷新时是工作区 common.sh，刷新后是 runtime 的。
if [ "$AUTO_REFRESH" = yes ]; then
  GENERATOR="$DSH_RUNTIME_DIR/scripts/common.sh"
else
  GENERATOR="$REPO/scripts/common.sh"
fi
EXPECT="$(wrapper_hook_expected "$GENERATOR")"
say "   生成器: $GENERATOR（钩子能力期望=$EXPECT）"
if patchset_wrapper_hook_check "$WRAP" "$EXPECT"; then
  assert_pass "wrapper 的 update 钩子符合生成器能力（期望 $EXPECT）"
else
  assert_fail "wrapper 的 update 钩子与生成器能力不符（详见上文差异）"
fi

# --- 9. R4.9 钩子目标 = runtime 内置更新器（Option A 优先级） ------------------
# 这是用户真实路径的关键一条：只要 runtime 里带着更新器，wrapper 就必须指它，
# 指回仓库 checkout 意味着设备上的 `dsh update` 依赖一份并不存在的 clone。
RT_UPDATER="$DSH_RUNTIME_DIR/scripts/update-dsh.sh"
[ -f "$RT_UPDATER" ] && assert_pass "runtime 内置更新器在位（Option A 布局）" \
  || assert_fail "runtime 缺 scripts/update-dsh.sh（打包回归）"
if grep -qF "\"$RT_UPDATER\"" "$WRAP"; then
  assert_pass "wrapper 钩子指向 runtime 内置更新器: $RT_UPDATER"
else
  assert_fail "wrapper 钩子未指向 runtime 内置更新器（期望 $RT_UPDATER）"
fi
if grep -qF "\"$REPO/scripts/update-dsh.sh\"" "$WRAP"; then
  assert_fail "wrapper 钩子指回了仓库 checkout（$REPO/scripts/update-dsh.sh）"
else
  assert_pass "wrapper 钩子没有指回仓库 checkout"
fi

# --- 10. 耐久证据 -------------------------------------------------------------
# R4.11 的 live_sentinel 没有在这里重写：整棵线上 runtime（含 wrapper 与 ~/.dsh 之外的
# 全部路径）的运行前后签名守卫由框架在**每条 case** 外统一做（lib/sandbox.sh +
# run.sh），比旧路线那条只查 node 四元组的断言更强，不重复实现。
FACTS="seed=$SEED_TAG seed_dsh=$SEED_DSH_VERSION update_target=$DSH_NPM_VERSION"
FACTS+=" before=$BEFORE after=${AFTER:-?} wrapper_exit=$wrc node=${NODE_VER:-?}"
FACTS+=" auto_refresh=$AUTO_REFRESH registry_verified=$REGISTRY_VERIFIED"
FACTS+=" applied=$n_applied skipped=$n_skipped"
FACTS+=" probes=$([ "$probe_rc" = 0 ] && echo ok || echo failed) probes_skipped=${PROBE_SKIPPED:-none}"
say "== 事实: $FACTS"
receipt_case_facts "$DSH_RUN_ID" "$DSH_CASE_ID" "$FACTS" \
  || case_error "必要证据（case-facts）写不进去 —— 本次结论不成立"

case_finish
