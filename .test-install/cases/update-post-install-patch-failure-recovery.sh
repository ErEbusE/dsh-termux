#!/usr/bin/env bash
# update/post-install-patch-failure-recovery — 契约: **npm 已经把安装树改写之后**
# 补丁应用失败时，用户数据不丢，且**在同一棵失败树上**（不还原 npm 树、不重建种子）
# 重跑更新能恢复到通过既定 boot 探针的状态。
#
# 为什么要独立一条（实查更正 C5 的另一半，见 STATUS 7f）:
# `update/failure-recovery` 证明的是 npm **解析/元数据阶段**的确定性失败与一次被
# 观察到的中断——那两种注入都发生在任何原地写入**之前**。真正危险的那一半是
# **npm 成功改写安装树之后**补丁才失败：此时树已经不是原来的样子了，用户可能拿到
# 一个"dsh 是新的、补丁没打上"的安装（session 保存与 write 工具在 Android 上会坏）。
# 这条 case 就是把那一半做成可复现、可归属的实验。
#
# 注入（ADR 允许的窄作用域 failpoint；不碰生产脚本）:
#   一个委派真实 git 的 **shim** 放在沙箱 PATH 首位（`$DSH_SANDBOX_ROOT/bin`），
#   只拦**一次**调用：`git -C <固定工作树> apply --directory=<固定目录> <补丁文件>`
#   —— 即 `dsh_apply_patch` 里那次**真正改写文件**的**正向** apply
#   （patch-lib.sh:85；它既没有 `--check` 也没有 `--reverse`）。
#   其余全部透传：`--check`、`--reverse`、`--reverse --check`、`rev-parse`、
#   `hash-object`，以及**任何别的 -C 目标**。不伪造 npm 成功、不碰 `--self`。
#   shim 由 `arm` 文件开关，所以"关注入"与"开注入"用的是**同一个 shim、同一套配置**。
#
# 双控制属于本 case 自己的同配置实验（不借成功路径 case 的历史结果）:
#   * 关注入 → 同克隆的种子、同目标、同 shim：真实 npm ＋ 真实补丁 ＋ boot **成功**；
#   * 开注入 → 必须**独立**证明 npm exit 0、受管内容相对"注入已就位、更新尚未开始"
#     的快照**确实变化**、**精确命中一次**补丁调用、updater **响亮非零**。
#   未命中、或提前误触发 = **ERROR**（注入/框架故障）；缺网络/缺目标产物 = **UNMET**；
#   已观察到的契约否定保留 **FAIL**。
#
# 恢复的定义（不得加重）: 只撤销注入，**不还原 npm 树、不重建种子**，在同一棵失败树上
# 真实重跑更新并成功、必需补丁状态正确、boot 成功、持久用户内容仍在。
# **立即 boot 与恢复后 boot 分别记账**：后者只证明"按该步骤可恢复到通过既定 boot
# 探针"，**不**证明失败瞬间可用、原子更新、自动回滚、功能完整或任意中断无损；
# 只跑 `--help`／`--check`／重复失败**不算**恢复成功。全程 `DSH_SELF_DONE=1`
# （自动刷新分支归 update/refresh-machinery）。

set -uo pipefail

. "$DSH_TI_DIR/lib/state.sh"
. "$DSH_TI_DIR/lib/receipt.sh"
. "$DSH_TI_DIR/lib/seed.sh"
. "$DSH_TI_DIR/lib/patchset.sh"
. "$DSH_TI_DIR/lib/probes.sh"
. "$DSH_HARNESS_ROOT/scripts/common.sh"
# DSH_PATCH_SET 与 dsh_* 助手来自工作区注册表；本 case 在控制组就要用它判定 marker，
# 所以在**动手之前**引入（不要等到恢复阶段才 source，那时 `set -u` 下已是未绑定变量）。
# shellcheck source=../../scripts/patch-lib.sh
. "$DSH_HARNESS_ROOT/scripts/patch-lib.sh"

case_begin

EVID="$(dirname "$DSH_RESULTS")/evidence-${DSH_CASE_ID//\//-}.txt"
mkdir -p "$(dirname "$EVID")" || case_error "无法创建证据目录 $(dirname "$EVID")"
: > "$EVID" || case_error "无法写证据文件 $EVID"
say() { printf '%s\n' "$*" | tee -a "$EVID" >&2; }

