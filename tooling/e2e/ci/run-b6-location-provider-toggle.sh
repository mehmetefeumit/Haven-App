#!/usr/bin/env bash
#
# B6 location-provider-toggle lane orchestrator —
# docs/CI_HARDENING_BACKLOG.md Workstream B, item B6: "Location provider
# toggle | `cmd location set-location-enabled false`".
#
# # What this lane proves that no other lane does
#
# B5 revokes the APP's runtime permission; this switches the DEVICE-WIDE
# location provider off underneath a live sharing session. They land in
# different code: `pm revoke` reaches `checkPermission()`'s denied branches,
# while the provider toggle reaches `Geolocator.isLocationServiceEnabled()`
# (via `GeolocatorLocationService._ensureAccessOrThrow()`, which both
# `getCurrentLocation()` and `getCurrentLocationFresh()` now run before they
# produce any coordinate) and the plugin's mid-stream
# `LocationServiceDisabledException`. Neither is reachable from the other,
# and NEITHER is reachable at all from `FakeLocationService`, whose
# `isLocationServiceEnabled()` is a hardcoded `true`
# (haven/integration_test/e2e/_lib/fake_location_service.dart:52). Every
# other scenario in this repo injects that fake, so before this lane the
# disabled-provider path executed nowhere in CI.
#
# B3 (`run-b3-real-gps.sh`) declines the fake and seeds a real fix, but it
# only ever runs with the provider ON. It proves the chain works; it says
# nothing about what happens when the user switches location off, which is
# the single most common way a location-sharing app goes quiet.
#
# # The oracle
#
# The drive target (`haven/integration_test/b6_location_provider_toggle_test
# .dart`) prints a marker per checkpoint; this shell drives the two `cmd
# location set-location-enabled` toggles from OUTSIDE the process, waiting on
# those markers, and then asserts the whole sequence from the capture:
#
#   1. BASELINE_PUBLISHED n=<N>, N >= 1        provider ON -> the app
#                                              publishes (PARSED, not
#                                              grepped: `n=0` is the
#                                              failing case and contains
#                                              the marker)
#   2. SURFACING_BASELINE present=false        anti-vacuity: no error
#                                              surface was ALREADY up
#   3. PROVIDER_DISABLED_OBSERVED              the toggle reached the app
#                                              itself, not just adb
#   4. DETECTED via=...                        the app KNOWS
#   5. PUBLISH_STOPPED tail=<S>s               publishing stopped, and how
#                                              long the documented
#                                              stale-cache tail lasted
#   6. SURFACING_PRESENT                       the user was TOLD
#   7. PROVIDER_REENABLED_OBSERVED +
#      PUBLISH_RESUMED n=<N>, N >= 1           recovery
#
# Every check is POSITIVE. An absence check would pass on a lane that never
# armed, and "the app published nothing" is the *expected* state for most of
# this sequence — so proving it means first proving the app was publishing.
#
# # STEP 6 WAS THE DELIVERABLE RED, AND IS NOW FIXED (2026-08-04)
#
# This lane was written to fail step 6, and that failure was predicted from
# source before the lane existed: both listeners of `locationStreamProvider`
# handled the error case with `next.whenData(...)`, which DISCARDS it, and
# the map's only error overlay was gated on a null location — false in every
# mid-session case. Haven stopped sharing location and told the user nothing.
#
# Both `whenData` sites are gone. A `locationAccessProvider` now owns
# detection (stream error, stream close, a 30 s silence watchdog, and app
# resume all funnel into one platform probe) and a `LocationAccessBanner`
# renders the verdict, distinguishing the device toggle from Haven's own
# permission because the two have different remedies. Step 6 is expected to
# PASS. If it fails, that is a regression, not the original defect.
#
# Do not "fix" this lane by relaxing the assertion (CLAUDE.md, Testing
# Requirements #5).
#
# Note what step 6 can and cannot prove: `find.text(...).evaluate()` matches
# OCCLUDED widgets, so a green step 6 proves the banner is in the tree, not
# that a user could see or tap it. Reachability at the bottom sheet's 0.85
# snap is pinned host-side instead, by hit-testing in
# `haven/test/pages/map_shell_banner_layering_test.dart`.
#
# # Traps this lane is built around
#
#   1. THE STALE-CACHE TAIL — CLOSED 2026-08-04, and the window is kept
#      anyway. `getCurrentLocation()` used to serve `_lastStreamPosition`
#      whenever the cached GPS FIX TIME was within `kStreamPositionMaxAge`
#      (168 s) BEFORE it consulted `isLocationServiceEnabled()` at all, so
#      publishing legitimately continued for up to 168 s after the toggle.
#      An access gate now runs before any coordinate is produced and the
#      cache is cleared the moment access loss is observed, so the tail
#      should measure ~0.
#
#      The window is deliberately NOT tightened to match. It bounds an
#      ABSENCE assertion, so a generous bound makes the assertion stronger,
#      and it is now the only thing that would catch the gate being reordered
#      back below the cache read. The reported tail changes meaning
#      accordingly: it was a measurement, it is now a REGRESSION SIGNAL.
#      A naive lane that asserted "no publish after the toggle" would still
#      fail a correct app on timing; one that checked once, early, would
#      still pass a broken one. The drive target therefore still requires
#      FOUR consecutive zero-publish cycles inside that window.
#   2. `adb emu geo fix` is a ONE-SHOT injection into the goldfish GNSS HAL.
#      The re-issue loop keeps running THROUGH the disabled window on
#      purpose: a publish that survived the toggle then proves the app
#      ignored the provider state, not that its position source dried up.
#   3. `pm grant` exits 0 even when it refuses (the hard-restricted gate is
#      a bare `return` after a `Log.e`), so `dumpsys package` is the gate —
#      same posture as run-b3-real-gps.sh.
#   4. The drive must run in the BACKGROUND here, because the toggles happen
#      MID-session. A two-drive design cannot express this lane: the whole
#      subject is one continuous session whose provider disappears under it.
#
# Usage:
#   run-b6-location-provider-toggle.sh [<apk> [<target.dart>]]
#   run-b6-location-provider-toggle.sh --self-test   # hermetic, no device
#
# Optional env:
#   B6_DRIVE_TIMEOUT       per-drive bound. Default 16m.
#   B6_GEO_REISSUE_SECS    `geo fix` re-issue period. Default 5.
#   B6_GEO_LAT/B6_GEO_LON  injected point. Defaults to a public landmark.

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
# haven/integration_test/b6_location_provider_toggle_test.dart — change both
# together or the lane silently stops finding them.
#
# Fixed literals matched with `grep -aF`: logcat is binary-tainted and these
# strings contain regex metacharacters.
# ---------------------------------------------------------------------------
readonly MARK_ARMED='[b6] ARMED'
readonly MARK_BASELINE='[b6] BASELINE_PUBLISHED'
readonly MARK_SURF_BASELINE='[b6] SURFACING_BASELINE'
readonly MARK_AWAIT_DISABLE='[b6] AWAITING_DISABLE'
readonly MARK_DISABLED='[b6] PROVIDER_DISABLED_OBSERVED'
readonly MARK_DETECTED='[b6] DETECTED'
readonly MARK_STOPPED='[b6] PUBLISH_STOPPED'
readonly MARK_NOT_STOPPED='[b6] PUBLISH_NOT_STOPPED'
readonly MARK_SURF_PRESENT='[b6] SURFACING_PRESENT'
readonly MARK_SURF_ABSENT='[b6] SURFACING_ABSENT'
readonly MARK_AWAIT_REENABLE='[b6] AWAITING_REENABLE'
readonly MARK_REENABLED='[b6] PROVIDER_REENABLED_OBSERVED'
readonly MARK_RESUMED='[b6] PUBLISH_RESUMED'
readonly MARK_NOT_RESUMED='[b6] PUBLISH_NOT_RESUMED'
readonly MARK_STREAM_OK='[b6] STREAM_RECOVERED'
readonly MARK_STREAM_DEAD='[b6] STREAM_DEAD'
readonly MARK_COMPLETE='[b6] SEQUENCE_COMPLETE'

