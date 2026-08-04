#!/usr/bin/env bash
#
# B4 — iOS REAL-GPS end-to-end lane
# (docs/CI_HARDENING_BACKLOG.md, Workstream B, item B4:
# "iOS real GPS | `simctl privacy grant location` + `simctl location set`").
#
# The iOS twin of run-b3-real-gps.sh. It proves the whole chain with nothing
# faked and asserts the VALUE rather than the event:
#
#   `xcrun simctl location <udid> set <lat>,<lon>` -> CoreLocation ->
#   geolocator plugin -> GeolocatorLocationService ->
#   locationPublisherProvider -> MLS encrypt -> kind-445 on a hermetic relay
#   -> a PEER's own CircleManagerFfi decrypt -> coordinates compared
#   numerically against what was injected.
#
# # The premise, checked against the tree (2026-08-03)
#
# It held. Every iOS scenario overrides `locationServiceProvider` with
# `FakeLocationService` — `e2e_combined.dart:475` and `:5171`,
# `e2e_profile_sharing.dart:706` — and run-ios-sim-scenario.sh's own header
# says so: "No native location-permission grant: the scenario overrides
# `locationServiceProvider` with `FakeLocationService` ... so CLLocationManager
# is never touched." So on iOS the "GPS fix" was a Dart constant, and the
# authorization path, `AppleSettings` and the simulator location stack were
# executed nowhere in CI.
#
# # simctl support is PROBED, never assumed
#
# `simctl location` (with the `set` action) has existed since Xcode 14 and
# `simctl privacy` since Xcode 11.4, so both are present on any plausible
# `macos-latest` image. This lane still reads the subcommands' own usage text
# and stops with an attributable misconfiguration (exit 2) rather than assuming
# — a lane whose entire subject is "did the OS deliver a real fix" must not
# discover a missing tool as an ambiguous timeout 20 minutes later.
#
# If a future runner image ever lacked `simctl location set`, do NOT substitute
# a fake — that reinstates exactly the hole this lane closes. Raise the image /
# Xcode version. The only real third-party substitute
# (MobileNativeFoundation/set-simulator-location, which drives the same private
# XPC service) would add an unvetted binary to a security-sensitive CI, so it is
# a worse trade than an image bump.
#
# # Why the app is installed BEFORE the grant (the ordering that matters)
#
# `xcrun simctl privacy <device> grant location <bundle-id>` resolves the bundle
# id against the simulator's INSTALLED apps, and the resulting grant does not
# survive `simctl uninstall`. `flutter test` builds, installs, launches and
# reports in one step, so there is no gap inside it for a grant.
#
# This script therefore does what run-b7-ios-auth-tier.sh established: build
# once, then uninstall -> install -> grant -> seed the location, and only then
# delegate the drive to run-ios-sim-scenario.sh with
# `HAVEN_E2E_IOS_SKIP_UNINSTALL=1` so the shared runner's hermetic uninstall
# cannot erase the grant. Authorization is thus in place BEFORE the app's first
# launch — the only ordering that does not rest on a running CLLocationManager
# observing a live TCC change (behaviour Apple documents nowhere and that
# several community reports say needs a relaunch).
#
# # Unlike Android, the fix is NOT one-shot
#
# `adb emu geo fix` injects a single sample into the goldfish GNSS HAL and
# starts no stream, so B3 needs a re-issue loop. `simctl location <udid> set` is
# DEVICE state that persists until `clear` or shutdown, and it is not
# app-scoped, so it survives the re-install `flutter test` performs. One `set`
# is therefore correct here, and a missing fix means the simulator never
# delivered rather than that a seed expired.
#
# # The out-of-process oracle
#
# The drive target's own assertions are the proof, but a drive that exits 0
# without reaching them proves nothing (A3b: a `flutter test` can report success
# over a suite that never ran its body). So this script additionally REQUIRES
# `[b4] PEER_DECRYPT_MATCH` in the captured log — a marker the target prints
# only after every coordinate assertion has passed.
#
# Everything else — the first-test watchdog, the narrowed retry gate, the
# secret-leak scan — is inherited by delegating to run-ios-sim-scenario.sh
# rather than reimplementing `flutter test` here.
#
# # Scope boundary (stated so nobody over-reads a green)
#
# The simulator runs no GNSS hardware and does not suspend a backgrounded app.
# This lane proves the FOREGROUND acquisition + publish + peer-decrypt chain
# against real CoreLocation. Real radio behaviour and real background
# suspension stay on the physical-device checklist
# (docs/CI_HARDENING_BACKLOG.md, "Out of scope for hosted runners").
#
# Usage:
#   run-b4-ios-real-gps.sh <simulator-udid>
#   run-b4-ios-real-gps.sh --self-test    # hermetic; no simulator, no Xcode
#
# Environment:
#   HAVEN_E2E_RELAY             WebSocket URL of the host relay (default
#                               ws://localhost:7777).
#   HAVEN_LIVE_SYNC             'true' or 'false'. MANDATORY — declared per STEP
#                               by the caller, exactly as run-ios-sim-scenario.sh
#                               requires (S1 / CI_HARDENING_BACKLOG.md A7).
#   HAVEN_B4_GEO_LAT            Latitude to seed and to assert against.
#   HAVEN_B4_GEO_LON            Longitude to seed and to assert against.
#   HAVEN_B4_GEO_TOLERANCE_DEG  Comparison tolerance in degrees (default 1e-5).
#
# Side effects:
#   - Writes /tmp/b4-ios-real-gps.log (uploaded as a CI failure artifact).
#   - Leaves the app installed, granted, and the simulator location seeded.
#
# Exit status:
#   0  a real CoreLocation fix reached a peer, decrypted, unchanged
#   1  the drive failed, or it exited 0 without reaching its proof
#   2  usage / harness misconfiguration (including: this Xcode cannot set a
#      simulated location or grant location privacy, so the lane cannot run)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# The drive target, relative to haven/ (the shared runner resolves it there).
readonly SCENARIO_FILE="integration_test/b4_ios_real_gps_test.dart"

