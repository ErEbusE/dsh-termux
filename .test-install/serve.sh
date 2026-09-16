#!/data/data/com.termux/files/usr/bin/bash
# serve.sh — 纯隔离沙箱启动器。
#
# 只启动一个**已经准备好**的沙箱：安装/打补丁/造载荷都是别处的事。本脚本不生成
# 内容、不写冻结记录、不做签认；它只隔离环境、装启动器、守卫线上 runtime，然后
# 把 `dsh web` 拉起来。
#
# 用法唯一事实源: bash .test-install/serve.sh -h
set -uo pipefail

TI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$TI_DIR/.." && pwd)"
export DSH_HARNESS_ROOT="$ROOT" DSH_TI_DIR="$TI_DIR"
# 线上 HOME 必须在任何覆盖之前捕获：lib/sandbox.sh 靠它定位"线上 runtime"。
export DSH_LIVE_HOME="${DSH_LIVE_HOME:-$HOME}"

# shellcheck source=lib/sandbox.sh
. "$TI_DIR/lib/sandbox.sh"
# registry.sh 只用于一件事：把沙箱名**正向**反查成 case id，再取它的固定清单。
# （绝不把 'sandbox-a-b-c' 用 `tr - /` 反推——case id 里的 '-' 与 '/' 都压成了 '-'，
#   逆向不可逆；正向遍历 sandbox_case_name 才是唯一不漂移的算法。）
# shellcheck source=lib/registry.sh
. "$TI_DIR/lib/registry.sh"
# 启动器生成器只有 scripts/common.sh 这一份实现，别处不抄。
# shellcheck source=../scripts/common.sh
. "$ROOT/scripts/common.sh"

