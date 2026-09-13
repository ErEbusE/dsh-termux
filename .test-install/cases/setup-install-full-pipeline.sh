#!/usr/bin/env bash
# setup-install/full-pipeline — 契约: **真实的 00-setup.sh 入口**产出一套可用的 runtime。
#
# 为什么必须走 00 本尊（实查更正 C1）：旧 r3 **不是** 00 的 E2E —— 它逐步调
# 01→02→03→04，还**手工复制**了 00 的 Bundling 段（scripts/ + patches/ + VERSION
# 进 runtime）。于是"方案 B 的真实入口"零覆盖：00 自己的装配逻辑坏掉，旧体系看不见。
# 这条 case 跑的就是 `scripts/00-setup.sh`，装配段也必须由它产出。
#
# 沙箱里怎么收尾：00 的最后一步是 `exec "$WRAPPER" web …`（交互式启动 Web）。自动层
# **不启动 Web**（那是人类实测的事），但也不能因此把 00 截断在半路 —— 所以做法是：
# 后台跑 00，**等它打印"Starting dsh web at"这个标记**（证明 01→04 全跑完、接线已落
# 地），然后把它停掉。标记没出现 = 流水线没走完 = FAIL，绝不用"跑到一半也算过"蒙混。
#
# 不在这里重复主张 SRI 闭环与"补丁前后树身份"——那两条是 `dry-run/pristine-npm` 的
# 契约，同一结果不得计两份覆盖。

set -uo pipefail

. "$DSH_TI_DIR/lib/state.sh"
. "$DSH_TI_DIR/lib/receipt.sh"
. "$DSH_HARNESS_ROOT/scripts/common.sh"

case_begin

EVID="$(dirname "$DSH_RESULTS")/evidence-${DSH_CASE_ID//\//-}.txt"
mkdir -p "$(dirname "$EVID")" || case_error "无法创建证据目录"
: > "$EVID" || case_error "无法写证据文件"
say() { printf '%s\n' "$*" | tee -a "$EVID" >&2; }

