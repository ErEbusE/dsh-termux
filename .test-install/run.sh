#!/data/data/com.termux/files/usr/bin/bash
# run.sh — 本地测试体系的唯一入口。
#
# 设计原则:
#   单一事实源 —— 基线数据只在 baseline.env, 其余全部派生;
#   共享逻辑进库不进散文 —— 隔离/断言/哨兵在 sandbox-lib.sh;
#   交付门槛 = 一个命令 —— all 即矩阵, 不需要「记得挑哪个脚本」;
#   测不到的盲区要显式化 —— r5 补上「tarball 内置更新器」这条真实用户路径。
#
# 用法:
#   bash .test-install/run.sh r1|r2|r4|r5      # 单条路线
#   bash .test-install/run.sh r3               # 源码管线(冷装 20min+, 仅在改 00-04 管线时跑)
#   bash .test-install/run.sh all              # 交付门槛 = r1+r2+r4+r5 (--with-r3 追加 r3)
#   bash .test-install/run.sh baseline set latest   # 发版后换基线: latest 自动解析为具体 tag
#   bash .test-install/run.sh serve [端口…]     # 人类实测入口(先过 r1 门槛再起 web)
#   bash .test-install/run.sh baseline check|set <tag|latest>
#   bash .test-install/run.sh clean            # 删除全部沙箱目录(保留基线与测试代码)
#
# 网络: r3/r4/r5 需要 npm registry(+r3 另需 nodejs.org)；受限时先 export https_proxy/http_proxy。
set -uo pipefail

TI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f build/install.sh ] || { echo "请在仓库根目录运行 (build/install.sh 不存在)" >&2; exit 1; }
# 复用公共库的 resolve_release_tag / fetch_release_assets (下载逻辑唯一实现)
# shellcheck disable=SC1091
. "$TI/sandbox-lib.sh"

usage_text() {
  cat <<'EOF'
用法: bash .test-install/run.sh <命令>

测试路线:
  r1                工作区 install.sh × 基线 tarball 全安装接线 (~12s, 每次迭代必跑)
  r2 [--pinned]     下载当前 latest release 认证 shipped 包 (--pinned 离线测 pin 资产)
  r3                工作区 00-setup 流水线 (npm 源; 冷装 20min+, 仅改管线时跑)
  r4                更新链路: 工作区更新器 × 种子沙箱 (需 npm 网络)
  r5                更新链路: tarball 内置更新器 = Option A 用户真实路径 (需 npm 网络)
  all [--with-r3]   交付门槛 = r1+r2+r4+r5

人类实测:
  serve [端口]      过 r1 门槛后在沙箱内起 dsh web (:3141)
                    环境开关: WITH_CREDS=1 复制凭据 / NO_OPEN=1 不弹浏览器 / REUSE=1 复用沙箱

基线管理 (事实源: .test-install/baseline.env):
  baseline check         查看 pin 内容/资产哈希/与 VERSION 是否漂移
  baseline set latest    发版后换基线 (latest 自动解析为当前最新 tag)
  baseline set <tag>     同上, 但钉住指定 tag

其他:
  clean             删除全部 sandbox-* 沙箱 (GB 级), 保留基线与代码; 重跑路线自动重建
  help              显示本帮助

网络受限时先 export https_proxy/http_proxy。测试协议细节见 AGENTS.md §1。
EOF
}
usage() { usage_text >&2; exit "${1:-2}"; }

# --- baseline 管理 ----------------------------------------------------------
# tag 形如 dsh-<dsh版本>-<项目VERSION>。写盘前原子替换；哈希一律现算，绝不手抄。
baseline_write() { # $1=tag $2=tarball_sha $3=installer_sha $4=dsh_version
  local tmp="$TI/baseline.env.tmp"
  {
    echo "# 本文件是基线发布物的唯一事实源。所有测试由此派生期望值。"
    echo "# 更新方式: bash .test-install/run.sh baseline set <release-tag>"
    echo "#           (会下载两个资产、现算 sha256、原子写入; 不要手编本文件)"
    echo "BASELINE_TAG=$1"
    echo "TARBALL_SHA256=$2"
    echo "INSTALLER_SHA256=$3"
    echo "DSH_VERSION=$4"
  } > "$tmp"
  mv -f "$tmp" "$TI/baseline.env"
  echo "==> baseline.env 已写入: tag=$1 dsh=$4"
}

baseline_dsh_ver() { # dsh-<dsh版本>-<项目版本> -> 剥掉首尾得到中间段
  local tag="$1" pv="${tag##*-}"
  echo "${tag#dsh-}" | sed "s/-$pv\$//"
}

