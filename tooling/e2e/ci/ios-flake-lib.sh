#!/usr/bin/env bash
#
# iOS E2E retry classifier — may this failed attempt be retried?
#
# ## Why this exists
#
# Both iOS lanes wrap their scenario step in `nick-fields/retry@v3` with
# `max_attempts: 2` and NO `retry_on` filter, so the action's default (`any`)
# applies: EVERY non-zero exit is retried, a genuine assertion failure exactly
# like a simulator that never launched. A blanket retry is how a real,
# reproducible red becomes a green on the second roll of the dice — the same
# defect family as a drive-log predicate that let `flutter drive` exit 0 on a
# failed suite (drive-log-lib.sh) and a secret scanner that passed when its
# input was missing (scan-logs-for-secrets.sh).
#
# ## What the evidence actually shows (97 iOS jobs / 156 attempts, 2026-07-13
# ## to 2026-08-03; `gh api .../actions/jobs/<id>/logs`)
#
# 19 attempts failed FAST with reporter output naming the failure — e.g.
# `::error::9 tests passed, 1 failed.` (job 89823392716), the FE-2 member-count
# TestFailure (job 88159861218), the `set_profile_relays_for_test already
# installed` setUpAll throw (job 91511139791, run 30753193231). Every one of
# them was retried. Each wasted retry costs a full Xcode rebuild (~7-11 min
# measured) plus the suite; more importantly, nothing stood between any of them
# and a green second attempt.
#
# 8 attempts failed with ONE other signature, and it is the same signature every
# time:
#
#     Running Xcode build...
#     Xcode build done.                                           651.8s
#     <silence until the attempt timeout>
#
# The app built and installed, then the suite never started — no reporter line
# was ever emitted. 4 of those recovered on attempt 2 and made the job green
# (jobs 87659255503, 89910560604, 90020055233, 91461087399); the other 4 were
# retried into a genuine failure. This is the documented "~10% iOS-simulator
# launch/attach flake (which presents as a HANG, not a fast fail)" the workflow
# comments already claimed, now confirmed: ~5% of attempts, always post-build
# and always pre-test.
#
# CI run 35690725254 (job 106630995666, 2026-09-22) measured the TOOL'S OWN
# spelling of that same signature:
#
#     Xcode build done.                                           647.3s
#     No tests ran.
#     Error waiting for a debug connection: The log reader failed unexpectedly
#     <the process never exits; the outer 30-minute timeout kills the attempt>
#
# flutter_tools printed those two lines itself — lib/src/ios/simulators.dart
# prints exactly that pair when the launched app never publishes a VM-service
# URI and it returns `LaunchResult.failed()`. The app built and installed and no
# Dart code ever ran: the same fact the watchdog infers from silence, stated by
# the tool. It is admitted below as a second FORM of the one signature, never as
# a second signature — every other clause still has to hold, and "no test ran"
# here is the tool's own account rather than our inference.
#
# That is the ONE signature admitted here. Nothing else observed in that window
# is retryable, and no signature is admitted that has not been seen — an invented
# pattern is indistinguishable from a blanket retry with extra steps.
#
# ## The shape of the check
#
# A stall cannot be recognised from the log alone: "built, then nothing" and
# "built, then killed by the outer step timeout while a test was running" look
# identical once the process is gone. So run-ios-sim-scenario.sh runs its own
# first-test watchdog on a deadline SHORTER than the attempt timeout and, when it
# fires, records that fact THREE ways: IOS_STALL_MARKER into the log, an empty
# `<log>.stall` flag, and a `<log>.prekill` snapshot of the log as it stood at the
# moment it decided. That is this classifier's required positive evidence: all of
# it is written by our code, at a moment when our code could still see that no
# test had started. The flag and the snapshot exist because the log is the one
# artefact the process we are about to kill can still write to — see the
# out-of-band evidence block below, and CI run 30964250098.
#
# `ios_log_is_launch_stall` then demands, on top of that marker, that the build
# completed, that NOTHING in the log shows a test ran, and that
# drive-log-lib.sh's independent app-side failure predicate is silent — so a
# suite that actually failed can never be retried, whichever reporter it used.
#
# ## The retry gate
#
# `nick-fields/retry` has no predicate input; it cannot be told "not this one".
# So the decision is carried across attempts in a verdict file, and it FAILS
# CLOSED: the file is stamped `unproven` before the suite starts, and only an
# attempt that reaches classification and proves a stall upgrades it to
# `retryable`. An attempt that is SIGKILLed, crashes, or dies any way that skips
# classification leaves `unproven` behind, and the next attempt refuses to run.
# Absence of evidence is not evidence of a flake.
#
# ## Usage
#
#   source "$(dirname "${BASH_SOURCE[0]}")/ios-flake-lib.sh"
#   ios_retry_gate "$(ios_retry_verdict_file "${SCENARIO_FILE}")" || exit $?
#
#   bash tooling/e2e/ci/ios-flake-lib.sh --self-test   # hermetic, no simulator
#
# Deliberately does NOT `set` shell options at source time, for the same reason
# drive-log-lib.sh does not: a sourced library that flips `-e`/`pipefail`
# silently changes error handling in whatever runner picked it up. Options are
# set only on the direct-execution path at the foot of this file.

