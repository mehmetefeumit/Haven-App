#!/usr/bin/env bash
#
# iOS background-publish lane — a REAL OS-level background transition.
#
# Runs ONE drive target (haven/integration_test/ios_bg_publish_test.dart) on a
# booted simulator and, MID-DRIVE, backgrounds the app for real by launching
# another app (com.apple.Preferences) over it — so iOS itself fires
# `applicationDidEnterBackground` and the Flutter engine dispatches the paused
# lifecycle state through the same channel a production backgrounding uses.
# No other lane does this: B7 and the Android B1 lane dispatch the lifecycle
# event IN-PROCESS, which runs the app's own paused branch but never the OS's
# side of the transition or the native session handler's survival across it.
#
# # The leg matrix: two axes, three legs
#
# The lane runs as a MATRIX and this invocation is one leg of it. Two inputs say
# which, and BOTH are mandatory here for the same reason: each is compiled into
# the artifact as well as acted on, so an unstated one would not be neutral — it
# would be another leg wearing this leg's name.
#
# HAVEN_BGP_AUTH_TIER — the CoreLocation grant:
#
#   when-in-use  `simctl privacy grant location`         -> whenInUse
#   always       `simctl privacy grant location-always`  -> always
#
# The value decides TWO things from one source: which service is granted here,
# and which shape the drive PINS (threaded on as
# --dart-define=HAVEN_BGP_EXPECT_TIER). That single source is the point. The
# drive must not branch on the tier it observes, because
# `requestAlwaysAuthorization()` reports `.authorizedAlways` while the second
# prompt is unanswered — a simulator that escalated the When-In-Use grant would
# then quietly run the Always shape and pass. Pinned, the escalation is a red,
# attributable run.
#
# HAVEN_LIVE_SYNC — the RECEIVE PLANE the app is built with, and therefore which
# receive phase the drive runs (P2c, the burst, or P2d, the 90 s catch-up
# timer). It is one `--dart-define` and one compile-time `liveSyncEnabled`
# const, so the plane and the phase can never disagree inside the app; what CAN
# disagree is that define and what this script demands of the log, which is what
# the completion gate's symmetry below exists to catch.
#
# Three legs, not four: (when-in-use, true), (always, true), (when-in-use,
# false). There is no (always, false) leg, and its absence is a decision rather
# than an omission — the poll leg exists to cover the POLL RECEIVE PATH under a
# real backgrounding, which has nothing to do with the authorization tier, and
# an Always poll leg would buy one more ~62-minute macOS job for a second
# reading of a tier policy the live-sync Always leg already proves.
#
# # What the drive proves (each phase leaves a terminal proof marker)
#
#   P1  After enabling background sharing through the production
#       `BackgroundSharingNotifier.setEnabled` path, CoreLocation reports the
#       PINNED tier, the native `HavenBackgroundSessionHandler` reports
#       supported==true (iOS 17+ runtime) and holds the session objects that
#       tier calls for, AND the position stream that flip REBUILDS — the one
#       carrying `allowsBackgroundLocationUpdates: true` — delivers a fresh
#       fix while the app is still foregrounded, with the native `status()`
#       read back to confirm it is running, background-capable, at the Best
#       profile and not yet backgrounded. iOS only lets a background-capable
#       location session start while the app is in use, so that is the only
#       moment it can be proven.
#
#       The session posture is INVERTED between the two jobs, which is the
#       tier->policy mapping the whole phase rests on: under When-In-Use a
#       CLBackgroundActivitySession is held and the indicator is asked for
#       (mandatory there, and the object whose absence produced the 2026-08-20
#       field failure); under a CONFIRMED Always — confirmed by a
#       CLServiceSessionDiagnostic, read through a bounded poll because the
#       verdict lands after arm() returns — the .always CLServiceSession is
#       held, the activity session is released and no indicator is asked for.
#       Only the Always job prints ALWAYS_SESSION_OK, and only its completion
#       gate requires it.
#   P2a With the app OS-backgrounded, a per-circle publish tick driven
#       through the production scheduler reaches the relay — the pipeline
#       works from a backgrounded process, answerable within seconds.
#   P2b With the app OS-backgrounded, the scheduler's OWN jittered timers
#       keep publishing: >= 2 further events, over a window sized to two
#       full 72-168 s jitter intervals. P2a passing and P2b failing means
#       the OS stopped scheduling the process, not that publishing broke.
#
#       P2b also polls the native session for the 100 m accuracy profile,
#       bounded to kStationaryDwell + kStationaryConfirmMaxAge (204 s) from
#       the backgrounding instant, and asserts it BEFORE the count. That poll
#       is the only CI-checkable part of the phase's power claim: it reads the
#       live `manager.desiredAccuracy`, so it says the coarse tier was really
#       requested of CoreLocation rather than written to a Dart field, and the
#       count beside it says publishing continued while it was. A single read
#       would be a coin flip — with nothing delivered under the coarse tier
#       the confirm deadline escalates back to Best every 84 s, so the coarse
#       profile is a window, not a steady state. The bound is what makes the
#       poll span one whole such window; see the drive target's library doc for
#       the one outcome that retires this oracle (a simulator that never runs
#       at 100 m at all -> move it to the host-side controller proof), and for
#       why the answer is never a longer window.
#   P2c With the app OS-backgrounded, a burst RECEIVES — the LIVE-SYNC legs'
#       receive phase. A live peer publishes a kind-445 to the circle, and the
#       burst driven afterwards decrypts it into the app's member-location
#       cache — coordinates compared, because a cache ROW proves a row was
#       written where the coordinates prove the ciphertext was peeled. Then,
#       with that burst over, the engine's relay pool must hold NO subscription
#       at all.
#
#       This is where the lane started compiling the receive engine IN
#       (HAVEN_LIVE_SYNC=true): since P4 the iOS background pause branch runs
#       every publish tick as a burst — open, ingest, publish, settle, pause —
#       so the receive engine is not a separate axis, it is the other half of
#       the mechanism P2a/P2b measure. Compiled out, every burst's open fails
#       and the lane measures a degenerate one.
#
#       The oracle is the engine's COUNT of registered subscriptions, never
#       `isPaused`: the core raises that flag as the first statement of its
#       pause, before it drops a single REQ, so it reads "paused" for every
#       state this phase exists to catch. Its control arm is a foreground read
#       of the same counter (non-zero, taken before the backgrounding) — zero
#       is the value the promise is KEPT by, so a counter that could only ever
#       read zero would prove it for free.
#
#       What P2c does NOT prove: that no SOCKET is open between bursts. There
#       is no in-process oracle for that, and this lane's relay journals no
#       REQ/CLOSE frames, so there is no relay-side one either; the socket
#       half is pinned in-process in Rust (live_sync_burst_e2e.rs, on relay
#       health). Read a green here as "no standing REQ", nothing wider.
#   P2d With the app OS-backgrounded, the POLL path's background CATCH-UP runs
#       — the flag-off leg's receive phase, and the reason that leg exists
#       (OD4-d). The rollback configuration receives through
#       `MapShell._startIosBackgroundReceiveTimer`'s `Timer.periodic(90 s)`,
#       whose tick reaches `CatchupService.runCatchup(isBackgroundWake: true)`;
#       that method returns immediately in a live-sync build, so P2c's plane and
#       this one are mutually exclusive by construction.
#
#       The same peer publishes the same sentinel fix, and this phase drives
#       NOTHING afterwards: the timer is the subject, so calling anything would
#       replace it. The oracle is the sweep's own side effect — Rust's
#       `persist_locations` upserts a last-known-location row per decrypted
#       location message — read back through
#       `snapshotLastKnownForCircle`, coordinates compared, against a BASELINE
#       taken before the peer published. Nothing else on this leg can write that
#       row: the publish tick's burst open fails with no engine (the drive
#       asserts that read THROWS while still foregrounded), the foreground
#       fetch timer was cancelled at the pause, and no provider recomputes with
#       frames off.
#
#       What P2d does NOT prove: anything about the burst plane, which this
#       build does not have; and not the C3 chokepoint that must refuse a wake
#       after consent is withdrawn — host tests own that.
#   P3  Flipping background sharing OFF while STILL backgrounded deactivates
#       the per-circle scheduler in-process and stops publishing on the wire
#       (an event-id DIFF over a bounded settle window — never a bare count),
#       and the native session reports disarmed.
#
#       It is proved TWICE over, from both sides of the app, because the app
#       may not survive its own window: the drive's diff from inside, and this
#       script's count from the relay. See "P3 when iOS takes the app" below
#       for why the second one exists and what each verdict then means.
#
# # P3 when iOS takes the app
#
# The disable is exactly what removes the app's claim to execute in the
# background, so from that instant iOS owns the process — and twice it has
# taken it mid-window. CI run 35622556197's sim-lifecycle.log names the
# mechanism end to end: the app dropped every CoreLocation claim 0.2 s after
# the disable, `runningboardd` invalidated the assertion locationd held on it
# one second later, the shared `FinishTask` grace that replaced it expired
# ~30 s on, and RunningBoard terminated the process for not invalidating it
# (OS_REASON_RUNNINGBOARD 0x2182bad2 — no jetsam, no crash report, no
# watchdog; the assertion nobody ended is the DEBUG Flutter engine's own
# "Flutter debug task", which UIKit warns about in every run of this lane).
# A healthy product therefore REACHES that outcome — it is the privacy-best
# outcome — and it used to end the lane on "P3 was neither proved nor
# disproved", an indeterminate result reported as a failure.
#
# So the wire half moved to a witness the OS cannot reclaim. On EVERY path,
# once the window has elapsed, this script asks the relay whether any kind-445
# was created inside it (`bgp-wire-probe.dart`). The count is the whole answer
# because the drive disposes the synthetic peer BEFORE P3, so nothing else on
# that relay can author one — a premise check 19 of
# scripts/ci/check_ios_background_publish.sh pins, since the host cannot tell
# two authors apart (ephemeral per-message keys, one shared `h` tag). And when
# the app is gone the probe is also the only oracle that would see a
# background RELAUNCH publishing, which is the defect P3 exists to catch.
#
# A reclaimed run then ends on exactly one of four PROVEN verdicts
# (`bgp_p3_host_verdict`), never on a default:
#
#   holds       silent for the whole window, the process stayed gone, and the
#               DISABLED marker is there — which the drive appends only after
#               asserting the provider false and the scheduler torn down. The
#               NATIVE half comes free: an app still holding a location
#               keep-alive is an app iOS keeps executing (P2a/P2b measure that
#               for 400+ s every run), so a process RunningBoard took for an
#               expired background assertion had already released it. A
#               simulator has no jetsam, so there is no other way to lose it.
#               What this does NOT prove is that the release was PROMPT; the
#               drive's own disarm poll owns that, and the other legs run it.
#   leak        a kind-445 inside the window. P3 broken, lane red.
#   relaunched  the app was RUNNING again at the window's end although this
#               script never launched it. Red.
#   unproven    the wire could not be read, the read had no control, the
#               liveness probe was never calibrated, or the disable was never
#               signalled. Red, naming the harness rather than the product.
#
# Only `holds` excuses anything, and only the two markers a dead process could
# not print (NEGATIVE_SILENCE_OK, SESSION_DISARMED). Every other terminal
# proof is still demanded, so a drive that stopped in an EARLIER phase cannot
# buy a green off P3's verdict.
#
# # The host<->test handshake
#
#   1. Once P1 passed, the drive writes `[bg-publish] READY_FOR_BACKGROUND`
#      into a file in its OWN sandbox tmp/ (and prints the same marker for a
#      human reading the log). The FILE is the signal, because the log is not
#      a stream this script may depend on: in run 32553078705 the whole
#      119-line drive log landed in one second, nine minutes after it was
#      produced. The cause was the `github` test reporter, which buffers a
#      test's entire output and flushes it as a `::group::` only when that test
#      ENDS (run-ios-sim-scenario.sh now pins `--reporter expanded` so the
#      watchdog is not fooled by the same silence). A handshake that read the
#      log would have to be re-proven against every future reporter and flush
#      decision; a file the drive writes itself has neither dependency. Tailing
#      the log can also only ever background the app AFTER the drive's own
#      paused-wait has expired if anything ever buffers again,
#      which is why this lane could not pass.
#   2. This script deletes that file, then polls the app data container for it
#      in a bounded loop, then backgrounds the app:
#          xcrun simctl terminate <udid> com.apple.Preferences || true
#          xcrun simctl launch    <udid> com.apple.Preferences
#      The drive keeps running only because the APP has a background-execution
#      claim: `UIBackgroundModes: location` plus the live updates session on
#      HavenLocationStreamHandler's own CLLocationManager, started with the
#      `allowsBackgroundLocationUpdates` argument its `onListen` receives (the
#      background-sharing toggle, verbatim). The simulator suspends a
#      backgrounded app that lacks one, and did so in both prior runs of this
#      lane: 32646436116 (~30 s in, the drive had faked its location service
#      away) and 32661622879 (~36 s in — that run's sim.logarchive shows the
#      background-capable subscription starting 0.43 s AFTER SpringBoard set
#      `visiblity is no`, locationd answering `#Warning Denying process
#      assertion`, and runningboardd `Suspending task` once the app's own
#      FinishTask grace expired). The drive now establishes that session
#      before signalling READY, and P1 fails if it did not. A suspended
#      drive's `flutter test` isolate stops executing until the app is
#      re-foregrounded.
#   3. The drive bounded-polls its own lifecycle state for the REAL paused
#      transition; its failure message names this script's background step,
#      so a broken handshake is attributed from both sides.
#   4. When the drive disables background sharing it appends
#      `[bg-publish] BACKGROUND_SHARING_DISABLED`. That is the instant the
#      app loses its right to run in the background, so this script times
#      P3's settle window from there — from the APPEND's mtime, not from the
#      poll that read it — and re-foregrounds Haven itself once it has
#      elapsed: a suspended drive cannot re-fetch the relay, and the re-fetch
#      has to happen before the window's own kind-445s age past their 228 s
#      NIP-40 expiration (see DISARM_WAIT_SECS).
#   5. After the drive's LAST marker (`[bg-publish] SESSION_DISARMED`) this
#      script re-foregrounds Haven (`simctl launch` on the running bundle
#      activates it) so flutter_test's post-suite teardown gets real engine
#      frames again — an in-process resumed dispatch cannot restart the
#      native animator iOS paused on the way out.
#   6. Then, on every path, it asks the RELAY what happened inside P3's
#      window. After the re-foreground deliberately: a foregrounded Haven
#      publishes by design and those events are created past the window, so
#      the probe's seconds come out of nobody's margin, while spending them
#      first would come straight out of the drive's own race with the 228 s
#      kind-445 expiration.
#
# # The completion gate (A3b)
#
# `flutter test` reports success over a body that was skipped or returned
# early, and the READY marker is printed BEFORE P2/P3 run — so a drive that
# exited 0 is not a drive that proved anything. This script therefore requires
# an EXACT set of terminal proofs in the preserved log, each printed only after
# the last assertion of its own phase. Four are shared by every leg:
#
#   [bg-publish] SESSION_ARMED
#   [bg-publish] BACKGROUND_PUBLISH_OK …   (prefix match; ` count=<n>` suffix)
#   [bg-publish] NEGATIVE_SILENCE_OK
#   [bg-publish] SESSION_DISARMED
#
# and each axis adds exactly one more, DEMANDED on its own leg and REFUSED on
# the others:
#
#   [bg-publish] BACKGROUND_RECEIVE_OK   HAVEN_LIVE_SYNC=true  (P2c, the burst)
#   [bg-publish] BACKGROUND_CATCHUP_OK   HAVEN_LIVE_SYNC=false (P2d, the timer)
#   [bg-publish] ALWAYS_SESSION_OK       the always tier
#
# So the poll leg's gate is not "one fewer proof". It is five proofs, one of
# which is a DIFFERENT fifth — and a log carrying the live-sync five is refused
# there, exactly as a When-In-Use log carrying ALWAYS_SESSION_OK is. Each of the
# three is reachable only from one compiled branch, so the wrong one in a log
# means the value this script acted on and the value the drive was BUILT with
# came apart, and the job is measuring another leg's subject under this leg's
# name. The Always leg's own proof carries the same argument on the tier axis:
# that leg exists for one shape — service session held, diagnostic confirmed, NO
# activity session — and without its own proof it could exit 0 over a body that
# never reached those assertions while the shared four made it look complete.
#
# # Scope boundary (stated so nobody over-reads a green)
#
# A simulator has no jetsam, no Significant-Location-Change relaunch and no
# BGTaskScheduler, so a background-execution bug only those surface cannot
# show up here. This lane proves that the production background stack — plist
# mode, AppleSettings, the native session handler, the Dart publish pipeline and
# whichever receive plane the leg was built with — survives a genuinely fired
# UIApplication background transition and keeps kind-445 events flowing both
# ways. The physical-device checklist (docs/M7_BACKGROUND_SHARING.md §6,
# item 0) remains the final proof.
#
# It is also the ONLY place in the repo that produces a real OS backgrounding on
# iOS: `OVERLAY_BUNDLE_ID` / com.apple.Preferences appear in no other workflow
# or harness, and e2e-ios runs both of its variants FOREGROUNDED. That is why
# the poll leg has to live here rather than beside it (OD4-d), and why deleting
# a leg from this lane deletes a configuration's only real-backgrounding
# coverage rather than a duplicate of another lane's.
#
# One boundary is not yet settled, and P2a/P2b exist to settle it. Apple
# documents "the UIBackgroundModes key" as one of the features "not available
# in Simulator" ("Testing in Simulator versus testing on hardware devices"),
# and DTS advises against testing background execution there at all — while
# run 32661622879's own sim.logarchive shows this simulator's locationd
# creating a CLBackgroundActivitySession, holding a RunningBoard "Location
# subscription" assertion for the app and delivering fixes on a 10 s cadence
# throughout. Both prior failures are explained by the app's late session,
# which is now fixed. If P2a passes and P2b still reports a suspension, the
# policy is genuinely absent here and the continuity claim must move out of
# CI to §6 item 0 — an OWNER decision, never a widened window.
#
# # Why the app is installed and granted BEFORE the drive
#
# Same reasoning as run-b4-ios-real-gps.sh: a `simctl privacy` grant resolves
# the bundle id against INSTALLED apps and does not survive `simctl
# uninstall`, which the shared runner performs on entry. So this script
# builds once, uninstalls, installs, grants the tier's service (see "The leg
# matrix"), seeds a `simctl location` fix, and asks the shared runner to skip
# its own uninstall via HAVEN_E2E_IOS_SKIP_UNINSTALL=1. Both are
# load-bearing, not hygiene: the drive overrides NOTHING about location (B4's
# stance, not B7's), because the production CLLocationManager session is the
# app's only claim to execute while backgrounded. Without the grant the app
# sits on an unanswerable prompt; without the fix locationd has nothing to
# deliver.
#
# Everything else — the first-test watchdog, the narrowed retry gate, the
# log-privacy gate — is inherited by delegating the drive to
# `run-ios-sim-scenario.sh` rather than reimplementing `flutter test` here.
#
# Usage:
#   run-ios-bg-publish.sh <simulator-udid>
#   run-ios-bg-publish.sh --self-test     # hermetic; no simulator, no Xcode
#
# Environment:
#   HAVEN_E2E_RELAY   WebSocket URL of the host relay (default
#                     ws://localhost:7777).
#   HAVEN_LIVE_SYNC   'true' or 'false'. MANDATORY — declared per STEP by the
#                     caller, exactly as run-ios-sim-scenario.sh requires
#                     (S1 / CI_HARDENING_BACKLOG.md A7). It selects the receive
#                     PLANE the app is compiled with, so it also selects which
#                     receive phase the drive runs and which of the two plane
#                     proofs this script demands and refuses.
#   HAVEN_BGP_AUTH_TIER  'when-in-use' or 'always'. MANDATORY, and for the same
#                     reason HAVEN_LIVE_SYNC is: it selects the grant AND the
#                     shape the drive pins, so a default would let the matrix
#                     lose a leg silently — both jobs would run the
#                     When-In-Use assertions and the Always job would report
#                     success for a posture it never exercised.
#   HAVEN_BGP_DISABLE_WAIT_SECS / _DISABLE_WAIT_POLL_SECS  the per-leg DISABLE
#                     deadlines (1440 / 1310), each derived from its own leg's
#                     phase sum. Overriding either is a debugging affordance,
#                     never a fix: see the derivation above for both bounds.
#   HAVEN_LOGSCAN / HAVEN_LOGSCAN_PROFILE  the post-drive log-privacy gate's
#                     arm and seal profile, declared per JOB and inherited by
#                     the delegate; an unset profile is inferred from the
#                     recorder's exports exactly as run-ios-sim-scenario.sh
#                     infers it (proxy under WIRE_UPSTREAM or
#                     HAVEN_WIRE_SENTINEL, else host), never defaulted.
#
# Side effects:
#   - Writes /tmp/bg-publish-ios.log (uploaded as a CI failure artifact).
#   - Writes /tmp/ios-logscan/bg-publish.ndjson (the scanner's findings
#     report; never uploaded).
#   - Leaves the app UNINSTALLED from the simulator on completion.
#
# Exit status:
#   0  the session armed, publishes continued across a real backgrounding, this
#      leg's receive plane carried a peer's location into the app (a burst that
#      left no standing REQ, or a background catch-up sweep), and the disable
#      stopped both — every proof this leg owes, and none it must not produce
#   1  the drive failed, or it exited 0 without this leg's full proof set, or it
#      printed a proof only another leg can reach, or a kind-445 reached the
#      relay inside P3's settle window, or that window could not be read at all
#   2  usage / harness misconfiguration (including: this Xcode cannot grant
#      location privacy or seed a simulated location, or there is no `dart` to
#      run P3's wire oracle with, or that oracle fails its own self-test here)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
# The log-privacy gate: the key-material floor AND the identifier scanner, one
# call, one verdict (Security Rules 6 and 15).
# shellcheck source=tooling/e2e/ci/logscan-gate.sh
source "${SCRIPT_DIR}/logscan-gate.sh"

# The drive target, relative to haven/ (the shared runner resolves it there).
readonly SCENARIO_FILE="integration_test/ios_bg_publish_test.dart"

# Must match `haven/ios/Runner.xcodeproj`'s PRODUCT_BUNDLE_IDENTIFIER and the
# id run-ios-sim-scenario.sh uninstalls.
readonly BUNDLE_ID="com.oblivioustech.haven"

# The app launched OVER Haven to force the real background transition.
# Preferences ships on every simulator runtime, so launching it can never
# fail for a missing bundle.
readonly OVERLAY_BUNDLE_ID="com.apple.Preferences"

