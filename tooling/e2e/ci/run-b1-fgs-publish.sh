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
#   8. ASSERT the no-fix chain: with the platform's `fused` provider replaced by
#      a test provider nothing ever gives a location to, and the device forced
#      into DEEP IDLE, a `trigger=watchdog` cycle still publishes — from the
#      last known position, after the one-shot it cannot answer — within
#      `kLocationPublishMaxInterval + kBackgroundRepeatInterval +
#      kFirstDeliveryWait + kOneShotLocationTimeout` plus slack OF THE PUBLISH
#      BEFORE IT. The premise is read back from `dumpsys location`, and a
#      delivery inside that window fails the step as a LANE defect, by name.
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
# It also MAKES its own premise instead of assuming one. Until run 34642726338
# the step rested on "the `geo fix` drip is stopped, therefore no fix can
# arrive"; the emulator streams the seeded position at 1 Hz for as long as the
# platform runs GNSS, so that was never true, and the step reported the healthy
# delivery-driven publishes it then saw as "background publishing STOPS here".
# See `arm_no_fix` and `assert_no_fix_chain_oracle`.
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
# * Step 3 is windowed at BOTH ends. It opens at the FGS's own
#   `[BackgroundTask] session acquired` line after the pause, because a publish
#   emitted while the UI still held the MLS session is not the thing under test
#   — it is a Rule-14 single-writer violation, and counting it as success would
#   invert the lane's meaning. The FGS's line and not the drive's
#   `HANDOFF_CONFIRMED`, because the drive only OBSERVES the handoff through a
#   poll while the FGS publishes the moment it lands: run 34740325027 published
#   38 ms before the marker and went red on a healthy cadence
#   (`proof_window_opener`; the marker opens the window only when the FGS
#   acquired at `onStart`). It closes at the hold because everything after
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
# The shared fresh-install step: install_fresh and its broadcast barrier.
# shellcheck source=tooling/e2e/ci/app-install-lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/app-install-lib.sh"
# The log-privacy gate — the key-material floor AND the identifier scanner,
# one call, one verdict — over the captures after the drive and over the whole
# evidence directory at exit.
# shellcheck source=tooling/e2e/ci/logscan-gate.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/logscan-gate.sh"

# location_provider_names — the providers `dumpsys location` lists, with their
# `[mock]` state, and nothing else. The dump's `last location=` line is the
# position, which no log may carry (Security Rule 15) — a synthetic landmark
# included, because the scanner declares this lane's point as a needle.
location_provider_names() {
  tr -d '\r' | grep -aoE '^[[:space:]]*[a-z_]+ provider( \[mock\])?' \
    | sed 's/^[[:space:]]*//' | sort -u
}

# withhold_positions — a `dumpsys location` provider block with its
# `last location=` / `last mock location=` values withheld: the block is what
# tells a refused app-op from a renamed provider, the values are a position
# (Security Rule 15).
withhold_positions() {
  sed -E 's/(last( mock)? location=).*/\1<withheld>/'
}

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

# The logcat-stamp-to-seconds converter every timing oracle here shares:
# `ts($1, $2)` over `logcat -v threadtime`'s `MM-DD` and `HH:MM:SS.mmm`. Held in
# one place and interpolated into each awk program rather than copied into it,
# so a correction reaches all of them; each caller seeds `mlen` in its own
# `BEGIN` beside the reasoning for why a month table is enough.
readonly AWK_TS_FN='
    function ts(dm, hms,   md, t, sec, mo, dy, cum, i) {
      # The fraction split off by hand: a POSIX awk reads `16.091` through the
      # locale, and a comma-decimal one makes it 16.
      split(dm, md, "-"); split(hms, t, ":"); split(t[3], sec, ".")
      mo = md[1] + 0; dy = md[2] + 0; cum = 0
      for (i = 1; i < mo; i++) cum += mlen[i]
      return (cum + dy) * 86400 + t[1] * 3600 + t[2] * 60 \
        + sec[1] + sec[2] / 10 ^ length(sec[2])
    }'

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
  # `const Duration kBackgroundRepeatInterval = kLocationPublishMinInterval;` —
  # the ALIAS is the point of that declaration (the two constants are one number
  # by construction, and the Dart doc says so), so following it keeps the bound
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
   || ! PUBLISH_MAX_INTERVAL_SECS="$(dart_duration_secs kLocationPublishMaxInterval)" \
   || ! WATCHDOG_PERIOD_SECS="$(dart_duration_secs kBackgroundRepeatInterval)" \
   || ! FIRST_DELIVERY_WAIT_SECS="$(dart_duration_secs kFirstDeliveryWait)" \
   || ! PLATFORM_MIN_INTERVAL_SECS="$(dart_duration_secs kMinFixRequestInterval)" \
   || ! ONE_SHOT_TIMEOUT_SECS="$(dart_duration_secs kOneShotLocationTimeout)"
then
  echo "run-b1-fgs-publish.sh: could not read the publish-cadence constants from \
${LOCATION_CONSTANTS_SRC}. The declarations moved or changed shape, so every bound \
below would be scanning nothing. Fix the extraction, never the bound." >&2
  exit 2
fi
readonly PUBLISH_MIN_INTERVAL_SECS FIX_LEAD_SECS WAKE_LOCK_MAX_AGE_SECS
readonly PUBLISH_MAX_INTERVAL_SECS WATCHDOG_PERIOD_SECS FIRST_DELIVERY_WAIT_SECS
readonly ONE_SHOT_TIMEOUT_SECS PLATFORM_MIN_INTERVAL_SECS

# The floor on the FGS's registered interval once it has published.
#
# `_ensureRegistration` aims at `earliestDue - kBackgroundFixLeadTime`, measured
# from the instant the burst was planned, and for the circle about to publish
# `earliestDue` is its planned start — never before that instant — plus the
# CSPRNG draw J in [kLocationPublishMinInterval, kLocationPublishMaxInterval].
# So the interval it asks for is at least `J - lead`, 62 s at the shortest draw,
# and a RETRY registration after a failed publish is `kBackgroundRepeatInterval
# - lead` = 62 s exactly; both are pinned to the millisecond by
# background_location_task_delivery_cycle_test.dart. 72 would therefore red a
# CORRECT implementation on every draw below 82 s, about one in ten.
#
# The clause the whole paragraph rests on is "once it has published". A RECOVERY
# registration (`trigger=stream-error`) does not follow a publish: the platform
# killed the live request mid-interval and the isolate re-aims at the SAME
# due-time, so what it asks for is the REMAINDER of an interval that was already
# at least kLocationPublishMinInterval long — legitimately anywhere down to the
# platform floor below. `INV-L-ANDROID-BACKGROUND-SINGLE-GNSS-REQUEST` says this
# in its own words ("interval >= kMinFixRequestInterval; for the circle just
# published >= 62 s"); the oracle below now says it too, attributed per sample,
# instead of asserting the specialisation everywhere and calling a correct
# recovery a regression.
readonly MIN_FIX_INTERVAL_SECS=$((PUBLISH_MIN_INTERVAL_SECS - FIX_LEAD_SECS))

# The floor on the spacing between two delivery-driven publishes: 90 % of the
# registered-interval floor, because the interval is what the platform is ASKED
# for and delivery lands at `>= interval` minus nothing but measurement noise.
# floor(0.9 x 62) = 55; a healthy boundary run lands at ~55.8 s, so 56 would be
# a false-red generator.
#
# The 90 % is the rule and 62 s is the interval it is specialised to. For a
# delivery on a RECOVERY registration the same 90 % applies to the interval THAT
# registration asked for, read off its own `registration armed (Ns)` line — see
# `delivery_gaps_after_registration`, which reports the floor per gap.
readonly MIN_DELIVERY_GAP_SECS=$((MIN_FIX_INTERVAL_SECS * 9 / 10))

# Step 8's bound: how long background publishing may go quiet once the platform
# can no longer answer with a fix.
#
# Measured between two PUBLISHES, not from the instant the no-fix condition was
# armed. What a peer sees is the gap between markers, and it is the gap the
# chain's own links set — an arm that lands just after a publish has a full
# jittered interval ahead of it before the next one is even due, which a bound
# measured from the arm would charge to the chain.
#
# Every term is the length of one link, and every one is read out of the Dart
# source above:
#
#   kLocationPublishMaxInterval the longest a circle can be scheduled after its
#                               last publish (the CSPRNG draw's ceiling),
#   kBackgroundRepeatInterval   the watchdog tick granularity — with nothing
#                               deliverable, a cycle can only start on a tick,
#   kFirstDeliveryWait          the cold-cache wait for a platform answer that
#                               will not come,
#   kOneShotLocationTimeout     the one-shot that cannot succeed, before
#                               `getLastKnownPosition()` finally answers.
#
# The last term is a MARGIN, not a bound: the encrypt, the relay ack and the
# fetch that follow the fix on a loaded emulator. It is the only hand-chosen
# number here, and it is deliberately additive so that no derived term can be
# quietly widened by tuning it.
readonly NO_FIX_SLACK_SECS=30
readonly NO_FIX_BOUND_SECS=$((PUBLISH_MAX_INTERVAL_SECS + WATCHDOG_PERIOD_SECS \
  + FIRST_DELIVERY_WAIT_SECS + ONE_SHOT_TIMEOUT_SECS + NO_FIX_SLACK_SECS))

