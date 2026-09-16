#!/data/data/com.termux/files/usr/bin/bash
# run.sh — 测试体系的唯一入口。（正在按 DECISIONS.md 替换旧的六路线体系。）
#
# 三个 profile 的语义**严格区分**（ADR-002），别当同义词用：
#   check    快集：离线或短网、不依赖大体积种子。**不授予交付资格**。
#   verify   **交付裁决（自动层）**：按改动范围机器规则算出必需 case 并执行。
#            人类实测在沙箱里另外做（serve.sh），凭据写进合并提交的 Tested-by。
#   full     诊断性全量执行。它是一个执行范围，不是交付标准。
#
# 状态、聚合优先级、退出码、交付结论的定义在 `lib/state.sh` 文件头与 ADR-003。
# case 清单的唯一事实源是 `cases/registry.tsv`，由 `lib/registry.sh` 解析。
#
# 用法: bash .test-install/run.sh <命令> [参数]
#   help | list [--json|--format=md] | validate | check | verify | full | seed | clean

set -uo pipefail

TI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$TI_DIR/.." && pwd)"
export DSH_HARNESS_ROOT="$ROOT"
export DSH_TI_DIR="$TI_DIR"
# 线上 HOME 必须在**任何覆盖之前**捕获: lib/sandbox.sh 靠它定义"线上 runtime"
# 是哪一份。一旦有人先改了 HOME 再回落到 $HOME，"线上"就被重新定义成沙箱本身，
# 整个守卫会退化成自我比对（永远为真）。
export DSH_LIVE_HOME="${DSH_LIVE_HOME:-$HOME}"

# shellcheck source=lib/state.sh
. "$TI_DIR/lib/state.sh"
# shellcheck source=lib/registry.sh
. "$TI_DIR/lib/registry.sh"
# shellcheck source=lib/seed.sh
. "$TI_DIR/lib/seed.sh"
# shellcheck source=lib/sandbox.sh
. "$TI_DIR/lib/sandbox.sh"
# shellcheck source=lib/receipt.sh
. "$TI_DIR/lib/receipt.sh"
# shellcheck source=lib/inputs.sh
. "$TI_DIR/lib/inputs.sh"

STATE_DIR="$TI_DIR/state"

# 用 `python3 -c` 而不是 `python3 - <<HEREDOC`：heredoc 会**顶掉**管道的 stdin，
# 那样脚本能跑但数据全丢（SC2259 抓到的就是这个静默失效）。
LIST_JSON_PY="$(cat <<'PY'
import json, sys

def csv(s):
    return [] if s == "-" else s.split(",")

cases = []
for line in sys.stdin.read().splitlines():
    if not line.strip():
        continue
    f = line.split("\t")
    cases.append({
        "id": f[0], "class": f[1], "contract": f[2], "executor": f[3],
        "inputs": csv(f[4]), "requires": csv(f[5]), "changes": csv(f[6]),
        "evidence": csv(f[7]), "human": csv(f[8]), "profiles": f[9].split(","),
        "executor_present": f[10] == "ok",
    })
print(json.dumps({"schema": "dsh-termux-case-registry/1", "count": len(cases),
                  "cases": cases}, ensure_ascii=False, indent=2, sort_keys=True))
PY
)"

if [ -f "$ROOT/VERSION" ]; then
  REPO_VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
else
  REPO_VERSION="?"
fi
REV="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo nogit)"
DIRTY="$(git -C "$ROOT" status --porcelain 2>/dev/null | head -n 1)" || true
# 树不干净必须记录在案：证据要绑定**实际被测的那份内容**，而不是"HEAD 的哈希"。
[ -n "$DIRTY" ] && DIRTY="+dirty" || DIRTY=""
IDENTITY="dsh-termux/$REPO_VERSION@$REV$DIRTY"

usage() {
  cat <<'EOF'
用法: bash .test-install/run.sh <命令> [参数]

清单与自检:
  list [--json] [--format=md]   列出 case 清单（唯一事实源是 cases/registry.tsv）
  validate [--strict-executors] 校验清单自身（段数/枚举/id 唯一/glob 可匹配/
                                人工清单正文齐备）
                                --strict-executors 另查"登记的 executor 必须存在"

执行 profile:
  check      快集：离线或短网、不依赖大体积种子。**不授予交付资格**
  verify     交付裁决（自动层）：按改动范围算出必需 case 并执行
             --diff-base <ref>  比对基准（默认 main；取 merge-base 后比到工作树）
  full       诊断性全量执行

  三者共用: -c|--case <id>（可重复）  --class <大类>（可重复）  --json
            --release-tag <tag>  发布物输入**实例**（默认稳定选择器 releases/latest；
                      显式给 `pre-dsh-*` 就是认证该 prerelease）。一次运行只有一个
                      实例；实例身份进报告头与轮次记录（DECISIONS.md ADR-011）

人类实测: 沙箱由 agent（或人）准备好，用 `bash .test-install/serve.sh --sandbox <名>`
          在隔离环境里启动它；实测凭据按 AGENTS.md §6 用 tools/tb.sh 写进合并提交。

种子管理（事实源 seeds/<name>.env；资产按**内容寻址**存 seeds/seed-assets/<sha256>/，见 ADR-004）:
  seed list                    列出已有种子及其资产状态
  seed show <name>             打印种子事实源并逐件核对哈希
  seed set <tag|latest> [name] [--force]
                               下载发布物、现算 sha256、**先入库后写事实源**
                               （name 默认 stable）。**占用名下换 pin 默认被拒绝**：
                               ADR-004 要求旧种子保留，请换一个名字新增；
                               只有重钉同一个 tag（上游重发资产）才用 --force
  seed migrate                 把旧的扁平位置资产按 pin 归位到内容寻址存储
  seed rm <name>               删除种子事实源（CAS 对象不自动回收，可能被别的种子引用）

其他:
  clean      删除沙箱目录与运行留档（**保留 receipts/ 证据**、清单、种子与代码）
  help       本帮助

环境: 沙箱一律就地保留（run.sh 只创建、不删除）；清理走 `run.sh clean`（默认交互确认）。
退出码: 0=必需项全 PASS / 1=有 FAIL / 2=有 ERROR（框架或配置故障）/ 3=有必需 UNMET。
交付结论 READY / INCOMPLETE / REJECTED 独立于执行结果，见 DECISIONS.md ADR-003。
EOF
}

