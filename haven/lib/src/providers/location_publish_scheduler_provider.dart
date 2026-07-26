/// Foreground per-circle location-publish scheduler (privacy: decorrelation).
///
/// ## Why this exists
///
/// The recurring location publisher used to fire ONE jittered tick that
/// published a kind-445 to EVERY accepted circle at once (`Future.wait` over
/// all circles). A relay then saw several distinct `#h` (nostr_group_id) tags
/// all receiving an event within milliseconds, every ~120 s — enough to
/// correlate those otherwise-unlinkable pseudonymous circles as a single
/// device. This notifier replaces that shared tick with one INDEPENDENT
/// [JitteredScheduler] per circle: each circle publishes on its own CSPRNG-
/// jittered cadence (re-sampled every tick), so the per-circle publish rhythms
/// drift independently and a relay can no longer link circles by co-timing.
///
/// Per-circle freshness is unchanged (each circle still samples the same
/// `[72 s, 168 s]` interval the shared scheduler used), and the GPS fix is
/// served from the geolocator stream cache (`kStreamPositionMaxAge`), so there
/// is no extra battery/GPS cost.
///
/// ## Relationship to `locationPublisherProvider`
///
/// This notifier owns only the RECURRING per-circle publishes. The one-shot
/// "publish to every circle now" burst (`locationPublisherProvider`) is left
/// intact for cold-start, app-resume, motion, and the accept/create UI — those
/// are discrete, user-driven, non-periodic events (a far weaker correlation
/// surface than the eliminated ~120 s lockstep). A burst that overlaps a
/// per-circle tick can publish the same circle twice within a short window;
/// that is benign — a kind-9 application message never advances the MLS epoch,
/// and every publish is serialized through the engine's session mutex. The
/// per-circle gate/serialization here plus that mutex uphold Rule 14
/// (single writer).
///
/// ## Lifecycle
///
/// Modeled on [MaintenanceSchedulerNotifier]: a monotonic generation fences
/// stale ticks across an `invalidate`+re-read (Riverpod reuses the instance),
/// timers are cancelled on [Ref.onDispose] and on the explicit invalidate in
/// `IdentityNotifier.deleteIdentity`. Unlike maintenance, publishing must PAUSE
/// while the app is backgrounded so the background isolate is the sole writer
/// (Rule 14): [stopScheduling]/[startScheduling] are driven by `MapShell`'s
/// lifecycle handlers.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:haven/src/constants/location.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/jittered_scheduler.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Circles eligible for outbound location publishing: accepted, not a
/// pre-cutover orphan (no live MLS group to encrypt against), and not flagged
/// Unrecoverable by the engine (Rule 8 — no send/mutate for a blocked circle).
///
/// Single source of truth shared by the foreground per-circle scheduler and
/// (duplicated by value, since the background isolate has no Riverpod
/// container) the background publish cycle, so the two planes can never diverge
/// on eligibility.
List<Circle> filterPublishEligibleCircles(
  List<Circle> circles,
  CircleService circleService,
) {
  return circles
      .where((c) => c.membershipStatus == MembershipStatus.accepted)
      .where((c) => !c.isLegacyOrphaned)
      .where((c) => !circleService.isCircleBlocked(c.mlsGroupId))
      .toList();
}

/// Injectable jitter sampler: given a nominal interval in seconds, returns a
/// CSPRNG-jittered interval in seconds. Production wraps the Rust
/// `compute_jittered_publish_interval_secs` (OsRng) via
/// `LocationEventService.jitteredPublishIntervalSecs`; tests override with a
/// deterministic sequence.
final locationPublishJitterSamplerProvider =
    Provider<int Function(int nominalSecs)>((ref) {
  final service = LocationEventService();
  return (nominalSecs) {
    try {
      return service
          .jitteredPublishIntervalSecs(nominalSecs: BigInt.from(nominalSecs))
          .toInt();
    } on Object catch (_) {
      // Fall back to the nominal interval on any FFI error — location sharing
      // must stay live rather than silently halting.
      return nominalSecs;
    }
  };
});

/// Hex-encodes a `nostrGroupId` for use as a per-circle scheduler key. Matches
/// the existing `LocationSharingService._circleKey` / `LiveSyncResubscriber`
/// convention (the public `#h` value — never the real MLS group id, Rule 4).
String _circleKey(List<int> nostrGroupId) =>
    nostrGroupId.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// Owns one [JitteredScheduler] per eligible circle for the foreground session.
class LocationPublishSchedulerNotifier extends Notifier<void> {
  final Map<String, JitteredScheduler> _schedulers = {};
  final Map<String, Circle> _circles = {};

  /// Serializes every per-circle publish onto one FIFO chain so two circles'
  /// ticks can never run `encryptLocation` concurrently (Rule 14 — belt-and-
  /// suspenders on top of the engine's own session mutex).
  Future<void> _publishChain = Future<void>.value();

  bool _disposed = false;

  /// Whether recurring publishing is active. Set false while the app is
  /// backgrounded so the background isolate is the sole writer.
  bool _active = true;

  /// Monotonic lifecycle counter (see [MaintenanceSchedulerNotifier]). A stale
  /// tick from a superseded generation must never publish or re-arm.
  int _generation = 0;

