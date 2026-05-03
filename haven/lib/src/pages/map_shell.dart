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
import 'package:haven/src/pages/map/map_page.dart';
import 'package:haven/src/providers/background_location_provider.dart';
import 'package:haven/src/providers/debug_log_provider.dart';
import 'package:haven/src/providers/evolution_poller_provider.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/invitation_provider.dart';
import 'package:haven/src/providers/join_watcher_provider.dart';
import 'package:haven/src/providers/key_package_provider.dart';
import 'package:haven/src/providers/location_provider.dart';
import 'package:haven/src/providers/location_sharing_provider.dart';
import 'package:haven/src/providers/self_update_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/background_idle_waiter.dart';
import 'package:haven/src/services/background_location_manager.dart';
import 'package:haven/src/services/geolocator_location_service.dart';
import 'package:haven/src/services/jittered_scheduler.dart';
import 'package:haven/src/services/location_service.dart';
import 'package:haven/src/services/location_sharing_service.dart';
import 'package:haven/src/services/nostr_relay_service.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:haven/src/widgets/circles/circles_bottom_sheet.dart';
import 'package:haven/src/widgets/circles/join_watch_banner.dart';
import 'package:haven/src/widgets/common/dim_overlay.dart';
import 'package:haven/src/widgets/common/invitations_button.dart';
import 'package:haven/src/widgets/common/settings_button.dart';
import 'package:haven/src/widgets/debug/debug_log_overlay.dart';

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

  @override
  ConsumerState<MapShell> createState() => _MapShellState();
}

