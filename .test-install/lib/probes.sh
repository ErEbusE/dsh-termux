#!/usr/bin/env bash
# lib/probes.sh — 行为级探针：marker 只证明"文件变过"，这里证明"行为对了"。
#
# 从旧 `.test-install/sandbox-lib.sh` 移植（第 7b 步）。探针本体逐字保留——它们是
# 旧体系里最有价值的一块资产；改的只有**触发条件的派生方式与失败语义**：
#
#   1. 触发不靠补丁**文件名**：旧体系在探针里写死 marker 串（审计 H2），marker 一
#      改名，路线断言跟着新名字走，探针却落到"旧补丁集，跳过"分支——行为级覆盖静默
#      降级成一句 note（还不在 summary 的 WARN 区里）。现在按**补丁目标 rel**从
#      `DSH_PATCH_SET` 派生 marker，改名不再能让覆盖消失；同一目标出现多条**无条件**
#      条目时判为配置歧义 -> FAIL，而不是随便挑一条。
#   2. 跳过与失败都是**状态**，不是打印：注册表没有该目标的条目 -> 可见的 n/a
#      （原因经 case 写进 case-facts，跳过不等于已验证）；声明了而被测 lib 缺 marker
#      -> **FAIL**（旧体系只 warn_record，降级信号淹在噪声里）。
#   3. 断言走 `lib/state.sh` 的 assert_pass/assert_fail，进同一条结果协议。
#
# 调用约定：case 先 source `lib/state.sh` 与 `scripts/patch-lib.sh`（后者提供
# `DSH_PATCH_SET`），环境里必须有 DSH_WORK_DIR / DSH_RUNTIME_DIR / DSH_SANDBOX_ROOT
# ——三者都由 run.sh 的沙箱钉子提供，探针不自己猜路径。
#
# `probe_*` 返回 0 = 跑过或按规则跳过，1 = 失败（已 assert_fail，已记账）。

# 本 case 里被跳过的探针（原因）。case 把它写进 case-facts。
PROBE_SKIPPED=""

probe_note() { # $1=原因
  echo "n/a: $*" >&2
  PROBE_SKIPPED+="${PROBE_SKIPPED:+;}${1}"
}

# probe_marker_for_rel <补丁目标 rel> -> stdout=marker；无该条目返回 1，歧义返回 2。
# 读的是**本 shell 里已经生效**的 DSH_PATCH_SET（工作区注册表由 case source 得到，
# 产物内注册表由 7c 的解析器写入同名数组）。条目格式与 patch-lib.sh 一致：
#   <patch>:<rel>:<marker>[:<precondition>]
# 只认**无条件**条目（无第四段）：条件条目的 marker 是按 dsh 版本可选出现的，
# 用它做触发条件会让探针在"该补丁本就不适用"的树上失败。
# 第三段为空时回退 platformLinkDenied（旧 release 的两段式条目，与
# `patch_entry_marker` 同语义，只为旧产物不误红）。
probe_marker_for_rel() {
  local want="$1" entry rel marker pre found="" n=0
  for entry in ${DSH_PATCH_SET[@]+"${DSH_PATCH_SET[@]}"}; do
    rel="${entry#*:}"; rel="${rel%%:*}"
    [ "$rel" = "$want" ] || continue
    IFS=: read -r _ _ marker pre <<<"$entry"
    [ -z "${pre:-}" ] || continue
    n=$((n + 1))
    found="${marker:-platformLinkDenied}"
  done
  [ "$n" -gt 0 ] || return 1
  [ "$n" = 1 ] || { echo "注册表里 $want 有 $n 条无条件条目，探针无法派生唯一 marker" >&2; return 2; }
  printf '%s\n' "$found"
}