SETUP="$DSH_HARNESS_ROOT/scripts/00-setup.sh"
[ -f "$SETUP" ] || case_error "找不到真实入口: $SETUP"
say "== 真实入口 $SETUP -y"
say "   RUNTIME_DIR=$DSH_RUNTIME_DIR"
say "   BIN_DIR=$DSH_BIN_DIR"
say "   WORK_DIR=$DSH_WORK_DIR"
# 沙箱里这三条已经由 run.sh 钉好，00 的默认值直接取自它们（不做额外注入，
# 否则测的就不是"用户默认路径"了）。
case "$DSH_RUNTIME_DIR" in "$DSH_SANDBOX_ROOT"/*) assert_pass "RUNTIME_DIR 在沙箱内" ;;
  *) assert_fail "RUNTIME_DIR 越界: $DSH_RUNTIME_DIR" ;; esac

export DSH_ASSUME_YES=1
TMPD="$DSH_SANDBOX_ROOT/tmp"
mkdir -p "$TMPD" || case_error "无法创建沙箱 tmp"
LOG="$TMPD/00-setup.log"
: > "$LOG" || case_error "无法写日志 $LOG"

say "== 后台执行 00（冷装 npm 可能 20min+，这是预期）"
# `DSH_WEB_PORT=0`：00 的最后一步是 `exec dsh web …`，而本机的**线上 GUI 就占着
# 3080**。绑 0 让内核给一个临时端口，既不会与线上抢端口，也不改变"走到 Web 启动"
# 这个我们要观察的事实（随后立刻停掉它——自动层不跑服务）。
DSH_WEB_PORT=0 bash "$SETUP" -y >>"$LOG" 2>&1 &
PID=$!
MARKER="Starting dsh web at"
DEADLINE=$((SECONDS + ${DSH_FULL_PIPELINE_TIMEOUT:-3600}))
REACHED=0
while [ "$SECONDS" -lt "$DEADLINE" ]; do
  if grep -qF -- "$MARKER" "$LOG" 2>/dev/null; then REACHED=1; break; fi
  kill -0 "$PID" 2>/dev/null || break
  sleep 5
done
if [ "$REACHED" = 0 ]; then
  tail -n 40 "$LOG" >>"$EVID" 2>/dev/null || true
  if kill -0 "$PID" 2>/dev/null; then
    kill -TERM "$PID" 2>/dev/null || true
    assert_fail "00 在 ${DSH_FULL_PIPELINE_TIMEOUT:-3600}s 内没有走到 Web 启动一步（详见证据文件尾部）"
  else
    wait "$PID" 2>/dev/null; rc=$?
    assert_fail "00 提前退出（exit $rc）且没有走到 Web 启动一步（详见证据文件尾部）"
  fi
else
  assert_pass "00 真的走完了 01→04：日志里出现 '$MARKER'"
  # 停掉它自己启动的 web（自动层不跑服务）。exec 过，所以 $PID 就是它。
  kill -TERM "$PID" 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$PID" 2>/dev/null || break
    sleep 0.3
  done
  kill -0 "$PID" 2>/dev/null && kill -KILL "$PID" 2>/dev/null || true
  wait "$PID" 2>/dev/null || true
  kill -0 "$PID" 2>/dev/null \
    && assert_fail "启动的 web 进程没被停掉（沙箱里不该留服务）" \
    || assert_pass "自动层不留下 Web 服务（已停）"
fi

# --- 产物断言（无论上面结局如何都要把它们讲清楚） ---------------------------
NODE="$DSH_RUNTIME_DIR/node/bin/node"
say "== 产物"
[ -x "$NODE" ] && assert_pass "[01] node 就位" || assert_fail "[01] node 缺失: $NODE"
if [ -x "$NODE" ]; then
  NODE_VER="$(run_glibc_node "$NODE" --version 2>/dev/null | tr -d '\r\n')"
  [ -n "$NODE_VER" ] && assert_pass "[01] node 可运行 ($NODE_VER)" || assert_fail "[01] node 无法执行"
fi
PKGJSON="$DSH_WORK_DIR/node_modules/@deepseek-ai/dsh/package.json"
if [ -f "$PKGJSON" ]; then
  assert_pass "[02] dsh 已装入"
  INST_VER="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["version"])' "$PKGJSON" 2>/dev/null)"
  if [ -n "${DSH_NPM_VERSION:-}" ]; then
    [ "$INST_VER" = "$DSH_NPM_VERSION" ] \
      && assert_pass "[02] 装上的版本 == 冻结目标 ($INST_VER)" \
      || assert_fail "[02] 版本不符: 装上 $INST_VER, 冻结 $DSH_NPM_VERSION"
  else
    say "   [02] 本轮没有冻结的 npm 目标，只断言'装上了'"
  fi
else
  assert_fail "[02] dsh 未装入: $PKGJSON 缺失"
fi

# [03] 补丁：期望值全部派生，条件条目不适用要留痕
# shellcheck source=../../scripts/patch-lib.sh
. "$DSH_HARNESS_ROOT/scripts/patch-lib.sh"
n_applied=0; n_skipped=0; SKIPPED=""; APPLIED=()
for entry in "${DSH_PATCH_SET[@]}"; do
  if dsh_patch_applicable "$DSH_WORK_DIR" "$entry"; then
    APPLIED+=("$entry"); n_applied=$((n_applied + 1))
  else
    n_skipped=$((n_skipped + 1)); SKIPPED+="${entry%%:*},"
  fi
done
[ "$n_applied" -gt 0 ] && assert_pass "[03] $n_applied 条补丁适用于本目标" \
  || assert_fail "[03] 没有补丁适用于本目标"
if [ "$n_applied" -gt 0 ]; then
  dsh_verify_patch_markers "$DSH_WORK_DIR" "${APPLIED[@]}" >>"$EVID" 2>&1 \
    && assert_pass "[03] 适用补丁的 marker 齐全" \
    || assert_fail "[03] 有适用补丁的 marker 缺失"
fi
[ "$n_skipped" -gt 0 ] && say "   覆盖率缺口: $n_skipped 条不适用（不适用 ≠ 已验证）: ${SKIPPED%,}"

# [04] 接线
WRAP="$DSH_WORK_DIR/dsh"; OPENER="$DSH_WORK_DIR/dsh-termux-open"
[ -x "$WRAP" ] && assert_pass "[04] wrapper 就位" || assert_fail "[04] wrapper 缺失"
[ -x "$OPENER" ] && assert_pass "[04] opener 就位" || assert_fail "[04] opener 缺失"
[ -L "$DSH_BIN_DIR/dsh" ] && assert_pass "[04] bin 里的 dsh 是 symlink" \
  || assert_fail "[04] symlink 缺失"
grep -q '# dsh-termux' "$HOME/.bashrc" 2>/dev/null && assert_pass "[04] .bashrc 打了 tag" \
  || assert_fail "[04] .bashrc 缺 tag"
if [ -x "$OPENER" ]; then
  "$OPENER" </dev/null >/dev/null 2>&1
  [ $? -eq 2 ] && assert_pass "[04] opener 无参退出 2" || assert_fail "[04] opener 无参退出码 != 2"
fi

# 00 的 Bundling 段：runtime 必须自含机件（旧 r3 手工复制的那一段，现在要由 00 产出）
say "== runtime 自含（00 的 Bundling 段）"
self_ok=1
for f in scripts/update-dsh.sh scripts/common.sh scripts/patch-lib.sh; do
  [ -f "$DSH_RUNTIME_DIR/$f" ] || { assert_fail "runtime 缺 $f（00 的装配段没跑或坏了）"; self_ok=0; }
done
[ -f "$DSH_RUNTIME_DIR/VERSION" ] || { assert_fail "runtime 缺 VERSION"; self_ok=0; }
[ "$self_ok" = 1 ] && assert_pass "runtime 自含 scripts/ 与 VERSION"
if [ -f "$DSH_RUNTIME_DIR/VERSION" ]; then
  VSHIP="$(tr -d '[:space:]' < "$DSH_RUNTIME_DIR/VERSION")"
  VREPO="$(tr -d '[:space:]' < "$DSH_HARNESS_ROOT/VERSION")"
  [ "$VSHIP" = "$VREPO" ] && assert_pass "runtime VERSION == 仓库 VERSION ($VSHIP)" \
    || assert_fail "runtime VERSION($VSHIP) != 仓库 VERSION($VREPO)"
fi
NSHIP="$(grep -c . < <(sed -n 's/^[[:space:]]*"\([^"]*\)".*/\1/p' "$DSH_RUNTIME_DIR/scripts/patch-lib.sh" 2>/dev/null) || true)"
[ "${NSHIP:-0}" -ge 1 ] && assert_pass "runtime patches/ 随 patch-lib 声明（$NSHIP 条）" \
  || assert_fail "runtime 的 patch-lib.sh 没有 DSH_PATCH_SET 条目"