  @override
  void build() {
    _cancelAllSchedulers();
    _disposed = false;
    _active = true;
    _publishChain = Future<void>.value();
    final generation = ++_generation;

    ref
      ..onDispose(() {
        _disposed = true;
        _cancelAllSchedulers();
      })
      // React to circle-set changes: fireImmediately seeds from the current
      // roster; every later emission diffs against it (existing circles keep
      // their schedulers/phases untouched — only add/remove changes).
      ..listen<AsyncValue<List<Circle>>>(circlesProvider, (_, next) {
        next.whenData((circles) => _syncCircles(circles, generation));
      }, fireImmediately: true);
  }

  bool _isCurrent(int generation) => !_disposed && generation == _generation;

  void _cancelAllSchedulers() {
    for (final s in _schedulers.values) {
      s.cancel();
    }
    _schedulers.clear();
    _circles.clear();
  }

  void _syncCircles(List<Circle> circles, int generation) {
    if (!_isCurrent(generation)) return;
    if (!_active) {
      // Paused (backgrounded): keep no live foreground timers.
      _cancelAllSchedulers();
      return;
    }
    final circleService = ref.read(circleServiceProvider);
    final eligible = filterPublishEligibleCircles(circles, circleService);
    final byKey = {for (final c in eligible) _circleKey(c.nostrGroupId): c};

    // Remove schedulers for circles that dropped out (left / blocked /
    // orphaned / removed) — cancel their timer, drop their cache entry.
    for (final key
        in _schedulers.keys.where((k) => !byKey.containsKey(k)).toList()) {
      _schedulers.remove(key)?.cancel();
      _circles.remove(key);
    }

    // Add a fresh, independently-phased scheduler for each newly-eligible
    // circle; refresh the cached snapshot for ones we already track (leaving
    // their scheduler/phase untouched so an unrelated roster change never
    // re-locksteps everyone).
    final sample = ref.read(locationPublishJitterSamplerProvider);
    for (final entry in byKey.entries) {
      _circles[entry.key] = entry.value;
      if (_schedulers.containsKey(entry.key)) continue;
      _schedulers[entry.key] = JitteredScheduler(
        nominal: kLocationUpdateInterval,
        sampleIntervalSecs: sample,
        onTick: () => _onCircleTick(entry.key, generation),
      )..start();
    }
  }

  void _onCircleTick(String key, int generation) {
    if (!_isCurrent(generation) || !_active) return;
    final circle = _circles[key];
    if (circle == null) return; // removed between arm and fire
    // Enqueue onto the single serialization chain. catchError keeps one failed
    // publish from poisoning the chain for later circles.
    _publishChain = _publishChain
        .then((_) => _publishCircle(circle, generation))
        .catchError((Object _) {});
  }

  /// Publishes the current location to a single [circle]. Mirrors
  /// `locationPublisherProvider`'s identity + disclosure gate and GPS fetch,
  /// but for one circle only. Never throws (the chain swallows errors too).
  Future<void> _publishCircle(Circle circle, int generation) async {
    if (!_isCurrent(generation) || !_active) return;
    try {
      final identity = await ref.read(identityProvider.future);
      if (identity == null) return;

      // Play "disclosure before collection": never publish before the user has
      // accepted the in-app foreground-location disclosure (mirrors
      // locationPublisherProvider — keep the two gates in sync).
      final prefs = await SharedPreferences.getInstance();
      if (!(prefs.getBool(kLocationDisclosureAcceptedKey) ?? false)) return;
      if (!_isCurrent(generation) || !_active) return;

      final locationService = ref.read(locationServiceProvider);
      final service = ref.read(locationSharingServiceProvider);
      final position = await locationService.getCurrentLocation();
      if (!_isCurrent(generation) || !_active) return;

      await service.publishLocation(
        mlsGroupId: circle.mlsGroupId,
        senderPubkeyHex: identity.pubkeyHex,
        latitude: position.latitude,
        longitude: position.longitude,
      );
    } on Object catch (e) {
      debugPrint('[LocationPublishScheduler] per-circle publish failed: '
          '${e.runtimeType}');
    }
  }

  /// Resumes recurring per-circle publishing (app foregrounded). Re-arms fresh
  /// independent schedules from the current roster. Idempotent.
  void startScheduling() {
    if (_disposed) return;
    _active = true;
    ref.read(circlesProvider).whenData(
          (circles) => _syncCircles(circles, _generation),
        );
  }

  /// Pauses recurring per-circle publishing (app backgrounded) so the
  /// background isolate is the sole writer (Rule 14). Cancels all per-circle
  /// timers; a later [startScheduling] re-arms fresh phases. Idempotent.
  void stopScheduling() {
    _active = false;
    _cancelAllSchedulers();
  }

  // --- Test seams (mirror MaintenanceSchedulerNotifier) --------------------

  @visibleForTesting
  Set<String> get trackedCircleKeysForTest => _schedulers.keys.toSet();

  @visibleForTesting
  bool get isActiveForTest => _active;

  /// Enqueues a per-circle tick immediately (as a real timer would) and returns
  /// the serialization chain snapshot INCLUDING it — `await` the result to let
  /// the publish settle, or enqueue several before awaiting to exercise the
  /// FIFO serialization.
  @visibleForTesting
  Future<void> triggerTickForTest(String key) {
    _onCircleTick(key, _generation);
    return _publishChain;
  }
}

/// Provider owning the foreground per-circle publish schedulers.
///
/// Anchor once in `MapShell` (`ref.read(locationPublishSchedulerProvider
/// .notifier)`); cancelled on dispose and on the explicit invalidate in
/// `IdentityNotifier.deleteIdentity`.
final locationPublishSchedulerProvider =
    NotifierProvider<LocationPublishSchedulerNotifier, void>(
      LocationPublishSchedulerNotifier.new,
    );
