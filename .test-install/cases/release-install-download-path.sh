#!/usr/bin/env bash
# release-install/download-path — 契约: `install.sh resolves DSH_RELEASE and
# fetches the release it was asked for`.
#
# 为什么单独一条（而不并进 workspace-installer）: 上面那条永远带 `-p`，也就是
# **永远不走下载分支**。而下载分支里有两件事只能这样测出来：
#   1. `DSH_RELEASE` 真的被用来拼 URL（不是被忽略成 latest），且拉的是**那个 tag**
#      的资产 —— 拼错 tag 的 URL 仍然会"成功下载"（GitHub 对同仓库任何 tag 都答），
#      只有比对"请求的 URL / 拿到的字节"才能发现；
#   2. 失败时**不留半装状态**（本 case 的负例）。
#
# 覆盖/映射（DECISIONS.md 附录 A.8 的 `DSH_RELEASE` 一行；A.9 缺口清单里
# "第 8 项：更新目标具名输入"之外的下载旋钮）: 旧体系**没有**这条断言 —— 旧
# r1 用 `-p`、旧 r2 下载的是自己拼的 URL。这是一条新契约的 case，不是移植。
#
# 三条铁律的落实:
#   * **不改生产脚本**（build/install.sh 的 URL 硬编码在 `https://github.com/$REPO/...`
#     处）。本 case 用**真实网络**跑真实安装器，只在沙箱 PATH 前面放一层
#     "见证 curl"（local-stub）：它把 install.sh 真正请求的 URL 与下载到的字节的
#     sha256 记下来，再把参数原样转发给真 curl。既不 patch 产物，也不伪造响应。
#   * 期望值全部派生: 目标 tag / 期望 dsh 版本 / 期望资产 sha256 都来自种子
#     （seeds/<name>.env，且 seed_load 已核对过哈希）；URL 只断言**尾巴**
#     （`/releases/download/<tag>/<asset>`），不写死仓库名。
#   * 负例（不存在的 tag）是**故意的**否定结论: 必须响亮失败、且不留半装状态；
#     它同时也是见证机制的**正控**（证明 curl 见证者真的在工作，否则正例里
#     "没记录"什么都不说明）。

set -uo pipefail

. "$DSH_TI_DIR/lib/state.sh"
. "$DSH_TI_DIR/lib/receipt.sh"
. "$DSH_TI_DIR/lib/seed.sh"

case_begin

EVID="$(dirname "$DSH_RESULTS")/evidence-${DSH_CASE_ID//\//-}.txt"
mkdir -p "$(dirname "$EVID")" || case_error "无法创建证据目录 $(dirname "$EVID")"
: > "$EVID" || case_error "无法写证据文件 $EVID"
say() { printf '%s\n' "$*" | tee -a "$EVID" >&2; }

[ -n "${DSH_SANDBOX_ROOT:-}" ] || case_error "DSH_SANDBOX_ROOT 未设置（本 case 只能由 run.sh 提供环境）"
case "${DSH_SANDBOX_ROOT:-}" in "$DSH_TI_DIR"/sandbox-*) ;; *)
  case_error "沙箱落点异常: ${DSH_SANDBOX_ROOT:-<空>}" ;; esac
TMPD="$DSH_SANDBOX_ROOT/tmp"
WITNESS="$TMPD/witness"
WRAPPER="$DSH_WORK_DIR/dsh"
LINK="$DSH_BIN_DIR/dsh"

