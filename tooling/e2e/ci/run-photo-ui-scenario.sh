#!/usr/bin/env bash
#
# The debug photo UI lane: the real Identity-page photo trip — system Photo
# Picker and uCrop — with background sharing on, against the hermetic profile
# relays and the Primal-mimicking Blossom server.
#
# The Dart target (haven/integration_test/e2e/e2e_profile_ui_photo.dart) taps
# the app; Android's picker and uCrop are other activities no Flutter test can
# touch, so this runner plays the user there, from the host, while
# run-single-avd-scenario.sh drives the target. The two sides never wait on
# each other's words, only on each other's effects:
#
#   Dart                                    host (the sidecar, below)
#   print "[pp] ARM round=<n> act=<a>"  ->  sees the marker in the logcat
#   tap Edit Photo                          waits for the picker to be resumed
#   await its lifecycle sequence            picks thumbnail <i> (or BACK)
#     (pick: paused, then resumed;          waits for uCrop, taps its crop,
#      cancel: inactive, then resumed,      waits for MainActivity
#      no paused)                     <-    (the app's own resume hands back)
#   asserts the photo, and waits for  <-    records the round, then creates
#     files/pp_recorded_<n>                 files/pp_recorded_<n> (run-as)
#   the relays, Bob; then the next ARM      waits for n+1
#   print "[pp] END rounds=<n>"             checks the count
#
# The record file is the one effect the Dart side waits for from here: an ARM
# that came before the sidecar saw Haven back would put the picker in front
# again, and the sidecar would wait out its return window on a screen it was
# never asked about. The drive also cannot end under a round this has not
# recorded, so a refused run-as is the harness's, never a dying drive's.
#
# Per pick round the sidecar also requires MapShell's Android pause branch
# marker between the ARM and the return (C6: `[MapShell] pause: background
# handoff branch`) — the precondition of root cause A, true before and after
# the fix — and reads the grace marker (`[MapShell] handoff grace: ended by
# <cause>`): a grace that EXPIRED although Haven was away for less than the
# grace minus a margin is a product failure. "Away" is measured from just
# before the thumbnail tap to MainActivity seen resumed — an upper bound, since
# the grace starts at the pause uCrop causes after that tap — so a slow runner
# that sees uCrop late can only lengthen it, never fake an early expiry.
#
# Verdicts (one `::error::` line names the round and the selector):
#   0  the drive passed and every round it armed was played and recorded
#   1  product: a known wrong picker (DocumentsUI, the GET_CONTENT alias, the
#      Play services picker), Haven's own "isn't responding" or "keeps
#      stopping" dialog holding the picker's focus, Haven staying in front
#      instead of opening uCrop, uCrop never returned, the grace expired early,
#      or the drive failed or hung past HAVEN_DRIVE_TIMEOUT (124/137) while
#      the sidecar was fine and the device was still there
#   2  harness: a screen or an activity the selectors do not know, a system
#      picker whose window never took input focus or that ignored the BACK
#      it was sent while it held focus (nothing Haven decides; Haven not
#      resuming after the picker DID leave the front is product, 1), the marker
#      sequence broken, the pause branch never taken (the precondition unmet),
#      a round run-as could not record on the device, a passing drive that
#      never reported its rounds, the gallery fixtures not seeded although
#      the device answered (a push or query it refused, or a media store that
#      never listed them), or
#      run-single-avd-scenario.sh refusing its configuration (its rc 2)
#   3  infrastructure: no device, error dialogs that could not be hidden, a
#      process the boot left in an error state that CLOSE_SYSTEM_DIALOGS did
#      not clear, the device gone when the drive ended, no
#      answer while the gallery was seeded, shared storage that never
#      attached, or another process's "isn't responding" or "keeps stopping"
#      dialog holding the picker's or uCrop's focus — re-run
# A sidecar failure reds the lane even when the drive passed; when the drive
# failed too, the verdict line says so, since that failure may be the product's.
#
# System error dialogs are hidden first (rc 3 unless the setting reads back),
# as the release launch gate hides them: another process's "isn't responding"
# dialog on a slow emulator would take the input focus the picker and uCrop
# need. With no dialog to show, the system kills a foreground app that stops
# responding (AOSP AppErrors.handleShowAnrUi), so Haven's own ANR still ends
# the drive, red; the dialog verdicts above remain for a dialog shown anyway.
# The setting stops only dialogs decided after it, so one the boot decided
# first is then waited out as the launch gate does (pp_settle_errors).
#
# The sidecar log (/tmp/photo-sidecar.log) is fixed vocabulary: round
# numbers, selector names, cause and class words, seconds (`focus=<s>s` is
# how long the picker took from resumed to holding input focus), and after a
# failed round `events=[...]`, photo-picker-lib.sh's PP_TRACE. It passes the log-privacy
# gate before it is echoed, and the workflow scans it again before upload.
#
# Usage:
#   run-photo-ui-scenario.sh <integration_test target>   env as run-single-avd-scenario.sh
#   run-photo-ui-scenario.sh --self-test

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR="${script_dir}"

# shellcheck source=tooling/e2e/ci/logscan-gate.sh
source "${SCRIPT_DIR}/logscan-gate.sh"
# shellcheck source=tooling/e2e/ci/photo-picker-lib.sh
source "${SCRIPT_DIR}/photo-picker-lib.sh"

readonly DEVICE='emulator-5554'
readonly SINGLE_AVD="${SCRIPT_DIR}/run-single-avd-scenario.sh"
# The paths are fixed in a lane; the self-test moves them into its sandbox, so
# it shares no file with another runner's self-test run beside it.
readonly NEEDLE_DIR="${PHOTO_UI_NEEDLE_DIR:-/tmp/haven-soak/needles}"
readonly LOGCAT="${PHOTO_UI_LOGCAT:-/tmp/adb-logcat.log}"
readonly SIDECAR_LOG="${PHOTO_UI_SIDECAR_LOG:-/tmp/photo-sidecar.log}"
readonly WORK="${PHOTO_UI_WORK:-/tmp/photo-ui}"
readonly STOP="${WORK}/stop"
readonly WATCH_VERDICT="${WORK}/verdict"
readonly LOGSCAN_REPORT="${WORK}-logscan.ndjson"
readonly DEVICE_SECS=60
readonly ADB_STATE_SECS=10
readonly MARKER_POLL_SECS=1
readonly GRACE_MARKER_SECS="${PHOTO_UI_GRACE_MARKER_SECS:-10}"
readonly JOIN_SECS="${PHOTO_UI_JOIN_SECS:-30}"
# Mirrors haven/lib/src/services/system_activity_excursions.dart's
# kSystemActivityHandoffGrace; the self-test pins the two together.
readonly GRACE_SECS=20
# The self-test shrinks the margin so a few seconds of "uCrop seen late" can
# stand for the real thing; no lane sets it.
readonly GRACE_MARGIN_SECS="${PHOTO_UI_GRACE_MARGIN_SECS:-5}"
readonly ARM_RE='\[pp\] ARM round=[0-9]+ act=(pick:[0-9]+|cancel)'
readonly END_RE='\[pp\] END rounds=[0-9]+'
readonly PAUSE_MARKER='[MapShell] pause: background handoff branch'
# Under files/, the directory run-as starts in plus the one the target's
# getApplicationSupportDirectory() (Context.getFilesDir) names; the self-test
# pins it to the target's _kRecordedFile.
readonly RECORDED_NAME='pp_recorded_'
readonly GRACE_RE='\[MapShell\] handoff grace: ended by (resumed|expired|superseded|detached|disposed)'

