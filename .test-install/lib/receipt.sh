#!/data/data/com.termux/files/usr/bin/bash
# receipt.sh — 两类收据：**不可变的 build receipt** 与**只追加的 test receipt**。
#
# 为什么要分开（评审收敛的结论）: 一次"通过"如果不绑定**被测对象的内容**，
# 它证明不了任何事——同一个 tag 可以对应无数次不同的工作树。而把运行时间、
# 结果塞进同一个文件，又会让它每次都变，于是"同样的输入应当得到同样的收据"
# 这条可核对的性质就没了。
#
#   build receipt  被测输入的**纯函数**：不带时间戳、不带 run id，因此
#                  **内容寻址**（`.test-install/state/receipts/build-<digest>.tsv`），
#                  同样的输入永远落到同一个文件，跨运行可比对。
#   test receipt   只追加的一行一次运行：run_id、时间、选了哪些、聚合与结论，
#                  以及它指向哪个 build digest。**这是把"结论"钉到"对象"上的那根钉子。**
#
# 格式用 TSV（`key<TAB>value`，键排序）而不是 JSON: 不需要 python3、
# 不会被引号/转义坑到，而且直接 `sha256sum` 就能当摘要。
#
# 摘要覆盖的是**内容**而不只是 commit: 工作树脏、有未跟踪文件时，
# commit 哈希根本代表不了被跑的代码。

set -uo pipefail

RECEIPT_STORE() { printf '%s\n' "${DSH_TI_DIR:?}/state/receipts"; }

_receipt_sha() { # $1=文件 -> sha256（拿不到时输出 missing，绝不用空串冒充）
  [ -f "$1" ] && { sha256sum "$1" | cut -d' ' -f1; return 0; }
  printf 'missing\n'
}

# 工作树内容摘要: 「受跟踪 ∪ 未忽略」的每个文件逐个哈希后整体再哈希。
# 只看 `git rev-parse HEAD` 是错的——脏工作树与未跟踪代码根本不在 HEAD 里。
receipt_worktree_digest() { # $1=仓库根 $2=清单暂存文件（写在状态目录内）
  local root="$1" list="$2"
  git -C "$root" ls-files --cached --others --exclude-standard 2>/dev/null \
    | LC_ALL=C sort > "$list" || : > "$list"
  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ -f "$root/$f" ]; then
      printf '%s\t%s\n' "$f" "$(sha256sum "$root/$f" | cut -d' ' -f1)"
    else
      printf '%s\tMISSING\n' "$f"
    fi
  done < "$list" | sha256sum | cut -d' ' -f1
}

receipt_platform_android_sdk() {
  command -v getprop >/dev/null 2>&1 || { printf '-\n'; return 0; }
  getprop ro.build.version.sdk 2>/dev/null | tr -d '\r\n' || printf '%s\n' '-'
  printf '\n'
}