# --- 1. 环境与工具前提 -------------------------------------------------------
say "== 环境"
say "   sandbox ${DSH_SANDBOX_ROOT}"
say "   runtime ${DSH_RUNTIME_DIR:-<空>}"
case "${DSH_RUNTIME_DIR:-}" in "$DSH_SANDBOX_ROOT"/*) assert_pass "runtime 落点在沙箱内" ;;
  *) assert_fail "runtime 越界: ${DSH_RUNTIME_DIR:-<空>}" ;; esac
case "${DSH_BIN_DIR:-}" in "$DSH_SANDBOX_ROOT"/*) assert_pass "bin 落点在沙箱内" ;;
  *) assert_fail "bin 越界: ${DSH_BIN_DIR:-<空>}" ;; esac
case "${HOME:-}" in "$DSH_SANDBOX_ROOT"/*) assert_pass "HOME 在沙箱内" ;;
  *) assert_fail "HOME 越界: ${HOME:-<空>}" ;; esac
# curl 是 registry 的 requires 已声明的；sha256sum 只是本 case 自用，缺了记缺结论。
command -v curl >/dev/null 2>&1 || case_unmet "缺少 curl（registry 的 requires 已声明 tool:curl）"
command -v sha256sum >/dev/null 2>&1 || case_unmet "缺少 sha256sum（coreutils），无法核对下载字节"

# --- 2. 种子 = 期望值（tag / dsh 版本 / 资产哈希）的唯一来源 -----------------
SEED_WANT="$(seed_default_name)"
if [ ! -f "$(seed_env_path "$SEED_WANT")" ]; then
  case_unmet "种子事实源不存在（生成: bash .test-install/run.sh seed set <tag> $SEED_WANT）"
fi
seed_load_require "$SEED_WANT"
SEED_TARBALL="$(seed_asset_by_name dsh-termux-runtime.tar.gz)" || {
  assert_fail "种子里没有 dsh-termux-runtime.tar.gz"; case_finish; }
# seed_load 已核对该文件与事实源一致，所以这里的现算就是 pin 住的那个 sha256。
SEED_SHA="$(sha256sum "$SEED_TARBALL" | cut -d' ' -f1)"
ASSET="dsh-termux-runtime.tar.gz"
EXPECT_SUFFIX="/releases/download/$SEED_TAG/$ASSET"
say "== 种子: tag=$SEED_TAG dsh=$SEED_DSH_VERSION"
say "   期望 URL 尾巴: $EXPECT_SUFFIX"
say "   期望资产 sha256: $SEED_SHA"

# --- 3. 安装器: 必须真的走下载分支 -------------------------------------------
INSTALLER_SRC="$DSH_HARNESS_ROOT/build/install.sh"
[ -f "$INSTALLER_SRC" ] || case_error "工作区安装器不存在: $INSTALLER_SRC"
# install.sh 优先看**自己旁边**有没有 *-runtime.tar.gz；有的话它根本不下载，
# 本 case 的意义当场消失。所以旁路文件在场时，把安装器**原字节**复制进沙箱再跑
# （只换 SCRIPT_DIR，不 patch 任何东西），常态下就地在工作区跑。
INSTALLER="$INSTALLER_SRC"; RUNFROM="workspace"
SIBLINGS="$(ls -1 "$DSH_HARNESS_ROOT/build"/*-runtime.tar.gz 2>/dev/null || true)"
if [ -n "$SIBLINGS" ]; then
  mkdir -p "$TMPD/dlpath" || case_error "无法创建 $TMPD/dlpath"
  if ! cp -f "$INSTALLER_SRC" "$TMPD/dlpath/install.sh"; then
    case_error "无法把安装器复制进沙箱"
  fi
  SHA_SRC="$(sha256sum "$INSTALLER_SRC" | cut -d' ' -f1)"
  SHA_CP="$(sha256sum "$TMPD/dlpath/install.sh" | cut -d' ' -f1)"
  if [ "$SHA_SRC" = "$SHA_CP" ]; then
    assert_pass "沙箱副本与工作区安装器字节相同（只换 SCRIPT_DIR）"
  else
    assert_fail "沙箱副本与工作区安装器字节不同 —— 见证对象不是被测脚本"
  fi
  INSTALLER="$TMPD/dlpath/install.sh"; RUNFROM="sandbox-copy"
  say "   build/ 下有旁路 tarball（$SIBLINGS）→ 用字节相同的沙箱副本强制走下载分支"
fi

# --- 4. 见证 curl（local-stub） ---------------------------------------------
# 记录每一笔请求的 URL 与真实退出码（attempts.log），成功下载时另存字节副本与
# sha256（curl.log）。**正控**靠负例: 那时也必须有记录，否则说明见证层没生效，
# 正例里"没有记录"就什么都证明不了。
REAL_CURL="$(command -v curl)"
rm -rf "$WITNESS"; mkdir -p "$WITNESS" || case_error "无法创建见证目录 $WITNESS"
cat > "$DSH_BIN_DIR/curl" <<SHIM_EOF
#!${BASH:-/data/data/com.termux/files/usr/bin/bash}
# witness curl (local-stub): 记下 install.sh 真正请求的 URL 与下载字节, 再原样转发。
# 不改生产脚本 —— 见证者只是站在 PATH 前面。
set -uo pipefail
real="$REAL_CURL"
witness="$WITNESS"
out=""
url=""
prev=""
for a in "\$@"; do
  if [ "\$prev" = "-o" ]; then out="\$a"; fi
  case "\$a" in http://*|https://*) url="\$a" ;; esac
  prev="\$a"
done
"\$real" "\$@"
rc=\$?
printf '%s\t%s\n' "\$url" "\$rc" >> "\$witness/attempts.log"
if [ "\$rc" = 0 ] && [ -n "\$out" ] && [ -f "\$out" ]; then
  n=\$(ls -1 "\$witness"/asset-*.tar.gz 2>/dev/null | wc -l)
  cp -f "\$out" "\$witness/asset-\$n.tar.gz" 2>/dev/null || true
  sum=\$(sha256sum "\$out" | cut -d' ' -f1)
  printf '%s\t%s\t%s\n' "\$url" "\$sum" "\$n" >> "\$witness/curl.log"
fi
exit "\$rc"
SHIM_EOF
chmod +x "$DSH_BIN_DIR/curl" || case_error "无法启用见证 curl"
say "== 见证 curl 就位: $DSH_BIN_DIR/curl（真 curl = $REAL_CURL）"

# 下载失败时区分「网络没到位」（UNMET：没结论）与「这个发布物就没有该资产」
# （FAIL：结论是否定）。只看 fetch 的返回值分不出这两件事。
download_failure_kind() { # $1=tag -> 打印 404/403/410/... 或 000
  local tag="$1" url code
  url="https://github.com/$(seed_repo_slug)/releases/download/$tag/$ASSET"
  code="$(curl -sIL -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || true)"
  printf '%s\n' "${code:-000}"
}

# --- 5. 负例: 不存在的 tag 必须响亮失败, 且不留半装状态 ----------------------
# tag 从种子派生（后缀带本进程号，保证不可能存在），不写死任何字面量。
BAD_TAG="${SEED_TAG}-does-not-exist-$$"
say "== 负例: DSH_RELEASE=$BAD_TAG（不存在的 release）"
if DSH_RELEASE="$BAD_TAG" bash "$INSTALLER" -y \
     --prefix "$DSH_RUNTIME_DIR" --bin "$DSH_BIN_DIR" >"$TMPD/neg-install.log" 2>&1; then
  assert_fail "不存在的 tag ($BAD_TAG) 竟然安装成功 —— 下载分支没有失败关闭"
else
  neg_rc=$?
  assert_pass "不存在的 tag 让 install.sh 响亮失败（exit $neg_rc）"
fi
if grep -qF -- "$BAD_TAG" "$TMPD/neg-install.log"; then
  assert_pass "失败日志里出现被请求的那个 tag（不是悄悄回落到 latest）"
else
  assert_fail "失败日志里没有 $BAD_TAG —— 无法证明它请求的是被要求的那一个"
fi
# 注意: BAD_TAG 以 SEED_TAG 开头，所以不能用 `grep "$SEED_TAG"` 判"回落"
# （它必然命中）。判据是**完整 URL 段**: 日志里不得出现针对种子 tag 的下载 URL。
if grep -qF -- "/releases/download/$SEED_TAG/" "$TMPD/neg-install.log"; then
  assert_fail "失败日志里出现了针对种子 tag 的下载 URL（$SEED_TAG）—— 疑似回落到别的发布物"
else
  assert_pass "失败日志只请求了被要求（且不存在）的那个 tag"
fi
# 见证层正控: 负例也必须留下一条 URL+非 0 退出码的记录。
# （不用 `grep | grep -q` 之类管道判定: pipefail 下上游吃 SIGPIPE 会把命中读成失败。）
NEG_ATTEMPT="$(grep -F -- "$BAD_TAG" "$WITNESS/attempts.log" 2>/dev/null || true)"
NEG_RC="$(printf '%s\n' "$NEG_ATTEMPT" | tail -n 1 | cut -f2)"
if [ -n "$NEG_ATTEMPT" ] && [ "${NEG_RC:-0}" != 0 ]; then
  assert_pass "见证层记录了这次失败请求（正控: 见证机制真的在工作）"
else
  assert_fail "见证层没有记录失败请求 —— 见证机制失效，正例的结论将不成立"
fi
for p in "$DSH_RUNTIME_DIR/node" "$DSH_RUNTIME_DIR/work" "$LINK"; do
  if [ -e "$p" ] || [ -L "$p" ]; then
    assert_fail "负例留下了半装状态: $p"
  else
    assert_pass "负例未留下 $p"
  fi
done
LEFTOVER="$(ls -1 "$TMPD"/runtime.*.tar.gz 2>/dev/null || true)"
if [ -n "$LEFTOVER" ]; then
  assert_fail "负例把半截下载物留在了 TMPDIR: $LEFTOVER"
else
  assert_pass "负例未留下半截下载物（cleanup trap 生效）"
fi
if grep -qF -- '# dsh-termux' "$HOME/.bashrc" 2>/dev/null; then
  assert_fail "负例改动了 ~/.bashrc（不该走到接线那一步）"
else
  assert_pass "负例未改动 ~/.bashrc"
fi

# --- 6. 正例: DSH_RELEASE=<种子 tag>, 不带 -p 的完整安装 ---------------------
say "== 正例: DSH_RELEASE=$SEED_TAG，不带 -p"
if DSH_RELEASE="$SEED_TAG" bash "$INSTALLER" -y \
     --prefix "$DSH_RUNTIME_DIR" --bin "$DSH_BIN_DIR" >"$TMPD/pos-install.log" 2>&1; then
  assert_pass "不带 -p 的完整安装退出 0"
else
  pos_rc=$?
  say "--- 安装日志 tail ---"
  tail -n 40 "$TMPD/pos-install.log" | tee -a "$EVID" >&2
  # 分不清"网络没到位"与"该发布物没有资产"就会把环境问题报成被测对象的结论。
  code="$(download_failure_kind "$SEED_TAG")"
  case "$code" in
    404|403|410) assert_fail "发布物 $SEED_TAG 不提供 $ASSET（HTTP $code）—— release 资产缺件"; case_finish ;;
    *) case_unmet "无法下载 $ASSET（tag=$SEED_TAG, HTTP ${code:-000}）—— 网络/代理受限则先 export https_proxy/http_proxy（install.sh exit $pos_rc）" ;;
  esac
fi
# 安装日志里的 tarball 路径落在 TMPDIR = 它是**下载来的**，不是本地旁路文件。
if grep -qF -- "tarball : $TMPD/" "$TMPD/pos-install.log"; then
  assert_pass "安装用的是下载到 TMPDIR 的 tarball（不是本地旁路文件）"
else
  assert_fail "安装用的 tarball 不在 TMPDIR —— 下载分支可能没被走到"
fi

# --- 7. 见证: 请求的就是被要求的那个 release, 字节就是 pin 住的那份 ----------
WURL=""; WSHA=""; WFILE=""
if [ -f "$WITNESS/curl.log" ]; then
  while IFS=$'\t' read -r wu ws wn; do
    case "$wu" in *"$EXPECT_SUFFIX") WURL="$wu"; WSHA="$ws"; WFILE="$WITNESS/asset-$wn.tar.gz" ;; esac
  done < "$WITNESS/curl.log"
fi
if [ -n "$WURL" ]; then
  assert_pass "install.sh 请求的正是被要求的那个 release: $WURL"
else
  say "--- attempts.log / curl.log ---"
  cat "$WITNESS/attempts.log" "$WITNESS/curl.log" 2>/dev/null | tee -a "$EVID" >&2
  assert_fail "没有见证到针对 $EXPECT_SUFFIX 的下载请求（请求的 release 不对或分支没走到）"
fi
if [ -n "$WFILE" ] && [ -f "$WFILE" ]; then
  assert_pass "见证层保存了下载字节副本"
else
  assert_fail "见证层没有保存下载字节副本 —— 无法核对资产身份"
fi
if [ -n "$WSHA" ] && [ "$WSHA" = "$SEED_SHA" ]; then
  assert_pass "下载到的资产 sha256 == 种子记录（$WSHA）"
else
  assert_fail "下载到的资产 sha256=[${WSHA:-<无>}] != 种子记录=[$SEED_SHA]"
fi

# --- 8. 装出来的 dsh 版本 == 种子版本 ---------------------------------------
PKGJSON="$DSH_WORK_DIR/node_modules/@deepseek-ai/dsh/package.json"
INSTALLED_VER="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$PKGJSON" 2>/dev/null | head -1)"
if [ "$INSTALLED_VER" = "$SEED_DSH_VERSION" ]; then
  assert_pass "安装树版本 == SEED_DSH_VERSION（$INSTALLED_VER）"
else
  assert_fail "安装树版本=[${INSTALLED_VER:-<无>}] != SEED_DSH_VERSION=[$SEED_DSH_VERSION]"
fi
[ -x "$WRAPPER" ] && assert_pass "wrapper 就位" \
  || { assert_fail "wrapper 缺失或不可执行: $WRAPPER"; case_finish; }
if WVER="$("$WRAPPER" --version 2>&1)"; then
  if [ "$WVER" = "$SEED_DSH_VERSION" ]; then
    assert_pass "wrapper 报出的版本 == 种子版本（$WVER）"
  else
    assert_fail "dsh --version=[$WVER] != SEED_DSH_VERSION=[$SEED_DSH_VERSION]"
  fi
else
  assert_fail "wrapper 执行失败: $WVER"
fi

# --- 9. 耐久证据 -------------------------------------------------------------
FACTS="seed=${SEED_TAG} dsh=${SEED_DSH_VERSION} installer_run_from=$RUNFROM"
FACTS+=" installer_sha=$(sha256sum "$INSTALLER" | cut -d' ' -f1)"
FACTS+=" downloaded_sha=${WSHA:-none} expected_sha=$SEED_SHA sha_match=$([ -n "$WSHA" ] && [ "$WSHA" = "$SEED_SHA" ] && echo yes || echo no)"
FACTS+=" requested_url=${WURL:-none} negative_tag=$BAD_TAG"
FACTS+=" tree=$(receipt_tree_id "$DSH_RUNTIME_DIR")"
say "== 事实: $FACTS"
receipt_case_facts "$DSH_RUN_ID" "$DSH_CASE_ID" "$FACTS" \
  || case_error "必要证据（case-facts）写不进去 —— 本次结论不成立"

case_finish