# Markers the drive target prints. Duplicated here (and ONLY here) because
# the Dart consts are not readable from bash; the drive target's doc comment
# names this file as the other half of the contract, and the --self-test
# below feeds the real parser fixtures built from these literals, so a drift
# shows up as a failing self-test rather than as a silently unparseable log.
#
# READY_MARKER and DISABLED_MARKER feed the HANDSHAKE only and are printed
# before the assertions that follow them, so neither can stand in for a
# completion proof. The other seven are the terminal proofs: each is printed
# only after the last assertion of its own phase. PUBLISH_MARKER is matched as
# a PREFIX (the drive appends ` count=<n>`). Three are LEG-SPECIFIC and the
# gate is symmetric about each: ALWAYS_MARKER is required by the Always leg and
# REFUSED elsewhere; RECEIVE_MARKER (the burst) is required by the live-sync
# legs and refused on the poll one; CATCHUP_MARKER (the 90 s receive timer) is
# required by the poll leg and refused on the others — see the completion gate.
readonly READY_MARKER='[bg-publish] READY_FOR_BACKGROUND'
readonly DISABLED_MARKER='[bg-publish] BACKGROUND_SHARING_DISABLED'
readonly ARMED_MARKER='[bg-publish] SESSION_ARMED'
readonly PUBLISH_MARKER='[bg-publish] BACKGROUND_PUBLISH_OK'
readonly RECEIVE_MARKER='[bg-publish] BACKGROUND_RECEIVE_OK'
readonly CATCHUP_MARKER='[bg-publish] BACKGROUND_CATCHUP_OK'
readonly SILENCE_MARKER='[bg-publish] NEGATIVE_SILENCE_OK'
readonly DISARMED_MARKER='[bg-publish] SESSION_DISARMED'
readonly ALWAYS_MARKER='[bg-publish] ALWAYS_SESSION_OK'

# P3's settle window and its in-flight grace, DUPLICATED from the drive
# target's `_negativeSettleWindow` (`kLocationPublishMaxInterval` 168 s + 32 s)
# and `_inFlightGraceSecs` for the same reason the markers are: the Dart
# consts are not readable from bash. The host's own wire verdict has to
# measure the SAME window the drive measures — a host window that started
# earlier would count the app's in-flight tick as a leak, and one that ended
# later would count the post-window foreground publish the host itself
# provokes. Check 19 of scripts/ci/check_ios_background_publish.sh pins both
# numbers against the Dart sources, so a drift is a red rather than a quiet
# disagreement between two oracles.
readonly SETTLE_WINDOW_SECS=200
readonly LEAK_GRACE_SECS=10

# The host-side wire oracle for that window (see "P3 when iOS takes the app").
# Standalone Dart: `dart <file>` needs no package resolution, the same shape
# check-wire-canaries.dart has and the same way CI already runs it.
readonly WIRE_PROBE="${SCRIPT_DIR}/bgp-wire-probe.dart"

# The shared runner's fixed log path (run-ios-sim-scenario.sh's LOG_FILE).
# Read ONLY after the drive exits — for the completion gate and the artifact —
# never for the live handshake: what reaches it, and when, is the test
# reporter's decision rather than this script's, so it is treated as a
# post-mortem and not as a stream.
readonly SHARED_LOG="/tmp/flutter-ios-test.log"

# The handshake signal. The drive APPENDS the two markers this script must act
# on while the drive is still running (READY_MARKER, then DISARMED_MARKER) to a
# file of this name in its own sandbox tmp/ (`Directory.systemTemp` ==
# `<data container>/tmp`). A file write reaches the filesystem immediately, so
# unlike the log it is readable mid-run. Duplicated from the Dart const
# `kHandshakeSignalFileName` for the same reason the markers are — change both.
readonly SIGNAL_NAME='bg-publish-handshake'

# Where the run's log is preserved for the artifact upload.
readonly BG_LOG="/tmp/bg-publish-ios.log"

# This lane's `drive` line floor, sealed by the delegate and re-stated on the
# belt below. It is the HOST SKELETON an iOS `flutter test -d <udid>` transcript
# always carries whatever the scenario printed — run-ios-sim-scenario.sh's
# IOS_HOST_SKELETON_LINES, derived there — and NOT a fraction of a measured
# transcript, which is what 56 was (half of this drive's 112 lines on CI run
# 35280144455). The delegate refuses anything above it.
#
# One number serves both call sites although the belt's sink sums TWO copies of
# the same transcript: a floor is a minimum, so the single-capture bound holds
# for the pair too and is merely weaker there. What 56 used to catch — a drive
# that built and never launched — is the scanner's proof_of_run now, which
# stopped accepting the reporter's `loading <suite>` line as evidence a test
# ran; the policy default of 100 is the core-flow drive's and would read every
# green run of this lane as truncated.
readonly BGP_DRIVE_FLOOR=4

# Handshake bounds. READY must appear after the delegated `flutter test`'s
# incremental build (~2-4 min; the cold build happens in THIS script, before
# the drive) plus install/launch/attach plus the in-test setup and P1 —
# ~10 min worst case measured against B7's phases, so 20 min is ~2x. The
# ALWAYS job adds at most its 60 s confirmed-Always poll to P1, which the 2x
# absorbs; a poll that actually burns 60 s has failed its assertion anyway.
# The live-sync engine this lane now compiles in (see the header) starts
# during that same setup and adds seconds, not minutes.
#
# DISABLED starts at the backgrounding and is the sum of the drive phases
# between the two. Every term below names the constant that ENFORCES it; the
# two awaited ticks are the only ones whose pricing needs an argument.
#
#   AWAITED TICK = `kPublishLinkTimeout`, 180 s. P2a and P2c each `await`
#           `triggerTickForTest`, which returns the scheduler's FIFO
#           `_publishChain`, and `_dispatchTick` wraps every link in
#           `.timeout(kPublishLinkTimeout)`. The watchdog does not cancel the
#           burst — the burst runs on and still owns its settle, pause and
#           close — but it DOES complete the chain link, which is the future
#           the drive is holding, so it is the ceiling that binds here.
#           NOT `burstBound(1) + kOptOutBurstWait` (108 s), which is what this
#           budget used to say: `burstBound`'s own doc states that the
#           maintenance fold and the teardown sit outside it and that "no
#           bound on a whole burst exists", and `kOptOutBurstWait`'s states
#           that the Rule-13 drain behind its four lifecycle ops is
#           deliberately unpriced. Being unpriceable is a good argument for a
#           BOUND on a wait inside the app; it is not an argument for leaving
#           the term out of a CI wall clock, which has to elapse whether or
#           not anyone can price what is happening in it.
#
#   paused-transition poll (`_pausedTransitionWindow`)            <= 180 s
#   P2a  the PAUSE-driven publish, waited out before the anchor is
#        taken: `MapShell._onPaused` drives a burst synchronously
#        inside the lifecycle dispatch, before the drive's 250 ms
#        poll has even seen the pause, so an anchor at the transition
#        would let THAT burst satisfy P2a's collect and the tick this
#        phase drives would go unasserted. `burstBound(1)` 50 s +
#        `_relayObservationSlack` 15 s                             <=  65 s
#        + heartbeat drain (`_heartbeatInterval`)                  <=  20 s
#        + two `_anchorAfterCurrentSecond` spins                   <=   2 s
#   P2a  the awaited tick (`kPublishLinkTimeout`)                 <= 180 s
#        (its 133 s collect window — `kOptOutBurstWait` 68 +
#         `burstBound(1)` 50 + `_relayObservationSlack` 15 — runs
#         concurrently and is subsumed, and its heartbeat has drained
#         long before the tick returns)
#   P2b  collect window (`_postBackgroundPublishWindow` =
#        2 x `kLocationPublishMaxInterval` + 60 s)                    396 s
#        + heartbeat drain (`_heartbeatInterval`)                  <=  20 s
#        + one `_anchorAfterCurrentSecond` spin                    <=   1 s
#   P2c  the peer's publish. `publishAndAwaitOk` is wrapped in
#        `_reissuingAcrossReconnect`, which runs `_maxReconnectAttempts`
#        (3) re-issues PLUS a final attempt = 4, and each may spend
#        `_awaitWritable`'s `_reconnectBudget` (1 + sum over k<3 of
#        (2^k + 5) = 23 s) before its 5 s OK wait: 4 x 28            <= 112 s
#        + the awaited tick that must ingest it                     <= 180 s
#        + member-cache poll (`_peerFixWindow` 30 s + one
#          `_statusPollInterval`) + heartbeat drain                 <=  55 s
#        + between-bursts poll (`burstBound(1)` 50 s +
#          `kOptOutBurstWait` 68 s + one `_statusPollInterval`)
#          + heartbeat drain                                        <= 143 s
#          — a CEILING on how long the read may be retried, not a
#            window the phase spends: that poll runs
#            `decideOnFirstAnswer`, so it ends on the engine's first
#            ANSWER whatever the count is, and only a read that keeps
#            THROWING (no live session) can reach the deadline. A
#            healthy run spends ~0 here.
#   P3   baseline fetch (`_snapshotFetchWindow`)                       15 s
#                                                                  = 1369 s
#
# 1440 s clears that by ~5% on the LIVE-SYNC legs. (NOT the ~37% this comment
# once claimed: that
# figure priced both awaited ticks at 108 s, which is a price and not a bound,
# and the number was safe by an accident the reasoning did not contain. Nor
# the ~12% of the first re-derivation, which predates P2a's pause-burst wait.)
# The `_`-prefixed terms are the drive target's own constants and live in
# haven/integration_test/ios_bg_publish_test.dart; the rest are the app's and
# the e2e harness's. Re-derive from the sources, never from either file's
# current literals.
#
# 5% is thin, and it is deliberately not spent on a bigger number, because
# this deadline is bounded from ABOVE as well as below and the two bounds are
# ~100 s apart:
#
#   below — the 1369 s sum, so it never fires on a run the drive can finish;
#   above — the drive's own `Timeout(40 min)`. On the measured shape that
#           Timeout is spent ~515 s before the backgrounding (setup + P1) and
#           ~410 s after the disable (settle + snapshot + disarm poll +
#           teardown), leaving ~1475 s for THIS window. A deadline above that
#           is unreachable: the drive dies first, `bgp_wait_until` returns
#           "the drive exited" rather than a deadline, and its rc is collected
#           below — which is the better red anyway, because the drive's
#           Timeout names the failing test and this deadline names nothing.
#
# What the sum does NOT bound, said here because a 5% margin would otherwise
# be read as one: `_publishChain` is FIFO and has no enforced DEPTH, so each
# awaited tick is priced for ONE link, and a link already queued ahead of a
# trigger — this lane's single circle re-arms every 72-168 s against a 180 s
# per-link ceiling — costs another `kPublishLinkTimeout`. 1440 does not cover
# even the first (1549 s). That is not closable by arithmetic and it does not
# need to be: 1549 s is past the drive's own ~1475 s ceiling too, so such a
# run ends on the Timeout that names the test.
# Exceeding this deadline is in any case not a kill. The wrapper WARNs and
# falls through to the DISARM wait, so Haven is not re-foregrounded until
# DISABLE + DISARM = 1650 s — 210 s past this deadline and past the drive's
# own ceiling — and it is the RE-FOREGROUND that would corrupt P3 (it would
# then measure a foregrounded app, which keeps publishing on the foreground
# path, so the in-process half or the event-id diff reds the lane, one of them
# for the wrong stated reason). On the measured shape the drive is already
# gone by then. Undersizing this therefore costs attribution, never
# correctness — but it costs attribution on exactly the runs that most need
# it, which is why the terms above are bounds and not estimates.
# P2b's profile poll adds NOTHING to the sum: it runs while the collect above
# it is already running, is bounded by an ABSOLUTE deadline (backgrounding +
# 204 s) that falls inside the collect's own window, and is awaited before it.
#
# DISARM is NOT a "something went wrong" backstop — it is the timer that ends
# P3, and every second of it comes from a constant. From DISABLED the app has
# no right to run in the background, so iOS may suspend it and the wrapper
# owns the wake-up. It is bounded on both sides:
#   lower — it must exceed the drive's settle window (200 s =
#           kLocationPublishMaxInterval + 32 s), or the app this script
#           re-foregrounds publishes INSIDE the window the drive is
#           measuring and a correct app fails P3;
#   upper — the drive re-fetches the relay when it wakes, and the earliest
#           event that can count as a leak is created at the disable cutoff
#           plus the 10 s in-flight grace, so it stops being READABLE BY THE
#           APP at cutoff + 10 + 228 s (the kind-445 NIP-40 expiration) =
#           238 s. Not because the relay drops it — this one never does, see
#           `bgp_wait_until` — but because the app's own client does:
#           nostr-relay-pool 0.44 rejects an expired event on receipt
#           (`Error::EventExpired`, relay/inner.rs), before any Haven code
#           sees it. A later wake-up re-fetches silence whether or not the
#           disable worked.
# 200 + 10 = 210 s clears the window by the in-flight grace and leaves the
# re-fetch (210 + one <=5 s poll + the drive's own resume) ~20 s inside that
# bound. A run where the app was NOT suspended signals DISARMED first and
# never reaches the deadline.
#
# The HOST's wire probe is not bound by any of this: it reads the relay over a
# raw socket with no nostr client in the way, so it still sees what the relay
# kept. That is why its verdict survives a wake-up this budget could not save
# — and why it, not the drive's re-fetch, is what ends P3.
#
# Both of those bounds are WALL-CLOCK facts about the app and the relay, so
# the 210 s has to be measured the same way, from the same instant they are:
# the app's OWN disable append. It was neither. The wait counted its own
# sleeps and ignored what the poll's container sweep spent, and it started
# from the poll that NOTICED the marker rather than from the append — so the
# wake-up landed 216.8-222.0 s after the disable across five runs
# (35376588206, 35311161479, 35280144455 x2, 34798752509 — marker in the
# drive log to re-foreground line, so each is a LOWER bound on the app's own
# wait) instead of 210,
# leaving 16-21 s of the 238 s readability bound rather than 28, and shrinking
# under load, which is exactly when a runner is slowest to wake the app.
# `bgp_wait_until` therefore measures wall clock, and `bgp_budget_after_lag`
# takes the observation lag off the budget (bounded by
# DISARM_ANCHOR_MAX_LAG_SECS, and one-sided: it may never wake the app EARLY,
# which is the error that reds a correct app). Overshooting is not merely
# untidy — past that bound P3's re-fetch collects silence whichever
# way the disable went, and the wire half passes VACUOUSLY.
#
# What neither bound can do is keep the app ALIVE. From the disable it holds
# no execution claim — the guarantee under test — so iOS owns the process for
# the whole window, and in CI run 35397118356 it took it: 37 s after the
# disable the app's background-task assertions invalidated without UIKit ever
# running their expiration handlers, the process logged nothing again, and
# the host's VM-service connection closed 5 s later, and it happened again in
# run 35622556197. Shortening the exposure to the 210 s the proof actually
# needs is all a wrapper can do about the app's LIFE — but it no longer has to
# do anything about the PROOF: the wire half is now asked of the relay, which
# is not the app's to take with it, so the DISARM wait's exit branch holds the
# window open and finishes P3 from the host instead of reporting an
# indeterminate outcome as a failure ("P3 when iOS takes the app", above).
# The 210 s therefore cannot be shortened for a different reason than before:
# it is not exposure any more, it is the drive's own settle window plus the
# grace, and both oracles measure it.
#
# P2c does not move either side of that, and the re-derivation above is why it
# does not have to: P2c runs entirely BEFORE the disable, so it changes when
# the DISABLED signal arrives (which DISABLE_WAIT_SECS above absorbs) and
# nothing at all about the window that follows it. Both bounds are still the
# drive's own settle window and the 228 s kind-445 expiration, unchanged. The
# same is true of P2d on the poll leg.
#
# # …and the POLL leg's own DISABLE deadline
#
# The poll leg (HAVEN_LIVE_SYNC=false, OD4-d) runs P2d in P2c's place, and it
# is NOT the same price, so it does not inherit the same number. Copying 1440
# forward would put the deadline PAST that leg's drive Timeout, where it can
# never fire and buys nothing but a misleading ceiling in this comment. Every
# other term is unchanged, so only P2c/P2d differ:
#
#   P2d  the peer's publish, priced exactly as P2c's is (the same
#        `publishAndAwaitOk` inside `_reissuingAcrossReconnect`,
#        4 x 28 s)                                                <= 112 s
#        + the catch-up window (`_pollPathCatchupWindow` = two
#          90 s `_pollPathReceiveInterval` ticks + the sweep's own
#          20 s `maxDurationSecs` + `_relayObservationSlack` 15)      215 s
#        + the baseline store read (`_storeBaselineWindow`)            15 s
#        + heartbeat drain (`_heartbeatInterval`)                  <=  20 s
#                                                                  =  362 s
#
# There is no awaited-tick term at all: P2d drives NOTHING, because the timer
# is its subject. So the poll leg's sum is 1369 - 490 + 362 = 1241 s, and
# 1310 s clears it by ~5.6% — the same discipline as 1440/1369, against the
# same upper bound one leg down: that leg's drive `Timeout(37 min)` = 2220 s,
# spent ~425 s before the backgrounding (setup + a P1 with neither live-sync
# term) and ~410 s after the disable, leaves ~1385 s for this window. 1310 sits
# 75 s inside it.
readonly READY_WAIT_SECS="${HAVEN_BGP_READY_WAIT_SECS:-1200}"
# READY is a build-dominated envelope (~10 min worst case, doubled), so it is
# leg-independent: the poll leg's cheaper P1 only widens the same margin.
readonly DISABLE_WAIT_LIVE_SYNC_SECS="${HAVEN_BGP_DISABLE_WAIT_SECS:-1440}"
readonly DISABLE_WAIT_POLL_SECS="${HAVEN_BGP_DISABLE_WAIT_POLL_SECS:-1310}"
readonly DISARM_WAIT_SECS="${HAVEN_BGP_DISARM_WAIT_SECS:-210}"
readonly MARKER_POLL_SECS="${HAVEN_BGP_MARKER_POLL_SECS:-5}"

# The simulated-location drip: two fixes ~5 m apart (4.5e-5 deg of latitude),
# alternated every DRIP_SECS for the whole run.
#
# Two jobs, both load-bearing. (1) The drive's P1 requires a FRESH fix from
# the position stream the background-sharing flip rebuilds — that delivery is
# the proof the background-capable CLLocationManager session is live, and a
# `simctl location ... set` is a ONE-SHOT static fix, so without a moving
# drip the rebuilt session may have nothing new to deliver and P1 times out
# on a healthy app. (2) CoreLocation does not keep a backgrounded app
# executing when it has nothing to deliver to it — Apple states exactly that
# for the whole session family (WWDC24 "What's new in location
# authorization": "Core Location does not take measures to keep apps running
# continuously when it has nothing to deliver to them").
#
# The native updates session carries NO distance filter
# (`kCLDistanceFilterNone`, in BOTH accuracy profiles — the shape iOS 16.4
# requires of a continuously-delivering background app), so a step of any size
# is delivered and 5 m is not chosen against a filter threshold. It is chosen
# against the two distances that DO decide something. Because the points
# ALTERNATE rather than advance, total displacement never approaches
# `kMotionTriggerDistanceMeters` (100 m): the drip never becomes a second
# publish driver, so P2 keeps measuring the per-circle scheduler, and the
# stationary controller keeps CONFIRMING its anchor instead of escalating back
# to Best on a phantom move — which is what lets P2b's profile poll observe the
# 100 m tier at all. A drip that advanced would look like a walk, and the
# session would sit at Best for the whole window.
readonly DRIP_SECS="${HAVEN_BGP_DRIP_SECS:-10}"
readonly DRIP_POINT_A='47.606209,-122.332069'
readonly DRIP_POINT_B='47.606254,-122.332069'
if ! [[ "${READY_WAIT_SECS}" =~ ^[1-9][0-9]*$ ]] \
   || ! [[ "${DISABLE_WAIT_LIVE_SYNC_SECS}" =~ ^[1-9][0-9]*$ ]] \
   || ! [[ "${DISABLE_WAIT_POLL_SECS}" =~ ^[1-9][0-9]*$ ]] \
   || ! [[ "${DISARM_WAIT_SECS}" =~ ^[1-9][0-9]*$ ]] \
   || ! [[ "${MARKER_POLL_SECS}" =~ ^[1-9][0-9]*$ ]] \
   || ! [[ "${DRIP_SECS}" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: HAVEN_BGP_*_SECS overrides must be positive integers." >&2
  exit 2
fi

# How much of the DISARM budget may be reclaimed from the OBSERVATION lag —
# the stretch between the drive APPENDING the disable marker and this script's
# poll reading it. That lag is one poll plus the container sweep the poll runs:
# 0.2-3.5 s measured (CI runs 35376588206, 35311161479, 35280144455 x2,
# 34798752509), so two poll intervals is a ceiling, not a budget. Anything
# larger is not a lag but a stale signal or a moved clock, and
# `bgp_budget_after_lag` keeps the WHOLE budget rather than trust it — waking
# the app early is the error that cannot be recovered from (see there).
# Derived after the validation above, so a garbage override reports itself
# rather than becoming a 0 in an arithmetic expansion.
readonly DISARM_ANCHOR_MAX_LAG_SECS=$(( MARKER_POLL_SECS * 2 ))

# ---------------------------------------------------------------------------
# Pure helpers (exercised by --self-test)
# ---------------------------------------------------------------------------

# bgp_simctl_supports_location_privacy <usage-text> — does this Xcode's
# `simctl privacy` offer the `location` service?
#
# Returns 0 (supported), 1 (parsed, and it is NOT offered), or 2 (the usage
# text does not look like a service list at all — do not guess either way).
# Deliberately no `\b`: macOS BSD grep does not implement the GNU
# word-boundary escape, so a `\b` pattern would silently never match and
# every real run would report "unparseable" on a perfectly good Xcode.
bgp_simctl_supports_location_privacy() {
  local usage="$1"
  if ! grep -qE '(^|[^A-Za-z-])(grant|revoke)([^A-Za-z-]|$)' <<<"${usage}"; then
    return 2
  fi
  grep -qE '(^|[^A-Za-z-])location([^A-Za-z-]|$)' <<<"${usage}"
}

# bgp_simctl_supports_location_set <usage-text> — does this Xcode's
# `simctl location` offer the `set` action? Same tri-state contract; the
# structural gate needs BOTH `location` and `action` because an Xcode with no
# `location` subcommand answers an error string containing the word
# `location` (see run-b4-ios-real-gps.sh, where this parser originates).
bgp_simctl_supports_location_set() {
  local usage="$1"
  grep -qE '(^|[^A-Za-z-])location([^A-Za-z-]|$)' <<<"${usage}" || return 2
  grep -qE '(^|[^A-Za-z-])action([^A-Za-z-]|$)' <<<"${usage}" || return 2
  grep -qE '(^|[^A-Za-z-])set([^A-Za-z-]|$)' <<<"${usage}"
}

# bgp_marker_present <log> <marker> — is the literal marker in the log?
#
# `grep -aF` (literal, binary-safe): the markers contain `[bg-publish]`,
# which is a valid character class, so any regex form of this check would
# match a lone `b` or `g` and pass vacuously. A missing or empty log reports
# absent — absence of evidence is never evidence.
bgp_marker_present() {
  local log="${1:-}" marker="$2"
  [[ -s "${log}" ]] || return 1
  LC_ALL=C grep -aqF -- "${marker}" "${log}"
}

# bgp_privacy_service <tier> — the `simctl privacy` service this tier grants.
# Non-zero on anything else, so an unrecognised tier can never fall through to
# a grant nobody chose.
bgp_privacy_service() {
  case "${1:-}" in
    when-in-use) printf 'location\n' ;;
    always) printf 'location-always\n' ;;
    *) return 1 ;;
  esac
}