say() { echo "[photo-ui] $*"; }

# The library's hook: a round is abandoned once the drive has ended.
pp_hook_alive() { [[ ! -e "${STOP}" ]]; }

record() { printf '%s\n' "$*" >> "${SIDECAR_LOG}"; }

# class_word <rc> — a verdict class in the sidecar log's words.
class_word() {
  case "$1" in 1) echo product ;; 2) echo harness ;; 3) echo infrastructure ;; *) echo "rc$1" ;; esac
}

# watch_verdict <rc> <message> — the sidecar's verdict, for the main shell.
watch_verdict() { printf '%s\t%s\n' "$1" "$2" > "${WATCH_VERDICT}"; }

# next_marker <offset> — "<absolute byte offset>\t<marker>" of the first ARM
# or END marker at or after <offset>, or nothing.
next_marker() {
  local hit
  hit="$(tail -c +"$(( $1 + 1 ))" "${LOGCAT}" 2>/dev/null | grep -aobE "${ARM_RE}|${END_RE}" | head -n 1 || true)"
  [[ -n "${hit}" ]] || return 0
  printf '%s\t%s\n' "$(( $1 + ${hit%%:*} ))" "${hit#*:}"
}

since_has() { # <offset> <fixed string>
  tail -c +"$(( $1 + 1 ))" "${LOGCAT}" 2>/dev/null | grep -aqF -- "$2"
}

# grace_cause <offset> — the cause the grace marker names after <offset>,
# waited for briefly (it is printed as the resume reaches Dart).
grace_cause() {
  local deadline cause
  deadline=$(( SECONDS + GRACE_MARKER_SECS ))
  while (( SECONDS < deadline )); do
    cause="$(tail -c +"$(( $1 + 1 ))" "${LOGCAT}" 2>/dev/null | grep -aoE "${GRACE_RE}" | head -n 1 | sed -E 's/.* ended by //' || true)"
    if [[ -n "${cause}" ]]; then printf '%s' "${cause}"; return 0; fi
    sleep 1
  done
  printf 'none'
}

# play_round <offset> <round> <act> — one armed round; 0 or a verdict class.
play_round() {
  local offset="$1" round="$2" act="$3" index=0 kind=pick rc=0 pause=no cause=-
  if [[ "${act}" == cancel ]]; then kind=cancel; else index="${act#pick:}"; fi
  pp_round "${DEVICE}" "${WORK}/priv" "${kind}" "${index}" "${API_LEVEL}" || rc=$?
  if (( rc == 4 )); then
    record "round=${round} act=${kind} aborted: the drive ended mid-round"
    return 4
  fi
  if (( rc != 0 )); then
    record "round=${round} act=${kind} picker=${PP_PICKER} ucrop=${PP_UCROP} failed class=$(class_word "${rc}") focus=${PP_FOCUS_WAIT}s events=[${PP_TRACE}]"
    watch_verdict "${rc}" "round ${round} (${kind}): ${PP_MSG}"
    return "${rc}"
  fi
  if since_has "${offset}" "${PAUSE_MARKER}"; then pause=yes; fi
  if [[ "${kind}" == pick ]]; then
    cause="$(grace_cause "${offset}")"
    record "round=${round} act=pick picker=${PP_PICKER} ucrop=${PP_UCROP} pause=${pause} grace=${cause} dwell=${PP_DWELL}s focus=${PP_FOCUS_WAIT}s"
    if [[ "${pause}" == no ]]; then
      watch_verdict 2 "round ${round} (pick): MapShell never took its Android pause branch between the ARM and the return, so root cause A's precondition (background sharing on at the pause) was not exercised"
      rc=2
    elif [[ "${cause}" == expired ]] && (( PP_DWELL < GRACE_SECS - GRACE_MARGIN_SECS )); then
      watch_verdict 1 "round ${round} (pick): the excursion grace expired though Haven was away for at most ${PP_DWELL} s of its ${GRACE_SECS} s"
      rc=1
    fi
  else
    record "round=${round} act=cancel picker=${PP_PICKER} pause=${pause} focus=${PP_FOCUS_WAIT}s"
  fi
  # Haven is back and the round is recorded: only now may the drive go on.
  # It is let go whatever the verdict, so its own checks of the round run.
  if ! timeout "${PP_ADB_SECS}" adb -s "${DEVICE}" shell run-as "${PP_PKG}" touch "files/${RECORDED_NAME}${round}" >/dev/null 2>&1 \
     && (( rc == 0 )); then
    watch_verdict 2 "round ${round}: run-as could not record the round on the device, so the drive cannot go on (the lane needs a debug build)"
    rc=2
  fi
  return "${rc}"
}

