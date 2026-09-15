#!/data/data/com.termux/files/usr/bin/bash
# build-runtime.sh — build a dsh-termux runtime directory on arm64 Linux.
#
# Intended to run on an arm64 (aarch64) glibc Linux host (e.g. GitHub Actions
# ubuntu-24.04-arm) to produce a self-contained runtime that can be shipped and
# installed on Termux. It:
#   1. fetches the official Node.js linux-arm64 binary into $RUNTIME_DIR/node,
#   2. npm-installs dsh (with --ignore-scripts) into $RUNTIME_DIR/work,
#   3. applies the Android patches (DSH_PATCH_SET from scripts/patch-lib.sh)
#      to the installed libs and verifies the patch markers are present,
#   4. does a boot smoke test.
#
# On the build host (arm64 glibc) node runs directly and ships in the tarball
# in its pristine state; on the Termux device install.sh points its ELF
# interpreter at Termux's glibc loader and writes the direct-exec `dsh` wrapper
# plus the $BROWSER opener, so this script does not touch any of that.
#
# Usage:
#   bash build/build-runtime.sh                        # defaults
#   DSH_NODE_VERSION=24.19.0 bash build/build-runtime.sh   # default: NODE_VERSION file
#   DSH_DSH_VERSION=@deepseek-ai/dsh@next bash build/build-runtime.sh
#
# Env:
#   DSH_RUNTIME_DIR   where the runtime is built (default ./dsh-termux-runtime)
#   DSH_NODE_VERSION  node version to fetch (default: NODE_VERSION file)
#   DSH_DSH_VERSION   dsh npm spec to install (default @deepseek-ai/dsh@latest)
#   DSH_SOURCE_TREE   build FROM SOURCE instead of npm: path to an upstream
#                     checkout that has already been built and packed (see
#                     stage_from_source below). Ignored when unset, which is
#                     what every stable release does.
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PATCHES="$BASE_DIR/patches"
source "$BASE_DIR/scripts/patch-lib.sh"

RUNTIME_DIR="${DSH_RUNTIME_DIR:-$BASE_DIR/dsh-termux-runtime}"
# Node 版本单一事实源: 仓库根 NODE_VERSION 文件 (DSH_NODE_VERSION 仍可覆盖)。
NODE_VERSION="${DSH_NODE_VERSION:-$(tr -d '[:space:]' < "$BASE_DIR/NODE_VERSION" 2>/dev/null || true)}"
[ -n "$NODE_VERSION" ] || { echo "!! NODE_VERSION file missing/empty at $BASE_DIR/NODE_VERSION" >&2; exit 1; }
DSH_VERSION="${DSH_DSH_VERSION:-@deepseek-ai/dsh@latest}"
SOURCE_TREE="${DSH_SOURCE_TREE:-}"

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
if [ -n "$SOURCE_TREE" ]; then
  echo "    dsh source  : $SOURCE_TREE (packed tarballs, not npm)"
else
  echo "    dsh version : $DSH_VERSION"
fi
echo "    arch        : $ARCH"

