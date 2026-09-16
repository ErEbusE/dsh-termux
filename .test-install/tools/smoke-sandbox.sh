#!/data/data/com.termux/files/usr/bin/bash
# .tmp-debug/sandbox-smoke.sh — 隔离内核 + 收据的回归冒烟（不入库，可复跑）。
#
# 真清单里 15 条 executor 一个都还没写，所以这里在 `.test-install/state/smoke/` 里自造
# 「独立 git 仓库 + 假清单 + 假 case + **假线上 HOME**」，把隔离与收据这两件
# 事的判定条件全部摊开验证。绝不触碰真实线上 runtime —— 假线上 HOME 就是为此
# 存在的: 唯一能安全验证"守卫抓得住越界"的办法，是让越界发生在一个假的线上。
#
# 覆盖:
#   * 白名单环境: HOME/TMPDIR/XDG_*/DSH_HOME 全在沙箱内、无线上路径泄漏、
#     线上 wrapper 目录已从 PATH 摘掉、cwd 在沙箱内（相对落点不会写进仓库）
#   * 线上守卫: 假线上被改动 -> framework/live-guard ERROR（哪怕 case 自报通过）；
#     真实线上跑一次快照/校验必须为 0（不误报）
#   * 沙箱生命周期: run.sh 只创建（**从不删除**）；clean 是唯一删除者，默认交互
#   * build receipt: 内容寻址、跨运行同输入同摘要
#   * test receipt: 只追加、每次运行一行、含 build digest 与结论
#
# 用法: bash .test-install/tools/smoke-sandbox.sh

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SMOKE="$REPO/.test-install/state/smoke/sandbox"
TI="$SMOKE/.test-install"
LIVE="$SMOKE/fake-live-home"
SCRATCH="$SMOKE/scratch"
GIT="git -c user.email=smoke@local -c user.name=smoke -C $SMOKE"
FAILED=0

# shellcheck source=../lib/receipt.sh
. "$REPO/.test-install/lib/receipt.sh"

ok()  { echo "  ok: $*"; }
bad() { echo "  FAIL: $*" >&2; FAILED=$((FAILED + 1)); }
check() { if [ "$2" = "$3" ]; then ok "$1 ($3)"; else bad "$1: 期望 $2, 实得 $3"; fi }
pyget() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"; }
count_build_receipts() { # 不用 `ls | grep`（SC2010）: glob 对任何文件名都成立
  local f n=0
  for f in "$TI/state/receipts"/build-*.tsv; do [ -f "$f" ] && n=$((n + 1)); done
  printf '%s\n' "$n"
}

run_sh() { # 用**假线上 HOME** 起运行器，并把假线上 bin 塞进 PATH 以验 PATH 过滤
  DSH_LIVE_HOME="$LIVE" PATH="$LIVE/.local/bin:$PATH" bash "$TI/run.sh" "$@"
}

