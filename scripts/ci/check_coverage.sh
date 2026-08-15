#!/usr/bin/env bash
#
# Local coverage gate — a SUPERSET of .github/workflows/coverage.yml.
#
# ## What this is for
#
# Everything the coverage workflow can fail on, failing here first, on the
# machine that wrote the change. That is a stronger claim than "mirrors CI",
# which is what this script used to say while running four of the workflow's
# seven gates: the undeclared-skip check and the rollback-path flag-off run
# lived only in the Flutter Coverage job, so a green local gate was compatible
# with a red CI. It also measured Flutter coverage from the RAW lcov while CI
# measured it from a filtered one, and re-implemented the filter in awk rather
# than sharing it.
#
# The gates, in the order they run and against the workflow step each mirrors:
#
#   STATIC (no toolchain, no test run, well under a second)
#     1. coverage-floor manifest lint      -> repo-guards.yml
#     2. floors guard self-test            -> repo-guards.yml
#     3. lcov filter self-test             -> repo-guards.yml
#
#   RUST (haven-core)
#     4. suite runs green                  -> "Run tests with coverage"
#     5. aggregate >= 80%                  -> "Check coverage threshold"
#     6. per-path floors                   -> "Per-path coverage floors (haven-core)"
#
#   FLUTTER (haven)
#     7. suite runs green                  -> "Run tests with coverage"
#     8. no undeclared test skips          -> "No undeclared test skips"
#     9. rollback-path flag-off unit run   -> "Rollback-path flag-off unit check"
#    10. aggregate >= 50% on the FILTERED report
#                                          -> "Remove generated files" + "Check coverage threshold"
#    11. per-path floors on the same file  -> "Per-path coverage floors (haven)"
#
# The static gates run FIRST and alone. A hand-edited floor — the single most
# common way this workflow goes red — now costs 50 ms to discover instead of
# sixteen minutes, and the same three checks run in the pre-commit hook, so in
# practice it costs nothing at all.
#
# ## Measuring instrument
#
# Coverage percentages are ratios whose denominator is instrumented lines, which
# is a property of the compiler, not of the tests. scripts/ci/coverage_toolchain.env
# pins the rustc and Flutter versions the floors were measured with, and both
# this script and coverage.yml read it, so local numbers and CI numbers are
# comparable by construction. Measuring on a different rustc is refused rather
# than reported, because some floors are then UNSATISFIABLE (on 1.92,
# src/profile/fetch.rs tops out below its floor with every production line
# covered) and "add tests for the uncovered lines" would be advice for a gap no
# test can close.
#
# ## Usage
#
#   scripts/ci/check_coverage.sh                 # everything (~6-11 min, stacks in parallel)
#   scripts/ci/check_coverage.sh --static-only   # gates 1-3 only, instant
#   scripts/ci/check_coverage.sh --sequential    # one stack at a time
#   scripts/ci/check_coverage.sh --html          # also write HTML reports
#
# Wired as .githooks/pre-commit (--static-only) and .githooks/pre-push (full);
# enable both once per clone with scripts/ci/install_git_hooks.sh.
#
# Thresholds (KEEP IN SYNC with coverage.yml) — override via env:
#   RUST_COVERAGE_MIN     (default 80)
#   FLUTTER_COVERAGE_MIN  (default 50)
# Select stacks (default: both):
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

STATIC_ONLY=0
SEQUENTIAL=0
WANT_HTML=0
for arg in "$@"; do
  case "$arg" in
    --static-only) STATIC_ONLY=1 ;;
    --sequential)  SEQUENTIAL=1 ;;
    --html)        WANT_HTML=1 ;;
    -h|--help)
      sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; $d'
      exit 0
      ;;
    *) printf 'unknown option: %s (try --help)\n' "$arg" >&2; exit 2 ;;
  esac
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [ -t 1 ]; then
  BOLD=$'\033[1m'; RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else
  BOLD=''; RED=''; GREEN=''; YELLOW=''; DIM=''; RESET=''
fi
info() { printf '%s\n' "$*"; }
ok()   { printf '%s✅ %s%s\n' "$GREEN" "$*" "$RESET"; }
warn() { printf '%s⚠️  %s%s\n' "$YELLOW" "$*" "$RESET"; }
err()  { printf '%s❌ %s%s\n' "$RED" "$*" "$RESET" >&2; }
die()  { err "$*"; exit 1; }

