#!/data/data/com.termux/files/usr/bin/bash
# r6-self-workspace.sh — R6 更新链路(工作区更新器 --self 语义 + 本地补丁集)。
#
# --self 现在的语义是「刷新机件并直接应用补丁集, 不碰 npm」。本路线覆盖它,
# 并且大部分断言完全离线 (Part A-F): 本地目录集 / 本地 tarball / 签名相同跳过 /
# --force / 缺件负例 / 哨兵缺失回退。Part G 覆盖下载路径 (GitHub), Part H 用
# 白盒环境变量覆盖自动刷新后保留的哨兵行为 (该行为只在普通 update 的自动刷新
# 分支里活着, --self 不再经过它)。
#
# 关键点: --self 不重装 npm 树, 所以「先退旧集」必须在打新集之前发生 ——
# Part A 断言日志里真有这一步 (Reversing...), 而不只是 marker 最终在场。
# 期望值动态派生: 工作区 VERSION/脚本从仓库读, latest 项目版本从 tag 尾段取,
# marker 从被消费的注册表读 (工作区或安装后的), 不硬编码。
# 需要 GitHub (Part G)。更新目标 dist-tag: DSH_UPDATE_TAG > DSH_R4_TAG > latest。
set -uo pipefail
# ROUTE 先于 source: 库里写的是 ROUTE="${ROUTE:-}", 本就允许调用者预设,
# 而这个顺序让「谁用了它」对读者和 shellcheck 都成立。
ROUTE="r6"
# shellcheck source=../sandbox-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/sandbox-lib.sh"

TAG="${DSH_UPDATE_TAG:-${DSH_R4_TAG:-latest}}"
REPO_ROOT="$(cd "$TI_ROOT/.." && pwd)"
WORKSPACE_UPDATER="$REPO_ROOT/scripts/update-dsh.sh"
WORKSPACE_VERSION="$(tr -d '[:space:]' < "$REPO_ROOT/VERSION")"
[ -f "$WORKSPACE_UPDATER" ] || fail "工作区 update-dsh.sh 不存在"
[ -n "$WORKSPACE_VERSION" ] || fail "仓库 VERSION 为空"

echo "需要 GitHub (Part G 下载路径); 更新目标 dist-tag: $TAG"
echo "工作区项目 VERSION: $WORKSPACE_VERSION"

load_baseline
check_baseline_consistent
verify_baseline_assets

sandbox_init self --work
tar -xzf "$TARBALL" -C "$ROOT/prefix" || fail "基线 tarball 解包失败"
[ -x "$NODE" ] || fail "种子 node missing"

# verify_markers <patch-lib.sh 路径> <标签>
# 在子进程里 source 指定注册表并逐个验 marker, 不污染本路线 shell 的
# DSH_PATCH_SET; 四段式条目前置条件不在目标文件时记 note 跳过 (与生产判定同语义)。
# 这样 Part A-F 用工作区注册表、Part G 用下载安装后的注册表, 同一实现。
verify_markers() {
  local lib="$1" label="$2" out rc n
  out="$(bash -c '
    set -uo pipefail
    . "$1"
    work="$2"
    for entry in "${DSH_PATCH_SET[@]}"; do
      IFS=: read -r patch rel _ pre <<<"$entry"
      t="$work/node_modules/@deepseek-ai/$rel"
      if [ -n "$pre" ] && ! grep -qF "$pre" "$t" 2>/dev/null; then
        echo "skip $rel"; continue
      fi
      marker="$(dsh_patch_marker "$patch")" || { echo "ERR no-marker $patch"; exit 3; }
      grep -qF "$marker" "$t" || { echo "MISS $marker $rel"; exit 4; }
      echo "ok $rel"
    done
  ' _ "$lib" "$ROOT/prefix/work" 2>&1)"; rc=$?
  if [ "$rc" != 0 ]; then printf '%s\n' "$out" >&2; fail "$label: marker 校验失败 (rc=$rc)"; fi
  n="$(grep -c '^ok ' <<<"$out" || true)"
  [ "$n" -ge 1 ] || { printf '%s\n' "$out" >&2; fail "$label: 0 个适用补丁, 断言失效"; }
  ok "$label: $n 个适用补丁 marker 齐全 ($(basename "$lib"))"
}