REPO="$DSH_HARNESS_ROOT"
WORK="$DSH_WORK_DIR"
RT="$DSH_RUNTIME_DIR"
NODE="$RT/node/bin/node"
PKGJSON="$WORK/node_modules/@deepseek-ai/dsh/package.json"
USERDATA="$DSH_HOME"
TMP="$DSH_SANDBOX_ROOT/tmp"
mkdir -p "$TMP" || case_error "无法创建沙箱 tmp: $TMP"

# 控制组（关注入）用**另一棵同克隆的种子**：注入组必须从 pristine 状态出发，才能
# 主张"npm 改写了树"。两组共用同一个 shim（靠 arm 开关切换），所以配置相同。
CTL="$DSH_SANDBOX_ROOT/ctl"
CTL_RT="$CTL/rt"
CTL_WORK="$CTL_RT/work"
CTL_BIN="$CTL/bin"

BASH_BIN="${BASH:-/data/data/com.termux/files/usr/bin/bash}"
SHIM_DIR="$DSH_SANDBOX_ROOT/bin"          # 沙箱 PATH 首位（lib/sandbox.sh:101）
SHIM="$SHIM_DIR/git"
REAL_GIT=""                               # 解析后钉死，避免 shim 递归调用自己
ARM_FILE="$CTL/arm"
HIT_LOG="$CTL/git-hits.log"
CALL_LOG="$CTL/git-calls.log"
INJECT_EXIT=97                             # 专用退出码：既不是 git 的 0/1/128，也不是 timeout 的 124/137

# --- 0. 前置（先判"这轮能不能得出结论"，再动任何东西） -----------------------
for t in git patchelf readelf; do
  command -v "$t" >/dev/null 2>&1 \
    || case_unmet "本 case 需要 $t（补丁管线/隔离与 glibc 断言；registry 未声明 host:glibc）"
done
[ -n "$(ls "$(glibc_prefix)"/lib/ld-linux-*.so.* 2>/dev/null | head -1 || true)" ] \
  || case_unmet "本机没有 glibc loader（$(glibc_prefix)/lib）"
[ -n "${DSH_NPM_TARGET_FILE:-}" ] || case_unmet "本轮没有冻结的 npm 目标（未解析或解析失败）"
[ -f "$DSH_NPM_TARGET_FILE" ] || case_error "冻结文件不存在: $DSH_NPM_TARGET_FILE"
[ -n "${DSH_NPM_VERSION:-}" ] || case_error "冻结输入缺 version —— '升到哪一版'无从谈起"

seed_name="$(seed_default_name)"
seed_load_require "$seed_name"
TARBALL="$(seed_asset_by_name dsh-termux-runtime.tar.gz)" \
  || case_error "种子事实源没有 dsh-termux-runtime.tar.gz（发布约定缺件）"
say "== 种子 $SEED_TAG（dsh $SEED_DSH_VERSION）；冻结目标 $DSH_NPM_VERSION"

# --- 1. 两棵同克隆的种子树 ----------------------------------------------------
say "== 解出两棵种子树（注入组 + 关注入控制组）"
mkdir -p "$RT" "$CTL_RT" "$SHIM_DIR" "$CTL_BIN" || case_error "无法创建沙箱目录"
for d in "$RT" "$CTL_RT"; do
  if ! tar -xzf "$TARBALL" -C "$d" >>"$EVID" 2>&1; then
    assert_fail "种子 tarball 解包失败: $d（详见证据文件）"; case_finish
  fi
done
[ -x "$NODE" ] && assert_pass "种子 node 就位" \
  || { assert_fail "种子 node 缺失: $NODE"; case_finish; }
[ -x "$CTL_RT/node/bin/node" ] && assert_pass "控制组 node 就位" \
  || { assert_fail "控制组 node 缺失"; case_finish; }

