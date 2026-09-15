#!/usr/bin/env bash
# release-install/candidate-artifact — 契约: **分支候选产物**装得上、按"as shipped"
# 跑得起来。
#
# 覆盖/映射: 旧体系**没有**这条 case（旧 r2 的 `--tag <pre tag>` 认证的是**已发布**
# 的 prerelease，不是分支构建的 workflow artifact）。它是 ADR-006「分支候选产物：
# 立即做，复用生产构建入口」在 release-install 侧的落点，与 dry-run/candidate-artifact
# 分工: 那条验"候选产物 × 工作区补丁集的行为"，这条验"候选产物**原样**安装与启动"。
#
# ── 本 case 要求的候选产物布局（由 `.github/workflows/candidate-artifact.yml` 产出） ──
#
#   <artifact-root>/
#     dsh-termux-runtime.tar.gz   # 运行时 tarball（与发布物同名资产）
#     install.sh                  # 该分支构建出的安装器（build/install.sh 的副本）
#     VERSION                     # 项目版本（repo VERSION 的副本）
#
#   三件必须在**同一层**。允许两种形态:
#     * 目录: <root> 直接就是这一层，或只隔一层子目录
#             （`gh run download` 解出来是 <artifact-name>/…，故允许一层）；
#     * 归档: .tar.gz/.tgz/.zip，先解开再按上面的规则找这一层。
#   额外文件允许（例如某个可选资产），但三件套必须在场。
#   candidate-artifact.yml 把这三件作为**主 artifact** 上传，patchset 与
#   provenance/checksums 放在**另一个** companion artifact 里，所以下载主 artifact
#   数出来的就该正好是这三件、且与发布资产同名。
#
#   理由: 这三件就是发布出去的那一套 —— 候选 workflow 与 `release.yml` 共用
#   `.github/scripts/package-runtime.sh` 的 stage 阶段（`cp build/install.sh
#   "$RT/install.sh"` + `cp VERSION "$RT/VERSION"` + `tar -czf
#   dsh-termux-runtime.tar.gz …`）。候选产物的意义就是"用发布前完全相同的一套东西在
#   真实设备上实测"，所以布局与来源都应当与发布一致、而不是另造一套。
#
#   **走 npm 路径，不是源码路径**: 构建入口是 `build/build-runtime.sh`（`DSH_SOURCE_TREE`
#   不设），与 `release.yml` 相同；`pre-release.yml` 走上游源码且 `tar --hard-dereference`
#   ＋拒绝 hard-link 条目，是**另一条**路径，不是本 case 的产物来源。
#   注意这条差异是真实存在的：npm 打包路径**没有** pre-release 那套 hard-link 防御，
#   所以这个候选产物必须在真机上真解包一次（Android 拒绝 link(2)）；Ubuntu 上的
#   installer smoke **不能**代替这一点。
#
#   没有候选产物时本 case 记 `case_unmet` —— 那是**正确行为**，不是失败，更不许
#   为了让这条跑绿去放宽断言或改 workflow。上传步骤已落地；拿到产物后它应当真跑。
#
# 期望值全部派生: 版本自读安装树（候选产物没有 pin 可对），VERSION 一致性由"产物
# 自带的那份"与"装出来的那份"互相核对。不写死任何版本号。

set -uo pipefail

. "$DSH_TI_DIR/lib/state.sh"
. "$DSH_TI_DIR/lib/receipt.sh"
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
STAGE="$TMPD/candidate"
NODE="$DSH_RUNTIME_DIR/node/bin/node"
WRAPPER="$DSH_WORK_DIR/dsh"

TARBALL_NAME="dsh-termux-runtime.tar.gz"
WS_INSTALLER="$DSH_HARNESS_ROOT/build/install.sh"

