#!/usr/bin/env bash
#
# Installs — and then VERIFIES — every Android SDK package the emulator action
# needs, before the first step in the job that uses it.
#
# ## Why this exists
#
# `reactivecircus/android-emulator-runner` opens each of its runs with an
# "Install Android SDK" group of bare `sdkmanager --install` calls, tried once.
# In CI run 35524002720 (e2e-relay-customization) the emulator's download
# failed — `Warning: Failed to download package!` — sdkmanager exited non-zero,
# and the action stopped there. What it PRINTED last was its unconditional
# teardown, `adb -s emulator-5554 emu kill` -> "could not connect to TCP port
# 5554": a message about the emulator, from a job whose real fault was a
# transient download, in which no AVD was created and no test ever ran. CI run
# 35280144455 (network-reconnect) had the other shape of the same class: the
# emulator zip arrived corrupt, so the package directory existed and the binary
# inside it did not run.
#
# Nothing retried either one. This step does, before the action gets its turn:
# it installs unconditionally (the image's emulator is behind channel 0 on most
# runs, so there IS a download to make, and making it here puts it under the
# retry), and once the packages are present and current the action's own
# `sdkmanager --install` calls are no-ops (measured: 49 s of installs on a cold
# runner, 5 s on the second use in the same job).
#
# The retry is what answers the observed failure. The verification is what
# makes the retry safe to believe, and what answers the corrupt-zip one: every
# attempt is graded by what landed on disk — the package directory with its
# sdkmanager-written manifest, and for the emulator a binary that actually runs
# — never by sdkmanager's exit code, in either direction. A directory that
# fails that grading is REMOVED before the retry: a half-extracted package that
# keeps its directory would be read as installed by the next attempt and by the
# action alike.
#
# ## Bounds, and the worst case the step timeout derives from
#
# Each attempt is capped (ATTEMPT_TIMEOUT_SECS), and the whole run carries a
# budget (BUDGET_SECS): no new attempt starts once the budget is spent. So the
# longest this can take is one budget plus the one attempt that may start just
# inside it plus that attempt's emulator probe:
#
#     360 + 180 + 30 = 570 s = 9.5 min
#
# which is what each lane's `timeout-minutes: 11` is derived from (9.5 plus the
# step's own process startup and reporting, which the budget's clock does not
# cover, rounded up). The budget is ~7x the 49 s a cold cache-miss run actually
# spends here, so it can only fire on a genuine stall.
#
# Note which failure the three attempts are FOR: the observed one fails fast
# (the failed download above returned in 3 s), so all three attempts fit the
# budget comfortably. A package that instead STALLS eats its whole attempt cap,
# and the budget then cuts the third attempt — deliberately, because a third
# stall is no longer a transient.
#
# ## What this does NOT install
#
# The action also installs `build-tools;<latest>`, at a version it resolves from
# the remote repository list at run time. That version is not knowable here, and
# the ubuntu-latest image already ships it (the action's call returns in ~1.2 s),
# so it is left to the action. It is the one package in that group still
# un-hardened; a "Failed to download package!" naming build-tools is the shape
# to look for if this class recurs anyway.
#
# Usage:
#   provision-android-sdk.sh <api-level> <target> <arch>
#   provision-android-sdk.sh --self-test
#
# The api/target/arch are ARGUMENTS, never constants: they must equal the `with:`
# values of the emulator step they precede, and
# scripts/ci/check_android_sdk_provisioned.sh is what keeps them equal.
#
# sdkmanager is taken from `${ANDROID_HOME:-$ANDROID_SDK_ROOT}/cmdline-tools/
# latest/bin`, where the runner image publishes it, and failing that from PATH,
# where the action itself resolves the bare name.
#
# Exit codes:
#   0  every package is installed and verified
#   2  this step cannot run at all: bad usage, or no sdkmanager in either place
#      (a broken step, distinct from a failed provisioning)
#   3  SDK provisioning failed — infrastructure, and no test ran

set -euo pipefail

readonly SCRIPT_NAME="provision-android-sdk.sh"