class _MapShellState extends ConsumerState<MapShell>
    with WidgetsBindingObserver {
  double _sheetExpansion = 0.0;
  final DraggableScrollableController _sheetController =
      DraggableScrollableController();
  JitteredScheduler? _sendScheduler;
  // Cached BigInt to avoid per-tick allocation on the FFI hot path.
  static final BigInt _nominalPublishSecsBigInt = BigInt.from(
    kLocationUpdateInterval.inSeconds,
  );
  // Cached LocationEventService so the scheduler rearm path does not
  // allocate a fresh opaque handle on every tick.
  final LocationEventService _locationEventService = LocationEventService();
  Timer? _receiveTimer;
  Timer? _invitationTimer;
  Timer? _pruneTimer;
  Timer? _selfUpdateTimer;
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
  DateTime? _lastPublishTime;
  DateTime? _lastLocationFetchTime;
  DateTime? _lastInvitationPollTime;
  DateTime? _lastSelfUpdateTime;
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

  // ---- iOS background location stream ----
  //
  // On iOS, a continuous geolocator stream with
  // `allowsBackgroundLocationUpdates: true` keeps the app process alive
  // when backgrounded. The JitteredScheduler continues firing in the
  // main isolate. On Android, the foreground service handles background
  // publishing instead.
  StreamSubscription<Position>? _backgroundLocationSub;
  // Allow user-initiated bg-sharing disable to tear down the iOS retention
  // stream without waiting for resume.
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
    unawaited(BackgroundLocationManager.markForegroundActive(active: true));
    // Pre-warm relay service, then fire startup tasks.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // Defence in depth: the AppRouter gate should never mount MapShell
      // without an identity. Trips in debug builds if that invariant breaks.
      assert(
        ref.read(identityProvider).valueOrNull != null,
        'MapShell mounted without identity; AppRouter gate failed',
      );
      final relay = ref.read(relayServiceProvider);
      if (relay is NostrRelayService) {
        await relay.initialize();
      }
      ref
        ..read(keyPackagePublisherProvider)
        ..read(locationPublisherProvider)
        ..read(invitationPollerProvider)
        ..read(selfUpdateProvider)
        ..read(evolutionPollerProvider);
      // Startup sweep: prune any expired last-known-location rows so the
      // 1-day receiver retention window is honoured on disk.
      unawaited(_runPrune());
    });
  }

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

  Future<void> _runPrune() async {
    try {
      await ref.read(circleServiceProvider).pruneExpiredLastKnown();
      // Widget may have been disposed while the FFI call was in flight;
      // nothing to do here if so, but the guard prevents any follow-up
      // state access from racing with dispose.
      if (!mounted) return;
    } on Object catch (e) {
      debugPrint('[MapShell] pruneExpiredLastKnown failed: ${e.runtimeType}');
    }
  }

  void _startTimers() {
    // Defensive cancellation: if called from the resume path while
    // timers are still live (e.g. rapid pause/resume cycles that slip
    // past the debounce), cancel existing timers to prevent accumulation.
    _sendScheduler?.cancel();
    _receiveTimer?.cancel();
    _invitationTimer?.cancel();
    _pruneTimer?.cancel();
    _selfUpdateTimer?.cancel();
    _evolutionTimer?.cancel();
    _foregroundHeartbeatTimer?.cancel();
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

    // Publish location on a jittered cadence around
    // `kLocationUpdateInterval` (nominal mean, ±40% via Rust-side CSPRNG,
    // see `haven-core/src/location/ttl.rs`). Each tick rearms at a
    // freshly sampled interval in
    // `[kLocationPublishMinInterval, kLocationPublishMaxInterval]`.
    // The overlap guard (`kLocationPublishOverlapGuard`) sits strictly
    // below the min jittered interval, so genuine short-end ticks are
    // never suppressed — the guard only defends against the
    // resume-branch `ref.read` below which fires independently of the
    // scheduler.
    _sendScheduler = JitteredScheduler(
      nominal: kLocationUpdateInterval,
      sampleIntervalSecs: (_) => _locationEventService
          .jitteredPublishIntervalSecs(nominalSecs: _nominalPublishSecsBigInt)
          .toInt(),
      onTick: () {
        if (!mounted) return;
        _guardedPublish();
      },
    )..start();

    // Motion-triggered publish: subscribe to the GPS stream that the map
    // page already consumes. No extra GPS cost — Riverpod shares the
    // underlying geolocator stream. When the device moves more than
    // `kMotionTriggerDistanceMeters` since the last publish AND the
    // overlap guard has passed, trigger an extra publish.
    _startMotionTrigger();

    // Fetch member locations every 30 seconds, with overlap guard.
    _receiveTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      final now = DateTime.now();
      if (_lastLocationFetchTime == null ||
          now.difference(_lastLocationFetchTime!) >
              const Duration(seconds: 25)) {
        _lastLocationFetchTime = now;
        ref.invalidate(memberLocationsProvider);
      }
    });

    // Prune expired last-known locations every hour. The Timer.periodic
    // cadence already caps how often this fires; a redundant minute-based
    // guard here only adds confusion.
    _pruneTimer = Timer.periodic(const Duration(hours: 1), (_) {
      unawaited(_runPrune());
    });

    // Rotate stale MLS leaf node keys every hour (MIP-03 SHOULD).
    // Also catches any post-join self-updates that failed on the initial
    // attempt (MIP-02 MUST, 24h window).
    _selfUpdateTimer = Timer.periodic(const Duration(hours: 1), (_) {
      final now = DateTime.now();
      if (_lastSelfUpdateTime == null ||
          now.difference(_lastSelfUpdateTime!) > const Duration(minutes: 55)) {
        _lastSelfUpdateTime = now;
        ref
          ..invalidate(selfUpdateProvider)
          ..read(selfUpdateProvider);
      }
    });

    // Poll for new invitations on a jittered cadence (nominal 2 min,
    // ±25%, sampled per tick). Fixed cadences are fingerprintable to
    // a passive relay observer; per CLAUDE.md "Metadata & Connection
    // Privacy", every recurring relay interaction must be jittered.
    // The overlap guard is the lower jitter bound minus a small grace
    // so a foreground/resume re-trigger cannot double-fire.
    _invitationTimer = _scheduleInvitationPoll();

    // Poll for MLS evolution events every 60 seconds.
    //
    // A longer cadence than the 30-second location timer by design: the
    // goal is to catch leave/handoff commits that arrive while the app is
    // backgrounded and foregrounded, not to compete with the location poll
    // for relay bandwidth. The overlap guard (55 seconds) ensures that a
    // resume-triggered poll (see _onResumed) cannot double-fire within
    // the same minute even on rapid pause/resume cycles.
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
      debugPrint(
        '[MapShell] motion-triggered publish '
        '(moved ${distance.toStringAsFixed(0)} m)',
      );
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
    if (state == AppLifecycleState.paused) {
      unawaited(_onPaused());
    } else if (state == AppLifecycleState.resumed) {
      unawaited(_onResumed());
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

    if (bgEnabled && Platform.isAndroid) {
      // Android: hand off publishing to the already-running foreground
      // service. The service was started from `initState` via
      // `backgroundServiceLifecycleProvider` (see CLAUDE.md /
      // background_location_provider.dart) — Android 12+ rejects
      // `FOREGROUND_SERVICE_LOCATION` start requests issued from a
      // non-visible activity, so we deliberately do **not** start it
      // here.
      _sendScheduler?.cancel();
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
      unawaited(
        BackgroundLocationManager.updateNotification(
          text: 'Sharing location with your circles and receiving theirs',
        ),
      );
    } else if (bgEnabled && Platform.isIOS) {
      // iOS: keep _sendScheduler alive — the process stays running
      // because the background location stream holds a CLLocationManager
      // session. Cancel the motion trigger (replaced by the background
      // stream's distance filter).
      _stopMotionTrigger();
      _startBackgroundLocationStream();
    } else {
      // Background sharing disabled — original behaviour.
      _sendScheduler?.cancel();
      _stopMotionTrigger();
    }

    // Always cancel foreground-only timers — they are restarted (with
    // platform-appropriate cadences) below where applicable.
    _receiveTimer?.cancel();
    _invitationTimer?.cancel();
    _pruneTimer?.cancel();
    _selfUpdateTimer?.cancel();
    _evolutionTimer?.cancel();

    // Cancel any in-flight post-circle-add burst window — its short fetch
    // cadence is meaningless once the user has backgrounded, and we must
    // not leave timers running that fire FFI calls into a paused isolate.
    // The window is short-lived by design; if the user returns later, the
    // regular pollers (resumed below) cover them.
    ref.read(joinWatcherProvider.notifier).cancel();

    // Disconnect idle relay WebSockets.
    final relay = ref.read(relayServiceProvider);
    if (relay is NostrRelayService) {
      unawaited(relay.shutdown());
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
      // The relay shutdown above closes idle WebSockets; the first
      // 90 s tick reopens via `NostrRelayService._ensureInitialized()`.
      // Both `relayServiceProvider` and the relay handle inside
      // `locationSharingServiceProvider` resolve to the same
      // singleton, so reconnection is transparent.
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
  void _startIosBackgroundReceiveTimer() {
    _receiveTimer = Timer.periodic(const Duration(seconds: 90), (_) {
      if (!mounted) return;
      final now = DateTime.now();
      if (_lastLocationFetchTime != null &&
          now.difference(_lastLocationFetchTime!) <=
              const Duration(seconds: 80)) {
        return;
      }
      _lastLocationFetchTime = now;
      ref.invalidate(memberLocationsProvider);
      // Warm the SQLCipher last-known store; result discarded because
      // no widget is listening during iOS background. Errors are
      // already logged inside `fetchMemberLocations` via debugPrint.
      unawaited(
        ref.read(memberLocationsProvider.future).catchError((Object _) {
          return const <MemberLocation>[];
        }),
      );
    });
  }

  Future<void> _onResumed() async {
    // Debounce rapid resume cycles (e.g. notification shade pull on Android).
    if (_resumeStopwatch.isRunning &&
        _resumeStopwatch.elapsed < const Duration(seconds: 30)) {
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
      await BackgroundIdleWaiter().waitUntilIdle();
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
    } else if (Platform.isIOS) {
      _stopBackgroundLocationStream();
    }

    // Restart all timers (cancelled on pause).
    _startTimers();

    // Immediate send + receive on app resume. Update _lastPublishTime
    // so the overlap guard prevents a motion trigger from double-firing
    // within seconds of resume.
    _lastPublishTime = DateTime.now();
    if (!mounted) return;
    ref
      ..invalidate(locationPublisherProvider)
      ..invalidate(memberLocationsProvider)
      ..invalidate(keyPackagePublisherProvider)
      ..invalidate(invitationPollerProvider)
      ..read(locationPublisherProvider)
      ..read(memberLocationsProvider)
      ..read(keyPackagePublisherProvider)
      ..read(invitationPollerProvider)
      ..invalidate(selfUpdateProvider)
      ..read(selfUpdateProvider)
      // Immediately poll for evolution events on resume — leave/handoff
      // commits that arrived while backgrounded are processed before the
      // next location fetch, keeping the local MDK epoch in sync.
      ..invalidate(evolutionPollerProvider)
      ..read(evolutionPollerProvider);
    // Reset the evolution- and invitation-poll overlap guards after the
    // on-resume trigger so the periodic timers do not double-fire within
    // their respective overlap windows.
    _lastEvolutionPollTime = DateTime.now();
    _lastInvitationPollTime = DateTime.now();

    // Prune on resume in case the device slept past the hourly tick.
    unawaited(_runPrune());
  }

  // ---- iOS background location stream helpers ----

  void _startBackgroundLocationStream() {
    _backgroundLocationSub?.cancel();
    final locationService = ref.read(locationServiceProvider);
    if (locationService is GeolocatorLocationService) {
      _backgroundLocationSub = locationService
          .getBackgroundLocationStream()
          .listen((_) {
            // The stream's sole purpose is process retention — the
            // JitteredScheduler handles actual publishing.
          });
      debugPrint('[MapShell] iOS background location stream started');
      // Allow user-initiated bg-sharing disable to tear down the iOS
      // retention stream without waiting for resume.
      _bgSharingPausedSub?.close();
      _bgSharingPausedSub = ref.listenManual<bool>(backgroundSharingProvider, (
        _,
        next,
      ) {
        if (!next) _stopBackgroundLocationStream();
      });
    }
  }

  void _stopBackgroundLocationStream() {
    _bgSharingPausedSub?.close();
    _bgSharingPausedSub = null;
    _backgroundLocationSub?.cancel();
    _backgroundLocationSub = null;
  }

  // Sheet snap points — must mirror the constants in
  // `circles/circles_bottom_sheet.dart`. Kept private here so distance
  // scaling in `_animateSheetDuration` has a stable range to divide by.
  static const double _kMinSheetSize = 0.12;
  static const double _kMidSheetSize = 0.5;
  static const double _kMaxSheetSize = 0.85;

  Future<void> _collapseSheet() async {
    await _animateSheetTo(_kMinSheetSize);
  }

  /// Partially collapses the sheet to the "half" snap so the map below
  /// becomes visible while keeping the member list in view. Called after
  /// the user taps a member to recenter the camera.
  Future<void> _partiallyCollapseSheet() async {
    await _animateSheetTo(_kMidSheetSize);
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
    _sendScheduler?.cancel();
    _receiveTimer?.cancel();
    _invitationTimer?.cancel();
    _pruneTimer?.cancel();
    _selfUpdateTimer?.cancel();
    _evolutionTimer?.cancel();
    _foregroundHeartbeatTimer?.cancel();
    _stopMotionTrigger();
    _bgSharingPausedSub?.close();
    _bgSharingPausedSub = null;
    _stopBackgroundLocationStream();
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
                  onTap: _collapseSheet,
                ),
              ),

              // Invitations button (top-left, respects safe area)
              Positioned(
                top: topPadding + HavenSpacing.sm,
                left: HavenSpacing.base,
                child: const InvitationsFloatingButton(),
              ),

              // Settings button (top-right, respects safe area)
              Positioned(
                top: topPadding + HavenSpacing.sm,
                right: HavenSpacing.base,
                child: const SettingsFloatingButton(),
              ),

              // Post-circle-add burst-poll status banner. Renders nothing
              // when no burst window is active.
              Positioned(
                top: topPadding + HavenSpacing.sm + 56,
                left: HavenSpacing.base,
                right: HavenSpacing.base,
                child: const JoinWatchBanner(),
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
