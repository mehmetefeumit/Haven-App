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
#   G9 the TestFlight job runs check_ios_app_sdk.sh before uploading,
#      launch-gate-ios.yml runs it on the candidate before launching it, and
#      every build-check.yml job that builds the iOS app runs it on that build:
#      from April 2027 App Store Connect refuses a build below the iOS 27 SDK.
#   G10 every job that builds for iOS or boots a simulator runs on the
#      TestFlight job's runner and selects its Xcode before building, and that
#      runner is an `xcode-NN` image with NN at least check_ios_app_sdk.sh's
#      IOS_SDK_FLOOR: the gate and the lanes test what TestFlight receives, and
#      the label cannot fall below the floor the archive is held to.
#   G11 launch-gate-ios.yml runs the app's XCTest bundle (RunnerTests) on the
#      booted simulator in one step, after the legs and before any upload,
#      under its pinned `if:`, never continue-on-error, under `set -euo
#      pipefail`; xcodebuild's transcript goes to a file with its rc kept, a
#      run with a failed case or a non-zero rc and a run in which no case
#      passed each echo an ::error:: and `exit 1`; and the summary it prints is
#      scan-logs.sh's sink, scanned before it is printed and not written after.
#
# G4 and G9 read a script only from a step's `run:` line whose whole command is
# `bash <script> <args>` (no prefix, and no `||`, `&&`, `;`, pipe, subshell or
# comment after it) in a step that is neither conditional nor
# continue-on-error: a comment naming it, the call commented out, echoed, or
# with its failure swallowed is not a check that runs.
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
readonly BUILD_CHECK_REL='.github/workflows/build-check.yml'
# What makes a job an Apple-toolchain job (G10): it builds for iOS or boots a
# simulator. Read from lines that are neither comments nor a --self-test.
export APPLE_BUILD_ERE='boot-ios-sim\.sh|flutter build (ios|ipa)|build_release\.sh ipa|xcodebuild|aarch64-apple-ios'
# Pinned, because a mutation that stops running is a deleted check.
readonly SELF_TEST_MUTATIONS=56

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

# A `run:` line whose whole command is `bash <script> <args>`; the default
# <args> refuse `||`, `&&`, `;`, a pipe, a subshell, a redirect and a comment.
run_line() { # <script path ERE> [<args ERE>]
  printf '^[[:space:]]*(-[[:space:]]+)?run:[[:space:]]+bash %s %s' "$1" "${2:-[^|;&#\`()<>]+$}"
}

# Whether a step whose line matches <run ERE> is neither conditional nor
# continue-on-error and comes before the first line matching <later ERE>, which
# must exist ('' for no such line). Reads a job block or one-job workflow.
gated_step() { # <run ERE> <later ERE>
  E="$1" B="$2" awk '
    function flush() { if (hit && !soft && !late) ok = 1; hit = 0; soft = 0; late = 0 }
    /^      - / { flush() }
    /^      (- |  )(if|continue-on-error):/ { soft = 1 }
    $0 ~ ENVIRON["E"] { hit = 1; late = later }
    ENVIRON["B"] != "" && $0 ~ ENVIRON["B"] { later = 1 }
    END { flush(); exit !(ok && (ENVIRON["B"] == "" || later)) }'
}

# The steps of a job block or one-job workflow holding an uncommented line that
# matches <ERE>, each followed by a line holding only \035.
steps_with() { # <ERE>
  E="$1" awk '
    function flush() { if (hit) { for (i = 1; i <= n; i++) print buf[i]; print "\035" } n = 0; hit = 0 }
    /^      - / { flush(); on = 1 }
    !on { next }
    { buf[++n] = $0 }
    $0 !~ /^[[:space:]]*#/ && $0 ~ ENVIRON["E"] { hit = 1 }
    END { flush() }'
}

# A step's `run: |` body as commands: indentation and comments dropped, `\`
# continuations joined, and an inline `python3 -I -c '…'` program's lines left
# out (they are Python, not shell).
run_body() { # a step on stdin
  awk -v q="'" '
    /^        run: \|[[:space:]]*$/ { on = 1; next }
    on && /^        [A-Za-z-]+:/ { on = 0 }
    !on { next }
    { l = $0; sub(/^[[:space:]]+/, "", l) }
    py { if (substr(l, 1, 1) != q) next; py = 0 }
    l == "" || l ~ /^#/ { next }
    { if (acc != "") l = acc " " l; acc = "" }
    l ~ /\\$/ { sub(/[[:space:]]*\\$/, "", l); acc = l; next }
    { print l }
    l ~ ("python3 -I -c " q "$") { py = 1 }'
}

