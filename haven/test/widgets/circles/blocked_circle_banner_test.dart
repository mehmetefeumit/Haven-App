/// Tests for the Dark Matter cutover (DM-4c) blocked-circle banner in
/// [CirclesBottomSheet] (Security Rule 8: `CircleService.isCircleBlocked`).
///
/// Verifies that:
/// - A circle marked blocked shows the blocked banner above its (still
///   visible, read-only) member list.
/// - A healthy (not-blocked) circle never shows the blocked banner.
/// - An admin's "Add member" CTA in the circle-details sheet is hidden for a
///   blocked circle (Rule 8: no mutate), even though the cached roster still
///   shows them as admin.
/// - The banner offers the ONE repair a wedged circle has — re-create it —
///   and that repair opens the create flow pre-filled with the circle's name
///   (OD4-c (i): the wedge must not be detected silently).
/// - Nothing the banner renders carries a group id, an exception or any other
///   internal state (Security Rule 8).
/// - Every part of it — the alert glyph, the title, the body and the repair
///   button — clears its WCAG 2.1 contrast threshold in BOTH themes, measured
///   against the fill as composited rather than as nominally declared. The
///   banner used to tint its container with 10 % of the same amber it drew the
///   glyph in, which left the glyph at 2.86:1 (SC 1.4.11 asks 3:1) in light.
/// - The banner ANNOUNCES itself when it appears, and says the fault and the
///   remedy in one utterance without repeating either. Nothing else surfaces
///   this fault — `MapStatusBanners` takes no blocked-circle input — and the
///   banner is inserted by a peer's traffic rather than by anything the user
///   did, so a rendered-only banner tells sighted users a circle is dead and
///   tells a screen-reader user nothing at all (WCAG 2.1 SC 4.1.3).
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

import '../../mocks/mock_circle_service.dart';

const _selfPubkey =
    'abc123def456abc123def456abc123def456abc123def456abc123def456abcd';

final _testIdentity = Identity(
  pubkeyHex: _selfPubkey,
  npub: 'npub1test',
  createdAt: DateTime(2024),
);

Widget _buildTestWidget({
  required MockCircleService mockService,
  required Circle selectedCircle,
  ThemeData? theme,
}) {
  return ProviderScope(
    overrides: [
      circleServiceProvider.overrideWithValue(mockService),
      selectedCircleProvider.overrideWith((ref) => selectedCircle),
      identityProvider.overrideWith((_) async => _testIdentity),
      memberLocationsProvider.overrideWith((_) async => const []),
    ],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: theme,
      home: Scaffold(
        body: Stack(children: [CirclesBottomSheet(onExpansionChanged: (_) {})]),
      ),
    ),
  );
}

/// Every non-empty semantics label under [finder], in tree order.
///
/// A count rather than a presence check is the point: a live-region label that
/// duplicates the visual copy it already speaks makes a screen reader read the
/// whole banner twice, which is its own defect.
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

