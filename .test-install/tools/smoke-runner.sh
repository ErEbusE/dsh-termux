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

# --- 场景 2: 单条 PASS 的交付结论（自动层） --------------------------------
# 交付结论只看自动层：无 FAIL/ERROR/UNMET 就是 READY。人类实测不在这里判——
# 它在沙箱里做，凭据走合并提交的 Tested-by（AGENTS §6）。
scenario_human() {
  echo "== 场景 2: 单条 PASS -> READY（纯自动层结论）"
  local rc
  bash "$TI/run.sh" check -c dry-run/fake-pass --json > "$SCRATCH/out2.json" 2>/dev/null; rc=$?
  check "点选单条 -> exit" 0 "$rc"
  check "选中数（点选只跑点选的）" 1 "$(pyget "$SCRATCH/out2.json" 'd["counts"]["selected"]')"
  check "PASS 且无 UNMET -> READY" READY "$(pyget "$SCRATCH/out2.json" 'd["verdict"]')"
  check "PASS 就是 PASS" PASS "$(pyget "$SCRATCH/out2.json" 'd["aggregate"]')"
  check "其余 6 条被补记 NOT_SELECTED" 6 "$(pyget "$SCRATCH/out2.json" 'd["counts"]["NOT_SELECTED"]')"

  # 被删掉的旧入口必须真的不存在（不是"还在但没人用"）。
  bash "$TI/run.sh" check -c dry-run/fake-pass --signed serve-patch \
    > "$SCRATCH/out3.txt" 2>&1; rc=$?
  check "已删除的 --signed -> 未知选项拒绝" 2 "$rc"
  grep -q "未知选项" "$SCRATCH/out3.txt" && ok "拒绝理由可读" || bad "没有说明为什么拒绝"
  bash "$TI/run.sh" check -c dry-run/fake-pass --freeze >/dev/null 2>&1; rc=$?
  check "已删除的 --freeze -> 未知选项拒绝" 2 "$rc"
  bash "$TI/run.sh" finalize whatever >/dev/null 2>&1; rc=$?
  check "已删除的 finalize 子命令 -> 未知命令拒绝" 2 "$rc"
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
  probe_seed nope; rc=$?;   check "事实源不存在 -> 3（UNMET：缺可测输入，且不在 set -u 下炸）" 3 "$rc"

  # 路径穿越（安全回归，顾问审计 R1 实测复现过的真缺陷）：`.env` 是普通文本，条目
  # 里的"资产名"会被拼成路径。**库外**放一个受害文件，用 `../../` 让旧扁平位置的
  # src 指到它；要求 (a) 不移动、不删除它，(b) 该条目被判为事实源损坏(ERROR=2)。
  # 没有这条断言，任何"顺手简化"都可能把 mv/rm 的路径来源重新变成未校验的文本。
  local victim="$SCRATCH/cas-victim" tdir="$SCRATCH/cas-trav"
  rm -rf "$victim" "$tdir"; mkdir -p "$victim" "$tdir/seeds/seed-assets"
  printf 'USER-DATA\n' > "$victim/precious.txt"
  local vsum; vsum="$(sha256sum "$victim/precious.txt" | cut -d' ' -f1)"
  # 相对深度必须**实测对齐**：记录的"资产名"会被拼在
  # `$tdir/seeds/seed-assets/` 之下，所以从那里回到 `$SCRATCH` 要**三**层
  # （seed-assets → seeds → tdir → scratch）。写成 `../../` 只到 `$tdir`，
  # 于是记录指向 `$tdir/cas-victim/...`（不存在）——迁移什么都不做、受害文件
  # 自然还在，断言"仍活着"**因为错误的原因**而通过（反证见下一条）。
  # 三个 `..` 才真正指向库外的受害文件；用它对着未修复的库跑，文件会被移走。
  {
    echo "SEED_NAME=evil"
    echo "SEED_TAG=dsh-0.0.9-x-0.0.9"
    echo "SEED_DSH_VERSION=0.0.9-x"
    echo "SEED_ASSET_1=../../../cas-victim/precious.txt:$vsum"
  } > "$tdir/seeds/evil.env"
  (
    export DSH_TI_DIR="$tdir"
    set -uo pipefail
    # shellcheck source=../lib/seed.sh
    . "$TI/lib/seed.sh"
    seed_migrate_legacy >/dev/null 2>&1
  )
  rc=$?; check "穿越条目下 migrate 正常返回（不炸）-> 0" 0 "$rc"
  [ -f "$victim/precious.txt" ] \
    && check "穿越条目**不得**移动/删除库外文件" 0 0 \
    || check "穿越条目**不得**移动/删除库外文件" 0 1
  (
    export DSH_TI_DIR="$tdir"
    set -uo pipefail
    # shellcheck source=../lib/seed.sh
    . "$TI/lib/seed.sh"
    seed_verify evil >/dev/null 2>&1
  )
  rc=$?; check "穿越条目 = 事实源损坏 -> 2（ERROR）" 2 "$rc"
  rm -rf "$victim" "$tdir"
  {
    echo "SEED_NAME=broken"
    echo "SEED_TAG=dsh-0.0.0-x-0.0.0"
    echo "SEED_DSH_VERSION=0.0.0-x"
    echo "SEED_ASSET_1=absent.tar.gz:0000000000000000000000000000000000000000000000000000000000000000"
  } > "$TI/seeds/broken.env"
  probe_seed broken; rc=$?; check "资产缺件 -> 3（UNMET）" 3 "$rc"
  mkdir -p "$TI/seeds/seed-assets"
  printf 'x\n' > "$TI/seeds/seed-assets/absent.tar.gz"
  # 语义要点：内容寻址下**身份即内容**，所以"同名旧位置文件内容不符"不是"对象损坏"，
  # 而是"pin 的那个对象根本不在" -> UNMET(3)。真正的"可读但与 pin 不符"是下面那条
  # CAS 对象被改（目录名与内容不一致）-> FAIL(1)。两种情形都响亮、都阻断资格
  # （ADR-003：必需 UNMET -> INCOMPLETE），区别只在归类是否诚实。
  probe_seed broken; rc=$?; check "旧扁平位置、内容与 pin 不符 => 该对象不在 -> 3（UNMET）" 3 "$rc"
  # 内容寻址布局：对象在 <sha256>/<名> 下
  sum="$(sha256sum "$TI/seeds/seed-assets/absent.tar.gz" | cut -d' ' -f1)"
  mkdir -p "$TI/seeds/seed-assets/$sum"
  mv "$TI/seeds/seed-assets/absent.tar.gz" "$TI/seeds/seed-assets/$sum/absent.tar.gz"
  {
    echo "SEED_NAME=good"
    echo "SEED_TAG=dsh-0.0.0-x-0.0.0"
    echo "SEED_DSH_VERSION=0.0.0-x"
    echo "SEED_ASSET_1=absent.tar.gz:$sum"
  } > "$TI/seeds/good.env"
  probe_seed good; rc=$?;   check "CAS 资产齐备且哈希相符 -> 0" 0 "$rc"
  # 对象内容被改（目录名不再代表内容）= FAIL，不是"缺件"
  printf 'tampered\n' > "$TI/seeds/seed-assets/$sum/absent.tar.gz"
  probe_seed good; rc=$?;   check "CAS 对象内容与目录名不符 -> 1（FAIL，不是缺件）" 1 "$rc"
  printf 'x\n' > "$TI/seeds/seed-assets/$sum/absent.tar.gz"
  # 缺 SEED_TAG 的坏事实源 = 配置故障 -> 2（不是"缺件"）
  # shellcheck disable=SC2016
  printf 'SEED_NAME=notag\n' > "$TI/seeds/notag.env"
  probe_seed notag; rc=$?;  check "事实源缺 SEED_TAG -> 2（配置故障）" 2 "$rc"
  # 内容寻址与"失败不破坏已有种子"（勿回退 #24 的回归）
  scenario_seed_cas
  rm -rf "$TI/seeds"
  unset -f probe_seed
}

