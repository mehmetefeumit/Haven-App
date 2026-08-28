/// Widget tests for [SelectedMembersSummary].
///
/// This is the create-circle confirmation — the last screen before the user
/// commits to sharing live location with the staged members — so each chip
/// must render the full [NpubValidator.shortenForDisplay] form, trailing
/// characters included, and must not clip it at an accessibility text scale.
///
/// The fixtures are **hex pubkeys**, because that is what the only production
/// call site passes (`name_circle_page.dart` maps `KeyPackageData.pubkey`,
/// which is hex). Asserting against npubs would test input this widget is
/// never given.
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/utils/npub_validator.dart';
import 'package:haven/src/widgets/circles/selected_members_list.dart';

/// Staged members, as `name_circle_page.dart` supplies them: 64-character
/// hex pubkeys. They differ only in their trailing half, so a chip that
/// dropped its tail would render two members identically.
const _hexA =
    'abc123def456abc123def456abc123def456abc123def456abc123def4560001';
const _hexB =
    'abc123def456abc123def456abc123def456abc123def456abc123def4560002';
const _hexC =
    'abc123def456abc123def456abc123def456abc123def456abc123def4560003';
const _hexD =
    'abc123def456abc123def456abc123def456abc123def456abc123def4560004';

Widget _wrap(Widget child, {Locale locale = const Locale('en')}) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  locale: locale,
  home: Scaffold(body: child),
);

/// Every string rendered inside the summary, in tree order.
List<String> _rendered(WidgetTester tester) => tester
    .widgetList<Text>(
      find.descendant(
        of: find.byType(SelectedMembersSummary),
        matching: find.byType(Text),
      ),
    )
    .map((text) => text.data ?? '')
    .toList();

/// Constrains the view to a narrow phone for the layout assertions.
void _useNarrowPhone(WidgetTester tester) {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(320, 900);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  group('SelectedMembersSummary', () {
    testWidgets('renders each staged member in the canonical short form', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(const SelectedMembersSummary(members: [_hexA, _hexB])),
      );

      expect(_rendered(tester), [
        NpubValidator.shortenForDisplay(_hexA),
        NpubValidator.shortenForDisplay(_hexB),
      ]);
    });

    testWidgets('keeps the trailing characters that distinguish members', (
      tester,
    ) async {
      // The regression this locks: the chip shipped a 6/3 form, whose three
      // trailing characters are identical for every fixture here — two
      // different staged members would have read as the same person.
      await tester.pumpWidget(
        _wrap(const SelectedMembersSummary(members: [_hexA, _hexB])),
      );

      final labels = _rendered(tester);
      expect(labels.first, isNot(labels.last));
      for (var i = 0; i < labels.length; i++) {
        final hex = [_hexA, _hexB][i];
        expect(labels[i], startsWith(hex.substring(0, 12)));
        expect(labels[i], endsWith(hex.substring(hex.length - 6)));
      }
    });

    testWidgets('summarizes the members past maxVisible instead of listing', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          const SelectedMembersSummary(
            members: [_hexA, _hexB, _hexC, _hexD],
          ),
        ),
      );
      final l10n = AppLocalizations.of(
        tester.element(find.byType(SelectedMembersSummary)),
      );

      expect(_rendered(tester), [
        NpubValidator.shortenForDisplay(_hexA),
        NpubValidator.shortenForDisplay(_hexB),
        NpubValidator.shortenForDisplay(_hexC),
        l10n.selectedMembersMore(1),
      ]);
    });

    testWidgets('renders nothing when no member is staged', (tester) async {
      await tester.pumpWidget(_wrap(const SelectedMembersSummary(members: [])));

      expect(_rendered(tester), isEmpty);
    });

    testWidgets('no chip clips its identifier at 2x on a 320dp phone', (
      tester,
    ) async {
      // A chip that overflowed would silently drop the trailing characters
      // the previous assertion depends on, so this asserts the paragraph
      // itself — `takeException()` cannot see it, because a `Text` with no
      // `maxLines` wraps instead of overflowing.
      _useNarrowPhone(tester);

      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: _wrap(
            const SelectedMembersSummary(members: [_hexA, _hexB, _hexC]),
          ),
        ),
      );

      final paragraphs = tester.renderObjectList<RenderParagraph>(
        find.descendant(
          of: find.byType(SelectedMembersSummary),
          matching: find.byType(Text),
        ),
      );
      expect(paragraphs, hasLength(3));
      for (final paragraph in paragraphs) {
        expect(paragraph.didExceedMaxLines, isFalse);
      }
      // ...and the chips stay inside the phone rather than running off it.
      expect(_rendered(tester), hasLength(3));
      expect(
        tester.getRect(find.byType(SelectedMembersSummary)).right,
        lessThanOrEqualTo(320),
      );
    });

    testWidgets('the identifier survives a 2x RTL layout unreordered', (
      tester,
    ) async {
      // The chip carries no `textDirection`, so in an RTL locale the ambient
      // direction applies. A hex/bech32 fragment is all weak+LTR characters,
      // which must still read left to right in the order they were given.
      _useNarrowPhone(tester);

      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: _wrap(
            const SelectedMembersSummary(members: [_hexA]),
            locale: const Locale('ar'),
          ),
        ),
      );

      expect(
        Directionality.of(tester.element(find.byType(SelectedMembersSummary))),
        TextDirection.rtl,
      );
      expect(_rendered(tester).single, NpubValidator.shortenForDisplay(_hexA));
      final paragraph = tester.renderObject<RenderParagraph>(
        find.descendant(
          of: find.byType(SelectedMembersSummary),
          matching: find.byType(Text),
        ),
      );
      expect(paragraph.didExceedMaxLines, isFalse);
    });
  });
}