usage_text() {
  cat <<'EOF'
serve.sh — 启动一个已准备好的隔离沙箱（人类实测入口）。

用法（仓库根目录下）:
  bash .test-install/serve.sh --sandbox <名字> [--checklist <名字|路径>] \
                              [--port <n>] [--with-creds] [--no-open]

选项:
  --sandbox <名字或目录>  优先 <repo>/.test-install/sandbox-<名>，其次
                          <repo>/.test-install/<名>；都不存在则报错退出。
  --checklist <名字|路径> 显式指定本次的任务检查清单。名字会在
                          .test-install/checklists/ 下找（自动补 .checklist.md）；
                          路径则直接使用。指定的清单会复制进沙箱 home/ 并打印。
                          不给此参数时：自动取 .test-install/checklists/ 下
                          **最新的** *.checklist.md；找不到则明确提示"本次没有任务清单"。
  --port <n>              端口（默认 3141）。
  --with-creds            复制本地 ~/.dsh 的 .credentials.yaml + settings.yaml
                          进沙箱（值不打印）；缺失只警告，不中断。
  --no-open               不自动开浏览器（agent 冒烟用）。
  -h, --help              显示本帮助。

检查清单两类（启动时都会打印）:
  任务清单  .test-install/checklists/*.checklist.md  —— 本次改动覆盖的功能点，
            由 agent 写、维护者审；沙箱内 agent 可从 home/ 读到副本。
  固定清单  cases/checklists/<id>.txt  —— 按 case 的通用回归（页面能开、
            $TMPDIR、浏览器交接、线上 runtime 未受影响）。由 registry 的
            human 列反查（正向遍历比对，不做名字逆向猜测）。

沙箱必须已含:
  prefix/work/node_modules/@deepseek-ai/dsh/lib/bin.js
  prefix/node/bin/node

例:
  bash .test-install/serve.sh --sandbox a1 --with-creds
EOF
}

die() { echo "!! $*" >&2; exit 2; }

# ---- 参数 ------------------------------------------------------------------
SANDBOX_ARG=""
CHECKLIST_ARG=""
PORT=3141
OPT_WITH_CREDS=0
OPT_NO_OPEN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --sandbox)    SANDBOX_ARG="${2:?--sandbox 需要名字或目录}"; shift 2 ;;
    --sandbox=*)  SANDBOX_ARG="${1#--sandbox=}"; shift ;;
    --port)       PORT="${2:?--port 需要端口号}"; shift 2 ;;
    --port=*)     PORT="${1#--port=}"; shift ;;
    --checklist)  CHECKLIST_ARG="${2:?--checklist 需要名字或路径}"; shift 2 ;;
    --checklist=*) CHECKLIST_ARG="${1#--checklist=}"; shift ;;
    --with-creds) OPT_WITH_CREDS=1; shift ;;
    --no-open)    OPT_NO_OPEN=1; shift ;;
    -h|--help)    usage_text; exit 0 ;;
    *)            usage_text >&2; die "未知参数: $1" ;;
  esac
done
[ -n "$SANDBOX_ARG" ] || { usage_text >&2; die "缺少 --sandbox"; }
case "$PORT" in ''|*[!0-9]*) die "端口必须是数字: '$PORT'" ;; esac
if [ "$((10#$PORT))" -lt 1 ] || [ "$((10#$PORT))" -gt 65535 ]; then
  die "端口超出范围 (1-65535): $PORT"
fi

# ---- 定位沙箱 --------------------------------------------------------------
if [ -d "$TI_DIR/sandbox-$SANDBOX_ARG" ]; then
  SB_ROOT="$TI_DIR/sandbox-$SANDBOX_ARG"
elif [ -d "$TI_DIR/$SANDBOX_ARG" ]; then
  SB_ROOT="$TI_DIR/$SANDBOX_ARG"
else
  die "找不到沙箱 '$SANDBOX_ARG'：既无 $TI_DIR/sandbox-$SANDBOX_ARG，也无 $TI_DIR/$SANDBOX_ARG"
fi
SB_ROOT="$(cd "$SB_ROOT" && pwd)"
echo "沙箱: $SB_ROOT"

DSH_BIN="$SB_ROOT/prefix/work/node_modules/@deepseek-ai/dsh/lib/bin.js"
NODE_BIN="$SB_ROOT/prefix/node/bin/node"
[ -f "$DSH_BIN" ]  || die "沙箱缺 dsh 入口: $DSH_BIN"
[ -x "$NODE_BIN" ] || die "沙箱缺可执行 node: $NODE_BIN"

# ---- 沙箱目录与隔离环境 ----------------------------------------------------
# 没有 `ws/`：可写区就是 home/（workspace-write 的授权根 = $HOME）。曾经建过一个
# `ws/` 并把进程 cwd 设进去，但 dsh web 的工作区来自 $HOME、与进程 cwd 无关，
# 而 ws/ 本身**不在**写授权表里——那个目录既不是工作区也写不进去。
mkdir -p "$SB_ROOT/tmp" "$SB_ROOT/home" "$SB_ROOT/bin" || die "无法创建沙箱目录"
SANDBOX_ROOT="$SB_ROOT"
SANDBOX_NAME="$(basename "$SB_ROOT")"
# 人类实测用"父环境 − 危险项 + 沙箱钉子"，而不是 case 的白名单。
sandbox_env_human
sandbox_env_leak_check || die "沙箱环境仍泄漏线上路径 —— 拒绝启动"

# ---- 本次启动的台账（clean 靠它判断"这个沙箱用过没有"）--------------------
# 只记沙箱名 + 时间戳，不记哈希：删除前 clean 会把这两样**显式打印**给人确认，
# 由人判断"这个还有没有用"。append-only，失败不阻断启动。
SERVED_LEDGER="$TI_DIR/state/served.tsv"
mkdir -p "$(dirname "$SERVED_LEDGER")" 2>/dev/null || true
printf '%s\t%s\n' "$SANDBOX_NAME" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  >> "$SERVED_LEDGER" 2>/dev/null || echo "WARN: 无法写启动台账 $SERVED_LEDGER" >&2

# ---- 生成启动器（写在载荷之外）--------------------------------------------
# ⚠ 先摘掉可能存在的 symlink：生成器用 `cat >` 写入，会**跟随** symlink 落进
# 载荷内部（安装器会把 bin/dsh 指向 prefix/work/dsh）。删掉再写，外壳才只在 bin/。
if [ -L "$SB_ROOT/bin/dsh" ]; then
  rm -f "$SB_ROOT/bin/dsh" || die "无法摘除 bin/dsh 的 symlink（不摘会被写进载荷内部）"
fi
write_dsh_wrapper "$SB_ROOT/bin/dsh" "$NODE_BIN" "$DSH_BIN" \
  || die "无法生成启动器: $SB_ROOT/bin/dsh"

# ---- 线上守卫起点 ----------------------------------------------------------
SNAP_BEFORE="$SB_ROOT/tmp/serve-guard-before.tsv"
SNAP_AFTER="$SB_ROOT/tmp/serve-guard-after.tsv"
# 取不到起点就不该起服务：守卫缺席的结论是不可信的。
sandbox_guard_snapshot "$SNAP_BEFORE" || die "取不到本地 dsh runtime 起点快照 —— 拒绝启动"

# ---- 凭据（可选）-----------------------------------------------------------
if [ "$OPT_WITH_CREDS" = 1 ]; then
  mkdir -p "$SB_ROOT/home/.dsh"
  for f in .credentials.yaml settings.yaml; do
    if [ -f "$HOME/.dsh/$f" ]; then
      cp "$HOME/.dsh/$f" "$SB_ROOT/home/.dsh/" || die "复制 $f 失败"
    else
      echo "WARN: --with-creds 但 $HOME/.dsh/$f 不存在，跳过" >&2
    fi
  done
  echo "--with-creds: 已处理 $SB_ROOT/home/.dsh（值未打印）" >&2
fi

# ---- 检查清单：任务清单 + 该 case 的固定清单 ---------------------------------
# 两类清单都**打印**；任务清单另存一份副本进沙箱 home/（那里的 agent 能读到，而
# home/ 正是 workspace-write 的授权区）。清单是**提示**，不是门：任何一步失败都只
# 警告，绝不因此拒绝启动。

CHECKLIST_DIR="$TI_DIR/checklists"

# 任务清单：显式给了就用它（名字自动补 .checklist.md 后缀），否则取目录下最新一个。
# “最新” = 文件名排序最后一条 —— 文件名以 YYYY-MM-DD 开头，字典序即时间序。
TASK_CL=""
if [ -n "$CHECKLIST_ARG" ]; then
  case "$CHECKLIST_ARG" in
    */*) TASK_CL="$CHECKLIST_ARG" ;;                # 路径形态
    *.checklist.md) TASK_CL="$CHECKLIST_DIR/$CHECKLIST_ARG" ;;
    *) TASK_CL="$CHECKLIST_DIR/$CHECKLIST_ARG.checklist.md" ;;
  esac
  [ -f "$TASK_CL" ] || die "--checklist 指向的文件不存在: $TASK_CL"
