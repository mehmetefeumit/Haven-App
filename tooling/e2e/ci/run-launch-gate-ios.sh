#!/usr/bin/env bash
#
# The iOS launch gate's runner (docs/LAUNCH_GATE.md): the candidate simulator
# app, started from the OS through its production main(), offline.
#
#   fresh    uninstall (keychain reset), install the candidate, onboard
#            (intro -> create -> a terminal screen), cold relaunch: the same
#            terminal screen and, when setup is held, the name the first run
#            saved — restored through the Keychain identity it is keyed by.
#   upgrade  the previous release's simulator build (its GitHub Release asset
#            app-ios-simulator.zip + .sha256), onboarded in its own words;
#            the candidate installed over it with its data kept; the same
#            terminal screen and the same name.
#
# The XCUITest bundle (tooling/e2e/ios-launch-gate) does the driving; this
# script installs, blocks egress, picks which test method each xcodebuild run
# executes (-only-testing) and classifies what came back.
#
# Offline, because a release build knows only production relays: pf blocks new
# TCP 80/443 and UDP 443 from the host the simulator shares (an anchor under
# com.apple, a pf enable token kept and released, the rules and the anchor's
# reach asserted). A probe that should be refused must fail before the first
# leg and after the last, and the block is released on every exit (and again by
# the workflow's `if: always()` step through --release-egress).
#
# The predecessor is the newest by version of the non-draft, non-prerelease
# releases with a plain vMAJOR.MINOR.PATCH tag below the candidate's (a pull
# request rules out nothing by version), not yanked for ios or all in
# scripts/ci/launch_gate_yanked_releases.txt, that carries app-ios-simulator.zip
# and its .sha256: a release whose iOS gate failed never reached TestFlight, so
# the release before it is what iOS users upgrade from. It is looked up and
# downloaded before egress is blocked.
#
# Usage:
#   run-launch-gate-ios.sh <simulator-udid> <candidate Runner.app> <.xctestrun>
#   run-launch-gate-ios.sh --release-egress   undo a block a killed run left
#   run-launch-gate-ios.sh --self-test        hermetic; no simulator, no Xcode
#
# Environment:
#   HAVEN_LAUNCH_GATE_CANDIDATE_TAG  the tag being released ('' outside a tag)
#   GITHUB_REPOSITORY, GH_TOKEN      the release lookup
#   HAVEN_LOGSCAN                    'true' runs the identifier scanner in the
#                                    gate over the summary (logscan-gate.sh)
#
# Output: /tmp/launch-gate-ios/launch-gate-summary.log, the one file a lane
# uploads, written by this script alone (legs, verdicts, the allowlisted lines
# of each xcodebuild transcript, crash-report frames) and passed through the
# log-privacy gate before it is echoed. Transcripts, result bundles and the
# downloaded build stay in an owner-only work directory deleted on exit.
#
# Exit: 0 every leg passed; 1 the candidate failed (product); 3 infrastructure
# (a second attempt runs only when this one started no test case); 4 the
# previous release's build cannot serve as the upgrade source (yank it); 5 the
# fresh legs passed and no iOS predecessor build exists to upgrade from; 2
# misuse, or a missing or malformed yanked-release list. Written for bash 3.2,
# macOS's /bin/bash, whichever bash PATH resolves.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
readonly REPO_ROOT
# shellcheck source=tooling/e2e/ci/logscan-gate.sh
source "${SCRIPT_DIR}/logscan-gate.sh"

readonly BUNDLE_ID='com.oblivioustech.haven'
readonly TEST_TARGET='LaunchGateUITests/LaunchGateUITests'
readonly ASSET_ZIP='app-ios-simulator.zip'
readonly PF_ANCHOR='com.apple/haven-launch-gate'
readonly NEEDLE_DIR=/tmp/haven-soak/needles
readonly OUT_DIR=/tmp/launch-gate-ios
readonly SUMMARY_LOG=/tmp/launch-gate-ios/launch-gate-summary.log
readonly REPORT=/tmp/ios-logscan/launch-gate.ndjson
# One xcodebuild run: the runner app's install and launch, then one test,
# which XCTest itself stops at TEST_ALLOWANCE_SECS.
readonly TEST_SECS="${HAVEN_LAUNCH_GATE_TEST_SECS:-900}"
readonly TEST_ALLOWANCE_SECS=600
readonly KILL_GRACE_SECS="${HAVEN_LAUNCH_GATE_KILL_GRACE_SECS:-30}"
# How long ReportCrash may take to write a failed leg's report.
readonly IPS_SETTLE_SECS="${HAVEN_LAUNCH_GATE_IPS_SETTLE_SECS:-30}"
readonly PROBE_SECS=10
readonly STATE_DIR="${HAVEN_LAUNCH_GATE_STATE_DIR:-/tmp/haven-launch-gate-ios-state}"
readonly DIAG_DIR="${HAVEN_LAUNCH_GATE_DIAG_DIR:-${HOME}/Library/Logs/DiagnosticReports}"
readonly YANKED_LIST="${HAVEN_LAUNCH_GATE_YANKED:-${REPO_ROOT}/scripts/ci/launch_gate_yanked_releases.txt}"

# ARB key -> the TEST_RUNNER_ variable the UI test reads (xcodebuild strips the
# prefix). The first three are required of every build driven.
readonly LABEL_KEYS='onboardingWelcomeCta:GATE_WELCOME_CTA
onboardingCreateIdentityCta:GATE_CREATE_CTA
commonSettings:GATE_MAP
locationDisclosureNotNow:GATE_DISCLOSURE_NOT_NOW
onboardingFinishSetupError:GATE_SETUP_HELD
onboardingCreateIdentityError:GATE_CREATE_ERROR
onboardingDisplayNameError:GATE_NAME_ERROR'

WORK=""
TEST_STARTED=0
FINAL_RC=0
GATE_REASON=""

note() { printf '%s\n' "$*" >>"${SUMMARY_LOG}"; }

# ---------------------------------------------------------------------------
# Bounded runs. macOS has no coreutils `timeout`.
# ---------------------------------------------------------------------------

# run_bounded <log> <cmd>... — the command's status, or 124 when it outlived
# TEST_SECS (SIGTERM, then SIGKILL after KILL_GRACE_SECS).
run_bounded() {
  local log="$1" pid rc=0
  shift
  "$@" >>"${log}" 2>&1 &
  pid=$!
  local deadline=$(( SECONDS + TEST_SECS ))
  while (( SECONDS < deadline )); do
    if ! kill -0 "${pid}" 2>/dev/null; then
      wait "${pid}" || rc=$?
      return "${rc}"
    fi
    sleep 1
  done
  kill -TERM "${pid}" 2>/dev/null || true
  local grace=$(( SECONDS + KILL_GRACE_SECS ))
  while (( SECONDS < grace )); do
    kill -0 "${pid}" 2>/dev/null || break
    sleep 1
  done
  kill -KILL "${pid}" 2>/dev/null || true
  wait "${pid}" 2>/dev/null || true
  return 124
}

# ---------------------------------------------------------------------------
# Labels from an ARB
# ---------------------------------------------------------------------------

# arb_env <arb file> — NUL-separated TEST_RUNNER_GATE_*=<label> for the keys the
# ARB has; rc 3 when a required key is absent or a label is not literal text.
arb_env() {
  python3 -I -c '
import json, sys
pairs = [line.split(":") for line in sys.argv[2].splitlines()]
with open(sys.argv[1], encoding="utf-8") as f:
    arb = json.load(f)
out = []
for i, (key, var) in enumerate(pairs):
    value = arb.get(key)
    if value is None and i >= 3:
        continue
    if not isinstance(value, str) or not value or "{" in value or "\n" in value:
        print("no literal label for " + key, file=sys.stderr)
        sys.exit(3)
    out.append("TEST_RUNNER_" + var + "=" + value)
sys.stdout.write("".join(v + "\0" for v in out))
' "$1" "${LABEL_KEYS}"
}

