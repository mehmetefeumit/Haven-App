#!/usr/bin/env bash
#
# B1 runtime-proof orchestrator for the `e2e-fgs-publish` CI lane
# (docs/CI_HARDENING_BACKLOG.md Workstream B, item B1 — "FGS-with-live-foreground").
#
# ## What this lane exists to catch (P0-1)
#
# Backgrounding Haven on Android stops the main-isolate publish scheduler and
# hands publishing off to the flutter_foreground_task FGS isolate. That isolate
# then calls `CircleManagerFfi.newInstance` while the FOREGROUND
# `NostrCircleService` still holds the Rule-14 `LiveSessionGuard` — and both
# isolates share ONE OS process (no `android:process` in AndroidManifest.xml),
# therefore one Rust `LIVE_SESSIONS` registry. The acquire fails closed, the
# error is swallowed (`onStart FAILED`), `_circleManager` stays null, and every
# subsequent publish cycle returns immediately. `onStart` runs once; no retry.
#
# The defect was found by static analysis and adversarially re-verified, but had
# NEVER been observed at runtime, because nothing in CI ever ran the FGS publish
# path at all. The `e2e-background-catchup` lane looks like coverage but is not:
# it force-runs the WorkManager CATCH-UP worker (a receive-only, separate-process
# mechanism) and its `go_cold` helper kills the app (`am kill`) before waking it,
# so the foreground session is gone — which is precisely the contention this lane
# needs to preserve.
#
# ## The oracle
#
#   1. ASSERT the drive delivered the lifecycle pause (`[b1] PAUSE_DELIVERED`)
#      AND that the handoff completed (`[b1] HANDOFF_CONFIRMED`).
#   2. ASSERT `[BackgroundTask] Initialized (… locationSharing=true)` PRESENT
#      and `onStart FAILED` ABSENT.
#   3. ASSERT `Published to N/M due circle(s)` with N >= 1, WINDOWED to the
#      handoff→hold-complete span and PARSED, never grepped.
#   4. ASSERT the publishing PID equals the PID that handed off, and that the
#      service was not destroyed inside that same span.
#   5. ASSERT, from `dumpsys location`, that from the first background publish
#      onward Haven holds exactly ONE platform location request; that it is
#      never shorter than `kLocationPublishMinInterval - kBackgroundFixLeadTime`;
#      that it carries neither the foreground 1 m distance filter nor a
#      `minUpdateInterval=` suffix; and that any interval-0 one-shot beside it
#      belongs to a `trigger=watchdog` cycle — having first seen the foreground
#      1 s / 1 m request while the app WAS in the foreground.
#   6. ASSERT, from `dumpsys power`, that the scoped `Haven:publish` lock is
#      never held past `kPublishWakeLockTimeout`, and that the plugin's
#      permanent lock — which P2a keeps on purpose — is held throughout.
#   7. ASSERT the publishes are delivery-driven and spaced: at least two in the
#      window, at least one of them driven by a platform delivery, and every
#      such delivery at least 90 % of the registered-interval floor after the
#      registration that asked for it.
#   8. ASSERT the no-fix chain: with the GPS drip stopped and the device forced
#      into DEEP IDLE, a `trigger=watchdog` cycle still publishes — from the
#      last known position, after the one-shot it cannot answer — inside
#      `kStreamPositionMaxAge + kBackgroundRepeatInterval + kFirstDeliveryWait
#      + kOneShotLocationTimeout` plus slack.
#
# Steps 5-8 are the runtime proof of Phase P2a (docs/POWER_EFFICIENCY_PLAN.md
# 5.2). Before it, backgrounded Haven held a 1 Hz / 1 m stream AND took a 30 s
# HIGH_ACCURACY one-shot every 72 s tick; after it, the platform duty-cycles
# GNSS between publishes and the CPU hold is Haven's own and bounded. Every
# bound is derived from the Dart constants at load time, and every `dumpsys`
# grammar is pinned by a fixture in --self-test.
#
# Step 8 is the Doze-POLICY half of POWER_EFFICIENCY_PLAN.md 5.2 step (8), and
# deliberately only that half. It runs as a SECOND hold, opened by
# `[b1] IDLE_PHASE_BEGIN` AFTER `[b1] HOLD_COMPLETE` has closed the P2a window,
# so steps 5-7 still read exactly the steady-state span they always did and the
# forced-idle span is never mistaken for one.
#
# Not assertable here, in step 8 or anywhere else: AP SUSPENSION. The emulator
# never suspends its application processor, so "a delivery still wakes Dart once
# the AP is genuinely asleep" — the merge gate for P2b's removal of the
# permanent wake lock — stays a handset question (POWER_EFFICIENCY_PLAN.md 2.5).
# Doze POLICY and AP SUSPEND are different claims: the first is software the
# emulator really applies, the second is silicon it does not have.
#
# Each step exists to close a specific false-green route found in adversarial
# review:
#
# * Step 2 is POSITIVE. An earlier revision waited for the `onStart (starter=`
#   entry marker and then grepped for the ABSENCE of the failure marker — but
#   the entry marker prints at the top of `onStart`, before RustLib, the
#   keyring, and `CircleManagerFfi.newInstance`, so the absence check could read
#   seconds before the failure it was looking for. `Initialized (…
#   locationSharing=true)` is emitted only once the manager exists, so it proves
#   the Rule-14 acquire succeeded rather than merely failing to observe it.
#
# * Step 3 is windowed at BOTH ends. It opens at the handoff because a publish
#   emitted while the UI was still foregrounded is not the thing under test — it
#   is a Rule-14 single-writer violation, and counting it as success would
#   invert the lane's meaning. It closes at the hold because everything after
#   that is teardown, where the service is stopped deliberately (twice: the
#   resume takes the MLS session back by stopping it, then the post-test unmount
#   stops it again) — an EOF-bounded window reads those as the service dying
#   mid-proof. N is parsed because `Published to 0/1` is P0-1's own signature
#   and contains the marker substring.
#
# * Step 4 is the anti-vacuity check and the most important line in the file.
#   The FGS's foreground-active gate goes stale after 144s, so if the app
#   process dies and Android restarts the START_STICKY service into a FRESH
#   process, the acquire trivially succeeds and steps 2 and 3 both pass with NO
#   foreground session in existence — green while proving nothing. Same PID
#   means same Rust `LIVE_SESSIONS` registry, which is what makes the contention
#   real.
#
# There is deliberately NO relay-side line-count check; see the note at the foot
# of Phase 5 for why one was removed rather than kept as decoration.
#
# EXPECT THIS LANE TO FAIL ON ITS FIRST RUN. That is the deliverable: it converts
# P0-1 from static analysis into a reproducible red. Do not "fix" it by relaxing
# an assertion — see CLAUDE.md, Testing Requirements #5.
#
# Usage:
#   run-b1-fgs-publish.sh <apk> <target.dart>   run the lane (needs emulator-5554)
#   run-b1-fgs-publish.sh --self-test           hermetic predicate self-test
#
set -Eeuo pipefail

# Shared app-side failure predicate — `flutter drive` can exit 0 on a failed
# test (see drive-log-lib.sh). Sourced before the --self-test dispatch so the
# hermetic self-test runs against a fully-wired script.
# shellcheck source=tooling/e2e/ci/drive-log-lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/drive-log-lib.sh"

# ---------------------------------------------------------------------------
# Paths, package identity, and the power-oracle constants.
#
# Hoisted ABOVE the --self-test dispatch on purpose: the power oracles are
# pure functions over a logcat capture and a `dumpsys` sample file, the
# hermetic self-test drives them END TO END, and the constants they compare
# against are READ OUT OF THE DART SOURCE. All three have to be wired before
# the dispatch or the self-test would be validating a half-built script.
# ---------------------------------------------------------------------------
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR="${script_dir}"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
readonly REPO_ROOT
readonly PKG="com.oblivioustech.haven"

# logcat tag the power sampler stamps each sample with. It is what puts the
# samples and the drive's own markers on ONE ordered timeline, on the DEVICE's
# clock, without any host-side clock arithmetic (the B8 lane's trap).
readonly SAMPLE_TAG="b1power"
readonly SAMPLE_PERIOD_SECS=5
# The stamp as `logcat -v threadtime` prints it: liblog formats the tag as
# `%-8.*s: ` (logprint.cpp), so a 7-character tag gains a pad space before the
# colon. Matching `b1power: SAMPLE ` found no stamp at all in run 34488512808.
SAMPLE_STAMP="$(printf '%-8s: SAMPLE ' "${SAMPLE_TAG}")"
readonly SAMPLE_STAMP

readonly LOCATION_CONSTANTS_SRC="${REPO_ROOT}/haven/lib/src/constants/location.dart"

# Read `const Duration <name> = Duration(seconds: N);` out of the Dart source.
#
# Every bound below is DERIVED rather than typed here. A hand-typed 62 keeps
# passing after a deliberate change to the cadence — checking nothing, while
# looking exactly like a check. Empty output is a hard error at load time
# (below) rather than a silent 0.
dart_duration_secs() {
  local name="$1" depth="${2:-0}" secs alias
  secs="$(sed -n \
    "s/^const Duration ${name} = Duration(seconds: \([0-9]\{1,\}\));\$/\1/p" \
    "${LOCATION_CONSTANTS_SRC}" 2>/dev/null | head -1)"
  if [[ -n "${secs}" ]]; then
    printf '%s\n' "${secs}"
    return 0
  fi
  # `const Duration kStreamPositionMaxAge = kLocationPublishMaxInterval;` — the
  # ALIAS is the point of that declaration (the two constants are one number by
  # construction, and the Dart doc says so), so following it keeps the bound
  # derived instead of re-typing the number the alias exists to avoid. Depth-
  # bounded, so a cyclic edit fails at load time rather than recursing.
  (( depth < 4 )) || return 1
  alias="$(sed -n \
    "s/^const Duration ${name} = \([A-Za-z_][A-Za-z0-9_]*\);\$/\1/p" \
    "${LOCATION_CONSTANTS_SRC}" 2>/dev/null | head -1)"
  [[ -n "${alias}" ]] || return 1
  dart_duration_secs "${alias}" "$((depth + 1))"
}

if ! PUBLISH_MIN_INTERVAL_SECS="$(dart_duration_secs kLocationPublishMinInterval)" \
   || ! FIX_LEAD_SECS="$(dart_duration_secs kBackgroundFixLeadTime)" \
   || ! WAKE_LOCK_MAX_AGE_SECS="$(dart_duration_secs kPublishWakeLockTimeout)" \
   || ! STREAM_MAX_AGE_SECS="$(dart_duration_secs kStreamPositionMaxAge)" \
   || ! WATCHDOG_PERIOD_SECS="$(dart_duration_secs kBackgroundRepeatInterval)" \
   || ! FIRST_DELIVERY_WAIT_SECS="$(dart_duration_secs kFirstDeliveryWait)" \
   || ! ONE_SHOT_TIMEOUT_SECS="$(dart_duration_secs kOneShotLocationTimeout)"
then
  echo "run-b1-fgs-publish.sh: could not read the publish-cadence constants from \
${LOCATION_CONSTANTS_SRC}. The declarations moved or changed shape, so every bound \
below would be scanning nothing. Fix the extraction, never the bound." >&2
  exit 2
fi
readonly PUBLISH_MIN_INTERVAL_SECS FIX_LEAD_SECS WAKE_LOCK_MAX_AGE_SECS
readonly STREAM_MAX_AGE_SECS WATCHDOG_PERIOD_SECS FIRST_DELIVERY_WAIT_SECS
readonly ONE_SHOT_TIMEOUT_SECS

# The floor on the FGS's registered interval once it has published.
#
# `_ensureRegistration` aims at `earliestDue - kBackgroundFixLeadTime`, and for
# the circle that just published `earliestDue = publishStart + J` with the
# CSPRNG draw J in [kLocationPublishMinInterval, kLocationPublishMaxInterval].
# So the interval it asks for is `J - lead - delta` — [62, 158] s here, and a
# RETRY registration after a failed publish is `kBackgroundRepeatInterval -
# lead` = 62 s exactly. 72 would therefore red a CORRECT implementation on
# every draw below 82 s, about one in ten.
readonly MIN_FIX_INTERVAL_SECS=$((PUBLISH_MIN_INTERVAL_SECS - FIX_LEAD_SECS))

# The floor on the spacing between two delivery-driven publishes: 90 % of the
# registered-interval floor, because the interval is what the platform is ASKED
# for and delivery lands at `>= interval` minus nothing but measurement noise.
# floor(0.9 x 62) = 55; a healthy boundary run lands at ~55.8 s, so 56 would be
# a false-red generator.
readonly MIN_DELIVERY_GAP_SECS=$((MIN_FIX_INTERVAL_SECS * 9 / 10))

# Step 8's bound: how long the no-fix chain may take to publish once the GPS
# drip has stopped and the device is in deep idle.
#
# Every term is the length of one link in that chain, and every one of them is
# read out of the Dart source above:
#
#   kStreamPositionMaxAge     the cached stream fix must age out before the
#                             cycle stops being served from it,
#   kBackgroundRepeatInterval the watchdog tick granularity — the cycle can only
#                             start on a tick,
#   kFirstDeliveryWait        the cold-cache wait for a platform answer that
#                             will not come,
#   kOneShotLocationTimeout   the one-shot that cannot succeed, before
#                             `getLastKnownPosition()` finally answers.
#
# The last term is a MARGIN, not a bound: the encrypt, the relay ack and the
# shell's own force-idle round trip on a loaded emulator. It is the only
# hand-chosen number here, and it is deliberately additive so that no derived
# term can be quietly widened by tuning it.
readonly NO_FIX_SLACK_SECS=30
readonly NO_FIX_BOUND_SECS=$((STREAM_MAX_AGE_SECS + WATCHDOG_PERIOD_SECS \
  + FIRST_DELIVERY_WAIT_SECS + ONE_SHOT_TIMEOUT_SECS + NO_FIX_SLACK_SECS))

# ---------------------------------------------------------------------------
# VERBATIM markers (haven/lib/src/services/background_location_task.dart).
# Kept as fixed literals matched with `grep -aF`: logcat is binary-tainted and
# these strings contain regex metacharacters.
# ---------------------------------------------------------------------------
readonly MARK_ONSTART_FAILED='[BackgroundTask] onStart FAILED'
# The TERMINAL success outcome of onStart. The `onStart (starter=` entry line is
# deliberately NOT a constant here, because it is deliberately NOT asserted on:
# it prints at the TOP
# of onStart (background_location_task.dart:141), before RustLib.init, the
# keyring, the data dir, the identity load and `CircleManagerFfi.newInstance` —
# seconds of emulator work. Keying the oracle on it and then grepping for the
# ABSENCE of the failure marker reads inside that window and can pass while the
# failure is still in flight. This marker is emitted only after ALL of that
# succeeded (:240-244), and `locationSharing=true` is only constructible when
# `_circleManager != null` (:218-230) — i.e. when the Rule-14 acquire WORKED.
# That makes it a POSITIVE oracle for P0-1 rather than an absence check.
readonly MARK_INITIALIZED='[BackgroundTask] Initialized ('
readonly MARK_LOCSHARING_OK='locationSharing=true'
# The SECOND positive proof, and the normal one under the pause-time handoff.
#
# The service starts while the app is foregrounded, so at `onStart` the UI
# isolate still legitimately holds the session and `locationSharing=false` is
# CORRECT — Rule 14 permits exactly one live session per database per process.
# The acquire happens later, in the publish cycle, once `_onPaused` has handed
# the session over. This marker is emitted there and only after
# `_locationSharingService != null`, so like the one above it is constructible
# only when the Rule-14 acquire actually worked. Accepting either is not a
# weakening: both prove the same thing, at the two points it can legitimately
# happen.
readonly MARK_SESSION_ACQUIRED='[BackgroundTask] session acquired'
readonly MARK_PUBLISHED_PREFIX='[BackgroundTask] Published to '
readonly MARK_CYCLE_FAILED='[BackgroundTask] Publish cycle FAILED'
readonly MARK_ONDESTROY='[BackgroundTask] onDestroy'
# Emitted by the drive target at the instant it delivers a REAL
# AppLifecycleState.paused to MapShell's own observer, running the production
# `_onPaused()` handoff. MUST match `kPauseDeliveredMarker` in
# haven/integration_test/b1_fgs_live_foreground_test.dart VERBATIM.
readonly MARK_PAUSE='[b1] PAUSE_DELIVERED'
# Strictly later: printed only once the drive has itself confirmed, by polling
# real SharedPreferences, that `kForegroundActiveAtMsKey` actually reached 0 —
# i.e. that `_onPaused()` ran to COMPLETION rather than merely being dispatched.
# This, not the pause itself, is the moment the FGS's gate-3 foreground check
# stops rejecting it, so it is the correct window start for the publish oracle:
# windowing from the dispatch instead would open the window before the FGS was
# permitted to publish at all. Mirrors `kHandoffConfirmedMarker`.
readonly MARK_HANDOFF_OK='[b1] HANDOFF_CONFIRMED'
# Closes the proof window. Printed by the drive the instant its hold ends and
# BEFORE it restores `resumed`, so everything after it is teardown. That
# distinction is load-bearing rather than tidy: resuming runs the production
# `_onResumed()`, which takes the MLS session back — and on Android taking it
# back means STOPPING the foreground service (mls_session_handover.dart), which
# emits `onDestroy`. flutter_test's post-test unmount then stops it again. An
# EOF-bounded window sees those two legitimate stops as "the service died inside
# the window it was supposed to publish in" and fails a passing lane. MUST match
# `kHoldCompleteMarker` in the drive target VERBATIM.
readonly MARK_HOLD_DONE='[b1] HOLD_COMPLETE'
# Step 8's own window. Printed by the drive AFTER MARK_HOLD_DONE — the P2a
# window is closed by then, so the forced-idle span is never read as steady
# state — and it is what tells THIS script to stop the GPS drip and force the
# device into deep idle. MUST match `kIdlePhaseBeginMarker` /
# `kIdlePhaseEndMarker` in the drive target VERBATIM.
readonly MARK_IDLE_BEGIN='[b1] IDLE_PHASE_BEGIN'
readonly MARK_IDLE_END='[b1] IDLE_PHASE_END'
# This script's own device-stamped record that deep idle actually ENGAGED,
# carrying the authoritative `dumpsys deviceidle get deep` read-back.
#
# The read-back is the whole point. `dumpsys deviceidle force-idle` answers a
# device whose deep idle is disabled with "Unable to go deep idle; not enabled"
# and exits 0 all the same, so keying step 8 on the command instead of on the
# state would let a lane that never dozed report the ordinary watchdog as a Doze
# result — a green row proving nothing, which is the failure mode this file
# spends most of its length avoiding.
readonly MARK_IDLE_FORCED='IDLE_FORCED state='
readonly MARK_TRIGGER_WATCHDOG='[BackgroundTask] cycle trigger=watchdog'
# The registration the cadence oracle measures its deliveries from. Logged in
# step 7c of `_publishCycle`, BEFORE the fix and the publish of the same cycle,
# so the registration that produced a delivery is the one logged in the cycle
# BEFORE it.
readonly MARK_REG_ARMED='[BackgroundTask] registration armed ('
# The drive prints this, then waits for BARRIER_FILE, before it mounts anything
# that can hold a platform location registration (see the barrier driver in
# Phase 4). MUST match `kBroadcastBarrierAwaitMarker` and
# `kBroadcastBarrierFileName` in the drive target VERBATIM. Relative to the
# directory `run-as` starts in — the app's data dir — so it is the drive's
# `getApplicationSupportDirectory()` (Context.getFilesDir) by construction.
readonly MARK_BARRIER_AWAIT='[b1] AWAITING_BROADCAST_BARRIER'
readonly BARRIER_FILE='files/b1_broadcast_barrier'

