#!/usr/bin/env bash
#
# Builds the debug APK for the KPR KeyPackage-rotation lane, BEFORE the
# emulator boots — the build-before-boot discipline every Android E2E lane
# follows, so the multi-GB Rust-NDK + Gradle peak never coincides with a
# resident emulator (see docs/E2E_TROUBLESHOOTING.md).
#
# # Why a DEDICATED build script rather than build-integration-apks.sh
#
# This is the only lane whose drive target needs a SECOND relay URL baked in.
# R2 is what makes the final phase possible: a responder that does not serve
# the account's KeyPackage slot is, to `decide_kp_maintenance`,
# indistinguishable from a relay that dropped the event, so the tick takes the
# heal branch and republishes the CACHED bytes under a fresh `created_at`. The
# drive reads both copies back and compares them, which it cannot do without
# knowing where R2 is.
#
# `flutter drive` does NOT forward `--dart-define`s, so the value is
# un-re-passable at drive time and has to be compiled in here. The shared
# builder deliberately carries no per-lane knobs, and teaching it one would
# make every other lane pay for this one.
#
# Usage (run from the haven/ Flutter project dir, as the workflow does):
#   bash ../tooling/e2e/ci/build-kp-rotation-apk.sh [<target.dart>]
#
# Required env (set by the calling job):
#   HAVEN_LIVE_SYNC    'true' | 'false'. MANDATORY, no default — see below.
#
# Optional env:
#   HAVEN_E2E_RELAY    R1 ws:// URL. Default ws://10.0.2.2:7777.
#   HAVEN_E2E_RELAY_2  R2 ws:// URL. Default ws://10.0.2.2:7778.
#
# Output:
#   /tmp/integration-apks/kp_rotation_wire_test.apk

set -euo pipefail

readonly OUT_DIR="/tmp/integration-apks"
readonly BUILD_APK="build/app/outputs/flutter-apk/app-debug.apk"
readonly TARGET="${1:-integration_test/kp_rotation_wire_test.dart}"
readonly RELAY_URL="${HAVEN_E2E_RELAY:-ws://10.0.2.2:7777}"
readonly RELAY_URL_2="${HAVEN_E2E_RELAY_2:-ws://10.0.2.2:7778}"

# --- Mandatory live-sync define. No default, deliberately.
#
# `liveSyncEnabled` is `bool.fromEnvironment('HAVEN_LIVE_SYNC', defaultValue:
# true)`, so omitting the define does not produce an "unset" build — it
# produces a LIVE build nobody chose (CI_HARDENING_BACKLOG.md A7). Enforced by
# scripts/ci/check_live_sync_define_declared.sh.
if [[ -z "${HAVEN_LIVE_SYNC:-}" ]]; then
  echo "ERROR: HAVEN_LIVE_SYNC is not set." >&2
  echo "       This script bakes the receive path into the APK, and 'unset'" >&2
  echo "       compiles the live-sync engine ON via the Dart default —" >&2
  echo "       silently, whatever the lane is called. Set it to 'true' or" >&2
  echo "       'false' in the calling job's env." >&2
  exit 2
fi
if [[ ! "${HAVEN_LIVE_SYNC}" =~ ^(true|false)$ ]]; then
  echo "ERROR: HAVEN_LIVE_SYNC must be exactly 'true' or 'false'" \
       "(got '${HAVEN_LIVE_SYNC}')." >&2
  exit 2
fi

# --- Relay URLs.
#
# Validated as loopback ws:// rather than merely non-empty. Both values are
# interpolated into `--dart-define` arguments, so whitespace would word-split
# into extra `flutter build apk` arguments; and the drive target's own
# `TestUser.bootstrapProcess` rejects any non-loopback host outright, so a
# typo caught here fails with a name instead of surfacing 25 minutes later as
# a bootstrap StateError on a booted emulator.
readonly RELAY_RE='^ws://(localhost|127\.0\.0\.1|10\.0\.2\.2|\[::1\]):[0-9]{2,5}$'

