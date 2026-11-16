#!/usr/bin/env bash
# shellcheck disable=SC2034  # PP_* results are read by the sourcing script
#
# The system photo picker and the crop editor, driven from the host. Sourced
# by run-launch-gate-android.sh (the release APK) and photo-picker-sidecar.sh
# (the debug UI lane), so what Haven's photo trip looks like on a device is
# known in one place.
#
# # The trip, as Android runs it (AOSP MediaProvider android14-release)
#
#   tap        Haven calls image_picker with useAndroidPhotoPicker
#              (lib/src/utils/image_picker_config.dart): ACTION_PICK_IMAGES,
#              which on API 33+ resolves to the Photo Picker,
#              `.photopicker.PhotoPickerActivity` in the MediaProvider module.
#   picker     TRANSLUCENT (PickerDefaultTheme, windowIsTranslucent=true), so
#              MainActivity is paused, not stopped: Flutter says `inactive`.
#   uCrop      com.yalantis.ucrop.UCropActivity, in Haven's own process and
#              opaque: MainActivity is stopped, Flutter says `paused`, and with
#              background sharing on MapShell takes its Android pause branch.
#   return     image_cropper answers from onActivityResult, before onResume.
#
# A resumed activity is read from `dumpsys activity activities` (ui-dump.py
# resumed), a screen from `uiautomator dump` (ui-dump.py find), and every step
# waits for the next activity rather than for time. On API 33+ any picker but
# the Photo Picker is refused as a product failure: main() promises the scoped,
# permission-free picker (C5), and a DocumentsUI or GET_CONTENT browser would
# mean that promise broke.
#
# # Contract
#
# The caller defines `pp_hook_alive` (return 0 to go on, non-zero to abort the
# round; the launch gate's ends the run itself when the app died). Results:
#
#   pp_seed_gallery <device> <dir>     0, or 3 when the media store never lists
#                                      both photos (infrastructure)
#   pp_clear_gallery <device>          best effort, always 0
#   pp_round <device> <dir> <pick|cancel> <index> <api>
#       0 done; 1 product; 2 harness (a screen the selectors do not know);
#       3 infrastructure (adb gave no answer); 4 aborted by the hook.
#       PP_MSG says why in fixed words; PP_PICKER and PP_UCROP name the
#       selector that matched (photopicker-rid | photopicker-desc |
#       documentsui-rid | -, and rid | desc | -); PP_DWELL is the seconds from
#       uCrop resumed to MainActivity resumed (-1 when not measured).
#
# Nothing this prints or returns carries what a node says: a thumbnail's
# description can hold a date. Component names and resource ids are developer
# names. Every loop is wall-clock bounded by a readonly constant below and
# priced in scripts/ci/e2e_lane_budget.manifest.

readonly PP_PKG='com.oblivioustech.haven'
readonly PP_MAIN="${PP_PKG}/${PP_PKG}.MainActivity"
readonly PP_UCROP_ACTIVITY="${PP_PKG}/com.yalantis.ucrop.UCropActivity"
readonly PP_PICKER_PKG_RE='^com(\.google)?\.android\.providers\.media(\.module)?$'
readonly PP_PHOTO_PICKER_RE='^com(\.google)?\.android\.providers\.media(\.module)?/.*\.photopicker\.PhotoPickerActivity$'
readonly PP_DOCUMENTSUI_PKG_RE='^com(\.google)?\.android\.documentsui$'
readonly PP_OURS_RE='^com\.oblivioustech\.haven$'
readonly PP_THUMB_RID='rid:^com(\.google)?\.android\.providers\.media(\.module)?:id/icon_thumbnail$'
readonly PP_DOCUMENTSUI_THUMB_RID='rid:^com(\.google)?\.android\.documentsui:id/icon_thumb$'
readonly PP_CROP_RID='rid:^com\.oblivioustech\.haven:id/menu_crop$'
readonly PP_FIXTURE_A='haven-gate-a.png'
readonly PP_FIXTURE_B='haven-gate-b.png'
readonly PP_MEDIA_DIR='/sdcard/Pictures'
# The bounds. PHOTO_* overrides exist for the self-tests, whose stub device
# answers at once; no workflow sets them.
readonly PP_MEDIA_SECS="${PHOTO_MEDIA_SECS:-60}"    # both photos listed by the media store
readonly PP_PICKER_SECS="${PHOTO_PICKER_SECS:-60}"  # tap -> picker resumed; picker -> thumbnail tapped
readonly PP_UCROP_SECS="${PHOTO_UCROP_SECS:-60}"    # thumbnail -> uCrop resumed; uCrop -> crop tapped
readonly PP_RETURN_SECS="${PHOTO_RETURN_SECS:-60}"  # crop (or cancel) -> MainActivity resumed
readonly PP_ADB_SECS="${PHOTO_ADB_SECS:-10}"        # one adb read
readonly PP_DUMP_SECS="${PHOTO_DUMP_SECS:-15}"      # one uiautomator dump

