#!/data/data/com.termux/files/usr/bin/bash
# install.sh — unpack a dsh-termux runtime tarball and wire up the `dsh` command.
#
# Runs ON THE TARGET DEVICE (Termux, arm64). It:
#   1. locates the runtime tarball: -p FILE, a *-runtime.tar.gz next to this
#      script, or an automatic download from this project's GitHub releases
#      (DSH_RELEASE=<tag|latest>, default: latest),
#   2. extracts node/ + work/ + install.sh + scripts/ + patches/ into
#      $DSH_RUNTIME_DIR (default $HOME/.local/opt/dsh-termux-runtime),
#   3. points Node's ELF interpreter at Termux's glibc loader so it can be
#      exec'd directly (no grun / ld.so indirection),
#   4. writes the `dsh` wrapper plus the Termux `$BROWSER` opener
#      (`dsh-termux-open`) into that dir,
#   5. symlinks it to $DSH_BIN_DIR/dsh (default $HOME/.local/bin),
#   6. prepends $DSH_BIN_DIR to PATH in ~/.bashrc (tagged # dsh-termux).
#
# Self-contained: needs nothing from the dsh-termux repo checkout. One-liner:
#   curl -fsSL https://github.com/ErEbusE/dsh-termux/releases/latest/download/install.sh | bash -s -- -y
# Pipe mode REQUIRES -y: stdin carries the script itself, so prompts would eat
# the remaining script bytes instead of an answer.
set -euo pipefail

REPO="${DSH_REPO:-ErEbusE/dsh-termux}"
RELEASE="${DSH_RELEASE:-latest}"
ASSUME_YES=0
PKG=""
PREFIX="${DSH_RUNTIME_DIR:-$HOME/.local/opt/dsh-termux-runtime}"
BIN_DIR="${DSH_BIN_DIR:-$HOME/.local/bin}"

usage() {
  cat <<'EOF'
install.sh — install the dsh-termux runtime on Termux (arm64).

Usage:
  bash install.sh                     # defaults; asks before mutating anything
  bash install.sh -y                  # non-interactive (REQUIRED when piping)
  bash install.sh -p <tarball>        # use a local runtime tarball
  bash install.sh --prefix <dir>      # override the install prefix
  bash install.sh --bin <dir>         # override the bin dir for the symlink

Without -p, the runtime tarball is fetched automatically:
  https://github.com/$DSH_REPO/releases/<DSH_RELEASE>/download/dsh-termux-runtime.tar.gz
  DSH_RELEASE  release tag to fetch (default: latest)
  DSH_REPO     owner/repo to fetch from (default: ErEbusE/dsh-termux)

Flags:
  -y, --yes            auto-accept every prompt (REQUIRED in pipe mode)
  -p, --package FILE   path to a local runtime tarball
  --prefix DIR         install prefix (default $HOME/.local/opt/dsh-termux-runtime)
  --bin DIR            bin dir for the dsh symlink (default $HOME/.local/bin)
  -h, --help           show this help

The tarball bundles node/, the patched dsh tree, and the updater
(scripts/update-dsh.sh + patches/), so later updates need no repo clone:
  bash ~/.local/opt/dsh-termux-runtime/scripts/update-dsh.sh -t next -y
EOF
}

while [ $# -gt 0 ]; do
  case "${1,,}" in
    -y|--yes) ASSUME_YES=1 ;;
    -p|--package) PKG="$2"; shift ;;
    --prefix) PREFIX="$2"; shift ;;
    --bin) BIN_DIR="$2"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "install.sh: unknown option: $1" >&2; usage >&2; exit 1 ;;
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

# --- Pipe-mode guard ---------------------------------------------------------
# Under `curl | bash` stdin IS the script stream: a `read` would swallow the
# rest of the script as its "answer". Non-interactive mode is mandatory there.
if [ ! -t 0 ] && [ "$ASSUME_YES" != "1" ]; then
  echo "!! stdin is not a terminal (pipe mode), but prompts need answers." >&2
  echo "   Re-run non-interactively:" >&2
  echo "       curl -fsSL .../install.sh | bash -s -- -y" >&2
  echo "   Or download install.sh first and run it interactively." >&2
  exit 1
fi

# --- Resolve the tarball -----------------------------------------------------
# $0 may be a process substitution (/dev/fd/63) in pipe mode; fall back to pwd.
SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)" || SCRIPT_DIR="$PWD"

DOWNLOADED=""
cleanup() {
  if [ -n "$DOWNLOADED" ] && [ -f "$DOWNLOADED" ]; then
    rm -f "$DOWNLOADED"
  fi
}
trap cleanup EXIT

if [ -z "$PKG" ]; then
  PKG="$(ls -1 "$SCRIPT_DIR"/*-runtime.tar.gz 2>/dev/null | head -1 || true)"
fi

if [ -z "$PKG" ]; then
  ASSET="dsh-termux-runtime.tar.gz"
  if [ "$RELEASE" = "latest" ]; then
    URL="https://github.com/$REPO/releases/latest/download/$ASSET"
  else
    URL="https://github.com/$REPO/releases/download/$RELEASE/$ASSET"
  fi
  echo "==> No local runtime tarball found; downloading"
  echo "    $URL"
  DL_DIR="${TMPDIR:-$HOME/.cache/dsh-termux}"
  mkdir -p "$DL_DIR"
  DOWNLOADED="$(mktemp "$DL_DIR/runtime.XXXXXXXX.tar.gz")"
  if ! curl -fL --retry 3 --retry-delay 2 -o "$DOWNLOADED" "$URL"; then
    echo "!! Download failed. Check the network, or download $ASSET from" >&2
    echo "   https://github.com/$REPO/releases manually and pass it with -p." >&2
    exit 1
  fi
  PKG="$DOWNLOADED"
fi

if [ ! -f "$PKG" ]; then
  echo "!! Runtime tarball not found: $PKG" >&2
  exit 1
fi
PKG="$(cd "$(dirname "$PKG")" && pwd)/$(basename "$PKG")"

echo "==> dsh-termux runtime installer"
echo "    tarball : $PKG"
echo "    prefix  : $PREFIX"
echo "    bin dir : $BIN_DIR"

# --- Preflight ---------------------------------------------------------------
if ! command -v grun >/dev/null 2>&1; then
  echo "!! grun (Termux glibc-runner) not found. Install with:" >&2
  echo "    pkg install glibc-repo && pkg install glibc glibc-runner" >&2
  exit 1
fi

# --- Extract -----------------------------------------------------------------
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

# --- Write the wrapper -------------------------------------------------------
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

# --- Symlink into bin dir ----------------------------------------------------
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

# --- Prepend bin dir to PATH in ~/.bashrc ------------------------------------
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
echo "    Update later (no repo clone needed):"
echo "        bash $PREFIX/scripts/update-dsh.sh -t next -y"
