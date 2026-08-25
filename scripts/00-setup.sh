#!/data/data/com.termux/files/usr/bin/bash
# 00-setup.sh — entry point: configure environment and drive the install
# pipeline (01 -> 02 -> 03 -> 04).
#
# Usage:
#   bash scripts/00-setup.sh               # default values + asks
#   bash scripts/00-setup.sh --interaction # interactively set env values + asks
#   bash scripts/00-setup.sh -y            # default values, auto-accept all prompts
#   bash scripts/00-setup.sh --interaction -y   # interactive env, auto-accept installs
#
# Flags:
#   -y, --yes           auto-accept every prompt
#   --interaction       interactively set environment values (default: use defaults)
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$BASE_DIR/scripts/common.sh"

MODE="default"          # default | interaction
DSH_ASSUME_YES=0

while [ $# -gt 0 ]; do
  case "${1,,}" in
    -y|--yes) DSH_ASSUME_YES=1 ;;
    --interaction|--interactive) MODE="interaction" ;;
    -h|--help)
      sed -n '2,16p' "$0" >&2; exit 0 ;;
    *)
      echo "00-setup.sh: unknown option: $1" >&2
      echo "Usage: bash scripts/00-setup.sh [--interaction] [-y]" >&2
      exit 2 ;;
  esac
  shift
done

echo "==> dsh-termux installer"
echo "    mode: ${MODE}   assume-yes: ${DSH_ASSUME_YES}"

# --- Environment configuration --------------------------------------------
DEF_RUNTIME_DIR="${DSH_RUNTIME_DIR:-$HOME/.local/opt/dsh-termux-runtime}"
DEF_NODE_VERSION="${DSH_NODE_VERSION:-24.19.0}"
DEF_WORK_DIR="${DSH_WORK_DIR:-}"
DEF_PORT="${DSH_WEB_PORT:-3080}"
DEF_BIN_DIR="${DSH_BIN_DIR:-$HOME/.local/bin}"

if [ "$MODE" = "interaction" ]; then
  echo
  echo "==> Configure environment (Enter accepts the default)"
  ask_input DSH_RUNTIME_DIR "Runtime dir (space-free absolute path)" \
    "$DEF_RUNTIME_DIR" validate_abs_path
  ask_input DSH_NODE_VERSION "Node.js version (^22.19.0 || >=24.0.0)" \
    "$DEF_NODE_VERSION" validate_node_version
  ask_input DSH_WORK_DIR "Work dir (empty = \$DSH_RUNTIME_DIR/work)" \
    "$DEF_WORK_DIR" validate_abs_path
  ask_input DSH_WEB_PORT "Default web port" "$DEF_PORT" validate_port
  ask_input DSH_BIN_DIR "Where to symlink the dsh command" \
    "$DEF_BIN_DIR" validate_abs_path
else
  DSH_RUNTIME_DIR="$DEF_RUNTIME_DIR"
  DSH_NODE_VERSION="$DEF_NODE_VERSION"
  DSH_WORK_DIR="$DEF_WORK_DIR"
  DSH_WEB_PORT="$DEF_PORT"
  DSH_BIN_DIR="$DEF_BIN_DIR"
fi

# Normalize empty work dir to <runtime>/work.
DSH_WORK_DIR="${DSH_WORK_DIR:-$DSH_RUNTIME_DIR/work}"

export DSH_RUNTIME_DIR DSH_NODE_VERSION DSH_WORK_DIR DSH_WEB_PORT DSH_BIN_DIR
export DSH_ASSUME_YES
echo "==> Using:"
echo "    DSH_RUNTIME_DIR = $DSH_RUNTIME_DIR"
echo "    DSH_NODE_VERSION = $DSH_NODE_VERSION"
echo "    DSH_WORK_DIR    = $DSH_WORK_DIR"
echo "    DSH_WEB_PORT    = $DSH_WEB_PORT"
echo "    DSH_BIN_DIR     = $DSH_BIN_DIR"

# --- Pipeline --------------------------------------------------------------
if ! ask_yes_no "Proceed with installation?"; then
  echo "Aborted."; exit 1
fi

bash "$BASE_DIR/scripts/01-setup-glibc-node.sh" || exit $?
bash "$BASE_DIR/scripts/02-install-dsh.sh" || exit $?
bash "$BASE_DIR/scripts/03-apply-patches.sh" || exit $?
bash "$BASE_DIR/scripts/04-run-web.sh" || exit $?

echo
echo "==> Install complete."
echo "    Start dsh web anytime with:  bash scripts/04-run-web.sh"