# bgp_expected_tier_name <tier> — the IosAuthStatus name the drive PINS, i.e.
# the value of --dart-define=HAVEN_BGP_EXPECT_TIER. Same tri-state discipline:
# the grant and the pin are two readings of ONE input, and neither may be
# derived independently of the other.
bgp_expected_tier_name() {
  case "${1:-}" in
    when-in-use) printf 'whenInUse\n' ;;
    always) printf 'always\n' ;;
    *) return 1 ;;
  esac
}

# bgp_missing_proofs <log> <tier> <live-sync> — prints the terminal proof
# markers this log does NOT carry, one per line. Empty output means the drive
# reached the end of every phase its LEG has. A missing or empty log reports
# them all as absent.
#
# Four proofs are shared by every leg (ARMED, PUBLISH, SILENCE, DISARMED). The
# other two axes each add exactly one:
#
#   receive plane — RECEIVE_MARKER on a live-sync leg (P2c, the burst),
#     CATCHUP_MARKER on the poll one (P2d, the 90 s receive timer). The two are
#     exclusive by construction: each is reachable only from the compiled branch
#     that has that plane at all.
#   tier — ALWAYS_MARKER on the Always leg, whose whole subject is the
#     confirmed-Always posture; the shared four would be printed by a body that
#     never reached those assertions.
#
# An unrecognised tier or live-sync value reports the corresponding proof(s)
# missing rather than falling back to the smaller gate: a caller that lost
# either axis must not be able to buy a green with the omission.
#
# Always returns 0; the ANSWER is the output, so a caller in a `$( … )` under
# `set -e` is never killed by "no markers were missing".
bgp_missing_proofs() {
  local log="${1:-}" tier="${2:-}" live_sync="${3:-}" marker
  for marker in "${ARMED_MARKER}" "${PUBLISH_MARKER}" "${SILENCE_MARKER}" \
                "${DISARMED_MARKER}"; do
    bgp_marker_present "${log}" "${marker}" || printf '%s\n' "${marker}"
  done
  if [[ "${live_sync}" != 'false' ]]; then
    bgp_marker_present "${log}" "${RECEIVE_MARKER}" \
      || printf '%s\n' "${RECEIVE_MARKER}"
  fi
  if [[ "${live_sync}" != 'true' ]]; then
    bgp_marker_present "${log}" "${CATCHUP_MARKER}" \
      || printf '%s\n' "${CATCHUP_MARKER}"
  fi
  if [[ "${tier}" != 'when-in-use' ]]; then
    bgp_marker_present "${log}" "${ALWAYS_MARKER}" \
      || printf '%s\n' "${ALWAYS_MARKER}"
  fi
  return 0
}

# bgp_unexpected_proofs <log> <tier> <live-sync> — prints any terminal proof
# this leg must NOT have produced, one per line.
#
# Three cases, one per leg-specific proof, and all three catch the same class of
# defect: a run whose two halves were derived from different values.
#
#   ALWAYS_MARKER in a When-In-Use log. The drive can only print it when its
#     compiled HAVEN_BGP_EXPECT_TIER says `always`, so seeing it here means the
#     grant this script performed and the shape the drive asserted disagree —
#     the one mutation that leaves BOTH tier legs running the same shape while
#     every count still looks right.
#   RECEIVE_MARKER in a flag-OFF log, or CATCHUP_MARKER in a flag-ON one. Each
#     phase sits behind the compile-time `liveSyncEnabled` branch that owns its
#     plane, so the wrong marker means the `--dart-define` the drive was built
#     with and the HAVEN_LIVE_SYNC this script acted on came apart — and the leg
#     is measuring the other receive plane under this leg's name.
#
# An unrecognised live-sync value reports nothing unexpected: fail-closed there
# is `bgp_missing_proofs`'s job (it demands BOTH plane proofs), and refusing
# both here as well would make the diagnostic contradict itself.
#
# Always returns 0, for the same `set -e` reason as above.
bgp_unexpected_proofs() {
  local log="${1:-}" tier="${2:-}" live_sync="${3:-}"
  # Every marker read sits in an `if` CONDITION, where `set -e` cannot see its
  # failure: "this leg printed nothing unexpected" is the healthy answer, and a
  # helper that killed the run on it would be unusable from the `$( … )` the
  # gate reads it with.
  if [[ "${tier}" == 'when-in-use' ]] \
     && bgp_marker_present "${log}" "${ALWAYS_MARKER}"; then
    printf '%s\n' "${ALWAYS_MARKER}"
  fi
  if [[ "${live_sync}" == 'false' ]] \
     && bgp_marker_present "${log}" "${RECEIVE_MARKER}"; then
    printf '%s\n' "${RECEIVE_MARKER}"
  fi
  if [[ "${live_sync}" == 'true' ]] \
     && bgp_marker_present "${log}" "${CATCHUP_MARKER}"; then
    printf '%s\n' "${CATCHUP_MARKER}"
  fi
  return 0
}

# bgp_signal_paths <app-data-root> <name> — every handshake-signal candidate
# under an app-data root, one path per line.
#
# A SWEEP over containers rather than one pinned path, because the drive's own
# install ROTATES the app's data container. This script installs the app first
# (it has to: `simctl privacy grant` resolves the bundle id against INSTALLED
# apps), then the delegated `flutter drive` installs its freshly built bundle
# over the top and iOS hands the app a NEW
# `Containers/Data/Application/<UUID>` directory. Any path resolved before the
# drive runs therefore names a container nobody writes to afterwards: in CI run
# 32618134993 the host polled …/29407E44…/tmp while the drive wrote to
# …/7ECBFB3C…/tmp, so READY was never observed, the app was never backgrounded,
# and the drive failed its own paused-wait 180 s later. Only the leaf UUID
# rotates — the root below is stable — so sweeping the root is what survives it.
#
# `|| true`: a `find` that meets one unreadable directory exits non-zero having
# still printed every other match. The answer is the OUTPUT, so this reports
# "these are the candidates" rather than handing callers a status they would
# have to distinguish from "none" — and it cannot trip `set -e` in a caller
# that reads it with `$( … )`.
bgp_signal_paths() {
  local root="${1:-}" name="$2"
  find "${root}" -maxdepth 3 -type f -name "${name}" 2>/dev/null || true
}

# bgp_app_data_root <container-path> — the app-data ROOT to sweep, or non-zero
# if the container is not laid out the way this script understands.
#
# Both halves matter and neither is redundant. Skipping the `dirname` leaves the
# sweep pointed at ONE container — which still finds that container's own signal
# at depth 2 and so looks perfectly healthy, right up until the drive's install
# rotates the leaf and the lane fails exactly as it did in CI run 32618134993.
# Skipping the suffix check lets a changed simulator layout silently redirect
# the sweep at whatever `dirname` happened to return.
bgp_app_data_root() {
  local container="${1:-}" root
  root="$(dirname "${container}")"
  [[ "${root}" == */Containers/Data/Application ]] || return 1
  printf '%s\n' "${root}"
}

# bgp_marker_present_under <app-data-root> <name> <marker> — is the marker in
# ANY handshake signal under this root?
#
# A missing root, a missing file and an empty file all read as "absent", the
# same fail-closed reading `bgp_marker_present` gives a single file.
bgp_marker_present_under() {
  local root="${1:-}" name="$2" marker="$3" path
  while IFS= read -r path; do
    [[ -n "${path}" ]] || continue
    if bgp_marker_present "${path}" "${marker}"; then return 0; fi
  done < <(bgp_signal_paths "${root}" "${name}")
  return 1
}

# bgp_now — the wall clock, in epoch seconds.
#
# The one unit every deadline here is stated in, and the unit
# `bgp_file_mtime` reports, so a budget and an anchor are always comparable.
bgp_now() {
  date +%s
}

# bgp_file_mtime <path> — when the file was last written, in epoch seconds,
# or NOTHING at all when that cannot be read.
#
# BSD `stat` first (this lane runs on macOS), GNU second, because --self-test
# runs on the Linux guards job: a helper that worked on only one of the two
# would be pinned by fixtures that never exercise the half CI depends on.
# Each spelling's OUTPUT is validated rather than its exit status, because GNU
# `stat -f %m <path>` neither fails cleanly nor stays quiet — it reads `%m` as
# a second path, complains about it on stderr, and prints the filesystem's
# block counts for the real one on stdout. Chained on status alone that junk
# becomes the answer, and every caller that then rejects it as non-numeric
# silently loses the anchor it asked for.
bgp_file_mtime() {
  local path="${1:-}" mtime
  mtime="$(stat -f %m "${path}" 2>/dev/null || true)"
  [[ "${mtime}" =~ ^[0-9]+$ ]] \
    || mtime="$(stat -c %Y "${path}" 2>/dev/null || true)"
  [[ "${mtime}" =~ ^[0-9]+$ ]] || return 0
  printf '%s\n' "${mtime}"
}

# bgp_signal_mtime_with <app-data-root> <name> <marker> — when the drive
# APPENDED <marker>, in epoch seconds; non-zero when no signal carries it.
#
# The drive appends its markers in phase order and nothing else writes the
# file, so the mtime of a copy carrying the newest marker IS the instant the
# drive reached that phase — read off the app's own write instead of off this
# script's poll, which trails it by a whole MARKER_POLL_SECS plus a sweep.
bgp_signal_mtime_with() {
  local root="${1:-}" name="$2" marker="$3" path mtime
  while IFS= read -r path; do
    [[ -n "${path}" ]] || continue
    bgp_marker_present "${path}" "${marker}" || continue
    mtime="$(bgp_file_mtime "${path}")"
    [[ -n "${mtime}" ]] || continue
    printf '%s\n' "${mtime}"
    return 0
  done < <(bgp_signal_paths "${root}" "${name}")
  return 1
}

# bgp_budget_after_lag <anchor-epoch> <budget-secs> <max-lag-secs> — what is
# left of <budget> once it is measured from <anchor> rather than from now.
#
# The two directions of error are not each other's mirror, so the correction
# is deliberately one-sided: it may only ever give back the observation lag
# this script itself introduced, never move a wake-up later, and never give
# back more than <max-lag>. Waking Haven EARLY re-foregrounds it INSIDE the
# drive's settle window, where a correct app publishes on the foreground path
# and P3 reds for the app behaving properly — an unrecoverable wrong verdict.
# Waking it late only spends margin. So an anchor in the future (a clock that
# moved), older than <max-lag> (a signal from a previous attempt), or not a
# number at all is not trusted: the caller gets the whole budget, which is
# exactly the behaviour that predates the anchor.
bgp_budget_after_lag() {
  local anchor="${1:-}" budget="$2" max_lag="$3" lag
  [[ "${anchor}" =~ ^[0-9]+$ ]] || { printf '%s\n' "${budget}"; return 0; }
  lag=$(( $(bgp_now) - anchor ))
  if (( lag < 0 || lag > max_lag )); then
    printf '%s\n' "${budget}"
    return 0
  fi
  printf '%s\n' "$(( budget - lag ))"
}

# bgp_app_process_state <udid> — `running`, `gone`, or `unknown`: is the app
# under test still a process on this device?
#
# Asked in exactly one place — when the drive dies inside P3's settle window,
# the one stretch of this lane where the app holds NO execution claim and iOS
# may take the process away (CI run 35397118356). "The drive exited" and "the
# OS reclaimed the app" produce the same rc and the same truncated transcript,
# and only this tells them apart.
#
# A simulator app is an ordinary host process whose argv names the bundle
# inside THIS device's container tree, so `pgrep -f` answers it without going
# through `simctl` — whose own answer for a process the OS is tearing down is
# the thing being asked about. Reports `unknown` rather than guessing when
# there is no `pgrep` or no device, so a wrong diagnosis is never printed as a
# confident one.
bgp_app_process_state() {
  local udid="${1:-}"
  command -v pgrep >/dev/null 2>&1 || { printf 'unknown\n'; return 0; }
  [[ -n "${udid}" ]] || { printf 'unknown\n'; return 0; }
  if pgrep -f "/Devices/${udid}/data/Containers/Bundle/.*/Runner\.app/Runner" \
       >/dev/null 2>&1; then
    printf 'running\n'
  else
    printf 'gone\n'
  fi
}

# bgp_calibrated_app_state <calibration> <state> — <state>, or `unknown` when
# the read that produced it was never shown to work on this runner.
#
# The read above matches an argv layout, and an argv layout is the simulator's
# to change. So it is taken ONCE while the app is unarguably alive (the drive
# has just signalled READY from inside it), and a `gone` that follows is only
# evidence if that calibration saw the app. Otherwise the honest answer is
# `unknown`: a diagnosis that blamed iOS for reclaiming an app that was still
# there would send the next reader past the drive's own failure.
bgp_calibrated_app_state() {
  local calibration="${1:-}" state="${2:-}"
  [[ "${calibration}" == 'running' ]] || { printf 'unknown\n'; return 0; }
  printf '%s\n' "${state}"
}

# bgp_secs_until <target-epoch> <cap-secs> — how long to wait for <target>,
# never more than <cap> and never less than nothing.
#
# The host takes over P3's settle window when the OS reclaims the app inside
# it, and that takeover must cost the lane NO extra wall clock: <cap> is
# whatever is left of the DISARM budget, which is what the wait it replaces
# would have spent. A target that is not a number, or already past, is 0 —
# the same fail-to-now reading `bgp_budget_after_lag` gives a bad anchor.
bgp_secs_until() {
  local target="${1:-}" cap="$2" remaining
  if ! [[ "${target}" =~ ^[0-9]+$ ]]; then printf '0\n'; return 0; fi
  remaining=$(( target - $(bgp_now) ))
  if (( remaining <= 0 )); then printf '0\n'; return 0; fi
  if (( remaining > cap )); then printf '%s\n' "${cap}"; return 0; fi
  printf '%s\n' "${remaining}"
}

# bgp_p3_host_verdict <disable-rc> <exit-state> <end-state> <wire-rc> — the
# verdict on a drive that exited INSIDE P3's settle window, in one word:
#
#   holds       the app applied the disable in-process (it appended the
#               DISABLED marker, which it only does AFTER asserting the
#               provider false and the publish scheduler torn down), the OS
#               then reclaimed it, the relay saw NO kind-445 for the whole
#               window, and nothing brought the process back. P3 kept.
#   leak        a kind-445 was created inside the window. Publishing outlived
#               the withdrawal of consent — whether from the app before it
#               died or from a background relaunch after, both of which are
#               the defect P3 exists to catch.
#   relaunched  the window ended with the app RUNNING again although the host
#               never launched it. Something re-armed a background wake after
#               consent was withdrawn.
#   unproven    anything else: the drive died with its app still there (its
#               own failure), the liveness read was never calibrated, the
#               disable was never signalled, or the wire could not be read.
#
# There is deliberately no fifth answer and no default-to-green: `unknown`
# reaching here means the evidence is missing, and missing evidence is not a
# pass. The NATIVE half of P3 — that the CoreLocation keep-alive was released
# — is not asserted separately on this path because the reclaim IS that
# assertion: an app still holding a location session is exactly an app iOS
# keeps executing (P2a/P2b measure that every run, for 400+ s), so a process
# RunningBoard took inside the window is a process that had already let its
# keep-alive go. A simulator has no jetsam, so there is no other way to lose
# it there.
bgp_p3_host_verdict() {
  local disable_rc="${1:-}" exit_state="${2:-}" end_state="${3:-}" \
        wire_rc="${4:-}"
  [[ "${disable_rc}" == '0' ]] || { printf 'unproven\n'; return 0; }
  [[ "${exit_state}" == 'gone' ]] || { printf 'unproven\n'; return 0; }
  case "${wire_rc}" in
    1) printf 'leak\n'; return 0 ;;
    0) : ;;
    *) printf 'unproven\n'; return 0 ;;
  esac
  [[ "${end_state}" == 'gone' ]] || { printf 'relaunched\n'; return 0; }
  printf 'holds\n'
}

# bgp_unexcused_proofs <missing-markers> — the missing terminal proofs that a
# host-proved P3 does NOT excuse, one per line.
#
# Exactly two markers are excusable, and only when `bgp_p3_host_verdict` says
# `holds`: the silence proof, which the host has just re-proven from the relay
# with an oracle the app's death cannot reach, and the disarm proof, which a
# process that no longer exists cannot print and does not need to. Every other
# phase's proof is still demanded — a drive reclaimed inside P3 has already
# printed them all, so a missing one means the run stopped somewhere else
# entirely and P3's verdict says nothing about it.
bgp_unexcused_proofs() {
  local missing="${1:-}"
  [[ -n "${missing}" ]] || return 0
  printf '%s\n' "${missing}" \
    | grep -vFx -e "${SILENCE_MARKER}" -e "${DISARMED_MARKER}" || true
}

# bgp_dart_bin — the `dart` this runner drives the wire oracle with.
#
# Prints the path, or nothing at all when there is none. `flutter-action`
# exports the SDK's bin/ on PATH and `dart` lives beside `flutter` in it, so
# the fallback covers a PATH that carried only the wrapper. No `dart` at all
# is a harness misconfiguration, never a silent skip: the caller exits 2.
bgp_dart_bin() {
  local flutter_bin
  if command -v dart >/dev/null 2>&1; then
    command -v dart
    return 0
  fi
  flutter_bin="$(command -v flutter 2>/dev/null || true)"
  [[ -n "${flutter_bin}" ]] || return 0
  flutter_bin="$(dirname "${flutter_bin}")/dart"
  [[ -x "${flutter_bin}" ]] || return 0
  printf '%s\n' "${flutter_bin}"
}

# bgp_wire_probe_rc <dart> <relay> <since> <until> <disable-at> — ask the relay
# whether any kind-445 was created inside P3's settle window. Prints the probe's
# own (bucketed, Rule-15 safe) line and returns its status: 0 silent, 1 leak,
# 3 unreadable, 4 a control came back empty. The relay URL is an ARGUMENT and
# never an output, here or in the probe.
#
# The disable anchor is passed as well as the window derived from it: the
# probe's SECOND control looks for a kind-445 in the seconds before it, which
# is what certifies that this relay is still serving the very kind the window
# is read for. Without it an empty window and a relay that stopped serving 445
# are the same observation.
bgp_wire_probe_rc() {
  # `till`, not `until`: shadowing a shell keyword with a local is legal and
  # works, but it reads as a loop to everyone who meets it next.
  local dart="$1" relay="$2" since="$3" till="$4" anchor="$5" out rc=0
  out="$("${dart}" "${WIRE_PROBE}" --relay "${relay}" --since "${since}" \
           --until "${till}" --disable-at "${anchor}" 2>&1)" || rc=$?
  if [[ -n "${out}" ]]; then printf '%s\n' "${out}"; fi
  return "${rc}"
}

# bgp_wait_until <pid> <deadline-secs> <poll-secs> -- <cmd> [args…] — bounded
# wait for a predicate command to succeed while a process is still alive.
#
# The predicate must read the handshake SIGNAL, never SHARED_LOG: when a
# marker reaches that log is the test reporter's decision, and under the one
# flutter_tools picks by default in CI it is not observable until the drive
# exits.
#
# The deadline is WALL CLOCK, and that is not a detail. Every poll also RUNS
# the predicate — a `find` over the app-data tree plus a `grep` per candidate
# — and a loop that counts only its own sleeps spends that time for free: the
# DISARM wait took 216.8-222.0 s of wall clock for its 210 s budget across
# five CI runs (35376588206, 35311161479, 35280144455 x2, 34798752509). Both
# of that budget's bounds are wall-clock facts about the app and the relay —
# the drive's settle window below it and the 228 s kind-445 expiration above
# it — so a counted deadline walks P3's re-fetch out of the interval where the
# app would still be publishing if it were broken. The same argument applies
# one phase up: the DISABLE deadline is derived to sit inside the drive's own
# Timeout, which is also wall clock.
#
# Not, note, relay-side EVICTION. VERIFIED in the crates this lane's relay is
# built from (nostr-relay-builder 0.44.1 over nostr-database 0.44.0): expiry is
# enforced at INGEST only — `helper.rs` `internal_index_event` rejects an
# already-expired event (`RejectedReason::Expired`), `internal_query` never
# filters on expiry, and no sweeper exists — so an event this relay accepted is
# served for the life of the process. The corollary matters more than the
# correction: an event that was ALREADY expired when it arrived is rejected and
# stored nowhere, so no REQ-based oracle can ever see it. Reaching that state
# needs a >=228 s stall between wrapping a kind-445 and flushing it, which
# Haven does not queue for.
#
# Returns:
#   0  the predicate succeeded
#   2  the process exited first (the predicate is re-evaluated before this
#      verdict, so a signal written as the drive's last act still counts)
#   3  the deadline elapsed with the process still running
bgp_wait_until() {
  local pid="$1" deadline="$2" poll="$3" started
  shift 3
  [[ "${1:-}" == '--' ]] && shift
  started="$(bgp_now)"
  while :; do
    if "$@"; then return 0; fi
    if ! kill -0 "${pid}" 2>/dev/null; then
      # The process may have written the signal in its final act.
      if "$@"; then return 0; fi
      return 2
    fi
    if (( $(bgp_now) - started >= deadline )); then return 3; fi
    sleep "${poll}"
  done
}

# bgp_scan_or_contain <preserved-log> <shared-log> — the log-privacy gate
# (Security Rules 6 and 15) over the logs the workflow uploads `if: failure()`,
# through logscan-gate.sh under the job's HAVEN_LOGSCAN and its profile
# (HAVEN_LOGSCAN_PROFILE, or inferred from the recorder's exports — the same
# rule as run-ios-sim-scenario.sh, so the belt and the delegate seal alike).
# The delegate gates the shared transcript at ITS end; this is the belt over
# the copy this lane preserves, for the case where the delegate was killed
# before it got there. A leak (rc 1) fails the lane, and that failure is what
# triggers the upload — so the gate REMOVES every log it scanned before
# returning. rc 3 (absent/empty) keeps them: nothing there to contain.
bgp_scan_or_contain() {
  local profile="${HAVEN_LOGSCAN_PROFILE:-}"
  if [[ -z "${profile}" ]]; then
    if [[ -n "${WIRE_UPSTREAM:-}${HAVEN_WIRE_SENTINEL:-}" ]]; then profile=proxy; else profile=host; fi
  fi
  logscan_gate "${profile}" /tmp/haven-soak/needles \
    --floor "drive=${BGP_DRIVE_FLOOR}" -- \
    --sink "drive=$1,$2" --report /tmp/ios-logscan/bg-publish.ndjson
}

