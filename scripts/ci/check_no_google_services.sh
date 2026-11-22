#!/usr/bin/env bash
# CI guard: no Google Play Services, Firebase or ML Kit code ships in Haven.
#
# ## Why
#
# Haven promises an app with no Google services, and Zapstore's catalog
# enricher (github.com/zapstore/steroid, internal/scan/rows.go) labels a
# release "Google services" from the APK itself: a class the dex DEFINES or a
# manifest component / meta-data name under a Play Services package
# (com/google/android/gms/...) or Firebase Messaging. Until 2026-11 two
# plugins put them there: geolocator_android linked play-services-location,
# and mobile_scanner bundled ML Kit, which pulls play-services-basement/base/
# tasks, firebase-components and the datatransport telemetry uploader. Haven
# now ships a patched geolocator_android (third_party/geolocator_android) and
# its own QR scanner; this guard is what fails if either comes back.
#
# The denied prefixes are wider than Zapstore's trigger on purpose: ML Kit
# (com/google/mlkit, com/google/android/odml), Firebase and datatransport are
# Google services too, and the last one uploads usage logs to Google.
# Guava, Tink, Gson, protobuf, androidx and Material are open-source libraries
# under com/google that talk to nobody, and are allowed.
#
# One manifest entry is allowed: image_picker_android declares the DISABLED
# service com.google.android.gms.metadata.ModuleDependencies (and its intent
# action ...metadata.MODULE_DEPENDENCIES), whose class is in no dex. It is a marker asking Play Services, where installed, to install
# Android's back-ported photo picker on Android 11-12; no Google code ships
# with it, and Zapstore's corpus has no key it matches (it lists gms
# sub-packages such as common and location, never gms/metadata). Removing it
# would leave those phones on the document picker. Its class in the dex fails.
#
# ## Modes
#
#   check_no_google_services.sh <apk>...   dexdump + aapt2 from the newest
#       $ANDROID_HOME/build-tools/*: every class the dex defines and every
#       manifest android:name. Run on the release APKs the Android launch gate
#       launched (launch-gate-android.yml), which are the bytes that ship.
#   check_no_google_services.sh --static   the source tree: no Gradle file
#       names a denied artifact group, pubspec.lock resolves geolocator_android
#       to the patched copy and holds no plugin known to bundle one, and the
#       patched copy still has no Play Services code (repo-guards.yml).
#   check_no_google_services.sh --self-test   the recorded v0.1.13/v0.1.14
#       release dumps (which shipped ML Kit) fail, the same dumps with every
#       Google line removed pass, an unparsable dump is refused, and each
#       --static rule fails when its violation is planted in a copy.
#
# Exit: 0 clean, 1 a Google services class/entry/dependency found,
#       2 cannot vouch (missing tool, unparsable dump, missing file).

set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
readonly REPO_ROOT
readonly FIXTURE_DIR="${SCRIPT_DIR}/fixtures/apk_loadable"

# Class descriptors (dex form) and manifest names (dotted form) denied.
readonly DENIED_DEX_RE='^L(com/google/android/gms/|com/google/firebase/|com/google/mlkit/|com/google/android/datatransport/|com/google/android/odml/|com/google/android/play/core/)'
readonly DENIED_NAME_RE='^(com\.google\.android\.gms\.|com\.google\.firebase\.|com\.google\.mlkit\.|com\.google\.android\.datatransport\.|com\.google\.android\.odml\.|com\.google\.android\.play\.core\.)'
# Maven groups denied in Gradle files, and pub packages that bundle them.
readonly ALLOWED_NAME_RE='^com\.google\.android\.gms\.metadata\.(ModuleDependencies|MODULE_DEPENDENCIES)$'
readonly DENIED_GRADLE_RE='com\.google\.(android\.gms|firebase|mlkit|android\.datatransport|android\.odml|android\.play):'
readonly DENIED_PUB_RE='^  (mobile_scanner|google_mlkit_[a-z_]+|firebase_[a-z_]+|google_mobile_ads|google_maps_flutter[a-z_]*|google_sign_in[a-z_]*|in_app_review|in_app_update):$'

