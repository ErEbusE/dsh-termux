#!/usr/bin/env bash
# patch-matrix.sh — 把「工作区补丁集能否应用」对每个 dsh build 验一遍, 秒级。
#
# 为什么需要它: 补丁历来只按「当前 latest」(patch-check) 或「当前 alpha」(手动
# dispatch) 验, 于是**基线那个 build 从没被工作区补丁集验过** —— 而 r1 的种子、
# serve.sh 的 overlay、`--pinned` 的期望值全指着它。内容若在两个 build 之间真的
# 不同 (不是行号偏移: git apply 双向都认, 实测过 -66 与 +1847), 只有这里会红。
#
# 第二段 (rebase) 是 2026-09-08 真机撞到的那一类: 沙箱树是「**已随 tarball 打过
# 补丁**」的状态, serve.sh 要把工作区那一套压上去; 补丁只要被改写过, 就直接打不
# 回自己造出的树, 还报成上游「版本漂移」。当时逐版本 pristine 检查与 CI 全绿, 只有
# 拿手机的人发现。这里用同一个 tarball 的 shipped 补丁集把 pristine 树打成"发版时
# 的样子", 再走**与 serve.sh 同一个** sandbox-lib.sh:overlay_workspace_patches。
#
# 全程不装包、不构建、不碰任何正在运行的 runtime: 只 curl registry 与 GitHub 上的
# 小体积发布物 (子包 tarball 几十~几百 KB, 补丁集资产 ~40KB)。临时树落在**仓库内**
# —— Termux 的 /tmp 属禁访目录且会被静默拒绝 (AGENTS §3)。
#
# 用法:
#   bash .github/scripts/patch-matrix.sh              # CI 用
#   PATCH_MATRIX_VERSIONS="0.1.2-rc.1" bash ...       # 调试: 指定要验的 build
#   PATCH_MATRIX_PATCHES=<dir> bash ...               # 反证: 换一套补丁内容
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO" || exit 1
ROUTE="patch-matrix"
# shellcheck source=../../.test-install/sandbox-lib.sh
. "$REPO/.test-install/sandbox-lib.sh"   # fail/ok/note/summary + overlay_workspace_patches
# shellcheck source=../../scripts/patch-lib.sh
. "$REPO/scripts/patch-lib.sh"           # DSH_PATCH_SET + dsh_apply_patch_set (本脚本第 2 段要用)

