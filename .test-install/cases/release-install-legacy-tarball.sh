#!/usr/bin/env bash
# release-install/legacy-tarball — 契约: **工作区安装器**能安装一个**低于支持下限**的
# 已发布 runtime（用那个产物**自带的** helper 集），且结果通过声明的 boot 探针。
#
# 为什么要这条（11d）: ADR-001 把 npm 路径的支持窗口定在 dsh >= 0.1.5-alpha.1，并规定
# "更早的版本走它们自己的 release tarball"。也就是说**旧版本的唯一入口是 tarball**。
# 11b 删掉了原生件机件（那套代码按 ADR-001 自己的说法"只为 0.1.3/0.1.4 存在"），
# 所以必须有一条回归证明"这条路径仍然工作"，而不是靠"调用关系上不受影响"的静态阅读。
#
# 这条 case 测的**到底是什么**（措辞必须照此，不得加重）:
#   * **当前 workpace `build/install.sh` × 指定旧 tag 的 tarball**，在隔离 prefix 里，
#     用**该产物自带的** `scripts/common.sh` 完成安装；安装后的 runtime 通过声明的 boot 探针。
#   * 它是"当前安装器 ↔ 历史 helper 接口"的兼容性 ＋ 该历史载荷的自足可运行性。
#   * 它**不是**"退役原生件机件"的因果验证：那条删除的代码**不在**这条执行路径上
#     （见下）。删掉它不会有任何可观测差异，所以本 case **不主张**它被验证过。
#
# 为什么用 pre-dsh-0.1.3-alpha.2-g82a5fd6-1.2.8:
#   * 稳定渠道**不存在** 0.1.3.x／0.1.4.x（实测枚举过全部稳定 release）；0.1.4 不存在于任何渠道；
#     唯一的 0.1.3 就是这条 prerelease。ADR-011 明确承认"已发布的 prerelease"是有效的
#     发布物实例，所以这不是勉强凑合。
#   * 它正是**依赖原生件的那个年代**的代表：tarball 里带**已编译的**
#     `work/node_modules/fs-ext/build/Release/fs_ext.node`（实测 76KB）；而对照的
#     `dsh-0.1.2-rc.1-1.2.8` 里 `fs-ext` 条目数为 **0**（实测）——0.1.2 根本不需要原生件，
#     拿它当"原生年代"的证据是错的（PATCHES.md 也这么写）。
#
# 为什么这条 case 的绿**不是**空洞的（顾问裁决 D）:
#   删除的当前代码在依赖图之外，所以"退役"本身不可观测——这是**结构性**的，不是本 case 的缺陷。
#   但真正的反证仍然存在：安装器新增一个旧 helper 没有的函数/改签名、解包或 ELF 接线坏掉、
#   载荷不对、旧原生件加载不了，都会让这条**红**。所以它有意义，只是意义**不是**"退役被验证"。
#
# 不做的事（护栏）:
#   * **不 overlay**：绝不拿当前 `scripts/`／`patches/` 去替换被测旧产物里的那份。
#   * **不借用种子路径**：`run.sh seed set` 明确拒绝 `pre-*`（run.sh:889-896），且
#     `seeds/seed-assets/` 是**扁平**目录、所有种子共用同名文件，加第二颗种子会**覆盖**
#     stable 的资产。所以本 case 用 `release-assets` 实例（`--release-tag`）**当场下载**。
#   * **不改** `release-install/shipped-release`：那条刻意执行**发布出去的** install.sh
#     （`changes=-`，不被 diff 触发），与本条"当前安装器"是不同契约。

set -uo pipefail

. "$DSH_TI_DIR/lib/state.sh"
. "$DSH_TI_DIR/lib/receipt.sh"
. "$DSH_TI_DIR/lib/seed.sh"
. "$DSH_HARNESS_ROOT/scripts/common.sh"

case_begin

