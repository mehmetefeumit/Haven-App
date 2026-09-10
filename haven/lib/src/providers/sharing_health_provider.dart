/// The one model of "is location sharing actually working right now".
///
/// ## Why this exists
///
/// Every way location sharing can die was completely silent to the user
/// (`docs/BACKGROUND_SHARING_FAILURE_ANALYSIS.md`): encrypt/publish failures
/// died in a `debugPrint` at all three call sites, a dead receive plane merely
/// let markers age out half an hour later, and `syncStatusProvider` could never
/// show a relay problem because no production code emitted one. The field
/// incident took two devices and hours to even notice. That silence is itself
/// the defect this model closes.
///
/// ## What it measures, and what it refuses to
///
/// DELIVERY, never flags. An engine that reports `isRunning`, a toggle the user
/// left on, a foreground-service notification reading "sending and receiving" —
/// all of them stay true through every failure mode analysed in that document.
/// So the evidence here is: when a relay last ACKed one of our publishes, when
/// a peer's location was last decrypted, and whether a publish we attempted
/// came back unacked.
///
/// It refuses to report a fault it cannot distinguish from ordinary quiet:
///
/// * A circle that has never received anything looks identical to one whose
///   receive plane is dead — the peer may simply not be sharing. Only a
///   timestamp that once existed and has since gone stale is evidence.
/// * A circle with no other members has nothing to receive.
/// * A momentary relay disconnect is normal on mobile. Every named cause must
///   stand for [kSharingFaultConfirmationWindow] before it reaches the user.
///
/// ## Thresholds
///
/// Derived from the publish cadence, never chosen for feel — see each constant.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:haven/src/constants/location.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/live_sync_provider.dart';
import 'package:haven/src/providers/location_sharing_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/circle_health_service.dart';
import 'package:haven/src/services/circle_service.dart';

/// The NIP-40 window Haven stamps on every kind-445 location message.
///
/// Mirrors `LOCATION_MESSAGE_RETENTION_SECS` (228 s) in
/// `haven-core/src/location/ttl.rs`, expressed here from the same two Dart
/// constants its own doc derives it from, so a cadence change moves both sides
/// together instead of stranding a magic number.
final Duration kLocationMessageRetention = Duration(
  seconds: kLocationPublishMaxInterval.inSeconds + 2 * kTtlNetworkBufferSeconds,
);

/// How long a NAMED cause must stand before it is shown to the user.
///
/// One worst-case publish interval: a cause that clears inside it cost the user
/// nothing (no update was due), and a relay socket that drops and reconnects
/// within one cadence is ordinary mobile behaviour, not an outage. Anything
/// shorter cries wolf; anything longer hides a gap that has already lost an
/// update.
const Duration kSharingFaultConfirmationWindow = kLocationPublishMaxInterval;

/// No relay has ACKed a publish for this long → the send plane is failing.
///
/// Two worst-case publish intervals. One missed tick is a transient — a relay
/// hiccup, a socket replaced mid-publish. Two consecutive ones is a pattern,
/// and by then the peer's relay copy of our last event has expired
/// (retention 228 s < 336 s), so peers really have lost us.
final Duration kPublishSilenceThreshold = kLocationPublishMaxInterval * 2;

/// No peer location has arrived for this long → the receive plane is silent.
///
/// Two worst-case publish intervals — the peer's own cadence, twice — plus the
/// full relay retention window, so an event a peer published just before we
/// last looked still has its entire on-relay life to reach us before we call
/// the plane dead.
final Duration kReceiveSilenceThreshold =
    kLocationPublishMaxInterval * 2 + kLocationMessageRetention;

/// How often the model re-derives itself while nothing is happening.
///
/// A silence threshold is crossed by the passage of time, not by an event: if
/// everything is dead, nothing arrives to trigger a recompute. The minimum
/// publish interval is the shortest cadence on which anything is ever expected
/// to happen, so it is the natural resolution — and it is two orders of
/// magnitude cheaper than the thresholds it is measuring against.
const Duration kSharingHealthTick = kLocationPublishMinInterval;

/// Encodes a circle's public `nostrGroupId` as the key every sharing-health
/// input uses.
///
/// Lowercase hex of the `#h` value — the same convention as
/// `LocationSharingService`'s cache keys and the live-sync resubscriber, and
/// never the real MLS group id (Security Rule 4).
String sharingCircleKey(List<int> nostrGroupId) =>
    nostrGroupId.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// Why sharing is paused, when the cause is KNOWN rather than inferred.
