#!/data/data/com.termux/files/usr/bin/bash
# run.sh — 测试体系的唯一入口。（正在按 DECISIONS.md 替换旧的六路线体系。）
#
# 三个 profile 的语义**严格区分**（ADR-002），别当同义词用：
#   check    快集：离线或短网、不依赖大体积种子。**不授予交付资格**。
#   verify   **唯一交付裁决**：按改动范围机器规则算出必需 case + 核对人工证据。
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
# frozen.sh 依赖 receipt.sh 的两个摘要函数，必须在其后 source。
# shellcheck source=lib/frozen.sh
. "$TI_DIR/lib/frozen.sh"
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
  verify     交付裁决：按改动范围算出必需 case + 核对人工证据；同时**开一个轮次**
             --diff-base <ref>  比对基准（默认 main；取 merge-base 后比到工作树）
  full       诊断性全量执行

  三者共用: -c|--case <id>（可重复）  --class <大类>（可重复）  --json
            --freeze  通过且带人工项的 case 留下沙箱并写冻结对象记录
                      （verify 默认开启；check/full 默认不留，避免堆 GB 级沙箱）
            --release-tag <tag>  发布物输入**实例**（默认稳定选择器 releases/latest；
                      显式给 `pre-dsh-*` 就是认证该 prerelease）。一次运行只有一个
                      实例；实例身份进报告头与轮次记录（DECISIONS.md ADR-011）

人工实测与终结（同一轮次内完成，不是跨轮复用，见 DECISIONS.md ADR-010）:
  finalize <轮次id> --observed <对象id,…>
             用人类回复中确认的**对象记录 id** 终结该轮次并给出最终结论。
             对象 id 由 serve.sh 打印；不接受手写清单 id——人工证据必须绑定对象。

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
  clean      删除沙箱目录与运行留档（**保留 receipts/ 证据、rounds/ 轮次记录与
             frozen/ 对象记录**、清单、种子与代码）
  help       本帮助

环境: DSH_KEEP_SANDBOX=1 保留通过 case 的沙箱（默认通过即删、失败保留供归因）。
退出码: 0=必需项全 PASS / 1=有 FAIL / 2=有 ERROR（框架或配置故障）/ 3=有必需 UNMET。
交付结论 READY / INCOMPLETE / REJECTED 独立于执行结果，见 DECISIONS.md ADR-003/010。
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
  FREEZE="${DSH_FREEZE:-0}"
  DIFF_BASE="${DSH_DIFF_BASE:-}"
  # 发布物输入实例（ADR-011）：默认稳定选择器（releases/latest），`--release-tag`
  # 显式指定另一个（含 pre-dsh-* 的 prerelease）。一次运行**一个实例**。
  RELEASE_TAG_INPUT="${DSH_RELEASE_TAG_INPUT:-}"
  while [ $# -gt 0 ]; do
    case "$1" in
      -c|--case)   SELECT_IDS+=("${2:?-c 需要 case id}"); shift 2 ;;
      --class)     SELECT_CLASSES+=("${2:?--class 需要大类名}"); shift 2 ;;
      --json)      JSON_OUT=1; shift ;;
      --freeze)    FREEZE=1; shift ;;
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
      sandbox_teardown keep
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

    # 通过就删沙箱（否则全量跑一次要堆十几份 GB 级目录）；没通过就留着，
    # 归因要靠里面的现场。DSH_KEEP_SANDBOX=1 可强制全留。
    if [ "$code" != 0 ] || [ "$grc" != 0 ]; then
      sandbox_teardown keep
      echo "   （沙箱保留: ${SANDBOX_ROOT#"$ROOT"/}/）" >&2
      continue
    fi

    # 冻结：把"通过且带人工项"的那棵树留成**人类可实测的对象**，并写下它的身份。
    # 为什么不能沿用"起服务时再 overlay 一遍"——那就是 C3：人类实测的对象已经不是
    # 被断言的那一个，而交付说明仍按被断言的那个写。见 DECISIONS.md ADR-010。
    if [ "$FREEZE" = 1 ] && [ "${REG_HUMAN[$i]}" != "-" ]; then
      local frc=0
      # 只有 verify 开出的轮次才能被 finalize 终结；check/full 冻结的对象是
      # 诊断用的自由对象（可 serve，但终结不了任何轮次）。
      local rid="-"; [ "$profile" = verify ] && rid="$RUN_ID"
      frozen_write "$SANDBOX_ROOT" "$id" "$cls" "${REG_HUMAN[$i]}" \
                   "$RUN_ID" "${DSH_BUILD_DIGEST:-${BUILD_DIGEST:--}}" "$rid" || frc=$?
      if [ "$frc" = 0 ]; then
        printf '%s\t%s\t%s\n' "$id" "$FROZEN_ID" "$SANDBOX_NAME" >> "$FROZEN_INDEX"
        echo "   冻结对象: $FROZEN_ID  ($(basename "$SANDBOX_ROOT")/, 人工清单 ${REG_HUMAN[$i]})" >&2
      else
        # 必要证据写不进去 = 本次结论不成立（ADR-009）。绝不留成"看起来通过"。
        local why="无法写冻结对象记录（人类实测将无从归属）"
        [ "$frc" = 3 ] && why="工作区内容在本次运行期间变过，拒绝冻结（来源说不清）"
        echo "ERROR [$id]: $why" >&2
        state_append_status "$raw" "framework/frozen" "-" yes ERROR "$id: $why" "frozen" 0 "-"
      fi
      sandbox_teardown keep
    else
      sandbox_teardown remove
    fi
  done
}

