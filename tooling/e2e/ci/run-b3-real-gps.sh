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
#   1. `adb emu geo fix` SETS the emulated position; the emulator then
#      streams it to the guest's GNSS HAL as NMEA once a second for as long
#      as the platform runs a GNSS session, whether or not the injection is
#      repeated. (CI run 34642726338: `Gnss:onGnssLocationCb` once a second
#      inside every session, minutes after another lane had stopped its own
#      re-issue loop; that lane's first session drained ~239 sentences that
#      had been buffered one per second since the seed.) The loop below is
#      therefore a RETRY for a console command that failed to land, not a
#      refresh for a feed that expires — redundant rather than wrong, and
#      it stays. What it must never be read as is a lever: stopping it
#      creates no no-fix condition (a lane that needs one replaces the
#      provider instead — `run-b1-fgs-publish.sh`'s `arm_no_fix`).
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
# The shared fresh-install step: install_fresh and its broadcast barrier.
# shellcheck source=tooling/e2e/ci/app-install-lib.sh
source "${SCRIPT_DIR}/app-install-lib.sh"
# The log-privacy gate — the key-material floor AND the identifier scanner,
# one call, one verdict — over the captures after the drive and over the whole
# evidence directory at exit.
# shellcheck source=tooling/e2e/ci/logscan-gate.sh
source "${SCRIPT_DIR}/logscan-gate.sh"

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
  # Not `tr | grep -q`: tr writes a real dump in chunks, and a grep that exits
  # on an early match SIGPIPEs it into rc 141, which pipefail reads as denied.
  grep -aqE "${perm}: granted=true" <<<"$(tr -d '\r' < "${dump}")"
}

# location_provider_names — the providers `dumpsys location` lists, with their
# `[mock]` state, and nothing else. The dump's `last location=` line is the
# position, which no log may carry (Security Rule 15) — a synthetic landmark
# included, because the scanner declares this lane's point as a needle.
location_provider_names() {
  tr -d '\r' | grep -aoE '^[[:space:]]*[a-z_]+ provider( \[mock\])?' \
    | sed 's/^[[:space:]]*//' | sort -u
}

