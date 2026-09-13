#!/data/data/com.termux/files/usr/bin/bash
# serve.sh — 人类实测入口：**只启动冻结对象**。
#
# 这一版与旧 serve.sh 的根本区别（实查更正 C3 + 评审裁决，见 DECISIONS.md ADR-010）：
#
#   旧: 跑门槛认证一个产物，然后**无条件**把工作区补丁 overlay 上去再起服务。
#       于是人在浏览器里实测的对象已经不是被认证/被断言的那一个，而交付说明
#       仍按被认证的那个写。
#   新: serve **不生成、不修补、不覆盖任何东西**。它只找"某条 case 已经装出来
#       并被断言过、且写下了身份记录"的那棵树，复核它的载荷字节，然后启动它。
#       要测新东西，就重跑一次 `run.sh verify` 让门槛重新产出对象。
#
# 身份与签认（为什么不能只打印一行版本号了事）：
#   * 对象记录（manifest）把 build digest、载荷内容摘要、run/case、人工清单绑成
#     一卷，内容寻址；serve 打印的**对象 id** 就是它的摘要；
#   * 人在会话里确认后，用 `run.sh finalize <轮次id> --observed <对象id>` 终结这一轮；
#   * 只写清单名（`serve-patch`）的签认**一律不接受**——它指不回任何对象。
#
# 启动前与退出后各做一次载荷校验：只有"开始时是对的"证明不了实测过程中对象没被
# 换掉。任何一次不过，这段观察就不成立（观察台账里留痕，finalize 会拒绝它）。
#
# 用法唯一事实源是本文件的 usage_text（`bash .test-install/serve.sh -h`）。
set -uo pipefail

TI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$TI_DIR/.." && pwd)"
export DSH_HARNESS_ROOT="$ROOT" DSH_TI_DIR="$TI_DIR"
# 线上 HOME 必须在**任何覆盖之前**捕获：lib/sandbox.sh 靠它定义"线上 runtime"
# 是哪一份。一旦先改了 HOME 再回落，守卫/泄漏检查就变成自我比对（永远为真）。
export DSH_LIVE_HOME="${DSH_LIVE_HOME:-$HOME}"

# shellcheck source=lib/registry.sh
. "$TI_DIR/lib/registry.sh"
# shellcheck source=lib/receipt.sh
. "$TI_DIR/lib/receipt.sh"
# shellcheck source=lib/frozen.sh
. "$TI_DIR/lib/frozen.sh"
# shellcheck source=lib/sandbox.sh
. "$TI_DIR/lib/sandbox.sh"
# 启动器与 opener 的生成器只有这一份实现（scripts/common.sh）；serve 绝不自己抄一段。
# shellcheck source=../scripts/common.sh
. "$ROOT/scripts/common.sh"

usage_text() {
  cat <<'EOF'
serve.sh — 人类实测入口。只启动**冻结对象**：某条 case 装出来、被断言过、
并且写下了身份记录的那棵树。serve 自己不装、不修、不覆盖任何东西。

用法（仓库根目录下）:
  bash .test-install/serve.sh --list
      列出盘上所有冻结对象与它们的状态（载荷/源是否漂移），以及已开出的轮次
  bash .test-install/serve.sh --round <轮次id> [--object <case-id>]
      启动某个轮次里的冻结对象。轮次由 `run.sh verify` 开出（它的报告末尾会打印
      轮次 id）。一个轮次里可能有多棵树（同一人工清单对应多条 case）——那就必须
      用 --object 指明要起哪一个：**逐对象实测与签认**，一棵树上点过的通过不能
      自动覆盖另一棵。
  bash .test-install/serve.sh --sandbox <沙箱名> [--allow-drift]
      直起一个已有的冻结对象（`--list` 里有它的名字）。不属于任何轮次，因此只能
      用来诊断/复看：它产生的观察**不能**用来终结轮次。

选项:
  --port <n>     端口（默认 3141，避开本地正在运行的 dsh web 的 3080）
  --no-open      不自动开浏览器（agent 冒烟用）
  --with-creds   把本地 ~/.dsh 的 .credentials.yaml + settings.yaml 复制进沙箱
                 （值不打印）。**环境变量型**凭据不需要这个开关——serve 用的是
                 你 shell 的父环境，export 过的 provider key 会原样继承，
                 与真实安装一致（这一点与 case 的白名单环境刻意不同）。
  --allow-drift  工作区内容已变（源漂移）时仍然启动。启动后这次观察仍归属于
                 **冻结记录里的旧主体**，不提供"当前工作区"的资格；载荷漂移
                 （对象本身被改过）永远硬拒绝，这个开关绕不过去
  --check-only   只做解析与校验并打印结论，不启动服务、不写观察记录（冒烟用）

诊断开关（**默认关闭**；打开后产生的结论不能替代默认环境下的人工项签认）:
  --probe-handoff       在 $BROWSER 前面插一层只做记录的 shim，用来把"dsh 到底有没有
                        调 opener、返回什么"变成可见证据。默认**不插**：走生成器写出的
                        原生接线（如果产品接线本身是错的，插桩会把它遮住）。
                        注意它记录的是"被调用/该进程返回"，**不是**"浏览器真的打开了"。
  --strip-android-root  丢掉 Android 14+ 注入的 ANDROID_{ART,I18N,TZDATA}_ROOT 三个变量。
                        实测（agent 环境）它们会让 `am` 打不开 /dev/binder，而人类自己的
                        环境带着它们照样能弹——所以默认**保留**，剥离只在定位问题时用。

例:
  bash .test-install/run.sh verify           # 开一个轮次（报告末尾给出轮次 id）
  bash .test-install/serve.sh --list
  bash .test-install/serve.sh --round 20260913T101112-3456 --with-creds
  bash .test-install/run.sh finalize 20260913T101112-3456 --observed <对象id>

退出码: 0 正常起过/检查通过；1 对象漂移或校验不通过（拒绝启动）；2 用法/框架错误。
EOF
}