# Attempts per package, and the pauses between them. Three attempts because the
# observed failure is a single transient CDN miss and a third try lands on a
# materially different network moment; the pauses grow so the second retry is
# not merely the first one repeated.
readonly PACKAGE_ATTEMPTS=3
readonly BACKOFF_SECS=(10 30)
# ~5x the worst single-package install measured on a cold runner (34.7 s, the
# system image), so it bounds a stall and never a slow day.
readonly ATTEMPT_TIMEOUT_SECS=180
# The whole-run budget. See the worst case above.
readonly BUDGET_SECS=360
# The emulator smoke probe. It runs once per emulator attempt, so it is a term
# of the worst case; 30 s is far past the ~1 s it takes to print a version.
readonly EMULATOR_PROBE_SECS=30

readonly RC_BROKEN=2
readonly RC_PROVISION_FAILED=3

# sdkmanager prompts for any licence the runner image has not pre-accepted, and
# a prompt reading an empty stdin answers "no" and fails the install. Feed it
# acceptances instead of depending on the image's licence state. A here-string,
# not a pipeline: under `pipefail` a producer that dies of SIGPIPE when the
# reader finishes early would fail the whole install.
readonly LICENSE_REPLIES="$(printf 'y\n%.0s' {1..64})"

# Resolved by provision_android_sdk() from the environment, per call, so the
# self-test can point them at a temporary SDK root.
SDK_ROOT=""
SDKMANAGER=""

# The two clock functions the self-test replaces, so it needs neither real time
# nor a knob a workflow could set. Deliberately NOT env-overridable: an
# environment that can shorten the backoff or fake the budget is an environment
# that can weaken the real run.
provision_sleep() { sleep "$1"; }
provision_elapsed_secs() { printf '%s\n' "${SECONDS}"; }

usage() {
  echo "ERROR: usage: ${SCRIPT_NAME} <api-level> <target> <arch>  |  ${SCRIPT_NAME} --self-test" >&2
  echo "  e.g. ${SCRIPT_NAME} 34 google_apis x86_64 — the same values as the" >&2
  echo "  emulator step's api-level/target/arch." >&2
}

# package_dir <pkg> — where sdkmanager unpacks <pkg> under the SDK root: its id
# with `;` as the path separator.
package_dir() { printf '%s/%s\n' "${SDK_ROOT}" "${1//;//}"; }

# verify_package <pkg> — 0 only when <pkg> is really there.
#
# The directory alone proves nothing (a failed download leaves one behind), so
# the sdkmanager-written manifest must be in it, and the emulator must also RUN:
# that is the check that catches the corrupt-zip variant, where every file is in
# place and the binary is not an executable.
verify_package() {
  local pkg="$1" dir
  dir="$(package_dir "${pkg}")"
  [[ -d "${dir}" ]] || return 1
  [[ -f "${dir}/source.properties" || -f "${dir}/package.xml" ]] || return 1
  if [[ "${pkg}" == "emulator" ]]; then
    [[ -x "${dir}/emulator" ]] || return 1
    timeout "${EMULATOR_PROBE_SECS}" "${dir}/emulator" -version >/dev/null 2>&1 || return 1
  fi
  return 0
}

# remove_partial <pkg> — drop a package directory that failed verification, so
# the next attempt (and the action after it) cannot read it as installed.
remove_partial() {
  local pkg="$1" dir
  dir="$(package_dir "${pkg}")"
  # Never anything but a directory strictly inside the SDK root.
  [[ "${dir}" == "${SDK_ROOT}/"?* && -d "${dir}" ]] || return 0
  rm -rf "${dir}"
  return 0
}

