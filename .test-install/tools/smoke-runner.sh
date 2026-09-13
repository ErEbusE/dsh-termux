#!/data/data/com.termux/files/usr/bin/bash
# .tmp-debug/runner-smoke.sh — 新 run.sh 的**运行器路径**回归冒烟（不入库，可复跑）。
#
# 为什么要有它: `lib/state.sh` 的协议已单独冒烟过（state-smoke），但"选择 -> 前置 ->
# 执行 -> 补记 -> 聚合 -> 报告"这条**编排**路径还没被验过。清单里 15 条 executor
# 一个都还没写，所以这里用一个**暂存的假清单 + 假 case**在 ignore 的 `.test-install/state/smoke/` 内自造环境，
# 不动真 registry、不碰仓库代码。
#
# 自造环境是**独立 git 仓库**：否则 `git diff` 会指到外层真仓库的改动上，测试就
# 变成了"看仓库当前状态"而不是"验这段逻辑"。
#
# 覆盖: PASS / FAIL / UNMET(前置缺失，case 不执行) / ERROR(未登记的前置种类) /
#       ERROR(executor 缺失) / ERROR(case 崩溃未上报) / 未登记 id 与未知大类拒绝 /
#       NOT_SELECTED 补记 / READY 与 INCOMPLETE 的差别 / --json 的 stdout 纯净性 /
#       validate 的语义段与 glob 拼错检查 / verify 的 docs-only 与清单缺口两条路。
#
# 用法: bash .test-install/tools/smoke-runner.sh

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SMOKE="$REPO/.test-install/state/smoke/runner"
TI="$SMOKE/.test-install"
SCRATCH="$SMOKE/scratch"
GIT="git -c user.email=smoke@local -c user.name=smoke -C $SMOKE"
FAILED=0

ok()  { echo "  ok: $*"; }
bad() { echo "  FAIL: $*" >&2; FAILED=$((FAILED + 1)); }
check() { # $1=描述 $2=期望 $3=实际
  if [ "$2" = "$3" ]; then ok "$1 ($3)"; else bad "$1: 期望 $2, 实得 $3"; fi
}
pyget() { # $1=文件 $2=取值表达式
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"
}

