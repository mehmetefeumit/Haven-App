/// Tests for the shared [RefreshRingButton] (segmented refresh ring).
///
/// Covers idle / no-inbox rendering and tap routing, the painter geometry and
/// per-segment colors (via a recording canvas), the outcome glyphs, the
/// accessibility labels, and the animation lifecycle (entrance, settle/hold,
/// reduced motion, disposal).
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/models/relay_ring_slot.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/theme/colors.dart';
import 'package:haven/src/widgets/common/refresh_ring/refresh_ring_button.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../helpers/localized_app_harness.dart';

/// The canvas size the recording paints into, and its derived geometry. The
/// painter uses `radius = (shortestSide - strokeWidth(3)) / 2`.
const Size _kPaintSize = Size(22, 22);
const Offset _kCenter = Offset(11, 11);
const double _kRadius = (22 - 3) / 2; // 9.5

/// A fake [Canvas] that records the arc and line draw calls so the private ring
/// painter can be inspected without a raster context.
class _RecordingCanvas implements Canvas {
  final List<({Color color, double strokeWidth})> arcs = [];
  final List<({Offset p1, Offset p2, Color color})> lines = [];

  @override
  void drawArc(
    Rect rect,
    double startAngle,
    double sweepAngle,
    bool useCenter,
    Paint paint,
  ) {
    arcs.add((color: paint.color, strokeWidth: paint.strokeWidth));
  }

  @override
  void drawLine(Offset p1, Offset p2, Paint paint) {
    lines.add((p1: p1, p2: p2, color: paint.color));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// Lines that form the center outcome glyph (near the center).
Iterable<({Offset p1, Offset p2, Color color})> _glyphLines(
  _RecordingCanvas c,
) => c.lines.where((l) {
  final mid = (l.p1 + l.p2) / 2;
  return (mid - _kCenter).distance < _kRadius * 0.6;
});

/// Lines that form a per-segment error tick (out at the arc radius).
Iterable<({Offset p1, Offset p2, Color color})> _tickLines(
  _RecordingCanvas c,
) => c.lines.where((l) {
  final mid = (l.p1 + l.p2) / 2;
  return (mid - _kCenter).distance >= _kRadius * 0.6;
});

void _expectColor(Color actual, Color expected) {
  const epsilon = 1.5 / 255;
  expect((actual.r - expected.r).abs(), lessThan(epsilon));
  expect((actual.g - expected.g).abs(), lessThan(epsilon));
  expect((actual.b - expected.b).abs(), lessThan(epsilon));
}

const Color _amber = HavenSecurityColors.warning;
const Color _green = HavenSecurityColors.encrypted;
const Color _red = HavenSecurityColors.danger;

Widget _host({
  required List<RelayRingSlotState> slots,
  bool noInbox = false,
  VoidCallback? onPressed,
  VoidCallback? onNoInbox,
  bool reduceMotion = true,
  String tooltip = 'Refresh',
  RefreshRingVocabulary vocabulary = RefreshRingVocabulary.responded,
}) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: reduceMotion),
    child: Scaffold(
      appBar: AppBar(
        actions: [
          RefreshRingButton(
            slots: slots,
            onPressed: onPressed ?? () {},
            tooltip: tooltip,
            noInbox: noInbox,
            onNoInbox: onNoInbox,
            vocabulary: vocabulary,
          ),
        ],
      ),
    ),
  ),
);

CustomPainter _painter(WidgetTester tester) => tester
    .widget<CustomPaint>(find.byKey(WidgetKeys.refreshRingPaint))
    .painter!;

/// Paints the live ring into a recording canvas and returns it.
_RecordingCanvas _record(WidgetTester tester) {
  final canvas = _RecordingCanvas();
  _painter(tester).paint(canvas, _kPaintSize);
  return canvas;
}

Iterable<({Color color, double strokeWidth})> _mainArcs(_RecordingCanvas c) =>
    c.arcs.where((a) => a.strokeWidth < 4);

