#!/usr/bin/env bash
#
# B7 — iOS "When In Use" vs "Always" authorization lane
# (docs/CI_HARDENING_BACKLOG.md, Workstream B, item B7).
#
# Runs ONE drive target (haven/integration_test/b7_ios_auth_tier_test.dart)
# TWICE on the SAME booted simulator, once per CoreLocation authorization tier,
# and then compares what the two runs OBSERVED.
#
#   run 1   xcrun simctl privacy <udid> grant location-always  -> authorizedAlways
#   run 2   xcrun simctl privacy <udid> grant location         -> authorizedWhenInUse
#
# # What this lane actually proves — and the premise it does NOT rest on
#
# The naive framing of B7 is "background publishing needs Always, so prove the
# app does not publish (and does not claim to) under When-In-Use". That framing
# is WRONG on iOS, and encoding it would have shipped a false oracle:
#
#   * A CLLocationManager session started while the app is foregrounded, with
#     `allowsBackgroundLocationUpdates = true` and the `location`
#     UIBackgroundMode declared, KEEPS DELIVERING under When-In-Use — the blue
#     status-bar indicator is the price. Haven relies on exactly that:
#     `MapShell._onPaused()` keeps the per-circle publish scheduler and the
#     motion trigger running on iOS purely on
#     `shouldKeepPublishingWhilePaused(backgroundSharingEnabled, isIOS)`; the
#     CoreLocation tier is never consulted there, and
#     `geolocator_location_service.dart` documents why.
#   * What "Always" genuinely buys is the RECEIVE-only relaunch after iOS
#     terminates the app: `HavenSLCHandler.startMonitoring()` refuses to arm
#     significant-location-change monitoring unless
#     `authorizationStatus == .authorizedAlways`.
#
# So the tier does not change WHETHER Haven publishes in the background. It
# changes what the UI is entitled to CLAIM, and the app's copy already draws
# that line (`locationSettingsIosLimitedNote` vs `locationSettingsIosGuidance`,
# whose ARB `@description` states the two-directional honesty rule verbatim).
# The drive target therefore asserts, per tier, that the observed tier drives
# the honest copy, and that background publishing continues in BOTH — which is
# correct behaviour, not a defect.
#
# # The two non-vacuity gates (the reason this script exists at all)
#
# Eight times in this repo's audit history a guard has passed while proving
# nothing. Two distinct routes to that outcome exist here, and each has its own
# gate.
#
# ## Gate 1 — DISCRIMINATION: did the two grants actually differ?
#
# If `simctl privacy grant` silently no-ops, both runs observe the SAME tier,
# every per-tier branch in the drive target still passes, and the lane goes
# green having discriminated nothing.
#
# This script therefore does not trust the grant. Each run PRINTS the tier it
# read back from real CoreLocation (via the production `MethodChannel` bridge,
# not a fake), and this script requires:
#
#   1. the `location-always` run observed exactly `always`,
#   2. the `location` run observed exactly `whenInUse`,
#   3. the two observations DIFFER.
#
# (3) is redundant given (1) and (2) and is asserted anyway: it is the one
# clause that survives any future loosening of the other two.
#
# ## Gate 2 — COMPLETION: did each run reach the end of BOTH of its tests?
#
# Gate 1 cannot see a drive that never ran. The tier marker is printed near the
# TOP of the first test, BEFORE a single assertion, so a `skip: true`, a
# `markTestSkipped`, or an early `return` in either test leaves `flutter test`
# reporting success over a body that proved nothing — and gate 1 reads the
# marker anyway and passes (CI_HARDENING_BACKLOG.md A3b).
#
# So this script ALSO requires both terminal proof markers, ONE PER TIER LOG:
#
#   [b7] COPY_OK                  printed only after the last copy assertion
#   [b7] BACKGROUND_PUBLISH_OK …  printed only after a post-pause kind-445 was
#                                 observed on the wire
#
# Both drives exit non-zero on a genuine assertion failure (the shared runner
# fails the run), so a missing marker under a rc-0 drive means something
# else: the body did not execute. The failure message says exactly that, and
# distinguishes it from an assertion that fired.
#
# # simctl support is PROBED, never assumed
#
# `location-always` has been a `simctl privacy` service since Xcode 11.4, but
# this lane's whole discrimination rests on it, so the preflight reads the
# subcommand's own usage text and fails with an attributable message if the
# runner's Xcode does not list it. A missing token is reported as a harness
# misconfiguration (exit 2), never as a test failure.
#
# # Why the app is installed BEFORE the grant
#
# A privacy grant is keyed by bundle identifier and lives in the simulator's
# locationd/TCC state, which `simctl uninstall` erases. The shared runner
# (`run-ios-sim-scenario.sh`) uninstalls the app on entry for the hermetic
# reasons documented there — which would erase the grant this lane just made.
# So this script builds the app once, and per tier does
# uninstall -> install -> grant -> run, asking the shared runner to skip its own
# uninstall via `HAVEN_E2E_IOS_SKIP_UNINSTALL=1` (an opt-in that leaves every
# other iOS lane byte-identical).
#
# Everything else — the first-test watchdog, the narrowed retry gate, the
# secret-leak scan — is inherited by delegating each run to
# `run-ios-sim-scenario.sh` rather than reimplementing `flutter test` here.
#
# # Scope boundary (stated so nobody over-reads a green)
#
# The simulator does not suspend a backgrounded app and does not run
# CoreLocation for real. This lane proves the app's OWN tier-dependent logic and
# copy, plus that a kind-445 leaves the device after a genuine
# `AppLifecycleState.paused`. It does NOT prove real background delivery on
# hardware, and it does not fire SLC or BGTask — both stay on the physical-device
# checklist (docs/CI_HARDENING_BACKLOG.md, "Out of scope for hosted runners").
#
# Usage:
#   run-b7-ios-auth-tier.sh <simulator-udid>
#   run-b7-ios-auth-tier.sh --self-test     # hermetic; no simulator, no Xcode
#
# Environment:
#   HAVEN_E2E_RELAY   WebSocket URL of the host relay (default
#                     ws://localhost:7777).
#   HAVEN_LIVE_SYNC   'true' or 'false'. MANDATORY — declared per STEP by the
#                     caller, exactly as run-ios-sim-scenario.sh requires (S1 /
#                     CI_HARDENING_BACKLOG.md A7).
#
# Side effects:
#   - Writes /tmp/b7-ios-always.log and /tmp/b7-ios-wheninuse.log (uploaded as
#     CI failure artifacts).
#   - Leaves the app UNINSTALLED from the simulator on completion.
#
# Exit status:
#   0  both tiers were granted, observed and behaved honestly
#   1  a drive run failed, the two runs did not discriminate the tiers, or a
#      drive exited 0 without printing both of its terminal proofs
#   2  usage / harness misconfiguration (including: this Xcode cannot grant
#      `location-always`, so the lane cannot be run at all)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# The drive target, relative to haven/ (the shared runner resolves it there).
readonly SCENARIO_FILE="integration_test/b7_ios_auth_tier_test.dart"