# 写 build receipt。$1=输出文件（run 目录内） $2=清单暂存文件
# 成功后设 BUILD_RECEIPT_FILE / BUILD_DIGEST。
receipt_build() {
  local out="$1" list="$2" root="${DSH_HARNESS_ROOT:?}"
  local tmp="$out.tmp"
  local head_sha dirty="no" f

  head_sha="$(git -C "$root" rev-parse HEAD 2>/dev/null || echo nogit)"
  [ -n "$(git -C "$root" status --porcelain 2>/dev/null | head -n 1)" ] && dirty="yes"

  {
    printf 'schema\tdsh-termux-build-receipt/1\n'
    printf 'harness_identity\t%s\n' "${DSH_HARNESS_IDENTITY:--}"
    printf 'repo_head\t%s\n' "$head_sha"
    printf 'worktree_dirty\t%s\n' "$dirty"
    printf 'worktree_digest\t%s\n' "$(receipt_worktree_digest "$root" "$list")"
    printf 'worktree_files\t%s\n' "$(grep -c . "$list" || true)"
    printf 'worktree_untracked\t%s\n' \
      "$(git -C "$root" ls-files --others --exclude-standard 2>/dev/null | grep -c . || true)"
    local v="?"
    [ -f "$root/VERSION" ] && v="$(tr -d '[:space:]' < "$root/VERSION")"
    printf 'repo_version\t%s\n' "$v"
    printf 'platform_system\t%s\n' "$(uname -s)"
    printf 'platform_machine\t%s\n' "$(uname -m)"
    printf 'platform_android_sdk\t%s\n' "$(receipt_platform_android_sdk)"
    printf 'platform_bash\t%s\n' "${BASH_VERSION:--}"
    printf 'termux_prefix\t%s\n' "${PREFIX:--}"
    printf 'patch_registry_digest\t%s\n' "$(_receipt_sha "$root/scripts/patch-lib.sh")"
    printf 'patch_registry_entries\t%s\n' \
      "$(grep -c '^  "' "$root/scripts/patch-lib.sh" 2>/dev/null || echo 0)"
    printf 'case_registry_digest\t%s\n' "$(_receipt_sha "$root/.test-install/cases/registry.tsv")"
    local p n
    for p in "$root"/patches/*.patch; do
      [ -f "$p" ] || continue
      n="$(basename "$p")"
      printf 'patch_%s\t%s\n' "$n" "$(_receipt_sha "$p")"
    done
    # 具名输入（当前只有 default-target）。冻结文件的每个字段进 receipt，
    # 因此"同一份代码在不同日子跑"会得到不同 receipt——这是**正确**的：
    # 解析出的版本本来就是被测对象的一部分。
    if [ -n "${DSH_NPM_TARGET_FILE:-}" ] && [ -f "${DSH_NPM_TARGET_FILE:-}" ]; then
      printf 'npm_input_role\tdefault-target\n'
      local k v
      while IFS=$'\t' read -r k v; do
        case "$k" in
          requested_spec|registry|package|version|dist_tag|selector_kind|selector|integrity|tarball|shasum)
            printf 'npm_%s\t%s\n' "$k" "$v" ;;
        esac
      done < "$DSH_NPM_TARGET_FILE"
      printf 'npm_target_digest\t%s\n' "$(sha256sum "$DSH_NPM_TARGET_FILE" | cut -d' ' -f1)"
    fi
    local s name
    for s in "$root"/.test-install/seeds/*.env; do
      [ -f "$s" ] || continue
      name="$(basename "$s" .env)"
      printf 'seed_%s_env_digest\t%s\n' "$name" "$(_receipt_sha "$s")"
      printf 'seed_%s_tag\t%s\n' "$name" "$(sed -n 's/^SEED_TAG=//p' "$s")"
      local rec asset sum
      while IFS= read -r rec; do
        [ -n "$rec" ] || continue
        asset="${rec%%:*}"; sum="${rec##*:}"
        printf 'seed_%s_asset_%s\t%s\n' "$name" "$asset" "$sum"
      done < <(sed -n 's/^SEED_ASSET_[0-9]*=//p' "$s")
    done
  } > "$tmp" || { echo "!! 无法写 build receipt" >&2; return 2; }

  mv -f "$tmp" "$out" || return 2
  local digest
  digest="$(sha256sum "$out" | cut -d' ' -f1)"
  # 出口变量，由调用者（run.sh）读取并 export 给 case。
  # shellcheck disable=SC2034
  BUILD_RECEIPT_FILE="$out"
  # shellcheck disable=SC2034
  BUILD_DIGEST="$digest"
  local store; store="$(RECEIPT_STORE)"
  mkdir -p "$store" || return 2
  # 内容寻址: 同名文件内容必然相同，所以"已存在就不覆盖"是安全的。
  [ -f "$store/build-$digest.tsv" ] || cp "$out" "$store/build-$digest.tsv"
  return 0
}

# 只追加一行运行收据。$1..=字段值（顺序见下），由调用方保证数量。
# 表头只在文件**首次创建**时写一次。
receipt_test_append() {
  local store file
  store="$(RECEIPT_STORE)"
  mkdir -p "$store" || return 2
  file="$store/test.tsv"
  if [ ! -f "$file" ]; then
    printf '%s\n' \
      "run_id	finished_at	profile	build_digest	selected	pass	fail	unmet	na	error	not_selected	aggregate	exit_code	verdict	human_required	human_covered	harness_identity" \
      > "$file"
  fi
  printf '%s\n' "$(printf '%s\t' "$@")" | sed 's/\t$//' >> "$file"
  return 0
}

receipt_test_path() { printf '%s/test.tsv\n' "$(RECEIPT_STORE)"; }

# --- 对象身份：规范化内容清单 -------------------------------------------------
# `receipt_tree_id <目录>` 回答的是"这两棵树是不是**同一份字节**"。
#
# ⚠️ 这条函数被评审驳回过一次，原因是它当时只记 (类型, 相对路径, 大小)：
#   一次**等长改写**（6 字节的 `hello` 改成 6 字节的 `jello`）不改变摘要，
#   符号链接目标与执行位也完全不在覆盖里。而"冻结对象的漂移判定"与"人类实测
#   的那棵树就是被断言的那棵树"正是建立在这条摘要上——一个能被同长度替换绕过
#   的身份等于没有身份。现在改成内容清单：
#
#   * 常规文件: 内容 sha256 + 相对路径 + **权限**（权限含执行位: node 二进制被
#     `chmod -x` 是真实变化，只哈希内容看不见）;
#   * 非常规项（目录/符号链接/其他）: 类型 + 相对路径 + 权限 + **链接目标**,
#     且**不记目录大小**——目录 st_size 取决于文件系统分配与条目布局，跨副本不稳定;
#   * 先 `cd` 进树再用 `%P`: 绝对路径会让同一份对象落在不同沙箱时得到不同身份，
#     跨运行就没法比对;
#   * **不含 mtime**: 时间戳是噪音，同一份输入装两次也会不同;
#   * 记录以 NUL 分隔再 `sort -z`: 文件名里的换行不会把一条记录劈成两条看起来
#     合法的行（这种树极少，但"极少"不是"不会伪造记录"的理由）。
#
# 它仍然**不**证明内容的来源——来源靠 lockfile + SRI 那条链（ADR-009）。
# 成本实测: 293MB / 7.4 万项 ≈ 1.7s。
receipt_tree_id() { # $1=目录 -> 摘要（不存在=absent, 不可读=unreadable，绝不用空串冒充）
  local d="${1:-}"
  if [ -z "$d" ] || [ ! -d "$d" ]; then printf 'absent\n'; return 0; fi
  (
    cd "$d" || { printf 'unreadable\n'; exit 0; }
    {
      printf 'schema\tdsh-termux-tree-manifest/1\0'
      find . -mindepth 1 ! -type f -printf 'n|%y|%P|%m|%l\0'
      find . -mindepth 1 -type f -printf 'm|%P|%m\0'
      find . -mindepth 1 -type f -exec sha256sum --zero {} +
    } 2>/dev/null | LC_ALL=C sort -z | sha256sum | cut -d' ' -f1
  )
}

# 只追加的 **case 级事实**。为什么不能只靠运行目录里的证据文件：`run.sh clean`
# 会删掉运行目录，而"这条契约当时到底测的是哪个版本、SRI 对不对得上、几条补丁
# 适用"是**结论的一部分**，删掉之后就无法回溯（"只剩几条通过"正是要避免的）。
#
# 写入失败必须由调用方升级成 ERROR —— 必要证据写不进去 = 这次结论不成立。
receipt_case_facts() { # $1=run_id $2=case_id $3=事实串(k=v 空格分隔)
  local store file facts
  store="$(RECEIPT_STORE)"
  mkdir -p "$store" || return 2
  file="$store/case-facts.tsv"
  [ -f "$file" ] || printf 'finished_at\trun_id\tcase_id\tbuild_digest\tfacts\n' > "$file"
  facts="$(printf '%s' "${3:-}" | tr '\t\n' '  ')"
  # 用 DSH_BUILD_DIGEST 而不是 BUILD_DIGEST: case 跑在**白名单环境**里,
  # 只有 DSH_* 那批契约变量被显式放进去。裸的 BUILD_DIGEST 在 case 里是未设置的,
  # 于是会静默记成 "-" —— 而那正是"结论绑定被测对象"的那根钉子。
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$(date '+%F %R%:z')" "${1:--}" "${2:--}" \
    "${DSH_BUILD_DIGEST:-${BUILD_DIGEST:--}}" "$facts" >> "$file"
}