setup() {
  rm -rf "$SMOKE"
  mkdir -p "$TI/lib" "$TI/cases" "$SCRATCH"
  cp "$REPO/.test-install/run.sh" "$TI/run.sh"
  cp "$REPO/.test-install/lib/"*.sh "$TI/lib/"

  # --- 假线上 runtime: 结构上模仿真实布局（树 / symlink / 文件 / 数据目录）---
  mkdir -p "$LIVE/.local/opt/dsh-termux-runtime/work/node/bin" "$LIVE/.local/bin" "$LIVE/.dsh"
  printf 'live-node-binary\n' > "$LIVE/.local/opt/dsh-termux-runtime/work/node/bin/node"
  printf '#!/usr/bin/env bash\necho live-dsh\n' > "$LIVE/.local/opt/dsh-termux-runtime/work/dsh"
  ln -s "$LIVE/.local/opt/dsh-termux-runtime/work/dsh" "$LIVE/.local/bin/dsh"
  printf 'export FOO=bar\n' > "$LIVE/.bashrc"
  printf 'session\n' > "$LIVE/.dsh/session.jsonl"
  # 注意: ~/.dsh 不在守卫名单里（活着的会话一直在写它，详见 lib/sandbox.sh 注释）,
  # 这里造出来只是为了假线上结构逼真。

  cat > "$TI/cases/registry.tsv" <<'EOF'
# 隔离/收据冒烟用假清单
dry-run/probe-env|dry-run|whitelisted environment is fully inside the sandbox|cases/probe-env.sh|-|-|.test-install/**|behavior|-|check,full
dry-run/probe-touch|dry-run|touching the live runtime is caught by the guard|cases/probe-touch.sh|-|-|.test-install/**|behavior|-|check,full
dry-run/probe-relative|dry-run|relative writes land inside the sandbox|cases/probe-relative.sh|-|-|.test-install/**|behavior|-|check,full
dry-run/probe-fail|dry-run|a failing case keeps its sandbox|cases/probe-fail.sh|-|-|.test-install/**|behavior|-|check,full
dry-run/probe-human|dry-run|a passing case with a human checklist keeps its sandbox|cases/probe-human.sh|-|-|.test-install/**|behavior|serve-patch|check,full
EOF

  cat > "$TI/cases/probe-env.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
# shellcheck source=../lib/state.sh
. "$DSH_TI_DIR/lib/state.sh"
case_begin
in_sandbox() { case "$2" in "$DSH_SANDBOX_ROOT"/*) assert_pass "$1 在沙箱内 ($2)";;
                          *) assert_fail "$1 越界: $2";; esac; }
in_sandbox HOME "$HOME"
in_sandbox TMPDIR "$TMPDIR"
in_sandbox DSH_HOME "$DSH_HOME"
in_sandbox XDG_CONFIG_HOME "$XDG_CONFIG_HOME"
in_sandbox XDG_CACHE_HOME "$XDG_CACHE_HOME"
in_sandbox XDG_DATA_HOME "$XDG_DATA_HOME"
in_sandbox XDG_STATE_HOME "$XDG_STATE_HOME"
in_sandbox DSH_RUNTIME_DIR "$DSH_RUNTIME_DIR"
# cwd 也必须在沙箱内: 相对落点不许写进仓库
in_sandbox cwd "$PWD"
# 线上 wrapper 目录必须已从 PATH 摘掉
case ":$PATH:" in *":$DSH_LIVE_HOME/.local/bin:"*) assert_fail "PATH 仍含线上 wrapper 目录";;
                  *) assert_pass "线上 wrapper 目录已从 PATH 摘掉";; esac
# 环境里不许出现任何线上路径
# 泄漏判定用**具体的线上路径**而不是整个线上 HOME: DSH_LIVE_HOME 的值就是那个
# HOME，按 HOME 判会把"告诉 case 线上在哪"本身当成泄漏（库里的 check 也是这么写的）。
leak=0
while IFS= read -r kv; do
  case "${kv#*=}" in
    *"$DSH_LIVE_HOME/.local/opt/dsh-termux-runtime"*|*"$DSH_LIVE_HOME/.dsh"*|*"$DSH_LIVE_HOME/.local/bin/dsh"*)
      leak=$((leak+1));;
  esac
done < <(env)
[ "$leak" = 0 ] && assert_pass "白名单环境无线上路径" || assert_fail "白名单环境有 $leak 处线上路径"
# 运行器契约变量必须到位
for v in DSH_RESULTS DSH_CASE_ID DSH_CASE_CLASS DSH_HARNESS_ROOT DSH_BUILD_DIGEST; do
  [ -n "${!v:-}" ] && assert_pass "契约变量 $v 到位" || assert_fail "契约变量 $v 缺失"
done
case_finish
EOF

  cat > "$TI/cases/probe-touch.sh" <<EOF
#!/usr/bin/env bash
set -uo pipefail
. "\$DSH_TI_DIR/lib/state.sh"
case_begin
# 故意越界: 往**假的**线上 runtime 树里写一个文件（真实线上绝不能这么干；
# 这里存在的意义就是让守卫有东西可抓）。
touch "$LIVE/.local/opt/dsh-termux-runtime/work/TOUCHED-BY-CASE"
assert_pass "case 自报通过（守卫仍应判这次运行无效）"
case_finish
EOF

  cat > "$TI/cases/probe-relative.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
. "$DSH_TI_DIR/lib/state.sh"
case_begin
printf 'x\n' > ./relative-write.txt
[ -f "./relative-write.txt" ] && assert_pass "相对写入可写"
case "$PWD" in "$DSH_SANDBOX_ROOT"/*) assert_pass "相对落点在沙箱内";;
                *) assert_fail "相对落点越界: $PWD";; esac
[ -f "$DSH_HARNESS_ROOT/relative-write.txt" ] && assert_fail "相对写入漏进了仓库根目录" \
  || assert_pass "仓库根目录未被写入"
rm -f ./relative-write.txt
case_finish
EOF

  cat > "$TI/cases/probe-fail.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
. "$DSH_TI_DIR/lib/state.sh"
case_begin
assert_fail "故意失败（验沙箱在失败时被保留）"
case_finish
EOF

  # 通过、但**声明了人工清单**：新设计下它必须保留沙箱（那棵树就是要交给人类实测的）。
  cat > "$TI/cases/probe-human.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
. "$DSH_TI_DIR/lib/state.sh"
case_begin
assert_pass "通过，且带人工清单 -> 沙箱必须保留"
case_finish
EOF

  # 沙箱与锁文件必须忽略: 否则它们会进入 build receipt 的 worktree 摘要，
  # 于是"同输入"每跑一次都变一个 digest —— 内容寻址的前提就没了。
  printf '.test-install/state/\n.test-install/sandbox-*/\n.test-install/.sandbox-*.lock\nscratch/\n' \
    > "$SMOKE/.gitignore"
  printf 'x\n' > "$SMOKE/NOTES.md"
  $GIT init -q
  $GIT add -A
  $GIT commit -q -m "sandbox smoke init"
}

