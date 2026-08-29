#!/data/data/com.termux/files/usr/bin/bash
# sandbox-lib.sh — 沙箱测试公共核心。被 routes/*.sh 与 serve.sh source；独立执行无意义。
#
# 设计原则: 必须一致的逻辑只存一份。这里集中:
#   - 调用者 shell 清洗 (唯一的 unset 清单——漂移过的历史教训)
#   - grun stub / 沙箱目录 / 隔离导出
#   - 断言与计数报告 (fail/ok/note/warn_record/summary)
#   - 基线事实源加载与资产校验 (baseline.env 是唯一基线数据)
#   - 「线上运行时未被触碰」哨兵 (每条路线收尾必跑)

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
  NODE="$ROOT/prefix/node/bin/node"
  live_snapshot
}

# 「线上运行时未被触碰」哨兵。真属性是**线上 node 与路线起点一致**
# (inode/mtime/size/sha256 四元组), 而非「与沙箱不同」——用户线上 runtime
# 完全可能与基线是同一 release, 二进制按设计相同 (教训: 用户重装 1.2.2 后
# 旧断言「沙箱 == 线上即 FAIL」误报; 反过来, 同字节覆写会变 inode/mtime,
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
  [ -x "$LIVE_NODE" ] || fail "线上运行时 node 缺失 ($LIVE_NODE)"
  "$LIVE_NODE" --version >/dev/null 2>&1 || fail "线上 node 无法运行 (是不是被误补丁了?)"
  live_now="$(stat -c '%i.%Y.%s' "$LIVE_NODE").$(sha256sum "$LIVE_NODE" | cut -d' ' -f1)"
  if [ -n "$LIVE_PRISTINE" ]; then
    [ "$live_now" = "$LIVE_PRISTINE" ] \
      || fail "线上 node 在路线运行期间被改动 (inode/mtime/size/sha256 与起点不符)"
  fi
  ok "线上运行时未被触碰 (与起点快照一致, 线上 node 正常)"
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
# platformLinkDenied), 新 release 是三段式 "<patch>:<rel>:<marker>" —— 两种都认,
# 这样旧 release 认证不误红, 新 release 自动跟随, 发版前后零改动。

# shipped_patch_entries <patch-lib.sh 路径>: 逐行输出其 DSH_PATCH_SET 条目原文。
shipped_patch_entries() {
  awk '/^DSH_PATCH_SET=\(/,/^\)/' "$1" | sed -n 's/^[[:space:]]*"\([^"]*\)".*/\1/p'
}

# patch_entry_marker <entry>: 三段式取第三段; 两段式 (旧格式) 回退 platformLinkDenied。
patch_entry_marker() {
  local rest="${1#*:}" m
  m="${rest#*:}"
  if [ -z "$m" ] || [ "$m" = "$rest" ]; then printf '%s' platformLinkDenied
  else printf '%s' "$m"; fi
}

# --- landlock tmpdir 行为探针 (marker 条件触发; r2/r4/r5/serve 共用) -----------
# marker 断言只证明「文件改过」; 这里证明「行为对了」: 用被测树的 node 真实
# import 其 dsh-sandbox-local, 调 landlockProfileArgs 所在的 runnerArgv, 断言
#   - workspace-write 的 --rw 授权表包含本进程的 os.tmpdir()
#   - read-only 的 --rw 授权表仍然只有 /dev/null (补丁不得放宽只读语义)
# 自条件化: 被测树无 dsh-termux-landlock-tmpdir marker (旧 release/旧补丁集) 时
# note+跳过——r2/r5 认证旧产物不误红, 认证 1.2.0+ 产物时自动升级为行为级断言。
# kernel 级验证 (受限 mktemp 真的能写) 属人类实测, 见 serve.sh 点检清单 3b。
#   landlock_tmpdir_probe <work_dir> <node_bin>
landlock_tmpdir_probe() {
  local work_dir="$1" node_bin="$2"
  local target="$work_dir/node_modules/@deepseek-ai/dsh-sandbox-local/lib/index.js"
  if [ ! -f "$target" ]; then
    note "landlock 探针: dsh-sandbox-local 不在被测树, 跳过"
    return 0
  fi
  if ! grep -q "dsh-termux-landlock-tmpdir" "$target" 2>/dev/null; then
    note "landlock 探针: marker 不在 (旧补丁集), 跳过"
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

# --- 最新 release 下载助手 (r2/r5 与 run.sh baseline set 共用, 唯一实现) -------

# resolve_release_tag [tag|latest] -> 向 stdout 输出具体 tag。
# latest 走 GitHub releases/latest 重定向解析 (无需 token, 不占 API 配额);
# 显式 tag 仅做形态校验后原样返回。
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
    *) echo "!! 非法 tag: $t" >&2; return 1 ;;
  esac
  echo "$t"
}

# fetch_release_assets <下载目录> <已解析tag> -> 全新下载两个发布资产。
# 教训: 这里绝不能用 wget -c —— 对不同 tag 的同名旧文件续传会经代理拼出
# 「新包+旧尾」的损坏文件, 且若 pin 由坏文件现算还会自洽放行 (曾致 r1 以
# trailing garbage 失败)。所以先 rm 再完整下载。
fetch_release_assets() {
  local dl="$1" tag="$2" a
  mkdir -p "$dl"
  for a in dsh-termux-runtime.tar.gz install.sh; do
    rm -f "$dl/$a"
    wget -t 2 -O "$dl/$a" \
      "https://github.com/ErEbusE/dsh-termux/releases/download/$tag/$a" \
      || { echo "!! wget $a 失败 (网络受限先 export https_proxy/http_proxy)" >&2; return 1; }
  done
}