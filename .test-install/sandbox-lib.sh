#!/data/data/com.termux/files/usr/bin/bash
# sandbox-lib.sh — 沙箱测试公共核心。被 routes/*.sh 与 serve.sh source；独立执行无意义。
#
# 设计原则: 必须一致的逻辑只存一份。这里集中:
#   - 调用者 shell 清洗 (唯一的 unset 清单——漂移过的历史教训)
#   - grun stub / 沙箱目录 / 隔离导出
#   - 断言与计数报告 (fail/ok/note/warn_record/summary)
#   - 基线事实源加载与资产校验 (baseline.env 是唯一基线数据)
#   - 「本地正在运行的 dsh runtime 未被触碰」哨兵 (每条路线收尾必跑)

TI_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # = .test-install/

ROUTE="${ROUTE:-}" ; OK_COUNT=0 ; WARNS=""

fail() { echo "FAIL [$ROUTE]: $*" >&2; exit 1; }
ok()   { echo "ok: $*"; OK_COUNT=$((OK_COUNT+1)); }
note() { echo "note: $*"; }
warn_record() { echo "WARN [$ROUTE]: $*" >&2; WARNS+="$*"$'\n'; }

summary() {
  echo
  echo "== [$ROUTE] done: ${OK_COUNT} ok =="
  if [ -n "$WARNS" ]; then
    echo "== warnings =="
    printf '%s' "$WARNS" | sed '/^$/d; s/^/  WARN: /'
  fi
}

# --- 基线事实源 -------------------------------------------------------------
# baseline.env 键: BASELINE_TAG TARBALL_SHA256 INSTALLER_SHA256 DSH_VERSION
load_baseline() {
  [ -f "$TI_ROOT/baseline.env" ] || fail "缺少 baseline.env。生成: bash .test-install/run.sh baseline set <tag|latest>"
  # shellcheck disable=SC1090
  . "$TI_ROOT/baseline.env"
  # 注意: 不要用 ${VAR:?} —— 非交互 shell 中其展开失败会绕过 fail() 直接终止, 键清单提示成死代码
  local k
  for k in BASELINE_TAG TARBALL_SHA256 INSTALLER_SHA256 DSH_VERSION; do
    [ -n "${!k:-}" ] || fail "baseline.env 键不齐 (缺 $k; 需要 BASELINE_TAG/TARBALL_SHA256/INSTALLER_SHA256/DSH_VERSION)"
  done
  TARBALL="$TI_ROOT/release-test/dsh-termux-runtime.tar.gz"
  INSTALLER="$TI_ROOT/release-test/install.sh"
}

# 路线内强校验: 资产被换过却没重新 pin = 必须停 (一条命令即可重 pin, 不构成阻塞理由)
verify_baseline_assets() {
  local pair got name want
  for pair in "$TARBALL:$TARBALL_SHA256" "$INSTALLER:$INSTALLER_SHA256"; do
    got="${pair%%:*}"; want="${pair##*:}"; name="${got##*/}"
    [ -f "$got" ] || fail "基线资产缺失: $got (重取: run.sh baseline set $BASELINE_TAG)"
    got="$(sha256sum "${pair%%:*}" | cut -d" " -f1)"
    [ "$got" = "$want" ] || fail "$name 的 sha256 与 baseline.env 不一致 (漂移)。若是有意更换资产, 先: run.sh baseline set <tag>"
  done
  ok "基线资产 sha256 与 pin 一致 ($BASELINE_TAG)"
  return 0
}

# 基线 vs VERSION 漂移提醒 (WARN 记录进 summary, 不阻塞——gate 结论只对安装脚本有效)
check_baseline_consistent() {
  local cur ver
  cur="$(tr -d "[:space:]" < "$TI_ROOT/../VERSION" 2>/dev/null || true)"
  ver="${BASELINE_TAG##*-}"
  if [ -z "$cur" ]; then warn_record "仓库无 VERSION, 跳过基线一致性检查"; return 0; fi
  if [ "$ver" != "$cur" ]; then
    warn_record "基线 $BASELINE_TAG (v$ver) != 当前 VERSION ($cur); 发版后更新: run.sh baseline set <新tag>"
  else
    ok "基线 v$ver == VERSION ($cur), 一致性检查通过"
  fi
}