# Extract the publish COUNT (N of "Published to N/M due circle(s)") from the
# highest-N line in a log. Emits nothing when no line matches; callers treat
# empty as "no publish cycle has reported yet".
#
# Highest-N rather than last-N: the FGS logs one line per cycle and a later
# cycle can legitimately report 0 (nothing due yet on its independent per-circle
# jittered schedule — see `PerCircleDueTracker`). Taking the last line would
# make a genuine success flap on cycle timing.
max_published_count() {
  local logfile="$1"
  { grep -aoE 'Published to [0-9]+/[0-9]+ due circle' "${logfile}" 2>/dev/null \
      | grep -aoE '[0-9]+/' | tr -d '/' | sort -n | tail -1; } || true
}

# Print every line from the FIRST occurrence of <start> up to, but NOT
# including, the first <end> at or after it. Falls back to EOF when <end> never
# appears.
#
# The OPEN is what keeps a publish emitted while the UI was still foregrounded
# out of the count — that is not the thing under test, it is a Rule-14
# single-writer violation being read as success.
#
# The CLOSE is what keeps the drive's teardown out, where the FGS is destroyed
# twice over, legitimately (see MARK_HOLD_DONE). Without it, "did the service
# survive its publish window" degrades into "was the service ever stopped,
# including on the way out".
#
# The EOF fallback is the conservative direction: a drive that died before
# printing the close leaves the widest window, so a truncated run fails rather
# than passing on a window that silently shrank to nothing. Such a run also
# trips `drive_failed`.
#
# `index()` rather than a regex: the markers contain `[`, `(` and other
# metacharacters.
window_between_markers() {
  local logfile="$1" start="$2" end="$3"
  awk -v s="${start}" -v e="${end}" '
    !f { if (index($0, s)) f = 1; else next }
    f && index($0, e) { exit }
    f
  ' "${logfile}" 2>/dev/null || true
}

# Print the PID column of the first line containing <marker>.
#
# `logcat -v threadtime` columns: date time PID TID LEVEL TAG: message.
# Used to prove the FGS publish came from the SAME OS process as the drive's
# own foreground isolate — see the caller for why that is the load-bearing
# anti-vacuity check in this lane.
pid_of_marker() {
  local logfile="$1" marker="$2"
  { awk -v m="${marker}" 'index($0, m) { print $3; exit }' "${logfile}" 2>/dev/null; } || true
}

# ===========================================================================
# POWER ORACLES (steps 5-7) — the `dumpsys` half of the lane.
#
# ## What they read
#
# One power SAMPLE is one `adb shell` invocation that stamps logcat, prints the
# DEVICE clock, and dumps `location` and `power`. The stamp is what makes the
# samples orderable against the drive's own markers without any host-side clock
# arithmetic: `[b1] HANDOFF_CONFIRMED` and `b1power : SAMPLE 17` are two lines
# in ONE logcat capture, so "which samples are before the handoff" is a question
# about line order, not about two clocks agreeing. (A host-clock sampler is the
# trap B8 was built around.)
#
# ## The grammars, and why they are fixtures
#
# Both dumps are `toString()` output of AOSP classes, i.e. an unversioned
# interface that can change under us:
#
#   `LocationProviderManager.Registration.toString` (android14-release :705-726)
#       <uid>/<package>[/<listener>] [bg] <LocationRequest>
#   `LocationRequest.toString` (:844-905), as the API-34 image prints it
#       Request[@<TimeUtils.formatDuration> HIGH_ACCURACY
#               (, minUpdateInterval=<duration> only when < interval)
#               (, minUpdateDistance=<meters> only when > 0)
#               (, WorkSource{<uid> <package>})]
#   `PowerManagerService.WakeLock.toString` (:5366-5396)
#       PARTIAL_WAKE_LOCK              'Haven:publish' ACQ=-12s345ms (uid=…)
#       — `getLockLevelString()` pads the level to 30 columns, so the quote
#       sits 14 spaces after `PARTIAL_WAKE_LOCK`, never one; ` LONG` follows
#       the age once a lock has been held past a minute
#   `TimeUtils.formatDuration` (fieldLen 0)
#       (+|-)(Nd)?(Nh)?(Nm)?Ns Nms; (+|-)Nms alone under one second; and the
#       bare string "0" for a zero duration
#
# Every one of those — and the logcat stamp — is pinned by a fixture in
# --self-test, so a platform text change lands as a red parser rather than as an
# oracle that quietly stops matching anything. Fixtures that agreed with the
# parser on a grammar the platform does not print are how run 34488512808 went
# red on a healthy sampler, so the stamp and registration fixtures include lines
# copied from that run's capture. At RUN time the same shape is protected twice
# over: an unparseable `Request[…]` is a hard failure (never a skipped line),
# and the anti-vacuity check below fails a capture in which the parser found no
# foreground request at all.
#
# ## What is NOT proven here
#
# AP suspension. The emulator never suspends its application processor, so this
# lane can show that the FGS asks the platform for a long-interval fix and that
# the scoped lock is bounded — it cannot show that a delivery still wakes Dart
# once the AP is genuinely asleep. That question belongs to a handset
# (docs/POWER_EFFICIENCY_PLAN.md 2.5), and it is why the permanent plugin wake
# lock is still held here and asserted PRESENT rather than absent.
# ===========================================================================