setup() {
  rm -rf "$SMOKE"
  mkdir -p "$TI/lib" "$TI/cases/checklists" "$SCRATCH"
  cp "$REPO/.test-install/run.sh" "$TI/run.sh"
  cp "$REPO/.test-install/lib/"*.sh "$TI/lib/"
  # 人工清单正文是**数据文件**（registry 的 human 字段引用它），validate 双向断言它存在。
  cp "$REPO/.test-install/cases/checklists/serve-patch.txt" "$TI/cases/checklists/"

  cat > "$TI/cases/registry.tsv" <<'EOF'
# 冒烟用假清单（changes 用 .test-install/** 才会在自造仓库里匹配得到东西）
dry-run/fake-pass|dry-run|trivially passes|cases/dry-run-fake-pass.sh|-|-|.test-install/**|behavior|serve-patch|check,full
dry-run/fake-fail|dry-run|trivially fails|cases/dry-run-fake-fail.sh|-|-|.test-install/**|behavior|-|check,full
dry-run/fake-unmet|dry-run|needs a seed that is absent|cases/dry-run-fake-unmet.sh|-|seed:stable|.test-install/lib/**|behavior|-|check,full
dry-run/fake-crash|dry-run|exits without reporting|cases/dry-run-fake-crash.sh|-|-|.test-install/lib/**|behavior|-|check,full
dry-run/fake-missing-exec|dry-run|registered but not implemented|cases/dry-run-fake-absent.sh|-|-|.test-install/lib/**|behavior|-|check,full
dry-run/fake-unknown-prereq|dry-run|registry typo in requires|cases/dry-run-fake-unknown.sh|-|bogus:thing|.test-install/lib/**|behavior|-|check,full
# profiles 只给 full：check 不会选中它，于是场景 1 的计数不变，也不会让 check
# 去联网解析发布物输入（只有显式点选才跑它）。ADR-011 的闸门在场景 6 验。
dry-run/fake-release|dry-run|needs a resolved release instance|cases/dry-run-fake-release.sh|release-assets|-|.test-install/lib/**|behavior|-|full
EOF

  cat > "$TI/cases/dry-run-fake-pass.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
# shellcheck source=../lib/state.sh
. "$DSH_TI_DIR/lib/state.sh"
case_begin
assert_pass "always true"
case_finish
EOF

  cat > "$TI/cases/dry-run-fake-fail.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
. "$DSH_TI_DIR/lib/state.sh"
case_begin
assert_pass "one thing is fine"
assert_fail "on purpose"
case_finish
EOF

  cat > "$TI/cases/dry-run-fake-unmet.sh" <<'EOF'
#!/usr/bin/env bash
. "$DSH_TI_DIR/lib/state.sh"
case_unmet "should never run: prereq 缺失时 case 不该被执行"
EOF

  cat > "$TI/cases/dry-run-fake-crash.sh" <<'EOF'
#!/usr/bin/env bash
echo "boom (故意不上报结果)" >&2   # case 只准写 stderr
exit 7
EOF

  cat > "$TI/cases/dry-run-fake-unknown.sh" <<'EOF'
#!/usr/bin/env bash
. "$DSH_TI_DIR/lib/state.sh"
case_unmet "should never run"
EOF

  # 声明了 release-assets 的假 case：输入实例解析失败时**框架就不该放它进来**
  # （ADR-011：不回退稳定版）。真的被执行了就报 ERROR —— 场景 6 因此能抓住闸门失效。
  cat > "$TI/cases/dry-run-fake-release.sh" <<'EOF'
#!/usr/bin/env bash
. "$DSH_TI_DIR/lib/state.sh"
case_begin
case_error "release 输入实例未解析成功，本 case 不该被执行"
EOF

  # 独立仓库 + 全量入库：这样 `ls-files --others` 为空、glob 校验有东西可匹配，
  # 而且 verify 的改动范围只反映本脚本自己造出来的那点差异。
  # 沙箱与锁文件必须忽略: 它们是被测运行产生的，不属于"改动范围"，
  # 也不该进入 build receipt 的 worktree 摘要（否则同输入每跑一次换个 digest）。
  printf '.test-install/state/\n.test-install/sandbox-*/\n.test-install/.sandbox-*.lock\nscratch/\n' \
    > "$SMOKE/.gitignore"
  printf 'x\n' > "$SMOKE/NOTES.md"
  printf 'code\n' > "$SMOKE/CODE.txt"
  $GIT init -q
  $GIT add -A
  $GIT commit -q -m "smoke init"
  printf 'y\n' >> "$SMOKE/NOTES.md"   # 未提交的文档改动
}

# --- 场景 1: 全量 check —— 五种状态一次看全 --------------------------------
scenario_full() {
  echo "== 场景 1: check（六条假 case）"
  local rc
  bash "$TI/run.sh" check --json > "$SCRATCH/out1.json" 2>"$SCRATCH/err1.txt"; rc=$?
  check "聚合 exit" 2 "$rc"
  python3 - "$SCRATCH/out1.json" <<'PY'
import json, sys
rep = json.load(open(sys.argv[1]))
c = rep["counts"]
want = {"PASS": 1, "FAIL": 1, "UNMET": 1, "ERROR": 3, "NOT_SELECTED": 1, "selected": 6}
bad = {k: (c.get(k), v) for k, v in want.items() if c.get(k) != v}
if bad:
    print("  FAIL: 计数不符 %s" % bad, file=sys.stderr); sys.exit(1)
print("  ok: 计数 PASS1 FAIL1 UNMET1 ERROR3")
by = {x["id"]: x for x in rep["cases"]}
crash = by["dry-run/fake-crash"]
if crash["status"] != "ERROR" or "退出码 7" not in crash["reason"]:
    print("  FAIL: 崩溃未上报没被补记 ERROR: %r" % crash, file=sys.stderr); sys.exit(1)
print("  ok: 崩溃未上报被补记 ERROR（%s）" % crash["reason"])
if "缺少种子事实源" not in by["dry-run/fake-unmet"]["reason"]:
    print("  FAIL: UNMET 原因不可读", file=sys.stderr); sys.exit(1)
print("  ok: 前置缺失 -> UNMET，含可读原因")
if by["dry-run/fake-unknown-prereq"]["status"] != "ERROR":
    print("  FAIL: 未登记前置种类没归 ERROR", file=sys.stderr); sys.exit(1)
print("  ok: 未登记前置种类 -> ERROR（不是 UNMET）")
if by["dry-run/fake-pass"]["status"] != "PASS" or by["dry-run/fake-fail"]["status"] != "FAIL":
    print("  FAIL: PASS/FAIL 归类错", file=sys.stderr); sys.exit(1)
print("  ok: PASS / FAIL 归类正确")
PY
  [ $? -eq 0 ] || FAILED=$((FAILED + 1))
  check "交付结论" REJECTED "$(pyget "$SCRATCH/out1.json" 'd["verdict"]')"
  grep -q "^UNMET \[dry-run/fake-unmet\]: 缺少种子事实源" "$SCRATCH/err1.txt" \
    && ok "UNMET 就地打印在 stderr" || bad "UNMET 未就地打印"
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$SCRATCH/out1.json" \
    && ok "--json 的 stdout 是纯 JSON" || bad "--json 的 stdout 混入了非 JSON"
}