# ---------------------------------------------------------------------------
# --self-test — hermetic. Fixtures are the ways this lane can go vacuously
# green or wedge unbounded, because those are the failures nothing else would
# catch.
# ---------------------------------------------------------------------------
run_self_test() {
  local tmp fail=0 checked=0
  # How many fixtures this suite must RUN, pinned by equality (the same rule
  # check_ios_background_publish.sh's SELF_TEST_FIXTURES enforces). A count in
  # the summary line alone reports whatever ran: a fixture deleted with the
  # code it covered would print a smaller number and still say "all passed".
  local -r SELF_TEST_FIXTURES=113
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  _check() { # _check <label> <want> <got>
    checked=$(( checked + 1 ))
    if [[ "$2" == "$3" ]]; then
      printf '  \033[1;32mPASS\033[0m %s\n' "$1"
    else
      printf '  \033[1;31mFAIL\033[0m %s (want %s, got %s)\n' "$1" "$2" "$3" >&2
      fail=1
    fi
  }

  # --- (P1) An Xcode whose `simctl privacy` offers the location service.
  local rc=0
  bgp_simctl_supports_location_privacy \
'Usage: simctl privacy <device> <action> <service> [<bundle identifier>]
   action: grant, revoke, reset
   service: all, calendar, contacts, location, location-always, photos' \
    || rc=$?
  _check "P1 privacy usage listing location is supported" 0 "${rc}"

  # --- (P2) A privacy service list WITHOUT location must be refused.
  rc=0
  bgp_simctl_supports_location_privacy \
'Usage: simctl privacy <device> <action> <service>
   action: grant, revoke
   service: calendar, contacts, photos, microphone' \
    || rc=$?
  _check "P2 privacy usage without location is REFUSED" 1 "${rc}"

  # --- (P3) Unparseable usage must be distinguishable from "unsupported".
  rc=0
  bgp_simctl_supports_location_privacy \
    'xcrun: error: unable to find utility "simctl"' || rc=$?
  _check "P3 unparseable privacy usage reports misconfiguration" 2 "${rc}"

  # --- (L1) `simctl location` offering the `set` action.
  rc=0
  bgp_simctl_supports_location_set \
'Set or clear simulated location.
Usage: simctl location <device> <action> [<arguments>]
   action: clear, set, start, stop, list' \
    || rc=$?
  _check "L1 location usage listing set is supported" 0 "${rc}"

  # --- (L2) A `location` listing without `set` is refused, not misread.
  rc=0
  bgp_simctl_supports_location_set \
'Usage: simctl location <device> <action>
   action: clear, list' \
    || rc=$?
  _check "L2 location usage without set is REFUSED" 1 "${rc}"

  # --- (L3) The no-location-subcommand error string mentions the word
  #     `location` but enumerates no actions; it must report unparseable,
  #     never "your Xcode lacks set".
  rc=0
  bgp_simctl_supports_location_set \
    'Unknown subcommand "location". Usage: simctl <subcommand>' || rc=$?
  _check "L3 a no-location-subcommand error reports misconfiguration" 2 "${rc}"

  # --- (M1) The marker parser accepts the PUBLISH prefix with its real
  #     ` count=<n>` suffix — a whole-line match would find nothing on every
  #     real run.
  local log="${tmp}/m1.log"
  printf '%s count=2\n' "${PUBLISH_MARKER}" > "${log}"
  rc=0; bgp_marker_present "${log}" "${PUBLISH_MARKER}" || rc=$?
  _check "M1 the trailing ' count=<n>' does not defeat the match" 0 "${rc}"

  # --- (M2) An absent marker is absent.
  printf 'Some tests failed.\n' > "${log}"
  rc=0; bgp_marker_present "${log}" "${ARMED_MARKER}" || rc=$?
  _check "M2 a markerless log reports absent" 1 "${rc}"

  # --- (M3) A MISSING log is absence of evidence, never evidence.
  rc=0; bgp_marker_present "${tmp}/nope.log" "${ARMED_MARKER}" || rc=$?
  _check "M3 a missing log reports absent" 1 "${rc}"

  # A tiny writer, so each completion fixture states exactly which proofs
  # its log carries.
  _bgp_log() { # _bgp_log <path> [marker ...]
    local path="$1"; shift
    {
      echo 'Xcode build done.                                           400.0s'
      echo "${READY_MARKER}"
      local m
      for m in "$@"; do echo "${m}"; done
      echo 'All tests passed!'
    } > "${path}"
  }

  # --- (C1) THE PASSING SHAPE for the When-In-Use live-sync leg: the four
  #     shared proofs plus the burst's.
  local clog="${tmp}/c.log" got
  _bgp_log "${clog}" "${ARMED_MARKER}" "${PUBLISH_MARKER} count=2" \
    "${RECEIVE_MARKER}" "${SILENCE_MARKER}" "${DISARMED_MARKER}"
  got="$(bgp_missing_proofs "${clog}" 'when-in-use' 'true')"
  _check "C1 the four shared proofs + RECEIVE is COMPLETE (wiu, live-sync)" \
    "" "${got}"

  # --- (C2..C5, C7) Each proof individually missing must be named. The READY
  #     marker is present in every fixture, which is the A3b point: it is
  #     printed before P2/P3 run, so it must never satisfy the gate.
  _bgp_log "${clog}" "${PUBLISH_MARKER} count=2" "${RECEIVE_MARKER}" \
    "${SILENCE_MARKER}" "${DISARMED_MARKER}"
  got="$(bgp_missing_proofs "${clog}" 'when-in-use' 'true')"
  _check "C2 a missing SESSION_ARMED is REFUSED" "${ARMED_MARKER}" "${got}"

  _bgp_log "${clog}" "${ARMED_MARKER}" "${RECEIVE_MARKER}" \
    "${SILENCE_MARKER}" "${DISARMED_MARKER}"
  got="$(bgp_missing_proofs "${clog}" 'when-in-use' 'true')"
  _check "C3 a missing BACKGROUND_PUBLISH_OK is REFUSED" \
    "${PUBLISH_MARKER}" "${got}"

  _bgp_log "${clog}" "${ARMED_MARKER}" "${PUBLISH_MARKER} count=2" \
    "${RECEIVE_MARKER}" "${DISARMED_MARKER}"
  got="$(bgp_missing_proofs "${clog}" 'when-in-use' 'true')"
  _check "C4 a missing NEGATIVE_SILENCE_OK is REFUSED" \
    "${SILENCE_MARKER}" "${got}"

  _bgp_log "${clog}" "${ARMED_MARKER}" "${PUBLISH_MARKER} count=2" \
    "${RECEIVE_MARKER}" "${SILENCE_MARKER}"
  got="$(bgp_missing_proofs "${clog}" 'when-in-use' 'true')"
  _check "C5 a missing SESSION_DISARMED is REFUSED" \
    "${DISARMED_MARKER}" "${got}"

  # --- (C7) P2c's own proof, missing. The receive half is the one phase whose
  #     absence is invisible in the other four: a drive that published for the
  #     whole window, went silent on the disable and disarmed prints every one
  #     of them without ever asking whether a burst RECEIVED anything or
  #     whether it left a standing REQ behind — which is the half of the
  #     background promise that has no wire oracle in this lane.
  _bgp_log "${clog}" "${ARMED_MARKER}" "${PUBLISH_MARKER} count=2" \
    "${SILENCE_MARKER}" "${DISARMED_MARKER}"
  got="$(bgp_missing_proofs "${clog}" 'when-in-use' 'true')"
  _check "C7 a missing BACKGROUND_RECEIVE_OK is REFUSED" \
    "${RECEIVE_MARKER}" "${got}"

  # --- (C6) An absent or empty log reports every proof of the leg missing —
  #     the `cp` that preserves the run is `|| true`d by design, so "no log" is
  #     a reachable state and must fail closed.
  got="$(bgp_missing_proofs "${tmp}/absent.log" 'when-in-use' 'true' \
          | tr '\n' ';')"
  _check "C6 a MISSING log reports every proof of the leg absent" \
    "${ARMED_MARKER};${PUBLISH_MARKER};${SILENCE_MARKER};${DISARMED_MARKER};${RECEIVE_MARKER};" \
    "${got}"
  : > "${tmp}/empty.log"
  got="$(bgp_missing_proofs "${tmp}/empty.log" 'when-in-use' 'true' \
          | tr '\n' ';')"
  _check "C6b an EMPTY log reports every proof of the leg absent" \
    "${ARMED_MARKER};${PUBLISH_MARKER};${SILENCE_MARKER};${DISARMED_MARKER};${RECEIVE_MARKER};" \
    "${got}"

  # --- (A1) THE PASSING SHAPE for the ALWAYS live-sync leg: six proofs.
  _bgp_log "${clog}" "${ARMED_MARKER}" "${PUBLISH_MARKER} count=2" \
    "${RECEIVE_MARKER}" "${SILENCE_MARKER}" "${DISARMED_MARKER}" \
    "${ALWAYS_MARKER}"
  got="$(bgp_missing_proofs "${clog}" 'always' 'true')"
  _check "A1 all six proofs is COMPLETE (always, live-sync)" "" "${got}"

  # --- (A2) The ALWAYS job's own proof, missing. This is the fixture the
  #     whole matrix rests on: the five When-In-Use proofs are printed by a
  #     drive that never reached the confirmed-Always assertions, so without
  #     this the Always job could go green having exercised nothing that
  #     distinguishes it from the other one.
  _bgp_log "${clog}" "${ARMED_MARKER}" "${PUBLISH_MARKER} count=2" \
    "${RECEIVE_MARKER}" "${SILENCE_MARKER}" "${DISARMED_MARKER}"
  got="$(bgp_missing_proofs "${clog}" 'always' 'true')"
  _check "A2 a missing ALWAYS_SESSION_OK is REFUSED under always" \
    "${ALWAYS_MARKER}" "${got}"

  # --- (A3) …and NOT required under when-in-use. The inverse mistake — one
  #     gate demanding all six everywhere — would red the When-In-Use job for
  #     behaving exactly as its tier requires.
  got="$(bgp_missing_proofs "${clog}" 'when-in-use' 'true')"
  _check "A3 ALWAYS_SESSION_OK is NOT required under when-in-use" "" "${got}"

  # --- (A4) An UNRECOGNISED tier fails CLOSED: the tier's proof reported
  #     missing, never a quiet fall-back to the smaller gate. A caller that
  #     lost the tier must not be able to buy a green with the omission.
  got="$(bgp_missing_proofs "${clog}" '' 'true' | tr '\n' ';')"
  _check "A4 an unrecognised tier demands the ALWAYS proof too" \
    "${ALWAYS_MARKER};" "${got}"

  # --- (PF1) THE PASSING SHAPE for the POLL leg (OD4-d): the same four shared
  #     proofs, with the 90 s receive timer's in place of the burst's. The
  #     receive plane a build HAS is what decides which one, so this is not a
  #     smaller gate — it is a different fifth proof.
  _bgp_log "${clog}" "${ARMED_MARKER}" "${PUBLISH_MARKER} count=2" \
    "${CATCHUP_MARKER}" "${SILENCE_MARKER}" "${DISARMED_MARKER}"
  got="$(bgp_missing_proofs "${clog}" 'when-in-use' 'false')"
  _check "PF1 the four shared proofs + CATCHUP is COMPLETE (wiu, poll)" \
    "" "${got}"

  # --- (PF2) …and its own proof missing is REFUSED. Without this the poll leg
  #     could exit 0 over a body that published for the whole window and never
  #     asked whether the background receive timer fired at all — which is the
  #     only reason the leg exists.
  _bgp_log "${clog}" "${ARMED_MARKER}" "${PUBLISH_MARKER} count=2" \
    "${SILENCE_MARKER}" "${DISARMED_MARKER}"
  got="$(bgp_missing_proofs "${clog}" 'when-in-use' 'false')"
  _check "PF2 a missing BACKGROUND_CATCHUP_OK is REFUSED under flag-off" \
    "${CATCHUP_MARKER}" "${got}"

  # --- (PF3) The LEG-IDENTITY fixture, and the one no count can see: the
  #     live-sync leg's own passing log, read as the poll leg. Every shared
  #     proof is present and the receive half is proved for the OTHER plane, so
  #     a gate that only counted five would call this complete.
  _bgp_log "${clog}" "${ARMED_MARKER}" "${PUBLISH_MARKER} count=2" \
    "${RECEIVE_MARKER}" "${SILENCE_MARKER}" "${DISARMED_MARKER}"
  got="$(bgp_missing_proofs "${clog}" 'when-in-use' 'false')"
  _check "PF3 the burst's proof does NOT satisfy the poll leg" \
    "${CATCHUP_MARKER}" "${got}"

  # --- (PF4) …and the mirror: the poll leg's passing log read as a live-sync
  #     leg must report the burst's proof missing.
  _bgp_log "${clog}" "${ARMED_MARKER}" "${PUBLISH_MARKER} count=2" \
    "${CATCHUP_MARKER}" "${SILENCE_MARKER}" "${DISARMED_MARKER}"
  got="$(bgp_missing_proofs "${clog}" 'when-in-use' 'true')"
  _check "PF4 the timer's proof does NOT satisfy a live-sync leg" \
    "${RECEIVE_MARKER}" "${got}"

  # --- (PF5) An UNRECOGNISED live-sync value fails CLOSED on BOTH planes, for
  #     the same reason A4 does on the tier: a caller that lost the axis must
  #     not be handed the smaller of the two gates. The fixture carries the four
  #     shared proofs and NEITHER plane's, so the answer names both.
  _bgp_log "${clog}" "${ARMED_MARKER}" "${PUBLISH_MARKER} count=2" \
    "${SILENCE_MARKER}" "${DISARMED_MARKER}"
  got="$(bgp_missing_proofs "${clog}" 'when-in-use' '' | tr '\n' ';')"
  _check "PF5 an unrecognised live-sync value demands BOTH plane proofs" \
    "${RECEIVE_MARKER};${CATCHUP_MARKER};" "${got}"

  # --- (U1) The SYMMETRIC half. ALWAYS_SESSION_OK is only reachable when the
  #     compiled HAVEN_BGP_EXPECT_TIER says `always`, so finding it in a
  #     When-In-Use run means the grant this script performed and the shape the
  #     drive asserted were derived from different values — and BOTH jobs would
  #     then measure one posture while every count still looked right. No
  #     count-based fixture can see that.
  _bgp_log "${clog}" "${ARMED_MARKER}" "${PUBLISH_MARKER} count=2" \
    "${RECEIVE_MARKER}" "${SILENCE_MARKER}" "${DISARMED_MARKER}" \
    "${ALWAYS_MARKER}"
  got="$(bgp_unexpected_proofs "${clog}" 'when-in-use' 'true')"
  _check "U1 ALWAYS_SESSION_OK in a when-in-use log is REFUSED" \
    "${ALWAYS_MARKER}" "${got}"

  # --- (U2) Non-vacuity for U1, both directions: the same log is legitimate
  #     under `always`, and a when-in-use log without the marker is clean. A
  #     helper that always printed would red every run.
  got="$(bgp_unexpected_proofs "${clog}" 'always' 'true')"
  _check "U2 the same log is legitimate under always" "" "${got}"
  _bgp_log "${clog}" "${ARMED_MARKER}" "${PUBLISH_MARKER} count=2" \
    "${RECEIVE_MARKER}" "${SILENCE_MARKER}" "${DISARMED_MARKER}"
  got="$(bgp_unexpected_proofs "${clog}" 'when-in-use' 'true')"
  _check "U2b a clean when-in-use log reports nothing unexpected" "" "${got}"

  # --- (U3) The receive-plane half of the same symmetry, and the mutation it
  #     catches is the one PF3/PF4 cannot: a leg whose `--dart-define` and whose
  #     HAVEN_LIVE_SYNC came from different values prints the OTHER plane's
  #     proof, so demanding this leg's is not enough — the wrong one has to be
  #     refused as well, or a log carrying BOTH would pass on either leg.
  _bgp_log "${clog}" "${ARMED_MARKER}" "${PUBLISH_MARKER} count=2" \
    "${RECEIVE_MARKER}" "${SILENCE_MARKER}" "${DISARMED_MARKER}"
  got="$(bgp_unexpected_proofs "${clog}" 'when-in-use' 'false')"
  _check "U3 BACKGROUND_RECEIVE_OK in a flag-off log is REFUSED" \
    "${RECEIVE_MARKER}" "${got}"
  _bgp_log "${clog}" "${ARMED_MARKER}" "${PUBLISH_MARKER} count=2" \
    "${CATCHUP_MARKER}" "${SILENCE_MARKER}" "${DISARMED_MARKER}"
  got="$(bgp_unexpected_proofs "${clog}" 'when-in-use' 'true')"
  _check "U3b BACKGROUND_CATCHUP_OK in a flag-on log is REFUSED" \
    "${CATCHUP_MARKER}" "${got}"

  # --- (U4) Non-vacuity for U3, both directions: each plane's proof is
  #     legitimate on its OWN leg. A helper that refused unconditionally would
  #     red every run of both.
  got="$(bgp_unexpected_proofs "${clog}" 'when-in-use' 'false')"
  _check "U4 the timer's proof is legitimate on the poll leg" "" "${got}"
  _bgp_log "${clog}" "${ARMED_MARKER}" "${PUBLISH_MARKER} count=2" \
    "${RECEIVE_MARKER}" "${SILENCE_MARKER}" "${DISARMED_MARKER}"
  got="$(bgp_unexpected_proofs "${clog}" 'when-in-use' 'true')"
  _check "U4b the burst's proof is legitimate on a live-sync leg" "" "${got}"

  # --- (T1/T2) The tier derivation. One input decides the grant AND the shape
  #     the drive pins; deriving them separately is how the two come apart, so
  #     both are pinned here and an unrecognised tier must be REFUSED rather
  #     than defaulted — a default would silently run the matrix's Always leg
  #     as a second When-In-Use job.
  got="$(bgp_privacy_service 'when-in-use')"
  _check "T1 when-in-use grants the location service" 'location' "${got}"
  got="$(bgp_privacy_service 'always')"
  _check "T1b always grants the location-always service" \
    'location-always' "${got}"
  rc=0; bgp_privacy_service 'sometimes' >/dev/null || rc=$?
  _check "T1c an unknown tier grants NOTHING" 1 "${rc}"

  got="$(bgp_expected_tier_name 'when-in-use')"
  _check "T2 when-in-use pins the whenInUse status" 'whenInUse' "${got}"
  got="$(bgp_expected_tier_name 'always')"
  _check "T2b always pins the always status" 'always' "${got}"
  rc=0; bgp_expected_tier_name 'sometimes' >/dev/null || rc=$?
  _check "T2c an unknown tier pins NOTHING" 1 "${rc}"

  # --- (W1) A marker already present returns immediately.
  local wlog="${tmp}/w.log"
  printf '%s\n' "${READY_MARKER}" > "${wlog}"
  ( sleep 30 ) & local wpid=$!
  rc=0; bgp_wait_until "${wpid}" 10 1 \
    -- bgp_marker_present "${wlog}" "${READY_MARKER}" || rc=$?
  kill "${wpid}" 2>/dev/null || true; wait "${wpid}" 2>/dev/null || true
  _check "W1 an already-present marker returns 0" 0 "${rc}"

  # --- (W2) A marker that appears mid-wait is found. The writer delays 1 s
  #     against a 10 s deadline — a 10x margin, so a loaded runner cannot
  #     flake this.
  : > "${wlog}"
  ( sleep 1; printf '%s\n' "${READY_MARKER}" >> "${wlog}"; sleep 30 ) &
  wpid=$!
  rc=0; bgp_wait_until "${wpid}" 10 1 \
    -- bgp_marker_present "${wlog}" "${READY_MARKER}" || rc=$?
  kill "${wpid}" 2>/dev/null || true; wait "${wpid}" 2>/dev/null || true
  _check "W2 a marker appearing mid-wait returns 0" 0 "${rc}"

  # --- (W3) A process that exits WITHOUT the marker reports 2, not a hang
  #     and not a deadline — the caller must distinguish "the drive died"
  #     from "the drive is slow".
  : > "${wlog}"
  ( exit 0 ) & wpid=$!
  wait "${wpid}" 2>/dev/null || true
  rc=0; bgp_wait_until "${wpid}" 10 1 \
    -- bgp_marker_present "${wlog}" "${READY_MARKER}" || rc=$?
  _check "W3 a dead process without the marker returns 2" 2 "${rc}"

  # --- (W3b) The post-death RE-CHECK, and ONLY it: the predicate is false on
  #     its first evaluation and true on its second, against an ALREADY-DEAD
  #     pid, so a 0 here can come from nowhere else. Writing the signal up
  #     front (the obvious way to write this fixture) is answered by the
  #     top-of-loop read instead and leaves the re-check unexercised —
  #     deleting the re-check outright then passes. The case it guards is a
  #     drive that writes its signal as its last act before exiting.
  local wonce="${tmp}/w.once"
  rm -f "${wonce}"
  _bgp_true_on_second_call() {
    [[ -e "${wonce}" ]] && return 0
    : > "${wonce}"
    return 1
  }
  ( exit 0 ) & wpid=$!
  wait "${wpid}" 2>/dev/null || true
  rc=0; bgp_wait_until "${wpid}" 10 1 -- _bgp_true_on_second_call || rc=$?
  _check "W3b the post-death re-check is what returns 0" 0 "${rc}"

  # --- (W4) A live, silent process runs into the DEADLINE (3): the loop is
  #     provably bounded, so a lost handshake can never hang the lane.
  : > "${wlog}"
  ( sleep 30 ) & wpid=$!
  rc=0; bgp_wait_until "${wpid}" 2 1 \
    -- bgp_marker_present "${wlog}" "${READY_MARKER}" || rc=$?
  kill "${wpid}" 2>/dev/null || true; wait "${wpid}" 2>/dev/null || true
  _check "W4 a silent live process hits the deadline (3)" 3 "${rc}"

  # --- (W5) REGRESSION (CI run 35397118356's window): the deadline is WALL
  #     CLOCK, so the time the PREDICATE spends counts against it. Every real
  #     poll runs a container sweep, and a loop that summed only its own
  #     sleeps handed that time back: the DISARM wait spent 216.8-222.0 s on a
  #     210 s budget in five CI runs, each of those seconds one more second
  #     the app is suspended with no execution claim and one less of margin
  #     to the 228 s kind-445 expiration P3's re-fetch has to beat.
  #
  #     A 2 s predicate against a 4 s deadline at a 1 s poll: wall clock
  #     returns at t=5 (predicate, no deadline yet, sleep, predicate, 5 >= 4),
  #     the summed-sleeps loop at t=14 (it needs FOUR sleeps to reach 4). The
  #     threshold is halfway between, so both readings are 4-5 s clear of it
  #     and only a loop that stopped measuring wall clock can cross it.
  _bgp_slow_false_predicate() {
    sleep 2
    return 1
  }
  local w5_start w5_elapsed
  ( sleep 30 ) & wpid=$!
  w5_start="$(bgp_now)"
  rc=0; bgp_wait_until "${wpid}" 4 1 -- _bgp_slow_false_predicate || rc=$?
  w5_elapsed=$(( $(bgp_now) - w5_start ))
  kill "${wpid}" 2>/dev/null || true; wait "${wpid}" 2>/dev/null || true
  _check "W5 a slow predicate still ends on the deadline (3)" 3 "${rc}"
  _check "W5b the deadline is wall clock, not a sum of sleeps" 'within' \
    "$( (( w5_elapsed <= 9 )) && echo within || echo "over (${w5_elapsed}s)" )"

  # --- (W6) The DISARM budget is measured from the drive's OWN disable
  #     append, not from the poll that read it — and the correction is
  #     one-sided. `bgp_budget_after_lag` may only ever hand back the lag this
  #     script introduced; an anchor it cannot trust leaves the budget whole,
  #     because a budget that came out too SMALL re-foregrounds Haven inside
  #     the settle window and reds P3 for an app that did nothing wrong.
  local w6_now
  w6_now="$(bgp_now)"
  got="$(bgp_budget_after_lag "$(( w6_now - 4 ))" 210 10)"
  _check "W6 a 4 s observation lag comes off the budget" 206 "${got}"
  got="$(bgp_budget_after_lag "$(( w6_now - 10 ))" 210 10)"
  _check "W6b a lag of exactly the cap still counts" 200 "${got}"
  got="$(bgp_budget_after_lag "$(( w6_now - 11 ))" 210 10)"
  _check "W6c a lag past the cap is not trusted (whole budget)" 210 "${got}"
  got="$(bgp_budget_after_lag "$(( w6_now + 30 ))" 210 10)"
  _check "W6d an anchor in the FUTURE is not trusted" 210 "${got}"
  got="$(bgp_budget_after_lag '' 210 10)"
  _check "W6e an unreadable anchor is not trusted" 210 "${got}"

  # --- (W7) …and the anchor is the mtime of the signal that CARRIES the
  #     marker. A sweep that returned the first signal it found would anchor
  #     P3's wake-up on a container the drive stopped writing to (the rotation
  #     S1 exists for), and a marker-blind read would anchor it on READY —
  #     minutes early, so the wake-up would land inside the settle window.
  local w7root="${tmp}/anchor/Containers/Data/Application"
  mkdir -p "${w7root}/AAAA/tmp" "${w7root}/BBBB/tmp"
  printf '%s\n' "${READY_MARKER}" > "${w7root}/AAAA/tmp/${SIGNAL_NAME}"
  printf '%s\n%s\n' "${READY_MARKER}" "${DISABLED_MARKER}" \
    > "${w7root}/BBBB/tmp/${SIGNAL_NAME}"
  # The abandoned container's own mtime is dated away from this second, so a
  # read that returned the first signal it found rather than the one carrying
  # the marker cannot pass by landing on the same whole second as the right
  # answer. `touch -t` is the one spelling BSD and GNU share.
  touch -t 202001010000 "${w7root}/AAAA/tmp/${SIGNAL_NAME}"
  got="$(bgp_signal_mtime_with "${w7root}" "${SIGNAL_NAME}" \
           "${DISABLED_MARKER}" || true)"
  _check "W7 the anchor is the mtime of the signal carrying the marker" \
    "$(bgp_file_mtime "${w7root}/BBBB/tmp/${SIGNAL_NAME}")" "${got}"
  rc=0
  bgp_signal_mtime_with "${w7root}" "${SIGNAL_NAME}" "${DISARMED_MARKER}" \
    >/dev/null || rc=$?
  _check "W7b a marker nothing carries yields no anchor" 1 "${rc}"
  # The read under all of that, against a mtime this fixture SET rather than
  # against itself: W7 compares one call with another and so cannot see a
  # spelling that answers with something other than the file's own time.
  # TZ-pinned, so the literal is the epoch and not this runner's timezone.
  local w7fixed="${tmp}/anchor/fixed-mtime"
  : > "${w7fixed}"
  TZ=UTC touch -t 202001010000 "${w7fixed}"
  _check "W7c the mtime read answers with the file's own epoch seconds" \
    1577836800 "$(bgp_file_mtime "${w7fixed}")"
  _check "W7d an unreadable path yields no mtime at all" \
    '' "$(bgp_file_mtime "${tmp}/anchor/no-such-file")"

  # --- (W8) The app-liveness read the settle-window diagnosis rests on. It
  #     must distinguish a process that is there from one that is not, and
  #     must say `unknown` rather than `gone` when it has no device to ask
  #     about — a confident wrong answer here would blame iOS for a drive that
  #     died on its own.
  local w8_udid='DEAD-BEEF-0000-1111-222233334444'
  local w8_app="${tmp}/Devices/${w8_udid}/data/Containers/Bundle/A/Runner.app"
  got="$(bgp_app_process_state "${w8_udid}")"
  _check "W8 no such process reads 'gone'" 'gone' "${got}"
  # A real executable at a real path, because `sh -c '<one command>'` execs
  # that command and the argv this read matches on would be gone with it.
  mkdir -p "${w8_app}"
  printf '#!/bin/sh\nsleep 30\n' > "${w8_app}/Runner"
  chmod +x "${w8_app}/Runner"
  "${w8_app}/Runner" & local w8pid=$!
  # The child must be in the process table before the read: `pgrep` against a
  # fork that has not exec'd yet reports 'gone' for a live process, which
  # would make this fixture the flake it exists to prevent. Bounded, so a
  # child that never starts fails the check instead of hanging the suite.
  local w8_waited=0
  until pgrep -f "${w8_app}/Runner" >/dev/null 2>&1 || (( w8_waited >= 50 )); do
    sleep 0.1
    w8_waited=$(( w8_waited + 1 ))
  done
  got="$(bgp_app_process_state "${w8_udid}")"
  kill "${w8pid}" 2>/dev/null || true; wait "${w8pid}" 2>/dev/null || true
  _check "W8b a live process under the device's bundle tree reads 'running'" \
    'running' "${got}"
  got="$(bgp_app_process_state '')"
  _check "W8c no device reads 'unknown', never 'gone'" 'unknown' "${got}"

  # --- (W9) …and a read that never saw the app when it was ALIVE reports
  #     nothing at all afterwards. The pattern it matches is the simulator's
  #     argv layout to change; a `gone` derived from a read that was already
  #     blind would blame iOS for reclaiming an app that never went anywhere,
  #     and send the next reader straight past the drive's own failure.
  got="$(bgp_calibrated_app_state 'running' 'gone')"
  _check "W9 a calibrated read's 'gone' stands" 'gone' "${got}"
  got="$(bgp_calibrated_app_state 'gone' 'gone')"
  _check "W9b an uncalibrated read reports 'unknown', not 'gone'" 'unknown' \
    "${got}"
  got="$(bgp_calibrated_app_state 'running' 'running')"
  _check "W9c a calibrated read's 'running' stands" 'running' "${got}"

  # --- (S1) REGRESSION (CI run 32618134993): the drive's own install ROTATES
  #     the app's data container, so the container that exists when this
  #     script resolves one is not the container the drive ends up writing
  #     into. The handshake must therefore find the signal in ANY container
  #     under the app-data root. Nothing above can see this — every W fixture
  #     hands the wait the very file its writer used, which is precisely the
  #     assumption the rotation breaks.
  local sroot="${tmp}/Containers/Data/Application"
  mkdir -p "${sroot}/AAAA/tmp" "${sroot}/BBBB/tmp"
  printf '%s\n' "${READY_MARKER}" > "${sroot}/BBBB/tmp/${SIGNAL_NAME}"
  rc=0
  bgp_marker_present_under "${sroot}" "${SIGNAL_NAME}" "${READY_MARKER}" || rc=$?
  _check "S1 a signal in a ROTATED container is still found" 0 "${rc}"

  # --- (S1b) Non-vacuity for S1: sweeping many containers must not turn into
  #     "any signal satisfies any marker". A marker the drive has not written
  #     is still absent, so the DISARMED wait cannot be satisfied by the READY
  #     the same file already carries.
  rc=0
  bgp_marker_present_under "${sroot}" "${SIGNAL_NAME}" "${DISARMED_MARKER}" \
    || rc=$?
  _check "S1b an unwritten marker stays absent across containers" 1 "${rc}"

  # --- (S3) The stale-signal clear must sweep EVERY container. A retry's
  #     drive can be handed a container an EARLIER attempt's drive already
  #     wrote its READY into, and a leftover READY is matched on the first
  #     poll — backgrounding the app before the drive has even launched (run
  #     32553078705 attempt 2). Clearing only the container resolvable at
  #     clear time is not enough once rotation is in play.
  printf '%s\n' "${READY_MARKER}" > "${sroot}/AAAA/tmp/${SIGNAL_NAME}"
  printf '%s\n' "${READY_MARKER}" > "${sroot}/BBBB/tmp/${SIGNAL_NAME}"
  local stale
  while IFS= read -r stale; do
    [[ -n "${stale}" ]] || continue
    rm -f "${stale}"
  done < <(bgp_signal_paths "${sroot}" "${SIGNAL_NAME}")
  rc=0
  bgp_marker_present_under "${sroot}" "${SIGNAL_NAME}" "${READY_MARKER}" || rc=$?
  _check "S3 the stale-signal sweep clears EVERY container" 1 "${rc}"

  # --- (R1) The app-data root of a well-formed container is its parent.
  got="$(bgp_app_data_root \
    '/d/8E85/data/Containers/Data/Application/29407E44')"
  _check "R1 a well-formed container yields its Application root" \
    "/d/8E85/data/Containers/Data/Application" "${got}"

  # --- (R2) A container that is NOT directly under an Application root is
  #     REFUSED. This is the shape a dropped `dirname` produces, and it is the
  #     silent half of the CI-run-32618134993 bug: sweeping the container
  #     itself still finds that container's own signal (at depth 2 of 3), so
  #     every behavioural fixture stays green until the drive's install
  #     rotates the leaf out from under it.
  rc=0
  bgp_app_data_root \
    '/d/8E85/data/Containers/Data/Application/29407E44/tmp' >/dev/null || rc=$?
  _check "R2 a container off the Application root is REFUSED" 1 "${rc}"

  # --- (R3) STRUCTURAL: the real run derives its root through that helper,
  #     rather than assigning the container to APP_DATA_ROOT directly — the
  #     mutation R1/R2 cannot see, because it never calls the helper at all.
  body="$(sed -n '/^# --- The handshake signal path\./,/^# --- Drive/p' \
            "${BASH_SOURCE[0]}" | grep -v '^[[:space:]]*#')"
  rc=0
  [[ -n "${body}" ]] || rc=1
  grep -qF 'APP_DATA_ROOT="$(bgp_app_data_root "${APP_DATA_CONTAINER}")"' \
    <<<"${body}" || rc=1
  _check "R3 the real run derives its root through bgp_app_data_root" 0 "${rc}"

  # --- (N1) The signal's NAME is one literal shared with the Dart drive. The
  #     two halves cannot agree by construction — Dart writes the file, this
  #     script finds it — so a rename on one side costs a full READY_WAIT_SECS
  #     wait and a misleading diagnostic. Unlike the five proof markers, which
  #     the completion gate would catch, nothing else compares these.
  #     Fails CLOSED on an unreadable drive file (empty answer, mismatch
  #     reported) rather than letting `set -e` kill the run from inside the
  #     assignment — a fixture that aborts the suite is a fixture that never
  #     reports, and every fixture after it goes unrun.
  local dart_const
  dart_const="$(sed -n \
    's/^const String kHandshakeSignalFileName = .\(.*\).;$/\1/p' \
    "${SCRIPT_DIR}/../../../haven/integration_test/ios_bg_publish_test.dart" \
    2>/dev/null || true)"
  _check "N1 the Dart signal name matches SIGNAL_NAME" \
    "${SIGNAL_NAME}" "${dart_const}"

  # --- (N2) The DISABLED marker literal is shared with the Dart drive, and
  #     nothing else compares them. The five proof markers are cross-checked
  #     by the completion gate; this one is not, and a drift is SILENT and
  #     dangerous rather than merely slow: the host would stop timing P3's
  #     settle window from the disable and re-foreground only on the DISABLE
  #     deadline, minutes late — by which time a real leak has aged past the
  #     228 s kind-445 expiration, which the app's own relay client refuses
  #     on receipt, so the drive re-fetches silence and P3 passes having
  #     proved nothing.
  local dart_disabled
  dart_disabled="$(sed -n \
    's/^const String kDisabledMarker = .\(.*\).;$/\1/p' \
    "${SCRIPT_DIR}/../../../haven/integration_test/ios_bg_publish_test.dart" \
    2>/dev/null || true)"
  _check "N2 the Dart disable marker matches DISABLED_MARKER" \
    "${DISABLED_MARKER}" "${dart_disabled}"

  # --- (H1) STRUCTURAL: the real run must background the app by launching
  #     the overlay bundle. Every gate above reads a LOG, so none can see a
  #     lane whose background step was deleted — the drive would then fail
  #     its paused-wait, but the failure would blame the handshake instead
  #     of naming the missing step. Asserted over the function's own source
  #     with comment lines stripped, so prose ABOUT the launch cannot
  #     satisfy it.
  local body
  body="$(sed -n '/^bgp_background_app() {/,/^}/p' "${BASH_SOURCE[0]}" \
            | grep -v '^[[:space:]]*#')"
  rc=0
  grep -qF 'simctl launch "${SIM_UDID}" "${OVERLAY_BUNDLE_ID}"' <<<"${body}" \
    || rc=1
  # …and that the READY branch actually CALLS it. Pinning only the body leaves
  # `if ! bgp_background_app` one indirection away from being stubbed out while
  # this fixture still reports the background step present.
  local handshake
  handshake="$(sed -n '/^# --- The handshake\./,/^# --- The completion gate/p' \
                 "${BASH_SOURCE[0]}" | grep -v '^[[:space:]]*#')"
  grep -qF 'if ! bgp_background_app; then' <<<"${handshake}" || rc=1
  _check "H1 the background step launches the overlay app, and is called" \
    0 "${rc}"

  # --- (H2) The privacy grant is fail-closed. `|| true` on it would be this
  #     repo's recurring "guard passes vacuously" failure: an ungranted app
  #     stalls on an unanswerable CoreLocation prompt.
  body="$(sed -n '/^# --- Prepare the simulator/,/^# --- Drive/p' \
            "${BASH_SOURCE[0]}" | grep -v '^[[:space:]]*#')"
  rc=0
  grep -qF 'if ! xcrun simctl privacy "${SIM_UDID}" grant "${PRIVACY_SERVICE}" "${BUNDLE_ID}"' \
    <<<"${body}" || rc=1
  _check "H2 the privacy grant is fail-closed" 0 "${rc}"

  # --- (H3) The delegate must be told to skip its own uninstall, or the
  #     grant made above is erased before first launch and the drive stalls
  #     exactly as if H2 had been violated.
  body="$(sed -n '/^# --- Drive/,/^DRIVE_PID=/p' "${BASH_SOURCE[0]}" \
            | grep -v '^[[:space:]]*#')"
  rc=0
  grep -qF 'HAVEN_E2E_IOS_SKIP_UNINSTALL=1' <<<"${body}" || rc=1
  # …and is told which tier it is compiling for. Without the define the drive
  # fails closed (it has no default), so this only turns a 45-minute macOS red
  # into a two-second one — but that is the difference between a lane you can
  # fix and a lane people re-run.
  grep -qF 'HAVEN_BGP_EXPECT_TIER="${EXPECT_TIER}"' <<<"${body}" || rc=1
  _check "H3 the delegate skips its own uninstall and gets the tier" 0 "${rc}"

  # --- (H4) STRUCTURAL: the live handshake must never be pointed back at
  #     SHARED_LOG. When a marker reaches that log is the test reporter's
  #     decision, not this script's — in CI run 32553078705 the drive's whole
  #     log materialised in one second, nine minutes after it was produced,
  #     because the `github` reporter holds a test's output until the test ends
  #     — so a marker in it is a post-mortem, not a stream, and a handshake
  #     reading it backgrounds the app only after the drive's own paused-wait
  #     has already failed. Nothing else
  #     here can see that regression: every marker fixture above passes
  #     against a file written promptly, which is precisely what SHARED_LOG
  #     is not.
  #     Scoped to the real run's handshake section, and narrowed to the WAIT
  #     CALLS in it, so neither this fixture's own needle nor the legitimate
  #     post-mortem `cp` of SHARED_LOG can decide the verdict.
  #
  #     It also pins WHAT the waits read: one `bgp_marker_present_under` per
  #     `bgp_wait_until`, each swept over the app-data ROOT. A wait repointed
  #     at a single pinned container is the CI-run-32618134993 regression (see
  #     `bgp_signal_paths`), and it looks perfectly healthy to every fixture
  #     above.
  #     Line continuations are JOINED first, so each wait is one line carrying
  #     its predicate AND its marker. Without that the marker checks below
  #     could not see a marker that sits on a continuation line, and the
  #     copy-paste this fixture exists to catch lives exactly there.
  body="$(sed -n '/^# --- The handshake\./,/^# --- The completion gate/p' \
            "${BASH_SOURCE[0]}" | grep -v '^[[:space:]]*#' \
            | sed -e ':a' -e '/\\$/{N; s/\\\n[[:space:]]*/ /; ta}' \
            | grep -F 'bgp_wait_until ' || true)"
  rc=0
  # Non-vacuity: an empty body would pass the checks below for free.
  [[ -n "${body}" ]] || rc=1
  grep -qF 'SHARED_LOG' <<<"${body}" && rc=1
  # A single-file read is the pinned-container regression, whatever it reads.
  grep -qF 'bgp_marker_present "' <<<"${body}" && rc=1
  # `|| true` on the counts: `grep -c` exits 1 on zero matches, and under
  # `set -e` that aborts the self-test MID-RUN — this fixture and H5 would
  # never report, leaving a deleted handshake to red the lane anonymously.
  local waits swept ready disabled disarmed
  waits="$(grep -cF 'bgp_wait_until ' <<<"${body}" || true)"
  swept="$(grep -cF 'bgp_marker_present_under "${APP_DATA_ROOT}"' <<<"${body}" \
             || true)"
  (( waits == 3 )) || rc=1
  (( waits == swept )) || rc=1
  # ONE wait per marker, and the three markers are all different. A DISARM
  # wait that reads READY_MARKER is the worst mutation this lane admits: READY
  # is already in the signal from the handshake, so the wait returns on its
  # first poll and the host re-foregrounds the app seconds after backgrounding
  # it — P2 then measures "publishes continue while backgrounded" against a
  # FOREGROUND app, every terminal proof still prints, and the lane goes green
  # having proved nothing. A DISARM wait keyed off DISABLED is the same shape
  # one phase later. No behavioural fixture can see either; only this can.
  ready="$(grep -cF '"${READY_MARKER}"' <<<"${body}" || true)"
  disabled="$(grep -cF '"${DISABLED_MARKER}"' <<<"${body}" || true)"
  disarmed="$(grep -cF '"${DISARMED_MARKER}"' <<<"${body}" || true)"
  (( ready == 1 )) || rc=1
  (( disabled == 1 )) || rc=1
  (( disarmed == 1 )) || rc=1
  _check "H4 each handshake wait sweeps the root for its OWN marker" 0 "${rc}"

  # --- (H5) STRUCTURAL: stale signals are cleared BEFORE the drive starts,
  #     and across EVERY container. The retry re-runs this script against the
  #     same device, so a READY left by the previous attempt is matched on the
  #     first poll — observed in run 32553078705 attempt 2, 63 ms after the
  #     seed step and before the drive had launched. The marker fixtures
  #     cannot see this: to them a present marker is a success. S3 proves the
  #     sweep clears every container; this proves the real run performs it,
  #     and performs it before the drive is launched.
  body="$(sed -n '/^echo "bg-publish — seeded an initial simulator fix"/,/^DRIVE_PID=/p' \
            "${BASH_SOURCE[0]}" | grep -v '^[[:space:]]*#')"
  rc=0
  grep -qF 'bgp_signal_paths "${APP_DATA_ROOT}" "${SIGNAL_NAME}"' <<<"${body}" \
    || rc=1
  grep -qF 'rm -f "${stale_signal}"' <<<"${body}" || rc=1
  _check "H5 every container's stale signal is cleared before the drive" 0 "${rc}"

  # --- (H6) STRUCTURAL: the simulated-location drip exists, MOVES, is started
  #     before the drive and is stopped on exit. CoreLocation suspends a
  #     backgrounded app it has nothing to deliver to (CI run 32646436116),
  #     and a suspended app publishes nothing — so a drip that was deleted,
  #     never started, or left re-setting ONE coordinate (a static fix
  #     locationd has no reason to re-deliver) reds the lane from the app's
  #     side, blaming the publish pipeline. Only the value comparison below can
  #     see the identical-points mutation.
  body="$(sed -n '/^bgp_location_drip() {/,/^}/p' "${BASH_SOURCE[0]}" \
            | grep -v '^[[:space:]]*#')"
  rc=0
  grep -qF 'xcrun simctl location "${SIM_UDID}" set "${next}"' <<<"${body}" \
    || rc=1
  grep -qF 'next="${DRIP_POINT_A}"' <<<"${body}" || rc=1
  grep -qF 'next="${DRIP_POINT_B}"' <<<"${body}" || rc=1
  [[ "${DRIP_POINT_A}" != "${DRIP_POINT_B}" ]] || rc=1
  body="$(sed -n '/^echo "bg-publish — seeded an initial simulator fix"/,/^DRIVE_PID=/p' \
            "${BASH_SOURCE[0]}" | grep -v '^[[:space:]]*#')"
  grep -qF 'bgp_location_drip &' <<<"${body}" || rc=1
  # Scoped to the real run: this fixture's own needles live above it, and a
  # whole-file grep would match them and pass over a deleted trap.
  body="$(sed -n '/^# Real run$/,$p' "${BASH_SOURCE[0]}" \
            | grep -v '^[[:space:]]*#')"
  grep -qF 'trap bgp_stop_drip EXIT' <<<"${body}" || rc=1
  _check "H6 the location drip moves, starts before the drive and is reaped" \
    0 "${rc}"

  # --- (H7) STRUCTURAL: ONE input decides the grant AND the compiled shape.
  #     The grant and the pin are the two halves the matrix rests on, and the
  #     failure they admit is silent: derive them separately, or default the
  #     tier, and the Always job runs the When-In-Use shape while every marker
  #     count and every behavioural fixture above stays green. U1 catches the
  #     mismatch only once a run has produced a log; this catches the shape
  #     that produces it. Scoped to the real run so the fixture's own needles
  #     cannot satisfy it.
  body="$(sed -n '/^# Real run$/,$p' "${BASH_SOURCE[0]}" \
            | grep -v '^[[:space:]]*#')"
  rc=0
  [[ -n "${body}" ]] || rc=1
  grep -qF 'HAVEN_BGP_AUTH_TIER}" =~ ^(when-in-use|always)$' <<<"${body}" || rc=1
  grep -qF 'PRIVACY_SERVICE="$(bgp_privacy_service "${AUTH_TIER}")"' \
    <<<"${body}" || rc=1
  grep -qF 'EXPECT_TIER="$(bgp_expected_tier_name "${AUTH_TIER}")"' \
    <<<"${body}" || rc=1
  grep -qF -- '--dart-define=HAVEN_BGP_EXPECT_TIER="${EXPECT_TIER}"' \
    <<<"${body}" || rc=1
  _check "H7 the grant and the compiled tier come from ONE validated input" \
    0 "${rc}"

  # --- (N3/N4) The Always job's marker and the tier define's NAME are shared
  #     with the Dart drive. The completion gate would eventually catch a
  #     renamed marker — as a 45-minute macOS red reporting an absence — and
  #     nothing at all compares the define name, whose drift shows up as the
  #     drive throwing on a value it never received. Both are two-second
  #     checks here. Same fail-closed sed as N1/N2: an unreadable drive file
  #     yields an empty answer and a reported mismatch.
  local dart_always dart_define_name
  dart_always="$(sed -n \
    's/^const String kAlwaysSessionMarker = .\(.*\).;$/\1/p' \
    "${SCRIPT_DIR}/../../../haven/integration_test/ios_bg_publish_test.dart" \
    2>/dev/null || true)"
  _check "N3 the Dart always-session marker matches ALWAYS_MARKER" \
    "${ALWAYS_MARKER}" "${dart_always}"
  dart_define_name="$(sed -n \
    's/^const String kExpectedTierDefine = .\(.*\).;$/\1/p' \
    "${SCRIPT_DIR}/../../../haven/integration_test/ios_bg_publish_test.dart" \
    2>/dev/null || true)"
  _check "N4 the Dart tier-define name matches the one threaded here" \
    'HAVEN_BGP_EXPECT_TIER' "${dart_define_name}"

  # --- (N5) P2c's marker, for the same two-second reason as N3. C7 proves the
  #     gate DEMANDS it; this proves the literal it demands is still the one the
  #     drive prints, so a rename costs a failing fixture here instead of a
  #     45-minute macOS red reporting a phase that ran perfectly well.
  local dart_receive
  dart_receive="$(sed -n \
    's/^const String kBackgroundReceiveMarker = .\(.*\).;$/\1/p' \
    "${SCRIPT_DIR}/../../../haven/integration_test/ios_bg_publish_test.dart" \
    2>/dev/null || true)"
  _check "N5 the Dart background-receive marker matches RECEIVE_MARKER" \
    "${RECEIVE_MARKER}" "${dart_receive}"

  # --- (N6) P2d's marker, same argument as N5 one leg over. PF2 proves the
  #     poll leg's gate DEMANDS it; this proves the literal it demands is the
  #     one the drive's flag-off branch prints.
  local dart_catchup
  dart_catchup="$(sed -n \
    's/^const String kBackgroundCatchupMarker = .\(.*\).;$/\1/p' \
    "${SCRIPT_DIR}/../../../haven/integration_test/ios_bg_publish_test.dart" \
    2>/dev/null || true)"
  _check "N6 the Dart background-catchup marker matches CATCHUP_MARKER" \
    "${CATCHUP_MARKER}" "${dart_catchup}"

  # --- (N7) P3's in-flight grace. Two oracles now measure ONE window — the
  #     drive's event-id diff and this script's wire probe — and a grace that
  #     drifted between them would make them disagree about the app's own
  #     last in-flight tick: the drive tolerating it as a straggler while the
  #     host counted it as a leak, on a perfectly healthy run. The window's
  #     other end is a sum across two Dart files and is pinned by check 19 of
  #     scripts/ci/check_ios_background_publish.sh instead.
  local dart_grace
  dart_grace="$(sed -n \
    's/^const int _inFlightGraceSecs = \([0-9]*\);$/\1/p' \
    "${SCRIPT_DIR}/../../../haven/integration_test/ios_bg_publish_test.dart" \
    2>/dev/null || true)"
  _check "N7 the Dart in-flight grace matches LEAK_GRACE_SECS" \
    "${LEAK_GRACE_SECS}" "${dart_grace}"

  # --- (T1-T4) `bgp_secs_until`: the host's takeover of P3's settle window
  #     costs the lane no extra wall clock, and cannot sleep on a bad anchor.
  #     A target already past is 0 (the drive died late in the window), a
  #     future one is the remainder, and a remainder larger than what is left
  #     of the DISARM budget is CAPPED — without the cap a stale anchor from a
  #     previous attempt would hold the job for its whole span.
  _check "T1 a target already past waits for nothing" \
    0 "$(bgp_secs_until "$(( $(bgp_now) - 5 ))" 200)"
  _check "T2 a future target waits out the remainder" \
    30 "$(bgp_secs_until "$(( $(bgp_now) + 30 ))" 200)"
  _check "T3 a remainder past the budget is capped" \
    200 "$(bgp_secs_until "$(( $(bgp_now) + 9999 ))" 200)"
  _check "T4 an unreadable anchor waits for nothing" \
    0 "$(bgp_secs_until 'not-a-number' 200)"

  # --- (V1-V8) `bgp_p3_host_verdict`: what a drive that died INSIDE P3's
  #     settle window leaves behind. The whole point of this function is that
  #     it has no "unknown" outcome that reads as a pass — every fixture below
  #     differs from V1 by exactly one input, and every one of them must land
  #     on a verdict that is not `holds`.
  _check "V1 gone + silent wire + still gone + disable signalled => P3 holds" \
    'holds' "$(bgp_p3_host_verdict 0 gone gone 0)"
  _check "V2 a kind-445 inside the window => leak (P3 broken)" \
    'leak' "$(bgp_p3_host_verdict 0 gone gone 1)"
  _check "V3 an unreadable relay is NOT silence" \
    'unproven' "$(bgp_p3_host_verdict 0 gone gone 3)"
  _check "V4 a wire read with no control is NOT silence" \
    'unproven' "$(bgp_p3_host_verdict 0 gone gone 4)"
  _check "V5 the app still RUNNING at the drive's exit is the drive's own failure" \
    'unproven' "$(bgp_p3_host_verdict 0 running gone 0)"
  _check "V6 an uncalibrated liveness read proves nothing" \
    'unproven' "$(bgp_p3_host_verdict 0 unknown gone 0)"
  _check "V7 the app back at the window's end is a surviving background wake" \
    'relaunched' "$(bgp_p3_host_verdict 0 gone running 0)"
  _check "V8 no disable signal at all => no P3 verdict" \
    'unproven' "$(bgp_p3_host_verdict 3 gone gone 0)"

  # --- (X1-X3) `bgp_unexcused_proofs`: the completion gate's ONE excuse, and
  #     its exact width. A host-proved P3 excuses the two markers a reclaimed
  #     process could not print and nothing else, so a drive that also lost an
  #     earlier phase's proof still reds — which is what keeps this from being
  #     a way to buy a green with a truncated transcript.
  _check "X1 the two excusable proofs are excused" \
    "" "$(bgp_unexcused_proofs "${SILENCE_MARKER}
${DISARMED_MARKER}")"
  _check "X2 any other missing proof survives the excuse" \
    "${ARMED_MARKER}" "$(bgp_unexcused_proofs "${ARMED_MARKER}
${SILENCE_MARKER}
${DISARMED_MARKER}")"
  _check "X3 nothing missing stays nothing" "" "$(bgp_unexcused_proofs "")"

  # --- (H8) STRUCTURAL: the DISABLE deadline is SELECTED from LIVE_SYNC, and
  #     the two legs' values are different. Both halves matter. A run that
  #     always took the live-sync value would put the deadline past the poll
  #     leg's own drive Timeout, where it can never fire — so the WARN that
  #     names "P2 never finished" would be replaced by an anonymous drive
  #     Timeout, on exactly the runs that need the attribution. And two
  #     constants that had drifted back to the same number would make the
  #     selection a no-op while still reading as a per-leg one. Neither is
  #     visible to any behavioural fixture: this deadline only fires on a run
  #     that is already failing. Scoped to the real run so this fixture's own
  #     needles cannot satisfy it.
  body="$(sed -n '/^# Real run$/,$p' "${BASH_SOURCE[0]}" \
            | grep -v '^[[:space:]]*#')"
  rc=0
  [[ -n "${body}" ]] || rc=1
  grep -qF 'DISABLE_WAIT_SECS="${DISABLE_WAIT_LIVE_SYNC_SECS}"' <<<"${body}" \
    || rc=1
  grep -qF 'DISABLE_WAIT_SECS="${DISABLE_WAIT_POLL_SECS}"' <<<"${body}" || rc=1
  grep -qF "LIVE_SYNC}\" == 'true'" <<<"${body}" || rc=1
  [[ "${DISABLE_WAIT_LIVE_SYNC_SECS}" != "${DISABLE_WAIT_POLL_SECS}" ]] || rc=1
  _check "H8 the DISABLE deadline is per-leg and selected from LIVE_SYNC" \
    0 "${rc}"

  # --- (H9) STRUCTURAL: the wake-up that ends P3 is timed from the drive's
  #     OWN disable append. The real run must derive its budget through
  #     `bgp_budget_after_lag` off `bgp_signal_mtime_with … DISABLED_MARKER`
  #     and hand THAT to the wait, never the raw constant. W6 proves the
  #     arithmetic; only this proves the run uses it, and the mutation it
  #     catches — passing DISARM_WAIT_SECS again — is invisible to every
  #     behavioural fixture because both spellings are the same number on a
  #     runner with no observation lag, which is every runner but a loaded one.
  #     The anchor must also be read from the DISABLED marker: anchoring on
  #     READY is minutes early and would re-foreground Haven INSIDE the settle
  #     window, where a correct app publishes and P3 reds for it.
  rc=0
  [[ -n "${body}" ]] || rc=1
  grep -qF 'bgp_wait_until "${DRIVE_PID}" "${DISARM_BUDGET_SECS}"' \
    <<<"${body}" || rc=1
  grep -qF 'DISABLE_AT="$(bgp_signal_mtime_with "${APP_DATA_ROOT}" \' \
    <<<"${body}" || rc=1
  grep -qF '"${SIGNAL_NAME}" "${DISABLED_MARKER}" || true)"' <<<"${body}" \
    || rc=1
  grep -qF 'DISARM_BUDGET_SECS="$(bgp_budget_after_lag "${DISABLE_AT}" \' \
    <<<"${body}" || rc=1
  _check "H9 the DISARM wake-up is anchored on the disable append" 0 "${rc}"

  # --- (H10) STRUCTURAL: a drive that exits INSIDE P3's settle window is
  #     reported, and reported with the app's process state. That branch used
  #     to be a bare `:`, so CI run 35397118356 — iOS reclaiming the suspended
  #     app 42 s into the window — surfaced as a bare rc=79 over a transcript
  #     ending at the disable, indistinguishable from an assertion failure
  #     until someone parsed the simulator's own log. Nothing behavioural can
  #     see a missing diagnostic; only this can.
  local disarm_exit
  # `|| true` throughout: an empty match exits 1, and under `set -e` with
  # `pipefail` that would abort the whole suite mid-run — so a DELETED branch,
  # the very mutation this fixture exists for, would report nothing at all.
  disarm_exit="$(sed -n '/^    case "${DISARM_RC}" in$/,/^    esac$/p' \
                   "${BASH_SOURCE[0]}" \
                 | sed -n '/^      \*)$/,/^        ;;$/p' \
                 | grep -v '^[[:space:]]*#' || true)"
  rc=0
  [[ -n "${disarm_exit}" ]] || rc=1
  grep -qF 'bgp_app_process_state "${SIM_UDID}"' <<<"${disarm_exit}" || rc=1
  grep -qF 'bgp_calibrated_app_state' <<<"${disarm_exit}" || rc=1
  grep -qF "P3's settle window" <<<"${disarm_exit}" || rc=1
  # The calibration itself must be taken while the app is unarguably alive,
  # i.e. inside the READY branch and before the backgrounding. Taken later it
  # would read the very state it is supposed to qualify.
  local ready_probe bg_call
  ready_probe="$(grep -nF 'APP_PROBE_AT_READY="$(bgp_app_process_state' \
                   <<<"${body}" | cut -d: -f1 | head -n 1 || true)"
  bg_call="$(grep -nF 'if ! bgp_background_app; then' <<<"${body}" \
               | cut -d: -f1 | head -n 1 || true)"
  [[ -n "${ready_probe}" && -n "${bg_call}" ]] || rc=1
  if [[ -n "${ready_probe}" && -n "${bg_call}" ]]; then
    (( ready_probe < bg_call )) || rc=1
  fi
  _check "H10 a drive that dies inside the settle window is attributed" \
    0 "${rc}"

  # --- (H11) STRUCTURAL: the 'gone' branch can no longer END there. Before
  #     the host owned a wire oracle it printed a diagnosis and fell through
  #     to the drive's rc, so an app iOS reclaimed produced an unconditional
  #     red whose own message said P3 was "neither proved nor disproved" — an
  #     indeterminate result reported as a failure, which is a flaky lane by
  #     construction. The branch must now HOLD the window open (`bgp_secs_until`
  #     against the disable anchor plus the settle window) and hand the answer
  #     to the relay. Nothing behavioural can see this: V1-V8 prove the
  #     verdict function, and only this proves the run reaches it.
  rc=0
  [[ -n "${disarm_exit}" ]] || rc=1
  grep -qF 'RECLAIMED_INSIDE_WINDOW=1' <<<"${disarm_exit}" || rc=1
  grep -qF 'bgp_secs_until \' <<<"${disarm_exit}" || rc=1
  grep -qF 'DISABLE_AT:-0} + SETTLE_WINDOW_SECS' <<<"${disarm_exit}" || rc=1
  _check "H11 the reclaimed branch holds P3's window open instead of ending" \
    0 "${rc}"

  # --- (H12) STRUCTURAL: the wire oracle's window is derived from the SAME
  #     anchor and the SAME two constants the drive uses, and the verdict is
  #     taken from the function V1-V8 pin. A `--since` computed from `now`
  #     instead of the anchor would drift with the runner's load, and a probe
  #     called without `--until` would count the foreground publishes the
  #     host's own re-foreground provokes as leaks. The anchor itself goes too:
  #     the probe's second control reads the kind-445s from just before it, and
  #     without that argument it can only report `no verdict`.
  rc=0
  [[ -n "${body}" ]] || rc=1
  grep -qF 'bgp_wire_probe_rc "${DART_BIN}" "${RELAY_URL}" \' <<<"${body}" \
    || rc=1
  grep -qF '"$(( DISABLE_AT + LEAK_GRACE_SECS ))" \' <<<"${body}" || rc=1
  grep -qF '"$(( DISABLE_AT + SETTLE_WINDOW_SECS ))" \' <<<"${body}" || rc=1
  # Anchored as a whole line: `"${DISABLE_AT}"` also appears in the guard that
  # decides whether to ask at all, and a needle that matches there would pass
  # on a call that never passed the anchor.
  grep -qFx '        "${DISABLE_AT}"' <<<"${body}" || rc=1
  grep -qF 'P3_HOST_VERDICT="$(bgp_p3_host_verdict "${DISABLE_RC}" \' \
    <<<"${body}" || rc=1
  _check "H12 the wire verdict measures the drive's own window" 0 "${rc}"

  # --- (H13) STRUCTURAL: the instrument proves itself on the runner BEFORE
  #     the lane depends on it, and the completion gate's excuse has exactly
  #     one source. `P3_PROVEN_BY_HOST` may be set only under the `holds`
  #     verdict — assigned anywhere else it would excuse two proofs on a run
  #     that proved nothing — and the preflight must run the probe's own
  #     `--self-test`, because a probe that reads nothing answers "silent"
  #     for every relay there is (the lesson of the emulator-probe round: a
  #     fake proves nothing about behaviour nobody measured).
  rc=0
  [[ -n "${body}" ]] || rc=1
  grep -qF '"${DART_BIN}" "${WIRE_PROBE}" --self-test' <<<"${body}" || rc=1
  grep -qF 'MISSING_PROOFS="$(bgp_unexcused_proofs "${MISSING_PROOFS}")"' \
    <<<"${body}" || rc=1
  local proven_assignments
  proven_assignments="$(grep -cF 'P3_PROVEN_BY_HOST=1' <<<"${body}" || true)"
  [[ "${proven_assignments}" == '1' ]] || rc=1
  _check "H13 the probe proves itself first and the excuse has one source" \
    0 "${rc}"

  # --- (H14) STRUCTURAL: no verdict but `holds` can end in exit 0. Each of
  #     the other three has its own exit, so the lane's STATUS names what
  #     happened instead of handing back the drive's rc for the OS reclaim
  #     that preceded it — and the drive's rc is bypassed only under the
  #     proven flag. Delete any one of these and the outcome is still red
  #     today, which is exactly why nothing behavioural would notice the day
  #     the last one went.
  rc=0
  [[ -n "${body}" ]] || rc=1
  grep -qF 'if (( WIRE_LEAK == 1 )); then' <<<"${body}" || rc=1
  grep -qF 'if (( P3_RELAUNCHED == 1 )); then' <<<"${body}" || rc=1
  grep -qF 'if (( WIRE_UNREAD == 1 )); then' <<<"${body}" || rc=1
  grep -qF 'if (( P3_PROVEN_BY_HOST == 1 )); then' <<<"${body}" || rc=1
  _check "H14 every verdict but 'holds' has its own non-zero exit" 0 "${rc}"

  # --- (G1-G3) The flag-off arm CONTAINS. The workflow uploads this lane's
  #     log `if: failure()` and a leak is a failure, so unless the gate removes
  #     what it flagged the lane publishes the line it went red on. Driven
  #     through the REAL sourced gate with HAVEN_LOGSCAN pinned empty and a
  #     FAKE key-material floor: rc 1 removes every scanned log, rc 3 (nothing
  #     scannable) and rc 0 leave them, and the verdict comes back unchanged.
  local fake_scan="${tmp}/fake-scan.sh" gate_a gate_b want got
  printf '%s\n' '#!/usr/bin/env bash' 'exit "${FAKE_SCAN_RC}"' > "${fake_scan}"
  gate_a="${tmp}/gate-a.log"
  gate_b="${tmp}/gate-b.log"
  for want in 1 3 0; do
    printf 'a\n' > "${gate_a}"
    printf 'b\n' > "${gate_b}"
    rc=0
    HAVEN_LOGSCAN= HAVEN_LOGSCAN_PROFILE= SECRET_SCAN="${fake_scan}" FAKE_SCAN_RC="${want}" \
      HAVEN_LOGSCAN_BIN="${tmp}/no-such-binary" \
      bgp_scan_or_contain "${gate_a}" "${gate_b}" 2>/dev/null || rc=$?
    # One observation per verdict: "<rc> <a present> <b present>".
    got="${rc} $([[ -e "${gate_a}" ]] && echo 1 || echo 0) $([[ -e "${gate_b}" ]] && echo 1 || echo 0)"
    if (( want == 1 )); then
      _check "G1 a leak (rc 1) removes every scanned log" "1 0 0" "${got}"
    elif (( want == 3 )); then
      _check "G2 nothing scannable (rc 3) keeps the logs" "3 1 1" "${got}"
    else
      _check "G3 a clean scan (rc 0) keeps the logs" "0 1 1" "${got}"
    fi
  done

  # --- (G4) STRUCTURAL: the real run passes the preserved log AND the shared
  #     transcript through the gate — after the copy that preserves it, before
  #     the drive's exit code can end the script — and never echoes either.
  #     Scoped to the real run so this fixture's own needles cannot satisfy it.
  body="$(sed -n '/^# Real run$/,$p' "${BASH_SOURCE[0]}" \
            | grep -v '^[[:space:]]*#')"
  rc=0
  [[ -n "${body}" ]] || rc=1
  ! grep -qE '^(cat|head|tail) .*(BG_LOG|SHARED_LOG)' <<<"${body}" || rc=1
  local cp_line gate_line exit_line
  cp_line="$(grep -nF 'cp "${SHARED_LOG}" "${BG_LOG}"' <<<"${body}" | cut -d: -f1 | head -n 1)"
  gate_line="$(grep -nF 'bgp_scan_or_contain "${BG_LOG}" "${SHARED_LOG}"' <<<"${body}" | cut -d: -f1 | head -n 1)"
  exit_line="$(grep -nF 'exit "${DRIVE_RC}"' <<<"${body}" | cut -d: -f1 | head -n 1)"
  [[ -n "${cp_line}" && -n "${gate_line}" && -n "${exit_line}" ]] || rc=1
  if [[ -n "${cp_line}" && -n "${gate_line}" && -n "${exit_line}" ]]; then
    (( cp_line < gate_line && gate_line < exit_line )) || rc=1
  fi
  _check "G4 the real run gates the preserved log between the copy and the drive's exit" \
    0 "${rc}"

  # --- (G5) THE FLAG-ON CALL SITE. logscan-gate.sh's own --self-test proves
  #     what the gate does with its arguments; only this file can prove which
  #     it is handed: the job's profile, the fixed sidecar directory, this
  #     lane's own drive floor, both copies as ONE drive sink, and the report
  #     beside (never among) the uploaded files; the verdict comes back
  #     unchanged.
  local gate_argv="${tmp}/gate-argv" real_gate
  real_gate="$(declare -f logscan_gate)"
  logscan_gate() { printf '%s\n' "$@" > "${gate_argv}"; return "${FAKE_GATE_RC}"; }
  rc=0
  HAVEN_LOGSCAN=true HAVEN_LOGSCAN_PROFILE=host FAKE_GATE_RC=4 \
    bgp_scan_or_contain "${gate_a}" "${gate_b}" || rc=$?
  _check "G5 the flag-on arm hands the sourced gate the profile, this lane's drive floor, both copies and the report" \
    "4 host /tmp/haven-soak/needles --floor drive=${BGP_DRIVE_FLOOR} -- --sink drive=${gate_a},${gate_b} --report /tmp/ios-logscan/bg-publish.ndjson" \
    "${rc} $(tr '\n' ' ' < "${gate_argv}" | sed 's/ $//')"
  # --- (G5b) …and that floor stays DERIVED from the host skeleton the shared
  #     runner defines, rather than measured from a transcript's length: the
  #     delegate refuses anything above it, and the belt above — whose sink sums
  #     two copies of the same transcript — must pass the same number. 56 was
  #     half a measured capture, and what it used to catch is the scanner's
  #     proof_of_run now.
  local skeleton
  skeleton="$(sed -n -E 's/^readonly IOS_HOST_SKELETON_LINES=([0-9]+).*/\1/p' \
                "${SCRIPT_DIR}/run-ios-sim-scenario.sh")"
  rc=0
  [[ -n "${skeleton}" ]] \
    && (( BGP_DRIVE_FLOOR >= 1 && BGP_DRIVE_FLOOR <= skeleton )) || rc=1
  _check "G5b this lane's drive floor stays within the shared runner's host skeleton" 0 "${rc}"
  # --- (G7) THE PROFILE IS INFERRED, NEVER DEFAULTED. With the profile unset
  #     the gate is handed `proxy` under either recorder export alone and
  #     `host` under neither; every variable the inference reads is pinned on
  #     each call, so a lane's exported values cannot pick the answer.
  local spec label sentinel upstream want
  for spec in 'HAVEN_WIRE_SENTINEL alone|HAVEN_WIRE_SENTINEL:cafe||proxy' 'WIRE_UPSTREAM alone||ws://127.0.0.1:7777|proxy' 'neither export|||host'; do
    IFS='|' read -r label sentinel upstream want <<<"${spec}"
    rc=0
    HAVEN_LOGSCAN=true HAVEN_LOGSCAN_PROFILE= HAVEN_WIRE_SENTINEL="${sentinel}" WIRE_UPSTREAM="${upstream}" \
      FAKE_GATE_RC=0 bgp_scan_or_contain "${gate_a}" "${gate_b}" || rc=$?
    _check "G7 with no stated profile, ${label} infers ${want}" \
      "0 ${want}" "${rc} $(head -n 1 "${gate_argv}")"
  done
  eval "${real_gate}"

  # --- (G6) FAIL-CLOSED SHAPES: no soft `if [[ -x` scanner gate, no bare
  #     key-material floor call (the floor runs inside the wrapper), and the
  #     identifier arm is reachable — the sourced gate reads HAVEN_LOGSCAN.
  local floor='scan-logs-for-'
  floor+='secrets.sh'
  rc=0
  ! grep -qE 'if[[:space:]]+\[\[[[:space:]]+-x[[:space:]]' "${BASH_SOURCE[0]}" || rc=1
  ! grep -qF "${floor}" "${BASH_SOURCE[0]}" || rc=1
  declare -f logscan_gate | grep -q 'HAVEN_LOGSCAN' || rc=1
  _check "G6 no soft scanner gate, no bare floor call, and the HAVEN_LOGSCAN arm exists" \
    0 "${rc}"

  if (( checked != SELF_TEST_FIXTURES )); then
    echo "SELF-TEST FAIL: ran ${checked} fixture(s), expected ${SELF_TEST_FIXTURES}" >&2
    fail=1
  fi
  if (( fail != 0 )); then
    echo "run-ios-bg-publish.sh --self-test: FAILED" >&2
    return 1
  fi
  echo "run-ios-bg-publish.sh --self-test: all ${checked} fixtures passed (the" \
       "simctl probes report supported/unsupported/unparseable distinctly;" \
       "the marker parser is literal, prefix-tolerant and fails closed on" \
       "missing logs; the completion gate demands the four shared terminal" \
       "proofs plus the ONE its leg's receive plane owns — the burst's under" \
       "HAVEN_LIVE_SYNC=true, the 90 s catch-up timer's under false — refuses" \
       "the other plane's in both directions, never accepts READY in their" \
       "place, demands a further proof under the always tier, refuses that one" \
       "under when-in-use, and fails closed on a tier or a live-sync value it" \
       "does not recognise; the tier derivation maps one" \
       "input to both the grant and the compiled pin and refuses anything" \
       "else; the marker wait is bounded by WALL CLOCK rather than by its own" \
       "sleeps" \
       "and distinguishes a dead drive from a slow one, the re-check after" \
       "it included; P3's wake-up budget is measured from the drive's own" \
       "disable append, off the signal that CARRIES that marker, and refuses" \
       "an anchor that is stale, future-dated or unreadable rather than wake" \
       "the app early; the app-liveness read behind the settle-window" \
       "diagnosis tells a live process from a gone one, says 'unknown' rather" \
       "than guess, and disqualifies its own answer when it never saw the app" \
       "while the app was alive; the signal sweep survives the container" \
       "rotation the" \
       "drive's own install causes, stays marker-specific and clears every" \
       "container; the app-data root is derived AND validated; the signal" \
       "name, the disable marker, the always marker, the receive marker, the" \
       "catch-up marker, P3's in-flight grace and" \
       "the tier-define name still match the Dart drive's; a drive the OS" \
       "reclaimed inside P3's settle window ends on a PROVEN verdict and" \
       "never on an indeterminate one — silent wire plus a process that" \
       "stayed gone is the only shape that holds, a kind-445 inside the" \
       "window is a leak, a process that came back is a surviving background" \
       "wake, and an unreadable relay, a read with no control, an" \
       "uncalibrated liveness probe or a missing disable signal are each" \
       "'unproven' rather than a pass; the host's takeover of that window" \
       "waits out the remainder, caps a stale anchor and never sleeps on an" \
       "unreadable one; the completion gate's one excuse covers exactly the" \
       "two markers a dead process could not print and nothing else; and the" \
       "background step and its call, the per-wait markers, the fail-closed" \
       "grant, the uninstall" \
       "skip, the tier threaded to the delegate, the single validated tier" \
       "input, the per-leg DISABLE deadline, the anchored DISARM budget, the" \
       "attribution of a drive that dies inside the settle window, the" \
       "window the wire verdict measures, the probe's own preflight" \
       "self-test, the single source of that excuse, the own non-zero exit" \
       "every verdict but 'holds' has, and the" \
       "moving location drip are" \
       "structurally pinned; and the log-privacy gate is the floor alone when" \
       "HAVEN_LOGSCAN is unset, removing what it flags and nothing else, sits" \
       "between the log's preservation and the drive's exit with no echo of" \
       "either copy, hands the sourced gate the job's profile, this lane's own" \
       "drive floor — itself within the shared runner's host skeleton — both" \
       "copies and the report when the flag is on, and has" \
       "no soft or bare arm)."
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
# receive path is compiled into the artifact, so the calling STEP has to
# state it rather than inherit one (CI_HARDENING_BACKLOG.md A7).
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

# The DISABLE deadline is the one wait whose terms differ between the receive
# planes, because P2c and P2d are not the same phase (see the derivation above).
# Selected here rather than defaulted, so the poll leg cannot silently inherit a
# ceiling its own drive Timeout sits below.
if [[ "${LIVE_SYNC}" == 'true' ]]; then
  DISABLE_WAIT_SECS="${DISABLE_WAIT_LIVE_SYNC_SECS}"
else
  DISABLE_WAIT_SECS="${DISABLE_WAIT_POLL_SECS}"
fi
readonly DISABLE_WAIT_SECS

# The tier axis, declared per JOB by the matrix and mandatory for the same
# reason HAVEN_LIVE_SYNC is: it is compiled into the artifact (as
# HAVEN_BGP_EXPECT_TIER) as well as acted on here, so an unstated value would
# not be "neutral" — it would be a second When-In-Use job wearing the Always
# job's name.
if [[ -z "${HAVEN_BGP_AUTH_TIER:-}" ]]; then
  echo "ERROR: HAVEN_BGP_AUTH_TIER is not set. This script grants a" >&2
  echo "       CoreLocation tier and compiles the shape the drive pins, so" >&2
  echo "       the calling step must state 'when-in-use' or 'always'." >&2
  exit 2
fi
if [[ ! "${HAVEN_BGP_AUTH_TIER}" =~ ^(when-in-use|always)$ ]]; then
  echo "ERROR: HAVEN_BGP_AUTH_TIER must be exactly 'when-in-use' or 'always'" >&2
  echo "       (got '${HAVEN_BGP_AUTH_TIER}')." >&2
  exit 2
fi
readonly AUTH_TIER="${HAVEN_BGP_AUTH_TIER}"
# Both derived from that ONE value, through the two pure helpers, so the
# service granted below and the tier the drive pins can never disagree.
PRIVACY_SERVICE="$(bgp_privacy_service "${AUTH_TIER}")"
readonly PRIVACY_SERVICE
EXPECT_TIER="$(bgp_expected_tier_name "${AUTH_TIER}")"
readonly EXPECT_TIER

readonly REPO_ROOT="${SCRIPT_DIR}/../../.."
readonly HAVEN_DIR="${REPO_ROOT}/haven"
readonly SIM_RUNNER="${SCRIPT_DIR}/run-ios-sim-scenario.sh"

[[ -f "${HAVEN_DIR}/${SCENARIO_FILE}" ]] \
  || { echo "ERROR: drive target not found: ${HAVEN_DIR}/${SCENARIO_FILE}" >&2; exit 2; }
[[ -f "${SIM_RUNNER}" ]] \
  || { echo "ERROR: shared runner not found: ${SIM_RUNNER}" >&2; exit 2; }
# The scanner's findings reports go beside the uploaded files, never among them.
mkdir -p /tmp/ios-logscan

echo "iOS bg-publish lane — udid=${SIM_UDID} relay=${RELAY_URL}" \
     "live_sync=${LIVE_SYNC} tier=${AUTH_TIER} (grant=${PRIVACY_SERVICE}," \
     "pinned=${EXPECT_TIER})"

# --- Preflight: can THIS Xcode grant location privacy and seed a fix? -------
PRIVACY_USAGE="$(xcrun simctl help privacy 2>&1 || true)"
set +e
bgp_simctl_supports_location_privacy "${PRIVACY_USAGE}"
PRIV_RC=$?
set -e
case "${PRIV_RC}" in
  0)
    echo "bg-publish preflight — 'xcrun simctl privacy' offers the location service."
    ;;
  1)
    echo "ERROR: this runner's 'xcrun simctl privacy' does NOT list the" >&2
    echo "       'location' service, so no CoreLocation authorization can be" >&2
    echo "       granted and the app would sit on an unanswerable system" >&2
    echo "       prompt. Raise the runner image / Xcode version." >&2
    printf '%s\n' "${PRIVACY_USAGE}" | sed 's/^/       /' >&2
    exit 2
    ;;
  *)
    echo "ERROR: could not parse 'xcrun simctl help privacy' output — the" >&2
    echo "       preflight cannot tell 'unsupported' from 'the probe is" >&2
    echo "       broken', and guessing either way is worse than stopping." >&2
    printf '%s\n' "${PRIVACY_USAGE}" | sed 's/^/       /' >&2
    exit 2
    ;;
