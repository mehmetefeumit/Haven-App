#!/usr/bin/env bash
# Nothing ships that the launch gates have not started (docs/LAUNCH_GATE.md).
#
# v0.1.14's APKs died at every process start and were published anyway: the
# release workflow built, checksummed and released them without ever
# launching one. The gates now sit between build and publish, and that holds
# only as long as the wiring does. A dropped `needs:`, a publish step moved
# back into the build job, or a gate taken out of ci.yml or the verdict gate
# would each remove the guarantee while every remaining job stays green, so
# this guard reads the wiring itself:
#
#   G1 release-build.yml's android-launch-gate calls launch-gate-android.yml on
#      the artifact `android` uploads (haven-release-android).
#   G2 every job that publishes APKs to the GitHub Release needs
#      android-launch-gate and checks the gate's tested_sha256.
#   G3 Zapstore, which pulls the APK from the Release, needs android-publish.
#   G4 ios-launch-gate calls launch-gate-ios.yml, the TestFlight job needs it,
#      and that job runs check_ios_app_loadable.sh before uploading.
#   G5 the job attaching the iOS simulator build needs ios-launch-gate.
#   G6 ci.yml calls both launch-gate workflows.
#   G7 check_ci_verdict.sh holds launch-gate-ios.yml among its gate workflows.
#
# Usage:
#   bash scripts/ci/check_release_launch_gated.sh             # check the tree
#   bash scripts/ci/check_release_launch_gated.sh --self-test # mutation tests
#
# Exit codes: 0 wired; 1 a check failed; 2 a file is missing or unreadable.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly RELEASE_REL='.github/workflows/release-build.yml'
readonly CI_REL='.github/workflows/ci.yml'
readonly VERDICT_REL='scripts/ci/check_ci_verdict.sh'
# Pinned, because a mutation that stops running is a deleted check.
readonly SELF_TEST_MUTATIONS=11

# The block of one top-level job (`  <key>:` up to the next one).
job_block() { # <workflow> <job key>
  awk -v k="  $2:" '
    /^jobs:/ { j = 1; next }
    j && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { inside = ($0 == k) ; next }
    j && inside { print }
  ' "$1"
}

# Job keys of a workflow whose block matches every given ERE.
jobs_matching() { # <workflow> <ere>...
  local wf="$1" key; shift
  for key in $(awk '/^jobs:/ { j = 1; next } j && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { k = $1; sub(/:$/, "", k); print k }' "${wf}"); do
    local block re ok=1
    block="$(job_block "${wf}" "${key}")"
    for re in "$@"; do grep -Eq -- "${re}" <<<"${block}" || { ok=0; break; }; done
    (( ok )) && echo "${key}"
  done
  return 0
}

# Whether a job's single-line `needs:` names a job.
needs_has() { # <workflow> <job key> <needed>
  job_block "$1" "$2" | grep -E '^    needs:' | head -n1 | tr -d '[] ' | sed 's/^needs://' \
    | tr ',' '\n' | grep -qx -- "$3"
}

check() { # <root>
  local root="$1" rel="$1/${RELEASE_REL}" ci="$1/${CI_REL}" verdict="$1/${VERDICT_REL}"
  local f errs=0 key publishers ios_jobs
  for f in "${rel}" "${ci}" "${verdict}"; do
    [[ -r "${f}" ]] || { echo "ERROR: ${f#"${root}"/} not found" >&2; return 2; }
  done
  err() { echo "FAIL $1" >&2; errs=$((errs + 1)); }

  job_block "${rel}" android-launch-gate | grep -q 'uses: ./.github/workflows/launch-gate-android.yml' \
    && job_block "${rel}" android-launch-gate | grep -q 'candidate_artifact: haven-release-android' \
    || err "G1: android-launch-gate must call launch-gate-android.yml on haven-release-android"

  publishers="$(jobs_matching "${rel}" 'softprops/action-gh-release' 'app-\*-release\.apk')"
  [[ -n "${publishers}" ]] || err "G2: no job publishes the APKs (expected android-publish)"
  for key in ${publishers}; do
    needs_has "${rel}" "${key}" android-launch-gate \
      || err "G2: ${key} publishes APKs without needing android-launch-gate"
    job_block "${rel}" "${key}" | grep -q 'needs.android-launch-gate.outputs.tested_sha256' \
      || err "G2: ${key} publishes APKs without checking the gate's tested_sha256"
  done

  needs_has "${rel}" zapstore android-publish || err "G3: zapstore must need android-publish"

  job_block "${rel}" ios-launch-gate | grep -q 'uses: ./.github/workflows/launch-gate-ios.yml' \
    || err "G4: ios-launch-gate must call launch-gate-ios.yml"
  ios_jobs="$(jobs_matching "${rel}" 'fastlane ios upload')"
  [[ -n "${ios_jobs}" ]] || err "G4: no job uploads to TestFlight (expected ios)"
  for key in ${ios_jobs}; do
    needs_has "${rel}" "${key}" ios-launch-gate || err "G4: ${key} uploads to TestFlight without needing ios-launch-gate"
    job_block "${rel}" "${key}" | awk '
      /check_ios_app_loadable\.sh/ && !up { checked = 1 }
      /fastlane ios upload/ { up = 1 }
      END { exit !(checked && up) }' \
      || err "G4: ${key} must run check_ios_app_loadable.sh before fastlane ios upload"
  done

  for key in $(jobs_matching "${rel}" 'app-ios-simulator\.zip' 'softprops/action-gh-release'); do
    needs_has "${rel}" "${key}" ios-launch-gate || err "G5: ${key} attaches the simulator build without needing ios-launch-gate"
  done

  grep -q '^    uses: ./.github/workflows/launch-gate-android.yml' "${ci}" || err "G6: ci.yml must call launch-gate-android.yml"
  grep -q '^    uses: ./.github/workflows/launch-gate-ios.yml' "${ci}" || err "G6: ci.yml must call launch-gate-ios.yml"

  grep -Eq '^readonly GATE_WORKFLOWS=\(.*\blaunch-gate-ios\.yml\b' "${verdict}" \
    || err "G7: check_ci_verdict.sh GATE_WORKFLOWS must include launch-gate-ios.yml"

  (( errs == 0 )) || return 1
  echo "release launch gates wired (G1-G7)"
}

