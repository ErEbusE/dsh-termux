#!/data/data/com.termux/files/usr/bin/bash
# update-dsh.sh — update dsh to a chosen npm version and re-apply patches.
#
# This is the maintenance counterpart to 00-setup.sh. It:
#   1. queries the npm registry for available versions (dist-tags + full list),
#   2. installs the chosen version under the glibc Node (npm install <tag>),
#   3. re-applies the two Android hard-link patches (idempotent),
#   4. rewrites the `dsh` wrapper + symlink.
#
# It does NOT manage a running web instance; start/restart web yourself with
# `dsh web` (e.g. `dsh web --port 3080`). This keeps the updater side-effect free.
#
# Usage:
#   bash scripts/update-dsh.sh                # pick a version interactively
#   bash scripts/update-dsh.sh -y             # update to latest (auto-accept)
#   bash scripts/update-dsh.sh -v 0.1.0-rc.8  # update to a specific version
#   bash scripts/update-dsh.sh -t next        # update to a dist-tag (e.g. next)
#   bash scripts/update-dsh.sh -h             # show this help
#
# Flags:
#   -y, --yes           auto-accept every prompt
#   -v, --version VER   exact version to install (overrides tag selection)
#   -t, --tag TAG       npm dist-tag to install (default: latest)
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

DSH_ASSUME_YES=0
SPEC=""
TAG=""

usage() { sed -n '3,22p' "$0" >&2; exit 0; }

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

echo "==> [update] dsh updater"
echo "    assume-yes: ${DSH_ASSUME_YES}"

# --- Query available versions ----------------------------------------------
echo "==> Querying npm registry for @deepseek-ai/dsh ..."
DIST_TAGS="$(grun "$NODE_BIN" "$NPM_CLI" view @deepseek-ai/dsh dist-tags 2>/dev/null || true)"
ALL_VERSIONS="$(grun "$NODE_BIN" "$NPM_CLI" view @deepseek-ai/dsh versions --json 2>/dev/null || true)"
CURRENT="$(grun "$NODE_BIN" --expose-internals "$WORK_DIR/node_modules/@deepseek-ai/dsh/lib/bin.js" --version 2>/dev/null | tr -d '\r' || echo unknown)"

echo "    currently installed: $CURRENT"
echo "    registry dist-tags:"
echo "      $DIST_TAGS" | sed 's/^/      /'

# --- Decide target ----------------------------------------------------------
resolve_target() {
  if [ -n "$SPEC" ]; then
    echo "@deepseek-ai/dsh@$SPEC"
    return
  fi
  local t="${TAG:-latest}"
  if [ "${DSH_ASSUME_YES:-0}" = "1" ]; then
    echo "@deepseek-ai/dsh@$t"
    return
  fi
  echo "    Select a target (Enter = $t):"
  local idx=1 choice
  local tags="$(echo "$DIST_TAGS" | tr -d '{}' | tr ',' '\n' | sed 's/^ *//;s/ *$//')"
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    local k="${line%%:*}"; local v="${line##*:}"
    echo "      [$idx] tag $k -> $v"
    idx=$((idx+1))
  done <<< "$tags"
  echo "      [0] exact version"
  printf '    Choice [1-%d, 0=version, Enter=%s]: ' "$((idx-1))" "$t"
  read -r choice
  choice="${choice:-1}"
  if [ "$choice" = "0" ]; then
    printf '    Enter exact version (e.g. 0.1.0-rc.8): '
    read -r SPEC
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
grun "$NODE_BIN" "$NPM_CLI" install "$TARGET" --ignore-scripts

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
cat > "$WRAPPER" << EOF
#!/data/data/com.termux/files/usr/bin/bash
# dsh wrapper generated by dsh-termux (glibc Node via grun).
# Accepts the same arguments as the original dsh CLI.
exec grun "$NODE_BIN" --expose-internals "$DSH_BIN" "\$@"
EOF
chmod +x "$WRAPPER"
mkdir -p "$BIN_DIR"
ln -sf "$WRAPPER" "$BIN_DIR/dsh"
echo "==> Wrapper updated: $BIN_DIR/dsh -> $WRAPPER"

NEW_VERSION="$(grun "$NODE_BIN" --expose-internals "$DSH_BIN" --version 2>/dev/null | tr -d '\r')"
echo "==> Updated to: $NEW_VERSION"

echo "==> [update] Done. dsh is now $NEW_VERSION (was $CURRENT)."
echo "    Start the web UI yourself, e.g.:  dsh web --port ${DSH_WEB_PORT:-3080}"