# install_package <pkg> — 0 once <pkg> verifies, 1 when the attempts or the
# budget run out.
install_package() {
  local pkg="$1" attempt rc elapsed
  for (( attempt = 1; attempt <= PACKAGE_ATTEMPTS; attempt++ )); do
    elapsed="$(provision_elapsed_secs)"
    if (( elapsed >= BUDGET_SECS )); then
      printf '%s: budget of %ds spent before attempt %d/%d for %s.\n' \
        "${SCRIPT_NAME}" "${BUDGET_SECS}" "${attempt}" "${PACKAGE_ATTEMPTS}" "${pkg}"
      return 1
    fi
    rc=0
    # sdkmanager's own output is discarded, as the action discards it: it is
    # progress bars and download hosts, and the attributable line is the one
    # printed here.
    timeout -k 10 "${ATTEMPT_TIMEOUT_SECS}" "${SDKMANAGER}" --install "${pkg}" --channel=0 \
      >/dev/null 2>&1 <<<"${LICENSE_REPLIES}" || rc=$?
    if verify_package "${pkg}"; then
      printf '%s: %s verified on attempt %d/%d (sdkmanager rc %d).\n' \
        "${SCRIPT_NAME}" "${pkg}" "${attempt}" "${PACKAGE_ATTEMPTS}" "${rc}"
      return 0
    fi
    printf '%s: %s did NOT verify on attempt %d/%d (sdkmanager rc %d); removing the partial package directory.\n' \
      "${SCRIPT_NAME}" "${pkg}" "${attempt}" "${PACKAGE_ATTEMPTS}" "${rc}"
    remove_partial "${pkg}"
    # No pause once the budget is spent: the loop's next act would be to refuse
    # the attempt anyway, and a backoff slept first is time the stated worst
    # case (budget + one attempt + its probe) does not contain.
    elapsed="$(provision_elapsed_secs)"
    if (( attempt < PACKAGE_ATTEMPTS && elapsed < BUDGET_SECS )); then
      provision_sleep "${BACKOFF_SECS[attempt - 1]}"
    fi
  done
  return 1
}

# provision_android_sdk <api-level> <target> <arch>
provision_android_sdk() {
  local api="$1" target="$2" arch="$3"

  # The `::error::` lines go to STDOUT: GitHub parses workflow commands out of
  # the step's standard output, so a `::error::` on stderr is just text.
  SDK_ROOT="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
  if [[ -z "${SDK_ROOT}" ]]; then
    echo "::error::${SCRIPT_NAME}: neither ANDROID_HOME nor ANDROID_SDK_ROOT is set, so there is no SDK to provision — this step is broken, not the lane."
    return "${RC_BROKEN}"
  fi
  SDKMANAGER="${SDK_ROOT}/cmdline-tools/latest/bin/sdkmanager"
  if [[ ! -x "${SDKMANAGER}" ]]; then
    # Where the runner image documents it, then PATH — which is how the action
    # itself resolves the bare `sdkmanager` name. If the action can run it, so
    # can this step, whatever the image does with `cmdline-tools/latest`.
    SDKMANAGER="$(command -v sdkmanager || true)"
  fi
  if [[ -z "${SDKMANAGER}" || ! -x "${SDKMANAGER}" ]]; then
    echo "::error::${SCRIPT_NAME}: no executable sdkmanager under the SDK root's cmdline-tools/latest/bin, and none on PATH — this step is broken, not the lane."
    return "${RC_BROKEN}"
  fi

  # The order the action installs them in, so a shared failure is the same
  # failure. The system image is last because it is the large one.
  local packages=(
    platform-tools
    "platforms;android-${api}"
    emulator
    "system-images;android-${api};${target};${arch}"
  )

  local pkg
  for pkg in "${packages[@]}"; do
    if ! install_package "${pkg}"; then
      echo "::error::Android SDK provisioning failed for package ${pkg} after ${PACKAGE_ATTEMPTS} attempt(s) or a spent ${BUDGET_SECS}s budget. This is INFRASTRUCTURE, not a product failure: sdkmanager could not install a package the emulator needs, and no test ran in this job."
      return "${RC_PROVISION_FAILED}"
    fi
  done

  printf '%s: OK — %d package(s) installed and verified for api %s, %s, %s.\n' \
    "${SCRIPT_NAME}" "${#packages[@]}" "${api}" "${target}" "${arch}"
  return 0
}

# ---------------------------------------------------------------------------
# Self-test: hermetic. A fake sdkmanager in a temporary SDK root, no network,
# and both clock functions replaced, so nothing here sleeps or waits.
# ---------------------------------------------------------------------------

readonly SELF_TEST_FIXTURES=12