echo "=== Part A. --self --patch-set <工作区目录> (离线, 不碰 npm) ==="
echo "1.1.0" > "$ROOT/prefix/VERSION"
if ! bash "$WORKSPACE_UPDATER" --self --patch-set "$REPO_ROOT" >"$ROOT/a.log" 2>&1; then
  cat "$ROOT/a.log"; fail "Part A: --self --patch-set 工作区目录失败"
fi
grep -q "project VERSION: 1.1.0 -> $WORKSPACE_VERSION" "$ROOT/a.log" \
  || { cat "$ROOT/a.log"; fail "Part A: 缺少 旧->新 项目版本显示"; }
grep -q "Reversing the previously applied patch set" "$ROOT/a.log" \
  || { cat "$ROOT/a.log"; fail "Part A: 缺少先退旧集步骤 (不重装时它是正确性保障)"; }
grep -q "Applying the refreshed patch set" "$ROOT/a.log" \
  || { cat "$ROOT/a.log"; fail "Part A: 缺少应用新集步骤"; }
if grep -q "Querying npm registry" "$ROOT/a.log"; then
  cat "$ROOT/a.log"; fail "Part A: --self 不该进入 npm 流程"
fi
V="$(tr -d '[:space:]' < "$ROOT/prefix/VERSION")"
[ "$V" = "$WORKSPACE_VERSION" ] || fail "Part A: VERSION($V) != 工作区($WORKSPACE_VERSION)"
for f in update-dsh.sh common.sh patch-lib.sh; do
  diff -q "$REPO_ROOT/scripts/$f" "$ROOT/prefix/scripts/$f" >/dev/null \
    || fail "Part A: $f 未被安装到 runtime"
done
verify_markers "$REPO_ROOT/scripts/patch-lib.sh" "Part A"
[ -x "$ROOT/prefix/work/dsh" ] || fail "Part A: wrapper 未重写"
"$ROOT/prefix/work/dsh" --version >/dev/null 2>&1 || fail "Part A: 重写的 wrapper 不能运行"
ok "Part A: 本地目录集全链路 (安装+退旧+应用+marker+wrapper), 全程无 npm"

echo "=== Part B. 机件签名相同 -> 报告已最新, 不重打 ==="
if ! bash "$WORKSPACE_UPDATER" --self --patch-set "$REPO_ROOT" >"$ROOT/b.log" 2>&1; then
  cat "$ROOT/b.log"; fail "Part B: 已是最新时应 exit 0"
fi
grep -q "machinery already current" "$ROOT/b.log" \
  || { cat "$ROOT/b.log"; fail "Part B: 缺少 已是最新 报告"; }
if grep -q "Applying the refreshed patch set" "$ROOT/b.log"; then
  cat "$ROOT/b.log"; fail "Part B: 签名相同不该重打补丁"
fi
ok "Part B: 签名相同 -> 报告已最新并跳过 (exit 0)"

echo "=== Part C. --force 强制重打; -t/-v 被忽略并提示 ==="
if ! bash "$WORKSPACE_UPDATER" --self --patch-set "$REPO_ROOT" --force -t "$TAG" -y >"$ROOT/c.log" 2>&1; then
  cat "$ROOT/c.log"; fail "Part C: --force 失败"
fi
grep -q "Applying the refreshed patch set" "$ROOT/c.log" \
  || { cat "$ROOT/c.log"; fail "Part C: --force 未重打"; }
grep -q "applies the patch set only; -t/-v are ignored" "$ROOT/c.log" \
  || { cat "$ROOT/c.log"; fail "Part C: 缺少 -t/-v 忽略提示"; }
if grep -q "Querying npm registry" "$ROOT/c.log"; then
  cat "$ROOT/c.log"; fail "Part C: --self 不该进入 npm 流程"
fi
verify_markers "$REPO_ROOT/scripts/patch-lib.sh" "Part C"
ok "Part C: --force 重打 + -t/-v 忽略提示 + 无 npm"

echo "=== Part D. 本地打包 tarball -> --patch-set 消费 (与发布资产同构) ==="
bash "$REPO_ROOT/build/build-patchset.sh" -r "$REPO_ROOT" -o "$ROOT/local-patches.tar.gz" >"$ROOT/pack.log" 2>&1 \
  || { cat "$ROOT/pack.log"; fail "Part D: build-patchset.sh 打包失败"; }