# Must match `haven/ios/Runner.xcodeproj`'s PRODUCT_BUNDLE_IDENTIFIER and the
# id run-ios-sim-scenario.sh uninstalls.
readonly BUNDLE_ID="com.oblivioustech.haven"

# Markers the drive target prints. Duplicated here (and ONLY here) because the
# Dart consts are not readable from bash; the drive target's doc comment names
# this file as the other half of the contract, and the --self-test below feeds
# the real parser fixtures built from these literals, so a drift shows up as a
# failing self-test rather than as a silently unparseable log.
#
# TIER_MARKER feeds gate 1 and is printed BEFORE any assertion, so it can never
# stand in for gate 2. COPY_MARKER and PUBLISH_MARKER are the terminal proofs:
# each is printed only after the last assertion of its own test.
readonly TIER_MARKER='[b7] OBSERVED_TIER='
readonly COPY_MARKER='[b7] COPY_OK'
readonly PUBLISH_MARKER='[b7] BACKGROUND_PUBLISH_OK'

# ---------------------------------------------------------------------------
# Pure helpers (exercised by --self-test)
# ---------------------------------------------------------------------------

# b7_simctl_supports_always <usage-text> — does this Xcode's `simctl privacy`
# offer the `location-always` service?
#
# Returns 0 (supported), 1 (parsed, and it is NOT offered), or 2 (the usage text
# does not look like a service list at all — do not guess either way).
b7_simctl_supports_always() {
  local usage="$1"
  # Deliberately no `\b`: this runs on macOS, whose BSD grep does not implement
  # the GNU word-boundary escape, so a `\b` pattern would silently never match
  # and every real run would report "unparseable" on a perfectly good Xcode.
  if ! grep -qE '(^|[^A-Za-z-])location([^A-Za-z-]|$)' <<<"${usage}"; then
    return 2
  fi
  grep -qF -- 'location-always' <<<"${usage}"
}