read_ver() { # $1=package.json -> 版本
  sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$1" 2>/dev/null | head -1
}
INST_VER="$(read_ver "$PKGJSON")"
[ -n "$INST_VER" ] || { assert_fail "无法读取种子 dsh 版本"; case_finish; }
say "   种子 dsh 版本: $INST_VER"
# 两棵树必须逐字同源，否则"同克隆"这个前提本身不成立。
TREE_SRC_ID="$(receipt_tree_id "$WORK/node_modules/@deepseek-ai")"
CTL_SRC_ID="$(receipt_tree_id "$CTL_WORK/node_modules/@deepseek-ai")"
[ "$TREE_SRC_ID" = "$CTL_SRC_ID" ] \
  && assert_pass "两棵种子树的受管内容逐字相同（双控制同源）" \
  || assert_fail "两棵种子树的受管内容不同（双控制不同源）: $TREE_SRC_ID vs $CTL_SRC_ID"

# 真实设备上更新发生在一棵**已装好**的 runtime 上（install.sh 早已配好 glibc 直连）。
for n in "$NODE" "$CTL_RT/node/bin/node"; do
  configure_glibc_node "$n" >>"$EVID" 2>&1 \
    || { assert_fail "无法把种子 node 配成 glibc 直连（boot 基线无从建立）: $n"; case_finish; }
done
assert_pass "两棵树的 node 都已配成 glibc 直连"

# --- 2. 用户数据 + boot 基线 ---------------------------------------------------
mkdir -p "$USERDATA/sessions" "$USERDATA/attachments" || case_error "无法准备用户数据目录"
printf '{"sentinel":"post-install-patch-failure","n":1}\n' > "$USERDATA/sessions/sentinel.jsonl"
printf 'attachment-bytes\n' > "$USERDATA/attachments/sentinel.bin"
USERDATA_ID="$(receipt_tree_id "$USERDATA")"
say "   用户数据基线身份: $USERDATA_ID"

boot_check() { # $1=标签 $2=node $3=bin.js $4=期望版本
  local label="$1" node="$2" bin="$3" want="$4" out rc
  out="$(run_glibc_node "$node" "$bin" --version 2>&1)"; rc=$?
  say "   boot[$label]: exit=$rc out=${out//$'\n'/ | }"
  [ "$rc" = 0 ] && assert_pass "$label: 能启动（--version exit 0）" \
    || assert_fail "$label: 不能启动 (exit $rc): $out"
  case "$out" in
    *"$want"*) assert_pass "$label: 启动版本含 $want" ;;
    *) assert_fail "$label: 启动版本不含 $want: $out" ;;
  esac
}
boot_check "注入前（基线）" "$NODE" "$WORK/node_modules/@deepseek-ai/dsh/lib/bin.js" "$INST_VER"

# --- 3. git shim（同配置开关；默认 disarm） ------------------------------------
REAL_GIT="$(command -v git)"
case "$REAL_GIT" in /*) ;; *) case_error "git 不在绝对路径上: $REAL_GIT" ;; esac
[ -x "$REAL_GIT" ] || case_error "git 不可执行: $REAL_GIT"

# shebang 现算：内核 `#!` 解析用字面绝对路径，且不做变量展开（ADR-012）。未加引号的
# heredoc 会在**生成时**展开 ${BASH:-…}，与 cases/release-install-download-path.sh:115 同一手法。
cat > "$SHIM" <<SHIM_EOF
#!${BASH_BIN}
# 补丁执行边界 failpoint（本 case 专用，不是生产脚本）。
# 只拦"正向、非 --check、非 --reverse 的 apply 到固定工作树上的工作区补丁"这一次调用；
# 其余一律透传真实 git。
set -uo pipefail
REAL_GIT='${REAL_GIT}'
ARM_FILE='${ARM_FILE}'
HIT_LOG='${HIT_LOG}'
CALL_LOG='${CALL_LOG}'
FIXED_WORK='${WORK}'
PATCH_DIR='${REPO}/patches'
INJECT_EXIT='${INJECT_EXIT}'

# 记录本次调用（便于事后核对"漏拦/误拦"），并判断是否命中。
is_apply=0; has_check=0; has_reverse=0; cdir=''; patchfile=''
prev=''
for a in "\$@"; do
  case "\$a" in
    apply) is_apply=1 ;;
    --check) has_check=1 ;;
    --reverse) has_reverse=1 ;;
    --directory=*) ;;
    -C) ;;
    --*) ;;
    *)
      if [ "\$prev" = '-C' ]; then cdir="\$a"; fi
      case "\$a" in *.patch) patchfile="\$a" ;; esac ;;
  esac
  prev="\$a"
done
printf '%s\tapply=%s check=%s reverse=%s C=%s patch=%s\n' \
  "\${*:0:1}" "\$is_apply" "\$has_check" "\$has_reverse" "\$cdir" "\${patchfile##*/}" >> "\$CALL_LOG" 2>/dev/null || true