enum SharingPausedReason {
  /// The relay connection dropped and has not come back
  /// ([SyncConnectionPhase.disconnected]).
  relayDisconnected,

  /// The MLS engine deferred an outbound send instead of encrypting it
  /// (a queued outbound intent — Unit B).
  sendDeferred,

  /// A relay dropped this device's group subscription (Unit C).
  receiveSubscriptionLost,
}

/// What the sharing pipeline is doing.
enum SharingHealthState {
  /// Nothing measurable is wrong.
  healthy,

  /// Publishes are attempted but no relay has kept one recently.
  publishFailing,

  /// Peer locations have stopped arriving for a circle that used to receive
  /// them.
  receiveSilent,

  /// A named cause has stopped the pipeline.
  paused,
}

/// One verdict about the selected circle's sharing pipeline.
@immutable
class SharingHealth {
  const SharingHealth._(this.state, this.since, this.pausedReason);

  /// No relay has kept a publish since [since].
  const SharingHealth.publishFailing(DateTime since)
    : this._(SharingHealthState.publishFailing, since, null);

  /// No peer location has arrived since [since].
  const SharingHealth.receiveSilent(DateTime since)
    : this._(SharingHealthState.receiveSilent, since, null);

  /// A known [reason] has held the pipeline since [since].
  const SharingHealth.paused(SharingPausedReason reason, DateTime since)
    : this._(SharingHealthState.paused, since, reason);

  /// Nothing measurably wrong.
  static const healthy =
      SharingHealth._(SharingHealthState.healthy, null, null);

  /// Which state this is.
  final SharingHealthState state;

  /// When the fault started. `null` only for [SharingHealthState.healthy].
  final DateTime? since;

  /// The named cause. Non-null only for [SharingHealthState.paused].
  final SharingPausedReason? pausedReason;

  /// Whether the user should be told sharing has stopped.
  bool get isStopped => state != SharingHealthState.healthy;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SharingHealth &&
          runtimeType == other.runtimeType &&
          state == other.state &&
          since == other.since &&
          pausedReason == other.pausedReason;

  @override
  int get hashCode => Object.hash(state, since, pausedReason);

  @override
  String toString() =>
      'SharingHealth(${state.name}, since: $since, reason: $pausedReason)';
}

/// Injectable clock, so every transition is provable without waiting.
final sharingHealthClockProvider = Provider<DateTime Function()>(
  (ref) => DateTime.now,
);

/// `true` while the app is in the foreground.
///
/// The re-derivation tick exists to keep a BANNER honest, and a backgrounded
/// app has no banner on screen. At [kSharingHealthTick] it would also fire
/// about twice as often as the app's own background wake cadence, for a surface
/// nobody can see. What those extra wakeups would cost is ESTIMATED and has
/// never been measured: model E prices one background wake at `c` × 0.0208 %/h
/// (E-A2, `docs/POWER_EFFICIENCY_PLAN.md` §6.5a), and its coalescing factor
/// `c` ∈ [0.15, 1.0] (E-P2) is itself unmeasured. The wake COUNT is the only
/// part of that this code decides.
///
/// A `ValueListenable` rather than a stream so the notifier can read the
/// current value synchronously when it re-arms, and injectable because
/// [AppForegroundNotifier] needs a `WidgetsBinding` that the model's own tests
/// (plain `ProviderContainer`, no widget tree) deliberately do not build.
final sharingHealthForegroundProvider = Provider<ValueListenable<bool>>((ref) {
  final source = AppForegroundNotifier();
  ref.onDispose(source.dispose);
  return source;
});

