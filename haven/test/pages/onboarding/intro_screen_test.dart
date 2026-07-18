/// Widget tests for [IntroScreen] — the merged intro page (page 1 of 2).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/pages/onboarding/intro_screen.dart';
import 'package:haven/src/providers/onboarding_provider.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/widgets/common/haven_logo.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/localized_app_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  List<Override> overrides() => [
    onboardingControllerProvider.overrideWith(
      (ref) => OnboardingController(OnboardingFlags.none),
    ),
  ];

  testWidgets('renders the hero, all three value props, and the CTA', (
    tester,
  ) async {
    await pumpLocalized(
      tester,
      const IntroScreen(),
      overrides: overrides(),
    );

    expect(find.byType(HavenLogo), findsOneWidget);
    expect(find.text('Haven'), findsOneWidget);
    expect(find.text('What makes Haven different'), findsOneWidget);
    expect(find.text('Only your circles can see you'), findsOneWidget);
    expect(find.text('No one can shut it down'), findsOneWidget);
    expect(find.text('No account needed'), findsOneWidget);
    expect(find.byKey(WidgetKeys.introCta), findsOneWidget);
    expect(find.text('Get Started'), findsOneWidget);
  });

  testWidgets('tapping "Get Started" flips the intro_seen flag', (tester) async {
    await pumpLocalized(
      tester,
      const IntroScreen(),
      overrides: overrides(),
      // The CTA shows an indefinite spinner after tap; don't settle.
      settle: false,
    );

    final container = ProviderScope.containerOf(
      tester.element(find.byType(IntroScreen)),
    );
    expect(container.read(onboardingControllerProvider).introSeen, isFalse);

    await tester.tap(find.byKey(WidgetKeys.introCta));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(container.read(onboardingControllerProvider).introSeen, isTrue);
  });

  testWidgets('does not scroll on a common phone viewport (390x844)', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await pumpLocalized(
      tester,
      const IntroScreen(),
      overrides: overrides(),
    );

    expect(tester.takeException(), isNull);
    final position = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position;
    expect(
      position.maxScrollExtent,
      0,
      reason: 'IntroScreen must fit without scrolling on a 390x844 phone',
    );
  });
}
