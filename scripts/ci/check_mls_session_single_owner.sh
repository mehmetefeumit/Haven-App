#!/usr/bin/env bash
# CI guard: exactly one place per isolate may open the MLS database, and the UI
# isolate's one place must honour the pause-time handoff.
#
# Security Rule 14 allows ONE live `AccountDeviceSession` per MLS database per
# process. Android runs the UI and the location foreground service as two Dart
# isolates inside ONE OS process, so they share the Rust `LIVE_SESSIONS`
# registry that enforces it — and a second live session is not a tidiness
# problem: two hydrated sessions reach the same `(epoch, leaf, generation)` in
# the sender ratchet, which is a key/nonce reuse over location payloads.
#
# The handoff that makes background publishing work therefore has two halves,
# and this guard pins both:
#
#   1. SINGLE SITE. `CircleManagerFfi.newInstance` may appear in exactly three
#      files under haven/lib — one per isolate that legitimately owns a session
#      (UI, foreground service, WorkManager catch-up worker). A fourth call site
#      in the UI isolate would open the database directly and bypass (2)
#      entirely, which is precisely how the handoff was defeated before.
#
#   2. THE HANDOFF IS DURABLE. `NostrCircleService.releaseForHandoff` must latch
#      `_handedOff`, and `initialize` must consult it. Releasing without
#      latching frees the guard for an instant and re-takes it milliseconds
#      later — a paused isolate is not a dead one, and its suspended publish
#      chains, live-sync re-subscriber and maintenance ticks all re-open. The
#      foreground service then finds the guard held by a provably-alive owner,
#      its reclaim correctly declines, and background publishing stays dead.
#      That is the failure the `e2e-fgs-publish` lane reproduced.
#
# Pure-grep gate (no toolchain) so it runs in seconds alongside the other repo
# guards. Behavioural coverage lives in
# `haven/test/services/nostr_circle_service_test.dart` ("handoff durability");
# this exists to stop a NEW opener appearing where no test is looking.

set -euo pipefail

cd "$(dirname "$0")/../.."

readonly UI_OWNER='haven/lib/src/services/nostr_circle_service.dart'
readonly FGS_OWNER='haven/lib/src/services/background_location_task.dart'
readonly WORKER_OWNER='haven/lib/src/services/background_catchup_worker.dart'
status=0

# --- 1. Single site per isolate ----------------------------------------------
# Matches the CALL only (`newInstance(`), so the many doc comments naming the
# constructor across the codebase do not trip it. `haven/lib/src/rust/` is
# excluded: it is the generated binding that DEFINES the constructor.
if ! openers=$(grep -rln --include='*.dart' 'CircleManagerFfi\.newInstance(' \
    haven/lib 2>/dev/null | grep -v '^haven/lib/src/rust/' | sort); then
  echo "ERROR: no CircleManagerFfi.newInstance call site found in haven/lib."
  echo "Either the constructor was renamed or this guard is now vacuous —"
  echo "update it rather than deleting it."
  exit 1
fi

expected=$(printf '%s\n%s\n%s\n' "${UI_OWNER}" "${FGS_OWNER}" "${WORKER_OWNER}" \
  | sort)
if [[ "${openers}" != "${expected}" ]]; then
  echo "ERROR: unexpected set of MLS session openers in haven/lib."
  echo "found:"
  echo "${openers}" | sed 's/^/    /'
  echo "expected (one per isolate that owns a session):"
  echo "${expected}" | sed 's/^/    /'
  echo
  echo "Every other consumer must go through"
  echo "    NostrCircleService.getCircleManagerFfi()"
  echo "which is the single chokepoint honouring the pause-time handoff. A"
  echo "direct open bypasses it and re-takes the Rule-14 guard the foreground"
  echo "service was just handed (Security Rule 14; docs/CI_HARDENING_BACKLOG.md"
  echo "P0-1)."
  status=1
fi

# --- 2. The handoff latches, and the open consults the latch ------------------
# Ordering (latch before the early return) and the foregrounded lapse are
# asserted behaviourally by the unit tests; what a grep can add is that the two
# halves have not been deleted or drifted apart.
if ! grep -q '_handedOff = true;' "${UI_OWNER}"; then
  echo "ERROR: ${UI_OWNER} no longer latches the pause-time handoff."
  echo "releaseForHandoff() must set _handedOff, or the release frees the"
  echo "Rule-14 guard for an instant and this isolate takes it straight back."
  status=1
fi

# The refusal must live in `initialize` — the one funnel every reopen passes
# through. Bounded to that method so a stray mention elsewhere cannot satisfy
# it.
init_body=$(awk '/^  Future<void> initialize\(\) \{/ { f = 1 }
                 f { print }
                 f && /^  \}/ { exit }' "${UI_OWNER}")
if [[ -z "${init_body}" ]]; then
  echo "ERROR: could not locate NostrCircleService.initialize in ${UI_OWNER};"
  echo "update this guard rather than deleting it."
  status=1
elif ! grep -q '_handedOff' <<<"${init_body}"; then
  echo "ERROR: NostrCircleService.initialize does not consult the handoff latch."
  echo "Without that check every straggler open during the backgrounded window"
  echo "re-takes the session from the foreground service."
  status=1
fi

if (( status == 0 )); then
  echo "MLS session single-owner guard: OK (3 sanctioned openers, handoff latch intact)."
fi
exit "${status}"
