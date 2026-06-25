/// Tests for [DimOverlay].
///
/// The dim overlay sits `Positioned.fill` directly above the map in
/// `MapShell`. It has two jobs that pull in opposite directions:
///
/// 1. Regression coverage for the "map frozen until I touch the panel" bug:
///    when the scrim is a sub-perceptual residual (which the bottom sheet's
///    drag-release velocity spring can strand just above the collapsed snap)
///    it must render nothing and let every gesture reach the map.
/// 2. One-gesture dismiss: while the scrim IS visible, a tap collapses the
///    sheet (and is shielded from the map), but a *drag* must collapse the
///    sheet AND fall through to the map so the user pans in a single motion.
///
/// Taps and drags are probed separately because they take different arena
/// paths: a tap is caught by the scrim's tap recognizer (shielding the map),
/// while a drag is observed by the scrim's arena-invisible [Listener] (to
/// collapse) yet still reaches the map's own pan recognizer underneath.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/widgets/common/dim_overlay.dart';

void main() {
  /// Builds the `MapShell`-shaped stack: a full-screen pointer target standing
  /// in for the map, with a [DimOverlay] layered on top of it. The stand-in
  /// records taps and pan-starts separately so a test can assert exactly which
  /// pointer interactions reached the map.
  Future<
    ({
      ValueGetter<bool> mapTapped,
      ValueGetter<bool> mapPanned,
      ValueGetter<int> dismissCount,
    })
  >
  pumpOverlayOverMap(WidgetTester tester, {required double opacity}) async {
    var mapTapped = false;
    var mapPanned = false;
    var dismissCount = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              // Stand-in for MapPage: an opaque, full-screen target that
              // records taps and pan-starts (the map's own recognizers live
              // below the scrim and only fire if the pointer reaches them).
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => mapTapped = true,
                  onPanStart: (_) => mapPanned = true,
                  child: const ColoredBox(color: Color(0xFF00FF00)),
                ),
              ),
              Positioned.fill(
                child: DimOverlay(
                  opacity: opacity,
                  onDismiss: () => dismissCount++,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    return (
      mapTapped: () => mapTapped,
      mapPanned: () => mapPanned,
      dismissCount: () => dismissCount,
    );
  }

  group('DimOverlay — pointer routing', () {
    // The velocity-spring snap-to-collapsed and the programmatic collapse can
    // each strand the expansion a hair above 0 (worst case ~0.014). At every
    // value in this band the scrim is imperceptible, so the overlay must render
    // nothing and let pointers fall through to the map beneath it.
    for (final residual in <double>[0.0014, 0.006, 0.0137, 0.019]) {
      testWidgets(
        'lets pointers through to the map when opacity is a sub-perceptual '
        'residual ($residual)',
        (tester) async {
          final latches = await pumpOverlayOverMap(tester, opacity: residual);

          await tester.tapAt(tester.getCenter(find.byType(Scaffold)));
          await tester.pump();

          expect(
            latches.mapTapped(),
            isTrue,
            reason:
                'map under an imperceptible DimOverlay must receive the tap',
          );
          expect(
            latches.dismissCount(),
            0,
            reason: 'an imperceptible DimOverlay must not intercept gestures',
          );
        },
      );
    }

    // Guards against an over-correction that disables the dim entirely: once
    // the scrim is actually visible it MUST keep absorbing taps so tapping the
    // dimmed map collapses the sheet — and must NOT leak the tap to the map.
    for (final visible in <double>[0.05, 0.3, 1]) {
      testWidgets(
        'intercepts taps to collapse the sheet (and shields the map) when '
        'visibly dimmed ($visible)',
        (tester) async {
          final latches = await pumpOverlayOverMap(tester, opacity: visible);

          await tester.tapAt(tester.getCenter(find.byType(Scaffold)));
          await tester.pump();

          expect(
            latches.dismissCount(),
            1,
            reason: 'a visible DimOverlay must catch the tap (tap-to-collapse)',
          );
          expect(
            latches.mapTapped(),
            isFalse,
            reason: 'a visible DimOverlay must shield the map from the tap',
          );
          expect(
            latches.mapPanned(),
            isFalse,
            reason: 'a tap must not start a map pan',
          );
        },
      );
    }
  });

  group('DimOverlay — drag-through (one-gesture dismiss + pan)', () {
    // The core feature: a drag starting on the visible scrim must collapse the
    // sheet AND let the same drag reach the map, so the user moves the map in
    // one gesture rather than tapping to dismiss and then dragging.
    for (final dir in const <({String name, Offset delta})>[
      (name: 'down', delta: Offset(0, 40)),
      (name: 'up', delta: Offset(0, -40)),
      (name: 'sideways', delta: Offset(40, 0)),
    ]) {
      testWidgets(
        'a ${dir.name} drag on a visible scrim collapses the sheet AND reaches '
        'the map',
        (tester) async {
          final latches = await pumpOverlayOverMap(tester, opacity: 0.5);

          await tester.dragFrom(
            tester.getCenter(find.byType(Scaffold)),
            dir.delta,
          );
          await tester.pumpAndSettle();

          expect(
            latches.dismissCount(),
            1,
            reason: 'a drag on the scrim must collapse the sheet exactly once',
          );
          expect(
            latches.mapPanned(),
            isTrue,
            reason:
                'the same drag must fall through to the map so it pans in one '
                'gesture',
          );
          expect(
            latches.mapTapped(),
            isFalse,
            reason: 'a drag is not a tap',
          );
        },
      );
    }

    testWidgets(
      'a pinch starting on the scrim collapses the sheet at most once and '
      'reaches the map',
      (tester) async {
        final latches = await pumpOverlayOverMap(tester, opacity: 0.5);
        final center = tester.getCenter(find.byType(Scaffold));

        // Two fingers land on the scrim and spread apart (a pinch-zoom). Only
        // the first pointer drives the dismiss; the map still receives both.
        final g1 = await tester.startGesture(center - const Offset(20, 0));
        final g2 = await tester.startGesture(center + const Offset(20, 0));
        await g1.moveBy(const Offset(-40, 0));
        await g2.moveBy(const Offset(40, 0));
        await tester.pump();
        await g1.up();
        await g2.up();
        await tester.pumpAndSettle();

        expect(
          latches.dismissCount(),
          1,
          reason:
              'a multi-touch gesture must not double-collapse — only the first '
              'pointer drives the dismiss',
        );
      },
    );

    testWidgets(
      'a drag that stays within the touch slop is treated as a tap '
      '(collapses, does not pan)',
      (tester) async {
        final latches = await pumpOverlayOverMap(tester, opacity: 0.5);

        // A 4px wobble is below kTouchSlop (18): the scrim's Listener does NOT
        // fire the drag-dismiss, and the map's drag recognizers do not engage
        // either. Instead the tap recognizer wins and fires onDismiss once — so
        // dismissCount is 1 (a tap-to-collapse), not 0, and the map never pans.
        await tester.dragFrom(
          tester.getCenter(find.byType(Scaffold)),
          const Offset(0, 4),
        );
        await tester.pumpAndSettle();

        expect(latches.dismissCount(), 1);
        expect(
          latches.mapPanned(),
          isFalse,
          reason: 'a sub-slop wobble must not pan the map',
        );
      },
    );
  });

  group('DimOverlay — reappear after collapse', () {
    // When the scrim fades out mid-collapse its pointer layers unmount before
    // the in-flight pointer lifts, so its up event is never delivered. The
    // overlay must clear that stale gesture when it disappears, otherwise the
    // active-pointer guard would swallow the first pointer of the next drag
    // once the scrim reappears.
    testWidgets('a drag still works after the scrim hides and reappears', (
      tester,
    ) async {
      var dismissCount = 0;
      var mapPanned = false;
      var opacity = 0.5;
      late StateSetter setOuterState;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                setOuterState = setState;
                return Stack(
                  children: [
                    Positioned.fill(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onPanStart: (_) => mapPanned = true,
                        child: const ColoredBox(color: Color(0xFF00FF00)),
                      ),
                    ),
                    Positioned.fill(
                      child: DimOverlay(
                        opacity: opacity,
                        onDismiss: () => dismissCount++,
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // First drag: collapse the sheet, then simulate the scrim fading out by
      // dropping the opacity below the visible threshold while the gesture is
      // still notionally in flight.
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(Scaffold)),
      );
      await gesture.moveBy(const Offset(0, 40));
      await tester.pump();
      expect(dismissCount, 1);
      setOuterState(() => opacity = 0); // scrim hides (pointer layers unmount)
      await tester.pump();
      await gesture.up(); // up arrives with no scrim mounted to receive it

      // Sheet re-expands → scrim reappears.
      setOuterState(() => opacity = 0.5);
      await tester.pump();

      // Second drag must collapse again — proving the stale active-pointer was
      // cleared when the scrim hid.
      await tester.dragFrom(
        tester.getCenter(find.byType(Scaffold)),
        const Offset(0, 40),
      );
      await tester.pumpAndSettle();

      expect(
        dismissCount,
        2,
        reason: 'a drag after the scrim reappears must still collapse',
      );
      expect(mapPanned, isTrue);
    });
  });

  group('DimOverlay — gesture state hygiene', () {
    testWidgets(
      'a cancelled drag does not wedge the tracker — the next drag collapses',
      (tester) async {
        final latches = await pumpOverlayOverMap(tester, opacity: 0.5);
        final center = tester.getCenter(find.byType(Scaffold));

        final gesture = await tester.startGesture(center);
        await gesture.moveBy(const Offset(0, 40));
        await tester.pump();
        expect(latches.dismissCount(), 1);
        await gesture.cancel(); // aborts mid-gesture, no pointer-up
        await tester.pumpAndSettle();

        // The cancel must have cleared the active-pointer guard; otherwise this
        // second drag's pointer-down would be ignored and the count stays 1.
        await tester.dragFrom(center, const Offset(0, 40));
        await tester.pumpAndSettle();
        expect(latches.dismissCount(), 2);
      },
    );

    testWidgets('a null onDismiss is a no-op and never throws', (tester) async {
      var mapPanned = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onPanStart: (_) => mapPanned = true,
                    child: const ColoredBox(color: Color(0xFF00FF00)),
                  ),
                ),
                // No onDismiss wired.
                const Positioned.fill(child: DimOverlay(opacity: 0.5)),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tapAt(tester.getCenter(find.byType(Scaffold)));
      await tester.pump();
      await tester.dragFrom(
        tester.getCenter(find.byType(Scaffold)),
        const Offset(0, 40),
      );
      await tester.pumpAndSettle();

      // Pass-through is independent of the callback, and neither the tap nor
      // the drag may throw when onDismiss is null.
      expect(mapPanned, isTrue);
      expect(tester.takeException(), isNull);
    });
  });

  group('DimOverlay — structure', () {
    Future<void> pumpBare(WidgetTester tester, double opacity) {
      return tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: DimOverlay(opacity: opacity, onDismiss: () {})),
        ),
      );
    }

    testWidgets('builds no pointer target at the collapsed rest state', (
      tester,
    ) async {
      await pumpBare(tester, 0);
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: find.byType(DimOverlay),
          matching: find.byType(GestureDetector),
        ),
        findsNothing,
      );
    });

    testWidgets('builds no pointer target for a sub-perceptual residual', (
      tester,
    ) async {
      await pumpBare(tester, 0.01);
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: find.byType(DimOverlay),
          matching: find.byType(GestureDetector),
        ),
        findsNothing,
      );
    });

    testWidgets('builds the tap-catcher once the scrim is visible', (
      tester,
    ) async {
      await pumpBare(tester, 0.5);
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: find.byType(DimOverlay),
          matching: find.byType(GestureDetector),
        ),
        findsOneWidget,
      );
    });
  });
}