esac

LOCATION_USAGE="$(xcrun simctl help location 2>&1 || true)"
set +e
bgp_simctl_supports_location_set "${LOCATION_USAGE}"
LOC_RC=$?
set -e
case "${LOC_RC}" in
  0)
    echo "bg-publish preflight — 'xcrun simctl location' offers the 'set' action."
    ;;
  1)
    echo "ERROR: this runner's 'xcrun simctl location' does NOT offer a 'set'" >&2
    echo "       action, so locationd cannot be given a fix while the armed" >&2
    echo "       background session is live. 'simctl location ... set' has" >&2
    echo "       shipped since Xcode 14; raise the runner image / Xcode." >&2
    printf '%s\n' "${LOCATION_USAGE}" | sed 's/^/       /' >&2
    exit 2
    ;;
  *)
    echo "ERROR: could not parse 'xcrun simctl help location' output." >&2
    printf '%s\n' "${LOCATION_USAGE}" | sed 's/^/       /' >&2
    exit 2
    ;;
esac

# --- Preflight: does the wire oracle work ON THIS RUNNER? -------------------
# P3's verdict rests on this probe whenever iOS reclaims the app mid-window,
# and a probe that reads nothing answers "silent" for every relay there is. So
# it proves itself here, before anything depends on it — the same discipline
# start-wire-proxy.sh applies to the recording proxy. Its own fixtures are
# what make the proof worth having: a planted in-window event must RED, one
# second past the window must not, and an unread relay must never be reported
# as a silent one. The output is printed on failure, because a verifier that
# rejects without saying why is the failure this round started with.
[[ -f "${WIRE_PROBE}" ]] \
  || { echo "ERROR: the wire oracle is missing: ${WIRE_PROBE}" >&2; exit 2; }