# ---------------------------------------------------------------- list / validate

cmd_list() {
  local fmt=text
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) fmt=json; shift ;;
      --format=*) fmt="${1#--format=}"; shift ;;
      --format) fmt="${2:?--format 需要值}"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) echo "未知选项: $1" >&2; exit 2 ;;
    esac
  done
  registry_load "$TI_DIR" || exit 2
  registry_validate || exit 2
  case "$fmt" in
    text) list_text ;;
    md) list_md ;;
    json) list_json ;;
    *) echo "未知格式: $fmt (可选 text|md|json)" >&2; exit 2 ;;
  esac
}

list_text() {
  local i missing=0
  printf '  %-32s %-16s %-9s %-8s %-9s %s\n' CASE CLASS PROFILES EXECUTOR EVIDENCE HUMAN
  for i in "${!REG_ID[@]}"; do
    local st; st="$(registry_executor_state "$i")"
    [ "$st" = ok ] || missing=$((missing + 1))
    printf '  %-32s %-16s %-9s %-8s %-9s %s\n' \
      "${REG_ID[$i]}" "${REG_CLASS[$i]}" "${REG_PROFILES[$i]}" \
      "$([ "$st" = ok ] && echo ok || echo MISSING)" \
      "${REG_EV[$i]}" "${REG_HUMAN[$i]}"
  done
  echo
  echo "  共 $REG_COUNT 条；executor 已实现 $((REG_COUNT - missing)) 条，待实现 $missing 条。"
  [ "$missing" -gt 0 ] && echo "  （登记先于实现是允许的过渡态；选中一个没有 executor 的 case 是 ERROR。）"
  return 0
}

list_md() {
  local i
  echo "| case | 大类 | 契约 | 前置 | 证据 | 人工项 |"
  echo "|---|---|---|---|---|---|"
  for i in "${!REG_ID[@]}"; do
    printf '| `%s` | %s | %s | %s | %s | %s |\n' \
      "${REG_ID[$i]}" "${REG_CLASS[$i]}" "${REG_CONTRACT[$i]}" \
      "${REG_REQ[$i]}" "${REG_EV[$i]}" "${REG_HUMAN[$i]}"
  done
}

list_json() {
  command -v python3 >/dev/null 2>&1 || { echo "!! --json 需要 python3" >&2; return 2; }
  local i
  for i in "${!REG_ID[@]}"; do
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "${REG_ID[$i]}" "${REG_CLASS[$i]}" "${REG_CONTRACT[$i]}" "${REG_EXEC[$i]}" \
      "${REG_INPUTS[$i]}" "${REG_REQ[$i]}" "${REG_CHANGES[$i]}" "${REG_EV[$i]}" \
      "${REG_HUMAN[$i]}" "${REG_PROFILES[$i]}" "$(registry_executor_state "$i")"
  done | python3 -c "$LIST_JSON_PY"
}

cmd_validate() {
  local strict=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --strict-executors) strict=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) echo "未知选项: $1" >&2; exit 2 ;;
    esac
  done
  registry_load "$TI_DIR" || exit 2
  local rc=0 i tok
  registry_validate || rc=2
  registry_validate_unregistered || rc=2
  registry_validate_checklists || rc=2
  [ "$strict" = 1 ] && { registry_validate_executors || rc=2; }

  # glob 的"匹配得到东西"用「受跟踪 ∪ 未忽略」的文件集判定：
  # 只看 git ls-files 会把本分支尚未提交的新文件算成不存在。
  local flist="$STATE_DIR/validate-files.txt"
  mkdir -p "$STATE_DIR" || exit 2
  git -C "$ROOT" ls-files --cached --others --exclude-standard > "$flist" 2>/dev/null || true
  if [ ! -s "$flist" ]; then
    echo "!! 拿不到文件清单（不在 git 工作树里？），跳过 glob 校验" >&2
  else
    registry_validate_globs "$flist" || rc=2
  fi

  # 前置种类的语义校验归 state.sh：枚举只有那一处，清单里写错必须报 ERROR 而不是静默。
  for i in "${!REG_ID[@]}"; do
    while IFS= read -r tok; do
      state_require_kind "$tok" && continue
      echo "!! ${REG_ID[$i]} 的 requires 含未登记的前置种类 '$tok'" >&2
      rc=2
    done <<<"$(registry_csv_tokens "${REG_REQ[$i]}")"
  done

  if [ "$rc" = 0 ]; then
    local missing=0
    for i in "${!REG_ID[@]}"; do
      [ "$(registry_executor_state "$i")" = ok ] || missing=$((missing + 1))
    done
    echo "OK: registry 自洽（$REG_COUNT 条，executor 已实现 $((REG_COUNT - missing)) 条）"
  fi
  exit "$rc"
}

