#!/usr/bin/env bash
# CI guard: what a built APK's manifest declares of the Bluetooth mesh — all
# of it with the build flag on, none of it with the flag off
# (docs/BLUETOOTH_MESH_M3_DESIGN.md §B.8, F-15, §N.3).
#
# The mesh's permissions are in `haven/android/app/src/mesh/AndroidManifest.xml`,
# which `app/build.gradle.kts` merges into a variant only when the build's Dart
# defines carry `HAVEN_MESH=true`. `check_mesh_radio.sh` reads the sources: no
# other manifest names Bluetooth, and the Gradle switch is written once. This
# reads the artifact, which is what a phone installs and what no way of
# writing the sources gets past — a dependency's own manifest is merged in too.
#
#   * `off` — the APK every lane and every release builds. No attribute value
#     names Bluetooth (a permission old or new, the `bluetooth_le` feature, a
#     broadcast), none names the connected-device foreground-service
#     permission, no service has the `connectedDevice` type, and no component
#     is of the mesh's package. A release with the flag off asks the user for
#     nothing new and gives Play nothing to review.
#
#   * `on` — every entry of the mesh's manifest, once, with its attributes and
#     no other: `BLUETOOTH_SCAN` flagged `neverForLocation` (without the flag
#     Android 12 would want the location permission for a scan, and the mesh
#     never asks for it); `BLUETOOTH_ADVERTISE` and `BLUETOOTH_CONNECT`;
#     `BLUETOOTH` and `BLUETOOTH_ADMIN` up to API 30 and no further;
#     `FOREGROUND_SERVICE_CONNECTED_DEVICE`; and `android.hardware.bluetooth`
#     and `android.hardware.bluetooth_le`, neither required. And nothing more
#     of the mesh: what `off` looks for fails here too in any element that is
#     not one of those entries — another manifest's Bluetooth permission,
#     feature or broadcast. The mesh's service, its receiver and the alias
#     its notices' taps go through are written and in no manifest yet
#     (§O.3): until the push that declares them lists them here, one would
#     fail.
#
#     Then what Play reads, which is not the manifest's text: the two legacy
#     permissions each IMPLY `android.hardware.bluetooth` as a required
#     feature, whatever their `maxSdkVersion`, and only a `<uses-feature>` of
#     that same name takes it back — Bluetooth LE declared not required does
#     not. Implied, it would hide Haven from every phone without Bluetooth.
#     So `aapt2 dump badging`, which applies those rules, must list both
#     Bluetooth features as `uses-feature-not-required`, and no Bluetooth
#     feature as `uses-feature` or `uses-implied-feature`.
#
# How it reads: `aapt2 dump xmltree --file AndroidManifest.xml <apk>`, one
# record an element — its tag and its attributes, a string as written and a
# number in decimal, whichever base it was printed in. The shape was taken
# from aapt2 2.19 over a manifest with these entries:
#
#       E: uses-permission (line=5)
#         A: http://schemas.android.com/apk/res/android:name(0x01010003)="android.permission.BLUETOOTH_SCAN" (Raw: "android.permission.BLUETOOTH_SCAN")
#         A: http://schemas.android.com/apk/res/android:usesPermissionFlags(0x01010644)=0x00010000
#
# A dump that does not hold the INTERNET permission every build of Haven
# declares was not read as Haven's manifest, and is a misconfiguration: a
# printer that changed its shape must not pass `off` by finding nothing. So
# is a badging that names no feature in the shape 2.19 printed:
#
#       feature-group: label=''
#         uses-feature-not-required: name='android.hardware.bluetooth_le'
#         uses-feature: name='android.hardware.bluetooth'
#         uses-implied-feature: name='android.hardware.bluetooth' reason='requested android.permission.BLUETOOTH permission, requested android.permission.BLUETOOTH_ADMIN permission, and targetSdkVersion > 4'
#
# Which lane runs it: `build-check.yml` — `off` on each of the three ABIs'
# debug APK, `on` on the flag-on APK of its `android-mesh` job. A release
# build's manifest is not read.
#
# Usage:
#   bash scripts/ci/check_mesh_manifest.sh <apk> on|off
#   bash scripts/ci/check_mesh_manifest.sh --self-test
#
# AAPT2 names the tool; by default it is the `aapt2` of the newest build-tools
# under ANDROID_HOME (or ANDROID_SDK_ROOT).
#
# Exit codes:
#   0  the manifest declares what the mode says (or the self-test passed)
#   1  `off`: something of the mesh is declared; `on`: an entry is missing,
#      declared twice, or carries other attributes, something of the mesh is
#      declared beside the entries, or Play would read a Bluetooth feature as
#      required
#   2  no aapt2, an APK it cannot read, an empty dump or one that is not
#      Haven's manifest, a badging that names no feature, or wrong arguments
#      (misconfiguration)

set -euo pipefail