# ---------------------------------------------------------------------------
# Egress
# ---------------------------------------------------------------------------

# 0 when the probe was REFUSED, which is what a block must do.
probe_refused() { # <url>
  ! curl -sS --max-time "${PROBE_SECS}" -o /dev/null "$1" >/dev/null 2>&1
}

block_egress_pf() {
  local out token rules info main
  out="$(sudo pfctl -E 2>&1)" || { GATE_REASON="pfctl -E failed"; return 3; }
  token="$(sed -n 's/^Token : \([0-9][0-9]*\)$/\1/p' <<<"${out}")"
  [[ -n "${token}" ]] || { GATE_REASON="pfctl -E returned no enable token"; return 3; }
  printf '%s\n' "${token}" >"${STATE_DIR}/pf.token"
  printf '%s\n' \
    'block return out quick proto tcp from any to any port 443 flags S/SA' \
    'block return out quick proto tcp from any to any port 80 flags S/SA' \
    'block return out quick proto udp from any to any port 443' \
    | sudo pfctl -a "${PF_ANCHOR}" -f - >/dev/null 2>&1 \
    || { GATE_REASON="pf refused the anchor's rules"; return 3; }
  rules="$(sudo pfctl -a "${PF_ANCHOR}" -sr 2>/dev/null)" || rules=""
  grep -qE '^block return out quick proto tcp .*port = (443|https) flags S/SA' <<<"${rules}" \
    && grep -qE '^block return out quick proto tcp .*port = (80|http|www) flags S/SA' <<<"${rules}" \
    && grep -qE '^block return out quick proto udp .*port = (443|https)' <<<"${rules}" \
    || { GATE_REASON="the pf anchor does not hold the three block rules"; return 3; }
  info="$(sudo pfctl -s info 2>/dev/null)" || info=""
  grep -q '^Status: Enabled' <<<"${info}" || { GATE_REASON="pf is not enabled"; return 3; }
  # Rules in an anchor the main ruleset never evaluates block nothing.
  main="$(sudo pfctl -sr 2>/dev/null)" || main=""
  grep -qF 'anchor "com.apple/*"' <<<"${main}" \
    || { GATE_REASON="the main pf ruleset does not evaluate com.apple/*"; return 3; }
}

block_egress() {
  mkdir -p "${STATE_DIR}"
  chmod 0700 "${STATE_DIR}"
  block_egress_pf || return $?
  egress_still_blocked || return $?
  note "egress: blocked (pf); a probe that should be refused was refused"
}

egress_still_blocked() {
  probe_refused https://github.com/ || { GATE_REASON="egress is not blocked: the probe connected"; return 3; }
}

release_egress() {
  if [[ -f "${STATE_DIR}/pf.token" ]]; then
    sudo pfctl -a "${PF_ANCHOR}" -F all >/dev/null 2>&1 || true
    sudo pfctl -X "$(cat "${STATE_DIR}/pf.token")" >/dev/null 2>&1 || true
    rm -f "${STATE_DIR}/pf.token"
  fi
}

# ---------------------------------------------------------------------------
# The previous release's simulator build
# ---------------------------------------------------------------------------

PREV_TAG=""
PREV_APP=""
declare -a PREV_ENV=()
declare -a CAND_ENV=()

