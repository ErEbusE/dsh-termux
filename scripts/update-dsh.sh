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
#                       latest project release, then continue into the dsh
#                       update (answer n at the update prompt to stop after
#                       the refresh)
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
# Original argv, kept BEFORE the parser shifts anything: self_update re-execs
# the fresh updater and must pass the user's flags (-y/-t/-v) through — by
# parse time $@ is already drained, so the parser's leftovers cannot serve.
SELF_ARGV=("$@")

usage() { sed -n '3,38p' "$0" >&2; exit 0; }

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
# from an older release keeps its old patches forever unless refreshed.
#
# Two entry paths converge here:
#   - explicit:  `dsh update --self ...` forces the refresh;
#   - automatic: every update run compares this runtime's release identity
#     with the latest GitHub release FIRST, and refreshes before touching
#     npm — so the patch set applied to the new dsh version is always the
#     newest one (the old end-of-run NOTE pointed at --self as a manual
#     second step; users who ignored it kept stale patches silently).
#
# The preferred download is the lightweight patch-set asset
# (dsh-termux-patches.tar.gz, ~40KB: the updater's own three scripts +
# patches/ + VERSION — the whole bootstrap machinery, deliberately, so any
# future updater evolution travels with it). Releases before 1.2.1 have no
# such asset: --self falls back to extracting the same members out of the
# full runtime tarball (~100MB, with a notice). node/ and work/ are never
# touched — the npm flow below owns the dsh tree.
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

runtime_release_tag() {
  # This runtime's release identity: dsh-<installed dsh version>-<project
  # VERSION>. Fails when VERSION is absent (pre-1.2.1 runtimes) — callers
  # treat that as "unknown, cannot compare" and must NOT block npm updates.
  local proj
  proj="$(cat "$SELF_DIR/VERSION" 2>/dev/null | tr -d '[:space:]')"
  [ -n "$proj" ] || return 1
  printf 'dsh-%s-%s\n' "$1" "$proj"
}

# runtime_is_current <installed_dsh_version> <latest_tag>
# Exit 0: current (nothing to do). Exit 1: genuinely behind — refresh.
# Exit 2: runtime predates VERSION (cannot compare) — continue the npm
# update with the patch set we have; auto-refresh is a best-effort
# enhancement, never a gate. (A pre-1.2.1 runtime that wants the new
# machinery reinstalls; that is documented behavior.)
runtime_is_current() {
  local local_tag
  local_tag="$(runtime_release_tag "$1")" || return 2
  [ "$2" = "$local_tag" ] || return 1
  return 0
}

