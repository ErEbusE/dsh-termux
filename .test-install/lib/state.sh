#!/data/data/com.termux/files/usr/bin/bash
# state.sh — 结果/证据协议的内核。被 run.sh（聚合端）与 cases/*.sh（上报端）source。
#
# 单一事实源: 状态集合、聚合优先级、退出码、结果记录格式、报告文本与 JSON。
# 契约见 DECISIONS.md ADR-003。改这里的任何一条都必须同 PR 更新 ADR-003。
#
# 状态集合（case 级）:
#   PASS            完成验证，符合断言
#   FAIL            完成验证，违反断言（含资产 hash 不符、架构不符、被测脚本非零退出）
#   UNMET           必要前置不满足 -> 没有结论。不是较轻的 WARN
#   NOT_APPLICABLE  有适用性依据，本 case 不适用
#   ERROR           测试框架/配置自身故障，或无法解释的执行异常
#   NOT_SELECTED    本次未选中（由聚合端补记，case 不自行上报）
#
# 聚合优先级固定 ERROR > FAIL > UNMET > PASS/N.A.；退出码见 state_exit_code。
#
# 结果记录格式（TSV，一行一个 case，字段内不得含制表符/换行）:
#   id <TAB> class <TAB> selected <TAB> status <TAB> reason <TAB> phase <TAB> duration_s <TAB> evidence

set -uo pipefail

# stdout / stderr 的分工（对整个测试体系生效）:
#   stdout = **报告**（人读的表格或 --json 的 JSON），下游可以直接拿去解析;
#   stderr = **过程**（进度、断言明细、失败原因）。
# 把断言明细写 stdout 会让 `--json | jq` 当场炸——这正是本文件里每个 echo 都要
# 想清楚去哪个流的原因。

# --- 状态与退出码 ------------------------------------------------------------
# 状态取值（见文件头注释）: PASS / FAIL / UNMET / NOT_APPLICABLE / ERROR / NOT_SELECTED
state_exit_code() { # $1=聚合状态
  case "${1:-}" in
    ERROR) echo 2 ;;
    FAIL)  echo 1 ;;
    UNMET) echo 3 ;;
    PASS|NOT_APPLICABLE|NOT_SELECTED|"") echo 0 ;;
    *) echo 2 ;;
  esac
}

# --- 上报端（cases/*.sh 使用）------------------------------------------------
# 调用方须先设 DSH_RESULTS / DSH_CASE_ID / DSH_CASE_CLASS，
# 并在 setup 阶段调用 case_begin。
CASE_FAILURES=""
CASE_PASSES=0
CASE_PHASE="run"

_sanitize() { printf '%s' "${1:-}" | tr '\t\n' '  '; }

case_begin() { # $1=phase(可选)
  CASE_PHASE="${1:-run}"
  CASE_FAILURES=""
  CASE_PASSES=0
  : "${DSH_RESULTS:?case_begin: DSH_RESULTS 未设置}"
  : "${DSH_CASE_ID:?case_begin: DSH_CASE_ID 未设置}"
  : "${DSH_CASE_CLASS:?case_begin: DSH_CASE_CLASS 未设置}"
  # 绝不在这里截断: 多个 case 是**独立进程**追加同一个结果文件,
  # 截断会把先前 case 的记录抹掉（只有最后一条幸存）。初始化归聚合端（run.sh）。
  mkdir -p "$(dirname "$DSH_RESULTS")" || { echo "!! 无法创建结果目录" >&2; exit 2; }
  CASE_T0="$SECONDS"
}

case_phase() { CASE_PHASE="${1:-run}"; }

# 断言: 继续执行并记账（保留全部明细，不因首个失败而中断）
assert_pass() { echo "ok: $*" >&2; CASE_PASSES=$((CASE_PASSES + 1)); }
assert_fail() { echo "FAIL [${DSH_CASE_ID}]: $*" >&2; CASE_FAILURES+="$*"$'\n'; }

