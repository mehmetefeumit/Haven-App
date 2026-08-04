#!/usr/bin/env bash
#
# Builds the debug APK for the B3 real-GPS lane
# (docs/CI_HARDENING_BACKLOG.md Workstream B, item B3), BEFORE the emulator
# boots — the build-before-boot discipline every Android E2E lane follows, so
# the multi-GB Rust-NDK + Gradle peak never coincides with a resident emulator
# (see docs/E2E_TROUBLESHOOTING.md).
#
# # Why a DEDICATED build script rather than build-integration-apks.sh
#
# B3 is the only lane whose drive target must KNOW the coordinates the shell
# is about to inject with `adb emu geo fix`: its assertion is that the value a
# PEER decrypts equals the value that was injected, which is unassertable
# without both halves agreeing on a number. That means three extra
# `--dart-define`s (lat / lon / tolerance) which no other target reads and
# which must FAIL CLOSED when absent — the shared builder deliberately carries
# no per-lane knobs, and adding some would make every other lane pay for this
# one. Keeping them here also keeps the guarantee local: the same env pair
# feeds this build and `run-b3-real-gps.sh`, so a mismatch is impossible by
# construction rather than by review.
#
# Usage (run from the haven/ Flutter project dir, as the workflow does):
#   bash ../tooling/e2e/ci/build-b3-real-gps-apk.sh [<target.dart>]
#
# Required env (set by the calling job):
#   HAVEN_B3_GEO_LAT   latitude  the lane injects and asserts. No default.
#   HAVEN_B3_GEO_LON   longitude the lane injects and asserts. No default.
#   HAVEN_LIVE_SYNC    'true' | 'false'. MANDATORY, no default — see below.
#
# Optional env:
#   HAVEN_E2E_RELAY              ws:// URL baked into the APK.
#                                Default ws://10.0.2.2:7777.
#   HAVEN_B3_GEO_TOLERANCE_DEG   comparison tolerance in degrees.
#                                Default 1e-5 (matches the Dart default).
#
# Output:
#   /tmp/integration-apks/b3_real_gps_test.apk

set -euo pipefail

readonly OUT_DIR="/tmp/integration-apks"
readonly BUILD_APK="build/app/outputs/flutter-apk/app-debug.apk"
readonly TARGET="${1:-integration_test/b3_real_gps_test.dart}"
readonly RELAY_URL="${HAVEN_E2E_RELAY:-ws://10.0.2.2:7777}"

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

# --- Mandatory coordinates.
#
# Validated as decimal degrees rather than merely non-empty. The value is
# interpolated into a `--dart-define` AND, in the sibling runner, into an
# `adb emu geo fix` argument; an unvalidated value could word-split into extra
# arguments to either. The range check is the cheaper half of the same
# argument: a transposed lat/lon pair (|lat| > 90) is a lane that injects one
# point and asserts another, which would present as an unattributable
# "the peer decrypted the wrong coordinates".
readonly NUM_RE='^-?(([0-9]{1,3})(\.[0-9]{1,12})?)$'

require_coord() { # require_coord <name> <value> <abs-max>
  local name="$1" value="$2" absmax="$3"
  if [[ -z "${value}" ]]; then
    echo "ERROR: ${name} is not set. B3 asserts that the coordinates a PEER" >&2
    echo "       decrypts equal the ones injected with 'adb emu geo fix';" >&2
    echo "       with no value there is nothing to assert against." >&2
    exit 2
  fi
  if [[ ! "${value}" =~ ${NUM_RE} ]]; then
    echo "ERROR: ${name}='${value}' is not decimal degrees." >&2
    exit 2
  fi
  # Integer-only magnitude check: bash has no floats, and the degree part is
  # all that matters for an out-of-range coordinate.
  local whole="${value#-}"
  whole="${whole%%.*}"
  if (( 10#${whole} > absmax )); then
    echo "ERROR: ${name}='${value}' is outside +/-${absmax} degrees." >&2
    exit 2
  fi
}

require_coord "HAVEN_B3_GEO_LAT" "${HAVEN_B3_GEO_LAT:-}" 90
require_coord "HAVEN_B3_GEO_LON" "${HAVEN_B3_GEO_LON:-}" 180

readonly TOLERANCE="${HAVEN_B3_GEO_TOLERANCE_DEG:-1e-5}"
if [[ ! "${TOLERANCE}" =~ ^[0-9]+(\.[0-9]+)?(e-?[0-9]+)?$ ]]; then
  echo "ERROR: HAVEN_B3_GEO_TOLERANCE_DEG='${TOLERANCE}' is not a positive" \
       "decimal / scientific literal Dart can parse." >&2
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

# Bounded retry, same rationale as build-integration-apks.sh: Gradle
# dependency resolution intermittently 403/429/5xxs on shared CI IPs, which is
# a network flake rather than a build error, and Gradle keeps whatever it did
# fetch so a retry is cheap. A genuine compile error fails every attempt.
readonly BUILD_MAX_ATTEMPTS="${HAVEN_BUILD_MAX_ATTEMPTS:-3}"
readonly BUILD_RETRY_DELAY_SECS="${HAVEN_BUILD_RETRY_DELAY_SECS:-20}"

mkdir -p "${OUT_DIR}"

echo "============================================================"
echo "Building ${TARGET} -> ${OUT_DIR}/b3_real_gps_test.apk"
echo "  relay          ${RELAY_URL}"
echo "  live sync      ${HAVEN_LIVE_SYNC}"
echo "  injected fix   lat=${HAVEN_B3_GEO_LAT} lon=${HAVEN_B3_GEO_LON}"
echo "  tolerance      ${TOLERANCE} deg"
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
    --dart-define=HAVEN_B3_GEO_LAT="${HAVEN_B3_GEO_LAT}" \
    --dart-define=HAVEN_B3_GEO_LON="${HAVEN_B3_GEO_LON}" \
    --dart-define=HAVEN_B3_GEO_TOLERANCE_DEG="${TOLERANCE}" || rc=$?
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

cp "${BUILD_APK}" "${OUT_DIR}/b3_real_gps_test.apk"
ls -lh "${OUT_DIR}/b3_real_gps_test.apk"