# --- 场景 1: 白名单环境与 cwd ------------------------------------------------
scenario_env() {
  echo "== 场景 1: 白名单环境 / PATH 过滤 / cwd"
  local rc
  run_sh check -c dry-run/probe-env --json > "$SCRATCH/out1.json" 2>"$SCRATCH/err1.txt"; rc=$?
  check "隔离充分的 case -> exit" 0 "$rc"
  check "聚合" PASS "$(pyget "$SCRATCH/out1.json" 'd["aggregate"]')"
  # run.sh 只创建、**从不删除**：删除一律归 `clean`（唯一删除者，默认交互确认）。
  if [ -d "$TI/sandbox-dry-run-probe-env" ]; then ok "通过的 case 沙箱被保留（run.sh 不删）"; else bad "通过的 case 沙箱被删了 —— run.sh 不该删沙箱"; fi

  # 带人工清单的 case 通过后同样保留，并把 serve 命令打印出来。
  run_sh check -c dry-run/probe-human --json > "$SCRATCH/out1b.json" 2>"$SCRATCH/err1b.txt"; rc=$?
  check "带人工清单的通过 case -> exit" 0 "$rc"
  if [ -d "$TI/sandbox-dry-run-probe-human" ]; then ok "带人工清单的通过 case 沙箱被保留"; else bad "带人工清单的通过 case 沙箱被删了"; fi
  grep -q 'serve.sh --sandbox' "$SCRATCH/err1b.txt" && ok "打印了 serve.sh --sandbox 命令" || bad "没有把人类实测入口打印出来"
}