_PP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly _PP_LIB_DIR

PP_MSG=''
PP_PICKER='-'
PP_UCROP='-'
PP_DWELL=-1
PP_RESUMED=''
PP_FIND_SEL=''
PP_FIND_DIGEST=''
PP_FIND_RIDS=''
PP_FIND_XY=()

# pp_seed_gallery <device> <dir> — the two fixtures in the shared Pictures
# directory, indexed. Deterministic files and dates (make-avatar-fixture.py),
# so the grid is the same two photos in the same order every run.
pp_seed_gallery() {
  local device="$1" dir="$2" deadline listed f
  python3 -I "${_PP_LIB_DIR}/make-avatar-fixture.py" --variant a --out "${dir}/${PP_FIXTURE_A}" || return 3
  python3 -I "${_PP_LIB_DIR}/make-avatar-fixture.py" --variant b --out "${dir}/${PP_FIXTURE_B}" || return 3
  for f in "${PP_FIXTURE_A}" "${PP_FIXTURE_B}"; do
    adb -s "${device}" push "${dir}/${f}" "${PP_MEDIA_DIR}/${f}" >/dev/null 2>&1 || return 3
  done
  adb -s "${device}" shell touch -t 202601020000.00 "${PP_MEDIA_DIR}/${PP_FIXTURE_A}" >/dev/null 2>&1 || true
  adb -s "${device}" shell touch -t 202601010000.00 "${PP_MEDIA_DIR}/${PP_FIXTURE_B}" >/dev/null 2>&1 || true
  # MediaProvider's scan_volume reports nothing either way (it logs an unknown
  # volume and returns an empty Bundle), so what decides is the query below.
  adb -s "${device}" shell content call --uri content://media --method scan_volume --arg external_primary >/dev/null 2>&1 || true
  deadline=$(( SECONDS + PP_MEDIA_SECS ))
  while (( SECONDS < deadline )); do
    # One device command string: the device shell re-splits the words, so the
    # WHERE clause must reach it quoted.
    listed="$(timeout "${PP_ADB_SECS}" adb -s "${device}" shell \
      "content query --uri content://media/external/images/media --projection _display_name --where \"_display_name LIKE 'haven-gate-%'\"" \
      2>/dev/null | tr -d '\r' || true)"
    if grep -q "_display_name=${PP_FIXTURE_A}" <<<"${listed}" && grep -q "_display_name=${PP_FIXTURE_B}" <<<"${listed}"; then
      return 0
    fi
  done
  return 3
}

# pp_clear_gallery <device> — the fixtures out of the media store and the
# disk, so a saved AVD snapshot never carries them into another lane.
pp_clear_gallery() {
  local device="$1"
  adb -s "${device}" shell \
    "content delete --uri content://media/external/images/media --where \"_display_name LIKE 'haven-gate-%'\"" >/dev/null 2>&1 || true
  adb -s "${device}" shell rm -f "${PP_MEDIA_DIR}/${PP_FIXTURE_A}" "${PP_MEDIA_DIR}/${PP_FIXTURE_B}" >/dev/null 2>&1 || true
  return 0
}