# ---------------------------------------------------------------------------
# Oracle predicates — pure text, no device. Everything the lane's verdict
# rests on lives here so `--self-test` can exercise it hermetically.
# ---------------------------------------------------------------------------

# b6_android_system_died <file>... — 0 (true) iff the ANDROID SYSTEM PROCESS
# died during this run, as distinct from the app crashing.
#
# THIS LANE PROVOKES A REAL EMULATOR BUG. It toggles the device-wide location
# provider, and on the api-34 image the GNSS HAL can deadlock when a stop
# arrives shortly after the provider was re-enabled. In CI run 30980908814 the
# system server's foreground thread sat in `GnssNative.native_stop()` for 66 s
# and the platform Watchdog SIGKILLed it:
#
#   W Watchdog: *** WATCHDOG KILLING SYSTEM PROCESS: Blocked in handler on
#               foreground thread (android.fg) for 66s
#     at com.android.server.location.gnss.hal.GnssNative.native_stop
#     at ...GnssLocationProvider.stopNavigating
#   I Process : Sending signal. PID: 518 SIG: 9
#
# The app had made exactly ONE `startPositionUpdates` / ONE stop — no thrashing.
# Nothing the app can do makes a native HAL stop hang, so this is infrastructure
# by construction. But the lane reported it as two PRODUCT findings ("the drive
# never printed SEQUENCE_COMPLETE", "no PUBLISH_RESUMED line"), which are pure
# consequences of the OS dying underneath it — a red lane blaming the app for
# the emulator.
#
# DISCRIMINATION IS THE WHOLE POINT, so only markers that the SYSTEM's death
# produces are matched:
#
#   * `WATCHDOG KILLING SYSTEM PROCESS` — the platform Watchdog's own verdict,
#     emitted only when it kills system_server.
#   * `DeadSystemException` — the framework's exception for "binder to
#     system_server failed because system_server is gone". Its own message is
#     "The system died".
#
# An ordinary app crash (`FATAL EXCEPTION` with, say, a NullPointerException in
# the app's process) matches NEITHER, so it stays a product defect. That is
# deliberate: an app that crashes when the location provider is toggled is
# exactly what this lane exists to catch, and must never be excused as infra.
b6_android_system_died() {
  local f
  for f in "$@"; do
    [[ -f "${f}" ]] || continue
    if LC_ALL=C grep -aqE \
      'WATCHDOG KILLING SYSTEM PROCESS|DeadSystemException' "${f}"; then
      return 0
    fi
  done
  return 1
}

# b6_system_death_reason <file>... — echo the one-line watchdog verdict (or the
# DeadSystemException line) so the operator sees WHY without opening artefacts.
b6_system_death_reason() {
  local f
  for f in "$@"; do
    [[ -f "${f}" ]] || continue
    LC_ALL=C grep -ahoE \
      'WATCHDOG KILLING SYSTEM PROCESS[^"]*|DeadSystemException[^"]*' "${f}" \
      | head -1 && return 0
  done
  return 0
}

# b6_has_marker <logfile> <marker> — 0 (true) when the marker appears.
#
# Substring match, not anchored: the same line reaches us either as raw
# `debugPrint` output in the drive log or wrapped by logcat's
# `I/flutter ( 1234): ` prefix, and both must count.
b6_has_marker() {
  local logfile="${1:-}" marker="${2:-}"
  [[ -f "${logfile}" ]] || return 1
  grep -aqF -- "${marker}" "${logfile}"
}

# b6_marker_number <logfile> <marker> <key> — echoes the LARGEST integer
# following `<key>=` on any line carrying <marker>, or nothing when no such
# line exists.
#
# PARSED, never grepped for presence. `[b6] BASELINE_PUBLISHED n=0` is the
# failing case and contains the marker substring, so a presence check would
# bless a run in which the app published to nothing. Largest rather than
# first because a marker may legitimately be printed more than once.
#
# `sort -n`, never lexical: '9' outranks '12' lexically.
b6_marker_number() {
  local logfile="${1:-}" marker="${2:-}" key="${3:-}"
  [[ -f "${logfile}" ]] || return 0
  { grep -aF -- "${marker}" "${logfile}" 2>/dev/null \
      | grep -aoE "${key}=[0-9]+" \
      | grep -aoE '[0-9]+' | sort -n | tail -1; } || true
}

# b6_marker_flag <logfile> <marker> <key> — echoes the LAST `<key>=<word>`
# value on any line carrying <marker>, or nothing.
#
# Used for the `present=true|false` anti-vacuity reading, where the VALUE is
# the verdict and presence of the marker means only that the drive got there.
b6_marker_flag() {
  local logfile="${1:-}" marker="${2:-}" key="${3:-}"
  [[ -f "${logfile}" ]] || return 0
  { grep -aF -- "${marker}" "${logfile}" 2>/dev/null \
      | grep -aoE "${key}=[A-Za-z0-9_.-]+" \
      | sed "s/^${key}=//" | tail -1 | tr -d '\r'; } || true
}

