/// Map shell for Haven.
///
/// The main container view that displays the map with a draggable bottom
/// sheet for circles and a floating settings button. Replaces the traditional
/// tab-based navigation with a map-centric interface.
library;

import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/constants/location.dart';
import 'package:haven/src/constants/profile_refresh_tiers.dart';
import 'package:haven/src/pages/map/map_page.dart';
import 'package:haven/src/providers/background_location_provider.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/debug_log_provider.dart';
import 'package:haven/src/providers/evolution_poller_provider.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/invitation_provider.dart';
import 'package:haven/src/providers/join_watcher_provider.dart';
import 'package:haven/src/providers/key_package_provider.dart';
import 'package:haven/src/providers/legacy_cutover_provider.dart';
import 'package:haven/src/providers/legacy_retraction_provider.dart';
import 'package:haven/src/providers/live_sync_provider.dart';
import 'package:haven/src/providers/locale_provider.dart';
import 'package:haven/src/providers/location_access_provider.dart';
import 'package:haven/src/providers/location_provider.dart';
import 'package:haven/src/providers/location_publish_scheduler_provider.dart';
import 'package:haven/src/providers/location_sharing_provider.dart';
import 'package:haven/src/providers/maintenance_scheduler_provider.dart';
import 'package:haven/src/providers/relay_preferences_provider.dart';
import 'package:haven/src/providers/resume_extras_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/providers/sharing_health_provider.dart';
import 'package:haven/src/services/background_burst_coordinator.dart';
import 'package:haven/src/services/background_idle_waiter.dart';
import 'package:haven/src/services/background_location_manager.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/foreground_liveness_probe.dart';
import 'package:haven/src/services/geolocator_location_service.dart';
import 'package:haven/src/services/identity_service.dart' show Identity;
import 'package:haven/src/services/live_sync_resubscriber.dart';
import 'package:haven/src/services/location_service.dart';
import 'package:haven/src/services/nostr_circle_service.dart';
import 'package:haven/src/services/nostr_relay_service.dart';
import 'package:haven/src/services/pending_leave_service.dart';
import 'package:haven/src/services/subscription_service.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:haven/src/utils/geo_distance.dart';
import 'package:haven/src/utils/profile_refresh_trigger.dart';
import 'package:haven/src/utils/profile_sync_trigger.dart';
import 'package:haven/src/widgets/circles/circles_bottom_sheet.dart';
import 'package:haven/src/widgets/common/dim_overlay.dart';
import 'package:haven/src/widgets/common/invitations_button.dart';
import 'package:haven/src/widgets/common/legacy_cutover_explainer_dialog.dart';
import 'package:haven/src/widgets/common/settings_button.dart';
import 'package:haven/src/widgets/debug/debug_log_overlay.dart';
import 'package:haven/src/widgets/map/map_status_banners.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A latch that lets concurrent callers share ONE run of an async build.
///
/// `MapShell` installs the live-sync re-subscriber from places that share no
/// lock — startup, the periodic heal backstop, and the resume heal — and all of
/// them park on the same `circlesProvider` read. Without this each would build
/// its own `LiveSyncResubscriber` over the one engine: two independent
/// serialization chains whose `stop()`/`start()` pairs interleave against a
/// shared session, which is exactly the hazard
/// `LiveSyncResubscriber.ensureRunning` exists to rule out (Security Rule 14),
/// and the loser's `circlesProvider` listener would leak — re-subscribing an
/// orphan on every circle-set change for the rest of the mount.
///
/// Extracted from `_MapShellState` rather than inlined so that invariant is
/// PROVABLE: `MapShell` reaches the Rust bridge in `initState` and cannot be
/// pumped in `flutter test` (CLAUDE.md), so an inline latch is only ever
/// assertable by reading the source.
@visibleForTesting
class SingleFlight<T> {
  Future<T>? _inFlight;

  /// Whether a run is currently in flight.
  bool get isBusy => _inFlight != null;

  /// Runs [body], or joins the run already in flight.
  ///
  /// The latch is assigned before [body] can yield — `??=` evaluates its
  /// right-hand side to completion of the SYNCHRONOUS prefix only — so a caller
  /// arriving during the first `await` joins instead of starting a second run.
  /// It is released when the run settles, INCLUDING when it throws, so a failed
  /// install is retried on the next tick rather than latched forever.
  Future<T> run(Future<T> Function() body) =>
      _inFlight ??= body().whenComplete(() => _inFlight = null);
}

/// Who holds a relay connection while this isolate is paused.
///
/// Three answers, because the pause has three genuinely different shapes — see
/// [MapShell.pausedRelayOwner], which decides between them.
enum PausedRelayOwner {
  /// Nobody, and both socket sets are closed at the pause instant.
  ///
  /// Background sharing is off: nothing publishes or receives while the app is
  /// away, on either platform, so a socket left open is a standing "this
  /// pubkey is online" signal with nothing to show for it.
  ///
  /// This value closes only the PUBLISH pool. The engine's own socket, its
  /// standing REQs and the crate's 55 s pinger belong to the other plane and
  /// are closed by the [MapShell.shouldStopLiveSyncOnPause] stop on the same
  /// branch — which is why that rule is not "Android", but "every pause except
  /// the one whose process keeps receiving".
  none,

  /// The Android foreground service's own isolate, which dials its own pool.
  ///
  /// This isolate still closes its socket at the pause instant — the handoff
  /// moves the MLS session (Rule 14), and the service does not reuse this
  /// isolate's connections.
  foregroundService,

  /// One [BackgroundBurstCoordinator] burst per publish tick.
  ///
  /// The socket is neither kept nor closed HERE: this branch hands EVERY iOS
  /// background pause to the coordinator, and the coordinator answers each
  /// with a teardown — the burst this pause drove, or the
  /// [BackgroundBurstCoordinator.closeIdle] it took instead when nothing was
  /// eligible or the last publish was still inside the overlap guard. Two
  /// owners of one plane would be worse than either alone: the pool shutdown
  /// at this call site is unawaited, so it could cut the socket while the
  /// coordinator's teardown is deliberately waiting on a commit ladder
  /// (Security Rule 13).
  ///
  /// R14: the burst rides the publish tick that already exists. Nothing on
  /// this branch may add a background timer of its own to reach it.
  burst,
}

/// Mirror of `RELAY_LIFECYCLE_OP_TIMEOUT_SECS` in
/// `haven-core/src/relay/live_sync/config.rs` — the engine's own bound on ONE
/// relay control-plane op.
const int _kRelayLifecycleOpSecs = 10;

/// How many [_kRelayLifecycleOpSecs]-bounded steps `pause_subscriptions` takes
/// before it reaches its uncapped Rule-13 publish drain: `unsubscribe_all`,
/// the leftover-subscription probe, the `RawSignal::Pause` marker send, and
/// the worker's ack of it.
///
/// The leftover SWEEP adds one more per REQ a partial `unsubscribe_all` left
/// registered, and the drain that follows has no cap at all — which is exactly
/// why [kOptOutBurstWait] is a bound and not an await.
const int _kPauseBoundedSteps = 4;

/// Mirror of `BURST_SETTLE_CAP_SECS` in the same Rust module — the cap on the
/// follow-on commit quiesce a burst holds its sockets open for.
const int _kBurstSettleCapSecs = 18;

/// Mirror of [kBurstPublishBudget] in seconds, so [kOptOutBurstWait] can be a
/// compile-time sum (`Duration.inSeconds` is not a const expression).
const int _kBurstPublishSecs = 10;

/// How long a mid-pause opt-out waits on a burst in flight before it pauses
/// the engine itself (C4).
///
/// Derived from the teardown a cancelled burst still owes, not chosen. Consent
/// is re-read between links, so what remains is at most:
///
///  * the single-attempt location publish it is already inside —
///    [_kBurstPublishSecs] (`LOCATION_PUBLISH_ATTEMPTS` is 1, so
///    `CONNECTION_TIMEOUT` 5 s + `LOCATION_ACK_WINDOW` 5 s);
///  * its own `settleBeforePause`, capped at [_kBurstSettleCapSecs]; and
///  * the BOUNDED prefix of its `pauseSubscriptions` —
///    [_kPauseBoundedSteps] × [_kRelayLifecycleOpSecs] = 40 s.
///
/// The last term used to be priced at a single 10 s relay OK wait, which is
/// the crate's per-relay `wait_for_ok` and not the engine's pause at all: the
/// pause spends four separately bounded lifecycle ops before it even reaches
/// the drain. At 38 s the wait therefore expired on HEALTHY bursts and the
/// direct pause below ran underneath one — the exact thing the wait exists to
/// avoid. Pinned to the Rust source by
/// `test/pages/map_shell_burst_wiring_test.dart`.
///
/// The uncapped publish drain that follows those four steps is deliberately
/// NOT priced: it is unbounded by design (Security Rule 13), and being
/// unpriceable is what makes a bound necessary rather than an await.
///
/// It bounds the WAIT, never the burst — see
/// [MapShell.releaseBurstPlaneOnOptOut].
const Duration kOptOutBurstWait = Duration(
  seconds:
      _kBurstPublishSecs +
      _kBurstSettleCapSecs +
      _kPauseBoundedSteps * _kRelayLifecycleOpSecs,
);

/// The main shell containing the map, bottom sheet, and floating controls.
///
/// This widget serves as the primary container for the Haven app, featuring:
/// - A full-screen map that extends edge-to-edge
/// - A draggable bottom sheet for viewing and selecting circles
/// - A dim overlay when the sheet is expanded
/// - A floating settings button in the top-right corner
class MapShell extends ConsumerStatefulWidget {
  /// Creates the map shell.
  const MapShell({super.key});

  /// Who owns a relay connection while this isolate is paused.
  ///
  /// This used to be a bool ("keep the socket warm?"), true only on the iOS
  /// background branch. P4 gave that branch an answer neither value describes:
  /// the socket is neither kept for the whole background window nor closed
  /// once at the pause — a [BackgroundBurstCoordinator] opens and closes it
  /// per publish tick. Flipping the bool to `false` would have said "closed at
  /// the pause", which is not what happens and would have made the ONE branch
  /// that behaves differently indistinguishable from the two that do not.
  ///
  /// It used to take the eligible set as a third input, so an account with
  /// nothing to publish fell through to [PausedRelayOwner.none]. That is no
  /// longer a case: the branch drives a burst or a
  /// [BackgroundBurstCoordinator.closeIdle], and the coordinator owns the
  /// close either way — see [PausedRelayOwner.burst] for why a second owner
  /// here would be worse than none.
  ///
  /// Exposed as a static so the pause decision is unit-tested without pumping
  /// the widget (which requires the Rust bridge).
  @visibleForTesting
  static PausedRelayOwner pausedRelayOwner({
    required bool backgroundSharingEnabled,
    required bool isIOS,
  }) {
    if (!backgroundSharingEnabled) return PausedRelayOwner.none;
    if (!isIOS) return PausedRelayOwner.foregroundService;
    return PausedRelayOwner.burst;
  }

  /// Whether entering the paused burst branch should drive a burst NOW instead
  /// of waiting for the publish scheduler to tick.
  ///
  /// [lastPublishAt] is the shell's own last one-shot publish (`null` before
  /// the first); [now] is the pause instant.
  ///
  /// Without this the branch pauses with a live engine, a standing REQ and an
  /// open socket until whichever circle ticks first — up to
  /// [kLocationUpdateInterval] plus jitter, i.e. the very "one continuous
  /// socket while backgrounded" the burst design removes. With it, at least
  /// half of all pauses close everything within seconds of going away.
  ///
  /// [kLocationPublishOverlapGuard] (60 s) is the app's existing "do not
  /// repeat a relay round-trip sooner than this" quantum — the same one
  /// `_guardedPublish` uses — so a pause that lands right after a resume or a
  /// motion publish does not re-send what was just sent. That makes it a
  /// derived bound, not a chosen one.
  ///
  /// Exposed as a static for the same reason the rules around it are.
  @visibleForTesting
  static bool shouldBurstImmediatelyOnPause({
    required DateTime? lastPublishAt,
    required DateTime now,
  }) =>
      lastPublishAt == null ||
      now.difference(lastPublishAt) > kLocationPublishOverlapGuard;

  /// Whether the publish machinery (the jittered send scheduler and the
  /// motion-trigger listener) should keep running while the app is paused.
  ///
  /// True only on the iOS background-sharing branch: the unified geolocator
  /// stream (created with `allowBackgroundLocationUpdates: true` the moment
  /// the toggle was enabled, necessarily while foregrounded) keeps the
  /// process fully executable in the background, so Dart timers keep firing
  /// and publishing continues on the normal cadence. Android hands
  /// publishing off to the foreground-service isolate instead, and with
  /// background sharing off the app must genuinely go idle.
  ///
  /// The branch this selects is also the ONLY one that may install the burst
  /// coordinator: the other three call `stopScheduling()`, which clears the
  /// scheduler's active flag, and both `BurstPublisher` methods hard-gate on
  /// it — a sink installed there would open a burst, wait out its backlog,
  /// publish nothing and pause.
  @visibleForTesting
  static bool shouldKeepPublishingWhilePaused({
    required bool backgroundSharingEnabled,
    required bool isIOS,
  }) => backgroundSharingEnabled && isIOS;

  /// Whether pausing should stop the live-sync engine outright.
  ///
  /// Every pause EXCEPT iOS-with-sharing-on, which is the one configuration
  /// where this paused process is itself the receiver — the burst plane owns
  /// the engine there and stopping it would end background delivery.
  ///
  /// Everywhere else nothing in this isolate needs the engine while the app is
  /// away, and leaving it up costs one standing WebSocket per relay, its
  /// standing REQs and the crate's 55 s pinger for the whole background window
  /// — a continuous "this pubkey is online" signal with nothing to show for
  /// it. On Android with sharing ON the stop is redundant but not skipped: the
  /// MLS handoff stops the engine first anyway (it holds its own `Arc` on the
  /// circle manager, so the foreground service cannot open the database until
  /// it lets go). The iOS sharing-OFF arm is the one this rule used to miss:
  /// `!isIOS` made it false there, so a user who had turned background sharing
  /// off still held every REQ and socket until the OS suspended the process.
  ///
  /// Stopping is the recoverable direction, which is why it is preferred to a
  /// pause here: `_healLiveSyncIfStopped()` restarts a STOPPED engine on every
  /// resume and on every heal tick, and `ensureRunning` short-circuits when it
  /// is already up. A paused engine is invisible to that path — `isRunning`
  /// stays true across a pause — and needs the separate repair
  /// [reanchorPausedEngine].
  ///
  /// Exposed as a static so the pause/resume decision is unit-tested without
  /// pumping the widget (which requires the Rust bridge).
  @visibleForTesting
  static bool shouldStopLiveSyncOnPause({
    required bool isIOS,
    required bool backgroundSharingEnabled,
  }) => !(isIOS && backgroundSharingEnabled);

  /// Whether a resume should re-anchor the live-sync engine's subscriptions.
  ///
  /// [lastReanchorAt] is `null` until the first one; [now] is the resume
  /// instant.
  ///
  /// The re-anchor runs AHEAD of the 30 s resume debounce (it is the only
  /// repair for a relay-`CLOSED` REQ, and behind the debounce the glance
  /// pattern reliably suppressed it), so it needs a throttle of its own or ten
  /// shade-pull glances become ten pool reconnects and ten 49-hour gift-wrap
  /// replays — see `_onResumed` for that cost in full.
  ///
  /// [kLocationPublishOverlapGuard] (60 s) is the app's existing "do not repeat
  /// a relay round-trip sooner than this" quantum, and it is numerically the
  /// resubscribe clock-skew window `GROUP_RESUBSCRIBE_BUFFER_SECS` as well — so
  /// a second re-anchor inside it re-queries a window the first already
  /// covered and can deliver nothing new. That makes 60 s a derived floor, not
  /// a chosen one.
  ///
  /// It is the throttle, not the whole decision, and its two callers use it in
  /// opposite directions on purpose. `_onResumed` EXEMPTS a paused engine from
  /// it, because "the first re-anchor already covered that window" is a
  /// statement about an engine that held its REQs, and a paused one held none.
  /// [reanchorPausedEngine] — which runs only for a paused engine — APPLIES
  /// it, because it is the periodic backstop behind that resume and must not
  /// spend a second pool reconnect and a second 49 h `#p` replay on the same
  /// repair the resume has just launched.
  ///
  /// Exposed as a static so the throttle is unit-tested without pumping the
  /// widget (which requires the Rust bridge).
  @visibleForTesting
  static bool shouldReanchorOnResume({
    required DateTime? lastReanchorAt,
    required DateTime now,
  }) =>
      lastReanchorAt == null ||
      now.difference(lastReanchorAt) > kLocationPublishOverlapGuard;

