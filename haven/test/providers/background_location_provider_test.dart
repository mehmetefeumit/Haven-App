/// Tests for BackgroundSharingNotifier and backgroundServiceLifecycleProvider.
///
/// Groups:
///   1. BackgroundSharingNotifier.setEnabled permission gating (Test Set 3)
///   2. backgroundServiceLifecycleProvider platform matrix (Test Set 4 + T6–T8)
///   3. BackgroundSharingNotifier persistence / load (Test Set 5)
///   4. BackgroundSharingNotifier Android-seam permission cases (T9–T11)
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/constants/location.dart';
import 'package:haven/src/providers/background_location_provider.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/background_location_manager.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

// =============================================================================
// Stub helpers
// =============================================================================

/// Creates an [EnsurePermissionsFn] that always returns [r].
EnsurePermissionsFn stubReturning(EnsurePermissionsResult r) =>
    () async => r;

/// Creates an [EnsurePermissionsFn] that throws if called.
///
/// Used to prove that disabling does NOT call the permission check.
EnsurePermissionsFn stubThatThrows() => () async {
  throw StateError('ensurePermissions must NOT be called when disabling');
};

// =============================================================================
// Fake IdentityService for Riverpod container tests
// =============================================================================

/// Minimal fake [IdentityService] that returns a fixed identity or null.
class _FakeIdentityService implements IdentityService {
  _FakeIdentityService({required this.identity});

  final Identity? identity;

  @override
  Future<Identity?> getIdentity() async => identity;

  @override
  Future<bool> hasIdentity() async => identity != null;

  @override
  Future<Identity> createIdentity() async => identity!;

  @override
  Future<Identity> importFromNsec(String nsec) async => identity!;

  @override
  Future<String> exportNsec() async => 'nsec1fake';

  @override
  Future<String> getPubkeyHex() async =>
      identity?.pubkeyHex ??
      '0000000000000000000000000000000000000000000000000000000000000000';

  @override
  Future<List<int>> getSecretBytes() async => List.filled(32, 0);

  @override
  Future<void> deleteIdentity() async {}

  @override
  Future<String?> getDisplayName() async => null;

  @override
  Future<void> setDisplayName(String? name) async {}

  @override
  Future<void> clearCache() async {}

  @override
  Future<String> sign(dynamic messageHash) async => '00' * 64;
}

// =============================================================================
// Fake service-function pair for lifecycle provider tests
// =============================================================================

/// Tracks calls to the injected start/stop functions.
class _ServiceCallTracker {
  int startCallCount = 0;
  int stopCallCount = 0;

  Future<void> start({required Function callback}) async {
    startCallCount++;
  }

  Future<void> stop() async {
    stopCallCount++;
  }
}

// =============================================================================
// Shared fixture identity
// =============================================================================

final _loadedIdentity = Identity(
  pubkeyHex: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  npub: 'npub1testloaded',
  createdAt: DateTime(2026),
);

// =============================================================================
// Test Set 3: BackgroundSharingNotifier.setEnabled — permission gating
// =============================================================================

