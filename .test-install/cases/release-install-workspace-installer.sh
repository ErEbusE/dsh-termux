#!/usr/bin/env bash
# release-install/workspace-installer — 契约: **工作区**安装器（build/install.sh）
# 把一棵种子 runtime 正确接线；**覆盖重装**时旧树残留必须清空。
#
# 覆盖/映射（DECISIONS.md 附录 A.2；旧文件 .test-install/routes/r1-install.sh **已删除**）:
#   r1 §1  install.sh 退出 0            -> §3 本节（R1.1）
#   r1 §1b 覆盖重装回归                 -> §4 本节（R1.2；真机 1.2.2 覆盖 1.1.0 事故）
#   r1 §3  node interpreter + 可运行    -> §5 本节（R1.4／R1.5）
#   r1 §4  wrapper 直连 exec + 版本     -> §6 本节（R1.6）
#   r1 §5  opener 无参 exit 2           -> §7 本节（R1.7）
#   r1 §6  symlink + .bashrc 注入       -> §8 本节（R1.8）
#   r1 §6b 工作区补丁集 overlay         -> **不移植**：归 dry-run/pinned-rebase
#                                          （附录 A.2 的 R1.9；同一次真机事故的另一半，
#                                          同一结果不得计两份覆盖）
#   r1 §2  install.sh 不携带复制逻辑    -> **不移植**：归 CI verify.yml 的
#                                          "Verify install.sh delegates to common.sh"
#                                          （附录 A.2 的 R1.3，那边的断言更严：正向
#                                          source/调用 + 反向定义串 + --set-rpath 陷阱）。
#                                          同一个事实在 case 里再抄一份必然漂移。
#   r1 §7  live_sentinel                -> 框架（lib/sandbox.sh 的 case 前后全路径守卫，R1.10）
#
# 期望值全部派生: 版本来自种子（并用安装树的 package.json 交叉核对），interpreter
# 期望来自 scripts/common.sh 自己选 loader 的那段逻辑（glibc_prefix），路径来自
# 运行器钉进的沙箱变量。这里不写死任何版本号或路径。

set -uo pipefail

. "$DSH_TI_DIR/lib/state.sh"
. "$DSH_TI_DIR/lib/receipt.sh"
. "$DSH_TI_DIR/lib/seed.sh"
# common.sh 提供 glibc_prefix / run_glibc_node: glibc 前缀的知识只有一份事实源，
# 不许在 case 里再抄一遍（抄了迟早与 configure_glibc_node 漂移）。
# shellcheck source=../../scripts/common.sh
. "$DSH_HARNESS_ROOT/scripts/common.sh"

case_begin

EVID="$(dirname "$DSH_RESULTS")/evidence-${DSH_CASE_ID//\//-}.txt"
mkdir -p "$(dirname "$EVID")" || case_error "无法创建证据目录 $(dirname "$EVID")"
: > "$EVID" || case_error "无法写证据文件 $EVID"
say() { printf '%s\n' "$*" | tee -a "$EVID" >&2; }

[ -n "${DSH_SANDBOX_ROOT:-}" ] || case_error "DSH_SANDBOX_ROOT 未设置（本 case 只能由 run.sh 提供环境）"
case "${DSH_SANDBOX_ROOT:-}" in "$DSH_TI_DIR"/sandbox-*) ;; *)
  case_error "沙箱落点异常: ${DSH_SANDBOX_ROOT:-<空>}" ;; esac
TMPD="$DSH_SANDBOX_ROOT/tmp"

INSTALLER="$DSH_HARNESS_ROOT/build/install.sh"
NODE="$DSH_RUNTIME_DIR/node/bin/node"
WRAPPER="$DSH_WORK_DIR/dsh"
OPENER="$DSH_WORK_DIR/dsh-termux-open"
LINK="$DSH_BIN_DIR/dsh"