# Include guard — `readonly` below would abort a second source.
if [[ -n "${_HAVEN_IOS_FLAKE_LIB_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
_HAVEN_IOS_FLAKE_LIB_SOURCED=1

# The app-side failure predicate is REUSED, not reimplemented: a lane must never
# retry a run whose suite actually failed, and drive-log-lib.sh is where that
# question is already answered (and self-tested against a verbatim CI log in
# which the driver claimed "All tests passed." over a failed setUpAll).
# shellcheck source=tooling/e2e/ci/drive-log-lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/drive-log-lib.sh"

# The literal `flutter test` prints when the Xcode build phase has finished, i.e.
# the last thing between "we are compiling" and "the app should now launch on the
# simulator". Everything after it is install + launch + attach + run.
#
# Rot direction, stated explicitly because nothing hermetic can pin a literal
# owned by the Flutter SDK: if this string ever changes, the watchdog never arms
# and the classifier never finds its build evidence, so stalls stop being
# retried and the lane simply goes red on them. That is the SAFE direction —
# noisier, never quieter — and a red lane is what prompts someone to look. The
# unsafe direction (a changed literal that starts matching genuine failures) is
# not reachable: every other clause still has to hold.
readonly IOS_BUILD_DONE_MARKER='Xcode build done.'

# Written into the test log by run-ios-sim-scenario.sh's first-test watchdog, and
# ONLY by it. This is the classifier's required positive evidence, so it must
# stay in sync with the string the runner appends; the runner's --self-test
# drives the real watchdog and then asserts this classifier accepts its output,
# which is what stops the two drifting apart.
readonly IOS_STALL_MARKER='IOS-WATCHDOG: no on-device test started'

# The exact line the watchdog appends. Built HERE, not in the runner, so the
# producer and the classifier cannot drift apart. Deliberately does not quote the
# `Xcode build done.` literal: that string is the classifier's separate evidence
# that the build finished, and a marker line containing it would let the watchdog
# satisfy that clause by talking about itself (see ios_log_is_launch_stall).
ios_stall_marker_line() {
  echo "${IOS_STALL_MARKER} within ${1}s of the Xcode build finishing — killing a pre-test simulator launch/attach stall."
}

# ---------------------------------------------------------------------------
# Out-of-band stall evidence.
#
# The marker above was the classifier's ONLY positive evidence, and it lived in
# the one file the process we are about to kill can still write to. In CI run
# 30964250098 that lost us a sanctioned retry: `flutter test` traps SIGTERM and
# prints "\n🎉 0 tests passed.\n" on its way out — 22 bytes, written at the
# child's OWN file offset, landing exactly on the 22-byte prefix
# "IOS-WATCHDOG: no on-de" the watchdog had just appended. The marker was
# mangled into "vice test started within 300s…", so clause (b) failed; and the
# teardown line matched the test-start predicate, so clause (d) failed too. Verdict:
# `genuine`, retry refused, lane red on an infrastructure stall the watchdog had
# correctly identified.
#
# The runner now writes at EOF (append mode) so that overwrite cannot recur, but
# a log a dying process still holds a descriptor to is the wrong place to keep
# the verdict at all. So the watchdog additionally deposits, BEFORE it signals:
#
#   <log>.stall    an empty flag file — existence is the whole message
#   <log>.prekill  a snapshot of the log at the instant it decided to kill
#
# Both are written only on the kill path, only after the watchdog has re-checked
# that the process is alive and that no test activity exists. A suite that fails
# on its own exits without the watchdog ever firing, so neither file can appear
# for a genuine failure. Classification then reads the snapshot — a strict PREFIX
# of what the run emitted, ending before we intervened — so every veto still
# applies to everything the suite actually said, and only our own SIGTERM's
# artefacts are excluded. This is the pattern run-single-avd-scenario.sh already
# uses for its Android pre-connect stall verdict.
# ---------------------------------------------------------------------------

# ios_stall_flag_path <log> — the out-of-band "the watchdog killed this" flag.
ios_stall_flag_path() { printf '%s' "${1:-}.stall"; }

# ios_prekill_log_path <log> — the log as it stood when the watchdog decided.
ios_prekill_log_path() { printf '%s' "${1:-}.prekill"; }

# ios_clear_stall_evidence <log> — drop any prior attempt's flag and snapshot.
# Attempt 2 must never inherit attempt 1's verdict: that is precisely the
# blanket retry this lane exists to prevent.
ios_clear_stall_evidence() {
  local log="${1:-}"
  [[ -n "${log}" ]] || return 0
  rm -f "$(ios_stall_flag_path "${log}")" "$(ios_prekill_log_path "${log}")"
}

# WHAT COUNTS AS "A TEST STARTED" — and, since CI run 35690725254, what does not.
#
# One predicate answers one question for two callers: run-ios-sim-scenario.sh's
# watchdog ("the suite is running, stand down") and clause (d) below ("a test
# ran, so this is not a launch stall"). Both need a test-START event, and the
# predicate this replaces matched the wrong thing twice over:
#
#   1. It scanned the WHOLE log. The expanded reporter's first line is
#      `00:00 +0: loading <suite>.dart`, printed while the suite is being LOADED
#      — before flutter_tools has even started the Xcode build (green run
#      35664400984: `loading` at 23:37:55, `Xcode build done.` at 23:51:37, the
#      first test at 23:52:20). It matched the progress-line alternative, so on
#      the FIRST poll after arming the watchdog concluded the suite had spoken.
#      The watchdog could not fire at all on current Flutter output, and clause
#      (d) was unsatisfiable with it.
#   2. `No tests ran.` was in the set — the line the expanded reporter prints
#      when the engine finished with ZERO live tests, i.e. the exact opposite of
#      a test starting.
#
# So: only the SUFFIX after the build marker is scanned, and a suite LOAD is not
# a start. What a progress line's subject can be is enumerated by the reporter
# itself (test_core's runner/reporter/expanded.dart): a test's name — with
# `(setUpAll)` and `(tearDownAll)` ordinary synthetic test names — `loading
# <path>`, and the `All tests passed!` / `All tests skipped.` / `Some tests
# failed.` summaries. `No tests ran.` is NOT among them: it is written bare,
# with no `HH:MM +N:` prefix, which is why nothing below has to name it.
# Excluding `loading` therefore leaves only subjects that imply a test ran, and
# the three summaries need no rule of their own — none is reachable without a
# live test, so none can precede a start line.
#
# This mirrors tooling/logscan/policy.toml's `proof_of_run_excludes`, which
# subtracts the same suite-load shape from the same question for the same
# measured reason (the `drive` entry cites run 35280144455, where an iOS
# build-only prefix read as a run). They are meant to agree on that, and they are
# duplicated because this runs on a macOS runner's /bin/bash at a point where the
# Rust scanner has not been built — and on attempts where it never will be. Where
# they differ, each errs toward its own noisier answer: the scanner also refuses
# `Some tests failed.` as proof of a run, while here that line implies a test
# STARTED and therefore vetoes the retry, so neither reading can quietly turn a
# failure into a pass.
#
# Over-matching is still the SAFE direction: a false positive only means an
# attempt is not retried, while a false negative would let a suite that RAN be
# treated as one that never started. That is why the GitHub reporter's shapes
# stay in the set even though every iOS lane pins `--reporter expanded` (see
# spawn_ios_test): this predicate also reads logs from older attempts and from
# lanes that invoke `flutter test` themselves. test_core's github.dart writes
# `✅ <name>` for a test with no output and `::group::✅ <name>` for one with
# output, `❌` for failed, `❎` for skipped, `🎉 N tests passed.` on success and
# `::error::N tests passed, M failed.` on failure; anchoring to line-start or to
# `::group::` keeps this matching the REPORTER rather than app chatter that
# happens to carry an emoji.
readonly IOS_TEST_STARTED_RE='(^|::group::)(✅|❌|❎) |🎉 [0-9]+ tests? (passed|skipped)|::error::[0-9]+ tests? passed|^[0-9]{2}:[0-9]{2} \+[0-9]+( -[0-9]+)?( ~[0-9]+)?: '

# A progress line whose subject is a suite LOAD. Subtracted from the candidate
# lines before the match above, because ERE has no negative lookahead; anchored
# identically, so it can only ever remove the reporter's own load line.
readonly IOS_SUITE_LOAD_RE='^[0-9]{2}:[0-9]{2} \+[0-9]+( -[0-9]+)?( ~[0-9]+)?: loading '

# flutter_tools' OWN account of a failed attach, measured verbatim in CI run
# 35690725254 and emitted by its lib/src/ios/simulators.dart when the launched
# app never publishes a VM-service URI. Only the stable head is matched, as a
# fixed string: the tail is either `The log reader failed unexpectedly` or an
# arbitrary exception rendering, and pattern-matching an exception's text is how
# a predicate starts depending on prose nobody controls.
readonly IOS_ATTACH_FAILURE_MARKER='Error waiting for a debug connection'

# Same rationale as drive-log-lib.sh's `_drive_log_decolour`: reporter output can
# carry SGR escapes that split a pattern in half, and depending on a colour
# default staying off is one literal away from silently disabling a signal. Kept
# local rather than reaching into the other library's private symbol, so neither
# file can quietly change the other's matching.
_ios_log_decolour() {
  local esc
  esc="$(printf '\033')"
  sed "s/${esc}\\[[0-9;]*m//g" -- "$1" 2>/dev/null || true
}

# Every match below reads the decoloured text through a PROCESS SUBSTITUTION
# rather than a pipe, and that is deliberate. Under `set -o pipefail` (which
# every runner sourcing this sets) `decolour | grep -q …` would report FAILURE on
# a SUCCESSFUL match whenever `grep -q` exits at the first hit and the upstream
# `sed` then takes SIGPIPE (141) — a fault that hides on small fixtures, where
# sed finishes first, and appears only on a real multi-megabyte CI log. Today
# `_ios_log_decolour`'s trailing `|| true` is what absorbs that, which means one
# deleted `|| true` away from a predicate that silently stops matching. With
# `< <(…)` the status is grep's alone and does not depend on that at all.

# _ios_log_after_build_done <log> — the decoloured log from the line AFTER the
# build marker to EOF, and EMPTY when the build never finished. That emptiness
# is what makes every predicate built on it fail closed on a build failure.
#
# The LAST occurrence is the anchor. `flutter test` prints the marker once per
# invocation and the runner truncates the log per invocation, so today "last" is
# "the only one"; taking the last is what keeps the answer about the build that
# just finished if a future flutter ever rebuilds mid-run.
#
# Watchdog marker lines are excluded from the SEARCH for the build marker, for
# the same reason clause (c) excludes them: the marker line is free text, and one
# that came to quote the build-done literal would otherwise move this window
# onto itself.
_ios_log_after_build_done() {
  local log="${1:-}" last=''
  [[ -f "${log}" ]] || return 0
  # `|| last=''` because "no build-done line" is an answer here, not an error,
  # and every runner sourcing this sets errexit and pipefail.
  last="$(_ios_log_decolour "${log}" \
            | LC_ALL=C grep -anF -- "${IOS_BUILD_DONE_MARKER}" \
            | LC_ALL=C grep -avF -- "${IOS_STALL_MARKER}" \
            | LC_ALL=C tail -n 1 | LC_ALL=C cut -d: -f1)" || last=''
  [[ -n "${last}" ]] || return 0
  _ios_log_decolour "${log}" | LC_ALL=C tail -n +"$(( last + 1 ))"
}

# ios_log_test_started <log> — 0 (true) when a TEST started after the build
# finished. A missing log returns 1: it cannot show a start it does not contain,
# and callers treat "no log" as their own error.
ios_log_test_started() {
  local log="${1:-}"
  [[ -f "${log}" ]] || return 1
  LC_ALL=C grep -aqE -- "${IOS_TEST_STARTED_RE}" \
    < <(_ios_log_after_build_done "${log}" | LC_ALL=C grep -avE -- "${IOS_SUITE_LOAD_RE}")
}

# ios_log_reports_attach_failure <log> — 0 (true) when flutter_tools itself said,
# after the build, that it could not attach to the app it had just launched. The
# second admitted form of clause (b); see there for why it does not widen the
# retry.
ios_log_reports_attach_failure() {
  local log="${1:-}"
  [[ -f "${log}" ]] || return 1
  LC_ALL=C grep -aqF -- "${IOS_ATTACH_FAILURE_MARKER}" < <(_ios_log_after_build_done "${log}")
}

# ios_log_is_launch_stall <log> — 0 (true, RETRYABLE) iff the log is the one
# admitted infrastructure signature: the Xcode build completed, no test started
# after it, somebody observed that (our watchdog, or flutter_tools reporting a
# failed attach), and nothing anywhere in the log says a test ran or failed.
#
# Every clause is a veto, and every clause requires evidence rather than
# assuming it:
#
#   (a) An absent or EMPTY log is not retryable. `-s`, not `-f`: a zero-byte log
#       is the same "no evidence" as no log at all, and the secret-scanner fix
#       (A4) established that missing input must never read as the benign case.
#       Here the benign-for-retry case is "infrastructure flake", so no evidence
#       means no retry — the run stays red and a human reads the artifact.
#   (b) Somebody must have OBSERVED that no test started, in one of three forms:
#       the watchdog's out-of-band flag file, the watchdog's marker in the
#       evidence log, or flutter_tools' own `Error waiting for a debug
#       connection` after the build. The first two are positive evidence
#       produced by our own watchdog at a moment it could still see that no test
#       had started; the flag is checked FIRST because it is the one a dying
#       child cannot corrupt (see above). The third is the SAME observation
#       spelled by the tool instead of by us: it prints that line only after it
#       has launched the app and given up waiting for a VM service, i.e. no Dart
#       code ran, by its own account. Without one of the three, "built then
#       silence" is indistinguishable from "killed by the outer timeout
#       mid-suite".
#
#       The third form widens nothing: it substitutes for the WITNESS, never for
#       a clause. (c) still requires the build to have finished — and the
#       attach-failure search is scoped to the post-build suffix, so a build
#       failure cannot supply it at all — (d) still requires that no test
#       started, and (e) still lets any self-reported failure veto. A run that
#       reached test code and then failed carries a test-start line and a
#       failure, so it cannot reach this verdict however flutter_tools worded
#       its exit.
#   (c) `Xcode build done.` must be present, so this is provably a launch/attach
#       stall and not a hung or failed BUILD. A build failure is deterministic
#       and reproducible; retrying it buys nothing and hides it for 10 minutes.
#   (d) No test STARTED after the build, in the EVIDENCE log. Closes the
#       watchdog/first-test race: if the suite started in the window between the
#       watchdog's last look and its kill, the attempt is NOT retried. Scoped to
#       the build-done suffix (the reporter's pre-build `loading` line is not a
#       start — see IOS_TEST_STARTED_RE) and to the pre-kill
#       snapshot rather than "anywhere", deliberately — `flutter test`'s SIGTERM
#       handler prints "🎉 0 tests passed." as it dies, which matches
#       IOS_TEST_STARTED_RE but is teardown noise, not the suite speaking. The
#       snapshot ends before we signalled, so everything the suite ACTUALLY said
#       is still in scope and only our own kill's artefacts are excluded. Note
#       this is why clause (e) below reads BOTH logs: an unambiguous
#       self-reported FAILURE must veto whenever it appears, including on the
#       way out.
#   (e) drive-log-lib.sh's app-side failure predicate must be silent — on the
#       snapshot AND on the live log. A second,
#       independently-maintained opinion on the same question, and the one that
#       also catches `All tests skipped.` — so a vacuous suite cannot be retried
#       into a green either.
ios_log_is_launch_stall() {
  local log="${1:-}" evidence flag
  flag="$(ios_stall_flag_path "${log}")"
  # Clauses (a)-(d) judge the PRE-KILL snapshot when the watchdog left one, so
  # nothing the child wrote while dying can vote. With no snapshot — every
  # hermetic fixture, and any path where the watchdog never fired — this is the
  # log itself and the predicate is byte-for-byte what it always was.
  evidence="$(ios_prekill_log_path "${log}")"
  [[ -s "${evidence}" ]] || evidence="${log}"

  [[ -s "${evidence}" ]] || return 1
  if [[ ! -f "${flag}" ]] \
     && ! LC_ALL=C grep -aqF -- "${IOS_STALL_MARKER}" < <(_ios_log_decolour "${evidence}") \
     && ! ios_log_reports_attach_failure "${evidence}"; then
    return 1
  fi
  # The build-done evidence is taken from lines that are NOT the watchdog's own.
  # The marker line is free text written by the runner; if it ever came to quote
  # the build-done literal, clause (c) would be satisfied by the watchdog talking
  # about itself and a build failure would become retryable. Fixture 8 pins this.
  LC_ALL=C grep -aqF -- "${IOS_BUILD_DONE_MARKER}" \
    < <(_ios_log_decolour "${evidence}" | LC_ALL=C grep -avF -- "${IOS_STALL_MARKER}") || return 1
  if ios_log_test_started "${evidence}"; then return 1; fi
  # Clause (e) is checked against the snapshot AND the full log. A suite that
  # reported a real failure vetoes the retry no matter when it said so, and the
  # post-SIGTERM teardown line does not match this predicate, so the extra read
  # costs nothing and closes the "it failed as it died" case.
  if drive_log_reports_test_failure "${evidence}"; then return 1; fi
  if drive_log_reports_test_failure "${log}"; then return 1; fi
  return 0
}

# ---------------------------------------------------------------------------
# Cross-attempt verdict state.
#
# One file per SCENARIO, so the two steps of e2e-ios.yml (e2e_combined, then
# ios_bg_mirror) cannot inherit each other's verdict, and so e2e-profile.yml's
# single step is isolated from both.
# ---------------------------------------------------------------------------

# Overridable ONLY so the self-test can run hermetically in a temp dir. CI and
# local runs use /tmp, matching every other path this harness hardcodes
# (/tmp/flutter-ios-test.log, /tmp/relay.log).
ios_retry_state_dir() {
  echo "${HAVEN_IOS_RETRY_STATE_DIR:-/tmp}"
}

# ios_retry_verdict_file <scenario-file> — the verdict path for one scenario.
# Slugified with a bash bracket expression (no `tr`, no subshell) so a path
# separator in the scenario cannot escape the state directory.
ios_retry_verdict_file() {
  local slug="${1//[^A-Za-z0-9._-]/-}"
  echo "$(ios_retry_state_dir)/haven-ios-retry-verdict-${slug}"
}

# ios_retry_record <file> <verdict> <rc> <reason> — one tab-separated line.
# Written with `>` so the newest verdict fully replaces the previous one; a
# partially-overwritten file would parse as an unknown verdict, which the gate
# already treats as "do not retry".
ios_retry_record() {
  local file="$1" verdict="$2" rc="$3" reason="$4"
  printf '%s\t%s\t%s\n' "${verdict}" "${rc}" "${reason}" > "${file}"
}

ios_retry_clear() {
  rm -f "${1}"
}

# ios_record_failure_verdict <verdict-file> <log> <rc> — classify a FAILED
# attempt and write the verdict the gate will read. Returns 0 when the failure
# was the admitted launch/attach stall (so the caller can say so in the step
# output), 1 otherwise.
#
# This is the ONLY place `retryable` is ever written, and it is deliberately a
# library function rather than an `if` in the runner: an `if` at the call site is
# unreachable from any hermetic self-test, so a mutation that recorded
# `retryable` unconditionally — reinstating the blanket retry exactly — would
# pass every fixture. Here it is covered (fixtures R1/R2).
ios_record_failure_verdict() {
  local file="$1" log="$2" rc="$3"
  if ios_log_is_launch_stall "${log}"; then
    ios_retry_record "${file}" retryable "${rc}" \
      "no on-device test started before the watchdog deadline (post-build launch/attach stall)"
    return 0
  fi
  ios_retry_record "${file}" genuine "${rc}" "the suite ran and did not pass (rc=${rc})"
  return 1
}

# Field 1 = verdict word, 2 = rc, 3 = reason. An absent file reports `absent`
# (this is attempt 1); an unreadable or malformed one reports `unknown`, which
# the gate refuses — a verdict we cannot read is not a verdict to act on.
ios_retry_verdict_field() {
  local file="$1" index="$2" verdict rc reason
  if [[ ! -f "${file}" ]]; then
    [[ "${index}" == 1 ]] && echo "absent" || echo ""
    return 0
  fi
  IFS=$'\t' read -r verdict rc reason < "${file}" || true
  case "${index}" in
    1) echo "${verdict:-unknown}" ;;
    2) echo "${rc:-1}" ;;
    3) echo "${reason:-}" ;;
  esac
}