/// Tracks whether the app is foreground-visible.
///
/// A bare [WidgetsBindingObserver] rather than `AppLifecycleListener`, matching
/// every other lifecycle consumer in `lib/src`. That class ASSERTS on
/// transitions it judges illegal — `paused` → `resumed` among them, which is
/// an ordinary Android resume — and does so BEFORE invoking `onStateChange`,
/// so an unusual-but-real platform sequence becomes a debug-build crash
/// rather than a missed update. This app already has one recorded incident of
/// a mid-sequence assert taking down startup, and the E2E lanes run debug
/// builds, so the failure mode is reachable in CI as well as on a device. The
/// same reasoning is written up on `_ResumeReassertObserver` in
/// `background_location_provider.dart`.
///
/// Only the resumed/not-resumed distinction is needed, and a bare observer
/// reports every state unconditionally, so nothing here can refuse a
/// transition.
class AppForegroundNotifier extends ValueNotifier<bool>
    with WidgetsBindingObserver {
  /// Starts observing the app lifecycle, assuming foreground until told
  /// otherwise (the first callback arrives only when something changes).
  AppForegroundNotifier() : super(true) {
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    value = state == AppLifecycleState.resumed;
  }

  @override
  void dispose() {
    // Before `super.dispose()`: a `ChangeNotifier` that is disposed while still
    // registered would be written to by the next lifecycle callback, which
    // throws on a disposed notifier.
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

/// The selected circle's [SharingHealth].
final sharingHealthProvider =
    NotifierProvider<SharingHealthNotifier, SharingHealth>(
      SharingHealthNotifier.new,
    );

/// Derives [SharingHealth] from delivery evidence.
class SharingHealthNotifier extends Notifier<SharingHealth> {
  /// When the current run of unacked publishes began, per circle key. Cleared
  /// by an ACK — from this isolate directly, or from the Android foreground
  /// service via the persisted ack timestamp (see [_evaluate]).
  final Map<String, DateTime> _publishFailingSince = {};

  /// When the engine first deferred a send, per circle key (Unit B).
  final Map<String, DateTime> _deferredSendSince = {};

  /// When a relay last dropped this device's group subscription (Unit C).
  /// Process-wide rather than per-circle: the engine holds one socket set, and
  /// Unit C's signal is about the socket, not a group.
  DateTime? _subscriptionLostSince;

  /// When the engine last entered [SyncConnectionPhase.disconnected].
  DateTime? _disconnectedSince;

  Timer? _tick;
  Duration _tickInterval = kSharingHealthTick;

  /// Monotonic lifecycle counter. A [refresh] whose async read completes after
  /// a newer one started must not publish its older verdict — the same
  /// generation-fence shape `LocationPublishSchedulerNotifier` uses.
  int _generation = 0;

  /// Set once the notifier is disposed, so a late async completion cannot
  /// resurrect it.
  bool _disposed = false;

  DateTime Function() get _now => ref.read(sharingHealthClockProvider);

  @override
  SharingHealth build() {
    // A disconnect has no timestamp of its own — `SyncStatus` carries a phase,
    // not an instant — so the transition edge is where the clock is read.
    //
    // `SyncConnectionPhase.paused` neither sets nor clears it. Clearing was
    // wrong in the one direction that matters: it turned a confirmed
    // `relayDisconnected` into `healthy` the moment a burst paused, and the
    // banner speaks every stopped → healthy edge as "sharing resumed" — so a
    // screen-reader user was told the outage was over when all that happened
    // was the app closing its sockets. Retaining the stamp keeps the ONSET
    // honest too: an outage that spans a pause is still dated from when it
    // started, not re-dated to the un-pause. The pause is instead prevented
    // from confirming a fault by [refresh], which derives nothing at all while
    // the engine is paused.
    ref.listen<SyncStatus>(syncStatusProvider, (previous, next) {
      switch (next.phase) {
        case SyncConnectionPhase.disconnected:
          _disconnectedSince ??= _now();
        case SyncConnectionPhase.paused:
          break;
        case SyncConnectionPhase.idle:
        case SyncConnectionPhase.connecting:
        case SyncConnectionPhase.connected:
          _disconnectedSince = null;
      }
      unawaited(refresh());
    });

    // A silence threshold is crossed by time passing, not by an event. Without
    // this the model could only update when something arrived — which is
    // exactly what stops when the pipeline dies. Gated on the foreground: see
    // [sharingHealthForegroundProvider].
    final foreground = ref.read(sharingHealthForegroundProvider);
    void syncTick() {
      if (foreground.value) {
        // Re-derive immediately as well as re-arming, so the first thing a
        // returning user sees is a fresh verdict rather than the one that was
        // true when they left.
        _tick ??= Timer.periodic(_tickInterval, (_) => unawaited(refresh()));
        unawaited(refresh());
      } else {
        _tick?.cancel();
        _tick = null;
      }
    }

    foreground.addListener(syncTick);
    ref.onDispose(() {
      _disposed = true;
      foreground.removeListener(syncTick);
      _tick?.cancel();
      _tick = null;
    });
    syncTick();

    return SharingHealth.healthy;
  }

  /// Records the outcome of one publish attempt.
  ///
  /// [acked] must mean a relay ACK, never a completed send: the whole point of
  /// this record is that an unacked publish delivered nothing.
  void recordPublishOutcome(String circleKey, {required bool acked}) {
    if (acked) {
      _publishFailingSince.remove(circleKey);
      // An acknowledged publish is proof the engine encrypted and a relay kept
      // it, which is exactly the condition a deferred send says did not hold.
      // Unit B's repair therefore clears itself here rather than needing its
      // own "all better now" call that a caller could forget to make.
      _deferredSendSince.remove(circleKey);
    } else {
      _publishFailingSince[circleKey] ??= _now();
    }
    unawaited(refresh());
  }

  /// Records that the MLS engine deferred an outbound send for a circle
  /// instead of encrypting it (Unit B's `EncryptOutcome::Deferred`).
  ///
  /// Cleared by the next acknowledged publish for the same circle, so a repair
  /// that works clears the banner without anyone having to remember to.
  void recordDeferredSend(String circleKey) {
    _deferredSendSince[circleKey] ??= _now();
    unawaited(refresh());
  }

  /// Records that a relay dropped this device's group subscription (Unit C's
  /// `CLOSED` handling).
  ///
  /// Cleared ONLY by [recordRelaySubscriptionRestored], which Unit C calls when
  /// it has re-issued the REQ. Deliberately not cleared by a peer location
  /// arriving: locations reach this device over any relay in the pool, so one
  /// arriving proves nothing about the subscription that was dropped.
  void recordRelaySubscriptionLost() {
    _subscriptionLostSince ??= _now();
    unawaited(refresh());
  }

  /// Records that the dropped subscription was re-established (Unit C).
  void recordRelaySubscriptionRestored() {
    _subscriptionLostSince = null;
    unawaited(refresh());
  }

  /// Re-derives the verdict now.
  ///
  /// Safe to call concurrently: the verdict comes from an async storage read,
  /// so two overlapping calls can complete out of order, and the older one
  /// would otherwise overwrite the newer with a stale answer.
  ///
  /// A PAUSED engine derives nothing and the last verdict stands. Between
  /// background bursts there is no REQ and no socket: the app is not looking,
  /// so it learns nothing in either direction, and both directions do harm.
  /// Deriving `healthy` announces a recovery that did not happen — the app
  /// stopped looking, the relay did not come back — and deriving a fault dates
  /// an outage from a silence the app chose. The generation bump lands BEFORE
  /// the early return so a derivation already in flight when the pause began
  /// cannot land its answer either. The status listener above refreshes on
  /// every phase change, so the verdict is re-derived the moment the next
  /// burst opens.
  Future<void> refresh() async {
    final generation = ++_generation;
    if (ref.read(syncStatusProvider).phase == SyncConnectionPhase.paused) {
      return;
    }
    final next = await _evaluate();
    // Riverpod disposes the notifier on logout / identity change; a late async
    // completion must not resurrect it, nor overtake a newer derivation.
    if (_disposed || generation != _generation) return;
    state = next;
  }

  Future<SharingHealth> _evaluate() async {
    final circle = ref.read(selectedCircleProvider);
    if (circle == null ||
        circle.membershipStatus != MembershipStatus.accepted ||
        circle.isLegacyOrphaned) {
      return SharingHealth.healthy;
    }

    final now = _now();
    final key = sharingCircleKey(circle.nostrGroupId);
    final health = await ref
        .read(circleHealthServiceProvider)
        .read(nostrGroupId: circle.nostrGroupId);
    final ackedAt = health.lastPublishAckedAt;

    // An ACK recorded by the OTHER isolate (the Android foreground service,
    // which has no Riverpod container and can only leave a persisted stamp)
    // clears this isolate's in-memory failure run. Without this, a foreground
    // failure before a pause would outlive a whole backgrounded session that
    // published perfectly.
    final failingSince = _publishFailingSince[key];
    if (failingSince != null &&
        ackedAt != null &&
        ackedAt.isAfter(failingSince)) {
      _publishFailingSince.remove(key);
    }

    // A named cause outranks an inferred one: it says something true and
    // specific, and it is what Units A/B/C repair.
    final paused = _pausedVerdict(key, now, health);
    if (paused != null) return paused;

    final publishing = _publishVerdict(key, now, ackedAt);
    if (publishing != null) return publishing;

    return _receiveVerdict(circle, now, health) ?? SharingHealth.healthy;
  }

  SharingHealth? _pausedVerdict(
    String key,
    DateTime now,
    CircleHealthTimestamps health,
  ) {
    final candidates = <SharingPausedReason, DateTime?>{
      SharingPausedReason.sendDeferred: _deferredSendSince[key],
      SharingPausedReason.receiveSubscriptionLost: _subscriptionLostSince,
      SharingPausedReason.relayDisconnected: _disconnectedSince,
    };
    for (final entry in candidates.entries) {
      final onset = entry.value;
      if (onset != null &&
          now.difference(onset) > kSharingFaultConfirmationWindow) {
        return SharingHealth.paused(entry.key, _lastKnownGood(onset, health));
      }
    }
    return null;
  }

  /// The last instant at which SOMETHING is known to have been delivered.
  ///
  /// The fault ONSET is not that instant, and reporting it as one understates
  /// the outage. A dropped subscription noticed three minutes ago on a circle
  /// whose last peer location arrived forty minutes ago would have been dated
  /// "three minutes" — telling the user their map is nearly fresh when it is
  /// two thirds of an hour old, on a surface whose entire job is to stop the
  /// app from looking healthier than it is.
  ///
  /// So the answer is the EARLIER of the onset and the newest delivery either
  /// plane can still prove. That is never later than the true last delivery, so
  /// the banner can under-state freshness but never over-state it — the only
  /// direction an error may safely go here.
  DateTime _lastKnownGood(DateTime onset, CircleHealthTimestamps health) {
    final acked = health.lastPublishAckedAt;
    final peer = health.lastPeerEventAt;
    var newestDelivery = acked;
    if (peer != null &&
        (newestDelivery == null || peer.isAfter(newestDelivery))) {
      newestDelivery = peer;
    }
    if (newestDelivery == null) return onset;
    return newestDelivery.isBefore(onset) ? newestDelivery : onset;
  }

  SharingHealth? _publishVerdict(String key, DateTime now, DateTime? ackedAt) {
    // Route 1 — this isolate watched a publish come back unacked and nothing
    // has acked since. Fast, but only ever available in the foreground.
    final failingSince = _publishFailingSince[key];
    if (failingSince != null &&
        now.difference(failingSince) > kSharingFaultConfirmationWindow) {
      return SharingHealth.publishFailing(ackedAt ?? failingSince);
    }

    // Route 2 — whoever was publishing (either isolate), nothing has been kept
    // by a relay for two cadences. Requires a baseline: a circle that has never
    // published successfully has nothing to have stopped.
    if (ackedAt != null && now.difference(ackedAt) > kPublishSilenceThreshold) {
      return SharingHealth.publishFailing(ackedAt);
    }
    return null;
  }

  SharingHealth? _receiveVerdict(
    Circle circle,
    DateTime now,
    CircleHealthTimestamps health,
  ) {
    // Nothing to receive: a solo circle is quiet because it is empty. An
    // unresolved identity (the provider is still loading, or the secure-storage
    // read missed) means the roster cannot be split into self and others, so
    // the verdict is withheld rather than guessed — the tick re-derives it
    // moments later, and a banner shown on a guess is worse than one shown
    // late.
    final selfPubkey = ref.read(identityProvider).valueOrNull?.pubkeyHex;
    if (selfPubkey == null) return null;
    final others = circle.members.where((m) => m.pubkey != selfPubkey).length;
    if (others == 0) return null;

    // The persisted receipt stamp is the ONLY evidence consulted, and it is a
    // LOCAL clock reading written by whichever isolate decrypted the location.
    //
    // A cached `MemberLocation.timestamp` must never be mixed in here even
    // though it is newer-looking and readily available: it is the SENDER's
    // clock, and `LocationSharingService._persistDecryptedLocation` records
    // the receipt time precisely because a peer running fast would otherwise
    // keep the circle looking live long after it went silent. Taking a max
    // over it would hand that peer the power to suppress this banner.
    final lastPeerAt = health.lastPeerEventAt;
    // Never received anything: indistinguishable from a peer who has never
    // shared, so there is no fault to report.
    if (lastPeerAt == null) return null;
    if (now.difference(lastPeerAt) > kReceiveSilenceThreshold) {
      return SharingHealth.receiveSilent(lastPeerAt);
    }
    return null;
  }

  /// Shortens the re-derivation tick so the time-driven transitions are
  /// provable in milliseconds. Production never writes it.
  @visibleForTesting
  // Nothing reads this back; the production value is the const above.
  // ignore: avoid_setters_without_getters
  set tickIntervalForTest(Duration value) {
    _tickInterval = value;
    if (_tick == null) return; // gated off (backgrounded) — leave it off
    _tick!.cancel();
    _tick = Timer.periodic(_tickInterval, (_) => unawaited(refresh()));
  }

  /// Whether the re-derivation tick is currently armed. Lets a test prove the
  /// foreground gate without waiting for a tick that must never fire.
  @visibleForTesting
  bool get isTickingForTest => _tick != null;
}

/// The repair a user can run from the sharing-health banner.
///
/// Returns what the epoch-repair leg answered, so the banner can tell the user
/// something honest instead of leaving them to guess from an unchanged screen.
typedef SharingRepair = Future<EpochRepairResult?> Function();

/// The remedy behind the banner's "Repair" button.
///
/// One injectable callback rather than logic inside the widget, so Units A
/// (force-release the orphaned MLS guard), B (drop a queued outbound intent and
/// re-converge) and C (force a fresh REQ) extend the remedy in one place and
/// every test that pins the button keeps working.
///
/// What it does TODAY is the set of repair paths that already exist: re-read
/// the circle roster (a failed open leaves `circlesProvider` cached at `[]`),
/// re-run the publish burst, and re-anchor the live-sync subscriptions — the
/// same call `MapShell` makes on resume, which is the one repair the analysis
/// found actually recovers a relay-dropped REQ.
final sharingRepairProvider = Provider<SharingRepair>((ref) {
  return () async {
    ref
      ..invalidate(circlesProvider)
      ..invalidate(locationPublisherProvider);
    try {
      await ref.read(subscriptionServiceProvider).resumeAfterBackground();
    } on Object catch (e) {
      // Rule 8: the type only. A repair that fails must still let the other
      // legs run and must never put engine internals on screen.
      debugPrint('[SharingHealth] repair resume failed: ${e.runtimeType}');
    }
    try {
      await ref.read(locationPublisherProvider.future);
    } on Object catch (e) {
      debugPrint('[SharingHealth] repair publish failed: ${e.runtimeType}');
    }

    // The epoch-rotation leg runs LAST, and only for the selected circle.
    //
    // It is the only leg that authors an MLS commit, so it goes after the
    // cheap, local remedies have had their chance: if a dropped REQ was the
    // whole problem, nothing needs re-keying. It is also the only leg with a
    // user-visible answer, which is why this callback now returns one.
    final result = await repairSelectedCircleEpoch(ref);

    // Contained like every other leg. `_repair` awaits this callback inside a
    // `try/finally` with no `catch`, so a throwing refresh would escape as an
    // unhandled async error, losing the outcome the user is waiting for AND
    // putting the raw error on the zone handler (Rule 8). The verdict the
    // banner reads next is stale rather than absent — the model re-derives on
    // its own tick — which is strictly better than no answer at all.
    try {
      await ref.read(sharingHealthProvider.notifier).refresh();
    } on Object catch (e) {
      debugPrint('[SharingHealth] repair refresh failed: ${e.runtimeType}');
    }
    return result;
  };
});

/// Runs the epoch-rotation repair for the selected circle, or returns `null`
/// when there is nothing to run it against.
///
/// A named top-level function rather than an inline block so its three gates —
/// a selected circle, a known identity, and a failure that must not escape —
/// are testable without standing up the whole repair chain.
///
/// Foreground only (Rule 14): this provider is read from the map's banner and
/// nowhere else, and `scripts/ci/check_epoch_repair_isolation.sh` keeps it that
/// way.
@visibleForTesting
Future<EpochRepairResult?> repairSelectedCircleEpoch(Ref ref) async {
  final circle = ref.read(selectedCircleProvider);
  final selfPubkey = ref.read(identityProvider).valueOrNull?.pubkeyHex;
  if (circle == null || selfPubkey == null) return null;
  try {
    return await ref
        .read(circleServiceProvider)
        .repairCircleEpoch(circle, selfPubkeyHex: selfPubkey);
  } on Object catch (e) {
    // Rule 8 again: a failed epoch repair must not put engine text on screen,
    // and must not mask the other legs' work.
    debugPrint('[SharingHealth] epoch repair failed: ${e.runtimeType}');
    return null;
  }
}
