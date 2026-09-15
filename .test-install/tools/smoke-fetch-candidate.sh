#!/data/data/com.termux/files/usr/bin/bash
# smoke-fetch-candidate.sh — `fetch-candidate.sh` 的核验逻辑回归冒烟。
#
# 为什么要有它: 那个工具存在的唯一理由是**在信任一份产物之前机械地证伪**——
# run 是否成功、产物是否来自被测提交、下载字节是否等于报告 digest、解包后是否
# 与 checksums.txt 逐条相符。这些判断全是纯逻辑，却决定"真机测的到底是哪份代码"；
# 而它们**没法**靠真跑覆盖（真跑只会走成功路径，也没法让服务器返回一个坏 digest）。
# 所以这里用一个**假 gh**在本地自造全部场景，包括每一个应当**拒绝**的场景。
#
# 覆盖（每条都对应一个真实的失效模式）:
#   1. 成功路径: 两个 artifact、digest 相符、checksums 相符 -> exit 0，
#      并打印可用的 DSH_CANDIDATE_ARTIFACT
#   2. run 的 conclusion 不是 success（cancelled）-> 拒绝，即使产物完整
#   3. run 的 head_sha 与期望提交不符 -> 拒绝（测的不是那个提交）
#   4. 缺 evidence artifact（没有 checksums 可对）-> 拒绝
#   5. 解出的文件 sha256 与 checksums.txt 不符 -> 拒绝
#   6. artifact 标记为 expired -> 拒绝
#   7. 下载字节与 REST digest 不符 -> 拒绝
#   8. run id 非数字 / 缺参数 / 未知开关 -> 用法错误 exit 2
#   9. --list-only 不下载任何东西
#
# 用法: bash .test-install/tools/smoke-fetch-candidate.sh

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SMOKE="$REPO/.test-install/state/smoke/fetch-candidate"
FAKEBIN="$SMOKE/bin"
SCEN="$SMOKE/scenario"
OUTROOT="$SMOKE/out"
FAILED=0

ok()  { echo "  ok: $*"; }
bad() { echo "  FAIL: $*" >&2; FAILED=$((FAILED + 1)); }
check() { # $1=描述 $2=期望 $3=实际
  if [ "$2" = "$3" ]; then ok "$1 ($3)"; else bad "$1: 期望 $2, 实得 $3"; fi
}
contains() { # $1=描述 $2=子串 $3=文本
  case "$3" in *"$2"*) ok "$1" ;; *) bad "$1: 输出里找不到「$2」"; printf '%s\n' "$3" | head -5 >&2 ;; esac
}

TOOL="$REPO/.test-install/tools/fetch-candidate.sh"
EXPECT_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

rm -rf "$SMOKE"
mkdir -p "$FAKEBIN" "$SCEN" "$OUTROOT"

# --- 假 gh: 只实现本工具用到的三个调用，数据全从场景目录读 -------------------
# shebang **现算**: 内核解析 `#!` 后那一段时用的是**字面绝对路径**，既不走 PATH，
# 也**不做变量展开**（写 `#!$PREFIX/bin/env bash` 同样失败）。设备上 `env` 是有的
# （`$PREFIX/bin/env`），但**路径 `/usr/bin/env` 不存在**，所以 `#!/usr/bin/env bash`
# 一旦被**直接 exec** 就会失败——实测是 126（`bad interpreter: No such file or directory`；
# 同一失败若是经 `timeout` 等包装方调用，外层看到的可能是 127，**别把某个数字当契约**）。
# 写死 Termux 路径又会在 CI 的 ubuntu runner 上失效。取当前 bash 的真实路径即可两边都跑。
#
# 注意这**不是**"仓库里其他脚本的写法有问题"：那 22 个 `#!/usr/bin/env bash`
# （＝16 个 cases ＋ `lib/{patchset,probes}.sh` ＋ `scripts/patch-lib.sh` ＋
# `.github/scripts/` 的三个）**从不被直接 exec**：
#   * cases 由 run.sh 经 sandbox_exec 跑，显式 `"$bash_bin" "$1"`（lib/sandbox.sh:280-283）；
#   * 两个 lib 与 patch-lib.sh 只被 `.` / `source` 引入；
#   * `.github/scripts/` 那三个在两处都是 `bash <file>` 调用——**注意它们并非"只在 CI"**：
#     `patch-matrix.sh` 明确支持 Termux（临时树落仓库内，因 Termux 禁访 `/tmp`），
#     `package-runtime.sh` 的 stage/verify 也在设备上真跑过（见 STATUS「本地证据」）。
# **会被内核直接执行的生成物都已经用绝对路径**——`dsh` wrapper 与 `$BROWSER` opener
# （scripts/common.sh:208/283），以及沙箱里的 `grun`（lib/sandbox.sh:67-69，且被放进
# PATH **首位**）。假 gh 是这里唯一靠 PATH 直接执行的临时脚本，所以它是第一个撞上的
# ——这正是"只在直接 exec 时才现形"的那类问题。
BASH_BIN="$(command -v bash)" || { echo "找不到 bash" >&2; exit 2; }
{
printf '#!%s\n' "$BASH_BIN"
cat <<'FAKEGH'
# 假 gh。场景目录由 FAKE_SCEN 指定。
set -uo pipefail
S="${FAKE_SCEN:?FAKE_SCEN 未设置}"
# 调用形态: gh api <path>        （--jq 等一律不支持，工具也不用）
[ "${1:-}" = "api" ] || { echo "fake-gh: 只支持 api，实得: $*" >&2; exit 64; }
path="${2:?fake-gh: 缺 path}"

case "$path" in
  */actions/runs/*/artifacts)  cat "$S/artifacts.json" ;;
  */actions/artifacts/*/zip)
    aid="${path##*/actions/artifacts/}"; aid="${aid%%/*}"
    # 场景可指定"下载时返回一份**不同**的字节"来验 digest 校验
    f="$S/zip-$aid.bin"
    [ -f "$f" ] || { echo "fake-gh: 没有 $f" >&2; exit 1; }
    cat "$f" ;;
  */actions/runs/*)
    rid="${path##*/actions/runs/}"
    [ -f "$S/run-$rid.json" ] || { echo "fake-gh: 没有 run $rid" >&2; exit 22; }
    cat "$S/run-$rid.json" ;;
  *) echo "fake-gh: 未实现的 path: $path" >&2; exit 64 ;;
