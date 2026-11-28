#!/usr/bin/env bash
#
# Android launch gate: a RELEASE APK opens, onboards as far as an offline
# device can, keeps what it saved across a cold restart, and upgrades cleanly
# from the last good release. Run inside .github/workflows/launch-gate-android.yml's
# emulator step, under run-with-deadline.sh and the host egress guard.
#
# v0.1.14 died at every process start (WorkDatabase_Impl.<init> stripped by R8)
# and nothing in CI had ever launched a release build. This launches one the
# way a user does — the launcher activity, cold, with the production main() —
# and reads the screen through UiAutomator, which sees Flutter's semantics in a
# release build (CI run 43588108447 tapped through onboarding that way).
#
# # Legs
#
#   fresh     install the candidate fresh, onboard, cold restart.
#   upgrade   install the previous release fresh, onboard it, install the
#             candidate over it (a replace: its data stays), cold launch.
#   baseline  the upgrade leg from a fixed older release (v0.1.13), which
#             onboards to the map offline, so the candidate opens MapShell in
#             release mode. Run when LAUNCH_GATE_BASELINE_DIR is set; the
#             workflow leaves it unset when the baseline IS the previous
#             release.
#
# # The photo rounds
#
# The release build's real Photo Picker and uCrop, driven through
# photo-picker-lib.sh over two fixtures seeded into the gallery:
#
#   onboarding  the fresh leg, on the create screen before "Create My
#               Identity": tap Add profile photo, pick, crop, and the screen
#               must say Change profile photo and Remove within APPLY_SECS.
#               Proves picker -> uCrop -> result on the shipped build (R8,
#               the androidx classes uCrop needs, edge-to-edge on API 35).
#   MapShell    the first leg that reaches MAP (the baseline leg today): grant
#               notifications, exempt the app from battery optimisation, turn
#               background sharing on through Settings > Location as a user
#               does, then Settings > Identity > Edit Photo. uCrop stops
#               MainActivity, MapShell takes its Android pause branch with
#               background sharing on, and the crop result arrives before the
#               app is resumed — root cause A of the 2026-11-16 photo bug. The
#               photo must show (View profile photo + Remove) within
#               APPLY_SECS, the error SnackBar never, and it must still show
#               after a cold restart (read back from SQLCipher).
#
# Between the picker and uCrop Haven is resumed (photo-picker-lib.sh,
# "between"); the error SnackBar seen then ends the round at once, and a
# Haven that stays in front ends it at the uCrop bound. A failed round's
# summary line carries `events=[...]`: the activities the activity manager
# created and finished during it, a crash's exception class and an ANR's
# owner, in fixed words (ui-dump.py trace).
# A run in which no leg reached MAP is rc 2: the hand-off path went untested.
#
# # Offline, and why that is the right network
#
# The guest is in airplane mode with no default network, and the host's egress
# guard rejects TCP 80/443 besides. A release build pins rustls to the bundled
# roots and production relays, so the only alternative to offline would be
# publishing to production from CI. Offline, current onboarding stops at
# "Couldn't finish setting up" (onboardingFinishSetupError, the reachability
# wait of OD-C) — the SETUP_HELD terminal — after creating the identity and
# saving the display name; a build from before OD-C goes on to the location
# disclosure and the map — the MAP terminal. A cold restart or an upgrade must
# then show the same terminal class, never the intro, and the very name the
# first launch saved: on the create screen at SETUP_HELD, on Settings > Identity
# at MAP. That name is SharedPreferences keyed by the public key of the identity
# the app loads from secure storage (the Android keystore), so the round trip
# proves the identity and the preferences survived. It does NOT prove SQLCipher:
# every value a user can see offline that SQLCipher holds has a fallback that
# hides a failed open (the circle list reads empty on any failure,
# circles_provider.dart:36-49; the Identity page's name falls back to the
# preferences copy, display_name_card.dart:200-229).
#
# # How the screen is read
#
# Every label is the APK's OWN app_en.arb value, resolved by ui-dump.py, which
# matches whole lines of a node's text or description. Keys a build's ARB does
# not have remove their state (a pre-OD-C ARB has no onboardingFinishSetupError);
# the welcome and create CTAs and commonSettings are required. A tap is judged
# by the screen digest (see the journey below): a label is tapped once per
# screen, never retried, and a tap after which the screen stays exactly as it
# was for the whole window is "did not progress", a product failure under the
# responsiveness pillar. Every verdict says whether its last observation is
# fresh or stale, counting the dumps since the last tap, BACK or launch.
#
# # Verdicts
#
# Crash evidence is read before anything is blamed: the crash buffer naming the
# process, the events buffer's am_crash/am_anr for the package, or the process
# gone or replaced while it should be running. The crash summary — exception
# lines, `at` frames, `#nn pc <offset> <library>` native frames, random install
# paths removed — is written only then.
#
#   0  every leg passed
#   1  product: the candidate crashed, stalled, lost data, showed the intro
#      after onboarding, kept a debug log plant, or did not replace the
#      previous release; a photo tap opened no picker or a known wrong one
#      (DocumentsUI, the GET_CONTENT alias, the Play services picker; API
#      33+), Haven showed its photo-failure SnackBar or stayed in front
#      instead of opening uCrop, Haven's own "isn't responding" dialog held
#      the picker's focus or held focus when a screen's window closed, uCrop
#      never returned, the photo save was refused or did not show within
#      APPLY_SECS, or was gone after a cold restart
#   2  usage or harness: a missing input; a picker screen the selectors do
#      not know (its resource ids are printed) or an activity the picker
#      rules do not know (its component is printed); background sharing would not
#      turn on while Android showed the battery/notification snack the
#      grants were meant to prevent; no leg reached MapShell; the gallery
#      fixtures could not be seeded although the device answered (a push or
#      query it refused, or a media store that never listed them)
#   3  infrastructure: the device went away, never booted, is not en-US,
#      would not go offline, kept a process the boot left in an error state
#      after CLOSE_SYSTEM_DIALOGS, refused an injected tap or BACK, failed at
#      adb itself every dump of a window after an action (the gate saw
#      nothing), gave no answer while the gallery was seeded, or
#      never attached its shared storage, or another process's "isn't
#      responding" or "keeps stopping" dialog held the picker's or uCrop's
#      focus, or held focus when one of Haven's screens' windows closed —
#      nothing about the app is known
#   4  the upgrade source is unusable: the previous release itself failed
#      before the candidate was installed (yank it in
#      scripts/ci/launch_gate_yanked_releases.txt)
#
# One `::error::` line names the leg, the state reached, the last observation
# (visible keys, foreground package, EditText count), the evidence since the
# last action (dumps read, unchanged, failed; the observation fresh or stale)
# and the class. The summary
# and any crash summary are written under LAUNCH_GATE_OUT and passed through the
# log-privacy gate BEFORE either is echoed; the workflow uploads nothing else.
# The display name the app generated is held in a 0700 directory, declared to
# the gate (`--host-decl display_name=…`) so the scanner proves it absent, and
# never printed. UI dumps live in that directory and are deleted per read.
#
# Every wait is bounded by a readonly constant below and polls a condition;
# nothing sleeps. scripts/ci/e2e_lane_budget.manifest prices each one.
#
# Usage:
#   run-launch-gate-android.sh <candidate-dir> <previous-dir>
#     each dir: install.apk, app_en.arb, version_code, tag
#     env: LAUNCH_GATE_BASELINE_DIR (optional, same layout), LAUNCH_GATE_OUT
#          (default /tmp/launch-gate/out)
#   run-launch-gate-android.sh --self-test     stub adb driven by scenarios

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR="${script_dir}"

# shellcheck source=tooling/e2e/ci/app-install-lib.sh
source "${SCRIPT_DIR}/app-install-lib.sh"
# shellcheck source=tooling/e2e/ci/logscan-gate.sh
source "${SCRIPT_DIR}/logscan-gate.sh"
# shellcheck source=tooling/e2e/ci/photo-picker-lib.sh
source "${SCRIPT_DIR}/photo-picker-lib.sh"

readonly PKG='com.oblivioustech.haven'
readonly ACTIVITY="${PKG}/.MainActivity"
readonly DEVICE='emulator-5554'
readonly UI_DUMP="${SCRIPT_DIR}/ui-dump.py"
# The rotated needle directory every scanning lane seals into; a constant, as
# rotate-needle-dir.sh's is.
readonly NEEDLE_DIR=/tmp/haven-soak/needles
readonly OUT_DIR="${LAUNCH_GATE_OUT:-/tmp/launch-gate/out}"
readonly SUMMARY="${OUT_DIR}/launch-gate-summary.log"
readonly CRASH_SUMMARY="${OUT_DIR}/crash-summary.log"
readonly LOGSCAN_REPORT="${OUT_DIR%/*}/launch-gate-logscan.ndjson"

# Bounds. The LAUNCH_GATE_* overrides exist for the self-test, whose stub device
# answers instantly; the workflow sets none of them. Every bound is read on the
# clock `date +%s` answers, never SECONDS: the self-test's stub `date` counts
# the stub device's calls, so no fixture's verdict depends on machine speed.
readonly BOOT_SECS="${LAUNCH_GATE_BOOT_SECS:-60}"        # adb and boot_completed after the action's boot
readonly OFFLINE_SECS="${LAUNCH_GATE_OFFLINE_SECS:-30}"  # airplane mode and no default network
readonly LAUNCH_SECS="${LAUNCH_GATE_LAUNCH_SECS:-60}"    # `am start -W` to a drawn activity
readonly SCREEN_SECS="${LAUNCH_GATE_SCREEN_SECS:-60}"    # from one screen to the next
# After "Create My Identity": identity creation, then the 60 s reachability
# wait (create_identity_screen.dart finishSetupTimeout) before the error shows.
readonly FINISH_SECS="${LAUNCH_GATE_FINISH_SECS:-120}"
readonly DUMP_SECS="${LAUNCH_GATE_DUMP_SECS:-15}"        # one uiautomator dump
readonly PROCESS_SECS="${LAUNCH_GATE_PROCESS_SECS:-20}"  # a pid after launch, none after force-stop
readonly ADB_SECS="${LAUNCH_GATE_ADB_SECS:-10}"          # one polled adb read
# A whole onboarding, each window opening at the last tap: the intro, the
# create screen, the finish wait, and two disclosures on the way to the map
# (v0.1.13 asks for background location, then foreground).
readonly JOURNEY_SECS=$(( 4 * SCREEN_SECS + FINISH_SECS ))
# A cold reopen: the first screen, then a window after each tap on the way to
# the Identity page — a disclosure declined, Settings, Identity.
readonly REOPEN_SECS=$(( 4 * SCREEN_SECS ))
# After a candidate's terminal screen: how long it must stay up, unattended.
readonly SETTLE_SECS="${LAUNCH_GATE_SETTLE_SECS:-30}"
# From MainActivity resumed after a crop to the photo on screen: the product's
# worst case, not its usual one. A crop that outlasts the 20 s excursion grace
# hands the session over; the save then waits up to kHandoffEndWait (10 s) for
# the resume to end the hand-off and the open up to handoverTimeout (15 + 5 s,
# haven/lib/src/services/mls_session_handover.dart), + 10 s of margin. A
# shorter bound would race a correct build's slow path; the no-stall promise
# inside the grace is the Flutter fake_async tests'. The self-test pins the sum.
readonly APPLY_SECS="${LAUNCH_GATE_APPLY_SECS:-40}"
# Settings > Location > the toggle > Agree > back to Settings, a window each.
readonly SETTINGS_SECS=$(( 5 * SCREEN_SECS ))
# Intro -> create screen settled, before the onboarding photo round.
readonly CREATE_SECS=$(( 2 * SCREEN_SECS ))
# Settings -> the Identity page settled, before the MapShell photo round.
readonly IDENTITY_SECS=$(( 2 * SCREEN_SECS ))

readonly KEY_WELCOME=onboardingWelcomeCta
readonly KEY_CREATE=onboardingCreateIdentityCta
readonly KEY_NOT_NOW=locationDisclosureNotNow
readonly KEY_SETUP_HELD=onboardingFinishSetupError
readonly KEY_MAP=commonSettings
readonly KEY_IDENTITY=settingsIdentityTitle
readonly KEY_IDENTITY_PAGE=identityTitle
# Optional: the Identity page's name card while it loads (its only plain-text
# "Display Name"; the loaded field carries it as a hint, which no dump shows).
readonly KEY_NAME_LOADING=displayNameCardTitle
# onboardingPhotoNotSaved: the create screen's report of a picked photo it
# could not save (a build without the key leaves it out).
readonly KEYS_FATAL='onboardingCreateIdentityError onboardingDisplayNameError onboardingPhotoNotSaved'
readonly ALL_KEYS="${KEY_WELCOME},${KEY_CREATE},${KEY_NOT_NOW},${KEY_SETUP_HELD},${KEY_MAP},${KEY_IDENTITY},${KEY_IDENTITY_PAGE},${KEY_NAME_LOADING},onboardingCreateIdentityError,onboardingDisplayNameError,onboardingPhotoNotSaved"
# The photo and background-sharing labels, read only on the candidate's
# screens (an older release's ARB may spell them otherwise). C7: the photo
# state is read from the app's own semantics labels.
readonly KEY_ADD_PHOTO=photoHeaderAddPhotoSemantics
readonly KEY_CHANGE_PHOTO=photoHeaderChangePhotoSemantics
readonly KEY_REMOVE_PHOTO=photoHeaderRemove
readonly KEY_VIEW_PHOTO=photoHeaderViewPhotoSemantics
readonly KEY_EDIT_PHOTO=photoHeaderEditPhoto
readonly KEY_PHOTO_ERROR=avatarPickerUpdateError
readonly KEY_LOCATION=settingsLocationTitle
readonly KEY_BG_OFF=settingsLocationSubtitleOff
readonly KEY_BG_ON=settingsLocationSubtitleOn
readonly KEY_BG_TOGGLE=locationSettingsToggleTitle
readonly KEY_AGREE=locationDisclosureAgree
readonly KEY_SNACK_BATTERY=locationSettingsBatteryOptSnack
readonly KEY_SNACK_NOTIFY=locationSettingsNotificationDeniedSnack
readonly PHOTO_KEYS="${KEY_ADD_PHOTO},${KEY_CHANGE_PHOTO},${KEY_REMOVE_PHOTO},${KEY_VIEW_PHOTO},${KEY_EDIT_PHOTO},${KEY_PHOTO_ERROR},${KEY_LOCATION},${KEY_BG_OFF},${KEY_BG_ON},${KEY_BG_TOGGLE},${KEY_AGREE}"
readonly PHOTO_OPTIONAL_KEYS="${KEY_SNACK_BATTERY},${KEY_SNACK_NOTIFY}"

# What the summary reports, set as the run goes.
LEG='preconditions'
STATE='-'
LEGS_DONE='none '
OBS_SUMMARY='no observation yet'
VERDICT_RC=''
VERDICT_MSG=''
UPGRADE_SOURCE=0
APP_PID=''
PRIV=''
API_LEVEL=0
# Which keys observe() asks for: ALL_KEYS, plus the photo keys on the
# candidate's photo and Settings screens.
OBS_KEYSET="${ALL_KEYS}"
PHOTO_SUMMARY='onboarding=- map=-'
PHOTO_AT_MAP_DONE=''

# Set by observe.
OBS_FG=''
OBS_EDITS=0
OBS_KEYS=''
OBS_DIGEST=''
declare -A OBS_XY=()

# The evidence since the last action (mark_action): what the device was asked
# to do, and how every dump since went — read, unchanged from the screen the
# action was made on, or failed, by ui-dump.py's fixed reason or adb's.
ACTION=''
ACTION_DIGEST=''
DUMPS_OK=0
DUMPS_SAME=0
DUMPS_FAILED=0
DUMPS_UNREACHED=0
declare -A DUMP_FAILS=()

say() { echo "[launch-gate] $*"; }

# verdict <rc> <message> — record the outcome and end the run; the EXIT trap
# classifies, writes, gates and reports. rc "" means "product unless the device
# is gone", decided once, in the trap.
verdict() {
  VERDICT_RC="$1"
  VERDICT_MSG="$2"
  exit 0
}

# ---------------------------------------------------------------------------
# Device reads.
# ---------------------------------------------------------------------------
dev() { adb -s "${DEVICE}" "$@"; }

# pid_now — the app's pid, or nothing when it is not running (pidof's rc 1);
# non-zero when adb gave no answer in time, which a caller polls past rather
# than reads as a death.
pid_now() {
  local out rc=0
  out="$(timeout "${ADB_SECS}" adb -s "${DEVICE}" shell pidof "${PKG}" 2>/dev/null)" || rc=$?
  (( rc == 0 || rc == 1 )) || return 1
  printf '%s' "${out//$'\r'/}"
}

# mark_action <words> [<digest>] — the device was asked for something the
# screen should answer (<digest>: the screen it was asked on); the evidence
# starts over from it.
mark_action() {
  ACTION="$1"; ACTION_DIGEST="${2:-}"
  DUMPS_OK=0; DUMPS_SAME=0; DUMPS_FAILED=0; DUMPS_UNREACHED=0; DUMP_FAILS=()
}