# --- 1. 环境与工具前提 -------------------------------------------------------
# 缺件 -> UNMET（缺结论），绝不能把"这台机器没装齐"报成"被测对象是坏的"。
say "== 环境"
say "   sandbox ${DSH_SANDBOX_ROOT}"
say "   runtime ${DSH_RUNTIME_DIR:-<空>}"
say "   bin     ${DSH_BIN_DIR:-<空>}"
case "${DSH_RUNTIME_DIR:-}" in "$DSH_SANDBOX_ROOT"/*) assert_pass "runtime 落点在沙箱内" ;;
  *) assert_fail "runtime 越界: ${DSH_RUNTIME_DIR:-<空>}" ;; esac
case "${DSH_BIN_DIR:-}" in "$DSH_SANDBOX_ROOT"/*) assert_pass "bin 落点在沙箱内" ;;
  *) assert_fail "bin 越界: ${DSH_BIN_DIR:-<空>}" ;; esac
case "${HOME:-}" in "$DSH_SANDBOX_ROOT"/*) assert_pass "HOME 在沙箱内" ;;
  *) assert_fail "HOME 越界: ${HOME:-<空>}" ;; esac
[ -f "$INSTALLER" ] || case_error "工作区安装器不存在: $INSTALLER"

# install.sh 会调 configure_glibc_node（要 patchelf + glibc loader），也要求 grun
# 在场。registry 的 requires 目前只声明 seed:stable,device:arm64（见报告：这里该补
# host:glibc）；在补上之前，本 case 自己把缺件判成 UNMET，而不是让 install.sh 以
# 非 0 退出被记成 FAIL。host:glibc 的判定只有 lib/state.sh 一处实现，直接复用。
glibc_reason=""
if ! glibc_reason="$(state_check_require host:glibc 2>&1)"; then
  case_unmet "工作区安装器需要 glibc 工具链，本机不满足: $glibc_reason"
fi
command -v readelf >/dev/null 2>&1 \
  || case_unmet "缺少 readelf，无法核对 node 的 ELF interpreter（registry 的 requires 未声明 tool:readelf）"

# --- 2. 种子（-p 的 tarball 是这条 case 唯一的输入实例） ----------------------
SEED_WANT="$(seed_default_name)"
if [ ! -f "$(seed_env_path "$SEED_WANT")" ]; then
  case_unmet "种子事实源不存在（生成: bash .test-install/run.sh seed set <tag> $SEED_WANT）"
fi
seed_rc=0
seed_load "$SEED_WANT" || seed_rc=$?
case "$seed_rc" in
  0) ;;
  1) # 验证完成了、结论否定 -> FAIL（不是"没结论"）
     assert_fail "种子不可用（缺件或哈希与事实源不符）—— 见上文原因"
     case_finish ;;
  *) case_error "种子事实源自身坏了（seed_load rc=$seed_rc）—— 配置/生成故障，不是被测对象的结论" ;;
esac
TARBALL="$(seed_asset_by_name dsh-termux-runtime.tar.gz)" || {
  assert_fail "种子里没有 dsh-termux-runtime.tar.gz（本 case 只用 -p 的 tarball）"
  case_finish
}
say "== 种子: tag=$SEED_TAG dsh=$SEED_DSH_VERSION"
say "   tarball $TARBALL"

# --- 3. 首次安装（干净前缀） -------------------------------------------------
say "== 首次安装: bash build/install.sh -y -p <种子 tarball>"
if ! bash "$INSTALLER" -y -p "$TARBALL" \
     --prefix "$DSH_RUNTIME_DIR" --bin "$DSH_BIN_DIR" >"$TMPD/first-install.log" 2>&1; then
  say "--- 安装日志 tail ---"
  tail -n 40 "$TMPD/first-install.log" | tee -a "$EVID" >&2
  assert_fail "工作区 install.sh 退出非 0（完整日志: $TMPD/first-install.log）"
  case_finish
fi
assert_pass "工作区 install.sh 退出 0"

# --- 4. 覆盖重装回归（R1.2；这条是整条路线里最贵的一条） ----------------------
# 为什么贵: tar 只覆盖/新增、从不删除。修复前 install.sh 直接解包到已有目录, 旧
# runtime 的 npm 树会整体残留 —— 真机 1.2.2 覆盖 1.1.0 时, 旧嵌套 minipass@3
# 影子顶掉新 npm 的顶层 minipass@7, 新版 minipass-flush 解构 require('minipass')
# 得 undefined, npm 启动即 "Class extends value undefined"。
#
# 判定手段与旧路线的一处**有意差异**: 旧断言按**路径存在性**判残留
# （`[ ! -e .../npm/lib/commands/hook.js ]`）。上游 npm 将来完全可能又发布一个
# 同名文件, 那时"文件在"并不代表残留, 这条回归就会变成假红。这里改成**内容哨兵**:
# 种进去的字节带一个本次运行独有的串, 只要旧树残留就必被 grep 到, 与文件叫什么
# 名字无关。历史场景（嵌套 minipass 影子 + 旧 npm 命令文件）照旧复刻。
say "== 覆盖重装回归"
STALE_SENTINEL="dsh-stale-tree-${DSH_RUN_ID:-norun}"
KEEP_SENTINEL="dsh-keep-me-${DSH_RUN_ID:-norun}"
STALE_NESTED="$DSH_RUNTIME_DIR/node/lib/node_modules/npm/node_modules/minipass-flush/node_modules/minipass"
STALE_ORPHAN="$DSH_RUNTIME_DIR/node/lib/node_modules/npm/lib/commands/dsh-stale-orphan.js"
KEEP_FILE="$DSH_RUNTIME_DIR/keep-me.txt"

mkdir -p "$STALE_NESTED" "$(dirname "$STALE_ORPHAN")" || { assert_fail "无法种入残留夹具"; case_finish; }
printf '{"name":"minipass","version":"3.3.6","main":"index.js","dshSentinel":"%s"}\n' "$STALE_SENTINEL" \
  > "$STALE_NESTED/package.json"
printf 'module.exports = function Minipass () { /* %s */ }\n' "$STALE_SENTINEL" \
  > "$STALE_NESTED/index.js"
