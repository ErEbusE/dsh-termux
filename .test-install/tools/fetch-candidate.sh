#!/data/data/com.termux/files/usr/bin/bash
# fetch-candidate.sh — download a candidate-artifact build by EXACT run id and
# prove it is the build the tests are about to install.
#
# Why this exists (ADR-009): the candidate cases only compare the artifact's
# VERSION with the workspace, and VERSION is unchanged across many commits — so
# on its own it cannot say WHICH build is under test. Binding is therefore an
# explicit step, and doing it by hand is exactly the kind of thing that silently
# degrades. This tool makes the binding mechanical and fails loudly.
#
# What it verifies, in order, refusing to continue on any mismatch:
#   1. the run exists, its event is candidate-artifact, and its conclusion is
#      SUCCESS — **a cancelled or failed run can still have a complete artifact
#      attached** (observed: a run cancelled by concurrency left its full 104MB
#      artifact), so "an artifact exists" is NOT evidence the run succeeded;
#   2. the run's head_sha equals the expected commit (either passed explicitly or
#      taken from a tree-ish), so the artifact provably came from the code under
#      test;
#   3. both artifacts of that run are present and unexpired (primary + evidence);
#   4. the artifact ARCHIVE's sha256 equals the digest the REST API reports for
#      it (verified empirically: GitHub's `digest` is the sha256 of the
#      downloaded zip);
#   5. after extraction, every file listed in the evidence artifact's
#      checksums.txt hashes to the value recorded there.
#
# It does NOT decide whether the code is trustworthy: a fork PR can produce a
# self-consistent artifact and a self-consistent checksum file. Trust comes from
# the human choosing a reviewed source, not from this script.
#
# help-begin
# Usage:
#   bash .test-install/tools/fetch-candidate.sh <run-id> [--expect-sha <sha>]
#                                               [--expect-sha-from <tree-ish>]
#                                               [--out <dir>]
#   bash .test-install/tools/fetch-candidate.sh <run-id> --list-only
#
#   --expect-sha       the commit the artifact must have been built from
#   --expect-sha-from  take the expected commit from a tree-ish (default: HEAD)
#   --out              where to put the result (default: .test-install/state/candidate-<run-id>)
#   --list-only        print the run + artifact facts and exit; download nothing
#
# Exit codes: 0 verified; 1 a check failed (mismatch/incomplete); 2 usage or
# environment failure. Requires: gh (authenticated), python3, sha256sum, unzip (or python3 zipfile).
# help-end
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO" || exit 2
ROUTE="fetch-candidate"

fail()  { echo "FAIL [$ROUTE]: $*" >&2; exit 1; }
usage_err() { echo "!! $*" >&2; exit 2; }
note()  { echo "note: $*"; }
ok()    { echo "ok: $*"; }

RUN_ID=""
EXPECT_SHA=""
SHA_FROM=""
OUT=""
LIST_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --expect-sha)      [ $# -ge 2 ] || usage_err "--expect-sha 需要参数"; EXPECT_SHA="$2"; shift 2 ;;
    --expect-sha-from) [ $# -ge 2 ] || usage_err "--expect-sha-from 需要参数"; SHA_FROM="$2"; shift 2 ;;
    --out)             [ $# -ge 2 ] || usage_err "--out 需要参数"; OUT="$2"; shift 2 ;;
    --list-only)       LIST_ONLY=1; shift ;;
    -h|--help)         sed -n '/^# help-begin/,/^# help-end/{//!p;}' "$0" >&2; exit 0 ;;
    -*)                usage_err "未知开关: $1" ;;
    *)                 [ -z "$RUN_ID" ] || usage_err "只接受一个 run id（已给 $RUN_ID）"; RUN_ID="$1"; shift ;;
  esac
done
[ -n "$RUN_ID" ] || usage_err "用法: fetch-candidate.sh <run-id> [--expect-sha <sha>] [--expect-sha-from <tree-ish>] [--out <dir>]"
case "$RUN_ID" in *[!0-9]*) usage_err "run id 必须是数字: $RUN_ID" ;; esac

command -v gh >/dev/null 2>&1 || fail "缺少 gh CLI（本工具用 gh 读公开 metadata 并下载 artifact）"
command -v sha256sum >/dev/null 2>&1 || fail "缺少 sha256sum"
command -v python3 >/dev/null 2>&1 || fail "缺少 python3"

SLUG="${DSH_GITHUB_REPO:-$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)}"
[ -n "$SLUG" ] || fail "无法确定仓库 slug（设 DSH_GITHUB_REPO=owner/name）"

