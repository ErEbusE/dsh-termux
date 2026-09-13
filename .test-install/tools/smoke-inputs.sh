#!/data/data/com.termux/files/usr/bin/bash
# smoke-inputs.sh — 具名输入（default-target）的解析、冻结与失败分类。
#
# 为什么单独一个冒烟: 这件事的核心承诺是**"同一轮里目标只解析一次、解析结果
# 就是被测对象的一部分"**。这条承诺既不该靠真去 npm 联网来验（慢且不确定），
# 也不该只靠读代码相信——所以这里起一个**本机假 registry**，把
# packument 的正常路径与三种负例（缺 integrity、非法 selector、不选就不解析）
# 全部摊开。真机的联网路径由第一个真 case 覆盖。
#
# 覆盖:
#   * dist-tag 解析 -> 冻结文件 + build receipt 字段 + case 环境变量
#   * 未选中任何需要该输入的 case 时**根本不联网**（指向死端口也必须照跑）
#   * packument 缺 dist.integrity -> 依赖该输入的 case 记 UNMET，独立 case 照跑
#   * 非法 selector（范围表达式）-> 明确拒绝，不静默降级
#
# 用法: bash .test-install/tools/smoke-inputs.sh

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SMOKE="$REPO/.test-install/state/smoke/inputs"
TI="$SMOKE/.test-install"
SCRATCH="$SMOKE/scratch"
GIT="git -c user.email=smoke@local -c user.name=smoke -C $SMOKE"
FAILED=0
REG_PID=""

ok()  { echo "  ok: $*"; }
bad() { echo "  FAIL: $*" >&2; FAILED=$((FAILED + 1)); }
check() { if [ "$2" = "$3" ]; then ok "$1 ($3)"; else bad "$1: 期望 $2, 实得 $3"; fi }
pyget() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"; }

free_port() {
  python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'
}

# 假 registry: 路由表由 JSON 给出，因此可以精确模拟"缺 integrity"这类畸形响应。
start_registry() { # $1=路由表 JSON $2=端口
  cat > "$SCRATCH/registry-server.py" <<'PY'
import http.server, json, sys
routes = json.load(open(sys.argv[1]))
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path not in routes:
            self.send_response(404); self.end_headers(); self.wfile.write(b"not found"); return
        data = json.dumps(routes[self.path]).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers(); self.wfile.write(data)
    def log_message(self, *a):
        pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[2])), H).serve_forever()
PY
  python3 "$SCRATCH/registry-server.py" "$1" "$2" &
  REG_PID=$!
  local tries=0
  while [ "$tries" -lt 10 ]; do
    curl -sS -o /dev/null "http://127.0.0.1:$2/@deepseek-ai/dsh" 2>/dev/null && return 0
    sleep 0.3
    tries=$((tries + 1))
  done
  return 1
}
stop_registry() { [ -n "$REG_PID" ] && kill "$REG_PID" 2>/dev/null; REG_PID=""; }