printf '// stale orphan from an old npm: %s\n' "$STALE_SENTINEL" > "$STALE_ORPHAN"
printf 'user file, not owned by the tarball: %s\n' "$KEEP_SENTINEL" > "$KEEP_FILE"

# 正控: 先证明哨兵真的可被检出, 否则"没检出"什么也证明不了。
if grep -rqF -- "$STALE_SENTINEL" "$DSH_RUNTIME_DIR"; then
  assert_pass "残留夹具已种入（哨兵可被检出）"
else
  assert_fail "种入哨兵后 grep 不到 —— 检出手段失效, 这条回归本次无意义"
fi

say "== 覆盖重装: 再跑一次同一安装器"
if ! bash "$INSTALLER" -y -p "$TARBALL" \
     --prefix "$DSH_RUNTIME_DIR" --bin "$DSH_BIN_DIR" >"$TMPD/reinstall.log" 2>&1; then
  say "--- 重装日志 tail ---"
  tail -n 40 "$TMPD/reinstall.log" | tee -a "$EVID" >&2
  assert_fail "覆盖重装 install.sh 退出非 0（完整日志: $TMPD/reinstall.log）"
  case_finish
fi
assert_pass "覆盖重装 install.sh 退出 0"

if grep -rqF -- "$STALE_SENTINEL" "$DSH_RUNTIME_DIR"; then
  assert_fail "覆盖重装后旧树残留仍在（解包未清旧树）: grep 到哨兵 [$STALE_SENTINEL]"
else
  assert_pass "覆盖重装清空了旧树残留（哨兵已不可检出）"
