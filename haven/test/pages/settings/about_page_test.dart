/// Widget tests for [AboutPage].
///
/// After the Privacy consolidation, About carries only identity, attribution
/// and legal content. The negative assertions below are the guard that the
/// privacy material does not creep back in: two copies of a claim across 13
/// locales is how the copy drifted out of sync with the code in the first place.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/pages/settings/about_page.dart';
import 'package:haven/src/widgets/common/haven_logo.dart';

import '../../helpers/localized_app_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('renders the Haven logo in the hero section', (tester) async {
    await pumpLocalized(tester, const AboutPage());

    expect(find.byType(HavenLogo), findsOneWidget);
    expect(find.text('Haven'), findsOneWidget);
    // Guard the surrounding page plumbing so a hero change can't silently
    // drop the value-prop rows or the footer.
    expect(find.text('Only your circles can see you'), findsOneWidget);
    expect(find.text('Version 0.1.0'), findsOneWidget);
  });

  testWidgets('keeps the legal and attribution actions', (tester) async {
    await pumpLocalized(tester, const AboutPage());

    expect(find.text('Open-source licenses'), findsOneWidget);
    expect(find.text('Report a map issue'), findsOneWidget);
    expect(find.text('Support OpenStreetMap'), findsOneWidget);
  });

  testWidgets('no longer carries the privacy disclosures', (tester) async {
    await pumpLocalized(tester, const AboutPage());

    // These moved to the Privacy section. If any reappears here, the app has
    // two divergent answers to the same question again.
    expect(find.text('Who can see what'), findsNothing);
    expect(find.textContaining('Relay operators'), findsNothing);
    expect(find.textContaining('FLAG_SECURE'), findsNothing);
    expect(find.textContaining('VPN'), findsNothing);
    expect(find.textContaining('mullvad'), findsNothing);
  });
}