# --- 环境 --------------------------------------------------------------------
# 唯一 unset 清单。bionic LD_* 或 ~/.profile 注入的 NODE_* 会令 glibc node 启动失败;
# 测的是产物而不是调用者的 shell。serve.sh 也从这里取——历史上窄清单漂移过一次。
SANDBOX_UNSET_LIST=(LD_PRELOAD LD_LIBRARY_PATH NODE_OPTIONS NODE_REPL_EXTERNAL_MODULE)
# 脚本侧消费的 DSH_* 也纳入清洗, 防调用者 export 渗入改变被测行为;
# 运行时侧的 DSH_HOME/DSH_LAUNCH_ENVIRONMENT_KEY/DSH_TELEMETRY_DISABLED 不在此列——
# 前者由 sandbox_init/serve 显式重建, 后两者属运行时用户意图, 清除反而是行为改变。
SANDBOX_DSH_UNSET_LIST=(DSH_ASSUME_YES DSH_WEB_PORT DSH_PATCH_SET DSH_UPDATE_TAG DSH_R4_TAG DSH_NODE_VERSION DSH_RELEASE DSH_REPO)
env_sanitize() { unset "${SANDBOX_UNSET_LIST[@]}" "${SANDBOX_DSH_UNSET_LIST[@]}" 2>/dev/null || true; }

write_grun_stub() {
  mkdir -p "$1"
  printf '#!/data/data/com.termux/files/usr/bin/bash\nexec "$@"\n' > "$1/grun"
  chmod +x "$1/grun"
}

# sandbox_init <沙箱名> [--work]
#   建 .test-install/sandbox-<name>/{home,tmp,bin,prefix}, 导出全套隔离变量,
#   写 grun stub 并把沙箱 bin 前置到 PATH (--work 另导出 DSH_WORK_DIR=<root>/prefix/work)。
#   出口变量: ROOT NODE。调用者须已在仓库根目录。
sandbox_init() {
  local name="$1"; shift
  local do_work=0
  [ "${1:-}" = "--work" ] && do_work=1
  # 沙箱根锚定在脚本自身位置而非 $PWD: routes 可被绕过 run.sh 直接调用, CWD 不可信;
  # 而 rm -rf 发生在任何断言之前 —— 位置错了就会删到别处的同名沙箱 (AGENTS §3 同类事故)。
  [ -f "$TI_ROOT/../build/install.sh" ] || fail "请在仓库根目录运行 (build/install.sh 不存在)"
  # 并发防护: r4/r5 共用 sandbox-<name>/, 后启动者会 rm -rf 掉前者正在用的沙箱
  # (症状=随机假红, 难归因——testsystem 审计 H1)。flock 锁随进程退出自动释放,
  # 无陈锁问题; -n 冲突立即人话报错, 而不是互删或挂起。
  command -v flock >/dev/null 2>&1 || fail "需要 flock (Termux: pkg install util-linux)"
  exec 9>"$TI_ROOT/.sandbox-$name.lock"
  flock -n 9 || fail "sandbox-$name 正被另一路线占用 (共用沙箱不可并行; 确认无并发后再试)"
  ROOT="$TI_ROOT/sandbox-$name"
  rm -rf "$ROOT"
  mkdir -p "$ROOT/home" "$ROOT/tmp" "$ROOT/bin" "$ROOT/prefix"
  export HOME="$ROOT/home"
  export TMPDIR="$ROOT/tmp"
  export DSH_RUNTIME_DIR="$ROOT/prefix"
  export DSH_BIN_DIR="$ROOT/bin"
  [ "$do_work" = 1 ] && export DSH_WORK_DIR="$ROOT/prefix/work"
  env_sanitize
  write_grun_stub "$ROOT/bin"
  # 统一前置: stub 就在 bin 里; 对 r1/r2 这比逐命令前缀更简单且行为等价
  export PATH="$ROOT/bin:$PATH"
  # 出口变量 (见函数头注释): 路线脚本 source 本库之后才读它, 库内自然"未用"。
  # shellcheck disable=SC2034
  NODE="$ROOT/prefix/node/bin/node"
  live_snapshot
}