# ---------------------------------------------------------------- 选择

changed_files() { # $1=已解析的基准 commit
  git -C "$ROOT" diff --name-only "$1" -- 2>/dev/null || true
  git -C "$ROOT" ls-files --others --exclude-standard 2>/dev/null || true
}

resolve_diff_base() { # $1=ref -> 打印 merge-base
  local base="${1:-main}"
  if ! git -C "$ROOT" rev-parse --verify --quiet "$base^{commit}" >/dev/null; then
    if git -C "$ROOT" rev-parse --verify --quiet "origin/$base^{commit}" >/dev/null; then
      base="origin/$base"
    else
      echo "!! 无法解析比对基准 '$1'（试试 --diff-base <ref>）" >&2
      return 1
    fi
  fi
  git -C "$ROOT" merge-base "$base" HEAD 2>/dev/null || printf '%s\n' "$base"
}

# 选择结果写进 REG_SELECTED（yes/no）。SEL_LABEL 供报告标注。
apply_selection() { # $1=check|full|verify
  local profile="$1" i
  SEL_LABEL="profile:$profile"
  for i in "${!REG_ID[@]}"; do REG_SELECTED[$i]=no; done

  case "$profile" in
    check|full)
      # 显式点选时**只跑点选的**：并集会让"单跑一条"实际跑一整档，而跑的人
      # 以为只跑了一条。verify 不同——它是交付裁决，点选只能与 diff 取并集。
      if [ "${#SELECT_IDS[@]}" -eq 0 ] && [ "${#SELECT_CLASSES[@]}" -eq 0 ]; then
        for i in "${!REG_ID[@]}"; do
          _csv_has "${REG_PROFILES[$i]}" "$profile" && REG_SELECTED[$i]=yes
        done
        SEL_LABEL="profile:$profile"
      else
        SEL_LABEL="explicit"
      fi ;;
    verify)
      SEL_DIFF_BASE="$(resolve_diff_base "${DIFF_BASE:-main}")" || return 2
      mapfile -t SEL_CHANGED < <(changed_files "$SEL_DIFF_BASE")
      for i in "${!REG_ID[@]}"; do
        [ "${REG_CHANGES[$i]}" = "-" ] && continue
        local f
        for f in ${SEL_CHANGED[@]+"${SEL_CHANGED[@]}"}; do
          registry_glob_match_any "$f" "${REG_CHANGES[$i]}" && { REG_SELECTED[$i]=yes; break; }
        done
      done ;;
    *) echo "!! 未知 profile: $profile" >&2; return 2 ;;
  esac

  # 显式选择是**并集**：选了就必需，不存在"顺手跑跑、不算数"的 case。
  local id idx cls
  for id in ${SELECT_IDS[@]+"${SELECT_IDS[@]}"}; do
    idx="$(registry_index_of "$id")" || { echo "!! 未登记的 case: $id" >&2; return 2; }
    REG_SELECTED[$idx]=yes
  done
  for cls in ${SELECT_CLASSES[@]+"${SELECT_CLASSES[@]}"}; do
    _csv_has "$REG_CLASSES" "$cls" || { echo "!! 未知大类: $cls" >&2; return 2; }
    for i in "${!REG_ID[@]}"; do
      [ "${REG_CLASS[$i]}" = "$cls" ] && REG_SELECTED[$i]=yes
    done
  done
  return 0
}

parse_run_args() {
  SELECT_IDS=(); SELECT_CLASSES=(); JSON_OUT=0
  DIFF_BASE="${DSH_DIFF_BASE:-}"
  # 发布物输入实例（ADR-011）：默认稳定选择器（releases/latest），`--release-tag`
  # 显式指定另一个（含 pre-dsh-* 的 prerelease）。一次运行**一个实例**。
  RELEASE_TAG_INPUT="${DSH_RELEASE_TAG_INPUT:-}"
  while [ $# -gt 0 ]; do
    case "$1" in
      -c|--case)   SELECT_IDS+=("${2:?-c 需要 case id}"); shift 2 ;;
      --class)     SELECT_CLASSES+=("${2:?--class 需要大类名}"); shift 2 ;;
      --json)      JSON_OUT=1; shift ;;
      --diff-base) DIFF_BASE="${2:?--diff-base 需要 ref}"; shift 2 ;;
      --release-tag) RELEASE_TAG_INPUT="${2:?--release-tag 需要 tag}"; shift 2 ;;
      -h|--help)   usage; exit 0 ;;
      *) echo "未知选项: $1" >&2; exit 2 ;;
    esac
  done
}

# ---------------------------------------------------------------- 执行与聚合

