#!/usr/bin/env bash
#
# One-time setup: point git at the version-controlled hooks in .githooks/.
#
# core.hooksPath is a LOCAL git setting (not committed), so each clone runs this
# once. After that, `git push` runs the coverage gate (scripts/ci/check_coverage.sh).
#
#   Enable:  scripts/ci/install_git_hooks.sh
#   Disable: git config --unset core.hooksPath
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

chmod +x .githooks/* scripts/ci/check_coverage.sh 2>/dev/null || true
git config core.hooksPath .githooks

echo "✅ Git hooks enabled (core.hooksPath = .githooks)."
echo "   'git push' now runs the coverage gate (scripts/ci/check_coverage.sh, ~4-6 min)."
echo "   Bypass a single push with: git push --no-verify"
echo "   Disable entirely with:     git config --unset core.hooksPath"
