#!/data/data/com.termux/files/usr/bin/bash
# registry.sh — `cases/registry.tsv` 的唯一解析与选择实现。
#
# 为什么要有这个库: 矩阵的唯一事实源是 `cases/registry.tsv`，而它的消费者有
# 四个（`run.sh list` / `list --format=md` 生成 README 矩阵 / `run.sh
# check|verify|full` 的选择 / CI 的登记完整性断言）。让每个消费者各写一遍解析，
# 迟早出现"README 说有十五条、run.sh 只跑十二条"。
#
# **分层**（刻意的，别把两者混起来）:
#   * 本库只做**语法与结构**校验: 段数、枚举取值、id 唯一、executor 路径形状、
#     glob 是否匹配得到东西。
#   * "某个前置种类是否已登记"这类**语义**判定归 `lib/state.sh` 的
#     `state_require_kind`（枚举只存在一处），由 `run.sh validate` 串起来。
#
# executor **是否存在**不在这里判死: 登记先于实现是允许的过渡状态（配套的
# `list` 会把它标成 MISSING，选中一个没有 executor 的 case 是 ERROR）。
# CI 用 `run.sh validate --strict-executors` 把这条收紧。

set -uo pipefail

# 这些枚举**用逗号分隔**，与 registry 字段同形：所有取值判定都走 `_csv_has`，
# 免得出现"清单里是逗号、代码里以为空格"的静默不匹配。
REG_CLASSES="dry-run,update,release-install,setup-install"
REG_INPUT_KINDS="repo-tree,baseline-seed,release-seed,release-assets,npm-spec,candidate-artifact,local-stub"
REG_EVIDENCE_KINDS="marker,behavior,boot,install,download"
REG_HUMAN_ITEMS="serve-patch,serve-install,serve-update,serve-chat,serve-floor"
REG_PROFILE_NAMES="check,full"

REG_TI_DIR=""
REG_FILE=""
REG_COUNT=0
REG_ID=(); REG_CLASS=(); REG_CONTRACT=(); REG_EXEC=(); REG_INPUTS=()
REG_REQ=(); REG_CHANGES=(); REG_EV=(); REG_HUMAN=(); REG_PROFILES=()
REG_SELECTED=()

# 把逗号分隔字段安全地拆成 token。**绝不要用 `for x in $csv`**：那是未加引号的
# 展开，shell 会顺手做一次**路径展开**——registry 里的 `.test-install/**` 会被
# 展开成 cwd 下的真实文件名（实测踩到：glob 校验报出一串风马牛不相及的名字，
# 而真正的 glob 根本没被检查）。`read -a` 不做任何展开。
registry_csv_tokens() { # $1=csv -> 每行一个 token
  local p
  local -a parts=()
  local IFS=','
  read -r -a parts <<<"$1"
  for p in "${parts[@]}"; do [ -n "$p" ] && printf '%s\n' "$p"; done
}

_csv_has() { # $1=csv $2=token
  local t
  while IFS= read -r t; do [ "$t" = "$2" ] && return 0; done \
    <<<"$(registry_csv_tokens "$1")"
  return 1
}

# 模式匹配语义: `[[ ]]`/`case` 里的 `*` 也会跨 `/`，因此 `patches/**` 与
# `patches/*` 在这里同义。这是**刻意**的选择——本仓库的 glob 都很浅，而
# "补丁挪进子目录就静默漏选"是比"多选一点"严重得多的失效模式。
# SC2254 正是要禁掉这种用法，此处刻意启用。
registry_glob_match() { # $1=path $2=glob
  # shellcheck disable=SC2254
  case "$1" in $2) return 0 ;; esac
  return 1
}

registry_glob_match_any() { # $1=path $2=csv globs
  local g
  while IFS= read -r g; do
    [ "$g" = "-" ] && continue
    registry_glob_match "$1" "$g" && return 0
  done <<<"$(registry_csv_tokens "$2")"
  return 1
}

registry_index_of() { # $1=id -> 打印下标
  local i
  for i in "${!REG_ID[@]}"; do
    [ "${REG_ID[$i]}" = "$1" ] && { echo "$i"; return 0; }
  done
  return 1
}

registry_executor_path() { # $1=index -> 绝对路径
  printf '%s/%s\n' "$REG_TI_DIR" "${REG_EXEC[$1]}"
}

registry_executor_state() { # $1=index -> ok | missing
  local p
  p="$(registry_executor_path "$1")"
  [ -f "$p" ] && { echo ok; return 0; }
  echo missing
}