# watch — the sidecar, in the background: the rounds in marker order until the
# main shell touches STOP. Its verdict is the file it writes.
watch() {
  local offset=0 expect=0 played=0 hit at marker round act rc reported=-1 stopped
  watch_verdict 0 ''
  # After STOP it still reads what the drive wrote before it ended (its END
  # marker above all); a round armed then is abandoned by pp_hook_alive. STOP
  # is seen before the read, since the drive's last line can land between an
  # empty read and STOP.
  while :; do
    stopped=0
    [[ ! -e "${STOP}" ]] || stopped=1
    hit="$(next_marker "${offset}")"
    if [[ -z "${hit}" ]]; then
      (( ! stopped )) || break
      sleep "${MARKER_POLL_SECS}"
      continue
    fi
    at="${hit%%$'\t'*}"; marker="${hit#*$'\t'}"
    offset=$(( at + ${#marker} ))
    if [[ "${marker}" == *' END rounds='* ]]; then
      reported="${marker##*=}"
      record "end rounds=${reported} played=${played}"
      continue
    fi
    round="$(sed -E 's/.*round=([0-9]+) .*/\1/' <<<"${marker}")"
    act="${marker##*act=}"
    # A drive retried after a connect flake starts again at round 0.
    if (( round == 0 && expect > 0 )); then
      record "drive restarted: rounds counted again from 0"
      expect=0; played=0; reported=-1
      watch_verdict 0 ''
    fi
    if (( round != expect )); then
      watch_verdict 2 "the marker sequence broke: round ${round} was armed where round ${expect} was due"
      return 0
    fi
    rc=0
    play_round "${at}" "${round}" "${act}" || rc=$?
    (( rc == 0 )) || return 0
    expect=$(( expect + 1 )); played=$(( played + 1 ))
    printf '%s %s\n' "${played}" "${reported}" > "${WORK}/played"
  done
  printf '%s %s\n' "${played}" "${reported}" > "${WORK}/played"
}

RC=''
MSG=''
WATCH_PID=''

# drive_verdict <rc> — DRIVE_CLASS and DRIVE_WHY for run-single-avd-scenario.sh's
# exit: 2 is its own refusal of the configuration, 124/137 the drive killed at
# HAVEN_DRIVE_TIMEOUT, anything else a failed drive.
drive_verdict() {
  case "$1" in
    2) DRIVE_CLASS=2; DRIVE_WHY="run-single-avd-scenario.sh refused its configuration (rc 2)" ;;
    124|137) DRIVE_CLASS=1; DRIVE_WHY="the drive hung past HAVEN_DRIVE_TIMEOUT and was killed (rc $1): product unless its log shows the runner or the device stalled" ;;
    *) DRIVE_CLASS=1; DRIVE_WHY="the drive failed (rc $1)" ;;
  esac
}

finish() {
  local gate_rc=0 deadline
  if [[ -n "${WATCH_PID}" ]]; then
    touch "${STOP}"
    deadline=$(( SECONDS + JOIN_SECS ))
    while (( SECONDS < deadline )) && kill -0 "${WATCH_PID}" 2>/dev/null; do
      sleep 1
    done
    kill "${WATCH_PID}" 2>/dev/null || true
  fi
  pp_clear_gallery "${DEVICE}"
  [[ -n "${RC}" ]] || { RC=2; MSG="the runner stopped unexpectedly"; }
  record "verdict rc=${RC}"
  record "reason: ${MSG}"
  logscan_gate host "${NEEDLE_DIR}" -- --sink "diag=${SIDECAR_LOG}" --report "${LOGSCAN_REPORT}" || gate_rc=$?
  rm -rf "${WORK}/priv"
  if (( gate_rc != 0 )); then
    echo "::error::photo-ui: the log-privacy gate refused the sidecar log (rc ${gate_rc}); it is not shown."
    exit $(( RC == 0 ? 1 : RC ))
  fi
  echo "--- photo sidecar ---"
  cat "${SIDECAR_LOG}"
  if (( RC != 0 )); then
    echo "::error::photo-ui rc ${RC}: ${MSG}"
  fi
  exit "${RC}"
}

main() {
  local target="${1:-}" drive_rc=0 wrc wmsg played=0 reported=-1
  [[ -n "${target}" ]] || { echo "usage: $0 <integration_test target>" >&2; exit 2; }
  rm -rf "${WORK}" "${LOGCAT}"
  mkdir -p "${WORK}"
  mkdir -m 0700 "${WORK}/priv"
  : > "${SIDECAR_LOG}"
  trap finish EXIT
  if ! timeout "${DEVICE_SECS}" adb -s "${DEVICE}" wait-for-device; then
    RC=3; MSG="${DEVICE} did not come online within ${DEVICE_SECS} s"; exit 0
  fi
  API_LEVEL="$(adb -s "${DEVICE}" shell getprop ro.build.version.sdk 2>/dev/null | tr -d '\r' || true)"
  if [[ ! "${API_LEVEL}" =~ ^[0-9]+$ ]]; then
    RC=3; MSG="ro.build.version.sdk did not read as a number"; exit 0
  fi
  adb -s "${DEVICE}" shell settings put global hide_error_dialogs 1 >/dev/null 2>&1 || true
  if [[ "$(adb -s "${DEVICE}" shell settings get global hide_error_dialogs 2>/dev/null | tr -d '\r' || true)" != 1 ]]; then
    RC=3; MSG="hide_error_dialogs did not read back 1"; exit 0
  fi
  # A dialog the boot decided before the setting applied stays over the picker
  # the rounds read (job 137248796793: another app's "isn't responding" dialog
  # held input focus for the picker's whole 60 s); the launch gate waits it out
  # the same way.
  pp_settle_errors "${DEVICE}" "${WORK}/priv" || { RC=$?; MSG="${PP_MSG}"; exit 0; }
  record "errors=settled"
  pp_seed_gallery "${DEVICE}" "${WORK}/priv" || { RC=$?; MSG="gallery (API ${API_LEVEL}): ${PP_MSG}"; exit 0; }
  record "api=${API_LEVEL} gallery=seeded"
  watch &
  WATCH_PID=$!
  bash "${SINGLE_AVD}" "${target}" || drive_rc=$?
  touch "${STOP}"
  local deadline
  deadline=$(( SECONDS + JOIN_SECS ))
  while (( SECONDS < deadline )) && kill -0 "${WATCH_PID}" 2>/dev/null; do
    sleep 1
  done
  if kill -0 "${WATCH_PID}" 2>/dev/null; then
    kill "${WATCH_PID}" 2>/dev/null || true
    RC=2; MSG="the sidecar did not stop within ${JOIN_SECS} s of the drive's end"; exit 0
  fi
  WATCH_PID=''
  IFS=$'\t' read -r wrc wmsg < "${WATCH_VERDICT}" || { wrc=2; wmsg="the sidecar left no verdict"; }
  [[ ! -f "${WORK}/played" ]] || read -r played reported < "${WORK}/played"
  record "drive rc=${drive_rc} sidecar rc=${wrc} rounds played=${played}"
  local state=''
  if (( drive_rc != 0 )); then
    drive_verdict "${drive_rc}"
    state="$(timeout "${ADB_STATE_SECS}" adb -s "${DEVICE}" get-state 2>/dev/null | tr -d '\r' || true)"
  fi
  if (( drive_rc != 0 )) && [[ "${state}" != device ]]; then
    RC=3; MSG="${DEVICE} was gone when the drive ended (rc ${drive_rc}): infrastructure, re-run the job"
  elif (( wrc != 0 )); then
    RC="${wrc}"
    if (( drive_rc == 0 )); then
      MSG="${wmsg} (the drive itself passed: a sidecar failure is red)"
    else
      MSG="${wmsg}; the drive also failed — ${DRIVE_WHY}: read its log, a failure the sidecar's did not cause is product"
    fi
  elif (( drive_rc != 0 )); then
    RC="${DRIVE_CLASS}"; MSG="${DRIVE_WHY}, with the sidecar's ${played} round(s) all played"
  elif [[ "${reported}" != "${played}" ]]; then
    RC=2; MSG="the drive passed but reported ${reported/#-1/no} round count where the sidecar played ${played}"
  else
    RC=0; MSG="every round played"
  fi
  exit 0
}

