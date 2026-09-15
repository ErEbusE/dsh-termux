#!/usr/bin/env bash
# package-runtime.sh — how a built runtime becomes a shippable artifact set.
#
# Three phases, run in this order:
#   stage    copy the installer / updater / patch set into the runtime dir and
#            pack dsh-termux-runtime.tar.gz + dsh-termux-patches.tar.gz
#   verify   prove the runtime tarball carries everything the installer and the
#            embedded updater need (member list derived from DSH_PATCH_SET)
#   smoke    install the tarball with the shipped install.sh on THIS host and
#            assert the wiring (wrapper direct-exec, bin symlink, .bashrc line)
#
# Why this is a script and not three blocks inside one workflow
# ------------------------------------------------------------
# Two workflows must run the SAME packaging code:
#   * release.yml — the npm path that ships a release; and
#   * the candidate-artifact workflow — a branch build uploaded as a workflow
#     artifact so a real phone can install and exercise it before any release
#     exists (DECISIONS.md ADR-006).
# release.yml cannot be end-to-end validated without actually publishing, so the
# candidate run is the only way this path gets executed before a real release
# does. One implementation means the smoke test that guards a release is the
# same one that guards the tree about to be installed on a device.
#
# Why three invocations from three workflow steps, not one
# -------------------------------------------------------
# Each phase used to be its own step, and therefore its own shell process with
# its own `set -e` boundary: a failure aborted that step and no further step ran.
# Keeping one phase per invocation preserves that: variables do not leak across
# phases, and the ARCHIVE / PATCH_ARCHIVE handoff between stage and the later
# consumers still travels through $GITHUB_ENV exactly as before.
#
# Env:
#   DSH_RUNTIME_DIR   runtime dir to package (default <workspace>/dsh-termux-runtime)
#   GITHUB_WORKSPACE  checkout root (default: the repo root this script lives in)
#   GITHUB_ENV        set by Actions; `stage` exports ARCHIVE and PATCH_ARCHIVE to it
#
# This script never publishes and never touches a git tag or a release. The
# release-only machinery — input resolution, the changed/downgrade gates, the
# tag guard, release notes and softprops/action-gh-release — stays in
# release.yml, on purpose: packaging is not publishing.
set -euo pipefail

self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${GITHUB_WORKSPACE:-$(cd "$self_dir/../.." && pwd)}"
cd "$REPO" || { echo "!! cannot cd to workspace: $REPO" >&2; exit 1; }
RT="${DSH_RUNTIME_DIR:-$REPO/dsh-termux-runtime}"

# Fixed asset names so /releases/latest/download/<name> works for the curl|bash
# install path. The candidate workflow relies on the same names: its artifact
# layout must be the release layout, or the device would test something else.
ARCHIVE="dsh-termux-runtime.tar.gz"
PATCH_ARCHIVE="dsh-termux-patches.tar.gz"

phase="${1:-}"
case "$phase" in
  stage|verify|smoke) ;;
  *) echo "usage: $0 <stage|verify|smoke>" >&2; exit 2 ;;
esac

if [ "$phase" = stage ]; then
  # The tarball is self-contained: runtime + installer + everything the
  # embedded updater needs (its own helpers and the patch files). The
  # repo-relative layout is preserved so update-dsh.sh works unmodified;
  # install.sh sources scripts/common.sh out of this very tarball, so the
  # helper set must match scripts/ exactly.
  cp build/install.sh "$RT/install.sh"
  mkdir -p "$RT/scripts"
  cp scripts/update-dsh.sh scripts/common.sh scripts/patch-lib.sh "$RT/scripts/"
  cp -r patches "$RT/patches"
  # The runtime's own project version: the bundled updater compares it
  # with the latest release to warn when the shipped PATCH SET is
  # outdated (new patches ship in new project releases, not via npm).
  cp VERSION "$RT/VERSION"
  tar -czf "$ARCHIVE" -C "$RT" node work install.sh scripts patches VERSION
  # Lightweight patch-set asset: the updater's self-update channel.
  # 40KB vs the 100MB runtime tarball — refreshing the updater +
  # patches + VERSION must not cost a full-runtime download. The member
  # list lives in build/build-patchset.sh (also used locally and by
  # --patch-set), so the release and a test package cannot drift apart.
  #
  # Built unconditionally by BOTH consumers. Skipping it in the candidate
  # workflow would leave a release-only branch of this very file unexercised —
  # a divergence in the one place the two callers are supposed to be identical.
  # What a caller uploads is a separate question from what gets built.
  bash build/build-patchset.sh -r "$RT" -o "$PATCH_ARCHIVE"
  # Keep a standalone copy of the installer as its own asset too.
  cp build/install.sh ./install.sh
  echo "ARCHIVE=$ARCHIVE" >> "$GITHUB_ENV"
  echo "PATCH_ARCHIVE=$PATCH_ARCHIVE" >> "$GITHUB_ENV"
  echo "Built: $ARCHIVE + $PATCH_ARCHIVE"
  ls -lh "$ARCHIVE" "$PATCH_ARCHIVE"
  exit 0
