#!/data/data/com.termux/files/usr/bin/bash
# update-dsh.sh — update dsh to a chosen npm version and re-apply patches.
#
# This is the maintenance counterpart to 00-setup.sh. It:
#   1. queries the npm registry for available versions (dist-tags + full list),
#   2. installs the chosen version under the glibc Node (npm install <tag>),
#   3. re-applies the two Android hard-link patches (idempotent),
#   4. rewrites the `dsh` wrapper + symlink (including the Termux $BROWSER
#      handoff — see write_dsh_wrapper in common.sh).
#
# It does NOT manage a running web instance; start/restart web yourself with
# `dsh web` (e.g. `dsh web --port 3080`). This keeps the updater side-effect free.
#
# Usage:
#   bash scripts/update-dsh.sh                # pick a version interactively
#   bash scripts/update-dsh.sh -y             # update to latest (auto-accept)
#   bash scripts/update-dsh.sh -v 0.1.0-rc.8  # update to a specific version (no menu)
#   bash scripts/update-dsh.sh -t next        # update to a dist-tag (no menu)
#   bash scripts/update-dsh.sh -h             # show this help
#
# Flags:
#   -y, --yes           auto-accept every prompt
#   -v, --version VER   exact version to install (skips the target menu)
#   -t, --tag TAG       npm dist-tag to install (skips the target menu)
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$BASE_DIR/scripts/common.sh"
source "$BASE_DIR/scripts/patch-lib.sh"

RUNTIME_DIR="${DSH_RUNTIME_DIR:-$HOME/.local/opt/dsh-termux-runtime}"
NODE_BIN="$RUNTIME_DIR/node/bin/node"
NPM_CLI="$RUNTIME_DIR/node/lib/node_modules/npm/bin/npm-cli.js"
WORK_DIR="${DSH_WORK_DIR:-$RUNTIME_DIR/work}"
PATCHES="$BASE_DIR/patches"
BIN_DIR="${DSH_BIN_DIR:-$HOME/.local/bin}"

# Same npm-heap guard as 02-install-dsh.sh: npm's arborist OOMs at the ~2GB
# default V8 heap when resolving dsh's ~60-dependency tree on arm64.
export NODE_OPTIONS="${NODE_OPTIONS:+$NODE_OPTIONS }--max-old-space-size=4096"

DSH_ASSUME_YES=0
SPEC=""
TAG=""

usage() { sed -n '3,24p' "$0" >&2; exit 0; }

while [ $# -gt 0 ]; do
  case "${1,,}" in
    -y|--yes) DSH_ASSUME_YES=1 ;;
    -v|--version) SPEC="$2"; shift ;;
    -t|--tag) TAG="$2"; shift ;;
    -h|--help) usage ;;
    *) echo "update-dsh.sh: unknown option: $1" >&2; usage ;;
  esac
  shift
done

# --- Preflight --------------------------------------------------------------
if [ ! -x "$NODE_BIN" ]; then
  echo "!! glibc Node not found. Run: bash scripts/00-setup.sh" >&2
  exit 1
fi
if [ ! -d "$WORK_DIR/node_modules/@deepseek-ai/dsh" ]; then
  echo "!! dsh not installed yet. Run: bash scripts/00-setup.sh" >&2
  exit 1
fi

# An install made before the direct-exec change still has a pristine node.
configure_glibc_node "$NODE_BIN"

echo "==> [update] dsh updater"
echo "    assume-yes: ${DSH_ASSUME_YES}"

# --- Query available versions ----------------------------------------------
echo "==> Querying npm registry for @deepseek-ai/dsh ..."
DIST_TAGS="$(run_glibc_node "$NODE_BIN" "$NPM_CLI" view @deepseek-ai/dsh dist-tags 2>/dev/null || true)"
ALL_VERSIONS="$(run_glibc_node "$NODE_BIN" "$NPM_CLI" view @deepseek-ai/dsh versions --json 2>/dev/null || true)"
CURRENT="$(run_glibc_node "$NODE_BIN" --expose-internals "$WORK_DIR/node_modules/@deepseek-ai/dsh/lib/bin.js" --version 2>/dev/null | tr -d '\r' || echo unknown)"

echo "    currently installed: $CURRENT"
echo "    registry dist-tags:"
echo "      $DIST_TAGS" | sed 's/^/      /'

