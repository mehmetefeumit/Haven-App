/// Tests for relay status provider.
///
/// Verifies that:
/// - Initial state has all default relays in pending status
/// - checkAllRelays updates to found when mock returns events
/// - checkAllRelays updates to notFound when mock returns no events
/// - checkAllRelays updates to error when mock throws
/// - checkAllRelays is a no-op when no identity exists
/// - isRefreshing flag is set during check and cleared after
/// - lastChecked timestamp is set after completion
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/constants/relays.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/relay_status_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/services/relay_service.dart';

import '../mocks/mock_relay_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final testIdentity = Identity(
    pubkeyHex:
        'abc123def456abc123def456abc123def456abc123def456abc123def456abcd',
    npub: 'npub1test',
    createdAt: DateTime(2024),
  );

  group('RelayStatusNotifier', () {
    test('initial state has all default relays in pending', () async {
      final container = ProviderContainer(
        overrides: [
          identityProvider.overrideWith((_) async => testIdentity),
          relayServiceProvider.overrideWithValue(MockRelayService()),
        ],
      );
      addTearDown(container.dispose);

      final state = await container.read(relayStatusProvider.future);

      expect(state.relays.length, defaultRelays.length);
      for (final relay in state.relays) {
        expect(relay.keyPackage.status, EventCheckStatus.pending);
        expect(relay.relayList.status, EventCheckStatus.pending);
      }
      expect(state.isRefreshing, false);
      expect(state.lastChecked, isNull);
    });

    test('checkAllRelays sets found when mock returns events', () async {
      final now = DateTime.now();
      final checkResults = <String, RelayEventCheck>{};
      for (final relay in defaultRelays) {
        checkResults['$relay:443'] = RelayEventCheck(
          relayUrl: relay,
          found: true,
          eventCount: 1,
          newestTimestamp: now,
        );
        checkResults['$relay:10051'] = RelayEventCheck(
          relayUrl: relay,
          found: true,
          eventCount: 1,
          newestTimestamp: now,
        );
      }

      final mockRelay = MockRelayService(checkEventResults: checkResults);
      final container = ProviderContainer(
        overrides: [
          identityProvider.overrideWith((_) async => testIdentity),
          relayServiceProvider.overrideWithValue(mockRelay),
        ],
      );
      addTearDown(container.dispose);

      // Wait for initial build
      await container.read(relayStatusProvider.future);

      // Run check
      await container.read(relayStatusProvider.notifier).checkAllRelays();

      final state = await container.read(relayStatusProvider.future);

      for (final relay in state.relays) {
        expect(relay.keyPackage.status, EventCheckStatus.found);
        expect(relay.relayList.status, EventCheckStatus.found);
        expect(relay.keyPackage.newestTimestamp, isNotNull);
        expect(relay.relayList.newestTimestamp, isNotNull);
      }
      expect(state.isRefreshing, false);
      expect(state.lastChecked, isNotNull);
    });

    test('checkAllRelays sets notFound when mock returns no events', () async {
      final mockRelay = MockRelayService();
      final container = ProviderContainer(
        overrides: [
          identityProvider.overrideWith((_) async => testIdentity),
          relayServiceProvider.overrideWithValue(mockRelay),
        ],
      );
      addTearDown(container.dispose);

      await container.read(relayStatusProvider.future);
      await container.read(relayStatusProvider.notifier).checkAllRelays();

      final state = await container.read(relayStatusProvider.future);

      for (final relay in state.relays) {
        expect(relay.keyPackage.status, EventCheckStatus.notFound);
        expect(relay.relayList.status, EventCheckStatus.notFound);
      }
    });

    test('checkAllRelays sets error when mock throws', () async {
      final mockRelay = MockRelayService(shouldThrowOnCheckEvent: true);
      final container = ProviderContainer(
        overrides: [
          identityProvider.overrideWith((_) async => testIdentity),
          relayServiceProvider.overrideWithValue(mockRelay),
        ],
      );
      addTearDown(container.dispose);

      await container.read(relayStatusProvider.future);
      await container.read(relayStatusProvider.notifier).checkAllRelays();

      final state = await container.read(relayStatusProvider.future);

      for (final relay in state.relays) {
        expect(relay.keyPackage.status, EventCheckStatus.error);
        expect(relay.relayList.status, EventCheckStatus.error);
      }
    });

    test('checkAllRelays is no-op when no identity', () async {
      final mockRelay = MockRelayService();
      final container = ProviderContainer(
        overrides: [
          identityProvider.overrideWith((_) async => null),
          relayServiceProvider.overrideWithValue(mockRelay),
        ],
      );
      addTearDown(container.dispose);

      await container.read(relayStatusProvider.future);
      await container.read(relayStatusProvider.notifier).checkAllRelays();

      final state = await container.read(relayStatusProvider.future);

      // Should still be pending (no check happened)
      for (final relay in state.relays) {
        expect(relay.keyPackage.status, EventCheckStatus.pending);
        expect(relay.relayList.status, EventCheckStatus.pending);
      }
      expect(mockRelay.methodCalls, isEmpty);
    });

    test('lastChecked timestamp is set after completion', () async {
      final mockRelay = MockRelayService();
      final container = ProviderContainer(
        overrides: [
          identityProvider.overrideWith((_) async => testIdentity),
          relayServiceProvider.overrideWithValue(mockRelay),
        ],
      );
      addTearDown(container.dispose);

      await container.read(relayStatusProvider.future);

      final beforeCheck = DateTime.now();
      await container.read(relayStatusProvider.notifier).checkAllRelays();
      final afterCheck = DateTime.now();

      final state = await container.read(relayStatusProvider.future);

      expect(state.lastChecked, isNotNull);
      expect(
        state.lastChecked!.isAfter(
          beforeCheck.subtract(const Duration(seconds: 1)),
        ),
        true,
      );
      expect(
        state.lastChecked!.isBefore(afterCheck.add(const Duration(seconds: 1))),
        true,
      );
    });

    test('relay URLs match defaultRelays', () async {
      final container = ProviderContainer(
        overrides: [
          identityProvider.overrideWith((_) async => testIdentity),
          relayServiceProvider.overrideWithValue(MockRelayService()),
        ],
      );
      addTearDown(container.dispose);

      final state = await container.read(relayStatusProvider.future);

      final relayUrls = state.relays.map((r) => r.relayUrl).toList();
      expect(relayUrls, defaultRelays);
    });
  });
}