# --- 1. Node ----------------------------------------------------------------
fetch_node() {
  local dl="$RUNTIME_DIR/downloads"
  mkdir -p "$dl"
  echo "==> Downloading Node.js ${NODE_VERSION} (linux-arm64) ..."
  curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/${TARBALL}.tar.xz" \
    -o "$dl/${TARBALL}.tar.xz"
  rm -rf "${NODE_ROOT:?}" "${dl:?}/${TARBALL:?}"
  mkdir -p "$NODE_ROOT"
  tar -xJf "$dl/${TARBALL}.tar.xz" -C "$dl"
  mv "$dl/${TARBALL}"/* "$NODE_ROOT/"
  rm -rf "${dl:?}/${TARBALL:?}"
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

# --- 2. install dsh ---------------------------------------------------------
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"
if [ ! -f package.json ]; then
  "$NODE_BIN" "$NODE_ROOT/lib/node_modules/npm/bin/npm-cli.js" init -y >/dev/null 2>&1
fi
# npm's arborist OOMs at the ~2GB default V8 heap when resolving dsh's
# ~60-dependency tree on arm64 hosts (verified on-device); give it 4GB.
export NODE_OPTIONS="${NODE_OPTIONS:+$NODE_OPTIONS }--max-old-space-size=4096"
NPM_CLI="$NODE_ROOT/lib/node_modules/npm/bin/npm-cli.js"

# Install every first-party package from tarballs the upstream checkout packed,
# and let the registry serve everything else. This mirrors what upstream's own
# release:verify-packed-install does, and for the same reason: a source tree can
# be AHEAD of npm, so its packages' mutual version ranges may not resolve
# against the registry at all. Naming each one as a file: dependency pins the
# closure to exactly what was built.
#
# The vendored framework packs as a separate family and is declared as a peer,
# so it has to be present too. The landlock native addon is NOT built here: it
# is versioned and released independently of dsh (0.1.1 while dsh is 0.1.2-*),
# so npm resolves it like any other external dependency.
stage_from_source() {
  local tree="$1" dir count
  local -a dirs=()
  for dir in "$tree/dist/npm" "$tree/dist/npm-vendor"; do
    [ -d "$dir" ] || { echo "!! source build produced no $dir — run release:pack first" >&2; return 1; }
    dirs+=("$dir")
  done
  count="$("$NODE_BIN" -e '
    const fs = require("node:fs"), path = require("node:path");
    const dirs = process.argv.slice(1);
    const deps = {};
    for (const dir of dirs) {
      const tarballs = fs.readdirSync(dir).filter(n => n.endsWith(".tgz")).sort();
      if (tarballs.length === 0) throw new Error(dir + " holds no packed tarball");
      for (const name of tarballs) {
        // <name minus @, / -> ->-<version>.tgz; read the real name from the
        // tarball instead of parsing the filename back into a package name.
        const abs = path.resolve(dir, name);
        const { execFileSync } = require("node:child_process");
        const meta = JSON.parse(execFileSync("tar",
          ["-xzOf", abs, "package/package.json"], { encoding: "utf8" }));
        deps[meta.name] = "file:" + abs;
      }
    }
    const pkg = JSON.parse(fs.readFileSync("package.json", "utf8"));
    pkg.dependencies = { ...(pkg.dependencies || {}), ...deps };
    fs.writeFileSync("package.json", JSON.stringify(pkg, null, 2) + "\n");
    console.log(Object.keys(deps).length);
  ' "${dirs[@]}")" || return 1
  echo "    staged $count packed packages as file: dependencies"
}

if [ -n "$SOURCE_TREE" ]; then
  echo "==> Installing dsh FROM SOURCE ($SOURCE_TREE) ..."
  stage_from_source "$SOURCE_TREE" || exit 1
  "$NODE_BIN" "$NPM_CLI" install --ignore-scripts
else
  echo "==> Installing ${DSH_VERSION} (--ignore-scripts) ..."
  "$NODE_BIN" "$NPM_CLI" install "$DSH_VERSION" --ignore-scripts
fi

# --- 3. Apply patches -------------------------------------------------------
# Note: $WORK_DIR is usually *inside* a git checkout here (CI builds the runtime
# under $GITHUB_WORKSPACE), which is exactly the case plain
# `git apply --directory=...` skips while still exiting 0. dsh_apply_patch_set
# handles the prefix and verifies each file really changed.
echo "==> Applying Android patches (DSH_PATCH_SET)"
if ! dsh_apply_patch_set "$WORK_DIR" "$PATCHES"; then
  echo "!! Patches do not apply to the installed dsh version; aborting build." >&2
  echo "   Regenerate them from the npm packages — see PATCHES.md." >&2
  exit 1
fi

# --- 4. Boot smoke ----------------------------------------------------------
echo "==> Boot smoke (CLI version)"
DSH_BIN="$WORK_DIR/node_modules/@deepseek-ai/dsh/lib/bin.js"
"$NODE_BIN" --expose-internals "$DSH_BIN" --version

echo "==> [build] Done. Runtime built at $RUNTIME_DIR"
echo "    node : $NODE_ROOT"
echo "    work : $WORK_DIR"
