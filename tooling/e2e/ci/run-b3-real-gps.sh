#!/usr/bin/env bash
#
# B3 real-GPS lane orchestrator — docs/CI_HARDENING_BACKLOG.md Workstream B,
# item B3: "Android real GPS — no `locationServiceProvider` override;
# `pm grant`; `adb emu geo fix`; assert peer decrypt".
#
# # What this lane proves that no other lane does
#
# Every multi-party scenario in this repo injects `FakeLocationService`
# through a `locationServiceProvider` override, so the coordinates a peer
# decrypts are a Dart constant that never touched the OS.
# `run-b1-fgs-publish.sh` already declines the override and already seeds
# `adb emu geo fix` — but its oracle is the foreground service's
# `[BackgroundTask] Published to N/M` logcat marker, which proves a publish
# HAPPENED and says nothing about WHAT was published; its peer is disposed
# before the proof window opens.
#
# So the missing proof is specifically the VALUE: that the coordinates a
# genuinely separate peer recovers, after MLS decryption, are the coordinates
# the emulator's GNSS HAL delivered. This lane injects a known point, and the
# drive target asserts the decrypted value against it numerically.
#
# # The oracle is deliberately doubled
#
# The numeric assertions live in the drive target (`expect`), because that is
# the only place the decrypted value exists. But `flutter drive` CAN EXIT 0 ON
# A FAILED SUITE (drive-log-lib.sh, run 30753193231), and it also exits 0 when
# NOTHING ran. So the shell independently requires the three completion
# markers the target prints as it clears each half of the chain:
#
#   [b3] REAL_FIX_OBSERVED   the OS delivered the injected fix
#   [b3] PUBLISHED n=<N>     the production publisher published to N circles
#   [b3] PEER_DECRYPT_MATCH  the peer decrypted coordinates that matched
#
# A missing marker is a lane that did not reach its own conclusion, whatever
# the exit code claims. The markers carry DELTAS, never coordinates (the drive
# target's privacy note explains why).
#
# # Traps this lane is built around
#
#   1. `adb emu geo fix` is a ONE-SHOT injection into the goldfish GNSS HAL —
#      it starts no stream, and the HAL discards any requested interval — so
#      the fix must be RE-ISSUED on a loop for the life of the drive or a
#      one-shot `getCurrentPosition()` can land in a gap and time out.
#   2. A `pm grant` that is REJECTED still exits 0 (the hard-restricted gate
#      is a bare `return` after a `Log.e`). The authoritative read is
#      `dumpsys package`, so that is what gates here — and the drive target
#      re-reads the permission through the plugin as a second, independent
#      check.
#   3. The AVDs run `google_apis` images where geolocator could resolve to
#      FUSED location while `geo fix` feeds the LocationManager provider.
#      Haven's production `AndroidSettings` already sets
#      `forceLocationManager: true`
#      (haven/lib/src/services/geolocator_location_service.dart), so the two
#      agree — but if this lane ever goes dark on a healthy emulator, that
#      flag is where to look first.
#
# Usage:
#   run-b3-real-gps.sh [<apk> [<target.dart>]]
#   run-b3-real-gps.sh --self-test      # hermetic; no device, no relay
#
# Required env (set by the calling job; MUST match what the APK was built
# with — build-b3-real-gps-apk.sh bakes the same pair as --dart-defines):
#   HAVEN_B3_GEO_LAT   latitude injected with `adb emu geo fix`
#   HAVEN_B3_GEO_LON   longitude injected with `adb emu geo fix`
#
# Optional env:
#   B3_DRIVE_TIMEOUT       per-drive bound. Default 12m.
#   B3_GEO_REISSUE_SECS    `geo fix` re-issue period. Default 5.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR="${script_dir}"

# shellcheck source=tooling/e2e/ci/drive-log-lib.sh
source "${SCRIPT_DIR}/drive-log-lib.sh"

# ---------------------------------------------------------------------------
# Oracle predicates — pure text, no device. Everything the lane's verdict
# rests on lives here so `--self-test` can exercise it hermetically.
# ---------------------------------------------------------------------------

# b3_has_marker <logfile> <marker> — 0 (true) when the marker appears.
#
# Substring match, not anchored: the same line reaches us either as raw
# `debugPrint` output in the drive log or wrapped by logcat's
# `I/flutter ( 1234): ` prefix, and both must count.
b3_has_marker() {
  local log="${1:-}" marker="${2:-}"
  [[ -f "${log}" ]] || return 1
  grep -aqF -- "${marker}" "${log}"
}

