/// Widget tests for [AboutPage].
///
/// About carries only identity, attribution and legal content. The negative
/// assertions below are the guard that the removed privacy explainer does not
/// creep back in: copy across 13 locales is how the claims drifted out of sync
/// with the code in the first place.
library;

import 'package:flutter/material.dart';
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
    // drop the footer.
    expect(find.text('Version 0.1.0'), findsOneWidget);
  });

  testWidgets('keeps the legal and attribution actions', (tester) async {
    await pumpLocalized(tester, const AboutPage());

    expect(find.text('Open-source licenses'), findsOneWidget);
    expect(find.text('Report a map issue'), findsOneWidget);
    expect(find.text('Support OpenStreetMap'), findsOneWidget);
  });

  testWidgets('no longer carries the value-prop cards', (tester) async {
    await pumpLocalized(tester, const AboutPage());

    // The three feature cards were removed: About is identity, attribution and
    // legal only, and the value props are the onboarding intro screen's job.
    expect(find.text('Only your circles can see you'), findsNothing);
    expect(find.text('No one can shut it down'), findsNothing);
    expect(find.text('No account needed'), findsNothing);

    // The card assertion is the copy-independent half: the legal actions are
    // the only Card left, so nothing sits between the hero tagline and the
    // licenses tile.
    expect(find.byType(Card), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Open-source licenses')).dy,
      greaterThan(
        tester
            .getBottomLeft(
              find.text('Private and censorship-resistant location sharing.'),
            )
            .dy,
      ),
    );
  });

  testWidgets('no longer carries the privacy disclosures', (tester) async {
    await pumpLocalized(tester, const AboutPage());

    // The explainer was removed from the app outright; if any of it reappears
    // here it has to be kept accurate again in thirteen languages.
    expect(find.text('Who can see what'), findsNothing);
    expect(find.textContaining('Relay operators'), findsNothing);
    expect(find.textContaining('FLAG_SECURE'), findsNothing);
    expect(find.textContaining('VPN'), findsNothing);
    expect(find.textContaining('mullvad'), findsNothing);
  });
}
