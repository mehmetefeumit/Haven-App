#!/usr/bin/env bash
# CI guard: the device-clock skew policy must not drift between Rust and Dart.
#
# The policy has one authoritative home — `haven-core/src/relay/clock_skew.rs` —
# and one unavoidable mirror in Dart. There is no shared source of truth across
# the FFI (the same constraint documented on `LOCATION_MESSAGE_RETENTION_SECS`),
# so the mirror is checked here instead of trusted.
#
# Three things must agree, and each has a distinct failure mode if it does not:
#
#   1. THE WIRE TOKEN. `RelayError::DeviceClockRejected`'s `Display` is the only
#      channel through which a device-clock classification survives the FFI's
#      `Result<T, String>` error flattening. If the Rust literal and the Dart
#      matcher diverge by even one character, Dart stops recognising a
#      fast-clock rejection and the failure goes SILENT again — which is the
#      entire defect this policy exists to fix. Nothing else would fail: the
#      code compiles, the tests on each side pass, and the banner simply never
#      appears.
#
#   2. THE ALERT THRESHOLD. Widening it hides real breakage; narrowing it cries
#      wolf. Both sides carry a pinning test, but only this guard catches the
#      case where someone updates one side's constant AND its test together and
#      leaves the other side behind.
#
#   3. THE TOTAL-LOSS POINT. `retention + receiver grace` is the arithmetic the
#      receiver actually performs; the threshold's upper bound is justified
#      against it. If the Dart mirror drifts, the Dart pinning test would keep
#      passing against a bound that is no longer real.
#
# Pure-grep gate (no Rust or Flutter toolchain) so it runs fast in the shared
# repo-guards job.
#
# Exit codes:
#   0  all checks pass
#   1  a divergence was found

set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly RUST_POLICY="${repo_root}/haven-core/src/relay/clock_skew.rs"
readonly DART_DETECTOR="${repo_root}/haven/lib/src/services/clock_skew_detector.dart"
readonly DART_CONSTANTS="${repo_root}/haven/lib/src/constants/location.dart"

fail=0

note_fail() {
  echo "FAIL: $*" >&2
  fail=1
}

for f in "${RUST_POLICY}" "${DART_DETECTOR}" "${DART_CONSTANTS}"; do
  if [[ ! -f "${f}" ]]; then
    note_fail "missing file: ${f#"${repo_root}/"}"
  fi
done
if (( fail != 0 )); then
  echo "check_clock_skew_policy_parity.sh: FAILED" >&2
  exit 1
fi

# --- 1. The wire token -------------------------------------------------------
#
# Extracted from the const definitions on both sides rather than matched
# against a literal written here: a guard that hard-codes the value would keep
# passing after a deliberate, coordinated rename, and would then be checking
# nothing.
rust_token="$(sed -n 's/^pub const DEVICE_CLOCK_REJECTED_TOKEN: &str = "\(.*\)";$/\1/p' \
  "${RUST_POLICY}" | head -1)"
dart_token="$(sed -n "s/^      '\(haven\.clock\.[a-z_]*\)';$/\1/p" \
  "${DART_DETECTOR}" | head -1)"

if [[ -z "${rust_token}" ]]; then
  note_fail "could not read DEVICE_CLOCK_REJECTED_TOKEN from ${RUST_POLICY#"${repo_root}/"} \
— the declaration moved or changed shape, so this guard is scanning nothing."
elif [[ -z "${dart_token}" ]]; then
  note_fail "could not read deviceClockRejectedToken from ${DART_DETECTOR#"${repo_root}/"} \
— the declaration moved or changed shape, so this guard is scanning nothing."
elif [[ "${rust_token}" != "${dart_token}" ]]; then
  note_fail "device-clock wire token diverged: Rust says '${rust_token}', Dart says \
'${dart_token}'. Dart would stop recognising a fast-clock rejection and the failure would \
go silent again."
else
  echo "  [1/3] wire token agrees ('${rust_token}')."
fi

# --- 2. The alert threshold --------------------------------------------------
#
# Rust defines it as `2 * RECEIVER_EXPIRATION_GRACE_SECS`, so the numeric value
# is read from the pinning test's literal (which is itself asserted equal to the
# expression by `clock_skew_threshold_is_pinned`). Reading the test's pin rather
# than evaluating the expression keeps this a pure-grep gate without letting it
# read a number nothing enforces.
rust_threshold="$(sed -n 's/^            threshold, \([0-9]\+\),$/\1/p' \
  "${RUST_POLICY}" | head -1)"
dart_threshold="$(sed -n \
  's/^const Duration kClockSkewAlertThreshold = Duration(seconds: \([0-9]\+\));$/\1/p' \
  "${DART_CONSTANTS}" | head -1)"

if [[ -z "${rust_threshold}" ]]; then
  note_fail "could not read the pinned threshold from \
${RUST_POLICY#"${repo_root}/"} (clock_skew_threshold_is_pinned) — the pin moved or changed \
shape, so this guard is scanning nothing."
elif [[ -z "${dart_threshold}" ]]; then
  note_fail "could not read kClockSkewAlertThreshold from \
${DART_CONSTANTS#"${repo_root}/"} — the declaration moved or changed shape, so this guard \
is scanning nothing."
elif [[ "${rust_threshold}" != "${dart_threshold}" ]]; then
  note_fail "clock-skew alert threshold diverged: Rust pins ${rust_threshold}s, Dart \
declares ${dart_threshold}s. One side would warn at a magnitude the other considers fine."
else
  echo "  [2/3] alert threshold agrees (${rust_threshold}s)."
fi

# --- 3. The total-loss point -------------------------------------------------
rust_total_loss="$(sed -n 's/^        assert_eq!(TOTAL_LOSS_SKEW_SECS, \([0-9]\+\) + \([0-9]\+\));$/\1 \2/p' \
  "${RUST_POLICY}" | head -1)"
if [[ -n "${rust_total_loss}" ]]; then
  # shellcheck disable=SC2086  # deliberate split into the two addends
  set -- ${rust_total_loss}
  rust_total_loss=$(( $1 + $2 ))
fi
dart_total_loss="$(sed -n \
  's/^const Duration kClockSkewTotalLossThreshold = Duration(seconds: \([0-9]\+\));$/\1/p' \
  "${DART_CONSTANTS}" | head -1)"

if [[ -z "${rust_total_loss}" ]]; then
  note_fail "could not read the total-loss arithmetic from \
${RUST_POLICY#"${repo_root}/"} (total_loss_point_is_the_receiver_gate) — the assertion moved \
or changed shape, so this guard is scanning nothing."
elif [[ -z "${dart_total_loss}" ]]; then
  note_fail "could not read kClockSkewTotalLossThreshold from \
${DART_CONSTANTS#"${repo_root}/"} — the declaration moved or changed shape."
elif [[ "${rust_total_loss}" != "${dart_total_loss}" ]]; then
  note_fail "total-loss point diverged: Rust computes ${rust_total_loss}s (retention + \
receiver grace), Dart declares ${dart_total_loss}s. The Dart threshold's upper bound would \
be justified against a number that is no longer real."
else
  echo "  [3/3] total-loss point agrees (${rust_total_loss}s)."
fi

if (( fail != 0 )); then
  echo "check_clock_skew_policy_parity.sh: FAILED" >&2
  exit 1
fi

echo "check_clock_skew_policy_parity.sh: OK"
