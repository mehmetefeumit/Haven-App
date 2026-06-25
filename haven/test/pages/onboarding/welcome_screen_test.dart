/// Widget tests for [WelcomeScreen].
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/pages/onboarding/welcome_screen.dart';
import 'package:haven/src/widgets/common/haven_logo.dart';

import '../../helpers/localized_app_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('renders hero headline and CTA', (tester) async {
    await pumpLocalized(tester, const WelcomeScreen());

    expect(find.text('Haven'), findsOneWidget);
    // The subtitle renders as rich text (one word is emphasised in bold), so
    // match the full sentence across its spans.
    expect(
      find.text(
        'Share your location privately, only with those you want.',
        findRichText: true,
      ),
      findsOneWidget,
    );
    expect(find.text('Get Started'), findsOneWidget);
  });

  testWidgets('shows the Haven logo as the hero mark', (tester) async {
    await pumpLocalized(tester, const WelcomeScreen());

    expect(find.byType(HavenLogo), findsOneWidget);
  });
}