# evidence — the dumps since the last action, in fixed words; nothing before
# the first action.
evidence() {
  local why fails='' fresh='stale: no dump has succeeded since' same=''
  [[ -n "${ACTION}" ]] || return 0
  while IFS= read -r why; do
    [[ -z "${why}" ]] || fails+="${fails:+, }${DUMP_FAILS[${why}]} ${why}"
  done < <(printf '%s\n' "${!DUMP_FAILS[@]}" | sort)
  (( DUMPS_OK == 0 )) || fresh='fresh, taken after it'
  if [[ -n "${ACTION_DIGEST}" ]] && (( DUMPS_OK )); then
    if (( DUMPS_SAME == DUMPS_OK )); then same=', all unchanged'; else same=", ${DUMPS_SAME} unchanged"; fi
  fi
  printf 'since %s: %s dump(s) read%s, %s failed%s; the last observation is %s' \
    "${ACTION}" "${DUMPS_OK}" "${same}" "${DUMPS_FAILED}" "${fails:+ (${fails})}" "${fresh}"
}

# observe <arb> [<edit-value-file>] — one dump, read by ui-dump.py into OBS_*.
# A failed one leaves OBS_SUMMARY on the last dump that succeeded, which
# evidence then calls stale.
observe() {
  local arb="$1" edit_out="${2:-}" out rc=0 adb_rc=0 line w why
  local -a extra=(--digest-out "${PRIV}/digest")
  OBS_FG=''; OBS_EDITS=0; OBS_KEYS=''; OBS_XY=(); OBS_DIGEST=''
  rm -f "${PRIV}/digest"
  timeout "${DUMP_SECS}" adb -s "${DEVICE}" exec-out \
    "uiautomator dump /sdcard/haven-launch-gate.xml >/dev/null 2>&1 && cat /sdcard/haven-launch-gate.xml; rm -f /sdcard/haven-launch-gate.xml" \
    > "${PRIV}/dump.xml" 2>/dev/null || adb_rc=$?
  [[ -z "${edit_out}" ]] || extra+=(--edit-value-out "${edit_out}")
  out="$(python3 -I "${UI_DUMP}" observe --dump "${PRIV}/dump.xml" --package "${PKG}" \
    --arb "${arb}" --keys "${OBS_KEYSET}" "${extra[@]}")" || rc=$?
  rm -f "${PRIV}/dump.xml"
  if (( rc == 2 )); then
    verdict 2 "ui-dump.py refused its input (see stderr)"
  fi
  if (( rc != 0 )); then
    # A non-zero adb is the transport failing (exec-out carries no remote
    # status). An empty dump adb did bring back is uiautomator's, which a
    # Haven that stops answering accessibility queries causes too.
    case "${adb_rc}" in
      0) if [[ "${out}" =~ ^observation\ none\ ([A-Za-z ]+)$ ]]; then why="${BASH_REMATCH[1]}"; else why='ui-dump.py gave no reason'; fi ;;
      124) why="no dump within ${DUMP_SECS} s" ;;
      *) why='adb did not reach the device'; DUMPS_UNREACHED=$(( DUMPS_UNREACHED + 1 )) ;;
    esac
    DUMPS_FAILED=$(( DUMPS_FAILED + 1 ))
    DUMP_FAILS["${why}"]=$(( ${DUMP_FAILS[${why}]:-0} + 1 ))
    return 1
  fi
  OBS_DIGEST="$(cat "${PRIV}/digest")"
  rm -f "${PRIV}/digest"
  DUMPS_OK=$(( DUMPS_OK + 1 ))
  [[ -z "${ACTION_DIGEST}" || "${OBS_DIGEST}" != "${ACTION_DIGEST}" ]] || DUMPS_SAME=$(( DUMPS_SAME + 1 ))
  while IFS= read -r line; do
    read -r -a w <<<"${line}"
    case "${w[0]:-}" in
      foreground) OBS_FG="${w[1]}" ;;
      edittexts) OBS_EDITS="${w[1]}" ;;
      visible) OBS_KEYS+="${OBS_KEYS:+ }${w[1]}"; OBS_XY["${w[1]}"]="${w[2]} ${w[3]}" ;;
    esac
  done <<<"${out}"
  OBS_SUMMARY="visible [${OBS_KEYS:-none}], foreground ${OBS_FG}, edittexts ${OBS_EDITS}"
}

seen() { [[ " ${OBS_KEYS} " == *" $1 "* ]]; }

# inject <words> <input-args>... — one input on the screen last observed. An
# input the device refused never reached Haven, so it says nothing about it.
inject() {
  local words="$1" rc=0
  shift
  dev shell input "$@" >/dev/null 2>&1 || rc=$?
  if (( rc != 0 )); then
    verdict 3 "the device refused ${words} (adb rc ${rc}): the input never reached Haven, which says nothing about it; re-run"
  fi
  mark_action "${words}, accepted by the device" "${OBS_DIGEST}"
}

tap() { # tap <key> — at the centre ui-dump.py reported for it
  local x y
  read -r x y <<<"${OBS_XY[$1]}"
  inject "the tap on $1" tap "${x}" "${y}"
  say "${LEG}: tapped ${1} (accepted by the device)"
}

# unseen — before a window's verdict: every dump since the last action failed
# at adb itself, so the window saw nothing of Haven to judge.
unseen() {
  (( DUMPS_OK == 0 && DUMPS_FAILED > 0 && DUMPS_UNREACHED == DUMPS_FAILED )) || return 0
  verdict 3 "adb reached no dump in the window after ${ACTION}: all ${DUMPS_FAILED} failed at adb itself, so nothing about Haven is known; re-run"
}

# alive — the process launched for this leg is still the one running.
alive() {
  local now
  now="$(pid_now)" || return 0
  if [[ -z "${now}" ]]; then
    verdict '' "the app process died at state ${STATE}"
  fi
  if [[ "${now}" != "${APP_PID}" ]]; then
    verdict '' "the app process was replaced at state ${STATE} (a crash and restart)"
  fi
}

clear_logs() { dev logcat -b all -c >/dev/null 2>&1 || true; }

launch_app() {
  local out rc=0 start spent
  STATE='launch'
  out="$(timeout "${LAUNCH_SECS}" adb -s "${DEVICE}" shell am start -W -n "${ACTIVITY}" 2>&1 | tr -d '\r')" || rc=$?
  if ! grep -qx 'Status: ok' <<<"${out}"; then
    verdict '' "am start -W did not report 'Status: ok' within ${LAUNCH_SECS} s (rc ${rc})"
  fi
  start="$(date +%s)"
  while spent=$(( $(date +%s) - start )); (( spent < PROCESS_SECS )); do
    if APP_PID="$(pid_now)"; then
      if [[ -z "${APP_PID}" ]]; then
        verdict 1 "am start -W reported ok but no ${PKG} process is running"
      fi
      mark_action 'the launch'
      say "${LEG}: launched cold"
      return 0
    fi
  done
  verdict '' "adb gave no process list within ${PROCESS_SECS} s of the launch"
}

stop_app() {
  local start spent now
  dev shell am force-stop "${PKG}" >/dev/null 2>&1 || true
  start="$(date +%s)"
  while spent=$(( $(date +%s) - start )); (( spent < PROCESS_SECS )); do
    if now="$(pid_now)" && [[ -z "${now}" ]]; then
      APP_PID=''
      return 0
    fi
  done
  verdict '' "${PKG} was still running ${PROCESS_SECS} s after force-stop"
}

installed_version_code() {
  dev shell "dumpsys package ${PKG} | grep -m1 versionCode=" 2>/dev/null \
    | tr -d '\r' | sed -nE 's/.*versionCode=([0-9]+).*/\1/p'
}

# check_no_crash — the leg-end proof that nothing died behind the screen.
check_no_crash() {
  if crash_evidence; then
    verdict '' "crash evidence for ${PKG} at the end of the leg"
  fi
}

check_no_plant() {
  local n
  n="$(dev shell 'logcat -d | grep -c logscan-plant-' 2>/dev/null | tr -d '\r' || true)"
  if [[ ! "${n}" =~ ^[0-9]+$ ]]; then
    verdict '' "could not count debug log plants in logcat"
  fi
  if (( n > 0 )); then
    verdict 1 "a debug-only log plant (logscan-plant-*) reached logcat: this is not a release build's logging"
  fi
}

# crash_evidence — 0 when the device holds evidence that the app crashed or
# stopped responding. Read into memory only; never written raw.
CRASH_TEXT=''
crash_evidence() {
  local crash events
  crash="$(timeout "${ADB_SECS}" adb -s "${DEVICE}" logcat -d -b crash 2>/dev/null | tr -d '\r' || true)"
  events="$(timeout "${ADB_SECS}" adb -s "${DEVICE}" logcat -d -b events 2>/dev/null | tr -d '\r' || true)"
  CRASH_TEXT=''
  if grep -qE "Process: ${PKG//./\\.}(,|$)|>>> ${PKG//./\\.} <<<" <<<"${crash}"; then
    CRASH_TEXT="${crash}"
    return 0
  fi
  if grep -qE "am_(crash|anr)[^[]*\[[^]]*[[,]${PKG//./\\.}[],]" <<<"${events}"; then
    CRASH_TEXT="$(grep -E "am_(crash|anr)" <<<"${events}")"
    return 0
  fi
  return 1
}

# crash_summary — stdin a crash text, stdout the lines that say what died:
# threadtime prefixes stripped, native frames reduced to number, offset and
# library, random install paths and R8's 64-hex map id removed (the log-privacy
# gate rightly withholds a line carrying one, and with it the explanation).
crash_summary() {
  echo "crash evidence for ${PKG}:"
  awk '
    / am_(crash|anr) *: / { sub(/^.* am_/, "am_"); sub(/ *: /, ": "); print; next }
    { sub(/^[0-9][0-9]-[0-9][0-9] [0-9:.]+ +[0-9]+ +[0-9]+ [A-Z] [^:]*: /, "") }
    /#[0-9]+ pc [0-9a-f]+/ {
      match($0, /#[0-9]+ pc [0-9a-f]+/); f = substr($0, RSTART, RLENGTH)
      lib = $0; sub(/^.*#[0-9]+ pc [0-9a-f]+ +/, "", lib); sub(/ .*$/, "", lib); sub(/^.*\//, "", lib)
      print f " " lib; next
    }
    { gsub(/\/data\/app\/[^ ]*/, "<app>"); gsub(/r8-map-id-[0-9a-f]+/, "r8") }
    /FATAL EXCEPTION|Caused by:|^[[:space:]]*at |Exception|Error:|Fatal signal|Abort message/ { print }
  ' | head -n 80
}

# ---------------------------------------------------------------------------
# The journey: one launch from wherever the app opens to a terminal state.
#
# A tap is judged by the screen, not by its label. Each observation carries the
# screen digest (ui-dump.py: a sha256 of our window's text, kept in memory and
# never printed). A tap records the digest it was made on; ANY change to it is
# the tap taking effect, and the tap "did not progress" only when the digest
# stayed exactly that for the whole window after it. A label seen again on a
# different screen is a new screen: v0.1.13 declines the background disclosure
# and then shows the foreground one, another dialog with the same "Not now".
# A label is never tapped twice on one screen, and only on a screen two dumps
# in a row agree on, so a route still animating in is never tapped mid-way.
# ---------------------------------------------------------------------------
TERMINAL=''
TAP_KEY=''
TAP_DIGEST=''
PREV_DIGEST=''
STALL=0
NAME_UNREAD=0
declare -A TAPPED=()

# window_open <secs> — a fresh launch's tap state, and its first window.
window_open() {
  TAP_KEY=''; TAP_DIGEST=''; PREV_DIGEST=''; NAME_UNREAD=0; TAPPED=()
  STALL=$(( $(date +%s) + $1 ))
}

# act <name-file> <key>... — after an observation of our window: wait out a
# pending tap, or tap the first key on screen that this screen has not had.
act() {
  local name_file="$1" key settled=0
  shift
  if [[ "${OBS_DIGEST}" == "${PREV_DIGEST}" ]]; then settled=1; fi
  PREV_DIGEST="${OBS_DIGEST}"
  if [[ -n "${TAP_KEY}" ]]; then
    [[ "${OBS_DIGEST}" != "${TAP_DIGEST}" ]] || return 0
    TAP_KEY=''
  fi
  for key in "$@"; do
    seen "${key}" || continue
    [[ -z "${TAPPED[${key}|${OBS_DIGEST}]:-}" ]] || continue
    (( settled )) || return 0
    if [[ "${key}" == "${KEY_CREATE}" ]]; then
      if (( OBS_EDITS != 1 )) || [[ ! -s "${name_file}.read" ]]; then
        NAME_UNREAD=1
        continue
      fi
      mv "${name_file}.read" "${name_file}"
      STALL=$(( $(date +%s) + FINISH_SECS ))
    else
      STALL=$(( $(date +%s) + SCREEN_SECS ))
    fi
    tap "${key}"
    TAP_KEY="${key}"
    TAP_DIGEST="${OBS_DIGEST}"
    TAPPED["${key}|${OBS_DIGEST}"]=1
    STATE="after ${key}"
    return 0
  done
}

# stalled <foreign-package> — the verdict when a window closes without progress.
# <foreign-package> is only the last good dump's root, and the system's error
# dialogs are rooted in package `android` whoever stopped responding, so input
# focus decides whose window it is: Haven's own error dialog is Haven failing,
# another process's is the device's, and Haven's own activity holding focus
# means the foreign root was not what stayed in front.
stalled() {
  unseen
  if [[ -n "$1" || -n "${TAP_KEY}" ]]; then
    pp_focused "${DEVICE}" "${PRIV}"
    case "${PP_FOCUSED}" in
      window:not-responding-ours|window:app-error-ours)
        verdict 1 "input focus was $(_pp_focus_words "${PP_FOCUSED}") at state ${STATE} when its window closed: Haven failed" ;;
      window:not-responding-*|window:app-error-*)
        verdict 3 "input focus was $(_pp_focus_words "${PP_FOCUSED}") at state ${STATE} when its window closed: the device is struggling, which says nothing about Haven; re-run" ;;
    esac
  fi
  if [[ -n "$1" && "${PP_FOCUSED}" != "${PKG}/"* ]]; then
    verdict 1 "$1 held the foreground at state ${STATE} until the deadline (input focus $(_pp_focus_words "${PP_FOCUSED}"))"
  fi
  # The focus is named so a tap that never reached Haven's window can be told
  # from a Haven that did not answer it (CI run 44870800362, API 34).
  if [[ -n "${TAP_KEY}" ]] && (( DUMPS_OK )); then
    verdict 1 "did not progress: the screen did not change in the window after ${TAP_KEY} was tapped (input focus $(_pp_focus_words "${PP_FOCUSED}"))"
  fi
  # adb answered and uiautomator brought back nothing usable: a Haven whose
  # main thread stopped answering accessibility queries can look exactly so.
  if [[ -n "${TAP_KEY}" ]]; then
    verdict 1 "did not progress: no dump of the screen succeeded in the window after ${TAP_KEY} was tapped, though adb answered (input focus $(_pp_focus_words "${PP_FOCUSED}"))"
  fi
  if (( NAME_UNREAD )); then
    verdict 1 "the create screen never showed exactly one non-empty name field, so the name it saves could not be checked"
  fi
}

# journey <arb> <name-file> — sets TERMINAL to SETUP_HELD or MAP.
journey() {
  local arb="$1" name_file="$2" start spent now key foreign=''
  start="$(date +%s)"
  window_open "${SCREEN_SECS}"
  STATE='first screen'
  while spent=$(( $(date +%s) - start )); (( spent < JOURNEY_SECS )); do
    alive
    now="$(date +%s)"
    if (( now >= STALL )); then
      break
    fi
    observe "${arb}" "${name_file}.read" || continue
    if [[ "${OBS_FG}" != "${PKG}" ]]; then
      foreign="${OBS_FG}"
      continue
    fi
    foreign=''
    for key in ${KEYS_FATAL}; do
      if seen "${key}"; then verdict 1 "the app showed ${key} at state ${STATE}"; fi
    done
    if seen "${KEY_SETUP_HELD}"; then TERMINAL=SETUP_HELD; STATE="${TERMINAL}"; return 0; fi
    if seen "${KEY_MAP}"; then TERMINAL=MAP; STATE="${TERMINAL}"; return 0; fi
    act "${name_file}" "${KEY_NOT_NOW}" "${KEY_CREATE}" "${KEY_WELCOME}"
  done
  stalled "${foreign}"
  verdict 1 "no progress past state ${STATE} within its deadline"
}

