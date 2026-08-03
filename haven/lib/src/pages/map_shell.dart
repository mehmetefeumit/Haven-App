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
import 'package:haven/src/providers/location_provider.dart';
import 'package:haven/src/providers/location_publish_scheduler_provider.dart';
import 'package:haven/src/providers/location_sharing_provider.dart';
import 'package:haven/src/providers/maintenance_scheduler_provider.dart';
import 'package:haven/src/providers/relay_preferences_provider.dart';
import 'package:haven/src/providers/self_update_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/nostr_circle_service.dart';
import 'package:haven/src/services/foreground_liveness_probe.dart';
import 'package:haven/src/services/background_idle_waiter.dart';
import 'package:haven/src/services/background_location_manager.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/geolocator_location_service.dart';
import 'package:haven/src/services/identity_service.dart' show Identity;
import 'package:haven/src/services/live_sync_resubscriber.dart';
import 'package:haven/src/services/location_service.dart';
import 'package:haven/src/services/nostr_relay_service.dart';
import 'package:haven/src/services/pending_leave_service.dart';
import 'package:haven/src/services/subscription_service.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:haven/src/utils/profile_refresh_trigger.dart';
import 'package:haven/src/widgets/circles/circles_bottom_sheet.dart';
import 'package:haven/src/widgets/common/dim_overlay.dart';
import 'package:haven/src/widgets/common/invitations_button.dart';
import 'package:haven/src/widgets/common/legacy_cutover_explainer_dialog.dart';
import 'package:haven/src/widgets/common/settings_button.dart';
import 'package:haven/src/widgets/debug/debug_log_overlay.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  /// Whether the relay WebSocket should stay connected while the app is
  /// paused.
  ///
  /// On the iOS background-sharing branch the main isolate stays alive
  /// (held by the CLLocationManager retention stream) and keeps publishing
  /// plus running the 90 s receive timer, so tearing the socket down here
  /// only forces a cold reconnect — and a dropped first publish — on the
  /// very next tick. Everywhere else the relay is disconnected for metadata
  /// minimisation: Android hands publishing off to the foreground-service
  /// isolate (which owns its own relay), and with background sharing off the
  /// app is genuinely going idle.
  ///
  /// Exposed as a static so the pause/resume decision is unit-tested without
  /// pumping the widget (which requires the Rust bridge).
  @visibleForTesting
  static bool shouldKeepRelayConnectedWhilePaused({
    required bool backgroundSharingEnabled,
    required bool isIOS,
  }) => backgroundSharingEnabled && isIOS;

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
  /// Same truth table as [shouldKeepRelayConnectedWhilePaused] today, but a
  /// deliberately separate concept — if the two ever diverge, collapsing
  /// them would make the divergence a silent bug.
  @visibleForTesting
  static bool shouldKeepPublishingWhilePaused({
    required bool backgroundSharingEnabled,
    required bool isIOS,
  }) => backgroundSharingEnabled && isIOS;

  @override
  ConsumerState<MapShell> createState() => _MapShellState();
}

