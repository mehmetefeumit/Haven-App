/// Widget tests for [ReadyScreen].
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/constants/location.dart';
import 'package:haven/src/pages/onboarding/ready_screen.dart';
import 'package:haven/src/providers/onboarding_provider.dart';
import 'package:haven/src/providers/relay_preferences_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/location_service.dart';
import 'package:haven/src/test_keys.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../mocks/mock_relay_preferences_service.dart';

/// Minimal [LocationService] fake. Onboarding only calls [requestPermission];
/// every other member is unused and asserts if reached.
class _FakeLocationService implements LocationService {
  bool requestPermissionCalled = false;

  @override
  Future<bool> requestPermission() async {
    requestPermissionCalled = true;
    return true;
  }

  @override
  Future<LocationPermissionStatus> checkPermission() =>
      throw UnimplementedError();

  @override
  Future<Position> getCurrentLocation() => throw UnimplementedError();

  @override
  Future<Position> getCurrentLocationFresh() => throw UnimplementedError();

  @override
  Stream<Position> getLocationStream() => throw UnimplementedError();

  @override
  Future<bool> isLocationServiceEnabled() => throw UnimplementedError();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<_FakeLocationService> pumpReady(WidgetTester tester) async {
    final fakeLocation = _FakeLocationService();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          onboardingControllerProvider.overrideWith(
            (ref) => OnboardingController(
              const OnboardingFlags(
                introSeen: true,
                displayNameSet: true,
                completed: false,
              ),
            ),
          ),
          relayPreferencesServiceProvider.overrideWith(
            (ref) async => MockRelayPreferencesService(),
          ),
          locationServiceProvider.overrideWithValue(fakeLocation),
        ],
        child: const MaterialApp(home: ReadyScreen()),
      ),
    );
    await tester.pumpAndSettle();
    return fakeLocation;
  }

  // The success path leaves the CTA spinner running forever (the production
  // parent swaps the screen away), so pumpAndSettle can't be used after the
  // tap. Pump a bounded number of frames instead.
  Future<void> pumpFrames(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets(
    'accepting the disclosure completes onboarding and enables background '
    'sharing',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final fakeLocation = await pumpReady(tester);

      await tester.tap(find.byKey(WidgetKeys.readyCta));
      await pumpFrames(tester);

      // The single informational pop-up appears before any permission request.
      expect(find.byKey(WidgetKeys.locationDisclosureAgree), findsOneWidget);
      // Disclosure-before-collection: nothing may be requested until consent.
      expect(
        fakeLocation.requestPermissionCalled,
        isFalse,
        reason: 'no OS permission may be requested before the user consents',
      );

      await tester.tap(find.byKey(WidgetKeys.locationDisclosureAgree));
      await pumpFrames(tester);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(kOnboardingCompletedKey), isTrue);
      expect(prefs.getBool(kBackgroundSharingKey), isTrue);
      expect(fakeLocation.requestPermissionCalled, isTrue);
    },
  );

  testWidgets(
    'declining the disclosure still completes onboarding without background '
    'sharing',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final fakeLocation = await pumpReady(tester);

      await tester.tap(find.byKey(WidgetKeys.readyCta));
      await pumpFrames(tester);

      expect(find.byKey(WidgetKeys.locationDisclosureNotNow), findsOneWidget);
      await tester.tap(find.byKey(WidgetKeys.locationDisclosureNotNow));
      await pumpFrames(tester);

      final prefs = await SharedPreferences.getInstance();
      // Declining must not trap the user in onboarding.
      expect(prefs.getBool(kOnboardingCompletedKey), isTrue);
      // ...but nothing was requested or enabled.
      expect(prefs.getBool(kBackgroundSharingKey), isNot(true));
      expect(fakeLocation.requestPermissionCalled, isFalse);
    },
  );

  testWidgets(
    'previously-accepted disclosure skips the pop-up and still sets up sharing',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        kLocationDisclosureAcceptedKey: true,
        kLocationDisclosureBackgroundAcceptedKey: true,
      });
      final fakeLocation = await pumpReady(tester);

      await tester.tap(find.byKey(WidgetKeys.readyCta));
      await pumpFrames(tester);

      // Already consented previously — no dialog shown.
      expect(find.byKey(WidgetKeys.locationDisclosureAgree), findsNothing);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(kOnboardingCompletedKey), isTrue);
      expect(prefs.getBool(kBackgroundSharingKey), isTrue);
      expect(fakeLocation.requestPermissionCalled, isTrue);
    },
  );
}