# expect_reopened <arb> <name-file> — a cold launch after onboarding shows the
# same terminal class, never the intro, and the display name the source
# onboarded with: SETUP_HELD's create screen shows it, and a MAP launch is
# driven to Settings > Identity, whose name field must show it. That page is
# its title (identityTitle, the same "Identity" the Settings entry reads) with
# one EditText; Settings has none (settings_page.dart). On it nothing is ever
# tapped — its title would match the Settings entry — and the field, which
# seeds asynchronously, is read until it shows the name. The map's
# Settings button alone proves only SharedPreferences' onboarding flag; the
# name is read under the identity the app loads from secure storage (it is
# keyed by that identity's public key, nostr_identity_service.dart:444-449),
# so an update that loses the identity cannot pass. A map the location
# disclosure covers (a user who declined it is asked again, modally) is
# declined the way the journey declines it.
expect_reopened() {
  local arb="$1" name_file="$2" start spent now key name_seen=0
  STATE="reopen (${TERMINAL})"
  start="$(date +%s)"
  window_open "${SCREEN_SECS}"
  while spent=$(( $(date +%s) - start )); (( spent < REOPEN_SECS )); do
    alive
    now="$(date +%s)"
    if (( now >= STALL )); then
      break
    fi
    observe "${arb}" "${name_file}.after" || continue
    [[ "${OBS_FG}" == "${PKG}" ]] || continue
    for key in ${KEYS_FATAL}; do
      if seen "${key}"; then verdict 1 "the app showed ${key} after a cold launch"; fi
    done
    if seen "${KEY_WELCOME}"; then
      verdict 1 "a cold launch after onboarding showed the intro again (onboarding state was lost)"
    fi
    if [[ "${TERMINAL}" == MAP ]] \
       && { seen "${KEY_NAME_LOADING}" || { seen "${KEY_IDENTITY_PAGE}" && (( OBS_EDITS == 1 )); }; }; then
      # The Identity page is up: the tap that opened it took effect.
      TAP_KEY=''
      if (( OBS_EDITS == 1 )); then
        name_seen=1
        if cmp -s "${name_file}" "${name_file}.after"; then
          rm -f "${name_file}.after"
          return 0
        fi
      fi
      continue
    fi
    if [[ "${TERMINAL}" == SETUP_HELD ]] && seen "${KEY_CREATE}" && (( OBS_EDITS == 1 )); then
      name_seen=1
      if cmp -s "${name_file}" "${name_file}.after"; then
        rm -f "${name_file}.after"
        return 0
      fi
    fi
    if [[ "${TERMINAL}" == MAP ]]; then
      act "${name_file}" "${KEY_NOT_NOW}" "${KEY_IDENTITY}" "${KEY_MAP}"
    fi
  done
  rm -f "${name_file}.after"
  stalled ''
  if (( name_seen )); then
    verdict 1 "a cold launch did not show the display name the first launch saved"
  fi
  verdict 1 "a cold launch did not reopen at ${TERMINAL} and show the saved display name"
}

# settle_watch <arb> — the screen a candidate reached stays up, unattended,
# for SETTLE_SECS, its process the same one throughout; the caller's
# check_no_crash then reads the crash and events buffers, so a crash or an ANR
# moments after MapShell's or the setup screen's first frame is still caught.
settle_watch() {
  local arb="$1" start spent
  STATE="${STATE}, settling"
  start="$(date +%s)"
  while spent=$(( $(date +%s) - start )); (( spent < SETTLE_SECS )); do
    alive
    observe "${arb}" || true
  done
}

# ---------------------------------------------------------------------------
# The photo rounds (see the header). photo-picker-lib.sh drives the system
# screens; these read Haven's own, by the labels its ARB gives them.
# ---------------------------------------------------------------------------
PHOTO_ONBOARDING='-'
PHOTO_MAP='-'

PHOTO_ARB=''

# The library's hook, called every tick of a round: the process launched for
# this leg must still be the one running (alive ends the run otherwise).
pp_hook_alive() { alive; }

# The library's hook while uCrop is awaited and MainActivity is in front:
# Haven showing its photo-failure SnackBar is the pick or the crop editor
# failing, decided now; anything else waits on. The SnackBar stays up 4 s
# (Flutter's default), longer than one read.
pp_hook_home() {
  observe "${PHOTO_ARB}" || return 0
  [[ "${OBS_FG}" == "${PKG}" ]] || return 0
  seen "${KEY_PHOTO_ERROR}" || return 0
  PP_MSG="Haven showed its photo-failure message (${KEY_PHOTO_ERROR}) instead of the crop editor: the pick, the copy of the picked photo or the crop editor failed"
  return 1
}

photo_summary() {
  PHOTO_SUMMARY="onboarding=${PHOTO_ONBOARDING} map=${PHOTO_MAP} picker=${PP_PICKER} ucrop=${PP_UCROP} events=[${PP_TRACE}]"
}

# photo_round <arb> <onboarding|identity> — from a settled screen of ours on
# which the tap target was just observed, to the photo shown, or a verdict.
photo_round() {
  local arb="$1" surface="$2" target shown index rc=0 start spent key
  if [[ "${surface}" == onboarding ]]; then
    target="${KEY_ADD_PHOTO}"; shown="${KEY_CHANGE_PHOTO}"; index=0
  else
    target="${KEY_EDIT_PHOTO}"; shown="${KEY_VIEW_PHOTO}"; index=1
  fi
  STATE="photo round (${surface})"
  PHOTO_ARB="${arb}"
  tap "${target}"
  pp_round "${DEVICE}" "${PRIV}" pick "${index}" "${API_LEVEL}" || rc=$?
  photo_summary
  case "${rc}" in
    0) ;;
    2) verdict 2 "photo round (${surface}): ${PP_MSG}" ;;
    3) verdict 3 "photo round (${surface}): ${PP_MSG}" ;;
    *) verdict 1 "photo round (${surface}): ${PP_MSG}" ;;
  esac
  STATE="photo round (${surface}), back from uCrop"
  mark_action 'the return from uCrop'
  start="$(date +%s)"
  while spent=$(( $(date +%s) - start )); (( spent < APPLY_SECS )); do
    alive
    observe "${arb}" || continue
    [[ "${OBS_FG}" == "${PKG}" ]] || continue
    if seen "${KEY_PHOTO_ERROR}"; then
      verdict 1 "the photo save was refused after the crop (${KEY_PHOTO_ERROR}): root cause A's class, the result arriving before the app is resumed while MapShell has handed the MLS session off"
    fi
    for key in ${KEYS_FATAL}; do
      if seen "${key}"; then verdict 1 "the app showed ${key} after the crop"; fi
    done
    if seen "${shown}" && seen "${KEY_REMOVE_PHOTO}"; then
      if [[ "${surface}" == onboarding ]]; then PHOTO_ONBOARDING=ok; else PHOTO_MAP=ok; fi
      photo_summary
      say "${LEG}: photo round (${surface}) applied (picker ${PP_PICKER}, uCrop ${PP_UCROP})"
      return 0
    fi
  done
  unseen
  verdict 1 "photo round (${surface}): the photo did not show within ${APPLY_SECS} s of Haven's return from uCrop"
}

# onboarding_photo <arb> — from a fresh launch to the create screen, settled,
# then the onboarding photo round; the journey takes it from there.
onboarding_photo() {
  local arb="$1" start spent now key foreign=''
  OBS_KEYSET="${ALL_KEYS},${PHOTO_KEYS}"
  start="$(date +%s)"
  window_open "${SCREEN_SECS}"
  STATE='first screen (before the onboarding photo)'
  while spent=$(( $(date +%s) - start )); (( spent < CREATE_SECS )); do
    alive
    now="$(date +%s)"
    if (( now >= STALL )); then
      break
    fi
    observe "${arb}" || continue
    if [[ "${OBS_FG}" != "${PKG}" ]]; then
      foreign="${OBS_FG}"
      continue
    fi
    foreign=''
    for key in ${KEYS_FATAL}; do
      if seen "${key}"; then verdict 1 "the app showed ${key} at state ${STATE}"; fi
    done
    if seen "${KEY_CREATE}" && seen "${KEY_ADD_PHOTO}"; then
      TAP_KEY=''
      if [[ "${OBS_DIGEST}" == "${PREV_DIGEST}" ]]; then
        photo_round "${arb}" onboarding
        OBS_KEYSET="${ALL_KEYS}"
        return 0
      fi
      PREV_DIGEST="${OBS_DIGEST}"
      continue
    fi
    act "${PRIV}/name.unused" "${KEY_WELCOME}"
  done
  stalled "${foreign}"
  verdict 1 "the create screen did not settle with ${KEY_ADD_PHOTO} on it, so the onboarding photo round could not start"
}

# grant_read_back <permission> — pm grant exits 0 even when it refuses, so the
# package dump decides.
grant_read_back() {
  local n
  dev shell pm grant "${PKG}" "$1" >/dev/null 2>&1 || true
  n="$(dev shell "dumpsys package ${PKG} | grep -c '$1: granted=true'" 2>/dev/null | tr -d '\r' || true)"
  [[ "${n}" =~ ^[1-9][0-9]*$ ]] || verdict 3 "pm grant ${1##*.} did not read back as granted"
}

# enable_background_sharing <arb> — Settings > Location > the toggle > Agree >
# back, as a user turns it on; done when Settings says it is on.
enable_background_sharing() {
  local arb="$1" start spent now agreed=0 snack=0 back_digest=''
  local -a keys
  OBS_KEYSET="${ALL_KEYS},${PHOTO_KEYS},${PHOTO_OPTIONAL_KEYS}"
  STATE='enabling background sharing (Settings)'
  start="$(date +%s)"
  window_open "${SCREEN_SECS}"
  while spent=$(( $(date +%s) - start )); (( spent < SETTINGS_SECS )); do
    alive
    now="$(date +%s)"
    if (( now >= STALL )); then
      break
    fi
    observe "${arb}" || continue
    [[ "${OBS_FG}" == "${PKG}" ]] || continue
    if seen "${KEY_SNACK_BATTERY}" || seen "${KEY_SNACK_NOTIFY}"; then snack=1; fi
    if seen "${KEY_LOCATION}" && seen "${KEY_BG_ON}"; then
      say "${LEG}: background sharing is on (Settings says so)"
      return 0
    fi
    # The Location page again after Agree: back to Settings, once per screen.
    if (( agreed )) && seen "${KEY_BG_TOGGLE}" && ! seen "${KEY_AGREE}" \
       && [[ "${OBS_DIGEST}" == "${PREV_DIGEST}" && "${OBS_DIGEST}" != "${back_digest}" ]]; then
      inject 'the back key' keyevent 4
      say "${LEG}: pressed back (accepted by the device)"
      back_digest="${OBS_DIGEST}"
      TAP_KEY=BACK
      TAP_DIGEST="${OBS_DIGEST}"
      STALL=$(( $(date +%s) + SCREEN_SECS ))
      continue
    fi
    keys=("${KEY_AGREE}")
    (( agreed )) || keys+=("${KEY_BG_TOGGLE}")
    if seen "${KEY_BG_OFF}"; then keys+=("${KEY_LOCATION}"); fi
    act "${PRIV}/name.unused" "${keys[@]}"
    if [[ "${TAP_KEY}" == "${KEY_AGREE}" ]]; then agreed=1; fi
  done
  if (( snack )); then
    verdict 2 "harness precondition: background sharing did not turn on, and Android showed the battery or notification snack the grants and the battery exemption were there to prevent"
  fi
  stalled ''
  verdict 1 "background sharing did not turn on through Settings > Location with notifications granted and the battery exemption read back"
}

# identity_page <arb> <purpose> — from Settings to the Identity page, settled.
identity_page() {
  local arb="$1" purpose="$2" start spent now
  STATE="to Settings > Identity (${purpose})"
  start="$(date +%s)"
  window_open "${SCREEN_SECS}"
  while spent=$(( $(date +%s) - start )); (( spent < IDENTITY_SECS )); do
    alive
    now="$(date +%s)"
    if (( now >= STALL )); then
      break
    fi
    observe "${arb}" || continue
    [[ "${OBS_FG}" == "${PKG}" ]] || continue
    if seen "${KEY_EDIT_PHOTO}"; then
      TAP_KEY=''
      if [[ "${OBS_DIGEST}" == "${PREV_DIGEST}" ]]; then return 0; fi
      PREV_DIGEST="${OBS_DIGEST}"
      continue
    fi
    if seen "${KEY_LOCATION}"; then act "${PRIV}/name.unused" "${KEY_IDENTITY}"; fi
  done
  stalled ''
  verdict 1 "the Identity page did not settle with ${KEY_EDIT_PHOTO} on it (${purpose})"
}

# expect_photo_kept <arb> — after a cold restart reopened the Identity page:
# the photo saved before it is still shown.
expect_photo_kept() {
  local arb="$1" start spent
  OBS_KEYSET="${ALL_KEYS},${PHOTO_KEYS}"
  STATE='photo after a cold restart'
  start="$(date +%s)"
  while spent=$(( $(date +%s) - start )); (( spent < SCREEN_SECS )); do
    alive
    observe "${arb}" || continue
    [[ "${OBS_FG}" == "${PKG}" ]] || continue
    if seen "${KEY_VIEW_PHOTO}" && seen "${KEY_REMOVE_PHOTO}"; then
      OBS_KEYSET="${ALL_KEYS}"
      return 0
    fi
  done
  verdict 1 "the photo saved at MapShell was gone after a cold restart"
}

# photo_at_map <arb> <name-file> — the MapShell photo round on the Identity
# page expect_reopened left open, with background sharing turned on first.
photo_at_map() {
  local arb="$1" name_file="$2"
  STATE='background sharing preconditions'
  grant_read_back android.permission.POST_NOTIFICATIONS
  grant_read_back android.permission.ACCESS_FINE_LOCATION
  grant_read_back android.permission.ACCESS_COARSE_LOCATION
  # "Allow all the time" held, so the enable shows no all-time step and opens
  # no OS permission page over Haven, which the loop would wait out (OD-R2).
  grant_read_back android.permission.ACCESS_BACKGROUND_LOCATION
  # No battery dialog on the enable path (background_location_manager.dart
  # asks only while the app is not exempt).
  dev shell dumpsys deviceidle whitelist "+${PKG}" >/dev/null 2>&1 || true
  [[ "$(dev shell "dumpsys deviceidle whitelist | grep -c ',${PKG},'" 2>/dev/null | tr -d '\r' || true)" =~ ^[1-9][0-9]*$ ]] \
    || verdict 3 "the battery-optimisation exemption did not read back"
  inject 'the back key' keyevent 4
  enable_background_sharing "${arb}"
  identity_page "${arb}" 'before the photo'
  photo_round "${arb}" identity
  OBS_KEYSET="${ALL_KEYS}"
  say "${LEG}: restarting cold to check the photo was kept"
  stop_app
  launch_app
  expect_reopened "${arb}" "${name_file}"
  expect_photo_kept "${arb}"
  PHOTO_AT_MAP_DONE=1
}

# ---------------------------------------------------------------------------
# Legs.
# ---------------------------------------------------------------------------
leg_fresh() {
  local cand="$1"
  LEG='fresh'
  STATE='install'
  if ! install_fresh "${DEVICE}" "${cand}/install.apk"; then
    verdict '' "the candidate did not install fresh"
  fi
  dev shell pm grant "${PKG}" android.permission.POST_NOTIFICATIONS >/dev/null 2>&1 || true
  clear_logs
  launch_app
  onboarding_photo "${cand}/app_en.arb"
  journey "${cand}/app_en.arb" "${PRIV}/name.fresh"
  settle_watch "${cand}/app_en.arb"
  check_no_crash
  say "fresh: onboarded to ${TERMINAL}; restarting cold"
  local before="${APP_PID}"
  stop_app
  launch_app
  if [[ "${APP_PID}" == "${before}" ]]; then
    verdict 1 "the restart reused the old process"
  fi
  expect_reopened "${cand}/app_en.arb" "${PRIV}/name.fresh"
  settle_watch "${cand}/app_en.arb"
  check_no_crash
  check_no_plant
  LEGS_DONE="fresh=${TERMINAL} "
  say "fresh: passed (${TERMINAL} kept across a cold restart)"
}

