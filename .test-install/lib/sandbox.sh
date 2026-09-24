#!/data/data/com.termux/files/usr/bin/bash
# sandbox.sh — 隔离内核：每个 case 在自己的沙箱里跑，且**绝不触碰本地正在运行的
# dsh runtime**。
#
# 为什么不能只是"设几个环境变量"（旧体系的教训，见 DECISIONS 实查更正 C4）:
#   旧哨兵只校验线上 node 二进制的四元组 —— 它证明不了 `~/.dsh`、`~/.bashrc`、
#   wrapper 没被碰过; 而 `PATH` 里的 `~/.local/bin` 会让 case 里的 `dsh` 直接命中
#   **线上** wrapper。隔离必须同时是**预防**和**检测**，缺一半都不算数:
#
#   1. 预防 —— 环境是**白名单**（`env -i` 起进程，只放进显式列出的变量），
#      并把线上 wrapper 所在目录从 PATH 里摘掉。于是"某个 DSH_*/LD_*/NODE_*
#      忘了 unset"这一类失效模式在结构上就不存在，而不是靠清单不漂移。
#   2. 检测 —— 每次运行前后对线上 runtime 的**全路径**做签名比对（整棵
#      runtime 树 + wrapper + `~/.bashrc` + `~/.dsh`），而不只是 node 二进制。
#
# 第三条纪律: **任何相对落点都不在仓库里**。case 的 cwd 是沙箱内的目录，
# 仓库一律通过 `$DSH_HARNESS_ROOT` 绝对引用（先例: 旧体系里一个无守卫的临时
# 目录测试曾在仓库根目录误覆盖文件）。

set -uo pipefail

# 线上 HOME 由 run.sh 在**覆盖任何变量之前**捕获并导出。这里绝不回落到运行期
# 的 $HOME —— 一旦有人先改了 HOME，回落到它就会把"线上"重新定义成沙箱。
sandbox_live_home() {
  : "${DSH_LIVE_HOME:?sandbox: DSH_LIVE_HOME 未设置（应由 run.sh 传入真实 HOME）}"
  printf '%s\n' "$DSH_LIVE_HOME"
}

# 需要守卫的线上路径。
#
# ⚠️ `~/.dsh` **刻意不在名单里**，这是实测得出的结论而不是遗漏:
#   * 它是**活着的运行时会话状态目录** —— 只要用户在用 dsh（比如正开着 web 会话），
#     里面就一直在被写。实测 6 秒间隔两次签名已经不同。
#   * 把"一直在变的东西"当违规信号，结果是每次都红；一个总是红的守卫等于没有守卫。
#   * 编译期/运行期的**预防**已经覆盖了它: DSH_HOME 被钉进沙箱、线上 wrapper 目录
#     从 PATH 摘掉、白名单环境里不允许出现线上路径。要越过这三道去写 `~/.dsh`，
#     case 必须显式硬编码 `$DSH_LIVE_HOME/.dsh` —— 那是 code review 能看见的事，
#     本条注释就是给 review 的提示（残留风险，已知并接受）。
#
# 剩下的这几条则相反: **除了测试自己，没有任何东西会写它们**，所以"运行期间变了"
# 是明确无疑的越界证据。
sandbox_live_paths() {
  local h
  h="$(sandbox_live_home)"
  printf '%s\n' \
    "$h/.local/opt/dsh-termux-runtime" \
    "$h/.local/bin/dsh" \
    "$h/.bashrc" \
    "$h/.bash_profile" \
    "$h/.profile"
}

sandbox_case_name() { # $1=case id -> 沙箱名（同时用于目录名与锁文件名）
  local n
  n="$(printf '%s' "${1:-}" | tr '/' '-')"
  case "$n" in
    ''|*[!a-z0-9-]*) echo "!! case id 含非法字符（只允许 a-z0-9- 与 '/'）: ${1:-<空>}" >&2; return 2 ;;
  esac
  printf '%s\n' "$n"
}

sandbox_root_for() { # $1=沙箱名
  printf '%s/sandbox-%s\n' "${DSH_TI_DIR:?}" "$1"
}