readonly ANDROID='http://schemas.android.com/apk/res/android'
readonly MESH_PACKAGE='com.oblivioustech.haven.mesh.'
# `ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE`.
readonly CONNECTED_DEVICE_TYPE=16
# `<tag> <name> <the entry's other attributes, sorted>` for each entry of the
# mesh's manifest. 65536 is `neverForLocation`, the one flag of
# `usesPermissionFlags`.
# A line of `aapt2 dump badging` for a Bluetooth feature: its kind, its name.
readonly BLUETOOTH_FEATURE="^[[:space:]]*(uses-[a-z0-9-]+): name='(android\.hardware\.bluetooth[^']*)'"
readonly -a ENTRIES=(
  'uses-permission android.permission.BLUETOOTH_SCAN usesPermissionFlags=65536'
  'uses-permission android.permission.BLUETOOTH_ADVERTISE'
  'uses-permission android.permission.BLUETOOTH_CONNECT'
  'uses-permission android.permission.BLUETOOTH maxSdkVersion=30'
  'uses-permission android.permission.BLUETOOTH_ADMIN maxSdkVersion=30'
  'uses-permission android.permission.FOREGROUND_SERVICE_CONNECTED_DEVICE'
  'uses-feature android.hardware.bluetooth required=false'
  'uses-feature android.hardware.bluetooth_le required=false'
)

log() {
  printf '\033[1;34m[check_mesh_manifest]\033[0m %s\n' "$*"
}

fail() {
  printf '\033[1;31m[check_mesh_manifest] FAIL:\033[0m %s\n' "$*" >&2
  FAILED=1
}

misconfigured() {
  echo "ERROR: $*" >&2
  exit 2
}

aapt2_path() {
  local sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
  if [[ -n "${AAPT2:-}" ]]; then
    echo "${AAPT2}"
  elif [[ -n "${sdk}" ]]; then
    find "${sdk}/build-tools" -mindepth 2 -maxdepth 2 -type f -name aapt2 2>/dev/null | LC_ALL=C sort -V | tail -n 1 || true
  fi
}

# One line an element of a dump on stdin: its tag, then a tab and
# `<attribute>=<value>` for each attribute, without the namespace, the
# resource id and the raw copy aapt2 prints of a string.
records() {
  awk -v android="${ANDROID}:" '
    function flush() { if (tag != "") print tag attributes; tag = ""; attributes = "" }
    {
      line = $0; sub(/^[[:space:]]+/, "", line)
      if (index(line, "E: ") == 1) {
        flush(); tag = substr(line, 4); sub(/ .*$/, "", tag)
      } else if (index(line, "A: ") == 1 && tag != "") {
        line = substr(line, 4); at = index(line, "=")
        name = substr(line, 1, at - 1); value = substr(line, at + 1)
        if (index(name, android) == 1) name = substr(name, length(android) + 1)
        sub(/\(0x[0-9a-fA-F]+\)$/, "", name)
        if (substr(value, 1, 1) == "\"") { value = substr(value, 2); value = substr(value, 1, index(value, "\"") - 1) }
        else sub(/ .*$/, "", value)
        attributes = attributes "\t" name "=" value
      }
    }
    END { flush() }'
}

# A record's attributes but its name, sorted, a number in decimal.
others() { # <record>
  local field
  local -a out=()
  while IFS= read -r field; do
    [[ -z "${field}" || "${field}" == name=* ]] && continue
    if [[ "${field#*=}" =~ ^(0x[0-9a-fA-F]+|0|[1-9][0-9]*)$ ]]; then
      field="${field%%=*}=$(( ${field#*=} ))"
    fi
    out+=("${field}")
  done < <(cut -sf2- <<<"$1" | tr '\t' '\n' | LC_ALL=C sort)
  echo "${out[*]:-}"
}

