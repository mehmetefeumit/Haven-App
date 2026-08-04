#!/usr/bin/env bash
# CI guard: no sync-cursor advance may be derived from an inbound event's
# `created_at`, and NO FFI entry point may raise a sync cursor at all.
#
# A sync-cursor ADVANCE is a claim about what this device has already seen. An
# inbound `kind:445`'s outer `created_at` is chosen by whoever signed the
# envelope — a throwaway ephemeral key — and is authenticated by NOTHING on the
# receive path: the MLS engine authenticates the inner message, and no
# receive-side check binds the outer timestamp to it, for any ingest outcome. A
# circle's `#h` routing tag IS its public `nostr_group_id`, so any relay
# observer can mint (or re-wrap an observed ciphertext into) an event carrying
# any timestamp it likes. Deriving an advance from that field hands the
# persisted REQ floor to a remote party, in the one direction that destroys
# availability permanently: every legitimate event below the poisoned floor
# falls outside every future REQ, across restarts. A stranded location merely
# ages out; a stranded COMMIT breaks the epoch chain.
#
# Both Rust receive planes therefore anchor every advance on a LOCAL clock
# reading taken when the observation window opened — the catch-up fetch's open
# time, the live subscription's REQ time — and let event timestamps only hold an
# advance BACK (`haven_core::relay::cursor`, "the governing asymmetry").
#
# Dart had two unanchored writers of its own, both deleted.
#
# The GROUP one was a seconds-taking FFI wrapper that advanced the BARE
# `group_445` stream straight from an event's `created_at`, with no window and
# no clamp. It was also write-only — every REQ floor is derived from the
# PER-CIRCLE key `group_445:{hex(nostr_group_id)}` or from `inbox_1059`, and
# `sync_cursors` is only ever read by exact `stream =` match — so it was dead
# code carrying a live defect.
#
# The INBOX one was live, and cheaper to exploit. It advanced `inbox_1059`
# straight from a `kind:1059` gift wrap's outer `created_at`, saturating but
# otherwise unclamped, and that cursor IS read: it is the floor of the live-sync
# engine's inbox REQ. A gift wrap is routed by a `#p` tag carrying the
# recipient's PUBLIC key (published in their kind:0 profile, their relay lists
# and every KeyPackage), is authored by a throwaway ephemeral key by
# construction, and is peeled with NIP-59 alone — no MLS state is consulted and
# nothing binds the wrapper timestamp to its payload. So minting one that a
# victim's client peels cleanly, at any `created_at`, costs one NIP-44
# encryption to a published npub.
#
# The FUTURE direction was the whole exploit: the derived floor is capped at
# `now`, so a cursor above the wall clock pins every later inbox floor at `now`
# — and NIP-59 mandates backdating (up to 48h), so a floor at `now` filters out
# even a wrap published this second. Invitation delivery stopped entirely,
# permanently, and across restarts.
#
# Both were deleted rather than anchored: a primitive that does not exist cannot
# be wired up later by someone who does not know it is unsafe. This guard keeps
# them deleted, and keeps the whole class deleted via check 5.
#
# The bans are FLAT (fixed-string, comments included), following
# `check_no_exporter_label_override.sh`: prose that needs to discuss the removed
# path describes it instead of naming it, so the guard needs no comment-parsing
# machinery that a rewording could sidestep.
#
# Pure-grep gate (no Rust/Flutter toolchain) so it runs fast and independently.
#
# Checks:
#   1. The Rust FFI symbol `cursor_advance_group_to_event` appears nowhere under
#      haven/rust_builder/src (generated bindings included — a re-added #[frb]
#      method would show up there too).
#   2. The Dart symbols `advanceGroupCursorToEventSecs` / `cursorAdvanceGroupToEvent`
#      appear nowhere under haven/lib, haven/test or haven/integration_test.
#   3. The Rust FFI symbol `cursor_advance_inbox_to_wrap` appears nowhere under
#      haven/rust_builder/src.
#   4. The Dart symbols `advanceInboxCursorToWrapSecs` / `cursorAdvanceInboxToWrap`
#      appear nowhere under haven/lib, haven/test or haven/integration_test.
#   5. THE BEHAVIOURAL HALF, which renaming cannot evade: no FFI entry point may
#      call either haven-core cursor-RAISING primitive (`advance_sync_cursor`,
#      `seed_sync_cursor_if_unset`) or name either stream key
#      (`STREAM_GROUP_445`, `STREAM_INBOX_1059`) at all.
#
#      Cursor advances are earned by a completed observation window, and only
#      haven-core's receive planes observe one — the FFI boundary sees single
#      events and caller-supplied numbers, neither of which is evidence of
#      anything. Reading a cursor and RESETTING one (which can only lower it, to
#      unseeded) stay allowed: neither can raise a floor.
#
# Exit codes:
#   0  all checks pass
#   1  a banned symbol is present
#   2  expected paths missing (misconfiguration)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FFI_SRC_DIR="${REPO_ROOT}/haven/rust_builder/src"
DART_LIB_DIR="${REPO_ROOT}/haven/lib"
DART_TEST_DIR="${REPO_ROOT}/haven/test"
DART_E2E_DIR="${REPO_ROOT}/haven/integration_test"

