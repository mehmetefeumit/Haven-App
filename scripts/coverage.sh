#!/usr/bin/env bash
#
# Coverage for local development — reports AND gates, in one command.
#
# This used to be a third, independent way of computing Haven's coverage, and
# the numbers it printed were not the numbers anything enforced:
#
#   * it excluded `(frb_generated\.rs|\.g\.rs)` where CI excludes `frb_generated`,
#   * it measured `rust_builder` as well, which no gate covers,
#   * it read Flutter's RAW lcov, where CI reads the filtered one,
#   * it measured on whatever toolchain happened to be default, where the
#     per-path floors are pinned to a specific rustc/LLVM,
#   * and it applied no thresholds at all, so it printed a cheerful summary for
#     a tree that CI would reject.
#
# Three implementations of one measurement is three answers, and the one people
# ran by hand was the one that agreed with nothing. So this is now a thin front
# end on the real gate: same flags, same filters, same toolchain pins, same
# thresholds, plus the HTML reports that made this script worth having.
#
#   scripts/coverage.sh                # both stacks, gated, with HTML reports
#   scripts/ci/check_coverage.sh       # the gate itself (no HTML) — pre-push hook
#   scripts/ci/check_coverage.sh --static-only   # instant manifest/guard checks
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "📊 Coverage for Haven — running the same gates CI does, plus HTML reports."
echo ""

exec "$SCRIPT_DIR/ci/check_coverage.sh" --html "$@"