self_test() {
  local tmp ran=0 rc
  tmp="$(mktemp -d)"; trap 'rm -rf "${tmp}"' RETURN
  fresh() {
    rm -rf "${tmp}/r"; mkdir -p "${tmp}/r/.github/workflows" "${tmp}/r/scripts/ci"
    cp "${REPO_ROOT}/${RELEASE_REL}" "${tmp}/r/${RELEASE_REL}"
    cp "${REPO_ROOT}/${CI_REL}" "${tmp}/r/${CI_REL}"
    cp "${REPO_ROOT}/${VERDICT_REL}" "${tmp}/r/${VERDICT_REL}"
  }
  expect() { # <label> <want rc> <file rel> <sed program or ''>
    fresh
    [[ -z "$4" ]] || sed -i -E "$4" "${tmp}/r/$3"
    rc=0; check "${tmp}/r" >/dev/null 2>&1 || rc=$?
    [[ "${rc}" == "$2" ]] || { echo "self-test FAIL: ${1}: rc ${rc}, want $2" >&2; return 1; }
    ran=$((ran + 1))
  }
  expect "the tree as committed" 0 "${RELEASE_REL}" ''
  expect "publish no longer needs the gate" 1 "${RELEASE_REL}" 's/needs: \[android, android-launch-gate\]/needs: [android]/'
  expect "publish skips the digest check" 1 "${RELEASE_REL}" '/needs\.android-launch-gate\.outputs\.tested_sha256/d'
  expect "the gate tests another artifact" 1 "${RELEASE_REL}" 's/candidate_artifact: haven-release-android/candidate_artifact: something-else/'
  expect "zapstore runs off the build" 1 "${RELEASE_REL}" 's/needs: \[android-publish\]$/needs: [android]/'
  expect "TestFlight no longer waits for iOS" 1 "${RELEASE_REL}" 's/needs: \[gate, ios-launch-gate\]/needs: [gate]/'
  expect "the IPA load check is dropped" 1 "${RELEASE_REL}" '/check_ios_app_loadable\.sh/d'
  expect "ci.yml drops the iOS gate" 1 "${CI_REL}" '/uses: \.\/\.github\/workflows\/launch-gate-ios\.yml/d'
  expect "ci.yml drops the Android gate" 1 "${CI_REL}" '/uses: \.\/\.github\/workflows\/launch-gate-android\.yml/d'
  expect "the simulator build is attached untested" 1 "${RELEASE_REL}" 's/needs: \[android-publish, ios-launch-gate\]/needs: [android-publish]/'
  expect "the verdict gate drops iOS" 1 "${VERDICT_REL}" 's/ launch-gate-ios\.yml\)/)/'
  # A mutation whose sed matches nothing leaves rc 0 and fails above; this
  # catches a case that stopped running at all.
  (( ran == SELF_TEST_MUTATIONS )) || { echo "self-test FAIL: ran ${ran} cases, pinned ${SELF_TEST_MUTATIONS}" >&2; return 1; }
  echo "self-test: ${ran} cases passed"
}

case "${1:-}" in
  --self-test) self_test ;;
  "") check "${REPO_ROOT}" ;;
  *) echo "usage: $0 [--self-test]" >&2; exit 2 ;;
esac
