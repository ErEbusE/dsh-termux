#!/usr/bin/env bash
# update/self-patch-set — 契约: `--self` / `--patch-set` 刷新机件并**直接应用**
# 补丁集，全程不碰 npm（映射表 A.7 的 R6.A–R6.G；Part H 的哨兵行为归
# update/refresh-machinery）。
#
# Part A–F 与 Part G 是同一契约的**不同输入来源**（ADR-005：来源只是输入参数）：
# A 用本地目录、D 用本地现打 tarball、G 用**已发布资产**（`--self` 不带 --patch-set）。
# 因此不为下载路径另开 case。
#
# 为什么这些断言必须在这里（而不是被"更新成功"顺带覆盖）: `--self` 不重装 npm 树，
# 于是"**先退旧集**、再打新集"就是正确性的全部保障——补丁被改写/删除后，只打新集
# 会既退不掉旧 post-image 又打不上，还会把结论报成上游"版本漂移"（2026-09-08 真机
# 撞到）。所以 Part A 断言日志里真有这一步，而不只是 marker 最终在场。
#
# 期望值一律派生:
#   * 项目 VERSION 从仓库 VERSION 读（Part G 的期望从解析出的 latest tag 尾段取）；
#   * 补丁清单 / marker 从**被消费的那一份注册表**解析（lib/patchset.sh 的文本
#     解析——产物内注册表是别人发布的任何历史形态，两/三/四段式都要认；旧 r6 内联
#     的 verify_markers 助手就换成它，不再各写一份）；
#   * 本地 tarball 的成员清单从 build-patchset.sh 现打的包里读。
#
# 为什么需要基线种子: apply 阶段要把补丁打到**已装的 dsh 树**上（`self_apply_only`
# 先查 node 与 node_modules/@deepseek-ai/dsh），还要先退旧集——两件事都要一棵真树。
# 缺种子 -> UNMET（缺结论），不是 FAIL。

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

# 注入用的"假旧项目 VERSION"：Part A/D/F 都靠它制造"落后"（机件签名必然与目标不同，
# 于是刷新真的发生而不是被"已是最新"提前返回）。它是**注入物**，不是期望值；期望值
# 只有仓库 VERSION（$WS_VERSION）。取值刻意不像任何真实版本。
FAKE_OLD_PROJECT_VERSION="0.0.0-probe"

UPDATER="$REPO/scripts/update-dsh.sh"
WS_VERSION="$(tr -d '[:space:]' < "$REPO/VERSION" 2>/dev/null || true)"
[ -f "$UPDATER" ] || case_error "工作区 update-dsh.sh 不存在: $UPDATER"
[ -n "$WS_VERSION" ] || case_error "仓库 VERSION 为空 —— 旧->新 项目版本无从断言"

# --- 0. 前置 ------------------------------------------------------------------
# `configure_glibc_node`（apply 阶段的前置）要 patchelf + glibc loader；缺工具是
# "世界没配合" -> UNMET，不许变成产品失败的红。
for t in patchelf git; do
  command -v "$t" >/dev/null 2>&1 || case_unmet "本 case 需要 $t"
done
[ -n "$(ls "$(glibc_prefix)"/lib/ld-linux-*.so.* 2>/dev/null | head -1 || true)" ] \
  || case_unmet "本机没有 glibc loader（$(glibc_prefix)/lib）"
seed_name="$(seed_default_name)"
seed_msg="$(state_check_require "seed:$seed_name")"; seed_chk=$?
case "$seed_chk" in
  0) ;;
  1) case_unmet "$seed_msg（本 case 的 apply 阶段需要一棵已装 dsh 的树；registry 未声明 baseline-seed）" ;;
  *) case_error "seed:$seed_name 前置判定配置错误: $seed_msg" ;;
esac

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
TARBALL="$(seed_asset_by_name dsh-termux-runtime.tar.gz)" \
  || case_error "种子事实源没有 dsh-termux-runtime.tar.gz（发布约定缺件）"
