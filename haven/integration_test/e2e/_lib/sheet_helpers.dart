/// Deterministic helpers for interacting with the circles bottom
/// sheet from integration tests.
///
/// The production sheet (`circles_bottom_sheet.dart::CirclesBottomSheet`)
/// uses a custom velocity-aware physics pipeline (`_onPointerDown` +
/// `_runSnap`) layered on top of Flutter's [DraggableScrollableSheet].
/// The pipeline reads release velocity to drive a spring-based snap,
/// replacing the SDK's purely linear `_SnappingSimulation`.
///
/// `tester.dragFrom` synthesises a fixed pointer-event timeline at
/// the test clock and the custom velocity tracker is sensitive to
/// the timing of those events. On slower CI emulators the synthetic
/// drag does not always trigger an expansion — the sheet snaps back
/// to its starting position on release, the target CTA stays below
/// the viewport, and downstream `tester.tap` lands off-screen. A
/// retry loop around `dragFrom` does not help because every attempt
/// hits the same physics-pipeline behaviour.
///
/// [expandCirclesSheetToMax] bypasses the synthetic-gesture path
/// entirely. It looks up the sheet's [CirclesBottomSheetState] via
/// [WidgetTester.state] and drives the internal
/// [DraggableScrollableController.animateTo] directly. This is the
/// same code path the user's drag-release-snap would arrive at; the
/// only difference is that the test issues the snap declaratively
/// rather than coaxing the velocity tracker into producing it. The
/// production widget API is unchanged.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/widgets/circles/circles_bottom_sheet.dart';