# ---------------------------------------------------------------------------
# Self-test — hermetic fixtures. The fixtures are chosen so a predicate that
# has rotted into always-true cannot survive: every helper has at least one
# NEGATIVE fixture, and the near-misses (a zero count, a granted NEIGHBOUR
# permission) are the ways these would silently start passing.
# ---------------------------------------------------------------------------
run_self_test() {
  local tmp fails=0 checked=0
  local -r SELF_TEST_FIXTURES=27
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  _case() { # _case <label> <expected 0|1> <actual-rc>
    local label="$1" want="$2" got="$3"
    checked=$((checked + 1))
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
    checked=$((checked + 1))
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

  # (12) Granted on the FIRST line of a >1 MiB dump. Piped into `grep -q`, the
  #      writer still has most of the dump to write when the match exits the
  #      reader, so this is the deterministic SIGPIPE shape, not a lucky race.
  { printf '    android.permission.ACCESS_FINE_LOCATION: granted=true\r\n'
    awk 'BEGIN { for (i = 0; i < 24576; i++)
      printf "    android.permission.FILLER_%05d: granted=false\r\n", i }'
  } > "${tmp}/g4.txt"
  rc=0
  b3_permission_granted "${tmp}/g4.txt" 'android.permission.ACCESS_FINE_LOCATION' || rc=1
  _case "granted at the head of a >1 MiB dump" 0 "${rc}"

  # (12a) THE UPLOADED FILE IS AN EXTRACT, so the predicate has to be satisfied
  #       by what the extract keeps — not by the raw platform dump it came
  #       from. Both directions, over the AOSP shape whose install-path
  #       furniture is what tripped S4 in CI run 35280144455.
  printf '%s\r\n' \
    '  Package [com.oblivioustech.haven] (5e1f2a3):' \
    '    codePath=/data/app/~~QzvxN8kLpR2mTfY7wJdBnA==/com.oblivioustech.haven-Q5SpczNlQjMGRcjTLpQ2Kg==' \
    '      runtime permissions:' \
    '        android.permission.ACCESS_FINE_LOCATION: granted=true, flags=[ USER_SET ]' \
    '        android.permission.ACCESS_BACKGROUND_LOCATION: granted=false' \
    | logscan_permission_extract > "${tmp}/extract.log"
  rc=0
  b3_permission_granted "${tmp}/extract.log" \
    'android.permission.ACCESS_FINE_LOCATION' || rc=1
  _case "the uploaded extract still answers granted=true" 0 "${rc}"
  rc=0
  b3_permission_granted "${tmp}/extract.log" \
    'android.permission.ACCESS_BACKGROUND_LOCATION' || rc=1
  _case "…and answers granted=false for a denied permission" 1 "${rc}"

  # (13) The drive-log failure predicate this lane leans on is exercised by
  #      its own self-test; assert only that sourcing it worked, so a
  #      refactor that drops the `source` fails here rather than at 3am.
  rc=0; declare -F drive_log_reports_test_failure >/dev/null || rc=1
  _case "drive-log failure predicate is in scope" 0 "${rc}"

  # --- location_provider_names ---------------------------------------------
  # (14) A real `dumpsys location` shape: the provider headers survive, the
  #      position does not — planted, then asserted absent.
  printf '%s\n' \
    '  fused provider [mock]:' \
    '      last location=Location[fused 52.370215,4.895167 hAcc=5.0 et=+10m0s201ms alt=0.0]' \
    '      enabled=true' \
    '  gps provider:' \
    '      last location=Location[gps 52.370215,4.895167 hAcc=5.0 et=+10m0s201ms alt=0.0]' \
    '  passive provider:' \
    > "${tmp}/dumpsys-location.txt"
  _eq_case "provider names and mock state, no position" \
    "$(printf '%s\n' 'fused provider [mock]' 'gps provider' 'passive provider')" \
    "$(location_provider_names < "${tmp}/dumpsys-location.txt")"
  _eq_case "…the planted coordinate is absent from the output" "0" \
    "$(location_provider_names < "${tmp}/dumpsys-location.txt" | grep -c '52.37' || true)"

  # --- log-privacy gate wiring ---------------------------------------------
  # Source pins in the shape of run-single-avd-scenario.sh's (9b): the gate
  # is what stands between a captured log and the job log, so its position is
  # read from this file's own lines, never trusted. Continuation lines are
  # joined and comments dropped, so a call that spans lines is one line here.
  local self="${BASH_SOURCE[0]}" joined gate_at cat_at
  joined="$(sed -e ':a' -e '/\\$/N; s/\\\n//; ta' "${self}" | grep -vE '^[[:space:]]*#')"
  # (16) The drive log is echoed only after the gate, and exactly once.
  gate_at="$(grep -nE '^logscan_gate host /tmp/haven-soak/needles ' <<<"${joined}" \
    | cut -d: -f1 | head -n 1 || true)"
  cat_at="$(grep -nE '^[[:space:]]*cat "\$\{(DRIVE_LOG|LOGCAT_FILE)\}"' <<<"${joined}" | cut -d: -f1 | head -n 1 || true)"
  rc=0
  [[ -n "${gate_at}" && -n "${cat_at}" ]] && (( gate_at < cat_at )) || rc=1
  _case "the drive log is echoed only after the log-privacy gate" 0 "${rc}"
  _eq_case "…and exactly once" "1" "$(grep -cE '^[[:space:]]*cat "\$\{(DRIVE_LOG|LOGCAT_FILE)\}"' <<<"${joined}" || true)"
  # (18) The gate's sinks are this lane's captures, the injected point is
  #      declared beside the host needles, and the report stays out of the
  #      uploaded directory.
  #      Counted at column 0 (`index == 1`), where the real call sits and
  #      this fixture's own literal does not.
  local gate_lit='logscan_gate host /tmp/haven-soak/needles "${SEAL_EXTRA[@]}" --   --sink "logcat=${LOGCAT_FILE}" --sink "drive=${DRIVE_LOG}"   --report "${LOGSCAN_REPORTS}/gate.ndjson" || LOGSCAN_GATE_RC=$?'
  _eq_case "the gate names the logcat, the drive log and the injected point" "1" \
    "$(awk -v lit="${gate_lit}" \
         'index($0, lit) == 1 { n++ } END { print n + 0 }' <<<"${joined}")"
  # …and the array that call passes is this lane's whole seal claim: its
  # injected point and both line floors, pinned so a red lane cannot be turned
  # green by lowering one of them.
  local extra_lit='readonly -a SEAL_EXTRA=(--host-decl "coordinate=${GEO_LAT},${GEO_LON}" --floor drive=64 --floor relay=7)'
  _eq_case "the seal extras carry the injected point and both line floors" "1" \
    "$(awk -v lit="${extra_lit}" \
         'index($0, lit) == 1 { n++ } END { print n + 0 }' "${self}")"
  # (19) The EXIT trap scans the whole directory through the same gate, after
  #      the relay dump is written and before the exit, every file typed by
  #      name (logscan-gate.sh's walker).
  local trap_body dump_at scan_at exit_at
  trap_body="$(sed -n '/^cleanup() {/,/^}/p' <<<"${joined}")"
  dump_at="$(grep -nF 'docker logs strfry > "${LOG_DIR}/strfry.final.log"' <<<"${trap_body}" | cut -d: -f1 | head -n 1 || true)"
  scan_at="$(grep -nF 'logscan_gate_dir host /tmp/haven-soak/needles "${LOG_DIR}" "${LOGSCAN_REPORTS}/exit.ndjson" "${SEAL_EXTRA[@]}"     || scan_rc=$?' <<<"${trap_body}" \
    | cut -d: -f1 | head -n 1 || true)"
  exit_at="$(grep -nF 'exit "${rc}"' <<<"${trap_body}" | cut -d: -f1 | head -n 1 || true)"
  rc=0
  [[ -n "${dump_at}" && -n "${scan_at}" && -n "${exit_at}" ]] \
    && (( dump_at < scan_at && scan_at < exit_at )) || rc=1
  _case "the EXIT trap gates the whole log directory after the relay dump" 0 "${rc}"
  # (20) Fail-closed shapes: no soft `if [[ -x` scanner gate, no bare
  #      key-material floor call (the floor runs inside the wrapper), and the
  #      identifier arm is reachable — the sourced gate reads HAVEN_LOGSCAN.
  local floor='scan-logs-for-'
  floor+='secrets.sh'
  _eq_case "no soft scanner gate" "0" \
    "$(grep -cE 'if[[:space:]]+\[\[[[:space:]]+-x[[:space:]]' <<<"${joined}" || true)"
  _eq_case "no bare key-material floor call" "0" "$(grep -cF "${floor}" <<<"${joined}" || true)"
  rc=0; declare -f logscan_gate | grep -q 'HAVEN_LOGSCAN' || rc=1
  _case "the HAVEN_LOGSCAN arm exists in the sourced gate" 0 "${rc}"
  # (23) No coordinate reaches the step log: the injected point is never
  #      echoed and `dumpsys location` is read only through the name filter.
  _eq_case "the injected coordinates are never echoed" "0" \
    "$(grep -cE '(echo|printf) .*\$\{GEO_L(AT|ON)\}' <<<"${joined}" || true)"
  _eq_case "dumpsys location reaches the log only as provider names" \
    "$(grep -c 'dumpsys location' <<<"${joined}" || true)" \
    "$(grep -c 'dumpsys location .*| location_provider_names' <<<"${joined}" || true)"

  if (( checked != SELF_TEST_FIXTURES )); then
    echo "SELF-TEST FAIL: ran ${checked} fixture(s), expected ${SELF_TEST_FIXTURES}" >&2
    fails=1
  fi
  if (( fails )); then
    echo "run-b3-real-gps.sh --self-test: FAILURES (see above)" >&2
    return 1
  fi
  echo "run-b3-real-gps.sh --self-test: all ${checked} fixtures passed"
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
# install (and its broadcast barrier) + grants + GPS seeding + the oracle on
# top; the sum is derived at e2e-real-gps.yml's drive step, and see
# scripts/ci/check_e2e_step_timeout_ordering.sh for the ordering invariant.
#
# Sizing: the target's own budget is arming (~60s under emulator mlock
# pressure) + up to 150s waiting for the OS fix + circle creation and Welcome
# round-trip (~60s) + up to 120s for the peer decrypt = ~7 min worst case,
# against an 8-minute in-test `Timeout`. 12m leaves headroom for a slow cold
# start without letting a wedge run to the outer deadline anonymously.
readonly DRIVE_TIMEOUT="${B3_DRIVE_TIMEOUT:-12m}"

# How long SIGKILL follows the drive's SIGTERM at DRIVE_TIMEOUT: a term in
# this lane's worst case, which its workflow derives at the drive step.
readonly DRIVE_KILL_AFTER_SECS=30

# `adb emu geo fix` re-issue period (trap 1 in the header). The seeded
# position does not expire, so this is a retry cadence for an injection that
# failed to land — short enough to be quick about it, long enough not to spam
# the console socket.
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
       "(the values are withheld: they may be a position)." >&2
  exit 2
fi

readonly REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
readonly HAVEN_DIR="${REPO_ROOT}/haven"
readonly START_STRFRY="${SCRIPT_DIR}/start-strfry.sh"
readonly STOP_STRFRY="${SCRIPT_DIR}/stop-strfry.sh"

LOGCAT_PID=""
GEO_PID=""
# The post-drive gate's verdict, folded into the EXIT trap's: a leak the gate
# contained has deleted its sinks, so the trap's rescan alone would read clean.
LOGSCAN_GATE_RC=0

mkdir -p "${LOG_DIR}"
readonly LOGCAT_FILE="${LOG_DIR}/logcat.b3.log"
readonly DRIVE_LOG="${LOG_DIR}/flutter-drive.log"
readonly PERM_DUMP="${LOG_DIR}/permissions.b3.log"
# The scanner's findings reports (sink:line, class, rule — never a value) live
# BESIDE the uploaded directory, not in it: the workflow uploads LOG_DIR whole.
readonly LOGSCAN_REPORTS="/tmp/b3-logscan"
mkdir -p "${LOGSCAN_REPORTS}"

# The seal extras this lane's gates pass, in ONE place: its own fixed
# coordinate (a value the harness names, which the logs must never carry) and
# its line floors. BOTH gate calls pass this same array, because whichever runs
# first is the one that seals the manifest and every later gate reuses what is
# at the out path.
#
# A floor is what turns "the scan read an empty or truncated file and found
# nothing" into rc 4 instead of a green, so it is sized to the smallest
# COMPLETE capture and never to what would make the lane pass.
#
# drive=64. The policy's 100 is sized for the Android core flow's 394-line
# transcript; this lane drives one scenario whose complete transcript is
# 128 lines (flutter-drive.log) in run 35376588206, the first green run after the
# gate's rollout. 64 is half of that and far above the ~17 lines `flutter
# drive` prints before the first test result, so a transcript that fails it
# is one in which no test ran. (The provisional 20 was set blind: run
# 35280144455's rc 1 on the dumpsys hits outranked the rc 4 beneath it and
# containment deleted the transcript before it could be measured.)
#
# relay=7. The policy's 1 is sized for the hermetic host relay, which prints a
# single listen line; this lane's relay is strfry, whose `docker logs` dump is
# 14-23 lines for a full run, of which the first 9 are a fixed startup block.
# 7 is half the smallest complete dump, so a dump below it is truncated or
# absent — which is what a container torn down before the dump looks like: ONE
# line of docker error text.
readonly -a SEAL_EXTRA=(--host-decl "coordinate=${GEO_LAT},${GEO_LON}" --floor drive=64 --floor relay=7)

# ---------------------------------------------------------------------------
# Cleanup (EXIT trap): stop the background helpers, run the MANDATORY
# log-privacy scan over every captured log (Security Rules 6 and 15 — must run
# even on a phase failure), snapshot + tear down strfry. Escalates on a leak;
# never masks a phase rc. Mirrors run-b1-fgs-publish.sh's containment posture,
# including the deliberate asymmetry between rc 1 (leak -> the wrapper has
# destroyed the sinks) and rc 2/3/4 (nothing proven leaked -> keep, because
# the truncated artefacts ARE the evidence).
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
  echo "== Log-privacy scan over ${LOG_DIR} (Security Rules 6 and 15) =="
  logscan_gate_dir host /tmp/haven-soak/needles "${LOG_DIR}" "${LOGSCAN_REPORTS}/exit.ndjson" "${SEAL_EXTRA[@]}" \
    || scan_rc=$?
  if (( scan_rc == 1 || LOGSCAN_GATE_RC == 1 )); then
    {
      echo "Logs withheld: the log-privacy gate tripped (Security Rules 6 and 15)."
      echo "See the LEAK line(s) in the step log for file/label/line numbers."
    } > "${LOG_DIR}/LEAK_DETECTED.txt"
    echo "ERROR: log-privacy gate tripped on B3 logs — logs deleted," \
         "not uploaded." >&2
    rc=1
  elif (( scan_rc != 0 || LOGSCAN_GATE_RC != 0 )); then
    echo "ERROR: the log-privacy gate could not certify the B3 logs" \
         "(rc=${scan_rc}, post-drive rc=${LOGSCAN_GATE_RC}) — see the lines" \
         "above. Logs kept for triage." >&2
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
  # Which providers the platform has and which are mocked; never the position
  # (Security Rule 15 — the point is synthetic, and still a needle).
  echo "---- emulator location providers ----" >&2
  adb -s "${DEVICE}" shell dumpsys location 2>/dev/null | location_provider_names >&2 \
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
# from a prior target survives into this run, and flush the fresh install's
# broadcasts before anything launches the app (app-install-lib.sh).
# ---------------------------------------------------------------------------
echo "Phase 1/5 — installing ${APK}..."
[[ -f "${APK}" ]] || fail "APK not found: ${APK} (was the build step skipped?)"
install_fresh "${DEVICE}" "${APK}" \
  || fail "the fresh install of ${APK} did not complete (see the ERROR above)."

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

# The dump is FILTERED on the way in (logscan_permission_extract): what the
# lane reads and what it uploads are the same lines, and the platform's
# install-path furniture — which S4 read as a blob, twice per dump, in CI run
# 35280144455 — never reaches a file at all.
adb -s "${DEVICE}" shell dumpsys package "${PKG}" 2>&1 \
  | logscan_permission_extract > "${PERM_DUMP}" || true
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
# Phase 3 — enable the platform location provider, then seed the emulator's
# position (and re-seed it on a loop — trap 1: a retry, not a refresh).
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

echo "  geo fix injected (re-issued every ${GEO_REISSUE_SECS}s)"
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
( cd "${HAVEN_DIR}" && timeout --kill-after="${DRIVE_KILL_AFTER_SECS}s" "${DRIVE_TIMEOUT}" flutter drive \
    --no-pub \
    --device-id "${DEVICE}" \
    --use-application-binary "${APK}" \
    --driver "${DRIVER_FILE}" \
    --target "${TARGET}" ) > "${DRIVE_LOG}" 2>&1 || drc=$?

# Scan BEFORE echoing. The EXIT trap's scan runs far too late to protect the
# STEP log, which has no retention control and cannot be redacted after the
# fact — a wider, more permanent sink than the artifact upload. The gate is
# the key-material floor AND the identifier scanner, sealed from the host
# needles plus the point this lane injected; a leak deletes both captures.
logscan_gate host /tmp/haven-soak/needles "${SEAL_EXTRA[@]}" -- \
  --sink "logcat=${LOGCAT_FILE}" --sink "drive=${DRIVE_LOG}" \
  --report "${LOGSCAN_REPORTS}/gate.ndjson" || LOGSCAN_GATE_RC=$?
if (( LOGSCAN_GATE_RC == 0 )); then
  cat "${DRIVE_LOG}" || true
else
  echo "drive log withheld from the step log — log-privacy gate rc ${LOGSCAN_GATE_RC}." >&2
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