# b3_published_count <logfile> — echoes the LARGEST N from any
# `[b3] PUBLISHED n=<N>` line, or nothing when no such line exists.
#
# Parsed, never grepped for presence: "the publisher ran" and "the publisher
# published to at least one circle" are different claims, and the lane needs
# the second. Largest rather than first because the marker is printed once per
# publish attempt and a later, higher count is still a success.
b3_published_count() {
  local log="${1:-}"
  [[ -f "${log}" ]] || return 0
  grep -aoE '\[b3\] PUBLISHED n=[0-9]+' "${log}" 2>/dev/null \
    | grep -oE '[0-9]+$' \
    | sort -n \
    | tail -1
}

# b3_permission_granted <dumpsys-file> <permission> — 0 (true) when
# `dumpsys package` reports the permission as granted.
#
# `pm grant`'s exit code is worthless (trap 2 in the header), so this is the
# gate. Matched on the `<perm>: granted=true` shape rather than on
# `granted=true` alone, because one `dumpsys package` dump lists every
# permission and a neighbouring granted one would otherwise answer for ours.
b3_permission_granted() {
  local dump="${1:-}" perm="${2:-}"
  [[ -f "${dump}" ]] || return 1
  tr -d '\r' < "${dump}" | grep -aqE "${perm}: granted=true"
}

