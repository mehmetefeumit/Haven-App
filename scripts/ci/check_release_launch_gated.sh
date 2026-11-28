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
#   G3 Zapstore, which pulls the APK from the Release, needs publish.
#   G4 ios-launch-gate calls launch-gate-ios.yml, the TestFlight job needs it,
#      and that job runs check_ios_app_loadable.sh before uploading.
#   G5 the job attaching the iOS simulator build needs ios-launch-gate.
#   G6 ci.yml calls both launch-gate workflows.
#   G7 check_ci_verdict.sh holds launch-gate-ios.yml among its gate workflows.
#   G8 the Release is written whole before it is published, because a
#      published Release is immutable here: one job writes it, its upload sets
#      `draft: true` (a prerelease would otherwise be created published), and
#      that job publishes it after the upload. v0.1.16's simulator asset was
#      refused because a second job attached it after the first had published.
#   G9 the TestFlight job runs check_ios_app_sdk.sh before uploading, and
#      launch-gate-ios.yml runs it on the candidate before launching it: from
#      April 2027 App Store Connect refuses a build below the iOS 27 SDK.
#   G10 every job that builds for iOS or boots a simulator runs on the
#      TestFlight job's runner and selects its Xcode before building, and that
#      runner is an `xcode-NN` image with NN at least check_ios_app_sdk.sh's
#      IOS_SDK_FLOOR: the gate and the lanes test what TestFlight receives, and
#      the label cannot fall below the floor the archive is held to.
#   G11 launch-gate-ios.yml runs the app's XCTest bundle (RunnerTests) on the
#      booted simulator after the legs, and a run in which no test case passed
#      fails it.
#
# G4 and G9 read a script only from a step's `run:` line, so a comment naming
# it, or the call commented out, is not a check that runs.
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
readonly LAUNCH_GATE_IOS_REL='.github/workflows/launch-gate-ios.yml'
readonly SDK_CHECK_REL='scripts/ci/check_ios_app_sdk.sh'
# What makes a job an Apple-toolchain job (G10): it builds for iOS or boots a
# simulator. Read from lines that are neither comments nor a --self-test.
export APPLE_BUILD_ERE='boot-ios-sim\.sh|flutter build (ios|ipa)|build_release\.sh ipa|xcodebuild|aarch64-apple-ios'
# Pinned, because a mutation that stops running is a deleted check.
readonly SELF_TEST_MUTATIONS=29

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

# Whether a job runs <script> from a step's `run:` line before its `fastlane
# ios upload` run line.
runs_before_upload() { # <workflow> <job key> <script ERE>
  job_block "$1" "$2" | S="$3" awk '
    /^[[:space:]]*(-[[:space:]]+)?run:[[:space:]]/ && $0 ~ ENVIRON["S"] && !up { checked = 1 }
    /^[[:space:]]*(-[[:space:]]+)?run:[[:space:]]+bundle exec fastlane ios upload/ { up = 1 }
    END { exit !(checked && up) }'
}

