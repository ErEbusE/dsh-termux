#!/data/data/com.termux/files/usr/bin/bash
# common.sh — shared helpers for the dsh-termux install scripts.
# Sourced by scripts/00-04. No shebang execution.

# --- Prompt helpers -------------------------------------------------------

# Ask a yes/no question. Default is YES. Returns 0 (yes) or 1 (no).
# Honors DSH_ASSUME_YES=1 (from the -y flag): returns the default without asking.
ask_yes_no() {
  local prompt="$1"
  local default="${2:-yes}"   # yes | no
  if [ "${DSH_ASSUME_YES:-0}" = "1" ]; then
    echo "   [auto-yes] ${prompt}"
    [ "$default" = "yes" ]
    return $?
  fi
  local ans
  while :; do
    if [ "$default" = "yes" ]; then
      printf '%s [Y/n]: ' "$prompt"
    else
      printf '%s [y/N]: ' "$prompt"
    fi
    read -r ans
    case "${ans,,}" in
      "" ) [ "$default" = "yes" ]; return $? ;;
      y|yes ) return 0 ;;
      n|no ) return 1 ;;
      * ) echo "   Please answer y or n." ;;
    esac
  done
}

# Ask for a value with a default; validates input with a validator function.
#   ask_input <var_name> <prompt> <default> <validator_func>
# The validator receives the candidate as $1 and returns 0 if valid.
ask_input() {
  local var="$1" prompt="$2" default="$3" validator="$4"
  if [ "${DSH_ASSUME_YES:-0}" = "1" ]; then
    printf -v "$var" '%s' "$default"
    echo "   [auto] ${prompt} -> ${default}"
    return 0
  fi
  local val
  while :; do
    printf '%s [%s]: ' "$prompt" "$default"
    read -r val
    val="${val:-$default}"
    # 空默认 + 空输入 = 用户接受「无值」语义: 直接放行, 由调用方归一 (如
    # 00-setup 的 ${DSH_WORK_DIR:-$DSH_RUNTIME_DIR/work})。空串此刻若再交给
    # validator (validate_abs_path 等) 必被拒, 提示里「empty = 默认」的承诺
    # 就成了交互死循环 (architecture 审计实测确认)。default 非空时 val 已
    # 回落为 default, 不会走到这里, 各原有调用点行为不变。
    if [ -z "$val" ]; then
      printf -v "$var" '%s' "$val"
      return 0
    fi
    if [ -z "$validator" ] || "$validator" "$val"; then
      printf -v "$var" '%s' "$val"
      return 0
    fi
    echo "   Invalid input, please try again."
  done
}

# --- Validators -----------------------------------------------------------

# Absolute path, no spaces, no leading '~'.
validate_abs_path() {
  local p="$1"
  [[ "$p" =~ ^/ ]] || { echo "   (must be an absolute path starting with /)"; return 1; }
  [[ "$p" != *" "* ]] || { echo "   (must not contain spaces — npm and the ELF loader path dislike them)"; return 1; }
  return 0
}

# Semantic version X.Y.Z matching dsh engines: ^22.19.0 || >=24.0.0.
validate_node_version() {
  local v="${1#v}"
  if ! [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "   (expected X.Y.Z, e.g. 24.19.0)"
    return 1
  fi
  local major minor
  major="${v%%.*}"; minor="${v#*.}"; minor="${minor%%.*}"
  if { [ "$major" -eq 22 ] && [ "$minor" -ge 19 ]; } || [ "$major" -ge 24 ]; then
    return 0
  fi
  echo "   (dsh requires Node ^22.19.0 || >=24.0.0; you entered ${major}.${minor})"
  return 1
}

# A bare port number 1..65535.
validate_port() {
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -ge 1 ] && [ "$p" -le 65535 ]
}

# --- glibc Node ------------------------------------------------------------

# Termux's glibc prefix; exported inside a glibc-runner shell, defaulted here.
glibc_prefix() {
  echo "${GLIBC_PREFIX:-/data/data/com.termux/files/usr/glibc}"
}

# Run the configured Node the same way the generated `dsh` wrapper does.
#   run_glibc_node <node_bin> [args...]
run_glibc_node() {
  local node_bin="$1"; shift
  env -u LD_PRELOAD PATH="$(glibc_prefix)/bin:$PATH" "$node_bin" "$@"
}