# Portable float compare: exit 0 (true) when $1 >= $2 (no `bc` dependency).
ge() { awk -v a="$1" -v b="$2" 'BEGIN { exit (a + 0 >= b + 0) ? 0 : 1 }'; }

# --------------------------- measuring instrument ---------------------------
# Single source of truth, shared with coverage.yml. `HAVEN_COVERAGE_TOOLCHAIN`
# still overrides for a deliberate experiment; `none` measures with whatever
# rustc is default and accepts that the numbers are not comparable.
TOOLCHAIN_ENV="$SCRIPT_DIR/coverage_toolchain.env"
[ -f "$TOOLCHAIN_ENV" ] || die "missing $TOOLCHAIN_ENV — the pinned measuring toolchains."
# shellcheck disable=SC1090
. "$TOOLCHAIN_ENV"
COVERAGE_TOOLCHAIN="${HAVEN_COVERAGE_TOOLCHAIN:-${HAVEN_COVERAGE_RUST_TOOLCHAIN:?not set in coverage_toolchain.env}}"
COVERAGE_FLUTTER="${HAVEN_COVERAGE_FLUTTER_VERSION:?not set in coverage_toolchain.env}"

# ============================== static gates ================================
# No toolchain, no test run. These are the checks that can answer "will the
# coverage workflow reject this?" before anything is compiled, and they are the
# ones that catch the manifest edits that break it most often.
run_static() {
  local rc=0
  info "${BOLD}▶ Static coverage gates${RESET} ${DIM}(manifest lint + guard self-tests; no test run)${RESET}"

  if "$SCRIPT_DIR/check_coverage_floors.sh" --lint; then
    ok "Coverage-floor manifest obeys the pin rule"
  else
    err "Coverage-floor manifest lint failed — fix with: scripts/ci/check_coverage_floors.sh --lint --fix"
    rc=1
  fi

  if "$SCRIPT_DIR/check_coverage_floors.sh" --self-test >"$TMP/floors-selftest.log" 2>&1; then
    ok "Coverage-floors guard self-test"
  else
    err "Coverage-floors guard self-test FAILED — the guard itself cannot be trusted:"
    cat "$TMP/floors-selftest.log" >&2
    rc=1
  fi

  if "$SCRIPT_DIR/filter_lcov.sh" --self-test >"$TMP/filter-selftest.log" 2>&1; then
    ok "lcov filter self-test"
  else
    err "lcov filter self-test FAILED — the filter that defines which files count is broken:"
    cat "$TMP/filter-selftest.log" >&2
    rc=1
  fi

  if "$SCRIPT_DIR/check_lcov_aggregate.sh" --self-test >"$TMP/aggregate-selftest.log" 2>&1; then
    ok "lcov aggregate gate self-test"
  else
    err "lcov aggregate gate self-test FAILED — the 50% threshold check is broken:"
    cat "$TMP/aggregate-selftest.log" >&2
    rc=1
  fi

  info ""
  return "$rc"
}

