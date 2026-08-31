#!/data/data/com.termux/files/usr/bin/bash
# r6-self-workspace.sh — R6 更新链路(工作区更新器 --self 全链路 + 哨兵行为)。
# 固化原一次性演练 (.scratch-selfcheck.sh)。存在理由: r4 跑工作区更新器, 但种子
# 身份与 latest release 一致时 self_update 天然不触发; r5 的 1b 执行的又是
# tarball 内置的 shipped 旧更新器——工作区新代码的显式 --self、旧→新项目版本
# 显示、DSH_SELF_RAN / DSH_PATCHES_CHANGED 哨兵、答 n 中止时的「补丁未应用」
# 警告, 在 r4/r5 里零覆盖。本路线用基线 tarball 种子 + 工作区更新器补上:
#   Part A  显式 --self -y: 播种假旧 VERSION + 弄脏一个补丁 → 全链路成功,
#           断言「project VERSION: 1.1.0 -> <latest 项目版本>」+ VERSION 被替换
#           (re-exec 的是下载到的 shipped 更新器, 与用户真实路径一致);
#   Part B  白盒模拟 re-exec 后的哨兵状态 (环境变量正是 exec 会带过去的东西):
#           B1 DSH_PATCHES_CHANGED=1 → 答 n 中止 + 「补丁未应用」NOTE;
#           B2 无 DSH_PATCHES_CHANGED → 中止干净、无 NOTE;
#   Part C  -y + 哨兵 → 全链路成功、明示在、停止提示被抑制、banner 项目版本在。
# 期望值动态派生 (latest tag 尾段 = 项目 VERSION, CI 保证与 dsh 段自洽), 不硬
# 编码——发版后自动跟随。Part B/C 以 DSH_SELF_DONE=1 关掉自动刷新判定 (该哨兵
# 本来就是防二次刷新的机制), 否则基线 pin 落后 latest 时模拟会被真刷新劫走。
# 需要 GitHub + npm registry 网络。更新目标: DSH_UPDATE_TAG > DSH_R4_TAG(旧名兼容) > latest
set -uo pipefail
# ROUTE 先于 source: 库里写的是 ROUTE="${ROUTE:-}", 本就允许调用者预设,
# 而这个顺序让「谁用了它」对读者和 shellcheck 都成立。
ROUTE="r6"
# shellcheck source=../sandbox-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/sandbox-lib.sh"

TAG="${DSH_UPDATE_TAG:-${DSH_R4_TAG:-latest}}"
WORKSPACE_UPDATER="$TI_ROOT/../scripts/update-dsh.sh"
[ -f "$WORKSPACE_UPDATER" ] || fail "工作区 update-dsh.sh 不存在"

echo "需要 GitHub + npm registry 网络; 更新目标 dist-tag: $TAG"

load_baseline
check_baseline_consistent
verify_baseline_assets

echo "=== 0. 解析 latest release, 派生期望值 ==="
RTAG="$(resolve_release_tag latest)" || fail "解析 latest release 失败"
PV_LATEST="${RTAG##*-}"   # tag = dsh-<dsh版本>-<项目VERSION>
echo "    latest release: $RTAG (项目 VERSION $PV_LATEST)"

sandbox_init self --work

echo "=== Part A. 工作区 --self -y (落后 + 补丁集有真实变化) ==="
tar -xzf "$TARBALL" -C "$ROOT/prefix" || fail "基线 tarball 解包失败"
[ -x "$NODE" ] || fail "种子 node missing"
echo "1.1.0" > "$ROOT/prefix/VERSION"
FIRST_PATCH="$(shipped_patch_entries "$ROOT/prefix/scripts/patch-lib.sh" | head -1 | cut -d: -f1)"
[ -n "$FIRST_PATCH" ] || fail "无法从 shipped patch-lib 派生补丁清单"
echo "junk-old-content" >> "$ROOT/prefix/patches/$FIRST_PATCH"   # 让补丁签名真的变化
if ! bash "$WORKSPACE_UPDATER" --self -t "$TAG" -y >"$ROOT/self.log" 2>&1; then
  cat "$ROOT/self.log"; fail "工作区 --self 全链路失败"
fi
grep -q "project VERSION: 1.1.0 -> $PV_LATEST" "$ROOT/self.log" \
  || { cat "$ROOT/self.log"; fail "缺少 旧->新 项目版本显示"; }