# Point the official Node binary's ELF interpreter at Termux's glibc loader so
# the kernel can exec node DIRECTLY instead of running it through `grun`.
#
# Why this matters: grun launches a glibc binary as `ld.so <binary>` (the final
# `exec ... ld.so $@` in glibc-runner.sh). The program the kernel executed is
# then the LOADER, so `/proc/self/exe` — and therefore Node's
# `process.execPath` — is `ld-linux-aarch64.so.1`, not node. dsh re-spawns
# `process.execPath` to run helpers, including the `dsh web` browser handoff,
# which therefore died with:
#     ld-linux-aarch64.so.1: unrecognized option '--input-type=module'
# grun additionally word-splits its arguments (`source ... $@` and
# `exec ld.so $@`, both unquoted), so `dsh "two words"` arrived as two argv
# entries. Exec'ing node directly fixes both.
#
# ONLY --set-interpreter. Combining it with --set-rpath in a single patchelf run
# produces a Node binary that SEGFAULTS (verified on node 22.20.0 + patchelf
# 0.19.1/aarch64: either option alone is fine, the two together are not). No
# rpath is needed anyway — Termux's glibc loader already searches its own lib dir.
#
# The swap is copy -> patch -> verify -> atomic rename, never an in-place
# rewrite. A running dsh has this binary mmap'd, and rewriting those pages under
# it raises SIGBUS/SIGSEGV and kills the live process (this is exactly how an
# in-place `grun -c` killed a running `dsh web` during development). `mv` only
# replaces the directory entry, so running processes keep their inode untouched,
# and verifying the patched copy first means a bad patch can never replace a
# working node.
#
#   configure_glibc_node <node_bin>
configure_glibc_node() {
  local node_bin="$1"
  local prefix loader current staged version
  prefix="$(glibc_prefix)"

  if [ ! -x "$node_bin" ]; then
    echo "!! configure_glibc_node: '$node_bin' is missing or not executable" >&2
    return 1
  fi
  if ! command -v patchelf >/dev/null 2>&1; then
    echo "!! configure_glibc_node: patchelf not found (it ships with glibc-runner)" >&2
    return 1
  fi
  loader="$(ls "$prefix"/lib/ld-linux-*.so.* 2>/dev/null | head -1 || true)"
  if [ -z "$loader" ]; then
    echo "!! configure_glibc_node: no glibc loader found in $prefix/lib" >&2
    return 1
  fi

  current="$(patchelf --print-interpreter "$node_bin" 2>/dev/null || true)"
  if [ "$current" = "$loader" ]; then
    echo "    Node already configured for direct exec."
    return 0
  fi

  staged="$node_bin.dsh-configure.$$"
  rm -f "$staged"
  echo "    Configuring Node for direct exec (interpreter -> $loader) ..."
  if ! cp "$node_bin" "$staged"; then
    rm -f "$staged"
    echo "!! configure_glibc_node: could not stage a copy (disk space?); Node left unchanged" >&2
    return 1
  fi
  chmod +x "$staged"
  if ! patchelf --set-interpreter "$loader" "$staged"; then
    rm -f "$staged"
    echo "!! configure_glibc_node: patchelf failed; Node left unchanged" >&2
    return 1
  fi
  # The patched COPY must prove it runs before it may replace a working node.
  version="$(env -u LD_PRELOAD "$staged" --version 2>/dev/null || true)"
  if [ -z "$version" ]; then
    rm -f "$staged"
    echo "!! configure_glibc_node: the patched Node does not run; Node left unchanged" >&2
    return 1
  fi
  mv -f "$staged" "$node_bin"
  echo "    Node configured for direct exec: $version"
}

# --- dsh wrapper ----------------------------------------------------------

# Write the Termux `$BROWSER` opener the wrapper points at.
#
# dsh reaches $BROWSER from two call sites that need DIFFERENT Android intents:
#   - `dsh web` passes an http(s) URL, through the `open` package's bundled
#     freedesktop xdg-open (which consults $BROWSER before any desktop probe);
#   - host.openPath passes a FILE PATH for .html/.htm/.xhtml/.svg, because
#     dsh's native-path-opener prefers a named browser for documents a browser
#     renders and reads $BROWSER directly to find one.
# `am start -d <bare path>` cannot resolve an Intent (no scheme, exits 1), while
# TermuxOpenReceiver builds the content:// URI a file needs. So dispatch on the
# argument instead of forcing either tool to cover both.
#
#   write_dsh_opener <opener_path>
write_dsh_opener() {
  local opener="$1"
  cat > "$opener" << 'DSH_OPENER'
#!/data/data/com.termux/files/usr/bin/sh
# dsh-termux-open — the $BROWSER opener the dsh wrapper installs on Termux.
# Generated by dsh-termux; regenerated by every install/update, so do not edit.
#
# `dsh web` hands this an http(s) URL, while dsh's native path opener hands it a
# FILE PATH for .html/.htm/.xhtml/.svg documents. Those need different Android
# intents: `am start -d <bare path>` cannot resolve an Intent, and only
# TermuxOpenReceiver builds the content:// URI a local file needs.
set -u

target="${1:-}"
if [ -z "$target" ]; then
  echo "dsh-termux-open: expected one URL or file path" >&2
  exit 2
fi

case "$target" in
  # What a browser handoff actually means: am start -a VIEW -d <url>.
  http://*|https://*) tool=termux-open-url ;;
  # File paths (and any other scheme): termux-open handles both, and is what
  # Termux's own /usr/bin/xdg-open symlink points at.
  *) tool=termux-open ;;