fi
if [ -f "$KEEP_FILE" ] && grep -qF -- "$KEEP_SENTINEL" "$KEEP_FILE"; then
  assert_pass "非 tarball 成员文件被保留（没被误删）"
else
  assert_fail "覆盖重装误删或改写了非 tarball 成员文件: $KEEP_FILE"
fi
# 残留清空后, npm 启动必加载的缓存模块链必须能 require —— 这正是真机崩溃链。
if "$NODE" -e "require('$DSH_RUNTIME_DIR/node/lib/node_modules/npm/node_modules/cacache/lib/content/write.js')" \
     >/dev/null 2>"$TMPD/cacache-err.log"; then
  assert_pass "npm cacache 模块链可加载（minipass 影子残留会让它失败）"
else
  say "--- cacache require stderr ---"
  cat "$TMPD/cacache-err.log" | tee -a "$EVID" >&2
  assert_fail "npm cacache 模块链加载失败（minipass 影子残留?）"
fi

# --- 5. node: ELF interpreter + 可直连运行（R1.4／R1.5） ----------------------
say "== node"
[ -x "$NODE" ] && assert_pass "node 就位（$NODE）" || assert_fail "node 缺失或不可执行: $NODE"
# readelf 的输出先缓冲再判: `readelf | grep -q` 会在 grep 提前退出时让 readelf
# 吃 SIGPIPE, 在 pipefail 下把"命中"读成非 0 —— 经典的假红。
READELF_OUT="$(readelf -l "$NODE" 2>/dev/null || true)"
printf '%s\n' "$READELF_OUT" >>"$EVID"
case "$READELF_OUT" in
  *ld-linux-aarch64.so.1*) assert_pass "node 的 ELF interpreter 是 glibc loader（R1.4）" ;;
  *) assert_fail "node 的 ELF interpreter 不是 glibc loader" ;;
esac
# 更精确的一条: interpreter 必须**等于 configure_glibc_node 会选中的那个 loader**
# （glibc_prefix 是唯一事实源）。上面那条只认 basename, 这条认全路径。
EXPECT_LOADER="$(ls "$(glibc_prefix)"/lib/ld-linux-*.so.* 2>/dev/null | head -1 || true)"
if [ -n "$EXPECT_LOADER" ]; then
  GOT_LOADER="$(patchelf --print-interpreter "$NODE" 2>/dev/null || true)"
  if [ "$GOT_LOADER" = "$EXPECT_LOADER" ]; then
    assert_pass "interpreter == common.sh 选中的 glibc loader"
  else
    assert_fail "interpreter=[$GOT_LOADER] != $(glibc_prefix) 下的 loader=[$EXPECT_LOADER]"
  fi
else
  # 不适用 != 已验证: 留可见原因, 不静默通过。
  say "   覆盖缺口: $(glibc_prefix)/lib 下没有 ld-linux-*.so.*, 无法做全路径比对（上面 basename 断言仍有效）"
fi
# 直连 exec（不经 grun）是这条断言的实质: grun 会让 /proc/self/exe 变成 loader,
# dsh 再 spawn 自己时就炸。所以这里**故意**不加 run_glibc_node 的包装。
if NODE_VER="$("$NODE" --version 2>"$TMPD/node-err.log")"; then
  assert_pass "补丁后的 node 可直连运行（$NODE_VER）"
else
  say "--- node stderr ---"
  cat "$TMPD/node-err.log" | tee -a "$EVID" >&2
  assert_fail "补丁后的 node 无法直连运行"
fi

# --- 6. wrapper 直连 exec + 版本（R1.6） ------------------------------------
say "== wrapper"
PKGJSON="$DSH_WORK_DIR/node_modules/@deepseek-ai/dsh/package.json"
INSTALLED_VER="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$PKGJSON" 2>/dev/null | head -1)"
if [ -z "$INSTALLED_VER" ]; then
  assert_fail "无法从安装树读出 dsh 版本: $PKGJSON"
  case_finish
