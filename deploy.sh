#!/usr/bin/env bash
set -euo pipefail

# The source is pinned to a commit in lib.nix (a moving tag would break the
# hash), so the release tag is derived from it instead of from HEAD.
rev=$(sed -n 's/.*srcRev = "\([0-9a-f]*\)".*/\1/p' lib.nix)
[ -n "$rev" ] || { echo "no srcRev in lib.nix" >&2; exit 1; }

git push origin main
git tag -f 0.9.0 "$rev"
git push origin 0.9.0 --force

# Build from the pinned commit. On a hash mismatch nix prints the correct
# value: copy the "got:" hash into lib.nix (src sha256 or mixDeps hash),
# then set srcRev to the commit whose tree you want to release.
nix-build