# resolve_previous — 0 with PREV_TAG/PREV_APP/PREV_ENV set; 5 no predecessor
# build; 4 the predecessor's build is unusable; 3 the lookup failed; 2 the
# yanked list is missing or malformed.
resolve_previous() {
  local releases yanked="" tag reason rc=0 dl="${WORK}/previous" line
  [[ -f "${YANKED_LIST}" ]] || { GATE_REASON="the yanked-release list is missing"; return 2; }
  local platform
  while read -r tag platform reason; do
    [[ -z "${tag}" || "${tag}" == \#* ]] && continue
    [[ "${tag}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ && "${platform}" =~ ^(android|ios|all)$ && -n "${reason}" ]] \
      || { GATE_REASON="the yanked-release list has a line that is not '<vMAJOR.MINOR.PATCH> <android|ios|all> <reason>'"; return 2; }
    [[ "${platform}" == android ]] || yanked="${yanked} ${tag}"
  done <"${YANKED_LIST}"
  releases="$(gh api "repos/${GITHUB_REPOSITORY}/releases?per_page=100" 2>/dev/null)" \
    || { GATE_REASON="the release list could not be read"; return 3; }
  tag="$(python3 -I -c '
import json, re, sys
releases, cand, yanked = json.loads(sys.argv[1]), sys.argv[2], set(sys.argv[3].split())
def ver(t):
    m = re.fullmatch(r"v(\d+)\.(\d+)\.(\d+)", t)
    return tuple(int(x) for x in m.groups()) if m else None
limit = ver(cand) if cand else None
eligible = [r for r in releases
            if not r.get("draft") and not r.get("prerelease") and ver(r.get("tag_name", ""))
            and r["tag_name"] != cand and r["tag_name"] not in yanked
            and (limit is None or ver(r["tag_name"]) < limit)]
pair = {sys.argv[4], sys.argv[4] + ".sha256"}
carrying = [r for r in eligible if pair <= {a.get("name") for a in r.get("assets", [])}]
if not carrying:
    sys.exit(5)
print(max(carrying, key=lambda r: ver(r["tag_name"]))["tag_name"])
' "${releases}" "${HAVEN_LAUNCH_GATE_CANDIDATE_TAG:-}" "${yanked}" "${ASSET_ZIP}")" || rc=$?
  case "${rc}" in
    0) ;;
    5) note "upgrade: no iOS predecessor build (no eligible release carries ${ASSET_ZIP} and its checksum)"; return 5 ;;
    *) GATE_REASON="the predecessor could not be chosen"; return 3 ;;
  esac
  PREV_TAG="${tag}"
  mkdir -p "${dl}"
  gh release download "${tag}" --repo "${GITHUB_REPOSITORY}" --dir "${dl}" \
    --pattern "${ASSET_ZIP}" --pattern "${ASSET_ZIP}.sha256" >/dev/null 2>&1 \
    || { GATE_REASON="${tag}'s simulator asset could not be downloaded"; return 3; }
  line="$(cat "${dl}/${ASSET_ZIP}.sha256")"
  [[ "${line:0:64}" =~ ^[0-9a-f]{64}$ && "${line:64}" == "  ${ASSET_ZIP}" ]] \
    || { GATE_REASON="${tag}'s checksum file does not name ${ASSET_ZIP} alone"; return 4; }
  # release-build.yml verified the pair before attaching it, so a mismatch
  # here is the download's.
  (cd "${dl}" && shasum -a 256 -c "${ASSET_ZIP}.sha256" >/dev/null 2>&1) \
    || { GATE_REASON="${tag}'s ${ASSET_ZIP} does not match its checksum as downloaded"; return 3; }
  ditto -x -k "${dl}/${ASSET_ZIP}" "${dl}/x" >/dev/null 2>&1 \
    || { GATE_REASON="${tag}'s ${ASSET_ZIP} does not unpack"; return 4; }
  PREV_APP="${dl}/x/Runner.app"
  [[ "$(cd "${dl}/x" && ls)" == "Runner.app" ]] && simulator_app_ok "${PREV_APP}" \
    || { GATE_REASON="${tag}'s ${ASSET_ZIP} is not one simulator Runner.app"; return 4; }
  git -C "${REPO_ROOT}" fetch --quiet --depth=1 origin "+refs/tags/${tag}:refs/tags/${tag}" >/dev/null 2>&1 \
    && git -C "${REPO_ROOT}" show "${tag}:haven/lib/l10n/app_en.arb" >"${WORK}/previous.arb" 2>/dev/null \
    || { GATE_REASON="${tag}'s English ARB could not be read"; return 3; }
  load_env "${WORK}/previous.arb" \
    || { GATE_REASON="${tag}'s ARB lacks a label the journey needs"; return 4; }
  PREV_ENV=("${LOADED_ENV[@]}")
  note "upgrade: source ${tag}"
}

# simulator_app_ok <Runner.app> — Haven's bundle id, built for the simulator.
simulator_app_ok() {
  [[ -f "$1/Info.plist" ]] || return 1
  python3 -I -c '
import plistlib, sys
with open(sys.argv[1] + "/Info.plist", "rb") as f:
    p = plistlib.load(f)
sys.exit(0 if p.get("CFBundleIdentifier") == sys.argv[2] and p.get("DTPlatformName") == "iphonesimulator" else 1)
' "$1" "${BUNDLE_ID}"
}

# load_env <arb> — LOADED_ENV from arb_env, which always yields the three
# required labels.
LOADED_ENV=()
load_env() {
  local item out="${WORK}/labels"
  arb_env "$1" >"${out}" || return 1
  LOADED_ENV=()
  while IFS= read -r -d '' item; do LOADED_ENV+=("${item}"); done <"${out}"
  rm -f "${out}"
}

# ---------------------------------------------------------------------------
# Installs
# ---------------------------------------------------------------------------

installed_executable_sha() { # <udid>
  local container exe
  container="$(xcrun simctl get_app_container "$1" "${BUNDLE_ID}" app 2>/dev/null)" || return 1
  exe="$(bundle_executable "${container}")"
  shasum -a 256 "${container}/${exe}" | cut -d' ' -f1
}

bundle_executable() {
  python3 -I -c '
import plistlib, sys
with open(sys.argv[1] + "/Info.plist", "rb") as f:
    print(plistlib.load(f).get("CFBundleExecutable", "Runner"))
' "$1"
}

# The Keychain outlives an uninstall; reset it so every leg creates its own
# identity rather than finding the last leg's.
uninstall_app() { # <udid>
  xcrun simctl uninstall "$1" "${BUNDLE_ID}" >/dev/null 2>&1 || true
  if xcrun simctl get_app_container "$1" "${BUNDLE_ID}" app >/dev/null 2>&1; then
    GATE_REASON="the simulator still holds the app after an uninstall"; return 3
  fi
  xcrun simctl keychain "$1" reset >/dev/null 2>&1 \
    || { GATE_REASON="the simulator's keychain could not be reset"; return 3; }
}

# ---------------------------------------------------------------------------
# One xcodebuild run of one test method
# ---------------------------------------------------------------------------

# Crash reports present now, so a leg names only its own.
ips_mark() { # <file>
  ls "${DIAG_DIR}"/Runner*.ips 2>/dev/null | sort >"$1" || true
}

# New Runner crash reports (bug_type 309) since <mark>, one path per line.
ips_new_crashes() { # <mark>
  local f
  ls "${DIAG_DIR}"/Runner*.ips 2>/dev/null | sort | comm -13 "$1" - | while IFS= read -r f; do
    python3 -I -c '
import json, sys
with open(sys.argv[1], encoding="utf-8", errors="replace") as f:
    head = json.loads(f.readline())
sys.exit(0 if str(head.get("bug_type")) == "309" else 1)
' "${f}" 2>/dev/null && printf '%s\n' "${f}"
  done
  return 0
}

# The exception and the crashed thread's frames (image basename + symbol) of
# each report: no path, process id, timestamp, device or incident id.
ips_summary() { # <report>...
  python3 -I -c '
import json, os, sys
for n, path in enumerate(sys.argv[1:], 1):
    with open(path, encoding="utf-8", errors="replace") as f:
        f.readline()
        try:
            body = json.loads(f.read())
        except ValueError:
            print("crash report %d: body unreadable" % n)
            continue
    exc = body.get("exception") or {}
    print("crash report %d: %s %s" % (n, exc.get("type", "?"), exc.get("signal", "")))
    images = body.get("usedImages") or []
    def image(i):
        if isinstance(i, int) and 0 <= i < len(images):
            img = images[i]
            return img.get("name") or os.path.basename(img.get("path") or "") or "?"
        return "?"
    def frames(label, fs):
        print("  " + label)
        for k, fr in enumerate(fs[:32]):
            print("    #%02d %s %s" % (k, image(fr.get("imageIndex")), fr.get("symbol", "?")))
    threads = body.get("threads") or []
    i = body.get("faultingThread")
    if isinstance(i, int) and 0 <= i < len(threads):
        frames("crashed thread", threads[i].get("frames") or [])
    if body.get("lastExceptionBacktrace"):
        frames("last exception backtrace", body["lastExceptionBacktrace"])
' "$@"
}

# The transcript lines a summary may keep: test-case progress, XCTest failure
# and xcodebuild error lines, the result banners and the terminal marker.
# Paths are cut to their last component and UUIDs (the simulator's) dropped.
transcript_lines() { # <transcript>
  python3 -I -c '
import re, sys
uuid = re.compile(r"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\b")
path = re.compile(r"(?<![\w.])/(?:[^\s/:\x27\"]+/)+([^\s/:\x27\"]+)")
keep = re.compile(r"^\s*Test [Cc]ase \x27.*\x27 (started|passed|failed)|: error: |^\*\* TEST .*\*\*$|^\s*Executed \d+ tests?,|LAUNCH-GATE-TERMINAL (SETUP_HELD|MAP)$|^Testing failed:")
tail = False
with open(sys.argv[1], encoding="utf-8", errors="replace") as f:
    for raw in f:
        line = raw.rstrip("\n")
        if "LAUNCH-GATE-NAME-DIGEST" in line:
            continue
        if keep.search(line) or (tail and line.startswith("\t")):
            tail = line.startswith("Testing failed:") or (tail and line.startswith("\t"))
            print("  | " + uuid.sub("<uuid>", path.sub(r"\1", line))[:300])
        else:
            tail = False
' "$1"
}

# run_test <leg> <method> <env assignment>... — 0 passed; 1 the test failed;
# 3 no test case started. Writes the transcript to ${WORK}/<leg>.log.
run_test() {
  local leg="$1" method="$2" rc=0 started=0 passed=0 failed=0
  shift 2
  local log="${WORK}/${leg}.log" mark="${WORK}/${leg}.ips-mark" crashes
  : >"${log}"
  ips_mark "${mark}"
  run_bounded "${log}" env "$@" xcodebuild test-without-building \
    -xctestrun "${XCTESTRUN}" -destination "id=${UDID}" \
    -only-testing:"${TEST_TARGET}/${method}" -parallel-testing-enabled NO \
    -test-timeouts-enabled YES -maximum-test-execution-time-allowance "${TEST_ALLOWANCE_SECS}" \
    -resultBundlePath "${WORK}/${leg}.xcresult" || rc=$?
  local pat="(-\[LaunchGateUITests\.LaunchGateUITests ${method}\]|LaunchGateUITests\.${method}\(\))"
  grep -qE "Test [Cc]ase '${pat}' started" "${log}" && started=1
  grep -qE "Test [Cc]ase '${pat}' passed" "${log}" && passed=1
  grep -qE "Test [Cc]ase '${pat}' failed" "${log}" && failed=1
  (( started )) && TEST_STARTED=1
  note "leg ${leg}: ${method} (xcodebuild rc ${rc})"
  transcript_lines "${log}" >>"${SUMMARY_LOG}"
  # A failed leg's report can land a moment after the process died.
  crashes="$(ips_new_crashes "${mark}")"
  if [[ -z "${crashes}" ]] && (( started )) && (( ! passed || failed || rc != 0 )); then
    local deadline=$(( SECONDS + IPS_SETTLE_SECS ))
    while (( SECONDS < deadline )); do
      crashes="$(ips_new_crashes "${mark}")"
      [[ -z "${crashes}" ]] || break
      sleep 1
    done
  fi
  if [[ -n "${crashes}" ]]; then
    local -a reports=()
    while IFS= read -r f; do reports+=("${f}"); done <<<"${crashes}"
    note "leg ${leg}: the app crashed"
    ips_summary "${reports[@]}" >>"${SUMMARY_LOG}"
    return 1
  fi
  if (( passed && ! failed && rc == 0 )); then return 0; fi
  if (( ! started )); then
    note "leg ${leg}: no test case started"
    return 3
  fi
  (( rc == 124 )) && note "leg ${leg}: xcodebuild outlived its ${TEST_SECS} s bound"
  return 1
}

marker() { # <leg> <name> — the value a passed test printed after "LAUNCH-GATE-<name> "
  sed -n "s/.*LAUNCH-GATE-$2 \([A-Za-z0-9_]*\)\$/\1/p" "${WORK}/$1.log" | tail -n 1
}

# ---------------------------------------------------------------------------
# Legs
# ---------------------------------------------------------------------------

leg_fresh() {
  local rc=0 terminal
  uninstall_app "${UDID}" || return 3
  xcrun simctl install "${UDID}" "${CANDIDATE}" >/dev/null 2>&1 \
    || { GATE_REASON="the simulator refused to install the candidate"; return 1; }
  run_test fresh testFreshInstallThenColdRelaunch ${CAND_ENV[@]+"${CAND_ENV[@]}"} || rc=$?
  case "${rc}" in
    0) terminal="$(marker fresh TERMINAL)"
       note "leg fresh: PASS (terminal ${terminal:-unknown}; cold relaunch restored it)" ;;
    3) GATE_REASON="the fresh leg's test never started" ;;
    *) GATE_REASON="the candidate failed the fresh install and cold relaunch" ;;
  esac
  return "${rc}"
}