log() {
  printf '\033[1;34m[check_no_event_timestamp_cursor_advance]\033[0m %s\n' "$*"
}

fail() {
  printf '\033[1;31m[check_no_event_timestamp_cursor_advance] FAIL:\033[0m %s\n' "$*" >&2
  exit 1
}

for d in "${FFI_SRC_DIR}" "${DART_LIB_DIR}" "${DART_TEST_DIR}" "${DART_E2E_DIR}"; do
  [[ -d "${d}" ]] || { echo "ERROR: ${d} not found" >&2; exit 2; }
done

# ---------------------------------------------------------------------------
# Check 1: the removed FFI method stays removed.
# ---------------------------------------------------------------------------
log "Scanning haven/rust_builder/src for the removed group-cursor FFI advance ..."
hits="$(grep -rnF 'cursor_advance_group_to_event' "${FFI_SRC_DIR}" 2>/dev/null || true)"
if [[ -n "${hits}" ]]; then
  printf '%s\n' "${hits}" >&2
  fail "the group-cursor-to-event FFI advance is back. It writes a sync cursor from an inbound event's unauthenticated created_at; group cursors are advanced in haven-core only, anchored on the local instant an observation window opened."
fi

# ---------------------------------------------------------------------------
# Check 2: the removed Dart service method + its FFI binding stay removed.
# ---------------------------------------------------------------------------
log "Scanning haven/lib, haven/test and haven/integration_test for the removed Dart group-cursor advance ..."
hits="$(grep -rnE 'advanceGroupCursorToEventSecs|cursorAdvanceGroupToEvent' \
  "${DART_LIB_DIR}" "${DART_TEST_DIR}" "${DART_E2E_DIR}" 2>/dev/null || true)"
if [[ -n "${hits}" ]]; then
  printf '%s\n' "${hits}" >&2
  fail "a Dart group-cursor advance is back. The poll path must derive NO cursor from an event timestamp; the per-circle group cursor is owned by haven-core's catch-up sweep and live-sync EOSE anchor."
fi

# ---------------------------------------------------------------------------
# Check 3: the removed inbox FFI method stays removed.
# ---------------------------------------------------------------------------
log "Scanning haven/rust_builder/src for the removed inbox-cursor FFI advance ..."
hits="$(grep -rnF 'cursor_advance_inbox_to_wrap' "${FFI_SRC_DIR}" 2>/dev/null || true)"
if [[ -n "${hits}" ]]; then
  printf '%s\n' "${hits}" >&2
  fail "the inbox-cursor-to-gift-wrap FFI advance is back. It writes the inbox REQ floor from a kind:1059 wrapper's unauthenticated created_at, which anyone who knows this user's published npub can choose; future-dated it pins every later floor at now, where NIP-59's mandatory backdating hides every genuine invitation. The inbox cursor is advanced in haven-core only, on the inbox REQ's EOSE, to that REQ's local open time."
fi

# ---------------------------------------------------------------------------
# Check 4: the removed Dart inbox service method + its FFI binding stay removed.
# ---------------------------------------------------------------------------
log "Scanning haven/lib, haven/test and haven/integration_test for the removed Dart inbox-cursor advance ..."
hits="$(grep -rnE 'advanceInboxCursorToWrapSecs|cursorAdvanceInboxToWrap' \
  "${DART_LIB_DIR}" "${DART_TEST_DIR}" "${DART_E2E_DIR}" 2>/dev/null || true)"
if [[ -n "${hits}" ]]; then
  printf '%s\n' "${hits}" >&2
  fail "a Dart inbox-cursor advance is back. Dart must derive NO cursor from a gift-wrap timestamp; the inbox cursor is owned by haven-core's live-sync EOSE anchor."
fi

# ---------------------------------------------------------------------------
# Check 5: no FFI entry point may RAISE a sync cursor, or name a stream key.
#
# The behavioural half of the guard: renaming a method does not evade it, and
# it bans the whole class rather than the two instances that existed.
# ---------------------------------------------------------------------------
log "Scanning haven/rust_builder/src for any cursor-raising primitive or stream key ..."
hits="$(grep -rnE 'advance_sync_cursor|seed_sync_cursor_if_unset|STREAM_GROUP_445|STREAM_INBOX_1059' \
  "${FFI_SRC_DIR}" 2>/dev/null || true)"
if [[ -n "${hits}" ]]; then
  printf '%s\n' "${hits}" >&2
  fail "the FFI crate raises a sync cursor (or names a cursor stream key). A cursor advance is earned by a COMPLETED OBSERVATION WINDOW, and only haven-core's receive planes observe one; this boundary sees single events and caller-supplied numbers, which are evidence of nothing. Reading a cursor and resetting one to unseeded remain allowed. Cursor advances belong in haven_core::relay::catchup and live_sync::anchor."
fi

log "OK: no cursor advance is derived from an event timestamp, and no FFI entry point raises a cursor."
