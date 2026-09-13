#!/usr/bin/env bash
# lib/patchset.sh — **产物内**补丁注册表的文本解析 ＋ 工作区补丁集 overlay。
#
# 从旧 `.test-install/sandbox-lib.sh` 迁入（第 7c 步；映射表 L8/L9/L10）。旧文件在
# 删除前**委托到这里**，免得两份实现分叉。
#
# 为什么是"文本解析"而不是 source 被测产物里的 patch-lib.sh：
#   * 被测对象是**别人发布出来的**那一份，可能是任何历史形态（两段式 / 三段式 /
#     带前置条件的四段式条目），甚至可能带有当前 bash 下不该执行的副作用；
#   * 我们要断言的是"这份产物**声明**了什么"，所以只读它的文本。
#   * 期望值因此永远从**消费的那份注册表**派生，不写死。
#
# 与 `scripts/patch-lib.sh` 的分工：那边是**工作区**（我们自己正在改的）注册表，
# 可以被 source，并提供 apply / reverse / verify 等真实动作；这边只读文本。

# ---------------------------------------------------------------- L9 文本解析

# patchset_entries <patch-lib.sh 路径> -> 逐行输出 DSH_PATCH_SET 条目原文。
patchset_entries() {
  [ -f "${1:-}" ] || return 1
  awk '/^DSH_PATCH_SET=\(/,/^\)/' "$1" | sed -n 's/^[[:space:]]*"\([^"]*\)".*/\1/p'
}

# 条目字段：<patch>:<rel>:<marker>[:<precondition>]
patchset_patch() { printf '%s' "${1%%:*}"; }
patchset_rel() { local r="${1#*:}"; printf '%s' "${r%%:*}"; }

# 第三段；两段式旧条目（pre-marker 时代）回退 platformLinkDenied，与
# `scripts/patch-lib.sh` 的 `dsh_patch_marker` 同语义 —— 旧 release 不该误红。
# 必须**只**取第三段：四段式条目的第四段不是 marker 的一部分。
patchset_marker() {
  local m _
  IFS=: read -r _ _ m _ <<<"${1:-}"
  if [ -z "$m" ]; then printf '%s' platformLinkDenied; else printf '%s' "$m"; fi
}

# 第四段（适用性前置条件）；空串 = 无条件条目（必须打上）。
patchset_precondition() {
  local pre _
  IFS=: read -r _ _ _ pre <<<"${1:-}"
  printf '%s' "$pre"
}

# patchset_marker_for_patch <patch-lib.sh 路径> <补丁文件名> -> marker；无该条目返回 1。
# 按补丁**文件**为主键：同一目标 lib 可以挂多条（例如 attachment 的 walk + 每代
# link 回退），按目标反查不唯一。
patchset_marker_for_patch() {
  local file="$1" want="$2" entry
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    [ "${entry%%:*}" = "$want" ] || continue
    patchset_marker "$entry"
    return 0
  done < <(patchset_entries "$file")
  return 1
}

# patchset_verify_markers <patch-lib.sh> <work_dir> -> 0 全部在场 / 1 有缺失
# 逐条验**该产物自己声明**的 marker，条件条目在目标不含其前置串时跳过（与生产
# 判定同语义）。marker 缺失的条目打到 stderr。
patchset_verify_markers() {
  local file="$1" work="$2" entry rel pre marker t rc=0
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    rel="$(patchset_rel "$entry")"
    t="$work/node_modules/@deepseek-ai/$rel"
    pre="$(patchset_precondition "$entry")"
    if [ -n "$pre" ] && ! grep -qF "$pre" "$t" 2>/dev/null; then
      echo "skip $rel (本版本无前置条件 '$pre')" >&2
      continue
    fi
    marker="$(patchset_marker "$entry")"
    if ! grep -qF -- "$marker" "$t" 2>/dev/null; then
      echo "missing marker '$marker' in $rel" >&2
      rc=1
    fi
  done < <(patchset_entries "$file")
  return "$rc"
}

# ---------------------------------------------------------------- L8 wrapper 钩子

