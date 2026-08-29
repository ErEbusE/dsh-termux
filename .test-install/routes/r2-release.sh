#!/data/data/com.termux/files/usr/bin/bash
# r2-release.sh — R2 发布物认证: 下载**当前 latest release** 并完整安装断言。
# release 工作流打包出的产物从未经过真实 Termux 环境检验, 这条路线就是补这一环,
# 所以默认永远瞄准"用户将要拿到的东西"(latest), 而不是 pin 住的旧资产。
#   r2            默认: 解析 latest -> 全新下载到沙箱 dl/ -> 安装+断言 (需网络)
#   r2 --pinned   离线回退: 测试 baseline.env pin 住的资产 (期望版本=pin 的 DSH_VERSION)
# 下载物落在沙箱 dl/ 内, 与 release-test/ 的 pin 资产严格隔离——r1/r4 的资产校验不受影响。
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/sandbox-lib.sh"
ROUTE="r2"

case "${1:-latest}" in
  latest|--latest) MODE=latest ;;
  pinned|--pinned) MODE=pinned ;;
  *) fail "未知参数: $1 (支持 --pinned; 缺省为认证 latest)" ;;
esac

if [ "$MODE" = pinned ]; then
  load_baseline
  check_baseline_consistent
  verify_baseline_assets
  TAGNOTE="pin 的 $BASELINE_TAG"
else
  TAG="$(resolve_release_tag latest)" || fail "解析 latest 失败"
  TAGNOTE="$TAG"
fi

sandbox_init release

if [ "$MODE" = latest ]; then
  echo "=== 0. 下载认证目标: $TAG ==="
  DL="$ROOT/dl"
  fetch_release_assets "$DL" "$TAG" || fail "下载失败"
  TARBALL="$DL/dsh-termux-runtime.tar.gz"
  INSTALLER="$DL/install.sh"
fi

echo "=== 1. tarball 完整性 (关键文件齐全; 不用 tar|grep 防 SIGPIPE) ==="
TAR_LIST="$(tar tzf "$TARBALL" 2>/dev/null)" || fail "无法读取 tarball 文件列表"
for want in \
  node/bin/node \
  work/node_modules/@deepseek-ai/dsh/lib/bin.js \
  scripts/common.sh \
  scripts/patch-lib.sh \
  scripts/update-dsh.sh \
  install.sh; do
  grep -qx "$want" <<<"$TAR_LIST" || fail "tarball 缺少 $want"
done
# 1.2.1 起 tarball 打包顶层 VERSION (更新器的补丁集新鲜度比对依据); 旧
# release 没有——按存在性条件断言并记录, 不对旧产物误红。
if grep -qx "VERSION" <<<"$TAR_LIST"; then
  ok "tarball 携带 VERSION ($(tar xzOf "$TARBALL" VERSION | tr -d '[:space:]'))"
else
  note "tarball 无顶层 VERSION (pre-1.2.1 release), 跳过其断言"
fi
# 补丁清单不硬编码: 按 tarball 内置 patch-lib.sh 的 DSH_PATCH_SET 派生
# (sandbox-lib 的 shipped_patch_entries)——旧 2 补丁 / 新 3 补丁 release 都正确
# 认证, 且「声明了却没打包」的缺件在这里红。补丁目标 lib 一并核对。
mkdir -p "$ROOT/tmp"
tar -xzf "$TARBALL" -C "$ROOT/tmp" scripts/patch-lib.sh || fail "无法解出 scripts/patch-lib.sh"
NPATCH=0
while IFS= read -r entry; do
  [ -n "$entry" ] || continue
  NPATCH=$((NPATCH+1))
  patch="${entry%%:*}"; rest="${entry#*:}"; rel="${rest%%:*}"
  grep -qx "patches/$patch" <<<"$TAR_LIST" || fail "tarball 缺少 patches/$patch (shipped DSH_PATCH_SET 声明了它)"
  grep -qx "work/node_modules/@deepseek-ai/$rel" <<<"$TAR_LIST" || fail "tarball 缺少补丁目标 $rel"
done < <(shipped_patch_entries "$ROOT/tmp/scripts/patch-lib.sh")
[ "$NPATCH" -ge 1 ] || fail "shipped patch-lib.sh 未声明 DSH_PATCH_SET 条目 (打包回归)"
ok "tarball 关键文件齐全 + $NPATCH 个 shipped 补丁自洽 (按内置 DSH_PATCH_SET 派生)"

