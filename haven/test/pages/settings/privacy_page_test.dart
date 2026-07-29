/// Widget tests for [PrivacyPage] (the Privacy hub).
///
/// The hub's design promise is that a reader who taps nothing still gets an
/// answer, so the always-visible summary is asserted as strictly as the
/// navigation is.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/pages/settings/privacy_content.dart';
import 'package:haven/src/pages/settings/privacy_page.dart';
import 'package:haven/src/pages/settings/privacy_topic_page.dart';
import 'package:haven/src/test_keys.dart';

import '../../helpers/localized_app_harness.dart';

/// Scrolls [finder] into view, tolerating a target that is already visible.
///
/// The hub grows a tile per topic, so it outgrows one viewport; a [ListView]
/// builds no element for an off-screen child.
Future<void> _reveal(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isNotEmpty) return;
  await tester.scrollUntilVisible(finder, 200);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('shows the plain-language summary without any interaction', (
    tester,
  ) async {
    await pumpLocalized(tester, const PrivacyPage());
    final l10n = l10nOf(tester, PrivacyPage);

    // The thirty-second answer must be on screen at first paint, not behind a
    // tap or a scroll.
    expect(find.text(l10n.privacyHubSummary), findsOneWidget);
    expect(find.text(l10n.privacyTitle), findsOneWidget);
  });

  testWidgets('lists every topic in the content model exactly once', (
    tester,
  ) async {
    await pumpLocalized(tester, const PrivacyPage());
    final l10n = l10nOf(tester, PrivacyPage);

    final listed = privacyTopicGroups
        .expand((group) => group.topics)
        .toList();
    // Guards against a topic being added to the enum but never surfaced, which
    // would leave its content unreachable.
    expect(listed.toSet(), PrivacyTopic.values.toSet());

    for (final topic in listed) {
      final tile = find.byKey(WidgetKeys.privacyTopicTile(topic.name));
      await _reveal(tester, tile);
      expect(tile, findsOneWidget, reason: 'no hub tile for ${topic.name}');
      expect(find.text(privacyTopicTitle(l10n, topic)), findsOneWidget);
    }
  });

  testWidgets('renders a header for every group', (tester) async {
    await pumpLocalized(tester, const PrivacyPage());
    final l10n = l10nOf(tester, PrivacyPage);

    for (final group in privacyTopicGroups) {
      final heading = find.text(group.heading(l10n));
      await _reveal(tester, heading);
      expect(heading, findsOneWidget);
    }
  });

  testWidgets('groups partition the topics with no gaps or duplicates', (
    tester,
  ) async {
    // Guards the two ways the hub can silently misrepresent the content model:
    // a topic listed twice, or a topic in the enum that no group surfaces.
    final listed = privacyTopicGroups.expand((g) => g.topics).toList();
    expect(listed.length, listed.toSet().length, reason: 'duplicate tile');
    expect(listed.toSet(), PrivacyTopic.values.toSet());
  });

  for (final topic in PrivacyTopic.values) {
    testWidgets('tapping the ${topic.name} tile opens its topic page', (
      tester,
    ) async {
      await pumpLocalized(tester, const PrivacyPage());

      final tile = find.byKey(WidgetKeys.privacyTopicTile(topic.name));
      await _reveal(tester, tile);
      await tester.tap(tile);
      await tester.pumpAndSettle();

      final page = tester.widget<PrivacyTopicPage>(
        find.byType(PrivacyTopicPage),
      );
      expect(page.topic, topic);
    });
  }
}