# --- 场景 2: 守卫抓住越界 ----------------------------------------------------
scenario_guard() {
  echo "== 场景 2: 线上守卫（假线上被触碰）"
  local rc
  run_sh check -c dry-run/probe-touch --json > "$SCRATCH/out2.json" 2>"$SCRATCH/err2.txt"; rc=$?
  check "越界运行 -> exit" 2 "$rc"
  check "聚合被框架记录拉成 ERROR" ERROR "$(pyget "$SCRATCH/out2.json" 'd["aggregate"]')"
  check "交付结论" REJECTED "$(pyget "$SCRATCH/out2.json" 'd["verdict"]')"
  grep -q "framework/live-guard" "$SCRATCH/out2.json" && ok "报告里有 live-guard 记录" \
    || bad "报告里没有 live-guard 记录"
  grep -q "本地正在运行的 dsh runtime 在 case 运行期间被触碰" "$SCRATCH/err2.txt" \
    && ok "守卫打印了可读原因" || bad "守卫未打印原因"
  if [ -d "$TI/sandbox-dry-run-probe-touch" ]; then ok "越界的沙箱被保留供归因"; else bad "越界的沙箱被删了"; fi
  # 恢复假线上，免得影响后续场景
  rm -f "$LIVE/.local/opt/dsh-termux-runtime/work/TOUCHED-BY-CASE"
}

# --- 场景 3: 相对落点不越界 --------------------------------------------------
scenario_relative() {
  echo "== 场景 3: 相对写入落在沙箱内"
  local rc
  run_sh check -c dry-run/probe-relative --json > "$SCRATCH/out3.json" 2>/dev/null; rc=$?
  check "case -> exit" 0 "$rc"
  [ -f "$SMOKE/relative-write.txt" ] && bad "相对写入漏进了烟雾仓库根目录" \
    || ok "烟雾仓库根目录未被污染"
}

# --- 场景 4: 失败保留沙箱 ----------------------------------------------------
scenario_keep_on_fail() {
  echo "== 场景 4: 失败时保留沙箱"
  local rc
  run_sh check -c dry-run/probe-fail >/dev/null 2>&1; rc=$?
  check "失败 case -> exit" 1 "$rc"
  [ -d "$TI/sandbox-dry-run-probe-fail" ] && ok "失败沙箱已保留" || bad "失败沙箱被删了"
}

# --- 场景 5: 收据 ------------------------------------------------------------
scenario_receipts() {
  echo "== 场景 5: build / test 收据"
  local d1 d2 n1 n2
  d1="$(tail -1 "$TI/state/receipts/test.tsv" | cut -f4)"
  n1="$(count_build_receipts)"
  run_sh check -c dry-run/probe-env >/dev/null 2>&1
  d2="$(tail -1 "$TI/state/receipts/test.tsv" | cut -f4)"
  n2="$(count_build_receipts)"
  check "同输入两次运行得到同一 build digest" "$d1" "$d2"
  check "内容寻址: build 收据没有随运行增殖" "$n1" "$n2"
  [ -f "$TI/state/receipts/build-$d1.tsv" ] && ok "build 收据按 digest 落盘" || bad "找不到 build 收据"
  local lines
  lines="$(wc -l < "$TI/state/receipts/test.tsv")"
  [ "$lines" -ge 6 ] && ok "test 收据只追加（已有 $lines 行）" || bad "test 收据行数异常: $lines"
  grep -q "	dsh-termux/" "$TI/state/receipts/test.tsv" && ok "test 收据含 harness 身份" || bad "test 收据缺身份"
}