esac

if ! command -v "$tool" >/dev/null 2>&1; then
  echo "dsh-termux-open: $tool not found; it ships in Termux's termux-tools package" >&2
  exit 127
fi

exec "$tool" "$target"
DSH_OPENER
  chmod +x "$opener"
}

# Write the `dsh` launcher: it execs the configured Node DIRECTLY (never
# through grun) and teaches the browser handoff about Android. Emits the opener
# above next to it.
#
# Why not grun: see configure_glibc_node. grun runs `ld.so <node>`, which makes
# `process.execPath` the loader and breaks every dsh helper that re-spawns it —
# the `dsh web` browser handoff most visibly — and it word-splits arguments.
# This wrapper reproduces the only environment glibc-runner actually set up for
# node: no bionic LD_PRELOAD, and its own bin dir first on PATH.
#
# Why the $BROWSER line: `process.platform` is "linux" under glibc Node, so the
# `open` package that dsh hands `dsh web` URLs to prefers its own bundled
# freedesktop `xdg-open`. Android has no freedesktop desktop, so that script
# walks x-www-browser/firefox/lynx/w3m..., finds none, and exits 3 with
# "no method available". `$BROWSER` is the first hook it consults, and dsh's own
# native-path-opener reads it directly, so one variable fixes both without
# patching dsh.
#
#   write_dsh_wrapper <wrapper_path> <node_bin> <dsh_bin> [updater_path]
#
# With <updater_path> set, the wrapper also owns a `dsh update` shortcut: when
# the FIRST argument is exactly "update", it execs bash on that updater with
# the remaining argv, so `dsh update -t next -y` runs the bundled
# update-dsh.sh with no repo checkout. Upstream dsh has no `update`
# subcommand or --update option (the CLI top level is only `web` and
# `plugin`, see upstream apps/cli/src/args.ts) and a bare `dsh update`
# previously died with "error: --profile <name> is required", so matching $1
# shadows nothing. Only $1 is ever inspected — inner arguments such as
# `--profile tui update ...` still pass through to the booted app untouched.
# Callers without an updater (e.g. CI's three-argument check) simply get no
# branch emitted; a surplus positional argument would be ignored regardless.
#
# build/install.sh sources this file out of the release tarball, so there is
# exactly one copy of these texts — no need to mirror them (CI verifies
# install.sh delegates instead of duplicating).
write_dsh_wrapper() {
  local wrapper="$1" node_bin="$2" dsh_bin="$3" updater="${4:-}"
  local opener
  opener="$(cd "$(dirname "$wrapper")" && pwd)/dsh-termux-open"
  write_dsh_opener "$opener"
  cat > "$wrapper" << 'DSH_WRAPPER_HEAD'
#!/data/data/com.termux/files/usr/bin/bash
# dsh wrapper generated by dsh-termux (glibc Node, exec'd directly).
# Accepts the same arguments as the original dsh CLI.

# Node is exec'd DIRECTLY, not through grun. grun runs `ld.so <node>`, so
# /proc/self/exe — and thus process.execPath — became the glibc loader instead
# of node; dsh re-spawns process.execPath for helpers such as the `dsh web`
# browser handoff, which then failed with
# "ld-linux-aarch64.so.1: unrecognized option '--input-type=module'". grun also
# word-split its arguments, so `dsh "two words"` arrived as two argv entries.
# Node's ELF interpreter was pointed at Termux's glibc loader at install time
# (configure_glibc_node), so the two lines below are all the environment
# glibc-runner actually provided.

# Termux's bionic preload must not leak into a glibc process.
unset LD_PRELOAD
# glibc-runner put its own bin dir first; keep that so child tools match.
export PATH="/data/data/com.termux/files/usr/glibc/bin:$PATH"

# Termux browser handoff: Android has no freedesktop desktop, so the bundled
# xdg-open that dsh's `open` dependency runs exits 3 with "no method available"
# and `dsh web` never reaches a browser. $BROWSER is the hook xdg-open consults
# first, and dsh's native path opener reads it directly; point both at the
# Android-intent opener beside this wrapper. An inherited $BROWSER always wins.
DSH_WRAPPER_HEAD
  printf 'if [ -z "${BROWSER:-}" ] && [ -x "%s" ]; then export BROWSER="%s"; fi\n\n' \
    "$opener" "$opener" >> "$wrapper"
  # Update shortcut (see the function header): only $1 is intercepted; every
  # other invocation falls through to the real dsh untouched. The branch sits
  # after "unset LD_PRELOAD", so the updater inherits exactly the environment
  # the wrapper keeps for node. A missing updater script fails with its own
  # explicit message instead of dsh's unrelated "--profile required" error.
  if [ -n "$updater" ]; then
    cat >> "$wrapper" << DSH_WRAPPER_UPDATE
if [ "\${1:-}" = "update" ]; then
  if [ -f "${updater}" ]; then
    shift
    exec bash "${updater}" "\$@"
  fi
  echo "dsh update: updater script not found at ${updater}" >&2
  echo "       reinstall the runtime, or run scripts/update-dsh.sh directly." >&2
  exit 127
fi

DSH_WRAPPER_UPDATE
  fi
  printf 'exec "%s" --expose-internals "%s" "$@"\n' "$node_bin" "$dsh_bin" >> "$wrapper"
  chmod +x "$wrapper"
}
# native_prebuild_entries — 原生依赖注册表: "包名:构建后必须存在的产物"。
# 唯一事实源; 编译 (build_native_addons)、设备侧 overlay (ensure_native_prebuilds)
# 与 r2 的发布物断言 (verify_native_prebuilds) 都从这里派生, 新增原生依赖只改这里。
DSH_NATIVE_REPO="${DSH_NATIVE_REPO:-ErEbusE/dsh-termux}"

