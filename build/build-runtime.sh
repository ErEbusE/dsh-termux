#!/data/data/com.termux/files/usr/bin/bash
# build-runtime.sh — build a dsh-termux runtime directory on arm64 Linux.
#
# Intended to run on an arm64 (aarch64) glibc Linux host (e.g. GitHub Actions
# ubuntu-24.04-arm) to produce a self-contained runtime that can be shipped and
# installed on Termux via grun. It:
#   1. fetches the official Node.js linux-arm64 binary into $RUNTIME_DIR/node,
#   2. npm-installs dsh (with --ignore-scripts) into $RUNTIME_DIR/work,
#   3. applies the two Android hard-link patches to the installed libs,
#   4. verifies patch markers and does a boot smoke test.
#
# On the build host (arm64 glibc) node runs directly; the grun wrapper is added
# later by install.sh on the Termux device, so this script does not touch grun.
#
# Usage:
#   bash build/build-runtime.sh                        # defaults
#   DSH_NODE_VERSION=22.20.0 bash build/build-runtime.sh
#   DSH_DSH_VERSION=@deepseek-ai/dsh@next bash build/build-runtime.sh
#
# Env:
#   DSH_RUNTIME_DIR   where the runtime is built (default ./dsh-termux-runtime)
#   DSH_NODE_VERSION  node version to fetch (default 22.20.0)
#   DSH_DSH_VERSION   dsh npm spec to install (default @deepseek-ai/dsh@latest)
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PATCHES="$BASE_DIR/patches"

RUNTIME_DIR="${DSH_RUNTIME_DIR:-$BASE_DIR/dsh-termux-runtime}"
NODE_VERSION="${DSH_NODE_VERSION:-22.20.0}"
DSH_VERSION="${DSH_DSH_VERSION:-@deepseek-ai/dsh@latest}"

NODE_ROOT="$RUNTIME_DIR/node"
NODE_BIN="$NODE_ROOT/bin/node"
WORK_DIR="$RUNTIME_DIR/work"
TARBALL="node-v${NODE_VERSION}-linux-arm64"

ARCH="$(uname -m)"
if [ "$ARCH" != "aarch64" ] && [ "$ARCH" != "arm64" ]; then
  echo "!! build-runtime.sh must run on arm64 (got $ARCH)." >&2
  exit 1
fi

echo "==> [build] dsh-termux runtime build"
echo "    runtime dir : $RUNTIME_DIR"
echo "    node version: $NODE_VERSION"
echo "    dsh version : $DSH_VERSION"
echo "    arch        : $ARCH"

# --- 1. Node ----------------------------------------------------------------
fetch_node() {
  local dl="$RUNTIME_DIR/downloads"
  mkdir -p "$dl"
  echo "==> Downloading Node.js ${NODE_VERSION} (linux-arm64) ..."
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
  installed_ver="$("$NODE_BIN" --version 2>/dev/null || true)"
fi
if [ -n "$installed_ver" ] && [[ "$installed_ver" == *"v${NODE_VERSION}"* ]]; then
  echo "    Node.js $installed_ver already present."
else
  echo "    Node: ${installed_ver:-none} -> fetching v${NODE_VERSION}"
  fetch_node
fi
NODE_BIN="$NODE_ROOT/bin/node"

# --- 2. npm install dsh -----------------------------------------------------
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"
if [ ! -f package.json ]; then
  "$NODE_BIN" "$NODE_ROOT/lib/node_modules/npm/bin/npm-cli.js" init -y >/dev/null 2>&1
fi
echo "==> Installing ${DSH_VERSION} (--ignore-scripts) ..."
"$NODE_BIN" "$NODE_ROOT/lib/node_modules/npm/bin/npm-cli.js" install "$DSH_VERSION" --ignore-scripts

# --- 3. Apply patches -------------------------------------------------------
echo "==> Applying Android hard-link patches"
apply_patch() {
  local patch="$1" rel="$2"
  local target="$WORK_DIR/node_modules/@deepseek-ai/$rel"
  echo "==> ${patch} -> $rel"
  (cd "$WORK_DIR" && git apply --directory=node_modules/@deepseek-ai --reverse \
    "$PATCHES/${patch}" 2>/dev/null || true)
  if (cd "$WORK_DIR" \
    && git apply --directory=node_modules/@deepseek-ai --check "$PATCHES/${patch}" \
    && git apply --directory=node_modules/@deepseek-ai "$PATCHES/${patch}"); then
    echo "    OK"
  else
    echo "    !! ${patch} does not apply to installed version; aborting build." >&2
    exit 1
  fi
}
apply_patch npm-dsh-session-persistence-jsonl-link-rename.patch dsh-session-persistence-jsonl/lib/index.js
apply_patch npm-dsh-fs-local-link-rename.patch dsh-fs-local/lib/index.js

# --- 4. Verify + boot smoke -------------------------------------------------
echo "==> Verifying patch markers"
grep -q "platformLinkDenied" "$WORK_DIR/node_modules/@deepseek-ai/dsh-session-persistence-jsonl/lib/index.js" \
  && grep -q "platformLinkDenied" "$WORK_DIR/node_modules/@deepseek-ai/dsh-fs-local/lib/index.js" \
  && echo "    OK: both patches present" || { echo "    !! marker missing"; exit 1; }

echo "==> Boot smoke (CLI version)"
DSH_BIN="$WORK_DIR/node_modules/@deepseek-ai/dsh/lib/bin.js"
"$NODE_BIN" --expose-internals "$DSH_BIN" --version

echo "==> [build] Done. Runtime built at $RUNTIME_DIR"
echo "    node : $NODE_ROOT"
echo "    work : $WORK_DIR"
