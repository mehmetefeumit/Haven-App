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
    testWidgets('renders no age pill for age < 1 minute', (tester) async {
      // Sub-minute freshness is the default state for recently-received
      // locations; rendering a pill on every marker would be visual noise.
      // The pill only appears once the data is 1 minute stale or older.
      final lastSeen = DateTime.now().subtract(const Duration(seconds: 45));
      final text = await _agePillText(tester, lastSeen);
      expect(text, isNull);
    });

    testWidgets('renders no age pill at exactly 59 seconds', (tester) async {
      final lastSeen = DateTime.now().subtract(const Duration(seconds: 59));
      final text = await _agePillText(tester, lastSeen);
      expect(text, isNull);
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

    testWidgets('accessibility label omits "last seen" for sub-minute ages', (
      tester,
    ) async {
      // When the visible pill is suppressed (age < 1 minute), the SR label
      // must match — announcing "last seen just now" on every fresh marker
      // would be noise, and would diverge from what a sighted user sees.
      final lastSeen = DateTime.now().subtract(const Duration(seconds: 30));
      await tester.pumpWidget(
        _wrap(MemberMarker(initials: 'JD', lastSeen: lastSeen)),
      );

      final semantics = tester.getSemantics(find.byType(MemberMarker));
      expect(semantics.label, 'JD member marker');
    });

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

  group('MemberMarker pulse animation', () {
    /// Pumps a [MemberMarker] under an optional [reduceMotion] setting and
    /// returns the `tester` with control over subsequent rebuilds.
    Future<void> pumpMarker(
      WidgetTester tester, {
      required DateTime? lastSeen,
      bool reduceMotion = false,
      String initials = 'AB',
      String? publicKey,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.light(),
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: reduceMotion),
            child: Scaffold(
              body: Center(
                child: MemberMarker(
                  initials: initials,
                  publicKey: publicKey,
                  lastSeen: lastSeen,
                ),
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('does not pulse on first mount', (tester) async {
      await pumpMarker(
        tester,
        lastSeen: DateTime.now().subtract(const Duration(minutes: 1)),
      );
      // Advance a few frames — the pulse would appear within the first
      // tick if it were going to fire.
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byKey(MemberMarker.pulseLayerKey), findsNothing);
    });

    testWidgets('pulses when lastSeen advances to a newer timestamp', (
      tester,
    ) async {
      final t0 = DateTime.now().subtract(const Duration(minutes: 5));
      await pumpMarker(tester, lastSeen: t0);
      expect(find.byKey(MemberMarker.pulseLayerKey), findsNothing);

      // Re-pump with a strictly newer timestamp.
      final t1 = t0.add(const Duration(minutes: 1));
      await pumpMarker(tester, lastSeen: t1);
      // Advance into the animation so the forward phase is active.
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byKey(MemberMarker.pulseLayerKey), findsOneWidget);
    });

    testWidgets('pulse layer is removed once the animation completes', (
      tester,
    ) async {
      final t0 = DateTime.now().subtract(const Duration(minutes: 5));
      await pumpMarker(tester, lastSeen: t0);
      final t1 = t0.add(const Duration(minutes: 1));
      await pumpMarker(tester, lastSeen: t1);

      await tester.pumpAndSettle();

      expect(find.byKey(MemberMarker.pulseLayerKey), findsNothing);
    });

    testWidgets('does not pulse when lastSeen is unchanged', (tester) async {
      final t0 = DateTime.now().subtract(const Duration(minutes: 5));
      await pumpMarker(tester, lastSeen: t0);
      await pumpMarker(tester, lastSeen: t0);
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byKey(MemberMarker.pulseLayerKey), findsNothing);
    });

    testWidgets('does not pulse when lastSeen regresses', (tester) async {
      final t0 = DateTime.now().subtract(const Duration(minutes: 1));
      await pumpMarker(tester, lastSeen: t0);
      final older = t0.subtract(const Duration(minutes: 5));
      await pumpMarker(tester, lastSeen: older);
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byKey(MemberMarker.pulseLayerKey), findsNothing);
    });

    testWidgets('respects MediaQuery.disableAnimations', (tester) async {
      final t0 = DateTime.now().subtract(const Duration(minutes: 5));
      await pumpMarker(tester, lastSeen: t0, reduceMotion: true);
      final t1 = t0.add(const Duration(minutes: 1));
      await pumpMarker(tester, lastSeen: t1, reduceMotion: true);

      // Check immediately (t=0): a zero-duration animation would already
      // be gone at t=100ms but would still be visible at t=0 if it was
      // incorrectly started. Catches "fires but completes instantly".
      expect(find.byKey(MemberMarker.pulseLayerKey), findsNothing);

      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(MemberMarker.pulseLayerKey), findsNothing);

      await tester.pumpAndSettle();
      expect(find.byKey(MemberMarker.pulseLayerKey), findsNothing);
    });

    testWidgets('stops in-flight pulse when reduce motion toggles on', (
      tester,
    ) async {
      // Start without reduce motion and trigger a pulse.
      final t0 = DateTime.now().subtract(const Duration(minutes: 5));
      await pumpMarker(tester, lastSeen: t0);
      final t1 = t0.add(const Duration(minutes: 1));
      await pumpMarker(tester, lastSeen: t1);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(MemberMarker.pulseLayerKey), findsOneWidget);

      // Toggle Reduce Motion on — the in-flight animation must abort.
      await pumpMarker(tester, lastSeen: t1, reduceMotion: true);
      await tester.pump();
      expect(find.byKey(MemberMarker.pulseLayerKey), findsNothing);
    });

    testWidgets('disposes AnimationController cleanly on unmount', (
      tester,
    ) async {
      final t0 = DateTime.now().subtract(const Duration(minutes: 5));
      await pumpMarker(tester, lastSeen: t0);
      final t1 = t0.add(const Duration(minutes: 1));
      await pumpMarker(tester, lastSeen: t1);
      await tester.pump(const Duration(milliseconds: 100));

      // Replace the subtree to unmount the marker. A leaked ticker /
      // controller would surface as a framework assertion during the
      // subsequent pumps.
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pumpAndSettle();
    });

    testWidgets('does not pulse when only unrelated props change', (
      tester,
    ) async {
      final t0 = DateTime.now().subtract(const Duration(minutes: 5));
      await pumpMarker(tester, lastSeen: t0);
      // Re-pump with different initials but identical lastSeen.
      await pumpMarker(tester, lastSeen: t0, initials: 'CD');
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byKey(MemberMarker.pulseLayerKey), findsNothing);
    });

    testWidgets('pulse layer renders with theme outline color', (tester) async {
      final t0 = DateTime.now().subtract(const Duration(minutes: 5));
      await pumpMarker(tester, lastSeen: t0);
      final t1 = t0.add(const Duration(minutes: 1));
      await pumpMarker(tester, lastSeen: t1);
      await tester.pump(const Duration(milliseconds: 100));

      final pulseContainer = tester.widget<Container>(
        find.byKey(MemberMarker.pulseLayerKey),
      );
      final decoration = pulseContainer.decoration! as BoxDecoration;
      // Pulse uses `colorScheme.outline` (a neutral mid-tone) so light/dark
      // themes produce symmetric peripheral salience on the same map tiles.
      final outline = ThemeData.light().colorScheme.outline;

      // Sanity: we're mid-animation, so alpha must be strictly positive.
      expect(decoration.color!.a, greaterThan(0.0));
      expect(decoration.color!.r, outline.r);
      expect(decoration.color!.g, outline.g);
      expect(decoration.color!.b, outline.b);
    });
  });
}