native_prebuild_entries() {
  cat <<'NATIVE_EOF'
fs-ext:build/Release/fs_ext.node
NATIVE_EOF
}

# build_native_addons <work_dir> <node_bin> <npm_cli>
# 编译「不发 prebuild 的原生依赖」。dsh 一律以 --ignore-scripts 安装: koffi 自带
# linux-arm64 prebuild, npm 直接解析, 不需要构建脚本; 但 dsh >= 0.1.3 的会话租约
# 经 fs-ext 取 flock(2), 而 fs-ext 走 node-gyp、不发任何 prebuild —— 不补这一步,
# 任何 npm 路径装出的 0.1.3 都在启动时死掉 ("Cannot find module
# './build/Release/fs_ext.node'", 2026-09-08 首见于 patch-check @alpha)。
# 只应在**有工具链**的机器上调用 (CI runner / release 构建); Termux 设备没有
# glibc gcc, 设备侧的二进制来自发布物 (ensure_native_prebuilds)。
build_native_addons() {
  local work_dir="$1" node_bin="$2" npm_cli="$3" entry pkg artifact pkg_dir
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    IFS=: read -r pkg artifact <<<"$entry"
    pkg_dir="$work_dir/node_modules/$pkg"
    if [ ! -f "$pkg_dir/package.json" ]; then
      echo "    -- $pkg: this dsh build does not use it; skipped"
      continue
    fi
    if [ -f "$pkg_dir/$artifact" ]; then
      echo "    -- $pkg already carries $artifact; skipped"
      continue
    fi
    echo "    building $pkg (node-gyp: python3/make/g++ must be on PATH)..."
    # npm rebuild 在「当前目录的项目」里找包 —— 调用方未必 cd 进过 work_dir
    # (patch-check 就没有), 在仓库根上它会"成功地重建 0 个包"并返回 0, 再靠
    # 下面的产物断言兜住。这里显式进 work_dir, 重建的必然是目标树。
    if ! ( cd "$work_dir" && "$node_bin" "$npm_cli" rebuild --foreground-scripts "$pkg" ); then
      echo "!! npm rebuild $pkg failed — the runtime would not boot without it." >&2
      return 1
    fi
    if [ ! -f "$pkg_dir/$artifact" ]; then
      echo "!! $pkg built no $artifact (install script ran but produced nothing?)" >&2
      return 1
    fi
    # 真装载自检: 用将要在设备上跑它的同一个 node require 一遍。构建产物存在
    # 但 ABI/平台不符时, 只有这一步能当场抓住。
    if ! ( cd "$work_dir" && "$node_bin" -e "require('$pkg')" ); then
      echo "!! $pkg cannot be loaded by $node_bin (ABI/platform mismatch?)" >&2
      return 1
    fi
    echo "    built & loaded: $pkg -> $artifact"
  done < <(native_prebuild_entries)
}

