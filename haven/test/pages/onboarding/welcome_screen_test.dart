/// Widget tests for [WelcomeScreen].
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/pages/onboarding/onboarding_strings.dart';
import 'package:haven/src/pages/onboarding/welcome_screen.dart';
import 'package:haven/src/widgets/common/haven_logo.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('renders hero headline, subline and CTA', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: WelcomeScreen()));
    await tester.pumpAndSettle();

    expect(find.text(OnboardingStrings.appName), findsOneWidget);
    expect(find.text(OnboardingStrings.welcomeHeadline), findsOneWidget);
    expect(find.text(OnboardingStrings.welcomeSub), findsOneWidget);
    expect(find.text(OnboardingStrings.welcomeCta), findsOneWidget);
  });

  testWidgets('shows the Haven logo as the hero mark', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: WelcomeScreen()));
    await tester.pumpAndSettle();

    expect(find.byType(HavenLogo), findsOneWidget);
  });
}
