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
///   2. Renders toggle ON when kBackgroundSharingKey is pre-seeded to true
///      (the 'end-to-end encrypted' row was removed and must not appear).
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

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/constants/location.dart';
import 'package:haven/src/pages/settings/location_settings_page.dart';
import 'package:haven/src/providers/background_location_provider.dart';
import 'package:haven/src/providers/location_disclosure_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/background_location_manager.dart';
import 'package:haven/src/services/ios_background_session_service.dart';
import 'package:haven/src/services/ios_location_auth_service.dart';
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
// Fake iOS location auth service
// =============================================================================

/// Returns a fixed [IosAuthStatus] so the provider-driven "limited" note can be
/// exercised on the Linux test host.
class _FakeIosLocationAuth implements IosLocationAuthService {
  _FakeIosLocationAuth(this.status);

  /// Mutable so a test can model the user answering the "Always" prompt in
  /// Settings while the page is backgrounded.
  IosAuthStatus status;

  @override
  Future<IosAuthStatus> checkStatus() async => status;

  @override
  Future<IosAuthStatus> requestAlways() async => status;
}

// =============================================================================
// Fake iOS background session handler
// =============================================================================

/// Stands in for the native `HavenBackgroundSessionHandler`, as the STATE
/// MACHINE it is rather than as four independent booleans.
///
/// The contract the Swift side enforces, and the reason this double is written
/// this way: `alwaysConfirmed` is a MEASUREMENT that only a held `.always`
/// service session's diagnostics can make, and `disarm()` clears it
/// unconditionally. So confirmed-while-disarmed cannot occur on a device — a
/// fake that let a test set the two fields independently pinned a state no
/// user can ever be in, and the reasoning written beside that test ("both
/// sentences are conditional, so they stay true with the toggle off") is what
/// let the page promise a blue bar to a confirmed-Always iPhone with sharing
/// off. Here the unreachable configuration cannot be constructed, and
/// [confirmAlways] is the only way in — from the one state that has a session
/// to be diagnosed.
///
/// `backgroundActivitySessionHeld` and `serviceSessionHeld` are DERIVED for
/// the same reason: on a device they follow the same predicates, and a free
/// field could contradict the arming it is supposed to describe.
class _FakeIosBackgroundSession implements IosBackgroundSessionService {
  _FakeIosBackgroundSession({
    bool armed = false,
    bool alwaysConfirmed = false,
    this.supported = true,
    this.neverAnswers = false,
  }) : _armed = armed,
       _alwaysConfirmed = alwaysConfirmed,
       assert(
         armed || !alwaysConfirmed,
         'a disarmed handler cannot report a confirmed Always: only a '
         'diagnostic on a held .always session sets the predicate, and '
         'disarm() clears it',
       );

  /// False on iOS 15/16, where `CLBackgroundActivitySession` does not exist
  /// and no activity session can therefore ever be held — while the stream
  /// handler's indicator flag still puts the blue bar on screen.
  final bool supported;

  /// Leaves [status] pending forever, modelling the window before the native
  /// handler has answered — the state in which no indicator sentence is yet
  /// known to be true.
  final bool neverAnswers;

  bool _armed;
  bool _alwaysConfirmed;

  /// Whether the handler's consent + authorization gates last passed.
  bool get armed => _armed;

  /// Models the `CLServiceSessionDiagnostic` that promotes Always.
  ///
  /// Only reachable while armed, which is the native contract: the diagnostics
  /// task belongs to the held session and dies with it.
  void confirmAlways() {
    if (!_armed) {
      throw StateError(
        'no session is held, so no diagnostic can arrive: arm() first',
      );
    }
    _alwaysConfirmed = true;
  }

  @override
  Future<void> arm() async {
    _armed = true;
  }

  @override
  Future<void> disarm() async {
    _armed = false;
    // The confirmation belonged to the session just released.
    _alwaysConfirmed = false;
  }

