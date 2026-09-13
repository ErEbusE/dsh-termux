#!/data/data/com.termux/files/usr/bin/bash
# smoke-frozen.sh — 冻结对象、轮次与人工终结的回归冒烟（可复跑，CI 每 PR 必跑）。
#
# 真清单里的 executor 大多还没写，而"人工实测"这条链路的判定条件必须现在就能验：
# 在 `.test-install/state/smoke/frozen/` 里自造「独立 git 仓库 + 假清单 + 假 case +
# 假线上 HOME」，让一条假 case 装出一棵**载荷树**并走完 verify → serve --check-only
# → 观察 → finalize。全程不启动任何服务器、不联网、不碰真实线上 runtime。
#
# 覆盖（每条都对应一个具体的失效模式）:
#   * manifest 绑三层身份: build digest（哪组输入）、载荷摘要（哪些字节）、
#     run/case 与人工清单（哪一次、走哪条过程）
#   * 载荷边界: 人类实测会写的 home/tmp/ws 不在身份里，改它们**不**算漂移；
#     改 prefix/work 里的等长内容**算**漂移（这是旧身份函数抓不住的那一类）
#   * 源漂移: 工作区变了要显式 --allow-drift；对象漂移硬拒绝，开关绕不过去
#   * serve --check-only **不改动被测对象**（前后载荷摘要相同）
#   * 签认绑定对象: 没有观察记录不能终结；只有 start 没有 end 也不能；
#     裸清单 id 没有任何入口能换出 READY
#   * 逐对象与逐轮次: 新轮次不能消费旧轮次的对象确认
#   * clean 保留 receipts/ rounds/ frozen/（删了就永远无法终结/回溯）
#
# 用法: bash .test-install/tools/smoke-frozen.sh

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SMOKE="$REPO/.test-install/state/smoke/frozen"
TI="$SMOKE/.test-install"
LIVE="$SMOKE/fake-live-home"
SCRATCH="$SMOKE/scratch"
GIT="git -c user.email=smoke@local -c user.name=smoke -C $SMOKE"
FAILED=0

# 冒烟自己也要有 DSH_TI_DIR/DSH_HARNESS_ROOT：它直接调库里的观察台账与商店函数。
# shellcheck source=../lib/receipt.sh
. "$REPO/.test-install/lib/receipt.sh"
# shellcheck source=../lib/frozen.sh
. "$REPO/.test-install/lib/frozen.sh"

