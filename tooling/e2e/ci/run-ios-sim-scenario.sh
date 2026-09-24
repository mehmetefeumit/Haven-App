#!/usr/bin/env bash
#
# iOS-simulator E2E scenario runner (Tier 1).
#
# Mirrors run-single-avd-scenario.sh, but for an iOS simulator. A real
# iOS-Alice UI runs the consolidated `e2e_combined.dart` flow on the booted
# simulator while Bob/Carol/Dave participate as in-process `SyntheticUser`
# FFI peers. All actors coordinate through a host-native Nostr relay at
# `ws://localhost:7777` — the macOS runner has no Linux Docker daemon, so the
# Android lane's `strfry` container cannot run there (see
# tooling/e2e/local-relay/).
#
# Differences from the Android lane:
#   - No `adb install` / `pm grant`: `flutter test -d <udid>` builds, installs,
#     runs, and reports in one step.
#   - No native location-permission grant: the scenario overrides
#     `locationServiceProvider` with `FakeLocationService` (reports permission
#     `always`), so CLLocationManager is never touched.
#   - The simulator reaches the host relay at `localhost` (it shares the host
#     network namespace), NOT the Android `10.0.2.2` alias.
#
# `flutter test` builds in DEBUG, so the `#[cfg(debug_assertions)]` Rust test
# hooks (in-memory keyring, ws:// loopback allow-list, relay override) are
# active — exactly as the Android lane relies on.
#
# Usage:
#   run-ios-sim-scenario.sh <scenario-file> <simulator-udid>
#
# Environment:
#   HAVEN_E2E_RELAY  WebSocket URL of the host relay (default
#                    ws://localhost:7777). Compiled into the test build via
#                    --dart-define so it must match the running relay.
#   HAVEN_LIVE_SYNC  'true' or 'false'. MANDATORY — set per STEP by the caller
#                    (S1). There is deliberately no default; see below.
#   HAVEN_E2E_BLOSSOM_URL  Base URL of the host-native Blossom server, used
#                    ONLY by the public-profile lane (e2e-profile.yml). When
#                    set, it is threaded into the build as a --dart-define;
#                    when UNSET (every other lane), no such define is added, so
#                    those lanes' compiled builds stay byte-identical
#                    (backward-compatible).
#   HAVEN_E2E_PROFILE_RELAY   ws:// URL of the FIRST profile-plane relay, and
#   HAVEN_E2E_PROFILE_RELAYS  the comma-separated URL list of the whole
#                    profile-plane pool (tooling/e2e/ci/start-profile-relays.sh).
#                    Also public-profile-lane-only: kind-0 traffic must ride
#                    relays DISJOINT from the circle relay in HAVEN_E2E_RELAY.
#                    Same opt-in shape as HAVEN_E2E_BLOSSOM_URL — forwarded only
#                    when set, so no other lane's build changes.
#   HAVEN_BGP_EXPECT_TIER  The CoreLocation tier the iOS background-publish
#                    lane's drive PINS ('whenInUse' or 'always'), set only by
#                    tooling/e2e/ci/run-ios-bg-publish.sh, which derives it
#                    from the same HAVEN_BGP_AUTH_TIER that chose the
#                    `simctl privacy grant`. Same opt-in shape as the blocks
#                    above: forwarded only when set, so no other lane's
#                    compiled defines change.
#   HAVEN_WIRE_SENTINEL  The one-per-job wire-journal sentinel token, set only
#                    by a lane that runs the recording proxy in front of its
#                    relay (e2e-ios.yml). Threaded into the build as a
#                    --dart-define so TestRelay.emitWireJournalSentinel() emits
#                    the SAME string the host oracle anchors on. Same opt-in
#                    shape again: unset elsewhere, so no other lane's compiled
#                    defines change.
#   HAVEN_LOGSCAN    'true' switches the post-drive gate to the identifier
#                    scanner (tooling/e2e/ci/logscan-gate.sh); unset, the gate
#                    is the key-material floor alone.
#   HAVEN_LOGSCAN_PROFILE  The seal profile, declared per JOB: 'proxy' where
#                    the recording wire proxy is in front of the relay (its
#                    declaration sidecars are sealed), 'host' where it is not
#                    (the host-knowable needles alone). Any other value is
#                    refused before the build. Unset, it is inferred the way
#                    run-single-avd-scenario.sh infers it: 'proxy' when the
#                    workflow exported WIRE_UPSTREAM or handed this drive a
#                    HAVEN_WIRE_SENTINEL — both exist only where the recorder
#                    runs — else 'host'. A job that drops its env therefore
#                    cannot fall to the weaker profile by default: the proxy
#                    lane's own exports pick `proxy` for it.
#   HAVEN_LOGSCAN_HOST_COORDINATE  'lat,lon' a lane seeded into the simulator
#                    (run-b4-ios-real-gps.sh), declared at seal time beside the
#                    host needles. Never echoed.
#   HAVEN_LOGSCAN_DRIVE_FLOOR  This lane's `drive` line floor, sealed as
#                    `--floor drive=<n>`. The policy default (100) is the long
#                    core-flow drive's, which a single-scenario b-lane would
#                    read as truncated on a fully passing run, so each such lane
#                    states its own. It must be DERIVED from the host skeleton
#                    below, never measured from a transcript's length: a number
#                    above IOS_HOST_SKELETON_LINES is refused at script start,
#                    before anything can have been captured — never on the gate
#                    path, where a refusal would leave a transcript unscanned.
#                    "A test ran" is the scanner's proof_of_run, not this
#                    number. Unset keeps the policy's.
#
# Retry discipline (CI_HARDENING_BACKLOG.md A6):
#   Both iOS callers wrap this script in `nick-fields/retry@v3` with no
#   `retry_on` filter, so the action retries EVERY non-zero exit — a genuine
#   assertion failure exactly like a simulator that never launched. Measured
#   across 156 attempts, 19 genuine test failures were retried and the only
#   real infrastructure flake was a post-build, pre-first-test launch/attach
#   stall. This script now (a) runs a first-test watchdog that kills such a
#   stall on a deadline SHORTER than the attempt timeout, so it is attributed
#   instead of being an anonymous "Timeout of 1800000ms hit", and (b) records a
#   verdict that makes the NEXT attempt refuse to run unless that one signature
#   was proven. See tooling/e2e/ci/ios-flake-lib.sh.
#
# Usage (self-test):
#   run-ios-sim-scenario.sh --self-test   # hermetic; no simulator, no Xcode
#
# Side effects:
#   - Writes /tmp/flutter-ios-test.log (uploaded as a CI failure artifact).
#   - Writes /tmp/ios-logscan/sim.ndjson (the scanner's findings report; never
#     uploaded).
#   - Writes /tmp/haven-ios-retry-verdict-<scenario-slug> (cross-attempt state).
#
# Exit status: the `flutter test` exit code (0 = scenario passed).

set -euo pipefail

# Sourced BEFORE the --self-test dispatch below so the self-test exercises a
# runner wired exactly like the real one (the same discipline
# run-single-avd-scenario.sh applies to drive-log-lib.sh).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
# shellcheck source=tooling/e2e/ci/ios-flake-lib.sh
source "${SCRIPT_DIR}/ios-flake-lib.sh"
# The log-privacy gate: the key-material floor AND the identifier scanner, one
# call, one verdict (Security Rules 6 and 15).
# shellcheck source=tooling/e2e/ci/logscan-gate.sh
source "${SCRIPT_DIR}/logscan-gate.sh"