# leg_upgrade <label> <source-dir> <candidate-dir>
leg_upgrade() {
  local label="$1" src="$2" cand="$3" vc name="${PRIV}/name.$1"
  LEG="${label} (from $(cat "${src}/tag"))"
  UPGRADE_SOURCE=1
  STATE='install'
  if ! install_fresh "${DEVICE}" "${src}/install.apk"; then
    verdict '' "the previous release did not install fresh"
  fi
  dev shell pm grant "${PKG}" android.permission.POST_NOTIFICATIONS >/dev/null 2>&1 || true
  dev shell pm grant "${PKG}" android.permission.ACCESS_FINE_LOCATION >/dev/null 2>&1 || true
  dev shell pm grant "${PKG}" android.permission.ACCESS_COARSE_LOCATION >/dev/null 2>&1 || true
  clear_logs
  launch_app
  journey "${src}/app_en.arb" "${name}"
  check_no_crash
  vc="$(installed_version_code)"
  if [[ "${vc}" != "$(cat "${src}/version_code")" ]]; then
    verdict '' "the device reports versionCode '${vc}' for the previous release, not $(cat "${src}/version_code")"
  fi
  say "${LEG}: the previous release onboarded to ${TERMINAL}; installing the candidate over it"
  stop_app
  UPGRADE_SOURCE=0
  STATE='upgrade install'
  # Before the install, so a crash during or right after it stays in evidence.
  clear_logs
  if ! install_app "${DEVICE}" "${cand}/install.apk"; then
    verdict 1 "the candidate did not install over the previous release"
  fi
  vc="$(installed_version_code)"
  if [[ "${vc}" != "$(cat "${cand}/version_code")" ]]; then
    verdict 1 "after the upgrade the device reports versionCode '${vc}', not the candidate's $(cat "${cand}/version_code")"
  fi
  launch_app
  expect_reopened "${cand}/app_en.arb" "${name}"
  if [[ "${TERMINAL}" == MAP && -z "${PHOTO_AT_MAP_DONE}" ]]; then
    photo_at_map "${cand}/app_en.arb" "${name}"
  fi
  settle_watch "${cand}/app_en.arb"
  check_no_crash
  check_no_plant
  LEGS_DONE+="${label}=${TERMINAL} "
  say "${LEG}: passed (${TERMINAL} kept across the upgrade)"
}

# ---------------------------------------------------------------------------
# Preconditions: a booted en-US device, offline, with error dialogs hidden and
# no process the boot left in an error state.
# ---------------------------------------------------------------------------

preconditions() {
  local start spent boot locale air='' net='' close=0 closes=0
  if ! timeout "${BOOT_SECS}" adb -s "${DEVICE}" wait-for-device; then
    verdict 3 "${DEVICE} did not come online within ${BOOT_SECS} s"
  fi
  start="$(date +%s)"
  while spent=$(( $(date +%s) - start )); (( spent < BOOT_SECS )); do
    boot="$(timeout "${ADB_SECS}" adb -s "${DEVICE}" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)"
    [[ "${boot}" == 1 ]] && break
  done
  [[ "${boot:-}" == 1 ]] || verdict 3 "sys.boot_completed never read 1 within ${BOOT_SECS} s"
  locale="$(dev shell getprop persist.sys.locale 2>/dev/null | tr -d '\r' || true)"
  [[ -n "${locale}" ]] || locale="$(dev shell getprop ro.product.locale 2>/dev/null | tr -d '\r' || true)"
  if [[ "${locale}" != en-US ]]; then
    verdict 3 "the device locale is '${locale}', not en-US: the gate reads the English ARB's labels"
  fi
  dev shell settings put global hide_error_dialogs 1 >/dev/null 2>&1 || true
  if [[ "$(dev shell settings get global hide_error_dialogs 2>/dev/null | tr -d '\r')" != 1 ]]; then
    verdict 3 "hide_error_dialogs did not read back 1"
  fi
  dev shell cmd connectivity airplane-mode enable >/dev/null 2>&1 || true
  # "Active default network: none" is ConnectivityService.dump()'s line when
  # no network is the default (AOSP android-14); read from source, so a guest
  # that prints anything else is refused here, by name, rather than trusted.
  #
  # hide_error_dialogs stops only the error dialogs shown after it: AOSP asks
  # it when a dialog would be shown (AppErrors.handleShowAnrUi). One the boot
  # raised first (the emulator action's keyevent 82 timing out on a launcher or
  # System UI still starting) stays over every screen the legs read, and the
  # first leg stalls under it (CI runs 44698826899 and 44870800362, API 35).
  # CLOSE_SYSTEM_DIALOGS ends it as the setting would have: an "isn't
  # responding" dialog's closeDialog force-closes its app
  # (AppNotRespondingDialog overrides BaseErrorDialog's dismiss with
  # FORCE_CLOSE, killAppAtUsersRequest). Input focus cannot say no such dialog
  # is coming: release run 44922735173 (API 35) read focus free of one, and
  # System UI's held it from the first leg's launch on. The activity manager
  # marks the process before the dialog is even decided, and until it is
  # dismissed, so readiness waits for no process so marked. `am broadcast`
  # waits for the ordered broadcast to finish, which a hung receiver stretches
  # to 60 s, so it is bounded, and sent in a pass of its own: no pass outlasts
  # the reads the budget books past the window.
  start="$(date +%s)"
  while spent=$(( $(date +%s) - start )); (( spent < OFFLINE_SECS )); do
    if (( close )); then
      close=0
      closes=$(( closes + 1 ))
      timeout "${ADB_SECS}" adb -s "${DEVICE}" shell am broadcast -a android.intent.action.CLOSE_SYSTEM_DIALOGS >/dev/null 2>&1 || true
      continue
    fi
    air="$(timeout "${ADB_SECS}" adb -s "${DEVICE}" shell settings get global airplane_mode_on 2>/dev/null | tr -d '\r' || true)"
    net="$(timeout "${ADB_SECS}" adb -s "${DEVICE}" shell "dumpsys connectivity | grep -m1 'Active default network:'" 2>/dev/null | tr -d '\r' || true)"
    # The read photo-picker-lib.sh's pp_settle_errors waits on, inside this
    # window because the offline reads share it.
    pp_error_state "${DEVICE}" "${PRIV}"
    case "${PP_ERROR_STATE}" in
      none) ;;
      '') continue ;;
      *) close=1; continue ;;
    esac
    if [[ "${air}" == 1 && "${net}" =~ Active\ default\ network:\ none$ ]]; then
      say "device ready: booted, en-US, airplane mode on, no default network, no process in an error state"
      gallery
      return 0
    fi
  done
  if [[ "${air}" == 1 && "${net}" =~ Active\ default\ network:\ none$ ]]; then
    verdict 3 "no read of the activity manager's processes within ${OFFLINE_SECS} s showed none in an error state (last read: $(pp_error_words "${PP_ERROR_STATE}")), after ${closes} CLOSE_SYSTEM_DIALOGS broadcast(s)"
  fi
  verdict 3 "the device did not go offline within ${OFFLINE_SECS} s (airplane_mode_on='${air:-}', '${net:-no default-network line}')"
}

# gallery — the API level the picker rules depend on, and the two photos the
# rounds pick, indexed. adb rides the emulator console, not the guest network,
# so offline is no obstacle.
gallery() {
  API_LEVEL="$(dev shell getprop ro.build.version.sdk 2>/dev/null | tr -d '\r' || true)"
  [[ "${API_LEVEL}" =~ ^[0-9]+$ ]] || verdict 3 "ro.build.version.sdk did not read as a number"
  local rc=0
  pp_seed_gallery "${DEVICE}" "${PRIV}" || rc=$?
  (( rc == 0 )) || verdict "${rc}" "gallery (API ${API_LEVEL}): ${PP_MSG}"
  say "gallery seeded (API ${API_LEVEL})"
}

# ---------------------------------------------------------------------------
# The EXIT trap: classify, write, gate, then — only then — echo.
# ---------------------------------------------------------------------------
finish() {
  local rc=$? cls gate_rc=0 cause='' ev
  local -a decls=()
  local f
  if [[ -z "${VERDICT_MSG}" ]]; then
    VERDICT_RC=''
    VERDICT_MSG="the runner stopped unexpectedly (rc ${rc}) at state ${STATE}"
  fi
  rm -f "${CRASH_SUMMARY}"
  if [[ "${VERDICT_RC}" != 0 && "${VERDICT_RC}" != 2 ]] && crash_evidence; then
    crash_summary <<<"${CRASH_TEXT}" > "${CRASH_SUMMARY}"
    VERDICT_MSG="the app crashed (${VERDICT_MSG})"
    VERDICT_RC=1
  elif [[ -z "${VERDICT_RC}" ]]; then
    if [[ "$(timeout "${ADB_SECS}" adb -s "${DEVICE}" get-state 2>/dev/null | tr -d '\r')" == device ]]; then
      VERDICT_RC=1
    else
      VERDICT_RC=3
      VERDICT_MSG="${DEVICE} went offline (${VERDICT_MSG})"
    fi
  fi
  if (( VERDICT_RC == 1 && UPGRADE_SOURCE == 1 )); then
    VERDICT_RC=4
  fi
  case "${VERDICT_RC}" in
    0) cls='pass' ;; 1) cls='product' ;; 2) cls='usage' ;; 3) cls='infrastructure' ;;
    4) cls='upgrade source unusable — yank it in scripts/ci/launch_gate_yanked_releases.txt' ;;
  esac
  ev="$(evidence)"
  {
    echo "launch-gate-android verdict: ${cls} (rc ${VERDICT_RC})"
    echo "leg: ${LEG}; state: ${STATE}; last observation: ${OBS_SUMMARY}"
    [[ -z "${ev}" ]] || echo "evidence: ${ev}"
    echo "reason: ${VERDICT_MSG}"
    echo "legs passed: ${LEGS_DONE% }"
    echo "photo: ${PHOTO_SUMMARY}"
  } > "${SUMMARY}"
  if [[ -n "${PRIV}" ]]; then
    for f in "${PRIV}"/name.*; do
      [[ -s "${f}" ]] && decls+=(--host-decl "display_name=$(cat "${f}")")
    done
  fi
  local -a sinks=(--sink "diag=${SUMMARY}")
  [[ ! -f "${CRASH_SUMMARY}" ]] || sinks+=(--sink "diag=${CRASH_SUMMARY}")
  logscan_gate host "${NEEDLE_DIR}" ${decls[@]+"${decls[@]}"} -- "${sinks[@]}" \
    --report "${LOGSCAN_REPORT}" || gate_rc=$?
  [[ -z "${PRIV}" ]] || rm -rf "${PRIV}"
  if (( gate_rc != 0 )); then
    echo "::error::launch-gate-android: the log-privacy gate refused the summary (rc ${gate_rc}); it is not shown. Verdict class: ${cls}."
    exit $(( VERDICT_RC == 0 ? 1 : VERDICT_RC ))
  fi
  cat "${SUMMARY}"
  if [[ -f "${CRASH_SUMMARY}" ]]; then
    echo "--- crash summary ---"
    cat "${CRASH_SUMMARY}"
    cause="$(grep -E 'Caused by:|Exception|Fatal signal' "${CRASH_SUMMARY}" | tail -n 1 || true)"
  fi
  if (( VERDICT_RC != 0 )); then
    echo "::error::launch-gate-android ${cls}: leg ${LEG}, state ${STATE}; ${VERDICT_MSG}${cause:+; ${cause}}; last observation: ${OBS_SUMMARY}${ev:+; ${ev}}"
  fi
  exit "${VERDICT_RC}"
}

# ---------------------------------------------------------------------------
# Self-test. A stub `adb` plays a device: the install, the barrier, airplane
# mode, `am start -W`, pidof, `input tap`, the crash and events buffers, and a
# small model of Haven's onboarding whose screens it renders as uiautomator
# XML, so the real ui-dump.py reads them. Each APK is a text file naming the
# flow it plays and its versionCode. Scenarios are environment knobs on the
# stub. Logs go through the real logscan-gate.sh and scan-logs.sh with the
# shared fake scanner. Time is the stub's too: a stub `date` answers `+%s`
# with a clock each adb call advances by STUB_TICK (default 1), so every
# deadline is a count of device calls and every verdict comes from what the
# stub shows, never from how fast this machine runs it.
# ---------------------------------------------------------------------------
readonly SELF_TEST_FIXTURES=149
readonly ST_NAME='Quiet Wanderer Fixture'
# What a picker thumbnail's description says in the stub: a date, which no
# transcript or summary may carry.
readonly ST_PICKER_DESC='aken on Nov 1'

