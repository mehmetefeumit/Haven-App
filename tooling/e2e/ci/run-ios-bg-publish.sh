#!/usr/bin/env bash
#
# iOS background-publish lane — a REAL OS-level background transition.
#
# Runs ONE drive target (haven/integration_test/ios_bg_publish_test.dart) on a
# booted simulator and, MID-DRIVE, backgrounds the app for real by launching
# another app (com.apple.Preferences) over it — so iOS itself fires
# `applicationDidEnterBackground` and the Flutter engine dispatches the paused
# lifecycle state through the same channel a production backgrounding uses.
# No other lane does this: B7 and the Android B1 lane dispatch the lifecycle
# event IN-PROCESS, which runs the app's own paused branch but never the OS's
# side of the transition or the native session handler's survival across it.
#
# # What the drive proves (each phase leaves a terminal proof marker)
#
#   P1  After enabling background sharing through the production
#       `BackgroundSharingNotifier.setEnabled` path, the native
#       `HavenBackgroundSessionHandler` reports supported==true and
#       backgroundActivitySessionHeld==true (iOS 17+ runtime).
#   P2  With the app OS-backgrounded, kind-445 publishes CONTINUE to reach
#       the relay: >= 2 events created after the backgrounding instant,
#       observed over a window sized to two full 72-168 s jitter intervals.
#   P3  Flipping background sharing OFF while STILL backgrounded stops
#       publishing (an event-id DIFF over a bounded settle window — never a
#       bare count) and the native session reports disarmed.
#
# # The host<->test handshake
#
#   1. The drive prints `[bg-publish] READY_FOR_BACKGROUND` once P1 passed.
#   2. This script tails the shared runner's log for that marker in a bounded
#      loop, then backgrounds the app:
#          xcrun simctl terminate <udid> com.apple.Preferences || true
#          xcrun simctl launch    <udid> com.apple.Preferences
#      The drive keeps running — the simulator never suspends a backgrounded
#      app (documented in .github/workflows/e2e-ios.yml), so `flutter test`'s
#      VM-service connection survives the transition.
#   3. The drive bounded-polls its own lifecycle state for the REAL paused
#      transition; its failure message names this script's background step,
#      so a broken handshake is attributed from both sides.
#   4. After the drive's LAST marker (`[bg-publish] SESSION_DISARMED`) this
#      script re-foregrounds Haven (`simctl launch` on the running bundle
#      activates it) so flutter_test's post-suite teardown gets real engine
#      frames again — an in-process resumed dispatch cannot restart the
#      native animator iOS paused on the way out.
#
# # The completion gate (A3b)
#
# `flutter test` reports success over a body that was skipped or returned
# early, and the READY marker is printed BEFORE P2/P3 run — so a drive that
# exited 0 is not a drive that proved anything. This script therefore
# requires ALL FOUR terminal proofs in the preserved log, each printed only
# after the last assertion of its own phase:
#
#   [bg-publish] SESSION_ARMED
#   [bg-publish] BACKGROUND_PUBLISH_OK …   (prefix match; ` count=<n>` suffix)
#   [bg-publish] NEGATIVE_SILENCE_OK
#   [bg-publish] SESSION_DISARMED
#
# # Scope boundary (stated so nobody over-reads a green)
#
# The simulator does NOT reproduce real-device background SUSPENSION: the
# process stays alive and the VM-service stays attached, so jetsam, true
# suspension and SLC/BGTask behaviour cannot surface here. This lane proves
# plist/plugin-flag/native-session-arming/Dart-pipeline continuity under a
# genuinely fired UIApplication background transition — NOT the OS's
# suspension heuristics. The physical-device checklist
# (docs/M7_BACKGROUND_SHARING.md §6, item 0) remains the final proof.
#
# # Why the app is installed and granted BEFORE the drive
#
# Same reasoning as run-b4-ios-real-gps.sh: a `simctl privacy` grant resolves
# the bundle id against INSTALLED apps and does not survive `simctl
# uninstall`, which the shared runner performs on entry. So this script
# builds once, uninstalls, installs, grants When-In-Use (`location` — this
# lane proves the production When-In-Use path; Always is B7's axis), seeds a
# `simctl location` fix, and asks the shared runner to skip its own uninstall
# via HAVEN_E2E_IOS_SKIP_UNINSTALL=1. The drive fakes its location SOURCE
# (B7 precedent — GPS acquisition is the B4 lane's subject), so the grant and
# the fix are CoreLocation hygiene: no prompt can wedge the run and locationd
# holds a real fix while the armed CLBackgroundActivitySession is live. No
# `simctl location start` route is needed for the same reason.
#
# Everything else — the first-test watchdog, the narrowed retry gate, the
# secret-leak scan — is inherited by delegating the drive to
# `run-ios-sim-scenario.sh` rather than reimplementing `flutter test` here.
#
# Usage:
#   run-ios-bg-publish.sh <simulator-udid>
#   run-ios-bg-publish.sh --self-test     # hermetic; no simulator, no Xcode
#
# Environment:
#   HAVEN_E2E_RELAY   WebSocket URL of the host relay (default
#                     ws://localhost:7777).
#   HAVEN_LIVE_SYNC   'true' or 'false'. MANDATORY — declared per STEP by the
#                     caller, exactly as run-ios-sim-scenario.sh requires
#                     (S1 / CI_HARDENING_BACKLOG.md A7).
#
# Side effects:
#   - Writes /tmp/bg-publish-ios.log (uploaded as a CI failure artifact).
#   - Leaves the app UNINSTALLED from the simulator on completion.
#
# Exit status:
#   0  the session armed, publishes continued across a real backgrounding,
#      and the disable stopped both — all four proofs present
#   1  the drive failed, or it exited 0 without printing all four proofs
#   2  usage / harness misconfiguration (including: this Xcode cannot grant
#      location privacy or seed a simulated location)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# The drive target, relative to haven/ (the shared runner resolves it there).
readonly SCENARIO_FILE="integration_test/ios_bg_publish_test.dart"

