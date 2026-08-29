#!/usr/bin/env bash
# CI guard: the Dart live-sync restart budget stays derived from the Rust
# engine constants it mirrors.
#
# `kLiveSyncRestartBudget` (haven/lib/src/services/live_sync_resubscriber.dart)
# bounds one `ensureRunning()` — the ONLY periodic recovery the live-sync build
# has, since `MapShell` arms its next self-heal tick from that future's
# completion. It is not a taste number: it is what the Rust engine allows
# ITSELF to spend on a stop + start, namely
# `_kLifecycleOpsPerRestart x RELAY_LIFECYCLE_OP_TIMEOUT_SECS +
# SUBSCRIBE_CONNECT_WAIT_SECS` from
# `haven-core/src/relay/live_sync/config.rs`.
#
# The two live in different languages with no shared header, so nothing but
# this stops them drifting — and drift is silent in both directions:
#
#   * Rust gets SLOWER than the Dart budget -> every restart that was still
#     going to succeed is abandoned as "not running", and the heal re-enters a
#     restart loop it can never win.
#   * Rust gets FASTER -> the heal sits waiting on a future the engine has
#     already given up on, and the backstop's next tick is delayed by the
#     difference, with a dead receive plane the whole time.
#
# The op COUNT itself is a structural claim about `stop_inner`'s three bounded
# pool ops and `NostrSubscriptionService`'s one stop retry; no grep can check
# that, so it is documented at the constant. What this guard pins is the two
# per-op magnitudes, which are the numbers that actually move.
#
# Pure-grep gate (no toolchain) so it runs in seconds alongside the other repo
# guards, as a step in .github/workflows/repo-guards.yml.
#
# Usage:
#   check_live_sync_restart_budget.sh              # check the tree
#   check_live_sync_restart_budget.sh --self-test  # hermetic fixtures
#
# Exit codes:
#   0  the derivation holds
#   1  the constants have drifted apart
#   2  the guard itself is broken (a constant it reads no longer exists)

set -euo pipefail

cd "$(dirname "$0")/../.."

readonly RUST_SRC='haven-core/src/relay/live_sync/config.rs'
readonly DART_SRC='haven/lib/src/services/live_sync_resubscriber.dart'
readonly RUST_CURSOR_SRC='haven-core/src/relay/cursor.rs'
readonly DART_CONST_SRC='haven/lib/src/constants/location.dart'

# Reads `pub const NAME: u64 = N;` -> N.
rust_secs() {
  local name="$1" src="$2"
  sed -n "s/^pub const ${name}: u64 = \([0-9]\+\);.*/\1/p" "${src}" | head -n 1
}

# Reads `pub const NAME: i64 = N;` -> N.
rust_i64() {
  local name="$1" src="$2"
  sed -n "s/^pub const ${name}: i64 = \([0-9]\+\);.*/\1/p" "${src}" | head -n 1
}

# Reads `const Duration NAME = Duration(seconds: N);` -> N.
dart_duration_secs() {
  local name="$1" src="$2"
  sed -n "s/^const Duration ${name} = Duration(seconds: \([0-9]\+\));.*/\1/p" \
    "${src}" | head -n 1
}

# Reads `const int NAME = N;` -> N.
dart_secs() {
  local name="$1" src="$2"
  sed -n "s/^const int ${name} = \([0-9]\+\);.*/\1/p" "${src}" | head -n 1
}