# check_dumps <dexdump text> <aapt2 xmltree text> — prints one FAIL line per
# denied class or manifest name; rc 0 clean, 1 found, 2 unparsable.
check_dumps() {
  local dex="$1" manifest="$2" classes names found
  classes="$(sed -n "s/^  Class descriptor  : '\\(L[^']*;\\)'\$/\\1/p" "${dex}")"
  if [[ -z "${classes}" ]]; then
    echo "VACUOUS the dexdump output lists no class descriptor" >&2
    return 2
  fi
  if ! grep -q '^ *E: manifest (line=[0-9]*)$' "${manifest}"; then
    echo "VACUOUS the manifest dump has no manifest element" >&2
    return 2
  fi
  names="$(sed -n 's/^ *A: http:\/\/schemas\.android\.com\/apk\/res\/android:name(0x[0-9a-f]*)="\([^"]*\)".*$/\1/p' "${manifest}")"
  found=0
  while IFS= read -r c; do
    [[ "${c}" =~ ${DENIED_DEX_RE} ]] || continue
    echo "FAIL dex defines ${c}"
    found=1
  done <<<"${classes}"
  while IFS= read -r n; do
    # A Firebase components key names its class after the colon.
    [[ "${n}" =~ ${ALLOWED_NAME_RE} ]] && continue
    [[ "${n}" =~ ${DENIED_NAME_RE} || "${n#*:}" =~ ${DENIED_NAME_RE} ]] || continue
    echo "FAIL manifest names ${n}"
    found=1
  done <<<"${names}"
  return "${found}"
}

resolve_tools() {
  local sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}" newest
  if [[ -z "${sdk}" || ! -d "${sdk}/build-tools" ]]; then
    echo "check_no_google_services: no \$ANDROID_HOME/build-tools; cannot read the dex." >&2
    return 2
  fi
  newest="$(for d in "${sdk}"/build-tools/*/; do [[ -d "${d}" ]] && basename "${d}"; done | sort -V | tail -n 1)"
  DEXDUMP="${sdk}/build-tools/${newest}/dexdump"
  AAPT2="${sdk}/build-tools/${newest}/aapt2"
  if [[ ! -x "${DEXDUMP}" || ! -x "${AAPT2}" ]]; then
    echo "check_no_google_services: dexdump/aapt2 missing in build-tools ${newest}." >&2
    return 2
  fi
}

check_apks() {
  local rc=0 apk tmp dexes r
  resolve_tools || return 2
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp}"' RETURN
  for apk in "$@"; do
    if [[ ! -f "${apk}" ]]; then
      echo "check_no_google_services: no such APK: ${apk}" >&2
      return 2
    fi
    rm -rf "${tmp:?}"/*
    unzip -qo "${apk}" 'classes*.dex' -d "${tmp}/dex" || { echo "check_no_google_services: ${apk} has no classes*.dex" >&2; return 2; }
    dexes=("${tmp}"/dex/classes*.dex)
    "${DEXDUMP}" "${dexes[@]}" >"${tmp}/dexdump.txt" 2>/dev/null || { echo "check_no_google_services: dexdump failed on ${apk}" >&2; return 2; }
    "${AAPT2}" dump xmltree --file AndroidManifest.xml "${apk}" >"${tmp}/manifest.txt" || { echo "check_no_google_services: aapt2 failed on ${apk}" >&2; return 2; }
    r=0
    check_dumps "${tmp}/dexdump.txt" "${tmp}/manifest.txt" || r=$?
    case "${r}" in
      0) echo "ok ${apk##*/}: no Google services class or manifest entry (${#dexes[@]} dex)" ;;
      1) echo "FAIL ${apk##*/}: ships Google services code (above)"; rc=1 ;;
      *) return 2 ;;
    esac
  done
  return "${rc}"
}

# check_static <repo root>
check_static() {
  local root="$1" rc=0 lock="$1/haven/pubspec.lock" geo="$1/third_party/geolocator_android" hits f
  for f in "${lock}" "${geo}/android/build.gradle" "${geo}/HAVEN_PATCH.md"; do
    [[ -f "${f}" ]] || { echo "check_no_google_services: missing ${f#"${root}"/}" >&2; return 2; }
  done
  hits="$(grep -rnE --include='*.gradle' --include='*.gradle.kts' --include='*.toml' "${DENIED_GRADLE_RE}" \
            "${root}/haven/android" "${root}/haven/rust_builder" "${geo}/android" 2>/dev/null || true)"
  if [[ -n "${hits}" ]]; then
    echo "FAIL a Gradle file names a Google services artifact:"; echo "${hits/#"${root}"\//}"; rc=1
  fi
  hits="$(grep -nE "${DENIED_PUB_RE}" "${lock}" || true)"
  if [[ -n "${hits}" ]]; then
    echo "FAIL pubspec.lock resolves a plugin that bundles Google services:"; echo "${hits}"; rc=1
  fi
  if ! awk '/^  geolocator_android:$/{f=1;next} f&&/^  [^ ]/{exit} f' "${lock}" | grep -q 'path: "../third_party/geolocator_android"'; then
    echo "FAIL pubspec.lock does not resolve geolocator_android to third_party/geolocator_android (upstream links play-services-location)"; rc=1
  fi
  hits="$(grep -rln 'com\.google\.android\.gms\|FusedLocationClient' "${geo}/android" || true)"
  if [[ -n "${hits}" ]]; then
    echo "FAIL the patched geolocator_android has Play Services code again:"; echo "${hits/#"${root}"\//}"; rc=1
  fi
  # The scanner that replaced ML Kit must stay wired: unregistered, or out of
  # the Xcode project, it builds fine and every scan reads "camera unavailable".
  if [[ "$(grep -c 'HavenQrScannerHandler\.swift' "${root}/haven/ios/Runner.xcodeproj/project.pbxproj" 2>/dev/null)" != 4 ]]; then
    echo "FAIL HavenQrScannerHandler.swift is not in the Runner target (want 4 pbxproj references)"; rc=1
  fi
  if ! grep -q 'qrScannerHandler\.register(with: registrar)' "${root}/haven/ios/Runner/AppDelegate.swift" 2>/dev/null; then
    echo "FAIL AppDelegate.swift does not register the QR scanner"; rc=1
  fi
  if ! grep -q 'QrScanner(this)\.also { it\.register(flutterEngine) }' "${root}/haven/android/app/src/main/kotlin/com/oblivioustech/haven/MainActivity.kt" 2>/dev/null; then
    echo "FAIL MainActivity.kt does not register the QR scanner"; rc=1
  fi
  [[ "${rc}" -eq 0 ]] && echo "ok: no Google services dependency in the source tree"
  return "${rc}"
}

