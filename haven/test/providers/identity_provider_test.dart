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

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/constants/tiles.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/live_sync_provider.dart' show liveSyncEnabled;
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/providers/tile_prefetch_provider.dart';
import 'package:haven/src/rust/api.dart' show FfiGroupSpec;
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/services/pending_mls_wipe_service.dart';
import 'package:haven/src/services/subscription_service.dart'
    show SubscriptionService;
import 'package:haven/src/services/tile_prefetch_service.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../mocks/mock_circle_service.dart';

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

    test('deleteIdentity wipes staged-commit markers + resets cursors '
        '(M7 teardown)', () async {
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
        containsAll(<String>['wipeAllStagedCommits', 'resetAllSyncCursors']),
        reason: 'logout must wipe the M7 staged_commits + all sync cursors',
      );
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
  Future<void> stop() async {
    stopCalls++;
    sharedLog.add('subscriptionService.stop');
    _running = false;
  }

  @override
  Future<void> resumeAfterBackground() async {}

  @override
  Future<void> subscribeCircle(FfiGroupSpec spec) async {}

  @override
  Future<void> unsubscribeCircle(Uint8List nostrGroupId) async {}

  @override
  bool get isRunning => _running;
}
