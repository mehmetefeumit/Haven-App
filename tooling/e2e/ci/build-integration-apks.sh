#!/usr/bin/env bash
#
# Builds the debug APKs for the non-E2E integration-test lane (backlog
# CI-4), ONE per target, BEFORE the emulator boots — so the multi-GB
# Rust-NDK + Gradle build peak never coincides with a resident emulator
# (the historical lost-runner cause; see docs/E2E_TROUBLESHOOTING.md).
#
# Each target becomes its own debug APK (the test code is baked in via
# --target), staged at /tmp/integration-apks/<basename>.apk where
# <basename> is the target file name without the .dart extension
# (e.g. integration_test/app_test.dart -> /tmp/integration-apks/app_test.apk).
# run-integration-tests.sh copies each staged APK into /tmp/scenario.apk
# before driving it, so no Gradle runs while the emulator is up.
#
# The Rust .so is compiled once and reused (the Gradle/cargo cache makes
# subsequent target builds mostly Dart + Gradle packaging), so building
# five APKs is cheaper than five cold builds.
#
# # Why a checked-in script
#
# Same rationale as the sibling tooling/e2e/ci scripts: a multi-target
# build loop with a baked-in relay --dart-define is fragile as inline
# YAML, and keeping the staging paths here keeps them in sync with
# run-integration-tests.sh and e2e-integration.yml.
#
# Usage (run from the haven/ Flutter project dir, as the workflow does):
#   bash ../tooling/e2e/ci/build-integration-apks.sh [<target.dart> ...]
#
# With no target arguments it builds the canonical five orphan targets.
#
# Required env (set by the workflow before invoking this script):
#   HAVEN_E2E_RELAY  WebSocket URL compiled into each APK via
#                    --dart-define. MUST match the URL the drive step
#                    uses (the value is baked in; drive does not
#                    re-pass it). Defaults to ws://10.0.2.2:7777.
#
# Output:
#   /tmp/integration-apks/<basename>.apk for each target.

set -euo pipefail

readonly RELAY_URL="${HAVEN_E2E_RELAY:-ws://10.0.2.2:7777}"
readonly OUT_DIR="/tmp/integration-apks"
readonly BUILD_APK="build/app/outputs/flutter-apk/app-debug.apk"

# Bounded retry for `flutter build apk`. Gradle dependency resolution
# intermittently fails on CI when Maven Central / plugins.gradle.org rate-limit
# or hiccup on shared runner IPs — the tell is an HTTP 403/429/5xx (e.g.
# "Could not GET '.../kotlin-stdlib-*.pom'. Received status code 403") during
# ':classpath' resolution. That is a network flake, NOT a build error: a re-run
# resolves it, and Gradle caches the artifacts it DID fetch in ~/.gradle within
# the job, so a retry only re-fetches what the transient failure missed (fast). A
# genuine compile error still fails every attempt and surfaces normally. Tunable
# via env for local runs.
readonly BUILD_MAX_ATTEMPTS="${HAVEN_BUILD_MAX_ATTEMPTS:-3}"
readonly BUILD_RETRY_DELAY_SECS="${HAVEN_BUILD_RETRY_DELAY_SECS:-20}"

build_apk_with_retry() {
  local target="$1" attempt=1 rc=0
  while (( attempt <= BUILD_MAX_ATTEMPTS )); do
    rc=0
    # `--target-platform android-x64`: the E2E AVDs are all x86_64, so x64 is the
    # only ABI these APKs ever run on. Without it cargokit compiles the large
    # debug haven-core Rust lib for four ABIs (arm/arm64 + the debug-forced
    # x86/x64), which — with the NDK strip pass — has exhausted the runner disk.
    flutter build apk \
      --debug \
      --target-platform android-x64 \
      --target="${target}" \
      --dart-define=HAVEN_E2E_RELAY="${RELAY_URL}" || rc=$?
    if (( rc == 0 )); then
      return 0
    fi
    if (( attempt < BUILD_MAX_ATTEMPTS )); then
      echo "WARN: 'flutter build apk' for ${target} failed (rc=${rc}," \
           "attempt ${attempt}/${BUILD_MAX_ATTEMPTS}) — retrying in" \
           "${BUILD_RETRY_DELAY_SECS}s. Transient Gradle repo/network failures" \
           "(e.g. a Maven Central 403) are common on shared CI IPs and clear on" \
           "re-run; Gradle reuses what it already cached this job." >&2
      sleep "${BUILD_RETRY_DELAY_SECS}"
    fi
    attempt=$(( attempt + 1 ))
  done
  echo "ERROR: 'flutter build apk' for ${target} failed after" \
       "${BUILD_MAX_ATTEMPTS} attempts (rc=${rc}) — see the last failure above." >&2
  return "${rc}"
}

# The smoke-test pre-flight plus the five orphan integration targets
# (backlog CI-4). Kept in sync with the target list e2e-integration.yml
# passes to run-integration-tests.sh.
#
# smoke_test runs FIRST as a fast pre-flight: it exercises the Rust
# bridge, the in-memory keyring, deterministic identity derivation, and
# relay connectivity in ~30s, so a broken bootstrap fails fast (with a
# small log) before the five heavier targets run.
declare -a DEFAULT_TARGETS=(
  "integration_test/e2e/smoke_test.dart"
  "integration_test/app_test.dart"
  "integration_test/keyring_test.dart"
  "integration_test/encryption_pipeline_test.dart"
  "integration_test/circle_service_remove_member_test.dart"
  "integration_test/circle_admin_leave_ghost_test.dart"
)

declare -a TARGETS
if [[ $# -gt 0 ]]; then
  TARGETS=("$@")
else
  TARGETS=("${DEFAULT_TARGETS[@]}")
fi

if [[ ! -f "pubspec.yaml" ]]; then
  echo "ERROR: must run from the haven/ Flutter project dir (no pubspec.yaml here)." >&2
  exit 1
fi

mkdir -p "${OUT_DIR}"

for target in "${TARGETS[@]}"; do
  if [[ ! -f "${target}" ]]; then
    echo "ERROR: integration target not found: ${target}" >&2
    exit 1
  fi

  base="$(basename "${target}" .dart)"
  dest="${OUT_DIR}/${base}.apk"

  echo "============================================================"
  echo "Building ${target} -> ${dest}"
  echo "============================================================"
  # Build with a bounded retry so a transient Maven Central / plugins.gradle.org
  # 403 during Gradle dependency resolution does not fail the whole lane (the
  # x86_64-only rationale is documented on the flag inside the helper).
  build_apk_with_retry "${target}"
  cp "${BUILD_APK}" "${dest}"
  ls -lh "${dest}"
done

echo
echo "Built ${#TARGETS[@]} integration APK(s) under ${OUT_DIR}:"
ls -lh "${OUT_DIR}"
