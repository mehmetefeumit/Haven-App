/// Widget tests for [ReadyScreen].
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/pages/onboarding/onboarding_strings.dart';
import 'package:haven/src/pages/onboarding/ready_screen.dart';
import 'package:haven/src/providers/onboarding_provider.dart';
import 'package:haven/src/providers/relay_preferences_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../mocks/mock_relay_preferences_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Enter Haven CTA flips the completed flag', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final mockPrefs = MockRelayPreferencesService();
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
            (ref) async => mockPrefs,
          ),
        ],
        child: const MaterialApp(home: ReadyScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text(OnboardingStrings.readyTitle), findsOneWidget);
    expect(find.text(OnboardingStrings.readyCta), findsOneWidget);

    await tester.tap(find.text(OnboardingStrings.readyCta));
    // Success path leaves the spinner running forever; the production
    // parent flips the screen away. Pump a bounded number of frames.
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(kOnboardingCompletedKey), isTrue);
  });
}
