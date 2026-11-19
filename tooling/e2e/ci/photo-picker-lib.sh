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
# resumed), the window holding input focus from `dumpsys input` (ui-dump.py
# focused), a screen from `uiautomator dump` (ui-dump.py find), and every step
# waits for the next activity rather than for time.
#
# No input reaches a system screen before its window holds input focus.
# "Resumed" is the activity manager's word, said before the window exists:
# the Photo Picker runs in a process of its own (android:process=":PhotoPicker")
# and is translucent, so no starting window stands in, and until its first
# frame no window has focus at all. A key injected then waits in the input
# dispatcher and is dropped once no window has taken focus within its
# dispatching timeout; a tap lands on whatever is visible under it. The
# dispatcher focuses only a visible window, so focus is also proof the
# window is on screen. The first device run sent its BACK in that gap and the
# picker never saw it. On API 33+ a picker KNOWN
# to be the wrong one — DocumentsUI, the Photo Picker's GET_CONTENT alias, the
# Play services picker — is a product failure: main() promises the scoped,
# permission-free picker (C5), and those would mean that promise broke. An
# activity this file does not know (a newer Photopicker module, say) is a
# harness failure naming its component, never a product one.
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
#       0 done; 1 product; 2 harness (a screen the selectors do not know, or
#       a system screen that never took focus or ignored the input it was
#       given while focused: nothing Haven decides); 3 infrastructure (adb
#       gave no answer); 4 aborted by the hook.
#       PP_MSG says why in fixed words; PP_PICKER and PP_UCROP name the
#       selector that matched (photopicker-rid | photopicker-desc |
#       documentsui-rid | -, and rid | desc | -); PP_DWELL is the seconds from
#       just before the thumbnail tap to MainActivity seen resumed (-1 when not
#       measured): it starts before uCrop can resume and ends after Haven
#       did, so it is an UPPER bound on the time Haven was away.
#       PP_FOCUS_WAIT is the seconds from the picker seen resumed to its
#       window seen focused (-1 when not reached).
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
readonly PP_GETCONTENT_RE='\.photopicker\.PhotoPickerGetContentActivity$'
readonly PP_GMS_PKG='com.google.android.gms'
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
readonly PP_PICKER_SECS="${PHOTO_PICKER_SECS:-60}"  # tap -> picker resumed; picker -> focused, thumbnail tapped (or BACK sent)
readonly PP_UCROP_SECS="${PHOTO_UCROP_SECS:-60}"    # thumbnail -> uCrop resumed; uCrop -> focused, crop tapped
readonly PP_RETURN_SECS="${PHOTO_RETURN_SECS:-60}"  # crop (or cancel) -> MainActivity resumed
readonly PP_ADB_SECS="${PHOTO_ADB_SECS:-10}"        # one adb read
readonly PP_DUMP_SECS="${PHOTO_DUMP_SECS:-15}"      # one uiautomator dump

_PP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly _PP_LIB_DIR

PP_MSG=''
PP_PICKER='-'
PP_UCROP='-'
PP_DWELL=-1
PP_FOCUS_WAIT=-1
PP_TAP_AT=''
PP_RESUMED=''
PP_FOCUSED=''
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
  timeout "${PP_ADB_SECS}" adb -s "${device}" shell \
    "content delete --uri content://media/external/images/media --where \"_display_name LIKE 'haven-gate-%'\"" >/dev/null 2>&1 || true
  timeout "${PP_ADB_SECS}" adb -s "${device}" shell rm -f "${PP_MEDIA_DIR}/${PP_FIXTURE_A}" "${PP_MEDIA_DIR}/${PP_FIXTURE_B}" >/dev/null 2>&1 || true
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

# pp_focused <device> <dir> — PP_FOCUSED: the component whose window holds
# input focus on the default display, `other` (a window that is no
# activity's), `none`, or '' when adb gave no answer.
pp_focused() {
  local device="$1" dir="$2" out
  PP_FOCUSED=''
  timeout "${PP_ADB_SECS}" adb -s "${device}" shell dumpsys input \
    > "${dir}/pp-input.txt" 2>/dev/null || true
  out="$(python3 -I "${_PP_LIB_DIR}/ui-dump.py" focused --dumpsys "${dir}/pp-input.txt" 2>/dev/null || true)"
  rm -f "${dir}/pp-input.txt"
  [[ "${out}" == 'focused '* && "${out}" != 'focused unknown' ]] || return 0
  PP_FOCUSED="${out#focused }"
}

# _pp_focus_words <focus> — a PP_FOCUSED value in fixed words, for a message.
_pp_focus_words() {
  case "$1" in
    '') echo 'unread (adb gave no answer)' ;;
    none) echo 'on no window' ;;
    other) echo 'on a window that is no activity'"'"'s' ;;
    *) echo "on $1" ;;
  esac
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

