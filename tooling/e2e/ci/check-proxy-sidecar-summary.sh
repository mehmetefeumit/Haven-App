#!/usr/bin/env bash
#
# Reads the recording proxy's shutdown summary back and fails the lane if its
# declaration channel lost anything.
#
# On SIGTERM `haven-wire-proxy` prints one line per sidecar it keeps for the
# runtime log scanner (tooling/e2e/local-relay/src/bin/wire_proxy.rs,
# `report_needle_channel`):
#
#   [haven-wire-proxy] needle sidecar: N declaration(s) recorded, N refused, N lost[ — STALE (…)]
#   [haven-wire-proxy] canary sidecar: N manifest(s) recorded, N repeat(s), N refused, N lost[ — STALE (…)]
#
# A REFUSED or LOST declaration is a needle the scanner never searched for, so
# its "clean" is quieter than the run believed; a STALE sidecar is a previous
# run's file appended to, so the seal carries a previous run's identifiers and
# this run's floors can be met by the wrong values. Neither is visible anywhere
# else — the scanner sees only what reached the file. Every summary in the log
# must be healthy: a recorder restarted mid-lane appends a second one, and the
# first is not excused by the second.
#
# Counts only. The lines are counts and fixed labels by construction, and this
# script prints them back as counts.
#
# Usage:
#   check-proxy-sidecar-summary.sh <proxy-log>
#   check-proxy-sidecar-summary.sh --self-test
#
# Exit codes:
#   0  both lines present in every summary, nothing refused or lost, no STALE
#   1  a line absent, a refused or lost count non-zero, or a STALE marker
#   2  usage error
#   3  the proxy log is absent, empty or unreadable — nothing was read

set -euo pipefail

readonly RC_OK=0
readonly RC_UNHEALTHY=1
readonly RC_USAGE=2
readonly RC_UNUSABLE=3

SELF_PATH="${BASH_SOURCE[0]}"
readonly SELF_PATH

readonly NEEDLE_RE='^\[haven-wire-proxy\] needle sidecar: ([0-9]+) declaration\(s\) recorded, ([0-9]+) refused, ([0-9]+) lost(.*)$'
readonly CANARY_RE='^\[haven-wire-proxy\] canary sidecar: ([0-9]+) manifest\(s\) recorded, ([0-9]+) repeat\(s\), ([0-9]+) refused, ([0-9]+) lost(.*)$'

# judge <label> <refused> <lost> <tail> — one FAIL line per finding, rc 1 if any.
judge() {
  local label="$1" refused="$2" lost="$3" tail="$4" rc=0
  if (( refused != 0 )); then
    echo "FAIL: ${label}: ${refused} declaration(s) refused by the recorder — a needle the scanner never searched for." >&2
    rc=1
  fi
  if (( lost != 0 )); then
    echo "FAIL: ${label}: ${lost} declaration(s) lost by the recorder — a needle the scanner never searched for." >&2
    rc=1
  fi
  if [[ "${tail}" == *STALE* ]]; then
    echo "FAIL: ${label}: STALE — a previous run's sidecar was appended to, so this run's manifest carries another run's identifiers. The needle directory must be rotated before the recorder starts." >&2
    rc=1
  fi
  return "${rc}"
}

check_summary() { # check_summary <proxy-log>
  local log="$1" line rc=0 needle_n=0 canary_n=0
  if [[ ! -f "${log}" || ! -r "${log}" || ! -s "${log}" ]]; then
    echo "UNUSABLE: ${log} is absent, unreadable or empty — the recorder wrote no summary, so its declaration channel is unaccounted for." >&2
    return "${RC_UNUSABLE}"
  fi
  while IFS= read -r line; do
    if [[ "${line}" =~ ${NEEDLE_RE} ]]; then
      needle_n=$(( needle_n + 1 ))
      echo "proxy declaration channel: needle sidecar ${BASH_REMATCH[1]} recorded, ${BASH_REMATCH[2]} refused, ${BASH_REMATCH[3]} lost"
      judge "needle sidecar" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}" || rc=1
    elif [[ "${line}" =~ ${CANARY_RE} ]]; then
      canary_n=$(( canary_n + 1 ))
      echo "proxy declaration channel: canary sidecar ${BASH_REMATCH[1]} recorded, ${BASH_REMATCH[2]} repeat(s), ${BASH_REMATCH[3]} refused, ${BASH_REMATCH[4]} lost"
      judge "canary sidecar" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}" "${BASH_REMATCH[5]}" || rc=1
    fi
  done < "${log}"
  if (( needle_n == 0 )); then
    echo "FAIL: no needle-sidecar summary line in ${log##*/} — the recorder never printed its shutdown account (killed without SIGTERM, or the line changed shape), so its declaration channel is unaccounted for." >&2
    rc=1
  fi
  if (( canary_n == 0 )); then
    echo "FAIL: no canary-sidecar summary line in ${log##*/} — the recorder never printed its shutdown account, so the wire-canary manifest channel is unaccounted for." >&2
    rc=1
  fi
  return "${rc}"
}

readonly SELF_TEST_FIXTURES=16

