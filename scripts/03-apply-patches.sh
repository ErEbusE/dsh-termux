#!/data/data/com.termux/files/usr/bin/bash
# 03-apply-patches.sh — apply the Android-only patches to the installed npm libs.
#
# The patch set lives in scripts/patch-lib.sh (DSH_PATCH_SET): currently the
# hard-link EACCES fallbacks (Android's kernel SELinux forbids hard links in
# app-private storage) and the Landlock os.tmpdir() grant. They apply to the
# COMPILED lib files inside node_modules (npm packages ship built JS). Adding
# or dropping a patch happens in DSH_PATCH_SET — no edit needed here.
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$BASE_DIR/scripts/common.sh"
source "$BASE_DIR/scripts/patch-lib.sh"

RUNTIME_DIR="${DSH_RUNTIME_DIR:-$HOME/.local/opt/dsh-termux-runtime}"
WORK_DIR="${DSH_WORK_DIR:-$RUNTIME_DIR/work}"
PATCHES="$BASE_DIR/patches"

echo "==> [03] Applying Android patches"

if [ ! -d "$WORK_DIR/node_modules" ]; then
  echo "!! No node_modules found in $WORK_DIR. Run: bash scripts/02-install-dsh.sh" >&2
  exit 1
fi

if ask_yes_no "Apply the ${#DSH_PATCH_SET[@]} Android patches?"; then
  # dsh_apply_patch_set is idempotent and fails loudly on version drift or when
  # git apply skips a patch instead of applying it (see scripts/patch-lib.sh).
  if ! dsh_apply_patch_set "$WORK_DIR" "$PATCHES"; then
    echo "!! Patching failed. dsh would misbehave on Android without these fixes" >&2
    echo "   (session saves, the write tool, sandboxed temp writes); see PATCHES.md" >&2
    echo "   to regenerate the failing patch." >&2
    exit 1
  fi
else
  echo "    Skipped (note: patched behaviors may fail on Android)."
fi

echo "==> [03] Done. Next: scripts/04-run-web.sh"