leg_upgrade() {
  local rc=0 terminal digest salt want got
  uninstall_app "${UDID}" || return 3
  xcrun simctl install "${UDID}" "${PREV_APP}" >/dev/null 2>&1 \
    || { GATE_REASON="the simulator refused to install ${PREV_TAG}'s build"; return 3; }
  xcrun simctl privacy "${UDID}" grant location "${BUNDLE_ID}" >/dev/null 2>&1 \
    || { GATE_REASON="the location grant for the upgrade source failed"; return 3; }
  salt="$(openssl rand -hex 16)" || salt=""
  [[ "${salt}" =~ ^[0-9a-f]{32}$ ]] || { GATE_REASON="no salt could be drawn"; return 3; }
  run_test upgrade-source testOnboardUpgradeSource \
    ${PREV_ENV[@]+"${PREV_ENV[@]}"} "TEST_RUNNER_GATE_NAME_SALT=${salt}" || rc=$?
  case "${rc}" in
    0) ;;
    3) GATE_REASON="the upgrade source's test never started"; return 3 ;;
    *) GATE_REASON="${PREV_TAG}'s build did not onboard offline: it cannot be the upgrade source"; return 4 ;;
  esac
  terminal="$(marker upgrade-source TERMINAL)"
  digest="$(marker upgrade-source NAME-DIGEST)"
  [[ "${terminal}" =~ ^(SETUP_HELD|MAP)$ && "${digest}" =~ ^[0-9a-f]{64}$ ]] \
    || { GATE_REASON="the upgrade source's test passed without reporting its terminal and digest"; return 1; }
  note "leg upgrade-source: PASS (${PREV_TAG}, terminal ${terminal})"

  xcrun simctl install "${UDID}" "${CANDIDATE}" >/dev/null 2>&1 \
    || { GATE_REASON="the simulator refused to install the candidate over ${PREV_TAG}"; return 1; }
  want="$(shasum -a 256 "${CANDIDATE}/$(bundle_executable "${CANDIDATE}")" | cut -d' ' -f1)"
  got="$(installed_executable_sha "${UDID}")" || got=""
  [[ -n "${got}" && "${got}" == "${want}" ]] \
    || { GATE_REASON="after the upgrade the simulator does not run the candidate's executable"; return 1; }
  rc=0
  run_test upgrade testUpgradedCandidateRelaunch ${CAND_ENV[@]+"${CAND_ENV[@]}"} \
    "TEST_RUNNER_GATE_NAME_SALT=${salt}" "TEST_RUNNER_GATE_EXPECT_TERMINAL=${terminal}" \
    "TEST_RUNNER_GATE_EXPECT_NAME_DIGEST=${digest}" || rc=$?
  case "${rc}" in
    0) note "leg upgrade: PASS (over ${PREV_TAG}: terminal ${terminal} and the name kept)" ;;
    3) GATE_REASON="the upgraded candidate's test never started" ;;
    *) GATE_REASON="the candidate failed after the upgrade from ${PREV_TAG}" ;;
  esac
  return "${rc}"
}

# ---------------------------------------------------------------------------
# Exit: release egress, record the verdict, gate the summary, then echo it.
# ---------------------------------------------------------------------------

finish() {
  local gate_rc=0 retry=0
  FINAL_RC="$1"
  release_egress
  if [[ -n "${WORK}" ]]; then rm -rf "${WORK}"; fi
  note "verdict: rc ${FINAL_RC}${GATE_REASON:+ — ${GATE_REASON}}"
  mkdir -p "$(dirname "${REPORT}")"
  logscan_gate host "${NEEDLE_DIR}" -- --sink diag=/tmp/launch-gate-ios/launch-gate-summary.log --report "${REPORT}" || gate_rc=$?
  if (( gate_rc == 1 )); then
    FINAL_RC=1
    GATE_REASON="the log-privacy gate found a leak in the summary and deleted it unread"
  elif (( gate_rc != 0 )); then
    rm -f "${SUMMARY_LOG}"
    if (( FINAL_RC == 0 || FINAL_RC == 5 )); then FINAL_RC=3; fi
    GATE_REASON="the log-privacy gate could not vouch for the summary (rc ${gate_rc}); it was deleted unread"
  elif (( FINAL_RC == 3 && ! TEST_STARTED )); then
    retry=1
  fi
  printf 'rc=%s retry=%s\n' "${FINAL_RC}" "${retry}" >"${STATE_DIR}/verdict"
  if (( gate_rc == 0 )); then cat "${SUMMARY_LOG}"; fi
  case "${FINAL_RC}" in
    0) ;;
    5) echo "::notice::iOS launch gate: the fresh legs passed; no iOS predecessor build to upgrade from (expected until a release carries ${ASSET_ZIP})" ;;
    *) echo "::error::iOS launch gate failed (rc ${FINAL_RC}): ${GATE_REASON:-see the summary above}" >&2 ;;
  esac
}

on_exit() {
  finish "$?"
  exit "${FINAL_RC}"
}

