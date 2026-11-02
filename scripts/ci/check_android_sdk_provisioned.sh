#!/usr/bin/env bash
# CI guard: no Android lane can boot an emulator against an unverified SDK, or
# boot a different emulator binary from the one that was verified.
#
# # The invariant
#
# Every workflow job that uses `reactivecircus/android-emulator-runner` runs
# `tooling/e2e/ci/provision-android-sdk.sh` first, unconditionally, with the
# api/target/arch that job's action steps declare — and every such step boots
# headless, because headless is what the provisioning step verified.
#
# # Why
#
# The action installs the SDK packages itself, with bare `sdkmanager --install`
# calls it tries once and verifies never. When a download fails the action
# stops, and the last thing it prints is its unconditional teardown ("could not
# connect to TCP port 5554") — a message about the emulator, with no test run
# and no hint that the fault was a download (CI run 35524002720). The
# provisioning step installs the same packages first, retries what did not
# land, grades each one by what is on disk, and fails with a message that says
# infrastructure — after which the action's own installs are no-ops.
#
# That only holds where the step RUNS, and there are two ways to lose it
# silently: leave it out of a new lane, or put it after the first use of the
# action (the AVD-snapshot step boots an emulator too, so "before the drive" is
# not far enough). A third is subtler — gating it on the AVD cache miss. The
# cache holds `~/.android/avd/*` only, so a cache HIT still needs the emulator
# binary and the system image, which is why the step carries no `if:` and why
# this guard refuses one.
#
# The arguments are checked against the action's own `with:` block rather than
# pinned here: a lane that moves to another api level must move both, and a
# provisioning step that installs `android-34` in front of an action asking for
# `android-35` would be a silent no-op followed by the same red.
#
# The provisioning step proves the emulator runs with `emulator -no-window
# -version`, and `-no-window` is how the launcher picks the HEADLESS qemu
# binary; the windowed one links desktop libraries a runner does not have (CI
# run 35536892150: 13 lanes red on a probe that omitted the flag). That probe
# vouches for a lane only while the lane boots the same binary, so every
# emulator step must say `-no-window` itself — the action's default options
# include it today, and a default nothing here pins is one that can change.
#
# # Checks
#
#   P1  A job with an emulator step has a provisioning step.
#   P2  It sits textually BEFORE the job's first emulator step.
#   P3  Its three arguments equal that step's api-level/target/arch.
#   P4  It carries no `if:` — a conditional provisioning is one a cache hit
#       skips.
#   P5  Every emulator step in the job declares the same api/target/arch, since
#       one provisioning call has to cover all of them.
#   P6  No provisioning step in a job that has no emulator step: a stale step is
#       indistinguishable, in review, from a backstop.
#   P7  Every emulator step declares `emulator-options` carrying the token
#       `-no-window` — the binary the provisioning step verified.
#   P8  A job that builds an APK before its provisioning step runs
#       `tooling/e2e/ci/release-apk-build-outputs.sh` after the last such
#       build and before that step. The build tree and cargokit's Rust target
#       stay on disk otherwise, and on a 72 GB runner one APK's outputs left
#       too little room for the system image to unpack (CI run 41322563075):
#       the provisioning step then fails every attempt, for a reason no retry
#       can fix.
#
# Pure bash/awk over the checked-out tree, no toolchain and no Android SDK —
# belongs in repo-guards.yml.
#
# Usage:
#   check_android_sdk_provisioned.sh              # check the repo
#   check_android_sdk_provisioned.sh --self-test
#
# Exit codes:
#   0  every emulator job provisions its SDK first
#   1  a job violates one of P1-P8
#   2  the extractor cannot read a step list it must grade, or the self-test
#      failed (the guard itself cannot vouch for the lanes)

set -euo pipefail

SCRIPT_NAME="check_android_sdk_provisioned"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly PROVISION_SH="tooling/e2e/ci/provision-android-sdk.sh"
readonly EMULATOR_ACTION="reactivecircus/android-emulator-runner"

log() { printf '\033[1;34m[%s]\033[0m %s\n' "${SCRIPT_NAME}" "$*"; }
fail_msg() { printf '\033[1;31m[%s] FAIL:\033[0m %s\n' "${SCRIPT_NAME}" "$*" >&2; }
misconfig() { printf '\033[1;31m[%s] ERROR:\033[0m %s\n' "${SCRIPT_NAME}" "$*" >&2; exit 2; }