setup() {
  rm -rf "$SMOKE"
  mkdir -p "$TI/lib" "$TI/cases" "$SCRATCH"
  cp "$REPO/.test-install/run.sh" "$TI/run.sh"
  cp "$REPO/.test-install/lib/"*.sh "$TI/lib/"

  cat > "$TI/cases/registry.tsv" <<'EOF'
# 具名输入冒烟用假清单
dry-run/probe-plain|dry-run|needs no named input|cases/probe-plain.sh|-|-|.test-install/**|behavior|-|check,full
dry-run/probe-npm|dry-run|consumes the frozen npm default-target|cases/probe-npm.sh|npm-spec|-|.test-install/**|behavior|-|check,full
EOF

  cat > "$TI/cases/probe-plain.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
. "$DSH_TI_DIR/lib/state.sh"
case_begin
[ -z "${DSH_NPM_TARGET_FILE:-}" ] && assert_pass "未选 npm case 时没有冻结文件" \
  || assert_fail "不该有冻结文件却有: $DSH_NPM_TARGET_FILE"
case_finish
EOF

  cat > "$TI/cases/probe-npm.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
. "$DSH_TI_DIR/lib/state.sh"
case_begin
[ -n "${DSH_NPM_TARGET_FILE:-}" ] && [ -f "$DSH_NPM_TARGET_FILE" ] \
  && assert_pass "拿到冻结文件" || assert_fail "没有冻结文件"
[ -n "${DSH_NPM_VERSION:-}" ] && assert_pass "拿到精确版本 $DSH_NPM_VERSION" \
  || assert_fail "没有精确版本"
case "$DSH_NPM_SPEC" in *"@${DSH_NPM_VERSION}") assert_pass "spec 是精确版本而非 dist-tag";;
                              *) assert_fail "spec 不是精确版本: $DSH_NPM_SPEC";; esac
[ -n "${DSH_NPM_INTEGRITY:-}" ] && assert_pass "拿到 SRI" || assert_fail "没有 SRI"
case_finish
EOF

  printf '.test-install/state/\n.test-install/sandbox-*/\n.test-install/.sandbox-*.lock\nscratch/\n' \
    > "$SMOKE/.gitignore"
  printf 'x\n' > "$SMOKE/NOTES.md"
  $GIT init -q
  $GIT add -A
  $GIT commit -q -m "inputs smoke init"
}

routes_ok() { # $1=输出文件: 正常 packument（latest -> 0.1.5-alpha.2）
  cat > "$1" <<'JSON'
{
  "/@deepseek-ai/dsh": {
    "name": "@deepseek-ai/dsh",
    "dist-tags": {"latest": "0.1.5-alpha.2", "alpha": "0.1.6-alpha.1"},
    "versions": {
      "0.1.5-alpha.2": {
        "name": "@deepseek-ai/dsh", "version": "0.1.5-alpha.2",
        "dist": {"integrity": "sha512-AAAA", "shasum": "bbbb",
                 "tarball": "https://registry.npmjs.org/@deepseek-ai/dsh/-/dsh-0.1.5-alpha.2.tgz"}
      }
    }
  }
}
JSON
}

routes_no_integrity() {
  cat > "$1" <<'JSON'
{
  "/@deepseek-ai/dsh": {
    "name": "@deepseek-ai/dsh",
    "dist-tags": {"latest": "0.1.5-alpha.2"},
    "versions": {
      "0.1.5-alpha.2": {
        "name": "@deepseek-ai/dsh", "version": "0.1.5-alpha.2",
        "dist": {"tarball": "https://registry.npmjs.org/x.tgz"}
      }
    }
  }
}
JSON
}

run_sh() { # 用假 registry 起运行器
  DSH_LIVE_HOME="$SMOKE/fake-live-home" DSH_NPM_REGISTRY="http://127.0.0.1:$1/" \
    bash "$TI/run.sh" "${@:2}"
}

# --- 场景 1: 正常解析 + 冻结 + receipt 字段 --------------------------------
scenario_resolve() {
  echo "== 场景 1: dist-tag 解析并冻结"
  local port rc
  port="$(free_port)"
  routes_ok "$SCRATCH/routes-ok.json"
  start_registry "$SCRATCH/routes-ok.json" "$port" || { bad "假 registry 起不来"; return; }
  run_sh "$port" check -c dry-run/probe-npm --json > "$SCRATCH/out1.json" 2>"$SCRATCH/err1.txt"; rc=$?
  stop_registry
  check "选了 npm case -> exit" 0 "$rc"
  check "聚合" PASS "$(pyget "$SCRATCH/out1.json" 'd["aggregate"]')"
  local receipt
  receipt="$(ls "$SMOKE"/.test-install/state/*/build-receipt.tsv | tail -1)"
  grep -q "^npm_version	0.1.5-alpha.2$" "$receipt" && ok "receipt 记了精确版本" \
    || bad "receipt 没有 npm_version"
  grep -q "^npm_integrity	sha512-AAAA$" "$receipt" && ok "receipt 记了 SRI" || bad "receipt 没有 npm_integrity"
  grep -q "^npm_selector_kind	dist-tag$" "$receipt" && ok "receipt 记了选择依据" || bad "receipt 缺选择依据"
  grep -q "^npm_target_digest	" "$receipt" && ok "receipt 记了冻结文件摘要" || bad "receipt 缺冻结摘要"
  local frozen
  frozen="$(ls "$SMOKE"/.test-install/state/*/input-npm-target.tsv | tail -1)"
  grep -q "^role	default-target$" "$frozen" && ok "冻结文件带角色名" || bad "冻结文件缺角色名"
  [ -z "$(ls "$SMOKE"/.test-install/state/*/input-npm-target.tsv.tmp 2>/dev/null)" ] \
    && ok "冻结是原子的（无 .tmp 残留）" || bad "有 .tmp 残留"
}

