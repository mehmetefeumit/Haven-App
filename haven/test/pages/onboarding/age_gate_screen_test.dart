/// Widget tests for [AgeGateScreen].
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/pages/onboarding/age_gate_screen.dart';
import 'package:haven/src/pages/onboarding/onboarding_strings.dart';
import 'package:haven/src/providers/onboarding_provider.dart';
import 'package:haven/src/test_keys.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget buildHarness({OnboardingController? controller}) {
    final ctrl = controller ?? OnboardingController(OnboardingFlags.none);
    return ProviderScope(
      overrides: [
        onboardingControllerProvider.overrideWith((ref) => ctrl),
      ],
      child: const MaterialApp(home: AgeGateScreen()),
    );
  }

  testWidgets('renders title, body, confirm CTA and under CTA', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(buildHarness());
    await tester.pumpAndSettle();

    expect(find.text(OnboardingStrings.ageGateTitle), findsOneWidget);
    expect(find.text(OnboardingStrings.ageGateBody), findsOneWidget);
    expect(find.text(OnboardingStrings.ageGateConfirmCta), findsOneWidget);
    expect(find.text(OnboardingStrings.ageGateUnderCta), findsOneWidget);
  });

  testWidgets(
    'tapping confirm sets ageConfirmed in state and persists the key',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final controller = OnboardingController(OnboardingFlags.none);

      await tester.pumpWidget(buildHarness(controller: controller));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(WidgetKeys.ageGateConfirm));
      // Success path leaves a spinner; pump bounded frames rather than
      // pumpAndSettle to avoid a never-settling hang.
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      // In-memory state updated.
      expect(controller.state.ageConfirmed, isTrue);

      // Persisted.
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(kAgeConfirmedKey), isTrue);
    },
  );

  testWidgets(
    'tapping under-13 CTA shows the AlertDialog without confirming age',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final controller = OnboardingController(OnboardingFlags.none);

      await tester.pumpWidget(buildHarness(controller: controller));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(WidgetKeys.ageGateUnder));
      await tester.pumpAndSettle();

      // Under-13 dialog must appear.
      expect(
        find.text(OnboardingStrings.ageGateUnderTitle),
        findsOneWidget,
      );
      expect(
        find.text(OnboardingStrings.ageGateUnderBody),
        findsOneWidget,
      );

      // ageConfirmed must NOT have been set.
      expect(controller.state.ageConfirmed, isFalse);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(kAgeConfirmedKey), isNot(isTrue));
    },
  );

  testWidgets(
    'under-13 dialog can be dismissed and does not block further use',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(buildHarness());
      await tester.pumpAndSettle();

      // Open under-13 dialog.
      await tester.tap(find.byKey(WidgetKeys.ageGateUnder));
      await tester.pumpAndSettle();

      // Dismiss it via the OK button.
      await tester.tap(find.text(OnboardingStrings.ageGateUnderDismiss));
      await tester.pumpAndSettle();

      // Dialog gone; main screen still visible.
      expect(
        find.text(OnboardingStrings.ageGateUnderTitle),
        findsNothing,
      );
      expect(find.byKey(WidgetKeys.ageGateConfirm), findsOneWidget);
    },
  );
}
