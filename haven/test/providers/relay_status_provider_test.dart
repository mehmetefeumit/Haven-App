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

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/constants/relays.dart';
import 'package:haven/src/models/relay_ring_slot.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/relay_preferences_provider.dart';
import 'package:haven/src/providers/relay_status_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/services/relay_preferences_service.dart';
import 'package:haven/src/services/relay_service.dart';

import '../mocks/mock_relay_preferences_service.dart';
import '../mocks/mock_relay_service.dart';

/// Returns a relay-prefs override seeded so the union builder finds at
/// least one relay per category. Falls back to `fallbackDefaultRelays`
/// for the actual content so existing test assertions against
/// `defaultRelays.length` still hold.
Override _relayPrefsOverride() {
  return relayPreferencesServiceProvider.overrideWith(
    (ref) async => MockRelayPreferencesService(
      initialRelays: {
        RelayCategory.inbox: List<String>.from(fallbackDefaultRelays),
        RelayCategory.keyPackage: List<String>.from(fallbackDefaultRelays),
      },
    ),
  );
}

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
          _relayPrefsOverride(),
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

    test(
      'shows exactly the user-configured relays — never the public defaults',
      () async {
        // A privacy-conscious user whose ONLY relay is a private one. The
        // status page must show exactly that relay and NEVER re-introduce the
        // public defaults — doing so would mean the old defaults-union has
        // regressed into the status display. (The seeded-defaults test above
        // cannot catch that, since its user list already equals the defaults.)
        final container = ProviderContainer(
          overrides: [
            identityProvider.overrideWith((_) async => testIdentity),
            relayServiceProvider.overrideWithValue(MockRelayService()),
            relayPreferencesServiceProvider.overrideWith(
              (ref) async => MockRelayPreferencesService(
                initialRelays: const {
                  RelayCategory.inbox: ['wss://private.example.com'],
                  RelayCategory.keyPackage: ['wss://private.example.com'],
                },
              ),
            ),
          ],
        );
        addTearDown(container.dispose);

        final state = await container.read(relayStatusProvider.future);

        final urls = state.relays.map((r) => r.relayUrl).toList();
        expect(urls, ['wss://private.example.com']);
        for (final d in fallbackDefaultRelays) {
          expect(urls, isNot(contains(d)));
        }
      },
    );

    test('checkAllRelays sets found when mock returns events', () async {
      final now = DateTime.now();
      final checkResults = <String, RelayEventCheck>{};
      for (final relay in defaultRelays) {
        checkResults['$relay:30443'] = RelayEventCheck(
          relayUrl: relay,
          found: true,
          eventCount: 1,
          newestTimestamp: now,
        );
        checkResults['$relay:10002'] = RelayEventCheck(
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
          _relayPrefsOverride(),
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
          _relayPrefsOverride(),
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
          _relayPrefsOverride(),
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
          _relayPrefsOverride(),
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
          _relayPrefsOverride(),
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
          _relayPrefsOverride(),
        ],
      );
      addTearDown(container.dispose);

      final state = await container.read(relayStatusProvider.future);

      final relayUrls = state.relays.map((r) => r.relayUrl).toList();
      expect(relayUrls, defaultRelays);
    });
  });

  group('RelayStatusState.ringSlots', () {
    KindCheckResult kind(EventCheckStatus s) => KindCheckResult(status: s);
    RelayStatusState stateWith(RelayEventStatus relay) =>
        RelayStatusState(relays: [relay]);

    test('an unchecked relay is pending', () {
      expect(stateWith(const RelayEventStatus(relayUrl: 'wss://a')).ringSlots, [
        RelayRingSlotState.pending,
      ]);
    });

    test('any kind still checking -> checking', () {
      expect(
        stateWith(
          RelayEventStatus(
            relayUrl: 'wss://a',
            keyPackage: kind(EventCheckStatus.found),
            relayList: kind(EventCheckStatus.checking),
          ),
        ).ringSlots,
        [RelayRingSlotState.checking],
      );
    });

    test('any kind found (and none checking) -> ok', () {
      expect(
        stateWith(
          RelayEventStatus(
            relayUrl: 'wss://a',
            keyPackage: kind(EventCheckStatus.found),
            relayList: kind(EventCheckStatus.notFound),
            inboxRelayList: kind(EventCheckStatus.notFound),
          ),
        ).ringSlots,
        [RelayRingSlotState.ok],
      );
    });

    test('all kinds notFound/error -> error', () {
      expect(
        stateWith(
          RelayEventStatus(
            relayUrl: 'wss://a',
            keyPackage: kind(EventCheckStatus.notFound),
            relayList: kind(EventCheckStatus.error),
            inboxRelayList: kind(EventCheckStatus.notFound),
          ),
        ).ringSlots,
        [RelayRingSlotState.error],
      );
    });

    test('fills in per relay as each one resolves', () async {
      // Relay a's checks resolve immediately (found -> ok); relay b is gated,
      // so the ring shows [ok, checking] mid-flight, proving the per-relay
      // writes land incrementally rather than all at once on completion.
      final now = DateTime.now();
      final checkResults = <String, RelayEventCheck>{
        for (final k in [30443, 10002, 10050])
          'wss://a:$k': RelayEventCheck(
            relayUrl: 'wss://a',
            found: true,
            eventCount: 1,
            newestTimestamp: now,
          ),
      };
      final mock = MockRelayService(checkEventResults: checkResults);
      mock.checkEventGates['wss://b'] = Completer<void>();

      final container = ProviderContainer(
        overrides: [
          identityProvider.overrideWith((_) async => testIdentity),
          relayServiceProvider.overrideWithValue(mock),
          relayPreferencesServiceProvider.overrideWith(
            (ref) async => MockRelayPreferencesService(
              initialRelays: const {
                RelayCategory.inbox: ['wss://a'],
                RelayCategory.keyPackage: ['wss://b'],
              },
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      await container.read(relayStatusProvider.future);
      final check = container
          .read(relayStatusProvider.notifier)
          .checkAllRelays();

      // a resolves while b stays gated -> [ok, checking].
      await _pumpUntil(
        () =>
            container.read(relayStatusProvider).value?.ringSlots.first ==
            RelayRingSlotState.ok,
      );
      expect(container.read(relayStatusProvider).value!.ringSlots, const [
        RelayRingSlotState.ok,
        RelayRingSlotState.checking,
      ]);

      mock.checkEventGates['wss://b']!.complete();
      await check;

      expect(container.read(relayStatusProvider).value!.ringSlots, const [
        RelayRingSlotState.ok,
        RelayRingSlotState.error,
      ]);
    });
  });
}

/// Spins the microtask/timer queue until [condition] holds (or a tick cap is
/// reached), so a test can observe an intermediate in-flight state.
Future<void> _pumpUntil(bool Function() condition, {int maxTicks = 100}) async {
  for (var i = 0; i < maxTicks && !condition(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
  if (!condition()) {
    fail('_pumpUntil: condition not satisfied after $maxTicks ticks');
  }
}
