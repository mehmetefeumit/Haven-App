#!/usr/bin/env bash
#
# Secret-leak guard for E2E logs (CLAUDE.md Security Rule #6: "NEVER log,
# print, or expose key material").
#
# Scans captured logcat + flutter-drive logs for key material and FAILS
# (exit 1) if any is found. This is the CI enforcement that property
# "no sensitive logging" previously lacked: it caught a real regression
# where keyring-core 0.7 logged the raw SQLCipher DB-key bytes at DEBUG
# (`secret: Some([..])`) into world-readable CI logs and artifacts. The
# source-side fix is the `keyring_core` log filter in
# `haven/rust_builder/src/api.rs::init_app`; THIS guard is the belt to
# that suspenders — it also catches any FUTURE leak the filter misses.
#
# # Why the patterns are narrow
#
# `adb logcat -v threadtime` captures the ENTIRE device, not just Haven's
# process, so a bare "any long byte array" pattern would false-positive on
# unrelated Android system logs and flake the lane red. Every pattern here
# is therefore a specific secret SHAPE (Rust `Debug` of a credential, a
# bech32 nsec, or a secret-keyword immediately followed by a byte array)
# that does not occur in incidental system output.
#
# # Output never re-leaks
#
# On a hit we print only `file [label] line(s): N` — never the matched
# content — so the guard's own output (itself a CI log) can't echo the
# secret it just caught.
#
# Usage:
#   bash tooling/e2e/ci/scan-logs-for-secrets.sh <log-file-or-dir> [more...]
#   bash tooling/e2e/ci/scan-logs-for-secrets.sh --self-test
#
# Exit codes: 0 = clean / nothing to scan; 1 = secret material found or
# self-test failed; 2 = usage error.

set -euo pipefail

# Forbidden patterns (ERE) and their human labels, index-aligned. Kept
# specific enough to be safe against a device-wide logcat (see header).
readonly -a PATTERNS=(
  'secret:[[:space:]]*Some\(\['
  'password:[[:space:]]*Some\(\['
  'nsec1[ac-hj-np-z02-9]{20,}'
  '(secret|seed|exporter_secret|private[_-]?key)[^]]{0,30}\[[0-9]{1,3}(,[[:space:]]*[0-9]{1,3}){15,}\]'
)
readonly -a LABELS=(
  'keyring secret byte-dump'
  'keyring password byte-dump'
  'bech32 nsec (private key)'
  'labeled key byte-array'
)

usage() {
  echo "Usage: $0 <log-file-or-dir> [more...]  |  $0 --self-test" >&2
}

# scan_file <path> — returns 1 if any forbidden pattern matched, else 0.
# Prints only file + label + line numbers (never the matched content).
scan_file() {
  local file="$1" rc=0 i linenos
  [[ -f "${file}" ]] || return 0
  for i in "${!PATTERNS[@]}"; do
    # `-a` treats the (possibly binary-tainted) logcat as text; `-n` gives
    # line numbers, which we isolate with `cut` so the secret never prints.
    linenos="$(grep -aEn -- "${PATTERNS[$i]}" "${file}" 2>/dev/null | cut -d: -f1 | tr '\n' ' ' || true)"
    if [[ -n "${linenos// /}" ]]; then
      rc=1
      echo "LEAK: ${file} [${LABELS[$i]}] at line(s): ${linenos}" >&2
    fi
  done
  return "${rc}"
}

self_test() {
  local tmp clean dirty fail=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  clean="${tmp}/clean.log"
  dirty="${tmp}/dirty.log"

  # Realistic CLEAN log: event-id/pubkey prefixes, counts, runtimeType, a
  # short non-secret array and a numeric-heavy system line — must NOT trip.
  printf '%s\n' \
    'I/haven: [LocationService] evt=a1b2c3d4 published to 2 relay(s)' \
    'D/RustStdoutStderr: decrypt ok sender=deadbeef (3 new, 0 failed)' \
    'I/ActivityManager: Start proc 12345:com.oblivioustech.haven/u0a99' \
    'D/sensors: latest reading [1, 2, 3]' \
    'I/flutter: REJECTED by relay: FormatException' > "${clean}"

  # DIRTY log: the exact keyring_core leak shape (also a labeled byte
  # array) plus a bech32 nsec — every line MUST be caught.
  printf '%s\n' \
    'D/keyring_core: created entry Cred { specifiers: ("x","circles.db.key"), secret: Some([17, 80, 157, 233, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28]) }' \
    'I/restore: recovery nsec1acdefghjklmnpqrstuvwxyz023456789acdefghjkl' > "${dirty}"

  # The clean log must pass (scan_file returns 0).
  if ! scan_file "${clean}"; then
    echo "SELF-TEST FAIL: clean log was flagged as leaking" >&2
    fail=1
  fi
  # The dirty log must be caught (scan_file returns non-zero). Silence its
  # expected LEAK lines so the self-test output stays readable.
  if scan_file "${dirty}" 2>/dev/null; then
    echo "SELF-TEST FAIL: planted secret was NOT detected" >&2
    fail=1
  fi

  if (( fail )); then
    echo "scan-logs-for-secrets: SELF-TEST FAILED" >&2
    return 1
  fi
  echo "scan-logs-for-secrets: self-test passed (clean log clears, planted secrets caught)."
  return 0
}

main() {
  if [[ $# -lt 1 ]]; then
    usage
    exit 2
  fi
  if [[ "$1" == "--self-test" ]]; then
    self_test
    exit $?
  fi

  local -a files=()
  local arg f
  for arg in "$@"; do
    if [[ -d "${arg}" ]]; then
      while IFS= read -r -d '' f; do files+=("${f}"); done \
        < <(find "${arg}" -type f -name '*.log' -print0)
    elif [[ -f "${arg}" ]]; then
      files+=("${arg}")
    else
      echo "secret-scan: skipping non-existent path: ${arg}" >&2
    fi
  done

  if [[ ${#files[@]} -eq 0 ]]; then
    echo "secret-scan: no log files to scan (args: $*) — nothing to do."
    exit 0
  fi

  local leaked=0
  for f in "${files[@]}"; do
    scan_file "${f}" || leaked=1
  done

  if (( leaked )); then
    echo >&2
    echo "ERROR: secret material detected in E2E logs (see LEAK line(s) above)." >&2
    echo "       This violates Security Rule #6 (no key material in logs)." >&2
    exit 1
  fi
  echo "secret-scan: clean — scanned ${#files[@]} log file(s), no secret material found."
  exit 0
}

main "$@"