state_append_all_not_selected() { # $1=结果文件
  local i
  for i in "${!REG_ID[@]}"; do
    [ "${REG_SELECTED[$i]}" = yes ] && continue
    state_append_not_selected "$1" "${REG_ID[$i]}" "${REG_CLASS[$i]}" "本次未选中"
  done
}

# 按 registry 顺序重排结果文件：执行顺序受前置影响会浮动，报告顺序不该跟着浮动。
order_results() { # $1=原始结果 $2=输出
  local in="$1" out="$2" i id line
  local -A res=()
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    res["${line%%$'\t'*}"]="$line"
  done < "$in"
  : > "$out"
  for i in "${!REG_ID[@]}"; do
    id="${REG_ID[$i]}"
    [ -n "${res[$id]:-}" ] && printf '%s\n' "${res[$id]}" >> "$out"
  done
  # 不在清单里的记录也带出去：宁可多看见一条，也不要静默丢弃证据。
  for id in "${!res[@]}"; do
    registry_index_of "$id" >/dev/null 2>&1 || printf '%s\n' "${res[$id]}" >> "$out"
  done
}

run_selected_cases() { # $1=原始结果文件 $2=run 目录
  local raw="$1" run_dir="$2" i
  for i in "${!REG_ID[@]}"; do
    [ "${REG_SELECTED[$i]}" = yes ] || continue
    local id="${REG_ID[$i]}" cls="${REG_CLASS[$i]}" ev="${REG_EV[$i]}"
    local exec_path; exec_path="$(registry_executor_path "$i")"

    if [ ! -f "$exec_path" ]; then
      echo "ERROR [$id]: executor 不存在 (${REG_EXEC[$i]})" >&2
      state_append_status "$raw" "$id" "$cls" yes ERROR \
        "executor 不存在: ${REG_EXEC[$i]}" "-" 0 "$ev"
      continue
    fi

    # 前置判定：不满足 -> UNMET（缺结论，不是较轻的 WARN），**不阻断其他 case**。
    # 分词走 registry_csv_tokens（不做路径展开），且**不设 IFS**：在这类函数里
    # `local IFS=','` 会一路泄漏进被调用的沙箱/收据代码，把按空白分词的循环
    # 变成"整串当一个词"（已实测踩到：透传名单被当成一个变量名）。
    local unmet="" bad="" tok rc msg
    while IFS= read -r tok; do
      msg="$(state_check_require "$tok")"; rc=$?
      case "$rc" in
        0) ;;
        1) unmet+="${unmet:+; }$msg" ;;
        *) bad+="${bad:+; }$msg" ;;
      esac
    done <<<"$(registry_csv_tokens "${REG_REQ[$i]}")"
    if [ -n "$bad" ]; then
      echo "ERROR [$id]: $bad" >&2
      state_append_status "$raw" "$id" "$cls" yes ERROR "$bad" "prereq" 0 "$ev"
      continue
    fi
    if [ -n "$unmet" ]; then
      echo "UNMET [$id]: $unmet" >&2
      state_append_status "$raw" "$id" "$cls" yes UNMET "$unmet" "prereq" 0 "$ev"
      continue
    fi

    # 具名输入：本轮没解析成功时，**依赖它的 case** 记 UNMET（缺结论），
    # 其他独立 case 照跑。绝不回退到上一轮的旧目标——那会得出一个
    # "针对当前默认安装"的资格，而实际测的是别的版本。
    if _csv_has "${REG_INPUTS[$i]}" npm-spec && [ -z "${DSH_NPM_TARGET_FILE:-}" ]; then
      local ierr="${INPUT_RESOLVE_ERR:-本轮未解析 npm 目标}"
      echo "UNMET [$id]: $ierr" >&2
      state_append_status "$raw" "$id" "$cls" yes UNMET "$ierr" "input" 0 "$ev"
      continue
    fi
    # 发布物输入实例没解析成功 -> 依赖"已发布资产"的 case 记 UNMET。**不回退稳定版**：
    # 那会得出"认证了稳定渠道"的结论，而实际什么都没认证（ADR-011）。
    if [ -n "${RELEASE_RESOLVE_FAILED:-}" ] && _csv_has "${REG_INPUTS[$i]}" release-assets; then
      local rerr="发布物输入实例未解析成功（selector=${RELEASE_TAG_INPUT:-latest}）"
      echo "UNMET [$id]: $rerr" >&2
      state_append_status "$raw" "$id" "$cls" yes UNMET "$rerr" "input" 0 "$ev"
      continue
    fi

    echo "-- [$id] ${REG_CONTRACT[$i]}" >&2
    export DSH_CASE_ID="$id" DSH_CASE_CLASS="$cls" DSH_CASE_EVIDENCE="$ev"

    if ! sandbox_prepare "$id"; then
      state_append_status "$raw" "$id" "$cls" yes ERROR \
        "沙箱准备失败（原因见 stderr）" "sandbox" 0 "$ev"
      continue
    fi
    local snap="$run_dir/guard-$SANDBOX_NAME.before.tsv"
    local snap2="$run_dir/guard-$SANDBOX_NAME.after.tsv"
    sandbox_guard_snapshot "$snap" || {
      echo "!! 无法取线上 runtime 起点快照" >&2
      state_append_status "$raw" "$id" "$cls" yes ERROR \
        "无法取线上 runtime 起点快照（守卫缺席，结论不可信）" "guard" 0 "$ev"
      echo "   （沙箱保留: ${SANDBOX_ROOT#"$ROOT"/}/）" >&2
      continue
    }

    local before after code grc=0
    before="$(grep -c . "$raw" 2>/dev/null || true)"
    sandbox_exec "$exec_path"
    code=$?
    after="$(grep -c . "$raw" 2>/dev/null || true)"

    # 守卫先行：线上 runtime 只要被动过，这次运行的结论就不成立——哪怕 case 自报
    # 通过。补一条**框架记录**进结果，聚合与 JSON 报告都会因此变成 ERROR。
    sandbox_guard_verify "$snap" "$snap2" || grc=$?
    if [ "$grc" != 0 ]; then
      state_append_status "$raw" "framework/live-guard" "-" yes ERROR \
        "case $id 运行期间本地正在运行的 dsh runtime 被触碰（差异见 stderr）" "guard" 0 "-"
    fi

    if [ "$after" -le "$before" ]; then
      # case 崩了或被信号打断，没来得及上报：由聚合端补一条 ERROR，
      # 否则它会以 NOT_SELECTED 的样子凭空消失（"没这条"是最坏的失效方式）。
      state_append_status "$raw" "$id" "$cls" yes ERROR \
        "case 退出码 $code 且未上报结果（崩溃/被中断？）" "run" 0 "$ev"
    fi

    # 沙箱一律**就地保留**：run.sh 只创建，删除一律归 `clean`（唯一删除者，默认交互确认）。
    # 理由：删早了人就没得测；而"跑完顺手删"曾是本仓库最隐蔽的意外删除器。
    if [ "$code" != 0 ] || [ "$grc" != 0 ]; then
      echo "   （case 未通过，沙箱保留供归因: ${SANDBOX_ROOT#"$ROOT"/}/）" >&2
      continue
    fi
    # 带人工清单的 case：那棵树就是 agent 要交给人类实测的东西，人用
    # `serve.sh --sandbox <名>` 起它。沙箱名由 case id 派生，所以命令可照抄。
    if [ "${REG_HUMAN[$i]}" != "-" ]; then
      echo "   待人类实测: bash .test-install/serve.sh --sandbox $(basename "$SANDBOX_ROOT")" >&2
    fi
  done
}