# --- boot --------------------------------------------------------------------
say "== boot"
BIN="$DSH_WORK_DIR/node_modules/@deepseek-ai/dsh/lib/bin.js"
if [ -x "$NODE" ] && [ -f "$BIN" ]; then
  boot_out="$(run_glibc_node "$NODE" "$BIN" --version 2>&1)"; boot_rc=$?
  say "   exit=$boot_rc out=${boot_out//$'\n'/ | }"
  [ "$boot_rc" = 0 ] && assert_pass "00 产出的 runtime 能启动" \
    || assert_fail "dsh 启动失败 (exit $boot_rc): $boot_out"
else
  boot_rc="-"
  assert_fail "无法 boot：node 或 dsh 入口缺失"
fi

# --- 耐久证据 ----------------------------------------------------------------
FACTS="entry=00-setup.sh reached_web=$REACHED installer_rc=${rc:--}"
FACTS+=" node=${NODE_VER:-?} installed=${INST_VER:-?} frozen=${DSH_NPM_VERSION:-none}"
FACTS+=" patches_applied=$n_applied patches_skipped=$n_skipped boot=$boot_rc self_contained=$self_ok"
say "== 事实: $FACTS"
receipt_case_facts "$DSH_RUN_ID" "$DSH_CASE_ID" "$FACTS" \
  || case_error "必要证据（case-facts）写不进去 —— 本次结论不成立"

case_finish
