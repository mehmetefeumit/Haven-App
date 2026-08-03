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
# # "Nothing to scan" is not "nothing leaked"
#
# Every path handed to this guard is a caller ASSERTION that the log exists.
# Until backlog A4 a missing file returned 0 ("skipping non-existent path"),
# so the crash case — a lane that died before it ever wrote a log — reported
# `no secret material found` on the strength of having looked at nothing.
# That is this repo's recurring false-green shape (cf. A3b, where `flutter
# drive` reported "All tests passed." over a failed suite), and on a PRIVACY
# control it is the worst instance of it: the guard answers a question it
# never asked. An unusable log is therefore its own FAILURE class with its
# own exit code, distinct from both "clean" and "leaking".
#
# Usage:
#   bash tooling/e2e/ci/scan-logs-for-secrets.sh <log-file-or-dir> [more...]
#   bash tooling/e2e/ci/scan-logs-for-secrets.sh --self-test
#
# Exit codes:
#   0 = every named log was present, readable, non-empty and clean
#   1 = secret material found (or self-test failed)
#   2 = usage error
#   3 = a named log was ABSENT, UNREADABLE, EMPTY, or a named directory held
#       no *.log at all — the scan could not be performed, so this run proves
#       nothing either way. Callers treat any non-zero as fatal; the separate
#       code exists so triage can tell "we found a leak" from "we found no
#       evidence" without parsing prose.

set -euo pipefail

# Named exit/return codes, so the "missing != clean" distinction is impossible
# to collapse by an accidental `return 0` during a later edit.
readonly RC_CLEAN=0
readonly RC_LEAK=1
readonly RC_USAGE=2
readonly RC_UNUSABLE=3

# Absolute-ish path to THIS script, used by --self-test to exercise the real
# `main` end-to-end (see self_test) rather than only its internals.
SELF_PATH="${BASH_SOURCE[0]}"
readonly SELF_PATH

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

# scan_file <path> — RC_CLEAN if the file is scannable and clean, RC_LEAK if
# any forbidden pattern matched, RC_UNUSABLE if it could not be scanned at all.
# Prints only file + label + line numbers (never the matched content).
scan_file() {
  local file="$1" rc=0 i linenos
  # Usability gate. Each branch is a DIFFERENT operator failure and each says
  # so, because "the log is missing" and "the log is clean" demand opposite
  # responses and used to be indistinguishable in this guard's output.
  if [[ ! -e "${file}" ]]; then
    echo "UNUSABLE: ${file} [absent] — expected log does not exist; nothing was scanned." >&2
    return "${RC_UNUSABLE}"
  fi
  if [[ ! -f "${file}" ]]; then
    echo "UNUSABLE: ${file} [not a regular file] — refusing to treat as a scanned log." >&2
    return "${RC_UNUSABLE}"
  fi
  if [[ ! -r "${file}" ]]; then
    # `grep` on an unreadable file exits non-zero with an empty match set, and
    # the `|| true` below would launder that into "no matches" — i.e. clean.
    # Catch it here instead, while the cause is still known.
    echo "UNUSABLE: ${file} [unreadable] — exists but permission denied; nothing was scanned." >&2
    return "${RC_UNUSABLE}"
  fi
  # EMPTY is deliberately fatal, exactly like ABSENT.
  #
  # `cmd > file &` creates the file at REDIRECTION time, before the command has
  # written a byte. So a lane that dies immediately after starting its logcat
  # leaves a zero-byte log, while a lane that dies a moment earlier leaves none
  # at all: the same crash, in two states, decided by scheduling. Passing one
  # and failing the other would make this guard's verdict on an identical
  # failure a coin flip, and a nondeterministic privacy control is not a
  # control. Zero bytes is also independently damning — every log this guard is
  # ever pointed at (a device-wide logcat, a `flutter drive` / `flutter test`
  # transcript, `docker logs strfry`) is non-empty within moments of starting on
  # a healthy lane, so an empty one means the capture never worked and the run
  # has no evidence to offer.
  if [[ ! -s "${file}" ]]; then
    echo "UNUSABLE: ${file} [empty] — 0 bytes; the capture never wrote anything." >&2
    return "${RC_UNUSABLE}"
  fi
  for i in "${!PATTERNS[@]}"; do
    # `-a` treats the (possibly binary-tainted) logcat as text; `-n` gives
    # line numbers, which we isolate with `cut` so the secret never prints.
    linenos="$(grep -aEn -- "${PATTERNS[$i]}" "${file}" 2>/dev/null | cut -d: -f1 | tr '\n' ' ' || true)"
    if [[ -n "${linenos// /}" ]]; then
      rc="${RC_LEAK}"
      echo "LEAK: ${file} [${LABELS[$i]}] at line(s): ${linenos}" >&2
    fi
  done
  return "${rc}"
}