_st_write_stub() { # <dir>
  cat > "$1/adb" <<'STUB'
#!/usr/bin/env bash
# The launch gate's stub device. State lives in files under ${STUB}.
S="${STUB}"
printf '%s\n' "$*" >> "${S}/calls"
echo $(( $(cat "${S}/clock") + ${STUB_TICK:-1} )) > "${S}/clock"
[[ "${1:-}" == -s ]] && shift 2
if [[ -f "${S}/offline" ]]; then echo "error: device offline" >&2; exit 1; fi
PKG=com.oblivioustech.haven
# STUB_BOOT_DIALOG=<title>: an error dialog the boot raised before the gate set
# hide_error_dialogs, in front of every screen and holding input focus until
# CLOSE_SYSTEM_DIALOGS (never, with STUB_BOOT_DIALOG_STUCK). The activity
# manager holds its process in an error state (boot_anr) from the start;
# STUB_BOOT_DIALOG_SHOWN_AT=<clock>: the window itself is up only from that
# device call on, and the broadcast closes nothing before.
if [[ -n "${STUB_BOOT_DIALOG:-}" && ! -f "${S}/boot_dialog_raised" ]]; then touch "${S}/boot_anr" "${S}/boot_dialog_raised"; fi
if [[ -f "${S}/boot_anr" && ! -f "${S}/boot_dialog" ]] && (( $(cat "${S}/clock") >= ${STUB_BOOT_DIALOG_SHOWN_AT:-0} )); then touch "${S}/boot_dialog"; fi
get() { cat "${S}/$1" 2>/dev/null || true; }
# Every change of screen is a new window: its focus starts over (focus_of).
put() { printf '%s\n' "$2" > "${S}/$1"; [[ "$1" != screen ]] || printf '%s\n' "$(( $(get gen) + 1 ))" > "${S}/gen"; }
flow() { sed -n 's/^flow //p' "$(get installed)"; }
tt() { echo "11-14 12:00:00.000  4242  4242 E AndroidRuntime: $*"; }
node() { # <class> <text> <desc> <bounds> [pkg]
  printf '<node index="0" text="%s" resource-id="" class="%s" package="%s" content-desc="%s" clickable="true" enabled="true" bounds="%s"/>' \
    "$2" "$1" "${5:-${PKG}}" "$3" "$4"
}
pnode() { # <pkg> <resource-id> <desc> <bounds>
  printf '<node index="0" text="" resource-id="%s" class="android.widget.ImageView" package="%s" content-desc="%s" clickable="true" enabled="true" bounds="%s"/>' "$2" "$1" "$3" "$4"
}
picker_pkg() {
  case "${STUB_PICKER_COMPONENT:-photopicker}" in
    documentsui) echo com.google.android.documentsui ;;
    *) echo com.google.android.providers.media.module ;;
  esac
}
picker_rid() {
  [[ -z "${STUB_PICKER_UNKNOWN:-}" ]] || { echo "$(picker_pkg):id/unknown_grid_item"; return; }
  case "${STUB_PICKER_COMPONENT:-photopicker}" in
    documentsui) echo com.google.android.documentsui:id/icon_thumb ;;
    *) echo com.google.android.providers.media.module:id/icon_thumbnail ;;
  esac
}
# The activity a screen is.
component_of() {
  local c="${PKG}/${PKG}.MainActivity"
  case "$1" in
    picker) case "${STUB_PICKER_COMPONENT:-photopicker}" in
        documentsui) c='com.google.android.documentsui/com.android.documentsui.picker.PickActivity' ;;
        getcontent) c='com.google.android.providers.media.module/com.android.providers.media.photopicker.PhotoPickerGetContentActivity' ;;
        unknown) c='com.android.photopicker/com.android.photopicker.MainActivity' ;;
        *) c='com.google.android.providers.media.module/com.android.providers.media.photopicker.PhotoPickerActivity' ;;
      esac ;;
    ucrop) c="${PKG}/com.yalantis.ucrop.UCropActivity" ;;
  esac
  printf '%s' "${c}"
}
resumed_line() { printf '  topResumedActivity=ActivityRecord{2b2a1e5 u0 %s t42}\n' "$(component_of "$(get screen)")"; }
# Input focus as the device has it: a system picker or uCrop is resumed before
# its window can hold focus, so the first STUB_FOCUS_LAG `dumpsys input` reads
# of each new one see no focused window (STUB_NEVER_FOCUSED=<screen>: none
# ever does). Haven's own screens are focused at once.
focus_of() { # <advance: 1 on a dumpsys read>
  local scr reads; scr="$(get screen)"
  case "${scr}" in picker|ucrop) ;; *) component_of "${scr}"; return ;; esac
  [[ "$(get fgen)" == "$(get gen)" ]] || { put fgen "$(get gen)"; put freads 0; }
  reads="$(get freads)"
  if (( $1 )); then reads=$(( reads + 1 )); put freads "${reads}"; fi
  if [[ "${STUB_NEVER_FOCUSED:-}" == "${scr}" ]] || (( reads <= ${STUB_FOCUS_LAG:-1} )); then echo none; return; fi
  component_of "${scr}"
}
# STUB_FOCUS_WINDOW=<title>: a window that is no activity's (an error dialog)
# holds the focus the picker or uCrop does not. STUB_FOREIGN_FOCUS=<name>: the
# focused window's name while STUB_FOREIGN roots the dump (unset: Haven's own
# activity keeps the focus, the foreign root notwithstanding).
focus_dump() {
  local f; f="$(focus_of 1)"
  echo 'Input Dispatcher State:'
  if [[ -f "${S}/boot_dialog" ]]; then
    printf "  FocusedWindows:\n    displayId=0, name='5a1 %s'\n" "${STUB_BOOT_DIALOG}"
  elif [[ -n "${STUB_FOREIGN:-}" && -n "${STUB_FOREIGN_FOCUS:-}" && "$(get screen)" == "${STUB_FOREIGN_ON:-create}" ]]; then
    printf "  FocusedWindows:\n    displayId=0, name='5a1 %s'\n" "${STUB_FOREIGN_FOCUS}"
  elif [[ "${f}" == none && -n "${STUB_FOCUS_WINDOW:-}" ]]; then printf "  FocusedWindows:\n    displayId=0, name='5a1 %s'\n" "${STUB_FOCUS_WINDOW}"
  elif [[ "${f}" == none ]]; then echo '  FocusedWindows: <none>'
  else printf "  FocusedWindows:\n    displayId=0, name='4f2e1c0 %s'\n" "${f}"; fi
}
# The activity manager's events, as `logcat -b events -v epoch` prints them
# (wm_create_activity carries the intent's URI, which no summary may show).
ev() { # <create|finish> <screen>
  if [[ "$1" == create ]]; then
    printf '%s.250   500   600 I wm_create_activity: [0,77,42,%s,NULL,NULL,content://media/picker/0/x/media/1000000018,0]\n' "${STUB_NOW:-1000}" "$(component_of "$2")"
  else
    printf '%s.500   500   600 I wm_finish_activity: [0,77,42,%s,app-request]\n' "${STUB_NOW:-1000}" "$(component_of "$2")"
  fi >> "${S}/events.log"
}
# An input to a system screen whose window does not hold focus: dropped, as
# the dispatcher drops a key no window took in time, and recorded so the
# self-test fails on it.
unfocused() {
  case "$(get screen)" in picker|ucrop) ;; *) return 1 ;; esac
  [[ "$(focus_of 0)" == none ]] || return 1
  printf '%s\n' "$1" >> "${S}/unfocused"
}
body_of() {
  local scr="$1" body=''
  case "${scr}" in
    blank) body="$(node android.view.View '' '' '[0,0][1080,2400]')" ;;
    intro) body="$(node android.widget.Button 'Get Started' '' '[40,2200][1040,2300]')" ;;
    create) body="$(node "${STUB_EDIT_CLASS:-android.widget.EditText}" "$(get shown_name)" '' '[40,900][1040,1000]')$(node android.widget.Button 'Create My Identity' '' '[40,2200][1040,2300]')"
      [[ -z "$(get not_saved)" ]] || body+="$(node android.view.View 'Your photo couldn’t be saved. You can add it later in Settings, under Identity.' '' '[40,2000][1040,2100]')"
      if [[ -n "$(get onb_photo)" ]]; then
        body+="$(node android.widget.Button '' 'Change profile photo' '[440,400][640,600]')$(node android.widget.Button 'Remove' '' '[440,650][640,720]')"
      else
        body+="$(node android.widget.Button '' 'Add profile photo' '[440,400][640,600]')"
      fi
      [[ -z "$(get refused)" ]] || body+="$(node android.view.View 'Could not update your photo. Please try again.' '' '[40,2100][1040,2300]')" ;;
    finishing) body="$(node android.widget.EditText "$(get shown_name)" '' '[40,900][1040,1000]')$(node android.view.View '' 'Finishing setup…' '[40,2200][1040,2300]')" ;;
    held) body="$(node android.widget.EditText "$(get shown_name)" '' '[40,900][1040,1000]')$(node android.view.View 'Couldn&apos;t finish setting up your account. Check your connection and try again.' '' '[40,1100][1040,1200]')$(node android.widget.Button 'Retry' '' '[40,2200][1040,2300]')" ;;
    name_error) body="$(node android.view.View 'Couldn’t save that name. Please try again.' '' '[40,2000][1040,2100]')" ;;
    # v0.1.13's two disclosures: one button label, two dialogs. The map's
    # is modal, so the map under it is not in the tree.
    bg_disclosure) body="$(node android.view.View 'Share your location in the background?' '' '[40,900][1040,1000]')$(node android.widget.Button 'Not now' '' '[40,2000][500,2100]')" ;;
    fg_disclosure) body="$(node android.view.View 'Share your location while you use Haven?' '' '[40,900][1040,1000]')$(node android.widget.Button 'Not now' '' '[40,2000][500,2100]')" ;;
    map) body="$(node android.widget.Button '' 'Settings' '[900,100][1000,200]')" ;;
    settings) body="$(node android.view.View 'Settings' '' '[40,100][600,200]')$(node android.widget.Button 'Identity' '' '[40,300][1040,400]')$(node android.widget.Button 'Relays' '' '[40,450][1040,550]')"
      if [[ -f "${S}/data/bg" ]]; then body+="$(node android.widget.Button 'Location&#10;Background sharing on' '' '[40,600][1040,700]')"
      else body+="$(node android.widget.Button 'Location&#10;Only while Haven is open' '' '[40,600][1040,700]')"; fi ;;
    location) body="$(node android.view.View 'Location' '' '[40,100][600,200]')$(node android.widget.Switch 'Share in background&#10;Keeps sharing while Haven is closed' '' '[40,300][1040,450]')"
      [[ -z "$(get snack)" ]] || body+="$(node android.view.View 'On. Battery optimization may pause sharing on some phones. Exclude Haven from battery optimization to keep it reliable.' '' '[40,2100][1040,2300]')" ;;
    disclosure) body="$(node android.view.View 'Share your location in the background?' '' '[40,900][1040,1000]')$(node android.widget.Button 'Agree' '' '[540,2000][1040,2100]')$(node android.widget.Button 'Not now' '' '[40,2000][500,2100]')" ;;
    picker) local d1='Photo taken on Nov 16, 2026 12:01' d2='Photo taken on Nov 15, 2026 09:30'
      [[ -z "${STUB_PICKER_UNKNOWN:-}" ]] || { d1='Taken on Nov 16, 2026 12:01'; d2='Taken on Nov 15, 2026 09:30'; }
      body="$(pnode "$(picker_pkg)" "$(picker_rid)" "${d1}" '[40,600][340,900]')$(pnode "$(picker_pkg)" "$(picker_rid)" "${d2}" '[400,600][700,900]')" ;;
    ucrop) if [[ -n "${STUB_UCROP_NO_RID:-}" ]]; then body="$(pnode "${PKG}" '' 'Crop' '[900,100][1040,240]')"
      else body="$(pnode "${PKG}" "${PKG}:id/menu_crop" 'Crop' '[900,100][1040,240]')"; fi ;;
    # The Identity page as the real tree has it: the app-bar title "Identity"
    # (the Settings entry's words too) and, once loaded, ONE EditText whose
    # "Display Name" label is a hint no dump shows. While the card loads
    # (STUB_IDENTITY_LOADING dumps, default 1) it shows "Display Name" as plain
    # text and no field. The field holds the saved name, read under the
    # identity — empty when STUB_IDENTITY_LOST.
    identity) body="$(node android.view.View 'Identity' '' '[40,100][600,200]')"
      if (( $(get identity_dumps) > ${STUB_IDENTITY_LOADING:-1} )); then
        body+="$(node android.widget.EditText "$([[ -n "${STUB_IDENTITY_LOST:-}" ]] || cat "${S}/data/name")" '' '[40,900][1040,1000]')"
      else
        body+="$(node android.view.View 'Display Name' '' '[40,800][1040,850]')"
      fi
      # The photo header: the avatar's label says whether a photo is set, the
      # badge is always "Change", Remove only with a photo. After a crop the
      # photo shows once STUB_APPLY_DUMPS dumps have passed.
      if [[ -n "$(get applying)" ]]; then
        put applying $(( $(get applying) - 1 ))
        if (( $(get applying) <= 0 )); then rm -f "${S}/applying"; touch "${S}/data/photo"; fi
      fi
      if [[ -f "${S}/data/photo" ]]; then
        body+="$(node android.widget.Button '' 'View profile photo' '[440,250][640,450]')$(node android.widget.Button 'Remove' '' '[600,500][800,560]')"
      else
        body+="$(node android.widget.Button '' 'Add profile photo' '[440,250][640,450]')"
      fi
      body+="$(node android.widget.Button '' 'Change profile photo' '[600,400][650,450]')$(node android.widget.Button 'Edit Photo' '' '[280,500][560,560]')"
      [[ -z "$(get refused)" ]] || body+="$(node android.view.View 'Could not update your photo. Please try again.' '' '[40,2100][1040,2300]')" ;;
  esac
  printf '%s' "${body}"
}
screen_xml() { # <screen> [<outgoing screen still in the tree>]
  local scr="$1" body
  body="${2:+$(body_of "$2")}$(body_of "${scr}")"
  printf "<?xml version='1.0' encoding='UTF-8' standalone='yes' ?><hierarchy rotation=\"0\">"
  if [[ -n "${STUB_FOREIGN:-}" && "${scr}" == "${STUB_FOREIGN_ON:-create}" ]]; then
    node android.widget.FrameLayout '' '' '[0,0][1080,2400]' "${STUB_FOREIGN}"
  elif [[ "${scr}" == picker ]]; then
    printf '<node index="0" text="" resource-id="" class="android.widget.FrameLayout" package="%s" content-desc="" bounds="[0,0][1080,2400]">%s</node>' "$(picker_pkg)" "${body}"
  else
    printf '<node index="0" text="" resource-id="" class="android.widget.FrameLayout" package="%s" content-desc="" bounds="[0,0][1080,2400]">%s</node>' "${PKG}" "${body}"
  fi
  printf '</hierarchy>'
}
launch() {
  local f; f="$(flow)"
  put dumps 0
  if [[ "${f}" == crash-at-start ]]; then
    { tt "FATAL EXCEPTION: main"; tt "Process: ${PKG}, PID: 4242"
      tt "java.lang.RuntimeException: Unable to get provider androidx.startup.InitializationProvider: androidx.startup.StartupException"
      tt "	at android.app.ActivityThread.installProvider(ActivityThread.java:7660)"
      tt "	at dz2.a(r8-map-id-$(printf '2%.0s' {1..64}):535)"
      tt "Caused by: java.lang.NoSuchMethodException: androidx.work.impl.WorkDatabase_Impl.<init> []"
      echo "11-14 12:00:00.000  4242  4242 F DEBUG   :       #00 pc 000000000005e8b4  /data/app/~~Zq1x==/${PKG}-Ab2==/lib/x86_64/librust_lib_haven.so (BuildId: 1a2b)"
    } >> "${S}/crash.log"
    rm -f "${S}/pid"
  else
    put pid $(( $(get pidseq) + 1 )); put pidseq "$(get pid)"
    rm -f "${S}/leaving" "${S}/onb_photo" "${S}/refused" "${S}/applying" "${S}/bounce"
    [[ -z "${STUB_PHOTO_LOST:-}" ]] || rm -f "${S}/data/photo"
    # Declining the foreground disclosure is asked again on every launch;
    # one agreed to is not.
    if [[ -f "${S}/data/agreed" ]]; then put screen map
    elif [[ -f "${S}/data/completed" ]]; then put screen fg_disclosure
    elif [[ -f "${S}/data/intro_seen" && -z "${STUB_FORGET_INTRO:-}" ]]; then
      put screen create; put shown_name 'Fresh Random Name'; put restore_pending 1
    else put screen intro; fi
    [[ -z "${STUB_ANR:-}" ]] || echo "11-14 12:00:01.000   500   600 I am_anr  : [0,4242,${PKG},952745540,Input dispatching timed out]" >> "${S}/events.log"
  fi
  printf 'Starting: Intent { cmp=%s/.MainActivity }\nStatus: ok\nLaunchState: COLD\nActivity: %s/.MainActivity\nTotalTime: 812\nWaitTime: 815\nComplete\n' "${PKG}" "${PKG}"
}
dump() {
  local n scr
  n=$(( $(get dumps) + 1 )); put dumps "${n}"
  [[ -n "$(get pid)" ]] || return 0
  # STUB_DUMP_EMPTY_AFTER_TAP: uiautomator brings back nothing once a tap was
  # sent, though adb answers — what a Haven no longer answering accessibility
  # queries gives.
  [[ -z "${STUB_DUMP_EMPTY_AFTER_TAP:-}" || ! -f "${S}/tapped" ]] || return 0
  if [[ -f "${S}/boot_dialog" ]]; then
    printf "<?xml version='1.0' encoding='UTF-8' standalone='yes' ?><hierarchy rotation=\"0\">%s</hierarchy>" \
      "$(node android.widget.FrameLayout '' '' '[0,0][1080,2400]' android)"
    return 0
  fi
  if (( n == 3 )) && [[ -n "${STUB_PID_FLIP:-}" ]]; then put pid 9999; fi
  scr="$(get screen)"
  if (( n == 1 )); then screen_xml blank; return 0; fi
  # A route still on its way out: one dump of the old screen alone, then one
  # with both, then the new one.
  if [[ -n "$(get leaving)" ]]; then
    put leaving_dumps $(( $(get leaving_dumps) + 1 ))
    if (( $(get leaving_dumps) == 1 )); then screen_xml "$(get leaving)"; return 0; fi
    screen_xml "${scr}" "$(get leaving)"; rm -f "${S}/leaving"; return 0
  fi
  if [[ "${scr}" == create && -n "$(get restore_pending)" && -z "${STUB_NAME_LOST:-}" ]] && (( n >= 3 )); then
    put shown_name "$(cat "${S}/data/name")"; rm -f "${S}/restore_pending"
  fi
  if [[ "${scr}" == finishing ]]; then
    put fin $(( $(get fin) + 1 )); (( $(get fin) < 3 )) || put screen held
  fi
  [[ "${scr}" != identity ]] || put identity_dumps $(( $(get identity_dumps) + 1 ))
  screen_xml "${scr}"
  # A crash moments after the setup screen's first frame: the dump that shows
  # it is the process's last. Keyed to that dump, never to the reads after it,
  # because how many reads a 1 s settle window holds is the host's speed.
  if [[ -n "${STUB_LATE_CRASH:-}" && "${scr}" == held ]]; then
    tt "FATAL EXCEPTION: main" >> "${S}/crash.log"; tt "Process: ${PKG}, PID: 4242" >> "${S}/crash.log"
    tt "java.lang.IllegalStateException: late" >> "${S}/crash.log"
    rm -f "${S}/pid"
  fi
}
# A crop's result: saved (after STUB_APPLY_DUMPS dumps on the Identity page)
# or refused; back on the screen the trip started from.
crop_done() {
  local from; from="$(get trip_from)"
  if [[ "${from}" == create ]]; then put onb_photo 1; [[ -z "${STUB_ONB_NOT_SAVED:-}" ]] || put not_saved 1
  elif [[ -n "${STUB_PHOTO_REFUSED:-}" ]]; then put refused 1
  else put applying "${STUB_APPLY_DUMPS:-1}"; fi
  put screen "${from}"
}
tap() {
  local x="$1" y="$2" scr; scr="$(get screen)"
  [[ ! -f "${S}/boot_dialog" ]] || return 0
  ! unfocused "tap ${x} ${y}" || return 0
  case "${scr}" in picker|ucrop|location|disclosure) ;; *)
    [[ -z "${STUB_TRANSITION:-}" ]] || { put leaving "${scr}"; put leaving_dumps 0; } ;;
  esac
  case "${scr}" in
    intro) (( y >= 2200 && y <= 2300 )) || return 0
      [[ -n "${STUB_CTA_STUCK:-}" ]] && return 0
      touch "${S}/data/intro_seen"; put shown_name "${STUB_NAME}"; put screen create ;;
    create)
      if (( y >= 400 && y <= 600 )) && [[ -z "$(get onb_photo)" ]]; then
        rm -f "${S}/leaving"
        [[ -n "${STUB_PICKER_NEVER:-}" ]] || { put trip_from create; put screen picker; ev create picker; }
        return 0
      fi
      (( y >= 2200 && y <= 2300 )) || return 0
      get shown_name > "${S}/data/name"
      case "$(flow)" in
        setup-held) put fin 0; put screen finishing ;;
        map) put screen bg_disclosure ;;
        name-error) put screen name_error ;;
      esac ;;
    bg_disclosure) (( x <= 500 && y >= 2000 && y <= 2100 )) || return 0
      touch "${S}/data/completed"; put screen fg_disclosure ;;
    fg_disclosure) (( x <= 500 && y >= 2000 && y <= 2100 )) || return 0
      put screen map ;;
    map) (( x >= 900 && x <= 1000 && y >= 100 && y <= 200 )) || return 0
      put screen settings ;;
    settings)
      if (( y >= 600 && y <= 700 )); then rm -f "${S}/leaving"; put screen location; return 0; fi
      (( y >= 300 && y <= 400 )) || return 0
      put identity_dumps 0; put screen identity ;;
    identity) (( y >= 500 && y <= 560 && x >= 280 && x <= 560 )) || return 0
      rm -f "${S}/leaving"
      [[ -n "${STUB_PICKER_NEVER:-}" ]] || { put trip_from identity; put screen picker; ev create picker; } ;;
    location) (( y >= 300 && y <= 450 )) || return 0
      put screen disclosure ;;
    disclosure) (( x >= 540 && y >= 2000 && y <= 2100 )) || return 0
      touch "${S}/data/agreed"
      if [[ -n "${STUB_BG_SNACK:-}" ]]; then put snack 1
      elif [[ -z "${STUB_BG_STUCK:-}" ]]; then touch "${S}/data/bg"; fi
      put screen location ;;
    picker) (( y >= 600 && y <= 900 )) || return 0
      if [[ -n "${STUB_UCROP_CRASH:-}" ]]; then
        { tt "FATAL EXCEPTION: main"; tt "Process: ${PKG}, PID: 4242"
          tt "java.lang.NoClassDefFoundError: Failed resolution of: Landroidx/appcompat/app/AppCompatActivity;"
          tt "	at com.yalantis.ucrop.UCropActivity.onCreate(UCropActivity.java:120)"; } >> "${S}/crash.log"
        rm -f "${S}/pid"; put screen blank; return 0
      fi
      # The picker finishes on the tap, and Haven is resumed until it starts
      # uCrop: the first STUB_PICK_BOUNCE activity reads find MainActivity.
      # STUB_PICK_SILENT: it never does (a pick that came back empty).
      # STUB_UCROP_ERROR: uCrop opens and closes itself between two reads and
      # Haven shows its photo-failure SnackBar.
      ev finish picker; put screen "$(get trip_from)"
      if [[ -n "${STUB_UCROP_ERROR:-}" ]]; then ev create ucrop; ev finish ucrop; put refused 1; return 0; fi
      [[ -n "${STUB_PICK_SILENT:-}" ]] || put bounce "${STUB_PICK_BOUNCE:-1}" ;;
    ucrop) (( x >= 900 && y >= 100 && y <= 240 )) || return 0
      [[ -n "${STUB_UCROP_NEVER:-}" ]] || { ev finish ucrop; crop_done; } ;;
  esac
}
keyevent() {
  ! unfocused BACK || return 0
  case "$(get screen)" in
    picker) put screen "$(get trip_from)" ;;
    identity|location) put screen settings ;;
  esac
}
# The shared storage and its media store, in AOSP's order: sys.boot_completed
# reads 1 before the system user unlocks, and the storage is mounted, then
# attached by MediaProvider, only on that unlock. Until then a push finds no
# /sdcard and the query is refused (Volume external_primary not found).
# STUB_STORAGE_LATE=<n> is that window, the first n queries — the API-35 run
# reached the gallery inside it — and STUB_STORAGE_NEVER keeps it open. A
# pushed file's row stays pending, which the query hides, for
# STUB_PENDING_READS queries: its FUSE release not yet handled.
storage_up() {
  local n; n="$(get media_reads)"
  [[ -z "${STUB_STORAGE_NEVER:-}" ]] && (( ${n:-0} >= ${STUB_STORAGE_LATE:-0} ))
}
media_push() { # <local> <remote>
  if ! storage_up; then echo "adb: error: failed to copy: remote secure_mkdirs() failed: No such file or directory" >&2; exit 1; fi
  if [[ -n "${STUB_PUSH_REFUSED:-}" ]]; then echo "adb: error: failed to copy: remote Permission denied" >&2; exit 1; fi
  cp "$1" "${S}/media.$(basename "$2")"; put media_pending "${STUB_PENDING_READS:-0}"; exit 0
}
# The query must reach the device as ONE word, or the device shell would
# re-split its WHERE clause: any other argv answers nothing.
media_query() {
  local up=1 n pending f rows=0
  storage_up || up=0
  n="$(get media_reads)"; put media_reads $(( ${n:-0} + 1 ))
  [[ -z "${STUB_MEDIA_SILENT:-}" ]] || exit 0
  (( $# == 1 )) && [[ "$1" == "content query --uri content://media/external/images/media --projection _display_name --where \"_display_name LIKE 'haven-gate-%'\"" ]] || exit 0
  if [[ -n "${STUB_MEDIA_REFUSED:-}" ]]; then
    printf 'Error while accessing provider:media\njava.lang.SecurityException: Permission Denial\n' >&2; exit 0
  fi
  if (( ! up )); then
    printf 'Error while accessing provider:media\njava.lang.IllegalArgumentException: Volume external_primary not found\n' >&2; exit 0
  fi
  pending="$(get media_pending)"
  if [[ -z "${STUB_MEDIA_NEVER:-}" ]] && (( ${pending:-0} == 0 )); then
    for f in "${S}"/media.haven-gate-*.png; do
      [[ -f "${f}" ]] || continue
      echo "Row: ${rows} _display_name=${f##*/media.}"; rows=$(( rows + 1 ))
    done
  fi
  (( ${pending:-0} == 0 )) || put media_pending $(( pending - 1 ))
  (( rows > 0 )) || echo 'No result found.'
  exit 0
}
case "${1:-}" in
  wait-for-device) exit 0 ;;
  get-state) echo device; exit 0 ;;
  uninstall) rm -f "${S}/installed" "${S}/data/"*; exit 0 ;;
  install) apk="${!#}"
    if [[ -f "${S}/installed" ]]; then
      [[ -n "${STUB_VC_UNCHANGED:-}" ]] || put vc "$(sed -n 's/^vc //p' "${apk}")"
      # A crash the replace provokes (a receiver of MY_PACKAGE_REPLACED, say).
      if [[ -n "${STUB_CRASH_ON_REPLACE:-}" ]]; then
        { tt "FATAL EXCEPTION: main"; tt "Process: ${PKG}, PID: 4243"; tt "java.lang.IllegalStateException: replaced"; } >> "${S}/crash.log"
      fi
    else rm -f "${S}/data/"*; put vc "$(sed -n 's/^vc //p' "${apk}")"; fi
    cp "${apk}" "${S}/apk.$(get pidseq).$RANDOM"; put installed "${apk}"
    echo "Performing Streamed Install"; echo "Success"; exit 0 ;;
  logcat)
    case "$*" in
      "logcat -b all -c") : > "${S}/crash.log"; : > "${S}/events.log" ;;
      "logcat -d -b crash") cat "${S}/crash.log" ;;
      "logcat -d -b events") cat "${S}/events.log" ;;
    esac; exit 0 ;;
  # STUB_EXEC_OUT_DOWN_AFTER_TAP: adb itself fails every dump once a tap was
  # sent, the shell reads still answering.
  exec-out) if [[ -n "${STUB_EXEC_OUT_DOWN_AFTER_TAP:-}" && -f "${S}/tapped" ]]; then echo "error: closed" >&2; exit 1; fi
    dump; exit 0 ;;
  push) media_push "$2" "$3" ;;
  shell) shift ;;
  *) exit 9 ;;