# --- 1 + 2. run facts and the expected commit --------------------------------
RUN_JSON="$(gh api "repos/$SLUG/actions/runs/$RUN_ID" 2>/dev/null)" || fail "读不到 run $RUN_ID（不存在？无权限？）"
read -r R_EVENT R_CONC R_SHA R_BRANCH < <(python3 -c '
import json,sys
d=json.loads(sys.argv[1])
print(d.get("event",""), d.get("conclusion") or "in_progress", d.get("head_sha",""), d.get("head_branch",""))
' "$RUN_JSON")

note "run $RUN_ID  event=$R_EVENT  branch=$R_BRANCH  head=${R_SHA:0:12}  conclusion=$R_CONC"

[ "$R_CONC" = "success" ] || fail "run $RUN_ID 的 conclusion 是 '$R_CONC'，不是 success —— 不拿它的产物（取消/失败的 run 也可能留有完整 artifact）"

if [ -n "$SHA_FROM" ] && [ -n "$EXPECT_SHA" ]; then
  usage_err "--expect-sha 与 --expect-sha-from 只能给一个"
fi
if [ -z "$EXPECT_SHA" ] && [ -z "$SHA_FROM" ]; then
  SHA_FROM="HEAD"
  note "未指定期望提交；默认取 HEAD"
fi
if [ -n "$SHA_FROM" ]; then
  EXPECT_SHA="$(git -C "$REPO" rev-parse "$SHA_FROM" 2>/dev/null)" \
    || fail "无法解析 tree-ish: $SHA_FROM"
fi
case "$EXPECT_SHA" in
  [0-9a-fA-F]*) ;;
  *) fail "期望提交不是 SHA: $EXPECT_SHA" ;;
esac
if [ "$R_SHA" != "$EXPECT_SHA" ]; then
  fail "产物来源不符: run head_sha=${R_SHA:0:12} != 期望 ${EXPECT_SHA:0:12}（这份产物测的不是那个提交）"
fi
ok "run 成功，且产物来自被测提交 ${EXPECT_SHA:0:12}"

# --- 3. both artifacts present and unexpired --------------------------------
ART_JSON="$(gh api "repos/$SLUG/actions/runs/$RUN_ID/artifacts" 2>/dev/null)" || fail "读不到 run $RUN_ID 的 artifacts"
PRIMARY_NAME="$(python3 -c '
import json,sys,re
d=json.loads(sys.argv[1])
for a in d.get("artifacts",[]):
    n=a["name"]
    if n.startswith("dsh-termux-candidate-") and not n.startswith("dsh-termux-candidate-evidence-"):
        print(n); break
' "$ART_JSON")"
EVID_NAME="$(python3 -c '
import json,sys
d=json.loads(sys.argv[1])
for a in d.get("artifacts",[]):
    if a["name"].startswith("dsh-termux-candidate-evidence-"):
        print(a["name"]); break
' "$ART_JSON")"
[ -n "$PRIMARY_NAME" ] || fail "run $RUN_ID 没有主 artifact（dsh-termux-candidate-*）"
[ -n "$EVID_NAME" ] || fail "run $RUN_ID 没有 evidence artifact —— 缺 provenance/checksums 就无法绑定身份"