# --- 场景 2: 单条 PASS，人工项的交付结论 ------------------------------------
# 人工签认的完整链路（对象记录 / 观察台账 / 同轮终结）在 smoke-frozen.sh 里验。
# 这里只钉住**fail-closed** 这一条：裸清单名没有任何入口能换出 READY。
scenario_human() {
  echo "== 场景 2: 单条 PASS 与人工项的 fail-closed"
  local rc
  bash "$TI/run.sh" check -c dry-run/fake-pass --json > "$SCRATCH/out2.json" 2>/dev/null; rc=$?
  check "点选单条 -> exit" 0 "$rc"
  check "选中数（点选只跑点选的）" 1 "$(pyget "$SCRATCH/out2.json" 'd["counts"]["selected"]')"
  check "无人工证据 -> 执行 PASS 但交付 INCOMPLETE" INCOMPLETE "$(pyget "$SCRATCH/out2.json" 'd["verdict"]')"
  check "PASS 就是 PASS（不因缺人工证据被降级）" PASS "$(pyget "$SCRATCH/out2.json" 'd["aggregate"]')"
  check "其余 6 条被补记 NOT_SELECTED" 6 "$(pyget "$SCRATCH/out2.json" 'd["counts"]["NOT_SELECTED"]')"

  # 旧写法 `--signed <清单id>` 必须**不存在**：只写清单名指不回任何对象，
  # 人工证据必须能落到"哪一次执行、哪一棵树"上（ADR-010）。
  bash "$TI/run.sh" check -c dry-run/fake-pass --signed serve-patch \
    > "$SCRATCH/out3.txt" 2>&1; rc=$?
  check "裸清单名签认 -> 当作未知选项拒绝" 2 "$rc"
  grep -q "未知选项" "$SCRATCH/out3.txt" && ok "拒绝理由可读" || bad "没有说明为什么拒绝"
}

# --- 场景 3: 未登记 id / 未知大类 / 未知命令 必须硬拒绝 ---------------------
scenario_reject() {
  echo "== 场景 3: 非法选择必须硬拒绝"
  local rc
  bash "$TI/run.sh" check -c dry-run/nope >/dev/null 2>&1; rc=$?
  check "未登记 case id -> exit" 2 "$rc"
  bash "$TI/run.sh" check --class nope >/dev/null 2>&1; rc=$?
  check "未知大类 -> exit" 2 "$rc"
  bash "$TI/run.sh" frobnicate >/dev/null 2>&1; rc=$?
  check "未知命令 -> exit" 2 "$rc"
}

