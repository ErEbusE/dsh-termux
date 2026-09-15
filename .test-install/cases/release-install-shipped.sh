#!/usr/bin/env bash
# release-install/shipped-release — 契约: **已发布**的 release 装得上、跑得起来，
# 且与它自己声明的东西自洽（"as shipped"）。
#
# 覆盖/映射（DECISIONS.md 附录 A.3；旧文件 .test-install/routes/r2-release.sh **已删除**，
# 稳定发布物部分 = R2.1–R2.14）:
#   r2 §0 解析 latest + 全新下载两个资产 -> §3 本节（R2.1）。**解析**已归运行器
#        （具名输入实例: `run.sh --release-tag` → DSH_RELEASE_TAG，ADR-011）；
#        本节只做"全新下载"，走 lib/seed.sh 的 seed_fetch_assets（唯一实现:
#        绝不 wget -c 续传、先 .part 再原子替换）。
#   r2 §1 tarball 关键成员（6 项）        -> §4 本节（R2.2）
#   r2 §1 顶层 VERSION（条件断言）        -> §4 本节（R2.3）
#   r2 §1 shipped DSH_PATCH_SET 自洽      -> §4 本节（R2.4，用 lib/patchset.sh 的**文本解析**）
#   r2 §2 shipped install.sh 退出 0       -> §5 本节（R2.5）
#   r2 §2b shipped 补丁 marker（条件感知）-> §6 本节（R2.6）
#   r2 §2b-2 shipped 原生件在场           -> §7 本节（R2.7）
#   r2 §2c 三个行为探针（shipped marker 触发）-> §8 本节（R2.8）
#   r2 §3 node 补丁 + 可运行              -> §9 本节（R2.9）
#   r2 §4 wrapper execs dsh（浮动模式自读期望版本）-> §10 本节（R2.10）
#   r2 §5 opener 无参 exit 2              -> §10 本节（R2.11）
#   r2 §6 symlink + .bashrc 注入          -> §10 本节（R2.12）
#   r2 §7 live_sentinel                   -> 框架（lib/sandbox.sh 的 case 前后守卫，R2.13）
#   r2 --pinned 离线回退                  -> **不在本 row**：附录 A.3 的 R2.14 已改判给
#        `baseline-seed`／`release-seed` 具名输入 + `seed:stable` 前置（消费它们的是
#        update/shipped-updater 与 dry-run/pinned-rebase）。本 case 的输入是
#        `release-assets`（按实例解析并**全新下载**），不实现 pin 回退。
#   r2 --tag <pre tag>（R2.15，pre 渠道） -> **不在本次分工**（ADR-011 的第二个实例，
#        由另一条线落地；同一个 executor 在 `--release-tag pre-…` 下天然也能跑，
#        但"同一轮两个实例"的记账键不归这里改）。
#
# 期望值全部派生: 补丁清单/marker 来自**产物内**的 patch-lib.sh（文本解析，不 source
# 被测产物），原生件来自 common.sh 的 native_prebuild_entries，期望版本从**下载树
# 自读**（浮动模式没有 pin 可对，断言的是"wrapper 与其内容自洽"）。不写死任何版本号、
# marker 串或补丁文件名。

set -uo pipefail

. "$DSH_TI_DIR/lib/state.sh"
. "$DSH_TI_DIR/lib/receipt.sh"
. "$DSH_TI_DIR/lib/seed.sh"
. "$DSH_TI_DIR/lib/patchset.sh"
. "$DSH_TI_DIR/lib/probes.sh"
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
DL="$TMPD/dl"

NODE="$DSH_RUNTIME_DIR/node/bin/node"
WRAPPER="$DSH_WORK_DIR/dsh"
OPENER="$DSH_WORK_DIR/dsh-termux-open"
LINK="$DSH_BIN_DIR/dsh"