# Must match `haven/ios/Runner.xcodeproj`'s PRODUCT_BUNDLE_IDENTIFIER and the id
# run-ios-sim-scenario.sh uninstalls.
readonly BUNDLE_ID="com.oblivioustech.haven"

# The marker the drive target prints ONLY after every coordinate assertion has
# passed. Duplicated here (and only here) because the Dart const is not readable
# from bash; the target's doc comment names this file as the other half of the
# contract, and the --self-test below feeds the real parser fixtures built from
# this literal, so a drift shows up as a failing self-test.
readonly PROOF_MARKER='[b4] PEER_DECRYPT_MATCH'

# Where the delegated run's log is preserved for the artifact upload.
readonly B4_LOG="/tmp/b4-ios-real-gps.log"

# ---------------------------------------------------------------------------
# Pure helpers (exercised by --self-test)
# ---------------------------------------------------------------------------

# b4_simctl_supports_location_set <usage-text> — does this Xcode's
# `simctl location` offer the `set` action?
#
# Returns 0 (supported), 1 (parsed, and `set` is NOT offered), or 2 (the text
# does not look like a `simctl location` usage listing at all — do not guess).
#
# The structural gate needs BOTH `location` and `action`: an Xcode with no
# `location` subcommand answers `Unknown subcommand "location". Usage: simctl
# <subcommand>`, which contains the word `location` and would otherwise be read
# as a valid listing that merely lacks `set` — reporting "your Xcode is too old"
# for a probe that in fact never ran. Every real usage listing enumerates its
# `action`s; the error text does not.
#
# Deliberately no `\b`: this runs on macOS, whose BSD grep does not implement
# the GNU word-boundary escape, so a `\b` pattern would silently never match and
# every real run would report "unparseable" on a perfectly good Xcode.
b4_simctl_supports_location_set() {
  local usage="$1"
  grep -qE '(^|[^A-Za-z-])location([^A-Za-z-]|$)' <<<"${usage}" || return 2
  grep -qE '(^|[^A-Za-z-])action([^A-Za-z-]|$)' <<<"${usage}" || return 2
  grep -qE '(^|[^A-Za-z-])set([^A-Za-z-]|$)' <<<"${usage}"
}

