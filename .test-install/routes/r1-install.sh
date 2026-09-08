#!/data/data/com.termux/files/usr/bin/bash
# r1-install.sh — R1 基础安装: 工作区 build/install.sh × 基线 tarball。
# 每次改动迭代必跑。期望值全部派生自 baseline.env（版本不硬编码）。
set -uo pipefail
# ROUTE 先于 source: 库里写的是 ROUTE="${ROUTE:-}", 本就允许调用者预设,
# 而这个顺序让「谁用了它」对读者和 shellcheck 都成立。
ROUTE="r1"
# shellcheck source=../sandbox-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/sandbox-lib.sh"

load_baseline
check_baseline_consistent
verify_baseline_assets

sandbox_init run

echo "=== 1. 工作区 install.sh × 基线 tarball ==="
bash build/install.sh -y \
  -p "$TARBALL" \
  --prefix "$ROOT/prefix" --bin "$ROOT/bin" >"$ROOT/install.log" 2>&1 \
  || { cat "$ROOT/install.log"; fail "install.sh exited non-zero"; }
ok "install.sh exit 0"

echo "=== 1b. 覆盖重装 (升级者真实路径: 旧 runtime 残留必须清空) ==="
# tar 只覆盖/新增、从不删除 —— 修复前 install.sh 直接解包到已有目录, 旧
# runtime 的 npm 树会整体残留。真机案例 (1.2.2 覆盖 1.1.0): 旧嵌套
# minipass@3 影子顶掉新 npm 的顶层 minipass@7, 新版 minipass-flush 解构
# require('minipass') 得 undefined, npm 启动即 "Class extends value
# undefined"。此处复刻该场景做回归。
STALE_NESTED="$ROOT/prefix/node/lib/node_modules/npm/node_modules/minipass-flush/node_modules/minipass"
mkdir -p "$STALE_NESTED"
printf '{"name":"minipass","version":"3.3.6","main":"index.js"}\n' > "$STALE_NESTED/package.json"
printf 'module.exports = function Minipass () {}\n' > "$STALE_NESTED/index.js"
STALE_ORPHAN="$ROOT/prefix/node/lib/node_modules/npm/lib/commands/hook.js"
mkdir -p "$(dirname "$STALE_ORPHAN")"
echo '// stale orphan from an old npm' > "$STALE_ORPHAN"
echo 'user file, not owned by the tarball' > "$ROOT/prefix/keep-me.txt"
bash build/install.sh -y \
  -p "$TARBALL" \
  --prefix "$ROOT/prefix" --bin "$ROOT/bin" >"$ROOT/reinstall.log" 2>&1 \
  || { cat "$ROOT/reinstall.log"; fail "覆盖重装 install.sh exited non-zero"; }
[ ! -e "$STALE_NESTED/package.json" ] || fail "覆盖重装后嵌套残留 minipass 仍在 (解包未清旧树)"
[ ! -e "$STALE_ORPHAN" ] || fail "覆盖重装后孤儿文件仍在"
[ -f "$ROOT/prefix/keep-me.txt" ] || fail "覆盖重装误删了非 tarball 成员文件"
# 残留清空后, npm 启动必加载的缓存模块链必须能 require (正是真机崩溃链)
"$NODE" -e "require('$ROOT/prefix/node/lib/node_modules/npm/node_modules/cacache/lib/content/write.js')" \
  || fail "npm cacache 模块链加载失败 (minipass 影子残留?)"
ok "覆盖重装: 残留清空 + 非 tarball 文件保留 + npm cacache 链可加载"

echo "=== 2. install.sh 不携带复制逻辑 (委托 common.sh) ==="
for pat in 'configure_glibc_node()' 'write_dsh_wrapper()' 'write_dsh_opener()' 'DSH_OPENER=' 'DSH_WRAPPER_HEAD=' 'ask_yes_no()'; do
  if grep -qF -- "$pat" build/install.sh; then fail "install.sh still contains $pat"; fi
done
if grep -q -- '--set-interpreter' build/install.sh; then
  fail "install.sh 仍提及 --set-interpreter (只允许出现在 common.sh)"
fi
ok "无重复 helper 文本"

echo "=== 3. node 补丁: ELF interpreter -> glibc loader ==="
[ -x "$NODE" ] || fail "node missing"
readelf -l "$NODE" | grep -q 'ld-linux-aarch64.so.1' || fail "node interpreter not glibc loader"
ok "node interpreter 是 glibc loader"
VER="$("$NODE" --version 2>"$ROOT/node-err.log")"
RC=$?
if [ "$RC" -ne 0 ]; then
  echo "--- 补丁后 node stderr (另存 sandbox-run/node-err.log) ---" >&2
  cat "$ROOT/node-err.log" >&2
  fail "补丁后的 node 无法运行 (exit $RC)"
fi
ok "补丁后的 node 可直连运行 ($VER)"

echo "=== 4. wrapper 直连 exec + dsh --version (期望值取自 baseline.env) ==="
WRAP="$ROOT/prefix/work/dsh"
[ -x "$WRAP" ] || fail "wrapper missing"
WVER="$("$WRAP" --version)"
[ "$WVER" = "$BASELINE_DSH_VERSION" ] || fail "dsh --version=[$WVER] != 基线 BASELINE_DSH_VERSION=[$BASELINE_DSH_VERSION]; 若刚换基线请重跑前先确认资产与 pin 同步"
ok "wrapper 直连 exec 出 dsh ($WVER, 与基线一致)"

echo "=== 5. \$BROWSER opener 存在; 无参 -> exit 2 ==="
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
ok "symlink + bashrc PATH 注入齐备"

echo "=== 6b. 工作区补丁集 overlay (serve.sh 起 web 前的同一动作、同一实现) ==="
# 为什么放这儿: 这棵树的 post-image 是**发版时**那套补丁打出来的, 而 serve.sh 会把
# 「工作区那一套」压上去。此前这条判定只存在于 serve.sh —— 也就是只有真机能发现
# 「补丁被改写过后打不回自己造出的树」这类错 (2026-09-08 实测: 逐版本 pristine
# 矩阵与 CI 全绿, 人类一跑 serve.sh 就被拒绝启动)。用同一个
# sandbox-lib.sh:overlay_workspace_patches, 不另写一份标准; 它内部走生产入口
# dsh_apply_patch_set, 含 precondition 跳过与 marker 验证。
overlay_workspace_patches "$ROOT/prefix/work" \
  || fail "工作区补丁集打不进基线种子树 (serve.sh 也会拒绝启动)"
ok "工作区补丁集可 overlay 到本树 (含 marker 验证)"

echo "=== 7. 本地正在运行的 dsh runtime 未被触碰 ==="
live_sentinel

summary