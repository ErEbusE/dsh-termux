#!/data/data/com.termux/files/usr/bin/bash
# seed.sh — 种子的唯一实现（`run.sh seed …` 与前置判定共用）。
#
# 种子 = 「某个**已发布**的 dsh-termux 发布物」被钉住的那份事实：tag + 资产
# 及其 sha256。它是大量 case 的输入（`baseline-seed` / `release-seed`），所以
# 它的纪律就是"绝不手编、哈希现算、写盘原子"。
#
# 与旧 `baseline.env` 的三点差别（ADR-004）:
#   1. 可以**并存多个**种子（`seeds/<name>.env`）。旧种子不因发版而淘汰——
#      每次追 pin 都会消灭一批旧版本的升级覆盖窗口，那是覆盖面的净损失。
#   2. 种子变更**走 review**，不再有"机械 re-pin 可直推 main"的豁免：
#      pin 改变的是"测试覆盖哪些版本"的判断，不是纯派生数据。
#   3. 资产落 `seeds/seed-assets/`（仍 ignore，~100MB），事实源文件随代码入库。
#
# ── 资产存储：**内容寻址**（2026-09-15 起；顾问裁决 ＋ 实测复现的缺陷）───────
# 曾经按 `<资产名>` 扁平存放，而发布资产名是**跨 tag 固定**的
# （`dsh-termux-runtime.tar.gz` / `install.sh`），于是：
#   * 加第二颗种子会**静默覆盖**第一颗的字节（两个 .env 都在，却只有一份字节）——
#     ADR-004"旧种子保留"在**记录层**成立、**字节层**被违反；
#   * `seed_fetch_assets` 的 `.part`→`mv` 是**逐资产**原子的，不是**每颗种子**原子的：
#     re-pin 时资产 1 已 mv、资产 2 下载失败 → `seed_write_env` 不执行，`.env` 仍是旧
#     pin，而旧字节已变 → 先前全绿的种子变红，且**两个 tag 都没有有效 pin**（这不依赖
#     多种子）。
# 现在每个对象落在 `seed-assets/<sha256>/<资产名>`：**内容决定路径**，所以
#   内容不同的资产永不互相覆盖；同一份内容天然去重；路径本身不是信任依据
#   （读之前一律重新现算并与目录名核对，不符即**响亮失败**、绝不覆盖）。
# 发布规则（同址修复）：先下到私有 staging，逐件校验后**只新增**对象，**最后**才写
# `.env`——所以一次失败的 pin 绝不可能破坏已有种子。
#
# 两条踩过的坑，写在这里不许再犯:
#   * **绝不 `wget -c`**：对不同 tag 的同名旧文件续传，会经代理拼出"新包+旧尾"
#     的损坏文件；若 pin 又由这个坏文件现算，还会自洽放行。
#   * **先下到 `.part` 再原子替换**：直接 `-O` 到目标名会在下载失败**之前**就把
#     已有的好文件截断成 0 字节，一次打错 tag 就能毁掉已 pin 的资产。

set -uo pipefail

SEED_ASSETS_DEFAULT="dsh-termux-runtime.tar.gz install.sh"

seed_repo_slug() { # -> owner/repo，取自 git remote（拿不到时回落到本仓库）
  local url slug
  url="$(git -C "${DSH_HARNESS_ROOT:-.}" remote get-url origin 2>/dev/null || true)"
  slug="$(printf '%s' "$url" | sed -n 's#.*github\.com[:/]\([^/]*/[^/]*\)$#\1#p' | sed 's/\.git$//')"
  [ -n "$slug" ] || slug="ErEbusE/dsh-termux"
  printf '%s\n' "$slug"
}

# tag 形态: dsh-<dsh版本>-<项目版本>（稳定）或 pre-dsh-…（pre 渠道，prerelease）
resolve_release_tag() { # $1=tag|latest -> 具体 tag
  local t="${1:-latest}" slug loc
  case "$t" in
    latest)
      command -v curl >/dev/null 2>&1 || {
        echo "!! 解析 latest 需要 curl, 或改用 seed set <具体tag>" >&2; return 1; }
      slug="$(seed_repo_slug)"
      # 走 releases/latest 的 302：免 token、不吃 API 配额、也不需要 jq。
      loc="$(curl -sIo /dev/null -w '%{redirect_url}' \
        "https://github.com/$slug/releases/latest")"
      t="${loc##*/}"
      case "$t" in
        dsh-*-*-*) ;;
        *) echo "!! 无法解析 latest 指向的实际 tag (got: ${loc:-<空>})" >&2; return 1 ;;
      esac ;;
    dsh-*-*-*|pre-dsh-*-*-*) ;;
    *) echo "!! 非法 tag: $t" >&2; return 1 ;;
  esac
  printf '%s\n' "$t"
}