check_pair() {
  local rust_src="$1" dart_src="$2"
  local rust_op rust_wait dart_op dart_wait

  rust_op=$(rust_secs 'RELAY_LIFECYCLE_OP_TIMEOUT_SECS' "${rust_src}")
  rust_wait=$(rust_secs 'SUBSCRIBE_CONNECT_WAIT_SECS' "${rust_src}")
  dart_op=$(dart_secs '_kRelayLifecycleOpTimeoutSecs' "${dart_src}")
  dart_wait=$(dart_secs '_kSubscribeConnectWaitSecs' "${dart_src}")

  if [[ -z "${rust_op}" || -z "${rust_wait}" ]]; then
    echo "ERROR: could not read RELAY_LIFECYCLE_OP_TIMEOUT_SECS /"
    echo "SUBSCRIBE_CONNECT_WAIT_SECS from ${rust_src}. They were renamed or"
    echo "reshaped — update this guard rather than deleting it."
    return 2
  fi
  if [[ -z "${dart_op}" || -z "${dart_wait}" ]]; then
    echo "ERROR: could not read _kRelayLifecycleOpTimeoutSecs /"
    echo "_kSubscribeConnectWaitSecs from ${dart_src}. kLiveSyncRestartBudget"
    echo "must stay expressed as integer second counts so this guard can"
    echo "compare them; update the guard if the shape genuinely had to change."
    return 2
  fi

  # The mirrors only matter if the budget is actually COMPOSED from them. A
  # hardcoded `Duration(seconds: 65)` passes every numeric check above while
  # silently decoupling from the engine, so require the initializer to name all
  # three terms.
  local initializer
  initializer=$(sed -n '/^const Duration kLiveSyncRestartBudget = Duration(/,/^);/p' \
    "${dart_src}")
  if [[ -z "${initializer}" ]]; then
    echo "ERROR: could not find kLiveSyncRestartBudget's initializer in"
    echo "${dart_src}. It must stay a top-level \`const Duration\` so this"
    echo "guard can read how it is composed."
    return 2
  fi

  local failed=0
  local term
  for term in _kLifecycleOpsPerRestart _kRelayLifecycleOpTimeoutSecs \
    _kSubscribeConnectWaitSecs; do
    if ! grep -qF -- "${term}" <<<"${initializer}"; then
      echo "ERROR: kLiveSyncRestartBudget no longer derives from ${term}."
      echo "A literal budget drifts from the engine silently — that is the"
      echo "whole failure this guard exists to prevent."
      failed=1
    fi
  done

  if (( rust_op != dart_op )); then
    echo "ERROR: the relay lifecycle-op bound has drifted."
    echo "  ${rust_src}: RELAY_LIFECYCLE_OP_TIMEOUT_SECS=${rust_op}s"
    echo "  ${dart_src}: _kRelayLifecycleOpTimeoutSecs=${dart_op}s"
    failed=1
  fi
  if (( rust_wait != dart_wait )); then
    echo "ERROR: the subscribe connect wait has drifted."
    echo "  ${rust_src}: SUBSCRIBE_CONNECT_WAIT_SECS=${rust_wait}s"
    echo "  ${dart_src}: _kSubscribeConnectWaitSecs=${dart_wait}s"
    failed=1
  fi
  if (( failed )); then
    echo
    echo "kLiveSyncRestartBudget is the engine's own stop+start bound by"
    echo "definition — it is how long MapShell's self-heal waits before"
    echo "declaring a restart failed, and the heal backstop's next tick is"
    echo "armed from that answer. Re-derive the Dart mirrors from the Rust"
    echo "constants; do not widen this check."
    return 1
  fi
  return 0
}

# The resume re-anchor's throttle. `MapShell.shouldReanchorOnResume` refuses a
# second re-anchor inside `kLocationPublishOverlapGuard`, and the ONLY reason
# that is a derived floor rather than a taste number is that it equals
# `GROUP_RESUBSCRIBE_BUFFER_SECS` — the clock-skew window a resubscribe
# re-queries with — so a re-anchor inside it asks the relays for a window the
# previous one already covered and can deliver nothing new.
#
# Both drift directions are silent:
#
#   * Rust buffer RAISED above the Dart guard -> re-anchors inside the new
#     buffer are waste: a pool reconnect and a 7-day gift-wrap replay (the
#     inbox `since` ignores the resubscribe phase) that can return nothing new.
#   * Dart guard RAISED above the Rust buffer -> resumes inside the gap are
#     refused a repair that WOULD have fetched something, silently losing the
#     one recovery a relay-`CLOSED` REQ has.
check_reanchor_guard() {
  local rust_src="$1" dart_src="$2" buffer guard

  buffer=$(rust_i64 'GROUP_RESUBSCRIBE_BUFFER_SECS' "${rust_src}")
  guard=$(dart_duration_secs 'kLocationPublishOverlapGuard' "${dart_src}")

  if [[ -z "${buffer}" ]]; then
    echo "ERROR: could not read GROUP_RESUBSCRIBE_BUFFER_SECS from ${rust_src}."
    echo "It was renamed or reshaped — update this guard rather than deleting"
    echo "it."
    return 2
  fi
  if [[ -z "${guard}" ]]; then
    echo "ERROR: could not read kLocationPublishOverlapGuard from ${dart_src}."
    echo "It must stay a top-level \`const Duration ... = Duration(seconds: N)\`"
    echo "so this guard can compare it."
    return 2
  fi

  if (( buffer != guard )); then
    echo "ERROR: the resume re-anchor throttle has drifted from the"
    echo "resubscribe buffer it is derived from."
    echo "  ${rust_src}: GROUP_RESUBSCRIBE_BUFFER_SECS=${buffer}s"
    echo "  ${dart_src}: kLocationPublishOverlapGuard=${guard}s"
    echo
    echo "MapShell.shouldReanchorOnResume refuses a re-anchor inside the Dart"
    echo "value, and that is only defensible while it equals the window a"
    echo "resubscribe re-queries. Raise them together, or give the throttle its"
    echo "own constant with its own derivation."
    return 1
  fi
  return 0
}