# 「本地正在运行的 dsh runtime 未被触碰」哨兵。真属性是**本地正在运行的 runtime 的 node 与路线起点一致**
# (inode/mtime/size/sha256 四元组), 而非「与沙箱不同」——用户本地正在运行的 runtime
# 完全可能与基线是同一 release, 二进制按设计相同 (教训: 用户重装 1.2.2 后
# 旧断言「沙箱 == 本地正在运行的安装即 FAIL」误报; 反过来, 同字节覆写会变 inode/mtime,
# 四元组照样抓得住)。起点快照在 sandbox_init 里取。
LIVE_NODE="/data/data/com.termux/files/home/.local/opt/dsh-termux-runtime/node/bin/node"
LIVE_PRISTINE=""
live_snapshot() {
  LIVE_PRISTINE=""
  [ -x "$LIVE_NODE" ] || return 0
  LIVE_PRISTINE="$(stat -c '%i.%Y.%s' "$LIVE_NODE").$(sha256sum "$LIVE_NODE" | cut -d' ' -f1)"
}
live_sentinel() {
  local live_now
  [ -x "$LIVE_NODE" ] || fail "本地正在运行的 dsh runtime 缺少 node ($LIVE_NODE)"
  "$LIVE_NODE" --version >/dev/null 2>&1 || fail "本地正在运行的 dsh runtime 的 node 无法运行 (是不是被误补丁了?)"
  live_now="$(stat -c '%i.%Y.%s' "$LIVE_NODE").$(sha256sum "$LIVE_NODE" | cut -d' ' -f1)"
  if [ -n "$LIVE_PRISTINE" ]; then
    [ "$live_now" = "$LIVE_PRISTINE" ] \
      || fail "本地正在运行的 dsh runtime 的 node 在路线运行期间被改动 (inode/mtime/size/sha256 与起点不符)"
  fi
  ok "本地正在运行的 dsh runtime 未被触碰 (与起点快照一致, node 正常)"
}

# wrapper 里 update 钩子的存在性断言。期望值由「即将运行的生成器」的能力派生,
# 而不是硬编码——生成器将来去掉/改掉该特性时测试自动跟随, 不会留下神秘红灯。
# ⚠ 下面两个锚点串与 scripts/common.sh 生成文本逐字耦合 (生成器能力探测用
# 'updater="${4:-}"', 产物探测用 '= "update"'); 改 common.sh 生成格式时必须同步这里,
# 否则期望值会静默翻转 0/1 —— 这正是本函数注释声称要避免的。
#   wrapper_hook_expected <生成器common.sh> -> 打印 0|1
#   assert_wrapper_hook  <wrapper路径> <期望0|1>
wrapper_hook_expected() {
  grep -qF 'updater="${4:-}"' "$1" 2>/dev/null && echo 1 || echo 0
}
assert_wrapper_hook() {
  local wrap="$1" exp="$2" got=0
  grep -q '= "update"' "$wrap" && got=1
  [ "$got" = "$exp" ] || fail "wrapper update 钩子期望=$exp 实际=$got"
  ok "wrapper update 钩子符合生成器能力 ($([ "$got" = 1 ] && echo 存在 || echo 无))"
}

# --- shipped 补丁集解析 (r2/r5 用; 与 wrapper_hook_expected 同一派生哲学) ----
# 补丁清单不在路线里硬编码: tarball/release 内置的 patch-lib.sh 自带 DSH_PATCH_SET,
# 它声明了「这套产物有能力打哪些补丁」。旧 release 是两段式条目 (marker 硬编码为
# platformLinkDenied), 新 release 是三段式 "<patch>:<rel>:<marker>", 更新的还可能
# 带第四段适用性前置条件 "<...>:<precondition>" —— 三种都认,
# 这样旧 release 认证不误红, 新 release 自动跟随, 发版前后零改动。

# shipped_patch_entries <patch-lib.sh 路径>: 逐行输出其 DSH_PATCH_SET 条目原文。
shipped_patch_entries() {
  awk '/^DSH_PATCH_SET=\(/,/^\)/' "$1" | sed -n 's/^[[:space:]]*"\([^"]*\)".*/\1/p'
}

# patch_entry_marker <entry>: 取第三段; 两段式 (旧格式) 回退 platformLinkDenied。
# 必须**只**取第三段: 四段式条目 (带适用性前置条件) 的第四段不是 marker 的一部分。
patch_entry_marker() {
  local m _
  IFS=: read -r _ _ m _ <<<"${1:-}"
  if [ -z "$m" ]; then printf '%s' platformLinkDenied
  else printf '%s' "$m"; fi
}

# patch_entry_precondition <entry>: 四段式条目的适用性前置条件, 否则空串。
# 空串 = 无条件补丁 (必须打上); 非空 = 目标文件里没有该串时本条目不适用。
patch_entry_precondition() {
  local pre _
  IFS=: read -r _ _ _ pre <<<"${1:-}"
  printf '%s' "$pre"
}

