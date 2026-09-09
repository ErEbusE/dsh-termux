#!/data/data/com.termux/files/usr/bin/bash
# serve.sh — 人类实测入口：在 .test-install/ 沙箱内装好 runtime 后，
# 启动沙箱化的 dsh web，供真机浏览器点检。全程不触碰本地正在运行的 dsh runtime 及其数据。
# 由原始「浏览器交接实测」启动脚本（端口 3141，会话记录中恢复）演进而来：
# 沿用其位置参数端口/XDG 隔离/显式 --host，新增自动层门槛/点检清单/凭据选项。
#
# 用法唯一事实源是下面的 usage_text（`bash .test-install/serve.sh -h`）——
# 注释里再抄一份只会腐烂，改用法只改那一处。
set -uo pipefail

# ---- 用法 + 参数守卫（先于任何耗时步骤）----
usage_text() {
  cat <<'EOF'
serve.sh — 人类实测入口: 在 .test-install/ 沙箱内装好 runtime 后启动沙箱化的
dsh web, 供真机浏览器点检。全程不触碰本地正在运行的 dsh runtime 及其数据。

用法 (仓库根目录下):
  bash .test-install/serve.sh              门槛全绿才起服务, 端口 3141
  bash .test-install/serve.sh 3099         位置参数换端口 (唯一合法的位置参数)

其余开关一律是**环境变量, 必须写在命令前面**:
  PORT=3099       端口 (位置参数优先)
  TAG=<tag>       起用指定发布物而不是基线, 门槛换成 r2 --tag
                  (pre 渠道产物的人类实测入口: latest 按定义看不见 prerelease)
  DSH_TARGET=<t>  构建并起用「npm 某个渠道」的运行时 (t = dist-tag, 如 alpha/next):
                  走 setup 链路 (官方 node -> npm 装该渠道 -> **工作区**补丁集 -> wrapper),
                  落在独立沙箱 sandbox-target-<t>, 与基线 pin 断言无关。
                  补丁漂移类改动必须走这条: 基线那个 build 里被修的代码从没漂过,
                  拿它测等于什么也没测。别用更新器做这件事, 见 README 的
                  「该让谁当前测对象」。
  SANDBOX=<name>  直接起 sandbox-<name> 的 web (配 DSH_TARGET 用; 单用则要求该
                  沙箱已构建过)。同样免基线门槛, 但会打印被测 dsh 版本
  WITH_CREDS=1    把本地 ~/.dsh 的凭据/设置复制进沙箱 (实测聊天用; 只复制文件——
                  环境变量型凭据须由启动 shell 自带; 每次启动覆盖沙箱内同名文件)
  NO_OPEN=1       不自动开浏览器 (agent 冒烟专用)
  REUSE=1         跳过自动层门槛, 复用现有沙箱
                  (仅限网页行为迭代; 安装链路改动禁止跳过)
  REBUILD=1       配 DSH_TARGET: 即使沙箱已存在也重新构建一遍

例:
  WITH_CREDS=1 TAG=pre-dsh-0.1.2-alpha.3-gdd6322d-1.2.7 bash .test-install/serve.sh
  DSH_TARGET=alpha bash .test-install/serve.sh      # 在漂移目标版本上实测补丁链
EOF
}

case "${1:-}" in
  -h|--help) usage_text; exit 0 ;;
esac

# 位置参数只有一个合法含义 = 端口。开关是环境变量, 写在命令**前面**。
# 写成位置参数时本脚本以前会把它当端口: 白跑一整轮门槛+安装 (TAG 模式下是
# 150s 下载装机), 而且装的还是**基线**而不是你要测的那个发布物, 最后才由 dsh
# 抛 "--port must be a number" —— 2026-09-01 实测踩过 (`bash serve.sh TAG=...`
# 装成 rc.2 并打印了 "http://127.0.0.1:TAG=..." 这种地址)。所以先验后跑。
if [ "$#" -gt 1 ]; then
  echo "!! 位置参数最多一个 (端口); 收到 $# 个: $*" >&2
  usage_text >&2
  exit 2
