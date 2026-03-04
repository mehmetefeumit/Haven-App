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
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/identity_service.dart';

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
        overrides: [identityServiceProvider.overrideWithValue(mockService)],
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
        overrides: [identityServiceProvider.overrideWithValue(mockService)],
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
          overrides: [identityServiceProvider.overrideWithValue(mockService)],
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
        overrides: [identityServiceProvider.overrideWithValue(mockService)],
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
          overrides: [identityServiceProvider.overrideWithValue(mockService)],
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
          overrides: [identityServiceProvider.overrideWithValue(mockService)],
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
        overrides: [identityServiceProvider.overrideWithValue(mockService)],
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
    const testNsec =
        'nsec1vl029mgpspedva04g90vltkh6fvh240zqtv9k3lh5cvdcbztk0qu9jnqhg';

    test(
      'identityProvider returns imported identity after importFromNsec',
      () async {
        final mockService = _MockIdentityService(
          initialIdentity: null,
          importResult: importedIdentity,
        );
        final container = ProviderContainer(
          overrides: [identityServiceProvider.overrideWithValue(mockService)],
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
        overrides: [identityServiceProvider.overrideWithValue(mockService)],
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
        overrides: [identityServiceProvider.overrideWithValue(mockService)],
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
          overrides: [identityServiceProvider.overrideWithValue(mockService)],
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
          overrides: [identityServiceProvider.overrideWithValue(mockService)],
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
        overrides: [identityServiceProvider.overrideWithValue(mockService)],
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
        overrides: [identityServiceProvider.overrideWithValue(mockService)],
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

    test(
      'identityNotifierProvider state is null after deleteIdentity',
      () async {
        final mockService = _MockIdentityService(
          initialIdentity: createdIdentity,
          deleteClears: true,
        );
        final container = ProviderContainer(
          overrides: [identityServiceProvider.overrideWithValue(mockService)],
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
        overrides: [identityServiceProvider.overrideWithValue(mockService)],
      );
      addTearDown(container.dispose);

      await container.read(identityNotifierProvider.notifier).deleteIdentity();

      expect(mockService.deleteCallCount, 1);
    });
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
  Future<void> clearCache() async {}
}
