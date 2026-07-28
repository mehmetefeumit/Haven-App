/// Widget tests for [PrivacyTopicPage].
///
/// Every assertion here is parameterised over all of [PrivacyTopic], so the
/// structural guarantees the renderer exists to enforce — navigable headings,
/// a takeaway block, opt-in technical depth, and reflowable prose — are proven
/// for each topic as it is added rather than only for the first one written.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/pages/settings/privacy_content.dart';
import 'package:haven/src/pages/settings/privacy_topic_page.dart';
import 'package:haven/src/widgets/common/more_detail_section.dart';

import '../../helpers/localized_app_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final topic in PrivacyTopic.values) {
    group(topic.name, () {
      testWidgets('renders its title and every body paragraph', (tester) async {
        await pumpLocalized(tester, PrivacyTopicPage(topic: topic));
        final l10n = l10nOf(tester, PrivacyTopicPage);

        expect(find.text(privacyTopicTitle(l10n, topic)), findsOneWidget);

        for (final block in privacyBlocksFor(l10n, topic)) {
          if (block is PrivacyPara) {
            expect(
              find.text(block.text),
              findsOneWidget,
              reason: 'paragraph missing on ${topic.name}',
            );
          }
        }
      });

      testWidgets('ends with a "what this means for you" takeaway', (
        tester,
      ) async {
        await pumpLocalized(tester, PrivacyTopicPage(topic: topic));
        final l10n = l10nOf(tester, PrivacyTopicPage);

        // Every topic owes the reader a practical takeaway; a topic that only
        // explains is a topic that leaves them unsure what to do.
        final takeaway = privacyBlocksFor(l10n, topic)
            .whereType<PrivacyMeansForYou>();
        expect(takeaway, hasLength(1), reason: '${topic.name} needs exactly 1');
        expect(find.text(l10n.privacyMeansForYouLabel), findsOneWidget);
        expect(find.text(takeaway.single.text), findsOneWidget);
      });

      testWidgets('keeps technical depth collapsed until asked', (
        tester,
      ) async {
        await pumpLocalized(tester, PrivacyTopicPage(topic: topic));
        final l10n = l10nOf(tester, PrivacyTopicPage);

        final detail = privacyBlocksFor(l10n, topic)
            .whereType<PrivacyMoreDetail>()
            .single;

        expect(find.byType(HavenMoreDetailSection), findsOneWidget);
        for (final paragraph in detail.paragraphs) {
          expect(
            find.text(paragraph),
            findsNothing,
            reason: 'detail leaked into tier 2 on ${topic.name}',
          );
        }

        // Scroll first: as topics grow the header drops below the fold, and a
        // ListView creates no element for an off-screen child, so an
        // unscrolled tap would fail for a reason unrelated to this assertion.
        final header = find.text(l10n.privacyMoreDetailLabel);
        await tester.scrollUntilVisible(header, 200);
        await tester.tap(header);
        await tester.pumpAndSettle();

        for (final paragraph in detail.paragraphs) {
          expect(find.text(paragraph), findsOneWidget);
        }
      });

      testWidgets('exposes a navigable heading for the takeaway', (
        tester,
      ) async {
        final handle = tester.ensureSemantics();
        await pumpLocalized(tester, PrivacyTopicPage(topic: topic));
        final l10n = l10nOf(tester, PrivacyTopicPage);

        // Headings are the primary way a screen-reader user navigates a page
        // this long, so the takeaway must be reachable by the headings rotor.
        final semantics = tester.getSemantics(
          find.text(l10n.privacyMeansForYouLabel),
        );
        expect(semantics.flagsCollection.isHeader, isTrue);

        handle.dispose();
      });

      testWidgets('never truncates prose', (tester) async {
        await pumpLocalized(tester, PrivacyTopicPage(topic: topic));

        // Reading content must reflow, not ellipsise, or it becomes unreadable
        // at large accessibility text scales (WCAG 1.4.4).
        for (final text in tester.widgetList<Text>(find.byType(Text))) {
          expect(
            text.maxLines,
            isNull,
            reason: 'maxLines set on "${text.data}" in ${topic.name}',
          );
          expect(text.overflow, isNot(TextOverflow.ellipsis));
        }
      });

      testWidgets('does not overflow at 320dp and 200% text scale', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(320, 1400);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        await pumpLocalized(
          tester,
          PrivacyTopicPage(topic: topic),
          textScaler: const TextScaler.linear(2),
        );

        expect(tester.takeException(), isNull);
      });
    });
  }
}
