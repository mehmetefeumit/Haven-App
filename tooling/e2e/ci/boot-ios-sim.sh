#!/usr/bin/env bash
#
# Boots an iOS simulator for the E2E lane and emits its UDID.
#
# Selection is resilient to the exact Xcode/runtime installed on the runner:
#   1. newest available iOS runtime,
#   2. an existing available device of the preferred type, else
#   3. a freshly created device of the preferred type (falling back to the
#      first available iPhone device type).
#
# Emits `udid=<udid>` to $GITHUB_OUTPUT (for `${{ steps.<id>.outputs.udid }}`)
# and to stdout. Uses python3 (preinstalled on GitHub macOS runners) to parse
# `simctl ... --json`, which is far less brittle than scraping the text table.
#
# Usage: boot-ios-sim.sh [preferred-device-name]   (default "iPhone 15")

set -euo pipefail

readonly PREFERRED="${1:-iPhone 15}"

newest_runtime() {
  xcrun simctl list runtimes --json | python3 -c '
import json, sys
rs = [r for r in json.load(sys.stdin)["runtimes"]
      if r.get("isAvailable") and "iOS" in r.get("name", "")]
def ver(r):
    return [int(x) for x in r.get("version", "0").split(".") if x.isdigit()]
rs.sort(key=ver, reverse=True)
print(rs[0]["identifier"] if rs else "")'
}

existing_device() {  # $1 = device name
  xcrun simctl list devices --json | python3 -c '
import json, sys
name = sys.argv[1]
for _rt, devs in json.load(sys.stdin)["devices"].items():
    for dev in devs:
        if dev.get("isAvailable") and dev["name"] == name:
            print(dev["udid"]); sys.exit(0)
' "$1"
}

device_type() {  # $1 = preferred device name
  xcrun simctl list devicetypes --json | python3 -c '
import json, sys
name = sys.argv[1]
ts = json.load(sys.stdin)["devicetypes"]
exact = [t["identifier"] for t in ts if t["name"] == name]
iphones = [t["identifier"] for t in ts if t["name"].startswith("iPhone")]
print(exact[0] if exact else (iphones[0] if iphones else ""))
' "$1"
}

RUNTIME="$(newest_runtime)"
if [[ -z "${RUNTIME}" ]]; then
  echo "ERROR: no available iOS simulator runtime on this runner" >&2
  exit 1
fi

UDID="$(existing_device "${PREFERRED}")"
if [[ -z "${UDID}" ]]; then
  DEVTYPE="$(device_type "${PREFERRED}")"
  if [[ -z "${DEVTYPE}" ]]; then
    echo "ERROR: no iPhone device type available on this runner" >&2
    exit 1
  fi
  echo "Creating simulator (${DEVTYPE} on ${RUNTIME})..."
  UDID="$(xcrun simctl create "haven-e2e" "${DEVTYPE}" "${RUNTIME}")"
fi

echo "Booting ${PREFERRED} (${UDID})..."
xcrun simctl boot "${UDID}" 2>/dev/null || true
# Blocks until the simulator is fully booted (or fails).
xcrun simctl bootstatus "${UDID}" -b

echo "Simulator booted: ${UDID}"

# Persist Haven's OWN oslog subsystem, and nothing else.
#
# The `oslog` crate maps Rust's `log::Debug` to OS_LOG_TYPE_INFO, and logd keeps
# INFO records in a wrapping MEMORY buffer it never writes to the persisted
# store — so whether `log collect` still finds them is decided by how long the
# app ran, not by whether the backend worked. CI run 35280144455 measured
# exactly that: the opening plant (`log::debug!`, the LAST statement of
# `init_app`) survived in the two lanes whose app lived 15 s and 24 s and was
# gone from the two that ran for minutes, while the `warn!`/`info!` lines of the
# same launch survived in all four. A positive control a lane's DURATION can
# decide is not a control, so the subsystem is marked persistent before any app
# writes to it.
#
# Best-effort and loud: a runner image whose `log config` refuses leaves the
# plant duration-dependent again, which the scanner reports as the missed
# control it is (rc 3) rather than as a pass.
if ! xcrun simctl spawn "${UDID}" log config --subsystem frb_user \
     --mode "level:debug,persist:debug" 2>/dev/null; then
  echo "WARNING: could not mark the frb_user oslog subsystem persistent; the" \
       "runtime log scanner's Rust plant may be evicted before 'log collect'" >&2
fi

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "udid=${UDID}" >>"${GITHUB_OUTPUT}"
fi
echo "udid=${UDID}"