# --- 场景 6: 对象身份的性质 --------------------------------------------------
# 这一组里有四条是**评审驳回过旧实现**之后补的：旧版只记 (类型, 相对路径, 大小)，
# 于是等长改写、改执行位、改符号链接目标都"看起来没变"——而"这两棵树是不是同一份
# 字节"的判定正建立在这条摘要上（它仍被 receipt 的树身份使用）。
scenario_tree_id() {
  echo "== 场景 6: receipt_tree_id 的性质（内容清单，不是形状摘要）"
  local a="$SCRATCH/tree-a" b="$SCRATCH/tree-b" d1 d2 d3
  rm -rf "$a" "$b"
  mkdir -p "$a/sub" "$b/sub"
  printf 'x\n' > "$a/sub/f1"; printf 'yy\n' > "$a/f2"
  chmod 755 "$a/sub/f1"; ln -s f1 "$a/sub/link"
  cp -a "$a/." "$b/"
  touch -d '2001-01-01' "$b/sub/f1" "$b/f2" 2>/dev/null || true
  d1="$(receipt_tree_id "$a")"; d2="$(receipt_tree_id "$b")"
  check "同内容、不同路径/时间戳 -> 同一身份" "$d1" "$d2"

  # 等长改写: 6 字节换成 6 字节。这是旧实现漏掉的那一类。
  printf 'j\n' > "$b/sub/f1"
  d3="$(receipt_tree_id "$b")"
  [ "$d1" != "$d3" ] && ok "等长内容改写 -> 身份变了" || bad "等长内容改写后身份没变"
  printf 'x\n' > "$b/sub/f1"

  chmod 644 "$b/sub/f1"
  d3="$(receipt_tree_id "$b")"
  [ "$d1" != "$d3" ] && ok "执行位变化 -> 身份变了" || bad "执行位变了身份没变"
  chmod 755 "$b/sub/f1"

  rm -f "$b/sub/link"; ln -s f2 "$b/sub/link"
  d3="$(receipt_tree_id "$b")"
  [ "$d1" != "$d3" ] && ok "符号链接目标变化 -> 身份变了" || bad "符号链接目标变了身份没变"
  rm -f "$b/sub/link"; ln -s f1 "$b/sub/link"

  # 目录大小不参与: 目录 st_size 取决于分配与条目布局，跨副本不稳定。
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do : > "$b/sub/tmp$i"; done
  for i in 1 2 3 4 5 6 7 8 9 10; do rm -f "$b/sub/tmp$i"; done
  d3="$(receipt_tree_id "$b")"
  check "目录条目增删后回到同一身份（不含目录大小）" "$d1" "$d3"

  check "不存在的目录 -> absent（不是空串）" absent "$(receipt_tree_id "$SCRATCH/nope-$$")"
}