hit=0
if [ -f "\$ARM_FILE" ] && [ "\$is_apply" = 1 ] && [ "\$has_check" = 0 ] && [ "\$has_reverse" = 0 ] \\
   && [ "\$cdir" = "\$FIXED_WORK" ] && [ -n "\$patchfile" ]; then
  # 补丁身份也要固定：必须是工作区 patches/ 下的真实补丁文件。
  case "\$patchfile" in
    "\$PATCH_DIR"/*.patch) [ -f "\$patchfile" ] && hit=1 ;;
  esac
fi
if [ "\$hit" = 1 ]; then
  printf 'HIT %s %s\n' "\$cdir" "\${patchfile##*/}" >> "\$HIT_LOG" 2>/dev/null || true
  echo "shim: refusing the forward patch apply (injected failpoint)" >&2
  exit "\$INJECT_EXIT"
fi
exec "\$REAL_GIT" "\$@"
SHIM_EOF
chmod +x "$SHIM" || case_error "无法启用 git shim"
: > "$CALL_LOG"; : > "$HIT_LOG"; rm -f "$ARM_FILE"
assert_pass "git shim 就位（默认 disarmed）: $SHIM"
say "   PATH 首位: $SHIM_DIR；真实 git: $REAL_GIT"

# invoke_update <runtime> <work> <bin> <日志> [秒上限]
# 固定 `-v <冻结目标>`：一轮里只解析一次目标，结论才绑得住被测对象（ADR-009）。
invoke_update() {
  local rt="$1" work="$2" bin="$3" log="$4" secs="${5:-900}"
  DSH_SELF_DONE=1 DSH_RUNTIME_DIR="$rt" DSH_WORK_DIR="$work" DSH_BIN_DIR="$bin" \
    timeout "$secs" bash "$REPO/scripts/update-dsh.sh" -v "$DSH_NPM_VERSION" -y >"$log" 2>&1
}

# --- 4. 控制组：关注入 -> 同 shim 下真实 npm ＋ 真实补丁 ＋ boot 成功 ----------
# 这一段证明 shim 本身不扰动成功路径（否则注入组的"失败"就归因不到注入）。
say "== 控制组（关注入）: 同克隆种子 / 同目标 / 同 shim"
CTL_LOG="$TMP/ctl.log"
invoke_update "$CTL_RT" "$CTL_WORK" "$CTL_BIN" "$CTL_LOG"; ctl_rc=$?
{ echo "--- 控制组日志（tail 80） ---"; tail -n 80 "$CTL_LOG"; } >>"$EVID"
[ "$ctl_rc" = 0 ] && assert_pass "控制组: 更新成功（exit 0）" \
  || assert_fail "控制组: 更新失败（exit $ctl_rc）—— shim 扰动成功路径，注入组结论不成立"
CTL_VER="$(read_ver "$CTL_WORK/node_modules/@deepseek-ai/dsh/package.json")"
[ "$CTL_VER" = "$DSH_NPM_VERSION" ] \
  && assert_pass "控制组: 安装树版本 == 冻结目标（$CTL_VER）" \
  || assert_fail "控制组: 安装树版本($CTL_VER) != 冻结目标($DSH_NPM_VERSION)"
[ ! -s "$HIT_LOG" ] && assert_pass "控制组: shim 记录到 0 次命中（未误拦）" \
  || assert_fail "控制组: shim 在关注入时仍有命中（注入开关失效）"
# 控制组的补丁 marker 齐全：证明"同一套配置下补丁本来打得进去"。
# 只验**适用**的条目：条件补丁在该 dsh 版本上不适用时根本不会被应用（dsh_apply_patch_set
# 会 skip），对它要求 marker 会把正常状态误判成红（旧体系踩过，勿回退 #22 同类）。
CTL_APPLIED=(); n_ctl_na=0
for entry in "${DSH_PATCH_SET[@]}"; do
  if dsh_patch_applicable "$CTL_WORK" "$entry"; then CTL_APPLIED+=("$entry"); else n_ctl_na=$((n_ctl_na + 1)); fi