sandbox_write_grun_stub() { # $1=目录
  mkdir -p "$1" || return 1
  printf '#!/data/data/com.termux/files/usr/bin/bash\nexec "$@"\n' > "$1/grun"
  chmod +x "$1/grun"
}

# PATH 里必须摘掉线上 wrapper 所在目录: 否则 `dsh` 会命中线上安装，
# 这是隔离失效最直接的一条路。其余 PATH 原样保留（Termux 的工具都在里面）。
sandbox_filtered_path() {
  local live_bin out="" part
  live_bin="$(sandbox_live_home)/.local/bin"
  local IFS=':'
  for part in $PATH; do
    [ -n "$part" ] || continue
    [ "$part" = "$live_bin" ] && continue
    out="${out:+$out:}$part"
  done
  printf '%s\n' "$out"
}

# 透传名单: **只有**这些父进程变量会进沙箱。分两类理由——
#   Android/Termux 运行必需（PREFIX 等）、以及网络（受限环境靠代理才能装包）。
# 刻意不含: GH_TOKEN（设备侧脚本不得依赖 token，泄漏进沙箱更是坏事）、
# LD_*/NODE_*/NODE_OPTIONS（bionic 与 glibc 混用会直接让被测进程起不来，
# 测的是产物不是调用者的 shell）。
SANDBOX_PASSTHROUGH="PREFIX TERM LANG LC_ALL SHELL USER LOGNAME COLORTERM
EXTERNAL_STORAGE ANDROID_ROOT ANDROID_DATA ANDROID_ASSETS ANDROID_STORAGE
http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY"

# 沙箱**钉子**：无论走哪条环境政策都要覆盖的那批。抽出来是因为 serve 与 case
# 用的是两种不同的环境政策（见 sandbox_env_human），但"哪些变量必须钉进沙箱"是同一件事。
sandbox_pin_env() { # 结果写进全局数组 SANDBOX_PINS
  # 显式定死 IFS: 下面按空白分词透传名单，绝不能继承调用者可能改过的 IFS。
  local IFS=$' \t\n'
  SANDBOX_PINS=()
  SANDBOX_PINS+=("PATH=$SANDBOX_ROOT/bin:$(sandbox_filtered_path)")
  SANDBOX_PINS+=("HOME=$SANDBOX_ROOT/home")
  SANDBOX_PINS+=("TMPDIR=$SANDBOX_ROOT/tmp" "TMP=$SANDBOX_ROOT/tmp")
  # 运行时读 XDG_* 与 DSH_HOME（实测 `dsh-anonymous-user-id` 等包直接消费它们）,
  # 所以在**变量层面**就把它们钉进沙箱, 而不是指望调用方各自守规矩。
  SANDBOX_PINS+=("XDG_CONFIG_HOME=$SANDBOX_ROOT/home/.config"
                 "XDG_CACHE_HOME=$SANDBOX_ROOT/home/.cache"
                 "XDG_DATA_HOME=$SANDBOX_ROOT/home/.local/share"
                 "XDG_STATE_HOME=$SANDBOX_ROOT/home/.local/state")
  SANDBOX_PINS+=("DSH_HOME=$SANDBOX_ROOT/home/.dsh")
  SANDBOX_PINS+=("DSH_RUNTIME_DIR=$SANDBOX_ROOT/prefix"
                 "DSH_BIN_DIR=$SANDBOX_ROOT/bin"
                 "DSH_WORK_DIR=$SANDBOX_ROOT/prefix/work")
  SANDBOX_PINS+=("DSH_SANDBOX_NAME=$SANDBOX_NAME" "DSH_SANDBOX_ROOT=$SANDBOX_ROOT")
  # 运行器交给 case 的契约变量（白名单环境不会自动带上它们）
  #
  # DSH_LIVE_HOME 也在名单里，且是**刻意**的: case 需要能断言"我没碰线上"、
  # "PATH 里没有线上 wrapper"。知道线上在哪不等于被允许写它——真正的保护是
  # 运行前后的全路径守卫，不是信息隐藏。它的值恰好就是线上 HOME 本身，
  # 不匹配 leak check 的三条模式（只有拼上 /.local/opt/... 、/.dsh 等才算泄漏）。
  local v
  for v in DSH_HARNESS_ROOT DSH_TI_DIR DSH_LIVE_HOME DSH_RESULTS DSH_CASE_ID \
           DSH_CASE_CLASS DSH_CASE_EVIDENCE DSH_RUN_ID DSH_HARNESS_IDENTITY \
           DSH_BUILD_DIGEST DSH_BUILD_RECEIPT DSH_CANDIDATE_ARTIFACT DSH_SEED_NAME \
           DSH_RELEASE_SELECTOR DSH_RELEASE_TAG \
           DSH_NPM_TARGET_FILE DSH_NPM_TARGET_DIGEST DSH_NPM_PACKAGE DSH_NPM_VERSION \
           DSH_NPM_SPEC DSH_NPM_INTEGRITY DSH_NPM_TARBALL DSH_NPM_REGISTRY; do
    SANDBOX_PINS+=("$v=${!v:-}")
  done
  return 0
}