cmd_run() {
  local profile="$1"; shift
  parse_run_args "$@"
  registry_load "$TI_DIR" || exit 2
  registry_validate || exit 2
  apply_selection "$profile" || exit 2

  # verify 是**交付裁决**：它同时开一个轮次（round），人类实测与终结都在这一轮里
  # 完成，不重新解析输入、不重跑 case（ADR-010）。因此它默认冻结对象——没有对象，
  # 人工项永远只能停在 INCOMPLETE。check/full 不是裁决，默认不留（手机磁盘）。
  [ "$profile" = verify ] && FREEZE=1

  # 注意: 不要在这里重置 SEL_CHANGED —— apply_selection 的 verify 分支刚填好它。
  RUN_ID="$(date +%Y%m%dT%H%M%S)-$$"
  local run_dir="$STATE_DIR/$RUN_ID"
  mkdir -p "$run_dir" || { echo "!! 无法创建 $run_dir" >&2; exit 2; }
  local raw="$run_dir/results.raw.tsv" results="$run_dir/results.tsv"
  : > "$raw"
  FROZEN_INDEX="$run_dir/frozen-objects.tsv"
  : > "$FROZEN_INDEX"
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

  # 人工必需清单 = 选中 case 的 human 字段之并集
  local human="" tok
  for i in "${!REG_ID[@]}"; do
    [ "${REG_SELECTED[$i]}" = yes ] || continue
    while IFS= read -r tok; do
      [ "$tok" = "-" ] && continue
      _csv_has "$human" "$tok" || human="${human:+$human,}$tok"
    done <<<"$(registry_csv_tokens "${REG_HUMAN[$i]}")"
  done

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
  # 人工项在本轮**一律未覆盖**：覆盖只能由 `finalize` 从观察台账反查得出。
  # 这里给它空值，于是"有必需人工项 -> INCOMPLETE"是结构性的，不靠人记得传参数。
  export DSH_HUMAN_REQUIRED="$human" DSH_HUMAN_COVERED=""
  local verdict; verdict="$(state_verdict)"

  # 轮次记录：verify 开的这一轮要能被 serve 与 finalize 在**不重跑、不重新解析**
  # 的前提下接着走，所以结果、冻结输入与对象索引都要留一份耐久副本。
  # `clean` 保留它，理由与 receipts/ 相同：删了就没法终结，也没法回溯"当时测了什么"。
  if [ "$profile" = verify ]; then
    write_round "$RUN_ID" "$run_dir" "$results" "$verdict" "$human" || \
      echo "!! 未能写轮次记录（人类实测路径将不可用）" >&2
  fi

  # 只追加的运行收据：把"结论"钉到"对象"（build digest）上。这是 `clean`
  # 唯一保留的东西——运行目录可以删，证据不行。
  receipt_test_append \
    "$RUN_ID" "$(date '+%F %R%:z')" "$profile" "${BUILD_DIGEST:--}" \
    "$AGG_SEL" "$AGG_PASS" "$AGG_FAIL" "$AGG_UNMET" "$AGG_NA" "$AGG_ERR" "$AGG_NSEL" \
    "$AGG_STATUS" "$AGG_EXIT" "$verdict" "${human:--}" "-" "$IDENTITY" \
    || echo "!! 未能追加 test receipt" >&2

  # `--json` 时 stdout **只给 JSON**：否则"喂给下游的机器可读输出"里混着一段中文
  # 表格，任何 `| jq` 都会当场炸。人读的报告永远落 report.txt。
  if [ "$JSON_OUT" = 1 ]; then
    { state_emit_text; run_report_tail "$verdict" "$human" "$run_dir"; } > "$run_dir/report.txt"
    state_emit_json "$profile" "$verdict" | tee "$run_dir/report.json"
  else
    { state_emit_text; run_report_tail "$verdict" "$human" "$run_dir"; } | tee "$run_dir/report.txt"
    state_emit_json "$profile" "$verdict" > "$run_dir/report.json" \
      || echo "!! 未能生成 report.json（需要 python3；文本报告不受影响）" >&2
  fi
  exit "$AGG_EXIT"
}