esac
FAKEGH
} > "$FAKEBIN/gh"
chmod +x "$FAKEBIN/gh"

# 造一份"三件套 zip + checksums"的场景。参数: <名字> <sha 是否一致: ok|mismatch>
#                                <run 结论> <run head_sha> <是否带 evidence: yes|no>
#                                <expired> <下载字节是否被篡改: ok|tamper> <version 布局单层|双层>
make_scenario() {
  local name="$1" csum="$2" concl="$3" headsha="$4" withev="$5" expired="$6" tamper="$7" nest="$8"
  local d="$SCEN/$name"; rm -rf "$d"; mkdir -p "$d"
  local files="$d/files"; mkdir -p "$files"
  printf '1.3.0\n' > "$files/VERSION"
  printf '#!/bin/sh\necho installer\n' > "$files/install.sh"
  # 一个"runtime tarball"：内容任意，只要能算哈希
  printf 'fake runtime payload %s\n' "$name" > "$files/dsh-termux-runtime.tar.gz"

  # checksums.txt：可按需写成"不符"
  {
    for f in dsh-termux-runtime.tar.gz install.sh VERSION; do
      if [ "$csum" = mismatch ] && [ "$f" = install.sh ]; then
        echo "$(printf 'deadbeef')0000000000000000000000000000000000000000000000000000000000  $f"
      else
        sha256sum "$files/$f" | sed "s|$files/||"
      fi
    done
  } > "$d/checksums.txt"

  # zip 布局：单层（三件套在根）或双层（套一层 artifact 名目录）
  local zipprefix=""
  [ "$nest" = nested ] && zipprefix="dsh-termux-candidate-$name/"
  python3 - "$d" "$files" "$zipprefix" <<'PY'
import os, sys, zipfile
d, files, prefix = sys.argv[1], sys.argv[2], sys.argv[3]
with zipfile.ZipFile(os.path.join(d, 'primary.zip'), 'w') as z:
    for f in sorted(os.listdir(files)):
        z.write(os.path.join(files, f), prefix + f)
PY
  printf '%s\n' "$(cat "$d/checksums.txt")" > "$d/checksums_only.txt"
  ( cd "$d" && python3 - <<'PY'
import zipfile
with zipfile.ZipFile('evidence.zip','w') as z:
    z.write('checksums.txt')
PY
  )

  local psha esha pdid edid
  psha="$(sha256sum "$d/primary.zip" | cut -d' ' -f1)"
  esha="$(sha256sum "$d/evidence.zip" | cut -d' ' -f1)"
  pdid=1001; edid=1002
  cp "$d/primary.zip"  "$d/zip-$pdid.bin"
  cp "$d/evidence.zip" "$d/zip-$edid.bin"
  if [ "$tamper" = tamper ]; then
    # 下载返回**不同**字节：digest 必须抓住
    printf 'tampered!\n' > "$d/zip-$pdid.bin"
  fi

  printf '{"id":%s,"event":"pull_request","conclusion":"%s","head_sha":"%s","head_branch":"b"}\n' \
    4242 "$concl" "$headsha" > "$d/run-4242.json"

  # artifacts.json
  local arts="["
  arts="$arts{\"id\":$pdid,\"name\":\"dsh-termux-candidate-$name\",\"expired\":$([ "$expired" = yes ] && echo true || echo false),\"digest\":\"sha256:$psha\"}"
  if [ "$withev" = yes ]; then
    arts="$arts,{\"id\":$edid,\"name\":\"dsh-termux-candidate-evidence-$name\",\"expired\":false,\"digest\":\"sha256:$esha\"}"
  fi
  arts="$arts]"
  printf '{"artifacts":%s}\n' "$arts" > "$d/artifacts.json"
}

