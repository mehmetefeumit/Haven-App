#!/usr/bin/env bash
# CI guard: the boot/update resume wiring survives into the RELEASE APK
# (owner-directed 2026-11-26, OD-R2).
#
# Guard 14c of check_m7_native_wake_guards.sh holds the SOURCE manifest; what
# ships is the manifest the merger and R8 produce, which only the built APK
# holds. Read from it:
#   R1  `…BootResumeReceiver` is declared, not exported, and filters exactly
#       BOOT_COMPLETED and MY_PACKAGE_REPLACED.
#   R2  no receiver named `…flutter_foreground_task.service.RebootReceiver`
#       survived the merge (tools:node="remove"): it would start the service
#       on options an old build stored, outside the resume rule.
#   R3  the string resources the receiver and the notice read by name are in
#       the APK (a resource shrinker that dropped one would crash the receiver).
#
# Usage:
#   check_apk_resume_wiring.sh --merged-manifest <file>  `aapt2 dump xmltree
#        --file AndroidManifest.xml <release apk>`
#   check_apk_resume_wiring.sh --resources <file>        `aapt2 dump resources
#        <release apk>`
#   check_apk_resume_wiring.sh --self-test               hermetic fixtures
#
# Exit: 0 pass, 1 a violation, 2 usage or an input that proves nothing.

set -euo pipefail

readonly BOOT_RECEIVER='com.oblivioustech.haven.BootResumeReceiver'
readonly PLUGIN_RECEIVER='com.pravera.flutter_foreground_task.service.RebootReceiver'
readonly WANT_ACTIONS='android.intent.action.BOOT_COMPLETED android.intent.action.MY_PACKAGE_REPLACED'
readonly STRINGS='fgs_notification_sharing android_resume_notice_title android_resume_notice_body android_resume_notice_channel_name'