# ios_retry_gate <verdict-file> — decide whether THIS invocation may run the
# suite. Returns 0 to proceed, or the exit code the caller must exit with
# immediately.
#
# Proceeding always stamps `unproven` first, so the window between here and
# classification is covered: whatever kills us in it leaves a verdict that the
# next attempt refuses.
ios_retry_gate() {
  local file="$1" word rc reason
  word="$(ios_retry_verdict_field "${file}" 1)"
  rc="$(ios_retry_verdict_field "${file}" 2)"
  reason="$(ios_retry_verdict_field "${file}" 3)"

  case "${word}" in
    absent)
      ios_retry_record "${file}" unproven 1 "attempt did not reach classification"
      return 0
      ;;
    retryable)
      echo "iOS E2E — sanctioned retry: the previous attempt was classified as" \
           "an iOS-simulator launch/attach stall (${reason}). Re-running."
      ios_retry_record "${file}" unproven 1 "attempt did not reach classification"
      return 0
      ;;
    *)
      # Normalise: 0 would read as success, and a non-numeric rc as a bash error.
      [[ "${rc}" =~ ^[1-9][0-9]*$ ]] || rc=1
      (( rc > 255 )) && rc=1
      echo "ERROR: refusing to retry the iOS scenario. The previous attempt's" \
           "verdict is '${word}' (${reason}), which is NOT the one retryable" \
           "signature (a post-build, pre-first-test simulator launch/attach" \
           "stall). Retrying anything else is how a reproducible failure" \
           "becomes a green on the second attempt — see" \
           "tooling/e2e/ci/ios-flake-lib.sh." >&2
      echo "       Failing immediately with the original exit code ${rc}." >&2
      return "${rc}"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# --self-test — hermetic; needs no simulator, no Xcode, no network. Wired into