# ================================ rust stack ================================
# Uses `return`, never `exit`: this function runs inside a background subshell
# whose exit code is captured after it, and an `exit` here would kill that
# subshell before its status was recorded — a stack that failed would then look
# like a stack that never ran.
stack_rust() {
  command -v cargo >/dev/null 2>&1 || { err "cargo not found on PATH."; return 1; }

  local cargo_bin=(cargo)
  if [ "$COVERAGE_TOOLCHAIN" != "none" ]; then
    if cargo "+$COVERAGE_TOOLCHAIN" --version >/dev/null 2>&1; then
      cargo_bin=(cargo "+$COVERAGE_TOOLCHAIN")
    else
      err "the coverage floors were measured on rustc ${COVERAGE_TOOLCHAIN} (scripts/ci/coverage_toolchain.env), which is not installed.
   Measuring on a different toolchain compares against floors it may be unable to satisfy.
   Install it:   rustup toolchain install ${COVERAGE_TOOLCHAIN}
   Or override:  HAVEN_COVERAGE_TOOLCHAIN=none scripts/ci/check_coverage.sh"
      return 1
    fi
  fi

  "${cargo_bin[@]}" llvm-cov --version >/dev/null 2>&1 \
    || { err "cargo-llvm-cov not installed for ${COVERAGE_TOOLCHAIN}. Install with: cargo +${COVERAGE_TOOLCHAIN} install cargo-llvm-cov"; return 1; }

  info "${BOLD}▶ Rust coverage (haven-core) — threshold ${RUST_MIN}%, rustc ${COVERAGE_TOOLCHAIN}${RESET}"

  # Exact flags AND env from coverage.yml. This RUNS the suite: a test failure
  # exits non-zero here, so a broken or flaky test is caught by the same command.
  #
  # HAVEN_TEST_WAIT_SCALE must match coverage.yml or this gate is not the CI
  # superset this script claims to be: the e2e anti-vacuity waits are sized for
  # an uninstrumented build, and under llvm-cov they expire on a loaded machine
  # while the same test passes in `cargo test`. Omitting it here made the local
  # gate STRICTER than CI on timing and looser on nothing — so a local red could
  # be a phantom, and the habit that teaches (re-run until green) is the one
  # that hides a real race.
  local rc=0
  ( cd "$ROOT/haven-core" \
    && HAVEN_TEST_WAIT_SCALE="${HAVEN_TEST_WAIT_SCALE:-4}" \
       "${cargo_bin[@]}" llvm-cov --all-features \
         --ignore-filename-regex 'frb_generated' --summary-only ) \
    >"$TMP/rust.out" 2>"$TMP/rust.err" || rc=$?
  if [ "$rc" -ne 0 ]; then
    err "Rust tests/coverage run failed (test failure or build error):"
    tail -n 40 "$TMP/rust.err" >&2 || true
    tail -n 20 "$TMP/rust.out" >&2 || true
    return 1
  fi

  local status=0 rust_cov
  # TOTAL line, column 10 = line-coverage % (matches coverage.yml's awk).
  rust_cov="$(grep -m1 'TOTAL' "$TMP/rust.out" | awk '{print $10}' | tr -d '%' || true)"
  # Same shape validation coverage.yml does: a parse failure used to pass this
  # gate silently, which is the worst outcome available to a coverage check.
  case "${rust_cov}" in
    ''|*[!0-9.]*) err "Could not parse a coverage percentage from llvm-cov (got: '${rust_cov}')"; return 1 ;;
  esac
  if ge "$rust_cov" "$RUST_MIN"; then
    ok "Rust (haven-core) line coverage ${rust_cov}% ≥ ${RUST_MIN}%"
  else
    err "Rust (haven-core) line coverage ${rust_cov}% is BELOW ${RUST_MIN}%"
    status=1
  fi

  # Per-path floors, on the SAME run. `llvm-cov report` re-renders the existing
  # profdata rather than executing the suite again, so this costs seconds and is
  # guaranteed to describe the run the percentage above came from.
  if "${cargo_bin[@]}" llvm-cov report --lcov --output-path "$TMP/rust.lcov" \
       --ignore-filename-regex 'frb_generated' \
       --manifest-path "$ROOT/haven-core/Cargo.toml" >/dev/null 2>&1; then
    "$SCRIPT_DIR/check_coverage_floors.sh" rust "$TMP/rust.lcov" || status=1
  else
    err "Could not render an lcov report for the per-path floors."
    status=1
  fi

  if [ "$WANT_HTML" = "1" ]; then
    ( cd "$ROOT/haven-core" && "${cargo_bin[@]}" llvm-cov report --html \
        --ignore-filename-regex 'frb_generated' ) >/dev/null 2>&1 \
      && info "   HTML report: haven-core/target/llvm-cov/html/index.html"
  fi

  return "$status"
}