_state_emit() { # $1=status $2=reason
  local dur=$((SECONDS - ${CASE_T0:-0}))
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$DSH_CASE_ID" "$DSH_CASE_CLASS" "yes" "$1" "$(_sanitize "$2")" \
    "$CASE_PHASE" "$dur" "${DSH_CASE_EVIDENCE:--}" >> "$DSH_RESULTS"
}

case_finish() { # 由已记账的断言决定 PASS/FAIL
  if [ -n "$CASE_FAILURES" ]; then
    local detail failed
    detail="$(printf '%s' "$CASE_FAILURES" | sed '/^$/d' | tr '\n' ';' | sed 's/;$//; s/;/; /g')"
    failed="$(printf '%s' "$CASE_FAILURES" | sed '/^$/d' | wc -l | tr -d ' ')"
    _state_emit FAIL "$detail"
    echo "== [${DSH_CASE_ID}] FAIL (${CASE_PASSES} ok, ${failed} failed) ==" >&2
    exit 1
  fi
  _state_emit PASS "${CASE_PASSES} 项断言通过"
  echo "== [${DSH_CASE_ID}] done: ${CASE_PASSES} ok ==" >&2
  exit 0
}

# 终止型上报（覆盖断言结果，优先级 UNMET < FAIL < ERROR 由聚合端保证）
case_unmet() { _state_emit UNMET "$*"; echo "UNMET [${DSH_CASE_ID}]: $*" >&2; exit 3; }
case_na()    { _state_emit NOT_APPLICABLE "$*"; echo "n/a [${DSH_CASE_ID}]: $*" >&2; exit 0; }
case_error() { _state_emit ERROR "$*"; echo "ERROR [${DSH_CASE_ID}]: $*" >&2; exit 2; }

# --- 前置判定（聚合端在运行 case 之前调用；不满足 -> UNMET，不执行该 case）-----
# state_require_kind <kind> -> 0 已登记的前置种类 / 1 未登记
# **种类枚举只存在这一处**：registry.sh 只校验语法形状，语义由这里裁决，
# 免得"清单里新加了一种前置"与"内核认识它"两件事各写一遍再漂移。
state_require_kind() {
  case "${1:-}" in
    -|"") return 0 ;;
    seed:*)
      case "${1#seed:}" in ''|*[!a-z0-9._-]*) return 1 ;; *) return 0 ;; esac ;;
    device:*)  case "${1#device:}" in arm64) return 0 ;; *) return 1 ;; esac ;;
    host:*)    case "${1#host:}" in glibc) return 0 ;; *) return 1 ;; esac ;;
    tool:*)    [ -n "${1#tool:}" ] && return 0; return 1 ;;
    network:*) case "${1#network:}" in npm|github|nodejs) return 0 ;; *) return 1 ;; esac ;;
    artifact:*) case "${1#artifact:}" in branch-candidate) return 0 ;; *) return 1 ;; esac ;;
    *) return 1 ;;
  esac
}