cmd_run() {
  local profile="$1"; shift
  parse_run_args "$@"
  registry_load "$TI_DIR" || exit 2
  registry_validate || exit 2
  apply_selection "$profile" || exit 2


  # 注意: 不要在这里重置 SEL_CHANGED —— apply_selection 的 verify 分支刚填好它。
  RUN_ID="$(date +%Y%m%dT%H%M%S)-$$"
  local run_dir="$STATE_DIR/$RUN_ID"
  mkdir -p "$run_dir" || { echo "!! 无法创建 $run_dir" >&2; exit 2; }
  local raw="$run_dir/results.raw.tsv" results="$run_dir/results.tsv"
  : > "$raw"
  export DSH_RUN_ID="$RUN_ID" DSH_HARNESS_IDENTITY="$IDENTITY"
  # case 追加到 raw；聚合读的是重排后的 results，所以在报告前会再指一次。
  # **必须在跑 case 之前导出**：case 拿到的是一份白名单环境，不会自动继承
  # 调用命令行上的临时赋值（先前的写法正是靠那个，换成 env -i 后就断了）。
  export DSH_RESULTS="$raw"

  local i nsel=0
  for i in "${!REG_ID[@]}"; do
    [ "${REG_SELECTED[$i]}" = yes ] && nsel=$((nsel + 1))
  done

  # 具名输入的解析与冻结**必须在 build receipt 之前**：receipt 是"将要被跑的
  # 那组输入"的纯函数，解析结果（精确版本、SRI、来源）是这组输入的一部分。
  # 没有 case 需要该输入时**根本不联网**（help/list/validate 与纯离线 profile 不受影响）。
  INPUT_RESOLVE_ERR=""
  if [ "$nsel" -gt 0 ] && inputs_selection_needs npm-spec; then
    echo "==> 解析并冻结具名输入 default-target（npm）…" >&2
    if ! inputs_freeze_npm_target "$run_dir/input-npm-target.tsv"; then
      INPUT_RESOLVE_ERR="npm 目标解析失败（原因见上）—— 依赖该输入的 case 记 UNMET，不回退旧目标"
      echo "!! $INPUT_RESOLVE_ERR" >&2
    fi
  fi

  # 发布物输入实例（ADR-011）。与 npm 输入同一条纪律：选中的 case 里真的有 case
  # 声明了 `release-assets`（=**认证一份已发布资产**）时才解析，没选就不联网。
  # 声明 `release-seed`/`baseline-seed` 的 case 用的是**已经 pin 好的种子**，它的实例
  # 身份来自种子事实源，不需要也不应该为此联网（否则离线 profile 会平白变 UNMET）。
  # 一次运行**只允许一个实例**——默认稳定选择器（releases/latest），`--release-tag <tag>`
  # 指定另一个（含 pre-dsh-* 的 prerelease）。实例身份单独留一份（报告头 + 轮次都要能
  # 读到）：只写 case id 的 PASS 会把一次 pre 认证读成稳定渠道认证。
  RELEASE_SELECTOR="" RELEASE_TAG="" RELEASE_PRERELEASE="" RELEASE_RESOLVE_FAILED=""
  if [ "$nsel" -gt 0 ] && inputs_selection_needs release-assets; then
    RELEASE_SELECTOR="${RELEASE_TAG_INPUT:-latest}"
    echo "==> 解析发布物输入实例: $RELEASE_SELECTOR …" >&2
    if RELEASE_TAG="$(resolve_release_tag "$RELEASE_SELECTOR")"; then
      case "$RELEASE_TAG" in pre-*) RELEASE_PRERELEASE=yes ;; *) RELEASE_PRERELEASE=no ;; esac
      {
        printf 'selector\t%s\n' "$RELEASE_SELECTOR"
        printf 'resolved_tag\t%s\n' "$RELEASE_TAG"
        printf 'prerelease\t%s\n' "$RELEASE_PRERELEASE"
        printf 'resolved_at\t%s\n' "$(date '+%F %R%:z')"
      } > "$run_dir/input-release.tsv" || echo "!! 未能写发布物实例记录" >&2
      export DSH_RELEASE_SELECTOR="$RELEASE_SELECTOR" DSH_RELEASE_TAG="$RELEASE_TAG"
    else
      RELEASE_RESOLVE_FAILED=1
      echo "!! 发布物输入实例解析失败: $RELEASE_SELECTOR（依赖它的 case 记 UNMET，不回退稳定版）" >&2
    fi
  fi

  # build receipt = 被测输入的纯函数（无时间戳、无 run id），所以内容寻址、
  # 跨运行可比对。**必须在跑任何 case 之前生成**：它描述的是"将要被跑的东西"。
  BUILD_DIGEST=""
  if receipt_build "$run_dir/build-receipt.tsv" "$STATE_DIR/worktree-list.txt"; then
    export BUILD_DIGEST
    export DSH_BUILD_DIGEST="$BUILD_DIGEST"
    export DSH_BUILD_RECEIPT="$BUILD_RECEIPT_FILE"
  else
    echo "ERROR: 无法生成 build receipt —— 结论将无法绑定被测对象" >&2
    state_append_status "$raw" "framework/receipt" "-" yes ERROR \
      "无法生成 build receipt（结论无法绑定被测对象）" "receipt" 0 "-"
  fi


  # stdout 只留给报告；过程走 stderr（见 lib/state.sh 文件头的分工说明）。
  {
    echo "== run $RUN_ID  profile=$profile  $SEL_LABEL"
    echo "   被测对象: $IDENTITY"
    [ "$profile" = verify ] && \
      echo "   改动范围: ${SEL_DIFF_BASE}..工作树（${#SEL_CHANGED[@]} 个文件）"
    [ -n "${NPM_TARGET_VERSION:-}" ] && \
      echo "   npm 目标: ${NPM_TARGET_PACKAGE}@${NPM_TARGET_VERSION}（冻结于本轮，来源 $(inputs_npm_registry)）"
    # ADR-011：资格是 (case, 输入实例)。报告头必须显示实例，否则一次 pre 认证会被
    # 读成稳定渠道认证。
    [ -n "${RELEASE_TAG:-}" ] && \
      echo "   发布物实例: ${RELEASE_SELECTOR} → ${RELEASE_TAG}（prerelease=${RELEASE_PRERELEASE}）"
    echo
  } >&2

  if [ "$nsel" -eq 0 ]; then
    # "什么都没选中"绝不能悄悄退化成 PASS。做法不是内联 exit，而是补一条
    # **框架记录**：这样聚合与 JSON 报告天然得出 ERROR，理由也落在正文里
    # （ADR-003 要求 UNMET/ERROR 必须出现在报告正文，不许藏进汇总）。
    local codefiles=0 f
    if [ "$profile" = verify ]; then
      for f in ${SEL_CHANGED[@]+"${SEL_CHANGED[@]}"}; do
        case "$f" in *.md|*.mdx) ;; *) codefiles=$((codefiles + 1)) ;; esac
      done
    fi
    state_append_all_not_selected "$raw"
    if [ "$profile" != verify ]; then
      echo "ERROR: profile $profile 没有选中任何 case —— 清单的 profiles 字段坏了" >&2
      state_append_status "$raw" "framework/selection" "-" yes ERROR \
        "profile $profile 没有选中任何 case —— 清单的 profiles 字段坏了" "select" 0 "-"
    elif [ "$codefiles" -gt 0 ]; then
      echo "ERROR: 本次改动没有任何 case 的 changes 覆盖它（$codefiles 个非文档文件）——" >&2
      echo "       这是**清单缺口**，不是通过。请补 case，或补 changes glob。" >&2
      state_append_status "$raw" "framework/selection" "-" yes ERROR \
        "本次改动没有任何 case 的 changes 覆盖它（$codefiles 个非文档文件）—— 清单缺口，不是通过" \
        "select" 0 "-"
    else
      echo "note: 本次改动只有文档，未命中任何 case 的 changes。" >&2
    fi
  else
    echo "   选中 $nsel 条 case" >&2
    echo >&2
    run_selected_cases "$raw" "$run_dir"
    state_append_all_not_selected "$raw"
  fi

  order_results "$raw" "$results"
  export DSH_RESULTS="$results"
  state_load "$results"
  state_aggregate
  local verdict; verdict="$(state_verdict)"

  # 只追加的运行收据：把"结论"钉到"对象"（build digest）上。这是 `clean`
  # 唯一保留的东西——运行目录可以删，证据不行。
  receipt_test_append \
    "$RUN_ID" "$(date '+%F %R%:z')" "$profile" "${BUILD_DIGEST:--}" \
    "$AGG_SEL" "$AGG_PASS" "$AGG_FAIL" "$AGG_UNMET" "$AGG_NA" "$AGG_ERR" "$AGG_NSEL" \
    "$AGG_STATUS" "$AGG_EXIT" "$verdict" "-" "-" "$IDENTITY" \
    || echo "!! 未能追加 test receipt" >&2

  # `--json` 时 stdout **只给 JSON**：否则"喂给下游的机器可读输出"里混着一段中文
  # 表格，任何 `| jq` 都会当场炸。人读的报告永远落 report.txt。
  if [ "$JSON_OUT" = 1 ]; then
    { state_emit_text; run_report_tail "$verdict" "$run_dir"; } > "$run_dir/report.txt"
    state_emit_json "$profile" "$verdict" | tee "$run_dir/report.json"
  else
    { state_emit_text; run_report_tail "$verdict" "$run_dir"; } | tee "$run_dir/report.txt"
    state_emit_json "$profile" "$verdict" > "$run_dir/report.json" \
      || echo "!! 未能生成 report.json（需要 python3；文本报告不受影响）" >&2
  fi
  exit "$AGG_EXIT"
}

