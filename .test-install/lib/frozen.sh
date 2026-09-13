#!/data/data/com.termux/files/usr/bin/bash
# frozen.sh — **冻结对象**（人类实测对象）的载荷边界、耐久记录、漂移判定与观察台账。
#
# 为什么需要这一层（实查更正 C3 + 评审裁决）：
#   旧 serve.sh 在认证完发布物之后**无条件**把工作区补丁 overlay 上去，于是人类在
#   浏览器里实测的对象已经不是被认证/被断言的那一个，而交付说明仍按被认证的那个写。
#   修法不是"少 overlay 一点"，而是让"人类实测的对象"成为一个**有身份、可复核**的
#   东西——没有身份，"人类说测过了"就无法归属于任何候选。
#
# 三层身份，互不替代（评审结论，缺一层就有一类失效挡不住）：
#
#   build digest    这次资格针对**哪组输入**（冻结的 npm 目标 + 工作树 + 补丁集…）
#   payload digest  人实际启动的是**哪些字节**（同一组输入可能产出不同对象）
#   run_id/case_id  这棵树是哪一次执行、**走哪条过程**得到的
#                   （同一棵最终树不能证明安装路径与升级路径都验证过）
#
# 载荷边界（关键，且是踩过的那条教训的推广）：
#
#   * **载荷**（可执行的那部分）= 装出来的 dsh 树 + 解释器，逐字节冻结；
#   * **可写区** = HOME / tmp / ws / 会话与缓存。人类实测本身就在写它们，把可写区
#     算进身份，结果就是"正常实测"每次都自己制造对象漂移——正如当年把 `~/.dsh`
#     当越界证据会**永远为真**一样（一个总是红的检测等于没有检测）；
#   * **机件**（启动器 / grun stub）由 serve 现生成，单独记摘要追溯：它的生成器源码
#     本来就在被测工作树摘要里，但它是被测对象的**外壳**而不是候选内容。
#
# 记录（manifest）是内容寻址的：不含时间戳、不含 run 之外的浮动值，同一份对象
# 永远落到同一个 id。**时间属于观察台账**，不属于对象身份。

set -uo pipefail

# 记录格式版本。改字段语义必须同时改它（manifest 是证据，不能悄悄变形状）。
FROZEN_SCHEMA="dsh-termux-frozen-object/1"

frozen_store() { printf '%s\n' "${DSH_TI_DIR:?}/state/frozen"; }

# 载荷内的**排除项**（逐层目录名）。进 manifest 备查：覆盖边界必须是写下来的，
# 不能靠"读代码才知道"。`.cache` 是包自己会写的缓存目录——把它算进身份，第一次
# 人类实测就会假报漂移。
FROZEN_PAYLOAD_EXCLUDES=".cache"

# 载荷根（相对沙箱根）。刻意**不含** bin/（机件）、home/ tmp/ ws/（可写区）。
frozen_payload_roots() {
  printf '%s\n' "prefix/work" "prefix/node/bin"
}

frozen_get() { # $1=manifest 文件 $2=键 -> 值（缺键输出空）
  [ -f "$1" ] || return 1
  sed -n "s/^$2\t//p" "$1" | head -n 1
}

frozen_resolve() { # $1=对象 id -> manifest 路径（找不到返回 1）
  local id="${1:-}" f
  case "$id" in
    *[!0-9a-f]*|'') return 1 ;;
  esac
  f="$(frozen_store)/frozen-$id.tsv"
  [ -f "$f" ] || return 1
  printf '%s\n' "$f"
}

# --- 载荷摘要 ----------------------------------------------------------------