esac
cmd="$*"
if [[ "${cmd}" == "content query "* ]]; then media_query "$@"; fi
case "${cmd}" in
  "pm path ${PKG}") [[ -f "${S}/installed" ]] && echo "package:/data/app/~~x==/${PKG}-y==/base.apk"; exit 0 ;;
  "cmd package wait-for-handler"*) echo; echo "haven-barrier-rc 0 0 255 255" ;;
  "am force-stop ${PKG}") rm -f "${S}/pid" ;;
  "pm grant "*) : ;;
  "getprop sys.boot_completed") echo 1 ;;
  "getprop persist.sys.locale") echo "" ;;
  "getprop ro.product.locale") echo "${STUB_LOCALE:-en-US}" ;;
  "settings put global hide_error_dialogs 1") touch "${S}/hide" ;;
  "settings get global hide_error_dialogs") [[ -f "${S}/hide" ]] && echo 1 || echo 0 ;;
  # STUB_BROADCAST_HANG: a receiver that never finishes, so `am broadcast`
  # never returns; the dialogs were closed on delivery all the same.
  "am broadcast -a android.intent.action.CLOSE_SYSTEM_DIALOGS")
    [[ -n "${STUB_BOOT_DIALOG_STUCK:-}" || ! -f "${S}/boot_dialog" ]] || rm -f "${S}/boot_dialog" "${S}/boot_anr"
    if [[ -n "${STUB_BROADCAST_HANG:-}" ]]; then [[ -p "${S}/never" ]] || mkfifo "${S}/never"; : < "${S}/never"; fi ;;
  "cmd connectivity airplane-mode enable") [[ -n "${STUB_AIRPLANE_STUCK:-}" ]] || touch "${S}/airplane" ;;
  "settings get global airplane_mode_on") [[ -f "${S}/airplane" ]] && echo 1 || echo 0 ;;
  # The activity manager's processes, filtered as the gate asks: the boot
  # dialog's process marked not responding (or crashing) while boot_anr holds.
  "dumpsys activity processes | grep -E '^ACTIVITY MANAGER RUNNING PROCESSES|^  [*](APP|PERS)[*] UID |mCrashing='")
    echo 'ACTIVITY MANAGER RUNNING PROCESSES (dumpsys activity processes)'
    echo '  *PERS* UID 1000 ProcessRecord{5e1a 512:system/1000}'
    echo '  *PERS* UID 10123 ProcessRecord{7c0d 900:com.android.systemui/u0a123}'
    echo '  *APP* UID 10140 ProcessRecord{9b2f 1100:com.google.android.apps.nexuslauncher/u0a140}'
    if [[ -f "${S}/boot_anr" ]]; then
      proc="${STUB_BOOT_DIALOG#*: }"
      echo "  *APP* UID 10150 ProcessRecord{3f1e 1200:${proc}/u0a150}"
      d=null; [[ ! -f "${S}/boot_dialog" ]] || d='[com.android.server.am.AppNotRespondingDialog@1f2e]'
      case "${STUB_BOOT_DIALOG}" in
        'Application Error: '*) echo "     mCrashing=true ${d/AppNotResponding/AppError} mNotResponding=false null bad=false" ;;
        *) echo "     mCrashing=false null mNotResponding=true ${d} bad=false" ;;
      esac
    fi ;;
  "dumpsys connectivity | grep -m1 'Active default network:'")
    [[ -f "${S}/airplane" ]] && echo "Active default network: none" || echo "Active default network: 100" ;;
  "am start -W -n ${PKG}/.MainActivity")
    if [[ -n "${STUB_OFFLINE_AT_LAUNCH:-}" && -f "${S}/data/intro_seen" ]]; then touch "${S}/offline"; exit 1; fi
    launch ;;
  "pidof ${PKG}")
    # Every other read is one adb cannot answer (its own rc 255).
    put pidof_reads $(( $(get pidof_reads) + 1 ))
    if [[ -n "${STUB_PIDOF_FLAKY:-}" ]] && (( $(get pidof_reads) % 2 == 1 )); then exit 255; fi
    [[ -n "$(get pid)" ]] || exit 1; get pid ;;
  # STUB_TAP_REFUSED: `input` fails on the device, saying something no
  # summary may carry.
  "input tap "*) if [[ -n "${STUB_TAP_REFUSED:-}" ]]; then echo "java.lang.SecurityException: stub-device-says-${PKG}" >&2; exit 1; fi
    read -r _ _ x y <<<"${cmd}"; tap "${x}" "${y}"; touch "${S}/tapped" ;;
  "dumpsys package ${PKG} | grep -m1 versionCode=") echo "    versionCode=$(get vc) minSdk=24 targetSdk=35" ;;
  "logcat -d | grep -c logscan-plant-") echo "${STUB_PLANTS:-0}" ;;
  "getprop ro.build.version.sdk") echo "${STUB_API:-34}" ;;
  "touch -t "*|"content call "*) : ;;
  "dumpsys activity activities")
    if [[ -n "$(get bounce)" ]]; then
      if (( $(get bounce) > 0 )); then put bounce $(( $(get bounce) - 1 )); else rm -f "${S}/bounce"; put screen ucrop; ev create ucrop; fi
    fi
    resumed_line ;;
  "date +%s && logcat -d -b events -v epoch") echo "${STUB_NOW:-1000}"; cat "${S}/events.log" ;;
  "dumpsys input") focus_dump ;;
  "input keyevent 4") keyevent ;;
  # STUB_BG_GRANTED: the background-location grant alone does not read back.
  "dumpsys package ${PKG} | grep -c 'android.permission.ACCESS_BACKGROUND_LOCATION: granted=true'") echo "${STUB_BG_GRANTED:-${STUB_GRANTED:-1}}" ;;
  "dumpsys package ${PKG} | grep -c 'android.permission."*": granted=true'") echo "${STUB_GRANTED:-1}" ;;
  "dumpsys deviceidle whitelist +${PKG}") echo "Added: ${PKG}" ;;
  "dumpsys deviceidle whitelist | grep -c ',${PKG},'") echo 1 ;;
  *) exit 9 ;;
esac
exit 0
STUB
  chmod +x "$1/adb"
  cat > "$1/date" <<'STUB'
#!/usr/bin/env bash
# The stub device's clock: the runner reads time only as `date +%s`.
[[ "$*" == +%s ]] || { echo "stub date: unexpected arguments: $*" >&2; exit 9; }
cat "${STUB}/clock"
STUB
  chmod +x "$1/date"
}

