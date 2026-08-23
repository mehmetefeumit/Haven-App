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
#   1. Once P1 passed, the drive writes `[bg-publish] READY_FOR_BACKGROUND`
#      into a file in its OWN sandbox tmp/ (and prints the same marker for a
#      human reading the log). The FILE is the signal, because the log is not
#      a stream this script may depend on: in run 32553078705 the whole
#      119-line drive log landed in one second, nine minutes after it was
#      produced. The cause was the `github` test reporter, which buffers a
#      test's entire output and flushes it as a `::group::` only when that test
#      ENDS (run-ios-sim-scenario.sh now pins `--reporter expanded` so the
#      watchdog is not fooled by the same silence). A handshake that read the
#      log would have to be re-proven against every future reporter and flush
#      decision; a file the drive writes itself has neither dependency. Tailing
#      the log can also only ever background the app AFTER the drive's own
#      paused-wait has expired if anything ever buffers again,
#      which is why this lane could not pass.
#   2. This script deletes that file, then polls the app data container for it
#      in a bounded loop, then backgrounds the app:
#          xcrun simctl terminate <udid> com.apple.Preferences || true
#          xcrun simctl launch    <udid> com.apple.Preferences
#      The drive keeps running only because the APP has a background-execution
#      claim: `UIBackgroundModes: location` plus the live CLLocationManager
#      updates session the production GeolocatorLocationService creates with
#      `allowsBackgroundLocationUpdates`. The simulator suspends a
#      backgrounded app just like a device — CI run 32646436116 caught it
#      doing so ~30 s in, back when the drive faked its location service away
#      — and a suspended drive's `flutter test` isolate stops executing until
#      the app is re-foregrounded.
#   3. The drive bounded-polls its own lifecycle state for the REAL paused
#      transition; its failure message names this script's background step,
#      so a broken handshake is attributed from both sides.
#   4. When the drive disables background sharing it appends
#      `[bg-publish] BACKGROUND_SHARING_DISABLED`. That is the instant the
#      app loses its right to run in the background, so this script times
#      P3's settle window from there and re-foregrounds Haven itself once it
#      has elapsed: a suspended drive cannot re-fetch the relay, and the
#      re-fetch has to happen before the window's own kind-445s age past
#      their 228 s NIP-40 expiration (see DISARM_WAIT_SECS).
#   5. After the drive's LAST marker (`[bg-publish] SESSION_DISARMED`) this
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
# A simulator has no jetsam, no Significant-Location-Change relaunch and no
# BGTaskScheduler, so a background-execution bug only those surface cannot
# show up here. This lane proves that the production background stack — plist
# mode, AppleSettings, the native session handler, the Dart publish pipeline —
# survives a genuinely fired UIApplication background transition and keeps
# kind-445 events reaching the relay. The physical-device checklist
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
# via HAVEN_E2E_IOS_SKIP_UNINSTALL=1. Both are load-bearing, not hygiene: the
# drive overrides NOTHING about location (B4's stance, not B7's), because the
# production CLLocationManager session is the app's only claim to execute
# while backgrounded. Without the grant the app sits on an unanswerable
# prompt; without the fix locationd has nothing to deliver.
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
# READY_MARKER and DISABLED_MARKER feed the HANDSHAKE only and are printed
# before the assertions that follow them, so neither can stand in for a
# completion proof. The other four are the terminal proofs: each is printed
# only after the last assertion of its own phase. PUBLISH_MARKER is matched as
# a PREFIX (the drive appends ` count=<n>`).
readonly READY_MARKER='[bg-publish] READY_FOR_BACKGROUND'
readonly DISABLED_MARKER='[bg-publish] BACKGROUND_SHARING_DISABLED'
readonly ARMED_MARKER='[bg-publish] SESSION_ARMED'
readonly PUBLISH_MARKER='[bg-publish] BACKGROUND_PUBLISH_OK'
readonly SILENCE_MARKER='[bg-publish] NEGATIVE_SILENCE_OK'
readonly DISARMED_MARKER='[bg-publish] SESSION_DISARMED'

# The shared runner's fixed log path (run-ios-sim-scenario.sh's LOG_FILE).
# Read ONLY after the drive exits — for the completion gate and the artifact —
# never for the live handshake: what reaches it, and when, is the test
# reporter's decision rather than this script's, so it is treated as a
# post-mortem and not as a stream.
readonly SHARED_LOG="/tmp/flutter-ios-test.log"

# The handshake signal. The drive APPENDS the two markers this script must act
# on while the drive is still running (READY_MARKER, then DISARMED_MARKER) to a
# file of this name in its own sandbox tmp/ (`Directory.systemTemp` ==
# `<data container>/tmp`). A file write reaches the filesystem immediately, so
# unlike the log it is readable mid-run. Duplicated from the Dart const
# `kHandshakeSignalFileName` for the same reason the markers are — change both.
readonly SIGNAL_NAME='bg-publish-handshake'

# Where the run's log is preserved for the artifact upload.
readonly BG_LOG="/tmp/bg-publish-ios.log"