# Must match `haven/ios/Runner.xcodeproj`'s PRODUCT_BUNDLE_IDENTIFIER and the
# id run-ios-sim-scenario.sh uninstalls.
readonly BUNDLE_ID="com.oblivioustech.haven"

# The app launched OVER Haven to force the real background transition.
# Preferences ships on every simulator runtime, so launching it can never
# fail for a missing bundle.
readonly OVERLAY_BUNDLE_ID="com.apple.Preferences"

# Markers the drive target prints. Duplicated here (and ONLY here) because
# the Dart consts are not readable from bash; the drive target's doc comment
# names this file as the other half of the contract, and the --self-test
# below feeds the real parser fixtures built from these literals, so a drift
# shows up as a failing self-test rather than as a silently unparseable log.
#
# READY_MARKER feeds the HANDSHAKE only and is printed before P2/P3 run, so
# it can never stand in for a completion proof. The other four are the
# terminal proofs: each is printed only after the last assertion of its own
# phase. PUBLISH_MARKER is matched as a PREFIX (the drive appends
# ` count=<n>`).
readonly READY_MARKER='[bg-publish] READY_FOR_BACKGROUND'
readonly ARMED_MARKER='[bg-publish] SESSION_ARMED'
readonly PUBLISH_MARKER='[bg-publish] BACKGROUND_PUBLISH_OK'
readonly SILENCE_MARKER='[bg-publish] NEGATIVE_SILENCE_OK'
readonly DISARMED_MARKER='[bg-publish] SESSION_DISARMED'

# The shared runner's fixed log path (run-ios-sim-scenario.sh's LOG_FILE).
# This script tails it for the handshake, so the coupling is deliberate and
# named here.
readonly SHARED_LOG="/tmp/flutter-ios-test.log"

# Where the run's log is preserved for the artifact upload.
readonly BG_LOG="/tmp/bg-publish-ios.log"