# case 用的环境政策：**白名单**（钉子 + 显式透传名单）。
# 透传名单存在的理由见 SANDBOX_PASSTHROUGH 的定义；"要加什么变量"只改那一处。
sandbox_build_env() { # 结果写进全局数组 SANDBOX_ENV
  local IFS=$' \t\n'
  sandbox_pin_env
  SANDBOX_ENV=("${SANDBOX_PINS[@]}")
  local name
  for name in $SANDBOX_PASSTHROUGH; do
    [ -n "${!name:-}" ] && SANDBOX_ENV+=("$name=${!name}")
  done
  return 0
}

# 会被丢掉、且**必须让人看见**的那批父环境变量（serve 用）。
SANDBOX_ENV_DROPPED=""

# 环境政策标识：进观察台账。裁决要求"证据必须说清它属于哪套环境政策"——
# 自动层与人工层现在是**互补**证据，不是同一环境的两次复现。
# 这两个常量由调用方（run.sh / serve.sh）读走写进收据与台账。
# shellcheck disable=SC2034
SANDBOX_POLICY_CASE="case-whitelist/1"
# shellcheck disable=SC2034
SANDBOX_POLICY_HUMAN="serve-parent/1"

# **serve 用的环境政策：父环境 − 危险项 + 沙箱覆盖。**
#
# 为什么不沿用 case 的白名单（2026-09 真机实测，见 DECISIONS「尚未解决」与 ADR-010）:
#   同一台设备、同一支 opener，白名单环境里 `termux-open-url` 退出码 0 而浏览器不弹;
#   换成"父环境 + 沙箱覆盖"就正常弹出。而且 `~/.profile` 里的 provider key 也进不来。
#   根子上: 白名单是给**无人值守、必须可复现**的 case 用的; 人类实测的目的恰恰是
#   "按真实用户的环境跑一遍"——给它一份没人真正使用的环境, 测的就不是产品了。
#
# 仍然不让进沙箱的（每一条都有理由，不是"顺手过滤")：
#   LD_* / NODE_OPTIONS / NODE_PATH  bionic 与 glibc 混用会让被测进程直接起不来
#   GH_TOKEN / GITHUB_TOKEN          测试体系一律不给凭据（ADR-008）；会话里的 agent
#                                    不该顺手拿到能推仓库的令牌
#   SHELL / PWD / OLDPWD / _         与 HOME 同类的"指向外面"的定位变量
#   ANDROID_{ART,I18N,TZDATA}_ROOT  Android 14+ 注入的 APEX 路径，**实测**会让 `am`
#                                    打不开 /dev/binder（见下面那行注释里的最小失败集合）
#   值里含**线上 runtime 路径**的任何变量（名字列进 SANDBOX_ENV_DROPPED，不静默丢）
# 覆盖（钉子）: PATH/HOME/TMPDIR/TMP/XDG_*/DSH_* —— 与 case 完全相同，追加在最后，
# 因此同名变量以钉子为准。
# 可用 `--strip-android-root` 打开**仅诊断**的剥离：Android 14+ 注入的
# `ANDROID_{ART,I18N,TZDATA}_ROOT` 在 agent 环境里实测会让 `am` 打不开 /dev/binder
# （delta-debugging 到最小失败集合，三个缺一不可），而人类自己的环境带着它们照样能弹。
# 因此**默认保留**——否则就是"测试入口替产品把问题修好了"：载荷摘要一个字没变，
# 验收的启动条件却被偷偷改过。诊断模式下剥离后成功，**不能**替代原环境下的人工项。
sandbox_env_human() { # [--strip-android-root] 结果写进全局数组 SANDBOX_ENV
  local IFS=$' \t\n'
  local strip_android=0
  [ "${1:-}" = "--strip-android-root" ] && strip_android=1
  SANDBOX_ENV=()
  SANDBOX_ENV_DROPPED=""
  local h; h="$(sandbox_live_home)"
  local n v
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    case "$n" in
      LD_*|NODE_OPTIONS|NODE_PATH|GH_TOKEN|GITHUB_TOKEN) continue ;;
      ANDROID_ART_ROOT|ANDROID_I18N_ROOT|ANDROID_TZDATA_ROOT)
        [ "$strip_android" = 1 ] || SANDBOX_ENV+=("$n=${!n}")
        continue ;;
      SHELL|PWD|OLDPWD|_|HOME|TMPDIR|TMP|PATH|BROWSER|XDG_*|DSH_*) continue ;;
    esac
    v="${!n}"
    case "$v" in
      *"$h/.local/opt/dsh-termux-runtime"*|*"$h/.dsh"*|*"$h/.local/bin/dsh"*)
        SANDBOX_ENV_DROPPED+="${SANDBOX_ENV_DROPPED:+ }$n"
        continue ;;
    esac
    SANDBOX_ENV+=("$n=$v")
  done < <(compgen -e | LC_ALL=C sort)
  sandbox_pin_env
  SANDBOX_ENV+=("${SANDBOX_PINS[@]}")
  return 0
}

