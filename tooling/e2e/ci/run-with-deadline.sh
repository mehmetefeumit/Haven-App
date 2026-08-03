#!/usr/bin/env bash
# E2E harness: run a command under an ATTRIBUTABLE inner deadline.
#
# # Why this exists
#
# Every emulator lane is bounded three times over, and only the innermost
# bound produces a usable red:
#
#   inner deadline (this script)  <  step `timeout-minutes`  <  job `timeout-minutes`
#
# The two outer bounds are GitHub's, and neither is trustworthy here:
#
#   * The step `timeout-minutes` on a `reactivecircus/android-emulator-runner`
#     step does NOT reliably reap the action's backgrounded emulator/adb/drive
#     subtree. A hang once ran the FULL ~45 min to the 60-min JOB timeout
#     TWICE (runs 28056995601, 28065762568) with the step cap set to 30.
#     That is recorded in e2e-android.yml's own step comment.
#   * The JOB timeout SIGKILLs the runner BEFORE any `if: failure()` step,
#     so the diagnostics, the secret scan and the artifact upload never run.
#     A job-cap death is the worst possible red: slow, and evidence-free.
#
# A plain coreutils `timeout` is immune to the action's process handling, so
# it is the RELIABLE bound. e2e-android.yml and e2e-profile.yml already used a
# raw `timeout --kill-after=60s <dur> ...` inline for exactly this reason.
#
# This script exists to make that pattern (a) uniform across every lane rather
# than present in two of seven, and (b) ATTRIBUTABLE. A raw `timeout` that
# fires prints nothing: the log ends mid-stream and the step reports
# "Process completed with exit code 124", which reads identically to a dozen
# unrelated failures. Triage then has to reconstruct, from the workflow file,
# which of the nested bounds fired and what its budget was. The banner below
# says it in the log, at the moment it happens, naming the lane and the number.
#
# # Contract
#
#   run-with-deadline.sh <deadline> <label> -- <command> [args...]
#
#   <deadline>  a `timeout` DURATION with an explicit unit (`28m`, `310m`,
#               `90s`). The unit is REQUIRED: coreutils reads a bare number as
#               SECONDS, so a caller that means "30 minutes" and writes `30`
#               silently gets a 30-second deadline that kills every healthy
#               run. That mistake is unrecoverable-looking in CI (it presents
#               as "the lane broke"), so it is rejected up front.
#   <label>     free-form lane/step identifier echoed in the banner. This is
#               what makes the failure attributable, so it should name the
#               lane, not the tool.
#   --          mandatory separator. Without it a label that happens to look
#               like a command would be silently executed.
#
# Exit codes:
#   0..123, 125+  the command's own exit code, passed through untouched. A
#                 genuine test failure MUST stay distinguishable from a hang;
#                 callers such as run-relay-customization.sh retry on 124 only.
#   124           the deadline fired (SIGTERM, or SIGKILL after the grace).
#   2             misuse (bad deadline, missing `--`, no command) — the caller
#                 is broken, not the thing being run.
#
# The kill grace (SIGTERM -> SIGKILL) defaults to 60s and is overridable via
# HAVEN_DEADLINE_KILL_GRACE. `flutter drive` and adb need a moment to flush
# their logs after SIGTERM; those logs are the evidence, so the grace is
# deliberately generous rather than instant. Budget it: the true worst case of
# a step is <deadline> + <grace>, which is what must sit under the step cap.
#
# macOS note: GNU coreutils `timeout` is NOT present on the macos-* runners,
# which is why the iOS lanes bound their drives with `nick-fields/retry`'s
# `timeout_minutes` instead. This script is for the ubuntu-latest Android
# lanes only; check_e2e_step_timeout_ordering.sh knows that split and accepts
# either form.
#
# Usage:
#   run-with-deadline.sh 28m e2e-integration -- bash tooling/e2e/ci/run-integration-tests.sh a=b
#   run-with-deadline.sh --self-test

set -euo pipefail

readonly DEADLINE_SCRIPT_NAME="run-with-deadline"

# A `timeout` DURATION that carries an explicit unit. Deliberately narrower
# than coreutils accepts (no bare numbers, no decimals): every caller in this
# repo writes whole minutes, and the two forms coreutils would also take are
# precisely the two that read as a different magnitude than intended.
readonly DEADLINE_RE='^[1-9][0-9]*[smhd]$'

# deadline_secs <duration> -> seconds. Used only to tell OUR timeout apart from
# the command's own exit 124 (see below).
deadline_secs() {
  local t="$1" n unit
  [[ "${t}" =~ ^([0-9]+)([smhd])$ ]] || { echo 0; return; }
  n="${BASH_REMATCH[1]}"; unit="${BASH_REMATCH[2]}"
  case "${unit}" in
    s) echo "${n}" ;;
    m) echo $(( n * 60 )) ;;
    h) echo $(( n * 3600 )) ;;
    d) echo $(( n * 86400 )) ;;
  esac
}