# --- 场景 8: 两种环境政策（case 白名单 vs serve 父环境） ----------------------
# 这两条政策**刻意不同**（server 的人类实测要跑真实用户的环境；见 ADR-010），
# 所以它们各自的边界必须各自钉住——否则哪天有人"顺手统一"一下，失效是静默的。
scenario_env_policies() {
  echo "== 场景 8: case 白名单 与 serve 父环境 的边界"
  (
    set -uo pipefail
    export DSH_TI_DIR="$TI" DSH_LIVE_HOME="$LIVE"
    # shellcheck source=../lib/sandbox.sh
    . "$REPO/.test-install/lib/sandbox.sh"
    SANDBOX_ROOT="$TI/sandbox-policy"; SANDBOX_NAME=policy
    mkdir -p "$SANDBOX_ROOT/home" "$SANDBOX_ROOT/tmp" "$SANDBOX_ROOT/bin"

    # --- case 政策：白名单 ---------------
    SANDBOX_PARENT_PROBE=from-parent
    export SANDBOX_PARENT_PROBE
    sandbox_build_env
    if printf '%s\n' "${SANDBOX_ENV[@]}" | grep -q '^SANDBOX_PARENT_PROBE='; then
      echo "FAIL: case 的白名单不该继承父环境的任意变量"
    else
      echo "ok: case 白名单不继承父环境任意变量"
    fi
    if printf '%s\n' "${SANDBOX_ENV[@]}" | grep -q '^HOME='"$SANDBOX_ROOT"'/home$'; then
      echo "ok: case 白名单钉住了 HOME"
    else
      echo "FAIL: case 白名单没钉住 HOME"
    fi

    # --- serve 政策：父环境 − 危险项 + 钉子 ---------------
    #   用 LD_PROBE 而不是 LD_PRELOAD 探 LD_* 这条规则：真设 LD_PRELOAD 会让这个子 shell
    #   里每一次外部命令都往 stderr 吐 loader 警告，把冒烟输出淹掉。
    export LD_PROBE=/evil.so GH_TOKEN=secret-value ANDROID_ART_ROOT=/apex/com.android.art
    export SANDBOX_LEAKY="$LIVE/.local/opt/dsh-termux-runtime/work"
    sandbox_env_human
    joined="$(printf '%s\n' "${SANDBOX_ENV[@]}")"
    for bad in LD_PROBE GH_TOKEN SANDBOX_LEAKY; do
      if printf '%s\n' "$joined" | grep -q "^$bad="; then
        echo "FAIL: serve 政策把 $bad 带进了沙箱"
      else
        echo "ok: serve 政策丢弃 $bad"
      fi
    done
    case " $SANDBOX_ENV_DROPPED " in
      *" SANDBOX_LEAKY "*) echo "ok: 含线上路径的变量被记录在丢弃名单里" ;;
      *) echo "FAIL: 含线上路径的变量没有出现在丢弃名单: $SANDBOX_ENV_DROPPED" ;;
    esac
    # 默认**保留** Android 三变量：这是本决策的要点——不替产品把问题修好。
    if printf '%s\n' "$joined" | grep -q '^ANDROID_ART_ROOT='; then
      echo "ok: serve 默认保留 ANDROID_ART_ROOT（不替产品修问题）"
    else
      echo "FAIL: serve 默认把 ANDROID_ART_ROOT 丢了"
    fi
    if printf '%s\n' "$joined" | grep -q '^SANDBOX_PARENT_PROBE=from-parent$'; then
      echo "ok: serve 政策继承普通父环境变量"
    else
      echo "FAIL: serve 政策丢了普通父环境变量"
    fi
    if printf '%s\n' "$joined" | grep -q '^HOME='"$SANDBOX_ROOT"'/home$'; then
      echo "ok: serve 政策同样把 HOME 钉进沙箱"
    else
      echo "FAIL: serve 政策没钉住 HOME（隔离的底线）"
    fi
    if sandbox_env_leak_check; then
      echo "ok: 两种政策产出的环境都通过泄漏检查"
    else
      echo "FAIL: 环境泄漏检查不通过"
    fi
    # 仅诊断的剥离开关
    sandbox_env_human --strip-android-root
    if printf '%s\n' "${SANDBOX_ENV[@]}" | grep -q '^ANDROID_ART_ROOT='; then
      echo "FAIL: --strip-android-root（仅诊断）没有剥离"
    else
      echo "ok: --strip-android-root（仅诊断）才剥离 Android 三变量"
    fi
  ) | while IFS= read -r line; do
        case "$line" in
          ok:*)  echo "  $line" ;;
          FAIL:*) echo "  FAIL:${line#FAIL:}" >&2 ;;
        esac
      done
  # 子 shell 里数不到失败，用 grep 复查一遍
  missing="$( (
    set -uo pipefail
    export DSH_TI_DIR="$TI" DSH_LIVE_HOME="$LIVE"
    . "$REPO/.test-install/lib/sandbox.sh"
    SANDBOX_ROOT="$TI/sandbox-policy"; SANDBOX_NAME=policy
    sandbox_env_human
    printf '%s\n' "${SANDBOX_ENV[@]}" | grep -cE '^(LD_PROBE|GH_TOKEN)='
  ) )"
  check "serve 政策下危险变量计数为 0（ANDROID_* 默认保留，不算危险项）" 0 "$missing"
}

# --- 场景 7: 真实线上不误报（只读快照，绝不改动） ----------------------------
scenario_real_guard() {
  echo "== 场景 7: 真实线上 runtime 的守卫不误报"
  local rc
  (
    set -uo pipefail
    export DSH_TI_DIR="$REPO/.test-install"
    export DSH_LIVE_HOME="$HOME"
    # shellcheck source=../lib/sandbox.sh
    . "$REPO/.test-install/lib/sandbox.sh"
    sandbox_guard_snapshot "$SCRATCH/real.before.tsv"
    sandbox_guard_verify "$SCRATCH/real.before.tsv" "$SCRATCH/real.after.tsv"
  ) >/dev/null 2>&1; rc=$?
  check "同一份真实线上做两次快照 -> 一致" 0 "$rc"
}