VIOLATIONS=0
note_violation() { fail_msg "$*"; VIOLATIONS=$((VIOLATIONS + 1)); }

# ---------------------------------------------------------------------------
# Extraction
#
# Indentation-driven, like check_e2e_step_timeout_ordering.sh's and for the same
# reason: a YAML library would buy nothing here (every value read is a plain
# scalar or a command line) and would cost a runtime dependency in a job that
# has none.
#
# One TSV record per step:
#   file  job  index  name  uses  api  target  arch  has_if  headless
#   provision_args  build_at  release_at
#
# `headless` is "yes" when the step's `emulator-options` holds the token
# `-no-window`, "no" when it holds options without it, "-" when the step
# declares none. The value is read inline or from a block scalar (`>`, `|`, with
# any chomping indicator), whose lines are the ones indented past the key.
#
# `provision_args` is the three arguments of a provisioning invocation in the
# step's body, or "-". Full-line comments never reach the body, so a
# commented-out step is not a step and a commented-out invocation is not one
# either.
#
# `build_at` and `release_at` are the offsets in that body of the LAST APK
# build and the LAST release of its outputs, or 0, so P8 can order the two
# within one step as well as across steps.
# ---------------------------------------------------------------------------
extract_steps() {
  local file="$1"
  awk -v file="${file}" -v prov="${PROVISION_SH}" '
    function last_at(s, re,   at, off) {
      at = 0; off = 0
      while (match(substr(s, off + 1), re)) { at = off + RSTART; off = at + RLENGTH - 1 }
      return at
    }
    function flush_step() {
      if (in_step) {
        args = "-"; build_at = 0; release_at = 0
        if (uses == "-") {
          if (match(body, prov " +[0-9]+ +[A-Za-z0-9_-]+ +[A-Za-z0-9_-]+")) {
            args = substr(body, RSTART + length(prov) + 1, RLENGTH - length(prov) - 1)
            gsub(/^ +| +$/, "", args)
            gsub(/ +/, " ", args)
          }
          build_at = last_at(body, "build_apk_with_retry\\.sh|tooling/e2e/ci/build-[A-Za-z0-9_-]+-apks?\\.sh|flutter +build +apk")
          release_at = last_at(body, "tooling/e2e/ci/release-apk-build-outputs\\.sh")
        }
        headless = "-"
        if (has_opts) headless = ((" " opts " ") ~ / -no-window /) ? "yes" : "no"
        printf "%s\t%s\t%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%d\t%d\n",
          file, job, idx, stepname, uses, api, target, arch, has_if, headless, args, build_at, release_at
        idx++
      }
      in_step = 0
      stepname = "(unnamed)"; uses = "-"; api = "-"; target = "-"; arch = "-"
      has_if = "no"; body = ""; has_opts = 0; in_opts = 0; opts = ""
    }
    function value(line) { sub(/^[^:]*:[[:space:]]*/, "", line); sub(/[[:space:]]+#.*$/, "", line); return line }
    BEGIN {
      job = "-"; idx = 0; in_jobs = 0; in_steps = 0; in_step = 0
      stepname = "(unnamed)"; uses = "-"; api = "-"; target = "-"; arch = "-"
      has_if = "no"; body = ""; has_opts = 0; in_opts = 0; opts = ""
    }
    /^[A-Za-z_][A-Za-z0-9_-]*:/ { flush_step(); in_steps = 0; in_jobs = ($0 ~ /^jobs:/); next }
    !in_jobs { next }
    /^  [A-Za-z_][A-Za-z0-9_.-]*:[[:space:]]*(#.*)?$/ {
      flush_step(); in_steps = 0; idx = 0
      job = $0; sub(/^  /, "", job); sub(/:[[:space:]]*(#.*)?$/, "", job)
      next
    }
    in_steps && /^    [A-Za-z_]/ { flush_step(); in_steps = 0 }
    /^    steps:[[:space:]]*(#.*)?$/ { in_steps = 1; next }
    !in_steps { next }
    /^      - / {
      flush_step()
      in_step = 1
      if ($0 ~ /^      - name:[[:space:]]*/) { stepname = $0; sub(/^      - name:[[:space:]]*/, "", stepname) }
      sub(/^      - /, "        ")
    }
    !in_step { next }
    /^[[:space:]]*#/ { next }
    /^        uses:/ { uses = value($0) }
    /^        if:/ { has_if = "yes" }
    /^          api-level:/ { api = value($0) }
    /^          target:/ { target = value($0) }
    /^          arch:/ { arch = value($0) }
    in_opts {
      if ($0 ~ /^           /) opts = opts " " $0
      else if (NF) in_opts = 0
    }
    /^          emulator-options:/ {
      has_opts = 1; opts = value($0)
      if (opts ~ /^[>|][-+0-9]*$/) { in_opts = 1; opts = "" }
    }
    { gsub(/\t/, " "); body = body " " $0 }
    END { flush_step() }
  ' "${file}"
}

is_emulator_step() {
  local u
  u="$(LC_ALL=C tr '[:upper:]' '[:lower:]' <<<"$1")"
  [[ "${u}" == *"${EMULATOR_ACTION}"* ]]
}

# ---------------------------------------------------------------------------
# The check
# ---------------------------------------------------------------------------

# check_dir <dir> — reports violations on stderr, leaves the counts in the
# globals. Globals rather than stdout because a `$(...)` capture would run this
# in a subshell and discard every increment, so the guard would report each
# violation and then exit 0.
EMU_STEPS=0
GRADED_JOBS=0
BUILDING_JOBS=0
check_dir() {
  local dir="$1" f
  local files=()
  while IFS= read -r f; do files+=("${f}"); done < <(find "${dir}" -maxdepth 1 -name '*.yml' | sort)
  (( ${#files[@]} > 0 )) || misconfig "no workflow files under ${dir}"

  EMU_STEPS=0
  GRADED_JOBS=0
  BUILDING_JOBS=0

  local file job idx name uses api target arch has_if headless args build_at release_at base
  for f in "${files[@]}"; do
    base="${f##*/}"
    local -A emu_first=() emu_spec=() emu_mixed=() prov_first=() prov_args=() prov_if=() jobs_seen=()
    local -A build_last=() build_name=() release_last=()
    while IFS=$'\t' read -r file job idx name uses api target arch has_if headless args build_at release_at; do
      jobs_seen[${job}]=1
      if is_emulator_step "${uses}"; then
        EMU_STEPS=$((EMU_STEPS + 1))
        # P7 — per step, not per job: the snapshot step boots an emulator too.
        case "${headless}" in
          no) note_violation "P7 ${base} :: ${job}: '${name}' (step ${idx}) passes emulator-options without \`-no-window\`. ${PROVISION_SH} verifies the HEADLESS emulator binary (\`emulator -no-window -version\`); without the flag this step boots the windowed one, which nothing verified and which links desktop libraries a runner does not have." ;;
          -) note_violation "P7 ${base} :: ${job}: '${name}' (step ${idx}) declares no emulator-options. The action's default options happen to include \`-no-window\`, but a default this repo does not pin is a default that can change — declare the options and keep \`-no-window\` among them." ;;
        esac
        local spec="${api}/${target}/${arch}"
        if [[ -z "${emu_first[${job}]:-}" ]]; then
          emu_first[${job}]="${idx}:${name}"
          emu_spec[${job}]="${spec}"
        elif [[ "${spec}" != "${emu_spec[${job}]}" ]]; then
          emu_mixed[${job}]="${spec}"
        fi
        continue
      fi
      [[ -z "${prov_first[${job}]:-}" ]] || continue
      if [[ "${args}" != "-" ]]; then
        prov_first[${job}]="${idx}:${name}"
        prov_args[${job}]="${args}"
        prov_if[${job}]="${has_if}"
        continue
      fi
      if (( build_at > 0 )); then
        build_last[${job}]="${idx} ${build_at}"
        build_name[${job}]="${name}"
      fi
      if (( release_at > 0 )); then release_last[${job}]="${idx} ${release_at}"; fi
    done < <(extract_steps "${f}")

    while IFS= read -r job; do
      [[ -n "${job}" ]] || continue
      local label="${base} :: ${job}"
      if [[ -z "${emu_first[${job}]:-}" ]]; then
        # P6 — a provisioning step where nothing boots an emulator.
        if [[ -n "${prov_first[${job}]:-}" ]]; then
          note_violation "P6 ${label}: runs ${PROVISION_SH} but has no ${EMULATOR_ACTION} step. Either the lane lost its emulator step, or this is a leftover — and a leftover reads exactly like a backstop."
        fi
        continue
      fi
      GRADED_JOBS=$((GRADED_JOBS + 1))
      local emu_idx="${emu_first[${job}]%%:*}" emu_name="${emu_first[${job}]#*:}"

      if [[ -n "${emu_mixed[${job}]:-}" ]]; then
        note_violation "P5 ${label}: its ${EMULATOR_ACTION} steps ask for different images (${emu_spec[${job}]} and ${emu_mixed[${job}]}). One provisioning step cannot cover both, so one of them would boot against an SDK nothing verified."
      fi

      if [[ -z "${prov_first[${job}]:-}" ]]; then
        note_violation "P1 ${label}: uses ${EMULATOR_ACTION} but never runs ${PROVISION_SH}. The action's own \`sdkmanager --install\` exits 0 after a failed download, so this job can boot an emulator that was never installed and red on the missing emulator instead."
        continue
      fi
      local prov_idx="${prov_first[${job}]%%:*}" prov_name="${prov_first[${job}]#*:}"

      if (( prov_idx > emu_idx )); then
        note_violation "P2 ${label}: '${prov_name}' (step ${prov_idx}) runs AFTER '${emu_name}' (step ${emu_idx}). The first use of the action is what needs the SDK — put the provisioning step above it."
      fi

      if [[ "${prov_if[${job}]}" == "yes" ]]; then
        note_violation "P4 ${label}: '${prov_name}' carries an \`if:\`. The AVD cache holds the AVD only, so a cache HIT still needs the emulator binary and the system image; a conditional provisioning is one that is skipped exactly when the packages are least likely to be there."
      fi

      local want="${emu_spec[${job}]//\// }"
      if [[ "${prov_args[${job}]}" != "${want}" ]]; then
        note_violation "P3 ${label}: '${prov_name}' provisions '${prov_args[${job}]}' but '${emu_name}' boots api-level/target/arch '${want}'. Provisioning a different image is a no-op followed by the same red."
      fi

      if [[ -n "${build_last[${job}]:-}" ]]; then
        BUILDING_JOBS=$((BUILDING_JOBS + 1))
        local b_idx b_at r_idx=-1 r_at=0
        read -r b_idx b_at <<<"${build_last[${job}]}"
        [[ -z "${release_last[${job}]:-}" ]] || read -r r_idx r_at <<<"${release_last[${job}]}"
        if (( r_idx < b_idx || (r_idx == b_idx && r_at < b_at) )); then
          note_violation "P8 ${label}: '${build_name[${job}]}' (step ${b_idx}) builds an APK before '${prov_name}' (step ${prov_idx}), and nothing between that build and that step runs tooling/e2e/ci/release-apk-build-outputs.sh. Its build tree and cargokit's Rust target stay on disk while the system image unpacks; on a 72 GB runner one APK's outputs left too little room, and the image failed to verify on every attempt (CI run 41322563075)."
        fi
      fi
    done < <(printf '%s\n' "${!jobs_seen[@]}" | sort)
  done
}

# ---------------------------------------------------------------------------
# Anti-vacuity: the extractor must see every emulator step that is really there.
#
# `uses:` appears exactly once per step, so the number of uncommented action
# lines IS the number of emulator steps. An equality, not a floor: reading FEWER
# means a step list this guard silently skipped, and reading MORE means the
# record parser is double-counting and the indices P2 compares are not what it
# thinks.
# ---------------------------------------------------------------------------
check_extractor_sees_the_dir() {
  local dir="$1" f n expect=0
  for f in "${dir}"/*.yml; do
    n="$(grep -v '^[[:space:]]*#' "${f}" | grep -ci "uses:.*${EMULATOR_ACTION}" || true)"
    expect=$((expect + n))
  done
  if (( expect != EMU_STEPS )); then
    misconfig "the extractor counted ${EMU_STEPS} emulator step(s) but ${expect} \`uses: ${EMULATOR_ACTION}\` line(s) exist under ${dir}. A step list is laid out in a way it cannot read (items at six spaces, each \`- <key>:\`), so some job is graded by nothing."
  fi
}

# ---------------------------------------------------------------------------
# Self-test (hermetic: synthetic workflows in a temp dir, no repo access)
# ---------------------------------------------------------------------------

readonly SELF_TEST_FIXTURES=26

write_wf() {
  local path="$1"; shift
  printf '%s\n' "$@" > "${path}"
}

# A job body with the real shape: a provisioning step, then the AVD-snapshot
# step, then the drive step. The arguments follow so a fixture can bend one.
# The two steps spell their options in the two forms the reader takes, and the
# drive script names the flag as well, at the block's own depth: a reader that
# ran the folded block past its end would find `-no-window` there and pass
# fixtures (13) and (16).
compliant_job() {
  local prov_args="${1:-34 google_apis x86_64}"
  printf '%s\n' \
    'jobs:' \
    '  lane:' \
    '    runs-on: ubuntu-latest' \
    '    steps:' \
    '      - name: Checkout' \
    '        uses: actions/checkout@v6' \
    '      - name: Provision the Android SDK' \
    "        run: bash tooling/e2e/ci/provision-android-sdk.sh ${prov_args}" \
    '      - name: Create AVD snapshot' \
    '        uses: reactivecircus/android-emulator-runner@v2' \
    '        with:' \
    '          api-level: 34' \
    '          target: google_apis' \
    '          arch: x86_64' \
    '          emulator-options: -no-window -gpu swiftshader_indirect' \
    '      - name: Drive' \
    '        uses: reactivecircus/android-emulator-runner@v2' \
    '        with:' \
    '          api-level: 34' \
    '          target: google_apis' \
    '          arch: x86_64' \
    '          emulator-options: >-' \
    '            -no-snapshot-save -no-window -gpu swiftshader_indirect' \
    '            -noaudio -no-boot-anim -camera-back none' \
    '          script: |' \
    '            echo booted with -no-window'
}

# build_step <name> <command> [norelease] — a run step that builds an APK,
# copies it out and, unless told not to, releases the build outputs.
build_step() {
  printf '%s\n' \
    "      - name: $1" \
    '        working-directory: haven' \
    '        run: |' \
    "          $2" \
    '          cp build/app/outputs/flutter-apk/app-debug.apk /tmp/scenario.apk'
  if [[ "${3:-}" != norelease ]]; then
    printf '%s\n' '          bash ../tooling/e2e/ci/release-apk-build-outputs.sh /tmp'
  fi
}

# splice_before <line> <text> — stdin with <text> spliced in above <line>.
splice_before() {
  local line
  while IFS= read -r line; do
    if [[ "${line}" == "$1" ]]; then printf '%s\n' "$2"; fi
    printf '%s\n' "${line}"
  done
}
readonly PROV_STEP='      - name: Provision the Android SDK'
readonly SNAPSHOT_STEP='      - name: Create AVD snapshot'
readonly BUILD_CMD='../scripts/ci/build_apk_with_retry.sh android-x64 --target=integration_test/e2e/e2e_combined.dart'
readonly RELEASE_STEP=$'      - name: Release\n        run: bash tooling/e2e/ci/release-apk-build-outputs.sh /tmp'

# run_case <dir> -> rc of a full check over <dir>, with the counters reset.
run_case() {
  local dir="$1" rc=0
  VIOLATIONS=0
  (
    check_dir "${dir}" >/dev/null 2>&1
    check_extractor_sees_the_dir "${dir}" >/dev/null 2>&1
    (( VIOLATIONS == 0 )) || exit 1
    exit 0
  ) || rc=$?
  printf '%s\n' "${rc}"
}

expect_rc() {
  local label="$1" want="$2" dir="$3" got
  got="$(run_case "${dir}")"
  if [[ "${got}" != "${want}" ]]; then
    echo "SELF-TEST FAIL (${label}): want rc=${want}, got rc=${got}" >&2
    return 1
  fi
  return 0
}

# expect_only <label> <check> <dir> <step> — rc 1 alone would not do: every
# check exits 1, so the fixture must fail for <check>, on the named job and
# step, and for nothing else.
expect_only() {
  local label="$1" check="$2" dir="$3" step="$4" out
  expect_rc "${label}" 1 "${dir}" || return 1
  out="$(check_dir "${dir}" 2>&1 >/dev/null)"
  if [[ "$(grep -c 'FAIL:' <<<"${out}" || true)" != 1 || "${out}" != *"${check} lane.yml :: lane: '${step}'"* ]]; then
    echo "SELF-TEST FAIL (${label}): want exactly one violation, ${check} naming lane.yml :: lane: '${step}'" >&2
    return 1
  fi
  return 0
}

run_self_test() {
  local tmp fail=0 ran=0 d
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  # (1) The real shape: provisioning first, two emulator steps behind it.
  ran=$(( ran + 1 )); d="${tmp}/ok"; mkdir -p "${d}"
  compliant_job > "${d}/lane.yml"
  expect_rc 1 0 "${d}" || fail=1

  # (2) P1 — no provisioning step at all.
  ran=$(( ran + 1 )); d="${tmp}/missing"; mkdir -p "${d}"
  grep -v 'provision-android-sdk.sh' <(compliant_job) | grep -v 'Provision the Android SDK' > "${d}/lane.yml"
  expect_rc 2 1 "${d}" || fail=1

  # (3) P2 — provisioning after the first use of the action.
  ran=$(( ran + 1 )); d="${tmp}/after"; mkdir -p "${d}"
  write_wf "${d}/lane.yml" \
    'jobs:' \
    '  lane:' \
    '    runs-on: ubuntu-latest' \
    '    steps:' \
    '      - name: Create AVD snapshot' \
    '        uses: reactivecircus/android-emulator-runner@v2' \
    '        with:' \
    '          api-level: 34' \
    '          target: google_apis' \
    '          arch: x86_64' \
    '          emulator-options: -no-window -gpu swiftshader_indirect' \
    '      - name: Provision the Android SDK' \
    '        run: bash tooling/e2e/ci/provision-android-sdk.sh 34 google_apis x86_64'
  expect_rc 3 1 "${d}" || fail=1

  # (4)-(6) P3 — each argument checked against the action's own `with:`.
  local bent label=4
  for bent in '35 google_apis x86_64' '34 default x86_64' '34 google_apis arm64-v8a'; do
    ran=$(( ran + 1 )); d="${tmp}/bent${label}"; mkdir -p "${d}"
    compliant_job "${bent}" > "${d}/lane.yml"
    expect_rc "${label}" 1 "${d}" || fail=1
    label=$(( label + 1 ))
  done

  # (7) A commented-out provisioning step is not a step.
  ran=$(( ran + 1 )); d="${tmp}/commented"; mkdir -p "${d}"
  compliant_job | sed 's|^      - name: Provision the Android SDK$|#      - name: Provision the Android SDK|; s|^        run: bash tooling/e2e/ci/provision-android-sdk.sh|#        run: bash tooling/e2e/ci/provision-android-sdk.sh|' > "${d}/lane.yml"
  expect_rc 7 1 "${d}" || fail=1

  # (8) P4 — a provisioning step gated on the AVD cache miss.
  ran=$(( ran + 1 )); d="${tmp}/gated"; mkdir -p "${d}"
  compliant_job \
    | sed "s|^        run: bash tooling/e2e/ci/provision-android-sdk.sh 34 google_apis x86_64$|        if: steps.avd-cache.outputs.cache-hit != 'true'\n        run: bash tooling/e2e/ci/provision-android-sdk.sh 34 google_apis x86_64|" \
    > "${d}/lane.yml"
  expect_rc 8 1 "${d}" || fail=1

  # (9) A job that boots no emulator needs nothing — the iOS jobs' shape.
  ran=$(( ran + 1 )); d="${tmp}/noemu"; mkdir -p "${d}"
  write_wf "${d}/lane.yml" \
    'jobs:' \
    '  ios:' \
    '    runs-on: macos-latest' \
    '    steps:' \
    '      - name: Checkout' \
    '        uses: actions/checkout@v6' \
    '      - name: Boot iOS simulator' \
    '        run: bash tooling/e2e/ci/boot-ios-sim.sh'
  expect_rc 9 0 "${d}" || fail=1

  # (10) P6 — a provisioning step left behind in a job with no emulator step.
  ran=$(( ran + 1 )); d="${tmp}/stale"; mkdir -p "${d}"
  write_wf "${d}/lane.yml" \
    'jobs:' \
    '  lane:' \
    '    runs-on: ubuntu-latest' \
    '    steps:' \
    '      - name: Provision the Android SDK' \
    '        run: bash tooling/e2e/ci/provision-android-sdk.sh 34 google_apis x86_64'
  expect_rc 10 1 "${d}" || fail=1

  # (11) P5 — two emulator steps in one job asking for different images.
  ran=$(( ran + 1 )); d="${tmp}/mixed"; mkdir -p "${d}"
  compliant_job | sed '0,/          api-level: 34/! s/          api-level: 34/          api-level: 35/' > "${d}/lane.yml"
  expect_rc 11 1 "${d}" || fail=1

  # (12) Anti-vacuity: a step list the extractor cannot read must stop the
  #      guard (rc 2), never pass as a clean lane. YAML allows an indentless
  #      sequence; this reader does not.
  ran=$(( ran + 1 )); d="${tmp}/unreadable"; mkdir -p "${d}"
  write_wf "${d}/lane.yml" \
    'jobs:' \
    '  lane:' \
    '    runs-on: ubuntu-latest' \
    '    steps:' \
    '    - name: Create AVD snapshot' \
    '      uses: reactivecircus/android-emulator-runner@v2' \
    '      with:' \
    '        api-level: 34'
  expect_rc 12 2 "${d}" || fail=1

  # (13) P7 — the drive step drops `-no-window`; the snapshot step keeps it.
  ran=$(( ran + 1 )); d="${tmp}/windowed"; mkdir -p "${d}"
  compliant_job | sed 's/-no-snapshot-save -no-window -gpu/-no-snapshot-save -gpu/' > "${d}/lane.yml"
  expect_only 13 P7 "${d}" 'Drive' || fail=1

  # (14) P7 — an emulator step with no emulator-options at all.
  ran=$(( ran + 1 )); d="${tmp}/defaulted"; mkdir -p "${d}"
  grep -v 'emulator-options: -no-window' <(compliant_job) > "${d}/lane.yml"
  expect_only 14 P7 "${d}" 'Create AVD snapshot' || fail=1

  # (15) The flag on the SECOND continuation line of the folded form counts.
  ran=$(( ran + 1 )); d="${tmp}/secondline"; mkdir -p "${d}"
  compliant_job \
    | sed 's/-no-snapshot-save -no-window -gpu/-no-snapshot-save -gpu/; s/-noaudio -no-boot-anim/-noaudio -no-window -no-boot-anim/' \
    > "${d}/lane.yml"
  expect_rc 15 0 "${d}" || fail=1

  # (16) P7 — the token, not a substring.
  ran=$(( ran + 1 )); d="${tmp}/substring"; mkdir -p "${d}"
  compliant_job | sed 's/-no-snapshot-save -no-window -gpu/-no-snapshot-save -no-window-foo -gpu/' > "${d}/lane.yml"
  expect_only 16 P7 "${d}" 'Drive' || fail=1

  # (17) P8 — the fixed shape: build, copy out, release, then provision.
  ran=$(( ran + 1 )); d="${tmp}/released"; mkdir -p "${d}"
  compliant_job | splice_before "${PROV_STEP}" "$(build_step Build "${BUILD_CMD}")" > "${d}/lane.yml"
  expect_rc 17 0 "${d}" || fail=1

  # (18)-(21) P8 — no release, for each way a lane builds an APK.
  local cmd
  label=18
  for cmd in "${BUILD_CMD}" \
    'bash ../tooling/e2e/ci/build-integration-apks.sh' \
    'bash ../tooling/e2e/ci/build-b3-real-gps-apk.sh integration_test/b3_real_gps_test.dart' \
    'flutter build apk --debug --target-platform android-x64'; do
    ran=$(( ran + 1 )); d="${tmp}/unreleased${label}"; mkdir -p "${d}"
    compliant_job | splice_before "${PROV_STEP}" "$(build_step Build "${cmd}" norelease)" > "${d}/lane.yml"
    expect_only "${label}" P8 "${d}" 'Build' || fail=1
    label=$(( label + 1 ))
  done

  # (22) P8 — a release ahead of the build in the same step frees nothing.
  ran=$(( ran + 1 )); d="${tmp}/earlyrelease"; mkdir -p "${d}"
  compliant_job \
    | splice_before "${PROV_STEP}" "$(build_step Build "bash ../tooling/e2e/ci/release-apk-build-outputs.sh /tmp; ${BUILD_CMD}" norelease)" \
    > "${d}/lane.yml"
  expect_only 22 P8 "${d}" 'Build' || fail=1

  # (23) P8 — a release after provisioning comes too late.
  ran=$(( ran + 1 )); d="${tmp}/laterelease"; mkdir -p "${d}"
  compliant_job \
    | splice_before "${PROV_STEP}" "$(build_step Build "${BUILD_CMD}" norelease)" \
    | splice_before "${SNAPSHOT_STEP}" "${RELEASE_STEP}" > "${d}/lane.yml"
  expect_only 23 P8 "${d}" 'Build' || fail=1

  # (24) P8 — a commented-out release is not a release.
  ran=$(( ran + 1 )); d="${tmp}/commentedrelease"; mkdir -p "${d}"
  compliant_job \
    | splice_before "${PROV_STEP}" "$(build_step Build "${BUILD_CMD}" | sed 's|^          bash \.\./tooling/e2e/ci/release-apk|          # bash ../tooling/e2e/ci/release-apk|')" \
    > "${d}/lane.yml"
  expect_only 24 P8 "${d}" 'Build' || fail=1

  # (25) P8 — the release must follow the LAST build: a second build after it
  #      refills the tree.
  ran=$(( ran + 1 )); d="${tmp}/rebuilt"; mkdir -p "${d}"
  compliant_job \
    | splice_before "${PROV_STEP}" "$(build_step 'Build first' "${BUILD_CMD}"; build_step 'Build second' "${BUILD_CMD}" norelease)" \
    > "${d}/lane.yml"
  expect_only 25 P8 "${d}" 'Build second' || fail=1

  # (26) A release in a step of its own, after the last build, counts.
  ran=$(( ran + 1 )); d="${tmp}/ownstep"; mkdir -p "${d}"
  compliant_job \
    | splice_before "${PROV_STEP}" "$(build_step 'Build first' "${BUILD_CMD}" norelease; build_step 'Build second' "${BUILD_CMD}" norelease; printf '%s\n' "${RELEASE_STEP}")" \
    > "${d}/lane.yml"
  expect_rc 26 0 "${d}" || fail=1

  VIOLATIONS=0
  if (( fail )); then
    echo "${SCRIPT_NAME}: SELF-TEST FAILED" >&2
    return 1
  fi
  if (( ran != SELF_TEST_FIXTURES )); then
    echo "${SCRIPT_NAME}: SELF-TEST FAILED — ran ${ran} fixture(s), expected exactly ${SELF_TEST_FIXTURES}; a fixture was added or removed without moving the pin" >&2
    return 1
  fi
  echo "${SCRIPT_NAME}: self-test passed (${ran}/${SELF_TEST_FIXTURES} fixtures: the real lane shape passes; a missing provisioning step, one placed after the first use of the action, a wrong api level, target or arch, a commented-out one, and one gated on an \`if:\` each fail; a job that boots no emulator needs none while a provisioning step left in one fails; two emulator steps asking for different images fail; a step list this reader cannot parse stops the guard rather than passing it; and an emulator step that drops \`-no-window\`, declares no emulator-options, or carries only \`-no-window-foo\` fails P7 naming its job and step, while the flag on the second line of a folded block passes; an APK build released before provisioning passes, in its own step or the build's, while one never released — for each of the four ways a lane builds — one released ahead of the build, after provisioning, only in a comment, or ahead of a second build fails P8 naming that build)."
  return 0
}

# ---------------------------------------------------------------------------

if [[ "${1:-}" == "--self-test" && $# -eq 1 ]]; then
  run_self_test
  exit $?
fi
(( $# == 0 )) || misconfig "usage: ${SCRIPT_NAME}.sh [--self-test]"

WORKFLOW_DIR="${REPO_ROOT}/.github/workflows"
[[ -d "${WORKFLOW_DIR}" ]] || misconfig "${WORKFLOW_DIR} does not exist"

log "checking Android SDK provisioning in .github/workflows"
check_dir "${WORKFLOW_DIR}"
check_extractor_sees_the_dir "${WORKFLOW_DIR}"
(( GRADED_JOBS > 0 )) || misconfig "no job uses ${EMULATOR_ACTION}; this guard has gone blind rather than found a clean tree."

if (( VIOLATIONS > 0 )); then
  fail_msg "${VIOLATIONS} violation(s). Every job that boots an emulator must run ${PROVISION_SH} first, unconditionally, with that job's own api/target/arch, after releasing the outputs of any APK it built; and every emulator step must boot with \`-no-window\`."
  exit 1
fi
log "OK — ${GRADED_JOBS} job(s) with ${EMU_STEPS} emulator step(s); each provisions and verifies its SDK first, every emulator step boots the headless binary that was verified, and the ${BUILDING_JOBS} that build an APK first release its build outputs before provisioning."