fi
PORT="${1:-${PORT:-3141}}"   # 位置参数优先, 否则 $PORT, 默认 3141 (避开本地 dsh web 的 3080)
case "$PORT" in
  *=*)
    echo "!! '$PORT' 看起来是环境变量赋值 —— 它必须写在命令**前面**:" >&2
    echo "     $PORT bash .test-install/serve.sh" >&2
    exit 2 ;;
  ''|*[!0-9]*)
    echo "!! 位置参数只能是端口号 (收到: '$PORT')" >&2
    usage_text >&2
    exit 2 ;;
esac
if [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
  echo "!! 端口超出范围 (1-65535): $PORT" >&2
  exit 2
fi

# TAG 给定时改用 r2 的沙箱: 装机与断言都由 r2 --tag 完成, 而它的落点布局
# ($ROOT/prefix + $ROOT/bin) 与 r1 逐字相同, 所以下面每一步照用不误。
# DSH_TARGET / SANDBOX 走第三条: 被测对象是「npm 某渠道 × 工作区补丁链」的运行时,
# 由 r4 落在自己的沙箱里 (布局同上, 所以后续每一步也照用)。
TAG="${TAG:-}"
DSH_TARGET="${DSH_TARGET:-}"
SANDBOX="${SANDBOX:-}"
MODE=""   # "" = 基线模式 (默认), tag = 指定发布物, sandbox = 指定沙箱/渠道
if [ -n "$DSH_TARGET" ] && [ -n "$TAG" ]; then
  echo "!! DSH_TARGET 与 TAG 互斥: 前者现构建某个 npm 渠道的运行时, 后者认证已发布的那个产物" >&2
  exit 2
fi
if [ -n "$SANDBOX" ] && [ -n "$TAG" ]; then
  echo "!! SANDBOX 与 TAG 互斥 (TAG 固定用 sandbox-release)" >&2
  exit 2
fi
if [ -n "$DSH_TARGET" ] && [ -z "$SANDBOX" ]; then
  # 渠道名可以带 . 和 - (如 0.1.3-alpha.2), 其余字符一律换成 -, 免得变成奇怪路径
  SANDBOX="target-$(printf '%s' "$DSH_TARGET" | tr -c 'A-Za-z0-9._-' '-')"
fi
if [ -n "$TAG" ]; then
  ROOT="$PWD/.test-install/sandbox-release"
  MODE=tag
elif [ -n "$SANDBOX" ]; then
  ROOT="$PWD/.test-install/sandbox-$SANDBOX"
  MODE=sandbox
else
  ROOT="$PWD/.test-install/sandbox-run"
fi

# ---- 0. 前置检查 (仓库根目录 + 基线发布物) ----
[ -f build/install.sh ] || { echo "请在仓库根目录运行 (build/install.sh 不存在)"; exit 1; }
ITS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROUTE="serve"   # 先于 source: 库里的 ROUTE="${ROUTE:-}" 保留调用者预设值
# shellcheck source=sandbox-lib.sh
. "$ITS_DIR/sandbox-lib.sh"   # 复用唯一 unset 清单 (env_sanitize), 消除清洗清单漂移
TARBALL=.test-install/release-test/dsh-termux-runtime.tar.gz
# TAG 模式不消费基线资产 (r2 --tag 自己下载到沙箱 dl/), 故跳过这条预检。
# 渠道/沙箱模式也不消费: 它跑的是 setup 链路, dsh 来自 npm、node 来自 nodejs.org,
# 与基线 tarball 无关 (只有默认基线模式拿它当种子)。
if [ -z "$TAG" ] && [ "$MODE" != sandbox ] && [ "${REUSE:-0}" != "1" ] && [ ! -f "$TARBALL" ]; then
  echo "缺少基线发布物: $TARBALL"
  echo "请先运行: bash .test-install/run.sh baseline set <tag|latest> (联网下载并 pin)"
  exit 1
fi

# ---- 1. 自动层门槛: 沙箱安装测试必须全绿, 否则拒绝启动 ----
# 基线事实源是 baseline.env (sandbox-lib.sh 的 load_baseline/check_baseline_consistent):
# 正常流程时其输出已随 r1 门槛透传; REUSE=1 跳过自动层时也补跑一次,
# 防止基线条目过期却无人知晓 (WARN 不阻塞)。
if [ "$MODE" = sandbox ] && [ -n "$DSH_TARGET" ]; then
  # 渠道沙箱由 **r3 的 setup 链路**现构建: 官方 node+glibc 补丁 -> [02] npm 装该渠道
  # -> [03] 工作区补丁集 -> [04] wrapper/opener/symlink。为什么不借 r4 (更新器) 的壳:
  # update-dsh.sh 的补丁集**永远来自最新稳定 release** (它 self_update 时从那个 release
  # 拉 patches/ 覆盖 runtime 再 re-exec 那份旧 updater), 所以 `-t alpha` 的真实含义是
  # 「拿稳定版补丁去打 alpha 的 lib」——补丁一漂移必红, 且红相是 import hunk 的 :1,
  # 会把人往上游引 (2026-09-08 实测坐实)。r3 这条链路的「装的渠道」与「打的补丁集」
  # 各自独立, 才是渠道测试该走的路。代价: [02] 冷解析慢 (缓存热时约 2min)。
  if [ "${REBUILD:-0}" = "1" ] || [ ! -x "$ROOT/bin/dsh" ]; then
    echo "=== 构建 npm 渠道运行时: DSH_SANDBOX=$SANDBOX DSH_VERSION=@deepseek-ai/dsh@$DSH_TARGET bash $ITS_DIR/run.sh r3 ==="
    echo "    (npm 装 $DSH_TARGET + **工作区**补丁集; 冷解析可能 20min+, 缓存热约 2-3min)"
    DSH_SANDBOX="$SANDBOX" DSH_VERSION="@deepseek-ai/dsh@$DSH_TARGET" \
      bash "$ITS_DIR/run.sh" r3 \
      || { echo "FAIL: 渠道运行时构建失败 (r3 红), 拒绝启动 serve"; exit 1; }
  else
    echo "note: sandbox-$SANDBOX 已存在, 跳过构建 (REBUILD=1 强制重建)"
  fi
fi
if [ "$MODE" = sandbox ]; then
  # 这条模式故意**不跑**基线门槛, 理由是它的被测对象就不是基线: 补丁漂移类改动在
  # 基线那个 build 上从没漂过, 拿基线认证它等于什么都没测 (2026-09-08 实测踩实:
  # 补丁 1 重锚后 serve 默认模式失败报的是「版本漂移」, 而漂移只存在于上游新版本)。
  # 替代断言: 树必须是真装出来的 runtime + 打印被测 dsh 版本让人确认对象; 1b 仍会
  # 用工作区补丁集重打一遍并验 marker + 跑两条行为探针。
  [ -x "$ROOT/bin/dsh" ] || {
    echo "!! sandbox-$SANDBOX 里没有可用 runtime; 单用 SANDBOX 需它已构建过," >&2
    echo "   否则请给 DSH_TARGET=<dist-tag> 让本脚本用 r4 现构建" >&2
    exit 1; }
  SERVED="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    "$ROOT/prefix/work/node_modules/@deepseek-ai/dsh/package.json" 2>/dev/null | head -1)"
  echo "=== 实测对象: sandbox-$SANDBOX · dsh ${SERVED:-<未知>} (非基线, 不跑 r1/基线 pin 断言) ==="
  echo "    渠道=${DSH_TARGET:-<复用已有沙箱>} · 补丁集=工作区 (1b 重打并验 marker)"
elif [ "${REUSE:-0}" = "1" ] && [ -x "$ROOT/bin/dsh" ]; then
  echo "WARN: REUSE=1 跳过自动层门槛, 复用现有沙箱 (仅限网页行为迭代; 安装链路改动禁止跳过)"
  # REUSE 模式不消费基线, 只做软提醒: load_baseline 内部的 fail 会直接终止 serve
  # (|| true 拦不住 exit), 故这里自行内联检查并降级为 WARN。
  # TAG 模式与基线无关, 这条检查对它没有意义, 跳过。
  if [ -n "$TAG" ]; then
    echo "note: TAG=$TAG 模式复用 sandbox-release, 与基线无关"
  elif [ -f "$ITS_DIR/baseline.env" ]; then
    . "$ITS_DIR/baseline.env"
    check_baseline_consistent || true
  else
    echo "WARN: baseline.env 缺失, REUSE 模式跳过基线一致性检查" >&2
  fi
elif [ -n "$TAG" ]; then
  # 指定发布物: 门槛换成 r2 --tag, 它下载该 tag 的资产、用 **shipped** install.sh
  # 装进 sandbox-release 并做完整断言。serve 只负责在它之上起 web。
  echo "=== 自动层门槛: bash .test-install/run.sh r2 --tag $TAG ==="
  bash "$ITS_DIR/run.sh" r2 --tag "$TAG" \
    || { echo "FAIL: 发布物认证未通过, 拒绝启动 serve (先修复再重试)"; exit 1; }
  echo "ok: 自动层全绿 (认证目标: $TAG)"
else
  echo "=== 自动层门槛: bash .test-install/run.sh r1 ==="
  bash "$ITS_DIR/run.sh" r1 \
    || { echo "FAIL: 自动层未全绿, 拒绝启动 serve (先修复再重试)"; exit 1; }
  echo "ok: 自动层全绿"
fi

# ---- 1b. 把工作区补丁集应用到沙箱 work 树 ----
# 为什么必须有: r1 门槛用基线 tarball 重建沙箱, 而 tarball pin 的是**发版时**的
# 补丁集, 永远滞后于工作区——新写的补丁若不补进沙箱, 沙箱 Web 跑的还是旧状态,
# 人工实测无从覆盖新补丁 (历史教训: 曾因此误导交付步骤直改本地正在运行的 runtime, 违反
# §1.4 边界)。这里打的场景与 R4 认证一致: 基线种子 × 工作区补丁链。
# 补丁漂移 (上游 lib 变了) 时 dsh_apply_patch_set 响亮失败, serve 拒绝启动。
if [ -f "$ROOT/prefix/work/node_modules/@deepseek-ai/dsh/lib/bin.js" ]; then
  echo "=== 应用工作区补丁集到沙箱 work 树 (基线 tarball 滞后于工作区) ==="
  # shellcheck source=../scripts/patch-lib.sh
  . "$ITS_DIR/../scripts/patch-lib.sh" \
    || { echo "FAIL: 无法 source scripts/patch-lib.sh"; exit 1; }
  # 先按 tarball 自带的那一版回退, 再打工作区补丁集 —— 实现和理由都在
  # sandbox-lib.sh 的 overlay_workspace_patches 里 (r1 的 6b 断言用同一个函数,
  # 这样"serve 起不来的错"必定先在 CI 红一次, 而不是反过来由真机发现)。
  overlay_workspace_patches "$ROOT/prefix/work" \
    || { echo "FAIL: 工作区补丁集无法应用到沙箱 work 树 (版本漂移?); 拒绝启动 serve"; exit 1; }
  # 行为级探针 (marker 条件触发): 证明补丁后的授权表真的包含 os.tmpdir(),
  # 而不只是文件里有 marker。kernel 级行为由点检清单 3b 的人类实测覆盖。
  # marker 从工作区注册表派生 (上方已 source patch-lib.sh), 不硬编码。
  LMARKER="$(dsh_patch_marker "npm-dsh-sandbox-local-landlock-tmpdir.patch" 2>/dev/null || true)"
  landlock_tmpdir_probe "$ROOT/prefix/work" "$ROOT/prefix/node/bin/node" "$LMARKER"
  FLMARKER="$(dsh_patch_marker "npm-dsh-fs-local-link-rename.patch" 2>/dev/null || true)"
  fslocal_link_rename_probe "$ROOT/prefix/work" "$ROOT/prefix/node/bin/node" "$FLMARKER"
  AMARKER="$(dsh_patch_marker "npm-dsh-attachment-local-durable-walk.patch" 2>/dev/null || true)"
  attachment_durability_probe "$ROOT/prefix/work" "$ROOT/prefix/node/bin/node" "$AMARKER"
else
  echo "WARN: 沙箱缺 work 树 ($ROOT/prefix/work), 跳过补丁应用" >&2
fi

# ---- 2. 隔离环境 (导出沙箱 HOME 前先记住本地正在运行的安装的路径, 供 WITH_CREDS 用) ----
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

# ---- 3. (可选) 复制本地正在运行的 dsh runtime 的凭据/设置进沙箱, 让聊天实测真正可用 ----
# 默认不复制: 沙箱隔离 = 无真实凭据, 发消息会提示缺 API Key (属预期)。
# WITH_CREDS=1 时从本地正在运行的 dsh runtime 的 ~/.dsh 只读复制两个文件, 值不打印。
# 两个注意 (0.1.5-alpha.1 实测踩过):
#   - 只复制文件: 模型键若走环境变量 (如 DEEPSEEK_API_KEY), 必须由启动 serve.sh
#     的 shell 自带——本脚本不注入任何环境变量, 缺了它 UI 会显示「无可用供应商」;
#   - 每次启动都覆盖沙箱内的同名文件: 手工改过沙箱 settings.yaml 后再带 WITH_CREDS
#     重启, 手改会被本地版本盖掉——要么先改本地, 要么去掉 WITH_CREDS 复用已复制过的
#     沙箱 (凭据文件上轮已在)。
if [ "${WITH_CREDS:-0}" = "1" ]; then
  if [ -f "$LIVE_DOTDSH/.credentials.yaml" ] && [ -f "$LIVE_DOTDSH/settings.yaml" ]; then
    mkdir -p "$DSH_HOME"
    cp "$LIVE_DOTDSH/.credentials.yaml" "$LIVE_DOTDSH/settings.yaml" "$DSH_HOME/"
    echo "WITH_CREDS=1: 已把本地 ~/.dsh 凭据/设置复制进沙箱 $DSH_HOME (仅本次聊天实测用, 值未打印)"
  else
    echo "WARN: WITH_CREDS=1 但 $LIVE_DOTDSH 下缺 .credentials.yaml 或 settings.yaml, 跳过复制"
  fi
fi

# ---- 4. 工作区 + 端口 ----
mkdir -p "$ROOT/ws"
# 落点守卫 (AGENTS §3): cd 失败还往下走, 后面的 dsh web 就会在**仓库根**里跑起来
cd "$ROOT/ws" || { echo "FAIL: 无法进入沙箱工作区 $ROOT/ws"; exit 1; }
# PORT 已在顶部的参数守卫里定好并校验过 (那里必须先于门槛跑, 否则错的端口要等
# 一整轮安装之后才暴露)。
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
echo "     dsh >= 0.1.2: 打印的 URL 是一次性握手 (?token= -> 303 -> 会话 cookie),"
echo "     兑换成功后地址栏只剩 127.0.0.1:$PORT —— 那是成功的样子, 不是失败"
echo "     若页面是 'dsh web authentication required': 补丁 6 (SameSite=Lax) 没生效,"
echo "     属回归, 请报维护者 (Android intent 导航是跨站, Strict cookie 不随行, 刷新也无效);"
echo "     临时进入办法: 把 dsh 打印的**完整带 token 的 URL** 粘到地址栏"
echo "     页面标题应为 DeepSeek Harness"
echo "  2) 新建会话并发送一条消息, 等待 agent 回复"
echo "     - 若提示缺少 API Key: 属预期 (沙箱默认无真实凭据);"
echo "       可用 WITH_CREDS=1 重启, 或在沙箱 UI 手动填 Key"
echo "       未配凭据时此项只能标「未实测」"
echo "  3) 让 agent 写/读文件, 确认落点在沙箱工作区: $(pwd)"
echo "     (仓库与本地正在运行的 dsh runtime 全程不受影响)"
echo "  3b) 让 agent 在 bash 工具里执行 mktemp -d 和 echo x > \$TMPDIR/t && cat \$TMPDIR/t"
echo "      (workspace-write 下应成功且落在 $ROOT/tmp —— 验证 Landlock tmpdir 补丁;"
echo "       修复前这两条会被 [sandbox: file access denied] 拒绝)"
echo "  4) 浏览器交接: 第 1 条自动弹出的那次就是它 —— opener 由 dsh 进程调用,"
echo "     不受 agent 文件沙箱约束; 浏览器弹出即本项通过"
echo "     (别让 agent 在 bash 工具里跑 opener: workspace-write 下必定 SIGABRT/134,"
echo "      am 要以 O_RDWR 打开 /dev/binder, 而 Landlock 只授权 workspace/tmpdir//dev/null。"
echo "      这是沙箱设计边界, 不是回归 —— 见 PATCHES.md 补丁 5 的 Notes)"
echo "  5) 边界检查: 本地正在运行的 dsh runtime 的 ~/.dsh 与 http://127.0.0.1:3080 全程不受影响"
echo "  6) 测完 Ctrl-C 退出; 再开本地原来的 dsh web http://127.0.0.1:3080 确认仍正常"
echo "======================================================================"
echo

exec "$ROOT/bin/dsh" web --host 127.0.0.1 --port "$PORT" "${OPEN_FLAGS[@]}"
