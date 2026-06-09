/// Tests for [DimOverlay].
///
/// Regression coverage for the "map frozen until I touch the panel" bug:
/// the dim overlay sits `Positioned.fill` directly above the map in
/// `MapShell`. It must only install its full-screen
/// `HitTestBehavior.opaque` tap-catcher (used to collapse the sheet) when
/// it is actually visible. If it stays opaque at a sub-perceptual opacity
/// — which the bottom sheet's drag-release velocity spring can leave behind
/// as a stranded residual — it silently swallows every gesture meant for
/// the map (pan, pinch-zoom), and the map appears frozen until an unrelated
/// widget interaction resets the opacity to 0.
///
/// A tap is used as the probe: hit-testing routes every pointer gesture
/// through the same path, so "the map below receives the tap" is equivalent
/// to "the map is interactive" for pan/zoom alike.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/widgets/common/dim_overlay.dart';

void main() {
  /// Builds the `MapShell`-shaped stack: a full-screen tap target standing
  /// in for the map, with a [DimOverlay] layered on top of it. Returns the
  /// two tap-latches so a test can assert which layer received the pointer.
  Future<({ValueGetter<bool> mapTapped, ValueGetter<bool> overlayTapped})>
  pumpOverlayOverMap(WidgetTester tester, {required double opacity}) async {
    var mapTapped = false;
    var overlayTapped = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              // Stand-in for MapPage: an opaque, full-screen tap target.
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => mapTapped = true,
                  child: const ColoredBox(color: Color(0xFF00FF00)),
                ),
              ),
              Positioned.fill(
                child: DimOverlay(
                  opacity: opacity,
                  onTap: () => overlayTapped = true,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    return (mapTapped: () => mapTapped, overlayTapped: () => overlayTapped);
  }

  group('DimOverlay — pointer routing', () {
    // The velocity-spring snap-to-collapsed and the programmatic collapse
    // can each strand the expansion a hair above 0 (worst case ~0.014). At
    // every value in this band the scrim is imperceptible, so the overlay
    // must let pointers fall through to the map beneath it.
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
            latches.overlayTapped(),
            isFalse,
            reason: 'an imperceptible DimOverlay must not intercept gestures',
          );
        },
      );
    }

    // Guards against an over-correction that disables the dim entirely:
    // once the scrim is actually visible it MUST keep absorbing taps so
    // tapping the dimmed map collapses the sheet.
    for (final visible in <double>[0.05, 0.3, 1]) {
      testWidgets(
        'intercepts taps to collapse the sheet when visibly dimmed ($visible)',
        (tester) async {
          final latches = await pumpOverlayOverMap(tester, opacity: visible);

          await tester.tapAt(tester.getCenter(find.byType(Scaffold)));
          await tester.pump();

          expect(
            latches.overlayTapped(),
            isTrue,
            reason: 'a visible DimOverlay must catch the tap (tap-to-collapse)',
          );
          expect(
            latches.mapTapped(),
            isFalse,
            reason: 'a visible DimOverlay must shield the map from the tap',
          );
        },
      );
    }
  });

  group('DimOverlay — structure', () {
    Future<void> pumpBare(WidgetTester tester, double opacity) {
      return tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: DimOverlay(opacity: opacity, onTap: () {})),
        ),
      );
    }

    testWidgets('builds no opaque hit target at the collapsed rest state', (
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

    testWidgets('builds no opaque hit target for a sub-perceptual residual', (
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

    testWidgets('builds the opaque tap-catcher once the scrim is visible', (
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