self_test() {
  local tmp fails=0 v r
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp}"' RETURN
  # expect <name> <want rc> <command...>
  expect() {
    local name="$1" want="$2" got=0; shift 2
    "$@" >"${tmp}/out" 2>&1 || got=$?
    if [[ "${got}" -eq "${want}" ]]; then echo "  ok   ${name}"; else
      echo "  FAIL ${name}: rc ${got}, want ${want}"; sed 's/^/       /' "${tmp}/out"; fails=$((fails + 1)); fi
  }
  for v in v0.1.13 v0.1.14; do
    grep -v '^#' "${FIXTURE_DIR}/${v}.dexdump.txt" >"${tmp}/${v}.dex"
    grep -v '^#' "${FIXTURE_DIR}/${v}.manifest.txt" >"${tmp}/${v}.man"
    expect "${v} release (ML Kit) fails" 1 check_dumps "${tmp}/${v}.dex" "${tmp}/${v}.man"
    r=0; check_dumps "${tmp}/${v}.dex" "${tmp}/${v}.man" >"${tmp}/why" 2>&1 || r=$?
    for want in 'FAIL dex defines Lcom/google/mlkit/vision/barcode/internal/BarcodeRegistrar;' \
                'FAIL manifest names com.google.mlkit.common.internal.MlKitComponentDiscoveryService' \
                'FAIL manifest names com.google.firebase.components:com.google.mlkit.vision.barcode.internal.BarcodeRegistrar'; do
      if grep -qxF "${want}" "${tmp}/why"; then echo "  ok   ${v} names: ${want#FAIL }"; else
        echo "  FAIL ${v} did not report: ${want}"; fails=$((fails + 1)); fi
    done
    # Remove each denied class block's descriptor line and each denied name.
    grep -vE "Class descriptor  : 'L(com/google/(android/gms|firebase|mlkit|android/datatransport|android/odml|android/play/core))/" \
      "${tmp}/${v}.dex" >"${tmp}/${v}.clean.dex"
    awk '/android:name\(0x[0-9a-f]+\)="(com\.google\.firebase\.components:)?com\.google\.(android\.gms|firebase|mlkit)\./ \
           && !/(ModuleDependencies|MODULE_DEPENDENCIES)"/ { next } { print }' "${tmp}/${v}.man" >"${tmp}/${v}.clean.man"
    if grep -q 'ModuleDependencies' "${tmp}/${v}.clean.man" && grep -q 'MODULE_DEPENDENCIES' "${tmp}/${v}.clean.man"; then echo "  ok   ${v} cleaned manifest keeps the allowed photo-picker marker"; else
      echo "  FAIL ${v} cleaned manifest lost the allowed marker, so its pass proves nothing about the allowance"; fails=$((fails + 1)); fi
    expect "${v} with the Google lines removed passes" 0 check_dumps "${tmp}/${v}.clean.dex" "${tmp}/${v}.clean.man"
  done
  printf 'Opened x\n' >"${tmp}/empty.dex"
  expect "a dexdump with no class is refused" 2 check_dumps "${tmp}/empty.dex" "${tmp}/v0.1.14.clean.man"
  printf 'N: android=x\n' >"${tmp}/empty.man"
  expect "a manifest dump with no manifest is refused" 2 check_dumps "${tmp}/v0.1.14.clean.dex" "${tmp}/empty.man"
  printf "  Class descriptor  : 'Lcom/google/android/gms/common/GoogleApiAvailability;'\n" >"${tmp}/gms.dex"
  expect "a Play Services class fails" 1 check_dumps "${tmp}/gms.dex" "${tmp}/v0.1.14.clean.man"
  printf "  Class descriptor  : 'Lcom/google/android/gms/metadata/ModuleDependencies;'\n" >"${tmp}/md.dex"
  expect "the photo-picker marker's class in the dex fails" 1 check_dumps "${tmp}/md.dex" "${tmp}/v0.1.14.clean.man"
  printf "  Class descriptor  : 'Lcom/google/common/util/concurrent/ListenableFuture;'\n  Class descriptor  : 'Lcom/google/crypto/tink/Aead;'\n" >"${tmp}/oss.dex"
  expect "Guava and Tink are allowed" 0 check_dumps "${tmp}/oss.dex" "${tmp}/v0.1.14.clean.man"

  # --static over a copy of the tree, then one planted violation per rule.
  mkdir -p "${tmp}/repo/haven/android" "${tmp}/repo/haven/rust_builder" "${tmp}/repo/third_party"
  cp "${REPO_ROOT}/haven/pubspec.lock" "${tmp}/repo/haven/"
  cp -R "${REPO_ROOT}/haven/android/app" "${tmp}/repo/haven/android/"
  cp "${REPO_ROOT}"/haven/android/*.kts "${tmp}/repo/haven/android/"
  cp -R "${REPO_ROOT}/third_party/geolocator_android" "${tmp}/repo/third_party/"
  mkdir -p "${tmp}/repo/haven/ios/Runner.xcodeproj" "${tmp}/repo/haven/ios/Runner"
  cp "${REPO_ROOT}/haven/ios/Runner.xcodeproj/project.pbxproj" "${tmp}/repo/haven/ios/Runner.xcodeproj/"
  cp "${REPO_ROOT}/haven/ios/Runner/AppDelegate.swift" "${tmp}/repo/haven/ios/Runner/"
  expect "--static passes on this tree" 0 check_static "${tmp}/repo"
  _mutant() { # <name> <command run inside a fresh copy>
    rm -rf "${tmp}/m"; cp -R "${tmp}/repo" "${tmp}/m"
    ( cd "${tmp}/m" && eval "$2" )
    expect "--static fails: $1" 1 check_static "${tmp}/m"
  }
  _mutant "an app Gradle file adds ML Kit" \
    'printf "\ndependencies { implementation(\"com.google.mlkit:barcode-scanning:17.3.0\") }\n" >> haven/android/app/build.gradle.kts'
  _mutant "the patched geolocator links Play Services again" \
    "sed -i \"s|implementation 'androidx.core:core|implementation 'com.google.android.gms:play-services-location:21.2.0'\\n    implementation 'androidx.core:core|\" third_party/geolocator_android/android/build.gradle"
  _mutant "pubspec.lock resolves mobile_scanner" \
    'printf "  mobile_scanner:\n    dependency: \"direct main\"\n" >> haven/pubspec.lock'
  _mutant "geolocator_android resolves from pub.dev" \
    'sed -i "s|path: \"../third_party/geolocator_android\"|name: geolocator_android|" haven/pubspec.lock'
  _mutant "the fused client is restored in the patched copy" \
    'touch third_party/geolocator_android/android/src/main/java/com/baseflow/geolocator/location/FusedLocationClient.java && echo "class FusedLocationClient {}" > third_party/geolocator_android/android/src/main/java/com/baseflow/geolocator/location/FusedLocationClient.java'
  _mutant "the iOS scanner is left out of the Xcode project" \
    "sed -i '/HavenQrScannerHandler.swift in Sources/d' haven/ios/Runner.xcodeproj/project.pbxproj"
  _mutant "AppDelegate no longer registers the scanner" \
    "sed -i 's/qrScannerHandler.register(with: registrar)/_ = registrar/' haven/ios/Runner/AppDelegate.swift"
  _mutant "MainActivity no longer registers the scanner" \
    "sed -i 's/QrScanner(this).also { it.register(flutterEngine) }/QrScanner(this)/' haven/android/app/src/main/kotlin/com/oblivioustech/haven/MainActivity.kt"
  rm -rf "${tmp}/m"; cp -R "${tmp}/repo" "${tmp}/m"; rm "${tmp}/m/third_party/geolocator_android/HAVEN_PATCH.md"
  expect "--static refuses a tree without the patched copy" 2 check_static "${tmp}/m"

  if [[ "${fails}" -gt 0 ]]; then echo "self-test: ${fails} case(s) failed"; return 1; fi
  echo "self-test: all cases passed"
}

case "${1:-}" in
  --self-test) self_test ;;
  --static) check_static "${REPO_ROOT}" ;;
  ''|-*) echo "usage: $0 <apk>... | --static | --self-test" >&2; exit 2 ;;
  *) check_apks "$@" ;;
esac
