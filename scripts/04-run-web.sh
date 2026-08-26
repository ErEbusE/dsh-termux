#!/data/data/com.termux/files/usr/bin/bash
# 04-run-web.sh — start the dsh browser UI, and install the `dsh` wrapper.
#
# Besides starting web on :3080, this script:
#   - writes a `dsh` launcher wrapper into $WORK_DIR (execs the configured glibc
#     Node directly, accepting the same args as the real dsh CLI) plus the
#     `dsh-termux-open` Android-intent opener it points $BROWSER at — see
#     write_dsh_wrapper and write_dsh_opener in common.sh,
#   - symlinks it into a bin dir (default $HOME/.local/bin, interactive),
#   - prepends that bin dir to PATH in ~/.bashrc (tagged # dsh-termux) so the
#     wrapper behaves exactly like the original `dsh` command.
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$BASE_DIR/scripts/common.sh"

RUNTIME_DIR="${DSH_RUNTIME_DIR:-$HOME/.local/opt/dsh-termux-runtime}"
NODE_BIN="$RUNTIME_DIR/node/bin/node"
WORK_DIR="${DSH_WORK_DIR:-$RUNTIME_DIR/work}"
PORT="${DSH_WEB_PORT:-${PORT:-3080}}"
HOST="${HOST:-127.0.0.1}"
BIN_DIR="${DSH_BIN_DIR:-$HOME/.local/bin}"

echo "==> [04] Preparing dsh wrapper + web launch"

if [ ! -x "$NODE_BIN" ]; then
  echo "!! glibc Node not found. Run: bash scripts/01-setup-glibc-node.sh" >&2
  exit 1
fi
if [ ! -d "$WORK_DIR/node_modules/@deepseek-ai" ]; then
  echo "!! dsh not installed. Run: bash scripts/02-install-dsh.sh" >&2
  exit 1
fi

# --- Configure Node for direct exec ----------------------------------------
# Existing installs predate the direct-exec wrapper; this is idempotent.
configure_glibc_node "$NODE_BIN"

# --- Generate the wrapper --------------------------------------------------
DSH_BIN="$WORK_DIR/node_modules/@deepseek-ai/dsh/lib/bin.js"
WRAPPER="$WORK_DIR/dsh"

# `dsh update` shortcut target: prefer the updater bundled inside the runtime
# dir (Option A release installs), fall back to this repo copy (Option B, where
# scripts/ only exists in the checkout).
UPDATER="$RUNTIME_DIR/scripts/update-dsh.sh"
[ -f "$UPDATER" ] || UPDATER="$BASE_DIR/scripts/update-dsh.sh"

write_dsh_wrapper "$WRAPPER" "$NODE_BIN" "$DSH_BIN" "$UPDATER"
echo "    Wrapper written: $WRAPPER"
echo "    Opener written : $WORK_DIR/dsh-termux-open  (\$BROWSER for the web handoff)"

# --- Symlink into bin dir ---------------------------------------------------
mkdir -p "$BIN_DIR"
LINK="$BIN_DIR/dsh"
ln -sf "$WRAPPER" "$LINK"
echo "    Symlinked: $LINK -> $WRAPPER"

# --- Prepend bin dir to PATH in ~/.bashrc ----------------------------------
BASHRC="$HOME/.bashrc"
TAG="# dsh-termux"
if ! grep -qF "$TAG" "$BASHRC" 2>/dev/null; then
  if ask_yes_no "Add '$BIN_DIR' to PATH in ~/.bashrc (tagged $TAG)?"; then
    printf '\n%s\n# Prepend dsh-termux bin dir so the dsh wrapper is on PATH.\nexport PATH="%s:$PATH"\n' \
      "$TAG" "$BIN_DIR" >> "$BASHRC"
    echo "    Appended to $BASHRC:"
    echo "      $TAG"
    echo "      export PATH=\"$BIN_DIR:\$PATH\""
  else
    echo "    Skipped PATH setup (you can run the wrapper as '$WRAPPER')."
  fi
else
  echo "    ~/.bashrc already tagged with $TAG; leaving it unchanged."
fi

echo "    NOTE: start a new shell (or 'source ~/.bashrc') so 'dsh' resolves."
echo "    You can now run:  dsh --version   /   dsh web   /   dsh --profile headless ..."

# --- Launch web -------------------------------------------------------------
# Launch through the wrapper so this run gets exactly what the `dsh` command
# gets: direct node exec (correct process.execPath) and the $BROWSER handoff.
if ask_yes_no "Start dsh web now on ${HOST}:${PORT}?"; then
  cd "$WORK_DIR"
  echo "==> Starting dsh web at http://${HOST}:${PORT} ..."
  echo "    (Keep Termux in the foreground: Android blocks activity launches"
  echo "     from a background app, which would swallow the browser handoff.)"
  exec "$WRAPPER" web --host "$HOST" --port "$PORT"
fi
echo "==> [04] Done."