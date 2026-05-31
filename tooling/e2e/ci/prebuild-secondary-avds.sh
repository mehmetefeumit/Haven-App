#!/usr/bin/env bash
#
# Creates the secondary Android Virtual Devices (`bob_avd`, `carol_avd`)
# used by the consolidated 3-AVD Haven E2E scenario
# (`integration_test/e2e/e2e_combined.dart`).
#
# The action seeds the primary AVD (`test`) via its own machinery —
# this script adds the two siblings. They are created cold (no
# snapshot) here; the per-scenario run script boots them and lets
# them warm up.
#
# Lives in a checked-in file rather than inline in YAML because the
# `reactivecircus/android-emulator-runner@v2` action executes
# `script:` blocks one line per `sh -c` invocation, so shell variable
# assignments, `cd`, and piped commands ("echo no | avdmanager") do
# not persist across lines. Wrapping the whole script in `bash
# <path>` bypasses that.
#
# Usage:
#   bash tooling/e2e/ci/prebuild-secondary-avds.sh
#
# Required env (set by the action):
#   ANDROID_HOME      Android SDK root.
#   ANDROID_AVD_HOME  Override for the AVD storage directory; default
#                     is $HOME/.android/avd.

set -euo pipefail

readonly AVD_NAMES=("bob_avd" "carol_avd")
readonly SYSTEM_IMAGE="system-images;android-34;google_apis;x86_64"
readonly DEVICE_PROFILE="pixel_6"

avd_home="${ANDROID_AVD_HOME:-${HOME}/.android/avd}"
avdmanager="${ANDROID_HOME}/cmdline-tools/latest/bin/avdmanager"

if [[ ! -x "${avdmanager}" ]]; then
  echo "ERROR: avdmanager not found at ${avdmanager}" >&2
  exit 1
fi

mkdir -p "${avd_home}"

for avd_name in "${AVD_NAMES[@]}"; do
  # `echo no` declines the optional "create a custom hardware profile?"
  # prompt without aborting the AVD creation. `--force` overwrites any
  # stale AVD left over by a previous run on the same cache.
  echo no | "${avdmanager}" create avd \
    --force \
    --name "${avd_name}" \
    --package "${SYSTEM_IMAGE}" \
    --device "${DEVICE_PROFILE}"
  echo "Created AVD '${avd_name}' under ${avd_home}."
done

echo "Primary AVD ('test') is the emulator-runner action's default."
echo "Secondary AVDs (${AVD_NAMES[*]}) are ready for the 3-AVD harness."
