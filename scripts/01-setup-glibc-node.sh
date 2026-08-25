#!/data/data/com.termux/files/usr/bin/bash
# 01-setup-glibc-node.sh — verify Termux, install glibc components, fetch Node.
#
# Steps:
#   1. Detect Termux ($PREFIX).
#   2. Detect glibc-repo / glibc / glibc-runner; ask to install if missing.
#   3. Re-check after install (still fail loudly if missing).
#   4. Fetch the official glibc Node.js linux-arm64 binary (shows version).
#   5. Point its ELF interpreter at Termux's glibc loader so it can be exec'd
#      directly — see configure_glibc_node in common.sh for why grun's
#      `ld.so <node>` indirection breaks dsh.
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$BASE_DIR/scripts/common.sh"

RUNTIME_DIR="${DSH_RUNTIME_DIR:-$HOME/.local/opt/dsh-termux-runtime}"
NODE_VERSION="${DSH_NODE_VERSION:-24.19.0}"
NODE_ROOT="$RUNTIME_DIR/node"
NODE_BIN="$NODE_ROOT/bin/node"
TARBALL="node-v${NODE_VERSION}-linux-arm64"

echo "==> [01] Environment check"

# --- 1. Termux detection ---------------------------------------------------
if [ -z "${PREFIX:-}" ] || [ ! -d "$PREFIX" ]; then
  echo "!! Not a Termux environment (\$PREFIX unset or missing). Aborting." >&2
  exit 1
fi
echo "    Termux detected: PREFIX=$PREFIX"

# --- 2. glibc components ---------------------------------------------------
missing=()
command -v grun >/dev/null 2>&1  || missing+=("glibc-runner")
dpkg -s glibc >/dev/null 2>&1   || missing+=("glibc")
dpkg -s glibc-repo >/dev/null 2>&1 || missing+=("glibc-repo")

if [ ${#missing[@]} -gt 0 ]; then
  echo "    Missing glibc components: ${missing[*]}"
  if ask_yes_no "Install them now (pkg install glibc-repo glibc glibc-runner)?"; then
    echo "==> Installing glibc components ..."
    pkg install -y glibc-repo glibc glibc-runner
  else
    echo "!! glibc components are required. Aborting." >&2
    exit 1
  fi
fi

# --- 3. Re-check -----------------------------------------------------------
if ! command -v grun >/dev/null 2>&1; then
  echo "!! glibc-runner (grun) still missing after install. Aborting." >&2
  exit 1
fi
echo "    glibc-runner OK: $(command -v grun)"

# --- 4. Node.js ------------------------------------------------------------
mkdir -p "$RUNTIME_DIR"
fetch_node() {
  local dl="$RUNTIME_DIR/downloads"
  mkdir -p "$dl"
  echo "==> Downloading Node.js ${NODE_VERSION} (linux-arm64, glibc) ..."
  curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/${TARBALL}.tar.xz" \
    -o "$dl/${TARBALL}.tar.xz"
  rm -rf "$NODE_ROOT" "$dl/${TARBALL}"
  mkdir -p "$NODE_ROOT"
  tar -xJf "$dl/${TARBALL}.tar.xz" -C "$dl"
  mv "$dl/${TARBALL}"/* "$NODE_ROOT/"
  rm -rf "$dl/${TARBALL}"
}

installed_ver=""
if [ -x "$NODE_BIN" ]; then
  # An already-present node may still be pristine (interpreter /lib/ld-...),
  # which the kernel cannot exec on Termux; configure it before probing.
  configure_glibc_node "$NODE_BIN" || true
  installed_ver="$(run_glibc_node "$NODE_BIN" --version 2>/dev/null || true)"
fi

if [ -n "$installed_ver" ] && [[ "$installed_ver" == *"v${NODE_VERSION}"* ]]; then
  echo "    Node.js $installed_ver already present (v${NODE_VERSION})."
else
  echo "    Current node: ${installed_ver:-none}  (target: v${NODE_VERSION})"
  if ask_yes_no "Download and install Node.js v${NODE_VERSION}?"; then
    fetch_node
  else
    echo "!! Node.js is required. Aborting." >&2
    exit 1
  fi
fi

# A freshly extracted node is pristine; configure it (idempotent otherwise).
configure_glibc_node "$NODE_BIN"

# Verify by direct exec, which is how the `dsh` wrapper runs it. execPath must
# be node itself, not the glibc loader: dsh re-spawns process.execPath for
# helpers such as the `dsh web` browser handoff.
cat > "$RUNTIME_DIR/.v.js" << 'EOF'
console.log('node', process.version, process.platform, process.arch)
console.log('execPath', process.execPath)
EOF
run_glibc_node "$NODE_BIN" "$RUNTIME_DIR/.v.js" 2>&1
rm -f "$RUNTIME_DIR/.v.js"

echo "==> [01] Done. Next: scripts/02-install-dsh.sh"