# 单根摘要。用 `%p` 而不是 `%P`，且 **cd 到沙箱根**：这样记录里的路径是
# `prefix/work/...` 这种**相对且带根前缀**的形式——既跨沙箱可比对，又不会让
# "把文件从一个载荷根挪到另一个根"看起来什么都没发生。
frozen_root_digest() { # $1=沙箱根 $2=载荷根
  local root="$1" rel="$2"
  (
    cd "$root" || { printf 'unreadable\n'; exit 0; }
    if [ ! -e "$rel" ]; then printf 'absent\n'; exit 0; fi
    {
      printf 'schema\tdsh-termux-payload-root/1\0'
      local name prune=()
      for name in $FROZEN_PAYLOAD_EXCLUDES; do prune+=(-name "$name" -prune -o); done
      find "$rel" -mindepth 1 "${prune[@]}" ! -type f -printf 'n|%p|%m|%l\0'
      find "$rel" -mindepth 1 "${prune[@]}" -type f -printf 'm|%p|%m\0'
      find "$rel" -mindepth 1 "${prune[@]}" -type f -exec sha256sum --zero {} +
    } 2>/dev/null | LC_ALL=C sort -z | sha256sum | cut -d' ' -f1
  )
}

# 整个载荷的合并摘要。每行都带完整相对路径，所以不同根的记录混在一起也不会
# 互相冒充；`payload_digest` 是给签认用的**单一 id**，分根摘要用于归因。
frozen_payload_digest() { # $1=沙箱根
  local root="${1:-}"
  if [ -z "$root" ] || [ ! -d "$root" ]; then printf 'absent\n'; return 0; fi
  (
    cd "$root" || { printf 'unreadable\n'; exit 0; }
    {
      printf 'schema\tdsh-termux-payload-manifest/1\0'
      local rel
      while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        printf 'root\t%s\t%s\0' "$rel" "$(frozen_root_digest "$root" "$rel")"
      done < <(frozen_payload_roots)
    } 2>/dev/null | LC_ALL=C sort -z | sha256sum | cut -d' ' -f1
  )
}

# --- manifest 写入 -----------------------------------------------------------

frozen_dsh_version() { # $1=沙箱根
  local pj="$1/prefix/work/node_modules/@deepseek-ai/dsh/package.json"
  [ -f "$pj" ] || { printf '%s\n' '-'; return 0; }
  sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$pj" | head -n 1
}

frozen_node_version() { # $1=沙箱根（拿不到就记 '-'，绝不猜）
  local n="$1/prefix/node/bin/node" v
  [ -x "$n" ] || { printf '%s\n' '-'; return 0; }
  # bionic 的 LD_PRELOAD 泄漏进 glibc 进程会让它直接起不来——这里只想知道版本，
  # 不值得为此把 launch 环境也搭起来；拿不到就诚实地记 '-'。
  v="$(env -u LD_PRELOAD -u LD_LIBRARY_PATH "$n" --version 2>/dev/null | tr -d '\r\n')"
  printf '%s\n' "${v:--}"
}

# 冻结时的**工作区内容摘要**。刻意在这里现算而不是复用 build receipt 里那份：
# receipt 是**运行开始前**算的，如果跑 case 的过程中源码被改了，复用旧摘要就等于
# 把"这份对象是从哪份源码装出来的"写成了一个当时为真、现在不再为真的值。
# 调用方（run.sh）拿它与 build receipt 的那份比对，不一致就**拒绝冻结**。
frozen_source_digest() {
  receipt_worktree_digest "${DSH_HARNESS_ROOT:?}" "$(frozen_store)/.source-list.txt"
}

frozen_machinery_digest() { # $1=沙箱根：机件（启动器/opener/grun stub）
  local b="$1/bin"
  [ -d "$b" ] || { printf 'absent\n'; return 0; }
  receipt_tree_id "$b"
}

