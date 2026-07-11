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
/// Animation-driven approaches (`controller.animateTo` even when
/// wrapped in `tester.runAsync`) are likewise unreliable here:
/// `IntegrationTestWidgetsFlutterBinding` inherits
/// `LiveTestWidgetsFlutterBindingFramePolicy.fadePointers` from its
/// parent binding, which only schedules frame callbacks on pointer
/// events or explicit `pump()` calls. `runAsync` makes `Future`/`Timer`
/// work in real time but does **not** change frame policy, so any
/// animation `Ticker` registers for vsync that never fires while the
/// test is awaiting — the await deadlocks until the outer timeout.
///
/// [expandCirclesSheetToMax] sidesteps every quirk above. It looks up
/// the sheet's [CirclesBottomSheetState] via [WidgetTester.state],
/// grabs the internal [DraggableScrollableController], and calls
/// [DraggableScrollableController.jumpTo] — the synchronous,
/// non-animated cousin of `animateTo`. The controller's internal
/// `_currentSize` `ValueNotifier` updates in the same frame, the
/// sheet rebuilds at max size on the next pump, and the target
/// finder is then guaranteed to be laid out within the viewport.
///
/// Tests assert on the *final state* (target widget is in the
/// viewport and tappable), not on the visual transition, so the
/// production widget's user-facing animation behaviour is unchanged.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/widgets/circles/circles_bottom_sheet.dart';

/// Drives the [CirclesBottomSheet] to its maximum snap point and
/// optionally waits for [targetFinder] to land fully on-screen.
///
/// Implementation:
///   1. Verifies exactly one [CirclesBottomSheet] is in the widget
///      tree and pumps once defensively if its
///      [DraggableScrollableController] has not yet attached.
///   2. Calls `controller.jumpTo(kCirclesBottomSheetMaxSizeForTesting)`.
///      Synchronous — no animation, no ticker, no frame-policy
///      dependency. The controller dispatches a
///      `DraggableScrollableNotification` and the sheet's internal
///      `_currentSize` notifier updates immediately.
///   3. Pumps a bounded handful of frames to flush post-update layout
///      listeners. We deliberately avoid `tester.pumpAndSettle`
///      here: MapShell installs several `Timer.periodic` instances
///      (`_receiveTimer` every 30 s, `_evolutionTimer` every 1 min,
///      `_foregroundHeartbeatTimer` every `kBackgroundRepeatInterval`)
///      that continuously schedule frames in
///      `IntegrationTestWidgetsFlutterBinding`. Under those
///      conditions `pumpAndSettle` never observes an empty frame
///      queue and waits until its internal 10-minute timeout,
///      deadlocking the surrounding test long after the sheet has
///      actually settled at max size.
///   4. If [targetFinder] is provided, verifies the target widget is
///      laid out within the viewport bounds. A `StateError` is
///      thrown if it isn't — that would indicate a layout regression
///      independent of the sheet's snap position (e.g., the CTA was
///      removed from the empty-state widget).
Future<void> expandCirclesSheetToMax(
  WidgetTester tester, {
  Finder? targetFinder,
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

  // Synchronous jump — see library doc comment for why animateTo is
  // unreliable in IntegrationTestWidgetsFlutterBinding.
  controller.jumpTo(kCirclesBottomSheetMaxSizeForTesting);

  debugPrint(
    '[expandCirclesSheetToMax] jumpTo dispatched, size=${controller.size}',
  );

  // Flush the post-jump rebuild with a bounded pump sequence. Three
  // short pumps cover the typical layout-listener cascade
  // (size-notifier listener → bottom-sheet builder rebuild → child
  // slivers' layout) without depending on the global frame queue
  // ever draining (see the header comment about MapShell's periodic
  // timers).
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 100));

  debugPrint('[expandCirclesSheetToMax] post-jump pumps complete');

  if (targetFinder == null) return;

  // Bounded wait for the target's content branch to settle. Under
  // `liveSyncEnabled`, `MapShell.initState` concurrently starts the live-sync
  // engine (a real relay connect/subscribe handshake) in the same window this
  // helper runs, so on a CPU-constrained CI runner `circlesProvider`'s
  // one-time AsyncLoading → AsyncData transition (which renders the empty-state
  // CTA) can land AFTER the three fixed post-jump pumps above. That is a
  // legitimate async-settle race, not a synthetic-gesture or layout issue, so
  // wait for the observable widget the way `pumpUntilFound` does (bounded,
  // single-frame pumps — never `pumpAndSettle`, which MapShell's periodic
  // timers would hang) rather than trusting a fixed frame budget. A genuine
  // absence still fails below with the same StateError after the deadline.
  final targetDeadline = DateTime.now().add(const Duration(seconds: 10));
  while (targetFinder.evaluate().isEmpty &&
      DateTime.now().isBefore(targetDeadline)) {
    await tester.pump(const Duration(milliseconds: 100));
  }

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