# 三个探针的公共前置：定位被测 lib、派生 marker、确认 marker 在场。
# 设置全局 PROBE_MARKER；返回 0=可继续 / 1=跳过（不是失败）/ 2=失败（已记账）。
_probe_preflight() { # $1=被测 lib 相对路径 $2=探针名
  local rel="$1" label="$2" target marker rc
  target="$DSH_WORK_DIR/node_modules/@deepseek-ai/$rel"
  if [ ! -f "$target" ]; then
    probe_note "$label: $rel 不在被测树，跳过"
    return 1
  fi
  marker="$(probe_marker_for_rel "$rel")"; rc=$?
  if [ "$rc" = 1 ]; then
    probe_note "$label: 注册表没有 $rel 的无条件条目（这套补丁集不含它），跳过"
    return 1
  fi
  if [ "$rc" != 0 ]; then
    assert_fail "$label: 无法从注册表唯一派生 $(printf '%s' "$rel") 的 marker（条目歧义）"
    return 2
  fi
  if ! grep -qF -- "$marker" "$target" 2>/dev/null; then
    assert_fail "$label: 注册表声明了 $rel (marker=$marker) 但被测 lib 缺它 —— 行为级覆盖缺失"
    return 2
  fi
  PROBE_MARKER="$marker"
  return 0
}

# 探针脚本落在沙箱 tmp 内（Termux 禁访系统 /tmp；沙箱内路径才可写）。
_probe_script() { # $1=文件名 -> stdout=完整路径
  mkdir -p "$DSH_SANDBOX_ROOT/tmp" || return 1
  printf '%s\n' "$DSH_SANDBOX_ROOT/tmp/$1"
}

# --- landlock tmpdir：workspace-write 授权表必须含本进程 tmpdir ------------------
# 用被测树的 node 真实 import 其 dsh-sandbox-local，调 runnerArgv，断言
#   - workspace-write 的 --rw 授权表包含本进程 os.tmpdir()
#   - read-only 的 --rw 授权表仍然只有 /dev/null（补丁不得放宽只读语义）
# kernel 级验证（受限 mktemp 真的能写）属人类实测，见 serve.sh 点检清单。
#   probe_landlock_tmpdir <work_dir> <node_bin>
probe_landlock_tmpdir() {
  local work_dir="$1" node_bin="$2" probe out rc
  _probe_preflight "dsh-sandbox-local/lib/index.js" "landlock 探针"; rc=$?
  [ "$rc" = 0 ] || { [ "$rc" = 1 ] && return 0; return 1; }
  probe="$(_probe_script probe-landlock.mjs)" || {
    assert_fail "landlock 探针: 无法准备沙箱 tmp"; return 1; }
  cat > "$probe" <<'PROBE_EOF'
import { tmpdir } from 'node:os'
const mod = await import(process.argv[2] + '/node_modules/@deepseek-ai/dsh-sandbox-local/lib/index.js')
const call = (mode) => mod.LocalSandboxProvider.prototype.runnerArgv.call(
  { landlockLauncher: () => '/probe/landlock-run' }, 'landlock', { mode, workspaceRoot: '/probe/ws' })
const rw = (a) => a.filter((_, i) => a[i - 1] === '--rw')
const ww = rw(call('workspace-write'))
const ro = rw(call('read-only'))
if (!ww.includes(tmpdir())) { console.error('FAIL: workspace-write grants lack tmpdir(): ' + ww.join(' ')); process.exit(1) }
if (!(ro.length === 1 && ro[0] === '/dev/null')) { console.error('FAIL: read-only grants changed: ' + ro.join(' ')); process.exit(1) }
console.log('rw(ww)=' + ww.join(',') + ' | rw(ro)=' + ro.join(','))
PROBE_EOF
  # TMPDIR 显式钉到沙箱 tmp: 断言的是"补丁后授权表跟随进程 tmpdir"这一行为本身。
  if ! out="$(TMPDIR="$DSH_SANDBOX_ROOT/tmp" "$node_bin" "$probe" "$work_dir" 2>&1)"; then
    echo "$out" >&2
    rm -f "$probe"
    assert_fail "landlock tmpdir 行为探针失败 (marker=$PROBE_MARKER 在但行为不符)"
    return 1
  fi
  rm -f "$probe"
  assert_pass "landlock tmpdir 行为探针: $out"
  return 0
}

