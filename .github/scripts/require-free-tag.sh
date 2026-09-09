#!/usr/bin/env bash
# require-free-tag.sh <tag> — refuse an invalid or already-existing release tag.
#
# The single home of the release tag's syntax rule and its collision guard.
# release.yml calls it twice: before the ~16-minute build on the *predicted*
# tag (dist-tag and exact-version specs resolve before the build), and after
# the build on the authoritative tag. One script means the message and the
# exit semantics cannot drift between the two.
#
# Exit 0: the tag is valid and free. Non-zero: it is malformed or taken.
set -euo pipefail

tag="${1:?用法: require-free-tag.sh <tag>}"

if ! [[ "$tag" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "::error::Invalid tag '$tag': only letters, digits, '.', '_' and '-' are" >&2
  echo "   allowed (it becomes both a git ref and an asset path)." >&2
  exit 1
fi

if git ls-remote --tags origin "refs/tags/${tag}" 2>/dev/null | grep -q .; then
  echo "::error::Tag $tag already exists. Bump VERSION (or pick another tag) instead of reusing it." >&2
  exit 1
fi
