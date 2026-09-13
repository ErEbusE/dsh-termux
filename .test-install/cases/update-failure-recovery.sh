#!/usr/bin/env bash
# update/failure-recovery — 契约: 更新**失败**或被**中断**之后，runtime 仍处于可恢复
# 状态，用户数据一个字节都没丢（新写的 case；映射表 A.9 第 6 项"失败/恢复状态机覆盖"
# 就是它，依据实查更正 C5）。
#
# 为什么要这条（C5）: `scripts/update-dsh.sh` **先原地 npm 装、补丁失败才退出**——
# 失败时树可能已经被改过。旧文档"补丁打不上就响亮停下，没人会拿到坏安装"因此不成立。
# 这条 case 用**确定性注入**把"失败"变成可复现的实验，并断言三件事：
#   ① 失败是响亮的（非零退出 + 日志里能读到原因）；
#   ② 用户数据（$DSH_HOME 下的会话/附件）逐字未变；
#   ③ runtime 仍可再次更新、仍能启动。
#
# 注入与"窄而真"的边界（宁窄勿假）:
#   * 使用**不可达的 npm registry**（$HOME/.npmrc 指向保留域 .invalid）注入失败：它
#     在解析阶段就失败，**发生在任何原地写入之前**。因此本 case 能主张的是"这次失败
#     没有损坏 runtime"，而不是"任何失败都不损坏"——后者需要 npm 成功之后再让补丁
#     失败，那要求真 npm 网络（registry 的 requires 没有 network:npm）。这条缺口在
#     case-facts 里明确记账。
#   * 中断场景用 `timeout -s KILL`：黑 hole registry 让 npm 卡在元数据请求上，进程被
#     SIGKILL 掉。若该环境让请求快速失败（没有黑洞路由），则记录"未观察到中断"，而不
#     伪造一次中断——两种结局下②③都必须成立。
#   * 两个场景都带 `DSH_SELF_DONE=1`：自动刷新分支（补丁集跨 release 演进）归
#     update/refresh-machinery，这里要测的是 npm 阶段失败后的状态，不让它先把机件换掉。
#
# boot 基线在注入**之前**先测一次（并先把 node 配成 glibc 直连——真实设备上
# install.sh 安装时已经这么做过了），这样"失败之后还能启动"不会被"node 本来就是
# pristine"污染。

set -uo pipefail

. "$DSH_TI_DIR/lib/state.sh"
. "$DSH_TI_DIR/lib/receipt.sh"
. "$DSH_TI_DIR/lib/seed.sh"
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
DSH_BIN="$WORK/node_modules/@deepseek-ai/dsh/lib/bin.js"
PKGJSON="$WORK/node_modules/@deepseek-ai/dsh/package.json"
USERDATA="$DSH_HOME"          # 沙箱内的 ~/.dsh —— 产品的用户状态目录
TMP="$DSH_SANDBOX_ROOT/tmp"
mkdir -p "$TMP" || case_error "无法创建沙箱 tmp: $TMP"   # Termux 禁访系统 /tmp

INJECT_HOST="registry.invalid"          # RFC 2606 保留域：永不解析
BLACKHOLE_REGISTRY="http://10.255.255.1:81/"   # RFC1918 内不可达地址：TCP 连接黑洞

# --- 0. 前置 ------------------------------------------------------------------
command -v timeout >/dev/null 2>&1 \
  || case_unmet "本 case 需要 timeout（coreutils）做有界失败/中断注入"
command -v patchelf >/dev/null 2>&1 \
  || case_unmet "配置种子 node 需要 patchelf（glibc-runner；registry 未声明 host:glibc）"
[ -n "$(ls "$(glibc_prefix)"/lib/ld-linux-*.so.* 2>/dev/null | head -1 || true)" ] \
  || case_unmet "本机没有 glibc loader（$(glibc_prefix)/lib）"
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
TARBALL="$(seed_asset_by_name dsh-termux-runtime.tar.gz)" \
  || case_error "种子事实源没有 dsh-termux-runtime.tar.gz（发布约定缺件）"