# ---------------------------------------------------------------------------
# Self-test — hermetic fixtures. The fixtures are chosen so a predicate that
# has rotted into always-true cannot survive: every helper has at least one
# NEGATIVE fixture, and the near-misses (a zero count, a granted NEIGHBOUR
# permission) are the ways these would silently start passing.
# ---------------------------------------------------------------------------
run_self_test() {
  local tmp fails=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  _case() { # _case <label> <expected 0|1> <actual-rc>
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

  echo "run-b3-real-gps.sh --self-test"

  # --- b3_has_marker ------------------------------------------------------
  # (1) A raw drive-log line.
  printf '%s\n' \
    '[b3] REAL_FIX_OBSERVED dLat=1e-07 dLon=2e-07 tolerance=1e-5' \
    > "${tmp}/raw.log"
  local rc=0; b3_has_marker "${tmp}/raw.log" '[b3] REAL_FIX_OBSERVED' || rc=1
  _case "marker found in a raw drive log" 0 "${rc}"

  # (2) THE SHAPE THAT ACTUALLY SHIPS — the same line via logcat, prefixed.
  #     An anchored match would pass fixture (1) and silently fail every real
  #     run that reads logcat instead.
  printf '%s\n' \
    'I/flutter ( 4021): [b3] PEER_DECRYPT_MATCH dLat=0.0 dLon=0.0 tol=1e-5' \
    > "${tmp}/logcat.log"
  rc=0; b3_has_marker "${tmp}/logcat.log" '[b3] PEER_DECRYPT_MATCH' || rc=1
  _case "marker found behind a logcat prefix" 0 "${rc}"

  # (3) Absent marker must not be reported present.
  printf '%s\n' 'I/flutter ( 4021): [b3] REAL_FIX_OBSERVED dLat=0.0' \
    > "${tmp}/partial.log"
  rc=0; b3_has_marker "${tmp}/partial.log" '[b3] PEER_DECRYPT_MATCH' || rc=1
  _case "absent marker reports absent" 1 "${rc}"

  # (4) A missing file is not evidence of success.
  rc=0; b3_has_marker "${tmp}/nope.log" '[b3] REAL_FIX_OBSERVED' || rc=1
  _case "missing log reports absent" 1 "${rc}"

  # --- b3_published_count -------------------------------------------------
  # (5) The ordinary case.
  printf '%s\n' 'I/flutter ( 40): [b3] PUBLISHED n=1' > "${tmp}/p1.log"
  _eq_case "published count parsed" "1" "$(b3_published_count "${tmp}/p1.log")"

  # (6) THE CRITICAL FIXTURE — `n=0` is the publisher reporting it published
  #     to NOTHING. A presence-grep would call this a pass.
  printf '%s\n' 'I/flutter ( 40): [b3] PUBLISHED n=0' > "${tmp}/p0.log"
  _eq_case "zero count parsed as 0 (not as presence)" "0" \
    "$(b3_published_count "${tmp}/p0.log")"

  # (7) Several attempts: the highest wins.
  printf '%s\n' \
    'I/flutter ( 40): [b3] PUBLISHED n=0' \
    'I/flutter ( 40): [b3] PUBLISHED n=2' \
    > "${tmp}/pmulti.log"
  _eq_case "largest count across attempts" "2" \
    "$(b3_published_count "${tmp}/pmulti.log")"

  # (8) No marker at all -> empty, distinct from "0".
  printf '%s\n' 'I/flutter ( 40): nothing to see' > "${tmp}/pnone.log"
  _eq_case "absent marker yields empty (not 0)" "" \
    "$(b3_published_count "${tmp}/pnone.log")"

  # --- b3_permission_granted ---------------------------------------------
  # (9) Granted.
  printf '%s\n' \
    '    android.permission.ACCESS_FINE_LOCATION: granted=true' \
    > "${tmp}/g1.txt"
  rc=0
  b3_permission_granted "${tmp}/g1.txt" 'android.permission.ACCESS_FINE_LOCATION' || rc=1
  _case "granted permission detected" 0 "${rc}"

  # (10) Denied — with CRLF, which is what adb actually emits.
  printf '    android.permission.ACCESS_FINE_LOCATION: granted=false\r\n' \
    > "${tmp}/g2.txt"
  rc=0
  b3_permission_granted "${tmp}/g2.txt" 'android.permission.ACCESS_FINE_LOCATION' || rc=1
  _case "denied permission (CRLF) reports denied" 1 "${rc}"

  # (11) THE OTHER CRITICAL FIXTURE — a granted NEIGHBOUR. `dumpsys package`
  #      prints every permission, so a bare `granted=true` grep would report
  #      our permission as held on the strength of an unrelated one.
  printf '%s\n' \
    '    android.permission.INTERNET: granted=true' \
    '    android.permission.ACCESS_FINE_LOCATION: granted=false' \
    > "${tmp}/g3.txt"
  rc=0
  b3_permission_granted "${tmp}/g3.txt" 'android.permission.ACCESS_FINE_LOCATION' || rc=1
  _case "granted neighbour does not answer for us" 1 "${rc}"

  # (12) The drive-log failure predicate this lane leans on is exercised by
  #      its own self-test; assert only that sourcing it worked, so a
  #      refactor that drops the `source` fails here rather than at 3am.
  rc=0; declare -F drive_log_reports_test_failure >/dev/null || rc=1
  _case "drive-log failure predicate is in scope" 0 "${rc}"

  if (( fails )); then
    echo "run-b3-real-gps.sh --self-test: FAILURES (see above)" >&2
    return 1
  fi
  echo "run-b3-real-gps.sh --self-test: all 12 fixtures passed"
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
readonly LOG_DIR="/tmp/b3-logs"
readonly APK="${1:-/tmp/integration-apks/b3_real_gps_test.apk}"
readonly TARGET="${2:-integration_test/b3_real_gps_test.dart}"

# Bounds the drive only. The step's `run-with-deadline.sh` wrapper bounds
# install + grants + GPS seeding + the oracle on top; see
# scripts/ci/check_e2e_step_timeout_ordering.sh for the ordering invariant.
#
# Sizing: the target's own budget is arming (~60s under emulator mlock
# pressure) + up to 150s waiting for the OS fix + circle creation and Welcome
# round-trip (~60s) + up to 120s for the peer decrypt = ~7 min worst case,
# against an 8-minute in-test `Timeout`. 12m leaves headroom for a slow cold
# start without letting a wedge run to the outer deadline anonymously.
readonly DRIVE_TIMEOUT="${B3_DRIVE_TIMEOUT:-12m}"

# `adb emu geo fix` re-issue period (trap 1 in the header). Short enough that
# a one-shot `getCurrentPosition()` never waits long for a fresh fix, long
# enough not to spam the console socket.
readonly GEO_REISSUE_SECS="${B3_GEO_REISSUE_SECS:-5}"

# The injected point. REQUIRED, with no default on purpose: the same pair is
# baked into the APK as `--dart-define`s, and a shell-side default that
# disagreed with the build would make the lane fail on its own assertion with
# no hint that the two halves had drifted apart.
readonly GEO_LAT="${HAVEN_B3_GEO_LAT:-}"
readonly GEO_LON="${HAVEN_B3_GEO_LON:-}"
if [[ -z "${GEO_LAT}" || -z "${GEO_LON}" ]]; then
  echo "ERROR: HAVEN_B3_GEO_LAT / HAVEN_B3_GEO_LON must be set, and must" >&2
  echo "       match the values build-b3-real-gps-apk.sh baked into the APK." >&2
  exit 2
fi
# Validated because both values are interpolated into an `adb emu geo fix`
# argument list; an unvalidated value could word-split into extra arguments.
if [[ ! "${GEO_LAT}" =~ ^-?[0-9]{1,2}(\.[0-9]{1,12})?$ ]] ||
   [[ ! "${GEO_LON}" =~ ^-?[0-9]{1,3}(\.[0-9]{1,12})?$ ]]; then
  echo "ERROR: HAVEN_B3_GEO_LAT/LON must be plain decimal degrees" \
       "(got '${GEO_LAT}' / '${GEO_LON}')." >&2
  exit 2
fi

readonly REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
readonly HAVEN_DIR="${REPO_ROOT}/haven"
readonly START_STRFRY="${SCRIPT_DIR}/start-strfry.sh"
readonly STOP_STRFRY="${SCRIPT_DIR}/stop-strfry.sh"
readonly SECRET_SCAN="${SCRIPT_DIR}/scan-logs-for-secrets.sh"

LOGCAT_PID=""
GEO_PID=""

mkdir -p "${LOG_DIR}"
readonly LOGCAT_FILE="${LOG_DIR}/logcat.b3.log"
readonly DRIVE_LOG="${LOG_DIR}/flutter-drive.log"
readonly PERM_DUMP="${LOG_DIR}/permissions.b3.log"

# ---------------------------------------------------------------------------
# Cleanup (EXIT trap): stop the background helpers, run the MANDATORY secret
# scan over every captured log (Security Rule 6 — must run even on a phase
# failure), snapshot + tear down strfry. Escalates on a leak; never masks a
# phase rc. Mirrors run-b1-fgs-publish.sh's containment posture, including the
# deliberate asymmetry between rc 1 (leak -> destroy) and rc 3 (unscannable ->
# keep, because there is no leak and the truncated artefacts ARE the evidence).
# ---------------------------------------------------------------------------
cleanup() {
  local rc=$?
  local scan_rc=0
  trap - EXIT
  if [[ -n "${GEO_PID}" ]] && kill -0 "${GEO_PID}" 2>/dev/null; then
    kill "${GEO_PID}" 2>/dev/null || true
  fi
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
    echo "ERROR: secret-leak guard tripped on B3 logs — logs deleted," \
         "not uploaded." >&2
    rc=1
  elif (( scan_rc != 0 )); then
    echo "ERROR: secret-leak guard could not scan the B3 logs" \
         "(rc=${scan_rc}) — see the UNUSABLE line(s) above. Logs kept for" \
         "triage." >&2
    rc=1
  fi
  bash "${STOP_STRFRY}" >/dev/null 2>&1 || true
  exit "${rc}"
}
trap cleanup EXIT

fail() {
  echo "B3-LANE-FAIL: $*" >&2
  echo "---- [b3] markers seen ----" >&2
  grep -aF '[b3] ' "${DRIVE_LOG}" "${LOGCAT_FILE}" 2>/dev/null | tail -30 >&2 \
    || echo "(none — the drive target reached no checkpoint at all)" >&2
  # Emulator location state. The injected point is a hardcoded public
  # landmark, so printing it is acceptable here (same posture as
  # run-b1-fgs-publish.sh) — but see this lane's docs before ever pointing it
  # at a value derived from a real device.
  echo "---- emulator location state ----" >&2
  adb -s "${DEVICE}" shell dumpsys location 2>/dev/null \
    | grep -aiA 4 'last location\|fused\|gps provider' | head -40 >&2 \
    || echo "(dumpsys location unavailable)" >&2
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
# Phase 1 — clean install. Force-stop + uninstall FIRST so no sticky state
# from a prior target survives into this run.
# ---------------------------------------------------------------------------
echo "Phase 1/5 — installing ${APK}..."
[[ -f "${APK}" ]] || fail "APK not found: ${APK} (was the build step skipped?)"
adb -s "${DEVICE}" shell am force-stop "${PKG}" || true
adb -s "${DEVICE}" uninstall "${PKG}" >/dev/null 2>&1 || true
adb -s "${DEVICE}" install -r "${APK}"

# ---------------------------------------------------------------------------
# Phase 2 — runtime permissions, VERIFIED.
#
# The whole point of B3's `pm grant` is that the app takes the REAL runtime-
# permission branch of `GeolocatorLocationService` rather than a fake that
# always answers "always". So the grant has to actually be held — and
# `pm grant`'s exit code cannot tell us (trap 2 in the header). `dumpsys
# package` is the authoritative read and is what gates.
#
# ACCESS_BACKGROUND_LOCATION is deliberately NOT granted: this lane publishes
# from a VISIBLE activity, and granting more than the scenario needs would
# quietly make the lane stop representing the permission state real
# foreground users have.
# ---------------------------------------------------------------------------
echo "Phase 2/5 — granting and VERIFYING runtime permissions..."
for perm in \
  android.permission.ACCESS_FINE_LOCATION \
  android.permission.ACCESS_COARSE_LOCATION \
  android.permission.POST_NOTIFICATIONS
do
  adb -s "${DEVICE}" shell pm grant "${PKG}" "${perm}" 2>&1 | sed 's/^/    /' \
    || true
done

adb -s "${DEVICE}" shell dumpsys package "${PKG}" > "${PERM_DUMP}" 2>&1 || true
for perm in \
  android.permission.ACCESS_FINE_LOCATION \
  android.permission.ACCESS_COARSE_LOCATION
do
  if b3_permission_granted "${PERM_DUMP}" "${perm}"; then
    echo "  verified ${perm}: granted=true"
  else
    grep -a "${perm}" "${PERM_DUMP}" | sed 's/^/    /' >&2 || true
    fail "${perm} is NOT granted according to dumpsys package. \`pm grant\`" \
         "exits 0 even when it refuses, so a silent rejection here would" \
         "otherwise present as an unattributable GPS timeout in the drive."
  fi
done

# ---------------------------------------------------------------------------
# Phase 3 — enable the platform location provider, then feed the emulator a
# GPS fix and KEEP feeding it.
#
# `cmd location set-location-enabled true` is best-effort: the AVD images used
# here have location on by default and the command is absent on some API
# levels. It is not a gate because the drive target asserts
# `isLocationServiceEnabled()` from inside the app, which is the read that
# actually matters and attributes the failure precisely.
#
# NOTE the argument order: `geo fix` takes LONGITUDE first, then LATITUDE.
# ---------------------------------------------------------------------------
echo "Phase 3/5 — enabling location provider and seeding GPS..."
adb -s "${DEVICE}" shell cmd location set-location-enabled true >/dev/null 2>&1 \
  || echo "  (cmd location set-location-enabled unavailable — continuing)"

echo "  injecting lon=${GEO_LON} lat=${GEO_LAT} (re-issued every ${GEO_REISSUE_SECS}s)"
adb -s "${DEVICE}" emu geo fix "${GEO_LON}" "${GEO_LAT}" \
  || fail "\`adb emu geo fix\` was rejected by the emulator console — no" \
          "position can be injected, so this lane cannot run."
(
  while sleep "${GEO_REISSUE_SECS}"; do
    adb -s "${DEVICE}" emu geo fix "${GEO_LON}" "${GEO_LAT}" >/dev/null 2>&1 \
      || true
  done
) &
GEO_PID=$!

# ---------------------------------------------------------------------------
# Phase 4 — drive the target.
#
# No `--keep-app-running`: unlike B1, nothing here has to outlive the drive.
# The entire proof — the OS fix, the publish and the peer's decrypt — happens
# inside the `testWidgets` body, so letting `flutter drive` stop the app
# afterwards is correct and keeps the lane from leaving a live MLS session
# behind for the next job on the runner.
# ---------------------------------------------------------------------------
echo "Phase 4/5 — capturing logcat and driving ${TARGET}..."
adb -s "${DEVICE}" logcat -c || true
adb -s "${DEVICE}" logcat -v threadtime > "${LOGCAT_FILE}" 2>&1 &
LOGCAT_PID=$!

drc=0
( cd "${HAVEN_DIR}" && timeout --kill-after=30s "${DRIVE_TIMEOUT}" flutter drive \
    --no-pub \
    --device-id "${DEVICE}" \
    --use-application-binary "${APK}" \
    --driver "${DRIVER_FILE}" \
    --target "${TARGET}" ) > "${DRIVE_LOG}" 2>&1 || drc=$?

# Scan BEFORE echoing. The EXIT trap's scan runs far too late to protect the
# STEP log, which has no retention control and cannot be redacted after the
# fact — a wider, more permanent sink than the artifact upload.
if bash "${SECRET_SCAN}" "${DRIVE_LOG}"; then
  cat "${DRIVE_LOG}" || true
else
  echo "drive log withheld from the step log — secret-leak guard tripped." >&2
fi

# ---------------------------------------------------------------------------
# Phase 5 — the oracle.
# ---------------------------------------------------------------------------
echo "Phase 5/5 — asserting the real-GPS chain..."

# Step 1: the drive itself. `drc == 0` is NOT sufficient — `flutter drive`
# exits 0 when the on-device suite failed outside a testWidgets body, and when
# nothing ran at all (drive-log-lib.sh).
if (( drc != 0 )); then
  fail "flutter drive exited ${drc} for ${TARGET}."
fi
if drive_log_reports_test_failure "${DRIVE_LOG}"; then
  echo "---- app-side failure evidence ----" >&2
  drive_log_failure_evidence "${DRIVE_LOG}" >&2
  fail "flutter drive exited 0 but the ON-DEVICE suite reported a failure" \
       "(or ran nothing). The numeric coordinate assertions live in the" \
       "drive target, so this is where a coordinate mismatch surfaces."
fi

# Step 2: the OS half of the chain. Without this marker the target never got
# a fix matching the injection, so nothing downstream means anything.
if ! b3_has_marker "${DRIVE_LOG}" '[b3] REAL_FIX_OBSERVED' &&
   ! b3_has_marker "${LOGCAT_FILE}" '[b3] REAL_FIX_OBSERVED'; then
  fail "the drive never reported REAL_FIX_OBSERVED — the production" \
       "GeolocatorLocationService never returned the injected position." \
       "Suspect: the \`geo fix\` re-issue loop, the LocationManager vs FUSED" \
       "provider split (trap 3 in this script's header), or a location" \
       "provider that is disabled on this AVD."
fi
echo "  OK: the OS delivered the injected fix to the production location service."

# Step 3: the publish. PARSED, not grepped — `n=0` is the publisher reporting
# that it published to nothing, which a presence check would call a pass.
published=""
published="$(b3_published_count "${DRIVE_LOG}")"
if [[ -z "${published}" ]]; then
  published="$(b3_published_count "${LOGCAT_FILE}")"
fi
if [[ -z "${published}" ]]; then
  fail "no \`[b3] PUBLISHED n=<N>\` line anywhere — the production" \
       "locationPublisherProvider never reported a result."
fi
if (( published < 1 )); then
  fail "the production publisher published to ${published} circle(s)." \
       "A real GPS fix was available (step 2 passed), so the failure is on" \
       "the publish path or in circle eligibility, not in the OS."
fi
echo "  OK: the production publisher published to ${published} circle(s)."

# Step 4: THE DELIVERABLE. A peer decrypted coordinates that matched the
# injection. The numeric comparison itself is the drive target's `expect`;
# this marker is only printed after it passes, and step 1 has already ruled
# out a suite that failed or never ran.
if ! b3_has_marker "${DRIVE_LOG}" '[b3] PEER_DECRYPT_MATCH' &&
   ! b3_has_marker "${LOGCAT_FILE}" '[b3] PEER_DECRYPT_MATCH'; then
  fail "the peer never decrypted a location matching the injected fix." \
       "The send half worked (steps 2-3), so suspect the receive half:" \
       "the peer's epoch, the kind-445 NIP-40 expiration, or the relay."
fi
echo "  OK: a PEER decrypted the coordinates that were injected into the GPS."

echo
echo "B3 real-GPS lane PASSED — \`adb emu geo fix\` -> Android LocationManager"
echo "-> geolocator -> production publisher -> MLS kind-445 -> peer decrypt,"
echo "with the decrypted VALUE asserted against what was injected."
