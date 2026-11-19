#!/usr/bin/env bash
# CI guard: the four radio modes `MeshRadioConstants.kt` holds as integers are
# the Android SDK's own (docs/BLUETOOTH_MESH_M3_DESIGN.md §G, §N.4).
#
# The radio's pure Kotlin compiles without Android, so that its decisions run
# as JVM tests. It therefore cannot name `ScanSettings.SCAN_MODE_LOW_POWER`:
# it holds the integer, with the constant's name in the comment above it, and
# the adapters pass the integer to the platform as it is. No compiler ties the
# two. A wrong integer is still a valid mode — a scan at full duty, an
# advertisement at the highest rate or power, a connection at the shortest
# interval — and nothing fails but the battery.
#
# So each of PINS is read both ways: the integer of `const val <name> = <n>`
# in the constants' file, whose comment directly above must name the pinned
# platform constant, and the value `javap -constants` prints for that constant
# from the SDK's `android.jar`.
#
# Which lane runs it: `build-check.yml`'s `android-mesh` job, against the
# platform the app compiles with. `check_mesh_radio.sh` (check 8) holds that
# no other file of the radio names a mode.
#
# Usage:
#   bash scripts/ci/check_mesh_radio_constants.sh [<android.jar>]
#   bash scripts/ci/check_mesh_radio_constants.sh --self-test
#
# With no argument the jar is `platforms/android-<n>/android.jar` under
# ANDROID_HOME (or ANDROID_SDK_ROOT), `<n>` the `compileSdk` of
# `haven/android/app/build.gradle.kts`. JAVAP names the class-file reader
# (default `javap`).
#
# Exit codes:
#   0  the four integers are the SDK's (or the self-test passed)
#   1  an integer differs, the file does not hold one, its comment names
#      another constant, or the SDK's class has no such constant
#   2  no jar, no javap, a class javap cannot read, or a file that is missing
#      (misconfiguration)

set -euo pipefail

REPO_ROOT="${REPO_ROOT_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
readonly CONSTANTS='haven/android/app/src/main/kotlin/com/oblivioustech/haven/mesh/core/MeshRadioConstants.kt'
readonly APP_GRADLE='haven/android/app/build.gradle.kts'
readonly JAVAP="${JAVAP:-javap}"
# `<the file's constant> <the SDK's class> <its constant>`: §G's table.
readonly -a PINS=(
  'SCAN_MODE android.bluetooth.le.ScanSettings SCAN_MODE_LOW_POWER'
  'ADVERTISE_MODE android.bluetooth.le.AdvertiseSettings ADVERTISE_MODE_LOW_POWER'
  'ADVERTISE_TX_POWER android.bluetooth.le.AdvertiseSettings ADVERTISE_TX_POWER_MEDIUM'
  'CONNECTION_PRIORITY android.bluetooth.BluetoothGatt CONNECTION_PRIORITY_LOW_POWER'
)

log() {
  printf '\033[1;34m[check_mesh_radio_constants]\033[0m %s\n' "$*"
}

fail() {
  printf '\033[1;31m[check_mesh_radio_constants] FAIL:\033[0m %s\n' "$*" >&2
  FAILED=1
}

misconfigured() {
  echo "ERROR: $*" >&2
  exit 2
}

# The platform jar the app compiles against.
compile_jar() {
  local sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}" level
  [[ -n "${sdk}" ]] || misconfigured "no android.jar named, and neither ANDROID_HOME nor ANDROID_SDK_ROOT is set"
  [[ -f "${REPO_ROOT}/${APP_GRADLE}" ]] || misconfigured "${REPO_ROOT}/${APP_GRADLE} not found"
  level="$(sed -nE 's/^[[:space:]]*compileSdk[[:space:]]*=[[:space:]]*([0-9]+)[[:space:]]*$/\1/p' "${REPO_ROOT}/${APP_GRADLE}")"
  [[ "${level}" =~ ^[0-9]+$ ]] || misconfigured "${APP_GRADLE} does not set 'compileSdk = <n>' exactly once (found: '${level//$'\n'/ }'), so the platform it compiles with cannot be read"
  echo "${sdk}/platforms/android-${level}/android.jar"
}