# ---- 旧开关守卫（必须在**我们自己的变量赋值之前**跑）------------------------
# 注意：本脚本**内部**的选项变量叫 OPT_*，但守卫检查的是**环境变量**——两者不能串味，
# 所以这一步也刻意放在自己那批赋值之前。
# 旧版 serve.sh 的开关是**环境变量**，新版全是 `--flag`。静默忽略一个用户明确写下的
# 开关，比报错糟糕得多：人以为自己开了凭据、实际什么都没发生（本轮实测踩到：
# `OPT_WITH_CREDS=1 ... --sandbox <n>` 一路跑完，沙箱里没有任何凭据）。所以这里
# **响亮拒绝**，并给出等价写法；没有等价写法（TAG/DSH_TARGET/REUSE）的就说清
# 为什么——那三种模式的语义已经被"冻结对象"取代，不是被改了个名字。
legacy_guard() {
  local bad=0 v
  for v in WITH_CREDS REUSE NO_OPEN DSH_TARGET TAG SANDBOX; do
    [ -n "${!v:-}" ] || continue
    bad=1
    case "$v" in
      WITH_CREDS) echo "!! 检测到旧开关 $v=${!v} —— 新版是命令行开关: --with-creds" >&2 ;;
      NO_OPEN)    echo "!! 检测到旧开关 $v=${!v} —— 新版是命令行开关: --no-open" >&2 ;;
      SANDBOX)    echo "!! 检测到旧开关 $v=${!v} —— 新版是命令行开关: --sandbox ${!v}" >&2 ;;
      REUSE)      echo "!! 检测到旧开关 $v=${!v} —— 新版没有等价开关: serve 只启动已有的冻结对象，" >&2
                  echo "   \"复用\"就是它的默认行为；要重新产出对象就重跑 run.sh verify。" >&2 ;;
      TAG|DSH_TARGET)
                  echo "!! 检测到旧开关 $v=${!v} —— 新版没有等价开关: 旧模式\"先认证发布物再无条件" >&2
                  echo "   overlay 工作区补丁\"已被取消（那正是实查更正 C3）。现在先 run.sh verify" >&2
                  echo "   产出冻结对象，再 serve --round <轮次id>。" >&2 ;;
    esac
  done
  [ "$bad" = 0 ] || { echo "   （旧写法被静默忽略过，所以这里改成硬拒绝）" >&2; exit 2; }
}
legacy_guard