  /// Tears the burst plane down when background sharing is switched OFF while
  /// the app is paused (C4), leaving NO socket behind — unconditionally.
  ///
  /// Two states, and the difference is not cosmetic:
  ///
  ///  * [runningBurst] non-null — a burst is in flight, and the consent read
  ///    it re-runs between links already answers `false`, so it stops at its
  ///    next link and its own `finally` settles, pauses and shuts both pools.
  ///    Pausing underneath it instead would cut its ingest mid-replay and
  ///    shorten the settle that exists to keep a commit's OK from being lost.
  ///  * `null` — nothing was opened, so there is nothing to wait for.
  ///
  /// The wait is BOUNDED because the burst's settle ends in an uncapped
  /// publish-gauge wait (Security Rule 13, by design): a wedged one never
  /// completes, and an unbounded wait here would hold the opt-out open — with
  /// the socket still up — for the rest of the process's life. On expiry the
  /// pause and the pool shutdown are issued anyway, which is what makes "an
  /// opt-out leaves no socket" unconditional rather than conditional on the
  /// burst being healthy.
  ///
  /// Bounding the wait is NOT bounding the commit-critical work, and the
  /// distinction is the whole reason this is safe: `Future.timeout` cancels
  /// nothing, so the burst runs on to its own pause, and the direct pause
  /// taken on expiry cannot cut a commit between SEND and OK either — the
  /// engine's `pause_subscriptions` drains its in-flight publish gauge before
  /// it disconnects. The cost of expiry is at most a shortened follow-on
  /// quiesce window on a burst that was already ending.
  ///
  /// Both links run whatever the wait did: a burst that finished has already
  /// paused and shut the pool, and re-issuing an idempotent pause is a cheap
  /// price for not making the promise depend on the coordinator's own error
  /// handling.
  ///
  /// ## Why the two links are STARTED together
  ///
  /// They used to be sequential `await`s in independent try/catches, which
  /// contains a throw and nothing else. The wedge [kOptOutBurstWait] exists
  /// for is the engine's uncapped `wait_publishes_drained()` — and
  /// `pauseSubscriptions` enters that same wait, so a wedged engine meant the
  /// pool shutdown behind it never ran AT ALL: consent withdrawn, publish
  /// sockets open for the life of the process. Neither may be given a
  /// `.timeout(` (it cancels no Rust future — it would only let this return
  /// with a commit between SEND and OK, Security Rule 13, and is pinned
  /// against by `test/lints/commit_critical_no_timeout_test.dart`), so instead
  /// both are ISSUED before either is awaited. Independence is the bound.
  ///
  /// A static over injected collaborators, because this is the one edge that
  /// runs only while the process is PAUSED — `MapShell` cannot be pumped
  /// (CLAUDE.md), so this is what makes the promise testable at all.
  @visibleForTesting
  static Future<void> releaseBurstPlaneOnOptOut({
    required SubscriptionService engine,
    required Future<void> Function() shutdownPublishPool,
    Future<void>? runningBurst,
    Duration burstWait = kOptOutBurstWait,
  }) async {
    if (runningBurst != null) {
      try {
        await runningBurst.timeout(
          burstWait,
          onTimeout: () => debugPrint(
            '[MapShell] opt-out: the burst in flight has not settled within '
            '${burstWait.inSeconds}s — pausing the engine directly',
          ),
        );
      } on Object catch (e) {
        // Rule 8: the type only. The burst's own links log their causes.
        debugPrint('[MapShell] opt-out: burst failed: ${e.runtimeType}');
      }
    }
    // Both calls happen HERE, in one synchronous sweep, so neither can starve
    // the other however long it takes to answer.
    final links = <Future<void>>[
      _optOutLink('pause', () => engine.pauseSubscriptions()),
      _optOutLink('pool shutdown', shutdownPublishPool),
    ];
    await Future.wait(links);
  }

  /// Runs one opt-out teardown link, absorbing its failure.
  ///
  /// Each link owns a different socket, so a throw from one must not skip the
  /// other — and neither may escape: the opt-out is launched with `unawaited`
  /// from a `listenManual` callback, where an escaping error is an unhandled
  /// async error rather than a caught one.
  static Future<void> _optOutLink(
    String what,
    Future<void> Function() link,
  ) async {
    try {
      await link();
    } on Object catch (e) {
      // Rule 8: the type only — an FFI error string is remote text.
      debugPrint('[MapShell] opt-out $what failed: ${e.runtimeType}');
    }
  }

  /// Re-anchors the engine's subscriptions on resume, and AGAIN if a burst
  /// that was still in flight paused it underneath the foreground.
  ///
  /// [burstInFlight] is the coordinator's `runningBurst` read at the resume
  /// instant, `null` when no burst was running.
  ///
  /// Clearing the tick sink does not cancel a burst already on the chain, and
  /// the coordinator's own consent read (`burstEnabled`) cannot cancel it
  /// either — background sharing is still ON in the foreground. The
  /// coordinator therefore stops its teardown as soon as the foreground owns
  /// the engine, which makes the common case cost one `isPaused` read here.
  /// What that cannot stop is a `pauseSubscriptions` ALREADY under way when
  /// the resume landed: it completes, and it completes after the re-anchor
  /// below.
  ///
  /// Nothing else recovers that. `ensureRunning` reads `isRunning`, which
  /// stays true across a pause, so the periodic heal short-circuits;
  /// `_fullRestart` declines while paused; and
  /// `SharingHealthNotifier.refresh()` early-returns while paused — so the
  /// banner holds at its last verdict, "healthy", while the device receives
  /// nothing until the next full background→foreground cycle.
  ///
  /// The wait on [burstInFlight] is deliberately unbounded: a `Future.timeout`
  /// cancels nothing, so a bounded one would simply re-anchor into the same
  /// race again, and the only link that can still be running at that point is
  /// one of the engine's two uncapped Rule-13 drains, which must not be cut.
  ///
  /// A static over injected collaborators for the same reason its neighbours
  /// are: `MapShell` cannot be pumped (CLAUDE.md).
  @visibleForTesting
  static Future<void> reanchorOnResume({
    required SubscriptionService engine,
    Future<void>? burstInFlight,
  }) async {
    await _reanchor(engine);
    if (burstInFlight == null) return;
    try {
      await burstInFlight;
    } on Object catch (e) {
      debugPrint('[MapShell] resume: burst in flight failed: ${e.runtimeType}');
    }
    if (!engine.isPaused) return;
    debugPrint(
      '[MapShell] resume: a burst paused the engine behind the re-anchor — '
      're-anchoring again',
    );
    await _reanchor(engine);
  }

  /// Re-anchors an engine that is still PAUSED while the app is on screen, and
  /// reports whether it did — the caller records [now] as the last re-anchor
  /// when it did.
  ///
  /// ## The state this exists for
  ///
  /// [reanchorOnResume] gets ONE attempt. `resume_after_background` exhausts
  /// the engine's `SUBSCRIBE_MAX_ATTEMPTS` and gives up, and a burst's
  /// `resume_burst` deliberately re-pauses and stays silent on that failure —
  /// correct for a burst, whose next tick retries 72-168 s later, and wrong
  /// for a foreground that has no next tick. So a user returning while the
  /// radio is cold (a captive portal, a dead zone, a lock-screen unlock) lands
  /// foregrounded with a paused engine.
  ///
  /// Nothing else in the app sees that. `ensureRunning` reads `isRunning`,
  /// which a pause leaves TRUE; the subscription-health tick short-circuits on
  /// the paused state; a circle-set delta only stages into the engine's model
  /// while paused; and `_fullRestart` declines outright. Meanwhile publishing
  /// keeps acking on the SEPARATE publish pool, so the sharing banner stays
  /// green while the map receives nothing — for the whole foreground session,
  /// recoverable only by another background→foreground cycle.
  ///
  /// ## Why it is the heal tick that pays for it
  ///
  /// The heal timer is the only periodic thing that runs while foregrounded
  /// and is cancelled at every pause, so it is already exactly "while the app
  /// is on screen" and adds no background wake (R14). [foregrounded] is still
  /// required rather than assumed: `_startLiveSync` re-arms that timer from
  /// its own completion, which can land after a pause, and a re-anchor there
  /// would put a standing REQ back between bursts.
  ///
  /// Throttled on [shouldReanchorOnResume] against the same `_lastReanchorAt`
  /// the resume stamps, which is what stops the two racing: `_onResumed`
  /// records the instant BEFORE it launches its own re-anchor, so a heal
  /// running behind it declines, and the 90-150 s heal cadence is always
  /// outside the 60 s throttle by the time a repair is genuinely owed.
  @visibleForTesting
  static Future<bool> reanchorPausedEngine({
    required SubscriptionService engine,
    required bool foregrounded,
    required DateTime now,
    DateTime? lastReanchorAt,
  }) async {
    if (!foregrounded || !engine.isPaused) return false;
    if (!shouldReanchorOnResume(lastReanchorAt: lastReanchorAt, now: now)) {
      return false;
    }
    debugPrint(
      '[MapShell] heal: the engine is paused with the app on screen — '
      're-anchoring',
    );
    await _reanchor(engine);
    return true;
  }

  static Future<void> _reanchor(SubscriptionService engine) async {
    try {
      await engine.resumeAfterBackground();
    } on Object catch (e) {
      // Rule 8: the type only — an FFI error string can carry relay urls.
      debugPrint('[MapShell] resume re-anchor failed: ${e.runtimeType}');
    }
  }

  /// Issues [ticks] to [sink] as ONE burst — however many circles are in it.
  ///
  /// ## Why the head tick is issued alone
  ///
  /// `BurstSink.onTick` folds a circle into the burst that is RUNNING and
  /// QUEUES another one otherwise. Issued in one synchronous sweep, all N
  /// ticks find no burst running yet and queue a burst EACH — and a publish
  /// window that refuses (no identity, no accepted disclosure, a dead GPS)
  /// returns WITHOUT draining the due set, so bursts 2..N do not find it empty
  /// either. Measured at four circles on a refusal: four opens, four pauses,
  /// four pool cycles and four REQ sets, each replaying 49 hours of `#p`
  /// gift wraps, to publish nothing — on the branch this phase exists to make
  /// quiet. On success it was already one, which is what made it invisible.
  ///
  /// So the tail is issued from a continuation of the head: a burst queued on
  /// an idle chain starts on the next microtask, and one already in its
  /// publish pass folds them all in regardless.
  ///
  /// One residual is NOT closed here, because it cannot be from this side:
  /// ticks arriving while a burst is in its TEARDOWN (past joinable, chain
  /// still pending) queue behind it, and a refusal in the burst they queued
  /// costs one burst each again. That is fixed where the due set lives —
  /// `_publishPass` must drain it when the window refuses, exactly as
  /// `_runBurst` already does when consent is gone.
  ///
  /// A static over an injected [BurstSink] because `MapShell` cannot be pumped
  /// (CLAUDE.md), and "N ticks cost ONE burst" is a claim about a real
  /// coordinator rather than about the shape of a loop.
  @visibleForTesting
  static Future<void> queueOneBurst(
    BurstSink sink,
    List<({String key, Circle circle})> ticks,
  ) async {
    if (ticks.isEmpty) return;
    final head = ticks.first;
    final burst = sink.onTick(circleKey: head.key, circle: head.circle);
    if (ticks.length > 1) {
      await Future<void>.value();
      for (final tick in ticks.skip(1)) {
        unawaited(sink.onTick(circleKey: tick.key, circle: tick.circle));
      }
    }
    try {
      await burst;
    } on Object catch (e) {
      // The coordinator's chain absorbs its own errors, so this is defence in
      // depth against an unhandled async error on a lifecycle path. Rule 8:
      // the type only.
      debugPrint('[MapShell] immediate burst failed: ${e.runtimeType}');
    }
  }

  /// Reports a burst open to the sharing-health model: the RECEIVE plane's
  /// signals, never the send plane's.
  ///
  /// [consecutiveFailures] is `0` when the open succeeded. A failed open leaves
  /// the burst holding no subscription at all, so it ingests nothing — but it
  /// still publishes, over the separate publish pool, and those publishes
  /// genuinely get their relay acks. Recording it as a publish failure would
  /// make the banner name a plane that is working, and send the user to a
  /// remedy for a fault they do not have.
  ///
  /// A run of them is the silent failure this phase can produce: the device
  /// keeps publishing every 72-168 s while peers' commits pile up unread. So
  /// the first failure raises the subscription-lost onset (which the model
  /// confirms only after [kSharingFaultConfirmationWindow], so one transient
  /// open failure never reaches the user) and the first success clears it.
  @visibleForTesting
  static void recordBurstOpenOutcome(
    SharingHealthNotifier health,
    int consecutiveFailures,
  ) {
    if (consecutiveFailures == 0) {
      health.recordRelaySubscriptionRestored();
    } else {
      health.recordRelaySubscriptionLost();
    }
  }

  /// Vertical space the top-edge floating buttons occupy, measured from the
  /// safe-area inset: `HavenSpacing.sm` of offset plus the 48 dp Material
  /// minimum tap target that `IconButton` lays out to.
  static const double _kFloatingButtonExtent = HavenSpacing.sm + 48;

  /// Top offset of the status-banner slot, measured from the safe-area inset:
  /// clear of the floating buttons, with one spacing unit of air.
  static const double _kStatusBannerTop =
      _kFloatingButtonExtent + HavenSpacing.sm;