# Handshake bounds. READY must appear after the delegated `flutter test`'s
# incremental build (~2-4 min; the cold build happens in THIS script, before
# the drive) plus install/launch/attach plus the in-test setup and P1 —
# ~10 min worst case measured against B7's phases, so 20 min is ~2x. The
# DISARMED wait starts after the backgrounding and must cover P2 (396 s) +
# P3 (~5.5 min) + slack — 25 min is ~2x. Both loops also exit the moment the
# drive process itself exits, so neither can outlive a failed drive.
readonly READY_WAIT_SECS="${HAVEN_BGP_READY_WAIT_SECS:-1200}"
readonly DISARM_WAIT_SECS="${HAVEN_BGP_DISARM_WAIT_SECS:-1500}"
readonly MARKER_POLL_SECS="${HAVEN_BGP_MARKER_POLL_SECS:-5}"
if ! [[ "${READY_WAIT_SECS}" =~ ^[1-9][0-9]*$ ]] \
   || ! [[ "${DISARM_WAIT_SECS}" =~ ^[1-9][0-9]*$ ]] \
   || ! [[ "${MARKER_POLL_SECS}" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: HAVEN_BGP_*_SECS overrides must be positive integers." >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Pure helpers (exercised by --self-test)
# ---------------------------------------------------------------------------

# bgp_simctl_supports_location_privacy <usage-text> — does this Xcode's
# `simctl privacy` offer the `location` service?
#
# Returns 0 (supported), 1 (parsed, and it is NOT offered), or 2 (the usage
# text does not look like a service list at all — do not guess either way).
# Deliberately no `\b`: macOS BSD grep does not implement the GNU
# word-boundary escape, so a `\b` pattern would silently never match and
# every real run would report "unparseable" on a perfectly good Xcode.
bgp_simctl_supports_location_privacy() {
  local usage="$1"
  if ! grep -qE '(^|[^A-Za-z-])(grant|revoke)([^A-Za-z-]|$)' <<<"${usage}"; then
    return 2
  fi
  grep -qE '(^|[^A-Za-z-])location([^A-Za-z-]|$)' <<<"${usage}"
}

# bgp_simctl_supports_location_set <usage-text> — does this Xcode's
# `simctl location` offer the `set` action? Same tri-state contract; the
# structural gate needs BOTH `location` and `action` because an Xcode with no
# `location` subcommand answers an error string containing the word
# `location` (see run-b4-ios-real-gps.sh, where this parser originates).
bgp_simctl_supports_location_set() {
  local usage="$1"
  grep -qE '(^|[^A-Za-z-])location([^A-Za-z-]|$)' <<<"${usage}" || return 2
  grep -qE '(^|[^A-Za-z-])action([^A-Za-z-]|$)' <<<"${usage}" || return 2
  grep -qE '(^|[^A-Za-z-])set([^A-Za-z-]|$)' <<<"${usage}"
}

# bgp_marker_present <log> <marker> — is the literal marker in the log?
#
# `grep -aF` (literal, binary-safe): the markers contain `[bg-publish]`,
# which is a valid character class, so any regex form of this check would
# match a lone `b` or `g` and pass vacuously. A missing or empty log reports
# absent — absence of evidence is never evidence.
bgp_marker_present() {
  local log="${1:-}" marker="$2"
  [[ -s "${log}" ]] || return 1
  LC_ALL=C grep -aqF -- "${marker}" "${log}"
}

# bgp_missing_proofs <log> — prints the terminal proof markers this log does
# NOT carry, one per line. Empty output means the drive reached the end of
# every phase. A missing or empty log reports all four as absent.
#
# Always returns 0; the ANSWER is the output, so a caller in a `$( … )` under
# `set -e` is never killed by "no markers were missing".
bgp_missing_proofs() {
  local log="${1:-}" marker
  for marker in "${ARMED_MARKER}" "${PUBLISH_MARKER}" \
                "${SILENCE_MARKER}" "${DISARMED_MARKER}"; do
    bgp_marker_present "${log}" "${marker}" || printf '%s\n' "${marker}"
  done
  return 0
}

# bgp_wait_for_marker <log> <marker> <pid> <deadline-secs> <poll-secs> —
# bounded wait for a marker to appear in a log a live process is writing.
#
# Returns:
#   0  the marker appeared
#   2  the process exited first (the marker is still absent — a marker
#      printed on the way out is re-checked before this verdict)
#   3  the deadline elapsed with the process still running
#
# A not-yet-created log is tolerated (the delegated runner truncates it only
# once the drive starts): it simply reads as "marker absent".
bgp_wait_for_marker() {
  local log="$1" marker="$2" pid="$3" deadline="$4" poll="$5" waited=0
  while :; do
    if bgp_marker_present "${log}" "${marker}"; then return 0; fi
    if ! kill -0 "${pid}" 2>/dev/null; then
      # The process may have printed the marker in its final write.
      if bgp_marker_present "${log}" "${marker}"; then return 0; fi
      return 2
    fi
    if (( waited >= deadline )); then return 3; fi
    sleep "${poll}"
    waited=$(( waited + poll ))
  done
}

# ---------------------------------------------------------------------------
# --self-test — hermetic. Fixtures are the ways this lane can go vacuously
# green or wedge unbounded, because those are the failures nothing else would
# catch.
# ---------------------------------------------------------------------------
run_self_test() {
  local tmp fail=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  _check() { # _check <label> <want> <got>
    if [[ "$2" == "$3" ]]; then
      printf '  \033[1;32mPASS\033[0m %s\n' "$1"
    else
      printf '  \033[1;31mFAIL\033[0m %s (want %s, got %s)\n' "$1" "$2" "$3" >&2
      fail=1
    fi
  }

  # --- (P1) An Xcode whose `simctl privacy` offers the location service.
  local rc=0
  bgp_simctl_supports_location_privacy \
'Usage: simctl privacy <device> <action> <service> [<bundle identifier>]
   action: grant, revoke, reset
   service: all, calendar, contacts, location, location-always, photos' \
    || rc=$?
  _check "P1 privacy usage listing location is supported" 0 "${rc}"

  # --- (P2) A privacy service list WITHOUT location must be refused.
  rc=0
  bgp_simctl_supports_location_privacy \
'Usage: simctl privacy <device> <action> <service>
   action: grant, revoke
   service: calendar, contacts, photos, microphone' \
    || rc=$?
  _check "P2 privacy usage without location is REFUSED" 1 "${rc}"

  # --- (P3) Unparseable usage must be distinguishable from "unsupported".
  rc=0
  bgp_simctl_supports_location_privacy \
    'xcrun: error: unable to find utility "simctl"' || rc=$?
  _check "P3 unparseable privacy usage reports misconfiguration" 2 "${rc}"

  # --- (L1) `simctl location` offering the `set` action.
  rc=0
  bgp_simctl_supports_location_set \
'Set or clear simulated location.
Usage: simctl location <device> <action> [<arguments>]
   action: clear, set, start, stop, list' \
    || rc=$?
  _check "L1 location usage listing set is supported" 0 "${rc}"

  # --- (L2) A `location` listing without `set` is refused, not misread.
  rc=0
  bgp_simctl_supports_location_set \
'Usage: simctl location <device> <action>
   action: clear, list' \
    || rc=$?
  _check "L2 location usage without set is REFUSED" 1 "${rc}"

  # --- (L3) The no-location-subcommand error string mentions the word
  #     `location` but enumerates no actions; it must report unparseable,
  #     never "your Xcode lacks set".
  rc=0
  bgp_simctl_supports_location_set \
    'Unknown subcommand "location". Usage: simctl <subcommand>' || rc=$?
  _check "L3 a no-location-subcommand error reports misconfiguration" 2 "${rc}"

  # --- (M1) The marker parser accepts the PUBLISH prefix with its real
  #     ` count=<n>` suffix — a whole-line match would find nothing on every
  #     real run.
  local log="${tmp}/m1.log"
  printf '%s count=2\n' "${PUBLISH_MARKER}" > "${log}"
  rc=0; bgp_marker_present "${log}" "${PUBLISH_MARKER}" || rc=$?
  _check "M1 the trailing ' count=<n>' does not defeat the match" 0 "${rc}"

  # --- (M2) An absent marker is absent.
  printf 'Some tests failed.\n' > "${log}"
  rc=0; bgp_marker_present "${log}" "${ARMED_MARKER}" || rc=$?
  _check "M2 a markerless log reports absent" 1 "${rc}"

  # --- (M3) A MISSING log is absence of evidence, never evidence.
  rc=0; bgp_marker_present "${tmp}/nope.log" "${ARMED_MARKER}" || rc=$?
  _check "M3 a missing log reports absent" 1 "${rc}"

  # A tiny writer, so each completion fixture states exactly which proofs
  # its log carries.
  _bgp_log() { # _bgp_log <path> [marker ...]
    local path="$1"; shift
    {
      echo 'Xcode build done.                                           400.0s'
      echo "${READY_MARKER}"
      local m
      for m in "$@"; do echo "${m}"; done
      echo '🎉 1 test passed.'
    } > "${path}"
  }

  # --- (C1) THE PASSING SHAPE: all four proofs present.
  local clog="${tmp}/c.log" got
  _bgp_log "${clog}" "${ARMED_MARKER}" "${PUBLISH_MARKER} count=2" \
    "${SILENCE_MARKER}" "${DISARMED_MARKER}"
  got="$(bgp_missing_proofs "${clog}")"
  _check "C1 all four proofs is COMPLETE" "" "${got}"

  # --- (C2..C5) Each proof individually missing must be named. The READY
  #     marker is present in every fixture, which is the A3b point: it is
  #     printed before P2/P3 run, so it must never satisfy the gate.
  _bgp_log "${clog}" "${PUBLISH_MARKER} count=2" "${SILENCE_MARKER}" \
    "${DISARMED_MARKER}"
  got="$(bgp_missing_proofs "${clog}")"
  _check "C2 a missing SESSION_ARMED is REFUSED" "${ARMED_MARKER}" "${got}"

  _bgp_log "${clog}" "${ARMED_MARKER}" "${SILENCE_MARKER}" "${DISARMED_MARKER}"
  got="$(bgp_missing_proofs "${clog}")"
  _check "C3 a missing BACKGROUND_PUBLISH_OK is REFUSED" \
    "${PUBLISH_MARKER}" "${got}"

  _bgp_log "${clog}" "${ARMED_MARKER}" "${PUBLISH_MARKER} count=2" \
    "${DISARMED_MARKER}"
  got="$(bgp_missing_proofs "${clog}")"
  _check "C4 a missing NEGATIVE_SILENCE_OK is REFUSED" \
    "${SILENCE_MARKER}" "${got}"

  _bgp_log "${clog}" "${ARMED_MARKER}" "${PUBLISH_MARKER} count=2" \
    "${SILENCE_MARKER}"
  got="$(bgp_missing_proofs "${clog}")"
  _check "C5 a missing SESSION_DISARMED is REFUSED" \
    "${DISARMED_MARKER}" "${got}"

  # --- (C6) An absent or empty log reports all four proofs missing — the
  #     `cp` that preserves the run is `|| true`d by design, so "no log" is a
  #     reachable state and must fail closed.
  got="$(bgp_missing_proofs "${tmp}/absent.log" | tr '\n' ';')"
  _check "C6 a MISSING log reports all four proofs absent" \
    "${ARMED_MARKER};${PUBLISH_MARKER};${SILENCE_MARKER};${DISARMED_MARKER};" \
    "${got}"
  : > "${tmp}/empty.log"
  got="$(bgp_missing_proofs "${tmp}/empty.log" | tr '\n' ';')"
  _check "C6b an EMPTY log reports all four proofs absent" \
    "${ARMED_MARKER};${PUBLISH_MARKER};${SILENCE_MARKER};${DISARMED_MARKER};" \
    "${got}"

  # --- (W1) A marker already present returns immediately.
  local wlog="${tmp}/w.log"
  printf '%s\n' "${READY_MARKER}" > "${wlog}"
  ( sleep 30 ) & local wpid=$!
  rc=0; bgp_wait_for_marker "${wlog}" "${READY_MARKER}" "${wpid}" 10 1 || rc=$?
  kill "${wpid}" 2>/dev/null || true; wait "${wpid}" 2>/dev/null || true
  _check "W1 an already-present marker returns 0" 0 "${rc}"

  # --- (W2) A marker that appears mid-wait is found. The writer delays 1 s
  #     against a 10 s deadline — a 10x margin, so a loaded runner cannot
  #     flake this.
  : > "${wlog}"
  ( sleep 1; printf '%s\n' "${READY_MARKER}" >> "${wlog}"; sleep 30 ) &
  wpid=$!
  rc=0; bgp_wait_for_marker "${wlog}" "${READY_MARKER}" "${wpid}" 10 1 || rc=$?
  kill "${wpid}" 2>/dev/null || true; wait "${wpid}" 2>/dev/null || true
  _check "W2 a marker appearing mid-wait returns 0" 0 "${rc}"

  # --- (W3) A process that exits WITHOUT the marker reports 2, not a hang
  #     and not a deadline — the caller must distinguish "the drive died"
  #     from "the drive is slow".
  : > "${wlog}"
  ( exit 0 ) & wpid=$!
  wait "${wpid}" 2>/dev/null || true
  rc=0; bgp_wait_for_marker "${wlog}" "${READY_MARKER}" "${wpid}" 10 1 || rc=$?
  _check "W3 a dead process without the marker returns 2" 2 "${rc}"

  # --- (W3b) A process that prints the marker AS ITS LAST ACT and exits is
  #     still a found marker: the death re-check exists so a fast drive
  #     cannot be misread as a failed one.
  printf '%s\n' "${READY_MARKER}" > "${wlog}"
  ( exit 0 ) & wpid=$!
  wait "${wpid}" 2>/dev/null || true
  rc=0; bgp_wait_for_marker "${wlog}" "${READY_MARKER}" "${wpid}" 10 1 || rc=$?
  _check "W3b a marker printed just before exit returns 0" 0 "${rc}"

  # --- (W4) A live, silent process runs into the DEADLINE (3): the loop is
  #     provably bounded, so a lost handshake can never hang the lane.
  : > "${wlog}"
  ( sleep 30 ) & wpid=$!
  rc=0; bgp_wait_for_marker "${wlog}" "${READY_MARKER}" "${wpid}" 2 1 || rc=$?
  kill "${wpid}" 2>/dev/null || true; wait "${wpid}" 2>/dev/null || true
  _check "W4 a silent live process hits the deadline (3)" 3 "${rc}"

  # --- (H1) STRUCTURAL: the real run must background the app by launching
  #     the overlay bundle. Every gate above reads a LOG, so none can see a
  #     lane whose background step was deleted — the drive would then fail
  #     its paused-wait, but the failure would blame the handshake instead
  #     of naming the missing step. Asserted over the function's own source
  #     with comment lines stripped, so prose ABOUT the launch cannot
  #     satisfy it.
  local body
  body="$(sed -n '/^bgp_background_app() {/,/^}/p' "${BASH_SOURCE[0]}" \
            | grep -v '^[[:space:]]*#')"
  rc=0
  grep -qF 'simctl launch "${SIM_UDID}" "${OVERLAY_BUNDLE_ID}"' <<<"${body}" \
    || rc=1
  _check "H1 the background step launches the overlay app" 0 "${rc}"

  # --- (H2) The privacy grant is fail-closed. `|| true` on it would be this
  #     repo's recurring "guard passes vacuously" failure: an ungranted app
  #     stalls on an unanswerable CoreLocation prompt.
  body="$(sed -n '/^# --- Prepare the simulator/,/^# --- Drive/p' \
            "${BASH_SOURCE[0]}" | grep -v '^[[:space:]]*#')"
  rc=0
  grep -qF 'if ! xcrun simctl privacy "${SIM_UDID}" grant location "${BUNDLE_ID}"' \
    <<<"${body}" || rc=1
  _check "H2 the privacy grant is fail-closed" 0 "${rc}"

  # --- (H3) The delegate must be told to skip its own uninstall, or the
  #     grant made above is erased before first launch and the drive stalls
  #     exactly as if H2 had been violated.
  body="$(sed -n '/^# --- Drive/,/^DRIVE_PID=/p' "${BASH_SOURCE[0]}" \
            | grep -v '^[[:space:]]*#')"
  rc=0
  grep -qF 'HAVEN_E2E_IOS_SKIP_UNINSTALL=1' <<<"${body}" || rc=1
  _check "H3 the delegate skips its own uninstall" 0 "${rc}"

  if (( fail != 0 )); then
    echo "run-ios-bg-publish.sh --self-test: FAILED" >&2
    return 1
  fi
  echo "run-ios-bg-publish.sh --self-test: all 24 fixtures passed (the" \
       "simctl probes report supported/unsupported/unparseable distinctly;" \
       "the marker parser is literal, prefix-tolerant and fails closed on" \
       "missing logs; the completion gate demands all four terminal proofs" \
       "and never accepts READY in their place; the marker wait is bounded" \
       "and distinguishes a dead drive from a slow one; and the background" \
       "step, the fail-closed grant and the uninstall skip are structurally" \
       "pinned)."
  return 0
}

if [[ "${1:-}" == "--self-test" ]]; then
  run_self_test
  exit $?
fi

# ---------------------------------------------------------------------------
# Real run
# ---------------------------------------------------------------------------

SIM_UDID="${1:-}"
if [[ -z "${SIM_UDID}" || $# -gt 1 ]]; then
  echo "ERROR: usage: $0 <simulator-udid>  |  $0 --self-test" >&2
  exit 2
fi

readonly RELAY_URL="${HAVEN_E2E_RELAY:-ws://localhost:7777}"

# Same mandatory, no-default contract run-ios-sim-scenario.sh enforces: the
# receive path is compiled into the artifact, so the calling STEP has to
# state it rather than inherit one (CI_HARDENING_BACKLOG.md A7).
if [[ -z "${HAVEN_LIVE_SYNC:-}" ]]; then
  echo "ERROR: HAVEN_LIVE_SYNC is not set. This script compiles the app, so" >&2
  echo "       the calling step must state 'true' or 'false' in its env." >&2
  exit 2
fi
if [[ ! "${HAVEN_LIVE_SYNC}" =~ ^(true|false)$ ]]; then
  echo "ERROR: HAVEN_LIVE_SYNC must be exactly 'true' or 'false' (got '${HAVEN_LIVE_SYNC}')." >&2
  exit 2
fi
readonly LIVE_SYNC="${HAVEN_LIVE_SYNC}"

readonly REPO_ROOT="${SCRIPT_DIR}/../../.."
readonly HAVEN_DIR="${REPO_ROOT}/haven"
readonly SIM_RUNNER="${SCRIPT_DIR}/run-ios-sim-scenario.sh"

[[ -f "${HAVEN_DIR}/${SCENARIO_FILE}" ]] \
  || { echo "ERROR: drive target not found: ${HAVEN_DIR}/${SCENARIO_FILE}" >&2; exit 2; }
[[ -f "${SIM_RUNNER}" ]] \
  || { echo "ERROR: shared runner not found: ${SIM_RUNNER}" >&2; exit 2; }

echo "iOS bg-publish lane — udid=${SIM_UDID} relay=${RELAY_URL} live_sync=${LIVE_SYNC}"

# --- Preflight: can THIS Xcode grant location privacy and seed a fix? -------
PRIVACY_USAGE="$(xcrun simctl help privacy 2>&1 || true)"
set +e
bgp_simctl_supports_location_privacy "${PRIVACY_USAGE}"
PRIV_RC=$?
set -e
case "${PRIV_RC}" in
  0)
    echo "bg-publish preflight — 'xcrun simctl privacy' offers the location service."
    ;;
  1)
    echo "ERROR: this runner's 'xcrun simctl privacy' does NOT list the" >&2
    echo "       'location' service, so When-In-Use authorization cannot be" >&2
    echo "       granted and the app would sit on an unanswerable system" >&2
    echo "       prompt. Raise the runner image / Xcode version." >&2
    printf '%s\n' "${PRIVACY_USAGE}" | sed 's/^/       /' >&2
    exit 2
    ;;
  *)
    echo "ERROR: could not parse 'xcrun simctl help privacy' output — the" >&2
    echo "       preflight cannot tell 'unsupported' from 'the probe is" >&2
    echo "       broken', and guessing either way is worse than stopping." >&2
    printf '%s\n' "${PRIVACY_USAGE}" | sed 's/^/       /' >&2
    exit 2
    ;;
esac

LOCATION_USAGE="$(xcrun simctl help location 2>&1 || true)"
set +e
bgp_simctl_supports_location_set "${LOCATION_USAGE}"
LOC_RC=$?
set -e
case "${LOC_RC}" in
  0)
    echo "bg-publish preflight — 'xcrun simctl location' offers the 'set' action."
    ;;
  1)
    echo "ERROR: this runner's 'xcrun simctl location' does NOT offer a 'set'" >&2
    echo "       action, so locationd cannot be given a fix while the armed" >&2
    echo "       background session is live. 'simctl location ... set' has" >&2
    echo "       shipped since Xcode 14; raise the runner image / Xcode." >&2
    printf '%s\n' "${LOCATION_USAGE}" | sed 's/^/       /' >&2
    exit 2
    ;;
  *)
    echo "ERROR: could not parse 'xcrun simctl help location' output." >&2
    printf '%s\n' "${LOCATION_USAGE}" | sed 's/^/       /' >&2
    exit 2
    ;;