DART_BIN="$(bgp_dart_bin)"
readonly DART_BIN
if [[ -z "${DART_BIN}" ]]; then
  echo "ERROR: no 'dart' on PATH and none beside 'flutter'. P3's host-side" >&2
  echo "       wire oracle cannot run, and without it a run where iOS" >&2
  echo "       reclaims the app inside the settle window has no verdict." >&2
  exit 2
fi
if ! PROBE_SELFTEST="$("${DART_BIN}" "${WIRE_PROBE}" --self-test 2>&1)"; then
  echo "ERROR: the settle-window wire probe failed its own self-test, so" >&2
  echo "       nothing it reports about P3 can be believed." >&2
  printf '%s\n' "${PROBE_SELFTEST}" | sed 's/^/       /' >&2
  exit 2
fi
unset PROBE_SELFTEST
echo "bg-publish preflight — the settle-window wire probe passed its own" \
     "self-test on this runner."

cd "${HAVEN_DIR}"

# --- Build ONCE. -------------------------------------------------------------
# The .app must exist BEFORE the grant, because `simctl privacy grant`
# resolves the bundle id against the simulator's installed apps. The
# delegated `flutter test` below rebuilds incrementally from the same derived
# data, so this costs one cold Xcode+Rust build for the lane rather than two.
#
# The build is deliberately NOT bounded here: a hung or failed build is
# deterministic, and the caller's retry timeout is the backstop (the same
# stance run-ios-sim-scenario.sh's first-test watchdog takes when it declines
# to watch the build).
echo "bg-publish — building the drive target once for the simulator ..."
flutter build ios \
  --simulator \
  --debug \
  --target "${SCENARIO_FILE}" \
  --dart-define=HAVEN_E2E_RELAY="${RELAY_URL}" \
  --dart-define=HAVEN_LIVE_SYNC="${LIVE_SYNC}" \
  --dart-define=HAVEN_BGP_EXPECT_TIER="${EXPECT_TIER}"

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
echo "bg-publish — built ${APP_PATH}"

