#!/usr/bin/env bash
# CI guard: the version a release shows in the app is the release tag's.
#
# release-build.yml hands scripts/build_release.sh the tag as BUILD_NAME
# (v1.2.3-beta.1 -> 1.2.3-beta.1). The wrapper compiles it in full into the app
# as HAVEN_VERSION (About page, licence page, Haven's own User-Agent) and passes
# the digits-only part as the native stamp. The About page showed a hardcoded
# "0.1.0" for every release until 2026-11 because nothing checked this.
#
# Runs the wrapper's `version` target (builds nothing, needs no key) and checks:
#   1. a tag version reaches HAVEN_VERSION whole, and --build-name without its
#      -prerelease / +build suffix;
#   2. with no BUILD_NAME, HAVEN_VERSION is pubspec.yaml's version name, and the
#      real pubspec's passes the wrapper's validation;
#   3. a value that is not a version is refused (it lands in a compiled constant
#      and a header), and nothing is printed for it;
#   4. the define the wrapper passes is the one the Dart constant reads — a
#      renamed define compiles every release silently as "dev".
#
# Exit codes: 0 all checks pass | 1 a violation was found

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WRAPPER="${REPO_ROOT}/scripts/build_release.sh"
DART_CONST="${REPO_ROOT}/haven/lib/src/constants/app_version.dart"

FAILED=0
violation() { printf '\033[1;31m[check_release_version_stamp] FAIL:\033[0m %s\n' "$*" >&2; FAILED=1; }

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
# A copy of the wrapper in a tree whose pubspec this guard controls; the
# wrapper finds pubspec.yaml relative to its own location.
mkdir -p "${tmp}/scripts" "${tmp}/haven"
cp "${WRAPPER}" "${tmp}/scripts/build_release.sh"

# expect <case> <pubspec version line> <BUILD_NAME or -> <expected stdout>
expect() {
  local name="$1" pubspec="$2" build_name="$3" want="$4" got rc=0
  printf '%s\n' "${pubspec}" > "${tmp}/haven/pubspec.yaml"
  if [[ "${build_name}" == - ]]; then
    got="$(env -u BUILD_NAME BUILD_NUMBER=42 bash "${tmp}/scripts/build_release.sh" version 2>/dev/null)" || rc=$?
  else
    got="$(BUILD_NAME="${build_name}" BUILD_NUMBER=42 bash "${tmp}/scripts/build_release.sh" version 2>/dev/null)" || rc=$?
  fi
  (( rc == 0 )) || { violation "${name}: wrapper exited ${rc}"; return; }
  [[ "${got}" == "${want}" ]] \
    || violation "${name}: wrapper passed"$'\n'"${got}"$'\n'"expected"$'\n'"${want}"
}

# refuse <case> <pubspec version line> <BUILD_NAME or ->
refuse() {
  local name="$1" pubspec="$2" build_name="$3" got rc=0
  printf '%s\n' "${pubspec}" > "${tmp}/haven/pubspec.yaml"
  if [[ "${build_name}" == - ]]; then
    got="$(env -u BUILD_NAME -u BUILD_NUMBER bash "${tmp}/scripts/build_release.sh" version 2>/dev/null)" || rc=$?
  else
    got="$(BUILD_NAME="${build_name}" env -u BUILD_NUMBER bash "${tmp}/scripts/build_release.sh" version 2>/dev/null)" || rc=$?
  fi
  (( rc == 1 )) || violation "${name}: wrapper exited ${rc}, expected the refusal (1)"
  [[ -z "${got}" ]] || violation "${name}: refused value still produced arguments: ${got}"
}

# 1. The tag version.
expect "pre-release tag" 'version: 9.9.9+1' '1.2.3-beta.1' \
  $'--dart-define=HAVEN_VERSION=1.2.3-beta.1\n--build-name\n1.2.3\n--build-number\n42'
expect "release tag" 'version: 9.9.9+1' '1.2.3' \
  $'--dart-define=HAVEN_VERSION=1.2.3\n--build-name\n1.2.3\n--build-number\n42'
expect "build-metadata tag" 'version: 9.9.9+1' '1.2.3-rc.2+exp.7' \
  $'--dart-define=HAVEN_VERSION=1.2.3-rc.2+exp.7\n--build-name\n1.2.3\n--build-number\n42'
expect "two-part tag" 'version: 9.9.9+1' '2.0' \
  $'--dart-define=HAVEN_VERSION=2.0\n--build-name\n2.0\n--build-number\n42'

# 2. No tag: pubspec.yaml, without its +build part.
expect "pubspec fallback" 'version: 4.5.6+7' - \
  $'--dart-define=HAVEN_VERSION=4.5.6\n--build-number\n42'
real="$(env -u BUILD_NAME -u BUILD_NUMBER bash "${WRAPPER}" version 2>/dev/null)" \
  || violation "the real haven/pubspec.yaml version is refused by the wrapper"
real_name="$(sed -n 's/^version:[[:space:]]*\([^+[:space:]]*\).*$/\1/p' "${REPO_ROOT}/haven/pubspec.yaml")"
[[ "${real}" == "--dart-define=HAVEN_VERSION=${real_name}" ]] \
  || violation "with no BUILD_NAME the wrapper passed '${real}', not the pubspec version '${real_name}'"

# 3. Not a version.
refuse "v-prefixed tag" 'version: 9.9.9+1' 'v1.2.3'
refuse "space and text" 'version: 9.9.9+1' '1.2.3 (evil)'
refuse "header injection" 'version: 9.9.9+1' $'1.2.3\r\nX-Evil: 1'
refuse "shell metacharacter" 'version: 9.9.9+1' '1.2.3-beta;id'
refuse "path" 'version: 9.9.9+1' '1.2.3-beta/../x'
refuse "empty pre-release" 'version: 9.9.9+1' '1.2.3-'
refuse "no minor" 'version: 9.9.9+1' '1'
refuse "pubspec without a version" 'name: haven' -

# 4. One define name on both sides.
define="$(BUILD_NAME=1.2.3 env -u BUILD_NUMBER bash "${WRAPPER}" version 2>/dev/null \
  | sed -n 's/^--dart-define=\([A-Z_]*\)=.*$/\1/p')"
[[ -n "${define}" ]] || violation "the wrapper passes no version --dart-define"
tr -d '[:space:]' < "${DART_CONST}" | grep -qF "String.fromEnvironment('${define}'" \
  || violation "${DART_CONST#"${REPO_ROOT}/"} does not read the define the wrapper passes (${define:-none})"

if (( FAILED )); then
  exit 1
fi
printf '\033[1;34m[check_release_version_stamp]\033[0m OK: the app version follows the release tag.\n'