say "== 种子 $SEED_TAG（dsh $SEED_DSH_VERSION）"

if ! tar -xzf "$TARBALL" -C "$RT" >>"$EVID" 2>&1; then
  assert_fail "种子 tarball 解包失败（详见证据文件）"
  case_finish
fi
[ -x "$NODE" ] && assert_pass "种子 node 就位" \
  || { assert_fail "种子 node 缺失: $NODE"; case_finish; }
[ -f "$DSH_BIN" ] && assert_pass "已装 dsh 的 CLI 入口在位" \
  || { assert_fail "种子缺 dsh CLI: $DSH_BIN"; case_finish; }
INST_VER="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$PKGJSON" | head -1)"
[ -n "$INST_VER" ] || { assert_fail "无法读取已装 dsh 版本（package.json）"; case_finish; }

# 真实设备上，更新发生在一棵**已经装好**的 runtime 上（install.sh 早已把 node 配成
# glibc 直连）。这里补齐这一步，后面"失败之后还能启动"才是干净的对等比较。
configure_glibc_node "$NODE" >>"$EVID" 2>&1 \
  || { assert_fail "无法把种子 node 配成 glibc 直连（boot 基线无从建立）"; case_finish; }

# 用户数据：会话与附件（产品的 DSH_HOME 布局）。注入前后要比对**整棵目录**，不只是
# 文件存在性——等长改写/被截断这类损坏只比对内容摘要才看得见。
mkdir -p "$USERDATA/sessions" "$USERDATA/attachments" \
  || case_error "无法准备用户数据目录: $USERDATA"
printf '{"sentinel":"failure-recovery","n":1}\n' > "$USERDATA/sessions/sentinel.jsonl"
printf 'attachment-bytes\n' > "$USERDATA/attachments/sentinel.bin"
USERDATA_ID="$(receipt_tree_id "$USERDATA")"

# boot 基线：注入之前 runtime 本来就能启动。
boot_check() { # $1=时点标签
  local label="$1" out rc
  out="$(run_glibc_node "$NODE" "$DSH_BIN" --version 2>&1)"; rc=$?
  say "   boot[$label]: exit=$rc out=${out//$'\n'/ | }"
  [ "$rc" = 0 ] && assert_pass "$label: runtime 能启动（dsh --version exit 0）" \
    || assert_fail "$label: runtime 不能启动 (exit $rc): $out"
  case "$out" in
    *"$INST_VER"*) assert_pass "$label: 启动报出的版本仍是已装版本（$INST_VER）" ;;
    *) assert_fail "$label: 启动报出的版本不含 $INST_VER: $out" ;;
  esac
}
boot_check "注入前（基线）"

# 注入前后要比对的三个身份：被测 dsh 树 / runtime 机件 / 用户数据。
# VERSION 是**文件**，receipt_tree_id 只认目录（对文件一律回 'absent'）——文件身份
# 用内容摘要，免得"两边都 absent"看起来像比对成功。
file_id() { [ -f "$1" ] && sha256sum "$1" | cut -d' ' -f1 || echo absent; }
TREE_ID="$(receipt_tree_id "$WORK/node_modules/@deepseek-ai")"
MACH_ID="$(receipt_tree_id "$RT/scripts") $(receipt_tree_id "$RT/patches") $(file_id "$RT/VERSION")"
say "   基线身份: dsh_tree=$TREE_ID"
say "   基线身份: machinery=$MACH_ID"
say "   基线身份: userdata=$USERDATA_ID"