# 解析。**不**在这里做枚举校验——先解析后校验，才能把全部错误一次报出来。
registry_load() { # $1=.test-install 目录; 0 成功 / 2 结构错误
  local ti="$1"
  REG_TI_DIR="$ti"
  REG_FILE="$ti/cases/registry.tsv"
  REG_ID=(); REG_CLASS=(); REG_CONTRACT=(); REG_EXEC=(); REG_INPUTS=()
  REG_REQ=(); REG_CHANGES=(); REG_EV=(); REG_HUMAN=(); REG_PROFILES=()
  REG_SELECTED=()
  [ -f "$REG_FILE" ] || { echo "!! registry 缺失: $REG_FILE" >&2; return 2; }
  local ln=0 line
  while IFS= read -r line || [ -n "$line" ]; do
    ln=$((ln + 1))
    line="${line%$'\r'}"
    case "$line" in ''|'#'*) continue ;; esac
    local -a f=()
    IFS='|' read -r -a f <<<"$line"
    if [ "${#f[@]}" -ne 10 ]; then
      echo "!! $REG_FILE:$ln 需要 10 段, 实得 ${#f[@]} 段" >&2
      return 2
    fi
    REG_ID+=("${f[0]}");     REG_CLASS+=("${f[1]}");  REG_CONTRACT+=("${f[2]}")
    REG_EXEC+=("${f[3]}");   REG_INPUTS+=("${f[4]}"); REG_REQ+=("${f[5]}")
    REG_CHANGES+=("${f[6]}"); REG_EV+=("${f[7]}");    REG_HUMAN+=("${f[8]}")
    REG_PROFILES+=("${f[9]}")
  done < "$REG_FILE"
  REG_COUNT="${#REG_ID[@]}"
  [ "$REG_COUNT" -gt 0 ] || { echo "!! $REG_FILE 里没有任何 case" >&2; return 2; }
  local i
  # REG_SELECTED 由消费者（run.sh）读写，这里只负责按 registry 长度做齐。
  # shellcheck disable=SC2034
  for i in "${!REG_ID[@]}"; do REG_SELECTED[$i]=no; done
  return 0
}