# state_check_require <kind> -> 0 满足 / 1 未满足(UNMET) / 2 清单配置错误(ERROR)
# 返回码 2 的存在是刻意的: 一个**未登记的前置种类**是 registry 自身写错,
# 属于框架/配置故障 -> ERROR; 而"设备不在、种子没下"是世界没配合 -> UNMET。
# 把两者混为一谈会让"清单写错了"伪装成"前置缺失"。
#
# 这里只判**存在性**，不判哈希: 资产 hash 与 pin 不符按 ADR-003 是 FAIL（验证
# 完成了、结论是否定的），不是 UNMET。哈希核对归 case 自己。
state_check_require() {
  # 注意: 本函数原本用 `${DSH_HARNESS_ROOT:?}` 做参数守卫，seed:* 委托给 seed.sh 之后
  # 它不再需要 root（路径解析在那边），故去掉以免留下"看起来还在用"的死绑定。
  local kind="${1:-}"
  state_require_kind "$kind" || {
    echo "未登记的前置种类: $kind (registry.tsv 写错 -> 配置错误)"; return 2; }
  case "$kind" in
    -|"") return 0 ;;
    seed:*)
      # 只判**存在性**（哈希核对归 case，见本函数头部说明）。存储布局与记录形状的
      # **唯一**定义在 lib/seed.sh（`seed_cas_path` / `seed_records`），所以这里**委托**
      # 给它，而不是自己再拼一遍 `<sha>/<名>` 并自己 sed 记录——那样重写布局时这一处会
      # 静默误判（顾问审计 R4 实测：曾把"事实源损坏"判成 UNMET，而 ADR-003 要的是 ERROR）。
      # 依赖方向刻意是 state.sh → seed.sh；run.sh 的 source 顺序与各 case 都已满足。
      local name="${kind#seed:}"
      if [ "$(type -t seed_present 2>/dev/null)" != function ]; then
        echo "state_check_require seed:* 需要 lib/seed.sh（请先 source 它）"; return 2
      fi
      seed_present "$name" ;;
    device:arm64)
      case "$(uname -m)" in aarch64|arm64) return 0 ;; esac
      echo "需要 arm64 设备 (当前 $(uname -m))"; return 1 ;;
    host:glibc)
      # 只查 grun 不够: 安装链真正依赖的是「grun + glibc 运行库 + glibc-repo
      # 登记 + patchelf」四件套，缺任何一件都会在**几十秒之后**以难懂的方式炸
      # （patchelf 缺失时 configure_glibc_node 直接返回 1）。前置就该在这里拦住。
      local missing=""
      if ! command -v grun >/dev/null 2>&1 \
         && [ ! -x /data/data/com.termux/files/usr/glibc/bin/grun ]; then
        missing+="grun "
      fi
      command -v patchelf >/dev/null 2>&1 || missing+="patchelf "
      if command -v dpkg >/dev/null 2>&1; then
        dpkg -s glibc >/dev/null 2>&1 || missing+="glibc "
        dpkg -s glibc-repo >/dev/null 2>&1 || missing+="glibc-repo "
      fi
      [ -z "$missing" ] && return 0
      echo "缺少 glibc 组件: ${missing% } (Termux: pkg install glibc-repo glibc glibc-runner)"
      return 1 ;;
    tool:*)
      local t="${kind#tool:}"
      command -v "$t" >/dev/null 2>&1 && return 0
      echo "缺少工具 $t"; return 1 ;;
    network:*)
      local host="${kind#network:}"
      case "$host" in
        npm)     host="https://registry.npmjs.org/" ;;
        github)  host="https://api.github.com/" ;;
        nodejs)  host="https://nodejs.org/dist/" ;;
      esac
      command -v curl >/dev/null 2>&1 || { echo "缺少 curl，无法探测网络"; return 1; }
      curl -sS -o /dev/null --max-time 10 "$host" 2>/dev/null && return 0
      echo "无法访问 $host (受限时先 export https_proxy/http_proxy)"; return 1 ;;
    artifact:branch-candidate)
      # 归档**或**目录都算：`gh run download -n <name>` 落下来的是一个目录，而
      # `gh api .../artifacts/<id>/zip`（或手工 curl）落下来的是一个归档。把候选产物
      # 钉死成其中一种，等于让另一种在"前置"这一步就变成 UNMET —— 那不是缺结论，
      # 是入口写死了（ADR-006 只要求"以 workflow artifact 形式供设备侧消费"）。
      # 真正的布局契约由 case 自己声明（它在 case 头部写清楚要求的三件套）。
      if [ -n "${DSH_CANDIDATE_ARTIFACT:-}" ] \
         && { [ -f "${DSH_CANDIDATE_ARTIFACT}" ] || [ -d "${DSH_CANDIDATE_ARTIFACT}" ]; }; then
        return 0
      fi
      echo "未提供分支候选产物（设 DSH_CANDIDATE_ARTIFACT=<归档或目录>）"; return 1 ;;
  esac
}

