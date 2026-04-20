/// Tests for MemberMarker widget and its age-pill formatter.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/widgets/map/member_marker.dart';

Widget _wrap(Widget child) {
  return MaterialApp(
    theme: ThemeData.light(),
    home: Scaffold(body: Center(child: child)),
  );
}

/// Pumps a [MemberMarker] with the given [lastSeen] and returns the
/// rendered text of the age pill (if any).
Future<String?> _agePillText(WidgetTester tester, DateTime? lastSeen) async {
  await tester.pumpWidget(
    _wrap(MemberMarker(initials: 'AB', lastSeen: lastSeen)),
  );
  // Find the age-pill Text widgets (exclude the initials text 'AB').
  final texts = tester.widgetList<Text>(find.byType(Text)).toList();
  // The pill text is not the initials text.
  final pillTexts = texts
      .map((t) => t.data ?? '')
      .where((s) => s != 'AB')
      .toList();
  return pillTexts.isEmpty ? null : pillTexts.first;
}

void main() {
  group('MemberMarker age pill – _formatAge branches', () {
    testWidgets('shows "just now" for age < 1 minute', (tester) async {
      final lastSeen = DateTime.now().subtract(const Duration(seconds: 45));
      final text = await _agePillText(tester, lastSeen);
      expect(text, 'just now');
    });

    testWidgets('shows "just now" for age exactly 59 seconds', (tester) async {
      final lastSeen = DateTime.now().subtract(const Duration(seconds: 59));
      final text = await _agePillText(tester, lastSeen);
      expect(text, 'just now');
    });

    testWidgets('shows "1m" for age exactly 1 minute', (tester) async {
      final lastSeen = DateTime.now().subtract(const Duration(minutes: 1));
      final text = await _agePillText(tester, lastSeen);
      expect(text, '1m');
    });

    testWidgets('shows "5m" for age 5 minutes', (tester) async {
      final lastSeen = DateTime.now().subtract(const Duration(minutes: 5));
      final text = await _agePillText(tester, lastSeen);
      expect(text, '5m');
    });

    testWidgets('shows "59m" for age 59 minutes', (tester) async {
      final lastSeen = DateTime.now().subtract(const Duration(minutes: 59));
      final text = await _agePillText(tester, lastSeen);
      expect(text, '59m');
    });

    testWidgets('shows "1h" for age exactly 60 minutes', (tester) async {
      final lastSeen = DateTime.now().subtract(const Duration(minutes: 60));
      final text = await _agePillText(tester, lastSeen);
      expect(text, '1h');
    });

    testWidgets('shows "23h" for age 23 hours 59 minutes', (tester) async {
      final lastSeen = DateTime.now().subtract(
        const Duration(hours: 23, minutes: 59),
      );
      final text = await _agePillText(tester, lastSeen);
      expect(text, '23h');
    });

    testWidgets('shows "1d" for age exactly 24 hours', (tester) async {
      final lastSeen = DateTime.now().subtract(const Duration(hours: 24));
      final text = await _agePillText(tester, lastSeen);
      expect(text, '1d');
    });

    testWidgets('shows "3d" for age 3 days', (tester) async {
      final lastSeen = DateTime.now().subtract(const Duration(days: 3));
      final text = await _agePillText(tester, lastSeen);
      expect(text, '3d');
    });

    testWidgets('renders no age pill when lastSeen is null', (tester) async {
      final text = await _agePillText(tester, null);
      expect(text, isNull);
    });
  });

  group('MemberMarker appearance', () {
    testWidgets('marker with 5-minute-old lastSeen shows "5m" pill text', (
      tester,
    ) async {
      final lastSeen = DateTime.now().subtract(const Duration(minutes: 5));
      await tester.pumpWidget(
        _wrap(MemberMarker(initials: 'TU', lastSeen: lastSeen)),
      );

      expect(find.text('5m'), findsOneWidget);
    });

    testWidgets('marker is never wrapped in a fading Opacity widget', (
      tester,
    ) async {
      // Previously stale markers used Opacity(opacity: 0.55). The new
      // design renders all markers at full opacity regardless of age.
      final lastSeen = DateTime.now().subtract(const Duration(hours: 5));
      await tester.pumpWidget(
        _wrap(MemberMarker(initials: 'ZZ', lastSeen: lastSeen)),
      );

      // Verify no Opacity widget with opacity < 1.0 exists in the tree.
      final opacityWidgets = tester.widgetList<Opacity>(find.byType(Opacity));
      for (final op in opacityWidgets) {
        expect(
          op.opacity,
          1.0,
          reason: 'All marker Opacity widgets should have full opacity',
        );
      }
    });

    testWidgets(
      'accessibility label uses expanded "just now" for sub-minute ages',
      (tester) async {
        final lastSeen = DateTime.now().subtract(const Duration(seconds: 30));
        await tester.pumpWidget(
          _wrap(MemberMarker(initials: 'JD', lastSeen: lastSeen)),
        );

        final semantics = tester.getSemantics(find.byType(MemberMarker));
        expect(semantics.label, 'JD member marker, last seen just now');
      },
    );

    testWidgets('accessibility label uses singular "1 minute ago"', (
      tester,
    ) async {
      final lastSeen = DateTime.now().subtract(const Duration(minutes: 1));
      await tester.pumpWidget(
        _wrap(MemberMarker(initials: 'JD', lastSeen: lastSeen)),
      );

      final semantics = tester.getSemantics(find.byType(MemberMarker));
      expect(semantics.label, 'JD member marker, last seen 1 minute ago');
    });

    testWidgets('accessibility label uses plural "X minutes ago"', (
      tester,
    ) async {
      final lastSeen = DateTime.now().subtract(const Duration(minutes: 5));
      await tester.pumpWidget(
        _wrap(MemberMarker(initials: 'JD', lastSeen: lastSeen)),
      );

      final semantics = tester.getSemantics(find.byType(MemberMarker));
      expect(semantics.label, 'JD member marker, last seen 5 minutes ago');
    });

    testWidgets('accessibility label uses singular "1 hour ago"', (
      tester,
    ) async {
      final lastSeen = DateTime.now().subtract(const Duration(hours: 1));
      await tester.pumpWidget(
        _wrap(MemberMarker(initials: 'JD', lastSeen: lastSeen)),
      );

      final semantics = tester.getSemantics(find.byType(MemberMarker));
      expect(semantics.label, 'JD member marker, last seen 1 hour ago');
    });

    testWidgets('accessibility label uses plural "X hours ago"', (
      tester,
    ) async {
      final lastSeen = DateTime.now().subtract(const Duration(hours: 2));
      await tester.pumpWidget(
        _wrap(MemberMarker(initials: 'JD', lastSeen: lastSeen)),
      );

      final semantics = tester.getSemantics(find.byType(MemberMarker));
      expect(semantics.label, 'JD member marker, last seen 2 hours ago');
    });

    testWidgets('accessibility label uses singular "1 day ago"', (
      tester,
    ) async {
      final lastSeen = DateTime.now().subtract(const Duration(days: 1));
      await tester.pumpWidget(
        _wrap(MemberMarker(initials: 'JD', lastSeen: lastSeen)),
      );

      final semantics = tester.getSemantics(find.byType(MemberMarker));
      expect(semantics.label, 'JD member marker, last seen 1 day ago');
    });

    testWidgets('accessibility label uses plural "X days ago"', (tester) async {
      final lastSeen = DateTime.now().subtract(const Duration(days: 3));
      await tester.pumpWidget(
        _wrap(MemberMarker(initials: 'JD', lastSeen: lastSeen)),
      );

      final semantics = tester.getSemantics(find.byType(MemberMarker));
      expect(semantics.label, 'JD member marker, last seen 3 days ago');
    });

    testWidgets('accessibility label omits "last seen" when lastSeen is null', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(const MemberMarker(initials: 'AB')));

      final semantics = tester.getSemantics(find.byType(MemberMarker));
      expect(semantics.label, 'AB member marker');
    });

    testWidgets('pill text is clamped to 1.3x when textScaler exceeds cap', (
      tester,
    ) async {
      // Simulate a user with system text scale 2.0x. The pill should
      // render at no more than 1.3x to preserve the 56×56 footprint.
      final lastSeen = DateTime.now().subtract(const Duration(minutes: 5));
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.light(),
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: Scaffold(
              body: Center(
                child: MemberMarker(initials: 'ZZ', lastSeen: lastSeen),
              ),
            ),
          ),
        ),
      );

      final pillText = tester
          .widgetList<Text>(find.byType(Text))
          .firstWhere((t) => t.data == '5m');
      final effective = pillText.textScaler!.scale(11);
      // 11 * 1.3 = 14.3 — must not exceed that; 11 * 2 = 22 would fail.
      expect(effective, lessThanOrEqualTo(14.31));
      expect(effective, greaterThanOrEqualTo(11));
    });
  });
}