main() {
  if [[ $# -ne 3 ]]; then
    echo "usage: $0 <simulator-udid> <candidate Runner.app> <.xctestrun> | --release-egress | --self-test" >&2
    return 2
  fi
  UDID="$1" CANDIDATE="${2%/}" XCTESTRUN="$3"
  [[ -f "${XCTESTRUN}" ]] || { echo "ERROR: no .xctestrun at the given path" >&2; return 2; }

  mkdir -p "${STATE_DIR}"
  chmod 0700 "${STATE_DIR}"
  # The retry gate: a second attempt runs only after an infrastructure failure
  # in which no test case started, so no assertion is ever re-rolled.
  if [[ -f "${STATE_DIR}/verdict" ]]; then
    local prev
    prev="$(cat "${STATE_DIR}/verdict")"
    if [[ "${prev}" != *"retry=1"* ]]; then
      echo "iOS launch gate: refusing another attempt; the previous one ended '${prev}', not an infrastructure failure before any test case started" >&2
      prev="${prev#rc=}"
      return "${prev%% *}"
    fi
    echo "iOS launch gate: attempt after an infrastructure failure in which no test case started"
    rm -f "${STATE_DIR}/verdict"
  fi

  mkdir -p "${OUT_DIR}"
  : >"${SUMMARY_LOG}"
  WORK="$(mktemp -d)"
  chmod 0700 "${WORK}"
  trap on_exit EXIT
  trap 'exit 3' TERM INT

  simulator_app_ok "${CANDIDATE}" \
    || { GATE_REASON="the candidate is not a simulator build of ${BUNDLE_ID}"; return 2; }
  local booted
  booted="$(xcrun simctl list devices --json 2>/dev/null | python3 -I -c '
import json, sys
for devs in json.load(sys.stdin)["devices"].values():
    for d in devs:
        if d.get("udid") == sys.argv[1]:
            print(d.get("state", ""))
' "${UDID}")" || booted=""
  [[ "${booted}" == Booted ]] || { GATE_REASON="the simulator is not booted"; return 3; }
  load_env "${REPO_ROOT}/haven/lib/l10n/app_en.arb" \
    || { GATE_REASON="the candidate's ARB lacks a label the journey needs: update the gate with the product"; return 1; }
  CAND_ENV=("${LOADED_ENV[@]}")

  local prev_rc=0
  resolve_previous || prev_rc=$?
  if (( prev_rc == 2 || prev_rc == 3 )); then return "${prev_rc}"; fi

  block_egress || return $?

  local rc=0
  leg_fresh || rc=$?
  (( rc == 0 )) || return "${rc}"
  if (( prev_rc == 0 )); then
    leg_upgrade || rc=$?
    (( rc == 0 )) || return "${rc}"
  fi
  # A pass, or rc 4/5, is offline only if the block held to the end.
  egress_still_blocked || return 3
  return "${prev_rc}"
}

# ---------------------------------------------------------------------------
# --self-test: every external tool is a stub over a fake simulator; the
# xcodebuild stub plays the transcript each fixture asks for.
# ---------------------------------------------------------------------------
run_self_test() {
  local tmp ran=0 fail=0
  local -r SELF_TEST_FIXTURES=40
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}' '${OUT_DIR}'" RETURN
  mkdir -p "${tmp}/bin" "${tmp}/sim" "${tmp}/diag" "${tmp}/assets"

  # --- stubs -------------------------------------------------------------
  cat >"${tmp}/bin/sudo" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF
  cat >"${tmp}/bin/xcrun" <<'EOF'
#!/usr/bin/env bash
sim="${FAKE_SIM}"
[[ "$1" == simctl ]] || exit 9
shift
case "$1" in
  list) printf '{"devices":{"rt":[{"udid":"UDID-1","state":"%s"}]}}\n' "${FAKE_SIM_STATE:-Booted}" ;;
  uninstall) rm -rf "${sim}/app"; echo uninstall >>"${sim}/events" ;;
  install)
    [[ "${FAKE_INSTALL_FAIL:-}" != "$(cat "$3/which")" ]] || exit 1
    rm -rf "${sim}/app"; cp -R "$3" "${sim}/app"
    echo "install $(cat "$3/which")" >>"${sim}/events"
    [[ -z "${FAKE_INSTALL_SKEW:-}" ]] || echo skew >>"${sim}/app/Runner" ;;
  get_app_container) [[ -d "${sim}/app" ]] || exit 1; echo "${sim}/app" ;;
  privacy) echo "privacy $3 $4" >>"${sim}/events" ;;
  keychain) [[ "$3" == reset && -z "${FAKE_KEYCHAIN_FAIL:-}" ]] || exit 1; echo "keychain reset" >>"${sim}/events" ;;
  *) exit 9 ;;
esac
EOF
  cat >"${tmp}/bin/xcodebuild" <<'EOF'
#!/usr/bin/env bash
method=""
for a in "$@"; do [[ "${a}" == -only-testing:* ]] && method="${a##*/}"; done
env | grep '^TEST_RUNNER_GATE_' | sort >"${FAKE_SIM}/env.${method}"
which="$(cat "${FAKE_SIM}/app/which" 2>/dev/null)"
echo "xcodebuild ${method} on ${which}" >>"${FAKE_SIM}/events"
mode="${FAKE_XCB_MODE:-pass}"
[[ "${FAKE_XCB_ONLY:-${method}}" == "${method}" ]] || mode=pass
[[ "${method}" == testUpgradedCandidateRelaunch && -n "${FAKE_XCB_UPGRADE_MODE:-}" ]] && mode="${FAKE_XCB_UPGRADE_MODE}"
case "${mode}" in
  nostart)
    printf 'Testing failed:\n\tTest runner never began executing tests after launching.  Check device logs for (%s-EF0123456789)\n** TEST EXECUTE FAILED **\n' 'ABCDEF01-2345-6789-ABCD'
    exit 65 ;;
  hang) printf "Test Case '-[LaunchGateUITests.LaunchGateUITests %s]' started.\n" "${method}"; read -r _ <"${FAKE_SIM}/never" ;;
esac
printf "Test Suite 'All tests' started at 2026-11-14 10:00:00.000.\n"
printf "Test Case '-[LaunchGateUITests.LaunchGateUITests %s]' started.\n" "${method}"
printf '    t =     1.00s Tap "Get Started" Button\n'
case "${method}" in
  testFreshInstallThenColdRelaunch) echo "LAUNCH-GATE-TERMINAL SETUP_HELD" ;;
  testOnboardUpgradeSource)
    echo "LAUNCH-GATE-TERMINAL SETUP_HELD"
    echo "LAUNCH-GATE-NAME-DIGEST ${FAKE_DIGEST:-$(printf 'ab%.0s' {1..32})}" ;;
esac
if [[ "${mode}" == fail || "${mode}" == crash ]]; then
  if [[ "${mode}" == crash ]]; then
    { printf '{"bug_type":"309","app_name":"Runner","timestamp":"2026-11-14 10:00:01.00 +0000"}\n'
      printf '{"procPath":"/Users/runner/Library/Developer/CoreSimulator/Devices/%s-EF0123456789/data/Containers/Bundle/Application/X/Runner.app/Runner","pid":4242,"exception":{"type":"EXC_CRASH","signal":"SIGABRT"},"faultingThread":0,"threads":[{"frames":[{"imageIndex":0,"symbol":"__pthread_kill"},{"imageIndex":1,"symbol":"rust_panic"}]}],"usedImages":[{"name":"libsystem_kernel.dylib","path":"/usr/lib/system/libsystem_kernel.dylib"},{"path":"/Users/runner/x/rust_lib_haven.framework/rust_lib_haven"}]}\n' 'ABCDEF01-2345-6789-ABCD'
    } >"${FAKE_DIAG}/Runner-2026-11-14-100001.ips"
    printf '{"bug_type":"409"}\n{}\n' >"${FAKE_DIAG}/Runner-2026-11-14-100002.ips"
  fi
  printf "/Users/runner/work/Haven-App/tooling/e2e/ios-launch-gate/LaunchGateUITests/LaunchGateUITests.swift:120: error: -[LaunchGateUITests.LaunchGateUITests %s] : failed: caught error: \"the app showed onboardingCreateIdentityError at the onboarding journey\"\n" "${method}"
  printf "Test Case '-[LaunchGateUITests.LaunchGateUITests %s]' failed (3.000 seconds).\n" "${method}"
  printf '** TEST EXECUTE FAILED **\n'
  exit 65
