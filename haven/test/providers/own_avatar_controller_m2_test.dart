/// Unit tests for OwnAvatarController M2 publish-on-change behavior.
///
/// Verifies:
/// - pickAndSet calls buildAvatarShareEvents for each accepted circle.
/// - pickAndSet skips non-accepted circles.
/// - remove calls buildAvatarClearEvent for each accepted circle.
/// - Relay failures during publish do NOT propagate to the UI.
/// - Publish is best-effort: buildAvatarShareEvents failure is swallowed.
/// - DEC-4: intervalSecs = kLocationPublishMaxInterval + kTtlNetworkBufferSeconds.
library;

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/constants/location.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/own_avatar_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/services/relay_service.dart';

import '../mocks/mock_circle_service.dart';
import '../mocks/mock_relay_service.dart';

// ---------------------------------------------------------------------------
// Relay service that throws on publishEvent.
// ---------------------------------------------------------------------------

class _FailingRelayService extends MockRelayService {
  @override
  Future<PublishResult> publishEvent({
    required String eventJson,
    required List<String> relays,
  }) async {
    throw const RelayServiceException('Relay unreachable');
  }
}

// ---------------------------------------------------------------------------
// Fake identity service (pubkey only).
// ---------------------------------------------------------------------------

class _FakeIdentityService implements IdentityService {
  static final _identity = Identity(
    pubkeyHex:
        'aaaa1234aaaa1234aaaa1234aaaa1234aaaa1234aaaa1234aaaa1234aaaa1234',
    npub: 'npub1test',
    createdAt: DateTime(2025),
  );

  @override
  Future<bool> hasIdentity() async => true;

  @override
  Future<Identity?> getIdentity() async => _identity;

  @override
  Future<Identity> createIdentity() => throw UnimplementedError();

  @override
  Future<Identity> importFromNsec(String nsec) => throw UnimplementedError();

  @override
  Future<String> exportNsec() => throw UnimplementedError();

  @override
  Future<String> sign(Uint8List messageHash) => throw UnimplementedError();

  @override
  Future<String> getPubkeyHex() async => _identity.pubkeyHex;

  @override
  Future<List<int>> getSecretBytes() => throw UnimplementedError();

  @override
  Future<void> deleteIdentity() async {}

  @override
  Future<String?> getDisplayName() async => null;

  @override
  Future<void> setDisplayName(String? name) async {}

  @override
  Future<void> clearCache() async {}
}

// ---------------------------------------------------------------------------
// Helpers.
// ---------------------------------------------------------------------------

/// Builds a minimal accepted [Circle] with no members.
Circle _acceptedCircle({String name = 'TestCircle'}) {
  return TestCircleFactory.createCircle(
    displayName: name,
  );
}

/// Builds a pending [Circle] (should be skipped by publish logic).
Circle _pendingCircle() {
  return TestCircleFactory.createCircle(
    displayName: 'Pending',
    membershipStatus: MembershipStatus.pending,
  );
}