# =============================== flutter stack ==============================
stack_flutter() {
  command -v flutter >/dev/null 2>&1 || { err "flutter not found on PATH."; return 1; }

  # Percentages are only comparable to CI's when measured on CI's SDK, for the
  # same reason the Rust job pins rustc: how many lines get instrumented is a
  # property of the toolchain, not of the tests. rustc is required outright
  # below because `rustup toolchain install` makes matching free; there is no
  # equivalent for Flutter, so a mismatch is handled instead of refused — but
  # handled HONESTLY. On a mismatched SDK the RATIO-based verdicts (aggregate,
  # per-path floors) become advisory, while the SDK-independent ones (tests
  # green, no undeclared skips, the flag-off run) still gate. A gate that fails
  # on a number it knows it cannot measure is a gate that teaches --no-verify,
  # and a `--repin` taken from one would write floors CI cannot satisfy.
  local have advisory=0
  have="$(flutter --version 2>/dev/null | awk '/^Flutter /{print $2; exit}')"
  if [ -z "$have" ]; then
    advisory=1
    warn "could not determine the local Flutter version — treating coverage percentages as advisory."
  elif [ "$have" != "$COVERAGE_FLUTTER" ]; then
    advisory=1
    warn "local Flutter ${have} != pinned ${COVERAGE_FLUTTER} (scripts/ci/coverage_toolchain.env)."
    warn "   Instrumented-line counts differ between SDKs, so Flutter coverage percentages"
    warn "   below are ADVISORY — reported, but not gating. Tests, skips and the flag-off"
    warn "   run are SDK-independent and still gate. Install ${COVERAGE_FLUTTER} for a predictive gate."
    printf '%s\n' "$have" >"$TMP/flutter.sdk-mismatch"
  fi

  info "${BOLD}▶ Flutter coverage (haven) — threshold ${FLUTTER_MIN}%, SDK pin ${COVERAGE_FLUTTER}${RESET}"

  local status=0 report="$TMP/flutter-test-report.json"

  # `--file-reporter` writes machine-readable per-test verdicts ALONGSIDE the
  # console reporter, which is what the skip gate reads. Same flag CI passes,
  # and it costs no second run.
  ( cd "$ROOT/haven" && flutter test --coverage --file-reporter=json:"$report" ) \
    || { err "Flutter tests failed."; return 1; }

  # Gate: CI's "No undeclared test skips". Lived only in the workflow, so a
  # newly-skipped test passed here and failed there.
  if "$SCRIPT_DIR/check_no_undeclared_skips.sh" dart flutter "$report"; then
    ok "No undeclared test skips (dart/flutter)"
  else
    err "Undeclared test skips — see scripts/ci/expected_test_skips.txt"
    status=1
  fi

  # Gate: CI's "Rollback-path flag-off unit check". Production defaults
  # liveSyncEnabled ON, so the retained short-poll fallback branches are dead
  # code in the run above; these two files re-run with the flag OFF to keep the
  # rollback path's assertions executing. Also absent from this gate until now.
  if ( cd "$ROOT/haven" && flutter test \
         test/providers/identity_provider_test.dart \
         test/providers/location_sharing_provider_test.dart \
         --dart-define=HAVEN_LIVE_SYNC=false ) >"$TMP/flagoff.log" 2>&1; then
    ok "Rollback-path flag-off unit check (retained short-poll path)"
  else
    err "Rollback-path flag-off unit check failed:"
    tail -n 40 "$TMP/flagoff.log" >&2 || true
    status=1
  fi

  local raw="$ROOT/haven/coverage/lcov.info"
  [ -f "$raw" ] || { err "Coverage report not found: $raw"; return 1; }

  # The SAME filter CI applies, from the SAME script — not a second awk
  # implementation of the same five patterns, which is what used to let the two
  # disagree about which files count.
  local filtered="$ROOT/haven/coverage/lcov_filtered.info"
  "$SCRIPT_DIR/filter_lcov.sh" "$raw" "$filtered" 2>/dev/null \
    || { err "Could not filter the Flutter coverage report."; return 1; }

  # The SAME script coverage.yml runs, on the same filtered report — not a
  # second awk of the same sum. Its exit code distinguishes "below threshold"
  # (1) from "the report is not measurable" (2), and only the former is
  # something an SDK mismatch can fake.
  local arc=0
  "$SCRIPT_DIR/check_lcov_aggregate.sh" "$filtered" "$FLUTTER_MIN" "Flutter (haven)" || arc=$?
  if [ "$arc" -eq 1 ] && [ "$advisory" = "1" ]; then
    warn "…aggregate verdict is ADVISORY (SDK mismatch)."
  elif [ "$arc" -ne 0 ]; then
    status=1
  fi

  # Per-path floors read the FILTERED report, as coverage.yml does. Reading the
  # raw one was defensible only as long as no pinned path fell inside the
  # removal set, an invariant nothing checked and any new row could break.
  if ! "$SCRIPT_DIR/check_coverage_floors.sh" flutter "$filtered"; then
    if [ "$advisory" = "1" ]; then
      warn "Per-path floor verdicts above are ADVISORY — measured on Flutter ${have:-unknown}, not the pinned ${COVERAGE_FLUTTER}."
      warn "   Do NOT re-pin the manifest from this run: --repin needs CI's SDK, or it writes floors CI cannot satisfy."
    else
      status=1
    fi
  fi

  if [ "$WANT_HTML" = "1" ]; then
    if command -v genhtml >/dev/null 2>&1; then
      genhtml "$filtered" -o "$ROOT/haven/coverage/html" --quiet \
        && info "   HTML report: haven/coverage/html/index.html"
    else
      warn "genhtml not installed (apt install lcov / brew install lcov) — skipped HTML report."
    fi
  fi

  return "$status"
}

