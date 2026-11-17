#!/usr/bin/env bash
set -euo pipefail

# Pinned version = tag name = source revision in lib.nix.
tag=$(sed 's/[[:space:]]*$//' VERSION)

git push origin main

# The tag is created once. Moving it would change the source archive and
# invalidate the sha256 in lib.nix, while a warm store keeps serving the old
# archive - so the build would silently use the wrong tree.
if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
  echo "tag $tag exists (not moved)"
else
  git tag "$tag" main
  git push origin "$tag"
fi

# Drop the cached source archive so a re-tagged release is really re-fetched.
srcOut=$(nix-instantiate --eval -E 'toString (import ./lib.nix {}).src' 2>/dev/null || true)
[ -n "$srcOut" ] && nix-store --delete "$srcOut" 2>/dev/null || true

# Build from the tag. On a hash mismatch nix prints the correct value: put
# the "got:" hash into lib.nix, commit and push, then run this again.
nix-build