ok()  { echo "  ok: $*"; }
bad() { echo "  FAIL: $*" >&2; FAILED=$((FAILED + 1)); }
check() { if [ "$2" = "$3" ]; then ok "$1 ($3)"; else bad "$1: 期望 $2, 实得 $3"; fi }
has()   { grep -q -- "$2" "$1" && ok "$1 含: $2" || bad "$1 缺: $2"; }
count_lines() { local n; n="$(grep -c . "$1" 2>/dev/null)"; printf '%s\n' "${n:-0}"; }
count_rounds() { local d n=0; for d in "$TI/state/rounds"/*/; do [ -d "$d" ] && n=$((n + 1)); done; printf '%s\n' "$n"; }

run_sh()  { DSH_LIVE_HOME="$LIVE" bash "$TI/run.sh" "$@"; }
serve_sh() { DSH_LIVE_HOME="$LIVE" bash "$TI/serve.sh" "$@"; }

round_field() { sed -n "s/^$2\t//p" "$TI/state/rounds/$1/round.tsv" | head -n 1; }
last_verdict() { tail -1 "$TI/state/receipts/test.tsv" | cut -f14; }
last_profile() { tail -1 "$TI/state/receipts/test.tsv" | cut -f3; }
manifest_of() { # $1=case id -> 对象 id
  awk -F'\t' -v c="$1" '$1 == c { print $2; exit }' "$TI/state/rounds/$2/objects.tsv"
}
payload_file() { printf '%s/sandbox-dry-run-fake-payload/prefix/work/node_modules/@deepseek-ai/dsh/lib/bin.js\n' "$TI"; }

setup() {
  rm -rf "$SMOKE"
  mkdir -p "$TI/lib" "$TI/cases/checklists" "$SCRATCH" "$SMOKE/scripts" "$LIVE"
  cp "$REPO/.test-install/run.sh" "$REPO/.test-install/serve.sh" "$TI/"
  cp "$REPO/.test-install/lib/"*.sh "$TI/lib/"
  cp "$REPO/scripts/common.sh" "$SMOKE/scripts/"
  cp "$REPO/.test-install/cases/checklists/serve-patch.txt" "$TI/cases/checklists/"

  # 假线上 runtime: 只为让沙箱守卫有"线上"可定义（serve 不写它）。
  mkdir -p "$LIVE/.local/opt/dsh-termux-runtime/work" "$LIVE/.local/bin" "$LIVE/.dsh"
  printf 'live\n' > "$LIVE/.local/opt/dsh-termux-runtime/work/node"
  printf 'export x=1\n' > "$LIVE/.bashrc"

  cat > "$TI/cases/registry.tsv" <<'EOF'
# 冻结对象/轮次/finalize 冒烟用假清单
dry-run/fake-payload|dry-run|a fake runtime payload can be frozen and observed|cases/fake-payload.sh|repo-tree|-|.test-install/**|behavior|serve-patch|check,full
EOF

  # 假 case: 造出一棵**载荷**树（prefix/work + prefix/node/bin），并通过。
  # 刻意同时写 home/ 与 ws/ —— 人类实测会一直写它们，它们**不在**载荷边界里，
  # 场景里会去改它们并断言"这不算漂移"。
  cat > "$TI/cases/fake-payload.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
. "$DSH_TI_DIR/lib/state.sh"
case_begin
R="$DSH_SANDBOX_ROOT"
mkdir -p "$R/prefix/work/node_modules/@deepseek-ai/dsh/lib" "$R/prefix/node/bin" "$R/home" "$R/ws"
printf '{"name":"@deepseek-ai/dsh","version":"9.9.9-fake"}\n' \
  > "$R/prefix/work/node_modules/@deepseek-ai/dsh/package.json"
printf 'console.log(1)\n' > "$R/prefix/work/node_modules/@deepseek-ai/dsh/lib/bin.js"
printf '#!/bin/sh\necho v0.0.0-fake\n' > "$R/prefix/node/bin/node"
chmod +x "$R/prefix/node/bin/node"
printf '{"lockfileVersion":3}\n' > "$R/prefix/work/package-lock.json"
printf 'session\n' > "$R/home/.dsh-session"
assert_pass "假载荷树就位"
case_finish
EOF

  printf '.test-install/state/\n.test-install/sandbox-*/\n.test-install/.sandbox-*.lock\nscratch/\n' \
    > "$SMOKE/.gitignore"
  printf 'notes\n' > "$SMOKE/NOTES.md"
  $GIT init -q
  $GIT add -A
  $GIT commit -q -m "frozen smoke init"
}