# 清单先读进内存再匹配: tar | grep -q 在 pipefail 下会因 grep 提前退出、tar
# 收 SIGPIPE(141) 而误报 (release.yml 记录过同一个坑)。
LIST="$(tar -tzf "$ROOT/local-patches.tar.gz")"
for m in scripts/update-dsh.sh scripts/common.sh scripts/patch-lib.sh VERSION; do
  grep -qx "$m" <<< "$LIST" || { printf '%s\n' "$LIST"; fail "Part D: tarball 缺 $m"; }
done
echo "1.1.0" > "$ROOT/prefix/VERSION"
if ! bash "$WORKSPACE_UPDATER" --self --patch-set "$ROOT/local-patches.tar.gz" >"$ROOT/d.log" 2>&1; then
  cat "$ROOT/d.log"; fail "Part D: 消费本地 tarball 失败"
fi
grep -q "staging local patch set $ROOT/local-patches.tar.gz" "$ROOT/d.log" \
  || { cat "$ROOT/d.log"; fail "Part D: 未显示本地源"; }
grep -q "project VERSION: 1.1.0 -> $WORKSPACE_VERSION" "$ROOT/d.log" \
  || { cat "$ROOT/d.log"; fail "Part D: 缺少 旧->新 显示"; }
verify_markers "$ROOT/prefix/scripts/patch-lib.sh" "Part D"
ok "Part D: 本地 tarball (现打) 安装+应用闭环"

echo "=== Part E. 负例: 注册表声明的补丁文件缺失 -> 响亮失败 ==="
BAD="$ROOT/badset"
rm -rf "$BAD"; mkdir -p "$BAD"
cp -r "$REPO_ROOT/scripts" "$REPO_ROOT/patches" "$BAD/"
cp "$REPO_ROOT/VERSION" "$BAD/VERSION"
FIRST_PATCH="$(shipped_patch_entries "$REPO_ROOT/scripts/patch-lib.sh" | head -1 | cut -d: -f1)"
[ -n "$FIRST_PATCH" ] || fail "Part E: 无法从工作区注册表派生补丁名"
rm -f "$BAD/patches/$FIRST_PATCH"
V_BEFORE="$(tr -d '[:space:]' < "$ROOT/prefix/VERSION")"
if bash "$WORKSPACE_UPDATER" --self --patch-set "$BAD" >"$ROOT/e.log" 2>&1; then
  cat "$ROOT/e.log"; fail "Part E: 缺件补丁集应失败"
fi
grep -q "registry names a missing patch file" "$ROOT/e.log" \
  || { cat "$ROOT/e.log"; fail "Part E: 缺少缺件报错"; }
V_AFTER="$(tr -d '[:space:]' < "$ROOT/prefix/VERSION")"
[ "$V_BEFORE" = "$V_AFTER" ] || fail "Part E: 校验失败时不该改动 runtime (VERSION 变了)"
ok "Part E: 缺件补丁集响亮失败且未触碰 runtime"

echo "=== Part F. 安装的 updater 不认识哨兵 -> 子 shell 回退应用 ==="
OLD="$ROOT/oldsentinel"
rm -rf "$OLD"; mkdir -p "$OLD"
cp -r "$REPO_ROOT/scripts" "$REPO_ROOT/patches" "$OLD/"
cp "$REPO_ROOT/VERSION" "$OLD/VERSION"
sed -i 's/DSH_SELF_APPLY_ONLY/DSH_SELF_APPLY_DISABLED/g' "$OLD/scripts/update-dsh.sh"
if grep -q 'DSH_SELF_APPLY_ONLY' "$OLD/scripts/update-dsh.sh"; then
  fail "Part F: 哨兵串未被移除"
fi
echo "1.1.0" > "$ROOT/prefix/VERSION"
if ! bash "$WORKSPACE_UPDATER" --self --patch-set "$OLD" >"$ROOT/f.log" 2>&1; then
  cat "$ROOT/f.log"; fail "Part F: 回退路径失败"
fi
grep -q "predates apply-only mode" "$ROOT/f.log" \
  || { cat "$ROOT/f.log"; fail "Part F: 缺少回退提示"; }
grep -q "Applying the refreshed patch set" "$ROOT/f.log" \
  || { cat "$ROOT/f.log"; fail "Part F: 回退未应用补丁"; }
verify_markers "$OLD/scripts/patch-lib.sh" "Part F"
ok "Part F: 哨兵缺失 -> 子 shell 回退应用成功"

