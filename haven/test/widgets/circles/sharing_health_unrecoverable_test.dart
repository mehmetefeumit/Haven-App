/// A circle MDK halted on this device, as Circle details shows it.
///
/// Retargeted from the deleted blocked-circle banner's tests: the session
/// latch and its banner are gone, and the halt is now MDK's persisted state,
/// read as the core's `unrecoverable` cause and said by the sharing card at
/// the top of Circle details. The promises carried over:
/// - the card says the fault and its remedy as ONE spoken node, once, the
///   moment it appears, and the remedy keeps its own actionable node;
/// - the one remedy is Re-create, which opens the create flow pre-filled with
///   the circle's name, and no Repair is offered;
/// - "Add member" is withheld for the halted circle even for an admin (Rule 8),
///   while Leave stays;
/// - nothing it renders carries a group id or internal state (Rule 8);
/// - every element clears its WCAG 2.1 contrast threshold in BOTH themes, from
///   the error-container roles.
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/pages/circles/create_circle_page.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/location_sharing_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:haven/src/widgets/circles/circles_bottom_sheet.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../helpers/sheet_health_overrides.dart';
import '../../mocks/mock_circle_service.dart';

const _selfPubkey =
    'abc123def456abc123def456abc123def456abc123def456abc123def456abcd';

final _testIdentity = Identity(
  pubkeyHex: _selfPubkey,
  npub: 'npub1test',
  createdAt: DateTime(2024),
);

Circle _circle({
  CircleEngineState engineState = CircleEngineState.unrecoverable,
  List<int> mlsGroupId = const [7, 7, 7],
  List<int>? nostrGroupId,
}) => TestCircleFactory.createCircle(
  mlsGroupId: mlsGroupId,
  nostrGroupId: nostrGroupId,
  displayName: 'Family',
  engineState: engineState,
  members: [
    TestCircleFactory.createMember(
      pubkey: _selfPubkey,
      displayName: 'Alice',
      isAdmin: true,
    ),
  ],
);

