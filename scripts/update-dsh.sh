#!/data/data/com.termux/files/usr/bin/bash
# update-dsh.sh — update dsh to a chosen npm version and re-apply patches.
#
# This is the maintenance counterpart to 00-setup.sh. It:
#   1. queries the npm registry for available versions (dist-tags + full list),
#   2. installs the chosen version under the glibc Node (npm install <tag>),
#   3. re-applies the Android patch set (idempotent),
#   4. rewrites the `dsh` wrapper + symlink (including the Termux $BROWSER
#      handoff — see write_dsh_wrapper in common.sh).
#
# The npm update path only moves the dsh version. The PATCH SET (and this
# updater itself) evolves with project releases, not npm — so on every run the
# updater compares the runtime's bundled project VERSION with the latest
# GitHub release and, when behind, points at `--self`:
#
#   bash scripts/update-dsh.sh --self      # refresh updater + patch set from
#                                           # the latest release tarball, then
#                                           # re-run the normal update flow
#
# It does NOT manage a running web instance; start/restart web yourself with
# `dsh web` (e.g. `dsh web --port 3080`). This keeps the updater side-effect free.
#
# Usage:
#   bash scripts/update-dsh.sh                # pick a version interactively
#   bash scripts/update-dsh.sh -y             # update to latest (auto-accept)
#   bash scripts/update-dsh.sh -v 0.1.0-rc.8  # update to a specific version (no menu)
#   bash scripts/update-dsh.sh -t next        # update to a dist-tag (no menu)
#   bash scripts/update-dsh.sh --self -y      # self-update patch set, then update dsh
#   bash scripts/update-dsh.sh -h             # show this help
#
# Flags:
#   -y, --yes           auto-accept every prompt
#   -v, --version VER   exact version to install (skips the target menu)
#   -t, --tag TAG       npm dist-tag to install (skips the target menu)
#   --self              first refresh this updater + the patch set from the
#                       latest project release, then continue the update
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
REPO="${DSH_REPO:-ErEbusE/dsh-termux}"
SELF_DIR="$RUNTIME_DIR"   # where the self-update installs the fresh scripts

# Same npm-heap guard as 02-install-dsh.sh: npm's arborist OOMs at the ~2GB
# default V8 heap when resolving dsh's ~60-dependency tree on arm64.
export NODE_OPTIONS="${NODE_OPTIONS:+$NODE_OPTIONS }--max-old-space-size=4096"

DSH_ASSUME_YES=0
SPEC=""
TAG=""
SELF=0

usage() { sed -n '3,36p' "$0" >&2; exit 0; }

while [ $# -gt 0 ]; do
  case "${1,,}" in
    -y|--yes) DSH_ASSUME_YES=1 ;;
    -v|--version) SPEC="$2"; shift ;;
    -t|--tag) TAG="$2"; shift ;;
    --self) SELF=1 ;;
    -h|--help) usage ;;
    *) echo "update-dsh.sh: unknown option: $1" >&2; usage ;;
  esac
  shift
done

# --- Self-update: refresh this updater + the patch set ----------------------
# The patch set evolves with PROJECT releases (not npm): a runtime installed
# from an older release keeps its old patches forever unless refreshed. --self
# downloads the latest release tarball and replaces ONLY the updater/scripts/
# patches/VERSION parts inside the runtime, then re-execs the fresh updater so
# the patch set actually in use is the one this run applied.
latest_release_tag() {
  # Latest release tag via the releases/latest redirect (no token, no API
  # quota). The tag itself is the identity; VERSION (possibly containing
  # dashes) is read from the tarball / runtime file, never re-derived here —
  # splitting the tag on dashes is ambiguous once VERSION itself has one.
  local loc
  loc="$(curl -sIo /dev/null -w '%{redirect_url}' \
    "https://github.com/$REPO/releases/latest" 2>/dev/null || true)"
  case "${loc##*/}" in
    dsh-*) printf '%s\n' "${loc##*/}" ;;
    *) return 1 ;;
  esac
}