# 逐段语法/枚举校验。**一次报全**，不因首个错误中断。
registry_validate() {
  local rc=0 i tok
  local -A seen=()
  for i in "${!REG_ID[@]}"; do
    local id="${REG_ID[$i]}" cls="${REG_CLASS[$i]}" contract="${REG_CONTRACT[$i]}"
    local exec="${REG_EXEC[$i]}" inputs="${REG_INPUTS[$i]}" req="${REG_REQ[$i]}"
    local changes="${REG_CHANGES[$i]}" ev="${REG_EV[$i]}" human="${REG_HUMAN[$i]}"
    local profs="${REG_PROFILES[$i]}"
    local where="$REG_FILE:${id:-<空 id>}"

    if ! [[ "$id" =~ ^[a-z0-9][a-z0-9-]*/[a-z0-9][a-z0-9-]*$ ]]; then
      echo "!! $where 的 id 形状非法 (期望 <class>/<sub>, 小写字母数字与连字符)" >&2; rc=2
    fi
    if [ -n "${seen[$id]:-}" ]; then
      echo "!! $where 的 id 重复 (第 $((${seen[$id]} + 1)) 条与第 $((i + 1)) 条)" >&2; rc=2
    fi
    seen[$id]=$i

    if ! _csv_has "$REG_CLASSES" "$cls"; then
      echo "!! $where 的 class '$cls' 不在 {$REG_CLASSES//,/ }" >&2; rc=2
    elif [ "$cls" != "${id%%/*}" ]; then
      echo "!! $where 的 class '$cls' 与 id 前缀 '${id%%/*}' 不一致" >&2; rc=2
    fi
    [ -n "$contract" ] || { echo "!! $where 缺 contract" >&2; rc=2; }

    case "$exec" in
      cases/*.sh) ;;
      *) echo "!! $where 的 executor '$exec' 必须以 cases/ 开头且以 .sh 结尾" >&2; rc=2 ;;
    esac
    case "/$exec/" in *"/../"*) echo "!! $where 的 executor '$exec' 含 '..'" >&2; rc=2 ;; esac

    while IFS= read -r tok; do
      [ "$tok" = "-" ] && continue
      _csv_has "$REG_INPUT_KINDS" "$tok" \
        || { echo "!! $where 的 inputs 含未知种类 '$tok'" >&2; rc=2; }
    done <<<"$(registry_csv_tokens "$inputs")"
    while IFS= read -r tok; do
      [ "$tok" = "-" ] && continue
      case "$tok" in
        *:?*) ;;
        *) echo "!! $where 的 requires 含无法解析的项 '$tok'" >&2; rc=2 ;;
      esac
    done <<<"$(registry_csv_tokens "$req")"
    while IFS= read -r tok; do
      [ "$tok" = "-" ] && continue
      case "$tok" in
        *' '*) echo "!! $where 的 changes 项 '$tok' 含空格" >&2; rc=2 ;;
      esac
    done <<<"$(registry_csv_tokens "$changes")"
    while IFS= read -r tok; do
      [ "$tok" = "-" ] && continue
      _csv_has "$REG_EVIDENCE_KINDS" "$tok" \
        || { echo "!! $where 的 evidence 含未知等级 '$tok'" >&2; rc=2; }
    done <<<"$(registry_csv_tokens "$ev")"
    while IFS= read -r tok; do
      [ "$tok" = "-" ] && continue
      _csv_has "$REG_HUMAN_ITEMS" "$tok" \
        || { echo "!! $where 的 human 含未知清单 id '$tok'" >&2; rc=2; }
    done <<<"$(registry_csv_tokens "$human")"
    local nprof=0
    while IFS= read -r tok; do
      _csv_has "$REG_PROFILE_NAMES" "$tok" \
        || { echo "!! $where 的 profiles 含未知 profile '$tok'" >&2; rc=2; }
      nprof=$((nprof + 1))
    done <<<"$(registry_csv_tokens "$profs")"
    [ "$nprof" -gt 0 ] || { echo "!! $where 的 profiles 为空" >&2; rc=2; }
  done
  return $rc
}

_any_file_matches() { # $1=路径清单文件 $2=glob
  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    registry_glob_match "$f" "$2" && return 0
  done < "$1"
  return 1
}

# 每个 changes glob 至少要匹配得到一个"受跟踪或未被忽略"的文件。
# 这一条防的是**拼错 glob**：写错一个字母，那个 case 从此永远不被 diff 选中，
# 而报告上什么都看不出来（不是红，是"没这条"——最坏的失效方式）。
registry_validate_globs() { # $1=候选路径文件 (每行一条)
  local rc=0 i g
  for i in "${!REG_ID[@]}"; do
    while IFS= read -r g; do
      [ "$g" = "-" ] && continue
      if ! _any_file_matches "$1" "$g"; then
        echo "!! ${REG_ID[$i]} 的 changes glob '$g' 匹配不到任何文件 (拼错?)" >&2
        rc=2
      fi
    done <<<"$(registry_csv_tokens "${REG_CHANGES[$i]}")"
  done
  return $rc
}

# executor 存在性（CI 的严格模式用；过渡期 registry 先于实现是允许的）
registry_validate_executors() {
  local rc=0 i
  for i in "${!REG_ID[@]}"; do
    [ "$(registry_executor_state "$i")" = ok ] && continue
    echo "!! ${REG_ID[$i]} 登记的 executor 不存在: ${REG_EXEC[$i]}" >&2
    rc=2
  done
  return $rc
}

# 反向: cases/ 下可执行的 *.sh 必须都已登记（防"写了脚本忘了登记"）
registry_validate_unregistered() {
  local rc=0 f base i found
  for f in "$REG_TI_DIR"/cases/*.sh; do
    [ -f "$f" ] || continue
    base="cases/$(basename "$f")"
    found=0
    for i in "${!REG_ID[@]}"; do
      [ "${REG_EXEC[$i]}" = "$base" ] && { found=1; break; }
    done
    [ "$found" = 1 ] && continue
    echo "!! cases/ 下的 $base 未在 registry.tsv 登记" >&2
    rc=2
  done
  return $rc
}

# --- 人工清单（human id -> 静态清单正文） ------------------------------------
# 清单正文是**数据文件**而不是打印在 serve.sh 里的字面量：人工签认必须能引用
# "人到底照着哪份清单做的"，而那需要清单本身可摘要。打印出来的那份随 serve 的
# 代码而变，文件不会。
registry_checklist_path() { printf '%s/cases/checklists/%s.txt\n' "$REG_TI_DIR" "$1"; }

registry_checklist_digest() { # $1=清单 id -> sha256（缺文件时输出 missing，绝不用空串冒充）
  local f; f="$(registry_checklist_path "$1")"
  [ -f "$f" ] && { sha256sum "$f" | cut -d' ' -f1; return 0; }
  printf 'missing\n'
}

# 双向: 清单里用到的 human id 必须有正文文件；正文文件也必须被清单引用。
# 与 executor 的登记断言同形——**单边遗漏都要报**。
registry_validate_checklists() {
  local rc=0 i tok f base found id
  for i in "${!REG_ID[@]}"; do
    while IFS= read -r tok; do
      [ "$tok" = "-" ] && continue
      if [ ! -f "$(registry_checklist_path "$tok")" ]; then
        echo "!! ${REG_ID[$i]} 声明的人工清单 '$tok' 没有正文文件: cases/checklists/$tok.txt" >&2
        rc=2
      fi
    done <<<"$(registry_csv_tokens "${REG_HUMAN[$i]}")"
  done
  for f in "$REG_TI_DIR"/cases/checklists/*.txt; do
    [ -f "$f" ] || continue
    base="$(basename "$f" .txt)"
    found=0
    for i in "${!REG_ID[@]}"; do
      while IFS= read -r id; do
        [ "$id" = "$base" ] && { found=1; break; }
      done <<<"$(registry_csv_tokens "${REG_HUMAN[$i]}")"
      [ "$found" = 1 ] && break
    done
    [ "$found" = 1 ] && continue
    echo "!! cases/checklists/$base.txt 没有任何 case 声明（孤儿清单）" >&2
    rc=2
  done
  return $rc
}