fi
if [ "$INSTALLED_VER" = "$SEED_DSH_VERSION" ]; then
  assert_pass "安装树版本 == 种子声明的 dsh 版本（$INSTALLED_VER）"
else
  assert_fail "安装树版本 [$INSTALLED_VER] != 种子 SEED_DSH_VERSION [$SEED_DSH_VERSION]"
fi
[ -x "$WRAPPER" ] && assert_pass "wrapper 就位（$WRAPPER）" \
  || { assert_fail "wrapper 缺失或不可执行: $WRAPPER"; case_finish; }
if WVER="$("$WRAPPER" --version 2>&1)"; then
  if [ "$WVER" = "$SEED_DSH_VERSION" ]; then
    assert_pass "wrapper 直连 exec 出 dsh（$WVER, 与种子一致）"
  else
    assert_fail "dsh --version=[$WVER] != SEED_DSH_VERSION=[$SEED_DSH_VERSION]"
  fi
else
  assert_fail "wrapper 执行失败: $WVER"
fi

# --- 7. $BROWSER opener（R1.7） ---------------------------------------------
say "== opener"
[ -x "$OPENER" ] && assert_pass "opener 就位（$OPENER）" || assert_fail "opener 缺失: $OPENER"
if "$OPENER" </dev/null >/dev/null 2>&1; then
  assert_fail "opener 无参调用却退出 0（应退出 2）"
else
  opener_rc=$?
  if [ "$opener_rc" = 2 ]; then
    assert_pass "opener 无参退出 2"
  else
    assert_fail "opener 无参退出码 = $opener_rc, 期望 2"
  fi
fi

# --- 8. symlink + .bashrc PATH 注入（R1.8） ---------------------------------
say "== symlink + .bashrc"
if [ -L "$LINK" ]; then
  LINK_TARGET="$(readlink "$LINK")"
  if [ "$LINK_TARGET" = "$WRAPPER" ]; then
    assert_pass "dsh symlink 指向 wrapper"
  else
    assert_fail "symlink 目标错误: $LINK_TARGET != $WRAPPER"
  fi
else
  assert_fail "dsh symlink 缺失: $LINK"
fi
if "$LINK" --version >/dev/null 2>&1; then
  assert_pass "经 symlink 的 dsh 可运行"
else
  assert_fail "经 symlink 的 dsh 跑不起来: $LINK"
fi
BASHRC="$HOME/.bashrc"
if grep -qF -- '# dsh-termux' "$BASHRC" 2>/dev/null; then
  assert_pass ".bashrc 带 '# dsh-termux' tag"
else
  assert_fail ".bashrc 缺 '# dsh-termux' tag: $BASHRC"
fi
if grep -qF -- "export PATH=\"$DSH_BIN_DIR:\$PATH\"" "$BASHRC" 2>/dev/null; then
  assert_pass ".bashrc 注入了 bin 目录 PATH 行"
else
  assert_fail ".bashrc 缺 PATH 行: export PATH=\"$DSH_BIN_DIR:\$PATH\""
fi

# --- 9. 耐久证据 -------------------------------------------------------------
FACTS="seed=${SEED_TAG} dsh=${INSTALLED_VER:-?} node=${NODE_VER:-?}"
FACTS+=" installer_sha=$(sha256sum "$INSTALLER" | cut -d' ' -f1)"
FACTS+=" tarball_sha=$(sha256sum "$TARBALL" | cut -d' ' -f1)"
FACTS+=" reinstall=ok keep_file=kept stale_after_reinstall=none"
FACTS+=" opener_rc=${opener_rc:-?} tree=$(receipt_tree_id "$DSH_RUNTIME_DIR")"
say "== 事实: $FACTS"
receipt_case_facts "$DSH_RUN_ID" "$DSH_CASE_ID" "$FACTS" \
  || case_error "必要证据（case-facts）写不进去 —— 本次结论不成立"

case_finish