EVID="$(dirname "$DSH_RESULTS")/evidence-${DSH_CASE_ID//\//-}.txt"
mkdir -p "$(dirname "$EVID")" || case_error "无法创建证据目录 $(dirname "$EVID")"
: > "$EVID" || case_error "无法写证据文件 $EVID"
say() { printf '%s\n' "$*" | tee -a "$EVID" >&2; }

REPO="$DSH_HARNESS_ROOT"
RT="$DSH_RUNTIME_DIR"
WORK="$RT/work"
NODE="$RT/node/bin/node"
TMP="$DSH_SANDBOX_ROOT/tmp"
mkdir -p "$TMP" || case_error "无法创建沙箱 tmp: $TMP"
DL="$TMP/legacy-assets"

# 本 case 主张的**具体历史实例**。硬编码是刻意的：实例身份就是被测主体，不许漂。
# 与 run.sh 的 `--release-tag` 实例必须一致（下面显式核对），否则结论绑错对象（ADR-009）。
LEGACY_TAG="pre-dsh-0.1.3-alpha.2-g82a5fd6-1.2.8"
LEGACY_RUNTIME_SHA="d0a4f1e3f212f301c2aa6adb56369ba0d038febab6f638046c11bd06fbb097ac"
LEGACY_DSH_VER="0.1.3-alpha.2"
FLOOR="0.1.5-alpha.1"          # ADR-001 的支持下限（照此措辞：>= 0.1.5-alpha.1）

# --- 0. 前置（先判"这轮能不能得出结论"） --------------------------------------
for t in readelf patchelf sha256sum; do
  command -v "$t" >/dev/null 2>&1 || case_unmet "本 case 需要 $t（glibc 接线与摘要断言）"
done
[ -n "$(ls "$(glibc_prefix)"/lib/ld-linux-*.so.* 2>/dev/null | head -1 || true)" ] \
  || case_unmet "本机没有 glibc loader（$(glibc_prefix)/lib）"

# 实例必须由运行器显式给出，且**等于**本 case 主张的那个 tag。
# 不静默改用运行器的默认（稳定 latest）：那会变成"测了另一个对象还说通过"。
[ -n "${DSH_RELEASE_TAG:-}" ] \
  || case_unmet "本轮没有解析出发布物输入实例——请用 run.sh --release-tag $LEGACY_TAG 运行本 case"
say "== 发布物实例: selector=${DSH_RELEASE_SELECTOR:-?} -> tag=$DSH_RELEASE_TAG"
if [ "$DSH_RELEASE_TAG" != "$LEGACY_TAG" ]; then
  case_unmet "实例不符：本 case 只认证 $LEGACY_TAG（本轮是 $DSH_RELEASE_TAG）；请显式传 --release-tag $LEGACY_TAG"
fi

# 下限断言是**事实核对**，不是本 case 的结论：这条实例必须在窗口之外，否则它测的不是旧路径。
dsh_version_below_floor "$LEGACY_DSH_VER"; below_rc=$?
[ "$below_rc" = 0 ] \
  && assert_pass "该实例的 dsh $LEGACY_DSH_VER 确实低于支持下限 $FLOOR（走 tarball 路径的前提成立）" \
  || case_error "实例 dsh $LEGACY_DSH_VER 不在下限之下（rc=$below_rc）—— 本 case 的前提被破坏"

# --- 1. 取得该实例的资产（当场下载，不 overlay、不复用种子） -------------------
say "== 下载 $LEGACY_TAG 的 runtime 资产"
mkdir -p "$DL" || case_error "无法创建下载目录"
SLUG="$(seed_repo_slug 2>/dev/null || true)"
[ -n "$SLUG" ] || SLUG="ErEbusE/dsh-termux"
ASSET="dsh-termux-runtime.tar.gz"
URL="https://github.com/$SLUG/releases/download/$LEGACY_TAG/$ASSET"
if ! curl -fsSL --retry 2 --max-time 900 -o "$DL/$ASSET" "$URL" >>"$EVID" 2>&1; then
  case_unmet "下载失败（受限网络先 export https_proxy/http_proxy）: $URL"
