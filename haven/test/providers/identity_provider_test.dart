/// Tests for identity provider invalidation behavior.
///
/// Verifies that [identityProvider] (a read-only [FutureProvider]) is
/// correctly invalidated after mutations in [IdentityNotifier]:
///
/// - After [IdentityNotifier.createIdentity], [identityProvider] returns the
///   newly created identity instead of a stale null.
/// - After [IdentityNotifier.importFromNsec], [identityProvider] returns the
///   imported identity instead of a stale null.
/// - After [IdentityNotifier.deleteIdentity], [identityProvider] returns null.
/// - Error paths in [IdentityNotifier.createIdentity] and
///   [IdentityNotifier.importFromNsec] are reflected in notifier state and
///   do not corrupt [identityProvider].
///
/// These tests specifically guard against the regression where
/// [ref.invalidate(identityProvider)] was missing, leaving [identityProvider]
/// with a stale cached value after a successful mutation.
library;

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/constants/location.dart';
import 'package:haven/src/constants/tiles.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/live_sync_provider.dart' show liveSyncEnabled;
import 'package:haven/src/providers/relay_preferences_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/providers/tile_prefetch_provider.dart';
import 'package:haven/src/rust/api.dart'
    show
        BacklogOutcomeFfi,
        BurstOpenFfi,
        FfiGroupSpec,
        FfiRelayEvent,
        FfiRelayEventKind,
        LiveLifecycleFfi,
        RelayManagerFfi;
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/clock_skew_detector.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/services/live_sync_resubscriber.dart';
import 'package:haven/src/services/location_sharing_service.dart';
import 'package:haven/src/services/maintenance_service.dart';
import 'package:haven/src/services/nostr_relay_service.dart';
import 'package:haven/src/services/nostr_subscription_service.dart';
import 'package:haven/src/services/pending_leave_service.dart' show kPendingLeaveKey;
import 'package:haven/src/services/pending_mls_wipe_service.dart';
import 'package:haven/src/services/relay_preferences_service.dart';
import 'package:haven/src/services/subscription_service.dart'
    show
        LiveEventRouter,
        LiveSyncStopOutcome,
        SubscriptionService,
        SubscriptionServiceException;
