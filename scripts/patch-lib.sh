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

# dsh_verify_patch_markers <work_dir> <entry>...
# Confirm the marker each patch bakes into its target file is present. Entries
# come straight from DSH_PATCH_SET (the one home of the patch -> marker
# pairing), so callers may pass every applicable entry — including CI, which
# verifies an explicit list. Returns non-zero if any marker is missing.
dsh_verify_patch_markers() {
  local work_dir="$1"; shift
  local rc=0 entry rel marker target _
  for entry in "$@"; do
    IFS=: read -r _ rel marker _ <<<"$entry"
    if [ -z "$marker" ]; then
      echo "    !! DSH_PATCH_SET entry for ${rel} lacks a marker field" >&2
      rc=1
      continue
    fi
    target="$work_dir/node_modules/@deepseek-ai/$rel"
    if grep -qF "$marker" "$target" 2>/dev/null; then
      echo "    OK marker present: $rel"
      continue
    fi
    echo "    !! marker '${marker}' missing: $target" >&2
    rc=1
  done
  return "$rc"
}

# The Android patches, as "<patch file>:<rel target>:<marker>[:<precondition>]"
# entries. The marker is the grep-able string the patch bakes into its target —
# evidence the file really carries the fix. Callers iterate this so a patch is
# added or dropped in exactly one place.
#
# A 4th field makes the entry CONDITIONAL: the patch is applied, and its marker
# required, only while <precondition> is present in the target file. It exists
# for a fix whose upstream code is not in every dsh version — without it the
# only options are "break every install that lacks the code" or "ship the fix
# to nobody". Pick a precondition the patch itself does not remove, so
# applicability cannot flip once the fix is in (CI enforces that). Three-field
# entries stay mandatory: they must apply, and a failure stops the pipeline.
# Entries key by patch FILE, and one target lib may carry several of them —
# the attachment store ships a mandatory walk fix plus one conditional link
# fix per upstream code generation, each skipping loudly where it does not
# apply.
DSH_PATCH_SET=(
  "npm-dsh-session-persistence-jsonl-link-rename.patch:dsh-session-persistence-jsonl/lib/index.js:platformLinkDenied"
  # 0.1.3's released-format migration added a second link() call site in this
  # same lib: publishCurrentExclusive publishes the migrated session.v3
  # generation. Unpatched it made every WRITE open of a pre-0.1.3 session fail
  # with EACCES: link — the old session would render but not send, and every
  # agent-scoped RPC (slash commands, @ references) died with it. Conditional
  # on the exact call it rewrites; absent from 0.1.2 (no generation runtime).
  "npm-dsh-session-persistence-jsonl-link-rename-015.patch:dsh-session-persistence-jsonl/lib/index.js:dsh-termux-session-link-rename-015:await internals.fs.link(staged, currentPath)"
  # Same publish call, same anchor string, bundled inside the migration
  # verifier worker (worker.cjs, 0.1.3+ only — 0.1.2 ships no worker.cjs, so
  # the missing target skips too). Dormant today: the worker entry runs
  # verify() only. Patched so the bundled copy cannot silently resurrect the
  # EACCES if publishing ever moves into the worker.
  "npm-dsh-session-persistence-jsonl-worker-link-rename-015.patch:dsh-session-persistence-jsonl/lib/worker.cjs:dsh-termux-session-worker-link-rename-015:await internals.fs.link(staged, currentPath)"
  "npm-dsh-fs-local-link-rename.patch:dsh-fs-local/lib/index.js:platformLinkDenied"
  "npm-dsh-sandbox-local-landlock-tmpdir.patch:dsh-sandbox-local/lib/index.js:dsh-termux-landlock-tmpdir"
  # Browser-session cookie: dsh >= 0.1.2 only (COOKIE_PREFIX "dsh-auth-"); npm
  # latest is still 0.1.1-rc.2, which has no browser authentication at all.
  "npm-dsh-client-connection-samesite-lax.patch:dsh-client-connection/lib/index.js:dsh-termux-samesite-lax:dsh-auth-"
  # Attachment store durability, split per upstream code shape. The
  # ancestor-durability walk fsyncs up to the filesystem root (/data/data is
  # EACCES for the app uid) — one hunk, identical context in every published
  # bundle (0.1.0-rc.8 through 0.1.5-alpha.1), so it stays mandatory. The
  # link() publish fallback differs: 0.1.2 ships one call site
  # (commitPreparedImageFile), 0.1.3+ refactored the publish into
  # publishStagedObject + publishImmutableAlias (0.1.3-alpha.2 and
  # 0.1.5-alpha.1 ship byte-identical bundles). Each link patch is conditional
  # on the exact call it rewrites and keeps that string, so applicability
  # cannot flip. See PATCHES.md, Patch 7.
  "npm-dsh-attachment-local-durable-walk.patch:dsh-attachment-local/lib/index.js:dsh-termux-att-durability"
  "npm-dsh-attachment-local-link-rename.patch:dsh-attachment-local/lib/index.js:dsh-termux-att-link-rename:await link(temporary, target)"
  "npm-dsh-attachment-local-link-rename-015.patch:dsh-attachment-local/lib/index.js:dsh-termux-att-link-rename-015:await link(staged.path, target)"
)