# invoke_update <日志> <秒上限> <信号>
# 注入就绪后跑**工作区**更新器（被测对象 = scripts/update-dsh.sh）。DSH_SELF_DONE=1
# 跳过自动刷新分支（那条归 update/refresh-machinery），让失败确定地落在 npm 阶段。
invoke_update() {
  local log="$1" secs="$2" sig="$3"
  DSH_SELF_DONE=1 timeout -s "$sig" "$secs" \
    bash "$REPO/scripts/update-dsh.sh" -t latest -y >"$log" 2>&1
}
# 目标用 dist-tag latest：本 case 的 registry 没有 npm-spec 具名输入（没有冻结的精确
# 版本可派生），而注入让 npm **必然**失败，所以目标具体是哪一版与断言无关。

# --- 1. 场景 A: 不可达 registry -> 响亮失败、什么都没被改坏 -------------------
say "== 场景 A: 注入不可达 registry（$INJECT_HOST）"
printf 'registry=http://%s/\n' "$INJECT_HOST" > "$HOME/.npmrc" \
  || case_error "无法写注入用的 $HOME/.npmrc"
ALOG="$TMP/failure-a.log"
invoke_update "$ALOG" 600 TERM; a_rc=$?
{ echo "--- 场景 A 日志（tail 120） ---"; tail -n 120 "$ALOG"; } >>"$EVID"
if [ "$a_rc" = 124 ] || [ "$a_rc" = 143 ]; then
  assert_fail "场景 A: 更新在注入的不可达 registry 下挂住了（既没成功也没有可读失败，exit $a_rc）"
elif [ "$a_rc" = 0 ]; then
  assert_fail "场景 A: 不可达 registry 下更新竟然退出了 0"
else
  assert_pass "场景 A: 失败是响亮的（exit $a_rc）"
fi
# 可读原因：日志必须让维护者看得出"是 registry 解析不了"，而不是一句无头错误。
if grep -qF "$INJECT_HOST" "$ALOG"; then
  assert_pass "场景 A: 日志指名了注入的 registry（$INJECT_HOST）"
elif grep -qiE 'ENOTFOUND|EAI_AGAIN|ECONNREFUSED|ETIMEDOUT' "$ALOG"; then
  assert_pass "场景 A: 日志给出了可读的网络错误码"
else
  assert_fail "场景 A: 日志里读不出失败原因（详见证据文件）"
fi
grep -qF 'Querying npm registry' "$ALOG" \
  && assert_pass "场景 A: 确实走到了 npm 阶段才失败" \
  || assert_fail "场景 A: 没有走到 npm 阶段（注入点不对，断言失效）"
# ② 用户数据逐字未变。
[ "$(receipt_tree_id "$USERDATA")" = "$USERDATA_ID" ] \
  && assert_pass "场景 A: 用户数据（\$DSH_HOME 整棵树）逐字未变" \
  || assert_fail "场景 A: 用户数据被改动了"
[ "$(cat "$USERDATA/sessions/sentinel.jsonl" 2>/dev/null)" = '{"sentinel":"failure-recovery","n":1}' ] \
  && assert_pass "场景 A: 会话哨兵文件仍在且内容正确" \
  || assert_fail "场景 A: 会话哨兵文件丢失或被改写"
# 这个注入在解析阶段就失败 -> 树本身不该被碰过。这是本 case 能主张的边界（见文件头）。
[ "$(receipt_tree_id "$WORK/node_modules/@deepseek-ai")" = "$TREE_ID" ] \
  && assert_pass "场景 A: 已装 dsh 树逐字未变（注入发生在任何原地写入之前）" \
  || assert_fail "场景 A: 已装 dsh 树被改动了"
[ "$(receipt_tree_id "$RT/scripts") $(receipt_tree_id "$RT/patches") $(file_id "$RT/VERSION")" = "$MACH_ID" ] \
  && assert_pass "场景 A: runtime 机件（scripts/+patches/+VERSION）逐字未变" \
  || assert_fail "场景 A: runtime 机件被改动了"
# ③ 还能启动。
boot_check "场景 A 之后"