/// Drives the [CirclesBottomSheet] to its maximum snap point and
/// optionally waits for [targetFinder] to land fully on-screen.
///
/// Implementation:
///   1. Pumps once to ensure the sheet's [DraggableScrollableController]
///      has been attached to the widget tree.
///   2. Calls `controller.animateTo(kCirclesBottomSheetMaxSizeForTesting)`
///      with an explicit timeout so a hung animation framework
///      surfaces a clear `StateError` instead of letting the
///      outer test timer fire much later with no diagnostic.
///   3. Pumps a bounded handful of frames to flush post-animation
///      layout listeners. We deliberately avoid
///      `tester.pumpAndSettle` here: MapShell installs several
///      `Timer.periodic` instances (`_receiveTimer` every 30 s,
///      `_evolutionTimer` every 1 min, `_foregroundHeartbeatTimer`
///      every `kBackgroundRepeatInterval`) that continuously
///      schedule frames in `LiveTestWidgetsFlutterBinding`. Under
///      those conditions `pumpAndSettle` never observes an empty
///      frame queue and waits until its internal 10-minute
///      timeout, deadlocking the surrounding test long after the
///      sheet animation has actually completed.
///   4. If [targetFinder] is provided, verifies the target widget is
///      laid out within the viewport bounds. A `StateError` is
///      thrown if it isn't — that would indicate a layout regression
///      independent of the sheet's snap position (e.g., the CTA was
///      removed from the empty-state widget).
Future<void> expandCirclesSheetToMax(
  WidgetTester tester, {
  Finder? targetFinder,
  Duration animationDuration = const Duration(milliseconds: 300),
  Curve animationCurve = Curves.easeInOut,
}) async {
  debugPrint('[expandCirclesSheetToMax] entered');

  // Ensure the sheet has laid out at least once so the
  // DraggableScrollableController is attached. In integration tests
  // this is normally true before any user-facing interaction, but a
  // freshly-pumped widget tree can arrive here with the controller
  // still detached; pump one frame defensively.
  if (find.byType(CirclesBottomSheet).evaluate().isEmpty) {
    await tester.pump();
  }

  expect(
    find.byType(CirclesBottomSheet),
    findsOneWidget,
    reason:
        'expandCirclesSheetToMax expects exactly one CirclesBottomSheet '
        'in the widget tree. Make sure the test has pumped the HavenApp '
        'and that AppRouter routed to MapShell.',
  );

  final state = tester.state<CirclesBottomSheetState>(
    find.byType(CirclesBottomSheet),
  );
  final controller = state.controllerForTesting;

  // The controller is attached after the sheet's first build. If it
  // somehow isn't yet, pumping one more frame is sufficient — the
  // `DraggableScrollableSheet` builder attaches on every build.
  if (!controller.isAttached) {
    await tester.pump();
  }
  expect(
    controller.isAttached,
    isTrue,
    reason:
        "expandCirclesSheetToMax: the sheet's "
        'DraggableScrollableController did not attach after pumping. '
        'This usually means the sheet was rendered behind another '
        'route or removed from the tree.',
  );

  debugPrint(
    '[expandCirclesSheetToMax] controller attached, size=${controller.size}',
  );

  // Wrap `animateTo` in a generous timeout. In LiveTest mode the
  // engine pumps frames at vsync and the animation ticker should
  // advance in real time. 1 s of slack past the nominal duration
  // covers cold-emulator jitter. If the future never resolves we
  // surface a clear, diagnosable error rather than letting the
  // outer test timer fire much later with no hint of what stalled.
  try {
    await controller
        .animateTo(
          kCirclesBottomSheetMaxSizeForTesting,
          duration: animationDuration,
          curve: animationCurve,
        )
        .timeout(animationDuration + const Duration(seconds: 1));
  } on TimeoutException {
    throw StateError(
      'expandCirclesSheetToMax: '
      'DraggableScrollableController.animateTo did not complete in '
      '${(animationDuration + const Duration(seconds: 1)).inMilliseconds} '
      'ms. The animation framework is not advancing the controller '
      'in this test environment — check whether the binding is '
      'LiveTestWidgetsFlutterBinding and that no widget is calling '
      '`setState` in a build-time loop that prevents the ticker from '
      'running.',
    );
  }

  debugPrint(
    '[expandCirclesSheetToMax] animateTo completed, size=${controller.size}',
  );

  // Flush post-animation rebuilds with a bounded pump sequence.
  // Three short pumps cover the typical layout-listener cascade
  // (size listener → bottom-sheet builder rebuild → child slivers'
  // layout) without depending on the global frame queue ever
  // draining (see header comment about MapShell's periodic timers).
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 100));

  debugPrint('[expandCirclesSheetToMax] post-animation pumps complete');

  if (targetFinder == null) return;

  // Layout-fact verification: the target widget should now be within
  // the viewport bounds. This catches the case where the sheet IS
  // expanded but the target's render box still falls outside the
  // visible region (e.g., a Sliver layout change that pushed the
  // CTA below the sheet's clip). A failure here is meaningful and
  // distinct from the synthetic-drag flake the helper exists to
  // prevent — it names what *layout* fact broke.
  final matches = targetFinder.evaluate();
  if (matches.isEmpty) {
    throw StateError(
      'expandCirclesSheetToMax: target $targetFinder did not appear '
      'in the widget tree after the sheet expanded. Either the sheet '
      'is showing a different content branch than the test expects '
      '(e.g., a non-empty state when the empty-state CTA was the '
      'target) or the widget key was renamed.',
    );
  }
  final targetRect = tester.getRect(targetFinder.first);
  final screenSize = tester.view.physicalSize / tester.view.devicePixelRatio;
  final fitsHorizontally =
      targetRect.left >= 0 && targetRect.right <= screenSize.width;
  final fitsVertically =
      targetRect.top >= 0 && targetRect.bottom < screenSize.height;
  if (!fitsHorizontally || !fitsVertically) {
    throw StateError(
      'expandCirclesSheetToMax: target $targetFinder was found but '
      'lies outside the viewport. targetRect=$targetRect, '
      'screenSize=$screenSize. The sheet expanded as requested, so '
      'this is a layout regression in the sheet content — not a '
      'gesture-recognition issue.',
    );
  }
}