# dsh-<dsh版本>-<项目版本> -> <dsh版本>。两个 local 分开写是刻意的：
# bash 在执行 local 前就把整行的赋值词展开完，写成一行会取到调用者作用域的值
# （今天的调用点恰好同值才一直看着是对的，shellcheck SC2318）。
seed_dsh_version() {
  local tag="$1"
  local pv="${tag##*-}"
  printf '%s\n' "${tag#dsh-}" | sed "s/-$pv\$//"
}

seed_dir() { printf '%s\n' "${DSH_TI_DIR:?seed_dir: DSH_TI_DIR 未设置}/seeds"; }
seed_assets_dir() { printf '%s\n' "$(seed_dir)/seed-assets"; }
seed_env_path() { printf '%s\n' "$(seed_dir)/${1:?seed_env_path: 需要种子名}.env"; }

# ── 资产记录的**唯一**解析入口（形状校验也在这里，只此一份）──────────────────
# 为什么必须校验形状：`.env` 里那两段都会被拼成**路径**，而 `.env` 是普通文本文件。
# 一个写错的/被改过的条目（`SEED_ASSET_1=../../victim/x:<hash>`）过去能一路拼出
# `seed-assets/<sha>/../../victim/x`，把 `seed_migrate_legacy` 的 mv/rm 引到**库外**
# （2026-09-15 实测复现：库外的文件真的被移走）。所以形状不合法的条目在这里就被
# 判为**事实源损坏**，绝不参与任何路径拼接。
#   资产名：必须是**纯 basename**（不含 `/`、不含 `..`、只允许保守字符集）。
#           刻意**不**去比对"发布约定里那两种资产名"——那是发布侧的事实（由
#           SEED_ASSETS_DEFAULT 决定），库要保持对任意合法 basename 通用；穿越的
#           防线是"只允许 basename"，不是白名单。
#   sha256：必须 64 位小写十六进制
seed_rec_parts() { # $1=记录 -> stdout "资产名<TAB>sha256"；形状非法返回 1
  local rec="${1:-}" a want
  case "$rec" in
    *:*) a="${rec%%:*}"; want="${rec##*:}" ;;
    *) return 1 ;;
  esac
  case "$a" in
    ''|*/*|*..*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  case "$want" in
    *[!0-9a-f]*|'') return 1 ;;
  esac
  [ "${#want}" -eq 64 ] || return 1
  printf '%s\t%s\n' "$a" "$want"
}

# 内容寻址：<assets>/<sha256>/<资产名>。
# **构造函数自己把关**（不靠注释、不靠调用方自觉）：两段形状不对就返回 1，绝不
# 产出路径。理由见 seed_rec_parts 上方的注释——`.env` 是普通文本，一个越界条目
# 曾把 `seed_migrate_legacy` 的 mv/rm 引到库外。
seed_cas_path() { # $1=sha256 $2=资产名 -> stdout 路径；形状非法返回 1
  local sum="${1:-}" name="${2:-}"
  case "$sum" in
    *[!0-9a-f]*|'') return 1 ;;
  esac
  [ "${#sum}" -eq 64 ] || return 1
  case "$name" in
    ''|*/*|*..*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  printf '%s\n' "$(seed_assets_dir)/$sum/$name"
}