# How long after the Xcode build finishes the on-device suite has to START A
# TEST before the watchdog calls it a launch/attach stall. Measured over 164 real
# attempts, build-done → first TEST-START line is 32s median, 53s p90, 94s max,
# so 300s is >3x the worst observed and cannot trip a healthy (if slow) launch.
#
# The first REPORTER line is a different thing and comes much earlier: the
# expanded reporter prints `00:00 +0: loading <suite>.dart` while the suite is
# being loaded, i.e. BEFORE the build (measured 13m42s ahead of it in green run
# 35664400984). Counting that as the suite speaking is what left this watchdog
# unable to fire at all until CI run 35690725254 exposed it; the predicate now
# reads only the suffix after the build marker, and a suite load is not a start
# (ios-flake-lib.sh). It must also stay well UNDER the caller's per-attempt
# `timeout_minutes` (20-45 min), because a stall that the OUTER timeout kills
# first is never classified and therefore — by design — never retried.
#
# Those numbers describe "until the suite STARTS", and they only hold because
# spawn_ios_test pins `--reporter expanded`. Under the reporter flutter_tools
# picks by default in CI (`github`), the first reporter line does not appear
# until the first test ENDS, and this deadline silently becomes a cap on TEST
# RUNTIME — which is not a property this watchdog is allowed to have, and is
# how CI run 32622119290 killed a healthy 400-second lane twice. Read the two
# together: the deadline is safe because the signal is a start signal.
readonly FIRST_TEST_WATCHDOG_SECS="${HAVEN_IOS_FIRST_TEST_WATCHDOG_SECS:-300}"
readonly WATCHDOG_POLL_SECS="${HAVEN_IOS_WATCHDOG_POLL_SECS:-5}"
# Validate as positive integers (mirrors run-single-avd-scenario.sh). A garbage
# value would make the watchdog loop misbehave rather than fail loudly.
if ! [[ "${FIRST_TEST_WATCHDOG_SECS}" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: HAVEN_IOS_FIRST_TEST_WATCHDOG_SECS must be a positive integer," \
       "got '${FIRST_TEST_WATCHDOG_SECS}'" >&2
  exit 2
fi
if ! [[ "${WATCHDOG_POLL_SECS}" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: HAVEN_IOS_WATCHDOG_POLL_SECS must be a positive integer, got" \
       "'${WATCHDOG_POLL_SECS}'" >&2
  exit 2
fi

# spawn_ios_test <log> — backgrounds ONE `flutter test`, redirecting its output
# to <log>. Factored out (a) so the whole invocation lives in one place and
# (b) as the seam the --self-test at the foot of this file overrides with a
# synthetic "build then stall" / "build then run" / "fail fast" process, which is
# how the watchdog's control flow is proven without a simulator.
#
# `$!` set by the `&` here stays readable by the caller after the function
# returns (bash keeps the last-background PID shell-global).
#
# Output goes through a plain REDIRECT, not `| tee`: when the watchdog kills a
# stalled `flutter test`, its orphaned children keep the pipe's write end open,
# so `tee` would block forever on EOF and defeat the very bound we rely on —
# the failure run-single-avd-scenario.sh documents at length (run 28056995601,
# a ~47-min step hang). A follower streams the log to the console instead.
#
# APPEND (`>>`), not truncate (`>`). The caller already truncates the log once,
# so append changes nothing about what the file contains — but it changes WHERE
# the child writes. With `>` the child holds its own file offset, so anything it
# emits after the watchdog has appended lands ON TOP of the watchdog's bytes
# instead of after them. In CI run 30964250098 `flutter test`'s SIGTERM handler
# printed exactly 22 bytes over the 22-byte head of the stall marker and cost the
# lane its sanctioned retry. O_APPEND makes every write go to EOF, so the two
# writers can no longer collide.
spawn_ios_test() {
  # The `${EXTRA_DART_DEFINES[@]+"..."}` form is the nounset-safe idiom for
  # expanding a possibly-empty array under `set -u` on bash 3.2 (the macOS
  # runner default): it expands to the quoted elements when set and to nothing
  # when the array is empty, so a lane that did not set HAVEN_E2E_BLOSSOM_URL
  # adds no arg.
  #
  # `--reporter expanded` is LOAD-BEARING, not a formatting preference.
  # Fixture (W8) in run_self_test below fails if it is removed.
  #
  # Left to itself `flutter test` picks the `github` reporter whenever
  # GITHUB_ACTIONS is set, and that reporter emits NOTHING for a test until the
  # test FINISHES — it buffers the test's own output and then flushes it inside
  # a `::group::✅ <name>` block. The watchdog below therefore stopped measuring
  # "how long until the suite launched" and started measuring "how long until
  # the FIRST TEST COMPLETED", which for a lane whose single test legitimately
  # waits ~400 s (ios_bg_publish_test.dart: two jittered 72-168 s publish ticks)
  # is a deadline it can never meet. CI run 32622119290 is that: a healthy suite
  # that had already armed the session, been backgrounded by the OS and started
  # its publish wait was killed at 300 s, misfiled as a launch/attach stall, and
  # retried into the identical kill.
  #
  # `expanded` writes a line per event, including `00:00 +0: <name>` the moment
  # a test STARTS — which is exactly the event the watchdog needs, and is what
  # IOS_TEST_STARTED_RE matches once the reporter's own pre-build `loading
  # <suite>.dart` line is subtracted from it. `flutter test
  # --help` describes it as preferred "when logging to a file or in continuous
  # integration", which is both of the things this is. The cost is GitHub's
  # collapsible groups; the gain is that the log streams live through the
  # `tail -f` follower instead of arriving in one lump at the end.
  flutter test "${SCENARIO_FILE}" \
    -d "${SIM_UDID}" \
    --reporter expanded \
    --dart-define=HAVEN_E2E_RELAY="${RELAY_URL}" \
    --dart-define=HAVEN_LIVE_SYNC="${LIVE_SYNC}" \
    --dart-define=HAVEN_E2E_NO_BACKGROUND="${E2E_NO_BACKGROUND}" \
    ${EXTRA_DART_DEFINES[@]+"${EXTRA_DART_DEFINES[@]}"} \
    >> "$1" 2>&1 &
}

# run_ios_test_with_watchdog <log> — runs one `flutter test` under a first-test
# watchdog. Sets `ios_test_rc` for the caller.
#
# The watchdog arms only once `Xcode build done.` appears, and from that instant
# the suite has FIRST_TEST_WATCHDOG_SECS to START A TEST — reporter output from
# BEFORE the build (the suite-load line) does not count, which is the whole
# reason it can fire at all. It cannot mask a real failure: it fires only while
# no test has provably started, and it re-checks both that and the process at
# the deadline so a suite that started in the final poll window is never killed
# as a stall.
#
# It deliberately does NOT bound the BUILD. A build legitimately takes 7-11 min
# (measured) and a cold cache can take longer, and a hung or failed build is
# deterministic — retrying it hides it for another ten minutes. So a build that
# never completes runs into the caller's attempt timeout with the verdict still
# `unproven`, which the gate refuses to retry.
run_ios_test_with_watchdog() {
  local log="$1"
  ios_test_rc=0
  : > "${log}"
  # A previous attempt's stall verdict must never be inherited: that would be
  # the blanket retry restored by the back door.
  ios_clear_stall_evidence "${log}"

  spawn_ios_test "${log}"
  local test_pid=$!

  # Console follower. `flutter test`'s output no longer reaches the step log
  # directly (see spawn_ios_test), and a 45-minute step that prints nothing
  # until it ends is a real diagnosis cost. `tail -f` is a plain reader, so
  # unlike `tee` it holds no write end of anything the watchdog might kill.
  tail -f -n +1 "${log}" 2>/dev/null &
  local follower_pid=$!

  (
    local armed=0 waited=0
    while :; do
      sleep "${WATCHDOG_POLL_SECS}"
      # Process gone (connected and ran, or failed fast) — stand down.
      kill -0 "${test_pid}" 2>/dev/null || exit 0
      if (( armed == 0 )); then
        if LC_ALL=C grep -aqF -- "${IOS_BUILD_DONE_MARKER}" "${log}" 2>/dev/null; then
          armed=1
        fi
        continue
      fi
      # A test started — the suite is running; the caller's attempt timeout
      # governs from here, exactly as a post-connect hang does on Android.
      # (`if …; then exit 0; fi` rather than `pred && exit 0` for the same
      # reason run-single-avd-scenario.sh's watchdog uses it: the intent is a
      # branch, not a side effect. Both are errexit-safe — bash exempts every
      # command in an AND-list but the last — so this is style, not a fix.)
      if ios_log_test_started "${log}"; then exit 0; fi
      waited=$(( waited + WATCHDOG_POLL_SECS ))
      (( waited >= FIRST_TEST_WATCHDOG_SECS )) || continue
      # Deadline. Re-check both facts so a run that just started, or just
      # exited in the last few microseconds, is never mislabelled a stall —
      # the boundary false-positive guard, as on Android.
      #
      # This start check and the one above are deliberately REDUNDANT: they
      # run in the same loop iteration, so removing either alone changes
      # nothing observable and no hermetic fixture can separate them (the
      # window between them is microseconds). Removing BOTH is a real defect —
      # the watchdog would then kill running suites — and that IS covered:
      # fixture W2 fails the moment neither check remains.
      kill -0 "${test_pid}" 2>/dev/null || exit 0
      if ios_log_test_started "${log}"; then exit 0; fi
      ios_stall_marker_line "${FIRST_TEST_WATCHDOG_SECS}" >> "${log}"
      # Capture the verdict OUT OF BAND, before signalling. Both land after the
      # two re-checks above, so they exist only when the watchdog has positively
      # observed a live process with no test started — a suite that failed on
      # its own never reaches here. The snapshot is the evidence the watchdog
      # actually acted on; the flag is the one artefact the dying child has no
      # descriptor to and therefore cannot corrupt.
      cp "${log}" "$(ios_prekill_log_path "${log}")" 2>/dev/null || true
      : > "$(ios_stall_flag_path "${log}")"
      kill -TERM "${test_pid}" 2>/dev/null || true
      sleep 5
      kill -KILL "${test_pid}" 2>/dev/null || true
      exit 0
    done
  ) &
  local watchdog_pid=$!

  wait "${test_pid}" 2>/dev/null || ios_test_rc=$?
  kill "${watchdog_pid}" 2>/dev/null || true
  wait "${watchdog_pid}" 2>/dev/null || true
  # Give the follower a moment to drain the last writes (including a marker the
  # watchdog appended) before it is stopped.
  sleep 1
  kill "${follower_pid}" 2>/dev/null || true
  wait "${follower_pid}" 2>/dev/null || true
}

# scan_log_or_contain <log> — the log-privacy gate over the transcript the
# workflows upload `if: failure()`, through logscan-gate.sh: with
# HAVEN_LOGSCAN=true it seals the run's needle manifest under the job's
# profile (HAVEN_LOGSCAN_PROFILE, or inferred from the recorder's own exports
# — see the header) and runs the key-material floor AND the identifier
# scanner; otherwise the floor alone. A leak (rc 1) fails the lane, and that
# failure is what triggers the upload — so the gate REMOVES the log before
# returning. A lane that seeded a position (B4) hands it in through
# HAVEN_LOGSCAN_HOST_COORDINATE so the seal declares it beside the host
# needles; that value is never echoed here. The transcript is one file, so
# there is no final-attempt slice to narrow the plants to.
#
# Endpoint exemptions, mirroring run-single-avd-scenario.sh:321-323: every
# endpoint THIS lane configures is infrastructure the harness named, not a value
# the run minted, so it is exempted from S7/S12 and never declared. The gate
# already exempts RELAY_URL and the proxy's two spellings; what it cannot know
# is the profile pool and the Blossom server, which only the profile lane sets.

# The lines an iOS `flutter test -d <udid>` transcript carries whatever the app
# printed — its HOST skeleton, the iOS twin of the `VMServiceFlutterDriver:`
# block run-b3-real-gps.sh derives its Android floor from:
#   1. the expanded reporter's `HH:MM +N: loading <suite>.dart`, written before
#      anything is built;
#   2. flutter_tools' `Running Xcode build...`, and
#   3. its `Xcode build done.  <n>s` — an incremental build prints both exactly
#      as a cold one does (measured across every iOS upload of CI runs
#      35280144455, 35397118356 and 35622556197);
#   4. the reporter's first test-start line, which the scanner's `proof_of_run`
#      separately requires.
# Nothing else is a property of the RUN: the rest of a transcript is whatever
# the scenario chose to print, which is why floors measured from a transcript's
# length (22/24/27/56, each half of one) redden a lane for printing less than
# last time — CI run 35464818348 on the Android side. A floor is a MINIMUM, so
# this bound holds for a sink of several transcripts too; it only grows weaker
# there, never wrong.
readonly IOS_HOST_SKELETON_LINES=4

# ios_drive_floor_ok <n> — refuses a floor that is not derived from that
# skeleton. Called ONCE, at script start (below the --self-test dispatch), never
# on the gate path: a refusal there would mean a mis-set floor skipped the gate
# and left the transcript the failure upload publishes unscanned and
# uncontained, which is the one outcome the gate exists to prevent.
ios_drive_floor_ok() {
  if ! [[ "$1" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: HAVEN_LOGSCAN_DRIVE_FLOOR must be an integer in 1..${IOS_HOST_SKELETON_LINES}, got '$1'" >&2
    return 1
  fi
  if (( $1 > IOS_HOST_SKELETON_LINES )); then
    echo "ERROR: HAVEN_LOGSCAN_DRIVE_FLOOR=$1 is outside 1..${IOS_HOST_SKELETON_LINES}, the host skeleton an iOS transcript always carries. A higher number can only have been measured from one transcript's length, which is not a property of the run; what proves a test ran is the scanner's proof_of_run, not this number." >&2
    return 1
  fi
  return 0
}

scan_log_or_contain() {
  local profile="${HAVEN_LOGSCAN_PROFILE:-}"
  if [[ -z "${profile}" ]]; then
    if [[ -n "${WIRE_UPSTREAM:-}${HAVEN_WIRE_SENTINEL:-}" ]]; then profile=proxy; else profile=host; fi
  fi
  # THE DRIVE SINK IS EVERY SCENARIO'S TRANSCRIPT, not just this invocation's.
  #
  # `$1` is one fixed path that this script TRUNCATES per invocation, so a lane
  # that drives two scenarios through it (e2e-ios.yml: e2e_combined, then
  # ios_bg_mirror_test) has only the last one by the time anything reads it —
  # and the mirror check is a single `testWidgets` with no prints, ~14 lines
  # against a `drive` floor calibrated to the core flow's ~394, i.e. rc 4 on
  # every green run of both variants. Per-STEP floors cannot fix it: the first
  # gate seals the manifest and every later gate reuses it, floors included
  # (tooling/e2e/ci/logscan-gate.sh).
  #
  # So this scenario's live transcript is weighed together with every EARLIER
  # scenario's preserved one, and this scenario's copy is taken after the gate
  # (see below). Each file is counted once: the floor is a minimum, and a sink
  # list holding both a transcript and a copy of it would halve the floor's
  # strictness for every single-scenario lane.
  local transcript sink="$1"
  for transcript in "${1%.log}".*.log; do
    [[ -f "${transcript}" ]] || continue
    sink="${sink},${transcript}"
  done
  local -a lane=()
  [[ -z "${HAVEN_LOGSCAN_HOST_COORDINATE:-}" ]] \
    || lane=(--host-decl "coordinate=${HAVEN_LOGSCAN_HOST_COORDINATE}")
  # Whatever the floor says, this function SCANS: the value was validated at
  # script start, and a refusal here would leave a transcript that exists
  # unscanned and uncontained while the workflow's failure upload still ran.
  [[ -z "${HAVEN_LOGSCAN_DRIVE_FLOOR:-}" ]] \
    || lane+=(--floor "drive=${HAVEN_LOGSCAN_DRIVE_FLOOR}")
  # The profile pool is three `ws://` URLs, which is an S7 hit on any
  # Haven-owned line that names one — latent until CI run 35280144455 made iOS
  # lines parse at all. Split on comma AND space so the lane's spelling cannot
  # decide whether the exemption lands; HAVEN_E2E_PROFILE_RELAY (the pool's
  # first member) needs no entry of its own, being one of these.
  local endpoint
  local -a pool=()
  IFS=', ' read -r -a pool <<<"${HAVEN_E2E_PROFILE_RELAYS:-}"
  for endpoint in ${pool[@]+"${pool[@]}"}; do
    [[ -z "${endpoint}" ]] || lane+=(--exempt-endpoint "${endpoint}")
  done
  # The Blossom server prints `listening on 127.0.0.1:<port>` into its own log
  # while the client's URL says `localhost`, so the exemption has to name the
  # SERVER's spelling: `localhost` trips no rule, `127.0.0.1` trips S12. Until
  # now that line was clean only because the gate's unconditional
  # `ws://127.0.0.1:7788` proxy exemption happens to expand to the bare host —
  # an accident that would end with the next change to the proxy's port.
  [[ -z "${HAVEN_E2E_BLOSSOM_URL:-}" ]] \
    || lane+=(--exempt-endpoint "http://127.0.0.1:${HAVEN_E2E_BLOSSOM_URL##*:}")
  local rc=0
  logscan_gate "${profile}" /tmp/haven-soak/needles \
    ${lane[@]+"${lane[@]}"} -- \
    --sink "drive=${sink}" --report /tmp/ios-logscan/sim.ndjson || rc=$?
  # Preserve this scenario's transcript for the NEXT invocation's gate and for
  # the artifact — AFTER the gate, never before. On rc 1 the gate has just
  # deleted every file it scanned, because the workflows upload on failure and
  # a leak is a failure; a copy taken beforehand would survive to be published,
  # and fixture S1 fails on exactly that. The ORDER is what contains a leak —
  # `cp` of a deleted source copies nothing — and the rc test below is defence
  # in depth, not the mechanism.
  if (( rc != 1 )); then
    cp "$1" "$(scenario_transcript "$1")" 2>/dev/null || true
  fi
  return "${rc}"
}

# scenario_transcript <log> — where THIS invocation's drive log is preserved.
#
# One file per scenario, named after it and placed BESIDE the transcript it
# copies, so a two-scenario lane keeps both, an artifact listing says which is
# which, and the gate's glob above stays inside whatever directory it was
# handed — which is what keeps the self-test's fixtures hermetic instead of
# sweeping up a previous lane's /tmp. Sanitised the way
# ios_retry_verdict_file sanitises its own slug: the scenario is an argument,
# and an argument is not somewhere a path separator should be able to reach.
scenario_transcript() {
  local slug="${SCENARIO_FILE##*/}"
  slug="${slug%.dart}"
  printf '%s.%s.log' "${1%.log}" "${slug//[^A-Za-z0-9._-]/-}"
}

# ---------------------------------------------------------------------------
# --self-test — exercise THE WIRING, not the predicate.
#
# ios-flake-lib.sh's own self-test proves the classifier reads logs correctly.
# It cannot prove the watchdog ever produces such a log, ever fires, or ever
# stands down — and a watchdog that never fires silently reverts this lane to
# "the outer timeout kills it, nothing is classified, nothing is retried",
# while a watchdog that fires too eagerly kills running suites. Both are
# invisible to a fixture-only test.
#
# So this drives the REAL run_ios_test_with_watchdog against a stubbed
# `spawn_ios_test` — no simulator, no Xcode, no network — and then hands the
# resulting log to the REAL classifier. That last step is also the anti-drift
# proof: if the marker the watchdog writes ever stops being the marker the
# classifier requires, fixture W1 fails.
#
# The count below is pinned by EQUALITY, and counts CASES — each distinct input
# driven through the thing under test, loop iterations included — not the
# assertions made about them, because several assertions can rest on one run.
# A summary printed from whatever happened to run would report "all passed"
# over a case somebody deleted, which is how the floor cases added in
# 2026-09 went in with nothing pinning them.
# ---------------------------------------------------------------------------
readonly IOS_SIM_SELF_TEST_FIXTURES=33
readonly IOS_SIM_WATCHDOG_CASES=12

run_self_test() {
  # Drive the watchdog on a compressed clock. The deadline constants are
  # `readonly` on purpose (they gate a 45-minute step), so re-exec once with a
  # 2-second deadline rather than making them mutable for the test's benefit.
  if [[ "${HAVEN_IOS_SELF_TEST_REEXEC:-}" != "1" ]]; then
    HAVEN_IOS_SELF_TEST_REEXEC=1 \
    HAVEN_IOS_FIRST_TEST_WATCHDOG_SECS=2 \
    HAVEN_IOS_WATCHDOG_POLL_SECS=1 \
      exec bash "${BASH_SOURCE[0]}" --self-test
  fi

  local tmp fail=0 log ran=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN
  log="${tmp}/ios-test.log"

  # Every fixture below replaces `spawn_ios_test` with a synthetic process, so
  # the SHIPPED one has to be captured before the first override or W8 would
  # inspect a stub instead of the real invocation.
  local real_spawn
  real_spawn="$(declare -f spawn_ios_test)"

  # THE REAL TRANSCRIPT'S FIRST LINE. The expanded reporter prints it while the
  # suite is being LOADED, minutes before the build finishes (green run
  # 35664400984: 23:37:55 here, `Xcode build done.` at 23:51:37). Every stub
  # below emits it, because a stub whose log starts at the build cannot
  # reproduce the vacuity it caused — while the predicate scanned the whole log
  # this line stood the watchdog down on its first poll, so the watchdog could
  # not fire on ANY real run and none of these fixtures could see that. Dynamic
  # scoping is what carries it into the stubs, the same way W8's SCENARIO_FILE
  # reaches the shipped spawn_ios_test.
  local loading='00:00 +0: loading /Users/runner/work/Haven-App/Haven-App/haven/integration_test/e2e/e2e_combined.dart'

  ran=$(( ran + 1 ))
  # (W1) THE ADMITTED FLAKE — build completes, then the suite never starts a
  #      test. The watchdog MUST fire, mark the log, and kill the run, and the
  #      REAL classifier MUST accept the result as retryable.
  #
  #      This is also the regression pin for the DEAD watchdog: with the
  #      pre-build load line present, restoring the old whole-log predicate
  #      makes the watchdog stand down here and this fixture reds.
  spawn_ios_test() {
    {
      echo "${loading}"
      echo 'Running Xcode build...'
      echo 'Xcode build done.                                           400.0s'
      sleep 20
    } > "$1" 2>&1 &
  }
  run_ios_test_with_watchdog "${log}" >/dev/null 2>&1
  if ! LC_ALL=C grep -aqF -- "${IOS_STALL_MARKER}" "${log}"; then
    echo "SELF-TEST FAIL (W1): the watchdog did NOT fire on a post-build stall" >&2
    fail=1
  fi
  if (( ios_test_rc == 0 )); then
    echo "SELF-TEST FAIL (W1): a killed stall reported success" >&2
    fail=1
  fi
  if ! ios_log_is_launch_stall "${log}"; then
    echo "SELF-TEST FAIL (W1): the classifier REJECTED the watchdog's own output" \
         "— the marker the watchdog writes and the marker the classifier requires" \
         "have drifted apart, so the one real iOS flake would stop being retried" >&2
    fail=1
  fi

  ran=$(( ran + 1 ))
  # (W1b) CI RUN 35690725254, AS IT HAPPENED. flutter_tools failed to attach,
  #       said so in its own words, and then did NOT exit. `No tests ran.` used
  #       to be in the activity set, so the watchdog treated the sentence "no
  #       test ran" as a test running and stood down; the outer 30-minute
  #       timeout did the killing, the attempt never reached classification, and
  #       the verdict stayed `unproven` so attempt 2 refused. The watchdog MUST
  #       fire here, and the verdict MUST be the launch stall.
  spawn_ios_test() {
    {
      echo "${loading}"
      echo 'Running Xcode build...'
      echo 'Xcode build done.                                           647.3s'
      echo 'No tests ran.'
      echo 'Error waiting for a debug connection: The log reader failed unexpectedly'
      sleep 20
    } > "$1" 2>&1 &
  }
  run_ios_test_with_watchdog "${log}" >/dev/null 2>&1
  if ! LC_ALL=C grep -aqF -- "${IOS_STALL_MARKER}" "${log}"; then
    echo "SELF-TEST FAIL (W1b): the watchdog stood down on 'No tests ran.' — the" \
         "line flutter_tools prints when NOTHING ran, so the attempt runs into" \
         "the outer timeout unclassified (CI run 35690725254)" >&2
    fail=1
  fi
  if (( ios_test_rc == 0 )); then
    echo "SELF-TEST FAIL (W1b): a killed stall reported success" >&2
    fail=1
  fi
  if ! ios_log_is_launch_stall "${log}"; then
    echo "SELF-TEST FAIL (W1b): a failed attach that ran no test was classified" \
         "as GENUINE" >&2
    fail=1
  fi

  ran=$(( ran + 1 ))
  # (W1c) THE SAME FAILURE, SPELLED BY THE TOOL AND THEN EXITING. flutter_tools
  #       is entitled to give up rather than hang, and then the watchdog never
  #       fires: the process is gone before the deadline, so there is no marker,
  #       no flag and no snapshot. The verdict rests ENTIRELY on flutter_tools'
  #       own account of the attach, which is what makes this the fixture that
  #       reds if that form of clause (b) is dropped.
  spawn_ios_test() {
    {
      echo "${loading}"
      echo 'Running Xcode build...'
      echo 'Xcode build done.                                           647.3s'
      echo 'No tests ran.'
      echo 'Error waiting for a debug connection: The log reader failed unexpectedly'
      exit 1
    } > "$1" 2>&1 &
  }
  run_ios_test_with_watchdog "${log}" >/dev/null 2>&1
  if LC_ALL=C grep -aqF -- "${IOS_STALL_MARKER}" "${log}" \
     || [[ -f "$(ios_stall_flag_path "${log}")" ]]; then
    echo "SELF-TEST FAIL (W1c): the watchdog left evidence for a process that" \
         "had already exited, so this fixture no longer proves the tool's own" \
         "report carries the verdict on its own" >&2
    fail=1
  fi
  if (( ios_test_rc != 1 )); then
    echo "SELF-TEST FAIL (W1c): the real exit code was lost (got ${ios_test_rc})" >&2
    fail=1
  fi
  if ! ios_log_is_launch_stall "${log}"; then
    echo "SELF-TEST FAIL (W1c): flutter_tools reported that it attached to" \
         "nothing and ran no test, and the attempt was still classified as" \
         "GENUINE — the same infrastructure failure as W1b, and it must end" \
         "attributed rather than as an anonymous outer timeout" >&2
    fail=1
  fi

  ran=$(( ran + 1 ))
  # (W2) A HEALTHY, SLOW SUITE — it STARTS, then keeps working well past the
  #      watchdog deadline. The watchdog MUST stand down: killing a running
  #      suite at a fixed deadline would be a self-inflicted flake, and it is
  #      the one this lane actually suffered (run 32622119290, a 400-second
  #      ios_bg_publish test killed at 300 s and retried into the same kill).
  #
  #      The shape is the EXPANDED reporter's start line and nothing else until
  #      long after the deadline: a test that has begun and not yet finished.
  #      Deliberately not a COMPLETED test — a fixture that emits `✅ <name>`
  #      before sleeping proves only "a finished test stands the watchdog
  #      down", which is the weaker property and the one that held while this
  #      lane was dying.
  #
  #      `(setUpAll)` is what a healthy iOS run actually prints first (green run
  #      35664400984, 43 s after the build): a synthetic test name from
  #      test_core, and an ordinary progress-line subject — which is why this
  #      case is also the proof that a healthy start is never killed, and why
  #      there is no separate fixture for it.
  spawn_ios_test() {
    {
      echo "${loading}"
      echo 'Xcode build done.                                           400.0s'
      echo '00:00 +0: (setUpAll)'
      sleep 6
      echo '00:06 +1: All tests passed!'
    } > "$1" 2>&1 &
  }
  run_ios_test_with_watchdog "${log}" >/dev/null 2>&1
  if LC_ALL=C grep -aqF -- "${IOS_STALL_MARKER}" "${log}"; then
    echo "SELF-TEST FAIL (W2): the watchdog killed a RUNNING suite" >&2
    fail=1
  fi
  if (( ios_test_rc != 0 )); then
    echo "SELF-TEST FAIL (W2): a passing run reported rc=${ios_test_rc}" >&2
    fail=1
  fi

  ran=$(( ran + 1 ))
  # (W3) A GENUINE FAST FAILURE. The watchdog must not touch it, the true exit
  #      code must survive, and the classifier must refuse to retry it. Spelled
  #      in the GitHub reporter's shapes; W3b is the same event under the
  #      reporter this lane actually pins.
  spawn_ios_test() {
    {
      echo "${loading}"
      echo 'Xcode build done.                                           400.0s'
      echo '::group::❌ (setUpAll) (failed)'
      echo '::error::0 tests passed, 1 failed.'
      exit 1
    } > "$1" 2>&1 &
  }
  run_ios_test_with_watchdog "${log}" >/dev/null 2>&1
  if (( ios_test_rc != 1 )); then
    echo "SELF-TEST FAIL (W3): the real exit code was lost (got ${ios_test_rc})" >&2
    fail=1
  fi
  if ios_log_is_launch_stall "${log}"; then
    echo "SELF-TEST FAIL (W3): a genuine test failure was classified as retryable" >&2
    fail=1
  fi

  ran=$(( ran + 1 ))
  # (W3b) A GENUINE FAILURE UNDER THE REPORTER THIS LANE PINS. Every iOS lane
  #       runs `--reporter expanded`, and nothing else here drives a real
  #       assertion failure through it end to end — W3 is the github reporter's
  #       shapes, which CI has not emitted since that pin. A test STARTS, fails,
  #       and the suite exits: the watchdog must not touch it and the verdict
  #       must be `genuine`, whatever the transcript's opening line says.
  spawn_ios_test() {
    {
      echo "${loading}"
      echo 'Xcode build done.                                           400.0s'
      echo '00:00 +0: the kind-0 plane resolved onto the hermetic pool'
      echo '00:03 +0 -1: the kind-0 plane resolved onto the hermetic pool [E]'
      echo '00:03 +0 -1: Some tests failed.'
      exit 1
    } > "$1" 2>&1 &
  }
  run_ios_test_with_watchdog "${log}" >/dev/null 2>&1
  if LC_ALL=C grep -aqF -- "${IOS_STALL_MARKER}" "${log}"; then
    echo "SELF-TEST FAIL (W3b): the watchdog fired on a suite that ran and failed" >&2
    fail=1
  fi
  if (( ios_test_rc != 1 )); then
    echo "SELF-TEST FAIL (W3b): the real exit code was lost (got ${ios_test_rc})" >&2
    fail=1
  fi
  if ios_log_is_launch_stall "${log}"; then
    echo "SELF-TEST FAIL (W3b): an expanded-reporter test failure was classified" \
         "as retryable — the reporter every iOS lane pins" >&2
    fail=1
  fi

  ran=$(( ran + 1 ))
  # (W4) THE BUILD IS NOT WATCHED. A build that outlives the deadline must NOT
  #      arm the watchdog: a hung or failed build is deterministic, and retrying
  #      it hides it for another ten minutes.
  spawn_ios_test() {
    {
      echo "${loading}"
      echo 'Running pod install...'
      sleep 6
      echo 'Error running pod install'
      exit 1
    } > "$1" 2>&1 &
  }
  run_ios_test_with_watchdog "${log}" >/dev/null 2>&1
  if LC_ALL=C grep -aqF -- "${IOS_STALL_MARKER}" "${log}"; then
    echo "SELF-TEST FAIL (W4): the watchdog armed before the build finished" >&2
    fail=1
  fi
  if ios_log_is_launch_stall "${log}"; then
    echo "SELF-TEST FAIL (W4): a build-phase failure was classified as retryable" >&2
    fail=1
  fi

  ran=$(( ran + 1 ))
  # (W5) THE ADMITTED FLAKE, WITH A CHILD THAT SPEAKS ON ITS WAY OUT — the case
  #      that cost CI run 30964250098 its retry, and which NO fixture covered:
  #      every stub above dies silently, so `>` and `>>` were indistinguishable
  #      and a post-kill write could not be modelled at all.
  #
  #      `flutter test` traps SIGTERM and prints "\n🎉 0 tests passed.\n" — 22
  #      bytes. The redirect here is deliberately `>` (truncating), so the child
  #      keeps its OWN file offset and those 22 bytes land exactly on the 22-byte
  #      head of the marker the watchdog just appended ("IOS-WATCHDOG: no on-de"),
  #      leaving "vice test started within 300s…". That is the hostile case, kept
  #      hostile on purpose: the point of this fixture is that the verdict no
  #      longer depends on a file the dying child can still reach.
  spawn_ios_test() {
    {
      trap 'printf "\n\360\237\216\211 0 tests passed.\n"; exit 1' TERM
      echo "${loading}"
      echo 'Running Xcode build...'
      echo 'Xcode build done.                                           400.0s'
      sleep 20 & wait
    } > "$1" 2>&1 &
  }
  run_ios_test_with_watchdog "${log}" >/dev/null 2>&1
  # (W5a) The fixture must actually reproduce the hazard, or it proves nothing.
  if LC_ALL=C grep -aqF -- "${IOS_STALL_MARKER}" "${log}"; then
    echo "SELF-TEST FAIL (W5a): the in-log marker survived, so this fixture is" \
         "no longer modelling the post-kill overwrite it exists for" >&2
    fail=1
  fi
  # (W5b) The out-of-band evidence must exist and be intact.
  if [[ ! -f "$(ios_stall_flag_path "${log}")" ]]; then
    echo "SELF-TEST FAIL (W5b): the watchdog fired but left no stall flag" >&2
    fail=1
  fi
  if ! LC_ALL=C grep -aqF -- "${IOS_STALL_MARKER}" "$(ios_prekill_log_path "${log}")" 2>/dev/null; then
    echo "SELF-TEST FAIL (W5b): the pre-kill snapshot is missing or does not" \
         "carry the marker the watchdog wrote before signalling" >&2
    fail=1
  fi
  if (( ios_test_rc == 0 )); then
    echo "SELF-TEST FAIL (W5b): a killed stall reported success" >&2
    fail=1
  fi
  # (W5c) THE POINT: retryable, despite a log the dying child corrupted.
  if ! ios_log_is_launch_stall "${log}"; then
    echo "SELF-TEST FAIL (W5c): a post-build launch/attach stall was classified" \
         "as GENUINE because the process we killed overwrote our evidence —" \
         "this is exactly the CI run 30964250098 regression" >&2
    fail=1
  fi

  ran=$(( ran + 1 ))
  # (W5d) THE PRODUCTION REDIRECT ITSELF. Every fixture here overrides
  #       `spawn_ios_test` wholesale, so none of them can observe how the REAL
  #       one redirects — reverting it to `>` would leave all of them green
  #       while restoring the clobber that cost CI run 30964250098 its retry.
  #       Read from the function's own body, with comment lines stripped, so a
  #       comment merely *mentioning* `>>` cannot satisfy it (the assertion has
  #       to be about the code, or it is about nothing).
  local spawn_body
  spawn_body="$(sed -n '/^spawn_ios_test() {/,/^}/p' "${BASH_SOURCE[0]}" \
    | grep -v '^[[:space:]]*#')"
  if ! grep -qE '>>[[:space:]]*"\$1"' <<<"${spawn_body}"; then
    echo "SELF-TEST FAIL (W5d): the production spawn_ios_test no longer" \
         "redirects in APPEND mode. With a truncating '>' the child keeps its" \
         "own file offset and its post-SIGTERM output lands ON TOP of the" \
         "watchdog's marker instead of after it — CI run 30964250098." >&2
    fail=1
  fi
  if grep -qE '(^|[^>])>[[:space:]]*"\$1"' <<<"${spawn_body}"; then
    echo "SELF-TEST FAIL (W5d2): the production spawn_ios_test still has a" \
         "TRUNCATING redirect to the log." >&2
    fail=1
  fi

  ran=$(( ran + 1 ))
  # (W6) THE NEGATIVE TWIN. The same post-kill log SHAPE, but with no flag and
  #      no snapshot: nothing our watchdog produced. That is what an outer
  #      attempt timeout (SIGKILL from the retry action) leaves behind, and it
  #      must stay NOT retryable — otherwise "the log ends mid-suite" would
  #      become a retry ticket and the blanket retry is back.
  local orphan="${tmp}/orphan.log"
  {
    echo "${loading}"
    echo 'Running Xcode build...'
    echo 'Xcode build done.                                           400.0s'
    printf '\n\360\237\216\211 0 tests passed.\n'
  } > "${orphan}"
  ios_clear_stall_evidence "${orphan}"
  if ios_log_is_launch_stall "${orphan}"; then
    echo "SELF-TEST FAIL (W6): a kill this watchdog did not perform was" \
         "classified as retryable" >&2
    fail=1
  fi

  ran=$(( ran + 1 ))
  # (W7) A stale verdict must not be inherited. W5 left a flag and a snapshot on
  #      `${log}`; a fresh run that fails GENUINELY must clear them, or attempt 2
  #      would inherit attempt 1's retryable verdict.
  spawn_ios_test() {
    {
      echo "${loading}"
      echo 'Xcode build done.                                           400.0s'
      echo '::group::❌ (setUpAll) (failed)'
      echo '::error::0 tests passed, 1 failed.'
      exit 1
    } > "$1" 2>&1 &
  }
  run_ios_test_with_watchdog "${log}" >/dev/null 2>&1
  if [[ -f "$(ios_stall_flag_path "${log}")" ]]; then
    echo "SELF-TEST FAIL (W7): a prior attempt's stall flag survived into a new" \
         "run — a genuine failure would inherit a retryable verdict" >&2
    fail=1
  fi
  if ios_log_is_launch_stall "${log}"; then
    echo "SELF-TEST FAIL (W7): a genuine failure was classified as retryable on" \
         "the strength of a previous attempt's evidence" >&2
    fail=1
  fi

  ran=$(( ran + 1 ))
  # (W8) THE REPORTER IS PINNED. Everything above is about how the watchdog
  #      reacts to a log; this is about which log `flutter test` produces at
  #      all. Left to itself flutter_tools picks the `github` reporter in CI,
  #      which emits nothing for a test until that test FINISHES — turning the
  #      deadline above from "time to launch" into "time to finish", which no
  #      long-running scenario can satisfy. No fixture over a stubbed process
  #      can see that, because the stub decides its own output; the only place
  #      it is observable is the argv the real function builds.
  #
  #      So restore the shipped `spawn_ios_test` and run it against a `flutter`
  #      that records its arguments instead of launching anything.
  eval "${real_spawn}"
  local argv="${tmp}/flutter-argv"
  flutter() { printf '%s\n' "$@" > "${argv}"; }
  local SCENARIO_FILE="integration_test/selftest.dart"
  local SIM_UDID="selftest-simulator-udid"
  local RELAY_URL="ws://localhost:7777"
  local LIVE_SYNC="false"
  local E2E_NO_BACKGROUND="1"
  local EXTRA_DART_DEFINES=()
  spawn_ios_test "${tmp}/spawn.log"
  wait "$!" 2>/dev/null || true
  unset -f flutter
  if ! grep -qxF -- '--reporter' "${argv}" 2>/dev/null \
     || ! grep -qxF -- 'expanded' "${argv}" 2>/dev/null; then
    echo "SELF-TEST FAIL (W8): spawn_ios_test does not pass '--reporter" \
         "expanded', so CI falls back to the github reporter, which emits" \
         "nothing until a test ENDS — the first-test watchdog then bounds test" \
         "RUNTIME instead of launch time and kills healthy long scenarios" >&2
    fail=1
  fi
  # …and the recorded argv must really be this invocation, not an empty file a
  # never-called stub left behind.
  if ! grep -qxF -- "${SCENARIO_FILE}" "${argv}" 2>/dev/null; then
    echo "SELF-TEST FAIL (W8): the flutter stub recorded no scenario file —" \
         "spawn_ios_test was not exercised, so the check above proved nothing" >&2
    fail=1
  fi

  # (S1) THE FLAG-OFF ARM CONTAINS. The workflows upload the transcript
  #      `if: failure()` and a leak is a failure, so unless the gate removes
  #      what it flagged the lane publishes the line it went red on. Driven
  #      through the REAL sourced gate with HAVEN_LOGSCAN pinned empty (a
  #      lane's exported `true` must not pick the other arm) and a FAKE
  #      key-material floor: rc 1 removes the log, rc 3 (nothing scannable)
  #      and rc 0 leave it, the verdict comes back unchanged, and the
  #      identifier scanner is never invoked.
  local fake_scan="${tmp}/fake-scan.sh" gate_log want rc
  printf '%s\n' '#!/usr/bin/env bash' 'exit "${FAKE_SCAN_RC}"' > "${fake_scan}"
  gate_log="${tmp}/gate.log"
  for want in 1 3 0; do
    ran=$(( ran + 1 ))
    printf 'transcript\n' > "${gate_log}"
    rm -f "${tmp}"/gate.*.log
    rc=0
    SCENARIO_FILE=integration_test/e2e/e2e_combined.dart \
      HAVEN_LOGSCAN= HAVEN_LOGSCAN_PROFILE= HAVEN_LOGSCAN_HOST_COORDINATE= \
      SECRET_SCAN="${fake_scan}" FAKE_SCAN_RC="${want}" \
      HAVEN_LOGSCAN_BIN="${tmp}/no-such-binary" \
      scan_log_or_contain "${gate_log}" 2>/dev/null || rc=$?
    if (( rc != want )); then
      echo "SELF-TEST FAIL (S1): the gate returned ${rc} for a floor rc of ${want}" >&2
      fail=1
    fi
    if (( want == 1 )) && [[ -e "${gate_log}" ]]; then
      echo "SELF-TEST FAIL (S1): a leak (rc 1) left the transcript on disk for" \
           "the failure-artifact upload to publish" >&2
      fail=1
    fi
    if (( want == 1 )) && [[ -e "${tmp}/gate.e2e_combined.log" ]]; then
      echo "SELF-TEST FAIL (S1): a leak (rc 1) left a per-scenario COPY of the" \
           "transcript on disk — the gate deleted what it scanned and the copy" \
           "would be published in its place" >&2
      fail=1
    fi
    if (( want != 1 )) && [[ ! -e "${tmp}/gate.e2e_combined.log" ]]; then
      echo "SELF-TEST FAIL (S1): floor rc ${want} left no per-scenario copy, so" \
           "a second scenario's gate would weigh this one's transcript as absent" >&2
      fail=1
    fi
    if (( want != 1 )) && [[ ! -e "${gate_log}" ]]; then
      echo "SELF-TEST FAIL (S1): floor rc ${want} removed a log it had no" \
           "leak to contain" >&2
      fail=1
    fi
  done

  ran=$(( ran + 1 ))
  # (S2) THE GATE IS HARD, AND FIRST. Read from the real run (everything from
  #      the LOG_FILE definition down, comments stripped): the transcript goes
  #      through the gate at top level, BEFORE the retry classification that
  #      could re-roll a leak; no `cat`/`head`/`tail` of the transcript sits at
  #      top level at all (the live follower inside the watchdog is a reader
  #      of a log that is still being written, and the gate is what stands
  #      between the finished transcript and the upload); the former soft
  #      `-x` scanner gate is gone; no bare key-material floor call remains
  #      (the floor runs inside the wrapper); the sourced gate reads
  #      HAVEN_LOGSCAN; and a flag-on run refuses a STATED profile that is
  #      not `proxy` or `host` BEFORE the build, so a job that mistyped one
  #      costs seconds, not a 15-minute Xcode build scanned by nothing.
  local real_run gate_line verdict_line
  real_run="$(sed -n '/^readonly LOG_FILE=/,$p' "${BASH_SOURCE[0]}" \
                | grep -v '^[[:space:]]*#')"
  if [[ -z "${real_run}" ]]; then
    echo "SELF-TEST FAIL (S2): cannot find the real run's LOG_FILE definition" >&2
    fail=1
  fi
  gate_line="$(grep -nE '^scan_log_or_contain "\$\{LOG_FILE\}"' <<<"${real_run}" \
                 | cut -d: -f1 | head -n 1)"
  verdict_line="$(grep -n 'ios_record_failure_verdict "${VERDICT_FILE}"' <<<"${real_run}" \
                    | cut -d: -f1 | head -n 1)"
  if [[ -z "${gate_line}" || -z "${verdict_line}" ]] || (( verdict_line < gate_line )); then
    echo "SELF-TEST FAIL (S2): the real run must gate the transcript at top" \
         "level and BEFORE the retry classification (gate='${gate_line}'," \
         "classify='${verdict_line}')" >&2
    fail=1
  fi
  if grep -qE '^(cat|head|tail) .*LOG_FILE' <<<"${real_run}"; then
    echo "SELF-TEST FAIL (S2): the transcript is echoed at top level — a leak" \
         "would reach the job log outside the gate" >&2
    fail=1
  fi
  if grep -qE 'if[[:space:]]+\[\[[[:space:]]+-x[[:space:]]' <<<"${real_run}"; then
    echo "SELF-TEST FAIL (S2): a soft \`if [[ -x …\` scanner gate is back — an" \
         "unbuilt scanner would be skipped, not fatal" >&2
    fail=1
  fi
  local floor='scan-logs-for-'
  floor+='secrets.sh'
  if grep -qF "${floor}" <<<"${real_run}"; then
    echo "SELF-TEST FAIL (S2): a bare key-material floor call is back; the" \
         "floor runs inside the wrapper, behind the gate" >&2
    fail=1
  fi
  if ! declare -f logscan_gate | grep -q 'HAVEN_LOGSCAN'; then
    echo "SELF-TEST FAIL (S2): the sourced gate no longer reads HAVEN_LOGSCAN;" \
         "the identifier arm is unreachable" >&2
    fail=1
  fi
  if ! grep -qE 'HAVEN_LOGSCAN_PROFILE.*\^\(proxy\|host\)\$' <<<"${real_run}"; then
    echo "SELF-TEST FAIL (S2): the real run no longer refuses a flag-on run" \
         "whose profile is not proxy|host before the build" >&2
    fail=1
  fi

  # (S3) THE FLAG-ON CALL SITE. The library's own --self-test proves what
  #      logscan_gate does with its arguments; what only this file can prove
  #      is which arguments it is handed. A recording stub in place of the
  #      sourced function: the job's profile, the fixed sidecar directory, THIS
  #      SCENARIO'S PRESERVED transcript as the drive sink (not the fixed path
  #      the next invocation truncates), the report beside (never in) the
  #      uploaded files, and a lane's seeded position, own drive floor and own
  #      endpoints passed as seal arguments only when the lane hands them in;
  #      the verdict comes back unchanged.
  local gate_argv="${tmp}/gate-argv" real_gate
  local gate_drive="${gate_log}"
  real_gate="$(declare -f logscan_gate)"
  logscan_gate() { printf '%s\n' "$@" > "${gate_argv}"; return "${FAKE_GATE_RC}"; }
  ran=$(( ran + 1 ))
  local -a want_argv=(proxy /tmp/haven-soak/needles --
    --sink "drive=${gate_drive}" --report /tmp/ios-logscan/sim.ndjson)
  rc=0
  rm -f "${tmp}"/gate.*.log
  SCENARIO_FILE=integration_test/e2e/e2e_combined.dart \
    HAVEN_LOGSCAN=true HAVEN_LOGSCAN_PROFILE=proxy HAVEN_LOGSCAN_HOST_COORDINATE= \
    HAVEN_LOGSCAN_DRIVE_FLOOR= HAVEN_E2E_PROFILE_RELAYS= HAVEN_E2E_BLOSSOM_URL= \
    FAKE_GATE_RC=4 scan_log_or_contain "${gate_log}" || rc=$?
  if (( rc != 4 )) || [[ "$(cat "${gate_argv}")" != "$(printf '%s\n' "${want_argv[@]}")" ]]; then
    echo "SELF-TEST FAIL (S3): wanted rc 4 with argv '${want_argv[*]}', got rc" \
         "${rc} with '$(tr '\n' ' ' < "${gate_argv}")'" >&2
    fail=1
  fi
  ran=$(( ran + 1 ))
  want_argv=(host /tmp/haven-soak/needles --host-decl 'coordinate=-63.076429,-141.927821' --
    --sink "drive=${gate_drive}" --report /tmp/ios-logscan/sim.ndjson)
  rc=0
  rm -f "${tmp}"/gate.*.log
  SCENARIO_FILE=integration_test/e2e/e2e_combined.dart \
    HAVEN_LOGSCAN=true HAVEN_LOGSCAN_PROFILE=host \
    HAVEN_LOGSCAN_HOST_COORDINATE='-63.076429,-141.927821' \
    HAVEN_LOGSCAN_DRIVE_FLOOR= HAVEN_E2E_PROFILE_RELAYS= HAVEN_E2E_BLOSSOM_URL= \
    FAKE_GATE_RC=0 scan_log_or_contain "${gate_log}" || rc=$?
  if (( rc != 0 )) || [[ "$(cat "${gate_argv}")" != "$(printf '%s\n' "${want_argv[@]}")" ]]; then
    echo "SELF-TEST FAIL (S3): a seeded position must be declared as one" \
         "--host-decl before the separator; got rc ${rc} with" \
         "'$(tr '\n' ' ' < "${gate_argv}")'" >&2
    fail=1
  fi
  # A lane's own drive floor: one `--floor drive=<n>` seal argument, and only
  # when the lane states one. The policy default is the core-flow drive's, and
  # a b-lane that took it would read its own complete transcript as truncated
  # (CI run 35280144455: 45, 49 and 54 lines against a floor of 100).
  #
  # …and the number itself is DERIVED, not measured. The fixture below is a
  # real iOS transcript's opening — the build-only prefix of CI run
  # 35280144455's B4 upload, verbatim, plus the one test-start line that makes
  # it a run — interleaved with the app output a scenario happens to print. Only
  # the host skeleton is a property of the run, so the floor may not exceed it,
  # which is what refuses a number taken from a transcript's length.
  ran=$(( ran + 1 ))
  local ios_skeleton_re printed
  ios_skeleton_re='^([0-9]{2}:[0-9]{2} \+[0-9]+( -[0-9]+)?: |Running Xcode build|Xcode build done)'
  printf '%s\n' \
    '00:00 +0: loading /Users/runner/work/Haven-App/Haven-App/haven/integration_test/b4_ios_real_gps_test.dart' \
    'The following plugins do not support Swift Package Manager for ios:' \
    '  - rust_lib_haven' \
    'Running Xcode build...                                          ' \
    'Xcode build done.                                           74.2s' \
    '00:00 +0: B4: publish a REAL simulator GPS fix' \
    '[b4] LOCATION_AUTH_OK status=LocationPermissionStatus.whileInUse' \
    '[ScenarioHarness] bootstrapped role=ScenarioRole.solo' > "${tmp}/ios-skeleton.drive.log"
  printed="$(grep -cE "${ios_skeleton_re}" "${tmp}/ios-skeleton.drive.log" || true)"
  if [[ "${printed}" != "${IOS_HOST_SKELETON_LINES}" ]]; then
    echo "SELF-TEST FAIL (S3): the fixture carries ${printed} host-skeleton" \
         "line(s), and IOS_HOST_SKELETON_LINES pins ${IOS_HOST_SKELETON_LINES}." \
         "A floor derived from a number nothing counts is a measurement again." >&2
    fail=1
  fi
  # …so a floor that is not derived from it is refused AT SCRIPT START, before
  # any capture can exist. Driven by RE-RUNNING THIS SCRIPT with no arguments:
  # the refusal has to precede even the usage error, so a lane that mis-set the
  # floor never builds, never launches and never writes a transcript. The old
  # refusal lived in scan_log_or_contain instead — on the very path the
  # workflows upload `if: failure()` — where it meant the key-material floor
  # never ran, nothing was contained, and the artifact step published the
  # transcript anyway.
  local bad out floor_rc
  for bad in "$(( IOS_HOST_SKELETON_LINES + 1 ))" 22 0 'four'; do
    ran=$(( ran + 1 ))
    floor_rc=0
    out="$(HAVEN_LOGSCAN_DRIVE_FLOOR="${bad}" bash "${BASH_SOURCE[0]}" 2>&1)" || floor_rc=$?
    if (( floor_rc != 2 )) || ! grep -qF 'HAVEN_LOGSCAN_DRIVE_FLOOR' <<<"${out}" \
       || grep -qF 'usage:' <<<"${out}"; then
      echo "SELF-TEST FAIL (S3): a drive floor of '${bad}' is not derived from" \
           "the ${IOS_HOST_SKELETON_LINES}-line host skeleton and must stop the" \
           "script before it reads its arguments; got rc ${floor_rc} with" \
           "'$(tr '\n' ' ' <<<"${out}")'" >&2
      fail=1
    fi
  done
  # …and the control, so the refusal above is the floor's and not an artefact of
  # calling this script with no arguments: a DERIVED floor gets past it and the
  # run stops on the usage error instead.
  ran=$(( ran + 1 ))
  floor_rc=0
  out="$(HAVEN_LOGSCAN_DRIVE_FLOOR="${IOS_HOST_SKELETON_LINES}" bash "${BASH_SOURCE[0]}" 2>&1)" || floor_rc=$?
  if (( floor_rc != 2 )) || ! grep -qF 'usage:' <<<"${out}" \
     || grep -qF 'HAVEN_LOGSCAN_DRIVE_FLOOR' <<<"${out}"; then
    echo "SELF-TEST FAIL (S3): a floor of ${IOS_HOST_SKELETON_LINES} is derived" \
         "from the host skeleton and must pass the start-up check; got rc" \
         "${floor_rc} with '$(tr '\n' ' ' <<<"${out}")'" >&2
    fail=1
  fi
  # …while the gate path itself no longer refuses ANYTHING: a transcript that
  # exists is scanned and its verdict returned, floor or no floor. This is the
  # half the old `|| return 2` broke — it skipped the gate on a capture the
  # failure upload was about to publish.
  ran=$(( ran + 1 ))
  rc=0
  rm -f "${tmp}"/gate.*.log "${gate_argv}"
  SCENARIO_FILE=integration_test/e2e/e2e_combined.dart \
    HAVEN_LOGSCAN=true HAVEN_LOGSCAN_PROFILE=host HAVEN_LOGSCAN_HOST_COORDINATE= \
    HAVEN_LOGSCAN_DRIVE_FLOOR=99 HAVEN_E2E_PROFILE_RELAYS= HAVEN_E2E_BLOSSOM_URL= \
    FAKE_GATE_RC=1 scan_log_or_contain "${gate_log}" || rc=$?
  if (( rc != 1 )) || [[ ! -e "${gate_argv}" ]] \
     || [[ -e "${tmp}/gate.e2e_combined.log" ]]; then
    echo "SELF-TEST FAIL (S3): a capture that exists must be scanned and" \
         "contained whatever the floor says; got rc ${rc}$([[ -e "${gate_argv}" ]] || echo ' with the gate never called')." >&2
    fail=1
  fi
  rm -f "${tmp}"/gate.*.log "${gate_argv}"
  ran=$(( ran + 1 ))
  want_argv=(host /tmp/haven-soak/needles "--floor" "drive=${IOS_HOST_SKELETON_LINES}" --
    --sink "drive=${gate_drive}" --report /tmp/ios-logscan/sim.ndjson)
  rc=0
  rm -f "${tmp}"/gate.*.log
  SCENARIO_FILE=integration_test/e2e/e2e_combined.dart \
    HAVEN_LOGSCAN=true HAVEN_LOGSCAN_PROFILE=host HAVEN_LOGSCAN_HOST_COORDINATE= \
    HAVEN_LOGSCAN_DRIVE_FLOOR="${IOS_HOST_SKELETON_LINES}" HAVEN_E2E_PROFILE_RELAYS= HAVEN_E2E_BLOSSOM_URL= \
    FAKE_GATE_RC=0 scan_log_or_contain "${gate_log}" || rc=$?
  if (( rc != 0 )) || [[ "$(cat "${gate_argv}")" != "$(printf '%s\n' "${want_argv[@]}")" ]]; then
    echo "SELF-TEST FAIL (S3): a lane's drive floor must be one --floor seal" \
         "argument before the separator; got rc ${rc} with" \
         "'$(tr '\n' ' ' < "${gate_argv}")'" >&2
    fail=1
  fi

  # A lane's own endpoints: every member of the profile pool and the Blossom
  # server's OWN spelling, each one `--exempt-endpoint` before the separator.
  # The pool is split on comma AND space, so the same three URLs land whichever
  # way the workflow writes them.
  want_argv=(host /tmp/haven-soak/needles
    --exempt-endpoint ws://localhost:7778
    --exempt-endpoint ws://localhost:7779
    --exempt-endpoint ws://localhost:7780
    --exempt-endpoint http://127.0.0.1:3000 --
    --sink "drive=${gate_drive}" --report /tmp/ios-logscan/sim.ndjson)
  local spelling
  for spelling in 'ws://localhost:7778,ws://localhost:7779,ws://localhost:7780' \
                  'ws://localhost:7778 ws://localhost:7779 ws://localhost:7780'; do
    ran=$(( ran + 1 ))
    rc=0
    rm -f "${tmp}"/gate.*.log
    SCENARIO_FILE=integration_test/e2e/e2e_combined.dart \
    HAVEN_LOGSCAN=true HAVEN_LOGSCAN_PROFILE=host HAVEN_LOGSCAN_HOST_COORDINATE= \
      HAVEN_LOGSCAN_DRIVE_FLOOR= HAVEN_E2E_PROFILE_RELAYS="${spelling}" \
      HAVEN_E2E_BLOSSOM_URL=http://localhost:3000 \
      FAKE_GATE_RC=0 scan_log_or_contain "${gate_log}" || rc=$?
    if (( rc != 0 )) || [[ "$(cat "${gate_argv}")" != "$(printf '%s\n' "${want_argv[@]}")" ]]; then
      echo "SELF-TEST FAIL (S3): a lane's own endpoints must each be one" \
           "--exempt-endpoint before the separator (pool spelled" \
           "'${spelling}'); got rc ${rc} with" \
           "'$(tr '\n' ' ' < "${gate_argv}")'" >&2
      fail=1
    fi
  done
  # …and a lane that configures neither passes neither: an exemption nobody
  # asked for is a rule switched off for free.
  ran=$(( ran + 1 ))
  want_argv=(host /tmp/haven-soak/needles --
    --sink "drive=${gate_drive}" --report /tmp/ios-logscan/sim.ndjson)
  rc=0
  rm -f "${tmp}"/gate.*.log
  SCENARIO_FILE=integration_test/e2e/e2e_combined.dart \
    HAVEN_LOGSCAN=true HAVEN_LOGSCAN_PROFILE=host HAVEN_LOGSCAN_HOST_COORDINATE= \
    HAVEN_LOGSCAN_DRIVE_FLOOR= HAVEN_E2E_PROFILE_RELAYS= HAVEN_E2E_BLOSSOM_URL= \
    FAKE_GATE_RC=0 scan_log_or_contain "${gate_log}" || rc=$?
  if (( rc != 0 )) || [[ "$(cat "${gate_argv}")" != "$(printf '%s\n' "${want_argv[@]}")" ]]; then
    echo "SELF-TEST FAIL (S3): a lane that sets no endpoint must exempt none;" \
         "got rc ${rc} with '$(tr '\n' ' ' < "${gate_argv}")'" >&2
    fail=1
  fi

  # A SECOND scenario in the same job: e2e-ios.yml drives e2e_combined and then
  # ios_bg_mirror_test through this script, which truncates the one fixed
  # transcript per invocation. The mirror check is one `testWidgets` with no
  # prints — ~14 lines against a floor calibrated to the core flow — so the
  # second gate has to weigh the first scenario's PRESERVED transcript with it,
  # or every green core-flow run is rc 4. Per-step floors cannot substitute:
  # the first gate sealed the manifest and this one reuses it.
  ran=$(( ran + 1 ))
  rm -f "${tmp}"/gate.*.log
  printf 'the core flow, preserved by its own gate\n' > "${tmp}/gate.e2e_combined.log"
  want_argv=(host /tmp/haven-soak/needles --
    --sink "drive=${gate_log},${tmp}/gate.e2e_combined.log"
    --report /tmp/ios-logscan/sim.ndjson)
  rc=0
  SCENARIO_FILE=integration_test/ios_bg_mirror_test.dart \
    HAVEN_LOGSCAN=true HAVEN_LOGSCAN_PROFILE=host HAVEN_LOGSCAN_HOST_COORDINATE= \
    HAVEN_LOGSCAN_DRIVE_FLOOR= HAVEN_E2E_PROFILE_RELAYS= HAVEN_E2E_BLOSSOM_URL= \
    FAKE_GATE_RC=0 scan_log_or_contain "${gate_log}" || rc=$?
  if (( rc != 0 )) || [[ "$(cat "${gate_argv}")" != "$(printf '%s\n' "${want_argv[@]}")" ]]; then
    echo "SELF-TEST FAIL (S3): a second scenario's gate must weigh the first" \
         "scenario's preserved transcript with its own; got rc ${rc} with" \
         "'$(tr '\n' ' ' < "${gate_argv}")'" >&2
    fail=1
  fi
  if [[ ! -e "${tmp}/gate.ios_bg_mirror_test.log" ]]; then
    echo "SELF-TEST FAIL (S3): the gate left no transcript under THIS" \
         "scenario's name, so a third scenario would not see it" >&2
    fail=1
  fi
  rm -f "${tmp}"/gate.*.log

  # (S4) THE PROFILE IS INFERRED, NEVER DEFAULTED. With HAVEN_LOGSCAN_PROFILE
  #      unset the gate is handed `proxy` when the recorder's exports are
  #      present — WIRE_UPSTREAM (the job's proxy-start step) or
  #      HAVEN_WIRE_SENTINEL (the drive's own half of the sentinel), either
  #      alone — and `host` only when both are absent. Every variable the
  #      inference reads is pinned on each call, so a lane's exported values
  #      cannot leak into the fixture (the guards job inherits none, a lane
  #      inherits all).
  local inferred spec label sentinel upstream
  for spec in 'sentinel|HAVEN_WIRE_SENTINEL:cafe||proxy' 'upstream||ws://127.0.0.1:7777|proxy' 'neither|||host'; do
    ran=$(( ran + 1 ))
    IFS='|' read -r label sentinel upstream want <<<"${spec}"
    rc=0
    rm -f "${tmp}"/gate.*.log
    SCENARIO_FILE=integration_test/e2e/e2e_combined.dart \
      HAVEN_LOGSCAN=true HAVEN_LOGSCAN_PROFILE= HAVEN_LOGSCAN_HOST_COORDINATE= \
      HAVEN_LOGSCAN_DRIVE_FLOOR= HAVEN_E2E_PROFILE_RELAYS= HAVEN_E2E_BLOSSOM_URL= \
      HAVEN_WIRE_SENTINEL="${sentinel}" WIRE_UPSTREAM="${upstream}" \
      FAKE_GATE_RC=0 scan_log_or_contain "${gate_log}" || rc=$?
    inferred="$(head -n 1 "${gate_argv}")"
    if (( rc != 0 )) || [[ "${inferred}" != "${want}" ]]; then
      echo "SELF-TEST FAIL (S4 ${label}): with the profile unset the gate must be" \
           "handed '${want}', got '${inferred}' (rc ${rc})" >&2
      fail=1
    fi
  done
  eval "${real_gate}"

  if (( fail != 0 )); then
    echo "run-ios-sim-scenario.sh --self-test: FAILED" >&2
    return 1
  fi
  if (( ran != IOS_SIM_SELF_TEST_FIXTURES )); then
    echo "run-ios-sim-scenario.sh --self-test: FAILED — ran ${ran} case(s)," \
         "expected exactly ${IOS_SIM_SELF_TEST_FIXTURES}; a case was added or" \
         "removed without moving the pin" >&2
    return 1
  fi
  echo "run-ios-sim-scenario.sh --self-test: all ${ran} cases passed" \
       "(${IOS_SIM_WATCHDOG_CASES} watchdog," \
       "$(( IOS_SIM_SELF_TEST_FIXTURES - IOS_SIM_WATCHDOG_CASES ))" \
       "log-privacy-gate)" \
       "(a post-build stall is caught, marked and accepted by the classifier," \
       "over a transcript that opens the way a real one does — with the" \
       "reporter's pre-build suite load, which is what the watchdog used to" \
       "stand down on — and stays retryable even when the process we kill" \
       "overwrites the marker on its way out, or when flutter_tools reports the" \
       "failed attach itself and hangs, or reports it and exits; a running" \
       "suite, a genuine failure under either reporter, a slow build, a kill" \
       "this watchdog did not perform, and a previous attempt's stale verdict" \
       "are all correctly NOT retried; the streaming reporter the whole" \
       "deadline rests on is still passed to flutter test; and the log-privacy" \
       "gate is the floor alone when HAVEN_LOGSCAN is unset, removing the" \
       "transcript on a leak and on nothing else, stands at top level before" \
       "the retry classification with no echo of the transcript beside it," \
       "hands the sourced gate the job's profile, the transcript, a seeded" \
       "position and this lane's own drive floor when it supplies them," \
       "refuses at SCRIPT START — before any capture can exist — a drive floor" \
       "outside the four-line host skeleton an iOS transcript always carries," \
       "while scanning and containing a capture that does exist whatever that" \
       "floor says, infers proxy from either recorder" \
       "export and host from neither when no profile is stated, and refuses a" \
       "mistyped profile before the build)."
  return 0
}

if [[ "${1:-}" == "--self-test" ]]; then
  run_self_test
  exit $?
fi

# THE LANE'S DRIVE FLOOR, VALIDATED ONCE AND FIRST — before the arguments are
# read, before the build, before anything can have been captured. It used to be
# checked inside scan_log_or_contain, which runs on the very path the workflows
# upload `if: failure()`: a mis-set floor refused THERE meant the key-material
# floor never ran, the transcript was never contained, and the artifact step
# published it anyway. Refused here, the lane costs seconds and captures
# nothing; every iOS lane reaches the gate through this script (b4, b7, the
# profile lane's iOS job and the background-publish wrapper all delegate), so
# one call covers them all.
if [[ -n "${HAVEN_LOGSCAN_DRIVE_FLOOR:-}" ]] \
   && ! ios_drive_floor_ok "${HAVEN_LOGSCAN_DRIVE_FLOOR}"; then
  exit 2
fi

SCENARIO_FILE="${1:-}"
SIM_UDID="${2:-}"
if [[ -z "${SCENARIO_FILE}" || -z "${SIM_UDID}" ]]; then
  echo "ERROR: usage: $0 <scenario-file> <simulator-udid>  |  $0 --self-test" >&2
  exit 2
fi

readonly RELAY_URL="${HAVEN_E2E_RELAY:-ws://localhost:7777}"
# S1: HAVEN_LIVE_SYNC is threaded per-STEP by the caller (env), never hardcoded
# in this shared script, so the same script serves BOTH the e2e_combined step
# (live-sync ON) and the ios_bg_mirror_test step (live-sync OFF — the M7 mirror
# must NOT start the engine).
#
# MANDATORY, with no default. The former `:-false` default was the last place a
# caller could decline to answer: e2e-profile.yml's iOS job took it silently
# while the Android job of the SAME lane took Dart's opposite default, so one
# lane ran one scenario on two receive paths and neither half said so
# (CI_HARDENING_BACKLOG.md A7). Both callers now set it per step, which is what
# S1 always intended — a per-step decision, not a fallback that happens to be
# safe today. Failing closed also means a NEW iOS step cannot inherit poll by
# accident the way a new Android build inherits live.
if [[ -z "${HAVEN_LIVE_SYNC:-}" ]]; then
  echo "ERROR: HAVEN_LIVE_SYNC is not set." >&2
  echo "       This script compiles the receive path into the test build, so" >&2
  echo "       every calling STEP must state 'true' or 'false' in its env" >&2
  echo "       (S1 per-step scoping; CI_HARDENING_BACKLOG.md A7)." >&2
  exit 2
fi
if [[ ! "${HAVEN_LIVE_SYNC}" =~ ^(true|false)$ ]]; then
  echo "ERROR: HAVEN_LIVE_SYNC must be exactly 'true' or 'false' (got '${HAVEN_LIVE_SYNC}')." >&2
  exit 2
fi
readonly LIVE_SYNC="${HAVEN_LIVE_SYNC}"
# Single-engine guard for `flutter drive` (see main.dart): threaded per-STEP by
# the caller, like HAVEN_LIVE_SYNC, so e2e_combined can skip the M7 background
# init (which spawns a 2nd Flutter engine that collides with the driver) while
# the shared ios_bg_mirror step (which TESTS the background system) does not.
readonly E2E_NO_BACKGROUND="${HAVEN_E2E_NO_BACKGROUND:-false}"
readonly LOG_FILE="/tmp/flutter-ios-test.log"

# SCRIPT_DIR is set at the top of this file (the library source needs it).
readonly REPO_ROOT="${SCRIPT_DIR}/../../.."
readonly HAVEN_DIR="${REPO_ROOT}/haven"
# Under HAVEN_LOGSCAN=true a profile the job DID state must be one the seal
# knows; refused HERE, before a 15-minute build: a lane whose recorder is in
# front of the relay but which is sealed as `host` searches for fewer needles
# than the run declared, and `rules` scans for none. Unset is not refused —
# scan_log_or_contain infers it from the recorder's own exports.
if [[ "${HAVEN_LOGSCAN:-}" == "true" && -n "${HAVEN_LOGSCAN_PROFILE:-}" \
      && ! "${HAVEN_LOGSCAN_PROFILE}" =~ ^(proxy|host)$ ]]; then
  echo "ERROR: HAVEN_LOGSCAN is true but HAVEN_LOGSCAN_PROFILE is neither 'proxy'" >&2
  echo "       nor 'host' (got '${HAVEN_LOGSCAN_PROFILE}'). The job's env block" >&2
  echo "       declares it beside HAVEN_LOGSCAN: proxy where the recording wire" >&2
  echo "       proxy is in front of the relay, host everywhere else." >&2
  exit 2
fi
# The scanner's findings reports (sink:line, class, rule — never a value) go
# beside the uploaded files, never among them.
mkdir -p /tmp/ios-logscan

if [[ ! -f "${HAVEN_DIR}/${SCENARIO_FILE}" ]]; then
  echo "ERROR: scenario file not found: ${HAVEN_DIR}/${SCENARIO_FILE}" >&2
  exit 2
fi

cd "${HAVEN_DIR}"

# ---------------------------------------------------------------------------
# Retry gate (A6). `nick-fields/retry` will start attempt 2 on ANY non-zero
# exit, and it has no input that could be told otherwise — so the refusal has to
# live here, in the command it re-runs, keyed on the verdict the previous
# attempt left behind. Placed FIRST so a refused attempt costs seconds rather
# than another 10-minute Xcode build.
#
# Fails closed: only an attempt that reached classification AND proved the one
# admitted signature leaves `retryable`. Everything else — a genuine failure, a
# crash, an outer-timeout SIGKILL, a verdict too mangled to parse — stops here
# with the original exit code. See tooling/e2e/ci/ios-flake-lib.sh.
# ---------------------------------------------------------------------------
VERDICT_FILE="$(ios_retry_verdict_file "${SCENARIO_FILE}")"
readonly VERDICT_FILE
ios_retry_gate "${VERDICT_FILE}" || exit $?

echo "iOS E2E — scenario=${SCENARIO_FILE} udid=${SIM_UDID} relay=${RELAY_URL} live_sync=${LIVE_SYNC}"

# Optional Blossom URL passthrough (public-profile lane only). Appended to the
# flutter-test dart-defines ONLY when HAVEN_E2E_BLOSSOM_URL is set in the
# environment (the e2e-profile.yml iOS job sets it), so every OTHER iOS lane's
# compiled dart-defines stay byte-identical — this shared script must not
# change behaviour for the lanes that do not use Blossom.
EXTRA_DART_DEFINES=()
if [[ -n "${HAVEN_E2E_BLOSSOM_URL:-}" ]]; then
  EXTRA_DART_DEFINES+=(--dart-define=HAVEN_E2E_BLOSSOM_URL="${HAVEN_E2E_BLOSSOM_URL}")
  echo "iOS E2E — blossom=${HAVEN_E2E_BLOSSOM_URL}"
fi

# Optional profile-plane relay passthrough (public-profile lane only), same
# opt-in shape as the Blossom URL above. These point kind-0 publish/fetch at the
# hermetic pool started by start-profile-relays.sh, which is DISJOINT from the
# circle relay in ${RELAY_URL} — a contaminated relay is subtracted from the
# pool by haven-core's contamination ledger, so reusing the circle relay for
# kind-0 would fail closed with PoolUnderflow.
if [[ -n "${HAVEN_E2E_PROFILE_RELAY:-}" ]]; then
  EXTRA_DART_DEFINES+=(--dart-define=HAVEN_E2E_PROFILE_RELAY="${HAVEN_E2E_PROFILE_RELAY}")
  echo "iOS E2E — profile relay=${HAVEN_E2E_PROFILE_RELAY}"
fi
if [[ -n "${HAVEN_E2E_PROFILE_RELAYS:-}" ]]; then
  EXTRA_DART_DEFINES+=(--dart-define=HAVEN_E2E_PROFILE_RELAYS="${HAVEN_E2E_PROFILE_RELAYS}")
  echo "iOS E2E — profile pool=${HAVEN_E2E_PROFILE_RELAYS}"
fi

# Optional real-GPS expectation passthrough (B4 lane only — set by
# tooling/e2e/ci/run-b4-ios-real-gps.sh), same opt-in shape as the two above, so
# every other iOS lane's compiled dart-defines stay byte-identical.
#
# These name the coordinates that lane seeded with `xcrun simctl location set`.
# They MUST reach the compiler: b4_ios_real_gps_test.dart has no default for
# them and fails closed when they are absent, precisely so it can never end up
# comparing a decrypt against a constant it chose itself. The values are not
# echoed — a seeded position is the payload that lane exists to prove is
# encrypted, and this log is uploaded as a CI artifact.
if [[ -n "${HAVEN_B4_GEO_LAT:-}" ]]; then
  EXTRA_DART_DEFINES+=(--dart-define=HAVEN_B4_GEO_LAT="${HAVEN_B4_GEO_LAT}")
fi
if [[ -n "${HAVEN_B4_GEO_LON:-}" ]]; then
  EXTRA_DART_DEFINES+=(--dart-define=HAVEN_B4_GEO_LON="${HAVEN_B4_GEO_LON}")
fi
if [[ -n "${HAVEN_B4_GEO_TOLERANCE_DEG:-}" ]]; then
  EXTRA_DART_DEFINES+=(
    --dart-define=HAVEN_B4_GEO_TOLERANCE_DEG="${HAVEN_B4_GEO_TOLERANCE_DEG}"
  )
fi

# Optional auth-tier passthrough (the iOS background-publish lane only — set by
# tooling/e2e/ci/run-ios-bg-publish.sh), same opt-in shape as the blocks above.
#
# It names the tier that lane's drive PINS, and it MUST reach the compiler:
# ios_bg_publish_test.dart has no default for it and fails closed when it is
# absent, precisely so the Always matrix job can never silently run the
# When-In-Use assertions. Echoed, unlike B4's coordinates — a tier name is not
# a payload, and knowing which leg a preserved log came from is the first thing
# anyone reading it wants.
if [[ -n "${HAVEN_BGP_EXPECT_TIER:-}" ]]; then
  EXTRA_DART_DEFINES+=(
    --dart-define=HAVEN_BGP_EXPECT_TIER="${HAVEN_BGP_EXPECT_TIER}"
  )
  echo "iOS E2E — pinned auth tier=${HAVEN_BGP_EXPECT_TIER}"
fi

# Optional wire-journal SENTINEL passthrough (instrumented lanes only — set by
# the caller when it has started the recording proxy in front of the relay),
# same opt-in shape as the three blocks above, so every other iOS lane's
# compiled dart-defines stay byte-identical.
#
# The token is minted ONCE per job and handed to BOTH halves: to the drive here
# as `--dart-define=HAVEN_WIRE_SENTINEL=`, which is where
# `TestRelay.emitWireJournalSentinel()` reads it from
# (haven/integration_test/e2e/_lib/test_relay.dart's `String.fromEnvironment`),
# and to the host oracle as `--sentinel`. One string read from one place is what
# stops the two halves drifting: a lane that minted it twice would get two
# different random values and the resulting "no anchor" META-FLOOR would read as
# a flake rather than as the wiring bug it is.
#
# NOT echoed with its value. The token is not secret (docs/WIRE_JOURNAL.md:
# "Never put anything sensitive in the token" — it is written to the journal
# verbatim), but this log is uploaded as a CI failure artifact and a bare
# confirmation that the passthrough fired is all a triager needs.
#
# Spelled over three lines rather than as a one-line `+=(...)`, matching the B4
# tolerance define just above: static readers of this chain
# (scripts/ci/check_wire_oracle_lane_reachable.sh) match the define with a
# whitespace-delimited regex, so a closing `)` on the same token ends up INSIDE
# the value they compare against the lane's `--sentinel`, and the two halves
# then read as naming different strings.
if [[ -n "${HAVEN_WIRE_SENTINEL:-}" ]]; then
  EXTRA_DART_DEFINES+=(
    --dart-define=HAVEN_WIRE_SENTINEL="${HAVEN_WIRE_SENTINEL}"
  )
  echo "iOS E2E — wire-journal sentinel supplied (${#HAVEN_WIRE_SENTINEL} chars);" \
       "the drive will anchor the host oracle's snapshot."
fi

# Clean slate — mirror the Android lane's force-stop + `adb uninstall`
# (run-single-avd-scenario.sh). This simulator is booted ONCE and reused across
# steps and both retry attempts, and `flutter test` does NOT guarantee a data
# wipe (a timeout-killed prior attempt never runs its "remove app on
# completion"). A `haven_mdk.db` left in the app's Documents container by a
# prior process is then opened by THIS process under a fresh, ephemeral
# in-memory test keyring whose key does not match the one that encrypted that
# file → MDK "Wrong encryption key: database cannot be decrypted", which
# deterministically fails live-sync engine start for EVERY scenario. Removing
# the app deletes that container so the first open mints a fresh key+DB pair.
# `|| true`: a not-yet-installed app is fine.
#
# OPT-OUT (HAVEN_E2E_IOS_SKIP_UNINSTALL=1): a caller that has ALREADY prepared
# the simulator — its own uninstall, install, and per-run `xcrun simctl privacy`
# grants — must be able to stop this line from erasing that preparation. A
# privacy grant is keyed by bundle id and does not survive an uninstall, so an
# unconditional wipe here would silently revert the B7 auth-tier lane
# (tooling/e2e/ci/run-b7-ios-auth-tier.sh) to "no authorization granted", which
# reads on the wire exactly like a passing run of a lane that proved nothing.
# Unset in every other lane, so their behaviour is unchanged.
if [[ "${HAVEN_E2E_IOS_SKIP_UNINSTALL:-}" == "1" ]]; then
  echo "iOS E2E — skipping the pre-run uninstall (HAVEN_E2E_IOS_SKIP_UNINSTALL=1):" \
       "the caller owns this simulator's install + privacy state."
else
  xcrun simctl uninstall "${SIM_UDID}" com.oblivioustech.haven >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------------------
# Drive the integration test on the booted simulator.
#
# `flutter test <integration_test> -d <udid>` builds (debug), installs, runs,
# and reports — no separate `flutter drive` / test_driver indirection (which
# on iOS would need an IPA, not a simulator .app). The dart-define injects the
# relay URL the host relay is serving. The invocation itself lives in
# `spawn_ios_test` (near the top of this file) so the watchdog can supervise it
# and so --self-test can substitute a synthetic process for it.
# ---------------------------------------------------------------------------
set +e
run_ios_test_with_watchdog "${LOG_FILE}"
TEST_RC=${ios_test_rc}
set -e

# ---------------------------------------------------------------------------
# Security Rules 6 and 15: no key material and no identifier may reach CI logs.
# Gate the transcript and FAIL the lane on any non-zero verdict, even if the
# scenario itself passed.
#
# Ordered BEFORE the retry classification on purpose: a leak is never
# infrastructure, and must never be re-rolled in the hope the next attempt keeps
# it out of the log.
# ---------------------------------------------------------------------------
scan_rc=0
scan_log_or_contain "${LOG_FILE}" || scan_rc=$?
if (( scan_rc != 0 )); then
  ios_retry_record "${VERDICT_FILE}" genuine 1 "log-privacy gate failed the test log (rc=${scan_rc})"
  echo "ERROR: log-privacy gate failed for the iOS test log (rc=${scan_rc}:" \
       "1 = leak, now removed; 2 = guard broken; 3 = unusable; 4 = meta floor)" >&2
  exit 1
fi

if [[ "${TEST_RC}" -ne 0 ]]; then
  # ---------------------------------------------------------------------------
  # Classify, and record the verdict the NEXT attempt is gated on. The
  # classify-and-record step lives in the library so it is reachable from a
  # hermetic self-test (fixtures R1/R2) — an unconditional `retryable` here is
  # the blanket retry restored, and it must not be able to slip past CI.
  # ---------------------------------------------------------------------------
  if ios_record_failure_verdict "${VERDICT_FILE}" "${LOG_FILE}" "${TEST_RC}"; then
    echo "WARN: iOS e2e scenario '${SCENARIO_FILE}' hit a simulator" \
         "LAUNCH/ATTACH STALL (rc=${TEST_RC}) — the app built and installed but" \
         "no test ever started: either the suite was still silent" \
         "${FIRST_TEST_WATCHDOG_SECS}s after the build and the watchdog killed" \
         "it, or flutter_tools reported that it could not attach. This is the" \
         "one failure this lane retries; a retry may follow." >&2
  fi
  echo "ERROR: iOS e2e scenario '${SCENARIO_FILE}' failed (rc=${TEST_RC})" >&2
  exit "${TEST_RC}"
fi

# Passed — leave no verdict behind for a later step or a re-run to trip over.
ios_retry_clear "${VERDICT_FILE}"
echo "iOS E2E — PASSED"