# b4_simctl_supports_location_privacy <usage-text> — does this Xcode's
# `simctl privacy` offer the `location` service? Same tri-state contract.
b4_simctl_supports_location_privacy() {
  local usage="$1"
  if ! grep -qE '(^|[^A-Za-z-])(grant|revoke)([^A-Za-z-]|$)' <<<"${usage}"; then
    return 2
  fi
  grep -qE '(^|[^A-Za-z-])location([^A-Za-z-]|$)' <<<"${usage}"
}

# b4_valid_coordinate <value> <max-abs> — a finite decimal within +/- max-abs.
#
# The range check goes through awk because bash cannot compare floats; the
# regex first, so awk is never handed something that would coerce to 0 (awk
# reads "abc" as 0, which is inside every range — the exact way a validator
# rots into always-passing).
b4_valid_coordinate() {
  local value="$1" max="$2"
  [[ "${value}" =~ ^-?[0-9]+(\.[0-9]+)?$ ]] || return 1
  awk -v v="${value}" -v m="${max}" 'BEGIN { exit !(v >= -m && v <= m) }'
}

# b4_coordinates_usable <lat> <lon> — both valid AND not the null island.
#
# (0, 0) is a legal coordinate and a terrible sentinel: it is exactly what an
# iOS simulator with no simulated location reports, so seeding it would make the
# lane unable to tell "the fix arrived" from "there was never a fix".
b4_coordinates_usable() {
  local lat="$1" lon="$2"
  b4_valid_coordinate "${lat}" 90 || return 1
  b4_valid_coordinate "${lon}" 180 || return 1
  awk -v a="${lat}" -v b="${lon}" 'BEGIN { exit !(a == 0 && b == 0) }' && return 1
  return 0
}

# b4_proof_marker_present <log> — did the drive reach the end of its proof?
#
# A missing or empty log reports absent. `grep -aF` (literal, binary-safe): the
# marker contains `[b4]`, which is a valid character class, so any regex form of
# this check would match a single `b` or `4` and pass vacuously.
b4_proof_marker_present() {
  local log="${1:-}"
  [[ -s "${log}" ]] || return 1
  LC_ALL=C grep -aqF -- "${PROOF_MARKER}" "${log}"
}