import 'package:haven/src/services/tile_prefetch_service.dart';
import 'package:latlong2/latlong.dart' hide Circle;
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_live_sync_engine.dart';
import '../mocks/mock_circle_service.dart';
import '../mocks/mock_relay_preferences_service.dart';
import '../mocks/mock_relay_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ---------------------------------------------------------------------------
  // Shared test fixtures
  // ---------------------------------------------------------------------------

  /// An identity representing the state BEFORE any mutation.
  ///
  /// When the service starts with no stored identity, [getIdentity] returns
  /// null. After creation, it returns [_createdIdentity].
  const _emptyPubkey =
      '0000000000000000000000000000000000000000000000000000000000000000';

  final createdIdentity = Identity(
    pubkeyHex:
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    npub: 'npub1created',
    createdAt: DateTime(2025),
  );

  final importedIdentity = Identity(
    pubkeyHex:
        'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
    npub: 'npub1imported',
    createdAt: DateTime(2025),
  );

  // ---------------------------------------------------------------------------
  // identityProvider — read-only FutureProvider
  // ---------------------------------------------------------------------------

  group('identityProvider', () {
    test('returns null when service has no identity', () async {
      final mockService = _MockIdentityService(initialIdentity: null);
      final container = ProviderContainer(
        overrides: [
          identityServiceProvider.overrideWithValue(mockService),
          circleServiceProvider.overrideWithValue(MockCircleService()),
        ],
      );
      addTearDown(container.dispose);

      final identity = await container.read(identityProvider.future);

      expect(identity, isNull);
    });

    test('returns identity when service has one stored', () async {
      final mockService = _MockIdentityService(
        initialIdentity: createdIdentity,
      );
      final container = ProviderContainer(
        overrides: [
          identityServiceProvider.overrideWithValue(mockService),
          circleServiceProvider.overrideWithValue(MockCircleService()),
        ],
      );
      addTearDown(container.dispose);

      final identity = await container.read(identityProvider.future);

      expect(identity, equals(createdIdentity));
      expect(identity!.pubkeyHex, createdIdentity.pubkeyHex);
    });
  });

  // ---------------------------------------------------------------------------
  // IdentityNotifier.createIdentity invalidates identityProvider
  // ---------------------------------------------------------------------------

  group('IdentityNotifier.createIdentity', () {
    test(
      'identityProvider returns new identity after createIdentity succeeds',
      () async {
        // Service starts with no identity; after createIdentity it returns one.
        final mockService = _MockIdentityService(
          initialIdentity: null,
          createResult: createdIdentity,
        );
        final container = ProviderContainer(
          overrides: [
            identityServiceProvider.overrideWithValue(mockService),
            circleServiceProvider.overrideWithValue(MockCircleService()),
          ],
        );
        addTearDown(container.dispose);

        // Seed identityProvider cache with null (no identity yet).
        final beforeCreate = await container.read(identityProvider.future);
        expect(
          beforeCreate,
          isNull,
          reason: 'identityProvider should be null before createIdentity',
        );

        // Perform the mutation.
        await container
            .read(identityNotifierProvider.notifier)
            .createIdentity();

        // identityProvider must have been invalidated so it re-fetches; the
        // service now returns createdIdentity.
        final afterCreate = await container.read(identityProvider.future);
        expect(
          afterCreate,
          isNotNull,
          reason:
              'identityProvider must not return stale null after '
              'createIdentity — ref.invalidate(identityProvider) is required',
        );
        expect(afterCreate, equals(createdIdentity));
        expect(afterCreate!.npub, 'npub1created');
      },
    );

    test('identityNotifierProvider state reflects created identity', () async {
      final mockService = _MockIdentityService(
        initialIdentity: null,
        createResult: createdIdentity,
      );
      final container = ProviderContainer(
        overrides: [
          identityServiceProvider.overrideWithValue(mockService),
          circleServiceProvider.overrideWithValue(MockCircleService()),
        ],
      );
      addTearDown(container.dispose);

      await container.read(identityNotifierProvider.notifier).createIdentity();

      final notifierState = await container.read(
        identityNotifierProvider.future,
      );
      expect(notifierState, isNotNull);
      expect(notifierState, equals(createdIdentity));
    });

    test(
      'identityNotifierProvider enters error state when createIdentity throws',
      () async {
        final mockService = _MockIdentityService(
          initialIdentity: null,
          throwOnCreate: true,
        );
        final container = ProviderContainer(
          overrides: [
            identityServiceProvider.overrideWithValue(mockService),
            circleServiceProvider.overrideWithValue(MockCircleService()),
          ],
        );
        addTearDown(container.dispose);

        await container
            .read(identityNotifierProvider.notifier)
            .createIdentity();

        final notifierState = container.read(identityNotifierProvider);
        expect(
          notifierState.hasError,
          isTrue,
          reason:
              'IdentityNotifier should expose the error via AsyncValue.guard',
        );
      },
    );

    test(
      'identityProvider is invalidated even when createIdentity throws',
      () async {
        // Service starts returning an identity (simulates a pre-existing cache).
        // After throwing on createIdentity, identityProvider should be
        // invalidated (forced to re-fetch) rather than holding the old value.
        final mockService = _MockIdentityService(
          initialIdentity: createdIdentity,
          throwOnCreate: true,
        );
        final container = ProviderContainer(
          overrides: [
            identityServiceProvider.overrideWithValue(mockService),
            circleServiceProvider.overrideWithValue(MockCircleService()),
          ],
        );
        addTearDown(container.dispose);

        // Prime the cache.
        await container.read(identityProvider.future);

        // Trigger failing mutation.
        await container
            .read(identityNotifierProvider.notifier)
            .createIdentity();

        // After the call, identityProvider should have been re-fetched.
        // The service still returns createdIdentity, so we check re-fetch
        // happened by observing the call count.
        expect(
          mockService.getIdentityCallCount,
          greaterThan(1),
          reason:
              'identityProvider must re-fetch after createIdentity '
              'even on failure, proving invalidation occurred',
        );
      },
    );

    test('service createIdentity is called exactly once', () async {
      final mockService = _MockIdentityService(
        initialIdentity: null,
        createResult: createdIdentity,
      );
      final container = ProviderContainer(
        overrides: [
          identityServiceProvider.overrideWithValue(mockService),
          circleServiceProvider.overrideWithValue(MockCircleService()),
        ],
      );
      addTearDown(container.dispose);

      await container.read(identityNotifierProvider.notifier).createIdentity();

      expect(mockService.createCallCount, 1);
    });
  });

  // ---------------------------------------------------------------------------
  // IdentityNotifier.importFromNsec invalidates identityProvider
  // ---------------------------------------------------------------------------

  group('IdentityNotifier.importFromNsec', () {
    const testNsec = 'nsec1fake_test_value_not_a_real_key_000000000000000000';

    test(
      'identityProvider returns imported identity after importFromNsec',
      () async {
        final mockService = _MockIdentityService(
          initialIdentity: null,
          importResult: importedIdentity,
        );
        final container = ProviderContainer(
          overrides: [
            identityServiceProvider.overrideWithValue(mockService),
            circleServiceProvider.overrideWithValue(MockCircleService()),
          ],
        );
        addTearDown(container.dispose);

        // Seed identityProvider cache with null.
        final beforeImport = await container.read(identityProvider.future);
        expect(
          beforeImport,
          isNull,
          reason: 'identityProvider should be null before importFromNsec',
        );

        // Perform the mutation.
        await container
            .read(identityNotifierProvider.notifier)
            .importFromNsec(testNsec);

        // identityProvider must have been invalidated and re-fetched.
        final afterImport = await container.read(identityProvider.future);
        expect(
          afterImport,
          isNotNull,
          reason:
              'identityProvider must not return stale null after '
              'importFromNsec — ref.invalidate(identityProvider) is required',
        );
        expect(afterImport, equals(importedIdentity));
        expect(afterImport!.npub, 'npub1imported');
      },
    );

    test('identityNotifierProvider state reflects imported identity', () async {
      final mockService = _MockIdentityService(
        initialIdentity: null,
        importResult: importedIdentity,
      );
      final container = ProviderContainer(
        overrides: [
          identityServiceProvider.overrideWithValue(mockService),
          circleServiceProvider.overrideWithValue(MockCircleService()),
        ],
      );
      addTearDown(container.dispose);

      await container
          .read(identityNotifierProvider.notifier)
          .importFromNsec(testNsec);

      final notifierState = await container.read(
        identityNotifierProvider.future,
      );
      expect(notifierState, isNotNull);
      expect(notifierState, equals(importedIdentity));
    });

    test('nsec string is forwarded to the service unchanged', () async {
      final mockService = _MockIdentityService(
        initialIdentity: null,
        importResult: importedIdentity,
      );
      final container = ProviderContainer(
        overrides: [
          identityServiceProvider.overrideWithValue(mockService),
          circleServiceProvider.overrideWithValue(MockCircleService()),
        ],
      );
      addTearDown(container.dispose);

      await container
          .read(identityNotifierProvider.notifier)
          .importFromNsec(testNsec);

      expect(
        mockService.lastImportedNsec,
        testNsec,
        reason: 'The nsec passed to importFromNsec must reach the service',
      );
    });

    test(
      'identityNotifierProvider enters error state when importFromNsec throws',
      () async {
        final mockService = _MockIdentityService(
          initialIdentity: null,
          throwOnImport: true,
        );
        final container = ProviderContainer(
          overrides: [
            identityServiceProvider.overrideWithValue(mockService),
            circleServiceProvider.overrideWithValue(MockCircleService()),
          ],
        );
        addTearDown(container.dispose);

        await container
            .read(identityNotifierProvider.notifier)
            .importFromNsec(testNsec);

        final notifierState = container.read(identityNotifierProvider);
        expect(
          notifierState.hasError,
          isTrue,
          reason:
              'IdentityNotifier should expose import errors via '
              'AsyncValue.guard',
        );
      },
    );

    test(
      'identityProvider is invalidated even when importFromNsec throws',
      () async {
        final mockService = _MockIdentityService(
          initialIdentity: importedIdentity,
          throwOnImport: true,
        );
        final container = ProviderContainer(
          overrides: [
            identityServiceProvider.overrideWithValue(mockService),
            circleServiceProvider.overrideWithValue(MockCircleService()),
          ],
        );
        addTearDown(container.dispose);

        // Prime the cache.
        await container.read(identityProvider.future);

        // Trigger failing mutation.
        await container
            .read(identityNotifierProvider.notifier)
            .importFromNsec(testNsec);

        // identityProvider must have been invalidated and re-fetched.
        expect(
          mockService.getIdentityCallCount,
          greaterThan(1),
          reason:
              'identityProvider must re-fetch after importFromNsec '
              'even on failure, proving invalidation occurred',
        );
      },
    );

    test('service importFromNsec is called exactly once', () async {
      final mockService = _MockIdentityService(
        initialIdentity: null,
        importResult: importedIdentity,
      );
      final container = ProviderContainer(
        overrides: [
          identityServiceProvider.overrideWithValue(mockService),
          circleServiceProvider.overrideWithValue(MockCircleService()),
        ],
      );
      addTearDown(container.dispose);

      await container
          .read(identityNotifierProvider.notifier)
          .importFromNsec(testNsec);

      expect(mockService.importCallCount, 1);
    });
  });

  // ---------------------------------------------------------------------------
  // IdentityNotifier.deleteIdentity invalidates identityProvider
  // ---------------------------------------------------------------------------

  group('IdentityNotifier.deleteIdentity', () {
    test('identityProvider returns null after deleteIdentity', () async {
      // Service starts with an identity; after deletion it returns null.
      final mockService = _MockIdentityService(
        initialIdentity: createdIdentity,
        deleteClears: true,
      );
      final container = ProviderContainer(
        overrides: [
          identityServiceProvider.overrideWithValue(mockService),
          circleServiceProvider.overrideWithValue(MockCircleService()),
        ],
      );
      addTearDown(container.dispose);

      // Seed cache with an identity.
      final beforeDelete = await container.read(identityProvider.future);
      expect(
        beforeDelete,
        isNotNull,
        reason: 'identityProvider should have an identity before delete',
      );

      // Perform deletion.
      await container.read(identityNotifierProvider.notifier).deleteIdentity();

      // identityProvider must return null after deletion.
      final afterDelete = await container.read(identityProvider.future);
      expect(
        afterDelete,
        isNull,
        reason:
            'identityProvider must return null after deleteIdentity — '
            'ref.invalidate(identityProvider) is required',
      );
    });

    // Dark Matter DM-4b note: this test used to also assert
    // `wipeAllStagedCommits` ran on logout (M7). `CircleService
    // .wipeAllStagedCommits` was deleted — the Dark Matter engine now owns
    // commit staging/convergence entirely inside Rust, so there is no
    // Dart-visible staged-commit marker left for `deleteIdentity()` to wipe.
    // `resetAllSyncCursors` remains a real, still-called teardown step, so
    // the test is re-expressed around it rather than dropped outright.
    test('deleteIdentity resets all sync cursors (M7 teardown)', () async {
      final mockService = _MockIdentityService(
        initialIdentity: createdIdentity,
        deleteClears: true,
      );
      final mockCircle = MockCircleService();
      final container = ProviderContainer(
        overrides: [
          identityServiceProvider.overrideWithValue(mockService),
          circleServiceProvider.overrideWithValue(mockCircle),
        ],
      );
      addTearDown(container.dispose);

      await container.read(identityProvider.future);
      await container.read(identityNotifierProvider.notifier).deleteIdentity();

      expect(
        mockCircle.methodCalls,
        contains('resetAllSyncCursors'),
        reason: 'logout must reset all sync cursors',
      );
    });

    test("a logout forgets the clock evidence the identity's peers gave",
        () async {
      final at = DateTime.utc(2026, 10, 14, 12);
      final detector = ClockSkewDetector(now: () => at);
      final container = ProviderContainer(
        overrides: [
          identityServiceProvider.overrideWithValue(
            _MockIdentityService(
              initialIdentity: createdIdentity,
              deleteClears: true,
            ),
          ),
          circleServiceProvider.overrideWithValue(MockCircleService()),
          clockSkewDetectorProvider.overrideWithValue(detector),
        ],
      );
      addTearDown(container.dispose);
      detector.recordPeerTimestamp(
        senderPubkey: 'a-peer-of-the-first-identity',
        peerTimestamp: at.add(const Duration(minutes: 10)),
      );
      expect(detector.status.isSkewed, isTrue, reason: 'premise: a verdict');

      await container.read(identityNotifierProvider.notifier).deleteIdentity();

      expect(
        detector.status,
        ClockSkewStatus.healthy,
        reason: 'the next identity is shown a clock banner raised by the '
            "deleted one's peers",
      );
      expect(detector.trackedSourceCountForTest, 0);
    });

    test("a logout forgets the waits the identity's leaves and drives named",
        () async {
      final maintenance = _ForgetCountingMaintenance();
      final container = ProviderContainer(
        overrides: [
          identityServiceProvider.overrideWithValue(
            _MockIdentityService(
              initialIdentity: createdIdentity,
              deleteClears: true,
            ),
          ),
          circleServiceProvider.overrideWithValue(MockCircleService()),
          maintenanceServiceProvider.overrideWithValue(maintenance),
        ],
      );
      addTearDown(container.dispose);

      await container.read(identityNotifierProvider.notifier).deleteIdentity();

      expect(
        maintenance.forgets,
        1,
        reason: "the next identity's first carry-on and drive wait out the "
            "deleted one's circles",
      );
    });

    test('a logout closes the publish connection after the stops and the '
        "wipe, so the next identity's first publish opens its own", () async {
      // Left open, the pool's sockets live 60-70 s past their last send, and
      // the next identity's publishes inside that window would ride them —
      // one connection carrying both identities links the two at that relay.
      final identity = _MockIdentityService(
        initialIdentity: createdIdentity,
        deleteClears: true,
      );
      final circle = MockCircleService();
      final engine = _RecordingSubscriptionService(sharedLog: []);
      late final List<String> atShutdown;
      final pool = _RecordingRelayManager(
        onShutdown: () => atShutdown = [
          if (circle.methodCalls.contains('wipeAllMlsState')) 'wiped',
          if (identity.deleteCallCount == 1) 'key deleted',
          'stops:${engine.stopCalls}',
        ],
      );
      final relay = NostrRelayService.withInjectedManager(pool);
      final container = ProviderContainer(
        overrides: [
          identityServiceProvider.overrideWithValue(identity),
          circleServiceProvider.overrideWithValue(circle),
          subscriptionServiceProvider.overrideWithValue(engine),
          relayServiceProvider.overrideWithValue(relay),
        ],
      );
      addTearDown(container.dispose);

      await container.read(identityNotifierProvider.notifier).deleteIdentity();

      expect(pool.shutdownCalls, 1, reason: 'the pool was left open');
      expect(atShutdown, [
        'wiped',
        'key deleted',
        'stops:${liveSyncEnabled ? 2 : 0}',
      ]);
      expect(
        relay.poolOpenForTest,
        isFalse,
        reason: "the next identity's first relay call would reuse the last "
            "identity's pool",
      );
      expect(pool.otherCalls, isEmpty);
    });

    /// Logs in through [login] over a pool that records its shutdown.
    Future<void> loginShutsThePool(
      Future<void> Function(IdentityNotifier notifier) login,
    ) async {
      // Whatever the last identity left on the pool — a publish, a fetch, a
      // pool opened after its logout — the next one opens its own.
      SharedPreferences.setMockInitialValues({});
      final identity = _MockIdentityService(
        createResult: createdIdentity,
        importResult: importedIdentity,
      );
      int? provisionedAtShutdown;
      final pool = _RecordingRelayManager(
        onShutdown: () => provisionedAtShutdown =
            identity.createCallCount + identity.importCallCount,
      );
      final relay = NostrRelayService.withInjectedManager(pool);
      final container = ProviderContainer(
        overrides: [
          identityServiceProvider.overrideWithValue(identity),
          circleServiceProvider.overrideWithValue(MockCircleService()),
          relayServiceProvider.overrideWithValue(relay),
        ],
      );
      addTearDown(container.dispose);

      await login(container.read(identityNotifierProvider.notifier));

      expect(pool.shutdownCalls, 1, reason: 'the pool was left open');
      expect(provisionedAtShutdown, 0, reason: 'shut after provisioning');
      expect(relay.poolOpenForTest, isFalse);
    }

    test('createIdentity shuts the publish pool before the identity is '
        'provisioned', () => loginShutsThePool((n) => n.createIdentity()));

    test('importFromNsec shuts the publish pool before the identity is '
        'provisioned', () => loginShutsThePool((n) => n.importFromNsec('x')));

    test('the clock reset comes after the stops: a sample recorded while the '
        'first is out is gone', () {
      // A handler of the deleted identity's session runs until its stop
      // returns, and records what it receives on the location service the
      // wipe has not yet closed. On a fake clock: the logout arms its 65 s
      // stop deadline.
      SharedPreferences.setMockInitialValues({});
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            ..allMessagesHandler = (_, _, _) async => null;
      addTearDown(() => messenger.allMessagesHandler = null);
      fakeAsync((async) {
        final at = DateTime.utc(2026, 10, 15, 12);
        final detector = ClockSkewDetector(now: () => at);
        final engine = _ParkedFirstStopService()
          ..firstStop = Completer<void>();
        final container = ProviderContainer(
          overrides: [
            identityServiceProvider.overrideWithValue(
              _MockIdentityService(
                initialIdentity: createdIdentity,
                deleteClears: true,
              ),
            ),
            circleServiceProvider.overrideWithValue(MockCircleService()),
            clockSkewDetectorProvider.overrideWithValue(detector),
            subscriptionServiceProvider.overrideWithValue(engine),
          ],
        );
        final sharing = container.read(locationSharingServiceProvider);
        var loggedOut = false;
        unawaited(
          container
              .read(identityNotifierProvider.notifier)
              .deleteIdentity()
              .then((_) => loggedOut = true),
        );
        async.flushMicrotasks();
        unawaited(
          sharing.ingestStreamedLocation(
            circle: TestCircleFactory.createCircle(
              nostrGroupId: const [1, 2, 3],
              mlsGroupId: const [9, 9, 9],
            ),
            decrypted: DecryptedLocation(
              senderPubkey: 'a-peer-of-the-first-identity',
              latitude: 1,
              longitude: 2,
              geohash: 'g',
              timestamp: at.add(const Duration(minutes: 10)),
              expiresAt: at.add(const Duration(hours: 1)),
            ),
          ),
        );
        async.flushMicrotasks();
        if (liveSyncEnabled) {
          expect(engine.stopCalls, 1, reason: 'premise: inside the first stop');
          expect(detector.status.isSkewed, isTrue, reason: 'premise: recorded');
        }
        engine.firstStop!.complete();
        async.flushMicrotasks();

        expect(loggedOut, isTrue, reason: 'premise: the logout ended');
        expect(
          detector.trackedSourceCountForTest,
          0,
          reason: "the next identity inherits a sample of the deleted one's "
              'peer, recorded after the reset',
        );
        expect(detector.status, ClockSkewStatus.healthy);
        container.dispose();
      });
    });

    test(
      'deleteIdentity calls closeAndInvalidate and wipeAllMlsState (M10)',
      () async {
        final mockService = _MockIdentityService(
          initialIdentity: createdIdentity,
          deleteClears: true,
        );
        final mockCircle = MockCircleService();
        final container = ProviderContainer(
          overrides: [
            identityServiceProvider.overrideWithValue(mockService),
            circleServiceProvider.overrideWithValue(mockCircle),
          ],
        );
        addTearDown(container.dispose);

        await container.read(identityNotifierProvider.notifier).deleteIdentity();

        expect(
          mockCircle.methodCalls,
          containsAll(<String>['closeAndInvalidate', 'wipeAllMlsState']),
          reason:
              'logout must close the DB handle then wipe MLS state (M10)',
        );
      },
    );

    test(
      'deleteIdentity calls closeAndInvalidate BEFORE wipeAllMlsState (M10 ordering)',
      () async {
        final mockService = _MockIdentityService(
          initialIdentity: createdIdentity,
          deleteClears: true,
        );
        final mockCircle = MockCircleService();
        final container = ProviderContainer(
          overrides: [
            identityServiceProvider.overrideWithValue(mockService),
            circleServiceProvider.overrideWithValue(mockCircle),
          ],
        );
        addTearDown(container.dispose);

        await container.read(identityNotifierProvider.notifier).deleteIdentity();

        final closeIdx = mockCircle.methodCalls.indexOf('closeAndInvalidate');
        final wipeIdx = mockCircle.methodCalls.indexOf('wipeAllMlsState');

        expect(closeIdx, isNot(-1), reason: 'closeAndInvalidate must be called');
        expect(wipeIdx, isNot(-1), reason: 'wipeAllMlsState must be called');
        expect(
          closeIdx,
          lessThan(wipeIdx),
          reason:
              'closeAndInvalidate must precede wipeAllMlsState so the SQLite '
              'fd is closed before the file is deleted (POSIX-safe)',
        );
      },
    );

    test(
      'identityNotifierProvider state is null after deleteIdentity',
      () async {
        final mockService = _MockIdentityService(
          initialIdentity: createdIdentity,
          deleteClears: true,
        );
        final container = ProviderContainer(
          overrides: [
            identityServiceProvider.overrideWithValue(mockService),
            circleServiceProvider.overrideWithValue(MockCircleService()),
          ],
        );
        addTearDown(container.dispose);

        await container
            .read(identityNotifierProvider.notifier)
            .deleteIdentity();

        final notifierState = await container.read(
          identityNotifierProvider.future,
        );
        expect(notifierState, isNull);
      },
    );

    test('service deleteIdentity is called exactly once', () async {
      final mockService = _MockIdentityService(
        initialIdentity: createdIdentity,
        deleteClears: true,
      );
      final container = ProviderContainer(
        overrides: [
          identityServiceProvider.overrideWithValue(mockService),
          circleServiceProvider.overrideWithValue(MockCircleService()),
        ],
      );
      addTearDown(container.dispose);

      await container.read(identityNotifierProvider.notifier).deleteIdentity();

      expect(mockService.deleteCallCount, 1);
    });
  });

  // ---------------------------------------------------------------------------
  // M11 — deleteIdentity stops the live-sync engine BEFORE the MLS wipe
  //
  // identity_provider.dart's deleteIdentity() stops subscriptionServiceProvider
  // (when liveSyncEnabled) BEFORE closeAndInvalidate()/wipeAllMlsState() — a
  // standing engine subscription must tear down before the SQLCipher state it
  // reads is deleted. `liveSyncEnabled` is a compile-time const
  // (bool.fromEnvironment, default true since M11 Phase B), so this test
  // asserts the CORRECT behavior for whichever value is actually compiled in:
  // under the default (flag ON) build it asserts the real stop-before-wipe
  // ordering; built with `--dart-define=HAVEN_LIVE_SYNC=false` (the retained
  // rollback path), the guarded branch is dead code and the engine must be
  // untouched.
  // ---------------------------------------------------------------------------

  group('IdentityNotifier.deleteIdentity — M11 engine stop ordering', () {
    test(
      'subscriptionServiceProvider.stop() fires and precedes wipeAllMlsState() '
      'when liveSyncEnabled',
      () async {
        final mockCircle = MockCircleService();
        final engine = _RecordingSubscriptionService(
          sharedLog: mockCircle.methodCalls,
        );
        final mockService = _MockIdentityService(
          initialIdentity: createdIdentity,
          deleteClears: true,
        );
        final container = ProviderContainer(
          overrides: [
            identityServiceProvider.overrideWithValue(mockService),
            circleServiceProvider.overrideWithValue(mockCircle),
            subscriptionServiceProvider.overrideWithValue(engine),
          ],
        );
        addTearDown(container.dispose);

        await container
            .read(identityNotifierProvider.notifier)
            .deleteIdentity();

        if (liveSyncEnabled) {
          expect(
            engine.stopCalls,
            greaterThanOrEqualTo(1),
            reason: 'deleteIdentity must stop the live-sync engine when '
                'liveSyncEnabled (identity_provider.dart).',
          );
          final stopIdx = mockCircle.methodCalls.indexOf(
            'subscriptionService.stop',
          );
          final wipeIdx = mockCircle.methodCalls.indexOf('wipeAllMlsState');
          expect(stopIdx, isNot(-1), reason: 'stop() must be recorded');
          expect(wipeIdx, isNot(-1), reason: 'wipeAllMlsState must be called');
          expect(
            stopIdx,
            lessThan(wipeIdx),
            reason:
                'the engine must stop BEFORE circles.db is wiped, so no '
                'standing subscription can read/touch it mid-wipe',
          );
        } else {
          expect(
            engine.stopCalls,
            0,
            reason:
                'with liveSyncEnabled false (the default), deleteIdentity '
                'must never touch the subscription service — the stop call '
                'is inside an `if (liveSyncEnabled)` branch',
          );
        }
      },
    );

    test('a PAUSED engine is stopped too, not left holding the MLS guard',
        () async {
      // A pause drops the REQs and the sockets; it does NOT release the
      // engine's `Arc<CircleManager>`, and with it the MLS database's Rule-14
      // single-session guard. So a logout that skipped the stop because the
      // engine "was not doing anything" would wipe the identity and leave the
      // guard registered against a database nothing can reopen.
      final mockCircle = MockCircleService();
      final engine = _RecordingSubscriptionService(
        sharedLog: mockCircle.methodCalls,
      )..paused = true;
      final container = ProviderContainer(
        overrides: [
          identityServiceProvider.overrideWithValue(
            _MockIdentityService(
              initialIdentity: createdIdentity,
              deleteClears: true,
            ),
          ),
          circleServiceProvider.overrideWithValue(mockCircle),
          subscriptionServiceProvider.overrideWithValue(engine),
        ],
      );
      addTearDown(container.dispose);

      await container.read(identityNotifierProvider.notifier).deleteIdentity();

      // Once before the wipes, once behind the circle service's latch.
      expect(engine.stopCalls, liveSyncEnabled ? 2 : 0);
    });

    test('the second stop is behind the latch and ahead of the MLS wipe',
        () async {
      final mockCircle = MockCircleService();
      final engine = _RecordingSubscriptionService(
        sharedLog: mockCircle.methodCalls,
      );
      final container = ProviderContainer(
        overrides: [
          identityServiceProvider.overrideWithValue(
            _MockIdentityService(
              initialIdentity: createdIdentity,
              deleteClears: true,
            ),
          ),
          circleServiceProvider.overrideWithValue(mockCircle),
          subscriptionServiceProvider.overrideWithValue(engine),
        ],
      );
      addTearDown(container.dispose);

      await container.read(identityNotifierProvider.notifier).deleteIdentity();

      final order = [
        for (final call in mockCircle.methodCalls)
          if (const {
            'subscriptionService.stop',
            'resetAllSyncCursors',
            'closeAndInvalidate',
            'wipeAllMlsState',
          }.contains(call))
            call,
      ];
      expect(
        order,
        liveSyncEnabled
            ? const [
                'subscriptionService.stop',
                'resetAllSyncCursors',
                'closeAndInvalidate',
                'subscriptionService.stop',
                'wipeAllMlsState',
              ]
            : const [
                'resetAllSyncCursors',
                'closeAndInvalidate',
                'wipeAllMlsState',
              ],
        reason: 'ahead of the latch a queued leg can still build an engine '
            'behind the stop; behind the wipe that engine has already been '
            'left holding the files',
      );
    });
  });

  // A logout stops the engine and then wipes. It has no deadline of its own,
  // and a start can be seconds from resolving — or never resolve.
  group('IdentityNotifier.deleteIdentity — a live-sync start in flight', () {
    test('the logout ends the start, and wipes only once the engine has '
        'stopped', () async {
      final mockCircle = MockCircleService();
      final engine = _LoggingEngine(mockCircle.methodCalls)
        ..startGate = Completer<void>();
      final service = NostrSubscriptionService(
        router: LiveEventRouter(
          circleService: () => mockCircle,
          circlesSnapshot: () async => const [],
          secretBytes: () async => const [],
          parseLocation: (_, _) async => null,
          ingestLocation: (_, _) async {},
          reconcileRoster: (_) async {},
          onLocationsChanged: () {},
          onGroupUpdated: (_) {},
          onInvitationReceived: () {},
          onStatus: (_) {},
        ),
        engineFactory: () async => engine,
      );
      final container = ProviderContainer(
        overrides: [
          identityServiceProvider.overrideWithValue(
            _MockIdentityService(
              initialIdentity: createdIdentity,
              deleteClears: true,
            ),
          ),
          circleServiceProvider.overrideWithValue(mockCircle),
          subscriptionServiceProvider.overrideWithValue(service),
        ],
      );
      addTearDown(container.dispose);
      final starting = service
          .start(groups: const [], inboxRelays: const [])
          .then<Object?>((_) => null, onError: (Object e) => e);
      await pumpEventQueue();
      expect(engine.calls, ['start'], reason: 'premise: still connecting');

      // The start's gate is never opened.
      final loggingOut =
          container.read(identityNotifierProvider.notifier).deleteIdentity();
      await pumpEventQueue();
      if (liveSyncEnabled) {
        expect(
          engine.calls,
          ['start', 'stop'],
          reason: 'the logout is waiting for a start nothing else can end',
        );
      }
      await loggingOut;

      final wiped = mockCircle.methodCalls.indexOf('wipeAllMlsState');
      expect(wiped, isNot(-1), reason: 'the logout must reach its wipe');
      if (liveSyncEnabled) {
        expect(
          engine.calls,
          ['start', 'stop'],
          reason: 'a logout that waited for the start would never have '
              'returned',
        );
        expect(
          mockCircle.methodCalls.indexOf('engine.stopSession'),
          lessThan(wiped),
          reason: 'the session must be down before the state it reads is '
              'deleted',
        );
        expect(await starting, isA<SubscriptionServiceException>());
        expect(service.isRunning, isFalse);
      } else {
        expect(
          engine.calls,
          ['start'],
          reason: 'the rollback build never touches the engine at logout',
        );
        await service.stop();
      }
    });
  });

  // MapShell stays mounted across a logout (the router gates on onboarding,
  // not on identity), so its re-subscriber and every leg queued on it are
  // still there, in an app that is in front. The first stop ends the start
  // in flight; the legs behind it then find the identity present and the
  // manager open, for as long as the awaited wipes take.
  group('IdentityNotifier.deleteIdentity — legs queued behind the start it '
      'ends', () {
    LiveEventRouter router(MockCircleService circle) => LiveEventRouter(
      circleService: () => circle,
      circlesSnapshot: () async => const [],
      secretBytes: () async => const [],
      parseLocation: (_, _) async => null,
      ingestLocation: (_, _) async {},
      reconcileRoster: (_) async {},
      onLocationsChanged: () {},
      onGroupUpdated: (_) {},
      onInvitationReceived: () {},
      onStatus: (_) {},
    );

    test('no engine survives the wipe, and none is built behind the latch',
        () async {
      final circle = _GatedCursorsCircle()..cursorGate = Completer<void>();
      final engines = <_LoggingEngine>[];
      var refusedBuilds = 0;
      final service = NostrSubscriptionService(
        router: router(circle),
        // What the provider's factory does: once the circle service has
        // latched it hands out no manager (`NostrCircleService.initialize`).
        engineFactory: () async {
          if (circle.methodCalls.contains('closeAndInvalidate')) {
            refusedBuilds++;
            throw const CircleServiceException('circle service was wiped');
          }
          final engine = _LoggingEngine(circle.methodCalls);
          if (engines.isEmpty) engine.startGate = Completer<void>();
          engines.add(engine);
          return engine;
        },
      );
      final resubscriber = LiveSyncResubscriber(
        engine: service,
        inboxRelays: () async => const ['wss://inbox.test'],
        initialCircles: const [],
        sessionWanted: () => true,
      );
      addTearDown(resubscriber.dispose);
      final container = ProviderContainer(
        overrides: [
          identityServiceProvider.overrideWithValue(
            _MockIdentityService(
              initialIdentity: createdIdentity,
              deleteClears: true,
            ),
          ),
          circleServiceProvider.overrideWithValue(circle),
          subscriptionServiceProvider.overrideWithValue(service),
        ],
      );
      addTearDown(container.dispose);

      // The resume's heal, still connecting, and two more legs behind it.
      final legs = [
        resubscriber.ensureRunning(),
        resubscriber.ensureRunning(),
        resubscriber.ensureRunning(),
      ];
      await pumpEventQueue();
      expect(engines.single.calls, ['start'], reason: 'premise: connecting');

      final loggingOut =
          container.read(identityNotifierProvider.notifier).deleteIdentity();
      await pumpEventQueue();
      expect(
        circle.methodCalls,
        isNot(contains('closeAndInvalidate')),
        reason: 'premise: the logout is still in its awaited wipes',
      );

      if (!liveSyncEnabled) {
        // The rollback build never touches the engine at logout.
        circle.cursorGate!.complete();
        await loggingOut;
        expect(engines.single.calls, ['start']);
        await service.stop();
        await Future.wait(legs);
        return;
      }

      expect(
        engines,
        hasLength(2),
        reason: 'premise: a leg queued behind the start the logout ended '
            'built a new engine, with the identity still present',
      );
      expect(service.isRunning, isTrue, reason: 'premise: and it is up');

      circle.cursorGate!.complete();
      await loggingOut;
      await pumpEventQueue();

      expect(await Future.wait(legs), [
        LiveSyncHealOutcome.stoodDown,
        LiveSyncHealOutcome.running,
        LiveSyncHealOutcome.running,
      ]);
      expect(
        [for (final engine in engines) engine.stopCalls],
        [1, 1],
        reason: 'an engine built during the wipes outlived the logout: its '
            'REQs stand on the deleted identity until the app is restarted',
      );
      expect(service.isRunning, isFalse);
      final stops = [
        for (final (i, call) in circle.methodCalls.indexed)
          if (call == 'engine.stopSession') i,
      ];
      expect(
        stops.last,
        allOf(
          greaterThan(circle.methodCalls.indexOf('closeAndInvalidate')),
          lessThan(circle.methodCalls.indexOf('wipeAllMlsState')),
        ),
        reason: 'behind the latch, so nothing can start behind it; ahead of '
            'the wipe, so the files are not deleted under an open session',
      );
      expect(refusedBuilds, 0, reason: 'no start was left in flight');

      // And the latch really is final: a heal tick after the logout.
      expect(
        await resubscriber.ensureRunning(),
        LiveSyncHealOutcome.failed,
      );
      expect(refusedBuilds, 1);
      expect(engines, hasLength(2));
      expect(service.isRunning, isFalse);
    });

    test('a session the engine would not let go does not hold the wipe back',
        () async {
      // The key's deletion is the primary objective. What the logout must
      // not do is report that session gone: the service goes on answering
      // `stillHolding` for it.
      final circle = MockCircleService();
      final engine = _LoggingEngine(circle.methodCalls)..failStopCalls = 2;
      final service = NostrSubscriptionService(
        router: router(circle),
        engineFactory: () async => engine,
      );
      final identity = _MockIdentityService(
        initialIdentity: createdIdentity,
        deleteClears: true,
      );
      final container = ProviderContainer(
        overrides: [
          identityServiceProvider.overrideWithValue(identity),
          circleServiceProvider.overrideWithValue(circle),
          subscriptionServiceProvider.overrideWithValue(service),
        ],
      );
      addTearDown(container.dispose);
      await service.start(groups: const [], inboxRelays: const []);

      await container.read(identityNotifierProvider.notifier).deleteIdentity();

      expect(circle.methodCalls, contains('wipeAllMlsState'));
      expect(identity.deleteCallCount, 1);
      expect(await service.stop(), LiveSyncStopOutcome.stillHolding);
    });
  });

  // The secret key's removal is the logout's last step, behind two engine
  // stops. The engine's stop takes its lifecycle lock first, with no bound.
  group('IdentityNotifier.deleteIdentity — a stop that does not return', () {
    test('does not keep the key past one deadline: both stops share it, and '
        'the wipe and the deletion proceed at it', () {
      // Every platform channel the logout touches answers "not implemented",
      // as in every other test here — but at once, inside the fake clock,
      // not from the real event loop this test never returns to.
      SharedPreferences.setMockInitialValues({});
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            ..allMessagesHandler = (_, _, _) async => null;
      addTearDown(() => messenger.allMessagesHandler = null);
      fakeAsync((async) {
        final circle = MockCircleService();
        final engine = _NeverStoppingSubscriptionService();
        final identity = _MockIdentityService(
          initialIdentity: createdIdentity,
          deleteClears: true,
        );
        final container = ProviderContainer(
          overrides: [
            identityServiceProvider.overrideWithValue(identity),
            circleServiceProvider.overrideWithValue(circle),
            subscriptionServiceProvider.overrideWithValue(engine),
          ],
        );
        var done = false;
        unawaited(
          container
              .read(identityNotifierProvider.notifier)
              .deleteIdentity()
              .then((_) => done = true),
        );
        async.flushMicrotasks();
        if (liveSyncEnabled) {
          expect(identity.deleteCallCount, 0, reason: 'premise: waiting');
          expect(circle.methodCalls, isNot(contains('wipeAllMlsState')));
          async.elapse(kLiveSyncRestartBudget - const Duration(seconds: 1));
          expect(
            circle.methodCalls,
            isNot(contains('resetAllSyncCursors')),
            reason: 'premise: still inside the first stop',
          );
          expect(done, isFalse, reason: 'premise: the deadline is not up');
        }

        // The second stop joins the same stop in flight: it gets no budget of
        // its own. The whole wait is one budget.
        async.elapse(const Duration(seconds: 1));

        expect(
          done,
          isTrue,
          reason: 'the key waited a second budget for a stop that had already '
              'had one — a user who kills the app meanwhile keeps it',
        );
        expect(
          async.pendingTimers,
          isEmpty,
          reason: 'the deadline outlived the logout',
        );
        expect(engine.stopCalls, liveSyncEnabled ? 2 : 0);
        expect(circle.methodCalls, contains('wipeAllMlsState'));
        expect(identity.deleteCallCount, 1);
        container.dispose();
      });
    });

    test("a stop given up on drops the deleted identity's handlers: none "
        "reaches the next identity's cache", () {
      // The engine's stop waits on its lifecycle lock, unbounded, and the
      // logout gives up on it. A handler parked across the logout and the
      // login must find its identity ended, and the old core must deliver
      // nothing more, although the stop never returned.
      SharedPreferences.setMockInitialValues({});
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            ..allMessagesHandler = (_, _, _) async => null;
      addTearDown(() => messenger.allMessagesHandler = null);
      fakeAsync((async) {
        final circleServices = <MockCircleService>[];
        late ProviderContainer container;
        final circle = TestCircleFactory.createCircle(
          nostrGroupId: const [1, 2, 3],
          mlsGroupId: const [9, 9, 9],
        );
        final t0 = DateTime.utc(2026, 10, 15, 12);
        final parsing = Completer<void>();
        final engine = FakeLiveSyncEngine();
        final router = LiveEventRouter(
          circleService: () => container.read(circleServiceProvider),
          circlesSnapshot: () async => [circle],
          secretBytes: () async => const [],
          parseLocation: (_, sender) async {
            await parsing.future;
            return DecryptedLocation(
              senderPubkey: sender,
              latitude: 1,
              longitude: 2,
              geohash: 'g',
              timestamp: t0,
              expiresAt: t0.add(const Duration(days: 3650)),
            );
          },
          ingestLocation: (circle, decrypted) => container
              .read(locationSharingServiceProvider)
              .ingestStreamedLocation(circle: circle, decrypted: decrypted),
          reconcileRoster: (_) async {},
          onLocationsChanged: () {},
          onGroupUpdated: (_) {},
          onInvitationReceived: () {},
          onStatus: (_) {},
        );
        final service = NostrSubscriptionService(
          router: router,
          engineFactory: () async => engine,
        );
        container = ProviderContainer(
          overrides: [
            identityServiceProvider.overrideWithValue(
              _MockIdentityService(
                initialIdentity: createdIdentity,
                deleteClears: true,
                createResult: importedIdentity,
              ),
            ),
            circleServiceProvider.overrideWith((ref) {
              final service = MockCircleService();
              circleServices.add(service);
              return service;
            }),
            subscriptionServiceProvider.overrideWithValue(service),
            liveEventRouterProvider.overrideWithValue(router),
          ],
        );
        unawaited(service.start(groups: const [], inboxRelays: const []));
        async.flushMicrotasks();
        engine
          ..stopGate = Completer<void>()
          ..controller.add(
            FfiRelayEvent(
              kind: FfiRelayEventKind.location,
              nostrGroupId: Uint8List.fromList(circle.nostrGroupId),
              senderPubkey: 'a-peer-of-the-first-identity',
              content: '{}',
            ),
          );
        async.flushMicrotasks();

        final notifier = container.read(identityNotifierProvider.notifier);
        var loggedOut = false;
        unawaited(notifier.deleteIdentity().then((_) => loggedOut = true));
        async
          ..elapse(kLiveSyncRestartBudget)
          ..flushMicrotasks();
        expect(loggedOut, isTrue, reason: 'premise: the logout gave up');
        unawaited(notifier.createIdentity());
        async.flushMicrotasks();
        parsing.complete();
        // The old core is still up, its stop unanswered: what it delivers
        // after the login arrives under the next identity.
        if (!engine.controller.isClosed) {
          engine.controller.add(
            FfiRelayEvent(
              kind: FfiRelayEventKind.location,
              nostrGroupId: Uint8List.fromList(circle.nostrGroupId),
              senderPubkey: 'another-peer-of-the-first-identity',
              content: '{}',
            ),
          );
        }
        async
          ..elapse(Duration.zero)
          ..flushMicrotasks();

        if (liveSyncEnabled) {
          expect(
            container
                .read(locationSharingServiceProvider)
                .debugCachedLocationCount,
            0,
            reason: "a coordinate of the deleted identity's peer was merged "
                "into the next identity's cache",
          );
          expect(
            [
              for (final circles in circleServices)
                ...circles.methodCalls.where(
                  (c) => c == 'upsertLastKnownLocation',
                ),
            ],
            isEmpty,
            reason: "and written to the next identity's store",
          );
        } else {
          expect(engine.stopCalls, 0, reason: 'the flag-off logout stops none');
        }
        container.dispose();
      });
    });

    test('leaves no deadline behind when the engine stops at once', () {
      SharedPreferences.setMockInitialValues({});
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            ..allMessagesHandler = (_, _, _) async => null;
      addTearDown(() => messenger.allMessagesHandler = null);
      fakeAsync((async) {
        final circle = MockCircleService();
        final engine = _RecordingSubscriptionService(sharedLog: []);
        final container = ProviderContainer(
          overrides: [
            identityServiceProvider.overrideWithValue(
              _MockIdentityService(
                initialIdentity: createdIdentity,
                deleteClears: true,
              ),
            ),
            circleServiceProvider.overrideWithValue(circle),
            subscriptionServiceProvider.overrideWithValue(engine),
          ],
        );
        var done = false;
        unawaited(
          container
              .read(identityNotifierProvider.notifier)
              .deleteIdentity()
              .then((_) => done = true),
        );
        async.flushMicrotasks();

        expect(done, isTrue);
        expect(engine.stopCalls, liveSyncEnabled ? 2 : 0);
        // Riverpod's zero-delay refresh of what the logout invalidated.
        async.elapse(Duration.zero);
        expect(
          async.pendingTimers,
          isEmpty,
          reason: 'a 65 s timer left running after a logout that is over',
        );
        container.dispose();
      });
    });
  });

  // One container lives for the process. Whatever a provider read while it
  // was built — the circle service, a relay list, the own pubkey — is the
  // PREVIOUS identity's after a logout and a login, unless it is rebuilt.
  group('a logout, then a login as someone else, in one process', () {
    const firstInbox = ['wss://inbox.private.first.example'];
    const secondInbox = ['wss://inbox.second.example'];

    /// A container whose circle service is a NEW instance at every build, as
    /// the production one is, and whose relay preferences are that
    /// instance's: the first identity's list is customised.
    ({
      ProviderContainer container,
      List<MockCircleService> circleServices,
      _MockIdentityService identity,
    })
    scope({
      List<Override> overrides = const [],
      MockCircleService Function() circleService = MockCircleService.new,
    }) {
      SharedPreferences.setMockInitialValues({});
      final circleServices = <MockCircleService>[];
      final identity = _MockIdentityService(
        initialIdentity: createdIdentity,
        deleteClears: true,
        createResult: importedIdentity,
      );
      final container = ProviderContainer(
        overrides: [
          identityServiceProvider.overrideWithValue(identity),
          circleServiceProvider.overrideWith((ref) {
            final service = circleService();
            circleServices.add(service);
            return service;
          }),
          relayPreferencesServiceProvider.overrideWith((ref) async {
            final first = identical(
              ref.read(circleServiceProvider),
              circleServices.first,
            );
            return MockRelayPreferencesService(
              initialRelays: {
                RelayCategory.inbox: first ? firstInbox : secondInbox,
              },
            );
          }),
          ...overrides,
        ],
      );
      addTearDown(container.dispose);
      return (
        container: container,
        circleServices: circleServices,
        identity: identity,
      );
    }

    test("the second identity's inbox REQ is issued on its own relay list",
        () async {
      final (:container, :circleServices, identity: _) = scope();
      final notifier = container.read(identityNotifierProvider.notifier);
      expect(
        await container.read(inboxRelaysProvider.future),
        firstInbox,
        reason: 'premise: the first identity customised its inbox list',
      );

      await notifier.deleteIdentity();
      // Logged out, the shell is still mounted and a heal tick still reads
      // the list.
      await container.read(inboxRelaysProvider.future);
      await notifier.createIdentity();

      expect(
        await container.read(inboxRelaysProvider.future),
        secondInbox,
        reason: "the new npub's gift-wrap REQ went to the previous "
            "identity's private inbox relay: the two are linked there, and "
            'it listens where nobody sends its Welcomes',
      );
      expect(circleServices, hasLength(2), reason: 'on a fresh circle service');
    });

    test('a logout drops what was built from the identity, before any login',
        () async {
      final held = TestCircleFactory.createCircle(
        nostrGroupId: const [4, 5, 6],
        mlsGroupId: const [7, 7, 7],
      );
      final (:container, :circleServices, identity: _) = scope(
        circleService: () => _WipedCircleService(held),
      );
      await container.read(inboxRelaysProvider.future);
      expect(
        await container.read(circlesProvider.future),
        [held],
        reason: "premise: the identity's circle list was read",
      );
      final sharing = container.read(locationSharingServiceProvider);

      await container.read(identityNotifierProvider.notifier).deleteIdentity();

      expect(
        container.read(locationSharingServiceProvider),
        isNot(same(sharing)),
        reason: 'the service that cached the deleted pubkey is still the one '
            'in use',
      );
      // Settled values only: the refresh the logout's invalidation began
      // carries the previous list until the wiped service answers.
      final yielded = <List<Circle>>[];
      container.listen<AsyncValue<List<Circle>>>(circlesProvider, (_, next) {
        if (next is AsyncData<List<Circle>> && !next.isLoading) {
          yielded.add(next.value);
        }
      }, fireImmediately: true);
      yielded.add(await container.read(circlesProvider.future));
      expect(
        yielded.where((circles) => circles.contains(held)),
        isEmpty,
        reason: "the deleted identity's circle list was served after the "
            'logout',
      );
      expect(
        (circleServices.single as _WipedCircleService).readsAfterWipe,
        isPositive,
        reason: 'the circle list after the logout was not read from the '
            'wiped service',
      );
      expect(
        circleServices,
        hasLength(1),
        reason: 'the circle service itself is NOT retired by a logout: it '
            'stays as the wiped, latched instance until a login',
      );
    });

    test('a location still in its handler at the logout reaches no cache, '
        'then or after the login', () async {
      // A handler outlives the stop. One parked before the ingest, across
      // the logout AND the login: the service it would reach by then is the
      // next identity's, open and empty.
      late final LiveEventRouter router;
      final (:container, :circleServices, identity: _) = scope(
        overrides: [liveEventRouterProvider.overrideWith((_) => router)],
      );
      final notifier = container.read(identityNotifierProvider.notifier);
      final circle = TestCircleFactory.createCircle(
        nostrGroupId: const [1, 2, 3],
        mlsGroupId: const [9, 9, 9],
      );
      final t0 = DateTime.now();
      final parsing = Completer<void>();
      final engine = FakeLiveSyncEngine();
      final service = NostrSubscriptionService(
        router: router = LiveEventRouter(
          circleService: () => container.read(circleServiceProvider),
          circlesSnapshot: () async => [circle],
          secretBytes: () async => const [],
          parseLocation: (_, sender) async {
            await parsing.future;
            return DecryptedLocation(
              senderPubkey: sender,
              latitude: 1,
              longitude: 2,
              geohash: 'g',
              timestamp: t0,
              expiresAt: t0.add(const Duration(hours: 1)),
            );
          },
          // The production wiring's own closure.
          ingestLocation: (circle, decrypted) => container
              .read(locationSharingServiceProvider)
              .ingestStreamedLocation(circle: circle, decrypted: decrypted),
          reconcileRoster: (_) async {},
          onLocationsChanged: () {},
          onGroupUpdated: (_) {},
          onInvitationReceived: () {},
          onStatus: (_) {},
        ),
        engineFactory: () async => engine,
      );
      await service.start(groups: const [], inboxRelays: const []);
      engine.controller.add(
        FfiRelayEvent(
          kind: FfiRelayEventKind.location,
          nostrGroupId: Uint8List.fromList(circle.nostrGroupId),
          senderPubkey: 'a-peer-of-the-first-identity',
          content: '{}',
        ),
      );
      await pumpEventQueue();

      // The logout's own stop, then the logout and the login.
      await service.stop();
      await notifier.deleteIdentity();
      await notifier.createIdentity();
      parsing.complete();
      await pumpEventQueue();

      expect(
        container.read(locationSharingServiceProvider).debugCachedLocationCount,
        0,
        reason: "a coordinate of the deleted identity's peer was merged into "
            "the next identity's cache",
      );
      expect(
        [
          for (final circles in circleServices)
            ...circles.methodCalls.where((c) => c == 'upsertLastKnownLocation'),
        ],
        isEmpty,
        reason: "and written to the next identity's store",
      );
    });

    test('a location the engine delivered, mid-write at the logout, is not '
        'merged behind the wipe', () async {
      // Through the chain a live location takes: engine stream, router,
      // the production ingest closure, the location service, its store.
      late final LiveEventRouter router;
      final park = Completer<void>();
      final (:container, :circleServices, identity: _) = scope(
        overrides: [liveEventRouterProvider.overrideWith((_) => router)],
        circleService: () => _ParkedUpsertCircle()..park = park,
      );
      final circle = TestCircleFactory.createCircle(
        nostrGroupId: const [1, 2, 3],
        mlsGroupId: const [9, 9, 9],
      );
      final t0 = DateTime.now();
      final engine = FakeLiveSyncEngine();
      final service = NostrSubscriptionService(
        router: router = LiveEventRouter(
          circleService: () => container.read(circleServiceProvider),
          circlesSnapshot: () async => [circle],
          secretBytes: () async => const [],
          parseLocation: (_, sender) async => DecryptedLocation(
            senderPubkey: sender,
            latitude: 1,
            longitude: 2,
            geohash: 'g',
            timestamp: t0,
            expiresAt: t0.add(const Duration(hours: 1)),
          ),
          ingestLocation: (circle, decrypted) => container
              .read(locationSharingServiceProvider)
              .ingestStreamedLocation(circle: circle, decrypted: decrypted),
          reconcileRoster: (_) async {},
          onLocationsChanged: () {},
          onGroupUpdated: (_) {},
          onInvitationReceived: () {},
          onStatus: (_) {},
        ),
        engineFactory: () async => engine,
      );
      final used = container.read(locationSharingServiceProvider);
      await service.start(groups: const [], inboxRelays: const []);
      engine.controller.add(
        FfiRelayEvent(
          kind: FfiRelayEventKind.location,
          nostrGroupId: Uint8List.fromList(circle.nostrGroupId),
          senderPubkey: 'a-peer-of-the-first-identity',
          content: '{}',
        ),
      );
      await pumpEventQueue();
      expect(
        (circleServices.single as _ParkedUpsertCircle).upserts,
        1,
        reason: 'premise: parked inside the write',
      );

      await service.stop();
      await container.read(identityNotifierProvider.notifier).deleteIdentity();
      park.complete();
      await pumpEventQueue();

      expect(
        used.debugCachedLocationCount,
        0,
        reason: "a coordinate of the deleted identity's peer went back into "
            'the cache the logout had just wiped',
      );
      expect(
        container.read(locationSharingServiceProvider).debugCachedLocationCount,
        0,
      );
    });

    test('a location mid-write at the logout is not merged behind the wipe',
        () async {
      // The other half: a handler already inside the ingest when the wipe
      // clears the cache. It belongs to a session that was still live when
      // it entered.
      final (:container, circleServices: _, identity: _) = scope();
      final store = _ParkedUpsertCircle()..park = Completer<void>();
      final sharing = LocationSharingService(
        circleService: store,
        relayService: MockRelayService(),
      );
      final circle = TestCircleFactory.createCircle(
        nostrGroupId: const [1, 2, 3],
        mlsGroupId: const [9, 9, 9],
      );
      final t0 = DateTime.now();
      final ingesting = sharing.ingestStreamedLocation(
        circle: circle,
        decrypted: DecryptedLocation(
          senderPubkey: 'a-peer-of-the-first-identity',
          latitude: 1,
          longitude: 2,
          geohash: 'g',
          timestamp: t0,
          expiresAt: t0.add(const Duration(hours: 1)),
        ),
      );
      await pumpEventQueue();
      expect(store.upserts, 1, reason: 'premise: parked inside the write');

      await sharing.wipeAll();
      store.park!.complete();
      await ingesting;

      expect(
        sharing.debugCachedLocationCount,
        0,
        reason: "a coordinate of the deleted identity's peer went back into "
            'the cache the wipe had just cleared',
      );
      expect(await sharing.cachedLocations(circle), isEmpty);
      // And a logout does call that wipe, on the service in use.
      final used = container.read(locationSharingServiceProvider);
      await container.read(identityNotifierProvider.notifier).deleteIdentity();
      expect(
        await used.cachedLocations(circle),
        isEmpty,
        reason: 'the service a logout wiped still takes writes',
      );
      await used.ingestStreamedLocation(
        circle: circle,
        decrypted: DecryptedLocation(
          senderPubkey: 'a-peer-of-the-first-identity',
          latitude: 1,
          longitude: 2,
          geohash: 'g',
          timestamp: t0,
          expiresAt: t0.add(const Duration(hours: 1)),
        ),
      );
      expect(used.debugCachedLocationCount, 0);
    });

    test('a resume dispatched during the logout does not reopen the cache '
        'the wipe closed', () async {
      // The shell stays mounted through a logout, and its resume handler
      // opens the cache first thing. Between the wipe and the end of the
      // logout — milliseconds, or the stops' whole bound with a wedged engine
      // — a shade pull is enough.
      final store = _ParkedUpsertCircle()..park = Completer<void>();
      final sharing = LocationSharingService(
        circleService: store,
        relayService: MockRelayService(),
      );
      final circle = TestCircleFactory.createCircle(
        nostrGroupId: const [1, 2, 3],
        mlsGroupId: const [9, 9, 9],
      );
      final t0 = DateTime.now();
      final ingesting = sharing.ingestStreamedLocation(
        circle: circle,
        decrypted: DecryptedLocation(
          senderPubkey: 'a-peer-of-the-first-identity',
          latitude: 1,
          longitude: 2,
          geohash: 'g',
          timestamp: t0,
          expiresAt: t0.add(const Duration(hours: 1)),
        ),
      );
      await pumpEventQueue();
      expect(store.upserts, 1, reason: 'premise: parked inside the write');

      await sharing.wipeAll();
      sharing.onAppResumed();
      store.park!.complete();
      await ingesting;

      expect(
        sharing.debugCachedLocationCount,
        0,
        reason: "a coordinate of the deleted identity's peer was merged into "
            'a cache the wipe had closed and a resume reopened',
      );
      expect(await sharing.cachedLocations(circle), isEmpty);
    });

    test("a wiped location service hands neither identity's location to its "
        'store', () async {
      // Before: it was read off the self-echo filter — the deleted identity's
      // cached pubkey must not make the next one's own location a peer's.
      // Now nothing of either reaches the wiped instance's store at all.
      SharedPreferences.setMockInitialValues({});
      final identity = _MockIdentityService(
        initialIdentity: createdIdentity,
        deleteClears: true,
        createResult: importedIdentity,
      );
      final store = _ParkedUpsertCircle();
      final sharing = LocationSharingService(
        circleService: store,
        relayService: MockRelayService(),
        identityService: identity,
      );
      final circle = TestCircleFactory.createCircle(
        nostrGroupId: const [1, 2, 3],
        mlsGroupId: const [9, 9, 9],
      );
      final t0 = DateTime.now();
      Future<void> streamFrom(String sender) => sharing.ingestStreamedLocation(
        circle: circle,
        decrypted: DecryptedLocation(
          senderPubkey: sender,
          latitude: 1,
          longitude: 2,
          geohash: 'g',
          timestamp: t0,
          expiresAt: t0.add(const Duration(hours: 1)),
        ),
      );
      await streamFrom(createdIdentity.pubkeyHex);
      expect(store.upserts, 0, reason: 'premise: dropped as an own echo');

      await sharing.wipeAll();
      await identity.deleteIdentity();
      await identity.createIdentity();

      await streamFrom(importedIdentity.pubkeyHex);
      await streamFrom(createdIdentity.pubkeyHex);
      await streamFrom('a-peer-of-the-first-identity');
      expect(
        store.upserts,
        0,
        reason: 'the wiped service persisted a location after the logout',
      );
      expect(sharing.debugCachedLocationCount, 0);
    });

    test("a streamed Welcome reaches the second identity's circle service",
        () async {
      final (:container, :circleServices, identity: _) = scope();
      final notifier = container.read(identityNotifierProvider.notifier);
      final router = container.read(liveEventRouterProvider);

      await notifier.deleteIdentity();
      await notifier.createIdentity();
      await router.handleEvent(
        const FfiRelayEvent(
          kind: FfiRelayEventKind.welcome,
          giftWrapJson: '{}',
        ),
      );

      expect(
        circleServices.last.methodCalls,
        contains('processGiftWrappedInvitation'),
        reason: 'the Welcome was handed to the wiped service of the '
            'previous identity, which refuses it',
      );
      expect(
        circleServices.first.methodCalls,
        isNot(contains('processGiftWrappedInvitation')),
      );
    });

    test("the location pipeline is the second identity's: its store, and "
        'its own pubkey for the self-echo', () async {
      final (:container, :circleServices, identity: _) = scope();
      final notifier = container.read(identityNotifierProvider.notifier);
      final circle = TestCircleFactory.createCircle(
        nostrGroupId: const [1, 2, 3],
        mlsGroupId: const [9, 9, 9],
      );
      final t0 = DateTime.now();
      DecryptedLocation from(String sender) => DecryptedLocation(
        senderPubkey: sender,
        latitude: 1,
        longitude: 2,
        geohash: 'g',
        timestamp: t0,
        expiresAt: t0.add(const Duration(hours: 1)),
      );
      // The first identity's service learns its own pubkey.
      await container
          .read(locationSharingServiceProvider)
          .ingestStreamedLocation(
            circle: circle,
            decrypted: from(createdIdentity.pubkeyHex),
          );

      await notifier.deleteIdentity();
      await notifier.createIdentity();
      final sharing = container.read(locationSharingServiceProvider);
      await sharing.ingestStreamedLocation(
        circle: circle,
        decrypted: from(importedIdentity.pubkeyHex),
      );
      expect(
        sharing.debugCachedLocationCount,
        0,
        reason: "the second identity's own location was shown as a peer's: "
            'the self-echo filter still holds the first pubkey',
      );
      await sharing.ingestStreamedLocation(
        circle: circle,
        decrypted: from(createdIdentity.pubkeyHex),
      );
      expect(
        sharing.debugCachedLocationCount,
        1,
        reason: 'the first identity is a peer like any other now',
      );
      expect(
        circleServices.last.methodCalls,
        contains('upsertLastKnownLocation'),
        reason: 'last-known persistence went to the wiped service',
      );
    });
  });

  // ---------------------------------------------------------------------------
  // deleteIdentity — cancel prefetch before wipe
  //
  // Verifies that tilePrefetchServiceProvider.cancel() is called BEFORE
  // service.deleteIdentity(), preventing in-flight tile GETs from writing to
  // the encrypted cache after the identity is wiped.
  // ---------------------------------------------------------------------------

  group('IdentityNotifier.deleteIdentity — cancel prefetch ordering', () {
    test(
      'cancel() is called on tilePrefetchServiceProvider before deleteIdentity',
      () async {
        // Spy service that records call order.
        final spy = _SpyPrefetchService();
        final mockService = _MockIdentityService(
          initialIdentity: createdIdentity,
          deleteClears: true,
          onDelete: spy.recordDeleteCall,
        );
        final container = ProviderContainer(
          overrides: [
            identityServiceProvider.overrideWithValue(mockService),
            circleServiceProvider.overrideWithValue(MockCircleService()),
            tilePrefetchServiceProvider.overrideWithValue(spy),
          ],
        );
        addTearDown(container.dispose);

        await container
            .read(identityNotifierProvider.notifier)
            .deleteIdentity();

        expect(
          spy.cancelCalled,
          isTrue,
          reason: 'cancel() must be called during deleteIdentity',
        );
        expect(
          spy.cancelBeforeDelete,
          isTrue,
          reason:
              'cancel() must be called BEFORE service.deleteIdentity() '
              'so no in-flight prefetch burst writes tiles after the wipe',
        );
      },
    );
  });

  // ---------------------------------------------------------------------------
  // M10.1 — durable pending-wipe marker in deleteIdentity
  //
  // Verifies the crash-safe SET-before / CLEAR-after marker ordering in the
  // logout path.
  //
  // (a) marker is SET (true) before wipeAllMlsState is attempted
  // (b) marker is CLEARED (false) after a successful wipe
  // (c) marker is left SET when wipeAllMlsState throws
  // ---------------------------------------------------------------------------

  group('IdentityNotifier.deleteIdentity — M10.1 pending-wipe marker', () {
    setUp(() {
      // Reset SharedPreferences fake between tests so one test's state does not
      // leak into the next.
      SharedPreferences.setMockInitialValues({});
    });

    test(
      '(a) pending-wipe marker is true BEFORE wipeAllMlsState is attempted',
      () async {
        // Use a circle service that records when the marker was written
        // relative to when wipe runs by capturing the prefs state AT the
        // moment wipeAllMlsState is called.
        bool? markerAtWipeTime;
        final capturingCircle = _CapturingWipeMockCircleService(
          onWipe: () async {
            final prefs = await SharedPreferences.getInstance();
            markerAtWipeTime = prefs.getBool(kPendingMlsWipeKey);
          },
        );
        final mockService = _MockIdentityService(
          initialIdentity: createdIdentity,
          deleteClears: true,
        );
        final container = ProviderContainer(
          overrides: [
            identityServiceProvider.overrideWithValue(mockService),
            circleServiceProvider.overrideWithValue(capturingCircle),
          ],
        );
        addTearDown(container.dispose);

        await container.read(identityNotifierProvider.notifier).deleteIdentity();

        expect(
          markerAtWipeTime,
          isTrue,
          reason:
              '(a) pending-wipe marker must be SET to true before '
              'wipeAllMlsState is called',
        );
      },
    );

    test(
      '(b) pending-wipe marker is false after a successful wipe',
      () async {
        final mockService = _MockIdentityService(
          initialIdentity: createdIdentity,
          deleteClears: true,
        );
        final container = ProviderContainer(
          overrides: [
            identityServiceProvider.overrideWithValue(mockService),
            circleServiceProvider.overrideWithValue(MockCircleService()),
          ],
        );
        addTearDown(container.dispose);

        await container.read(identityNotifierProvider.notifier).deleteIdentity();

        final prefs = await SharedPreferences.getInstance();
        expect(
          prefs.getBool(kPendingMlsWipeKey),
          isFalse,
          reason:
              '(b) pending-wipe marker must be CLEARED after a successful wipe',
        );
      },
    );

    test(
      '(c) pending-wipe marker stays true when wipeAllMlsState throws',
      () async {
        final throwingCircle = _ThrowingWipeMockCircleService2();
        final mockService = _MockIdentityService(
          initialIdentity: createdIdentity,
          deleteClears: true,
        );
        final container = ProviderContainer(
          overrides: [
            identityServiceProvider.overrideWithValue(mockService),
            circleServiceProvider.overrideWithValue(throwingCircle),
          ],
        );
        addTearDown(container.dispose);

        // deleteIdentity is best-effort: it must complete even if the wipe
        // throws.
        await container.read(identityNotifierProvider.notifier).deleteIdentity();

        final prefs = await SharedPreferences.getInstance();
        expect(
          prefs.getBool(kPendingMlsWipeKey),
          isTrue,
          reason:
              '(c) pending-wipe marker must remain SET when wipeAllMlsState '
              'throws so the next launch retries',
        );
      },
    );

    test(
      'deleteIdentity still completes when wipeAllMlsState throws',
      () async {
        // The wipe throwing must not abort logout — deleteIdentity is always
        // best-effort. (The marker-write best-effort path is exercised
        // separately in pending_mls_wipe_service_test.dart with a throwing
        // SharedPreferences; here the fake prefs never fails.)
        final throwingCircle = _ThrowingWipeMockCircleService2();
        final mockService = _MockIdentityService(
          initialIdentity: createdIdentity,
          deleteClears: true,
        );
        final container = ProviderContainer(
          overrides: [
            identityServiceProvider.overrideWithValue(mockService),
            circleServiceProvider.overrideWithValue(throwingCircle),
          ],
        );
        addTearDown(container.dispose);

        // Must not throw.
        await expectLater(
          container.read(identityNotifierProvider.notifier).deleteIdentity(),
          completes,
        );
      },
    );
  });

  // ---------------------------------------------------------------------------
  // Identity-delete residue fix — every promise `identityAdvancedDeleteBody`
  // makes ("This deletes your identity and all circle data from this phone")
  // must be backed by a test that fails if the corresponding clear is
  // removed. Each group below pins ONE such promise.
  // ---------------------------------------------------------------------------

  group('IdentityNotifier.deleteIdentity — pending-leave markers', () {
    test(
      'kPendingLeaveKey becomes entirely absent (not merely emptied)',
      () async {
        SharedPreferences.setMockInitialValues({
          kPendingLeaveKey: <String>['aa' * 16],
        });
        final mockService = _MockIdentityService(
          initialIdentity: createdIdentity,
          deleteClears: true,
        );
        final container = ProviderContainer(
          overrides: [
            identityServiceProvider.overrideWithValue(mockService),
            circleServiceProvider.overrideWithValue(MockCircleService()),
          ],
        );
        addTearDown(container.dispose);

        await container
            .read(identityNotifierProvider.notifier)
            .deleteIdentity();

        final prefs = await SharedPreferences.getInstance();
        expect(
          prefs.containsKey(kPendingLeaveKey),
          isFalse,
          reason:
              'a durable leave-in-progress marker records the PUBLIC '
              'nostr_group_id of a circle this identity belonged to — it '
              'must not survive "delete my identity and all circle data"',
        );
      },
    );

    test(
      'kPendingLeaveKey is cleared AFTER wipeAllMlsState, not before',
      () async {
        // There is nothing left to resume once every local MLS group is
        // destroyed and the signing secret is gone — clearing the marker
        // any earlier would risk losing durable leave-in-progress intent
        // while the state it refers to might still exist.
        SharedPreferences.setMockInitialValues({
          kPendingLeaveKey: <String>['aa' * 16],
        });
        final capturingCircle = _CapturingWipePendingLeaveMockCircleService();
        final mockService = _MockIdentityService(
          initialIdentity: createdIdentity,
          deleteClears: true,
        );
        final container = ProviderContainer(
          overrides: [
            identityServiceProvider.overrideWithValue(mockService),
            circleServiceProvider.overrideWithValue(capturingCircle),
          ],
        );
        addTearDown(container.dispose);

        await container
            .read(identityNotifierProvider.notifier)
            .deleteIdentity();

        expect(
          capturingCircle.pendingLeaveKeyPresentAtWipeTime,
          isTrue,
          reason:
              'the pending-leave marker must still be present WHILE '
              'wipeAllMlsState runs — proving the clear happens strictly '
              'after it, not before',
        );
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.containsKey(kPendingLeaveKey), isFalse);
      },
    );
  });

  group(
    'IdentityNotifier.deleteIdentity — background publish-history residue',
    () {
      test('clears kBackgroundLastPublishMsKey', () async {
        SharedPreferences.setMockInitialValues({
          kBackgroundLastPublishMsKey: DateTime.now().millisecondsSinceEpoch,
        });
        final mockService = _MockIdentityService(
          initialIdentity: createdIdentity,
          deleteClears: true,
        );
        final container = ProviderContainer(
          overrides: [
            identityServiceProvider.overrideWithValue(mockService),
            circleServiceProvider.overrideWithValue(MockCircleService()),
          ],
        );
        addTearDown(container.dispose);

        await container
            .read(identityNotifierProvider.notifier)
            .deleteIdentity();

        final prefs = await SharedPreferences.getInstance();
        expect(
          prefs.containsKey(kBackgroundLastPublishMsKey),
          isFalse,
          reason:
              'the wall-clock time of the deleted identity\'s last location '
              'transmission must not survive "delete my identity"',
        );
      });

      test('clears kBackgroundSessionReclaimAtMsKey', () async {
        SharedPreferences.setMockInitialValues({
          kBackgroundSessionReclaimAtMsKey:
              DateTime.now().millisecondsSinceEpoch,
        });
        final mockService = _MockIdentityService(
          initialIdentity: createdIdentity,
          deleteClears: true,
        );
        final container = ProviderContainer(
          overrides: [
            identityServiceProvider.overrideWithValue(mockService),
            circleServiceProvider.overrideWithValue(MockCircleService()),
          ],
        );
        addTearDown(container.dispose);

        await container
            .read(identityNotifierProvider.notifier)
            .deleteIdentity();

        final prefs = await SharedPreferences.getInstance();
        expect(
          prefs.containsKey(kBackgroundSessionReclaimAtMsKey),
          isFalse,
        );
      });
    },
  );

  group(
    'IdentityNotifier.deleteIdentity — background scheduling coordination '
    'keys (M7-A, full container)',
    () {
      test(
        'clears kBackgroundIdleKey and kForegroundActiveAtMsKey via '
        'disableBackgroundScheduling',
        () async {
          SharedPreferences.setMockInitialValues({
            kBackgroundIdleKey: false,
            kForegroundActiveAtMsKey: DateTime.now().millisecondsSinceEpoch,
          });
          final mockService = _MockIdentityService(
            initialIdentity: createdIdentity,
            deleteClears: true,
          );
          final container = ProviderContainer(
            overrides: [
              identityServiceProvider.overrideWithValue(mockService),
              circleServiceProvider.overrideWithValue(MockCircleService()),
            ],
          );
          addTearDown(container.dispose);

          await container
              .read(identityNotifierProvider.notifier)
              .deleteIdentity();

          final prefs = await SharedPreferences.getInstance();
          expect(
            prefs.containsKey(kBackgroundIdleKey),
            isFalse,
            reason:
                'deleteIdentity must call disableBackgroundScheduling, which '
                'removes kBackgroundIdleKey',
          );
          expect(
            prefs.containsKey(kForegroundActiveAtMsKey),
            isFalse,
            reason:
                'deleteIdentity must call disableBackgroundScheduling, which '
                'removes kForegroundActiveAtMsKey',
          );
        },
      );
    },
  );

  group(
    'IdentityNotifier.deleteIdentity — locationSharingService.wipeAll() '
    'wiring',
    () {
      test(
        'wipeAll() reaches the circle service (wipeAllLastKnownLocations is '
        'called)',
        () async {
          // locationSharingServiceProvider is not overridden in this test —
          // it composes the SAME circleServiceProvider override, so an
          // observed wipeAllLastKnownLocations() call proves deleteIdentity
          // actually invoked locationSharingServiceProvider.wipeAll()
          // end-to-end, not merely that the provider exists.
          final mockService = _MockIdentityService(
            initialIdentity: createdIdentity,
            deleteClears: true,
          );
          final mockCircle = MockCircleService();
          final container = ProviderContainer(
            overrides: [
              identityServiceProvider.overrideWithValue(mockService),
              circleServiceProvider.overrideWithValue(mockCircle),
            ],
          );
          addTearDown(container.dispose);

          await container
              .read(identityNotifierProvider.notifier)
              .deleteIdentity();

          expect(
            mockCircle.methodCalls,
            contains('wipeAllLastKnownLocations'),
            reason:
                'deleteIdentity must call '
                'locationSharingServiceProvider.wipeAll(), which wipes '
                'every persisted last-known-location row via the circle '
                'service',
          );
        },
      );
    },
  );

  // ---------------------------------------------------------------------------
  // M10.1 — reconcile a pending wipe BEFORE a new identity writes circle state
  //
  // A marker left set by a prior failed logout must be resolved when a NEW
  // identity is created, otherwise a later launch would honour the stale marker
  // and wipe the new identity's live MLS data. createIdentity/importFromNsec
  // run the wipe-then-clear up front to prevent that data loss.
  // ---------------------------------------------------------------------------

  group('IdentityNotifier — M10.1 reconcile pending wipe on new identity', () {
    test(
      'createIdentity completes a pending wipe and clears the marker before '
      'provisioning the new identity',
      () async {
        SharedPreferences.setMockInitialValues({kPendingMlsWipeKey: true});
        final wipeCircle = MockCircleService();
        final mockService = _MockIdentityService(
          initialIdentity: null,
          createResult: createdIdentity,
        );
        final container = ProviderContainer(
          overrides: [
            identityServiceProvider.overrideWithValue(mockService),
            circleServiceProvider.overrideWithValue(wipeCircle),
          ],
        );
        addTearDown(container.dispose);

        await container.read(identityNotifierProvider.notifier).createIdentity();

        expect(
          wipeCircle.methodCalls,
          contains('wipeAllMlsState'),
          reason: 'a pending wipe must be completed before the new identity '
              'writes any circle state',
        );
        final prefs = await SharedPreferences.getInstance();
        expect(
          prefs.getBool(kPendingMlsWipeKey),
          isFalse,
          reason: 'the marker must be cleared so a later launch cannot wipe the '
              "new identity's data",
        );
      },
    );

    test(
      'createIdentity does NOT wipe when no wipe is pending',
      () async {
        SharedPreferences.setMockInitialValues(<String, Object>{});
        final wipeCircle = MockCircleService();
        final mockService = _MockIdentityService(
          initialIdentity: null,
          createResult: createdIdentity,
        );
        final container = ProviderContainer(
          overrides: [
            identityServiceProvider.overrideWithValue(mockService),
            circleServiceProvider.overrideWithValue(wipeCircle),
          ],
        );
        addTearDown(container.dispose);

        await container.read(identityNotifierProvider.notifier).createIdentity();

        expect(
          wipeCircle.methodCalls,
          isNot(contains('wipeAllMlsState')),
          reason: 'no pending marker → normal identity creation must not wipe',
        );
      },
    );

    test(
      'importFromNsec also reconciles a pending wipe before importing',
      () async {
        SharedPreferences.setMockInitialValues({kPendingMlsWipeKey: true});
        final wipeCircle = MockCircleService();
        final mockService = _MockIdentityService(
          initialIdentity: null,
          importResult: importedIdentity,
        );
        final container = ProviderContainer(
          overrides: [
            identityServiceProvider.overrideWithValue(mockService),
            circleServiceProvider.overrideWithValue(wipeCircle),
          ],
        );
        addTearDown(container.dispose);

        await container
            .read(identityNotifierProvider.notifier)
            .importFromNsec('nsec1validplaceholder');

        expect(wipeCircle.methodCalls, contains('wipeAllMlsState'));
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getBool(kPendingMlsWipeKey), isFalse);
      },
    );

    test(
      'createIdentity FAILS CLOSED when the pending wipe cannot be completed — '
      'no new identity is provisioned over unwiped old state',
      () async {
        // Marker set + the wipe THROWS → the marker stays set → the reconcile
        // reports the slate as UNCLEAN → createIdentity must refuse (no
        // service.createIdentity), surface an error, and keep the marker set
        // for a later retry. Without the fail-closed check a new identity would
        // be provisioned over the old (possibly-decryptable) circles.db.
        SharedPreferences.setMockInitialValues({kPendingMlsWipeKey: true});
        final failingWipe = _ThrowingWipeMockCircleService2();
        final mockService = _MockIdentityService(
          initialIdentity: null,
          createResult: createdIdentity,
        );
        final container = ProviderContainer(
          overrides: [
            identityServiceProvider.overrideWithValue(mockService),
            circleServiceProvider.overrideWithValue(failingWipe),
          ],
        );
        addTearDown(container.dispose);

        await container
            .read(identityNotifierProvider.notifier)
            .createIdentity();

        expect(
          failingWipe.methodCalls,
          contains('wipeAllMlsState'),
          reason: 'the pending wipe must be attempted',
        );
        expect(
          mockService.createCallCount,
          0,
          reason: 'must NOT provision a new identity over unwiped old state',
        );
        expect(
          container.read(identityNotifierProvider),
          isA<AsyncError<Identity?>>(),
          reason: 'the failed reconcile must surface as an error state',
        );
        final prefs = await SharedPreferences.getInstance();
        expect(
          prefs.getBool(kPendingMlsWipeKey),
          isTrue,
          reason: 'the marker must remain set so a later launch retries',
        );
      },
    );
  });

  // ---------------------------------------------------------------------------
  // Provider isolation — mutations on one container do not affect another
  // ---------------------------------------------------------------------------

  group('provider isolation', () {
    test(
      'two independent containers do not share identityProvider state',
      () async {
        final serviceA = _MockIdentityService(
          initialIdentity: null,
          createResult: createdIdentity,
        );
        final serviceB = _MockIdentityService(
          initialIdentity: null,
          importResult: importedIdentity,
        );

        final containerA = ProviderContainer(
          overrides: [identityServiceProvider.overrideWithValue(serviceA)],
        );
        final containerB = ProviderContainer(
          overrides: [identityServiceProvider.overrideWithValue(serviceB)],
        );
        addTearDown(containerA.dispose);
        addTearDown(containerB.dispose);

        // Create in container A.
        await containerA
            .read(identityNotifierProvider.notifier)
            .createIdentity();

        // Container B should still have null (not affected by A's mutation).
        final identityInB = await containerB.read(identityProvider.future);
        expect(
          identityInB,
          isNull,
          reason:
              'Container B must not be affected by mutations in container A',
        );
      },
    );
  });

  // ---------------------------------------------------------------------------
  // Unused fixture suppression
  // ---------------------------------------------------------------------------

  // The _emptyPubkey constant is declared at the top level of main for
  // documentation purposes; this line prevents the unused-variable lint.
  // ignore: avoid_print
  test('fixture constants are well-formed', () {
    expect(_emptyPubkey.length, 64);
    expect(createdIdentity.pubkeyHex.length, 64);
    expect(importedIdentity.pubkeyHex.length, 64);
    expect(createdIdentity, isNot(equals(importedIdentity)));
  });
}

