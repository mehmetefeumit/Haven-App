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
#   asserts the photo, the relays, Bob      records the round, waits for n+1
#   print "[pp] END rounds=<n>"             checks the count
#
# Per pick round the sidecar also requires MapShell's Android pause branch
# marker between the ARM and the return (C6: `[MapShell] pause: background
# handoff branch`) — the precondition of root cause A, true before and after
# the fix — and reads the grace marker (`[MapShell] handoff grace: ended by
# <cause>`): a grace that EXPIRED while uCrop was in front for less than the
# grace minus a margin is a product failure.
#
# Verdicts (one `::error::` line names the round and the selector):
#   0  the drive passed and every round it armed was played and recorded
#   1  product: a picker other than the Photo Picker, uCrop never returned,
#      the grace expired early, or the drive failed while the sidecar was fine
#   2  harness: a screen the selectors do not know, the marker sequence
#      broken, the pause branch never taken (the precondition unmet), or a
#      passing drive that never reported its rounds
#   3  infrastructure: no device, or the gallery never indexed
# A sidecar failure reds the lane even when the drive passed.
#
# The sidecar log (/tmp/photo-sidecar.log) is fixed vocabulary: round
# numbers, selector names, cause words, seconds. It passes the log-privacy
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
readonly NEEDLE_DIR=/tmp/haven-soak/needles
# The paths are fixed in a lane; the self-test moves them into its sandbox.
readonly LOGCAT="${PHOTO_UI_LOGCAT:-/tmp/adb-logcat.log}"
readonly SIDECAR_LOG="${PHOTO_UI_SIDECAR_LOG:-/tmp/photo-sidecar.log}"
readonly WORK="${PHOTO_UI_WORK:-/tmp/photo-ui}"
readonly STOP="${WORK}/stop"
readonly WATCH_VERDICT="${WORK}/verdict"
readonly LOGSCAN_REPORT="${WORK}-logscan.ndjson"
readonly DEVICE_SECS=60
readonly MARKER_POLL_SECS=1
readonly GRACE_MARKER_SECS="${PHOTO_UI_GRACE_MARKER_SECS:-10}"
readonly JOIN_SECS="${PHOTO_UI_JOIN_SECS:-30}"
# Mirrors haven/lib/src/services/system_activity_excursions.dart's
# kSystemActivityHandoffGrace; the self-test pins the two together.
readonly GRACE_SECS=20
readonly GRACE_MARGIN_SECS=5
readonly ARM_RE='\[pp\] ARM round=[0-9]+ act=(pick:[0-9]+|cancel)'
readonly END_RE='\[pp\] END rounds=[0-9]+'
readonly PAUSE_MARKER='[MapShell] pause: background handoff branch'
readonly GRACE_RE='\[MapShell\] handoff grace: ended by (resumed|expired|superseded|detached|disposed)'

say() { echo "[photo-ui] $*"; }

# The library's hook: a round is abandoned once the drive has ended.
pp_hook_alive() { [[ ! -e "${STOP}" ]]; }

record() { printf '%s\n' "$*" >> "${SIDECAR_LOG}"; }

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
    record "round=${round} act=${kind} picker=${PP_PICKER} ucrop=${PP_UCROP} failed"
    watch_verdict "${rc}" "round ${round} (${kind}): ${PP_MSG}"
    return "${rc}"
  fi
  if since_has "${offset}" "${PAUSE_MARKER}"; then pause=yes; fi
  if [[ "${kind}" == pick ]]; then
    cause="$(grace_cause "${offset}")"
    record "round=${round} act=pick picker=${PP_PICKER} ucrop=${PP_UCROP} pause=${pause} grace=${cause} dwell=${PP_DWELL}s"
    if [[ "${pause}" == no ]]; then
      watch_verdict 2 "round ${round} (pick): MapShell never took its Android pause branch between the ARM and the return, so root cause A's precondition (background sharing on at the pause) was not exercised"
      return 2
    fi
    if [[ "${cause}" == expired ]] && (( PP_DWELL < GRACE_SECS - GRACE_MARGIN_SECS )); then
      watch_verdict 1 "round ${round} (pick): the excursion grace expired though uCrop was in front for only ${PP_DWELL} s of its ${GRACE_SECS} s"
      return 1
    fi
  else
    record "round=${round} act=cancel picker=${PP_PICKER} pause=${pause}"
  fi
  return 0
}

