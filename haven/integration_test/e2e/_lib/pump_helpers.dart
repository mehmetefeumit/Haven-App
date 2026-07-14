/// Frame-pump helpers that survive ambient periodic timers.
///
/// Haven's `MapShell` installs several `Timer.periodic` instances on
/// mount — the evolution poller (60 s), the location-receive timer
/// (30 s), and a foreground heartbeat. Under
/// `IntegrationTestWidgetsFlutterBinding` these timers keep the
/// scheduler's frame queue perpetually non-empty, so
/// `tester.pumpAndSettle()` (which waits for the queue to drain for
/// one cycle) never converges and ultimately hangs until its 10-minute
/// internal timeout — by which point the outer test budget has
/// already elapsed.
///
/// The helpers here pump *individual frames* and inspect the widget
/// tree between pumps, terminating as soon as a target condition
/// holds. They never wait for "the queue to drain"; they wait for a
/// specific observable state. That makes them the right primitive
/// after any UI action that triggers a route change, an FFI call, or
/// a provider invalidation cascade — i.e. the exact situations where
/// `pumpAndSettle` is known to hang in our two-AVD scenarios.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pumps frames at [pumpInterval] until [finder] matches at least one
/// element, or [timeout] elapses.
///
/// Use this instead of `pumpAndSettle()` after any UI action that
/// transitions to a screen with ambient providers/timers, e.g.:
///
/// ```dart
/// await tester.tap(find.byKey(WidgetKeys.invitationsFloatingButton));
/// await pumpUntilFound(tester, find.byType(InvitationsPage));
/// ```
///
/// Throws a [StateError] with a diagnostic naming [finder] and the
/// timeout budget on miss — that surfaces the wait failure cleanly
/// instead of letting the outer test timer fire much later with no
/// hint of what stalled.
Future<void> pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 30),
  Duration pumpInterval = const Duration(milliseconds: 100),
  String? description,
  bool Function()? shouldAbort,
}) async {
  final label = description ?? '$finder';
  final deadline = DateTime.now().add(timeout);
  var pumps = 0;
  while (DateTime.now().isBefore(deadline)) {
    // Checked BEFORE `tester.pump`, with no intervening await, so a caller
    // whose own bound already elapsed (e.g. a per-scenario generation token)
    // can never issue another guarded WidgetTester call from this loop — the
    // fix for a timed-out caller's leftover polling loop colliding with a
    // LATER caller's own guarded calls ("Guarded function conflict").
    // Optional and generic/M11-agnostic: unset for every non-M11 caller, so
    // this is a no-op change for them.
    if (shouldAbort != null && shouldAbort()) {
      throw StateError(
        'pumpUntilFound: aborted waiting for $label — shouldAbort() '
        'returned true (the caller is no longer current).',
      );
    }
    await tester.pump(pumpInterval);
    pumps += 1;
    if (finder.evaluate().isNotEmpty) return;
  }
  throw StateError(
    'pumpUntilFound: $label did not appear within '
    '${timeout.inSeconds}s ($pumps pumps at ${pumpInterval.inMilliseconds}ms). '
    'If the widget should be visible, the page may not have mounted; '
    'if it should not, the test expectation is inverted.',
  );
}

/// Pumps frames at [pumpInterval] until [finder] matches **zero**
/// elements, or [timeout] elapses.
///
/// The companion to [pumpUntilFound] — useful when waiting for a
/// loading spinner, a dialog, or a transient widget to go away after
/// an action settles.
Future<void> pumpUntilGone(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 30),
  Duration pumpInterval = const Duration(milliseconds: 100),
  String? description,
  bool Function()? shouldAbort,
}) async {
  final label = description ?? '$finder';
  final deadline = DateTime.now().add(timeout);
  var pumps = 0;
  while (DateTime.now().isBefore(deadline)) {
    // See pumpUntilFound's identical guard above for why this is checked
    // before `tester.pump` with no intervening await.
    if (shouldAbort != null && shouldAbort()) {
      throw StateError(
        'pumpUntilGone: aborted waiting for $label — shouldAbort() '
        'returned true (the caller is no longer current).',
      );
    }
    await tester.pump(pumpInterval);
    pumps += 1;
    if (finder.evaluate().isEmpty) return;
  }
  throw StateError(
    'pumpUntilGone: $label was still present after '
    '${timeout.inSeconds}s ($pumps pumps at ${pumpInterval.inMilliseconds}ms). '
    'The action that should have removed it from the tree may not '
    'have fired or its side effect may not have propagated.',
  );
}