# Handshake bounds. READY must appear after the delegated `flutter test`'s
# incremental build (~2-4 min; the cold build happens in THIS script, before
# the drive) plus install/launch/attach plus the in-test setup and P1 —
# ~10 min worst case measured against B7's phases, so 20 min is ~2x.
#
# DISABLED starts at the backgrounding and is the sum of the drive phases
# between the two: the paused-transition poll (<=180 s), P2's window (396 s),
# its heartbeat drain (<=20 s) and the P3 baseline fetch (15 s) = 611 s.
# 900 s is that plus half again.
#
# DISARM is NOT a "something went wrong" backstop — it is the timer that ends
# P3, and every second of it comes from a constant. From DISABLED the app has
# no right to run in the background, so iOS may suspend it and the wrapper
# owns the wake-up. It is bounded on both sides:
#   lower — it must exceed the drive's settle window (200 s =
#           kLocationPublishMaxInterval + 32 s), or the app this script
#           re-foregrounds publishes INSIDE the window the drive is
#           measuring and a correct app fails P3;
#   upper — the drive re-fetches the relay when it wakes, and the earliest
#           event that can count as a leak is created at the disable cutoff
#           plus the 10 s in-flight grace, so it is evicted at cutoff + 10 +
#           228 s (the kind-445 NIP-40 expiration) = 238 s. A later wake-up
#           re-fetches silence whether or not the disable worked.
# 200 + 10 = 210 s clears the window by the in-flight grace and leaves the
# re-fetch (210 + one <=5 s poll + the drive's own resume) ~20 s inside the
# eviction bound. A run where the app was NOT suspended signals DISARMED
# first and never reaches the deadline.
readonly READY_WAIT_SECS="${HAVEN_BGP_READY_WAIT_SECS:-1200}"
readonly DISABLE_WAIT_SECS="${HAVEN_BGP_DISABLE_WAIT_SECS:-900}"
readonly DISARM_WAIT_SECS="${HAVEN_BGP_DISARM_WAIT_SECS:-210}"
readonly MARKER_POLL_SECS="${HAVEN_BGP_MARKER_POLL_SECS:-5}"

# The simulated-location drip: two fixes ~5 m apart (4.5e-5 deg of latitude),
# alternated every DRIP_SECS for the whole run.
#
# CoreLocation does not keep a backgrounded app executing when it has nothing
# to deliver to it — Apple states exactly that for the whole session family
# (WWDC24 "What's new in location authorization": "Core Location does not
# take measures to keep apps running continuously when it has nothing to
# deliver to them"). A single `simctl location ... set` is ONE fix, so a
# device that never moves again is a device with nothing to deliver.
#
# 5 m is chosen from both ends: comfortably above the stream's 1 m
# `distanceFilter` (so every step is a genuine delivery) and, because the two
# points ALTERNATE rather than advance, total displacement never approaches
# `kMotionTriggerDistanceMeters` (100 m). The drip therefore never becomes a
# second publish driver, and P2 keeps measuring the per-circle scheduler.
readonly DRIP_SECS="${HAVEN_BGP_DRIP_SECS:-10}"
readonly DRIP_POINT_A='47.606209,-122.332069'
readonly DRIP_POINT_B='47.606254,-122.332069'
if ! [[ "${READY_WAIT_SECS}" =~ ^[1-9][0-9]*$ ]] \
   || ! [[ "${DISABLE_WAIT_SECS}" =~ ^[1-9][0-9]*$ ]] \
   || ! [[ "${DISARM_WAIT_SECS}" =~ ^[1-9][0-9]*$ ]] \
   || ! [[ "${MARKER_POLL_SECS}" =~ ^[1-9][0-9]*$ ]] \
   || ! [[ "${DRIP_SECS}" =~ ^[1-9][0-9]*$ ]]; then
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

# bgp_signal_paths <app-data-root> <name> — every handshake-signal candidate
# under an app-data root, one path per line.
#
# A SWEEP over containers rather than one pinned path, because the drive's own
# install ROTATES the app's data container. This script installs the app first
# (it has to: `simctl privacy grant` resolves the bundle id against INSTALLED
# apps), then the delegated `flutter drive` installs its freshly built bundle
# over the top and iOS hands the app a NEW
# `Containers/Data/Application/<UUID>` directory. Any path resolved before the
# drive runs therefore names a container nobody writes to afterwards: in CI run
# 32618134993 the host polled …/29407E44…/tmp while the drive wrote to
# …/7ECBFB3C…/tmp, so READY was never observed, the app was never backgrounded,
# and the drive failed its own paused-wait 180 s later. Only the leaf UUID
# rotates — the root below is stable — so sweeping the root is what survives it.
#
# `|| true`: a `find` that meets one unreadable directory exits non-zero having
# still printed every other match. The answer is the OUTPUT, so this reports
# "these are the candidates" rather than handing callers a status they would
# have to distinguish from "none" — and it cannot trip `set -e` in a caller
# that reads it with `$( … )`.
bgp_signal_paths() {
  local root="${1:-}" name="$2"
  find "${root}" -maxdepth 3 -type f -name "${name}" 2>/dev/null || true
}