# receivers <aapt2 xmltree output> — one "<receiver>\t<exported>\t<action>" row
# per action (and one with an empty action for a receiver without any). An
# element's own attributes are the A: lines one level deeper than its E: line.
receivers() {
  awk '
    function depth(line) { match(line, /^ */); return RLENGTH }
    function attr(line) { if (match(line, /="[^"]*"/)) return substr(line, RSTART + 2, RLENGTH - 3); return "" }
    function flush() { if (rname != "" && !rows) print rname "\t" rexp "\t"; rname = ""; rows = 0 }
    /E: / {
      d = depth($0)
      if (inrecv && d <= rdepth) { flush(); inrecv = 0 }
      if ($0 ~ /E: receiver /) { inrecv = 1; rdepth = d; rexp = "unset"; rname = ""; rows = 0; owner = "receiver"; odepth = d; next }
      if (inrecv && $0 ~ /E: action /) { owner = "action"; odepth = d; next }
      if (inrecv) { owner = "other"; odepth = d }
      next
    }
    inrecv && /A: http:\/\/schemas.android.com\/apk\/res\/android:name\(/ {
      if (owner == "receiver" && depth($0) == odepth + 2) rname = attr($0)
      else if (owner == "action") { print rname "\t" rexp "\t" attr($0); rows++ }
      next
    }
    inrecv && owner == "receiver" && /A: http:\/\/schemas.android.com\/apk\/res\/android:exported\(/ {
      rexp = ($0 ~ /=false|=\(type 0x12\)0x0$/) ? "false" : "true"
      next
    }
    END { if (inrecv) flush() }
  ' "$1"
}

check_merged_manifest() {
  local tree="$1" rows actions exported
  rows="$(receivers "${tree}")"
  if [[ -z "${rows}" ]]; then
    echo "check_apk_resume_wiring: no receiver in ${tree}; it proves nothing." >&2
    return 2
  fi
  actions="$(awk -F'\t' -v r="${BOOT_RECEIVER}" '$1 == r && $3 != "" { print $3 }' <<<"${rows}" | sort | tr '\n' ' ')"
  exported="$(awk -F'\t' -v r="${BOOT_RECEIVER}" '$1 == r { print $2; exit }' <<<"${rows}")"
  local rc=0
  if [[ "${actions}" != "${WANT_ACTIONS} " ]]; then
    echo "R1: ${BOOT_RECEIVER} must filter exactly ${WANT_ACTIONS} (got '${actions:-none}')." >&2
    rc=1
  fi
  if [[ "${exported}" != false ]]; then
    echo "R1: ${BOOT_RECEIVER} must be android:exported=false (got '${exported:-absent}')." >&2
    rc=1
  fi
  if awk -F'\t' -v r="${PLUGIN_RECEIVER}" '$1 == r { found = 1 } END { exit !found }' <<<"${rows}"; then
    echo "R2: ${PLUGIN_RECEIVER} survived the merge — tools:node=\"remove\" regressed." >&2
    rc=1
  fi
  return "${rc}"
}

check_resources() {
  local dump="$1" name rc=0
  grep -qE '^ *resource 0x[0-9a-f]+ ' "${dump}" || {
    echo "check_apk_resume_wiring: ${dump} lists no resource; it proves nothing." >&2
    return 2
  }
  for name in ${STRINGS}; do
    grep -qE "resource 0x[0-9a-f]+ string/${name}( |$)" "${dump}" || {
      echo "R3: string/${name} is not in the APK — the boot receiver or the resume notice reads it by name." >&2
      rc=1
    }
  done
  return "${rc}"
}

self_test() {
  local tmp failures=0 ran=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN
  _case() { # <label> <want rc> <fn> <file>
    local rc=0
    ran=$((ran + 1))
    "$3" "$4" >/dev/null 2>&1 || rc=$?
    if ((rc == $2)); then printf '  PASS %s\n' "$1"; else printf '  FAIL %s (want %s, got %s)\n' "$1" "$2" "${rc}" >&2; failures=$((failures + 1)); fi
  }
  cat >"${tmp}/good.txt" <<'TREE'
N: android=http://schemas.android.com/apk/res/android (line=2)
  E: manifest (line=2)
    E: application (line=60)
      E: service (line=100)
        A: http://schemas.android.com/apk/res/android:name(0x01010003)="com.pravera.flutter_foreground_task.service.ForegroundService" (Raw: "com.pravera.flutter_foreground_task.service.ForegroundService")
      E: receiver (line=150)
        A: http://schemas.android.com/apk/res/android:name(0x01010003)="com.oblivioustech.haven.BootResumeReceiver" (Raw: "com.oblivioustech.haven.BootResumeReceiver")
        A: http://schemas.android.com/apk/res/android:exported(0x01010010)=false
        E: intent-filter (line=153)
          E: action (line=154)
            A: http://schemas.android.com/apk/res/android:name(0x01010003)="android.intent.action.BOOT_COMPLETED" (Raw: "android.intent.action.BOOT_COMPLETED")
          E: action (line=155)
            A: http://schemas.android.com/apk/res/android:name(0x01010003)="android.intent.action.MY_PACKAGE_REPLACED" (Raw: "android.intent.action.MY_PACKAGE_REPLACED")
      E: receiver (line=160)
        A: http://schemas.android.com/apk/res/android:name(0x01010003)="com.pravera.flutter_foreground_task.service.RestartReceiver" (Raw: "com.pravera.flutter_foreground_task.service.RestartReceiver")
        A: http://schemas.android.com/apk/res/android:enabled(0x0101000e)=false
TREE
  _case 'the shipped wiring passes' 0 check_merged_manifest "${tmp}/good.txt"
  sed 's/:exported(0x01010010)=false/:exported(0x01010010)=true/' "${tmp}/good.txt" >"${tmp}/exported.txt"
  _case 'an exported receiver fails' 1 check_merged_manifest "${tmp}/exported.txt"
  sed 's/MY_PACKAGE_REPLACED/QUICKBOOT_POWERON/g' "${tmp}/good.txt" >"${tmp}/actions.txt"
  _case 'a changed action set fails' 1 check_merged_manifest "${tmp}/actions.txt"
  sed 's/service\.RestartReceiver/service.RebootReceiver/g' "${tmp}/good.txt" >"${tmp}/plugin.txt"
  _case 'the plugin RebootReceiver back in the merge fails' 1 check_merged_manifest "${tmp}/plugin.txt"
  grep -v 'BootResumeReceiver' "${tmp}/good.txt" | sed '/E: receiver (line=150)/,/E: receiver (line=160)/{/E: receiver (line=160)/!d}' >"${tmp}/gone.txt"
  _case 'no BootResumeReceiver fails' 1 check_merged_manifest "${tmp}/gone.txt"
  grep -v 'E: receiver\|Receiver' "${tmp}/good.txt" >"${tmp}/none.txt"
  _case 'a manifest with no receiver proves nothing' 2 check_merged_manifest "${tmp}/none.txt"
  {
    echo 'Package name=com.oblivioustech.haven id=7f'
    echo '  type string id=0e entryCount=4'
    for name in ${STRINGS}; do echo "    resource 0x7f0e000${#name} string/${name}"; done
  } >"${tmp}/res.txt"
  _case 'every string the native side reads is in the APK' 0 check_resources "${tmp}/res.txt"
  grep -v 'android_resume_notice_body' "${tmp}/res.txt" >"${tmp}/res-missing.txt"
  _case 'a missing string fails' 1 check_resources "${tmp}/res-missing.txt"
  : >"${tmp}/res-empty.txt"
  _case 'an empty dump proves nothing' 2 check_resources "${tmp}/res-empty.txt"
  if ((failures > 0 || ran != 9)); then
    echo "check_apk_resume_wiring: self-test FAILED (${failures} of ${ran}; 9 expected)" >&2
    return 1
  fi
  echo "check_apk_resume_wiring: self-test OK (9 fixtures)."
}

case "${1:-}" in
  --self-test) self_test ;;
  --merged-manifest)
    [[ -f "${2:-}" ]] || { echo "usage: $0 --merged-manifest <aapt2 xmltree output>" >&2; exit 2; }
    check_merged_manifest "$2"
    echo "OK: the release APK carries BootResumeReceiver as built and not the plugin RebootReceiver."
    ;;
  --resources)
    [[ -f "${2:-}" ]] || { echo "usage: $0 --resources <aapt2 dump resources output>" >&2; exit 2; }
    check_resources "$2"
    echo "OK: the release APK carries every string the resume path reads by name."
    ;;
  *) echo "usage: $0 --self-test | --merged-manifest <file> | --resources <file>" >&2; exit 2 ;;
esac
