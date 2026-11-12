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
/// * A momentary relay disconnect is normal on mobile. Every transient cause
///   must stand for [kSharingFaultConfirmationWindow] before it reaches the
///   user, unless the user's own action just made it.
/// * A silence nobody was looking through is not a silence. While the app is
///   away nothing may be sending or receiving at all, so the stored delivery
///   instants only age; read at the moment the app comes back they say how
///   long it was away, not that anything broke — and the resume's own publish
///   and reconnect are already under way. So that window is counted in time
///   the app was in front ([SharingHealthNotifier] `_watchedSince`), across
///   visits — for a silence, from where it stops being ordinary: a fault that
///   began unwatched is shown once it has outlasted one window of watching,
///   and at once on every later visit until a delivery ends it.
///
/// What the core knows holds the circle — a disband, a halt, a pending change,
/// a removal not made — is READ from it ([CircleService.circleRecovery]) and
/// outranks everything inferred here; it is never re-derived on this side.
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
import 'package:haven/src/providers/clock_skew_provider.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/live_sync_provider.dart';
import 'package:haven/src/providers/location_access_provider.dart';
import 'package:haven/src/providers/location_sharing_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/rust/api.dart' show ChangeNoteFfi;
import 'package:haven/src/services/change_notices.dart';
import 'package:haven/src/services/circle_health_service.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/subscription_service.dart'
    show LiveSyncStopOutcome;
import 'package:haven/src/utils/log_alias.dart';

/// The NIP-40 window Haven stamps on every kind-445 location message.
///
/// Mirrors `LOCATION_MESSAGE_RETENTION_SECS` (228 s) in
/// `haven-core/src/location/ttl.rs`, expressed here from the same two Dart
/// constants its own doc derives it from, so a cadence change moves both sides
/// together instead of stranding a magic number.
final Duration kLocationMessageRetention = Duration(
  seconds: kLocationPublishMaxInterval.inSeconds + 2 * kTtlNetworkBufferSeconds,
);

/// How long a transient cause must stand before it is shown to the user.
///
/// One worst-case publish interval: a cause that clears inside it cost the user
/// nothing (no update was due), and a relay socket that drops and reconnects
/// within one cadence is ordinary mobile behaviour, not an outage. Anything
/// shorter cries wolf; anything longer hides a gap that has already lost an
/// update.
///
/// Counted in time the app was in front. Inside one such window a working
/// pipeline has sent (this device's own cadence) and received (the peer's), so
/// a cause still standing at its end is one the app watched fail, not one it
/// found on its way back.
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

/// The key every sharing-health input uses for [circle]: lowercase hex of its
/// `mlsGroupId`, the one id a routing rotation leaves alone (its
/// `nostrGroupId` moves, and a key on it would orphan the circle's health
/// under the prior id). An in-memory key only: never logged, never sent.
String sharingCircleKey(Circle circle) =>
    circle.mlsGroupId.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// Why sharing is paused, when the cause is KNOWN rather than inferred.
///
/// The causes after the first three are the core's, read in its worst-first
/// order ([CircleService.circleRecovery]) and never re-derived here.
enum SharingPausedReason {
  /// The relay connection dropped and has not come back
  /// ([SyncConnectionPhase.disconnected]).
  relayDisconnected,

  /// A relay dropped this device's group subscription (Unit C).
  receiveSubscriptionLost,

  /// A previous live-sync session still holds the one-session guard, so no
  /// new one can start (Rule 14).
  sessionStillHeld,

  /// The circle's encrypted state failed to load on this device
  /// ([Circle.isQuarantined]), so it neither sends nor receives until a retry
  /// loads it.
  circleQuarantined,

  /// An admin disbanded the circle ([Circle.isDisbanded]): nothing is sent or
  /// received for it again.
  circleDisbanded,

  /// MDK halted the circle on this device ([Circle.isUnrecoverable]).
  circleUnrecoverable,

  /// The circle's routing collision is recorded: it stands until the circle
  /// itself is left.
  routingCollision,

  /// The core reads the circle as collided but no collision is recorded: the
  /// store did not answer, and the next read checks again.
  routingUnchecked,

  /// This device asked to leave the circle.
  leaving,

  /// This device cannot read its peers' updates.
  stalled,

  /// A removal the user asked for was dropped unmade; its notice says so.
  removalUnmade,

  /// As [removalUnmade], with no notice saying so.
  removalUnmadeUntold,

  /// The removal of a member who left is due and not made yet.
  departureDue,

  /// A relay change waits for the app's foreground.
  awaitsForeground,

