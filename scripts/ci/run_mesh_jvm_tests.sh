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
# A Gradle `test` task that finds no test, or skips one, or is filtered down to
# a few, succeeds. So the verdict here is read from the result files of this
# run: no failure, no error, none skipped, and the tests that ran are the tests
# the sources declare — the `name` of every `<testcase>` against every
# function declared `fun <name>()` on the line after a line that is `@Test`
# alone, in the `.kt` files under the project's `src/test`. One list, the
# sources' own; `check_mesh_radio.sh` (check 11) pins its names.
#
# What this cannot see: a test that ran and asserts nothing. A body emptied of
# its assertions runs, passes and is counted.
#
# Usage:
#   bash scripts/ci/run_mesh_jvm_tests.sh
#
# Exit codes:
#   0  every test ran and passed
#   1  the build or a test failed, a test was skipped, or the tests that ran
#      are not the ones declared
#   2  the project or Gradle is missing, or a result file cannot be read
#      (misconfiguration)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly PROJECT="${REPO_ROOT}/haven/android/mesh-jvm"
readonly RESULTS="${PROJECT}/build/test-results/test"
readonly SOURCES="${PROJECT}/src/test"
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

declared="$(find "${SOURCES}" -type f -name '*.kt' -exec awk '
  marked && match($0, /^[[:space:]]*fun [A-Za-z0-9_]+\(\)/) { name = substr($0, RSTART, RLENGTH); sub(/^[[:space:]]*fun /, "", name); sub(/\(\)$/, "", name); print name }
  { marked = ($0 ~ /^[[:space:]]*@Test[[:space:]]*$/) }' {} + | LC_ALL=C sort)"
ran="$(cat "${RESULTS}"/TEST-*.xml | grep -oE '<testcase name="[^"]+"' | sed -E 's/^<testcase name="//; s/"$//' | LC_ALL=C sort)"
if [[ -z "${declared}" || "${ran}" != "${declared}" ]]; then
  echo "FAIL: the tests that ran are not the tests the sources declare ('<' declared, '>' ran):" >&2
  diff <(printf '%s\n' "${declared}") <(printf '%s\n' "${ran}") | grep -E '^[<>]' >&2 || true
  exit 1
fi
echo "mesh-jvm: the $(grep -c . <<<"${declared}") tests the sources declare are the ones that ran"
