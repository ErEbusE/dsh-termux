#!/data/data/com.termux/files/usr/bin/bash
# r5-update-shipped.sh — R5 更新链路(发布物内置更新器): 下载**当前 latest release**
# 的 tarball 作为种子, 执行其**自带**的 scripts/update-dsh.sh + patches/。
# 这是 Option A 用户真实执行的东西——release 打包缺更新器/补丁、或内置更新器
# 与捆绑 lib 版本不自洽, 只有这里会红。种子与下载物落在沙箱 dl/ 内, 与
# release-test/ 的 pin 资产隔离, r1/r4 不受影响。钩子期望值从 shipped
# common.sh 派生; 补丁文件清单与 marker 同样从 shipped patch-lib.sh 的
# DSH_PATCH_SET 派生 (跟随基线内补丁集的新旧自动变化)。
# 需要 npm registry 网络。更新目标 tag: DSH_UPDATE_TAG > DSH_R4_TAG(旧名兼容) > latest
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/sandbox-lib.sh"
ROUTE="r5"

TAG="${DSH_UPDATE_TAG:-${DSH_R4_TAG:-latest}}"   # 更新目标 (npm dist-tag)

echo "需要 npm registry 网络; 更新目标 dist-tag: $TAG"

sandbox_init update --work

echo "=== 0. 下载 latest release 作为种子 ==="
RTAG="$(resolve_release_tag latest)" || fail "解析 latest 失败"
DL="$ROOT/dl"
fetch_release_assets "$DL" "$RTAG" || fail "下载失败"
STARBALL="$DL/dsh-termux-runtime.tar.gz"
echo "    种子 release: $RTAG"

echo "=== 1. 种子 runtime ==="
tar -xzf "$STARBALL" -C "$ROOT/prefix" || fail "tarball 解包失败"
[ -x "$NODE" ] || fail "种子 node missing"
PKGJSON="$ROOT/prefix/work/node_modules/@deepseek-ai/dsh/package.json"
BEFORE="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$PKGJSON" | head -1)"
[ -n "$BEFORE" ] || fail "无法读取被种子 dsh 版本 (package.json)"
ok "种子 dsh $BEFORE (来自 $RTAG)"

UPDATER="$ROOT/prefix/scripts/update-dsh.sh"
[ -f "$UPDATER" ] || fail "release 未内置 update-dsh.sh — 无法覆盖 Option A 真实路径 (打包回归, 该红)"
# 补丁文件清单按 shipped patch-lib.sh 的 DSH_PATCH_SET 派生 (sandbox-lib 的
# shipped_patch_entries): 旧 release 两段式/新 release 三段式都认, 不硬编码。
NPATCH=0
while IFS= read -r entry; do
  [ -n "$entry" ] || continue
  NPATCH=$((NPATCH+1))
  patch="${entry%%:*}"
  [ -f "$ROOT/prefix/patches/$patch" ] || fail "release 未内置补丁文件 $patch (打包回归)"
done < <(shipped_patch_entries "$ROOT/prefix/scripts/patch-lib.sh")
[ "$NPATCH" -ge 1 ] || fail "shipped patch-lib.sh 未声明 DSH_PATCH_SET 条目 (打包回归)"
EXPECT="$(wrapper_hook_expected "$ROOT/prefix/scripts/common.sh")"
ok "内置更新器在位 + $NPATCH 个 shipped 补丁文件; 其生成器钩子能力=$EXPECT"

echo "=== 1b. --self 自更新链路 (按 tarball 是否携带 VERSION 条件触发) ==="
# --self 是补丁集跨项目 release 演进的通道: 下载 latest tarball 替换 runtime
# 内置 scripts/patches/VERSION。1.2.1 起 tarball 才打包 VERSION——旧 release
# 的 --self 会正确响亮失败 (reinstall 指引), 该行为不在此断言范围; 只有种子
# tarball 携带 VERSION 时才执行完整链路并断言替换结果。
if tar tzf "$STARBALL" | grep -qx "VERSION"; then
  # 用 1.1.0 时代的假 VERSION 播种, 让 --self 有"落后"可修 (已是最新时
  # self_update 无操作也正确, 但那样断言不到替换)
  echo "1.1.0" > "$ROOT/prefix/VERSION"
  if ! bash "$UPDATER" --self -t "$TAG" -y >"$ROOT/self.log" 2>&1; then
    cat "$ROOT/self.log"; fail "--self 链路失败"
  fi
  VSELF="$(tr -d '[:space:]' < "$ROOT/prefix/VERSION")"
  VSHIPPED="$(tar xzOf "$STARBALL" VERSION | tr -d '[:space:]')"
  [ "$VSELF" = "$VSHIPPED" ] || fail "--self 后 VERSION($VSELF) != tarball($VSHIPPED)"
  # self 后重新解析 (re-exec 的 fresh updater 已把 runtime scripts 换新)
  NPATCH2=0
  while IFS= read -r entry; do
    [ -n "$entry" ] && NPATCH2=$((NPATCH2+1))
  done < <(shipped_patch_entries "$ROOT/prefix/scripts/patch-lib.sh")
  [ "$NPATCH2" -ge "$NPATCH" ] || fail "--self 后补丁声明变少 ($NPATCH2 < $NPATCH)"
  ok "--self 全链路: VERSION 1.1.0→$VSELF, $NPATCH2 个补丁声明, re-exec 完成"