run_report_tail() { # $1=verdict $2=human 必需项 $3=run_dir
  echo
  echo "被测输入:   ${BUILD_DIGEST:-<未生成 build receipt>}"
  [ -n "${BUILD_DIGEST:-}" ] && echo "            .test-install/state/receipts/build-${BUILD_DIGEST}.tsv"
  if [ -n "$2" ]; then
    echo "人工必需项: $2"
    # 覆盖只能来自 finalize 反查观察台账；本轮永远是空的。这一行是刻意写出来的：
    # "谁说自己能签认"比"忘了传参数"更容易出问题。
    echo "已覆盖:     ${DSH_HUMAN_COVERED:-<无>}  (覆盖只能由 finalize 从观察台账反查)"
    if [ "$1" != READY ]; then
      echo "（人工项未终结 -> 结论停在 INCOMPLETE。这不是失败，是还没做完。）"
      echo "下一步:     bash .test-install/serve.sh --round $RUN_ID"
      echo "            人在浏览器里逐项实测并在会话里确认后，用 serve 打印的对象 id:"
      echo "            bash .test-install/run.sh finalize $RUN_ID --observed <对象id,…>"
    fi
  else
    echo "人工必需项: 无"
  fi
  echo "交付结论:   $1"
  echo "留档:       ${3#"$ROOT"/}/"
}

# ---------------------------------------------------------------- 轮次与终结

round_dir() { printf '%s/rounds/%s\n' "$STATE_DIR" "$1"; }