# Whether <body> holds the given lines consecutively.
has_seq() { # <body> <line>...
  local body=$'\n'"$1"$'\n' want=$'\n' l; shift
  for l in "$@"; do want+="${l}"$'\n'; done
  [[ "${body}" == *"${want}"* ]]
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
  local lg="$1/${LAUNCH_GATE_IOS_REL}" sdk="$1/${SDK_CHECK_REL}" bc="$1/${BUILD_CHECK_REL}"
  local f errs=0 key publishers ios_jobs writers builders
  local upload='^[[:space:]]*(-[[:space:]]+)?run:[[:space:]]+bundle exec fastlane ios upload'
  local drive='^[[:space:]]*command:[[:space:]]+bash tooling/e2e/ci/run-launch-gate-ios\.sh '
  for f in "${rel}" "${ci}" "${verdict}" "${lg}" "${sdk}" "${bc}"; do
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
    job_block "${rel}" "${key}" | gated_step "$(run_line '\.\./scripts/ci/check_ios_app_loadable\.sh')" "${upload}" \
      || err "G4: ${key} must run check_ios_app_loadable.sh before fastlane ios upload, unconditionally and as its step's whole command"
    job_block "${rel}" "${key}" | gated_step "$(run_line '\.\./scripts/ci/check_ios_app_sdk\.sh')" "${upload}" \
      || err "G9: ${key} must run check_ios_app_sdk.sh before fastlane ios upload, unconditionally and as its step's whole command"
  done
  gated_step "$(run_line 'scripts/ci/check_ios_app_sdk\.sh' '--simulator "\$\{CANDIDATE_APP\}"[[:space:]]*$')" "${drive}" <"${lg}" \
    || err "G9: launch-gate-ios.yml must run check_ios_app_sdk.sh --simulator on the candidate before launching it, unconditionally and as its step's whole command"
  builders="$(jobs_matching "${bc}" '^[[:space:]]*(-[[:space:]]+)?run:[[:space:]]+flutter build ios ')"
  [[ -n "${builders}" ]] || err "G9: no build-check.yml job builds the iOS app (expected ios)"
  for key in ${builders}; do
    job_block "${bc}" "${key}" | gated_step "$(run_line '\.\./scripts/ci/check_ios_app_sdk\.sh')" '' \
      || err "G9: build-check.yml ${key} must run check_ios_app_sdk.sh on its iOS build, unconditionally and as its step's whole command"
  done

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

  local rt body n
  # shellcheck disable=SC2016 # workflow text, expanded by the workflow's shell
  local scan='bash tooling/e2e/ci/scan-logs.sh --manifest-dir /tmp/haven-soak/needles --sink diag="${summary}" --report /tmp/ios-logscan/runner-tests.ndjson'
  rt="$(steps_with '-only-testing:RunnerTests' <"${lg}")"
  n="$(grep -c $'^\035$' <<<"${rt}" || true)"
  if [[ "${n}" != 1 ]]; then
    err "G11: launch-gate-ios.yml must run RunnerTests (xcodebuild test -only-testing:RunnerTests) in exactly one step (found ${n})"
  else
    rt="${rt%$'\n\035'}"
    body="$(run_body <<<"${rt}")"
    D="${drive}" awk '
      $0 ~ ENVIRON["D"] { drive = 1 }
      /^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]+actions\/upload-artifact@/ { up = 1 }
      !/^[[:space:]]*#/ && /-only-testing:RunnerTests/ && !seen { seen = 1; ok = drive && !up }
      END { exit !ok }' "${lg}" \
      || err "G11: the RunnerTests step must come after the drive and before every upload"
    grep -Fxq "        if: \${{ !cancelled() && steps.sim.outcome == 'success' && steps.drive.outcome != 'skipped' }}" <<<"${rt}" \
      || err "G11: the RunnerTests step must run whenever the simulator booted and the drive ran (its pinned if:)"
    ! grep -Eq '^      (- |  )continue-on-error:' <<<"${rt}" \
      || err "G11: the RunnerTests step must not be continue-on-error"
    [[ "$(head -n1 <<<"${body}")" == 'set -euo pipefail' ]] \
      || err "G11: the RunnerTests step must start with set -euo pipefail"
    grep -Eq '^\(cd haven/ios && xcodebuild test -workspace Runner\.xcworkspace -scheme Runner .*-only-testing:RunnerTests .*\) >"\$\{work\}/xcodebuild\.out" 2>&1 \|\| rc=\$\?$' <<<"${body}" \
      || err "G11: xcodebuild test must write its transcript to \${work}/xcodebuild.out and keep its rc (2>&1 || rc=\$?)"
    # shellcheck disable=SC2016
    grep -Fxq 'passed="$(grep -cE "^[[:space:]]*Test [Cc]ase '"'.*'"' passed" "${summary}" || true)"' <<<"${body}" \
      || err "G11: the passed count must be read from the summary's passed test cases"
    # shellcheck disable=SC2016
    grep -Fxq 'failed="$(grep -cE "^[[:space:]]*Test [Cc]ase '"'.*'"' failed" "${summary}" || true)"' <<<"${body}" \
      || err "G11: the failed count must be read from the summary's failed test cases"
    # shellcheck disable=SC2016
    has_seq "${body}" 'if (( rc != 0 || failed != 0 )); then' \
      'echo "::error::RunnerTests failed (xcodebuild rc ${rc}, ${failed} failed)"' 'exit 1' \
      || err "G11: a non-zero xcodebuild rc or a failed test case must echo its ::error:: and exit 1"
    has_seq "${body}" 'if (( passed == 0 )); then' 'echo "::error::RunnerTests ran no test case"' 'exit 1' \
      || err "G11: a run in which no test case passed must echo its ::error:: and exit 1"
    grep -Fxq -- "${scan}" <<<"${body}" \
      || err "G11: the RunnerTests summary must be scan-logs.sh's sink, at a command position whose failure fails the step"
    S="${scan}" awk '
      $0 == ENVIRON["S"] { s = 1 }
      /(^|[;&|(]|then |do |else )[[:space:]]*(cat|tail|head|less|more)([[:space:]]|$)/ && !(s && $0 == "cat \"${summary}\"") { bad = 1 }
      END { exit bad }' <<<"${body}" \
      || err "G11: the RunnerTests step may print only the scanned summary (cat \"\${summary}\"), after its scan"
    S="${scan}" awk '
      s && /summary/ && $0 != "cat \"${summary}\"" { bad = 1 }
      $0 == ENVIRON["S"] { s = 1 }
      END { exit bad }' <<<"${body}" \
      || err "G11: nothing may write or rename the RunnerTests summary after its scan"
  fi

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
  expect "the XCTest step is continue-on-error" 1 "${LAUNCH_GATE_IOS_REL}" 's/^(        if: .*steps\.sim\.outcome == .success. && steps\.drive\.outcome != .skipped. \}\})$/\1\n        continue-on-error: true/'
  expect "the XCTest step never runs" 1 "${LAUNCH_GATE_IOS_REL}" 's/^        if: .*steps\.sim\.outcome == .success. && steps\.drive\.outcome != .skipped. \}\}$/        if: ${{ false }}/'
  expect "a failed test case exits 0" 1 "${LAUNCH_GATE_IOS_REL}" '/echo "::error::RunnerTests failed /{n;s/exit 1/exit 0/}'
  expect "a run with no test case exits 0" 1 "${LAUNCH_GATE_IOS_REL}" '/echo "::error::RunnerTests ran no test case"/{n;s/exit 1/exit 0/}'
  expect "a failed run is never tested for" 1 "${LAUNCH_GATE_IOS_REL}" 's/if \(\( rc != 0 \|\| failed != 0 \)\); then/if false; then/'
  expect "a run with no passed case is never tested for" 1 "${LAUNCH_GATE_IOS_REL}" 's/if \(\( passed == 0 \)\); then/if false; then/'
  expect "xcodebuild's failure is swallowed" 1 "${LAUNCH_GATE_IOS_REL}" 's/2>&1 \|\| rc=\$\?$/2>\&1 || true/'
  expect "the XCTest step runs after an upload" 1 "${LAUNCH_GATE_IOS_REL}" 's/^(      - name: Run the app.s XCTest bundle)$/      - uses: actions\/upload-artifact@v6\n\1/'
  expect "the passed count is forged" 1 "${LAUNCH_GATE_IOS_REL}" 's/^(          passed=).*/\1"1"/'
  expect "the failed count is forged" 1 "${LAUNCH_GATE_IOS_REL}" 's/^(          failed=).*/\1"0"/'
  expect "the XCTest summary is printed unscanned" 1 "${LAUNCH_GATE_IOS_REL}" '/--sink diag="\$\{summary\}"/d; /bash tooling\/e2e\/ci\/scan-logs\.sh --manifest-dir \/tmp\/haven-soak\/needles \\$/d'
  expect "the XCTest summary is printed before its scan" 1 "${LAUNCH_GATE_IOS_REL}" '/^          cat "\$\{summary\}"$/d; s/^(          bash tooling\/e2e\/ci\/scan-logs\.sh --manifest-dir \/tmp\/haven-soak\/needles \\)$/          cat "${summary}"\n\1/'
  expect "the XCTest summary's scan cannot fail the step" 1 "${LAUNCH_GATE_IOS_REL}" 's/(--sink diag="\$\{summary\}" --report \/tmp\/ios-logscan\/runner-tests\.ndjson)$/\1 || true/'
  expect "the XCTest scan reads another file" 1 "${LAUNCH_GATE_IOS_REL}" 's/--sink diag="\$\{summary\}"/--sink diag=\/dev\/null/'
  expect "the XCTest summary is written after its scan" 1 "${LAUNCH_GATE_IOS_REL}" '/^          printf .RunnerTests: xcodebuild rc/{h;d}; /--report \/tmp\/ios-logscan\/runner-tests\.ndjson$/G'
  expect "the XCTest step runs without set -e" 1 "${LAUNCH_GATE_IOS_REL}" '/name: Run the app.s XCTest bundle/,/set -euo pipefail/{/set -euo pipefail/d}'
  expect "the IPA load check only echoes" 1 "${RELEASE_REL}" 's/^(        run: )(bash \.\.\/scripts\/ci\/check_ios_app_loadable\.sh .*)$/\1echo \2/'
  expect "the IPA load check's failure is ignored" 1 "${RELEASE_REL}" 's/^(        run: bash \.\.\/scripts\/ci\/check_ios_app_loadable\.sh .*)$/\1 || true/'
  expect "the IPA load check is continue-on-error" 1 "${RELEASE_REL}" 's/^(        run: bash \.\.\/scripts\/ci\/check_ios_app_loadable\.sh .*)$/        continue-on-error: true\n\1/'
  expect "the IPA SDK check only echoes" 1 "${RELEASE_REL}" 's/^(        run: )(bash \.\.\/scripts\/ci\/check_ios_app_sdk\.sh .*)$/\1echo \2/'
  expect "the IPA SDK check's failure is ignored" 1 "${RELEASE_REL}" 's/^(        run: bash \.\.\/scripts\/ci\/check_ios_app_sdk\.sh .*)$/\1 || true/'
  expect "the IPA SDK check is skipped" 1 "${RELEASE_REL}" 's/^(        run: bash \.\.\/scripts\/ci\/check_ios_app_sdk\.sh .*)$/        if: false\n\1/'
  expect "the gate's SDK check's failure is ignored" 1 "${LAUNCH_GATE_IOS_REL}" 's/^(        run: bash scripts\/ci\/check_ios_app_sdk\.sh .*)$/\1 || true/'
  expect "the gate's SDK check is continue-on-error" 1 "${LAUNCH_GATE_IOS_REL}" 's/^(        run: bash scripts\/ci\/check_ios_app_sdk\.sh .*)$/        continue-on-error: true\n\1/'
  expect "build-check drops its SDK check" 1 "${BUILD_CHECK_REL}" '/check_ios_app_sdk\.sh/d'
  expect "build-check's SDK check's failure is ignored" 1 "${BUILD_CHECK_REL}" 's/^(        run: bash \.\.\/scripts\/ci\/check_ios_app_sdk\.sh .*)$/\1 || true/'
  expect "build-check's SDK check is skipped" 1 "${BUILD_CHECK_REL}" 's/^(        run: bash \.\.\/scripts\/ci\/check_ios_app_sdk\.sh .*)$/        if: false\n\1/'
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
