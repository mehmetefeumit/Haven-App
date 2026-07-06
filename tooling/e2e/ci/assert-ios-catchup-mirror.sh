#!/usr/bin/env bash
#
# Asserts the M7-E iOS mirror at the OS (UserDefaults) layer — a belt over the
# in-Dart read-back in ios_bg_mirror_test.dart (docs/M7E_GO_LIVE_PLAN.md D7).
#
# After the mirror scenario writes `flutter.background_catchup_enabled` via
# SharedPreferences, this reads the app's REAL NSUserDefaults plist from the
# simulator's data container and confirms the value is true. The Swift side
# gates all scheduling on this exact key, so proving it at the plist layer
# corroborates that a device launch arms (rather than inerts) the wake paths.
#
# Why a checked-in script: CI-best-practices — no multi-line inline YAML `run:`
# blobs; keep the settle + plist parsing here where it is testable and in sync.
#
# Usage:
#   bash tooling/e2e/ci/assert-ios-catchup-mirror.sh <simulator-udid>
#
# Exit codes: 0 = mirror is true; 1 = not true / plist or container missing;
# 2 = usage error.

set -Eeuo pipefail

readonly UDID="${1:-}"
if [[ -z "${UDID}" ]]; then
  echo "ERROR: usage: $0 <simulator-udid>" >&2
  exit 2
fi

readonly BUNDLE_ID="com.oblivioustech.haven"
# SharedPreferences stores under the `flutter.` prefix on iOS, so the Dart key
# `background_catchup_enabled` is `flutter.background_catchup_enabled` here.
readonly KEY="flutter.background_catchup_enabled"

# Settle: give the sim a moment to flush UserDefaults to the on-disk plist after
# the Dart test wrote the mirror (A10 — the write is async at the OS layer).
sleep 3

container="$(xcrun simctl get_app_container "${UDID}" "${BUNDLE_ID}" data 2>/dev/null)" || {
  echo "ERROR: could not resolve the data container for ${BUNDLE_ID} on ${UDID} " \
       "(is the app still installed after the mirror scenario?)." >&2
  exit 1
}
readonly PLIST="${container}/Library/Preferences/${BUNDLE_ID}.plist"

if [[ ! -f "${PLIST}" ]]; then
  echo "ERROR: mirror plist not found at ${PLIST}" >&2
  exit 1
fi

# L3: read ONLY the target key — do NOT dump the whole Preferences plist, which
# can carry unrelated on-device-only values (e.g. display names) after the app
# has run. PlistBuddy uses ':' as its key separator, so ":${KEY}" addresses the
# LITERAL flat NSUserDefaults key (which itself contains dots — `plutil
# -extract` would mis-parse those dots as a nested keypath). An NSNumber(bool)
# prints as `true`; accept `1` defensively.
value="$(/usr/libexec/PlistBuddy -c "Print :${KEY}" "${PLIST}" 2>/dev/null || true)"
echo "== ${KEY} = ${value:-<absent>} =="
if [[ "${value}" == "true" || "${value}" == "1" ]]; then
  echo "OK: ${KEY} is true at the UserDefaults layer (M7-E mirror armed)."
  exit 0
fi

echo "ERROR: ${KEY} is not true in ${BUNDLE_ID}.plist (value: ${value:-<absent>})" \
     "— the M7-E mirror was not written." >&2
exit 1