/// Scrolls [finder] into view (when it lives in a scrollable) and taps it once
/// it is genuinely HIT-TESTABLE, pumping frames until a hit test at the
/// widget's centre reaches its render object (or [timeout] elapses).
///
/// Plain `tester.tap` computes a widget's centre and dispatches a pointer
/// there immediately, with no regard for whether the centre is actually
/// on-screen and reachable. Two iOS-specific situations break that on Haven's
/// `e2e_combined` flow while the Android lane stays green:
///
///  1. **Below the fold / behind the keyboard.** Pages like `NameCirclePage`
///     anchor their primary button to the bottom (after a `Spacer`) inside a
///     `SingleChildScrollView`, and autofocus a text field — which pops the
///     iOS soft keyboard on entry. The keyboard shrinks the Scaffold body, so
///     the button's logical centre lands off-screen / behind the keyboard and
///     a tap there misses. [tester.ensureVisible] scrolls it back into the
///     (keyboard-resized) viewport.
///  2. **Mid-transition pointer barrier.** A freshly pushed route is wrapped
///     in an `AbsorbPointer`/`IgnorePointer` while it animates; an immediate
///     tap after [pumpUntilFound] (which returns the instant a page *mounts*)
///     is swallowed. Waiting for hittability rides out the transition.
///
/// This makes cross-platform UI interaction deterministic WITHOUT
/// `pumpAndSettle` (which hangs on Haven's ambient periodic timers — see the
/// library doc above). A widget that is already on-screen and hittable is
/// tapped on the first iteration, so this is a safe drop-in for `tester.tap`.
Future<void> tapWhenHittable(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 30),
  Duration pumpInterval = const Duration(milliseconds: 100),
  String? description,
}) async {
  final label = description ?? '$finder';
  final deadline = DateTime.now().add(timeout);
  var pumps = 0;
  while (DateTime.now().isBefore(deadline)) {
    if (finder.evaluate().length == 1) {
      // Best-effort scroll-into-view. Re-attempted each iteration because the
      // autofocus keyboard can reflow the layout a frame or two AFTER the page
      // mounts, pushing a just-scrolled button back down. A no-op when the
      // target is already visible; throws when there is no Scrollable ancestor
      // (the target simply isn't scrollable) — which we tolerate.
      try {
        await tester.ensureVisible(finder);
      } on Object {
        // No Scrollable ancestor / not yet resolvable — fall through to the
        // hittability check and pump.
      }
      if (_isHittable(tester, finder)) {
        await tester.tap(finder);
        return;
      }
    }
    await tester.pump(pumpInterval);
    pumps += 1;
  }
  throw StateError(
    'tapWhenHittable: $label did not become hit-testable within '
    '${timeout.inSeconds}s ($pumps pumps at ${pumpInterval.inMilliseconds}ms). '
    'The widget may be below the fold / behind the keyboard with no scrollable '
    'to reveal it, offstage, obscured, or behind an ancestor pointer barrier '
    'that never lifted.',
  );
}

/// Whether a hit test at [finder]'s centre reaches its render object — i.e.
/// the widget resolves to exactly one attached [RenderBox], is laid out
/// on-screen, and is not behind an absorbing/ignoring/offstage ancestor (as
/// installed transiently while a route animates). Returns `false` (keep
/// waiting) for anything that is not yet cleanly tappable.
bool _isHittable(WidgetTester tester, Finder finder) {
  final elements = finder.evaluate();
  if (elements.length != 1) return false;
  final renderObject = elements.single.renderObject;
  if (renderObject is! RenderBox || !renderObject.attached) return false;
  final Offset centre;
  try {
    centre = tester.getCenter(finder);
  } on Object {
    return false;
  }
  final result = tester.hitTestOnBinding(centre);
  for (final entry in result.path) {
    if (identical(entry.target, renderObject)) return true;
  }
  return false;
}

/// Pumps frames at [pumpInterval] until [condition] returns `true`,
/// or [timeout] elapses.
///
/// Use when the success criterion is not a Finder match — e.g.
/// "an FFI provider has returned a value", "the page state's loading
/// flag has flipped", or "two specific finders are *both* present".
Future<void> pumpUntilCondition(
  WidgetTester tester,
  bool Function() condition, {
  required String description,
  Duration timeout = const Duration(seconds: 30),
  Duration pumpInterval = const Duration(milliseconds: 100),
  bool Function()? shouldAbort,
}) async {
  final deadline = DateTime.now().add(timeout);
  var pumps = 0;
  while (DateTime.now().isBefore(deadline)) {
    // See pumpUntilFound's identical guard above for why this is checked
    // before `tester.pump` with no intervening await.
    if (shouldAbort != null && shouldAbort()) {
      throw StateError(
        'pumpUntilCondition: aborted waiting for "$description" — '
        'shouldAbort() returned true (the caller is no longer current).',
      );
    }
    await tester.pump(pumpInterval);
    pumps += 1;
    if (condition()) return;
  }
  throw StateError(
    'pumpUntilCondition: "$description" was not satisfied within '
    '${timeout.inSeconds}s ($pumps pumps at ${pumpInterval.inMilliseconds}ms).',
  );
}
