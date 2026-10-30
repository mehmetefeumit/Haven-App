/// Proves the clock-skew detector is REACHED from the production paths, not
/// merely reachable.
///
/// [ClockSkewDetector] is unit-tested in `clock_skew_detector_test.dart`; the
/// failure mode this file guards against is different and, in this repo,
/// far more common: a correct policy object that nothing ever calls. Both of
/// the wire-ups below were absent before this change —
///
///  * `publishLocation` returned its outcome to callers that dropped it on
///    the floor (`catch`-and-`debugPrint` in both the per-circle scheduler
///    and the publisher provider), and threw away a total rejection
///    entirely;
///  * `_persistDecryptedLocation` — the single funnel every receive plane
///    reaches — read the sender's timestamp only to store it.
///
/// so each test here fails against the pre-change service.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/rust/api.dart' show LocationPublishFfi;
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/clock_skew_detector.dart';
import 'package:haven/src/services/location_sharing_service.dart';

import '../mocks/mock_circle_service.dart';
import '../mocks/mock_relay_service.dart';

DecryptedLocation _loc(String sender, {required DateTime timestamp}) =>
    DecryptedLocation(
      senderPubkey: sender,
      latitude: 1,
      longitude: 2,
      geohash: 'g',
      timestamp: timestamp,
      expiresAt: timestamp.add(const Duration(hours: 1)),
    );

void main() {
  late MockCircleService circleService;
  late MockRelayService relayService;
  late ClockSkewDetector detector;
  late LocationSharingService service;
  late Circle circle;

  setUp(() {
    circleService = MockCircleService();
    relayService = MockRelayService();
    detector = ClockSkewDetector();
    service = LocationSharingService(
      circleService: circleService,
      relayService: relayService,
      clockSkewDetector: detector,
    );
    circle = TestCircleFactory.createCircle(
      nostrGroupId: const [1, 2, 3],
      mlsGroupId: const [9, 9, 9],
    );
  });

  tearDown(() => detector.dispose());

  Future<void> publish() => service.publishLocation(
    mlsGroupId: const [9, 9, 9],
    nostrGroupId: const [1, 2, 3],
    latitude: 1,
    longitude: 2,
  );

  group('publish path', () {
    test('a send the relays refused for its time raises the verdict in its '
        'direction', () async {
      // The bar: a refusal must reach something that can act on it — every
      // caller drops the outcome once it has fed the health model.
      for (final (answer, complaint) in [
        (LocationPublishFfi.clockAhead, DeviceClockComplaint.ahead),
        (LocationPublishFfi.clockBehind, DeviceClockComplaint.behind),
        (LocationPublishFfi.clockUnspecified, DeviceClockComplaint.unspecified),
      ]) {
        circleService.publishAnswers = [answer];

        await publish();
        circleService.publishAnswers = [];

        expect(
          detector.status.signal,
          ClockSkewSignal.relayRejectedTimestamp,
          reason: '$answer',
        );
        expect(detector.status.complaint, complaint, reason: '$answer');
      }
    });

    test('a refusal for anything else is distinguished from a clock one',
        () async {
      // Same shape of failure, different cause: the user must not be told
      // their clock is wrong when the relays blamed something else.
      circleService.publishAnswers = [LocationPublishFfi.refused];

      await publish();

      expect(detector.status.signal, ClockSkewSignal.none);
    });

    test('a send no relay was reached for, or not made, leaves the verdict '
        'alone', () async {
      // An ordinary transport failure says nothing either way about the
      // clock: clearing the verdict there would let one dropped connection
      // hide a clock that is still wrong.
      detector.recordLocationPublish(LocationPublishFfi.clockAhead);
      for (final answer in [
        LocationPublishFfi.unreachable,
        LocationPublishFfi.expired,
        LocationPublishFfi.superseded,
        LocationPublishFfi.ended,
        LocationPublishFfi.inFlight,
      ]) {
        circleService.publishAnswers = [answer];

        await publish();
        circleService.publishAnswers = [];

        expect(detector.status.isSkewed, isTrue, reason: '$answer');
      }
    });

    test('a held send tells the detector nothing', () async {
      detector.recordLocationPublish(LocationPublishFfi.clockAhead);
      circleService.holdNextSeal = true;

      await publish();

      expect(detector.status.isSkewed, isTrue);
    });

    test('a successful publish clears a previously raised signal', () async {
      detector.recordLocationPublish(LocationPublishFfi.clockAhead);
      expect(detector.status.isSkewed, isTrue);

      await publish();

      expect(detector.status.signal, ClockSkewSignal.none);
    });
  });

  group('receive path', () {
    test('decrypted peer timestamps reach the detector', () async {
      // Two distinct MLS-authenticated members, both ahead of this device.
      final now = DateTime.now();
      await service.ingestStreamedLocation(
        circle: circle,
        decrypted: _loc(
          'aa' * 32,
          timestamp: now.add(const Duration(hours: 6)),
        ),
      );
      await service.ingestStreamedLocation(
        circle: circle,
        decrypted: _loc(
          'bb' * 32,
          timestamp: now.add(const Duration(hours: 6)),
        ),
      );

      expect(
        detector.status.signal,
        ClockSkewSignal.peersAheadOfDevice,
        reason:
            'the slow direction is silent by construction — the publisher '
            'gets a successful ACK — so the receive funnel is the only place '
            'the evidence exists',
      );
      expect(detector.status.complaint, DeviceClockComplaint.behind);
    });

    test('one peer alone DOES raise the signal through the service, and a '
        'second, agreeing peer clears it', () async {
      // A two-member circle has exactly this shape: one peer, forever. The
      // service must funnel that evidence, not swallow it — otherwise the
      // commonest circle size can never see a fault that discards every
      // update while the publisher keeps getting a successful ACK. (This
      // assertion was inverted when the rule always required two members;
      // the DOCUMENTED behaviour moved, and the second half below keeps the
      // corroboration promise under test rather than dropping it.)
      final now = DateTime.now();
      await service.ingestStreamedLocation(
        circle: circle,
        decrypted: _loc(
          'aa' * 32,
          timestamp: now.add(const Duration(hours: 6)),
        ),
      );

      expect(detector.status.signal, ClockSkewSignal.peersAheadOfDevice);
      expect(detector.status.corroboratingSources, 1);

      // …and once a second member IS reachable, its agreement with this
      // device wins: corroboration still decides whenever it is available.
      await service.ingestStreamedLocation(
        circle: circle,
        decrypted: _loc('bb' * 32, timestamp: now),
      );

      expect(
        detector.status.signal,
        ClockSkewSignal.none,
        reason:
            'a member who agrees with this clock is direct evidence that the '
            'odd one out is the outlier, so the verdict must clear',
      );
    });

    test('ordinary in-time peer locations keep the verdict healthy', () async {
      final now = DateTime.now();
      for (final key in ['aa', 'bb', 'cc']) {
        await service.ingestStreamedLocation(
          circle: circle,
          decrypted: _loc(key * 32, timestamp: now),
        );
      }
      expect(detector.status.signal, ClockSkewSignal.none);
    });
  });

  test('the service works without a detector', () async {
    // The dependency is optional; every pre-existing test constructs the
    // service without it and must keep passing.
    final bare = LocationSharingService(
      circleService: MockCircleService(),
      relayService: MockRelayService(),
    );
    final result = await bare.publishLocation(
      mlsGroupId: const [9, 9, 9],
      nostrGroupId: const [1, 2, 3],
      latitude: 1,
      longitude: 2,
    );
    expect(result, isA<LocationPublishSent>());
    expect((result as LocationPublishSent).acked, isTrue);
  });
}