# dsh_patch_entry_for <patch_file>
# Print the whole DSH_PATCH_SET entry registering <patch_file>. Non-zero when
# no entry carries that name. The registry keys entries by patch FILE — one
# target lib may carry several patches (e.g. the attachment walk fix plus a
# per-generation link fallback), so a rel-target lookup would be ambiguous.

# dsh_patch_marker <patch_file>
# Print the marker of the entry registering <patch_file>. Non-zero (with a
# message on stderr) when the patch is absent from the set or its entry lacks
# the marker field — a malformed entry must fail verification, not pass it.
dsh_patch_marker() {
  local patch_file="$1" entry marker _
  for entry in "${DSH_PATCH_SET[@]}"; do
    IFS=: read -r field_patch _ <<<"$entry"
    [ "$field_patch" = "$patch_file" ] || continue
    IFS=: read -r _ _ marker _ <<<"$entry"
    if [ -z "$marker" ]; then
      echo "!! dsh_patch_marker: DSH_PATCH_SET entry for ${patch_file} lacks a marker field" >&2
      return 1
    fi
    printf '%s' "$marker"
    return 0
  done
  echo "!! dsh_patch_marker: no DSH_PATCH_SET entry for ${patch_file}" >&2
  return 1
}

# dsh_patch_applicable <work_dir> <entry>
# 0 = apply it (mandatory entry, or precondition present in the target),
# 1 = not applicable to this dsh version. The entry carries its own rel and
# precondition, so no registry lookup is needed here.
dsh_patch_applicable() {
  local work_dir="$1" entry="$2" rel precondition target _
  IFS=: read -r _ rel _ precondition _ <<<"$entry"
  [ -n "$precondition" ] || return 0
  target="$work_dir/node_modules/@deepseek-ai/$rel"
  [ -f "$target" ] || return 1
  grep -qF "$precondition" "$target" 2>/dev/null
}

# dsh_apply_patch_set <work_dir> <patches_dir>
# Apply every patch in DSH_PATCH_SET, then verify all markers.
dsh_apply_patch_set() {
  local work_dir="$1" patches_dir="$2"
  # 整条补丁管线骑在 git 上 (apply 与 worktree-prefix 的 rev-parse); 缺 git 时
  # 若不预检, 失败会以逐补丁的噪音形式晚到。一次预检 + 人话修法。
  # (hardcoding 审计 E1, 高风险 Top2: 全仓 0 预检)
  command -v git >/dev/null 2>&1 || {
    echo "!! git not found — the patch pipeline requires it (git apply)." >&2
    echo "   Termux: pkg install git" >&2
    return 1
  }
  local entry patch rel precondition app applied=() _
  for entry in "${DSH_PATCH_SET[@]}"; do
    IFS=: read -r patch rel _ precondition _ <<<"$entry"
    if dsh_patch_applicable "$work_dir" "$entry"; then app=0; else app=$?; fi
    if [ "$app" != 0 ]; then
      echo "==> ${patch} -> ${rel}"
      echo "    -- skipped: no '${precondition}' in this dsh version (not applicable)"
      continue
    fi
    dsh_apply_patch "$work_dir" "$patches_dir/$patch" "$rel" || return 1
    applied+=("$entry")
  done
  echo "==> Verifying patch markers"
  if [ "${#applied[@]}" -eq 0 ]; then
    echo "    (no applicable patches for this dsh version)"
    return 0
  fi
  dsh_verify_patch_markers "$work_dir" "${applied[@]}"
}
