#!/data/data/com.termux/files/usr/bin/bash
# update-dsh.sh — update dsh to a chosen npm version and re-apply patches.
# help-begin
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
# GitHub release and, when behind, refreshes the machinery before touching npm.
#
# `--self` is the patches-only path: it refreshes this updater + the patch set
# from the latest release and APPLIES the refreshed set to the installed dsh
# directly — no npm download, no npm install. `--patch-set` takes the same set
# from a local directory or tarball (offline; development and testing).
#
# It does NOT manage a running web instance; start/restart web yourself with
# `dsh web` (e.g. `dsh web --port 3080`). This keeps the updater side-effect free.
#
# Usage:
#   bash scripts/update-dsh.sh                # pick a version interactively
#   bash scripts/update-dsh.sh -y             # update to latest (auto-accept)
#   bash scripts/update-dsh.sh -v 0.1.0-rc.8  # update to a specific version (no menu)
#   bash scripts/update-dsh.sh -t next        # update to a dist-tag (no menu)
#   bash scripts/update-dsh.sh --self         # refresh updater + patch set from the
#                                             # latest release, then apply it to the
#                                             # installed dsh (no npm update)
#   bash scripts/update-dsh.sh --patch-set <dir|tar.gz>
#                                             # same, with the patch set taken from a
#                                             # local directory or tarball (offline)
#   bash scripts/update-dsh.sh --self --force # re-apply even when already current
#   bash scripts/update-dsh.sh -h             # show this help
#
# Flags:
#   -y, --yes           auto-accept every prompt
#   -v, --version VER   exact version to install (skips the target menu)
#   -t, --tag TAG       npm dist-tag to install (skips the target menu)
#   --self              refresh this updater + patch set from the latest project
#                       release, then apply the patch set to the installed dsh.
#                       This does NOT run the npm update — use plain `dsh update`
#                       for that (-t/-v are ignored here).
#   --patch-set PATH    take the patch set from PATH (a directory or .tar.gz with
#                       scripts/ + patches/ + VERSION) instead of downloading it
#                       from GitHub. Implies --self and works offline.
#   --force             with --self/--patch-set: re-apply even when the machinery
#                       content is already current.
#   -h, --help          show this help
# help-end
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
PATCH_SET=""
FORCE=0
# Original argv, kept BEFORE the parser shifts anything: self_update re-execs
# the fresh updater and must pass the user's flags (-y/-t/-v) through — by
# parse time $@ is already drained, so the parser's leftovers cannot serve.
SELF_ARGV=("$@")

# The help text is the block between the '# help-begin' / '# help-end' markers
# in the header above — derived, never a hardcoded line range. The old form
# (sed -n '3,38p') silently truncated or shifted the help the moment anyone
# added a line near the top; CI now asserts that what this prints and what the
# markers delimit are the same text.
usage() { sed -n '/^# help-begin/,/^# help-end/{//!p;}' "$0" >&2; exit 0; }

while [ $# -gt 0 ]; do
  case "${1,,}" in
    -y|--yes) DSH_ASSUME_YES=1 ;;
    -v|--version) SPEC="$2"; shift ;;
    -t|--tag) TAG="$2"; shift ;;
    --self) SELF=1 ;;
    --patch-set)
      [ $# -ge 2 ] || { echo "update-dsh.sh: --patch-set needs a path" >&2; usage; }
      PATCH_SET="$2"; shift ;;
    --force) FORCE=1 ;;
    -h|--help) usage ;;
    *) echo "update-dsh.sh: unknown option: $1" >&2; usage ;;
  esac
  shift
done

# --patch-set is the same operation as --self, only with a local source.
[ -z "$PATCH_SET" ] || SELF=1
if [ "$FORCE" = 1 ] && [ "$SELF" != 1 ]; then
  echo "update-dsh.sh: note: --force only applies to --self/--patch-set; ignoring it." >&2
  FORCE=0
fi

# --- Self-update: refresh this updater + the patch set ----------------------
# The patch set evolves with PROJECT releases (not npm): a runtime installed
# from an older release keeps its old patches forever unless refreshed.
#
# Two entry paths converge here:
#   - explicit:  `dsh update --self [--patch-set <src>]` refreshes the machinery
#     and then APPLIES the refreshed patch set to the installed dsh itself — no
#     npm install involved (that step only ever moved the dsh version);
#   - automatic: every plain update run compares this runtime's release identity
#     with the latest GitHub release FIRST, and refreshes before touching npm —
#     so the patch set applied to the new dsh version is always the newest one.
#
# The refresh source is the lightweight patch-set asset
# (dsh-termux-patches.tar.gz, ~40KB: the updater's own three scripts +
# patches/ + VERSION — the whole bootstrap machinery, deliberately, so any
# future updater evolution travels with it), the same members extracted from
# the full runtime tarball (releases before 1.2.1 ship no such asset), or a
# local directory / tarball given with --patch-set (offline; for development
# and testing — build one with build/build-patchset.sh). node/ and work/ are
# never touched by the refresh: the npm flow below owns the dsh tree.
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