esac

cd "${HAVEN_DIR}"

# --- Build ONCE. -------------------------------------------------------------
# The .app must exist BEFORE the grant, because `simctl privacy grant`
# resolves the bundle id against the simulator's installed apps. The
# delegated `flutter test` below rebuilds incrementally from the same derived
# data, so this costs one cold Xcode+Rust build for the lane rather than two.
#
# The build is deliberately NOT bounded here: a hung or failed build is
# deterministic, and the caller's retry timeout is the backstop (the same
# stance run-ios-sim-scenario.sh's first-test watchdog takes when it declines
# to watch the build).
echo "bg-publish — building the drive target once for the simulator ..."
flutter build ios \
  --simulator \
  --debug \
  --target "${SCENARIO_FILE}" \
  --dart-define=HAVEN_E2E_RELAY="${RELAY_URL}" \
  --dart-define=HAVEN_LIVE_SYNC="${LIVE_SYNC}"

APP_PATH=""
for candidate in build/ios/iphonesimulator/*.app; do
  [[ -d "${candidate}" ]] || continue
  if [[ -n "${APP_PATH}" ]]; then
    echo "ERROR: more than one .app under build/ios/iphonesimulator — refusing" >&2
    echo "       to guess which one to install." >&2
    exit 2
  fi
  APP_PATH="${candidate}"
done
[[ -n "${APP_PATH}" ]] \
  || { echo "ERROR: no .app produced under build/ios/iphonesimulator." >&2; exit 2; }
readonly APP_PATH
echo "bg-publish — built ${APP_PATH}"

# --- Prepare the simulator: uninstall -> install -> grant -> seed. -----------
# The uninstall is the hermetic wipe run-ios-sim-scenario.sh normally performs
# (a stale, differently-keyed haven_mdk.db in the data container fails every
# scenario deterministically); doing it HERE, before the grant, is what lets
# the grant survive to first launch.
xcrun simctl uninstall "${SIM_UDID}" "${BUNDLE_ID}" >/dev/null 2>&1 || true

if ! xcrun simctl install "${SIM_UDID}" "${APP_PATH}"; then
  echo "ERROR: could not install ${APP_PATH} on ${SIM_UDID}." >&2
  exit 2
fi

# When-In-Use, deliberately NOT location-always: this lane proves the
# production When-In-Use background-continuation path (the tier most users
# hold); the Always axis is B7's lane. A refused grant must be FATAL —
# `|| true` here would be another instance of the repo's recurring "guard
# passes vacuously" failure, presenting at runtime as an app hanging on a
# system prompt nobody can answer.
if ! xcrun simctl privacy "${SIM_UDID}" grant location "${BUNDLE_ID}"; then
  echo "ERROR: 'xcrun simctl privacy ${SIM_UDID} grant location ${BUNDLE_ID}'" >&2
  echo "       failed. Authorization was never granted; the likeliest cause" >&2
  echo "       is the install above not having landed — the grant resolves" >&2
  echo "       the bundle id against INSTALLED apps." >&2
  exit 2
fi
echo "bg-publish — granted When-In-Use location to ${BUNDLE_ID}"

# An initial fix so locationd is not fixless while the armed
# CLBackgroundActivitySession is live. Device state: it persists until
# `clear`/shutdown and survives the drive's own install. The VALUE is never
# asserted — the drive fakes its location source (B7 precedent), so these
# coordinates are CoreLocation hygiene, not a test input, and echoing them is
# harmless.
if ! xcrun simctl location "${SIM_UDID}" set "47.606209,-122.332069"; then
  echo "ERROR: 'xcrun simctl location ${SIM_UDID} set <lat>,<lon>' failed, so" >&2
  echo "       the simulator has no simulated position." >&2
  exit 2
fi
echo "bg-publish — seeded an initial simulator fix"

# bgp_background_app — the REAL background transition: launch Preferences
# over Haven so iOS fires applicationDidEnterBackground. The prior terminate
# is best-effort hygiene (a leftover Preferences from an earlier attempt
# would make the launch a no-op foregrounding of an already-front app).
# Returns non-zero when the launch itself failed.
bgp_background_app() {
  xcrun simctl terminate "${SIM_UDID}" "${OVERLAY_BUNDLE_ID}" >/dev/null 2>&1 || true
  xcrun simctl launch "${SIM_UDID}" "${OVERLAY_BUNDLE_ID}" >/dev/null 2>&1
}

# bgp_foreground_app — re-activate Haven after the drive's final marker so
# flutter_test's post-suite teardown gets real engine frames again
# (`simctl launch` on an already-running bundle activates it). Best-effort
# BY DESIGN: it aids teardown, it is never a gate, and the completion gate
# below owes nothing to it.
bgp_foreground_app() {
  xcrun simctl launch "${SIM_UDID}" "${BUNDLE_ID}" >/dev/null 2>&1 || true
}

# --- Drive (backgrounded so this script can run the handshake). --------------
# Delegated so the first-test watchdog, the narrowed retry gate (A6) and the
# secret-leak scan are inherited rather than reimplemented.
# HAVEN_E2E_IOS_SKIP_UNINSTALL=1 stops the shared runner's own uninstall from
# erasing the grant made above.
HAVEN_LIVE_SYNC="${LIVE_SYNC}" \
HAVEN_E2E_RELAY="${RELAY_URL}" \
HAVEN_E2E_IOS_SKIP_UNINSTALL=1 \
  bash "${SIM_RUNNER}" "${SCENARIO_FILE}" "${SIM_UDID}" &
DRIVE_PID=$!
readonly DRIVE_PID

# --- The handshake. ----------------------------------------------------------
set +e
bgp_wait_for_marker "${SHARED_LOG}" "${READY_MARKER}" "${DRIVE_PID}" \
  "${READY_WAIT_SECS}" "${MARKER_POLL_SECS}"
READY_RC=$?
set -e

case "${READY_RC}" in
  0)
    echo "bg-publish — READY marker observed; backgrounding the app by" \
         "launching ${OVERLAY_BUNDLE_ID} over it."
    if ! bgp_background_app; then
      # Loud, but NOT a kill: the drive's own paused-wait fails in <=180s
      # with a message naming this step, so the lane reds with attribution
      # on both sides instead of an orphaned half-run.
      echo "ERROR: 'xcrun simctl launch ${SIM_UDID} ${OVERLAY_BUNDLE_ID}'" >&2
      echo "       failed — the app was never backgrounded. The drive's" >&2
      echo "       paused-wait will now fail and name this step." >&2
    fi
    # Wait for the drive's LAST marker, then re-foreground Haven so the
    # flutter_test teardown gets real frames. On the deadline (3) the app is
    # re-foregrounded ANYWAY — if the drive is wedged post-assertions, an
    # activated engine un-wedges a frame-bound teardown; if it is wedged
    # earlier, foregrounding changes nothing and the drive's own bounds
    # (test timeout, attempt timeout) still govern. On (2) the drive already
    # exited and there is nothing to aid.
    set +e
    bgp_wait_for_marker "${SHARED_LOG}" "${DISARMED_MARKER}" "${DRIVE_PID}" \
      "${DISARM_WAIT_SECS}" "${MARKER_POLL_SECS}"
    DISARM_RC=$?
    set -e
    case "${DISARM_RC}" in
      0)
        echo "bg-publish — final marker observed; re-foregrounding ${BUNDLE_ID} for teardown."
        bgp_foreground_app
        ;;
      3)
        echo "WARN: the drive printed no ${DISARMED_MARKER} within ${DISARM_WAIT_SECS}s;" >&2
        echo "      re-foregrounding ${BUNDLE_ID} anyway to un-wedge a" >&2
        echo "      frame-bound teardown, then waiting for the drive's own" >&2
        echo "      bounds to report." >&2
        bgp_foreground_app
        ;;
      *)
        : # 2 — the drive exited on its own; its rc is collected below.
        ;;
    esac
    ;;
  2)
    echo "bg-publish — the drive exited before printing ${READY_MARKER};" \
         "collecting its exit code."
    ;;
  3)
    echo "ERROR: the drive printed no ${READY_MARKER} within ${READY_WAIT_SECS}s." >&2
    echo "       Not backgrounding. If the drive is healthy but slow, its own" >&2
    echo "       paused-wait will fail attributably; if it is wedged pre-test," >&2
    echo "       the shared runner's first-test watchdog owns it." >&2
    ;;
esac

set +e
wait "${DRIVE_PID}"
DRIVE_RC=$?
set -e

# Preserve the log under this lane's own name for the artifact upload, before
# anything else can overwrite the shared path.
cp "${SHARED_LOG}" "${BG_LOG}" 2>/dev/null || true

if (( DRIVE_RC != 0 )); then
  echo "ERROR: the iOS bg-publish drive failed (rc=${DRIVE_RC})." >&2
  exit "${DRIVE_RC}"
fi

# --- The completion gate (A3b). ----------------------------------------------
# The drive exited 0 — which is NOT the same as the drive having RUN.
# `flutter test` reports success over a body that was skipped
# (`skip: true`, `markTestSkipped`) or returned early, and the READY marker
# cannot see it: it is printed before P2/P3 run. Each proof below is printed
# only after the last assertion of its own phase.
MISSING_PROOFS="$(bgp_missing_proofs "${BG_LOG}")"
readonly MISSING_PROOFS
if [[ -n "${MISSING_PROOFS}" ]]; then
  echo "ERROR: the drive exited 0 WITHOUT printing its terminal proof(s):" >&2
  printf '%s\n' "${MISSING_PROOFS}" | sed 's/^/         missing: /' >&2
  echo "       This is NOT an assertion failure — a failed expect() makes" >&2
  echo "       the drive exit non-zero and is reported above with its own" >&2
  echo "       reason. Reaching here means the run finished CLEANLY without" >&2
  echo "       executing the body that would have printed the marker — a" >&2
  echo "       self-skip, an early return, a suite that ran nothing" >&2
  echo "       (CI_HARDENING_BACKLOG.md A3b), or a renamed marker. The" >&2
  echo "       literals live in this script and in haven/${SCENARIO_FILE};" >&2
  echo "       change them together. Log: ${BG_LOG}." >&2
  exit 1
fi

# Leave the simulator clean for whatever step runs next.
xcrun simctl uninstall "${SIM_UDID}" "${BUNDLE_ID}" >/dev/null 2>&1 || true

echo ""
echo "bg-publish — PASSED: the native CoreLocation background session armed on"
echo "     enable, kind-445 publishes kept reaching the relay across a REAL"
echo "     OS background transition, and disabling background sharing while"
echo "     still backgrounded stopped publishing and disarmed the session."