# A picker other than the Photo Picker that a device can resolve Haven's
# request to: DocumentsUI, the GET_CONTENT alias, the Play services picker.
_pp_is_other_picker() { # <component>
  [[ "${1%%/*}" =~ ${PP_DOCUMENTSUI_PKG_RE} || "$1" =~ ${PP_GETCONTENT_RE} || "${1%%/*}" == "${PP_GMS_PKG}" ]]
}

_pp_is_picker() { # <component> <api>
  if [[ "$1" =~ ${PP_PHOTO_PICKER_RE} ]]; then return 0; fi
  (( $2 < 33 )) && _pp_is_other_picker "$1"
}

# Phase 1: the tap opened the picker. A known wrong picker on API 33+ is the
# broken Photo Picker promise; an activity nobody here knows is named for the
# harness to learn.
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
    if _pp_is_other_picker "${PP_RESUMED}"; then
      PP_MSG="a picker other than the system Photo Picker opened (${PP_RESUMED}); main() promises the scoped Photo Picker on API ${api}"
      return 1
    fi
    PP_MSG="harness: an activity the picker rules do not know took the front after the photo tap (${PP_RESUMED}); teach photo-picker-lib.sh what it is"
    return 2
  done
  if (( ! answered )); then PP_MSG="adb never named a resumed activity within ${PP_PICKER_SECS} s of the tap"; return 3; fi
  PP_MSG="did not progress: the photo tap opened no picker within ${PP_PICKER_SECS} s"
  return 1
}

# Phase 2: one thumbnail tapped, once the picker's window holds input focus
# and then holds still (the sheet slides up after its first frame). One
# bounded read per pass: the focus until it is the picker's, then the dump.
# Focus does not leave a resumed picker unless another window takes it, and
# the tap is judged by its effect (phase 3), so it is not read again.
_pp_pick_thumbnail() { # <device> <dir> <index> <api>
  local device="$1" dir="$2" index="$3" api="$4" deadline prev='' n regex="${PP_PICKER_PKG_RE}" focused=0 last='' start="${SECONDS}"
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
    if (( ! focused )); then
      pp_focused "${device}" "${dir}"
      last="${PP_FOCUSED:-${last}}"
      _pp_is_picker "${PP_FOCUSED}" "${api}" || continue
      focused=1; PP_FOCUS_WAIT=$(( SECONDS - start ))
      continue
    fi
    pp_find "${device}" "${dir}" "${regex}" "${specs[@]}" || continue
    if [[ "${PP_FIND_DIGEST}" != "${prev}" ]]; then prev="${PP_FIND_DIGEST}"; continue; fi
    [[ "${PP_FIND_SEL}" != none ]] || continue
    n="${#PP_FIND_XY[@]}"
    if (( n <= index )); then
      PP_MSG="harness: the picker shows ${n} thumbnail(s), fewer than the ${index}+1 this round picks from (rids: ${PP_FIND_RIDS:-none})"
      return 2
    fi
    PP_PICKER="${names[$(( PP_FIND_SEL - 1 ))]}"
    PP_TAP_AT="${SECONDS}"
    _pp_tap "${device}" "${PP_FIND_XY[${index}]}"
    return 0
  done
  (( focused )) || { _pp_unfocused_picker "${last}"; return; }
  PP_MSG="harness: no thumbnail selector matched the picker within ${PP_PICKER_SECS} s (rids: ${PP_FIND_RIDS:-none})"
  return 2
}

# _pp_unfocused_picker <last focus read> — a resumed picker whose window
# never took input focus: the system's own window never became ready, which
# nothing in Haven decides.
_pp_unfocused_picker() {
  if [[ -z "$1" ]]; then
    PP_MSG="adb never named the focused window within ${PP_PICKER_SECS} s of the picker resuming"
    return 3
  fi
  PP_MSG="harness: the system picker was resumed but its window never took input focus within ${PP_PICKER_SECS} s (focus $(_pp_focus_words "$1")), so no input was sent to it"
  return 2
}

# The cancel round: ONE BACK, sent once the picker's window holds input
# focus; Haven must come back with nothing changed. One BACK is the whole
# gesture: PhotoPickerActivity registers no back callback of its own, and at
# its root (the Photos tab, nothing on the fragment back stack) the default
# handling finishes it (AOSP MediaProvider, PhotoPickerActivity.onBackPressed
# and TabContainerFragment.show). Where the sheet is in its slide does not
# matter to a key, so no dump is read.
_pp_cancel() { # <device> <dir> <api>
  local device="$1" dir="$2" api="$3" deadline last='' start="${SECONDS}"
  deadline=$(( SECONDS + PP_PICKER_SECS ))
  while (( SECONDS < deadline )); do
    pp_hook_alive || return 4
    pp_focused "${device}" "${dir}"
    last="${PP_FOCUSED:-${last}}"
    _pp_is_picker "${PP_FOCUSED}" "${api}" || continue
    PP_FOCUS_WAIT=$(( SECONDS - start ))
    adb -s "${device}" shell input keyevent 4 >/dev/null 2>&1
    return 0
  done
  _pp_unfocused_picker "${last}"
}

