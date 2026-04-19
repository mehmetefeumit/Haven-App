/// Widget tests for [ValuePropsScreen].
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/pages/onboarding/onboarding_strings.dart';
import 'package:haven/src/pages/onboarding/value_props_screen.dart';
import 'package:haven/src/providers/onboarding_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget buildHarness({OnboardingFlags initialFlags = OnboardingFlags.none}) {
    return ProviderScope(
      overrides: [
        onboardingControllerProvider.overrideWith(
          (ref) => OnboardingController(initialFlags),
        ),
      ],
      child: const MaterialApp(home: ValuePropsScreen()),
    );
  }

  testWidgets('renders title, all four cards, and CTA', (tester) async {
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(buildHarness());
    await tester.pumpAndSettle();

    expect(find.text(OnboardingStrings.valuePropsTitle), findsOneWidget);
    expect(find.text(OnboardingStrings.valueProp1Title), findsOneWidget);
    expect(find.text(OnboardingStrings.valueProp2Title), findsOneWidget);
    expect(find.text(OnboardingStrings.valueProp3Title), findsOneWidget);
    expect(find.text(OnboardingStrings.valueProp4Title), findsOneWidget);
    expect(find.text(OnboardingStrings.valuePropsCta), findsOneWidget);
  });

  testWidgets('Continue flips intro_seen and persists it', (tester) async {
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(buildHarness());
    await tester.pumpAndSettle();

    await tester.tap(find.text(OnboardingStrings.valuePropsCta));
    // Avoid pumpAndSettle: Navigator.pop after marking runs without the
    // enclosing shell, so the route-pop settle never terminates.
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(kOnboardingIntroSeenKey), isTrue);
  });
}