# 轮次（round）= 一次 `verify` 开的判定回合。serve 与 finalize 都在**这一轮之内**
# 工作：不重跑 case、不重新解析 default-target。这不是"跨运行复用人工证据"
# （那件事被明确推迟），而是**把已经开出的这一轮做完**（ADR-010）。
write_round() { # $1=round id $2=run_dir $3=results $4=verdict $5=human csv
  local rid="$1" run_dir="$2" results="$3" verdict="$4" human="$5"
  local rd; rd="$(round_dir "$rid")"
  mkdir -p "$rd" || return 2
  cp "$results" "$rd/results.tsv" || return 2
  if [ -s "${FROZEN_INDEX:-}" ]; then cp "$FROZEN_INDEX" "$rd/objects.tsv" || return 2
  else : > "$rd/objects.tsv" || return 2; fi
  [ -f "$run_dir/input-npm-target.tsv" ] && cp "$run_dir/input-npm-target.tsv" "$rd/"
  [ -f "$run_dir/input-release.tsv" ] && cp "$run_dir/input-release.tsv" "$rd/"
  [ -f "$run_dir/build-receipt.tsv" ] && cp "$run_dir/build-receipt.tsv" "$rd/"
  {
    printf 'schema\tdsh-termux-round/1\n'
    printf 'round_id\t%s\n' "$rid"
    printf 'created_at\t%s\n' "$(date '+%F %R%:z')"
    printf 'harness_identity\t%s\n' "$IDENTITY"
    printf 'build_digest\t%s\n' "${BUILD_DIGEST:--}"
    printf 'release_selector\t%s\n' "${RELEASE_SELECTOR:--}"
    printf 'release_instance\t%s\n' "${RELEASE_TAG:--}"
    printf 'release_prerelease\t%s\n' "${RELEASE_PRERELEASE:--}"
    printf 'aggregate\t%s\n' "$AGG_STATUS"
    printf 'exit_code\t%s\n' "$AGG_EXIT"
    printf 'verdict\t%s\n' "$verdict"
    printf 'human_required\t%s\n' "${human:--}"
    printf 'diff_base\t%s\n' "${SEL_DIFF_BASE:-}"
    printf 'selected\t%s\n' "$AGG_SEL"
  } > "$rd/round.tsv.tmp" || return 2
  mv -f "$rd/round.tsv.tmp" "$rd/round.tsv" || return 2
  return 0
}

round_get() { # $1=round dir $2=键
  [ -f "$1/round.tsv" ] || return 1
  sed -n "s/^$2\t//p" "$1/round.tsv" | head -n 1
}