# --- Prepare the simulator: uninstall -> install -> grant -> seed. -----------
# The uninstall is the hermetic wipe run-ios-sim-scenario.sh normally performs
# (a stale, differently-keyed haven_mdk.db in the data container fails every
# scenario deterministically); doing it HERE, before the grant, is what lets
# the grant survive to first launch.
xcrun simctl uninstall "${SIM_UDID}" "${BUNDLE_ID}" >/dev/null 2>&1 || true

if ! xcrun simctl install "${SIM_UDID}" "${APP_PATH}"; then
  echo "ERROR: could not install ${APP_PATH} on ${SIM_UDID}." >&2
  exit 2
fi

# The tier's own service, derived from HAVEN_BGP_AUTH_TIER by
# bgp_privacy_service — `location` for the When-In-Use job (the tier most
# users hold) and `location-always` for the Always one, whose subject is the
# confirmed-Always posture that removes the blue bar. A refused grant must be
# FATAL — `|| true` here would be another instance of the repo's recurring
# "guard passes vacuously" failure, presenting at runtime as an app hanging on
# a system prompt nobody can answer.
if ! xcrun simctl privacy "${SIM_UDID}" grant "${PRIVACY_SERVICE}" "${BUNDLE_ID}"; then
  echo "ERROR: 'xcrun simctl privacy ${SIM_UDID} grant ${PRIVACY_SERVICE}" >&2
  echo "       ${BUNDLE_ID}' failed. Authorization was never granted; the" >&2
  echo "       likeliest cause is the install above not having landed — the" >&2
  echo "       grant resolves the bundle id against INSTALLED apps." >&2
  exit 2
fi
echo "bg-publish — granted ${PRIVACY_SERVICE} to ${BUNDLE_ID}"

# The fix the app will actually publish: the drive runs the production
# location service, so a fixless locationd means no publishes and a red P2.
# Device state — it persists until `clear`/shutdown and survives the drive's
# own install. The VALUE is never asserted (P2/P3 count events, they do not
# read coordinates; B4 owns the coordinate-fidelity proof), so echoing it is
# harmless.
if ! xcrun simctl location "${SIM_UDID}" set "47.606209,-122.332069"; then
  echo "ERROR: 'xcrun simctl location ${SIM_UDID} set <lat>,<lon>' failed, so" >&2
  echo "       the simulator has no simulated position." >&2
  exit 2
fi
echo "bg-publish — seeded an initial simulator fix"

# --- The handshake signal path. ----------------------------------------------
# The host watches the app-data ROOT, not one container: the drive's own
# install rotates the leaf `<UUID>` (see `bgp_signal_paths`), so a path pinned
# here would name a directory nobody writes to. Resolving the container is
# still how the root is found, and is still FATAL on failure — the install and
# grant above already proved the bundle id resolves, so a failure here means
# the layout is not what this script understands, and a script that fell back
# to sweeping some other path would wait out READY_WAIT_SECS and never
# background the app: a vacuous handshake, exactly the failure mode this
# lane's guards exist to keep out.
if ! APP_DATA_CONTAINER="$(xcrun simctl get_app_container \
      "${SIM_UDID}" "${BUNDLE_ID}" data 2>/dev/null)" \
   || [[ -z "${APP_DATA_CONTAINER}" ]]; then
  echo "ERROR: 'xcrun simctl get_app_container ${SIM_UDID} ${BUNDLE_ID} data'" >&2
  echo "       returned nothing, so the host cannot find the file the drive" >&2
  echo "       writes to hand over the READY signal. Without it there is no" >&2
  echo "       handshake and the app would never be backgrounded." >&2
  exit 2
fi
readonly APP_DATA_CONTAINER
if ! APP_DATA_ROOT="$(bgp_app_data_root "${APP_DATA_CONTAINER}")"; then
  echo "ERROR: the app data container resolved to a path whose parent is not" >&2
  echo "       an .../Containers/Data/Application root, so this script cannot" >&2
  echo "       tell which directories the drive's rotated container may land" >&2
  echo "       in. Update bgp_app_data_root for the new simulator layout." >&2
  exit 2
fi
readonly APP_DATA_ROOT

# A signal left by a PREVIOUS attempt must never be read as this one's: the
# retry re-runs this script against the same device and matching a stale READY
# would background the app before the drive had even launched. Observed in CI
# run 32553078705 attempt 2, where the host "observed" READY 63 ms after the
# seed step. Swept across EVERY container, not just the one resolved above,
# because the rotation can hand this attempt's drive a container an earlier
# attempt's drive already wrote its READY into.
while IFS= read -r stale_signal; do
  [[ -n "${stale_signal}" ]] || continue
  rm -f "${stale_signal}"
done < <(bgp_signal_paths "${APP_DATA_ROOT}" "${SIGNAL_NAME}")
echo "bg-publish — handshake signal: ${SIGNAL_NAME} under ${APP_DATA_ROOT}" \
     "(any container; stale copies cleared)"

# bgp_background_app — the REAL background transition: launch Preferences
# over Haven so iOS fires applicationDidEnterBackground. The prior terminate
# is best-effort hygiene (a leftover Preferences from an earlier attempt
# would make the launch a no-op foregrounding of an already-front app).
# Returns non-zero when the launch itself failed.
bgp_background_app() {
  xcrun simctl terminate "${SIM_UDID}" "${OVERLAY_BUNDLE_ID}" >/dev/null 2>&1 || true
  xcrun simctl launch "${SIM_UDID}" "${OVERLAY_BUNDLE_ID}" >/dev/null 2>&1
}

# bgp_foreground_app — re-activate Haven after the drive's final marker so
# flutter_test's post-suite teardown gets real engine frames again
# (`simctl launch` on an already-running bundle activates it). Best-effort
# BY DESIGN: it aids teardown, it is never a gate, and the completion gate
# below owes nothing to it.
bgp_foreground_app() {
  xcrun simctl launch "${SIM_UDID}" "${BUNDLE_ID}" >/dev/null 2>&1 || true
}

# bgp_location_drip — alternate the simulated fix between the two DRIP_POINTs
# forever, so CoreLocation always has a delivery to make (see DRIP_SECS).
# Failures are swallowed per iteration: a transient simctl hiccup must not end
# the drip, and the app's own suspension detector is what reports a drip that
# stopped mattering.
bgp_location_drip() {
  local next="${DRIP_POINT_B}"
  while true; do
    sleep "${DRIP_SECS}"
    xcrun simctl location "${SIM_UDID}" set "${next}" >/dev/null 2>&1 || true
    if [[ "${next}" == "${DRIP_POINT_B}" ]]; then
      next="${DRIP_POINT_A}"
    else
      next="${DRIP_POINT_B}"
    fi
  done
}

DRIP_PID=""
bgp_stop_drip() {
  [[ -n "${DRIP_PID}" ]] && kill "${DRIP_PID}" >/dev/null 2>&1
  return 0
}
trap bgp_stop_drip EXIT

# Start the drip BEFORE the drive: the app's position stream must already be
# receiving deliveries when it is backgrounded, not start receiving them
# afterwards.
bgp_location_drip &
DRIP_PID=$!
echo "bg-publish — simulated-location drip every ${DRIP_SECS}s (two fixes ~5m" \
     "apart; CoreLocation suspends an app it has nothing to deliver to)"

# --- Drive (backgrounded so this script can run the handshake). --------------
# Delegated so the first-test watchdog, the narrowed retry gate (A6) and the
# log-privacy gate are inherited rather than reimplemented.
# HAVEN_E2E_IOS_SKIP_UNINSTALL=1 stops the shared runner's own uninstall from
# erasing the grant made above.
#
# HAVEN_LOGSCAN_DRIVE_FLOOR is this lane's own anti-vacuity floor, and it seals
# the manifest the belt below and the workflow's own scan step both read. Its
# derivation is at BGP_DRIVE_FLOOR above: the host skeleton, not a fraction of a
# transcript.
HAVEN_LIVE_SYNC="${LIVE_SYNC}" \
HAVEN_E2E_RELAY="${RELAY_URL}" \
HAVEN_E2E_IOS_SKIP_UNINSTALL=1 \
HAVEN_LOGSCAN_DRIVE_FLOOR="${BGP_DRIVE_FLOOR}" \
HAVEN_BGP_EXPECT_TIER="${EXPECT_TIER}" \
  bash "${SIM_RUNNER}" "${SCENARIO_FILE}" "${SIM_UDID}" &
DRIVE_PID=$!
readonly DRIVE_PID

# --- The handshake. ----------------------------------------------------------
set +e
bgp_wait_until "${DRIVE_PID}" "${READY_WAIT_SECS}" "${MARKER_POLL_SECS}" \
  -- bgp_marker_present_under "${APP_DATA_ROOT}" "${SIGNAL_NAME}" "${READY_MARKER}"
READY_RC=$?
set -e

# P3's host-side state, declared before the branches that may set it so every
# exit below reads a defined value rather than a `set -u` abort on the paths
# that never reached the settle window.
DRIVE_EXIT_APP_STATE=""
RECLAIMED_INSIDE_WINDOW=0
P3_PROVEN_BY_HOST=0
WIRE_LEAK=0
WIRE_UNREAD=0
P3_RELAUNCHED=0