# 审计用：**只打印变量名**（排序）。裁决要求"完整继承的变量名可供审计"——
# 凭据是被继承进来的，所以"哪些名字进了沙箱"必须看得见；值一个都不记录。
sandbox_env_names() { # 读全局数组 SANDBOX_ENV
  local e
  for e in "${SANDBOX_ENV[@]}"; do printf '%s\n' "${e%%=*}"; done | LC_ALL=C sort
}

# 白名单建成之后仍然自检一次: 任何变量的值里出现线上路径，就是泄漏。
sandbox_env_leak_check() {
  local h e name
  h="$(sandbox_live_home)"
  for e in "${SANDBOX_ENV[@]}"; do
    name="${e%%=*}"
    case "${e#*=}" in
      *"$h/.local/opt/dsh-termux-runtime"*|*"$h/.dsh"*|*"$h/.local/bin/dsh"*)
        echo "!! 沙箱环境泄漏了线上路径: $name" >&2
        return 1 ;;
    esac
  done
  return 0
}

# sandbox_prepare <case-id> -> 0 ok / 2 框架错误
# 只**计算**环境、不改调用者的环境: 调用者（run.sh）自己的 HOME/PATH 必须保持
# 原样，否则下一个 case 的"线上"就被上一个 case 的沙箱污染了。
sandbox_prepare() {
  local id="$1" name root
  name="$(sandbox_case_name "$id")" || return 2
  root="$(sandbox_root_for "$name")"
  # rm -rf 发生在任何断言之前 —— 先证明落点在 .test-install/ 下再动手
  # （AGENTS §3 同类事故: 无守卫的临时目录曾删到别处）。
  case "$root" in
    "$DSH_TI_DIR"/sandbox-*) ;;
    *) echo "!! 沙箱路径越界，拒绝创建: $root" >&2; return 2 ;;
  esac
  case "$root" in *'..'*) echo "!! 沙箱路径含 '..': $root" >&2; return 2 ;; esac

  command -v flock >/dev/null 2>&1 || { echo "!! 隔离需要 flock (Termux: pkg install util-linux)" >&2; return 2; }
  exec 9>"$DSH_TI_DIR/.sandbox-$name.lock" || return 2
  flock -n 9 || { echo "!! sandbox-$name 正被占用（同一沙箱不可并行）" >&2; return 2; }

  rm -rf "$root"
  mkdir -p "$root/home" "$root/tmp" "$root/prefix" "$root/bin" || return 2
  sandbox_write_grun_stub "$root/bin" || return 2
  SANDBOX_NAME="$name"
  SANDBOX_ROOT="$root"
  sandbox_build_env
  sandbox_env_leak_check >/dev/null || return 2
  return 0
}

