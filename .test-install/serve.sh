#!/data/data/com.termux/files/usr/bin/bash
# serve.sh — 人类实测入口：在 .test-install/ 沙箱内装好 runtime 后，
# 启动沙箱化的 dsh web，供真机浏览器点检。全程不触碰任何线上环境。
# 由原始「浏览器交接实测」启动脚本（端口 3141，会话记录中恢复）演进而来：
# 沿用其位置参数端口/XDG 隔离/显式 --host，新增自动层门槛/点检清单/凭据选项。
#
# 用法（仓库根目录下）：
#   bash .test-install/serve.sh                 # 先跑自动层门槛, 再起服务, 端口 3141
#   bash .test-install/serve.sh 3099            # 或直接给位置参数换端口 (默认 3141, 避开线上 3080)
#   PORT=3099 bash .test-install/serve.sh       # 也可以用环境变量 PORT (位置参数优先)
#   NO_OPEN=1 bash .test-install/serve.sh       # 不自动开浏览器 (agent 冒烟专用)
#   WITH_CREDS=1 bash .test-install/serve.sh    # 复制线上 ~/.dsh 凭据/设置进沙箱 (可选)
#   REUSE=1 bash .test-install/serve.sh         # 跳过自动层门槛, 复用现有沙箱
#                                               # (仅限网页行为迭代; 安装链路改动禁止跳过)
set -uo pipefail

ROOT="$PWD/.test-install/sandbox-run"

# ---- 0. 前置检查 (仓库根目录 + 基线发布物) ----
[ -f build/install.sh ] || { echo "请在仓库根目录运行 (build/install.sh 不存在)"; exit 1; }
ITS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$ITS_DIR/sandbox-lib.sh"   # 复用唯一 unset 清单 (env_sanitize), 消除清洗清单漂移
ROUTE="serve"
TARBALL=.test-install/release-test/dsh-termux-runtime.tar.gz
if [ "${REUSE:-0}" != "1" ] && [ ! -f "$TARBALL" ]; then
  echo "缺少基线发布物: $TARBALL"
  echo "请先运行: bash .test-install/run.sh baseline set <tag|latest> (联网下载并 pin)"
  exit 1
fi

# ---- 1. 自动层门槛: 沙箱安装测试必须全绿, 否则拒绝启动 ----
# 基线事实源是 baseline.env (sandbox-lib.sh 的 load_baseline/check_baseline_consistent):
# 正常流程时其输出已随 r1 门槛透传; REUSE=1 跳过自动层时也补跑一次,
# 防止基线条目过期却无人知晓 (WARN 不阻塞)。
if [ "${REUSE:-0}" = "1" ] && [ -x "$ROOT/bin/dsh" ]; then
  echo "WARN: REUSE=1 跳过自动层门槛, 复用现有沙箱 (仅限网页行为迭代; 安装链路改动禁止跳过)"
  # REUSE 模式不消费基线, 只做软提醒: load_baseline 内部的 fail 会直接终止 serve
  # (|| true 拦不住 exit), 故这里自行内联检查并降级为 WARN。
  if [ -f "$ITS_DIR/baseline.env" ]; then
    . "$ITS_DIR/baseline.env"
    check_baseline_consistent || true
  else
    echo "WARN: baseline.env 缺失, REUSE 模式跳过基线一致性检查" >&2
  fi
else
  echo "=== 自动层门槛: bash .test-install/run.sh r1 ==="
  bash "$ITS_DIR/run.sh" r1 \
    || { echo "FAIL: 自动层未全绿, 拒绝启动 serve (先修复再重试)"; exit 1; }
  echo "ok: 自动层全绿"
fi

# ---- 1b. 把工作区补丁集应用到沙箱 work 树 ----
# 为什么必须有: r1 门槛用基线 tarball 重建沙箱, 而 tarball pin 的是**发版时**的
# 补丁集, 永远滞后于工作区——新写的补丁若不补进沙箱, 沙箱 Web 跑的还是旧状态,
# 人工实测无从覆盖新补丁 (历史教训: 曾因此误导交付步骤直改线上 runtime, 违反
# §1.4 边界)。这里打的场景与 R4 认证一致: 基线种子 × 工作区补丁链。
# 补丁漂移 (上游 lib 变了) 时 dsh_apply_patch_set 响亮失败, serve 拒绝启动。
if [ -f "$ROOT/prefix/work/node_modules/@deepseek-ai/dsh/lib/bin.js" ]; then
  echo "=== 应用工作区补丁集到沙箱 work 树 (基线 tarball 滞后于工作区) ==="
  # shellcheck disable=SC1091
  . "$ITS_DIR/../scripts/patch-lib.sh" \
    || { echo "FAIL: 无法 source scripts/patch-lib.sh"; exit 1; }
  dsh_apply_patch_set "$ROOT/prefix/work" "$ITS_DIR/../patches" \
    || { echo "FAIL: 工作区补丁集无法应用到沙箱 work 树 (版本漂移?); 拒绝启动 serve"; exit 1; }
  # 行为级探针 (marker 条件触发): 证明补丁后的授权表真的包含 os.tmpdir(),
  # 而不只是文件里有 marker。kernel 级行为由点检清单 3b 的人类实测覆盖。
  # marker 从工作区注册表派生 (上方已 source patch-lib.sh), 不硬编码。
  LMARKER="$(dsh_patch_marker "dsh-sandbox-local/lib/index.js" 2>/dev/null || true)"
  landlock_tmpdir_probe "$ROOT/prefix/work" "$ROOT/prefix/node/bin/node" "$LMARKER"