# 可再次更新：同一个注入下再跑一次，仍要在同一点响亮失败（没有被前一次失败卡死）。
say "== 场景 A': 再次运行（可再更新性）"
A2LOG="$TMP/failure-a2.log"
invoke_update "$A2LOG" 600 TERM; a2_rc=$?
{ echo "--- 场景 A' 日志（tail 60） ---"; tail -n 60 "$A2LOG"; } >>"$EVID"
[ "$a2_rc" != 0 ] && assert_pass "场景 A': 第二次运行仍响亮失败（exit $a2_rc）" \
  || assert_fail "场景 A': 第二次运行竟然成功（不可达 registry 下不可能）"
grep -qF 'Querying npm registry' "$A2LOG" \
  && assert_pass "场景 A': 第二次运行仍在同一阶段失败（更新器未卡死）" \
  || assert_fail "场景 A': 第二次运行没有走到 npm 阶段（更新器状态可能已损坏）"
[ "$(receipt_tree_id "$WORK/node_modules/@deepseek-ai")" = "$TREE_ID" ] \
  && assert_pass "场景 A': 第二次运行也没有改动已装 dsh 树" \
  || assert_fail "场景 A': 第二次运行改动了已装 dsh 树"

# --- 1b. 可恢复性（补丁管线视角）：树没有被留在"半退"状态 ---------------------
# 下一次更新要在 npm 之后重新跑整条补丁管线；它能不能开工，取决于这棵树是否还处在
# 该管线认得的状态。逐条用**工作区注册表**（registry 的 changes 声明的正是它）判定：
#   * 不适用（该 dsh 版本没有这段上游代码）        -> 跳过，记账；
#   * 适用且 marker 在场（补丁还在）               -> 好；
#   * 适用但 marker 不在（npm 侧从未被改过/已被还原）-> 补丁必须还能**干净地 check 上**
#     （--check 不改动任何东西）。两条都不成立，就是"半退"——下一次更新也救不回来。
say "== 补丁管线可恢复性（工作区注册表）"
# shellcheck source=../../scripts/patch-lib.sh
. "$REPO/scripts/patch-lib.sh"
WPREF="$(dsh_git_worktree_prefix "$WORK")"
n_marked=0; n_clean=0; n_na=0; halfstate=""
for entry in "${DSH_PATCH_SET[@]}"; do
  IFS=: read -r pfile rel marker _ <<<"$entry"
  target="$WORK/node_modules/@deepseek-ai/$rel"
  if ! dsh_patch_applicable "$WORK" "$entry"; then
    n_na=$((n_na + 1)); continue
  fi
  if [ -n "$marker" ] && grep -qF -- "$marker" "$target" 2>/dev/null; then
    n_marked=$((n_marked + 1)); continue
  fi
  if git -C "$WORK" apply --directory="${WPREF}node_modules/@deepseek-ai" --check \
      "$REPO/patches/$pfile" >/dev/null 2>&1; then
    n_clean=$((n_clean + 1))
  else
    halfstate+="${halfstate:+, }$pfile"
  fi
done
say "   已打上 marker=$n_marked；可干净 check=$n_clean；不适用=$n_na"
if [ -z "$halfstate" ]; then
  assert_pass "失败之后补丁管线仍认得这棵树（没有条目停在半退状态）"
else
  assert_fail "失败之后有补丁既没打上也不能干净 check（半退状态）: $halfstate"
fi
if [ "$n_na" -gt 0 ]; then
  say "   覆盖率缺口: $n_na 条条件补丁不适用于该 dsh 版本（不适用 ≠ 已验证）"
fi

# --- 2. 场景 B: 中断（SIGKILL）-> 用户数据与可运行性仍成立 -------------------
# 黑洞 registry 让 npm 卡在元数据请求上，`timeout -s KILL` 到点把整组进程杀掉。
# 若这个环境让请求快速失败（没有黑洞路由），就记录"未观察到中断"，不伪造结论。
say "== 场景 B: 中断注入（blackhole registry + SIGKILL）"
printf 'registry=%s\n' "$BLACKHOLE_REGISTRY" > "$HOME/.npmrc" \
  || case_error "无法写注入用的 $HOME/.npmrc"