# ---- 参数 ------------------------------------------------------------------
PORT="${PORT:-3141}"
OPT_LIST=0; OPT_ROUND=""; OPT_SANDBOX=""; OPT_OBJECT=""
OPT_ALLOW_DRIFT=0; OPT_CHECK_ONLY=0; OPT_NO_OPEN=0; OPT_WITH_CREDS=0
OPT_PROBE_HANDOFF=0; OPT_STRIP_ANDROID_ROOT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --list)        OPT_LIST=1; shift ;;
    --round)       OPT_ROUND="${2:?--round 需要轮次 id}"; shift 2 ;;
    --round=*)     OPT_ROUND="${1#--round=}"; shift ;;
    --object)      OPT_OBJECT="${2:?--object 需要 case id}"; shift 2 ;;
    --object=*)    OPT_OBJECT="${1#--object=}"; shift ;;
    --sandbox)     OPT_SANDBOX="${2:?--sandbox 需要沙箱名}"; shift 2 ;;
    --sandbox=*)   OPT_SANDBOX="${1#--sandbox=}"; shift ;;
    --port)        PORT="${2:?--port 需要端口号}"; shift 2 ;;
    --port=*)      PORT="${1#--port=}"; shift ;;
    --allow-drift) OPT_ALLOW_DRIFT=1; shift ;;
    # 下面两个是**诊断**开关。它们会改变"人实测时的启动条件"，因此默认关闭，
    # 且打开后产生的结论**不能**替代默认（原生）环境下的人工项签认。
    --probe-handoff)      OPT_PROBE_HANDOFF=1; shift ;;
    --strip-android-root) OPT_STRIP_ANDROID_ROOT=1; shift ;;
    --check-only)  OPT_CHECK_ONLY=1; shift ;;
    --no-open)     OPT_NO_OPEN=1; shift ;;
    --with-creds)  OPT_WITH_CREDS=1; shift ;;
    -h|--help)     usage_text; exit 0 ;;
    # 旧 serve 的坑：`bash serve.sh TAG=xxx` 会被当成端口，白跑一整轮门槛+装机的
    # 时间，最后才由 dsh 抛出 "--port must be a number"。这里对 `VAR=value` 形状
    # 的位置参数直接人话拒绝。
    *=*)           echo "!! '$1' 看起来是变量赋值；本脚本的开关都是 --flag 形式:" >&2
                   echo "     $1 bash .test-install/serve.sh ..." >&2
                   exit 2 ;;
    *)             echo "!! 未知参数: $1" >&2; usage_text >&2; exit 2 ;;
  esac
