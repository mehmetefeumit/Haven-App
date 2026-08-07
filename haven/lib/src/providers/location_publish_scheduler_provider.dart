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
/// "publish to every circle now" burst (`locationPublisherProvider`) handles
/// cold-start, app-resume, motion, and the accept/create UI. That burst is
/// also staggered now, for a reason this file's original note underrated: the
/// engine binds the outer kind-445 `created_at` to the inner app event's
/// WHOLE-SECOND timestamp, so co-timed publishes do not merely share a
/// connection-level moment, they share a byte-identical field inside the
/// signed event — readable from an archive by someone who never saw the
/// socket. Co-timing is therefore transferable evidence, not a weak hint.
/// A burst that overlaps a per-circle tick can publish the same circle twice
/// within a short window; that is benign — a kind-9 application message never
/// advances the MLS epoch, and every publish is serialized through the
/// engine's session mutex. The per-circle gate/serialization here plus that
/// mutex uphold Rule 14 (single writer).
///
/// Two circles' independent jittered ticks can still land in the same second
/// by chance (both intervals are sampled from the same 97-value window), and
/// the FIFO chain would then run them back to back. [PublishStagger] closes
/// that too: the chain holds each publish until more than a second has passed
/// since the previous one.
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
import 'package:haven/src/services/publish_stagger.dart';
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

  /// Ceiling on a single chained publish before the chain moves on without
  /// it.
  ///
  /// A FIFO chain has one structural failure mode: a link that never
  /// completes is not an error the `catchError` below can absorb, it is a
  /// permanent stall. Every later tick — for EVERY circle — queues behind
  /// it, and only [build] resets the chain, so a single hung await ends
  /// location sharing for the rest of the process, silently. One route in
  /// was a backgrounded iOS permission prompt that iOS defers and
  /// geolocator never resolves; that specific route is closed at the
  /// source in `GeolocatorLocationService`, but the fragility is the
  /// chain's, not that call site's, so it is bounded here too.
  ///
  /// 3 minutes is chosen to be unreachable by a slow-but-honest publish
  /// and still bounded: the composed internal ceilings are the 30 s
  /// one-shot GPS `timeLimit` plus the Rust relay publisher's ~49 s worst
  /// case (3 attempts × (`CONNECTION_TIMEOUT` + `DEFAULT_TIMEOUT`) + 2
  /// backoffs, `haven-core/src/relay/manager.rs`), i.e. ≈79 s — so this
  /// leaves better than 2× headroom, while still recovering within about
  /// one publish cadence.
  ///
  /// Letting the abandoned link run on does not weaken Rule 14. The
  /// single-writer guarantee is the engine's `tokio::sync::Mutex<
  /// AccountDeviceSession>`, which every `encrypt_location` funnels
  /// through (documented at `rust_builder/src/api.rs`'s `encryptLocation`);
  /// this chain is the belt on top of those suspenders, and a stall long
  /// enough to trip this cap is overwhelmingly in the GPS/permission
  /// stage, before the engine is touched at all.
  static const Duration _defaultPublishLinkTimeout = Duration(minutes: 3);

  Duration _publishLinkTimeout = _defaultPublishLinkTimeout;

  /// When the chain last STARTED a publish, so [_pacedPublish] can hold the
  /// next one until more than a second has passed. `null` until the first
  /// publish of this generation.
  DateTime? _lastChainPublishAt;

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
    _lastChainPublishAt = null;
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
    // publish from poisoning the chain for later circles, and the timeout
    // keeps one HUNG publish from poisoning it forever (see
    // [_defaultPublishLinkTimeout] — an unfinished future raises no error, so
    // catchError alone cannot see it).
    //
    // The timeout is constructed INSIDE the `then`, so its clock starts when
    // the link begins rather than when it is enqueued; starting it at enqueue
    // time would make queued links expire for the sin of waiting their turn.
    _publishChain = _publishChain
        .then((_) => _pacedPublish(circle, generation))
        .catchError((Object _) {});
  }

  /// Holds the link until more than a second has passed since the chain's
  /// previous publish, then runs it under the per-link timeout.
  ///
  /// The wait sits OUTSIDE [_publishLinkTimeout] deliberately: the timeout
  /// bounds a hung publish, and folding a deliberate wait into it would make
  /// the decorrelation gap look like a hang and abandon the link.
  Future<void> _pacedPublish(Circle circle, int generation) async {
    final last = _lastChainPublishAt;
    if (last != null) {
      final elapsed = DateTime.now().difference(last);
      final gap = ref.read(locationPublishStaggerProvider).sampleGap();
      if (elapsed < gap) {
        await Future<void>.delayed(gap - elapsed);
        if (!_isCurrent(generation) || !_active) return;
      }
    }
    _lastChainPublishAt = DateTime.now();
    await _publishCircle(circle, generation).timeout(
      _publishLinkTimeout,
      onTimeout: () => debugPrint(
        '[LocationPublishScheduler] per-circle publish exceeded '
        '${_publishLinkTimeout.inSeconds}s — abandoning the link so the '
        'chain keeps moving',
      ),
    );
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

  /// Shortens [_defaultPublishLinkTimeout] so the wedge-recovery property is
  /// provable in milliseconds instead of minutes. Production never writes it.
  @visibleForTesting
  // A getter would be dead weight: nothing reads this back, and the
  // production value is the const above.
  // ignore: avoid_setters_without_getters
  set publishLinkTimeoutForTest(Duration value) => _publishLinkTimeout = value;

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