run_tool() { # $1=scenario name, 其余=额外参数 -> stdout+stderr 进 $OUT，rc 进 $RC
  local s="$1"; shift
  OUT="$(FAKE_SCEN="$SCEN/$s" PATH="$FAKEBIN:$PATH" DSH_GITHUB_REPO="o/r" \
    bash "$TOOL" "$@" 2>&1)"; RC=$?
}

echo "== 1. 成功路径"
make_scenario good ok success "$EXPECT_SHA" yes no ok single
run_tool good 4242 --expect-sha "$EXPECT_SHA" --out "$OUTROOT/good"
check "rc" 0 "$RC"
contains "报告绑定成功" "候选产物已绑定并核验" "$OUT"
contains "给出 DSH_CANDIDATE_ARTIFACT" "DSH_CANDIDATE_ARTIFACT=" "$OUT"
[ -f "$OUTROOT/good/artifact/VERSION" ] && ok "产物已解出到 --out" || bad "产物没解到 --out"

echo "== 2. run 被取消（产物完整也不收）"
make_scenario cancelled ok cancelled "$EXPECT_SHA" yes no ok single
run_tool cancelled 4242 --expect-sha "$EXPECT_SHA" --out "$OUTROOT/cancelled"
check "rc" 1 "$RC"
contains "点名 conclusion" "不是 success" "$OUT"

echo "== 3. 产物来自别的提交"
make_scenario wrongsha ok success "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" yes no ok single
run_tool wrongsha 4242 --expect-sha "$EXPECT_SHA" --out "$OUTROOT/wrongsha"
check "rc" 1 "$RC"
contains "报来源不符" "产物来源不符" "$OUT"

echo "== 4. 缺 evidence artifact"
make_scenario noev ok success "$EXPECT_SHA" no no ok single
run_tool noev 4242 --expect-sha "$EXPECT_SHA" --out "$OUTROOT/noev"
check "rc" 1 "$RC"
contains "要的是缺证据" "没有 evidence artifact" "$OUT"

echo "== 5. checksums.txt 与实际文件不符"
make_scenario badsum mismatch success "$EXPECT_SHA" yes no ok single
run_tool badsum 4242 --expect-sha "$EXPECT_SHA" --out "$OUTROOT/badsum"
check "rc" 1 "$RC"
contains "报哈希不符" "sha256 与 evidence 记录不符" "$OUT"

echo "== 6. artifact 已过期"
make_scenario expired ok success "$EXPECT_SHA" yes yes ok single
run_tool expired 4242 --expect-sha "$EXPECT_SHA" --out "$OUTROOT/expired"
check "rc" 1 "$RC"
contains "报过期" "已过期" "$OUT"

echo "== 7. 下载字节与 REST digest 不符"
make_scenario tampered ok success "$EXPECT_SHA" yes no tamper single
run_tool tampered 4242 --expect-sha "$EXPECT_SHA" --out "$OUTROOT/tampered"
check "rc" 1 "$RC"
contains "报 digest 不符" "与 REST digest 不符" "$OUT"

echo "== 8. 用法错误"
run_tool good notanumber
check "非数字 run id" 2 "$RC"
run_tool good
check "缺 run id" 2 "$RC"
run_tool good 4242 --bogus
check "未知开关" 2 "$RC"
run_tool good 4242 --expect-sha "$EXPECT_SHA" --expect-sha-from HEAD
check "两个 expect 互斥" 2 "$RC"

echo "== 9. --list-only 不下载"
make_scenario listonly ok success "$EXPECT_SHA" yes no ok single
run_tool listonly 4242 --expect-sha "$EXPECT_SHA" --list-only
check "rc" 0 "$RC"
contains "打印 primary digest" "primary_digest=sha256:" "$OUT"
[ ! -d "$OUTROOT/listonly" ] && ok "没有产生下载目录" || bad "--list-only 竟然下载了"

echo "== 10. 双层 zip 布局（gh run download 的形态）也能找到三件套"
make_scenario nested ok success "$EXPECT_SHA" yes no ok nested
run_tool nested 4242 --expect-sha "$EXPECT_SHA" --out "$OUTROOT/nested"
check "rc" 0 "$RC"
contains "报告绑定成功" "候选产物已绑定并核验" "$OUT"

echo
if [ "$FAILED" = 0 ]; then
  echo "== smoke-fetch-candidate: 全部通过 =="
  exit 0
fi
echo "== smoke-fetch-candidate: $FAILED 项失败 ==" >&2
exit 1
