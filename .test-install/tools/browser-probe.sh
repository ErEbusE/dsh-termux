#!/data/data/com.termux/files/usr/bin/bash
# browser-probe.sh — **一次性探针**：定位"浏览器交接在哪一层断掉"。
#
# 为什么需要它：`dsh web` 起浏览器这条链有 5 段，而它**失败时完全无声**——
# dsh 用 `stdio:'ignore'` + detached 起 xdg-open，`open()` 在 spawn 那一刻就返回成功。
# 于是"浏览器没弹"与"弹了"在终端上长得一模一样。真机现象：
#   * 普通 Termux 前台 shell 里 `termux-open-url <url>` → 正常弹出（对照成立）
#   * 走 serve 的沙箱环境 → 同一支 opener 报退出码 0，但人看不到浏览器
# 所以逐段切开：是**白名单环境**？是 opener？是 dsh 那条 node 链？还是 serve 的
# 父进程结构？第 5 步直接给出候选修复（用父环境 + 沙箱覆盖，≈真实安装的环境）。
#
# 用法（Termux 必须在前台；每步都会等你回答"弹没弹"）:
#   bash .test-install/tools/browser-probe.sh [--sandbox <名>]
#
# 只读仓库与沙箱，不碰本地正在运行的 dsh runtime。每个 URL 带不同的 ?probe=N，
# 地址栏能看出是哪一步弹的。

set -uo pipefail

TI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$(cd "$TI_DIR/.." && pwd)"
export DSH_HARNESS_ROOT="$ROOT" DSH_TI_DIR="$TI_DIR"
export DSH_LIVE_HOME="${DSH_LIVE_HOME:-$HOME}"

# shellcheck source=../lib/sandbox.sh
. "$TI_DIR/lib/sandbox.sh"

SANDBOX="dry-run-pristine-npm"
while [ $# -gt 0 ]; do
  case "$1" in
    --sandbox) SANDBOX="${2:?--sandbox 需要名字}"; shift 2 ;;
    -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

R="$TI_DIR/sandbox-${SANDBOX#sandbox-}"
[ -d "$R" ] || { echo "!! 沙箱不存在: $R" >&2; exit 2; }
OPENER="$R/bin/dsh-termux-open"
NODE="$R/prefix/node/bin/node"
OPEN_MOD="$R/prefix/work/node_modules/open/index.js"
[ -x "$OPENER" ] || { echo "!! 沙箱里没有 opener（先 serve 一次就有）: $OPENER" >&2; exit 2; }
[ -x "$NODE" ] || { echo "!! 沙箱里没有 node: $NODE" >&2; exit 2; }

SANDBOX_ROOT="$R"; SANDBOX_NAME="$(basename "$R")"
sandbox_build_env          # -> SANDBOX_ENV（serve 给 dsh 的就是这一份）

# 第 5 步的环境：**父环境去掉少数危险/线上变量**，再加上沙箱覆盖。
# 这正是"真实安装"跑的环境（真实用户不经过 env -i），所以它同时是候选修复。
ENV_PARENT=()
while IFS= read -r n; do
  case "$n" in
    LD_*|NODE_OPTIONS|NODE_PATH|HOME|TMPDIR|TMP|PATH|SHELL|BROWSER|XDG_*|DSH_*) continue ;;
  esac
  ENV_PARENT+=("$n=${!n}")
done < <(compgen -e | sort)
for e in "${SANDBOX_ENV[@]}"; do
  case "${e%%=*}" in PATH|HOME|TMPDIR|TMP|XDG_*|DSH_*) ENV_PARENT+=("$e") ;; esac
done
ENV_PARENT+=("BROWSER=$OPENER")

ANSWERS=()
ask() {
  local a
  printf '   → 浏览器弹出来了吗？ [y=弹了 / n=没弹 / s=跳过] ' >&2
  read -r a || a=n
  ANSWERS+=("$1=$a")
}

step() { # $1=序号 $2=说明 $3=环境模式(shell|sandbox|parent) $4..=命令
  local no="$1" desc="$2" mode="$3"; shift 3
  echo
  echo "── 第 $no 步: $desc"
  local rc=0
  case "$mode" in
    shell)   "$@" >/dev/null 2>&1 || rc=$? ;;
    sandbox) env -i "${SANDBOX_ENV[@]}" "$@" >/dev/null 2>&1 || rc=$? ;;
    parent)  env -i "${ENV_PARENT[@]}" "$@" >/dev/null 2>&1 || rc=$? ;;
  esac
  echo "   退出码: $rc $([ "$rc" != 0 ] && echo '（非 0 = 这一步自己就报错了，与浏览器无关）')"
  ask "step$no"
}

U="https://example.com/"
# 完整 dsh 链路：node open() → open 包自带的 xdg-open → $BROWSER → opener
CHAIN=("$NODE" --input-type=module --eval '
const {default: open} = await import(process.argv[1]);
await open(process.argv[2]); await new Promise(r => setTimeout(r, 3000));
' "file://$OPEN_MOD")

echo "======================================================================"
echo " 浏览器交接探针 — 沙箱: $(basename "$R")"
echo " 保持 Termux 在**前台**；每步之后回答一次（y/n/s）。"
echo " 每步 URL 不同（?probe=N），地址栏能看出是哪一步弹的。"
echo "======================================================================"

step 1 "对照：普通 shell 直接调 termux-open-url（已知能弹）" shell \
  termux-open-url "${U}?probe=1"
step 2 "**serve 给 dsh 的那份白名单环境**（env -i + 白名单）里调同一个命令" sandbox \
  termux-open-url "${U}?probe=2"
step 3 "白名单环境 + 沙箱生成的 opener（dsh 交给 \$BROWSER 的就是它）" sandbox \
  "$OPENER" "${U}?probe=3"
step 4 "完整 dsh 链路（node → xdg-open → \$BROWSER → opener），白名单环境" sandbox \
  "${CHAIN[@]}" "${U}?probe=4"
step 5 "**候选修复**：父环境（去 LD_*/NODE_*/线上变量）+ 沙箱覆盖，同一条完整链路" parent \
  "${CHAIN[@]}" "${U}?probe=5"

echo
echo "==================== 请把下面这段原样发回 ===================="
for a in "${ANSWERS[@]}"; do echo "  $a"; done
echo "  （y=弹了 / n=没弹 / s=跳过；probe=N 对应步骤号）"
echo "  另请附上地址栏里真正打开的那个 probe 号（如果弹了的话）"
echo "=============================================================="