self_test() {
  local tmp fails=0 ran=0 rc out
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN
  mkdir -p "${tmp}/bin" "${tmp}/priv"
  _st_write_stub "${tmp}/bin"
  local arb_now arb_old
  arb_now="$(python3 -I -c 'import json, sys
k = sys.argv[1:]
print(json.dumps({k[0]: "Get Started", k[1]: "Create My Identity", k[2]: "Not now",
  k[3]: "Couldn\x27t finish setting up your account. Check your connection and try again.",
  k[4]: "Settings", k[5]: "Identity", k[6]: "Identity", k[7]: "Display Name",
  "onboardingCreateIdentityError": "Something went wrong creating your identity. Please try again.",
  "onboardingDisplayNameError": "Couldn\u2019t save that name. Please try again.",
  "onboardingPhotoNotSaved": "Your photo couldn\u2019t be saved. You can add it later in Settings, under Identity.",
  "photoHeaderAddPhotoSemantics": "Add profile photo", "photoHeaderChangePhotoSemantics": "Change profile photo",
  "photoHeaderRemove": "Remove", "photoHeaderViewPhotoSemantics": "View profile photo", "photoHeaderEditPhoto": "Edit Photo",
  "avatarPickerUpdateError": "Could not update your photo. Please try again.",
  "settingsLocationTitle": "Location", "settingsLocationSubtitleOff": "Only while Haven is open",
  "settingsLocationSubtitleOn": "Background sharing on", "locationSettingsToggleTitle": "Share in background",
  "locationDisclosureAgree": "Agree",
  "locationSettingsBatteryOptSnack": "On. Battery optimization may pause sharing on some phones. Exclude Haven from battery optimization to keep it reliable.",
  "locationSettingsNotificationDeniedSnack": "Background sharing needs a notification so Android keeps it running."}))' \
    "${KEY_WELCOME}" "${KEY_CREATE}" "${KEY_NOT_NOW}" "${KEY_SETUP_HELD}" "${KEY_MAP}" "${KEY_IDENTITY}" "${KEY_IDENTITY_PAGE}" "${KEY_NAME_LOADING}")"
  # A pre-OD-C ARB, as v0.1.13's: no onboardingFinishSetupError.
  arb_old="$(python3 -I -c 'import json,sys; d=json.loads(sys.argv[1]); d.pop("onboardingFinishSetupError"); print(json.dumps(d))' "${arb_now}")"

  _mkdir() { # <dir> <tag> <vc> <flow> <arb-json>
    mkdir -p "$1"
    printf 'flow %s\nvc %s\n' "$4" "$3" > "$1/install.apk"
    printf '%s\n' "$5" > "$1/app_en.arb"
    printf '%s\n' "$3" > "$1/version_code"
    printf '%s\n' "$2" > "$1/tag"
  }
  # _scenario <label> <want-rc> <cand-flow> <prev-flow> [VAR=value...]
  _scenario() {
    local label="$1" want_rc="$2" cf="$3" pf="$4"
    shift 4
    ran=$(( ran + 1 ))
    rm -rf "${tmp}/stub" "${tmp}/cand" "${tmp}/prev" "${tmp}/out" "${tmp}/priv" "${tmp}/seal.argv"
    mkdir -p "${tmp}/stub/data" "${tmp}/priv"
    : > "${tmp}/stub/crash.log"; : > "${tmp}/stub/events.log"; echo 4000 > "${tmp}/stub/pidseq"
    echo 0 > "${tmp}/stub/clock"
    _mkdir "${tmp}/cand" candidate 4022 "${cf}" "${ARB_CAND:-${arb_now}}"
    _mkdir "${tmp}/prev" v0.1.13 4020 "${pf}" "${ARB_PREV:-${arb_old}}"
    rc=0
    # The bound turns a gate that hangs (a wait it should bound and does not)
    # into rc 124: every scenario ends in seconds.
    out="$(timeout 300 env PATH="${tmp}/bin:${PATH}" STUB="${tmp}/stub" STUB_NAME="${ST_NAME}" TMPDIR="${tmp}/priv" \
      LAUNCH_GATE_OUT="${tmp}/out/summary" \
      HAVEN_LOGSCAN=true HAVEN_LOGSCAN_BIN="${LOGSCAN_FAKE_BIN}" FAKE_SEAL_ARGV="${tmp}/seal.argv" \
      GITHUB_RUN_ID="launch-gate-self-test-$$-${ran}" GITHUB_RUN_ATTEMPT=1 LAUNCH_GATE_SCREEN_SECS=20 LAUNCH_GATE_FINISH_SECS=30 \
      LAUNCH_GATE_OFFLINE_SECS=8 LAUNCH_GATE_PROCESS_SECS=4 LAUNCH_GATE_SETTLE_SECS=6 LAUNCH_GATE_APPLY_SECS=24 \
      PHOTO_STORAGE_SECS=10 PHOTO_MEDIA_SECS=12 PHOTO_PICKER_SECS=40 PHOTO_UCROP_SECS=36 PHOTO_RETURN_SECS=32 "$@" \
      bash "${BASH_SOURCE[0]}" "${tmp}/cand" "${tmp}/prev" 2>&1)" || rc=$?
    if (( rc == want_rc )); then
      printf '  PASS %s\n' "${label}"
    else
      printf '  FAIL %s (want rc %s, got %s)\n%s\n' "${label}" "${want_rc}" "${rc}" "${out}" >&2
      fails=1
    fi
    # Every scenario: the generated name never reaches the transcript or the
    # summaries, and the private directory is gone.
    if grep -qF -- "${ST_NAME}" <<<"${out}" || grep -rqF -- "${ST_NAME}" "${tmp}/out" 2>/dev/null; then
      printf '  FAIL %s: the display name reached the transcript or a summary\n' "${label}" >&2
      fails=1
    fi
    # …nor what a picker thumbnail's description says.
    if grep -qF -- "${ST_PICKER_DESC}" <<<"${out}" || grep -rqF -- "${ST_PICKER_DESC}" "${tmp}/out" 2>/dev/null; then
      printf '  FAIL %s: a picker thumbnail description reached the transcript or a summary\n' "${label}" >&2
      fails=1
    fi
    # …nor the URI an activity was started with (the events buffer has it).
    if grep -qF -- 'content://' <<<"${out}" || grep -rqF -- 'content://' "${tmp}/out" 2>/dev/null; then
      printf '  FAIL %s: a content URI reached the transcript or a summary\n' "${label}" >&2
      fails=1
    fi
    # …nor does a screen digest, which hashes that name (no 64-hex string at all).
    if grep -Eq '[0-9a-f]{64}' <<<"${out}" || grep -rEq '[0-9a-f]{64}' "${tmp}/out" 2>/dev/null; then
      printf '  FAIL %s: a 64-hex string (a screen digest?) reached the transcript or a summary\n' "${label}" >&2
      fails=1
    fi
    if [[ -n "$(ls -A "${tmp}/priv")" ]]; then
      printf '  FAIL %s: the private directory was left behind\n' "${label}" >&2
      fails=1
    fi
    # …and no input ever reached a system screen whose window did not hold focus.
    if [[ -s "${tmp}/stub/unfocused" ]]; then
      printf '  FAIL %s: an input was sent to the picker or uCrop before its window held focus: %s\n' "${label}" "$(tr '\n' ' ' < "${tmp}/stub/unfocused")" >&2
      fails=1
    fi
  }
  _has() { # <label> <fixed-string> — the last transcript names it
    ran=$(( ran + 1 ))
    if grep -qF -- "$2" <<<"${out}"; then printf '  PASS %s\n' "$1"; else
      printf '  FAIL %s: transcript lacks "%s"\n%s\n' "$1" "$2" "${out}" >&2; fails=1; fi
  }
  _lacks() { # <label> <fixed-string> — the last transcript never says it
    ran=$(( ran + 1 ))
    if ! grep -qF -- "$2" <<<"${out}"; then printf '  PASS %s\n' "$1"; else
      printf '  FAIL %s: transcript says "%s"\n%s\n' "$1" "$2" "${out}" >&2; fails=1; fi
  }

  echo "run-launch-gate-android.sh --self-test"
  # (1) The current product: fresh SETUP_HELD with the name restored; the
  #     upgrade from a pre-OD-C release that reaches the map.
  #     The previous release is v0.1.13-shaped: it declines the background
  #     disclosure, then the foreground one (same "Not now", another dialog),
  #     and the upgraded candidate's map opens under that dialog again.
  _scenario "a healthy candidate passes every leg" 0 setup-held map
  _has "…fresh ends SETUP_HELD and upgrade MAP" "legs passed: fresh=SETUP_HELD upgrade=MAP"
  _has "…and both photo rounds applied, by the Photo Picker's id and uCrop's" "photo: onboarding=ok map=ok picker=photopicker-rid ucrop=rid"
  _taps() { # <label> — the run made exactly the twenty-one taps the flows need
    ran=$(( ran + 1 ))
    local n
    n="$(grep -c '^-s emulator-5554 shell input tap ' "${tmp}/stub/calls" || true)"
    if [[ "${n}" == 21 ]]; then printf '  PASS %s\n' "$1"; else
      printf '  FAIL %s: %s taps, want 21 (welcome and create, twice; two disclosures; the reopened map'"'"'s disclosure, Settings, Identity; Add photo, thumbnail, crop; Location, the toggle, Agree, Identity; Edit Photo, thumbnail, crop; Settings and Identity after the restart)\n' "$1" "${n}" >&2; fails=1; fi
  }
  _taps "…with every CTA tapped once per screen it appeared on: 21 taps"
  # The media-store query and the battery exemption, as the device got them.
  ran=$(( ran + 1 ))
  if grep -qxF -- "-s emulator-5554 shell dumpsys deviceidle whitelist +com.oblivioustech.haven" "${tmp}/stub/calls" \
     && grep -qF -- "-s emulator-5554 push " "${tmp}/stub/calls"; then
    echo "  PASS the fixtures are pushed and the battery exemption is asked for before the MapShell round"
  else echo "  FAIL the fixtures or the battery exemption never reached the device" >&2; fails=1; fi
  # (6) Each tap's outgoing screen stays in the tree for two dumps (alone,
  #     then beside the new one): a label still visible mid-transition is
  #     neither "did not progress" nor tapped again.
  _scenario "a tapped label still on screen during a transition is not a stall" 0 setup-held map STUB_TRANSITION=1
  _taps "…and is never tapped twice: still 21 taps"
  # (8) The Identity page whose card is still loading for three dumps: its
  #     title reads like the Settings entry, and is never tapped.
  _scenario "an Identity page still loading is waited on, its title never tapped" 0 setup-held map STUB_IDENTITY_LOADING=3
  _taps "…still 21 taps"
  # (10) The scanner is told the generated name, so it proves it absent.
  ran=$(( ran + 1 ))
  if grep -qxF -- "display_name=${ST_NAME}" "${tmp}/seal.argv"; then echo "  PASS the generated name is declared to the log-privacy gate"; else
    echo "  FAIL the generated name was not declared to the seal" >&2; fails=1; fi
  # (11) The v0.1.14 crash: product, the crash summary names the missing
  #     constructor, the native frame is reduced and the install path gone.
  _scenario "a candidate that crashes at start is a product failure" 1 crash-at-start map
  _has "…and the ::error:: line names the missing constructor" "WorkDatabase_Impl.<init>"
  _has "…native frames reduced to number, offset and library" "#00 pc 000000000005e8b4 librust_lib_haven.so"
  ran=$(( ran + 1 ))
  if grep -q '/data/app/' <<<"${out}"; then echo "  FAIL the random install path reached the transcript" >&2; fails=1
  else echo "  PASS random install paths are removed"; fi
  ran=$(( ran + 1 ))
  if grep -Eq 'r8-map-id-[0-9a-f]' <<<"${out}"; then echo "  FAIL R8's map id reached the transcript" >&2; fails=1
  else echo "  PASS R8's map id is removed from Java frames"; fi
  # (16) The crash summary is echoed only after the log-privacy gate.
  ran=$(( ran + 1 ))
  local gate_at echo_at
  gate_at="$(grep -n '^scan-logs: ' <<<"${out}" | head -n 1 | cut -d: -f1)"
  echo_at="$(grep -n -- '--- crash summary ---' <<<"${out}" | head -n 1 | cut -d: -f1)"
  if [[ -n "${gate_at}" && -n "${echo_at}" ]] && (( gate_at < echo_at )); then
    echo "  PASS the crash summary is echoed only after the log-privacy gate"
  else
    echo "  FAIL the crash summary is echoed only after the log-privacy gate (gate line ${gate_at:-none}, echo line ${echo_at:-none})" >&2; fails=1
  fi
  # (17) A gate that finds a leak: nothing is echoed and the run is red.
  _scenario "a summary the gate refuses is never echoed" 1 crash-at-start map FAKE_SCAN_RC=1
  ran=$(( ran + 1 ))
  if grep -q -- '--- crash summary ---\|^launch-gate-android verdict' <<<"${out}"; then
    echo "  FAIL a refused summary was echoed" >&2; fails=1
  else echo "  PASS …and neither summary reaches the transcript"; fi
  # (19) The previous release crashing is the upgrade source, not the candidate.
  _scenario "a previous release that crashes is rc 4 (upgrade source unusable)" 4 setup-held crash-at-start
  # (20) A process replaced mid-journey.
  _scenario "a pid change mid-journey is a product failure" 1 setup-held map STUB_PID_FLIP=1
  # (21) A pid read adb cannot answer is polled past, never read as a death.
  _scenario "an unanswered pid read is not a death" 0 setup-held map STUB_PIDOF_FLAKY=1
  # (22) An ANR in the events buffer.
  _scenario "an am_anr for the package is a product failure" 1 setup-held map STUB_ANR=1
  _has "…reported as a crash" "the app crashed"
  # (24) Onboarding forgotten across the restart.
  _scenario "the intro after a cold restart is a product failure" 1 setup-held map STUB_FORGET_INTRO=1
  _has "…named as lost onboarding state" "showed the intro again"
  # (26) The saved name not restored.
  _scenario "a display name that is not restored is a product failure" 1 setup-held map STUB_NAME_LOST=1
  _has "…named as such" "did not show the display name the first launch saved"
  # An upgrade that keeps the onboarding flag and loses the identity: the map
  # opens, but the Identity page has no name.
  _scenario "an upgraded map whose Identity page lost the name is a product failure" 1 setup-held map STUB_IDENTITY_LOST=1
  _has "…named at the upgrade leg's Identity page" "leg upgrade (from v0.1.13), state after settingsIdentityTitle; a cold launch did not show the display name the first launch saved"
  # A crash moments after a terminal screen is drawn.
  _scenario "a crash just after the setup screen is a product failure" 1 setup-held map STUB_LATE_CRASH=1
  _has "…caught by the settle watch" "state: SETUP_HELD, settling"
  # A crash the upgrade's own install provokes is not cleared away.
  _scenario "a crash during the in-place install is a product failure" 1 setup-held map STUB_CRASH_ON_REPLACE=1
  _has "…blamed on the candidate, not the upgrade source" "verdict: product (rc 1)"
  # (34) The upgrade not taking.
  _scenario "a versionCode unchanged by the upgrade is a product failure" 1 setup-held map STUB_VC_UNCHANGED=1
  # (35) The device going away.
  _scenario "a device that goes offline is infrastructure" 3 setup-held map STUB_OFFLINE_AT_LAUNCH=1
  # (36) Another app holding the screen.
  _scenario "a foreign window until the deadline is a product failure naming it" 1 setup-held map \
    STUB_FOREIGN=com.android.permissioncontroller \
    STUB_FOREIGN_FOCUS=com.android.permissioncontroller/com.android.permissioncontroller.permission.ui.GrantPermissionsActivity
  _has "…naming the package and what held input focus" "com.android.permissioncontroller held the foreground at state after onboardingWelcomeCta until the deadline (input focus on com.android.permissioncontroller/"
  # An error dialog is rooted in package `android` whoever stopped responding
  # (CI run 44698826899, API 35: `android` over the first screen for the whole
  # window, Haven alive, no crash or ANR of Haven's): input focus says whose.
  _scenario "another process's \"isn't responding\" dialog over Haven's first screen is infrastructure" 3 setup-held map \
    STUB_FOREIGN=android STUB_FOREIGN_ON=intro "STUB_FOREIGN_FOCUS=Application Not Responding: com.android.systemui"
  _has "…named as such" "input focus was on System UI's \"isn't responding\" dialog at state first screen (before the onboarding photo) when its window closed"
  _scenario "Haven's own \"isn't responding\" dialog over its first screen is a product failure" 1 setup-held map \
    STUB_FOREIGN=android STUB_FOREIGN_ON=intro "STUB_FOREIGN_FOCUS=Application Not Responding: com.oblivioustech.haven"
  _has "…named as such" "input focus was on Haven's \"isn't responding\" dialog at state first screen (before the onboarding photo) when its window closed: Haven failed"
  _scenario "a system window that is no error dialog over Haven's first screen is a product failure naming it" 1 setup-held map \
    STUB_FOREIGN=android STUB_FOREIGN_ON=intro STUB_FOREIGN_FOCUS=android
  _has "…with the focus in fixed words" "android held the foreground at state first screen (before the onboarding photo) until the deadline (input focus on a window that is no activity's)"
  _scenario "a foreign root while Haven's own activity holds input focus is Haven's own stall" 1 setup-held map \
    STUB_FOREIGN=android STUB_FOREIGN_ON=intro
  _has "…named as Haven's screen not settling" "the create screen did not settle with photoHeaderAddPhotoSemantics on it"
  _lacks "…never as the foreign root holding the foreground" "held the foreground"
  # CI run 44870800362, API 35: an "isn't responding" dialog the boot raised
  # before hide_error_dialogs was set, over Haven's first screen for the whole
  # window. The setting does not close it; CLOSE_SYSTEM_DIALOGS does.
  _scenario "an error dialog the boot left in front is closed before the first leg" 0 setup-held map \
    "STUB_BOOT_DIALOG=Application Not Responding: com.google.android.apps.nexuslauncher"
  ran=$(( ran + 1 ))
  # One process, not `sed | grep -q`: grep -q exits at the match, and under
  # pipefail the SIGPIPE that then ends sed failed this check at random.
  if awk -v want='-s emulator-5554 shell am broadcast -a android.intent.action.CLOSE_SYSTEM_DIALOGS' \
      'index($0, "settings get global hide_error_dialogs") { after = 1 } after && $0 == want { found = 1; exit } END { exit !found }' \
      "${tmp}/stub/calls"; then
    echo "  PASS …by CLOSE_SYSTEM_DIALOGS, once hide_error_dialogs reads back 1"
  else echo "  FAIL CLOSE_SYSTEM_DIALOGS never reached the device after hide_error_dialogs read back 1" >&2; fails=1; fi
  _scenario "an error dialog CLOSE_SYSTEM_DIALOGS does not close is infrastructure, before any leg" 3 setup-held map \
    "STUB_BOOT_DIALOG=Application Not Responding: com.google.android.apps.nexuslauncher" STUB_BOOT_DIALOG_STUCK=1
  _has "…naming whose process the activity manager still held" "no read of the activity manager's processes within 8 s showed none in an error state (last read: another app's process held as not responding), after 2 CLOSE_SYSTEM_DIALOGS broadcast(s)"
  _has "…and no leg ran under it" "legs passed: none"
  # Release run 44922735173, API 35: readiness read input focus free of an
  # error dialog, and System UI's "isn't responding" dialog held it from the
  # first leg's launch on; the activity manager had marked System UI before.
  # Here the dialog's window is up only after readiness's first read and after
  # the first broadcast, which had nothing to close: reading focus, the gate
  # gives that run's verdict word for word.
  _scenario "a process the boot left not responding, its dialog not yet holding focus, is waited out before the first leg" 0 setup-held map \
    "STUB_BOOT_DIALOG=Application Not Responding: com.android.systemui" STUB_BOOT_DIALOG_SHOWN_AT=13 LAUNCH_GATE_OFFLINE_SECS=12
  _lacks "…never stalling the first leg under it" "when its window closed"
  _has "…ready only once no process is held in an error state" "device ready: booted, en-US, airplane mode on, no default network, no process in an error state"
  # `am broadcast` waits for the ordered broadcast to finish, and one receiver
  # that never does would hold the gate past every bound it states.
  _scenario "a CLOSE_SYSTEM_DIALOGS broadcast that never finishes is bounded, and the dialog it closed is gone" 0 setup-held map \
    "STUB_BOOT_DIALOG=Application Not Responding: com.google.android.apps.nexuslauncher" STUB_BROADCAST_HANG=1
  # (38) A debug log plant in a release build.
  _scenario "a debug log plant is a product failure" 1 setup-held map STUB_PLANTS=2
  # (39) A tap that does not take effect.
  _scenario "a CTA still on screen after its tap is 'did not progress'" 1 setup-held map STUB_CTA_STUCK=1
  _has "…the screen unchanged for the whole window after the tap" "did not progress: the screen did not change in the window after onboardingWelcomeCta was tapped"
  _has "…naming what held input focus, so a tap that missed Haven's window is told from a Haven that did not answer" "was tapped (input focus on com.oblivioustech.haven/com.oblivioustech.haven.MainActivity)"
  _has "…the tap accepted by the device" "evidence: since the tap on onboardingWelcomeCta, accepted by the device: "
  _has "…and judged on dumps taken after it, every one the screen it was made on" " dump(s) read, all unchanged, 0 failed; the last observation is fresh, taken after it"
  # CI run 136755434767 (API 34): a failed dump left the last observation on a
  # screen from before the tap, and nothing said so. adb answering with no
  # dump is also what a Haven no longer answering accessibility queries gives,
  # so it stays product, but never as "the screen did not change".
  _scenario "dumps that come back empty after an accepted tap are a stall on stale evidence, still product" 1 setup-held map STUB_DUMP_EMPTY_AFTER_TAP=1
  _has "…never claiming the screen did not change" "did not progress: no dump of the screen succeeded in the window after onboardingWelcomeCta was tapped, though adb answered"
  _has "…its last observation, from before the tap, called stale" "last observation: visible [onboardingWelcomeCta], foreground com.oblivioustech.haven, edittexts 0; since the tap on onboardingWelcomeCta, accepted by the device: 0 dump(s) read, "
  _has "…with ui-dump.py's reason" " the dump is empty); the last observation is stale: no dump has succeeded since"
  # Every dump after the tap failed at adb itself: the gate saw nothing.
  _scenario "dumps that all fail at adb after an accepted tap are infrastructure" 3 setup-held map STUB_EXEC_OUT_DOWN_AFTER_TAP=1
  _has "…named as such" "adb reached no dump in the window after the tap on onboardingWelcomeCta, accepted by the device: all "
  _has "…the last observation called stale" " adb did not reach the device); the last observation is stale: no dump has succeeded since"
  # A tap the device refused never reached Haven.
  _scenario "a tap the device refuses is infrastructure" 3 setup-held map STUB_TAP_REFUSED=1
  _has "…named as such" "the device refused the tap on onboardingWelcomeCta (adb rc 1): the input never reached Haven"
  _lacks "…never as Haven not answering it" "did not progress"
  _lacks "…and what the device said is not echoed" "stub-device-says-"
  # (41) The device not in the state the gate needs.
  _scenario "a device that is not en-US is infrastructure" 3 setup-held map STUB_LOCALE=fr-FR
  _scenario "a device that will not go offline is infrastructure" 3 setup-held map STUB_AIRPLANE_STUCK=1
  # (43) Deadlines run on the injected clock, not this machine's: a device
  #      whose every call outlasts a screen's window stalls at the first one.
  _scenario "a device slower than a screen's window is a stall at the first screen" 1 setup-held map STUB_TICK=100
  _has "…on the stub's clock, before any observation" "state first screen (before the onboarding photo); the create screen did not settle with photoHeaderAddPhotoSemantics on it, so the onboarding photo round could not start; last observation: no observation yet"
  # (45) A name field the gate cannot read is never tapped past.
  _scenario "a create screen without a readable name field is a product failure" 1 setup-held map STUB_EDIT_CLASS=android.view.View
  _has "…named as such" "never showed exactly one non-empty name field"
  # --- The photo rounds. ---
  # The bound after a crop is the product's worst case, pinned to the Dart
  # constants it is derived from.
  ran=$(( ran + 1 ))
  local handover drain after endwait
  handover="${SCRIPT_DIR}/../../../haven/lib/src/services/mls_session_handover.dart"
  drain="$(sed -nE 's/^const int _teardownDrainBudgetSecs = ([0-9]+);/\1/p' "${handover}")"
  after="$(sed -nE 's/^const int _teardownAfterDrainSecs = ([0-9]+);/\1/p' "${handover}")"
  endwait="$(sed -nE 's/^const Duration kHandoffEndWait = Duration\(seconds: ([0-9]+)\);/\1/p' "${handover}")"
  if [[ -n "${drain}" && -n "${after}" && -n "${endwait}" ]] && (( ${LAUNCH_GATE_APPLY_SECS:-40} == drain + after + endwait + 10 )); then
    echo "  PASS APPLY_SECS is handoverTimeout + kHandoffEndWait + 10 s, read from mls_session_handover.dart"
  else
    echo "  FAIL APPLY_SECS (${LAUNCH_GATE_APPLY_SECS:-40}) is not handoverTimeout (${drain:-?} + ${after:-?}) + kHandoffEndWait (${endwait:-?}) + 10" >&2; fails=1
  fi
  _scenario "a photo save refused after the crop is a product failure (root cause A)" 1 setup-held map STUB_PHOTO_REFUSED=1
  _has "…named as the hand-off class" "the photo save was refused after the crop (avatarPickerUpdateError)"
  _has "…at the MapShell round" "leg upgrade (from v0.1.13), state photo round (identity), back from uCrop"
  _scenario "uCrop crashing for a missing androidx class is a product failure with its crash summary" 1 setup-held map STUB_UCROP_CRASH=1
  _has "…naming the class" "NoClassDefFoundError: Failed resolution of: Landroidx/appcompat/app/AppCompatActivity;"
  _scenario "a picker screen no selector knows is a harness failure, rc 2" 2 setup-held map STUB_PICKER_UNKNOWN=1
  _has "…listing the resource ids it does have" "rids: unknown_grid_item"
  _scenario "a photo tap that opens no picker is 'did not progress'" 1 setup-held map STUB_PICKER_NEVER=1
  _has "…named as such" "did not progress: the photo tap opened no picker"
  _scenario "DocumentsUI in place of the Photo Picker on API 34 is a product failure" 1 setup-held map STUB_PICKER_COMPONENT=documentsui
  _has "…naming the broken promise" "a picker other than the system Photo Picker opened (com.google.android.documentsui/com.android.documentsui.picker.PickActivity)"
  _scenario "the GET_CONTENT picker alias on API 34 is a product failure" 1 setup-held map STUB_PICKER_COMPONENT=getcontent
  _scenario "an activity the picker rules do not know is a harness failure, not a product one" 2 setup-held map STUB_PICKER_COMPONENT=unknown
  _has "…naming its component" "took the front after the photo tap (com.android.photopicker/com.android.photopicker.MainActivity)"
  _scenario "DocumentsUI below API 33 is the picker that API has, and passes" 0 setup-held map STUB_PICKER_COMPONENT=documentsui STUB_API=32
  _has "…by its own selector" "picker=documentsui-rid"
  _scenario "a photo that does not show within APPLY_SECS is a product failure" 1 setup-held map STUB_APPLY_DUMPS=999
  _has "…named with its bound" "the photo did not show within 24 s of Haven's return from uCrop"
  _scenario "a photo gone after the cold restart is a product failure" 1 setup-held map STUB_PHOTO_LOST=1
  _has "…named as such" "the photo saved at MapShell was gone after a cold restart"
  _scenario "uCrop that never hands Haven back is a product failure" 1 setup-held map STUB_UCROP_NEVER=1
  _has "…named as such" "uCrop did not return a result"
  _scenario "uCrop's crop action without its id is found by its description" 0 setup-held map STUB_UCROP_NO_RID=1
  _has "…and the summary says which" "ucrop=desc"
  # The first device run: the picker resumed long before its window held
  # focus. Every input waits for the focus, so none is dropped (the check
  # every scenario makes), and the trip still completes.
  _scenario "a picker and uCrop that take focus late get no input before they hold it" 0 setup-held map STUB_FOCUS_LAG=4
  _taps "…and the trip still makes its 21 taps"
  # CI run 44503460373: the picker finished on the thumbnail tap and the gate
  # read MainActivity, resumed while image_picker copied the photo and before
  # uCrop started, as Haven having come back without the crop editor.
  _scenario "Haven resumed between the picker and uCrop is the trip going on, not a failure" 0 setup-held map STUB_PICK_BOUNCE=3
  _has "…and both rounds apply" "photo: onboarding=ok map=ok picker=photopicker-rid ucrop=rid"
  _scenario "a pick after which Haven stays in front without uCrop is a product failure at the bound" 1 setup-held map STUB_PICK_SILENT=1
  _has "…named as such" "photo round (onboarding): the crop editor did not open within 36 s of the pick: Haven came back from the picker and stayed in front"
  _has "…with what the activity manager recorded: the picker came and went, uCrop never started" "events=[+PhotoPickerActivity -PhotoPickerActivity(app-request)]"
  _scenario "uCrop closing itself under Haven's photo-failure SnackBar is a product failure, named at once" 1 setup-held map STUB_UCROP_ERROR=1
  _has "…named by the SnackBar Haven showed" "Haven showed its photo-failure message (avatarPickerUpdateError) instead of the crop editor"
  _has "…and the trace shows uCrop opened and closed between two reads" "events=[+PhotoPickerActivity -PhotoPickerActivity(app-request) +UCropActivity -UCropActivity(app-request)]"
  _scenario "Haven's \"isn't responding\" dialog over the picker is a product failure" 1 setup-held map STUB_NEVER_FOCUSED=picker "STUB_FOCUS_WINDOW=Application Not Responding: com.oblivioustech.haven"
  _has "…named as such" "input focus was on Haven's \"isn't responding\" dialog over the picker for 40 s: Haven failed while the picker was open"
  _scenario "System UI's \"isn't responding\" dialog over the picker is infrastructure" 3 setup-held map STUB_NEVER_FOCUSED=picker "STUB_FOCUS_WINDOW=Application Not Responding: com.android.systemui"
  _has "…named as such" "input focus was on System UI's \"isn't responding\" dialog over the picker for 40 s"
  _scenario "a picker whose window never takes focus gets no input and is a harness failure" 2 setup-held map STUB_NEVER_FOCUSED=picker
  _has "…named as such" "the system picker was resumed but its window never took input focus within 40 s (focus on no window), so no input was sent to it"
  _scenario "uCrop, Haven's own, never taking focus is a product failure" 1 setup-held map STUB_NEVER_FOCUSED=ucrop
  _has "…named as such" "uCrop, Haven's own activity, was resumed but its window never took input focus"
  ARB_PREV="${arb_now}" _scenario "a run in which no leg reached MapShell is rc 2" 2 setup-held setup-held
  _has "…naming the untested hand-off path" "no leg reached MapShell"
  # The gallery is seeded right after sys.boot_completed, which AOSP sets
  # before the system user's storage is mounted: the API-35 run got there
  # first, and its first push failed at once.
  _scenario "shared storage attached only after the gate reaches the gallery is waited for, then seeded" 0 setup-held map \
    STUB_API=35 STUB_STORAGE_LATE=3 STUB_PENDING_READS=2
  _has "…and the gallery is seeded on API 35" "gallery seeded (API 35)"
  _scenario "shared storage that never attaches is infrastructure" 3 setup-held map STUB_STORAGE_NEVER=1
  _has "…named as such" "the media store had no shared storage attached within 10 s"
  _scenario "a media-store query adb never answers is infrastructure" 3 setup-held map STUB_MEDIA_SILENT=1
  _has "…named as such" "adb gave no answer to the media-store query within 10 s"
  _scenario "a media-store query the device refuses is a harness failure" 2 setup-held map STUB_MEDIA_REFUSED=1
  _has "…named as such" "the media store refused the gallery query for 10 s though adb answered"
  _scenario "a push the device refuses, its storage attached, is a harness failure" 2 setup-held map STUB_PUSH_REFUSED=1
  _has "…named as such" "the device refused a gallery fixture's push into /sdcard/Pictures"
  _scenario "a media store that answers but never lists the fixtures is a harness failure" 2 setup-held map STUB_MEDIA_NEVER=1
  _has "…named as such, with the API level" "gallery (API 34): the media store answered but never listed both gallery fixtures"
  _scenario "background sharing held off by the battery snack is a harness precondition, rc 2" 2 setup-held map STUB_BG_SNACK=1
  _has "…named as such" "harness precondition: background sharing did not turn on"
  _scenario "background sharing that does not turn on with everything granted is a product failure" 1 setup-held map STUB_BG_STUCK=1
  _has "…named as such" "background sharing did not turn on through Settings > Location"
  _scenario "a permission grant that does not read back is infrastructure" 3 setup-held map STUB_GRANTED=0
  _has "…naming the permission" "pm grant POST_NOTIFICATIONS did not read back as granted"
  _scenario "background sharing is enabled only over a read-back \"Allow all the time\" grant" 3 setup-held map STUB_BG_GRANTED=0
  _has "…naming it" "pm grant ACCESS_BACKGROUND_LOCATION did not read back as granted"
  ARB_CAND="$(python3 -I -c 'import json,sys; d=json.loads(sys.argv[1]); d.pop("photoHeaderEditPhoto"); print(json.dumps(d))' "${arb_now}")" \
    _scenario "a candidate ARB without a photo label is a usage error" 2 setup-held map
  _scenario "the create screen reporting a photo it could not save is a product failure" 1 setup-held map STUB_ONB_NOT_SAVED=1
  _has "…naming the key" "the app showed onboardingPhotoNotSaved"
  # (113) An error state names its key; a required key missing is usage.
  _scenario "a display-name error on screen is a product failure naming it" 1 name-error map
  ARB_CAND="$(python3 -I -c 'import json,sys; d=json.loads(sys.argv[1]); d.pop("commonSettings"); print(json.dumps(d))' "${arb_now}")" \
    _scenario "an ARB without a required key is a usage error" 2 setup-held map

  # Every window must read the clock the stub `date` counts, the photo trip's
  # in photo-picker-lib.sh included; a single loop put back on bash's SECONDS
  # races the wall clock again, and the slow-device fixture above only covers
  # the first screen's window.
  ran=$(( ran + 1 ))
  if grep -nE '^[^#]*(\$\{?SECONDS|\(\(\s*SECONDS|SECONDS\s*[-+*/<>=])' "${BASH_SOURCE[0]}" "${SCRIPT_DIR}/photo-picker-lib.sh" >&2; then
    echo "  FAIL a window reads bash's SECONDS instead of date +%s" >&2; fails=1
  else echo "  PASS every window reads date +%s, never SECONDS"; fi

  if (( ran != SELF_TEST_FIXTURES )); then
    echo "SELF-TEST FAIL: ran ${ran} fixture(s), expected ${SELF_TEST_FIXTURES}" >&2
    fails=1
  fi
  if (( fails )); then
    echo "run-launch-gate-android.sh --self-test: FAILED" >&2
    return 1
  fi
  echo "run-launch-gate-android.sh --self-test: all ${ran} fixtures passed"
}