# pp_resumed <device> <dir> — PP_RESUMED: the resumed component, or '' when
# adb gave no answer or no line named one.
pp_resumed() {
  local device="$1" dir="$2" out
  PP_RESUMED=''
  timeout "${PP_ADB_SECS}" adb -s "${device}" shell dumpsys activity activities \
    > "${dir}/pp-activities.txt" 2>/dev/null || true
  out="$(python3 -I "${_PP_LIB_DIR}/ui-dump.py" resumed --dumpsys "${dir}/pp-activities.txt" 2>/dev/null || true)"
  rm -f "${dir}/pp-activities.txt"
  [[ "${out}" == 'resumed '* && "${out}" != 'resumed none' ]] || return 0
  PP_RESUMED="${out#resumed }"
}

# pp_find <device> <dir> <package-regex> <spec>... — one dump read for system
# nodes: PP_FIND_SEL (the matching spec's number, or none), PP_FIND_XY
# ("x y" per match), PP_FIND_RIDS, PP_FIND_DIGEST (the foreground window's,
# compared between dumps and never printed). Non-zero when there was no
# observation.
pp_find() {
  local device="$1" dir="$2" regex="$3" out line rc=0
  shift 3
  local -a argv=(find --dump "${dir}/pp-dump.xml" --package-regex "${regex}" --list-rids --digest-out "${dir}/pp-digest")
  local spec
  for spec in "$@"; do argv+=(--select "${spec}"); done
  PP_FIND_SEL=''; PP_FIND_DIGEST=''; PP_FIND_RIDS=''; PP_FIND_XY=()
  rm -f "${dir}/pp-digest"
  timeout "${PP_DUMP_SECS}" adb -s "${device}" exec-out \
    "uiautomator dump /sdcard/haven-pp.xml >/dev/null 2>&1 && cat /sdcard/haven-pp.xml; rm -f /sdcard/haven-pp.xml" \
    > "${dir}/pp-dump.xml" 2>/dev/null || true
  out="$(python3 -I "${_PP_LIB_DIR}/ui-dump.py" "${argv[@]}" 2>/dev/null)" || rc=$?
  rm -f "${dir}/pp-dump.xml"
  (( rc == 0 )) || { rm -f "${dir}/pp-digest"; return 1; }
  PP_FIND_DIGEST="$(cat "${dir}/pp-digest")"
  rm -f "${dir}/pp-digest"
  while IFS= read -r line; do
    case "${line}" in
      'selector '*) PP_FIND_SEL="${line#selector }" ;;
      'match '*) PP_FIND_XY+=("${line#match }") ;;
      'rids '*) PP_FIND_RIDS="${line#rids }" ;;
    esac
  done <<<"${out}"
}

_pp_tap() { # <device> <"x y">
  local x y
  read -r x y <<<"$2"
  adb -s "$1" shell input tap "${x}" "${y}" >/dev/null 2>&1
}

_pp_is_picker() { # <component> <api>
  if (( $2 >= 33 )); then
    [[ "$1" =~ ${PP_PHOTO_PICKER_RE} ]]
  else
    [[ "$1" =~ ${PP_PHOTO_PICKER_RE} || "${1%%/*}" =~ ${PP_DOCUMENTSUI_PKG_RE} || "${1%%/*}" == com.google.android.gms ]]
  fi
}