say "== 种子 $SEED_TAG（dsh $SEED_DSH_VERSION）；工作区项目 VERSION=$WS_VERSION"

if ! tar -xzf "$TARBALL" -C "$RT" >>"$EVID" 2>&1; then
  assert_fail "种子 tarball 解包失败（详见证据文件）"
  case_finish
fi
[ -x "$NODE" ] || { assert_fail "种子 node 缺失: $NODE"; case_finish; }
[ -d "$WORK/node_modules/@deepseek-ai/dsh" ] \
  || { assert_fail "种子缺已装的 dsh 树，--self 的 apply 阶段无从谈起"; case_finish; }
# 旧集回退（Part A 的"Reversing..."）读的是 runtime 自带的注册表 + patches/。
# 缺它们时 --self 会走"pre-feature runtime"的另一条路径，本 case 的断言不成立。
if [ -d "$RT/scripts" ] && [ -d "$RT/patches" ]; then
  assert_pass "种子是 Option A 形态（自带 scripts/ + patches/）"
else
  case_unmet "种子 tarball 没有 scripts/+patches/（pre-1.2.1 形态），本 case 的前置不成立"
fi

# verify_markers <注册表> <标签>
# 用 lib/patchset.sh 的文本解析逐条验 marker（含四段式前置条件跳过），并保证
# "0 个适用补丁"不会伪装成通过——那等于断言失效。
verify_markers() {
  local lib="$1" label="$2" out rc skipped total applied
  out="$(patchset_verify_markers "$lib" "$WORK" 2>&1)"; rc=$?
  printf '%s\n' "$out" >>"$EVID"
  skipped="$(printf '%s\n' "$out" | grep -c '^skip ' || true)"
  total="$(patchset_entries "$lib" | grep -c . || true)"
  applied=$((total - skipped))
  if [ "$rc" != 0 ]; then
    assert_fail "$label: 有适用补丁缺 marker（详见证据文件）"
    return 1
  fi
  if [ "$applied" -lt 1 ]; then
    assert_fail "$label: 0 个适用补丁 —— 断言失效（注册表或树不对）"
    return 1
  fi
  if [ "$skipped" -gt 0 ]; then
    say "   $label: $applied 条适用、$skipped 条条件补丁不适用（不适用 ≠ 已验证）"
  fi
  assert_pass "$label: $applied 条适用补丁的 marker 都在"
  return 0
}

# --- Part A. --self --patch-set <工作区目录>（离线，不碰 npm） -----------------
say "== Part A: --self --patch-set <工作区目录>"
printf '%s\n' "$FAKE_OLD_PROJECT_VERSION" > "$RT/VERSION"
ALOG="$TMP/self-a.log"
if ! bash "$UPDATER" --self --patch-set "$REPO" >"$ALOG" 2>&1; then
  { echo "--- Part A 日志（tail 120） ---"; tail -n 120 "$ALOG"; } >>"$EVID"
  assert_fail "Part A: --self --patch-set 工作区目录失败（日志见证据文件）"
fi
{ echo "--- Part A 日志（tail 120） ---"; tail -n 120 "$ALOG"; } >>"$EVID"
grep -qF "project VERSION: $FAKE_OLD_PROJECT_VERSION -> $WS_VERSION" "$ALOG" \
  && assert_pass "Part A: 日志显示项目 VERSION $FAKE_OLD_PROJECT_VERSION -> $WS_VERSION" \
  || assert_fail "Part A: 缺少 旧->新 项目版本显示"
# 不重装 npm 树时，"先退旧集"是正确性的全部保障——必须真出现，不能只看 marker。
grep -qF 'Reversing the previously applied patch set' "$ALOG" \
  && assert_pass "Part A: 真出现了'先退旧集'这一步" \
  || assert_fail "Part A: 缺少先退旧集步骤（不重装时它是正确性保障）"