done
[ "${#CTL_APPLIED[@]}" -gt 0 ] \
  && assert_pass "控制组: 有 ${#CTL_APPLIED[@]} 条补丁适用于该树" \
  || assert_fail "控制组: 没有任何补丁适用（补丁集重打无从谈起）"
if [ "${#CTL_APPLIED[@]}" -gt 0 ]; then
  if dsh_verify_patch_markers "$CTL_WORK" "${CTL_APPLIED[@]}" >>"$EVID" 2>&1; then
    assert_pass "控制组: 全部适用补丁的 marker 齐全"
  else
    assert_fail "控制组: 有适用补丁 marker 缺失（详见证据文件）"
  fi
fi
[ "$n_ctl_na" -gt 0 ] \
  && say "   控制组覆盖率缺口: $n_ctl_na 条条件补丁不适用（不适用 ≠ 已验证）"
boot_check "控制组之后" "$CTL_RT/node/bin/node" \
  "$CTL_WORK/node_modules/@deepseek-ai/dsh/lib/bin.js" "$DSH_NPM_VERSION"

# --- 5. 注入组：npm 成功改写树之后补丁失败 ------------------------------------
say "== 注入组: arm 后跑更新（期望：npm 成功、补丁被拦、updater 响亮非零）"
: > "$CALL_LOG"; : > "$HIT_LOG"
TREE_BEFORE="$(receipt_tree_id "$WORK/node_modules/@deepseek-ai")"
say "   更新前受管内容身份（快照）: $TREE_BEFORE"
printf '1\n' > "$ARM_FILE" || case_error "无法 arm 注入"
ILOG="$TMP/injected.log"
invoke_update "$RT" "$WORK" "$DSH_BIN_DIR" "$ILOG"; inj_rc=$?
{ echo "--- 注入组日志（tail 120） ---"; tail -n 120 "$ILOG"; } >>"$EVID"

# updater 必须**响亮**非零，并给出人话原因（不是静默、不是 0）。
[ "$inj_rc" != 0 ] && assert_pass "注入组: updater 响亮非零（exit $inj_rc）" \
  || assert_fail "注入组: 补丁被拦，updater 竟然退出了 0"
grep -qF 'Patches do not apply' "$ILOG" \
  && assert_pass "注入组: 日志给出人话原因（Patches do not apply）" \
  || assert_fail "注入组: 日志里读不出补丁失败的原因"

# 精确命中：**一次**拦截（多次 = 注入点漂移到别的调用；零次 = 根本没走到补丁阶段）。
HITS="$(grep -c '^HIT ' "$HIT_LOG" 2>/dev/null || true)"
[ "$HITS" = 1 ] && assert_pass "注入组: 精确命中 1 次补丁应用调用" \
  || case_error "注入组: 命中 $HITS 次（期望 1）—— 注入点不对，本 case 结论不成立"
# 透传必须仍然发生：证明拦的是"那一次"，不是把所有 git 调用都掐了。
PASSTHRU="$(grep -c 'apply=1' "$CALL_LOG" 2>/dev/null || true)"
[ "${PASSTHRU:-0}" -ge 2 ] \
  && assert_pass "注入组: 仍有 $PASSTHRU 次 apply 调用透传（拦的是单点，不是整条管线）" \
  || assert_fail "注入组: 只有 ${PASSTHRU:-0} 次 apply 调用——疑似把所有 git 调用都拦了"

# npm 确实成功：安装树版本已经变成冻结目标（只有 npm 能造成这一点）。
INJ_VER="$(read_ver "$PKGJSON")"
[ "$INJ_VER" = "$DSH_NPM_VERSION" ] \
  && assert_pass "注入组: npm 确实成功改写了安装树（版本 $INST_VER -> $INJ_VER）" \
  || assert_fail "注入组: 安装树版本($INJ_VER) != 冻结目标($DSH_NPM_VERSION) —— npm 未成功，实验前提不成立"