# write_fake_sdkmanager <root> <mode>
#
# Writes the fake into the same cmdline-tools/latest/bin the real one is read
# from, and has it append one line per invocation to <root>/invocations so a
# fixture can count what ran. Every mode EXITS 0, because that is the harder
# case to catch: the run is graded by what landed on disk, so an sdkmanager
# that reports success over nothing must still fail closed.
#
#   ok       installs the package properly (the emulator's binary prints a
#            version and exits 0)
#   flaky    installs nothing for the first two invocations, properly after
#   nothing  installs nothing, ever — the "Failed to download package!" shape
#   corrupt  installs the emulator with a binary that exits non-zero
write_fake_sdkmanager() {
  local root="$1" mode="$2" bin="$1/cmdline-tools/latest/bin"
  mkdir -p "${bin}"
  cat > "${bin}/sdkmanager" <<EOF
#!/usr/bin/env bash
set -euo pipefail
root="${root}"
mode="${mode}"
pkg=""
for a in "\$@"; do
  case "\${a}" in --*) ;; *) pkg="\${a}" ;; esac
done
echo "\${pkg}" >> "\${root}/invocations"
n="\$(wc -l < "\${root}/invocations")"
if [[ "\${mode}" == "nothing" ]]; then
  echo "Warning: Failed to download package!"
  exit 0
fi
if [[ "\${mode}" == "flaky" && "\${n}" -lt 3 ]]; then
  echo "Warning: Failed to download package!"
  exit 0
fi
dir="\${root}/\${pkg//;//}"
mkdir -p "\${dir}"
printf 'Pkg.Revision=1\n' > "\${dir}/source.properties"
if [[ "\${pkg}" == "emulator" ]]; then
  if [[ "\${mode}" == "corrupt" ]]; then
    printf '#!/usr/bin/env bash\nexit 1\n' > "\${dir}/emulator"
  else
    printf '#!/usr/bin/env bash\necho "Android emulator version 0.0.0"\n' > "\${dir}/emulator"
  fi
  chmod +x "\${dir}/emulator"
fi
exit 0
EOF
  chmod +x "${bin}/sdkmanager"
  : > "${root}/invocations"
}

# invocation_count <root> — how many times the fake sdkmanager ran.
invocation_count() {
  local n
  n="$(wc -l < "$1/invocations")"
  printf '%s\n' "$(( n ))"
}