# 写 manifest。成功后 FROZEN_ID / FROZEN_FILE 是出口变量。
# $7=轮次 id（不属于任何轮次时传 '-'；只有 verify 开出的轮次才能被 finalize 终结）。
# 任何一步写不进去都返回非零——**必要证据写不进去，本次结论就不成立**（ADR-009）。
frozen_write() { # $1=沙箱根 $2=case id $3=class $4=人工清单(逗号或-) $5=run id $6=build digest [$7=round id]
  local root="$1" case_id="$2" class="$3" checklists="$4" run_id="$5" build_digest="$6"
  local round_id="${7:--}"
  local sandbox_name; sandbox_name="$(basename "$root")"
  [ -d "$root" ] || { echo "!! frozen: 沙箱不存在: $root" >&2; return 2; }
  local store; store="$(frozen_store)"
  mkdir -p "$store" || return 2

  local tmp="$root/.frozen.tsv.tmp" rel d
  local src; src="$(frozen_source_digest)" || return 2
  # 源码在本次运行**期间**变过的话，这份对象到底是从哪份源码装出来的就说不清了
  # （build receipt 是运行开始前算的）。宁可拒绝冻结，也不要写一个当时为真、
  # 现在已经不成立的"来源"。
  if [ -n "${DSH_BUILD_RECEIPT:-}" ] && [ -f "${DSH_BUILD_RECEIPT:-}" ]; then
    local at_start
    at_start="$(sed -n 's/^worktree_digest\t//p' "$DSH_BUILD_RECEIPT" | head -n 1)"
    if [ -n "$at_start" ] && [ "$at_start" != "$src" ]; then
      echo "!! frozen: 工作区内容在本次运行期间变过" >&2
      echo "   build receipt(开始时): $at_start" >&2
      echo "   冻结时:                $src" >&2
      return 3
    fi
  fi
  {
    printf 'schema\t%s\n' "$FROZEN_SCHEMA"
    printf 'case_id\t%s\n' "$case_id"
    printf 'case_class\t%s\n' "$class"
    printf 'checklists\t%s\n' "$checklists"
    printf 'run_id\t%s\n' "$run_id"
    printf 'round_id\t%s\n' "$round_id"
    printf 'build_digest\t%s\n' "$build_digest"
    printf 'source_worktree_digest\t%s\n' "$src"
    printf 'harness_identity\t%s\n' "${DSH_HARNESS_IDENTITY:--}"
    printf 'dsh_version\t%s\n' "$(frozen_dsh_version "$root")"
    printf 'node_version\t%s\n' "$(frozen_node_version "$root")"
    printf 'sandbox_name\t%s\n' "$sandbox_name"
    printf 'payload_roots\t%s\n' "$(frozen_payload_roots | paste -sd, -)"
    printf 'payload_excludes\t%s\n' "$FROZEN_PAYLOAD_EXCLUDES"
    local i=0
    while IFS= read -r rel; do
      [ -n "$rel" ] || continue
      d="$(frozen_root_digest "$root" "$rel")"
      printf 'payload_root_%d\t%s\n' "$i" "$rel"
      printf 'payload_root_digest_%d\t%s\n' "$i" "$d"
      i=$((i + 1))
    done < <(frozen_payload_roots)
    # 合并摘要**必须**用与 frozen_object_ok 同一个函数算，不能在这里另拼一遍：
    # 两处各写一次"合并"，比较的就是两个不同算法的输出，任何对象都会被判成漂移。
    printf 'payload_digest\t%s\n' "$(frozen_payload_digest "$root")"
  } > "$tmp" || { echo "!! frozen: 无法写 $tmp" >&2; return 2; }

  local id; id="$(sha256sum "$tmp" | cut -d' ' -f1)"
  local dest="$store/frozen-$id.tsv"
  # 内容寻址: 同一个 id 的内容必然相同，"已存在就不覆盖"是安全的。
  [ -f "$dest" ] || mv "$tmp" "$dest" || { echo "!! frozen: 无法写 $dest" >&2; return 2; }
  rm -f "$tmp"
  # 沙箱里的定位副本：serve 用它确认"这个沙箱就是该 manifest 描述的那个对象"。
  cp "$dest" "$root/frozen.tsv" || { echo "!! frozen: 无法写 $root/frozen.tsv" >&2; return 2; }

  # 出口变量，由调用者（run.sh）读取并打印/登记；本文件里读不到它们。
  # shellcheck disable=SC2034
  FROZEN_ID="$id"
  # shellcheck disable=SC2034
  FROZEN_FILE="$dest"
  return 0
}

# --- 漂移判定 ----------------------------------------------------------------

