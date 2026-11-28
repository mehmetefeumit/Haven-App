#!/usr/bin/env bash
#
# Boots an iOS simulator for the E2E lane and emits its UDID.
#
# Selection is resilient to the exact Xcode/runtimes installed on the runner,
# and every lane on one image lands on the same runtime:
#   1. the newest available iOS runtime by version; among runtimes of that
#      version, one that supports the preferred device type, then the highest
#      build;
#   2. an existing available device of the preferred name ON THAT RUNTIME, else
#   3. a freshly created device of a type THAT RUNTIME supports: the preferred
#      one, else (with a ::warning::) its first supported iPhone.
# An image carries the same device name on several runtimes (the xcode-27
# image has "iPhone 17" on iOS 27.0 and 27.2), so a lookup across runtimes
# would boot whichever simctl happens to list first.
#
# Emits `udid=<udid>` to $GITHUB_OUTPUT (for `${{ steps.<id>.outputs.udid }}`)
# and to stdout. Uses python3 (preinstalled on GitHub macOS runners) to parse
# `simctl ... --json`, which is far less brittle than scraping the text table.
# Written for bash 3.2, macOS's /bin/bash.
#
# Usage: boot-ios-sim.sh [preferred-device-name]   (default "iPhone 17")
#        boot-ios-sim.sh --self-test               (stubbed xcrun; no Xcode)

set -euo pipefail

# How many fixtures --self-test runs. Pinned, because a fixture that stops
# running is the one way a deleted check reports success.
readonly SELF_TEST_FIXTURES=10

# The chosen runtime's identifier; rc 0 with no output when none is available.
newest_runtime() {  # $1 = preferred device name
  xcrun simctl list runtimes --json | python3 -I -c '
import json, re, sys
name = sys.argv[1]
rs = [r for r in json.load(sys.stdin)["runtimes"]
      if r.get("isAvailable") and "iOS" in r.get("name", "")]
def ver(r):
    return [int(x) for x in r.get("version", "0").split(".") if x.isdigit()]
def build(r):
    m = re.fullmatch(r"(\d+)([A-Za-z])(\d+)([a-z]?)", r.get("buildversion", ""))
    return (int(m.group(1)), m.group(2), int(m.group(3)), m.group(4)) if m else (0, "", 0, "")
def supports(r):
    return any(t.get("name") == name for t in r.get("supportedDeviceTypes") or [])
rs.sort(key=lambda r: (ver(r), supports(r), build(r)), reverse=True)
print(rs[0]["identifier"] if rs else "")' "$1"
}

existing_device() {  # $1 = device name, $2 = runtime identifier
  xcrun simctl list devices --json | python3 -I -c '
import json, sys
name, rt = sys.argv[1], sys.argv[2]
for dev in json.load(sys.stdin)["devices"].get(rt, []):
    if dev.get("isAvailable") and dev.get("name") == name:
        print(dev["udid"]); break
' "$1" "$2"
}

# "<identifier>\t<name>" of the type to create: the preferred one if the
# runtime supports it, else its first supported iPhone; nothing when it
# supports no iPhone.
device_type() {  # $1 = preferred device name, $2 = runtime identifier
  xcrun simctl list runtimes --json | python3 -I -c '
import json, sys
name, rt = sys.argv[1], sys.argv[2]
for r in json.load(sys.stdin)["runtimes"]:
    if r.get("identifier") == rt:
        ts = r.get("supportedDeviceTypes") or []
        exact = [t for t in ts if t.get("name") == name]
        iphones = [t for t in ts if t.get("productFamily") == "iPhone"]
        pick = exact or iphones
        if pick:
            print(pick[0]["identifier"] + "\t" + pick[0]["name"])
        break
' "$1" "$2"
}

boot() {
  local preferred="$1" runtime udid devtype devname
  runtime="$(newest_runtime "${preferred}")"
  if [[ -z "${runtime}" ]]; then
    echo "ERROR: no available iOS simulator runtime on this runner" >&2
    return 1
  fi

  udid="$(existing_device "${preferred}" "${runtime}")"
  devname="${preferred}"
  if [[ -z "${udid}" ]]; then
    IFS=$'\t' read -r devtype devname <<<"$(device_type "${preferred}" "${runtime}")" || true
    if [[ -z "${devtype:-}" ]]; then
      echo "ERROR: the ${runtime} runtime supports no iPhone device type" >&2
      return 1
    fi
    if [[ "${devname}" != "${preferred}" ]]; then
      echo "::warning::boot-ios-sim: the ${runtime} runtime does not support \"${preferred}\"; booting its first supported iPhone, \"${devname}\""
    fi
    echo "Creating simulator (${devtype} on ${runtime})..."
    udid="$(xcrun simctl create "haven-e2e" "${devtype}" "${runtime}")"
  fi

  echo "Booting ${devname} (${udid})..."
  xcrun simctl boot "${udid}" 2>/dev/null || true
  # Blocks until the simulator is fully booted (or fails).
  xcrun simctl bootstatus "${udid}" -b

  echo "Simulator booted: ${udid} (${devname}, ${runtime})"

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
  if ! xcrun simctl spawn "${udid}" log config --subsystem frb_user \
       --mode "level:debug,persist:debug" 2>/dev/null; then
    echo "WARNING: could not mark the frb_user oslog subsystem persistent; the" \
         "runtime log scanner's Rust plant may be evicted before 'log collect'" >&2
  fi

  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "udid=${udid}" >>"${GITHUB_OUTPUT}"
  fi
  echo "udid=${udid}"
}

