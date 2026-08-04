#!/usr/bin/env bash
#
# B9 network-loss/reconnect lane orchestrator —
# docs/CI_HARDENING_BACKLOG.md Workstream B, item B9: "Network loss/reconnect
# | `adb emu network disable/enable`".
#
# # THE ITEM'S MECHANISM DOES NOT EXIST
#
# There is no `network disable` / `network enable` in the Android emulator
# console. The console's `network` command takes exactly four subcommands —
# `status`, `speed`, `delay`, `capture` — confirmed by reading the help
# strings compiled into the shipped `qemu-system-x86_64` binary. The only
# connectivity kill switch the console offers is `gsm data <state>`, which
# reaches the CELLULAR path only, while an API-34 `google_apis` AVD routes
# over its emulated Wi-Fi, so `gsm data off` on its own is close to a no-op.
#
# This lane therefore drops the network with two layers, and does NOT trust
# either one:
#
#   L1 (the lane's subject) `cmd connectivity airplane-mode enable`, VERIFIED
#      through `settings get global airplane_mode_on`. This is genuine,
#      device-wide network loss across every transport — the thing item B9
#      names. The read-back is a HARD gate: a lane that silently degraded to
#      L2 alone would still be called "network loss" while testing only relay
#      unreachability.
#   L2 (immediacy)          an iptables REJECT of the strfry port on the
#      RUNNER HOST, in a dedicated `HAVEN_B9_OUTAGE` chain. The emulator uses
#      QEMU SLIRP userspace networking, so guest TCP is proxied through host
#      sockets and IS subject to the host OUTPUT chain (the same empirical
#      property `setup-network-guard.sh` documents and relies on). This turns
#      a blackout that Android might otherwise leave to a 55 s WebSocket
#      `PING_INTERVAL` into an immediate RST. Best-effort: skipped with a
#      warning where sudo/iptables are unavailable.
#
# The AUTHORITY on whether an outage happened is neither of them: the drive
# target probes the relay over a real WebSocket from inside the app process
# and prints `[b9] OUTAGE_OBSERVED` / `[b9] OUTAGE_NOT_OBSERVED`. That probe
# validates itself — it must succeed before the drop and after the restore —
# so it cannot rot into an always-fails oracle that reports a permanent
# outage.
#
# # What this lane proves that no other lane does
#
# Nothing in CI has ever disconnected a running Haven from the network. The
# live-sync engine's recovery story has three independent mechanisms and all
# three were unexercised at runtime:
#
#   1. the relay pool's own reconnect + `resubscribe()` replay of the stored
#      filters (nostr-relay-pool: 10 s retry adapting to 60 s);
#   2. Haven's M8 subscription-health tick re-anchoring at the persisted
#      cursor when a relay is `Disconnected` (+90 s, then every 15 min);
#   3. `MapShell._healLiveSyncIfStopped` -> `LiveSyncResubscriber
#      .ensureRunning()`, the ONLY thing that restarts an engine that
#      `NostrSubscriptionService._onStreamClosed` tore down, on a jittered
#      90-150 s timer that doubles per consecutive failure.
#
# (3) landed precisely because nothing restarted a dead engine. A network
# drop is its realistic trigger, and this lane is its runtime proof.
#
# # The oracle
#
#   1. SEQUENCE_COMPLETE                the drive finished (checked FIRST, so
#                                       later absences are not misread as
#                                       product defects)
#   2. BASELINE_RECEIVED ms=<N>         live receive worked BEFORE the drop
#   3. ENGINE_BASELINE running=true     anti-vacuity: something was connected
#   4. OUTAGE_OBSERVED                  the drop reached the app process
#   5. NETWORK_RESTORED                 connectivity came back
#   6. PEER_PUBLISHED_POST_OUTAGE       something was sent to receive
#   7. RECEIVE_RESUMED ms=<N>           THE HEADLINE: a PEER event decrypted
#                                       after the reconnect
#
# Step 7 is the point. A socket that reopened proves nothing a user cares
# about, so the drive asserts on the peer's NEW coordinates reaching
# `memberLocationsProvider` — the pre-outage entry survives the blackout, so
# a presence check would pass on an app whose receive path never came back.
#
# Steps 2, 3, 4 and 6 all exist to stop step 7 passing or failing vacuously:
# without a baseline, "it did not arrive" is unattributable; without a
# running engine there was no subscription to drop; without an observed
# outage nothing was disconnected; and without a published peer event there
# was nothing to receive.
#
# Usage:
#   run-b9-network-reconnect.sh [<apk> [<target.dart>]]
#   run-b9-network-reconnect.sh --self-test   # hermetic, no device
#
# Optional env:
#   B9_DRIVE_TIMEOUT        per-drive bound. Default 20m.
#   B9_STRFRY_PORT          host port strfry is published on. Default 7777.
#   B9_SKIP_HOST_BLOCK      set to 1 to skip layer L2 (local dev).

set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR="${script_dir}"

# Shared app-side failure predicate — `flutter drive` can exit 0 on a failed
# suite (drive-log-lib.sh). Sourced before the --self-test dispatch so the
# hermetic self-test runs against a fully-wired script.
# shellcheck source=tooling/e2e/ci/drive-log-lib.sh
source "${SCRIPT_DIR}/drive-log-lib.sh"

# ---------------------------------------------------------------------------
# VERBATIM markers. MUST match the `k*Marker` constants in
# haven/integration_test/b9_network_reconnect_test.dart — change both
# together or the lane silently stops finding them.
#
# Fixed literals matched with `grep -aF`: logcat is binary-tainted and these
# strings contain regex metacharacters.
#
# Every negative twin is a DISTINCT string rather than a suffix of its
# positive, so a substring match can never read one as the other
# (`NETWORK_RESTORED` is not a substring of `NETWORK_NOT_RESTORED`).
# ---------------------------------------------------------------------------
readonly MARK_ARMED='[b9] ARMED'
readonly MARK_BASELINE='[b9] BASELINE_RECEIVED'
readonly MARK_BASELINE_DEAD='[b9] BASELINE_DEAD'
readonly MARK_ENGINE_BASE='[b9] ENGINE_BASELINE'
readonly MARK_AWAIT_DOWN='[b9] AWAITING_NETWORK_DOWN'
readonly MARK_OUTAGE='[b9] OUTAGE_OBSERVED'
readonly MARK_NO_OUTAGE='[b9] OUTAGE_NOT_OBSERVED'
readonly MARK_ENGINE_OUTAGE='[b9] ENGINE_DURING_OUTAGE'
readonly MARK_AWAIT_UP='[b9] AWAITING_NETWORK_UP'
readonly MARK_RESTORED='[b9] NETWORK_RESTORED'
readonly MARK_NOT_RESTORED='[b9] NETWORK_NOT_RESTORED'
readonly MARK_PEER_PUB='[b9] PEER_PUBLISHED_POST_OUTAGE'
readonly MARK_PEER_PUB_FAIL='[b9] PEER_PUBLISH_FAILED'
readonly MARK_RESUMED='[b9] RECEIVE_RESUMED'
readonly MARK_RECEIVE_DEAD='[b9] RECEIVE_DEAD'
readonly MARK_ENGINE_RECOVERED='[b9] ENGINE_AFTER_RECOVERY'
readonly MARK_COMPLETE='[b9] SEQUENCE_COMPLETE'

