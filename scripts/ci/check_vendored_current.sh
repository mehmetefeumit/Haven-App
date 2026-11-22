#!/usr/bin/env bash
# CI guard: every package Haven vendors is the latest upstream release.
#
# Dependabot cannot see a vendored copy: `third_party/geolocator_android` is a
# path dependency (patched to drop Google Play services, see its HAVEN_PATCH.md),
# so upstream fixes would otherwise never reach Haven. This asks pub.dev for the
# newest version of each vendored package and fails when the copy is older, the
# same way `cargo audit` turns a new advisory red. It also holds that the copy,
# its patch record and pubspec.lock name the same version.
#
# Usage:
#   check_vendored_current.sh             pub.dev over HTTPS (audit.yml)
#   check_vendored_current.sh --static    versions agree, no network (repo-guards)
#   check_vendored_current.sh --self-test
#
# Exit: 0 current, 1 behind upstream or versions disagree, 2 cannot vouch.

set -euo pipefail
export LC_ALL=C

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly REPO_ROOT
readonly VENDORED=(geolocator_android)

# vendored_version <root> <package>
vendored_version() {
  sed -n 's/^version: \([^ ]*\)$/\1/p' "$1/third_party/$2/pubspec.yaml"
}

# check_static <root> — the copy, its patch record and the lockfile agree.
check_static() {
  local root="$1" rc=0 p v
  for p in "${VENDORED[@]}"; do
    v="$(vendored_version "${root}" "${p}" 2>/dev/null || true)"
    if [[ -z "${v}" ]]; then echo "check_vendored_current: no version in third_party/${p}/pubspec.yaml" >&2; return 2; fi
    if ! grep -q "^# ${p} ${v}, patched for Haven$" "${root}/third_party/${p}/HAVEN_PATCH.md"; then
      echo "FAIL third_party/${p}/HAVEN_PATCH.md does not record version ${v}"; rc=1
    fi
    if ! awk -v p="  ${p}:" '$0==p{f=1;next} f&&/^  [^ ]/{exit} f' "${root}/haven/pubspec.lock" | grep -qx "    version: \"${v}\""; then
      echo "FAIL haven/pubspec.lock does not resolve ${p} ${v}"; rc=1
    fi
  done
  [[ "${rc}" -eq 0 ]] && echo "ok: vendored versions agree"
  return "${rc}"
}

# check_latest <root> <fetch-command...> — the command prints pub.dev's JSON for
# the package named by $PKG.
check_latest() {
  local root="$1" rc=0 p v latest json; shift
  for p in "${VENDORED[@]}"; do
    v="$(vendored_version "${root}" "${p}")"
    json="$(PKG="${p}" "$@")" || { echo "check_vendored_current: could not reach pub.dev for ${p}" >&2; return 2; }
    latest="$(python3 -I -c 'import json,sys; print(json.load(sys.stdin)["latest"]["version"])' <<<"${json}" 2>/dev/null)" \
      || { echo "check_vendored_current: pub.dev answered no latest version for ${p}" >&2; return 2; }
    if [[ "${latest}" == "${v}" ]]; then
      echo "ok ${p} ${v} is the latest release"
    else
      echo "FAIL ${p}: vendored ${v}, pub.dev's latest is ${latest} — upgrade third_party/${p} (HAVEN_PATCH.md, Upgrading)"; rc=1
    fi
  done
  return "${rc}"
}

fetch_pub() {
  curl -sSf --max-time 30 --retry 3 "https://pub.dev/api/packages/${PKG}"
}

self_test() {
  local tmp fails=0 v
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp}"' RETURN
  expect() {
    local name="$1" want="$2" got=0; shift 2
    "$@" >"${tmp}/out" 2>&1 || got=$?
    if [[ "${got}" -eq "${want}" ]]; then echo "  ok   ${name}"; else
      echo "  FAIL ${name}: rc ${got}, want ${want}"; sed 's/^/       /' "${tmp}/out"; fails=$((fails + 1)); fi
  }
  mkdir -p "${tmp}/repo/haven" "${tmp}/repo/third_party"
  cp "${REPO_ROOT}/haven/pubspec.lock" "${tmp}/repo/haven/"
  cp -R "${REPO_ROOT}/third_party/geolocator_android" "${tmp}/repo/third_party/"
  v="$(vendored_version "${tmp}/repo" geolocator_android)"
  _answer() { printf '{"name":"%s","latest":{"version":"%s"}}' "${PKG}" "${ANSWER}"; }
  _refuse() { return 7; }
  _garbage() { printf 'not json'; }

  expect "--static passes on this tree" 0 check_static "${tmp}/repo"
  ANSWER="${v}" expect "the latest release passes" 0 check_latest "${tmp}/repo" _answer
  ANSWER="99.0.0" expect "a newer upstream release fails" 1 check_latest "${tmp}/repo" _answer
  expect "an unreachable pub.dev is refused" 2 check_latest "${tmp}/repo" _refuse
  expect "an answer with no version is refused" 2 check_latest "${tmp}/repo" _garbage

  cp -R "${tmp}/repo" "${tmp}/m1"
  sed -i "s/^# geolocator_android ${v}, patched for Haven$/# geolocator_android 0.0.1, patched for Haven/" \
    "${tmp}/m1/third_party/geolocator_android/HAVEN_PATCH.md"
  expect "--static fails: the patch record names another version" 1 check_static "${tmp}/m1"
  cp -R "${tmp}/repo" "${tmp}/m2"
  sed -i "s/^version: ${v}$/version: 0.0.1/" "${tmp}/m2/third_party/geolocator_android/pubspec.yaml"
  expect "--static fails: the copy and the lockfile disagree" 1 check_static "${tmp}/m2"

  if [[ "${fails}" -gt 0 ]]; then echo "self-test: ${fails} case(s) failed"; return 1; fi
  echo "self-test: all cases passed"
}

case "${1:-}" in
  --self-test) self_test ;;
  --static) check_static "${REPO_ROOT}" ;;
  '') check_static "${REPO_ROOT}" && check_latest "${REPO_ROOT}" fetch_pub ;;
  *) echo "usage: $0 [--static | --self-test]" >&2; exit 2 ;;
esac
