#!/usr/bin/env bash
# CI guard: the publish-cadence jitter fraction must not drift between Rust
# and Dart.
#
# The spread lives authoritatively in Rust —
# `PUBLISH_INTERVAL_JITTER_FRACTION_BP` (haven-core/src/location/ttl.rs) — and
# is pinned there by `publish_interval_jitter_fraction_bp_is_pinned`. Dart
# never reads that constant: it hard-codes the two endpoints it produces,
# `kLocationPublishMinInterval` / `kLocationPublishMaxInterval`
# (haven/lib/src/constants/location.dart), documented as "drift-check only;
# the authoritative bound lives in Rust". There is no shared source of truth
# across the FFI (the same constraint documented on
# `LOCATION_MESSAGE_RETENTION_SECS` and checked for the clock-skew policy by
# `check_clock_skew_policy_parity.sh`), so the mirror is checked here instead
# of trusted.
#
# `cargo test` and `flutter test` each keep their OWN side internally
# consistent — the Rust pin proves the constant did not move, the Dart
# `location_test.dart` proves min/max equal `nominal * (1 ∓ 0.4)` — but
# neither can see the other stack. Narrow the Rust fraction alone (both its
# constant AND its pinning test, correctly, together) and every existing gate
# stays green while the Dart constants become false documentation: the
# ±40% figure baked into their doc comments, and the "~6.6h to recover the
# mean" claim `PUBLISH_INTERVAL_JITTER_FRACTION_BP`'s own doc comment makes,
# would both silently stop describing what ships.
#
# Two things are checked, each with a distinct failure mode:
#
#   1. THE MINIMUM. `kLocationPublishMinInterval` must equal
#      `round(nominal * (10_000 - bp) / 10_000)`, where `nominal` is
#      `kLocationUpdateInterval` in seconds and `bp` is the Rust spread in
#      basis points. A narrowed Rust spread with an unchanged Dart minimum
#      makes the Dart floor SMALLER than what the engine can actually sample
#      down to — Dart would advertise a tighter floor than reality.
#
#   2. THE MAXIMUM. Symmetric on the ceiling. A widened Rust spread with an
#      unchanged Dart maximum makes the Dart-documented worst-case
#      inter-publish gap SMALLER than what the engine can actually produce —
#      the no-gap invariant Dart's own file header derives
#      (`LOCATION_MESSAGE_RETENTION_SECS = 228s > δ_max (168s) + 60s buffer`)
#      would be checked against a δ_max that is no longer real.
#
# Rounding matches Dart's own `(nominal * factor).round()` (round-half-up for
# the non-half values either side of this constant produces), not truncation.
#
# Pure-grep gate (no Rust or Flutter toolchain), belongs in the shared
# repo-guards job.
#
# Usage:
#   check_publish_jitter_fraction_parity.sh            # check the repo
#   check_publish_jitter_fraction_parity.sh --self-test
#
# Exit codes:
#   0  all checks pass
#   1  a divergence was found (including "could not read" — a moved/renamed
#      declaration scans nothing, which is a guard failure, not a pass)
#   2  self-test failed (the guard itself is broken)

set -Eeuo pipefail

SCRIPT_NAME="check_publish_jitter_fraction_parity"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

log() { printf '\033[1;34m[%s]\033[0m %s\n' "${SCRIPT_NAME}" "$*"; }
fail_msg() { printf '\033[1;31m[%s] FAIL:\033[0m %s\n' "${SCRIPT_NAME}" "$*" >&2; }
misconfig() { printf '\033[1;31m[%s] ERROR:\033[0m %s\n' "${SCRIPT_NAME}" "$*" >&2; exit 2; }