deadline_banner() {
  # Written to STDERR so it survives a caller that pipes stdout into a parser
  # (run-integration-tests.sh and friends `tee` drive output), and framed with
  # a fixed marker so log triage can grep one string across every lane.
  local label="$1" deadline="$2" signal="$3"
  {
    echo
    echo "================ E2E INNER DEADLINE EXCEEDED ================"
    echo "[${DEADLINE_SCRIPT_NAME}] ${label} exceeded its ${deadline} deadline (${signal})."
    echo
    echo "This is the lane's INNER bound — a coreutils timeout deliberately"
    echo "sized BELOW the step's timeout-minutes, which is itself below the"
    echo "job's. It fired first ON PURPOSE: the step's if: failure()"
    echo "diagnostics, secret scan and artifact upload still run, so the"
    echo "evidence for this hang is in this run's artifacts. A job-cap death"
    echo "would have skipped all three."
    echo
    echo "Triage: the hang is INSIDE ${label} — the emulator, adb"
    echo "install/grant, or flutter drive. Start from the uploaded logcat and"
    echo "drive log, not from this script."
    echo "============================================================"
    echo
  } >&2
}

# run_with_deadline <deadline> <label> -- <command...>
run_with_deadline() {
  local deadline label
  deadline="${1:-}"
  label="${2:-}"

  if [[ -z "${deadline}" || -z "${label}" ]]; then
    echo "ERROR: usage: ${DEADLINE_SCRIPT_NAME}.sh <deadline> <label> -- <command> [args...]" >&2
    return 2
  fi
  if [[ ! "${deadline}" =~ ${DEADLINE_RE} ]]; then
    echo "ERROR: deadline '${deadline}' needs an explicit unit (e.g. 28m, 90s)." \
         "A bare number is SECONDS to coreutils timeout — almost never what a" \
         "lane means, and it would kill every healthy run." >&2
    return 2
  fi
  shift 2
  if [[ "${1:-}" != "--" ]]; then
    echo "ERROR: expected '--' after <label>, got '${1:-<nothing>}'." \
         "The separator is mandatory so a stray label can never be executed." >&2
    return 2
  fi
  shift
  if (( $# == 0 )); then
    echo "ERROR: no command after '--'." >&2
    return 2
  fi

  local grace="${HAVEN_DEADLINE_KILL_GRACE:-60s}"
  if [[ ! "${grace}" =~ ${DEADLINE_RE} ]]; then
    echo "ERROR: HAVEN_DEADLINE_KILL_GRACE '${grace}' needs an explicit unit." >&2
    return 2
  fi

  echo "[${DEADLINE_SCRIPT_NAME}] ${label}: deadline ${deadline} (SIGKILL +${grace})"

  # `|| rc=$?` rather than an `if`: `set -e` must not swallow the command's
  # exit code, because passing it through UNCHANGED is this script's whole
  # contract for the non-timeout cases.
  local rc=0 start_ts="${SECONDS}"
  timeout --kill-after="${grace}" "${deadline}" "$@" || rc=$?
  local elapsed=$(( SECONDS - start_ts ))

  # 124 = coreutils killed it at the deadline. 137 = 128+SIGKILL, i.e. the
  # command ignored SIGTERM and coreutils escalated after the grace. Both are
  # "the deadline fired"; they are normalised to 124 so every caller has ONE
  # timeout code to key on (run-relay-customization.sh's cold-attach retry and
  # run-single-avd-scenario.sh's no-retry-on-hang rule both test for 124).
  if (( rc == 124 )); then
    # ...but 124 is also what the command returns when ITS OWN inner `timeout`
    # fired — every harness script bounds each `flutter drive` that way, and
    # coreutils gives the caller no way to tell the two apart by exit code.
    # Elapsed time does. Claiming "the step exceeded 25m" when what actually
    # happened is "one target exceeded its 10m per-drive bound, 6 minutes in"
    # would point triage at the wrong bound entirely — the precise failure this
    # banner exists to prevent, reintroduced one layer up.
    local budget
    budget="$(deadline_secs "${deadline}")"
    if (( elapsed + 2 >= budget )); then
      deadline_banner "${label}" "${deadline}" "SIGTERM at deadline"
    else
      echo "[${DEADLINE_SCRIPT_NAME}] ${label}: command exited 124 after ${elapsed}s," \
           "well inside the ${deadline} deadline — this is the COMMAND's own timeout" \
           "(a per-drive bound inside the harness), not ours. Read the harness log." >&2
    fi
    return 124
  fi
  if (( rc == 137 )); then
    deadline_banner "${label}" "${deadline}" "SIGKILL after ${grace} grace — the command ignored SIGTERM"
    return 124
  fi
  return "${rc}"
}

# ---------------------------------------------------------------------------
# Self-test (hermetic; no emulator, no network) — wired into repo-guards.yml.
#
# What it has to prove is narrow but load-bearing: this script sits in the
# failure path of every Android lane, so a regression here does not break a
# test, it breaks the ABILITY TO TELL WHY a test broke. The cases below are
# the ones where a plausible edit changes the meaning:
#   pass-through of a NON-timeout exit code (a real red must not be reported
#   as a hang), normalisation of 137 (a SIGTERM-ignoring drive is still a
#   hang), and rejection of a unit-less deadline (the seconds-vs-minutes trap).
# ---------------------------------------------------------------------------

self_test() {
  local failures=0
  local out rc

  _case() {
    local desc="$1"; shift
    local want_rc="$1"; shift
    local want_grep="$1"; shift
    rc=0
    out="$("$@" 2>&1)" || rc=$?
    if (( rc != want_rc )); then
      echo "FAIL: ${desc}: expected rc ${want_rc}, got ${rc}" >&2
      echo "  output: ${out}" >&2
      failures=$((failures + 1))
      return
    fi
    if [[ -n "${want_grep}" ]] && ! grep -q -- "${want_grep}" <<<"${out}"; then
      echo "FAIL: ${desc}: output did not contain '${want_grep}'" >&2
      echo "  output: ${out}" >&2
      failures=$((failures + 1))
      return
    fi
    if [[ -z "${want_grep}" ]] && grep -q "DEADLINE EXCEEDED" <<<"${out}"; then
      echo "FAIL: ${desc}: banner printed for a non-timeout outcome" >&2
      failures=$((failures + 1))
      return
    fi
    echo "  ok: ${desc}"
  }

  echo "[${DEADLINE_SCRIPT_NAME}] self-test"

  # 1. A command that finishes inside the deadline passes through rc 0 and
  #    prints NO banner (a banner on a green run would train people to ignore
  #    it, which is the failure mode this whole script exists to avoid).
  _case "fast command -> rc 0, no banner" 0 "" \
    run_with_deadline 10s ok-lane -- true

  # 2. A command that outlives the deadline is reported as 124 WITH the banner,
  #    and the banner names the lane — that naming is the "attributably" half
  #    of the contract.
  _case "overrunning command -> rc 124 + banner naming the lane" 124 "slow-lane exceeded its 1s deadline" \
    run_with_deadline 1s slow-lane -- sleep 5

  # 3. A genuine failure passes its own code through. If this ever returned
  #    124, run-relay-customization.sh would retry real assertion failures and
  #    a red could flake green — the single most damaging regression possible
  #    in this file.
  _case "failing command -> own rc, no banner" 3 "" \
    run_with_deadline 10s red-lane -- bash -c 'exit 3'

  # 4. A command that TRAPS SIGTERM still ends as a timeout: coreutils
  #    escalates to SIGKILL after the grace (rc 137) and we normalise to 124.
  #    A wedged `flutter drive` holding a VM-service socket is exactly this.
  HAVEN_DEADLINE_KILL_GRACE=1s _case "SIGTERM-ignoring command -> normalised to 124" 124 "ignored SIGTERM" \
    run_with_deadline 1s stubborn-lane -- bash -c 'trap "" TERM; sleep 10'

  # 5..7. Misuse is rc 2, never 124 and never 0 — a broken caller must not be
  #    indistinguishable from a hang, nor silently succeed.
  _case "unit-less deadline rejected" 2 "needs an explicit unit" \
    run_with_deadline 30 bad-lane -- true
  _case "missing -- separator rejected" 2 "expected '--'" \
    run_with_deadline 10s bad-lane true
  _case "no command after -- rejected" 2 "no command after" \
    run_with_deadline 10s bad-lane --

  # 8. A label with spaces survives intact into the banner (lane names in the
  #    workflows are written as human phrases).
  _case "multi-word label preserved" 124 "e2e integration drive exceeded" \
    run_with_deadline 1s "e2e integration drive" -- sleep 5

  # 9. A command that returns 124 ON ITS OWN, well inside the deadline, is the
  #    harness's per-drive timeout propagating up. It must still surface as 124
  #    (the caller's contract) but must NOT be reported as this deadline
  #    firing, or triage is sent to the wrong bound. `grep -v` semantics are
  #    covered by _case's no-banner assertion for the empty want_grep, so this
  #    asserts the distinguishing message instead.
  rc=0
  out="$(run_with_deadline 60s inner-lane -- bash -c 'exit 124' 2>&1)" || rc=$?
  if (( rc != 124 )); then
    echo "FAIL: command's own 124: expected rc 124, got ${rc}" >&2
    failures=$((failures + 1))
  elif grep -q "DEADLINE EXCEEDED" <<<"${out}"; then
    echo "FAIL: command's own 124 was misreported as this deadline firing" >&2
    echo "  output: ${out}" >&2
    failures=$((failures + 1))
  elif ! grep -q "not ours" <<<"${out}"; then
    echo "FAIL: command's own 124 was not distinguished in the log" >&2
    echo "  output: ${out}" >&2
    failures=$((failures + 1))
  else
    echo "  ok: command's own 124 is passed through, not misattributed"
  fi

  if (( failures > 0 )); then
    echo "[${DEADLINE_SCRIPT_NAME}] self-test FAILED (${failures} case(s))" >&2
    return 1
  fi
  echo "[${DEADLINE_SCRIPT_NAME}] self-test passed (9 cases)"
  return 0
}

# Only act when executed directly, so a future caller may `source` the helper.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if [[ "${1:-}" == "--self-test" ]]; then
    self_test
    exit $?
  fi
  rc=0
  run_with_deadline "$@" || rc=$?
  exit "${rc}"
fi
