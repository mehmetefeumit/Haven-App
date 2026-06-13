#!/usr/bin/env bash
# Build a RELEASE Haven artifact with the Stadia Maps API key injected and Dart
# obfuscation enabled. This is the BLESSED release path: a bare
# `flutter build --release` is gated to fail (see android/app/build.gradle.kts
# and ios Runner Run Script) and tells you to use this script instead.
#
# What it does that a bare `flutter build` cannot:
#   * injects STADIA_API_KEY via --dart-define-from-file (kept off argv/history)
#   * forces --obfuscate --split-debug-info (the flutter CLI has no project
#     default for these; they MUST be passed on the command line)
#   * runs the no-committed-secrets guard first (fail fast)
#   * exports HAVEN_RELEASE_WRAPPER=1 so the Gradle/Xcode release gate passes
#
# Usage:
#   scripts/build_release.sh apk         # release APK   (build/app/outputs/flutter-apk/app-release.apk)
#   scripts/build_release.sh appbundle   # Play .aab     (build/app/outputs/bundle/release/app-release.aab)
#   scripts/build_release.sh ios         # iOS release   (no codesign; build/ios/iphoneos)
#   scripts/build_release.sh ipa         # iOS signed App Store IPA for TestFlight
#                                        # (build/ios/ipa/*.ipa). Signing identity +
#                                        # profile must be provisioned first (Fastlane
#                                        # Match — see haven/DEVELOPMENT.md); export is
#                                        # driven by ios/ExportOptions.plist.
#                                        # BUILD_NUMBER is REQUIRED (unique build no.).
#
# Version stamping (optional env; the release pipeline sets both from the git tag
# + CI run number, so the tag is the single source of truth — no pubspec edits):
#   BUILD_NAME    marketing version, digits only e.g. 1.2.3  (-> CFBundleShortVersionString /
#                 Android versionName). Unset -> falls back to pubspec.yaml `version:`.
#   BUILD_NUMBER  unique, monotonic build number e.g. the CI run number
#                 (-> CFBundleVersion / Android versionCode). REQUIRED for ipa.
#
# Key source (first match wins):
#   1. haven/dart_defines/secrets.json          (gitignored; local dev)
#   2. $STADIA_API_KEY env var                  (CI; written to a chmod-600 temp
#                                                file so the key never hits argv)
#
# Exit codes: 0 ok | 1 bad args | 2 no usable key | 3 key is empty/placeholder

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HAVEN_DIR="${REPO_ROOT}/haven"
SECRETS_FILE="${HAVEN_DIR}/dart_defines/secrets.json"
SYMBOLS_DIR="${HAVEN_DIR}/build/symbols"
GUARD="${REPO_ROOT}/scripts/ci/check_no_committed_secrets.sh"
PLACEHOLDER='STADIA_API_KEY_PLACEHOLDER'
TMP_DEFINES=""

log()  { printf '\033[1;34m[build_release]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[build_release] FAIL:\033[0m %s\n' "$1" >&2; exit "${2:-1}"; }

# NOTE: must always return 0 — an EXIT trap whose last command is falsy flips
# the script's exit code (a bare `[[ … ]] && rm` returns 1 when no temp file
# was created, making a successful build report failure). Use an if-block.
cleanup() {
  if [[ -n "${TMP_DEFINES}" && -f "${TMP_DEFINES}" ]]; then
    rm -f "${TMP_DEFINES}"
  fi
}
trap cleanup EXIT

usage() { sed -n '2,/^set -euo pipefail/p' "$0" | sed 's/^#\{1,\} \{0,1\}//; /^set -euo pipefail/d'; }