self_update() {
  local tag dl_dir tmp tarball
  if ! tag="$(latest_release_tag)" || [ -z "$tag" ]; then
    echo "!! --self: cannot resolve the latest release of $REPO (network?)." >&2
    echo "   Retry later, or reinstall:" >&2
    echo "     curl -fsSL https://github.com/$REPO/releases/latest/download/install.sh | bash -s -- -y" >&2
    exit 1
  fi
  echo "==> [self] fetching latest release $tag"
  dl_dir="${TMPDIR:-$HOME/.cache}/dsh-termux-self"
  mkdir -p "$dl_dir"
  tmp="$(mktemp -d "$dl_dir/self.XXXXXXXX")"
  tarball="$tmp/dsh-termux-runtime.tar.gz"
  if ! curl -fL --retry 3 --retry-delay 2 -o "$tarball" \
      "https://github.com/$REPO/releases/latest/download/dsh-termux-runtime.tar.gz"; then
    echo "!! --self: download failed. Network, or fetch the tarball manually:" >&2
    echo "   https://github.com/$REPO/releases/latest/download/dsh-termux-runtime.tar.gz" >&2
    rm -rf "$tmp"
    exit 1
  fi
  # Extract ONLY the updater machinery into the runtime; node/ and work/ stay
  # untouched (the npm flow below owns the dsh tree). VERSION inside the
  # tarball is the authoritative project version of this patch set.
  if ! tar -xzf "$tarball" -C "$tmp" scripts patches VERSION; then
    echo "!! --self: tarball lacks scripts/ patches/ VERSION — cannot self-update" >&2
    echo "   (releases before 1.2.1 did not ship VERSION; reinstall instead:)" >&2
    echo "     curl -fsSL https://github.com/$REPO/releases/latest/download/install.sh | bash -s -- -y" >&2
    rm -rf "$tmp"
    exit 1
  fi
  mkdir -p "$SELF_DIR/scripts"
  cp "$tmp/scripts/update-dsh.sh" "$tmp/scripts/common.sh" \
     "$tmp/scripts/patch-lib.sh" "$SELF_DIR/scripts/"
  rm -rf "$SELF_DIR/patches"
  cp -r "$tmp/patches" "$SELF_DIR/patches"
  cp "$tmp/VERSION" "$SELF_DIR/VERSION"
  rm -rf "$tmp"
  echo "    Updated: scripts/ patches/ VERSION -> project $(cat "$SELF_DIR/VERSION")"
  # Re-exec the FRESH updater for the rest of the run, so the patch set that
  # gets applied is the one just installed (not the pre-self copy in memory).
  # Drop --self from the argv; keep every other flag the user passed.
  local args=()
  for a in "$@"; do [ "$a" = "--self" ] || args+=("$a"); done
  exec bash "$SELF_DIR/scripts/update-dsh.sh" "${args[@]}"
}

if [ "$SELF" = "1" ]; then
  self_update "$@"
fi

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

# --- Patch-set freshness notice ----------------------------------------------
# npm moved the dsh version; the PATCH SET did not move with it. Reconstruct
# this runtime's release tag (dsh-<dsh version>-<project VERSION>, the
# canonical tag shape) and compare with the latest release tag. A mismatch
# means the release tarball carries a newer/changed patch set than the one
# this run applied — point at --self. Never fatal: the update succeeded.
patchset_notice() {
  local latest local_tag proj
  latest="$(latest_release_tag)" || return 0    # offline: informational only
  proj="$(cat "$SELF_DIR/VERSION" 2>/dev/null || true)"
  [ -n "$proj" ] || return 0                     # pre-1.2.1 runtime: unknown
  local_tag="dsh-$NEW_VERSION-$proj"
  if [ "$latest" != "$local_tag" ]; then
    echo
    echo "==> NOTE: a newer dsh-termux release exists ($latest; this runtime's patch set: $local_tag)."
    echo "    New/changed patches ship in project releases, not via npm."
    echo "    Refresh the patch set with:  dsh update --self -y"
  fi
}
patchset_notice

echo "==> [update] Done. dsh is now $NEW_VERSION (was $CURRENT)."
echo "    Start the web UI yourself, e.g.:  dsh web --port ${DSH_WEB_PORT:-3080}"