fi

# stage exported ARCHIVE and PATCH_ARCHIVE through $GITHUB_ENV for the publish
# step (release.yml consumes them as `env.ARCHIVE`); verify/smoke read the file
# from the workspace root, which is why they `cd "$REPO"` above.

if [ "$phase" = verify ]; then
  want=(
    node/bin/node
    work/node_modules/@deepseek-ai/dsh/lib/bin.js
    install.sh
    scripts/update-dsh.sh
    scripts/common.sh
    scripts/patch-lib.sh
  )
  # Patch files AND their target libs derive from DSH_PATCH_SET — the
  # single registry in scripts/patch-lib.sh — so adding a patch needs
  # no edit here; a patch declared but not packaged still fails below.
  # A CONDITIONAL entry (4th field) whose target lib is absent from
  # THIS bundle is inapplicable there — the same [ -f ] gate as
  # dsh_patch_applicable (0.1.2-rc.1 ships no
  # dsh-session-persistence-jsonl/lib/worker.cjs) — so it is not
  # demanded. Mandatory entries keep demanding their target: a
  # missing file is version drift and must fail the release.
  # shellcheck source=../../scripts/patch-lib.sh
  source "$REPO/scripts/patch-lib.sh"
  for entry in "${DSH_PATCH_SET[@]}"; do
    want+=("patches/${entry%%:*}")
    IFS=: read -r _ rel _ precondition _ <<<"$entry"
    target="work/node_modules/@deepseek-ai/$rel"
    if [ -n "$precondition" ] && [ ! -f "$RT/$target" ]; then
      echo "skip (conditional patch target absent from this bundle): $rel"
      continue
    fi
    want+=("$target")
  done
  # Read the listing once, then match in memory. Do NOT pipe tar directly
  # into `grep -q`: grep exits on the first match, the pipe closes and
  # tar dies with SIGPIPE (141), and with `-o pipefail` that fails the
  # pipeline — a phantom "MISSING" on large (200MB) archives.
  LIST="$(tar -tzf "$ARCHIVE")"
  miss=0
  for f in "${want[@]}"; do
    if ! grep -qx "$f" <<< "$LIST"; then
      echo "MISSING from tarball: $f"; miss=1
    fi
  done
  [ "$miss" = 0 ] || { echo "FAIL: tarball structure"; exit 1; }
  echo "OK: tarball has node + dsh + installer + updater + patches ($(grep -c '' <<< "$LIST") entries)"
  exit 0
fi

# phase = smoke.
# Smoke the shipped installer on this arm64 host: a stub `grun` satisfies
# its preflight (the wrapper is never executed here), a temp HOME keeps
# ~/.bashrc untouched, and temp prefix/bin prove the full unpack+wire-up.
# The browser-handoff fix makes install.sh reconfigure Node's ELF
# interpreter on the device; on this glibc host that needs patchelf and a
# loader the script's probe can find, so install patchelf and expose
# /lib/ld-linux-aarch64.so.1 (node ships with exactly that interpreter, so
# the configure step short-circuits as "already configured").
if ! command -v patchelf >/dev/null 2>&1; then
  sudo apt-get update
  sudo apt-get install -y patchelf
fi
if [ ! -e /lib/ld-linux-aarch64.so.1 ]; then
  LOADER="$(ldconfig -p | awk '/ld-linux-aarch64/{print $NF; exit}')"
  test -n "$LOADER"
  sudo ln -sf "$LOADER" /lib/ld-linux-aarch64.so.1
fi
T="$(mktemp -d)"
mkdir -p "$T/bin" "$T/home" "$T/prefix-parent"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/grun"
chmod +x "$T/bin/grun"
PATH="$T/bin:$PATH" HOME="$T/home" GLIBC_PREFIX=/ \
  bash ./install.sh -y -p "$ARCHIVE" \
    --prefix "$T/prefix/dsh-termux-runtime" --bin "$T/bin2"
test -x "$T/prefix/dsh-termux-runtime/node/bin/node"
test -f "$T/prefix/dsh-termux-runtime/work/node_modules/@deepseek-ai/dsh/lib/bin.js"
test -f "$T/prefix/dsh-termux-runtime/install.sh"
test -f "$T/prefix/dsh-termux-runtime/scripts/update-dsh.sh"
# Browser-handoff fix: the wrapper must exec Node DIRECTLY (not via
# grun), or /proc/self/exe — process.execPath — becomes the loader.
grep -q '^exec ".*node/bin/node" --expose-internals ".*bin\.js" "\$@"' \
  "$T/prefix/dsh-termux-runtime/work/dsh"
if grep -q 'exec grun' "$T/prefix/dsh-termux-runtime/work/dsh"; then
  echo "FAIL: wrapper routes Node through grun (breaks process.execPath)"; exit 1
fi
test -L "$T/bin2/dsh"
grep -q "# dsh-termux" "$T/home/.bashrc"
echo "OK: installer smoke passed"
