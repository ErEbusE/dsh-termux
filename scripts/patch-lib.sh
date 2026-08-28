#!/usr/bin/env bash
# patch-lib.sh — shared patch application for the dsh-termux npm lib patches.
# Sourced by scripts/03-apply-patches.sh, scripts/update-dsh.sh,
# build/build-runtime.sh and the CI verify workflow. No shebang execution, and
# deliberately free of Termux-only assumptions so it also runs on Linux CI.
#
# WHY THIS FILE EXISTS
# --------------------
# `git apply` resolves patch paths against the top of the *enclosing git work
# tree* and silently DROPS every patch entry that falls outside the current
# directory: it prints "Skipped patch '...'." and still exits 0. So the obvious
#
#   (cd "$WORK_DIR" && git apply --directory=node_modules/@deepseek-ai p.patch)
#
# works on a Termux device (the runtime lives outside any repo, so there is no
# prefix) but silently patches NOTHING when the work dir sits inside a git
# checkout — e.g. the CI runner building the runtime under the cloned repo.
# Both `--check` and the real apply "succeed" while the libs stay pristine.
#
# dsh_apply_patch therefore:
#   1. prepends the work dir's prefix within the enclosing work tree (empty
#      when the work dir is not inside one), so paths line up either way, and
#   2. proves the target file actually changed, so a silent skip can never be
#      mistaken for success again.

# Print the path of <dir> relative to the top of its enclosing git work tree
# (with a trailing slash), or nothing when <dir> is not inside a work tree.
dsh_git_worktree_prefix() {
  local dir="$1"
  if git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$dir" rev-parse --show-prefix 2>/dev/null || true
  fi
}

# Print a content id for <file>; used to detect no-op applies.
dsh_file_content_id() {
  local file="$1"
  git hash-object "$file" 2>/dev/null || cksum <"$file"
}

# dsh_apply_patch <work_dir> <patch_file> <rel_target>
#   <work_dir>   dir holding node_modules (e.g. $RUNTIME_DIR/work)
#   <patch_file> absolute path to a patch under patches/
#   <rel_target> patched file under node_modules/@deepseek-ai,
#                e.g. dsh-fs-local/lib/index.js
# Idempotent: an already patched file is reversed first, so every run verifies
# the patch against the pristine npm file. Returns non-zero on any failure.
dsh_apply_patch() {
  local work_dir="$1" patch_file="$2" rel="$3"
  local name target directory prefix out before after
  name="$(basename "$patch_file")"
  target="$work_dir/node_modules/@deepseek-ai/$rel"

  echo "==> ${name} -> ${rel}"

  if [ ! -f "$patch_file" ]; then
    echo "    !! patch file not found: $patch_file" >&2
    return 1
  fi
  if [ ! -f "$target" ]; then
    echo "    !! target not found: $target" >&2
    echo "       (@deepseek-ai/${rel%%/*} is not installed in $work_dir)" >&2
    return 1
  fi

  prefix="$(dsh_git_worktree_prefix "$work_dir")"
  directory="${prefix}node_modules/@deepseek-ai"

  # npm may restore a previously patched copy from its cache, and re-runs must
  # be idempotent, so reverse an already applied patch before re-applying it.
  if git -C "$work_dir" apply --directory="$directory" --reverse --check \
    "$patch_file" >/dev/null 2>&1; then
    git -C "$work_dir" apply --directory="$directory" --reverse "$patch_file" \
      >/dev/null 2>&1 || true
  fi

  before="$(dsh_file_content_id "$target")"

  if ! out="$(git -C "$work_dir" apply --directory="$directory" --check "$patch_file" 2>&1)"; then
    echo "    !! ${name} does not apply to the installed version (version drift)" >&2
    [ -n "$out" ] && printf '       %s\n' "$out" >&2
    echo "       Regenerate the patch from the npm package — see PATCHES.md." >&2
    return 1
  fi
  if ! out="$(git -C "$work_dir" apply --directory="$directory" "$patch_file" 2>&1)"; then
    echo "    !! ${name} failed to apply" >&2
    [ -n "$out" ] && printf '       %s\n' "$out" >&2
    return 1
  fi

  after="$(dsh_file_content_id "$target")"
  if [ "$after" = "$before" ]; then
    # git apply exits 0 when it skips patch paths outside the current
    # directory; catch that instead of shipping unpatched libs.
    echo "    !! ${name}: git apply reported success but ${rel} is unchanged" >&2
    echo "       (work dir: $work_dir, git prefix: '${prefix}')" >&2
    echo "       Run with --verbose to see whether git skipped the patch." >&2
    return 1
  fi

  echo "    OK (patch matches the installed version)"
}