# `TimeUtils.formatDuration` token -> integer milliseconds.
#
# Returns 1 (printing nothing) on anything that is not that grammar, which is
# how a platform text change reaches the caller as a failure. Note the trailing
# field really is "<millis>ms": `printFieldLocked(…, millis, 'm', …)` then a
# literal 's'. Under one second the seconds field is skipped too (it prints only
# after a larger field or when non-zero), so a lock sampled inside its first
# second reads `ACQ=-326ms` — rejecting that reds step 6 by sampling chance.
formatted_duration_ms() {
  local tok="$1" sign=1 body d h m s ms
  if [[ "${tok}" == "0" ]]; then
    printf '0\n'
    return 0
  fi
  case "${tok}" in
    -*) sign=-1 ;;
    +*) sign=1 ;;
    *) return 1 ;;
  esac
  body="${tok:1}"
  if [[ "${body}" =~ ^([0-9]{1,3})ms$ ]]; then
    printf '%d\n' "$((sign * 10#${BASH_REMATCH[1]}))"
    return 0
  fi
  [[ "${body}" =~ ^(([0-9]+)d)?(([0-9]+)h)?(([0-9]+)m)?([0-9]+)s([0-9]+)ms$ ]] || return 1
  d=$((10#${BASH_REMATCH[2]:-0}))
  h=$((10#${BASH_REMATCH[4]:-0}))
  m=$((10#${BASH_REMATCH[6]:-0}))
  s=$((10#${BASH_REMATCH[7]}))
  ms=$((10#${BASH_REMATCH[8]}))
  printf '%d\n' "$((sign * ((((d * 24 + h) * 60 + m) * 60 + s) * 1000 + ms)))"
}

# Split every LIVE Haven LocationManager registration in samples [lo, hi] into
# "<sample>\t<duration-token>\t<minUpdateDistance|->\t<request>".
#
# Two lines in `dumpsys location` look exactly like a registration of ours and
# are not one, and BOTH would break the oracles rather than merely add noise:
#
#   * `service: ProviderRequest[@… WorkSource{<uid> <pkg>}]` — the provider's
#     MERGED request. It names our package and contains "Request[" as a
#     substring, so it would read as a second concurrent registration. The
#     leading SPACE in " Request[" excludes it (`ProviderRequest[` has none).
#   * `gps provider +registration <uid>/<pkg> -> Request[gps @+1s0ms …
#     minUpdateDistance=1.0]` — the Event Log REPLAYING a registration that has
#     since been cancelled. It keeps printing the foreground 1 s / 1 m request
#     for the rest of the run, so it would resurrect the very request the
#     background assertion says is gone. Anchoring on `CallerIdentity.toString`
#     at the START of the line — which is where `Registration.toString` puts it
#     and where the event log does not — excludes it.
#
# An `(inactive)` suffix is deliberately NOT excluded: a registration that still
# exists is still one Haven has not released.
#
# The package match is anchored at BOTH ends. A prefix match would count
# `<pkg>.test` — the instrumentation package this very lane installs alongside
# the app — as one of ours, and a second "Haven" registration is a hard failure
# in the oracle below. `CallerIdentity.toString` puts an attribution tag behind
# a `/`, the historical-aggregate line a `:`, and nothing else can follow the
# package name but a space or the end of the line.
_location_request_fields() {
  local samplefile="$1" lo="$2" hi="$3"
  awk -v pkg="${PKG}" -v lo="${lo}" -v hi="${hi}" '
    /^=== SAMPLE n=/ {
      n = $0
      sub(/^=== SAMPLE n=/, "", n)
      sub(/[^0-9].*$/, "", n)
      n += 0
      inrange = (n >= lo && n <= hi)
      next
    }
    !inrange { next }
    match($0, /^[ \t]*[0-9]+\//) == 0 { next }
    { identity = substr($0, RSTART + RLENGTH) }
    index(identity, pkg) != 1 { next }
    { after = substr(identity, length(pkg) + 1, 1) }
    after != "" && after != "/" && after != ":" && after != " " { next }
    { at = index($0, " Request[") }
    at == 0 { next }
    {
      req = substr($0, at + 9)
      closing = index(req, "]")
      if (closing == 0) { print n "\tGRAMMAR\t-\t" $0; next }
      req = substr(req, 1, closing - 1)
      a = index(req, "@")
      if (a == 0) { print n "\tGRAMMAR\t-\t" req; next }
      tail = substr(req, a + 1)
      sp = index(tail, " ")
      dur = (sp == 0) ? tail : substr(tail, 1, sp - 1)
      dist = "-"
      k = index(req, "minUpdateDistance=")
      if (k > 0) {
        dist = substr(req, k + 18)
        c = index(dist, ",")
        if (c > 0) dist = substr(dist, 1, c - 1)
      }
      print n "\t" dur "\t" dist "\t" req
    }
  ' "${samplefile}" 2>/dev/null || true
}

# As above, with the duration token resolved to milliseconds:
# "<sample>|<interval-ms>|<minUpdateDistance|->|<request>". An interval of
# "GRAMMAR" means the line did not parse and is a hard failure for every caller.
location_request_records() {
  local samplefile="$1" lo="$2" hi="$3" n tok dist req ms
  while IFS=$'\t' read -r n tok dist req; do
    if ms="$(formatted_duration_ms "${tok}")"; then
      printf '%s|%s|%s|%s\n' "${n}" "${ms}" "${dist}" "${req}"
    else
      printf '%s|GRAMMAR|%s|%s\n' "${n}" "${dist}" "${req}"
    fi
  done < <(_location_request_fields "${samplefile}" "${lo}" "${hi}")
}

# A held wake lock's line in `dumpsys power`: the padded level, then the quoted
# tag. One or more spaces, because only PROXIMITY_SCREEN_OFF_WAKE_LOCK fills the
# 30-column level field; a single-space match saw no lock in run 34488512808.
readonly WAKE_LOCK_LINE_ERE="_WAKE_LOCK +'"

# "<sample>\t<tag>\t<ACQ token>" for every HELD wake lock in samples [lo, hi].
#
# Keyed on the LOCK LEVEL plus the quoted tag ("PARTIAL_WAKE_LOCK … 'x'"), which
# `WakeLock.toString` always prints, rather than on `ACQ=`, which it prints only
# once the lock has been notified. Keying on `ACQ=` would make a lock that
# printed without one DISAPPEAR, and "the plugin lock went away" is a very
# different finding from "we could not read its age".
_wake_lock_fields() {
  local samplefile="$1" lo="$2" hi="$3"
  awk -v lo="${lo}" -v hi="${hi}" -v q="'" -v wl="${WAKE_LOCK_LINE_ERE}" '
    /^=== SAMPLE n=/ {
      n = $0
      sub(/^=== SAMPLE n=/, "", n)
      sub(/[^0-9].*$/, "", n)
      n += 0
      inrange = (n >= lo && n <= hi)
      next
    }
    !inrange { next }
    $0 !~ wl { next }
    {
      q1 = index($0, q)
      rest = substr($0, q1 + 1)
      q2 = index(rest, q)
      if (q2 == 0) { print n "\tGRAMMAR\t" $0; next }
      a = index($0, "ACQ=")
      if (a == 0) { print n "\t" substr(rest, 1, q2 - 1) "\tNOACQ"; next }
      tail = substr($0, a + 4)
      sp = index(tail, " ")
      print n "\t" substr(rest, 1, q2 - 1) "\t" ((sp == 0) ? tail : substr(tail, 1, sp - 1))
    }
  ' "${samplefile}" 2>/dev/null || true
}

# "<sample>|<tag>|<held-for-ms>" per held wake lock. `ACQ=` is the acquire time
# MINUS now, so the age is the negation.
wake_lock_records() {
  local samplefile="$1" lo="$2" hi="$3" n tag tok ms
  while IFS=$'\t' read -r n tag tok; do
    if [[ "${tag}" == "GRAMMAR" ]]; then
      printf '%s|GRAMMAR|%s\n' "${n}" "${tok}"
    elif ms="$(formatted_duration_ms "${tok}")"; then
      printf '%s|%s|%s\n' "${n}" "${tag}" "$((-ms))"
    else
      # The tag survives an unreadable age, so "the lock is held" and "we can
      # read how long for" stay separate findings.
      printf '%s|%s|UNREADABLE\n' "${n}" "${tag}"
    fi
  done < <(_wake_lock_fields "${samplefile}" "${lo}" "${hi}")
}

# One sample's raw `date; dumpsys location; dumpsys power` output on stdin ->
# the lines the parsers read, under a `=== SAMPLE n=<n> …` header.
#
# Filtered on the HOST, not the device, and before anything is written:
# `dumpsys location` prints the active position, and the artifact this feeds
# has no business carrying coordinates when the assertions need only
# registration and wake-lock lines. It is deliberately LOOSER than the parser —
# it keeps every line naming the package beside a `Request[`, including the
# Event Log's replays of long-cancelled registrations — so the artifact still
# shows the registration history for triage while the parser (which anchors on
# the caller identity at the start of a line) counts only the live ones.
#
# A function rather than inline in the sampler so --self-test can drive it: a
# filter that drops a line the parser needs is invisible to every parser
# fixture, and that is exactly how run 34488512808 captured no wake lock at all.
filter_power_sample() {
  awk -v n="$1" -v pkg="${PKG}" -v wl="${WAKE_LOCK_LINE_ERE}" '
    NR == 1 { print "=== SAMPLE n=" n " device-clock=" $0 " ==="; next }
    $0 ~ wl { print; next }
    index($0, pkg) && index($0, " Request[") { print }
  '
}

# The index of every sample the sampler actually WROTE in [lo, hi], ascending.
sample_indices() {
  local samplefile="$1" lo="$2" hi="$3"
  awk -v lo="${lo}" -v hi="${hi}" '
    /^=== SAMPLE n=/ {
      n = $0
      sub(/^=== SAMPLE n=/, "", n)
      sub(/[^0-9].*$/, "", n)
      n += 0
      if (n >= lo && n <= hi) print n
    }
  ' "${samplefile}" 2>/dev/null || true
}

# Highest sample index whose logcat stamp precedes the FIRST line containing
# <marker>; 0 when no sample precedes it, nothing at all when <marker> is
# absent (so a caller can tell the two apart).
last_sample_before() {
  local logfile="$1" marker="$2"
  awk -v m="${marker}" -v tag="${SAMPLE_STAMP}" '
    BEGIN { last = 0 }
    index($0, m) { print last; found = 1; exit }
    { i = index($0, tag); if (i > 0) last = substr($0, i + length(tag)) + 0 }
    END { if (!found) exit 1 }
  ' "${logfile}" 2>/dev/null || true
}

# Lowest sample index whose logcat stamp FOLLOWS the first line containing
# <marker>; empty when there is none.
first_sample_after() {
  local logfile="$1" marker="$2"
  awk -v m="${marker}" -v tag="${SAMPLE_STAMP}" '
    !seen { if (index($0, m)) seen = 1; next }
    { i = index($0, tag); if (i > 0) { print substr($0, i + length(tag)) + 0; exit } }
  ' "${logfile}" 2>/dev/null || true
}

# "<sample>|<trigger>" for every sample stamp in the capture: the trigger of the
# most recent `[BackgroundTask] cycle trigger=` line at or before that stamp, or
# `none` when no cycle had started yet.
#
# What makes the interval-0 carve-out safe rather than a hole.
# `getCurrentLocation()`'s one-shot carries no interval at all and so prints as
# `Request[gps @0 …]`; P2a keeps it, but ONLY as the cache-miss fallback the
# watchdog falls back to. The request P2a retired — a 30 s HIGH_ACCURACY
# one-shot on EVERY cycle, delivery-driven ones included — has exactly the same
# printed shape, so excluding `@0` from the concurrency count without asking
# WHICH cycle it belongs to lets that regression sit beside the long
# registration with the lane still green.
#
# Line order, not clock arithmetic: the sampler stamps logcat from the device in
# the same round trip that takes the dump, so "which cycle was running when this
# sample was taken" is a question about position in one capture.
sample_trigger_context() {
  awk -v tag="${SAMPLE_STAMP}" -v m='[BackgroundTask] cycle trigger=' '
    {
      i = index($0, m)
      if (i > 0) {
        last = substr($0, i + length(m))
        sub(/[ \t\r].*$/, "", last)
        next
      }
    }
    {
      i = index($0, tag)
      if (i > 0) {
        print (substr($0, i + length(tag)) + 0) "|" (last == "" ? "none" : last)
      }
    }
  ' "$1" 2>/dev/null || true
}

# The first `Published to N/M` line with N >= 1, verbatim. Used as the opening
# boundary of the steady-state assertions: before the first publish the FGS is
# legitimately allowed a short registration (everything is already due, so the
# interval formula floors), and asserting the steady state across that would be
# asserting it where it does not hold.
first_successful_publish_line() {
  awk '
    { i = index($0, "Published to ") }
    i == 0 { next }
    { n = substr($0, i + 13); sub(/\/.*$/, "", n); if (n + 0 >= 1) { print; exit } }
  ' "$1" 2>/dev/null || true
}

# How many cycles reported a publish to at least one circle.
successful_publish_count() {
  awk '
    { i = index($0, "Published to ") }
    i == 0 { next }
    { n = substr($0, i + 13); sub(/\/.*$/, "", n); if (n + 0 >= 1) c++ }
    END { print c + 0 }
  ' "$1" 2>/dev/null || echo 0
}

# Milliseconds from the registration that PRODUCED a delivery to that delivery,
# one line per delivery-driven cycle that went on to publish.
#
# Anchored on the REGISTRATION, not on the previous delivery. A
# delivery-to-delivery measurement needs TWO delivery-driven publishes inside
# one window, and a healthy hold contains exactly one: the hold is sized for
# ">= 1 delivery-driven publish" (`kLocationPublishMaxInterval` plus slack), and
# a second one needs two CSPRNG draws summing under that, which J ~ U[72, 168]
# does on roughly one run in six. Seeding `prev` on the first publish therefore
# yielded N-1 = 0 gaps and an empty loop on ~83 % of HEALTHY runs — an oracle
# that self-disables rather than flaking, which is worse, because it reports a
# check it never ran. The registration precedes its own delivery by
# construction, so this pair exists on every delivery-driven publish there is.
#
# Anchored on the ARM rather than on the publish of the same cycle: the publish
# line trails the arm by that cycle's fix + encrypt + ack + fetch latency, and
# at the boundary draw (I = 62 s) that latency would spend the entire 7 s the
# 90 % floor allows and red a correct run under emulator load. The arm is also
# the honest subject — the interval is what the platform was ASKED for.
#
# A delivery that did not lead to a publish is not a cadence point, and neither
# is any other trigger (`watchdog`, `paused-signal`, `pending-delivery`) — the
# whole claim is about the delivery-driven path. A delivery-driven publish with
# NO registration before it in the window is emitted as `NOARM`: unmeasurable,
# which the caller FAILS rather than skips.
delivery_gaps_after_registration() {
  awk '
    function ts(dm, hms,   md, t, mo, dy, cum, i) {
      split(dm, md, "-"); split(hms, t, ":")
      mo = md[1] + 0; dy = md[2] + 0; cum = 0
      for (i = 1; i < mo; i++) cum += mlen[i]
      return (cum + dy) * 86400 + t[1] * 3600 + t[2] * 60 + t[3]
    }
    BEGIN {
      # Day lengths only ever resolve a midnight rollover inside one ~20-minute
      # run, so the year (and the leap day) cannot matter. A run that somehow
      # produced a NEGATIVE gap is reported as one and fails the caller rather
      # than being wrapped into a plausible number.
      split("31 28 31 30 31 30 31 31 30 31 30 31", mlen, " ")
      armed = -1; pending = -1; pending_arm = -1
    }
    index($0, "[BackgroundTask] registration armed (") { armed = ts($1, $2); next }
    index($0, "[BackgroundTask] cycle trigger=") {
      if (index($0, "trigger=delivery") > 0) {
        pending = ts($1, $2); pending_arm = armed
      } else {
        pending = -1
      }
      next
    }
    {
      i = index($0, "Published to ")
      if (i == 0 || pending < 0) next
      n = substr($0, i + 13); sub(/\/.*$/, "", n)
      if (n + 0 < 1) next
      if (pending_arm < 0) print "NOARM"
      else printf "%d\n", int((pending - pending_arm) * 1000 + 0.5)
      pending = -1
    }
  ' "$1" 2>/dev/null || true
}

# Why no sample could be placed after a marker. Samples on disk with no stamp
# in the capture is a stamp-grammar mismatch, not a dead sampler — the cause
# run 34488512808 reported as "the sampler died" while it had written 113.
no_sample_cause() {
  local logfile="$1" samplefile="$2" written stamped
  written="$(grep -c '^=== SAMPLE n=' "${samplefile}" 2>/dev/null || true)"
  stamped="$(grep -acF -- "${SAMPLE_STAMP}" "${logfile}" 2>/dev/null || true)"
  if (( ${written:-0} > 0 && ${stamped:-0} == 0 )); then
    printf "the sampler wrote %s sample(s) but the capture holds no '%s' stamp: \
the stamp grammar changed, the sampler did not die\n" "${written}" "${SAMPLE_STAMP}"
  else
    printf 'the sampler died, or the hold ended inside one sample period\n'
  fi
}

# ---------------------------------------------------------------------------
# Oracle step 5 — ONE long-interval platform request while backgrounded.
#
# Prints `FAIL: …` for each violation and returns 1 if there was any; prints
# `  ` -prefixed evidence otherwise. Split out from Phase 5 so --self-test can
# drive it end to end over synthetic captures rather than per-predicate.
# ---------------------------------------------------------------------------
assert_registration_oracle() {
  local logfile="$1" samplefile="$2" windowfile="$3"
  local rc=0 pre_max post_min hold_max pub_line
  local n ms dist req ui_seen=0 long_seen=0
  local ctx_n ctx_trigger
  local -A trigger_at=()

  pre_max="$(last_sample_before "${logfile}" "${MARK_HANDOFF_OK}")"
  if [[ -z "${pre_max}" ]]; then
    echo "FAIL: no '${MARK_HANDOFF_OK}' in the capture, so no sample can be classified \
as before or after the handoff."
    return 1
  fi
  pub_line="$(first_successful_publish_line "${windowfile}")"
  if [[ -z "${pub_line}" ]]; then
    echo "FAIL: no successful publish in the proof window, so the steady state the \
registration oracle describes was never entered."
    return 1
  fi
  post_min="$(first_sample_after "${logfile}" "${pub_line}")"
  if [[ -z "${post_min}" ]]; then
    echo "FAIL: no power sample was taken after the first publish — \
$(no_sample_cause "${logfile}" "${samplefile}"). Every steady-state assertion below \
would be vacuous."
    return 1
  fi
  hold_max="$(last_sample_before "${logfile}" "${MARK_HOLD_DONE}")"
  # No close marker means the drive died mid-hold; run to the end of the
  # capture, which is the conservative direction (more samples asserted over).
  [[ -n "${hold_max}" ]] || hold_max=999999

  # (a) ANTI-VACUITY. A dump in which the parser sees NOTHING must never read as
  #     "no fast request": it reads as a broken parser. The foreground stream is
  #     1 s / 1 m, so it is the positive control, and the whole background claim
  #     is that this exact request is gone afterwards.
  while IFS='|' read -r n ms dist req; do
    if [[ "${ms}" == "GRAMMAR" ]]; then
      echo "FAIL: could not parse a Haven location request in sample ${n}: '${req}'. \
The dumpsys grammar changed; fix the parser and its fixtures, never the assertion."
      rc=1
    elif [[ "${dist}" == "1.0" && "${ms}" == "1000" ]]; then
      ui_seen=1
    fi
  done < <(location_request_records "${samplefile}" 1 "${pre_max}")
  if (( ui_seen == 0 )); then
    echo "FAIL: no sample before the handoff showed the foreground 1 s / 1 m request \
(@+1s0ms … minUpdateDistance=1.0) in samples 1-${pre_max}. Either the UI never held \
the stream, or the sampler/parser saw nothing — in which case every 'no fast request' \
finding below would be vacuous."
    rc=1
  fi

  # Which cycle each sample was taken during — the input to the interval-0
  # attribution below. Read over the WHOLE capture, because a sample's cycle is
  # whichever one last announced itself before it, regardless of window.
  while IFS='|' read -r ctx_n ctx_trigger; do
    trigger_at[${ctx_n}]="${ctx_trigger}"
  done < <(sample_trigger_context "${logfile}")

  # (b)-(d) The steady state, from the first publish to the close of the window.
  local -a positive_per_sample=()
  while IFS='|' read -r n ms dist req; do
    if [[ "${ms}" == "GRAMMAR" ]]; then
      echo "FAIL: could not parse a Haven location request in sample ${n}: '${req}'. \
The dumpsys grammar changed; fix the parser and its fixtures, never the assertion."
      rc=1
      continue
    fi
    if [[ "${dist}" == "1.0" ]]; then
      echo "FAIL: sample ${n} still shows the foreground 1 m distance filter while \
backgrounded: '${req}'. The UI stream was not released at the handoff, so the FGS's \
long-interval request is running ON TOP of a 1 Hz one."
      rc=1
    fi
    # `LocationRequest.toString` prints `minUpdateInterval=` ONLY when the
    # fastest interval is below the interval, and geolocator's background
    # profile sets the two equal (`LocationManagerClient.java:182-185`). Its
    # presence therefore means the platform has been given permission to deliver
    # faster than the duty cycle the interval buys — the duty cycle IS the
    # saving, so a faster-than-asked delivery spends it.
    if [[ "${req}" == *"minUpdateInterval="* ]]; then
      echo "FAIL: sample ${n} shows a Haven location request carrying a \
minUpdateInterval= suffix: '${req}'. That suffix is printed only when the fastest \
interval is BELOW the interval, so the platform may deliver faster than the \
registration's own duty cycle."
      rc=1
    fi
    if (( ms > 0 && ms < MIN_FIX_INTERVAL_SECS * 1000 )); then
      echo "FAIL: sample ${n} shows a Haven location request at $((ms / 1000)) s, below \
the ${MIN_FIX_INTERVAL_SECS} s floor (kLocationPublishMinInterval ${PUBLISH_MIN_INTERVAL_SECS} s \
- kBackgroundFixLeadTime ${FIX_LEAD_SECS} s): '${req}'. The FGS is asking the platform \
to run GNSS faster than the publish cadence can ever use."
      rc=1
    fi
    if (( ms >= MIN_FIX_INTERVAL_SECS * 1000 )); then
      long_seen=1
    fi
    # An interval of exactly 0 is the ONE-SHOT (`getCurrentLocation()`, whose
    # request carries no interval at all), not a stream. P2a keeps it as the
    # cache-miss fallback the watchdog falls back to, so it is deliberately not
    # counted as a concurrent registration — but ONLY when it is attributable to
    # that fallback. The request P2a retired (a 30 s HIGH_ACCURACY one-shot per
    # tick) prints identically, so an unattributed carve-out would let the whole
    # runtime half of this phase's saving regress with the lane still green.
    if (( ms == 0 )) && [[ "${trigger_at[${n}]:-none}" != "watchdog" ]]; then
      echo "FAIL: sample ${n} shows an interval-0 one-shot ('${req}') while the most \
recent background cycle was 'trigger=${trigger_at[${n}]:-none}'. P2a keeps \
getCurrentLocation() ONLY as the watchdog's cache-miss fallback; a one-shot on a \
delivery-driven cycle is the per-tick 30 s HIGH_ACCURACY request this phase retired, \
running again beside the long registration."
      rc=1
    fi
    if (( ms > 0 )); then
      positive_per_sample[n]=$(( ${positive_per_sample[n]:-0} + 1 ))
    fi
  done < <(location_request_records "${samplefile}" "${post_min}" "${hold_max}")

  if (( long_seen == 0 )); then
    echo "FAIL: no sample between ${post_min} and ${hold_max} showed a Haven location \
request of at least ${MIN_FIX_INTERVAL_SECS} s. Haven's own \
'[BackgroundTask] registration armed' line is not enough — this is the PLATFORM's copy \
of the request, and its absence means the registration never reached LocationManager."
    rc=1
  fi
  for n in "${!positive_per_sample[@]}"; do
    if (( positive_per_sample[n] > 1 )); then
      echo "FAIL: sample ${n} shows ${positive_per_sample[n]} concurrent Haven location \
registrations. Exactly one owner per isolate, exclusive by lifecycle, is the whole \
Android power claim."
      rc=1
    fi
  done

  if (( rc == 0 )); then
    echo "  registration: 1 s / 1 m seen pre-handoff (samples 1-${pre_max}); from \
sample ${post_min} on, one request only, never under ${MIN_FIX_INTERVAL_SECS} s, no \
distance filter, no minUpdateInterval=, no unattributed one-shot."
  fi
  return "${rc}"
}

# ---------------------------------------------------------------------------
# Oracle step 6 — wake locks.
# ---------------------------------------------------------------------------
assert_wake_lock_oracle() {
  local logfile="$1" samplefile="$2"
  local rc=0 first hold_max n tag age publish_seen=0
  local -a plugin_held=()

  first="$(first_sample_after "${logfile}" "${MARK_HANDOFF_OK}")"
  if [[ -z "${first}" ]]; then
    echo "FAIL: no power sample was taken after the handoff \
($(no_sample_cause "${logfile}" "${samplefile}")), so nothing can be said about the \
wake locks held while backgrounded."
    return 1
  fi
  hold_max="$(last_sample_before "${logfile}" "${MARK_HOLD_DONE}")"
  [[ -n "${hold_max}" ]] || hold_max=999999

  while IFS='|' read -r n tag age; do
    if [[ "${tag}" == "GRAMMAR" ]]; then
      echo "FAIL: could not parse a wake-lock line in sample ${n} (ACQ token '${age}'). \
The dumpsys power grammar changed; fix the parser and its fixtures."
      rc=1
      continue
    fi
    case "${tag}" in
      'ForegroundService:WakeLock')
        plugin_held[n]=1
        ;;
      'Haven:publish')
        publish_seen=$((publish_seen + 1))
        if [[ "${age}" == "UNREADABLE" ]]; then
          echo "FAIL: sample ${n} holds 'Haven:publish' with no readable ACQ= age. The \
bound on that hold is the only thing only a device can show, so an unreadable age is a \
grammar failure, not a lock to pass over."
          rc=1
        elif (( age > WAKE_LOCK_MAX_AGE_SECS * 1000 )); then
          echo "FAIL: sample ${n} shows 'Haven:publish' held for $((age / 1000)) s, past \
its own ${WAKE_LOCK_MAX_AGE_SECS} s ceiling (kPublishWakeLockTimeout, coerced natively by \
PublishWakeLock.MAX_TIMEOUT_MS). A cycle re-acquires between stagger, publish and fetch, \
which RE-POSTS the timeout, so reaching the ceiling at all means Dart's finally did not \
release."
          rc=1
        fi
        ;;
    esac
  done < <(wake_lock_records "${samplefile}" "${first}" "${hold_max}")

  # Asserted over the samples that were actually TAKEN, not over an index range:
  # a sample the sampler never wrote must not read as "the lock was absent", and
  # a range walked blindly would invent thousands of them when the drive died
  # before printing the close marker.
  local taken=0
  while read -r n; do
    taken=$((taken + 1))
    if [[ -z "${plugin_held[n]:-}" ]]; then
      echo "FAIL: sample ${n} does not hold 'ForegroundService:WakeLock'. P2a KEEPS the \
plugin's permanent lock deliberately — it is the wake source of the no-fix watchdog and \
of the armed-but-never-delivered recovery — so its absence means the service died or \
allowWakeLock was turned off. (P2b inverts this row; do not invert it early.)"
      rc=1
    fi
  done < <(sample_indices "${samplefile}" "${first}" "${hold_max}")
  if (( taken == 0 )); then
    echo "FAIL: no power sample exists between ${first} and ${hold_max}, so the \
wake-lock assertions have nothing to read."
    rc=1
  fi

  if (( rc == 0 )); then
    # Sightings are EVIDENCE, not a gate. A cycle can complete inside one
    # ${SAMPLE_PERIOD_SECS} s sample period, so "the scoped lock was seen at
    # least once" would be a coin flip; that the lock is taken at all is pinned
    # by the host tests and by check_android_location_power.sh, and what only a
    # device can add is the BOUND, asserted above.
    echo "  wake locks: plugin lock held throughout; 'Haven:publish' seen in \
${publish_seen} sample(s), none older than ${WAKE_LOCK_MAX_AGE_SECS} s."
  fi
  return "${rc}"
}

# ---------------------------------------------------------------------------
# Oracle step 7 — the cadence is delivery-driven, and spaced.
# ---------------------------------------------------------------------------
assert_cadence_oracle() {
  local windowfile="$1" rc=0 publishes gap measured=0
  publishes="$(successful_publish_count "${windowfile}")"
  if (( publishes < 2 )); then
    echo "FAIL: only ${publishes} successful publish(es) in the proof window. The hold \
covers a full kLocationPublishMaxInterval past the handoff cycle, so the delivery-driven \
publish that follows it is not optional — one publish means the platform delivered once \
and never again."
    rc=1
  fi
  while read -r gap; do
    [[ -n "${gap}" ]] || continue
    measured=$((measured + 1))
    if [[ "${gap}" == "NOARM" ]]; then
      echo "FAIL: a delivery-driven publish in the window had no \
'${MARK_REG_ARMED}' line before it, so the interval that was supposed to space it \
cannot be read from this capture at all."
      rc=1
    elif (( gap < 0 )); then
      echo "FAIL: a delivery landed ${gap} ms after the registration that asked for it \
— the device clock moved backwards inside the window, so no spacing can be read from \
this capture."
      rc=1
    elif (( gap < MIN_DELIVERY_GAP_SECS * 1000 )); then
      echo "FAIL: a delivery landed only $((gap / 1000)) s after the registration that \
asked for it, under the ${MIN_DELIVERY_GAP_SECS} s floor (90 % of \
${MIN_FIX_INTERVAL_SECS} s). The FGS is being woken by something other than its own \
registered interval."
      rc=1
    fi
  done < <(delivery_gaps_after_registration "${windowfile}")
  # The anti-vacuity half, and the reason this oracle is anchored on the
  # registration at all: with nothing measured there is no spacing claim, only
  # a loop that did not run.
  if (( measured == 0 )); then
    echo "FAIL: not one publish in the window was delivery-driven, so the spacing this \
step exists to measure was never measured. ${publishes} publish(es) reached the relay, \
none of them behind a '[BackgroundTask] cycle trigger=delivery' — either the cadence is \
back on the watchdog poll P2a replaced, or the platform never delivered."
    rc=1
  fi
  (( rc == 0 )) && echo "  cadence: ${publishes} publish(es), ${measured} \
delivery-driven, each at least ${MIN_DELIVERY_GAP_SECS} s after the registration that \
produced it."
  return "${rc}"
}

# ---------------------------------------------------------------------------
# Oracle step 8 — the no-fix chain under deep idle.
#
# With the `geo fix` drip stopped, the registration steps 5-7 just proved has
# nothing left to deliver. The claim is that publishing does not stop with it:
# the watchdog notices (the circle falls due, or the silence outlasts
# `kStreamPositionMaxAge`), runs a cycle, finds no fresh stream fix, spends
# `kOneShotLocationTimeout` on a one-shot that cannot be answered, falls back to
# `getLastKnownPosition()` and publishes anyway — with Doze's POLICY applied to
# the app throughout.
#
# Three things keep it from being decoration:
#
#   * `state=IDLE` is required from `dumpsys deviceidle get deep`, the
#     authoritative read. Without it a device that refused to doze would report
#     the ordinary watchdog — already proven, on an awake device — as a Doze
#     result.
#   * The publish must be behind a `trigger=watchdog` marker. A delivery-driven
#     publish here would mean the drip did not actually stop, so the no-fix
#     chain never ran.
#   * The bound is measured from the instant idle ENGAGED, not from the drive's
#     request to engage it.
#
# It does NOT prove the AP-suspend half; see this file's header.
# ---------------------------------------------------------------------------
assert_no_fix_chain_oracle() {
  local logfile="$1" verdict state elapsed
  verdict="$(awk -v forced="${MARK_IDLE_FORCED}" -v endm="${MARK_IDLE_END}" \
                 -v wd="${MARK_TRIGGER_WATCHDOG}" '
    function ts(dm, hms,   md, t, mo, dy, cum, i) {
      split(dm, md, "-"); split(hms, t, ":")
      mo = md[1] + 0; dy = md[2] + 0; cum = 0
      for (i = 1; i < mo; i++) cum += mlen[i]
      return (cum + dy) * 86400 + t[1] * 3600 + t[2] * 60 + t[3]
    }
    BEGIN {
      split("31 28 31 30 31 30 31 31 30 31 30 31", mlen, " ")
      t0 = -1; state = "ABSENT"; pending = 0
    }
    t0 < 0 {
      i = index($0, forced)
      if (i == 0) next
      t0 = ts($1, $2)
      state = substr($0, i + length(forced))
      sub(/[ \t\r].*$/, "", state)
      next
    }
    index($0, endm) { exit }
    index($0, wd) { pending = 1; next }
    index($0, "[BackgroundTask] cycle trigger=") { pending = 0; next }
    {
      i = index($0, "Published to ")
      if (i == 0 || !pending) next
      n = substr($0, i + 13); sub(/\/.*$/, "", n)
      if (n + 0 < 1) next
      printf "%s|%d\n", state, ts($1, $2) - t0
      found = 1
      exit
    }
    END { if (!found) printf "%s|none\n", state }
  ' "${logfile}" 2>/dev/null)"
  state="${verdict%%|*}"
  elapsed="${verdict##*|}"

  if [[ "${state}" == "ABSENT" ]]; then
    echo "FAIL: the forced-idle phase never started — no '${MARK_IDLE_FORCED}' stamp in \
the capture. Either the drive never printed '${MARK_IDLE_BEGIN}' or this script's idle \
watcher died before it could act, so the no-fix chain was never exercised."
    return 1
  fi
  if [[ "${state}" != "IDLE" ]]; then
    echo "FAIL: the device did not enter deep idle ('dumpsys deviceidle get deep' read \
back '${state}'). Anything that publishes after this is the ordinary watchdog on an \
awake device, which steps 1-7 already cover; none of it would be a Doze result."
    return 1
  fi
  if [[ "${elapsed}" == "none" ]]; then
    echo "FAIL: no '${MARK_TRIGGER_WATCHDOG}' cycle published after the device entered \
deep idle. With the GPS drip stopped the delivery-driven path has nothing to run on, so \
background publishing STOPS here unless the no-fix chain (stale stream fix -> one-shot \
timeout -> getLastKnownPosition) carries it."
    return 1
  fi
  if (( elapsed < 0 )); then
    echo "FAIL: the no-fix watchdog publish is stamped ${elapsed} s BEFORE deep idle \
engaged — the device clock moved backwards, so nothing can be read from this capture."
    return 1
  fi
  if (( elapsed > NO_FIX_BOUND_SECS )); then
    echo "FAIL: the no-fix watchdog publish landed ${elapsed} s after deep idle engaged, \
past the ${NO_FIX_BOUND_SECS} s bound (kStreamPositionMaxAge ${STREAM_MAX_AGE_SECS} s + \
kBackgroundRepeatInterval ${WATCHDOG_PERIOD_SECS} s + kFirstDeliveryWait \
${FIRST_DELIVERY_WAIT_SECS} s + kOneShotLocationTimeout ${ONE_SHOT_TIMEOUT_SECS} s + \
${NO_FIX_SLACK_SECS} s slack). Publishing recovered, but late enough that a peer's \
228 s marker retention had already lapsed."
    return 1
  fi
  echo "  no-fix chain: deep idle engaged; a ${MARK_TRIGGER_WATCHDOG} cycle published \
${elapsed} s later (bound ${NO_FIX_BOUND_SECS} s)."
  return 0
}

# ---------------------------------------------------------------------------
# Self-test fixtures: the AOSP grammars, VERBATIM.
#
# These lines are the contract between this script and the platform. They are
# transcribed from `LocationRequest.toString`, `CallerIdentity.toString`,
# `ProviderRequest.toString` and `PowerManagerService.WakeLock.toString`
# (android14-release — the lane's API-34 image), and the fixtures below assert
# that the parsers read exactly them. A platform text change therefore lands as
# a red parser with a diff to look at, not as an oracle that silently stops
# matching and passes everything.
#
# V-P2-1 (docs/POWER_EFFICIENCY_PLAN.md 7.5) is closed by these. The first CI
# run (34488512808) checked them against the real image and disproved two: the
# logcat stamp and the wake-lock level are both PADDED on the device, and the
# single-space forms first transcribed here matched nothing there. The stamp and
# the registration lines are now pinned by lines copied from that run's capture;
# the wake-lock lines follow `getLockLevelString()`'s padded literal, because
# that run's sampler filtered every one of them out before it wrote anything.
# The request constants below keep a `gps ` provider token the API-34 image does
# not print; the parser reads from `@`, so that token is inert.
# ---------------------------------------------------------------------------
# The foreground stream: 1 s interval, 1 m displacement. The distance suffix is
# printed only when > 0, so it is the UI request's signature.
readonly FIX_REQ_UI='  10123/com.oblivioustech.haven/A1B2C3D4 Request[gps @+1s0ms HIGH_ACCURACY, minUpdateDistance=1.0]'
# The FGS stream: minUpdateInterval == interval and distance 0, so NEITHER
# suffix is printed. 100 s.
readonly FIX_REQ_FGS='  10123/com.oblivioustech.haven/B2C3D4E5 Request[gps @+1m40s0ms HIGH_ACCURACY]'
# The same at 61 s and at exactly the 62 s floor.
readonly FIX_REQ_61S='  10123/com.oblivioustech.haven/B2C3D4E5 Request[gps @+1m1s0ms HIGH_ACCURACY]'
readonly FIX_REQ_62S='  10123/com.oblivioustech.haven/B2C3D4E5 Request[gps @+1m2s0ms HIGH_ACCURACY]'
# `getCurrentLocation()`'s one-shot: no interval at all, which TimeUtils prints
# as the bare "0". Legitimate in P2a as the cache-miss fallback.
readonly FIX_REQ_ONESHOT='  10123/com.oblivioustech.haven/C3D4E5F6 Request[gps @0 HIGH_ACCURACY]'
# A fastest-interval below the interval. geolocator sets the two EQUAL
# (`LocationManagerClient.java:182-185`), so this suffix cannot appear on a
# request Haven asked for — its presence means the platform may deliver faster
# than the duty cycle, which is the saving itself.
readonly FIX_REQ_FASTEST='  10123/com.oblivioustech.haven/B2C3D4E5 Request[gps @+1m40s0ms HIGH_ACCURACY, minUpdateInterval=+30s0ms]'
# A DIFFERENT package that merely starts with ours — the instrumentation package
# this very lane installs beside the app. A prefix match counts it as a second
# Haven registration, and a foreground-shaped one at that.
readonly FIX_REQ_SIBLING_PKG='  10123/com.oblivioustech.haven.test/D4E5F6A7 Request[gps @+1s0ms HIGH_ACCURACY, minUpdateDistance=1.0]'
# The provider's MERGED request. It names our package in its WorkSource and
# contains "Request[" as a substring, so it is the false-positive the leading
# space in " Request[" exists to exclude.
readonly FIX_REQ_MERGED='  service: ProviderRequest[@+1m40s0ms, HIGH_ACCURACY, WorkSource{10123 com.oblivioustech.haven}]'
# The Event Log replaying a registration that was CANCELLED at the handoff. It
# keeps printing the foreground request for the rest of the capture, so it is
# the line that would make "the 1 s / 1 m stream is gone" impossible to prove.
readonly FIX_REQ_LOG_EVENT='  gps provider +registration 10123/com.oblivioustech.haven/A1B2C3D4 -> Request[gps @+1s0ms HIGH_ACCURACY, minUpdateDistance=1.0]'
# The historical-aggregate section: a CallerIdentity at the start of the line,
# with no request after it.
readonly FIX_AGG_STATS='  10123/com.oblivioustech.haven: fixes=12 durationTotal=+1m0s0ms'
# `getLockLevelString()`'s PARTIAL_WAKE_LOCK literal, 30 columns wide; `dumpsys
# power` prints "  " + level + " '" + tag + "'" (PowerManagerService :4710,
# :5366-5396). The plugin lock carries ` LONG`: it has been held past a minute.
readonly FIX_LOCK_LEVEL='PARTIAL_WAKE_LOCK             '
readonly FIX_LOCK_PLUGIN="  ${FIX_LOCK_LEVEL} 'ForegroundService:WakeLock' ACQ=-1m12s345ms LONG (uid=10123 pid=1111)"
readonly FIX_LOCK_PUBLISH="  ${FIX_LOCK_LEVEL} 'Haven:publish' ACQ=-2s500ms (uid=10123 pid=1111)"
readonly FIX_LOCK_PUBLISH_STUCK="  ${FIX_LOCK_LEVEL} 'Haven:publish' ACQ=-31s000ms (uid=10123 pid=1111)"

# Write a power-sample file: <out> <pre-handoff request line> <steady-state
# request block>. Samples 1-2 are the foreground phase, 3-5 the steady state.
# An empty request argument writes a sample with wake locks and no request,
# which is how the anti-vacuity fixture is built.
build_fixture_samples() {
  local out="$1" pre="$2" steady="$3" i
  {
    for i in 1 2; do
      printf '=== SAMPLE n=%s device-clock=08-02 04:40:%02d.000 ===\n' "${i}" "$(( (i - 1) * 5 ))"
      if [[ -n "${pre}" ]]; then printf '%s\n' "${pre}"; fi
      printf '%s\n' "${FIX_LOCK_PLUGIN}"
    done
    for i in 3 4 5; do
      printf '=== SAMPLE n=%s device-clock=08-02 04:4%s:00.000 ===\n' "${i}" "${i}"
      if [[ -n "${steady}" ]]; then printf '%s\n' "${steady}"; fi
      # The three impostors ride in EVERY steady-state sample, so every oracle
      # fixture below — the passing ones especially — is asserted against them.
      printf '%s\n%s\n%s\n%s\n%s\n' "${FIX_REQ_MERGED}" "${FIX_REQ_LOG_EVENT}" \
        "${FIX_AGG_STATS}" "${FIX_LOCK_PLUGIN}" "${FIX_LOCK_PUBLISH}"
    done
  } > "${out}"
}

# `hh:mm:ss` plus N seconds, so every fixture stamp that has to sit at a BOUND
# is computed from the bound rather than transcribed beside it. Pure arithmetic
# (no `date -d`) so the self-test stays hermetic and portable.
_fixture_bump() {
  local hms="$1" add="$2" h m s t
  IFS=: read -r h m s <<< "${hms}"
  t=$(( (10#${h} * 3600 + 10#${m} * 60 + 10#${s} + add) % 86400 ))
  printf '%02d:%02d:%02d\n' "$(( t / 3600 ))" "$(( t % 3600 / 60 ))" "$(( t % 60 ))"
}

# One delivery-driven cycle, in the order the FGS really logs it: the trigger,
# then the registration for the NEXT fix (step 7c aims it BEFORE the publish),
# then the publish. The registration that PRODUCED a delivery is therefore the
# one logged by the cycle before it, which is what the cadence oracle measures.
_fixture_delivery_cycle() {
  local d="$1"
  printf '08-02 %s.000  1111  1140 I flutter : [BackgroundTask] cycle trigger=delivery\n' "${d}"
  printf '08-02 %s.000  1111  1140 I flutter : %s100s)\n' \
    "$(_fixture_bump "${d}" 1)" "${MARK_REG_ARMED}"
  printf '08-02 %s.000  1111  1140 I flutter : [BackgroundTask] Published to 1/1 due circle(s) (1 eligible), fetched 1/1 circle(s).\n' \
    "$(_fixture_bump "${d}" 2)"
}

# Write the matching logcat capture:
#   <out> <delivery-driven cycles: 0, 1 or 2> <1st delivery> <2nd delivery> <sample-5>
#
# The paused-signal cycle arms at 04:40:08 and publishes at 04:40:09, so the
# first delivery's spacing is measured from 04:40:08 and the second's from one
# second after the first delivery.
#
# Sample stamps and drive markers share ONE ordered capture — that, not any
# host-side clock arithmetic, is what puts a sample before or after the handoff.
build_fixture_logcat() {
  local out="$1" cycles="$2" d1="$3" d2="$4" s5="$5"
  {
    printf '08-02 04:40:00.000  1500  1500 I %-8s: SAMPLE 1\n' "${SAMPLE_TAG}"
    printf '08-02 04:40:01.000  1111  1120 I flutter : %s pid=1111\n' "${MARK_PAUSE}"
    printf '08-02 04:40:05.000  1500  1500 I %-8s: SAMPLE 2\n' "${SAMPLE_TAG}"
    printf '08-02 04:40:06.000  1111  1120 I flutter : %s\n' "${MARK_HANDOFF_OK}"
    printf '08-02 04:40:07.000  1111  1140 I flutter : [BackgroundTask] cycle trigger=paused-signal\n'
    printf '08-02 04:40:08.000  1111  1140 I flutter : %s100s)\n' "${MARK_REG_ARMED}"
    printf '08-02 04:40:09.000  1111  1140 I flutter : [BackgroundTask] Published to 1/1 due circle(s) (1 eligible), fetched 1/1 circle(s).\n'
    printf '08-02 04:40:10.000  1500  1500 I %-8s: SAMPLE 3\n' "${SAMPLE_TAG}"
    (( cycles >= 1 )) && _fixture_delivery_cycle "${d1}"
    printf '08-02 04:41:45.000  1500  1500 I %-8s: SAMPLE 4\n' "${SAMPLE_TAG}"
    (( cycles >= 2 )) && _fixture_delivery_cycle "${d2}"
    printf '08-02 %s.000  1500  1500 I %-8s: SAMPLE 5\n' "${s5}" "${SAMPLE_TAG}"
    printf '08-02 04:43:30.000  1111  1130 I flutter : %s\n' "${MARK_HOLD_DONE}"
  } > "${out}"
}

# Write a step-8 capture: <out> <deep-idle state read-back> <watchdog publish
# hh:mm:ss, or `none`>. The publish is preceded by its trigger two seconds
# earlier, as the real cycle logs it.
build_fixture_idle_logcat() {
  local out="$1" state="$2" pub="$3"
  {
    printf '08-02 04:43:30.000  1111  1130 I flutter : %s\n' "${MARK_HOLD_DONE}"
    printf '08-02 04:43:31.000  1111  1130 I flutter : %s\n' "${MARK_IDLE_BEGIN}"
    printf '08-02 04:43:34.000  1500  1500 I %-8s: %s%s\n' \
      "${SAMPLE_TAG}" "${MARK_IDLE_FORCED}" "${state}"
    if [[ "${pub}" != "none" ]]; then
      printf '08-02 %s.000  1111  1140 I flutter : %s\n' \
        "$(_fixture_bump "${pub}" -2)" "${MARK_TRIGGER_WATCHDOG}"
      printf '08-02 %s.000  1111  1140 I flutter : [BackgroundTask] Published to 1/1 due circle(s) (1 eligible), fetched 1/1 circle(s).\n' \
        "${pub}"
    fi
    printf '08-02 04:52:00.000  1111  1130 I flutter : %s\n' "${MARK_IDLE_END}"
  } > "${out}"
}

# ---------------------------------------------------------------------------
# --self-test — validate max_published_count against synthetic fixtures WITHOUT
# a device (mirrors run-single-avd-scenario.sh / scan-logs-for-secrets.sh). CI
# gates the parser through this in the fast repo-guards job so it can never
# silently rot into a parser that accepts the failing case.
#
# Runs BEFORE the EXIT trap is installed: the trap tears down docker/strfry,
# which a hermetic self-test must never touch.
# ---------------------------------------------------------------------------
run_self_test() {
  # Pinned by EQUALITY, never by a floor: the run used to end with a hard-coded
  # "all N fixtures passed" and no counter, so deleting a case left the message
  # — and the exit code — untouched. Mirrors check_android_location_power.sh.
  local -r SELF_TEST_FIXTURES=65
  local tmp fail=0 checked=0 got
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  # Every case calls this exactly once, immediately before it asserts.
  _case() { checked=$((checked + 1)); }

  # (1) THE CRITICAL FIXTURE — P0-1's actual signature. The marker substring is
  #     present but the count is 0. A `grep -q 'Published to'` oracle would pass
  #     here; the parser MUST report 0 so the caller fails the lane.
  printf '%s\n' \
    '08-02 04:41:02.001  1234  1300 I flutter : [BackgroundTask] onStart (starter=developer)' \
    '08-02 04:42:14.552  1234  1300 I flutter : [BackgroundTask] Published to 0/1 due circle(s) (1 eligible), fetched 0/1 circle(s).' \
    > "${tmp}/zero.log"
  _case
  got="$(max_published_count "${tmp}/zero.log")"
  if [[ "${got}" != "0" ]]; then
    echo "SELF-TEST FAIL (1): expected 0 from a 0/1 line, got '${got}'" >&2
    fail=1
  fi

  # (2) TRUE POSITIVE — a real publish.
  printf '%s\n' \
    '08-02 04:42:14.552  1234  1300 I flutter : [BackgroundTask] Published to 1/1 due circle(s) (1 eligible), fetched 1/1 circle(s).' \
    > "${tmp}/one.log"
  _case
  got="$(max_published_count "${tmp}/one.log")"
  if [[ "${got}" != "1" ]]; then
    echo "SELF-TEST FAIL (2): expected 1, got '${got}'" >&2
    fail=1
  fi

  # (3) MULTI-CYCLE — a later cycle reporting 0 (nothing due on its own jittered
  #     schedule) must NOT mask an earlier real publish. Guards the "last line
  #     wins" bug that would make a passing lane flap on cycle timing.
  printf '%s\n' \
    '08-02 04:42:14.552  1234  1300 I flutter : [BackgroundTask] Published to 2/2 due circle(s) (2 eligible), fetched 2/2 circle(s).' \
    '08-02 04:43:26.552  1234  1300 I flutter : [BackgroundTask] Published to 0/0 due circle(s) (2 eligible), fetched 0/2 circle(s).' \
    > "${tmp}/multi.log"
  _case
  got="$(max_published_count "${tmp}/multi.log")"
  if [[ "${got}" != "2" ]]; then
    echo "SELF-TEST FAIL (3): expected 2 across cycles, got '${got}'" >&2
    fail=1
  fi

  # (4) EMPTY — no publish line at all yields empty, never a spurious 0 that a
  #     caller could confuse with "cycle ran and published nothing".
  printf '%s\n' \
    '08-02 04:41:02.001  1234  1300 I flutter : [BackgroundTask] onStart (starter=developer)' \
    > "${tmp}/none.log"
  _case
  got="$(max_published_count "${tmp}/none.log")"
  if [[ -n "${got}" ]]; then
    echo "SELF-TEST FAIL (4): expected empty from a log with no publish line, got '${got}'" >&2
    fail=1
  fi

  # (5) DOUBLE-DIGIT — the parser must not truncate or mis-sort N >= 10
  #     (a plain lexical sort ranks '9' above '12').
  printf '%s\n' \
    '08-02 04:42:14.552  1234  1300 I flutter : [BackgroundTask] Published to 9/12 due circle(s) (12 eligible), fetched 9/12 circle(s).' \
    '08-02 04:43:26.552  1234  1300 I flutter : [BackgroundTask] Published to 12/12 due circle(s) (12 eligible), fetched 12/12 circle(s).' \
    > "${tmp}/wide.log"
  _case
  got="$(max_published_count "${tmp}/wide.log")"
  if [[ "${got}" != "12" ]]; then
    echo "SELF-TEST FAIL (5): expected 12, got '${got}'" >&2
    fail=1
  fi

  # --- window_between_markers + pid_of_marker ------------------------------
  # These two carry the lane's anti-vacuity checks (windowing to the proof span
  # and same-process proof), so they get fixtures of their own rather than being
  # trusted because they look obvious.
  printf '%s\n' \
    '08-02 04:40:00.000  1111  1120 I flutter : [BackgroundTask] Published to 9/9 due circle(s) (9 eligible), fetched 9/9 circle(s).' \
    '08-02 04:41:00.000  1111  1130 I flutter : [b1] HANDOFF_CONFIRMED' \
    '08-02 04:42:14.552  1111  1140 I flutter : [BackgroundTask] Published to 1/1 due circle(s) (1 eligible), fetched 1/1 circle(s).' \
    > "${tmp}/window.log"

  # (6) A publish from BEFORE the handoff must not count. Without the window
  #     the parser would return 9 and the lane would pass on a foreground
  #     publish — which is a Rule-14 single-writer violation, not a success.
  _case
  got="$(window_between_markers "${tmp}/window.log" '[b1] HANDOFF_CONFIRMED' \
    '[b1] HOLD_COMPLETE' | { max_published_count /dev/stdin; })"
  if [[ "${got}" != "1" ]]; then
    echo "SELF-TEST FAIL (6): windowed count should be 1 (post-handoff), got '${got}'" >&2
    fail=1
  fi

  # (7) No open marker at all ⇒ empty window, so a missing handoff can never be
  #     silently treated as "the whole log counts".
  _case
  got="$(window_between_markers "${tmp}/window.log" '[b1] NEVER_HAPPENED' \
    '[b1] HOLD_COMPLETE' | wc -l | tr -d ' ')"
  if [[ "${got}" != "0" ]]; then
    echo "SELF-TEST FAIL (7): a missing marker must yield an empty window, got ${got} line(s)" >&2
    fail=1
  fi

  # (8) PID extraction from the `logcat -v threadtime` column layout.
  _case
  got="$(pid_of_marker "${tmp}/window.log" '[b1] HANDOFF_CONFIRMED')"
  if [[ "${got}" != "1111" ]]; then
    echo "SELF-TEST FAIL (8): expected PID 1111, got '${got}'" >&2
    fail=1
  fi

  # (9) A restarted service logs under a DIFFERENT pid — the false-green route
  #     step 4 exists to catch. The extractor must report that difference.
  printf '%s\n' \
    '08-02 04:41:00.000  1111  1130 I flutter : [b1] HANDOFF_CONFIRMED' \
    '08-02 04:44:00.000  2222  2230 I flutter : [BackgroundTask] Published to 1/1 due circle(s) (1 eligible), fetched 1/1 circle(s).' \
    > "${tmp}/restart.log"
  _case
  if [[ "$(pid_of_marker "${tmp}/restart.log" '[b1] HANDOFF_CONFIRMED')" == \
        "$(pid_of_marker "${tmp}/restart.log" '[BackgroundTask] Published to ')" ]]; then
    echo "SELF-TEST FAIL (9): a cross-process publish was reported as same-PID" >&2
    fail=1
  fi

  # --- window_between_markers ----------------------------------------------
  # The CLOSE of the window. Teardown legitimately destroys the FGS twice (the
  # resume takes the MLS session back by stopping it, then the post-test unmount
  # stops it again), so an EOF-bounded window fails a lane that passed.
  printf '%s\n' \
    '08-02 04:41:00.000  1111  1130 I flutter : [b1] HANDOFF_CONFIRMED' \
    '08-02 04:42:14.552  1111  1140 I flutter : [BackgroundTask] Published to 1/1 due circle(s) (1 eligible), fetched 1/1 circle(s).' \
    '08-02 04:45:00.000  1111  1130 I flutter : [b1] HOLD_COMPLETE' \
    '08-02 04:45:02.000  1111  1140 I flutter : [BackgroundTask] onDestroy (isTimeout=false)' \
    > "${tmp}/closed.log"

  # (10) A teardown destroy must fall OUTSIDE the window.
  _case
  if window_between_markers "${tmp}/closed.log" '[b1] HANDOFF_CONFIRMED' \
       '[b1] HOLD_COMPLETE' | grep -aqF -- '[BackgroundTask] onDestroy'; then
    echo "SELF-TEST FAIL (10): a post-hold onDestroy leaked into the window" >&2
    fail=1
  fi

  # (11) …while the publish inside it still counts. A close that swallowed the
  #      window's contents would turn every assertion vacuous.
  _case
  got="$(window_between_markers "${tmp}/closed.log" '[b1] HANDOFF_CONFIRMED' \
    '[b1] HOLD_COMPLETE' | { max_published_count /dev/stdin; })"
  if [[ "${got}" != "1" ]]; then
    echo "SELF-TEST FAIL (11): expected 1 publish inside the window, got '${got}'" >&2
    fail=1
  fi

  # (12) A destroy BEFORE the close is the real failure this check exists for —
  #      the service dying mid-window — and must still be caught.
  printf '%s\n' \
    '08-02 04:41:00.000  1111  1130 I flutter : [b1] HANDOFF_CONFIRMED' \
    '08-02 04:42:00.000  1111  1140 I flutter : [BackgroundTask] onDestroy (isTimeout=true)' \
    '08-02 04:45:00.000  1111  1130 I flutter : [b1] HOLD_COMPLETE' \
    > "${tmp}/died.log"
  _case
  if ! window_between_markers "${tmp}/died.log" '[b1] HANDOFF_CONFIRMED' \
       '[b1] HOLD_COMPLETE' | grep -aqF -- '[BackgroundTask] onDestroy'; then
    echo "SELF-TEST FAIL (12): a mid-window onDestroy was not caught" >&2
    fail=1
  fi

  # (13) No close marker (a drive killed mid-hold) must fall back to EOF, never
  #      to an empty window — an empty one would make every assertion pass
  #      vacuously on exactly the runs that are least trustworthy.
  _case
  got="$(window_between_markers "${tmp}/closed.log" '[b1] HANDOFF_CONFIRMED' \
    '[b1] NEVER_PRINTED' | wc -l | tr -d ' ')"
  if [[ "${got}" != "4" ]]; then
    echo "SELF-TEST FAIL (13): expected a 4-line EOF fallback, got ${got}" >&2
    fail=1
  fi

  # (14) An end marker BEFORE the start must not open the window backwards —
  #      the close is only ever the first one at or after the open.
  _case
  got="$(window_between_markers "${tmp}/closed.log" '[BackgroundTask] Published to ' \
    '[b1] HANDOFF_CONFIRMED' | wc -l | tr -d ' ')"
  if [[ "${got}" != "3" ]]; then
    echo "SELF-TEST FAIL (14): a close preceding the open must be ignored, got ${got} line(s)" >&2
    fail=1
  fi

  # --- TimeUtils.formatDuration --------------------------------------------
  # Every interval and every wake-lock age in the power oracles is read through
  # this one parser, so its grammar is pinned in both directions: the shapes
  # AOSP actually prints (these five, and the sub-second one at (61)), and
  # shapes it does NOT (which is how a future platform that prints
  # milliseconds, or drops the ms field, arrives as a red parser instead of as
  # a silently-ignored line).
  local i=0
  local -a dur_ok_tok=('+1m40s0ms' '+1s0ms' '0' '-12s345ms' '+1h2m3s4ms')
  local -a dur_ok_ms=('100000' '1000' '0' '-12345' '3723004')
  for i in "${!dur_ok_tok[@]}"; do
    _case
    got="$(formatted_duration_ms "${dur_ok_tok[$i]}" || echo 'REJECTED')"
    if [[ "${got}" != "${dur_ok_ms[$i]}" ]]; then
      echo "SELF-TEST FAIL ($((15 + i))): formatted_duration_ms '${dur_ok_tok[$i]}' should be \
${dur_ok_ms[$i]} ms, got '${got}'" >&2
      fail=1
    fi
  done

  # (20) A millisecond print is a grammar CHANGE, not a duration to guess at.
  _case
  if formatted_duration_ms '100000' >/dev/null 2>&1; then
    echo "SELF-TEST FAIL (20): a bare millisecond count was accepted as a formatDuration token" >&2
    fail=1
  fi
  # (21) …and so is dropping the trailing ms field.
  _case
  if formatted_duration_ms '+1m40s' >/dev/null 2>&1; then
    echo "SELF-TEST FAIL (21): '+1m40s' (no ms field) was accepted" >&2
    fail=1
  fi

  # --- dumpsys line splitting ----------------------------------------------
  build_fixture_samples "${tmp}/samples.ok" "${FIX_REQ_UI}" "${FIX_REQ_FGS}"

  # (22) The steady-state sample's ONE Haven registration parses to 100 s with
  #      no distance filter.
  # Taken from the whole output rather than through `head -1`: the reader is a
  # shell loop, and a closed pipe would kill it with SIGPIPE mid-fixture.
  _case
  got="$(location_request_records "${tmp}/samples.ok" 3 5)"
  got="${got%%$'\n'*}"
  if [[ "${got}" != "3|100000|-|"* ]]; then
    echo "SELF-TEST FAIL (22): expected sample 3 to yield one 100000 ms request with no \
distance filter, got '${got}'" >&2
    fail=1
  fi

  # (23) …and it is the ONLY one. The merged ProviderRequest beside it names our
  #      package and contains "Request[", the Event Log replays a registration
  #      cancelled at the handoff, and the historical-aggregate line starts with
  #      a CallerIdentity: counting any of them reports two owners on a healthy
  #      run.
  _case
  got="$(location_request_records "${tmp}/samples.ok" 3 3 | wc -l | tr -d ' ')"
  if [[ "${got}" != "1" ]]; then
    echo "SELF-TEST FAIL (23): sample 3 yielded ${got} requests; the merged \
ProviderRequest, the Event Log's replayed +registration and the historical-aggregate \
identity line must none of them be counted as ours" >&2
    fail=1
  fi

  # (24) The foreground request keeps its distance suffix — the token the
  #      background assertion is keyed on.
  _case
  got="$(location_request_records "${tmp}/samples.ok" 1 1)"
  if [[ "${got}" != "1|1000|1.0|"* ]]; then
    echo "SELF-TEST FAIL (24): expected the 1 s / 1 m request to parse as 1000 ms with \
minUpdateDistance 1.0, got '${got}'" >&2
    fail=1
  fi

  # (25) Wake-lock tag + ACQ age. `ACQ=` is acquire-minus-now, so the AGE is its
  #      negation — the sign flip is exactly what a count-of-samples oracle
  #      would never have to get right, and what makes the bound assertable.
  _case
  got="$(wake_lock_records "${tmp}/samples.ok" 3 3 | tr '\n' ' ')"
  if [[ "${got}" != "3|ForegroundService:WakeLock|72345 3|Haven:publish|2500 " ]]; then
    echo "SELF-TEST FAIL (25): wake-lock parse mismatch, got '${got}'" >&2
    fail=1
  fi

  # (26) A package that merely STARTS with ours — the instrumentation package
  #      this lane installs beside the app — is not ours. Under a prefix match
  #      it reads as a second, foreground-shaped Haven registration and reds a
  #      healthy run.
  build_fixture_samples "${tmp}/samples.sibling" "${FIX_REQ_UI}" \
    "$(printf '%s\n%s' "${FIX_REQ_FGS}" "${FIX_REQ_SIBLING_PKG}")"
  _case
  got="$(location_request_records "${tmp}/samples.sibling" 3 3 | wc -l | tr -d ' ')"
  if [[ "${got}" != "1" ]]; then
    echo "SELF-TEST FAIL (26): a '<pkg>.test' registration was counted as Haven's \
(${got} requests in sample 3)" >&2
    fail=1
  fi

  # --- the oracles, end to end ---------------------------------------------
  # The healthy capture: two delivery-driven cycles, the second landing exactly
  # on the delivery-spacing floor after the registration that produced it.
  local d1_ok='04:41:40' d2_ok d2_tight arm2_ok
  arm2_ok="$(_fixture_bump "${d1_ok}" 1)"
  d2_ok="$(_fixture_bump "${arm2_ok}" "${MIN_DELIVERY_GAP_SECS}")"
  d2_tight="$(_fixture_bump "${arm2_ok}" "$((MIN_DELIVERY_GAP_SECS - 1))")"
  build_fixture_logcat "${tmp}/power.ok.log" 2 "${d1_ok}" "${d2_ok}" '04:42:45'
  window_between_markers "${tmp}/power.ok.log" "${MARK_HANDOFF_OK}" "${MARK_HOLD_DONE}" \
    > "${tmp}/power.ok.window"

  # A capture whose most recent cycle before every steady-state sample is the
  # WATCHDOG — the one cycle a `getCurrentLocation()` one-shot is legitimate on.
  awk -v wd='08-02 04:41:39.000  1111  1140 I flutter : [BackgroundTask] cycle trigger=watchdog' '
    /SAMPLE [345]$/ { print wd }
    { print }
  ' "${tmp}/power.ok.log" > "${tmp}/power.watchdog.log"
  window_between_markers "${tmp}/power.watchdog.log" "${MARK_HANDOFF_OK}" \
    "${MARK_HOLD_DONE}" > "${tmp}/power.watchdog.window"

  # (27) The healthy capture passes.
  _case
  if ! assert_registration_oracle "${tmp}/power.ok.log" "${tmp}/samples.ok" \
       "${tmp}/power.ok.window" >/dev/null; then
    echo "SELF-TEST FAIL (27): the registration oracle failed a HEALTHY capture" >&2
    assert_registration_oracle "${tmp}/power.ok.log" "${tmp}/samples.ok" \
      "${tmp}/power.ok.window" >&2 || true
    fail=1
  fi

  # (28) The UI's 1 m filter still present while backgrounded — the P1 release
  #      regressing, which is the whole point of keying on that suffix.
  build_fixture_samples "${tmp}/samples.ui" "${FIX_REQ_UI}" "${FIX_REQ_UI}"
  _case
  if assert_registration_oracle "${tmp}/power.ok.log" "${tmp}/samples.ui" \
       "${tmp}/power.ok.window" >/dev/null 2>&1; then
    echo "SELF-TEST FAIL (28): a 1 s / 1 m request surviving the handoff was accepted" >&2
    fail=1
  fi

  # (29) ANTI-VACUITY. No foreground request anywhere before the handoff means
  #      the sampler or the parser saw nothing, and "no fast request afterwards"
  #      would then be true of an empty file.
  build_fixture_samples "${tmp}/samples.blind" "" "${FIX_REQ_FGS}"
  _case
  if assert_registration_oracle "${tmp}/power.ok.log" "${tmp}/samples.blind" \
       "${tmp}/power.ok.window" >/dev/null 2>&1; then
    echo "SELF-TEST FAIL (29): a capture with no pre-handoff 1 s / 1 m request passed" >&2
    fail=1
  fi

  # (30) Two concurrent Haven stream registrations in one sample.
  build_fixture_samples "${tmp}/samples.two" "${FIX_REQ_UI}" \
    "$(printf '%s\n%s' "${FIX_REQ_FGS}" "${FIX_REQ_62S}")"
  _case
  if assert_registration_oracle "${tmp}/power.ok.log" "${tmp}/samples.two" \
       "${tmp}/power.ok.window" >/dev/null 2>&1; then
    echo "SELF-TEST FAIL (30): two concurrent Haven registrations were accepted" >&2
    fail=1
  fi

  # (31) The one-shot beside the long request must NOT red the lane when the
  #      cycle it belongs to is the WATCHDOG: P2a keeps `getCurrentLocation()`
  #      as that cycle's cache-miss fallback, and its request carries no
  #      interval at all.
  build_fixture_samples "${tmp}/samples.oneshot" "${FIX_REQ_UI}" \
    "$(printf '%s\n%s' "${FIX_REQ_FGS}" "${FIX_REQ_ONESHOT}")"
  _case
  if ! assert_registration_oracle "${tmp}/power.watchdog.log" "${tmp}/samples.oneshot" \
       "${tmp}/power.watchdog.window" >/dev/null; then
    echo "SELF-TEST FAIL (31): a legitimate one-shot on a watchdog cycle was reported \
as a violation" >&2
    assert_registration_oracle "${tmp}/power.watchdog.log" "${tmp}/samples.oneshot" \
      "${tmp}/power.watchdog.window" >&2 || true
    fail=1
  fi

  # (32) …and the SAME one-shot on a delivery-driven cycle must red the lane.
  #      That is the pre-P2a per-tick 30 s HIGH_ACCURACY request, which prints
  #      identically; without the attribution the carve-out in (31) hides it.
  _case
  if assert_registration_oracle "${tmp}/power.ok.log" "${tmp}/samples.oneshot" \
       "${tmp}/power.ok.window" >/dev/null 2>&1; then
    echo "SELF-TEST FAIL (32): a one-shot on a delivery-driven cycle was accepted — the \
per-tick one-shot P2a retired can regress unseen" >&2
    fail=1
  fi

  # (33)/(34) The floor is kLocationPublishMinInterval - kBackgroundFixLeadTime,
  #      and it is INCLUSIVE: a retry registration after a failed publish asks
  #      for exactly that. 61 s is a real regression; 62 s is a correct run that
  #      a 72 s bound would have failed on every draw under 82 s.
  build_fixture_samples "${tmp}/samples.61" "${FIX_REQ_UI}" "${FIX_REQ_61S}"
  _case
  if assert_registration_oracle "${tmp}/power.ok.log" "${tmp}/samples.61" \
       "${tmp}/power.ok.window" >/dev/null 2>&1; then
    echo "SELF-TEST FAIL (33): a 61 s registration passed a ${MIN_FIX_INTERVAL_SECS} s floor" >&2
    fail=1
  fi
  build_fixture_samples "${tmp}/samples.62" "${FIX_REQ_UI}" "${FIX_REQ_62S}"
  _case
  if ! assert_registration_oracle "${tmp}/power.ok.log" "${tmp}/samples.62" \
       "${tmp}/power.ok.window" >/dev/null; then
    echo "SELF-TEST FAIL (34): a registration at exactly ${MIN_FIX_INTERVAL_SECS} s was \
rejected — the bound must be inclusive" >&2
    fail=1
  fi

  # (35) Grammar drift is a FAILURE, never a skipped line.
  build_fixture_samples "${tmp}/samples.drift" "${FIX_REQ_UI}" \
    '  10123/com.oblivioustech.haven/B2C3D4E5 Request[gps every 100000 millis]'
  _case
  if assert_registration_oracle "${tmp}/power.ok.log" "${tmp}/samples.drift" \
       "${tmp}/power.ok.window" >/dev/null 2>&1; then
    echo "SELF-TEST FAIL (35): an unparseable Request[...] was passed over silently" >&2
    fail=1
  fi

  # (36) A fastest-interval below the interval. The plan names the ABSENCE of
  #      `minUpdateInterval=` as the FGS request's signature: with it, the
  #      platform may deliver faster than the duty cycle that IS the saving.
  build_fixture_samples "${tmp}/samples.fastest" "${FIX_REQ_UI}" "${FIX_REQ_FASTEST}"
  _case
  if assert_registration_oracle "${tmp}/power.ok.log" "${tmp}/samples.fastest" \
       "${tmp}/power.ok.window" >/dev/null 2>&1; then
    echo "SELF-TEST FAIL (36): a request carrying minUpdateInterval= was accepted" >&2
    fail=1
  fi

  # (37) Wake locks on the healthy capture.
  _case
  if ! assert_wake_lock_oracle "${tmp}/power.ok.log" "${tmp}/samples.ok" >/dev/null; then
    echo "SELF-TEST FAIL (37): the wake-lock oracle failed a HEALTHY capture" >&2
    assert_wake_lock_oracle "${tmp}/power.ok.log" "${tmp}/samples.ok" >&2 || true
    fail=1
  fi

  # (38) A `Haven:publish` older than its own ceiling. Asserted on the AGE, not
  #      on how many samples it appears in: a legitimate cycle re-acquires
  #      across stagger, publish and fetch, and a 30 s hold spans six samples at
  #      ${SAMPLE_PERIOD_SECS} s — a count would be boundary-flaky in both
  #      directions.
  sed "s|${FIX_LOCK_PUBLISH}|${FIX_LOCK_PUBLISH_STUCK}|" "${tmp}/samples.ok" \
    > "${tmp}/samples.stucklock"
  _case
  if assert_wake_lock_oracle "${tmp}/power.ok.log" "${tmp}/samples.stucklock" \
       >/dev/null 2>&1; then
    echo "SELF-TEST FAIL (38): a 31 s 'Haven:publish' hold passed a \
${WAKE_LOCK_MAX_AGE_SECS} s ceiling" >&2
    fail=1
  fi

  # (39) The plugin's permanent lock disappearing mid-window. P2a keeps it on
  #      purpose; P2b is the phase that inverts this row.
  grep -v "ForegroundService:WakeLock" "${tmp}/samples.ok" > "${tmp}/samples.nolock" || true
  _case
  if assert_wake_lock_oracle "${tmp}/power.ok.log" "${tmp}/samples.nolock" \
       >/dev/null 2>&1; then
    echo "SELF-TEST FAIL (39): a window without 'ForegroundService:WakeLock' passed" >&2
    fail=1
  fi

  # (40) A held lock whose ACQ= is missing must still be SEEN (so the plugin
  #      lock's presence is judged on its tag) and must still fail the bound (so
  #      an unreadable age is never an unchecked one).
  sed "s|${FIX_LOCK_PUBLISH}|  ${FIX_LOCK_LEVEL} 'Haven:publish' (uid=10123 pid=1111)|" \
    "${tmp}/samples.ok" > "${tmp}/samples.noacq"
  _case
  if assert_wake_lock_oracle "${tmp}/power.ok.log" "${tmp}/samples.noacq" \
       >/dev/null 2>&1; then
    echo "SELF-TEST FAIL (40): a 'Haven:publish' lock with no readable ACQ= age passed" >&2
    fail=1
  fi

  # (41)/(42) The delivery-spacing floor, pinned on both sides of itself, on the
  #      SECOND delivery-driven cycle (its registration is the one the first
  #      delivery's cycle armed). ${MIN_DELIVERY_GAP_SECS} s is a correct run;
  #      one second under it is a real regression.
  _case
  if ! assert_cadence_oracle "${tmp}/power.ok.window" >/dev/null; then
    echo "SELF-TEST FAIL (41): a ${MIN_DELIVERY_GAP_SECS} s delivery gap was rejected" >&2
    assert_cadence_oracle "${tmp}/power.ok.window" >&2 || true
    fail=1
  fi
  build_fixture_logcat "${tmp}/power.tight.log" 2 "${d1_ok}" "${d2_tight}" '04:42:45'
  window_between_markers "${tmp}/power.tight.log" "${MARK_HANDOFF_OK}" "${MARK_HOLD_DONE}" \
    > "${tmp}/power.tight.window"
  _case
  if assert_cadence_oracle "${tmp}/power.tight.window" >/dev/null 2>&1; then
    echo "SELF-TEST FAIL (42): a $((MIN_DELIVERY_GAP_SECS - 1)) s delivery gap passed" >&2
    fail=1
  fi

  # (43) One publish in the whole window: the platform delivered once and never
  #      again, which is the failure mode the delivery-driven cadence replaced a
  #      poll with.
  build_fixture_logcat "${tmp}/power.none.log" 0 "${d1_ok}" "${d2_ok}" '04:42:45'
  window_between_markers "${tmp}/power.none.log" "${MARK_HANDOFF_OK}" "${MARK_HOLD_DONE}" \
    > "${tmp}/power.none.window"
  _case
  if assert_cadence_oracle "${tmp}/power.none.window" >/dev/null 2>&1; then
    echo "SELF-TEST FAIL (43): a window with a single publish passed the cadence oracle" >&2
    fail=1
  fi

  # (44) A delivery that led to NO publish is not a cadence point. Inserted 35 s
  #      before the second real one: counting it would measure the gap from the
  #      wrong end and red a healthy run.
  awk -v ins='08-02 04:42:00.000  1111  1140 I flutter : [BackgroundTask] cycle trigger=delivery' '
    { print }
    index($0, "SAMPLE 4") { print ins }
  ' "${tmp}/power.ok.log" > "${tmp}/power.barren.log"
  window_between_markers "${tmp}/power.barren.log" "${MARK_HANDOFF_OK}" "${MARK_HOLD_DONE}" \
    > "${tmp}/power.barren.window"
  _case
  if ! assert_cadence_oracle "${tmp}/power.barren.window" >/dev/null; then
    echo "SELF-TEST FAIL (44): a delivery that produced no publish was counted as a \
cadence point" >&2
    assert_cadence_oracle "${tmp}/power.barren.window" >&2 || true
    fail=1
  fi

  # (45)/(46) THE SHAPE OF A REAL HEALTHY RUN, and the reason this oracle is
  #      anchored on the registration. A 200 s hold contains the paused-signal
  #      publish plus ONE delivery-driven publish — a second needs two CSPRNG
  #      draws summing under the hold, about one run in six — so a
  #      delivery-to-delivery measurement produced ZERO gaps and an empty loop
  #      on ~83 % of healthy runs. (46) is that exact window with the delivery
  #      one second inside the floor: it MUST fail, and under the old anchor it
  #      passed while measuring nothing.
  local d1_floor d1_tight
  d1_floor="$(_fixture_bump '04:40:08' "${MIN_DELIVERY_GAP_SECS}")"
  d1_tight="$(_fixture_bump '04:40:08' "$((MIN_DELIVERY_GAP_SECS - 1))")"
  build_fixture_logcat "${tmp}/power.single.log" 1 "${d1_floor}" "${d2_ok}" '04:42:45'
  window_between_markers "${tmp}/power.single.log" "${MARK_HANDOFF_OK}" \
    "${MARK_HOLD_DONE}" > "${tmp}/power.single.window"
  _case
  if ! assert_cadence_oracle "${tmp}/power.single.window" >/dev/null; then
    echo "SELF-TEST FAIL (45): the one-delivery window a healthy 200 s hold actually \
produces was rejected at exactly the ${MIN_DELIVERY_GAP_SECS} s floor" >&2
    assert_cadence_oracle "${tmp}/power.single.window" >&2 || true
    fail=1
  fi
  build_fixture_logcat "${tmp}/power.singletight.log" 1 "${d1_tight}" "${d2_ok}" '04:42:45'
  window_between_markers "${tmp}/power.singletight.log" "${MARK_HANDOFF_OK}" \
    "${MARK_HOLD_DONE}" > "${tmp}/power.singletight.window"
  _case
  if assert_cadence_oracle "${tmp}/power.singletight.window" >/dev/null 2>&1; then
    echo "SELF-TEST FAIL (46): a one-delivery window \
$((MIN_DELIVERY_GAP_SECS - 1)) s after its registration passed — the oracle is silent \
on the window a healthy run actually produces" >&2
    fail=1
  fi

  # (47) Two publishes, neither of them delivery-driven. Nothing is measurable,
  #      and "nothing measurable" must never read as "every pair was fine".
  sed 's/trigger=delivery/trigger=watchdog/' "${tmp}/power.single.window" \
    > "${tmp}/power.nodelivery.window"
  _case
  if assert_cadence_oracle "${tmp}/power.nodelivery.window" >/dev/null 2>&1; then
    echo "SELF-TEST FAIL (47): a window with no delivery-driven publish at all passed \
the cadence oracle" >&2
    fail=1
  fi

  # (48) A delivery-driven publish with no registration before it. Unmeasurable
  #      for a different reason, and equally not a pass.
  grep -vF -- "${MARK_REG_ARMED}" "${tmp}/power.single.window" \
    > "${tmp}/power.noarm.window" || true
  _case
  if assert_cadence_oracle "${tmp}/power.noarm.window" >/dev/null 2>&1; then
    echo "SELF-TEST FAIL (48): a delivery with no '${MARK_REG_ARMED}' before it passed" >&2
    fail=1
  fi

  # --- step 8: the no-fix chain under deep idle ----------------------------
  local pub_ok pub_late
  pub_ok="$(_fixture_bump '04:43:34' "${NO_FIX_BOUND_SECS}")"
  pub_late="$(_fixture_bump '04:43:34' "$((NO_FIX_BOUND_SECS + 1))")"

  # (49) Idle engaged, and a watchdog cycle published at exactly the bound.
  build_fixture_idle_logcat "${tmp}/idle.ok.log" 'IDLE' "${pub_ok}"
  _case
  if ! assert_no_fix_chain_oracle "${tmp}/idle.ok.log" >/dev/null; then
    echo "SELF-TEST FAIL (49): a watchdog publish at exactly the ${NO_FIX_BOUND_SECS} s \
bound was rejected" >&2
    assert_no_fix_chain_oracle "${tmp}/idle.ok.log" >&2 || true
    fail=1
  fi

  # (50) Publishing simply stops once the fixes do — the thing step 8 exists to
  #      catch, and the P2b failure mode.
  build_fixture_idle_logcat "${tmp}/idle.silent.log" 'IDLE' 'none'
  _case
  if assert_no_fix_chain_oracle "${tmp}/idle.silent.log" >/dev/null 2>&1; then
    echo "SELF-TEST FAIL (50): a forced-idle phase with no publish at all passed" >&2
    fail=1
  fi

  # (51) ANTI-VACUITY. `force-idle` exits 0 on a device that refuses to doze, so
  #      a publish under `state=ACTIVE` is the ordinary watchdog on an awake
  #      device — already covered by steps 1-7, and no kind of Doze result.
  build_fixture_idle_logcat "${tmp}/idle.awake.log" 'ACTIVE' "${pub_ok}"
  _case
  if assert_no_fix_chain_oracle "${tmp}/idle.awake.log" >/dev/null 2>&1; then
    echo "SELF-TEST FAIL (51): a publish on a device that never entered deep idle passed" >&2
    fail=1
  fi

  # (52) The phase never ran at all (no stamp): also not a pass.
  grep -vF -- "${MARK_IDLE_FORCED}" "${tmp}/idle.ok.log" > "${tmp}/idle.absent.log" || true
  _case
  if assert_no_fix_chain_oracle "${tmp}/idle.absent.log" >/dev/null 2>&1; then
    echo "SELF-TEST FAIL (52): a capture with no '${MARK_IDLE_FORCED}' stamp passed" >&2
    fail=1
  fi

  # (53) One second past the bound. Publishing recovered, but late enough that a
  #      peer's 228 s marker retention had already lapsed.
  build_fixture_idle_logcat "${tmp}/idle.late.log" 'IDLE' "${pub_late}"
  _case
  if assert_no_fix_chain_oracle "${tmp}/idle.late.log" >/dev/null 2>&1; then
    echo "SELF-TEST FAIL (53): a watchdog publish $((NO_FIX_BOUND_SECS + 1)) s after \
idle engaged passed a ${NO_FIX_BOUND_SECS} s bound" >&2
    fail=1
  fi

  # (54) A DELIVERY-driven publish under idle proves the opposite of step 8: the
  #      drip did not stop, so the no-fix chain never ran.
  # `index`/`substr`, not sed: the marker's `[...]` is a character class in a
  # BRE, so a sed pattern would match nothing and hand this fixture back its own
  # passing input — a mutation test that mutates nothing.
  awk -v wd="${MARK_TRIGGER_WATCHDOG}" '
    {
      i = index($0, wd)
      if (i > 0) {
        $0 = substr($0, 1, i - 1) "[BackgroundTask] cycle trigger=delivery" \
             substr($0, i + length(wd))
      }
      print
    }
  ' "${tmp}/idle.ok.log" > "${tmp}/idle.delivery.log"
  _case
  if assert_no_fix_chain_oracle "${tmp}/idle.delivery.log" >/dev/null 2>&1; then
    echo "SELF-TEST FAIL (54): a delivery-driven publish was accepted as the no-fix \
chain" >&2
    fail=1
  fi

  # --- the real image's text (run 34488512808) ------------------------------
  # Every capture above is built from this script's own idea of the grammar,
  # which is how two wrong grammars passed 54 fixtures and failed the first real
  # run. The stamp, registration, Event Log and position lines below are copied
  # from that run's capture; the lock lines follow the AOSP literal (see
  # FIX_LOCK_LEVEL), because that run's filter kept none of them.

  # (55) The stamp with logcat's padded tag column. Verbatim, in capture order.
  printf '%s\n' \
    '09-10 14:54:58.142  4518  4518 I b1power : SAMPLE 8' \
    '09-10 14:54:58.237  4190  4190 I flutter : [b1] HANDOFF_CONFIRMED' \
    '09-10 14:54:58.512  4190  4190 I flutter : [BackgroundTask] Published to 1/1 due circle(s) (1 eligible), fetched 1/1 circle(s).' \
    '09-10 14:55:03.310  4530  4530 I b1power : SAMPLE 9' \
    > "${tmp}/real.log"
  _case
  got="$(last_sample_before "${tmp}/real.log" "${MARK_HANDOFF_OK}")/$(first_sample_after \
    "${tmp}/real.log" "${MARK_PUBLISHED_PREFIX}")"
  if [[ "${got}" != "8/9" ]]; then
    echo "SELF-TEST FAIL (55): the real capture's stamps placed the handoff/publish at \
'${got}', expected '8/9' — the stamp grammar no longer matches the device" >&2
    fail=1
  fi

  # (56)/(57) The anti-vacuity guard names its cause. Samples on disk whose
  #      stamps the capture does not contain are a stamp-grammar change, which
  #      the old message reported as a dead sampler; with no samples on disk it
  #      must not claim a grammar change either.
  sed 's/b1power : SAMPLE/b1power: SAMPLE/' "${tmp}/power.ok.log" \
    > "${tmp}/power.unstamped.log"
  : > "${tmp}/samples.none"
  _case
  if got="$(assert_registration_oracle "${tmp}/power.unstamped.log" "${tmp}/samples.ok" \
       "${tmp}/power.ok.window")" || [[ "${got}" != *"stamp grammar changed"* ]]; then
    echo "SELF-TEST FAIL (56): unrecognised stamps beside written samples were not \
reported as a stamp-grammar change: '${got}'" >&2
    fail=1
  fi
  _case
  if got="$(assert_registration_oracle "${tmp}/power.unstamped.log" "${tmp}/samples.none" \
       "${tmp}/power.ok.window")" || [[ "${got}" != *"sampler died"* ]]; then
    echo "SELF-TEST FAIL (57): an empty sample file was not reported as a dead sampler: \
'${got}'" >&2
    fail=1
  fi

  # The sampler's own filter over two raw dumps: the foreground's, then the
  # first background one.
  {
    printf '%s\n' '09-10 14:54:52.000' \
      '        10192/com.oblivioustech.haven/BA8E03C9 Request[@+1s0ms HIGH_ACCURACY, minUpdateDistance=1.0, WorkSource{10192 com.oblivioustech.haven}]' \
      '      last location=Location[fused 52.370215,4.895167 hAcc=5.0 et=+9m1s978ms alt=0.0 vAcc=0.5 vel=0.0 sAcc=0.5]' \
      'Wake Locks: size=0' | filter_power_sample 7
    printf '%s\n' '09-10 14:54:58.000' \
      '        10192/com.oblivioustech.haven/4E055D0E Request[@+2m24s79ms HIGH_ACCURACY, WorkSource{10192 com.oblivioustech.haven}]' \
      '      last location=Location[fused 52.370215,4.895167 hAcc=5.0 et=+9m1s978ms alt=0.0 vAcc=0.5 vel=0.0 sAcc=0.5]' \
      '    09-10 14:54:51.171: fused provider +registration 10192/com.oblivioustech.haven/BA8E03C9 -> Request[@+1s0ms HIGH_ACCURACY, minUpdateDistance=1.0, WorkSource{10192 com.oblivioustech.haven}]' \
      'Wake Locks: size=2' \
      "  ${FIX_LOCK_LEVEL} 'ForegroundService:WakeLock' ACQ=-4s98ms (uid=10192 pid=4190)" \
      "  ${FIX_LOCK_LEVEL} 'Haven:publish' ACQ=-326ms (uid=10192 pid=4190)" \
      | filter_power_sample 8
  } > "${tmp}/samples.real"

  # (58) Both locks survive the filter and parse — the second one sampled
  #      inside its first second, where TimeUtils drops the seconds field.
  _case
  got="$(wake_lock_records "${tmp}/samples.real" 7 8 | tr '\n' ' ')"
  if [[ "${got}" != "8|ForegroundService:WakeLock|4098 8|Haven:publish|326 " ]]; then
    echo "SELF-TEST FAIL (58): the padded lock lines did not survive the sampler's \
filter and parse, got '${got}'" >&2
    fail=1
  fi

  # (59) Exactly the two live registrations, read through the WorkSource suffix
  #      the real image appends — and not the Event Log's replay beside them.
  _case
  got="$(location_request_records "${tmp}/samples.real" 7 8 | cut -d'|' -f1-3 \
    | tr '\n' ' ')"
  if [[ "${got}" != "7|1000|1.0 8|144079|- " ]]; then
    echo "SELF-TEST FAIL (59): the real registrations parsed as '${got}', expected \
'7|1000|1.0 8|144079|- '" >&2
    fail=1
  fi

  # (60) No position reaches the uploaded sample file.
  _case
  if grep -qF '52.370215' "${tmp}/samples.real"; then
    echo "SELF-TEST FAIL (60): the sampler's filter let a coordinate through" >&2
    fail=1
  fi

  # (61) TimeUtils' sub-second form is a duration, not a grammar change…
  _case
  got="$(formatted_duration_ms '-326ms' || echo 'REJECTED')"
  if [[ "${got}" != "-326" ]]; then
    echo "SELF-TEST FAIL (61): '-326ms' should be -326 ms, got '${got}'" >&2
    fail=1
  fi
  # (62) …but only under a second: past one, AOSP always prints the seconds.
  _case
  if formatted_duration_ms '+1500ms' >/dev/null 2>&1; then
    echo "SELF-TEST FAIL (62): '+1500ms' (a seconds field AOSP would have printed) was \
accepted" >&2
    fail=1
  fi

  # --- the failure path shows its evidence ----------------------------------
  # Line numbers of the non-comment lines that silence stderr BEFORE pointing
  # stdout at it. Redirections bind left to right, so that order sends both to
  # /dev/null: run 34488512808's "last power samples" dump printed nothing over
  # a 151 KB sample file. Every stage reads to EOF, so nothing can SIGPIPE.
  _silenced_dumps() {
    { grep -nE '2>[[:space:]]*/dev/null[[:space:]]*1?>&2' "$1" || true; } \
      | { grep -vE '^[0-9]+:[[:space:]]*#' || true; } | cut -d: -f1 | tr '\n' ' '
  }
  # Assembled at run time, so the scan of this file in (64) never sees it.
  local silenced="tail -30 file 2>/dev/null"
  {
    printf '%s\n' 'tail -30 file >&2 2>/dev/null'
    printf '%s\n' "${silenced} >&2"
    printf '%s\n' "  # ${silenced} >&2, described in a comment"
    printf '%s\n' "${silenced}>&2"
  } > "${tmp}/redirects.sh"

  # (63) The detector flags both spellings of the bad order, and neither the
  #      good order nor a comment.
  _case
  got="$(_silenced_dumps "${tmp}/redirects.sh")"
  if [[ "${got}" != "2 4 " ]]; then
    echo "SELF-TEST FAIL (63): the redirect-order detector flagged lines '${got}', \
expected '2 4 '" >&2
    fail=1
  fi

  # (64) …and this script has no such line.
  _case
  got="$(_silenced_dumps "${BASH_SOURCE[0]}")"
  if [[ -n "${got}" ]]; then
    echo "SELF-TEST FAIL (64): line(s) ${got}of this script send a dump's own output \
to /dev/null (write \`>&2 2>/dev/null\`, stdout first)" >&2
    fail=1
  fi

  # (65) The sampler is stopped at a sample boundary AND waited for before any
  #      oracle reads its file. The stop is inline in the main flow, so this pins
  #      its shape, in order: the loop that checks SAMPLER_STOP, the `touch`,
  #      the bounded wait, the only `kill` (its fallback), the `wait`, the first
  #      oracle read. A `kill` anywhere earlier brings the read-before-exit race
  #      back; losing the fallback lets a sampler stuck in adb hang the lane.
  local self="${BASH_SOURCE[0]}" loop_at stop_at bound_at kill_at wait_at read_at
  # Anchored at the line start, or these very lines would be the matches.
  loop_at="$(grep -m1 -nE '^  until \[\[ -e "\$\{SAMPLER_STOP\}" \]\]; do$' "${self}" \
    | cut -d: -f1 || true)"
  stop_at="$(grep -m1 -nE '^touch "\$\{SAMPLER_STOP\}"$' "${self}" | cut -d: -f1 || true)"
  bound_at="$(grep -m1 -nE '^for \(\( waited = 0; ' "${self}" | cut -d: -f1 || true)"
  kill_at="$(awk -v from="${loop_at:-0}" \
    'NR > from && index($0, "kill \"${SAMPLE_PID}\"") { print NR; exit }' "${self}")"
  wait_at="$(grep -m1 -nE '^wait "\$\{SAMPLE_PID\}"' "${self}" | cut -d: -f1 || true)"
  read_at="$(grep -m1 -nE '^if ! oracle_out="\$\(assert_registration_oracle ' "${self}" \
    | cut -d: -f1 || true)"
  _case
  if [[ -z "${loop_at}" || -z "${stop_at}" || -z "${bound_at}" || -z "${kill_at}" \
        || -z "${wait_at}" || -z "${read_at}" ]] \
     || (( loop_at > stop_at || stop_at > bound_at || bound_at > kill_at \
           || kill_at > wait_at || wait_at > read_at )); then
    echo "SELF-TEST FAIL (65): the sampler is no longer stopped between samples and \
waited for before the oracles read (loop ${loop_at:-?}, stop ${stop_at:-?}, bounded \
wait ${bound_at:-?}, kill ${kill_at:-?}, wait ${wait_at:-?}, read ${read_at:-?})" >&2
    fail=1
  fi

  if (( checked != SELF_TEST_FIXTURES )); then
    echo "SELF-TEST FAIL: ran ${checked} fixture(s), expected ${SELF_TEST_FIXTURES}" >&2
    fail=1
  fi
  if (( fail != 0 )); then
    echo "run-b1-fgs-publish.sh --self-test: FAILED" >&2
    return 1
  fi
  echo "run-b1-fgs-publish.sh --self-test: ${checked} fixtures passed"
  return 0
}

if [[ "${1:-}" == "--self-test" ]]; then
  run_self_test
  exit $?
fi

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
readonly DEVICE="emulator-5554"
readonly DRIVER_FILE="test_driver/integration_test.dart"
readonly LOG_DIR="/tmp/b1-logs"
readonly APK="${1:-/tmp/integration-apks/b1_fgs_live_foreground_test.apk}"
readonly TARGET="${2:-integration_test/b1_fgs_live_foreground_test.dart}"

# The drive owns the whole timeline: arm, deliver the lifecycle pause, and HOLD
# the widget tree mounted while the FGS runs its cycles (the tree must stay up,
# or flutter_test's post-test unmount stops the service — see Phase 4). So this
# bounds arming + BOTH of the drive's holds — the steady-state one (one
# kLocationPublishMaxInterval plus slack, 200 s: the latest a delivery-driven
# publish can land after the handoff cycle) and the forced-idle one (332 s: the
# no-fix chain's own length, step 8) — plus RustLib/keyring/SQLCipher boot under
# the emulator's mlock pressure, plus GPS and relay slack, plus the broadcast
# barrier below. The drive target's own `Timeout` is 14m and fires first with an
# attributable message; this is the belt. Phase 5 holds no timeouts of its own —
# by the time it reads, the capture is complete, so it is a set of reads rather
# than live polls.
readonly DRIVE_TIMEOUT="${B1_DRIVE_TIMEOUT:-20m}"

# The bound on `am wait-for-broadcast-barrier` (Phase 4): ~3.5x the 34 s the
# install broadcasts took to reach LocationManagerService in run 34488512808.
# The drive's own wait (`_broadcastBarrierWait`, 150 s) outlasts it, so a
# barrier that never drains is reported HERE, by name.
readonly BARRIER_TIMEOUT_SECS=120

# Synthetic coordinates fed to the emulator's GPS: Dam Square, Amsterdam — a
# well-known public landmark, chosen precisely BECAUSE it is obviously not a
# real user's position. The kind-445 carrying it is MLS-encrypted on the wire.
#
# WARNING before overriding these: `fail()` dumps `dumpsys location`, which
# PRINTS the active position into the step log and the uploaded artifact. That
# is fine for a hardcoded landmark and NOT fine for anything derived from a real
# device or person. If backlog B3/B4 make coordinates assertion-relevant, keep
# them synthetic or drop the location dump.
readonly GEO_LON="${B1_GEO_LON:-4.895168}"
readonly GEO_LAT="${B1_GEO_LAT:-52.370216}"

readonly HAVEN_DIR="${REPO_ROOT}/haven"
readonly START_STRFRY="${SCRIPT_DIR}/start-strfry.sh"
readonly STOP_STRFRY="${SCRIPT_DIR}/stop-strfry.sh"
readonly SECRET_SCAN="${SCRIPT_DIR}/scan-logs-for-secrets.sh"

LOGCAT_PID=""
GEO_PID=""
SAMPLE_PID=""
IDLE_PID=""
BARRIER_PID=""

mkdir -p "${LOG_DIR}"
readonly LOGCAT_FILE="${LOG_DIR}/logcat.b1.log"
readonly DRIVE_LOG="${LOG_DIR}/flutter-drive.log"
readonly SAMPLE_FILE="${LOG_DIR}/dumpsys-power-samples.log"

# ---------------------------------------------------------------------------
# Cleanup (EXIT trap): stop the background helpers, run the MANDATORY secret
# scan over every captured log (Security Rule 6 — must run even on a phase
# failure), snapshot + tear down strfry. Escalates on a leak; never masks a
# phase rc.
# ---------------------------------------------------------------------------
cleanup() {
  local rc=$?
  local scan_rc=0
  trap - EXIT
  if [[ -n "${GEO_PID}" ]] && kill -0 "${GEO_PID}" 2>/dev/null; then
    kill "${GEO_PID}" 2>/dev/null || true
  fi
  if [[ -n "${SAMPLE_PID}" ]] && kill -0 "${SAMPLE_PID}" 2>/dev/null; then
    kill "${SAMPLE_PID}" 2>/dev/null || true
  fi
  if [[ -n "${IDLE_PID}" ]] && kill -0 "${IDLE_PID}" 2>/dev/null; then
    kill "${IDLE_PID}" 2>/dev/null || true
  fi
  if [[ -n "${BARRIER_PID}" ]] && kill -0 "${BARRIER_PID}" 2>/dev/null; then
    kill "${BARRIER_PID}" 2>/dev/null || true
  fi
  if [[ -n "${LOGCAT_PID}" ]] && kill -0 "${LOGCAT_PID}" 2>/dev/null; then
    kill "${LOGCAT_PID}" 2>/dev/null || true
  fi
  # Leave the device as we found it. Both are no-ops on a run that never
  # reached step 8, and both must run even on a failed phase: the workflow's
  # `if: failure()` diagnostics step talks to this device afterwards, and a
  # forced-idle, battery-unplugged emulator answers some of those questions
  # differently for no reason connected to the failure being triaged.
  adb -s "${DEVICE}" shell dumpsys deviceidle unforce >/dev/null 2>&1 || true
  adb -s "${DEVICE}" shell dumpsys battery reset >/dev/null 2>&1 || true
  docker logs strfry > "${LOG_DIR}/strfry.final.log" 2>&1 || true
  echo "== Secret-leak scan over ${LOG_DIR} (Security Rule 6) =="
  bash "${SECRET_SCAN}" "${LOG_DIR}" || scan_rc=$?
  if (( scan_rc == 1 )); then
    # CONTAINMENT, not just detection. The workflow uploads ${LOG_DIR} with
    # `if: always()` and a 14-day retention, so merely going red here would
    # publish the leaking log for a fortnight — the guard would tell us about
    # the leak while shipping it. Destroy the logs and leave a marker instead;
    # the scanner has already printed file + label + line numbers (never the
    # matched content), which is everything triage needs.
    find "${LOG_DIR}" -type f -name '*.log' -delete 2>/dev/null || true
    {
      echo "Logs withheld: the secret-leak guard tripped (Security Rule 6)."
      echo "See the LEAK line(s) in the step log for file/label/line numbers."
    } > "${LOG_DIR}/LEAK_DETECTED.txt"
    echo "ERROR: secret-leak guard tripped on B1 logs — logs deleted, not uploaded." >&2
    rc=1
  elif (( scan_rc != 0 )); then
    # rc 3 = a log was absent / unreadable / EMPTY, i.e. this lane died before
    # it finished writing its evidence. Go red — a run that scanned nothing has
    # proved nothing — but deliberately do NOT take the containment branch.
    # Deletion exists to stop a LEAK from being published; there is no leak
    # here, only the truncated crash artefacts that triage needs most, and
    # destroying them would erase the evidence of the very failure that tripped
    # the guard.
    echo "ERROR: secret-leak guard could not scan the B1 logs (rc=${scan_rc}) —" \
         "see the UNUSABLE line(s) above. Logs kept for triage." >&2
    rc=1
  fi
  bash "${STOP_STRFRY}" >/dev/null 2>&1 || true
  exit "${rc}"
}
trap cleanup EXIT

fail() {
  echo "B1-LANE-FAIL: $*" >&2
  # A deferred drive failure changes how EVERY later message should be read.
  # Without this note, a drive that died before arming makes the oracle's step-1
  # message ("the foreground never handed off … this lane proved nothing") read
  # as a product defect, which is exactly the kind of claim this lane exists to
  # make credibly. Attribute it here rather than letting the terminal
  # drive-failure `fail()` carry it — that one is unreachable once any earlier
  # oracle step fails.
  if (( ${drive_failed:-0} == 1 )); then
    echo "NOTE: the drive ALSO did not complete cleanly (${drive_reason:-unknown})." \
         "The finding above may be a CONSEQUENCE of that rather than a product" \
         "defect — rule the drive failure out first." >&2
  fi
  echo "---- [BackgroundTask] lines seen ----" >&2
  grep -aF '[BackgroundTask]' "${LOGCAT_FILE}" 2>/dev/null | tail -40 >&2 || \
    echo "(none — the FGS isolate logged nothing at all)" >&2
  # Emulator location state. B1 is the FIRST lane to need a REAL position (every
  # other scenario injects FakeLocationService), so a silent GPS failure is a
  # live risk and would otherwise present as an unattributed publish timeout.
  # Two known traps: `adb emu geo fix` is a ONE-SHOT injection into the goldfish
  # GNSS HAL with no stream between injections (hence the re-issue loop), and the
  # AVD runs a `google_apis` image where geolocator may resolve to FUSED location
  # while `geo fix` documents only the LocationManager provider.
  echo "---- emulator location state ----" >&2
  # `sed`, not `head`: under pipefail a `head` that stops reading SIGPIPEs grep,
  # and run 34488512808 printed forty lines and then "(dumpsys location
  # unavailable)".
  adb -s "${DEVICE}" shell dumpsys location 2>/dev/null \
    | grep -aiA 4 'last location\|fused\|gps provider' | sed -n '1,40p' >&2 || \
    echo "(dumpsys location unavailable)" >&2
  # The last few power samples, for the steps-5/6 findings: which requests and
  # locks were actually seen is the whole evidence base for those, and reading
  # the parser's verdict without them is guesswork.
  echo "---- last power samples ----" >&2
  # Stdout to stderr FIRST: the reverse order sends both to /dev/null, which is
  # why run 34488512808 printed nothing here from a 151 KB sample file.
  tail -30 "${SAMPLE_FILE}" >&2 2>/dev/null || \
    echo "(no power samples were captured)" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# Phase 0 — hermetic relay + device readiness.
# ---------------------------------------------------------------------------
echo "Phase 0/5 — starting hermetic strfry..."
bash "${START_STRFRY}"
adb -s "${DEVICE}" wait-for-device
echo "Phase 0/5 — device ready."

# ---------------------------------------------------------------------------
# Phase 1 — clean install. Force-stop + uninstall FIRST so no sticky FGS from a
# prior target survives into this run (see run-single-avd-scenario.sh Phase 2).
# ---------------------------------------------------------------------------
echo "Phase 1/5 — installing ${APK}..."
[[ -f "${APK}" ]] || fail "APK not found: ${APK} (was the build step skipped?)"
adb -s "${DEVICE}" shell am force-stop "${PKG}" || true
adb -s "${DEVICE}" uninstall "${PKG}" >/dev/null 2>&1 || true
adb -s "${DEVICE}" install -r "${APK}"

# ---------------------------------------------------------------------------
# Phase 2 — runtime permissions, plus the ACCESS_BACKGROUND_LOCATION PROBE.
#
# The probe answers a question the repo has been carrying as an untested
# assertion: `run-single-avd-scenario.sh:323` and `docs/M7_BACKGROUND_SHARING.md`
# both state that `pm grant` cannot grant ACCESS_BACKGROUND_LOCATION on API 30+.
# It is recorded as EVIDENCE (grant attempt + authoritative read-back), never as
# a gate: this lane must not turn red over a diagnostic. See the lane's docs
# entry for the verdict once a run has published one.
#
# B1 itself should not NEED background location: the FGS declares
# `foregroundServiceType="location"`, which is what keeps location flowing while
# the UI is hidden. The probe exists to settle the claim and to explain the
# failure fast if that assumption turns out to be wrong.
# ---------------------------------------------------------------------------
echo "Phase 2/5 — granting runtime permissions..."
for perm in \
  android.permission.ACCESS_FINE_LOCATION \
  android.permission.ACCESS_COARSE_LOCATION \
  android.permission.POST_NOTIFICATIONS
do
  if adb -s "${DEVICE}" shell pm grant "${PKG}" "${perm}"; then
    echo "  granted ${perm}"
  else
    fail "could not grant ${perm} — the lane cannot acquire a GPS fix without it."
  fi
done

# --- ACCESS_BACKGROUND_LOCATION probe ---------------------------------------
#
# `pm grant`'s EXIT CODE IS WORTHLESS HERE. ACCESS_BACKGROUND_LOCATION is a
# hardRestricted permission in AOSP (`core/res/AndroidManifest.xml`, unchanged
# across android11..android15), and the gate in
# `PermissionManagerServiceImpl.grantRuntimePermissionInternal` is a bare
# `return` after a `Log.e` — no exception, no non-zero exit. A silently-failed
# grant is textually identical to a successful one.
#
# It is nevertheless expected to SUCCEED here: `adb install` goes through
# `PackageManagerShellCommand.makeInstallParams()`, which sets
# INSTALL_ALL_WHITELIST_RESTRICTED_PERMISSIONS by default (only the explicit
# `--restrict-permissions` flag clears it), so the package is installer-exempt
# and the hard-restricted gate passes. The long-standing claim in this repo that
# `pm grant` "cannot grant it on API 30+" conflated that with the SEPARATE
# Android 11 runtime-API rule that an app cannot REQUEST background location in
# the same `requestPermissions()` call as foreground location. `pm grant` never
# enters `GrantPermissionsActivity`, so that rule does not apply to it.
#
# Recorded as EVIDENCE, never as a gate: B1 should not need this permission at
# all, because the FGS is started while the activity is VISIBLE and
# `foregroundServiceType="location"` carries location access from there. The
# permission matters for the FGS-on-BOOT path (API 34+ refuses to create a
# `location` FGS from the background without it), which this lane does not test.
#
# The app-op read-back is POLLED, not read once: PermissionPolicyService
# synchronises the permission→app-op mapping asynchronously on FgThread, so an
# immediate read can still show `foreground` on a grant that did land.
echo "== SPIKE PROBE: ACCESS_BACKGROUND_LOCATION on API $(adb -s "${DEVICE}" shell getprop ro.build.version.sdk | tr -d '\r') =="
adb -s "${DEVICE}" shell pm grant "${PKG}" android.permission.ACCESS_BACKGROUND_LOCATION 2>&1 \
  | sed 's/^/    /' || true
echo "  read-back (dumpsys package — authoritative grant state):"
adb -s "${DEVICE}" shell dumpsys package "${PKG}" 2>/dev/null \
  | grep -a "ACCESS_BACKGROUND_LOCATION" | sed 's/^/    /' \
  || echo "    (permission not listed)"
# Single read, not a poll. An earlier revision polled this for 30s expecting
# `allow` vs `foreground`; run 30753193231 showed it reports NOTHING for the
# location ops on a fresh install, because `cmd appops get` lists only ops the
# package has actually exercised — there is no entry to read before the first
# location access. Polling for a line that cannot exist just burned the full
# deadline. Kept as one informational read; `dumpsys package` above is the
# authoritative grant state and is what the assertions would ever key on.
echo "  read-back (appops — informational; empty is normal pre-first-use):"
adb -s "${DEVICE}" shell cmd appops get "${PKG}" 2>/dev/null \
  | grep -aiE 'COARSE_LOCATION|FINE_LOCATION' | sed 's/^/    /' \
  || echo "    (no location app-ops reported yet)"
echo "  authoritative failure signal (expect NO match):"
adb -s "${DEVICE}" logcat -d 2>/dev/null \
  | grep -a "Cannot grant hard restricted non-exempt permission" | sed 's/^/    /' \
  || echo "    (none — the hard-restricted gate did not reject the grant)"
echo "== END SPIKE PROBE =="

# ---------------------------------------------------------------------------
# Phase 3 — feed the emulator a GPS fix, and keep feeding it.
#
# The FGS isolate uses the REAL GeolocatorLocationService (overrides injected in
# the drive isolate do not reach it), and `_publishCycle` takes a ONE-SHOT
# `getCurrentLocation()` per due circle. `adb emu geo fix` sets the emulated
# position, but a single fix can age out before the cycle that needs it, so it
# is re-issued on a short loop for the life of the lane.
#
# NOTE the argument order: `geo fix` takes LONGITUDE first, then LATITUDE.
# ---------------------------------------------------------------------------
echo "Phase 3/5 — seeding emulator GPS (lon=${GEO_LON} lat=${GEO_LAT})..."
adb -s "${DEVICE}" emu geo fix "${GEO_LON}" "${GEO_LAT}"
(
  while sleep 10; do
    adb -s "${DEVICE}" emu geo fix "${GEO_LON}" "${GEO_LAT}" >/dev/null 2>&1 || true
  done
) &
GEO_PID=$!

# ---------------------------------------------------------------------------
# Phase 4 — drive the target, then hand off.
#
# `--keep-app-running` is LOAD-BEARING. Without it `flutter drive` (with
# --use-application-binary) stops the app on completion, and on Android that is
# `adb shell am force-stop` — which kills the foreground service this entire
# lane is about to observe, AND releases the foreground MLS session whose
# retention is the precondition for P0-1. The lane would then pass vacuously.
# ---------------------------------------------------------------------------
echo "Phase 4/5 — capturing logcat and driving ${TARGET}..."
adb -s "${DEVICE}" logcat -c || true
adb -s "${DEVICE}" logcat -v threadtime > "${LOGCAT_FILE}" 2>&1 &
LOGCAT_PID=$!

# The power sampler, started BEFORE the drive and not after it.
#
# The foreground 1 s / 1 m request exists only while the map is up, which is
# inside the drive; a sampler started later can miss it entirely and then fail
# the anti-vacuity read on a perfectly healthy run. ${SAMPLE_PERIOD_SECS} s is
# the cadence, so the shortest thing the oracles reason about (a 30 s wake-lock
# ceiling) is covered several times over.
#
# ONE `adb shell` per sample, deliberately: the logcat stamp, the device clock
# and both dumps come from the same device round trip, so the sample cannot be
# mis-ordered against the drive's markers by host scheduling. The stamp is
# written FIRST, so the dumps describe the instant just after it. What survives
# of each dump is `filter_power_sample`'s decision (see there, and --self-test).
#
# Each sample is assembled into a scratch file OUTSIDE the uploaded directory
# and appended whole, and the loop stops only BETWEEN samples, when
# SAMPLER_STOP appears. A `kill` could land inside the append — severing a line
# mid-`Request[`, which the parser cannot tell from a grammar change — and would
# leave the append running after the orchestrator had moved on to read the file.
sample_part="${LOG_DIR}.part"
readonly SAMPLER_STOP="${LOG_DIR}.stop-sampler"
rm -f "${SAMPLER_STOP}"
(
  n=0
  until [[ -e "${SAMPLER_STOP}" ]]; do
    n=$((n + 1))
    {
      adb -s "${DEVICE}" shell \
        "log -p i -t ${SAMPLE_TAG} 'SAMPLE ${n}'; date '+%m-%d %H:%M:%S.000'; dumpsys location; dumpsys power" \
        2>/dev/null | tr -d '\r' | filter_power_sample "${n}" > "${sample_part}" \
        && cat "${sample_part}" >> "${SAMPLE_FILE}"
    } || true
    sleep "${SAMPLE_PERIOD_SECS}"
  done
) 2>/dev/null &
SAMPLE_PID=$!

# The step-8 driver.
#
# It has to act DURING the drive — the forced-idle phase is a second hold inside
# the same test body, held open while the tree is still mounted — so it waits on
# the drive's own marker in the growing logcat capture instead of being
# sequenced by this script. The drive prints `${MARK_IDLE_BEGIN}` only AFTER
# `${MARK_HOLD_DONE}` has closed the P2a window, so nothing below can disturb
# the span steps 5-7 read.
#
# Stopping the drip is the whole experiment: `adb emu geo fix` is a one-shot
# injection with no stream between injections, so with the loop dead the
# registration this lane just proved has nothing left to deliver and the only
# way another location reaches a relay is the no-fix chain.
#
# `battery unplug` first, because `DeviceIdleController.updateChargingLocked()`
# drops the device straight back to ACTIVE on a charging event and the emulator
# reports AC-plugged; `enable deep` because a device whose deep idle is disabled
# answers `force-idle` with a message and exit code 0. The authoritative answer
# is neither of those but the `get deep` read-back, which is stamped into logcat
# for the oracle — see MARK_IDLE_FORCED.
(
  until grep -aqF -- "${MARK_IDLE_BEGIN}" "${LOGCAT_FILE}" 2>/dev/null; do
    sleep 2
  done
  echo "Phase 4/5 — forced-idle phase: stopping the GPS drip and dozing the device..."
  if [[ -n "${GEO_PID}" ]] && kill -0 "${GEO_PID}" 2>/dev/null; then
    kill "${GEO_PID}" 2>/dev/null || true
  fi
  adb -s "${DEVICE}" shell dumpsys battery unplug >/dev/null 2>&1 || true
  adb -s "${DEVICE}" shell dumpsys deviceidle enable deep >/dev/null 2>&1 || true
  adb -s "${DEVICE}" shell dumpsys deviceidle force-idle >/dev/null 2>&1 || true
  idle_state="$(adb -s "${DEVICE}" shell dumpsys deviceidle get deep 2>/dev/null \
    | tr -d '\r' | awk 'NF { print $1; exit }')" || idle_state=""
  [[ -n "${idle_state}" ]] || idle_state="UNREADABLE"
  echo "Phase 4/5 — deep-idle state: ${idle_state}"
  adb -s "${DEVICE}" shell \
    "log -p i -t ${SAMPLE_TAG} '${MARK_IDLE_FORCED}${idle_state}'" >/dev/null 2>&1 || true
) &
IDLE_PID=$!

# The broadcast barrier.
#
# `flutter drive` force-stops and reinstalls the app immediately before it
# launches it, and LocationManagerService answers both broadcasts
# (PACKAGE_RESTARTED, and PACKAGE_REMOVED for the replaced install) by deleting
# every location registration the package holds — with no callback, no stream
# error and, on a user build, no log line (SystemPackageResetHelper ->
# LocationProviderManager.onPackageReset). A freshly booted emulator's queue is
# backed up: in run 34488512808 they arrived 34 s after the install, 8 s after
# the FGS armed its first registration, which vanished between two samples and
# left the 200 s proof window with nothing that could deliver. That run stopped
# at step 5; replayed through the fixed parsers, its step 7 fails a product
# that did nothing wrong.
#
# So the drive waits, before it mounts anything that can register, for this
# script to flush them. `am wait-for-broadcast-barrier` (a latch with no timeout
# of its own) returns once every broadcast enqueued before it has been handed to
# its receiver, and `flutter drive`'s were enqueued before the launch that
# printed the marker. The reset itself then crosses up to three in-process hops
# (FgThread, main looper, FgThread) that nothing outside system_server can wait
# on: a margin of one app bootstrap, not a barrier. Losing it can only redden
# the lane — the registration vanishes — never pass it.
(
  until grep -aqF -- "${MARK_BARRIER_AWAIT}" "${LOGCAT_FILE}" 2>/dev/null; do
    sleep 1
  done
  barrier_rc=0
  timeout "${BARRIER_TIMEOUT_SECS}" \
    adb -s "${DEVICE}" shell am wait-for-broadcast-barrier >/dev/null 2>&1 \
    || barrier_rc=$?
  if (( barrier_rc == 124 )); then
    barrier_state="NOT flushed within ${BARRIER_TIMEOUT_SECS} s"
  elif (( barrier_rc != 0 )); then
    barrier_state="am wait-for-broadcast-barrier failed (rc=${barrier_rc})"
  elif ! adb -s "${DEVICE}" shell run-as "${PKG}" touch "${BARRIER_FILE}" \
       >/dev/null 2>&1; then
    barrier_state="flushed, but run-as could not create ${BARRIER_FILE}"
  else
    barrier_state="flushed"
  fi
  # The drive fails on its own bounded wait when this is not "flushed"; this
  # line is what names why.
  echo "Phase 4/5 — broadcast barrier: ${barrier_state}"
) &
BARRIER_PID=$!

drc=0
( cd "${HAVEN_DIR}" && timeout --kill-after=30s "${DRIVE_TIMEOUT}" flutter drive \
    --no-pub \
    --keep-app-running \
    --device-id "${DEVICE}" \
    --use-application-binary "${APK}" \
    --driver "${DRIVER_FILE}" \
    --target "${TARGET}" ) > "${DRIVE_LOG}" 2>&1 || drc=$?

# Stop sampling when the drive ends, and WAIT until the sampler has exited
# before anything reads its file: signalling it and reading at once is the
# read-before-exit race the KPR lane hit in run 34488512808. Everything the
# oracles read happened inside the drive, and the teardown after it is not
# evidence. The bound is three sample periods — two for the sample in flight
# (sub-second in that run) and the sleep it then finishes. A sampler still alive
# past that is blocked in `adb`, not in its append, so killing it is safe.
touch "${SAMPLER_STOP}"
for (( waited = 0; waited < 3 * SAMPLE_PERIOD_SECS; waited++ )); do
  kill -0 "${SAMPLE_PID}" 2>/dev/null || break
  sleep 1
done
if kill -0 "${SAMPLE_PID}" 2>/dev/null; then
  echo "WARN: the power sampler did not stop within $((3 * SAMPLE_PERIOD_SECS)) s; \
killed while blocked in adb." >&2
  kill "${SAMPLE_PID}" 2>/dev/null || true
fi
wait "${SAMPLE_PID}" 2>/dev/null || true
SAMPLE_PID=""
if [[ -n "${IDLE_PID}" ]] && kill -0 "${IDLE_PID}" 2>/dev/null; then
  kill "${IDLE_PID}" 2>/dev/null || true
fi
IDLE_PID=""
if [[ -n "${BARRIER_PID}" ]] && kill -0 "${BARRIER_PID}" 2>/dev/null; then
  kill "${BARRIER_PID}" 2>/dev/null || true
fi
BARRIER_PID=""
rm -f "${sample_part}"
# Scan BEFORE echoing. The EXIT trap's scan runs far too late to protect this:
# GitHub Actions step logs have no retention control and cannot be redacted
# after the fact, so an unscanned `cat` of the drive log is a wider, more
# permanent sink than the artifact upload the trap does guard.
drive_log_clean=1
if bash "${SECRET_SCAN}" "${DRIVE_LOG}"; then
  cat "${DRIVE_LOG}" || true
else
  drive_log_clean=0
  echo "drive log withheld from the step log — secret-leak guard tripped." >&2
fi

# Record the drive's verdict WITHOUT exiting on it yet.
#
# The oracle below reads logcat, and its findings are the point of this lane —
# in CI run 30753193231 the drive hung to its own 10-minute timeout while the
# FGS had ALREADY logged `onStart FAILED`, i.e. P0-1 reproduced. Exiting here
# would have thrown that away and reported the misleading "the app was never
# armed" instead. Phase 5 step 1 independently proves the arming reached the
# handoff, so a broken drive cannot make the oracle read as a pass; the
# deferred failure is re-raised at the end so a bad drive still fails the lane.
#
# `drc == 0` alone is not trustworthy: `flutter drive` exits 0 when the failure
# happened outside a `testWidgets` body (drive-log-lib.sh).
drive_failed=0
drive_reason=""
if (( drc != 0 )); then
  drive_failed=1
  drive_reason="flutter drive exited ${drc}"
elif drive_log_reports_test_failure "${DRIVE_LOG}"; then
  drive_failed=1
  drive_reason="flutter drive exited 0 but the on-device suite reported failures"
fi
if (( drive_failed == 1 )); then
  echo "WARN: ${drive_reason} for ${TARGET}. Continuing to the oracle anyway —" \
       "its logcat findings are this lane's deliverable and are valid as long" \
       "as step 1 confirms the handoff. This is re-raised as a failure at the" \
       "end regardless of the oracle's verdict." >&2
  # Gated on the SAME containment decision made above: this prints raw drive-log
  # lines, and echoing them after the secret-leak guard tripped would defeat the
  # withholding by the back door — into the step log, which has no retention
  # control and cannot be redacted after the fact.
  if (( drive_log_clean == 1 )); then
    drive_log_failure_evidence "${DRIVE_LOG}" >&2
  else
    echo "  (evidence withheld — secret-leak guard tripped on this log)" >&2
  fi
fi

# NOTE: no `input keyevent HOME` here, and that is deliberate.
#
# An earlier revision pressed HOME after the drive and expected MapShell's real
# `_onPaused()` to fire. It cannot: `flutter_test` unmounts the widget tree on a
# PASSING test (`binding.dart:1684-1691`, `runApp(Container(...)) // Unmount any
# remaining widgets`), which disposes the ProviderScope, fires
# `backgroundServiceLifecycleProvider`'s `ref.onDispose(() => fns.stop())`, and
# removes MapShell's lifecycle observer — so by the time the drive exits, the
# FGS is already stopped and nothing is listening for the pause. The handoff now
# happens INSIDE the drive, which delivers a genuine AppLifecycleState.paused
# while the tree is still mounted and the foreground MLS session still held.
echo "Phase 4/5 — drive complete; the handoff and publish window ran inside it."

# ---------------------------------------------------------------------------
# Phase 5 — the oracle.
#
# Everything asserted here already happened during the drive, so these are
# reads over a complete capture rather than live polls.
# ---------------------------------------------------------------------------
echo "Phase 5/5 — asserting the FGS publish path..."

# (1) The handoff actually happened. Every later assertion is windowed to it, so
#     without this the window is the whole capture and (3) loses its meaning.
if ! grep -aqF -- "${MARK_PAUSE}" "${LOGCAT_FILE}" 2>/dev/null; then
  fail "the drive never delivered the lifecycle pause (no '${MARK_PAUSE}'). The \
foreground never handed off, so the FGS was gated out of publishing for the whole run \
and this lane proved nothing."
fi
# Dispatched is not the same as took-effect. `_onPaused()` is async and writes
# the handoff flag several awaits in; until it lands, the FGS's gate-3 check
# still sees the foreground as active and returns without publishing.
if ! grep -aqF -- "${MARK_HANDOFF_OK}" "${LOGCAT_FILE}" 2>/dev/null; then
  fail "the lifecycle pause was delivered but the handoff never completed (no \
'${MARK_HANDOFF_OK}'): kForegroundActiveAtMsKey never reached 0, so MapShell._onPaused() \
did not run to completion and the FGS stayed gated out of publishing."
fi
echo "  [1/8] Foreground handoff delivered and confirmed."

# (2) P0-1's oracle — POSITIVE, not an absence check. `Initialized (…
#     locationSharing=true)` is emitted only after CircleManagerFfi.newInstance
#     returned, i.e. after the Rule-14 acquire succeeded against a foreground
#     session that is still held.
if grep -aqF -- "${MARK_ONSTART_FAILED}" "${LOGCAT_FILE}" 2>/dev/null; then
  echo "---- offending logcat ----" >&2
  grep -aF '[BackgroundTask]' "${LOGCAT_FILE}" >&2 || true
  # Deliberately does NOT assert the CAUSE. The marker prints only
  # `${e.runtimeType}` (background_location_task.dart:246) — correctly, per
  # Security Rule 8 — so a SQLCipher key mismatch, a keyring miss, or an OOM
  # reach this line identically to the Rule-14 collision. P0-1 is by far the
  # most likely cause and the reason this lane exists, but naming it as a
  # certainty would make the lane's headline finding unfalsifiable.
  fail "the FGS isolate failed to start ('${MARK_ONSTART_FAILED}') while the foreground \
MLS session was live, so it never opened the database and can publish nothing this \
session. EXPECTED CAUSE: the Rule-14 LiveSessionGuard collision — see \
docs/CI_HARDENING_BACKLOG.md P0-1. Confirm from the runtime type dumped above before \
concluding; an unrelated open failure reaches this same marker."
fi
# Braced group so the negation covers BOTH alternatives: `! A || B` would parse
# as `(!A) || B` and pass whenever B alone held, which is the opposite of the
# intent. Both markers are read from logcat — the FGS isolate logs there, not to
# the drive log.
if ! { grep -aF -- "${MARK_INITIALIZED}" "${LOGCAT_FILE}" 2>/dev/null \
         | grep -aqF -- "${MARK_LOCSHARING_OK}" \
       || grep -aqF -- "${MARK_SESSION_ACQUIRED}" "${LOGCAT_FILE}" 2>/dev/null; }
then
  fail "the FGS isolate never acquired an MLS session. Neither positive proof \
appeared: '${MARK_INITIALIZED}… ${MARK_LOCSHARING_OK}' (acquired at onStart) nor \
'${MARK_SESSION_ACQUIRED}' (acquired after the pause-time handoff). It either never \
booted, or it booted and never took the session — the P0-1 steady state, in which \
_publishCycle returns immediately and silently forever."
fi
echo "  [2/8] FGS initialized with location sharing wired (Rule-14 acquire succeeded)."

# (3) Delivery, windowed to the handoff→hold-complete span and PARSED (never
#     grepped — `Published to 0/1` is P0-1's own signature and contains the
#     marker). The window OPENS at the handoff because a publish emitted while
#     the UI was still foregrounded is a Rule-14 single-writer violation, not a
#     success; it CLOSES at the hold because everything after is teardown, where
#     the service is stopped on purpose.
WINDOW="${LOG_DIR}/post-pause.window.log"
window_between_markers "${LOGCAT_FILE}" "${MARK_HANDOFF_OK}" "${MARK_HOLD_DONE}" \
  > "${WINDOW}"
# Recorded, not asserted: a drive killed mid-hold never prints the close, and
# the window then runs to EOF. That is the safe direction, but it changes what
# the assertions below are reading, so say so when one of them fails.
window_note=""
if ! grep -aqF -- "${MARK_HOLD_DONE}" "${LOGCAT_FILE}" 2>/dev/null; then
  window_note=" NOTE: the drive never printed '${MARK_HOLD_DONE}', so this \
window ran to the end of the capture and includes teardown."
fi
published="$(max_published_count "${WINDOW}")"
if [[ -z "${published}" ]]; then
  if grep -aqF -- "${MARK_CYCLE_FAILED}" "${WINDOW}" 2>/dev/null; then
    fail "the publish cycle threw ('${MARK_CYCLE_FAILED}') and never reported a count."
  fi
  fail "no publish cycle reported after the handoff. The cycle returns early when no \
circle is eligible, nothing is due, or the foreground is still marked active — all \
SILENTLY — and also when the location disclosure has not been accepted, which DOES log \
'Publish BLOCKED'. Check the [BackgroundTask] dump below for that line first; its \
absence narrows the cause to the silent ones (\`_publishCycle\` in \
background_location_task.dart)."
fi
if (( published < 1 )); then
  fail "the FGS ran a publish cycle after the handoff but published to ZERO circles \
(highest count observed: ${published}). The isolate is alive but delivering nothing."
fi
echo "  [3/8] FGS published to ${published} circle(s) after the handoff."

# (4) THE ANTI-VACUITY CHECK. Same OS process ⇒ same Rust `LIVE_SESSIONS`
#     registry ⇒ the Rule-14 contention was real.
#
#     Without this the lane has a live false-green path: if the app process
#     dies and Android restarts the START_STICKY service into a FRESH process,
#     there is no foreground session at all, the acquire trivially succeeds,
#     and (2) and (3) both pass while nothing under test was exercised. The
#     144s foreground-active staleness fallback (2 * kBackgroundRepeatInterval)
#     makes that window wide enough to hit comfortably.
pause_pid="$(pid_of_marker "${LOGCAT_FILE}" "${MARK_PAUSE}")"
publish_pid="$(pid_of_marker "${WINDOW}" "${MARK_PUBLISHED_PREFIX}")"
if [[ -z "${pause_pid}" || -z "${publish_pid}" ]]; then
  fail "could not read the PID column for the handoff (${pause_pid:-none}) and/or the \
publish (${publish_pid:-none}) — cannot prove they shared a process, so the Rule-14 \
contention is unproven. Is logcat still in -v threadtime format?"
fi
if [[ "${pause_pid}" != "${publish_pid}" ]]; then
  fail "the FGS published from PID ${publish_pid} but the foreground that handed off was \
PID ${pause_pid}. DIFFERENT PROCESSES — most likely a START_STICKY restart after the app \
died, which means there was no live foreground MLS session to contend with and this run \
proves NOTHING about P0-1."
fi
if grep -aqF -- "${MARK_ONDESTROY}" "${WINDOW}" 2>/dev/null; then
  fail "the FGS was destroyed during the publish window ('${MARK_ONDESTROY}') — the \
service did not survive the window it was supposed to publish in.${window_note}"
fi
echo "  [4/8] Publish came from PID ${publish_pid}, the same process as the foreground."

# (5)-(7) THE POWER ORACLES. Steps 1-4 prove the FGS publishes; these prove it
#         does so the way P2a says it does — one long-interval platform request
#         instead of a 1 Hz stream plus a per-tick one-shot, a scoped and
#         bounded CPU hold, and a cadence set by the platform's delivery rather
#         than by a poll. Read from `dumpsys`, i.e. from the PLATFORM's copy of
#         the request, so a Haven log line claiming a 100 s registration cannot
#         satisfy them on its own.
oracle_out=""
if ! oracle_out="$(assert_registration_oracle "${LOGCAT_FILE}" "${SAMPLE_FILE}" "${WINDOW}")"; then
  echo "${oracle_out}" >&2
  fail "the FGS's platform location request does not match the P2a contract (above).\
${window_note}"
fi
echo "${oracle_out}"
echo "  [5/8] One Haven location request while backgrounded, never under \
${MIN_FIX_INTERVAL_SECS} s, with the foreground 1 s / 1 m stream released."

if ! oracle_out="$(assert_wake_lock_oracle "${LOGCAT_FILE}" "${SAMPLE_FILE}")"; then
  echo "${oracle_out}" >&2
  fail "the wake locks held while backgrounded do not match the P2a contract (above).\
${window_note}"
fi
echo "${oracle_out}"
echo "  [6/8] Wake locks bounded: the plugin's permanent lock held throughout (P2a keeps \
it), 'Haven:publish' never past its ${WAKE_LOCK_MAX_AGE_SECS} s ceiling."

if ! oracle_out="$(assert_cadence_oracle "${WINDOW}")"; then
  echo "${oracle_out}" >&2
  fail "the background publish cadence does not match the P2a contract (above).\
${window_note}"
fi
echo "${oracle_out}"
echo "  [7/8] Publishes are delivery-driven and spaced at least \
${MIN_DELIVERY_GAP_SECS} s apart from the registration that produced them."

# (8) The no-fix chain, in the SECOND hold: the drip is stopped and the device
#     is in deep idle, so nothing can be delivered and the delivery-driven path
#     this lane just proved has nothing to run on. Publishing must continue
#     anyway, from the watchdog and the last known position.
if ! oracle_out="$(assert_no_fix_chain_oracle "${LOGCAT_FILE}")"; then
  echo "${oracle_out}" >&2
  fail "background publishing did not survive the no-fix chain under deep idle (above)."
fi
echo "${oracle_out}"
echo "  [8/8] Publishing survived deep idle with no fix available: a \
'${MARK_TRIGGER_WATCHDOG}' cycle published from the last known position."

# Evidence only, never asserted: the emulator's GNSS accounting. batterystats on
# a goldfish HAL measures nothing real (there is no receiver), so a threshold
# here would be a number with no referent — the kind of gate this file's Phase 5
# footnote already removed once. The duty cycle it would describe is asserted
# above, structurally, as the interval the platform was ASKED for.
echo "---- emulator GNSS accounting (evidence only) ----"
adb -s "${DEVICE}" shell dumpsys batterystats --checkin 2>/dev/null \
  | grep -a 'gps' | head -20 || echo "(no gps rows in batterystats)"

# NOTE on what is deliberately NOT asserted: there is no relay-side line-count
# check. An earlier revision compared strfry's docker-log line count before and
# after, which was worthless in both directions — it cannot fail (the FGS's own
# relay connect, plus strfry's 9s expired-event cron, guarantee new lines) and it
# adds nothing (`Published to N` is only reached after `publishEvent` returns,
# and `publish_with_retry` returns Ok ONLY when at least one relay OK-acked:
# haven-core/src/relay/manager.rs:119-133 — Security Rule 13's ack/sent
# distinction, honoured). A gate that cannot fail is the repo's documented
# recurring failure mode, so it was removed rather than left as decoration.

if (( drive_failed == 1 )); then
  fail "the oracle passed, but ${drive_reason}. The FGS behaviour above is real \
and was proven, yet the drive itself did not complete cleanly — treat the lane as \
RED until that is fixed, because a drive that dies early can truncate the very \
window the oracle measures."
fi

echo "B1 PASS — the FGS published ${published} location(s) from PID ${publish_pid} with \
the foreground MLS session held by that same process."
