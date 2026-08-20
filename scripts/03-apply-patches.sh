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

RUNTIME_DIR="${DSH_RUNTIME_DIR:-$HOME/.local/opt/dsh-termux-runtime}"
WORK_DIR="${DSH_WORK_DIR:-$RUNTIME_DIR/work}"
PATCHES="$BASE_DIR/patches"

echo "==> [03] Applying Android patches"

apply_to_node_modules() {
  local patch="$1"
  local rel="$2"       # path under node_modules/@deepseek-ai, e.g. dsh-fs-local/lib/index.js
  local target="$WORK_DIR/node_modules/@deepseek-ai/$rel"
  echo "==> Applying ${patch} ..."
  if grep -q "platformLinkDenied" "$target" 2>/dev/null; then
    echo "    already applied (marker present), skipping"
    return 0
  fi
  if (cd "$WORK_DIR" \
    && git apply --directory=node_modules/@deepseek-ai --check "$PATCHES/${patch}" \
    && git apply --directory=node_modules/@deepseek-ai "$PATCHES/${patch}"); then
    echo "    OK"
  else
    echo "    !! ${patch} NOT applied (version drift? re-generate from the npm package)"
  fi
}

if [ ! -d "$WORK_DIR/node_modules" ]; then
  echo "!! No node_modules found in $WORK_DIR. Run: bash scripts/02-install-dsh.sh" >&2
  exit 1
fi

if ask_yes_no "Apply the two Android hard-link patches?"; then
  apply_to_node_modules npm-dsh-session-persistence-jsonl-link-rename.patch dsh-session-persistence-jsonl/lib/index.js
  apply_to_node_modules npm-dsh-fs-local-link-rename.patch dsh-fs-local/lib/index.js
else
  echo "    Skipped (note: session saves and the write tool may fail on Android)."
fi

echo "==> [03] Done. Next: scripts/04-run-web.sh"