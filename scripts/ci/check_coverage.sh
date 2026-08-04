#!/usr/bin/env bash
#
# Local coverage gate — mirrors .github/workflows/coverage.yml.
#
# Runs the unit tests WITH coverage for haven-core (Rust) and haven (Flutter)
# and fails if line coverage drops below the SAME thresholds CI enforces —
# both the global aggregates AND the per-path floors in
# scripts/ci/coverage_floors.txt (check_coverage_floors.sh), because an
# aggregate is a shared budget that cannot see one critical file emptying out.
#
# Because it runs the suites, it also catches a failing test before it reaches CI: a
# single test panic fails the CI "Rust Coverage" job, since cargo-llvm-cov runs
# the whole suite. Wired as a pre-push hook (.githooks/pre-push); also runnable
# by hand:  scripts/ci/check_coverage.sh
#
# Thresholds (KEEP IN SYNC with coverage.yml) — override via env:
#   RUST_COVERAGE_MIN     (default 80)
#   FLUTTER_COVERAGE_MIN  (default 50)
# Select stacks (default: both) — handy for a quick manual run:
#   CHECK_RUST=0     skip the Rust (haven-core) gate
#   CHECK_FLUTTER=0  skip the Flutter (haven) gate
#
set -euo pipefail

RUST_MIN="${RUST_COVERAGE_MIN:-80}"
FLUTTER_MIN="${FLUTTER_COVERAGE_MIN:-50}"
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

# The toolchain the per-path floors in coverage_floors.txt were MEASURED with.
#
# This is not a style preference — it is what makes the comparison meaningful.
# The floors' denominator is INSTRUMENTED LINES, which is a property of the
# LLVM version, not of the tests. Measuring here on an older toolchain reads
# every path 1-4 points lower than the pin, and for some rows the floor then
# becomes UNSATISFIABLE: on rustc 1.92 against the current pins,
# `src/profile/fetch.rs` tops out at 96.26% under a floor of 97 and
# `src/keyring_policy.rs` at 88.00% under a floor of 89 — with EVERY remaining
# production line covered, because the rest are assertion-failure messages that
# only execute when a test fails. A developer hitting that would be told to
# "add tests for the uncovered lines" for a gap no test can close.
#
# So the gate pins the measuring toolchain to the one the floors came from, and
# says so loudly if it is missing rather than silently measuring something
# incomparable. Re-pinning the floors and bumping this belong in ONE commit.
COVERAGE_TOOLCHAIN="${HAVEN_COVERAGE_TOOLCHAIN:-1.97.1}"

# ------------------------------- Rust (haven-core) --------------------------
if [ "$CHECK_RUST" = "1" ]; then
  command -v cargo >/dev/null 2>&1 || die "cargo not found on PATH."

  # Resolve the pinned toolchain, or explain exactly how to get it. `+none`
  # opts out (measure with whatever is default) for a deliberate experiment.
  cargo_bin=(cargo)
  if [ "$COVERAGE_TOOLCHAIN" != "none" ]; then
    if cargo "+$COVERAGE_TOOLCHAIN" --version >/dev/null 2>&1; then
      cargo_bin=(cargo "+$COVERAGE_TOOLCHAIN")
    else
      die "the coverage floors were measured on rustc ${COVERAGE_TOOLCHAIN}, which is not installed.
   Measuring on a different toolchain compares against floors it may be unable to satisfy.
   Install it:   rustup toolchain install ${COVERAGE_TOOLCHAIN}
   Or override:  HAVEN_COVERAGE_TOOLCHAIN=none scripts/ci/check_coverage.sh"
    fi
  fi

  "${cargo_bin[@]}" llvm-cov --version >/dev/null 2>&1 \
    || die "cargo-llvm-cov not installed for ${COVERAGE_TOOLCHAIN}. Install with: cargo install cargo-llvm-cov"

  info "${BOLD}▶ Rust coverage (haven-core) — threshold ${RUST_MIN}%${RESET} ${DIM}(runs the test suite)${RESET}"
  # Exact flags from coverage.yml. This RUNS the tests: a test failure exits
  # non-zero here and fails the gate (so a broken/flaky test is caught too).
  if ! ( cd "$ROOT/haven-core" \
         && "${cargo_bin[@]}" llvm-cov --all-features \
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

  # Per-path floors (coverage.yml runs the same guard on its own lcov). The
  # aggregate above is a budget the whole crate shares — ~2290 lines of slack
  # over the 80% line — so it cannot see a single critical file emptying out.
  # `llvm-cov report` re-renders the run above from its existing profdata
  # instead of executing the suite a second time, so this costs seconds and is
  # guaranteed to describe the SAME run the percentage came from.
  if "${cargo_bin[@]}" llvm-cov report --lcov --output-path "$TMP/rust.lcov" \
       --ignore-filename-regex 'frb_generated' \
       --manifest-path "$ROOT/haven-core/Cargo.toml" >/dev/null 2>&1; then
    if ! "$SCRIPT_DIR/check_coverage_floors.sh" rust "$TMP/rust.lcov"; then
      rust_status="fail"
    fi
  else
    err "Could not render an lcov report for the per-path floors (skipped)."
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

  # Per-path floors, as in coverage.yml. The raw report is used rather than the
  # workflow's `lcov --remove` output: no pinned path is in the removal set
  # (test/, src/rust/, *.g.dart, *.freezed.dart, generated l10n), so the two
  # produce identical verdicts and this needs no `lcov` binary — same reason
  # the aggregate above is computed by parsing lcov.info directly.
  if ! "$SCRIPT_DIR/check_coverage_floors.sh" flutter "$lcov_file"; then
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