case "${READY_RC}" in
  0)
    echo "bg-publish — READY signal observed; backgrounding the app by" \
         "launching ${OVERLAY_BUNDLE_ID} over it."
    # Calibrate the liveness read while the app is unarguably alive — READY
    # was written from inside it — so the settle-window diagnosis below knows
    # whether a later `gone` is the app dying or the read failing.
    APP_PROBE_AT_READY="$(bgp_app_process_state "${SIM_UDID}")"
    if ! bgp_background_app; then
      # Loud, but NOT a kill: the drive's own paused-wait fails in <=180s
      # with a message naming this step, so the lane reds with attribution
      # on both sides instead of an orphaned half-run.
      echo "ERROR: 'xcrun simctl launch ${SIM_UDID} ${OVERLAY_BUNDLE_ID}'" >&2
      echo "       failed — the app was never backgrounded. The drive's" >&2
      echo "       paused-wait will now fail and name this step." >&2
    fi
    # P2 runs here. The next thing this script must see is the drive
    # disabling background sharing — the instant the app loses its right to
    # execute in the background, and therefore the instant from which the
    # DISARM timer below has to be measured. Nothing to DO on it: the value
    # is when it arrives.
    set +e
    bgp_wait_until "${DRIVE_PID}" "${DISABLE_WAIT_SECS}" "${MARKER_POLL_SECS}" \
      -- bgp_marker_present_under "${APP_DATA_ROOT}" "${SIGNAL_NAME}" \
         "${DISABLED_MARKER}"
    DISABLE_RC=$?
    set -e
    # The budget for the wake-up below, ANCHORED on the drive's own append
    # rather than on the poll that noticed it. Unanchored is the full budget,
    # which is what every branch but the first one gets. The same anchor is
    # what the host's own wire verdict measures its window from, so it is read
    # ONCE into DISABLE_AT rather than twice into two possibly different
    # answers.
    DISABLE_AT=""
    DISARM_BUDGET_SECS="${DISARM_WAIT_SECS}"
    case "${DISABLE_RC}" in
      0)
        DISABLE_AT="$(bgp_signal_mtime_with "${APP_DATA_ROOT}" \
                        "${SIGNAL_NAME}" "${DISABLED_MARKER}" || true)"
        DISARM_BUDGET_SECS="$(bgp_budget_after_lag "${DISABLE_AT}" \
          "${DISARM_WAIT_SECS}" "${DISARM_ANCHOR_MAX_LAG_SECS}")"
        echo "bg-publish — disable signal observed; P3's settle window is" \
             "running. Re-foregrounding in at most ${DISARM_BUDGET_SECS}s."
        ;;
      3)
        echo "WARN: the drive signalled no ${DISABLED_MARKER} within" >&2
        echo "      ${DISABLE_WAIT_SECS}s, so P2 never finished. The DISARM" >&2
        echo "      wait below still runs; the drive's own P2 assertion is" >&2
        echo "      what reports the failure." >&2
        ;;
      *)
        : # 2 — the drive exited on its own; its rc is collected below.
        ;;
    esac

    # Wait for the drive's LAST marker, then re-foreground Haven. On the
    # deadline (3) the app is re-foregrounded ANYWAY, and here that is the
    # EXPECTED path rather than a rescue: the disable withdrew the app's
    # background keep-alive, so iOS is entitled to suspend it for the whole
    # settle window, and a suspended drive cannot re-fetch the relay. The
    # deadline is sized to land just after that window and well inside the
    # 228 s kind-445 expiration (see DISARM_WAIT_SECS). It also still un-wedges
    # a frame-bound teardown. On (2) the drive already exited.
    set +e
    bgp_wait_until "${DRIVE_PID}" "${DISARM_BUDGET_SECS}" \
      "${MARKER_POLL_SECS}" \
      -- bgp_marker_present_under "${APP_DATA_ROOT}" "${SIGNAL_NAME}" \
         "${DISARMED_MARKER}"
    DISARM_RC=$?
    set -e
    case "${DISARM_RC}" in
      0)
        echo "bg-publish — final signal observed; re-foregrounding ${BUNDLE_ID} for teardown."
        bgp_foreground_app
        ;;
      3)
        echo "bg-publish — no ${DISARMED_MARKER} within" \
             "${DISARM_BUDGET_SECS}s of the disable; re-foregrounding" \
             "${BUNDLE_ID} so the suspended drive can re-fetch the relay" \
             "and finish P3."
        bgp_foreground_app
        ;;
      *)
        # 2 — the drive exited on its own, INSIDE P3's settle window. This is
        # the one stretch of the lane where the app holds no execution claim
        # (that is the guarantee being proven), so it is also the one where
        # iOS can end the process under a drive that has printed every proof
        # but its last two. In CI runs 35397118356 and 35622556197 it did, and
        # the second one's sim-lifecycle.log names the mechanism exactly: the
        # disable released every CoreLocation claim, runningboardd invalidated
        # the assertion locationd held on the app one second later, the shared
        # FinishTask grace that replaced it expired ~30 s on, and RunningBoard
        # terminated the process for not invalidating it
        # (OS_REASON_RUNNINGBOARD 0x2182bad2 — no jetsam, no crash report, no
        # watchdog). That is iOS doing exactly what a healthy app with no
        # background claim invites, so it cannot be a red on its own.
        DRIVE_EXIT_APP_STATE="$(bgp_calibrated_app_state \
          "${APP_PROBE_AT_READY}" "$(bgp_app_process_state "${SIM_UDID}")")"
        echo "bg-publish — the drive exited INSIDE P3's settle window," \
             "before ${DISARMED_MARKER}, with the app process" \
             "'${DRIVE_EXIT_APP_STATE}'."
        if [[ "${DRIVE_EXIT_APP_STATE}" == 'gone' ]]; then
          # The OS reclaimed the app. Its in-process half of P3 is already
          # proven — the DISABLED marker is appended only AFTER the provider
          # and the publish scheduler have been asserted — and the half it
          # could not finish is the one the HOST can take over, because the
          # relay outlives the app. So this is not the end of the phase: wait
          # the rest of the window out (capped by the budget the wake-up it
          # replaces would have spent, so the lane costs no extra wall clock)
          # and let the wire answer below.
          RECLAIMED_INSIDE_WINDOW=1
          echo "      The OS reclaimed the suspended app, which is its right" \
               "once the disable removed the app's background claim. Holding" \
               "P3's window open from the host and asking the relay."
          SETTLE_SLEEP_SECS="$(bgp_secs_until \
            "$(( ${DISABLE_AT:-0} + SETTLE_WINDOW_SECS ))" \
            "${DISARM_BUDGET_SECS}")"
          if (( SETTLE_SLEEP_SECS > 0 )); then sleep "${SETTLE_SLEEP_SECS}"; fi
        else
          echo "      'running' means the drive died with its app still" >&2
          echo "      there, which is the drive's own failure and its" >&2
          echo "      transcript's to explain; 'unknown' means the liveness" >&2
          echo "      read was never calibrated, so neither reading is" >&2
          echo "      evidence. The device log's lifecycle daemons are the" >&2
          echo "      record either way (sim-lifecycle.log in this job's" >&2
          echo "      artifact). The drive's rc is collected below." >&2
        fi
        ;;
    esac

    # --- P3's WIRE verdict, taken by the HOST. --------------------------
    # Asked on EVERY path, not only the reclaimed one. The relay is the
    # ground truth for "did anything publish after consent was withdrawn",
    # it does not depend on the app surviving, and it is the only oracle in
    # this lane that would see a background RELAUNCH publishing. Running it
    # every time is also what keeps it honest: an oracle exercised only on
    # the rare path is an oracle nobody would notice had stopped reading.
    #
    # It runs AFTER the re-foreground above, deliberately. Not because the
    # window's events would age out of the relay — they do not; this relay
    # enforces the kind-445 NIP-40 expiration at INGEST only and never evicts
    # (see bgp_wait_until's note) — but because the wake-up above is sized
    # against that 228 s bound, so seconds spent before it come straight out of
    # the drive's own margin, while seconds spent after it cost nothing. A
    # foregrounded Haven publishes by design; those events are created past the
    # window and excluded by `--until`, and they are also why the probe's
    # pre-disable control has an upper bound of its own.
    WIRE_RC=''
    if [[ "${DISABLE_AT}" =~ ^[0-9]+$ ]] \
       && (( $(bgp_now) >= DISABLE_AT + SETTLE_WINDOW_SECS )); then
      set +e
      bgp_wire_probe_rc "${DART_BIN}" "${RELAY_URL}" \
        "$(( DISABLE_AT + LEAK_GRACE_SECS ))" \
        "$(( DISABLE_AT + SETTLE_WINDOW_SECS ))" \
        "${DISABLE_AT}"
      WIRE_RC=$?
      set -e
    else
      # No anchor, or the window has not elapsed — the second happens only
      # when the drive died with its app still there, which is already a
      # red. An unasked question is never an answer, so it is said and the
      # verdict stays `unproven`.
      echo "bg-publish — P3's settle window was not asked of the relay:" \
           "there is no disable anchor, or the window had not elapsed when" \
           "the drive ended."
    fi

    # Read ONCE, after the window: "did anything bring the app back while
    # nobody was allowed to?" is a different question from the one asked at
    # the drive's exit, and both feed the verdict.
    APP_STATE_AT_WINDOW_END="$(bgp_calibrated_app_state \
      "${APP_PROBE_AT_READY}" "$(bgp_app_process_state "${SIM_UDID}")")"
    P3_HOST_VERDICT="$(bgp_p3_host_verdict "${DISABLE_RC}" \
      "${DRIVE_EXIT_APP_STATE}" "${APP_STATE_AT_WINDOW_END}" "${WIRE_RC}")"
    case "${WIRE_RC}" in
      1) WIRE_LEAK=1 ;;
      0) : ;;
      '') : ;;
      *) WIRE_UNREAD=1 ;;
    esac
    if (( RECLAIMED_INSIDE_WINDOW == 1 )); then
      case "${P3_HOST_VERDICT}" in
        holds)
          P3_PROVEN_BY_HOST=1
          echo "bg-publish — P3 HOLDS on the wire: the app applied the" \
               "disable in-process, the OS reclaimed it, no kind-445 was" \
               "created for the whole settle window, and nothing brought" \
               "the process back."
          ;;
        relaunched)
          P3_RELAUNCHED=1
          echo "ERROR: P3 — the settle window ended with the app RUNNING" >&2
          echo "       again, although this script never launched it. A" >&2
          echo "       background wake that survives the withdrawal of" >&2
          echo "       consent is the defect this phase exists to catch." >&2
          ;;
        leak)
          : # reported by the probe, and turned into the exit status below.
          ;;
        *)
          echo "ERROR: P3 has NO verdict on this run. The OS reclaimed the" >&2
          echo "       app inside the settle window and the host's own wire" >&2
          echo "       oracle could not answer either, so the phase was" >&2
          echo "       neither proved nor disproved. That is a harness" >&2
          echo "       failure, not a product one: fix the oracle rather" >&2
          echo "       than the lane's expectations." >&2
          ;;
      esac
    fi
    ;;
  2)
    echo "bg-publish — the drive exited before signalling ${READY_MARKER};" \
         "collecting its exit code."
    ;;
  3)
    echo "ERROR: the drive wrote no ${READY_MARKER} to any ${SIGNAL_NAME}" >&2
    echo "       under ${APP_DATA_ROOT} within ${READY_WAIT_SECS}s. Not" >&2
    echo "       backgrounding. If the drive is healthy but slow, its own" >&2
    echo "       paused-wait will fail attributably; if it is wedged pre-test," >&2
    echo "       the shared runner's first-test watchdog owns it. If the" >&2
    echo "       drive's log DOES carry the marker, the two halves disagree" >&2
    echo "       about the signal's name or the tree it lands in (Dart:" >&2
    echo "       kHandshakeSignalFileName; here: SIGNAL_NAME)." >&2
    # Name the disagreement instead of leaving it to be re-diagnosed: the Dart
    # side writes to `Directory.systemTemp`, which is `<data container>/tmp` on
    # iOS. If the runtime resolves it elsewhere in the sandbox, the sweep above
    # cannot see it — so widen to the whole device data tree and say where.
    # `|| true`: under `set -e` a `find` that hits one unreadable directory
    # would abort the script mid-diagnostic, losing the message it exists to
    # print.
    FOUND_SIGNAL="$(find "${APP_DATA_ROOT%/Containers/Data/Application}" \
                      -maxdepth 8 -name "${SIGNAL_NAME}" 2>/dev/null \
                      | head -n 1 || true)"
    if [[ -n "${FOUND_SIGNAL}" && "${FOUND_SIGNAL}" == "${APP_DATA_ROOT}"/* ]]; then
      # INSIDE the swept tree: the sweep saw this file and rejected it, so the
      # disagreement is about CONTENT, not location. Saying "fix the path"
      # here would send the next maintainer after a bug that does not exist.
      echo "       The drive DID write ${FOUND_SIGNAL}, which this script" >&2
      echo "       swept and read — so the file exists but carries no" >&2
      echo "       ${READY_MARKER}: an empty, truncated or unflushed write," >&2
      echo "       or a drive that died between creating it and writing it." >&2
    elif [[ -n "${FOUND_SIGNAL}" ]]; then
      echo "       The drive DID write the signal, at ${FOUND_SIGNAL}, which" >&2
      echo "       is outside the app-data root this script sweeps. Teach" >&2
      echo "       bgp_app_data_root the tree Dart's systemTemp actually" >&2
      echo "       resolves into." >&2
    else
      echo "       No ${SIGNAL_NAME} exists anywhere on the device, so the" >&2
      echo "       drive never reached the handshake — look at its own" >&2
      echo "       output, not at this step." >&2
    fi
    ;;
esac

set +e
wait "${DRIVE_PID}"
DRIVE_RC=$?
set -e

# Preserve the log under this lane's own name for the artifact upload, before
# anything else can overwrite the shared path.
cp "${SHARED_LOG}" "${BG_LOG}" 2>/dev/null || true

# Both copies go through the gate BEFORE the drive's own verdict: a leak
# outranks whatever the drive reported, and a drive the outer timeout killed
# before its own scan leaves an unscanned transcript that the upload step would
# otherwise publish. On rc 1 the gate has removed both files; on rc 3 (nothing
# scannable) a failed drive keeps its own, more useful, exit code below.
SCAN_RC=0
bgp_scan_or_contain "${BG_LOG}" "${SHARED_LOG}" || SCAN_RC=$?
if (( SCAN_RC == 1 )); then
  exit 1
fi

# A LEAK outranks every other verdict here, including the drive's own rc: it
# is the one outcome that names a product defect rather than a harness one,
# and it is the same defect whichever oracle saw it first.
if (( WIRE_LEAK == 1 )); then
  echo "ERROR: P3 — kind-445 event(s) reached the relay INSIDE the settle" >&2
  echo "       window that follows disabling background sharing. Publishing" >&2
  echo "       must stop when the user withdraws consent (privacy Rule 10);" >&2
  echo "       the scheduler ticks every 72-168 s, so the window is a full" >&2
  echo "       max-jitter interval and this cannot be a straggler. The" >&2
  echo "       ${LEAK_GRACE_SECS}s in-flight grace already excludes a tick" >&2
  echo "       that had begun when the disable landed." >&2
  exit 1
fi

# A process that came BACK inside the window is the same class of defect one
# step removed: nothing may re-arm a background wake after consent is
# withdrawn. Its own exit, so the lane's status names it rather than handing
# back the drive's rc for the OS reclaim that preceded it.
if (( P3_RELAUNCHED == 1 )); then
  echo "ERROR: P3 — the app was reclaimed inside the settle window and was" >&2
  echo "       RUNNING again before it ended, with nothing on the host" >&2
  echo "       having launched it." >&2
  exit 1
fi

if (( DRIVE_RC != 0 )); then
  if (( P3_PROVEN_BY_HOST == 1 )); then
    # The drive's rc is the OS reclaiming its app inside P3's settle window,
    # not an assertion. Every proof but the two that phase owes was already
    # printed, and both of those have been answered from the host: the wire
    # by the probe above, the native session by the reclaim itself. Said out
    # loud, because a green that skipped two markers must never be silent
    # about which ones and why.
    echo "bg-publish — the drive exited rc=${DRIVE_RC} because iOS reclaimed" \
         "its app inside P3's settle window. P3 was proved from the host" \
         "instead; the two markers the dead process could not print are" \
         "excused by name below."
  else
    echo "ERROR: the iOS bg-publish drive failed (rc=${DRIVE_RC})." >&2
    exit "${DRIVE_RC}"
  fi
fi

# An oracle that could not read is not an oracle that found nothing. This is
# the harness failing, so it says so rather than naming P3.
if (( WIRE_UNREAD == 1 )); then
  echo "ERROR: P3's host-side wire oracle could not read the relay (or read" >&2
  echo "       it with no control), so the settle window has no verdict from" >&2
  echo "       this side. The probe proved itself on this runner in the" >&2
  echo "       preflight, so a failure here is about the relay or the run," >&2
  echo "       not about the instrument. Fail closed rather than read an" >&2
  echo "       unread relay as a silent one." >&2
  exit 1
fi
if (( SCAN_RC != 0 )); then
  echo "ERROR: ${BG_LOG} / ${SHARED_LOG} could not be scanned (rc=${SCAN_RC});" >&2
  echo "       a log the guard could not read is not a clean log." >&2
  exit 1
fi

# --- The completion gate (A3b). ----------------------------------------------
# The drive exited 0 — which is NOT the same as the drive having RUN.
# `flutter test` reports success over a body that was skipped
# (`skip: true`, `markTestSkipped`) or returned early, and the READY marker
# cannot see it: it is printed before P2/P3 run. Each proof below is printed
# only after the last assertion of its own phase, and the set demanded is this
# LEG's: four shared, one for the receive plane this build has, and one more
# under the Always tier that the When-In-Use legs must not produce.
MISSING_PROOFS="$(bgp_missing_proofs "${BG_LOG}" "${AUTH_TIER}" \
                    "${LIVE_SYNC}")"
# The ONE excuse this gate has, and it is not a widening: when the host proved
# P3 itself, the two markers a reclaimed process could not print are dropped
# from the demanded set BY NAME. Every other proof is still required, so a
# drive that stopped anywhere else still reds — and on every other run the set
# is untouched, because P3_PROVEN_BY_HOST is 0 there.
if (( P3_PROVEN_BY_HOST == 1 )); then
  echo "bg-publish — completion gate: excusing ${SILENCE_MARKER} and" \
       "${DISARMED_MARKER}; the host proved P3 from the relay after iOS" \
       "reclaimed the app. Every other proof is still demanded."
  MISSING_PROOFS="$(bgp_unexcused_proofs "${MISSING_PROOFS}")"
fi
readonly MISSING_PROOFS
if [[ -n "${MISSING_PROOFS}" ]]; then
  if (( P3_PROVEN_BY_HOST == 1 )); then
    echo "ERROR: the drive was reclaimed inside P3, and the proof(s) it is" >&2
    echo "       missing are NOT the two that excuses, so it had already" >&2
    echo "       stopped somewhere earlier" >&2
  else
    echo "ERROR: the drive exited 0 WITHOUT printing its terminal proof(s)" >&2
  fi
  echo "       for the ${AUTH_TIER} tier at live_sync=${LIVE_SYNC}:" >&2
  printf '%s\n' "${MISSING_PROOFS}" | sed 's/^/         missing: /' >&2
  echo "       This is NOT an assertion failure — a failed expect() makes" >&2
  echo "       the drive exit non-zero and is reported above with its own" >&2
  echo "       reason. Reaching here means the run finished CLEANLY without" >&2
  echo "       executing the body that would have printed the marker — a" >&2
  echo "       self-skip, an early return, a suite that ran nothing" >&2
  echo "       (CI_HARDENING_BACKLOG.md A3b), or a renamed marker. The" >&2
  echo "       literals live in this script and in haven/${SCENARIO_FILE};" >&2
  echo "       change them together. Log: ${BG_LOG}." >&2
  exit 1
fi

# The symmetric half: a proof this LEG must NOT have produced. Each of the three
# is reachable only from one compiled branch — ALWAYS_MARKER when
# HAVEN_BGP_EXPECT_TIER says `always`, RECEIVE_MARKER when the receive engine is
# compiled in, CATCHUP_MARKER when it is not — so finding the wrong one means
# what this script acted on and what the drive was BUILT with came from
# different values, and the job is measuring something other than its name.
UNEXPECTED_PROOFS="$(bgp_unexpected_proofs "${BG_LOG}" "${AUTH_TIER}" \
                       "${LIVE_SYNC}")"
readonly UNEXPECTED_PROOFS
if [[ -n "${UNEXPECTED_PROOFS}" ]]; then
  echo "ERROR: the ${AUTH_TIER}/live_sync=${LIVE_SYNC} run printed a proof" >&2
  echo "       only another leg's run can reach:" >&2
  printf '%s\n' "${UNEXPECTED_PROOFS}" | sed 's/^/         unexpected: /' >&2
  echo "       The grant this script performed (${PRIVACY_SERVICE}), the tier" >&2
  echo "       compiled into the drive (${EXPECT_TIER}) and the receive path" >&2
  echo "       it was built with (HAVEN_LIVE_SYNC=${LIVE_SYNC}) do not all" >&2
  echo "       describe one leg, so this job is not measuring the shape its" >&2
  echo "       name claims. The tier pair is derived from HAVEN_BGP_AUTH_TIER" >&2
  echo "       by bgp_privacy_service and bgp_expected_tier_name; the receive" >&2
  echo "       path is one --dart-define threaded from HAVEN_LIVE_SYNC. Fix" >&2
  echo "       the wiring, never the gate. Log: ${BG_LOG}." >&2
  exit 1
fi

# Leave the simulator clean for whatever step runs next.
xcrun simctl uninstall "${SIM_UDID}" "${BUNDLE_ID}" >/dev/null 2>&1 || true

echo ""
echo "bg-publish — PASSED (${AUTH_TIER}, live_sync=${LIVE_SYNC}):"
echo "     CoreLocation reported the pinned tier, the native session handler"
echo "     took that tier's posture, the backgrounded session ran at the 100 m"
echo "     accuracy profile, kind-445 publishes kept reaching the relay across"
echo "     a REAL OS background transition, and disabling background sharing"
echo "     while still backgrounded stopped publishing and disarmed the"
if [[ "${LIVE_SYNC}" == 'true' ]]; then
  echo "     session. The receive half: a burst decrypted a peer's location"
  echo "     and then held no standing subscription."
  echo "     NOT proven here: that no SOCKET is open between bursts (no oracle"
  echo "     exists for it in this lane — the Rust in-process tests own it),"
else
  echo "     session. The receive half, on the POLL path this leg exists for"
  echo "     (OD4-d): the 90 s background receive timer ran a catch-up sweep"
  echo "     from the backgrounded process and landed a peer's location in the"
  echo "     persisted last-known store."
  echo "     NOT proven here: anything about the burst plane, which this build"
  echo "     does not have; and not the C3 chokepoint that refuses a wake after"
  echo "     consent is withdrawn — host tests own that,"
fi
echo "     and, not provable on a simulator at all, that the shape survives"
echo "     hours of stationary wall clock on a device (M7 §6 item 0a,"
echo "     DEFERRED for want of hardware — still owed)."
if (( P3_PROVEN_BY_HOST == 1 )); then
  echo "     P3 on THIS run was proved from the host, not from the app: iOS"
  echo "     reclaimed the process inside the settle window (its right, once"
  echo "     the disable removed the background claim), so the relay answered"
  echo "     the silence and the reclaim itself answered the keep-alive — a"
  echo "     process iOS takes for an expired background assertion is one"
  echo "     that had already released its CoreLocation session. NOT proved"
  echo "     this way: that the release was PROMPT rather than merely done"
  echo "     before the OS acted — the drive's own disarm poll owns that, and"
  echo "     the other legs ran it."
fi
