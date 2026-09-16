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

# 内容寻址：<assets>/<sha256>/<资产名>
seed_cas_path() { # $1=sha256 $2=资产名
  printf '%s\n' "$(seed_assets_dir)/${1:?seed_cas_path: 需要 sha256}/${2:?seed_cas_path: 需要资产名}"
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
    dst="$(seed_cas_path "$sum" "$a")"
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
seed_records() { # $1=env 文件
  sed -n 's/^SEED_ASSET_[0-9]*=//p' "${1:?seed_records: 需要 env 文件}"
}

# 把一个记录解析到本地实际路径（CAS 优先；过渡期容忍旧扁平位置）。
# 输出路径；找不到返回 3（缺对象），内容不符返回 1，读不了返回 2。
seed_resolve_record() { # $1=记录
  local rec="$1" a want p lp got
  a="${rec%%:*}"; want="${rec##*:}"
  p="$(seed_cas_path "$want" "$a")"
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

# 只报告不改状态。与 seed_load 同一套四分语义：
#   0 = 全部就位且哈希相符 / 1 = 现算与 pin 不符(FAIL) / 2 = 事实源或校验工具坏(ERROR)
#   3 = 缺事实源或缺对象(UNMET)
# ⚠ `local` 声明必须**独占一行**：曾因为一次"去空行"的编辑把它拼进上面那行注释里，
# 声明被整行吞掉 —— `bash -n` 与 shellcheck 都不报（语法完全合法），只在 `set -u`
# 下以 `rc: unbound variable` 现形（首跑 `seed set` 实测撞到）。改动本函数时看住它。
seed_verify() { # $1=name
  local name="$1" f rc=0 rec a want p r
  f="$(seed_env_path "$name")"
  [ -f "$f" ] || { echo "MISSING: seeds/$name.env 不存在"; return 3; }
  [ -n "$(sed -n 's/^SEED_TAG=//p' "$f")" ] || { echo "BROKEN: $f 缺 SEED_TAG"; return 2; }
  while IFS= read -r rec; do
    [ -n "$rec" ] || continue
    a="${rec%%:*}"; want="${rec##*:}"
    if p="$(seed_resolve_record "$rec" 2>/dev/null)"; then
      echo "ASSET-OK: $a"
    else
      r=$?
      case "$r" in
        3) echo "ASSET-MISSING: $a (pin=${want:0:12}…)" ;;
        1) echo "ASSET-CHANGED: $a" ;;
        *) echo "ASSET-UNREADABLE: $a" ;;
      esac
      # 严重度取最坏：ERROR(2) > FAIL(1) > UNMET(3)（与聚合端 state_aggregate 同序）。
      # 即"读不了"压过"内容不符"，"内容不符"压过"缺件"——一次诊断里只要出现更坏的
      # 那类，返回码就报那一类。
      case "$r" in
        2) rc=2 ;;
        1) [ "$rc" = 2 ] || rc=1 ;;
        3) [ "$rc" = 0 ] && rc=3 ;;
      esac
    fi
  done < <(seed_records "$f")
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
  local f rec p n_rec=0 n_ok=0 n_missing=0 n_bad=0 n_err=0
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
    n_rec=$((n_rec + 1))
    case "$rec" in
      *:*) ;;
      *) echo "$f 的资产记录格式非法: $rec" >&2; n_err=$((n_err + 1)); continue ;;
    esac
    if p="$(seed_resolve_record "$rec")"; then
      paths+=("$p"); n_ok=$((n_ok + 1))
    else
      case "$?" in
        3) n_missing=$((n_missing + 1)) ;;
        1) n_bad=$((n_bad + 1)) ;;
        *) n_err=$((n_err + 1)) ;;
      esac
    fi
  done < <(seed_records "$f")
  [ "$n_rec" -gt 0 ] || { echo "$f 没有任何资产条目" >&2; return 2; }
  # 严重度取最坏：ERROR > FAIL > UNMET（与聚合端 state_aggregate 同序）。
  if [ "$n_err" -gt 0 ]; then echo "种子校验无法完成（$f）" >&2; return 2; fi
  if [ "$n_bad" -gt 0 ]; then return 1; fi
  if [ "$n_missing" -gt 0 ]; then return 3; fi
  # 只有完全通过才交出去：部分路径绝不许泄漏给调用方（否则调用方可能拿到半份资产
  # 就开始跑，结论却算在"种子可用"头上）。
  [ "$n_ok" -eq "$n_rec" ] || return 2
  SEED_ASSETS=("${paths[@]}")
  return 0
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
# 这层存在的唯一理由：12 个 case 各写一遍 switch 必然漂移（顾问明确警告过
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

# 把**旧扁平位置**、且与某条 pin 逐字相符的资产移进 CAS。不改任何 `.env`。
# 先核哈希再搬（"恢复必须与旧 pin 相符"）；不符就**不动**并报出来，绝不覆盖/猜测。
seed_migrate_legacy() {
  local f rec a want src dst moved=0 checked=0
  for f in "$(seed_dir)"/*.env; do
    [ -f "$f" ] || continue
    while IFS= read -r rec; do
      [ -n "$rec" ] || continue
      a="${rec%%:*}"; want="${rec##*:}"
      src="$(seed_assets_dir)/$a"
      [ -f "$src" ] || continue
      checked=$((checked + 1))
      if [ "$(seed_sha256 "$src")" != "$want" ]; then
        echo "!! $a 与 $(basename "$f") 的 pin 不符（pin=${want:0:12}…）—— 不迁移，人工检查" >&2
        continue
      fi
      dst="$(seed_cas_path "$want" "$a")"
      if [ -f "$dst" ]; then
        rm -f "$src"
      else
        mkdir -p "$(dirname "$dst")" || return 1
        mv -f "$src" "$dst" || return 1
      fi
      echo "   归位 $a -> ${want:0:12}…/$a"
      moved=$((moved + 1))
    done < <(seed_records "$f")
  done
  echo "==> seed migrate: 检查 $checked 个旧位置文件，归位 $moved 个"
  return 0
}