# ---------------------------------------------------------------------------
# --self-test — hermetic. The fixtures are the ways this lane can go vacuously
# green or blame the wrong component, because those are the failures nothing
# else would catch.
# ---------------------------------------------------------------------------
run_self_test() {
  local tmp fail=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  _check() { # _check <label> <want-rc> <got-rc>
    if [[ "$2" == "$3" ]]; then
      printf '  \033[1;32mPASS\033[0m %s\n' "$1"
    else
      printf '  \033[1;31mFAIL\033[0m %s (want rc=%s, got rc=%s)\n' "$1" "$2" "$3" >&2
      fail=1
    fi
  }

  local rc

  # --- (L1) An Xcode that offers `simctl location ... set` (Xcode 14+).
  rc=0
  b4_simctl_supports_location_set \
'Set or clear a simulated location.
Usage: simctl location <device> <action> [<arguments>]
   action: list, clear, set, start, run' || rc=$?
  _check "L1 usage listing the set action is supported" 0 "${rc}"

  # --- (L2) THE PREMISE FIXTURE. A `simctl location` without `set` — the case
  #     the backlog warned about ("not available on all versions"). The lane
  #     must refuse, not improvise a fake fix.
  rc=0
  b4_simctl_supports_location_set \
'Usage: simctl location <device> <action>
   action: list, clear' || rc=$?
  _check "L2 usage without the set action is REFUSED" 1 "${rc}"

  # --- (L3) An Xcode with no `location` subcommand at all reports
  #     misconfiguration, distinctly from "parsed and unsupported" — otherwise
  #     the lane would blame Xcode for its own broken probe.
  rc=0
  b4_simctl_supports_location_set \
'Unknown subcommand "location". Usage: simctl <subcommand>' || rc=$?
  _check "L3 an absent location subcommand reports misconfiguration" 2 "${rc}"

  # --- (P1) `simctl privacy` offering the `location` service.
  rc=0
  b4_simctl_supports_location_privacy \
'Grant, revoke, or reset privacy and permissions.
Usage: simctl privacy <device> <action> <service> [<bundle identifier>]
   action: grant, revoke, reset
   service: all, calendar, contacts, location, location-always, photos' || rc=$?
  _check "P1 privacy usage listing the location service is supported" 0 "${rc}"

  # --- (P2) A privacy service list without `location`.
  rc=0
  b4_simctl_supports_location_privacy \
'Usage: simctl privacy <device> <action> <service>
   action: grant, revoke, reset
   service: all, calendar, contacts, photos, microphone' || rc=$?
  _check "P2 privacy usage without the location service is REFUSED" 1 "${rc}"

  # --- (P3) Unparseable privacy usage.
  rc=0
  b4_simctl_supports_location_privacy \
'xcrun: error: unable to find utility "simctl"' || rc=$?
  _check "P3 unparseable privacy usage reports misconfiguration" 2 "${rc}"

  # --- (C1) The sentinel this lane ships with must validate, including its
  #     negative signs (both hemispheres — a sign-dropping regression in the
  #     encode path is precisely what a same-hemisphere sentinel cannot see).
  rc=0; b4_coordinates_usable -41.234567 -134.567890 || rc=$?
  _check "C1 the shipped negative-hemisphere sentinel is usable" 0 "${rc}"

  # --- (C2) Out-of-range values are rejected, per axis (a latitude limit
  #     applied to longitude would silently accept 134 as a latitude).
  rc=0; b4_coordinates_usable 91.0 10.0 || rc=$?
  _check "C2 an out-of-range latitude is rejected" 1 "${rc}"
  rc=0; b4_coordinates_usable 10.0 -181.0 || rc=$?
  _check "C2b an out-of-range longitude is rejected" 1 "${rc}"
  rc=0; b4_coordinates_usable 10.0 134.5 || rc=$?
  _check "C2c a longitude beyond the latitude limit is still accepted" 0 "${rc}"

  # --- (C3) Non-numeric input must be rejected by the REGEX, before awk gets a
  #     chance to coerce it to 0 and call it in range.
  rc=0; b4_coordinates_usable abc 10.0 || rc=$?
  _check "C3 a non-numeric latitude is rejected" 1 "${rc}"
  rc=0; b4_coordinates_usable "" "" || rc=$?
  _check "C3b empty coordinates are rejected" 1 "${rc}"

  # --- (C4) THE VACUOUS-SEED FIXTURE. (0, 0) is what a simulator with no
  #     simulated location reports, so seeding it would make the lane unable to
  #     distinguish a delivered fix from no fix at all.
  rc=0; b4_coordinates_usable 0 0 || rc=$?
  _check "C4 the null island is refused as a seed" 1 "${rc}"
  rc=0; b4_coordinates_usable 0.0 12.5 || rc=$?
  _check "C4b a zero on ONE axis is still usable" 0 "${rc}"

  # --- (M1) The out-of-process proof marker, on a realistic passing log.
  local log="${tmp}/pass.log"
  {
    echo 'Xcode build done.                                           400.0s'
    echo '[b4] LOCATION_AUTH_OK status=LocationPermissionStatus.whileInUse'
    echo '[b4] PUBLISHED n=1'
    echo '[b4] PEER_DECRYPT_MATCH dLat=0.0 dLon=0.0 tol=1e-5'
    echo '🎉 1 test passed.'
  } > "${log}"
  rc=0; b4_proof_marker_present "${log}" || rc=$?
  _check "M1 a completed proof is detected" 0 "${rc}"

  # --- (M2) THE A3b FIXTURE. A run that reported success without ever reaching
  #     the proof — a skipped body, an early return, or a reporter that lied —
  #     must NOT pass. This is the only check that can see it.
  log="${tmp}/vacuous.log"
  {
    echo 'Xcode build done.                                           400.0s'
    echo '[b4] LOCATION_AUTH_OK status=LocationPermissionStatus.whileInUse'
    echo '🎉 1 test passed.'
  } > "${log}"
  rc=0; b4_proof_marker_present "${log}" || rc=$?
  _check "M2 a suite that passed WITHOUT the proof is refused" 1 "${rc}"

  # --- (M3) An absent or empty log is absence of evidence, never evidence.
  rc=0; b4_proof_marker_present "${tmp}/nope.log" || rc=$?
  _check "M3 a missing log is refused" 1 "${rc}"
  : > "${tmp}/empty.log"
  rc=0; b4_proof_marker_present "${tmp}/empty.log" || rc=$?
  _check "M3b an empty log is refused" 1 "${rc}"

  if (( fail != 0 )); then
    echo "run-b4-ios-real-gps.sh --self-test: FAILED" >&2
    return 1
  fi
  echo "run-b4-ios-real-gps.sh --self-test: all 17 fixtures passed (simctl" \
       "location/privacy support is probed not assumed and the two failure" \
       "modes are distinguished; coordinate seeds are range- and type-checked" \
       "and the null island is refused; and a run that exits 0 without" \
       "reaching its proof is refused)."
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
# receive path is compiled into the artifact, so the calling STEP has to state
# it rather than inherit one (CI_HARDENING_BACKLOG.md A7).
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

# The coordinates to seed AND to assert against — one value, one source, so the
# two can never disagree. South Pacific, both negative: far from anything, and
# the opposite hemisphere from every other sentinel in this repo, so a
# sign-dropping regression in the encode path cannot hide behind it.
GEO_LAT="${HAVEN_B4_GEO_LAT:--41.234567}"
GEO_LON="${HAVEN_B4_GEO_LON:--134.567890}"
GEO_TOLERANCE="${HAVEN_B4_GEO_TOLERANCE_DEG:-1e-5}"
readonly GEO_LAT GEO_LON GEO_TOLERANCE

if ! b4_coordinates_usable "${GEO_LAT}" "${GEO_LON}"; then
  echo "ERROR: HAVEN_B4_GEO_LAT/HAVEN_B4_GEO_LON are not a usable seed" >&2
  echo "       (got '${GEO_LAT}' / '${GEO_LON}'). They must be finite decimals" >&2
  echo "       within +/-90 and +/-180, and must not be (0, 0) — the null" >&2
  echo "       island is what a simulator with NO simulated location reports," >&2
  echo "       so seeding it would make this lane unable to tell a delivered" >&2
  echo "       fix from no fix at all." >&2
  exit 2
fi

readonly REPO_ROOT="${SCRIPT_DIR}/../../.."
readonly HAVEN_DIR="${REPO_ROOT}/haven"
readonly SIM_RUNNER="${SCRIPT_DIR}/run-ios-sim-scenario.sh"

[[ -f "${HAVEN_DIR}/${SCENARIO_FILE}" ]] \
  || { echo "ERROR: drive target not found: ${HAVEN_DIR}/${SCENARIO_FILE}" >&2; exit 2; }
[[ -f "${SIM_RUNNER}" ]] \
  || { echo "ERROR: shared runner not found: ${SIM_RUNNER}" >&2; exit 2; }

echo "B4 iOS real-GPS lane — udid=${SIM_UDID} relay=${RELAY_URL} live_sync=${LIVE_SYNC}"
echo "B4 — tolerance=${GEO_TOLERANCE} deg (coordinates are not echoed here)"

# --- Preflight: can THIS Xcode seed a location and grant location privacy? ---
LOCATION_USAGE="$(xcrun simctl help location 2>&1 || true)"
set +e
b4_simctl_supports_location_set "${LOCATION_USAGE}"
LOC_RC=$?
set -e
case "${LOC_RC}" in
  0)
    echo "B4 preflight — 'xcrun simctl location' offers the 'set' action."
    ;;
  1)
    echo "ERROR: this runner's 'xcrun simctl location' does NOT offer a 'set'" >&2
    echo "       action, so no real fix can be seeded and this lane cannot be" >&2
    echo "       run. 'simctl location ... set' has shipped since Xcode 14, so" >&2
    echo "       a runner without it has regressed below that." >&2
    echo "       Do NOT paper over this by injecting a fake position — that is" >&2
    echo "       exactly the hole B4 exists to close. Raise the runner image /" >&2
    echo "       Xcode version. The only real substitute" >&2
    echo "       (MobileNativeFoundation/set-simulator-location, which drives" >&2
    echo "       the same private XPC service) would add an unvetted binary to" >&2
    echo "       a security-sensitive CI and is the worse trade." >&2
    printf '%s\n' "${LOCATION_USAGE}" | sed 's/^/       /' >&2
    exit 2
    ;;
  *)
    echo "ERROR: could not parse 'xcrun simctl help location' output — the" >&2
    echo "       preflight cannot tell 'set is unsupported' from 'the probe is" >&2
    echo "       broken', and guessing either way is worse than stopping." >&2
    printf '%s\n' "${LOCATION_USAGE}" | sed 's/^/       /' >&2
    exit 2
    ;;
