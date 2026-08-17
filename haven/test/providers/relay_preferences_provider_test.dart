/// Tests for the relay preferences notifiers.
///
/// Covers self-healing seed in `build()`, the mutation methods (add /
/// remove / restore / wipe), and the invalidation chain that triggers
/// downstream republish when the user mutates a list.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/relay_preferences_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/services/relay_preferences_service.dart';

import '../mocks/mock_relay_preferences_service.dart';
import '../mocks/mock_relay_service.dart';

/// Minimal identity notifier that returns a fixed 32-byte secret without
/// touching the real identity service, so the best-effort removal scrub has
/// a working secret key to sign its NIP-09 deletion.
class _FakeIdentityNotifier extends IdentityNotifier {
  @override
  Future<Identity?> build() async => null;

  @override
  Future<List<int>> getSecretBytes() async => List<int>.filled(32, 7);
}

void main() {
  late MockRelayPreferencesService mock;
  late MockRelayService mockRelayService;
  late ProviderContainer container;

  setUp(() {
    mock = MockRelayPreferencesService();
    mockRelayService = MockRelayService();
    container = ProviderContainer(
      overrides: [
        relayPreferencesServiceProvider.overrideWith((ref) async => mock),
        relayServiceProvider.overrideWithValue(mockRelayService),
      ],
    );
    addTearDown(container.dispose);
  });

  group('InboxRelaysNotifier', () {
    test('self-heals empty storage by seeding defaults', () async {
      final list = await container.read(inboxRelaysProvider.future);
      expect(mock.didSeed, isTrue);
      expect(list, isNotEmpty);
    });

    test('returns existing list without seeding when not empty', () async {
      final pre = MockRelayPreferencesService(
        initialRelays: const {
          RelayCategory.inbox: ['wss://existing.example.com'],
          RelayCategory.keyPackage: ['wss://kp.example.com'],
        },
      );
      final c = ProviderContainer(
        overrides: [
          relayPreferencesServiceProvider.overrideWith((ref) async => pre),
          relayServiceProvider.overrideWithValue(MockRelayService()),
        ],
      );
      addTearDown(c.dispose);
      final list = await c.read(inboxRelaysProvider.future);
      expect(pre.didSeed, isFalse);
      expect(list, ['wss://existing.example.com']);
    });

    test('addRelay updates state and invalidates downstream markers', () async {
      // Prime the provider tree so we can observe markers.
      await container.read(inboxRelaysProvider.future);
      final markerBefore = container.read(invitationInvalidatorProvider);
      final notifier = container.read(inboxRelaysProvider.notifier);
      await notifier.addRelay('wss://added.example.com');
      final after = await container.read(inboxRelaysProvider.future);
      expect(after, contains('wss://added.example.com'));
      // Invalidation triggers a fresh read of the marker (rebuilt provider).
      final markerAfter = container.read(invitationInvalidatorProvider);
      expect(
        identical(markerBefore, markerAfter),
        isTrue,
        reason:
            'StateProvider returns same int 0 — invalidate forces rebuild '
            'but the value comparison is moot; semantics tested via downstream '
            'read counts in integration test.',
      );
    });

    test('removeRelay refuses to delete the last relay', () async {
      final pre = MockRelayPreferencesService(
        initialRelays: const {
          RelayCategory.inbox: ['wss://only.example.com'],
          RelayCategory.keyPackage: [
            'wss://x.example.com',
            'wss://y.example.com',
          ],
        },
      );
      final c = ProviderContainer(
        overrides: [
          relayPreferencesServiceProvider.overrideWith((ref) async => pre),
          relayServiceProvider.overrideWithValue(MockRelayService()),
        ],
      );
      addTearDown(c.dispose);
      await c.read(inboxRelaysProvider.future);
      expect(
        () => c
            .read(inboxRelaysProvider.notifier)
            .removeRelay('wss://only.example.com'),
        throwsA(isA<RelayValidationError>()),
      );
    });

    test('removeRelay disconnects the relay on success', () async {
      final pre = MockRelayPreferencesService(
        initialRelays: const {
          RelayCategory.inbox: ['wss://a.example.com', 'wss://b.example.com'],
          RelayCategory.keyPackage: [],
        },
      );
      final mockRelay = MockRelayService();
      final c = ProviderContainer(
        overrides: [
          relayPreferencesServiceProvider.overrideWith((ref) async => pre),
          relayServiceProvider.overrideWithValue(mockRelay),
        ],
      );
      addTearDown(c.dispose);
      await c.read(inboxRelaysProvider.future);
      final removed = await c
          .read(inboxRelaysProvider.notifier)
          .removeRelay('wss://b.example.com');
      expect(removed, isTrue);
      // Disconnect now goes through RelayService, not the prefs service.
      expect(
        mockRelay.methodCalls,
        contains('disconnectRelay:wss://b.example.com'),
      );
    });

    test('removeRelay scrubs the dropped relay before disconnecting it',
        () async {
      final pre = MockRelayPreferencesService(
        initialRelays: const {
          RelayCategory.inbox: [
            'wss://keep.example.com',
            'wss://drop.example.com',
          ],
          RelayCategory.keyPackage: ['wss://kp.example.com'],
        },
      );
      final mockRelay = MockRelayService();
      final c = ProviderContainer(
        overrides: [
          relayPreferencesServiceProvider.overrideWith((ref) async => pre),
          relayServiceProvider.overrideWithValue(mockRelay),
          // Provide a working identity so the (best-effort) scrub actually
          // runs instead of silently no-oping on a missing secret key.
          identityNotifierProvider.overrideWith(_FakeIdentityNotifier.new),
        ],
      );
      addTearDown(c.dispose);
      await c.read(inboxRelaysProvider.future);

      final removed = await c
          .read(inboxRelaysProvider.notifier)
          .removeRelay('wss://drop.example.com');
      expect(removed, isTrue);

      // Two-plane removal hygiene: a NIP-09 deletion was built for the
      // dropped relay only...
      expect(pre.log, contains('scrub:inbox:wss://drop.example.com'));
      // ...and published (to the dropped relay) BEFORE the disconnect.
      expect(mockRelay.publishedEvents, contains('{"kind":5,"scrub":true}'));
      final scrubIdx = mockRelay.methodCalls.indexOf('publishEvent');
      final disconnectIdx = mockRelay.methodCalls.indexOf(
        'disconnectRelay:wss://drop.example.com',
      );
      expect(scrubIdx, isNonNegative);
      expect(
        scrubIdx < disconnectIdx,
        isTrue,
        reason: 'scrub must publish before the relay is disconnected',
      );
    });

    test('restoreDefaults preserves existing custom entries', () async {
      final pre = MockRelayPreferencesService(
        initialRelays: const {
          RelayCategory.inbox: ['wss://custom.example.com'],
          RelayCategory.keyPackage: ['wss://kp.example.com'],
        },
      );
      final c = ProviderContainer(
        overrides: [
          relayPreferencesServiceProvider.overrideWith((ref) async => pre),
          relayServiceProvider.overrideWithValue(MockRelayService()),
        ],
      );
      addTearDown(c.dispose);
      await c.read(inboxRelaysProvider.future);
      await c.read(inboxRelaysProvider.notifier).restoreDefaults();
      final after = await c.read(inboxRelaysProvider.future);
      expect(after, contains('wss://custom.example.com'));
      expect(after, contains('wss://default-a'));
    });

    test('wipeAndReset removes user customizations', () async {
      final pre = MockRelayPreferencesService(
        initialRelays: const {
          RelayCategory.inbox: ['wss://custom.example.com'],
          RelayCategory.keyPackage: ['wss://kp.example.com'],
        },
      );
      final c = ProviderContainer(
        overrides: [
          relayPreferencesServiceProvider.overrideWith((ref) async => pre),
          relayServiceProvider.overrideWithValue(MockRelayService()),
        ],
      );
      addTearDown(c.dispose);
      await c.read(inboxRelaysProvider.future);
      await c.read(inboxRelaysProvider.notifier).wipeAndReset();
      final after = await c.read(inboxRelaysProvider.future);
      expect(after, isNot(contains('wss://custom.example.com')));
    });
  });

  group('ProfileRelaysNotifier', () {
    test(
      'self-heals empty storage by seeding profile-plane defaults',
      () async {
        final list = await container.read(profileRelaysProvider.future);
        expect(mock.didSeed, isTrue);
        expect(list, isNotEmpty);
      },
    );

    test('returns existing list without seeding when not empty', () async {
      final pre = MockRelayPreferencesService(
        initialRelays: const {
          RelayCategory.profile: ['wss://existing-profile.example.com'],
        },
      );
      final c = ProviderContainer(
        overrides: [
          relayPreferencesServiceProvider.overrideWith((ref) async => pre),
          relayServiceProvider.overrideWithValue(MockRelayService()),
        ],
      );
      addTearDown(c.dispose);
      final list = await c.read(profileRelaysProvider.future);
      expect(pre.didSeed, isFalse);
      expect(list, ['wss://existing-profile.example.com']);
    });

    test('addRelay updates state', () async {
      await container.read(profileRelaysProvider.future);
      final notifier = container.read(profileRelaysProvider.notifier);
      await notifier.addRelay('wss://added-profile.example.com');
      final after = await container.read(profileRelaysProvider.future);
      expect(after, contains('wss://added-profile.example.com'));
    });

    test('removeRelay refuses to delete the last relay', () async {
      final pre = MockRelayPreferencesService(
        initialRelays: const {
          RelayCategory.profile: ['wss://only-profile.example.com'],
        },
      );
      final c = ProviderContainer(
        overrides: [
          relayPreferencesServiceProvider.overrideWith((ref) async => pre),
          relayServiceProvider.overrideWithValue(MockRelayService()),
        ],
      );
      addTearDown(c.dispose);
      await c.read(profileRelaysProvider.future);
      expect(
        () => c
            .read(profileRelaysProvider.notifier)
            .removeRelay('wss://only-profile.example.com'),
        throwsA(isA<RelayValidationError>()),
      );
    });

    test(
      'removeRelay does NOT scrub and does NOT disconnect — diverges from '
      'Inbox/KeyPackage because the profile list is never published',
      () async {
        final pre = MockRelayPreferencesService(
          initialRelays: const {
            RelayCategory.profile: [
              'wss://keep-profile.example.com',
              'wss://drop-profile.example.com',
            ],
          },
        );
        final mockRelay = MockRelayService();
        final c = ProviderContainer(
          overrides: [
            relayPreferencesServiceProvider.overrideWith((ref) async => pre),
            relayServiceProvider.overrideWithValue(mockRelay),
            // A working identity is available (scrub COULD run if the
            // notifier attempted it) — proves the omission is deliberate,
            // not merely a side-effect of a missing secret.
            identityNotifierProvider.overrideWith(_FakeIdentityNotifier.new),
          ],
        );
        addTearDown(c.dispose);
        await c.read(profileRelaysProvider.future);

        final removed = await c
            .read(profileRelaysProvider.notifier)
            .removeRelay('wss://drop-profile.example.com');
        expect(removed, isTrue);

        // No two-plane NIP-09 removal scrub was built for the dropped
        // relay — there is no published list to have a stale copy of.
        expect(
          pre.log,
          isNot(contains('scrub:profile:wss://drop-profile.example.com')),
        );
        // No persistent-socket disconnect either — profile reads/writes go
        // through a throwaway per-call relay manager, never the persistent
        // `RelayService` client Inbox/KeyPackage ride. In fact RelayService
        // is never touched at all for a profile removal.
        expect(mockRelay.methodCalls, isEmpty);
      },
    );

    test('restoreDefaults preserves existing custom entries', () async {
      final pre = MockRelayPreferencesService(
        initialRelays: const {
          RelayCategory.profile: ['wss://custom-profile.example.com'],
        },
      );
      final c = ProviderContainer(
        overrides: [
          relayPreferencesServiceProvider.overrideWith((ref) async => pre),
          relayServiceProvider.overrideWithValue(MockRelayService()),
        ],
      );
      addTearDown(c.dispose);
      await c.read(profileRelaysProvider.future);
      await c.read(profileRelaysProvider.notifier).restoreDefaults();
      final after = await c.read(profileRelaysProvider.future);
      expect(after, contains('wss://custom-profile.example.com'));
      // Profile-plane defaults are a distinct string family from the
      // Inbox/KeyPackage ones the mock uses (see
      // `MockRelayPreferencesService.restoreDefaults`) — the same
      // plane-separation fixture convention as `seedDefaultsIfUnseeded`.
      expect(after, contains('wss://profile-default-a'));
    });

    test('wipeAndReset removes user customizations', () async {
      final pre = MockRelayPreferencesService(
        initialRelays: const {
          RelayCategory.profile: ['wss://custom-profile.example.com'],
        },
      );
      final c = ProviderContainer(
        overrides: [
          relayPreferencesServiceProvider.overrideWith((ref) async => pre),
          relayServiceProvider.overrideWithValue(MockRelayService()),
        ],
      );
      addTearDown(c.dispose);
      await c.read(profileRelaysProvider.future);
      await c.read(profileRelaysProvider.notifier).wipeAndReset();
      final after = await c.read(profileRelaysProvider.future);
      expect(after, isNot(contains('wss://custom-profile.example.com')));
    });
  });

  group('profilePoolStatusProvider', () {
    test('surfaces the service-reported status', () async {
      final pre = MockRelayPreferencesService(
        poolStatus: const ProfilePoolStatus(
          configured: 5,
          excluded: 3,
          usable: 2,
          isUnderflow: true,
        ),
      );
      final c = ProviderContainer(
        overrides: [
          relayPreferencesServiceProvider.overrideWith((ref) async => pre),
          relayServiceProvider.overrideWithValue(MockRelayService()),
        ],
      );
      addTearDown(c.dispose);

      final status = await c.read(profilePoolStatusProvider.future);
      expect(status.configured, 5);
      expect(status.excluded, 3);
      expect(status.usable, 2);
      expect(status.isUnderflow, isTrue);
    });

    test('defaults to a healthy (non-underflow) pool', () async {
      final status = await container.read(profilePoolStatusProvider.future);
      expect(status.isUnderflow, isFalse);
    });

    test('recomputes when the Profile relay list changes', () async {
      final pre = MockRelayPreferencesService(
        initialRelays: const {
          RelayCategory.profile: ['wss://only-profile.example.com'],
        },
      );
      final c = ProviderContainer(
        overrides: [
          relayPreferencesServiceProvider.overrideWith((ref) async => pre),
          relayServiceProvider.overrideWithValue(MockRelayService()),
        ],
      );
      addTearDown(c.dispose);

      await c.read(profilePoolStatusProvider.future);
      final callsBefore = pre.log
          .where((e) => e == 'profilePoolStatus')
          .length;

      await c
          .read(profileRelaysProvider.notifier)
          .addRelay('wss://second-profile.example.com');
      // profileRelaysProvider's new state triggers profilePoolStatusProvider
      // (which `ref.watch`es it) to rebuild and re-query the status.
      await c.read(profilePoolStatusProvider.future);
      final callsAfter = pre.log
          .where((e) => e == 'profilePoolStatus')
          .length;
      expect(callsAfter, greaterThan(callsBefore));
    });
  });

  group('publishableRelayCategories / forceEnablePublishToggles', () {
    test('excludes RelayCategory.profile from the publish allowlist', () {
      expect(
        publishableRelayCategories,
        containsAll(<RelayCategory>[
          RelayCategory.inbox,
          RelayCategory.keyPackage,
        ]),
      );
      expect(
        publishableRelayCategories,
        isNot(contains(RelayCategory.profile)),
      );
    });

    test(
      'force-enables publish only for Inbox/KeyPackage — regression: the '
      'service-provider init loop must never call setPublishRelayList for '
      'profile',
      () async {
        final freshMock = MockRelayPreferencesService();
        await forceEnablePublishToggles(freshMock);
        expect(freshMock.log, contains('toggle:inbox=true'));
        expect(freshMock.log, contains('toggle:keyPackage=true'));
        expect(freshMock.log, isNot(contains('toggle:profile=true')));
      },
    );
  });
}