// =============================================================================
// Mock Identity Service
// =============================================================================

/// Counts the logout's [MaintenanceService.forget]; nothing else is asked
/// of it.
class _ForgetCountingMaintenance extends Fake implements MaintenanceService {
  int forgets = 0;

  @override
  void forget() => forgets++;
}

/// A controllable mock [IdentityService] for testing [IdentityNotifier]
/// and [identityProvider] invalidation behavior.
///
/// The service maintains an internal [_currentIdentity] that can be updated
/// by create/import/delete operations, simulating real persistence. This
/// allows tests to verify that [identityProvider] truly re-fetches (rather
/// than returning a stale cached value) after invalidation.
class _MockIdentityService implements IdentityService {
  _MockIdentityService({
    Identity? initialIdentity,
    this.createResult,
    this.importResult,
    this.throwOnCreate = false,
    this.throwOnImport = false,
    this.deleteClears = false,
    this.onDelete,
  }) : _currentIdentity = initialIdentity;

  Identity? _currentIdentity;

  /// The identity returned by [createIdentity] on success.
  final Identity? createResult;

  /// The identity returned by [importFromNsec] on success.
  final Identity? importResult;

  /// If true, [createIdentity] throws [IdentityServiceException].
  final bool throwOnCreate;

  /// If true, [importFromNsec] throws [IdentityServiceException].
  final bool throwOnImport;