grep -qF 'Applying the refreshed patch set' "$ALOG" \
  && assert_pass "Part A: 真出现了'应用刷新后的补丁集'这一步" \
  || assert_fail "Part A: 缺少应用新集步骤"
if grep -qF 'Querying npm registry' "$ALOG"; then
  assert_fail "Part A: --self 不该进入 npm 流程"
else
  assert_pass "Part A: 全程没有进入 npm 流程"
fi
V="$(tr -d '[:space:]' < "$RT/VERSION")"
[ "$V" = "$WS_VERSION" ] && assert_pass "Part A: runtime VERSION == 工作区 VERSION ($V)" \
  || assert_fail "Part A: VERSION($V) != 工作区($WS_VERSION)"
missing_scripts=""
for f in update-dsh.sh common.sh patch-lib.sh; do
  cmp -s "$REPO/scripts/$f" "$RT/scripts/$f" || missing_scripts+="${missing_scripts:+, }$f"
done
[ -z "$missing_scripts" ] \
  && assert_pass "Part A: scripts/{update-dsh,common,patch-lib}.sh 逐字装进了 runtime" \
  || assert_fail "Part A: 机件未被逐字安装到 runtime: $missing_scripts"
verify_markers "$RT/scripts/patch-lib.sh" "Part A"
[ -x "$WRAP" ] && assert_pass "Part A: wrapper 被重写" || assert_fail "Part A: wrapper 未重写"
"$WRAP" --version >/dev/null 2>&1 \
  && assert_pass "Part A: 重写的 wrapper 能运行" \
  || assert_fail "Part A: 重写的 wrapper 不能运行"

# --- Part B. 机件签名相同 -> 报告已最新，不重打 --------------------------------
say "== Part B: 签名相同 -> 已最新"
BLOG="$TMP/self-b.log"
if ! bash "$UPDATER" --self --patch-set "$REPO" >"$BLOG" 2>&1; then
  { echo "--- Part B 日志（tail 80） ---"; tail -n 80 "$BLOG"; } >>"$EVID"
  assert_fail "Part B: 已是最新时应 exit 0（日志见证据文件）"
else
  assert_pass "Part B: 已是最新时 exit 0"
fi
{ echo "--- Part B 日志（tail 80） ---"; tail -n 80 "$BLOG"; } >>"$EVID"
grep -qF 'machinery already current' "$BLOG" \
  && assert_pass "Part B: 报告了 machinery already current" \
  || assert_fail "Part B: 缺少 已是最新 报告"
if grep -qF 'Applying the refreshed patch set' "$BLOG"; then
  assert_fail "Part B: 签名相同时不该重打补丁"
else
  assert_pass "Part B: 签名相同时没有重打补丁"
fi

# --- Part C. --force 强制重打；-t/-v 被忽略并提示 -----------------------------
say "== Part C: --force 重打 + -t 忽略提示"
CLOG="$TMP/self-c.log"
# `-t latest` 只为了让"忽略 -t/-v"这条提示出现：--self 从不消费它（也不会因此
# 联网），所以这里不是"写死目标版本"。断言只看提示与应用两步。
if ! bash "$UPDATER" --self --patch-set "$REPO" --force -t latest -y >"$CLOG" 2>&1; then
  { echo "--- Part C 日志（tail 120） ---"; tail -n 120 "$CLOG"; } >>"$EVID"
  assert_fail "Part C: --force 失败（日志见证据文件）"
fi
{ echo "--- Part C 日志（tail 120） ---"; tail -n 120 "$CLOG"; } >>"$EVID"
grep -qF 'Applying the refreshed patch set' "$CLOG" \
  && assert_pass "Part C: --force 真的重打了补丁集" \
  || assert_fail "Part C: --force 未重打"
grep -qF 'applies the patch set only; -t/-v are ignored' "$CLOG" \
  && assert_pass "Part C: 出现了 -t/-v 被忽略的提示" \
  || assert_fail "Part C: 缺少 -t/-v 忽略提示"
