#!/data/data/com.termux/files/usr/bin/bash
# install.sh — unpack a dsh-termux runtime tarball and wire up the `dsh` command.
#
# This script ships inside the release tarball and runs ON THE TARGET DEVICE
# (Termux, arm64). It:
#   1. extracts node/ + work/ into $DSH_RUNTIME_DIR (default $HOME/.local/opt/dsh-termux-runtime),
#   2. points Node's ELF interpreter at Termux's glibc loader so it can be
#      exec'd directly (no grun / ld.so indirection),
#   3. writes the `dsh` wrapper plus the Termux `$BROWSER` opener
#      (`dsh-termux-open`) into that dir,
#   4. symlinks it to $DSH_BIN_DIR/dsh (default $HOME/.local/bin),
#   5. prepends $DSH_BIN_DIR to PATH in ~/.bashrc (tagged # dsh-termux).
#
# This script is self-contained (no dependency on the dsh-termux repo scripts)
# so it can be shipped as part of the release artifact.
#
# Usage:
#   bash install.sh                     # install to defaults, ask before mutating
#   bash install.sh -y                  # install to defaults, non-interactive
#   bash install.sh -p <tarball>        # specify the runtime tarball
#   bash install.sh --prefix <dir>      # override install prefix
#   bash install.sh --bin <dir>         # override bin dir
#   bash install.sh -h                  # show this help
#
# Flags:
#   -y, --yes           auto-accept every prompt
#   -p, --package FILE  path to the runtime tarball (default: sibling <name>-runtime.tar.gz)
#   --prefix DIR        install prefix (default $HOME/.local/opt/dsh-termux-runtime)
#   --bin DIR           bin dir for the dsh symlink (default $HOME/.local/bin)
set -euo pipefail

ASSUME_YES=0
PKG=""
PREFIX="${DSH_RUNTIME_DIR:-$HOME/.local/opt/dsh-termux-runtime}"
BIN_DIR="${DSH_BIN_DIR:-$HOME/.local/bin}"

usage() { sed -n '3,29p' "$0" >&2; exit 0; }

while [ $# -gt 0 ]; do
  case "${1,,}" in
    -y|--yes) ASSUME_YES=1 ;;
    -p|--package) PKG="$2"; shift ;;
    --prefix) PREFIX="$2"; shift ;;
    --bin) BIN_DIR="$2"; shift ;;
    -h|--help) usage ;;
    *) echo "install.sh: unknown option: $1" >&2; usage ;;
  esac
  shift
done

ask_yes_no() {
  local prompt="$1" default="${2:-yes}"
  if [ "$ASSUME_YES" = "1" ]; then echo "   [auto-yes] $prompt"; return 0; fi
  local ans
  while :; do
    if [ "$default" = "yes" ]; then printf '%s [Y/n]: ' "$prompt"; else printf '%s [y/N]: ' "$prompt"; fi
    read -r ans
    case "${ans,,}" in
      "" ) [ "$default" = "yes" ]; return $? ;;
      y|yes ) return 0 ;;
      n|no ) return 1 ;;
      * ) echo "   Please answer y or n." ;;
    esac
  done
}

validate_abs_path() {
  local p="$1"
  [[ "$p" =~ ^/ ]] || { echo "   (must be an absolute path starting with /)"; return 1; }
  [[ "$p" != *" "* ]] || { echo "   (must not contain spaces — grun cannot handle them)"; return 1; }
  return 0
}

# --- Resolve tarball --------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -z "$PKG" ]; then
  local_match="$(ls -1 "$SCRIPT_DIR"/*-runtime.tar.gz 2>/dev/null | head -1 || true)"
  PKG="${local_match:-}"
fi
if [ -z "$PKG" ] || [ ! -f "$PKG" ]; then
  echo "!! Runtime tarball not found. Pass it with -p, or place it next to this script." >&2
  exit 1
fi
PKG="$(cd "$(dirname "$PKG")" && pwd)/$(basename "$PKG")"

echo "==> dsh-termux runtime installer"
echo "    tarball : $PKG"
echo "    prefix  : $PREFIX"
echo "    bin dir : $BIN_DIR"

# --- Preflight --------------------------------------------------------------
if ! command -v grun >/dev/null 2>&1; then
  echo "!! grun (Termux glibc-runner) not found. Install with:" >&2
  echo "    pkg install glibc-repo && pkg install glibc glibc-runner" >&2
  exit 1
fi

# --- Extract ----------------------------------------------------------------
if ! ask_yes_no "Install dsh-termux runtime into $PREFIX?"; then
  echo "Aborted."; exit 1
fi
mkdir -p "$PREFIX"
echo "==> Extracting runtime into $PREFIX ..."
tar -xzf "$PKG" -C "$PREFIX"
NODE_BIN="$PREFIX/node/bin/node"
WORK_DIR="$PREFIX/work"
DSH_BIN="$WORK_DIR/node_modules/@deepseek-ai/dsh/lib/bin.js"

if [ ! -x "$NODE_BIN" ]; then
  echo "!! node not found in tarball ($NODE_BIN). Corrupt package?" >&2
  exit 1
fi
if [ ! -f "$DSH_BIN" ]; then
  echo "!! dsh not found in tarball ($DSH_BIN). Corrupt package?" >&2
  exit 1
fi

