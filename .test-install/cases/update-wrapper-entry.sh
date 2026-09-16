#!/usr/bin/env bash
# update/wrapper-entry — 契约: `dsh update` 这个 **wrapper 快捷方式**把 argv
# 端到端转发给更新器（新写的 case；旧六条路线没有对应断言，映射表 A.5 的 R4.8 只
# 验"钩子在不在"，不验"转发对不对"）。
#
# 为什么单独一条: wrapper 是 `$1 == "update"` 的**字符串匹配**加一句
# `exec bash "$updater" "$@"`（scripts/common.sh 的 write_dsh_wrapper）。这段代码
# 一改，用户敲的 `dsh update -t next -y` 就可能：
#   * 变成把参数交给真正的 dsh（于是报 "--profile <name> is required"），
#   * 或把带空格的路径拆开（旧 grun 就因为 `$@` 未加引号干过这件事），
#   * 或在没有更新器时给出与更新器无关的报错。
# 三种都在这条 case 里被断言，而且**只有在 wrapper 真的把 argv 交给了更新器**时
# 才可能通过（比的是同一 argv 下"直接调更新器"与"经 `dsh update`"的输出）。
#
# 被测对象是**工作区**的两份文件（scripts/common.sh 的生成器 + scripts/update-dsh.sh
# 的 argv 解析，正是 registry 的 changes 里那两个 glob）。种子 runtime 提供一棵真树
# 与真 node，但机件先被换成工作区那一份——否则"改了生成器"会被 diff 选中却什么都没测。

set -uo pipefail

. "$DSH_TI_DIR/lib/state.sh"
. "$DSH_TI_DIR/lib/receipt.sh"
. "$DSH_TI_DIR/lib/seed.sh"
. "$DSH_TI_DIR/lib/patchset.sh"
. "$DSH_HARNESS_ROOT/scripts/common.sh"

case_begin

EVID="$(dirname "$DSH_RESULTS")/evidence-${DSH_CASE_ID//\//-}.txt"
mkdir -p "$(dirname "$EVID")" || case_error "无法创建证据目录 $(dirname "$EVID")"
: > "$EVID" || case_error "无法写证据文件 $EVID"
say() { printf '%s\n' "$*" | tee -a "$EVID" >&2; }

REPO="$DSH_HARNESS_ROOT"
WORK="$DSH_WORK_DIR"
RT="$DSH_RUNTIME_DIR"
NODE="$RT/node/bin/node"
WRAP="$WORK/dsh"
DSH_BIN="$WORK/node_modules/@deepseek-ai/dsh/lib/bin.js"
RT_UPDATER="$RT/scripts/update-dsh.sh"
TMP="$DSH_SANDBOX_ROOT/tmp"
mkdir -p "$TMP" || case_error "无法创建沙箱 tmp: $TMP"   # Termux 禁访系统 /tmp

# --- 0. 前置 ------------------------------------------------------------------
command -v patchelf >/dev/null 2>&1 \
  || case_unmet "配置种子 node 需要 patchelf（glibc-runner；registry 未声明 host:glibc）"
[ -n "$(ls "$(glibc_prefix)"/lib/ld-linux-*.so.* 2>/dev/null | head -1 || true)" ] \
  || case_unmet "本机没有 glibc loader（$(glibc_prefix)/lib）"
seed_name="$(seed_default_name)"
seed_msg="$(state_check_require "seed:$seed_name")"; seed_chk=$?
case "$seed_chk" in
  0) ;;
  1) case_unmet "$seed_msg（本 case 需要一棵真 runtime 才能走 wrapper 的真实路径）" ;;
  *) case_error "seed:$seed_name 前置判定配置错误: $seed_msg" ;;
esac

seed_load_require "$seed_name"
TARBALL="$(seed_asset_by_name dsh-termux-runtime.tar.gz)" \
  || case_error "种子事实源没有 dsh-termux-runtime.tar.gz（发布约定缺件）"
say "== 种子 $SEED_TAG（dsh $SEED_DSH_VERSION）"

if ! tar -xzf "$TARBALL" -C "$RT" >>"$EVID" 2>&1; then
  assert_fail "种子 tarball 解包失败（详见证据文件）"
  case_finish
fi
[ -x "$NODE" ] && assert_pass "种子 node 就位" \
  || { assert_fail "种子 node 缺失: $NODE"; case_finish; }
[ -f "$DSH_BIN" ] && assert_pass "已装 dsh 的 CLI 入口在位" \
  || { assert_fail "种子缺 dsh CLI: $DSH_BIN"; case_finish; }