# --- 场景 2: 不需要该输入时根本不联网 ---------------------------------------
scenario_no_resolve() {
  echo "== 场景 2: 未选 npm case 时不解析"
  # 指向一个**死端口**: 只要它尝试解析就必然失败，case 就会 UNMET。
  local dead rc
  dead="$(free_port)"
  run_sh "$dead" check -c dry-run/probe-plain >/dev/null 2>&1; rc=$?
  check "不需要该输入 -> exit" 0 "$rc"
}

# --- 场景 3: 缺 integrity -> UNMET，独立 case 照跑 ---------------------------
scenario_no_integrity() {
  echo "== 场景 3: packument 缺 integrity"
  local port rc
  port="$(free_port)"
  routes_no_integrity "$SCRATCH/routes-bad.json"
  start_registry "$SCRATCH/routes-bad.json" "$port" || { bad "假 registry 起不来"; return; }
  run_sh "$port" check -c dry-run/probe-npm -c dry-run/probe-plain --json \
    > "$SCRATCH/out3.json" 2>"$SCRATCH/err3.txt"; rc=$?
  stop_registry
  check "缺 integrity -> exit" 3 "$rc"
  check "聚合" UNMET "$(pyget "$SCRATCH/out3.json" 'd["aggregate"]')"
  check "交付结论（缺结论不授资格）" INCOMPLETE "$(pyget "$SCRATCH/out3.json" 'd["verdict"]')"
  check "独立 case 照跑并通过" PASS \
    "$(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print([c["status"] for c in d["cases"] if c["id"]=="dry-run/probe-plain"][0])' "$SCRATCH/out3.json")"
  grep -q "dist.integrity" "$SCRATCH/err3.txt" && ok "失败原因点明缺 integrity" || bad "原因不可读"
}

# --- 场景 4: 非法 selector 明确拒绝 -----------------------------------------
scenario_bad_selector() {
  echo "== 场景 4: 非法 selector（范围表达式）"
  local dead rc
  dead="$(free_port)"
  DSH_LIVE_HOME="$SMOKE/fake-live-home" DSH_NPM_REGISTRY="http://127.0.0.1:$dead/" \
    DSH_NPM_SPEC='@deepseek-ai/dsh@^1.0.0' bash "$TI/run.sh" check -c dry-run/probe-npm \
    >/dev/null 2>"$SCRATCH/err4.txt"; rc=$?
  check "范围 selector -> exit" 3 "$rc"
  grep -q "不支持的 selector" "$SCRATCH/err4.txt" && ok "拒绝理由可读" || bad "拒绝理由不可读"
}

setup
routes_ok "$SCRATCH/routes-ok.json"
scenario_resolve
scenario_no_resolve
scenario_no_integrity
scenario_bad_selector
stop_registry

echo
if [ "$FAILED" -eq 0 ]; then
  echo "INPUTS SMOKE: ALL OK"
else
  echo "INPUTS SMOKE: $FAILED 项失败" >&2
  exit 1
fi
