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
# The handoff that makes background publishing work therefore has three parts,
# and this guard pins all of them:
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
#   3. NO OPENER FILE IS RELEASE-STARVED. Each opener file must release at
#      least as many SESSION handles as it opens. An open is a CLAIM on the Rust
#      `LIVE_SESSIONS` registry, and only `dispose()` drops it; a handle that
#      falls out of scope undisposed holds the claim until the process dies, so
#      every later open in EVERY isolate is refused with "an MLS session is
#      already open on this database". The registry that makes (1) and (2) safe
#      is the same registry that makes one missed release permanent — and the
#      damage is not confined to the leaking isolate, which is why counting per
#      file is the check and why it belongs beside (1) rather than in a guard of
#      its own: a separate script would have to re-derive the sanctioned opener
#      set, and two derivations of one set drift.
#
#      This is a COUNT, and a count is a floor, not a matching — see the note on
#      `check_releases`. The matching is
#      `haven/test/lints/mls_session_handle_release_test.dart`, an analyzer-AST
#      lint that resolves each open to the name owning the handle and requires a
#      release on every explicit exit path. This step is kept as the fast
#      toolchain-free backstop: it is the only half that runs in this job, and a
#      file that stops releasing altogether should not have to wait for the
#      Flutter lane to say so.
#
# Pure-grep gate (no toolchain) so it runs in seconds alongside the other repo
# guards. Behavioural coverage lives in
# `haven/test/services/nostr_circle_service_test.dart` ("handoff durability");
# this exists to stop a NEW opener appearing where no test is looking.
#
# Usage:
#   check_mls_session_single_owner.sh              # check the tree
#   check_mls_session_single_owner.sh --self-test  # hermetic fixtures for (3)
#
# Exit codes:
#   0  all checks pass
#   1  an invariant is violated
#   2  the guard itself is broken (an opener that no longer opens; a failed
#      self-test)

set -euo pipefail

cd "$(dirname "$0")/../.."

readonly UI_OWNER='haven/lib/src/services/nostr_circle_service.dart'
readonly FGS_OWNER='haven/lib/src/services/background_location_task.dart'
readonly WORKER_OWNER='haven/lib/src/services/background_catchup_worker.dart'
status=0
broken=0

# --- check 3, factored so --self-test can drive it over fixtures -------------
# Counted over a comment-stripped view, so the prose in these files explaining
# why `dispose()` matters can never stand in for the call, and only over
# disposals of a SESSION handle — a receiver whose name ENDS in `manager`, the
# way every release in the tree is written (`manager`, `_manager`,
# `_circleManager`, `circleManager`). Without that restriction any unrelated
# `.dispose()` in the file — a stream controller, a ticker — counts as a release
# of the MLS session, which is the one thing this check exists to see. A handle
# named something else fails closed here rather than passing silently.
#
# The count is a FLOOR, not a matching, and the slack is real: the UI service
# legitimately releases its ONE handle on three exit paths (handoff, wiped
# in-flight init, close), so two further undisposed opens THERE still pass here
# — mutation-confirmed, not theorised. Tracing the handle is out of a grep's
# reach because the open is a closure result inside `withFreshSecret`, so the
# matching lives where an AST is available:
# `haven/test/lints/mls_session_handle_release_test.dart` follows that closure
# (and the local `open()` fan-out) to the local or field that owns the handle
# and walks every explicit exit path. It fails on both cases this count misses,
# and on a release deleted from one path while another still holds the count up.
# What the count still buys is speed and independence: it needs no toolchain,
# and it catches the limit case — an opener file that releases nothing at all —
# without depending on the lint being correct.
check_releases() {
  local owner="$1" code opens frees
  code=$(sed 's|//.*||' "${owner}")
  opens=$(grep -c 'CircleManagerFfi\.newInstance(' <<<"${code}" || true)
  frees=$(grep -cE '[Mm]anager\??\.dispose\(\)' <<<"${code}" || true)

  if (( opens == 0 )); then
    echo "ERROR: ${owner} no longer opens a session in code; check 1 and this one"
    echo "have drifted apart — update the guard rather than deleting it."
    return 2
  fi
  if (( frees < opens )); then
    echo "ERROR: ${owner} opens ${opens} MLS session(s) but releases only ${frees}."
    echo "Every CircleManagerFfi.newInstance() takes a claim on the Rust"
    echo "LIVE_SESSIONS registry that ONLY dispose() drops. An undisposed handle"
    echo "holds it for the life of the process, so every later open in every"
    echo "isolate — the foreground service's, the catch-up worker's — is refused"
    echo "with \"an MLS session is already open on this database\" (Security"
    echo "Rule 14; docs/CI_HARDENING_BACKLOG.md workstream D)."
    echo "A release whose receiver is not named *manager does not count here;"
    echo "name the handle for what it is rather than widening this check."
    echo "This count is only the floor — haven/test/lints/"
    echo "mls_session_handle_release_test.dart is the per-path matching, and it"
    echo "names the exit path that leaks rather than the file that is short."
    return 1
  fi
  return 0
}

