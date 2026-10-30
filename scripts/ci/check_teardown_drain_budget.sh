#!/usr/bin/env bash
# CI guard: the Dart foreground-service teardown budget stays equal to the Rust
# relay constants it is derived from.
#
# `kBackgroundTeardownDrainBudget` (haven/lib/src/services/mls_session_handover.dart)
# is what the Android foreground service's `onDestroy` spends waiting for an
# in-flight location publish before it tears down anyway, and `handoverTimeout`
# is derived from it in turn. It is not a taste number: it is exactly ONE relay
# publish attempt, `CONNECTION_TIMEOUT + DEFAULT_TIMEOUT` in
# `haven-core/src/relay/manager.rs`.
#
# The two live in different languages with no shared header, so nothing but this
# stops them drifting — and drift is silent in both directions:
#
#   * Rust attempt gets SLOWER than the Dart budget → every stop abandons a
#     publish that was still inside its first attempt, turning a bounded
#     teardown into a routinely lost location sample.
#   * Rust attempt gets FASTER → the service sits in `onDestroy` past the point
#     anything can still happen, and the UI isolate's handover budget (derived
#     from this one) makes the user wait it out on a blank map.
#
# It also holds that a location drive is the one thing left inside that budget:
# the service waits on every other driver entry unbounded after it, never on a
# location's seal and send (`check_split`, decision 252).
#
# Pure-grep gate (no toolchain) so it runs in seconds alongside the other repo
# guards, as a step in .github/workflows/repo-guards.yml.
#
# Usage:
#   check_teardown_drain_budget.sh              # check the tree
#   check_teardown_drain_budget.sh --self-test  # hermetic fixtures
#
# Exit codes:
#   0  the derivation holds
#   1  the constants have drifted apart
#   2  the guard itself is broken (a constant it reads no longer exists)

set -euo pipefail

cd "$(dirname "$0")/../.."

readonly RUST_SRC='haven-core/src/relay/manager.rs'
readonly DART_SRC='haven/lib/src/services/mls_session_handover.dart'
readonly FGS_SRC='haven/lib/src/services/background_location_task.dart'
readonly RELAY_SRC='haven/lib/src/services/nostr_relay_service.dart'

# Reads `const NAME: Duration = Duration::from_secs(N);` → N.
rust_secs() {
  local name="$1" src="$2"
  sed -n "s/^\(pub \)\{0,1\}const ${name}: Duration = Duration::from_secs(\([0-9]\+\));.*/\2/p" \
    "${src}" | head -n 1
}

# Reads `const int NAME = N;` → N.
dart_secs() {
  local name="$1" src="$2"
  sed -n "s/^const int ${name} = \([0-9]\+\);.*/\1/p" "${src}" | head -n 1
}

check_pair() {
  local rust_src="$1" dart_src="$2" connect ack budget

  connect=$(rust_secs 'CONNECTION_TIMEOUT' "${rust_src}")
  ack=$(rust_secs 'DEFAULT_TIMEOUT' "${rust_src}")
  budget=$(dart_secs '_teardownDrainBudgetSecs' "${dart_src}")

  if [[ -z "${connect}" || -z "${ack}" ]]; then
    echo "ERROR: could not read CONNECTION_TIMEOUT / DEFAULT_TIMEOUT from"
    echo "${rust_src}. They were renamed or reshaped — update this guard"
    echo "rather than deleting it."
    return 2
  fi
  if [[ -z "${budget}" ]]; then
    echo "ERROR: could not read _teardownDrainBudgetSecs from ${dart_src}."
    echo "kBackgroundTeardownDrainBudget must stay expressed as an integer"
    echo "second count so this guard can compare it; update the guard if the"
    echo "shape genuinely had to change."
    return 2
  fi

  if (( connect + ack != budget )); then
    echo "ERROR: the foreground-service teardown budget has drifted."
    echo "  ${rust_src}: CONNECTION_TIMEOUT=${connect}s + DEFAULT_TIMEOUT=${ack}s"
    echo "    = $((connect + ack))s for ONE relay publish attempt"
    echo "  ${dart_src}: _teardownDrainBudgetSecs=${budget}s"
    echo
    echo "kBackgroundTeardownDrainBudget is ONE publish attempt by definition —"
    echo "it is how long onDestroy waits for the location publish it is allowed"
    echo "to abandon (Rule 13 is not at stake for an application message), and"
    echo "handoverTimeout is derived from it. Re-derive the Dart constant from"
    echo "the Rust ones and re-pin the doc comment; do not widen this check."
    return 1
  fi
  return 0
}