seed_names() { # -> 已存在的种子名，每行一个
  local f
  for f in "$(seed_dir)"/*.env; do
    [ -f "$f" ] || continue
    basename "$f" .env
  done
}

# 全新完整下载两个发布资产到 $2。绝不续传；先 .part 再 mv。
# $2 应当是**私有 staging**（发布流程里就是），不是 CAS 根。
seed_fetch_assets() { # $1=tag $2=目标目录
  local tag="$1" dl="$2" slug a tmp url
  slug="$(seed_repo_slug)"
  command -v wget >/dev/null 2>&1 || { echo "!! 需要 wget 下载发布资产" >&2; return 1; }
  mkdir -p "$dl" || return 1
  for a in $SEED_ASSETS_DEFAULT; do
    url="https://github.com/$slug/releases/download/$tag/$a"
    tmp="$dl/.$a.part"
    rm -f "$tmp"
    if ! wget -t 2 -O "$tmp" "$url"; then
      rm -f "$tmp"
      echo "!! 下载 $a 失败 (tag=$tag)" >&2
      echo "   网络受限时先 export https_proxy/http_proxy；已 pin 的旧资产未被破坏。" >&2
      return 1
    fi
    mv -f "$tmp" "$dl/$a" || return 1
  done
  return 0
}

seed_sha256() { # $1=file -> sha256（拿不到时返回 1，绝不用空串冒充）
  [ -f "$1" ] || return 1
  sha256sum "$1" | cut -d' ' -f1
}

# 把 staging 里的资产**只新增**地放进 CAS，逐件输出 "<资产名>:<sha256>"。
# 已存在的对象必须与自身目录名相符，否则响亮失败——**绝不**覆盖：
# 目录名是哈希，覆盖它等于让"路径即身份"这条依据失效。
seed_install_cas() { # $1=staging 目录 $2..=资产名
  local stage="$1"; shift
  local a src sum dst
  for a in "$@"; do
    src="$stage/$a"
    [ -f "$src" ] || { echo "!! staging 里缺 $a" >&2; return 1; }
    sum="$(seed_sha256 "$src")" || { echo "!! 无法计算 $a 的 sha256" >&2; return 1; }
    dst="$(seed_cas_path "$sum" "$a")" || {
      echo "!! $a 无法构成合法的 CAS 路径（形状非法）—— 拒绝入库" >&2; return 1; }
    # 目标存在但**不是普通文件**（最可能是个目录）：`mv` 会把源**塞进**那个目录里
    # （mv src dir/ → dir/src），而记录照常发布——于是路径与内容对不上。
    # 这条路径要么是普通文件（下面比内容），要么干脆不存在；别的形态一律拒绝。
    if [ -e "$dst" ] && [ ! -f "$dst" ]; then
      echo "!! CAS 目标已存在但不是普通文件（$dst）—— 拒绝入库，请人工检查存储" >&2
      return 1
    fi
    if [ -f "$dst" ]; then
      if [ "$(seed_sha256 "$dst")" = "$sum" ]; then
        rm -f "$src"                       # 同内容已在库里：丢弃重复下载
      else
        echo "!! CAS 对象内容与目录名不符（$dst）—— 拒绝覆盖，请人工检查存储" >&2
        return 1
      fi
    else
      mkdir -p "$(dirname "$dst")" || return 1
      mv -f "$src" "$dst" || return 1      # 同一文件系统内的原子改名
    fi
    printf '%s:%s\n' "$a" "$sum"
  done
}

# 写事实源。$4.. 是 "<资产名>:<sha256>" 记录（由 seed_install_cas 产出）。
seed_write_env() { # $1=name $2=tag $3=dsh_version
  local name="$1" tag="$2" dshv="$3"; shift 3
  local dir tmp n=0 rec
  dir="$(seed_dir)"; mkdir -p "$dir" || return 1
  tmp="$dir/.$name.env.tmp"
  {
    echo "# seeds/$name.env — 种子发布物的唯一事实源。"
    echo "# 生成: bash .test-install/run.sh seed set <tag|latest> $name"
    echo "# 不要手编：哈希一律现算，改 pin 走 review（DECISIONS.md ADR-004）。"
    echo "SEED_NAME=$name"
    echo "SEED_TAG=$tag"
    echo "SEED_DSH_VERSION=$dshv"
    for rec in "$@"; do
      case "$rec" in
        *:*) ;;
        *) echo "!! seed_write_env: 记录必须形如 <资产名>:<sha256>（got: $rec）" >&2; return 1 ;;
      esac
      n=$((n + 1))
      echo "SEED_ASSET_$n=$rec"
    done
  } > "$tmp" || return 1
  mv -f "$tmp" "$dir/$name.env" || return 1
  return 0
}

# 读一条 pin 的资产记录 -> 每行 "<资产名>:<sha256>"
# 读事实源里的资产记录，**逐条过形状校验**，只输出可用的 `资产名<TAB>sha256`。
# 非法条目输出为 `!MALFORMED!<TAB><原文>`：第一段是个不可能与真实资产名相撞的哨兵，
# 于是所有消费者（resolve / verify / load / migrate）都把它当"事实源损坏"（ERROR）
# 而不是去拼路径。
# 为什么要哨兵而不是空名（**实测坑**）：`read` 的 IFS 会把**制表符当空白**吞掉，
# 前导制表符会让字段整体左移——空名标记会静默失效、把原文读进 `a`。用非空哨兵才稳。
# 也不用全局计数器：本函数总是经进程替换 `< <(...)` 调用，子 shell 里的计数传不出来。
seed_records() { # $1=env 文件
  local rec parsed
  while IFS= read -r rec; do
    [ -n "$rec" ] || continue
    if parsed="$(seed_rec_parts "$rec")"; then
      printf '%s\n' "$parsed"
    else
      echo "!! 非法的资产记录（形状不符，判为事实源损坏）: $rec" >&2
      printf '%s\t%s\n' "$SEED_REC_MALFORMED" "$rec"
    fi
  done < <(sed -n 's/^SEED_ASSET_[0-9]*=//p' "${1:?seed_records: 需要 env 文件}")
}

# 非法记录的哨兵；消费者只需比一次（见 seed_rec_is_bad）。
readonly SEED_REC_MALFORMED='!MALFORMED!'
seed_rec_is_bad() { [ "${1:-}" = "$SEED_REC_MALFORMED" ]; }

# 把一个记录解析到本地实际路径（CAS 优先；过渡期容忍旧扁平位置）。
# 输入必须是 seed_records 输出的**已校验**形式 "资产名<TAB>sha256"。
# 输出路径；找不到返回 3（缺对象），内容不符返回 1，读不了返回 2。
seed_resolve_record() { # $1=seed_records 输出的记录
  local a want p lp got
  IFS=$'\t' read -r a want <<<"${1:-}"
  seed_rec_is_bad "$a" && { echo "资产记录形状非法（判为事实源损坏）" >&2; return 2; }
  [ -n "$want" ] || { echo "资产记录缺 sha256（判为事实源损坏）" >&2; return 2; }
  p="$(seed_cas_path "$want" "$a")" || {
    echo "资产记录无法构成合法的 CAS 路径（判为事实源损坏）" >&2; return 2; }
  if [ ! -f "$p" ]; then
    lp="$(seed_assets_dir)/$a"
    if [ -f "$lp" ] && [ "$(seed_sha256 "$lp")" = "$want" ]; then
      echo "note: $a 仍在旧的扁平位置（$lp）—— 跑 \`run.sh seed migrate\` 归位" >&2
      printf '%s\n' "$lp"; return 0
    fi
    echo "缺少种子资产: $a (pin=${want:0:12}…) 期望 $p" >&2
    return 3
  fi
  got="$(seed_sha256 "$p")" || { echo "无法读取 $p" >&2; return 2; }
  [ "$got" = "$want" ] || {
    echo "种子资产哈希不符: $a (现算=${got:0:12}… pin=${want:0:12}…)" >&2; return 1; }
  printf '%s\n' "$p"
}

# 严重度合并：把两条"四条返回码"里的坏消息取最坏的一条。
# 有序性是 ADR-003 的（ERROR > FAIL > UNMET），不是本库发明的；**这条梯子只写在这里
# 一份**——原先 seed_verify 与 seed_load 各写一遍，属重复政策（顾问审计 R3）。
# 注意 3(UNMET) 数值最大但**最轻**，所以不能用 max/算术，只能显式排序。
# $1=当前码 $2=新码 -> stdout 合并后的码
seed_worst() { # 0=好 / 1=FAIL / 2=ERROR / 3=UNMET
  local cur="${1:-0}" new="${2:-0}"
  case "$cur" in
    2) printf '2\n'; return ;;
  esac
  case "$new" in
    2) printf '2\n' ;;
    1) printf '1\n' ;;
    3) [ "$cur" = 1 ] && printf '1\n' || printf '3\n' ;;
    *) printf '%s\n' "$cur" ;;
  esac
}

# 只报告不改状态。与 seed_load 同一套四分语义：
#   0 = 全部就位且哈希相符 / 1 = 现算与 pin 不符(FAIL) / 2 = 事实源或校验工具坏(ERROR)
#   3 = 缺事实源或缺对象(UNMET)
# ⚠ `local` 声明必须**独占一行**：曾因为一次"去空行"的编辑把它拼进上面那行注释里，
# 声明被整行吞掉 —— `bash -n` 与 shellcheck 都不报（语法完全合法），只在 `set -u`
# 下以 `rc: unbound variable` 现形（首跑 `seed set` 实测撞到）。改动本函数时看住它。
seed_verify() { # $1=name
  local name="$1" f rc=0 rec a want p r n_rec=0
  f="$(seed_env_path "$name")"
  [ -f "$f" ] || { echo "MISSING: seeds/$name.env 不存在"; return 3; }
  [ -n "$(sed -n 's/^SEED_TAG=//p' "$f")" ] || { echo "BROKEN: $f 缺 SEED_TAG"; return 2; }
  # SEED_DSH_VERSION 与 SEED_TAG 同为**必需**字段（seed_load 也这么判）：缺了它们，
  # 事实源就是损坏的，而且消费者拿不到它声明的 dsh 版本。判据必须三处一致，
  # 否则 `seed list` / `seed show` 会对一颗 load 必判 ERROR 的种子报"资产齐、哈希相符"
  # （评审 claim 5 实测的分类分歧）。
  [ -n "$(sed -n 's/^SEED_DSH_VERSION=//p' "$f")" ] || { echo "BROKEN: $f 缺 SEED_DSH_VERSION"; return 2; }
  while IFS= read -r rec; do
    [ -n "$rec" ] || continue
    IFS=$'\t' read -r a want <<<"$rec"
    if seed_rec_is_bad "$a"; then
      echo "ASSET-MALFORMED: $want"
      rc="$(seed_worst "$rc" 2)"
      continue
    fi
    n_rec=$((n_rec + 1))
    if p="$(seed_resolve_record "$rec" 2>/dev/null)"; then
      echo "ASSET-OK: $a"
    else
      r=$?
      case "$r" in
        3) echo "ASSET-MISSING: $a (pin=${want:0:12}…)" ;;
        1) echo "ASSET-CHANGED: $a" ;;
        *) echo "ASSET-UNREADABLE: $a" ;;
      esac
      rc="$(seed_worst "$rc" "$r")"
    fi
  done < <(seed_records "$f")
  # 一条资产条目都没有 = 事实源损坏（ERROR），不是"齐备"：这与 seed_load 的同名规则
  # **必须一致**，否则 `seed list` / `seed show` 会对一颗根本不可用的种子报"资产齐、
  # 哈希相符"，而实际消费它的 case 会以 ERROR 收场（评审 NEW-1 实测的分类分歧）。
  [ "$n_rec" -gt 0 ] || { echo "BROKEN: $f 没有任何资产条目"; return 2; }
  return "$rc"
}

# case 消费种子的事实源入口。**唯一入口**，不许 case 自己 sed 解析 —— 哈希核对是
# 结论的一部分（映射表 A.1/L2：`state_check_require seed:*` 只判存在性，哈希归 case），
# 让每个 case 各写一遍的结果是迟早有一个忘了核。
#
# seed_default_name -> 默认为 `stable`；`DSH_SEED_NAME` 可指另一颗种子（run.sh 把它
# 作为契约变量钉进 case 环境）。注册表的 `baseline-seed` / `release-seed` 说的是
# "需要一份发布物种子"，具体是哪一颗由这个名字决定，不由 case 猜。
seed_default_name() { printf '%s\n' "${DSH_SEED_NAME:-stable}"; }

# seed_load <name> -> 设置 SEED_NAME / SEED_TAG / SEED_DSH_VERSION / SEED_ASSETS[]（绝对路径）。
# 返回码（顾问裁决的四分，调用方**必须**分开归类，见 ADR-003）：
#   0 = 全部就位且哈希相符
#   1 = **FAIL**：对象在、但现算与 pin 不符（验证完成、结论否定）
#   2 = **ERROR**：事实源损坏 / 哈希工具失败等"校验根本没跑成"
#   3 = **UNMET**：缺事实源或缺对象（缺可测输入，不是被测对象的结论）
# 只有**完全通过**后才把 SEED_ASSETS 交出去：部分路径绝不许泄漏给调用方。
seed_load() {
  local name="${1:-$(seed_default_name)}"
  local f rec p rc=0 n_rec=0 n_ok=0 a want
  local -a paths=()
  # 契约变量清零：**逐字段解析而不是 source**，避免 SEED_ASSET_n 之类的旧变量
  # 残留在调用者作用域里（上一个种子留下的路径是最危险的一种残留）。
  # 注意 SEED_NAME 仍是本库的**公开输出**（文档与 `seed_default_name` 的注释都提到它），
  # 只是当前没有消费点——shellcheck 看不见"谁在用"，故在此显式说明并逐条禁用。
  SEED_ASSETS=()
  # shellcheck disable=SC2034  # SEED_NAME 是给调用方/调试用的公开输出，见上
  SEED_NAME=""
  SEED_TAG=""
  SEED_DSH_VERSION=""
  f="$(seed_env_path "$name")"
  [ -f "$f" ] || { echo "缺少种子事实源 $f（生成: run.sh seed set <tag|latest> $name）" >&2; return 3; }
  # shellcheck disable=SC2034  # 同上
  SEED_NAME="$name"
  SEED_TAG="$(sed -n 's/^SEED_TAG=//p' "$f")"
  SEED_DSH_VERSION="$(sed -n 's/^SEED_DSH_VERSION=//p' "$f")"
  [ -n "$SEED_TAG" ] || { echo "$f 缺 SEED_TAG" >&2; return 2; }
  [ -n "$SEED_DSH_VERSION" ] || { echo "$f 缺 SEED_DSH_VERSION" >&2; return 2; }
  while IFS= read -r rec; do
    [ -n "$rec" ] || continue
    IFS=$'\t' read -r a want <<<"$rec"
    if seed_rec_is_bad "$a"; then
      echo "ASSET-MALFORMED: $want"
      rc="$(seed_worst "$rc" 2)"   # 形状非法 = 事实源损坏（ERROR），不参与任何路径拼接
      continue
    fi
    n_rec=$((n_rec + 1))
    if p="$(seed_resolve_record "$rec")"; then
      paths+=("$p"); n_ok=$((n_ok + 1))
    else
      rc="$(seed_worst "$rc" "$?")"     # 梯子只有 seed_worst 一份（见其注释）
    fi
  done < <(seed_records "$f")
  [ "$n_rec" -gt 0 ] || { echo "$f 没有任何资产条目" >&2; return 2; }
  # 只有完全通过才交出去：部分路径绝不许泄漏给调用方（否则调用方可能拿到半份资产
  # 就开始跑，结论却算在"种子可用"头上）。
  if [ "$rc" = 0 ] && [ "$n_ok" -ne "$n_rec" ]; then rc=2; fi
  [ "$rc" != 0 ] || SEED_ASSETS=("${paths[@]}")
  return "$rc"
}

# seed_asset_by_name <basename>：从 SEED_ASSETS 里按文件名取路径（拿不到返回 1）。
# 资产名（dsh-termux-runtime.tar.gz / install.sh）是发布约定，不是这里发明的。
seed_asset_by_name() {
  local want="$1" p
  for p in ${SEED_ASSETS[@]+"${SEED_ASSETS[@]}"}; do
    [ "${p##*/}" = "$want" ] && { printf '%s\n' "$p"; return 0; }
  done
  return 1
}

