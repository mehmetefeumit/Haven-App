#!/usr/bin/env bash
#
# Shared predicate: did the ON-DEVICE test suite actually fail, regardless of
# what `flutter drive` reported as its exit code?
#
# ## Why this exists
#
# `flutter drive` CAN EXIT 0 ON A FAILED TEST. Observed in CI run 30753193231:
# `e2e_profile_android` printed
#
#     I/flutter ( 3849): 00:01 +0: (setUpAll) [E]
#     I/flutter ( 3849):   set_profile_relays_for_test already installed
#     I/flutter ( 3849): 00:01 +1 -1: Some tests failed.
#
# and the harness recorded `flutter drive attempt 1/3 (rc=0)`. The lane went
# GREEN on a red test. The same scenario on iOS — which runs under
# `flutter test -d <udid>` rather than `flutter drive` — failed correctly, which
# is what exposed the split.
#
# The mechanism is `package:integration_test`: its binding collects per-test
# results from `testWidgets` bodies only, and `integrationDriver()` passes when
# that results map contains no failures. A failure in `setUpAll` /
# `tearDownAll` is never entered into the map, so the driver is told everything
# passed and exits 0. Anything that fails OUTSIDE a `testWidgets` body is
# therefore invisible to every `flutter drive`-based lane in this repo.
#
# That is the CI_HARDENING_BACKLOG.md thesis in its purest form — "CI verifies
# structure, logic and liveness, but almost never verifies delivery" — so the
# fix is not to trust the exit code but to read what the APP said.
#
# ## Usage
#
#   source "$(dirname "${BASH_SOURCE[0]}")/drive-log-lib.sh"
#   if drive_log_reports_test_failure /tmp/flutter-drive.log; then ... fi
#
#   bash tooling/e2e/ci/drive-log-lib.sh --self-test   # hermetic, no device
#
# Deliberately does NOT `set` shell options at source time: a sourced library
# that flips `-e`/`-E`/`pipefail` silently changes error handling in whatever
# runner picked it up. Options are set only on the direct-execution path at the
# foot of this file.