# --- 1. Validate the build target -----------------------------------------
target="${1:-}"
extra_args=()
case "${target}" in
  apk)        build_args=(apk) ;;
  appbundle)  build_args=(appbundle) ;;
  ios)        build_args=(ios --no-codesign) ;;
  ipa)        build_args=(ipa)
              # Signed App Store IPA. The signing identity + "match AppStore
              # com.oblivioustech.haven" profile are provisioned out-of-band by Fastlane
              # Match and the export is driven by ios/ExportOptions.plist (manual
              # signing). BUILD_NUMBER (REQUIRED; CI passes the run number) is the
              # ONLY correct way to set a unique, monotonic TestFlight build
              # number — `flutter build` regenerates Generated.xcconfig and
              # clobbers any pbxproj/agvtool edit, and ExportOptions.plist sets
              # manageAppVersionAndBuildNumber=false. Without it the IPA would
              # silently archive as build "1" and TestFlight would reject a repeat.
              [[ -f "${HAVEN_DIR}/ios/ExportOptions.plist" ]] \
                || fail "ios/ExportOptions.plist not found (needed to export a signed IPA)" 1
              [[ -n "${BUILD_NUMBER:-}" ]] \
                || fail "BUILD_NUMBER must be set for ipa builds (CI passes github.run_number; locally e.g. BUILD_NUMBER=1)" 1
              extra_args=(--export-options-plist ios/ExportOptions.plist)
              ;;
  -h|--help)  usage; exit 0 ;;
  "")         usage; fail "missing build target (apk|appbundle|ios|ipa)" 1 ;;
  *)          usage; fail "unknown target '${target}' (expected apk|appbundle|ios|ipa)" 1 ;;
esac

# --- 1b. Version stamping (single source of truth) -------------------------
# BUILD_NAME (marketing version) and BUILD_NUMBER (unique build no.) are passed
# by the release pipeline — BUILD_NAME from the git tag, BUILD_NUMBER from the CI
# run number — so a release is fully versioned by `git tag vX.Y.Z`. Both are
# optional here (a bare local build falls back to pubspec.yaml's `version:`);
# BUILD_NUMBER is additionally required for ipa (enforced above).
version_args=()
if [[ -n "${BUILD_NAME:-}" ]]; then
  [[ "${BUILD_NAME}" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] \
    || fail "BUILD_NAME='${BUILD_NAME}' is not a valid version (expected MAJOR.MINOR[.PATCH], digits only — e.g. tag v1.2.3)" 1
  version_args+=(--build-name "${BUILD_NAME}")
fi
if [[ -n "${BUILD_NUMBER:-}" ]]; then
  version_args+=(--build-number "${BUILD_NUMBER}")
fi

# --- 2. Resolve the key source, refusing empty/placeholder ------------------
defines_path=""
if [[ -f "${SECRETS_FILE}" ]]; then
  grep -Fq "${PLACEHOLDER}" "${SECRETS_FILE}" \
    && fail "STADIA_API_KEY is still the placeholder in ${SECRETS_FILE}" 3
  grep -Eq '"STADIA_API_KEY"[[:space:]]*:[[:space:]]*"[^"]+"' "${SECRETS_FILE}" \
    || fail "STADIA_API_KEY missing or empty in ${SECRETS_FILE}" 3
  defines_path="${SECRETS_FILE}"
  log "using key from ${SECRETS_FILE}"
elif [[ -n "${STADIA_API_KEY:-}" && "${STADIA_API_KEY}" != "${PLACEHOLDER}" ]]; then
  # CI / power-user path: materialize a 600-perm temp file so the key never
  # appears in argv or the process table (unlike --dart-define=KEY=...).
  TMP_DEFINES="$(mktemp)"
  chmod 600 "${TMP_DEFINES}"
  printf '{ "STADIA_API_KEY": "%s" }\n' "${STADIA_API_KEY}" > "${TMP_DEFINES}"
  defines_path="${TMP_DEFINES}"
  log "using STADIA_API_KEY from environment (temp dart-define file)"
else
  fail "no usable key: create ${SECRETS_FILE} from secrets.example.json, or export STADIA_API_KEY" 2
fi

# The key is now in the dart-define file; drop it from the environment so child
# processes (flutter/gradle/xcodebuild) don't inherit it via /proc/<pid>/environ.
unset STADIA_API_KEY || true

# --- 3. Fail fast if any secret is committed -------------------------------
log "running no-committed-secrets guard..."
bash "${GUARD}"

# --- 4. Build (release-gated: HAVEN_RELEASE_WRAPPER tells the native gate
#        this is the sanctioned path) ---------------------------------------
export HAVEN_RELEASE_WRAPPER=1
mkdir -p "${SYMBOLS_DIR}"
log "building release ${target} (obfuscated; symbols -> ${SYMBOLS_DIR})"
cd "${HAVEN_DIR}"
flutter build "${build_args[@]}" \
  --release \
  --dart-define-from-file="${defines_path}" \
  --obfuscate \
  --split-debug-info="${SYMBOLS_DIR}" \
  ${version_args[@]+"${version_args[@]}"} \
  ${extra_args[@]+"${extra_args[@]}"}

log "done. Keep ${SYMBOLS_DIR} to de-obfuscate crash reports (never commit it)."