run_self_test() {
  local tmp fail=0 ran=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  local healthy_needle='[haven-wire-proxy] needle sidecar: 12 declaration(s) recorded, 0 refused, 0 lost'
  local healthy_canary='[haven-wire-proxy] canary sidecar: 1 manifest(s) recorded, 0 repeat(s), 0 refused, 0 lost'
  local stale=' — STALE (a previous run'"'"'s file was appended to)'

  # expect <label> <want-rc> <lines...> — writes the lines as the proxy log and
  # runs the real script over it.
  expect() {
    local label="$1" want="$2" rc=0
    shift 2
    printf '%s\n' "$@" > "${tmp}/proxy.log"
    ran=$(( ran + 1 ))
    bash "${SELF_PATH}" "${tmp}/proxy.log" > "${tmp}/out" 2>&1 || rc=$?
    if (( rc != want )); then
      echo "SELF-TEST FAIL (${label}): wanted rc ${want}, got ${rc}" >&2
      fail=1
    fi
  }

  local noise='[haven-wire-proxy] shutting down: 3 connection(s), 40 record(s) observed, 40 line(s) written'
  expect "healthy"                         0 "${noise}" "${healthy_needle}" "${healthy_canary}"
  expect "needle refused"                  1 "${noise}" '[haven-wire-proxy] needle sidecar: 12 declaration(s) recorded, 1 refused, 0 lost' "${healthy_canary}"
  expect "needle lost"                     1 "${noise}" '[haven-wire-proxy] needle sidecar: 12 declaration(s) recorded, 0 refused, 2 lost' "${healthy_canary}"
  expect "canary refused"                  1 "${noise}" "${healthy_needle}" '[haven-wire-proxy] canary sidecar: 1 manifest(s) recorded, 0 repeat(s), 1 refused, 0 lost'
  expect "canary lost"                     1 "${noise}" "${healthy_needle}" '[haven-wire-proxy] canary sidecar: 0 manifest(s) recorded, 0 repeat(s), 0 refused, 1 lost'
  expect "needle STALE"                    1 "${noise}" "${healthy_needle}${stale}" "${healthy_canary}"
  expect "canary STALE"                    1 "${noise}" "${healthy_needle}" "${healthy_canary}${stale}"
  expect "needle line absent"              1 "${noise}" "${healthy_canary}"
  expect "canary line absent"              1 "${noise}" "${healthy_needle}"
  expect "a mis-shaped line is absent"     1 "${noise}" '[haven-wire-proxy] needle sidecar: some declarations recorded' "${healthy_canary}"
  # A restarted recorder appends a second summary; the first is not excused.
  expect "an earlier unhealthy summary is not masked by a later healthy one" 1 \
    "${noise}" '[haven-wire-proxy] needle sidecar: 3 declaration(s) recorded, 0 refused, 1 lost' "${healthy_canary}" \
    "${noise}" "${healthy_needle}" "${healthy_canary}"
  # A repeat is not a fault (the proxy de-duplicates an identical manifest).
  expect "canary repeats are not a fault"  0 "${noise}" "${healthy_needle}" '[haven-wire-proxy] canary sidecar: 1 manifest(s) recorded, 2 repeat(s), 0 refused, 0 lost'

  # Nothing to read is rc 3, never a pass.
  local rc=0
  ran=$(( ran + 1 ))
  bash "${SELF_PATH}" "${tmp}/absent.log" > "${tmp}/out" 2>&1 || rc=$?
  if (( rc != 3 )); then echo "SELF-TEST FAIL (absent log): wanted rc 3, got ${rc}" >&2; fail=1; fi
  : > "${tmp}/empty.log"
  rc=0
  ran=$(( ran + 1 ))
  bash "${SELF_PATH}" "${tmp}/empty.log" > "${tmp}/out" 2>&1 || rc=$?
  if (( rc != 3 )); then echo "SELF-TEST FAIL (empty log): wanted rc 3, got ${rc}" >&2; fail=1; fi

  # Usage errors stay distinct from every verdict.
  rc=0
  ran=$(( ran + 1 ))
  bash "${SELF_PATH}" > "${tmp}/out" 2>&1 || rc=$?
  if (( rc != 2 )); then echo "SELF-TEST FAIL (no arguments): wanted rc 2, got ${rc}" >&2; fail=1; fi

  # The read-back is counts only: the healthy run prints exactly the two count
  # lines, nothing quoted from the log beyond them.
  rc=0
  ran=$(( ran + 1 ))
  printf '%s\n' "${noise}" "${healthy_needle}" "${healthy_canary}" > "${tmp}/proxy.log"
  bash "${SELF_PATH}" "${tmp}/proxy.log" > "${tmp}/out" 2>&1 || rc=$?
  local want_out
  want_out="$(printf '%s\n%s' \
    'proxy declaration channel: needle sidecar 12 recorded, 0 refused, 0 lost' \
    'proxy declaration channel: canary sidecar 1 recorded, 0 repeat(s), 0 refused, 0 lost')"
  if (( rc != 0 )) || [[ "$(<"${tmp}/out")" != "${want_out}" ]]; then
    echo "SELF-TEST FAIL (counts only): the healthy read-back printed something other than the two count lines" >&2
    fail=1
  fi

  if (( fail )); then
    echo "check-proxy-sidecar-summary: SELF-TEST FAILED" >&2
    return 1
  fi
  if (( ran != SELF_TEST_FIXTURES )); then
    echo "check-proxy-sidecar-summary: SELF-TEST FAILED — ran ${ran} fixture(s), expected exactly ${SELF_TEST_FIXTURES}; a fixture was added or removed without moving the pin" >&2
    return 1
  fi
  echo "check-proxy-sidecar-summary: self-test passed (${ran}/${SELF_TEST_FIXTURES} fixtures: a healthy summary passes, a refused or lost count on either sidecar fails, a STALE marker fails, a missing or mis-shaped line fails, an earlier unhealthy summary is not masked, repeats are not a fault, an absent or empty log is rc 3, usage is rc 2, and the read-back prints counts only)."
  return 0
}

if [[ "${1:-}" == "--self-test" ]]; then
  run_self_test
  exit $?
fi

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <proxy-log>  |  $0 --self-test" >&2
  exit "${RC_USAGE}"
fi

check_summary "$1"
