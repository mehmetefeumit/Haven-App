#!/usr/bin/env bash
#
# B1 runtime-proof orchestrator for the `e2e-fgs-publish` CI lane
# (docs/CI_HARDENING_BACKLOG.md Workstream B, item B1 — "FGS-with-live-foreground").
#
# ## What this lane exists to catch (P0-1)
#
# Backgrounding Haven on Android stops the main-isolate publish scheduler and
# hands publishing off to the flutter_foreground_task FGS isolate. That isolate
# then calls `CircleManagerFfi.newInstance` while the FOREGROUND
# `NostrCircleService` still holds the Rule-14 `LiveSessionGuard` — and both
# isolates share ONE OS process (no `android:process` in AndroidManifest.xml),
# therefore one Rust `LIVE_SESSIONS` registry. The acquire fails closed, the
# error is swallowed (`onStart FAILED`), `_circleManager` stays null, and every
# subsequent publish cycle returns immediately. `onStart` runs once; no retry.
#
# The defect was found by static analysis and adversarially re-verified, but had
# NEVER been observed at runtime, because nothing in CI ever ran the FGS publish
# path at all. The `e2e-background-catchup` lane looks like coverage but is not:
# it force-runs the WorkManager CATCH-UP worker (a receive-only, separate-process
# mechanism) and its `go_cold` helper kills the app (`am kill`) before waking it,
# so the foreground session is gone — which is precisely the contention this lane
# needs to preserve.
#
# ## The oracle
#
#   1. ASSERT the drive delivered the lifecycle pause (`[b1] PAUSE_DELIVERED`)
#      AND that the handoff completed (`[b1] HANDOFF_CONFIRMED`).
#   2. ASSERT `[BackgroundTask] Initialized (… locationSharing=true)` PRESENT
#      and `onStart FAILED` ABSENT.
#   3. ASSERT `Published to N/M due circle(s)` with N >= 1, WINDOWED to after
#      the pause and PARSED, never grepped.
#   4. ASSERT the publishing PID equals the PID that handed off.
#
# Each step exists to close a specific false-green route found in adversarial
# review:
#
# * Step 2 is POSITIVE. An earlier revision waited for the `onStart (starter=`
#   entry marker and then grepped for the ABSENCE of the failure marker — but
#   the entry marker prints at the top of `onStart`, before RustLib, the
#   keyring, and `CircleManagerFfi.newInstance`, so the absence check could read
#   seconds before the failure it was looking for. `Initialized (…
#   locationSharing=true)` is emitted only once the manager exists, so it proves
#   the Rule-14 acquire succeeded rather than merely failing to observe it.
#
# * Step 3 is windowed because a publish emitted while the UI was still
#   foregrounded is not the thing under test — it is a Rule-14 single-writer
#   violation, and counting it as success would invert the lane's meaning. N is
#   parsed because `Published to 0/1` is P0-1's own signature and contains the
#   marker substring.
#
# * Step 4 is the anti-vacuity check and the most important line in the file.
#   The FGS's foreground-active gate goes stale after 144s, so if the app
#   process dies and Android restarts the START_STICKY service into a FRESH
#   process, the acquire trivially succeeds and steps 2 and 3 both pass with NO
#   foreground session in existence — green while proving nothing. Same PID
#   means same Rust `LIVE_SESSIONS` registry, which is what makes the contention
#   real.
#
# There is deliberately NO relay-side line-count check; see the note at the foot
# of Phase 5 for why one was removed rather than kept as decoration.
#
# EXPECT THIS LANE TO FAIL ON ITS FIRST RUN. That is the deliverable: it converts
# P0-1 from static analysis into a reproducible red. Do not "fix" it by relaxing
# an assertion — see CLAUDE.md, Testing Requirements #5.
#
# Usage:
#   run-b1-fgs-publish.sh <apk> <target.dart>   run the lane (needs emulator-5554)
#   run-b1-fgs-publish.sh --self-test           hermetic predicate self-test
#
set -Eeuo pipefail