PATCHES_DIR="${PATCH_MATRIX_PATCHES:-$REPO/patches}"
# 必须绝对: dsh_apply_patch 是 `git -C <work_dir> apply <patch>`, 相对路径按 work
# 目录解析 —— 症状是 "can't open patch" 被报成版本漂移 (反证时骗过我一次)。
case "$PATCHES_DIR" in /*) ;; *) PATCHES_DIR="$REPO/${PATCHES_DIR#./}" ;; esac
[ -d "$PATCHES_DIR" ] || fail "补丁目录不存在: $PATCHES_DIR"

DL_TIMEOUT=40
REPO_SLUG="${GITHUB_REPOSITORY:-ErEbusE/dsh-termux}"

# 临时树落在仓库内, 并确认落点 (不假设 mktemp 成功)
WORK="$(mktemp -d "$REPO/.patch-matrix.XXXXXX" 2>/dev/null)" || WORK="$REPO/.patch-matrix.$$"
mkdir -p "$WORK" && [ -d "$WORK" ] || fail "无法创建临时目录: $WORK"
trap 'rm -rf "$WORK"' EXIT INT TERM

curl_registry() { # <url> -> stdout; 404 返回 22, 其它失败返回 1
  local url="$1" http tmp
  tmp="$WORK/.resp.$BASHPID.json"
  http="$(curl -s --max-time "$DL_TIMEOUT" -o "$tmp" -w '%{http_code}' "$url" || echo 000)"
  case "$http" in
    200) cat "$tmp"; rm -f "$tmp"; return 0 ;;
    404) rm -f "$tmp"; return 22 ;;
    *)   rm -f "$tmp"; return 1 ;;
  esac
}

# unpack_target <version> <pkg> <inner> <pkgdir>  -> 0 取到 / 22 该版本无此包
unpack_target() {
  local v="$1" pkg="$2" inner="$3" pkgdir="$4" esc url
  esc="$(printf '%s' "@deepseek-ai/$pkg" | sed 's#/#%2F#')"
  url="$(curl_registry "https://registry.npmjs.org/$esc/$v" \
    | python3 -c 'import json,sys
try: print(json.load(sys.stdin)["dist"]["tarball"])
except Exception: pass' 2>/dev/null)"
  [ -n "$url" ] || return 22
  mkdir -p "$pkgdir" || fail "无法建 $pkgdir"
  # 先落盘 + gzip 完整性校验, 再解 —— 不写 `curl | tar`: 一次瞬断会把管道尾部
  # 截断, 本脚本自己报的 "tarball 变了布局?" 其实是假红 (实测抖过一次, 重跑即好;
  # 在 CI 上那就是无理由的红)。
  local tgz="$WORK/pkg.$BASHPID.tgz"
  curl -sL --retry 3 --retry-delay 2 --max-time 180 "$url" -o "$tgz" \
    || { rm -f "$tgz"; fail "下载 $pkg@$v 失败"; }
  gzip -t "$tgz" 2>/dev/null \
    || { rm -f "$tgz"; fail "$pkg@$v: tarball 不完整 (gzip 校验失败)"; }
  # npm tarball 的根是 package/: 剥**一**层即得 <inner> (如 lib/index.js)。
  # -C 必须是包根 —— 指到 inner 的父目录会叠成 $pkg/lib/lib/index.js, 下一步
  # 只报 "target not found", 把真相埋掉。解完再确认落点非空。
  tar xzf "$tgz" -C "$pkgdir" --strip-components=1 "package/$inner" \
    || { rm -f "$tgz"; fail "展开 $pkg@$v 的 $inner 失败 (tarball 变了布局?)"; }
  rm -f "$tgz"
  [ -s "$pkgdir/$inner" ] || fail "$pkg@$v: 解出的 $inner 不存在或为空"
}

# --- 1. 要验哪些 build: 基线 pin + npm latest + npm alpha ----------------------
[ -f .test-install/baseline.env ] || fail "缺 baseline.env (矩阵需要基线版本)"
# shellcheck disable=SC1091
. .test-install/baseline.env
[ -n "${BASELINE_DSH_VERSION:-}" ] || fail "baseline.env 缺 BASELINE_DSH_VERSION"

declare -a WANT=("baseline:$BASELINE_DSH_VERSION")
DIST_TAGS="$(curl_registry 'https://registry.npmjs.org/@deepseek-ai%2Fdsh' \
  | python3 -c 'import json,sys
try: print(" ".join(f"{k}={v}" for k,v in json.load(sys.stdin).get("dist-tags",{}).items()))
except Exception: pass' 2>/dev/null)"
[ -n "$DIST_TAGS" ] || fail "取不到 @deepseek-ai/dsh 的 registry 元数据 (网络受限? 先 export https_proxy)"
for t in latest alpha; do
  v="$(sed -n "s/.*$t=\([^ ]*\).*/\1/p" <<< "$DIST_TAGS")"
  [ -n "$v" ] && WANT+=("npm-$t:$v")
done
if [ -n "${PATCH_MATRIX_VERSIONS:-}" ]; then
  WANT=(); for v in $PATCH_MATRIX_VERSIONS; do WANT+=("explicit:$v"); done
fi

declare -a VERSIONS=()
: > "$WORK/origins"
for entry in "${WANT[@]}"; do
  v="${entry#*:}"; seen=0
  for x in "${VERSIONS[@]:-}"; do [ "$x" = "$v" ] && seen=1 && break; done
  [ "$seen" = 1 ] || VERSIONS+=("$v")
  printf '%s\n' "$entry" >> "$WORK/origins"
done
echo "=== 补丁矩阵 (补丁集: ${PATCHES_DIR#"$REPO"/}) · build: ${VERSIONS[*]} · 补丁: ${#DSH_PATCH_SET[@]} 条 ==="