fi
[ -s "$DL/$ASSET" ] || case_unmet "下载到的资产为空: $DL/$ASSET"
PKG="$DL/$ASSET"
PKG_SHA="$(sha256sum "$PKG" | cut -d' ' -f1)"
say "   sha256=$PKG_SHA"
# 摘要必须与记录的实例一致：这是"测的是那个已发布对象"的硬绑定（ADR-009）。
if [ "$PKG_SHA" = "$LEGACY_RUNTIME_SHA" ]; then
  assert_pass "runtime 资产 sha256 与该实例记录的一致"
else
  assert_fail "runtime 资产 sha256 与记录不符：实得 $PKG_SHA，记录 $LEGACY_RUNTIME_SHA（发布物被替换或下载损坏）"
fi

# --- 2. 解包真机可行性（Android 拒绝 link(2)；这个 release 当年就死在这里） ----
# 这一步与"安装"分开记账：解包失败是**打包**问题，不是安装器问题。
say "== 真机解包检查（Android 拒绝 hard link）"
EX="$TMP/extract-check"
rm -rf "$EX"; mkdir -p "$EX" || case_error "无法创建解包检查目录"
if tar -xzf "$PKG" -C "$EX" >>"$EVID" 2>&1; then
  assert_pass "该 tarball 在本设备（Android/arm64）能完整解包"
else
  assert_fail "该 tarball 在本设备解包失败（Android 拒绝 link(2) 一类；详见证据文件）"
fi
# 用独立方法核对 hard-link 条目：**不能**用 `tar -tzf | grep ' link to '`——不带 -v 的
# 列表只有成员名，那个 grep 永远匹配不到（我曾据此得出过错误结论）。
HL="$(python3 - "$PKG" <<'PY' 2>/dev/null || echo "?"
import sys, tarfile
try:
    with tarfile.open(sys.argv[1]) as t:
        print(sum(1 for m in t if m.islnk()))
except Exception:
    print("?")
PY
)"
say "   hard-link(TarInfo.islnk) 条目数: $HL"
case "$HL" in
  0) assert_pass "tarball 内无 hard-link 条目（与解包结果一致）" ;;
  \?) say "   note: 无法解析 hard-link 计数（不解为已验证）" ;;
  *) assert_fail "tarball 含 $HL 个 hard-link 条目 —— Android 会在解包时拒绝" ;;
esac
[ -x "$EX/node/bin/node" ] && assert_pass "解包后 node 就位" \
  || assert_fail "解包后缺 node（产物不完整）"

# --- 3. 载荷自足性：该产物**自带** helper 集（不是当前那份） -------------------
say "== 载荷自足性（自带 scripts/ 与 patches/）"
for f in scripts/common.sh scripts/update-dsh.sh scripts/patch-lib.sh VERSION install.sh; do
  if [ -f "$EX/$f" ]; then
    assert_pass "旧产物自带 $f"
  else
    assert_fail "旧产物缺 $f —— 安装器要 source 它自带的 common.sh，缺件即无法安装"
  fi
done
# 关键：该产物的 common.sh 必须定义**当前安装器会调用的每一个函数**。
# 这就是"当前安装器 ↔ 历史 helper 接口"这条契约的可证伪点：将来安装器若新增一个
# 旧 helper 没有的函数，这里会红（而不是等到有人在真机上装旧版本才发现）。
say "== 接口兼容性（当前 install.sh 需要的历史 helper）"
NEEDS="ask_yes_no configure_glibc_node write_dsh_wrapper"
OLD_CM="$EX/scripts/common.sh"
if [ -f "$OLD_CM" ]; then
  OLD_CM_SHA="$(sha256sum "$OLD_CM" | cut -d' ' -f1)"
  say "   旧产物 common.sh sha256=$OLD_CM_SHA"
  miss=""
  for fn in $NEEDS; do
    grep -qE "^${fn}[[:space:]]*\(\)" "$OLD_CM" || miss+="$fn "
  done
  if [ -z "$miss" ]; then
    assert_pass "旧产物自带的 common.sh 定义了当前安装器需要的全部函数（$NEEDS）"
  else
    assert_fail "旧产物 common.sh 缺函数: ${miss% } —— 当前的 install.sh 会在真机上失败"
  fi
