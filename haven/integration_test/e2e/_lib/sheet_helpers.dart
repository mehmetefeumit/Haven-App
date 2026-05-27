/// Robust helpers for interacting with the circles bottom sheet from
/// integration tests.
///
/// The production sheet (`circles_bottom_sheet.dart::CirclesBottomSheet`)
/// uses a custom velocity-aware physics pipeline (`_onPointerDown` +
/// `_runSnap`) layered on top of Flutter's [DraggableScrollableSheet].
/// The pipeline reads release velocity to drive a spring-based snap,
/// replacing the SDK's purely linear `_SnappingSimulation`.
///
/// `tester.dragFrom` synthesises a fixed pointer-event timeline at the
/// test clock, and the custom velocity tracker doesn't always react
/// cleanly to that. We've seen intermittent flakes where the sheet
/// stays at the 12% snap and the target CTA renders below the
/// viewport, even though the drag visually appears correct in
/// snapshot tools. The result is a `tester.tap(circlesCreateCta)` at
/// an off-screen offset, a "would not hit test" warning, and a
/// downstream `find.byType(CreateCirclePage)` failure.
///
/// [expandCirclesSheetToMax] makes the interaction deterministic: it
/// drags, settles, then verifies the target widget is fully on-screen
/// before returning. If the first drag didn't take, it pumps and
/// drags again, up to `maxAttempts`. Each retry costs roughly one
/// drag duration + one settle, which is small compared to the test
/// budgets. The helper raises [StateError] on persistent failure so
/// the diagnostic message points at *what* failed (the sheet never
/// reached a state where the CTA was tappable) rather than the
/// downstream symptom (the navigation didn't happen).
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Drags the circles bottom sheet upward until [targetFinder] resolves
/// to a widget that is fully visible inside the viewport.
///
/// The helper assumes:
///   - There is exactly one [DraggableScrollableSheet] in the tree.
///   - The target widget lives inside that sheet and becomes laid
///     out once the sheet expands past roughly the 50% snap point.
///
/// Each iteration drags from the sheet's center upward by
/// [dragDistance] logical pixels, pumps until idle, then checks
/// whether the target is on-screen. Up to [maxAttempts] iterations
/// are tried. A persistent failure throws [StateError] with the
/// observed positions so CI failure logs explain *what* didn't
/// happen — the production code did not respond to the synthetic
/// drag, not "the test couldn't find a widget" downstream.
///
/// Pass a `find.byKey(...)` finder when the target has a widget key
/// (e.g. `WidgetKeys.circlesCreateCta`), or a `find.textContaining(...)`
/// when verifying that a circle name appears in the list. Either way
/// the helper expects the finder to match at most one widget; if
/// multiple widgets share the finder, the first is used.
Future<void> expandCirclesSheetToMax(
  WidgetTester tester, {
  required Finder targetFinder,
  double dragDistance = 600,
  int maxAttempts = 4,
}) async {
  final sheetFinder = find.byType(DraggableScrollableSheet);
  expect(
    sheetFinder,
    findsOneWidget,
    reason:
        'expandCirclesSheetToMax expects exactly one '
        'DraggableScrollableSheet in the tree.',
  );

  Rect? lastObservedTargetRect;
  Size? lastObservedScreenSize;

  for (var attempt = 1; attempt <= maxAttempts; attempt++) {
    // The dragFrom origin is recomputed every iteration: as the sheet
    // expands, its render-box center moves, and using a stale
    // coordinate would re-drag from where the sheet *used to be*.
    await tester.dragFrom(
      tester.getCenter(sheetFinder),
      Offset(0, -dragDistance),
    );
    await tester.pumpAndSettle();

    final matches = targetFinder.evaluate();
    if (matches.isNotEmpty) {
      final targetRect = tester.getRect(targetFinder.first);
      final screenSize =
          tester.view.physicalSize / tester.view.devicePixelRatio;
      lastObservedTargetRect = targetRect;
      lastObservedScreenSize = screenSize;

      // "Fully on-screen" = the entire target rect lies within the
      // viewport. We use `<` (not `<=`) on the bottom edge because a
      // widget whose bottom edge is exactly at the screen edge is
      // not safely tappable in CI emulators (partial occlusion has
      // produced intermittent hit-test failures in practice).
      final fitsHorizontally =
          targetRect.left >= 0 && targetRect.right <= screenSize.width;
      final fitsVertically =
          targetRect.top >= 0 && targetRect.bottom < screenSize.height;
      if (fitsHorizontally && fitsVertically) {
        return;
      }
    }
  }

  throw StateError(
    'expandCirclesSheetToMax: bottom sheet failed to expand far '
    'enough to bring $targetFinder on-screen after $maxAttempts '
    'attempts. Last observed: '
    'targetRect=$lastObservedTargetRect, '
    'screenSize=$lastObservedScreenSize. The custom velocity-aware '
    'physics pipeline likely did not pick up the synthetic drag — '
    'check `circles_bottom_sheet.dart::_onPointerDown` for changes '
    'that would affect test-driver gesture recognition.',
  );
}