done
case "$PORT" in ''|*[!0-9]*) echo "!! 端口必须是数字: '$PORT'" >&2; exit 2 ;; esac
if [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
  echo "!! 端口超出范围 (1-65535): $PORT" >&2; exit 2
fi

if [ "$OPT_LIST" = 1 ] && { [ -n "$OPT_ROUND" ] || [ -n "$OPT_SANDBOX" ]; }; then
  echo "!! --list 只列清单，不与 --round/--sandbox 同时用" >&2; exit 2
fi
if [ -n "$OPT_ROUND" ] && [ -n "$OPT_SANDBOX" ]; then
  echo "!! --round 与 --sandbox 互斥（前者是某轮里的对象，后者是自由对象）" >&2; exit 2
fi
if [ -n "$OPT_OBJECT" ] && [ -z "$OPT_ROUND" ]; then
  echo "!! --object 只在 --round 下有意义" >&2; exit 2
fi

round_dir() { printf '%s/state/rounds/%s\n' "$TI_DIR" "$1"; }

# 对象 id = manifest **内容**的 sha256。刻意不靠文件名解析：沙箱里的定位副本叫
# `frozen.tsv`、商店里的叫 `frozen-<id>.tsv`，两条路径都要能算出同一个 id。
obj_id_of() { sha256sum "$1" | cut -d' ' -f1; }

# ---- --list ----------------------------------------------------------------
payload_state() { # $1=沙箱根 $2=manifest -> ok | DRIFT | 缺失
  if frozen_object_ok "$1" "$2" >/dev/null 2>&1; then printf 'ok\n'; else printf 'DRIFT\n'; fi
}
source_state() { # $1=manifest -> ok | drift
  if frozen_source_ok "$1" >/dev/null 2>&1; then printf 'ok\n'; else printf 'drift\n'; fi
}

cmd_list() {
  local sbox mf n=0
  echo "== 冻结对象（可被人类实测的那些） =="
  printf '  %-32s %-26s %-12s %-9s %-7s %s\n' SANDBOX CASE dsh OBJECT PAYLOAD SOURCE
  while IFS=$'\t' read -r sbox mf; do
    n=$((n + 1))
    printf '  %-32s %-26s %-12s %-9s %-7s %s\n' \
      "$sbox" "$(frozen_get "$mf" case_id)" "$(frozen_get "$mf" dsh_version)" \
      "$(obj_id_of "$mf" | cut -c1-8)" \
      "$(payload_state "$TI_DIR/$sbox" "$mf")" "$(source_state "$mf")"
  done < <(frozen_each_sandbox)
  if [ "$n" = 0 ]; then
    echo "  （一个都没有。先跑一次 run.sh verify —— 它会为带人工项的 case 留下冻结对象。）"
  fi
  echo
  echo "== 轮次（run.sh verify 开出的判定回合；人工项只能在**它自己那一轮**里终结） =="
  local rd rid verdict need objs
  n=0
  for rd in "$TI_DIR"/state/rounds/*/; do
    [ -f "$rd/round.tsv" ] || continue
    n=$((n + 1))
    rid="$(basename "$rd")"
    verdict="$(sed -n 's/^verdict\t//p' "$rd/round.tsv" | head -n 1)"
    need="$(sed -n 's/^human_required\t//p' "$rd/round.tsv" | head -n 1)"
    # grep -c 在"零匹配"时打印 0 但退出 1：写成 `$(grep -c ... || echo 0)` 会得到
    # 两行("0\n0")，报告里就多出一行莫名其妙的数字。
    objs=0
    if [ -f "$rd/objects.tsv" ]; then objs="$(grep -c . "$rd/objects.tsv" || true)"; fi
    printf '  %-26s %-12s 人工:%-22s 对象:%s\n' "$rid" "$verdict" "$need" "$objs"
  done
  [ "$n" = 0 ] && echo "  （还没有轮次。）"
  return 0
}

# ---- 解析一个对象 ----------------------------------------------------------
# 从轮次里挑对象；多个对象而没 --object 时**不猜**（逐对象签认的前提）。
pick_from_round() {
  local rd="$1" case_id manifest sbox
  local -a rows=()
  while IFS=$'\t' read -r case_id manifest sbox; do
    [ -n "$case_id" ] || continue
    rows+=("$case_id|$manifest|$sbox")
  done < "$rd/objects.tsv"
  if [ "${#rows[@]}" = 0 ]; then
    echo "!! 轮次 $(basename "$rd") 里没有冻结对象 —— 人工项无法实测。" >&2
    echo "   该轮次开出来时可能没有带人工项的 case，或冻结失败了（看 run.sh 输出）。" >&2
    exit 1
  fi
  if [ -n "$OPT_OBJECT" ]; then
    local r
    for r in "${rows[@]}"; do
      [ "${r%%|*}" = "$OPT_OBJECT" ] && { printf '%s\n' "$r"; return 0; }
    done
    echo "!! 轮次 $(basename "$rd") 里没有 case '$OPT_OBJECT' 的对象。可选:" >&2
    for r in "${rows[@]}"; do echo "     --object ${r%%|*}" >&2; done
    exit 2
  fi
  if [ "${#rows[@]}" -gt 1 ]; then
    echo "!! 这一轮有 ${#rows[@]} 个对象，同一个清单下**逐对象**实测与签认，请指明:" >&2
    for r in "${rows[@]}"; do echo "     --object ${r%%|*}" >&2; done
    exit 2
  fi
  printf '%s\n' "${rows[0]}"
}

# ---- 起一个冻结对象 --------------------------------------------------------
serve_object() { # $1=沙箱根 $2=manifest $3=轮次id(-) $4=case id
  local root="$1" mf="$2" round="$3" case_id="$4"
  local oid; oid="$(obj_id_of "$mf")"
  local cls; cls="$(frozen_get "$mf" case_class)"
  local clist; clist="$(frozen_get "$mf" checklists)"
  local mround; mround="$(frozen_get "$mf" round_id)"

  if [ ! -d "$root" ]; then
    echo "!! 沙箱不存在: $root" >&2
    echo "   对象记录还在（$mf），但那棵树已经不在盘上了 —— 无法实测，也无法复核。" >&2
    exit 1
  fi
  if [ "$round" != "-" ] && [ "$mround" != "$round" ]; then
    echo "!! 对象 $oid 属于轮次 $mround，不是 $round —— 拒绝启动" >&2
    exit 1
  fi
  # 载荷漂移：对象本身被改过。硬拒绝，--allow-drift 也绕不过去。
  if ! frozen_object_ok "$root" "$mf"; then
    echo "!! 冻结载荷与记录不一致 —— 拒绝启动（这棵树不是被断言过的那一棵）" >&2
    exit 1
  fi
  # 源漂移：工作区内容变了。对象本身没坏，但这次观察只归属于旧主体。
  local drifted=0
  if ! frozen_source_ok "$mf" >/dev/null 2>&1; then
    drifted=1
    if [ "$OPT_ALLOW_DRIFT" != 1 ]; then
      echo "!! 工作区内容已经不是冻结这个对象时的那份（源漂移）—— 拒绝启动。" >&2
      frozen_source_ok "$mf" || true
      echo "   要么重跑 run.sh verify 让门槛按当前工作区重新产出对象，" >&2
      echo "   要么确认你就是要复看旧主体: 加 --allow-drift。" >&2
      exit 1
    fi
    echo "!! WARN: --allow-drift —— 这次实测归属于**冻结记录里的旧主体**，" >&2
    echo "        不提供当前工作区的资格（对象 id 与记录都不会改写）。" >&2
  fi

  echo "======================================================================"
  echo " 冻结对象:  $oid"
  echo "   case      $case_id  ($cls)"
  [ "$round" != "-" ] && echo "   轮次      $round"
  echo "   dsh       $(frozen_get "$mf" dsh_version)   node $(frozen_get "$mf" node_version)"
  echo "   载荷根    $(frozen_get "$mf" payload_roots)  （排除: $(frozen_get "$mf" payload_excludes)）"
  echo "   载荷摘要  $(frozen_get "$mf" payload_digest)"
  echo "   被测输入  $(frozen_get "$mf" build_digest)"
  echo "   记录      ${mf#"$ROOT"/}"
  echo "   沙箱      ${root#"$ROOT"/}/   (这棵树就是被断言过的那一棵, serve 不会改它)"
  echo "   工作区    ${root#"$ROOT"/}/ws   (人在会话里让 agent 写的文件落在这里)"
  if [ "$round" != "-" ]; then
    echo "   终结命令  bash .test-install/run.sh finalize $round --observed $oid"
    echo "             （**人工确认清单之后**才执行；serve 不会自己跑它）"
  fi
  [ "$drifted" = 1 ] && echo "   ⚠ 源漂移: 本次观察不提供当前工作区的资格"
  echo "======================================================================"
  local c cp
  for c in $(printf '%s' "$clist" | tr ',' ' '); do
    [ -n "$c" ] || continue
    cp="$(registry_checklist_path "$c")"
    echo
    echo "---- 人工点检清单 [$c]  $(basename "$cp") sha256:$(registry_checklist_digest "$c" | cut -c1-12) ----"
    if [ -f "$cp" ]; then cat "$cp"; else echo "  !! 清单正文缺失: $cp"; exit 2; fi
  done
  echo

  if [ "$OPT_CHECK_ONLY" = 1 ]; then
    echo "（--check-only: 校验通过，未启动服务、未写观察记录。）"
    return 0
  fi

  # 隔离环境（与 case 沙箱同一套白名单内核）
  mkdir -p "$root/tmp" "$root/ws" "$root/home" "$root/bin" || exit 2
  SANDBOX_ROOT="$root"
  SANDBOX_NAME="$(basename "$root")"
  # **serve 的环境政策与 case 刻意不同**：父环境 − 危险项 + 沙箱覆盖。
  # 理由见 lib/sandbox.sh 的 sandbox_env_human 与 DECISIONS ADR-010：
  # 真机实测白名单环境下浏览器不弹（同一台设备换父环境就弹），且 ~/.profile 里的
  # provider key 进不来——人类实测要的是"真实用户的环境"，不是一份没人用的环境。
  if [ "$OPT_STRIP_ANDROID_ROOT" = 1 ]; then
    sandbox_env_human --strip-android-root
  else
    sandbox_env_human
  fi
  [ -n "${SANDBOX_ENV_DROPPED:-}" ] && \
    echo "隔离: 下列父环境变量因值里含线上 runtime 路径被丢弃: $SANDBOX_ENV_DROPPED" >&2
  # 审计留档：**只记变量名**（凭据是被继承进来的，所以"哪些名字进了沙箱"必须看得见；
  # 值一个都不记录，也不记值的摘要）。进 frozen/env/，与守卫快照同级。
  local envdir; envdir="$(frozen_store)/env"
  mkdir -p "$envdir" 2>/dev/null || true
  sandbox_env_names > "$envdir/${oid:0:8}-$$.names.txt" 2>/dev/null || true
  if ! sandbox_env_leak_check; then
    echo "!! 沙箱环境仍泄漏线上路径 —— 拒绝启动（上面的丢弃逻辑没覆盖到）" >&2
    exit 2
  fi
  export SANDBOX_ROOT SANDBOX_NAME
  # 机件（启动器 + opener）由生成器现写，**写在载荷之外**（bin/），并单独记摘要。
  # 它是被测对象的**外壳**，不是候选内容——这样"serve 不改动被测对象"是一条
  # 结构上的性质，而不是靠人记得别写错地方。
  local dsh_bin="$root/prefix/work/node_modules/@deepseek-ai/dsh/lib/bin.js"
  local node_bin="$root/prefix/node/bin/node"
  if [ ! -f "$dsh_bin" ]; then
    echo "!! 沙箱里没有 dsh 入口: $dsh_bin" >&2; exit 1
  fi
  write_dsh_wrapper "$root/bin/dsh" "$node_bin" "$dsh_bin" \
    || { echo "!! 无法生成启动器" >&2; exit 2; }
  local mach; mach="$(frozen_machinery_digest "$root")"

  # 浏览器交接：**默认不插桩**，走生成器写出的原生接线（wrapper 在 $BROWSER 未设时
  # 指向沙箱 opener）。这是评审裁决要的：`$BROWSER` 是启动选择的一部分，插桩可能把
  # 产品原本错误的接线遮住；而启动器不在载荷身份里，manifest 校验证明不了这件事。
  # `--probe-handoff` 只在定位问题时插一层记录用的 shim。
  #
  # 为什么需要它（诊断时）：dsh 用 `stdio:'ignore'` + detached 起 xdg-open，而
  # `open()` 在 spawn 那一刻就 resolve——"没弹出来"与"弹出来了"在终端上一模一样。
  local blog="$root/serve-browser.log"
  rm -f "$blog" "$root/.serve-browser-url"
  if [ "$OPT_PROBE_HANDOFF" = 1 ]; then
    : > "$blog" || { echo "!! 无法创建 $blog" >&2; exit 2; }
    local shim="$root/bin/.serve-browser-shim"
    # 这层 shim **等待** opener 返回再转发退出码与输出——只有等它返回才拿得到结果，
    # 代价是它不再透明（进程语义与原生链路不同）。所以它只作诊断。
    # 路径从环境拿（用**引号 heredoc**，避免宿主 shell 提前展开）；URL 与输出里的
    # `token=` 一律打码：台账是耐久的，一次性令牌不该留在里面。
    SANDBOX_ENV+=("SERVE_BROWSER_LOG=$blog" "SERVE_BROWSER_RAW=$root/.serve-browser-url"
                  "SERVE_OPENER=$root/bin/dsh-termux-open")
    cat > "$shim" <<'SHIM' || { echo "!! 无法写 $shim" >&2; exit 2; }
#!/data/data/com.termux/files/usr/bin/sh
LOG="${SERVE_BROWSER_LOG:?}"
RAW="${SERVE_BROWSER_RAW:?}"
OPENER="${SERVE_OPENER:?}"
mask() { sed 's/token=[^& ]*/token=***/g'; }
printf '%s' "${1:-}" > "$RAW"
printf 'call\t%s\n' "$(printf '%s' "${1:-}" | mask)" >> "$LOG"
out="$("$OPENER" "$@" 2>&1)"; rc=$?
printf 'rc\t%s\n' "$rc" >> "$LOG"
[ -n "$out" ] && printf 'out\t%s\n' "$(printf '%s' "$out" | mask)" >> "$LOG"
exit "$rc"
SHIM
    chmod +x "$shim"
    SANDBOX_ENV+=("BROWSER=$shim")
    echo "诊断: 已插桩握手（--probe-handoff）—— 这次的结论**不能**替代默认环境下的人工项" >&2
  fi
  sandbox_env_leak_check >/dev/null || { echo "!! 环境泄漏（BROWSER 行）" >&2; exit 2; }

  if [ "$OPT_WITH_CREDS" = 1 ]; then
    local live="$DSH_LIVE_HOME/.dsh"
    if [ -f "$live/.credentials.yaml" ] && [ -f "$live/settings.yaml" ]; then
      mkdir -p "$root/home/.dsh"
      cp "$live/.credentials.yaml" "$live/settings.yaml" "$root/home/.dsh/" \
        || { echo "!! 复制凭据失败" >&2; exit 2; }
      echo "--with-creds: 已把本地 ~/.dsh 的凭据/设置复制进沙箱（值未打印）" >&2
    else
      echo "WARN: --with-creds 但 $live 下缺 .credentials.yaml 或 settings.yaml，跳过" >&2
    fi
    # 环境变量型凭据**不再需要点名**：serve 用的是父环境，你 shell 里 export 的
    # provider key（~/.profile 里的那些）会原样继承——与真实安装完全一致。
  fi

  # 观察开始：在人看到任何东西**之前**把"对象此刻是对的"记下来。
  # 记 tty= 是为了**可追溯**：这一行是人坐在终端前起的，还是脚本/agent 起的。
  # 判定"人是不是真测了"仍然是流程信任（agent 有 shell 就能起服务），但"这段
  # 观察从哪来"不该只靠记忆——台账里留下它是免费的。
  local ttyf=no; [ -t 0 ] && ttyf=yes
  # 线上守卫（ADR-008 的"检测"层）：与 case 用同一套快照/比对，缺一不可——
  # "预防"（白名单环境 + DSH_HOME 钉进沙箱 + 线上 wrapper 目录从 PATH 摘掉）挡的是
  # "忘了清某个变量"，挡不住"某个包硬编码了线上路径"。取不到快照就不该起服务：
  # 守卫缺席的结论是不可信的。快照留在 frozen/guard/ 里当证据，不删。
  local gdir; gdir="$(frozen_store)/guard"
  mkdir -p "$gdir" || { echo "!! 无法创建守卫留档目录 $gdir" >&2; exit 2; }
  local gtag; gtag="$(date +%Y%m%dT%H%M%S)"
  local snap="$gdir/guard-${oid:0:8}-$gtag.$$.before.tsv"
  local snap2="$gdir/guard-${oid:0:8}-$gtag.$$.after.tsv"
  if ! sandbox_guard_snapshot "$snap"; then
    echo "!! 取不到本地正在运行的 dsh runtime 的起点快照 —— 拒绝启动（守卫缺席，结论不可信）" >&2
    exit 2
  fi
  # 清单**正文**的摘要进台账：签认要能引用"人到底照着哪份清单做的"，而清单是数据
  # 文件——改一个字就是另一份清单，只记 id 记不住这件事。
  local csha="" c
  for c in $(printf '%s' "$clist" | tr ',' ' '); do
    [ -n "$c" ] || continue
    csha+="${csha:+,}$c=$(registry_checklist_digest "$c" | cut -c1-12)"
  done
  # frozen_observe_append 只接受**一个** note 字段（多传会静默丢掉），所以拼好再交。
  # 环境政策与剥离的变量名必须进台账：自动层与人工层现在是**互补**证据，
  # "这份观察是哪套环境政策下取的"是它的适用范围，不能省。
  local onote s1name
  s1name="$(basename "$snap")"
  onote="checklists=$csha machinery=$mach drifted=$drifted tty=$ttyf"
  onote+=" guard=$s1name env_policy=$SANDBOX_POLICY_HUMAN"
  onote+=" dropped=${SANDBOX_ENV_DROPPED:--} strip_android_root=$OPT_STRIP_ANDROID_ROOT"
  onote+=" probe_handoff=$OPT_PROBE_HANDOFF"
  frozen_observe_append start "$oid" "$round" "$case_id" "$clist" ok "$onote" \
    || { echo "!! 观察台账写不进去 —— 这次实测不会成立，拒绝启动" >&2; exit 2; }

  local OPEN_FLAGS=()
  [ "$OPT_NO_OPEN" = 1 ] && OPEN_FLAGS=(--no-open)
  echo "======================================================================"
  echo " 沙箱 Web 地址:  http://127.0.0.1:$PORT"
  echo " 隔离:  HOME=$SANDBOX_ROOT/home"
  echo "        DSH_HOME=$SANDBOX_ROOT/home/.dsh   (凭据/会话/数据全在沙箱内)"
  echo " 工作区: $SANDBOX_ROOT/ws"
  echo " 实测完成后请 Ctrl-C 退出，然后在会话里逐项回复本清单。"
  echo "======================================================================"
  echo

  local child rc=0
  ( cd "$root/ws" && exec env -i "${SANDBOX_ENV[@]}" "$root/bin/dsh" \
      web --host 127.0.0.1 --port "$PORT" ${OPEN_FLAGS[@]+"${OPEN_FLAGS[@]}"} ) &
  child=$!
  # 只转发终止信号；INT 让子进程自己处理（Ctrl-C 会同时到达整个前台进程组），
  # 这里不能退出——退出就跑不到下面的"实测结束后再校验一次"。
  trap ':' INT
  trap 'kill -TERM "$child" 2>/dev/null || true' TERM
  wait "$child"; rc=$?
  trap - INT TERM

  local end_check=ok
  if ! frozen_object_ok "$root" "$mf"; then
    end_check=fail
    echo >&2
    echo "!! 实测结束后载荷与冻结记录不一致 —— 这段观察**作废**（finalize 会拒绝它）。" >&2
  fi
  if ! sandbox_guard_verify "$snap" "$snap2"; then
    end_check=fail
    echo "!! 实测期间本地正在运行的 dsh runtime 被触碰 —— 这段观察**作废**" >&2
  fi
  # 交接结果：**分层**报告，不把"被调用/返回 0"混成"交接成功"（评审裁决）。
  # 只有"人在浏览器里看见目标页面"才算交接成功，那件事 serve 看不到。
  local browser="unobserved-native" burl="" brc="" bout=""
  if [ "$OPT_PROBE_HANDOFF" = 1 ]; then
    browser="not-called"
    if [ -s "$blog" ]; then
      burl="$(sed -n 's/^call	//p' "$blog" | head -n 1)"
      brc="$(sed -n 's/^rc	//p' "$blog" | head -n 1)"
      bout="$(sed -n 's/^out	//p' "$blog" | head -n 1)"
      if [ -z "$brc" ]; then browser="called-no-return"
      elif [ "$brc" = 0 ]; then browser="called-exit-0"
      else browser="called-exit-$brc"; fi
    fi
  fi
  local enote s2name
  s2name="$(basename "$snap2")"
  enote="serve_exit=$rc machinery=$mach tty=$ttyf guard=$s2name"
  enote+=" browser=$browser handoff_url=${burl:--} env_policy=$SANDBOX_POLICY_HUMAN"
  enote+=" dropped=${SANDBOX_ENV_DROPPED:--} strip_android_root=$OPT_STRIP_ANDROID_ROOT"
  enote+=" probe_handoff=$OPT_PROBE_HANDOFF"
  frozen_observe_append end "$oid" "$round" "$case_id" "$clist" "$end_check" "$enote" \
    || echo "!! 观察台账写不进去（收尾那次）" >&2

  echo
  echo "======================================================================"
  echo " 本次实测对象: $oid"
  [ "$end_check" = ok ] && echo " 起止两次载荷校验: 都通过" \
                        || echo " 起止两次载荷校验: **结束那次不通过 —— 这段观察作废**"
  case "$browser" in
    unobserved-native)
      echo " 浏览器交接: serve **未插桩**（默认走原生接线）"
      echo "            → 成不成以你**在浏览器里看到目标页面**为准；serve 不对它下结论" ;;
    not-called)
      echo " 浏览器交接: [诊断] shim 没被调用 —— dsh 没有走到 opener" ;;
    called-no-return)
      echo " 浏览器交接: [诊断] shim 被调用，但没记到返回（记录不完整 = 未观测，不算成功）" ;;
    called-exit-0)
      echo " 浏览器交接: [诊断] opener 返回 0 —— 只证明**该进程返回**，不证明浏览器打开了" ;;
    called-exit-*)
      echo " 浏览器交接: [诊断] opener 失败，退出码 ${browser#called-exit-}"
      [ -n "$bout" ] && echo "   opener 输出: $bout" ;;
  esac
  # 目标 URL 只在终端上给一次（供手动打开），**不落台账**；用完即删。
  if [ -f "$root/.serve-browser-url" ]; then
    echo "   目标 URL（仅本次打印，不落台账）: $(cat "$root/.serve-browser-url")"
    rm -f "$root/.serve-browser-url"
  fi
  [ -f "$blog" ] && echo "   记录: ${blog#"$ROOT"/}"
  if [ "$round" != "-" ]; then
    echo
    echo " 若上面的清单逐项确认通过，请把这句话交给 agent 执行（它不会自己跑）:"
    echo "   bash .test-install/run.sh finalize $round --observed $oid"
  else
    echo " （--sandbox 直起的对象不属于任何轮次，只能用于诊断/复看，不能终结轮次。）"
  fi
  echo "======================================================================"
  [ "$end_check" = ok ] || exit 1
  return 0
}