# watch — the sidecar, in the background: the rounds in marker order until the
# main shell touches STOP. Its verdict is the file it writes.
watch() {
  local offset=0 expect=0 played=0 hit at marker round act rc reported=-1
  watch_verdict 0 ''
  # After STOP it still reads what the drive wrote before it ended (its END
  # marker above all); a round armed then is abandoned by pp_hook_alive.
  while :; do
    hit="$(next_marker "${offset}")"
    if [[ -z "${hit}" ]]; then
      [[ ! -e "${STOP}" ]] || break
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
  if ! pp_seed_gallery "${DEVICE}" "${WORK}/priv"; then
    RC=3; MSG="the media store did not list both gallery fixtures within ${PP_MEDIA_SECS} s"; exit 0
  fi
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
  if (( wrc != 0 )); then
    RC="${wrc}"; MSG="${wmsg}$( (( drive_rc == 0 )) && printf ' (the drive itself passed: a sidecar failure is red)')"
  elif (( drive_rc != 0 )); then
    RC="${drive_rc}"; MSG="the drive failed (rc ${drive_rc}) with the sidecar's ${played} round(s) all played"
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
# side — markers in a logcat file, the tap that opens the picker, and the wait
# for Haven to be back. Bounds are shrunk through the PHOTO_* overrides only.
# ---------------------------------------------------------------------------
readonly SELF_TEST_FIXTURES=26

_st_stub_adb() { # <bin dir>
  cat > "$1/adb" <<'STUB'
#!/usr/bin/env bash
S="${STUB}"
printf '%s\n' "$*" >> "${S}/calls"
[[ "${1:-}" == -s ]] && shift 2
PKG=com.oblivioustech.haven
get() { cat "${S}/$1" 2>/dev/null || true; }
put() { printf '%s\n' "$2" > "${S}/$1"; }
log() { printf '11-16 12:00:00.000  4242  4242 I flutter : %s\n' "$1" >> "${PHOTO_UI_LOGCAT}"; }
pnode() { printf '<node index="0" text="" resource-id="%s" class="android.widget.ImageView" package="%s" content-desc="%s" clickable="true" enabled="true" bounds="%s"/>' "$2" "$1" "$3" "$4"; }
screen_xml() {
  local root="${PKG}" body=''
  case "$(get screen)" in
    picker) root=com.google.android.providers.media.module
      local rid="${root}:id/icon_thumbnail"
      [[ -z "${STUB_PICKER_UNKNOWN:-}" ]] || rid="${root}:id/unknown_grid_item"
      body="$(pnode "${root}" "${rid}" 'Taken on Nov 16, 2026 12:01' '[40,600][340,900]')$(pnode "${root}" "${rid}" 'Taken on Nov 15, 2026 09:30' '[400,600][700,900]')" ;;
    ucrop) body="$(pnode "${PKG}" "${PKG}:id/menu_crop" 'Crop' '[900,100][1040,240]')" ;;
    *) body="$(pnode "${PKG}" '' 'Edit Photo' '[280,500][560,560]')" ;;
  esac
  printf "<?xml version='1.0' encoding='UTF-8' standalone='yes' ?><hierarchy rotation=\"0\"><node index=\"0\" text=\"\" resource-id=\"\" class=\"android.widget.FrameLayout\" package=\"%s\" content-desc=\"\" bounds=\"[0,0][1080,2400]\">%s</node></hierarchy>" "${root}" "${body}"
}
resumed() {
  local c="${PKG}/.MainActivity"
  case "$(get screen)" in
    picker) c='com.google.android.providers.media.module/com.android.providers.media.photopicker.PhotoPickerActivity' ;;
    ucrop) c="${PKG}/com.yalantis.ucrop.UCropActivity" ;;
  esac
  printf '  topResumedActivity=ActivityRecord{1 u0 %s t1}\n' "${c}"
}
case "${1:-}" in
  wait-for-device) exit 0 ;;
  push) cp "$2" "${S}/media.$(basename "$3")"; exit 0 ;;
  exec-out) screen_xml; exit 0 ;;
  shell) shift ;;
  *) exit 9 ;;