  /// The shell's overlay stack, bottom-most first — i.e. in both paint and
  /// (reverse) hit-test order.
  ///
  /// ## Why the status banner sits ABOVE the bottom sheet
  ///
  /// It used to sit below it, and that made the whole surface ineffective in a
  /// state users sit in routinely. `CirclesBottomSheet` paints an opaque
  /// `colorScheme.surface` and its snap ladder tops out at 0.85, so on a
  /// 390 x 844 phone (safe-area top 47) its top edge rests at y = 126.6 while
  /// the banner spans y = 111 to 319. Fifteen of its 208 dp were visible, the
  /// remedy button — which is at the BOTTOM of the card — was neither visible
  /// nor hit-testable, and a user browsing their member list was told nothing
  /// at all. Paint order was the entire cause: nothing about the geometry
  /// changed here.
  ///
  /// Ordering it above the sheet is safe with respect to everything that
  /// legitimately outranks it:
  ///
  ///   * `DimOverlay` is the sheet's own scrim and stays below, which is what
  ///     keeps the banner from being dimmed along with the map;
  ///   * `DebugLogOverlay` stays last, so a debug build's log still covers
  ///     everything; and
  ///   * dialogs, modal sheets and pushed routes live on the `Navigator`'s
  ///     overlay, which is above this entire `Stack` regardless of order.
  ///
  /// The cost is real and accepted: while a banner is up at the 0.85 detent it
  /// covers the sheet's grab handle and circle selector. The sheet stays
  /// draggable and scrollable from everywhere else, and the alternative —
  /// hiding a non-dismissible warning about the user's own sharing being dead
  /// because they happened to open a list — is the defect wearing a different
  /// hat.
  ///
  /// ## Why the banner slot is given a `bottom:`
  ///
  /// `top` + `start` + `end` alone leave the height unbounded, so the banners
  /// inside cannot bound themselves either: at a 200 % text scale the card is
  /// 652 dp on a 390 dp-wide phone and 788 dp at 320 dp, and with no bound it
  /// simply runs off the viewport — no overflow stripe, no exception, remedy
  /// button hundreds of dp below the fold. Adding `bottom:` bounds it; the
  /// `Align` re-loosens those constraints so the card still shrink-wraps at
  /// ordinary scales instead of stretching to fill the screen.
  ///
  /// Extracted as a pure static because `MapPage` reaches the Rust bridge in
  /// `initState` and cannot be pumped in `flutter test` (CLAUDE.md), so this is
  /// what lets a widget test compose the REAL banner over the REAL sheet at
  /// the REAL offsets and hit-test the result.
  @visibleForTesting
  static List<Widget> buildLayers({
    required double topPadding,
    required double bottomPadding,
    required Widget map,
    required Widget dimOverlay,
    required Widget invitationsButton,
    required Widget settingsButton,
    required Widget statusBanners,
    required Widget circlesSheet,
    Widget? debugOverlay,
  }) {
    return [
      // Full-screen map (always visible)
      map,

      // Dim overlay (animated based on sheet expansion)
      Positioned.fill(child: dimOverlay),

      // Invitations button (top leading edge; mirrors to the right in RTL,
      // respects safe area)
      PositionedDirectional(
        top: topPadding + HavenSpacing.sm,
        start: HavenSpacing.base,
        child: invitationsButton,
      ),

      // Settings button (top trailing edge; mirrors to the left in RTL,
      // respects safe area)
      PositionedDirectional(
        top: topPadding + HavenSpacing.sm,
        end: HavenSpacing.base,
        child: settingsButton,
      ),

      // Circles bottom sheet
      circlesSheet,

      // Status banners: tell the user, WHILE it is happening, that their
      // location sharing has stopped and what to do about it. Render nothing
      // while everything is fine.
      //
      // Above the sheet, and height-bounded — see this method's doc for both.
      // Offset below the floating controls (`_kFloatingButtonExtent`) so it
      // never overlaps them; start/end insets mirror under RTL; the map canvas
      // beneath is untouched, so circle members stay visible and useful
      // throughout the outage.
      PositionedDirectional(
        top: topPadding + _kStatusBannerTop,
        start: HavenSpacing.base,
        end: HavenSpacing.base,
        bottom: bottomPadding + HavenSpacing.base,
        child: Align(
          alignment: AlignmentDirectional.topStart,
          child: statusBanners,
        ),
      ),

      // Debug log overlay (debug builds only)
      if (debugOverlay != null) debugOverlay,
    ];
  }

  @override
  ConsumerState<MapShell> createState() => _MapShellState();
}