# ---------------------------------------------------------------------------
# check_parity <rust-ttl.rs> <dart-constants.dart>
#
# Extracted from the const DECLARATIONS on both sides, never a literal
# hard-coded here: a guard that hard-codes the value would keep passing after
# a deliberate, coordinated rename or edit, and would then be checking nothing.
# ---------------------------------------------------------------------------
check_parity() {
  local rust_ttl="$1" dart_constants="$2" fail=0

  local rust_bp_raw rust_bp
  rust_bp_raw="$(sed -n \
    's/^pub const PUBLISH_INTERVAL_JITTER_FRACTION_BP: u16 = \([0-9_]\+\);$/\1/p' \
    "${rust_ttl}" | head -1)"
  rust_bp="${rust_bp_raw//_/}"

  local dart_nominal_min dart_nominal_sec dart_nominal
  dart_nominal_min="$(sed -n \
    's/^const Duration kLocationUpdateInterval = Duration(minutes: \([0-9]\+\));$/\1/p' \
    "${dart_constants}" | head -1)"
  dart_nominal_sec="$(sed -n \
    's/^const Duration kLocationUpdateInterval = Duration(seconds: \([0-9]\+\));$/\1/p' \
    "${dart_constants}" | head -1)"
  if [[ -n "${dart_nominal_min}" ]]; then
    dart_nominal=$(( dart_nominal_min * 60 ))
  else
    dart_nominal="${dart_nominal_sec}"
  fi

  local dart_min dart_max
  dart_min="$(sed -n \
    's/^const Duration kLocationPublishMinInterval = Duration(seconds: \([0-9]\+\));$/\1/p' \
    "${dart_constants}" | head -1)"
  dart_max="$(sed -n \
    's/^const Duration kLocationPublishMaxInterval = Duration(seconds: \([0-9]\+\));$/\1/p' \
    "${dart_constants}" | head -1)"

  if [[ -z "${rust_bp}" ]]; then
    fail_msg "could not read PUBLISH_INTERVAL_JITTER_FRACTION_BP from \
${rust_ttl#"${REPO_ROOT}/"} — the declaration moved or changed shape, so this guard is \
scanning nothing."
    fail=1
  fi
  if [[ -z "${dart_nominal}" ]]; then
    fail_msg "could not read kLocationUpdateInterval from \
${dart_constants#"${REPO_ROOT}/"} — the declaration moved or changed shape, so this guard \
is scanning nothing."
    fail=1
  fi
  if [[ -z "${dart_min}" ]]; then
    fail_msg "could not read kLocationPublishMinInterval from \
${dart_constants#"${REPO_ROOT}/"} — the declaration moved or changed shape."
    fail=1
  fi
  if [[ -z "${dart_max}" ]]; then
    fail_msg "could not read kLocationPublishMaxInterval from \
${dart_constants#"${REPO_ROOT}/"} — the declaration moved or changed shape."
    fail=1
  fi
  (( fail == 0 )) || return 1

  # Round-half-up, matching Dart's `(nominal * factor).round()` for the
  # non-half values this arithmetic produces.
  local expected_min expected_max
  expected_min=$(( (dart_nominal * (10000 - rust_bp) + 5000) / 10000 ))
  expected_max=$(( (dart_nominal * (10000 + rust_bp) + 5000) / 10000 ))

  if [[ "${dart_min}" != "${expected_min}" ]]; then
    fail_msg "jitter minimum diverged: Rust's ${rust_bp}bp spread around a ${dart_nominal}s \
nominal computes to ${expected_min}s, but Dart declares kLocationPublishMinInterval = \
${dart_min}s. A narrowed Rust spread with an unchanged Dart floor makes Dart's floor \
SMALLER than what the engine can actually sample down to."
    fail=1
  else
    echo "  [1/2] jitter minimum agrees (${dart_min}s)."
  fi

  if [[ "${dart_max}" != "${expected_max}" ]]; then
    fail_msg "jitter maximum diverged: Rust's ${rust_bp}bp spread around a ${dart_nominal}s \
nominal computes to ${expected_max}s, but Dart declares kLocationPublishMaxInterval = \
${dart_max}s. A widened Rust spread with an unchanged Dart ceiling makes the disclosed \
no-gap invariant's δ_max no longer real."
    fail=1
  else
    echo "  [2/2] jitter maximum agrees (${dart_max}s)."
  fi

  (( fail == 0 ))
}