esac

PRIVACY_USAGE="$(xcrun simctl help privacy 2>&1 || true)"
set +e
b4_simctl_supports_location_privacy "${PRIVACY_USAGE}"
PRIV_RC=$?
set -e
case "${PRIV_RC}" in
  0)
    echo "B4 preflight — 'xcrun simctl privacy' offers the 'location' service."
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
    echo "ERROR: could not parse 'xcrun simctl help privacy' output." >&2
    printf '%s\n' "${PRIVACY_USAGE}" | sed 's/^/       /' >&2
    exit 2
    ;;
esac

cd "${HAVEN_DIR}"

# --- Build ONCE. -------------------------------------------------------------
# The .app must exist BEFORE the grant, because `simctl privacy grant` resolves
# the bundle id against the simulator's installed apps. The delegated
# `flutter test` below rebuilds incrementally from the same derived data, so
# this costs one cold Xcode+Rust build for the lane rather than two.
#
# The expected coordinates are baked in here AND forwarded to the delegated
# build (below) from the same variables, so the seed and the assertion can never
# disagree.
#
# The build is deliberately NOT bounded here: a hung or failed build is
# deterministic, and the caller's retry timeout is the backstop (the same stance
# run-ios-sim-scenario.sh's first-test watchdog takes when it declines to watch
# the build).
echo "B4 — building the drive target once for the simulator ..."
flutter build ios \
  --simulator \
  --debug \
  --target "${SCENARIO_FILE}" \
  --dart-define=HAVEN_E2E_RELAY="${RELAY_URL}" \
  --dart-define=HAVEN_LIVE_SYNC="${LIVE_SYNC}" \
  --dart-define=HAVEN_B4_GEO_LAT="${GEO_LAT}" \
  --dart-define=HAVEN_B4_GEO_LON="${GEO_LON}" \
  --dart-define=HAVEN_B4_GEO_TOLERANCE_DEG="${GEO_TOLERANCE}"

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
echo "B4 — built ${APP_PATH}"