# b7_observed_tier <log> — the tier the drive target read back from CoreLocation.
#
# The target prints this marker ONCE, near the top of its FIRST test, before any
# assertion has run — which is precisely why its presence proves nothing about
# completion (that is gate 2's job, below). A repeated identical line is still
# tolerated, because a log can legitimately carry the same line twice (a
# `debugPrint` throttle flush, or the shared runner tee-ing a retry).
# DISAGREEING lines are NOT tolerated: they are reported as `conflict` rather
# than silently resolved by taking the first or the last. An absent marker
# reports `missing`.
b7_observed_tier() {
  local log="$1" tiers
  [[ -f "${log}" ]] || { echo "missing"; return 0; }
  # awk's index()/substr() are LITERAL operations. A sed or grep -o expression
  # built from the marker would not be: `[b7]` is a valid character class, so
  # `.*[b7] OBSERVED_TIER=` matches a single b or 7 and silently mis-parses.
  tiers="$(
    LC_ALL=C grep -aF -- "${TIER_MARKER}" "${log}" 2>/dev/null \
      | awk -v m="${TIER_MARKER}" '
          {
            i = index($0, m)
            if (i == 0) next
            s = substr($0, i + length(m))
            sub(/[^A-Za-z].*$/, "", s)
            if (s != "") print s
          }' \
      | sort -u
  )" || true
  if [[ -z "${tiers}" ]]; then echo "missing"; return 0; fi
  if (( $(grep -c '' <<<"${tiers}") > 1 )); then echo "conflict"; return 0; fi
  echo "${tiers}"
}

# b7_discrimination_ok <always-observed> <wheninuse-observed> — the non-vacuity
# gate. Prints nothing; returns 0 only when the two runs proved the grants
# actually discriminated.
b7_discrimination_ok() {
  local from_always="$1" from_wheninuse="$2"
  [[ "${from_always}" == "always" ]] || return 1
  [[ "${from_wheninuse}" == "whenInUse" ]] || return 1
  [[ "${from_always}" != "${from_wheninuse}" ]] || return 1
  return 0
}

# b7_missing_proofs <log> — prints the terminal proof markers this log does NOT
# carry, one per line. Empty output means the run reached the end of BOTH of its
# tests. A missing or empty log reports both as absent: absence of evidence is
# never evidence.
#
# `grep -aF` (literal, binary-safe) for the same reason as b7_observed_tier:
# `[b7]` is a valid character class, so any regex form of this check would match
# a lone `b` or `7` and pass vacuously — the exact failure this gate exists to
# prevent, reintroduced inside the gate itself.
#
# Always returns 0; the ANSWER is the output, so a caller in a `$( … )` under
# `set -e` is never killed by "no markers were missing".
b7_missing_proofs() {
  local log="${1:-}"
  if [[ ! -s "${log}" ]]; then
    printf '%s\n%s\n' "${COPY_MARKER}" "${PUBLISH_MARKER}"
    return 0
  fi
  LC_ALL=C grep -aqF -- "${COPY_MARKER}" "${log}" \
    || printf '%s\n' "${COPY_MARKER}"
  LC_ALL=C grep -aqF -- "${PUBLISH_MARKER}" "${log}" \
    || printf '%s\n' "${PUBLISH_MARKER}"
  return 0
}

# b7_completion_failures <always-log> <wheninuse-log> — GATE 2, over the whole
# lane. Prints one `<tier> <marker>` line per absent proof; empty output means
# both runs reached the end of both of their tests.
#
# Both logs are demanded, ONE PER TIER: the lane runs the target twice, and a
# proof printed by one tier says nothing about the other. Folding them into a
# single "the markers appeared somewhere" check would let a wholly skipped
# second tier ride on the first tier's evidence.
#
# Always returns 0; the answer is the output.
b7_completion_failures() {
  local always_log="${1:-}" wheninuse_log="${2:-}" entry marker
  for entry in "always:${always_log}" "whenInUse:${wheninuse_log}"; do
    while IFS= read -r marker; do
      [[ -n "${marker}" ]] || continue
      printf '%s %s\n' "${entry%%:*}" "${marker}"
    done < <(b7_missing_proofs "${entry#*:}")
  done
  return 0
}