# --- 聚合端 ----------------------------------------------------------------
# 结果 TSV -> 并行数组。缺失的 selected case 由调用方先补记 NOT_SELECTED。
state_load() { # $1=results file
  R_ID=(); R_CLASS=(); R_SEL=(); R_ST=(); R_REASON=(); R_PHASE=(); R_DUR=(); R_EV=()
  local id class sel st reason phase dur ev
  [ -f "$1" ] || return 0
  while IFS=$'\t' read -r id class sel st reason phase dur ev; do
    [ -n "${id:-}" ] || continue
    R_ID+=("$id"); R_CLASS+=("${class:--}"); R_SEL+=("${sel:-yes}")
    R_ST+=("${st:-ERROR}"); R_REASON+=("${reason:--}"); R_PHASE+=("${phase:--}")
    R_DUR+=("${dur:-0}"); R_EV+=("${ev:--}")
  done < "$1"
}

# 聚合端补记一条记录（case 未上报、或前置不满足而根本没执行）。
# case 自身一律走 case_begin/case_finish/case_unmet 上报，不用这个函数。
state_append_status() { # $1=file $2=id $3=class $4=selected $5=status $6=reason $7=phase $8=dur $9=evidence
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$2" "$3" "$4" "$5" "$(_sanitize "$6")" "$7" "$8" "${9:--}" >> "$1"
}

state_append_not_selected() { # $1=results file $2=id $3=class $4=reason
  state_append_status "$1" "$2" "$3" "no" "NOT_SELECTED" "$4" "-" "0" "-"
}

# 聚合: 设 AGG_STATUS / AGG_EXIT / AGG_PASS / AGG_FAIL / AGG_UNMET / AGG_NA / AGG_ERR / AGG_NSEL
state_aggregate() {
  AGG_PASS=0; AGG_FAIL=0; AGG_UNMET=0; AGG_NA=0; AGG_ERR=0; AGG_NSEL=0; AGG_SEL=0
  local i st sel
  for i in "${!R_ID[@]}"; do
    st="${R_ST[$i]}"; sel="${R_SEL[$i]}"
    [ "$sel" = yes ] && AGG_SEL=$((AGG_SEL + 1))
    case "$st" in
      PASS) AGG_PASS=$((AGG_PASS + 1)) ;;
      FAIL) AGG_FAIL=$((AGG_FAIL + 1)) ;;
      UNMET) AGG_UNMET=$((AGG_UNMET + 1)) ;;
      NOT_APPLICABLE) AGG_NA=$((AGG_NA + 1)) ;;
      ERROR) AGG_ERR=$((AGG_ERR + 1)) ;;
      NOT_SELECTED) AGG_NSEL=$((AGG_NSEL + 1)) ;;
      *) AGG_ERR=$((AGG_ERR + 1)) ;;
    esac
  done
  if [ "$AGG_ERR" -gt 0 ]; then AGG_STATUS=ERROR
  elif [ "$AGG_FAIL" -gt 0 ]; then AGG_STATUS=FAIL
  elif [ "$AGG_UNMET" -gt 0 ]; then AGG_STATUS=UNMET
  else AGG_STATUS=PASS; fi
  AGG_EXIT="$(state_exit_code "$AGG_STATUS")"
}

# 交付结论（独立于执行结果）: READY / INCOMPLETE / REJECTED
#   REJECTED   存在 FAIL 或 ERROR
#   INCOMPLETE 无 FAIL/ERROR，但存在 UNMET，或存在未被**观察台账**覆盖的必需人工项
#   READY      上述皆无
#
# 人工证据由调用方传入两个变量（空格分隔的清单 id）:
#   DSH_HUMAN_REQUIRED  本轮要求的人工清单
#   DSH_HUMAN_COVERED   已由观察台账覆盖的那些——由 `run.sh finalize` 从
#                       `state/frozen/observations.tsv` 反查得出，**不接受调用者
#                       手写清单 id**。刻意没有"直接签认某个 id"的入口：人工签认
#                       必须绑定到一个有身份的**对象记录**，否则"我测过了"无从
#                       归属于任何候选（见 DECISIONS.md ADR-010）。
state_verdict() {
  if [ "$AGG_FAIL" -gt 0 ] || [ "$AGG_ERR" -gt 0 ]; then echo REJECTED; return; fi
  if [ "$AGG_UNMET" -gt 0 ]; then echo INCOMPLETE; return; fi
  local need="${DSH_HUMAN_REQUIRED:-}" id
  for id in $need; do
    case " ${DSH_HUMAN_COVERED:-} " in *" $id "*) ;; *) echo INCOMPLETE; return ;; esac
  done
  echo READY
}