# Include guard — `readonly` below would abort a second source.
if [[ -n "${_HAVEN_DRIVE_LOG_LIB_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
_HAVEN_DRIVE_LOG_LIB_SOURCED=1

# App-side failure evidence, matched against the drive log (which carries the
# device's forwarded `I/flutter` output). Three independent signals so a
# reporter-format change cannot silently disable all of them:
#
#   1. `Some tests failed.` — the flutter_test reporter's own verdict.
#   2. A compact-reporter progress line with a NON-ZERO failure count
#      (`+3 -1:`). `-0` is never emitted, so `-[1-9]` cannot false-positive on
#      a clean run.
#   3. `(setUpAll) [E]` / `(tearDownAll) [E]` — the exact shape that is
#      invisible to integrationDriver, called out explicitly so this keeps
#      working even if the counters or the summary line ever change.
#
# Deliberately NOT matched: a bare `[E]`, which appears in unrelated device
# chatter, and `All tests passed.`, which is the DRIVER's claim rather than the
# app's and is precisely the string that lied in run 30753193231.
#   4. `All tests skipped.` — the app's summary when NOTHING ran.
#      `integrationDriver` treats an EMPTY results map as
#      `allTestsPassed == true`, so a target whose `main()` declares no
#      `testWidgets` (a bad conditional, a refactor that drops the call) is
#      green in every drive lane. A suite that ran nothing has proven nothing;
#      that is the same class of lie this whole predicate exists to catch.
#
# The counter rule tolerates an optional `~N` skipped column (`+3 ~1 -2:`) and
# accepts end-of-line as a terminator, because a drive killed mid-line — the
# exact case fixture 4 is meant to cover — loses the trailing separator.
readonly DRIVE_LOG_FAILURE_RE='Some tests failed\.|All tests skipped\.|\+[0-9]+( ~[0-9]+)? -[1-9][0-9]*([[:space:]:]|$)|\((setUpAll|tearDownAll)\) \[E\]'

# The reporter wraps the counter and the `[E]` marker in SGR escapes when
# colour is on (`_green + "+N" + _noColor + _red + " -M" + …`), which splits
# both patterns and would silently collapse the three signals down to
# `Some tests failed.` alone. Colour is off today only because of a hardcoded
# `_Reporter(color: false)` upstream — one literal away from breaking this. So
# strip SGR sequences before matching rather than depending on that.
_drive_log_decolour() {
  local esc
  esc="$(printf '\033')"
  sed "s/${esc}\\[[0-9;]*m//g" -- "$1" 2>/dev/null || true
}

# drive_log_reports_test_failure <logfile> — 0 (true) when the app reported a
# test failure. A missing or unreadable log returns 1 (no evidence of failure);
# callers already treat a missing drive log as their own error, and this
# predicate must never invent a failure it cannot see.
drive_log_reports_test_failure() {
  local log="${1:-}"
  [[ -f "${log}" ]] || return 1
  _drive_log_decolour "${log}" | grep -aqE -- "${DRIVE_LOG_FAILURE_RE}"
}

# Print the matching evidence lines (for the error message). Capped so a
# pathological log cannot flood the step output.
drive_log_failure_evidence() {
  local log="${1:-}"
  [[ -f "${log}" ]] || return 0
  _drive_log_decolour "${log}" \
    | grep -aE -- "${DRIVE_LOG_FAILURE_RE}" | head -10 || true
}

drive_log_lib_self_test() {
  local tmp fail=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  # (1) THE CRITICAL FIXTURE — verbatim from run 30753193231, including the
  #     driver's own contradicting "All tests passed." line. If this ever stops
  #     being detected, a setUpAll failure silently turns green again.
  printf '%s\n' \
    'I/flutter ( 3849): 00:00 +0: (setUpAll)' \
    'I/flutter ( 3849): [ScenarioHarness] bootstrapped role=ScenarioRole.solo relay=ws://10.0.2.2:7777' \
    'I/flutter ( 3849): 00:01 +0: (setUpAll) [E]' \
    'I/flutter ( 3849):   set_profile_relays_for_test already installed' \
    'All tests passed.' \
    'I/flutter ( 3849): 00:01 +1 -1: Some tests failed.' \
    > "${tmp}/setupall.log"
  if ! drive_log_reports_test_failure "${tmp}/setupall.log"; then
    echo "SELF-TEST FAIL (1): a setUpAll failure was NOT detected" >&2
    fail=1
  fi

  # (2) A clean run must NOT trip — including the driver's "All tests passed."
  #     and a passing counter with no failure component.
  printf '%s\n' \
    'I/flutter ( 3849): 00:00 +0: scenario A' \
    'I/flutter ( 3849): 00:12 +1: scenario B' \
    'I/flutter ( 3849): 00:31 +12: All tests passed!' \
    'All tests passed.' \
    > "${tmp}/clean.log"
  if drive_log_reports_test_failure "${tmp}/clean.log"; then
    echo "SELF-TEST FAIL (2): a clean run was flagged as failing" >&2
    fail=1
  fi

  # (3) An in-body test failure (the ordinary case, where drive DOES exit
  #     non-zero) must still be detected — the predicate is a belt to the
  #     exit code's braces, not a replacement scoped to setUpAll.
  printf '%s\n' \
    'I/flutter ( 3849): 00:44 +3 -1: scenario C [E]' \
    'I/flutter ( 3849): 00:45 +3 -1: Some tests failed.' \
    > "${tmp}/inbody.log"
  if ! drive_log_reports_test_failure "${tmp}/inbody.log"; then
    echo "SELF-TEST FAIL (3): an in-body test failure was NOT detected" >&2
    fail=1
  fi

  # (4) Counter-only failure, no summary line (a drive killed mid-run by a
  #     timeout never prints "Some tests failed.").
  printf '%s\n' \
    'I/flutter ( 3849): 02:10 +7 -2: scenario D' \
    > "${tmp}/counter.log"
  if ! drive_log_reports_test_failure "${tmp}/counter.log"; then
    echo "SELF-TEST FAIL (4): a non-zero failure counter was NOT detected" >&2
    fail=1
  fi

  # (5) A missing log is NOT evidence of failure — callers diagnose that
  #     themselves, and inventing a failure here would misattribute it.
  if drive_log_reports_test_failure "${tmp}/does-not-exist.log"; then
    echo "SELF-TEST FAIL (5): a missing log was reported as a test failure" >&2
    fail=1
  fi

  # (6) A scenario NAME containing the digits pattern must not false-positive.
  #     Guards the `-[1-9]` counter rule against ordinary prose.
  printf '%s\n' \
    'I/flutter ( 3849): 00:03 +2: circle 1-2 members sync' \
    'I/flutter ( 3849): 00:04 +3: epoch 3-1 rotation' \
    > "${tmp}/prose.log"
  if drive_log_reports_test_failure "${tmp}/prose.log"; then
    echo "SELF-TEST FAIL (6): ordinary prose was flagged as a failure counter" >&2
    fail=1
  fi

  # (7) ANSI-COLOURED reporter output. The escapes split the counter and the
  #     `[E]` marker; without de-colouring, two of the four signals die
  #     silently and nothing in a colourless fixture set would notice.
  printf 'I/flutter ( 3849): 00:01 +0: (setUpAll) \033[1m\033[31m[E]\033[0m\n' \
    > "${tmp}/ansi.log"
  if ! drive_log_reports_test_failure "${tmp}/ansi.log"; then
    echo "SELF-TEST FAIL (7): an ANSI-coloured setUpAll failure was NOT detected" >&2
    fail=1
  fi
  printf 'I/flutter ( 3849): \033[32m00:44 +3\033[0m\033[31m -1\033[0m: scenario C\n' \
    > "${tmp}/ansi-counter.log"
  if ! drive_log_reports_test_failure "${tmp}/ansi-counter.log"; then
    echo "SELF-TEST FAIL (7b): an ANSI-coloured failure counter was NOT detected" >&2
    fail=1
  fi

  # (8) MID-LINE TRUNCATION — a drive killed by a timeout loses the trailing
  #     separator after the counter. This is fixture 4's own stated scenario,
  #     which the original terminator-required regex did not actually cover.
  printf 'I/flutter ( 3849): 02:10 +7 -2' > "${tmp}/truncated.log"
  if ! drive_log_reports_test_failure "${tmp}/truncated.log"; then
    echo "SELF-TEST FAIL (8): a truncated failure counter was NOT detected" >&2
    fail=1
  fi

  # (9) VACUOUS SUITE — nothing ran. `integrationDriver` reports an EMPTY
  #     results map as all-passed and exits 0, so this is green in every drive
  #     lane without the signal. A suite that ran nothing proved nothing.
  printf '%s\n' \
    'I/flutter ( 3849): 00:00 +0: All tests skipped.' \
    'All tests passed.' \
    > "${tmp}/skipped.log"
  if ! drive_log_reports_test_failure "${tmp}/skipped.log"; then
    echo "SELF-TEST FAIL (9): a suite where NOTHING ran was NOT detected" >&2
    fail=1
  fi

  # (10) SKIPPED COLUMN present alongside a real failure (`+3 ~1 -2:`) — the
  #      counter rule must still fire with the `~N` column interposed.
  printf '%s\n' \
    'I/flutter ( 3849): 00:50 +3 ~1 -2: scenario E' \
    > "${tmp}/skipcol.log"
  if ! drive_log_reports_test_failure "${tmp}/skipcol.log"; then
    echo "SELF-TEST FAIL (10): a failure counter with a ~N column was NOT detected" >&2
    fail=1
  fi

  # (11) A clean run WITH a skipped column must still pass — `~N` alone is not
  #      a failure, and over-reading it would redden honest runs.
  printf '%s\n' \
    'I/flutter ( 3849): 00:50 +9 ~2: scenario F' \
    'I/flutter ( 3849): 00:51 +9 ~2: All tests passed!' \
    > "${tmp}/skipclean.log"
  if drive_log_reports_test_failure "${tmp}/skipclean.log"; then
    echo "SELF-TEST FAIL (11): a clean run with skipped tests was flagged" >&2
    fail=1
  fi

  if (( fail != 0 )); then
    echo "drive-log-lib.sh --self-test: FAILED" >&2
    return 1
  fi
  echo "drive-log-lib.sh --self-test: all 11 fixtures passed"
  return 0
}

# Executed directly (not sourced) with --self-test.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -Eeuo pipefail
  if [[ "${1:-}" == "--self-test" ]]; then
    drive_log_lib_self_test
    exit $?
  fi
  echo "drive-log-lib.sh is a sourced library; pass --self-test to verify it." >&2
  exit 2
fi