# --- 1. 环境 + 候选产物在场（缺件 -> UNMET: 没有可测对象） -------------------
say "== 环境"
say "   sandbox ${DSH_SANDBOX_ROOT}"
say "   runtime ${DSH_RUNTIME_DIR:-<空>}"
if [ -z "${DSH_CANDIDATE_ARTIFACT:-}" ]; then
  case_unmet "未提供分支候选产物（设 DSH_CANDIDATE_ARTIFACT=<目录|归档>；artifact:branch-candidate 前置）"
fi
say "   candidate ${DSH_CANDIDATE_ARTIFACT}"
if [ ! -e "$DSH_CANDIDATE_ARTIFACT" ]; then
  case_unmet "候选产物路径不存在: $DSH_CANDIDATE_ARTIFACT"
fi
case "${DSH_RUNTIME_DIR:-}" in "$DSH_SANDBOX_ROOT"/*) assert_pass "runtime 落点在沙箱内" ;;
  *) assert_fail "runtime 越界: ${DSH_RUNTIME_DIR:-<空>}" ;; esac
case "${DSH_BIN_DIR:-}" in "$DSH_SANDBOX_ROOT"/*) assert_pass "bin 落点在沙箱内" ;;
  *) assert_fail "bin 越界: ${DSH_BIN_DIR:-<空>}" ;; esac
command -v readelf >/dev/null 2>&1 || case_unmet "缺少 readelf（registry 的 requires 未声明 tool:readelf）"

# --- 2. 布局: 目录直接用, 归档先解开 -----------------------------------------
rm -rf "$STAGE"
mkdir -p "$STAGE" || case_error "无法创建暂存目录 $STAGE"
LAYOUT_FORM=""
if [ -d "$DSH_CANDIDATE_ARTIFACT" ]; then
  ROOT="$DSH_CANDIDATE_ARTIFACT"; LAYOUT_FORM="directory"
elif [ -f "$DSH_CANDIDATE_ARTIFACT" ]; then
  case "$DSH_CANDIDATE_ARTIFACT" in
    *.tar.gz|*.tgz)
      LAYOUT_FORM="archive"
      tar -xzf "$DSH_CANDIDATE_ARTIFACT" -C "$STAGE" >>"$EVID" 2>&1 || {
        case_unmet "候选产物归档解不开（不是合法 tar.gz?）: $DSH_CANDIDATE_ARTIFACT" ; } ;;
    *.zip)
      LAYOUT_FORM="archive"
      if command -v unzip >/dev/null 2>&1; then
        unzip -q -o "$DSH_CANDIDATE_ARTIFACT" -d "$STAGE" >>"$EVID" 2>&1 || {
          case_unmet "候选产物归档解不开: $DSH_CANDIDATE_ARTIFACT" ; }
      elif command -v python3 >/dev/null 2>&1; then
        python3 -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' \
          "$DSH_CANDIDATE_ARTIFACT" "$STAGE" >>"$EVID" 2>&1 || {
          case_unmet "候选产物归档解不开: $DSH_CANDIDATE_ARTIFACT" ; }
      else
        case_unmet "候选产物是 .zip，但既没有 unzip 也没有 python3 可以解开它"
      fi ;;
    *)
      case_unmet "候选产物 '$DSH_CANDIDATE_ARTIFACT' 是文件，但既不是可识别的归档（.tar.gz/.tgz/.zip）也不是目录 —— 本 case 要求的布局见文件头" ;;
  esac
  ROOT="$STAGE"
else
  case_unmet "候选产物既不是目录也不是常规文件: $DSH_CANDIDATE_ARTIFACT"
fi
say "== 布局形态: $LAYOUT_FORM（root=$ROOT）"

# 含三件套的那一层: 根，或根下唯一的若干层之一（gh run download 会多一层 artifact 名）。
layout_root() { # $1=目录 -> stdout=含三件套的目录；找不到返回 1
  local d="$1" s
  if [ -f "$d/$TARBALL_NAME" ] && [ -f "$d/install.sh" ] && [ -f "$d/VERSION" ]; then
    printf '%s\n' "$d"; return 0
  fi
  for s in "$d"/*/; do
    [ -d "$s" ] || continue
    if [ -f "$s$TARBALL_NAME" ] && [ -f "$s/install.sh" ] && [ -f "$s/VERSION" ]; then
      printf '%s\n' "$s"; return 0
    fi
  done
  return 1
}