  /// A change of the circle awaits a relay's acknowledgement.
  awaitingRelays,

  /// A change a relay acknowledged awaits its confirm.
  acknowledged,

  /// A commit is staged with no record.
  stagedWithoutRecord,

  /// Stored input still holds the circle's sends.
  storedInput,
}

/// The [SharingPausedReason] of a core recovery cause. The two the circle's
/// notice refines ([CircleRecoveryCause.routingCollision],
/// [CircleRecoveryCause.removalUnmade]) take their notice-backed reading.
SharingPausedReason pausedReasonOf(CircleRecoveryCause cause) =>
    switch (cause) {
      CircleRecoveryCause.disbanded => SharingPausedReason.circleDisbanded,
      CircleRecoveryCause.unrecoverable =>
        SharingPausedReason.circleUnrecoverable,
      CircleRecoveryCause.quarantined => SharingPausedReason.circleQuarantined,
      CircleRecoveryCause.routingCollision =>
        SharingPausedReason.routingCollision,
      CircleRecoveryCause.leaving => SharingPausedReason.leaving,
      CircleRecoveryCause.stalled => SharingPausedReason.stalled,
      CircleRecoveryCause.removalUnmade => SharingPausedReason.removalUnmade,
      CircleRecoveryCause.departureDue => SharingPausedReason.departureDue,
      CircleRecoveryCause.awaitsForeground =>
        SharingPausedReason.awaitsForeground,
      CircleRecoveryCause.awaitingRelays => SharingPausedReason.awaitingRelays,
      CircleRecoveryCause.acknowledged => SharingPausedReason.acknowledged,
      CircleRecoveryCause.stagedWithoutRecord =>
        SharingPausedReason.stagedWithoutRecord,
      CircleRecoveryCause.storedInput => SharingPausedReason.storedInput,
    };

/// Whether [reason] stands until something changes the circle itself, so it
/// is shown the moment it is read. Every other core cause clears in the
/// course of ordinary work and waits out [kSharingFaultConfirmationWindow].
bool isDurablePausedReason(SharingPausedReason reason) => switch (reason) {
  SharingPausedReason.circleDisbanded ||
  SharingPausedReason.circleUnrecoverable ||
  SharingPausedReason.circleQuarantined ||
  SharingPausedReason.routingCollision ||
  SharingPausedReason.routingUnchecked ||
  SharingPausedReason.leaving ||
  SharingPausedReason.stalled ||
  SharingPausedReason.removalUnmade ||
  SharingPausedReason.removalUnmadeUntold => true,
  SharingPausedReason.departureDue ||
  SharingPausedReason.awaitsForeground ||
  SharingPausedReason.awaitingRelays ||
  SharingPausedReason.acknowledged ||
  SharingPausedReason.stagedWithoutRecord ||
  SharingPausedReason.storedInput ||
  SharingPausedReason.relayDisconnected ||
  SharingPausedReason.receiveSubscriptionLost ||
  SharingPausedReason.sessionStillHeld => false,
};