baseline_check() { # 只报告不改状态; 资产缺失/漂移时 exit 1 (可脚本化判定)
  local rc=0 cur f want got
  if [ ! -f "$TI/baseline.env" ]; then
    echo "MISSING: baseline.env 不存在 — 生成: run.sh baseline set <tag|latest> (联网)"
    return 1
  fi
  # shellcheck disable=SC1091
  . "$TI/baseline.env"
  echo "BASELINE_TAG=$BASELINE_TAG  DSH_VERSION=$DSH_VERSION"
  cur="$(tr -d "[:space:]" < "$TI/../VERSION" 2>/dev/null || true)"
  if [ "${BASELINE_TAG##*-}" != "$cur" ]; then
    echo "DRIFT: 基线(${BASELINE_TAG##*-}) != VERSION($cur) — 发版后请跑: run.sh baseline set <新tag>"
  else
    echo "CONSISTENT: 基线 == VERSION ($cur)"
  fi
  for f in "dsh-termux-runtime.tar.gz:$TARBALL_SHA256" "install.sh:$INSTALLER_SHA256"; do
    want="${f#*:}"; name="${f%%:*}"
    got="$(sha256sum "$TI/release-test/$name" 2>/dev/null | cut -d" " -f1)" || true
    if [ "$got" = "$want" ]; then echo "ASSET-OK: $name"
    elif [ -z "$got" ]; then echo "ASSET-MISSING: release-test/$name"; rc=1
    else echo "ASSET-CHANGED: $name (现算=${got:0:12}… pin=$want) — 若是有意更换请 baseline set <tag|latest> 重 pin"; rc=1; fi
  done
  return "$rc"
}

baseline_set() { # $1 = 新 release tag 或 'latest': 联网下载两资产 -> 现算哈希 -> 重 pin
  local pv
  local tag
  tag="$(resolve_release_tag "${1:-latest}")" || exit 1
  [ "$tag" != "${1:-}" ] && echo "    latest -> $tag"
  pv="${tag##*-}"
  echo "==> 下载 $tag 的两个发布物到 release-test/ …"
  fetch_release_assets "$TI/release-test" "$tag" || exit 1
  baseline_write "$tag" \
    "$(sha256sum "$TI/release-test/dsh-termux-runtime.tar.gz" | cut -d" " -f1)" \
    "$(sha256sum "$TI/release-test/install.sh" | cut -d" " -f1)" \
    "$(baseline_dsh_ver "$tag")"
  if [ "$pv" != "$(tr -d "[:space:]" < VERSION 2>/dev/null || true)" ]; then
    echo "note: tag 项目版本段($pv) != 仓库 VERSION($(tr -d "[:space:]" < VERSION)); 基线按发布物为准 pin住了"
  fi
  bash "$TI/run.sh" baseline check
}

# --- 路由调度 ----------------------------------------------------------------
# 路由 id -> 文件名 (描述性文件名, 短 id 是对外接口)
route_file() {
  case "$1" in
    r1) echo r1-install.sh ;;
    r2) echo r2-release.sh ;;
    r3) echo r3-setup.sh ;;
    r4) echo r4-update-ws.sh ;;
    r5) echo r5-update-shipped.sh ;;
    *) return 1 ;;
  esac
}

route_run() {
  local r="$1"; shift
  local file; file="$(route_file "$r")" || { echo "!! 未知路由: $r" >&2; return 2; }
  local t0=$SECONDS rc
  echo
  echo "##################### ROUTE $r #####################"
  bash "$TI/routes/$file" "$@"
  rc=$?
  echo "[route $r] exit=$rc 耗时=$((SECONDS-t0))s"
  return "$rc"
}

do_clean() {
  local p sz
  for p in "$TI"/sandbox-*; do
    [ -d "$p" ] || continue
    sz="$(du -sh "$p" 2>/dev/null | cut -f1)"
    rm -rf "$p"
    echo "已删除 $(basename "$p")/ ($sz)"
  done
  # 残留扫描必须能看到点开头文件 ("$TI"/* 不匹配它们): sandbox_init 的 flock
  # sidecar (.sandbox-*.lock) 就落在这里, 未来任何隐藏垃圾也不该对扫描隐身。
  # 锁文件只白名单、不删除——若并发路线正持有该锁, 删文件会让下一个开锁者
  # 锁到新建的同名文件上, r4/r5 的互斥就被静默破坏了 (审计 2026-08-30)。
  for p in "$TI"/* "$TI"/.[!.]*; do
    case "${p##*/}" in
      release-test|routes|sandbox-*|run.sh|serve.sh|sandbox-lib.sh|baseline.env|README.md|.sandbox-*.lock) continue ;;
    esac
    [ -e "$p" ] || continue
    echo "note: 发现非白名单残留: $(basename "$p") (确认无用可手动删)"
  done
  echo "==> 清理完成 (保留 baseline.env / README.md / release-test/ / routes/ / 库与入口)"
}

main() {
  local cmd="${1:-}"; [ $# -gt 0 ] && shift
  case "$cmd" in
    r1|r2|r4|r5) route_run "$cmd" "$@" ;;
    r3)
      echo "提醒: r3 冷装 npm 全量解析约 20min+(依赖图属性, 属正常耗时, 别当挂死);"
      route_run r3 "$@" ;;
    all)
      local routes="r1 r2 r4 r5"
      case " $* " in *" --with-r3 "*) routes="$routes r3" ;; esac
      local r rc
      for r in $routes; do
        route_run "$r" || { echo "!! all 在 $r 处失败, 后续路线未执行" >&2; exit 1; }
      done
      echo
      echo "ALL ROUTES PASSED ($routes)" ;;
    serve) exec bash "$TI/serve.sh" "$@" ;;
    clean) do_clean ;;
    help|-h|--help) usage_text ;;
    baseline)
      case "${1:-}" in
        check) baseline_check ;;
        set) shift; [ -n "${1:-}" ] || usage; baseline_set "$1" ;;
        *) usage ;;
      esac ;;
    *) usage ;;
  esac
}

main "$@"