# ---------------------------------------------------------------------------
# --self-test: a stub xcrun on PATH serves JSON fixtures and records every
# create and boot, so the selection is proved without a simulator.
# ---------------------------------------------------------------------------

self_test() {
  local tmp ran=0 fail=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN
  mkdir -p "${tmp}/bin"
  cat >"${tmp}/bin/xcrun" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == simctl ]] || exit 1
shift
case "$1 ${2:-}" in
  "list runtimes") cat "${FAKE_SIM}/runtimes.json" ;;
  "list devices") cat "${FAKE_SIM}/devices.json" ;;
  create*) echo "create $3 $4" >>"${FAKE_SIM}/events"; echo NEW-UDID ;;
  boot*) echo "boot $2" >>"${FAKE_SIM}/events" ;;
  bootstatus*) echo "bootstatus $2" >>"${FAKE_SIM}/events" ;;
  spawn*) ;;
  *) exit 1 ;;
esac
STUB
  chmod +x "${tmp}/bin/xcrun"

  # rt <id> <version> <build> <available> <type name>... — one runtime entry.
  rt() {
    local id="$1" v="$2" b="$3" a="$4" types="" n
    shift 4
    for n in "$@"; do
      local fam=iPhone
      [[ "${n}" == iPad* ]] && fam=iPad
      types="${types}${types:+,}{\"name\":\"${n}\",\"identifier\":\"type.${n// /-}\",\"productFamily\":\"${fam}\"}"
    done
    printf '{"identifier":"%s","name":"iOS %s","version":"%s","buildversion":"%s","isAvailable":%s,"supportedDeviceTypes":[%s]}' \
      "${id}" "${v}" "${v}" "${b}" "${a}" "${types}"
  }
  dev() { # <name> <udid> <available>
    printf '{"name":"%s","udid":"%s","isAvailable":%s}' "$1" "$2" "$3"
  }
  # fixture <runtimes, comma-joined> <devices object body>
  fixture() {
    rm -rf "${tmp}/sim"; mkdir -p "${tmp}/sim"
    printf '{"runtimes":[%s]}' "$1" >"${tmp}/sim/runtimes.json"
    printf '{"devices":{%s}}' "$2" >"${tmp}/sim/devices.json"
    : >"${tmp}/sim/events"
  }
  # case_ <desc> <want rc> <want udid or -> <want create or -> [<ere stdout must hold>]
  case_() {
    local desc="$1" want_rc="$2" want_udid="$3" want_create="$4" want_out="${5:-}" rc=0 out got_create
    ran=$((ran + 1))
    out="$(FAKE_SIM="${tmp}/sim" PATH="${tmp}/bin:${PATH}" GITHUB_OUTPUT= \
      bash "${BASH_SOURCE[0]}" "iPhone 17" 2>&1)" || rc=$?
    got_create="$(grep '^create ' "${tmp}/sim/events" || true)"
    if (( rc != want_rc )); then
      printf 'SELF-TEST FAIL: %s: rc %s, want %s\n%s\n' "${desc}" "${rc}" "${want_rc}" "${out}" >&2; fail=1; return
    fi
    if [[ "${want_udid}" != - ]] && ! grep -qx "udid=${want_udid}" <<<"${out}"; then
      printf 'SELF-TEST FAIL: %s: did not boot %s\n%s\n' "${desc}" "${want_udid}" "${out}" >&2; fail=1; return
    fi
    if [[ "${want_udid}" != - ]] && ! grep -qx "boot ${want_udid}" "${tmp}/sim/events"; then
      printf 'SELF-TEST FAIL: %s: %s was never booted\n' "${desc}" "${want_udid}" >&2; fail=1; return
    fi
    if [[ "${want_create}" == - && -n "${got_create}" ]] || [[ "${want_create}" != - && "${got_create}" != "create ${want_create}" ]]; then
      printf 'SELF-TEST FAIL: %s: created "%s", want "%s"\n' "${desc}" "${got_create}" "${want_create}" >&2; fail=1; return
    fi
    if [[ -n "${want_out}" ]] && ! grep -qE -- "${want_out}" <<<"${out}"; then
      printf 'SELF-TEST FAIL: %s: output lacks /%s/\n%s\n' "${desc}" "${want_out}" "${out}" >&2; fail=1; return
    fi
    printf '  PASS %s\n' "${desc}"
  }

  local r270 r272
  r270="$(rt rt.27-0 27.0 24A100 true "iPhone 17" "iPhone Air")"
  r272="$(rt rt.27-2 27.2 24C52 true "iPhone 17" "iPhone Duo")"

  # (1) The preferred device on the newest runtime, though its older-runtime
  #     twin is listed first.
  fixture "${r270},${r272}" "\"rt.27-0\":[$(dev "iPhone 17" OLD-UDID true)],\"rt.27-2\":[$(dev "iPhone 17" NEW-RT-UDID true)]"
  case_ "the preferred device on the newest runtime, not its older twin listed first" 0 NEW-RT-UDID - 'Simulator booted: NEW-RT-UDID \(iPhone 17, rt\.27-2\)'

  # (2) Present only on an older runtime: created on the newest.
  fixture "${r270},${r272}" "\"rt.27-0\":[$(dev "iPhone 17" OLD-UDID true)],\"rt.27-2\":[]"
  case_ "a device only an older runtime has is created on the newest" 0 NEW-UDID 'type.iPhone-17 rt.27-2'

  # (3) A preferred type the newest runtime does not support: its first
  #     supported iPhone, announced, never the unsupported type.
  fixture "$(rt rt.28-0 28.0 25A10 true "iPad Pro" "iPhone 19" "iPhone 19 Pro")" '"rt.28-0":[]'
  case_ "an unsupported preferred type falls back to the runtime's first iPhone, with a warning" 0 NEW-UDID 'type.iPhone-19 rt.28-0' '^::warning::.*does not support "iPhone 17".*"iPhone 19"'

  # (4) An unavailable device is skipped.
  fixture "${r272}" "\"rt.27-2\":[$(dev "iPhone 17" STALE-UDID false)]"
  case_ "an unavailable device is skipped" 0 NEW-UDID 'type.iPhone-17 rt.27-2'

  # (5) No iOS runtime.
  fixture '{"identifier":"rt.watch","name":"watchOS 12.0","version":"12.0","buildversion":"23R1","isAvailable":true,"supportedDeviceTypes":[{"name":"Apple Watch","identifier":"type.watch","productFamily":"Apple Watch"}]}' ''
  case_ "no iOS runtime fails" 1 - - 'no available iOS simulator runtime'

  # (6) A runtime that supports no iPhone.
  fixture "$(rt rt.27-2 27.2 24C52 true "iPad Pro" "iPad Air")" '"rt.27-2":[]'
  case_ "a runtime with no supported iPhone fails" 1 - - 'supports no iPhone device type'

  # (7) Two runtimes of one version, the one without the preferred type listed
  #     first: the one that supports it.
  fixture "$(rt rt.duo 27.2 24C60 true "iPhone Duo"),$(rt rt.main 27.2 24C52 true "iPhone 17" "iPhone Duo")" \
    "\"rt.duo\":[],\"rt.main\":[$(dev "iPhone 17" MAIN-UDID true)]"
  case_ "of two same-version runtimes, the one supporting the preferred type" 0 MAIN-UDID - 'rt\.main\)$'

  # (8) Two runtimes of one version that both support it: the higher build.
  fixture "$(rt rt.lo 27.2 24C52 true "iPhone 17"),$(rt rt.hi 27.2 24C108 true "iPhone 17")" '"rt.lo":[],"rt.hi":[]'
  case_ "of two same-version runtimes that both support it, the higher build" 0 NEW-UDID 'type.iPhone-17 rt.hi'

  # (9) An unavailable runtime is never chosen, however new.
  fixture "${r272},$(rt rt.29-0 29.0 26A1 false "iPhone 17")" '"rt.27-2":[],"rt.29-0":[]'
  case_ "an unavailable runtime is not chosen, however new" 0 NEW-UDID 'type.iPhone-17 rt.27-2'

  # (10) A runtime entry without supportedDeviceTypes cannot vouch for a type.
  fixture '{"identifier":"rt.bare","name":"iOS 27.2","version":"27.2","buildversion":"24C52","isAvailable":true}' '"rt.bare":[]'
  case_ "a runtime that lists no supported types fails" 1 - - 'supports no iPhone device type'

  if (( ran != SELF_TEST_FIXTURES )); then
    echo "SELF-TEST FAIL: ran ${ran} fixtures, expected ${SELF_TEST_FIXTURES}" >&2; fail=1
  fi
  if (( fail )); then echo "boot-ios-sim.sh --self-test: FAILED" >&2; return 1; fi
  echo "boot-ios-sim.sh --self-test: all ${ran} fixtures passed"
}

case "${1:-}" in
  --self-test) self_test ;;
  *) boot "${1:-iPhone 17}" ;;
esac