# 受管内容相对"注入已就位、更新尚未开始"的快照**确实变化**（排除注入文件/日志/时间戳：
# shim 与日志都在沙箱 bin/tmp 下，**不在**受管树内；receipt_tree_id 只看内容/权限，不看 mtime）。
TREE_AFTER="$(receipt_tree_id "$WORK/node_modules/@deepseek-ai")"
[ "$TREE_BEFORE" != "$TREE_AFTER" ] \
  && assert_pass "注入组: 受管内容相对快照确实变化（npm 真的改写了树）" \
  || assert_fail "注入组: 受管内容未变（无法区分'npm 没成功'与'补丁失败'）"
# 用户数据此时就必须没丢（失败瞬间）。
[ "$(receipt_tree_id "$USERDATA")" = "$USERDATA_ID" ] \
  && assert_pass "注入组: 用户数据逐字未变" \
  || assert_fail "注入组: 用户数据被改动了"
# **失败瞬间的降级状态必须被证明**，否则上面那条"能启动"会被误读成"这次失败无害"。
# 此刻树是"新 npm 树 + 补丁未打上"——也就是本 case 存在的理由：CLI 能报版本，
# 但补丁带来的行为在 Android 上并不在位。逐条检查**适用**补丁的 marker：
# 至少有一条必需补丁的 marker 缺席，才说明这确实是受损状态而非无事发生。
INJ_APPLIED=(); n_inj_na=0
for entry in "${DSH_PATCH_SET[@]}"; do
  if dsh_patch_applicable "$WORK" "$entry"; then INJ_APPLIED+=("$entry"); else n_inj_na=$((n_inj_na + 1)); fi
done
n_inj_marked=0; n_inj_missing=0
for entry in "${INJ_APPLIED[@]}"; do
  IFS=: read -r _ rel marker _ <<<"$entry"
  if grep -qF -- "$marker" "$WORK/node_modules/@deepseek-ai/$rel" 2>/dev/null; then
    n_inj_marked=$((n_inj_marked + 1))
  else
    n_inj_missing=$((n_inj_missing + 1))
  fi
done
say "   失败瞬间: 适用补丁 ${#INJ_APPLIED[@]} 条，marker 在场 $n_inj_marked，缺席 $n_inj_missing"
[ "$n_inj_missing" -gt 0 ] \
  && assert_pass "注入组: 失败瞬间确有 $n_inj_missing 条适用补丁的 marker 缺席（安装处于降级状态，不是无事发生）" \
  || assert_fail "注入组: 补丁被拦却仍有全部 marker 在场 —— 注入没有真正阻止补丁生效"
# 单独的"CLI 能报版本"只说明二进制可执行，**不**说明安装可用（勿把两者混为一谈）。
boot_check "注入后（立即，仅证明可执行）" "$NODE" "$WORK/node_modules/@deepseek-ai/dsh/lib/bin.js" "$DSH_NPM_VERSION"
say "   note: 上面这条只证明 CLI 可执行；破坏的是补丁带来的行为（$n_inj_missing 条 marker 缺席）。失败瞬间的可用性**不在**本 case 的主张范围内。"

# --- 6. 恢复：只撤注入，不还原 npm 树、不重建种子 -----------------------------
say "== 恢复：仅撤除注入，在同一棵失败树上重跑更新"
rm -f "$ARM_FILE"
: > "$CALL_LOG"; : > "$HIT_LOG"
REC_LOG="$TMP/recovery.log"
invoke_update "$RT" "$WORK" "$DSH_BIN_DIR" "$REC_LOG"; rec_rc=$?
{ echo "--- 恢复日志（tail 120） ---"; tail -n 120 "$REC_LOG"; } >>"$EVID"
[ "$rec_rc" = 0 ] && assert_pass "恢复: 同一棵失败树上重跑更新成功（exit 0）" \
  || assert_fail "恢复: 重跑更新仍失败（exit $rec_rc）—— 未证明可恢复"
[ ! -s "$HIT_LOG" ] && assert_pass "恢复: shim 未再拦截（注入确已撤除）" \
  || assert_fail "恢复: 撤除注入后 shim 仍有命中"
grep -qF 'Done. dsh is now' "$REC_LOG" \
  && assert_pass "恢复: 更新器走完了完整流程（有 Done 行）" \
  || assert_fail "恢复: 更新器没有走完（无 Done 行）"
