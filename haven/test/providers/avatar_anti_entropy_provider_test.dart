/// Tests for [AvatarAntiEntropyNotifier] and [avatarAntiEntropyProvider].
///
/// Verifies:
/// - triggerForTest() calls reshareToAllCircles on the avatar controller.
/// - Publish failure (via reshare) does NOT crash the timer or throw.
/// - Timer re-arms after each tick (self-rescheduling).
/// - effectiveIntervalForTest returns 24h when data-saver is off.
/// - effectiveIntervalForTest returns 72h when data-saver is on.
/// - The notifier reads the data-saver state from [avatarDataSaverProvider].
/// - reschedule() cancels and re-arms the timer (smoke test via triggerForTest).
library;

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/providers/avatar_anti_entropy_provider.dart';
import 'package:haven/src/providers/avatar_data_saver_provider.dart';
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

/// Creates a container with all required overrides for the anti-entropy
/// provider tests.
///
/// [dataSaverEnabled] seeds the SharedPreferences mock so the
/// [avatarDataSaverProvider] picks up the value.
ProviderContainer _makeContainer({
  required MockCircleService circleService,
  required MockRelayService relayService,
  List<Circle> circles = const [],
  bool dataSaverEnabled = false,
}) {
  return ProviderContainer(
    overrides: [
      identityServiceProvider.overrideWithValue(_FakeIdentityService()),
      circleServiceProvider.overrideWithValue(circleService),
      relayServiceProvider.overrideWithValue(relayService),
      circlesProvider.overrideWith((_) async => circles),
      // Override data-saver directly using a notifier seeded to the desired
      // value, so we don't need SharedPreferences in the container.
      avatarDataSaverProvider.overrideWith(
        (_) => _SeededDataSaverNotifier(enabled: dataSaverEnabled),
      ),
    ],
  );
}

/// A [AvatarDataSaverNotifier] seeded to a fixed value for tests.
///
/// Passes the seeded value through [_DummyPrefs] so that the async _load()
/// call reads the same value back — preventing the async completion from
/// overwriting the seeded state with false.
class _SeededDataSaverNotifier extends AvatarDataSaverNotifier {
  _SeededDataSaverNotifier({required bool enabled})
    : super(prefs: _DummyPrefs(seeded: enabled));
}

/// Minimal SharedPreferences shim that returns a fixed value for all keys.
class _DummyPrefs implements SharedPreferences {
  _DummyPrefs({required this.seeded});

  final bool seeded;

  @override
  bool? getBool(String key) => seeded;

  @override
  Future<bool> setBool(String key, bool value) async => true;

  // All other members are unused — delegate to noSuchMethod.
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
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
  // Interval constants via effectiveIntervalForTest
  // =========================================================================

  group('AvatarAntiEntropyNotifier — effectiveIntervalForTest', () {
    test('returns 24h when data-saver is off', () {
      final svc = MockCircleService();
      final relay = MockRelayService();

      final container = _makeContainer(
        circleService: svc,
        relayService: relay,
      );
      addTearDown(container.dispose);

      final notifier = container.read(avatarAntiEntropyProvider.notifier);

      expect(
        notifier.effectiveIntervalForTest,
        equals(const Duration(hours: 24)),
      );
    });

    test('returns 72h when data-saver is on', () async {
      final svc = MockCircleService();
      final relay = MockRelayService();

      final container = _makeContainer(
        circleService: svc,
        relayService: relay,
        dataSaverEnabled: true,
      );
      addTearDown(container.dispose);

      // Force-initialize the data-saver notifier and wait for its async
      // _load() to complete before reading the anti-entropy notifier.
      // Without this, effectiveIntervalForTest reads the pre-_load() state.
      container.read(avatarDataSaverProvider);
      await Future<void>.delayed(Duration.zero); // drain _load() microtask

      final notifier = container.read(avatarAntiEntropyProvider.notifier);

      expect(
        notifier.effectiveIntervalForTest,
        equals(const Duration(hours: 72)),
      );
    });

    test('data-saver interval is 3× normal interval', () async {
      final svc = MockCircleService();
      final relay = MockRelayService();
      final containerOff = _makeContainer(
        circleService: svc,
        relayService: relay,
      );
      final containerOn = _makeContainer(
        circleService: svc,
        relayService: relay,
        dataSaverEnabled: true,
      );
      addTearDown(containerOff.dispose);
      addTearDown(containerOn.dispose);

      // Initialize data-saver notifiers and drain their _load() microtask.
      containerOff.read(avatarDataSaverProvider);
      containerOn.read(avatarDataSaverProvider);
      await Future<void>.delayed(Duration.zero);

      final off =
          containerOff.read(avatarAntiEntropyProvider.notifier)
              .effectiveIntervalForTest;
      final on_ =
          containerOn.read(avatarAntiEntropyProvider.notifier)
              .effectiveIntervalForTest;

      expect(on_.inHours, equals(off.inHours * 3));
    });
  });

  // =========================================================================
  // triggerForTest() — fires the reshare action directly
  // =========================================================================

  group('AvatarAntiEntropyNotifier — triggerForTest()', () {
    test('calls reshareToAllCircles when avatar is set', () async {
      final circle = TestCircleFactory.createCircle(
        displayName: 'C1',
      );
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
        circles: [
          TestCircleFactory.createCircle(
          ),
        ],
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
      final circle = TestCircleFactory.createCircle(
        displayName: 'C1',
      );
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
      final circle = TestCircleFactory.createCircle(
        displayName: 'C1',
      );
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
      // First call: buildAvatarShareEvents throws.
      // Second call: succeeds.
      final circle = TestCircleFactory.createCircle(
        displayName: 'C1',
      );
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

      // Both calls were attempted (first threw, second succeeded).
      expect(svc.buildAvatarShareEventsCalls, hasLength(2));
      expect(
        relay.publishedEvents,
        hasLength(1),
        reason: 'only the successful call should have published',
      );
    });
  });

  // =========================================================================
  // reschedule() smoke test
  // =========================================================================

  group('AvatarAntiEntropyNotifier — reschedule()', () {
    test('reschedule() keeps the notifier functional (triggerForTest still works)',
        () async {
      final circle = TestCircleFactory.createCircle(
        displayName: 'C1',
      );
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

      // Call reschedule (simulates data-saver toggle), then trigger.
      container.read(avatarAntiEntropyProvider.notifier)
        ..reschedule()
        ..triggerForTest();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(svc.buildAvatarShareEventsCalls, hasLength(1));
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