# --- 场景 8: serve 的任务清单加载 + clean 作为唯一删除者 ----------------------
# 这两条一起验，因为它们共享同一条纪律：**删除与启动是分开的**——serve 只读清单、
# 记台账、起服务；clean 才删，而且默认要人逐条确认。
scenario_checklist_and_clean() {
  echo "== 场景 8: 任务清单加载 + clean 唯一删除者"
  local rc base="$SCRATCH/cl" latest
  rm -rf "$base"; mkdir -p "$base/checklists/archived"
  printf "OLD\n" > "$base/checklists/2026-09-10-old.checklist.md"
  printf "LATEST\n" > "$base/checklists/2026-09-16-new.checklist.md"
  printf "ARCHIVED\n" > "$base/checklists/archived/2026-08-01-arc.checklist.md"
  printf "not-a-checklist\n" > "$base/checklists/readme.txt"

  # 记录上一次 serve 的台账：clean 靠它标出「用过」与「没用过」。
  printf "sandbox-dry-run-probe-human\t2026-09-16T00:00:00Z\n" > "$TI/state/served.tsv"
  mkdir -p "$TI/sandbox-dry-run-probe-env/tmp"   # 一个没有台账记录的沙箱

  # --dry-run 必须只列、不删（两个沙箱都还在）。
  bash "$TI/run.sh" clean --dry-run > "$SCRATCH/clean-dry.txt" 2>&1; rc=$?
  check "clean --dry-run -> exit" 0 "$rc"
  [ -d "$TI/sandbox-dry-run-probe-env" ] && ok "--dry-run 未删沙箱" || bad "--dry-run 竟然删了沙箱"
  grep -q "2026-09-16T00:00:00Z" "$SCRATCH/clean-dry.txt" && ok "打印了 serve 启动时间戳" \
    || bad "没有打印启动时间戳（人无法辨认）"
  grep -q "serve 启动记录: 无" "$SCRATCH/clean-dry.txt" && ok "无记录的沙箱被显式标注" \
    || bad "无记录的沙箱没有被区分出来"

  # 非交互（无 tty）下默认必须**跳过**，绝不默默删。
  bash "$TI/run.sh" clean < /dev/null > "$SCRATCH/clean-nointeractive.txt" 2>&1; rc=$?
  check "clean 非交互 -> exit" 0 "$rc"
  [ -d "$TI/sandbox-dry-run-probe-env" ] && ok "非交互默认不删（安全）" || bad "非交互竟然删了沙箱"

  # --yes 才真删，且台账随之清掉。
  bash "$TI/run.sh" clean --yes > "$SCRATCH/clean-yes.txt" 2>&1; rc=$?
  check "clean --yes -> exit" 0 "$rc"
  [ -d "$TI/sandbox-dry-run-probe-env" ] && bad "--yes 没有删除沙箱" || ok "--yes 删除了沙箱"
  [ -f "$TI/state/served.tsv" ] && bad "删除后启动台账应被清掉" || ok "启动台账被清掉"
  [ -d "$TI/state/receipts" ] && ok "receipts/ 证据被保留" || bad "receipts/ 被误删"

  # 任务清单「取最新一个」，且排除 archived/ 与非 *.checklist.md。
  latest="$(find "$base/checklists" -maxdepth 1 -name "*.checklist.md" -print | LC_ALL=C sort | tail -n 1)"
  [ "$(basename "$latest")" = "2026-09-16-new.checklist.md" ] \
    && ok "任务清单取最新一份（排除 archived/ 与 .txt）" \
    || bad "任务清单选取错误: $(basename "$latest")"
}
setup
scenario_env
scenario_guard
scenario_relative
scenario_keep_on_fail
scenario_receipts
scenario_tree_id
scenario_env_policies
scenario_real_guard
scenario_checklist_and_clean

echo
if [ "$FAILED" -eq 0 ]; then
  echo "SANDBOX SMOKE: ALL OK"
else
  echo "SANDBOX SMOKE: $FAILED 项失败" >&2
  exit 1
fi
