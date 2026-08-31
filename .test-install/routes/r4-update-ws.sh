#!/data/data/com.termux/files/usr/bin/bash
# r4-update-ws.sh — R4 更新链路(工作区更新器): 从基线 tarball 种子一套 runtime
# (node 仍 pristine), 跑工作区 scripts/update-dsh.sh -t <tag> -y, 断言:
#   npm 重装成功 / 补丁集重打并验标记 / wrapper+opener+symlink 重写可用 /
#   wrapper 的 update 钩子按「工作区生成器」能力存在 / 本地正在运行的 dsh runtime 未被触碰。
# 需要 npm registry 网络 (受限先 export https_proxy/http_proxy)。
#   tag 选择: DSH_UPDATE_TAG > DSH_R4_TAG(旧名兼容) > latest
set -uo pipefail
# ROUTE 先于 source: 库里写的是 ROUTE="${ROUTE:-}", 本就允许调用者预设,
# 而这个顺序让「谁用了它」对读者和 shellcheck 都成立。
ROUTE="r4"
# shellcheck source=../sandbox-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/sandbox-lib.sh"

TAG="${DSH_UPDATE_TAG:-${DSH_R4_TAG:-latest}}"

load_baseline
check_baseline_consistent
verify_baseline_assets   # 种子 = 基线 tarball, 先验完整再种

echo "需要 npm registry 网络; 目标 dist-tag: $TAG"

sandbox_init update --work

echo "=== 1. 基线 tarball 种子旧 runtime ==="
tar -xzf "$TARBALL" -C "$ROOT/prefix" || fail "tarball 解包失败"
[ -x "$NODE" ] || fail "种子 node missing"
PKGJSON="$ROOT/prefix/work/node_modules/@deepseek-ai/dsh/package.json"
BEFORE="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$PKGJSON" | head -1)"
[ -n "$BEFORE" ] || fail "无法读取被种子 dsh 版本 (package.json)"
ok "种子 dsh $BEFORE (基线 tarball; node 尚未补丁)"

echo "=== 2. 工作区 update-dsh.sh -t $TAG -y ==="
bash "$TI_ROOT/../scripts/update-dsh.sh" -t "$TAG" -y >"$ROOT/update.log" 2>&1 \
  || { cat "$ROOT/update.log"; fail "update-dsh.sh exited non-zero"; }
ok "update-dsh.sh exit 0"

echo "=== 3. node 补丁仍在 + 可直连 ==="
readelf -l "$NODE" | grep -q 'ld-linux-aarch64.so.1' || fail "node interpreter not glibc loader"
NV="$("$NODE" --version 2>"$ROOT/node-err.log")" \
  || { cat "$ROOT/node-err.log" >&2; fail "patched node won't run"; }
ok "node patched, runs ($NV)"

echo "=== 4. 更新后版本 (经重写的 wrapper) ==="
WRAP="$ROOT/prefix/work/dsh"
[ -x "$WRAP" ] || fail "wrapper missing after update"
WVER="$(PATH="$ROOT/bin:$PATH" "$WRAP" --version 2>/dev/null)"
[ -n "$WVER" ] || fail "wrapper --version 为空 (更新后 wrapper 未生效?)"
AFTER="$(printf '%s\n' "$WVER" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?' | head -1)"
[ -n "$AFTER" ] || fail "无法从 wrapper 输出解析版本: $WVER"
if [ "$BEFORE" != "$AFTER" ]; then
  ok "dsh 版本: $BEFORE -> $AFTER"
else
  note "dsh 版本未变 ($AFTER == 种子): npm 仍执行了重装+重打补丁+wrapper 重写, 更新机制本身验证通过"
fi

echo "=== 5. 补丁标记 (工作区 DSH_PATCH_SET 全集) ==="
# 期望值不硬编码: source 工作区 patch-lib.sh, 逐条目验 marker——新增/删除补丁时
# 本路线自动跟随, 与 CI 的 dsh_verify_patch_markers 同源同逻辑。
# shellcheck source=../../scripts/patch-lib.sh
. "$TI_ROOT/../scripts/patch-lib.sh"
NPATCH=0
for entry in "${DSH_PATCH_SET[@]}"; do
  NPATCH=$((NPATCH+1))
  rest="${entry#*:}"; rel="${rest%%:*}"
  marker="$(dsh_patch_marker "$rel")" || fail "DSH_PATCH_SET 条目缺 marker 字段: $entry"
  t="$ROOT/prefix/work/node_modules/@deepseek-ai/$rel"
  grep -q "$marker" "$t" || fail "marker '$marker' missing in $rel (补丁未生效?)"
done
ok "全部补丁标记齐全 ($NPATCH 个)"

echo "=== 5b. landlock tmpdir 行为探针 (marker 在则必测) ==="
# marker 由工作区注册表派生 (dsh_patch_marker 按目标反查; 上方已 source patch-lib.sh)
LMARKER="$(dsh_patch_marker "dsh-sandbox-local/lib/index.js" 2>/dev/null || true)"
landlock_tmpdir_probe "$ROOT/prefix/work" "$NODE" "$LMARKER"
FLMARKER="$(dsh_patch_marker "dsh-fs-local/lib/index.js" 2>/dev/null || true)"
fslocal_link_rename_probe "$ROOT/prefix/work" "$NODE" "$FLMARKER"

echo "=== 6. opener + symlink 重写可用 ==="
OPENER="$ROOT/prefix/work/dsh-termux-open"
[ -x "$OPENER" ] || fail "opener missing"
"$OPENER" </dev/null >/dev/null 2>&1
[ $? -eq 2 ] || fail "opener 无参退出码 != 2"
[ -L "$ROOT/bin/dsh" ] || fail "symlink missing"
[ "$(readlink "$ROOT/bin/dsh")" = "$WRAP" ] || fail "symlink target wrong"
"$ROOT/bin/dsh" --version >/dev/null 2>&1 || fail "symlinked dsh won't run"
ok "wrapper/opener/symlink 已重写并可用"

echo "=== 7. update 钩子按工作区生成器能力存活 ==="
EXPECT="$(wrapper_hook_expected "$TI_ROOT/../scripts/common.sh")"
assert_wrapper_hook "$WRAP" "$EXPECT"

echo "=== 7b. 钩子目标 = runtime 内置更新器 (Option A 布局优先级) ==="
# 种子 tarball 是 Option A 布局 (含 scripts/update-dsh.sh), 更新器重写 wrapper
# 时 UPDATER 解析必须 runtime 内置优先——wrapper 不得再指回仓库 checkout。
grep -qF "\"$ROOT/prefix/scripts/update-dsh.sh\"" "$WRAP" \
  || fail "wrapper 钩子未指向 runtime 内置更新器 (指回了 checkout?)"
ok "wrapper 钩子指向 runtime 内置: $ROOT/prefix/scripts/update-dsh.sh"

echo "=== 8. 本地正在运行的 dsh runtime 未被触碰 ==="
live_sentinel

summary