#!/usr/bin/env bash
# CI guard: the device-clock skew policy must not drift between Rust and Dart.
#
# The policy has one authoritative home — `haven-core/src/relay/clock_skew.rs` —
# and one unavoidable mirror in Dart. There is no shared source of truth across
# the FFI (the same constraint documented on `LOCATION_MESSAGE_RETENTION_SECS`),
# so the mirror is checked here instead of trusted.
#
# Two things must agree, and each has a distinct failure mode if it does not.
# (The wire token and the rejection phrase tables were checked here too until
# Dart stopped reading either: a publish failure and a relay refusal now cross
# the FFI with the clock verdict as a typed field, classified in Rust alone.)
#
#   1. THE ALERT THRESHOLD. Widening it hides real breakage; narrowing it cries
#      wolf. Both sides carry a pinning test, but only this guard catches the
#      case where someone updates one side's constant AND its test together and
#      leaves the other side behind.
#
#   2. THE TOTAL-LOSS POINT. It IS the retention: `nostr-relay-pool` drops an
#      event on receipt once its expiration (`created_at + retention`) is
#      behind the receiver's clock, with no grace. The threshold's upper bound
#      and the banner copy are justified against it. If the Dart mirror drifts,
#      the Dart pinning test would keep passing against a bound that is no
#      longer real.
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
readonly DART_CONSTANTS="${repo_root}/haven/lib/src/constants/location.dart"
readonly RUST_TTL="${repo_root}/haven-core/src/location/ttl.rs"

fail=0

note_fail() {
  echo "FAIL: $*" >&2
  fail=1
}

for f in "${RUST_POLICY}" "${DART_CONSTANTS}" "${RUST_TTL}"; do
  if [[ ! -f "${f}" ]]; then
    note_fail "missing file: ${f#"${repo_root}/"}"
  fi
done
if (( fail != 0 )); then
  echo "check_clock_skew_policy_parity.sh: FAILED" >&2
  exit 1
fi

# --- 1. The alert threshold --------------------------------------------------
#
# Read from the declaration, which `clock_skew_threshold_is_pinned` pins.
rust_threshold="$(sed -n 's/^pub const CLOCK_SKEW_ALERT_THRESHOLD_SECS: u64 = \([0-9]\+\);$/\1/p' \
  "${RUST_POLICY}" | head -1)"
dart_threshold="$(sed -n \
  's/^const Duration kClockSkewAlertThreshold = Duration(seconds: \([0-9]\+\));$/\1/p' \
  "${DART_CONSTANTS}" | head -1)"

if [[ -z "${rust_threshold}" ]]; then
  note_fail "could not read CLOCK_SKEW_ALERT_THRESHOLD_SECS from \
${RUST_POLICY#"${repo_root}/"} — the declaration moved or changed shape, so this guard is \
scanning nothing."
elif [[ -z "${dart_threshold}" ]]; then
  note_fail "could not read kClockSkewAlertThreshold from \
${DART_CONSTANTS#"${repo_root}/"} — the declaration moved or changed shape, so this guard \
is scanning nothing."
elif [[ "${rust_threshold}" != "${dart_threshold}" ]]; then
  note_fail "clock-skew alert threshold diverged: Rust pins ${rust_threshold}s, Dart \
declares ${dart_threshold}s. One side would warn at a magnitude the other considers fine."
else
  echo "  [1/2] alert threshold agrees (${rust_threshold}s)."
fi

# --- 2. The total-loss point -------------------------------------------------
#
# Rust must DEFINE it as the retention (a literal or any other expression would
# be a number nothing ties to the pool's drop point), so its value is the
# retention's declared value.
rust_total_loss=""
if grep -qx 'pub const TOTAL_LOSS_SKEW_SECS: u64 = LOCATION_MESSAGE_RETENTION_SECS;' \
     "${RUST_POLICY}"; then
  rust_total_loss="$(sed -n \
    's/^pub const LOCATION_MESSAGE_RETENTION_SECS: u64 = \([0-9]\+\);$/\1/p' \
    "${RUST_TTL}" | head -1)"
fi
dart_total_loss="$(sed -n \
  's/^const Duration kClockSkewTotalLossThreshold = Duration(seconds: \([0-9]\+\));$/\1/p' \
  "${DART_CONSTANTS}" | head -1)"

if [[ -z "${rust_total_loss}" ]]; then
  note_fail "could not read the total-loss point: ${RUST_POLICY#"${repo_root}/"} must define \
TOTAL_LOSS_SKEW_SECS as LOCATION_MESSAGE_RETENTION_SECS, whose value is read from \
${RUST_TTL#"${repo_root}/"} — one of the two moved or changed shape, so this guard is \
scanning nothing."
elif [[ -z "${dart_total_loss}" ]]; then
  note_fail "could not read kClockSkewTotalLossThreshold from \
${DART_CONSTANTS#"${repo_root}/"} — the declaration moved or changed shape."
elif [[ "${rust_total_loss}" != "${dart_total_loss}" ]]; then
  note_fail "total-loss point diverged: Rust's is the retention, ${rust_total_loss}s; Dart \
declares ${dart_total_loss}s. The Dart threshold's upper bound would be justified against a \
number that is no longer real."
else
  echo "  [2/2] total-loss point agrees (${rust_total_loss}s)."
fi

if (( fail != 0 )); then
  echo "check_clock_skew_policy_parity.sh: FAILED" >&2
  exit 1
fi

echo "check_clock_skew_policy_parity.sh: OK"