fi

# --- 4. 安装：**当前工作区** install.sh × 该旧 tarball ------------------------
say "== 安装: bash build/install.sh -y -p <旧 tarball> --prefix <沙箱> --bin <沙箱>"
INST_LOG="$TMP/legacy-install.log"
if ! bash "$REPO/build/install.sh" -y -p "$PKG" \
     --prefix "$RT" --bin "$DSH_BIN_DIR" >"$INST_LOG" 2>&1; then
  say "--- 安装日志 tail 60 ---"
  tail -n 60 "$INST_LOG" | tee -a "$EVID" >&2
  assert_fail "当前 install.sh 无法安装该旧 tarball（详见证据文件）"
  case_finish
fi
{ echo "--- 安装日志（tail 60） ---"; tail -n 60 "$INST_LOG"; } >>"$EVID"
assert_pass "当前 install.sh 退出 0"

# 安装树自报的版本必须等于该实例的 dsh 版本（资格绑定主体）。
PKGJSON="$WORK/node_modules/@deepseek-ai/dsh/package.json"
INST_VER="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$PKGJSON" 2>/dev/null | head -1)"
say "   安装树 dsh 版本: ${INST_VER:-<读不到>}"
[ "$INST_VER" = "$LEGACY_DSH_VER" ] \
  && assert_pass "安装树 dsh 版本 == 该实例记录（$LEGACY_DSH_VER）" \
  || assert_fail "安装树 dsh 版本(${INST_VER:-?}) != 实例记录($LEGACY_DSH_VER) —— 装错对象"
# installed common.sh 必须**逐字**等于产物自带的那份：证明没有 overlay 当前脚本。
if [ -f "$RT/scripts/common.sh" ] && [ -f "$OLD_CM" ]; then
  [ "$(sha256sum "$RT/scripts/common.sh" | cut -d' ' -f1)" = "$OLD_CM_SHA" ] \
    && assert_pass "装出来的 common.sh 与旧产物自带的那份逐字相同（未被当前脚本 overlay）" \
    || assert_fail "装出来的 common.sh 与旧产物自带的**不同** —— 发生了 overlay，被测对象被换掉"
fi

# --- 5. boot 探针（**命名清楚**：这不是"完整 Web/native 启动"） ----------------
say "== boot 探针"
# 5a Node 可直连（安装器的接线是否正确）
LOADER_BASE="$(basename "$(ls "$(glibc_prefix)"/lib/ld-linux-*.so.* 2>/dev/null | head -1)")"
if readelf -l "$NODE" 2>/dev/null | grep -q "$LOADER_BASE"; then
  assert_pass "装出来的 node 解释器 == glibc loader（$LOADER_BASE，接线正确）"
else
  assert_fail "装出来的 node 解释器不是 glibc loader（期望 $LOADER_BASE，接线失败）"
fi
# 5b CLI 版本探针（**只证明 CLI 可执行**，不证明 loader/Web 可用）
DSH_BIN="$WORK/node_modules/@deepseek-ai/dsh/lib/bin.js"
if [ -f "$DSH_BIN" ]; then
  out="$(run_glibc_node "$NODE" "$DSH_BIN" --version 2>&1)"; rc=$?
  say "   CLI --version: exit=$rc out=${out//$'\n'/ | }"
  [ "$rc" = 0 ] && assert_pass "CLI 探针: dsh --version 成功（仅证明 CLI 可执行）" \
    || assert_fail "CLI 探针: dsh --version 失败 (exit $rc): $out"
  case "$out" in
    *"$LEGACY_DSH_VER"*) assert_pass "CLI 探针: 报出的版本含 $LEGACY_DSH_VER" ;;
    *) assert_fail "CLI 探针: 报出的版本不含 $LEGACY_DSH_VER: $out" ;;
  esac
else
  assert_fail "安装树缺 dsh CLI 入口: $DSH_BIN"