# seed_load_require <name>：把 seed_load 的返回码按 ADR-003 归类并**终止 case**。
# 这层存在的唯一理由：原先有 10 个 case 各写一遍 switch（共 11 个调用点）必然漂移（顾问明确警告过
# "generic nonzero-to-FAIL mappings"会保留误分类），所以映射只有这一份。
# 依赖 state.sh 的 case_*（调用方必须已经 source 它）；三个分支都会 exit。
seed_load_require() {
  local name="${1:-$(seed_default_name)}" rc=0
  seed_load "$name" || rc=$?
  case "$rc" in
    0) return 0 ;;
    1) # 对象在、现算与 pin 不符 = 验证完成、结论否定 -> FAIL
       assert_fail "种子不可用：资产存在，但现算与事实源 pin 不符（见上文原因）"
       case_finish ;;
    3) # 缺事实源/缺对象 = 缺可测输入，不是被测对象的结论 -> UNMET
       case_unmet "缺少种子事实源或资产（run.sh seed set 生成）—— 缺可测输入，不是被测对象的结论" ;;
    *) # 只剩 2 = 校验根本没跑成（事实源损坏 / 哈希工具失败）-> ERROR
       case_error "种子事实源或校验自身损坏（生成/配置故障），不是被测对象的结论" ;;
  esac
}

