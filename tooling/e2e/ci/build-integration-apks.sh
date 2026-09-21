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
#   HAVEN_LIVE_SYNC  'true' or 'false'. MANDATORY — there is deliberately no
#                    default; see below.
#
# Output:
#   /tmp/integration-apks/<basename>.apk for each target.

set -euo pipefail

# Resolved from this script's own location, not from the caller's cwd: the
# workflow runs it from haven/ as `bash ../tooling/e2e/ci/...`, a local run may
# not.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
readonly REPO_ROOT

readonly RELAY_URL="${HAVEN_E2E_RELAY:-ws://10.0.2.2:7777}"

# Mandatory live-sync define — no default, on purpose.
#
# `liveSyncEnabled` is `bool.fromEnvironment('HAVEN_LIVE_SYNC', defaultValue:
# true)`, so omitting the define does not produce an "unset" build: it produces
# a LIVE build that no lane asked for and no lane name describes
# (CI_HARDENING_BACKLOG.md A7). Every caller of this script therefore has to
# state which receive path its APKs compile.
#
# A default here would defeat the point. This script is the single funnel for
# three lanes (e2e-integration, e2e-background-catchup, e2e-fgs-publish), so any
# default it carried would become those lanes' de-facto answer without any of
# them saying anything — the exact shape of the defect, moved one file down.
# Failing closed costs a caller one env line and makes the mode greppable from
# the workflow.
#
# The value is VALIDATED because the expansion at the build site is deliberately
# unquoted (it must expand to exactly one word); an unvalidated value containing
# whitespace would word-split into extra `flutter build apk` arguments.
if [[ -z "${HAVEN_LIVE_SYNC:-}" ]]; then
  echo "ERROR: HAVEN_LIVE_SYNC is not set." >&2
  echo "       This script bakes the receive path into every APK it builds, and" >&2
  echo "       'unset' compiles the live-sync engine ON via the Dart default —" >&2
  echo "       silently, whatever the lane is called. Set it to 'true' or" >&2
  echo "       'false' in the calling job's env (CI_HARDENING_BACKLOG.md A7)." >&2
  exit 2
fi
if [[ ! "${HAVEN_LIVE_SYNC}" =~ ^(true|false)$ ]]; then
  echo "ERROR: HAVEN_LIVE_SYNC must be exactly 'true' or 'false' (got '${HAVEN_LIVE_SYNC}')." >&2
  exit 2
fi
readonly LIVE_SYNC_DEFINE="--dart-define=HAVEN_LIVE_SYNC=${HAVEN_LIVE_SYNC}"

readonly OUT_DIR="/tmp/integration-apks"
readonly BUILD_APK="build/app/outputs/flutter-apk/app-debug.apk"

# The ONE classified, budgeted retry every Gradle-backed lane builds through.
#
# This script used to carry its own loop, which retried EVERY non-zero exit. That
# is wrong in the two directions that matter: it retried compile errors (three
# copies of the same error, and the step's time spent before showing it), and it
# retried disk/memory exhaustion — intermittent but REAL — which turns a capacity
# problem into a green build that hides it. The wrapper classifies on Gradle's
# own dependency-resolution wording instead, and carries the per-job wall-clock
# budget that keeps a seven-APK step's worst case bounded (a per-target budget
# would be spent seven times over). Its header has the failure it was measured
# against and the worst-case arithmetic.
readonly BUILD_WRAPPER="${REPO_ROOT}/scripts/ci/build_apk_with_retry.sh"

build_target_apk() {
  local target="$1"
  # `--target-platform android-x64` (inside the wrapper): the E2E AVDs are all
  # x86_64, so x64 is the only ABI these APKs ever run on. Without it cargokit
  # compiles the large debug haven-core Rust lib for four ABIs (arm/arm64 + the
  # debug-forced x86/x64), which — with the NDK strip pass — has exhausted the
  # runner disk.
  # shellcheck disable=SC2086  # LIVE_SYNC_DEFINE is one validated word.
  "${BUILD_WRAPPER}" android-x64 \
    --target="${target}" \
    ${LIVE_SYNC_DEFINE} \
    --dart-define=HAVEN_E2E_RELAY="${RELAY_URL}"
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
  # Forced Rule-14 contention. Once the reclaim and handover keep both
  # isolates unstuck, nothing else drives a contended acquire, so the
  # fail-closed property they all rest on could rot unnoticed.
  "integration_test/session_guard_contention_test.dart"
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
  # Build through the classified retry so a transient Maven Central rate limit
  # during Gradle dependency resolution does not fail the whole lane, while a
  # compile error or a full disk still fails it immediately (the x86_64-only
  # rationale is documented on the flag inside the helper).
  build_target_apk "${target}"
  cp "${BUILD_APK}" "${dest}"
  ls -lh "${dest}"
done

echo
echo "Built ${#TARGETS[@]} integration APK(s) under ${OUT_DIR}:"
ls -lh "${OUT_DIR}"