# Phase 1: the tap opened the picker. Anything else that took the front is
# named; on API 33+ it is the broken Photo Picker promise.
_pp_await_picker() { # <device> <dir> <api>
  local device="$1" dir="$2" api="$3" deadline answered=0
  deadline=$(( SECONDS + PP_PICKER_SECS ))
  while (( SECONDS < deadline )); do
    pp_hook_alive || return 4
    pp_resumed "${device}" "${dir}"
    [[ -n "${PP_RESUMED}" ]] || continue
    answered=1
    [[ "${PP_RESUMED}" != "${PP_MAIN}" ]] || continue
    if _pp_is_picker "${PP_RESUMED}" "${api}"; then return 0; fi
    PP_MSG="a picker other than the system Photo Picker opened (${PP_RESUMED}); main() promises the scoped Photo Picker on API ${api}"
    return 1
  done
  if (( ! answered )); then PP_MSG="adb never named a resumed activity within ${PP_PICKER_SECS} s of the tap"; return 3; fi
  PP_MSG="did not progress: the photo tap opened no picker within ${PP_PICKER_SECS} s"
  return 1
}

# Phase 2: one thumbnail tapped, once the picker's window holds still.
_pp_pick_thumbnail() { # <device> <dir> <index> <api>
  local device="$1" dir="$2" index="$3" api="$4" deadline prev='' n regex="${PP_PICKER_PKG_RE}"
  local -a specs=("${PP_THUMB_RID}") names=(photopicker-rid)
  if (( api < 33 )); then
    specs+=("${PP_DOCUMENTSUI_THUMB_RID}"); names+=(documentsui-rid)
    regex='^com(\.google)?\.android\.(providers\.media(\.module)?|documentsui)$|^com\.google\.android\.gms$'
  fi
  # The Compose picker of newer module builds labels each item by what it is.
  specs+=('desc-prefix:Photo'); names+=(photopicker-desc)
  deadline=$(( SECONDS + PP_PICKER_SECS ))
  while (( SECONDS < deadline )); do
    pp_hook_alive || return 4
    pp_find "${device}" "${dir}" "${regex}" "${specs[@]}" || continue
    if [[ "${PP_FIND_DIGEST}" != "${prev}" ]]; then prev="${PP_FIND_DIGEST}"; continue; fi
    [[ "${PP_FIND_SEL}" != none ]] || continue
    n="${#PP_FIND_XY[@]}"
    if (( n <= index )); then
      PP_MSG="harness: the picker shows ${n} thumbnail(s), fewer than the ${index}+1 this round picks from (rids: ${PP_FIND_RIDS:-none})"
      return 2
    fi
    PP_PICKER="${names[$(( PP_FIND_SEL - 1 ))]}"
    _pp_tap "${device}" "${PP_FIND_XY[${index}]}"
    return 0
  done
  PP_MSG="harness: no thumbnail selector matched the picker within ${PP_PICKER_SECS} s (rids: ${PP_FIND_RIDS:-none})"
  return 2
}

# The cancel round: BACK once the picker holds still; Haven must come back
# with nothing changed.
_pp_cancel() { # <device> <dir>
  local device="$1" dir="$2" deadline prev=''
  deadline=$(( SECONDS + PP_PICKER_SECS ))
  while (( SECONDS < deadline )); do
    pp_hook_alive || return 4
    pp_find "${device}" "${dir}" "${PP_PICKER_PKG_RE}" 'text:-' || continue
    if [[ "${PP_FIND_DIGEST}" == "${prev}" ]]; then
      adb -s "${device}" shell input keyevent 4 >/dev/null 2>&1
      return 0
    fi
    prev="${PP_FIND_DIGEST}"
  done
  PP_MSG="harness: the picker never held still for a cancel within ${PP_PICKER_SECS} s"
  return 2
}