# staging 目录形如 `<assets>/.staging.<pid>`。下载中途被杀（SIGINT/SIGTERM/timeout）
# 会让它留下——可能是一份 110MB 的半成品，所以下次开跑时收掉。
#
# 判定用 `kill -0`：进程还在就不动它。**已知的边界（接受）**：跨用户时 `kill -0`
# 会以 EPERM 失败，与"进程不存在"无法用 shell 可移植地区分，于是那种情形下会误删
# 别人的 staging。本 harness 是单人设备上的本地工具（同一 uid），故接受该边界；
# 若将来要多人共用，应改成在 staging 里放一个带 uid/host 的标记文件再判定。
seed_prune_stale_staging() {
  local d pid n=0
  for d in "$(seed_assets_dir)"/.staging.*; do
    [ -d "$d" ] || continue
    pid="${d##*.}"
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    kill -0 "$pid" 2>/dev/null && continue      # 进程还在：不是垃圾
    rm -rf "$d" && n=$((n + 1))
  done
  [ "$n" -gt 0 ] && echo "==> 清理了 $n 个上次遗留的 staging 目录（下载中断）" >&2
  return 0
}

# staging 目录名是**本库**的事实（`seed_prune_stale_staging` 要 glob 它、发布流程要
# 建它）：名字只在这里定义一次，别让 run.sh 也拼一遍。
seed_staging_dir() { printf '%s\n' "$(seed_assets_dir)/.staging.$$"; }

