/// Per-circle delivery-liveness timestamps (presence only).
///
/// ## Why a separate, narrow service
///
/// Everything Haven surfaced about location sharing until now was a FLAG — an
/// engine that reports `isRunning`, a toggle the user left on, a foreground
/// service whose notification still says "sending and receiving". Every failure
/// mode in `docs/BACKGROUND_SHARING_FAILURE_ANALYSIS.md` leaves all of those
/// flags true while nothing is actually delivered. The only honest liveness
/// signal is DELIVERY, and delivery has to be measured where it happens and
/// remembered across process death — hence two persisted instants per circle,
/// and nothing else.
///
/// ## Privacy
///
/// Presence only: two millisecond instants on the LOCAL clock, keyed by the
/// public `nostr_group_id` that `circles.db` already stores (never the real MLS
/// group id — Security Rule 4). No coordinates, no pubkeys, no relay URLs, and
/// the rows are dropped with the circle, so leaving a circle leaves no record
/// of when it last worked.
library;

import 'package:flutter/foundation.dart';

import 'package:haven/src/rust/api.dart';

/// A circle's delivery-health timestamps, or `null` where nothing has ever been
/// observed.
///
/// "Never observed" is deliberately distinct from "stopped": a circle whose
/// peer has never shared is indistinguishable from one whose receive plane is
/// dead, so only a timestamp that once existed and has since gone stale is
/// evidence of a fault.
@immutable
class CircleHealthTimestamps {
  /// Creates a timestamp pair.
  const CircleHealthTimestamps({this.lastPublishAckedAt, this.lastPeerEventAt});

  /// The empty pair — nothing observed for this circle yet.
  static const none = CircleHealthTimestamps();

  /// When a relay last ACKed a location publish for this circle.
  final DateTime? lastPublishAckedAt;

  /// When a peer's location for this circle was last decrypted and persisted.
  final DateTime? lastPeerEventAt;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CircleHealthTimestamps &&
          runtimeType == other.runtimeType &&
          lastPublishAckedAt == other.lastPublishAckedAt &&
          lastPeerEventAt == other.lastPeerEventAt;

  @override
  int get hashCode => Object.hash(lastPublishAckedAt, lastPeerEventAt);
}

/// Records and reads per-circle delivery liveness.
abstract class CircleHealthService {
  /// Records that at least one relay ACKed a location publish.
  ///
  /// Callers MUST have an affirmative relay ACK. A `PublishResult` with an
  /// empty `acceptedBy` delivered nothing, and stamping it would make a dead
  /// publish plane read as healthy — the exact defect this record exists to
  /// end (the principle behind Security Rule 13: acked means acked).
  Future<void> notePublishAcked({
    required List<int> nostrGroupId,
    required DateTime at,
  });

  /// Records that a peer's location was decrypted and persisted.
  ///
  /// [at] is the local receipt clock, never the sender's timestamp: this
  /// answers "is anything still arriving", which a peer's clock cannot.
  Future<void> notePeerEvent({
    required List<int> nostrGroupId,
    required DateTime at,
  });

  /// Reads a circle's delivery-health timestamps.
  Future<CircleHealthTimestamps> read({required List<int> nostrGroupId});
}

/// Production [CircleHealthService] over the shared [CircleManagerFfi] handle.
///
/// Takes the same `circleManagerFactory` shape as `NostrProfileService` and
/// `CatchupService`, and for the same reason: never open a second manager over
/// the same SQLCipher database.
///
/// Every method is failure-tolerant. Health telemetry is diagnostic; a write
/// that throws must never take down the publish or receive path it observes,
/// and a read that throws must resolve to "nothing observed" rather than
/// inventing an outage. Only the error TYPE is logged (Security Rule 8).
class NostrCircleHealthService implements CircleHealthService {
  /// Creates a service over the shared circle-manager handle.
  const NostrCircleHealthService({
    required Future<CircleManagerFfi> Function() circleManagerFactory,
  }) : _circleManagerFactory = circleManagerFactory;

  final Future<CircleManagerFfi> Function() _circleManagerFactory;

  @override
  Future<void> notePublishAcked({
    required List<int> nostrGroupId,
    required DateTime at,
  }) async {
    try {
      final manager = await _circleManagerFactory();
      await manager.notePublishAcked(
        nostrGroupId: nostrGroupId,
        atMs: at.millisecondsSinceEpoch,
      );
    } on Object catch (e) {
      debugPrint('[CircleHealth] publish-ack record failed: ${e.runtimeType}');
    }
  }

  @override
  Future<void> notePeerEvent({
    required List<int> nostrGroupId,
    required DateTime at,
  }) async {
    try {
      final manager = await _circleManagerFactory();
      await manager.notePeerEvent(
        nostrGroupId: nostrGroupId,
        atMs: at.millisecondsSinceEpoch,
      );
    } on Object catch (e) {
      debugPrint('[CircleHealth] peer-event record failed: ${e.runtimeType}');
    }
  }

  @override
  Future<CircleHealthTimestamps> read({
    required List<int> nostrGroupId,
  }) async {
    try {
      final manager = await _circleManagerFactory();
      final health = await manager.circleHealth(nostrGroupId: nostrGroupId);
      return CircleHealthTimestamps(
        lastPublishAckedAt: _fromMs(health.lastPublishAckedAtMs),
        lastPeerEventAt: _fromMs(health.lastPeerEventAtMs),
      );
    } on Object catch (e) {
      debugPrint('[CircleHealth] read failed: ${e.runtimeType}');
      return CircleHealthTimestamps.none;
    }
  }

  static DateTime? _fromMs(int? ms) =>
      ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
}