# 终结: 用人类回复中确认的**对象记录 id** 给这一轮下最终结论。
# 为什么必须逐对象: 同一个人工清单 id 可能对应多条 case、多棵树，在一棵树上点过
# 的"通过"不能自动覆盖另一棵（评审结论）。为什么必须绑定对象而不是清单 id:
# 只写 `serve-patch` 的话，"人测的那棵树"与"这一轮判的那棵树"之间没有任何连接。
cmd_finalize() {
  local rid="" obs_in=""
  local -a observed=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --observed)  obs_in="${2:?--observed 需要对象 id 列表}"; shift 2 ;;
      --observed=*) obs_in="${1#--observed=}"; shift ;;
      -h|--help) usage; exit 0 ;;
      -*) echo "未知选项: $1" >&2; exit 2 ;;
      *) if [ -n "$rid" ]; then
           echo "!! finalize 只接受一个轮次 id（收到 '$rid' 与 '$1'）" >&2; exit 2
         fi
         rid="$1"; shift ;;
    esac
  done
  [ -n "$rid" ] || {
    echo "!! finalize 需要一个轮次 id: run.sh finalize <轮次id> --observed <对象id,…>" >&2
    exit 2; }
  case "$rid" in *[!0-9A-Za-z-]*) echo "!! 轮次 id 形状非法: $rid" >&2; exit 2 ;; esac
  local o
  for o in $(printf '%s' "$obs_in" | tr ',' ' '); do
    [ -n "$o" ] && observed+=("$o")
  done
  [ "${#observed[@]}" -gt 0 ] || {
    echo "!! 必须给出至少一个 --observed 对象 id（serve.sh 启动时会打印的那个）" >&2
    echo "   人工证据必须能指回具体对象；只写清单名的签认一律不接受。" >&2
    exit 2; }

  local rd; rd="$(round_dir "$rid")"
  if [ ! -f "$rd/round.tsv" ]; then
    echo "!! 没有轮次 $rid（缺 $rd/round.tsv）" >&2
    echo "   finalize 只能终结由 run.sh verify 开出的轮次；独立发起的新 verify 是" >&2
    echo "   **新轮次**，不能消费旧轮次的人工签认，即便 build digest 相同（ADR-010）。" >&2
    exit 2
  fi
  registry_load "$TI_DIR" || exit 2

  state_load "$rd/results.tsv"
  state_aggregate
  if [ "$AGG_FAIL" -gt 0 ] || [ "$AGG_ERR" -gt 0 ]; then
    echo "!! 轮次 $rid 的自动结果是 $AGG_STATUS：先修自动层，再谈人工实测" >&2
    echo "   轮次留档: ${rd#"$ROOT"/}/results.tsv" >&2
    exit "$AGG_EXIT"
  fi

  # 逐对象核对：每个"通过且带人工项"的被选 case 都必须有对象记录，且该对象
  # (a) 出现在 --observed 里（人的明确回复）、(b) 有完整的观察（start 与 end 都 ok）、
  # (c) 现在仍与冻结时的载荷一致（对象还在盘上、字节没变）。
  local covered="" n_obj=0 i case_id manifest sbox root k sel
  while IFS=$'\t' read -r case_id manifest sbox; do
    [ -n "$case_id" ] || continue
    i="$(registry_index_of "$case_id")" || {
      echo "!! 轮次里的对象记录指向未登记的 case: $case_id" >&2; exit 2; }
    # 是否被选中要读**那一轮的结果文件**，不是 registry 的默认值：finalize 不重跑
    # 选择（那会重新解析 diff 与输入，就不再是"终结同一轮"了）。
    sel=no
    for k in "${!R_ID[@]}"; do [ "${R_ID[$k]}" = "$case_id" ] && sel="${R_SEL[$k]}"; done
    [ "$sel" = yes ] || continue
    [ "${REG_HUMAN[$i]}" != "-" ] || continue
    root="$TI_DIR/sandbox-$sbox"

    local inlist=0; local -a chk=("${observed[@]}")
    for o in "${chk[@]}"; do [ "$o" = "$manifest" ] && inlist=1; done
    if [ "$inlist" != 1 ]; then
      echo "!! case $case_id 的对象未被 --observed 确认: $manifest" >&2
      echo "   它声明的人工清单是 ${REG_HUMAN[$i]}；在一棵树上点过的通过不能覆盖另一棵。" >&2
      exit 2
    fi
    if ! frozen_observed_ok "$manifest"; then
      echo "!! 对象 $manifest 没有完整的观察记录（需要 start 与 end 都 ok）" >&2
      echo "   查看: ${DSH_TI_DIR}/state/frozen/observations.tsv" >&2
      exit 2
    fi
    local mf; mf="$(frozen_resolve "$manifest")" || {
      echo "!! 找不到对象记录 $manifest（state/frozen/）" >&2; exit 2; }
    if [ "$(frozen_get "$mf" round_id)" != "$rid" ]; then
      echo "!! 对象 $manifest 属于轮次 $(frozen_get "$mf" round_id)，不是 $rid" >&2
      exit 2
    fi
    if ! frozen_object_ok "$root" "$mf"; then
      echo "!! case $case_id 的对象当前与冻结记录不一致（或被删了）—— 拒绝终结" >&2
      exit 2
    fi
    local tok
    while IFS= read -r tok; do
      [ "$tok" = "-" ] && continue
      _csv_has "$covered" "$tok" || covered="${covered:+$covered,}$tok"
    done <<<"$(registry_csv_tokens "${REG_HUMAN[$i]}")"
    n_obj=$((n_obj + 1))
  done < "$rd/objects.tsv"

  local need_h; need_h="$(round_get "$rd" human_required)"
  local missing="" tok
  [ -n "$need_h" ] && [ "$need_h" != "-" ] && while IFS= read -r tok; do
    [ "$tok" = "-" ] && continue
    _csv_has "$covered" "$tok" || missing+="${missing:+ }$tok"
  done <<<"$(registry_csv_tokens "$need_h")"
  if [ -n "$missing" ]; then
    echo "!! 轮次 $rid 的必需人工项未被对象观察覆盖: $missing" >&2
    echo "   本轮的对象记录: ${rd#"$ROOT"/}/objects.tsv" >&2
    exit 2
  fi

  export DSH_RUN_ID="$rid" DSH_HUMAN_REQUIRED="$need_h"
  # 先赋值再 export：`export X="$(...)"` 会把命令替换的退出码吞掉（SC2155）。
  local covered_sp; covered_sp="$(printf '%s' "$covered" | tr ',' ' ')"
  local rd_build rd_ident
  rd_build="$(round_get "$rd" build_digest)"
  rd_ident="$(round_get "$rd" harness_identity)"
  export DSH_HUMAN_COVERED="$covered_sp" DSH_BUILD_DIGEST="$rd_build"
  export DSH_HARNESS_IDENTITY="$rd_ident"
  # JSON 报告读的是 DSH_RESULTS；指向**那一轮**的结果文件，报告才描述得对。
  export DSH_RESULTS="$rd/results.tsv"
  local verdict; verdict="$(state_verdict)"

  {
    echo "== finalize $rid"
    echo "   对象确认: $n_obj 个（人工清单覆盖: ${covered:--}）"
    state_emit_text
    run_report_tail "$verdict" "$need_h" "$rd"
  } | tee "$rd/finalize-report.txt"
  state_emit_json "verify+finalize" "$verdict" > "$rd/finalize-report.json" \
    || echo "!! 未能生成 finalize 报告 JSON" >&2

  receipt_test_append \
    "$rid" "$(date '+%F %R%:z')" "verify+finalize" "${DSH_BUILD_DIGEST:--}" \
    "$AGG_SEL" "$AGG_PASS" "$AGG_FAIL" "$AGG_UNMET" "$AGG_NA" "$AGG_ERR" "$AGG_NSEL" \
    "$AGG_STATUS" "$AGG_EXIT" "$verdict" "${need_h:--}" "$covered" "$DSH_HARNESS_IDENTITY" \
    || echo "!! 未能追加 test receipt" >&2
  echo "（终结不是新一轮执行：没有重跑 case，也没有重新解析 default-target。）" >&2
  exit "$AGG_EXIT"
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
      # 可选 --force 可以出现在任意位置：只影响"占用名下换 pin"这一条决策。
      FORCE_SEED=0
      local -a setargs=()
      local a
      for a in "$@"; do
        case "$a" in
          --force) FORCE_SEED=1 ;;
          *) setargs+=("$a") ;;
        esac
      done
      set -- ${setargs[@]+"${setargs[@]}"}
      local tagarg="${1:?seed set 需要 <tag|latest>}"; shift || true
      local name="${1:-stable}"
      case "$name" in *[!a-z0-9._-]*|'') echo "!! 非法种子名: $name" >&2; return 1 ;; esac
      local tag; tag="$(resolve_release_tag "$tagarg")" || return 1
      case "$tag" in
        pre-*)
          echo "!! $tag 是 pre 渠道产物（prerelease），不作种子。" >&2
          echo "   稳定渠道的种子只 pin 已发布版本；分支/pre 产物走候选产物路径（DSH_CANDIDATE_ARTIFACT）。" >&2
          return 1 ;;
      esac
      [ "$tag" != "$tagarg" ] && echo "   $tagarg -> $tag"

      # **不许在占用名下静默换 pin**（ADR-004：旧 pin 记录本身就是要保留的输入——
      # 追新 pin 会消灭旧版本的升级覆盖窗口，而"孤儿字节"没有版本关联、不算旧种子）。
      # 想上新版本请换一个种子名；确实要重钉同一个 tag（例如上游重发资产）才用 --force。
      local envf; envf="$(seed_env_path "$name")"
      if [ -f "$envf" ] && [ "${FORCE_SEED:-0}" != 1 ]; then
        local old_tag; old_tag="$(sed -n 's/^SEED_TAG=//p' "$envf")"
        if [ "$old_tag" != "$tag" ]; then
          echo "!! 种子名 '$name' 已被占用：$old_tag" >&2
          echo "   ADR-004 要求旧种子**保留**，所以在同名下换 pin 默认被拒绝。" >&2
          echo "   请换一个名字新增：bash .test-install/run.sh seed set $tag <新名>" >&2
          echo "   （确实要重钉同一个 tag，例如上游重发资产时才用 --force。）" >&2
          return 1
        fi
      fi

      # 先下到**私有 staging**、逐件校验、只**新增**对象，**最后**才写 .env——
      # 所以一次失败的 pin 绝不可能破坏已有种子的字节（实测复现过的缺陷）。
      local dl; dl="$(seed_assets_dir)"
      seed_prune_stale_staging            # 上次被杀留下的半成品可能占 110MB
      local stage="$dl/.staging.$$"
      rm -rf "$stage"; mkdir -p "$stage" || return 1
      # 被 Ctrl-C / SIGTERM（含 timeout）打断时也要收掉自己的 staging：
      # 否则一次中断就白占最多 110MB，且没有任何东西会来提醒。
      # shellcheck disable=SC2064  # 故意在此刻展开 $stage
      trap "rm -rf '$stage'" INT TERM HUP
      echo "==> 下载 $tag 的发布物到 staging …"
      if ! seed_fetch_assets "$tag" "$stage"; then
        rm -rf "$stage"; trap - INT TERM HUP; return 1
      fi
      local records; records="$(seed_install_cas "$stage" $SEED_ASSETS_DEFAULT)" || {
        echo "!! 无法把资产归入内容寻址存储（已有种子未被改动）" >&2
        rm -rf "$stage"; trap - INT TERM HUP; return 1; }
      rm -rf "$stage"; trap - INT TERM HUP
      # 记录是每行一条 "<资产名>:<sha256>"，无空白，故按词拆分。
      # shellcheck disable=SC2086
      if ! seed_write_env "$name" "$tag" "$(seed_dsh_version "$tag")" $records; then
        echo "!! 写 seeds/$name.env 失败（资产已入库，可重试；已有种子未被改动）" >&2
        rm -rf "$stage"; return 1
      fi
      echo "==> seeds/$name.env 已写入"
      seed_verify "$name"
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
  return 0
}

cmd_clean() {
  local n=0 p
  for p in "$TI_DIR"/sandbox-*; do
    [ -d "$p" ] || continue
    rm -rf "$p"; n=$((n + 1))
  done
  for p in "$STATE_DIR"/*/; do
    [ -d "$p" ] || continue
    # receipts/ 是**证据**、rounds/ 是**未完结的轮次**（删了人工项就永远无法终结）、
    # frozen/ 是**对象记录与观察台账**：三者都不是垃圾，删了就没法回溯"当时测了什么"。
    case "$p" in
      "$STATE_DIR/receipts/"|"$STATE_DIR/rounds/"|"$STATE_DIR/frozen/") continue ;;
    esac
    rm -rf "$p"; n=$((n + 1))
  done
  rm -f "$STATE_DIR/validate-files.txt" "$STATE_DIR/worktree-list.txt"
  echo "==> 已清理 $n 项（沙箱目录 + 运行留档）；receipts/ rounds/ frozen/ 保留"
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
  finalize) cmd_finalize "$@" ;;
  seed)     cmd_seed "$@" ;;
  clean)    cmd_clean "$@" ;;
  *) echo "未知命令: $cmd" >&2; echo; usage >&2; exit 2 ;;
esac