class _MapShellState extends ConsumerState<MapShell>
    with WidgetsBindingObserver {
  double _sheetExpansion = 0;
  final DraggableScrollableController _sheetController =
      DraggableScrollableController();
  // Recurring location publishing is driven by `locationPublishSchedulerProvider`
  // (one independent jittered schedule PER circle, so a relay cannot correlate
  // a device's circles by co-timing — privacy decorrelation). MapShell only
  // starts/stops it across the app lifecycle; the per-circle timers live in the
  // notifier. The one-shot "publish all now" burst still goes through
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

  /// The live-sync engine handle, captured in [_startLiveSync] so [dispose] can
  /// stop it without `ref` (forbidden in dispose). `null` until started / when
  /// `liveSyncEnabled` is off.
  SubscriptionService? _liveSync;

  /// B0 (M11): re-subscribes the engine when the accepted-circle set changes
  /// mid-session (create / accept / leave), since the engine subscribes only to
  /// the circles present at `start()`. Installed by [_startLiveSync]; `null`
  /// until started / when `liveSyncEnabled` is off.
  LiveSyncResubscriber? _liveSyncResubscriber;

  /// The `circlesProvider` listener feeding [_liveSyncResubscriber]. Closed on
  /// dispose so no re-subscribe fires after teardown.
  ProviderSubscription<AsyncValue<List<Circle>>>? _liveSyncCirclesSub;

  DateTime? _lastPublishTime;
  DateTime? _lastLocationFetchTime;
  DateTime? _lastInvitationPollTime;
  DateTime? _lastEvolutionPollTime;
  final _resumeStopwatch = Stopwatch();

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
  // backgrounded: the per-circle publish scheduler
  // (`locationPublishSchedulerProvider`) keeps firing on its jittered cadences
  // and `_motionSub` keeps delivering movement-driven publishes. There is no
  // second "background stream" — geolocator supports exactly one stream, and
  // a second request would silently inherit the first stream's settings
  // (the defect that originally broke iOS background publishing). On
  // Android, the foreground service handles background publishing instead.
  //
  // C4 (M7-A): installed on the iOS pause branch UNCONDITIONALLY (i.e. for
  // both `liveSyncEnabled` states) so that toggling background sharing OFF
  // while paused deterministically tears down every publish/receive driver
  // (scheduler, motion trigger, receive timer, warm relay socket) instead of
  // waiting for the OS to suspend the process. Closed on resume and on
  // dispose.
  ProviderSubscription<bool>? _bgSharingPausedSub;

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
    // Periodic + post-join leaf-key rotation is disabled (M5,
    // `enablePeriodicSelfUpdate`): leaderless self-update is the dominant
    // fork generator. Gated, not deleted, so it re-enables cleanly post-M3/M4.
    if (enablePeriodicSelfUpdate) {
      ref.read(selfUpdateProvider);
    }
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
      debugPrint('[MapShell] pruneExpiredLastKnown failed: ${e.runtimeType}');
      if (kDebugMode) {
        debugPrint('[MapShell] pruneExpiredLastKnown error: $e');
      }
    }
    // The widget may have been disposed while the first FFI call was in
    // flight. `ref` throws once the ConsumerState is disposed, so guard
    // BEFORE reading it again for the second prune (C1). This runs on both the
    // success and failure paths of the first prune.
    if (!mounted) return;
    try {
      await ref.read(circleServiceProvider).pruneProcessedGiftWraps();
    } on Object catch (e) {
      debugPrint('[MapShell] pruneProcessedGiftWraps failed: ${e.runtimeType}');
      if (kDebugMode) {
        debugPrint('[MapShell] pruneProcessedGiftWraps error: $e');
      }
    }
  }

  /// Builds the [FfiGroupSpec]s for the accepted circles + reads the inbox
  /// relays, then starts the live-sync engine. Best-effort: a failure leaves
  /// the app functional (the next resume retries via `resumeAfterBackground`).
  Future<void> _startLiveSync() async {
    try {
      // Capture the handle so dispose() can stop it without `ref`.
      _liveSync = ref.read(subscriptionServiceProvider);
      final circles = await ref.read(circlesProvider.future);
      final groups = LiveSyncResubscriber.groupsForCircles(circles);
      final inboxRelays = await ref.read(inboxRelaysProvider.future);
      if (!mounted) return;
      await _liveSync!.start(groups: groups, inboxRelays: inboxRelays);
      // The widget may have been disposed during the start round-trips (rapid
      // logout): dispose()'s `_liveSync?.stop()` ran before start() completed,
      // so tear down the now-started session to avoid orphaning it.
      if (!mounted) {
        unawaited(_liveSync?.stop());
        return;
      }
      // B0 (M11): the engine subscribes only to the circles present here at
      // start(). Install a re-subscriber so a mid-session create / accept /
      // leave re-anchors the engine to the new accepted-circle set (the
      // M3-deferred stop+start interim) instead of silently receiving no live
      // locations for the new circle until relaunch. `fireImmediately: true`
      // closes the tiny race where the accepted set changed during the awaits
      // above: the immediate fire is a no-op if the current set still matches
      // the started signature, and re-anchors otherwise.
      _liveSyncResubscriber = LiveSyncResubscriber(
        engine: _liveSync!,
        inboxRelays: () => ref.read(inboxRelaysProvider.future),
        initialSignature: LiveSyncResubscriber.signatureForGroups(groups),
        initialGroups: groups,
      );
      _liveSyncCirclesSub = ref.listenManual<AsyncValue<List<Circle>>>(
        circlesProvider,
        (_, next) {
          next.whenData(_onLiveSyncCirclesChanged);
        },
        fireImmediately: true,
      );
    } on Object catch (e) {
      debugPrint('[MapShell] live-sync start failed: ${e.runtimeType}');
      // The FFI error is a Rust `Result<_, String>` already sanitized by
      // `redact_hex_sequences`; surface its (redacted) detail in debug/e2e
      // builds so a start failure is diagnosable instead of an opaque
      // "String" runtimeType. Release builds keep only the runtimeType.
      if (kDebugMode) {
        debugPrint('[MapShell] live-sync start error: $e');
      }
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

    // Recurring location publishing: each accepted circle publishes on its OWN
    // independent jittered cadence (nominal `kLocationUpdateInterval`, ±40% via
    // Rust-side CSPRNG per tick), owned by `locationPublishSchedulerProvider`.
    // Independent per-circle schedules mean a relay can't correlate a device's
    // circles by co-timing (privacy decorrelation). Reading the notifier builds
    // it (arming a schedule per current circle); `startScheduling` re-activates
    // after a background pause. Cancelled on pause (below), on dispose
    // (Ref.onDispose), and on `deleteIdentity`.
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
    // periodic + post-join self-update is the dominant MLS fork generator
    // (see `enablePeriodicSelfUpdate`). Epochs now advance only on real
    // membership changes.

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

  /// Releases this isolate's MLS session so the foreground service can take it.
  ///
  /// Android + background-sharing only: it is the one configuration where
  /// another isolate needs the session while this one is merely paused.
  Future<void> _handOffMlsSession() async {
    // The engine holds its own Arc on the circle manager, so it must go first
    // or the release frees nothing.
    try {
      await _liveSync?.stop();
    } on Object catch (e) {
      debugPrint('[MapShell] handoff: live-sync stop failed: ${e.runtimeType}');
    }

    final service = ref.read(circleServiceProvider);
    if (service is! NostrCircleService) return;
    try {
      final released = service.releaseForHandoff();
      debugPrint('[MapShell] handoff: released=$released');
    } on Object catch (e) {
      // Never throw out of the pause path: the framework dispatches it without
      // awaiting, and the service's own reclaim is the fallback.
      debugPrint('[MapShell] handoff failed: ${e.runtimeType}');
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
  Future<void> _healLiveSyncIfStopped() async {
    final resubscriber = _liveSyncResubscriber;
    if (resubscriber == null) return;
    try {
      if (await resubscriber.ensureRunning()) {
        _consecutiveHealFailures = 0;
        return;
      }
    } on Object catch (e) {
      // Never surface the raw error (Rule 8) and never let a failed heal break
      // the timer — the next tick retries.
      debugPrint('[MapShell] live-sync heal failed: ${e.runtimeType}');
    }
    // Counted, not just logged: a relay set that is unreachable would otherwise
    // be swept on every tick indefinitely.
    if (_consecutiveHealFailures < _healBackoffMaxMultiplier) {
      _consecutiveHealFailures++;
    }
  }

  // ---- Motion-triggered publish helpers ----

  void _startMotionTrigger() {
    _motionSub?.close();
    _motionSub = ref.listenManual<AsyncValue<Position>>(
      locationStreamProvider,
      (_, next) {
        next.whenData(_onMotionPosition);
      },
    );
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
    final distance = _haversineMeters(
      last.latitude,
      last.longitude,
      position.latitude,
      position.longitude,
    );
    if (distance < kMotionTriggerDistanceMeters) return;

    // Sufficient movement detected — check the overlap guard before
    // actually publishing. This shares the guard with the scheduler
    // and the resume-branch so none of them can stampede.
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

  /// Haversine distance in metres between two WGS-84 points.
  static double _haversineMeters(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    const r = 6371000.0; // Earth mean radius in metres
    final dLat = _toRadians(lat2 - lat1);
    final dLon = _toRadians(lon2 - lon1);
    final a =
        math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_toRadians(lat1)) *
            math.cos(_toRadians(lat2)) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    return r * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }

  static double _toRadians(double degrees) => degrees * math.pi / 180;

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
    final liveSync = _liveSync;
    if (liveSync == null) return;
    try {
      await liveSync.stop();
    } on Object catch (e) {
      // Never the raw error (Rule 8), and never rethrow: this runs on a
      // best-effort teardown path with no one to handle a failure.
      debugPrint('[MapShell] detached live-sync release: ${e.runtimeType}');
    }
  }

  /// Mirrors the pause/resume transition into
  /// [GeolocatorLocationService.foregroundActive] so a backgrounded
  /// `getCurrentLocation()` with a stale cache skips the one-shot GPS
  /// request that iOS can never fulfil in the background.
  void _setForegroundActive(bool active) {
    final locationService = ref.read(locationServiceProvider);
    if (locationService is GeolocatorLocationService) {
      locationService.foregroundActive = active;
    }
  }

  // Fix 6: _onPaused is now async so it can await the ordered writes.
  // didChangeAppLifecycleState ignores the returned Future, which is fine —
  // the awaited sequence runs to completion in the background without
  // blocking the framework's lifecycle dispatch.
  Future<void> _onPaused() async {
    final bgEnabled = ref.read(backgroundSharingProvider);

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
      await _handOffMlsSession();
      unawaited(
        BackgroundLocationManager.updateNotification(
          text: 'Haven is sending and receiving location information',
        ),
      );
    } else if (MapShell.shouldKeepPublishingWhilePaused(
      backgroundSharingEnabled: bgEnabled,
      isIOS: Platform.isIOS,
    )) {
      // iOS + background sharing on: nothing to stop. The unified
      // `locationStreamProvider` stream already carries background-capable
      // AppleSettings (it watches `backgroundSharingProvider` directly), so
      // the CLLocationManager session that keeps this process executing was
      // established the moment the toggle turned on — necessarily while
      // foregrounded, as iOS requires. The per-circle publish scheduler and
      // `_motionSub` keep running exactly as in the foreground, giving
      // background publishing both a periodic floor and movement-driven
      // responsiveness.
      //
      // C4: install the disable-while-paused watcher UNCONDITIONALLY here
      // (not inside the `liveSyncEnabled`-gated receive-timer setup) so a
      // mid-pause opt-out deterministically stops every publish/receive
      // driver — the OS-suspension fallback alone would leave a
      // non-deterministic seconds-to-minutes window of continued
      // publishing after consent was withdrawn.
      _bgSharingPausedSub?.close();
      _bgSharingPausedSub = ref.listenManual<bool>(backgroundSharingProvider, (
        _,
        next,
      ) {
        if (next) return;
        ref.read(locationPublishSchedulerProvider.notifier).stopScheduling();
        _stopMotionTrigger();
        _receiveTimer?.cancel();
        _receiveTimer = null;
        // Parity with the pause-time relay decision: had the toggle been
        // off at pause, `shouldKeepRelayConnectedWhilePaused` would have
        // shut the socket down. The stream itself downgrades via the
        // `locationStreamProvider` rebuild (its `backgroundSharingProvider`
        // watch), removing the keep-alive so the process can suspend.
        final relay = ref.read(relayServiceProvider);
        if (relay is NostrRelayService) {
          unawaited(relay.shutdown());
        }
      });
    } else {
      // Background sharing disabled — original behaviour.
      ref.read(locationPublishSchedulerProvider.notifier).stopScheduling();
      _stopMotionTrigger();
    }

    // Always cancel foreground-only timers — they are restarted (with
    // platform-appropriate cadences) below where applicable.
    _receiveTimer?.cancel();
    _invitationTimer?.cancel();
    _pruneTimer?.cancel();
    _evolutionTimer?.cancel();
    _liveSyncHealTimer?.cancel();

    // Cancel any in-flight post-circle-add burst window — its short fetch
    // cadence is meaningless once the user has backgrounded, and we must
    // not leave timers running that fire FFI calls into a paused isolate.
    // The window is short-lived by design; if the user returns later, the
    // regular pollers (resumed below) cover them.
    ref.read(joinWatcherProvider.notifier).cancel();

    // Disconnect idle relay WebSockets — unless the iOS background branch
    // is keeping the main isolate alive, where a warm socket lets the next
    // background publish/fetch land instead of racing a cold reconnect
    // (which silently drops the first publish). See
    // [shouldKeepRelayConnectedWhilePaused].
    if (!MapShell.shouldKeepRelayConnectedWhilePaused(
      backgroundSharingEnabled: bgEnabled,
      isIOS: Platform.isIOS,
    )) {
      final relay = ref.read(relayServiceProvider);
      if (relay is NostrRelayService) {
        unawaited(relay.shutdown());
      }
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
      // The relay is kept connected on this branch (see
      // [shouldKeepRelayConnectedWhilePaused]) so the 90 s receive tick
      // and the scheduler/motion publishes (still running — see
      // [MapShell.shouldKeepPublishingWhilePaused]) reuse a warm socket
      // instead of racing a cold reconnect. Both `relayServiceProvider`
      // and the relay handle inside `locationSharingServiceProvider`
      // resolve to the same singleton, so the warm connection is shared.
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
  /// The body mirrors `_startTimers`'s 30 s receive timer (overlap-guarded
  /// invalidate) but at 90 s. Unlike the foreground variant, this fires
  /// while the map widget is paused — no widget is actively watching
  /// `memberLocationsProvider`, so we explicitly drive the future to
  /// completion to keep the SQLCipher last-known store warm. The
  /// returned `AsyncValue` is intentionally discarded; the side effect
  /// we care about is the `upsertLastKnownLocation` write inside
  /// `LocationSharingService.fetchMemberLocations`.
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

    // Heal BEFORE the debounce, deliberately.
    //
    // `_onPaused` cancels `_liveSyncHealTimer` and only `_startTimers()` (below,
    // after the debounce) re-arms it. So a resume inside the debounce window
    // used to skip the heal AND skip the re-arm — leaving a foregrounded app
    // with a dead engine and no periodic backstop at all, indefinitely, until
    // some resume finally landed more than 30 s after the previous one. The
    // glance pattern the debounce exists to absorb (shade pull, lock-screen
    // check, app-switcher peek) is exactly what keeps resumes inside that
    // window, so the debounce was gating recovery precisely when it was least
    // likely to recover on its own.
    //
    // Safe to run unconditionally: `ensureRunning` short-circuits on a running
    // engine, so the repeated-resume case costs one `isRunning` read.
    unawaited(_healLiveSyncIfStopped());

    // Debounce rapid resume cycles (e.g. notification shade pull on Android).
    if (_resumeStopwatch.isRunning &&
        _resumeStopwatch.elapsed < const Duration(seconds: 30)) {
      // Re-arm the heal backstop even on the debounced path: `_onPaused`
      // cancelled it, and returning here skips the `_startTimers()` that would
      // otherwise bring it back.
      _rearmLiveSyncHealTimer();
      return;
    }
    _resumeStopwatch
      ..reset()
      ..start();

    // Reclaim publishing ownership and seed the overlap guard from any
    // background publish that happened while we were paused.
    if (Platform.isAndroid) {
      // Mark the foreground active so the background service skips its
      // next `onRepeatEvent` and doesn't race with the foreground
      // scheduler we are about to start. The service itself stays
      // running across resume — restarting it on every resume would
      // waste battery and (more importantly) re-trigger Android 12+
      // background-start checks the next time the user backgrounds
      // the app.
      await BackgroundLocationManager.markForegroundActive(active: true);
      // Wait briefly for any in-flight background publish cycle to
      // drain. The 60 s overlap guard provides defense-in-depth, but
      // explicit handoff avoids stepping on an in-flight encrypt.
      await const BackgroundIdleWaiter().waitUntilIdle();
      if (!mounted) return;
      // Refresh the notification text so the user sees an honest
      // representation of what the service is doing while the app is
      // in the foreground.
      unawaited(
        BackgroundLocationManager.updateNotification(text: 'Haven is open'),
      );
      final bgLastPublish =
          await BackgroundLocationManager.readLastPublishTime();
      if (bgLastPublish != null) {
        _lastPublishTime = bgLastPublish;
      }
    }
    // (The pause-installed C4 watcher was already closed at the top of this
    // method, before the debounce — see the comment there.)

    // Restart all timers (cancelled on pause).
    _startTimers();

    // Immediate send + receive on app resume. Update _lastPublishTime
    // so the overlap guard prevents a motion trigger from double-firing
    // within seconds of resume.
    _lastPublishTime = DateTime.now();
    if (!mounted) return;
    // Publishers + the location view refresh on every resume.
    ref
      ..invalidate(locationPublisherProvider)
      ..invalidate(memberLocationsProvider)
      ..invalidate(keyPackagePublisherProvider)
      ..read(locationPublisherProvider)
      ..read(memberLocationsProvider)
      ..read(keyPackagePublisherProvider);
    // §6.2: refresh member/own public profiles on app resume.
    triggerProfileRefresh(
      ref,
      maxAge: profileInteractiveMaxAge,
      circles: ref.read(circlesProvider).valueOrNull,
    );
    if (liveSyncEnabled) {
      // Re-anchor the engine's subscriptions (lossless offline-gap backfill);
      // the engine kept its connection, so this is a fast resubscribe.
      unawaited(ref.read(subscriptionServiceProvider).resumeAfterBackground());
    } else {
      ref
        ..invalidate(invitationPollerProvider)
        ..read(invitationPollerProvider)
        // Immediately poll for evolution events on resume — leave/handoff
        // commits that arrived while backgrounded are processed before the
        // next location fetch, keeping the local MDK epoch in sync.
        ..invalidate(evolutionPollerProvider)
        ..read(evolutionPollerProvider);
    }
    // Periodic + post-join leaf-key rotation is disabled (M5,
    // `enablePeriodicSelfUpdate`); gated so it re-enables cleanly post-M3/M4.
    if (enablePeriodicSelfUpdate) {
      ref
        ..invalidate(selfUpdateProvider)
        ..read(selfUpdateProvider);
    }
    // Reset the evolution- and invitation-poll overlap guards after the
    // on-resume trigger so the periodic timers do not double-fire within
    // their respective overlap windows.
    _lastEvolutionPollTime = DateTime.now();
    _lastInvitationPollTime = DateTime.now();

    // Prune on resume in case the device slept past the hourly tick.
    unawaited(_runPrune());
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
    // The per-circle publish scheduler lives in
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

    final topPadding = MediaQuery.of(context).padding.top;

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
            children: [
              // Full-screen map (always visible)
              const MapPage(),

              // Dim overlay (animated based on sheet expansion)
              Positioned.fill(
                child: DimOverlay(
                  opacity: _sheetExpansion,
                  onDismiss: _collapseSheet,
                ),
              ),

              // Invitations button (top leading edge; mirrors to the right in
              // RTL, respects safe area)
              PositionedDirectional(
                top: topPadding + HavenSpacing.sm,
                start: HavenSpacing.base,
                child: const InvitationsFloatingButton(),
              ),

              // Settings button (top trailing edge; mirrors to the left in
              // RTL, respects safe area)
              PositionedDirectional(
                top: topPadding + HavenSpacing.sm,
                end: HavenSpacing.base,
                child: const SettingsFloatingButton(),
              ),

              // Circles bottom sheet
              CirclesBottomSheet(
                controller: _sheetController,
                onExpansionChanged: (expansion) {
                  setState(() => _sheetExpansion = expansion);
                },
                onMemberFocused: () => unawaited(_partiallyCollapseSheet()),
              ),

              // Debug log overlay (debug builds only)
              if (kDebugMode)
                Consumer(
                  builder: (context, ref, _) {
                    final logState = ref.watch(debugLogProvider);
                    if (!logState.isVisible) return const SizedBox.shrink();
                    return const DebugLogOverlay();
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}