else
  echo "WARN: 沙箱缺 work 树 ($ROOT/prefix/work), 跳过补丁应用" >&2
fi

# ---- 2. 隔离环境 (导出沙箱 HOME 前先记住线上路径, 供 WITH_CREDS 用) ----
LIVE_HOME="$HOME"
LIVE_DOTDSH="$HOME/.dsh"

mkdir -p "$ROOT/tmp" "$ROOT/xdg/config" "$ROOT/xdg/cache" "$ROOT/xdg/state"
export HOME="$ROOT/home"
export TMPDIR="$ROOT/tmp"
export TMP="$ROOT/tmp"
export XDG_CONFIG_HOME="$ROOT/xdg/config"
export XDG_CACHE_HOME="$ROOT/xdg/cache"
export XDG_STATE_HOME="$ROOT/xdg/state"
export DSH_RUNTIME_DIR="$ROOT/prefix"
export DSH_BIN_DIR="$ROOT/bin"
export DSH_HOME="$ROOT/home/.dsh"
env_sanitize   # 统一清单: LD_PRELOAD/LD_LIBRARY_PATH/NODE_OPTIONS/NODE_REPL_EXTERNAL_MODULE
export PATH="$ROOT/bin:/data/data/com.termux/files/usr/glibc/bin:$PATH"

# $BROWSER 缺省指向沙箱 opener (Android intent 打开默认浏览器); 已继承的保留
if [ -z "${BROWSER:-}" ]; then
  export BROWSER="$ROOT/prefix/work/dsh-termux-open"
fi

# ---- 3. (可选) 复制线上凭据/设置进沙箱, 让聊天实测真正可用 ----
# 默认不复制: 沙箱隔离 = 无线上凭据, 发消息会提示缺 API Key (属预期)。
# WITH_CREDS=1 时从线上 ~/.dsh 只读复制两个文件, 值不打印。
if [ "${WITH_CREDS:-0}" = "1" ]; then
  if [ -f "$LIVE_DOTDSH/.credentials.yaml" ] && [ -f "$LIVE_DOTDSH/settings.yaml" ]; then
    mkdir -p "$DSH_HOME"
    cp "$LIVE_DOTDSH/.credentials.yaml" "$LIVE_DOTDSH/settings.yaml" "$DSH_HOME/"
    echo "WITH_CREDS=1: 已把线上凭据/设置复制进沙箱 $DSH_HOME (仅本次聊天实测用, 值未打印)"
  else
    echo "WARN: WITH_CREDS=1 但 $LIVE_DOTDSH 下缺 .credentials.yaml 或 settings.yaml, 跳过复制"
  fi
fi

# ---- 4. 工作区 + 端口 ----
mkdir -p "$ROOT/ws"
cd "$ROOT/ws"
PORT="${1:-${PORT:-3141}}"   # 位置参数优先, 否则 $PORT, 默认 3141 (避开线上 3080)
OPEN_FLAGS=()
[ "${NO_OPEN:-0}" = "1" ] && OPEN_FLAGS=(--no-open)

# ---- 5. 人类点检清单 ----
echo
echo "======================================================================"
echo " 沙箱 Web 地址:  http://127.0.0.1:$PORT"
echo " 隔离:  HOME=$HOME"
echo "        DSH_HOME=$DSH_HOME   (凭据/会话/数据全部落在沙箱内)"
echo "======================================================================"
echo " 人类点检清单 (测完请在回复里逐项确认或标注「未实测」):"
echo "  1) 浏览器打开 http://127.0.0.1:$PORT"
echo "     (未设 NO_OPEN 时应自动弹出; 首次启动会先初始化 web 模板, 稍等片刻)"
echo "     页面标题应为 DeepSeek Harness"
echo "  2) 新建会话并发送一条消息, 等待 agent 回复"
echo "     - 若提示缺少 API Key: 属预期 (沙箱默认无线上凭据);"
echo "       可用 WITH_CREDS=1 重启, 或在沙箱 UI 手动填 Key"
echo "       未配凭据时此项只能标「未实测」"
echo "  3) 让 agent 写/读文件, 确认落点在沙箱工作区: $(pwd)"
echo "     (仓库与线上目录全程不受影响)"
echo "  3b) 让 agent 在 bash 工具里执行 mktemp -d 和 echo x > \$TMPDIR/t && cat \$TMPDIR/t"
echo "      (workspace-write 下应成功且落在 $ROOT/tmp —— 验证 Landlock tmpdir 补丁;"
echo "       修复前这两条会被 [sandbox: file access denied] 拒绝)"
echo "  4) 浏览器交接: 让 agent 打开一个链接, 应经沙箱 opener 交到 Android 默认浏览器"
echo "  5) 边界检查: 线上 ~/.dsh 与 http://127.0.0.1:3080 全程不受影响"
echo "  6) 测完 Ctrl-C 退出; 再开线上 http://127.0.0.1:3080 确认仍正常"
echo "======================================================================"
echo

exec "$ROOT/bin/dsh" web --host 127.0.0.1 --port "$PORT" "${OPEN_FLAGS[@]}"