run_self_test() {
  local tmp fail=0 ran=0 root rc out n
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  # Replaced for the whole self-test: the real backoff would put 40 s of sleep
  # into a guard that is supposed to be instant, and a test that waits is a test
  # that will one day be flaky.
  provision_sleep() { :; }

  # (a) The ordinary run: one attempt per package, all four verified.
  ran=$(( ran + 1 ))
  root="${tmp}/a"; write_fake_sdkmanager "${root}" ok
  rc=0
  out="$(ANDROID_HOME="${root}" ANDROID_SDK_ROOT="" provision_android_sdk 34 google_apis x86_64)" || rc=$?
  n="$(invocation_count "${root}")"
  if (( rc != 0 )) || (( n != 4 )) || [[ "${out}" != *"4 package(s) installed and verified"* ]]; then
    echo "SELF-TEST FAIL (a): a clean provisioning must exit 0 after exactly 4 installs; got rc=${rc}, ${n} invocation(s)" >&2
    fail=1
  fi
  if [[ ! -x "${root}/emulator/emulator" || ! -d "${root}/system-images/android-34/google_apis/x86_64" ]]; then
    echo "SELF-TEST FAIL (a): the emulator and the system image named by the arguments are not on disk" >&2
    fail=1
  fi

  # (b) Two failures then a success: the retry is what installs the package.
  ran=$(( ran + 1 ))
  root="${tmp}/b"; write_fake_sdkmanager "${root}" flaky
  rc=0
  out="$(ANDROID_HOME="${root}" ANDROID_SDK_ROOT="" provision_android_sdk 34 google_apis x86_64)" || rc=$?
  n="$(invocation_count "${root}")"
  # 3 for platform-tools (2 failures + 1 success), then 1 each for the rest.
  if (( rc != 0 )) || (( n != 6 )) || [[ "${out}" != *"verified on attempt 3/3"* ]]; then
    echo "SELF-TEST FAIL (b): two transient failures must be ridden out on the third attempt; got rc=${rc}, ${n} invocation(s)" >&2
    fail=1
  fi

  # (c) The observed failure: sdkmanager exits 0 and installs nothing, every
  #     time. Trusting that exit code is exactly what let a lane boot an
  #     emulator that was not there.
  ran=$(( ran + 1 ))
  root="${tmp}/c"; write_fake_sdkmanager "${root}" nothing
  rc=0
  out="$(ANDROID_HOME="${root}" ANDROID_SDK_ROOT="" provision_android_sdk 34 google_apis x86_64 2>&1)" || rc=$?
  if (( rc != RC_PROVISION_FAILED )) \
     || [[ "${out}" != *"::error::"* ]] \
     || [[ "${out}" != *"platform-tools"* ]] \
     || [[ "${out}" != *"INFRASTRUCTURE"* ]] \
     || [[ "${out}" != *"no test ran"* ]]; then
    echo "SELF-TEST FAIL (c): an sdkmanager that exits 0 and installs nothing must fail CLOSED with one ::error:: naming the package and saying no test ran; got rc=${rc}" >&2
    fail=1
  fi

  # (d) The corrupt-zip variant: the package directory is complete and the
  #     binary does not run. The probe is what sees it, and the partial
  #     directory must not survive into the retry.
  ran=$(( ran + 1 ))
  root="${tmp}/d"; write_fake_sdkmanager "${root}" corrupt
  rc=0
  out="$(ANDROID_HOME="${root}" ANDROID_SDK_ROOT="" provision_android_sdk 34 google_apis x86_64 2>&1)" || rc=$?
  if (( rc != RC_PROVISION_FAILED )) || [[ "${out}" != *"::error::"* ]] || [[ "${out}" != *"emulator"* ]]; then
    echo "SELF-TEST FAIL (d): an emulator whose binary does not run must fail closed; got rc=${rc}" >&2
    fail=1
  fi
  if [[ -e "${root}/emulator" ]]; then
    echo "SELF-TEST FAIL (d): the unusable emulator package survived — the next attempt, and the action, would read it as installed" >&2
    fail=1
  fi

  # (e) No sdkmanager anywhere. A broken step, and it must not be reported as
  #     the infrastructure failure of (c).
  #
  #     PATH is emptied and bash invoked by its own absolute path, because the
  #     runner this self-test runs on in CI DOES have an sdkmanager on PATH —
  #     the fixture would otherwise pass here and quietly install packages
  #     there. Nothing this reaches is external: every command before the
  #     resolution is a bash builtin.
  ran=$(( ran + 1 ))
  root="${tmp}/e"; mkdir -p "${root}"; : > "${root}/invocations"
  rc=0
  out="$(ANDROID_HOME="${root}" ANDROID_SDK_ROOT="" PATH="" "${BASH}" "${BASH_SOURCE[0]}" 34 google_apis x86_64 2>&1)" || rc=$?
  if (( rc != RC_BROKEN )) || (( rc == RC_PROVISION_FAILED )) || [[ "${out}" != *"broken"* ]]; then
    echo "SELF-TEST FAIL (e): an sdkmanager absent from both the SDK root and PATH must exit ${RC_BROKEN}, distinct from the provisioning failure ${RC_PROVISION_FAILED}; got rc=${rc}" >&2
    fail=1
  fi

  # (k) sdkmanager only on PATH: the documented location is empty and the
  #     action's own resolution is what finds it. Exercised in a subshell so
  #     the replaced PATH cannot leak into the fixtures behind it.
  ran=$(( ran + 1 ))
  root="${tmp}/k"; write_fake_sdkmanager "${root}" ok
  mkdir -p "${tmp}/kbin"
  mv "${root}/cmdline-tools/latest/bin/sdkmanager" "${tmp}/kbin/sdkmanager"
  rc=0
  out="$(export ANDROID_HOME="${root}" ANDROID_SDK_ROOT="" PATH="${tmp}/kbin:${PATH}"; provision_android_sdk 34 google_apis x86_64)" || rc=$?
  n="$(invocation_count "${root}")"
  if (( rc != 0 )) || (( n != 4 )); then
    echo "SELF-TEST FAIL (k): an sdkmanager reachable only through PATH must still provision; got rc=${rc}, ${n} invocation(s)" >&2
    fail=1
  fi

  # (f) Usage. A step wired with the wrong arguments must run nothing at all,
  #     rather than provision something other than what the action will boot.
  ran=$(( ran + 1 ))
  root="${tmp}/f"; write_fake_sdkmanager "${root}" ok
  local args
  for args in "" "34" "34 google_apis" "34 google_apis x86_64 extra" "--frobnicate"; do
    rc=0
    # shellcheck disable=SC2086
    out="$(ANDROID_HOME="${root}" ANDROID_SDK_ROOT="" bash "${BASH_SOURCE[0]}" ${args} 2>&1)" || rc=$?
    n="$(invocation_count "${root}")"
    if (( rc != RC_BROKEN )) || [[ "${out}" != *"usage"* ]] || (( n != 0 )); then
      echo "SELF-TEST FAIL (f): '${args}' must print usage, exit ${RC_BROKEN} and run nothing; got rc=${rc}, ${n} invocation(s)" >&2
      fail=1
    fi
  done

  # (g) The attempt bound is exactly what it says, and a package that exhausts
  #     it stops the run: three invocations for the first package and none for
  #     the three behind it.
  ran=$(( ran + 1 ))
  root="${tmp}/g"; write_fake_sdkmanager "${root}" nothing
  rc=0
  ANDROID_HOME="${root}" ANDROID_SDK_ROOT="" provision_android_sdk 34 google_apis x86_64 >/dev/null 2>&1 || rc=$?
  n="$(invocation_count "${root}")"
  if (( n != PACKAGE_ATTEMPTS )); then
    echo "SELF-TEST FAIL (g): expected exactly ${PACKAGE_ATTEMPTS} attempt(s) before failing closed, got ${n}" >&2
    fail=1
  fi

  # (h) The budget stops a run that is still inside its attempt count, without
  #     starting another attempt — the bound the step's timeout-minutes is
  #     derived from. Overridden inside a subshell so the real clock is back
  #     for anything after this.
  ran=$(( ran + 1 ))
  root="${tmp}/h"; write_fake_sdkmanager "${root}" ok
  rc=0
  (
    provision_elapsed_secs() { printf '%s\n' "$(( BUDGET_SECS + 1 ))"; }
    ANDROID_HOME="${root}" ANDROID_SDK_ROOT="" provision_android_sdk 34 google_apis x86_64
  ) >/dev/null 2>&1 || rc=$?
  n="$(invocation_count "${root}")"
  if (( rc != RC_PROVISION_FAILED )) || (( n != 0 )); then
    echo "SELF-TEST FAIL (h): a spent budget must fail closed without starting an attempt; got rc=${rc}, ${n} invocation(s)" >&2
    fail=1
  fi

  # (h2) ...and a budget crossed DURING an attempt is followed by no backoff:
  #      the pause would be slept and then the attempt refused, which is how
  #      the reachable worst case once ran 30 s past the one the header states.
  ran=$(( ran + 1 ))
  root="${tmp}/h2"; write_fake_sdkmanager "${root}" nothing
  : > "${tmp}/h2.sleeps"; printf '0\n' > "${tmp}/h2.clock"
  rc=0
  (
    # First read (the top-of-loop check) is inside the budget; every later one
    # is past it, i.e. the attempt itself spent the budget.
    provision_elapsed_secs() {
      local reads; reads="$(cat "${tmp}/h2.clock")"
      printf '%s\n' "$(( reads + 1 ))" > "${tmp}/h2.clock"
      if (( reads == 0 )); then printf '0\n'; else printf '%s\n' "$(( BUDGET_SECS + 1 ))"; fi
    }
    provision_sleep() { printf 'slept\n' >> "${tmp}/h2.sleeps"; }
    ANDROID_HOME="${root}" ANDROID_SDK_ROOT="" provision_android_sdk 34 google_apis x86_64
  ) >/dev/null 2>&1 || rc=$?
  n="$(invocation_count "${root}")"
  slept="$(wc -l < "${tmp}/h2.sleeps")"
  if (( rc != RC_PROVISION_FAILED )) || (( n != 1 )) || (( slept != 0 )); then
    echo "SELF-TEST FAIL (h2): an attempt that spends the budget must be the last thing that runs; got rc=${rc}, ${n} invocation(s), ${slept} backoff(s)" >&2
    fail=1
  fi

  # (i) Static pins that no fixture can reach.
  #
  #   * A `return` with no operand: reached from a trap handler on bash < 5.3
  #     (ubuntu-latest is 5.2) it reports the status from BEFORE the handler.
  #   * A pipeline whose reader is a quiet grep: under `pipefail` the reader
  #     exits on its first match, the writer dies of SIGPIPE, and the pipeline
  #     reads as a miss — a check that fails open.
  #   * The backoff list must have one entry per pause, i.e. one fewer than the
  #     attempts, so raising the attempt count cannot silently reuse nothing.
  ran=$(( ran + 1 ))
  local source_no_comments
  source_no_comments="$(grep -v '^[[:space:]]*#' "${BASH_SOURCE[0]}")"
  if grep -qE '^[[:space:]]*return[[:space:]]*$' <<<"${source_no_comments}"; then
    echo "SELF-TEST FAIL (i): a \`return\` with no operand is in this file; under a trap handler on bash < 5.3 it reports a status this script never arrived at" >&2
    fail=1
  fi
  if grep -qE '\|[[:space:]]*grep[[:space:]]+-[A-Za-z]*q' <<<"${source_no_comments}"; then
    echo "SELF-TEST FAIL (i): a pipeline in this file ends in a quiet grep; the writer's SIGPIPE makes it read as a miss under pipefail" >&2
    fail=1
  fi
  if (( ${#BACKOFF_SECS[@]} != PACKAGE_ATTEMPTS - 1 )); then
    echo "SELF-TEST FAIL (i): ${#BACKOFF_SECS[@]} backoff(s) for ${PACKAGE_ATTEMPTS} attempt(s); there must be exactly one per pause" >&2
    fail=1
  fi

  # (j) The worst case stated in the header is the one the constants add up to.
  #     That number is what every lane's step cap is derived from, so a constant
  #     raised without the header is a step cap that no longer covers the script.
  ran=$(( ran + 1 ))
  local worst
  worst=$(( BUDGET_SECS + ATTEMPT_TIMEOUT_SECS + EMULATOR_PROBE_SECS ))
  if ! grep -qF "${BUDGET_SECS} + ${ATTEMPT_TIMEOUT_SECS} + ${EMULATOR_PROBE_SECS} = ${worst} s" "${BASH_SOURCE[0]}"; then
    echo "SELF-TEST FAIL (j): the header no longer states the worst case these constants produce (${BUDGET_SECS} + ${ATTEMPT_TIMEOUT_SECS} + ${EMULATOR_PROBE_SECS} = ${worst} s); every lane's step cap is derived from that line" >&2
    fail=1
  fi

  if (( fail )); then
    echo "${SCRIPT_NAME}: SELF-TEST FAILED" >&2
    return 1
  fi
  if (( ran != SELF_TEST_FIXTURES )); then
    echo "${SCRIPT_NAME}: SELF-TEST FAILED — ran ${ran} fixture(s), expected exactly ${SELF_TEST_FIXTURES}; a fixture was added or removed without moving the pin" >&2
    return 1
  fi
  echo "${SCRIPT_NAME}: self-test passed (${ran}/${SELF_TEST_FIXTURES} fixtures: a clean run installs and verifies exactly the four packages the arguments name; two transient failures are ridden out on the third attempt; an sdkmanager that exits 0 having installed nothing fails closed with one ::error:: naming the package, calling it infrastructure and saying no test ran; an emulator whose binary does not run is caught by the probe and its directory removed before the retry; an sdkmanager absent from both the SDK root and PATH exits ${RC_BROKEN}, distinct from that, while one reachable only through PATH still provisions; every wrong argument list prints usage, exits ${RC_BROKEN} and runs nothing; a package that exhausts the attempts stops the run at exactly ${PACKAGE_ATTEMPTS} invocations; a spent budget fails closed without starting another attempt, and an attempt that spends it is followed by no backoff; no operand-less \`return\`, no pipeline ending in a quiet grep, one backoff per pause; and the header's worst case is the one the constants add up to)."
  return 0
}

if [[ "${1:-}" == "--self-test" && $# -eq 1 ]]; then
  run_self_test
  exit $?
fi

if (( $# != 3 )); then
  usage
  exit "${RC_BROKEN}"
fi
case "$1" in
  '' | *[!0-9]*) usage; exit "${RC_BROKEN}" ;;
esac
case "$2" in
  '' | *[!A-Za-z0-9_-]*) usage; exit "${RC_BROKEN}" ;;
esac
case "$3" in
  '' | *[!A-Za-z0-9_-]*) usage; exit "${RC_BROKEN}" ;;
esac

rc=0
provision_android_sdk "$1" "$2" "$3" || rc=$?
exit "${rc}"