Iterable<({Color color, double strokeWidth})> _haloArcs(_RecordingCanvas c) =>
    c.arcs.where((a) => a.strokeWidth >= 4);

void main() {
  group('RefreshRingButton idle & no-inbox', () {
    testWidgets('idle (empty slots) shows the refresh icon, not a ring', (
      tester,
    ) async {
      await tester.pumpWidget(_host(slots: const []));
      await tester.pumpAndSettle();

      expect(find.byIcon(LucideIcons.refreshCw), findsOneWidget);
      expect(find.byKey(WidgetKeys.refreshRingPaint), findsNothing);
    });

    testWidgets('an all-pending list is treated as idle (icon, no ring)', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          slots: const [RelayRingSlotState.pending, RelayRingSlotState.pending],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byIcon(LucideIcons.refreshCw), findsOneWidget);
      expect(find.byKey(WidgetKeys.refreshRingPaint), findsNothing);
    });

    testWidgets('idle tap calls onPressed', (tester) async {
      var pressed = 0;
      await tester.pumpWidget(
        _host(slots: const [], onPressed: () => pressed++),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byType(RefreshRingButton));
      await tester.pump();
      expect(pressed, 1);
    });

    testWidgets('no-inbox shows the inbox icon and routes a tap to onNoInbox', (
      tester,
    ) async {
      var pressed = 0;
      var configure = 0;
      await tester.pumpWidget(
        _host(
          slots: const [],
          noInbox: true,
          onPressed: () => pressed++,
          onNoInbox: () => configure++,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byIcon(LucideIcons.inbox), findsOneWidget);
      expect(find.byIcon(LucideIcons.refreshCw), findsNothing);

      await tester.tap(find.byType(RefreshRingButton));
      await tester.pump();
      // No-inbox must route to relay settings, never silently re-poll.
      expect(configure, 1);
      expect(pressed, 0);
    });

    testWidgets('noInbox without onNoInbox falls back to the refresh icon', (
      tester,
    ) async {
      // Defensive: all three sites gate on onNoInbox != null, so a noInbox
      // flag with no destination must behave like a normal refresh (icon +
      // onPressed), never a null dereference or a dead-end inbox icon.
      var pressed = 0;
      await tester.pumpWidget(
        _host(slots: const [], noInbox: true, onPressed: () => pressed++),
      );
      await tester.pumpAndSettle();

      expect(find.byIcon(LucideIcons.refreshCw), findsOneWidget);
      expect(find.byIcon(LucideIcons.inbox), findsNothing);

      await tester.tap(find.byType(RefreshRingButton));
      await tester.pump();
      expect(pressed, 1);
    });

    testWidgets('keeps a >=48dp tap target', (tester) async {
      await tester.pumpWidget(_host(slots: const []));
      await tester.pumpAndSettle();

      final size = tester.getSize(find.byType(RefreshRingButton));
      expect(size.width, greaterThanOrEqualTo(48));
      expect(size.height, greaterThanOrEqualTo(48));
    });
  });

  group('RefreshRingButton painter geometry & colors', () {
    testWidgets('draws one solid arc + halo per relay while checking', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          slots: const [
            RelayRingSlotState.checking,
            RelayRingSlotState.checking,
            RelayRingSlotState.checking,
          ],
        ),
      );
      await tester.pumpAndSettle();

      final c = _record(tester);
      expect(_mainArcs(c), hasLength(3));
      expect(_haloArcs(c), hasLength(3));
      // Checking is not settled, so no outcome glyph yet.
      expect(c.lines, isEmpty);
      for (final arc in _mainArcs(c)) {
        _expectColor(arc.color, _amber);
      }
    });

    testWidgets('ok arcs are green, error arcs are red (partial)', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(slots: const [RelayRingSlotState.ok, RelayRingSlotState.error]),
      );
      await tester.pumpAndSettle();

      final mains = _mainArcs(_record(tester)).toList();
      expect(mains, hasLength(2));
      _expectColor(mains[0].color, _green);
      _expectColor(mains[1].color, _red);
    });

    testWidgets('a pending segment is a thin full-opacity arc with no halo', (
      tester,
    ) async {
      // A mixed list exercises the painter's pending branch directly.
      await tester.pumpWidget(
        _host(
          slots: const [RelayRingSlotState.pending, RelayRingSlotState.error],
        ),
      );
      await tester.pumpAndSettle();

      final c = _record(tester);
      // Only the error segment gets a halo; the pending one does not.
      expect(_haloArcs(c), hasLength(1));
      // Exactly one arc is the thin (2dp) pending arc — a shape cue, not a
      // translucent one (full opacity keeps it above the 3:1 contrast floor).
      final thin = c.arcs.where((a) => a.strokeWidth < 2.5).toList();
      expect(thin, hasLength(1));
      expect(thin.single.color.a, 1.0);
    });
  });

  group('RefreshRingButton outcome glyph & error tick', () {
    testWidgets('all-ok draws a green check glyph and no error ticks', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(slots: const [RelayRingSlotState.ok, RelayRingSlotState.ok]),
      );
      await tester.pumpAndSettle();

      final c = _record(tester);
      final glyph = _glyphLines(c).toList();
      expect(glyph, hasLength(2)); // check = two central strokes
      for (final l in glyph) {
        _expectColor(l.color, _green);
      }
      expect(_tickLines(c), isEmpty);
    });

    testWidgets('any failure draws a red cross glyph', (tester) async {
      await tester.pumpWidget(
        _host(slots: const [RelayRingSlotState.ok, RelayRingSlotState.error]),
      );
      await tester.pumpAndSettle();

      final glyph = _glyphLines(_record(tester)).toList();
      expect(glyph, hasLength(2)); // cross = two central strokes
      for (final l in glyph) {
        _expectColor(l.color, _red);
      }
    });

    testWidgets('error segments carry a per-arc tick (non-color cue)', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          slots: const [
            RelayRingSlotState.ok,
            RelayRingSlotState.error,
            RelayRingSlotState.error,
          ],
        ),
      );
      await tester.pumpAndSettle();

      // One peripheral tick per error arc (here: 2), distinguishing failures
      // by shape, not hue alone.
      final ticks = _tickLines(_record(tester)).toList();
      expect(ticks, hasLength(2));
      // Every tick endpoint must stay within the canvas, or the real
      // (clipping) canvas would cut the outer tip — recording canvas does not.
      const bounds = Rect.fromLTWH(0, 0, 22, 22);
      for (final t in ticks) {
        expect(
          bounds.contains(t.p1),
          isTrue,
          reason: 'tick p1 $t out of bounds',
        );
        expect(
          bounds.contains(t.p2),
          isTrue,
          reason: 'tick p2 $t out of bounds',
        );
      }
    });

    testWidgets('an error tick is present even mid-flight (before settle)', (
      tester,
    ) async {
      // A mixed in-flight ring is not yet "settled", so there is no center
      // glyph — but the error arc must still be shape-distinct.
      await tester.pumpWidget(
        _host(
          slots: const [RelayRingSlotState.error, RelayRingSlotState.checking],
        ),
      );
      await tester.pumpAndSettle();

      final c = _record(tester);
      expect(_glyphLines(c), isEmpty); // not settled -> no center glyph
      expect(_tickLines(c), hasLength(1)); // the one error arc is ticked
    });
  });

  group('RefreshRingButton semantics', () {
    testWidgets('checking exposes a resolved/total label', (tester) async {
      await tester.pumpWidget(
        _host(
          slots: const [
            RelayRingSlotState.ok,
            RelayRingSlotState.checking,
            RelayRingSlotState.checking,
          ],
        ),
      );
      await tester.pumpAndSettle();

      final l10n = l10nOf(tester, RefreshRingButton);
      expect(
        find.bySemanticsLabel(l10n.refreshRingSemanticChecking(1, 3)),
        findsOneWidget,
      );
    });

    testWidgets('all-ok exposes a success label', (tester) async {
      await tester.pumpWidget(
        _host(slots: const [RelayRingSlotState.ok, RelayRingSlotState.ok]),
      );
      await tester.pumpAndSettle();

      final l10n = l10nOf(tester, RefreshRingButton);
      expect(
        find.bySemanticsLabel(l10n.refreshRingSemanticAllOk(2)),
        findsOneWidget,
      );
    });

    testWidgets('no-inbox exposes the routing label', (tester) async {
      await tester.pumpWidget(
        _host(slots: const [], noInbox: true, onNoInbox: () {}),
      );
      await tester.pumpAndSettle();

      final l10n = l10nOf(tester, RefreshRingButton);
      expect(
        find.bySemanticsLabel(l10n.refreshRingSemanticNoInbox),
        findsOneWidget,
      );
    });

    testWidgets('hasData vocabulary uses the data-centric labels', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          slots: const [RelayRingSlotState.ok, RelayRingSlotState.error],
          vocabulary: RefreshRingVocabulary.hasData,
        ),
      );
      await tester.pumpAndSettle();

      final l10n = l10nOf(tester, RefreshRingButton);
      // The relay-settings flow must say "have your data", never "responded".
      expect(
        find.bySemanticsLabel(l10n.refreshRingSemanticPartialFound(1, 2)),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel(l10n.refreshRingSemanticPartial(1, 2)),
        findsNothing,
      );
    });
  });

  group('RefreshRingButton animation lifecycle', () {
    testWidgets('a relay flipping to ok turns its arc green', (tester) async {
      await tester.pumpWidget(
        _host(
          slots: const [
            RelayRingSlotState.checking,
            RelayRingSlotState.checking,
          ],
          reduceMotion: false,
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));

      // First relay responds.
      await tester.pumpWidget(
        _host(
          slots: const [RelayRingSlotState.ok, RelayRingSlotState.checking],
          reduceMotion: false,
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));

      final mains = _mainArcs(_record(tester)).toList();
      _expectColor(mains[0].color, _green);
      _expectColor(mains[1].color, _amber);
    });

    testWidgets('an all-green result holds, then fades to the refresh icon', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          slots: const [RelayRingSlotState.ok, RelayRingSlotState.ok],
          reduceMotion: false,
        ),
      );
      // Entrance + color settle, well within the hold.
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byKey(WidgetKeys.refreshRingPaint), findsOneWidget);

      // Hold elapses → fades back to the calm icon.
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(find.byKey(WidgetKeys.refreshRingPaint), findsNothing);
      expect(find.byIcon(LucideIcons.refreshCw), findsOneWidget);
    });

    testWidgets('a partial result stays sticky (no fade)', (tester) async {
      await tester.pumpWidget(
        _host(
          slots: const [RelayRingSlotState.ok, RelayRingSlotState.error],
          reduceMotion: false,
        ),
      );
      // Past the hold window an all-ok ring would use, the error ring remains.
      await tester.pump(const Duration(seconds: 3));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(WidgetKeys.refreshRingPaint), findsOneWidget);
    });

    testWidgets('reduced motion shows the final ring, then still dismisses', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(slots: const [RelayRingSlotState.ok, RelayRingSlotState.ok]),
      );
      await tester.pump(); // one frame: final colors are present immediately

      expect(find.byKey(WidgetKeys.refreshRingPaint), findsOneWidget);
      for (final arc in _mainArcs(_record(tester))) {
        _expectColor(arc.color, _green);
      }

      // The hold is a plain timer (not an animation), so reduced motion still
      // returns to the calm icon after it — just without the crossfade.
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(find.byKey(WidgetKeys.refreshRingPaint), findsNothing);
      expect(find.byIcon(LucideIcons.refreshCw), findsOneWidget);
    });

    testWidgets('disposes cleanly while a refresh is in flight', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          slots: const [
            RelayRingSlotState.checking,
            RelayRingSlotState.checking,
          ],
          reduceMotion: false,
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      // Replace the whole tree mid-animation; controllers + timers must be
      // cancelled in dispose (no "Timer/Ticker still pending" failure).
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  });
}