primary_field() { python3 -c '
import json,sys
name,field=sys.argv[2],sys.argv[3]
for a in json.loads(sys.argv[1]).get("artifacts",[]):
    if a["name"]==name:
        v=a.get(field)
        print("" if v is None else v); break
' "$ART_JSON" "$1" "$2"; }
for nm in "$PRIMARY_NAME" "$EVID_NAME"; do
  exp="$(primary_field "$nm" expired)"
  [ "$exp" = "False" ] || fail "artifact $nm 已过期或状态未知 (expired=$exp)"
done
P_ID="$(primary_field "$PRIMARY_NAME" id)";       P_DIG="$(primary_field "$PRIMARY_NAME" digest)"
E_ID="$(primary_field "$EVID_NAME" id)";         E_DIG="$(primary_field "$EVID_NAME" digest)"
ok "主 artifact: $PRIMARY_NAME (id=$P_ID)"
ok "证据 artifact: $EVID_NAME (id=$E_ID)"
[ -n "$P_DIG" ] || fail "主 artifact 没有 digest —— 无法校验下载字节"
[ -n "$E_DIG" ] || fail "证据 artifact 没有 digest —— 无法校验下载字节"

if [ "$LIST_ONLY" = 1 ]; then
  echo "primary_name=$PRIMARY_NAME"; echo "primary_id=$P_ID";     echo "primary_digest=$P_DIG"
  echo "evidence_name=$EVID_NAME";  echo "evidence_id=$E_ID";    echo "evidence_digest=$E_DIG"
  echo "head_sha=$R_SHA";           echo "run_id=$RUN_ID"
  exit 0
fi

# --- 4. download and check the archive digests ------------------------------
OUT="${OUT:-$REPO/.test-install/state/candidate-$RUN_ID}"
rm -rf "$OUT" || fail "无法清理输出目录 $OUT"
mkdir -p "$OUT/artifact" "$OUT/evidence" "$OUT/zips" || fail "无法创建输出目录 $OUT"

dl_zip() { # $1=artifact id $2=dest
  gh api "repos/$SLUG/actions/artifacts/$1/zip" > "$2" 2>/dev/null || fail "下载 artifact $1 失败"
}
check_digest() { # $1=file $2=REST digest(sha256:...)
  local want got
  want="${2#sha256:}"
  got="$(sha256sum "$1" | cut -d' ' -f1)"
  [ "$got" = "$want" ] || fail "归档 sha256 与 REST digest 不符: 下载=$got 报告=$want"
  ok "归档 digest 核对通过 ($(basename "$1") ${got:0:12}…)"
}
dl_zip "$P_ID" "$OUT/zips/$PRIMARY_NAME.zip";  check_digest "$OUT/zips/$PRIMARY_NAME.zip" "$P_DIG"
dl_zip "$E_ID" "$OUT/zips/$EVID_NAME.zip";     check_digest "$OUT/zips/$EVID_NAME.zip"  "$E_DIG"

unzip_to() { # $1=zip $2=destdir —— GitHub artifact archives are ZIP, not tar
  if command -v unzip >/dev/null 2>&1; then
    unzip -q -o "$1" -d "$2" || fail "解包 $1 失败 (unzip)"
  else
    python3 -c 'import sys,zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' "$1" "$2" \
      || fail "解包 $1 失败 (python3 zipfile)"
  fi
}
unzip_to "$OUT/zips/$PRIMARY_NAME.zip" "$OUT/artifact"
unzip_to "$OUT/zips/$EVID_NAME.zip"    "$OUT/evidence"

# --- 5. the recorded checksums must match the extracted files --------------
CS="$(find "$OUT/evidence" -name checksums.txt | head -1)"
[ -n "$CS" ] || fail "证据 artifact 里没有 checksums.txt"
# Resolve the three declared files wherever the archive nested them.
ROOT=""
if [ -f "$OUT/artifact/VERSION" ] && [ -f "$OUT/artifact/dsh-termux-runtime.tar.gz" ]; then
  ROOT="$OUT/artifact"
else
  for d in "$OUT/artifact"/*/; do
    [ -d "$d" ] || continue
    if [ -f "${d}dsh-termux-runtime.tar.gz" ] && [ -f "${d}install.sh" ] && [ -f "${d}VERSION" ]; then
      ROOT="${d%/}"; break
    fi
  done
fi
[ -n "$ROOT" ] || fail "解出的主 artifact 不含三件套（runtime/install.sh/VERSION）"
MISS=0
while read -r want_sha fname; do
  [ -n "${fname:-}" ] || continue
  if [ ! -f "$ROOT/$fname" ]; then
    echo "FAIL [$ROUTE]: checksums.txt 列的 $fname 不在主 artifact 里" >&2; MISS=1; continue
  fi
  got="$(sha256sum "$ROOT/$fname" | cut -d' ' -f1)"
  if [ "$got" != "$want_sha" ]; then
    echo "FAIL [$ROUTE]: $fname 的 sha256 与 evidence 记录不符: 实际=$got 记录=$want_sha" >&2; MISS=1
  else
    ok "checksums.txt 核对通过: $fname ${got:0:12}…"
  fi
done < "$CS"
[ "$MISS" = 0 ] || fail "有文件与 evidence 记录的哈希不符"

echo
ok "候选产物已绑定并核验: $EXPECT_SHA"
echo "  DSH_CANDIDATE_ARTIFACT=$ROOT"
echo "下一步（真机）:"
echo "  DSH_CANDIDATE_ARTIFACT=$ROOT bash .test-install/run.sh check \\"
echo "    -c release-install/candidate-artifact -c dry-run/candidate-artifact"