# ---------------------------------------------------------------------------
# VERBATIM markers (haven/lib/src/services/background_location_task.dart).
# Kept as fixed literals matched with `grep -aF`: logcat is binary-tainted and
# these strings contain regex metacharacters.
# ---------------------------------------------------------------------------
readonly MARK_ONSTART_FAILED='[BackgroundTask] onStart FAILED'
# The TERMINAL success outcome of onStart. The `onStart (starter=` entry line is
# deliberately NOT a constant here, because it is deliberately NOT asserted on:
# it prints at the TOP
# of onStart (background_location_task.dart:141), before RustLib.init, the
# keyring, the data dir, the identity load and `CircleManagerFfi.newInstance` —
# seconds of emulator work. Keying the oracle on it and then grepping for the
# ABSENCE of the failure marker reads inside that window and can pass while the
# failure is still in flight. This marker is emitted only after ALL of that
# succeeded (:240-244), and `locationSharing=true` is only constructible when
# `_circleManager != null` (:218-230) — i.e. when the Rule-14 acquire WORKED.
# That makes it a POSITIVE oracle for P0-1 rather than an absence check.
readonly MARK_INITIALIZED='[BackgroundTask] Initialized ('
readonly MARK_LOCSHARING_OK='locationSharing=true'
readonly MARK_PUBLISHED_PREFIX='[BackgroundTask] Published to '
readonly MARK_CYCLE_FAILED='[BackgroundTask] Publish cycle FAILED'
readonly MARK_ONDESTROY='[BackgroundTask] onDestroy'
# Emitted by the drive target at the instant it delivers a REAL
# AppLifecycleState.paused to MapShell's own observer, running the production
# `_onPaused()` handoff. MUST match `kPauseDeliveredMarker` in
# haven/integration_test/b1_fgs_live_foreground_test.dart VERBATIM.
readonly MARK_PAUSE='[b1] PAUSE_DELIVERED'
# Strictly later: printed only once the drive has itself confirmed, by polling
# real SharedPreferences, that `kForegroundActiveAtMsKey` actually reached 0 —
# i.e. that `_onPaused()` ran to COMPLETION rather than merely being dispatched.
# This, not the pause itself, is the moment the FGS's gate-3 foreground check
# stops rejecting it, so it is the correct window start for the publish oracle:
# windowing from the dispatch instead would open the window before the FGS was
# permitted to publish at all. Mirrors `kHandoffConfirmedMarker`.
readonly MARK_HANDOFF_OK='[b1] HANDOFF_CONFIRMED'

# Extract the publish COUNT (N of "Published to N/M due circle(s)") from the
# highest-N line in a log. Emits nothing when no line matches; callers treat
# empty as "no publish cycle has reported yet".
#
# Highest-N rather than last-N: the FGS logs one line per cycle and a later
# cycle can legitimately report 0 (nothing due yet on its independent per-circle
# jittered schedule — see `PerCircleDueTracker`). Taking the last line would
# make a genuine success flap on cycle timing.
max_published_count() {
  local logfile="$1"
  { grep -aoE 'Published to [0-9]+/[0-9]+ due circle' "${logfile}" 2>/dev/null \
      | grep -aoE '[0-9]+/' | tr -d '/' | sort -n | tail -1; } || true
}

# Print every line from the FIRST occurrence of <marker> to EOF.
#
# The publish oracle MUST be windowed to after the foreground handoff. Grepping
# the whole capture would accept a publish emitted while the UI was still
# foregrounded — which is not the thing under test, and is in fact a Rule-14
# single-writer violation being counted as success. `index()` rather than a
# regex: the markers contain `[`, `(` and other metacharacters.
window_after_marker() {
  local logfile="$1" marker="$2"
  awk -v m="${marker}" 'index($0, m) { f = 1 } f' "${logfile}" 2>/dev/null || true
}

# Print the PID column of the first line containing <marker>.
#
# `logcat -v threadtime` columns: date time PID TID LEVEL TAG: message.
# Used to prove the FGS publish came from the SAME OS process as the drive's
# own foreground isolate — see the caller for why that is the load-bearing
# anti-vacuity check in this lane.
pid_of_marker() {
  local logfile="$1" marker="$2"
  { awk -v m="${marker}" 'index($0, m) { print $3; exit }' "${logfile}" 2>/dev/null; } || true
}