# The budget bounds a location drive, and only that one is left inside it
# (decision 252): the service's unbounded wait reads the registry without a
# location's seal and send, and the relay service registers exactly those two
# as location drives. Waiting a location drive out unbounded would outlast the
# handover budget this file pins.
check_split() {
  local fgs_src="$1" relay_src="$2" located
  if ! grep -qF '_relayService?.inFlightNonLocationDrives' "${fgs_src}" ||
    grep -qF '.inFlightDrives' "${fgs_src}"; then
    echo "ERROR: ${fgs_src} must wait, past its bounded drain, on"
    echo "_relayService?.inFlightNonLocationDrives and never on inFlightDrives:"
    echo "a location drive waited out unbounded outlasts handoverTimeout."
    return 1
  fi
  located=$(grep -c 'location: true' "${relay_src}" || true)
  if [[ "${located}" != 2 ]]; then
    echo "ERROR: ${relay_src} must carry 'location: true' exactly twice — on"
    echo "sealLocation and publishLocation; found ${located}. This guard counts"
    echo "the marks; which entries carry them is pinned by"
    echo "test/services/nostr_relay_service_drive_registry_test.dart."
    return 1
  fi
  return 0
}

self_test() {
  local tmp failures=0
  tmp=$(mktemp -d)
  trap 'rm -rf "${tmp}"' RETURN

  write_rust() {
    printf 'const CONNECTION_TIMEOUT: Duration = Duration::from_secs(%s);\nconst DEFAULT_TIMEOUT: Duration = Duration::from_secs(%s);\n' \
      "$1" "$2" >"${tmp}/manager.rs"
  }
  write_dart() {
    printf 'const int _teardownDrainBudgetSecs = %s;\n' "$1" >"${tmp}/handover.dart"
  }

  case_is() {
    local want="$1" name="$2" got
    set +e
    check_pair "${tmp}/manager.rs" "${tmp}/handover.dart" >/dev/null 2>&1
    got=$?
    set -e
    if (( got != want )); then
      echo "self-test FAILED [${name}]: expected exit ${want}, got ${got}" >&2
      failures=$((failures + 1))
    fi
  }

  write_rust 5 10; write_dart 15
  case_is 0 'the sum matches'

  write_rust 5 10; write_dart 12
  case_is 1 'a Dart budget below the Rust attempt is drift'

  write_rust 5 10; write_dart 20
  case_is 1 'a Dart budget above the Rust attempt is drift'

  write_rust 7 10; write_dart 15
  case_is 1 'a Rust connect timeout change is drift'

  : >"${tmp}/manager.rs"; write_dart 15
  case_is 2 'a missing Rust constant is guard drift, not a pass'

  write_rust 5 10; : >"${tmp}/handover.dart"
  case_is 2 'a missing Dart constant is guard drift, not a pass'

  split_is() {
    local want="$1" name="$2" got
    set +e
    check_split "${tmp}/fgs.dart" "${tmp}/relay.dart" >/dev/null 2>&1
    got=$?
    set -e
    if (( got != want )); then
      echo "self-test FAILED [${name}]: expected exit ${want}, got ${got}" >&2
      failures=$((failures + 1))
    fi
  }
  local fgs='final c = _relayService?.inFlightNonLocationDrives;'
  local relay=$'_driving(location: true, () {});\n_driving(location: true, () {});'
  printf '%s\n' "${fgs}" >"${tmp}/fgs.dart"; printf '%s\n' "${relay}" >"${tmp}/relay.dart"
  split_is 0 'the split holds'
  printf '%s\n' 'final c = _relayService?.inFlightDrives;' >"${tmp}/fgs.dart"
  split_is 1 'the service waiting on every drive is refused'
  printf '%s\n%s\n' "${fgs}" 'await x.inFlightDrives;' >"${tmp}/fgs.dart"
  split_is 1 'a second read of every drive is refused'
  printf '%s\n' "${fgs}" >"${tmp}/fgs.dart"
  printf '%s\n' '_driving(location: true, () {});' >"${tmp}/relay.dart"
  split_is 1 'a location drive registered as another is refused'

  if (( failures )); then
    echo "the teardown-budget guard cannot be trusted until the ${failures} case(s) above are fixed." >&2
    return 2
  fi
  echo "teardown drain budget guard: self-test OK (10 fixtures)."
  return 0
}

if [[ "${1:-}" == "--self-test" ]]; then
  self_test
  exit $?
fi

rc=0
check_pair "${RUST_SRC}" "${DART_SRC}" || rc=$?
if (( rc == 0 )); then check_split "${FGS_SRC}" "${RELAY_SRC}" || rc=$?; fi
if (( rc == 0 )); then
  echo "teardown drain budget guard: OK ($(dart_secs '_teardownDrainBudgetSecs' \
    "${DART_SRC}")s == CONNECTION_TIMEOUT + DEFAULT_TIMEOUT)."
fi
exit "${rc}"
