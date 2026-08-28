#!/data/data/com.termux/files/usr/bin/bash
# r3-setup.sh — R3 setup 管线测试: 驱动工作区 scripts/00-setup 流水线（拆步调用）。
# [01] nodejs.org 官方 node + glibc 补丁 -> [02] npm 装 @deepseek-ai/dsh
#      (--ignore-scripts) -> [03] 双硬链接补丁 -> [04] wrapper/opener/symlink/bashrc。
# 这是与 build/install.sh 并行的第二种安装方案 (dsh 来自 npm registry, 不经 tarball)。
# 需要网络: npm registry + nodejs.org。注意 [02] 冷装全量解析约 20min+ 才可能完成
# (依赖图在 arm64 冷解析的正常耗时; 先跑过一次 r4 会热缓存), 别误判为挂死。
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/sandbox-lib.sh"
ROUTE="r3"

load_baseline
check_baseline_consistent

# --- 前置: 真机 glibc 三件套必须在场 (否则 01 会触发 pkg install 的真机变更) ---
echo "=== 0. preflight 真机 glibc 前置 ==="
[ -x /data/data/com.termux/files/usr/glibc/bin/grun ] \
  || fail "真机 glibc-runner 缺失 (先真机: pkg install glibc-runner)"
for p in glibc glibc-repo glibc-runner; do
  dpkg -s "$p" >/dev/null 2>&1 \
    || fail "真机缺 dpkg 包 $p (01 会试图 pkg install, 沙箱里不允许)"
done
ok "glibc 组件齐备 (grun + glibc/glibc-repo/glibc-runner)"

sandbox_init setup --work
export DSH_NODE_VERSION="24.19.0"   # r3 自选的被测 node 版本 (独立参数; 与 01 的默认值相同, 不随基线——基线 node 已补丁, 这里取官方原版)   # 与基线 node 同代的目标版本 (r3 自己取官方发行物)

echo "=== 1. [01] 取官方 node + glibc 补丁 (nodejs.org) ==="
bash "$TI_ROOT/../scripts/01-setup-glibc-node.sh" -y >"$ROOT/01.log" 2>&1 \
  || { cat "$ROOT/01.log"; fail "[01] exited non-zero"; }
[ -x "$NODE" ] || fail "node missing after [01]"
readelf -l "$NODE" | grep -q 'ld-linux-aarch64.so.1' || fail "node not glibc-patched"
NV="$("$NODE" --version 2>"$ROOT/node-err.log")" || { cat "$ROOT/node-err.log" >&2; fail "patched node won't run"; }
ok "[01] node 取得并补丁 ($NV)"

echo "=== 2. [02] npm 装 dsh (--ignore-scripts; 冷装可能 20min+) ==="
bash "$TI_ROOT/../scripts/02-install-dsh.sh" -y >"$ROOT/02.log" 2>&1 \
  || { cat "$ROOT/02.log"; fail "[02] exited non-zero"; }
[ -f "$ROOT/prefix/work/node_modules/@deepseek-ai/dsh/lib/bin.js" ] \
  || fail "dsh not installed after [02]"
ok "[02] dsh 已从 npm 装入"

echo "=== 3. [03] 补丁集 ==="
bash "$TI_ROOT/../scripts/03-apply-patches.sh" -y >"$ROOT/03.log" 2>&1 \
  || { cat "$ROOT/03.log"; fail "[03] exited non-zero"; }
# 期望值不硬编码: source 工作区 patch-lib.sh, 按 DSH_PATCH_SET 全集验 marker
# (与 r4 同款派生逻辑; 新增/删除补丁时本路线自动跟随)。
# shellcheck disable=SC1091
. "$TI_ROOT/../scripts/patch-lib.sh"
NPATCH=0
for entry in "${DSH_PATCH_SET[@]}"; do
  NPATCH=$((NPATCH+1))
  rest="${entry#*:}"; rel="${rest%%:*}"
  marker="$(dsh_patch_marker "$rel")" || fail "DSH_PATCH_SET 条目缺 marker 字段: $entry"
  grep -q "$marker" "$ROOT/prefix/work/node_modules/@deepseek-ai/$rel" \
    || fail "marker '$marker' missing in $rel (补丁未生效?)"
done
ok "[03] 补丁标记齐全 ($NPATCH 个)"

echo "=== 4. [04] wrapper/opener/symlink/bashrc (stdin 答 y,n 启动 web 答 n) ==="
printf 'y\nn\n' | bash "$TI_ROOT/../scripts/04-run-web.sh" >"$ROOT/04.log" 2>&1 \
  || { cat "$ROOT/04.log"; fail "[04] exited non-zero"; }
WRAP="$ROOT/prefix/work/dsh"
[ -x "$WRAP" ] || fail "wrapper missing after [04]"
WV="$(PATH="$ROOT/bin:$PATH" "$WRAP" --version 2>/dev/null | head -1)"
[ -n "$WV" ] || fail "dsh --version empty after [04]"
OPENER="$ROOT/prefix/work/dsh-termux-open"
[ -x "$OPENER" ] || fail "opener missing"
"$OPENER" </dev/null >/dev/null 2>&1
[ $? -eq 2 ] || fail "opener 无参退出码 != 2"
[ -L "$ROOT/bin/dsh" ] || fail "symlink missing"
[ "$(readlink "$ROOT/bin/dsh")" = "$WRAP" ] || fail "symlink target wrong"
grep -q '# dsh-termux' "$ROOT/home/.bashrc" || fail "bashrc tag missing"
grep -q "export PATH=\"$ROOT/bin:\$PATH\"" "$ROOT/home/.bashrc" || fail "PATH line missing"
ok "[04] wrapper/opener/symlink/bashrc 接线完成 ($WV)"

echo "=== 5. 线上运行时未触碰 ==="
live_sentinel

summary