echo "=== 2. SHIPPED install.sh 安装 (发布资产, 不是工作区那份) ==="
bash "$INSTALLER" -y \
  -p "$TARBALL" \
  --prefix "$ROOT/prefix" --bin "$ROOT/bin" >"$ROOT/install.log" 2>&1 \
  || { cat "$ROOT/install.log"; fail "shipped install.sh exited non-zero"; }
ok "shipped install.sh exit 0"

echo "=== 2b. shipped 补丁标记 (release 构建时已打; 按 shipped 能力派生) ==="
# tarball 里的 lib 应由 release 构建流水线预打补丁; 若某个声明了的补丁在产物里
# 缺 marker (构建漏打), 这里红。marker 派生同上, 三段式/两段式都认。
while IFS= read -r entry; do
  [ -n "$entry" ] || continue
  rest="${entry#*:}"; rel="${rest%%:*}"
  marker="$(patch_entry_marker "$entry")"
  t="$ROOT/prefix/work/node_modules/@deepseek-ai/$rel"
  grep -q "$marker" "$t" || fail "shipped lib 缺 marker '$marker': $rel (release 构建未打补丁?)"
done < <(shipped_patch_entries "$ROOT/tmp/scripts/patch-lib.sh")
ok "shipped 补丁标记齐全"

echo "=== 2c. landlock tmpdir 行为探针 (按 marker 条件触发) ==="
LMARKER="$(shipped_patch_entries "$ROOT/tmp/scripts/patch-lib.sh" \
  | marker_for_target "dsh-sandbox-local/lib/index.js")"
landlock_tmpdir_probe "$ROOT/prefix/work" "$NODE" "$LMARKER"
FLMARKER="$(shipped_patch_entries "$ROOT/tmp/scripts/patch-lib.sh" \
  | marker_for_target "dsh-fs-local/lib/index.js")"
fslocal_link_rename_probe "$ROOT/prefix/work" "$NODE" "$FLMARKER"

echo "=== 3. node 补丁 + 直连运行 ==="
[ -x "$NODE" ] || fail "node missing"
readelf -l "$NODE" | grep -q 'ld-linux-aarch64.so.1' || fail "node interpreter not glibc loader"
VER="$("$NODE" --version 2>"$ROOT/node-err.log")"
RC=$?
if [ "$RC" -ne 0 ]; then cat "$ROOT/node-err.log" >&2; fail "补丁后的 node 无法运行 (exit $RC)"; fi
ok "node 补丁且可运行 ($VER)"

echo "=== 4. wrapper 直连 exec, 版本与安装树 package.json 自洽 ==="
WRAP="$ROOT/prefix/work/dsh"
[ -x "$WRAP" ] || fail "wrapper missing"
PKGJSON="$ROOT/prefix/work/node_modules/@deepseek-ai/dsh/package.json"
if [ "$MODE" = pinned ]; then
  EXPECT_VER="$DSH_VERSION"
else
  # 浮动模式没有 pin 可对: 期望值从下载树自读, 断言的是「wrapper 与其内容自洽」
  EXPECT_VER="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$PKGJSON" | head -1)"
fi
[ -n "$EXPECT_VER" ] || fail "无法确定期望版本"
WVER="$("$WRAP" --version)"
[ "$WVER" = "$EXPECT_VER" ] || fail "dsh --version=[$WVER] != 期望 [$EXPECT_VER]"
ok "shipped wrapper execs dsh ($WVER)"

echo "=== 5. opener 存在; 无参 -> exit 2 ==="
OPENER="$ROOT/prefix/work/dsh-termux-open"
[ -x "$OPENER" ] || fail "opener missing"
"$OPENER" </dev/null >/dev/null 2>&1
[ $? -eq 2 ] || fail "opener 无参退出码 != 2"
ok "opener 无参退出 2"

echo "=== 6. symlink + bashrc PATH 注入 ==="
[ -L "$ROOT/bin/dsh" ] || fail "dsh symlink missing"
[ "$(readlink "$ROOT/bin/dsh")" = "$WRAP" ] || fail "symlink target wrong"
"$ROOT/bin/dsh" --version >/dev/null 2>&1 || fail "symlinked dsh won't run"
grep -q '# dsh-termux' "$ROOT/home/.bashrc" || fail "bashrc tag missing"
grep -q "export PATH=\"$ROOT/bin:\$PATH\"" "$ROOT/home/.bashrc" || fail "PATH line missing"
ok "symlink + bashrc 注入齐备"

echo "=== 7. 线上运行时未触碰 ==="
live_sentinel

note "本次认证的 release: $TAGNOTE (dsh $WVER)"
summary