# --- 场景 1: verify 开轮次 + 冻结对象 ---------------------------------------
R1=""
scenario_verify_freezes() {
  echo "== 场景 1: verify 开轮次、冻结对象、结论停在 INCOMPLETE"
  local rc
  R1="$(run_sh verify -c dry-run/fake-payload --diff-base HEAD 2>"$SCRATCH/r1.err")"
  rc=$?
  check "verify -> exit" 0 "$rc"
  printf '%s\n' "$R1" > "$SCRATCH/r1.out"
  has "$SCRATCH/r1.out" "人工必需项: serve-patch"
  has "$SCRATCH/r1.out" "交付结论:   INCOMPLETE"
  has "$SCRATCH/r1.out" "finalize"
  local rid; rid="$(ls "$TI/state/rounds" | head -n 1)"
  check "轮次目录已建立" 1 "$(count_rounds)"
  check "轮次已记录人工必需项" serve-patch "$(round_field "$rid" human_required)"
  check "轮次 build digest 非空" 64 "$(printf '%s' "$(round_field "$rid" build_digest)" | wc -c | tr -d ' ')"
  check "轮次里登记了 1 个对象" 1 "$(count_lines "$TI/state/rounds/$rid/objects.tsv")"
  [ -d "$TI/sandbox-dry-run-fake-payload" ] && ok "带人工项的通过 case 沙箱被保留（冻结）" \
    || bad "冻结对象的沙箱被删了"

  local mid; mid="$(manifest_of dry-run/fake-payload "$rid")"
  [ -n "$mid" ] && ok "对象 id 非空 ($mid)" || bad "对象 id 为空"
  local mf="$TI/state/frozen/frozen-$mid.tsv"
  [ -f "$mf" ] && ok "manifest 落盘且内容寻址" || bad "找不到 manifest $mf"
  check "manifest 记 case" dry-run/fake-payload "$(frozen_get "$mf" case_id)"
  check "manifest 记人工清单" serve-patch "$(frozen_get "$mf" checklists)"
  check "manifest 记轮次" "$rid" "$(frozen_get "$mf" round_id)"
  check "manifest 的 build digest == 本次运行" "$(round_field "$rid" build_digest)" \
    "$(frozen_get "$mf" build_digest)"
  check "manifest 记 dsh 版本" 9.9.9-fake "$(frozen_get "$mf" dsh_version)"
  check "manifest 记 node 版本" v0.0.0-fake "$(frozen_get "$mf" node_version)"
  check "载荷根有两个" 2 "$(printf '%s' "$(frozen_get "$mf" payload_roots)" | tr ',' '\n' | grep -c .)"
  [ -f "$TI/sandbox-dry-run-fake-payload/frozen.tsv" ] && ok "沙箱里有定位副本 frozen.tsv" \
    || bad "沙箱里缺 frozen.tsv"
}

# --- 场景 2: 载荷边界（可写区不算漂移） -------------------------------------
scenario_payload_boundary() {
  echo "== 场景 2: 载荷边界"
  local rid; rid="$(ls "$TI/state/rounds" | head -n 1)"
  local mid; mid="$(manifest_of dry-run/fake-payload "$rid")"
  local root="$TI/sandbox-dry-run-fake-payload"
  local d1 d2
  d1="$(frozen_payload_digest "$root")"
  # 人类实测期间一定会写的东西: 会话数据、工作区文件、临时文件、包缓存。
  printf 'more\n' >> "$root/home/.dsh-session"
  printf 'written by agent\n' > "$root/ws/file.txt"
  printf 'tmp\n' > "$root/tmp/t"
  mkdir -p "$root/prefix/work/node_modules/.cache"; printf 'cache\n' > "$root/prefix/work/node_modules/.cache/x"
  d2="$(frozen_payload_digest "$root")"
  check "写 home/ws/tmp 与 .cache 不改变载荷身份" "$d1" "$d2"
  ( DSH_TI_DIR="$TI" frozen_object_ok "$root" "$TI/state/frozen/frozen-$mid.tsv" ) >/dev/null 2>&1 \
    && ok "frozen_object_ok 判定未漂移" || bad "可写区被误判成漂移"
}

# --- 场景 3: serve --check-only 不改对象、能列出清单 -------------------------
scenario_serve_check() {
  echo "== 场景 3: serve --check-only 与旧开关守卫"
  local rid; rid="$(ls "$TI/state/rounds" | head -n 1)"
  local root="$TI/sandbox-dry-run-fake-payload"
  local before after rc
  # 旧版 serve 的开关是环境变量。静默忽略一次，就够让人以为"凭据已经复制进来了"
  # 而实际什么都没发生（真机踩到）。所以它们必须被**硬拒绝**并给出等价写法。
  WITH_CREDS=1 serve_sh --list > "$SCRATCH/legacy.out" 2>&1; rc=$?
  check "旧开关 WITH_CREDS=1 -> 硬拒绝" 2 "$rc"
  has "$SCRATCH/legacy.out" "--with-creds"
  REUSE=1 serve_sh --list > "$SCRATCH/legacy2.out" 2>&1; rc=$?
  check "旧开关 REUSE=1 -> 硬拒绝" 2 "$rc"
  has "$SCRATCH/legacy2.out" "没有等价开关"

  before="$(frozen_payload_digest "$root")"
  serve_sh --list > "$SCRATCH/list.out" 2>&1
  has "$SCRATCH/list.out" "dry-run/fake-payload"
  has "$SCRATCH/list.out" "ok"
  serve_sh --round "$rid" --check-only > "$SCRATCH/check.out" 2>&1; rc=$?
  check "--check-only -> exit" 0 "$rc"
  has "$SCRATCH/check.out" "冻结对象:"
  has "$SCRATCH/check.out" "landlock"          # 清单正文真的被打印了
  has "$SCRATCH/check.out" "finalize $rid --observed"
  after="$(frozen_payload_digest "$root")"
  check "serve --check-only 未改动被测对象" "$before" "$after"
  check "未启动服务时不留观察记录" 0 \
    "$(grep -c "$rid" "$TI/state/frozen/observations.tsv" 2>/dev/null || echo 0)"
  [ -f "$root/serve-browser.log" ] && bad "--check-only 不该生成浏览器观测文件" \
    || ok "--check-only 没有起服务，也没有交接观测文件"
}