# ---------------------------------------------------------------------------
# Self-test: a copy of this directory in a sandbox, a stub adb that plays the
# picker and uCrop, and a stub run-single-avd-scenario.sh that plays the Dart
# side — markers in a logcat file, the tap that opens the picker, and the waits
# for Haven to be back and for the sidecar's record of the round. Bounds are
# shrunk through the PHOTO_* overrides only.
# ---------------------------------------------------------------------------
readonly SELF_TEST_FIXTURES=72

_st_stub_adb() { # <bin dir>
  cat > "$1/adb" <<'STUB'
#!/usr/bin/env bash
S="${STUB}"
printf '%s\n' "$*" >> "${S}/calls"
[[ "${1:-}" == -s ]] && shift 2
PKG=com.oblivioustech.haven
get() { cat "${S}/$1" 2>/dev/null || true; }
# Every change of screen is a new window: its focus starts over (focus_of).
put() { printf '%s\n' "$2" > "${S}/$1"; [[ "$1" != screen ]] || printf '%s\n' "$(( $(get gen) + 1 ))" > "${S}/gen"; }
log() { printf '11-16 12:00:00.000  4242  4242 I flutter : %s\n' "$1" >> "${PHOTO_UI_LOGCAT}"; }
pnode() { printf '<node index="0" text="" resource-id="%s" class="android.widget.ImageView" package="%s" content-desc="%s" clickable="true" enabled="true" bounds="%s"/>' "$2" "$1" "$3" "$4"; }
# The screen as the host sees it. STUB_UCROP_LATE_SECS keeps the picker in
# front that long after the thumbnail tap, as a slow device would.
seen() {
  local scr; scr="$(get screen)"
  if [[ "${scr}" == ucrop && -n "$(get ucrop_at)" ]] && (( $(date +%s) < $(get ucrop_at) )); then scr=picker; fi
  printf '%s' "${scr}"
}
screen_xml() {
  local root="${PKG}" body=''
  case "$(seen)" in
    picker) root=com.google.android.providers.media.module
      local rid="${root}:id/icon_thumbnail"
      [[ -z "${STUB_PICKER_UNKNOWN:-}" ]] || rid="${root}:id/unknown_grid_item"
      body="$(pnode "${root}" "${rid}" 'Taken on Nov 16, 2026 12:01' '[40,600][340,900]')$(pnode "${root}" "${rid}" 'Taken on Nov 15, 2026 09:30' '[400,600][700,900]')" ;;
    ucrop) body="$(pnode "${PKG}" "${PKG}:id/menu_crop" 'Crop' '[900,100][1040,240]')" ;;
    *) body="$(pnode "${PKG}" '' 'Edit Photo' '[280,500][560,560]')" ;;
  esac
  printf "<?xml version='1.0' encoding='UTF-8' standalone='yes' ?><hierarchy rotation=\"0\"><node index=\"0\" text=\"\" resource-id=\"\" class=\"android.widget.FrameLayout\" package=\"%s\" content-desc=\"\" bounds=\"[0,0][1080,2400]\">%s</node></hierarchy>" "${root}" "${body}"
}
component_of() {
  case "$1" in
    picker) echo 'com.google.android.providers.media.module/com.android.providers.media.photopicker.PhotoPickerActivity' ;;
    ucrop) echo "${PKG}/com.yalantis.ucrop.UCropActivity" ;;
    home) echo 'com.android.launcher3/com.android.launcher3.uioverrides.QuickstepLauncher' ;;
    *) echo "${PKG}/${PKG}.MainActivity" ;;
  esac
}
resumed() { printf '  topResumedActivity=ActivityRecord{1 u0 %s t1}\n' "$(component_of "$(seen)")"; }
# The activity manager's events, as `logcat -b events -v epoch` prints them.
ev() { # <create|finish> <screen>
  if [[ "$1" == create ]]; then
    printf '1000.250   500   600 I wm_create_activity: [0,77,1,%s,NULL,NULL,NULL,0]\n' "$(component_of "$2")"
  else
    printf '1000.500   500   600 I wm_finish_activity: [0,77,1,%s,app-request]\n' "$(component_of "$2")"
  fi >> "${S}/events.log"
}
# Input focus as the device has it: the picker and uCrop are resumed before
# their windows can hold focus, so the first STUB_FOCUS_LAG `dumpsys input`
# reads of each new one see no focused window (STUB_NEVER_FOCUSED=<screen>:
# none ever does). uCrop seen late is a new window when it is seen.
focus_of() { # <advance: 1 on a dumpsys read>
  local scr key reads; scr="$(seen)"
  case "${scr}" in picker|ucrop) ;; *) component_of "${scr}"; return ;; esac
  key="$(get gen):${scr}"
  [[ "$(get fkey)" == "${key}" ]] || { put fkey "${key}"; put freads 0; }
  reads="$(get freads)"
  if (( $1 )); then reads=$(( reads + 1 )); put freads "${reads}"; fi
  if [[ "${STUB_NEVER_FOCUSED:-}" == "${scr}" ]] || (( reads <= ${STUB_FOCUS_LAG:-1} )); then echo none; return; fi
  component_of "${scr}"
}
# STUB_ANR=systemui: System UI stops responding as the picker opens;
# STUB_ANR=ours: Haven stops responding to uCrop's crop tap. The system shows
# the process's "isn't responding" dialog, which takes the focus from every
# window, or, with error dialogs hidden, kills the process (returns 1).
anr() { # <process>
  printf '1000.750   500   600 I am_anr  : [0,812,%s,551144,Input dispatching timed out]\n' "$1" >> "${S}/events.log"
  [[ ! -e "${S}/hide" ]] || return 1
  printf 'Application Not Responding: %s\n' "$1" > "${S}/dialog"
}
# STUB_FOCUS_WINDOW=<title>: a window that is no activity's (an error dialog)
# holds the focus the picker or uCrop does not.
focus_dump() {
  local f
  if [[ "${STUB_ANR:-}" == systemui && "$(seen)" == picker && ! -e "${S}/anr" ]]; then
    : > "${S}/anr"; anr com.android.systemui || true
  fi
  f="$(focus_of 1)"
  echo 'Input Dispatcher State:'
  if [[ -s "${S}/dialog" ]]; then printf "  FocusedWindows:\n    displayId=0, name='5a1 %s'\n" "$(cat "${S}/dialog")"
  elif [[ "${f}" == none && -n "${STUB_FOCUS_WINDOW:-}" ]]; then printf "  FocusedWindows:\n    displayId=0, name='5a1 %s'\n" "${STUB_FOCUS_WINDOW}"
  elif [[ "${f}" == none ]]; then echo '  FocusedWindows: <none>'
  else printf "  FocusedWindows:\n    displayId=0, name='4f2e1c0 %s'\n" "${f}"; fi
}
# An input to the picker or uCrop while its window does not hold focus:
# dropped, as the dispatcher drops a key no window took in time, and
# recorded so the self-test fails on it.
unfocused() {
  case "$(seen)" in picker|ucrop) ;; *) return 1 ;; esac
  [[ "$(focus_of 0)" == none || -s "${S}/dialog" ]] || return 1
  printf '%s\n' "$1" >> "${S}/unfocused"
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
  get-state) [[ -z "${STUB_DEVICE_LOST:-}" ]] || exit 1; echo device; exit 0 ;;
  push) media_push "$2" "$3" ;;
  exec-out) screen_xml; exit 0 ;;
  shell) shift ;;
  *) exit 9 ;;