run_check() { # [<android.jar>]
  local jar="${1:-}" pin name class constant held listing platform
  FAILED=0

  [[ -f "${REPO_ROOT}/${CONSTANTS}" ]] || misconfigured "${REPO_ROOT}/${CONSTANTS} not found"
  [[ -n "${jar}" ]] || jar="$(compile_jar)"
  [[ -f "${jar}" ]] || misconfigured "${jar} not found — is that platform installed?"
  command -v "${JAVAP}" >/dev/null || misconfigured "no '${JAVAP}' to read the SDK's classes with"

  for pin in "${PINS[@]}"; do
    read -r name class constant <<<"${pin}"
    # "<n>" where the line above names the SDK's constant, "<n> unnamed" where
    # it does not; one line for each `const val <name> = <n>`.
    held="$(awk -v name="${name}" -v named="\`${class##*.}.${constant}\`" '
      $0 ~ "^[[:space:]]*const val " name " = -?[0-9]+[[:space:]]*$" { print $NF (index(above, named) ? "" : " unnamed") }
      { above = $0 }' "${REPO_ROOT}/${CONSTANTS}")"
    if [[ ! "${held}" =~ ^-?[0-9]+$ ]]; then
      fail "${CONSTANTS} does not hold 'const val ${name} = <integer>' once, directly under a comment that names \`${class##*.}.${constant}\` (found: '${held//$'\n'/; }'). The integer is the platform's, and the comment is the only thing that says which constant it is."
      continue
    fi
    listing="$("${JAVAP}" -constants -cp "${jar}" "${class}")" || misconfigured "'${JAVAP} -constants -cp ${jar} ${class}' failed — is it the SDK's android.jar?"
    platform="$(sed -nE "s/^[[:space:]]*public static final int ${constant} = (-?[0-9]+);[[:space:]]*\$/\1/p" <<<"${listing}")"
    if [[ ! "${platform}" =~ ^-?[0-9]+$ ]]; then
      fail "${class} of ${jar} has no 'public static final int ${constant}'. ${CONSTANTS##*/} holds ${name} as that constant's integer: one the platform does not have is a mode nobody chose."
    elif [[ "${held}" != "${platform}" ]]; then
      fail "${CONSTANTS##*/} holds ${name} = ${held}, and ${class##*.}.${constant} is ${platform} in ${jar}. The adapters pass the integer on as it is: the radio would run in another mode than §G's table — a higher duty, rate or power — and no test would fail."
    fi
  done

  if (( FAILED )); then
    exit 1
  fi
  log "OK: the ${#PINS[@]} radio modes of ${CONSTANTS##*/} are the integers of the constants they name, in ${jar}."
}

# ---------------------------------------------------------------------------
# Self-test. Each fixture is a tree with the constants' file, the app's Gradle
# script and an SDK whose classes a stand-in for javap prints, run through the
# real entry point.
# ---------------------------------------------------------------------------
self_test() {
  local tmp fails=0 checked=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  # Prints `<jar>.classes/<class>` as `javap -constants` would, and fails for
  # a class the jar does not have.
  cat >"${tmp}/javap" <<'SH'
#!/usr/bin/env bash
[[ "$1 $2" == "-constants -cp" ]] || exit 64
cat "$3.classes/$4"
SH
  chmod +x "${tmp}/javap"

  _tree() { # <tree>
    local t="$1" jar="$1/sdk/platforms/android-36/android.jar"
    mkdir -p "${t}/${CONSTANTS%/*}" "${t}/${APP_GRADLE%/*}" "${jar}.classes"
    : >"${jar}"
    cat >"${t}/${CONSTANTS}" <<'KT'
package com.oblivioustech.haven.mesh.core

object MeshRadioConstants {
    /** `ScanSettings.SCAN_MODE_LOW_POWER`: the lowest duty the platform offers. */
    const val SCAN_MODE = 0

    /** `AdvertiseSettings.ADVERTISE_MODE_LOW_POWER`: the lowest rate. */
    const val ADVERTISE_MODE = 0

    /** `AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM`: lower costs range. */
    const val ADVERTISE_TX_POWER = 2

    /** `BluetoothGatt.CONNECTION_PRIORITY_LOW_POWER`. */
    const val CONNECTION_PRIORITY = 2

    // Not const val SCAN_MODE = 2
    const val ADVERTISE_TIMEOUT_MS = 0
}
KT
    printf 'android {\n    // compileSdk = 30 was long ago.\n    compileSdk = 36\n    defaultConfig {\n        targetSdk = 35\n    }\n}\n' >"${t}/${APP_GRADLE}"
    cat >"${jar}.classes/android.bluetooth.le.ScanSettings" <<'TXT'
Compiled from "ScanSettings.java"
public final class android.bluetooth.le.ScanSettings implements android.os.Parcelable {
  public static final int SCAN_MODE_OPPORTUNISTIC = -1;
  public static final int SCAN_MODE_LOW_POWER = 0;
  public static final int SCAN_MODE_BALANCED = 1;
  public static final int SCAN_MODE_LOW_LATENCY = 2;
  public int getScanMode();
}
TXT
    cat >"${jar}.classes/android.bluetooth.le.AdvertiseSettings" <<'TXT'
Compiled from "AdvertiseSettings.java"
public final class android.bluetooth.le.AdvertiseSettings implements android.os.Parcelable {
  public static final int ADVERTISE_MODE_LOW_POWER = 0;
  public static final int ADVERTISE_MODE_BALANCED = 1;
  public static final int ADVERTISE_TX_POWER_LOW = 1;
  public static final int ADVERTISE_TX_POWER_MEDIUM = 2;
  public static final int ADVERTISE_TX_POWER_HIGH = 3;
}
TXT
    cat >"${jar}.classes/android.bluetooth.BluetoothGatt" <<'TXT'
Compiled from "BluetoothGatt.java"
public final class android.bluetooth.BluetoothGatt implements android.bluetooth.BluetoothProfile {
  public static final int CONNECTION_PRIORITY_BALANCED = 0;
  public static final int CONNECTION_PRIORITY_HIGH = 1;
  public static final int CONNECTION_PRIORITY_LOW_POWER = 2;
  public static final int GATT_SUCCESS = 0;
}
TXT
  }
  _case() { # <label> <want-rc> <want-msg-substring> <tree> [<android.jar>]
    local label="$1" want="$2" msg="$3" tree="$4" got=0 out
    shift 4
    checked=$(( checked + 1 ))
    out="$(env REPO_ROOT_OVERRIDE="${tree}" JAVAP="${JAVAP_OVERRIDE:-${tmp}/javap}" ANDROID_HOME="${HOME_OVERRIDE-${tree}/sdk}" ANDROID_SDK_ROOT="${ROOT_OVERRIDE:-}" bash "${BASH_SOURCE[0]}" "$@" 2>&1)" || got=$?
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

  echo "check_mesh_radio_constants.sh --self-test"
  local t="${tmp}/ok" jar
  _tree "${t}"; jar="${t}/sdk/platforms/android-36/android.jar"
  _case "the four integers, read against the platform the app compiles with, pass" 0 "the 4 radio modes of MeshRadioConstants.kt are the integers" "${t}"
  _case "a jar named by its path passes" 0 "in ${jar}." "${t}" "${jar}"
  HOME_OVERRIDE='' ROOT_OVERRIDE="${t}/sdk" _case "the SDK is found under ANDROID_SDK_ROOT too" 0 '' "${t}"

  # The integers.
  t="${tmp}/kotlin-moved"; _tree "${t}"
  sed -i 's/^    const val SCAN_MODE = 0$/    const val SCAN_MODE = 2/' "${t}/${CONSTANTS}"
  _case "an integer of the file that is not the SDK's fails: here a scan at full duty" 1 'holds SCAN_MODE = 2, and ScanSettings.SCAN_MODE_LOW_POWER is 0' "${t}"

  t="${tmp}/sdk-moved"; _tree "${t}"
  sed -i 's/ADVERTISE_TX_POWER_MEDIUM = 2;/ADVERTISE_TX_POWER_MEDIUM = 5;/' "${t}/sdk/platforms/android-36/android.jar.classes/android.bluetooth.le.AdvertiseSettings"
  _case "an SDK whose constant has another integer fails" 1 'holds ADVERTISE_TX_POWER = 2, and AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM is 5' "${t}"

  t="${tmp}/renamed-comment"; _tree "${t}"
  sed -i 's/`BluetoothGatt.CONNECTION_PRIORITY_LOW_POWER`/`BluetoothGatt.CONNECTION_PRIORITY_HIGH`/' "${t}/${CONSTANTS}"
  _case "a comment that names another constant than the pinned one fails: the file says what it is not" 1 "does not hold 'const val CONNECTION_PRIORITY = <integer>' once" "${t}"

  t="${tmp}/unnamed"; _tree "${t}"
  sed -i '/`AdvertiseSettings.ADVERTISE_MODE_LOW_POWER`/d' "${t}/${CONSTANTS}"
  _case "an integer with no constant named above it fails" 1 "found: '0 unnamed'" "${t}"

  t="${tmp}/gone"; _tree "${t}"
  sed -i '/^    const val SCAN_MODE = 0$/d' "${t}/${CONSTANTS}"
  _case "a mode the file no longer holds fails: the one in a comment is not it" 1 "does not hold 'const val SCAN_MODE = <integer>' once" "${t}"

  t="${tmp}/twice"; _tree "${t}"
  sed -i 's|^    // Not const val SCAN_MODE = 2$|    /** `ScanSettings.SCAN_MODE_LOW_POWER`. */\n    const val SCAN_MODE = 0|' "${t}/${CONSTANTS}"
  _case "a mode held twice fails" 1 "found: '0; 0'" "${t}"

  t="${tmp}/sdk-lacks"; _tree "${t}"
  sed -i '/CONNECTION_PRIORITY_LOW_POWER/d' "${t}/sdk/platforms/android-36/android.jar.classes/android.bluetooth.BluetoothGatt"
  _case "a constant the SDK's class does not have fails" 1 "has no 'public static final int CONNECTION_PRIORITY_LOW_POWER'" "${t}"

  t="${tmp}/sdk-retyped"; _tree "${t}"
  sed -i 's/public static final int SCAN_MODE_LOW_POWER = 0;/public static final long SCAN_MODE_LOW_POWER = 0l;/' "${t}/sdk/platforms/android-36/android.jar.classes/android.bluetooth.le.ScanSettings"
  _case "a constant that is no longer an int fails" 1 "has no 'public static final int SCAN_MODE_LOW_POWER'" "${t}"

  # Misconfiguration.
  t="${tmp}/no-class"; _tree "${t}"
  rm "${t}/sdk/platforms/android-36/android.jar.classes/android.bluetooth.BluetoothGatt"
  _case "a class javap cannot read is a misconfiguration" 2 'failed' "${t}"

  t="${tmp}/other-platform"; _tree "${t}"
  sed -i 's/^    compileSdk = 36$/    compileSdk = 37/' "${t}/${APP_GRADLE}"
  _case "the platform the app compiles with not installed is a misconfiguration: another one is not read in its place" 2 'platforms/android-37/android.jar not found' "${t}"

  t="${tmp}/no-level"; _tree "${t}"
  sed -i 's/^    compileSdk = 36$/    compileSdk = flutter.compileSdkVersion/' "${t}/${APP_GRADLE}"
  _case "a compileSdk that is not a number in the script is a misconfiguration" 2 "does not set 'compileSdk = <n>' exactly once" "${t}"

  t="${tmp}/two-levels"; _tree "${t}"
  printf 'android {\n    compileSdk = 35\n}\n' >>"${t}/${APP_GRADLE}"
  _case "a compileSdk set twice is a misconfiguration" 2 "does not set 'compileSdk = <n>' exactly once" "${t}"

  t="${tmp}/no-sdk"; _tree "${t}"
  HOME_OVERRIDE='' _case "no SDK and no jar named is a misconfiguration" 2 'neither ANDROID_HOME nor ANDROID_SDK_ROOT is set' "${t}"
  _case "a jar that is not there is a misconfiguration" 2 'not found' "${t}" "${t}/absent.jar"
  JAVAP_OVERRIDE="${tmp}/no-such-javap" _case "no javap is a misconfiguration" 2 "to read the SDK's classes with" "${t}"

  t="${tmp}/no-constants"; _tree "${t}"
  rm "${t}/${CONSTANTS}"
  _case "a radio with no file of constants is a misconfiguration" 2 'not found' "${t}"

  if (( fails )); then
    echo "self-test: FAILED" >&2
    return 1
  fi
  if (( checked != 19 )); then
    echo "self-test: ran ${checked} fixture(s), expected exactly 19. A fixture was added or removed without moving the pin." >&2
    return 1
  fi
  echo "self-test: OK (${checked}/19 fixtures)"
}

case "${1:-}" in
  --self-test) self_test ;;
  *)
    [[ $# -le 1 ]] || { echo "usage: $(basename "$0") [<android.jar>] | --self-test" >&2; exit 2; }
    run_check "$@"
    ;;
esac