/// Whether [health] is inferred by this side from delivery evidence and the
/// connection, rather than read from the core: only such a verdict, or
/// healthy, may stand behind a device-level banner.
bool isInferredSharingHealth(SharingHealth health) =>
    switch (health.state) {
      SharingHealthState.healthy ||
      SharingHealthState.publishFailing ||
      SharingHealthState.receiveSilent => true,
      SharingHealthState.paused =>
        health.pausedReason == SharingPausedReason.relayDisconnected ||
            health.pausedReason == SharingPausedReason.receiveSubscriptionLost,
    };

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
  const SharingHealth._(
    this.state,
    this.since,
    this.pausedReason, {
    this.ageProvable = true,
    this.circleKey,
  });

  /// No relay has kept a publish since [since].
  const SharingHealth.publishFailing(DateTime since, {bool ageProvable = true})
    : this._(
        SharingHealthState.publishFailing,
        since,
        null,
        ageProvable: ageProvable,
      );

  /// No peer location has arrived since [since].
  const SharingHealth.receiveSilent(DateTime since)
    : this._(SharingHealthState.receiveSilent, since, null);

  /// A known [reason] has held the pipeline since [since].
  const SharingHealth.paused(
    SharingPausedReason reason,
    DateTime since, {
    bool ageProvable = true,
  }) : this._(
         SharingHealthState.paused,
         since,
         reason,
         ageProvable: ageProvable,
       );

  /// Nothing measurably wrong.
  static const healthy =
      SharingHealth._(SharingHealthState.healthy, null, null);

  /// Which state this is.
  final SharingHealthState state;

  /// When the fault started. `null` only for [SharingHealthState.healthy].
  final DateTime? since;

  /// The named cause. Non-null only for [SharingHealthState.paused].
  final SharingPausedReason? pausedReason;

  /// Whether a delivery proves how old the silence is. When none does,
  /// [since] is only when this process noticed the fault — it restarts with
  /// the process — so no age may be shown from it.
  final bool ageProvable;

  /// The [sharingCircleKey] of the circle this verdict was derived for;
  /// `null` when it is about no circle. Never logged.
  final String? circleKey;

  /// This verdict, about the circle keyed [key].
  SharingHealth about(String? key) => SharingHealth._(
    state,
    since,
    pausedReason,
    ageProvable: ageProvable,
    circleKey: key,
  );

  /// Whether the user should be told sharing has stopped.
  bool get isStopped => state != SharingHealthState.healthy;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SharingHealth &&
          runtimeType == other.runtimeType &&
          state == other.state &&
          since == other.since &&
          pausedReason == other.pausedReason &&
          ageProvable == other.ageProvable &&
          circleKey == other.circleKey;

  @override
  int get hashCode =>
      Object.hash(state, since, pausedReason, ageProvable, circleKey);

  /// [since] as an offset from now, never a wall-clock instant (Rule 15) —
  /// `-` when there is no fault to date.
  String get _sinceOffset {
    final at = since;
    return at == null ? '-' : relativeSecs(LogOrigin.now(), at);
  }

  @override
  // A marker blankets the whole rendering, so `since:` has no guard here —
  // its backstop is the "states how long ago the fault began" test.
  // log-scan-ok: pausedReason is a closed enum variant, never remote prose
  String toString() =>
      'SharingHealth(${state.name}, since: $_sinceOffset, '
      'reason: $pausedReason, ageProvable: $ageProvable)';
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
  /// Starts observing the app lifecycle from what the binding reads now.
  ///
  /// The binding dispatches only changes, so a process started in the
  /// background (an iOS location relaunch, an Android activity stopped during
  /// start-up) is never told it is not in front: assuming it was would count
  /// that whole time as watched. A lifecycle not yet reported reads as in
  /// front; the first dispatch corrects it.
  AppForegroundNotifier() : super(_inFront()) {
    WidgetsBinding.instance.addObserver(this);
  }

  static bool _inFront() {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    return lifecycle == null || lifecycle == AppLifecycleState.resumed;
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

/// What the circle details sheet shows of [health]: the verdict itself, or
/// [suppressed] while a device-level banner names an upstream cause.
@immutable
class SharingHealthShown {
  /// Creates the shown verdict.
  const SharingHealthShown(this.health, {this.suppressed = false});

  /// The model's verdict.
  final SharingHealth health;

  /// Whether a device-level banner stands above an inferred verdict.
  final bool suppressed;

  /// Whether a fault is shown.
  bool get isStopped => !suppressed && health.isStopped;

  /// Whether this is the end of a shown fault: an unsuppressed healthy
  /// verdict. A verdict going suppressed is never a recovery.
  bool get isRecovered => !suppressed && !health.isStopped;

  @override
  bool operator ==(Object other) =>
      other is SharingHealthShown &&
      other.health == health &&
      other.suppressed == suppressed;

  @override
  int get hashCode => Object.hash(health, suppressed);
}

/// The selected circle's verdict as Circle details shows it.
///
/// A verdict derived for another circle is suppressed until the selected
/// circle's own lands. An inferred verdict — and healthy — is suppressed while
/// location access is blocked or the clock is skewed: those banners name the
/// upstream cause, and Repair would be the wrong remedy under either
/// (`map_status_banners.dart`).
/// A cause the core reads is never suppressed: it is true whatever the device.
final sharingHealthShownProvider = Provider<SharingHealthShown>((ref) {
  final health = ref.watch(sharingHealthProvider);
  final selected = ref.watch(selectedCircleProvider);
  // A verdict about another circle (the selection moved before the new read
  // landed) is not known for this one: nothing is shown and no edge fires.
  final selectedKey = selected == null ? null : sharingCircleKey(selected);
  final aboutAnother =
      health.circleKey != null && health.circleKey != selectedKey;
  final deviceBanner =
      ref.watch(locationAccessProvider).isBlocked ||
      ref.watch(clockSkewProvider).isSkewed;
  return SharingHealthShown(
    health,
    suppressed:
        aboutAnother || (deviceBanner && isInferredSharingHealth(health)),
  );
});

/// Derives [SharingHealth] from delivery evidence.
class SharingHealthNotifier extends Notifier<SharingHealth> {
  /// When the current run of unacked publishes began, per circle key. Cleared
  /// by an ACK — from this isolate directly, or from the Android foreground
  /// service via the persisted ack timestamp (see [_evaluate]).
  final Map<String, DateTime> _publishFailingSince = {};

  /// When a send was first held for a circle, per circle key: the earliest
  /// proof of a transient core cause, older than the first read naming it.
  final Map<String, DateTime> _heldSince = {};

  /// The circle keys whose hold the user's own action just made: their
  /// transient cause shows at once, not after the window.
  final Set<String> _userHeld = {};

  /// The transient core cause last read for each circle key, and the instant
  /// the first read naming it returned.
  final Map<String, ({SharingPausedReason reason, DateTime since})>
  _transientSince = {};

  /// When a stop last left a previous live-sync session holding the guard.
  /// Process-wide, like [_subscriptionLostSince].
  DateTime? _sessionHeldSince;

  /// When a relay last dropped this device's group subscription (Unit C).
  /// Process-wide rather than per-circle: the engine holds one socket set, and
  /// Unit C's signal is about the socket, not a group.
  DateTime? _subscriptionLostSince;

  /// When the engine last entered [SyncConnectionPhase.disconnected].
  DateTime? _disconnectedSince;

  /// When the app last came to the front; `null` while it is away.
  DateTime? _watchingSince;

  /// The visits already ended, oldest first: only the newest that together
  /// outlast one confirmation window, which is all [_watchedSince] can need.
  final List<({DateTime from, DateTime to})> _watched = [];

  /// How much more watching the nearest withheld cause of the derivation in
  /// hand needs; `null` when it withheld none.
  Duration? _confirmIn;

  /// Re-derives when that watching is done, rather than at the next tick.
  Timer? _confirm;

  late ValueListenable<bool> _foreground;

  Timer? _tick;
  Duration _tickInterval = kSharingHealthTick;

  /// Monotonic lifecycle counter. A [refresh] whose async read completes after
  /// a newer one started must not publish its older verdict — the same
  /// generation-fence shape `LocationPublishSchedulerNotifier` uses.
  int _generation = 0;

  /// The derivation in flight, which a [refresh] asked meanwhile joins; one
  /// more runs after it ([_again]), so a burst of publish outcomes costs at
  /// most two recovery reads, never one per outcome.
  Future<void>? _inFlight;
  bool _again = false;

  /// Set once the notifier is disposed, so a late async completion cannot
  /// resurrect it.
  bool _disposed = false;

  DateTime Function() get _now => ref.read(sharingHealthClockProvider);

  @override
  SharingHealth build() {
    // An identity change rebuilds this same instance: start a fresh lifecycle
    // with none of the last identity's evidence, and fence out a derivation
    // the last one left in flight.
    _disposed = false;
    ++_generation;
    _publishFailingSince.clear();
    _heldSince.clear();
    _userHeld.clear();
    _transientSince.clear();
    _sessionHeldSince = null;
    _subscriptionLostSince = null;
    _disconnectedSince = null;
    _watchingSince = null;
    _watched.clear();

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
    final foreground = _foreground = ref.read(sharingHealthForegroundProvider);
    void syncTick() {
      if (foreground.value) {
        _watchingSince ??= _now();
        // Re-derive immediately as well as re-arming, so the first thing a
        // returning user sees is a fresh verdict rather than the one that was
        // true when they left.
        _tick ??= Timer.periodic(_tickInterval, (_) => unawaited(refresh()));
        unawaited(refresh());
      } else {
        _endVisit();
        _tick?.cancel();
        _tick = null;
        _confirm?.cancel();
        _confirm = null;
      }
    }

    foreground.addListener(syncTick);
    ref.onDispose(() {
      _disposed = true;
      foreground.removeListener(syncTick);
      _tick?.cancel();
      _tick = null;
      _confirm?.cancel();
      _confirm = null;
    });
    syncTick();

    // The verdict is about the circle on screen: another circle selected, or
    // none, is re-derived now, not at the next tick. `Circle` equality is its
    // id alone, so the selection does not notify when only the selected
    // circle's state changed; the circle list does. The list notifies from
    // inside the selection's rebuild, where the selection cannot be read, so
    // the derivation starts once that build has returned.
    void refreshAfterBuild() => scheduleMicrotask(() {
      if (!_disposed) unawaited(refresh());
    });
    ref
      ..listen<Circle?>(selectedCircleProvider, (_, _) => refreshAfterBuild())
      ..listen(circlesProvider, (_, _) => refreshAfterBuild());

    return SharingHealth.healthy;
  }

  /// Records the outcome of one publish attempt.
  ///
  /// [acked] must mean a relay ACK, never a completed send: the whole point of
  /// this record is that an unacked publish delivered nothing.
  void recordPublishOutcome(String circleKey, {required bool acked}) {
    if (acked) {
      _publishFailingSince.remove(circleKey);
      // An acknowledged publish is proof nothing held the circle's sends, so
      // a held send clears itself here rather than needing its own "all
      // better now" call that a caller could forget to make.
      _clearHeld(circleKey);
    } else {
      _publishFailingSince[circleKey] ??= _now();
    }
    unawaited(refresh());
  }

  /// Records that something held a send for a circle instead of sealing it.
  ///
  /// It names no cause: the core's recovery read does. It dates the hold, so
  /// a transient cause is shown from the first held send rather than from the
  /// first read that named it, and [byUser] marks a hold the user's own
  /// action made, whose cause shows at once. Cleared by the next acknowledged
  /// publish for the same circle, or a read naming no cause.
  void recordDeferredSend(String circleKey, {bool byUser = false}) {
    _heldSince[circleKey] ??= _now();
    if (byUser) _userHeld.add(circleKey);
    unawaited(refresh());
  }

  void _clearHeld(String circleKey) {
    _heldSince.remove(circleKey);
    _userHeld.remove(circleKey);
    _transientSince.remove(circleKey);
  }

  /// Records how a live-sync stop ended. [LiveSyncStopOutcome.stillHolding]
  /// dates the held session; any other outcome — a stop that released it, or
  /// a start, which proves the previous session drained — clears it.
  void recordStopOutcome(LiveSyncStopOutcome outcome) {
    switch (outcome) {
      case LiveSyncStopOutcome.stillHolding:
        _sessionHeldSince ??= _now();
      case LiveSyncStopOutcome.stopped:
      case LiveSyncStopOutcome.idle:
        _sessionHeldSince = null;
    }
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

  /// Records that this isolate just stored a peer's location.
  ///
  /// The receipt is already in the store the verdict reads; this makes it
  /// count now rather than at the next tick, so a "not receiving" verdict
  /// ends with the delivery that disproves it. A healthy verdict with no
  /// derivation in flight cannot change on a delivery, and reads nothing.
  void recordPeerDelivery() {
    if (state.isStopped || _inFlight != null) unawaited(refresh());
  }

  /// Closes the visit in progress into [_watched].
  void _endVisit() {
    final from = _watchingSince;
    if (from == null) return;
    _watchingSince = null;
    _watched.add((from: from, to: _now()));
    // A cause older than the visits that outlast one window has been watched
    // for the window whatever came before them.
    var kept = Duration.zero;
    var first = _watched.length;
    while (first > 0 && kept <= kSharingFaultConfirmationWindow) {
      first--;
      kept += _watched[first].to.difference(_watched[first].from);
    }
    _watched.removeRange(0, first);
  }

  /// How long the app has been in front since [onset], over every visit.
  Duration _watchedSince(DateTime onset, DateTime now) {
    Duration within(DateTime from, DateTime to) {
      final start = from.isBefore(onset) ? onset : from;
      return to.isAfter(start) ? to.difference(start) : Duration.zero;
    }

    var total = Duration.zero;
    for (final visit in _watched) {
      total += within(visit.from, visit.to);
    }
    final current = _watchingSince;
    return current == null ? total : total + within(current, now);
  }

  /// Whether a cause dated [onset] has outlasted the confirmation window in
  /// time the app was in front to watch it.
  ///
  /// Time away is not counted: nothing may have been sending or receiving
  /// then, and what the app finds on its way back its own resume is already
  /// repairing. A cause that has not is withheld, and [_confirmIn] has the
  /// derivation run again the moment it will have.
  bool _stood(DateTime onset, DateTime now) {
    final short = kSharingFaultConfirmationWindow - _watchedSince(onset, now);
    if (short < Duration.zero) return true;
    final nearest = _confirmIn;
    if (nearest == null || short < nearest) _confirmIn = short;
    return false;
  }

  /// Whether nothing has been delivered since [delivered] for longer than
  /// [threshold], and the app watched that silence stop being ordinary.
  ///
  /// The window is counted from one window short of the threshold, never from
  /// the delivery: until then the quiet is ordinary, and watching ordinary
  /// quiet proves nothing about what followed it while the app was away. In
  /// front throughout, this is the threshold alone.
  bool _watchedPast(DateTime delivered, Duration threshold, DateTime now) =>
      now.difference(delivered) > threshold &&
      _stood(
        delivered.add(threshold - kSharingFaultConfirmationWindow),
        now,
      );

  /// Re-derives the verdict now.
  ///
  /// Safe to call concurrently: a call made while a derivation is in flight
  /// joins it, and one more derivation runs after it, so the verdict always
  /// follows the newest call and never an older one.
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
  Future<void> refresh() {
    if (ref.read(syncStatusProvider).phase == SyncConnectionPhase.paused) {
      ++_generation;
      return Future<void>.value();
    }
    final inFlight = _inFlight;
    if (inFlight != null) {
      _again = true;
      return inFlight;
    }
    return _inFlight = _derive().whenComplete(() => _inFlight = null);
  }

  Future<void> _derive() async {
    do {
      _again = false;
      if (ref.read(syncStatusProvider).phase == SyncConnectionPhase.paused) {
        ++_generation;
        return;
      }
      final generation = ++_generation;
      // Tagged with the circle it was derived for: a verdict that lands after
      // another circle was selected must not be shown as that circle's.
      final circle = ref.read(selectedCircleProvider);
      final next = (await _evaluate()).about(
        circle == null ? null : sharingCircleKey(circle),
      );
      // Riverpod disposes the notifier on logout / identity change; a late
      // async completion must not resurrect it, nor overtake a newer
      // derivation.
      if (_disposed) return;
      // A refresh asked meanwhile reads newer evidence: only its answer lands.
      if (generation == _generation && !_again) {
        state = next;
        _confirm?.cancel();
        final due = _confirmIn;
        // A second past it: a cause must OUTLAST the window, so a timer that
        // fires on the instant would find it not yet confirmed.
        _confirm = due == null || !_foreground.value
            ? null
            : Timer(
                due + const Duration(seconds: 1),
                () => unawaited(refresh()),
              );
      }
    } while (_again);
  }

  Future<SharingHealth> _evaluate() async {
    _confirmIn = null;
    final circle = ref.read(selectedCircleProvider);
    if (circle == null ||
        circle.membershipStatus != MembershipStatus.accepted) {
      return SharingHealth.healthy;
    }

    // Everything read from `ref` is read before the first await: the
    // container may be disposed while a read is in flight.
    final now = _now();
    final key = sharingCircleKey(circle);
    final circles = ref.read(circleServiceProvider);
    final notices = ref.read(changeNoticesProvider);
    final selfPubkey = ref.read(identityProvider).valueOrNull?.pubkeyHex;
    final health = await ref
        .read(circleHealthServiceProvider)
        .read(nostrGroupId: circle.nostrGroupId);
    final ackedAt = health.lastPublishAckedAt;

    // The core's causes outrank everything inferred here: each says something
    // true and specific, and the core reads them in its own worst-first order.
    final SharingPausedReason? cause;
    try {
      cause = await _coreCause(circle, circles, notices);
    } on Object catch (_) {
      // The read failed: what the circle list says about the engine is the
      // best evidence left, then inference.
      return _engineStateVerdict(circle, now, health) ??
          _inferred(circle, key, now, health, ackedAt, selfPubkey);
    }
    if (cause == null) {
      _clearHeld(key);
    } else if (isDurablePausedReason(cause)) {
      return _paused(cause, now, health);
    } else {
      final shown = _transientVerdict(key, cause, now, health);
      if (shown != null) return shown;
    }
    return _inferred(circle, key, now, health, ackedAt, selfPubkey);
  }

  /// The core's cause for [circle], refined by its notice where the notice
  /// decides what is true to say. Throws when the recovery read fails.
  Future<SharingPausedReason?> _coreCause(
    Circle circle,
    CircleService circles,
    ChangeNotices notices,
  ) async {
    final cause = await circles.circleRecovery(circle);
    if (cause == null) return null;
    final reason = pausedReasonOf(cause);
    // A store that cannot answer reads as collided, and that reading is not
    // persisted: without the recorded note, no destructive remedy is named.
    if (reason == SharingPausedReason.routingCollision &&
        !await _noticeHolds(circle, ChangeNoteFfi.routingCollision, notices)) {
      return SharingPausedReason.routingUnchecked;
    }
    if (reason == SharingPausedReason.removalUnmade &&
        !await _noticeHolds(
          circle,
          ChangeNoteFfi.queuedRemovalDropped,
          notices,
        )) {
      return SharingPausedReason.removalUnmadeUntold;
    }
    return reason;
  }

  /// Whether the circle's notice holds [note]; `false` when it cannot be
  /// read, the reading that offers nothing destructive.
  Future<bool> _noticeHolds(
    Circle circle,
    ChangeNoteFfi note,
    ChangeNotices notices,
  ) async {
    try {
      final read = await notices.read(circle.mlsGroupId);
      return read?.notes.contains(note) ?? false;
    } on Object catch (e) {
      debugPrint('[SharingHealth] notice read failed: ${e.runtimeType}');
      return false;
    }
  }

  /// A transient core cause, shown once it has stood for the confirmation
  /// window ([_stood]) — from the first read naming it, or the first held send
  /// if that is older — or at once when the user's own action made the hold.
  SharingHealth? _transientVerdict(
    String key,
    SharingPausedReason reason,
    DateTime now,
    CircleHealthTimestamps health,
  ) {
    final seen = _transientSince[key];
    final readSince = seen != null && seen.reason == reason ? seen.since : now;
    _transientSince[key] = (reason: reason, since: readSince);
    final held = _heldSince[key];
    final onset = held != null && held.isBefore(readSince) ? held : readSince;
    if (_userHeld.contains(key) || _stood(onset, now)) {
      return _paused(reason, onset, health);
    }
    return null;
  }

  /// The verdict the circle list's engine state alone supports, used only
  /// when the core's read failed.
  SharingHealth? _engineStateVerdict(
    Circle circle,
    DateTime now,
    CircleHealthTimestamps health,
  ) => switch (circle.engineState) {
    CircleEngineState.live => null,
    CircleEngineState.quarantined => _paused(
      SharingPausedReason.circleQuarantined,
      now,
      health,
    ),
    CircleEngineState.disbanded => _paused(
      SharingPausedReason.circleDisbanded,
      now,
      health,
    ),
    CircleEngineState.unrecoverable => _paused(
      SharingPausedReason.circleUnrecoverable,
      now,
      health,
    ),
  };

  /// Dart's own named causes, then the inferred verdicts.
  SharingHealth _inferred(
    Circle circle,
    String key,
    DateTime now,
    CircleHealthTimestamps health,
    DateTime? ackedAt,
    String? selfPubkey,
  ) {
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

    final paused = _pausedVerdict(now, health);
    if (paused != null) return paused;

    final publishing = _publishVerdict(key, now, ackedAt);
    if (publishing != null) return publishing;

    return _receiveVerdict(circle, now, health, selfPubkey) ??
        SharingHealth.healthy;
  }

  SharingHealth? _pausedVerdict(DateTime now, CircleHealthTimestamps health) {
    final candidates = <SharingPausedReason, DateTime?>{
      SharingPausedReason.receiveSubscriptionLost: _subscriptionLostSince,
      SharingPausedReason.relayDisconnected: _disconnectedSince,
      SharingPausedReason.sessionStillHeld: _sessionHeldSince,
    };
    for (final entry in candidates.entries) {
      final onset = entry.value;
      if (onset != null && _stood(onset, now)) {
        return _paused(entry.key, onset, health);
      }
    }
    return null;
  }

  SharingHealth _paused(
    SharingPausedReason reason,
    DateTime onset,
    CircleHealthTimestamps health,
  ) {
    final delivered = _lastKnownGood(reason, health);
    return SharingHealth.paused(
      reason,
      delivered != null && delivered.isBefore(onset) ? delivered : onset,
      ageProvable: delivered != null,
    );
  }

  /// The last instant the direction [reason] stopped is known to have
  /// delivered, or `null` when nothing proves one.
  ///
  /// The fault ONSET is not that instant, and reporting it as one understates
  /// the outage: a dropped subscription noticed three minutes ago on a circle
  /// whose last peer location arrived forty minutes ago would read "three
  /// minutes". So the verdict is dated by the EARLIER of the onset and this
  /// instant, and the instant comes only from the direction that failed — a
  /// held send by the stored publish ack, a cause that stops receiving by the
  /// stored peer instant, one that holds both directions by the older of the
  /// two, and only when both exist — because peers' locations arriving say
  /// nothing about this device's going out. That is never later than the true
  /// last delivery, so the banner can under-state freshness but never
  /// over-state it — the only direction an error may safely go here. With no
  /// such instant the onset proves nothing, and the verdict carries no
  /// provable age: the banner then shows none. A circle that ended, halted or
  /// is being left is no fault in the pipeline, and has no age at all.
  DateTime? _lastKnownGood(
    SharingPausedReason reason,
    CircleHealthTimestamps health,
  ) {
    final acked = health.lastPublishAckedAt;
    final peer = health.lastPeerEventAt;
    final older = acked == null || peer == null
        ? null
        : (acked.isBefore(peer) ? acked : peer);
    return switch (reason) {
      SharingPausedReason.removalUnmade ||
      SharingPausedReason.removalUnmadeUntold ||
      SharingPausedReason.departureDue ||
      SharingPausedReason.storedInput ||
      SharingPausedReason.awaitsForeground => acked,
      SharingPausedReason.receiveSubscriptionLost ||
      SharingPausedReason.stalled => peer,
      SharingPausedReason.relayDisconnected ||
      SharingPausedReason.circleQuarantined ||
      SharingPausedReason.awaitingRelays ||
      SharingPausedReason.acknowledged ||
      SharingPausedReason.stagedWithoutRecord ||
      SharingPausedReason.routingCollision ||
      SharingPausedReason.routingUnchecked ||
      SharingPausedReason.sessionStillHeld => older,
      SharingPausedReason.circleDisbanded ||
      SharingPausedReason.circleUnrecoverable ||
      SharingPausedReason.leaving => null,
    };
  }

  SharingHealth? _publishVerdict(String key, DateTime now, DateTime? ackedAt) {
    // Route 1 — this isolate watched a publish come back unacked and nothing
    // has acked since. Fast, but only ever available in the foreground.
    final failingSince = _publishFailingSince[key];
    if (failingSince != null && _stood(failingSince, now)) {
      // With no stored ack, the onset is this process's own and proves no age.
      return SharingHealth.publishFailing(
        ackedAt ?? failingSince,
        ageProvable: ackedAt != null,
      );
    }

    // Route 2 — whoever was publishing (either isolate), nothing has been kept
    // by a relay for two cadences. Requires a baseline: a circle that has never
    // published successfully has nothing to have stopped. And the silence must
    // have been watched: an ack that only aged while the app was away is
    // replaced by the resume's own publish, or stands and is shown
    // ([_watchedPast]).
    if (ackedAt != null &&
        _watchedPast(ackedAt, kPublishSilenceThreshold, now)) {
      return SharingHealth.publishFailing(ackedAt);
    }
    return null;
  }

  SharingHealth? _receiveVerdict(
    Circle circle,
    DateTime now,
    CircleHealthTimestamps health,
    String? selfPubkey,
  ) {
    // Nothing to receive: a solo circle is quiet because it is empty. An
    // unresolved identity (the provider is still loading, or the secure-storage
    // read missed) means the roster cannot be split into self and others, so
    // the verdict is withheld rather than guessed — the tick re-derives it
    // moments later, and a banner shown on a guess is worse than one shown
    // late.
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
    // Watched, as the send side is: while the app was away nothing may have
    // been listening, and what peers published since arrives with the
    // resume's reconnect.
    if (_watchedPast(lastPeerAt, kReceiveSilenceThreshold, now)) {
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

/// The remedy behind the banner's "Try Again" for a quarantined circle.
///
/// Retries loading the selected circle's encrypted state, then re-reads the
/// circle list so the verdict follows what the engine now holds. Never throws:
/// a retry that fails leaves the circle quarantined, and the banner says so.
final sharingQuarantineRetryProvider = Provider<Future<void> Function()>((
  ref,
) {
  return () async {
    final circle = ref.read(selectedCircleProvider);
    if (circle == null) return;
    try {
      await ref
          .read(circleServiceProvider)
          .retryQuarantinedCircle(circle.mlsGroupId);
    } on Object catch (e) {
      // Rule 8: the type only.
      debugPrint('[SharingHealth] quarantine retry failed: ${e.runtimeType}');
    }
    ref.invalidate(circlesProvider);
    try {
      await ref.read(circlesProvider.future);
      await ref.read(sharingHealthProvider.notifier).refresh();
    } on Object catch (e) {
      debugPrint('[SharingHealth] retry refresh failed: ${e.runtimeType}');
    }
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
    final result = await ref
        .read(circleServiceProvider)
        .repairCircleEpoch(circle, selfPubkeyHex: selfPubkey);
    // Awaiting its relays shows as every change awaiting them does, at once:
    // the user's own action made the hold.
    if (result is EpochRepairAwaitingRelays) {
      ref
          .read(sharingHealthProvider.notifier)
          .recordDeferredSend(sharingCircleKey(circle), byUser: true);
    }
    return result;
  } on Object catch (e) {
    // Rule 8 again: a failed epoch repair must not put engine text on screen,
    // and must not mask the other legs' work.
    debugPrint('[SharingHealth] epoch repair failed: ${e.runtimeType}');
    return null;
  }
}