# ---------------------------------------------------------------------------
# --self-test — hermetic. Fixtures are the ways this lane can go vacuously
# green, because those are the failures nothing else would catch.
# ---------------------------------------------------------------------------
run_self_test() {
  local tmp fail=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  _check() { # _check <label> <want-rc> <got-rc>
    if [[ "$2" == "$3" ]]; then
      printf '  \033[1;32mPASS\033[0m %s\n' "$1"
    else
      printf '  \033[1;31mFAIL\033[0m %s (want rc=%s, got rc=%s)\n' "$1" "$2" "$3" >&2
      fail=1
    fi
  }

  # --- (P1) An Xcode that offers the Always grant.
  local rc=0
  b7_simctl_supports_always \
'Set a permission to allow or deny.
Usage: simctl privacy <device> <action> <service> [<bundle identifier>]
   service: all, calendar, contacts-limited, contacts, location,
            location-always, photos-add, photos, media-library, microphone' \
    || rc=$?
  _check "P1 usage listing location-always is supported" 0 "${rc}"

  # --- (P2) THE PREMISE FIXTURE. An Xcode whose privacy service list has
  #     `location` but no `location-always`. This lane cannot discriminate
  #     anything there, and must say so instead of running half a proof.
  rc=0
  b7_simctl_supports_always \
'Usage: simctl privacy <device> <action> <service> [<bundle identifier>]
   service: all, calendar, contacts, location, photos, microphone' \
    || rc=$?
  _check "P2 usage without location-always is REFUSED" 1 "${rc}"

  # --- (P3) Unparseable usage (a future simctl that renamed everything) must
  #     be distinguishable from "not supported", or the lane would blame Xcode
  #     for its own broken parser.
  rc=0
  b7_simctl_supports_always 'xcrun: error: unable to find utility "simctl"' || rc=$?
  _check "P3 unparseable usage reports misconfiguration" 2 "${rc}"

  # --- (T1) The marker parser on a realistic log. The target prints the tier
  #     marker ONCE, near the top of its first test — the shape this fixture
  #     encodes, so it cannot drift back into the false belief that the marker
  #     is printed per test (it is not, which is why gate 2 exists at all).
  local log="${tmp}/t1.log"
  {
    echo 'Xcode build done.                                           400.0s'
    echo '[b7] OBSERVED_TIER=always'
    echo '00:12 +0: B7: observes the granted CoreLocation tier ...'
    echo '[b7] COPY_OK'
    echo '[b7] BACKGROUND_PUBLISH_OK tier=always'
    echo '🎉 2 tests passed.'
  } > "${log}"
  local got
  got="$(b7_observed_tier "${log}")"
  _check "T1 parses a single marker printed once, in test 1" "always" "${got}"

  # --- (T1b) A log that carries the SAME line twice (a debugPrint throttle
  #     flush, a tee-ed retry) is still one agreeing observation, not a
  #     conflict.
  log="${tmp}/t1b.log"
  {
    echo '[b7] OBSERVED_TIER=always'
    echo '[b7] OBSERVED_TIER=always'
  } > "${log}"
  got="$(b7_observed_tier "${log}")"
  _check "T1b a duplicated, agreeing marker is not a conflict" "always" "${got}"

  # --- (T2) whenInUse must survive the parser's word-boundary handling (the
  #     camel case is the only tier name with an uppercase letter mid-word).
  log="${tmp}/t2.log"
  echo '[b7] OBSERVED_TIER=whenInUse tier follows' > "${log}"
  got="$(b7_observed_tier "${log}")"
  _check "T2 parses whenInUse" "whenInUse" "${got}"

  # --- (T3) A log with no marker is `missing`, never an empty string that a
  #     later `[[ "$a" == "$b" ]]` would happily match against another empty.
  log="${tmp}/t3.log"
  echo 'Some tests failed.' > "${log}"
  got="$(b7_observed_tier "${log}")"
  _check "T3 a markerless log reports missing" "missing" "${got}"

  # --- (T4) Two DISAGREEING markers in one run mean the tier changed under the
  #     app mid-run; resolving that silently would let a half-granted run pass.
  log="${tmp}/t4.log"
  {
    echo '[b7] OBSERVED_TIER=always'
    echo '[b7] OBSERVED_TIER=whenInUse'
  } > "${log}"
  got="$(b7_observed_tier "${log}")"
  _check "T4 disagreeing markers report conflict" "conflict" "${got}"

  # --- (D1) The healthy pair.
  rc=0; b7_discrimination_ok always whenInUse || rc=$?
  _check "D1 always/whenInUse discriminates" 0 "${rc}"

  # --- (D2) THE VACUOUS-ORACLE FIXTURE. Both grants landed on the same tier
  #     (e.g. `location-always` silently no-opped). Every per-tier branch in the
  #     drive target still passes; only this gate can catch it.
  rc=0; b7_discrimination_ok whenInUse whenInUse || rc=$?
  _check "D2 identical observations FAIL (the vacuous-oracle case)" 1 "${rc}"
  rc=0; b7_discrimination_ok always always || rc=$?
  _check "D2b identical observations FAIL the other way too" 1 "${rc}"

  # --- (D3) Swapped: each run must observe the tier ITS OWN grant asked for,
  #     not merely a different one from its sibling.
  rc=0; b7_discrimination_ok whenInUse always || rc=$?
  _check "D3 swapped observations FAIL" 1 "${rc}"

  # --- (D4) A run that observed no tier at all (grant refused, or the app
  #     never reached CoreLocation) must not be waved through by "they differ".
  rc=0; b7_discrimination_ok always missing || rc=$?
  _check "D4 a missing observation FAILS" 1 "${rc}"
  rc=0; b7_discrimination_ok notDetermined whenInUse || rc=$?
  _check "D4b notDetermined FAILS" 1 "${rc}"

  # --- GATE 2 (completion). These fixtures exist because the discrimination
  #     gate above is BLIND to a drive that never ran: the tier marker is
  #     printed before any assertion, so `[b7] OBSERVED_TIER=` is present in a
  #     log whose two test bodies were skipped outright.
  #
  # A tiny writer, so each fixture states exactly which proofs its log carries.
  _b7_log() { # _b7_log <path> [marker ...]
    local path="$1"; shift
    {
      echo 'Xcode build done.                                           400.0s'
      echo '[b7] OBSERVED_TIER=always'
      local m
      for m in "$@"; do echo "${m}"; done
      echo '🎉 2 tests passed.'
    } > "${path}"
  }

  local always_log="${tmp}/c-always.log" wiu_log="${tmp}/c-wheninuse.log"

  # --- (C1) THE PASSING SHAPE: both proofs, in BOTH tier logs.
  _b7_log "${always_log}" "${COPY_MARKER}" "${PUBLISH_MARKER} tier=always"
  _b7_log "${wiu_log}" "${COPY_MARKER}" "${PUBLISH_MARKER} tier=whenInUse"
  got="$(b7_completion_failures "${always_log}" "${wiu_log}")"
  _check "C1 both proofs in both tier logs is COMPLETE" "" "${got}"

  # --- (C2) THE A3b FIXTURE, copy half. The whole lane can otherwise pass with
  #     the copy test skipped: the tier marker is printed before the first
  #     assertion, so gate 1 still sees it and still discriminates.
  _b7_log "${always_log}" "${PUBLISH_MARKER} tier=always"
  _b7_log "${wiu_log}" "${COPY_MARKER}" "${PUBLISH_MARKER} tier=whenInUse"
  got="$(b7_completion_failures "${always_log}" "${wiu_log}")"
  _check "C2 a missing COPY_OK is REFUSED" "always ${COPY_MARKER}" "${got}"

  # --- (C3) …and the publish half. This is the more expensive test to lose:
  #     an early return before the 240 s wire wait costs nothing and looks
  #     exactly like a fast, healthy run.
  _b7_log "${always_log}" "${COPY_MARKER}" "${PUBLISH_MARKER} tier=always"
  _b7_log "${wiu_log}" "${COPY_MARKER}"
  got="$(b7_completion_failures "${always_log}" "${wiu_log}")"
  _check "C3 a missing BACKGROUND_PUBLISH_OK is REFUSED" \
    "whenInUse ${PUBLISH_MARKER}" "${got}"

  # --- (C4) PRESENT IN ONE TIER ONLY. The second tier's whole drive was
  #     skipped. A gate that asked "did these markers appear anywhere" would
  #     let the first tier's evidence answer for the second — which is why the
  #     gate takes both logs and reports per tier.
  _b7_log "${always_log}" "${COPY_MARKER}" "${PUBLISH_MARKER} tier=always"
  _b7_log "${wiu_log}"
  got="$(b7_completion_failures "${always_log}" "${wiu_log}" | tr '\n' ';')"
  _check "C4 proofs in ONE tier only are REFUSED for the other" \
    "whenInUse ${COPY_MARKER};whenInUse ${PUBLISH_MARKER};" "${got}"

  # --- (C5) An absent or empty log is absence of evidence, never evidence —
  #     the `cp /tmp/flutter-ios-test.log` that preserves each run is `|| true`d
  #     by design, so "no log" is a reachable state and must fail closed.
  got="$(b7_missing_proofs "${tmp}/nope.log" | tr '\n' ';')"
  _check "C5 a MISSING log reports both proofs absent" \
    "${COPY_MARKER};${PUBLISH_MARKER};" "${got}"
  : > "${tmp}/empty.log"
  got="$(b7_missing_proofs "${tmp}/empty.log" | tr '\n' ';')"
  _check "C5b an EMPTY log reports both proofs absent" \
    "${COPY_MARKER};${PUBLISH_MARKER};" "${got}"

  # --- (C6) The publish marker must be matched as a PREFIX of its own line:
  #     the target appends ` tier=<name>`, and a whole-line match would find
  #     nothing on every real run.
  _b7_log "${always_log}" "${COPY_MARKER}" "${PUBLISH_MARKER} tier=always"
  got="$(b7_missing_proofs "${always_log}")"
  _check "C6 the trailing ' tier=<name>' does not defeat the match" "" "${got}"

  if (( fail != 0 )); then
    echo "run-b7-ios-auth-tier.sh --self-test: FAILED" >&2
    return 1
  fi
  echo "run-b7-ios-auth-tier.sh --self-test: all 21 fixtures passed (simctl" \
       "support is probed not assumed; the tier parser reports missing and" \
       "conflict distinctly; the discrimination gate rejects identical," \
       "swapped and absent observations; and the completion gate refuses a" \
       "run that exited 0 without printing both terminal proofs in BOTH tier" \
       "logs)."
  return 0
}