class _MapShellState extends ConsumerState<MapShell>
    with WidgetsBindingObserver {
  double _sheetExpansion = 0;
  final DraggableScrollableController _sheetController =
      DraggableScrollableController();
  // Recurring location publishing is driven by `locationPublishSchedulerProvider`
  // — ONE jittered schedule for the device, whose tick publishes every eligible
  // circle in a CSPRNG-staggered burst. Per-circle schedules are gone, and so
  // is the claim they carried: co-timing does NOT hide a device's circles from
  // a shared relay, which reads the set off the multiplexed `#h` subscription
  // and off the single publish socket. What the stagger still buys is that two
  // circles never share a whole-second `created_at`. MapShell only starts/stops
  // the tick across the app lifecycle; the timer lives in the notifier. The
  // one-shot "publish all now" burst still goes through
  // `locationPublisherProvider` (cold-start / resume / motion / accept-create).
  Timer? _receiveTimer;
  Timer? _invitationTimer;
  Timer? _pruneTimer;
  // Polls for MLS evolution events (commits, proposals) every 60 seconds.
  // Decoupled from the 30-second location timer so leave/handoff commits
  // are processed even when the location poller is idle or the app is
  // backgrounded and then foregrounded.
  Timer? _evolutionTimer;
  // Refreshes the foreground-active timestamp on a fixed cadence faster
  // than the background isolate's staleness threshold
  // (`2 * kBackgroundRepeatInterval`). Decoupling the heartbeat
  // from publish ticks prevents the timestamp from drifting stale when
  // a tick lands at the upper end of the jitter range
  // (`kLocationPublishMaxInterval`), which would otherwise let the
  // background isolate falsely conclude the foreground was killed and
  // start a concurrent publish cycle — violating the MLS single-writer
  // invariant.
  Timer? _foregroundHeartbeatTimer;

  /// Periodically restarts the live-sync engine if it has stopped while a
  /// session is still wanted. Armed ONLY when `liveSyncEnabled` — the receive
  /// and evolution timers are both skipped in that mode, so without this there
  /// is no periodic tick at all on the live-sync path and a dead engine is
  /// never noticed.
  Timer? _liveSyncHealTimer;

  /// The live-sync engine handle, captured in [_ensureLiveSyncInstalled] so
  /// [dispose] can stop it without `ref` (forbidden in dispose). `null` until
  /// the engine is installed / when `liveSyncEnabled` is off.
  SubscriptionService? _liveSync;

  /// B0 (M11): re-subscribes the engine when the accepted-circle set changes
  /// mid-session (create / accept / leave), since the engine subscribes only to
  /// the circles present at `start()`. It also owns EVERY engine start,
  /// including the first one. Installed by [_ensureLiveSyncInstalled]; `null`
  /// until then / when `liveSyncEnabled` is off.
  LiveSyncResubscriber? _liveSyncResubscriber;

  /// Serializes [_ensureLiveSyncInstalled] so concurrent callers share one
  /// install — see [SingleFlight] for what two would cost.
  final SingleFlight<LiveSyncResubscriber?> _installFlight =
      SingleFlight<LiveSyncResubscriber?>();

  /// The `circlesProvider` listener feeding [_liveSyncResubscriber]. Closed on
  /// dispose so no re-subscribe fires after teardown.
  ProviderSubscription<AsyncValue<List<Circle>>>? _liveSyncCirclesSub;

  /// The engine stop a sharing-off iOS pause issued, so the R1 consent edge can
  /// order its restart BEHIND it — see [_restartReceiveAfterPausedStop].
  Future<void>? _pausedEngineStop;

  DateTime? _lastPublishTime;
  DateTime? _lastLocationFetchTime;
  DateTime? _lastInvitationPollTime;
  DateTime? _lastEvolutionPollTime;
  final _resumeStopwatch = Stopwatch();

  /// When the engine's subscriptions were last re-anchored from a resume.
  ///
  /// Separate from [_resumeStopwatch] on purpose: the resume debounce exists to
  /// stop a glance re-running the whole resume sequence, and putting the
  /// re-anchor behind it is what broke the repair (see [_onResumed]). This
  /// throttles only the re-anchor, so the repair still runs on the FIRST
  /// glance after a real gap.
  DateTime? _lastReanchorAt;


  // ---- Motion-triggered publish state ----
  //
  // Piggybacks on the GPS stream that the map page already consumes
  // via `locationStreamProvider`. When the device has moved more than
  // `kMotionTriggerDistanceMeters` since the last publish AND the
  // overlap guard has passed, an extra publish is triggered. This
  // collapses staleness for moving users from worst-case ~2.8 min
  // (max jittered interval) to the stream's emission cadence (~1 s).
  ProviderSubscription<AsyncValue<Position>>? _motionSub;
  Position? _lastMotionTriggerPosition;

  // ---- iOS background publish keep-alive ----
  //
  // On iOS with background sharing enabled, the SINGLE geolocator stream
  // (see `locationStreamProvider`) carries `allowsBackgroundLocationUpdates:
  // true`, so CoreLocation keeps this process fully executable while
  // backgrounded: the publish scheduler
  // (`locationPublishSchedulerProvider`) keeps firing on its jittered cadence
  // and `_motionSub` keeps delivering movement-driven publishes. There is no
  // second "background stream" — geolocator supports exactly one stream, and
  // a second request would silently inherit the first stream's settings
  // (the defect that originally broke iOS background publishing). On
  // Android, the foreground service handles background publishing instead.
  //
  // C4 (M7-A) + R1: installed on the iOS pause branch UNCONDITIONALLY (for
  // both `liveSyncEnabled` states AND both toggle states at pause time).
  // The true→false edge deterministically tears down every publish/receive
  // driver (scheduler, motion trigger, receive timer, warm relay socket)
  // instead of waiting for the OS to suspend the process; the false→true
  // edge re-arms them when a pause raced the notifier's async load of the
  // persisted consent (R1). Closed on resume and on dispose.
  ProviderSubscription<bool>? _bgSharingPausedSub;

  // ---- iOS background burst receive (P4) ----
  //
  // ONE coordinator per mount, built lazily by [_installBurstCoordinator] the
  // first time an iOS pause hands it the publish ticks. One rather than one
  // per pause because it is what serializes bursts: a second coordinator built
  // while the first still had a burst in flight would hold two engine opens
  // and two socket sets at once, which is the state this whole phase exists to
  // remove. Its chain absorbs that instead — a tick arriving mid-burst joins
  // or queues behind it.
  BackgroundBurstCoordinator? _burstCoordinator;

  /// The scheduler the sink was installed on, captured so `dispose()` can
  /// clear it without `ref` (repo convention: no `ref` use in `dispose`).
  LocationPublishSchedulerNotifier? _burstScheduler;

  /// Whether the FOREGROUND owns the live-sync engine right now, read by
  /// [BackgroundBurstCoordinator] before it opens a burst and before each link
  /// of a burst's teardown.
  ///
  /// A PULL, deliberately, and never a latch: one coordinator serves every
  /// pause of a mount (`_burstCoordinator ??=`), so a flag that only ever went
  /// true would leave every burst after the first resume holding its sockets
  /// for the whole background window — strictly worse than the defect it
  /// closes. [_installBurstCoordinator] takes it back to `false` on every
  /// install, which is the single site both the pause branch and the R1
  /// consent edge go through.
  ///
  /// Starts `true` because a mount that has never paused is foregrounded, and
  /// `dispose()` deliberately leaves it alone: an unmounted shell is not a
  /// foreground owner, and flipping it there would stop a burst's teardown and
  /// leave the engine subscribed with the pool open.
  bool _foregroundOwnsEngine = true;

  /// The publish pool, captured while mounted so a shutdown that outlives this
  /// State still closes its sockets — at startup, and refreshed on every
  /// mounted [_shutdownPublishPool].
  NostrRelayService? _publishPool;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startTimers();
    // Mark the foreground UI as active so the background service (if
    // running) defers to the foreground publisher (MLS single-writer
    // invariant). Best-effort: missed flag updates only relax the
    // overlap guard, not the underlying MLS safety.
    // Register the foreground-task channel from the widget layer as well as
    // `main()`. An entrypoint that builds the app itself never runs `main()`,
    // and without the channel every liveness ping vanishes into a null-safe
    // send — so the foreground service reads the silence as a dead UI isolate
    // and releases a session this isolate is actively using. Idempotent.
    ensureForegroundTaskComms();
    unawaited(BackgroundLocationManager.markForegroundActive(active: true));
    // Pre-warm relay service, then fire startup tasks.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // Defence in depth: the AppRouter gate should never mount MapShell
      // without an identity. The `identityProvider` is a FutureProvider
      // backed by secure-storage IO, so its value is null until the
      // future resolves — `valueOrNull` returns null in the brief window
      // between `ref.read` triggering the load and the storage IO
      // completing. Awaiting `.future` collapses that window: by the
      // time the check runs, the load is fully done.
      if (!mounted) return;
      await ref.read(identityProvider.future);
      if (!mounted) return;
      if (ref.read(identityProvider).valueOrNull == null) {
        // This used to be a bare `assert`. In any assertions-enabled build
        // (debug/profile, and every integration test) throwing here aborted
        // the REST of this callback — relay init, KeyPackage publish, the
        // location publisher, the maintenance scheduler AND `_startLiveSync()`
        // — so a single transient secure-storage miss left the app with no
        // receive plane for the whole session and no way back. That is exactly
        // the iOS live-sync CI failure: one null Keychain read, and the engine
        // never started.
        //
        // Report the broken invariant, then re-arm instead of giving up. The
        // identity service no longer latches a load that produced nothing (see
        // `NostrIdentityService._ensureInitialized`), so a later resolution is
        // reachable and runs startup exactly once.
        debugPrint(
          '[MapShell] mounted without an identity — deferring startup until '
          'one resolves (the AppRouter gate should have prevented this)',
        );
        _deferredStartupSub?.close();
        _deferredStartupSub = ref.listenManual<AsyncValue<Identity?>>(
          identityProvider,
          (_, next) {
            if (next.valueOrNull != null) unawaited(_runStartupTasks());
          },
        );
        return;
      }
      await _runStartupTasks();
    });
  }

  /// Guards [_runStartupTasks] to exactly one run per mount. The deferred
  /// identity path can re-enter it, and starting a SECOND live-sync engine
  /// would break the single-`AccountDeviceSession` invariant (Security
  /// Rule 14), so the flag is set before the first `await`.
  bool _startupTasksStarted = false;

  /// Watches for a late identity when MapShell mounted without one. Closed as
  /// soon as startup runs, and on dispose.
  ProviderSubscription<AsyncValue<Identity?>>? _deferredStartupSub;

  /// Runs the one-shot startup sequence: relay pre-warm, KeyPackage publish,
  /// location publisher, maintenance timers and — under `liveSyncEnabled` —
  /// the receive engine. Requires a resolved identity; see `initState`.
  Future<void> _runStartupTasks() async {
    if (_startupTasksStarted || !mounted) return;
    _startupTasksStarted = true;
    _deferredStartupSub?.close();
    _deferredStartupSub = null;
    final relay = ref.read(relayServiceProvider);
    if (relay is NostrRelayService) {
      // Captured HERE, not only on the last mounted shutdown: an unmounted
      // shell's `_shutdownPublishPool` reads no provider, so a teardown that
      // is the FIRST to reach the shutdown after the unmount (a burst that
      // outlived the widget) would close nothing at all.
      _publishPool = relay;
      await relay.initialize();
    }
    // The widget may have been disposed during the async relay init (rapid
    // logout); don't read providers (incl. the maintenance scheduler) if so.
    if (!mounted) return;
    // DM-4c: show the one-time Dark Matter cutover explainer if this
    // launch's cutover guard (main.dart, before runApp) newly destroyed
    // legacy MLS state. Flip the flag back immediately so a later
    // rebuild (hot reload, an unrelated provider invalidation cascade)
    // never re-shows it within the same app session.
    if (ref.read(legacyCutoverExplainerProvider)) {
      ref.read(legacyCutoverExplainerProvider.notifier).state = false;
      unawaited(LegacyCutoverExplainerDialog.show(context));
    }
    ref
      ..read(keyPackagePublisherProvider)
      ..read(locationPublisherProvider)
      // DM-4c (plan §6 F10a/F10b): once-only retraction of this account's
      // stale pre-migration KeyPackage advertisements, now that relays are
      // connected. Self-gates on a Rust sentinel, so reading it here every
      // app session is safe — it becomes a fast no-op after the first
      // successful run.
      ..read(legacyRetractionProvider)
      // M8: start the scheduled resilience timers (KeyPackage + relay-list
      // republish-if-missing). Engine-independent — active regardless of
      // `liveSyncEnabled`. Cancelled on dispose + explicitly invalidated in
      // `deleteIdentity` so no secret-bearing tick runs after logout.
      ..read(maintenanceSchedulerProvider.notifier);
    // Receive plane: the live-sync engine (when enabled) replaces the
    // invitation + evolution pollers; otherwise start those pollers.
    if (liveSyncEnabled) {
      unawaited(_startLiveSync());
      // REV-1: finish any leave a prior session interrupted mid-backstop
      // (crash / kill). Best-effort, live-sync only — leave markers are only
      // ever set inside the backstop, so this no-ops otherwise.
      unawaited(_resumePendingLeaves());
    } else {
      ref
        ..read(invitationPollerProvider)
        ..read(evolutionPollerProvider);
    }
    // No leaf-key rotation runs here, and none ever runs on a timer. A
    // circle's epoch advances on a membership change, or on the user's own
    // Repair action (`circle::rotation`); see
    // `docs/EPOCH_ROTATION_REPAIR_PLAN.md`.
    // Startup sweep: prune any expired last-known-location rows so the
    // 1-day receiver retention window is honoured on disk.
    unawaited(_runPrune());
    // Cold-start public-profile refresh. Haven holds no standing kind-0
    // subscription, so launch is the one moment a rename or new photo is
    // guaranteed to be picked up before the user looks at the map. Delayed
    // by a short settle so it never competes with identity load, relay
    // init, or engine bootstrap for the first frames; TTL-gated, so a
    // kill-and-relaunch loop still costs at most one fetch per tier window.
    _coldStartProfileRefreshTimer = Timer(_coldStartProfileRefreshDelay, () {
      if (!mounted) return;
      triggerProfileRefresh(
        ref,
        maxAge: profileInteractiveMaxAge,
        circles: ref.read(circlesProvider).valueOrNull,
      );
      // Resume any own-profile publish a prior session left queued — honours
      // the persisted backoff, never dials a relay unconditionally.
      triggerProfileSyncRetry(ref);
    });
  }

  /// Settle delay before the cold-start profile refresh (see `initState`).
  static const _coldStartProfileRefreshDelay = Duration(seconds: 5);

  /// Cancelled on dispose so a rapid logout cannot fire a post-teardown fetch.
  Timer? _coldStartProfileRefreshTimer;

  /// Per-tick jitter range for the invitation poll: nominal 120 s ±25 %
  /// → uniform [90 s, 150 s]. Sampled fresh on every tick so successive
  /// fetches are not on a fixed cadence.
  static const _invitationPollMinSecs = 90;
  static const _invitationPollMaxSecs = 150;
  static const _invitationPollOverlapGuard = Duration(seconds: 80);
  // Reused across ticks so the jitter draw is non-deterministic in
  // production but does not allocate a fresh CSPRNG per fire.
  final math.Random _invitationPollRng = math.Random.secure();

  Timer _scheduleInvitationPoll() {
    final delaySecs =
        _invitationPollMinSecs +
        _invitationPollRng.nextInt(
          _invitationPollMaxSecs - _invitationPollMinSecs + 1,
        );
    return Timer(Duration(seconds: delaySecs), () {
      if (!mounted) return;
      final now = DateTime.now();
      if (_lastInvitationPollTime == null ||
          now.difference(_lastInvitationPollTime!) >
              _invitationPollOverlapGuard) {
        _lastInvitationPollTime = now;
        ref
          ..invalidate(invitationPollerProvider)
          ..read(invitationPollerProvider);
      }
      _invitationTimer = _scheduleInvitationPoll();
    });
  }

  /// REV-1: finishes any leave a prior session interrupted mid-backstop
  /// (crash / kill). Best-effort — reads the durable leave markers and re-runs
  /// the leave for each still-pending circle (see [PendingLeaveService]). Only
  /// meaningful under live-sync, where the backstop sets those markers.
  Future<void> _resumePendingLeaves() async {
    try {
      final selfPubkey = ref.read(identityProvider).valueOrNull?.pubkeyHex;
      if (selfPubkey == null) return;
      final circleService = ref.read(circleServiceProvider);
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      await PendingLeaveService(prefs: prefs).resumePendingLeaves(
        circleService: circleService,
        selfPubkeyHex: selfPubkey,
      );
    } on Object catch (e) {
      debugPrint('[MapShell] pending-leave resume failed: ${e.runtimeType}');
    }
  }

  Future<void> _runPrune() async {
    try {
      await ref.read(circleServiceProvider).pruneExpiredLastKnown();
    } on Object catch (e) {
      // Type only. The FFI boundary hands back a Rust `Result<_, String>` whose
      // text is sanitized by `redact_hex_sequences`, but "sanitized by someone
      // else's regex" is not the standard the rest of this file holds itself
      // to, and a `kDebugMode` carve-out still logs it in every debug build and
      // every E2E capture — which is where the log scanners look.
      debugPrint('[MapShell] pruneExpiredLastKnown failed: ${e.runtimeType}');
    }
    // The widget may have been disposed while the first FFI call was in
    // flight. `ref` throws once the ConsumerState is disposed, so guard
    // BEFORE reading it again for the second prune (C1). This runs on both the
    // success and failure paths of the first prune.
    if (!mounted) return;
    try {
      await ref.read(circleServiceProvider).pruneProcessedGiftWraps();
    } on Object catch (e) {
      // Type only — see the sibling prune above.
      debugPrint('[MapShell] pruneProcessedGiftWraps failed: ${e.runtimeType}');
    }
  }

  /// Brings the live-sync receive plane up at startup.
  ///
  /// Runs once per mount (`_startupTasksStarted`), but is no longer the app's
  /// only chance at a receive plane. It used to be: a one-shot `start()` whose
  /// failure was logged and dropped, with the re-subscriber installed only
  /// AFTERWARDS — so a single transient failure at launch left
  /// [_liveSyncResubscriber] null, which makes [_healLiveSyncIfStopped] return
  /// immediately forever and `resumeAfterBackground()` a no-op against a null
  /// engine. One unlucky launch cost live receive for the whole process.
  ///
  /// Now the install and the first start are both retryable, and the first
  /// start IS a heal — so every start in the app goes through the
  /// re-subscriber's serialized chain and two of them can never race the one
  /// engine (Security Rule 14).
  Future<void> _startLiveSync() async {
    await _healLiveSyncIfStopped();
    if (!mounted) return;
    // Re-draw the backstop's interval from the outcome just recorded: a failed
    // first start should retry on the backed-off cadence, not on the one
    // `_startTimers` armed before any attempt had been made.
    _rearmLiveSyncHealTimer();
  }

  /// Installs (or returns) the re-subscriber that owns every engine start.
  ///
  /// Idempotent and RETRYABLE — every heal tick re-attempts it, so a transient
  /// failure to read the circle roster (the Android handoff window, an identity
  /// that has not resolved yet) costs one tick rather than the process.
  ///
  /// The re-subscriber is built from the circle snapshot ALONE, before any
  /// session exists: its `_running` set is the set the engine is WANTED to run,
  /// and `ensureRunning`'s full restart performs the first start from it.
  ///
  /// Returns `null` when the snapshot could not be read.
  Future<LiveSyncResubscriber?> _ensureLiveSyncInstalled() {
    final installed = _liveSyncResubscriber;
    if (installed != null) {
      return Future<LiveSyncResubscriber?>.value(installed);
    }
    // Join the in-flight install rather than starting a second one.
    return _installFlight.run(_installLiveSync);
  }

  /// The body of [_ensureLiveSyncInstalled], run at most once concurrently.
  Future<LiveSyncResubscriber?> _installLiveSync() async {
    try {
      // Capture the handle so dispose() can stop it without `ref`.
      // The explicit type argument is load-bearing: without it `??` gives the
      // read its own nullable context type and `engine` infers as nullable.
      final engine =
          _liveSync ??
          ref.read<SubscriptionService>(subscriptionServiceProvider);
      _liveSync = engine;
      final circles = await ref.read(circlesProvider.future);
      if (!mounted) return null;
      final groups = LiveSyncResubscriber.groupsForCircles(circles);
      final resubscriber = LiveSyncResubscriber(
        engine: engine,
        inboxRelays: () => ref.read(inboxRelaysProvider.future),
        initialSignature: LiveSyncResubscriber.signatureForGroups(groups),
        initialGroups: groups,
      );
      _liveSyncResubscriber = resubscriber;
      // B0 (M11): the engine subscribes only to the circles it was started
      // with, so a mid-session create / accept / leave must re-anchor it to the
      // new accepted set (the M3-deferred stop+start interim) instead of
      // silently receiving no live locations for the new circle until relaunch.
      // `fireImmediately: true` closes the race where the accepted set changed
      // during the await above: the immediate fire is a no-op if the set still
      // matches, and re-anchors otherwise.
      _liveSyncCirclesSub = ref.listenManual<AsyncValue<List<Circle>>>(
        circlesProvider,
        (_, next) {
          next.whenData(_onLiveSyncCirclesChanged);
        },
        fireImmediately: true,
      );
      return resubscriber;
    } on Object catch (e) {
      // Type only, like every other catch in this file. The FFI error is a
      // Rust `Result<_, String>` that `redact_hex_sequences` has been over,
      // but that redaction is a hex-shaped denylist — it is not a guarantee
      // that no relay URL, group id or internal state rides along in the
      // remaining prose, and the debug/E2E builds this used to print in are
      // exactly the ones whose logs get captured and uploaded.
      debugPrint('[MapShell] live-sync install failed: ${e.runtimeType}');
      return null;
    }
  }

  /// Feeds a fresh accepted-circle snapshot to [_liveSyncResubscriber] so a
  /// mid-session circle-set change re-anchors the engine (B0). Guarded by
  /// `mounted`; the re-subscriber additionally no-ops once disposed and
  /// debounces + skips unchanged sets, so an unrelated `circlesProvider`
  /// rebuild (e.g. a roster change to an existing circle) never restarts it.
  void _onLiveSyncCirclesChanged(List<Circle> circles) {
    if (!mounted) return;
    _liveSyncResubscriber?.onCirclesChanged(circles);
  }

  void _startTimers() {
    // Defensive cancellation: if called from the resume path while
    // timers are still live (e.g. rapid pause/resume cycles that slip
    // past the debounce), cancel existing timers to prevent accumulation.
    _receiveTimer?.cancel();
    _invitationTimer?.cancel();
    _pruneTimer?.cancel();
    _evolutionTimer?.cancel();
    _foregroundHeartbeatTimer?.cancel();
    _liveSyncHealTimer?.cancel();
    _stopMotionTrigger();

    // Foreground-active heartbeat — see `_foregroundHeartbeatTimer`
    // doc for why a separate timer is required (publish jitter range
    // can exceed the staleness window). Fires immediately via the
    // `markForegroundActive` call in `initState` / `_onResumed`; this
    // periodic refresh covers the in-session case.
    _foregroundHeartbeatTimer = Timer.periodic(kBackgroundRepeatInterval, (_) {
      if (!mounted) return;
      unawaited(BackgroundLocationManager.markForegroundActive(active: true));
    });

    // Recurring location publishing: ONE jittered cadence for the device
    // (nominal `kLocationUpdateInterval`, ±40% via Rust-side CSPRNG per tick),
    // owned by `locationPublishSchedulerProvider`, whose every tick publishes
    // the whole eligible roster in a staggered burst. Reading the notifier
    // builds it (arming that one tick); `startScheduling` re-activates after a
    // background pause. Cancelled on pause (below), on dispose (Ref.onDispose),
    // and on `deleteIdentity`.
    ref.read(locationPublishSchedulerProvider.notifier).startScheduling();

    // Motion-triggered publish: subscribe to the GPS stream that the map
    // page already consumes. No extra GPS cost — Riverpod shares the
    // underlying geolocator stream. When the device moves more than
    // `kMotionTriggerDistanceMeters` since the last publish AND the
    // overlap guard has passed, trigger an extra publish.
    _startMotionTrigger();

    // Fetch member locations every 30 seconds, with overlap guard. Skipped when
    // the live-sync engine drives receive — its Location events invalidate
    // memberLocationsProvider (which then reads the cache, not the relay).
    if (!liveSyncEnabled) {
      _receiveTimer = Timer.periodic(const Duration(seconds: 30), (_) {
        final now = DateTime.now();
        if (_lastLocationFetchTime == null ||
            now.difference(_lastLocationFetchTime!) >
                const Duration(seconds: 25)) {
          _lastLocationFetchTime = now;
          ref.invalidate(memberLocationsProvider);
        }
      });
    }

    // Prune expired last-known locations every hour. The Timer.periodic
    // cadence already caps how often this fires; a redundant minute-based
    // guard here only adds confusion.
    _pruneTimer = Timer.periodic(const Duration(hours: 1), (_) {
      unawaited(_runPrune());
    });

    // The hourly leaf-key self-update timer was removed in M5: leaderless
    // periodic self-update is the dominant MLS fork generator. Epochs advance
    // on a real membership change, or on the user's own Repair action — never
    // on a timer (`docs/EPOCH_ROTATION_REPAIR_PLAN.md` §3).

    // Poll for new invitations on a jittered cadence (nominal 2 min,
    // ±25%, sampled per tick). Fixed cadences are fingerprintable to
    // a passive relay observer; per CLAUDE.md "Metadata & Connection
    // Privacy", every recurring relay interaction must be jittered.
    // The overlap guard is the lower jitter bound minus a small grace
    // so a foreground/resume re-trigger cannot double-fire. Skipped when the
    // live-sync engine drives receive — its Welcome events deliver invitations.
    if (!liveSyncEnabled) {
      _invitationTimer = _scheduleInvitationPoll();
    }

    // Poll for MLS evolution events every 60 seconds.
    //
    // A longer cadence than the 30-second location timer by design: the
    // goal is to catch leave/handoff commits that arrive while the app is
    // backgrounded and foregrounded, not to compete with the location poll
    // for relay bandwidth. The overlap guard (55 seconds) ensures that a
    // resume-triggered poll (see _onResumed) cannot double-fire within
    // the same minute even on rapid pause/resume cycles.
    // Skipped when the live-sync engine drives receive — its GroupUpdate events
    // (the engine converges peer SelfRemoves in-Rust, M6-2) replace this poll.
    if (liveSyncEnabled) {
      // The engine owns receive on this path, so a stopped engine means NO
      // receive at all — and nothing else here would observe it. Interval is
      // deliberately unhurried: the check is a cheap `isRunning` read on a
      // healthy engine, and a restart is only ever needed after an event that
      // is supposed to be rare.
      _rearmLiveSyncHealTimer();
    }

    if (!liveSyncEnabled) {
      _evolutionTimer = Timer.periodic(const Duration(minutes: 1), (_) {
        if (!mounted) return;
        final now = DateTime.now();
        if (_lastEvolutionPollTime == null ||
            now.difference(_lastEvolutionPollTime!) >
                const Duration(seconds: 55)) {
          _lastEvolutionPollTime = now;
          ref
            ..invalidate(evolutionPollerProvider)
            ..read(evolutionPollerProvider);
        }
      });
    }
  }

  // Self-heal cadence. Jittered for the same reason the invitation poll is:
  // when the engine is healthy this costs a local `isRunning` read, but when a
  // restart keeps FAILING every tick issues a full connect + REQ sweep across
  // every group and inbox relay. A fixed period would give that a metronomic,
  // Haven-specific signature to a passive relay observer.
  static const _healMinSecs = 90;
  static const _healMaxSecs = 150;

  /// Consecutive failed restarts, used to back off. Reset on success so a
  /// transient failure does not permanently slow recovery.
  int _consecutiveHealFailures = 0;

  /// Cap on the backoff multiplier — 8 × the base cadence is roughly 15
  /// minutes, past which retrying faster buys nothing against a relay set that
  /// is simply unreachable.
  static const _healBackoffMaxMultiplier = 8;

  final math.Random _healRng = math.Random.secure();

  /// (Re-)arms the periodic self-heal backstop. Idempotent — cancels first, so
  /// repeated calls cannot leave two timers running.
  ///
  /// One-shot and re-armed from its own callback rather than `Timer.periodic`,
  /// so each interval draws fresh jitter and can widen under backoff.
  ///
  /// Re-arming from `whenComplete` is only safe because `ensureRunning` is
  /// bounded (`kLiveSyncRestartBudget`): a heal that could hang would otherwise
  /// never complete, and this backstop — the only periodic recovery the
  /// live-sync build has — would be gone for the rest of the process.
  void _rearmLiveSyncHealTimer() {
    if (!liveSyncEnabled) return;
    _liveSyncHealTimer?.cancel();
    final multiplier = math.min(
      1 << _consecutiveHealFailures,
      _healBackoffMaxMultiplier,
    );
    final delaySecs =
        (_healMinSecs + _healRng.nextInt(_healMaxSecs - _healMinSecs + 1)) *
        multiplier;
    _liveSyncHealTimer = Timer(Duration(seconds: delaySecs), () {
      if (!mounted) return;
      unawaited(_healLiveSyncIfStopped().whenComplete(_rearmLiveSyncHealTimer));
    });
  }

  /// Closes the publish pool's sockets.
  ///
  /// `shutdown()` is a [NostrRelayService] concern, not part of the
  /// `RelayService` interface every test double implements, so the type test
  /// belongs here rather than at each of the three call sites.
  ///
  /// Works after this State is gone, through the handle captured at startup
  /// and refreshed here. It used to `return` on `!mounted` instead, which
  /// quietly made "an opt-out leaves no socket" conditional on the shell still
  /// being mounted: a burst can outlive the widget (a logout taken while
  /// paused), and the sockets then stayed up until the pool's own idle sweep
  /// noticed. The provider is container-scoped and outlives the widget, so
  /// holding the handle keeps nothing alive that was not already alive.
  ///
  /// The refresh stays even though `relayServiceProvider` is a plain
  /// `Provider` nothing invalidates: no guard pins that, and re-reading a
  /// singleton costs nothing.
  Future<void> _shutdownPublishPool() async {
    if (mounted) {
      final relay = ref.read(relayServiceProvider);
      if (relay is NostrRelayService) _publishPool = relay;
    }
    await _publishPool?.shutdown();
  }

  /// Hands the publish ticks to a [BackgroundBurstCoordinator], so
  /// each one becomes a bounded open → ingest → publish → fold → close burst
  /// instead of a publish over a socket held for the whole background window.
  ///
  /// Only ever called from the iOS + background-sharing-on pause states (the
  /// pause branch itself and the R1 consent edge that arrives at the same
  /// state late): everywhere else the scheduler has been stopped, and both
  /// [BurstPublisher] methods refuse while it is, so a sink installed there
  /// would produce bursts that open a socket, wait, publish nothing and pause.
  ///
  /// Every collaborator is read ONCE here except the two that must not be:
  /// consent is re-read per link (it is what cooperative cancellation is made
  /// of), and the health notifier is re-read per report. `mounted` gates both,
  /// so an unmounted shell reads as "not enabled" — which cancels the burst
  /// cooperatively and still runs its teardown, rather than throwing out of
  /// it.
  BackgroundBurstCoordinator _installBurstCoordinator() {
    final scheduler = ref.read(locationPublishSchedulerProvider.notifier);
    final coordinator =
        _burstCoordinator ??= BackgroundBurstCoordinator(
          engine: ref.read(subscriptionServiceProvider),
          publisher: scheduler,
          maintenance: ref.read(maintenanceSchedulerProvider.notifier),
          stagger: ref.read(locationPublishStaggerProvider),
          shutdownPublishPool: _shutdownPublishPool,
          // Security Rule 13. The burst awaits its OWN publishes by structure,
          // but the pool is not the burst's: the motion trigger keeps running
          // while backgrounded on iOS and publishes over the same one,
          // unawaited by and invisible to the coordinator. That path reaches
          // the deferred-send ladder, and `shutdownPublishPool` disconnects
          // with no drain of any kind — so a commit between SEND and OK loses
          // its ack and is rolled back on a relay that may already have stored
          // and served it. This is the read that lets the teardown wait for
          // it. `mounted` fails safe in the same direction as the shutdown it
          // guards: an unmounted shell's `_shutdownPublishPool` closes only
          // what it captured, and there is nothing here to wait for.
          pendingCommitCritical: () => mounted
              ? ref.read(locationSharingServiceProvider).inFlightCommitCritical
              : null,
          burstEnabled: () => mounted && ref.read(backgroundSharingProvider),
          foregrounded: () => _foregroundOwnsEngine,
          onOpenOutcome: (failures) {
            if (!mounted) return;
            MapShell.recordBurstOpenOutcome(
              ref.read(sharingHealthProvider.notifier),
              failures,
            );
          },
        );
    _burstScheduler = scheduler;
    // Backgrounded again, whether this built the coordinator or reused it: one
    // instance serves every pause of the mount, so the handback flag has to be
    // taken back here or the second background window would be served by a
    // coordinator that thinks the foreground still owns the engine — no burst
    // opened, no socket ever closed.
    _foregroundOwnsEngine = false;
    scheduler.setTickSink(coordinator);
    return coordinator;
  }

  /// The circles a burst may publish to, in exactly the scheduler's terms
  /// ([filterPublishEligibleCircles]) — accepted, not legacy-orphaned, not
  /// blocked.
  ///
  /// Empty for an unmounted shell: `ref` is unusable there, and "nothing is
  /// eligible" is the answer that makes every caller close what it holds.
  List<Circle> _burstEligibleCircles() {
    if (!mounted) return const [];
    return filterPublishEligibleCircles(
      ref.read(circlesProvider).valueOrNull ?? const <Circle>[],
      ref.read(circleServiceProvider),
    );
  }

  /// Runs ONE burst now over [circles], the set currently eligible to publish.
  ///
  /// The same key the schedulers use ([sharingCircleKey]) over the same set
  /// ([filterPublishEligibleCircles]), so this is exactly their ticks arriving
  /// at once rather than a second notion of "due".
  Future<void> _driveBurstNow(
    BackgroundBurstCoordinator coordinator,
    List<Circle> circles,
  ) => MapShell.queueOneBurst(coordinator, [
    for (final circle in circles)
      (key: sharingCircleKey(circle.nostrGroupId), circle: circle),
  ]);

  /// Stops the live-sync engine and reports whether it actually let go.
  ///
  /// The ONE stop path: the pause-time handoff, the sharing-off pause branch
  /// and [_onDetached] all route through it, so a stop that timed out is
  /// classified the same way everywhere. A second, unclassified `stop()` would
  /// let a timed-out teardown read as a release and orphan the Rule-14 guard —
  /// which is a database no isolate can open until a Force Stop.
  ///
  /// Never throws: every caller runs on a lifecycle path the framework
  /// dispatches without awaiting. A failure is reported as
  /// [LiveSyncStopOutcome.stillHolding] — the wrong guess in the other
  /// direction is the one that wedges the app.
  Future<LiveSyncStopOutcome> _stopLiveSyncBounded() async {
    final liveSync = _liveSync;
    if (liveSync == null) return LiveSyncStopOutcome.idle;
    var outcome = LiveSyncStopOutcome.stillHolding;
    try {
      outcome = await liveSync.stop();
    } on Object catch (e) {
      // Never the raw error (Rule 8): an FFI error string can carry MLS
      // group ids.
      debugPrint('[MapShell] live-sync stop failed: ${e.runtimeType}');
    }
    debugPrint('[MapShell] live-sync stop=${outcome.name}');
    return outcome;
  }

  /// Releases this isolate's MLS session so the foreground service can take it.
  ///
  /// Android + background-sharing only: it is the one configuration where
  /// another isolate needs the session while this one is merely paused.
  ///
  /// Returns whether the session was actually handed over. `false` means this
  /// isolate kept it, so the service cannot publish for the whole backgrounded
  /// window — a state the caller must not describe to the user as "sending and
  /// receiving".
  Future<bool> _handOffMlsSession() async {
    // The engine holds its own Arc on the circle manager, so it must go first
    // or the release frees nothing.
    final stopOutcome = await _stopLiveSyncBounded();

    if (stopOutcome == LiveSyncStopOutcome.stillHolding) {
      // Releasing now would be strictly destructive. The engine's supervisor
      // tasks still hold their own `Arc<CircleManager>` — and with it the
      // Rule-14 guard — so disposing THIS isolate's handle frees nothing; it
      // just removes the last Dart reference to a guard a Rust static keeps
      // registered. The foreground service then cannot open (the guard is
      // held), its reclaim correctly declines (this isolate is provably
      // alive), and the app comes back on resume to a database nothing can
      // open: no circles, no map, no publishing, until a Force Stop.
      //
      // Keeping the handle costs this backgrounded session's background
      // publishing — which was already impossible, since the guard was never
      // going to be free for the service — and keeps the foreground working.
      return false;
    }

    final service = ref.read(circleServiceProvider);
    if (service is! NostrCircleService) return false;
    try {
      final released = service.releaseForHandoff();
      debugPrint('[MapShell] handoff: released=$released');
      // `released` reports only whether there was a live handle to give away;
      // the handoff itself is the LATCH this call sets either way, and that is
      // what lets the service open. So the handoff happened.
      return true;
    } on Object catch (e) {
      // Never throw out of the pause path: the framework dispatches it without
      // awaiting, and the service's own reclaim is the fallback.
      debugPrint('[MapShell] handoff failed: ${e.runtimeType}');
      return false;
    }
  }

  /// Takes the MLS session back on resume — the mirror of
  /// [_handOffMlsSession].
  ///
  /// Ending the handoff is all this has to do: the open itself happens lazily,
  /// under whichever provider needs the manager first, and if the foreground
  /// service still holds the guard that open recovers it through the ordinary
  /// `sessionHandover` path (`service_providers.dart`).
  ///
  /// The re-subscriber is replayed because a circle-set change that arrived
  /// while the handoff held could NOT be applied — restarting the engine needs
  /// the manager, and the manager was (correctly) refused. That failure leaves
  /// the re-subscriber's running-set signature un-advanced on purpose, so
  /// feeding it today's snapshot re-decides the same change and applies it now.
  /// An unchanged set is a no-op there, and this runs only when a handoff was
  /// genuinely in effect.
  ///
  /// This replay reads `circlesProvider` while it may still hold the `[]` a
  /// failed open during the handoff cached, so it DEPENDS on
  /// [_invalidateHandoffWindowPoison] running immediately after it: the fresh
  /// roster re-fires the same listener and supersedes the empty snapshot inside
  /// the re-subscriber's own 500 ms debounce, before it can apply as a
  /// "remove every circle" delta.
  void _endMlsSessionHandoff() {
    final service = ref.read(circleServiceProvider);
    if (service is! NostrCircleService) return;
    bool ended;
    try {
      ended = service.endSessionHandoff();
    } on Object catch (e) {
      debugPrint('[MapShell] handoff end failed: ${e.runtimeType}');
      return;
    }
    if (!ended) return;
    debugPrint('[MapShell] handoff: session taken back by the foreground');
    final circles = ref.read(circlesProvider).valueOrNull;
    if (circles != null) _onLiveSyncCirclesChanged(circles);
  }

  /// Drops provider state that a failed open during the pause window may have
  /// cached as a permanent answer.
  ///
  /// While the Android MLS handoff holds, every `getCircleManagerFfi()` fails
  /// closed by design — and the providers built on it do not all fail the same
  /// way:
  ///
  ///   * `circlesProvider` swallows EVERY failure to `[]` and caches it as a
  ///     SUCCESSFUL answer. A read that lost that race leaves an empty circle
  ///     list and a bare map, with no error anywhere, for the rest of the
  ///     process — which is what the field report described. Nothing can
  ///     detect it after the fact, so it is always re-read.
  ///   * `relayPreferencesServiceProvider` and `inboxRelaysProvider` DO cache
  ///     their failure, as an `AsyncError` that nothing else ever retries — and
  ///     the inbox list is what a full engine restart re-subscribes the
  ///     gift-wrap REQ with, so a stuck error there costs invitations.
  ///     Rebuilding them is not free (relay-list FFI reads, plus two
  ///     publish-toggle writes for the service), and this runs on every resume
  ///     ahead of the 30 s debounce, so only a cached error is dropped.
  void _invalidateHandoffWindowPoison() {
    ref.invalidate(circlesProvider);
    if (ref.read(relayPreferencesServiceProvider).hasError) {
      ref.invalidate(relayPreferencesServiceProvider);
    }
    if (ref.read(inboxRelaysProvider).hasError) {
      ref.invalidate(inboxRelaysProvider);
    }
  }

  /// Restarts the live-sync engine if it stopped while a session is still
  /// wanted.
  ///
  /// The engine can be stopped by things this widget does not control — a
  /// Rust-side teardown, or the background isolate force-releasing the
  /// process-global session to reclaim the MLS database. That reclaim is gated
  /// to only run against an isolate believed gone, but "believed" is a
  /// judgement, and without a recovery path a wrong call would cost live
  /// receive until the user relaunched the app. This bounds that to one tick.
  ///
  /// Cheap when healthy: `ensureRunning` short-circuits on a running engine.
  ///
  /// Installs the re-subscriber first, so this is also the app's FIRST start
  /// and its retry (see [_ensureLiveSyncInstalled]). Bounded end to end:
  /// `ensureRunning` answers within `kLiveSyncRestartBudget` whatever the
  /// engine does, which is what lets the caller's `whenComplete` re-arm be
  /// trusted.
  ///
  /// It heals the OTHER dead receive plane too. `ensureRunning` cannot see a
  /// PAUSED engine — `isRunning` stays true across a pause — so a resume whose
  /// single re-anchor attempt failed would otherwise stay paused, receiving
  /// nothing behind a green banner, until the next background→foreground
  /// cycle. See [MapShell.reanchorPausedEngine].
  ///
  /// Gated on `liveSyncEnabled` HERE rather than at each call site, because two
  /// of the four callers reach it unconditionally: `_onResumed` deliberately
  /// heals ahead of its own debounce, and the R1 consent edge heals from a
  /// PAUSED process. Neither re-read the flag, so a flag-off build used to
  /// START an engine on its first resume — the rollback path running the very
  /// receive plane its one-line rollback removes, with the pollers still armed
  /// beside it. Nothing below can be started for the flag-off plane's benefit:
  /// `_runStartupTasks` gives that build the invitation + evolution pollers
  /// instead, and `_startIosBackgroundReceiveTimer` its own background sweep.
  Future<void> _healLiveSyncIfStopped() async {
    if (!liveSyncEnabled) return;
    final resubscriber = await _ensureLiveSyncInstalled();
    if (resubscriber != null) {
      try {
        if (await resubscriber.ensureRunning()) {
          _consecutiveHealFailures = 0;
          if (!mounted) return;
          final at = DateTime.now();
          if (await MapShell.reanchorPausedEngine(
            engine: ref.read(subscriptionServiceProvider),
            foregrounded: ref.read(appForegroundProvider),
            now: at,
            lastReanchorAt: _lastReanchorAt,
          )) {
            _lastReanchorAt = at;
          }
          return;
        }
      } on Object catch (e) {
        // Never surface the raw error (Rule 8) and never let a failed heal
        // break the timer — the next tick retries.
        debugPrint('[MapShell] live-sync heal failed: ${e.runtimeType}');
      }
    }
    // Counted, not just logged: a relay set that is unreachable would otherwise
    // be swept on every tick indefinitely.
    if (_consecutiveHealFailures < _healBackoffMaxMultiplier) {
      _consecutiveHealFailures++;
    }
  }

  /// Brings the receive plane back for the R1 consent edge (a pause that read a
  /// stale `false` and stopped the engine, then saw the persisted consent
  /// resolve `true`), ordered BEHIND that stop.
  ///
  /// The ordering is the whole point. `NostrSubscriptionService.stop()` nulls
  /// its engine handle synchronously and only then awaits the FFI teardown, so
  /// a heal landing inside that window reads a stopped engine and starts a
  /// FRESH session — which the original stop, still unwinding, then cancels the
  /// event subscription of on its way out. A live-looking engine delivering
  /// nothing, for the whole background window.
  Future<void> _restartReceiveAfterPausedStop() async {
    final stop = _pausedEngineStop;
    _pausedEngineStop = null;
    if (stop != null) await stop;
    if (!mounted) return;
    await _healLiveSyncIfStopped();
  }

  // ---- Motion-triggered publish helpers ----

  void _startMotionTrigger() {
    _motionSub?.close();
    _motionSub = ref.listenManual<AsyncValue<Position>>(
      locationStreamProvider,
      _onMotionStreamEvent,
    );
  }

  /// Handles every position-stream state, not just the happy one.
  ///
  /// This was `next.whenData(_onMotionPosition)`, which runs ONLY for
  /// `AsyncData`: an `AsyncError` — the plugin's mid-stream
  /// `LocationServiceDisabledException` when the OS location provider is
  /// switched off, or a permission revocation — was discarded here, and so was
  /// a stream that stopped delivering. Sharing died and nothing in the app
  /// noticed. `locationAccessProvider` owns the user-facing verdict (it is the
  /// only thing that can ask the platform WHY); this listener's job is to stop
  /// treating a dead stream as a healthy one.
  void _onMotionStreamEvent(
    AsyncValue<Position>? previous,
    AsyncValue<Position> next,
  ) {
    if (next is AsyncError<Position>) {
      // Type only — never the raw error (Security Rule 8).
      debugPrint('[MapShell] position stream error: ${next.error.runtimeType}');
      // Drop the motion reference point: it was captured before the outage, so
      // the first fix after recovery would otherwise be measured against a
      // position that may be hours and many kilometres old and fire a bogus
      // "you moved 100 m" publish. Re-seeding costs one stream emission.
      _lastMotionTriggerPosition = null;
      return;
    }
    if (next is AsyncData<Position>) {
      _onMotionPosition(next.value);
    }
    // AsyncLoading: a (re)subscribe is in flight, nothing to publish from yet.
  }

  void _stopMotionTrigger() {
    _motionSub?.close();
    _motionSub = null;
    _lastMotionTriggerPosition = null;
  }

  void _onMotionPosition(Position position) {
    if (!mounted) return;
    final last = _lastMotionTriggerPosition;
    if (last == null) {
      // First emission after subscribe — seed the reference point
      // without triggering a publish.
      _lastMotionTriggerPosition = position;
      return;
    }
    final distance = haversineMeters(
      last.latitude,
      last.longitude,
      position.latitude,
      position.longitude,
    );
    if (distance < kMotionTriggerDistanceMeters) return;

    // Sufficient movement detected — check the overlap guard first. This is
    // the guard's only gated caller; resume and the background handoff just
    // WRITE `_lastPublishTime`, which is what suppresses a trigger behind them.
    if (_guardedPublish()) {
      _lastMotionTriggerPosition = position;
      debugPrint('[MapShell] motion-triggered publish');
    }
  }

  /// Publishes if the overlap guard has elapsed since the last publish.
  /// Returns `true` when a publish was triggered.
  bool _guardedPublish() {
    final now = DateTime.now();
    if (_lastPublishTime != null &&
        now.difference(_lastPublishTime!) <= kLocationPublishOverlapGuard) {
      return false;
    }
    _lastPublishTime = now;
    // Fix 3: Refresh the foreground-active timestamp on every successful
    // publish so a long foreground session does not drift past the
    // `2 * kBackgroundRepeatInterval` staleness threshold. The background
    // isolate reads this timestamp to determine if the foreground still
    // owns publishing; without periodic refreshes a long session would
    // cause the background to mistakenly believe the foreground was killed
    // and resume publishing concurrently.
    unawaited(BackgroundLocationManager.markForegroundActive(active: true));
    ref
      ..invalidate(locationPublisherProvider)
      ..read(locationPublisherProvider);
    return true;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // `inactive`/`hidden` are deliberately not distinct from paused/resumed:
    // iOS always sandwiches `inactive` between the two authoritative states,
    // so gating on paused/resumed alone cannot strand the foreground-active
    // hint.
    //
    // `detached` IS distinct, and is handled below — it is the only lifecycle
    // signal that says this isolate is going away while it can still act.
    if (state == AppLifecycleState.paused) {
      _setForegroundActive(false);
      unawaited(_onPaused());
    } else if (state == AppLifecycleState.resumed) {
      _setForegroundActive(true);
      unawaited(_onResumed());
    } else if (state == AppLifecycleState.detached) {
      _setForegroundActive(false);
      unawaited(_onDetached());
    }
  }

  /// Releases the live-sync engine when the Flutter engine is being torn down.
  ///
  /// # Why this is worth doing proactively
  ///
  /// The MLS database allows exactly one live session per process (Rule 14),
  /// and the guard enforcing it is a Rust static that no Dart finalizer
  /// reaches. When this isolate dies without releasing, the background service
  /// is left contending with a session whose owner no longer exists — the
  /// orphan the reclaim machinery exists to recover from. Reclaiming is
  /// reactive, gated on inferring that this isolate is gone, and destructive if
  /// that inference is ever wrong. Releasing here is none of those things: at
  /// `detached` we still exist, so we can simply hand the session back.
  ///
  /// # What this does NOT free
  ///
  /// The guard is also held by this isolate's `CircleManagerFfi`, which is a
  /// provider singleton used across the app and is deliberately left alone —
  /// `detached` can be followed by `resumed` (Android activity recreation), and
  /// disposing it would leave every circle operation broken on the way back.
  /// So this narrows the orphan rather than eliminating it: the engine, its
  /// supervisor tasks, and the process-global session slot are released, which
  /// is every holder except that one.
  ///
  /// # Coming back
  ///
  /// A resume after `detached` finds a stopped engine and restarts it through
  /// the ordinary self-heal, so this is safe to do on a signal that does not
  /// always mean death.
  Future<void> _onDetached() async {
    // Stop the periodic backstop first: a tick landing mid-teardown would race
    // the stop below with a restart, which is the one thing that could leave a
    // fresh session orphaned instead of releasing the old one.
    _liveSyncHealTimer?.cancel();
    // The shared bounded stop, not a second one of its own: an unclassified
    // stop here would read a timed-out teardown as a release and leave the
    // Rule-14 guard orphaned — see [_stopLiveSyncBounded].
    await _stopLiveSyncBounded();
  }

  /// The location service when it is the real one, else null.
  ///
  /// The stream gate ([GeolocatorLocationService.suspendStream] /
  /// [GeolocatorLocationService.resumeStream]) and the foreground-active hint
  /// are implementation concerns, not part of the `LocationService` interface
  /// every test double implements.
  GeolocatorLocationService? get _geolocatorService {
    final service = ref.read(locationServiceProvider);
    return service is GeolocatorLocationService ? service : null;
  }

  /// Mirrors the pause/resume transition into
  /// [GeolocatorLocationService.foregroundActive] — so a backgrounded
  /// `getCurrentLocation()` with a stale cache skips the one-shot GPS request
  /// that iOS can never fulfil in the background — and into
  /// [appForegroundProvider], which is what makes a provider build that
  /// happens while the app is away refuse to START a location session.
  void _setForegroundActive(bool active) {
    // `ref` on a `ConsumerState` is only usable while the element is mounted,
    // and `detached` dispatches this from a tear-down that may already have
    // unmounted it — a provider read or write there throws.
    if (!mounted) return;
    _geolocatorService?.foregroundActive = active;
    ref.read(appForegroundProvider.notifier).state = active;
  }

  // Fix 6: _onPaused is now async so it can await the ordered writes.
  // didChangeAppLifecycleState ignores the returned Future, which is fine —
  // the awaited sequence runs to completion in the background without
  // blocking the framework's lifecycle dispatch.
  Future<void> _onPaused() async {
    // FIRST, for the same reason `_onDetached` states: a heal tick landing
    // mid-pause would restart the engine while the Android branch below is
    // stopping it to hand the MLS session over — leaving a FRESH session
    // holding the Rule-14 guard the foreground service is waiting for, which
    // is strictly worse than not healing at all. `_handOffMlsSession` is
    // awaited, so cancelling after it would leave the whole handoff window
    // exposed.
    _liveSyncHealTimer?.cancel();

    final bgEnabled = ref.read(backgroundSharingProvider);

    // Only the iOS sharing-on branch can burst, so no other pause pays for the
    // roster read.
    final burstCircles = bgEnabled && Platform.isIOS
        ? _burstEligibleCircles()
        : const <Circle>[];

    // Release the platform location subscription BEFORE the ownership write
    // below hands publishing to the foreground service — this isolate must
    // have let go of GPS before another one is told to take over.
    //
    // A direct, synchronous service call, never a provider rebuild: a watched
    // write cancels the running subscription at once but SCHEDULES the rebuild
    // inside a frame, and Flutter disables frames before the lifecycle
    // observers run — so a release that rides a rebuild lands at RESUME.
    final locationService = _geolocatorService;
    if (!shouldKeepLocationStreamWhilePaused(
      backgroundSharingEnabled: bgEnabled,
      isIOS: Platform.isIOS,
    )) {
      locationService?.suspendStream();
    }
    // Cleared on the CONSENT condition, not on the keep rule: with sharing on
    // the warm Android fix still serves the resume publish inside its
    // freshness window, and with sharing off no coordinate may survive the
    // pause on either platform (privacy Rule 10).
    if (!bgEnabled) locationService?.clearCachedPosition();

    // Stop the foreground-active heartbeat before any handoff. On the
    // Android branch this prevents the heartbeat from racing the
    // `markForegroundActive(active: false)` write below; on iOS /
    // bg-disabled paths the heartbeat has no consumer once the UI is
    // hidden.
    _foregroundHeartbeatTimer?.cancel();
    // Public-profile freshness is a foreground concern: a launch that is
    // backgrounded within the settle window must not fire a relay fetch with
    // no UI to render it. Resume re-triggers the refresh anyway.
    _coldStartProfileRefreshTimer?.cancel();
    // Stop the location-access silence watchdog. It drives a banner nobody can
    // see while backgrounded, and its recovery edge invalidates
    // `locationStreamProvider` — which would cancel the kept iOS session now
    // and rebuild it only at the resume frame, and with background sharing OFF
    // also runs that provider's `clearCachedPosition()`. `_onResumed` calls
    // `resume()` and then `refresh()`, which re-decides it from a fresh
    // platform read.
    ref.read(locationAccessProvider.notifier).suspend();

    // Cancel the maintenance timers a backgrounded app must not run. The
    // scheduler's arming gate only refuses to RE-ARM after a tick settles, so
    // without this a pause landing between two ticks still bought one
    // KeyPackage and one relay-list relay round-trip from the timers already
    // armed. Health goes with them on every branch since P4: the iOS
    // keep-alive branch now receives by bounded burst, so a health tick
    // between bursts could only put back the standing REQs the burst exists to
    // close. The public-profile sweep is the one timer left armed — it gates
    // inside its own tick instead. See `suspendForBackground`.
    ref.read(maintenanceSchedulerProvider.notifier).suspendForBackground();

    if (bgEnabled && Platform.isAndroid) {
      // Android: hand off publishing to the already-running foreground
      // service. The service was started from `initState` via
      // `backgroundServiceLifecycleProvider` (see CLAUDE.md /
      // background_location_provider.dart) — Android 12+ rejects
      // `FOREGROUND_SERVICE_LOCATION` start requests issued from a
      // non-visible activity, so we deliberately do **not** start it
      // here.
      ref.read(locationPublishSchedulerProvider.notifier).stopScheduling();
      _stopMotionTrigger();
      // Resolved before the awaits below: the handoff can outlive this State,
      // and the foreground service never localizes anything itself — it has no
      // widget tree, so both notification texts are resolved here and handed
      // to it (see `appLocalizationsProvider`).
      final l10n = ref.read(appLocalizationsProvider);
      // Fix 6: Await in order — persist seed FIRST, then release
      // ownership. If the background isolate picks up active=false
      // before the last-publish timestamp is written, it may seed its
      // jitter target from stale data (or no data).
      if (_lastPublishTime != null) {
        await BackgroundLocationManager.writeLastPublishTime(_lastPublishTime!);
      }
      // Clear the foreground-active timestamp so the background isolate
      // takes over publishing (MLS single-writer handoff). Update the
      // notification text so the user can distinguish "foreground
      // running" from "actively sharing in background".
      await BackgroundLocationManager.markForegroundActive(active: false);

      // Hand the MLS session to the service. Rule 14 allows exactly one live
      // session per database per process, so while this isolate holds it the
      // service cannot open one and therefore cannot publish — the whole
      // reason background sharing was dead.
      //
      // Ordering matters: stop live-sync BEFORE releasing the manager. The
      // engine holds its own `Arc` on that manager, so releasing first would
      // leave the guard held by the engine and hand over nothing.
      //
      // This isolate stays alive and takes the session back on resume through
      // the ordinary handover, so nothing here is destructive. If it fails, the
      // service falls back to its own reclaim — slower, but it still recovers.
      final handedOff = await _handOffMlsSession();
      // The notification is the ONLY thing the user can see while backgrounded,
      // so it must not claim work that cannot happen. A declined handoff means
      // this isolate still holds the Rule-14 guard, so the service will not
      // publish or receive at all until the app is reopened — which is also the
      // action that repairs it (`NostrCircleService._recoverHeldSession`).
      unawaited(
        BackgroundLocationManager.updateNotification(
          text: handedOff
              ? l10n.fgsNotificationSharing
              : l10n.fgsNotificationPaused,
        ),
      );
      if (handedOff) {
        // Prompt the service to start its first cycle now instead of at its
        // next watchdog tick. Only on a handoff that COMPLETED: a declined one
        // means the bounded stop timed out and this isolate still holds the
        // Rule-14 guard, so signalling would move the service's reclaim probe
        // from "≤ 72 s later" to "now, while that stop may still be unwinding".
        BackgroundLocationManager.signalTask(kForegroundPausedSignal);
      }
    } else if (Platform.isIOS) {
      if (MapShell.shouldKeepPublishingWhilePaused(
        backgroundSharingEnabled: bgEnabled,
        isIOS: Platform.isIOS,
      )) {
        // iOS + background sharing on: nothing to stop. The unified
        // `locationStreamProvider` stream already asked Haven's own
        // CoreLocation session for background capability (it watches
        // `backgroundSharingProvider` directly), so the session that keeps
        // this process executing was
        // established the moment the toggle turned on — necessarily while
        // foregrounded, as iOS requires — and the native
        // `HavenBackgroundSessionHandler` holds the CoreLocation session
        // objects that make that keep-alive effective on iOS 17+. The
        // publish scheduler and `_motionSub` keep running exactly
        // as in the foreground, giving background publishing both a periodic
        // floor and movement-driven responsiveness.
        //
        // RECEIVE is those same ticks. Each one now runs a bounded burst
        // instead of a bare publish — open every REQ at its persisted cursor,
        // let the stored replay land, publish at the resulting epoch, fold any
        // due KeyPackage/relay-list maintenance onto the warm pool, settle,
        // pause, close — so between publishes the engine holds no subscription
        // and no socket at all.
        //
        // NO timer arms any of that, and none may. The maintenance timers are
        // cancelled on every branch, health included: a health tick landing
        // between bursts inspects a paused engine and learns nothing, and one
        // landing DURING a burst passes the engine's paused gate, reads the
        // mid-`connect()` pool as dropped and repairs it through the FOREGROUND
        // re-anchor — standing REQs, an inbox REQ replaying
        // `INBOX_RESUBSCRIBE_LOOKBACK_SECS` (49 h) of gift wraps keyed on this
        // npub, and a socket held to the next burst's pause, at an instant that
        // is not a publish. The burst IS the repair, at 72-168 s rather than
        // 15 min.
        final pausedAt = DateTime.now();
        final coordinator = _installBurstCoordinator();
        // Start closed rather than open, on BOTH arms: without this the engine
        // keeps the foreground's standing REQ, its socket and the crate's 55 s
        // pinger — to the first tick after a recent publish, and for the whole
        // background window with nothing eligible, where no tick is coming.
        // The stamp rides the burst arm only, for the same reason
        // `_guardedPublish` writes it: that arm publishes every eligible
        // circle, so a motion trigger seconds later would be a duplicate.
        if (burstCircles.isNotEmpty &&
            MapShell.shouldBurstImmediatelyOnPause(
              lastPublishAt: _lastPublishTime,
              now: pausedAt,
            )) {
          _lastPublishTime = pausedAt;
          unawaited(_driveBurstNow(coordinator, burstCircles));
        } else {
          unawaited(coordinator.closeIdle());
        }
      } else {
        // Toggle off — or its persisted value not yet loaded: the notifier
        // constructs `false` and resolves the stored value asynchronously,
        // so a pause racing a cold launch can read a stale `false` here.
        // Stop the publish drivers as the generic branch would; the watcher
        // below re-arms them if the load resolves `true` while paused (R1).
        ref.read(locationPublishSchedulerProvider.notifier).stopScheduling();
        _stopMotionTrigger();
      }
      // The engine, on the same rule Android uses. `PausedRelayOwner.none`
      // closes only the PUBLISH pool; the standing per-circle REQs (the
      // receive plane's, one per circle — unrelated to the publish tick), the
      // inbox
      // REQ, the engine's own socket and the crate's 55 s pinger are this
      // plane's, and with sharing off nothing in this process needs any of
      // them for the whole background window. Stopping is also the recoverable
      // direction — the resume heal restarts a stopped engine, where a paused
      // one is invisible to it.
      //
      // Only the engine: nothing reclaims this session on iOS, so
      // `releaseForHandoff()` would latch every `getCircleManagerFfi()` closed
      // until the next resume for no one's benefit.
      //
      // Issued, not awaited: the R1 watcher below has to be installed in this
      // same synchronous run or a consent that resolves during the stop's
      // round trip is never delivered at all. Kept in [_pausedEngineStop] so
      // that edge can order its restart behind it.
      if (MapShell.shouldStopLiveSyncOnPause(
        isIOS: Platform.isIOS,
        backgroundSharingEnabled: bgEnabled,
      )) {
        _pausedEngineStop = _stopLiveSyncBounded();
      }
      // ONE watcher for BOTH consent edges while paused, installed
      // regardless of the toggle's value at pause time:
      //
      // C4 (true→false): install it UNCONDITIONALLY here (not inside the
      // `liveSyncEnabled`-gated receive-timer setup) so a mid-pause opt-out
      // deterministically stops every publish/receive driver — the
      // OS-suspension fallback alone would leave a non-deterministic
      // seconds-to-minutes window of continued publishing after consent was
      // withdrawn.
      //
      // R1 (false→true): a pause that raced the notifier's async load read a
      // stale `false` above; when the persisted consent resolves `true`, the
      // drivers are re-armed. Restarting the stream from the background is
      // viable because the persisted consent means the AppDelegate armed the
      // CoreLocation session objects at launch. The consent itself can only
      // be `true` via the disclosure-gated enable paths, so this edge never
      // originates sharing the user did not opt into.
      _bgSharingPausedSub?.close();
      _bgSharingPausedSub = ref.listenManual<bool>(backgroundSharingProvider, (
        _,
        next,
      ) {
        if (next) {
          // Idempotent replays of what the enabled pause branch keeps
          // running; the sockets come back with the next burst.
          ref.read(locationPublishSchedulerProvider.notifier).startScheduling();
          _startMotionTrigger();
          _startIosBackgroundReceiveTimer();
          // Including the receive path: this process has just become the
          // background receiver, and its receive path is the burst. AFTER
          // `startScheduling()`, which is what re-raises the scheduler's
          // active flag — the burst publisher hard-gates on it, so a sink
          // installed ahead of it would open a socket and publish nothing.
          //
          // A timer would be the wrong repair here even though the process is
          // executable: it is a background wake whose tick can put a standing
          // REQ back between bursts (R14).
          //
          // The stale-`false` arm above STOPPED the engine, so the session has
          // to come back before the burst that is supposed to carry it — a
          // burst opened against a stopped session receives nothing and
          // reports a failed open to the sharing banner for this branch's own
          // fault.
          final receiving = _restartReceiveAfterPausedStop();
          final coordinator = _installBurstCoordinator();
          // And start closed on both arms, exactly as the pause branch does.
          // This edge arrives at the same state late, and `startScheduling()`
          // above arms FRESH jittered schedules — so its first tick is a full
          // 72-168 s away, and its first tick is also the only thing that
          // would ever close what it inherited. Same rule and same stamp:
          // [MapShell.shouldBurstImmediatelyOnPause] is what stops a consent
          // flip landing seconds after a publish from re-sending it.
          final armedAt = DateTime.now();
          final armedCircles = _burstEligibleCircles();
          if (armedCircles.isNotEmpty &&
              MapShell.shouldBurstImmediatelyOnPause(
                lastPublishAt: _lastPublishTime,
                now: armedAt,
              )) {
            _lastPublishTime = armedAt;
            unawaited(
              receiving.then((_) => _driveBurstNow(coordinator, armedCircles)),
            );
          } else {
            unawaited(receiving.then((_) => coordinator.closeIdle()));
          }
          return;
        }
        ref.read(locationPublishSchedulerProvider.notifier).stopScheduling();
        _stopMotionTrigger();
        _receiveTimer?.cancel();
        _receiveTimer = null;
        // The process is about to suspend and nothing here receives any
        // more. Idempotent with the pause above — nothing between them arms a
        // maintenance timer since P4 — and kept because this branch is the
        // opt-out's own teardown: it states what must be true when consent is
        // withdrawn, rather than inheriting it.
        ref.read(maintenanceSchedulerProvider.notifier).suspendForBackground();
        // Withdraw the keep-alive DIRECTLY, here. The rebuild this used to
        // rely on cannot run while the app is paused (frames are off), so the
        // CLLocationManager session would have outlived the consent until the
        // next foreground. Cancelling the subscription and releasing the
        // CoreLocation session objects lets the process suspend at once, and
        // the cached fix goes with the consent that produced it (Rule 10).
        _geolocatorService
          ?..suspendStream()
          ..clearCachedPosition();
        unawaited(ref.read(iosBackgroundSessionServiceProvider).disarm());
        // Leave NO socket, whatever the burst plane is doing: with a burst in
        // flight this waits (bounded) for it to reach its own settle-and-pause
        // rather than cutting it, and with none it pauses the engine and shuts
        // the pool directly — the state the toggle-off pause branch would have
        // been in all along. Withdrawn consent must not leave the engine
        // subscribed and a socket open for the rest of the background window.
        unawaited(
          MapShell.releaseBurstPlaneOnOptOut(
            engine: ref.read(subscriptionServiceProvider),
            shutdownPublishPool: _shutdownPublishPool,
            runningBurst: _burstCoordinator?.runningBurst,
          ),
        );
      });
    } else {
      // Android with background sharing off — the `else if` above owns iOS.
      ref.read(locationPublishSchedulerProvider.notifier).stopScheduling();
      _stopMotionTrigger();
      if (MapShell.shouldStopLiveSyncOnPause(
        isIOS: Platform.isIOS,
        backgroundSharingEnabled: bgEnabled,
      )) {
        // Stop the engine, and stop ONLY the engine: with sharing off no
        // isolate reclaims this session, so `releaseForHandoff()` would latch
        // every `getCircleManagerFfi()` closed until the next resume for no
        // one's benefit. The resume heal restarts the engine.
        await _stopLiveSyncBounded();
      }
    }

    // Cancel any one-shot burst still mid-flight, on every pause path above.
    //
    // A burst is no longer instantaneous: it paces its circles seconds apart so
    // that two of them cannot share a kind-445 `created_at` (the engine stamps
    // the outer event from the inner app event's whole-second clock). Without
    // this it would keep publishing for tens of seconds AFTER the Android
    // branch has told the background isolate the foreground is finished
    // (`markForegroundActive(active: false)`). `locationPublisherProvider` has
    // no permanent listeners, so invalidating it disposes it — which is exactly
    // what its own in-burst dispose guard watches for.
    ref.invalidate(locationPublisherProvider);

    // Always cancel foreground-only timers — they are restarted (with
    // platform-appropriate cadences) below where applicable. The heal timer is
    // NOT among them: it is cancelled at the top of this method, before the
    // handoff it must not race.
    _receiveTimer?.cancel();
    _invitationTimer?.cancel();
    _pruneTimer?.cancel();
    _evolutionTimer?.cancel();

    // Cancel any in-flight post-circle-add burst window — its short fetch
    // cadence is meaningless once the user has backgrounded, and we must
    // not leave timers running that fire FFI calls into a paused isolate.
    // The window is short-lived by design; if the user returns later, the
    // regular pollers (resumed below) cover them.
    ref.read(joinWatcherProvider.notifier).cancel();

    // Disconnect idle relay WebSockets — unless the burst plane owns them, in
    // which case the coordinator closes them at the end of every burst and of
    // every idle close, and closing here would only make its first burst pay a
    // cold reconnect (or race a Rule-13 drain). See [PausedRelayOwner].
    if (MapShell.pausedRelayOwner(
          backgroundSharingEnabled: bgEnabled,
          isIOS: Platform.isIOS,
        ) !=
        PausedRelayOwner.burst) {
      unawaited(_shutdownPublishPool());
    }

    if (bgEnabled && Platform.isIOS) {
      // iOS keeps the main isolate alive while CLLocationManager holds
      // its session, so we keep the peer-location fetch timer running
      // to prevent stale rehydration on resume. Cadence is slowed from
      // the 30 s foreground value to 90 s to absorb iOS's bounded
      // background time budget without sacrificing freshness — peer
      // publishes happen every 72–168 s, so 90 s catches updates
      // within one publish window.
      //
      // Crucially we do NOT call `onAppPaused()` on this branch:
      // dropping `_locationCache` and `_hydratedCircles` would force a
      // full re-hydrate-from-disk on every 90 s tick, defeating the
      // purpose. The plaintext residency window is an explicit
      // security tradeoff (CLAUDE.md privacy rule 9): the cache is
      // bounded by the existing 30 min eviction grace plus sender
      // retention, and iOS holds the same coordinates in
      // CLLocationManager state regardless.
      //
      // The pause hands both socket sets to the burst plane
      // ([PausedRelayOwner.burst]), which closes them AT ONCE — the burst this
      // pause drove, or its idle close. So the 90 s receive tick (flag-off
      // builds only) and the scheduler/motion publishes (still running — see
      // [MapShell.shouldKeepPublishingWhilePaused]) dial a cold pool unless
      // they land inside a burst. Both `relayServiceProvider` and the relay
      // handle inside `locationSharingServiceProvider` resolve to the same
      // singleton, so what is open is shared.
      _startIosBackgroundReceiveTimer();
      if (!mounted) return;
    } else {
      // Drop in-memory location caches so a long-running session
      // cannot accumulate plaintext coordinates beyond a single
      // foreground window. The SQLCipher-encrypted last-known-location
      // store is untouched and will rehydrate the cache on resume.
      // Skipped on the iOS-with-bg branch above — see comment there.
      if (!mounted) return;
      ref.read(locationSharingServiceProvider).onAppPaused();
    }
  }

  /// Starts the iOS background-mode `_receiveTimer` at a slower cadence.
  ///
  /// Same overlap-guarded shape as `_startTimers`'s 30 s receive timer, at
  /// 90 s. It does NOT invalidate `memberLocationsProvider` the way the
  /// foreground one does: no widget watches it while the app is paused, so
  /// there is nothing to rebuild. It runs the fork-safe catch-up sweep
  /// instead, whose side effect — the SQLCipher last-known store — is what the
  /// resume rehydrates from.
  ///
  /// Does not check `BackgroundLocationManager.isForegroundActive()`
  /// because that flag coordinates with the Android foreground service,
  /// which is not started on iOS.
  ///
  /// C4 (M7-A): toggling background sharing OFF while the app is paused
  /// cancels this timer immediately via the single `_bgSharingPausedSub`
  /// watcher installed on `_onPaused`'s iOS branch (unconditionally, for
  /// both `liveSyncEnabled` states) — this method no longer installs its
  /// own watcher.
  void _startIosBackgroundReceiveTimer() {
    // When the live-sync engine is enabled it owns the (kept-alive) relay
    // connection and receives in background; this timer is the flag-OFF iOS
    // background receive path.
    if (liveSyncEnabled) return;
    _receiveTimer = Timer.periodic(const Duration(seconds: 90), (_) {
      if (!mounted) return;
      final now = DateTime.now();
      if (_lastLocationFetchTime != null &&
          now.difference(_lastLocationFetchTime!) <=
              const Duration(seconds: 80)) {
        return;
      }
      _lastLocationFetchTime = now;
      unawaited(_runBackgroundCatchUp());
    });
    // C4 (mid-pause disable) is handled by the single `_bgSharingPausedSub`
    // watcher installed unconditionally on `_onPaused`'s iOS branch — its
    // callback cancels this timer too. Installing a second watcher here
    // (as this method did pre-unification) would be reachable only in
    // `liveSyncEnabled == false` builds and would shadow the unified one.
  }

  /// Runs a fork-safe, cursor-anchored receive-only catch-up sweep (M7).
  ///
  /// Replaces the bare background location poll: a commit that arrives while
  /// backgrounded is applied SAFELY (the sweep gates every decrypt on the
  /// persisted staged-commit marker and never blind-applies a same-epoch
  /// sibling). The sweep persists to the SQLCipher last-known store itself, so
  /// there is no UI repaint here — no widget watches while backgrounded, and
  /// `_onResumed` refreshes on return. Best-effort; the sweep never throws.
  ///
  /// `isBackgroundWake: true` is passed so the [CatchupService] chokepoint
  /// (C3) can hard-return if the user disabled background sharing between
  /// the timer fire and the FFI call — belt-and-suspenders after the C4 timer
  /// cancel above.
  Future<void> _runBackgroundCatchUp() async {
    await ref.read(catchupServiceProvider).runCatchup(isBackgroundWake: true);
  }

  Future<void> _onResumed() async {
    // Close the pause-installed C4 watcher BEFORE the debounce early-return:
    // a background→foreground→background→foreground cycle inside the 30 s
    // debounce window would otherwise leave the watcher alive while
    // foregrounded, and a FOREGROUND toggle-off would then silently kill the
    // foreground publish scheduler (background sharing is not a foreground
    // kill switch). The field is null on Android, so this is a safe no-op
    // there; a subsequent pause re-installs it. `_startTimers()` below
    // re-arms the scheduler in any case, including after a spurious
    // mid-pause cancel from the notifier's transient-false rebuild.
    _bgSharingPausedSub?.close();
    _bgSharingPausedSub = null;

    // Take the engine back BEFORE the sink, and take both back here. The flag
    // is what a burst already on the chain reads: it drops a burst queued
    // while paused, and stops the teardown of one in flight before each of its
    // settle / pause / pool-shutdown links. `burstEnabled` cannot do that job
    // — it reads the background-sharing consent, which is still true in the
    // foreground, so nothing else cancels a burst that started at the pause
    // instant and is still running 1-3 s later when the user comes back.
    _foregroundOwnsEngine = true;
    // Take the publish ticks back from the burst coordinator. This one line is
    // the whole of "the foreground publishes directly": with no sink a tick is
    // published here and now, over the engine's own standing subscription,
    // which is what a foregrounded app is allowed to hold. Leaving the sink
    // installed would keep every foreground publish paying an open/settle/pause
    // cycle and — worse — would pause the engine after each one, so a
    // foregrounded map would go blind between its own publishes.
    _burstScheduler?.setTickSink(null);

    // Re-establish the platform location subscription FIRST, and only here:
    // this is the one restart site, and it is foregrounded by construction —
    // iOS refuses to start a background-capable session from the background,
    // so a restart anywhere else is a silent end to background publishing.
    // A no-op on the iOS branch that never suspended.
    _geolocatorService?.resumeStream();

    // Re-check location access BEFORE the debounce, deliberately.
    //
    // Leaving the app to change a system toggle and coming straight back is
    // the single most likely way location access changes, and it lands well
    // inside the 30 s debounce window. Gating the re-check behind the debounce
    // would leave the banner stale in exactly the case it exists for — both
    // directions: still showing after the user turned location back on, and
    // still absent after they turned it off. Cheap: two local platform reads.
    //
    // `resume()` first: `refresh()` deliberately does NOT lift the suspension
    // (it is also reached from a stream error and from the retry button, and
    // a permission revoked while away must not re-open the probe loop for the
    // whole background window).
    ref.read(locationAccessProvider.notifier).resume();
    unawaited(ref.read(locationAccessProvider.notifier).refresh());

    // Reclaim publishing ownership and seed the overlap guard from any
    // background publish that happened while we were paused — BEFORE the
    // debounce, and before the handoff ends below.
    //
    // Before the debounce because the ownership stamp is what stops the
    // foreground service publishing on behalf of a foregrounded app: a
    // glance-and-return inside 30 s used to return above this and leave the
    // stamp at its paused value, so nothing at all published until some later
    // resume finally landed outside the window.
    //
    // Before the handoff ends because the service must be told to stand down
    // and be given time to drain BEFORE this isolate starts re-opening the
    // MLS database it was handed.
    if (Platform.isAndroid) {
      // Mark the foreground active so the background service skips its
      // next `onRepeatEvent` and doesn't race with the foreground
      // scheduler we are about to start. The service itself stays
      // running across resume — restarting it on every resume would
      // pay a teardown and a re-acquisition for nothing (an ESTIMATED
      // cost, model E E-A1/E-A2, `docs/POWER_EFFICIENCY_PLAN.md`
      // §6.5a) and (more importantly) re-trigger Android 12+
      // background-start checks the next time the user backgrounds
      // the app.
      await BackgroundLocationManager.markForegroundActive(active: true);
      // With the stamp written, tell the service to drop its own platform
      // location request; without the signal it keeps it until its next
      // watchdog tick. AFTER the stamp, never before — a cancel taken while
      // the service still reads "no foreground owner" is undone by that same
      // tick. The brief overlap with the UI stream restarted at the top of
      // this method coalesces at the provider to the tighter interval, which
      // is the foreground policy anyway.
      BackgroundLocationManager.signalTask(kForegroundResumedSignal);
      // Wait briefly for any in-flight background publish cycle to
      // drain. The 60 s overlap guard provides defense-in-depth, but
      // explicit handoff avoids stepping on an in-flight encrypt.
      await const BackgroundIdleWaiter().waitUntilIdle();
      if (!mounted) return;
      // Refresh the notification text so the user sees an honest
      // representation of what the service is doing while the app is
      // in the foreground.
      unawaited(
        BackgroundLocationManager.updateNotification(
          text: ref.read(appLocalizationsProvider).fgsNotificationOpen,
        ),
      );
      final bgLastPublish =
          await BackgroundLocationManager.readLastPublishTime();
      if (bgLastPublish != null) {
        _lastPublishTime = bgLastPublish;
      }
      if (!mounted) return;
    }

    // End the pause-time MLS handoff before the debounce and before the heal
    // below. Everything that follows — the heal's engine restart, the
    // publisher invalidations, the resume catch-up — needs the circle manager,
    // and while the handoff holds every one of those opens fails closed by
    // design. Running them ahead of this would spend the whole resume failing
    // and leave the engine down until the next circle-set change.
    _endMlsSessionHandoff();

    // Then drop what the handoff window may have poisoned — immediately after
    // the replay above, so the (possibly empty) snapshot it just fed the
    // re-subscriber is superseded well inside that class's 500 ms debounce.
    _invalidateHandoffWindowPoison();

    // Re-anchor the engine's subscriptions BEFORE the debounce, deliberately —
    // but on a guard of its own, NOT unthrottled.
    //
    // Ahead of the debounce because this is the only repair that recovers a
    // REQ a relay ended with `CLOSED`, and behind the 30 s resume debounce the
    // glance pattern that debounce exists to absorb (shade pull, lock-screen
    // check, app-switcher peek) was exactly what kept it from ever running: a
    // user opening the app BECAUSE peers had stopped appearing routinely got
    // no repair.
    //
    // Guarded because a re-anchor is not the cheap REQ replace it looks like.
    // `resume_after_background` reconnects the pool, waits out
    // `SUBSCRIBE_CONNECT_WAIT`, and re-issues every REQ — including the inbox
    // one, which asks for `INBOX_RESUBSCRIBE_LOOKBACK_SECS` (49 h) of gift
    // wraps keyed on this npub. Every replayed wrap costs an identity-secret
    // materialisation and an FFI NIP-59 unwrap, and every REQ re-advertises
    // that `#p` query. Ten glances must not be ten of those.
    //
    // A PAUSED engine bypasses the throttle, because the throttle's premise
    // does not hold for it: "a second re-anchor inside 60 s re-queries a window
    // the first already covered" is true of a LIVE engine, which kept its REQs
    // and its cursors moving. A paused one holds no REQ at all, so it covered
    // nothing, and a glance landing inside 60 s of the last background burst
    // would otherwise return to the foreground with the engine still paused —
    // no standing subscription until the next publish tick, on the one plane a
    // foregrounded app must have live.
    //
    // A burst still in flight is the third way in, and it bypasses the
    // throttle for a stronger reason than a paused engine does: the pause it
    // is going to take has not happened YET. It lands after this method
    // returns, on an engine the foreground now owns, and no periodic repair
    // sees it — see [MapShell.reanchorOnResume], which is what orders the
    // repair behind it.
    final engine = ref.read(subscriptionServiceProvider);
    final burstInFlight = _burstCoordinator?.runningBurst;
    final resumeAt = DateTime.now();
    if (liveSyncEnabled &&
        (engine.isPaused ||
            burstInFlight != null ||
            MapShell.shouldReanchorOnResume(
              lastReanchorAt: _lastReanchorAt,
              now: resumeAt,
            ))) {
      _lastReanchorAt = resumeAt;
      unawaited(
        MapShell.reanchorOnResume(engine: engine, burstInFlight: burstInFlight),
      );
    }

    // Heal BEFORE the debounce, deliberately.
    //
    // `_onPaused` cancels `_liveSyncHealTimer`, and only `_startTimers()`
    // re-arms it. So a resume inside the debounce window used to skip the heal
    // AND skip the re-arm — leaving a foregrounded app with a dead engine and
    // no periodic backstop at all, indefinitely, until some resume finally
    // landed more than 30 s after the previous one. The glance pattern the
    // debounce exists to absorb (shade pull, lock-screen check, app-switcher
    // peek) is exactly what keeps resumes inside that window, so the debounce
    // was gating recovery precisely when it was least likely to recover on its
    // own.
    //
    // Safe to run unconditionally: `ensureRunning` short-circuits on a running
    // engine, so the repeated-resume case costs one `isRunning` read.
    unawaited(_healLiveSyncIfStopped());

    // Re-arm the maintenance timers, which are not armed while backgrounded.
    ref.read(maintenanceSchedulerProvider.notifier).rearmForForeground();

    // Restart all timers (cancelled on pause), unconditionally.
    //
    // NOT behind the debounce. `_onPaused` stops the publish scheduler, the
    // motion trigger and the foreground-active heartbeat on every pause, and
    // this is the only thing that starts them again — so a glance-and-return
    // inside 30 s used to return above with every one of them dead, and the
    // app sat foregrounded publishing nothing until some later resume landed
    // outside the window. Idempotent by construction: it cancels each timer
    // before arming it, and both `startScheduling()` and `_startMotionTrigger`
    // are replays of what is already running.
    _startTimers();

    // Debounce rapid resume cycles (e.g. notification shade pull on Android).
    // Only the one-shot extras below are debounced — everything above is
    // either idempotent or a repair that a glance must not skip.
    if (_resumeStopwatch.isRunning &&
        _resumeStopwatch.elapsed < const Duration(seconds: 30)) {
      return;
    }
    _resumeStopwatch
      ..reset()
      ..start();

    // Immediate send + receive on app resume. Update _lastPublishTime
    // so the overlap guard prevents a motion trigger from double-firing
    // within seconds of resume.
    _lastPublishTime = DateTime.now();
    if (!mounted) return;
    // Publishers + the location view refresh on every resume that REACHES
    // here, never behind the extras window below: sending on return and
    // showing where peers are now are the two things the user can SEE, and a
    // throttled promise is a broken one. The contrast is with that window, not
    // with the debounce — the 30 s `_resumeStopwatch` return above gates this
    // too, so a quicker return refreshes neither. Anything that leans on the
    // one-shot burst as a per-resume backstop has to price that in.
    ref
      ..invalidate(locationPublisherProvider)
      ..invalidate(memberLocationsProvider)
      ..read(locationPublisherProvider)
      ..read(memberLocationsProvider);

    // The one-shot EXTRAS: work a resume repeats "just in case", every piece
    // of which already runs on a periodic timer of its own. Ten shade-pull
    // glances an hour used to be ten KeyPackage probes, ten profile fetches,
    // ten prunes and ten tile-cache sweeps — none of which returned anything
    // the timers were not about to fetch anyway.
    //
    // The stamp is also the SIGNAL: `MapPage` evicts its tile cache off a
    // listener on this provider rather than off its own resume callback,
    // because both widgets observe the same lifecycle edge and whichever ran
    // first would otherwise stamp the other out of its turn.
    final runExtras = shouldRunResumeExtras(
      lastAt: ref.read(lastResumeExtrasAtProvider),
      now: resumeAt,
    );
    if (runExtras) {
      ref
        ..read(lastResumeExtrasAtProvider.notifier).state = resumeAt
        ..invalidate(keyPackagePublisherProvider)
        ..read(keyPackagePublisherProvider);
      // §6.2: refresh member/own public profiles on app resume.
      triggerProfileRefresh(
        ref,
        maxAge: profileInteractiveMaxAge,
        circles: ref.read(circlesProvider).valueOrNull,
      );
      // Prune in case the device slept past the hourly tick — the tick this
      // backstops is itself hourly, so a per-glance sweep backstops nothing.
      unawaited(_runPrune());
    }
    // Resume any own-profile publish left queued while backgrounded. Not an
    // extra: it dials nothing unless a publish is actually queued, and it
    // honours its own persisted backoff.
    triggerProfileSyncRetry(ref);
    // (The engine re-anchor ran before the debounce — see the comment there.)
    if (!liveSyncEnabled) {
      ref
        ..invalidate(invitationPollerProvider)
        ..read(invitationPollerProvider)
        // Immediately poll for evolution events on resume — leave/handoff
        // commits that arrived while backgrounded are processed before the
        // next location fetch, keeping the local MDK epoch in sync.
        ..invalidate(evolutionPollerProvider)
        ..read(evolutionPollerProvider);
    }
    // Reset the evolution- and invitation-poll overlap guards after the
    // on-resume trigger so the periodic timers do not double-fire within
    // their respective overlap windows.
    _lastEvolutionPollTime = DateTime.now();
    _lastInvitationPollTime = DateTime.now();
  }

  // Sheet snap points mirrored from `circles/circles_bottom_sheet.dart`
  // (the subset this shell drives: the collapsed min, the low "peek" rest
  // point used after tap-to-focus, and the max — which with the min gives
  // `_animateSheetDuration` a stable range to divide by).
  static const double _kMinSheetSize = 0.12;
  static const double _kPeekSheetSize = 0.30;
  static const double _kMaxSheetSize = 0.85;

  Future<void> _collapseSheet() async {
    await _animateSheetTo(_kMinSheetSize);
  }

  /// Partially collapses the sheet to the low "peek" snap so most of the
  /// map below becomes visible while keeping the circle selector and the
  /// top of the member list in view. Called after the user taps a member
  /// to recenter the camera — at that point the map is what they want to
  /// see.
  Future<void> _partiallyCollapseSheet() async {
    await _animateSheetTo(_kPeekSheetSize);
  }

  /// Animates the sheet to [target] snap size, guarded against the
  /// `DraggableScrollableController` assertion that fires when the sheet
  /// is already at the requested size. When the user has asked the OS
  /// for reduced motion (WCAG 2.3.3 / iOS "Reduce Motion"), we jump to
  /// the snap instead of animating.
  ///
  /// Duration scales with travel distance (M3 motion guidance: longer
  /// transitions for bigger jumps) so a 0.85→0.12 collapse no longer
  /// takes the same time as a 0.5→0.12 collapse. The curve is
  /// `easeOutCubic` (M3 standard-decelerate), which matches the feel
  /// of programmatic Apple sheet transitions without spring overshoot.
  Future<void> _animateSheetTo(double target) async {
    if (!_sheetController.isAttached) return;
    final current = _sheetController.size;
    if ((current - target).abs() <= 0.01) return;
    if (mounted && MediaQuery.disableAnimationsOf(context)) {
      _sheetController.jumpTo(target);
      return;
    }
    await _sheetController.animateTo(
      target,
      duration: _animateSheetDuration(current, target),
      curve: Curves.easeOutCubic,
    );
  }

  /// Maps a sheet position delta to an animation duration in the M3
  /// 200–450 ms band. The full sheet travel range is 0.73 (max 0.85
  /// minus min 0.12); a 0.85→0.12 collapse gets ~445 ms, a 0.5→0.12
  /// hop gets ~290 ms, and tiny corrections clamp at 200 ms.
  static Duration _animateSheetDuration(double current, double target) {
    const fullRange = _kMaxSheetSize - _kMinSheetSize;
    final fraction = (target - current).abs() / fullRange;
    final ms = (220 + 350 * fraction).clamp(200.0, 450.0);
    return Duration(milliseconds: ms.round());
  }

  @override
  void dispose() {
    // The publish scheduler lives in
    // `locationPublishSchedulerProvider` (container-scoped, like
    // `maintenanceSchedulerProvider`): its timers are cancelled via
    // Ref.onDispose + the explicit invalidate in `deleteIdentity`, NOT here
    // (repo convention: no `ref` use in dispose()).
    _receiveTimer?.cancel();
    _invitationTimer?.cancel();
    _pruneTimer?.cancel();
    _evolutionTimer?.cancel();
    _liveSyncHealTimer?.cancel();
    _foregroundHeartbeatTimer?.cancel();
    _coldStartProfileRefreshTimer?.cancel();
    _stopMotionTrigger();
    // Deferred-startup watcher: a late identity must never run startup against
    // a torn-down tree.
    _deferredStartupSub?.close();
    _deferredStartupSub = null;
    _bgSharingPausedSub?.close();
    _bgSharingPausedSub = null;
    // Take the publish ticks back, through the captured handle rather than
    // `ref` (forbidden in dispose): the scheduler is container-scoped and
    // outlives this State, so a sink left behind would keep routing every
    // later tick into a coordinator whose `burstEnabled` now reads false
    // through `mounted` — each one opening nothing, publishing nothing and
    // reporting nothing, for the rest of the process. Silent, not loud, which
    // is why the handle is captured rather than reached for.
    //
    // `_foregroundOwnsEngine` is deliberately left as it is: an unmounted
    // shell is not a foreground owner, and flipping it here would stop the
    // teardown of a burst that is still running and leave the engine
    // subscribed with the publish pool open.
    _burstScheduler?.setTickSink(null);
    _burstScheduler = null;
    _burstCoordinator = null;
    // Stop re-subscribing BEFORE tearing the engine down (B0): close the
    // circles listener and cancel any pending / in-flight restart so no
    // start-after-dispose can race the stop below.
    _liveSyncCirclesSub?.close();
    _liveSyncCirclesSub = null;
    _liveSyncResubscriber?.dispose();
    _liveSyncResubscriber = null;
    // Stop the live-sync engine (idempotent; logout's deleteIdentity also stops
    // it — MapShell unmounts when AppRouter swaps back to onboarding). Uses the
    // captured handle, NOT `ref` (forbidden in dispose).
    unawaited(_liveSync?.stop());
    WidgetsBinding.instance.removeObserver(this);
    _sheetController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Watch the foreground-service lifecycle. This is the **only**
    // place that starts the Android service — calling it from `build`
    // guarantees the start request is issued from a visible activity,
    // which Android 12+ requires for `FOREGROUND_SERVICE_LOCATION`.
    // Reading `pause`/`resume` lifecycle events to start the service
    // would fail because `paused == Activity.onStop()` (no longer
    // visible).
    ref.watch(backgroundServiceLifecycleProvider);

    final mediaQuery = MediaQuery.of(context);

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Theme.of(context).brightness == Brightness.dark
            ? Brightness.light
            : Brightness.dark,
      ),
      child: WithForegroundTask(
        child: Scaffold(
          extendBodyBehindAppBar: true,
          body: Stack(
            children: MapShell.buildLayers(
              topPadding: mediaQuery.padding.top,
              bottomPadding: mediaQuery.padding.bottom,
              map: const MapPage(),
              dimOverlay: DimOverlay(
                opacity: _sheetExpansion,
                onDismiss: _collapseSheet,
              ),
              invitationsButton: const InvitationsFloatingButton(),
              settingsButton: const SettingsFloatingButton(),
              statusBanners: const MapStatusBanners(),
              circlesSheet: CirclesBottomSheet(
                controller: _sheetController,
                onExpansionChanged: (expansion) {
                  setState(() => _sheetExpansion = expansion);
                },
                onMemberFocused: () => unawaited(_partiallyCollapseSheet()),
              ),
              // Debug builds only.
              debugOverlay: kDebugMode
                  ? Consumer(
                      builder: (context, ref, _) {
                        final logState = ref.watch(debugLogProvider);
                        if (!logState.isVisible) return const SizedBox.shrink();
                        return const DebugLogOverlay();
                      },
                    )
                  : null,
            ),
          ),
        ),
      ),
    );
  }
}
