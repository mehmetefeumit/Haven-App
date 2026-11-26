#!/usr/bin/env bash
# CI guard: nothing of Haven's leaves an Android device by backup or by
# device-to-device transfer.
#
# The app's data directory holds what a backup must never carry: the
# identity key's ciphertext, the SQLCipher databases, the user's
# preferences. The manifest's
# android:allowBackup="false" stops cloud backup everywhere and stops
# device-to-device (D2D) transfer on Android 11 and lower. On Android 12+,
# for an app that targets API 31+ (Haven targets 35), some manufacturers'
# devices still run D2D transfers, which follow only the
# android:dataExtractionRules file — and a section that file leaves out
# allows everything
# (https://developer.android.com/about/versions/12/behavior-changes-12#backup-restore,
# https://developer.android.com/identity/data/autobackup). So:
#
#   N1  <application> declares android:allowBackup="false"
#   N2  <application> names an android:dataExtractionRules @xml resource that
#       exists
#   N3  that file's <cloud-backup> and <device-transfer> sections each exist
#       once, include nothing, and exclude path "." in every domain
#   N4  it has no <cross-platform-transfer> section: that transfer (Android 16
#       QPR2+) is opt-in, and only such a section opts in
#
# android:fullBackupContent is not required: it only scopes a backup that
# allowBackup="false" already stops on the versions that read it (11 and
# lower), and Android 12+ ignores it once dataExtractionRules is set.
#
# Modes:
#   check_android_no_backup.sh               the repository's manifest
#   check_android_no_backup.sh --self-test   hermetic fixtures
#
# Exit: 0 pass, 1 a violation, 2 usage or a missing tool.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MAIN_DIR="${REPO_ROOT}/haven/android/app/src/main"

# An attribute in the android namespace: a `tools:` one is a build-time
# instruction, never the app's setting.
readonly ANDROID_NS="http://schemas.android.com/apk/res/android"
android_attr() { echo "@*[local-name()='$1' and namespace-uri()='${ANDROID_NS}']"; }

readonly DOMAINS=(root file database sharedpref external
  device_root device_file device_database device_sharedpref)

# xp <file> <xpath> — the string value, or empty; xcount — a count, or 0.
xp() { xmllint --xpath "string($2)" "$1" 2>/dev/null || true; }
xcount() { xmllint --xpath "count($2)" "$1" 2>/dev/null || echo 0; }