# bgp_app_data_root <container-path> — the app-data ROOT to sweep, or non-zero
# if the container is not laid out the way this script understands.
#
# Both halves matter and neither is redundant. Skipping the `dirname` leaves the
# sweep pointed at ONE container — which still finds that container's own signal
# at depth 2 and so looks perfectly healthy, right up until the drive's install
# rotates the leaf and the lane fails exactly as it did in CI run 32618134993.
# Skipping the suffix check lets a changed simulator layout silently redirect
# the sweep at whatever `dirname` happened to return.
bgp_app_data_root() {
  local container="${1:-}" root
  root="$(dirname "${container}")"
  [[ "${root}" == */Containers/Data/Application ]] || return 1
  printf '%s\n' "${root}"
}

# bgp_marker_present_under <app-data-root> <name> <marker> — is the marker in
# ANY handshake signal under this root?
#
# A missing root, a missing file and an empty file all read as "absent", the
# same fail-closed reading `bgp_marker_present` gives a single file.
bgp_marker_present_under() {
  local root="${1:-}" name="$2" marker="$3" path
  while IFS= read -r path; do
    [[ -n "${path}" ]] || continue
    if bgp_marker_present "${path}" "${marker}"; then return 0; fi
  done < <(bgp_signal_paths "${root}" "${name}")
  return 1
}