if grep -qF 'Querying npm registry' "$CLOG"; then
  assert_fail "Part C: --self 不该进入 npm 流程"
else
  assert_pass "Part C: 全程没有进入 npm 流程"
fi
verify_markers "$RT/scripts/patch-lib.sh" "Part C"

# --- Part D. 本地现打 tarball -> --patch-set 消费（与发布资产同构） -----------
say "== Part D: 本地现打 tarball"
DTAR="$TMP/local-patches.tar.gz"
DLOG="$TMP/self-d.log"
PACKLOG="$TMP/pack.log"
if ! bash "$REPO/build/build-patchset.sh" -r "$REPO" -o "$DTAR" >"$PACKLOG" 2>&1; then
  { echo "--- build-patchset 日志（tail 80） ---"; tail -n 80 "$PACKLOG"; } >>"$EVID"
  assert_fail "Part D: build-patchset.sh 打包失败（日志见证据文件）"
else
  assert_pass "Part D: build-patchset.sh 现打成功"
fi
# 成员清单先读进内存再匹配：`tar | grep -q` 在 pipefail 下会因 grep 提前退出、
# tar 收 SIGPIPE(141) 而误报（release.yml 记录过同一个坑）。
if [ -f "$DTAR" ]; then
  LIST="$(tar -tzf "$DTAR" 2>/dev/null || true)"
  missing_members=""
  for m in scripts/update-dsh.sh scripts/common.sh scripts/patch-lib.sh VERSION; do
    grep -qx "$m" <<<"$LIST" || missing_members+="${missing_members:+, }$m"
  done
  [ -z "$missing_members" ] \
    && assert_pass "Part D: 现打 tarball 带齐补丁集成员（scripts×3 + VERSION）" \
    || { printf '%s\n' "$LIST" >>"$EVID"; assert_fail "Part D: tarball 缺成员: $missing_members"; }
  printf '%s\n' "$FAKE_OLD_PROJECT_VERSION" > "$RT/VERSION"
  if ! bash "$UPDATER" --self --patch-set "$DTAR" >"$DLOG" 2>&1; then
    { echo "--- Part D 日志（tail 120） ---"; tail -n 120 "$DLOG"; } >>"$EVID"
    assert_fail "Part D: 消费本地 tarball 失败（日志见证据文件）"
  fi
  { echo "--- Part D 日志（tail 120） ---"; tail -n 120 "$DLOG"; } >>"$EVID"
  grep -qF "staging local patch set $DTAR" "$DLOG" \
    && assert_pass "Part D: 日志显示本地源路径" \
    || assert_fail "Part D: 未显示本地源"
  grep -qF "project VERSION: $FAKE_OLD_PROJECT_VERSION -> $WS_VERSION" "$DLOG" \
    && assert_pass "Part D: 日志显示 $FAKE_OLD_PROJECT_VERSION -> $WS_VERSION" \
    || assert_fail "Part D: 缺少 旧->新 显示"
  verify_markers "$RT/scripts/patch-lib.sh" "Part D"
else
  assert_fail "Part D: 现打 tarball 不存在，消费路径无从验证"
fi

# --- Part E. 负例：注册表声明的补丁文件缺失 -> 响亮失败且未触碰 runtime --------
say "== Part E: 缺件负例"
BAD="$TMP/badset"
rm -rf "$BAD"; mkdir -p "$BAD"
cp -r "$REPO/scripts" "$REPO/patches" "$BAD/"
cp "$REPO/VERSION" "$BAD/VERSION"
FIRST_PATCH="$(patchset_entries "$REPO/scripts/patch-lib.sh" | head -1 | cut -d: -f1)"
if [ -n "$FIRST_PATCH" ]; then
  assert_pass "Part E: 从工作区注册表派生出了要抽掉的补丁名"
  rm -f "$BAD/patches/$FIRST_PATCH"