# --- 场景 4: 源漂移与载荷漂移 ------------------------------------------------
scenario_drift() {
  echo "== 场景 4: 源漂移要显式允许；载荷漂移硬拒绝"
  local rid; rid="$(ls "$TI/state/rounds" | head -n 1)"
  local root="$TI/sandbox-dry-run-fake-payload"
  local f; f="$(payload_file)"
  local rc

  # 源漂移: 改一个**被跟踪**的仓库文件（对象本身没动）
  printf 'notes changed\n' > "$SMOKE/NOTES.md"
  serve_sh --round "$rid" --check-only > "$SCRATCH/drift-src.out" 2>&1; rc=$?
  check "源漂移 -> 拒绝启动" 1 "$rc"
  has "$SCRATCH/drift-src.out" "源漂移"
  serve_sh --round "$rid" --check-only --allow-drift > "$SCRATCH/drift-src2.out" 2>&1; rc=$?
  check "--allow-drift -> 允许（但仍标注旧主体）" 0 "$rc"
  has "$SCRATCH/drift-src2.out" "不提供当前工作区的资格"
  printf 'notes\n' > "$SMOKE/NOTES.md"

  # 载荷漂移: **等长**改写（旧身份函数抓不住的那一类）
  printf 'console.log(2)\n' > "$f"
  serve_sh --round "$rid" --check-only > "$SCRATCH/drift-pay.out" 2>&1; rc=$?
  check "载荷漂移 -> 硬拒绝" 1 "$rc"
  has "$SCRATCH/drift-pay.out" "冻结载荷"
  serve_sh --round "$rid" --check-only --allow-drift >/dev/null 2>&1; rc=$?
  check "--allow-drift 绕不过载荷漂移" 1 "$rc"
  printf 'console.log(1)\n' > "$f"
  serve_sh --round "$rid" --check-only >/dev/null 2>&1
  check "恢复内容后重新可起" 0 "$?"
}

# --- 场景 5: 签认必须绑定对象，且要有完整观察 --------------------------------
scenario_observation() {
  echo "== 场景 5: 观察台账与 finalize 的绑定"
  local rid; rid="$(ls "$TI/state/rounds" | head -n 1)"
  local mid; mid="$(manifest_of dry-run/fake-payload "$rid")"
  local rc

  run_sh finalize "$rid" > "$SCRATCH/f0.out" 2>&1; rc=$?
  check "不给 --observed -> 拒绝" 2 "$rc"
  has "$SCRATCH/f0.out" "--observed"

  # 裸清单 id（旧写法）必须**没有**任何入口换出 READY
  run_sh finalize "$rid" --observed serve-patch > "$SCRATCH/f1.out" 2>&1; rc=$?
  check "拿清单名当对象 id -> 拒绝" 2 "$rc"

  run_sh finalize "$rid" --observed "$mid" > "$SCRATCH/f2.out" 2>&1; rc=$?
  check "没有观察记录 -> 拒绝终结" 2 "$rc"
  has "$SCRATCH/f2.out" "完整的观察记录"

  ( DSH_TI_DIR="$TI" frozen_observe_append start "$mid" "$rid" dry-run/fake-payload serve-patch ok "smoke" )
  run_sh finalize "$rid" --observed "$mid" > "$SCRATCH/f3.out" 2>&1; rc=$?
  check "只有 start、没有 end -> 仍拒绝" 2 "$rc"

  ( DSH_TI_DIR="$TI" frozen_observe_append end "$mid" "$rid" dry-run/fake-payload serve-patch ok "smoke" )
  run_sh finalize "$rid" --observed "$mid" > "$SCRATCH/f4.out" 2>&1; rc=$?
  check "完整观察 -> 终结成功" 0 "$rc"
  has "$SCRATCH/f4.out" "交付结论:   READY"
  has "$SCRATCH/f4.out" "对象确认: 1 个"
  check "test 收据记下终结" verify+finalize "$(last_profile)"
  check "终结后的结论" READY "$(last_verdict)"

  # 逐对象: 另一个 case 的对象不能被顶替（用同一个 mid 再终结一次不该被当成新对象）
  [ -f "$TI/state/rounds/$rid/finalize-report.txt" ] && ok "终结报告留档" || bad "缺终结报告"
}