# ---------------------------------------------------------------------------
# Self-test — hermetic fixtures, no repo state, no toolchain.
#
# (2) and (3) are the defect this guard exists for — narrowing/widening the
# Rust fraction alone, exactly as `PUBLISH_INTERVAL_JITTER_FRACTION_BP` was
# mutated by hand while landing this guard. (4)/(5)/(6) are the symmetric
# one-sided Dart edits. (7) proves the rounding matches Dart's `.round()`
# rather than truncation, the one place this arithmetic is not a plain
# integer division. (8)-(10) are the fail-closed "declaration moved" paths.
# ---------------------------------------------------------------------------
self_test() {
  local tmp fails=0 checked=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  _case() { # _case <label> <expect-rc> <rust-content> <dart-content>
    local label="$1" want="$2" rust_content="$3" dart_content="$4" got=0
    checked=$(( checked + 1 ))
    printf '%s' "${rust_content}" > "${tmp}/ttl.rs"
    printf '%s' "${dart_content}" > "${tmp}/location.dart"
    ( check_parity "${tmp}/ttl.rs" "${tmp}/location.dart" ) >/dev/null 2>&1 || got=$?
    if [[ "${got}" -eq "${want}" ]]; then
      printf '  \033[1;32mPASS\033[0m %s (rc=%d)\n' "${label}" "${got}"
    else
      printf '  \033[1;31mFAIL\033[0m %s (want rc=%d, got rc=%d)\n' "${label}" "${want}" "${got}" >&2
      fails=1
    fi
  }

  local rust_4000='pub const PUBLISH_INTERVAL_JITTER_FRACTION_BP: u16 = 4_000;'
  local dart_120_72_168='const Duration kLocationUpdateInterval = Duration(minutes: 2);
const Duration kLocationPublishMinInterval = Duration(seconds: 72);
const Duration kLocationPublishMaxInterval = Duration(seconds: 168);'

  log "self-test: parity checks"

  # (1) Happy path — the values actually committed to the tree.
  _case "matching 40% spread around a 120s nominal passes" 0 \
    "${rust_4000}" "${dart_120_72_168}"

  # (2) THE CRITICAL FIXTURE — the fraction is narrowed on the Rust side only,
  #     exactly the scenario this guard exists to catch.
  _case "Rust spread narrowed alone FAILS" 1 \
    'pub const PUBLISH_INTERVAL_JITTER_FRACTION_BP: u16 = 2_000;' \
    "${dart_120_72_168}"

  # (3) ...and symmetrically widened.
  _case "Rust spread widened alone FAILS" 1 \
    'pub const PUBLISH_INTERVAL_JITTER_FRACTION_BP: u16 = 6_000;' \
    "${dart_120_72_168}"

  # (4) The Dart nominal drifts alone (min/max literals left stale).
  _case "Dart nominal changed alone FAILS" 1 \
    "${rust_4000}" \
    'const Duration kLocationUpdateInterval = Duration(minutes: 3);
const Duration kLocationPublishMinInterval = Duration(seconds: 72);
const Duration kLocationPublishMaxInterval = Duration(seconds: 168);'

  # (5) The Dart minimum is hand-edited alone.
  _case "Dart minimum hand-edited alone FAILS" 1 \
    "${rust_4000}" \
    'const Duration kLocationUpdateInterval = Duration(minutes: 2);
const Duration kLocationPublishMinInterval = Duration(seconds: 50);
const Duration kLocationPublishMaxInterval = Duration(seconds: 168);'

  # (6) ...and symmetrically the maximum.
  _case "Dart maximum hand-edited alone FAILS" 1 \
    "${rust_4000}" \
    'const Duration kLocationUpdateInterval = Duration(minutes: 2);
const Duration kLocationPublishMinInterval = Duration(seconds: 72);
const Duration kLocationPublishMaxInterval = Duration(seconds: 200);'

  # (7) ROUNDING. A 121s nominal at 40% spread computes to 72.6s / 169.4s —
  #     the correctly ROUNDED 73s/169s must pass, and the truncated 72s/169s
  #     (an off-by-one a naive integer-division port would produce) must fail.
  #     Seconds form exercises the Dart nominal's seconds branch too.
  _case "rounded (not truncated) endpoints pass" 0 \
    "${rust_4000}" \
    'const Duration kLocationUpdateInterval = Duration(seconds: 121);
const Duration kLocationPublishMinInterval = Duration(seconds: 73);
const Duration kLocationPublishMaxInterval = Duration(seconds: 169);'
  _case "truncated endpoints FAIL" 1 \
    "${rust_4000}" \
    'const Duration kLocationUpdateInterval = Duration(seconds: 121);
const Duration kLocationPublishMinInterval = Duration(seconds: 72);
const Duration kLocationPublishMaxInterval = Duration(seconds: 169);'

  # (8)-(11) Fail-closed: a moved/renamed/deleted declaration on either side
  #          must FAIL, never silently pass for want of something to compare.
  _case "missing Rust declaration FAILS" 1 \
    '// PUBLISH_INTERVAL_JITTER_FRACTION_BP was renamed' \
    "${dart_120_72_168}"
  _case "missing Dart nominal FAILS" 1 \
    "${rust_4000}" \
    'const Duration kLocationPublishMinInterval = Duration(seconds: 72);
const Duration kLocationPublishMaxInterval = Duration(seconds: 168);'
  _case "missing Dart minimum FAILS" 1 \
    "${rust_4000}" \
    'const Duration kLocationUpdateInterval = Duration(minutes: 2);
const Duration kLocationPublishMaxInterval = Duration(seconds: 168);'
  _case "missing Dart maximum FAILS" 1 \
    "${rust_4000}" \
    'const Duration kLocationUpdateInterval = Duration(minutes: 2);
const Duration kLocationPublishMinInterval = Duration(seconds: 72);'

  if (( fails )); then
    fail_msg "self-test failed — this guard cannot be trusted until it is fixed"
    exit 2
  fi
  log "OK: self-test passed (${checked} fixtures)."
}

# ---------------------------------------------------------------------------
main() {
  if [[ "${1:-}" == "--self-test" ]]; then
    self_test
    exit 0
  fi
  (( $# == 0 )) || misconfig "usage: ${SCRIPT_NAME}.sh [--self-test]"

  local rust_ttl="${REPO_ROOT}/haven-core/src/location/ttl.rs"
  local dart_constants="${REPO_ROOT}/haven/lib/src/constants/location.dart"

  [[ -f "${rust_ttl}" ]] || misconfig "${rust_ttl} not found"
  [[ -f "${dart_constants}" ]] || misconfig "${dart_constants} not found"

  if check_parity "${rust_ttl}" "${dart_constants}"; then
    log "OK: the publish-cadence jitter fraction agrees between Rust and Dart."
    exit 0
  fi
  fail_msg "the publish-cadence jitter fraction diverged between Rust and Dart (see above)."
  exit 1
}

main "$@"