# verify_native_prebuilds <work_dir> <node_bin>
# 断言: 注册表里每个**已安装**的原生依赖, 其产物必须在场且能被该 node 装载。
# 消费方: r2 (shipped tarball 的发布物断言) 与 ensure_native_prebuilds (overlay 之后)。
verify_native_prebuilds() {
  local work_dir="$1" node_bin="$2" entry pkg artifact pkg_dir
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    IFS=: read -r pkg artifact <<<"$entry"
    pkg_dir="$work_dir/node_modules/$pkg"
    [ -f "$pkg_dir/package.json" ] || continue          # 该 dsh 版本不用它
    if [ ! -f "$pkg_dir/$artifact" ]; then
      echo "!! $pkg is installed but $artifact is missing (native addon never built?)" >&2
      return 1
    fi
    if ! ( cd "$work_dir" && "$node_bin" -e "require('$pkg')" ); then
      echo "!! $pkg cannot be loaded by $node_bin (ABI/platform mismatch?)" >&2
      return 1
    fi
    echo "    OK native addon loads: $pkg -> $artifact"
  done < <(native_prebuild_entries)
}

# ensure_native_prebuilds <work_dir> <node_bin> <dsh_version>
# 设备侧 (无工具链) 的原生件来源: 从「tag 里含 dsh-<此版本>-」的那个 release 取
# dsh-termux-natives.tar.gz, 铺进 work/ 并用 verify_native_prebuilds 验收。
# 该 dsh 版本不需要原生件 (如 0.1.2) 时静默跳过; 需要却没有任何 release 发布过
# 时响亮失败 —— 安静跳过等于把启动失败留给用户在 dsh web 上撞见。
ensure_native_prebuilds() {
  local work_dir="$1" node_bin="$2" dsh_version="$3"
  local entry pkg artifact pkg_dir need=0
  while IFS= read -r entry; do
    IFS=: read -r pkg artifact <<<"$entry"
    [ -f "$work_dir/node_modules/$pkg/package.json" ] || continue
    [ -f "$work_dir/node_modules/$pkg/$artifact" ] || need=1
  done < <(native_prebuild_entries)
  [ "$need" = 1 ] || { echo "    -- no native addons required by this dsh build"; return 0; }
  echo "    resolving the release that shipped dsh $dsh_version (for prebuilt natives)..."
  local api="https://api.github.com/repos/$DSH_NATIVE_REPO/releases?per_page=100"
  local tag
  tag="$("$node_bin" -e '
    let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{
      try {
        const rels=JSON.parse(d);
        const hit=rels.find(r=>String(r.tag_name).includes("dsh-"+process.argv[1]+"-"));
        if(!hit) process.exit(3);
        console.log(hit.tag_name);
      } catch(e) { process.exit(4); }
    });' "$dsh_version" <<< "$(curl -fsSL --max-time 40 "$api" 2>/dev/null)" )" || {
    echo "!! no release carries prebuilt natives for dsh $dsh_version" >&2
    echo "   (offline, or the release has not been published yet). Install this" >&2
    echo "   dsh from its release tarball instead: install.sh ships the binary." >&2
    return 1
  }
  echo "    fetching dsh-termux-natives.tar.gz from $tag ..."
  local tmp; tmp="$(mktemp -d "$(dirname "$work_dir")/.natives.XXXXXXXX")"     || return 1
  if ! curl -fsSL --retry 2 --retry-delay 2 --max-time 120         "https://github.com/$DSH_NATIVE_REPO/releases/download/$tag/dsh-termux-natives.tar.gz"         -o "$tmp/natives.tgz"       || ! gzip -t "$tmp/natives.tgz" 2>/dev/null; then
    echo "!! natives asset missing or broken at $tag" >&2
    rm -rf "$tmp"; return 1
  fi
  tar xzf "$tmp/natives.tgz" -C "$work_dir/node_modules"     || { echo "!! natives extraction failed" >&2; rm -rf "$tmp"; return 1; }
  rm -rf "$tmp"
  verify_native_prebuilds "$work_dir" "$node_bin"
}