# dsh_verify_patch_markers <work_dir> <rel_target>...
# Confirm the marker each patch bakes into its target file is present. Markers
# are derived from DSH_PATCH_SET (the one home of the patch -> marker pairing),
# so callers may pass bare rel targets — including CI, which verifies an
# explicit list. Returns non-zero if any marker is missing or unknown.
dsh_verify_patch_markers() {
  local work_dir="$1"; shift
  local rc=0 rel target marker
  for rel in "$@"; do
    if ! marker="$(dsh_patch_marker "$rel")"; then
      echo "    !! no marker known for ${rel} (not in DSH_PATCH_SET?)" >&2
      rc=1
      continue
    fi
    target="$work_dir/node_modules/@deepseek-ai/$rel"
    if grep -q "$marker" "$target" 2>/dev/null; then
      echo "    OK marker present: $rel"
    else
      echo "    !! marker '${marker}' missing: $target" >&2
      rc=1
    fi
  done
  return "$rc"
}

# The Android patches, as "<patch file>:<rel target>:<marker>" triples. The
# marker is the grep-able string the patch bakes into its target — evidence the
# file really carries the fix. Callers iterate this so a patch is added or
# dropped in exactly one place.
DSH_PATCH_SET=(
  "npm-dsh-session-persistence-jsonl-link-rename.patch:dsh-session-persistence-jsonl/lib/index.js:platformLinkDenied"
  "npm-dsh-fs-local-link-rename.patch:dsh-fs-local/lib/index.js:platformLinkDenied"
  "npm-dsh-sandbox-local-landlock-tmpdir.patch:dsh-sandbox-local/lib/index.js:dsh-termux-landlock-tmpdir"
)

# dsh_patch_marker <rel_target>
# Print the marker DSH_PATCH_SET pairs with <rel_target>. Non-zero (with a
# message on stderr) when the target is absent from the set or its entry lacks
# the marker field — a malformed entry must fail verification, not pass it.
dsh_patch_marker() {
  local rel="$1" entry rest r m
  for entry in "${DSH_PATCH_SET[@]}"; do
    rest="${entry#*:}"
    r="${rest%%:*}"
    [ "$r" = "$rel" ] || continue
    m="${rest#*:}"
    if [ -z "$m" ] || [ "$m" = "$rest" ]; then
      echo "!! dsh_patch_marker: DSH_PATCH_SET entry for ${rel} lacks a marker field" >&2
      return 1
    fi
    printf '%s' "$m"
    return 0
  done
  return 1
}

# dsh_apply_patch_set <work_dir> <patches_dir>
# Apply every patch in DSH_PATCH_SET, then verify all markers.
dsh_apply_patch_set() {
  local work_dir="$1" patches_dir="$2"
  local entry patch rest rel rels=()
  for entry in "${DSH_PATCH_SET[@]}"; do
    patch="${entry%%:*}"
    rest="${entry#*:}"
    rel="${rest%%:*}"
    dsh_apply_patch "$work_dir" "$patches_dir/$patch" "$rel" || return 1
    rels+=("$rel")
  done
  echo "==> Verifying patch markers"
  dsh_verify_patch_markers "$work_dir" "${rels[@]}"
}