# Phase 3: the thumbnail opened uCrop. A picker that asks to confirm a single
# pick (newer picker builds) gets one tap on its Add/Done/Select.
_pp_await_ucrop() { # <device> <dir> <api>
  local device="$1" dir="$2" api="$3" deadline confirmed=0
  deadline=$(( SECONDS + PP_UCROP_SECS ))
  while (( SECONDS < deadline )); do
    pp_hook_alive || return 4
    pp_resumed "${device}" "${dir}"
    case "${PP_RESUMED}" in
      "${PP_UCROP_ACTIVITY}") return 0 ;;
      "${PP_MAIN}") PP_MSG="the crop editor never opened: Haven came back from the picker without it"; return 1 ;;
      '') continue ;;
    esac
    if (( ! confirmed )) && _pp_is_picker "${PP_RESUMED}" "${api}" \
       && pp_find "${device}" "${dir}" "${PP_PICKER_PKG_RE}" 'text:Add' 'text:Done' 'text:Select' \
       && [[ "${PP_FIND_SEL}" != none ]]; then
      _pp_tap "${device}" "${PP_FIND_XY[0]}"
      confirmed=1
    fi
  done
  if _pp_is_picker "${PP_RESUMED}" "${api}"; then
    PP_MSG="harness: the picker stayed in front ${PP_UCROP_SECS} s after the thumbnail tap (rids: ${PP_FIND_RIDS:-none})"
    return 2
  fi
  PP_MSG="the crop editor did not open within ${PP_UCROP_SECS} s of the pick (front: ${PP_RESUMED:-unknown})"
  return 1
}

# Phase 4: uCrop's crop action, polled — the menu swaps it for a loader
# while the image decodes.
_pp_crop() { # <device> <dir>
  local device="$1" dir="$2" deadline prev=''
  deadline=$(( SECONDS + PP_UCROP_SECS ))
  while (( SECONDS < deadline )); do
    pp_hook_alive || return 4
    pp_find "${device}" "${dir}" "${PP_OURS_RE}" "${PP_CROP_RID}" 'desc-prefix:Crop' || continue
    if [[ "${PP_FIND_DIGEST}" != "${prev}" ]]; then prev="${PP_FIND_DIGEST}"; continue; fi
    [[ "${PP_FIND_SEL}" != none ]] || continue
    if [[ "${PP_FIND_SEL}" == 1 ]]; then PP_UCROP=rid; else PP_UCROP=desc; fi
    _pp_tap "${device}" "${PP_FIND_XY[0]}"
    return 0
  done
  PP_MSG="harness: uCrop's crop action was not found within ${PP_UCROP_SECS} s (rids: ${PP_FIND_RIDS:-none})"
  return 2
}

# Phase 5: MainActivity resumed again.
_pp_await_main() { # <device> <dir> <what>
  local device="$1" dir="$2" what="$3" deadline
  deadline=$(( SECONDS + PP_RETURN_SECS ))
  while (( SECONDS < deadline )); do
    pp_hook_alive || return 4
    pp_resumed "${device}" "${dir}"
    [[ "${PP_RESUMED}" != "${PP_MAIN}" ]] || return 0
  done
  PP_MSG="${what} did not hand Haven back within ${PP_RETURN_SECS} s (front: ${PP_RESUMED:-unknown})"
  return 1
}

# pp_round <device> <dir> <pick|cancel> <index> <api> — after the caller's tap.
pp_round() {
  local device="$1" dir="$2" act="$3" index="$4" api="$5" rc=0 ucrop_at
  PP_MSG=''; PP_PICKER='-'; PP_UCROP='-'; PP_DWELL=-1
  _pp_await_picker "${device}" "${dir}" "${api}" || return
  if [[ "${act}" == cancel ]]; then
    _pp_cancel "${device}" "${dir}" || return
    _pp_await_main "${device}" "${dir}" "the cancelled picker" || return
    return 0
  fi
  _pp_pick_thumbnail "${device}" "${dir}" "${index}" "${api}" || return
  _pp_await_ucrop "${device}" "${dir}" "${api}" || return
  ucrop_at="${SECONDS}"
  _pp_crop "${device}" "${dir}" || return
  _pp_await_main "${device}" "${dir}" "uCrop" || rc=$?
  if (( rc == 1 )); then PP_MSG="uCrop did not return a result: ${PP_MSG}"; fi
  (( rc == 0 )) || return "${rc}"
  PP_DWELL=$(( SECONDS - ucrop_at ))
  return 0
}
