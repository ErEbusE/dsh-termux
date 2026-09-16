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
# 启动器生成器只有 scripts/common.sh 这一份实现，别处不抄。
# shellcheck source=../scripts/common.sh
. "$ROOT/scripts/common.sh"

usage_text() {
  cat <<'EOF'
serve.sh — 启动一个已准备好的隔离沙箱（人类实测入口）。

用法（仓库根目录下）:
  bash .test-install/serve.sh --sandbox <名字> [--port <n>] [--with-creds] [--no-open]

选项:
  --sandbox <名字或目录>  优先 <repo>/.test-install/sandbox-<名>，其次
                          <repo>/.test-install/<名>；都不存在则报错退出。
  --port <n>              端口（默认 3141）。
  --with-creds            复制本地 ~/.dsh 的 .credentials.yaml + settings.yaml
                          进沙箱（值不打印）；缺失只警告，不中断。
  --no-open               不自动开浏览器（agent 冒烟用）。
  -h, --help              显示本帮助。

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
PORT=3141
OPT_WITH_CREDS=0
OPT_NO_OPEN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --sandbox)    SANDBOX_ARG="${2:?--sandbox 需要名字或目录}"; shift 2 ;;
    --sandbox=*)  SANDBOX_ARG="${1#--sandbox=}"; shift ;;
    --port)       PORT="${2:?--port 需要端口号}"; shift 2 ;;
    --port=*)     PORT="${1#--port=}"; shift ;;
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
mkdir -p "$SB_ROOT/tmp" "$SB_ROOT/ws" "$SB_ROOT/home" "$SB_ROOT/bin" || die "无法创建沙箱目录"
SANDBOX_ROOT="$SB_ROOT"
SANDBOX_NAME="$(basename "$SB_ROOT")"
# 人类实测用"父环境 − 危险项 + 沙箱钉子"，而不是 case 的白名单。
sandbox_env_human
sandbox_env_leak_check || die "沙箱环境仍泄漏线上路径 —— 拒绝启动"

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

# ---- 起服务 ----------------------------------------------------------------
OPEN_FLAGS=()
[ "$OPT_NO_OPEN" = 1 ] && OPEN_FLAGS=(--no-open)

echo "======================================================================"
echo " 沙箱:     $SB_ROOT"
echo " HOME:     $SB_ROOT/home"
echo " DSH_HOME: $SB_ROOT/home/.dsh"
echo " 工作区:   $SB_ROOT/ws"
echo " 地址:     http://127.0.0.1:$PORT"
echo "======================================================================"

child=0
( cd "$SB_ROOT/ws" && exec env -i "${SANDBOX_ENV[@]}" "$SB_ROOT/bin/dsh" \
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
