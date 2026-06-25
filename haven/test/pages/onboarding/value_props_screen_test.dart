/// Widget tests for [ValuePropsScreen].
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/pages/onboarding/value_props_screen.dart';
import 'package:haven/src/providers/onboarding_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/localized_app_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  List<Override> buildOverrides({
    OnboardingFlags initialFlags = OnboardingFlags.none,
  }) {
    return [
      onboardingControllerProvider.overrideWith(
        (ref) => OnboardingController(initialFlags),
      ),
    ];
  }

  testWidgets('renders title, all three cards, and CTA', (tester) async {
    SharedPreferences.setMockInitialValues({});

    await pumpLocalized(
      tester,
      const ValuePropsScreen(),
      overrides: buildOverrides(),
    );

    expect(find.text('What makes Haven different'), findsOneWidget);
    expect(find.text('Only your circles can see you'), findsOneWidget);
    expect(find.text('No one can shut it down'), findsOneWidget);
    expect(find.text('No account needed'), findsOneWidget);
    expect(find.text('Continue'), findsOneWidget);
  });

  testWidgets('Continue flips intro_seen and persists it', (tester) async {
    SharedPreferences.setMockInitialValues({});

    await pumpLocalized(
      tester,
      const ValuePropsScreen(),
      overrides: buildOverrides(),
    );

    await tester.tap(find.text('Continue'));
    // Avoid pumpAndSettle: Navigator.pop after marking runs without the
    // enclosing shell, so the route-pop settle never terminates.
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(kOnboardingIntroSeenKey), isTrue);
  });
}