/// Pumps the circles sheet with [circle] selected and opens its details.
Future<void> _openDetails(
  WidgetTester tester,
  Circle circle, {
  ThemeData? theme,
}) async {
  tester.view.physicalSize = const Size(800, 5000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final service = MockCircleService(circles: [circle])
    ..recoveryCause = circle.isUnrecoverable
        ? CircleRecoveryCause.unrecoverable
        : null;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ...sheetHealthOverrides(),
        circleServiceProvider.overrideWithValue(service),
        selectedCircleProvider.overrideWith((ref) => circle),
        identityProvider.overrideWith((_) async => _testIdentity),
        memberLocationsProvider.overrideWith((_) async => const []),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: theme,
        home: Scaffold(
          body: Stack(
            children: [CirclesBottomSheet(onExpansionChanged: (_) {})],
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(WidgetKeys.circleDetailsButton));
  await tester.pumpAndSettle();
}

AppLocalizations _l10n(WidgetTester tester) =>
    AppLocalizations.of(tester.element(find.byType(CirclesBottomSheet)));

/// Every non-empty semantics label under [finder], in tree order.
List<String> _semanticsLabels(WidgetTester tester, Finder finder) {
  final labels = <String>[];
  void walk(SemanticsNode node) {
    if (node.label.isNotEmpty) labels.add(node.label);
    node.visitChildren((child) {
      walk(child);
      return true;
    });
  }

  walk(tester.semantics.find(finder));
  return labels;
}

/// WCAG 2.1 contrast ratio between two opaque colours.
double _contrastRatio(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

/// The colour [data] is painted in under [scope], as resolved.
Color _textColor(WidgetTester tester, Finder scope, String data) {
  final paragraph = tester.renderObject<RenderParagraph>(
    find.descendant(of: scope, matching: find.text(data)),
  );
  return (paragraph.text as TextSpan).style!.color!;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('a halted circle in Circle details', () {
    testWidgets('shows the unrecoverable card', (
      tester,
    ) async {
      await _openDetails(tester, _circle());
      final l10n = _l10n(tester);
      expect(find.text(l10n.sharingHealthTitleUnrecoverable), findsOneWidget);
      expect(find.text(l10n.sharingHealthBodyUnrecoverable), findsOneWidget);
    });

    testWidgets('a live circle shows no unrecoverable card', (tester) async {
      await _openDetails(
        tester,
        _circle(engineState: CircleEngineState.live, mlsGroupId: [8, 8, 8]),
      );
      final l10n = _l10n(tester);
      expect(find.text(l10n.sharingHealthTitleUnrecoverable), findsNothing);
      expect(find.byKey(WidgetKeys.sharingHealthRecreateCta), findsNothing);
    });

    testWidgets('"Add member" is withheld even for an admin; Leave stays', (
      tester,
    ) async {
      await _openDetails(tester, _circle());
      expect(find.byKey(WidgetKeys.addMemberCta), findsNothing);
      expect(find.byKey(WidgetKeys.leaveCircleCta), findsOneWidget);
    });

    testWidgets('"Add member" IS offered for a live circle with an admin', (
      tester,
    ) async {
      await _openDetails(
        tester,
        _circle(engineState: CircleEngineState.live, mlsGroupId: [8, 8, 8]),
      );
      expect(find.byKey(WidgetKeys.addMemberCta), findsOneWidget);
    });

    testWidgets('its one remedy is Re-create, pre-filled with the name, and '
        'no Repair is offered', (tester) async {
      await _openDetails(tester, _circle());
      expect(find.byKey(WidgetKeys.sharingHealthRepairButton), findsNothing);
      final recreate = find.byKey(WidgetKeys.sharingHealthRecreateCta);
      expect(recreate, findsOneWidget);
      expect(
        find.text(_l10n(tester).legacyCircleRecreateCta),
        findsOneWidget,
        reason: 'the only re-create action on screen',
      );

      await tester.tap(recreate);
      await tester.pumpAndSettle();
      expect(
        tester.widget<CreateCirclePage>(find.byType(CreateCirclePage))
            .initialName,
        'Family',
      );
    });

    testWidgets('speaks the fault and its remedy once, as one live node', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await _openDetails(tester, _circle());
      final l10n = _l10n(tester);

      final node = tester.getSemantics(
        find.bySemanticsLabel(RegExp(l10n.sharingHealthTitleUnrecoverable)),
      );
      expect(node.flagsCollection.isLiveRegion, isTrue);
      expect(
        node.label,
        '${l10n.sharingHealthTitleUnrecoverable}\n'
        '${l10n.sharingHealthBodyUnrecoverable}',
        reason: 'the fault and what helps belong to one utterance',
      );
      final labels = _semanticsLabels(
        tester,
        find.byKey(WidgetKeys.sharingHealthBanner),
      );
      expect(
        labels
            .where((l) => l.contains(l10n.sharingHealthTitleUnrecoverable))
            .length,
        1,
        reason: 'an un-excluded visual Text would have it read out twice',
      );
      expect(
        tester
            .getSemantics(find.byKey(WidgetKeys.sharingHealthRecreateCta))
            .label,
        contains(l10n.legacyCircleRecreateCta),
        reason: 'the remedy keeps its own actionable node',
      );
      handle.dispose();
    });

    testWidgets('renders no group id or internal state (Rule 8)', (
      tester,
    ) async {
      const mlsGroupId = [0xde, 0xad, 0xbe, 0xef];
      const nostrGroupId = [0xca, 0xfe, 0xba, 0xbe];
      await _openDetails(
        tester,
        _circle(mlsGroupId: mlsGroupId, nostrGroupId: nostrGroupId),
      );
      final rendered = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data ?? '')
          .join('\n');
      String hex(List<int> b) =>
          b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
      for (final forbidden in <String>[
        hex(mlsGroupId),
        hex(nostrGroupId),
        mlsGroupId.join(', '),
        nostrGroupId.join(', '),
        'Exception',
        'Error',
        'Unrecoverable',
        'group_id',
        'mlsGroupId',
      ]) {
        expect(rendered.contains(forbidden), isFalse, reason: forbidden);
      }
      expect(rendered, contains(_l10n(tester).sharingHealthTitleUnrecoverable));
    });
  });

  group('contrast (WCAG 2.1 SC 1.4.11 / 1.4.3)', () {
    for (final (name, theme) in <(String, ThemeData)>[
      ('light', HavenTheme.light()),
      ('dark', HavenTheme.dark()),
    ]) {
      testWidgets('$name: every element clears its threshold, from the '
          'error-container roles', (tester) async {
        await _openDetails(tester, _circle(), theme: theme);
        final l10n = _l10n(tester);
        final card = find.byKey(WidgetKeys.sharingHealthBanner);
        final scheme = Theme.of(tester.element(card)).colorScheme;
        final fill = tester.widget<Card>(card).color!;
        expect(fill, scheme.errorContainer);

        final icon = tester
            .widget<Icon>(
              find.descendant(
                of: card,
                matching: find.byIcon(LucideIcons.radioTower),
              ),
            )
            .color!;
        final title = _textColor(
          tester,
          card,
          l10n.sharingHealthTitleUnrecoverable,
        );
        final body = _textColor(
          tester,
          card,
          l10n.sharingHealthBodyUnrecoverable,
        );
        final label = _textColor(tester, card, l10n.legacyCircleRecreateCta);
        for (final (what, color) in <(String, Color)>[
          ('icon', icon),
          ('title', title),
          ('body', body),
          ('remedy label', label),
        ]) {
          expect(color, scheme.onErrorContainer, reason: '$what role');
        }

        void expectClears(Color fg, double min, String what) {
          final ratio = _contrastRatio(fg, fill);
          expect(
            ratio,
            greaterThanOrEqualTo(min),
            reason: '$what in $name: ${ratio.toStringAsFixed(2)}:1',
          );
        }

        expectClears(icon, 3, 'the icon');
        expectClears(title, 4.5, 'the title');
        expectClears(body, 4.5, 'the body');
        expectClears(label, 4.5, 'the remedy label');
      });
    }
  });
}