/// Creates a ProviderContainer with common overrides.
ProviderContainer _makeContainer({
  required MockCircleService circleService,
  required MockRelayService relayService,
  List<Circle> circles = const [],
}) {
  return ProviderContainer(
    overrides: [
      identityServiceProvider.overrideWithValue(_FakeIdentityService()),
      circleServiceProvider.overrideWithValue(circleService),
      relayServiceProvider.overrideWithValue(relayService),
      circlesProvider.overrideWith((_) async => circles),
    ],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final kExpectedIntervalSecs =
      kLocationPublishMaxInterval.inSeconds + kTtlNetworkBufferSeconds;

  final testBytes = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0]);

  group('OwnAvatarController — M2 publish on pickAndSet', () {
    test(
      'pickAndSet calls buildAvatarShareEvents for each accepted circle',
      () async {
        final circle1 = _acceptedCircle(name: 'Circle1');
        final circle2 = _acceptedCircle(name: 'Circle2');
        final svc = MockCircleService()
          ..buildAvatarShareEventsResult = ['{"id":"evt1"}'];
        final relay = MockRelayService();

        final container = _makeContainer(
          circleService: svc,
          relayService: relay,
          circles: [circle1, circle2],
        );
        addTearDown(container.dispose);

        await container
            .read(ownAvatarControllerProvider.notifier)
            .pickAndSet(testBytes);

        // Allow the unawaited Future() timer to drain.
        await Future<void>.delayed(Duration.zero);

        expect(svc.buildAvatarShareEventsCalls, hasLength(2));
        // Both relay publishes fired (one event JSON per circle).
        expect(relay.publishedEvents, hasLength(2));
      },
    );

    test(
      'pickAndSet skips non-accepted (pending) circles',
      () async {
        final pending = _pendingCircle();
        final accepted = _acceptedCircle();
        final svc = MockCircleService()
          ..buildAvatarShareEventsResult = ['{"id":"evt1"}'];
        final relay = MockRelayService();

        final container = _makeContainer(
          circleService: svc,
          relayService: relay,
          circles: [pending, accepted],
        );
        addTearDown(container.dispose);

        await container
            .read(ownAvatarControllerProvider.notifier)
            .pickAndSet(testBytes);
        await Future<void>.delayed(Duration.zero);

        // Only the accepted circle should have been used.
        expect(svc.buildAvatarShareEventsCalls, hasLength(1));
        expect(relay.publishedEvents, hasLength(1));
      },
    );

    test(
      'pickAndSet does not call publish when no circles exist',
      () async {
        final svc = MockCircleService();
        final relay = MockRelayService();

        final container = _makeContainer(
          circleService: svc,
          relayService: relay,
          circles: [],
        );
        addTearDown(container.dispose);

        await container
            .read(ownAvatarControllerProvider.notifier)
            .pickAndSet(testBytes);
        await Future<void>.delayed(Duration.zero);

        expect(svc.buildAvatarShareEventsCalls, isEmpty);
        expect(relay.publishedEvents, isEmpty);
      },
    );

    test(
      'pickAndSet passes DEC-4 intervalSecs '
      '(kLocationPublishMaxInterval + kTtlNetworkBufferSeconds)',
      () async {
        final svc = MockCircleService()
          ..buildAvatarShareEventsResult = ['{"id":"evt"}'];
        final relay = MockRelayService();

        final container = _makeContainer(
          circleService: svc,
          relayService: relay,
          circles: [_acceptedCircle()],
        );
        addTearDown(container.dispose);

        await container
            .read(ownAvatarControllerProvider.notifier)
            .pickAndSet(testBytes);
        await Future<void>.delayed(Duration.zero);

        expect(svc.buildAvatarShareEventsCalls, hasLength(1));
        final captured =
            svc.buildAvatarShareEventsCalls.first['updateIntervalSecs'];
        expect(captured, equals(kExpectedIntervalSecs));
        expect(captured, equals(198));
      },
    );

    test(
      'pickAndSet relay publish failure does not throw to the UI',
      () async {
        final svc = MockCircleService()
          ..buildAvatarShareEventsResult = ['{"id":"evt"}'];
        final relay = _FailingRelayService();

        final container = _makeContainer(
          circleService: svc,
          relayService: relay,
          circles: [_acceptedCircle()],
        );
        addTearDown(container.dispose);

        // Must complete without error — relay failures are best-effort.
        await expectLater(
          container
              .read(ownAvatarControllerProvider.notifier)
              .pickAndSet(testBytes),
          completes,
        );
        await Future<void>.delayed(Duration.zero);
      },
    );

    test(
      'pickAndSet buildAvatarShareEvents failure does not throw to the UI',
      () async {
        final svc = MockCircleService()
          ..shouldThrowOnBuildAvatarShareEvents = true;
        final relay = MockRelayService();

        final container = _makeContainer(
          circleService: svc,
          relayService: relay,
          circles: [_acceptedCircle()],
        );
        addTearDown(container.dispose);

        await expectLater(
          container
              .read(ownAvatarControllerProvider.notifier)
              .pickAndSet(testBytes),
          completes,
        );
        await Future<void>.delayed(Duration.zero);
        // No events published.
        expect(relay.publishedEvents, isEmpty);
      },
    );
  });

  group('OwnAvatarController — M2 publish on remove', () {
    test(
      'remove calls buildAvatarClearEvent for each accepted circle',
      () async {
        final circle1 = _acceptedCircle(name: 'Circle1');
        final circle2 = _acceptedCircle(name: 'Circle2');
        final svc = MockCircleService();
        final relay = MockRelayService();

        final container = _makeContainer(
          circleService: svc,
          relayService: relay,
          circles: [circle1, circle2],
        );
        addTearDown(container.dispose);

        await container
            .read(ownAvatarControllerProvider.notifier)
            .remove();
        await Future<void>.delayed(Duration.zero);

        expect(svc.buildAvatarClearEventCalls, hasLength(2));
        expect(relay.publishedEvents, hasLength(2));
      },
    );

    test(
      'remove: clear events are published BEFORE clearMyAvatar is called '
      '(HIGH-1 ordering invariant)',
      () async {
        final accepted = _acceptedCircle(name: 'Circle1');
        final svc = MockCircleService();
        final relay = MockRelayService();

        final container = _makeContainer(
          circleService: svc,
          relayService: relay,
          circles: [accepted],
        );
        addTearDown(container.dispose);

        await container
            .read(ownAvatarControllerProvider.notifier)
            .remove();
        await Future<void>.delayed(Duration.zero);

        // The mock records all method calls in [methodCalls] in the order
        // they are invoked. Assert that 'buildAvatarClearEvent' appears
        // before 'clearMyAvatar' so we know Rust still holds the current
        // version when the tombstone is built.
        final calls = svc.methodCalls;
        final buildIdx = calls.indexOf('buildAvatarClearEvent');
        final clearIdx = calls.indexOf('clearMyAvatar');
        expect(
          buildIdx,
          isNot(equals(-1)),
          reason: 'buildAvatarClearEvent must be called',
        );
        expect(
          clearIdx,
          isNot(equals(-1)),
          reason: 'clearMyAvatar must be called',
        );
        expect(
          buildIdx < clearIdx,
          isTrue,
          reason:
              'buildAvatarClearEvent must be called BEFORE clearMyAvatar '
              'so Rust can derive the tombstone version from the stored '
              'own-avatar version + 1',
        );
      },
    );

    test(
      'remove: clearMyAvatar is called even when publish relay fails '
      '(relay failure does not skip local clear)',
      () async {
        final svc = MockCircleService();
        final relay = _FailingRelayService();

        final container = _makeContainer(
          circleService: svc,
          relayService: relay,
          circles: [_acceptedCircle()],
        );
        addTearDown(container.dispose);

        await container
            .read(ownAvatarControllerProvider.notifier)
            .remove();
        await Future<void>.delayed(Duration.zero);

        // Even though relay.publishEvent throws, clearMyAvatar must still run.
        expect(
          svc.clearMyAvatarCalled,
          isTrue,
          reason: 'relay failure must not skip the local avatar clear',
        );
      },
    );

    test(
      'remove skips non-accepted (pending) circles',
      () async {
        final pending = _pendingCircle();
        final accepted = _acceptedCircle();
        final svc = MockCircleService();
        final relay = MockRelayService();

        final container = _makeContainer(
          circleService: svc,
          relayService: relay,
          circles: [pending, accepted],
        );
        addTearDown(container.dispose);

        await container
            .read(ownAvatarControllerProvider.notifier)
            .remove();
        await Future<void>.delayed(Duration.zero);

        expect(svc.buildAvatarClearEventCalls, hasLength(1));
        expect(relay.publishedEvents, hasLength(1));
      },
    );

    test(
      'remove relay failure does not throw to the UI',
      () async {
        final svc = MockCircleService();
        final relay = _FailingRelayService();

        final container = _makeContainer(
          circleService: svc,
          relayService: relay,
          circles: [_acceptedCircle()],
        );
        addTearDown(container.dispose);

        await expectLater(
          container.read(ownAvatarControllerProvider.notifier).remove(),
          completes,
        );
        await Future<void>.delayed(Duration.zero);
      },
    );

    test(
      'remove buildAvatarClearEvent failure does not throw to the UI',
      () async {
        final svc = MockCircleService()
          ..shouldThrowOnBuildAvatarClearEvent = true;
        final relay = MockRelayService();

        final container = _makeContainer(
          circleService: svc,
          relayService: relay,
          circles: [_acceptedCircle()],
        );
        addTearDown(container.dispose);

        await expectLater(
          container.read(ownAvatarControllerProvider.notifier).remove(),
          completes,
        );
        await Future<void>.delayed(Duration.zero);
        expect(relay.publishedEvents, isEmpty);
      },
    );
  });
}