# --- 场景 4: validate 的语义段与 glob 拼错检查 ------------------------------
scenario_validate() {
  echo "== 场景 4: validate"
  local rc
  bash "$TI/run.sh" validate >/dev/null 2>&1; rc=$?
  check "含未登记前置种类 -> exit" 2 "$rc"
  bash "$TI/run.sh" validate --strict-executors >/dev/null 2>&1; rc=$?
  check "严格模式（executor 缺件）-> exit" 2 "$rc"

  sed 's/bogus:thing/-/' "$TI/cases/registry.tsv" > "$TI/cases/registry.new"
  mv "$TI/cases/registry.new" "$TI/cases/registry.tsv"
  bash "$TI/run.sh" validate >/dev/null 2>&1; rc=$?
  check "去掉未登记种类后结构自洽" 0 "$rc"

  # glob 拼错 = 该 case 从此永不被 diff 选中，而报告上看不出来 —— 必须报错
  printf '%s\n' \
    'dry-run/fake-typo|dry-run|glob typo|cases/dry-run-fake-typo.sh|-|-|patchs/**|behavior|-|full' \
    >> "$TI/cases/registry.tsv"
  bash "$TI/run.sh" validate 2>"$SCRATCH/err4.txt" >/dev/null; rc=$?
  check "changes glob 拼错 -> exit" 2 "$rc"
  grep -q "匹配不到任何文件" "$SCRATCH/err4.txt" \
    && ok "错误信息点明 glob 匹配不到文件" || bad "glob 拼错未给出可读原因"
  sed -i '$d' "$TI/cases/registry.tsv"
  # 恢复清单，免得 scenario 4 的改动被 verify 当成"代码改动"
  $GIT checkout -q -- .test-install/cases/registry.tsv
}

# --- 场景 5: verify 的两条边界（docs-only / 清单缺口） ----------------------
scenario_verify() {
  echo "== 场景 5: verify 的 docs-only 与清单缺口"
  local rc
  bash "$TI/run.sh" verify --diff-base HEAD >/dev/null 2>&1; rc=$?
  check "只有 .md 改动 -> exit" 0 "$rc"

  printf 'more\n' >> "$SMOKE/CODE.txt"   # 非文档、且不被任何 changes 覆盖
  bash "$TI/run.sh" verify --diff-base HEAD --json > "$SCRATCH/out5.json" 2>/dev/null; rc=$?
  check "非文档改动无 case 覆盖 -> exit" 2 "$rc"
  check "归类为框架 ERROR（清单缺口）" ERROR "$(pyget "$SCRATCH/out5.json" 'd["aggregate"]')"
  $GIT checkout -q -- CODE.txt
}