# 期望值由「即将运行的生成器」的能力派生，而不是硬编码——生成器将来去掉/改掉该
# 特性时测试自动跟随，不会留下神秘红灯。
# ⚠ 下面两个锚点串与 scripts/common.sh 的生成文本逐字耦合（生成器能力探测用
# 'updater="${4:-}"'，产物探测用 '= "update"'）；改 common.sh 生成格式时必须同步
# 这里，否则期望值会静默翻转 0/1 —— 这正是本函数注释声称要避免的。CI 的 build.yml
# 对产物另有 '= "update"' 的 grep，生成格式一改 CI 会红；'updater="${4:-}"' 这个
# 锚点只有 case 覆盖。
wrapper_hook_expected() { # $1=生成器（scripts/common.sh 或产物内同名文件） -> 打印 0|1
  grep -qF 'updater="${4:-}"' "$1" 2>/dev/null && echo 1 || echo 0
}

# patchset_wrapper_hook_check <wrapper 路径> <期望 0|1> -> 0=符合 / 1=不符（差异打到 stderr）
patchset_wrapper_hook_check() {
  local wrap="$1" exp="$2" got=0
  grep -q '= "update"' "$wrap" 2>/dev/null && got=1
  if [ "$got" != "$exp" ]; then
    echo "wrapper update 钩子期望=$exp 实际=$got（生成器能力与产物不符）" >&2
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------- L10 overlay

# patchset_overlay_workspace_patches <work_dir> [<patches_dir>]
# 把**工作区** DSH_PATCH_SET 打到一棵「已随 tarball 打过补丁」的 work 树上。
# 两步缺一不可：
#  1) 先用该树自带的 patches/ 逐条回退。那份 patches/ 与这棵树的来历同一（同一个
#     发布产物），因此它正是「造出树上 post-image 的那一版」；而 dsh_apply_patch 的
#     幂等只认**手上这份补丁文件的字节** —— 被改写过的补丁（重锚 / 加宽 / 因漂移
#     重生成）若直接 apply，会既退不掉旧 post-image 又打不上，还把结论报成上游
#     「版本漂移」（2026-09-08 真机撞到：逐版本 pristine 矩阵全绿，serve.sh 拒绝启动）。
#  2) 再走生产入口 dsh_apply_patch_set，与 install / update / 发版构建同一判定
#     （含 precondition 跳过与 marker 验证），不在这里另立一套标准。
# 回退不动的条目（该 dsh 版本本就不适用，或工作区已删除该补丁）跳过，让第 2 步
# 给出它自己的响亮结论。
# 临时/相对路径教训：PATCHES_DIR 必须是绝对路径（dsh_apply_patch 是
# `git -C <work_dir> apply <patch>`，相对路径按 work 目录解析，症状是 "can't open
# patch" 被报成版本漂移）。
patchset_overlay_workspace_patches() {
  local work_dir="$1" patches_dir="${2:-}"
  local runtime_dir shipped sp wpref harness
  harness="${DSH_HARNESS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
  [ -n "$patches_dir" ] || patches_dir="$harness/patches"
  case "$patches_dir" in /*) ;; *) patches_dir="$PWD/${patches_dir#./}" ;; esac
  # shellcheck source=../../scripts/patch-lib.sh
  . "$harness/scripts/patch-lib.sh"
  runtime_dir="$(dirname "$work_dir")"          # <runtime>/work -> <runtime>
  shipped="$runtime_dir/patches"
  if [ -d "$shipped" ]; then
    wpref="$(dsh_git_worktree_prefix "$work_dir")node_modules/@deepseek-ai"
    for sp in "$shipped"/*.patch; do
      [ -e "$sp" ] || continue
      if git -C "$work_dir" apply --directory="$wpref" --reverse --check \
          "$sp" >/dev/null 2>&1; then
        git -C "$work_dir" apply --directory="$wpref" --reverse "$sp" \
          && echo "   回退 shipped 版: ${sp##*/}"
      fi
    done
  fi
  dsh_apply_patch_set "$work_dir" "$patches_dir"
}