# --- 1. 环境 ----------------------------------------------------------------
say "== 环境"
say "   sandbox ${DSH_SANDBOX_ROOT}"
say "   runtime ${DSH_RUNTIME_DIR:-<空>}"
case "${DSH_RUNTIME_DIR:-}" in "$DSH_SANDBOX_ROOT"/*) assert_pass "runtime 落点在沙箱内" ;;
  *) assert_fail "runtime 越界: ${DSH_RUNTIME_DIR:-<空>}" ;; esac
case "${DSH_BIN_DIR:-}" in "$DSH_SANDBOX_ROOT"/*) assert_pass "bin 落点在沙箱内" ;;
  *) assert_fail "bin 越界: ${DSH_BIN_DIR:-<空>}" ;; esac
case "${HOME:-}" in "$DSH_SANDBOX_ROOT"/*) assert_pass "HOME 在沙箱内" ;;
  *) assert_fail "HOME 越界: ${HOME:-<空>}" ;; esac

# --- 2. 发布物输入实例 + 工具前提 -------------------------------------------
# 实例身份来自运行器（input-release.tsv → DSH_RELEASE_TAG/DSH_RELEASE_SELECTOR）。
# 拿不到 = 本轮没有可认证的对象 -> UNMET，绝不自作主张去解析 latest（那会得出
# "认证了稳定渠道"的结论而实际什么都没认证，ADR-011）。
[ -n "${DSH_RELEASE_TAG:-}" ] \
  || case_unmet "本轮没有解析出发布物输入实例（selector=${DSH_RELEASE_SELECTOR:-latest}）—— 没有可认证的对象"
say "== 发布物实例: selector=${DSH_RELEASE_SELECTOR:-latest} -> tag=$DSH_RELEASE_TAG"
command -v wget >/dev/null 2>&1 \
  || case_unmet "缺少 wget（全新下载发布资产走 seed_fetch_assets；registry 的 requires 未声明 tool:wget）"
command -v readelf >/dev/null 2>&1 \
  || case_unmet "缺少 readelf，无法核对 node 的 ELF interpreter（registry 的 requires 未声明 tool:readelf）"

# --- 3. 全新下载两个发布资产（R2.1） ----------------------------------------
# "全新"是断言的一部分: 旧体系踩过 `wget -c` 续传把不同 tag 的同名旧文件拼成
# "新包+旧尾"的坑，且下载物与任何 pin 资产严格隔离（不污染种子）。
say "== 全新下载 $DSH_RELEASE_TAG 的两个资产 -> $DL"
rm -rf "$DL"
mkdir -p "$DL" || { assert_fail "无法创建下载目录 $DL"; case_finish; }
if ! seed_fetch_assets "$DSH_RELEASE_TAG" "$DL" >"$TMPD/fetch.log" 2>&1; then
  tail -n 40 "$TMPD/fetch.log" | tee -a "$EVID" >&2
  # 分不清"网络没到位"（UNMET：没结论）与"该发布物就没有资产"（FAIL：结论是否定）
  # 就会把环境问题报成被测对象的结论。逐个资产问一次 HEAD 是哪一种。
  MISSING_ASSET=""; HTTP_SEEN=""
  for a in dsh-termux-runtime.tar.gz install.sh; do
    REL_URL="https://github.com/$(seed_repo_slug)/releases/download/$DSH_RELEASE_TAG/$a"
    HTTP_CODE="$(curl -sIL -o /dev/null -w '%{http_code}' "$REL_URL" 2>/dev/null || true)"
    HTTP_SEEN+="${HTTP_SEEN:+, }$a=${HTTP_CODE:-000}"
    case "${HTTP_CODE:-000}" in
      404|403|410) MISSING_ASSET="$a" ;;
    esac
  done
  if [ -n "$MISSING_ASSET" ]; then
    assert_fail "发布物 $DSH_RELEASE_TAG 不提供 $MISSING_ASSET（$HTTP_SEEN）—— 资产缺件"
    case_finish
  fi
  case_unmet "无法下载发布资产（tag=$DSH_RELEASE_TAG, $HTTP_SEEN）—— 受限网络先 export https_proxy/http_proxy"
fi
TARBALL="$DL/dsh-termux-runtime.tar.gz"
INSTALLER="$DL/install.sh"
for f in "$TARBALL" "$INSTALLER"; do
  [ -f "$f" ] && assert_pass "下载到 $(basename "$f")" || assert_fail "缺少下载物 $f"
done
[ -f "$TARBALL" ] && [ -f "$INSTALLER" ] || case_finish

# --- 4. tarball 结构与 shipped 注册表自洽（R2.2／R2.3／R2.4） -----------------
say "== tarball 完整性（不用 tar | grep 防 SIGPIPE：列表先缓冲到变量）"
TAR_LIST="$(tar tzf "$TARBALL" 2>/dev/null)" || { assert_fail "无法读取 tarball 文件列表"; case_finish; }
for want in \
  node/bin/node \
  work/node_modules/@deepseek-ai/dsh/lib/bin.js \
  scripts/common.sh \
  scripts/patch-lib.sh \
  scripts/update-dsh.sh \
  install.sh; do
  if grep -qx "$want" <<<"$TAR_LIST"; then
    assert_pass "tarball 含 $want"
  else
    assert_fail "tarball 缺少 $want"
  fi
done

# R2.3: 1.2.1 起 tarball 打包顶层 VERSION（更新器比对补丁集新鲜度的依据）；旧
# release 没有 —— 按存在性条件断言，不对旧产物误红。缺了=覆盖缺口，留可见原因。
if grep -qx "VERSION" <<<"$TAR_LIST"; then
  TVER="$(tar xzOf "$TARBALL" VERSION 2>/dev/null | tr -d '[:space:]')"
  assert_pass "tarball 携带顶层 VERSION（${TVER:-<空>}）"
else
  say "   覆盖缺口: tarball 无顶层 VERSION（pre-1.2.1 release），跳过其断言（不适用 != 已验证）"
fi

# R2.4: 补丁清单不硬编码 —— 从**产物内** patch-lib.sh 的 DSH_PATCH_SET 文本派生。
# 「声明了却没打包」的缺件在这里红；补丁目标 lib 一并核对。绝不 source 被测产物
# （它可能是任何历史形态，甚至是当前 bash 下不该执行的代码）。
SHIPPED_DIR="$TMPD/shipped"
rm -rf "$SHIPPED_DIR"; mkdir -p "$SHIPPED_DIR"
if ! tar -xzf "$TARBALL" -C "$SHIPPED_DIR" scripts/patch-lib.sh >/dev/null 2>&1; then
  assert_fail "无法从 tarball 解出 scripts/patch-lib.sh"
  case_finish
fi
SHIPPED_LIB="$SHIPPED_DIR/scripts/patch-lib.sh"
NPATCH=0
while IFS= read -r entry; do
  [ -n "$entry" ] || continue
  NPATCH=$((NPATCH + 1))
  pname="$(patchset_patch "$entry")"
  rel="$(patchset_rel "$entry")"
  if grep -qx "patches/$pname" <<<"$TAR_LIST"; then
    assert_pass "tarball 含 patches/$pname"
  else
    assert_fail "tarball 缺少 patches/$pname（shipped DSH_PATCH_SET 声明了它）"
  fi
  if grep -qx "work/node_modules/@deepseek-ai/$rel" <<<"$TAR_LIST"; then
    assert_pass "tarball 含补丁目标 $rel"
  else
    assert_fail "tarball 缺少补丁目标 work/node_modules/@deepseek-ai/$rel"
  fi
done < <(patchset_entries "$SHIPPED_LIB")
if [ "$NPATCH" -ge 1 ]; then
  assert_pass "shipped patch-lib.sh 声明了 $NPATCH 条 DSH_PATCH_SET 条目"
else
  assert_fail "shipped patch-lib.sh 未声明任何 DSH_PATCH_SET 条目（打包回归）"
fi

# --- 5. 用**发布资产自己的** install.sh 安装（R2.5） -------------------------
# 被测对象是用户真正拿到的那一份，不是工作区那份 —— 这正是"as shipped"的含义。
say "== shipped install.sh 安装"
if ! bash "$INSTALLER" -y -p "$TARBALL" \
     --prefix "$DSH_RUNTIME_DIR" --bin "$DSH_BIN_DIR" >"$TMPD/install.log" 2>&1; then
  say "--- 安装日志 tail ---"
  tail -n 40 "$TMPD/install.log" | tee -a "$EVID" >&2
  assert_fail "shipped install.sh 退出非 0（完整日志: $TMPD/install.log）"
  case_finish
fi
assert_pass "shipped install.sh 退出 0"

# --- 6. shipped 补丁 marker（条件条目感知；R2.6） ---------------------------
# tarball 里的 lib 应由 release 流水线预打补丁。marker 派生与"某条目是否适用"
# 的判定都用 lib/patchset.sh（文本解析），与生产判定同语义：
#   * 四段式条件条目在该 dsh 版本没有前置串时跳过（build-runtime.sh 用同一套
#     patch-lib，release 构建同样会跳过它）——稳定渠道落后于上游时这是常态，
#     不是构建漏打；
#   * 无条件条目缺 marker = 构建漏打 -> FAIL。
# "不适用"必须留下可读原因（跳过数与原因进证据与 case-facts），不是静默通过。
say "== shipped 补丁 marker"
if patchset_verify_markers "$SHIPPED_LIB" "$DSH_WORK_DIR" >"$TMPD/markers.log" 2>&1; then
  assert_pass "shipped 补丁标记齐全（按产物内 DSH_PATCH_SET 派生）"
else
  say "--- marker 检查明细 ---"
  cat "$TMPD/markers.log" | tee -a "$EVID" >&2
  assert_fail "shipped lib 缺 marker（release 构建未打补丁?）"
fi
cat "$TMPD/markers.log" >>"$EVID"
NSKIP="$(grep -c '^skip ' "$TMPD/markers.log" || true)"
if [ "${NSKIP:-0}" -gt 0 ]; then
  say "   覆盖率缺口: $NSKIP 条条件补丁不适用于本 dsh 版本（不适用 != 已验证）"
fi

# --- 7. shipped 原生件在场（R2.7；ADR-001 落地前保留） ----------------------
# dsh >= 0.1.3 的 fs-ext 是 node-gyp 原生件：tarball 必须带着编译产物，否则
# dsh web 在设备上起不来。这里只断言"产物在场"（架构/装载一致性由发布它的
# arm64 构建的 require 自检与真机实测负责）。条目从 common.sh 派生。
say "== shipped 原生件"
NATIVE_N=0; NATIVE_SKIP=0
while IFS= read -r nentry; do
  [ -n "$nentry" ] || continue
  NATIVE_N=$((NATIVE_N + 1))
  npkg="${nentry%%:*}"
  nart="${nentry#*:}"
  if [ ! -f "$DSH_WORK_DIR/node_modules/$npkg/package.json" ]; then
    NATIVE_SKIP=$((NATIVE_SKIP + 1))
    say "   覆盖缺口: 该 dsh 版本不用 $npkg，跳过其原生件断言"
    continue
  fi
  if [ -f "$DSH_WORK_DIR/node_modules/$npkg/$nart" ]; then
    assert_pass "shipped 原生件在场: $npkg/$nart"
  else
    assert_fail "shipped tarball 缺 $npkg/$nart（dsh web 在设备上会起不来）"
  fi
done < <(native_prebuild_entries)
[ "$NATIVE_N" -gt 0 ] || assert_fail "native_prebuild_entries 为空 —— 原生件注册表坏了"

# --- 8. 行为级探针（R2.8；触发 marker 由**产物内**注册表派生） ---------------
# lib/probes.sh 的约定: 注册表经 DSH_PATCH_SET 送进去。产物的那份只能文本解析，
# 所以在这里把解析结果装进同名数组 —— 探针因此按"这棵 shipped 树自己声明的"
# 目标/marker 触发，而不是按工作区那份（两者的补丁集可以不同）。
say "== 行为级探针"
DSH_PATCH_SET=()
while IFS= read -r pentry; do
  [ -n "$pentry" ] && DSH_PATCH_SET+=("$pentry")
done < <(patchset_entries "$SHIPPED_LIB")
say "   探针的注册表: 产物内 DSH_PATCH_SET（$NPATCH 条）"
probe_rc=0
probe_patch_set_behaviors "$DSH_WORK_DIR" "$NODE" || probe_rc=1
if [ -n "$PROBE_SKIPPED" ]; then
  say "   跳过的探针（不计为已验证）: $PROBE_SKIPPED"
fi

# --- 9. node 补丁 + 直连运行（R2.9） ---------------------------------------
say "== node"
[ -x "$NODE" ] && assert_pass "node 就位（$NODE）" || assert_fail "node 缺失或不可执行: $NODE"
# 输出先缓冲再判, 防 `readelf | grep -q` 的 SIGPIPE 假红（见 workspace-installer 同处注释）。
READELF_OUT="$(readelf -l "$NODE" 2>/dev/null || true)"
printf '%s\n' "$READELF_OUT" >>"$EVID"
case "$READELF_OUT" in
  *ld-linux-aarch64.so.1*) assert_pass "node 的 ELF interpreter 是 glibc loader" ;;
  *) assert_fail "node 的 ELF interpreter 不是 glibc loader" ;;
esac
if NODE_VER="$("$NODE" --version 2>"$TMPD/node-err.log")"; then
  assert_pass "补丁后的 node 可直连运行（$NODE_VER）"
else
  cat "$TMPD/node-err.log" | tee -a "$EVID" >&2
  assert_fail "补丁后的 node 无法直连运行"
fi

# --- 10. wrapper / opener / symlink + .bashrc（R2.10／R2.11／R2.12） ---------
say "== wrapper"
# 浮动模式没有 pin 可对: 期望版本从**下载树自读**，断言的是"wrapper 与其内容自洽"。
PKGJSON="$DSH_WORK_DIR/node_modules/@deepseek-ai/dsh/package.json"
EXPECT_VER="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$PKGJSON" 2>/dev/null | head -1)"
if [ -z "$EXPECT_VER" ]; then
  assert_fail "无法从安装树读出期望版本: $PKGJSON"
  case_finish
fi
say "   安装树自报版本: $EXPECT_VER"
[ -x "$WRAPPER" ] && assert_pass "wrapper 就位" \
  || { assert_fail "wrapper 缺失或不可执行: $WRAPPER"; case_finish; }
if WVER="$("$WRAPPER" --version 2>&1)"; then
  if [ "$WVER" = "$EXPECT_VER" ]; then
    assert_pass "shipped wrapper execs dsh（$WVER，与安装树自洽）"
  else
    assert_fail "dsh --version=[$WVER] != 安装树 [$EXPECT_VER]"
  fi
else
  assert_fail "wrapper 执行失败: $WVER"
fi

say "== opener"
[ -x "$OPENER" ] && assert_pass "opener 就位" || assert_fail "opener 缺失: $OPENER"
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

# --- 11. 耐久证据 -----------------------------------------------------------
# 实例身份必须进 case-facts: 只写 case id 的 PASS 会把一次 pre 认证读成稳定渠道
# 认证（ADR-011）。发布资产的内容摘要同样要留 —— 同一个 tag 的资产理论上可变。
FACTS="release_instance=$DSH_RELEASE_TAG selector=${DSH_RELEASE_SELECTOR:-latest}"
FACTS+=" tarball_sha=$(sha256sum "$TARBALL" | cut -d' ' -f1)"
FACTS+=" dsh=${EXPECT_VER:-?} node=${NODE_VER:-?} shipped_patches=$NPATCH markers_skipped=${NSKIP:-0}"
FACTS+=" natives_checked=$NATIVE_N natives_skipped=$NATIVE_SKIP"
FACTS+=" probes=$([ "$probe_rc" = 0 ] && echo ok || echo failed) probes_skipped=${PROBE_SKIPPED:-none}"
FACTS+=" opener_rc=${opener_rc:-?} tree=$(receipt_tree_id "$DSH_RUNTIME_DIR")"
say "== 事实: $FACTS"
receipt_case_facts "$DSH_RUN_ID" "$DSH_CASE_ID" "$FACTS" \
  || case_error "必要证据（case-facts）写不进去 —— 本次结论不成立"

case_finish
