/// The non-text "needs attention" cue: a circle with a fault or a note it has
/// not been shown is marked where the user can see it with Circle details
/// closed. It carries no message of its own (OD-1); it has an accessible
/// name, and its badge is visible against the sheet in both themes (WCAG 2.1
/// SC 1.4.11).
///
/// The SELECTED circle's cue is its details button itself — the alert glyph
/// in the info glyph's place, never a second control beside it — and a dot on
/// its avatar in the selector, which is all of the circle a resting sheet
/// shows. A circle NOT selected keeps a cue of its own beside the selector,
/// named for that circle, and one tap on it selects the circle and opens its
/// details.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/location_sharing_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/providers/sharing_health_provider.dart';
import 'package:haven/src/rust/api.dart' show ChangeNoteFfi;
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:haven/src/widgets/circles/circle_attention_cue.dart';
import 'package:haven/src/widgets/circles/circles_bottom_sheet.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../helpers/fake_change_notices.dart';
import '../../helpers/sheet_health_overrides.dart';
import '../../mocks/mock_circle_service.dart';

const _selfPubkey =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

class _Health extends SharingHealthNotifier {
  _Health(this._health);

  final SharingHealth _health;

  @override
  SharingHealth build() => _health;

  @override
  Future<void> refresh() async {}

  /// Lands [health] as a derivation would.
  void land(SharingHealth health) => state = health;
}

Circle _circle(int id, String name) => TestCircleFactory.createCircle(
  mlsGroupId: [id],
  nostrGroupId: [id],
  displayName: name,
  members: [TestCircleFactory.createMember(pubkey: _selfPubkey)],
);

final Circle _home = _circle(1, 'Home');
final Circle _work = _circle(2, 'Work');

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

