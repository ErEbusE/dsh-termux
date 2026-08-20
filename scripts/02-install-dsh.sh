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

echo "==> [02] Installing dsh"

if [ ! -x "$NODE_BIN" ]; then
  echo "!! glibc Node not found. Run: bash scripts/01-setup-glibc-node.sh" >&2
  exit 1
fi

# Idempotent: 01 normally did this, but this script is runnable on its own.
configure_glibc_node "$NODE_BIN"

mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

if [ ! -f package.json ]; then
  echo "==> Initializing $WORK_DIR ..."
  run_glibc_node "$NODE_BIN" "$NPM_CLI" init -y >/dev/null 2>&1
fi

if [ -d node_modules/@deepseek-ai/dsh ]; then
  echo "    dsh already installed in $WORK_DIR"
  if ask_yes_no "Reinstall / update dsh (npm install $DSH_VERSION)?"; then
    echo "==> Installing $DSH_VERSION (--ignore-scripts) ..."
    run_glibc_node "$NODE_BIN" "$NPM_CLI" install "$DSH_VERSION" --ignore-scripts
  else
    echo "    Keeping existing install."
  fi
else
  echo "    Will install: $DSH_VERSION"
  if ask_yes_no "Install dsh now?"; then
    echo "==> Installing $DSH_VERSION (--ignore-scripts) ..."
    run_glibc_node "$NODE_BIN" "$NPM_CLI" install "$DSH_VERSION" --ignore-scripts
  else
    echo "!! dsh is required. Aborting." >&2
    exit 1
  fi
fi

echo "==> [02] Done. Next: scripts/03-apply-patches.sh"