run_report_tail() { # $1=verdict $2=run_dir
  echo
  echo "被测输入:   ${BUILD_DIGEST:-<未生成 build receipt>}"
  [ -n "${BUILD_DIGEST:-}" ] && echo "            .test-install/state/receipts/build-${BUILD_DIGEST}.tsv"
  echo "交付结论:   $1  （自动层结论；人类实测按 AGENTS.md §6 走 serve.sh + Tested-by）"
  echo "留档:       ${2#"$ROOT"/}/"
}

# ---------------------------------------------------------------- seed

cmd_seed() {
  local sub="${1:-list}"; shift || true
  case "$sub" in
    list)
      local names n found=0
      names="$(seed_names)"
      [ -n "$names" ] || { echo "没有任何种子。生成: run.sh seed set <tag|latest> [name]"; return 1; }
      while IFS= read -r n; do
        [ -n "$n" ] || continue
        found=1
        local f tag
        f="$(seed_env_path "$n")"
        tag="$(sed -n 's/^SEED_TAG=//p' "$f")"
        if seed_verify "$n" >/dev/null 2>&1; then
          printf '  %-16s %s  (资产齐、哈希相符)\n' "$n" "$tag"
        else
          printf '  %-16s %s  (资产缺失或哈希不符: run.sh seed show %s)\n' "$n" "$tag" "$n"
        fi
      done <<<"$names"
      [ "$found" = 1 ] || return 1
      ;;
    show)
      local n="${1:?seed show 需要种子名}"
      local f; f="$(seed_env_path "$n")"
      [ -f "$f" ] || { echo "!! 没有种子 $n（$f）" >&2; return 1; }
      echo "== $f"
      cat "$f"
      echo "== 资产核对（内容寻址存储 $ROOT/.test-install/seeds/seed-assets/<sha256>/）"
      seed_verify "$n"
      ;;
    set)
      # 参数形状: [--force] <tag|latest> [name] [--force]（--force 可前置或后置）。
      # 一条 while/case 走完，不把 --force 的分支抄三遍（评审 NEW-3）。
      local force=0 pos=()
      while [ $# -gt 0 ]; do
        case "$1" in
          --force) force=1; shift ;;
          -*) echo "!! seed set 不认识的参数: $1" >&2; return 2 ;;
          *) pos+=("$1"); shift ;;
        esac
      done
      local tagarg="${pos[0]:?seed set 需要 <tag|latest>}"
      local name="${pos[1]:-stable}"
      [ "${#pos[@]}" -le 2 ] \
        || { echo "!! seed set 参数过多: ${pos[*]:2}" >&2; return 2; }
      case "$name" in *[!a-z0-9._-]*|'') echo "!! 非法种子名: $name" >&2; return 1 ;; esac
      local tag; tag="$(resolve_release_tag "$tagarg")" || return 1
      case "$tag" in
        pre-*)
          echo "!! $tag 是 pre 渠道产物（prerelease），不作种子。" >&2
          echo "   稳定渠道的种子只 pin 已发布版本；分支/pre 产物走候选产物路径（DSH_CANDIDATE_ARTIFACT）。" >&2
          return 1 ;;
      esac
      [ "$tag" != "$tagarg" ] && echo "   $tagarg -> $tag"
      # 发布流程（占用名检查 / staging / trap / CAS / 写 .env）整体住在 lib/seed.sh：
      # 那里才是"种子事实"的家，也才能与 seed_prune_stale_staging 挨着——staging 的
      # 名字只有一份定义（seed_staging_dir）。这里只做参数与 dispatch。
      seed_publish "$name" "$tag" "$force"
      ;;
    migrate)
      # 把旧扁平位置的资产按 pin 归位到内容寻址存储；不改任何 .env。
      seed_migrate_legacy || return 1
      echo "==> 复核所有种子："
      local mn
      while IFS= read -r mn; do
        [ -n "$mn" ] || continue
        printf '  %-16s ' "$mn"
        if seed_verify "$mn" >/dev/null 2>&1; then echo "OK"; else echo "异常：看 seed show $mn"; fi
      done < <(seed_names)
      ;;
    rm)
      local n="${1:?seed rm 需要种子名}"
      local f; f="$(seed_env_path "$n")"
      [ -f "$f" ] || { echo "!! 没有种子 $n" >&2; return 1; }
      rm -f "$f"
      echo "==> 已删除 $f（内容寻址存储里的对象可能仍被其他种子引用，故不自动回收）"
      ;;
    -h|--help|help) usage ;;
    *) echo "未知 seed 子命令: $sub" >&2; exit 2 ;;
  esac
}