REC_VER="$(read_ver "$PKGJSON")"
[ "$REC_VER" = "$DSH_NPM_VERSION" ] \
  && assert_pass "恢复: 安装树版本 == 冻结目标（$REC_VER）" \
  || assert_fail "恢复: 安装树版本($REC_VER) != 冻结目标($DSH_NPM_VERSION)"
# 必需补丁状态正确：逐条按**工作区注册表**判定（不适用=跳过并记账，不适用 ≠ 已验证）。
# 注册表已在文件头 source，这里不重复引入。
APPLIED=(); n_applied=0; n_skipped=0; SKIPPED=""
for entry in "${DSH_PATCH_SET[@]}"; do
  if dsh_patch_applicable "$WORK" "$entry"; then
    APPLIED+=("$entry"); n_applied=$((n_applied + 1))
  else
    n_skipped=$((n_skipped + 1)); SKIPPED+="${entry%%:*},"
  fi
done
[ "$n_applied" -gt 0 ] && assert_pass "恢复: 有 $n_applied 条工作区补丁适用于该树" \
  || assert_fail "恢复: 没有任何补丁适用（补丁集重打无从谈起）"
if [ "$n_applied" -gt 0 ]; then
  dsh_verify_patch_markers "$WORK" "${APPLIED[@]}" >>"$EVID" 2>&1 \
    && assert_pass "恢复: 适用补丁的 marker 齐全" \
    || assert_fail "恢复: 有适用补丁的 marker 缺失"
fi
[ "$n_skipped" -gt 0 ] \
  && say "   覆盖率缺口: $n_skipped 条条件补丁不适用（不适用 ≠ 已验证）: ${SKIPPED%,}"
# 用户数据仍在（恢复之后）。
[ "$(receipt_tree_id "$USERDATA")" = "$USERDATA_ID" ] \
  && assert_pass "恢复: 用户数据（\$DSH_HOME 整棵树）逐字未变" \
  || assert_fail "恢复: 用户数据被改动了"
[ "$(cat "$USERDATA/sessions/sentinel.jsonl" 2>/dev/null)" = '{"sentinel":"post-install-patch-failure","n":1}' ] \
  && assert_pass "恢复: 会话哨兵文件仍在且内容正确" \
  || assert_fail "恢复: 会话哨兵文件丢失或被改写"
# 恢复后**再** boot 一次：这是"按该步骤可恢复"的证据，与上面"立即 boot"分开记账。
boot_check "恢复之后" "$NODE" "$WORK/node_modules/@deepseek-ai/dsh/lib/bin.js" "$DSH_NPM_VERSION"
# 行为级探针：marker 只证明"文件变过"，恢复后的树行为也要对。
say "== 行为级探针（恢复后）"
probe_rc=0
probe_patch_set_behaviors "$WORK" "$NODE" || probe_rc=1
[ -n "$PROBE_SKIPPED" ] && say "   跳过的探针（不计为已验证）: $PROBE_SKIPPED"

# --- 7. 耐久证据 --------------------------------------------------------------
FACTS="seed=$SEED_TAG seed_dsh=$SEED_DSH_VERSION installed=$INST_VER target=$DSH_NPM_VERSION"
FACTS+=" ctl_exit=$ctl_rc ctl_version=${CTL_VER:-?} inj_exit=$inj_rc rec_exit=$rec_rc"
FACTS+=" inject_exit_code=$INJECT_EXIT hits=$HITS apply_calls=$PASSTHRU"
FACTS+=" tree_before=$TREE_BEFORE tree_after=$TREE_AFTER injected_version=${INJ_VER:-?}"
FACTS+=" recovered_version=${REC_VER:-?} applied=$n_applied skipped=$n_skipped"
FACTS+=" injected_degraded:markers_missing=$n_inj_missing markers_present=$n_inj_marked na=$n_inj_na"
FACTS+=" probes=$([ "$probe_rc" = 0 ] && echo ok || echo failed) probes_skipped=${PROBE_SKIPPED:-none}"
FACTS+=" userdata_id=$USERDATA_ID scope=DSH_SELF_DONE=1;recovery-proves-reachability-to-boot-probe-only"
say "== 事实: $FACTS"
receipt_case_facts "$DSH_RUN_ID" "$DSH_CASE_ID" "$FACTS" \
  || case_error "必要证据（case-facts）写不进去 —— 本次结论不成立"

case_finish