# --- Prepare the simulator: uninstall -> install -> grant -> seed. -----------
# The uninstall is the hermetic wipe run-ios-sim-scenario.sh normally performs
# (a stale, differently-keyed haven_mdk.db in the data container fails every
# scenario deterministically); doing it HERE, before the grant, is what lets the
# grant survive to first launch.
xcrun simctl uninstall "${SIM_UDID}" "${BUNDLE_ID}" >/dev/null 2>&1 || true

if ! xcrun simctl install "${SIM_UDID}" "${APP_PATH}"; then
  echo "ERROR: could not install ${APP_PATH} on ${SIM_UDID}." >&2
  exit 2
fi

# A refused grant must be FATAL. `simctl privacy` exits non-zero on a bad
# service or an unknown bundle id, and everything below is downstream of it —
# `|| true` here would be another instance of this repo's recurring "guard
# passes vacuously" failure, and would present at runtime as an app hanging on
# a system prompt nobody can answer.
if ! xcrun simctl privacy "${SIM_UDID}" grant location "${BUNDLE_ID}"; then
  echo "ERROR: 'xcrun simctl privacy ${SIM_UDID} grant location ${BUNDLE_ID}'" >&2
  echo "       failed. Authorization was never granted, so the app would stall" >&2
  echo "       on an unanswerable CoreLocation prompt. The likeliest cause is" >&2
  echo "       the install above not having landed — the grant resolves the" >&2
  echo "       bundle id against INSTALLED apps." >&2
  exit 2