# expect_rc <want-rc> <description> <args...> — run a FULL `main` invocation of
# this script in a child shell and assert its exit code.
#
# The A4 false-green did not live in scan_file alone: `main`'s arg loop printed
# "skipping non-existent path" and then exited 0 via the "nothing to do" branch.
# A self-test that only reached in and called scan_file would have stayed green
# while the hole it is supposed to guard stayed wide open, so these assertions
# go through the real entry point. Pure bash, no toolchain, no network.
expect_rc() {
  local want="$1" desc="$2"
  shift 2
  local got=0
  bash "${SELF_PATH}" "$@" >/dev/null 2>&1 || got=$?
  if [[ "${got}" != "${want}" ]]; then
    echo "SELF-TEST FAIL: ${desc} — expected rc=${want}, got rc=${got}" >&2
    return 1
  fi
  return 0
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

  # -------------------------------------------------------------------------
  # SCANNABILITY fixtures (backlog A4). Everything above proves the guard can
  # tell a clean log from a leaking one; these prove it can tell either from NO
  # log — the crash case, which used to be reported as clean.
  #
  # Asserted through `main` (see expect_rc) because that is where the defect
  # lived, and asserted on the EXACT exit code rather than merely "non-zero":
  # a clean run and a crashed run must never again be the same observation.
  # -------------------------------------------------------------------------
  local absent empty unreadable dir_empty dir_clean dir_dirty
  absent="${tmp}/never-written.log"          # deliberately never created
  empty="${tmp}/empty.log"
  unreadable="${tmp}/unreadable.log"
  dir_empty="${tmp}/dir-nologs"
  dir_clean="${tmp}/dir-clean"
  dir_dirty="${tmp}/dir-dirty"

  : > "${empty}"
  printf '%s\n' 'I/haven: nothing secret here' > "${unreadable}"
  chmod 000 "${unreadable}"
  mkdir -p "${dir_empty}" "${dir_clean}" "${dir_dirty}"
  # A non-.log file must NOT rescue a logless directory from the UNUSABLE
  # verdict — the directory walk only ever scans *.log, so anything else there
  # is unscanned by construction (cf. the `.log`-not-`.txt` note in
  # e2e-fgs-publish.yml's diag step).
  printf '%s\n' 'not a log' > "${dir_empty}/README.txt"
  cp "${clean}" "${dir_clean}/logcat.log"
  cp "${dirty}" "${dir_dirty}/logcat.log"

  # Baselines: the two states that must keep behaving exactly as before.
  expect_rc 0 "present-and-clean file" "${clean}" || fail=1
  expect_rc 1 "present-with-planted-secret file" "${dirty}" || fail=1

  # The reported defect, verbatim: a named log that was never written.
  expect_rc 3 "absent file" "${absent}" || fail=1
  # ...and its zero-byte twin (see the [empty] rationale in scan_file).
  expect_rc 3 "empty file" "${empty}" || fail=1

  # An unreadable file must not be laundered into "no matches found".
  # Skippable-with-a-reason rather than silently dropped: root defeats mode
  # 000, so on a root runner the fixture cannot be built at all. GitHub's
  # hosted runners execute as the non-root `runner` user, where it is live.
  if [[ -r "${unreadable}" ]]; then
    echo "scan-logs-for-secrets: NOTE — skipping the unreadable-file fixture" \
         "(running as uid $(id -u), which bypasses mode 000)." >&2
  else
    expect_rc 3 "unreadable file" "${unreadable}" || fail=1
  fi

  # Directory form of each verdict.
  expect_rc 0 "directory of clean logs" "${dir_clean}" || fail=1
  expect_rc 1 "directory containing a leaking log" "${dir_dirty}" || fail=1
  expect_rc 3 "directory with no *.log" "${dir_empty}" || fail=1
  expect_rc 3 "absent directory" "${tmp}/no-such-dir" || fail=1

  # MIXED args — the shape every real call site uses (a lane names its logcat
  # AND its drive log). One good log must never vouch for a missing one.
  expect_rc 3 "clean file + absent file" "${clean}" "${absent}" || fail=1
  expect_rc 3 "clean file + empty file" "${clean}" "${empty}" || fail=1
  # A real leak outranks missing evidence when both are present: callers key
  # their containment (log withholding) off rc=1.
  expect_rc 1 "leaking file + absent file" "${dirty}" "${absent}" || fail=1

  # Usage error stays distinct from all three verdicts.
  expect_rc 2 "no arguments" || fail=1

  # chmod back so the RETURN trap's `rm -rf` cannot be tripped up by an
  # unreadable leftover on hosts with restrictive umasks.
  chmod 644 "${unreadable}" 2>/dev/null || true

  if (( fail )); then
    echo "scan-logs-for-secrets: SELF-TEST FAILED" >&2
    return 1
  fi
  echo "scan-logs-for-secrets: self-test passed (clean clears, planted secrets caught," \
       "absent/unreadable/empty logs fail loudly)."
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
  # Paths the caller asserted would be scannable and were not. Counted, not
  # just flagged, so the final message can say how much evidence is missing.
  local -a unusable=()
  local arg f found
  for arg in "$@"; do
    if [[ -d "${arg}" ]]; then
      found=0
      while IFS= read -r -d '' f; do
        files+=("${f}")
        found=$(( found + 1 ))
      done < <(find "${arg}" -type f -name '*.log' -print0 2>/dev/null)
      # A logless directory is the crash case in directory form: the lane was
      # asked to hand over its logs and handed over none. Same reasoning as the
      # absent-file branch in scan_file — an empty evidence set is not an
      # exoneration. (This is why the two orchestrator lanes wired below scan
      # only where they actually deposit logs; see their call sites.)
      if (( found == 0 )); then
        echo "UNUSABLE: ${arg} [no logs] — directory holds no *.log; nothing was scanned." >&2
        unusable+=("${arg}")
      fi
    elif [[ -e "${arg}" ]]; then
      # Exists but may still be unreadable/empty/not-a-file: scan_file decides
      # and reports the precise reason.
      files+=("${arg}")
    else
      echo "UNUSABLE: ${arg} [absent] — expected log path does not exist; nothing was scanned." >&2
      unusable+=("${arg}")
    fi
  done

  local leaked=0 rc
  # Guarded because `"${files[@]}"` on an empty array is an unbound-variable
  # error under `set -u` in bash 3.2, still the default on the macOS runners
  # that host the iOS lanes.
  if (( ${#files[@]} > 0 )); then
    for f in "${files[@]}"; do
      rc=0
      scan_file "${f}" || rc=$?
      case "${rc}" in
        "${RC_CLEAN}") ;;
        "${RC_LEAK}") leaked=1 ;;
        *) unusable+=("${f}") ;;
      esac
    done
  fi

  if (( leaked )); then
    echo >&2
    echo "ERROR: secret material detected in E2E logs (see LEAK line(s) above)." >&2
    echo "       This violates Security Rule #6 (no key material in logs)." >&2
    # A confirmed leak outranks missing evidence when both occurred: it is the
    # actionable finding, and any UNUSABLE lines are already on stderr above.
    exit "${RC_LEAK}"
  fi
  if (( ${#unusable[@]} > 0 )); then
    echo >&2
    echo "ERROR: ${#unusable[@]} expected log path(s) could not be scanned" \
         "(see UNUSABLE line(s) above)." >&2
    echo "       An absent, unreadable or empty log is NOT a clean log. The lane" >&2
    echo "       most likely died before writing it, so this run carries NO" >&2
    echo "       evidence about key material reaching CI logs — which is exactly" >&2
    echo "       the case this guard exists to catch (Security Rule #6)." >&2
    exit "${RC_UNUSABLE}"
  fi
  echo "secret-scan: clean — scanned ${#files[@]} log file(s), no secret material found."
  exit "${RC_CLEAN}"
}

main "$@"