# Phase 5 of a cancel: MainActivity resumed again. A picker that left the
# front without Haven coming back is Haven's failure. One still in front,
# still holding the focus it held when the BACK was sent, ignored that BACK:
# the system's, which nothing in Haven decides.
_pp_await_cancelled() { # <device> <dir> <api>
  local device="$1" dir="$2" api="$3" deadline front=''
  deadline=$(( SECONDS + PP_RETURN_SECS ))
  while (( SECONDS < deadline )); do
    pp_hook_alive || return 4
    pp_resumed "${device}" "${dir}"
    [[ "${PP_RESUMED}" != "${PP_MAIN}" ]] || return 0
    [[ -z "${PP_RESUMED}" ]] || front="${PP_RESUMED}"
  done
  if [[ -z "${front}" ]]; then
    PP_MSG="adb never named a resumed activity within ${PP_RETURN_SECS} s of the BACK"
    return 3
  fi
  if _pp_is_picker "${front}" "${api}"; then
    pp_focused "${device}" "${dir}"
    if _pp_is_picker "${PP_FOCUSED}" "${api}"; then
      PP_MSG="harness: the system picker ignored the BACK sent while its window held input focus: still in front and focused ${PP_RETURN_SECS} s later; nothing in Haven decides that"
    else
      PP_MSG="harness: the system picker was still in front ${PP_RETURN_SECS} s after the BACK sent while it held input focus, with focus $(_pp_focus_words "${PP_FOCUSED}") since"
    fi
    return 2
  fi
  PP_MSG="the cancelled picker left the front but Haven did not resume within ${PP_RETURN_SECS} s (front: ${front})"
  return 1
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

# Phase 4: uCrop's crop action, once uCrop's window holds input focus, polled
# — the menu swaps it for a loader while the image decodes. As in phase 2,
# one bounded read per pass. (A picker's confirm tap in phase 3 needs no
# read of its own: it goes to the picker window phase 2 saw focused.)
_pp_crop() { # <device> <dir>
  local device="$1" dir="$2" deadline prev='' focused=0 last=''
  deadline=$(( SECONDS + PP_UCROP_SECS ))
  while (( SECONDS < deadline )); do
    pp_hook_alive || return 4
    if (( ! focused )); then
      pp_focused "${device}" "${dir}"
      last="${PP_FOCUSED:-${last}}"
      [[ "${PP_FOCUSED}" == "${PP_UCROP_ACTIVITY}" ]] || continue
      focused=1
      continue
    fi
    pp_find "${device}" "${dir}" "${PP_OURS_RE}" "${PP_CROP_RID}" 'desc-prefix:Crop' || continue
    if [[ "${PP_FIND_DIGEST}" != "${prev}" ]]; then prev="${PP_FIND_DIGEST}"; continue; fi
    [[ "${PP_FIND_SEL}" != none ]] || continue
    if [[ "${PP_FIND_SEL}" == 1 ]]; then PP_UCROP=rid; else PP_UCROP=desc; fi
    _pp_tap "${device}" "${PP_FIND_XY[0]}"
    return 0
  done
  if (( ! focused )); then
    case "${last}" in
      '') PP_MSG="adb never named the focused window within ${PP_UCROP_SECS} s of uCrop resuming"; return 3 ;;
      other|none|"${PP_PKG}/"*) PP_MSG="uCrop, Haven's own activity, was resumed but its window never took input focus within ${PP_UCROP_SECS} s (focus $(_pp_focus_words "${last}"))"; return 1 ;;
      *) PP_MSG="harness: another app's window held input focus over uCrop for ${PP_UCROP_SECS} s (focus $(_pp_focus_words "${last}"))"; return 2 ;;
    esac
  fi
  PP_MSG="harness: uCrop's crop action was not found within ${PP_UCROP_SECS} s (rids: ${PP_FIND_RIDS:-none})"
  return 2
}

# Phase 5 of a pick: MainActivity resumed again after uCrop, Haven's own.
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
  local device="$1" dir="$2" act="$3" index="$4" api="$5" rc=0
  PP_MSG=''; PP_PICKER='-'; PP_UCROP='-'; PP_DWELL=-1; PP_FOCUS_WAIT=-1
  _pp_await_picker "${device}" "${dir}" "${api}" || return
  if [[ "${act}" == cancel ]]; then
    _pp_cancel "${device}" "${dir}" "${api}" || return
    _pp_await_cancelled "${device}" "${dir}" "${api}" || return
    return 0
  fi
  _pp_pick_thumbnail "${device}" "${dir}" "${index}" "${api}" || return
  _pp_await_ucrop "${device}" "${dir}" "${api}" || return
  _pp_crop "${device}" "${dir}" || return
  _pp_await_main "${device}" "${dir}" "uCrop" || rc=$?
  if (( rc == 1 )); then PP_MSG="uCrop did not return a result: ${PP_MSG}"; fi
  (( rc == 0 )) || return "${rc}"
  PP_DWELL=$(( SECONDS - PP_TAP_AT ))
  return 0
}