fi
echo "B4 — granted When-In-Use location to ${BUNDLE_ID}"

# Device state, not app state: it persists until `clear`/shutdown and survives
# the re-install the delegated `flutter test` performs, which is why (unlike
# B3's `adb emu geo fix`) one call is enough and no re-issue loop exists here.
if ! xcrun simctl location "${SIM_UDID}" set "${GEO_LAT},${GEO_LON}"; then
  echo "ERROR: 'xcrun simctl location ${SIM_UDID} set <lat>,<lon>' failed, so" >&2
  echo "       the simulator has no simulated position and CoreLocation would" >&2
  echo "       deliver nothing." >&2
  exit 2
fi
echo "B4 — seeded the simulator location (value withheld from the log)"

# --- Drive. -----------------------------------------------------------------
# Delegated so the first-test watchdog, the narrowed retry gate (A6) and the
# secret-leak scan are inherited rather than reimplemented.
# HAVEN_E2E_IOS_SKIP_UNINSTALL is the one opt-in this lane needs from the shared
# runner: its own uninstall would erase the grant made three lines above.
set +e
HAVEN_LIVE_SYNC="${LIVE_SYNC}" \
HAVEN_E2E_RELAY="${RELAY_URL}" \
HAVEN_E2E_NO_BACKGROUND="true" \
HAVEN_E2E_IOS_SKIP_UNINSTALL=1 \
HAVEN_B4_GEO_LAT="${GEO_LAT}" \
HAVEN_B4_GEO_LON="${GEO_LON}" \
HAVEN_B4_GEO_TOLERANCE_DEG="${GEO_TOLERANCE}" \
  bash "${SIM_RUNNER}" "${SCENARIO_FILE}" "${SIM_UDID}"
DRIVE_RC=$?
set -e

# Preserve the log under this lane's own name for the artifact upload, before
# anything else can overwrite the shared path.
cp /tmp/flutter-ios-test.log "${B4_LOG}" 2>/dev/null || true

if (( DRIVE_RC != 0 )); then
  echo "ERROR: the B4 iOS real-GPS drive failed (rc=${DRIVE_RC})." >&2
  exit "${DRIVE_RC}"
fi

# --- The out-of-process oracle (A3b). ---------------------------------------
if ! b4_proof_marker_present "${B4_LOG}"; then
  echo "ERROR: the drive exited 0 but never printed '${PROOF_MARKER}', so it" >&2
  echo "       did not reach the end of its proof. A 'flutter test' can report" >&2
  echo "       success over a body that was skipped or returned early" >&2
  echo "       (CI_HARDENING_BACKLOG.md A3b), and the marker is printed only" >&2
  echo "       AFTER every coordinate assertion has passed — so this is the" >&2
  echo "       only check that can see it. Look for a self-skip, an early" >&2
  echo "       return, or a renamed marker (the literal lives in this script" >&2
  echo "       and in haven/${SCENARIO_FILE}; change them together)." >&2
  exit 1
fi

echo ""
echo "B4 — PASSED: a real CoreLocation fix seeded with 'simctl location set'" \
     "reached a peer through the production publisher and the hermetic relay," \
     "and the peer's decrypt matched it within ${GEO_TOLERANCE} degrees."