fi
printf "Test Case '-[LaunchGateUITests.LaunchGateUITests %s]' passed (3.000 seconds).\n" "${method}"
printf '\t Executed 1 test, with 0 failures (0 unexpected) in 3.000 (3.001) seconds\n'
printf '** TEST EXECUTE SUCCEEDED **\n'
EOF
  cat >"${tmp}/bin/pfctl" <<'EOF'
#!/usr/bin/env bash
st="${FAKE_SIM}"
case "$*" in
  -E) echo "pf enabled" >&2; [[ -n "${FAKE_PF_NO_TOKEN:-}" ]] || echo "Token : 18446744073709551" >&2 ;;
  "-a com.apple/haven-launch-gate -f -") sed -E 's/port ([0-9]+)/port = \1/' >"${st}/pf.rules"; touch "${st}/blocked" ;;
  "-a com.apple/haven-launch-gate -sr") cat "${st}/pf.rules" ;;
  "-s info") echo "Status: Enabled for 0 days" ;;
  -sr) [[ -n "${FAKE_PF_NO_ANCHOR:-}" ]] || echo 'anchor "com.apple/*" all' ;;
  "-a com.apple/haven-launch-gate -F all") rm -f "${st}/blocked"; echo flushed >>"${st}/events" ;;
  "-X "*) echo "released $2" >>"${st}/events" ;;
  *) exit 9 ;;
esac
EOF
  # FAKE_CURL_LEAK=always connects every probe; =late every probe after the first.
  cat >"${tmp}/bin/curl" <<'EOF'
#!/usr/bin/env bash
echo probe >>"${FAKE_SIM}/probes"
case "${FAKE_CURL_LEAK:-}" in
  always) exit 0 ;;
  late) [[ "$(wc -l <"${FAKE_SIM}/probes")" -gt 1 ]] && exit 0 ;;
esac
[[ -e "${FAKE_SIM}/blocked" ]] && exit 7
exit 0
EOF
  cat >"${tmp}/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  api) cat "${FAKE_RELEASES}" ;;
  release)
    tag="$3" dir=""
    while (( $# )); do [[ "$1" == --dir ]] && dir="$2"; shift; done
    cp "${FAKE_ASSETS}/${tag}/"* "${dir}/" ;;
esac
EOF
  cat >"${tmp}/bin/git" <<'EOF'
#!/usr/bin/env bash
shift 2
case "$1" in
  fetch) exit 0 ;;
  show) cat "${FAKE_PREV_ARB}" ;;
esac
EOF
  cat >"${tmp}/bin/ditto" <<'EOF'
#!/usr/bin/env bash
python3 -I -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' "$3" "$4"
EOF
  chmod +x "${tmp}/bin/"*
  mkfifo "${tmp}/sim/never"

  # --- fixtures ----------------------------------------------------------
  _app() { # <dir> <which>
    mkdir -p "$1"
    printf '%s' "$2" >"$1/which"
    printf '%s-executable' "$2" >"$1/Runner"
    python3 -I -c '
import plistlib, sys
with open(sys.argv[1] + "/Info.plist", "wb") as f:
    plistlib.dump({"CFBundleIdentifier": "com.oblivioustech.haven", "CFBundleExecutable": "Runner", "DTPlatformName": "iphonesimulator"}, f)
' "$1"
  }
  _app "${tmp}/candidate/Runner.app" candidate
  : >"${tmp}/LaunchGate.xctestrun"
  _asset() { # <tag> [corrupt]
    local d="${tmp}/assets/$1"
    mkdir -p "${d}"
    _app "${tmp}/build-$1/Runner.app" "previous-$1"
    (cd "${tmp}/build-$1" && python3 -I -c '
import os, sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    for root, _, files in os.walk("Runner.app"):
        for name in files:
            z.write(os.path.join(root, name))
' "${d}/${ASSET_ZIP}")
    (cd "${d}" && shasum -a 256 "${ASSET_ZIP}" >"${ASSET_ZIP}.sha256")
    [[ -z "${2:-}" ]] || printf 'x' >>"${d}/${ASSET_ZIP}"
  }
  _asset v0.1.20
  _asset v0.1.21
  _asset v0.1.19 corrupt
  _releases() { # <json body>
    printf '%s' "$1" >"${tmp}/releases.json"
  }
  local z='[{"name":"app-ios-simulator.zip"},{"name":"app-ios-simulator.zip.sha256"}]'
  local standard='[
    {"tag_name":"v0.1.22","draft":false,"prerelease":true,"published_at":"2026-11-10T00:00:00Z","assets":'"${z}"'},
    {"tag_name":"v0.1.20","draft":false,"prerelease":false,"published_at":"2026-11-01T00:00:00Z","assets":'"${z}"'},
    {"tag_name":"v0.1.21","draft":false,"prerelease":false,"published_at":"2026-11-05T00:00:00Z","assets":'"${z}"'},
    {"tag_name":"v0.1.13","draft":false,"prerelease":false,"published_at":"2026-10-01T00:00:00Z","assets":[]}]'
  # v0.1.21 (ios) is out; v0.1.20 (android only) stays in.
  _yank() { printf '# <tag> <platform> <reason>\n%s\n' "$@" >"${tmp}/yanked.txt"; }
  _yank 'v0.1.21 ios crashed at every process start' 'v0.1.20 android crashed at every Android start'
  python3 -I -c '
import json, sys
arb = json.load(open(sys.argv[1], encoding="utf-8"))
arb.pop("onboardingFinishSetupError", None)
arb["onboardingWelcomeCta"] = "Begin (previous)"
json.dump(arb, open(sys.argv[2], "w", encoding="utf-8"))
' "${REPO_ROOT}/haven/lib/l10n/app_en.arb" "${tmp}/previous.arb"

  # --- the harness ---------------------------------------------------------
  # The gate runs for real with the scanner faked: the seal through the tree's
  # one fake haven-logscan, the scan through a fake scan-logs.sh that records
  # its argv, prints a marker (so a fixture sees what was echoed before it) and
  # contains a staged leak by deleting its sinks.
  cat >"${tmp}/bin/fake-scan-logs" <<'EOF2'
