#!/data/data/com.termux/files/usr/bin/bash
# install.sh — unpack a dsh-termux runtime tarball and wire up the `dsh` command.
#
# Runs ON THE TARGET DEVICE (Termux, arm64). It:
#   1. locates the runtime tarball: -p FILE, a *-runtime.tar.gz next to this
#      script, or an automatic download from this project's GitHub releases
#      (DSH_RELEASE=<tag|latest>, default: latest),
#   2. wipes any previous runtime under $DSH_RUNTIME_DIR (member-wise — tar
#      alone never deletes files, and a stale tree left behind crashes the
#      bundled npm), then extracts node/ + work/ + install.sh + scripts/ +
#      patches/ into $DSH_RUNTIME_DIR (default $HOME/.local/opt/dsh-termux-runtime),
#   3. sources the shared helpers from the tarball (scripts/common.sh — the
#      same file update-dsh.sh runs on-device) and uses their
#      configure_glibc_node / write_dsh_wrapper to point Node's ELF
#      interpreter at Termux's glibc loader and emit the `dsh` wrapper plus
#      the Termux `$BROWSER` opener (`dsh-termux-open`),
#   4. symlinks it to $DSH_BIN_DIR/dsh (default $HOME/.local/bin),
#   5. prepends $DSH_BIN_DIR to PATH in ~/.bashrc (tagged # dsh-termux).
#
# Self-contained: needs nothing from the dsh-termux repo checkout beyond what
# the tarball itself carries. One-liner:
#   curl -fsSL https://github.com/ErEbusE/dsh-termux/releases/latest/download/install.sh | bash -s -- -y
# Pipe mode REQUIRES -y: stdin carries the script itself, so prompts would eat
# the remaining script bytes instead of an answer.
set -euo pipefail

REPO="${DSH_REPO:-ErEbusE/dsh-termux}"
RELEASE="${DSH_RELEASE:-latest}"
DSH_ASSUME_YES=0
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
    -y|--yes) DSH_ASSUME_YES=1 ;;
    -p|--package) PKG="$2"; shift ;;
    --prefix) PREFIX="$2"; shift ;;
    --bin) BIN_DIR="$2"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "install.sh: unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
  shift
done

# --- Pipe-mode guard ---------------------------------------------------------
# Under `curl | bash` stdin IS the script stream: a `read` would swallow the
# rest of the script as its "answer". Non-interactive mode is mandatory there.
if [ ! -t 0 ] && [ "$DSH_ASSUME_YES" != "1" ]; then
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
# Pull the shared helpers out of the tarball FIRST: install.sh sources
# scripts/common.sh (the same file update-dsh.sh runs on-device) instead of
# carrying private copies of the prompt / configure / wrapper logic.
mkdir -p "$PREFIX"
tar -xzf "$PKG" -C "$PREFIX" scripts/common.sh
# shellcheck source=../scripts/common.sh
source "$PREFIX/scripts/common.sh"

if ! ask_yes_no "Install dsh-termux runtime into $PREFIX?"; then
  rm -rf "$PREFIX/scripts"   # remove the pre-extracted common.sh (this dir is ours)
  rmdir "$PREFIX" 2>/dev/null || true
  echo "Aborted."; exit 1
fi
echo "==> Extracting runtime into $PREFIX ..."

# tar only overwrites and adds files — it never deletes. Unpacking over a
# previous runtime would keep its stale tree (real case: an old npm's nested
# minipass@3 shadowed the new npm's minipass@7 and crashed every npm command
# with "Class extends value undefined"). Wipe every top-level member this
# tarball owns BEFORE extracting — the member list comes from the archive
# itself, so members added later are covered automatically; anything the
# tarball does not own stays untouched.
echo "    clearing any previous runtime (re-extracting over one leaves stale files)"
tar -tzf "$PKG" | sed 's|^\./||' | cut -d/ -f1 | sort -u \
  | while read -r member; do
      case "$member" in
        ""|"."|".."|/*|../*|*/../*) continue ;;  # never rm anything path-weird
      esac
      rm -rf "${PREFIX:?}/$member"
    done

tar -xzf "$PKG" -C "$PREFIX"
NODE_BIN="$PREFIX/node/bin/node"
WORK_DIR="$PREFIX/work"
DSH_BIN="$WORK_DIR/node_modules/@deepseek-ai/dsh/lib/bin.js"

# Record the project version of this runtime. The bundled updater compares it
# with the latest GitHub release to warn when the PATCH SET is outdated (new
# patches ship in new project releases, not via npm). Newer tarballs carry a
# VERSION file at the root; for older ones (1.2.0 and before) fall back to
# deriving it from the release tag when it is known.
if [ ! -f "$PREFIX/VERSION" ]; then
  case "${RELEASE:-unknown}" in
    dsh-*-*) printf '%s\n' "${RELEASE##*-}" > "$PREFIX/VERSION" ;;
  esac
fi

if [ ! -x "$NODE_BIN" ]; then
  echo "!! node not found in tarball ($NODE_BIN). Corrupt package?" >&2
  exit 1
fi
if [ ! -f "$DSH_BIN" ]; then
  echo "!! dsh not found in tarball ($DSH_BIN). Corrupt package?" >&2
  exit 1
fi

# --- Configure Node for direct exec -----------------------------------------
# configure_glibc_node (sourced from scripts/common.sh) points Node's ELF
# interpreter at Termux's glibc loader so the kernel can exec node directly.
# The tarball ships the pristine official Node, whose interpreter is
# /lib/ld-linux-aarch64.so.1 — a path Android does not have. Without this,
# grun's `ld.so <node>` makes process.execPath the loader and breaks dsh's
# re-spawned helpers (the `dsh web` handoff most visibly); see common.sh for
# the --set-rpath segfault trap and the copy->patch->verify->rename discipline.
configure_glibc_node "$NODE_BIN"

# --- Write the $BROWSER opener + wrapper ------------------------------------
# write_dsh_wrapper (sourced from scripts/common.sh) emits the opener beside
# the wrapper and points $BROWSER at it. Generated by install/update on-device.
WRAPPER="$WORK_DIR/dsh"
# The tarball bundles the updater at $PREFIX/scripts/update-dsh.sh (release CI
# asserts the tarball listing), so bake the `dsh update` shortcut into it.
write_dsh_wrapper "$WRAPPER" "$NODE_BIN" "$DSH_BIN" "$PREFIX/scripts/update-dsh.sh"
echo "    Opener written : $WORK_DIR/dsh-termux-open"
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
