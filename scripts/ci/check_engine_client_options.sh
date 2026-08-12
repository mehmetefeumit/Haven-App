#!/usr/bin/env bash
# CI guard: the live-sync engine `Client` must not enable `verify_subscriptions`.
#
# nostr-sdk's `verify_subscriptions` re-checks every inbound EVENT against the
# filter registered for its subscription id — but `Relay::subscribe_long_lived`
# (nostr-relay-pool 0.44.3) SENDS the REQ and only THEN registers that filter.
# An event the relay replays inside that window finds no registered
# subscription and is discarded with `SubscriptionNotFound`, silently: no
# error reaches any caller, no notification is emitted, and nothing in the
# engine can tell the difference between "the relay had nothing" and "the pool
# threw away what it sent". The matching EOSE is NOT subject to the check, so
# it still lands and still anchors the sync cursor to the REQ's open time —
# past the events that were just dropped. The generation never comes back for
# them; only the next REQ's lookback does. On the inbox plane that is a
# gift-wrapped invitation (kind 1059) that does not arrive until the next
# session.
#
# The window is a task-scheduling gap, so it widens exactly when the device is
# busy and the relay answers quickly. It made
# `inbox_cursor_poisoning_e2e::a_future_dated_gift_wrap_never_pushes_the_inbox_cursor_past_the_local_clock`
# flaky in CI (runs 31216078806, 31555665220) and is reproducible locally by
# pinning that target to two cores.
#
# Nothing is given up by leaving the option off: the same identity dimensions
# of each plane's filter are re-checked in
# `live_sync::supervisor::plane_wants_event`, where the router context is
# registered BEFORE the REQ goes out and no such window exists. Re-enabling
# the option would restore the silent drop while adding nothing — hence this
# guard, which no test can replace: the drop is probabilistic, so a build with
# it re-enabled still passes the suite most of the time.
#
# Pure-grep gate (no Rust toolchain) so it runs fast and independently.
#
# Checks:
#   1. `verify_subscriptions(true)` appears nowhere under haven-core/src or
#      haven/rust_builder/src.
#   2. The engine client builder still pins the option OFF explicitly, so
#      deleting the line (and inheriting a future upstream default of `true`)
#      is caught too.
#
# Exit codes:
#   0  all checks pass
#   1  the option is enabled, or the explicit pin is gone
#   2  expected paths missing (misconfiguration)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CORE_SRC_DIR="${REPO_ROOT}/haven-core/src"
FFI_SRC_DIR="${REPO_ROOT}/haven/rust_builder/src"
SESSION_FILE="${CORE_SRC_DIR}/relay/live_sync/session.rs"

log() {
  printf '\033[1;34m[check_engine_client_options]\033[0m %s\n' "$*"
}

fail() {
  printf '\033[1;31m[check_engine_client_options] FAIL:\033[0m %s\n' "$*" >&2
  exit 1
}

[[ -d "${CORE_SRC_DIR}" ]] || { echo "ERROR: ${CORE_SRC_DIR} not found" >&2; exit 2; }
[[ -d "${FFI_SRC_DIR}" ]] || { echo "ERROR: ${FFI_SRC_DIR} not found" >&2; exit 2; }
[[ -f "${SESSION_FILE}" ]] || { echo "ERROR: ${SESSION_FILE} not found" >&2; exit 2; }

# ---------------------------------------------------------------------------
# Check 1: nobody turns the option on. Whitespace-tolerant so
# `verify_subscriptions( true )` cannot slip through.
# ---------------------------------------------------------------------------
log "Scanning Rust sources for an enabled verify_subscriptions ..."
enabled="$(grep -rnE 'verify_subscriptions[[:space:]]*\([[:space:]]*true[[:space:]]*\)' \
  "${CORE_SRC_DIR}" "${FFI_SRC_DIR}" 2>/dev/null || true)"
if [[ -n "${enabled}" ]]; then
  printf '%s\n' "${enabled}" >&2
  fail "verify_subscriptions(true) drops the stored events a REQ replays before nostr-relay-pool registers that REQ's filter — silently, while the EOSE still advances the cursor past them. The filter is re-checked in live_sync::supervisor::plane_wants_event instead."
fi

# ---------------------------------------------------------------------------
# Check 2: the engine builder still states the choice. Without this, deleting
# the line would pass check 1 while handing the decision to whatever the SDK
# defaults to next.
# ---------------------------------------------------------------------------
log "Checking the engine client still pins the option off explicitly ..."
if ! grep -qE 'verify_subscriptions[[:space:]]*\([[:space:]]*false[[:space:]]*\)' "${SESSION_FILE}"; then
  fail "${SESSION_FILE#"${REPO_ROOT}/"} no longer pins verify_subscriptions(false) on the engine client — the engine must not inherit the SDK default for an option that silently drops a REQ's first stored events"
fi

log "OK: the engine client keeps the racy pool-side filter check off; plane_wants_event enforces the filter."