  /// If true, [deleteIdentity] sets [_currentIdentity] to null.
  final bool deleteClears;

  /// Optional callback invoked inside [deleteIdentity] (for ordering tests).
  final void Function()? onDelete;

  // Observation counters for test assertions.
  int getIdentityCallCount = 0;
  int createCallCount = 0;
  int importCallCount = 0;
  int deleteCallCount = 0;
  String? lastImportedNsec;

  @override
  Future<Identity?> getIdentity() async {
    getIdentityCallCount++;
    return _currentIdentity;
  }

  @override
  Future<bool> hasIdentity() async => _currentIdentity != null;

  @override
  Future<Identity> createIdentity() async {
    createCallCount++;
    if (throwOnCreate) {
      throw const IdentityServiceException('Identity already exists');
    }
    final result =
        createResult ??
        Identity(
          pubkeyHex: 'a' * 64,
          npub: 'npub1mock',
          createdAt: DateTime(2025),
        );
    _currentIdentity = result;
    return result;
  }

  @override
  Future<Identity> importFromNsec(String nsec) async {
    importCallCount++;
    lastImportedNsec = nsec;
    if (throwOnImport) {
      throw const IdentityServiceException('Invalid nsec');
    }
    final result =
        importResult ??
        Identity(
          pubkeyHex: 'b' * 64,
          npub: 'npub1mockimport',
          createdAt: DateTime(2025),
        );
    _currentIdentity = result;
    return result;
  }