VSELF="$(tr -d '[:space:]' < "$ROOT/prefix/VERSION")"
[ "$VSELF" = "$PV_LATEST" ] || fail "--self 后 VERSION($VSELF) != latest 项目版本($PV_LATEST)"
grep -q "Done. dsh is now" "$ROOT/self.log" \
  || { cat "$ROOT/self.log"; fail "npm 更新未完成"; }
ok "Part A: --self 全链路 exit 0, 旧->新显示, VERSION 1.1.0->$VSELF, npm 完成"

echo "=== Part B. 白盒模拟 re-exec 后哨兵状态: 答 n 中止 ==="
# sandbox_init 重建沙箱; 种子 = 基线 tarball + 工作区 updater/补丁 + latest 项目
# VERSION (假装 self_update 刚刷新到最新、即将 exec 进新更新器的那一刻)。
sandbox_init self --work
tar -xzf "$TARBALL" -C "$ROOT/prefix" || fail "Part B 基线 tarball 解包失败"
cp "$TI_ROOT"/../scripts/*.sh "$ROOT/prefix/scripts/"
cp "$TI_ROOT"/../patches/*.patch "$ROOT/prefix/patches/"
echo "$PV_LATEST" > "$ROOT/prefix/VERSION"

echo "--- B1: DSH_PATCHES_CHANGED=1 -> 中止 + NOTE ---"
export DSH_SELF_DONE=1 DSH_SELF_RAN=1 DSH_PATCHES_CHANGED=1
echo n | bash "$ROOT/prefix/scripts/update-dsh.sh" -t "$TAG" >"$ROOT/abort1.log" 2>&1 \
  && { cat "$ROOT/abort1.log"; fail "答 n 应中止 (期望 exit 1)"; }
grep -q "continuing into the dsh update" "$ROOT/abort1.log" \
  || { cat "$ROOT/abort1.log"; fail "缺少继续进入 dsh 更新的明示"; }
grep -q "answer 'n' at the 'Update dsh to ...?' prompt" "$ROOT/abort1.log" \
  || { cat "$ROOT/abort1.log"; fail "缺少停止提示"; }
grep -q "Aborted." "$ROOT/abort1.log" || fail "缺少 Aborted."
grep -q "NOT applied to the installed" "$ROOT/abort1.log" \
  || { cat "$ROOT/abort1.log"; fail "缺少补丁未应用 NOTE"; }
ok "B1: 明示 + 停止提示 + 中止 + 补丁未应用 NOTE (exit 1)"

echo "--- B2: 无 DSH_PATCHES_CHANGED -> 中止干净 ---"
unset DSH_PATCHES_CHANGED
echo n | bash "$ROOT/prefix/scripts/update-dsh.sh" -t "$TAG" >"$ROOT/abort2.log" 2>&1 \
  && { cat "$ROOT/abort2.log"; fail "答 n 应中止"; }
grep -q "Aborted." "$ROOT/abort2.log" || fail "B2 缺少 Aborted."
if grep -q "NOT applied to the installed" "$ROOT/abort2.log"; then
  cat "$ROOT/abort2.log"; fail "补丁集未变化时不应出现 NOTE"
fi
ok "B2: 中止干净, 无 NOTE"

echo "=== Part C. -y + 哨兵 -> 全链路成功 ==="
export DSH_PATCHES_CHANGED=1
bash "$ROOT/prefix/scripts/update-dsh.sh" -t "$TAG" -y >"$ROOT/y.log" 2>&1 \
  || { cat "$ROOT/y.log"; fail "Part C -y 全链路失败"; }
grep -q "continuing into the dsh update" "$ROOT/y.log" \
  || { cat "$ROOT/y.log"; fail "Part C 缺少继续明示"; }
if grep -q "answer 'n' at the 'Update dsh to ...?' prompt" "$ROOT/y.log"; then
  cat "$ROOT/y.log"; fail "-y 下不应出现停止提示"
fi
grep -q "project VERSION: $PV_LATEST" "$ROOT/y.log" || fail "Part C 缺少 banner 项目版本"
grep -q "Done. dsh is now" "$ROOT/y.log" \
  || { cat "$ROOT/y.log"; fail "Part C npm 更新未完成"; }
ok "Part C: -y 全链路成功, 明示在, 停止提示被抑制, banner 项目版本在"

echo "=== 本地正在运行的 dsh runtime 未被触碰 ==="
live_sentinel

note "本次判定的 latest release: $RTAG (项目 VERSION $PV_LATEST)"
summary