echo "=== Part G. 下载路径: --self 从 latest release 资产刷新并应用 ==="
RTAG="$(resolve_release_tag latest)" || fail "Part G: 解析 latest 失败"
PV_LATEST="${RTAG##*-}"
echo "    latest release: $RTAG (项目 VERSION $PV_LATEST)"
echo "1.1.0" > "$ROOT/prefix/VERSION"
if ! bash "$WORKSPACE_UPDATER" --self >"$ROOT/g.log" 2>&1; then
  cat "$ROOT/g.log"; fail "Part G: --self 下载路径失败"
fi
grep -q "project VERSION: 1.1.0 -> $PV_LATEST" "$ROOT/g.log" \
  || { cat "$ROOT/g.log"; fail "Part G: 缺少 1.1.0 -> $PV_LATEST 显示"; }
if grep -q "Querying npm registry" "$ROOT/g.log"; then
  cat "$ROOT/g.log"; fail "Part G: --self 不该进入 npm 流程"
fi
VSELF="$(tr -d '[:space:]' < "$ROOT/prefix/VERSION")"
[ "$VSELF" = "$PV_LATEST" ] || fail "Part G: VERSION($VSELF) != latest 项目版本($PV_LATEST)"
verify_markers "$ROOT/prefix/scripts/patch-lib.sh" "Part G"
ok "Part G: 下载 latest 资产 -> 安装+应用 (无 npm)"

echo "=== Part H. 自动刷新后保留的哨兵行为 (白盒: env 即 exec 会带过去的东西) ==="
# 这组哨兵现在只服务普通 update 的自动刷新分支 (--self 直接应用, 不再经过中止提示)。
# 用工作区代码覆盖 prefix 后直接跑, 保证测的是本分支代码而不是 shipped 副本。
cp "$REPO_ROOT"/scripts/*.sh "$ROOT/prefix/scripts/"
cp "$REPO_ROOT"/patches/*.patch "$ROOT/prefix/patches/"
echo "$PV_LATEST" > "$ROOT/prefix/VERSION"
echo "--- H1: DSH_PATCHES_CHANGED=1 -> 答 n 中止 + 补丁未应用 NOTE ---"
export DSH_SELF_DONE=1 DSH_SELF_RAN=1 DSH_PATCHES_CHANGED=1
if echo n | bash "$ROOT/prefix/scripts/update-dsh.sh" -t "$TAG" >"$ROOT/h1.log" 2>&1; then
  cat "$ROOT/h1.log"; fail "H1: 答 n 应中止 (期望 exit 1)"
fi
grep -q "continuing into the dsh update" "$ROOT/h1.log" \
  || { cat "$ROOT/h1.log"; fail "H1: 缺少继续进入 dsh 更新的明示"; }
grep -q "answer 'n' at the 'Update dsh to ...?' prompt" "$ROOT/h1.log" \
  || { cat "$ROOT/h1.log"; fail "H1: 缺少停止提示"; }
grep -q "Aborted." "$ROOT/h1.log" || fail "H1: 缺少 Aborted."
grep -q "NOT applied to the installed" "$ROOT/h1.log" \
  || { cat "$ROOT/h1.log"; fail "H1: 缺少补丁未应用 NOTE"; }
ok "H1: 明示 + 停止提示 + 中止 + 补丁未应用 NOTE (exit 1)"

echo "--- H2: 无 DSH_PATCHES_CHANGED -> 中止干净 ---"
unset DSH_PATCHES_CHANGED
if echo n | bash "$ROOT/prefix/scripts/update-dsh.sh" -t "$TAG" >"$ROOT/h2.log" 2>&1; then
  cat "$ROOT/h2.log"; fail "H2: 答 n 应中止"
fi
grep -q "Aborted." "$ROOT/h2.log" || fail "H2: 缺少 Aborted."
if grep -q "NOT applied to the installed" "$ROOT/h2.log"; then
  cat "$ROOT/h2.log"; fail "H2: 补丁集未变化时不应出现 NOTE"
fi
ok "H2: 中止干净, 无 NOTE"
unset DSH_SELF_DONE DSH_SELF_RAN

echo "=== 本地正在运行的 dsh runtime 未被触碰 ==="
live_sentinel

note "本次判定的 latest release: $RTAG (项目 VERSION $PV_LATEST)"
summary