main() {
  local cand="${1:-}" prev="${2:-}" base="${LAUNCH_GATE_BASELINE_DIR:-}" d k
  local -a required_keys=("${KEY_WELCOME}" "${KEY_CREATE}" "${KEY_MAP}")
  mkdir -p "${OUT_DIR}"
  PRIV="$(mktemp -d)"
  chmod 0700 "${PRIV}"
  trap finish EXIT
  for d in "${cand}" "${prev}" ${base:+"${base}"}; do
    for k in install.apk app_en.arb version_code tag; do
      [[ -s "${d}/${k}" ]] || verdict 2 "'${d}' has no ${k}"
    done
    for k in "${required_keys[@]}"; do
      python3 -I "${UI_DUMP}" keys --arb "${d}/app_en.arb" --keys "${k}" | grep -qx "${k}" \
        || verdict 2 "$(cat "${d}/tag")'s app_en.arb has no usable ${k}"
    done
  done
  # The candidate also needs the way to its Identity page, and every label
  # the photo rounds and the background-sharing toggle are read by.
  for k in "${KEY_IDENTITY}" "${KEY_IDENTITY_PAGE}" ${PHOTO_KEYS//,/ }; do
    python3 -I "${UI_DUMP}" keys --arb "${cand}/app_en.arb" --keys "${k}" | grep -qx "${k}" \
      || verdict 2 "the candidate's app_en.arb has no usable ${k}"
  done
  preconditions
  leg_fresh "${cand}"
  leg_upgrade upgrade "${prev}" "${cand}"
  if [[ -n "${base}" ]]; then
    leg_upgrade baseline "${base}" "${cand}"
  else
    say "baseline: skipped (LAUNCH_GATE_BASELINE_DIR unset: the baseline is the previous release)"
  fi
  LEG='all'
  STATE='done'
  [[ -n "${PHOTO_AT_MAP_DONE}" ]] \
    || verdict 2 "no leg reached MapShell, so the photo save under background sharing (root cause A's hand-off path) went untested; the gate needs the baseline leg"
  verdict 0 "every leg passed"
}

if [[ "${1:-}" == "--self-test" ]]; then
  self_test
  exit $?
fi
main "$@"