# machinery_signature <dir>
# Content fingerprint of the self-update machinery: VERSION + the updater's
# three scripts + every patch file. Equal signatures before/after a refresh
# mean the set brought nothing new, so --self reports "already current"
# (--force overrides) and the automatic refresh can continue in-process
# without a pointless re-exec. cksum keeps it dependency-free (same fallback
# patch-lib relies on); this is a change detector, not crypto.
machinery_signature() {
  local dir="$1"
  {
    cat "$dir/VERSION" 2>/dev/null
    cat "$dir/scripts/update-dsh.sh" "$dir/scripts/common.sh" \
      "$dir/scripts/patch-lib.sh" 2>/dev/null
    cat "$dir"/patches/*.patch 2>/dev/null
  } | cksum
}

# patch_set_validate <dir>
# Assert <dir> holds the patch-set layout every consumer expects —
# scripts/{update-dsh,common,patch-lib}.sh + patches/*.patch + VERSION — and
# that its registry names only patch files present. Extra files are allowed (a
# repo checkout is a valid --patch-set source); an unregistered patch file is
# a note, not a failure.
patch_set_validate() {
  local dir="$1" f missing=0
  for f in scripts/update-dsh.sh scripts/common.sh scripts/patch-lib.sh VERSION; do
    [ -f "$dir/$f" ] || { echo "!! patch set is missing $f: $dir" >&2; missing=1; }
  done
  if [ ! -d "$dir/patches" ] || ! compgen -G "$dir/patches/*.patch" >/dev/null; then
    echo "!! patch set has no patches/*.patch: $dir" >&2
    missing=1
  fi
  [ "$missing" = 0 ] || return 1

  # The set's own patch-lib.sh is the registry authority (the same file the
  # apply step will load), so source it in a subshell.
  local entries entry patch p base hit e
  if ! entries="$(bash -c 'source "$1"; printf "%s\n" "${DSH_PATCH_SET[@]}"' _ "$dir/scripts/patch-lib.sh" 2>/dev/null)"; then
    echo "!! patch set patch-lib.sh could not be sourced: $dir/scripts/patch-lib.sh" >&2
    return 1
  fi
  [ -n "$entries" ] || { echo "!! patch set declares no DSH_PATCH_SET entries: $dir" >&2; return 1; }
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    patch="${entry%%:*}"
    [ -f "$dir/patches/$patch" ] || {
      echo "!! patch set registry names a missing patch file: $patch" >&2
      missing=1
    }
  done <<< "$entries"
  for p in "$dir"/patches/*.patch; do
    [ -f "$p" ] || continue
    base="$(basename "$p")"; hit=0
    while IFS= read -r e; do
      [ "${e%%:*}" = "$base" ] && { hit=1; break; }
    done <<< "$entries"
    [ "$hit" = 1 ] || echo "    note: patch file not in DSH_PATCH_SET (ignored): $base"
  done
  [ "$missing" = 0 ]
}

# stage_patch_set <source> <dest>
# Materialize <source> (directory or .tar.gz) into <dest>. Validation is the
# caller's step (patch_set_validate), so the local and the download paths run
# exactly the same checks.
stage_patch_set() {
  local src="$1" dest="$2"
  if [ -d "$src" ]; then
    mkdir -p "$dest"
    cp -r "$src/scripts" "$src/patches" "$dest/" 2>/dev/null || true
    cp "$src/VERSION" "$dest/" 2>/dev/null || true
  elif [ -f "$src" ]; then
    mkdir -p "$dest"
    if ! tar -xzf "$src" -C "$dest" scripts patches VERSION 2>/dev/null; then
      echo "!! --patch-set: $src is not a patch-set tarball" >&2
      echo "   (want scripts/{update-dsh,common,patch-lib}.sh + patches/ + VERSION)" >&2
      return 1
    fi
  else
    echo "!! --patch-set: no such file or directory: $src" >&2
    return 1
  fi
}

# fetch_release_patch_set <tag> <dest> <work_dir>
# Download the patch-set asset for <tag> into <dest>; releases without the
# asset fall back to the same members inside the full runtime tarball.
fetch_release_patch_set() {
  local tag="$1" dest="$2" work="$3"
  local pkg="$work/dsh-termux-patches.tar.gz"
  mkdir -p "$dest"
  if curl -fsSL --retry 2 --retry-delay 2 -o "$pkg" \
      "https://github.com/$REPO/releases/latest/download/dsh-termux-patches.tar.gz" 2>/dev/null \
      && tar -xzf "$pkg" -C "$dest" scripts patches VERSION 2>/dev/null; then
    echo "==> [self] fetching patch-set asset for $tag (~40KB)"
    return 0
  fi
  echo "==> [self] latest release $tag has no patch-set asset;"
  echo "    falling back to the full runtime tarball (~100MB) — consider"
  echo "    upgrading to a newer release for the lightweight channel."
  pkg="$work/dsh-termux-runtime.tar.gz"
  if ! curl -fL --retry 3 --retry-delay 2 -o "$pkg" \
      "https://github.com/$REPO/releases/latest/download/dsh-termux-runtime.tar.gz"; then
    echo "!! --self: download failed. Network, or fetch the tarball manually:" >&2
    echo "   https://github.com/$REPO/releases/latest/download/dsh-termux-runtime.tar.gz" >&2
    return 1
  fi
  if ! tar -xzf "$pkg" -C "$dest" scripts patches VERSION; then
    echo "!! --self: tarball lacks scripts/ patches/ VERSION — cannot self-update" >&2
    echo "   (releases before 1.2.1 did not ship VERSION; reinstall instead:)" >&2
    echo "     curl -fsSL https://github.com/$REPO/releases/latest/download/install.sh | bash -s -- -y" >&2
    return 1
  fi
}

# apply_patch_set_only <patches_dir> [old_set_dir]
# Apply the patch set in <patches_dir> to the installed tree using the registry
# the caller loaded, then rewrite the wrapper. When <old_set_dir> holds a
# pre-refresh snapshot (registry.sh + patches/), those patches are reversed
# FIRST with their own bytes: without a reinstall a dropped or rewritten patch
# would otherwise linger, or fail the forward apply as version drift.
apply_patch_set_only() {
  local patches_dir="$1" old_set="$2"
  if [ -n "$old_set" ] && [ -f "$old_set/registry.sh" ]; then
    echo "==> [self] Reversing the previously applied patch set"
    ( . "$old_set/registry.sh"; dsh_reverse_patch_set "$WORK_DIR" "$old_set/patches" ) || {
      echo "!! --self: could not reverse the previous patch set; aborting before applying the new one." >&2
      return 1
    }
  fi
  echo "==> [self] Applying the refreshed patch set"
  dsh_apply_patch_set "$WORK_DIR" "$patches_dir" || return 1

  local dsh_bin="$WORK_DIR/node_modules/@deepseek-ai/dsh/lib/bin.js"
  local wrapper="$WORK_DIR/dsh" updater="$RUNTIME_DIR/scripts/update-dsh.sh"
  [ -f "$updater" ] || updater="$BASE_DIR/scripts/update-dsh.sh"
  write_dsh_wrapper "$wrapper" "$NODE_BIN" "$dsh_bin" "$updater"
  mkdir -p "$BIN_DIR"
  ln -sf "$wrapper" "$BIN_DIR/dsh"
  echo "==> [self] Wrapper updated: $BIN_DIR/dsh -> $wrapper"
}

# apply_with_installed_machinery [old_set_dir]
# Apply with the freshly installed scripts/patches (not the copies this process
# happened to load at startup). Used by the re-exec'd apply-only branch and by
# the fallback when the installed updater predates DSH_SELF_APPLY_ONLY.
apply_with_installed_machinery() {
  local old_set="$1"
  ( . "$SELF_DIR/scripts/common.sh"
    . "$SELF_DIR/scripts/patch-lib.sh"
    apply_patch_set_only "$SELF_DIR/patches" "$old_set" )
}

# self_apply_only — the --self body after the refresh: apply the installed
# patch set to the installed dsh and stop. Never touches npm.
self_apply_only() {
  echo "==> [self] Applying the refreshed patch set (no npm update)"
  if [ ! -x "$NODE_BIN" ]; then
    echo "!! glibc Node not found. Run: bash scripts/00-setup.sh" >&2
    exit 1
  fi
  if [ ! -d "$WORK_DIR/node_modules/@deepseek-ai/dsh" ]; then
    echo "!! dsh not installed yet. Run: bash scripts/00-setup.sh" >&2
    exit 1
  fi
  configure_glibc_node "$NODE_BIN"
  if ! apply_with_installed_machinery "${DSH_SELF_OLD_SET:-}"; then
    [ -z "${DSH_SELF_OLD_SET:-}" ] || rm -rf "$DSH_SELF_OLD_SET"
    echo "!! --self: applying the refreshed patch set failed." >&2
    exit 1
  fi
  [ -z "${DSH_SELF_OLD_SET:-}" ] || rm -rf "$DSH_SELF_OLD_SET"
  echo "==> [self] Done. Patch set applied; the dsh version is unchanged."
  echo "    To update the dsh version too:  dsh update"
  exit 0
}

# self_update <mode> <reason>
#   mode=apply     explicit --self/--patch-set: refresh, then apply (or report
#                  "already current") and exit — never runs the npm flow.
#   mode=continue  automatic refresh inside a plain update: refresh, then
#                  re-exec and continue into the npm flow. Returns 10 when the
#                  machinery was already current (caller continues in-process).
self_update() {
  local mode="$1" why="$2"
  local dl_dir work stage tag="" src_desc old_proj new_proj old_sig new_sig
  local old_set_dir="" args=() a skip=0

  dl_dir="${TMPDIR:-$HOME/.cache}/dsh-termux-self"
  mkdir -p "$dl_dir"
  work="$(mktemp -d "$dl_dir/self.XXXXXXXX")"
  stage="$work/set"

  if [ -n "$PATCH_SET" ]; then
    src_desc="local patch set $PATCH_SET"
    echo "==> [self] $why: staging $src_desc"
    if ! stage_patch_set "$PATCH_SET" "$stage"; then
      rm -rf "$work"
      exit 1
    fi
  else
    if ! tag="$(latest_release_tag)" || [ -z "$tag" ]; then
      echo "!! --self: cannot resolve the latest release of $REPO (network?)." >&2
      echo "   Retry later, or reinstall:" >&2
      echo "     curl -fsSL https://github.com/$REPO/releases/latest/download/install.sh | bash -s -- -y" >&2
      rm -rf "$work"
      exit 1
    fi
    src_desc="release $tag"
    if ! fetch_release_patch_set "$tag" "$stage" "$work"; then
      rm -rf "$work"
      exit 1
    fi
  fi
  if ! patch_set_validate "$stage"; then
    rm -rf "$work"
    exit 1
  fi

  old_proj="$(tr -d '[:space:]' < "$SELF_DIR/VERSION" 2>/dev/null || true)"
  [ -n "$old_proj" ] || old_proj="unknown (pre-1.2.1 runtime)"
  new_proj="$(tr -d '[:space:]' < "$stage/VERSION")"
  old_sig="$(machinery_signature "$SELF_DIR")"
  new_sig="$(machinery_signature "$stage")"

  if [ "$old_sig" = "$new_sig" ] && [ "$FORCE" != 1 ]; then
    echo "==> [self] $why: machinery already current (project VERSION $old_proj; $src_desc)"
    rm -rf "$work"
    if [ "$mode" = apply ]; then
      echo "    Nothing to apply. Use --force to re-apply anyway."
      exit 0
    fi
    return 10
  fi

  # Snapshot the runtime's current patch set BEFORE replacing it: the apply
  # step must take the old patches back with the OLD bytes (see
  # dsh_reverse_patch_set). A pre-feature runtime cannot hand one over, and
  # the apply step then falls back to per-patch reverse with the new bytes.
  if [ -f "$SELF_DIR/scripts/patch-lib.sh" ] && [ -d "$SELF_DIR/patches" ]; then
    old_set_dir="$(mktemp -d "$dl_dir/old.XXXXXXXX")"
    mkdir -p "$old_set_dir/patches"
    sed -n '/^DSH_PATCH_SET=(/,/^)/p' "$SELF_DIR/scripts/patch-lib.sh" > "$old_set_dir/registry.sh"
    cp "$SELF_DIR"/patches/*.patch "$old_set_dir/patches/" 2>/dev/null || true
  fi

  mkdir -p "$SELF_DIR/scripts"
  cp "$stage/scripts/update-dsh.sh" "$stage/scripts/common.sh" \
     "$stage/scripts/patch-lib.sh" "$SELF_DIR/scripts/"
  rm -rf "$SELF_DIR/patches"
  cp -r "$stage/patches" "$SELF_DIR/patches"
  cp "$stage/VERSION" "$SELF_DIR/VERSION"
  rm -rf "$work"

  if [ "$new_proj" = "$old_proj" ]; then
    echo "==> [self] project VERSION: $old_proj (already current — forced refresh)"
  else
    echo "==> [self] project VERSION: $old_proj -> $new_proj"
  fi
  echo "    Updated: scripts/ + patches/ + VERSION in $SELF_DIR (project $new_proj; $src_desc)"

  # Sentinels for the re-exec'd updater (the environment survives exec):
  #   DSH_SELF_RAN        — this run refreshed the machinery, so the fresh
  #                         updater announces the continuation into the dsh
  #                         update explicitly instead of sliding into it;
  #   DSH_PATCHES_CHANGED — the patch set actually differs from the one the
  #                         runtime had, so DECLINING the dsh update must warn
  #                         that the new patches are not applied yet.
  export DSH_SELF_RAN=1
  if [ "$old_sig" != "$(machinery_signature "$SELF_DIR")" ]; then
    export DSH_PATCHES_CHANGED=1
  fi
  export DSH_SELF_DONE=1
  [ -z "$old_set_dir" ] || export DSH_SELF_OLD_SET="$old_set_dir"

  # Rebuild argv without the self-update flags (SELF_ARGV was captured before
  # the parser drained $@): the re-exec'd updater must not refresh again.
  for a in "${SELF_ARGV[@]}"; do
    if [ "$skip" = 1 ]; then skip=0; continue; fi
    case "$a" in
      --self|--force) ;;
      --patch-set) skip=1 ;;
      *) args+=("$a") ;;
    esac
  done

  if [ "$mode" = apply ]; then
    if [ -n "$SPEC" ] || [ -n "$TAG" ]; then
      echo "==> [self] NOTE: --self applies the patch set only; -t/-v are ignored." >&2
      echo "    To update the dsh version too, run: dsh update -t <tag>" >&2
    fi
    export DSH_SELF_APPLY_ONLY=1
    if grep -q 'DSH_SELF_APPLY_ONLY' "$SELF_DIR/scripts/update-dsh.sh" 2>/dev/null; then
      exec bash "$SELF_DIR/scripts/update-dsh.sh" "${args[@]}"
    fi
    echo "==> [self] the installed updater predates apply-only mode;"
    echo "    applying with the refreshed libraries instead of re-exec."
    if ! apply_with_installed_machinery "$old_set_dir"; then
      [ -z "$old_set_dir" ] || rm -rf "$old_set_dir"
      echo "!! --self: applying the refreshed patch set failed." >&2
      exit 1
    fi
    [ -z "$old_set_dir" ] || rm -rf "$old_set_dir"
    echo "==> [self] Done. Patch set applied; the dsh version is unchanged."
    echo "    To update the dsh version too:  dsh update"
    exit 0
  fi

  # mode=continue: re-exec the FRESH updater for the npm flow, so the patch set
  # that gets applied is the one just installed (not the pre-self copy in
  # memory). argv comes from SELF_ARGV: the user's -y/-t/-v must survive.
  exec bash "$SELF_DIR/scripts/update-dsh.sh" "${args[@]}"
}

# The re-exec'd apply-only child lands here BEFORE any npm work: the explicit
# --self/--patch-set path never enters the update flow. Handled first so a
# stale sentinel in the environment cannot fall through into the npm branch.
if [ "${DSH_SELF_APPLY_ONLY:-0}" = "1" ]; then
  self_apply_only
fi

if [ "$SELF" = "1" ]; then
  self_update apply "explicit request"
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
      # self_update re-execs into the npm flow when it refreshes; rc 10 means
      # the machinery content was already current, so this process continues.
      rc_self=0
      self_update continue "patch set behind latest release" || rc_self=$?
      [ "$rc_self" = 0 ] || [ "$rc_self" = 10 ] || exit "$rc_self"
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
  local tags
  tags="$(echo "$DIST_TAGS" | tr -d '{}' | tr ',' '\n' | sed 's/^ *//;s/ *$//')"
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

# --- Prebuilt native addons ---------------------------------------------------
# dsh >= 0.1.3 imports flock(2) from fs-ext; --ignore-scripts leaves it unbuilt
# and a Termux device has no glibc toolchain, so the compiled binary comes from
# the release that shipped this dsh (its dsh-termux-natives.tar.gz). Without it
# dsh cannot boot at all — not "degraded", dead.
NATIVE_DSH_VER="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
  "$WORK_DIR/node_modules/@deepseek-ai/dsh/package.json" | head -1)"
echo "==> Ensuring prebuilt native addons"
ensure_native_prebuilds "$WORK_DIR" "$NODE_BIN" "$NATIVE_DSH_VER" \
  || { echo "!! Cannot continue without prebuilt native addons (dsh would not boot)." >&2; exit 1; }

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