else
  assert_fail "Part E: 无法从工作区注册表派生补丁名（断言失效）"
fi
V_BEFORE="$(tr -d '[:space:]' < "$RT/VERSION")"
RT_BEFORE="$(receipt_tree_id "$RT/scripts") $(receipt_tree_id "$RT/patches")"
ELOG="$TMP/self-e.log"
if bash "$UPDATER" --self --patch-set "$BAD" >"$ELOG" 2>&1; then
  { echo "--- Part E 日志（tail 80） ---"; tail -n 80 "$ELOG"; } >>"$EVID"
  assert_fail "Part E: 缺件补丁集应当失败，却退出了 0"
else
  assert_pass "Part E: 缺件补丁集响亮失败（exit 非零）"
fi
{ echo "--- Part E 日志（tail 80） ---"; tail -n 80 "$ELOG"; } >>"$EVID"
grep -qF 'registry names a missing patch file' "$ELOG" \
  && assert_pass "Part E: 失败原因可读（注册表声明了缺失的补丁文件）" \
  || assert_fail "Part E: 缺少缺件报错文本"
V_AFTER="$(tr -d '[:space:]' < "$RT/VERSION")"
[ "$V_BEFORE" = "$V_AFTER" ] \
  && assert_pass "Part E: 校验失败时 VERSION 未变（$V_AFTER）" \
  || assert_fail "Part E: 校验失败却改动了 runtime 的 VERSION（$V_BEFORE -> $V_AFTER）"
[ "$RT_BEFORE" = "$(receipt_tree_id "$RT/scripts") $(receipt_tree_id "$RT/patches")" ] \
  && assert_pass "Part E: 校验失败时 runtime 的 scripts/+patches/ 逐字未变" \
  || assert_fail "Part E: 校验失败却改动了 runtime 的机件（scripts/ 或 patches/）"

# --- Part F. 安装的 updater 不认识哨兵 -> 子 shell 回退应用 -------------------
say "== Part F: 哨兵缺失 -> 子 shell 回退"
OLD="$TMP/oldsentinel"
rm -rf "$OLD"; mkdir -p "$OLD"
cp -r "$REPO/scripts" "$REPO/patches" "$OLD/"
cp "$REPO/VERSION" "$OLD/VERSION"
sed -i 's/DSH_SELF_APPLY_ONLY/DSH_SELF_APPLY_DISABLED/g' "$OLD/scripts/update-dsh.sh"
if grep -qF 'DSH_SELF_APPLY_ONLY' "$OLD/scripts/update-dsh.sh"; then
  assert_fail "Part F: 哨兵串未被移除（注入无效，断言失效）"
else
  assert_pass "Part F: 已把安装的 updater 改成不认识哨兵的老形态"
fi
printf '%s\n' "$FAKE_OLD_PROJECT_VERSION" > "$RT/VERSION"
FLOG="$TMP/self-f.log"
if ! bash "$UPDATER" --self --patch-set "$OLD" >"$FLOG" 2>&1; then
  { echo "--- Part F 日志（tail 120） ---"; tail -n 120 "$FLOG"; } >>"$EVID"
  assert_fail "Part F: 回退路径失败（日志见证据文件）"
fi
{ echo "--- Part F 日志（tail 120） ---"; tail -n 120 "$FLOG"; } >>"$EVID"
grep -qF 'predates apply-only mode' "$FLOG" \
  && assert_pass "Part F: 出现了'老 updater 不认识哨兵'的回退提示" \
  || assert_fail "Part F: 缺少回退提示"
grep -qF 'Applying the refreshed patch set' "$FLOG" \
  && assert_pass "Part F: 回退路径真的应用了补丁集" \
  || assert_fail "Part F: 回退未应用补丁"
verify_markers "$RT/scripts/patch-lib.sh" "Part F"