# --- Configure Node for direct exec -----------------------------------------
# Copy of configure_glibc_node in scripts/common.sh (install.sh must stay
# self-contained). The tarball ships the pristine official Node binary, whose
# ELF interpreter is /lib/ld-linux-aarch64.so.1 — a path Android does not have.
# grun works around that by running `ld.so <node>`, but then /proc/self/exe, and
# therefore Node's process.execPath, is the LOADER. dsh re-spawns
# process.execPath for helpers such as the `dsh web` browser handoff, which then
# fails with "unrecognized option '--input-type=module'"; grun also word-splits
# its arguments. Pointing the interpreter at Termux's loader lets the wrapper
# exec node directly and fixes both.
#
# ONLY --set-interpreter: combining it with --set-rpath in one patchelf run
# yields a SEGFAULTING node. No rpath is needed; the loader searches its own
# lib dir. Copy -> patch -> verify -> atomic rename, never in place: a running
# dsh has this binary mmap'd and an in-place rewrite would kill it.
GLIBC_PREFIX_DIR="${GLIBC_PREFIX:-/data/data/com.termux/files/usr/glibc}"
LOADER="$(ls "$GLIBC_PREFIX_DIR"/lib/ld-linux-*.so.* 2>/dev/null | head -1 || true)"
if [ -z "$LOADER" ]; then
  echo "!! No glibc loader found in $GLIBC_PREFIX_DIR/lib. Is glibc installed?" >&2
  exit 1
fi
if ! command -v patchelf >/dev/null 2>&1; then
  echo "!! patchelf not found (it ships with glibc-runner)." >&2
  exit 1
fi
if [ "$(patchelf --print-interpreter "$NODE_BIN" 2>/dev/null || true)" = "$LOADER" ]; then
  echo "    Node already configured for direct exec."
else
  echo "==> Configuring Node for direct exec (interpreter -> $LOADER) ..."
  STAGED="$NODE_BIN.dsh-configure.$$"
  rm -f "$STAGED"
  cp "$NODE_BIN" "$STAGED" || { rm -f "$STAGED"; echo "!! could not stage a Node copy (disk space?)" >&2; exit 1; }
  chmod +x "$STAGED"
  patchelf --set-interpreter "$LOADER" "$STAGED" \
    || { rm -f "$STAGED"; echo "!! patchelf failed; Node left unchanged" >&2; exit 1; }
  NODE_VER="$(env -u LD_PRELOAD "$STAGED" --version 2>/dev/null || true)"
  if [ -z "$NODE_VER" ]; then
    rm -f "$STAGED"
    echo "!! the patched Node does not run; Node left unchanged" >&2
    exit 1
  fi
  mv -f "$STAGED" "$NODE_BIN"
  echo "    Node configured for direct exec: $NODE_VER"
fi

# --- Write the $BROWSER opener + wrapper ------------------------------------
# Both texts are copies of write_dsh_opener / write_dsh_wrapper in
# scripts/common.sh; install.sh must stay self-contained inside the release
# tarball, so keep the two in sync (CI checks this).
OPENER="$WORK_DIR/dsh-termux-open"
cat > "$OPENER" << 'DSH_OPENER'
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
chmod +x "$OPENER"
echo "    Opener written : $OPENER"

WRAPPER="$WORK_DIR/dsh"
cat > "$WRAPPER" << 'DSH_WRAPPER_HEAD'
#!/data/data/com.termux/files/usr/bin/bash
# dsh wrapper generated by dsh-termux runtime installer.
# Accepts the same arguments as the original dsh CLI.

# Node is exec'd DIRECTLY, not through grun. grun runs `ld.so <node>`, so
# /proc/self/exe — and thus process.execPath — became the glibc loader instead
# of node; dsh re-spawns process.execPath for helpers such as the `dsh web`
# browser handoff, which then failed with
# "ld-linux-aarch64.so.1: unrecognized option '--input-type=module'". grun also
# word-split its arguments, so `dsh "two words"` arrived as two argv entries.
# Node's ELF interpreter was pointed at Termux's glibc loader at install time,
# so the two lines below are all the environment glibc-runner actually provided.

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
  "$OPENER" "$OPENER" >> "$WRAPPER"
printf 'exec "%s" --expose-internals "%s" "$@"\n' "$NODE_BIN" "$DSH_BIN" >> "$WRAPPER"
chmod +x "$WRAPPER"
echo "    Wrapper written: $WRAPPER"

# --- Symlink into bin dir ---------------------------------------------------
mkdir -p "$BIN_DIR"
LINK="$BIN_DIR/dsh"
if [ -e "$LINK" ] || [ -L "$LINK" ]; then
  if ! ask_yes_no "Replace existing $LINK?"; then
    echo "    Skipped symlink; you can run the wrapper as '$WRAPPER'."; SKIP_LINK=1
  fi
fi
if [ "${SKIP_LINK:-0}" != "1" ]; then
  ln -sf "$WRAPPER" "$LINK"
  echo "    Symlinked: $LINK -> $WRAPPER"
fi

# --- Prepend bin dir to PATH in ~/.bashrc ----------------------------------
BASHRC="$HOME/.bashrc"
TAG="# dsh-termux"
if ! grep -qF "$TAG" "$BASHRC" 2>/dev/null; then
  if ask_yes_no "Add '$BIN_DIR' to PATH in ~/.bashrc (tagged $TAG)?"; then
    printf '\n%s\n# Prepend dsh-termux bin dir so the dsh wrapper is on PATH.\nexport PATH="%s:$PATH"\n' \
      "$TAG" "$BIN_DIR" >> "$BASHRC"
    echo "    Appended to $BASHRC (tagged $TAG)."
  else
    echo "    Skipped PATH setup; run the wrapper as '$WRAPPER'."
  fi
else
  echo "    ~/.bashrc already tagged with $TAG; leaving it unchanged."
fi

echo
echo "==> Install complete."
echo "    Start a new shell (or 'source ~/.bashrc') so 'dsh' resolves."
echo "    Test:   dsh --version"
echo "    Web UI: dsh web --port 3080"