# --- 场景 6: 发布物输入实例解析失败 -> 依赖它的 case 记 UNMET（ADR-011） -----
# 用**非法 tag**制造解析失败：`resolve_release_tag` 对显式 tag 只做形态校验，不联网，
# 所以这条场景离线可复现。要验的是 fail-closed：**绝不回退稳定版**（那会得出"认证了
# 稳定渠道"的结论，而实际什么都没认证），并且独立 case 照跑。
scenario_release_instance() {
  echo "== 场景 6: 发布物实例解析失败 -> UNMET（不回退稳定版）"
  local rc
  bash "$TI/run.sh" check -c dry-run/fake-release -c dry-run/fake-pass \
    --release-tag bogus-not-a-tag --json > "$SCRATCH/out6.json" 2>"$SCRATCH/err6.txt"; rc=$?
  check "有 UNMET -> exit" 3 "$rc"
  check "聚合" UNMET "$(pyget "$SCRATCH/out6.json" 'd["aggregate"]')"
  check "发布物 case 记 UNMET" UNMET \
    "$(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print([c["status"] for c in d["cases"] if c["id"]=="dry-run/fake-release"][0])' "$SCRATCH/out6.json")"
  check "独立 case 照跑并通过" PASS \
    "$(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print([c["status"] for c in d["cases"] if c["id"]=="dry-run/fake-pass"][0])' "$SCRATCH/out6.json")"
  grep -q "发布物输入实例未解析成功" "$SCRATCH/err6.txt" \
    && ok "原因可读（点明是实例解析失败）" || bad "原因不可读"
  # 非法 selector 必须**不产生**实例记录：没有实例，就没有"认证了哪个主体"可写。
  local found=0 f
  for f in "$TI/state"/*/input-release.tsv; do
    [ -e "$f" ] && found=1
  done
  if [ "$found" = 1 ]; then
    bad "解析失败却写了 input-release.tsv（会让人以为有实例）"
  else
    ok "解析失败不写实例记录"
  fi
}

# --- 场景 7: 候选产物前置接受"归档或目录"（ADR-006） ------------------------
# `gh run download -n <name>` 落下来是**目录**，`gh api .../zip` 落下来是**归档**。
# 把候选产物钉死成其中一种，另一种会在"前置"这一步被记成 UNMET —— 那不是缺结论，
# 是入口写死了。这里直接测纯函数，不必造 case。
scenario_candidate_artifact() {
  echo "== 场景 7: 候选产物前置接受目录与归档（ADR-006）"
  local dir arch rc
  dir="$SCRATCH/artifact.d"; mkdir -p "$dir"
  arch="$SCRATCH/artifact.tar.gz"; printf 'x\n' > "$arch"

  probe() { # $1=DSH_CANDIDATE_ARTIFACT 的值（空串=未设置）
    (
      export DSH_HARNESS_ROOT="$SMOKE"
      unset DSH_CANDIDATE_ARTIFACT
      [ -n "$1" ] && export DSH_CANDIDATE_ARTIFACT="$1"
      # shellcheck source=../lib/state.sh
      . "$TI/lib/state.sh"
      state_check_require artifact:branch-candidate >/dev/null 2>&1
    )
  }
  probe "$dir"; rc=$?;  check "目录形态 -> 前置满足" 0 "$rc"
  probe "$arch"; rc=$?; check "归档形态 -> 前置满足" 0 "$rc"
  probe "$SCRATCH/nope"; rc=$?; check "不存在的路径 -> 前置缺失(UNMET)" 1 "$rc"
  probe ""; rc=$?;      check "未提供 -> 前置缺失(UNMET)" 1 "$rc"
  unset -f probe
}

# --- 场景 8: 种子事实源（set -u 下不炸；缺件/坏哈希各有返回码） --------------
# 这一条是被真机撞出来的：`seed_verify` 的 `local` 声明曾被一次"去空行"的编辑拼进
# 函数头注释里，声明整行被吞 —— `bash -n` 与 shellcheck 都不报（语法合法），只在
# `set -u` 下以 `unbound variable` 现形。所以这里在 set -u 的子 shell 里直接调它。
scenario_seed_facts() {
  echo "== 场景 8: 种子事实源"
  local rc
  mkdir -p "$TI/seeds"
  # shellcheck disable=SC2016
  probe_seed() {
    (
      export DSH_TI_DIR="$TI"
      # shellcheck source=../lib/seed.sh
      . "$TI/lib/seed.sh"
      seed_verify "$1" >/dev/null 2>&1
    )
  }
  probe_seed nope; rc=$?;   check "事实源不存在 -> 1（且不在 set -u 下炸）" 1 "$rc"
  {
    echo "SEED_NAME=broken"
    echo "SEED_TAG=dsh-0.0.0-x-0.0.0"
    echo "SEED_DSH_VERSION=0.0.0-x"
    echo "SEED_ASSET_1=absent.tar.gz:0000000000000000000000000000000000000000000000000000000000000000"
  } > "$TI/seeds/broken.env"
  probe_seed broken; rc=$?; check "资产缺件 -> 1" 1 "$rc"
  mkdir -p "$TI/seeds/seed-assets"
  printf 'x\n' > "$TI/seeds/seed-assets/absent.tar.gz"
  probe_seed broken; rc=$?; check "资产哈希不符 -> 1" 1 "$rc"
  sum="$(sha256sum "$TI/seeds/seed-assets/absent.tar.gz" | cut -d' ' -f1)"
  {
    echo "SEED_NAME=good"
    echo "SEED_TAG=dsh-0.0.0-x-0.0.0"
    echo "SEED_DSH_VERSION=0.0.0-x"
    echo "SEED_ASSET_1=absent.tar.gz:$sum"
  } > "$TI/seeds/good.env"
  probe_seed good; rc=$?;   check "资产齐备且哈希相符 -> 0" 0 "$rc"
  # 缺 SEED_TAG 的坏事实源 = 配置故障 -> 2（不是"缺件"）
  # shellcheck disable=SC2016
  printf 'SEED_NAME=notag\n' > "$TI/seeds/notag.env"
  probe_seed notag; rc=$?;  check "事实源缺 SEED_TAG -> 2（配置故障）" 2 "$rc"
  rm -rf "$TI/seeds"
  unset -f probe_seed
}

setup
scenario_full
scenario_human
scenario_reject
scenario_validate
scenario_verify
scenario_release_instance
scenario_candidate_artifact
scenario_seed_facts

echo
if [ "$FAILED" -eq 0 ]; then
  echo "RUNNER SMOKE: ALL OK"
else
  echo "RUNNER SMOKE: $FAILED 项失败" >&2
  exit 1
fi
