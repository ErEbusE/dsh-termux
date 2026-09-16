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

# --- npm support floor (ADR-001) ---------------------------------------------
# The npm install/update path only moves dsh to >= this version; earlier dsh is
# installed from its own release tarball instead. Below the floor the tree needs
# a compiled native addon (`fs-ext`'s build/Release/fs_ext.node) that this
# project no longer builds or ships, so npm would "succeed" and the runtime
# would then refuse to boot — a silent breakage. Both entry points therefore
# resolve the requested target to ONE exact version and refuse it here, before
# npm rewrites anything.
DSH_NPM_SUPPORT_FLOOR="0.1.5-alpha.1"
DSH_REPO="${DSH_REPO:-ErEbusE/dsh-termux}"

# _dsh_semver_parts <version> -> "<major> <minor> <patch> <prerelease>"
# Accepts plain X.Y.Z[-pre][+build]; drops build metadata (SemVer §10: it takes
# no part in precedence). Returns 1 when the shape is anything else.
_dsh_semver_parts() {
  local v="${1:-}" core pre maj min pat
  v="${v%%+*}"
  case "$v" in
    *-*) core="${v%%-*}"; pre="${v#*-}"; [ -n "$pre" ] || return 1 ;;
    *)   core="$v"; pre="" ;;
  esac
  [[ $core =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  # Prerelease must be dot-separated non-empty [0-9A-Za-z-] identifiers: this is
  # what rejects "1.2.3-", "1.2.3-rc..1" and similar SemVer-invalid shapes.
  [ -z "$pre" ] || [[ $pre =~ ^[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*$ ]] || return 1
  IFS=. read -r maj min pat <<<"$core"   # IFS is scoped to `read`, never leaked
  printf '%s %s %s %s\n' "$maj" "$min" "$pat" "$pre"
}

# _dsh_prerelease_cmp <a> <b> -> 0 equal / 1 a>b / 2 a<b (SemVer §11.4).
# `local LC_ALL=C` is load-bearing: [[ < ]] collates through the locale, and
# prerelease identifiers must sort by ASCII, not by the user's collation.
_dsh_prerelease_cmp() {
  local LC_ALL=C
  local -a A B
  local i n x y
  IFS=. read -r -a A <<<"$1"
  IFS=. read -r -a B <<<"$2"
  n="${#A[@]}"; [ "${#B[@]}" -ge "$n" ] || n="${#B[@]}"
  for ((i = 0; i < n; i++)); do
    x="${A[i]}"; y="${B[i]}"
    if [[ $x =~ ^[0-9]+$ && $y =~ ^[0-9]+$ ]]; then
      [ "$x" -lt "$y" ] && return 2
      [ "$x" -gt "$y" ] && return 1
    elif [[ $x =~ ^[0-9]+$ ]]; then
      return 2                      # numeric identifiers rank below alphanumeric
    elif [[ $y =~ ^[0-9]+$ ]]; then
      return 1
    else
      [[ $x < $y ]] && return 2
      [[ $x > $y ]] && return 1
    fi
  done
  [ "${#A[@]}" -lt "${#B[@]}" ] && return 2
  [ "${#A[@]}" -gt "${#B[@]}" ] && return 1
  return 0
}

# dsh_version_cmp <a> <b> -> 0 equal / 1 a>b / 2 a<b / 3 either is not a version.
# Deliberately NOT `sort -V`, string compare, or npm's range matching: npm's
# range rules exclude prereleases in a way that is not precedence comparison.
dsh_version_cmp() {
  local pa pb am aj ap ao bm bj bp bo ca cb
  pa="$(_dsh_semver_parts "$1")" || return 3
  pb="$(_dsh_semver_parts "$2")" || return 3
  read -r am aj ap ao <<<"$pa"
  read -r bm bj bp bo <<<"$pb"
  # Zero-padded so a plain string compare IS a numeric compare.
  ca="$(printf '%010d.%010d.%010d' "$am" "$aj" "$ap")"
  cb="$(printf '%010d.%010d.%010d' "$bm" "$bj" "$bp")"
  [ "$ca" = "$cb" ] || { [[ $ca < $cb ]] && return 2 || return 1; }
  # Equal cores: an absent prerelease ranks HIGHER (SemVer §11.3).
  if [ -z "$ao" ] && [ -z "$bo" ]; then return 0; fi
  [ -n "$ao" ] || return 1
  [ -n "$bo" ] || return 2
  _dsh_prerelease_cmp "$ao" "$bo"
}

# dsh_version_below_floor <version> -> 0 below / 1 at or above / 3 unparsable.
dsh_version_below_floor() {
  local rc=0
  dsh_version_cmp "${1:-}" "$DSH_NPM_SUPPORT_FLOOR" || rc=$?
  case "$rc" in
    2) return 0 ;;
    0|1) return 1 ;;
    *) return 3 ;;
  esac
}

