/// Widget tests for [PrivacyTopicPage].
///
/// Every assertion is parameterised over all of [PrivacyTopic], so the
/// structural guarantees the renderer exists to enforce — navigable headings,
/// a takeaway block, opt-in technical depth, and reflowable prose — are proven
/// for each topic as it is added rather than only for the first one written.
///
/// Assertions scroll before they look. These pages are deliberately longer than
/// one viewport, and a [ListView] builds no element for an off-screen child, so
/// a non-scrolling test would report "missing" for content that is merely
/// further down.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/pages/settings/privacy_content.dart';
import 'package:haven/src/pages/settings/privacy_topic_page.dart';
import 'package:haven/src/widgets/common/more_detail_section.dart';

import '../../helpers/localized_app_harness.dart';

/// Scrolls [finder] into view, tolerating a target that is already visible.
Future<void> _reveal(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(finder, 200);
  }
  // scrollUntilVisible stops as soon as the target is attached, which can
  // leave it flush with the viewport edge and untappable. ensureVisible pulls
  // it fully into view.
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
}

/// Drags the page back to the top so a subsequent search starts from a known
/// position rather than wherever the last [_reveal] left it.
Future<void> _toTop(WidgetTester tester) async {
  await tester.fling(find.byType(ListView), const Offset(0, 4000), 3000);
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final topic in PrivacyTopic.values) {
    group(topic.name, () {
      testWidgets('renders its title and every body paragraph', (tester) async {
        await pumpLocalized(tester, PrivacyTopicPage(topic: topic));
        final l10n = l10nOf(tester, PrivacyTopicPage);

        expect(find.text(privacyTopicTitle(l10n, topic)), findsOneWidget);

        for (final block in privacyBlocksFor(l10n, topic)) {
          if (block is! PrivacyPara) continue;
          final finder = find.text(block.text);
          await _reveal(tester, finder);
          expect(
            finder,
            findsOneWidget,
            reason: 'paragraph unreachable on ${topic.name}',
          );
        }
      });

      testWidgets('renders every section heading as a navigable heading', (
        tester,
      ) async {
        final handle = tester.ensureSemantics();
        await pumpLocalized(tester, PrivacyTopicPage(topic: topic));
        final l10n = l10nOf(tester, PrivacyTopicPage);

        for (final block in privacyBlocksFor(l10n, topic)) {
          if (block is! PrivacyHeading) continue;
          final finder = find.text(block.text);
          await _reveal(tester, finder);
          expect(finder, findsOneWidget);
          expect(
            tester.getSemantics(finder).flagsCollection.isHeader,
            isTrue,
            reason: 'heading "${block.text}" is not a semantic header',
          );
        }
        handle.dispose();
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

        final label = find.text(l10n.privacyMeansForYouLabel);
        await _reveal(tester, label);
        expect(label, findsOneWidget);
        expect(find.text(takeaway.single.text), findsOneWidget);
      });

      testWidgets('exposes a navigable heading for the takeaway', (
        tester,
      ) async {
        final handle = tester.ensureSemantics();
        await pumpLocalized(tester, PrivacyTopicPage(topic: topic));
        final l10n = l10nOf(tester, PrivacyTopicPage);

        // Headings are the primary way a screen-reader user navigates a page
        // this long, so the takeaway must be reachable by the headings rotor.
        final label = find.text(l10n.privacyMeansForYouLabel);
        await _reveal(tester, label);
        expect(tester.getSemantics(label).flagsCollection.isHeader, isTrue);

        handle.dispose();
      });

      testWidgets('keeps technical depth collapsed until asked', (
        tester,
      ) async {
        await pumpLocalized(tester, PrivacyTopicPage(topic: topic));
        final l10n = l10nOf(tester, PrivacyTopicPage);

        final detail = privacyBlocksFor(l10n, topic)
            .whereType<PrivacyMoreDetail>()
            .single;

        // Scroll the section into view FIRST, so "absent" means collapsed
        // rather than merely off-screen — otherwise this assertion would pass
        // for the wrong reason on any page taller than the viewport. The
        // section widget itself is likewise unbuilt until it is scrolled to.
        final header = find.text(l10n.privacyMoreDetailLabel);
        await _reveal(tester, header);
        expect(find.byType(HavenMoreDetailSection), findsOneWidget);

        for (final paragraph in detail.paragraphs) {
          expect(
            find.text(paragraph),
            findsNothing,
            reason: 'detail leaked into tier 2 on ${topic.name}',
          );
        }

        await tester.tap(header);
        await tester.pumpAndSettle();

        for (final paragraph in detail.paragraphs) {
          final finder = find.text(paragraph);
          await _reveal(tester, finder);
          expect(finder, findsOneWidget);
        }
      });

      testWidgets('never truncates prose', (tester) async {
        await pumpLocalized(tester, PrivacyTopicPage(topic: topic));
        final l10n = l10nOf(tester, PrivacyTopicPage);

        // Expand the detail region and sweep the whole page, so the check
        // covers tier-3 text too rather than only what fits on first paint.
        final header = find.text(l10n.privacyMoreDetailLabel);
        await _reveal(tester, header);
        await tester.tap(header);
        await tester.pumpAndSettle();
        await _toTop(tester);

        var checked = 0;
        for (var pass = 0; pass < 12; pass++) {
          for (final text in tester.widgetList<Text>(find.byType(Text))) {
            // Reading content must reflow, not ellipsise, or it becomes
            // unreadable at large accessibility text scales (WCAG 1.4.4).
            expect(
              text.maxLines,
              isNull,
              reason: 'maxLines set on "${text.data}" in ${topic.name}',
            );
            expect(text.overflow, isNot(TextOverflow.ellipsis));
            checked++;
          }
          await tester.drag(find.byType(ListView), const Offset(0, -400));
          await tester.pumpAndSettle();
        }
        expect(checked, greaterThan(0));
      });

      testWidgets('renders any outbound link as a real button', (tester) async {
        await pumpLocalized(tester, PrivacyTopicPage(topic: topic));
        final l10n = l10nOf(tester, PrivacyTopicPage);

        final links = privacyBlocksFor(l10n, topic).whereType<PrivacyLink>();
        if (links.isEmpty) return;

        final handle = tester.ensureSemantics();
        for (final link in links) {
          final finder = find.widgetWithText(TextButton, link.label);
          await _reveal(tester, finder);
          expect(finder, findsOneWidget, reason: 'link ${link.label} missing');
          // A button role, not bare text, so it shows up in the controls rotor.
          expect(
            tester.getSemantics(finder).flagsCollection.isButton,
            isTrue,
            reason: 'link ${link.label} has no button role',
          );
          // The label is the visible hostname; the URL must never be localized,
          // so it has to come from constants rather than the ARB.
          expect(link.url, startsWith('https://'));
        }
        handle.dispose();
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

  testWidgets('every topic declares exactly one collapsed detail region', (
    tester,
  ) async {
    // A topic that forgot its tier-3 region would silently drop the technical
    // depth the section promises to make available.
    await pumpLocalized(tester, const PrivacyTopicPage(
      topic: PrivacyTopic.whatHavenIs,
    ));
    final l10n = AppLocalizations.of(
      tester.element(find.byType(PrivacyTopicPage)),
    );
    for (final topic in PrivacyTopic.values) {
      expect(
        privacyBlocksFor(l10n, topic).whereType<PrivacyMoreDetail>(),
        hasLength(1),
        reason: '${topic.name} must declare exactly one detail region',
      );
    }
  });
}