# 被 Ctrl-C / SIGTERM（含 timeout）打断时收掉自己的 staging，并**以 128+signum 退出**。
# 为什么非要 `exit`：bash 的 trap 处理函数返回后脚本会**继续往下跑**，于是"被 SIGTERM
# 杀掉"会变成"跑完并以 0 退出"——那比留下垃圾更糟（实测：只写 rm 不写 exit，信号之后
# 后续语句照样打印、外层看到 exit=0）。
seed_trap_install() { # $1=staging 目录
  # shellcheck disable=SC2064  # 故意在此刻展开路径
  trap "rm -rf '$1'; exit 130" INT
  # shellcheck disable=SC2064
  trap "rm -rf '$1'; exit 143" TERM
  # shellcheck disable=SC2064
  trap "rm -rf '$1'; exit 129" HUP
}
seed_trap_clear() { trap - INT TERM HUP; }

# 发布一条新 pin：占用名检查 → 私有 staging 下载 → 逐件校验 → 只新增对象 → **最后**
# 才写 `.env`。任何一步失败都不改动已有种子（这是勿回退 #24 的落地形态）。
# 返回 0=成功 / 1=失败（失败原因已打印）。
seed_publish() { # $1=name $2=tag $3=force(0/1)
  local name="${1:?seed_publish: 需要种子名}"
  local tag="${2:?seed_publish: 需要 tag}"
  local force="${3:-0}"
  local envf old_tag stage records

  case "$name" in
    ''|*[!a-z0-9._-]*) echo "!! 非法种子名: $name" >&2; return 1 ;;
  esac

  # **不许在占用名下静默换 pin**（ADR-004：旧 pin 记录本身就是要保留的输入——追新
  # pin 会消灭旧版本的升级覆盖窗口，而"孤儿字节"没有版本关联、不算旧种子）。
  envf="$(seed_env_path "$name")"
  if [ -f "$envf" ] && [ "$force" != 1 ]; then
    old_tag="$(sed -n 's/^SEED_TAG=//p' "$envf")"
    if [ "$old_tag" != "$tag" ]; then
      echo "!! 种子名 '$name' 已被占用：$old_tag" >&2
      echo "   ADR-004 要求旧种子**保留**，所以在同名下换 pin 默认被拒绝。" >&2
      echo "   请换一个名字新增：bash .test-install/run.sh seed set $tag <新名>" >&2
      echo "   （确实要重钉同一个 tag，例如上游重发资产时才用 --force。）" >&2
      return 1
    fi
  fi

  seed_prune_stale_staging            # 上次被杀留下的半成品可能占 110MB
  stage="$(seed_staging_dir)"
  rm -rf "$stage"; mkdir -p "$stage" || return 1
  seed_trap_install "$stage"
  echo "==> 下载 $tag 的发布物到 staging …"
  if ! seed_fetch_assets "$tag" "$stage"; then
    rm -rf "$stage"; seed_trap_clear; return 1
  fi
  if ! records="$(seed_install_cas "$stage" $SEED_ASSETS_DEFAULT)"; then
    echo "!! 无法把资产归入内容寻址存储（已有种子未被改动）" >&2
    rm -rf "$stage"; seed_trap_clear; return 1
  fi
  # 生产写到这一步为止：staging 已收、trap 已清，再写 `.env`。清 trap 是刻意的——
  # 之后中断只会留下一个已入库的对象（可复用、不破坏任何种子），不该再谎报为"被信号中断"。
  rm -rf "$stage"; seed_trap_clear
  # 记录是每行一条 "<资产名>:<sha256>"（冒号分隔，与 seed_install_cas 的输出一致），
  # 两段都无空白，故按词拆分。
  # shellcheck disable=SC2086
  if ! seed_write_env "$name" "$tag" "$(seed_dsh_version "$tag")" $records; then
    echo "!! 写 seeds/$name.env 失败（资产已入库，可重试；已有种子未被改动）" >&2
    return 1
  fi
  echo "==> seeds/$name.env 已写入"
  seed_verify "$name"
}