  @override
  Future<void> deleteIdentity() async {
    deleteCallCount++;
    onDelete?.call();
    if (deleteClears) {
      _currentIdentity = null;
    }
  }

  @override
  Future<String> exportNsec() async {
    if (_currentIdentity == null) {
      throw const IdentityServiceException('No identity to export');
    }
    return 'nsec1mockexport';
  }

  @override
  Future<String> sign(Uint8List messageHash) async {
    if (_currentIdentity == null) {
      throw const IdentityServiceException('No identity to sign with');
    }
    return 'mocksignature' * 4;
  }

  @override
  Future<String> getPubkeyHex() async {
    if (_currentIdentity == null) {
      throw const IdentityServiceException('No identity');
    }
    return _currentIdentity!.pubkeyHex;
  }

  @override
  Future<List<int>> getSecretBytes() async {
    if (_currentIdentity == null) {
      throw const IdentityServiceException('No identity');
    }
    return List<int>.generate(32, (i) => i);
  }

  @override
  Future<String?> getDisplayName() async => null;

  @override
  Future<void> setDisplayName(String? name) async {}

  @override
  Future<void> clearCache() async {}
}

// =============================================================================
// Spy Prefetch Service
// =============================================================================

/// A spy [TilePrefetchService] that records whether [cancel] was called and
/// whether it was called before [_MockIdentityService.deleteIdentity].
class _SpyPrefetchService implements TilePrefetchService {
  bool cancelCalled = false;