# repo-guards.yml so the predicate and the gate state machine cannot rot into a
# blanket retry again without a red run saying so.
# ---------------------------------------------------------------------------
ios_flake_lib_self_test() {
  local tmp fail=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  # --- Predicate fixtures -------------------------------------------------

  # (1) THE ADMITTED SIGNATURE — verbatim shape of job 89910560604 attempt 1
  #     (run 30244945272): build finished, then nothing, and our watchdog said
  #     so. MUST be retryable, or the one real iOS flake stops being absorbed.
  printf '%s\n' \
    'iOS E2E — scenario=integration_test/e2e/e2e_combined.dart udid=EE61976B live_sync=false' \
    'Running Xcode build...' \
    'Xcode build done.                                           496.3s' \
    "$(ios_stall_marker_line 300)" \
    > "${tmp}/stall.log"
  if ! ios_log_is_launch_stall "${tmp}/stall.log"; then
    echo "SELF-TEST FAIL (1): the observed iOS launch/attach stall was NOT classified as retryable" >&2
    fail=1
  fi

  # (2) THE CRITICAL FIXTURE — a GENUINE test failure under the GitHub reporter,
  #     verbatim from job 89823392716 (run 30326904961). Retrying this is the
  #     whole defect; it MUST NOT be retryable even if a marker were somehow
  #     present, which is why the marker is included here.
  printf '%s\n' \
    'Xcode build done.                                           523.7s' \
    '::group::❌ Alice UI + Bob/Carol FFI: 3-member invite → 3-way locations (failed)' \
    'Expected: a value greater than or equal to <1>' \
    '  Actual: <0>' \
    '::endgroup::' \
    '::error::9 tests passed, 1 failed.' \
    "$(ios_stall_marker_line 300)" \
    > "${tmp}/testfail.log"
  if ios_log_is_launch_stall "${tmp}/testfail.log"; then
    echo "SELF-TEST FAIL (2): a genuine test failure was classified as retryable (would mask a bug)" >&2
    fail=1
  fi

  # (3) A setUpAll throw — job 91511139791 (run 30753193231), the same failure
  #     that exposed the `flutter drive` exit-0 lie on the Android side. Under
  #     the GitHub reporter it prints `0 tests passed, 1 failed.`, so it is only
  #     caught by the reporter signals; drive-log-lib's Android-shaped regex sees
  #     nothing here. MUST NOT be retryable.
  printf '%s\n' \
    'Xcode build done.                                           523.7s' \
    '::group::❌ (setUpAll) (failed)' \
    'set_profile_relays_for_test already installed' \
    '::endgroup::' \
    '::error::0 tests passed, 1 failed.' \
    "$(ios_stall_marker_line 300)" \
    > "${tmp}/setupall.log"
  if ios_log_is_launch_stall "${tmp}/setupall.log"; then
    echo "SELF-TEST FAIL (3): a setUpAll failure was classified as retryable" >&2
    fail=1
  fi

  # (4) A CLEAN PASS. Nothing to retry; also proves the `🎉` summary counts as
  #     activity even when every test printed nothing (the reporter emits bare
  #     `✅ <name>` lines in that case, with no `::group::`).
  printf '%s\n' \
    'Xcode build done.                                           541.1s' \
    '✅ M11: live-sync (flag-on) a — a peer location arrives over the live stream' \
    '🎉 12 tests passed.' \
    > "${tmp}/pass.log"
  if ios_log_is_launch_stall "${tmp}/pass.log"; then
    echo "SELF-TEST FAIL (4): a clean pass was classified as retryable" >&2
    fail=1
  fi

  # (5) EMPTY LOG. No evidence is not evidence of a flake (A4's lesson, applied
  #     in the other direction). MUST NOT be retryable.
  : > "${tmp}/empty.log"
  if ios_log_is_launch_stall "${tmp}/empty.log"; then
    echo "SELF-TEST FAIL (5): an EMPTY log was classified as retryable" >&2
    fail=1
  fi

  # (6) ABSENT LOG — e.g. the runner died before `flutter test` ever wrote a
  #     byte. MUST NOT be retryable.
  if ios_log_is_launch_stall "${tmp}/does-not-exist.log"; then
    echo "SELF-TEST FAIL (6): an ABSENT log was classified as retryable" >&2
    fail=1
  fi

  # (7) THE WATCHDOG RACE — the marker is present, but the suite HAD started in
  #     the window between the watchdog's last look and its kill. Retrying would
  #     re-roll a run that was already executing test code. MUST NOT be
  #     retryable.
  printf '%s\n' \
    'Xcode build done.                                           470.2s' \
    '::group::✅ (setUpAll)' \
    '[ScenarioHarness] bootstrapped role=ScenarioRole.solo relay=ws://localhost:7777' \
    '::endgroup::' \
    "$(ios_stall_marker_line 300)" \
    > "${tmp}/race.log"
  if ios_log_is_launch_stall "${tmp}/race.log"; then
    echo "SELF-TEST FAIL (7): a stall marker racing a STARTED suite was classified as retryable" >&2
    fail=1
  fi

  # (8) BUILD NEVER FINISHED. No `Xcode build done.`, so this is a build hang or
  #     failure, not a launch/attach stall. Deterministic; MUST NOT be retryable.
  printf '%s\n' \
    'Running pod install...' \
    'Error running pod install' \
    "${IOS_STALL_MARKER} within 300s of 'Xcode build done.'" \
    > "${tmp}/buildfail.log"
  if ios_log_is_launch_stall "${tmp}/buildfail.log"; then
    echo "SELF-TEST FAIL (8): a build-phase failure was classified as retryable" >&2
    fail=1
  fi

  # (9) SILENCE WITH NO MARKER — exactly what the CURRENT lane sees when
  #     `nick-fields/retry` SIGKILLs a stalled attempt: build done, then nothing,
  #     and our watchdog never got to speak. Without positive evidence this is
  #     indistinguishable from a mid-suite kill, so it MUST NOT be retryable.
  #     This is the fixture that makes the retry fail closed.
  printf '%s\n' \
    'Running Xcode build...' \
    'Xcode build done.                                           651.8s' \
    > "${tmp}/silent.log"
  if ios_log_is_launch_stall "${tmp}/silent.log"; then
    echo "SELF-TEST FAIL (9): unattributed post-build silence was classified as retryable" >&2
    fail=1
  fi

  # (10) COMPACT-REPORTER failure (a local run, no GITHUB_ACTIONS). The GitHub
  #      signals are all absent; drive-log-lib.sh is what catches this one.
  #      MUST NOT be retryable.
  printf '%s\n' \
    'Xcode build done.                                           480.0s' \
    '00:44 +3 -1: some scenario [E]' \
    '00:45 +3 -1: Some tests failed.' \
    "$(ios_stall_marker_line 300)" \
    > "${tmp}/compactfail.log"
  if ios_log_is_launch_stall "${tmp}/compactfail.log"; then
    echo "SELF-TEST FAIL (10): a compact-reporter test failure was classified as retryable" >&2
    fail=1
  fi

  # (11) VACUOUS SUITE — nothing ran, and `flutter test` reported that as
  #      success. Retrying it would re-roll a run that proved nothing; failing it
  #      is the point of drive-log-lib.sh fixture 9. MUST NOT be retryable.
  printf '%s\n' \
    'Xcode build done.                                           480.0s' \
    '00:00 +0: All tests skipped.' \
    "$(ios_stall_marker_line 300)" \
    > "${tmp}/skipped.log"
  if ios_log_is_launch_stall "${tmp}/skipped.log"; then
    echo "SELF-TEST FAIL (11): a suite where NOTHING ran was classified as retryable" >&2
    fail=1
  fi

  # (12) ANSI-COLOURED reporter output. If de-colouring ever regressed, the
  #      escapes would split `::error::…` and the emoji markers and a genuine
  #      failure would start looking like a stall. MUST NOT be retryable.
  printf 'Xcode build done.  480.0s\n\033[31m::group::❌\033[0m \033[1m(setUpAll)\033[0m (failed)\n%s\n' \
    "$(ios_stall_marker_line 300)" \
    > "${tmp}/ansi.log"
  if ios_log_is_launch_stall "${tmp}/ansi.log"; then
    echo "SELF-TEST FAIL (12): an ANSI-coloured genuine failure was classified as retryable" >&2
    fail=1
  fi

  # (13) THE SHAPE ONLY drive-log-lib.sh CATCHES. `(setUpAll) [E]` and a bare
  #      `+0 -1:` counter that is NOT at line start (indented, or forwarded with
  #      an `I/flutter (pid):` prefix) miss every signal in
  #      IOS_TEST_STARTED_RE, which anchors its progress-line rule to line
  #      start. Without this fixture the reuse of drive-log-lib.sh is untested
  #      overlap and could be deleted with every other fixture still green — so
  #      this is what makes clause (e) load-bearing. MUST NOT be retryable.
  printf '%s\n' \
    'Xcode build done.                                           480.0s' \
    '  00:01 +0 -1: (setUpAll) [E]' \
    '  Expected: <something>' \
    "$(ios_stall_marker_line 300)" \
    > "${tmp}/setupall-indented.log"
  if ios_log_is_launch_stall "${tmp}/setupall-indented.log"; then
    echo "SELF-TEST FAIL (13): an indented setUpAll failure was classified as retryable" >&2
    fail=1
  fi

  # (14) THE CI RUN 30964250098 BYTES. The log exactly as the artifact carried
  #      it: the marker's 22-byte head overwritten by `flutter test`'s SIGTERM
  #      handler, leaving "vice test started…", and the teardown's
  #      "🎉 0 tests passed." where those bytes used to be. On the live log alone
  #      this is unclassifiable — clause (b) has no marker and clause (d) sees
  #      activity — which is precisely why the verdict now rests on the pre-kill
  #      snapshot and the flag. With both present it MUST be retryable.
  printf '%s\n' \
    'Running Xcode build...' \
    'Xcode build done.                                           595.2s' \
    '' \
    '🎉 0 tests passed.' \
    'vice test started within 300s of the Xcode build finishing — killing a pre-test simulator launch/attach stall.' \
    > "${tmp}/clobbered.log"
  printf '%s\n' \
    'Running Xcode build...' \
    'Xcode build done.                                           595.2s' \
    "$(ios_stall_marker_line 300)" \
    > "$(ios_prekill_log_path "${tmp}/clobbered.log")"
  : > "$(ios_stall_flag_path "${tmp}/clobbered.log")"
  if ! ios_log_is_launch_stall "${tmp}/clobbered.log"; then
    echo "SELF-TEST FAIL (14): the CI run 30964250098 log was classified as" \
         "GENUINE — a launch/attach stall whose evidence the dying child" \
         "overwrote must still be retryable" >&2
    fail=1
  fi

  # (15) THE PROOF THAT (14) IS NOT A PATTERN-MATCH ESCAPE HATCH. Same clobbered
  #      live log, same flag — but now the suite genuinely spoke BEFORE the
  #      watchdog fired, so the activity is in the SNAPSHOT. The vacuous-suite
  #      veto is preserved, not traded away: only artefacts written after we
  #      signalled are excluded, and they are excluded structurally (by when they
  #      were written), never by matching the teardown string away.
  #      MUST NOT be retryable.
  printf '%s\n' \
    'Running Xcode build...' \
    'Xcode build done.                                           595.2s' \
    '🎉 0 tests passed.' \
    "$(ios_stall_marker_line 300)" \
    > "$(ios_prekill_log_path "${tmp}/clobbered.log")"
  if ios_log_is_launch_stall "${tmp}/clobbered.log"; then
    echo "SELF-TEST FAIL (15): a suite that spoke BEFORE the kill was retried —" \
         "the snapshot must carry every veto the live log used to" >&2
    fail=1
  fi
  ios_clear_stall_evidence "${tmp}/clobbered.log"

  # (16b) THE LIVE-LOG ARM OF CLAUSE (e) — "it failed as it died". The snapshot
  #       is clean (build done, marker, no activity) and the flag is present, so
  #       clauses (a)-(d) all pass; the veto has to come from reading the LIVE
  #       log, where the child reported a real failure on its way out. Without
  #       this fixture the second `drive_log_reports_test_failure` call can be
  #       deleted with every other fixture still green — i.e. a self-reported
  #       failure would start being retried and nothing would say so.
  printf '%s\n' \
    'Running Xcode build...' \
    'Xcode build done.                                           595.2s' \
    '00:07 +0 -1: Some tests failed.' \
    > "${tmp}/died-failing.log"
  printf '%s\n' \
    'Running Xcode build...' \
    'Xcode build done.                                           595.2s' \
    "$(ios_stall_marker_line 300)" \
    > "$(ios_prekill_log_path "${tmp}/died-failing.log")"
  : > "$(ios_stall_flag_path "${tmp}/died-failing.log")"
  if ios_log_is_launch_stall "${tmp}/died-failing.log"; then
    echo "SELF-TEST FAIL (16b): a suite that reported a FAILURE as it died was" \
         "classified as retryable — clause (e) must read the live log too, not" \
         "only the pre-kill snapshot" >&2
    fail=1
  fi
  ios_clear_stall_evidence "${tmp}/died-failing.log"

  # (16c) THE SNAPSHOT ARM OF CLAUSE (e). Mirror of 16b: the failure is in the
  #       SNAPSHOT (the suite failed before the watchdog looked), live log clean.
  #       Pins the first `drive_log_reports_test_failure` call, which 16b alone
  #       would let be deleted.
  printf '%s\n' \
    'Running Xcode build...' \
    'Xcode build done.                                           595.2s' \
    > "${tmp}/failed-early.log"
  printf '%s\n' \
    'Running Xcode build...' \
    'Xcode build done.                                           595.2s' \
    '  00:01 +0 -1: (setUpAll) [E]' \
    "$(ios_stall_marker_line 300)" \
    > "$(ios_prekill_log_path "${tmp}/failed-early.log")"
  : > "$(ios_stall_flag_path "${tmp}/failed-early.log")"
  if ios_log_is_launch_stall "${tmp}/failed-early.log"; then
    echo "SELF-TEST FAIL (16c): a failure recorded in the PRE-KILL snapshot was" \
         "classified as retryable — the snapshot must carry every veto the live" \
         "log used to" >&2
    fail=1
  fi
  ios_clear_stall_evidence "${tmp}/failed-early.log"

  # (16d) THE FLAG ARM OF CLAUSE (b). Snapshot exists and is clean but carries NO
  #       marker (the watchdog's `cp` ran before its append, or the append was
  #       lost); only the flag attests the kill. Must still be retryable, or the
  #       flag branch is dead code that could be deleted unnoticed.
  printf '%s\n' \
    'Running Xcode build...' \
    'Xcode build done.                                           595.2s' \
    > "${tmp}/flag-only.log"
  printf '%s\n' \
    'Running Xcode build...' \
    'Xcode build done.                                           595.2s' \
    > "$(ios_prekill_log_path "${tmp}/flag-only.log")"
  : > "$(ios_stall_flag_path "${tmp}/flag-only.log")"
  if ! ios_log_is_launch_stall "${tmp}/flag-only.log"; then
    echo "SELF-TEST FAIL (16d): the out-of-band flag alone must satisfy clause" \
         "(b) — it is the one artefact the dying child cannot corrupt" >&2
    fail=1
  fi
  ios_clear_stall_evidence "${tmp}/flag-only.log"

  # (16) A STALL FLAG DOES NOT OVERRIDE THE OTHER CLAUSES. Flag present, but the
  #      build never finished: clause (c) must still veto, or a hung build would
  #      become retryable by depositing a flag.
  printf '%s\n' \
    'Running pod install...' \
    'Error running pod install' \
    > "${tmp}/flagged-buildfail.log"
  : > "$(ios_stall_flag_path "${tmp}/flagged-buildfail.log")"
  if ios_log_is_launch_stall "${tmp}/flagged-buildfail.log"; then
    echo "SELF-TEST FAIL (16): a build failure with a stall flag was classified" \
         "as retryable — the flag replaces clause (b) only, never (c)-(e)" >&2
    fail=1
  fi
  ios_clear_stall_evidence "${tmp}/flagged-buildfail.log"

  # (17) THE ADMITTED SIGNATURE, SPELLED AS A REAL TRANSCRIPT. Fixture (1) starts
  #      at the build, which no `flutter test` log does: the expanded reporter's
  #      `loading <suite>.dart` is line 1 and lands MINUTES before the build
  #      finishes (green run 35664400984: 23:37:55 vs 23:51:37). While the
  #      predicate scanned the whole log that line read as the suite speaking, so
  #      clause (d) vetoed and this exact log — the one the lane exists to
  #      retry — was classified GENUINE. MUST be retryable.
  printf '%s\n' \
    '00:00 +0: loading /Users/runner/work/Haven-App/Haven-App/haven/integration_test/e2e/e2e_combined.dart' \
    'Running Xcode build...' \
    'Xcode build done.                                           496.3s' \
    "$(ios_stall_marker_line 300)" \
    > "${tmp}/loading-stall.log"
  if ! ios_log_is_launch_stall "${tmp}/loading-stall.log"; then
    echo "SELF-TEST FAIL (17): a post-build stall whose transcript carries the" \
         "reporter's pre-build 'loading' line was classified as GENUINE — a" \
         "suite LOAD is not a test start" >&2
    fail=1
  fi

  # (17b) NEITHER HALF OF "A TEST STARTED" IS DECORATION. Fixture (17) is the
  #       measured transcript, and either half of the definition alone satisfies
  #       it — so without this fixture one of them could be deleted with
  #       everything still green, and the watchdog would go vacuous again the
  #       next time the SDK moved a literal neither this file nor
  #       tooling/logscan/policy.toml owns. This log pins both at once:
  #
  #         * a progress line BEFORE the build under a subject the suite-load
  #           rule does not recognise — the window is "since the build", and
  #           nothing printed before it can be a test starting on a device the
  #           app has not been installed on yet;
  #         * a suite LOAD after it — measured at line 1 in every transcript
  #           (runs 35664400984 and 35690725254 both put it ~11 min ahead of
  #           `Xcode build done.`), but this predicate must not depend on an
  #           ordering flutter_tools is free to change, because the cost of
  #           being wrong is a watchdog that cannot fire at all.
  #
  #       Neither is a start, so this MUST be retryable.
  printf '%s\n' \
    '00:00 +0: compiling /Users/runner/work/Haven-App/Haven-App/haven/integration_test/e2e/e2e_combined.dart' \
    'Running Xcode build...' \
    'Xcode build done.                                           496.3s' \
    '00:00 +0: loading /Users/runner/work/Haven-App/Haven-App/haven/integration_test/e2e/e2e_combined.dart' \
    "$(ios_stall_marker_line 300)" \
    > "${tmp}/loading-both.log"
  if ! ios_log_is_launch_stall "${tmp}/loading-both.log"; then
    echo "SELF-TEST FAIL (17b): a post-build stall was classified as GENUINE on" \
         "the strength of reporter output that started no test — either the" \
         "build-done window or the suite-load rule has been dropped" >&2
    fail=1
  fi

  # (18) CI RUN 35690725254, VERBATIM. flutter_tools said `No tests ran.` and
  #      that it could not attach, then hung until the outer timeout — so there
  #      is no flag and no marker, and the verdict rests entirely on the tool's
  #      own account. MUST be retryable, or this failure keeps costing a lane 30
  #      unattributed minutes.
  printf '%s\n' \
    '00:00 +0: loading /Users/runner/work/Haven-App/Haven-App/haven/integration_test/e2e/e2e_profile_sharing.dart' \
    'Running Xcode build...' \
    'Xcode build done.                                           647.3s' \
    'No tests ran.' \
    'Error waiting for a debug connection: The log reader failed unexpectedly' \
    > "${tmp}/attach-failed.log"
  if ! ios_log_is_launch_stall "${tmp}/attach-failed.log"; then
    echo "SELF-TEST FAIL (18): flutter_tools' own report that it attached to" \
         "nothing and ran no test was classified as GENUINE" >&2
    fail=1
  fi

  # (19) …AND IT IS NOT A BLANKET RETRY TICKET. Same attach-failure line, but a
  #      test DID start after the build (flutter_tools can print it while tearing
  #      a running suite down). Clause (d) must still veto. MUST NOT be
  #      retryable.
  printf '%s\n' \
    'Running Xcode build...' \
    'Xcode build done.                                           647.3s' \
    '00:00 +0: (setUpAll)' \
    'Error waiting for a debug connection: The log reader failed unexpectedly' \
    > "${tmp}/attach-failed-after-start.log"
  if ios_log_is_launch_stall "${tmp}/attach-failed-after-start.log"; then
    echo "SELF-TEST FAIL (19): a suite that HAD started was retried because" \
         "flutter_tools also reported a failed attach" >&2
    fail=1
  fi

  # (20) …and it cannot rescue a BUILD failure either. Differs from (18) by
  #      exactly the build-done line, and clause (c) is what vetoes. MUST NOT be
  #      retryable.
  printf '%s\n' \
    'Running pod install...' \
    'Error running pod install' \
    'Error waiting for a debug connection: The log reader failed unexpectedly' \
    > "${tmp}/attach-failed-no-build.log"
  if ios_log_is_launch_stall "${tmp}/attach-failed-no-build.log"; then
    echo "SELF-TEST FAIL (20): a build-phase failure carrying an attach-failure" \
         "line was classified as retryable" >&2
    fail=1
  fi

  # (20b) THE ATTACH EVIDENCE MUST BE ABOUT THIS BUILD'S LAUNCH. An attach
  #       failure that PREDATES the build says nothing about the app that was
  #       installed after it; what followed this build is unattributed silence,
  #       and fixture (9) is the rule that such silence is never retryable —
  #       "the log ends after the build" must not become a retry ticket because
  #       an older line happens to be in the file. Pins the post-build scope of
  #       ios_log_reports_attach_failure, which clause (c) does not reach here:
  #       the build DID finish. MUST NOT be retryable.
  printf '%s\n' \
    'Error waiting for a debug connection: The log reader failed unexpectedly' \
    'Running Xcode build...' \
    'Xcode build done.                                           496.3s' \
    > "${tmp}/attach-failed-before-build.log"
  if ios_log_is_launch_stall "${tmp}/attach-failed-before-build.log"; then
    echo "SELF-TEST FAIL (20b): post-build silence was classified as retryable on" \
         "the strength of an attach failure reported BEFORE the build" >&2
    fail=1
  fi

  # --- Gate fixtures — THE WIRING, not the predicate ----------------------
  #
  # The predicate can be perfect and the lane still retry everything, because
  # `nick-fields/retry` decides on its own. These fixtures pin the state machine
  # that actually governs attempt 2.

  local saved_dir="${HAVEN_IOS_RETRY_STATE_DIR:-}"
  export HAVEN_IOS_RETRY_STATE_DIR="${tmp}"
  local vf gate_rc
  vf="$(ios_retry_verdict_file 'integration_test/e2e/e2e_combined.dart')"

  # (G0) Scenario slugging must keep the file inside the state dir — a scenario
  #      path is full of `/`.
  case "${vf}" in
    "${tmp}/haven-ios-retry-verdict-"*) : ;;
    *)
      echo "SELF-TEST FAIL (G0): the verdict path escaped the state dir: ${vf}" >&2
      fail=1
      ;;
  esac

  # (G1) ATTEMPT 1 — no verdict yet. Must proceed, and must leave `unproven`
  #      behind BEFORE the suite runs, so a kill in that window fails closed.
  ios_retry_clear "${vf}"
  gate_rc=0
  ios_retry_gate "${vf}" >/dev/null 2>&1 || gate_rc=$?
  if (( gate_rc != 0 )); then
    echo "SELF-TEST FAIL (G1): the gate blocked the FIRST attempt (rc=${gate_rc})" >&2
    fail=1
  fi
  if [[ "$(ios_retry_verdict_field "${vf}" 1)" != "unproven" ]]; then
    echo "SELF-TEST FAIL (G1): the gate did not stamp 'unproven' before running" >&2
    fail=1
  fi

  # (G2) THE CRITICAL GATE FIXTURE — a classified genuine failure must NOT be
  #      retried, and the refusal must carry the ORIGINAL exit code so the lane
  #      still reports the true failure.
  ios_retry_record "${vf}" genuine 1 "9 tests passed, 1 failed"
  gate_rc=0
  ios_retry_gate "${vf}" >/dev/null 2>&1 || gate_rc=$?
  if (( gate_rc != 1 )); then
    echo "SELF-TEST FAIL (G2): a genuine failure was allowed to retry (rc=${gate_rc})" >&2
    fail=1
  fi

  # (G3) UNPROVEN — an attempt that vanished without classifying (outer-timeout
  #      SIGKILL, crash). This is the fail-closed case and the exact state the
  #      lane is in TODAY on every stall, so getting it wrong reinstates the
  #      blanket retry.
  ios_retry_record "${vf}" unproven 1 "attempt did not reach classification"
  gate_rc=0
  ios_retry_gate "${vf}" >/dev/null 2>&1 || gate_rc=$?
  if (( gate_rc == 0 )); then
    echo "SELF-TEST FAIL (G3): an UNCLASSIFIED attempt was allowed to retry" >&2
    fail=1
  fi

  # (G4) RETRYABLE — the sanctioned path. Must proceed AND must reset the file to
  #      `unproven`, so a second unclassified death cannot chain into a third
  #      attempt on a verdict it never earned.
  ios_retry_record "${vf}" retryable 1 "post-build, pre-first-test stall"
  gate_rc=0
  ios_retry_gate "${vf}" >/dev/null 2>&1 || gate_rc=$?
  if (( gate_rc != 0 )); then
    echo "SELF-TEST FAIL (G4): a classified stall was NOT allowed to retry (rc=${gate_rc})" >&2
    fail=1
  fi
  if [[ "$(ios_retry_verdict_field "${vf}" 1)" != "unproven" ]]; then
    echo "SELF-TEST FAIL (G4): the sanctioned retry did not re-arm the fail-closed stamp" >&2
    fail=1
  fi

  # (G5) A MALFORMED / TRUNCATED verdict is not a verdict. Refuse.
  echo -n "" > "${vf}"
  gate_rc=0
  ios_retry_gate "${vf}" >/dev/null 2>&1 || gate_rc=$?
  if (( gate_rc == 0 )); then
    echo "SELF-TEST FAIL (G5): an unreadable verdict was allowed to retry" >&2
    fail=1
  fi

  # (G6) A recorded rc of 0 must never become the gate's return value — that
  #      would turn a refused retry into a PASSING step.
  ios_retry_record "${vf}" genuine 0 "bogus zero rc"
  gate_rc=0
  ios_retry_gate "${vf}" >/dev/null 2>&1 || gate_rc=$?
  if (( gate_rc == 0 )); then
    echo "SELF-TEST FAIL (G6): a refused retry exited 0 — the step would go GREEN" >&2
    fail=1
  fi

  # (R1) THE RECORDING PATH — a genuine failure must be recorded as `genuine`,
  #      which is what makes the gate refuse attempt 2. Covers the mutation an
  #      `if` at the runner's call site would hide: recording `retryable`
  #      unconditionally is the blanket retry, restored.
  ios_retry_clear "${vf}"
  local rec_rc=0
  ios_record_failure_verdict "${vf}" "${tmp}/testfail.log" 1 || rec_rc=$?
  if (( rec_rc == 0 )); then
    echo "SELF-TEST FAIL (R1): a genuine failure was reported as the retryable signature" >&2
    fail=1
  fi
  if [[ "$(ios_retry_verdict_field "${vf}" 1)" != "genuine" ]]; then
    echo "SELF-TEST FAIL (R1): a genuine failure was not recorded as 'genuine'" >&2
    fail=1
  fi

  # (R2) …and the admitted stall must be recorded as `retryable`, or the one
  #      real iOS flake stops being absorbed and the lane gets noisier, not
  #      safer.
  ios_retry_clear "${vf}"
  rec_rc=0
  ios_record_failure_verdict "${vf}" "${tmp}/stall.log" 1 || rec_rc=$?
  if (( rec_rc != 0 )); then
    echo "SELF-TEST FAIL (R2): the admitted stall was not reported as retryable" >&2
    fail=1
  fi
  if [[ "$(ios_retry_verdict_field "${vf}" 1)" != "retryable" ]]; then
    echo "SELF-TEST FAIL (R2): the admitted stall was not recorded as 'retryable'" >&2
    fail=1
  fi

  # (G7) Per-SCENARIO isolation: e2e-ios.yml runs two scenarios in one job, and
  #      the first one's leftover verdict must not gate the second.
  local vf2
  vf2="$(ios_retry_verdict_file 'integration_test/ios_bg_mirror_test.dart')"
  if [[ "${vf2}" == "${vf}" ]]; then
    echo "SELF-TEST FAIL (G7): two different scenarios share one verdict file" >&2
    fail=1
  fi

  if [[ -n "${saved_dir}" ]]; then
    export HAVEN_IOS_RETRY_STATE_DIR="${saved_dir}"
  else
    unset HAVEN_IOS_RETRY_STATE_DIR
  fi

  if (( fail != 0 )); then
    echo "ios-flake-lib.sh --self-test: FAILED" >&2
    return 1
  fi
  echo "ios-flake-lib.sh --self-test: all 25 predicate + 8 gate + 2 recording fixtures passed" \
       "(the one admitted stall retries in both its spellings — our watchdog's" \
       "and flutter_tools' own failed attach — including when the transcript" \
       "opens with the reporter's pre-build suite load; genuine failures," \
       "vacuous suites, build failures, a started suite, empty/absent logs and" \
       "unattributed silence do not)."
  return 0
}

# Executed directly (not sourced) with --self-test.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -Eeuo pipefail
  if [[ "${1:-}" == "--self-test" ]]; then
    ios_flake_lib_self_test
    exit $?
  fi
  echo "ios-flake-lib.sh is a sourced library; pass --self-test to verify it." >&2
  exit 2
fi