else
  TASK_CL="$(find "$CHECKLIST_DIR" -maxdepth 1 -name "*.checklist.md" -print 2>/dev/null \
             | LC_ALL=C sort | tail -n 1)"
fi

echo "======================================================================"
echo " 沙箱:     $SB_ROOT"
echo " HOME:     $SB_ROOT/home   （可写工作区；workspace-write 授权根）"
echo " DSH_HOME: $SB_ROOT/home/.dsh"
echo " 地址:     http://127.0.0.1:$PORT"
echo "======================================================================"

if [ -n "$TASK_CL" ] && [ -f "$TASK_CL" ]; then
  echo
  echo "---- 任务清单 [$(basename "$TASK_CL")] ----"
  cat "$TASK_CL"
  # 副本留在沙箱里，供沙箱内的 agent 读取
  if cp "$TASK_CL" "$SB_ROOT/home/CHECKLIST.md" 2>/dev/null; then
    echo "（副本已放入沙箱: HOME/CHECKLIST.md）"
  else
    echo "WARN: 无法把任务清单副本写进沙箱 home/" >&2
  fi
else
  echo
  echo "⚠ 本次没有任务清单"
  if [ -n "$CHECKLIST_ARG" ]; then
    echo "   （--checklist 给了 '$CHECKLIST_ARG'，但没有找到对应文件）"
  else
    echo "   （$CHECKLIST_DIR 下没有 *.checklist.md）"
  fi
fi

# 固定清单：把沙箱名**正向**反查成 case id，再取它的 human 列。
# 反查失败（手搓沙箱 / 未登记）不是错误——安静跳过，但「没有任务清单」与「固定清单
# 也没有」必须分开报，否则人分不清"没写清单"与"清单丢了"。
FIXED_CL=""
if registry_load "$TI_DIR" 2>/dev/null; then
  SB_CASE_NAME="${SANDBOX_NAME#sandbox-}"
  for _i in "${!REG_ID[@]}"; do
    _n="$(sandbox_case_name "${REG_ID[$_i]}" 2>/dev/null)" || continue
    if [ "$_n" = "$SB_CASE_NAME" ]; then
      _h="${REG_HUMAN[$_i]}"
      [ "$_h" != "-" ] && FIXED_CL="$(registry_checklist_path "$_h")"
      echo "（固定清单归属: case ${REG_ID[$_i]}  human=$_h）"
      break
    fi
  done
fi
if [ -n "$FIXED_CL" ] && [ -f "$FIXED_CL" ]; then
  echo
  echo "---- 固定清单 [$(basename "$FIXED_CL")] ----"
  cat "$FIXED_CL"
elif [ -z "$TASK_CL" ] || [ ! -f "$TASK_CL" ]; then
  echo
  echo "⚠ 既没有任务清单，也没有该 case 的固定清单 —— 本次无检查指引"
fi
echo

# ---- 起服务 ----------------------------------------------------------------
OPEN_FLAGS=()
[ "$OPT_NO_OPEN" = 1 ] && OPEN_FLAGS=(--no-open)

child=0
# cwd 设成 home/（工作区，也是唯一可写根）：dsh web 的工作区本身来自 $HOME，这里
# 对齐 cwd 是为了让那批**读 process.cwd() 作兜底**的包也落在同一个可写区内。
( cd "$SB_ROOT/home" && exec env -i "${SANDBOX_ENV[@]}" "$SB_ROOT/bin/dsh" \
    web --host 127.0.0.1 --port "$PORT" ${OPEN_FLAGS[@]+"${OPEN_FLAGS[@]}"} ) &
child=$!
# 只转发终止信号；INT 交给子进程自己处理（Ctrl-C 会到达整个前台进程组），
# 本脚本不能退出——退出就跑不到下面的线上守卫校验。
trap ':' INT
trap 'kill -TERM "$child" 2>/dev/null || true' TERM
wait "$child"; rc=$?
trap - INT TERM
echo "dsh 退出码: $rc"

# ---- 线上守卫终点 ----------------------------------------------------------
if ! sandbox_guard_verify "$SNAP_BEFORE" "$SNAP_AFTER"; then
  echo "!! 本地正在运行的 dsh runtime 在本次运行期间被触碰 —— 这是红线，退出非零。" >&2
  exit 1
fi
exit "$rc"
