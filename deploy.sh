#!/usr/bin/env bash
set -euo pipefail

# Push main and move the release tag onto it
git push origin main
git tag -f 0.9.0 main
git push origin 0.9.0 --force

# Build from the tag. On a hash mismatch nix prints the correct value:
# copy the "got:" hash into lib.nix (src sha256 or mixDeps hash) and rerun.
nix-build
