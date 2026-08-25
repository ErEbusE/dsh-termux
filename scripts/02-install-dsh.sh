#!/data/data/com.termux/files/usr/bin/bash
# 02-install-dsh.sh — install dsh from npm under the glibc Node.
#
# dsh is installed from the npm registry with --ignore-scripts so koffi's
# build script never runs; linux-arm64 prebuilt native modules are resolved
# automatically by npm under glibc Node.
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$BASE_DIR/scripts/common.sh"

RUNTIME_DIR="${DSH_RUNTIME_DIR:-$HOME/.local/opt/dsh-termux-runtime}"
NODE_BIN="$RUNTIME_DIR/node/bin/node"
NPM_CLI="$RUNTIME_DIR/node/lib/node_modules/npm/bin/npm-cli.js"
WORK_DIR="${DSH_WORK_DIR:-$RUNTIME_DIR/work}"
DSH_VERSION="${DSH_VERSION:-@deepseek-ai/dsh@latest}"

# dsh ships ~60 dependencies; npm's arborist needs more than the ~2GB default
# V8 heap when resolving that tree on a fresh install (verified: it OOMs with
# "JavaScript heap out of memory" at the default on arm64). 4GB is safe on
# 8GB+ devices; keep it off everything else so only the heavy npm install
# pays for it.
export NODE_OPTIONS="${NODE_OPTIONS:+$NODE_OPTIONS }--max-old-space-size=4096"

echo "==> [02] Installing dsh"

if [ ! -x "$NODE_BIN" ]; then
  echo "!! glibc Node not found. Run: bash scripts/01-setup-glibc-node.sh" >&2
  exit 1
fi

mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

if [ ! -f package.json ]; then
  echo "==> Initializing $WORK_DIR ..."
  grun "$NODE_BIN" "$NPM_CLI" init -y >/dev/null 2>&1
fi

if [ -d node_modules/@deepseek-ai/dsh ]; then
  echo "    dsh already installed in $WORK_DIR"
  if ask_yes_no "Reinstall / update dsh (npm install $DSH_VERSION)?"; then
    echo "==> Installing $DSH_VERSION (--ignore-scripts) ..."
    grun "$NODE_BIN" "$NPM_CLI" install "$DSH_VERSION" --ignore-scripts
  else
    echo "    Keeping existing install."
  fi
else
  echo "    Will install: $DSH_VERSION"
  if ask_yes_no "Install dsh now?"; then
    echo "==> Installing $DSH_VERSION (--ignore-scripts) ..."
    grun "$NODE_BIN" "$NPM_CLI" install "$DSH_VERSION" --ignore-scripts
  else
    echo "!! dsh is required. Aborting." >&2
    exit 1
  fi
fi

echo "==> [02] Done. Next: scripts/03-apply-patches.sh"