run_check() { # <apk> <on|off>
  local apk="$1" mode="$2" aapt2 dump all record field value entry tag name want found type
  local beside why badging features
  FAILED=0

  [[ "${mode}" == on || "${mode}" == off ]] || misconfigured "the mode is 'on' or 'off', not '${mode}'"
  [[ -f "${apk}" ]] || misconfigured "${apk} not found"
  aapt2="$(aapt2_path)"
  [[ -n "${aapt2}" && -x "${aapt2}" ]] || misconfigured "no aapt2 to read the manifest with: AAPT2 is '${AAPT2:-}', and no build-tools/<version>/aapt2 is under ANDROID_HOME or ANDROID_SDK_ROOT ('${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}')"
  dump="$("${aapt2}" dump xmltree --file AndroidManifest.xml "${apk}")" || misconfigured "'${aapt2} dump xmltree --file AndroidManifest.xml ${apk}' failed — is it an APK?"
  all="$(records <<<"${dump}")"
  if ! grep -qE $'^uses-permission\t(.*\t)?name=android\\.permission\\.INTERNET(\t|$)' <<<"${all}"; then
    misconfigured "the manifest read from ${apk} does not hold the INTERNET permission every build of Haven declares: it is empty, another app's, or printed in a shape this check does not read. Nothing was checked."
  fi

  if [[ "${mode}" == off ]]; then
    beside="with the mesh's flag off"
    why="A build without HAVEN_MESH declares nothing of the mesh: the user is asked for nothing new, and Play has nothing to review. If a dependency's own manifest brought it, that dependency is the finding."
  else
    beside="beside the mesh's own entries"
    why="A build with HAVEN_MESH declares the entries of haven/android/app/src/mesh/AndroidManifest.xml and nothing more of the mesh: this is another manifest's, which nobody here chose, or an entry this check has not been told of."
  fi
  while IFS= read -r record; do
    tag="${record%%$'\t'*}"
    if [[ "${mode}" == on ]]; then
      name="$(cut -sf2- <<<"${record}" | tr '\t' '\n' | sed -n 's/^name=//p')"
      for entry in "${ENTRIES[@]}"; do
        [[ "${entry} " == "${tag} ${name} "* ]] && continue 2
      done
    fi
    while IFS= read -r field; do
      value="${field#*=}"
      if grep -qi 'bluetooth' <<<"${value}"; then
        fail "the manifest of ${apk} names Bluetooth ${beside}: <${tag}> ${field}. ${why}"
      elif grep -qi 'connected_device' <<<"${value}"; then
        fail "the manifest of ${apk} names the connected-device foreground-service permission ${beside}: <${tag}> ${field}. ${why}"
      elif [[ "${field}" == "name=${MESH_PACKAGE}"* ]]; then
        fail "the manifest of ${apk} declares a component of the mesh ${beside}: <${tag}> ${field}. A component that is declared can be started — by the system at boot, or by an intent. ${why}"
      elif [[ "${field}" == foregroundServiceType=* ]]; then
        type="${value}"
        if [[ "${type}" =~ ^(0x[0-9a-fA-F]+|0|[1-9][0-9]*)$ ]]; then
          (( (type & CONNECTED_DEVICE_TYPE) == 0 )) || type=connectedDevice
        fi
        if grep -qi 'connectedDevice' <<<"${type}"; then
          fail "the manifest of ${apk} declares a foreground service of the connectedDevice type ${beside}: <${tag}> ${field}. ${why}"
        fi
      fi
    done < <(cut -sf2- <<<"${record}" | tr '\t' '\n')
  done <<<"${all}"
  if [[ "${mode}" == off ]]; then
    (( FAILED )) && exit 1
    log "OK: ${apk}, built without the flag, declares nothing of the mesh — no attribute names Bluetooth or the connected-device permission, no service has that type, and no component is the mesh's."
    return
  fi

  for entry in "${ENTRIES[@]}"; do
    read -r tag name want <<<"${entry}"
    found="$(grep -E "^${tag}"$'\t'"(.*"$'\t'")?name=${name//./\\.}("$'\t'"|\$)" <<<"${all}" || true)"
    if [[ -z "${found}" ]]; then
      fail "the manifest of ${apk}, built with the mesh's flag, has no <${tag}> ${name}. Every entry of haven/android/app/src/mesh/AndroidManifest.xml is merged into such a build: without this one the radio cannot start, or starts on fewer phones than it says."
    elif [[ "$(grep -c . <<<"${found}")" != 1 ]]; then
      fail "the manifest of ${apk} declares <${tag}> ${name} $(grep -c . <<<"${found}") times. One entry, the mesh's own: a second is another manifest's, with attributes nobody here chose."
    elif [[ "$(others "${found}")" != "${want}" ]]; then
      fail "<${tag}> ${name} in the manifest of ${apk} carries '$(others "${found}")' beside its name, and the mesh's entry is '${want}' (a number in decimal; 65536 is neverForLocation). BLUETOOTH_SCAN without that flag makes Android 12 ask for the location permission, which the mesh never requests; a legacy permission without maxSdkVersion=30 stays on every later release; a feature that is required hides Haven from phones without it."
    fi
  done

  # What Play reads: the features aapt2 derives, the implied ones among them.
  badging="$("${aapt2}" dump badging "${apk}")" || misconfigured "'${aapt2} dump badging ${apk}' failed — is it an APK?"
  features="$(grep -E "^[[:space:]]*uses-(implied-)?feature(-not-required)?(-sdk-23)?: name='[^']+'" <<<"${badging}" || true)"
  [[ -n "${features}" ]] || misconfigured "the badging of ${apk} names no feature as 'uses-feature…: name=…': it is empty, or printed in a shape this check does not read. What Play would require was not checked."
  while IFS= read -r field; do
    [[ "${field}" =~ ${BLUETOOTH_FEATURE} ]] || continue
    [[ "${BASH_REMATCH[1]}" == uses-feature-not-required ]] && continue
    fail "aapt2 dump badging of ${apk} lists '${BASH_REMATCH[1]}: ${BASH_REMATCH[2]}': Play reads a Bluetooth feature as required, and hides Haven from every phone without it. BLUETOOTH and BLUETOOTH_ADMIN each imply android.hardware.bluetooth, whatever their maxSdkVersion, and only a <uses-feature android:required=\"false\"> of that same name takes it back."
  done <<<"${features}"
  for entry in "${ENTRIES[@]}"; do
    read -r tag name want <<<"${entry}"
    [[ "${tag}" == uses-feature ]] || continue
    grep -qE "^[[:space:]]*uses-feature-not-required: name='${name//./\\.}'" <<<"${features}" \
      || fail "aapt2 dump badging of ${apk} does not list 'uses-feature-not-required: ${name}'. That line is what tells Play the feature may be missing."
  done
  (( FAILED )) && exit 1
  log "OK: ${apk}, built with the flag, declares the mesh's ${#ENTRIES[@]} entries, each once and with its own attributes, and nothing else of the mesh; Play reads no Bluetooth feature as required."
}