self_test() {
  local tmp failures=0
  tmp=$(mktemp -d)
  trap 'rm -rf "${tmp}"' RETURN

  write_rust() {
    printf 'pub const RELAY_LIFECYCLE_OP_TIMEOUT_SECS: u64 = %s;\npub const SUBSCRIBE_CONNECT_WAIT_SECS: u64 = %s;\n' \
      "$1" "$2" >"${tmp}/config.rs"
  }
  # Writes the two mirrors plus a correctly-derived budget initializer.
  write_dart() {
    printf 'const int _kRelayLifecycleOpTimeoutSecs = %s;\nconst int _kSubscribeConnectWaitSecs = %s;\nconst int _kLifecycleOpsPerRestart = 6;\nconst Duration kLiveSyncRestartBudget = Duration(\n  seconds:\n      _kLifecycleOpsPerRestart * _kRelayLifecycleOpTimeoutSecs +\n      _kSubscribeConnectWaitSecs,\n);\n' \
      "$1" "$2" >"${tmp}/resub.dart"
  }

  # Same mirrors, but the budget hardcoded to the value they happen to produce.
  write_dart_hardcoded() {
    printf 'const int _kRelayLifecycleOpTimeoutSecs = %s;\nconst int _kSubscribeConnectWaitSecs = %s;\nconst Duration kLiveSyncRestartBudget = Duration(\n  seconds: 65,\n);\n' \
      "$1" "$2" >"${tmp}/resub.dart"
  }

  case_is() {
    local want="$1" name="$2" got
    set +e
    check_pair "${tmp}/config.rs" "${tmp}/resub.dart" >/dev/null 2>&1
    got=$?
    set -e
    if (( got != want )); then
      echo "self-test FAILED [${name}]: expected exit ${want}, got ${got}" >&2
      failures=$((failures + 1))
    fi
  }

  write_rust 10 5; write_dart 10 5
  case_is 0 'the mirrors match'

  write_rust 20 5; write_dart 10 5
  case_is 1 'a Rust lifecycle-op change is drift'

  write_rust 10 8; write_dart 10 5
  case_is 1 'a Rust connect-wait change is drift'

  write_rust 10 5; write_dart 12 5
  case_is 1 'a Dart lifecycle-op change is drift'

  write_rust 10 5; write_dart 10 3
  case_is 1 'a Dart connect-wait change is drift'

  write_rust 10 5; write_dart_hardcoded 10 5
  case_is 1 'a hardcoded budget is drift even when its NUMBER is right'

  : >"${tmp}/config.rs"; write_dart 10 5
  case_is 2 'a missing Rust constant is guard drift, not a pass'

  write_rust 10 5; : >"${tmp}/resub.dart"
  case_is 2 'a missing Dart constant is guard drift, not a pass'

  # --- the resume re-anchor throttle pair ---
  write_cursor() {
    printf 'pub const GROUP_RESUBSCRIBE_BUFFER_SECS: i64 = %s;\n' "$1" \
      >"${tmp}/cursor.rs"
  }
  write_location() {
    printf 'const Duration kLocationPublishOverlapGuard = Duration(seconds: %s);\n' \
      "$1" >"${tmp}/location.dart"
  }
  guard_case_is() {
    local want="$1" name="$2" got
    set +e
    check_reanchor_guard "${tmp}/cursor.rs" "${tmp}/location.dart" >/dev/null 2>&1
    got=$?
    set -e
    if (( got != want )); then
      echo "self-test FAILED [${name}]: expected exit ${want}, got ${got}" >&2
      failures=$((failures + 1))
    fi
  }

  write_cursor 60; write_location 60
  guard_case_is 0 'the throttle matches the resubscribe buffer'

  write_cursor 90; write_location 60
  guard_case_is 1 'a RAISED Rust buffer is drift (re-anchors become waste)'

  write_cursor 60; write_location 90
  guard_case_is 1 'a RAISED Dart guard is drift (repairs are silently lost)'

  : >"${tmp}/cursor.rs"; write_location 60
  guard_case_is 2 'a missing Rust buffer is guard drift, not a pass'

  write_cursor 60; : >"${tmp}/location.dart"
  guard_case_is 2 'a missing Dart guard is guard drift, not a pass'

  if (( failures )); then
    echo "the live-sync restart-budget guard cannot be trusted until the ${failures} case(s) above are fixed." >&2
    return 2
  fi
  echo "live-sync restart budget guard: self-test OK (13 fixtures)."
  return 0
}

if [[ "${1:-}" == "--self-test" ]]; then
  self_test
  exit $?
fi

rc=0
check_pair "${RUST_SRC}" "${DART_SRC}" || rc=$?
guard_rc=0
check_reanchor_guard "${RUST_CURSOR_SRC}" "${DART_CONST_SRC}" || guard_rc=$?
if (( guard_rc != 0 )); then
  rc=$(( rc > guard_rc ? rc : guard_rc ))
fi
if (( rc == 0 )); then
  echo "live-sync restart budget guard: OK (lifecycle op $(rust_secs \
    'RELAY_LIFECYCLE_OP_TIMEOUT_SECS' "${RUST_SRC}")s, connect wait $(rust_secs \
    'SUBSCRIBE_CONNECT_WAIT_SECS' "${RUST_SRC}")s mirrored in Dart; resume"
  echo "throttle $(dart_duration_secs 'kLocationPublishOverlapGuard' \
    "${DART_CONST_SRC}")s == GROUP_RESUBSCRIBE_BUFFER_SECS)."
fi
exit "${rc}"