CROOT="$(layout_root "$ROOT")" || {
  # 缺结论: 产物没到位的正确形态是"布局不符 + 精确原因"，不是断言失败。
  INVENTORY="$(find "$ROOT" -maxdepth 2 -mindepth 1 2>/dev/null | LC_ALL=C sort | head -40)"
  say "--- 候选产物实际内容（前 40 项）---"
  printf '%s\n' "${INVENTORY:-<空>}" | tee -a "$EVID" >&2
  case_unmet "候选产物布局不符合契约: 同一层必须同时有 $TARBALL_NAME + install.sh + VERSION（目录或 .tar.gz/.zip 归档；允许隔一层 artifact 名目录）。实际见证据文件"
}
say "   布局根: $CROOT"
CTARBALL="$CROOT/$TARBALL_NAME"
CINSTALLER="$CROOT/install.sh"
CVERSION_FILE="$CROOT/VERSION"

# 三件套逐条断言（走到这里说明都在场；显式记下来，便于人读证据）。
for f in "$CTARBALL" "$CINSTALLER" "$CVERSION_FILE"; do
  [ -f "$f" ] && assert_pass "候选产物含 $(basename "$f")" || assert_fail "候选产物缺 $f"
done
[ -s "$CTARBALL" ] && assert_pass "运行时 tarball 非空" || assert_fail "运行时 tarball 为空: $CTARBALL"
CVERSION="$(tr -d '[:space:]' < "$CVERSION_FILE" 2>/dev/null || true)"
[ -n "$CVERSION" ] && assert_pass "VERSION 非空（$CVERSION）" || assert_fail "VERSION 为空: $CVERSION_FILE"

# --- 3. 用候选产物**自带**的 install.sh 安装（as shipped） --------------------
say "== 安装: bash <候选产物>/install.sh -y -p <候选产物>/$TARBALL_NAME"
if ! bash "$CINSTALLER" -y -p "$CTARBALL" \
     --prefix "$DSH_RUNTIME_DIR" --bin "$DSH_BIN_DIR" >"$TMPD/install.log" 2>&1; then
  say "--- 安装日志 tail ---"
  tail -n 40 "$TMPD/install.log" | tee -a "$EVID" >&2
  assert_fail "候选产物自带的 install.sh 退出非 0（完整日志: $TMPD/install.log）"
  case_finish
fi
assert_pass "候选产物自带的 install.sh 退出 0"

# --- 4. VERSION 自洽 + 安装树接线 -------------------------------------------
say "== 安装结果"
[ -x "$NODE" ] && assert_pass "node 就位" || { assert_fail "node 缺失或不可执行: $NODE"; case_finish; }
# 候选产物必须在**本机**（arm64 Termux）直接跑得起来: interpreter 得是 glibc loader。
# 输出先缓冲再判, 防 `readelf | grep -q` 的 SIGPIPE 假红。
READELF_OUT="$(readelf -l "$NODE" 2>/dev/null || true)"
printf '%s\n' "$READELF_OUT" >>"$EVID"
case "$READELF_OUT" in
  *ld-linux-aarch64.so.1*) assert_pass "候选产物里的 node 已被接成 glibc loader（直连 exec）" ;;
  *) assert_fail "候选产物里的 node 的 ELF interpreter 不是 glibc loader" ;;
