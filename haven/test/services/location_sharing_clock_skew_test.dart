/// Proves the clock-skew detector is REACHED from the production paths, not
/// merely reachable.
///
/// [ClockSkewDetector] is unit-tested in `clock_skew_detector_test.dart`; the
/// failure mode this file guards against is different and, in this repo,
/// far more common: a correct policy object that nothing ever calls. Both of
/// the wire-ups below were absent before this change —
///
///  * `publishLocation` returned its [PublishResult] to callers that dropped
///    it on the floor (`catch`-and-`debugPrint` in both the per-circle
///    scheduler and the publisher provider), and threw away a total rejection
///    entirely;
///  * `_persistDecryptedLocation` — the single funnel every receive plane
///    reaches — read the sender's timestamp only to store it.
///
/// so each test here fails against the pre-change service.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/clock_skew_detector.dart';
import 'package:haven/src/services/location_sharing_service.dart';
import 'package:haven/src/services/relay_service.dart';

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
    senderPubkeyHex: 'ff' * 32,
    latitude: 1,
    longitude: 2,
  );

  group('publish path', () {
    test('a relay rejection is propagated, not swallowed', () {
      // The bar: a rejection must reach something that can act on it. Before
      // this change the only witness was a debugPrint.
      relayService
        ..shouldRejectPublish = true
        ..publishRejectionReason = 'invalid: '
            'event too far off from the current time';

      return publish().then((_) {
        expect(
          detector.status.signal,
          ClockSkewSignal.relayRejectedTimestamp,
          reason:
              'publishLocation must report the relay verdict itself — every '
              'caller discards the returned PublishResult',
        );
      });
    });

    test('a fast-clock rejection is distinguished from an ordinary one', () {
      // Same shape of failure, different cause. If these two produced the same
      // state the user would be told "sharing is failing" in both cases, which
      // is exactly the unactionable message this work exists to replace.
      relayService
        ..shouldRejectPublish = true
        ..publishRejectionReason = 'rate-limited: slow down';

      return publish().then((_) {
        expect(detector.status.signal, ClockSkewSignal.none);
      });
    });

    test(
      'a total rejection that surfaces as a THROW still reaches the detector',
      () async {
        // The production shape: when no relay accepts, Rust returns `Err`, so
        // Dart gets an exception and never a PublishResult. Before the Rust
        // change the exception carried no cause at all.
        relayService.publishThrows = const RelayClockRejectionException(
          'ahead',
        );

        await expectLater(
          publish(),
          throwsA(isA<RelayClockRejectionException>()),
        );

        expect(detector.status.signal, ClockSkewSignal.relayRejectedTimestamp);
        expect(detector.status.complaint, DeviceClockComplaint.ahead);
      },
    );

    test('an ordinary publish throw does not blame the clock', () async {
      relayService.publishThrows = const RelayServiceException(
        'Failed to publish event',
      );

      await expectLater(publish(), throwsA(isA<RelayServiceException>()));

      expect(detector.status.signal, ClockSkewSignal.none);
    });

    test('a successful publish clears a previously raised signal', () async {
      detector.recordPublishClockRejection('ahead');
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

    test('one peer alone does not raise the signal through the service', () {
      final now = DateTime.now();
      return service
          .ingestStreamedLocation(
            circle: circle,
            decrypted: _loc(
              'aa' * 32,
              timestamp: now.add(const Duration(hours: 6)),
            ),
          )
          .then((_) {
            expect(detector.status.signal, ClockSkewSignal.none);
          });
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
      senderPubkeyHex: 'ff' * 32,
      latitude: 1,
      longitude: 2,
    );
    expect(result.isSuccess, isTrue);
  });
}