# 勿回退 #24 的回归：旧布局下"加第二颗种子会覆盖第一颗的字节"，而 .part→mv 是
# 逐资产、不是每颗种子原子的，所以 re-pin 中途失败会毁掉旧种子。这里走**真函数**
# （seed_install_cas / seed_write_env / seed_resolve_record / seed_migrate_legacy），
# 不另写一份逻辑；反证是"两份假发布物内容确实不同"。
scenario_seed_cas() {
  local rc n_obj lsum
  local CAS="$TI/seeds/seed-assets"
  rm -rf "$TI/seeds"; mkdir -p "$TI/seeds/seed-assets"

  seed_probe() { # $1=在 source 了 seed.sh 的 set -u 子 shell 里求值的片段
    (
      export DSH_TI_DIR="$TI"
      set -uo pipefail
      # shellcheck source=../lib/seed.sh
      . "$TI/lib/seed.sh"
      eval "$1"
    )
  }

  # 两份**内容不同**、**资产名相同**的假发布物 —— 正是旧布局会互相覆盖的形态。
  mkdir -p "$TI/stageA" "$TI/stageB"
  printf 'runtime-A\n' > "$TI/stageA/dsh-termux-runtime.tar.gz"
  printf 'installer-A\n' > "$TI/stageA/install.sh"
  printf 'runtime-B-different\n' > "$TI/stageB/dsh-termux-runtime.tar.gz"
  printf 'installer-B-different\n' > "$TI/stageB/install.sh"

  seed_probe 'recs="$(seed_install_cas "$TI/stageA" dsh-termux-runtime.tar.gz install.sh)" &&
              seed_write_env alpha dsh-0.0.1-x-0.0.1 0.0.1-x $recs' >/dev/null 2>&1
  rc=$?; check "alpha 入库并写事实源 -> 0" 0 "$rc"
  seed_probe 'seed_verify alpha' >/dev/null 2>&1
  rc=$?; check "alpha 校验通过 -> 0" 0 "$rc"

  seed_probe 'recs="$(seed_install_cas "$TI/stageB" dsh-termux-runtime.tar.gz install.sh)" &&
              seed_write_env beta dsh-0.0.2-x-0.0.2 0.0.2-x $recs' >/dev/null 2>&1
  rc=$?; check "beta（内容不同、资产同名）入库并写事实源 -> 0" 0 "$rc"
  seed_probe 'seed_verify beta' >/dev/null 2>&1
  rc=$?; check "beta 校验通过 -> 0" 0 "$rc"
  seed_probe 'seed_verify alpha' >/dev/null 2>&1
  rc=$?; check "**alpha 仍完好**（旧布局在这里会因被覆盖而变红）-> 0" 0 "$rc"
  n_obj="$(ls -1d "$CAS"/*/ 2>/dev/null | wc -l | tr -d ' ')"
  check "两份不同内容 × 两件资产 = 4 个独立对象（反证：确非同一份字节）" 4 "$n_obj"

  # 中途失败的 pin（勿回退 #24 的第二条）：`seed_fetch_assets` 是**逐资产** mv 的，
  # 所以第二个资产下载失败时 staging 里只剩第一件。这里如实模拟那个形态：staging
  # 缺件 -> seed_install_cas 必须**响亮失败**，`.env` 不会被写，已有种子毫发无损。
  mkdir -p "$TI/stageC"
  printf 'runtime-C-partial\n' > "$TI/stageC/dsh-termux-runtime.tar.gz"   # 只有第一件
  seed_probe 'seed_install_cas "$TI/stageC" dsh-termux-runtime.tar.gz install.sh' >/dev/null 2>&1
  rc=$?; check "staging 缺件 -> 入库失败（不发布半份种子）-> 1" 1 "$rc"
  seed_probe 'seed_verify alpha' >/dev/null 2>&1
  rc=$?; check "**中断的 pin 之后 alpha 仍完好** -> 0" 0 "$rc"
  seed_probe 'seed_verify beta' >/dev/null 2>&1
  rc=$?; check "**中断的 pin 之后 beta 仍完好** -> 0" 0 "$rc"
  [ -f "$TI/seeds/stable.env" ] \
    && check "中断的 pin 不该凭空造出事实源" 0 1 \
    || check "中断的 pin 不该凭空造出事实源" 0 0

  # 内容与目录名不符 = 拒绝（路径即身份，静默接受等于让身份失效）。
  # 注意摘要必须是**形状合法**的 64 位小写十六进制：否则会在更早的形状校验那一步
  # 就被判成事实源损坏(2)，测不到"内容不符"这条分支（这里用一个合法但假的摘要）。
  local fake_sum="0000000000000000000000000000000000000000000000000000000000000000"
  mkdir -p "$CAS/$fake_sum"
  printf 'not-the-hash\n' > "$CAS/$fake_sum/x.bin"
  # 记录用**制表符**分隔（seed_records 的输出形状）；用冒号会被形状校验先拦下(2)，
  # 那就测不到"内容不符"这条分支了。
  seed_probe "seed_resolve_record \"x.bin"$'\t'"$fake_sum\"" >/dev/null 2>&1
  rc=$?; check "CAS 对象内容与目录名不符 -> 1（FAIL，不静默接受）" 1 "$rc"

  # 过渡期：旧扁平位置且与 pin 相符仍可读；migrate 把它**移**（不是复制）进 CAS。
  rm -rf "$TI/seeds"; mkdir -p "$TI/seeds/seed-assets"
  printf 'legacy-bytes\n' > "$TI/seeds/seed-assets/legacy.tar.gz"
  lsum="$(sha256sum "$TI/seeds/seed-assets/legacy.tar.gz" | cut -d' ' -f1)"
  {
    echo "SEED_NAME=legacy"
    echo "SEED_TAG=dsh-0.0.3-x-0.0.3"
    echo "SEED_DSH_VERSION=0.0.3-x"
    echo "SEED_ASSET_1=legacy.tar.gz:$lsum"
  } > "$TI/seeds/legacy.env"
  seed_probe 'seed_verify legacy' >/dev/null 2>&1
  rc=$?; check "旧扁平位置且哈希相符 -> 0（过渡期容忍）" 0 "$rc"
  seed_probe 'seed_migrate_legacy' >/dev/null 2>&1
  rc=$?; check "seed migrate 归位 -> 0" 0 "$rc"
  [ -f "$TI/seeds/seed-assets/$lsum/legacy.tar.gz" ] \
    && check "归位后对象落在 <sha256>/ 下" 0 0 \
    || check "归位后对象落在 <sha256>/ 下" 0 1
  [ ! -f "$TI/seeds/seed-assets/legacy.tar.gz" ] \
    && check "旧扁平文件已移走（不是复制）" 0 0 \
    || check "旧扁平文件已移走（不是复制）" 0 1
  seed_probe 'seed_verify legacy' >/dev/null 2>&1
  rc=$?; check "归位后仍校验通过 -> 0" 0 "$rc"

  # **数据损失回归**（本次修复时发现，双评审都没抓到）：CAS 目标**已存在**但内容与
  # 目录名不符（截断/坏盘/手工改动）时，唯一还与 pin 相符的字节就是那份旧扁平文件。
  # 过去的 `if [ -f "$dst" ]; then rm -f "$src"` 会把它删掉、还打印"归位"记成功——
  # 静默把状态从"可修复(FAIL=1)"退化成"缺件、无从恢复(UNMET=3)"。
  # 断言两件事：旧副本**必须还在**，且 migrate **不得**把它算成归位成功。
  rm -rf "$TI/seeds"; mkdir -p "$TI/seeds/seed-assets"
  printf 'pinned-good-bytes\n' > "$TI/seeds/seed-assets/keep.tar.gz"
  ksum="$(sha256sum "$TI/seeds/seed-assets/keep.tar.gz" | cut -d' ' -f1)"
  mkdir -p "$TI/seeds/seed-assets/$ksum"
  printf 'CORRUPT-DIFFERENT\n' > "$TI/seeds/seed-assets/$ksum/keep.tar.gz"   # 占着目标路径的坏对象
  {
    echo "SEED_NAME=keep"
    echo "SEED_TAG=dsh-0.0.4-x-0.0.4"
    echo "SEED_DSH_VERSION=0.0.4-x"
    echo "SEED_ASSET_1=keep.tar.gz:$ksum"
  } > "$TI/seeds/keep.env"
  seed_probe 'seed_migrate_legacy' >/dev/null 2>&1
  rc=$?; check "坏 CAS 对象占位时 migrate 仍正常返回 -> 0" 0 "$rc"
  [ -f "$TI/seeds/seed-assets/keep.tar.gz" ] \
    && check "**坏 CAS 对象占位时 migrate 不得删除与 pin 相符的旧副本**" 0 0 \
    || check "**坏 CAS 对象占位时 migrate 不得删除与 pin 相符的旧副本**" 0 1
  seed_probe 'seed_verify keep' >/dev/null 2>&1
  rc=$?; check "该状态是 FAIL(1) 可修复，不是 UNMET(3) 无从恢复" 1 "$rc"
  rm -f "$TI/seeds/seed-assets/$ksum/keep.tar.gz"
  seed_probe 'seed_verify keep' >/dev/null 2>&1
  rc=$?; check "移走坏对象后旧副本令状态恢复 -> 0" 0 "$rc"

  # 事实源**一条资产记录都没有** = 事实源损坏(ERROR)：判据必须在三处一致
  # （评审 NEW-1 实测过 `seed list` 报"资产齐、哈希相符"、而消费它的 case 判 ERROR）。
  {
    echo "SEED_NAME=empty"
    echo "SEED_TAG=dsh-0.0.5-x-0.0.5"
    echo "SEED_DSH_VERSION=0.0.5-x"
  } > "$TI/seeds/empty.env"
  seed_probe 'seed_present empty' >/dev/null 2>&1
  rc=$?; check "零条资产记录 -> seed_present 判 ERROR(2)" 2 "$rc"
  seed_probe 'seed_verify empty' >/dev/null 2>&1
  rc=$?; check "零条资产记录 -> seed_verify 判 ERROR(2)" 2 "$rc"
  seed_probe 'seed_load empty' >/dev/null 2>&1
  rc=$?; check "零条资产记录 -> seed_load 判 ERROR(2)（三处一致）" 2 "$rc"
  rm -f "$TI/seeds/empty.env"

  # 缺 SEED_DSH_VERSION 同样是**事实源损坏**：它和 SEED_TAG 一样是必需字段
  # （seed_load 一直这么判），但 present/verify 曾漏判成 0，于是 `seed list` 会把
  # 一颗 load 必判 ERROR 的种子报成"资产齐、哈希相符"（评审 claim 5 实测）。
  # 这里资产**真实存在**，排除"缺件"这条混淆路径。
  rm -rf "$TI/seeds"; mkdir -p "$TI/seeds/seed-assets"
  printf 'ver-bytes\n' > "$TI/seeds/seed-assets/ver.tar.gz"
  vsum2="$(sha256sum "$TI/seeds/seed-assets/ver.tar.gz" | cut -d' ' -f1)"
  mkdir -p "$TI/seeds/seed-assets/$vsum2"
  mv "$TI/seeds/seed-assets/ver.tar.gz" "$TI/seeds/seed-assets/$vsum2/ver.tar.gz"
  {
    echo "SEED_NAME=noversion"
    echo "SEED_TAG=dsh-0.0.6-x-0.0.6"
    echo "SEED_ASSET_1=ver.tar.gz:$vsum2"
  } > "$TI/seeds/noversion.env"
  seed_probe 'seed_present noversion' >/dev/null 2>&1
  rc=$?; check "缺 SEED_DSH_VERSION -> seed_present 判 ERROR(2)" 2 "$rc"
  seed_probe 'seed_verify noversion' >/dev/null 2>&1
  rc=$?; check "缺 SEED_DSH_VERSION -> seed_verify 判 ERROR(2)" 2 "$rc"
  seed_probe 'seed_load noversion' >/dev/null 2>&1
  rc=$?; check "缺 SEED_DSH_VERSION -> seed_load 判 ERROR(2)（三处一致）" 2 "$rc"
  rm -f "$TI/seeds/noversion.env"

  # 被杀死的 pin 会留下 `.staging.<pid>` 半成品（实测：可能 110MB）。判定依据是
  # "那个 PID 还在不在"——所以**真起一个子进程、等它退出**，拿它已经死掉的 PID 做
  # 夹具（别写死 999999：长开机的机器上那个 PID 可能存在，断言会无故变红）。
  local dead_pid
  ( exit 0 ) & dead_pid=$!
  wait "$dead_pid" 2>/dev/null
  mkdir -p "$CAS/.staging.$dead_pid"
  printf 'half-downloaded\n' > "$CAS/.staging.$dead_pid/dsh-termux-runtime.tar.gz"
  mkdir -p "$CAS/.staging.$$"        # 本进程自己的 PID：活着，**不许**被删
  printf 'in-flight\n' > "$CAS/.staging.$$/x"
  seed_probe 'seed_prune_stale_staging' >/dev/null 2>&1
  rc=$?; check "清扫遗留 staging -> 0" 0 "$rc"
  [ ! -d "$CAS/.staging.$dead_pid" ] \
    && check "死进程的 staging 被清掉" 0 0 \
    || check "死进程的 staging 被清掉" 0 1
  [ -d "$CAS/.staging.$$" ] \
    && check "活进程（本 shell）的 staging **不**被误删" 0 0 \
    || check "活进程（本 shell）的 staging **不**被误删" 0 1
  rm -rf "$CAS/.staging.$$"

  # 信号 trap 必须**清理并终止**。这一条曾经写成"另建一个合成脚本"——那样把
  # `exit 143` 从产品里删掉、测试照样绿（顾问审计 F2 指出：那是复述 bash 语义，
  # 不是测产品）。现在改成驱动**真实发布路径** `seed_publish`，只把下载函数换成
  # 一个会卡住的 stub，于是断言真的能因为产品代码改动而失败。
  local tstage_dir="$SCRATCH/pub-stage"
  rm -rf "$tstage_dir"
  cat > "$SCRATCH/pub-run.sh" <<EOF
#!/usr/bin/env bash
set -uo pipefail
export DSH_TI_DIR="$TI"
. "$TI/lib/state.sh"
. "$TI/lib/seed.sh"
# 只替换"下载"这一步：其余（占用名检查 → staging → trap → CAS → 写 .env）走真货。
# 卡住的时长就是信号被**推迟**的时长：bash 要等前台子进程结束才处理 trap，
# 所以 wait 的返回时刻 ≈ 这个 sleep。取 5 秒而不是 30：被测性质（"终止被推迟、
# 但最终必定终止并清理"）与时长无关，而 30 秒会把整个冒烟套件推到 ~42 秒，
# 逼近 verify.yml / AGENTS §4 给 static 定的 1 分钟预算（评审 D3 实测 29 秒）。
seed_fetch_assets() { echo started; sleep 5; }
seed_publish sigterm-test dsh-0.0.9-x-0.0.9 1
echo CONTINUED-AFTER-SIGNAL
EOF
  bash "$SCRATCH/pub-run.sh" > "$SCRATCH/pub.out" 2>&1 &
  local tpid=$!
  sleep 1
  kill -TERM "$tpid" 2>/dev/null
  wait "$tpid"; rc=$?
  check "真实 seed_publish 被 TERM 时以 143 退出（trap 未吞掉终止）" 143 "$rc"
  if grep -q "CONTINUED-AFTER-SIGNAL" "$SCRATCH/pub.out"; then
    check "trap 之后**不得**继续执行发布流程" 0 1
  else
    check "trap 之后**不得**继续执行发布流程" 0 0
  fi
  # 被 TERM 时它自己的 staging 必须被收掉（否则一次中断白占最多 110MB）
  local leaked
  leaked="$(find "$TI/seeds/seed-assets" -maxdepth 1 -name '.staging.*' 2>/dev/null | wc -l | tr -d ' ')"
  check "被 TERM 时 seed_publish 的 staging 被清掉" 0 "$leaked"
  # 而且**没有**写出事实源（失败/中断绝不许留下半条 pin）
  [ -f "$TI/seeds/sigterm-test.env" ] \
    && check "被 TERM 不许留下半条 pin" 0 1 \
    || check "被 TERM 不许留下半条 pin" 0 0
  rm -f "$SCRATCH/pub-run.sh" "$SCRATCH/pub.out"
  rm -rf "$tstage_dir"

  rm -f "$TI/seeds/legacy.env"
  rm -rf "$TI/stageA" "$TI/stageB" "$TI/stageC"
  unset -f seed_probe
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