esac
if [ -f "$DSH_RUNTIME_DIR/VERSION" ]; then
  assert_pass "安装树携带 VERSION"
  IVERSION="$(tr -d '[:space:]' < "$DSH_RUNTIME_DIR/VERSION")"
  # 候选产物的两个 VERSION 来自同一次构建（candidate-artifact.yml 的 stage 阶段
  # 用 `cp VERSION "$RT/VERSION"` 把仓库那份放进 tarball），不一致
  # 说明这个候选产物不是一套自洽的东西 —— 装机前就该被发现。
  if [ "$IVERSION" = "$CVERSION" ]; then
    assert_pass "安装树的 VERSION == 候选产物的 VERSION（$IVERSION）"
  else
    assert_fail "安装树 VERSION=[$IVERSION] != 候选产物 VERSION=[$CVERSION]（产物不自洽）"
  fi
else
  assert_fail "安装树没有 VERSION —— tarball 未按打包契约携带它（pre-1.2.1? 候选产物不该这么旧）"
fi
PKGJSON="$DSH_WORK_DIR/node_modules/@deepseek-ai/dsh/package.json"
DSH_VER="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$PKGJSON" 2>/dev/null | head -1)"
[ -n "$DSH_VER" ] && assert_pass "安装树自报 dsh 版本（$DSH_VER）" \
  || { assert_fail "无法从安装树读出 dsh 版本: $PKGJSON"; case_finish; }
[ -x "$WRAPPER" ] && assert_pass "wrapper 就位" || assert_fail "wrapper 缺失或不可执行: $WRAPPER"

# --- 5. boot（候选产物按 as shipped 跑起来） --------------------------------
say "== boot"
BIN="$DSH_WORK_DIR/node_modules/@deepseek-ai/dsh/lib/bin.js"
boot_ok=0
if boot_out="$(run_glibc_node "$NODE" "$BIN" --version 2>&1)"; then
  boot_ok=1
  say "   exit=0 out=${boot_out//$'\n'/ | }"
  assert_pass "候选产物装出的 dsh 能启动"
  case "$boot_out" in
    *"$DSH_VER"*) assert_pass "启动报出的版本与安装树一致（$DSH_VER）" ;;
    *) assert_fail "启动报出的版本不含 $DSH_VER: $boot_out" ;;
  esac
else
  say "   out=${boot_out//$'\n'/ | }"
  assert_fail "候选产物装出的 dsh 启动失败: $boot_out"
fi

# --- 6. 耐久证据 -------------------------------------------------------------
# install.sh 与工作区那份是否同字节只是**信息**（候选产物可以来自别的 commit 的
# CI，工作树里有未推的改动也正常）：因此记进事实而不做成断言。
WS_SHA="missing"; [ -f "$WS_INSTALLER" ] && WS_SHA="$(sha256sum "$WS_INSTALLER" | cut -d' ' -f1)"
C_SHA="$(sha256sum "$CINSTALLER" | cut -d' ' -f1)"
INSTALLER_MATCH="no"; [ "$C_SHA" = "$WS_SHA" ] && INSTALLER_MATCH="yes"
if [ "$INSTALLER_MATCH" = no ]; then
  say "   信息: 候选产物的 install.sh 与工作区 build/install.sh 不同字节（可能来自别的 commit；本 case 不做断言）"
fi
FACTS="candidate=$(basename "${DSH_CANDIDATE_ARTIFACT:-none}") layout=$LAYOUT_FORM"
FACTS+=" tarball_sha=$(sha256sum "$CTARBALL" | cut -d' ' -f1)"
FACTS+=" installer_sha=$C_SHA workspace_installer_sha=$WS_SHA installer_matches_workspace=$INSTALLER_MATCH"
FACTS+=" project_version=${CVERSION:-?} dsh=${DSH_VER:-?} boot=$([ "${boot_ok:-0}" = 1 ] && echo ok || echo failed)"
FACTS+=" tree=$(receipt_tree_id "$DSH_RUNTIME_DIR")"
say "== 事实: $FACTS"
receipt_case_facts "$DSH_RUN_ID" "$DSH_CASE_ID" "$FACTS" \
  || case_error "必要证据（case-facts）写不进去 —— 本次结论不成立"

case_finish