  /// True when [cancel] was called before the identity service's delete
  /// callback fired (i.e. cancel precedes the actual wipe).
  bool cancelBeforeDelete = false;

  // Incremented by the mock identity service's onDelete callback to signal
  // that delete ran.
  int _deleteCount = 0;

  /// Called by the mock identity service's onDelete to record timing.
  void recordDeleteCall() {
    _deleteCount++;
    // cancelBeforeDelete is set by cancel() if it ran before delete.
  }

  @override
  void cancel() {
    cancelCalled = true;
    // At the point cancel() is called, deleteIdentity has not yet run
    // (delete count is still 0 if ordering is correct).
    if (_deleteCount == 0) {
      cancelBeforeDelete = true;
    }
  }

  @override
  Future<void> prefetch({
    required List<LatLng> points,
    required TileProviderConfig config,
    required int landingZoom,
    required bool retina,
  }) async {}
}

// =============================================================================
// M10.1 test helpers
// =============================================================================

/// A [CircleService] holding one circle until its [wipeAllMlsState] and
/// nothing after it, counting the circle reads made after the wipe.
class _WipedCircleService extends MockCircleService {
  _WipedCircleService(Circle circle) : super(circles: [circle]);

  bool _wiped = false;

  /// How many times the circle list was read after the wipe.
  int readsAfterWipe = 0;