# ---------------------------------------------------------------------------
# Oracle predicates — pure text, no device. Everything the lane's verdict
# rests on lives here so `--self-test` can exercise it hermetically.
# ---------------------------------------------------------------------------

# b9_has_marker <logfile> <marker> — 0 (true) when the marker appears.
#
# Substring match, not anchored: the same line reaches us either as raw
# `debugPrint` output in the drive log or wrapped by logcat's
# `I/flutter ( 1234): ` prefix, and both must count.
b9_has_marker() {
  local logfile="${1:-}" marker="${2:-}"
  [[ -f "${logfile}" ]] || return 1
  grep -aqF -- "${marker}" "${logfile}"
}

# b9_marker_number <logfile> <marker> <key> — echoes the LARGEST integer
# following `<key>=` on any line carrying <marker>, or nothing.
#
# PARSED, never grepped for presence: the numbers here are evidence
# (recovery latency, re-publish count) and a `sort -n` is required because
# '9' outranks '12' lexically.
b9_marker_number() {
  local logfile="${1:-}" marker="${2:-}" key="${3:-}"
  [[ -f "${logfile}" ]] || return 0
  { grep -aF -- "${marker}" "${logfile}" 2>/dev/null \
      | grep -aoE "${key}=[0-9]+" \
      | grep -aoE '[0-9]+' | sort -n | tail -1; } || true
}

# b9_marker_flag <logfile> <marker> <key> — echoes the LAST `<key>=<word>`
# value on any line carrying <marker>, or nothing.
#
# Used for the `running=true|false` engine readings, where the VALUE is the
# verdict and the marker's presence means only that the drive got there.
b9_marker_flag() {
  local logfile="${1:-}" marker="${2:-}" key="${3:-}"
  [[ -f "${logfile}" ]] || return 0
  { grep -aF -- "${marker}" "${logfile}" 2>/dev/null \
      | grep -aoE "${key}=[A-Za-z0-9_.-]+" \
      | sed "s/^${key}=//" | tail -1 | tr -d '\r'; } || true
}

# ---------------------------------------------------------------------------
# The oracle itself, as a testable function over a capture file.
#
# Findings accumulate rather than exiting on the first one: the lane's value
# is the WHOLE picture (was it live, did it really disconnect, did it come
# back, did a PEER EVENT arrive), and stopping early would hide the rest.
# Returns 1 when any finding was recorded. NOTES (never failures) go to
# stdout as evidence.
# ---------------------------------------------------------------------------
B9_FINDINGS=()

b9_note() { printf '  NOTE: %s\n' "$*"; }
b9_finding() { B9_FINDINGS+=("$*"); }