fi
# 5c wrapper / symlink 真的能执行（安装器的外壳接线）
WRAP="$WORK/dsh"
if [ -x "$WRAP" ]; then
  assert_pass "wrapper 就位且可执行"
  wrap_out="$(PATH="$DSH_BIN_DIR:$PATH" "$WRAP" --version 2>&1)"; wrc=$?
  say "   wrapper --version: exit=$wrc"
  [ "$wrc" = 0 ] && assert_pass "wrapper 真的能执行" \
    || assert_fail "wrapper 执行失败 (exit $wrc): $wrap_out"
else
  assert_fail "wrapper 缺失或不可执行: $WRAP"
fi
[ -L "$DSH_BIN_DIR/dsh" ] && assert_pass "bin 里的 dsh 是 symlink" \
  || assert_fail "symlink 缺失: $DSH_BIN_DIR/dsh"
"$DSH_BIN_DIR/dsh" --version >/dev/null 2>&1 \
  && assert_pass "经 symlink 调用的 dsh 能跑" \
  || assert_fail "经 symlink 调用的 dsh 不能跑"
# 5d **真正加载旧原生件**（这是本 case 唯一与"原生年代"有关的可证伪点）。
# 该产物带已编译的 fs-ext（0.1.3 的 session-persistence 依赖它）；`require` 成功
# 证明这份历史载荷的原生位**可加载**。它**不**证明 flock 语义正确（见 case-facts 的范围限定）。
FS_EXT="$WORK/node_modules/fs-ext"
if [ -d "$FS_EXT" ]; then
  # require 的解析根必须是**安装树**（cd 进 $WORK），否则 node 会去别处找或直接报
  # MODULE_NOT_FOUND —— 那是探针自己的错，不是产物的问题。
  req_out="$(cd "$WORK" && run_glibc_node "$NODE" -e 'const m=require("fs-ext"); if(typeof m.flock!=="function"){console.error("flock missing");process.exit(2)}; console.log("fs-ext-loadable")' 2>&1)"; req_rc=$?
  say "   fs-ext require: exit=$req_rc out=${req_out//$'\n'/ | }"
  if [ "$req_rc" = 0 ]; then
    assert_pass "旧产物携带的 fs-ext 原生件可被加载（require 成功且导出 flock）"
  else
    assert_fail "旧产物的 fs-ext 原生件加载失败 (exit $req_rc): $req_out"
  fi
else
  say "   note: 该产物树里没有 fs-ext 目录（不计为已验证）"
fi

# --- 6. 耐久证据 --------------------------------------------------------------
# 范围限定：把"没有主张"的东西写进事实，别让报告读起来更强。
FACTS="release_instance=$LEGACY_TAG selector=${DSH_RELEASE_SELECTOR:-?}"
FACTS+=" runtime_sha=$PKG_SHA expected_runtime_sha=$LEGACY_RUNTIME_SHA"
FACTS+=" installer=workspace build/install.sh installer_sha=$(sha256sum "$REPO/build/install.sh" | cut -d' ' -f1)"
FACTS+=" legacy_dsh=$LEGACY_DSH_VER floor=$FLOOR below_floor=yes hardlinks=$HL"
FACTS+=" old_common_sha=${OLD_CM_SHA:-?} installed_common_sha=$(sha256sum "$RT/scripts/common.sh" 2>/dev/null | cut -d' ' -f1 || echo '?')"
FACTS+=" probes=cli,wrapper,symlink,fs-ext-load"
FACTS+=" scope=current-installer-x-historical-helper-abi;native-retirement-NOT-causally-tested"
FACTS+=" excluded=npm-path,below-floor-npm,--self,machinery-refresh,upgrades,all-historical-versions"
FACTS+=" native_load=require-only(flock-semantics-not-proven)"
say "== 事实: $FACTS"
receipt_case_facts "$DSH_RUN_ID" "$DSH_CASE_ID" "$FACTS" \
  || case_error "必要证据（case-facts）写不进去 —— 本次结论不成立"

case_finish