# 沙箱的**删除**不在这里：run.sh 只创建、只报告路径，删除一律归 `run.sh clean`
# （默认交互确认）。曾经的 `sandbox_teardown keep|remove` 会在 case 跑完顺手 rm，
# 是个隐蔽的意外删除器——人还没测，树就没了。锁 fd（exec 9）在下一条 case 的
# `sandbox_prepare` 重新指向新文件时自动释放，不需要显式关闭。

# 用白名单环境执行 case。cwd 是**沙箱内**的目录: 仓库一律走 $DSH_HARNESS_ROOT。
sandbox_exec() { # $1=case 脚本绝对路径
  local bash_bin="${BASH:-/data/data/com.termux/files/usr/bin/bash}"
  ( cd "$SANDBOX_ROOT/prefix" && exec env -i "${SANDBOX_ENV[@]}" "$bash_bin" "$1" )
}

# --- 线上 runtime 守卫 --------------------------------------------------------
# 整棵 runtime 树用 (类型|路径|大小|mtime|inode) 的排序摘要: 改动、新增、删除
# 都会被抓住，成本实测 ~0.4s。文件用 (inode.mtime.size + sha256) 四元组,
# 与旧体系同源（同字节覆写会变 inode/mtime，抓得住）。
sandbox_path_sig() { # $1=路径
  if [ -L "$1" ]; then
    printf 'symlink|%s\n' "$(readlink "$1")"
  elif [ -d "$1" ]; then
    find "$1" -printf '%y|%p|%s|%T@|%i\n' 2>/dev/null | LC_ALL=C sort \
      | sha256sum | cut -d' ' -f1
  elif [ -f "$1" ]; then
    printf 'file|%s|%s\n' "$(stat -c '%i.%Y.%s' "$1")" "$(sha256sum "$1" | cut -d' ' -f1)"
  else
    printf 'absent\n'
  fi
}

sandbox_guard_snapshot() { # $1=输出文件
  local p
  : > "$1" || return 2
  while IFS= read -r p; do
    printf '%s\t%s\n' "$p" "$(sandbox_path_sig "$p")" >> "$1"
  done < <(sandbox_live_paths)
  return 0
}

# 0 一致 / 1 有差异（差异打到 stderr） / 2 框架错误
sandbox_guard_verify() { # $1=运行前快照 $2=现值文件
  local i p sig now rc=0
  sandbox_guard_snapshot "$2" || return 2
  mapfile -t p < <(sandbox_live_paths)
  for i in "${!p[@]}"; do
    sig="$(sed -n "$((i + 1))p" "$1")"; sig="${sig#*$'\t'}"
    now="$(sed -n "$((i + 1))p" "$2")"; now="${now#*$'\t'}"
    [ "$sig" = "$now" ] && continue
    echo "!! 本地正在运行的 dsh runtime 在 case 运行期间被触碰: ${p[$i]}" >&2
    echo "   运行前: ${sig:0:96}" >&2
    echo "   运行后: ${now:0:96}" >&2
    echo "   这是红线（AGENTS §1）。测试产物必须落在沙箱内。" >&2
    rc=1
  done
  return "$rc"
}
