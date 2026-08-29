/// Delivery liveness is recorded from DELIVERY, never from an attempt.
///
/// The whole sharing-health model rests on two persisted instants, and both are
/// worthless if they can be stamped by something that did not actually deliver.
/// A publish that no relay accepted reached nobody — recording it would make a
/// dead publish plane read as permanently healthy, which is exactly the silence
/// the field incident exposed (Security Rule 13's principle: acked means acked,
/// never merely sent).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/services/circle_health_service.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/location_sharing_service.dart';

import '../mocks/mock_circle_service.dart';
import '../mocks/mock_relay_service.dart';

const _peerPubkey =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

final _now = DateTime.utc(2026, 8, 28, 12);

/// Records every call so a test can assert on WHAT was stamped, not merely
/// that something was.
class _RecordingHealthService implements CircleHealthService {
  final List<({List<int> nostrGroupId, DateTime at})> acks = [];
  final List<({List<int> nostrGroupId, DateTime at})> peerEvents = [];

  @override
  Future<void> notePublishAcked({
    required List<int> nostrGroupId,
    required DateTime at,
  }) async => acks.add((nostrGroupId: nostrGroupId, at: at));

  @override
  Future<void> notePeerEvent({
    required List<int> nostrGroupId,
    required DateTime at,
  }) async => peerEvents.add((nostrGroupId: nostrGroupId, at: at));

  @override
  Future<CircleHealthTimestamps> read({
    required List<int> nostrGroupId,
  }) async => CircleHealthTimestamps.none;
}

void main() {
  late MockCircleService circleService;
  late MockRelayService relayService;
  late _RecordingHealthService health;
  late LocationSharingService service;

  setUp(() {
    circleService = MockCircleService();
    relayService = MockRelayService();
    health = _RecordingHealthService();
    service = LocationSharingService(
      circleService: circleService,
      relayService: relayService,
      healthService: health,
      now: () => _now,
    );
  });

  Future<LocationPublishOutcome> publish() => service.publishLocation(
    mlsGroupId: const [1, 2, 3],
    nostrGroupId: const [9, 9],
    senderPubkeyHex: 'ff' * 32,
    latitude: 1,
    longitude: 2,
  );

  group('publish liveness', () {
    test('an ACKed publish is recorded against the circle, on the local clock',
        () async {
      await publish();

      expect(health.acks, hasLength(1));
      expect(health.acks.single.nostrGroupId, const [9, 9]);
      expect(health.acks.single.at, _now);
    });

    test('a publish NO relay accepted is not recorded', () async {
      // The load-bearing assertion of this file. `shouldRejectPublish` returns
      // a well-formed `PublishResult` with an empty `acceptedBy` — the shape a
      // relay policy rejection produces, which the old code path could not
      // distinguish from a success because it dropped the result entirely.
      relayService.shouldRejectPublish = true;

      final result = await publish();

      expect(result, isA<LocationPublishSent>());
      expect(
        (result as LocationPublishSent).result.acceptedBy,
        isEmpty,
        reason: 'anti-vacuity for the below',
      );
      expect(
        health.acks,
        isEmpty,
        reason: 'a rejected publish delivered nothing; stamping it would make '
            'a dead publish plane read as healthy forever',
      );
    });

    test('a publish that throws is not recorded', () async {
      relayService.publishThrows = StateError('relay unreachable');

      await expectLater(publish(), throwsA(isA<StateError>()));
      expect(health.acks, isEmpty);
    });

    test('a DEFERRED send is never stamped as delivered', () async {
      // Unit B's engine-deferral path: the MLS engine queued the update instead
      // of encrypting it, so nothing reached a relay. It is the one outcome
      // that most resembles a success from the caller's side — no throw, no
      // rejection — and stamping it would be the original defect in a new
      // costume: a circle that has not sent anything for hours reading healthy.
      circleService.deferNextEncrypt = const LocationSendDeferred(
        unresolvedInputs: 1,
        discardedIntents: 1,
        repaired: false,
        commits: [],
        proposals: [],
      );

      final outcome = await publish();

      expect(outcome, isA<LocationPublishDeferred>());
      expect(
        health.acks,
        isEmpty,
        reason: 'nothing was delivered, so nothing may be dated as delivered',
      );
    });

    test('the service still publishes with no health recorder attached',
        () async {
      // The Android foreground service builds this without one; a null
      // recorder must not change the publish path.
      final bare = LocationSharingService(
        circleService: MockCircleService(),
        relayService: MockRelayService(),
      );

      final result = await bare.publishLocation(
        mlsGroupId: const [1, 2, 3],
        nostrGroupId: const [9, 9],
        senderPubkeyHex: 'ff' * 32,
        latitude: 1,
        longitude: 2,
      );

      expect(result, isA<LocationPublishSent>());
      expect((result as LocationPublishSent).result.acceptedBy, isNotEmpty);
    });
  });

  group('receive liveness', () {
    final circle = TestCircleFactory.createCircle(
      mlsGroupId: const [1, 2, 3],
      nostrGroupId: const [9, 9],
      members: [TestCircleFactory.createMember(pubkey: _peerPubkey)],
    );

    test('a decrypted peer location is recorded on the RECEIPT clock',
        () async {
      // Deliberately NOT `decrypted.timestamp`: this column answers "is
      // anything still arriving", and a peer whose clock runs fast would
      // otherwise keep the circle looking live long after it went silent.
      final senderClock = _now.add(const Duration(hours: 3));

      await service.ingestStreamedLocation(
        circle: circle,
        decrypted: DecryptedLocation(
          senderPubkey: _peerPubkey,
          latitude: 1,
          longitude: 2,
          geohash: 'u4pruy',
          timestamp: senderClock,
          expiresAt: senderClock.add(const Duration(minutes: 4)),
        ),
      );

      expect(health.peerEvents, hasLength(1));
      expect(health.peerEvents.single.nostrGroupId, const [9, 9]);
      expect(
        health.peerEvents.single.at,
        _now,
        reason: "the sender's clock must never set this device's receipt time",
      );
    });
  });
}
