#!/usr/bin/env bash
# Point git at the tracked formal-verification hooks. Run once per clone.
# Reverse with: git config --unset core.hooksPath
set -euo pipefail
root="$(git rev-parse --show-toplevel)"
chmod +x "$root/verification/githooks/pre-commit"
git config core.hooksPath verification/githooks
echo "core.hooksPath -> verification/githooks (formal-verification pre-commit gate active)"
echo "Bypass a single commit with: git commit --no-verify   (or FV_GATE_SKIP=1 git commit)"