# --- fs-local link→rename 回退：两个 hard-link 补丁从 marker 升到 behavior -------
# Android 的 link 拒绝在沙箱内无法自然触发（沙箱 fs 允许 link），注入是唯一确定性
# 途径。双控制自证，防探针自己变摆设：
#   负控制 EFOO（非 platform 错误码）→ 必须原样抛出（证明注入缝活着、分支真在区分错误码）；
#   正控制 EACCES → rename 回退 → 文件落盘且内容正确。
#   probe_fslocal_link_rename <work_dir> <node_bin>
probe_fslocal_link_rename() {
  local work_dir="$1" node_bin="$2" probe out rc
  _probe_preflight "dsh-fs-local/lib/index.js" "fs-local 探针"; rc=$?
  [ "$rc" = 0 ] || { [ "$rc" = 1 ] && return 0; return 1; }
  probe="$(_probe_script probe-fslocal.mjs)" || {
    assert_fail "fs-local 探针: 无法准备沙箱 tmp"; return 1; }
  cat > "$probe" <<'PROBE_EOF'
import { tmpdir } from 'node:os'
import { readFileSync, rmSync } from 'node:fs'
import { createRequire } from 'node:module'
const workDir = process.argv[2]
const stage = process.argv[3]
const mod = await import(workDir + '/node_modules/@deepseek-ai/dsh-fs-local/lib/index.js')
// 从被测树自身的解析上下文取 cordis (基类 FileSystem 是 cordis Service)
const { Context } = createRequire(workDir + '/node_modules/@deepseek-ai/dsh-fs-local/package.json')('@deepseek-ai/cordis')
const lfs = new mod.LocalFileSystem(new Context(), { cwd: tmpdir(), diffBasisMaxBytes: 1048576 })
const mkDenied = (code) => async () => { const e = new Error('link denied (simulated ' + code + ')'); e.code = code; throw e }
const path = (n) => stage + '/probe-fslocal-' + n + '.txt'
// 负控制: 非 platform 错误码必须原样抛出
lfs.internals.linkFile = mkDenied('EFOO')
let threw = false
try { await lfs.writeText({ targetKey: path('neg'), displayPath: path('neg') }, 'x', { kind: 'createIfAbsent' }) } catch { threw = true }
if (!threw) { console.error('FAIL: non-platform errno (EFOO) was swallowed — fallback branch not exercised (injection seam dead?)'); process.exit(1) }
// 正控制: EACCES → platformLinkDenied → rename 回退 → 落盘
lfs.internals.linkFile = mkDenied('EACCES')
const good = path('pos')
await lfs.writeText({ targetKey: good, displayPath: good }, 'probe-fs-local-content', { kind: 'createIfAbsent' })
const got = readFileSync(good, 'utf8')
rmSync(stage, { recursive: true, force: true })
if (got !== 'probe-fs-local-content') { console.error('FAIL: content mismatch: ' + got); process.exit(1) }
console.log('neg(EFOO threw) + pos(EACCES → rename fallback landed)')
PROBE_EOF
  if ! out="$(TMPDIR="$DSH_SANDBOX_ROOT/tmp" "$node_bin" "$probe" "$work_dir" "$DSH_SANDBOX_ROOT/tmp/probe-fs-stage" 2>&1)"; then
    echo "$out" >&2
    rm -f "$probe"
    assert_fail "fs-local link→rename 行为探针失败 (marker=$PROBE_MARKER 在但行为不符)"
    return 1
  fi
  rm -f "$probe"
  assert_pass "fs-local link→rename 行为探针: $out"
  return 0
}