state_emit_text() {
  local i st sel
  echo
  echo "== 结果总表（selected=${AGG_SEL}  pass=${AGG_PASS}  fail=${AGG_FAIL}  unmet=${AGG_UNMET}  n/a=${AGG_NA}  error=${AGG_ERR}  not-selected=${AGG_NSEL}）=="
  printf '  %-42s %-15s %-6s %s\n' CASE STATUS SEL DETAIL
  for i in "${!R_ID[@]}"; do
    st="${R_ST[$i]}"; sel="${R_SEL[$i]}"
    [ "$sel" = yes ] || sel="-"
    printf '  %-42s %-15s %-6s %s\n' "${R_ID[$i]}" "$st" "$sel" "${R_REASON[$i]}"
  done
  # UNMET 与 ERROR 必须出现在正文，不得藏进 WARN 汇总；NOT_SELECTED 同样必须可见。
  local section
  for section in UNMET ERROR NOT_SELECTED; do
    local shown=0
    for i in "${!R_ID[@]}"; do
      [ "${R_ST[$i]}" = "$section" ] || continue
      if [ "$shown" = 0 ]; then echo; echo "-- $section --"; shown=1; fi
      printf '  %-42s %s\n' "${R_ID[$i]}" "${R_REASON[$i]}"
    done
  done
  echo
  echo "== 聚合: $AGG_STATUS (exit $AGG_EXIT) =="
}

state_emit_json() { # $1=profile $2=verdict
  command -v python3 >/dev/null 2>&1 || {
    echo "!! --json 需要 python3（文本报告不依赖它）" >&2; return 2; }
  # 缺 DSH_RESULTS 时**不要**让它以未绑定变量的身份把调用方打死（`set -u` 下
  # 那是致命错误，脚本会直接退出，连"未生成 JSON"的提示都来不及打）。
  : "${DSH_RESULTS:=}"
  DSH_RESULTS="$DSH_RESULTS" DSH_PROFILE="$1" DSH_VERDICT="$2" python3 - <<'PYEOF'
import json, os

path = os.environ["DSH_RESULTS"]
counts = {k: 0 for k in ("selected", "PASS", "FAIL", "UNMET", "NOT_APPLICABLE", "ERROR", "NOT_SELECTED")}
cases = []
try:
    with open(path, encoding="utf-8") as fh:
        lines = fh.read().splitlines()
except FileNotFoundError:
    lines = []
for line in lines:
    if not line.strip():
        continue
    f = (line.split("\t") + ["-"] * 8)[:8]
    cid, cls, sel, status, reason, phase, dur, ev = f
    counts[status] = counts.get(status, 0) + 1
    if sel == "yes":
        counts["selected"] += 1
    cases.append({
        "id": cid, "class": cls, "selected": sel == "yes", "status": status,
        "reason": reason, "phase": phase,
        "duration_s": int(dur) if dur.isdigit() else 0, "evidence": ev,
    })
if counts["ERROR"]:
    agg = "ERROR"
elif counts["FAIL"]:
    agg = "FAIL"
elif counts["UNMET"]:
    agg = "UNMET"
else:
    agg = "PASS"
exit_code = {"ERROR": 2, "FAIL": 1, "UNMET": 3}.get(agg, 0)
print(json.dumps({
    "schema": "dsh-termux-test-report/1",
    "run_id": os.environ.get("DSH_RUN_ID", "-"),
    "harness": os.environ.get("DSH_HARNESS_IDENTITY", "-"),
    # 结论绑定到的**被测输入**摘要（build receipt 内容寻址的键）。
    "build_digest": os.environ.get("DSH_BUILD_DIGEST", "-"),
    "profile": os.environ.get("DSH_PROFILE", "-"),
    "aggregate": agg,
    "exit_code": exit_code,
    "verdict": os.environ.get("DSH_VERDICT", "-"),
    "counts": counts,
    "cases": cases,
}, ensure_ascii=False, indent=2, sort_keys=True))
PYEOF
}