# marker_for_target <目标 lib rel> (stdin = DSH_PATCH_SET 条目, 每行一条):
# 按目标反查 marker (与 patch_entry_marker 同语义); 无该目标的条目则输出空串。
# 探针触发条件由此派生——注册表仍是唯一事实源, 路线不硬编码 marker。
marker_for_target() {
  local target="$1" entry rel
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    rel="${entry#*:}"; rel="${rel%%:*}"
    [ "$rel" = "$target" ] || continue
    patch_entry_marker "$entry"
    return 0
  done
}

# --- landlock tmpdir 行为探针 (marker 条件触发; r2/r4/r5/serve 共用) -----------
# marker 断言只证明「文件改过」; 这里证明「行为对了」: 用被测树的 node 真实
# import 其 dsh-sandbox-local, 调 landlockProfileArgs 所在的 runnerArgv, 断言
#   - workspace-write 的 --rw 授权表包含本进程的 os.tmpdir()
#   - read-only 的 --rw 授权表仍然只有 /dev/null (补丁不得放宽只读语义)
# 自条件化: 触发 marker 由调用方从自己消费的注册表**派生**传入 (r2/r5 = shipped
# registry, r4/serve = 工作区 DSH_PATCH_SET), 本函数不再硬编码 marker 串——
# 注册表里 marker 改名时探针自动跟随, 不会静默降级成「marker 不在, 跳过」
# (testsystem 审计 H2)。跳过分级: 注册表无 landlock 条目 (旧补丁集) = note;
# 注册表声明了但被测 lib 缺 marker = warn_record (真降级信号, 进 summary)。
# kernel 级验证 (受限 mktemp 真的能写) 属人类实测, 见 serve.sh 点检清单 3b。
#   landlock_tmpdir_probe <work_dir> <node_bin> <marker>
landlock_tmpdir_probe() {
  local work_dir="$1" node_bin="$2" marker="$3"
  local target="$work_dir/node_modules/@deepseek-ai/dsh-sandbox-local/lib/index.js"
  if [ ! -f "$target" ]; then
    note "landlock 探针: dsh-sandbox-local 不在被测树, 跳过"
    return 0
  fi
  if [ -z "$marker" ]; then
    note "landlock 探针: 注册表无 landlock 条目 (旧补丁集), 跳过"
    return 0
  fi
  if ! grep -qF -- "$marker" "$target" 2>/dev/null; then
    warn_record "landlock 探针: 注册表声明了 landlock 补丁 (marker=$marker) 但被测 lib 缺它 — 行为级覆盖缺失"
    return 0
  fi
  mkdir -p "$ROOT/tmp"
  local probe="$ROOT/tmp/probe-landlock.mjs" out
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
  # TMPDIR 显式钉到沙箱 tmp: 与 serve/路线将被测进程的 TMPDIR 保持一致,
  # 断言的是「补丁后授权表跟随进程 tmpdir」这一行为本身。
  if ! out="$(env -u LD_PRELOAD TMPDIR="$ROOT/tmp" "$node_bin" "$probe" "$work_dir" 2>&1)"; then
    echo "$out" >&2
    rm -f "$probe"
    fail "landlock tmpdir 行为探针失败 (marker 在但行为不符)"
  fi
  rm -f "$probe"
  ok "landlock tmpdir 行为探针: $out"
}