# 0 一致 / 1 对象漂移（差异打到 stderr）/ 2 框架错误
# 只比**载荷**：人类实测会写 home/tmp/ws，把它们算进来就是每次必红。
frozen_object_ok() { # $1=沙箱根 $2=manifest 文件
  local root="$1" mf="$2" rel want got bad=0
  [ -f "$mf" ] || { echo "!! frozen: manifest 不存在: $mf" >&2; return 2; }
  [ -d "$root" ] || { echo "!! frozen: 沙箱不存在: $root" >&2; return 2; }
  local i=0
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    want="$(frozen_get "$mf" "payload_root_digest_$i")"
    got="$(frozen_root_digest "$root" "$rel")"
    if [ "$want" != "$got" ]; then
      echo "!! 冻结载荷漂移: $rel" >&2
      echo "   冻结于: ${want:-<缺>}" >&2
      echo "   现在:   $got" >&2
      bad=1
    fi
    i=$((i + 1))
  done < <(frozen_payload_roots)
  [ "$bad" = 0 ] || return 1
  want="$(frozen_get "$mf" payload_digest)"
  got="$(frozen_payload_digest "$root")"
  if [ "$want" != "$got" ]; then
    echo "!! 冻结载荷合并摘要不符: 冻结 ${want:-<缺>}, 现在 $got" >&2
    return 1
  fi
  return 0
}

# 0 一致 / 1 源漂移（工作区内容已不是冻结时那份）/ 2 框架错误
frozen_source_ok() { # $1=manifest 文件
  local mf="$1" want got
  want="$(frozen_get "$mf" source_worktree_digest)"
  [ -n "$want" ] && [ "$want" != "-" ] || { echo "!! frozen: manifest 缺 source_worktree_digest" >&2; return 2; }
  got="$(frozen_source_digest)" || return 2
  [ "$want" = "$got" ] && return 0
  echo "!! 源漂移: 当前工作区内容已不是冻结这个对象时的那份" >&2
  echo "   冻结于: $want" >&2
  echo "   现在:   $got" >&2
  return 1
}

# --- 观察台账（人工证据的落盘处） --------------------------------------------

# 只追加。**时间属于这里，不属于对象身份**。
# phase=start/end：serve 启动前与实测结束后各记一行，两次都要 check=ok——
# 只有"开始校验过"证明不了实测过程中对象没被换掉（评审要求）。
frozen_observe_log() { printf '%s\n' "$(frozen_store)/observations.tsv"; }

frozen_observe_append() { # $1=phase $2=obs id $3=round id $4=case id $5=checklist $6=check $7=note
  local store file
  store="$(frozen_store)"
  mkdir -p "$store" || return 2
  file="$store/observations.tsv"
  [ -f "$file" ] || printf 'at\tobs_id\tround_id\tcase_id\tbuild_digest\tpayload_digest\tchecklist\tphase\tcheck\tnote\n' > "$file"
  local mf build payload
  mf="$(frozen_resolve "$2" 2>/dev/null || true)"
  build="-"; payload="-"
  if [ -n "$mf" ]; then
    build="$(frozen_get "$mf" build_digest)"
    payload="$(frozen_get "$mf" payload_digest)"
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date '+%F %R%:z')" "${2:--}" "${3:--}" "${4:--}" "${build:--}" "${payload:--}" \
    "${5:--}" "${1:--}" "${6:--}" "$(printf '%s' "${7:-}" | tr '\t\n' '  ')" >> "$file"
}

# 某对象是否已有**完整**（start 与 end 都 ok）的观察。0=有 / 1=没有
frozen_observed_ok() { # $1=obs id
  local file; file="$(frozen_observe_log)"
  [ -f "$file" ] || return 1
  awk -F'\t' -v id="$1" '
    $2 == id && $8 == "start" && $9 == "ok" { s = 1 }
    $2 == id && $8 == "end"   && $9 == "ok" { e = 1 }
    END { exit (s && e) ? 0 : 1 }' "$file"
}

# 列出盘上所有带 manifest 的沙箱（一行一个：沙箱名<TAB>manifest 路径）
frozen_each_sandbox() {
  local d mf
  for d in "$DSH_TI_DIR"/sandbox-*; do
    [ -d "$d" ] || continue
    mf="$d/frozen.tsv"
    [ -f "$mf" ] || continue
    printf '%s\t%s\n' "$(basename "$d")" "$mf"
  done
}