# ---------------------------------------------------------------------------
# Self-test. Each fixture is an APK's name beside the dump a stand-in for
# aapt2 prints for it, run through the real entry point. The dumps have the
# shape aapt2 2.19 printed.
# ---------------------------------------------------------------------------
self_test() {
  local tmp fails=0 checked=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  cat >"${tmp}/aapt2" <<'SH'
#!/usr/bin/env bash
case "$1 $2 $3 $4" in
  'dump xmltree --file AndroidManifest.xml') cat "$5.xmltree" ;;
  "dump badging $3 ") cat "$3.badging" ;;
  *) exit 64 ;;
esac
SH
  chmod +x "${tmp}/aapt2"

  _permission() { # <name> [<attribute>(<id>)=<value>]
    printf '      E: uses-permission (line=9)\n        A: %s:name(0x01010003)="android.permission.%s" (Raw: "android.permission.%s")\n' "${ANDROID}" "$1" "$1"
    [[ -z "${2:-}" ]] || printf '        A: %s:%s\n' "${ANDROID}" "$2"
  }
  _dump() { # <apk> <on|off>
    : >"$1"
    {
      cat <<TXT
N: android=${ANDROID} (line=1)
  E: manifest (line=1)
    A: ${ANDROID}:versionCode(0x0101021b)=1
    A: package="com.oblivioustech.haven" (Raw: "com.oblivioustech.haven")
      E: uses-sdk (line=7)
        A: ${ANDROID}:minSdkVersion(0x0101020c)=24
        A: ${ANDROID}:targetSdkVersion(0x01010270)=35
TXT
      _permission INTERNET
      _permission ACCESS_BACKGROUND_LOCATION
      _permission FOREGROUND_SERVICE
      _permission FOREGROUND_SERVICE_LOCATION
      _permission RECEIVE_BOOT_COMPLETED
      if [[ "$2" == on ]]; then
        _permission BLUETOOTH_SCAN 'usesPermissionFlags(0x01010644)=0x00010000'
        _permission BLUETOOTH_ADVERTISE
        _permission BLUETOOTH_CONNECT
        _permission BLUETOOTH 'maxSdkVersion(0x01010271)=30'
        _permission BLUETOOTH_ADMIN 'maxSdkVersion(0x01010271)=30'
        _permission FOREGROUND_SERVICE_CONNECTED_DEVICE
        cat <<TXT
      E: uses-feature (line=30)
        A: ${ANDROID}:name(0x01010003)="android.hardware.bluetooth" (Raw: "android.hardware.bluetooth")
        A: ${ANDROID}:required(0x0101028e)=false
      E: uses-feature (line=33)
        A: ${ANDROID}:name(0x01010003)="android.hardware.bluetooth_le" (Raw: "android.hardware.bluetooth_le")
        A: ${ANDROID}:required(0x0101028e)=false
TXT
      fi
      cat <<TXT
      E: application (line=40)
        A: ${ANDROID}:label(0x01010001)="Haven" (Raw: "Haven")
        A: ${ANDROID}:name(0x01010003)="com.oblivioustech.haven.HavenApplication" (Raw: "com.oblivioustech.haven.HavenApplication")
          E: activity (line=47)
            A: ${ANDROID}:name(0x01010003)="com.oblivioustech.haven.MainActivity" (Raw: "com.oblivioustech.haven.MainActivity")
            A: ${ANDROID}:exported(0x01010010)=true
          E: service (line=70)
            A: ${ANDROID}:name(0x01010003)="com.pravera.flutter_foreground_task.service.ForegroundService" (Raw: "com.pravera.flutter_foreground_task.service.ForegroundService")
            A: ${ANDROID}:exported(0x01010010)=false
            A: ${ANDROID}:foregroundServiceType(0x01010599)=0x00000008
          E: receiver (line=90)
            A: ${ANDROID}:name(0x01010003)="com.pravera.flutter_foreground_task.service.RebootReceiver" (Raw: "com.pravera.flutter_foreground_task.service.RebootReceiver")
              E: intent-filter (line=93)
                  E: action (line=94)
                    A: ${ANDROID}:name(0x01010003)="android.intent.action.BOOT_COMPLETED" (Raw: "android.intent.action.BOOT_COMPLETED")
TXT
    } >"$1.xmltree"
    cat >"$1.badging" <<'TXT'
package: name='com.oblivioustech.haven' versionCode='1' versionName='1.0.0' platformBuildVersionName='16' platformBuildVersionCode='36' compileSdkVersion='36' compileSdkVersionCodename='16'
sdkVersion:'24'
targetSdkVersion:'35'
uses-permission: name='android.permission.INTERNET'
uses-permission: name='android.permission.BLUETOOTH_SCAN' usesPermissionFlags='neverForLocation'
uses-permission: name='android.permission.BLUETOOTH' maxSdkVersion='30'
uses-permission: name='android.permission.BLUETOOTH_ADMIN' maxSdkVersion='30'
application: label='Haven' icon=''
feature-group: label=''
  uses-feature-not-required: name='android.hardware.bluetooth'
  uses-feature-not-required: name='android.hardware.bluetooth_le'
  uses-feature: name='android.hardware.faketouch'
  uses-implied-feature: name='android.hardware.faketouch' reason='default feature for all apps'
supports-screens: 'small' 'normal' 'large' 'xlarge'
TXT
    [[ "$2" == on ]] || sed -i '/bluetooth/Id' "$1.badging"
  }
  # Replaces the one line of a badging that contains <text> by <replacement>
  # — `\n` a line break; an empty one deletes the line.
  _badge() { # <apk> <text> <replacement>
    awk -v text="$2" -v with="$3" 'index($0, text) { if (with != "") print with; next } { print }' "$1.badging" >"$1.new"
    mv "$1.new" "$1.badging"
  }
  # Replaces the lines of a dump from the one that contains <text> — and the
  # <more> lines after it — by <replacement>, in which awk reads `\n` as a
  # line break; an empty replacement deletes them.
  _edit() { # <apk> <text> <more> <replacement>
    awk -v text="$2" -v more="$3" -v with="$4" '
      skip > 0 { skip--; next }
      index($0, text) && !done { done = 1; skip = more; if (with != "") print with; next }
      { print }' "$1.xmltree" >"$1.new"
    mv "$1.new" "$1.xmltree"
  }
  # Puts <text> — `\n` a line break — before the <application> of a dump.
  _add() { # <apk> <text>
    awk -v text="$2" 'index($0, "E: application ") { print text } { print }' "$1.xmltree" >"$1.new"
    mv "$1.new" "$1.xmltree"
  }
  _case() { # <label> <want-rc> <want-msg-substring> <apk> <mode>
    local label="$1" want="$2" msg="$3" got=0 out
    checked=$(( checked + 1 ))
    out="$(env AAPT2="${AAPT2_OVERRIDE-${tmp}/aapt2}" ANDROID_HOME="${SDK_OVERRIDE:-}" ANDROID_SDK_ROOT= bash "${BASH_SOURCE[0]}" "$4" "$5" 2>&1)" || got=$?
    if [[ "${got}" -ne "${want}" ]]; then
      printf '  \033[1;31mFAIL\033[0m %s (want rc=%d, got rc=%d)\n%s\n' "${label}" "${want}" "${got}" "${out}" >&2
      fails=1
    elif [[ -n "${msg}" && "${out}" != *"${msg}"* ]]; then
      printf '  \033[1;31mFAIL\033[0m %s (rc=%d, but no message matched %q)\n%s\n' "${label}" "${got}" "${msg}" "${out}" >&2
      fails=1
    else
      printf '  \033[1;32mPASS\033[0m %s\n' "${label}"
    fi
  }

  echo "check_mesh_manifest.sh --self-test"
  local apk="${tmp}/off.apk" a="${ANDROID}"
  _dump "${apk}" off
  _case "a flag-off manifest — a location service, a boot receiver, no Bluetooth — passes off" 0 'declares nothing of the mesh' "${apk}" off
  _case "and fails on: every entry of the mesh is missing" 1 'has no <uses-permission> android.permission.BLUETOOTH_SCAN' "${apk}" on
  _case "the feature among them" 1 'has no <uses-feature> android.hardware.bluetooth_le' "${apk}" on

  apk="${tmp}/on.apk"; _dump "${apk}" on
  _case "a flag-on manifest with the mesh's eight entries, whose badging has both Bluetooth features not required, passes on" 0 "declares the mesh's 8 entries" "${apk}" on
  _case "and fails off: a Bluetooth permission is declared" 1 '<uses-permission> name=android.permission.BLUETOOTH_SCAN' "${apk}" off
  _case "the feature too" 1 '<uses-feature> name=android.hardware.bluetooth_le' "${apk}" off
  _case "and the connected-device permission" 1 'names the connected-device foreground-service permission' "${apk}" off

  # Off: each thing of the mesh alone.
  apk="${tmp}/off-legacy.apk"; _dump "${apk}" off
  _add "${apk}" "$(_permission BLUETOOTH 'maxSdkVersion(0x01010271)=30')"
  _case "a legacy Bluetooth permission alone fails off" 1 '<uses-permission> name=android.permission.BLUETOOTH.' "${apk}" off

  apk="${tmp}/off-sdk23.apk"; _dump "${apk}" off
  _add "${apk}" "$(_permission BLUETOOTH_CONNECT | sed 's/uses-permission/uses-permission-sdk-23/')"
  _case "a Bluetooth permission asked under the other tag fails off" 1 '<uses-permission-sdk-23> name=android.permission.BLUETOOTH_CONNECT' "${apk}" off

  apk="${tmp}/off-feature.apk"; _dump "${apk}" off
  _add "${apk}" "      E: uses-feature (line=31)\n        A: ${a}:name(0x01010003)=\"android.hardware.bluetooth\" (Raw: \"android.hardware.bluetooth\")"
  _case "a Bluetooth feature a dependency declares fails off" 1 '<uses-feature> name=android.hardware.bluetooth.' "${apk}" off

  apk="${tmp}/off-broadcast.apk"; _dump "${apk}" off
  _edit "${apk}" 'android.intent.action.BOOT_COMPLETED' 0 "                    A: ${a}:name(0x01010003)=\"android.bluetooth.adapter.action.STATE_CHANGED\" (Raw: \"android.bluetooth.adapter.action.STATE_CHANGED\")"
  _case "a receiver of a Bluetooth broadcast fails off" 1 '<action> name=android.bluetooth.adapter.action.STATE_CHANGED' "${apk}" off

  apk="${tmp}/off-fgs-permission.apk"; _dump "${apk}" off
  _add "${apk}" "$(_permission FOREGROUND_SERVICE_CONNECTED_DEVICE)"
  _case "the connected-device permission alone fails off" 1 'names the connected-device foreground-service permission' "${apk}" off

  apk="${tmp}/off-type.apk"; _dump "${apk}" off
  _edit "${apk}" 'foregroundServiceType' 0 "            A: ${a}:foregroundServiceType(0x01010599)=0x00000018"
  _case "a service whose type has the connectedDevice bit beside location fails off" 1 'of the connectedDevice type' "${apk}" off

  apk="${tmp}/off-type-decimal.apk"; _dump "${apk}" off
  _edit "${apk}" 'foregroundServiceType' 0 "            A: ${a}:foregroundServiceType(0x01010599)=16"
  _case "the same bit printed in decimal fails off" 1 'of the connectedDevice type' "${apk}" off

  apk="${tmp}/off-component.apk"; _dump "${apk}" off
  _edit "${apk}" 'E: receiver ' 0 "          E: receiver (line=88)\n            A: ${a}:name(0x01010003)=\"com.oblivioustech.haven.mesh.MeshReceiver\" (Raw: \"com.oblivioustech.haven.mesh.MeshReceiver\")\n          E: receiver (line=90)"
  _case "a component of the mesh's package fails off" 1 'declares a component of the mesh' "${apk}" off

  # On: each entry's attributes.
  apk="${tmp}/on-located.apk"; _dump "${apk}" on
  _edit "${apk}" 'usesPermissionFlags' 0 ''
  _case "BLUETOOTH_SCAN without neverForLocation fails on" 1 "BLUETOOTH_SCAN in the manifest of ${apk} carries ''" "${apk}" on

  apk="${tmp}/on-other-flag.apk"; _dump "${apk}" on
  _edit "${apk}" 'usesPermissionFlags' 0 "        A: ${a}:usesPermissionFlags(0x01010644)=0x00000001"
  _case "BLUETOOTH_SCAN under another flag fails on" 1 "carries 'usesPermissionFlags=1'" "${apk}" on

  apk="${tmp}/on-decimal.apk"; _dump "${apk}" on
  _edit "${apk}" 'usesPermissionFlags' 0 "        A: ${a}:usesPermissionFlags(0x01010644)=65536"
  _edit "${apk}" 'maxSdkVersion' 0 "        A: ${a}:maxSdkVersion(0x01010271)=0x1e"
  _case "a number printed in the other base reads the same" 0 '' "${apk}" on

  apk="${tmp}/on-legacy-for-good.apk"; _dump "${apk}" on
  _edit "${apk}" 'maxSdkVersion' 0 ''
  _case "a legacy permission with no maxSdkVersion fails on" 1 "<uses-permission> android.permission.BLUETOOTH in the manifest of ${apk} carries ''" "${apk}" on

  apk="${tmp}/on-legacy-short.apk"; _dump "${apk}" on
  _edit "${apk}" 'maxSdkVersion' 0 "        A: ${a}:maxSdkVersion(0x01010271)=28"
  _case "a legacy permission that ends before API 30 fails on" 1 "carries 'maxSdkVersion=28'" "${apk}" on

  apk="${tmp}/on-capped.apk"; _dump "${apk}" on
  _edit "${apk}" '"android.permission.BLUETOOTH_CONNECT"' 0 "$(_permission BLUETOOTH_CONNECT 'maxSdkVersion(0x01010271)=33' | tail -n 2)"
  _case "a new permission given a maxSdkVersion fails on" 1 "BLUETOOTH_CONNECT in the manifest of ${apk} carries 'maxSdkVersion=33'" "${apk}" on

  apk="${tmp}/on-required.apk"; _dump "${apk}" on
  _edit "${apk}" 'required(' 0 "        A: ${a}:required(0x0101028e)=true"
  _case "a feature required fails on" 1 "android.hardware.bluetooth in the manifest of ${apk} carries 'required=true'" "${apk}" on

  apk="${tmp}/on-required-by-default.apk"; _dump "${apk}" on
  _edit "${apk}" 'required(' 0 ''
  _case "a feature with no word on whether it is required fails on: the default is required" 1 "android.hardware.bluetooth in the manifest of ${apk} carries ''" "${apk}" on

  # On: what Play reads. Without the entry of its own name, the two legacy
  # permissions make classic Bluetooth required.
  apk="${tmp}/on-implied.apk"; _dump "${apk}" on
  _edit "${apk}" '"android.hardware.bluetooth"' 1 ''
  sed -i '/E: uses-feature (line=30)/d' "${apk}.xmltree"
  _badge "${apk}" "uses-feature-not-required: name='android.hardware.bluetooth'" "  uses-feature: name='android.hardware.bluetooth'\n  uses-implied-feature: name='android.hardware.bluetooth' reason='requested android.permission.BLUETOOTH permission, requested android.permission.BLUETOOTH_ADMIN permission, and targetSdkVersion > 4'"
  _case "the manifest without classic Bluetooth's own entry fails on: Bluetooth LE not required does not stand in for it" 1 'has no <uses-feature> android.hardware.bluetooth. ' "${apk}" on
  _case "and its badging fails: the legacy permissions imply the feature as required" 1 "lists 'uses-implied-feature: android.hardware.bluetooth'" "${apk}" on
  _case "under both of the lines aapt2 prints for it" 1 "lists 'uses-feature: android.hardware.bluetooth'" "${apk}" on

  apk="${tmp}/on-badged-required.apk"; _dump "${apk}" on
  _badge "${apk}" "uses-feature-not-required: name='android.hardware.bluetooth_le'" "  uses-feature: name='android.hardware.bluetooth_le'"
  _case "a badging that lists Bluetooth LE as required fails on, whatever the manifest's text" 1 "lists 'uses-feature: android.hardware.bluetooth_le'" "${apk}" on
  _case "and does not list it as not required" 1 "does not list 'uses-feature-not-required: android.hardware.bluetooth_le'" "${apk}" on

  apk="${tmp}/on-implied-sdk-23.apk"; _dump "${apk}" on
  _badge "${apk}" "uses-feature: name='android.hardware.faketouch'" "  uses-feature-sdk-23: name='android.hardware.bluetooth_le.extended'\n  uses-implied-feature-sdk-23: name='android.hardware.bluetooth_le.extended' reason='requested a permission'\n  uses-feature: name='android.hardware.faketouch'"
  _case "another Bluetooth feature implied, under the sdk-23 spelling, fails on" 1 "lists 'uses-implied-feature-sdk-23: android.hardware.bluetooth_le.extended'" "${apk}" on

  apk="${tmp}/on-unbadged.apk"; _dump "${apk}" on
  _badge "${apk}" "uses-feature-not-required: name='android.hardware.bluetooth'" ''
  _case "a badging that says nothing of classic Bluetooth fails on: nothing tells Play it may be missing" 1 "does not list 'uses-feature-not-required: android.hardware.bluetooth'" "${apk}" on

  # On: nothing of the mesh beside its entries.
  apk="${tmp}/on-extra-permission.apk"; _dump "${apk}" on
  _add "${apk}" "$(_permission BLUETOOTH_PRIVILEGED)"
  _case "a Bluetooth permission that is none of the mesh's fails on" 1 "names Bluetooth beside the mesh's own entries: <uses-permission> name=android.permission.BLUETOOTH_PRIVILEGED" "${apk}" on

  apk="${tmp}/on-extra-sdk23.apk"; _dump "${apk}" on
  _add "${apk}" "$(_permission BLUETOOTH_CONNECT | sed 's/uses-permission/uses-permission-sdk-23/')"
  _case "one of the mesh's permissions asked again under the other tag fails on" 1 '<uses-permission-sdk-23> name=android.permission.BLUETOOTH_CONNECT' "${apk}" on

  apk="${tmp}/on-extra-broadcast.apk"; _dump "${apk}" on
  _edit "${apk}" 'android.intent.action.BOOT_COMPLETED' 0 "                    A: ${a}:name(0x01010003)=\"android.bluetooth.adapter.action.STATE_CHANGED\" (Raw: \"android.bluetooth.adapter.action.STATE_CHANGED\")"
  _case "a dependency's receiver of a Bluetooth broadcast fails on" 1 '<action> name=android.bluetooth.adapter.action.STATE_CHANGED' "${apk}" on

  apk="${tmp}/on-extra-type.apk"; _dump "${apk}" on
  _edit "${apk}" 'foregroundServiceType' 0 "            A: ${a}:foregroundServiceType(0x01010599)=0x00000018"
  _case "a service of the connectedDevice type fails on until the mesh's own is listed here" 1 "of the connectedDevice type beside the mesh's own entries" "${apk}" on

  apk="${tmp}/on-extra-component.apk"; _dump "${apk}" on
  _edit "${apk}" 'E: receiver ' 0 "          E: receiver (line=88)\n            A: ${a}:name(0x01010003)=\"com.oblivioustech.haven.mesh.MeshReceiver\" (Raw: \"com.oblivioustech.haven.mesh.MeshReceiver\")\n          E: receiver (line=90)"
  _case "a component of the mesh fails on until it is listed here" 1 "declares a component of the mesh beside the mesh's own entries" "${apk}" on

  apk="${tmp}/on-twice.apk"; _dump "${apk}" on
  _add "${apk}" "$(_permission BLUETOOTH_ADVERTISE)"
  _case "an entry declared twice fails on" 1 'BLUETOOTH_ADVERTISE 2 times' "${apk}" on

  apk="${tmp}/on-no-fgs.apk"; _dump "${apk}" on
  _edit "${apk}" 'FOREGROUND_SERVICE_CONNECTED_DEVICE' 0 "        A: ${a}:name(0x01010003)=\"android.permission.FOREGROUND_SERVICE_DATA_SYNC\" (Raw: \"android.permission.FOREGROUND_SERVICE_DATA_SYNC\")"
  _case "the connected-device permission gone fails on" 1 'has no <uses-permission> android.permission.FOREGROUND_SERVICE_CONNECTED_DEVICE' "${apk}" on

  # The tool, found under the SDK: the newest build-tools' own.
  apk="${tmp}/on.apk"
  mkdir -p "${tmp}/sdk/build-tools/9.0.0" "${tmp}/sdk/build-tools/36.1.0"
  printf '#!/usr/bin/env bash\nexit 70\n' >"${tmp}/sdk/build-tools/9.0.0/aapt2"
  cp "${tmp}/aapt2" "${tmp}/sdk/build-tools/36.1.0/aapt2"
  chmod +x "${tmp}/sdk/build-tools/9.0.0/aapt2"
  AAPT2_OVERRIDE='' SDK_OVERRIDE="${tmp}/sdk" _case "with no AAPT2 the newest build-tools' aapt2 under the SDK is the one run" 0 '' "${apk}" on

  # Misconfiguration.
  AAPT2_OVERRIDE='' _case "no AAPT2 and no SDK is a misconfiguration" 2 'no aapt2' "${apk}" on
  AAPT2_OVERRIDE='' SDK_OVERRIDE="${tmp}/no-sdk" _case "an SDK with no build-tools is a misconfiguration" 2 'no aapt2' "${apk}" off
  AAPT2_OVERRIDE="${tmp}/no-such-aapt2" _case "an aapt2 that is not there is a misconfiguration" 2 'no aapt2' "${apk}" off
  _case "an APK that is not there is a misconfiguration" 2 'not found' "${tmp}/absent.apk" off
  : >"${tmp}/undumped.apk"
  _case "a dump that fails is a misconfiguration, not a manifest with nothing in it" 2 'failed' "${tmp}/undumped.apk" off
  apk="${tmp}/empty.apk"; : >"${apk}"; : >"${apk}.xmltree"
  _case "an empty dump is a misconfiguration: off would find nothing in it" 2 'does not hold the INTERNET permission' "${apk}" off
  apk="${tmp}/reshaped.apk"; _dump "${apk}" on
  sed -i 's/^\( *\)A: /\1Attribute: /' "${apk}.xmltree"
  _case "a dump in a shape this check does not read is a misconfiguration, not a pass" 2 'does not hold the INTERNET permission' "${apk}" off
  apk="${tmp}/no-badging.apk"; _dump "${apk}" on; rm "${apk}.badging"
  _case "a badging that fails is a misconfiguration" 2 'dump badging' "${apk}" on
  apk="${tmp}/empty-badging.apk"; _dump "${apk}" on; : >"${apk}.badging"
  _case "an empty badging is a misconfiguration: it would list nothing as required" 2 'names no feature' "${apk}" on
  apk="${tmp}/reshaped-badging.apk"; _dump "${apk}" on
  sed -i "s/uses-\(implied-\)\{0,1\}feature\(-not-required\)\{0,1\}: name='\([^']*\)'/feature '\3'/" "${apk}.badging"
  _case "a badging in a shape this check does not read is a misconfiguration, not a pass" 2 'names no feature' "${apk}" on
  _case "a mode that is neither on nor off is a misconfiguration" 2 "not 'maybe'" "${tmp}/on.apk" maybe

  if (( fails )); then
    echo "self-test: FAILED" >&2
    return 1
  fi
  if (( checked != 49 )); then
    echo "self-test: ran ${checked} fixture(s), expected exactly 49. A fixture was added or removed without moving the pin." >&2
    return 1
  fi
  echo "self-test: OK (${checked}/49 fixtures)"
}

case "${1:-}" in
  --self-test) self_test ;;
  *)
    [[ $# -eq 2 ]] || { echo "usage: $(basename "$0") <apk> on|off | --self-test" >&2; exit 2; }
    run_check "$1" "$2"
    ;;
esac