# --- attachment-local 走根容忍：chmod 311 的不可读祖先下仍能 commit --------------
# 无需注入: open(dir, O_RDONLY) 在 chmod 311 的目录上必得 EACCES —— 恰是补丁
# syncDirectory 要容忍、而 pristine bundle 会整笔提交失败的 errno（天然差分）。
# link→rename 分支仍是 marker 级: link() 在沙箱/CI 均可成功、拒绝无法自然触发，
# 而 bundle 未导出 fs-local 那样的 internals 注入缝。
#   probe_attachment_durability <work_dir> <node_bin>
probe_attachment_durability() {
  local work_dir="$1" node_bin="$2" probe out rc
  _probe_preflight "dsh-attachment-local/lib/index.js" "attachment 探针"; rc=$?
  [ "$rc" = 0 ] || { [ "$rc" = 1 ] && return 0; return 1; }
  probe="$(_probe_script probe-attach.mjs)" || {
    assert_fail "attachment 探针: 无法准备沙箱 tmp"; return 1; }
  cat > "$probe" <<'PROBE_EOF'
import { mkdtempSync, mkdirSync, chmodSync, rmSync, existsSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
const workDir = process.argv[2]
const stageRoot = process.argv[3]
const mod = await import(workDir + '/node_modules/@deepseek-ai/dsh-attachment-local/lib/index.js')
const stage = mkdtempSync(join(stageRoot, 'att-'))
// chmod 311 = 可遍历、可在其下创建, 但**不可读**: open(dir, O_RDONLY) 必得
// EACCES —— 正是补丁 syncDirectory 必须容忍、而 pristine bundle 会整笔失败
// 的那个 errno (天然差分, 无需注入)。
const guard = join(stage, 'no-read')
mkdirSync(guard)
chmodSync(guard, 0o311)
const root = join(guard, 'v1')
// 1x1 PNG (canonical base64)
const png = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
  'base64',
)
const limits = {
  maxImageBytes: 20 * 1024 * 1024,
  maxImagesPerMessage: 20,
  maxMessageImageBytes: 200 * 1024 * 1024,
  maxImagePixels: 64_000_000,
  maxImageDimension: 8192,
  mediaTypes: ['image/png', 'image/jpeg', 'image/webp', 'image/gif'],
}
const policy = { maxPixels: 2048 * 2048, maxDimension: 8192, maxBytes: 4 * 1024 * 1024 }
try {
  const prepared = await mod.prepareImageFile({ data: png, mediaType: 'image/png', name: 'probe.png' }, limits, policy)
  const ref = await mod.commitPreparedImageFile(root, prepared)
  const hex = String(ref.attachmentId).replace(/^sha256:/, '')
  const obj = join(root, 'objects', hex.slice(0, 2), hex)
  if (!existsSync(obj)) { console.error('FAIL: object missing at ' + obj); process.exit(1) }
  console.log('commit ok through unreadable ancestor (EACCES skipped), object ' + hex.slice(0, 12))
} finally {
  chmodSync(guard, 0o755)
  rmSync(stage, { recursive: true, force: true })
}
PROBE_EOF
  if ! out="$(TMPDIR="$DSH_SANDBOX_ROOT/tmp" "$node_bin" "$probe" "$work_dir" "$DSH_SANDBOX_ROOT/tmp" 2>&1)"; then
    echo "$out" >&2
    rm -f "$probe"
    assert_fail "attachment 走根容忍行为探针失败 (marker=$PROBE_MARKER 在但行为不符)"
    return 1
  fi
  rm -f "$probe"
  assert_pass "attachment 走根容忍行为探针: $out"
  return 0
}

# 三个探针一次跑完：所有消费补丁集的 case 都用这一个入口，免得各写一份顺序与汇总
# （漏跑一个探针在旧体系里正是"看起来全绿"的典型失效）。
#   probe_patch_set_behaviors <work_dir> <node_bin>
probe_patch_set_behaviors() {
  local work_dir="$1" node_bin="$2" rc=0
  probe_landlock_tmpdir "$work_dir" "$node_bin" || rc=1
  probe_fslocal_link_rename "$work_dir" "$node_bin" || rc=1
  probe_attachment_durability "$work_dir" "$node_bin" || rc=1
  return "$rc"
}
