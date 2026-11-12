#!/usr/bin/env bash
# Runs the JVM tests of the mesh radio's pure Kotlin, and fails unless every
# one of them ran (docs/BLUETOOTH_MESH_M3_DESIGN.md §B.10).
#
# `haven/android/mesh-jvm` is a Gradle build of its own: the package
# `com.oblivioustech.haven.mesh.core` of the app, compiled for the JVM with no
# Android SDK, and its tests. It needs a JDK and a `gradle` on the PATH (or
# named in GRADLE); android-unit.yml fetches the distribution the app's wrapper
# pins.
#
# A Gradle `test` task that finds no test, or skips one, succeeds. So the
# verdict here is read from the result files of this run: at least one test, no
# failure, no error, none skipped.
#
# Usage:
#   bash scripts/ci/run_mesh_jvm_tests.sh
#
# Exit codes:
#   0  every test ran and passed
#   1  the build or a test failed, a test was skipped, or none ran
#   2  the project or Gradle is missing, or a result file cannot be read
#      (misconfiguration)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly PROJECT="${REPO_ROOT}/haven/android/mesh-jvm"
readonly RESULTS="${PROJECT}/build/test-results/test"
readonly GRADLE="${GRADLE:-gradle}"

[[ -f "${PROJECT}/build.gradle.kts" ]] || { echo "ERROR: ${PROJECT} is not a Gradle project" >&2; exit 2; }
command -v "${GRADLE}" >/dev/null || { echo "ERROR: no '${GRADLE}' to run" >&2; exit 2; }

# The results of an earlier run are not this run's.
rm -rf "${RESULTS}"
"${GRADLE}" --no-daemon -p "${PROJECT}" test || exit 1

count() { # <attribute of a <testsuite>>
  local total=0 n file
  for file in "${RESULTS}"/TEST-*.xml; do
    [[ -f "${file}" ]] || continue
    n="$(sed -nE "s/.*<testsuite [^>]*[[:space:]]$1=\"([0-9]+)\".*/\1/p" "${file}" | head -n 1)"
    [[ -n "${n}" ]] || { echo "ERROR: ${file} names no '$1'" >&2; return 2; }
    total=$(( total + n ))
  done
  echo "${total}"
}

tests="$(count tests)"
skipped="$(count skipped)"
failures="$(count failures)"
errors="$(count errors)"
echo "mesh-jvm: ${tests} test(s) ran, $(( failures + errors )) failed, ${skipped} skipped"
if (( tests == 0 || failures != 0 || errors != 0 || skipped != 0 )); then
  echo "FAIL: the mesh radio's JVM tests did not all run and pass." >&2
  exit 1
fi