# The platform provider step 8 silences to create that condition: the one the
# FGS's registration and its one-shot both use. See `arm_no_fix`.
readonly NO_FIX_PROVIDER='fused'

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
# happen. It is also where the proof window opens (`proof_window_opener`).
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
# stops rejecting it, and step 1 requires it. It opens the proof window ONLY
# when the FGS acquired at `onStart` (`proof_window_opener`): the poll observes
# the flag the FGS reads directly, so it can trail the FGS's own first publish.
# Mirrors `kHandoffConfirmedMarker`.
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
# state — and it is what tells THIS script to take the platform's ability to
# answer with a fix away and force the device into deep idle. MUST match
# `kIdlePhaseBeginMarker` / `kIdlePhaseEndMarker` in the drive target VERBATIM.
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
# This script's own device-stamped record of the no-fix condition itself: the
# `dumpsys location` read-back of what that provider IS after the test provider
# was installed (see `arm_no_fix`). `mock` is the only verdict
# that means "no fix can reach the app from here"; every other token names what
# was found instead, and step 8 refuses to read a chain out of a window it did
# not hold for.
readonly MARK_NO_FIX_ARMED="NO_FIX_ARMED ${NO_FIX_PROVIDER}="
readonly MARK_TRIGGER_WATCHDOG='[BackgroundTask] cycle trigger=watchdog'
# The generic cycle-start line, and the two triggers that MEAN a platform
# delivery arrived. Inside the no-fix window either one says the premise did not
# hold — the lane, not the product, is what failed then.
readonly MARK_TRIGGER_ANY='[BackgroundTask] cycle trigger='
readonly MARK_TRIGGER_DELIVERY='[BackgroundTask] cycle trigger=delivery'
readonly MARK_TRIGGER_PENDING='[BackgroundTask] cycle trigger=pending-delivery'
# The RECOVERY trigger: the platform killed the FGS's registration (its provider
# process died, or the provider was removed) and the isolate re-arms
# kStreamErrorRearmDelay later instead of waiting out the watchdog. Like the
# watchdog it is a cycle that exists BECAUSE no delivery can arrive, so it is
# not a publish source and its registration is not a steady-state one — both
# oracles below name it explicitly rather than letting it pass as either.
readonly MARK_TRIGGER_REARM='stream-error'
# The FGS's own record of what it is recovering from: the stream's error handler
# (presence only: the exception TYPE, never its message) and its DONE handler,
# which reports no error at all — a provider removed rather than failed
# completes the stream. Both must be read, or a done-driven recovery looks like
# a cycle nothing asked for.
readonly MARK_FIX_STREAM_ERROR='[BackgroundTask] fix stream error:'
readonly MARK_FIX_STREAM_CLOSED='[BackgroundTask] fix stream closed'
# Play services reaping its own processes. Not a Haven event and not a verdict —
# printed as CONTEXT beside a cadence failure so the next reader does not have
# to re-derive from 30 000 logcat lines why the registration went quiet. CI run
# 35950857266: `TimedProcessReaper: Scheduling killing of process to refresh
# configuration`, then this line for `com.google.android.gms.persistent`, then
# `LocationServiceDisabledException` on Haven's stream 1 s later.
readonly MARK_GMS_PROCESS_DEATH='ActivityManager: Process com.google.android.gms'
# The markers `_publishCycle` prints around the ONLY calls that can reach the
# platform for a fix, emitted only when the stream cache could not serve the
# cycle. The interval between them is what separates a one-shot that was
# ANSWERED (seconds) from one that ran out into `getLastKnownPosition()`
# (kOneShotLocationTimeout or more) — i.e. the no-fix chain actually running.
# MUST match background_location_task.dart VERBATIM; pinned there by
# `background_location_task_delivery_cycle_test.dart`.
readonly MARK_COLD_ASK='[BackgroundTask] cold fix: asking the platform'
readonly MARK_COLD_IN_HAND='[BackgroundTask] cold fix: in hand'
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
# The app renders both fields through `magnitudeBucket` (Security Rule 15: an
# exact count of a user's circles is an identifier), so the vocabulary is
# `0 | 1 | 2-4 | 5+`, never a bare integer above 1. The parser keeps the
# bucket's LEADING number (0, 1, 2, 5): that preserves the only boundary this
# lane asserts, zero versus non-zero, and orders the buckets correctly. A regex
# anchored on `[0-9]+/` would match `2-4/` and `5+/` as NOTHING, and an empty
# parse takes the "no publish cycle reported" branch — a false product
# regression with a misleading cause list.
max_published_count() {
  local logfile="$1"
  { grep -aoE 'Published to [0-9]+(-[0-9]+|\+)?/[0-9]+(-[0-9]+|\+)? due circle' \
      "${logfile}" 2>/dev/null \
      | grep -aoE 'to [0-9]+' | tr -d 'to ' | sort -n | tail -1; } || true
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

# Print what the proof window OPENS at in <capture>, for `window_between_markers`:
# the FIRST `[BackgroundTask] session acquired` LINE after `[b1] PAUSE_DELIVERED`,
# else the `[b1] HANDOFF_CONFIRMED` marker.
#
# The acquire, because the FGS can only take the MLS session once `_onPaused()`
# has released it (Rule 14), so every publish after that line is post-handoff
# BY CONSTRUCTION — and the isolate that publishes is the one that logs it, in
# order. The drive's `HANDOFF_CONFIRMED` is an OBSERVER's poll of the flag the
# FGS reads directly, and the FGS publishes the moment it flips: in run
# 34740325027 the publish landed 38 ms BEFORE the marker (trigger-to-publish
# 0.88 s against the poll's 0.93 s) and step 7 reddened a healthy cadence on
# one publish; in run 34676420734 the same shape landed 674 ms AFTER it and
# passed. Opened at the marker, the window measured the poll.
#
# The marker still opens the window when nothing is acquired after the pause:
# the FGS acquired at `onStart` (`Initialized (… locationSharing=true)`) and
# logs nothing at the handoff, so the poll is the only post-handoff anchor.
#
# The whole LINE rather than the marker: an earlier FGS instance in the same
# capture can have logged `session acquired` before the pause, and
# `window_between_markers` opens at the first substring match. The line's own
# stamp and PID make it unique.
proof_window_opener() {
  local logfile="$1" line
  line="$(awk -v p="${MARK_PAUSE}" -v a="${MARK_SESSION_ACQUIRED}" '
    !paused { if (index($0, p)) paused = 1; next }
    index($0, a) { print; exit }
  ' "${logfile}" 2>/dev/null)" || true
  if [[ -n "${line}" ]]; then
    printf '%s\n' "${line}"
  else
    printf '%s\n' "${MARK_HANDOFF_OK}"
  fi
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

# "<sample>|<trigger of the cycle that ARMED the live registration>" for every
# sample stamp in the capture, or `none` before the first registration.
#
# NOT the same question as `sample_trigger_context`, and the difference is what
# step 5's sub-62 s carve-out has to key on. A registration OUTLIVES the cycle
# that armed it: `registrationIsAligned` keeps an aim that has not moved, so a
# recovery's ~39 s request is still the live one while later `trigger=delivery`
# cycles come and go — and a delivery more than
# `kBackgroundFixHorizon - kBackgroundFixLeadTime` before the aim publishes
# nothing and re-arms nothing. The red capture has exactly that shape at a
# harmless 128 s (`armed (128s)` 04:03:48, an early `trigger=delivery` 04:04:53,
# no re-arm); at 39 s, attributing by proximity would call a CORRECT recovery a
# floor breach on every sample after it.
#
# Same mechanics as `delivery_gaps_after_registration`'s `armed_by`, so the two
# cannot drift: `cur` tracks the announcing cycle, an arm snapshots it, and
# `[BackgroundTask] onStart` resets both because a registration dies with its
# FGS instance.
sample_armed_by() {
  awk -v tag="${SAMPLE_STAMP}" -v m='[BackgroundTask] cycle trigger=' \
      -v am='[BackgroundTask] registration armed (' '
    index($0, "[BackgroundTask] onStart") { cur = ""; armed_by = ""; next }
    {
      i = index($0, m)
      if (i > 0) {
        cur = substr($0, i + length(m))
        sub(/[ \t\r].*$/, "", cur)
        next
      }
    }
    index($0, am) { armed_by = cur; next }
    {
      i = index($0, tag)
      if (i > 0) {
        print (substr($0, i + length(tag)) + 0) "|" \
          (armed_by == "" ? "none" : armed_by)
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
# Paired against the capture, not the window alone. The first delivery in the
# window answers the HANDOFF cycle's registration, and when the window opens at
# `[b1] HANDOFF_CONFIRMED` (the onStart-acquire variant, `proof_window_opener`)
# that registration can precede it — the cycle arms about a second after the
# pause, which beats the drive's 1 s poll: 81 ms before it in run 34511084722,
# 84 ms in 34488512808. Read from the window alone that pair does not exist,
# and run 34511084722 went red on a healthy delivery 99 s after a 98 s
# registration. So <capture>, up to the line the window opened at, supplies the
# registration live when it opened — and every `[BackgroundTask] onStart`
# clears it: a registration dies with its FGS instance, and pairing across one
# would let a publish with no interval of its own pass.
#
# A delivery that did not lead to a publish is not a cadence point, and neither
# is any other trigger (`watchdog`, `paused-signal`, `pending-delivery`,
# `stream-error`) — the whole claim is about the delivery-driven path. A
# delivery-driven publish with NO registration before it in its own FGS instance
# is emitted as `NOARM`: unmeasurable, which the caller FAILS rather than skips.
#
# Each gap is emitted as `<ms>|<the interval that registration asked for, in
# ms>|<the trigger of the cycle that armed it>`. The caller needs all three
# because the constant floor is a property of the STEADY-STATE registration, and
# only one kind of cycle arms a registration that is not one: a recovery
# (`trigger=stream-error`) re-aims at a due-time that has not moved, so it asks
# for the remainder of an interval already spent (see MIN_FIX_INTERVAL_SECS'
# second paragraph). Attributing by the ARMING CYCLE rather than by the interval
# alone is what keeps run 34511084722's finding a finding: there a
# delivery-driven cycle armed 40 s through the overdue-planning defect and the
# platform delivered at 45 s, and a floor taken of the interval the FGS asked
# for would have called that healthy. `ASK` replaces the second field when the
# `(Ns)` suffix cannot be parsed — the caller fails on it, because a floor it
# cannot compute is not a floor it may skip.
#
# Usage: delivery_gaps_after_registration <window> <capture>
delivery_gaps_after_registration() {
  local windowfile="$1" logfile="$2" open
  open="$(proof_window_opener "${logfile}")"
  awk -v open="${open}" "${AWK_TS_FN}"'
    # Seconds out of `registration armed (Ns)` — what the platform was ASKED
    # for, which is the only thing the 90 % floor can honestly be taken of.
    # `-1` when the suffix is not the `(<digits>s)` the Dart line prints.
    function arm_secs(line,   i, rest, j, tok) {
      i = index(line, "registration armed (")
      if (i == 0) return -1
      rest = substr(line, i + 20)
      j = index(rest, "s)")
      if (j == 0) return -1
      tok = substr(rest, 1, j - 1)
      if (tok !~ /^[0-9]+$/) return -1
      return tok + 0
    }
    BEGIN {
      # Day lengths only ever resolve a midnight rollover inside one ~20-minute
      # run, so the year (and the leap day) cannot matter. A run that somehow
      # produced a NEGATIVE gap is reported as one and fails the caller rather
      # than being wrapped into a plausible number.
      split("31 28 31 30 31 30 31 31 30 31 30 31", mlen, " ")
      armed = -1; armed_ask = -1; armed_by = "none"
      pending = -1; pending_arm = -1; pending_ask = -1; pending_by = "none"
      cur = "none"
    }
    # The capture contributes its registrations up to the window, nothing else.
    FILENAME == ARGV[1] && index($0, open) { opened = 1 }
    FILENAME == ARGV[1] && opened { next }
    index($0, "[BackgroundTask] onStart") {
      armed = -1; armed_ask = -1; armed_by = "none"; cur = "none"; next
    }
    # Both files feed this: the cycle that armed a registration is whichever one
    # announced itself last before it, and for the handoff registration that
    # announcement can sit in the capture, above the window.
    index($0, "[BackgroundTask] cycle trigger=") {
      cur = substr($0, index($0, "cycle trigger=") + 14)
      sub(/[ \t\r].*$/, "", cur)
      if (FILENAME != ARGV[1]) {
        if (cur == "delivery") {
          pending = ts($1, $2); pending_arm = armed; pending_ask = armed_ask
          pending_by = armed_by
        } else {
          pending = -1
        }
      }
      next
    }
    index($0, "[BackgroundTask] registration armed (") {
      armed = ts($1, $2); armed_ask = arm_secs($0); armed_by = cur; next
    }
    FILENAME == ARGV[1] { next }
    {
      i = index($0, "Published to ")
      if (i == 0 || pending < 0) next
      n = substr($0, i + 13); sub(/\/.*$/, "", n)
      if (n + 0 < 1) next
      if (pending_arm < 0) print "NOARM"
      else if (pending_ask < 0) printf "%d|ASK|%s\n", \
        int((pending - pending_arm) * 1000 + 0.5), pending_by
      else printf "%d|%d|%s\n", int((pending - pending_arm) * 1000 + 0.5), \
        pending_ask * 1000, pending_by
      pending = -1
    }
  ' "${logfile}" "${windowfile}" 2>/dev/null || true
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
  local -A armed_by_at=()

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

  # Which cycle each sample was taken DURING — the input to the interval-0
  # attribution below, because a one-shot is taken inside the cycle that needs
  # it. Read over the WHOLE capture, because a sample's cycle is whichever one
  # last announced itself before it, regardless of window.
  while IFS='|' read -r ctx_n ctx_trigger; do
    trigger_at[${ctx_n}]="${ctx_trigger}"
  done < <(sample_trigger_context "${logfile}")
  # …and which cycle ARMED the request the sample shows, which is a different
  # question: a registration outlives the cycle that armed it (see
  # `sample_armed_by`). The sub-62 s carve-out keys on THIS one.
  while IFS='|' read -r ctx_n ctx_trigger; do
    armed_by_at[${ctx_n}]="${ctx_trigger}"
  done < <(sample_armed_by "${logfile}")

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
    # The steady-state floor, and the ONE cycle it is not the floor for. A
    # recovery cycle (`trigger=stream-error`) re-aims at a due-time that has not
    # moved, so it asks for the REMAINDER of an interval already at least
    # kLocationPublishMinInterval long — below 62 s by construction, and right
    # to be: asking for 62 s there would publish LATE, and asking for nothing
    # would leave the cadence on the watchdog, which is the wedge the recovery
    # exists to close. What still holds absolutely is the PLATFORM floor, which
    # is not a cadence choice at all.
    #
    # Keyed on the cycle that ARMED the request, never on the one running when
    # the sample was taken: a recovery's request survives every later
    # delivery-driven cycle that finds nothing due and re-arms nothing, and the
    # proximity reading would fail all of those samples on a correct build.
    #
    # Not carved out, and deliberately: a WATCHDOG re-aim on a suspect
    # registration with nothing due asks for the remainder too, and step 5 still
    # fails it. That is pre-existing (it is B6's second-failure path, which the
    # recovery hands back to the watchdog), it has never fired in-window, and it
    # is not this carve-out's to widen — see `docs/E2E_TROUBLESHOOTING.md`
    # failure mode 19.
    if (( ms > 0 && ms < MIN_FIX_INTERVAL_SECS * 1000 )) \
       && [[ "${armed_by_at[${n}]:-none}" != "${MARK_TRIGGER_REARM}" ]]; then
      echo "FAIL: sample ${n} shows a Haven location request at $((ms / 1000)) s, below \
the ${MIN_FIX_INTERVAL_SECS} s floor (kLocationPublishMinInterval ${PUBLISH_MIN_INTERVAL_SECS} s \
- kBackgroundFixLeadTime ${FIX_LEAD_SECS} s), armed by a \
'trigger=${armed_by_at[${n}]:-none}' cycle: '${req}'. The FGS is asking the platform to \
run GNSS faster than the publish cadence can ever use. (Only a '${MARK_TRIGGER_REARM}' \
cycle may arm a request under this floor, and never under \
${PLATFORM_MIN_INTERVAL_SECS} s.)"
      rc=1
    elif (( ms > 0 && ms < PLATFORM_MIN_INTERVAL_SECS * 1000 )); then
      echo "FAIL: sample ${n} shows a Haven location request at $((ms / 1000)) s, below \
the kMinFixRequestInterval ${PLATFORM_MIN_INTERVAL_SECS} s platform floor: '${req}'. \
Nothing licenses that — a recovery re-aim is bounded by the same floor \
(nextFixRequestInterval applies it last, so it wins over every other anchor)."
      rc=1
    fi
    if (( ms >= MIN_FIX_INTERVAL_SECS * 1000 )); then
      long_seen=1
    fi
    # An interval of exactly 0 is the ONE-SHOT (`getCurrentLocation()`, whose
    # request carries no interval at all), not a stream. P2a keeps it as the
    # cache-miss fallback of the two cycles that run BECAUSE no delivery can
    # arrive — the watchdog, and the recovery after the platform killed the
    # registration — so on those it is deliberately not counted as a concurrent
    # registration. On every other cycle it is exactly the request P2a retired
    # (a 30 s HIGH_ACCURACY one-shot per tick), which prints identically: an
    # unattributed carve-out would let the whole runtime half of this phase's
    # saving regress with the lane still green.
    if (( ms == 0 )) \
       && [[ "${trigger_at[${n}]:-none}" != "watchdog" \
             && "${trigger_at[${n}]:-none}" != "${MARK_TRIGGER_REARM}" ]]; then
      echo "FAIL: sample ${n} shows an interval-0 one-shot ('${req}') while the most \
recent background cycle was 'trigger=${trigger_at[${n}]:-none}'. P2a keeps \
getCurrentLocation() ONLY as the cache-miss fallback of a cycle no delivery could have \
started (watchdog, ${MARK_TRIGGER_REARM}); a one-shot on a delivery-driven cycle is the \
per-tick 30 s HIGH_ACCURACY request this phase retired, running again beside the long \
registration."
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

# CONTEXT for a cadence failure, never a verdict: the Play-services processes
# the system reaped inside the proof window, and Haven's own stream errors.
#
# Haven's registration lives in the process that serves the `fused` provider.
# When Play services reaps it — which it does on its own schedule, to reload a
# configuration — the stream reports `LocationServiceDisabledException` and the
# registration is dead until something re-arms it. In CI run 35950857266 that
# happened 17 s into a 62 s interval and cost the whole window its
# delivery-driven cadence; in the run before it (35690725254) the same reap
# landed 1.115 s BEFORE the first registration, which therefore bound to the new
# instance, and the lane was green. Same product, opposite verdicts, and nothing
# in the failure text said the provider had died — every reader had to re-derive
# it from ~26 000 lines.
#
# Emitted with an explicit "CONTEXT" prefix and NO exit-code effect: the product
# now recovers from this by itself (kStreamErrorRearmDelay), so a reap is no
# longer an excuse for a red cadence — it is only the first thing to look at.
gms_process_death_context() {
  local windowfile="$1" lines
  # ONE pass, so "in capture order" is what the reader gets: a death and the
  # Haven line it caused are seconds apart and belong beside each other. A
  # death needs BOTH tokens — `ActivityManager: Process com.google.android.gms…`
  # also prefixes the restart lines, which are not the event.
  lines="$(awk -v d="${MARK_GMS_PROCESS_DEATH}" -v dd='has died' \
               -v e="${MARK_FIX_STREAM_ERROR}" -v c="${MARK_FIX_STREAM_CLOSED}" '
    (index($0, d) && index($0, dd)) || index($0, e) || index($0, c) { print }
  ' "${windowfile}" 2>/dev/null || true)"
  if [[ -z "${lines}" ]]; then
    echo "  CONTEXT: no Play-services process died and Haven's fix stream neither \
errored nor closed inside the proof window, so the provider was up throughout and the \
cadence failure above is not a provider-death story."
    return 0
  fi
  echo "  CONTEXT (not a verdict): the platform's location provider was disturbed \
inside the proof window. Verbatim, in capture order:"
  local line
  while IFS= read -r line; do
    printf '    %s\n' "${line}"
  done <<< "${lines}"
  echo "  A reaped Play-services process takes Haven's registration with it. The FGS \
re-arms itself kStreamErrorRearmDelay after the stream errors OR closes (one recovery \
per registration that has not delivered), so if no \
'${MARK_TRIGGER_ANY}${MARK_TRIGGER_REARM}' cycle follows a line above, that recovery is \
what to look at first."
}

# Milliseconds between consecutive recovery cycles inside the proof window, one
# line per pair.
#
# The product bounds itself to ONE recovery per registration that has not
# delivered, and that bound is host-tested only — nothing on the device side
# would notice a 5 s re-arm loop at the platform floor, which would still leave
# a delivery-driven publish in the window and pass every other clause here while
# running GNSS far harder than the cadence needs.
#
# The floor is DERIVED, not chosen: a second recovery may only follow a new
# delivery (that is what restores the allowance), and a delivery cannot precede
# the interval the previous recovery asked for, which is never under
# `kMinFixRequestInterval`. So two recoveries closer together than that are one
# of the two failures the bound exists to catch — a loop, or an allowance that
# is not being spent.
recovery_gaps() {
  awk -v m="${MARK_TRIGGER_ANY}${MARK_TRIGGER_REARM}" "${AWK_TS_FN}"'
    BEGIN {
      # One ~20-minute window, so only a midnight rollover can matter and the
      # year (with its leap day) cannot.
      split("31 28 31 30 31 30 31 31 30 31 30 31", mlen, " ")
      prev = -1
    }
    index($0, m) {
      now = ts($1, $2)
      if (prev >= 0) printf "%d\n", int((now - prev) * 1000 + 0.5)
      prev = now
    }
  ' "$1" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Oracle step 7 — the cadence is delivery-driven, and spaced.
# ---------------------------------------------------------------------------
assert_cadence_oracle() {
  local windowfile="$1" logfile="$2" rc=0 publishes gap ask by measured=0 floor
  publishes="$(successful_publish_count "${windowfile}")"
  if (( publishes < 2 )); then
    echo "FAIL: only ${publishes} successful publish(es) in the proof window. The hold \
covers a full kLocationPublishMaxInterval past the handoff cycle, so the delivery-driven \
publish that follows it is not optional — one publish means the platform delivered once \
and never again."
    rc=1
  fi
  while IFS='|' read -r gap ask by; do
    [[ -n "${gap}" ]] || continue
    measured=$((measured + 1))
    if [[ "${gap}" == "NOARM" ]]; then
      echo "FAIL: a delivery-driven publish in the window had no \
'${MARK_REG_ARMED}' line before it in its own FGS instance, so the interval that was \
supposed to space it cannot be read from this capture at all."
      rc=1
      continue
    fi
    # The steady-state floor, unless a RECOVERY cycle armed the registration —
    # then it is 90 % of what that registration actually asked for, which is the
    # same rule (a delivery must not beat its own interval) applied to the one
    # registration the constant cannot describe. Attributed by the arming cycle,
    # never by the interval: run 34511084722's 40 s registration came from a
    # delivery-driven cycle and its 45 s delivery must stay a failure.
    floor=$(( MIN_DELIVERY_GAP_SECS * 1000 ))
    if [[ "${by}" == "${MARK_TRIGGER_REARM}" ]]; then
      if [[ "${ask}" == "ASK" ]]; then
        echo "FAIL: a recovery '${MARK_REG_ARMED}' line in the window carries no \
readable '(<seconds>s)' suffix, so the interval its delivery must clear cannot be \
computed. The marker's grammar changed; fix the parser and its fixtures, never the \
floor."
        rc=1
        continue
      fi
      floor=$(( ask * 9 / 10 ))
    fi
    if (( gap < 0 )); then
      echo "FAIL: a delivery landed ${gap} ms after the registration that asked for it \
— the device clock moved backwards inside the window, so no spacing can be read from \
this capture."
      rc=1
    elif (( gap < floor )); then
      echo "FAIL: a delivery landed only $((gap / 1000)) s after a '${by}' cycle's \
registration, under the $((floor / 1000)) s floor. In the steady state that floor is \
${MIN_DELIVERY_GAP_SECS} s (90 % of ${MIN_FIX_INTERVAL_SECS} s); on a \
'${MARK_TRIGGER_REARM}' registration it is 90 % of the interval that registration asked \
for. The FGS is being woken by something other than its own registered interval."
      rc=1
    fi
  done < <(delivery_gaps_after_registration "${windowfile}" "${logfile}")
  # The recovery's own bound, on the device rather than only on the host.
  local rgap
  while read -r rgap; do
    [[ -n "${rgap}" ]] || continue
    if (( rgap < PLATFORM_MIN_INTERVAL_SECS * 1000 )); then
      echo "FAIL: two '${MARK_TRIGGER_ANY}${MARK_TRIGGER_REARM}' cycles \
$((rgap / 1000)) s apart, under the ${PLATFORM_MIN_INTERVAL_SECS} s \
(kMinFixRequestInterval) floor. A second recovery may only follow a NEW delivery — that \
is what restores the one-per-registration allowance — and a delivery cannot arrive \
sooner than the interval the previous recovery asked for. So this is either a re-arm \
loop against a provider that cannot answer, or an allowance that is not being spent."
      rc=1
    fi
  done < <(recovery_gaps "${windowfile}")

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
  (( rc == 0 )) || gms_process_death_context "${windowfile}"
  (( rc == 0 )) && echo "  cadence: ${publishes} publish(es), ${measured} \
delivery-driven, each at least ${MIN_DELIVERY_GAP_SECS} s after the registration that \
produced it."
  return "${rc}"
}

# ---------------------------------------------------------------------------
# The no-fix condition (step 8's premise), and the read-back that proves it.
#
# Haven's background registration AND its one-shot both go to the platform's
# `fused` provider — `geolocator`'s `LocationManagerClient` picks
# `LocationManager.FUSED_PROVIDER` on API 31+ whenever it is enabled, and the
# FGS asks for it with `forceLocationManager: true`. Replacing THAT provider
# with a test provider nothing ever gives a location to is what makes "no fix
# can arrive" true at the platform, rather than hoping the emulator stops
# producing fixes (it does not — see the oracle below).
#
# Every link the chain has to walk stays real. From AOSP 14 source:
#
#   * `LocationManagerService.addTestProvider` -> `LocationProviderManager
#     .setMockProvider` -> `MockableLocationProvider.setProviderLocked`, which
#     hands the GMS proxy `ProviderRequest.EMPTY_REQUEST` and stops it.
#     `MockLocationProvider.onSetRequest` is EMPTY and the mock reports a
#     location only from `setProviderLocation`, which this lane never calls —
#     so the FGS's registration and its one-shot both go unanswered.
#   * The mock arrives `allowed=false` (`AbstractLocationProvider.State
#     .EMPTY_STATE`), so the provider is briefly DISABLED before
#     `set-test-provider-enabled` re-enables it. That is not noise: the disable
#     clears the provider's last locations (`LocationProviderManager
#     .onEnabledChanged`), so no historical re-delivery can answer the next
#     registration either, and it reaches the app as a provider-disabled error,
#     on which `GeolocatorLocationService` drops its cached fix. The cycle
#     therefore reaches the platform from a COLD cache — the state step 8 is
#     about.
#   * `getLastKnownPosition()` is not a LocationManager read (geolocator routes
#     it through Play services unless forced), so the chain's last link is the
#     one thing the mock does not touch.
#
# `addTestProvider` returns SILENTLY when the caller's `OP_MOCK_LOCATION` app-op
# is not allowed (`LocationManagerService.addTestProvider`: `if (!noteOp(...))
# return;`), and `cmd location` exits 0 either way — which is exactly why this
# ends in a read-back the oracle keys on rather than in an exit code.

# Reads `dumpsys location` on stdin; prints ONE token for the ${NO_FIX_PROVIDER}
# provider.
#
# `mock` — and only `mock` — means no fix can reach the app through it.
#
# The grammar is `LocationProviderManager.dump` (AOSP 14): the header
# `<name> provider`, plus ` [mock]` when `mProvider.isMock()`, plus `:`; then,
# indented under it, `last location=`, `enabled=`, the `MockableLocationProvider`
# state (`allowed=`, `identity=`, `properties=`) and finally the provider's own
# dump — for a test provider `MockLocationProvider.dump`'s
# `last mock location=<location>`, which reads `null` until something injects
# one. The block ends at the first line indented no deeper than the header.
no_fix_verdict() {
  awk -v prov="${NO_FIX_PROVIDER}" '
    $0 ~ ("^[ ]*" prov " provider( \\[mock\\])?:[ ]*$") {
      seen = 1
      mock = (index($0, "[mock]") > 0)
      indent = match($0, /[^ ]/) - 1
      inblock = 1
      next
    }
    inblock {
      if ($0 ~ /^[ ]*$/) next
      if (match($0, /[^ ]/) - 1 <= indent) { inblock = 0; next }
      if ($0 ~ /^[ ]*enabled=true[ ]*$/) enabled = 1
      if ($0 ~ /^[ ]*last mock location=/) {
        if ($0 ~ /^[ ]*last mock location=null[ ]*$/) silent = 1; else reported = 1
      }
    }
    END {
      if (!seen) { print "no-fused-provider"; exit }
      if (!mock) { print "not-mocked"; exit }
      if (reported) { print "mock-reported-a-location"; exit }
      if (!silent) { print "mock-unreadable"; exit }
      if (!enabled) { print "mock-disabled"; exit }
      print "mock"
    }
  '
}

# Installs the silent test provider and prints `no_fix_verdict`'s answer.
#
# Anything other than `mock` also dumps what the device said and the fused block
# it said it about, because that — not the exit codes, which are 0 throughout —
# is the only way to tell a refused app-op from a renamed provider from a dump
# grammar that moved.
arm_no_fix() {
  local uid said dump verdict
  uid="$(adb -s "${DEVICE}" shell id -u 2>/dev/null | tr -dc '0-9')" || true
  if [[ -z "${uid}" ]]; then
    echo "shell-uid-unreadable"
    return 0
  fi
  said="$(adb -s "${DEVICE}" shell \
    "appops set ${uid} android:mock_location allow; \
     cmd location providers add-test-provider ${NO_FIX_PROVIDER}; \
     cmd location providers set-test-provider-enabled ${NO_FIX_PROVIDER} true" \
    2>&1)" || true
  dump="$(adb -s "${DEVICE}" shell dumpsys location 2>/dev/null | tr -d '\r')" \
    || true
  verdict="$(printf '%s\n' "${dump}" | no_fix_verdict)"
  if [[ "${verdict}" != "mock" ]]; then
    {
      echo "---- arming the no-fix condition said ----"
      printf '%s\n' "${said}"
      echo "---- dumpsys location, the ${NO_FIX_PROVIDER} provider block ----"
      printf '%s\n' "${dump}" \
        | grep -aA 12 -E "^[[:space:]]*${NO_FIX_PROVIDER} provider( \[mock\])?:" \
        | withhold_positions \
        || echo "(no ${NO_FIX_PROVIDER} provider block in the dump)"
    } >&2
  fi
  echo "${verdict}"
}

# ---------------------------------------------------------------------------
# Oracle step 8 — the no-fix chain under deep idle.
#
# The PREMISE first, because this step spent a round asserting a conclusion it
# had never established. `adb emu geo fix` does not stop feeding the guest when
# the re-issue loop stops: the emulator streams the last seeded position to the
# guest's GNSS HAL as NMEA once a second for as long as the platform runs GNSS.
# Run 34642726338's capture shows both halves of that — the HAL's
# `Gnss:onGnssLocationCb` once a second in every GNSS session minutes after the
# drip was killed, and three `trigger=delivery` cycles publishing inside the
# forced-idle window — under the verdict "background publishing STOPS here".
# It had not stopped; the window simply never tested anything.
#
# So the premise is now MADE, at the platform, by replacing the `fused` provider
# with a test provider nothing ever gives a location to (`arm_no_fix`), and
# CHECKED, from that function's `dumpsys location` read-back.
#
# With it held, the claim is the one this step has always meant to make: with
# the platform unable to answer, publishing carries on anyway — the watchdog
# notices (a circle falls due, or the registration goes silent), runs a cycle,
# finds no fresh stream fix, spends `kOneShotLocationTimeout` on a one-shot that
# cannot be answered, falls back to `getLastKnownPosition()` and publishes —
# with Doze's POLICY applied to the app throughout.
#
# Five things keep that from being decoration:
#
#   * `mock` from the arm read-back. `addTestProvider` returns SILENTLY when the
#     caller's `MOCK_LOCATION` app-op is not allowed, so without the read-back a
#     lane that armed nothing would report live fixes as a Doze result.
#   * `state=IDLE` from `dumpsys deviceidle get deep`, the authoritative read:
#     `force-idle` answers a device whose deep idle is disabled with a message
#     and exit code 0.
#   * NO delivery-driven cycle after the arm. One means fixes were still
#     arriving — a LANE defect, and the point at which nothing about the product
#     may be concluded from this window in either direction.
#   * The publish must belong to a `trigger=watchdog` cycle that went COLD
#     (`MARK_COLD_ASK`) and whose fix took at least `kOneShotLocationTimeout` to
#     arrive. A cycle served from the stream cache proves the cache, not the
#     chain; a one-shot answered in seconds proves a fix was available, i.e.
#     that the premise slipped.
#   * The bound is measured between publishes — see NO_FIX_BOUND_SECS.
#
# It does NOT prove the AP-suspend half; see this file's header.
# ---------------------------------------------------------------------------
assert_no_fix_chain_oracle() {
  local logfile="$1" verdict seen
  local armed state leak pubs wds asks hands fast gap wait covered
  verdict="$(awk -v armm="${MARK_NO_FIX_ARMED}" -v forced="${MARK_IDLE_FORCED}" \
                 -v endm="${MARK_IDLE_END}" -v wdm="${MARK_TRIGGER_WATCHDOG}" \
                 -v trigm="${MARK_TRIGGER_ANY}" -v delm="${MARK_TRIGGER_DELIVERY}" \
                 -v penm="${MARK_TRIGGER_PENDING}" -v askm="${MARK_COLD_ASK}" \
                 -v handm="${MARK_COLD_IN_HAND}" -v pubm="${MARK_PUBLISHED_PREFIX}" \
                 -v oneshot="${ONE_SHOT_TIMEOUT_SECS}" "${AWK_TS_FN}"'
    function tok(i, m,   v) {
      v = substr($0, i + length(m)); sub(/[ \t\r].*$/, "", v); return v
    }
    BEGIN {
      split("31 28 31 30 31 30 31 31 30 31 30 31", mlen, " ")
      armed = "ABSENT"; state = "ABSENT"; leak = "-"; fast = "-"
      gap = "none"; wait = "none"
      t_arm = -1; t_idle = -1; t_end = -1
      prev_pub = -1; ask = -1; hand = -1; cur = "none"
    }
    {
      t = ts($1, $2)
      if (t_arm < 0 && (i = index($0, armm)) > 0) {
        t_arm = t; armed = tok(i, armm); next
      }
      if (t_idle < 0 && (i = index($0, forced)) > 0) {
        t_idle = t; state = tok(i, forced); next
      }
      if (index($0, endm) > 0) { t_end = t; exit }
      # Publishes are read from the WHOLE capture: the silence the chain has to
      # end starts at the publish before it, which is normally the last
      # delivery-driven one of the P2a window.
      if ((i = index($0, pubm)) > 0) {
        n = substr($0, i + length(pubm)); sub(/[^0-9].*$/, "", n)
        if (n + 0 < 1) next
        if (t_arm >= 0) {
          pubs++
          if (!found && cur == "watchdog" && wd_idle && ask >= 0 && hand >= 0) {
            found = 1
            gap = (prev_pub >= 0) ? sprintf("%d", t - prev_pub) : "noprev"
            wait = sprintf("%d", hand - ask)
          }
        }
        prev_pub = t
        next
      }
      if (t_arm < 0) next
      if ((i = index($0, trigm)) > 0) {
        ask = -1; hand = -1
        if (index($0, wdm) > 0) {
          cur = "watchdog"; wds++; wd_idle = (t_idle >= 0 && t >= t_idle)
        } else {
          cur = "other"
          if (leak == "-" && (index($0, delm) > 0 || index($0, penm) > 0)) {
            leak = $1 " " $2
          }
        }
        next
      }
      if (index($0, askm) > 0) { ask = t; asks++; next }
      if (index($0, handm) > 0 && ask >= 0) {
        hand = t; hands++
        if (fast == "-" && (t - ask) < oneshot + 0) fast = sprintf("%d", t - ask)
        next
      }
    }
    END {
      # How much of the silence the WINDOW itself covered: from the publish the
      # gap would be measured against to the moment the drive closed the hold.
      # Shorter than the bound means the hold ended before the chain was due,
      # which is a fact about the capture and not about the product.
      covered = (t_end >= 0 && prev_pub >= 0) \
        ? sprintf("%d", t_end - prev_pub) : "-"
      printf "%s|%s|%s|%d|%d|%d|%d|%s|%s|%s|%s\n", armed, state, leak, pubs + 0, \
        wds + 0, asks + 0, hands + 0, fast, gap, wait, covered
    }
  ' "${logfile}" 2>/dev/null)"
  if [[ -z "${verdict}" ]]; then
    echo "FAIL: the oracle's parser produced nothing over '${logfile}' — the capture is \
missing or unreadable, so this step has nothing to read."
    return 1
  fi
  IFS='|' read -r armed state leak pubs wds asks hands fast gap wait covered \
    <<<"${verdict}" || true

  if [[ "${armed}" == "ABSENT" ]]; then
    echo "FAIL: the no-fix condition was never armed — no '${MARK_NO_FIX_ARMED}' stamp in \
the capture. Either the drive never printed '${MARK_IDLE_BEGIN}' or this script's idle \
watcher died before it could arm, so the chain was never exercised and nothing about it — \
in either direction — can be read from this run."
    return 1
  fi
  if [[ "${armed}" != "mock" ]]; then
    echo "FAIL: the no-fix condition was NOT established: with the test provider installed, \
'dumpsys location' read the platform's ${NO_FIX_PROVIDER} provider back as '${armed}'. A fix could still \
reach the app, so this window tested nothing — in particular it does NOT say that \
publishing stopped. The arming output and the fused block are in the step log above; \
suspect the MOCK_LOCATION app-op, the provider name, or an image whose dump grammar moved."
    return 1
  fi
  if [[ "${state}" == "ABSENT" ]]; then
    echo "FAIL: the forced-idle phase never started — no '${MARK_IDLE_FORCED}' stamp in the \
capture, so the device was never put into deep idle and the Doze half of this step ran on \
nothing."
    return 1
  fi
  if [[ "${state}" != "IDLE" ]]; then
    echo "FAIL: the device did not enter deep idle ('dumpsys deviceidle get deep' read \
back '${state}'). Anything that publishes after this is the ordinary watchdog on an awake \
device, which steps 1-7 already cover; none of it would be a Doze result."
    return 1
  fi
  if [[ "${leak}" != "-" ]]; then
    echo "FAIL: the no-fix premise did not hold — a platform DELIVERY reached the FGS at \
${leak}, after the ${NO_FIX_PROVIDER} provider had been replaced by a test provider that is \
never given a location. Fixes were still arriving, so this window never ran the no-fix chain, and it is \
NOT evidence that publishing stopped: ${pubs} publish(es) landed in it. Suspect the arming \
(app-op, provider name, dump grammar), not the product."
    return 1
  fi
  if [[ "${fast}" != "-" ]]; then
    echo "FAIL: the no-fix premise did not hold — a cycle that found no fresh stream fix \
had one in hand ${fast} s later, inside the ${ONE_SHOT_TIMEOUT_SECS} s one-shot timeout. A \
fix that arrives that quickly is the platform answering, not \`getLastKnownPosition()\` \
after the one-shot ran out, so something was still feeding the app."
    return 1
  fi
  if [[ "${gap}" == "none" ]]; then
    seen="Seen after the arm: ${wds} watchdog cycle(s), ${asks} cold acquisition(s), \
${hands} of which produced a fix, ${pubs} publish(es)."
    if (( pubs == 0 )); then
      echo "FAIL: nothing published at all once the platform could no longer answer. \
${seen} The chain (watchdog -> one-shot timeout -> getLastKnownPosition) is then the only \
thing that can publish, so background sharing STOPPED here — which indoors, on a real \
phone, is a user who believes they are sharing and is not."
    else
      echo "FAIL: publishing continued (${pubs} publish(es)) but nothing published THROUGH \
the no-fix chain: no watchdog cycle missed the stream cache, ran its one-shot out and \
published from the last known position. ${seen} Publishing did not stop; what is unproven \
is the chain that has to carry it once the cached fix ages out."
    fi
    # BEFORE either reading is acted on: was the window even long enough? The
    # bound is measured between publishes, so the drive's hold has to outlast
    # the last publish by it. If it did not, this capture cannot say publishing
    # stopped — the chain was not yet due when the hold closed — and saying so
    # is how round 3's verdict went wrong in the first place.
    if [[ "${covered}" != "-" ]] && (( covered < NO_FIX_BOUND_SECS )); then
      echo "  NOT A PRODUCT FINDING: the hold closed ${covered} s after the publish \
before it, inside the ${NO_FIX_BOUND_SECS} s the chain's own links are allowed, so the \
chain was not yet due. Lengthen the drive's forced-idle hold \
(\`_forcedIdleHoldDuration\`) — do not read anything about the product out of this."
    fi
    if (( asks > hands )); then
      echo "  $((asks - hands)) cold acquisition(s) never produced a fix at all: the \
one-shot ran out and getLastKnownPosition() came back empty, which is the chain's last link \
failing. Play services is NOT in this path: the read is forced onto the platform \
LocationManager (\`forceAndroidLocationManager: true\`), so it polls EVERY enabled \
provider's last-known, not only the ${NO_FIX_PROVIDER} one this step silenced. An empty \
answer therefore means no enabled provider held any last-known at all — the honest no-data \
state, in which publishing nothing is correct and this step cannot prove the chain. Check \
that the GPS drip seeded \`gps\` before ${MARK_IDLE_BEGIN}; if it did and the read is \
still empty, that is a product finding."
    fi
    return 1
  fi
  if [[ "${gap}" == "noprev" ]]; then
    echo "FAIL: the chain published, but no earlier publish appears in the capture, so the \
silence it ended cannot be measured. Step 3 requires one inside the P2a window, so this is a \
truncated capture rather than a product finding."
    return 1
  fi
  if (( gap < 0 )); then
    echo "FAIL: the chain's publish is stamped ${gap} s BEFORE the publish that precedes it \
— the device clock moved backwards, so nothing can be read from this capture."
    return 1
  fi
  if (( gap > NO_FIX_BOUND_SECS )); then
    echo "FAIL: the no-fix chain published ${gap} s after the publish before it, past the \
${NO_FIX_BOUND_SECS} s bound (kLocationPublishMaxInterval ${PUBLISH_MAX_INTERVAL_SECS} s + \
kBackgroundRepeatInterval ${WATCHDOG_PERIOD_SECS} s + kFirstDeliveryWait \
${FIRST_DELIVERY_WAIT_SECS} s + kOneShotLocationTimeout ${ONE_SHOT_TIMEOUT_SECS} s + \
${NO_FIX_SLACK_SECS} s slack). Publishing recovered, but slower than the chain's own links \
account for."
    return 1
  fi
  echo "  no-fix chain: the ${NO_FIX_PROVIDER} provider was silenced and deep idle engaged; \
a ${MARK_TRIGGER_WATCHDOG} cycle found no fresh fix, waited ${wait} s on a one-shot that \
could not be answered, and published ${gap} s after the publish before it (bound \
${NO_FIX_BOUND_SECS} s)."
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
# A RECOVERY re-aim: the platform killed the registration 22 s into a 62 s
# interval and the FGS re-asks for the remainder. Below the 62 s steady-state
# floor by construction and correct there — and a violation on any other cycle.
readonly FIX_REQ_40S='  10123/com.oblivioustech.haven/B2C3D4E5 Request[gps @+40s0ms HIGH_ACCURACY]'
# Below kMinFixRequestInterval. `nextFixRequestInterval` applies that floor LAST,
# so no cycle — recovery included — can ask for this.
readonly FIX_REQ_30S='  10123/com.oblivioustech.haven/B2C3D4E5 Request[gps @+30s0ms HIGH_ACCURACY]'
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
# request block> [<request block from sample 4 on>]. Samples 1-2 are the
# foreground phase, 3-5 the steady state. An empty request argument writes a
# sample with wake locks and no request, which is how the anti-vacuity fixture
# is built.
#
# The optional fourth block exists for the registration shapes that only appear
# PART WAY through a window — a recovery re-aim, which replaces the steady-state
# request rather than joining it. Without it such a fixture would hold no
# long-interval request anywhere and fail the "the registration reached
# LocationManager" anti-vacuity read for that reason instead of the one under
# test.
build_fixture_samples() {
  local out="$1" pre="$2" steady="$3" late="${4:-}" i block
  {
    for i in 1 2; do
      printf '=== SAMPLE n=%s device-clock=08-02 04:40:%02d.000 ===\n' "${i}" "$(( (i - 1) * 5 ))"
      if [[ -n "${pre}" ]]; then printf '%s\n' "${pre}"; fi
      printf '%s\n' "${FIX_LOCK_PLUGIN}"
    done
    for i in 3 4 5; do
      printf '=== SAMPLE n=%s device-clock=08-02 04:4%s:00.000 ===\n' "${i}" "${i}"
      block="${steady}"
      if [[ -n "${late}" ]] && (( i >= 4 )); then block="${late}"; fi
      if [[ -n "${block}" ]]; then printf '%s\n' "${block}"; fi
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
# second after the first delivery. It arms AFTER `[b1] HANDOFF_CONFIRMED` here,
# the order a slow handoff produces; both real runs so far armed before it, and
# the run-34511084722 fixtures pin that order in the device's own lines.
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

# One publish line, at <hh:mm:ss>.
_fixture_publish() {
  printf '08-02 %s.000  1111  1140 I flutter : [BackgroundTask] Published to 1/1 due circle(s) (1 eligible), fetched 1/1 circle(s).\n' \
    "$1"
}

# Write a step-8 capture: <out> <no-fix read-back> <deep-idle read-back> <cycle>.
#
# The capture always opens with a publish at 04:43:20 — the last delivery-driven
# one of the P2a window, which is the publish the no-fix gap is measured from.
# <cycle> is `none`, or `<kind>:<hh:mm:ss of its publish>`:
#
#   chain     the shape the chain really logs: the watchdog trigger, the cold
#             marker two seconds later (kFirstDeliveryWait), the fix in hand
#             kOneShotLocationTimeout after that, then the publish;
#   fast      the same, but the fix arrives 5 s after the ask — a one-shot that
#             was ANSWERED, i.e. a fix was available after all;
#   warm      a watchdog cycle that published straight from the stream cache,
#             with no platform read at all;
#   empty     a cold cycle whose read never produced a fix, and so never
#             published (the publish argument is ignored);
#   delivery  a delivery-driven cycle, which inside this window means the
#             premise did not hold.
#
# The preamble every step-8 capture shares — the publish the no-fix gap is
# measured from, the drive's two markers and the two device-stamped read-backs
# ('none' omits one) — and the COLD cycle shape, both in ONE copy: the fixtures
# below are hand-built around the same stamps, and a stamp that drifted between
# a builder and a hand-built case is a difference nothing would report.
_fixture_idle_preamble() {
  local armed="$1" state="$2"
  _fixture_publish '04:43:20'
  printf '08-02 04:43:30.000  1111  1130 I flutter : %s\n' "${MARK_HOLD_DONE}"
  printf '08-02 04:43:31.000  1111  1130 I flutter : %s\n' "${MARK_IDLE_BEGIN}"
  if [[ "${armed}" != "none" ]]; then
    printf '08-02 04:43:33.000  1500  1500 I %-8s: %s%s\n' \
      "${SAMPLE_TAG}" "${MARK_NO_FIX_ARMED}" "${armed}"
  fi
  if [[ "${state}" != "none" ]]; then
    printf '08-02 04:43:34.000  1500  1500 I %-8s: %s%s\n' \
      "${SAMPLE_TAG}" "${MARK_IDLE_FORCED}" "${state}"
  fi
}

# One COLD cycle: <trigger line> <publish hh:mm:ss> <seconds the read took>.
# The fix lands a second before the publish and the trigger sits a whole
# kFirstDeliveryWait ahead of the ask, so the read is the only length under
# test. Emits NO publish line — the caller decides whether one follows, and
# what it says.
_fixture_cold_cycle() {
  local trigline="$1" pub="$2" read_secs="$3" hand trig
  hand="$(_fixture_bump "${pub}" -1)"
  trig="$(_fixture_bump "${hand}" $(( -read_secs - FIRST_DELIVERY_WAIT_SECS )))"
  printf '08-02 %s.000  1111  1140 I flutter : %s\n' "${trig}" "${trigline}"
  printf '08-02 %s.000  1111  1140 I flutter : %s\n' \
    "$(_fixture_bump "${trig}" "${FIRST_DELIVERY_WAIT_SECS}")" "${MARK_COLD_ASK}"
  printf '08-02 %s.000  1111  1140 I flutter : %s\n' "${hand}" "${MARK_COLD_IN_HAND}"
}

build_fixture_idle_logcat() {
  local out="$1" armed="$2" state="$3" cycle="$4"
  local kind="${cycle%%:*}" pub="${cycle#*:}"
  {
    _fixture_idle_preamble "${armed}" "${state}"
    case "${kind}" in
      chain|fast|empty)
        if [[ "${kind}" == "empty" ]]; then
          printf '08-02 04:45:00.000  1111  1140 I flutter : %s\n' \
            "${MARK_TRIGGER_WATCHDOG}"
          printf '08-02 04:45:02.000  1111  1140 I flutter : %s\n' "${MARK_COLD_ASK}"
        else
          if [[ "${kind}" == "chain" ]]; then
            _fixture_cold_cycle "${MARK_TRIGGER_WATCHDOG}" "${pub}" \
              "${ONE_SHOT_TIMEOUT_SECS}"
          else
            _fixture_cold_cycle "${MARK_TRIGGER_WATCHDOG}" "${pub}" 5
          fi
          _fixture_publish "${pub}"
        fi
        ;;
      warm)
        printf '08-02 %s.000  1111  1140 I flutter : %s\n' \
          "$(_fixture_bump "${pub}" -2)" "${MARK_TRIGGER_WATCHDOG}"
        _fixture_publish "${pub}"
        ;;
      delivery)
        printf '08-02 %s.000  1111  1140 I flutter : %s\n' \
          "$(_fixture_bump "${pub}" -2)" "${MARK_TRIGGER_DELIVERY}"
        _fixture_publish "${pub}"
        ;;
      none) ;;
    esac
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
  local -r SELF_TEST_FIXTURES=125
  local tmp fail=0 checked=0 got
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  # Every case calls this exactly once, immediately before it asserts.
  _case() { checked=$((checked + 1)); }

  # Cuts <name>.window from <name>.log the way Phase 5 does — through
  # `proof_window_opener` — so a fixture is sliced where the lane slices.
  _cut_window() {
    window_between_markers "${tmp}/$1.log" "$(proof_window_opener "${tmp}/$1.log")" \
      "${MARK_HOLD_DONE}" > "${tmp}/$1.window"
  }

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
    '08-02 04:42:14.552  1234  1300 I flutter : [BackgroundTask] Published to 2-4/2-4 due circle(s) (2-4 eligible), fetched 2-4/2-4 circle(s).' \
    '08-02 04:43:26.552  1234  1300 I flutter : [BackgroundTask] Published to 0/0 due circle(s) (2-4 eligible), fetched 0/2-4 circle(s).' \
    > "${tmp}/multi.log"
  _case
  got="$(max_published_count "${tmp}/multi.log")"
  if [[ "${got}" != "2" ]]; then
    echo "SELF-TEST FAIL (3): expected 2 (the 2-4 bucket's leading number) across cycles, got '${got}'" >&2
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

  # (5) BUCKETS — the app never prints a bare integer above 1: the fields are
  #     `magnitudeBucket` output (`2-4`, `5+`). The parser must read both
  #     shapes and rank `5+` above `2-4` above `1` (run 35376588206's recon
  #     found the previous `[0-9]+/` regex read `2-4/` and `5+/` as NOTHING,
  #     which the caller reports as "no publish cycle" — a false regression).
  printf '%s\n' \
    '08-02 04:42:14.552  1234  1300 I flutter : [BackgroundTask] Published to 2-4/5+ due circle(s) (5+ eligible), fetched 2-4/5+ circle(s).' \
    '08-02 04:43:26.552  1234  1300 I flutter : [BackgroundTask] Published to 5+/5+ due circle(s) (5+ eligible), fetched 5+/5+ circle(s).' \
    > "${tmp}/wide.log"
  _case
  got="$(max_published_count "${tmp}/wide.log")"
  if [[ "${got}" != "5" ]]; then
    echo "SELF-TEST FAIL (5): expected 5 (the 5+ bucket's leading number), got '${got}'" >&2
    fail=1
  fi

  # --- window_between_markers + pid_of_marker ------------------------------
  # These two carry the lane's anti-vacuity checks (windowing to the proof span
  # and same-process proof), so they get fixtures of their own rather than being
  # trusted because they look obvious.
  printf '%s\n' \
    '08-02 04:40:00.000  1111  1120 I flutter : [BackgroundTask] Published to 5+/5+ due circle(s) (5+ eligible), fetched 5+/5+ circle(s).' \
    '08-02 04:41:00.000  1111  1130 I flutter : [b1] HANDOFF_CONFIRMED' \
    '08-02 04:42:14.552  1111  1140 I flutter : [BackgroundTask] Published to 1/1 due circle(s) (1 eligible), fetched 1/1 circle(s).' \
    > "${tmp}/window.log"

  # (6) A publish from BEFORE the handoff must not count. Without the window
  #     the parser would return 5 and the lane would pass on a foreground
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
  _cut_window power.ok

  # A capture whose most recent cycle before every steady-state sample is the
  # WATCHDOG — the one cycle a `getCurrentLocation()` one-shot is legitimate on.
  awk -v wd='08-02 04:41:39.000  1111  1140 I flutter : [BackgroundTask] cycle trigger=watchdog' '
    /SAMPLE [345]$/ { print wd }
    { print }
  ' "${tmp}/power.ok.log" > "${tmp}/power.watchdog.log"
  _cut_window power.watchdog

  # The same for the RECOVERY cycle — the other cycle that runs only because no
  # delivery can arrive, and therefore the other one whose registration is not a
  # steady-state one and whose cache-miss one-shot is legitimate. The error, the
  # recovery and its ARM, so the fixture is the shape the device logs: the arm
  # is what makes `sample_armed_by` read `stream-error`, and a fixture with only
  # the trigger word would pass a proximity reading and prove nothing.
  local st_err st_re st_arm
  st_err='08-02 04:41:34.000  1111  1140 I flutter : [BackgroundTask] fix stream error: LocationServiceDisabledException'
  st_re='08-02 04:41:36.000  1111  1140 I flutter : [BackgroundTask] cycle trigger=stream-error'
  st_arm="08-02 04:41:37.000  1111  1140 I flutter : ${MARK_REG_ARMED}40s)"
  awk -v er="${st_err}" -v re="${st_re}" -v ar="${st_arm}" '
    /SAMPLE [345]$/ { print er; print re; print ar }
    { print }
  ' "${tmp}/power.ok.log" > "${tmp}/power.rearm.log"
  _cut_window power.rearm

  # THE SHAPE PROXIMITY GETS WRONG (the red capture's own, at a harmless 128 s).
  # ONE recovery, which arms before sample 3 and is then KEPT: a delivery that
  # lands more than `kBackgroundFixHorizon - kBackgroundFixLeadTime` before the
  # aim finds nothing due, publishes nothing and re-arms nothing, because
  # `registrationIsAligned` holds. Samples 4-5 are therefore taken DURING a
  # `trigger=delivery` cycle while the live request is still the recovery's.
  #
  # Built on a base with NO delivery-driven cycles, because
  # `_fixture_delivery_cycle` arms one of its own — which would make the
  # recovery's arm no longer the last one and quietly defeat the fixture.
  build_fixture_logcat "${tmp}/power.rearmkept.base.log" 0 "${d1_ok}" \
    "${d2_ok}" '04:42:45'
  awk -v er="${st_err}" -v re="${st_re}" -v ar="${st_arm}" \
      -v dl='08-02 04:41:50.000  1111  1140 I flutter : [BackgroundTask] cycle trigger=delivery' '
    /SAMPLE 3$/ { print er; print re; print ar }
    /SAMPLE 4$/ { print dl }
    { print }
  ' "${tmp}/power.rearmkept.base.log" > "${tmp}/power.rearmkept.log"
  _cut_window power.rearmkept

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

  # (31b) …and on a RECOVERY cycle, for the same reason: it too runs only
  #      because the platform stopped delivering, so its cache is cold by
  #      construction and the one-shot is the fallback, not a per-tick request.
  _case
  if ! assert_registration_oracle "${tmp}/power.rearm.log" "${tmp}/samples.oneshot" \
       "${tmp}/power.rearm.window" >/dev/null; then
    echo "SELF-TEST FAIL (31b): a legitimate one-shot on a '${MARK_TRIGGER_REARM}' \
cycle was reported as a violation" >&2
    assert_registration_oracle "${tmp}/power.rearm.log" "${tmp}/samples.oneshot" \
      "${tmp}/power.rearm.window" >&2 || true
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

  # (34b)/(34c)/(34d) The ONE cycle the ${MIN_FIX_INTERVAL_SECS} s floor is not
  #      the floor for. A recovery re-aims at a due-time that has not moved, so
  #      it asks for the remainder of an interval already at least
  #      kLocationPublishMinInterval long — 40 s here. On that cycle it passes;
  #      on a delivery-driven one the identical request is the overdue-planning
  #      defect CI run 34511084722 shipped; and the platform floor binds even
  #      the recovery, because `nextFixRequestInterval` applies it last.
  build_fixture_samples "${tmp}/samples.40" "${FIX_REQ_UI}" "${FIX_REQ_FGS}" \
    "${FIX_REQ_40S}"
  _case
  if ! assert_registration_oracle "${tmp}/power.rearm.log" "${tmp}/samples.40" \
       "${tmp}/power.rearm.window" >/dev/null; then
    echo "SELF-TEST FAIL (34b): a 40 s re-aim on a '${MARK_TRIGGER_REARM}' cycle was \
rejected — a recovery asking for 62 s would publish LATE, and asking for nothing would \
leave the cadence on the watchdog" >&2
    assert_registration_oracle "${tmp}/power.rearm.log" "${tmp}/samples.40" \
      "${tmp}/power.rearm.window" >&2 || true
    fail=1
  fi
  _case
  if assert_registration_oracle "${tmp}/power.ok.log" "${tmp}/samples.40" \
       "${tmp}/power.ok.window" >/dev/null 2>&1; then
    echo "SELF-TEST FAIL (34c): a 40 s registration on a delivery-driven cycle passed \
the ${MIN_FIX_INTERVAL_SECS} s floor — that is the defect run 34511084722 exposed, and \
the recovery carve-out must not cover it" >&2
    fail=1
  fi
  build_fixture_samples "${tmp}/samples.30" "${FIX_REQ_UI}" "${FIX_REQ_FGS}" \
    "${FIX_REQ_30S}"
  _case
  if assert_registration_oracle "${tmp}/power.rearm.log" "${tmp}/samples.30" \
       "${tmp}/power.rearm.window" >/dev/null 2>&1; then
    echo "SELF-TEST FAIL (34d): a 30 s request passed under the \
${PLATFORM_MIN_INTERVAL_SECS} s platform floor because a '${MARK_TRIGGER_REARM}' cycle \
was running — the platform floor is not a cadence choice and no cycle may go under it" >&2
    fail=1
  fi

  # (34e) THE ATTRIBUTION ITSELF. The recovery's 40 s request is still the live
  #      one when a later delivery-driven cycle runs and re-arms nothing — the
  #      red capture's own shape, harmless there only because the request was
  #      128 s. Read by proximity, every sample after that delivery reports a
  #      sub-${MIN_FIX_INTERVAL_SECS} s request on a 'delivery' cycle and a
  #      CORRECT build reds.
  _case
  if ! assert_registration_oracle "${tmp}/power.rearmkept.log" "${tmp}/samples.40" \
       "${tmp}/power.rearmkept.window" >/dev/null; then
    echo "SELF-TEST FAIL (34e): a recovery-armed 40 s request that OUTLIVED its cycle \
was charged to the '${MARK_TRIGGER_DELIVERY#*trigger=}' cycle running when the sample \
was taken — a registration outlives the cycle that armed it, so the carve-out has to \
key on the ARMING cycle" >&2
    assert_registration_oracle "${tmp}/power.rearmkept.log" "${tmp}/samples.40" \
      "${tmp}/power.rearmkept.window" >&2 || true
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
  if ! assert_cadence_oracle "${tmp}/power.ok.window" \
       "${tmp}/power.ok.log" >/dev/null; then
    echo "SELF-TEST FAIL (41): a ${MIN_DELIVERY_GAP_SECS} s delivery gap was rejected" >&2
    assert_cadence_oracle "${tmp}/power.ok.window" "${tmp}/power.ok.log" >&2 || true
    fail=1
  fi
  build_fixture_logcat "${tmp}/power.tight.log" 2 "${d1_ok}" "${d2_tight}" '04:42:45'
  _cut_window power.tight
  _case
  if assert_cadence_oracle "${tmp}/power.tight.window" \
       "${tmp}/power.tight.log" >/dev/null 2>&1; then
    echo "SELF-TEST FAIL (42): a $((MIN_DELIVERY_GAP_SECS - 1)) s delivery gap passed" >&2
    fail=1
  fi

  # (43) One publish in the whole window: the platform delivered once and never
  #      again, which is the failure mode the delivery-driven cadence replaced a
  #      poll with.
  build_fixture_logcat "${tmp}/power.none.log" 0 "${d1_ok}" "${d2_ok}" '04:42:45'
  _cut_window power.none
  _case
  if assert_cadence_oracle "${tmp}/power.none.window" \
       "${tmp}/power.none.log" >/dev/null 2>&1; then
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
  _cut_window power.barren
  _case
  if ! assert_cadence_oracle "${tmp}/power.barren.window" \
       "${tmp}/power.barren.log" >/dev/null; then
    echo "SELF-TEST FAIL (44): a delivery that produced no publish was counted as a \
cadence point" >&2
    assert_cadence_oracle "${tmp}/power.barren.window" \
      "${tmp}/power.barren.log" >&2 || true
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
  _cut_window power.single
  _case
  if ! assert_cadence_oracle "${tmp}/power.single.window" \
       "${tmp}/power.single.log" >/dev/null; then
    echo "SELF-TEST FAIL (45): the one-delivery window a healthy 200 s hold actually \
produces was rejected at exactly the ${MIN_DELIVERY_GAP_SECS} s floor" >&2
    assert_cadence_oracle "${tmp}/power.single.window" \
      "${tmp}/power.single.log" >&2 || true
    fail=1
  fi
  build_fixture_logcat "${tmp}/power.singletight.log" 1 "${d1_tight}" "${d2_ok}" '04:42:45'
  _cut_window power.singletight
  _case
  if assert_cadence_oracle "${tmp}/power.singletight.window" \
       "${tmp}/power.singletight.log" >/dev/null 2>&1; then
    echo "SELF-TEST FAIL (46): a one-delivery window \
$((MIN_DELIVERY_GAP_SECS - 1)) s after its registration passed — the oracle is silent \
on the window a healthy run actually produces" >&2
    fail=1
  fi

  # (47) Two publishes, neither of them delivery-driven. Nothing is measurable,
  #      and "nothing measurable" must never read as "every pair was fine".
  sed 's/trigger=delivery/trigger=watchdog/' "${tmp}/power.single.log" \
    > "${tmp}/power.nodelivery.log"
  _cut_window power.nodelivery
  _case
  if assert_cadence_oracle "${tmp}/power.nodelivery.window" \
       "${tmp}/power.nodelivery.log" >/dev/null 2>&1; then
    echo "SELF-TEST FAIL (47): a window with no delivery-driven publish at all passed \
the cadence oracle" >&2
    fail=1
  fi

  # (48) A delivery-driven publish with no registration before it. Unmeasurable
  #      for a different reason, and equally not a pass.
  grep -vF -- "${MARK_REG_ARMED}" "${tmp}/power.single.log" \
    > "${tmp}/power.noarm.log" || true
  _cut_window power.noarm
  _case
  if assert_cadence_oracle "${tmp}/power.noarm.window" \
       "${tmp}/power.noarm.log" >/dev/null 2>&1; then
    echo "SELF-TEST FAIL (48): a delivery with no '${MARK_REG_ARMED}' before it passed" >&2
    fail=1
  fi

  # --- step 7 on run 34511084722's own lines -------------------------------
  # Verbatim, in the order the device logged them. The handoff cycle acquired,
  # armed (81 ms before `[b1] HANDOFF_CONFIRMED`) and published ahead of the
  # drive's poll — the order no synthetic fixture above has, and the one that
  # reddened that run while the marker opened the window. (74) replays it as
  # the onStart-acquire variant, where the marker still does.
  local -r R_ONSTART='09-10 18:23:12.318  4032  4032 I flutter : [BackgroundTask] onStart (starter=TaskStarter.developer)'
  local -r R_PAUSE='09-10 18:23:15.055  4032  4032 I flutter : [b1] PAUSE_DELIVERED pid=4032'
  local -r R_TRIG_PAUSED='09-10 18:23:15.138  4032  4032 I flutter : [BackgroundTask] cycle trigger=paused-signal'
  local -r R_ACQUIRED='09-10 18:23:15.980  4032  4032 I flutter : [BackgroundTask] session acquired'
  local -r R_ARM_98='09-10 18:23:16.091  4032  4032 I flutter : [BackgroundTask] registration armed (98s)'
  local -r R_HANDOFF='09-10 18:23:16.172  4032  4032 I flutter : [b1] HANDOFF_CONFIRMED'
  local -r R_PUB_HANDOFF='09-10 18:23:16.957  4032  4032 I flutter : [BackgroundTask] Published to 1/1 due circle(s) (1 eligible), fetched 1/1 circle(s).'
  local -r R_TRIG_D1='09-10 18:24:55.341  4032  4032 I flutter : [BackgroundTask] cycle trigger=delivery'
  local -r R_ARM_128='09-10 18:24:55.356  4032  4032 I flutter : [BackgroundTask] registration armed (128s)'
  local -r R_PUB_D1='09-10 18:25:06.374  4032  4032 I flutter : [BackgroundTask] Published to 1/1 due circle(s) (1 eligible), fetched 0/1 circle(s).'
  local -r R_HOLD='09-10 18:26:36.205  4032  4032 I flutter : [b1] HOLD_COMPLETE'
  # The same run's forced-idle phase, after R_HOLD: the 31 s arm at the floor,
  # a delivery with nothing due, the 40 s re-aim, and the publish it drove.
  local -r R_TRIG_WD='09-10 18:28:01.064  4032  4032 I flutter : [BackgroundTask] cycle trigger=watchdog'
  local -r R_ARM_31='09-10 18:28:01.076  4032  4032 I flutter : [BackgroundTask] registration armed (31s)'
  local -r R_PUB_WD='09-10 18:28:06.023  4032  4032 I flutter : [BackgroundTask] Published to 1/1 due circle(s) (1 eligible), fetched 1/1 circle(s).'
  local -r R_TRIG_D2='09-10 18:28:37.362  4032  4032 I flutter : [BackgroundTask] cycle trigger=delivery'
  local -r R_ARM_40='09-10 18:28:37.373  4032  4032 I flutter : [BackgroundTask] registration armed (40s)'
  local -r R_TRIG_D3='09-10 18:29:22.367  4032  4032 I flutter : [BackgroundTask] cycle trigger=delivery'
  local -r R_ARM_116='09-10 18:29:22.378  4032  4032 I flutter : [BackgroundTask] registration armed (116s)'
  local -r R_PUB_D3='09-10 18:29:29.088  4032  4032 I flutter : [BackgroundTask] Published to 1/1 due circle(s) (1 eligible), fetched 0/1 circle(s).'
  # Run 34488512808's handoff registration, from an earlier app process, and
  # the acquire that process logged ahead of it (synthesized on the arm's stamp:
  # that run's capture holds only the arm).
  local -r R_ARM_PREV_PROC='09-10 14:54:58.153  4190  4190 I flutter : [BackgroundTask] registration armed (144s)'
  local -r R_ACQ_PREV_PROC='09-10 14:54:57.901  4190  4190 I flutter : [BackgroundTask] session acquired'

  # Writes <name>.log from the remaining arguments and cuts <name>.window from it.
  _real_capture() {
    local name="$1"; shift
    printf '%s\n' "$@" > "${tmp}/${name}.log"
    _cut_window "${name}"
  }
  _real_capture real.ok "${R_ONSTART}" "${R_PAUSE}" "${R_TRIG_PAUSED}" \
    "${R_ACQUIRED}" "${R_ARM_98}" "${R_HANDOFF}" "${R_PUB_HANDOFF}" \
    "${R_TRIG_D1}" "${R_ARM_128}" "${R_PUB_D1}" "${R_HOLD}"

  # (66) The delivery pairs with the 98 s registration the handoff cycle armed:
  #      18:23:16.091 -> 18:24:55.341.
  _case
  got="$(delivery_gaps_after_registration "${tmp}/real.ok.window" "${tmp}/real.ok.log")"
  if [[ "${got}" != "99250|98000|paused-signal" ]]; then
    echo "SELF-TEST FAIL (66): run 34511084722's first delivery paired as '${got}', \
expected 99250 ms after the handoff cycle's registration" >&2
    fail=1
  fi

  # (67) …so step 7 passes the window that run actually produced.
  _case
  if ! assert_cadence_oracle "${tmp}/real.ok.window" "${tmp}/real.ok.log" >/dev/null; then
    echo "SELF-TEST FAIL (67): step 7 failed run 34511084722's healthy window" >&2
    assert_cadence_oracle "${tmp}/real.ok.window" "${tmp}/real.ok.log" >&2 || true
    fail=1
  fi

  # (68) Without that registration the delivery has no interval behind it at
  #      all, and reading the capture as well as the window must not find one.
  _real_capture real.noarm "${R_ONSTART}" "${R_PAUSE}" "${R_TRIG_PAUSED}" \
    "${R_ACQUIRED}" "${R_HANDOFF}" "${R_PUB_HANDOFF}" \
    "${R_TRIG_D1}" "${R_ARM_128}" "${R_PUB_D1}" "${R_HOLD}"
  _case
  got="$(delivery_gaps_after_registration "${tmp}/real.noarm.window" \
    "${tmp}/real.noarm.log")"
  if [[ "${got}" != "NOARM" ]] \
     || assert_cadence_oracle "${tmp}/real.noarm.window" "${tmp}/real.noarm.log" \
          >/dev/null 2>&1; then
    echo "SELF-TEST FAIL (68): a delivery with no registration anywhere before it \
paired as '${got}' instead of failing as NOARM" >&2
    fail=1
  fi

  # (69) A registration from a process that has since died is not this
  #      instance's. Paired across the onStart it would read as a 3.5 h gap and
  #      pass, for a delivery that had no interval of its own.
  _real_capture real.prevproc "${R_ARM_PREV_PROC}" "${R_ONSTART}" "${R_PAUSE}" \
    "${R_TRIG_PAUSED}" "${R_ACQUIRED}" "${R_HANDOFF}" "${R_PUB_HANDOFF}" \
    "${R_TRIG_D1}" "${R_ARM_128}" "${R_PUB_D1}" "${R_HOLD}"
  _case
  got="$(delivery_gaps_after_registration "${tmp}/real.prevproc.window" \
    "${tmp}/real.prevproc.log")"
  if [[ "${got}" != "NOARM" ]] \
     || assert_cadence_oracle "${tmp}/real.prevproc.window" \
          "${tmp}/real.prevproc.log" >/dev/null 2>&1; then
    echo "SELF-TEST FAIL (69): a delivery paired with a registration from before \
'[BackgroundTask] onStart' (got '${got}')" >&2
    fail=1
  fi

  # (70) The forced-idle sequence, had it happened inside the proof window: the
  #      publish at 18:29:29 rode a delivery 44 994 ms after the 40 s re-aim that
  #      produced it, under the floor. (The barren 18:28:37 delivery in between
  #      is, as in (44), no cadence point.) R_HOLD's stamp is never read.
  _real_capture real.floor "${R_ONSTART}" "${R_PAUSE}" "${R_TRIG_PAUSED}" \
    "${R_ACQUIRED}" "${R_ARM_98}" "${R_HANDOFF}" "${R_PUB_HANDOFF}" \
    "${R_TRIG_WD}" "${R_ARM_31}" "${R_PUB_WD}" "${R_TRIG_D2}" "${R_ARM_40}" \
    "${R_TRIG_D3}" "${R_ARM_116}" "${R_PUB_D3}" "${R_HOLD}"
  _case
  got="$(delivery_gaps_after_registration "${tmp}/real.floor.window" \
    "${tmp}/real.floor.log")"
  if [[ "${got}" != "44994|40000|delivery" ]] \
     || assert_cadence_oracle "${tmp}/real.floor.window" "${tmp}/real.floor.log" \
          >/dev/null 2>&1; then
    echo "SELF-TEST FAIL (70): run 34511084722's 45 s delivery-driven publish was \
not failed under the ${MIN_DELIVERY_GAP_SECS} s floor (paired as '${got}')" >&2
    fail=1
  fi

  # (71) The capture is context, never claims: widening what step 7 MEASURES
  #      past the window is the one thing reading it must not do. The same real
  #      lines reordered (stamps unread) so a delivery-driven publish precedes
  #      the acquire and the handoff, and the window holds two publishes,
  #      neither of them one.
  _real_capture real.prewindow "${R_ONSTART}" "${R_PAUSE}" "${R_ARM_98}" \
    "${R_TRIG_D1}" "${R_ARM_128}" "${R_PUB_D1}" "${R_HANDOFF}" \
    "${R_TRIG_PAUSED}" "${R_ACQUIRED}" "${R_PUB_HANDOFF}" "${R_TRIG_WD}" \
    "${R_ARM_31}" "${R_PUB_WD}" "${R_HOLD}"
  _case
  if assert_cadence_oracle "${tmp}/real.prewindow.window" \
       "${tmp}/real.prewindow.log" >/dev/null 2>&1; then
    echo "SELF-TEST FAIL (71): a delivery-driven publish from before the window \
opened was credited to the proof window" >&2
    fail=1
  fi

  # --- the provider death, on run 35950857266's own lines ------------------
  # Verbatim, in the order the device logged them. Play services reaped its own
  # persistent process 17 s into a 62 s interval; the stream errored 1 s later;
  # nothing re-armed for 67 s, and the window closed with two publishes and no
  # delivery-driven one. The lane was RIGHT to fail it, and (71b) is that: the
  # product fix changes what the next run does, never what this capture says.
  local -r G_ONSTART='09-24 04:02:31.410  4158  4158 I flutter : [BackgroundTask] onStart (starter=TaskStarter.developer)'
  local -r G_PAUSE='09-24 04:02:40.650  4158  4158 I flutter : [b1] PAUSE_DELIVERED pid=4158'
  local -r G_TRIG_PAUSED='09-24 04:02:40.772  4158  4158 I flutter : [BackgroundTask] cycle trigger=paused-signal'
  local -r G_ACQUIRED='09-24 04:02:41.413  4158  4158 I flutter : [BackgroundTask] session acquired'
  local -r G_ARM_62='09-24 04:02:41.519  4158  4158 I flutter : [BackgroundTask] registration armed (62s)'
  local -r G_HANDOFF='09-24 04:02:41.723  4158  4158 I flutter : [b1] HANDOFF_CONFIRMED'
  local -r G_PUB_HANDOFF='09-24 04:02:42.001  4158  4158 I flutter : [BackgroundTask] Published to 1/1 due circle(s) (1 eligible), fetched 1/1 circle(s).'
  local -r G_GMS_DEATH='09-24 04:02:58.184   518   581 I ActivityManager: Process com.google.android.gms.persistent (pid 1169) has died: fg  BTOP'
  local -r G_STREAM_ERR='09-24 04:02:59.201  4158  4158 I flutter : [BackgroundTask] fix stream error: LocationServiceDisabledException'
  local -r G_TRIG_WD='09-24 04:03:48.912  4158  4158 I flutter : [BackgroundTask] cycle trigger=watchdog'
  local -r G_ARM_128='09-24 04:03:48.931  4158  4158 I flutter : [BackgroundTask] registration armed (128s)'
  local -r G_PUB_WD='09-24 04:03:54.337  4158  4158 I flutter : [BackgroundTask] Published to 1/1 due circle(s) (1 eligible), fetched 0/1 circle(s).'
  local -r G_HOLD='09-24 04:06:01.776  4158  4158 I flutter : [b1] HOLD_COMPLETE'

  # The recovery the fix produces, placed where kStreamErrorRearmDelay puts it:
  # 5 s after the error, re-aiming at the SAME due-time (04:03:53.5), so the
  # remainder it asks for is 39 s. The delivery then lands at the bound, and one
  # second under it is a wake that beat the interval the FGS registered for.
  local -r G_TRIG_REARM='09-24 04:03:04.201  4158  4158 I flutter : [BackgroundTask] cycle trigger=stream-error'
  local -r G_ARM_39='09-24 04:03:04.300  4158  4158 I flutter : [BackgroundTask] registration armed (39s)'
  local -r G_TRIG_D_OK='09-24 04:03:40.300  4158  4158 I flutter : [BackgroundTask] cycle trigger=delivery'
  local -r G_TRIG_D_TIGHT='09-24 04:03:39.300  4158  4158 I flutter : [BackgroundTask] cycle trigger=delivery'
  local -r G_ARM_NEXT='09-24 04:03:41.000  4158  4158 I flutter : [BackgroundTask] registration armed (97s)'
  local -r G_PUB_D='09-24 04:03:41.400  4158  4158 I flutter : [BackgroundTask] Published to 1/1 due circle(s) (1 eligible), fetched 1/1 circle(s).'

  # (71b) The red run itself. Two publishes, no delivery-driven one: still a
  #      FAIL, and now with the provider death printed beside the verdict
  #      instead of buried 26 000 lines into an artefact.
  _real_capture gms.red "${G_ONSTART}" "${G_PAUSE}" "${G_TRIG_PAUSED}" \
    "${G_ACQUIRED}" "${G_ARM_62}" "${G_HANDOFF}" "${G_PUB_HANDOFF}" \
    "${G_GMS_DEATH}" "${G_STREAM_ERR}" "${G_TRIG_WD}" "${G_ARM_128}" \
    "${G_PUB_WD}" "${G_HOLD}"
  _case
  # `|| true`: under `errexit` an assignment from a FAILING command substitution
  # aborts the script, and this oracle is expected to fail here.
  got="$(assert_cadence_oracle "${tmp}/gms.red.window" "${tmp}/gms.red.log" || true)"
  if assert_cadence_oracle "${tmp}/gms.red.window" "${tmp}/gms.red.log" \
       >/dev/null 2>&1; then
    echo "SELF-TEST FAIL (71b): run 35950857266's window — two publishes, neither \
delivery-driven — passed the cadence oracle" >&2
    fail=1
  elif [[ "${got}" != *"${G_GMS_DEATH}"* || "${got}" != *"${G_STREAM_ERR}"* ]]; then
    echo "SELF-TEST FAIL (71b): the cadence failure did not print the Play-services \
process death and the stream error that explain it, verbatim. Got: ${got}" >&2
    fail=1
  fi

  # (71c) The same run with the recovery in it: the delivery-driven publish is
  #      back, inside the same hold, and its spacing is measured against the
  #      39 s the recovery actually asked for.
  _real_capture gms.fixed "${G_ONSTART}" "${G_PAUSE}" "${G_TRIG_PAUSED}" \
    "${G_ACQUIRED}" "${G_ARM_62}" "${G_HANDOFF}" "${G_PUB_HANDOFF}" \
    "${G_GMS_DEATH}" "${G_STREAM_ERR}" "${G_TRIG_REARM}" "${G_ARM_39}" \
    "${G_TRIG_D_OK}" "${G_ARM_NEXT}" "${G_PUB_D}" "${G_HOLD}"
  _case
  got="$(delivery_gaps_after_registration "${tmp}/gms.fixed.window" \
    "${tmp}/gms.fixed.log")"
  if [[ "${got}" != "36000|39000|${MARK_TRIGGER_REARM}" ]] \
     || ! assert_cadence_oracle "${tmp}/gms.fixed.window" \
          "${tmp}/gms.fixed.log" >/dev/null; then
    echo "SELF-TEST FAIL (71c): a delivery 36 s after a 39 s RECOVERY registration was \
not credited (paired as '${got}'). 90 % of 39 s is 35.1 s; charging it the \
${MIN_DELIVERY_GAP_SECS} s steady-state floor reds a correct recovery" >&2
    assert_cadence_oracle "${tmp}/gms.fixed.window" "${tmp}/gms.fixed.log" >&2 || true
    fail=1
  fi

  # (71d) …and one second under 90 % of that ask is a wake the registration did
  #      not buy, which is the same finding the constant floor makes elsewhere.
  _real_capture gms.tight "${G_ONSTART}" "${G_PAUSE}" "${G_TRIG_PAUSED}" \
    "${G_ACQUIRED}" "${G_ARM_62}" "${G_HANDOFF}" "${G_PUB_HANDOFF}" \
    "${G_GMS_DEATH}" "${G_STREAM_ERR}" "${G_TRIG_REARM}" "${G_ARM_39}" \
    "${G_TRIG_D_TIGHT}" "${G_ARM_NEXT}" "${G_PUB_D}" "${G_HOLD}"
  _case
  if assert_cadence_oracle "${tmp}/gms.tight.window" "${tmp}/gms.tight.log" \
       >/dev/null 2>&1; then
    echo "SELF-TEST FAIL (71d): a delivery 35 s after a 39 s recovery registration \
passed a 35.1 s floor" >&2
    fail=1
  fi

  # (71e) THE CARVE-OUT MUST NOT LEAK. The identical 36 s gap after an identical
  #      39 s registration, armed by a DELIVERY-driven cycle, is the
  #      overdue-planning shape (70) pins — the ${MIN_DELIVERY_GAP_SECS} s floor
  #      still applies, and the recovery clause may not reach it.
  _real_capture gms.leak "${G_ONSTART}" "${G_PAUSE}" "${G_TRIG_PAUSED}" \
    "${G_ACQUIRED}" "${G_ARM_62}" "${G_HANDOFF}" "${G_PUB_HANDOFF}" \
    "${G_GMS_DEATH}" "${G_STREAM_ERR}" \
    "$(printf '%s' "${G_TRIG_REARM}" | sed "s/${MARK_TRIGGER_REARM}/watchdog/")" \
    "${G_ARM_39}" "${G_TRIG_D_OK}" "${G_ARM_NEXT}" "${G_PUB_D}" "${G_HOLD}"
  _case
  if assert_cadence_oracle "${tmp}/gms.leak.window" "${tmp}/gms.leak.log" \
       >/dev/null 2>&1; then
    echo "SELF-TEST FAIL (71e): a 36 s delivery after a 39 s registration armed by a \
WATCHDOG cycle passed — only a '${MARK_TRIGGER_REARM}' registration may be measured \
against its own ask" >&2
    fail=1
  fi

  # (71g)/(71h) THE RECOVERY'S OWN BOUND, on the device. The product allows one
  #      recovery per registration that has not delivered, and nothing on this
  #      side would otherwise notice a 5 s re-arm loop at the platform floor: it
  #      would still leave a delivery-driven publish in the window and pass
  #      every other clause here. A second recovery may only follow a NEW
  #      delivery, and a delivery cannot precede the interval the previous
  #      recovery asked for — so ${PLATFORM_MIN_INTERVAL_SECS} s apart is the
  #      derived floor. (No preceding `fix stream error:` is required: `onDone`
  #      raises none.)
  local -r G_TRIG_REARM_LOOP='09-24 04:03:09.201  4158  4158 I flutter : [BackgroundTask] cycle trigger=stream-error'
  local -r G_TRIG_REARM_FAR='09-24 04:03:44.301  4158  4158 I flutter : [BackgroundTask] cycle trigger=stream-error'
  _real_capture gms.loop "${G_ONSTART}" "${G_PAUSE}" "${G_TRIG_PAUSED}" \
    "${G_ACQUIRED}" "${G_ARM_62}" "${G_HANDOFF}" "${G_PUB_HANDOFF}" \
    "${G_GMS_DEATH}" "${G_STREAM_ERR}" "${G_TRIG_REARM}" "${G_ARM_39}" \
    "${G_TRIG_REARM_LOOP}" "${G_TRIG_D_OK}" "${G_ARM_NEXT}" "${G_PUB_D}" \
    "${G_HOLD}"
  _case
  if assert_cadence_oracle "${tmp}/gms.loop.window" "${tmp}/gms.loop.log" \
       >/dev/null 2>&1; then
    echo "SELF-TEST FAIL (71g): two recoveries 5 s apart passed — a re-arm loop against \
a provider that cannot answer is invisible to every other clause in this step" >&2
    fail=1
  fi
  _real_capture gms.spaced "${G_ONSTART}" "${G_PAUSE}" "${G_TRIG_PAUSED}" \
    "${G_ACQUIRED}" "${G_ARM_62}" "${G_HANDOFF}" "${G_PUB_HANDOFF}" \
    "${G_GMS_DEATH}" "${G_STREAM_ERR}" "${G_TRIG_REARM}" "${G_ARM_39}" \
    "${G_TRIG_D_OK}" "${G_ARM_NEXT}" "${G_PUB_D}" "${G_TRIG_REARM_FAR}" \
    "${G_HOLD}"
  _case
  if ! assert_cadence_oracle "${tmp}/gms.spaced.window" "${tmp}/gms.spaced.log" \
       >/dev/null; then
    echo "SELF-TEST FAIL (71h): a second recovery 40 s after the first — after the \
delivery that restored the allowance — was rejected; the allowance is per registration, \
not per service lifetime" >&2
    assert_cadence_oracle "${tmp}/gms.spaced.window" "${tmp}/gms.spaced.log" >&2 || true
    fail=1
  fi

  # (71f) A cadence failure with no provider disturbance says so, so the context
  #      line can never be read as "a reap explains this" when none happened.
  _case
  got="$(assert_cadence_oracle "${tmp}/power.none.window" \
    "${tmp}/power.none.log" || true)"
  if [[ "${got}" != *"no Play-services process died"* ]]; then
    echo "SELF-TEST FAIL (71f): a cadence failure in an undisturbed window did not say \
the provider was up throughout. Got: ${got}" >&2
    fail=1
  fi

  # (71i) A provider REMOVED rather than failed closes the stream and raises no
  #      error, and no process need die for it. The context has to quote that
  #      line too, or the triage reads "the provider was up throughout" over a
  #      window in which Haven's registration ended.
  local -r G_STREAM_CLOSED='09-24 04:02:59.201  4158  4158 I flutter : [BackgroundTask] fix stream closed'
  _real_capture gms.closed "${G_ONSTART}" "${G_PAUSE}" "${G_TRIG_PAUSED}" \
    "${G_ACQUIRED}" "${G_ARM_62}" "${G_HANDOFF}" "${G_PUB_HANDOFF}" \
    "${G_STREAM_CLOSED}" "${G_TRIG_WD}" "${G_ARM_128}" "${G_PUB_WD}" "${G_HOLD}"
  _case
  got="$(assert_cadence_oracle "${tmp}/gms.closed.window" \
    "${tmp}/gms.closed.log" || true)"
  if [[ "${got}" != *"${G_STREAM_CLOSED}"* \
        || "${got}" == *"neither errored nor closed"* ]]; then
    echo "SELF-TEST FAIL (71i): a window whose only disturbance was a CLOSED fix \
stream was reported as undisturbed. Got: ${got}" >&2
    fail=1
  fi

  # --- the window's opener, on run 34740325027's own lines -----------------
  # Verbatim. The FGS acquired, armed and published 38 ms BEFORE the drive's
  # poll printed `[b1] HANDOFF_CONFIRMED`; a window opened at the marker held
  # ONE publish and step 7 reddened a healthy cadence, where run 34676420734 —
  # the same shape, the publish 674 ms AFTER the marker — had passed.
  local -r F_ONSTART='09-13 06:00:35.247  4357  4357 I flutter : [BackgroundTask] onStart (starter=TaskStarter.developer)'
  local -r F_PAUSE='09-13 06:00:38.514  4357  4357 I flutter : [b1] PAUSE_DELIVERED pid=4357'
  local -r F_TRIG_PAUSED='09-13 06:00:38.645  4357  4357 I flutter : [BackgroundTask] cycle trigger=paused-signal'
  local -r F_ACQUIRED='09-13 06:00:39.279  4357  4357 I flutter : [BackgroundTask] session acquired'
  local -r F_ARM_108='09-13 06:00:39.321  4357  4357 I flutter : [BackgroundTask] registration armed (108s)'
  local -r F_PUB_HANDOFF='09-13 06:00:39.527  4357  4357 I flutter : [BackgroundTask] Published to 1/1 due circle(s) (1 eligible), fetched 1/1 circle(s).'
  local -r F_HANDOFF='09-13 06:00:39.565  4357  4357 I flutter : [b1] HANDOFF_CONFIRMED'
  local -r F_TRIG_D1='09-13 06:02:28.772  4357  4357 I flutter : [BackgroundTask] cycle trigger=delivery'
  local -r F_ARM_124='09-13 06:02:28.795  4357  4357 I flutter : [BackgroundTask] registration armed (124s)'
  local -r F_PUB_D1='09-13 06:02:38.085  4357  4357 I flutter : [BackgroundTask] Published to 1/1 due circle(s) (1 eligible), fetched 0/1 circle(s).'
  local -r F_HOLD='09-13 06:03:59.620  4357  4357 I flutter : [b1] HOLD_COMPLETE'

  # (72) The window opens at the FGS's own acquire, so the publish the poll
  #      trailed is credited: two publishes, the delivery paired with the 108 s
  #      registration now INSIDE the window (06:00:39.321 -> 06:02:28.772).
  _real_capture race.ok "${F_ONSTART}" "${F_PAUSE}" "${F_TRIG_PAUSED}" \
    "${F_ACQUIRED}" "${F_ARM_108}" "${F_PUB_HANDOFF}" "${F_HANDOFF}" \
    "${F_TRIG_D1}" "${F_ARM_124}" "${F_PUB_D1}" "${F_HOLD}"
  _case
  got="$(successful_publish_count "${tmp}/race.ok.window")/$(delivery_gaps_after_registration \
    "${tmp}/race.ok.window" "${tmp}/race.ok.log")"
  if [[ "$(head -n 1 "${tmp}/race.ok.window")" != "${F_ACQUIRED}" \
        || "${got}" != "2/109451|108000|paused-signal" ]] \
     || ! assert_cadence_oracle "${tmp}/race.ok.window" "${tmp}/race.ok.log" >/dev/null; then
    echo "SELF-TEST FAIL (72): run 34740325027's healthy window was not credited \
(publishes/gap '${got}') — the FGS's own publish 38 ms before '${MARK_HANDOFF_OK}' is \
post-handoff by construction" >&2
    assert_cadence_oracle "${tmp}/race.ok.window" "${tmp}/race.ok.log" >&2 || true
    fail=1
  fi

  # (73) A publish that precedes the acquire is a publish from before the
  #      handoff, whatever the drive's marker says: the same lines reordered so
  #      a delivery-driven publish and the registration that would pair it sit
  #      between the pause and the acquire. Opened at the pause it would pass —
  #      two publishes, the delivery 109 s after its registration.
  _real_capture race.preacquire "${F_ONSTART}" "${F_PAUSE}" "${F_ARM_108}" \
    "${F_TRIG_D1}" "${F_ARM_124}" "${F_PUB_D1}" "${F_TRIG_PAUSED}" \
    "${F_ACQUIRED}" "${F_PUB_HANDOFF}" "${F_HANDOFF}" "${F_HOLD}"
  _case
  got="$(successful_publish_count "${tmp}/race.preacquire.window")"
  if [[ "$(head -n 1 "${tmp}/race.preacquire.window")" != "${F_ACQUIRED}" \
        || "${got}" != "1" ]] \
     || assert_cadence_oracle "${tmp}/race.preacquire.window" \
          "${tmp}/race.preacquire.log" >/dev/null 2>&1; then
    echo "SELF-TEST FAIL (73): a delivery-driven publish from before \
'${MARK_SESSION_ACQUIRED}' was credited to the proof window (${got} publish(es) \
counted)" >&2
    fail=1
  fi

  # (74) The onStart-acquire variant: nothing is acquired after the pause, so
  #      the drive's marker opens the window and the handoff cycle's
  #      registration lies BEFORE it — run 34511084722's lines without their
  #      acquire, the pairing that reddened that run, read from the capture.
  #      An acquire from an EARLIER process before the pause is not this one.
  _real_capture race.onstart "${R_ACQ_PREV_PROC}" "${R_ARM_PREV_PROC}" \
    "${R_ONSTART}" "${R_PAUSE}" "${R_TRIG_PAUSED}" "${R_ARM_98}" "${R_HANDOFF}" \
    "${R_PUB_HANDOFF}" "${R_TRIG_D1}" "${R_ARM_128}" "${R_PUB_D1}" "${R_HOLD}"
  _case
  got="$(delivery_gaps_after_registration "${tmp}/race.onstart.window" \
    "${tmp}/race.onstart.log")"
  if [[ "$(head -n 1 "${tmp}/race.onstart.window")" != "${R_HANDOFF}" \
        || "${got}" != "99250|98000|paused-signal" ]] \
     || ! assert_cadence_oracle "${tmp}/race.onstart.window" \
          "${tmp}/race.onstart.log" >/dev/null; then
    echo "SELF-TEST FAIL (74): with no '${MARK_SESSION_ACQUIRED}' after the pause the \
window must open at '${MARK_HANDOFF_OK}' and pair the delivery with the registration \
before it (paired as '${got}')" >&2
    assert_cadence_oracle "${tmp}/race.onstart.window" "${tmp}/race.onstart.log" >&2 || true
    fail=1
  fi

  # (75) …and with both, the acquire AFTER the pause is the opener, never the
  #      earlier process's: `window_between_markers` opens at the first
  #      substring match, which is why the opener is a whole line.
  _real_capture race.prevacq "${R_ACQ_PREV_PROC}" "${R_ARM_PREV_PROC}" \
    "${R_ONSTART}" "${R_PAUSE}" "${R_TRIG_PAUSED}" "${R_ACQUIRED}" "${R_ARM_98}" \
    "${R_HANDOFF}" "${R_PUB_HANDOFF}" "${R_TRIG_D1}" "${R_ARM_128}" "${R_PUB_D1}" \
    "${R_HOLD}"
  _case
  got="$(head -n 1 "${tmp}/race.prevacq.window")"
  if [[ "${got}" != "${R_ACQUIRED}" ]] \
     || ! assert_cadence_oracle "${tmp}/race.prevacq.window" \
          "${tmp}/race.prevacq.log" >/dev/null; then
    echo "SELF-TEST FAIL (75): the window opened at '${got}' instead of the acquire \
that followed the pause" >&2
    fail=1
  fi

  # --- step 8: the no-fix chain under deep idle ----------------------------
  #
  # The gap is measured from the publish the fixture opens with (04:43:20), so
  # the at-bound case publishes exactly NO_FIX_BOUND_SECS after it.
  local pub_ok pub_late
  pub_ok="$(_fixture_bump '04:43:20' "${NO_FIX_BOUND_SECS}")"
  pub_late="$(_fixture_bump '04:43:20' "$((NO_FIX_BOUND_SECS + 1))")"

  # (49) Armed, idle engaged, and a cold watchdog cycle published from the last
  #      known position at exactly the bound.
  build_fixture_idle_logcat "${tmp}/idle.ok.log" 'mock' 'IDLE' "chain:${pub_ok}"
  _case
  if ! assert_no_fix_chain_oracle "${tmp}/idle.ok.log" >/dev/null; then
    echo "SELF-TEST FAIL (49): a no-fix chain publish at exactly the \
${NO_FIX_BOUND_SECS} s bound was rejected" >&2
    assert_no_fix_chain_oracle "${tmp}/idle.ok.log" >&2 || true
    fail=1
  fi

  # (50) One second past the bound: publishing recovered too slowly for the
  #      chain's own links to explain.
  build_fixture_idle_logcat "${tmp}/idle.late.log" 'mock' 'IDLE' "chain:${pub_late}"
  _case
  if assert_no_fix_chain_oracle "${tmp}/idle.late.log" >/dev/null 2>&1; then
    echo "SELF-TEST FAIL (50): a chain publish $((NO_FIX_BOUND_SECS + 1)) s after the \
publish before it passed a ${NO_FIX_BOUND_SECS} s bound" >&2
    fail=1
  fi

  # (51) Publishing simply stops once the platform stops answering — the thing
  #      step 8 exists to catch, and the P2b failure mode. The VERDICT matters as
  #      much as the rc: this is the one shape that may be reported as publishing
  #      having stopped.
  build_fixture_idle_logcat "${tmp}/idle.silent.log" 'mock' 'IDLE' 'none'
  _case
  if got="$(assert_no_fix_chain_oracle "${tmp}/idle.silent.log")" \
     || [[ "${got}" != *"STOPPED"* ]]; then
    echo "SELF-TEST FAIL (51): a no-fix window with no publish at all was not reported \
as publishing having stopped: '${got}'" >&2
    fail=1
  fi

  # (52) ANTI-VACUITY. `force-idle` exits 0 on a device that refuses to doze, so
  #      a publish under `state=ACTIVE` is the ordinary watchdog on an awake
  #      device — already covered by steps 1-7, and no kind of Doze result.
  build_fixture_idle_logcat "${tmp}/idle.awake.log" 'mock' 'ACTIVE' "chain:${pub_ok}"
  _case
  if assert_no_fix_chain_oracle "${tmp}/idle.awake.log" >/dev/null 2>&1; then
    echo "SELF-TEST FAIL (52): a publish on a device that never entered deep idle \
passed" >&2
    fail=1
  fi

  # (53) The forced-idle stamp never arrived: also not a pass.
  build_fixture_idle_logcat "${tmp}/idle.nostamp.log" 'mock' 'none' "chain:${pub_ok}"
  _case
  if assert_no_fix_chain_oracle "${tmp}/idle.nostamp.log" >/dev/null 2>&1; then
    echo "SELF-TEST FAIL (53): a capture with no '${MARK_IDLE_FORCED}' stamp passed" >&2
    fail=1
  fi

  # (54) A DELIVERY-driven publish inside the window proves the premise slipped,
  #      and the verdict must say so INSTEAD of claiming publishing stopped: run
  #      34642726338 failed exactly here, with three healthy delivery-driven
  #      publishes in the window and "background publishing STOPS here" as the
  #      verdict.
  build_fixture_idle_logcat "${tmp}/idle.delivery.log" 'mock' 'IDLE' 'delivery:04:45:00'
  _case
  if got="$(assert_no_fix_chain_oracle "${tmp}/idle.delivery.log")" \
     || [[ "${got}" != *"premise did not hold"* || "${got}" == *"STOPPED"* ]]; then
    echo "SELF-TEST FAIL (54): a delivery inside the no-fix window was not reported as \
the premise failing: '${got}'" >&2
    fail=1
  fi

  # (72) The condition was never armed at all — no stamp. Nothing about the
  #      chain can be read from such a capture in EITHER direction.
  build_fixture_idle_logcat "${tmp}/idle.unarmed.log" 'none' 'IDLE' "chain:${pub_ok}"
  _case
  if got="$(assert_no_fix_chain_oracle "${tmp}/idle.unarmed.log")" \
     || [[ "${got}" != *"never armed"* ]]; then
    echo "SELF-TEST FAIL (72): a capture with no '${MARK_NO_FIX_ARMED}' stamp was not \
reported as an unarmed window: '${got}'" >&2
    fail=1
  fi

  # (73) The arm ran and did not take (the app-op is refused SILENTLY, so this is
  #      the shape a mis-armed lane really has). Not a product finding.
  build_fixture_idle_logcat "${tmp}/idle.notmock.log" 'not-mocked' 'IDLE' "chain:${pub_ok}"
  _case
  if got="$(assert_no_fix_chain_oracle "${tmp}/idle.notmock.log")" \
     || [[ "${got}" != *"NOT established"* || "${got}" == *"STOPPED"* ]]; then
    echo "SELF-TEST FAIL (73): a read-back that was not 'mock' was not reported as an \
unestablished premise: '${got}'" >&2
    fail=1
  fi

  # (74) A watchdog publish served from the stream cache is publishing, but it is
  #      not the chain: nothing in it went near the platform. Crediting it would
  #      pass a build whose one-shot/last-known fallback is broken, which is the
  #      half that carries sharing once the cached fix ages out.
  #
  #      It also pins WHERE the too-short-hold note measures from. That warm
  #      publish lands at the bound, leaving under ${NO_FIX_BOUND_SECS} s of hold
  #      after it, so the chain was genuinely not due again before the window
  #      closed and the note belongs here. Anchored on the arm stamp instead the
  #      same capture looks long enough, which is why the anchor is the PUBLISH.
  build_fixture_idle_logcat "${tmp}/idle.warm.log" 'mock' 'IDLE' "warm:${pub_ok}"
  _case
  if got="$(assert_no_fix_chain_oracle "${tmp}/idle.warm.log")" \
     || [[ "${got}" != *"nothing published THROUGH the no-fix chain"* \
           || "${got}" != *"NOT A PRODUCT FINDING"* ]]; then
    echo "SELF-TEST FAIL (74): a cache-served watchdog publish was credited to the \
no-fix chain, or the hold it left too short went unsaid: '${got}'" >&2
    fail=1
  fi

  # (75) The cold read came back in 5 s: the one-shot was ANSWERED, so a fix was
  #      available and the premise slipped between the read-back and the cycle.
  build_fixture_idle_logcat "${tmp}/idle.fast.log" 'mock' 'IDLE' "fast:${pub_ok}"
  _case
  if got="$(assert_no_fix_chain_oracle "${tmp}/idle.fast.log")" \
     || [[ "${got}" != *"one-shot timeout"* || "${got}" == *"STOPPED"* ]]; then
    echo "SELF-TEST FAIL (75): a one-shot answered inside its timeout was accepted as \
the last-known fallback: '${got}'" >&2
    fail=1
  fi

  # (76) The chain's LAST link failing: the cycle asked the platform and never
  #      got a position, so nothing published. That IS publishing stopping, and
  #      the verdict has to name the empty read rather than leave it as a count.
  build_fixture_idle_logcat "${tmp}/idle.empty.log" 'mock' 'IDLE' 'empty:none'
  _case
  if got="$(assert_no_fix_chain_oracle "${tmp}/idle.empty.log")" \
     || [[ "${got}" != *"STOPPED"* || "${got}" != *"never produced a fix"* ]]; then
    echo "SELF-TEST FAIL (76): a cold read that produced no fix at all was not reported \
as the chain's last link failing: '${got}'" >&2
    fail=1
  fi

  # --- the arm read-back's own grammar --------------------------------------
  #
  # The unmocked block below is VERBATIM from run 34642726338's capture (the
  # `dumpsys location` dump `fail()` prints). The mocked one has no real capture
  # yet — this lane has never armed a test provider on a device — so every line
  # of it is derived from AOSP 14 source, field by field, and from nothing
  # observed:
  #
  #   * the header, `last location=` and `enabled=` — `LocationProviderManager
  #     .dump`: `ipw.print(" provider")`, then `if (mProvider.isMock())
  #     ipw.print(" [mock]")`, then `println(":")`. Four-space indent, six-space
  #     body, from `LocationManagerService.dump`'s two-space
  #     `IndentingPrintWriter`.
  #   * `allowed=` / `identity=` / `properties=` — `MockableLocationProvider
  #     .dump`. `identity` is `CallerIdentity.toString`, `uid/package[tag]` —
  #     the shape the real block above shows on a device. The uid is the BINDER
  #     caller's, i.e. `adb shell`'s 2000; the package and tag are the arguments
  #     `LocationShellCommand` passes, `mContext.getOpPackageName()` and
  #     `getAttributionTag()` on the context `LocationManagerService` builds with
  #     `createAttributionContext(ATTRIBUTION_TAG)`, `ATTRIBUTION_TAG =
  #     "LocationService"`. `properties` is `handleAddTestProvider`'s DEFAULT —
  #     `Criteria.POWER_LOW` and `ACCURACY_FINE`, because this lane passes
  #     neither `--powerRequirement` nor `--accuracy` — and
  #     `ProviderProperties.toString` prints POWER_USAGE_LOW as `Low`.
  #     Both lines were transcribed wrongly the first time (`2000/android`,
  #     `powerUsage=High`) and nothing caught it, because the parser reads
  #     neither. A fixture that agrees with the parser rather than with the
  #     platform is the defect this file exists to avoid, so they are corrected
  #     here even though no verdict moves.
  #   * `last mock location=` — `MockLocationProvider.dump`, one line, `null`
  #     until `set-test-provider-location`, which this lane never calls.
  #
  # `extra attribution tags=` is absent because no `--extraAttributionTags` is
  # passed. Both directions fail CLOSED: a grammar this parser does not
  # recognise answers with a token that is not `mock`, and step 8 then refuses
  # to read anything out of the window at all.
  local real_fused mock_fused
  real_fused='    fused provider:
      service: ProviderRequest[OFF]
      last location=Location[fused 52.370215,4.895167 hAcc=5.0 et=+10m0s201ms alt=0.0 vAcc=0.5 vel=0.0 sAcc=0.5]
      enabled=true
      allowed=true
      identity=10131/com.google.android.gms[fused_location_provider]
      extra attribution tags={awareness_provider, activity_recognition_provider, network_location_provider, network_location_calibration, current_semantic_location, fused_location_provider, wearable_flp_shim, geofencer_provider}
      properties=ProviderProperties[powerUsage=Low, accuracy=Fine, supports=[bearing,speed,altitude]]
      stationary throttled=false (not stationary)
      target service=10131/com.google.android.gms/com.google.android.location.fused.FusedLocationService@1
      connected=true'
  mock_fused='    fused provider [mock]:
      service: ProviderRequest[OFF]
      last location=null
      enabled=true
      allowed=true
      identity=2000/android[LocationService]
      properties=ProviderProperties[powerUsage=Low, accuracy=Fine]
      last mock location=null'

  # (77) The real image's own fused block: a provider that can still answer.
  _case
  got="$(printf '%s\n' "${real_fused}" | no_fix_verdict)"
  if [[ "${got}" != "not-mocked" ]]; then
    echo "SELF-TEST FAIL (77): run 34642726338's fused block read as '${got}', expected \
'not-mocked'" >&2
    fail=1
  fi

  # (78) The armed shape, and the only one step 8 accepts.
  _case
  got="$(printf '%s\n' "${mock_fused}" | no_fix_verdict)"
  if [[ "${got}" != "mock" ]]; then
    echo "SELF-TEST FAIL (78): the armed fused block read as '${got}', expected 'mock'" >&2
    fail=1
  fi

  # (79) Installed but left disabled — `add-test-provider` alone leaves it that
  #      way, and geolocator then picks `gps` instead, which CAN answer.
  _case
  got="$(printf '%s\n' "${mock_fused//enabled=true/enabled=false}" | no_fix_verdict)"
  if [[ "${got}" != "mock-disabled" ]]; then
    echo "SELF-TEST FAIL (79): a disabled test provider read as '${got}', expected \
'mock-disabled'" >&2
    fail=1
  fi

  # (80) Something injected a location into it: no longer silent. The value is
  #      `Location.toString()`'s, which for anything a test provider produced
  #      ends in a bare ` mock` (`setProviderLocation` calls
  #      `setIsFromMockProvider(true)`; `toString` then appends it) and carries
  #      `set-test-provider-location`'s default 100 m accuracy.
  _case
  got="$(printf '%s\n' "${mock_fused/last mock location=null/last mock location=Location[fused 52.370215,4.895167 hAcc=100.0 et=+9m1s978ms mock]}" \
    | no_fix_verdict)"
  if [[ "${got}" != "mock-reported-a-location" ]]; then
    echo "SELF-TEST FAIL (80): a test provider that had reported read as '${got}', \
expected 'mock-reported-a-location'" >&2
    fail=1
  fi

  # (81) A test provider whose own dump line is not there: the block says the
  #      provider is mocked but not that it has stayed silent, and "silent" is
  #      the half step 8 rests on. A dump grammar that moved lands here.
  _case
  got="$(printf '%s\n' "${mock_fused%$'\n'*}" | no_fix_verdict)"
  if [[ "${got}" != "mock-unreadable" ]]; then
    echo "SELF-TEST FAIL (81): a test provider with no 'last mock location=' line read \
as '${got}', expected 'mock-unreadable'" >&2
    fail=1
  fi

  # (82) No fused provider in the dump at all — the read-back cannot be vacuous.
  _case
  got="$(printf '%s\n' "${real_fused//fused provider:/network provider:}" | no_fix_verdict)"
  if [[ "${got}" != "no-fused-provider" ]]; then
    echo "SELF-TEST FAIL (82): a dump with no fused block read as '${got}', expected \
'no-fused-provider'" >&2
    fail=1
  fi

  # (85) The armed block AS THE LANE WILL ACTUALLY READ IT. `arm_no_fix` dumps
  #      the instant after the swap, while the FGS still holds its registration
  #      — `MockableLocationProvider.setProviderLocked` hands the mock the
  #      CURRENT request — so the real block carries a live `service:` line and
  #      a `listeners:` sub-block between the header and `last location=`, not
  #      the `ProviderRequest[OFF]` of the quiet fixture above. Those lines are
  #      the one shape the parser has to walk PAST rather than read, and the
  #      indentation is the device's own: run 34642726338's power samples print
  #      `fused` registrations at eight spaces (six-space `listeners:` header
  #      plus `IndentingPrintWriter`'s two), and the request text has no `gps `
  #      provider token on this image.
  _case
  got="$(printf '%s\n' '    fused provider [mock]:
      service: ProviderRequest[@+2m39s0ms, HIGH_ACCURACY, WorkSource{10192 com.oblivioustech.haven}]
      listeners:
        10192/com.oblivioustech.haven/F5F24530 Request[@+2m39s0ms HIGH_ACCURACY, WorkSource{10192 com.oblivioustech.haven}]
        10192/com.oblivioustech.haven/5438ED82 Request[@0 HIGH_ACCURACY, WorkSource{10192 com.oblivioustech.haven}] (inactive)
      last location=null
      enabled=true
      allowed=true
      identity=2000/android[LocationService]
      properties=ProviderProperties[powerUsage=Low, accuracy=Fine]
      last mock location=null' | no_fix_verdict)"
  if [[ "${got}" != "mock" ]]; then
    echo "SELF-TEST FAIL (85): an armed fused block carrying the FGS's live \
registration read as '${got}', expected 'mock' — the parser must walk past the \
'service:'/'listeners:' lines, not read them" >&2
    fail=1
  fi

  # --- the two real captures this step was rebuilt from ---------------------

  # (83) Run 34642726338's forced-idle window, VERBATIM, with the arm stamp this
  #      lane now writes spliced in (that run had none). Three delivery-driven
  #      cycles, each publishing: the verdict must be the premise, and must not
  #      claim publishing stopped — it plainly did not.
  {
    printf '%s\n' \
      '09-11 20:42:53.442  4922  4922 I flutter : [BackgroundTask] Published to 1/1 due circle(s) (1 eligible), fetched 0/1 circle(s).' \
      '09-11 20:44:54.357  4922  4922 I flutter : [b1] IDLE_PHASE_BEGIN'
    printf '09-11 20:44:55.900  6731  6731 I %-8s: %smock\n' \
      "${SAMPLE_TAG}" "${MARK_NO_FIX_ARMED}"
    printf '%s\n' \
      '09-11 20:44:55.932  6731  6731 I b1power : IDLE_FORCED state=IDLE' \
      '09-11 20:45:00.302  4922  4922 I flutter : [BackgroundTask] cycle trigger=delivery' \
      '09-11 20:45:00.314  4922  4922 I flutter : [BackgroundTask] registration armed (159s)' \
      '09-11 20:45:21.964  4922  4922 I flutter : [BackgroundTask] Published to 1/1 due circle(s) (1 eligible), fetched 1/1 circle(s).' \
      '09-11 20:47:44.317  4922  4922 I flutter : [BackgroundTask] cycle trigger=delivery' \
      '09-11 20:47:44.329  4922  4922 I flutter : [BackgroundTask] registration armed (105s)' \
      '09-11 20:47:50.866  4922  4922 I flutter : [BackgroundTask] Published to 1/1 due circle(s) (1 eligible), fetched 1/1 circle(s).' \
      '09-11 20:49:34.326  4922  4922 I flutter : [BackgroundTask] cycle trigger=delivery' \
      '09-11 20:49:34.337  4922  4922 I flutter : [BackgroundTask] registration armed (130s)' \
      '09-11 20:49:40.869  4922  4922 I flutter : [BackgroundTask] Published to 1/1 due circle(s) (1 eligible), fetched 0/1 circle(s).' \
      '09-11 20:50:34.410  4922  4922 I flutter : [b1] IDLE_PHASE_END'
  } > "${tmp}/real.idle.delivery.log"
  _case
  if got="$(assert_no_fix_chain_oracle "${tmp}/real.idle.delivery.log")" \
     || [[ "${got}" != *"premise did not hold"* || "${got}" == *"STOPPED"* \
           || "${got}" != *"3 publish(es)"* ]]; then
    echo "SELF-TEST FAIL (83): run 34642726338's window was not reported as three \
publishes under a premise that did not hold: '${got}'" >&2
    fail=1
  fi

  # (84) Run 34511084722's window, VERBATIM up to its watchdog publish, with the
  #      same stamp spliced in. That publish is what step 8 used to accept as a
  #      pass; its fix arrived 5 s after the trigger, with no cold-read markers
  #      at all (the run predates them), so it cannot be attributed to the chain
  #      and must not be credited to it.
  {
    printf '%s\n' \
      '09-10 18:25:06.374  4032  4032 I flutter : [BackgroundTask] Published to 1/1 due circle(s) (1 eligible), fetched 0/1 circle(s).' \
      '09-10 18:26:36.205  4032  4032 I flutter : [b1] IDLE_PHASE_BEGIN'
    printf '09-10 18:26:38.000  6344  6344 I %-8s: %smock\n' \
      "${SAMPLE_TAG}" "${MARK_NO_FIX_ARMED}"
    printf '%s\n' \
      '09-10 18:26:38.052  6344  6344 I b1power : IDLE_FORCED state=IDLE' \
      '09-10 18:28:01.064  4032  4032 I flutter : [BackgroundTask] cycle trigger=watchdog' \
      '09-10 18:28:01.076  4032  4032 I flutter : [BackgroundTask] registration armed (31s)' \
      '09-10 18:28:06.023  4032  4032 I flutter : [BackgroundTask] Published to 1/1 due circle(s) (1 eligible), fetched 1/1 circle(s).' \
      '09-10 18:32:16.258  4032  4032 I flutter : [b1] IDLE_PHASE_END'
  } > "${tmp}/real.idle.watchdog.log"
  _case
  if got="$(assert_no_fix_chain_oracle "${tmp}/real.idle.watchdog.log")" \
     || [[ "${got}" != *"nothing published THROUGH the no-fix chain"* ]]; then
    echo "SELF-TEST FAIL (84): run 34511084722's unattributable watchdog publish was \
still credited to the no-fix chain: '${got}'" >&2
    fail=1
  fi

  # --- what the step-8 oracle is allowed to CREDIT --------------------------
  #
  # Every case below was found by mutating `assert_no_fix_chain_oracle` and
  # watching the suite stay green: each one is a term the oracle already gets
  # right and nothing above pins. They are here because this step's whole
  # history is of an oracle that read the right thing by accident.

  # (86) The OTHER delivery trigger. `_runCycle` logs `pending-delivery` when a
  #      fix landed while a publish was in flight, so inside this window it says
  #      exactly what `delivery` says — the premise slipped — and the verdict
  #      must not blame the product.
  {
    _fixture_idle_preamble 'mock' 'IDLE'
    printf '08-02 04:45:00.000  1111  1140 I flutter : %s\n' "${MARK_TRIGGER_PENDING}"
    _fixture_publish '04:45:02'
    printf '08-02 04:52:00.000  1111  1130 I flutter : %s\n' "${MARK_IDLE_END}"
  } > "${tmp}/idle.pending.log"
  _case
  if got="$(assert_no_fix_chain_oracle "${tmp}/idle.pending.log")" \
     || [[ "${got}" != *"premise did not hold"* || "${got}" == *"STOPPED"* ]]; then
    echo "SELF-TEST FAIL (86): a '${MARK_TRIGGER_PENDING}' cycle inside the no-fix \
window was not reported as the premise failing: '${got}'" >&2
    fail=1
  fi

  # (87) P0-1's signature INSIDE step 8. The chain ran — cold ask, one-shot run
  #      out, fix in hand — and then every circle's publish failed, so the line
  #      says `0/`. Reading the marker and not the count is the defect this whole
  #      file was built around; step 8 must not reintroduce it by crediting a
  #      cycle that reached no relay.
  {
    _fixture_idle_preamble 'mock' 'IDLE'
    _fixture_cold_cycle "${MARK_TRIGGER_WATCHDOG}" "${pub_ok}" "${ONE_SHOT_TIMEOUT_SECS}"
    printf '08-02 %s.000  1111  1140 I flutter : [BackgroundTask] Published to 0/1 due circle(s) (1 eligible), fetched 0/1 circle(s).\n' \
      "${pub_ok}"
    printf '08-02 04:52:00.000  1111  1130 I flutter : %s\n' "${MARK_IDLE_END}"
  } > "${tmp}/idle.zero.log"
  _case
  if got="$(assert_no_fix_chain_oracle "${tmp}/idle.zero.log")" \
     || [[ "${got}" != *"STOPPED"* ]]; then
    echo "SELF-TEST FAIL (87): a chain cycle whose publish reached 0 circles was not \
reported as publishing having stopped: '${got}'" >&2
    fail=1
  fi

  # (88) The markers belong to ONE cycle. A cold cycle that reached no relay,
  #      followed by a warm watchdog cycle that did, is two facts — not a chain
  #      publish. Crediting it would let a build whose last-known fallback never
  #      publishes pass on the strength of its stream cache.
  {
    _fixture_idle_preamble 'mock' 'IDLE'
    _fixture_cold_cycle "${MARK_TRIGGER_WATCHDOG}" '04:45:00' "${ONE_SHOT_TIMEOUT_SECS}"
    printf '08-02 04:45:00.000  1111  1140 I flutter : [BackgroundTask] Published to 0/1 due circle(s) (1 eligible), fetched 0/1 circle(s).\n'
    printf '08-02 04:46:00.000  1111  1140 I flutter : %s\n' "${MARK_TRIGGER_WATCHDOG}"
    _fixture_publish '04:46:02'
    printf '08-02 04:52:00.000  1111  1130 I flutter : %s\n' "${MARK_IDLE_END}"
  } > "${tmp}/idle.carryover.log"
  _case
  if got="$(assert_no_fix_chain_oracle "${tmp}/idle.carryover.log")" \
     || [[ "${got}" != *"nothing published THROUGH the no-fix chain"* ]]; then
    echo "SELF-TEST FAIL (88): a warm watchdog publish inherited the PREVIOUS cycle's \
cold-read markers and was credited to the chain: '${got}'" >&2
    fail=1
  fi

  # (89) The fourth trigger. `paused-signal` is the UI isolate's handoff prompt,
  #      not a platform delivery: it is neither a premise breach nor the
  #      watchdog, and a cold read under it proves nothing about the chain Doze
  #      has to be carried by. A watchdog cycle runs FIRST and publishes
  #      nothing, so the capture is one where the window's deep-idle ordering is
  #      already satisfied and the trigger is the only thing left separating the
  #      two cycles.
  {
    _fixture_idle_preamble 'mock' 'IDLE'
    printf '08-02 04:44:00.000  1111  1140 I flutter : %s\n' "${MARK_TRIGGER_WATCHDOG}"
    _fixture_cold_cycle '[BackgroundTask] cycle trigger=paused-signal' \
      "${pub_ok}" "${ONE_SHOT_TIMEOUT_SECS}"
    _fixture_publish "${pub_ok}"
    printf '08-02 04:52:00.000  1111  1130 I flutter : %s\n' "${MARK_IDLE_END}"
  } > "${tmp}/idle.paused.log"
  _case
  if got="$(assert_no_fix_chain_oracle "${tmp}/idle.paused.log")" \
     || [[ "${got}" != *"nothing published THROUGH the no-fix chain"* \
           || "${got}" == *"premise did not hold"* ]]; then
    echo "SELF-TEST FAIL (89): a cold 'paused-signal' cycle was credited to the no-fix \
chain (or mistaken for a delivery): '${got}'" >&2
    fail=1
  fi

  # (90) The window's CLOSING edge. Restoring `resumed` hands publishing back to
  #      the UI isolate and stops the service, so anything after
  #      `${MARK_IDLE_END}` is teardown; an oracle that read to EOF would credit
  #      a teardown publish to a window that had already ended.
  {
    _fixture_idle_preamble 'mock' 'IDLE'
    printf '08-02 04:52:00.000  1111  1130 I flutter : %s\n' "${MARK_IDLE_END}"
    _fixture_cold_cycle "${MARK_TRIGGER_WATCHDOG}" '04:53:00' "${ONE_SHOT_TIMEOUT_SECS}"
    _fixture_publish '04:53:00'
  } > "${tmp}/idle.afterend.log"
  _case
  if got="$(assert_no_fix_chain_oracle "${tmp}/idle.afterend.log")" \
     || [[ "${got}" != *"STOPPED"* ]]; then
    echo "SELF-TEST FAIL (90): a chain publish AFTER '${MARK_IDLE_END}' was credited to \
the forced-idle window: '${got}'" >&2
    fail=1
  fi

  # (91) FALSE-RED GUARD, and the only case here that must PASS. Every real
  #      capture opens with the P2a window's delivery-driven cycles; they sit
  #      before the arm stamp and are what steps 5-7 measure. Reading them as
  #      premise breaches — or letting their markers reach the attribution —
  #      would fail a perfectly healthy run.
  {
    _fixture_delivery_cycle '04:43:10'
    _fixture_idle_preamble 'mock' 'IDLE'
    _fixture_cold_cycle "${MARK_TRIGGER_WATCHDOG}" "${pub_ok}" "${ONE_SHOT_TIMEOUT_SECS}"
    _fixture_publish "${pub_ok}"
    printf '08-02 04:52:00.000  1111  1130 I flutter : %s\n' "${MARK_IDLE_END}"
  } > "${tmp}/idle.prearm.log"
  _case
  if ! assert_no_fix_chain_oracle "${tmp}/idle.prearm.log" >/dev/null; then
    echo "SELF-TEST FAIL (91): the P2a window's own delivery cycles, before the arm, \
failed a healthy no-fix window" >&2
    assert_no_fix_chain_oracle "${tmp}/idle.prearm.log" >&2 || true
    fail=1
  fi

  # (92) A clock that moved backwards. The gap is a subtraction of two device
  #      stamps, so a rollback makes it negative — which is smaller than any
  #      bound and would otherwise read as a fast, healthy recovery. Built by
  #      hand rather than from `_fixture_cold_cycle`: the cycle has to stay
  #      inside the forced-idle window while its PUBLISH lands before the one
  #      the gap is measured from, which no derivation from the publish stamp
  #      can produce.
  {
    _fixture_idle_preamble 'mock' 'IDLE'
    printf '08-02 04:45:00.000  1111  1140 I flutter : %s\n' "${MARK_TRIGGER_WATCHDOG}"
    printf '08-02 04:45:02.000  1111  1140 I flutter : %s\n' "${MARK_COLD_ASK}"
    printf '08-02 %s.000  1111  1140 I flutter : %s\n' \
      "$(_fixture_bump '04:45:02' "${ONE_SHOT_TIMEOUT_SECS}")" "${MARK_COLD_IN_HAND}"
    _fixture_publish '04:43:15'
    printf '08-02 04:52:00.000  1111  1130 I flutter : %s\n' "${MARK_IDLE_END}"
  } > "${tmp}/idle.backwards.log"
  _case
  if got="$(assert_no_fix_chain_oracle "${tmp}/idle.backwards.log")" \
     || [[ "${got}" != *"clock moved backwards"* ]]; then
    echo "SELF-TEST FAIL (92): a chain publish stamped BEFORE the publish preceding it \
was accepted rather than reported as a clock rollback: '${got}'" >&2
    fail=1
  fi

  # (93) Deep idle has to come FIRST. A cold watchdog cycle that ran before the
  #      device was dozed is the ordinary awake-device watchdog steps 1-7 already
  #      cover; crediting it would report an awake result as a Doze one even
  #      though the read-back later says IDLE.
  {
    _fixture_idle_preamble 'mock' 'none'
    _fixture_cold_cycle "${MARK_TRIGGER_WATCHDOG}" '04:45:00' "${ONE_SHOT_TIMEOUT_SECS}"
    _fixture_publish '04:45:00'
    printf '08-02 04:46:00.000  1500  1500 I %-8s: %sIDLE\n' \
      "${SAMPLE_TAG}" "${MARK_IDLE_FORCED}"
    printf '08-02 04:52:00.000  1111  1130 I flutter : %s\n' "${MARK_IDLE_END}"
  } > "${tmp}/idle.preidle.log"
  _case
  if got="$(assert_no_fix_chain_oracle "${tmp}/idle.preidle.log")" \
     || [[ "${got}" != *"nothing published THROUGH the no-fix chain"* ]]; then
    echo "SELF-TEST FAIL (93): a cold watchdog publish from BEFORE deep idle engaged \
was credited to the no-fix chain: '${got}'" >&2
    fail=1
  fi

  # (94) Nothing to measure the silence from. Step 3 requires a publish inside
  #      the P2a window, so a capture without one is truncated — a fact about
  #      the capture, which must not be reported as a chain that recovered in
  #      however many seconds the parser happened to compute.
  {
    printf '08-02 04:43:30.000  1111  1130 I flutter : %s\n' "${MARK_HOLD_DONE}"
    printf '08-02 04:43:31.000  1111  1130 I flutter : %s\n' "${MARK_IDLE_BEGIN}"
    printf '08-02 04:43:33.000  1500  1500 I %-8s: %smock\n' \
      "${SAMPLE_TAG}" "${MARK_NO_FIX_ARMED}"
    printf '08-02 04:43:34.000  1500  1500 I %-8s: %sIDLE\n' \
      "${SAMPLE_TAG}" "${MARK_IDLE_FORCED}"
    _fixture_cold_cycle "${MARK_TRIGGER_WATCHDOG}" "${pub_ok}" "${ONE_SHOT_TIMEOUT_SECS}"
    _fixture_publish "${pub_ok}"
    printf '08-02 04:52:00.000  1111  1130 I flutter : %s\n' "${MARK_IDLE_END}"
  } > "${tmp}/idle.noprev.log"
  _case
  if got="$(assert_no_fix_chain_oracle "${tmp}/idle.noprev.log")" \
     || [[ "${got}" != *"no earlier publish"* ]]; then
    echo "SELF-TEST FAIL (94): a chain publish with nothing before it to measure from \
was not reported as a truncated capture: '${got}'" >&2
    fail=1
  fi

  # (95) The hold closed before the chain was DUE. Everything the window needs is
  #      present — armed, dozed, silent — and still nothing published, but only
  #      100 s of the 302 s the chain's own links are allowed had passed. That is
  #      a capture too short to conclude from, and calling it "background sharing
  #      STOPPED" is precisely the over-claim round 3 was reverted for.
  {
    _fixture_idle_preamble 'mock' 'IDLE'
    printf '08-02 04:45:00.000  1111  1130 I flutter : %s\n' "${MARK_IDLE_END}"
  } > "${tmp}/idle.shorthold.log"
  _case
  if got="$(assert_no_fix_chain_oracle "${tmp}/idle.shorthold.log")" \
     || [[ "${got}" != *"NOT A PRODUCT FINDING"* ]]; then
    echo "SELF-TEST FAIL (95): a hold that closed $((NO_FIX_BOUND_SECS - 100)) s before \
the chain was due was reported as publishing having stopped, with nothing said about the \
window being too short: '${got}'" >&2
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


  # (66) location_provider_names / withhold_positions: a real `dumpsys
  #      location` shape — the provider headers and the block structure
  #      survive, the position does not. Planted, then asserted absent.
  printf '%s\n' \
    '  fused provider [mock]:' \
    '      last location=Location[fused 52.370215,4.895167 hAcc=5.0 et=+10m0s201ms alt=0.0]' \
    '      enabled=true' \
    '      last mock location=Location[fused 52.370215,4.895167 hAcc=100.0 et=+9m1s978ms mock]' \
    '  gps provider:' \
    '      last location=Location[gps 52.370215,4.895167 hAcc=5.0 et=+10m0s201ms alt=0.0]' \
    '  passive provider:' \
    > "${tmp}/dumpsys-location.txt"
  _case
  got="$(location_provider_names < "${tmp}/dumpsys-location.txt")"
  if [[ "${got}" != "$(printf '%s\n' 'fused provider [mock]' 'gps provider' 'passive provider')" ]] \
     || grep -q '52.37' <<<"${got}"; then
    echo "SELF-TEST FAIL (66): location_provider_names must print the provider" \
         "headers and never the position; got '${got}'" >&2
    fail=1
  fi
  _case
  got="$(withhold_positions < "${tmp}/dumpsys-location.txt")"
  if grep -q '52.37' <<<"${got}" \
     || [[ "$(grep -c 'location=<withheld>' <<<"${got}")" != "3" ]] \
     || ! grep -q '^      enabled=true$' <<<"${got}"; then
    echo "SELF-TEST FAIL (66b): withhold_positions must keep the block and" \
         "withhold every position; got '${got}'" >&2
    fail=1
  fi

  # (67) log-privacy gate wiring. Source pins in the shape of
  #      run-single-avd-scenario.sh's (9b): the gate is what stands between a
  #      captured log and the job log, so its position is read from this
  #      file's own lines, never trusted. Continuation lines are joined and
  #      comments dropped, so a call that spans lines is one line here;
  #      literals are counted at column 0 (`index == 1`), where the real call
  #      sits and this fixture's own text does not.
  local joined gate_at cat_at trap_body dump_at scan_at exit_at
  joined="$(sed -e ':a' -e '/\\$/N; s/\\\n//; ta' "${self}" | grep -vE '^[[:space:]]*#')"
  gate_at="$(grep -nE '^logscan_gate host /tmp/haven-soak/needles' <<<"${joined}" \
    | cut -d: -f1 | head -n 1 || true)"
  cat_at="$(grep -nE '^[[:space:]]*cat "\$\{(DRIVE_LOG|LOGCAT_FILE)\}"' <<<"${joined}" | cut -d: -f1 | head -n 1 || true)"
  _case
  if [[ -z "${gate_at}" || -z "${cat_at}" ]] || (( cat_at < gate_at )) \
     || [[ "$(grep -cE '^[[:space:]]*cat "\$\{(DRIVE_LOG|LOGCAT_FILE)\}"' <<<"${joined}" || true)" != "1" ]]; then
    echo "SELF-TEST FAIL (67): the drive log must be echoed exactly once, after the" \
         "log-privacy gate (gate='${gate_at}', cat='${cat_at}')" >&2
    fail=1
  fi
  _case
  local gate_lit='logscan_gate host /tmp/haven-soak/needles "${SEAL_EXTRA[@]}" --   --sink "logcat=${LOGCAT_FILE}" --sink "drive=${DRIVE_LOG}"   --report "${LOGSCAN_REPORTS}/gate.ndjson" || LOGSCAN_GATE_RC=$?'
  got="$(awk -v lit="${gate_lit}" \
         'index($0, lit) == 1 { n++ } END { print n + 0 }' <<<"${joined}")"
  if [[ "${got}" != "1" ]]; then
    echo "SELF-TEST FAIL (67b): the gate no longer names the logcat, the drive" \
         "log and this lane's seal claim with the report beside the uploaded" \
         "directory (found ${got})" >&2
    fail=1
  fi
  _case
  trap_body="$(sed -n '/^cleanup() {/,/^}/p' <<<"${joined}")"
  dump_at="$(grep -nF 'docker logs strfry > "${LOG_DIR}/strfry.final.log"' <<<"${trap_body}" | cut -d: -f1 | head -n 1 || true)"
  scan_at="$(grep -nF 'logscan_gate_dir host /tmp/haven-soak/needles "${LOG_DIR}" "${LOGSCAN_REPORTS}/exit.ndjson" "${SEAL_EXTRA[@]}"     || scan_rc=$?' <<<"${trap_body}" \
    | cut -d: -f1 | head -n 1 || true)"
  exit_at="$(grep -nF 'exit "${rc}"' <<<"${trap_body}" | cut -d: -f1 | head -n 1 || true)"
  if [[ -z "${dump_at}" || -z "${scan_at}" || -z "${exit_at}" ]] \
     || (( dump_at > scan_at || scan_at > exit_at )); then
    echo "SELF-TEST FAIL (67c): the EXIT trap must gate the whole log directory" \
         "after the relay dump and before the exit (dump='${dump_at}'," \
         "scan='${scan_at}', exit='${exit_at}')" >&2
    fail=1
  fi
  _case
  local floor='scan-logs-for-'
  floor+='secrets.sh'
  if grep -qE 'if[[:space:]]+\[\[[[:space:]]+-x[[:space:]]' <<<"${joined}" \
     || grep -qF "${floor}" <<<"${joined}"; then
    echo "SELF-TEST FAIL (67d): a soft scanner gate (an -x test on the binary) or" \
         "a bare key-material floor call is back — the floor runs inside the wrapper" >&2
    fail=1
  fi
  _case
  if ! declare -f logscan_gate | grep -q 'HAVEN_LOGSCAN'; then
    echo "SELF-TEST FAIL (67e): the sourced gate has no HAVEN_LOGSCAN arm" >&2
    fail=1
  fi
  # (67f) The seal claim both gates pass is this lane's injected point AND its
  #       drive floor, pinned at the ONE place they live. Every gate after the
  #       first reuses the manifest the pre-seal wrote, so a declaration that
  #       reached a gate but not this array would be silently dropped — a
  #       coordinate the scan never searches its own captures for, which looks
  #       exactly like a clean run.
  _case
  local extra_lit='readonly -a SEAL_EXTRA=(--host-decl "coordinate=${GEO_LAT},${GEO_LON}" --floor drive=9 --floor relay=7)'
  got="$(awk -v lit="${extra_lit}" \
         'index($0, lit) == 1 { n++ } END { print n + 0 }' "${self}")"
  if [[ "${got}" != "1" ]]; then
    echo "SELF-TEST FAIL (67f): the seal extras no longer carry the injected" \
         "point and this lane's drive and relay floors (found ${got})" >&2
    fail=1
  fi
  # (67g) …and the pre-seal that writes them runs before the EXIT trap is
  #       armed: the host profile REUSES whatever manifest is at the out path,
  #       so a pre-seal moved below the trap leaves the policy defaults sealed
  #       and both the declaration and the floor silently inoperative.
  _case
  local seal_at trap_at
  seal_at="$(grep -n -m1 '^logscan_seal host /tmp/haven-soak/needles "${SEAL_EXTRA\[@\]}" || seal_rc=$?$' \
    "${self}" | cut -d: -f1 || true)"
  trap_at="$(grep -n -m1 '^trap cleanup EXIT$' "${self}" | cut -d: -f1 || true)"
  if [[ -z "${seal_at}" || -z "${trap_at}" ]] || (( seal_at > trap_at )); then
    echo "SELF-TEST FAIL (67g): the manifest must be sealed once before the EXIT" \
         "trap is armed (seal='${seal_at}', trap='${trap_at}')" >&2
    fail=1
  fi
  # (67h) …and that drive floor stays derived from what `flutter drive` prints
  #       on the HOST rather than from a transcript's length. The fixture is
  #       this lane's host-printed skeleton interleaved with forwarded device
  #       chatter, exactly as a real capture is: the floor may not exceed the
  #       skeleton, so a number measured from a whole transcript (249 was the
  #       shortest complete one) is rejected by the same check. Without this,
  #       the next red lane gets re-pinned from a length again — which is how a
  #       COMPLETE capture was reddened in CI run 35464818348.
  local host_printed_re printed drive_floor
  host_printed_re='^(Installing |VMServiceFlutterDriver: |All tests passed\.|Failure Details:|Leaving the application running\.)'
  printf '%s\n' \
    'Installing /tmp/integration-apks/b1_fgs_publish_test.apk...      8.7s' \
    'I/Choreographer( 4472): Skipped 147 frames!' \
    'VMServiceFlutterDriver: Connecting to Flutter application at <endpoint>' \
    'VMServiceFlutterDriver: Isolate found with number: <n>' \
    'VMServiceFlutterDriver: Isolate <n> is runnable.' \
    'VMServiceFlutterDriver: Isolate is paused at start.' \
    'VMServiceFlutterDriver: Attempting to resume isolate' \
    'VMServiceFlutterDriver: Connected to Flutter application.' \
    'I/flutter ( 4472): 00:00 +0: B1: the foreground service publishes' \
    'I/flutter ( 4472): 05:12 +2: All tests passed!' \
    'All tests passed.' \
    'Leaving the application running.' > "${tmp}/host-printed.drive.log"
  printed="$(grep -cE "${host_printed_re}" "${tmp}/host-printed.drive.log" || true)"
  _case
  if [[ "${printed}" != "9" ]]; then
    echo "SELF-TEST FAIL (67h): the fixture must carry this lane's 9-line" \
         "host-printed skeleton, counted ${printed} — the check below would" \
         "otherwise be measuring the wrong thing" >&2
    fail=1
  fi
  drive_floor="$(sed -n -E 's/^readonly -a SEAL_EXTRA=\(.*--floor drive=([0-9]+).*/\1/p' "${self}")"
  _case
  if [[ -z "${drive_floor}" ]] || (( drive_floor < 1 || drive_floor > printed )); then
    echo "SELF-TEST FAIL (67i): drive=${drive_floor:-none} is not within the" \
         "${printed} line(s) \`flutter drive\` prints on the host. A drive floor" \
         "is calibrated to those alone; a higher one was measured from a" \
         "transcript that also carried forwarded logcat furniture, which is not" \
         "a property of the run. 'A test ran' is the scanner's proof_of_run," \
         "not this number." >&2
    fail=1
  fi

  # (68) No coordinate reaches the step log: the injected point is never
  #      echoed, and every `dumpsys location` the lane RUNS either prints
  #      through a filter — the provider names, the position-withholding
  #      block, the sampler's own — or is captured for the verdict parser.
  _case
  if grep -qE '(echo|printf) .*\$\{GEO_L(AT|ON)' <<<"${joined}"; then
    echo "SELF-TEST FAIL (68): the injected coordinates are echoed" >&2
    fail=1
  fi
  _case
  got="$(grep -E 'adb .*dumpsys location|dumpsys location;' <<<"${joined}" \
    | grep -vcE 'location_provider_names|withhold_positions|filter_power_sample|^  dump=' || true)"
  if [[ "${got}" != "0" ]]; then
    echo "SELF-TEST FAIL (68b): ${got} \`dumpsys location\` read(s) print without" \
         "a position filter" >&2
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
# publish can land after the handoff cycle) and the forced-idle one (362 s: the
# no-fix chain's own length, plus one last pre-arm cycle and the arming round
# trips, step 8) — plus RustLib/keyring/SQLCipher boot under
# the emulator's mlock pressure, plus GPS and relay slack, plus the broadcast
# barrier below. The drive target's own `Timeout` is 15m and fires first with an
# attributable message; this is the belt. Phase 5 holds no timeouts of its own —
# by the time it reads, the capture is complete, so it is a set of reads rather
# than live polls.
readonly DRIVE_TIMEOUT="${B1_DRIVE_TIMEOUT:-20m}"

# How long SIGKILL follows the drive's SIGTERM at DRIVE_TIMEOUT: a term in
# this lane's worst case, which its workflow derives at the drive step.
readonly DRIVE_KILL_AFTER_SECS=30

# The bound on `am wait-for-broadcast-barrier` (Phase 4): ~3.5x the 34 s the
# install broadcasts took to reach LocationManagerService in run 34488512808.
# The drive's own wait (`_broadcastBarrierWait`, 150 s) outlasts it, so a
# barrier that never drains is reported HERE, by name.
readonly BARRIER_TIMEOUT_SECS=120

# Synthetic coordinates fed to the emulator's GPS: Dam Square, Amsterdam — a
# well-known public landmark, chosen precisely BECAUSE it is obviously not a
# real user's position. The kind-445 carrying it is MLS-encrypted on the wire.
#
# Declared to the log-privacy gate as a needle: synthetic or not, a position
# in a log is the violation (Security Rule 15), so nothing here prints it — the
# sampler filters it out on the host and `fail()` prints provider names only.
readonly GEO_LON="${B1_GEO_LON:-4.895168}"
readonly GEO_LAT="${B1_GEO_LAT:-52.370216}"

readonly HAVEN_DIR="${REPO_ROOT}/haven"
readonly START_STRFRY="${SCRIPT_DIR}/start-strfry.sh"
readonly STOP_STRFRY="${SCRIPT_DIR}/stop-strfry.sh"

LOGCAT_PID=""
GEO_PID=""
SAMPLE_PID=""
IDLE_PID=""
BARRIER_PID=""

mkdir -p "${LOG_DIR}"
readonly LOGCAT_FILE="${LOG_DIR}/logcat.b1.log"
readonly DRIVE_LOG="${LOG_DIR}/flutter-drive.log"
readonly SAMPLE_FILE="${LOG_DIR}/dumpsys-power-samples.log"

# The post-drive gate's verdict, folded into the EXIT trap's: a leak the gate
# contained has deleted its sinks, so the trap's rescan alone would read clean.
LOGSCAN_GATE_RC=0
# The scanner's findings reports (sink:line, class, rule — never a value) live
# BESIDE the uploaded directory, not in it: the workflow uploads LOG_DIR whole.
readonly LOGSCAN_REPORTS="/tmp/b1-logscan"
mkdir -p "${LOGSCAN_REPORTS}"

# ---------------------------------------------------------------------------
# Cleanup (EXIT trap): stop the background helpers, run the MANDATORY
# log-privacy scan over every captured log (Security Rules 6 and 15 — must run
# even on a phase failure), snapshot + tear down strfry. Escalates on a leak;
# never masks a phase rc.
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
  echo "== Log-privacy scan over ${LOG_DIR} (Security Rules 6 and 15) =="
  logscan_gate_dir host /tmp/haven-soak/needles "${LOG_DIR}" "${LOGSCAN_REPORTS}/exit.ndjson" "${SEAL_EXTRA[@]}" \
    || scan_rc=$?
  if (( scan_rc == 1 || LOGSCAN_GATE_RC == 1 )); then
    # CONTAINMENT, not just detection. The workflow uploads ${LOG_DIR} with
    # `if: always()` and a 14-day retention, so merely going red here would
    # publish the leaking log for a fortnight — the guard would tell us about
    # the leak while shipping it. The wrapper has destroyed the sinks; leave a
    # marker — the scanner has already printed file + label + line numbers
    # (never the matched content), which is everything triage needs.
    {
      echo "Logs withheld: the log-privacy gate tripped (Security Rules 6 and 15)."
      echo "See the LEAK line(s) in the step log for file/label/line numbers."
    } > "${LOG_DIR}/LEAK_DETECTED.txt"
    echo "ERROR: log-privacy gate tripped on B1 logs — logs deleted, not uploaded." >&2
    rc=1
  elif (( scan_rc != 0 || LOGSCAN_GATE_RC != 0 )); then
    # rc 3 = a log was absent / unreadable / EMPTY, i.e. this lane died before
    # it finished writing its evidence. Go red — a run that scanned nothing has
    # proved nothing — but deliberately do NOT take the containment branch.
    # Deletion exists to stop a LEAK from being published; there is no leak
    # here, only the truncated crash artefacts that triage needs most, and
    # destroying them would erase the evidence of the very failure that tripped
    # the guard.
    echo "ERROR: the log-privacy gate could not certify the B1 logs" \
         "(rc=${scan_rc}, post-drive rc=${LOGSCAN_GATE_RC}) — see the lines" \
         "above. Logs kept for triage." >&2
    rc=1
  fi
  bash "${STOP_STRFRY}" >/dev/null 2>&1 || true
  exit "${rc}"
}

# This lane's whole seal claim, in ONE place because every gate after the first
# reuses the manifest the first one wrote: a `--host-decl` passed to a later
# gate alone would be silently dropped, and the captures would never be
# searched for the point this lane feeds the emulator's GPS.
#
# drive=9. A floor is what turns "the scan read an empty or truncated file and
# found nothing" into rc 4 instead of a green, so it is calibrated to the part
# of a capture its PRODUCER always writes — never to what would make this lane
# pass, and never to a length the device can change. Until now this lane sealed
# no floor at all, so the policy default of 100 applied to its single transcript
# (tooling/logscan/policy.toml) against complete captures of 249, 266, 279 and
# 290 lines across four green runs (35311161479, 35376588206, 35397118356,
# 35524002720) — a number that is not a property of the run at all, since a
# `flutter drive` transcript is the tool's own output INTERLEAVED with whatever
# logcat furniture the device happened to print. Chasing it is how a COMPLETE
# capture was reddened in CI run 35464818348.
#
# "A test actually ran" is proven by the scanner instead, from the test
# reporter's own progress line (`proof_of_run` on the `drive` class in
# policy.toml). What is left for this floor is the other failure — an empty or
# truncated file — so it is derived from what `flutter drive` prints on the
# HOST, which no device chatter can change: `Installing …` (flutter_tools
# installs unconditionally on every launch), the six `VMServiceFlutterDriver:`
# connect lines (four unconditional; `Isolate is paused at start.` and
# `Attempting to resume isolate` are the `kPauseStart` branch of
# flutter_driver's vmservice_driver.dart, which `flutter drive` guarantees by
# defaulting `--start-paused` to true — nothing in drive mode resumes the root
# isolate, so another branch would mean a foreign debugger),
# the driver's own closing verdict, and
# `Leaving the application running.` — this lane passes `--keep-app-running`,
# which is load-bearing here (see the drive below), so its skeleton is the
# nine-line one rather than the eight a lane that lets the drive stop the app
# prints. That is 9 in each of the four transcripts above, and the --self-test
# reds if this floor ever exceeds the skeleton.
#
# relay=7. The policy's 1 is sized for the hermetic host relay, which prints a
# single listen line; this lane's relay is strfry, started from the same
# digest-pinned image and the same checked-in strfry.conf as every other
# Android lane (start-strfry.sh), whose `docker logs` dump OPENS with a fixed
# 9-line startup block — arguments, current dir, verbosity, the rule, the two
# CONFIG lines, the ephemeral-events WARN, `Started websocket server` — and
# grows only with traffic. Measured on THIS lane's own dumps: 44/45/48/49 lines
# across the four green runs above, the first 9 identical in all four, the 10th
# the first connection-dependent line. 7 sits under the block every LIVE
# container prints, while one torn down before the dump yields ONE line of
# docker error text — which a floor of 1 certifies clean. So this floor tells
# those two apart without depending on how much traffic the run happened to
# generate.
#
# Sealed ONCE, before the first gate: every later gate reuses the manifest at
# the out path, so without this the post-drive gate would seal this lane's
# manifest with the policy defaults instead.
readonly -a SEAL_EXTRA=(--host-decl "coordinate=${GEO_LAT},${GEO_LON}" --floor drive=9 --floor relay=7)
seal_rc=0
logscan_seal host /tmp/haven-soak/needles "${SEAL_EXTRA[@]}" || seal_rc=$?
if (( seal_rc != 0 )); then
  echo "ERROR: could not seal this lane's needle manifest (rc ${seal_rc}) — see the" \
       "line(s) above; every gate would fail the same way, so nothing this run" \
       "captures can be proven clean." >&2
  exit 1
fi

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
  # Which providers the platform has and which are mocked — never the position
  # (Security Rule 15; the point is synthetic, and still a needle). The AVD
  # runs a `google_apis` image where geolocator resolves to the FUSED provider,
  # the one step 8 arms, so after it this should list `fused provider [mock]`.
  echo "---- emulator location providers ----" >&2
  adb -s "${DEVICE}" shell dumpsys location 2>/dev/null | location_provider_names >&2 \
    || echo "(dumpsys location unavailable)" >&2
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
# prior target survives into this run (see run-single-avd-scenario.sh Phase 2),
# and flush the fresh install's broadcasts before anything launches the app.
#
# That is not Phase 4's broadcast barrier, and neither covers the other. Phase
# 4's runs after `flutter drive` has launched the app, for the drive's OWN
# force-stop and replace broadcasts, which reset LocationManagerService's
# registrations; the replace is a no-op to the overlay manager. This one keeps
# the fresh install's PACKAGE_ADDED from reaching the overlay manager while
# MainActivity is on screen, which would relaunch it under the driver
# (app-install-lib.sh) — and by the time Phase 4's barrier runs, MainActivity is
# already up. Draining the queue here only shortens Phase 4's wait.
# ---------------------------------------------------------------------------
echo "Phase 1/5 — installing ${APK}..."
[[ -f "${APK}" ]] || fail "APK not found: ${APK} (was the build step skipped?)"
install_fresh "${DEVICE}" "${APK}" \
  || fail "the fresh install of ${APK} did not complete (see the ERROR above)."

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
# Phase 3 — give the emulator a position to report.
#
# The FGS isolate uses the REAL GeolocatorLocationService (overrides injected in
# the drive isolate do not reach it), so something has to be on the other end of
# its registration.
#
# What `adb emu geo fix` does is SET the emulated position; the emulator then
# streams it to the guest's GNSS HAL as NMEA once a second for as long as the
# platform runs GNSS, whether or not the injection is repeated. Run
# 34642726338's capture is the evidence both ways: the HAL logged
# `Gnss:onGnssLocationCb` once a second inside every GNSS session, including the
# sessions five minutes after the re-issue loop below had been killed, and the
# first session drained a backlog of ~239 buffered sentences — one per second
# since the seed. The loop is therefore belt-and-braces and NOTHING in this lane
# may rest on stopping it; step 8 takes the platform's ability to answer away at
# the provider instead (`arm_no_fix`), and it deliberately leaves this loop
# running while it does, so a no-fix window can never be an artefact of a feed
# that stopped.
#
# NOTE the argument order: `geo fix` takes LONGITUDE first, then LATITUDE.
# ---------------------------------------------------------------------------
echo "Phase 3/5 — seeding emulator GPS (geo fix injected)..."
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
# Taking the platform's ability to answer away is the whole experiment, and it
# happens BEFORE the device is dozed — `DeviceIdleController` asks for a
# location on its way into IDLE (its STATE_LOCATING step), and a real fix landing
# in the fused provider's last-location slot at that moment is one a later
# registration could still be handed as a historical re-delivery. With the test
# provider already in place that request goes to the mock, like every other.
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
  echo "Phase 4/5 — no-fix phase: replacing the platform's ${NO_FIX_PROVIDER} \
provider with a silent test provider..."
  no_fix_state="$(arm_no_fix)" || no_fix_state="arm-failed"
  echo "Phase 4/5 — no-fix state: ${no_fix_state}"
  adb -s "${DEVICE}" shell \
    "log -p i -t ${SAMPLE_TAG} '${MARK_NO_FIX_ARMED}${no_fix_state}'" \
    >/dev/null 2>&1 || true
  echo "Phase 4/5 — forced-idle phase: dozing the device..."
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
( cd "${HAVEN_DIR}" && timeout --kill-after="${DRIVE_KILL_AFTER_SECS}s" "${DRIVE_TIMEOUT}" flutter drive \
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
# Scan BEFORE echoing. The EXIT trap's scan runs far too late to protect the
# STEP log, which has no retention control and cannot be redacted after the
# fact — a wider, more permanent sink than the artifact upload. The gate is
# the key-material floor AND the identifier scanner, sealed from the host
# needles plus this lane's own seal claim (SEAL_EXTRA: the point it injected
# and its drive floor). The pre-seal above already wrote the manifest, so these
# extras are the same array that produced it rather than a second, drifting
# copy. A leak deletes both captures.
logscan_gate host /tmp/haven-soak/needles "${SEAL_EXTRA[@]}" -- \
  --sink "logcat=${LOGCAT_FILE}" --sink "drive=${DRIVE_LOG}" \
  --report "${LOGSCAN_REPORTS}/gate.ndjson" || LOGSCAN_GATE_RC=$?
drive_log_clean=$(( LOGSCAN_GATE_RC == 0 ))
if (( drive_log_clean == 1 )); then
  cat "${DRIVE_LOG}" || true
else
  echo "drive log withheld from the step log — log-privacy gate rc ${LOGSCAN_GATE_RC}." >&2
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

# (3) Delivery, windowed to the acquire→hold-complete span and PARSED (never
#     grepped — `Published to 0/1` is P0-1's own signature and contains the
#     marker). The window OPENS at the FGS's own `session acquired` line after
#     the pause — post-handoff by construction, where the drive's
#     `HANDOFF_CONFIRMED` is a poll that can trail the FGS's first publish (see
#     `proof_window_opener`) — because a publish emitted while the UI still held
#     the session is a Rule-14 single-writer violation, not a success; it CLOSES
#     at the hold because everything after is teardown, where the service is
#     stopped on purpose.
WINDOW="${LOG_DIR}/post-pause.window.log"
window_between_markers "${LOGCAT_FILE}" "$(proof_window_opener "${LOGCAT_FILE}")" \
  "${MARK_HOLD_DONE}" > "${WINDOW}"
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
(highest bucket observed: ${published}). The isolate is alive but delivering nothing."
fi
echo "  [3/8] FGS published to a non-zero bucket of circles after the handoff (bucket leading number ${published})."

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

if ! oracle_out="$(assert_cadence_oracle "${WINDOW}" "${LOGCAT_FILE}")"; then
  echo "${oracle_out}" >&2
  fail "the background publish cadence does not match the P2a contract (above).\
${window_note}"
fi
echo "${oracle_out}"
echo "  [7/8] Publishes are delivery-driven and spaced at least \
${MIN_DELIVERY_GAP_SECS} s apart from the registration that produced them."

# (8) The no-fix chain, in the SECOND hold: the platform's `fused` provider is a
#     test provider nothing gives a location to and the device is in deep idle,
#     so the delivery-driven path this lane just proved has nothing to run on.
#     Publishing must continue anyway, from the watchdog and the last known
#     position. The oracle's own failures distinguish "the premise did not hold"
#     from "publishing stopped" — they are opposite findings, and only the
#     second is about the product.
if ! oracle_out="$(assert_no_fix_chain_oracle "${LOGCAT_FILE}")"; then
  echo "${oracle_out}" >&2
  fail "the no-fix chain under deep idle was not proven (above)."
fi
echo "${oracle_out}"
echo "  [8/8] Publishing survived deep idle with the platform unable to answer: \
a '${MARK_TRIGGER_WATCHDOG}' cycle published from the last known position."

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