  @override
  Future<List<Circle>> getVisibleCircles() async {
    if (!_wiped) return super.getVisibleCircles();
    methodCalls.add('getVisibleCircles');
    readsAfterWipe++;
    return const [];
  }

  @override
  Future<void> wipeAllMlsState() async {
    _wiped = true;
    return super.wipeAllMlsState();
  }
}

/// A [CircleService] that extends [MockCircleService] and invokes a callback
/// inside [wipeAllMlsState] so tests can inspect the SharedPreferences state
/// at the exact moment the wipe is called.
class _CapturingWipeMockCircleService extends MockCircleService {
  _CapturingWipeMockCircleService({required this.onWipe});

  final Future<void> Function() onWipe;

  @override
  Future<void> wipeAllMlsState() async {
    await onWipe();
    // Delegate to parent for the methodCalls record.
    return super.wipeAllMlsState();
  }
}

/// A [CircleService] that records whether [kPendingLeaveKey] was still
/// present in [SharedPreferences] at the exact moment [wipeAllMlsState] ran —
/// proving the pending-leave clear in `deleteIdentity()` happens strictly
/// AFTER the MLS wipe, not before.
class _CapturingWipePendingLeaveMockCircleService extends MockCircleService {
  bool? pendingLeaveKeyPresentAtWipeTime;