BLOG="$TMP/failure-b.log"
B_SECS=45
invoke_update "$BLOG" "$B_SECS" KILL; b_rc=$?
{ echo "--- 场景 B 日志（tail 120） ---"; tail -n 120 "$BLOG"; } >>"$EVID"
INTERRUPT_OBSERVED=no
case "$b_rc" in
  137|124)  # 128+9 = SIGKILL；部分 timeout 用 124 表示超时
    INTERRUPT_OBSERVED=yes
    assert_pass "场景 B: 观察到中断（进程在更新途中被 SIGKILL，exit $b_rc）"
    if grep -qF 'Done. dsh is now' "$BLOG"; then
      assert_fail "场景 B: 被中断的那次却不该已经完成"
    else
      assert_pass "场景 B: 被中断的那次没有走完（无 Done 行）"
    fi ;;
  0)
    assert_fail "场景 B: blackhole registry 下更新竟然退出了 0" ;;
  *)
    # 快速失败型环境：这不是中断，但也必须同样满足②③；如实记账。
    say "   note: 本环境未观察到中断（exit $b_rc，registry 快速失败而非挂起）—— 记为覆盖率缺口"
    assert_pass "场景 B: 注入确实让更新失败（exit $b_rc），但未构成中断（已记账）" ;;
esac
# ② 用户数据：中断与否都必须逐字未变。
[ "$(receipt_tree_id "$USERDATA")" = "$USERDATA_ID" ] \
  && assert_pass "场景 B: 用户数据（\$DSH_HOME 整棵树）逐字未变" \
  || assert_fail "场景 B: 用户数据被改动了"
[ "$(cat "$USERDATA/sessions/sentinel.jsonl" 2>/dev/null)" = '{"sentinel":"failure-recovery","n":1}' ] \
  && assert_pass "场景 B: 会话哨兵文件仍在且内容正确" \
  || assert_fail "场景 B: 会话哨兵文件丢失或被改写"
# 黑洞/不可达注入同样到不了 npm 的写入阶段，所以树与机件仍应逐字未变。
[ "$(receipt_tree_id "$WORK/node_modules/@deepseek-ai")" = "$TREE_ID" ] \
  && assert_pass "场景 B: 已装 dsh 树逐字未变" \
  || assert_fail "场景 B: 已装 dsh 树被改动了"
[ "$(receipt_tree_id "$RT/scripts") $(receipt_tree_id "$RT/patches") $(file_id "$RT/VERSION")" = "$MACH_ID" ] \
  && assert_pass "场景 B: runtime 机件逐字未变" \
  || assert_fail "场景 B: runtime 机件被改动了"
# ③ 中断之后仍能启动。
boot_check "场景 B 之后"

# 收尾：把注入撤掉，证明这台 runtime 仍是"可再更新"的正常状态（能重新走到 npm 阶段）。
rm -f "$HOME/.npmrc"
say "   注入已撤除（$HOME/.npmrc 删除）"

# --- 3. 耐久证据 -------------------------------------------------------------
FACTS="seed=$SEED_TAG seed_dsh=$SEED_DSH_VERSION installed=$INST_VER"
FACTS+=" inject=$INJECT_HOST a_exit=$a_rc a2_exit=$a2_rc b_exit=$b_rc interrupt=$INTERRUPT_OBSERVED"
FACTS+=" userdata_id=$USERDATA_ID dsh_tree_id=$TREE_ID"
FACTS+=" reconcilable:marked=$n_marked clean_check=$n_clean not_applicable=$n_na"
FACTS+=" gap=post-mutation-failure-not-covered(needs network:npm + patch-failure injection)"
say "== 事实: $FACTS"
receipt_case_facts "$DSH_RUN_ID" "$DSH_CASE_ID" "$FACTS" \
  || case_error "必要证据（case-facts）写不进去 —— 本次结论不成立"

case_finish