# 最后一次启动某沙箱的时间（来自 serve.sh 写的 state/served.tsv）。没记录就输出 "-"。
clean_served_at() { # $1=沙箱名
  local f="$STATE_DIR/served.tsv"
  [ -f "$f" ] || { printf -- '-\n'; return 0; }
  local ts
  ts="$(awk -F'\t' -v n="$1" '$1==n {t=$2} END {print t}' "$f")"
  printf '%s\n' "${ts:--}"
}

# 人类实测用的沙箱目录大小（只给一个量级，供人判断删除代价）。
clean_dir_size() { # $1=目录
  du -sh "$1" 2>/dev/null | cut -f1 || printf '?\n'
}

# `clean` 是**唯一**的删除者（run.sh 只创建，serve.sh 只记录）。默认交互：逐条打印
# 「名字 / serve 启动时间 / 大小」让人确认。刻意不记沙箱哈希——所以要靠这两样人工
# 辨认；没被 serve 启动过的（失败保留、残留）也列出来，但明确标注，由人决定。
cmd_clean() {
  local yes=0 dry=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --yes|-y)    yes=1; shift ;;
      --dry-run|-n) dry=1; shift ;;
      -h|--help)   echo "用法: run.sh clean [--yes] [--dry-run]"
                   echo "  默认逐条交互确认；--yes 全部删除（冒烟/非交互用）；--dry-run 只列不删。"; return 0 ;;
      *) echo "未知选项: $1" >&2; return 2 ;;
    esac
  done

  local n_del=0 n_keep=0 p name ts sz ans
  local -a victims=()
  for p in "$TI_DIR"/sandbox-*; do
    [ -d "$p" ] || continue
    name="$(basename "$p")"
    ts="$(clean_served_at "$name")"
    sz="$(clean_dir_size "$p")"
    if [ "$ts" = "-" ]; then
      echo "  $name   serve 启动记录: 无（可能是失败保留或残留）   大小 $sz"
    else
      echo "  $name   上次 serve 启动: $ts   大小 $sz"
    fi
    if [ "$dry" = 1 ]; then victims+=("$p"); continue; fi
    if [ "$yes" = 1 ]; then
      victims+=("$p")
    else
      # 读不到 tty（非交互）时按“不删”处理，绝不默默删掉——这是唯一删除者，宁保守。
      if [ -t 0 ]; then
        printf "    删除? [y/N] "; read -r ans || ans=""
      else
        echo "    （非交互：跳过；要删请加 --yes）"; ans=""
      fi
      case "$ans" in y|Y|yes|YES) victims+=("$p") ;; *) n_keep=$((n_keep + 1)) ;; esac
    fi
  done

  if [ "$dry" = 1 ]; then
    echo "==> --dry-run: 以上 ${#victims[@]} 个沙箱**未被删除**"
    return 0
  fi
  for p in ${victims[@]+"${victims[@]}"}; do
    rm -rf "$p" && n_del=$((n_del + 1))
  done
  [ "$n_del" -gt 0 ] && echo "==> 已删除 $n_del 个沙箱${n_keep:+, 保留 $n_keep 个}"
  [ "$n_del" = 0 ] && echo "==> 没有删除任何沙箱${n_keep:+, 保留 $n_keep 个}"

  # 运行留档（每次 verify 的 <run-id>/）。receipts/ 是**证据**，保留。
  local n_state=0
  for p in "$STATE_DIR"/*/; do
    [ -d "$p" ] || continue
    case "$p" in "$STATE_DIR/receipts/") continue ;; esac
    rm -rf "$p"; n_state=$((n_state + 1))
  done
  rm -f "$STATE_DIR/validate-files.txt" "$STATE_DIR/worktree-list.txt"
  # 沙箱都没了，启动台账也就没有意义了；一并清掉，下次从干净的记录开始。
  rm -f "$STATE_DIR/served.tsv"
  echo "==> 已清理 $n_state 项运行留档（receipts/ 与 seeds/ 保留）"
}

# ---------------------------------------------------------------- dispatch

cmd="${1:-help}"
[ $# -gt 0 ] && shift
case "$cmd" in
  help|-h|--help) usage ;;
  list)     cmd_list "$@" ;;
  validate) cmd_validate "$@" ;;
  check)    cmd_run check "$@" ;;
  verify)   cmd_run verify "$@" ;;
  full)     cmd_run full "$@" ;;
  seed)     cmd_seed "$@" ;;
  clean)    cmd_clean "$@" ;;
  *) echo "未知命令: $cmd" >&2; echo; usage >&2; exit 2 ;;
esac
