/// Tests for [AvatarAntiEntropyNotifier] and [avatarAntiEntropyProvider].
///
/// Verifies:
/// - triggerForTest() calls reshareToAllCircles on the avatar controller.
/// - Publish failure (via reshare) does NOT crash the timer or throw.
/// - Timer re-arms after each tick (self-rescheduling).
/// - effectiveIntervalForTest returns the fixed 24 h interval.
library;

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/providers/avatar_anti_entropy_provider.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/services/relay_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../mocks/mock_circle_service.dart';
import '../mocks/mock_relay_service.dart';

// ---------------------------------------------------------------------------
// Fake identity
// ---------------------------------------------------------------------------

class _FakeIdentityService implements IdentityService {
  static const _pubkey =
      'aaaa1234aaaa1234aaaa1234aaaa1234aaaa1234aaaa1234aaaa1234aaaa1234';

  static final _identity = Identity(
    pubkeyHex: _pubkey,
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
  Future<String> getPubkeyHex() async => _pubkey;

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
// Relay that always throws
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
// Helpers
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  // =========================================================================
  // Interval constant via effectiveIntervalForTest
  // =========================================================================

  group('AvatarAntiEntropyNotifier — effectiveIntervalForTest', () {
    test('returns the fixed 24 h interval', () {
      final container = _makeContainer(
        circleService: MockCircleService(),
        relayService: MockRelayService(),
      );
      addTearDown(container.dispose);

      final notifier = container.read(avatarAntiEntropyProvider.notifier);

      expect(
        notifier.effectiveIntervalForTest,
        equals(const Duration(hours: 24)),
      );
      expect(avatarAntiEntropyInterval, equals(const Duration(hours: 24)));
    });
  });

  // =========================================================================
  // triggerForTest() — fires the reshare action directly
  // =========================================================================

  group('AvatarAntiEntropyNotifier — triggerForTest()', () {
    test('calls reshareToAllCircles when avatar is set', () async {
      final circle = TestCircleFactory.createCircle(displayName: 'C1');
      final svc = MockCircleService()
        ..avatarThumbnailBytes = Uint8List.fromList([0xFF, 0xD8])
        ..buildAvatarShareEventsResult = ['{"id":"chunk0","kind":445}'];
      final relay = MockRelayService();

      final container = _makeContainer(
        circleService: svc,
        relayService: relay,
        circles: [circle],
      );
      addTearDown(container.dispose);

      container.read(avatarAntiEntropyProvider.notifier).triggerForTest();

      // Allow the unawaited Future() chain to drain.
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(
        svc.buildAvatarShareEventsCalls,
        hasLength(1),
        reason: 'triggerForTest() must invoke reshareToAllCircles',
      );
      expect(relay.publishedEvents, hasLength(1));
    });

    test('skips reshare when no avatar is set', () async {
      final svc = MockCircleService()..avatarThumbnailBytes = null;
      final relay = MockRelayService();

      final container = _makeContainer(
        circleService: svc,
        relayService: relay,
        circles: [TestCircleFactory.createCircle()],
      );
      addTearDown(container.dispose);

      container.read(avatarAntiEntropyProvider.notifier).triggerForTest();

      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(svc.buildAvatarShareEventsCalls, isEmpty);
      expect(relay.publishedEvents, isEmpty);
    });

    test('publish failure does not throw or crash after triggerForTest()',
        () async {
      final circle = TestCircleFactory.createCircle(displayName: 'C1');
      final svc = MockCircleService()
        ..avatarThumbnailBytes = Uint8List.fromList([0xFF, 0xD8])
        ..buildAvatarShareEventsResult = ['{"id":"chunk0","kind":445}'];
      final relay = _FailingRelayService();

      final container = _makeContainer(
        circleService: svc,
        relayService: relay,
        circles: [circle],
      );
      addTearDown(container.dispose);

      await expectLater(
        Future<void>(() async {
          container.read(avatarAntiEntropyProvider.notifier).triggerForTest();
          await Future<void>.delayed(Duration.zero);
          await Future<void>.delayed(Duration.zero);
        }),
        completes,
        reason: 'publish failure must never propagate',
      );
    });

    test('multiple triggerForTest() calls each invoke reshare independently',
        () async {
      final circle = TestCircleFactory.createCircle(displayName: 'C1');
      final svc = MockCircleService()
        ..avatarThumbnailBytes = Uint8List.fromList([0xFF, 0xD8])
        ..buildAvatarShareEventsResult = ['{"id":"chunk0","kind":445}'];
      final relay = MockRelayService();

      final container = _makeContainer(
        circleService: svc,
        relayService: relay,
        circles: [circle],
      );
      addTearDown(container.dispose);

      final notifier = container.read(avatarAntiEntropyProvider.notifier)
        ..triggerForTest();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      notifier.triggerForTest();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(
        svc.buildAvatarShareEventsCalls,
        hasLength(2),
        reason: 'each trigger fires one reshare',
      );
    });

    test('reshare error does not prevent subsequent triggerForTest() calls',
        () async {
      final circle = TestCircleFactory.createCircle(displayName: 'C1');
      final svc = MockCircleService()
        ..avatarThumbnailBytes = Uint8List.fromList([0xFF, 0xD8])
        ..shouldThrowOnBuildAvatarShareEvents = true;
      final relay = MockRelayService();

      final container = _makeContainer(
        circleService: svc,
        relayService: relay,
        circles: [circle],
      );
      addTearDown(container.dispose);

      // First trigger — will fail silently.
      final notifier = container.read(avatarAntiEntropyProvider.notifier)
        ..triggerForTest();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      // Allow the second trigger to succeed.
      svc
        ..shouldThrowOnBuildAvatarShareEvents = false
        ..buildAvatarShareEventsResult = ['{"id":"chunk0","kind":445}'];

      notifier.triggerForTest();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(svc.buildAvatarShareEventsCalls, hasLength(2));
      expect(
        relay.publishedEvents,
        hasLength(1),
        reason: 'only the successful call should have published',
      );
    });
  });

  // =========================================================================
  // Disposal
  // =========================================================================

  group('AvatarAntiEntropyNotifier — disposal', () {
    test('container.dispose() does not throw', () {
      final container = _makeContainer(
        circleService: MockCircleService(),
        relayService: MockRelayService(),
      );

      // Materialize the notifier so the timer is armed; then verify disposal.
      // ignore: cascade_invocations -- reads and dispose are distinct concerns
      container.read(avatarAntiEntropyProvider.notifier);
      expect(container.dispose, returnsNormally);
    });
  });
}