# ---- 入口 ------------------------------------------------------------------
if [ "$OPT_LIST" = 1 ]; then cmd_list; exit 0; fi

registry_load "$TI_DIR" || exit 2
if [ -n "$OPT_ROUND" ]; then
  rd="$(round_dir "$OPT_ROUND")"
  if [ ! -f "$rd/round.tsv" ]; then
    echo "!! 没有轮次 '$OPT_ROUND'（缺 $rd/round.tsv）" >&2
    echo "   轮次由 run.sh verify 开出；用 --list 看现有的。" >&2
    exit 2
  fi
  pick="$(pick_from_round "$rd")" || exit $?
  # objects.tsv 一行是 case_id<TAB>对象id<TAB>沙箱名
  pc_case="${pick%%|*}"; pc_rest="${pick#*|}"
  pc_id="${pc_rest%%|*}"; pc_sbox="${pc_rest#*|}"
  pc_mf="$(frozen_resolve "$pc_id")" || {
    echo "!! 找不到对象记录 $pc_id（state/frozen/）—— 它可能已被清理" >&2; exit 2; }
  serve_object "$TI_DIR/sandbox-$pc_sbox" "$pc_mf" "$OPT_ROUND" "$pc_case"
  exit $?
elif [ -n "$OPT_SANDBOX" ]; then
  root="$TI_DIR/$OPT_SANDBOX"
  case "$OPT_SANDBOX" in sandbox-*) ;; *) root="$TI_DIR/sandbox-$OPT_SANDBOX" ;; esac
  mf="$root/frozen.tsv"
  [ -f "$mf" ] || {
    echo "!! $root 里没有冻结记录（frozen.tsv）—— 它不是冻结对象。" >&2
    echo "   冻结对象由 run.sh verify（或 run.sh check --freeze -c <case>）产出；" >&2
    echo "   用 --list 看现有的。" >&2
    exit 2; }
  serve_object "$root" "$mf" "-" "$(frozen_get "$mf" case_id)"
  exit $?
fi

echo "serve.sh: 需要 --list / --round <轮次id> / --sandbox <沙箱名> 之一。" >&2
echo >&2
usage_text >&2
exit 2