esac
cmd="$*"
if [[ "${cmd}" == "content query "* ]]; then media_query "$@"; fi
if [[ "${cmd}" == "content delete "* ]]; then
  (( $# == 1 )) && [[ "${cmd}" == "content delete --uri content://media/external/images/media --where \"_display_name LIKE 'haven-gate-%'\"" ]] && rm -f "${S}"/media.haven-gate-*.png
  exit 0
fi
case "${cmd}" in
  "getprop ro.build.version.sdk") echo "${STUB_API:-34}" ;;
  # The activity manager's processes, filtered as the runner asks. STUB_BOOT_ANR:
  # the boot left System UI marked not responding, until CLOSE_SYSTEM_DIALOGS
  # (never, with STUB_BOOT_ANR_STUCK) dismisses its dialog.
  "dumpsys activity processes | grep -E '^ACTIVITY MANAGER RUNNING PROCESSES|^  [*](APP|PERS)[*] UID |mCrashing='")
    echo 'ACTIVITY MANAGER RUNNING PROCESSES (dumpsys activity processes)'
    echo '  *PERS* UID 1000 ProcessRecord{5e1a 512:system/1000}'
    echo '  *PERS* UID 10123 ProcessRecord{7c0d 900:com.android.systemui/u0a123}'
    if [[ -n "${STUB_BOOT_ANR:-}" && ! -e "${S}/boot_anr_closed" ]]; then
      echo '     mCrashing=false null mNotResponding=true [com.android.server.am.AppNotRespondingDialog@1f2e] bad=false'
    fi ;;
  "am broadcast -a android.intent.action.CLOSE_SYSTEM_DIALOGS") [[ -n "${STUB_BOOT_ANR_STUCK:-}" ]] || : > "${S}/boot_anr_closed" ;;
  "settings put global hide_error_dialogs 1") [[ -n "${STUB_HIDE_REFUSED:-}" ]] || : > "${S}/hide" ;;
  "settings get global hide_error_dialogs") [[ -e "${S}/hide" ]] && echo 1 || echo 0 ;;
  "run-as ${PKG} touch files/pp_recorded_"*) [[ -z "${STUB_RUNAS_REFUSED:-}" ]] || exit 1
    [[ "$4" =~ ^files/pp_recorded_[0-9]+$ ]] || exit 9
    mkdir -p "${S}/files"; : > "${S}/$4" ;;
  "touch -t "*|"content call "*|"rm -f "*) : ;;
  # The picker finishes on the tap and Haven is resumed until it starts uCrop:
  # the first STUB_PICK_BOUNCE activity reads after the tap find MainActivity.
  "dumpsys activity activities")
    if [[ "$(get bounce)" =~ ^[1-9] ]]; then put bounce $(( $(get bounce) - 1 )); component_of main | sed 's/^/  topResumedActivity=ActivityRecord{1 u0 /; s/$/ t1}/'
    else resumed; fi ;;
  "date +%s && logcat -d -b events -v epoch") echo 1000; cat "${S}/events.log" 2>/dev/null ;;
  "dumpsys input") focus_dump ;;
  "input keyevent 4") ! unfocused BACK || exit 0
    [[ "$(get screen)" == picker && -z "${STUB_BACK_IGNORED:-}" ]] || exit 0
    if [[ -n "${STUB_CANCEL_STRANDED:-}" ]]; then put screen home; else put screen main; fi ;;
  "input tap "*) read -r _ _ x y <<<"${cmd}"
    ! unfocused "tap ${x} ${y}" || exit 0
    case "$(seen)" in
      picker) (( y >= 600 && y <= 900 )) || exit 0
        [[ -n "${STUB_NO_PAUSE:-}" ]] || log '[MapShell] pause: background handoff branch'
        put ucrop_at $(( $(date +%s) + ${STUB_UCROP_LATE_SECS:-0} ))
        ev finish picker; ev create ucrop; put bounce "${STUB_PICK_BOUNCE:-1}"
        put screen ucrop ;;
      ucrop) (( x >= 900 )) || exit 0
        [[ -n "${STUB_UCROP_NEVER:-}" ]] && exit 0
        if [[ "${STUB_ANR:-}" == ours ]]; then anr "${PKG}" || { : > "${S}/dead"; put screen home; }; exit 0; fi
        ev finish ucrop
        put screen main
        log "[MapShell] handoff grace: ended by ${STUB_GRACE:-resumed}" ;;
    esac ;;
  *) exit 9 ;;
esac
exit 0
STUB
  chmod +x "$1/adb"
}