# Fixtures for check 3. Both directions, because the interesting failure is a
# guard that reports a clean tree: the first case is the regression the receiver
# restriction closes, and it passed before it.
self_test() {
  local tmp failures=0
  tmp=$(mktemp -d)
  trap 'rm -rf "${tmp}"' RETURN

  case_is() {
    local want="$1" name="$2" src="$3" got
    printf '%s' "${src}" >"${tmp}/case.dart"
    set +e
    check_releases "${tmp}/case.dart" >/dev/null 2>&1
    got=$?
    set -e
    if (( got != want )); then
      echo "self-test FAILED [${name}]: expected exit ${want}, got ${got}" >&2
      failures=$((failures + 1))
    fi
  }

  # One unrelated release per LINE, and as many of them as there are opens:
  # `grep -c` counts lines, so a fixture that stacked them on one line would
  # fail under a receiver-blind counter too, and prove nothing about the
  # restriction it exists to pin.
  case_is 1 'an unrelated .dispose() is not a session release' \
'void a() { CircleManagerFfi.newInstance(dataDir: d); }
void b() { CircleManagerFfi.newInstance(dataDir: d); }
void c() { _subscription.dispose(); }
void d() { _tileController.dispose(); }'

  case_is 0 'every handle-shaped receiver in the tree counts' \
'void a() { CircleManagerFfi.newInstance(dataDir: d); }
void b() { manager.dispose(); }
void c() { _manager?.dispose(); }
void d() { _circleManager?.dispose(); }
void e() { circleManager.dispose(); }'

  case_is 1 'a commented-out release does not stand in for the call' \
'void a() { CircleManagerFfi.newInstance(dataDir: d); }
// The handle must be released here: manager.dispose();'

  case_is 1 'an open with no release at all' \
'void a() { CircleManagerFfi.newInstance(dataDir: d); }'

  case_is 2 'a file that no longer opens is a guard drift, not a pass' \
'void a() { manager.dispose(); }'

  if (( failures )); then
    echo "check 3 cannot be trusted until the ${failures} case(s) above are fixed." >&2
    return 2
  fi
  echo "MLS session single-owner guard: self-test OK (5 fixtures)."
  return 0
}

if [[ "${1:-}" == "--self-test" ]]; then
  self_test
  exit $?
fi

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

# --- 3. No opener file releases fewer handles than it opens -------------------
for owner in "${UI_OWNER}" "${FGS_OWNER}" "${WORKER_OWNER}"; do
  rc=0
  check_releases "${owner}" || rc=$?
  # An opener that no longer opens is guard DRIFT, not a violation of the rule:
  # checks 1 and 3 disagree about the sanctioned set, and one of them is wrong.
  if (( rc == 2 )); then broken=1; elif (( rc != 0 )); then status=1; fi
done

if (( broken )); then
  exit 2
fi
if (( status == 0 )); then
  echo "MLS session single-owner guard: OK (3 sanctioned openers, none release-starved, handoff latch intact)."
fi
exit "${status}"
