#!/usr/bin/env bash
#
# Local coverage gate — mirrors .github/workflows/coverage.yml.
#
# Runs the unit tests WITH coverage for haven-core (Rust) and haven (Flutter)
# and fails if line coverage drops below the SAME thresholds CI enforces. Because
# it runs the suites, it also catches a failing test before it reaches CI: a
# single test panic fails the CI "Rust Coverage" job, since cargo-llvm-cov runs
# the whole suite. Wired as a pre-push hook (.githooks/pre-push); also runnable
# by hand:  scripts/ci/check_coverage.sh
#
# Thresholds (KEEP IN SYNC with coverage.yml) — override via env:
#   RUST_COVERAGE_MIN     (default 80)
#   FLUTTER_COVERAGE_MIN  (default 10)
# Select stacks (default: both) — handy for a quick manual run:
#   CHECK_RUST=0     skip the Rust (haven-core) gate
#   CHECK_FLUTTER=0  skip the Flutter (haven) gate
#
set -euo pipefail

RUST_MIN="${RUST_COVERAGE_MIN:-80}"
FLUTTER_MIN="${FLUTTER_COVERAGE_MIN:-10}"
CHECK_RUST="${CHECK_RUST:-1}"
CHECK_FLUTTER="${CHECK_FLUTTER:-1}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [ -t 1 ]; then
  BOLD=$'\033[1m'; RED=$'\033[31m'; GREEN=$'\033[32m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else
  BOLD=''; RED=''; GREEN=''; DIM=''; RESET=''
fi
info() { printf '%s\n' "$*"; }
ok()   { printf '%s✅ %s%s\n' "$GREEN" "$*" "$RESET"; }
err()  { printf '%s❌ %s%s\n' "$RED" "$*" "$RESET" >&2; }
die()  { err "$*"; exit 1; }

# Portable float compare: exit 0 (true) when $1 >= $2 (no `bc` dependency).
ge() { awk -v a="$1" -v b="$2" 'BEGIN { exit (a + 0 >= b + 0) ? 0 : 1 }'; }

rust_status="skipped"
flutter_status="skipped"

# ------------------------------- Rust (haven-core) --------------------------
if [ "$CHECK_RUST" = "1" ]; then
  command -v cargo >/dev/null 2>&1 || die "cargo not found on PATH."
  cargo llvm-cov --version >/dev/null 2>&1 \
    || die "cargo-llvm-cov not installed. Install with: cargo install cargo-llvm-cov"

  info "${BOLD}▶ Rust coverage (haven-core) — threshold ${RUST_MIN}%${RESET} ${DIM}(runs the test suite)${RESET}"
  # Exact flags from coverage.yml. This RUNS the tests: a test failure exits
  # non-zero here and fails the gate (so a broken/flaky test is caught too).
  if ! ( cd "$ROOT/haven-core" \
         && cargo llvm-cov --all-features \
              --ignore-filename-regex 'frb_generated' --summary-only ) \
         >"$TMP/rust.out" 2>"$TMP/rust.err"; then
    err "Rust tests/coverage run failed (test failure or build error):"
    tail -n 30 "$TMP/rust.err" >&2 || true
    tail -n 20 "$TMP/rust.out" >&2 || true
    exit 1
  fi
  # TOTAL line, column 10 = line-coverage % (matches coverage.yml's awk '{print $10}').
  rust_cov="$(grep -m1 'TOTAL' "$TMP/rust.out" | awk '{print $10}' | tr -d '%' || true)"
  [ -n "$rust_cov" ] || die "Could not parse Rust coverage from llvm-cov output."
  if ge "$rust_cov" "$RUST_MIN"; then
    ok "Rust (haven-core) line coverage ${rust_cov}% ≥ ${RUST_MIN}%"
    rust_status="pass"
  else
    err "Rust (haven-core) line coverage ${rust_cov}% is BELOW ${RUST_MIN}%"
    rust_status="fail"
  fi
fi

# -------------------------------- Flutter (haven) ---------------------------
if [ "$CHECK_FLUTTER" = "1" ]; then
  command -v flutter >/dev/null 2>&1 || die "flutter not found on PATH."

  info "${BOLD}▶ Flutter coverage (haven) — threshold ${FLUTTER_MIN}%${RESET} ${DIM}(runs flutter test --coverage)${RESET}"
  ( cd "$ROOT/haven" && flutter test --coverage ) \
    || { err "Flutter tests failed."; exit 1; }

  lcov_file="$ROOT/haven/coverage/lcov.info"
  [ -f "$lcov_file" ] || die "Coverage report not found: $lcov_file"
  # Compute line coverage (lines-hit / lines-found) over the SAME files CI keeps
  # — coverage.yml's `lcov --remove` filters — by parsing lcov.info directly, so
  # no `lcov` binary is required (only flutter + cargo-llvm-cov are needed).
  # Excluded: test/, generated FFI (src/rust/), *.g.dart, *.freezed.dart, and
  # generated localizations (l10n/app_localizations*.dart). This LH/LF ratio is
  # exactly the line-coverage metric very_good_coverage enforces in CI.
  flutter_cov="$(awk '
    /^SF:/ {
      sf = substr($0, 4)
      excl = (sf ~ /\/test\// || sf ~ /\/src\/rust\// || sf ~ /\.g\.dart$/ \
              || sf ~ /\.freezed\.dart$/ || sf ~ /\/l10n\/app_localizations[^\/]*\.dart$/)
    }
    /^LF:/ { if (!excl) lf += substr($0, 4) }
    /^LH:/ { if (!excl) lh += substr($0, 4) }
    END { if (lf > 0) printf "%.2f", (lh / lf) * 100; else print "0" }
  ' "$lcov_file" || true)"
  [ -n "$flutter_cov" ] || die "Could not compute Flutter coverage from $lcov_file."
  if ge "$flutter_cov" "$FLUTTER_MIN"; then
    ok "Flutter (haven) line coverage ${flutter_cov}% ≥ ${FLUTTER_MIN}%"
    flutter_status="pass"
  else
    err "Flutter (haven) line coverage ${flutter_cov}% is BELOW ${FLUTTER_MIN}%"
    flutter_status="fail"
  fi
fi

# ---------------------------------- Verdict ---------------------------------
info ""
info "${BOLD}Coverage gate:${RESET} rust=${rust_status}  flutter=${flutter_status}"
if [ "$rust_status" = "fail" ] || [ "$flutter_status" = "fail" ]; then
  die "Coverage below threshold (see above). Bypass a single push with: git push --no-verify"
fi
ok "Coverage gate passed."
