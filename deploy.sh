#!/usr/bin/env bash
set -euo pipefail

# Push main branch
git push origin main

# Move tag 0.9.0 to current main
git tag -f 0.9.0 main
git push origin 0.9.0 --force

# Clear nix source cache so nix-build fetches the updated tag
nix-store --delete /nix/store/wm984fhmjl032h1ms94g0h1fg6894rc6-source 2>/dev/null || true