# --- Part G. 下载路径: --self 从 latest release 资产刷新并应用（无 npm） -------
# 与 Part A/D 同一契约的另一个**输入来源**（ADR-005）：不带 --patch-set 的 `--self`
# 走 fetch_release_patch_set —— 优先 ~40KB 的补丁集资产，发布物没有该资产时回退完整
# runtime tarball 提取同内容。期望的项目版本**从解析出的 latest tag 尾段取**（与旧
# 路线同一派生方式），不写死。
say "== Part G: --self 从 latest release 资产刷新并应用"
# 解析失败 = 缺结论（registry 已声明 network:github，run.sh 会先判；这是第二道）。
# 但**A–F 已经收集到的失败必须优先落定**：case_unmet 是终止型上报，一次网络故障
# 不该把真正的 FAIL 盖成 UNMET（status.sh 的聚合优先级 ERROR > FAIL > UNMET 正是
# 这个意思，这里把它落实在同一条 case 内）。
rrc=0
RTAG="$(resolve_release_tag latest 2>/dev/null)" || rrc=$?
if [ "$rrc" != 0 ] || [ -z "$RTAG" ]; then
  if [ -n "${CASE_FAILURES:-}" ]; then
    case_finish
  fi
  case_unmet "Part G 需要 GitHub：解析 latest release 失败（network:github）"
fi
PV_LATEST="${RTAG##*-}"
say "   latest release: $RTAG（项目 VERSION $PV_LATEST）"
printf '%s\n' "$FAKE_OLD_PROJECT_VERSION" > "$RT/VERSION"
GLOG="$TMP/self-g.log"
if ! bash "$UPDATER" --self >"$GLOG" 2>&1; then
  { echo "--- Part G 日志（tail 120） ---"; tail -n 120 "$GLOG"; } >>"$EVID"
  assert_fail "Part G: --self 下载路径失败（日志见证据文件）"
fi
{ echo "--- Part G 日志（tail 120） ---"; tail -n 120 "$GLOG"; } >>"$EVID"
grep -qF "project VERSION: $FAKE_OLD_PROJECT_VERSION -> $PV_LATEST" "$GLOG" \
  && assert_pass "Part G: 日志显示 $FAKE_OLD_PROJECT_VERSION -> $PV_LATEST" \
  || assert_fail "Part G: 缺少 $FAKE_OLD_PROJECT_VERSION -> $PV_LATEST 显示"
if grep -qF 'Querying npm registry' "$GLOG"; then
  assert_fail "Part G: --self 不该进入 npm 流程"
else
  assert_pass "Part G: 全程没有进入 npm 流程"
fi
VSELF="$(tr -d '[:space:]' < "$RT/VERSION")"
[ "$VSELF" = "$PV_LATEST" ] \
  && assert_pass "Part G: runtime VERSION == latest 项目版本（$PV_LATEST）" \
  || assert_fail "Part G: VERSION($VSELF) != latest 项目版本($PV_LATEST)"
# marker 按**刷新后** runtime 自带的注册表验（下载来的那一份才是实际被打上去的）。
verify_markers "$RT/scripts/patch-lib.sh" "Part G"

# --- 耐久证据 -----------------------------------------------------------------
FACTS="workspace_version=$WS_VERSION fake_old=$FAKE_OLD_PROJECT_VERSION seed=$SEED_TAG seed_dsh=$SEED_DSH_VERSION"
FACTS+=" parts=A,B,C,D,E,F,G (A/C/D/F/G 应用了补丁集; B 跳过; E 负例)"
FACTS+=" latest_tag=${RTAG:-unresolved} latest_project=${PV_LATEST:-unresolved}"
FACTS+=" registry_verified=$RT/scripts/patch-lib.sh"
say "== 事实: $FACTS"
receipt_case_facts "$DSH_RUN_ID" "$DSH_CASE_ID" "$FACTS" \
  || case_error "必要证据（case-facts）写不进去 —— 本次结论不成立"

case_finish