# bgp_wait_until <pid> <deadline-secs> <poll-secs> -- <cmd> [args…] — bounded
# wait for a predicate command to succeed while a process is still alive.
#
# The predicate must read the handshake SIGNAL, never SHARED_LOG: when a
# marker reaches that log is the test reporter's decision, and under the one
# flutter_tools picks by default in CI it is not observable until the drive
# exits.
#
# Returns:
#   0  the predicate succeeded
#   2  the process exited first (the predicate is re-evaluated before this
#      verdict, so a signal written as the drive's last act still counts)
#   3  the deadline elapsed with the process still running
bgp_wait_until() {
  local pid="$1" deadline="$2" poll="$3" waited=0
  shift 3
  [[ "${1:-}" == '--' ]] && shift
  while :; do
    if "$@"; then return 0; fi
    if ! kill -0 "${pid}" 2>/dev/null; then
      # The process may have written the signal in its final act.
      if "$@"; then return 0; fi
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
      echo 'All tests passed!'
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
  rc=0; bgp_wait_until "${wpid}" 10 1 \
    -- bgp_marker_present "${wlog}" "${READY_MARKER}" || rc=$?
  kill "${wpid}" 2>/dev/null || true; wait "${wpid}" 2>/dev/null || true
  _check "W1 an already-present marker returns 0" 0 "${rc}"

  # --- (W2) A marker that appears mid-wait is found. The writer delays 1 s
  #     against a 10 s deadline — a 10x margin, so a loaded runner cannot
  #     flake this.
  : > "${wlog}"
  ( sleep 1; printf '%s\n' "${READY_MARKER}" >> "${wlog}"; sleep 30 ) &
  wpid=$!
  rc=0; bgp_wait_until "${wpid}" 10 1 \
    -- bgp_marker_present "${wlog}" "${READY_MARKER}" || rc=$?
  kill "${wpid}" 2>/dev/null || true; wait "${wpid}" 2>/dev/null || true
  _check "W2 a marker appearing mid-wait returns 0" 0 "${rc}"

  # --- (W3) A process that exits WITHOUT the marker reports 2, not a hang
  #     and not a deadline — the caller must distinguish "the drive died"
  #     from "the drive is slow".
  : > "${wlog}"
  ( exit 0 ) & wpid=$!
  wait "${wpid}" 2>/dev/null || true
  rc=0; bgp_wait_until "${wpid}" 10 1 \
    -- bgp_marker_present "${wlog}" "${READY_MARKER}" || rc=$?
  _check "W3 a dead process without the marker returns 2" 2 "${rc}"

  # --- (W3b) The post-death RE-CHECK, and ONLY it: the predicate is false on
  #     its first evaluation and true on its second, against an ALREADY-DEAD
  #     pid, so a 0 here can come from nowhere else. Writing the signal up
  #     front (the obvious way to write this fixture) is answered by the
  #     top-of-loop read instead and leaves the re-check unexercised —
  #     deleting the re-check outright then passes. The case it guards is a
  #     drive that writes its signal as its last act before exiting.
  local wonce="${tmp}/w.once"
  rm -f "${wonce}"
  _bgp_true_on_second_call() {
    [[ -e "${wonce}" ]] && return 0
    : > "${wonce}"
    return 1
  }
  ( exit 0 ) & wpid=$!
  wait "${wpid}" 2>/dev/null || true
  rc=0; bgp_wait_until "${wpid}" 10 1 -- _bgp_true_on_second_call || rc=$?
  _check "W3b the post-death re-check is what returns 0" 0 "${rc}"

  # --- (W4) A live, silent process runs into the DEADLINE (3): the loop is
  #     provably bounded, so a lost handshake can never hang the lane.
  : > "${wlog}"
  ( sleep 30 ) & wpid=$!
  rc=0; bgp_wait_until "${wpid}" 2 1 \
    -- bgp_marker_present "${wlog}" "${READY_MARKER}" || rc=$?
  kill "${wpid}" 2>/dev/null || true; wait "${wpid}" 2>/dev/null || true
  _check "W4 a silent live process hits the deadline (3)" 3 "${rc}"

  # --- (S1) REGRESSION (CI run 32618134993): the drive's own install ROTATES
  #     the app's data container, so the container that exists when this
  #     script resolves one is not the container the drive ends up writing
  #     into. The handshake must therefore find the signal in ANY container
  #     under the app-data root. Nothing above can see this — every W fixture
  #     hands the wait the very file its writer used, which is precisely the
  #     assumption the rotation breaks.
  local sroot="${tmp}/Containers/Data/Application"
  mkdir -p "${sroot}/AAAA/tmp" "${sroot}/BBBB/tmp"
  printf '%s\n' "${READY_MARKER}" > "${sroot}/BBBB/tmp/${SIGNAL_NAME}"
  rc=0
  bgp_marker_present_under "${sroot}" "${SIGNAL_NAME}" "${READY_MARKER}" || rc=$?
  _check "S1 a signal in a ROTATED container is still found" 0 "${rc}"

  # --- (S1b) Non-vacuity for S1: sweeping many containers must not turn into
  #     "any signal satisfies any marker". A marker the drive has not written
  #     is still absent, so the DISARMED wait cannot be satisfied by the READY
  #     the same file already carries.
  rc=0
  bgp_marker_present_under "${sroot}" "${SIGNAL_NAME}" "${DISARMED_MARKER}" \
    || rc=$?
  _check "S1b an unwritten marker stays absent across containers" 1 "${rc}"

  # --- (S3) The stale-signal clear must sweep EVERY container. A retry's
  #     drive can be handed a container an EARLIER attempt's drive already
  #     wrote its READY into, and a leftover READY is matched on the first
  #     poll — backgrounding the app before the drive has even launched (run
  #     32553078705 attempt 2). Clearing only the container resolvable at
  #     clear time is not enough once rotation is in play.
  printf '%s\n' "${READY_MARKER}" > "${sroot}/AAAA/tmp/${SIGNAL_NAME}"
  printf '%s\n' "${READY_MARKER}" > "${sroot}/BBBB/tmp/${SIGNAL_NAME}"
  local stale
  while IFS= read -r stale; do
    [[ -n "${stale}" ]] || continue
    rm -f "${stale}"
  done < <(bgp_signal_paths "${sroot}" "${SIGNAL_NAME}")
  rc=0
  bgp_marker_present_under "${sroot}" "${SIGNAL_NAME}" "${READY_MARKER}" || rc=$?
  _check "S3 the stale-signal sweep clears EVERY container" 1 "${rc}"

  # --- (R1) The app-data root of a well-formed container is its parent.
  got="$(bgp_app_data_root \
    '/d/8E85/data/Containers/Data/Application/29407E44')"
  _check "R1 a well-formed container yields its Application root" \
    "/d/8E85/data/Containers/Data/Application" "${got}"

  # --- (R2) A container that is NOT directly under an Application root is
  #     REFUSED. This is the shape a dropped `dirname` produces, and it is the
  #     silent half of the CI-run-32618134993 bug: sweeping the container
  #     itself still finds that container's own signal (at depth 2 of 3), so
  #     every behavioural fixture stays green until the drive's install
  #     rotates the leaf out from under it.
  rc=0
  bgp_app_data_root \
    '/d/8E85/data/Containers/Data/Application/29407E44/tmp' >/dev/null || rc=$?
  _check "R2 a container off the Application root is REFUSED" 1 "${rc}"

  # --- (R3) STRUCTURAL: the real run derives its root through that helper,
  #     rather than assigning the container to APP_DATA_ROOT directly — the
  #     mutation R1/R2 cannot see, because it never calls the helper at all.
  body="$(sed -n '/^# --- The handshake signal path\./,/^# --- Drive/p' \
            "${BASH_SOURCE[0]}" | grep -v '^[[:space:]]*#')"
  rc=0
  [[ -n "${body}" ]] || rc=1
  grep -qF 'APP_DATA_ROOT="$(bgp_app_data_root "${APP_DATA_CONTAINER}")"' \
    <<<"${body}" || rc=1
  _check "R3 the real run derives its root through bgp_app_data_root" 0 "${rc}"

  # --- (N1) The signal's NAME is one literal shared with the Dart drive. The
  #     two halves cannot agree by construction — Dart writes the file, this
  #     script finds it — so a rename on one side costs a full READY_WAIT_SECS
  #     wait and a misleading diagnostic. Unlike the four proof markers, which
  #     the completion gate would catch, nothing else compares these.
  #     Fails CLOSED on an unreadable drive file (empty answer, mismatch
  #     reported) rather than letting `set -e` kill the run from inside the
  #     assignment — a fixture that aborts the suite is a fixture that never
  #     reports, and every fixture after it goes unrun.
  local dart_const
  dart_const="$(sed -n \
    's/^const String kHandshakeSignalFileName = .\(.*\).;$/\1/p' \
    "${SCRIPT_DIR}/../../../haven/integration_test/ios_bg_publish_test.dart" \
    2>/dev/null || true)"
  _check "N1 the Dart signal name matches SIGNAL_NAME" \
    "${SIGNAL_NAME}" "${dart_const}"

  # --- (N2) The DISABLED marker literal is shared with the Dart drive, and
  #     nothing else compares them. The four proof markers are cross-checked
  #     by the completion gate; this one is not, and a drift is SILENT and
  #     dangerous rather than merely slow: the host would stop timing P3's
  #     settle window from the disable and re-foreground only on the DISABLE
  #     deadline, minutes late — by which time a real leak has aged past the
  #     228 s kind-445 expiration and been evicted, so the drive re-fetches
  #     silence and P3 passes having proved nothing.
  local dart_disabled
  dart_disabled="$(sed -n \
    's/^const String kDisabledMarker = .\(.*\).;$/\1/p' \
    "${SCRIPT_DIR}/../../../haven/integration_test/ios_bg_publish_test.dart" \
    2>/dev/null || true)"
  _check "N2 the Dart disable marker matches DISABLED_MARKER" \
    "${DISABLED_MARKER}" "${dart_disabled}"

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
  # …and that the READY branch actually CALLS it. Pinning only the body leaves
  # `if ! bgp_background_app` one indirection away from being stubbed out while
  # this fixture still reports the background step present.
  local handshake
  handshake="$(sed -n '/^# --- The handshake\./,/^# --- The completion gate/p' \
                 "${BASH_SOURCE[0]}" | grep -v '^[[:space:]]*#')"
  grep -qF 'if ! bgp_background_app; then' <<<"${handshake}" || rc=1
  _check "H1 the background step launches the overlay app, and is called" \
    0 "${rc}"

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

  # --- (H4) STRUCTURAL: the live handshake must never be pointed back at
  #     SHARED_LOG. When a marker reaches that log is the test reporter's
  #     decision, not this script's — in CI run 32553078705 the drive's whole
  #     log materialised in one second, nine minutes after it was produced,
  #     because the `github` reporter holds a test's output until the test ends
  #     — so a marker in it is a post-mortem, not a stream, and a handshake
  #     reading it backgrounds the app only after the drive's own paused-wait
  #     has already failed. Nothing else
  #     here can see that regression: every marker fixture above passes
  #     against a file written promptly, which is precisely what SHARED_LOG
  #     is not.
  #     Scoped to the real run's handshake section, and narrowed to the WAIT
  #     CALLS in it, so neither this fixture's own needle nor the legitimate
  #     post-mortem `cp` of SHARED_LOG can decide the verdict.
  #
  #     It also pins WHAT the waits read: one `bgp_marker_present_under` per
  #     `bgp_wait_until`, each swept over the app-data ROOT. A wait repointed
  #     at a single pinned container is the CI-run-32618134993 regression (see
  #     `bgp_signal_paths`), and it looks perfectly healthy to every fixture
  #     above.
  #     Line continuations are JOINED first, so each wait is one line carrying
  #     its predicate AND its marker. Without that the marker checks below
  #     could not see a marker that sits on a continuation line, and the
  #     copy-paste this fixture exists to catch lives exactly there.
  body="$(sed -n '/^# --- The handshake\./,/^# --- The completion gate/p' \
            "${BASH_SOURCE[0]}" | grep -v '^[[:space:]]*#' \
            | sed -e ':a' -e '/\\$/{N; s/\\\n[[:space:]]*/ /; ta}' \
            | grep -F 'bgp_wait_until ' || true)"
  rc=0
  # Non-vacuity: an empty body would pass the checks below for free.
  [[ -n "${body}" ]] || rc=1
  grep -qF 'SHARED_LOG' <<<"${body}" && rc=1
  # A single-file read is the pinned-container regression, whatever it reads.
  grep -qF 'bgp_marker_present "' <<<"${body}" && rc=1
  # `|| true` on the counts: `grep -c` exits 1 on zero matches, and under
  # `set -e` that aborts the self-test MID-RUN — this fixture and H5 would
  # never report, leaving a deleted handshake to red the lane anonymously.
  local waits swept ready disabled disarmed
  waits="$(grep -cF 'bgp_wait_until ' <<<"${body}" || true)"
  swept="$(grep -cF 'bgp_marker_present_under "${APP_DATA_ROOT}"' <<<"${body}" \
             || true)"
  (( waits == 3 )) || rc=1
  (( waits == swept )) || rc=1
  # ONE wait per marker, and the three markers are all different. A DISARM
  # wait that reads READY_MARKER is the worst mutation this lane admits: READY
  # is already in the signal from the handshake, so the wait returns on its
  # first poll and the host re-foregrounds the app seconds after backgrounding
  # it — P2 then measures "publishes continue while backgrounded" against a
  # FOREGROUND app, every terminal proof still prints, and the lane goes green
  # having proved nothing. A DISARM wait keyed off DISABLED is the same shape
  # one phase later. No behavioural fixture can see either; only this can.
  ready="$(grep -cF '"${READY_MARKER}"' <<<"${body}" || true)"
  disabled="$(grep -cF '"${DISABLED_MARKER}"' <<<"${body}" || true)"
  disarmed="$(grep -cF '"${DISARMED_MARKER}"' <<<"${body}" || true)"
  (( ready == 1 )) || rc=1
  (( disabled == 1 )) || rc=1
  (( disarmed == 1 )) || rc=1
  _check "H4 each handshake wait sweeps the root for its OWN marker" 0 "${rc}"

  # --- (H5) STRUCTURAL: stale signals are cleared BEFORE the drive starts,
  #     and across EVERY container. The retry re-runs this script against the
  #     same device, so a READY left by the previous attempt is matched on the
  #     first poll — observed in run 32553078705 attempt 2, 63 ms after the
  #     seed step and before the drive had launched. The marker fixtures
  #     cannot see this: to them a present marker is a success. S3 proves the
  #     sweep clears every container; this proves the real run performs it,
  #     and performs it before the drive is launched.
  body="$(sed -n '/^echo "bg-publish — seeded an initial simulator fix"/,/^DRIVE_PID=/p' \
            "${BASH_SOURCE[0]}" | grep -v '^[[:space:]]*#')"
  rc=0
  grep -qF 'bgp_signal_paths "${APP_DATA_ROOT}" "${SIGNAL_NAME}"' <<<"${body}" \
    || rc=1
  grep -qF 'rm -f "${stale_signal}"' <<<"${body}" || rc=1
  _check "H5 every container's stale signal is cleared before the drive" 0 "${rc}"

  # --- (H6) STRUCTURAL: the simulated-location drip exists, MOVES, is started
  #     before the drive and is stopped on exit. CoreLocation suspends a
  #     backgrounded app it has nothing to deliver to (CI run 32646436116),
  #     and a suspended app publishes nothing — so a drip that was deleted,
  #     never started, or left re-setting ONE coordinate (which the 1 m
  #     `distanceFilter` swallows, delivering nothing) reds the lane from the
  #     app's side, blaming the publish pipeline. Only the value comparison
  #     below can see the identical-points mutation.
  body="$(sed -n '/^bgp_location_drip() {/,/^}/p' "${BASH_SOURCE[0]}" \
            | grep -v '^[[:space:]]*#')"
  rc=0
  grep -qF 'xcrun simctl location "${SIM_UDID}" set "${next}"' <<<"${body}" \
    || rc=1
  grep -qF 'next="${DRIP_POINT_A}"' <<<"${body}" || rc=1
  grep -qF 'next="${DRIP_POINT_B}"' <<<"${body}" || rc=1
  [[ "${DRIP_POINT_A}" != "${DRIP_POINT_B}" ]] || rc=1
  body="$(sed -n '/^echo "bg-publish — seeded an initial simulator fix"/,/^DRIVE_PID=/p' \
            "${BASH_SOURCE[0]}" | grep -v '^[[:space:]]*#')"
  grep -qF 'bgp_location_drip &' <<<"${body}" || rc=1
  # Scoped to the real run: this fixture's own needles live above it, and a
  # whole-file grep would match them and pass over a deleted trap.
  body="$(sed -n '/^# Real run$/,$p' "${BASH_SOURCE[0]}" \
            | grep -v '^[[:space:]]*#')"
  grep -qF 'trap bgp_stop_drip EXIT' <<<"${body}" || rc=1
  _check "H6 the location drip moves, starts before the drive and is reaped" \
    0 "${rc}"

  if (( fail != 0 )); then
    echo "run-ios-bg-publish.sh --self-test: FAILED" >&2
    return 1
  fi
  echo "run-ios-bg-publish.sh --self-test: all 35 fixtures passed (the" \
       "simctl probes report supported/unsupported/unparseable distinctly;" \
       "the marker parser is literal, prefix-tolerant and fails closed on" \
       "missing logs; the completion gate demands all four terminal proofs" \
       "and never accepts READY in their place; the marker wait is bounded" \
       "and distinguishes a dead drive from a slow one, the re-check after" \
       "it included; the signal sweep survives the container rotation the" \
       "drive's own install causes, stays marker-specific and clears every" \
       "container; the app-data root is derived AND validated; the signal" \
       "name and the disable marker still match the Dart drive's; and the" \
       "background step and its call, the per-wait markers, the fail-closed" \
       "grant, the uninstall" \
       "skip and the moving location drip are structurally pinned)."
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

# The fix the app will actually publish: the drive runs the production
# location service, so a fixless locationd means no publishes and a red P2.
# Device state — it persists until `clear`/shutdown and survives the drive's
# own install. The VALUE is never asserted (P2/P3 count events, they do not
# read coordinates; B4 owns the coordinate-fidelity proof), so echoing it is
# harmless.
if ! xcrun simctl location "${SIM_UDID}" set "47.606209,-122.332069"; then
  echo "ERROR: 'xcrun simctl location ${SIM_UDID} set <lat>,<lon>' failed, so" >&2
  echo "       the simulator has no simulated position." >&2
  exit 2
fi
echo "bg-publish — seeded an initial simulator fix"

# --- The handshake signal path. ----------------------------------------------
# The host watches the app-data ROOT, not one container: the drive's own
# install rotates the leaf `<UUID>` (see `bgp_signal_paths`), so a path pinned
# here would name a directory nobody writes to. Resolving the container is
# still how the root is found, and is still FATAL on failure — the install and
# grant above already proved the bundle id resolves, so a failure here means
# the layout is not what this script understands, and a script that fell back
# to sweeping some other path would wait out READY_WAIT_SECS and never
# background the app: a vacuous handshake, exactly the failure mode this
# lane's guards exist to keep out.
if ! APP_DATA_CONTAINER="$(xcrun simctl get_app_container \
      "${SIM_UDID}" "${BUNDLE_ID}" data 2>/dev/null)" \
   || [[ -z "${APP_DATA_CONTAINER}" ]]; then
  echo "ERROR: 'xcrun simctl get_app_container ${SIM_UDID} ${BUNDLE_ID} data'" >&2
  echo "       returned nothing, so the host cannot find the file the drive" >&2
  echo "       writes to hand over the READY signal. Without it there is no" >&2
  echo "       handshake and the app would never be backgrounded." >&2
  exit 2
fi
readonly APP_DATA_CONTAINER
if ! APP_DATA_ROOT="$(bgp_app_data_root "${APP_DATA_CONTAINER}")"; then
  echo "ERROR: the app data container resolved to a path whose parent is not" >&2
  echo "       an .../Containers/Data/Application root, so this script cannot" >&2
  echo "       tell which directories the drive's rotated container may land" >&2
  echo "       in. Update bgp_app_data_root for the new simulator layout." >&2
  exit 2
fi
readonly APP_DATA_ROOT

# A signal left by a PREVIOUS attempt must never be read as this one's: the
# retry re-runs this script against the same device and matching a stale READY
# would background the app before the drive had even launched. Observed in CI
# run 32553078705 attempt 2, where the host "observed" READY 63 ms after the
# seed step. Swept across EVERY container, not just the one resolved above,
# because the rotation can hand this attempt's drive a container an earlier
# attempt's drive already wrote its READY into.
while IFS= read -r stale_signal; do
  [[ -n "${stale_signal}" ]] || continue
  rm -f "${stale_signal}"
done < <(bgp_signal_paths "${APP_DATA_ROOT}" "${SIGNAL_NAME}")
echo "bg-publish — handshake signal: ${SIGNAL_NAME} under ${APP_DATA_ROOT}" \
     "(any container; stale copies cleared)"

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

# bgp_location_drip — alternate the simulated fix between the two DRIP_POINTs
# forever, so CoreLocation always has a delivery to make (see DRIP_SECS).
# Failures are swallowed per iteration: a transient simctl hiccup must not end
# the drip, and the app's own suspension detector is what reports a drip that
# stopped mattering.
bgp_location_drip() {
  local next="${DRIP_POINT_B}"
  while true; do
    sleep "${DRIP_SECS}"
    xcrun simctl location "${SIM_UDID}" set "${next}" >/dev/null 2>&1 || true
    if [[ "${next}" == "${DRIP_POINT_B}" ]]; then
      next="${DRIP_POINT_A}"
    else
      next="${DRIP_POINT_B}"
    fi
  done
}

DRIP_PID=""
bgp_stop_drip() {
  [[ -n "${DRIP_PID}" ]] && kill "${DRIP_PID}" >/dev/null 2>&1
  return 0
}
trap bgp_stop_drip EXIT

# Start the drip BEFORE the drive: the app's position stream must already be
# receiving deliveries when it is backgrounded, not start receiving them
# afterwards.
bgp_location_drip &
DRIP_PID=$!
echo "bg-publish — simulated-location drip every ${DRIP_SECS}s (two fixes ~5m" \
     "apart; CoreLocation suspends an app it has nothing to deliver to)"

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
bgp_wait_until "${DRIVE_PID}" "${READY_WAIT_SECS}" "${MARKER_POLL_SECS}" \
  -- bgp_marker_present_under "${APP_DATA_ROOT}" "${SIGNAL_NAME}" "${READY_MARKER}"
READY_RC=$?
set -e

case "${READY_RC}" in
  0)
    echo "bg-publish — READY signal observed; backgrounding the app by" \
         "launching ${OVERLAY_BUNDLE_ID} over it."
    if ! bgp_background_app; then
      # Loud, but NOT a kill: the drive's own paused-wait fails in <=180s
      # with a message naming this step, so the lane reds with attribution
      # on both sides instead of an orphaned half-run.
      echo "ERROR: 'xcrun simctl launch ${SIM_UDID} ${OVERLAY_BUNDLE_ID}'" >&2
      echo "       failed — the app was never backgrounded. The drive's" >&2
      echo "       paused-wait will now fail and name this step." >&2
    fi
    # P2 runs here. The next thing this script must see is the drive
    # disabling background sharing — the instant the app loses its right to
    # execute in the background, and therefore the instant from which the
    # DISARM timer below has to be measured. Nothing to DO on it: the value
    # is when it arrives.
    set +e
    bgp_wait_until "${DRIVE_PID}" "${DISABLE_WAIT_SECS}" "${MARKER_POLL_SECS}" \
      -- bgp_marker_present_under "${APP_DATA_ROOT}" "${SIGNAL_NAME}" \
         "${DISABLED_MARKER}"
    DISABLE_RC=$?
    set -e
    case "${DISABLE_RC}" in
      0)
        echo "bg-publish — disable signal observed; P3's settle window is" \
             "running. Re-foregrounding in at most ${DISARM_WAIT_SECS}s."
        ;;
      3)
        echo "WARN: the drive signalled no ${DISABLED_MARKER} within" >&2
        echo "      ${DISABLE_WAIT_SECS}s, so P2 never finished. The DISARM" >&2
        echo "      wait below still runs; the drive's own P2 assertion is" >&2
        echo "      what reports the failure." >&2
        ;;
      *)
        : # 2 — the drive exited on its own; its rc is collected below.
        ;;
    esac

    # Wait for the drive's LAST marker, then re-foreground Haven. On the
    # deadline (3) the app is re-foregrounded ANYWAY, and here that is the
    # EXPECTED path rather than a rescue: the disable withdrew the app's
    # background keep-alive, so iOS is entitled to suspend it for the whole
    # settle window, and a suspended drive cannot re-fetch the relay. The
    # deadline is sized to land just after that window and well inside the
    # 228 s kind-445 expiration (see DISARM_WAIT_SECS). It also still un-wedges
    # a frame-bound teardown. On (2) the drive already exited.
    set +e
    bgp_wait_until "${DRIVE_PID}" "${DISARM_WAIT_SECS}" "${MARKER_POLL_SECS}" \
      -- bgp_marker_present_under "${APP_DATA_ROOT}" "${SIGNAL_NAME}" \
         "${DISARMED_MARKER}"
    DISARM_RC=$?
    set -e
    case "${DISARM_RC}" in
      0)
        echo "bg-publish — final signal observed; re-foregrounding ${BUNDLE_ID} for teardown."
        bgp_foreground_app
        ;;
      3)
        echo "bg-publish — no ${DISARMED_MARKER} within ${DISARM_WAIT_SECS}s of" \
             "the disable; re-foregrounding ${BUNDLE_ID} so the suspended" \
             "drive can re-fetch the relay and finish P3."
        bgp_foreground_app
        ;;
      *)
        : # 2 — the drive exited on its own; its rc is collected below.
        ;;
    esac
    ;;
  2)
    echo "bg-publish — the drive exited before signalling ${READY_MARKER};" \
         "collecting its exit code."
    ;;
  3)
    echo "ERROR: the drive wrote no ${READY_MARKER} to any ${SIGNAL_NAME}" >&2
    echo "       under ${APP_DATA_ROOT} within ${READY_WAIT_SECS}s. Not" >&2
    echo "       backgrounding. If the drive is healthy but slow, its own" >&2
    echo "       paused-wait will fail attributably; if it is wedged pre-test," >&2
    echo "       the shared runner's first-test watchdog owns it. If the" >&2
    echo "       drive's log DOES carry the marker, the two halves disagree" >&2
    echo "       about the signal's name or the tree it lands in (Dart:" >&2
    echo "       kHandshakeSignalFileName; here: SIGNAL_NAME)." >&2
    # Name the disagreement instead of leaving it to be re-diagnosed: the Dart
    # side writes to `Directory.systemTemp`, which is `<data container>/tmp` on
    # iOS. If the runtime resolves it elsewhere in the sandbox, the sweep above
    # cannot see it — so widen to the whole device data tree and say where.
    # `|| true`: under `set -e` a `find` that hits one unreadable directory
    # would abort the script mid-diagnostic, losing the message it exists to
    # print.
    FOUND_SIGNAL="$(find "${APP_DATA_ROOT%/Containers/Data/Application}" \
                      -maxdepth 8 -name "${SIGNAL_NAME}" 2>/dev/null \
                      | head -n 1 || true)"
    if [[ -n "${FOUND_SIGNAL}" && "${FOUND_SIGNAL}" == "${APP_DATA_ROOT}"/* ]]; then
      # INSIDE the swept tree: the sweep saw this file and rejected it, so the
      # disagreement is about CONTENT, not location. Saying "fix the path"
      # here would send the next maintainer after a bug that does not exist.
      echo "       The drive DID write ${FOUND_SIGNAL}, which this script" >&2
      echo "       swept and read — so the file exists but carries no" >&2
      echo "       ${READY_MARKER}: an empty, truncated or unflushed write," >&2
      echo "       or a drive that died between creating it and writing it." >&2
    elif [[ -n "${FOUND_SIGNAL}" ]]; then
      echo "       The drive DID write the signal, at ${FOUND_SIGNAL}, which" >&2
      echo "       is outside the app-data root this script sweeps. Teach" >&2
      echo "       bgp_app_data_root the tree Dart's systemTemp actually" >&2
      echo "       resolves into." >&2
    else
      echo "       No ${SIGNAL_NAME} exists anywhere on the device, so the" >&2
      echo "       drive never reached the handshake — look at its own" >&2
      echo "       output, not at this step." >&2
    fi
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