# 前置判定用的"种子在不在"（**只判存在性，绝不核对哈希**——那是 case 的结论，
# 见 state.sh 的 state_check_require 头部）。把这条也放进本库，是为了让**存储布局
# 与记录形状只有一份定义**：state.sh 之前自己拼 `<sha>/<名>` 并自己 sed 记录，等于
# 复制了本库的知识，重写布局时那一处会静默误判。
# 返回 0=齐备 / 1=缺件或缺失对象（UNMET）/ 2=**事实源损坏**（ERROR，与 ADR-003 一致）
seed_present() { # $1=name
  local name="${1:?seed_present: 需要种子名}"
  local f rec a want p
  f="$(seed_env_path "$name")"
  [ -f "$f" ] || { echo "缺少种子事实源 seeds/$name.env (run.sh seed set $name <tag> 生成)"; return 1; }
  [ -n "$(sed -n 's/^SEED_TAG=//p' "$f")" ] || { echo "$f 缺 SEED_TAG（事实源损坏）"; return 2; }
  [ -n "$(sed -n 's/^SEED_DSH_VERSION=//p' "$f")" ] \
    || { echo "$f 缺 SEED_DSH_VERSION（事实源损坏）"; return 2; }
  local n_rec=0
  while IFS= read -r rec; do
    [ -n "$rec" ] || continue
    IFS=$'\t' read -r a want <<<"$rec"
    seed_rec_is_bad "$a" && { echo "$f 有形状非法的资产记录（事实源损坏）"; return 2; }
    p="$(seed_cas_path "$want" "$a")" || { echo "$f 有无法构成路径的资产记录（事实源损坏）"; return 2; }
    n_rec=$((n_rec + 1))
    [ -f "$p" ] || [ -f "$(seed_assets_dir)/$a" ] \
      || { echo "缺少种子资产 $a (种子 $name pin 的 sha=${want:0:12}…)"; return 1; }
  done < <(seed_records "$f")
  # 与 seed_load / seed_verify 同一条完整性规则：零条目 = 事实源损坏(ERROR)，
  # 不是"齐备"。三处判据一致是这个委托存在的意义（评审 NEW-1）。
  [ "$n_rec" -gt 0 ] || { echo "$f 没有任何资产条目（事实源损坏）"; return 2; }
  return 0
}