b9_run_oracle() {
  local log="${1:-}"
  B9_FINDINGS=()

  if [[ ! -f "${log}" ]]; then
    b9_finding "no capture file at '${log}' — the lane recorded nothing."
    return 1
  fi

  # (1) The drive reached the end of its own sequence. Checked FIRST because
  #     every later "marker absent" finding would otherwise be reported as a
  #     product defect when the true cause is a drive that died early.
  if ! b9_has_marker "${log}" "${MARK_COMPLETE}"; then
    b9_finding "the drive never printed '${MARK_COMPLETE}' — it did not \
reach the end of its sequence, so every absent marker below may be a \
consequence of that rather than a product defect. Rule the drive out first."
  fi

  # (2) BASELINE — live receive worked BEFORE anything was broken.
  if b9_has_marker "${log}" "${MARK_BASELINE_DEAD}"; then
    b9_finding "the peer's BASELINE location never reached \
memberLocationsProvider ('${MARK_BASELINE_DEAD}'). Live receive was already \
broken BEFORE the network was touched, so nothing this lane observed \
afterwards can be attributed to the drop. Suspect the engine start, the \
staged-create confirm, or circle selection — not reconnect."
  elif ! b9_has_marker "${log}" "${MARK_BASELINE}"; then
    b9_finding "no '${MARK_BASELINE}' line — the drive never established \
that live receive worked before the outage, so the recovery verdict below \
has no baseline to be measured against."
  else
    b9_note "baseline: peer location decrypted in \
$(b9_marker_number "${log}" "${MARK_BASELINE}" 'ms')ms over the live engine."
  fi

  # (3) ANTI-VACUITY — something was actually connected to disconnect.
  local engine_base
  engine_base="$(b9_marker_flag "${log}" "${MARK_ENGINE_BASE}" 'running')"
  if [[ -z "${engine_base}" ]]; then
    b9_finding "no '${MARK_ENGINE_BASE} running=<bool>' line — without it, a \
run in which the live-sync engine was never up is indistinguishable from one \
whose engine was dropped and recovered."
  elif [[ "${engine_base}" != "true" ]]; then
    b9_finding "the live-sync engine was NOT running before the drop \
(${MARK_ENGINE_BASE} running=${engine_base}). There was no standing \
subscription to disconnect, so the reconnect verdict on this run is VACUOUS \
— fix the harness before reading anything into it."
  fi

  # (4) The drop reached the app under test, not merely adb.
  if b9_has_marker "${log}" "${MARK_NO_OUTAGE}"; then
    b9_finding "the relay stayed reachable from inside the app process after \
the network was dropped ('${MARK_NO_OUTAGE}'). HARNESS failure: neither \
\`cmd connectivity airplane-mode enable\` nor the host-side port REJECT \
disconnected the process under test, so this run exercised nothing."
  elif ! b9_has_marker "${log}" "${MARK_OUTAGE}"; then
    b9_finding "no '${MARK_OUTAGE}' line — the drive never confirmed an \
outage at all, so nothing below is a reconnect observation."
  else
    b9_note "outage observed by the app process after \
$(b9_marker_number "${log}" "${MARK_OUTAGE}" 'ms')ms."
  fi

  # (5) Connectivity came back.
  if b9_has_marker "${log}" "${MARK_NOT_RESTORED}"; then
    b9_finding "connectivity never returned to the app process \
('${MARK_NOT_RESTORED}'). HARNESS failure — recovery could not be tested. \
Check the restore half of the airplane-mode toggle and the \
HAVEN_B9_OUTAGE chain teardown."
  elif ! b9_has_marker "${log}" "${MARK_RESTORED}"; then
    b9_finding "no '${MARK_RESTORED}' line — the drive never confirmed that \
the network came back."
  fi

  # (6) Something was sent to receive.
  if b9_has_marker "${log}" "${MARK_PEER_PUB_FAIL}"; then
    b9_finding "the peer could not publish after connectivity returned \
('${MARK_PEER_PUB_FAIL}'). The receive verdict below is UNREADABLE: a silent \
receive path and a silent send path are indistinguishable when nothing was \
sent."
  elif ! b9_has_marker "${log}" "${MARK_PEER_PUB}"; then
    b9_finding "no '${MARK_PEER_PUB}' line — no post-outage peer event was \
confirmed onto the relay, so 'the location never arrived' says nothing about \
the receive path."
  fi

  # (7) THE HEADLINE — a PEER EVENT DECRYPTED AFTER THE RECONNECT.
  if ! b9_has_marker "${log}" "${MARK_RESUMED}"; then
    if b9_has_marker "${log}" "${MARK_RECEIVE_DEAD}"; then
      b9_finding "live location receive did NOT recover after the network \
came back ('${MARK_RECEIVE_DEAD}'). The peer's post-outage location was \
OK-acked by the relay and Alice never decrypted it, so a transient network \
drop permanently ended live receive for the session. The drive's budget \
covers ALL THREE recovery paths — the relay pool's own reconnect + \
resubscribe (<=60s), the M8 subscription-health re-anchor, and MapShell's \
90-150s self-heal including one doubled retry — so this is not a budget \
that was too tight."
    else
      b9_finding "neither '${MARK_RESUMED}' nor '${MARK_RECEIVE_DEAD}' was \
recorded — the drive never reached the recovery check."
    fi
  else
    b9_note "recovery: a PEER location was decrypted \
$(b9_marker_number "${log}" "${MARK_RESUMED}" 'ms')ms after connectivity \
returned, with \
$(b9_marker_number "${log}" "${MARK_RESUMED}" 'republishes') re-publish(es)."
  fi

  # (8) EVIDENCE ONLY — which recovery mechanism this run exercised. An
  #     engine that survived the outage recovered through the relay pool's
  #     own reconnect; one that died needed MapShell's self-heal, which is
  #     an order of magnitude slower and is the path that had no runtime
  #     proof before this lane. Recorded, never asserted: both are correct
  #     outcomes and the lane must not pin an implementation detail.
  local engine_outage engine_recovered
  engine_outage="$(b9_marker_flag "${log}" "${MARK_ENGINE_OUTAGE}" 'running')"
  engine_recovered="$(b9_marker_flag "${log}" "${MARK_ENGINE_RECOVERED}" \
    'running')"
  if [[ -n "${engine_outage}" ]]; then
    if [[ "${engine_outage}" == "true" ]]; then
      b9_note "the live-sync engine SURVIVED the outage — recovery went \
through the relay pool's reconnect/resubscribe, not MapShell's self-heal."
    else
      b9_note "the live-sync engine was torn down during the outage \
(NostrSubscriptionService._onStreamClosed), so recovery required MapShell's \
90-150s self-heal (LiveSyncResubscriber.ensureRunning) — the slow path, and \
the one this lane exists to prove."
    fi
  fi
  if [[ -n "${engine_recovered}" ]]; then
    b9_note "engine running after the recovery window: ${engine_recovered}."
  fi

  (( ${#B9_FINDINGS[@]} == 0 ))
}

# ---------------------------------------------------------------------------
# Self-test — hermetic fixtures, no device, no relay.
#
# Chosen so a predicate that has rotted into always-passing cannot survive:
# (11) is the REAL FINDING case (everything green except the recovery) and
# must be reported, (12) is the healthy app and must PASS — without it an
# oracle hard-coded to red would look correct in (11) — and (13)-(16) are the
# four distinct vacuity routes, each of which would otherwise let step 7 pass
# or fail for a reason that is not about reconnect at all.
# ---------------------------------------------------------------------------
run_self_test() {
  local tmp fails=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  _case() { # _case <label> <expected-rc> <actual-rc>
    local label="$1" want="$2" got="$3"
    if [[ "${got}" -eq "${want}" ]]; then
      printf '  \033[1;32mPASS\033[0m %s\n' "${label}"
    else
      printf '  \033[1;31mFAIL\033[0m %s (want rc=%s, got rc=%s)\n' \
        "${label}" "${want}" "${got}" >&2
      fails=1
    fi
  }

  _eq_case() { # _eq_case <label> <expected> <actual>
    local label="$1" want="$2" got="$3"
    if [[ "${got}" == "${want}" ]]; then
      printf '  \033[1;32mPASS\033[0m %s\n' "${label}"
    else
      printf '  \033[1;31mFAIL\033[0m %s (want "%s", got "%s")\n' \
        "${label}" "${want}" "${got}" >&2
      fails=1
    fi
  }

  # A complete, PASSING capture: live before, genuinely disconnected,
  # reconnected, and a PEER EVENT decrypted afterwards. Written as a function
  # so each negative fixture mutates exactly one line and nothing else.
  _fixture_full() { # _fixture_full <outfile> [recovery-line]
    local out="$1"
    local rec="${2:-I/flutter ( 40): ${MARK_RESUMED} ms=41210 republishes=1}"
    printf '%s\n' \
      "I/flutter ( 40): ${MARK_ARMED}" \
      "I/flutter ( 40): ${MARK_BASELINE} ms=1840" \
      "I/flutter ( 40): ${MARK_ENGINE_BASE} running=true" \
      "I/flutter ( 40): ${MARK_AWAIT_DOWN}" \
      "I/flutter ( 40): ${MARK_OUTAGE} ms=9120" \
      "I/flutter ( 40): ${MARK_ENGINE_OUTAGE} running=false" \
      "I/flutter ( 40): ${MARK_AWAIT_UP}" \
      "I/flutter ( 40): ${MARK_RESTORED} ms=6030" \
      "I/flutter ( 40): ${MARK_PEER_PUB}" \
      "${rec}" \
      "I/flutter ( 40): ${MARK_ENGINE_RECOVERED} running=true" \
      "I/flutter ( 40): ${MARK_COMPLETE}" \
      > "${out}"
  }

  echo "run-b9-network-reconnect.sh --self-test"

  # --- b9_has_marker ------------------------------------------------------
  # (1) A raw drive-log line (no logcat prefix).
  printf '%s\n' "${MARK_OUTAGE} ms=1" > "${tmp}/raw.log"
  local rc=0; b9_has_marker "${tmp}/raw.log" "${MARK_OUTAGE}" || rc=1
  _case "marker found in a raw drive log" 0 "${rc}"

  # (2) THE SHAPE THAT ACTUALLY SHIPS — the same line via logcat, prefixed.
  printf '%s\n' "I/flutter ( 4021): ${MARK_OUTAGE} ms=1" > "${tmp}/lc.log"
  rc=0; b9_has_marker "${tmp}/lc.log" "${MARK_OUTAGE}" || rc=1
  _case "marker found behind a logcat prefix" 0 "${rc}"

  # (3) A missing file is not evidence of success.
  rc=0; b9_has_marker "${tmp}/nope.log" "${MARK_OUTAGE}" || rc=1
  _case "missing log reports absent" 1 "${rc}"

  # (4) THE NEGATIVE-TWIN TRAP. `OUTAGE_NOT_OBSERVED` must never satisfy a
  #     search for `OUTAGE_OBSERVED`, or a lane that never disconnected
  #     would read as one that did — the single most dangerous false green
  #     available here.
  printf '%s\n' "I/flutter ( 40): ${MARK_NO_OUTAGE}" > "${tmp}/twin.log"
  rc=0; b9_has_marker "${tmp}/twin.log" "${MARK_OUTAGE}" || rc=1
  _case "negative twin does not satisfy its positive (outage)" 1 "${rc}"

  # (5) Same trap on the restore pair.
  printf '%s\n' "I/flutter ( 40): ${MARK_NOT_RESTORED}" > "${tmp}/twin2.log"
  rc=0; b9_has_marker "${tmp}/twin2.log" "${MARK_RESTORED}" || rc=1
  _case "negative twin does not satisfy its positive (restore)" 1 "${rc}"

  # (6) …and on the publish pair.
  printf '%s\n' "I/flutter ( 40): ${MARK_PEER_PUB_FAIL} reason=StateError" \
    > "${tmp}/twin3.log"
  rc=0; b9_has_marker "${tmp}/twin3.log" "${MARK_PEER_PUB}" || rc=1
  _case "negative twin does not satisfy its positive (publish)" 1 "${rc}"

  # --- b9_marker_number ---------------------------------------------------
  # (7) Double digits must not lose to a lexical sort ('9' > '12').
  printf '%s\n' \
    "I/flutter ( 40): ${MARK_RESUMED} ms=9 republishes=0" \
    "I/flutter ( 40): ${MARK_RESUMED} ms=124000 republishes=2" \
    > "${tmp}/wide.log"
  _eq_case "numeric (not lexical) max" "124000" \
    "$(b9_marker_number "${tmp}/wide.log" "${MARK_RESUMED}" 'ms')"

  # (8) A key on an UNRELATED marker must not answer for ours — several
  #     markers carry `ms=`.
  printf '%s\n' \
    "I/flutter ( 40): ${MARK_BASELINE} ms=1840" \
    "I/flutter ( 40): ${MARK_RESTORED} ms=99999" \
    > "${tmp}/mixed.log"
  _eq_case "key scoped to its own marker" "1840" \
    "$(b9_marker_number "${tmp}/mixed.log" "${MARK_BASELINE}" 'ms')"

  # (9) Absent marker -> empty, which is DISTINCT from "0".
  printf '%s\n' 'I/flutter ( 40): nothing here' > "${tmp}/none.log"
  _eq_case "absent marker yields empty (not 0)" "" \
    "$(b9_marker_number "${tmp}/none.log" "${MARK_RESUMED}" 'ms')"

  # --- b9_marker_flag -----------------------------------------------------
  # (10) The vacuity reading, with the CRLF adb actually emits.
  printf "I/flutter ( 40): ${MARK_ENGINE_BASE} running=false\r\n" \
    > "${tmp}/flag.log"
  _eq_case "flag parsed (false, CRLF)" "false" \
    "$(b9_marker_flag "${tmp}/flag.log" "${MARK_ENGINE_BASE}" 'running')"

  # --- b9_run_oracle ------------------------------------------------------
  # (11) THE REAL FINDING: everything worked until the reconnect, and live
  #      receive never came back. MUST be reported, or the lane blesses the
  #      defect it exists to find.
  _fixture_full "${tmp}/dead.log" \
    "I/flutter ( 40): ${MARK_RECEIVE_DEAD} republishes=7"
  rc=0; b9_run_oracle "${tmp}/dead.log" >/dev/null || rc=1
  _case "never-recovered capture is REPORTED" 1 "${rc}"
  if (( rc == 1 )) && [[ "${B9_FINDINGS[*]}" != *"did NOT recover"* ]]; then
    printf '  \033[1;31mFAIL\033[0m never-recovered finding does not name the recovery defect\n' >&2
    fails=1
  fi

  # (12) THE HEALTHY APP — identical except that the peer event arrived.
  #      Must PASS, or an oracle hard-coded to red would look correct above.
  _fixture_full "${tmp}/ok.log"
  rc=0; b9_run_oracle "${tmp}/ok.log" >/dev/null || rc=1
  _case "fully-recovered capture PASSES" 0 "${rc}"

  # (13) VACUITY ROUTE A — the engine was never running, so there was no
  #      subscription to drop. Every other marker is present.
  _fixture_full "${tmp}/noengine.log"
  sed -i 's/ENGINE_BASELINE running=true/ENGINE_BASELINE running=false/' \
    "${tmp}/noengine.log"
  rc=0; b9_run_oracle "${tmp}/noengine.log" >/dev/null || rc=1
  _case "engine never running fails as vacuous" 1 "${rc}"
  if (( rc == 1 )) && [[ "${B9_FINDINGS[*]}" != *"VACUOUS"* ]]; then
    printf '  \033[1;31mFAIL\033[0m non-running engine is not reported as vacuous\n' >&2
    fails=1
  fi

  # (14) VACUITY ROUTE B — the network never actually went away. This is the
  #      one the item's own (non-existent) `adb emu network disable` would
  #      have produced silently.
  _fixture_full "${tmp}/nodrop.log"
  sed -i "s/OUTAGE_OBSERVED ms=9120/OUTAGE_NOT_OBSERVED/" "${tmp}/nodrop.log"
  rc=0; b9_run_oracle "${tmp}/nodrop.log" >/dev/null || rc=1
  _case "outage that never happened fails the lane" 1 "${rc}"
  if (( rc == 1 )) && [[ "${B9_FINDINGS[*]}" != *"HARNESS failure"* ]]; then
    printf '  \033[1;31mFAIL\033[0m missing outage is not attributed to the harness\n' >&2
    fails=1
  fi

  # (15) VACUITY ROUTE C — receive was already broken before the drop, so
  #      "it did not come back" is unattributable.
  _fixture_full "${tmp}/nobase.log"
  sed -i "s/BASELINE_RECEIVED ms=1840/BASELINE_DEAD/" "${tmp}/nobase.log"
  rc=0; b9_run_oracle "${tmp}/nobase.log" >/dev/null || rc=1
  _case "dead baseline fails the lane" 1 "${rc}"

  # (16) VACUITY ROUTE D — nothing was published after the outage, so a
  #      silent receive path and a silent send path are indistinguishable.
  _fixture_full "${tmp}/nopub.log" \
    "I/flutter ( 40): ${MARK_RECEIVE_DEAD} republishes=0"
  sed -i "s/PEER_PUBLISHED_POST_OUTAGE/PEER_PUBLISH_FAILED reason=StateError/" \
    "${tmp}/nopub.log"
  rc=0; b9_run_oracle "${tmp}/nopub.log" >/dev/null || rc=1
  _case "unsent peer event fails the lane" 1 "${rc}"
  if (( rc == 1 )) && [[ "${B9_FINDINGS[*]}" != *"UNREADABLE"* ]]; then
    printf '  \033[1;31mFAIL\033[0m unsent peer event is not reported as unreadable\n' >&2
    fails=1
  fi

  # (17) A truncated capture (the drive died) must say so FIRST, so its
  #      downstream absences are not misread as product defects.
  printf '%s\n' \
    "I/flutter ( 40): ${MARK_ARMED}" \
    "I/flutter ( 40): ${MARK_BASELINE} ms=1840" \
    "I/flutter ( 40): ${MARK_ENGINE_BASE} running=true" \
    "I/flutter ( 40): ${MARK_AWAIT_DOWN}" \
    > "${tmp}/truncated.log"
  rc=0; b9_run_oracle "${tmp}/truncated.log" >/dev/null || rc=1
  _case "truncated capture fails the lane" 1 "${rc}"
  if (( rc == 1 )) && [[ "${B9_FINDINGS[0]}" != *"${MARK_COMPLETE}"* ]]; then
    printf '  \033[1;31mFAIL\033[0m truncated capture does not report the drive first\n' >&2
    fails=1
  fi

  # (18) A missing capture proves nothing and must never pass.
  rc=0; b9_run_oracle "${tmp}/absent.log" >/dev/null || rc=1
  _case "missing capture fails the lane" 1 "${rc}"

  # (19) The drive-log failure predicate this lane leans on is exercised by
  #      its own self-test; assert only that sourcing worked, so a refactor
  #      that drops the `source` fails here rather than at 3am.
  rc=0; declare -F drive_log_reports_test_failure >/dev/null || rc=1
  _case "drive-log failure predicate is in scope" 0 "${rc}"

  if (( fails )); then
    echo "run-b9-network-reconnect.sh --self-test: FAILURES" >&2
    return 1
  fi
  echo "run-b9-network-reconnect.sh --self-test: all 19 fixtures passed"
  return 0
}

if [[ "${1:-}" == "--self-test" ]]; then
  run_self_test
  exit $?
fi

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
readonly PKG="com.oblivioustech.haven"
readonly DEVICE="emulator-5554"
readonly DRIVER_FILE="test_driver/integration_test.dart"
readonly LOG_DIR="/tmp/b9-logs"
readonly APK="${1:-/tmp/integration-apks/b9_network_reconnect_test.apk}"
readonly TARGET="${2:-integration_test/b9_network_reconnect_test.dart}"

# Bounds the drive only; the step's run-with-deadline.sh wrapper bounds
# install + grants + both network toggles + the oracle on top (see
# scripts/ci/check_e2e_step_timeout_ordering.sh for the ordering invariant).
#
# Sizing: the drive target's own budget is arming (~90s under emulator mlock
# pressure) + up to 75s for the baseline receive + up to 120s waiting for the
# drop + the 75s outage hold + up to 120s waiting for the restore + up to
# 330s for recovery = ~13 min worst case, against a 16-minute in-test
# `Timeout`. 20m leaves headroom for a slow cold start without letting a
# wedge run anonymously to the outer deadline.
readonly DRIVE_TIMEOUT="${B9_DRIVE_TIMEOUT:-20m}"

# Host port strfry is published on — the port layer L2 rejects.
readonly STRFRY_PORT="${B9_STRFRY_PORT:-7777}"
if [[ ! "${STRFRY_PORT}" =~ ^[0-9]{1,5}$ ]]; then
  echo "ERROR: B9_STRFRY_PORT must be a plain port number (got" \
       "'${STRFRY_PORT}')." >&2
  exit 2
fi

# The dedicated iptables chain for layer L2. Named, created and destroyed by
# THIS script only, so it can never collide with setup-network-guard.sh's
# HAVEN_E2E_GUARD (which the hermetic lanes install for a different purpose
# and leave up for the whole job).
readonly HOST_CHAIN="HAVEN_B9_OUTAGE"

# How long to wait for each of the drive's cue markers. Generous relative to
# the drive's own internal budgets: a late marker is still usable evidence,
# while a marker wait that fires early destroys the run.
readonly ARM_MARKER_TIMEOUT="${B9_ARM_MARKER_TIMEOUT:-420}"
readonly OUTAGE_MARKER_TIMEOUT="${B9_OUTAGE_MARKER_TIMEOUT:-360}"

readonly REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
readonly HAVEN_DIR="${REPO_ROOT}/haven"
readonly START_STRFRY="${SCRIPT_DIR}/start-strfry.sh"
readonly STOP_STRFRY="${SCRIPT_DIR}/stop-strfry.sh"
readonly SECRET_SCAN="${SCRIPT_DIR}/scan-logs-for-secrets.sh"

LOGCAT_PID=""
DRIVE_PID=""
HOST_BLOCK_INSTALLED=0

mkdir -p "${LOG_DIR}"
readonly LOGCAT_FILE="${LOG_DIR}/logcat.b9.log"
readonly DRIVE_LOG="${LOG_DIR}/flutter-drive.log"
readonly NET_LOG="${LOG_DIR}/network-toggles.b9.log"

# ---------------------------------------------------------------------------
# Layer L2 — host-side REJECT of the relay port.
#
# The emulator proxies guest TCP through host sockets (QEMU SLIRP), so a host
# OUTPUT rule reaches the guest's relay connection. `--reject-with tcp-reset`
# rather than DROP: an RST kills the established socket immediately, where a
# black hole would leave the pool waiting out its 55 s PING_INTERVAL before
# noticing — turning a 75 s outage into one the app barely registers.
#
# Entirely best-effort. The drive is the authority on whether an outage
# happened, so a runner without passwordless sudo degrades to layer L1 alone
# (slower detection) rather than failing the lane.
# ---------------------------------------------------------------------------
host_block_install() {
  if [[ "${B9_SKIP_HOST_BLOCK:-}" == "1" ]]; then
    echo "  L2 skipped (B9_SKIP_HOST_BLOCK=1)"
    return 0
  fi
  if ! command -v iptables >/dev/null 2>&1 || ! sudo -n true 2>/dev/null; then
    echo "  L2 unavailable (no iptables or no passwordless sudo) — relying" \
         "on airplane mode alone; socket death may take up to one 55s" \
         "WebSocket ping interval." >&2
    return 0
  fi
  sudo iptables -N "${HOST_CHAIN}" 2>/dev/null \
    || sudo iptables -F "${HOST_CHAIN}" 2>/dev/null || true
  sudo iptables -A "${HOST_CHAIN}" -p tcp --dport "${STRFRY_PORT}" \
    -j REJECT --reject-with tcp-reset 2>/dev/null || true
  sudo iptables -D OUTPUT -j "${HOST_CHAIN}" 2>/dev/null || true
  sudo iptables -I OUTPUT 1 -j "${HOST_CHAIN}" 2>/dev/null || true
  HOST_BLOCK_INSTALLED=1
  echo "  L2 installed: OUTPUT -> ${HOST_CHAIN} rejects tcp/${STRFRY_PORT}"
}

host_block_remove() {
  (( HOST_BLOCK_INSTALLED == 1 )) || return 0
  sudo iptables -D OUTPUT -j "${HOST_CHAIN}" 2>/dev/null || true
  sudo iptables -F "${HOST_CHAIN}" 2>/dev/null || true
  sudo iptables -X "${HOST_CHAIN}" 2>/dev/null || true
  HOST_BLOCK_INSTALLED=0
  echo "  L2 removed"
}

# ---------------------------------------------------------------------------
# Cleanup (EXIT trap): stop the background helpers, RESTORE connectivity in
# BOTH layers (a lane that left airplane mode on, or an iptables REJECT
# installed, would silently poison every later step in this job — including
# its own artifact upload), run the MANDATORY secret scan over every captured
# log (Security Rule 6 — must run even on a phase failure), snapshot + tear
# down strfry. Escalates on a leak; never masks a phase rc.
#
# Mirrors run-b6-location-provider-toggle.sh containment, including the
# deliberate asymmetry between rc 1 (leak -> destroy the logs) and rc 3
# (unscannable -> keep them, because there is no leak and the truncated
# artefacts ARE the evidence of the failure that tripped the guard).
# ---------------------------------------------------------------------------
cleanup() {
  local rc=$?
  local scan_rc=0
  trap - EXIT
  if [[ -n "${DRIVE_PID}" ]] && kill -0 "${DRIVE_PID}" 2>/dev/null; then
    kill "${DRIVE_PID}" 2>/dev/null || true
  fi
  # Restore BEFORE logcat is stopped so the restore itself is captured.
  host_block_remove || true
  adb -s "${DEVICE}" shell cmd connectivity airplane-mode disable \
    >/dev/null 2>&1 || true
  if [[ -n "${LOGCAT_PID}" ]] && kill -0 "${LOGCAT_PID}" 2>/dev/null; then
    kill "${LOGCAT_PID}" 2>/dev/null || true
  fi
  docker logs strfry > "${LOG_DIR}/strfry.final.log" 2>&1 || true
  echo "== Secret-leak scan over ${LOG_DIR} (Security Rule 6) =="
  bash "${SECRET_SCAN}" "${LOG_DIR}" || scan_rc=$?
  if (( scan_rc == 1 )); then
    find "${LOG_DIR}" -type f -name '*.log' -delete 2>/dev/null || true
    {
      echo "Logs withheld: the secret-leak guard tripped (Security Rule 6)."
      echo "See the LEAK line(s) in the step log for file/label/line numbers."
    } > "${LOG_DIR}/LEAK_DETECTED.txt"
    echo "ERROR: secret-leak guard tripped on B9 logs — logs deleted," \
         "not uploaded." >&2
    rc=1
  elif (( scan_rc != 0 )); then
    echo "ERROR: secret-leak guard could not scan the B9 logs" \
         "(rc=${scan_rc}) — see the UNUSABLE line(s) above. Logs kept for" \
         "triage." >&2
    rc=1
  fi
  bash "${STOP_STRFRY}" >/dev/null 2>&1 || true
  exit "${rc}"
}
trap cleanup EXIT

fail() {
  echo "B9-LANE-FAIL: $*" >&2
  if (( ${drive_failed:-0} == 1 )); then
    echo "NOTE: the drive ALSO did not complete cleanly" \
         "(${drive_reason:-unknown}). The finding above may be a CONSEQUENCE" \
         "of that rather than a product defect — rule the drive failure out" \
         "first." >&2
  fi
  echo "---- [b9] markers seen ----" >&2
  grep -ahF '[b9] ' "${LOGCAT_FILE}" "${DRIVE_LOG}" 2>/dev/null | tail -40 >&2 \
    || echo "(none — the drive target reached no checkpoint at all)" >&2
  echo "---- network toggle log ----" >&2
  cat "${NET_LOG}" >&2 2>/dev/null || echo "(no toggles recorded)" >&2
  echo "---- guest connectivity state ----" >&2
  {
    echo "airplane_mode_on=$(airplane_state)"
    adb -s "${DEVICE}" shell dumpsys connectivity 2>/dev/null \
      | grep -aiE 'Active default network|NetworkAgentInfo.*CONNECTED' \
      | head -10
  } >&2 2>/dev/null || echo "(connectivity state unavailable)" >&2
  exit 1
}

# airplane_state — echoes `1` / `0` as the platform records it, or empty.
#
# `settings get global airplane_mode_on` is the AUTHORITATIVE read-back:
# `cmd connectivity airplane-mode enable` returns 0 whether or not the
# caller was permitted to change it, exactly like `pm grant` does for a
# hard-restricted permission (the trap B3/B6 document).
airplane_state() {
  adb -s "${DEVICE}" shell settings get global airplane_mode_on 2>/dev/null \
    | tr -d '\r' | tr -d '[:space:]' || true
}

# set_airplane <1|0> — toggles airplane mode and VERIFIES the read-back.
#
# The verification is a HARD gate on the DOWN direction: a toggle that
# silently did not take would leave layer L2 producing the outage on its own,
# and the lane would keep calling itself "network loss" while proving only
# that an unreachable relay is survivable. Naming that difference is the
# whole reason the read-back exists.
set_airplane() {
  local want="$1" verb="disable" got=""
  [[ "${want}" == "1" ]] && verb="enable"
  adb -s "${DEVICE}" shell cmd connectivity airplane-mode "${verb}" \
    >/dev/null 2>&1 || true
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    got="$(airplane_state)"
    [[ "${got}" == "${want}" ]] && break
    sleep 1
  done
  printf '%s airplane-mode %s -> airplane_mode_on=%s\n' \
    "$(date -u +%H:%M:%S)" "${verb}" "${got:-<unreadable>}" >> "${NET_LOG}"
  echo "  airplane_mode_on now: ${got:-<unreadable>}"
  [[ "${got}" == "${want}" ]]
}

# wait_for_marker <marker> <timeout-secs> — 0 when the marker appears in the
# logcat capture, 1 on timeout or on the drive dying first.
#
# Watching the drive's liveness matters: a target that crashed will never
# print its next cue, and burning the full marker timeout on a corpse turns a
# clear "the drive died" into an anonymous lane-level timeout.
wait_for_marker() {
  local marker="$1" timeout_s="$2" waited=0
  while (( waited < timeout_s )); do
    if grep -aqF -- "${marker}" "${LOGCAT_FILE}" 2>/dev/null; then
      echo "  observed '${marker}' after ${waited}s"
      return 0
    fi
    if [[ -n "${DRIVE_PID}" ]] && ! kill -0 "${DRIVE_PID}" 2>/dev/null; then
      echo "  the drive exited before '${marker}' appeared (after ${waited}s)" >&2
      return 1
    fi
    sleep 2
    waited=$(( waited + 2 ))
  done
  echo "  timed out after ${timeout_s}s waiting for '${marker}'" >&2
  return 1
}

# ---------------------------------------------------------------------------
# Phase 0 — hermetic relay + device readiness.
# ---------------------------------------------------------------------------
echo "Phase 0/6 — starting hermetic strfry..."
bash "${START_STRFRY}"
adb -s "${DEVICE}" wait-for-device
echo "Phase 0/6 — device ready."

# ---------------------------------------------------------------------------
# Phase 1 — clean install. Force-stop + uninstall FIRST so no sticky state
# from a prior target survives into this run.
# ---------------------------------------------------------------------------
echo "Phase 1/6 — installing ${APK}..."
[[ -f "${APK}" ]] || fail "APK not found: ${APK} (was the build step skipped?)"
adb -s "${DEVICE}" shell am force-stop "${PKG}" || true
adb -s "${DEVICE}" uninstall "${PKG}" >/dev/null 2>&1 || true
adb -s "${DEVICE}" install -r "${APK}"

# ---------------------------------------------------------------------------
# Phase 2 — runtime permissions, best-effort by design.
#
# This lane injects `FakeLocationService` for Alice's own position (the
# RECEIVE path is the subject), so no real GPS and no verified location grant
# is needed — unlike B3/B6, where the grant is a gate. POST_NOTIFICATIONS is
# granted so the foreground-service notification channel never blocks
# startup; the location grants are requested only so the app's own startup
# path takes its ordinary branch rather than a permission-denied one.
# ---------------------------------------------------------------------------
echo "Phase 2/6 — granting runtime permissions (best-effort)..."
for perm in \
  android.permission.ACCESS_FINE_LOCATION \
  android.permission.ACCESS_COARSE_LOCATION \
  android.permission.POST_NOTIFICATIONS
do
  adb -s "${DEVICE}" shell pm grant "${PKG}" "${perm}" 2>&1 | sed 's/^/    /' \
    || true
done

# ---------------------------------------------------------------------------
# Phase 3 — connectivity precondition: airplane mode OFF, verified.
#
# Checked BEFORE the drive rather than discovered at the toggle: a device
# whose airplane mode cannot be driven from the shell cannot run this lane at
# all, and finding that out 6 minutes into a drive wastes the whole run.
# ---------------------------------------------------------------------------
echo "Phase 3/6 — verifying the guest starts with connectivity..."
: > "${NET_LOG}"
if ! set_airplane 0; then
  fail "could not put the guest into a known-connected state:" \
       "\`settings get global airplane_mode_on\` did not read 0 after" \
       "\`cmd connectivity airplane-mode disable\`. This lane's whole" \
       "mechanism is that toggle, so it cannot run on this device."
fi

# ---------------------------------------------------------------------------
# Phase 4 — drive the target IN THE BACKGROUND and cut the network under it.
#
# The drive must be backgrounded because the outage happens MID-session: the
# subject is one continuous session that loses its relay connection and has
# to get it back, which a sequence of separate drives cannot express (each
# would start a fresh process, connect once, and never experience a drop at
# all).
#
# No `--keep-app-running`: nothing has to outlive the drive, and letting
# `flutter drive` stop the app afterwards keeps this lane from leaving a live
# MLS session behind for the next job on the runner (Rule 14).
# ---------------------------------------------------------------------------
echo "Phase 4/6 — capturing logcat and driving ${TARGET}..."
adb -s "${DEVICE}" logcat -c || true
adb -s "${DEVICE}" logcat -v threadtime > "${LOGCAT_FILE}" 2>&1 &
LOGCAT_PID=$!

: > "${DRIVE_LOG}"
(
  cd "${HAVEN_DIR}" && timeout --kill-after=30s "${DRIVE_TIMEOUT}" flutter drive \
    --no-pub \
    --device-id "${DEVICE}" \
    --use-application-binary "${APK}" \
    --driver "${DRIVER_FILE}" \
    --target "${TARGET}"
) > "${DRIVE_LOG}" 2>&1 &
DRIVE_PID=$!

# --- Toggle sequence. Each stage is DEFERRED on failure rather than fatal:
# the oracle's findings are this lane's deliverable and stay readable as long
# as the capture is complete, so we always drain the drive and always restore
# connectivity before reporting.
toggle_failed=0
toggle_reason=""

echo "Phase 4/6 — waiting for the drive to arm (${MARK_AWAIT_DOWN})..."
if wait_for_marker "${MARK_AWAIT_DOWN}" "${ARM_MARKER_TIMEOUT}"; then
  echo "Phase 4/6 — dropping the network (L1 airplane mode + L2 port REJECT)..."
  host_block_install
  if ! set_airplane 1; then
    toggle_failed=1
    toggle_reason="\`cmd connectivity airplane-mode enable\` did not take \
(settings still read $(airplane_state)); the drop degraded to the host-side \
port REJECT alone, so any outage the drive observed was relay \
unreachability, NOT device-wide network loss"
    echo "WARN: ${toggle_reason}" >&2
  fi

  echo "Phase 4/6 — waiting for the outage window to complete" \
       "(${MARK_AWAIT_UP})..."
  if wait_for_marker "${MARK_AWAIT_UP}" "${OUTAGE_MARKER_TIMEOUT}"; then
    echo "Phase 4/6 — restoring the network..."
  else
    toggle_failed=1
    toggle_reason="the drive never reached ${MARK_AWAIT_UP}"
  fi
  # Restore unconditionally: the drive's recovery phase must be able to run
  # and record evidence, and the runner must not be left disconnected.
  host_block_remove
  if ! set_airplane 0; then
    toggle_failed=1
    toggle_reason="airplane mode could not be turned back off"
  fi
else
  toggle_failed=1
  toggle_reason="the drive never reached ${MARK_AWAIT_DOWN}"
fi

echo "Phase 5/6 — draining the drive..."
drc=0
wait "${DRIVE_PID}" || drc=$?
DRIVE_PID=""

# Scan BEFORE echoing. The EXIT trap's scan runs far too late to protect the
# STEP log, which has no retention control and cannot be redacted after the
# fact — a wider, more permanent sink than the artifact upload.
drive_log_clean=1
if bash "${SECRET_SCAN}" "${DRIVE_LOG}"; then
  cat "${DRIVE_LOG}" || true
else
  drive_log_clean=0
  echo "drive log withheld from the step log — secret-leak guard tripped." >&2
fi

# Record the drive's verdict WITHOUT exiting on it yet: the oracle below reads
# the capture, and its findings are the point of this lane. `drc == 0` alone
# is not trustworthy — `flutter drive` exits 0 when the failure happened
# outside a `testWidgets` body, and when nothing ran (drive-log-lib.sh).
drive_failed=0
drive_reason=""
if (( drc != 0 )); then
  drive_failed=1
  drive_reason="flutter drive exited ${drc}"
elif drive_log_reports_test_failure "${DRIVE_LOG}"; then
  drive_failed=1
  drive_reason="flutter drive exited 0 but the on-device suite reported failures"
fi
if (( drive_failed == 1 )); then
  echo "WARN: ${drive_reason} for ${TARGET}. Continuing to the oracle anyway —" \
       "its findings are this lane's deliverable. This is re-raised as a" \
       "failure at the end regardless of the oracle's verdict." >&2
  if (( drive_log_clean == 1 )); then
    drive_log_failure_evidence "${DRIVE_LOG}" >&2
  else
    echo "  (evidence withheld — secret-leak guard tripped on this log)" >&2
  fi
fi

# ---------------------------------------------------------------------------
# Phase 6 — the oracle. Reads over a complete capture; no live polling.
# ---------------------------------------------------------------------------
echo "Phase 6/6 — asserting the network-loss/reconnect sequence..."
oracle_rc=0
b9_run_oracle "${LOGCAT_FILE}" || oracle_rc=$?

if (( oracle_rc != 0 )); then
  echo "---- network toggle log ----" >&2
  cat "${NET_LOG}" >&2 2>/dev/null || true
  {
    echo "B9 findings (${#B9_FINDINGS[@]}):"
    for finding in "${B9_FINDINGS[@]}"; do
      echo "  * ${finding}"
    done
  } >&2
  fail "the network-loss/reconnect sequence did not hold — see the" \
       "${#B9_FINDINGS[@]} finding(s) above."
fi

if (( toggle_failed == 1 )); then
  fail "the oracle passed, but the harness network sequence did not:" \
       "${toggle_reason}. Treat the lane as RED — a sequence that did not" \
       "produce the outage it claims cannot have measured what the oracle" \
       "just blessed."
fi

if (( drive_failed == 1 )); then
  fail "the oracle passed, but ${drive_reason}. Treat the lane as RED —" \
       "a drive that dies early can truncate the very capture the oracle" \
       "measures."
fi

echo "B9 PASS — live receive was up, the app lost the network device-wide," \
     "and a PEER location published after connectivity returned was" \
     "decrypted and surfaced."