# --- 场景 6: 新轮次不能消费旧轮次的对象确认 ---------------------------------
scenario_new_round_isolation() {
  echo "== 场景 6: 轮次隔离"
  local old_rid; old_rid="$(ls "$TI/state/rounds" | head -n 1)"
  local old_mid; old_mid="$(manifest_of dry-run/fake-payload "$old_rid")"
  local rc
  # 这一轮的对象记录已存在，但新轮次会重装同一棵树 -> 新 manifest（run_id 不同）
  run_sh verify -c dry-run/fake-payload --diff-base HEAD >/dev/null 2>&1
  local new_rid; new_rid="$(ls -t "$TI/state/rounds" | head -n 1)"
  [ "$new_rid" != "$old_rid" ] && ok "新 verify 开出了新轮次 ($new_rid)" || bad "没有开出新轮次"

  run_sh finalize "$new_rid" --observed "$old_mid" > "$SCRATCH/n1.out" 2>&1; rc=$?
  check "用旧轮次的对象确认终结新轮次 -> 拒绝" 2 "$rc"
  # 拦下来的第一道是"这个对象不在本轮的确认里"：**对象 id 而不是清单名**才是关联键，
  # 所以拿别轮的对象来顶替一定对不上（"属于轮次"那道检查是同一件事的第二道闸）。
  has "$SCRATCH/n1.out" "未被 --observed 确认"

  local new_mid; new_mid="$(manifest_of dry-run/fake-payload "$new_rid")"
  run_sh finalize "$old_rid" --observed "$new_mid" > "$SCRATCH/n2.out" 2>&1; rc=$?
  check "反向（旧轮次 + 新对象）-> 也拒绝" 2 "$rc"
  run_sh finalize "$new_rid" --observed "$new_mid" >/dev/null 2>&1; rc=$?
  check "新轮次自己的观察没做 -> INCOMPLETE 路径拒绝" 2 "$rc"
  [ "$new_mid" != "$old_mid" ] && ok "新轮次的对象 id 与旧轮次不同" \
    || bad "两个轮次给出了同一个对象 id（run_id 没进身份?）"
}

# --- 场景 7: clean 保留证据 --------------------------------------------------
scenario_clean() {
  echo "== 场景 7: clean 保留 receipts/ rounds/ frozen/"
  run_sh clean >/dev/null 2>&1
  [ -d "$TI/sandbox-dry-run-fake-payload" ] && bad "clean 没删沙箱" || ok "沙箱已清理"
  [ -f "$TI/state/receipts/test.tsv" ] && ok "receipts/ 保留" || bad "receipts/ 被删了"
  [ -d "$TI/state/rounds" ] && ok "rounds/ 保留（否则人工项永远无法终结）" || bad "rounds/ 被删了"
  [ -d "$TI/state/frozen" ] && ok "frozen/ 保留（对象记录与观察台账）" || bad "frozen/ 被删了"
}

setup
scenario_verify_freezes
scenario_payload_boundary
scenario_serve_check
scenario_drift
scenario_observation
scenario_new_round_isolation
scenario_clean

echo
if [ "$FAILED" -eq 0 ]; then
  echo "FROZEN SMOKE: ALL OK"
else
  echo "FROZEN SMOKE: $FAILED 项失败" >&2
  exit 1
fi
