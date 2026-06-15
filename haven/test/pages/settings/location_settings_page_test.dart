/// Widget tests for [LocationSettingsPage].
///
/// RED-PHASE TDD: The page does not exist yet. All tests in this file are
/// expected to fail with a compile error (missing import target) until a
/// separate implementation agent creates the page at:
///   haven/lib/src/pages/settings/location_settings_page.dart
///
/// Test cases:
///   1. Renders AppBar title 'Location' and toggle OFF with no persisted value;
///      no E2EE reassurance row.
///   2. Renders toggle ON and shows 'end-to-end encrypted' row when
///      kBackgroundSharingKey is pre-seeded to true.
///   3. Disclosure DECLINED: tapping the toggle leaves provider false, no
///      SnackBar.
///   4. Disclosure ACCEPTED + EnsurePermissionsGranted (isAndroid seam):
///      provider becomes true, SnackBar 'Background sharing enabled'.
///   5. Disclosure ACCEPTED + EnsurePermissionsNotificationDenied (isAndroid):
///      provider stays false, SnackBar containing 'notification' plus a
///      SnackBarAction labelled 'Open settings'.
///   6. Disclosure ACCEPTED + EnsurePermissionsBatteryOptDenied (isAndroid):
///      provider becomes true, SnackBar containing 'battery optimization'.
///   7. Disable from ON: provider becomes false, SnackBar 'Background sharing
///      disabled'. No disclosure gate.
///   8. Enable handler passes includeBackground: true to the disclosure
///      controller.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/constants/location.dart';
import 'package:haven/src/pages/settings/location_settings_page.dart';
import 'package:haven/src/providers/background_location_provider.dart';
import 'package:haven/src/providers/location_disclosure_provider.dart';
import 'package:haven/src/services/background_location_manager.dart';
import 'package:haven/src/test_keys.dart';
import 'package:shared_preferences/shared_preferences.dart';

// =============================================================================
// Fake disclosure controller
// =============================================================================

/// Fake [LocationDisclosureController] that returns a fixed boolean and
/// records the last `includeBackground` value it was called with.
///
/// Extends the real [StateNotifier] subclass so the override type constraint
/// is satisfied — NOT a value override, as required by the task spec.
class _FakeDisclosureController extends LocationDisclosureController {
  _FakeDisclosureController(this._result);

  final bool _result;

  /// Last value of `includeBackground` seen by [ensureDisclosed], or null
  /// if `ensureDisclosed` was never called.
  bool? lastIncludeBackground;

  @override
  Future<bool> ensureDisclosed(
    BuildContext context, {
    required bool includeBackground,
  }) async {
    lastIncludeBackground = includeBackground;
    return _result;
  }
}

// =============================================================================
// Build helper
// =============================================================================

/// Returns the [ProviderScope]-wrapped [MaterialApp] under test.
///
/// [ensurePermissions] — injected into [BackgroundSharingNotifier]; pass a
/// stub that returns the desired [EnsurePermissionsResult] for the test.
///
/// [isAndroid] — forces the Android branch in [BackgroundSharingNotifier]
/// on the Linux CI runner (test seam).
///
/// [fakeDisclosure] — the fake disclosure controller used to override
/// [locationDisclosureControllerProvider].
Widget _buildApp({
  required EnsurePermissionsFn ensurePermissions,
  required _FakeDisclosureController fakeDisclosure,
  bool isAndroid = false,
}) {
  return ProviderScope(
    overrides: [
      backgroundSharingProvider.overrideWith(
        (_) => BackgroundSharingNotifier(
          ensurePermissions: ensurePermissions,
          isAndroid: isAndroid,
        ),
      ),
      locationDisclosureControllerProvider.overrideWith(
        (_) => fakeDisclosure,
      ),
    ],
    child: const MaterialApp(home: LocationSettingsPage()),
  );
}

// =============================================================================
// Stub helpers — mirrors the pattern in background_location_provider_test.dart
// =============================================================================

EnsurePermissionsFn _stubReturning(EnsurePermissionsResult r) =>
    () async => r;

/// Stubs that should never be called (e.g. during a disable, which skips the
/// permission gate entirely). Throws so a false call is surfaced as a test
/// failure rather than a silent pass.
EnsurePermissionsFn _stubThatThrows() => () async {
  throw StateError('ensurePermissions must NOT be called in this test');
};