  @override
  Future<void> wipeAllMlsState() async {
    final prefs = await SharedPreferences.getInstance();
    pendingLeaveKeyPresentAtWipeTime = prefs.containsKey(kPendingLeaveKey);
    return super.wipeAllMlsState();
  }
}

/// A [CircleService] whose [wipeAllMlsState] always throws a
/// [CircleServiceException], simulating a persistent wipe failure.
class _ThrowingWipeMockCircleService2 extends MockCircleService {
  @override
  Future<void> wipeAllMlsState() async {
    methodCalls.add('wipeAllMlsState');
    throw const CircleServiceException('simulated wipe failure');
  }
}

// =============================================================================
// M11 test helpers
// =============================================================================

/// A circle service whose last-known write waits for the test.
class _ParkedUpsertCircle extends MockCircleService {
  Completer<void>? park;
  int upserts = 0;

  @override
  Future<void> upsertLastKnownLocation({
    required List<int> nostrGroupId,
    required String senderPubkey,
    required double latitude,
    required double longitude,
    required String geohash,
    required DateTime timestamp,
    required DateTime expiresAt,
    required DateTime purgeAfter,
    required DateTime updatedAt,
    String? displayName,
  }) async {
    upserts++;
    await park?.future;
    await super.upsertLastKnownLocation(
      nostrGroupId: nostrGroupId,
      senderPubkey: senderPubkey,
      latitude: latitude,
      longitude: longitude,
      geohash: geohash,
      timestamp: timestamp,
      expiresAt: expiresAt,
      purgeAfter: purgeAfter,
      updatedAt: updatedAt,
      displayName: displayName,
    );
  }
}

/// A [SubscriptionService] whose stop never answers: the engine waiting on
/// its lifecycle lock behind a pause that is draining a publish.
class _NeverStoppingSubscriptionService extends _RecordingSubscriptionService {
  _NeverStoppingSubscriptionService() : super(sharedLog: []);

  @override
  Future<LiveSyncStopOutcome> stop({Future<void>? givenUp}) {
    stopCalls++;
    return Completer<LiveSyncStopOutcome>().future;
  }
}

/// A relay manager that records its shutdown and refuses anything else.
class _RecordingRelayManager implements RelayManagerFfi {
  _RecordingRelayManager({required this.onShutdown});

  final void Function() onShutdown;
  int shutdownCalls = 0;
  final List<Symbol> otherCalls = [];

  @override
  Future<void> shutdown() async {
    shutdownCalls++;
    onShutdown();
  }

  @override
  void dispose() {}

  @override
  bool get isDisposed => false;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    otherCalls.add(invocation.memberName);
    throw UnimplementedError('unexpected relay call');
  }
}

/// A subscription service whose first stop waits for the test.
class _ParkedFirstStopService extends _RecordingSubscriptionService {
  _ParkedFirstStopService() : super(sharedLog: []);

  Completer<void>? firstStop;

  @override
  Future<LiveSyncStopOutcome> stop({Future<void>? givenUp}) async {
    final outcome = await super.stop(givenUp: givenUp);
    if (stopCalls == 1) await firstStop?.future;
    return outcome;
  }
}

/// A circle service whose cursor reset — one of the wipes a logout awaits
/// between its first stop and the latch — waits for the test.
class _GatedCursorsCircle extends MockCircleService {
  Completer<void>? cursorGate;

  @override
  Future<void> resetAllSyncCursors() async {
    await super.resetAllSyncCursors();
    await cursorGate?.future;
  }
}

/// A fake engine that records its `stopSession` into the SAME ordered log a
/// co-installed [MockCircleService] appends to.
class _LoggingEngine extends FakeLiveSyncEngine {
  _LoggingEngine(this.sharedLog);

  final List<String> sharedLog;

  @override
  Future<void> stopSession() {
    sharedLog.add('engine.stopSession');
    return super.stopSession();
  }
}

/// A [SubscriptionService] that records `stop()` into a SHARED call-order log
/// — the SAME [MockCircleService.methodCalls] list a test also installs on a
/// co-overridden [MockCircleService] — so the M11 ordering test above can
/// assert `subscriptionServiceProvider.stop()` fired strictly BEFORE
/// `wipeAllMlsState()`, mirroring the M10 `closeAndInvalidate`-before-
/// `wipeAllMlsState` ordering test. `start`/`resumeAfterBackground` are
/// no-ops (never exercised by `deleteIdentity`); `isRunning` reports whatever
/// `stop()` last left it as.
class _RecordingSubscriptionService implements SubscriptionService {
  _RecordingSubscriptionService({required this.sharedLog});

  @override
  LiveLifecycleFfi lifecycle() =>
      isRunning ? LiveLifecycleFfi.launched : LiveLifecycleFfi.noSession;

  /// The SAME ordered log a co-installed [MockCircleService] appends to, so
  /// this call's position can be compared against `wipeAllMlsState`'s.
  final List<String> sharedLog;

  int stopCalls = 0;
  bool _running = true;

  @override
  Future<void> start({
    required List<FfiGroupSpec> groups,
    required List<String> inboxRelays,
  }) async {
    sharedLog.add('subscriptionService.start');
    _running = true;
  }

  @override
  Future<LiveSyncStopOutcome> stop({Future<void>? givenUp}) async {
    stopCalls++;
    sharedLog.add('subscriptionService.stop');
    _running = false;
    return LiveSyncStopOutcome.stopped;
  }

  @override
  Future<void> resumeAfterBackground() async {}

  @override
  Future<void> settleForegroundClaim() async {}

  @override
  Future<void> claimForeground() async {}

  @override
  Future<void> subscribeCircle(FfiGroupSpec spec) async {}

  @override
  Future<void> unsubscribeCircle(Uint8List nostrGroupId) async {}

  @override
  bool get isRunning => _running;

  /// Whether the engine is between background bursts. Mutable for the same
  /// reason the resubscriber's fake makes it mutable: a getter hardcoded
  /// `false` cannot fail loudly the way the throwing burst members below do —
  /// a caller that ignored it would simply no-op, which is the shape of defect
  /// this fake is meant to expose.
  bool paused = false;

  @override
  bool get isPaused => paused;

  // The burst API is unreachable from `deleteIdentity`. Throwing rather than
  // no-op'ing means a future change that routes teardown through a burst fails
  // here instead of silently passing on a fake that did nothing.
  @override
  Future<BurstOpenFfi> openBackgroundBurstWithin(Duration budget) =>
      throw UnimplementedError();

  @override
  Future<void> startIntoBurst({
    required List<FfiGroupSpec> groups,
    required List<String> inboxRelays,
    required Duration budget,
  }) => throw UnimplementedError();

  @override
  Future<BacklogOutcomeFfi> waitBacklogSettled() => throw UnimplementedError();

  @override
  Future<void> settleBeforePause() => throw UnimplementedError();

  @override
  Future<void> pauseSubscriptions() => throw UnimplementedError();
}
