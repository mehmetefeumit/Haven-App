/// Widget tests for [AboutPage].
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/pages/onboarding/onboarding_strings.dart';
import 'package:haven/src/pages/settings/about_page.dart';
import 'package:haven/src/widgets/common/haven_logo.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('renders the Haven logo in the hero section', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: AboutPage()));
    await tester.pumpAndSettle();

    expect(find.byType(HavenLogo), findsOneWidget);
    expect(find.text('Haven'), findsOneWidget);
    // Guard the surrounding page plumbing so a hero change can't silently
    // drop the value-prop rows, the "who can see what" list, or the footer.
    expect(find.text(OnboardingStrings.valueProp1Title), findsOneWidget);
    expect(find.text('Who can see what'), findsOneWidget);
    expect(find.text('Version 0.1.0'), findsOneWidget);
  });
}