  @override
  Future<IosBackgroundSessionStatus> status() {
    if (neverAnswers) return Completer<IosBackgroundSessionStatus>().future;
    return Future.value(
      IosBackgroundSessionStatus(
        supported: supported,
        backgroundActivitySessionHeld:
            _armed && supported && !_alwaysConfirmed,
        serviceSessionHeld: _armed,
        alwaysConfirmed: _alwaysConfirmed,
        armed: _armed,
      ),
    );
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
///
/// [iosAuthStatus] — the status reported by the overridden
/// [iosLocationAuthServiceProvider]; drives the iOS "limited in background"
/// note. Defaults to [IosAuthStatus.always] (not limited).
///
/// [batteryOptProbe] — replaces the live OS probe behind
/// [batteryOptimizationDeniedProvider]. The provider's own Android gate and
/// re-probe logic still run, so a test can prove the gate as well as the
/// advisory.
///
/// [openBatteryOptSettings] — replaces the platform-channel opener behind the
/// advisory's action button.
Widget _buildApp({
  required EnsurePermissionsFn ensurePermissions,
  required _FakeDisclosureController fakeDisclosure,
  bool isAndroid = false,
  IosAuthStatus iosAuthStatus = IosAuthStatus.always,
  _FakeIosLocationAuth? iosAuth,
  _FakeIosBackgroundSession? iosSession,
  BatteryOptimizationProbeFn? batteryOptProbe,
  OpenBatteryOptimizationSettingsFn? openBatteryOptSettings,
  TextScaler textScaler = TextScaler.noScaling,
}) {
  final auth = iosAuth ?? _FakeIosLocationAuth(iosAuthStatus);
  return ProviderScope(
    overrides: [
      backgroundSharingProvider.overrideWith(
        (_) => BackgroundSharingNotifier(
          ensurePermissions: ensurePermissions,
          isAndroid: isAndroid,
          // A test that supplies a session double is testing iOS, so take the
          // iOS branch and hand the notifier the SAME handler the page reads
          // its indicator from. On a device there is exactly one: the toggle's
          // arm/disarm and the card's reading are the same object, and a
          // double wired to only one of the two cannot see a disable reach the
          // card.
          iosLocationAuth: auth,
          iosBackgroundSession:
              iosSession ?? const NoopIosBackgroundSessionService(),
          isIOS: iosSession != null,
        ),
      ),
      locationDisclosureControllerProvider.overrideWith((_) => fakeDisclosure),
      iosLocationAuthServiceProvider.overrideWithValue(auth),
      if (iosSession != null)
        iosBackgroundSessionServiceProvider.overrideWithValue(iosSession),
      platformIsAndroidProvider.overrideWithValue(isAndroid),
      if (batteryOptProbe != null)
        batteryOptimizationProbeProvider.overrideWithValue(batteryOptProbe),
      if (openBatteryOptSettings != null)
        openBatteryOptimizationSettingsProvider.overrideWithValue(
          openBatteryOptSettings,
        ),
    ],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      // MaterialApp rebuilds MediaQuery from the view, so a MediaQuery around
      // the whole app would be discarded; the builder is the supported way in.
      builder: (context, child) => MediaQuery.withClampedTextScaling(
        minScaleFactor: textScaler.scale(1),
        maxScaleFactor: textScaler.scale(1),
        child: child!,
      ),
      home: const LocationSettingsPage(),
    ),
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
      '2. renders toggle ON when kBackgroundSharingKey is pre-seeded to true '
      '(no E2EE reassurance row — it was removed)',
      (tester) async {
        SharedPreferences.setMockInitialValues({kBackgroundSharingKey: true,
        kLocationDisclosureBackgroundAcceptedKey: true});

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

        // The end-to-end-encrypted reassurance row was intentionally removed;
        // it must not appear even when sharing is ON.
        expect(find.textContaining('end-to-end encrypted'), findsNothing);
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
    testWidgets('5. disclosure ACCEPTED + EnsurePermissionsNotificationDenied '
        '(isAndroid seam): provider stays false, SnackBar contains '
        '"notification" and has SnackBarAction labelled "Open settings"', (
      tester,
    ) async {
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
    });

    // -------------------------------------------------------------------------
    // Test 6: Disclosure ACCEPTED + BatteryOptDenied → provider true +
    //         SnackBar containing 'battery optimization'
    // -------------------------------------------------------------------------
    testWidgets('6. disclosure ACCEPTED + EnsurePermissionsBatteryOptDenied '
        '(isAndroid seam): provider becomes true, SnackBar contains '
        '"battery optimization"', (tester) async {
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
    });

    // -------------------------------------------------------------------------
    // Test 7: Disable from ON → provider false + 'Background sharing disabled'
    // -------------------------------------------------------------------------
    testWidgets('7. disable from ON: provider becomes false, SnackBar '
        '"Background sharing disabled" (no disclosure gate)', (tester) async {
      // Pre-seed to ON.
      SharedPreferences.setMockInitialValues({kBackgroundSharingKey: true,
        kLocationDisclosureBackgroundAcceptedKey: true});

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
    });

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

    // -------------------------------------------------------------------------
    // Test 9: iOS limited (while-in-use) note shows when sharing is ON and the
    // authorization is only while-in-use. Driven by the
    // iosLocationPermissionProvider so it is now exercisable on the Linux test
    // host (previously gated behind a real-device Platform.isIOS check).
    // -------------------------------------------------------------------------
    testWidgets(
      '9. iOS while-in-use authorization + sharing ON shows the "Always" '
      'note with an Open settings action',
      (tester) async {
        SharedPreferences.setMockInitialValues({kBackgroundSharingKey: true,
        kLocationDisclosureBackgroundAcceptedKey: true});

        await tester.pumpWidget(
          _buildApp(
            ensurePermissions: _stubThatThrows(),
            fakeDisclosure: _FakeDisclosureController(false),
            iosAuthStatus: IosAuthStatus.whenInUse,
          ),
        );
        // Settle both _load() and the iosLocationPermissionProvider future.
        await tester.pumpAndSettle();

        expect(
          find.textContaining('with your current permission'),
          findsOneWidget,
        );
        expect(find.text('Open settings'), findsOneWidget);
      },
    );

    // -------------------------------------------------------------------------
    // Test 10: the limited note is hidden when Always is granted.
    // -------------------------------------------------------------------------
    testWidgets('10. iOS Always authorization hides the limited note', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({kBackgroundSharingKey: true,
        kLocationDisclosureBackgroundAcceptedKey: true});

      await tester.pumpWidget(
        // iosAuthStatus defaults to IosAuthStatus.always (not limited).
        _buildApp(
          ensurePermissions: _stubThatThrows(),
          fakeDisclosure: _FakeDisclosureController(false),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('with your current permission'), findsNothing);
    });

    // -------------------------------------------------------------------------
    // Test 11: the runtime journey the feature targets — enabling from OFF
    // while only while-in-use is granted must surface the limited note after
    // the toggle (disclosure → setEnabled → invalidate → re-read → rebuild).
    // -------------------------------------------------------------------------
    testWidgets(
      '11. enabling from OFF with while-in-use auth surfaces the limited note',
      (tester) async {
        SharedPreferences.setMockInitialValues({});

        await tester.pumpWidget(
          _buildApp(
            ensurePermissions: _stubReturning(const EnsurePermissionsGranted()),
            fakeDisclosure: _FakeDisclosureController(true),
            iosAuthStatus: IosAuthStatus.whenInUse,
          ),
        );
        await tester.pumpAndSettle();

        // Initially OFF → the note is not shown.
        expect(
          find.textContaining('with your current permission'),
          findsNothing,
        );

        // Enable: disclosure accepted → setEnabled(true) → the success branch
        // invalidates iosLocationPermissionProvider, which re-reads the still
        // while-in-use status, so the note appears.
        await tester.tap(find.byKey(WidgetKeys.backgroundSharingTile));
        await tester.pumpAndSettle();

        expect(
          find.textContaining('with your current permission'),
          findsOneWidget,
        );
        expect(find.text('Open settings'), findsOneWidget);
      },
    );

    // -------------------------------------------------------------------------
    // Tests 12–15: the standing battery-optimization advisory.
    //
    // `ensurePermissions` asks for the exemption exactly ONCE, when background
    // sharing is first enabled, and a decline is common. Before this the
    // answer reached only a transient snackbar (and onboarding discarded it
    // outright), so a user whose OEM keeps killing the foreground service had
    // no way to discover why.
    // -------------------------------------------------------------------------
    testWidgets(
      '12. a persisted battery-optimization denial renders a standing '
      'advisory with an action',
      (tester) async {
        SharedPreferences.setMockInitialValues({
          kBackgroundSharingKey: true,
          kLocationDisclosureBackgroundAcceptedKey: true,
        });

        await tester.pumpWidget(
          _buildApp(
            ensurePermissions: _stubThatThrows(),
            fakeDisclosure: _FakeDisclosureController(false),
            isAndroid: true,
            batteryOptProbe: () async => true,
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.textContaining('Battery optimization is still on'),
          findsOneWidget,
        );
        expect(find.text('Open settings'), findsOneWidget);
      },
    );

    testWidgets(
      '13. the advisory is hidden while the exemption is granted, and on iOS',
      (tester) async {
        SharedPreferences.setMockInitialValues({
          kBackgroundSharingKey: true,
          kLocationDisclosureBackgroundAcceptedKey: true,
        });

        // Exemption granted on Android → nothing to advise about.
        await tester.pumpWidget(
          _buildApp(
            ensurePermissions: _stubThatThrows(),
            fakeDisclosure: _FakeDisclosureController(false),
            isAndroid: true,
            batteryOptProbe: () async => false,
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.textContaining('Battery optimization is still on'),
          findsNothing,
        );

        // Off Android the probe must never even be CALLED: battery
        // optimization is an Android concept, the plugin channel does not
        // exist there, and a flag restored from an Android backup must not
        // surface irrelevant advice. The probe throws to prove it is unused.
        await tester.pumpWidget(
          _buildApp(
            ensurePermissions: _stubThatThrows(),
            fakeDisclosure: _FakeDisclosureController(false),
            batteryOptProbe: () async =>
                throw StateError('probe must not run off Android'),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.textContaining('Battery optimization is still on'),
          findsNothing,
        );
      },
    );

    testWidgets(
      '14. the advisory is hidden while background sharing is off',
      (tester) async {
        SharedPreferences.setMockInitialValues({});

        await tester.pumpWidget(
          _buildApp(
            ensurePermissions: _stubThatThrows(),
            fakeDisclosure: _FakeDisclosureController(false),
            isAndroid: true,
            batteryOptProbe: () async => true,
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.textContaining('Battery optimization is still on'),
          findsNothing,
          reason:
              'no foreground service exists to be killed while sharing is '
              'off; advising about it there is noise',
        );
      },
    );

    testWidgets(
      '15. the advisory action opens the system screen and clears once the '
      'exemption is granted there',
      (tester) async {
        SharedPreferences.setMockInitialValues({
          kBackgroundSharingKey: true,
          kLocationDisclosureBackgroundAcceptedKey: true,
        });

        var opened = 0;
        // The system screen reports nothing back, so the page re-probes on
        // return. Model the user granting it while they were away.
        var denied = true;

        await tester.pumpWidget(
          _buildApp(
            ensurePermissions: _stubThatThrows(),
            fakeDisclosure: _FakeDisclosureController(false),
            isAndroid: true,
            batteryOptProbe: () async => denied,
            openBatteryOptSettings: () async {
              opened++;
              return denied = false;
            },
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.textContaining('Battery optimization is still on'),
          findsOneWidget,
        );

        await tester.tap(find.text('Open settings'));
        await tester.pumpAndSettle();

        expect(opened, equals(1));
        expect(
          find.textContaining('Battery optimization is still on'),
          findsNothing,
          reason:
              'a granted exemption must clear the advisory without leaving '
              'the page — otherwise it reads as a warning about a solved '
              'problem',
        );
      },
    );

    testWidgets(
      '16. the advisory tracks an exemption changed OUTSIDE Haven, both ways',
      (tester) async {
        // The exemption can be granted or revoked from Android Settings, or
        // by an OEM battery manager, without ever passing through
        // `setEnabled` or the advisory's own button. A page that trusted the
        // persisted flag would assert "battery optimization is still on"
        // forever after a grant made outside the app — and would stay silent
        // forever after a revocation. Both directions are the live probe's
        // whole reason to exist.
        SharedPreferences.setMockInitialValues({
          kBackgroundSharingKey: true,
          kLocationDisclosureBackgroundAcceptedKey: true,
          // The persisted flag says "denied" and is deliberately WRONG here:
          // if the page read it instead of probing, this test would show the
          // advisory and fail on the first expectation.
          kBatteryOptimizationDeniedKey: true,
        });

        var denied = false;
        await tester.pumpWidget(
          _buildApp(
            ensurePermissions: _stubThatThrows(),
            fakeDisclosure: _FakeDisclosureController(false),
            isAndroid: true,
            batteryOptProbe: () async => denied,
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.textContaining('Battery optimization is still on'),
          findsNothing,
          reason:
              'granted outside Haven: the live OS answer must win over the '
              'stale persisted one',
        );

        // …and revoked later, again without Haven being told.
        denied = true;
        final element = tester.element(find.byType(LocationSettingsPage));
        ProviderScope.containerOf(
          element,
        ).invalidate(batteryOptimizationDeniedProvider);
        await tester.pumpAndSettle();

        expect(
          find.textContaining('Battery optimization is still on'),
          findsOneWidget,
          reason:
              'a revocation made outside Haven must bring the advisory back',
        );
      },
    );

    testWidgets(
      '17. the advisory stays on screen at a 200% text scale on the smallest '
      'phone',
      (tester) async {
        // Same shape as clock_skew_banner_test's 200% case. The advisory is
        // an `_ActionableNote`: a full-sentence message beside its icon, with
        // the action button STACKED UNDERNEATH rather than sitting alongside
        // — which is what lets both wrap at the largest scale either platform
        // offers. An advisory the user cannot read is the same as no
        // advisory, and the layout this replaced did not merely crowd, it
        // asserted and rendered an error box in the note's place.
        const viewport = Size(320, 568);
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = viewport;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        SharedPreferences.setMockInitialValues({
          kBackgroundSharingKey: true,
          kLocationDisclosureBackgroundAcceptedKey: true,
        });

        await tester.pumpWidget(
          _buildApp(
            ensurePermissions: _stubThatThrows(),
            fakeDisclosure: _FakeDisclosureController(false),
            isAndroid: true,
            batteryOptProbe: () async => true,
            textScaler: const TextScaler.linear(2),
          ),
        );
        await tester.pumpAndSettle();

        // The page is a ListView, so at this scale the advisory sits below
        // the fold and is not built until scrolled to — which is the correct
        // behaviour, and is why this scrolls rather than asserting it is
        // already on screen.
        final advisory =
            find.textContaining('Battery optimization is still on');
        await tester.scrollUntilVisible(advisory, 120);
        await tester.pumpAndSettle();

        expect(advisory, findsOneWidget);
        expect(find.text('Open settings'), findsOneWidget);
        expect(
          tester.takeException(),
          isNull,
          reason: 'the advisory row must not overflow at a 200% text scale',
        );
      },
    );

    testWidgets(
      '18. the iOS "Always required" note also survives a 200% text scale',
      (tester) async {
        // The battery advisory and this note share one layout
        // (`_ActionableNote`), because both used to be a ListTile whose
        // trailing button consumed the whole tile at this scale. This note
        // predates the advisory, so without its own case the shared fix would
        // be pinned on only one of the two users.
        const viewport = Size(320, 568);
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = viewport;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        SharedPreferences.setMockInitialValues({
          kBackgroundSharingKey: true,
          kLocationDisclosureBackgroundAcceptedKey: true,
        });

        await tester.pumpWidget(
          _buildApp(
            ensurePermissions: _stubThatThrows(),
            fakeDisclosure: _FakeDisclosureController(false),
            iosAuthStatus: IosAuthStatus.whenInUse,
            textScaler: const TextScaler.linear(2),
          ),
        );
        await tester.pumpAndSettle();

        final note = find.textContaining('with your current permission');
        await tester.scrollUntilVisible(note, 120);
        await tester.pumpAndSettle();

        expect(note, findsOneWidget);
        expect(find.text('Open settings'), findsOneWidget);
        expect(
          tester.takeException(),
          isNull,
          reason: 'the iOS note must not overflow at a 200% text scale',
        );
      },
    );

    // -------------------------------------------------------------------------
    // Tests 19-26: the iOS guidance card.
    //
    // The card is TWO sentences: a base that names no indicator, then exactly
    // one of the two indicator sentences. The card is gated on the TIER
    // (Always) and the indicator sentence on the SESSION HANDLER's own state —
    // never on the tier alone, because a provisional Always reports
    // `.authorizedAlways` while the OS still treats the app as While-In-Use and
    // keeps showing it the blue bar.
    //
    // The paragraph is asserted by EQUALITY against the localizations the page
    // itself resolved, not against copied fragments: the card's promise is
    // which sentences are composed, in which order, and a fragment match cannot
    // see a third sentence appended after the ones it looked for. A third
    // sentence is the defect this shape pins, and the inducement to grant
    // "Always" was the one that got in: the card renders ONLY for readers who
    // already hold Always, so anything urging them to grant it contradicts the
    // sentence it sits beside. Equality in both indicator states (19 and 20) is
    // what catches such a sentence being composed back in.
    // -------------------------------------------------------------------------

    /// The localizations the page itself resolved.
    ///
    /// Assertions read the same values the widget composed, so a reworded
    /// string cannot make a composition test pass by no longer matching.
    AppLocalizations l10nOf(WidgetTester tester) =>
        AppLocalizations.of(tester.element(find.byType(LocationSettingsPage)));

    /// The composed guidance paragraph, or null when the card is not rendered.
    ///
    /// The card is found by its BASE sentence, which no other string on the
    /// page contains — the bar sentence would also match the While-In-Use note.
    String? iosCardParagraph(WidgetTester tester) {
      final finder = find.textContaining(
        l10nOf(tester).locationSettingsIosGuidance,
      );
      final matches = finder.evaluate();
      if (matches.isEmpty) return null;
      expect(
        matches,
        hasLength(1),
        reason: 'the card is ONE Text, so VoiceOver reads one paragraph '
            'instead of one swipe per sentence',
      );
      return tester.widget<Text>(finder).data;
    }

    testWidgets(
      '19. under an unconfirmed Always the card is the base sentence then the '
      'blue location bar, and nothing else',
      (tester) async {
        SharedPreferences.setMockInitialValues({
          kBackgroundSharingKey: true,
          kLocationDisclosureBackgroundAcceptedKey: true,
        });

        await tester.pumpWidget(
          _buildApp(
            ensurePermissions: _stubThatThrows(),
            fakeDisclosure: _FakeDisclosureController(false),
            iosSession: _FakeIosBackgroundSession(armed: true),
          ),
        );
        await tester.pumpAndSettle();

        final l10n = l10nOf(tester);
        expect(
          iosCardParagraph(tester),
          '${l10n.locationSettingsIosGuidance} '
          '${l10n.locationSettingsIosIndicatorBar}',
        );
      },
    );

    testWidgets(
      '20. once Always is confirmed and the session released, the card is the '
      'base sentence then the status-bar arrow, and nothing else',
      (tester) async {
        // The OD1 shape: no activity session, no blue bar. The card still has
        // something true to say — the arrow and the Location Services listing
        // are the signals this user has — but promising the bar here would be
        // a claim about something they cannot see.
        SharedPreferences.setMockInitialValues({
          kBackgroundSharingKey: true,
          kLocationDisclosureBackgroundAcceptedKey: true,
        });

        await tester.pumpWidget(
          _buildApp(
            ensurePermissions: _stubThatThrows(),
            fakeDisclosure: _FakeDisclosureController(false),
            iosSession: _FakeIosBackgroundSession(
              armed: true,
              alwaysConfirmed: true,
            ),
          ),
        );
        await tester.pumpAndSettle();

        final l10n = l10nOf(tester);
        expect(
          iosCardParagraph(tester),
          '${l10n.locationSettingsIosGuidance} '
          '${l10n.locationSettingsIosIndicatorArrow}',
        );
      },
    );

    testWidgets(
      '21. no guidance card under any tier that is not Always, however the '
      'session handler answers',
      (tester) async {
        // It used to render for every reading that was not exactly
        // `whenInUse`, so a user who had DENIED location was told how their
        // location session behaves.
        for (final tier in const <IosAuthStatus>[
          IosAuthStatus.denied,
          IosAuthStatus.notDetermined,
          IosAuthStatus.restricted,
          IosAuthStatus.unknown,
          IosAuthStatus.whenInUse,
        ]) {
          SharedPreferences.setMockInitialValues({
            kBackgroundSharingKey: true,
            kLocationDisclosureBackgroundAcceptedKey: true,
          });

          await tester.pumpWidget(
            _buildApp(
              ensurePermissions: _stubThatThrows(),
              fakeDisclosure: _FakeDisclosureController(false),
              iosAuthStatus: tier,
              iosSession: _FakeIosBackgroundSession(armed: true),
            ),
          );
          await tester.pumpAndSettle();

          expect(
            iosCardParagraph(tester),
            isNull,
            reason: 'the card claims things that are only true under Always, '
                'and $tier is not Always',
          );
        }
      },
    );

    testWidgets(
      '22. the permission and indicator readings are re-read on resume',
      (tester) async {
        // Both change in ONE trip to Settings: the user answers the "Always"
        // prompt, and the diagnostic that confirms it releases the activity
        // session. Without the resume re-read the page would keep promising a
        // blue bar that is no longer on screen.
        SharedPreferences.setMockInitialValues({
          kBackgroundSharingKey: true,
          kLocationDisclosureBackgroundAcceptedKey: true,
        });
        final auth = _FakeIosLocationAuth(IosAuthStatus.always);
        final session = _FakeIosBackgroundSession(armed: true);

        await tester.pumpWidget(
          _buildApp(
            ensurePermissions: _stubThatThrows(),
            fakeDisclosure: _FakeDisclosureController(false),
            iosAuth: auth,
            iosSession: session,
          ),
        );
        await tester.pumpAndSettle();
        final l10n = l10nOf(tester);
        expect(
          iosCardParagraph(tester),
          contains(l10n.locationSettingsIosIndicatorBar),
        );

        // Away in Settings: the second prompt is answered and the diagnostic
        // confirms Always, so the handler drops the activity session. Driven
        // through the same door the OS uses, on a handler that is still armed
        // — the only way this transition happens on a device.
        session.confirmAlways();

        tester.binding
            .handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        tester.binding
            .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await tester.pumpAndSettle();

        expect(
          iosCardParagraph(tester),
          '${l10n.locationSettingsIosGuidance} '
          '${l10n.locationSettingsIosIndicatorArrow}',
        );
      },
    );

    testWidgets(
      '23. the card reads base, then the indicator sentence, in one paragraph',
      (tester) async {
        // One paragraph, in one semantics node, in this order: what Haven is
        // doing, and only then what the user can see while it does. The
        // sentence order is the whole reason these two are concatenated rather
        // than stacked in a Column.
        SharedPreferences.setMockInitialValues({
          kBackgroundSharingKey: true,
          kLocationDisclosureBackgroundAcceptedKey: true,
        });

        await tester.pumpWidget(
          _buildApp(
            ensurePermissions: _stubThatThrows(),
            fakeDisclosure: _FakeDisclosureController(false),
            iosSession: _FakeIosBackgroundSession(armed: true),
          ),
        );
        await tester.pumpAndSettle();

        final l10n = l10nOf(tester);
        final text = iosCardParagraph(tester)!;
        expect(
          text.indexOf(l10n.locationSettingsIosGuidance),
          isNonNegative,
        );
        expect(
          text.indexOf(l10n.locationSettingsIosGuidance),
          lessThan(text.indexOf(l10n.locationSettingsIosIndicatorBar)),
        );
      },
    );

    testWidgets(
      '24. an unconfirmed Always with no activity session still names the '
      'blue location bar',
      (tester) async {
        // `CLBackgroundActivitySession` is iOS 17+, and Haven deploys to
        // iOS 15.5: on iOS 15/16 no session can ever be held, so the handler
        // reports `backgroundActivitySessionHeld: false` while
        // `showsBackgroundLocationIndicator` — which the stream handler sets
        // from `!alwaysConfirmed` — is TRUE and the bar is on screen. The
        // same reading occurs on every iOS before the Always confirmation
        // lands. Selecting the sentence from the held flag showed those users
        // the arrow sentence while they were looking at the bar.
        SharedPreferences.setMockInitialValues({
          kBackgroundSharingKey: true,
          kLocationDisclosureBackgroundAcceptedKey: true,
        });

        await tester.pumpWidget(
          _buildApp(
            ensurePermissions: _stubThatThrows(),
            fakeDisclosure: _FakeDisclosureController(false),
            iosSession: _FakeIosBackgroundSession(
              armed: true,
              supported: false,
            ),
          ),
        );
        await tester.pumpAndSettle();

        final l10n = l10nOf(tester);
        expect(
          iosCardParagraph(tester),
          '${l10n.locationSettingsIosGuidance} '
          '${l10n.locationSettingsIosIndicatorBar}',
        );
      },
    );

    testWidgets(
      '25. no card at all while the indicator reading is unresolved',
      (tester) async {
        // One of the two sentences names what the user can SEE. Before the
        // session handler answers there is no honest sentence to pick, so the
        // card waits instead of guessing one — and a half-card, base sentence
        // alone, would be the same guess by omission.
        SharedPreferences.setMockInitialValues({
          kBackgroundSharingKey: true,
          kLocationDisclosureBackgroundAcceptedKey: true,
        });

        await tester.pumpWidget(
          _buildApp(
            ensurePermissions: _stubThatThrows(),
            fakeDisclosure: _FakeDisclosureController(false),
            iosSession: _FakeIosBackgroundSession(neverAnswers: true),
          ),
        );
        await tester.pumpAndSettle();

        expect(iosCardParagraph(tester), isNull);
      },
    );

    testWidgets(
      '26. background sharing OFF renders no card: a disarmed handler has '
      'measured nothing',
      (tester) async {
        // The state this page used to get wrong. While sharing is off the
        // native handler is disarmed, and `disarm()` clears `alwaysConfirmed`
        // unconditionally — so its `false` is a teardown residue, not a
        // reading of this device. Composed from it, the card told an iPhone
        // with Always granted that "iOS shows its blue location bar", at the
        // exact moment the reader was deciding whether to turn sharing on;
        // enabling then confirms Always, releases the activity session, and
        // hands them the arrow instead.
        //
        // Note what CANNOT be asserted here, because it cannot happen: a
        // confirmed Always with the toggle off. The double refuses to
        // construct it.
        SharedPreferences.setMockInitialValues({});

        await tester.pumpWidget(
          _buildApp(
            ensurePermissions: _stubThatThrows(),
            fakeDisclosure: _FakeDisclosureController(false),
            iosSession: _FakeIosBackgroundSession(),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          tester
              .widget<SwitchListTile>(
                find.byKey(WidgetKeys.backgroundSharingTile),
              )
              .value,
          isFalse,
        );
        expect(
          iosCardParagraph(tester),
          isNull,
          reason: 'no indicator sentence is known to be true of a reader '
              'whose handler is not running',
        );
      },
    );

    testWidgets(
      '27. turning sharing OFF withdraws the card in the same visit',
      (tester) async {
        // Disabling disarms the handler, so the sentence the card was showing
        // stops being a measurement the moment the toggle moves. Without the
        // re-read on the disable edge the page keeps rendering the reading it
        // fetched on entry, and the card outlives the session it describes.
        SharedPreferences.setMockInitialValues({
          kBackgroundSharingKey: true,
          kLocationDisclosureBackgroundAcceptedKey: true,
        });
        final session = _FakeIosBackgroundSession(armed: true);

        await tester.pumpWidget(
          _buildApp(
            ensurePermissions: _stubThatThrows(),
            fakeDisclosure: _FakeDisclosureController(false),
            iosSession: session,
          ),
        );
        await tester.pumpAndSettle();
        session.confirmAlways();
        tester.binding
          ..handleAppLifecycleStateChanged(AppLifecycleState.inactive)
          ..handleAppLifecycleStateChanged(AppLifecycleState.paused)
          ..handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await tester.pumpAndSettle();
        final l10n = l10nOf(tester);
        expect(
          iosCardParagraph(tester),
          '${l10n.locationSettingsIosGuidance} '
          '${l10n.locationSettingsIosIndicatorArrow}',
        );

        await tester.tap(find.byKey(WidgetKeys.backgroundSharingTile));
        await tester.pumpAndSettle();

        expect(session.armed, isFalse);
        expect(iosCardParagraph(tester), isNull);
      },
    );

    testWidgets(
      '28. turning sharing back on names the bar, as a fresh visit to the '
      'same state would',
      (tester) async {
        // The re-read on each edge is what makes those two agree. A freshly
        // armed handler has no diagnostic yet, holds the activity session, and
        // the blue bar IS up — the same paragraph test 19 pins for a page
        // opened in that state.
        SharedPreferences.setMockInitialValues({});
        final session = _FakeIosBackgroundSession();

        await tester.pumpWidget(
          _buildApp(
            ensurePermissions: _stubReturning(const EnsurePermissionsGranted()),
            fakeDisclosure: _FakeDisclosureController(true),
            iosSession: session,
          ),
        );
        await tester.pumpAndSettle();
        expect(iosCardParagraph(tester), isNull);

        await tester.tap(find.byKey(WidgetKeys.backgroundSharingTile));
        await tester.pumpAndSettle();

        expect(session.armed, isTrue);
        final l10n = l10nOf(tester);
        expect(
          iosCardParagraph(tester),
          '${l10n.locationSettingsIosGuidance} '
          '${l10n.locationSettingsIosIndicatorBar}',
        );
      },
    );

    testWidgets(
      '29. the guidance paragraph is no smaller than the page intro',
      (tester) async {
        // It is the one paragraph on the page whose whole job is to say what
        // the OS will show, and it used to be the smallest text on it.
        SharedPreferences.setMockInitialValues({
          kBackgroundSharingKey: true,
          kLocationDisclosureBackgroundAcceptedKey: true,
        });

        await tester.pumpWidget(
          _buildApp(
            ensurePermissions: _stubThatThrows(),
            fakeDisclosure: _FakeDisclosureController(false),
            iosSession: _FakeIosBackgroundSession(armed: true),
          ),
        );
        await tester.pumpAndSettle();

        final l10n = l10nOf(tester);
        final intro = tester
            .widget<Text>(find.text(l10n.locationSettingsIntro))
            .style
            ?.fontSize;
        final card = tester
            .widget<Text>(
              find.textContaining(l10n.locationSettingsIosGuidance),
            )
            .style
            ?.fontSize;
        expect(intro, isNotNull);
        expect(card, isNotNull);
        expect(card, greaterThanOrEqualTo(intro!));
      },
    );

    // -------------------------------------------------------------------------
    // The double itself: it is only evidence while it obeys the native
    // contract, and the last defect on this page was written INTO a fake that
    // did not.
    // -------------------------------------------------------------------------
    group('_FakeIosBackgroundSession models the native handler', () {
      test('disarming clears the Always confirmation', () async {
        final session = _FakeIosBackgroundSession(armed: true)
          ..confirmAlways();
        expect((await session.status()).alwaysConfirmed, isTrue);

        await session.disarm();

        final status = await session.status();
        expect(status.armed, isFalse);
        expect(
          status.alwaysConfirmed,
          isFalse,
          reason: 'the confirmation belonged to the session just released',
        );
      });

      test('re-arming does not restore the confirmation', () async {
        final session = _FakeIosBackgroundSession(armed: true)
          ..confirmAlways();
        await session.disarm();
        await session.arm();

        final status = await session.status();
        expect(status.armed, isTrue);
        expect(
          status.alwaysConfirmed,
          isFalse,
          reason: 'only a fresh diagnostic on the new session can confirm '
              'again — until then the blue bar is what the user sees',
        );
      });

      test('a confirmation cannot arrive on a handler that holds no '
          'session', () {
        expect(
          _FakeIosBackgroundSession().confirmAlways,
          throwsStateError,
        );
      });

      test('confirmed-while-disarmed cannot even be constructed', () {
        expect(
          () => _FakeIosBackgroundSession(alwaysConfirmed: true),
          throwsA(isA<AssertionError>()),
        );
      });
    });
  });

  /// The indicator sentence is chosen from `alwaysConfirmed` — the same value
  /// both native branches decide from.
  ///
  /// Never from the authorization tier: a provisional Always reports
  /// `.authorizedAlways` while the OS still treats the app as While-In-Use,
  /// and every iOS 17 Always user is in the same position (no diagnostics API
  /// to confirm with). And never from `backgroundActivitySessionHeld`: the
  /// session type is iOS 17+, so on the iOS 15/16 floor of Haven's deployment
  /// target nothing is ever held while `showsBackgroundLocationIndicator`
  /// (`= !alwaysConfirmed`) still puts the bar on screen.
  group('iosIndicatorSentenceProvider', () {
    Future<IosIndicatorSentence?> sentenceFor(
      _FakeIosBackgroundSession session,
    ) async {
      final container = ProviderContainer(
        overrides: [
          iosBackgroundSessionServiceProvider.overrideWithValue(session),
        ],
      );
      addTearDown(container.dispose);
      return container.read(iosIndicatorSentenceProvider.future);
    }

    test('a held activity session means the blue bar', () async {
      expect(
        await sentenceFor(_FakeIosBackgroundSession(armed: true)),
        IosIndicatorSentence.bar,
      );
    });

    test('a provisional Always keeps the bar, tier notwithstanding', () async {
      // Tier `.authorizedAlways`, `alwaysConfirmed` false: the handler still
      // holds the session, so the honest sentence is the bar one.
      expect(
        await sentenceFor(_FakeIosBackgroundSession(armed: true)),
        IosIndicatorSentence.bar,
      );
    });

    test('an OS too old to hold a session still means the blue bar', () async {
      // iOS 15/16: no `CLBackgroundActivitySession` exists, so the handler
      // reports `supported: false` and holds nothing — while the indicator
      // flag it derives from the same unconfirmed `alwaysConfirmed` is on.
      expect(
        await sentenceFor(
          _FakeIosBackgroundSession(armed: true, supported: false),
        ),
        IosIndicatorSentence.bar,
      );
    });

    test('a confirmed Always with no session held means the arrow', () async {
      expect(
        await sentenceFor(
          _FakeIosBackgroundSession(armed: true, alwaysConfirmed: true),
        ),
        IosIndicatorSentence.arrow,
      );
    });

    test('a disarmed handler yields no sentence at all', () async {
      // The repair for the conflation: while nothing is running, the handler's
      // `alwaysConfirmed: false` is what `disarm()` wrote, not what a
      // diagnostic found. Answering "bar" from it is a claim about a session
      // that does not exist — and the one the page made to every reader with
      // sharing off.
      expect(
        await sentenceFor(_FakeIosBackgroundSession()),
        isNull,
      );
    });

    test('a handler that never answered yields no sentence either', () async {
      // The channel fallback reports every field false, `armed` included, so
      // a missing native handler cannot be read as a measurement.
      expect(
        await sentenceFor(
          _FakeIosBackgroundSession(supported: false),
        ),
        isNull,
      );
    });
  });
}