/// NOTE ON ANDROID GATING
///
/// BackgroundSharingNotifier.setEnabled now accepts an `isAndroid` constructor
/// parameter as a test seam (T9–T11 below). The original tests below cover the
/// non-Android paths (disable + iOS/Linux enable) which always work on any
/// runner. See T9–T11 for the Android-seam versions.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ---------------------------------------------------------------------------
  // Test Set 3: setEnabled permission gating
  // ---------------------------------------------------------------------------

  group('BackgroundSharingNotifier.setEnabled — permission gating', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    // -----------------------------------------------------------------------
    // Android-specific cases — skipped on non-Android runners.
    // These remain as documentation; see T9–T11 for the isAndroid-seam
    // equivalents that DO run on all platforms.
    // -----------------------------------------------------------------------

    test(
      'Android: enable + Granted → state true, prefs true, returns Granted',
      () async {
        final notifier = BackgroundSharingNotifier(
          ensurePermissions: stubReturning(const EnsurePermissionsGranted()),
        );
        await Future<void>.delayed(Duration.zero); // let _load() complete

        final result = await notifier.setEnabled(enabled: true);

        expect(notifier.state, isTrue);
        expect(result, isA<EnsurePermissionsGranted>());

        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getBool(kBackgroundSharingKey), isTrue);
      },
      skip: 'Platform.isAndroid == false on runner — see T9 for seam version',
    );

    test(
      'Android: enable + NotificationDenied → state false, prefs false, '
      'returns NotificationDenied',
      () async {
        final notifier = BackgroundSharingNotifier(
          ensurePermissions: stubReturning(
            const EnsurePermissionsNotificationDenied(),
          ),
        );
        await Future<void>.delayed(Duration.zero);

        final result = await notifier.setEnabled(enabled: true);

        expect(notifier.state, isFalse);
        expect(result, isA<EnsurePermissionsNotificationDenied>());

        final prefs = await SharedPreferences.getInstance();
        expect(
          prefs.getBool(kBackgroundSharingKey),
          isNot(isTrue),
          reason: 'toggle must not be persisted as true when denied',
        );
      },
      skip: 'Platform.isAndroid == false on runner — see T10 for seam version',
    );

    test(
      'Android: enable + BatteryOptDenied → state true, prefs true, '
      'returns BatteryOptDenied (soft warning)',
      () async {
        final notifier = BackgroundSharingNotifier(
          ensurePermissions: stubReturning(
            const EnsurePermissionsBatteryOptDenied(),
          ),
        );
        await Future<void>.delayed(Duration.zero);

        final result = await notifier.setEnabled(enabled: true);

        expect(notifier.state, isTrue);
        expect(result, isA<EnsurePermissionsBatteryOptDenied>());

        final prefs = await SharedPreferences.getInstance();
        expect(
          prefs.getBool(kBackgroundSharingKey),
          isTrue,
          reason: 'battery-opt denial is a soft warning — toggle remains ON',
        );
      },
      skip: 'Platform.isAndroid == false on runner — see T11 for seam version',
    );

    // -----------------------------------------------------------------------
    // Disable case — does NOT gate on Platform.isAndroid → runs everywhere.
    // -----------------------------------------------------------------------

    test(
      'disable → state false, prefs false, no permission check called',
      () async {
        SharedPreferences.setMockInitialValues({kBackgroundSharingKey: true});

        // stubThatThrows proves the permission check is NOT called when
        // disabling (production code only checks when enabled && _isAndroid).
        final notifier = BackgroundSharingNotifier(
          ensurePermissions: stubThatThrows(),
        );
        await Future<void>.delayed(Duration.zero); // let _load() settle

        final result = await notifier.setEnabled(enabled: false);

        expect(notifier.state, isFalse);
        expect(result, isNull, reason: 'disabling always returns null');

        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getBool(kBackgroundSharingKey), isFalse);
      },
    );

    // -----------------------------------------------------------------------
    // Non-Android enable (iOS / Linux) — permission check is skipped.
    // Covers the production iOS path and documents non-Android behavior.
    // -----------------------------------------------------------------------

    test('non-Android: enable → state true, prefs true, returns null '
        '(no permission check)', () async {
      final notifier = BackgroundSharingNotifier(
        ensurePermissions: stubThatThrows(),
      );
      await Future<void>.delayed(Duration.zero);

      final result = await notifier.setEnabled(enabled: true);

      expect(notifier.state, isTrue);
      expect(
        result,
        isNull,
        reason: 'non-Android enable skips permission check and returns null',
      );

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(kBackgroundSharingKey), isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  // Test Set 4: backgroundServiceLifecycleProvider — platform matrix (T6–T8)
  // ---------------------------------------------------------------------------

  group('backgroundServiceLifecycleProvider — platform matrix (T6–T8)', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    // -----------------------------------------------------------------------
    // T6: Android + identity loaded + enabled → startService called once
    // -----------------------------------------------------------------------
    test(
      'T6: Android + enabled=true + identity loaded → startService called once',
      () async {
        // Pre-seed prefs so BackgroundSharingNotifier._load() sets state=true
        // without a race against setEnabled().
        SharedPreferences.setMockInitialValues({kBackgroundSharingKey: true});

        final tracker = _ServiceCallTracker();

        final container = ProviderContainer(
          overrides: [
            platformIsAndroidProvider.overrideWithValue(true),
            identityServiceProvider.overrideWithValue(
              _FakeIdentityService(identity: _loadedIdentity),
            ),
            backgroundServiceFunctionsProvider.overrideWithValue((
              start: tracker.start,
              stop: tracker.stop,
            )),
          ],
        );
        addTearDown(container.dispose);

        // Force notifier creation so _load() fires, then pump to let
        // _load() complete (reads kBackgroundSharingKey=true from prefs).
        container.read(backgroundSharingProvider.notifier);
        await Future<void>.delayed(Duration.zero);

        // Let the identity FutureProvider resolve.
        await container.read(identityProvider.future);

        // Reading the lifecycle provider triggers its synchronous body.
        // At this point: isAndroid=true, enabled=true, identity=loaded.
        container.read(backgroundServiceLifecycleProvider);

        // Allow any unawaited start/stop futures to drain.
        await Future<void>.delayed(Duration.zero);

        expect(
          tracker.startCallCount,
          equals(1),
          reason:
              'startService must be called exactly once when Android, '
              'enabled=true, and identity is loaded',
        );
        expect(
          tracker.stopCallCount,
          equals(0),
          reason: 'stopService must not be called in the happy path',
        );
      },
    );

    // -----------------------------------------------------------------------
    // T7: enabled=false → stop called; identity=null → stop called
    // -----------------------------------------------------------------------
    test(
      'T7a: Android + enabled=false → stopService called, startService not',
      () async {
        final tracker = _ServiceCallTracker();

        // Pre-seed: sharing is currently enabled.
        SharedPreferences.setMockInitialValues({kBackgroundSharingKey: false});

        final container = ProviderContainer(
          overrides: [
            platformIsAndroidProvider.overrideWithValue(true),
            identityServiceProvider.overrideWithValue(
              _FakeIdentityService(identity: _loadedIdentity),
            ),
            backgroundServiceFunctionsProvider.overrideWithValue((
              start: tracker.start,
              stop: tracker.stop,
            )),
          ],
        );
        addTearDown(container.dispose);

        // Sharing is disabled (default false via prefs).
        await container.read(identityProvider.future);
        container.read(backgroundServiceLifecycleProvider);
        await Future<void>.delayed(Duration.zero);

        expect(
          tracker.stopCallCount,
          greaterThanOrEqualTo(1),
          reason:
              'stopService must be called when enabled=false even if '
              'identity is loaded',
        );
        expect(
          tracker.startCallCount,
          equals(0),
          reason:
              'startService must not be called when background sharing '
              'is disabled',
        );
      },
    );

    test(
      'T7b: Android + identity=null → stopService called, startService not',
      () async {
        final tracker = _ServiceCallTracker();

        SharedPreferences.setMockInitialValues({kBackgroundSharingKey: true});

        final container = ProviderContainer(
          overrides: [
            platformIsAndroidProvider.overrideWithValue(true),
            identityServiceProvider.overrideWithValue(
              // No identity — returns null.
              _FakeIdentityService(identity: null),
            ),
            backgroundServiceFunctionsProvider.overrideWithValue((
              start: tracker.start,
              stop: tracker.stop,
            )),
          ],
        );
        addTearDown(container.dispose);

        await container.read(identityProvider.future);
        container.read(backgroundServiceLifecycleProvider);
        await Future<void>.delayed(Duration.zero);

        expect(
          tracker.stopCallCount,
          greaterThanOrEqualTo(1),
          reason:
              'stopService must be called when identity is null even if '
              'background sharing is toggled on',
        );
        expect(
          tracker.startCallCount,
          equals(0),
          reason: 'startService must not be called when there is no identity',
        );
      },
    );

    // -----------------------------------------------------------------------
    // T8: platformIsAndroid=false (iOS) → neither start nor stop called
    // -----------------------------------------------------------------------
    test('T8: non-Android (platformIsAndroid=false) → '
        'neither start nor stop is called (early-return)', () async {
      final tracker = _ServiceCallTracker();

      SharedPreferences.setMockInitialValues({kBackgroundSharingKey: true});

      final container = ProviderContainer(
        overrides: [
          // Simulate iOS / Linux test runner.
          platformIsAndroidProvider.overrideWithValue(false),
          identityServiceProvider.overrideWithValue(
            _FakeIdentityService(identity: _loadedIdentity),
          ),
          backgroundServiceFunctionsProvider.overrideWithValue((
            start: tracker.start,
            stop: tracker.stop,
          )),
        ],
      );
      addTearDown(container.dispose);

      await container.read(identityProvider.future);

      // Reading must not throw — provider must early-return silently.
      expect(
        () => container.read(backgroundServiceLifecycleProvider),
        returnsNormally,
        reason:
            'reading backgroundServiceLifecycleProvider on non-Android '
            'must not throw',
      );

      await Future<void>.delayed(Duration.zero);

      expect(
        tracker.startCallCount,
        equals(0),
        reason: 'startService must never be called on non-Android platforms',
      );
      expect(
        tracker.stopCallCount,
        equals(0),
        reason:
            'stopService must never be called by this provider on '
            'non-Android platforms (onDispose still runs but that is '
            'allowed — we verify no calls during the body execution)',
      );
    });

    // Legacy test retained from Test Set 4 for backward compatibility.
    test('non-Android (platformIsAndroid = false) is a no-op — '
        'provider reads without throwing', () {
      final container = ProviderContainer(
        overrides: [platformIsAndroidProvider.overrideWithValue(false)],
      );
      addTearDown(container.dispose);

      // Reading the provider on a non-Android platform must not throw.
      expect(
        () => container.read(backgroundServiceLifecycleProvider),
        returnsNormally,
        reason:
            'provider must return early without calling any static '
            'BackgroundLocationManager method on non-Android',
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Test Set 5: BackgroundSharingNotifier persistence / load
  // ---------------------------------------------------------------------------

  group('BackgroundSharingNotifier — persistence and load', () {
    // -----------------------------------------------------------------------
    // Case 1: Loads true from prefs on construction.
    // -----------------------------------------------------------------------
    test(
      'loads true from prefs on construction when key is preset to true',
      () async {
        SharedPreferences.setMockInitialValues({kBackgroundSharingKey: true});

        final notifier = BackgroundSharingNotifier(
          ensurePermissions: stubThatThrows(),
        );

        // _load() is async fire-and-forget; pump the event loop.
        await Future<void>.delayed(Duration.zero);

        expect(
          notifier.state,
          isTrue,
          reason: 'notifier must load persisted true on construction',
        );
      },
    );

    // -----------------------------------------------------------------------
    // Case 2: Loads false (default) when key is unset.
    // -----------------------------------------------------------------------
    test(
      'loads false (default) from prefs on construction when key is unset',
      () async {
        SharedPreferences.setMockInitialValues({});

        final notifier = BackgroundSharingNotifier(
          ensurePermissions: stubThatThrows(),
        );
        await Future<void>.delayed(Duration.zero);

        expect(
          notifier.state,
          isFalse,
          reason: 'notifier must default to false when key is absent',
        );
      },
    );

    // -----------------------------------------------------------------------
    // Case 3: Loads false from prefs when key is explicitly false.
    // -----------------------------------------------------------------------
    test(
      'loads false from prefs on construction when key is preset to false',
      () async {
        SharedPreferences.setMockInitialValues({kBackgroundSharingKey: false});

        final notifier = BackgroundSharingNotifier(
          ensurePermissions: stubThatThrows(),
        );
        await Future<void>.delayed(Duration.zero);

        expect(
          notifier.state,
          isFalse,
          reason: 'notifier must load persisted false on construction',
        );
      },
    );

    // -----------------------------------------------------------------------
    // Case 4: Persists to prefs on setEnabled(false) even when initial true.
    // -----------------------------------------------------------------------
    test(
      'persists false to prefs on setEnabled(false) when initial state is true',
      () async {
        SharedPreferences.setMockInitialValues({kBackgroundSharingKey: true});

        final notifier = BackgroundSharingNotifier(
          ensurePermissions: stubThatThrows(),
        );
        await Future<void>.delayed(Duration.zero);
        expect(notifier.state, isTrue); // baseline

        await notifier.setEnabled(enabled: false);

        expect(notifier.state, isFalse);
        final prefs = await SharedPreferences.getInstance();
        expect(
          prefs.getBool(kBackgroundSharingKey),
          isFalse,
          reason:
              'setEnabled(false) must write false to prefs regardless of '
              'initial state',
        );
      },
    );

    // -----------------------------------------------------------------------
    // Case 5: Survives prefs reload — new notifier reads value persisted by
    //         the previous one.
    // -----------------------------------------------------------------------
    test(
      'survives prefs reload: new notifier reads value written by previous',
      () async {
        SharedPreferences.setMockInitialValues({});

        // First notifier: starts at false, then enables (non-Android path).
        final firstNotifier = BackgroundSharingNotifier(
          ensurePermissions: stubThatThrows(),
        );
        await Future<void>.delayed(Duration.zero);
        expect(firstNotifier.state, isFalse);

        // Enable: non-Android path returns null, no permission check.
        await firstNotifier.setEnabled(enabled: true);
        expect(firstNotifier.state, isTrue);

        // Confirm value in prefs before constructing the second notifier.
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getBool(kBackgroundSharingKey), isTrue);

        // Second notifier — simulates a new app session / widget rebuild.
        final secondNotifier = BackgroundSharingNotifier(
          ensurePermissions: stubThatThrows(),
        );
        await Future<void>.delayed(Duration.zero);

        expect(
          secondNotifier.state,
          isTrue,
          reason:
              'second notifier must read the true value written by the first',
        );
      },
    );
  });

  // ---------------------------------------------------------------------------
  // T9–T11: BackgroundSharingNotifier Android-seam permission cases
  //
  // These use the isAndroid constructor parameter to force the Android branch
  // on any test runner, removing the need to skip on Linux CI.
  // ---------------------------------------------------------------------------

  group(
    'BackgroundSharingNotifier — Android-seam permission cases (T9–T11)',
    () {
      setUp(() {
        SharedPreferences.setMockInitialValues({});
      });

      // -----------------------------------------------------------------------
      // T9: Android + enable + EnsurePermissionsGranted
      //     → state true, prefs persisted to true
      // -----------------------------------------------------------------------
      test('T9: Android (seam) + enable + Granted → state true, prefs true, '
          'returns EnsurePermissionsGranted', () async {
        final notifier = BackgroundSharingNotifier(
          ensurePermissions: stubReturning(const EnsurePermissionsGranted()),
          isAndroid: true,
        );
        await Future<void>.delayed(Duration.zero);

        final result = await notifier.setEnabled(enabled: true);

        expect(
          notifier.state,
          isTrue,
          reason: 'state must be true when permissions are granted on Android',
        );
        expect(
          result,
          isA<EnsurePermissionsGranted>(),
          reason: 'result must surface the Granted result to the caller',
        );

        final prefs = await SharedPreferences.getInstance();
        expect(
          prefs.getBool(kBackgroundSharingKey),
          isTrue,
          reason:
              'kBackgroundSharingKey must be persisted to true when '
              'permissions are granted',
        );
      });

      // -----------------------------------------------------------------------
      // T10: Android + enable + EnsurePermissionsNotificationDenied
      //     → state false, prefs persisted to false
      //
      // This confirms the S1 fix: notification denial is fatal — the toggle
      // must not be left as true in prefs, which would cause the service to
      // auto-start on next launch without a notification (invisible FGS on
      // Android 13+, killed immediately by many OEMs).
      // -----------------------------------------------------------------------
      test('T10: Android (seam) + enable + NotificationDenied → '
          'state false, prefs persisted to false (S1 fix)', () async {
        final notifier = BackgroundSharingNotifier(
          ensurePermissions: stubReturning(
            const EnsurePermissionsNotificationDenied(),
          ),
          isAndroid: true,
        );
        await Future<void>.delayed(Duration.zero);

        final result = await notifier.setEnabled(enabled: true);

        expect(
          notifier.state,
          isFalse,
          reason: 'notification denial is fatal — toggle must remain OFF',
        );
        expect(
          result,
          isA<EnsurePermissionsNotificationDenied>(),
          reason:
              'result must surface the NotificationDenied result so the '
              'caller can show error UI',
        );

        final prefs = await SharedPreferences.getInstance();
        expect(
          prefs.getBool(kBackgroundSharingKey),
          isNot(isTrue),
          reason:
              'kBackgroundSharingKey must NOT be persisted as true when '
              'notification permission is denied — a stale true would '
              'cause auto-start without a notification on next launch',
        );
      });

      // -----------------------------------------------------------------------
      // T11: Android + enable + EnsurePermissionsBatteryOptDenied
      //     → state true (soft warning), prefs persisted to true,
      //       result surfaced to caller
      // -----------------------------------------------------------------------
      test(
        'T11: Android (seam) + enable + BatteryOptDenied → '
        'state true, prefs true, returns BatteryOptDenied (soft warning)',
        () async {
          final notifier = BackgroundSharingNotifier(
            ensurePermissions: stubReturning(
              const EnsurePermissionsBatteryOptDenied(),
            ),
            isAndroid: true,
          );
          await Future<void>.delayed(Duration.zero);

          final result = await notifier.setEnabled(enabled: true);

          expect(
            notifier.state,
            isTrue,
            reason:
                'battery-optimization denial is a soft warning — the '
                'service can still start; toggle stays ON',
          );
          expect(
            result,
            isA<EnsurePermissionsBatteryOptDenied>(),
            reason:
                'result must surface BatteryOptDenied so the caller can '
                'show an advisory snackbar about possible Doze throttling',
          );

          final prefs = await SharedPreferences.getInstance();
          expect(
            prefs.getBool(kBackgroundSharingKey),
            isTrue,
            reason:
                'kBackgroundSharingKey must be persisted to true even when '
                'battery optimization is denied (soft warning, not fatal)',
          );
        },
      );

      // -----------------------------------------------------------------------
      // Additional guard: Android seam + disable → ensurePermissions NOT called
      // -----------------------------------------------------------------------
      test('Android (seam) + disable → ensurePermissions not called, '
          'state false, prefs false', () async {
        SharedPreferences.setMockInitialValues({kBackgroundSharingKey: true});

        final notifier = BackgroundSharingNotifier(
          // stubThatThrows verifies the permission fn is never invoked.
          ensurePermissions: stubThatThrows(),
          isAndroid: true,
        );
        await Future<void>.delayed(Duration.zero);
        expect(notifier.state, isTrue); // verify initial load

        final result = await notifier.setEnabled(enabled: false);

        expect(notifier.state, isFalse);
        expect(
          result,
          isNull,
          reason: 'disabling on Android also returns null',
        );

        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getBool(kBackgroundSharingKey), isFalse);
      });
    },
  );
}