# patch_set_signature <runtime_dir>
# A cheap content fingerprint of the patch machinery that lands in the INSTALLED
# dsh tree: every patch file plus the DSH_PATCH_SET declaration (which pairs
# patches with targets and markers). Equal signatures before/after a --self
# refresh mean the refresh brought nothing new for the tree; a differing one
# means new patches exist that only the dsh update step can apply — the abort
# path uses this to warn about unapplied patches. cksum keeps it dependency-free
# (same fallback patch-lib relies on); this is a change detector, not crypto.
patch_set_signature() {
  local dir="$1"
  {
    cat "$dir"/patches/*.patch 2>/dev/null
    sed -n '/^DSH_PATCH_SET=(/,/^)/p' "$dir/scripts/patch-lib.sh" 2>/dev/null
  } | cksum
}

self_update() {
  # $1 is an optional human-readable reason; default it — the flag parser
  # shifts --self away, and a bare `dsh update --self` leaves $@ empty,
  # which under set -u must not crash the function (found by R5: the
  # parser consumes -t/-y too, so even `--self -t latest -y` arrives here
  # with an empty argv).
  local tag dl_dir tmp pkg why="${1:-explicit request}"
  local old_proj old_sig new_proj
  if ! tag="$(latest_release_tag)" || [ -z "$tag" ]; then
    echo "!! --self: cannot resolve the latest release of $REPO (network?)." >&2
    echo "   Retry later, or reinstall:" >&2
    echo "     curl -fsSL https://github.com/$REPO/releases/latest/download/install.sh | bash -s -- -y" >&2
    exit 1
  fi
  dl_dir="${TMPDIR:-$HOME/.cache}/dsh-termux-self"
  mkdir -p "$dl_dir"
  tmp="$(mktemp -d "$dl_dir/self.XXXXXXXX")"

  # Capture the CURRENT runtime's project VERSION and patch-set signature
  # BEFORE anything is replaced: the run reports "old -> new" (previously only
  # the target was shown), and the signature comparison decides whether the
  # refresh actually brought new patches (drives the abort-time warning).
  old_proj="$(tr -d '[:space:]' < "$SELF_DIR/VERSION" 2>/dev/null || true)"
  [ -n "$old_proj" ] || old_proj="unknown (pre-1.2.1 runtime)"
  old_sig="$(patch_set_signature "$SELF_DIR")"

  # Preferred: the ~40KB patch-set asset (updater scripts + patches + VERSION).
  # Fallback: extract the same members from the full runtime tarball — the
  # only option on releases that predate the separate asset.
  pkg="$tmp/dsh-termux-patches.tar.gz"
  if curl -fsSL --retry 2 --retry-delay 2 -o "$pkg" \
      "https://github.com/$REPO/releases/latest/download/dsh-termux-patches.tar.gz" 2>/dev/null \
      && tar -xzf "$pkg" -C "$tmp" scripts patches VERSION 2>/dev/null; then
    echo "==> [self] $why: fetching patch-set asset for $tag (~40KB)"
  else
    echo "==> [self] $why: latest release $tag has no patch-set asset;"
    echo "    falling back to the full runtime tarball (~100MB) — consider"
    echo "    upgrading to a newer release for the lightweight channel."
    pkg="$tmp/dsh-termux-runtime.tar.gz"
    if ! curl -fL --retry 3 --retry-delay 2 -o "$pkg" \
        "https://github.com/$REPO/releases/latest/download/dsh-termux-runtime.tar.gz"; then
      echo "!! --self: download failed. Network, or fetch the tarball manually:" >&2
      echo "   https://github.com/$REPO/releases/latest/download/dsh-termux-runtime.tar.gz" >&2
      rm -rf "$tmp"
      exit 1
    fi
    if ! tar -xzf "$pkg" -C "$tmp" scripts patches VERSION; then
      echo "!! --self: tarball lacks scripts/ patches/ VERSION — cannot self-update" >&2
      echo "   (releases before 1.2.1 did not ship VERSION; reinstall instead:)" >&2
      echo "     curl -fsSL https://github.com/$REPO/releases/latest/download/install.sh | bash -s -- -y" >&2
      rm -rf "$tmp"
      exit 1
    fi
  fi

  mkdir -p "$SELF_DIR/scripts"
  cp "$tmp/scripts/update-dsh.sh" "$tmp/scripts/common.sh" \
     "$tmp/scripts/patch-lib.sh" "$SELF_DIR/scripts/"
  rm -rf "$SELF_DIR/patches"
  cp -r "$tmp/patches" "$SELF_DIR/patches"
  cp "$tmp/VERSION" "$SELF_DIR/VERSION"
  rm -rf "$tmp"
  new_proj="$(tr -d '[:space:]' < "$SELF_DIR/VERSION")"
  if [ "$new_proj" = "$old_proj" ]; then
    echo "==> [self] project VERSION: $old_proj (already current — forced refresh)"
  else
    echo "==> [self] project VERSION: $old_proj -> $new_proj"
  fi
  echo "    Updated: scripts/ + patches/ + VERSION in $SELF_DIR (project $new_proj)"
  # Sentinels for the re-exec'd updater (the environment survives exec):
  #   DSH_SELF_RAN        — this run refreshed the machinery, so the fresh
  #                         updater announces the continuation into the dsh
  #                         update explicitly instead of sliding into it;
  #   DSH_PATCHES_CHANGED — the patch set actually differs from the one the
  #                         runtime had, so DECLINING the dsh update must warn
  #                         that the new patches are not applied yet.
  export DSH_SELF_RAN=1
  if [ "$old_sig" != "$(patch_set_signature "$SELF_DIR")" ]; then
    export DSH_PATCHES_CHANGED=1
  fi
  # Re-exec the FRESH updater for the rest of the run, so the patch set that
  # gets applied is the one just installed (not the pre-self copy in memory).
  # argv comes from SELF_ARGV (captured before the parser drained $@): the
  # user's -y/-t/-v must survive the re-exec. Only --self itself is dropped.
  local args=()
  for a in "${SELF_ARGV[@]}"; do [ "$a" = "--self" ] || args+=("$a"); done
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
echo "    project VERSION: $(tr -d '[:space:]' < "$SELF_DIR/VERSION" 2>/dev/null || echo unknown)"

# --- Query available versions ----------------------------------------------
echo "==> Querying npm registry for @deepseek-ai/dsh ..."
DIST_TAGS="$(run_glibc_node "$NODE_BIN" "$NPM_CLI" view @deepseek-ai/dsh dist-tags 2>/dev/null || true)"
CURRENT="$(run_glibc_node "$NODE_BIN" --expose-internals "$WORK_DIR/node_modules/@deepseek-ai/dsh/lib/bin.js" --version 2>/dev/null | tr -d '\r' || echo unknown)"

echo "    currently installed: $CURRENT"
echo "    registry dist-tags:"
echo "      $DIST_TAGS" | sed 's/^/      /'

# --- Automatic patch-set refresh ---------------------------------------------
# The patch set that will re-apply after the npm install must be the NEWEST
# one, so compare this runtime's release identity with the latest release
# BEFORE touching npm. Behind (or pre-1.2.1, VERSION unknown) → refresh now
# and re-exec; current → continue; offline → continue with what we have
# (never fatal: the user asked for an npm update, not a project update).
# DSH_SELF_DONE guards the re-exec: after self_update the runtime's VERSION
# is new but the INSTALLED dsh version is still the old one, so the tag
# comparison would mismatch again and loop forever. The fresh updater's npm
# flow applies the fresh patch set; a second refresh is never wanted.
if [ "${DSH_SELF_DONE:-0}" != "1" ]; then
  if LATEST_TAG_AUTO="$(latest_release_tag)" && [ -n "${LATEST_TAG_AUTO:-}" ]; then
    # Show both release identities before judging: the local one embeds the
    # project VERSION the user could otherwise never see on a normal run.
    local_tag_disp="$(runtime_release_tag "$CURRENT" 2>/dev/null || true)"
    echo "    patch-set freshness (project release identity):"
    echo "      runtime: ${local_tag_disp:-none (pre-1.2.1 runtime, no VERSION)}"
    echo "      latest:  $LATEST_TAG_AUTO"
    # `rc=... || rc=$?` (not `func; rc=$?`): under set -e the bare function
    # call returning non-zero would terminate before $? is captured.
    rc=0; runtime_is_current "$CURRENT" "$LATEST_TAG_AUTO" || rc=$?
    if [ "$rc" = "1" ]; then
      DSH_SELF_DONE=1 self_update "patch set behind latest release" "$@"
    elif [ "$rc" = "2" ]; then
      echo "    (runtime predates VERSION tracking; npm-update continues with"
      echo "     the current patch set — reinstall to gain self-update)"
    fi
  else
    echo "    (cannot reach GitHub to check for project updates; continuing)"
  fi
fi

# Arriving from a --self refresh (the sentinel survives the re-exec's exec):
# say so explicitly. --self is documented to continue into the dsh update (that
# step is where the fresh patch set gets applied), but the continuation should
# be visible, not something the run slides into — and the prompt below is the
# place to stop for anyone who only wanted the refresh.
if [ "${DSH_SELF_RAN:-0}" = "1" ]; then
  echo "==> [self] updater + patch set refreshed; continuing into the dsh update"
  if [ "${DSH_ASSUME_YES:-0}" != "1" ]; then
    echo "    (only wanted the refresh? answer 'n' at the 'Update dsh to ...?' prompt)"
  fi
fi

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
  echo "Aborted."
  # A --self run may have already swapped in a NEW patch set; declining here
  # means it was never applied to the installed dsh (only the npm update step
  # applies patches). Warn, but only when the refresh really changed something
  # — a same-content forced refresh leaves nothing pending.
  if [ "${DSH_PATCHES_CHANGED:-0}" = "1" ]; then
    echo "==> [self] NOTE: the refreshed patch set is NOT applied to the installed"
    echo "    dsh yet — patches are applied by the dsh update step. Run 'dsh"
    echo "    update' when ready to apply them."
  fi
  exit 1
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
