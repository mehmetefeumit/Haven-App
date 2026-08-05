#!/usr/bin/env bash
#
# One-time setup: point git at the version-controlled hooks in .githooks/.
#
# core.hooksPath is a LOCAL git setting (not committed), so each clone runs this
# once. After that:
#
#   pre-commit  scripts/ci/check_coverage.sh --static-only   (< 1 s, every commit)
#               The coverage-floor manifest lint and the two guard self-tests.
#               No toolchain, no test run — this is the half of the coverage
#               gate that catches a bad manifest edit in the diff that made it.
#
#   pre-push    scripts/ci/check_coverage.sh                 (~6-11 min)
#               The full superset of CI's Coverage job: both suites with
#               coverage, both aggregates, the per-path floors, the
#               undeclared-skip check and the rollback-path flag-off run.
#
#   Enable:  scripts/ci/install_git_hooks.sh
#   Disable: git config --unset core.hooksPath
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

chmod +x .githooks/* scripts/ci/check_coverage.sh scripts/ci/check_coverage_floors.sh \
         scripts/ci/filter_lcov.sh 2>/dev/null || true
git config core.hooksPath .githooks

echo "✅ Git hooks enabled (core.hooksPath = .githooks)."
echo "   'git commit' now runs the instant coverage checks (manifest lint + guard self-tests)."
echo "   'git push'   now runs the full coverage gate (~6-11 min, both stacks in parallel)."
echo "   Bypass once with: git commit --no-verify / git push --no-verify"
echo "   Disable entirely: git config --unset core.hooksPath"
echo ""

# A pinned measuring toolchain is only useful if it is installed; say so now
# rather than at the end of the first ten-minute push.
# shellcheck disable=SC1091
. scripts/ci/coverage_toolchain.env
if command -v cargo >/dev/null 2>&1 \
   && ! cargo "+${HAVEN_COVERAGE_RUST_TOOLCHAIN}" --version >/dev/null 2>&1; then
  echo "⚠️  rustc ${HAVEN_COVERAGE_RUST_TOOLCHAIN} (the pinned coverage toolchain) is not installed."
  echo "    The Rust gate will refuse to measure without it: rustup toolchain install ${HAVEN_COVERAGE_RUST_TOOLCHAIN}"
fi
have_flutter="$(flutter --version 2>/dev/null | awk '/^Flutter /{print $2; exit}' || true)"
if [ -n "${have_flutter}" ] && [ "${have_flutter}" != "${HAVEN_COVERAGE_FLUTTER_VERSION}" ]; then
  echo "⚠️  local Flutter ${have_flutter} != pinned ${HAVEN_COVERAGE_FLUTTER_VERSION}."
  echo "    Flutter coverage percentages will be reported but ADVISORY (they will not match CI)."
fi