# --- 2. 每个 build 一棵树 (布局镜像 runtime: prefix/work + prefix/patches) ------
rc=0
for v in "${VERSIONS[@]}"; do
  line="$(grep -m1 -F ":$v" "$WORK/origins" 2>/dev/null || true)"
  src="${line%:*}"; [ -n "$line" ] || src=unknown
  rt="$WORK/$v/prefix"; w="$rt/work"
  mkdir -p "$w/node_modules/@deepseek-ai" || fail "无法建 $w"
  echo "--- $v (来源: $src)"
  if [ "$v" = "$BASELINE_DSH_VERSION" ]; then
    # 基线 build 走 serve.sh / r1 的真实次序, 一步都不能省:
    #   pristine -> shipped 补丁集 (release 构建当时做的事; 树上从此带着自己的
    #               patches/, overlay 的回退正是靠它)
    #            -> overlay 工作区补丁集 (r1 的 6b 断言 = serve.sh 1b, 同一个函数)。
    # 次序反了就什么都测不到: 工作区补丁先落, shipped 那套的锚就没了。
    sh_dir="$WORK/shipped"
    mkdir -p "$sh_dir"
    curl -sL --retry 3 --retry-delay 2 --max-time 180 \
      "https://github.com/$REPO_SLUG/releases/download/$BASELINE_TAG/dsh-termux-patches.tar.gz" \
      -o "$WORK/pa.tgz" \
      || fail "下载 $BASELINE_TAG 的 dsh-termux-patches.tar.gz 失败"
    gzip -t "$WORK/pa.tgz" 2>/dev/null || fail "补丁集资产不完整 (gzip 校验失败)"
    tar xzf "$WORK/pa.tgz" -C "$sh_dir" || fail "解 $BASELINE_TAG 的补丁集资产失败"
    [ -d "$sh_dir/patches" ] && [ -f "$sh_dir/scripts/patch-lib.sh" ] \
      || fail "补丁集资产结构不对 (要 patches/ + scripts/patch-lib.sh): $sh_dir"
    mkdir -p "$rt/patches" && cp "$sh_dir"/patches/*.patch "$rt/patches/" \
      || fail "无法把 shipped patches 放进 $rt/patches"
    for entry in "${DSH_PATCH_SET[@]}"; do
      IFS=: read -r _ rel _ _ <<<"$entry"
      pkg="${rel%%/*}"; inner="${rel#*/}"
      unpack_target "$v" "$pkg" "$inner" "$w/node_modules/@deepseek-ai/$pkg"; urc=$?
      [ "$urc" = 0 ] || [ "$urc" = 22 ] || fail "取 $pkg@$v 时出错"
      [ "$urc" = 0 ] || note "  $pkg@$v 不在 registry (该 build 没有这个包)"
    done
    if out="$( ( . "$sh_dir/scripts/patch-lib.sh" && dsh_apply_patch_set "$w" "$rt/patches" ) 2>&1 )"; then
      ok "$v: shipped 补丁集适用于 pristine 树 (release 构建当时做的事)"
    else
      printf '%s\n' "$out"
      echo "FAIL: $v: shipped 补丁集打不进同 release 的 pristine 树 —— 矩阵对照失真, 先查资产" >&2
      rc=1; continue
    fi
    if out="$(overlay_workspace_patches "$w" "$PATCHES_DIR" 2>&1)"; then
      if grep -q '回退 shipped 版' <<< "$out"; then
        ok "$v: shipped post-image → 工作区补丁集 rebase 成功 (与 serve.sh/r1 同一实现)"
      else
        note "$v: rebase 成功, 但没有条目需要回退 (两套补丁此刻逐字相同?)"
      fi
    else
      printf '%s\n' "$out"
      echo "FAIL: $v: 改写过的补丁打不回 shipped 树 —— 真机 serve.sh 会拒绝启动, r1 也会红" >&2
      rc=1
    fi
    continue
  fi
  for entry in "${DSH_PATCH_SET[@]}"; do
    IFS=: read -r _ rel _ _ <<<"$entry"
    pkg="${rel%%/*}"; inner="${rel#*/}"
    unpack_target "$v" "$pkg" "$inner" "$w/node_modules/@deepseek-ai/$pkg"; urc=$?
    # 该 build 没有这个子包 -> 什么都不放: 条件条目会被判「不适用」, 强制条目会响亮失败
    [ "$urc" = 0 ] || [ "$urc" = 22 ] || fail "取 $pkg@$v 时出错"
    [ "$urc" = 0 ] || note "  $pkg@$v 不在 registry (该 build 没有这个包)"
  done
  if out="$(dsh_apply_patch_set "$w" "$PATCHES_DIR" 2>&1)"; then
    ok "$v: 工作区补丁集适用且 marker 齐全 (pristine 树)"
  else
    printf '%s\n' "$out"
    echo "FAIL: $v (来源 $src): 工作区补丁集不适用 —— install / update / serve 都会撞上它" >&2
    rc=1; continue
  fi

done

[ "$rc" = 0 ] || { echo "FAIL: 补丁矩阵未全绿" >&2; exit 1; }
echo "OK: 补丁矩阵全绿 (${#VERSIONS[@]} 个 build × ${#DSH_PATCH_SET[@]} 条补丁, 含 shipped→工作区 rebase)"