require_relay() { # require_relay <name> <value>
  local name="$1" value="$2"
  if [[ ! "${value}" =~ ${RELAY_RE} ]]; then
    echo "ERROR: ${name}='${value}' is not a hermetic loopback ws:// URL." >&2
    echo "       This lane must never reach a public relay: it publishes" >&2
    echo "       KeyPackage material under a wall clock 70 days in the" >&2
    echo "       past." >&2
    exit 2
  fi
}

require_relay "HAVEN_E2E_RELAY" "${RELAY_URL}"
require_relay "HAVEN_E2E_RELAY_2" "${RELAY_URL_2}"

if [[ "${RELAY_URL}" == "${RELAY_URL_2}" ]]; then
  echo "ERROR: HAVEN_E2E_RELAY and HAVEN_E2E_RELAY_2 are the same URL" \
       "('${RELAY_URL}')." >&2
  echo "       The heal phase needs a responder that does NOT serve the" >&2
  echo "       account's slot; one relay cannot be both." >&2
  exit 2
fi

if [[ ! -f "pubspec.yaml" ]]; then
  echo "ERROR: must run from the haven/ Flutter project dir" \
       "(no pubspec.yaml here)." >&2
  exit 1
fi
if [[ ! -f "${TARGET}" ]]; then
  echo "ERROR: integration target not found: ${TARGET}" >&2
  exit 1
fi

# Bounded retry, same rationale as build-integration-apks.sh: Gradle dependency
# resolution intermittently 403/429/5xxs on shared CI IPs, which is a network
# flake rather than a build error, and Gradle keeps whatever it did fetch so a
# retry is cheap. A genuine compile error fails every attempt.
readonly BUILD_MAX_ATTEMPTS="${HAVEN_BUILD_MAX_ATTEMPTS:-3}"
readonly BUILD_RETRY_DELAY_SECS="${HAVEN_BUILD_RETRY_DELAY_SECS:-20}"

mkdir -p "${OUT_DIR}"

echo "============================================================"
echo "Building ${TARGET} -> ${OUT_DIR}/kp_rotation_wire_test.apk"
echo "  relay R1       ${RELAY_URL}"
echo "  relay R2       ${RELAY_URL_2}"
echo "  live sync      ${HAVEN_LIVE_SYNC}"
echo "============================================================"

attempt=1
rc=0
while (( attempt <= BUILD_MAX_ATTEMPTS )); do
  rc=0
  # `--target-platform android-x64`: the E2E AVDs are all x86_64. Without it
  # cargokit builds the large debug haven-core lib for four ABIs, which has
  # exhausted the runner disk.
  flutter build apk \
    --debug \
    --target-platform android-x64 \
    --target="${TARGET}" \
    --dart-define=HAVEN_LIVE_SYNC="${HAVEN_LIVE_SYNC}" \
    --dart-define=HAVEN_E2E_RELAY="${RELAY_URL}" \
    --dart-define=HAVEN_E2E_RELAY_2="${RELAY_URL_2}" || rc=$?
  if (( rc == 0 )); then
    break
  fi
  if (( attempt < BUILD_MAX_ATTEMPTS )); then
    echo "WARN: 'flutter build apk' failed (rc=${rc}, attempt" \
         "${attempt}/${BUILD_MAX_ATTEMPTS}) — retrying in" \
         "${BUILD_RETRY_DELAY_SECS}s." >&2
    sleep "${BUILD_RETRY_DELAY_SECS}"
  fi
  attempt=$(( attempt + 1 ))
done

if (( rc != 0 )); then
  echo "ERROR: 'flutter build apk' for ${TARGET} failed after" \
       "${BUILD_MAX_ATTEMPTS} attempts (rc=${rc})." >&2
  exit "${rc}"
fi

cp "${BUILD_APK}" "${OUT_DIR}/kp_rotation_wire_test.apk"
ls -lh "${OUT_DIR}/kp_rotation_wire_test.apk"