# ================================ execution =================================
if ! run_static; then
  die "Static coverage gates failed. Nothing was compiled — fix the above and re-run (it is instant)."
fi
if [ "$STATIC_ONLY" = "1" ]; then
  ok "Static coverage gates passed."
  exit 0
fi

rust_status="skipped"
flutter_status="skipped"

# Run one stack, capturing its output and its verdict. Written so a stack that
# dies mid-way still records a FAILURE: an absent status file is treated as a
# failure by the reader below, never as a skip.
spawn() { # <name> <fn>
  local name="$1" fn="$2"
  ( rc=0; "$fn" >"$TMP/$name.log" 2>&1 || rc=$?; printf '%s\n' "$rc" >"$TMP/$name.rc" )
}

# `if`, not `[ … ] && …`: under `set -e` a false test at the end of a top-level
# AND-list exits the script, so the "skip the Rust stack" switch would have
# silently aborted the whole gate instead of running Flutter.
wanted=()
if [ "$CHECK_RUST" = "1" ]; then wanted+=("rust"); fi
if [ "$CHECK_FLUTTER" = "1" ]; then wanted+=("flutter"); fi
[ "${#wanted[@]}" -gt 0 ] || die "Both stacks disabled (CHECK_RUST=0 CHECK_FLUTTER=0) — nothing would be verified."

if [ "$SEQUENTIAL" = "1" ] || [ "${#wanted[@]}" -eq 1 ]; then
  for name in "${wanted[@]}"; do
    spawn "$name" "stack_$name"
    cat "$TMP/$name.log"
  done
else
  # The two stacks share nothing — different toolchains, different build
  # directories, different reports — so running them in series only ever cost
  # wall clock. Overlapping them turns the gate from sum-of-both into
  # slowest-of-both, which is the difference between a hook people keep and a
  # hook people reach for --no-verify to avoid.
  info "${BOLD}▶ Running both stacks in parallel${RESET} ${DIM}(use --sequential for interleaved live output)${RESET}"
  pids=()
  for name in "${wanted[@]}"; do
    spawn "$name" "stack_$name" &
    pids+=("$!")
  done

  # Heartbeat, so a ten-minute wait does not look like a hang.
  start="$SECONDS"
  while :; do
    running=()
    for i in "${!pids[@]}"; do
      if kill -0 "${pids[$i]}" 2>/dev/null; then running+=("${wanted[$i]}"); fi
    done
    [ "${#running[@]}" -gt 0 ] || break
    # Only on a terminal: the carriage returns that make this a live counter
    # turn into one enormous line in a captured log or a CI transcript.
    if [ -t 1 ]; then
      printf '\r%s   … %ss elapsed — still running: %s%s   ' \
        "$DIM" "$((SECONDS - start))" "${running[*]}" "$RESET"
    fi
    sleep 5
  done
  if [ -t 1 ]; then printf '\r%*s\r' 70 ''; fi
  wait || true

  for name in "${wanted[@]}"; do
    printf '%s\n' "${BOLD}────────────────────────────── ${name} ──────────────────────────────${RESET}"
    cat "$TMP/$name.log"
  done
fi

for name in "${wanted[@]}"; do
  # A missing .rc means the stack was killed before it could record a verdict.
  # That is a failure, not a skip: the alternative is a gate that passes when
  # its own runner dies.
  rc="$(cat "$TMP/$name.rc" 2>/dev/null || echo 1)"
  if [ "$rc" = "0" ]; then eval "${name}_status=pass"; else eval "${name}_status=fail"; fi
done

# ---------------------------------- verdict ---------------------------------
info ""
info "${BOLD}Coverage gate:${RESET} rust=${rust_status}  flutter=${flutter_status}"
if [ "$rust_status" = "fail" ] || [ "$flutter_status" = "fail" ]; then
  die "Coverage gate failed (see above). Bypass a single push with: git push --no-verify"
fi
if [ -f "$TMP/flutter.sdk-mismatch" ]; then
  warn "Flutter coverage percentages were ADVISORY this run (SDK $(cat "$TMP/flutter.sdk-mismatch") != pinned ${COVERAGE_FLUTTER})."
  warn "   The Flutter aggregate and per-path floors are the one part of this gate that did NOT predict CI."
fi
ok "Coverage gate passed — this is every gate .github/workflows/coverage.yml runs."