else
  note "种子 tarball 无 VERSION (pre-1.2.1 release), --self 链路跳过"
fi

echo "=== 2. 内置 update-dsh.sh -t $TAG -y ==="
bash "$UPDATER" -t "$TAG" -y >"$ROOT/update.log" 2>&1 \
  || { cat "$ROOT/update.log"; fail "shipped update-dsh.sh exited non-zero"; }
ok "shipped update-dsh.sh exit 0"

echo "=== 3. node 补丁仍在 + 可直连 ==="
readelf -l "$NODE" | grep -q 'ld-linux-aarch64.so.1' || fail "node interpreter not glibc loader"
NV="$("$NODE" --version 2>"$ROOT/node-err.log")" \
  || { cat "$ROOT/node-err.log" >&2; fail "patched node won't run"; }
ok "node patched, runs ($NV)"

echo "=== 4. 更新后版本 (经重写的 wrapper) ==="
WRAP="$ROOT/prefix/work/dsh"
[ -x "$WRAP" ] || fail "wrapper missing after update"
WVER="$(PATH="$ROOT/bin:$PATH" "$WRAP" --version 2>/dev/null)"
[ -n "$WVER" ] || fail "wrapper --version 为空"
AFTER="$(printf '%s\n' "$WVER" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?' | head -1)"
[ -n "$AFTER" ] || fail "无法从 wrapper 输出解析版本: $WVER"
if [ "$BEFORE" != "$AFTER" ]; then
  ok "dsh 版本: $BEFORE -> $AFTER"
else
  note "dsh 版本未变 ($AFTER == 种子): 重装+重打补丁+wrapper 重写机制本身验证通过"
fi

echo "=== 5. 补丁标记 (由 SHIPPED 补丁打上; 按 shipped 能力派生) ==="
# marker 同样从 shipped DSH_PATCH_SET 派生: 三段式条目自带 marker, 两段式旧格式
# 回退 platformLinkDenied (patch_entry_marker)。发版前后 (2 补丁/3 补丁) 都正确。
while IFS= read -r entry; do
  [ -n "$entry" ] || continue
  rest="${entry#*:}"; rel="${rest%%:*}"
  marker="$(patch_entry_marker "$entry")"
  t="$ROOT/prefix/work/node_modules/@deepseek-ai/$rel"
  grep -q "$marker" "$t" || fail "marker '$marker' missing in $rel (shipped 补丁未生效?)"
done < <(shipped_patch_entries "$ROOT/prefix/scripts/patch-lib.sh")
ok "shipped 补丁标记齐全 (按 shipped DSH_PATCH_SET 派生)"

echo "=== 5b. landlock tmpdir 行为探针 (按 marker 条件触发) ==="
landlock_tmpdir_probe "$ROOT/prefix/work" "$NODE"

echo "=== 6. opener + symlink 重写可用 ==="
OPENER="$ROOT/prefix/work/dsh-termux-open"
[ -x "$OPENER" ] || fail "opener missing"
"$OPENER" </dev/null >/dev/null 2>&1
[ $? -eq 2 ] || fail "opener 无参退出码 != 2"
[ -L "$ROOT/bin/dsh" ] || fail "symlink missing"
[ "$(readlink "$ROOT/bin/dsh")" = "$WRAP" ] || fail "symlink target wrong"
"$ROOT/bin/dsh" --version >/dev/null 2>&1 || fail "symlinked dsh won't run"
ok "wrapper/opener/symlink 已重写并可用"

echo "=== 7. update 钩子符合 shipped 生成器能力 ==="
assert_wrapper_hook "$WRAP" "$EXPECT"

echo "=== 8. 线上运行时未触碰 ==="
live_sentinel

note "本次认证的 release: $RTAG"
summary