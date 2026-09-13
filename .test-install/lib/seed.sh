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

seed_names() { # -> 已存在的种子名，每行一个
  local f
  for f in "$(seed_dir)"/*.env; do
    [ -f "$f" ] || continue
    basename "$f" .env
  done
}

# 全新完整下载两个发布资产到 $2。绝不续传；先 .part 再 mv。
seed_fetch_assets() { # $1=tag $2=目标目录
  local tag="$1" dl="$2" slug a tmp url
  slug="$(seed_repo_slug)"
  command -v wget >/dev/null 2>&1 || { echo "!! 需要 wget 下载发布资产" >&2; return 1; }
  mkdir -p "$dl" || return 1
  local first=1
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
    [ "$first" = 1 ] && first=0
    mv -f "$tmp" "$dl/$a" || return 1
  done
  return 0
}

seed_sha256() { # $1=file -> sha256（拿不到时返回 1，绝不用空串冒充）
  [ -f "$1" ] || return 1
  sha256sum "$1" | cut -d' ' -f1
}

seed_write_env() { # $1=name $2=tag $3=dsh_version $4..=资产绝对路径
  local name="$1" tag="$2" dshv="$3"; shift 3
  local dir tmp f n=0 sum
  dir="$(seed_dir)"; mkdir -p "$dir" || return 1
  tmp="$dir/.$name.env.tmp"
  {
    echo "# seeds/$name.env — 种子发布物的唯一事实源。"
    echo "# 生成: bash .test-install/run.sh seed set <tag|latest> $name"
    echo "# 不要手编：哈希一律现算，改 pin 走 review（DECISIONS.md ADR-004）。"
    echo "SEED_NAME=$name"
    echo "SEED_TAG=$tag"
    echo "SEED_DSH_VERSION=$dshv"
    for f in "$@"; do
      n=$((n + 1))
      sum="$(seed_sha256 "$f")" || { echo "!! 无法计算 $(basename "$f") 的 sha256" >&2; return 1; }
      echo "SEED_ASSET_$n=$(basename "$f"):$sum"
    done
  } > "$tmp" || return 1
  mv -f "$tmp" "$dir/$name.env" || return 1
  return 0
}

# 只报告不改状态。0=全部就位且哈希相符 / 1=缺件或哈希不符 / 2=事实源自身坏了
# ⚠ `local` 声明必须**独占一行**：曾因为一次"去空行"的编辑把它拼进上面那行注释里，
# 声明被整行吞掉 —— `bash -n` 与 shellcheck 都不报（语法完全合法），只在 `set -u`
# 下以 `rc: unbound variable` 现形（首跑 `seed set` 实测撞到）。改动本函数时看住它。
seed_verify() { # $1=name
  local name="$1" f rc=0 tag rec a want got dir
  f="$(seed_env_path "$name")"
  [ -f "$f" ] || { echo "MISSING: seeds/$name.env 不存在"; return 1; }
  tag="$(sed -n 's/^SEED_TAG=//p' "$f")"
  [ -n "$tag" ] || { echo "BROKEN: $f 缺 SEED_TAG"; return 2; }
  dir="$(seed_assets_dir)"
  while IFS= read -r rec; do
    [ -n "$rec" ] || continue
    a="${rec%%:*}"; want="${rec##*:}"
    got="$(seed_sha256 "$dir/$a")" || { echo "ASSET-MISSING: seed-assets/$a"; rc=1; continue; }
    if [ "$got" = "$want" ]; then
      echo "ASSET-OK: $a"
    else
      echo "ASSET-CHANGED: $a (现算=${got:0:12}… pin=${want:0:12}…)"
      rc=1
    fi
  done < <(sed -n 's/^SEED_ASSET_[0-9]*=//p' "$f")
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
# 返回 0=可用；1=缺件或哈希不符（**FAIL** 级：验证完成了、结论是否定）；
# 2=事实源自身坏了（**ERROR** 级：配置/生成故障）。
seed_load() {
  local name="${1:-$(seed_default_name)}" f rec a want got dir
  f="$(seed_env_path "$name")"
  [ -f "$f" ] || { echo "缺少种子事实源 $f（生成: run.sh seed set <tag|latest> $name）" >&2; return 2; }
  # shellcheck disable=SC1090
  . "$f"
  [ -n "${SEED_TAG:-}" ] || { echo "$f 缺 SEED_TAG" >&2; return 2; }
  [ -n "${SEED_DSH_VERSION:-}" ] || { echo "$f 缺 SEED_DSH_VERSION" >&2; return 2; }
  dir="$(seed_assets_dir)"
  SEED_ASSETS=()
  while IFS= read -r rec; do
    [ -n "$rec" ] || continue
    a="${rec%%:*}"; want="${rec##*:}"
    got="$(seed_sha256 "$dir/$a")" || { echo "缺少种子资产 $dir/$a" >&2; return 1; }
    if [ "$got" != "$want" ]; then
      echo "种子资产哈希不符: $a (现算=${got:0:12}… pin=${want:0:12}…)" >&2
      return 1
    fi
    SEED_ASSETS+=("$dir/$a")
  done < <(sed -n 's/^SEED_ASSET_[0-9]*=//p' "$f")
  [ "${#SEED_ASSETS[@]}" -gt 0 ] || { echo "$f 没有任何资产条目" >&2; return 2; }
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