# The Dart side: arms each round in turn, opens the picker as the app's tap
# would, waits for Haven to be back and then for the sidecar's record of the
# round before arming the next or printing its END. STUB/files is the app's
# files directory, which a restarted drive's fresh install empties.
_st_stub_drive() { # <ci dir>
  cat > "$1/run-single-avd-scenario.sh" <<'DRIVE'
#!/usr/bin/env bash
S="${STUB}"
log() { printf '11-16 12:00:00.000  4242  4242 I flutter : %s\n' "$1" >> "${PHOTO_UI_LOGCAT}"; }
show_picker() { # the tap on Edit Photo: a new picker window
  echo picker > "${S}/screen"; echo $(( $(cat "${S}/gen" 2>/dev/null || echo 0) + 1 )) > "${S}/gen"
}
back() { # Haven resumed again, within a bound; failed at once once the sidecar has, as the app would stay away
  local deadline=$(( SECONDS + 20 )) vrc
  while (( SECONDS < deadline )); do
    [[ ! -e "${S}/dead" ]] || return 1  # the app process killed: the drive loses it at once
    [[ "$(cat "${S}/screen" 2>/dev/null)" == main ]] && return 0
    vrc="$(cut -f1 "${PHOTO_UI_WORK}/verdict" 2>/dev/null || true)"
    [[ -z "${vrc}" || "${vrc}" == 0 ]] || return 1
    sleep 0.1
  done
  return 1
}
recorded() { # the sidecar's record of round $1, within a bound
  local deadline=$(( SECONDS + 20 ))
  while (( SECONDS < deadline )); do
    [[ -e "${S}/files/pp_recorded_$1" ]] && return 0
    sleep 0.1
  done
  return 1
}
: > "${PHOTO_UI_LOGCAT}"
log 'unrelated app line naming no marker'
n=0
for act in ${STUB_ROUNDS:-cancel pick:0 pick:1}; do
  if [[ -n "${STUB_RESTART:-}" && "${n}" == 1 && ! -f "${S}/restarted" ]]; then
    touch "${S}/restarted"; rm -rf "${S}/files"; n=0
    log '[pp] ARM round=0 act=cancel'; show_picker; back || exit 1; recorded 0 || exit 1; n=1
  fi
  log "[pp] ARM round=$(( n + ${STUB_ROUND_SKEW:-0} )) act=${act}"
  show_picker
  back || exit 1
  recorded "${n}" || exit 1
  n=$(( n + 1 ))
done
[[ -n "${STUB_NO_END:-}" ]] || log "[pp] END rounds=${n}"
exit "${STUB_DRIVE_RC:-0}"
DRIVE
}