#!/usr/bin/env bash
printf '%s\n' "$@" >"${FAKE_SIM}/../gate.argv"
echo "FAKE-GATE-RAN"
if [[ "${FAKE_GATE_RC:-0}" == 1 ]]; then
  while (( $# )); do [[ "$1" == --sink ]] && rm -f "${2#*=}"; shift; done
fi
exit "${FAKE_GATE_RC:-0}"
EOF2
  chmod +x "${tmp}/bin/fake-scan-logs"
  _run() { # [env assignments...] — a first attempt; sets OUT and RC
    rm -rf "${tmp}/state"
    _attempt "$@"
  }
  _attempt() { # [env assignments...] — an attempt that keeps the state directory
    rm -rf "${tmp}/sim/app" "${tmp}/sim/blocked" "${tmp}/sim/probes" "${tmp}/sim/env."* "${tmp}/diag/"* "${tmp}/gate.argv" "${tmp}/seal.argv"
    : >"${tmp}/sim/events"
    RC=0
    OUT="$(env PATH="${tmp}/bin:${PATH}" FAKE_SIM="${tmp}/sim" FAKE_DIAG="${tmp}/diag" \
      FAKE_RELEASES="${tmp}/releases.json" FAKE_ASSETS="${tmp}/assets" FAKE_PREV_ARB="${tmp}/previous.arb" \
      HAVEN_LAUNCH_GATE_STATE_DIR="${tmp}/state" HAVEN_LAUNCH_GATE_DIAG_DIR="${tmp}/diag" \
      HAVEN_LAUNCH_GATE_YANKED="${tmp}/yanked.txt" \
      HAVEN_LAUNCH_GATE_TEST_SECS=3 HAVEN_LAUNCH_GATE_KILL_GRACE_SECS=1 HAVEN_LAUNCH_GATE_IPS_SETTLE_SECS=1 \
      HAVEN_LOGSCAN=true HAVEN_LOGSCAN_BIN="${LOGSCAN_FAKE_BIN}" SCAN_LOGS="${tmp}/bin/fake-scan-logs" \
      FAKE_SEAL_ARGV="${tmp}/seal.argv" GITHUB_RUN_ID=launch-gate-self-test GITHUB_RUN_ATTEMPT=1 \
      GITHUB_REPOSITORY=example/haven HAVEN_LAUNCH_GATE_CANDIDATE_TAG="${CAND_TAG:-}" \
      "$@" bash "${BASH_SOURCE[0]}" UDID-1 "${tmp}/candidate/Runner.app" "${tmp}/LaunchGate.xctestrun" 2>&1)" || RC=$?
  }
  _case() { # <label> <want rc> <ERE that OUT, events or the summary must hold>...
    local label="$1" want="$2" ok=1 re
    shift 2
    ran=$((ran + 1))
    [[ "${RC}" == "${want}" ]] || ok=0
    for re in "$@"; do
      { printf '%s\n' "${OUT}"; cat "${tmp}/sim/events"; } | grep -E -- "${re}" >/dev/null || { ok=0; echo "  missing: ${re}" >&2; }
    done
    if (( ok )); then printf '  PASS %s (rc=%s)\n' "${label}" "${RC}"
    else printf 'SELF-TEST FAIL: %s (want rc %s, got %s)\n%s\n' "${label}" "${want}" "${RC}" "${OUT}" >&2; fail=1; fi
  }
  _absent() { # <label> <fixed string> — the run's output, the echoed summary included, never holds it
    ran=$((ran + 1))
    if grep -F -- "$2" >/dev/null <<<"${OUT}"; then
      printf 'SELF-TEST FAIL: %s\n' "$1" >&2; fail=1
    else printf '  PASS %s\n' "$1"; fi
  }

  # (1) The whole gate, upgrading from the newest eligible release: the
  #     prerelease and the yanked tag are skipped, the candidate is installed
  #     over the source, and each build is driven in its own labels.
  _releases "${standard}"
  _run
  _case "fresh, relaunch and upgrade pass" 0 \
    '^leg fresh: PASS \(terminal SETUP_HELD' '^upgrade: source v0.1.20$' \
    '^leg upgrade: PASS \(over v0.1.20' 'install previous-v0.1.20' \
    'xcodebuild testOnboardUpgradeSource on previous-v0.1.20' \
    'xcodebuild testUpgradedCandidateRelaunch on candidate' 'privacy grant location' \
    '^egress: blocked \(pf\)' 'released 18446744073709551'
  ran=$((ran + 1))
  if [[ "$(grep -c '^keychain reset$' "${tmp}/sim/events")" == 2 ]]; then
    printf '  PASS each leg starts from a reset keychain\n'
  else
    printf 'SELF-TEST FAIL: each leg starts from a reset keychain\n' >&2; fail=1
  fi
  ran=$((ran + 1))
  if grep -q 'GATE_WELCOME_CTA=Begin (previous)' "${tmp}/sim/env.testOnboardUpgradeSource" \
     && ! grep -q 'GATE_SETUP_HELD' "${tmp}/sim/env.testOnboardUpgradeSource" \
     && grep -q 'GATE_WELCOME_CTA=Get Started' "${tmp}/sim/env.testUpgradedCandidateRelaunch" \
     && grep -q 'GATE_EXPECT_TERMINAL=SETUP_HELD' "${tmp}/sim/env.testUpgradedCandidateRelaunch" \
     && grep -qE 'GATE_EXPECT_NAME_DIGEST=(ab){32}$' "${tmp}/sim/env.testUpgradedCandidateRelaunch"; then
    printf '  PASS each build is driven in its own ARB labels, the digest carried across\n'
  else
    printf 'SELF-TEST FAIL: the upgrade legs were not handed the right labels\n' >&2; fail=1
  fi

  # (2) THE PIN (check_logscan_wired_everywhere.sh RUNNER_PINS).
  ran=$((ran + 1))
  if [[ "$(printf '%s\n' "${OUT}" | grep -nE '^(FAKE-GATE-RAN|leg fresh: )' | head -n 1)" == *FAKE-GATE-RAN* ]] \
     && grep -qx -- 'diag=/tmp/launch-gate-ios/launch-gate-summary.log' "${tmp}/gate.argv" \
     && grep -qx -- 'none' "${tmp}/seal.argv"; then
    printf '  PASS %s\n' "the summary is echoed only after the log-privacy gate"
  else
    printf 'SELF-TEST FAIL: %s\n' "the summary is echoed only after the log-privacy gate" >&2; fail=1
  fi

  # (3) What the summary never carries: the salted digest, a transcript's
  #     activity lines, absolute paths, the simulator's UUID.
  _absent "the salted digest never reaches the summary" "$(printf 'ab%.0s' {1..32})"
  _absent "XCTest activity lines are not kept" 'Tap "Get Started"'
  _absent "the suite's absolute start time is not kept" '2026-11-14 10:00:00'

  # (4) A leak the gate contained: nothing is echoed.
  _run FAKE_GATE_RC=1
  _case "a contained leak fails the lane and echoes no summary" 1 'found a leak in the summary'
  _absent "a contained summary is not printed" 'leg fresh: PASS'
  _run FAKE_GATE_RC=3
  _case "a gate that cannot vouch fails the lane" 3 'could not vouch for the summary \(rc 3\)'
  _absent "an unvouched summary is not printed" 'leg fresh: PASS'
  ran=$((ran + 1))
  if [[ -e "${SUMMARY_LOG}" ]]; then
    printf 'SELF-TEST FAIL: an unvouched summary is deleted, not left for the upload\n' >&2; fail=1
  else printf '  PASS an unvouched summary is deleted, not left for the upload\n'; fi

  # (5) The candidate fails the journey: product, attributed, no retry.
  _run FAKE_XCB_MODE=fail FAKE_XCB_ONLY=testFreshInstallThenColdRelaunch
  _case "a failed fresh leg is a product failure" 1 \
    '\| LaunchGateUITests.swift:120: error: .*onboardingCreateIdentityError' \
    '::error::iOS launch gate failed \(rc 1\): the candidate failed the fresh install' 'rc=1 retry=0|verdict: rc 1'
  _absent "a failure line keeps no directory" '/Users/runner/work'

  # (6) A crash: the report's exception and frames, nothing that names the run.
  _run FAKE_XCB_MODE=crash FAKE_XCB_ONLY=testFreshInstallThenColdRelaunch
  _case "a crash is summarised from its report" 1 '^leg fresh: the app crashed$' \
    '^crash report 1: EXC_CRASH SIGABRT$' '#00 libsystem_kernel.dylib __pthread_kill' '#01 rust_lib_haven rust_panic'
  _absent "a crash summary carries no device UUID" 'ABCDEF01-2345-6789-ABCD-''EF0123456789'

  # (7) The runner never started: infrastructure, and a second attempt is
  #     admitted; a product failure admits none.
  _run FAKE_XCB_MODE=nostart
  _case "a test that never started is infrastructure" 3 '^leg fresh: no test case started$' '\| Testing failed:' '\| .*Test runner never began'
  _absent "an infrastructure line keeps no UUID" 'ABCDEF01-2345'
  _attempt
  _case "a second attempt runs after no test started" 0 'attempt after an infrastructure failure' '^leg upgrade: PASS'
  _run FAKE_XCB_MODE=fail FAKE_XCB_ONLY=testFreshInstallThenColdRelaunch
  _attempt
  _case "a second attempt after a product failure is refused" 1 'refusing another attempt'

  # (8) A test that hangs is stopped by the bound and is a product failure.
  _run FAKE_XCB_MODE=hang FAKE_XCB_ONLY=testFreshInstallThenColdRelaunch
  _case "a hung test is stopped at its bound" 1 'xcodebuild outlived its 3 s bound'

  # (9) No predecessor asset: the fresh legs ran and the outcome is named.
  _releases '[{"tag_name":"v0.1.20","draft":false,"prerelease":false,"published_at":"2026-11-01T00:00:00Z","assets":[]}]'
  _run
  _case "no predecessor asset is rc 5 after the fresh legs" 5 '^leg fresh: PASS' \
    'no iOS predecessor build \(no eligible release carries app-ios-simulator.zip and its checksum\)' '::notice::iOS launch gate'

  # (10) The candidate's own tag and later versions are never the source.
  _releases "${standard}"
  CAND_TAG=v0.1.20 _run
  _case "a release run never upgrades from itself" 5 'no iOS predecessor build'

  # (10b) The yanked list: ios and all exclude, android does not; a line
  #       without a platform or a reason, or no list at all, is refused before
  #       anything is installed.
  _yank 'v0.1.21 crashed at every process start'
  _run
  _case "a yanked line without a platform is refused" 2 "not '<vMAJOR.MINOR.PATCH> <android|ios|all> <reason>'"
  _yank 'v0.1.21 ios'
  _run
  _case "a yanked line without a reason is refused" 2 "not '<vMAJOR.MINOR.PATCH> <android|ios|all> <reason>'"
  _yank 'v0.1.21 all crashed everywhere'
  _run
  _case "a release yanked for all is skipped" 0 '^upgrade: source v0.1.20$'
  _yank 'v0.1.21 android crashed on Android only'
  _run
  _case "a release yanked for android only is still the iOS source" 0 '^upgrade: source v0.1.21$' '^leg upgrade: PASS \(over v0.1.21'
  _yank 'v0.1.21 ios crashed at every process start' 'v0.1.20 android crashed at every Android start'
  rm -f "${tmp}/yanked.txt"
  _run
  _case "a missing yanked list is refused" 2 'yanked-release list is missing'
  _yank 'v0.1.21 ios crashed at every process start' 'v0.1.20 android crashed at every Android start'

  # (11) A download that does not match its checksum is infrastructure; a
  #      build that fails its own onboarding is rc 4 — after the candidate's
  #      fresh legs passed.
  _releases '[{"tag_name":"v0.1.19","draft":false,"prerelease":false,"published_at":"2026-11-01T00:00:00Z","assets":'"${z}"'}]'
  _run
  _case "a corrupt predecessor download is infrastructure" 3 'does not match its checksum as downloaded'
  _releases "${standard}"
  # (11b) The source is the newest eligible release CARRYING the pair: a newer
  #       one without it, or with half of it, is passed over, not rc 5.
  _yank 'v0.1.13 ios placeholder so the list is not empty'
  _releases '[{"tag_name":"v0.1.22","draft":false,"prerelease":false,"published_at":"2026-11-09T00:00:00Z","assets":[]},
    {"tag_name":"v0.1.21","draft":false,"prerelease":false,"published_at":"2026-11-05T00:00:00Z","assets":[{"name":"app-ios-simulator.zip"}]},
    {"tag_name":"v0.1.20","draft":false,"prerelease":false,"published_at":"2026-11-01T00:00:00Z","assets":'"${z}"'}]'
  _run
  _case "a newer release without the asset pair is passed over" 0 '^upgrade: source v0.1.20$' '^leg upgrade: PASS \(over v0.1.20'
  _yank 'v0.1.21 ios crashed at every process start' 'v0.1.20 android crashed at every Android start'
  _releases "${standard}"
  _run FAKE_XCB_MODE=fail FAKE_XCB_ONLY=testOnboardUpgradeSource
  _case "a predecessor that cannot onboard is rc 4" 4 'did not onboard offline: it cannot be the upgrade source'

  # (12) The upgrade must put the candidate's bytes on the simulator.
  _run FAKE_INSTALL_SKEW=1
  _case "an upgrade that does not run the candidate fails" 1 'does not run the candidate'\''s executable'

  # (13) The upgraded candidate fails: product.
  _run FAKE_XCB_UPGRADE_MODE=fail
  _case "a candidate failing after the upgrade is a product failure" 1 'failed after the upgrade from v0.1.20'

  # (13b) Infrastructure, not the source's fault: the simulator refuses the
  #       source's install, or the keychain cannot be reset.
  _run FAKE_INSTALL_FAIL=previous-v0.1.20
  _case "a source the simulator will not install is infrastructure" 3 "refused to install v0.1.20's build"
  _run FAKE_KEYCHAIN_FAIL=1
  _case "a keychain that cannot be reset is infrastructure" 3 'keychain could not be reset'

  # (14) Egress: no token, an anchor pf never evaluates, a probe that
  #      connects — each is infrastructure, and the block is released.
  _run FAKE_PF_NO_TOKEN=1
  _case "pf without an enable token is infrastructure" 3 'no enable token'
  _run FAKE_PF_NO_ANCHOR=1
  _case "an anchor the main ruleset skips is infrastructure" 3 'does not evaluate com.apple'
  _run FAKE_CURL_LEAK=always
  _case "a probe that connects is infrastructure, and pf is released" 3 'egress is not blocked' '^flushed$' 'released 18446744073709551'
  _releases '[{"tag_name":"v0.1.20","draft":false,"prerelease":false,"published_at":"2026-11-01T00:00:00Z","assets":[]}]'
  _run FAKE_CURL_LEAK=late
  _case "a block that gave way during the legs fails even with no predecessor" 3 '^leg fresh: PASS' 'egress is not blocked'
  _releases "${standard}"

  # (16) The workflow's belt: --release-egress undoes what a killed run left.
  mkdir -p "${tmp}/state"
  printf '4242\n' >"${tmp}/state/pf.token"
  : >"${tmp}/sim/events"
  RC=0
  OUT="$(env PATH="${tmp}/bin:${PATH}" FAKE_SIM="${tmp}/sim" HAVEN_LAUNCH_GATE_STATE_DIR="${tmp}/state" \
    bash "${BASH_SOURCE[0]}" --release-egress 2>&1)" || RC=$?
  _case "--release-egress releases a block a killed run left" 0 '^flushed$' '^released 4242$'

  if (( ran != SELF_TEST_FIXTURES )); then
    printf 'SELF-TEST FAIL: ran %d fixtures, pinned %d\n' "${ran}" "${SELF_TEST_FIXTURES}" >&2
    fail=1
  fi
  if (( fail )); then echo "run-launch-gate-ios.sh --self-test: FAILED" >&2; return 1; fi
  echo "run-launch-gate-ios.sh --self-test: all ${ran} fixtures passed"
}

case "${1:-}" in
  --self-test) run_self_test ;;
  --release-egress) release_egress ;;
  *) main "$@" ;;
esac