# ---------------------------------------------------------------------------
# --self-test — validate max_published_count against synthetic fixtures WITHOUT
# a device (mirrors run-single-avd-scenario.sh / scan-logs-for-secrets.sh). CI
# gates the parser through this in the fast repo-guards job so it can never
# silently rot into a parser that accepts the failing case.
#
# Runs BEFORE the EXIT trap is installed: the trap tears down docker/strfry,
# which a hermetic self-test must never touch.
# ---------------------------------------------------------------------------
run_self_test() {
  local tmp fail=0 got
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  # (1) THE CRITICAL FIXTURE — P0-1's actual signature. The marker substring is
  #     present but the count is 0. A `grep -q 'Published to'` oracle would pass
  #     here; the parser MUST report 0 so the caller fails the lane.
  printf '%s\n' \
    '08-02 04:41:02.001  1234  1300 I flutter : [BackgroundTask] onStart (starter=developer)' \
    '08-02 04:42:14.552  1234  1300 I flutter : [BackgroundTask] Published to 0/1 due circle(s) (1 eligible), fetched 0/1 circle(s).' \
    > "${tmp}/zero.log"
  got="$(max_published_count "${tmp}/zero.log")"
  if [[ "${got}" != "0" ]]; then
    echo "SELF-TEST FAIL (1): expected 0 from a 0/1 line, got '${got}'" >&2
    fail=1
  fi

  # (2) TRUE POSITIVE — a real publish.
  printf '%s\n' \
    '08-02 04:42:14.552  1234  1300 I flutter : [BackgroundTask] Published to 1/1 due circle(s) (1 eligible), fetched 1/1 circle(s).' \
    > "${tmp}/one.log"
  got="$(max_published_count "${tmp}/one.log")"
  if [[ "${got}" != "1" ]]; then
    echo "SELF-TEST FAIL (2): expected 1, got '${got}'" >&2
    fail=1
  fi

  # (3) MULTI-CYCLE — a later cycle reporting 0 (nothing due on its own jittered
  #     schedule) must NOT mask an earlier real publish. Guards the "last line
  #     wins" bug that would make a passing lane flap on cycle timing.
  printf '%s\n' \
    '08-02 04:42:14.552  1234  1300 I flutter : [BackgroundTask] Published to 2/2 due circle(s) (2 eligible), fetched 2/2 circle(s).' \
    '08-02 04:43:26.552  1234  1300 I flutter : [BackgroundTask] Published to 0/0 due circle(s) (2 eligible), fetched 0/2 circle(s).' \
    > "${tmp}/multi.log"
  got="$(max_published_count "${tmp}/multi.log")"
  if [[ "${got}" != "2" ]]; then
    echo "SELF-TEST FAIL (3): expected 2 across cycles, got '${got}'" >&2
    fail=1
  fi

  # (4) EMPTY — no publish line at all yields empty, never a spurious 0 that a
  #     caller could confuse with "cycle ran and published nothing".
  printf '%s\n' \
    '08-02 04:41:02.001  1234  1300 I flutter : [BackgroundTask] onStart (starter=developer)' \
    > "${tmp}/none.log"
  got="$(max_published_count "${tmp}/none.log")"
  if [[ -n "${got}" ]]; then
    echo "SELF-TEST FAIL (4): expected empty from a log with no publish line, got '${got}'" >&2
    fail=1
  fi

  # (5) DOUBLE-DIGIT — the parser must not truncate or mis-sort N >= 10
  #     (a plain lexical sort ranks '9' above '12').
  printf '%s\n' \
    '08-02 04:42:14.552  1234  1300 I flutter : [BackgroundTask] Published to 9/12 due circle(s) (12 eligible), fetched 9/12 circle(s).' \
    '08-02 04:43:26.552  1234  1300 I flutter : [BackgroundTask] Published to 12/12 due circle(s) (12 eligible), fetched 12/12 circle(s).' \
    > "${tmp}/wide.log"
  got="$(max_published_count "${tmp}/wide.log")"
  if [[ "${got}" != "12" ]]; then
    echo "SELF-TEST FAIL (5): expected 12, got '${got}'" >&2
    fail=1
  fi

  # --- window_after_marker + pid_of_marker ---------------------------------
  # These two carry the lane's anti-vacuity checks (post-handoff windowing and
  # same-process proof), so they get fixtures of their own rather than being
  # trusted because they look obvious.
  printf '%s\n' \
    '08-02 04:40:00.000  1111  1120 I flutter : [BackgroundTask] Published to 9/9 due circle(s) (9 eligible), fetched 9/9 circle(s).' \
    '08-02 04:41:00.000  1111  1130 I flutter : [b1] HANDOFF_CONFIRMED' \
    '08-02 04:42:14.552  1111  1140 I flutter : [BackgroundTask] Published to 1/1 due circle(s) (1 eligible), fetched 1/1 circle(s).' \
    > "${tmp}/window.log"

  # (6) A publish from BEFORE the handoff must not count. Without the window
  #     the parser would return 9 and the lane would pass on a foreground
  #     publish — which is a Rule-14 single-writer violation, not a success.
  got="$(window_after_marker "${tmp}/window.log" '[b1] HANDOFF_CONFIRMED' \
    | { max_published_count /dev/stdin; })"
  if [[ "${got}" != "1" ]]; then
    echo "SELF-TEST FAIL (6): windowed count should be 1 (post-handoff), got '${got}'" >&2
    fail=1
  fi

  # (7) No marker at all ⇒ empty window, so a missing handoff can never be
  #     silently treated as "the whole log counts".
  got="$(window_after_marker "${tmp}/window.log" '[b1] NEVER_HAPPENED' | wc -l | tr -d ' ')"
  if [[ "${got}" != "0" ]]; then
    echo "SELF-TEST FAIL (7): a missing marker must yield an empty window, got ${got} line(s)" >&2
    fail=1
  fi

  # (8) PID extraction from the `logcat -v threadtime` column layout.
  got="$(pid_of_marker "${tmp}/window.log" '[b1] HANDOFF_CONFIRMED')"
  if [[ "${got}" != "1111" ]]; then
    echo "SELF-TEST FAIL (8): expected PID 1111, got '${got}'" >&2
    fail=1
  fi

  # (9) A restarted service logs under a DIFFERENT pid — the false-green route
  #     step 4 exists to catch. The extractor must report that difference.
  printf '%s\n' \
    '08-02 04:41:00.000  1111  1130 I flutter : [b1] HANDOFF_CONFIRMED' \
    '08-02 04:44:00.000  2222  2230 I flutter : [BackgroundTask] Published to 1/1 due circle(s) (1 eligible), fetched 1/1 circle(s).' \
    > "${tmp}/restart.log"
  if [[ "$(pid_of_marker "${tmp}/restart.log" '[b1] HANDOFF_CONFIRMED')" == \
        "$(pid_of_marker "${tmp}/restart.log" '[BackgroundTask] Published to ')" ]]; then
    echo "SELF-TEST FAIL (9): a cross-process publish was reported as same-PID" >&2
    fail=1
  fi

  if (( fail != 0 )); then
    echo "run-b1-fgs-publish.sh --self-test: FAILED" >&2
    return 1
  fi
  echo "run-b1-fgs-publish.sh --self-test: all 9 fixtures passed"
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
readonly LOG_DIR="/tmp/b1-logs"
readonly APK="${1:-/tmp/integration-apks/b1_fgs_live_foreground_test.apk}"
readonly TARGET="${2:-integration_test/b1_fgs_live_foreground_test.dart}"

# The drive now owns the whole timeline: arm, deliver the lifecycle pause, and
# HOLD the widget tree mounted while the FGS runs its cycles (the tree must stay
# up, or flutter_test's post-test unmount stops the service — see Phase 4). So
# this bounds arming + the FGS master tick (kBackgroundRepeatInterval = 72s,
# haven/lib/src/constants/location.dart:98) x2, plus RustLib/keyring/SQLCipher
# boot under the emulator's mlock pressure, plus GPS and relay slack. The shell
# holds no timeouts of its own any more — by the time it reads, the capture is
# complete, so Phase 5 is a set of reads rather than live polls.
readonly DRIVE_TIMEOUT="${B1_DRIVE_TIMEOUT:-18m}"

# Synthetic coordinates fed to the emulator's GPS: Dam Square, Amsterdam — a
# well-known public landmark, chosen precisely BECAUSE it is obviously not a
# real user's position. The kind-445 carrying it is MLS-encrypted on the wire.
#
# WARNING before overriding these: `fail()` dumps `dumpsys location`, which
# PRINTS the active position into the step log and the uploaded artifact. That
# is fine for a hardcoded landmark and NOT fine for anything derived from a real
# device or person. If backlog B3/B4 make coordinates assertion-relevant, keep
# them synthetic or drop the location dump.
readonly GEO_LON="${B1_GEO_LON:-4.895168}"
readonly GEO_LAT="${B1_GEO_LAT:-52.370216}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR="${script_dir}"
readonly REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
readonly HAVEN_DIR="${REPO_ROOT}/haven"
readonly START_STRFRY="${SCRIPT_DIR}/start-strfry.sh"
readonly STOP_STRFRY="${SCRIPT_DIR}/stop-strfry.sh"
readonly SECRET_SCAN="${SCRIPT_DIR}/scan-logs-for-secrets.sh"

LOGCAT_PID=""
GEO_PID=""

mkdir -p "${LOG_DIR}"
readonly LOGCAT_FILE="${LOG_DIR}/logcat.b1.log"
readonly DRIVE_LOG="${LOG_DIR}/flutter-drive.log"

# ---------------------------------------------------------------------------
# Cleanup (EXIT trap): stop the background helpers, run the MANDATORY secret
# scan over every captured log (Security Rule 6 — must run even on a phase
# failure), snapshot + tear down strfry. Escalates on a leak; never masks a
# phase rc.
# ---------------------------------------------------------------------------
cleanup() {
  local rc=$?
  trap - EXIT
  if [[ -n "${GEO_PID}" ]] && kill -0 "${GEO_PID}" 2>/dev/null; then
    kill "${GEO_PID}" 2>/dev/null || true
  fi
  if [[ -n "${LOGCAT_PID}" ]] && kill -0 "${LOGCAT_PID}" 2>/dev/null; then
    kill "${LOGCAT_PID}" 2>/dev/null || true
  fi
  docker logs strfry > "${LOG_DIR}/strfry.final.log" 2>&1 || true
  echo "== Secret-leak scan over ${LOG_DIR} (Security Rule 6) =="
  if ! bash "${SECRET_SCAN}" "${LOG_DIR}"; then
    # CONTAINMENT, not just detection. The workflow uploads ${LOG_DIR} with
    # `if: always()` and a 14-day retention, so merely going red here would
    # publish the leaking log for a fortnight — the guard would tell us about
    # the leak while shipping it. Destroy the logs and leave a marker instead;
    # the scanner has already printed file + label + line numbers (never the
    # matched content), which is everything triage needs.
    find "${LOG_DIR}" -type f -name '*.log' -delete 2>/dev/null || true
    {
      echo "Logs withheld: the secret-leak guard tripped (Security Rule 6)."
      echo "See the LEAK line(s) in the step log for file/label/line numbers."
    } > "${LOG_DIR}/LEAK_DETECTED.txt"
    echo "ERROR: secret-leak guard tripped on B1 logs — logs deleted, not uploaded." >&2
    rc=1
  fi
  bash "${STOP_STRFRY}" >/dev/null 2>&1 || true
  exit "${rc}"
}
trap cleanup EXIT

fail() {
  echo "B1-LANE-FAIL: $*" >&2
  echo "---- [BackgroundTask] lines seen ----" >&2
  grep -aF '[BackgroundTask]' "${LOGCAT_FILE}" 2>/dev/null | tail -40 >&2 || \
    echo "(none — the FGS isolate logged nothing at all)" >&2
  # Emulator location state. B1 is the FIRST lane to need a REAL position (every
  # other scenario injects FakeLocationService), so a silent GPS failure is a
  # live risk and would otherwise present as an unattributed publish timeout.
  # Two known traps: `adb emu geo fix` is a ONE-SHOT injection into the goldfish
  # GNSS HAL with no stream between injections (hence the re-issue loop), and the
  # AVD runs a `google_apis` image where geolocator may resolve to FUSED location
  # while `geo fix` documents only the LocationManager provider.
  echo "---- emulator location state ----" >&2
  adb -s "${DEVICE}" shell dumpsys location 2>/dev/null \
    | grep -aiA 4 'last location\|fused\|gps provider' | head -40 >&2 || \
    echo "(dumpsys location unavailable)" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# Phase 0 — hermetic relay + device readiness.
# ---------------------------------------------------------------------------
echo "Phase 0/5 — starting hermetic strfry..."
bash "${START_STRFRY}"
adb -s "${DEVICE}" wait-for-device
echo "Phase 0/5 — device ready."

# ---------------------------------------------------------------------------
# Phase 1 — clean install. Force-stop + uninstall FIRST so no sticky FGS from a
# prior target survives into this run (see run-single-avd-scenario.sh Phase 2).
# ---------------------------------------------------------------------------
echo "Phase 1/5 — installing ${APK}..."
[[ -f "${APK}" ]] || fail "APK not found: ${APK} (was the build step skipped?)"
adb -s "${DEVICE}" shell am force-stop "${PKG}" || true
adb -s "${DEVICE}" uninstall "${PKG}" >/dev/null 2>&1 || true
adb -s "${DEVICE}" install -r "${APK}"

# ---------------------------------------------------------------------------
# Phase 2 — runtime permissions, plus the ACCESS_BACKGROUND_LOCATION PROBE.
#
# The probe answers a question the repo has been carrying as an untested
# assertion: `run-single-avd-scenario.sh:323` and `docs/M7_BACKGROUND_SHARING.md`
# both state that `pm grant` cannot grant ACCESS_BACKGROUND_LOCATION on API 30+.
# It is recorded as EVIDENCE (grant attempt + authoritative read-back), never as
# a gate: this lane must not turn red over a diagnostic. See the lane's docs
# entry for the verdict once a run has published one.
#
# B1 itself should not NEED background location: the FGS declares
# `foregroundServiceType="location"`, which is what keeps location flowing while
# the UI is hidden. The probe exists to settle the claim and to explain the
# failure fast if that assumption turns out to be wrong.
# ---------------------------------------------------------------------------
echo "Phase 2/5 — granting runtime permissions..."
for perm in \
  android.permission.ACCESS_FINE_LOCATION \
  android.permission.ACCESS_COARSE_LOCATION \
  android.permission.POST_NOTIFICATIONS
do
  if adb -s "${DEVICE}" shell pm grant "${PKG}" "${perm}"; then
    echo "  granted ${perm}"
  else
    fail "could not grant ${perm} — the lane cannot acquire a GPS fix without it."
  fi
done

# --- ACCESS_BACKGROUND_LOCATION probe ---------------------------------------
#
# `pm grant`'s EXIT CODE IS WORTHLESS HERE. ACCESS_BACKGROUND_LOCATION is a
# hardRestricted permission in AOSP (`core/res/AndroidManifest.xml`, unchanged
# across android11..android15), and the gate in
# `PermissionManagerServiceImpl.grantRuntimePermissionInternal` is a bare
# `return` after a `Log.e` — no exception, no non-zero exit. A silently-failed
# grant is textually identical to a successful one.
#
# It is nevertheless expected to SUCCEED here: `adb install` goes through
# `PackageManagerShellCommand.makeInstallParams()`, which sets
# INSTALL_ALL_WHITELIST_RESTRICTED_PERMISSIONS by default (only the explicit
# `--restrict-permissions` flag clears it), so the package is installer-exempt
# and the hard-restricted gate passes. The long-standing claim in this repo that
# `pm grant` "cannot grant it on API 30+" conflated that with the SEPARATE
# Android 11 runtime-API rule that an app cannot REQUEST background location in
# the same `requestPermissions()` call as foreground location. `pm grant` never
# enters `GrantPermissionsActivity`, so that rule does not apply to it.
#
# Recorded as EVIDENCE, never as a gate: B1 should not need this permission at
# all, because the FGS is started while the activity is VISIBLE and
# `foregroundServiceType="location"` carries location access from there. The
# permission matters for the FGS-on-BOOT path (API 34+ refuses to create a
# `location` FGS from the background without it), which this lane does not test.
#
# The app-op read-back is POLLED, not read once: PermissionPolicyService
# synchronises the permission→app-op mapping asynchronously on FgThread, so an
# immediate read can still show `foreground` on a grant that did land.
echo "== SPIKE PROBE: ACCESS_BACKGROUND_LOCATION on API $(adb -s "${DEVICE}" shell getprop ro.build.version.sdk | tr -d '\r') =="
adb -s "${DEVICE}" shell pm grant "${PKG}" android.permission.ACCESS_BACKGROUND_LOCATION 2>&1 \
  | sed 's/^/    /' || true
echo "  read-back (dumpsys package — authoritative grant state):"
adb -s "${DEVICE}" shell dumpsys package "${PKG}" 2>/dev/null \
  | grep -a "ACCESS_BACKGROUND_LOCATION" | sed 's/^/    /' \
  || echo "    (permission not listed)"
echo "  read-back (appops — polled, expect 'allow' not 'foreground'):"
probe_deadline=$(( SECONDS + 30 ))
while (( SECONDS < probe_deadline )); do
  probe_ops="$(adb -s "${DEVICE}" shell cmd appops get "${PKG}" 2>/dev/null \
    | grep -aiE 'COARSE_LOCATION|FINE_LOCATION' || true)"
  if [[ "${probe_ops}" == *allow* ]]; then
    break
  fi
  sleep 3
done
echo "${probe_ops:-    (no location app-ops reported)}" | sed 's/^/    /'
echo "  authoritative failure signal (expect NO match):"
adb -s "${DEVICE}" logcat -d 2>/dev/null \
  | grep -a "Cannot grant hard restricted non-exempt permission" | sed 's/^/    /' \
  || echo "    (none — the hard-restricted gate did not reject the grant)"
echo "== END SPIKE PROBE =="

# ---------------------------------------------------------------------------
# Phase 3 — feed the emulator a GPS fix, and keep feeding it.
#
# The FGS isolate uses the REAL GeolocatorLocationService (overrides injected in
# the drive isolate do not reach it), and `_publishCycle` takes a ONE-SHOT
# `getCurrentLocation()` per due circle. `adb emu geo fix` sets the emulated
# position, but a single fix can age out before the cycle that needs it, so it
# is re-issued on a short loop for the life of the lane.
#
# NOTE the argument order: `geo fix` takes LONGITUDE first, then LATITUDE.
# ---------------------------------------------------------------------------
echo "Phase 3/5 — seeding emulator GPS (lon=${GEO_LON} lat=${GEO_LAT})..."
adb -s "${DEVICE}" emu geo fix "${GEO_LON}" "${GEO_LAT}"
(
  while sleep 10; do
    adb -s "${DEVICE}" emu geo fix "${GEO_LON}" "${GEO_LAT}" >/dev/null 2>&1 || true
  done
) &
GEO_PID=$!

# ---------------------------------------------------------------------------
# Phase 4 — drive the target, then hand off.
#
# `--keep-app-running` is LOAD-BEARING. Without it `flutter drive` (with
# --use-application-binary) stops the app on completion, and on Android that is
# `adb shell am force-stop` — which kills the foreground service this entire
# lane is about to observe, AND releases the foreground MLS session whose
# retention is the precondition for P0-1. The lane would then pass vacuously.
# ---------------------------------------------------------------------------
echo "Phase 4/5 — capturing logcat and driving ${TARGET}..."
adb -s "${DEVICE}" logcat -c || true
adb -s "${DEVICE}" logcat -v threadtime > "${LOGCAT_FILE}" 2>&1 &
LOGCAT_PID=$!

drc=0
( cd "${HAVEN_DIR}" && timeout --kill-after=30s "${DRIVE_TIMEOUT}" flutter drive \
    --no-pub \
    --keep-app-running \
    --device-id "${DEVICE}" \
    --use-application-binary "${APK}" \
    --driver "${DRIVER_FILE}" \
    --target "${TARGET}" ) > "${DRIVE_LOG}" 2>&1 || drc=$?
# Scan BEFORE echoing. The EXIT trap's scan runs far too late to protect this:
# GitHub Actions step logs have no retention control and cannot be redacted
# after the fact, so an unscanned `cat` of the drive log is a wider, more
# permanent sink than the artifact upload the trap does guard.
if bash "${SECRET_SCAN}" "${DRIVE_LOG}"; then
  cat "${DRIVE_LOG}" || true
else
  echo "drive log withheld from the step log — secret-leak guard tripped." >&2
fi
if (( drc != 0 )); then
  fail "drive of ${TARGET} failed (rc=${drc}) — the app was never armed."
fi

# NOTE: no `input keyevent HOME` here, and that is deliberate.
#
# An earlier revision pressed HOME after the drive and expected MapShell's real
# `_onPaused()` to fire. It cannot: `flutter_test` unmounts the widget tree on a
# PASSING test (`binding.dart:1684-1691`, `runApp(Container(...)) // Unmount any
# remaining widgets`), which disposes the ProviderScope, fires
# `backgroundServiceLifecycleProvider`'s `ref.onDispose(() => fns.stop())`, and
# removes MapShell's lifecycle observer — so by the time the drive exits, the
# FGS is already stopped and nothing is listening for the pause. The handoff now
# happens INSIDE the drive, which delivers a genuine AppLifecycleState.paused
# while the tree is still mounted and the foreground MLS session still held.
echo "Phase 4/5 — drive complete; the handoff and publish window ran inside it."

# ---------------------------------------------------------------------------
# Phase 5 — the oracle.
#
# Everything asserted here already happened during the drive, so these are
# reads over a complete capture rather than live polls.
# ---------------------------------------------------------------------------
echo "Phase 5/5 — asserting the FGS publish path..."

# (1) The handoff actually happened. Every later assertion is windowed to it, so
#     without this the window is the whole capture and (3) loses its meaning.
if ! grep -aqF -- "${MARK_PAUSE}" "${LOGCAT_FILE}" 2>/dev/null; then
  fail "the drive never delivered the lifecycle pause (no '${MARK_PAUSE}'). The \
foreground never handed off, so the FGS was gated out of publishing for the whole run \
and this lane proved nothing."
fi
# Dispatched is not the same as took-effect. `_onPaused()` is async and writes
# the handoff flag several awaits in; until it lands, the FGS's gate-3 check
# still sees the foreground as active and returns without publishing.
if ! grep -aqF -- "${MARK_HANDOFF_OK}" "${LOGCAT_FILE}" 2>/dev/null; then
  fail "the lifecycle pause was delivered but the handoff never completed (no \
'${MARK_HANDOFF_OK}'): kForegroundActiveAtMsKey never reached 0, so MapShell._onPaused() \
did not run to completion and the FGS stayed gated out of publishing."
fi
echo "  [1/4] Foreground handoff delivered and confirmed."

# (2) P0-1's oracle — POSITIVE, not an absence check. `Initialized (…
#     locationSharing=true)` is emitted only after CircleManagerFfi.newInstance
#     returned, i.e. after the Rule-14 acquire succeeded against a foreground
#     session that is still held.
if grep -aqF -- "${MARK_ONSTART_FAILED}" "${LOGCAT_FILE}" 2>/dev/null; then
  echo "---- offending logcat ----" >&2
  grep -aF '[BackgroundTask]' "${LOGCAT_FILE}" >&2 || true
  # Deliberately does NOT assert the CAUSE. The marker prints only
  # `${e.runtimeType}` (background_location_task.dart:246) — correctly, per
  # Security Rule 8 — so a SQLCipher key mismatch, a keyring miss, or an OOM
  # reach this line identically to the Rule-14 collision. P0-1 is by far the
  # most likely cause and the reason this lane exists, but naming it as a
  # certainty would make the lane's headline finding unfalsifiable.
  fail "the FGS isolate failed to start ('${MARK_ONSTART_FAILED}') while the foreground \
MLS session was live, so it never opened the database and can publish nothing this \
session. EXPECTED CAUSE: the Rule-14 LiveSessionGuard collision — see \
docs/CI_HARDENING_BACKLOG.md P0-1. Confirm from the runtime type dumped above before \
concluding; an unrelated open failure reaches this same marker."
fi
if ! grep -aF -- "${MARK_INITIALIZED}" "${LOGCAT_FILE}" 2>/dev/null \
     | grep -aqF -- "${MARK_LOCSHARING_OK}"; then
  fail "the FGS isolate never reported a completed init with location sharing wired \
('${MARK_INITIALIZED}… ${MARK_LOCSHARING_OK}'). It either never booted, or it booted \
without a CircleManagerFfi — the P0-1 steady state, in which _publishCycle returns \
immediately and silently forever."
fi
echo "  [2/4] FGS initialized with location sharing wired (Rule-14 acquire succeeded)."

# (3) Delivery, windowed to AFTER the handoff and PARSED (never grepped —
#     `Published to 0/1` is P0-1's own signature and contains the marker).
WINDOW="${LOG_DIR}/post-pause.window.log"
window_after_marker "${LOGCAT_FILE}" "${MARK_HANDOFF_OK}" > "${WINDOW}"
published="$(max_published_count "${WINDOW}")"
if [[ -z "${published}" ]]; then
  if grep -aqF -- "${MARK_CYCLE_FAILED}" "${WINDOW}" 2>/dev/null; then
    fail "the publish cycle threw ('${MARK_CYCLE_FAILED}') and never reported a count."
  fi
  fail "no publish cycle reported after the handoff. The cycle returns early and \
SILENTLY when no circle is eligible, nothing is due, or the foreground is still marked \
active (background_location_task.dart:360-430), so this covers several distinct causes \
— read the [BackgroundTask] dump below to tell them apart."
fi
if (( published < 1 )); then
  fail "the FGS ran a publish cycle after the handoff but published to ZERO circles \
(highest count observed: ${published}). The isolate is alive but delivering nothing."
fi
echo "  [3/4] FGS published to ${published} circle(s) after the handoff."

# (4) THE ANTI-VACUITY CHECK. Same OS process ⇒ same Rust `LIVE_SESSIONS`
#     registry ⇒ the Rule-14 contention was real.
#
#     Without this the lane has a live false-green path: if the app process
#     dies and Android restarts the START_STICKY service into a FRESH process,
#     there is no foreground session at all, the acquire trivially succeeds,
#     and (2) and (3) both pass while nothing under test was exercised. The
#     144s foreground-active staleness fallback (2 * kBackgroundRepeatInterval)
#     makes that window wide enough to hit comfortably.
pause_pid="$(pid_of_marker "${LOGCAT_FILE}" "${MARK_PAUSE}")"
publish_pid="$(pid_of_marker "${WINDOW}" "${MARK_PUBLISHED_PREFIX}")"
if [[ -z "${pause_pid}" || -z "${publish_pid}" ]]; then
  fail "could not read the PID column for the handoff (${pause_pid:-none}) and/or the \
publish (${publish_pid:-none}) — cannot prove they shared a process, so the Rule-14 \
contention is unproven. Is logcat still in -v threadtime format?"
fi
if [[ "${pause_pid}" != "${publish_pid}" ]]; then
  fail "the FGS published from PID ${publish_pid} but the foreground that handed off was \
PID ${pause_pid}. DIFFERENT PROCESSES — most likely a START_STICKY restart after the app \
died, which means there was no live foreground MLS session to contend with and this run \
proves NOTHING about P0-1."
fi
if grep -aqF -- "${MARK_ONDESTROY}" "${WINDOW}" 2>/dev/null; then
  fail "the FGS was destroyed after the handoff ('${MARK_ONDESTROY}') — the service did \
not survive the window it was supposed to publish in."
fi
echo "  [4/4] Publish came from PID ${publish_pid}, the same process as the foreground."

# NOTE on what is deliberately NOT asserted: there is no relay-side line-count
# check. An earlier revision compared strfry's docker-log line count before and
# after, which was worthless in both directions — it cannot fail (the FGS's own
# relay connect, plus strfry's 9s expired-event cron, guarantee new lines) and it
# adds nothing (`Published to N` is only reached after `publishEvent` returns,
# and `publish_with_retry` returns Ok ONLY when at least one relay OK-acked:
# haven-core/src/relay/manager.rs:119-133 — Security Rule 13's ack/sent
# distinction, honoured). A gate that cannot fail is the repo's documented
# recurring failure mode, so it was removed rather than left as decoration.

echo "B1 PASS — the FGS published ${published} location(s) from PID ${publish_pid} with \
the foreground MLS session held by that same process."