# "<runs-on>\t<xcode-versions, space-joined>\t<1 when setup-xcode precedes the
# first build line, else 0>" for one job.
toolchain_of() { # <workflow> <job key>
  job_block "$1" "$2" | awk '
    /^[[:space:]]*#/ { next }
    /^    runs-on:/ { r = $0; sub(/^    runs-on:[[:space:]]*/, "", r); sub(/[[:space:]]+#.*$/, "", r) }
    /^[[:space:]]+uses: maxim-lobanov\/setup-xcode@/ && !built { selected = 1 }
    /^          xcode-version:/ { v = $0; sub(/^          xcode-version:[[:space:]]*/, "", v); xc = xc (xc == "" ? "" : " ") v }
    $0 ~ ENVIRON["APPLE_BUILD_ERE"] && $0 !~ /--self-test/ { built = 1 }
    END { printf "%s\t%s\t%d\n", r, xc, selected }'
}

check() { # <root>
  local root="$1" rel="$1/${RELEASE_REL}" ci="$1/${CI_REL}" verdict="$1/${VERDICT_REL}"
  local lg="$1/${LAUNCH_GATE_IOS_REL}" sdk="$1/${SDK_CHECK_REL}"
  local f errs=0 key publishers ios_jobs writers
  for f in "${rel}" "${ci}" "${verdict}" "${lg}" "${sdk}"; do
    [[ -r "${f}" ]] || { echo "ERROR: ${f#"${root}"/} not found" >&2; return 2; }
  done
  err() { echo "FAIL $1" >&2; errs=$((errs + 1)); }

  job_block "${rel}" android-launch-gate | grep -q 'uses: ./.github/workflows/launch-gate-android.yml' \
    && job_block "${rel}" android-launch-gate | grep -q 'candidate_artifact: haven-release-android' \
    || err "G1: android-launch-gate must call launch-gate-android.yml on haven-release-android"

  publishers="$(jobs_matching "${rel}" 'softprops/action-gh-release' 'app-\*-release\.apk')"
  [[ -n "${publishers}" ]] || err "G2: no job publishes the APKs (expected publish)"
  for key in ${publishers}; do
    needs_has "${rel}" "${key}" android-launch-gate \
      || err "G2: ${key} publishes APKs without needing android-launch-gate"
    job_block "${rel}" "${key}" | grep -q 'needs.android-launch-gate.outputs.tested_sha256' \
      || err "G2: ${key} publishes APKs without checking the gate's tested_sha256"
  done

  needs_has "${rel}" zapstore publish || err "G3: zapstore must need publish"

  job_block "${rel}" ios-launch-gate | grep -q 'uses: ./.github/workflows/launch-gate-ios.yml' \
    || err "G4: ios-launch-gate must call launch-gate-ios.yml"
  ios_jobs="$(jobs_matching "${rel}" 'fastlane ios upload')"
  [[ -n "${ios_jobs}" ]] || err "G4: no job uploads to TestFlight (expected ios)"
  for key in ${ios_jobs}; do
    needs_has "${rel}" "${key}" ios-launch-gate || err "G4: ${key} uploads to TestFlight without needing ios-launch-gate"
    runs_before_upload "${rel}" "${key}" 'check_ios_app_loadable\.sh' \
      || err "G4: ${key} must run check_ios_app_loadable.sh before fastlane ios upload"
    runs_before_upload "${rel}" "${key}" 'check_ios_app_sdk\.sh' \
      || err "G9: ${key} must run check_ios_app_sdk.sh before fastlane ios upload"
  done
  awk '
    /^[[:space:]]*(-[[:space:]]+)?run:[[:space:]]+bash scripts\/ci\/check_ios_app_sdk\.sh --simulator "\$\{CANDIDATE_APP\}"/ && !drive { checked = 1 }
    /^[[:space:]]*command:[[:space:]]+bash tooling\/e2e\/ci\/run-launch-gate-ios\.sh / { drive = 1 }
    END { exit !(checked && drive) }' "${lg}" \
    || err "G9: launch-gate-ios.yml must run check_ios_app_sdk.sh --simulator on the candidate before launching it"

  local tf tf_runs tf_xc floor wf runs xc sel
  floor="$(sed -n 's/^readonly IOS_SDK_FLOOR=\([0-9][0-9]*\)$/\1/p' "${sdk}")"
  [[ -n "${floor}" ]] || err "G10: ${SDK_CHECK_REL} declares no IOS_SDK_FLOOR"
  for key in ${ios_jobs}; do
    IFS=$'\t' read -r tf_runs tf_xc sel <<<"$(toolchain_of "${rel}" "${key}")"
    if [[ ! "${tf_runs}" =~ ^xcode-([0-9]+)(-xlarge)?$ ]] || [[ -z "${floor}" ]] || (( BASH_REMATCH[1] < floor )); then
      err "G10: ${key} must run on an xcode-NN image at or above the iOS SDK floor (${floor:-?}), not '${tf_runs}'"
    fi
    [[ -n "${tf_xc}" ]] || err "G10: ${key} selects no Xcode"
    tf="${key}"
  done
  for wf in "${root}"/.github/workflows/*.yml; do
    for key in $(awk '/^jobs:/ { j = 1; next } j && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { k = $1; sub(/:$/, "", k); print k }' "${wf}"); do
      # Read to the end: a `grep -q` that stops early can SIGPIPE its writer,
      # which pipefail would turn into a job skipped unseen.
      job_block "${wf}" "${key}" | grep -v '^[[:space:]]*#' | grep -v -- '--self-test' \
        | grep -E -- "${APPLE_BUILD_ERE}" >/dev/null || continue
      IFS=$'\t' read -r runs xc sel <<<"$(toolchain_of "${wf}" "${key}")"
      [[ -n "${tf:-}" && "${runs}" == "${tf_runs}" && "${xc}" == "${tf_xc}" && "${sel}" == 1 ]] \
        || err "G10: ${wf##*/} ${key} must run on ${tf_runs:-?} and select xcode-version ${tf_xc:-?} before it builds, as the TestFlight job does (has '${runs}', '${xc}')"
    done
  done

  awk '
    /^[[:space:]]*command:[[:space:]]+bash tooling\/e2e\/ci\/run-launch-gate-ios\.sh / { drive = 1 }
    drive && /xcodebuild test -workspace Runner\.xcworkspace -scheme Runner/ { xc = 1 }
    drive && xc && /-only-testing:RunnerTests/ { only = 1 }
    drive && /echo "::error::RunnerTests ran no test case"/ { refuse = 1 }
    END { exit !(only && refuse) }' "${lg}" \
    || err "G11: launch-gate-ios.yml must run RunnerTests (xcodebuild test -only-testing:RunnerTests) after the drive, failing a run in which no test case passed"

  for key in $(jobs_matching "${rel}" 'app-ios-simulator\.zip' 'softprops/action-gh-release'); do
    needs_has "${rel}" "${key}" ios-launch-gate || err "G5: ${key} attaches the simulator build without needing ios-launch-gate"
  done

  grep -q '^    uses: ./.github/workflows/launch-gate-android.yml' "${ci}" || err "G6: ci.yml must call launch-gate-android.yml"
  grep -q '^    uses: ./.github/workflows/launch-gate-ios.yml' "${ci}" || err "G6: ci.yml must call launch-gate-ios.yml"

  grep -Eq '^readonly GATE_WORKFLOWS=\(.*\blaunch-gate-ios\.yml\b' "${verdict}" \
    || err "G7: check_ci_verdict.sh GATE_WORKFLOWS must include launch-gate-ios.yml"

  writers="$(jobs_matching "${rel}" 'softprops/action-gh-release')"
  if [[ "$(wc -w <<<"${writers}")" -ne 1 ]]; then
    err "G8: exactly one job may write the GitHub Release (found: ${writers//$'\n'/ })"
  else
    job_block "${rel}" "${writers}" | awk '
      /uses: softprops\/action-gh-release/ { up = 1 }
      up && /^          draft: true$/ { draft = 1 }
      up && /-F draft=false/ { published = 1 }
      END { exit !(draft && published) }' \
      || err "G8: ${writers} must upload with draft: true and only then publish (-F draft=false)"
  fi

  (( errs == 0 )) || return 1
  echo "release launch gates wired (G1-G11)"
}

self_test() {
  local tmp ran=0 rc
  tmp="$(mktemp -d)"; trap 'rm -rf "${tmp}"' RETURN
  fresh() {
    rm -rf "${tmp}/r"; mkdir -p "${tmp}/r/.github/workflows" "${tmp}/r/scripts/ci"
    cp "${REPO_ROOT}"/.github/workflows/*.yml "${tmp}/r/.github/workflows/"
    cp "${REPO_ROOT}/${VERDICT_REL}" "${tmp}/r/${VERDICT_REL}"
    cp "${REPO_ROOT}/${SDK_CHECK_REL}" "${tmp}/r/${SDK_CHECK_REL}"
  }
  expect() { # <label> <want rc> <file rel> <sed program or ''>
    fresh
    [[ -z "$4" ]] || sed -i -E "$4" "${tmp}/r/$3"
    rc=0; check "${tmp}/r" >/dev/null 2>&1 || rc=$?
    [[ "${rc}" == "$2" ]] || { echo "self-test FAIL: ${1}: rc ${rc}, want $2" >&2; return 1; }
    ran=$((ran + 1))
  }
  expect "the tree as committed" 0 "${RELEASE_REL}" ''
  expect "publish no longer needs the gate" 1 "${RELEASE_REL}" 's/needs: \[android, android-launch-gate, ios-launch-gate\]/needs: [android, ios-launch-gate]/'
  expect "publish skips the digest check" 1 "${RELEASE_REL}" '/needs\.android-launch-gate\.outputs\.tested_sha256/d'
  expect "the gate tests another artifact" 1 "${RELEASE_REL}" 's/candidate_artifact: haven-release-android/candidate_artifact: something-else/'
  expect "zapstore runs off the build" 1 "${RELEASE_REL}" 's/needs: \[publish\]$/needs: [android]/'
  expect "TestFlight no longer waits for iOS" 1 "${RELEASE_REL}" 's/needs: \[gate, ios-launch-gate\]/needs: [gate]/'
  expect "the IPA load check is dropped" 1 "${RELEASE_REL}" '/check_ios_app_loadable\.sh/d'
  expect "ci.yml drops the iOS gate" 1 "${CI_REL}" '/uses: \.\/\.github\/workflows\/launch-gate-ios\.yml/d'
  expect "ci.yml drops the Android gate" 1 "${CI_REL}" '/uses: \.\/\.github\/workflows\/launch-gate-android\.yml/d'
  expect "the simulator build is attached untested" 1 "${RELEASE_REL}" 's/needs: \[android, android-launch-gate, ios-launch-gate\]/needs: [android, android-launch-gate]/'
  expect "the release is created published" 1 "${RELEASE_REL}" '/^          draft: true$/d'
  expect "the draft is never published" 1 "${RELEASE_REL}" 's/-F draft=false/-F draft=true/'
  expect "a second job writes the release" 1 "${RELEASE_REL}" 's/^(      - name: Skipped \(no Zapstore secret\))$/      - uses: softprops\/action-gh-release@v2\n\1/'
  expect "the verdict gate drops iOS" 1 "${VERDICT_REL}" 's/ launch-gate-ios\.yml\)/)/'
  expect "the IPA load check is commented out" 1 "${RELEASE_REL}" 's/^        run: (bash \.\.\/scripts\/ci\/check_ios_app_loadable\.sh .*)$/        # run: \1/'
  expect "the IPA SDK check is dropped" 1 "${RELEASE_REL}" '/check_ios_app_sdk\.sh/d'
  expect "the IPA SDK check is commented out" 1 "${RELEASE_REL}" 's/^        run: (bash \.\.\/scripts\/ci\/check_ios_app_sdk\.sh .*)$/        # run: \1/'
  expect "the IPA SDK check runs after the upload" 1 "${RELEASE_REL}" '/check_ios_app_sdk\.sh/d; s/^(        run: bundle exec fastlane ios upload)$/\1\n      - run: bash ..\/scripts\/ci\/check_ios_app_sdk.sh late/'
  expect "the gate's SDK check is dropped" 1 "${LAUNCH_GATE_IOS_REL}" '/check_ios_app_sdk\.sh/d'
  expect "the gate's SDK check is commented out" 1 "${LAUNCH_GATE_IOS_REL}" 's/^        run: (bash scripts\/ci\/check_ios_app_sdk\.sh .*)$/        # run: \1/'
  expect "the gate runs on another image" 1 "${LAUNCH_GATE_IOS_REL}" 's/^    runs-on: xcode-27$/    runs-on: macos-26/'
  expect "the gate selects another Xcode" 1 "${LAUNCH_GATE_IOS_REL}" "s/xcode-version: latest-stable/xcode-version: '27.0'/"
  expect "TestFlight stops selecting Xcode" 1 "${RELEASE_REL}" '/xcode-version: latest-stable/d'
  expect "an iOS lane runs on another image" 1 ".github/workflows/e2e-ios.yml" 's/^    runs-on: xcode-27 /    runs-on: macos-latest /'
  expect "an iOS compile check selects no Xcode" 1 ".github/workflows/cross-check.yml" '/maxim-lobanov\/setup-xcode@/d'
  expect "an iOS compile check builds before it selects Xcode" 1 ".github/workflows/cross-check.yml" 's/^(      - name: Select Xcode)$/      - run: cargo check --target aarch64-apple-ios\n\1/'
  expect "the SDK floor rises above the runner's Xcode" 1 "${SDK_CHECK_REL}" 's/^readonly IOS_SDK_FLOOR=[0-9]+$/readonly IOS_SDK_FLOOR=28/'
  expect "the gate drops the app's XCTest bundle" 1 "${LAUNCH_GATE_IOS_REL}" '/-only-testing:RunnerTests/d'
  expect "an XCTest run with no test case passes" 1 "${LAUNCH_GATE_IOS_REL}" '/RunnerTests ran no test case/d'
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