# 把**旧扁平位置**、且与某条 pin 逐字相符的资产移进 CAS。不改任何 `.env`。
# 先核哈希再搬（"恢复必须与旧 pin 相符"）；不符就**不动**并报出来，绝不覆盖/猜测。
# **安全前提**：记录来自 seed_records（已过形状校验），且 seed_cas_path 会再拒一次。
# 这条路径做过 mv/rm，所以它**只**允许操作形状合法的两段拼出来的路径——实测过一个
# 越界条目能把库外的文件移走。
seed_migrate_legacy() {
  local f rec a want src dst moved=0 checked=0 skipped=0
  for f in "$(seed_dir)"/*.env; do
    [ -f "$f" ] || continue
    while IFS= read -r rec; do
      [ -n "$rec" ] || continue
      IFS=$'\t' read -r a want <<<"$rec"
      if seed_rec_is_bad "$a"; then
        echo "!! $(basename "$f") 有形状非法的资产记录，已跳过: $want" >&2
        skipped=$((skipped + 1)); continue
      fi
      src="$(seed_assets_dir)/$a"
      [ -f "$src" ] || continue
      checked=$((checked + 1))
      if [ "$(seed_sha256 "$src")" != "$want" ]; then
        echo "!! $a 与 $(basename "$f") 的 pin 不符（pin=${want:0:12}…）—— 不迁移，人工检查" >&2
        continue
      fi
      dst="$(seed_cas_path "$want" "$a")" || {
        echo "!! $a 无法构成合法的 CAS 路径，已跳过（不迁移、不删除）" >&2
        skipped=$((skipped + 1)); continue; }
      if [ -e "$dst" ] && [ ! -f "$dst" ]; then
        echo "!! CAS 目标 $a 已存在但不是普通文件（$dst）—— 不迁移、不删除旧副本" >&2
        skipped=$((skipped + 1)); continue
      fi
      if [ -f "$dst" ]; then
        # CAS 目标**已存在**时同样必须先核内容（与 seed_install_cas 同一判据）。
        # 实测过的数据损失：目录名是哈希、内容被损坏时（截断/坏盘/手工改动），
        # 唯一还与 pin 相符的好副本就是这份旧扁平文件；过去这里直接 `rm -f "$src"`
        # 就把它删了，还打印"归位"、把计数记成功——**静默毁掉最后一处可恢复的字节**，
        # 状态从"可修复(FAIL=1)"退化成"缺件、无从恢复(UNMET=3)"。
        # 与 seed_install_cas 的差别只在动作：那里是丢弃重复下载，这里是保留旧文件。
        if [ "$(seed_sha256 "$dst")" = "$want" ]; then
          rm -f "$src"                       # 同内容已在库里：旧扁平副本才是多余的
        else
          echo "!! CAS 对象 $a 内容与目录名不符（$dst）—— 不迁移、**不删除**旧副本（$src）" >&2
          echo "   旧副本与 pin 相符，是当前唯一可用的字节；请人工检查存储后再重试。" >&2
          skipped=$((skipped + 1)); continue
        fi
      else
        mkdir -p "$(dirname "$dst")" || return 1
        mv -f "$src" "$dst" || return 1
      fi
      echo "   归位 $a -> ${want:0:12}…/$a"
      moved=$((moved + 1))
    done < <(seed_records "$f")
  done
  echo "==> seed migrate: 检查 $checked 个旧位置文件，归位 $moved 个${skipped:+，跳过 $skipped 条非法记录}"
  return 0
}