# dsh_floor_refusal <resolved-version> <verb> — the refusal both entry points
# print. It must name the version, the floor, the reason, and a path that
# actually exists: npm having a version says NOTHING about a matching project
# release, so the alternative is stated with that condition instead of a tag we
# would have to invent.
dsh_floor_refusal() {
  local v="$1" verb="${2:-install}"
  {
    echo "!! Refusing to $verb dsh $v: it is below the supported floor ($DSH_NPM_SUPPORT_FLOOR)."
    echo "   Nothing has been changed yet. The npm path of this project only supports dsh"
    echo "   >= $DSH_NPM_SUPPORT_FLOOR: dsh 0.1.3/0.1.4 need a compiled native addon"
    echo "   (fs-ext build/Release/fs_ext.node) that this project no longer builds or ships,"
    echo "   so such a tree would install and then fail to start."
    echo "   An older dsh installs from its own release tarball — first confirm that a"
    echo "   release carrying that dsh version (and its runtime asset) exists:"
    echo "     https://github.com/$DSH_REPO/releases"
    echo "   then either pick one interactively:  bash install.sh -p"
    echo "   or name it explicitly:               DSH_RELEASE=<release-tag> bash install.sh"
    echo "   A version on npm does not imply a matching release; without one that dsh"
    echo "   version cannot be installed by this project at all."
    echo "   Otherwise choose a version at or above $DSH_NPM_SUPPORT_FLOOR."
  } >&2
}

# dsh_spec_version <spec> -> the version/tag part of "@deepseek-ai/dsh@X".
# Prints nothing (rc 0) when the spec names the package without a version part,
# and returns 1 for anything that is not a scoped package spec.
dsh_spec_version() {
  local spec="${1:-}" rest
  case "$spec" in
    *@*) ;;
    *) return 1 ;;
  esac
  rest="${spec#*@}"                 # drop the scope's leading @
  case "$rest" in
    *@*) printf '%s' "${rest#*@}" ;;
    *) printf '%s' "" ;;            # "@deepseek-ai/dsh" == the latest dist-tag
  esac
}

# dsh_dist_tag_version <tag> <npm-dist-tags-output> -> the version that tag
# points at, or 1 when it is absent/unparsable. Parses npm's human-facing
# `{ latest: '0.1.5-rc.1', ... }`, which is what `npm view ... dist-tags` prints.
dsh_dist_tag_version() {
  local tag="$1" blob="${2:-}" line k v
  [ -n "$blob" ] || return 1
  while IFS= read -r line; do
    line="${line#\{}"; line="${line%\}*}"
    k="${line%%:*}"; v="${line#*:}"
    k="${k//[\"\' ]/}"; v="${v//[\"\' ]/}"
    [ -n "$k" ] || continue
    [ "$k" = "$tag" ] || continue
    _dsh_semver_parts "$v" >/dev/null 2>&1 || return 1
    printf '%s' "$v"
    return 0
  done < <(printf '%s\n' "$blob" | tr ',' '\n')
  return 1
}

# dsh_registry_version <node_bin> <npm_cli> <tag-or-range> -> exact version.
# One registry query; returns 1 when npm cannot resolve it. Never used as a
# fallback path for "we could not decide" — an unresolvable target is refused.
dsh_registry_version() {
  local out
  out="$(run_glibc_node "$1" "$2" view "@deepseek-ai/dsh@$3" version 2>/dev/null \
    | tr -d "\r'\" " || true)"
  [ -n "$out" ] || return 1
  _dsh_semver_parts "$out" >/dev/null 2>&1 || return 1
  printf '%s' "$out"
}

# dsh_resolve_target_version <spec> <node_bin> <npm_cli> [dist-tags-blob]
# The one place that turns a requested target into a single exact version:
#   * already a plain version  -> used as-is, no network;
#   * a dist-tag               -> looked up in the blob when given, else asked
#                                 of the registry;
#   * anything unresolvable    -> rc 1 (the caller refuses; it must never hand
#                                 the original spec back to npm).
dsh_resolve_target_version() {
  local spec="$1" node_bin="$2" npm_cli="$3" blob="${4:-}" want="" v=""
  want="$(dsh_spec_version "$spec")" || return 1
  [ -n "$want" ] || want="latest"
  if _dsh_semver_parts "$want" >/dev/null 2>&1; then
    printf '%s' "$want"
    return 0
  fi
  if [ -n "$blob" ]; then v="$(dsh_dist_tag_version "$want" "$blob" || true)"; fi
  if [ -z "$v" ]; then v="$(dsh_registry_version "$node_bin" "$npm_cli" "$want" || true)"; fi
  [ -n "$v" ] || return 1
  printf '%s' "$v"
}