// =============================================================================
// Tests
// =============================================================================

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LocationSettingsPage', () {
    // -------------------------------------------------------------------------
    // Test 1: AppBar title + default toggle-OFF state
    // -------------------------------------------------------------------------
    testWidgets(
      '1. renders AppBar title "Location" and toggle OFF when no persisted '
      'value; no E2EE reassurance row visible',
      (tester) async {
        SharedPreferences.setMockInitialValues({});

        final fakeDisclosure = _FakeDisclosureController(false);

        await tester.pumpWidget(
          _buildApp(
            ensurePermissions: _stubThatThrows(),
            fakeDisclosure: fakeDisclosure,
          ),
        );

        // Let BackgroundSharingNotifier._load() settle (async fire-and-forget).
        await tester.pump(Duration.zero);

        // AppBar title
        expect(find.text('Location'), findsOneWidget);

        // Toggle tile is present and OFF
        final tile = tester.widget<SwitchListTile>(
          find.byKey(WidgetKeys.backgroundSharingTile),
        );
        expect(tile.value, isFalse);

        // No E2EE reassurance row when sharing is OFF
        expect(find.textContaining('end-to-end encrypted'), findsNothing);
      },
    );

    // -------------------------------------------------------------------------
    // Test 2: Toggle ON from persisted prefs + E2EE row visible
    // -------------------------------------------------------------------------
    testWidgets(
      '2. renders toggle ON and shows E2EE reassurance row when '
      'kBackgroundSharingKey is pre-seeded to true',
      (tester) async {
        SharedPreferences.setMockInitialValues({kBackgroundSharingKey: true});

        final fakeDisclosure = _FakeDisclosureController(false);

        await tester.pumpWidget(
          _buildApp(
            ensurePermissions: _stubThatThrows(),
            fakeDisclosure: fakeDisclosure,
          ),
        );

        // Pump Duration.zero (NOT pumpAndSettle) to let _load() complete
        // without spinning on any animations.
        await tester.pump(Duration.zero);

        final tile = tester.widget<SwitchListTile>(
          find.byKey(WidgetKeys.backgroundSharingTile),
        );
        expect(tile.value, isTrue);

        // E2EE reassurance row must be visible when toggle is ON
        expect(find.textContaining('end-to-end encrypted'), findsOneWidget);
      },
    );

    // -------------------------------------------------------------------------
    // Test 3: Disclosure DECLINED — no state change, no SnackBar
    // -------------------------------------------------------------------------
    testWidgets(
      '3. disclosure DECLINED: tapping toggle leaves backgroundSharingProvider '
      'false and shows no SnackBar',
      (tester) async {
        SharedPreferences.setMockInitialValues({});

        // Fake disclosure returns false → user declined the dialog.
        final fakeDisclosure = _FakeDisclosureController(false);

        await tester.pumpWidget(
          _buildApp(
            // Permissions must NOT be called when disclosure is declined.
            ensurePermissions: _stubThatThrows(),
            fakeDisclosure: fakeDisclosure,
            isAndroid: true,
          ),
        );
        await tester.pump(Duration.zero);

        // Tap the toggle to attempt enabling.
        await tester.tap(find.byKey(WidgetKeys.backgroundSharingTile));
        await tester.pump(Duration.zero);

        // Provider state must remain false.
        final container = ProviderScope.containerOf(
          tester.element(find.byType(LocationSettingsPage)),
        );
        expect(container.read(backgroundSharingProvider), isFalse);

        // No SnackBar should appear.
        expect(find.byType(SnackBar), findsNothing);
      },
    );

    // -------------------------------------------------------------------------
    // Test 4: Disclosure ACCEPTED + Granted → provider true + success SnackBar
    // -------------------------------------------------------------------------
    testWidgets(
      '4. disclosure ACCEPTED + EnsurePermissionsGranted (isAndroid seam): '
      'provider becomes true, SnackBar "Background sharing enabled"',
      (tester) async {
        SharedPreferences.setMockInitialValues({});

        final fakeDisclosure = _FakeDisclosureController(true);

        await tester.pumpWidget(
          _buildApp(
            ensurePermissions: _stubReturning(const EnsurePermissionsGranted()),
            fakeDisclosure: fakeDisclosure,
            isAndroid: true,
          ),
        );
        await tester.pump(Duration.zero);

        await tester.tap(find.byKey(WidgetKeys.backgroundSharingTile));
        await tester.pump(Duration.zero);

        final container = ProviderScope.containerOf(
          tester.element(find.byType(LocationSettingsPage)),
        );
        expect(container.read(backgroundSharingProvider), isTrue);

        // Pump to flush the SnackBar animation.
        await tester.pump();

        expect(find.text('Background sharing enabled'), findsOneWidget);
      },
    );

    // -------------------------------------------------------------------------
    // Test 5: Disclosure ACCEPTED + NotificationDenied → provider false +
    //         SnackBar with 'notification' + SnackBarAction 'Open settings'
    // -------------------------------------------------------------------------
    testWidgets(
      '5. disclosure ACCEPTED + EnsurePermissionsNotificationDenied '
      '(isAndroid seam): provider stays false, SnackBar contains '
      '"notification" and has SnackBarAction labelled "Open settings"',
      (tester) async {
        SharedPreferences.setMockInitialValues({});

        final fakeDisclosure = _FakeDisclosureController(true);

        await tester.pumpWidget(
          _buildApp(
            ensurePermissions: _stubReturning(
              const EnsurePermissionsNotificationDenied(),
            ),
            fakeDisclosure: fakeDisclosure,
            isAndroid: true,
          ),
        );
        await tester.pump(Duration.zero);

        await tester.tap(find.byKey(WidgetKeys.backgroundSharingTile));
        await tester.pump(Duration.zero);

        final container = ProviderScope.containerOf(
          tester.element(find.byType(LocationSettingsPage)),
        );
        // NotificationDenied is fatal → toggle must stay OFF.
        expect(container.read(backgroundSharingProvider), isFalse);

        await tester.pump();

        // SnackBar text contains 'notification'
        expect(find.textContaining('notification'), findsOneWidget);

        // SnackBarAction labelled 'Open settings' must be present.
        // We assert existence only — do NOT tap it (would hit Geolocator
        // channel).
        expect(
          find.widgetWithText(SnackBarAction, 'Open settings'),
          findsOneWidget,
        );
      },
    );

    // -------------------------------------------------------------------------
    // Test 6: Disclosure ACCEPTED + BatteryOptDenied → provider true +
    //         SnackBar containing 'battery optimization'
    // -------------------------------------------------------------------------
    testWidgets(
      '6. disclosure ACCEPTED + EnsurePermissionsBatteryOptDenied '
      '(isAndroid seam): provider becomes true, SnackBar contains '
      '"battery optimization"',
      (tester) async {
        SharedPreferences.setMockInitialValues({});

        final fakeDisclosure = _FakeDisclosureController(true);

        await tester.pumpWidget(
          _buildApp(
            ensurePermissions: _stubReturning(
              const EnsurePermissionsBatteryOptDenied(),
            ),
            fakeDisclosure: fakeDisclosure,
            isAndroid: true,
          ),
        );
        await tester.pump(Duration.zero);

        await tester.tap(find.byKey(WidgetKeys.backgroundSharingTile));
        await tester.pump(Duration.zero);

        final container = ProviderScope.containerOf(
          tester.element(find.byType(LocationSettingsPage)),
        );
        // BatteryOptDenied is a soft warning — toggle stays ON.
        expect(container.read(backgroundSharingProvider), isTrue);

        await tester.pump();

        expect(find.textContaining('battery optimization'), findsOneWidget);
      },
    );

    // -------------------------------------------------------------------------
    // Test 7: Disable from ON → provider false + 'Background sharing disabled'
    // -------------------------------------------------------------------------
    testWidgets(
      '7. disable from ON: provider becomes false, SnackBar '
      '"Background sharing disabled" (no disclosure gate)',
      (tester) async {
        // Pre-seed to ON.
        SharedPreferences.setMockInitialValues({kBackgroundSharingKey: true});

        // When disabling, the disclosure and permissions gates must NOT fire.
        final fakeDisclosure = _FakeDisclosureController(false);

        await tester.pumpWidget(
          _buildApp(
            ensurePermissions: _stubThatThrows(),
            fakeDisclosure: fakeDisclosure,
            isAndroid: true,
          ),
        );
        // Pump to let _load() settle so the toggle renders as ON.
        await tester.pump(Duration.zero);

        // Verify baseline: toggle is ON.
        final tileBefore = tester.widget<SwitchListTile>(
          find.byKey(WidgetKeys.backgroundSharingTile),
        );
        expect(tileBefore.value, isTrue);

        // Tap to disable.
        await tester.tap(find.byKey(WidgetKeys.backgroundSharingTile));
        await tester.pump(Duration.zero);

        final container = ProviderScope.containerOf(
          tester.element(find.byType(LocationSettingsPage)),
        );
        expect(container.read(backgroundSharingProvider), isFalse);

        await tester.pump();

        expect(find.text('Background sharing disabled'), findsOneWidget);
      },
    );

    // -------------------------------------------------------------------------
    // Test 8: Enable handler passes includeBackground: true
    // -------------------------------------------------------------------------
    testWidgets(
      '8. enable handler passes includeBackground: true to the disclosure '
      'controller',
      (tester) async {
        SharedPreferences.setMockInitialValues({});

        // Fake returns true so the handler proceeds past the gate; the
        // important assertion is on lastIncludeBackground.
        final fakeDisclosure = _FakeDisclosureController(true);

        await tester.pumpWidget(
          _buildApp(
            ensurePermissions: _stubReturning(const EnsurePermissionsGranted()),
            fakeDisclosure: fakeDisclosure,
            isAndroid: true,
          ),
        );
        await tester.pump(Duration.zero);

        await tester.tap(find.byKey(WidgetKeys.backgroundSharingTile));
        await tester.pump(Duration.zero);

        expect(
          fakeDisclosure.lastIncludeBackground,
          isTrue,
          reason:
              'the enable handler must call ensureDisclosed with '
              'includeBackground: true to satisfy the background disclosure '
              'requirement before triggering the Android permission gate',
        );
      },
    );
  });
}