esac
cmd="$*"
if [[ "${cmd}" == "content query "* ]]; then
  if (( $# == 1 )) && [[ "${cmd}" == "content query --uri content://media/external/images/media --projection _display_name --where \"_display_name LIKE 'haven-gate-%'\"" ]]; then
    for f in "${S}"/media.haven-gate-*.png; do [[ -f "${f}" ]] && echo "Row: 0 _display_name=${f##*/media.}"; done
  fi
  exit 0
fi
if [[ "${cmd}" == "content delete "* ]]; then
  (( $# == 1 )) && [[ "${cmd}" == "content delete --uri content://media/external/images/media --where \"_display_name LIKE 'haven-gate-%'\"" ]] && rm -f "${S}"/media.haven-gate-*.png
  exit 0
fi
case "${cmd}" in
  "getprop ro.build.version.sdk") echo 34 ;;
  "touch -t "*|"content call "*|"rm -f "*) : ;;
  "dumpsys activity activities") resumed ;;
  "input keyevent 4") [[ "$(get screen)" == picker ]] && put screen main ;;
  "input tap "*) read -r _ _ x y <<<"${cmd}"
    case "$(get screen)" in
      picker) (( y >= 600 && y <= 900 )) || exit 0
        [[ -n "${STUB_NO_PAUSE:-}" ]] || log '[MapShell] pause: background handoff branch'
        put screen ucrop ;;
      ucrop) (( x >= 900 )) || exit 0
        [[ -n "${STUB_UCROP_NEVER:-}" ]] && exit 0
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
# would, and waits for Haven to be back before arming the next.
_st_stub_drive() { # <ci dir>
  cat > "$1/run-single-avd-scenario.sh" <<'DRIVE'
#!/usr/bin/env bash
S="${STUB}"
log() { printf '11-16 12:00:00.000  4242  4242 I flutter : %s\n' "$1" >> "${PHOTO_UI_LOGCAT}"; }
back() { # Haven resumed again, within a bound
  local deadline=$(( SECONDS + 20 ))
  while (( SECONDS < deadline )); do
    [[ "$(cat "${S}/screen" 2>/dev/null)" == main ]] && return 0
    sleep 0.1
  done
  return 1
}
: > "${PHOTO_UI_LOGCAT}"
log 'unrelated app line naming no marker'
n=0
for act in ${STUB_ROUNDS:-cancel pick:0 pick:1}; do
  if [[ -n "${STUB_RESTART:-}" && "${n}" == 1 && ! -f "${S}/restarted" ]]; then
    touch "${S}/restarted"; n=0
    log '[pp] ARM round=0 act=cancel'; echo picker > "${S}/screen"; back || exit 1; n=1
  fi
  log "[pp] ARM round=$(( n + ${STUB_ROUND_SKEW:-0} )) act=${act}"
  echo picker > "${S}/screen"
  back || exit 1
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
      PHOTO_MEDIA_SECS=2 PHOTO_PICKER_SECS=3 PHOTO_UCROP_SECS=3 PHOTO_RETURN_SECS=3 PHOTO_UI_GRACE_MARKER_SECS=2 PHOTO_UI_JOIN_SECS=10 \
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
  }
  _has() { # <label> <fixed string>
    ran=$(( ran + 1 ))
    if grep -qF -- "$2" <<<"${out}"; then printf '  PASS %s\n' "$1"; else
      printf '  FAIL %s: transcript lacks "%s"\n%s\n' "$1" "$2" "${out}" >&2; fails=1; fi
  }

  echo "run-photo-ui-scenario.sh --self-test"
  _scenario "a cancel and two picks, each played, recorded and counted, pass" 0
  _has "…each pick recorded with its selectors, the pause branch and the grace cause" "round=1 act=pick picker=photopicker-rid ucrop=rid pause=yes grace=resumed"
  _has "…the cancel round recorded without a pick" "round=0 act=cancel picker=- pause=no"
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
  _has "…naming the dwell" "the excursion grace expired though uCrop was in front for only"
  _scenario "a grace ended by the resume or any other cause passes" 0 STUB_GRACE=superseded
  _scenario "a skipped round number breaks the marker sequence, rc 2" 2 STUB_ROUND_SKEW=1
  _has "…named as such" "the marker sequence broke: round 1 was armed where round 0 was due"
  _scenario "a picker screen no selector knows is a harness failure" 2 STUB_PICKER_UNKNOWN=1
  _has "…listing its resource ids" "rids: unknown_grid_item"
  _scenario "uCrop that never hands Haven back is a product failure" 1 STUB_UCROP_NEVER=1
  _has "…named as such" "uCrop did not return a result"
  _scenario "a drive that fails with every round played keeps the drive's verdict" 1 STUB_DRIVE_RC=1
  _has "…named as the drive's" "the drive failed (rc 1)"
  _scenario "a passing drive whose sidecar failed is red" 1 STUB_GRACE=expired STUB_ROUNDS="cancel pick:0"
  _has "…saying the drive itself passed" "a sidecar failure is red"
  _scenario "a passing drive that never reports its rounds is a harness failure" 2 STUB_NO_END=1
  _scenario "a drive restarted after a connect flake counts its rounds again from 0" 0 STUB_RESTART=1
  _has "…and says so" "drive restarted: rounds counted again from 0"
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
  got="$(grep -cE "^const String _k(Arm|End)Marker" "${target}" 2>/dev/null || true)"
  if [[ "${got}" == 2 ]] && grep -qF "const String _kArmMarker = '[pp] ARM round=';" "${target}" \
     && grep -qF "const String _kEndMarker = '[pp] END rounds=';" "${target}"; then
    echo "  PASS the Dart target prints the markers this sidecar reads"
  else echo "  FAIL the Dart target's marker constants are not the ones ARM_RE/END_RE read" >&2; fails=1; fi

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