/// Pumps the resting (0.12) circles sheet on a phone with [_home] selected.
Future<void> _pump(
  WidgetTester tester, {
  SharingHealth health = SharingHealth.healthy,
  FakeNoticeManager? notices,
  double scale = 1,
  ThemeData? theme,
  Size size = const Size(390, 844),
}) async {
  tester.view
    ..devicePixelRatio = 1
    ..physicalSize = size;
  addTearDown(tester.view.reset);
  final selected = StateProvider<Circle?>((ref) => _home);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ...sheetHealthOverrides(notices: notices),
        sharingHealthProvider.overrideWith(() => _Health(health)),
        circleServiceProvider.overrideWithValue(
          MockCircleService(circles: [_home, _work]),
        ),
        circlesProvider.overrideWith((ref) async => [_home, _work]),
        selectedCircleProvider.overrideWith((ref) {
          final id = ref.watch(selectedCircleIdProvider);
          if (id == null) return ref.watch(selected);
          return [_home, _work].firstWhere((c) => listEquals(c.mlsGroupId, id));
        }),
        identityProvider.overrideWith(
          (_) async => Identity(
            pubkeyHex: _selfPubkey,
            npub: 'npub1self',
            createdAt: DateTime(2024),
          ),
        ),
        memberLocationsProvider.overrideWith((_) async => const []),
      ],
      child: MaterialApp(
        theme: theme,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(
          body: Stack(
            children: [CirclesBottomSheet(onExpansionChanged: (_) {})],
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

AppLocalizations _l10n(WidgetTester tester) =>
    AppLocalizations.of(tester.element(find.byType(CirclesBottomSheet)));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Whether the dot on the selected circle's avatar is drawn.
  bool dotShown(WidgetTester tester) => tester
      .widget<Badge>(find.byKey(WidgetKeys.circleSelectedAttentionDot))
      .isLabelVisible;

  /// The attention glyph inside [button], if it shows one.
  Finder attentionGlyphIn(Finder button) => find.descendant(
    of: button,
    matching: find.byType(CircleAttentionGlyph),
  );

  /// Pulls the sheet up until the header row is on screen.
  Future<void> raiseSheet(WidgetTester tester) async {
    await tester.drag(find.text('Home'), const Offset(0, -400));
    await tester.pumpAndSettle();
  }

  for (final scale in const [1.0, 2.0]) {
    testWidgets('at ${scale}x, a fault dots the selected circle at the resting '
        'detent, and its one details button is the labelled cue that opens '
        'Circle details', (tester) async {
      final handle = tester.ensureSemantics();
      await _pump(
        tester,
        health: SharingHealth.publishFailing(DateTime.utc(2026, 8, 28, 12)),
        scale: scale,
      );
      expect(dotShown(tester), isTrue);
      expect(
        tester
            .getRect(find.byKey(WidgetKeys.circleSelectedAttentionDot))
            .bottom,
        lessThanOrEqualTo(844),
        reason: 'on screen with the sheet at rest',
      );
      expect(
        find.byKey(WidgetKeys.circleAttentionCue),
        findsNothing,
        reason: 'no second control beside the selector for the selected circle',
      );

      await raiseSheet(tester);
      final details = find.byKey(WidgetKeys.circleDetailsButton);
      expect(details, findsOneWidget);
      expect(attentionGlyphIn(details), findsOneWidget);
      expect(
        find.byIcon(LucideIcons.info),
        findsNothing,
        reason: "the alert glyph stands in the info glyph's place",
      );
      expect(tester.getRect(details).bottom, lessThanOrEqualTo(844));
      expect(
        tester.getSemantics(details).tooltip,
        _l10n(tester).circleDetailsAttentionTooltip,
      );

      await tester.tap(details);
      await tester.pumpAndSettle();
      expect(find.byKey(WidgetKeys.leaveCircleCta), findsOneWidget);
      handle.dispose();
    });
  }

  testWidgets('a healthy circle with no note shows no cue: no dot, and the '
      'details button keeps its info glyph and its plain name', (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(tester);
    expect(find.byKey(WidgetKeys.circleAttentionCue), findsNothing);
    expect(dotShown(tester), isFalse);

    await raiseSheet(tester);
    final details = find.byKey(WidgetKeys.circleDetailsButton);
    expect(attentionGlyphIn(details), findsNothing);
    expect(
      find.descendant(of: details, matching: find.byIcon(LucideIcons.info)),
      findsOneWidget,
    );
    expect(find.byIcon(LucideIcons.triangleAlert), findsNothing);
    expect(
      tester.getSemantics(details).tooltip,
      _l10n(tester).circleDetailsButtonTooltip,
    );
    handle.dispose();
  });

  testWidgets('a note the selected circle has not been shown dots it and '
      'turns its details button into the cue', (tester) async {
    final notices = FakeNoticeManager()
      ..notesFor = (id) => listEquals(id, _home.mlsGroupId)
          ? const [ChangeNoteFfi.changeUndone]
          : const [];
    await _pump(tester, notices: notices);
    expect(dotShown(tester), isTrue);
    expect(find.byKey(WidgetKeys.circleAttentionCue), findsNothing);
    expect(
      attentionGlyphIn(find.byKey(WidgetKeys.circleDetailsButton)),
      findsOneWidget,
    );
  });

  testWidgets('the details button is one button through a fault: its glyph '
      'and name change under whatever holds its focus', (tester) async {
    // Two buttons swapped under one key would drop a screen reader's or a
    // keyboard's focus at the moment a fault appears or clears.
    final handle = tester.ensureSemantics();
    await _pump(tester);
    await raiseSheet(tester);
    final details = find.byKey(WidgetKeys.circleDetailsButton);
    final button = tester.element(details);
    final container = ProviderScope.containerOf(button);
    final health = container.read(sharingHealthProvider.notifier) as _Health
      ..land(SharingHealth.publishFailing(DateTime.utc(2026, 8, 28, 12)));
    await tester.pumpAndSettle();
    expect(tester.element(details), same(button));
    expect(attentionGlyphIn(details), findsOneWidget);
    expect(
      tester.getSemantics(details).tooltip,
      _l10n(tester).circleDetailsAttentionTooltip,
    );

    health.land(SharingHealth.healthy);
    await tester.pumpAndSettle();
    expect(tester.element(details), same(button));
    expect(attentionGlyphIn(details), findsNothing);
    handle.dispose();
  });

  testWidgets('level notes alone show no cue', (tester) async {
    await _pump(
      tester,
      notices: FakeNoticeManager(notes: const [ChangeNoteFfi.unreadLocation]),
    );
    expect(find.byKey(WidgetKeys.circleAttentionCue), findsNothing);
    expect(dotShown(tester), isFalse);
    expect(find.byIcon(LucideIcons.triangleAlert), findsNothing);
  });

  testWidgets('a note in a circle NOT selected marks its row in the list, '
      'named for a screen reader, and its cue opens that circle', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final notices = FakeNoticeManager()
      ..notesFor = (id) => listEquals(id, _work.mlsGroupId)
          ? const [ChangeNoteFfi.removalUndone]
          : const [];
    // Tall enough that the opened list is on screen at the resting detent.
    await _pump(tester, notices: notices, size: const Size(800, 5000));

    await tester.tap(find.text('Home'));
    await tester.pumpAndSettle();
    final rowCue = find.byKey(WidgetKeys.circleRowAttentionCue(_hex([2])));
    expect(rowCue, findsOneWidget);
    expect(
      find.byKey(WidgetKeys.circleRowAttentionCue(_hex([1]))),
      findsNothing,
    );
    expect(
      find.bySemanticsLabel(
        RegExp(
          RegExp.escape(_l10n(tester).circleRowAttentionSemantics('Work')),
        ),
      ),
      findsOneWidget,
    );

    await tester.tap(rowCue);
    await tester.pumpAndSettle();
    expect(find.byKey(WidgetKeys.leaveCircleCta), findsOneWidget);
    expect(
      find.byKey(WidgetKeys.circleSelectorActive(_hex([2]))),
      findsOneWidget,
      reason: 'one tap selected the circle whose details opened',
    );
    handle.dispose();
  });

  testWidgets('a note in a circle NOT selected shows the cue at rest, and one '
      'tap opens that circle', (tester) async {
    // The sighted half of "a told note is never unseen": with the list
    // closed, the resting trigger row is all that is on screen.
    final notices = FakeNoticeManager()
      ..notesFor = (id) => listEquals(id, _work.mlsGroupId)
          ? const [ChangeNoteFfi.changeUndone]
          : const [];
    await _pump(tester, notices: notices);
    final cue = find.byKey(WidgetKeys.circleAttentionCue);
    expect(cue, findsOneWidget);
    expect(tester.getRect(cue).bottom, lessThanOrEqualTo(844));
    // Named for the circle it is about, not the one it sits beside.
    expect(
      tester.getSemantics(cue).tooltip,
      _l10n(tester).circleRowAttentionSemantics('Work'),
    );
    // The mark is that circle's alone: the selected one carries none.
    expect(dotShown(tester), isFalse);
    expect(
      attentionGlyphIn(find.byKey(WidgetKeys.circleDetailsButton)),
      findsNothing,
    );

    await tester.tap(cue);
    await tester.pumpAndSettle();
    expect(find.byKey(WidgetKeys.leaveCircleCta), findsOneWidget);
    expect(
      find.byKey(WidgetKeys.circleSelectorActive(_hex([2]))),
      findsOneWidget,
      reason: 'the circle that needed attention was selected and opened',
    );
  });

  for (final (name, theme) in <(String, ThemeData)>[
    ('light', HavenTheme.light()),
    ('dark', HavenTheme.dark()),
  ]) {
    testWidgets('$name: both badges clear 3:1 against the sheet surface', (
      tester,
    ) async {
      await _pump(
        tester,
        health: SharingHealth.publishFailing(DateTime.utc(2026, 8, 28, 12)),
        theme: theme,
      );
      final scheme = Theme.of(
        tester.element(find.byType(CirclesBottomSheet)),
      ).colorScheme;
      final badges = [
        tester.widget<Badge>(find.byKey(WidgetKeys.circleSelectedAttentionDot)),
        tester.widget<Badge>(
          find.descendant(
            of: find.byKey(WidgetKeys.circleDetailsButton),
            matching: find.byType(Badge),
          ),
        ),
      ];
      for (final badge in badges) {
        final colour = badge.backgroundColor!;
        expect(colour, scheme.error);
        for (final surface in [scheme.surface, scheme.surfaceContainerLow]) {
          expect(
            _contrast(colour, surface),
            greaterThanOrEqualTo(3),
            reason: '$name badge on $surface',
          );
        }
      }
    });
  }
}