# --- Decide target ----------------------------------------------------------
# IMPORTANT: resolve_target's stdout IS the result (TARGET="$(resolve_target)").
# All menu/prompt output must therefore go to stderr (>&2), and `read` must
# use `-p` (which also prints to stderr). Echoing prompts to stdout here would
# capture the whole menu INTO $TARGET and hand it to npm as a package spec —
# that is exactly the "Invalid tag name "=" of package "="" crash.
resolve_target() {
  if [ -n "$SPEC" ]; then
    echo "@deepseek-ai/dsh@$SPEC"
    return
  fi
  # -t picks a dist-tag directly (no menu), like -v picks a version.
  if [ -n "$TAG" ]; then
    echo "@deepseek-ai/dsh@$TAG"
    return
  fi
  local t="latest"
  if [ "${DSH_ASSUME_YES:-0}" = "1" ]; then
    echo "@deepseek-ai/dsh@$t"
    return
  fi
  echo "    Select a target (Enter = $t):" >&2
  local idx=1 choice
  local tags="$(echo "$DIST_TAGS" | tr -d '{}' | tr ',' '\n' | sed 's/^ *//;s/ *$//')"
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    local k="${line%%:*}"; local v="${line##*:}"
    echo "      [$idx] tag $k -> $v" >&2
    idx=$((idx+1))
  done <<< "$tags"
  echo "      [0] exact version" >&2
  read -r -p "    Choice [1-$((idx-1)), 0=version, Enter=$t]: " choice
  choice="${choice:-1}"
  if [ "$choice" = "0" ]; then
    read -r -p "    Enter exact version (e.g. 0.1.0-rc.8): " SPEC
    echo "@deepseek-ai/dsh@$SPEC"
    return
  fi
  local n=0
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    n=$((n+1))
    if [ "$n" = "$choice" ]; then
      local k="${line%%:*}"
      echo "@deepseek-ai/dsh@$k"
      return
    fi
  done <<< "$tags"
  echo "@deepseek-ai/dsh@$t"
}

TARGET="$(resolve_target)"
echo "==> Target: $TARGET"

# --- Install ----------------------------------------------------------------
cd "$WORK_DIR"
echo "==> Installing $TARGET (--ignore-scripts) ..."
if ! ask_yes_no "Update dsh to $TARGET?"; then
  echo "Aborted."; exit 1
fi
run_glibc_node "$NODE_BIN" "$NPM_CLI" install "$TARGET" --ignore-scripts

# --- Re-apply patches (verify against the freshly installed libs) -----------
# npm incremental installs may reuse the previously patched cache, so we cannot
# trust a leftover marker. dsh_apply_patch_set therefore reverse-applies any
# existing patch (restoring the pristine npm file), then forward-applies and
# verifies. If that fails, the patch does not match the installed version and
# must be regenerated (see PATCHES.md).
echo "==> [update] Re-applying Android hard-link patches"
if ! dsh_apply_patch_set "$WORK_DIR" "$PATCHES"; then
  echo "!! Patches do not apply to $TARGET." >&2
  echo "   dsh is installed but session saves and the write tool will fail on" >&2
  echo "   Android until the patches are regenerated — see PATCHES.md." >&2
  exit 1
fi

# --- Rewrite wrapper + symlink ----------------------------------------------
DSH_BIN="$WORK_DIR/node_modules/@deepseek-ai/dsh/lib/bin.js"
WRAPPER="$WORK_DIR/dsh"
# Re-bake the `dsh update` shortcut with the same resolution as 04-run-web.sh:
# runtime-bundled updater first, repo checkout as fallback.
UPDATER="$RUNTIME_DIR/scripts/update-dsh.sh"
[ -f "$UPDATER" ] || UPDATER="$BASE_DIR/scripts/update-dsh.sh"
write_dsh_wrapper "$WRAPPER" "$NODE_BIN" "$DSH_BIN" "$UPDATER"
mkdir -p "$BIN_DIR"
ln -sf "$WRAPPER" "$BIN_DIR/dsh"
echo "==> Wrapper updated: $BIN_DIR/dsh -> $WRAPPER"

NEW_VERSION="$(run_glibc_node "$NODE_BIN" --expose-internals "$DSH_BIN" --version 2>/dev/null | tr -d '\r')"
echo "==> Updated to: $NEW_VERSION"

echo "==> [update] Done. dsh is now $NEW_VERSION (was $CURRENT)."
echo "    Start the web UI yourself, e.g.:  dsh web --port ${DSH_WEB_PORT:-3080}"