if [[ "${1:-}" == "--self-test" ]]; then
  run_self_test
  exit $?
fi

# ---------------------------------------------------------------------------
# Real run
# ---------------------------------------------------------------------------

SIM_UDID="${1:-}"
if [[ -z "${SIM_UDID}" || $# -gt 1 ]]; then
  echo "ERROR: usage: $0 <simulator-udid>  |  $0 --self-test" >&2
  exit 2
fi

readonly RELAY_URL="${HAVEN_E2E_RELAY:-ws://localhost:7777}"

# Same mandatory, no-default contract run-ios-sim-scenario.sh enforces: the
# receive path is compiled into the artifact, so the calling STEP has to state
# it rather than inherit one (CI_HARDENING_BACKLOG.md A7).
if [[ -z "${HAVEN_LIVE_SYNC:-}" ]]; then
  echo "ERROR: HAVEN_LIVE_SYNC is not set. This script compiles the app, so" >&2
  echo "       the calling step must state 'true' or 'false' in its env." >&2
  exit 2
fi
if [[ ! "${HAVEN_LIVE_SYNC}" =~ ^(true|false)$ ]]; then
  echo "ERROR: HAVEN_LIVE_SYNC must be exactly 'true' or 'false' (got '${HAVEN_LIVE_SYNC}')." >&2
  exit 2
fi
readonly LIVE_SYNC="${HAVEN_LIVE_SYNC}"

readonly REPO_ROOT="${SCRIPT_DIR}/../../.."
readonly HAVEN_DIR="${REPO_ROOT}/haven"
readonly SIM_RUNNER="${SCRIPT_DIR}/run-ios-sim-scenario.sh"

[[ -f "${HAVEN_DIR}/${SCENARIO_FILE}" ]] \
  || { echo "ERROR: drive target not found: ${HAVEN_DIR}/${SCENARIO_FILE}" >&2; exit 2; }
[[ -f "${SIM_RUNNER}" ]] \
  || { echo "ERROR: shared runner not found: ${SIM_RUNNER}" >&2; exit 2; }

echo "B7 iOS auth-tier lane — udid=${SIM_UDID} relay=${RELAY_URL} live_sync=${LIVE_SYNC}"

# --- Preflight: does THIS Xcode's simctl offer the Always grant? ------------
PRIVACY_USAGE="$(xcrun simctl help privacy 2>&1 || true)"
set +e
b7_simctl_supports_always "${PRIVACY_USAGE}"
SUPPORT_RC=$?
set -e
case "${SUPPORT_RC}" in
  0)
    echo "B7 preflight — 'xcrun simctl privacy' offers the location-always service."
    ;;
  1)
    echo "ERROR: this runner's 'xcrun simctl privacy' does NOT list the" >&2
    echo "       'location-always' service, so the Always tier cannot be granted" >&2
    echo "       and this lane cannot discriminate the two tiers. Do not paper" >&2
    echo "       over it by granting 'location' twice — that is the vacuous" >&2
    echo "       oracle this lane exists to prevent. Raise the runner image /" >&2
    echo "       Xcode version instead. Usage text seen:" >&2
    printf '%s\n' "${PRIVACY_USAGE}" | sed 's/^/       /' >&2
    exit 2
    ;;
  *)
    echo "ERROR: could not parse 'xcrun simctl help privacy' output — the" >&2
    echo "       preflight cannot tell 'Always is unsupported' from 'the probe" >&2
    echo "       is broken', and guessing either way is worse than stopping." >&2
    printf '%s\n' "${PRIVACY_USAGE}" | sed 's/^/       /' >&2
    exit 2
    ;;
