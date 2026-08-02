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
  '(PRAGMA[[:space:]]+key|pragma_key|sqlcipher[_-]?key|db[_-]?key|passphrase)[^0-9a-fA-F]{0,24}[0-9a-fA-F]{64}'
  '(secret|seed|identity|private[_-]?key)[^A-Za-z0-9+/]{0,24}[A-Za-z0-9+/]{42,43}='
  '(flutter|RustStdoutStderr|keyring|haven|Haven).{0,200}\[[0-9]{1,3}(,[[:space:]]*[0-9]{1,3}){31}\]'
)
readonly -a LABELS=(
  'keyring secret byte-dump'
  'keyring password byte-dump'
  'bech32 nsec (private key)'
  'labeled key byte-array'
  'SQLCipher passphrase (hex-32)'
  'base64-encoded 32-byte secret'
  'unlabeled 32-byte array (key material or MLS group id)'
)

# On patterns 5-7 — added because the `e2e-fgs-publish` lane is the first to
# open the MLS SQLCipher database TWICE in one process while capturing a
# full-device debug log, which puts two previously-unmatched encodings in play:
# the SQLCipher passphrase (a 64-char hex string, `haven-core/src/nostr/mls/
# storage.rs`) and the identity secret at rest (base64, written by
# `TestUser.preSeedIdentityAndSkipOnboarding` and read back by the FGS isolate).
#
# Both are deliberately KEYWORD-ANCHORED rather than bare shape matches. A bare
# `[0-9a-f]{64}` would match every Nostr pubkey and event id in the logs — both
# public, both routinely printed by the harness — and would redden every lane on
# non-secrets. A guard that cries wolf is a guard that gets deleted.
#
# Pattern 7 needs no SECRET keyword — a 32-element decimal array on a Haven log
# line is never benign, being either raw key material or a 32-byte
# `nostr_group_id` (a Security Rule 4 violation in its own right). Pattern 4
# already catches the labeled case; this catches the rest. It is anchored to
# Haven's own log TAGS instead, because these scanners run over a DEVICE-WIDE
# logcat shared with every other lane: an unanchored array match would be free
# to fire on unrelated vendor/system output and redden lanes that leaked
# nothing. Tag-anchored keeps the blast radius inside code this repo owns.

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
    'I/flutter: REJECTED by relay: FormatException' \
    'I/flutter: [b1] fetchMemberKeypackage for 3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d' \
    'I/flutter: [coordination] waiting for event 5c83da77af1dec6d7289834998ad7aafbd9e2191396d75ec3cc27f5a77226f36' \
    'D/nostr: REQ ["kinds",[445]] authors=[npub1w0rthlessplaceholderpubkeynotasecret]' \
    'D/BackgroundTask: Published to 1/1 due circle(s) (1 eligible), fetched 1/1 circle(s).' \
    > "${clean}"

  # DIRTY log: the exact keyring_core leak shape (also a labeled byte
  # array) plus a bech32 nsec — every line MUST be caught.
  printf '%s\n' \
    'D/keyring_core: created entry Cred { specifiers: ("x","circles.db.key"), secret: Some([17, 80, 157, 233, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28]) }' \
    'I/restore: recovery nsec1acdefghjklmnpqrstuvwxyz023456789acdefghjkl' \
    "E/RustStdoutStderr: sqlite: file is not a database (PRAGMA key = 'a3f19c4e7b2d8051a3f19c4e7b2d8051a3f19c4e7b2d8051a3f19c4e7b2d8051')" \
    'D/flutter: [identity] restored secret AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE= from secure storage' \
    'D/flutter: raw bytes [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32]' \
    > "${dirty}"

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

  # PER-LINE proof. The combined check above is satisfied as soon as ANY one
  # pattern fires, so it would stay green with a newly-added pattern that
  # matches nothing — the repo's documented recurring failure mode (code that
  # looks complete and executes nowhere). Scanning each planted line on its own
  # proves every pattern is individually reachable.
  local line n=0 solo
  while IFS= read -r line; do
    n=$(( n + 1 ))
    solo="${tmp}/solo.${n}.log"
    printf '%s\n' "${line}" > "${solo}"
    if scan_file "${solo}" 2>/dev/null; then
      echo "SELF-TEST FAIL: dirty line ${n} was NOT detected by any pattern" >&2
      echo "  (a planted secret shape has no live pattern — see PATTERNS)" >&2
      fail=1
    fi
  done < "${dirty}"
  if (( n < 5 )); then
    echo "SELF-TEST FAIL: expected >=5 planted lines, found ${n}" >&2
    fail=1
  fi

  # Every CLEAN line must also clear on its own, so one forgiving line cannot
  # mask a pattern that false-positives on another. False positives are how a
  # guard earns its way into being deleted.
  n=0
  while IFS= read -r line; do
    n=$(( n + 1 ))
    solo="${tmp}/cleansolo.${n}.log"
    printf '%s\n' "${line}" > "${solo}"
    if ! scan_file "${solo}"; then
      echo "SELF-TEST FAIL: clean line ${n} was flagged as leaking" >&2
      fail=1
    fi
  done < "${clean}"

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