# --- 1. 把 runtime 的机件换成**工作区**版本 -----------------------------------
# 快捷方式指的就是 runtime 内置的更新器（Option A 优先级）；把工作区那三份脚本装
# 进去，`dsh update` 才会跑到**本分支**的 argv 解析上。这与 r6 Part H 的做法同源。
mkdir -p "$RT/scripts/patches"
cp "$REPO/scripts/update-dsh.sh" "$REPO/scripts/common.sh" "$REPO/scripts/patch-lib.sh" "$RT/scripts/" \
  || case_error "无法把工作区机件装进 runtime"
cp "$REPO"/patches/*.patch "$RT/patches/" 2>/dev/null || true
[ -f "$RT_UPDATER" ] && assert_pass "runtime 内置更新器 = 工作区版本（被测对象）" \
  || { assert_fail "机件安装失败: $RT_UPDATER"; case_finish; }

# --- 2. 用工作区生成器写出 wrapper + 沙箱 bin 的 symlink ----------------------
# write_dsh_wrapper 是**被测代码**（scripts/common.sh），所以这里调它而不是用种子里
# 那份现成的 wrapper；opener 会被它一并写到 wrapper 旁边（安装布局如此）。
write_dsh_wrapper "$WRAP" "$NODE" "$DSH_BIN" "$RT_UPDATER" \
  || case_error "write_dsh_wrapper 生成失败"
[ -x "$WRAP" ] && assert_pass "wrapper 由工作区生成器写出" \
  || { assert_fail "wrapper 未生成或不可执行: $WRAP"; case_finish; }
mkdir -p "$DSH_BIN_DIR"
ln -sf "$WRAP" "$DSH_BIN_DIR/dsh" || case_error "无法建 symlink: $DSH_BIN_DIR/dsh"
[ -L "$DSH_BIN_DIR/dsh" ] && assert_pass "沙箱 bin 里的 dsh 指向 wrapper" \
  || assert_fail "symlink 缺失: $DSH_BIN_DIR/dsh"

# 生成器能力（从被测生成器派生，不写死）：4 参调用才该带 update 钩子。
EXPECT="$(wrapper_hook_expected "$REPO/scripts/common.sh")"
if patchset_wrapper_hook_check "$WRAP" "$EXPECT"; then
  assert_pass "4 参 wrapper 的 update 钩子符合生成器能力（期望 $EXPECT）"
else
  assert_fail "wrapper 的 update 钩子与生成器能力不符"
fi

# node 解释器必须可用，后面"没被拦截"那一条要真的启动 dsh。
configure_glibc_node "$NODE" >>"$EVID" 2>&1 \
  || { assert_fail "无法把种子 node 配成 glibc 直连（后续断言要真启动 dsh）"; case_finish; }

# --- 3. 核心：同一 argv 下，`dsh update ...` 与直接调更新器逐字相同 -----------
# 输出含 stderr（更新器的 help/错误都走 stderr），所以 2>&1。比较的是整体字符串：
# 只要 wrapper 少传/错排/重新分词了参数，两者就不可能相同。
run_forward_case() { # $1=标签 $2..=argv
  local label="$1"; shift
  local direct direct_rc via via_rc
  direct="$(bash "$RT_UPDATER" "$@" 2>&1)"; direct_rc=$?
  via="$(PATH="$DSH_BIN_DIR:$PATH" "$DSH_BIN_DIR/dsh" update "$@" 2>&1)"; via_rc=$?
  printf '== [%s] argv: %s\n' "$label" "$*" >>"$EVID"
  printf -- '--- 直接调用（exit %s） ---\n%s\n' "$direct_rc" "$direct" >>"$EVID"
  printf -- '--- dsh update（exit %s） ---\n%s\n' "$via_rc" "$via" >>"$EVID"
  [ "$via_rc" = "$direct_rc" ] \
    && assert_pass "$label: 退出码经 wrapper 转发后一致 ($via_rc)" \
    || assert_fail "$label: 退出码不一致（直接 $direct_rc，经 wrapper $via_rc）"
  if [ "$via" = "$direct" ]; then
    assert_pass "$label: 输出逐字相同 —— argv 端到端转发"
  else
    assert_fail "$label: 输出不同 —— argv 未被忠实转发（详见证据文件）"
  fi
}

# 3a. -h：最干净的"到底跑的是谁"探针（更新器的 help 块）。
run_forward_case "help" -h
# 3b. 更新器自己的未知选项报错：证明 $2 之后的 argv 也进了更新器的解析器，
#     而不是被 wrapper 吃掉或交给 dsh。（usage() 对未知选项也退 0，故断言的是
#     输出与退出码两者都一致。）
run_forward_case "unknown-option" --definitely-not-a-flag
# 3c. 带空格的路径：旧 grun 就因为 `$@` 未加引号把 `dsh "two words"` 拆成两个
#     argv。--patch-set 指向不存在的目录会在**碰 node/npm 之前**响亮失败，正好
#     可以在完全不联网的前提下验证参数边界。
SPACED="$TMP/dir with spaces"
run_forward_case "spaced-argv" --patch-set "$SPACED"
grep -qF "$SPACED" "$EVID" \
  && assert_pass "带空格的参数原样抵达更新器（未被分词）" \
  || assert_fail "带空格的参数没有原样抵达更新器"

# --- 4. 没被当成 update 的调用要落到真 dsh -----------------------------------
# 只匹配 $1 == "update"：`dsh --version` 必须停在 wrapper 的 exec 行上、报出装着的
# dsh 版本，而不是更新器的 help。
INST_VER="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
  "$WORK/node_modules/@deepseek-ai/dsh/package.json" | head -1)"
[ -n "$INST_VER" ] || case_error "无法读取已装 dsh 版本（package.json）"
VER_OUT="$(PATH="$DSH_BIN_DIR:$PATH" "$DSH_BIN_DIR/dsh" --version 2>&1)"; ver_rc=$?
say "   dsh --version (exit=$ver_rc): ${VER_OUT//$'\n'/ | }"
[ "$ver_rc" = 0 ] && assert_pass "非 update 的调用仍落到真 dsh（exit 0）" \
  || assert_fail "非 update 的调用退出非零 ($ver_rc)"
case "$VER_OUT" in
  *"$INST_VER"*) assert_pass "dsh --version 报出已装版本（$INST_VER）" ;;
  *) assert_fail "dsh --version 未报出 $INST_VER: $VER_OUT" ;;
esac
UPDATER_HELP="$(bash "$RT_UPDATER" -h 2>&1)"
case "$VER_OUT" in
  *"$UPDATER_HELP"*) assert_fail "非 update 的调用被更新器截走了（输出了更新器 help）" ;;
  *) assert_pass "非 update 的调用没有落到更新器" ;;
esac

# --- 5. 缺更新器时的错误路径（生成器不该产出一个"哑"快捷方式） ---------------
# 生成器把更新器路径写在 wrapper 文本里；文件不在时必须给出**指名道姓**的报错并
# 退 127，而不是把参数交给 dsh（那会变成 "--profile <name> is required" 这种与
# 更新毫不相干的错误）。
MISS_DIR="$TMP/wrapper-missing"
mkdir -p "$MISS_DIR"
MISS_WRAP="$MISS_DIR/dsh"
write_dsh_wrapper "$MISS_WRAP" "$NODE" "$DSH_BIN" "$MISS_DIR/no-such-updater.sh" \
  || case_error "write_dsh_wrapper（缺更新器）生成失败"
MISS_OUT="$("$MISS_WRAP" update -h 2>&1)"; miss_rc=$?
say "   缺更新器: exit=$miss_rc out=${MISS_OUT//$'\n'/ | }"
[ "$miss_rc" = 127 ] && assert_pass "缺更新器时退出码 127" \
  || assert_fail "缺更新器时退出码应为 127，实得 $miss_rc"
grep -qF "$MISS_DIR/no-such-updater.sh" <<<"$MISS_OUT" \
  && assert_pass "缺更新器时报错指名了缺失路径" \
  || assert_fail "缺更新器时的报错没有指名路径: $MISS_OUT"

# --- 6. 没有更新器参数时不产生钩子（生成器的契约） ---------------------------
# 三参调用（CI 的 install.sh 委派守卫也查这一形态）不该带 update 分支——否则会把
# 一个并不存在的更新器暴露给用户。
W3="$MISS_DIR/dsh-no-updater"
write_dsh_wrapper "$W3" "$NODE" "$DSH_BIN" || case_error "write_dsh_wrapper（三参）生成失败"
if patchset_wrapper_hook_check "$W3" 0; then
  assert_pass "三参调用不产生 update 钩子（无更新器就没有快捷方式）"
else
  assert_fail "三参调用也产生了 update 钩子"
fi

# --- 7. 耐久证据 -------------------------------------------------------------
FACTS="seed=$SEED_TAG seed_dsh=$SEED_DSH_VERSION installed_dsh=$INST_VER"
FACTS+=" generator_expect=$EXPECT hook_ok=checked forwarded=help,unknown-option,spaced"
FACTS+=" dsh_fallthrough=$ver_rc missing_updater_exit=$miss_rc"
say "== 事实: $FACTS"
receipt_case_facts "$DSH_RUN_ID" "$DSH_CASE_ID" "$FACTS" \
  || case_error "必要证据（case-facts）写不进去 —— 本次结论不成立"

case_finish