# --- fs-local link→rename 回退行为探针 (marker 条件触发; r2/r4/r5/serve 共用) ---
# 两个 hard-link 补丁此前只有 marker 级验证; 本探针把 fs-local 升到行为级。
# 上游对 linkFile 失败原样抛错, 补丁新增 platformLinkDenied (EACCES/EPERM/
# ENOTSUP/EOPNOTSUPP) → rename 回退; Android 的 link 拒绝在沙箱内无法自然
# 触发 (沙箱 fs 允许 link), 注入是唯一确定性验证途径 (testsystem 审计)。
# 注入门与审计原案不同 (校准发现): writeFileAtomic 未从编译产物导出, 实际走
# 公共 API —— LocalFileSystem 的公开实例字段 internals (上游注释 "Test hook
# forwarded to fsio") + writeText({kind:'createIfAbsent'}) + cordis Context。
# 双控制自证, 防探针自己变摆设:
#   负控制 EFOO (非 platform 错误码) → 必须原样抛出 —— 证明注入缝活着、
#     分支真的在区分错误码 (若缝死了, 真 link 会成功, 正控制就会假绿);
#   正控制 EACCES → rename 回退 → 文件落盘且内容正确。
# 触发 marker 由调用方从注册表派生, 与 landlock 探针同哲学。
#   fslocal_link_rename_probe <work_dir> <node_bin> <marker>
fslocal_link_rename_probe() {
  local work_dir="$1" node_bin="$2" marker="$3"
  local target="$work_dir/node_modules/@deepseek-ai/dsh-fs-local/lib/index.js"
  if [ ! -f "$target" ]; then
    note "fs-local 探针: dsh-fs-local 不在被测树, 跳过"
    return 0
  fi
  if [ -z "$marker" ]; then
    note "fs-local 探针: 注册表无 fs-local 补丁条目 (旧补丁集), 跳过"
    return 0
  fi
  if ! grep -qF -- "$marker" "$target" 2>/dev/null; then
    warn_record "fs-local 探针: 注册表声明了 fs-local 补丁 (marker=$marker) 但被测 lib 缺它 — 行为级覆盖缺失"
    return 0
  fi
  mkdir -p "$ROOT/tmp"
  local probe="$ROOT/tmp/probe-fslocal.mjs" out
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
  # TMPDIR 钉到沙箱 tmp, 与 landlock 探针同款运行约定
  if ! out="$(env -u LD_PRELOAD TMPDIR="$ROOT/tmp" "$node_bin" "$probe" "$work_dir" "$ROOT/tmp/probe-fs-stage" 2>&1)"; then
    echo "$out" >&2
    rm -f "$probe"
    fail "fs-local link→rename 行为探针失败 (marker 在但行为不符)"
  fi
  rm -f "$probe"
  ok "fs-local link→rename 行为探针: $out"
}

# --- 最新 release 下载助手 (r2/r5 与 run.sh baseline set 共用, 唯一实现) -------

# resolve_release_tag [tag|latest] -> 向 stdout 输出具体 tag。
# latest 走 GitHub releases/latest 重定向解析 (无需 token, 不占 API 配额);
# 显式 tag 仅做形态校验后原样返回。
# pre-dsh-* (pre 渠道, prerelease) 只能**显式**传入: latest 那条路按 GitHub 的
# 定义就看不见 prerelease, 所以基线永远 pin 不到 pre 产物——「能测 pre」与
# 「拿 pre 当基线」在这里是两件事, 前者放行, 后者仍然走不通。
resolve_release_tag() {
  local t="${1:-latest}"
  command -v curl >/dev/null 2>&1 || { echo "!! 解析 latest 需要 curl (pkg install curl), 或改用 baseline set <具体tag>" >&2; return 1; }
  case "$t" in
    latest)
      local loc
      loc="$(curl -sIo /dev/null -w '%{redirect_url}' https://github.com/ErEbusE/dsh-termux/releases/latest)"
      t="${loc##*/}"
      case "$t" in dsh-*-*-*) ;; *)
        echo "!! 无法解析 latest 指向的实际 tag (got: ${loc:-<空>})" >&2; return 1 ;;
      esac ;;
    dsh-*-*-*) ;;
    pre-dsh-*-*-*) ;;
    *) echo "!! 非法 tag: $t" >&2; return 1 ;;
  esac
  echo "$t"
}

# fetch_release_assets <下载目录> <已解析tag> -> 全新下载两个发布资产。
# 教训: 这里绝不能用 wget -c —— 对不同 tag 的同名旧文件续传会经代理拼出
# 「新包+旧尾」的损坏文件, 且若 pin 由坏文件现算还会自洽放行 (曾致 r1 以
# trailing garbage 失败)。所以先 rm 再完整下载。
fetch_release_assets() {
  local dl="$1" tag="$2" a tmp
  mkdir -p "$dl"
  for a in dsh-termux-runtime.tar.gz install.sh; do
    # 先下到 .part 再原子替换: 直接 -O 到目标名会在**下载失败前**就把已有的好
    # 文件删掉 (wget 一开写就截断), 于是一次打错 tag 就能把 pin 住的基线资产
    # 变成 0 字节——实测踩到过, 靠 baseline check 的哈希才发现。
    # 仍然坚持"绝不 -c 续传"的老教训: 每次都是全新文件, 只是落点换成临时名。
    tmp="$dl/.$a.part"
    rm -f "$tmp"
    if ! wget -t 2 -O "$tmp" \
      "https://github.com/ErEbusE/dsh-termux/releases/download/$tag/$a"; then
      rm -f "$tmp"
      echo "!! wget $a 失败 (tag=$tag; 网络受限先 export https_proxy/http_proxy)" >&2
      echo "   已保留 $dl/$a 的原有内容, 未被这次失败破坏。" >&2
      return 1
    fi
    mv -f "$tmp" "$dl/$a"
  done
}