self_test() {
  local tmp fails=0 ran=0 rc out
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN
  mkdir -p "${tmp}/bin" "${tmp}/ci"
  cp -R "${SCRIPT_DIR}/." "${tmp}/ci/"
  _st_stub_adb "${tmp}/bin"
  _st_stub_drive "${tmp}/ci"

  _scenario() { # <label> <want rc> [VAR=value...]
    local label="$1" want_rc="$2"
    shift 2
    ran=$(( ran + 1 ))
    rm -rf "${tmp}/stub" "${tmp}/work" "${tmp}/seal.argv"
    mkdir -p "${tmp}/stub"
    echo main > "${tmp}/stub/screen"
    rc=0
    out="$(env PATH="${tmp}/bin:${PATH}" STUB="${tmp}/stub" \
      PHOTO_UI_LOGCAT="${tmp}/stub/logcat.log" PHOTO_UI_SIDECAR_LOG="${tmp}/stub/sidecar.log" PHOTO_UI_WORK="${tmp}/work" \
      PHOTO_UI_NEEDLE_DIR="${tmp}/needles" \
      PHOTO_SETTLE_SECS=2 PHOTO_STORAGE_SECS=2 PHOTO_MEDIA_SECS=2 PHOTO_PICKER_SECS=3 PHOTO_UCROP_SECS=3 PHOTO_RETURN_SECS=3 PHOTO_UI_GRACE_MARKER_SECS=2 PHOTO_UI_JOIN_SECS=10 \
      HAVEN_LOGSCAN=true HAVEN_LOGSCAN_BIN="${LOGSCAN_FAKE_BIN}" FAKE_SEAL_ARGV="${tmp}/seal.argv" \
      GITHUB_RUN_ID="photo-ui-self-test-$$-${ran}" GITHUB_RUN_ATTEMPT=1 "$@" \
      bash "${tmp}/ci/run-photo-ui-scenario.sh" integration_test/e2e/e2e_profile_ui_photo.dart 2>&1)" || rc=$?
    if (( rc == want_rc )); then printf '  PASS %s\n' "${label}"; else
      printf '  FAIL %s (want rc %s, got %s)\n%s\n' "${label}" "${want_rc}" "${rc}" "${out}" >&2; fails=1; fi
    if grep -qF 'aken on Nov 1' <<<"${out}" || grep -qF 'aken on Nov 1' "${tmp}/stub/sidecar.log" 2>/dev/null; then
      printf '  FAIL %s: a picker thumbnail description reached the transcript or the sidecar log\n' "${label}" >&2; fails=1
    fi
    if compgen -G "${tmp}/stub/media.haven-gate-*" >/dev/null; then
      printf '  FAIL %s: the gallery fixtures were left on the device\n' "${label}" >&2; fails=1
    fi
    if [[ -s "${tmp}/stub/unfocused" ]]; then
      printf '  FAIL %s: an input was sent to the picker or uCrop before its window held focus: %s\n' "${label}" "$(tr '\n' ' ' < "${tmp}/stub/unfocused")" >&2; fails=1
    fi
  }
  _has() { # <label> <fixed string>
    ran=$(( ran + 1 ))
    if grep -qF -- "$2" <<<"${out}"; then printf '  PASS %s\n' "$1"; else
      printf '  FAIL %s: transcript lacks "%s"\n%s\n' "$1" "$2" "${out}" >&2; fails=1; fi
  }

  echo "run-photo-ui-scenario.sh --self-test"
  _scenario "a cancel and two picks, each played, recorded and counted, pass" 0
  _has "…each pick recorded with its selectors, the pause branch and the grace cause" "round=1 act=pick picker=photopicker-rid ucrop=rid pause=yes grace=resumed"
  _has "…the cancel round recorded without a pick" "round=0 act=cancel picker=- pause=no focus="
  _has "…and the count the target reported matches" "end rounds=3 played=3"
  # The sidecar log is echoed only after the gate, and the gate is told nothing
  # the log does not carry.
  ran=$(( ran + 1 ))
  local gate_at echo_at
  gate_at="$(grep -n '^scan-logs: ' <<<"${out}" | head -n 1 | cut -d: -f1)"
  echo_at="$(grep -n -- '--- photo sidecar ---' <<<"${out}" | head -n 1 | cut -d: -f1)"
  if [[ -n "${gate_at}" && -n "${echo_at}" ]] && (( gate_at < echo_at )); then
    echo '  PASS _case "the sidecar log is echoed only after the log-privacy gate"'
  else
    echo "  FAIL the sidecar log is echoed only after the log-privacy gate (gate line ${gate_at:-none}, echo line ${echo_at:-none})" >&2; fails=1
  fi
  _scenario "a pick round without MapShell's pause branch is a harness failure (precondition unmet)" 2 STUB_NO_PAUSE=1
  _has "…naming the precondition" "MapShell never took its Android pause branch"
  _scenario "a grace that expired while uCrop was in front briefly is a product failure" 1 STUB_GRACE=expired
  _has "…naming the dwell" "the excursion grace expired though Haven was away for at most"
  # A slow device: uCrop seen 6 s after the thumbnail tap. The dwell runs from
  # the tap, so it covers that wait and an expired grace is not called early
  # (the margin is shrunk to a 3 s threshold to stand for the real 15 s).
  _scenario "uCrop seen late after the tap: an expired grace is not an early expiry" 0 STUB_GRACE=expired \
    STUB_UCROP_LATE_SECS=6 PHOTO_UCROP_SECS=20 PHOTO_UI_GRACE_MARGIN_SECS=17
  _has "…and the round records the expired grace with the dwell from the tap" "grace=expired dwell="
  _scenario "a grace ended by the resume or any other cause passes" 0 STUB_GRACE=superseded
  _scenario "a skipped round number breaks the marker sequence, rc 2" 2 STUB_ROUND_SKEW=1
  _has "…named as such" "the marker sequence broke: round 1 was armed where round 0 was due"
  _scenario "a picker screen no selector knows is a harness failure" 2 STUB_PICKER_UNKNOWN=1
  _has "…listing its resource ids" "rids: unknown_grid_item"
  _scenario "uCrop that never hands Haven back is a product failure" 1 STUB_UCROP_NEVER=1
  _has "…named as such" "uCrop did not return a result"
  _has "…and the sidecar log carries what the activity manager recorded" "events=[-PhotoPickerActivity(app-request) +UCropActivity]"
  # CI run 44503460373 (the release gate): Haven is resumed between the
  # picker's result and uCrop's start, and that read is not Haven back.
  _scenario "Haven resumed between the picker and uCrop is the trip going on" 0 STUB_PICK_BOUNCE=3
  _has "…every pick recorded as played" "round=2 act=pick picker=photopicker-rid ucrop=rid pause=yes"
  _scenario "a drive that fails with every round played keeps the drive's verdict" 1 STUB_DRIVE_RC=1
  _has "…named as the drive's" "the drive failed (rc 1)"
  _scenario "a drive killed at its timeout is a product failure named as a hang" 1 STUB_DRIVE_RC=124
  _has "…named as such" "the drive hung past HAVEN_DRIVE_TIMEOUT and was killed (rc 124)"
  _scenario "the AVD runner refusing its configuration is a harness failure" 2 STUB_DRIVE_RC=2
  _has "…named as such" "run-single-avd-scenario.sh refused its configuration"
  _scenario "a device gone when the drive failed is infrastructure" 3 STUB_DRIVE_RC=1 STUB_DEVICE_LOST=1
  _has "…named as such" "was gone when the drive ended (rc 1)"
  _scenario "a harness verdict beside a failed drive names the drive's failure too" 2 STUB_NO_PAUSE=1 STUB_ROUNDS="cancel pick:0" STUB_DRIVE_RC=1
  _has "…so a product failure under it is not lost" "the drive also failed — the drive failed (rc 1)"
  _scenario "a passing drive whose sidecar failed is red" 1 STUB_GRACE=expired STUB_ROUNDS="cancel pick:0"
  _has "…saying the drive itself passed" "a sidecar failure is red"
  _scenario "a passing drive that never reports its rounds is a harness failure" 2 STUB_NO_END=1
  _scenario "a round run-as cannot record on the device is a harness failure" 2 STUB_RUNAS_REFUSED=1
  _has "…named as such" "run-as could not record the round on the device"
  ran=$(( ran + 1 ))
  if grep -qF 'ARM round=1' "${tmp}/stub/logcat.log"; then
    echo "  FAIL the drive armed round 1 though the sidecar never recorded round 0" >&2; fails=1
  else echo "  PASS …and the drive arms nothing past a round the sidecar has not recorded"; fi
  _scenario "a drive restarted after a connect flake counts its rounds again from 0" 0 STUB_RESTART=1
  _has "…and says so" "drive restarted: rounds counted again from 0"
  # The first device run: the picker was resumed long before its window held
  # input focus, and the BACK sent in that gap was dropped. Every input now
  # waits for the focus (no scenario may send one before it, see _scenario).
  _scenario "a picker and uCrop that take focus late get the BACK and the taps only once they hold it" 0 STUB_FOCUS_LAG=4
  _scenario "a system picker that ignores the BACK it got while focused is a harness verdict, not Haven's" 2 STUB_BACK_IGNORED=1 STUB_ROUNDS=cancel
  _has "…named as such" "the system picker ignored the BACK sent while its window held input focus"
  _has "…and the sidecar log says which class" "round=0 act=cancel picker=- ucrop=- failed class=harness focus="
  _scenario "a picker that left after the BACK without Haven resuming is a product failure" 1 STUB_CANCEL_STRANDED=1 STUB_ROUNDS=cancel
  _has "…named as such" "the cancelled picker left the front but Haven did not resume"
  _has "…and the sidecar log says which class" "failed class=product"
  # CI run 44503460373 (this lane): focus held for 60 s by a window that is no
  # activity's. The system's error dialogs are named by owner, never by title.
  _scenario "Haven's \"isn't responding\" dialog over the picker is a product failure" 1 STUB_NEVER_FOCUSED=picker STUB_ROUNDS=cancel "STUB_FOCUS_WINDOW=Application Not Responding: com.oblivioustech.haven"
  _has "…named as such" "input focus was on Haven's \"isn't responding\" dialog over the picker for 3 s: Haven failed while the picker was open"
  _scenario "System UI's \"isn't responding\" dialog over the picker is infrastructure" 3 STUB_NEVER_FOCUSED=picker STUB_ROUNDS=cancel "STUB_FOCUS_WINDOW=Application Not Responding: com.android.systemui"
  _has "…named as such, the sidecar log classing it" "failed class=infrastructure"
  # Error dialogs are hidden before any round, so another process stopping
  # responding no longer holds the picker's focus; Haven stopping responding
  # is killed instead of covered, and the lane is still red.
  _scenario "error dialogs that cannot be hidden are infrastructure" 3 STUB_HIDE_REFUSED=1
  _has "…named as such" "hide_error_dialogs did not read back 1"
  _scenario "System UI stopping responding as the picker opens takes no focus from it" 0 STUB_ANR=systemui STUB_ROUNDS=cancel
  # A process the boot left not responding decided its dialog before the
  # setting applied: it is waited out, CLOSE_SYSTEM_DIALOGS sent, before the
  # gallery is seeded and any round runs (job 137248796793).
  _scenario "a process the boot left not responding is closed before the first round" 0 STUB_BOOT_ANR=1
  ran=$(( ran + 1 ))
  local close_at seed_at
  close_at="$(grep -n 'CLOSE_SYSTEM_DIALOGS' "${tmp}/stub/calls" | head -n 1 | cut -d: -f1)"
  seed_at="$(grep -n '^-s [^ ]* push ' "${tmp}/stub/calls" | head -n 1 | cut -d: -f1)"
  if [[ -n "${close_at}" && -n "${seed_at}" ]] && (( close_at < seed_at )) && grep -qF 'errors=settled' <<<"${out}"; then
    echo '  PASS …by CLOSE_SYSTEM_DIALOGS, before the gallery is seeded'
  else
    echo "  FAIL …by CLOSE_SYSTEM_DIALOGS, before the gallery is seeded (broadcast line ${close_at:-none}, first push line ${seed_at:-none})" >&2; fails=1
  fi
  _scenario "a process that stays not responding is infrastructure" 3 STUB_BOOT_ANR=1 STUB_BOOT_ANR_STUCK=1
  _has "…naming whose, before any round" "System UI's process held as not responding"
  _scenario "Haven stopping responding to the crop tap is still a product failure" 1 STUB_ANR=ours STUB_ROUNDS=pick:0
  _has "…the drive losing the app" "the drive failed (rc 1)"
  _scenario "a picker whose window never takes focus gets no input and is a harness verdict" 2 STUB_NEVER_FOCUSED=picker STUB_ROUNDS=cancel
  _has "…named as such" "the system picker was resumed but its window never took input focus within 3 s (focus on no window), so no input was sent to it"
  _scenario "uCrop, Haven's own, never taking focus is a product failure" 1 STUB_NEVER_FOCUSED=ucrop STUB_ROUNDS=pick:0
  _has "…named as such" "uCrop, Haven's own activity, was resumed but its window never took input focus"
  # The gallery, seeded right after sys.boot_completed: AOSP sets it before the
  # system user's storage is mounted, and the API-35 launch gate got there first.
  _scenario "shared storage attached only after the gallery is reached is waited for, then seeded" 0 \
    STUB_API=35 STUB_STORAGE_LATE=3 STUB_PENDING_READS=2
  _has "…and recorded as seeded on API 35" "api=35 gallery=seeded"
  _scenario "a media store that answers but never lists the fixtures is a harness failure" 2 STUB_MEDIA_NEVER=1
  _has "…named as such, with the API level" "gallery (API 34): the media store answered but never listed both gallery fixtures"
  _scenario "shared storage that never attaches is infrastructure" 3 STUB_STORAGE_NEVER=1
  _has "…named as such" "the media store had no shared storage attached within 2 s"
  # The constants the Dart target and this runner share, pinned both ways.
  ran=$(( ran + 1 ))
  local repo dart_grace target
  repo="${SCRIPT_DIR}/../../.."
  dart_grace="$(sed -nE 's/^const Duration kSystemActivityHandoffGrace = Duration\(seconds: ([0-9]+)\);/\1/p' "${repo}/haven/lib/src/services/system_activity_excursions.dart")"
  if [[ "${dart_grace}" == "${GRACE_SECS}" ]]; then echo "  PASS GRACE_SECS mirrors kSystemActivityHandoffGrace (${GRACE_SECS} s)"; else
    echo "  FAIL GRACE_SECS (${GRACE_SECS}) != kSystemActivityHandoffGrace (${dart_grace:-unreadable})" >&2; fails=1; fi
  ran=$(( ran + 1 ))
  target="${repo}/haven/integration_test/e2e/e2e_profile_ui_photo.dart"
  local pair name bound got drift=''
  for pair in "Picker ${PP_PICKER_SECS}" "Ucrop ${PP_UCROP_SECS}" "Return ${PP_RETURN_SECS}" "Dump ${PP_DUMP_SECS}" "Adb ${PP_ADB_SECS}"; do
    read -r name bound <<<"${pair}"
    got="$(sed -nE "s/^const int _sidecar${name}Secs = ([0-9]+);/\1/p" "${target}" 2>/dev/null)"
    [[ "${got}" == "${bound}" ]] || drift+=" ${name}(${got:-unreadable}!=${bound})"
  done
  if [[ -z "${drift}" ]]; then echo "  PASS the Dart target's trip bound is built from this lane's photo-picker-lib.sh bounds"; else
    echo "  FAIL the Dart target's mirrored bounds drifted:${drift}" >&2; fails=1; fi
  ran=$(( ran + 1 ))
  got="$(grep -cE "^const String _k(ArmMarker|EndMarker|RecordedFile) " "${target}" 2>/dev/null || true)"
  if [[ "${got}" == 3 ]] && grep -qF "const String _kArmMarker = '[pp] ARM round=';" "${target}" \
     && grep -qF "const String _kEndMarker = '[pp] END rounds=';" "${target}" \
     && grep -qF "const String _kRecordedFile = '${RECORDED_NAME}';" "${target}"; then
    echo "  PASS the Dart target prints the markers this sidecar reads and waits for the file it creates"
  else echo "  FAIL the Dart target's marker or record-file constants are not the ones ARM_RE/END_RE/RECORDED_NAME use" >&2; fails=1; fi

  if (( ran != SELF_TEST_FIXTURES )); then
    echo "SELF-TEST FAIL: ran ${ran} fixture(s), expected ${SELF_TEST_FIXTURES}" >&2
    fails=1
  fi
  if (( fails )); then
    echo "run-photo-ui-scenario.sh --self-test: FAILED" >&2
    return 1
  fi
  echo "run-photo-ui-scenario.sh --self-test: all ${ran} fixtures passed"
}

if [[ "${1:-}" == "--self-test" ]]; then
  self_test
  exit $?
fi
main "$@"