# b6_permission_granted <dumpsys-file> <permission> — 0 (true) when
# `dumpsys package` reports the permission as granted.
#
# `pm grant`'s exit code is worthless (trap 3 in the header), so this is the
# gate. Matched on the `<perm>: granted=true` shape rather than on
# `granted=true` alone, because one dump lists every permission and a
# neighbouring granted one would otherwise answer for ours.
b6_permission_granted() {
  local dump="${1:-}" perm="${2:-}"
  [[ -f "${dump}" ]] || return 1
  grep -aqE "${perm}: granted=true" "${dump}"
}

# ---------------------------------------------------------------------------
# The oracle itself, as a testable function over a capture file.
#
# Findings accumulate in B6_FINDINGS rather than exiting on the first one:
# the lane's value is the WHOLE picture (did it publish, did it stop, was the
# user told, did it recover), and stopping at the first failure would hide
# the rest behind it. Returns 1 when any finding was recorded.
#
# NOTES (never failures) go to stdout as evidence.
# ---------------------------------------------------------------------------
B6_FINDINGS=()

b6_note() { printf '  NOTE: %s\n' "$*"; }
b6_finding() { B6_FINDINGS+=("$*"); }

b6_run_oracle() {
  local log="${1:-}"
  B6_FINDINGS=()

  if [[ ! -f "${log}" ]]; then
    b6_finding "no capture file at '${log}' — the lane recorded nothing."
    return 1
  fi

  # (1) The drive reached the end of its own sequence. Checked FIRST because
  #     every later "marker absent" finding would otherwise be reported as a
  #     product defect when the true cause is a drive that died early.
  if ! b6_has_marker "${log}" "${MARK_COMPLETE}"; then
    b6_finding "the drive never printed '${MARK_COMPLETE}' — it did not \
reach the end of its sequence, so every absent marker below may be a \
consequence of that rather than a product defect. Rule the drive out first."
  fi

  # (2) BASELINE — provider ON, the app publishes. PARSED.
  local baseline
  baseline="$(b6_marker_number "${log}" "${MARK_BASELINE}" 'n')"
  if [[ -z "${baseline}" ]]; then
    b6_finding "no '${MARK_BASELINE} n=<N>' line — the drive never completed \
a baseline publish attempt, so nothing observed after the toggle can be \
attributed to it."
  elif (( baseline < 1 )); then
    b6_finding "baseline publish reached ${baseline} circles with the \
location provider ENABLED. The app was not publishing BEFORE the toggle, so \
observing that it does not publish after it proves nothing. Suspect the \
emulator GPS seed (\`adb emu geo fix\`), the verified permission grant, or \
circle eligibility."
  else
    b6_note "baseline: published to ${baseline} circle(s) with the provider ON."
  fi

  # (3) ANTI-VACUITY — no error surface was already up while healthy.
  local surf_baseline
  surf_baseline="$(b6_marker_flag "${log}" "${MARK_SURF_BASELINE}" 'present')"
  if [[ -z "${surf_baseline}" ]]; then
    b6_finding "no '${MARK_SURF_BASELINE} present=<bool>' line — without the \
healthy-state reading, the surfacing verdict below cannot be distinguished \
from an error surface that was up the whole time."
  elif [[ "${surf_baseline}" != "false" ]]; then
    b6_finding "an error surface was ALREADY visible before the provider was \
disabled (${MARK_SURF_BASELINE} present=${surf_baseline}). The surfacing \
verdict is VACUOUS on this run — fix the harness before reading anything \
into it."
  fi

  # (4) The toggle reached the app under test, not merely adb.
  if ! b6_has_marker "${log}" "${MARK_DISABLED}"; then
    b6_finding "the app never observed isLocationServiceEnabled() == false \
(no '${MARK_DISABLED}'). \`cmd location set-location-enabled false\` did not \
reach the process under test, so this run exercised nothing."
  fi

  # (5) The app DETECTED it.
  if ! b6_has_marker "${log}" "${MARK_DETECTED}"; then
    b6_finding "the app never DETECTED the disabled provider (no \
'${MARK_DETECTED}'): a fresh location read SUCCEEDED and the position stream \
reported no error while the OS provider was off."
  fi

  # (6) Publishing stopped. Positive marker, and its negative twin is called
  #     out separately so the message names the right failure.
  if b6_has_marker "${log}" "${MARK_NOT_STOPPED}"; then
    b6_finding "publishing did NOT stop after the provider was disabled \
('${MARK_NOT_STOPPED}'). The app kept broadcasting location after the user \
switched location services off — a privacy failure, not a liveness one."
  elif ! b6_has_marker "${log}" "${MARK_STOPPED}"; then
    b6_finding "no '${MARK_STOPPED}' line — the drive never confirmed that \
publishing stopped. Neither outcome was recorded, so the disabled window was \
not measured at all."
  else
    local tail_secs
    tail_secs="$(b6_marker_number "${log}" "${MARK_STOPPED}" 'tail')"
    b6_note "publishing stopped ${tail_secs:-?}s after the provider was \
disabled. This should now be ~0s: getCurrentLocation() runs its access gate \
before serving any coordinate, and the cached fix is cleared as soon as \
access loss is observed. A tail approaching kStreamPositionMaxAge (168s) \
means the gate was reordered back below the cache read."
  fi

  # (7) THE HEADLINE. Was the deliverable red; fixed 2026-08-04 — see header.
  if ! b6_has_marker "${log}" "${MARK_SURF_PRESENT}"; then
    if b6_has_marker "${log}" "${MARK_SURF_ABSENT}"; then
      b6_finding "the disabled location provider was NOT surfaced to the \
user ('${MARK_SURF_ABSENT}'). Location sharing stopped silently and the map \
kept showing the last fix. This is a REGRESSION, not the original defect: \
the surfacing landed 2026-08-04 (locationAccessProvider + \
LocationAccessBanner). Check that the banner is still rendered from \
MapShell.buildLayers, that the disclosure flag is set (a closed disclosure \
gate keeps the banner silent by design), and that detection still fires — \
stream error, stream close, the 30s silence watchdog, or app resume. See \
docs/CI_HARDENING_BACKLOG.md B6."
    else
      b6_finding "neither '${MARK_SURF_PRESENT}' nor '${MARK_SURF_ABSENT}' \
was recorded — the drive never reached the surfacing check."
    fi
  fi

  # (8) Recovery.
  if ! b6_has_marker "${log}" "${MARK_REENABLED}"; then
    b6_finding "the app never observed isLocationServiceEnabled() == true \
again (no '${MARK_REENABLED}') — recovery was not tested."
  elif b6_has_marker "${log}" "${MARK_NOT_RESUMED}"; then
    b6_finding "publishing did NOT resume after the provider was re-enabled \
('${MARK_NOT_RESUMED}'). Turning location back on left sharing dead for the \
rest of the session."
  else
    local resumed
    resumed="$(b6_marker_number "${log}" "${MARK_RESUMED}" 'n')"
    if [[ -z "${resumed}" ]]; then
      b6_finding "no '${MARK_RESUMED} n=<N>' line — the drive never \
confirmed that publishing came back."
    elif (( resumed < 1 )); then
      b6_finding "publishing 'resumed' to ${resumed} circles after the \
provider was re-enabled, i.e. it did not resume."
    else
      b6_note "recovery: published to ${resumed} circle(s) after re-enable."
    fi
  fi

  # (9) EVIDENCE ONLY — never a finding. The continuous position stream is a
  #     different mechanism from the one-shot the publisher uses, and the
  #     Android plugin's disable path (`removeUpdates` +
  #     `currentLocationProvider = null`, with an EMPTY `onProviderEnabled`)
  #     gives it no way back without a re-subscription. Recorded so the lane
  #     states which of the two recovered instead of implying both did.
  if b6_has_marker "${log}" "${MARK_STREAM_OK}"; then
    b6_note "the continuous position stream ALSO recovered."
  elif b6_has_marker "${log}" "${MARK_STREAM_DEAD}"; then
    b6_note "the continuous position stream did NOT recover (publishing did, \
via the one-shot path). Expected on Android: LocationManagerClient \
.onProviderDisabled calls removeUpdates and nulls its provider, and \
onProviderEnabled is an empty method. Recorded, not asserted."
  fi

  (( ${#B6_FINDINGS[@]} == 0 ))
}

# ---------------------------------------------------------------------------
# Self-test — hermetic fixtures, no device, no relay.
#
# The fixtures are chosen so a predicate that has rotted into always-passing
# cannot survive: (5) is the `n=0` near-miss a presence-grep would bless,
# (12) is TODAY'S REAL BEHAVIOUR (everything green except the surfacing) and
# must be reported as a failure, and (13) is the fully-fixed app, which must
# be reported as a pass — without it, a hard-coded "always red" oracle would
# look correct.
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

  # A complete, PASSING capture: the app publishes, stops, TELLS THE USER,
  # and recovers. Written as a function so each negative fixture can mutate
  # exactly one line and nothing else.
  _fixture_full() { # _fixture_full <outfile> [surfacing-line]
    local out="$1" surf="${2:-I/flutter ( 40): ${MARK_SURF_PRESENT}}"
    printf '%s\n' \
      "I/flutter ( 40): ${MARK_BASELINE} n=1" \
      "I/flutter ( 40): ${MARK_SURF_BASELINE} present=false" \
      "I/flutter ( 40): ${MARK_ARMED}" \
      "I/flutter ( 40): ${MARK_AWAIT_DISABLE}" \
      "I/flutter ( 40): ${MARK_DISABLED}" \
      "I/flutter ( 40): ${MARK_DETECTED} via=service-layer-throw+stream-error" \
      "I/flutter ( 40): ${MARK_STOPPED} tail=176s checks=4" \
      "${surf}" \
      "I/flutter ( 40): ${MARK_AWAIT_REENABLE}" \
      "I/flutter ( 40): ${MARK_REENABLED}" \
      "I/flutter ( 40): ${MARK_RESUMED} n=1" \
      "I/flutter ( 40): ${MARK_STREAM_DEAD}" \
      "I/flutter ( 40): ${MARK_COMPLETE}" \
      > "${out}"
  }

  echo "run-b6-location-provider-toggle.sh --self-test"

  # --- b6_has_marker ------------------------------------------------------
  # (1) A raw drive-log line (no logcat prefix).
  printf '%s\n' "${MARK_DISABLED}" > "${tmp}/raw.log"
  local rc=0; b6_has_marker "${tmp}/raw.log" "${MARK_DISABLED}" || rc=1
  _case "marker found in a raw drive log" 0 "${rc}"

  # (2) THE SHAPE THAT ACTUALLY SHIPS — the same line via logcat, prefixed.
  #     An anchored match would pass fixture (1) and fail every real run.
  printf '%s\n' "I/flutter ( 4021): ${MARK_DISABLED}" > "${tmp}/logcat.log"
  rc=0; b6_has_marker "${tmp}/logcat.log" "${MARK_DISABLED}" || rc=1
  _case "marker found behind a logcat prefix" 0 "${rc}"

  # (3) A missing file is not evidence of success.
  rc=0; b6_has_marker "${tmp}/nope.log" "${MARK_DISABLED}" || rc=1
  _case "missing log reports absent" 1 "${rc}"

  # --- b6_marker_number ---------------------------------------------------
  # (4) The ordinary case.
  printf '%s\n' "I/flutter ( 40): ${MARK_BASELINE} n=2" > "${tmp}/n2.log"
  _eq_case "count parsed" "2" \
    "$(b6_marker_number "${tmp}/n2.log" "${MARK_BASELINE}" 'n')"

  # (5) THE CRITICAL FIXTURE — `n=0` is the publisher reporting it published
  #     to NOTHING, on a line that CONTAINS the marker. A presence-grep
  #     blesses it; the parser must report 0 so the caller fails the lane.
  printf '%s\n' "I/flutter ( 40): ${MARK_BASELINE} n=0" > "${tmp}/n0.log"
  _eq_case "zero count parsed as 0 (not as presence)" "0" \
    "$(b6_marker_number "${tmp}/n0.log" "${MARK_BASELINE}" 'n')"

  # (6) Absent marker -> empty, which is DISTINCT from "0".
  printf '%s\n' 'I/flutter ( 40): nothing here' > "${tmp}/nnone.log"
  _eq_case "absent marker yields empty (not 0)" "" \
    "$(b6_marker_number "${tmp}/nnone.log" "${MARK_BASELINE}" 'n')"

  # (7) Double digits must not lose to a lexical sort ('9' > '12').
  printf '%s\n' \
    "I/flutter ( 40): ${MARK_STOPPED} tail=9s checks=4" \
    "I/flutter ( 40): ${MARK_STOPPED} tail=176s checks=4" \
    > "${tmp}/wide.log"
  _eq_case "numeric (not lexical) max" "176" \
    "$(b6_marker_number "${tmp}/wide.log" "${MARK_STOPPED}" 'tail')"

  # (8) A key on an UNRELATED marker must not answer for ours — both the
  #     baseline and the recovery marker carry `n=`.
  printf '%s\n' \
    "I/flutter ( 40): ${MARK_BASELINE} n=0" \
    "I/flutter ( 40): ${MARK_RESUMED} n=7" \
    > "${tmp}/mixed.log"
  _eq_case "key scoped to its own marker" "0" \
    "$(b6_marker_number "${tmp}/mixed.log" "${MARK_BASELINE}" 'n')"

  # --- b6_marker_flag -----------------------------------------------------
  # (9) The healthy reading.
  printf '%s\n' "I/flutter ( 40): ${MARK_SURF_BASELINE} present=false" \
    > "${tmp}/f0.log"
  _eq_case "flag parsed (false)" "false" \
    "$(b6_marker_flag "${tmp}/f0.log" "${MARK_SURF_BASELINE}" 'present')"

  # (10) The vacuous reading, with the CRLF adb actually emits.
  printf "I/flutter ( 40): ${MARK_SURF_BASELINE} present=true\r\n" \
    > "${tmp}/f1.log"
  _eq_case "flag parsed (true, CRLF)" "true" \
    "$(b6_marker_flag "${tmp}/f1.log" "${MARK_SURF_BASELINE}" 'present')"

  # --- b6_permission_granted ---------------------------------------------
  # (11) A granted NEIGHBOUR must not answer for us: `dumpsys package`
  #      prints every permission, so a bare `granted=true` grep would report
  #      ours as held on the strength of an unrelated one.
  printf '%s\n' \
    '    android.permission.INTERNET: granted=true' \
    '    android.permission.ACCESS_FINE_LOCATION: granted=false' \
    > "${tmp}/perm.txt"
  rc=0
  b6_permission_granted "${tmp}/perm.txt" \
    'android.permission.ACCESS_FINE_LOCATION' || rc=1
  _case "granted neighbour does not answer for us" 1 "${rc}"

  # --- b6_run_oracle ------------------------------------------------------
  # (12) TODAY'S REAL BEHAVIOUR: publishes, stops, recovers — and tells the
  #      user NOTHING. This MUST be reported as a failure, or the lane
  #      blesses the defect it exists to find.
  _fixture_full "${tmp}/today.log" "I/flutter ( 40): ${MARK_SURF_ABSENT}"
  rc=0; b6_run_oracle "${tmp}/today.log" >/dev/null || rc=1
  _case "silent-failure capture is REPORTED (today's behaviour)" 1 "${rc}"
  if (( rc == 1 )) && [[ "${B6_FINDINGS[*]}" != *"NOT surfaced"* ]]; then
    printf '  \033[1;31mFAIL\033[0m silent-failure finding does not name the surfacing defect\n' >&2
    fails=1
  fi

  # (13) THE FIXED APP — identical except that the user IS told. Must PASS,
  #      or an oracle hard-coded to red would look correct in fixture (12).
  _fixture_full "${tmp}/fixed.log"
  rc=0; b6_run_oracle "${tmp}/fixed.log" >/dev/null || rc=1
  _case "fully-correct capture PASSES" 0 "${rc}"

  # (14) A baseline of ZERO makes the whole run vacuous, even though every
  #      other marker is present: "it stopped publishing" is meaningless if
  #      it was never publishing.
  _fixture_full "${tmp}/nobase.log"
  sed -i "s/${MARK_BASELINE//[/\\[} n=1/${MARK_BASELINE//[/\\[} n=0/" \
    "${tmp}/nobase.log"
  rc=0; b6_run_oracle "${tmp}/nobase.log" >/dev/null || rc=1
  _case "zero baseline fails the lane" 1 "${rc}"

  # (15) An error surface that was ALREADY up makes the surfacing verdict
  #      vacuous — a false GREEN route, since SURFACING_PRESENT would then
  #      be true for the wrong reason.
  _fixture_full "${tmp}/vacuous.log"
  sed -i 's/present=false/present=true/' "${tmp}/vacuous.log"
  rc=0; b6_run_oracle "${tmp}/vacuous.log" >/dev/null || rc=1
  _case "pre-existing error surface fails as vacuous" 1 "${rc}"

  # (16) Publishing that never stopped is the privacy failure. Distinct
  #      message from "no verdict recorded", so the two cannot be conflated.
  _fixture_full "${tmp}/nostop.log"
  sed -i "s/${MARK_STOPPED//[/\\[} tail=176s checks=4/${MARK_NOT_STOPPED//[/\\[} reason=StateError/" \
    "${tmp}/nostop.log"
  rc=0; b6_run_oracle "${tmp}/nostop.log" >/dev/null || rc=1
  _case "publishing that never stopped fails the lane" 1 "${rc}"
  if (( rc == 1 )) && [[ "${B6_FINDINGS[*]}" != *"kept broadcasting"* ]]; then
    printf '  \033[1;31mFAIL\033[0m never-stopped finding does not name the privacy failure\n' >&2
    fails=1
  fi

  # (17) A truncated capture (the drive died) must say so FIRST, so its
  #      downstream absences are not misread as product defects.
  printf '%s\n' \
    "I/flutter ( 40): ${MARK_BASELINE} n=1" \
    "I/flutter ( 40): ${MARK_SURF_BASELINE} present=false" \
    "I/flutter ( 40): ${MARK_AWAIT_DISABLE}" \
    > "${tmp}/truncated.log"
  rc=0; b6_run_oracle "${tmp}/truncated.log" >/dev/null || rc=1
  _case "truncated capture fails the lane" 1 "${rc}"
  if (( rc == 1 )) && [[ "${B6_FINDINGS[0]}" != *"${MARK_COMPLETE}"* ]]; then
    printf '  \033[1;31mFAIL\033[0m truncated capture does not report the drive first\n' >&2
    fails=1
  fi

  # (18) A missing capture proves nothing and must never pass.
  rc=0; b6_run_oracle "${tmp}/absent.log" >/dev/null || rc=1
  _case "missing capture fails the lane" 1 "${rc}"

  # (19) The drive-log failure predicate this lane leans on is exercised by
  #      its own self-test; assert only that sourcing worked, so a refactor
  #      that drops the `source` fails here rather than at 3am.
  rc=0; declare -F drive_log_reports_test_failure >/dev/null || rc=1
  _case "drive-log failure predicate is in scope" 0 "${rc}"

  # --- system-death classification -----------------------------------------
  #
  # The discrimination is the whole value: an emulator that died must not be
  # blamed on the app, and an app that crashed must not be excused as the
  # emulator. Both directions are pinned, and the app-crash fixture is the one
  # that matters — it is what stops this becoming a blanket "ignore red".
  local sd="${tmp}/sysdeath"
  mkdir -p "${sd}"

  # (a) THE REAL SHAPE, verbatim from CI run 30980908814.
  printf '%s\n' \
    '08-05 06:40:32.212   518   543 W Watchdog: *** WATCHDOG KILLING SYSTEM PROCESS: Blocked in handler on  on foreground thread (android.fg) for 66s' \
    '08-05 06:40:32.213   518   543 W Watchdog:     at com.android.server.location.gnss.hal.GnssNative.native_stop(Native Method)' \
    '08-05 06:40:32.214   518   543 I Process : Sending signal. PID: 518 SIG: 9' \
    > "${sd}/watchdog.log"
  rc=0; b6_android_system_died "${sd}/watchdog.log" || rc=1
  _case "a watchdog-killed system_server reads as INFRASTRUCTURE" 0 "${rc}"

  # (b) The app's own view of the same event.
  printf '%s\n' \
    'E/AndroidRuntime( 3579): FATAL EXCEPTION: main' \
    'E/AndroidRuntime( 3579): Process: com.oblivioustech.haven, PID: 3579' \
    'E/AndroidRuntime( 3579): DeadSystemException: The system died; earlier logs will point to the root cause' \
    > "${sd}/deadsystem.log"
  rc=0; b6_android_system_died "${sd}/deadsystem.log" || rc=1
  _case "DeadSystemException reads as INFRASTRUCTURE" 0 "${rc}"

  # (c) THE CRITICAL NEGATIVE. An ordinary app crash — same FATAL EXCEPTION
  #     shape, same process, no system-death marker anywhere. An app that dies
  #     when the location provider is toggled is precisely what this lane
  #     exists to catch and must NEVER be written off as infrastructure.
  printf '%s\n' \
    'E/AndroidRuntime( 3579): FATAL EXCEPTION: main' \
    'E/AndroidRuntime( 3579): Process: com.oblivioustech.haven, PID: 3579' \
    'E/AndroidRuntime( 3579): java.lang.NullPointerException: position was null' \
    'E/AndroidRuntime( 3579):     at com.oblivioustech.haven.MainActivity.onResume' \
    > "${sd}/appcrash.log"
  rc=0; b6_android_system_died "${sd}/appcrash.log" || rc=1
  _case "an ordinary app crash stays a PRODUCT failure" 1 "${rc}"

  # (d) A clean run implicates nothing.
  printf '%s\n' \
    '08-05 06:38:44.764  3579  3579 I flutter : [b6] SURFACING_PRESENT' \
    '08-05 06:38:46.817  3579  3579 I flutter : [b6] PROVIDER_REENABLED_OBSERVED' \
    > "${sd}/clean.log"
  rc=0; b6_android_system_died "${sd}/clean.log" || rc=1
  _case "a healthy log is not mistaken for a system death" 1 "${rc}"

  # (e) Absent/empty inputs must not read as a system death — otherwise a
  #     missing capture would silently excuse every red.
  rc=0; b6_android_system_died "${sd}/nope.log" || rc=1
  _case "an absent log is not a system death" 1 "${rc}"

  # (f) The reason line is extracted for the operator.
  _eq_case "the watchdog verdict is surfaced in the message" \
    "1" "$(b6_system_death_reason "${sd}/watchdog.log" \
            | grep -ac 'WATCHDOG KILLING SYSTEM PROCESS' || true)"

  if (( fails )); then
    echo "run-b6-location-provider-toggle.sh --self-test: FAILURES" >&2
    return 1
  fi
  echo "run-b6-location-provider-toggle.sh --self-test: all 25 fixtures passed"
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
readonly LOG_DIR="/tmp/b6-logs"
readonly APK="${1:-/tmp/integration-apks/b6_location_provider_toggle_test.apk}"
readonly TARGET="${2:-integration_test/b6_location_provider_toggle_test.dart}"

# Bounds the drive only; the step's run-with-deadline.sh wrapper bounds
# install + grants + GPS seeding + the toggles + the oracle on top (see
# scripts/ci/check_e2e_step_timeout_ordering.sh for the ordering invariant).
#
# Sizing: the drive target's own budget is arming (~60s under emulator mlock
# pressure) + up to 150s for the baseline publish + up to 90s waiting for the
# disable + the 168s stale-cache tail plus sustained checks (~260s) + up to
# 90s waiting for the re-enable + up to 150s for recovery = ~13 min worst
# case, against a 12-minute in-test `Timeout`. 16m leaves headroom for a slow
# cold start without letting a wedge run anonymously to the outer deadline.
readonly DRIVE_TIMEOUT="${B6_DRIVE_TIMEOUT:-16m}"

# `adb emu geo fix` re-issue period. The injection is one-shot into the
# goldfish GNSS HAL (trap 2), so it must be re-issued for the life of the
# lane — INCLUDING through the disabled window, on purpose.
readonly GEO_REISSUE_SECS="${B6_GEO_REISSUE_SECS:-5}"

# The injected point: Uluru, Australia — a public landmark, chosen precisely
# BECAUSE it is obviously not a real user's position, and distinct from B1's
# Dam Square and B3's Christ the Redeemer so a stray fix is unmistakable.
# This lane never ASSERTS the value (that is B3's job), so no --dart-define
# pairing is needed; it only needs a fix to exist.
#
# WARNING before overriding: `fail()` dumps `dumpsys location`, which PRINTS
# the active position into the step log and the uploaded artifact. Fine for a
# hardcoded landmark, NOT fine for anything derived from a real device.
readonly GEO_LAT="${B6_GEO_LAT:--25.344490}"
readonly GEO_LON="${B6_GEO_LON:-131.035431}"
# Validated because both are interpolated into an `adb emu geo fix` argument
# list; an unvalidated value could word-split into extra arguments.
if [[ ! "${GEO_LAT}" =~ ^-?[0-9]{1,2}(\.[0-9]{1,12})?$ ]] ||
   [[ ! "${GEO_LON}" =~ ^-?[0-9]{1,3}(\.[0-9]{1,12})?$ ]]; then
  echo "ERROR: B6_GEO_LAT/B6_GEO_LON must be plain decimal degrees" \
       "(got '${GEO_LAT}' / '${GEO_LON}')." >&2
  exit 2
fi

# How long to wait for each of the drive's cue markers before giving up.
# Generous relative to the drive's own internal budgets, because a marker
# that is late is still usable evidence while a marker wait that fires early
# destroys the run.
readonly ARM_MARKER_TIMEOUT="${B6_ARM_MARKER_TIMEOUT:-420}"
readonly DISABLED_MARKER_TIMEOUT="${B6_DISABLED_MARKER_TIMEOUT:-480}"

readonly REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
readonly HAVEN_DIR="${REPO_ROOT}/haven"
readonly START_STRFRY="${SCRIPT_DIR}/start-strfry.sh"
readonly STOP_STRFRY="${SCRIPT_DIR}/stop-strfry.sh"
readonly SECRET_SCAN="${SCRIPT_DIR}/scan-logs-for-secrets.sh"

LOGCAT_PID=""
GEO_PID=""
DRIVE_PID=""

mkdir -p "${LOG_DIR}"
readonly LOGCAT_FILE="${LOG_DIR}/logcat.b6.log"
readonly DRIVE_LOG="${LOG_DIR}/flutter-drive.log"
readonly PERM_DUMP="${LOG_DIR}/permissions.b6.log"
readonly TOGGLE_LOG="${LOG_DIR}/provider-toggles.b6.log"

# ---------------------------------------------------------------------------
# Cleanup (EXIT trap): stop the background helpers, RESTORE the location
# provider (a lane that left it off would silently poison any later job on
# this runner), run the MANDATORY secret scan over every captured log
# (Security Rule 6 — must run even on a phase failure), snapshot + tear down
# strfry. Escalates on a leak; never masks a phase rc.
#
# Mirrors run-b1-fgs-publish.sh / run-b3-real-gps.sh containment, including
# the deliberate asymmetry between rc 1 (leak -> destroy the logs) and rc 3
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
  if [[ -n "${GEO_PID}" ]] && kill -0 "${GEO_PID}" 2>/dev/null; then
    kill "${GEO_PID}" 2>/dev/null || true
  fi
  # Restore BEFORE logcat is stopped so the restore itself is captured.
  adb -s "${DEVICE}" shell cmd location set-location-enabled true \
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
    echo "ERROR: secret-leak guard tripped on B6 logs — logs deleted," \
         "not uploaded." >&2
    rc=1
  elif (( scan_rc != 0 )); then
    echo "ERROR: secret-leak guard could not scan the B6 logs" \
         "(rc=${scan_rc}) — see the UNUSABLE line(s) above. Logs kept for" \
         "triage." >&2
    rc=1
  fi
  bash "${STOP_STRFRY}" >/dev/null 2>&1 || true
  exit "${rc}"
}
trap cleanup EXIT

fail() {
  # INFRASTRUCTURE FIRST. When the Android system process died, nothing this
  # lane observed afterwards is attributable to the app: the drive lost its VM
  # service, `cmd` lost `activity` and `package`, and every "marker missing"
  # finding below is a consequence of that. Reporting those as product defects
  # is how an emulator bug becomes hours spent reading app code (CI run
  # 30980908814). The findings are still PRINTED — they are evidence — but the
  # verdict says what actually happened.
  #
  # This cannot excuse a product failure: `b6_android_system_died` matches only
  # markers the SYSTEM's death produces, so an app crash still lands below.
  if b6_android_system_died "${LOGCAT_FILE}" "${DRIVE_LOG}"; then
    echo "B6-LANE-INFRA: the ANDROID SYSTEM PROCESS died during this run, so" \
         "the lane could not observe the product at all." >&2
    echo "  verdict: $(b6_system_death_reason "${LOGCAT_FILE}" "${DRIVE_LOG}")" >&2
    echo "  This lane toggles the device-wide location provider, and the" \
         "api-34 emulator's GNSS HAL can deadlock in native_stop() when a stop" \
         "arrives soon after a re-enable; the platform Watchdog then SIGKILLs" \
         "system_server. Haven cannot cause a native HAL stop to hang." >&2
    echo "  What would have been reported as findings, kept as EVIDENCE only:" >&2
    echo "    $*" >&2
    echo "  Re-run the lane. If this recurs often, the toggle cadence or the" \
         "emulator image is the thing to change, not the app." >&2
    # Non-zero on purpose — an infrastructure fault must never read as a pass —
    # but a DISTINCT code so it is greppable and separable from a product red.
    exit 75
  fi
  echo "B6-LANE-FAIL: $*" >&2
  if (( ${drive_failed:-0} == 1 )); then
    echo "NOTE: the drive ALSO did not complete cleanly" \
         "(${drive_reason:-unknown}). The finding above may be a CONSEQUENCE" \
         "of that rather than a product defect — rule the drive failure out" \
         "first." >&2
  fi
  echo "---- [b6] markers seen ----" >&2
  grep -ahF '[b6] ' "${LOGCAT_FILE}" "${DRIVE_LOG}" 2>/dev/null | tail -40 >&2 \
    || echo "(none — the drive target reached no checkpoint at all)" >&2
  echo "---- provider toggle log ----" >&2
  cat "${TOGGLE_LOG}" >&2 2>/dev/null || echo "(no toggles recorded)" >&2
  # The injected point is a hardcoded public landmark, so printing it is
  # acceptable here (same posture as run-b1/b3). See the GEO_LAT note.
  echo "---- emulator location state ----" >&2
  adb -s "${DEVICE}" shell dumpsys location 2>/dev/null \
    | grep -aiA 4 'last location\|fused\|gps provider' | head -40 >&2 \
    || echo "(dumpsys location unavailable)" >&2
  exit 1
}

# provider_state — echoes `true` / `false` as the platform reports it.
provider_state() {
  adb -s "${DEVICE}" shell cmd location is-location-enabled 2>/dev/null \
    | tr -d '\r' | tr -d '[:space:]' || true
}

# set_provider <true|false> — toggles the device-wide location provider and
# VERIFIES the read-back. A toggle that silently did not take would present
# as "the app never observed the provider as disabled", i.e. as a product
# finding, which is exactly the misattribution this lane must not make.
set_provider() {
  local want="$1" got=""
  adb -s "${DEVICE}" shell cmd location set-location-enabled "${want}" \
    >/dev/null 2>&1 || true
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    got="$(provider_state)"
    [[ "${got}" == "${want}" ]] && break
    sleep 1
  done
  printf '%s set-location-enabled %s -> is-location-enabled=%s\n' \
    "$(date -u +%H:%M:%S)" "${want}" "${got:-<unreadable>}" >> "${TOGGLE_LOG}"
  if [[ "${got}" != "${want}" ]]; then
    fail "\`cmd location set-location-enabled ${want}\` did not take:" \
         "\`is-location-enabled\` still reports '${got:-<unreadable>}'." \
         "This is a HARNESS failure, not a product finding — the app was" \
         "never shown the state this lane exists to test."
  fi
  echo "  provider now: ${got}"
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
# Phase 2 — runtime permissions, VERIFIED.
#
# This lane's subject is the SERVICE-ENABLED gate, which sits ABOVE the
# permission gate in `getCurrentLocation()`. Holding the permission for real
# is therefore a precondition, not the subject: without it the baseline
# publish fails for the wrong reason and the whole sequence is unattributable.
# `pm grant` exits 0 even when it refuses (trap 3), so `dumpsys package` is
# the gate.
#
# ACCESS_BACKGROUND_LOCATION is deliberately NOT granted: this lane publishes
# from a VISIBLE activity, and granting more than the scenario needs would
# quietly stop the lane representing real foreground users' permission state.
# ---------------------------------------------------------------------------
echo "Phase 2/6 — granting and VERIFYING runtime permissions..."
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
  if b6_permission_granted "${PERM_DUMP}" "${perm}"; then
    echo "  verified ${perm}: granted=true"
  else
    grep -a "${perm}" "${PERM_DUMP}" | sed 's/^/    /' >&2 || true
    fail "${perm} is NOT granted according to dumpsys package. \`pm grant\`" \
         "exits 0 even when it refuses, so a silent rejection here would" \
         "otherwise present as an unattributable baseline-publish timeout."
  fi
done

# ---------------------------------------------------------------------------
# Phase 3 — provider ON (verified) and a GPS fix, re-issued for the life of
# the lane.
#
# Unlike run-b3-real-gps.sh, `set-location-enabled true` is a GATE here, not
# best-effort: the entire lane is a toggle, so a device whose provider cannot
# be toggled cannot run it, and discovering that at the toggle rather than at
# the start would waste the whole drive.
#
# NOTE the argument order: `geo fix` takes LONGITUDE first, then LATITUDE.
# ---------------------------------------------------------------------------
echo "Phase 3/6 — enabling the location provider and seeding GPS..."
: > "${TOGGLE_LOG}"
set_provider true

echo "  injecting lon=${GEO_LON} lat=${GEO_LAT} (re-issued every ${GEO_REISSUE_SECS}s)"
adb -s "${DEVICE}" emu geo fix "${GEO_LON}" "${GEO_LAT}" \
  || fail "\`adb emu geo fix\` was rejected by the emulator console — no" \
          "position can be injected, so this lane cannot establish a" \
          "baseline and has nothing to take away."
(
  while sleep "${GEO_REISSUE_SECS}"; do
    adb -s "${DEVICE}" emu geo fix "${GEO_LON}" "${GEO_LAT}" >/dev/null 2>&1 \
      || true
  done
) &
GEO_PID=$!

# ---------------------------------------------------------------------------
# Phase 4 — drive the target IN THE BACKGROUND and toggle underneath it.
#
# The drive must be backgrounded because the toggles happen MID-session: the
# subject is one continuous session whose provider disappears under it, which
# a sequence of separate drives cannot express (each would start a fresh
# process with a fresh, empty position cache — and the stale-cache tail is
# precisely one of the behaviours being measured).
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
# the provider before reporting.
toggle_failed=0
toggle_reason=""

echo "Phase 4/6 — waiting for the drive to arm (${MARK_AWAIT_DISABLE})..."
if wait_for_marker "${MARK_AWAIT_DISABLE}" "${ARM_MARKER_TIMEOUT}"; then
  echo "Phase 4/6 — switching the location provider OFF..."
  set_provider false

  echo "Phase 4/6 — waiting for the disabled window to complete" \
       "(${MARK_AWAIT_REENABLE})..."
  if wait_for_marker "${MARK_AWAIT_REENABLE}" "${DISABLED_MARKER_TIMEOUT}"; then
    echo "Phase 4/6 — switching the location provider back ON..."
    set_provider true
  else
    toggle_failed=1
    toggle_reason="the drive never reached ${MARK_AWAIT_REENABLE}"
    # Restore anyway so the drive's recovery phase can still run and record
    # evidence, and so the emulator is not left disabled for later jobs.
    set_provider true
  fi
else
  toggle_failed=1
  toggle_reason="the drive never reached ${MARK_AWAIT_DISABLE}"
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
echo "Phase 6/6 — asserting the provider-toggle sequence..."
oracle_rc=0
b6_run_oracle "${LOGCAT_FILE}" || oracle_rc=$?

if (( oracle_rc != 0 )); then
  echo "---- provider toggle log ----" >&2
  cat "${TOGGLE_LOG}" >&2 2>/dev/null || true
  {
    echo "B6 findings (${#B6_FINDINGS[@]}):"
    for finding in "${B6_FINDINGS[@]}"; do
      echo "  * ${finding}"
    done
  } >&2
  fail "the location-provider toggle sequence did not hold — see the" \
       "${#B6_FINDINGS[@]} finding(s) above."
fi

if (( toggle_failed == 1 )); then
  fail "the oracle passed, but the harness toggle sequence did not:" \
       "${toggle_reason}. Treat the lane as RED — a sequence that skipped a" \
       "toggle cannot have measured what the oracle just blessed."
fi

if (( drive_failed == 1 )); then
  fail "the oracle passed, but ${drive_reason}. Treat the lane as RED —" \
       "a drive that dies early can truncate the very capture the oracle" \
       "measures."
fi

echo "B6 PASS — the app published with the OS location provider ON, stopped" \
     "and told the user when it was switched OFF, and recovered when it was" \
     "switched back ON."
