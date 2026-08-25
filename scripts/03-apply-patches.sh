#!/data/data/com.termux/files/usr/bin/bash
# 03-apply-patches.sh — apply the Android-only patches to the installed npm libs.
#
# Only two patches remain, both for the SAME root cause: Android's kernel
# SELinux forbids hard links in app-private storage. The dsh session store and
# the write tool both publish files with link() + unlink(); we make them fall
# back to rename() when the platform denies linking. These apply to the
# COMPILED lib files inside node_modules (npm packages ship built JS).
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

if ask_yes_no "Apply the two Android hard-link patches?"; then
  # dsh_apply_patch_set is idempotent and fails loudly on version drift or when
  # git apply skips a patch instead of applying it (see scripts/patch-lib.sh).
  if ! dsh_apply_patch_set "$WORK_DIR" "$PATCHES"; then
    echo "!! Patching failed. dsh would fail to save sessions and to write files" >&2
    echo "   on Android without these fixes; see PATCHES.md to regenerate them." >&2
    exit 1
  fi
else
  echo "    Skipped (note: session saves and the write tool may fail on Android)."
fi

echo "==> [03] Done. Next: scripts/04-run-web.sh"