# check <main source dir>: AndroidManifest.xml and res/xml under it.
check() {
  local dir="$1" manifest="$1/AndroidManifest.xml" fail=0 app rules name file section domain n
  if ! xmllint --noout "${manifest}" 2>/dev/null; then
    echo "FAIL the manifest is missing or not well-formed XML: ${manifest}" >&2
    return 1
  fi
  app="/manifest/application"
  if [[ "$(xp "${manifest}" "${app}/$(android_attr allowBackup)")" != "false" ]]; then
    echo "FAIL N1 <application> does not declare android:allowBackup=\"false\"" >&2
    fail=1
  fi
  rules="$(xp "${manifest}" "${app}/$(android_attr dataExtractionRules)")"
  if [[ ! "${rules}" =~ ^@xml/([A-Za-z0-9_]+)$ ]]; then
    echo "FAIL N2 <application> names no android:dataExtractionRules @xml resource (got '${rules}')" >&2
    return 1
  fi
  name="${BASH_REMATCH[1]}"
  file="${dir}/res/xml/${name}.xml"
  if ! xmllint --noout "${file}" 2>/dev/null; then
    echo "FAIL N2 ${rules} is missing or not well-formed XML: ${file}" >&2
    return 1
  fi
  for section in cloud-backup device-transfer; do
    n="$(xcount "${file}" "/data-extraction-rules/${section}")"
    if [[ "${n}" != "1" ]]; then
      echo "FAIL N3 <${section}> appears ${n} times, not once: a missing section allows everything" >&2
      fail=1
      continue
    fi
    if [[ "$(xcount "${file}" "/data-extraction-rules/${section}/include")" != "0" ]]; then
      echo "FAIL N3 <${section}> includes something" >&2
      fail=1
    fi
    for domain in "${DOMAINS[@]}"; do
      n="$(xcount "${file}" "/data-extraction-rules/${section}/exclude[@domain='${domain}'][@path='.' or @path='./']")"
      if [[ "${n}" == "0" ]]; then
        echo "FAIL N3 <${section}> does not exclude the whole '${domain}' domain (path \".\")" >&2
        fail=1
      fi
    done
  done
  if [[ "$(xcount "${file}" "//cross-platform-transfer")" != "0" ]]; then
    echo "FAIL N4 the rules opt in to a cross-platform transfer" >&2
    fail=1
  fi
  return "${fail}"
}

self_test() {
  local tmp failures=0 cases=0
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp}"' RETURN

  _case() { # <name> <want rc> <command...>
    local name="$1" want="$2" got=0
    shift 2
    cases=$((cases + 1))
    "$@" >/dev/null 2>&1 || got=$?
    if [[ "${got}" != "${want}" ]]; then
      echo "self-test FAILED [${name}]: expected exit ${want}, got ${got}" >&2
      failures=$((failures + 1))
    fi
  }

  # fixture <name>: a copy of the repository's manifest and rules to mutate.
  fixture() {
    mkdir -p "${tmp}/$1/res/xml"
    cp "${MAIN_DIR}/AndroidManifest.xml" "${tmp}/$1/"
    cp "${MAIN_DIR}/res/xml/data_extraction_rules.xml" "${tmp}/$1/res/xml/"
    echo "${tmp}/$1"
  }
  local d
  d="$(fixture ok)"
  _case "the repository's files pass" 0 check "${d}"

  d="$(fixture backup-on)"
  sed -i 's/android:allowBackup="false"/android:allowBackup="true"/' "${d}/AndroidManifest.xml"
  _case "allowBackup=true fails" 1 check "${d}"

  d="$(fixture backup-unset)"
  sed -i '/android:allowBackup="false"/d' "${d}/AndroidManifest.xml"
  _case "allowBackup left at its default fails" 1 check "${d}"

  d="$(fixture backup-tools-only)"
  sed -i 's/android:allowBackup="false"/tools:allowBackup="false"/' "${d}/AndroidManifest.xml"
  _case "allowBackup=false in the tools namespace only fails" 1 check "${d}"

  d="$(fixture rules-tools-only)"
  sed -i 's/android:dataExtractionRules=/tools:dataExtractionRules=/' "${d}/AndroidManifest.xml"
  _case "dataExtractionRules in the tools namespace only fails" 1 check "${d}"

  d="$(fixture no-rules)"
  sed -i '/android:dataExtractionRules=/d' "${d}/AndroidManifest.xml"
  _case "a manifest without dataExtractionRules fails" 1 check "${d}"

  d="$(fixture commented-rules)"
  sed -i 's|^\(\s*\)android:dataExtractionRules="@xml/data_extraction_rules"|\1|' "${d}/AndroidManifest.xml"
  sed -i 's|^\(\s*\)<application|\1<!-- android:dataExtractionRules="@xml/data_extraction_rules" -->\n&|' "${d}/AndroidManifest.xml"
  _case "dataExtractionRules named only in a comment fails" 1 check "${d}"

  d="$(fixture missing-file)"
  rm "${d}/res/xml/data_extraction_rules.xml"
  _case "a rules resource that does not exist fails" 1 check "${d}"

  d="$(fixture no-transfer)"
  sed -i '/<device-transfer>/,/<\/device-transfer>/d' "${d}/res/xml/data_extraction_rules.xml"
  _case "rules without a device-transfer section fail" 1 check "${d}"

  d="$(fixture no-cloud)"
  sed -i '/<cloud-backup>/,/<\/cloud-backup>/d' "${d}/res/xml/data_extraction_rules.xml"
  _case "rules without a cloud-backup section fail" 1 check "${d}"

  d="$(fixture one-domain-kept)"
  sed -i '/<device-transfer>/,/<\/device-transfer>/{/domain="sharedpref"/d}' "${d}/res/xml/data_extraction_rules.xml"
  _case "a transfer that keeps one domain fails" 1 check "${d}"

  d="$(fixture partial-path)"
  sed -i '0,/domain="database" path="."/s//domain="database" path="mls.db"/' "${d}/res/xml/data_extraction_rules.xml"
  _case "excluding one file instead of the domain fails" 1 check "${d}"

  d="$(fixture include)"
  sed -i 's|<device-transfer>|<device-transfer>\n        <include domain="file" path="." />|' "${d}/res/xml/data_extraction_rules.xml"
  _case "a section that includes something fails" 1 check "${d}"

  d="$(fixture cross-platform)"
  sed -i 's|</data-extraction-rules>|    <cross-platform-transfer platform="ios" />\n</data-extraction-rules>|' "${d}/res/xml/data_extraction_rules.xml"
  _case "a cross-platform opt-in fails" 1 check "${d}"

  d="$(fixture malformed)"
  printf '<data-extraction-rules>\n' >"${d}/res/xml/data_extraction_rules.xml"
  _case "malformed rules fail" 1 check "${d}"

  if ((failures > 0)); then
    echo "Android no-backup guard: self-test FAILED (${failures} of ${cases})" >&2
    return 1
  fi
  echo "Android no-backup guard: self-test OK (${cases} fixtures)."
}

need_xmllint() {
  command -v xmllint >/dev/null 2>&1 \
    || { echo "ERROR: xmllint (libxml2-utils) is required by this guard" >&2; exit 2; }
}

case "${1:-}" in
  --self-test) need_xmllint; self_test ;;
  "")
    need_xmllint
    check "${MAIN_DIR}"
    echo "OK: Android backup and device-to-device transfer carry nothing of Haven's."
    ;;
  *) echo "usage: $0 [--self-test]" >&2; exit 2 ;;
esac