esac

cd "${HAVEN_DIR}"

# --- Build ONCE. --------------------------------------------------------------
# The .app is needed BEFORE the first run so the privacy grant has an installed
# bundle to attach to. Each `flutter test` below rebuilds incrementally from the
# same derived data, so this costs one cold Xcode+Rust build for the lane rather
# than one per tier.
#
# The build is deliberately NOT bounded here: a hung or failed build is
# deterministic, and the caller's retry timeout is the backstop (same stance as
# run-ios-sim-scenario.sh's first-test watchdog, which also declines to watch
# the build).
echo "B7 — building the drive target once for the simulator ..."
flutter build ios \
  --simulator \
  --debug \
  --target "${SCENARIO_FILE}" \
  --dart-define=HAVEN_E2E_RELAY="${RELAY_URL}" \
  --dart-define=HAVEN_LIVE_SYNC="${LIVE_SYNC}"

APP_PATH=""
for candidate in build/ios/iphonesimulator/*.app; do
  [[ -d "${candidate}" ]] || continue
  if [[ -n "${APP_PATH}" ]]; then
    echo "ERROR: more than one .app under build/ios/iphonesimulator — refusing" >&2
    echo "       to guess which one to install." >&2
    exit 2
  fi
  APP_PATH="${candidate}"
done
[[ -n "${APP_PATH}" ]] \
  || { echo "ERROR: no .app produced under build/ios/iphonesimulator." >&2; exit 2; }
readonly APP_PATH
echo "B7 — built ${APP_PATH}"

# run_tier <tier-name> <simctl-service> <log-path>
#
# uninstall (clears any prior grant + data container) -> install -> grant ->
# drive. The shared runner is told to skip its own uninstall, which would
# otherwise erase the grant between this function and the app's first launch.
run_tier() {
  local tier="$1" service="$2" log="$3" rc=0

  echo ""
  echo "=== B7 tier '${tier}' (simctl privacy grant ${service}) ==============="

  xcrun simctl uninstall "${SIM_UDID}" "${BUNDLE_ID}" >/dev/null 2>&1 || true

  if ! xcrun simctl install "${SIM_UDID}" "${APP_PATH}"; then
    echo "ERROR: could not install ${APP_PATH} on ${SIM_UDID}." >&2
    return 2
  fi

  # A refused grant must be fatal. `simctl privacy` exits non-zero on a bad
  # service or an unknown bundle id, and this lane's entire discrimination is
  # downstream of it — `|| true` here would be the eighth instance of the
  # repo's recurring "guard passes vacuously" failure.
  if ! xcrun simctl privacy "${SIM_UDID}" grant "${service}" "${BUNDLE_ID}"; then
    echo "ERROR: 'xcrun simctl privacy ${SIM_UDID} grant ${service} ${BUNDLE_ID}'" >&2
    echo "       failed. The tier was never granted, so nothing below could" >&2
    echo "       have discriminated it." >&2
    return 2
  fi
  echo "B7 — granted '${service}' to ${BUNDLE_ID}"

  # Best-effort DIAGNOSTIC only, never a gate: locationd's client store is an
  # implementation detail with no stability promise, so it is printed to help
  # attribute a failure and is not parsed.
  local clients="${HOME}/Library/Developer/CoreSimulator/Devices/${SIM_UDID}/data/Library/Caches/locationd/clients.plist"
  if [[ -f "${clients}" ]]; then
    echo "B7 — locationd client store (diagnostic, not asserted):"
    plutil -p "${clients}" 2>/dev/null | grep -A 6 -F "${BUNDLE_ID}" | sed 's/^/       /' || true
  fi

  # Delegate: the shared runner owns the first-test watchdog, the narrowed
  # retry gate and the secret-leak scan. HAVEN_E2E_IOS_SKIP_UNINSTALL is the one
  # opt-in this lane needs from it (see this file's header).
  set +e
  HAVEN_LIVE_SYNC="${LIVE_SYNC}" \
  HAVEN_E2E_RELAY="${RELAY_URL}" \
  HAVEN_E2E_IOS_SKIP_UNINSTALL=1 \
    bash "${SIM_RUNNER}" "${SCENARIO_FILE}" "${SIM_UDID}"
  rc=$?
  set -e

  # Preserve this run's log before the next tier overwrites the shared path.
  cp /tmp/flutter-ios-test.log "${log}" 2>/dev/null || true

  return "${rc}"
}

ALWAYS_LOG="/tmp/b7-ios-always.log"
WHENINUSE_LOG="/tmp/b7-ios-wheninuse.log"
readonly ALWAYS_LOG WHENINUSE_LOG

TIER_RC=0
run_tier always location-always "${ALWAYS_LOG}" || TIER_RC=$?
if (( TIER_RC != 0 )); then
  echo "ERROR: the 'Always' tier run failed (rc=${TIER_RC}); observed tier =" \
       "$(b7_observed_tier "${ALWAYS_LOG}")" >&2
  exit "${TIER_RC}"
fi

run_tier whenInUse location "${WHENINUSE_LOG}" || TIER_RC=$?
if (( TIER_RC != 0 )); then
  echo "ERROR: the 'When In Use' tier run failed (rc=${TIER_RC}); observed tier =" \
       "$(b7_observed_tier "${WHENINUSE_LOG}")" >&2
  exit "${TIER_RC}"
fi

# --- The non-vacuity gate ----------------------------------------------------
FROM_ALWAYS="$(b7_observed_tier "${ALWAYS_LOG}")"
FROM_WHENINUSE="$(b7_observed_tier "${WHENINUSE_LOG}")"
readonly FROM_ALWAYS FROM_WHENINUSE

echo ""
echo "B7 — observed tiers:  after 'grant location-always' -> ${FROM_ALWAYS}"
echo "B7 —                  after 'grant location'        -> ${FROM_WHENINUSE}"

if ! b7_discrimination_ok "${FROM_ALWAYS}" "${FROM_WHENINUSE}"; then
  echo "ERROR: the two runs did not discriminate the CoreLocation tiers." >&2
  echo "       Expected always / whenInUse, got ${FROM_ALWAYS} / ${FROM_WHENINUSE}." >&2
  echo "       Both per-tier drive runs can PASS in this state — each one only" >&2
  echo "       checks the invariants for the tier it observed — so without this" >&2
  echo "       gate the lane would report green while proving nothing about the" >&2
  echo "       distinction it exists to prove." >&2
  case "${FROM_ALWAYS}:${FROM_WHENINUSE}" in
    missing:*|*:missing)
      echo "       A 'missing' observation means the drive target never printed" >&2
      echo "       its tier marker — look for a crash before the first test, or" >&2
      echo "       a renamed marker (the literal lives in this script and in" >&2
      echo "       haven/${SCENARIO_FILE}; they must be changed together)." >&2
      ;;
    notDetermined:*|*:notDetermined)
      echo "       'notDetermined' means the app saw NO authorization at all:" >&2
      echo "       the grant did not survive to first launch. The likeliest" >&2
      echo "       cause is the app being reinstalled between the grant and the" >&2
      echo "       launch — check that HAVEN_E2E_IOS_SKIP_UNINSTALL is still" >&2
      echo "       honoured by run-ios-sim-scenario.sh." >&2
      ;;
    conflict:*|*:conflict)
      echo "       'conflict' means one run printed two DIFFERENT tiers — the" >&2
      echo "       authorization changed under the app mid-run." >&2
      ;;
  esac
  exit 1
fi

# --- Gate 2: the terminal completion oracle (A3b) ----------------------------
# Both drives exited 0 above — which is NOT the same as both drives having RUN.
# `flutter test` reports success over a body that was skipped (`skip: true`,
# `markTestSkipped`) or returned early, and the tier marker cannot see it: it is
# printed near the top of test 1, BEFORE any assertion, so the gate above passes
# on a log whose two test bodies never executed. Each proof marker below is
# printed only after the last assertion of its own test, in EACH tier's run.
COMPLETION_FAILURES="$(b7_completion_failures "${ALWAYS_LOG}" "${WHENINUSE_LOG}")"
readonly COMPLETION_FAILURES
if [[ -n "${COMPLETION_FAILURES}" ]]; then
  echo "ERROR: a drive exited 0 WITHOUT printing its terminal proof(s):" >&2
  printf '%s\n' "${COMPLETION_FAILURES}" | sed 's/^/         missing in tier /' >&2
  echo "       This is NOT an assertion failure. A failed expect() makes the" >&2
  echo "       drive exit non-zero and is reported above with its own reason;" >&2
  echo "       reaching here means the run finished CLEANLY without executing" >&2
  echo "       the body that would have printed the marker — a self-skip, an" >&2
  echo "       early return, a suite that ran nothing (CI_HARDENING_BACKLOG.md" >&2
  echo "       A3b), or a renamed marker. Both literals live in this script and" >&2
  echo "       in haven/${SCENARIO_FILE}; change them together." >&2
  echo "       '${COPY_MARKER}' is printed after the last per-tier copy" >&2
  echo "       assertion; '${PUBLISH_MARKER}' only after a kind-445 was seen on" >&2
  echo "       the wire following a real AppLifecycleState.paused. Both are" >&2
  echo "       required ONCE PER TIER, because a proof printed by one tier's" >&2
  echo "       run says nothing about the other's." >&2
  echo "       Logs: ${ALWAYS_LOG} (always), ${WHENINUSE_LOG} (whenInUse)." >&2
  exit 1
fi

# Leave the simulator clean for whatever step runs next.
xcrun simctl uninstall "${SIM_UDID}" "${BUNDLE_ID}" >/dev/null 2>&1 || true

echo ""
echo "B7 — PASSED: 'Always' and 'When In Use' were granted separately, each was"
echo "     observed by the app through the production CoreLocation bridge, and"
echo "     each run asserted the honest per-tier copy plus continued background"
echo "     publishing across a real lifecycle pause."