void _setTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 5000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// WCAG 2.1 contrast ratio between two opaque colours.
double _contrastRatio(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

/// The fill a [Container] paints, given either as `color` or inside a
/// [BoxDecoration].
Color? _fillOf(Container container) {
  final decoration = container.decoration;
  if (decoration is BoxDecoration) return decoration.color;
  return container.color;
}

/// Every colour the blocked banner paints, plus the surface behind it.
typedef _BannerPaint = ({
  Color backdrop,
  Color fill,
  Color icon,
  Color title,
  Color body,
  Color ctaFill,
  Color ctaLabel,
});

/// Reads the banner's colours out of the rendered tree.
///
/// Read rather than recomputed from the tokens the banner is *expected* to
/// use: a ratio derived from the expectation proves arithmetic only, and would
/// stay green the moment the banner stopped using them.
_BannerPaint _readBannerPaint(WidgetTester tester) {
  final sheet = tester.element(find.byType(CirclesBottomSheet));
  final l10n = AppLocalizations.of(sheet);
  final cta = find.byKey(WidgetKeys.blockedCircleRecreateCta);
  final boxes = find.ancestor(of: cta, matching: find.byType(Container));
  // Nearest-first, so the filled ancestors are the banner's own container and
  // then the sheet surface it is painted onto.
  final filled = <int>[
    for (final (i, box) in tester.widgetList<Container>(boxes).indexed)
      if (_fillOf(box) != null) i,
  ];
  expect(
    filled.length,
    greaterThanOrEqualTo(2),
    reason: 'expected the banner container and the sheet surface behind it',
  );
  final banner = boxes.at(filled.first);

  Color textColor(Finder scope, String data) {
    final paragraph = tester.renderObject<RenderParagraph>(
      find.descendant(of: scope, matching: find.text(data)),
    );
    // The resolved span, so an inherited colour is measured as painted.
    return (paragraph.text as TextSpan).style!.color!;
  }

  return (
    backdrop: _fillOf(tester.widget<Container>(boxes.at(filled[1])))!,
    fill: _fillOf(tester.widget<Container>(banner))!,
    icon: tester
        .widget<Icon>(
          find.descendant(
            of: banner,
            matching: find.byIcon(LucideIcons.triangleAlert),
          ),
        )
        .color!,
    title: textColor(banner, l10n.circleBlockedBannerTitle),
    body: textColor(banner, l10n.circleBlockedBannerBody),
    ctaFill: tester
        .widget<Material>(
          find.descendant(of: cta, matching: find.byType(Material)),
        )
        .color!,
    ctaLabel: textColor(cta, l10n.legacyCircleRecreateCta),
  );
}

/// Pumps the sheet under [theme] with one blocked circle selected.
Future<void> _pumpBlockedCircle(WidgetTester tester, ThemeData theme) async {
  _setTallViewport(tester);
  final circle = TestCircleFactory.createCircle(
    mlsGroupId: const [7, 7, 7],
    displayName: 'Family',
    members: [
      TestCircleFactory.createMember(pubkey: _selfPubkey, displayName: 'Alice'),
    ],
  );
  final mockService = MockCircleService(circles: [circle])
    ..markCircleBlocked(circle.mlsGroupId);
  await tester.pumpWidget(
    _buildTestWidget(
      mockService: mockService,
      selectedCircle: circle,
      theme: theme,
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Blocked circle banner (DM-4c, Rule 8)', () {
    testWidgets(
      'a blocked circle shows the blocked banner above its member list',
      (tester) async {
        _setTallViewport(tester);
        final circle = TestCircleFactory.createCircle(
          mlsGroupId: const [7, 7, 7],
          displayName: 'Family',
          members: [
            TestCircleFactory.createMember(
              pubkey: _selfPubkey,
              displayName: 'Alice',
              isAdmin: true,
            ),
          ],
        );
        final mockService = MockCircleService(circles: [circle])
          ..markCircleBlocked(circle.mlsGroupId);

        await tester.pumpWidget(
          _buildTestWidget(mockService: mockService, selectedCircle: circle),
        );
        await tester.pumpAndSettle();

        expect(find.text('This circle can’t be updated'), findsOneWidget);
        // The (read-only) member list is still visible underneath.
        expect(find.text('Alice'), findsOneWidget);
      },
    );

    testWidgets('a healthy circle never shows the blocked banner', (
      tester,
    ) async {
      _setTallViewport(tester);
      final circle = TestCircleFactory.createCircle(
        mlsGroupId: const [8, 8, 8],
        displayName: 'Family',
        members: [
          TestCircleFactory.createMember(
            pubkey: _selfPubkey,
            displayName: 'Alice',
            isAdmin: true,
          ),
        ],
      );
      final mockService = MockCircleService(circles: [circle]);

      await tester.pumpWidget(
        _buildTestWidget(mockService: mockService, selectedCircle: circle),
      );
      await tester.pumpAndSettle();

      expect(find.text('This circle can’t be updated'), findsNothing);
    });

    testWidgets(
      '"Add member" is hidden in the circle-details sheet for a blocked '
      'circle, even for an admin',
      (tester) async {
        _setTallViewport(tester);
        final circle = TestCircleFactory.createCircle(
          mlsGroupId: const [7, 7, 7],
          displayName: 'Family',
          members: [
            TestCircleFactory.createMember(
              pubkey: _selfPubkey,
              displayName: 'Alice',
              isAdmin: true,
            ),
          ],
        );
        final mockService = MockCircleService(circles: [circle])
          ..markCircleBlocked(circle.mlsGroupId);

        await tester.pumpWidget(
          _buildTestWidget(mockService: mockService, selectedCircle: circle),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byIcon(LucideIcons.info));
        await tester.pumpAndSettle();

        expect(find.widgetWithText(OutlinedButton, 'Add member'), findsNothing);
        // The Leave Circle action remains available (exiting a broken
        // circle is not a "send/mutate" of its content).
        expect(
          find.widgetWithText(OutlinedButton, 'Leave Circle'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      '"Add member" IS shown in the circle-details sheet for a healthy '
      'circle with an admin',
      (tester) async {
        _setTallViewport(tester);
        final circle = TestCircleFactory.createCircle(
          mlsGroupId: const [8, 8, 8],
          displayName: 'Family',
          members: [
            TestCircleFactory.createMember(
              pubkey: _selfPubkey,
              displayName: 'Alice',
              isAdmin: true,
            ),
          ],
        );
        final mockService = MockCircleService(circles: [circle]);

        await tester.pumpWidget(
          _buildTestWidget(mockService: mockService, selectedCircle: circle),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byIcon(LucideIcons.info));
        await tester.pumpAndSettle();

        expect(
          find.widgetWithText(OutlinedButton, 'Add member'),
          findsOneWidget,
        );
      },
    );

    testWidgets('a blocked circle offers the re-create repair', (tester) async {
      _setTallViewport(tester);
      final circle = TestCircleFactory.createCircle(
        mlsGroupId: const [7, 7, 7],
        displayName: 'Family',
        members: [
          TestCircleFactory.createMember(
            pubkey: _selfPubkey,
            displayName: 'Alice',
          ),
        ],
      );
      final mockService = MockCircleService(circles: [circle])
        ..markCircleBlocked(circle.mlsGroupId);

      await tester.pumpWidget(
        _buildTestWidget(mockService: mockService, selectedCircle: circle),
      );
      await tester.pumpAndSettle();

      expect(
        find.widgetWithText(FilledButton, 'Re-create Circle'),
        findsOneWidget,
        reason: 'a detected wedge the user cannot act on is still silence',
      );
    });

    testWidgets('a healthy circle offers no re-create repair', (tester) async {
      _setTallViewport(tester);
      final circle = TestCircleFactory.createCircle(
        mlsGroupId: const [8, 8, 8],
        displayName: 'Family',
        members: [
          TestCircleFactory.createMember(
            pubkey: _selfPubkey,
            displayName: 'Alice',
          ),
        ],
      );
      final mockService = MockCircleService(circles: [circle]);

      await tester.pumpWidget(
        _buildTestWidget(mockService: mockService, selectedCircle: circle),
      );
      await tester.pumpAndSettle();

      expect(
        find.widgetWithText(FilledButton, 'Re-create Circle'),
        findsNothing,
        reason: 'never tell someone to rebuild a circle that works',
      );
    });

    testWidgets(
      'the re-create repair opens the create flow pre-filled with the '
      "circle's name",
      (tester) async {
        _setTallViewport(tester);
        final circle = TestCircleFactory.createCircle(
          mlsGroupId: const [7, 7, 7],
          displayName: 'Family',
          members: [
            TestCircleFactory.createMember(
              pubkey: _selfPubkey,
              displayName: 'Alice',
            ),
          ],
        );
        final mockService = MockCircleService(circles: [circle])
          ..markCircleBlocked(circle.mlsGroupId);

        await tester.pumpWidget(
          _buildTestWidget(mockService: mockService, selectedCircle: circle),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.widgetWithText(FilledButton, 'Re-create Circle'));
        await tester.pumpAndSettle();

        final page = tester.widget<CreateCirclePage>(
          find.byType(CreateCirclePage),
        );
        expect(page.initialName, 'Family');
      },
    );

    testWidgets('the banner announces itself the moment it appears', (
      tester,
    ) async {
      _setTallViewport(tester);
      final handle = tester.ensureSemantics();
      final circle = TestCircleFactory.createCircle(
        mlsGroupId: const [7, 7, 7],
        displayName: 'Family',
        members: [
          TestCircleFactory.createMember(
            pubkey: _selfPubkey,
            displayName: 'Alice',
          ),
        ],
      );
      final mockService = MockCircleService(circles: [circle])
        ..markCircleBlocked(circle.mlsGroupId);

      await tester.pumpWidget(
        _buildTestWidget(mockService: mockService, selectedCircle: circle),
      );
      await tester.pumpAndSettle();

      final node = tester.getSemantics(
        find.bySemanticsLabel(RegExp('This circle can’t be updated')),
      );
      expect(
        node.flagsCollection.isLiveRegion,
        isTrue,
        reason:
            "the wedge is inserted by a peer's traffic, so no user "
            'action leads here and nothing else states the fault: unannounced, '
            'the banner is silence for a screen-reader user',
      );
      expect(
        node.label,
        contains('leave the circle'),
        reason:
            'the fault and its remedy belong to one utterance — a node '
            'that says only "this circle can’t be updated" is a dead end',
      );
      handle.dispose();
    });

    testWidgets('the announced banner does not speak its copy twice', (
      tester,
    ) async {
      _setTallViewport(tester);
      final handle = tester.ensureSemantics();
      final circle = TestCircleFactory.createCircle(
        mlsGroupId: const [7, 7, 7],
        displayName: 'Family',
        members: [
          TestCircleFactory.createMember(
            pubkey: _selfPubkey,
            displayName: 'Alice',
          ),
        ],
      );
      final mockService = MockCircleService(circles: [circle])
        ..markCircleBlocked(circle.mlsGroupId);

      await tester.pumpWidget(
        _buildTestWidget(mockService: mockService, selectedCircle: circle),
      );
      await tester.pumpAndSettle();

      final labels = _semanticsLabels(tester, find.byType(CirclesBottomSheet));
      expect(
        labels.where((l) => l.contains('This circle can’t be updated')).length,
        1,
        reason:
            'the live label and an un-excluded visual Text would both '
            'carry the title, so the banner would be read out twice',
      );
      // The remedy keeps its own actionable node: excluding it along with the
      // copy would announce the fault and hide the only way out of it.
      expect(
        tester
            .getSemantics(find.byKey(WidgetKeys.blockedCircleRecreateCta))
            .label,
        contains('Re-create Circle'),
      );
      handle.dispose();
    });

    testWidgets(
      'a blocked circle whose roster read was swallowed keeps both repairs '
      'individually addressable',
      (tester) async {
        // `isLegacyOrphaned` is `accepted && members.isEmpty`, and an
        // Unrecoverable group's per-member lookup is swallowed to an empty
        // list (see `Circle.isLegacyOrphaned`) — so a blocked circle reaches
        // this state and BOTH banners render, each with a button labelled
        // "Re-create Circle". The keys are what keep them apart; the shared
        // label is recorded as an open item rather than pinned as correct.
        _setTallViewport(tester);
        final circle = TestCircleFactory.createCircle(
          mlsGroupId: const [7, 7, 7],
          displayName: 'Family',
          members: const [],
        );
        final mockService = MockCircleService(circles: [circle])
          ..markCircleBlocked(circle.mlsGroupId);

        await tester.pumpWidget(
          _buildTestWidget(mockService: mockService, selectedCircle: circle),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(WidgetKeys.blockedCircleRecreateCta),
          findsOneWidget,
          reason: 'the blocked banner still offers its repair',
        );
        expect(
          find.byKey(WidgetKeys.legacyCircleRecreateCta),
          findsOneWidget,
          reason:
              'the legacy banner also carries the REMOVE action, which '
              'the blocked banner does not, so it is not redundant',
        );
      },
    );

    testWidgets(
      'nothing the blocked banner renders carries a group id or internal '
      'state (Rule 8)',
      (tester) async {
        _setTallViewport(tester);
        // Distinctive ids, so any leak of either one is unmistakable. Only the
        // pseudonymous nostr id ever crosses the FFI (Protocol Rule 4); the MLS
        // id is local and must never be rendered either.
        const mlsGroupId = [0xde, 0xad, 0xbe, 0xef];
        const nostrGroupId = [0xca, 0xfe, 0xba, 0xbe];
        final circle = TestCircleFactory.createCircle(
          mlsGroupId: mlsGroupId,
          nostrGroupId: nostrGroupId,
          displayName: 'Family',
          members: [
            TestCircleFactory.createMember(
              pubkey: _selfPubkey,
              displayName: 'Alice',
            ),
          ],
        );
        final mockService = MockCircleService(circles: [circle])
          ..markCircleBlocked(circle.mlsGroupId);

        await tester.pumpWidget(
          _buildTestWidget(mockService: mockService, selectedCircle: circle),
        );
        await tester.pumpAndSettle();

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
          mlsGroupId.join(','),
          nostrGroupId.join(','),
          'Exception',
          'Error',
          'Unrecoverable',
          'group_id',
          'mlsGroupId',
        ]) {
          expect(
            rendered.contains(forbidden),
            isFalse,
            reason: 'a blocked circle must never render "$forbidden"',
          );
        }
        // Proof the scan looked at the right subtree in the first place.
        expect(rendered, contains('This circle can’t be updated'));
      },
    );
  });

  // The banner states a fault the user cannot otherwise see, so every part of
  // it has to be legible to a low-vision user. It once was not: the amber
  // `HavenSecurityColors.warning` glyph sat on a 10 % tint of ITSELF, which
  // dropped the icon to 2.86:1 over the composited fill (it clears 3.19:1 over
  // a plain light surface, so the tint was the defect, not the token).
  //
  // Both themes are measured because that defect was light-only, and a fix
  // measured in one theme is how the mirror-image defect gets shipped.
  group('Blocked circle banner — contrast (WCAG 2.1 SC 1.4.11 / 1.4.3)', () {
    for (final (name, theme) in <(String, ThemeData)>[
      ('light', HavenTheme.light()),
      ('dark', HavenTheme.dark()),
    ]) {
      testWidgets('$name: every element clears its WCAG threshold', (
        tester,
      ) async {
        await _pumpBlockedCircle(tester, theme);
        final scheme = Theme.of(
          tester.element(find.byType(CirclesBottomSheet)),
        ).colorScheme;
        final paint = _readBannerPaint(tester);
        expect(
          paint.backdrop,
          scheme.surface,
          reason: 'the composite below assumes the sheet paints `surface`',
        );
        // A translucent fill is only as legible as what shows through it, so
        // the icon and the copy are measured against the COMPOSITE, which is
        // what the eye receives.
        final fill = Color.alphaBlend(paint.fill, paint.backdrop);

        void expectClears(Color fg, Color bg, double min, String what) {
          final ratio = _contrastRatio(fg, bg);
          expect(
            ratio,
            greaterThanOrEqualTo(min),
            reason:
                '$what must clear $min:1 in $name — got '
                '${ratio.toStringAsFixed(2)}:1 ($fg on $bg)',
          );
        }

        // 3:1 — a non-text indicator (SC 1.4.11). It is the only glyph that
        // says "fault" before the copy is read.
        expectClears(paint.icon, fill, 3, 'the alert icon');
        // 4.5:1 — titleSmall is 14sp w500, under the 18.66sp bold bar that
        // would make it large text (SC 1.4.3).
        expectClears(paint.title, fill, 4.5, 'the banner title');
        // 4.5:1 — bodySmall is 12sp.
        expectClears(paint.body, fill, 4.5, 'the banner body');
        // 3:1 — the CTA's own fill is the boundary that makes it findable as a
        // control against the banner behind it (SC 1.4.11).
        expectClears(paint.ctaFill, fill, 3, "the repair button's fill");
        expectClears(
          paint.ctaLabel,
          paint.ctaFill,
          4.5,
          "the repair button's label",
        );
      });

      testWidgets('$name: takes its colours from the error-container roles', (
        tester,
      ) async {
        await _pumpBlockedCircle(tester, theme);
        final scheme = Theme.of(
          tester.element(find.byType(CirclesBottomSheet)),
        ).colorScheme;
        final paint = _readBannerPaint(tester);
        // A literal cannot follow the theme, and the ratio test above cannot
        // reliably catch one: hard-code BOTH halves of the light pair and it
        // still measures 8.20:1 in the dark run, while hard-coding only the
        // foreground puts `#7F1D1D` on the dark `#7F1D1D` fill at 1:1.
        // Pinning the roles is what binds it.
        //
        // `errorContainer` rather than a tint of `warning`: this is a fault,
        // styled as `SharingHealthBanner` — the app's other fault banner —
        // already styles one.
        expect(
          paint.fill,
          scheme.errorContainer,
          reason: 'the banner fill must be the `errorContainer` role',
        );
        for (final (what, color) in <(String, Color)>[
          ('icon', paint.icon),
          ('title', paint.title),
          ('body', paint.body),
        ]) {
          expect(
            color,
            scheme.onErrorContainer,
            reason:
                'the banner $what must be the `onErrorContainer` role, the '
                'pair `errorContainer` was designed with',
          );
        }
      });
    }
  });
}
