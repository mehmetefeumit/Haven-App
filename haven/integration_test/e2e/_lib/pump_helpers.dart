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
}) async {
  final label = description ?? '$finder';
  final deadline = DateTime.now().add(timeout);
  var pumps = 0;
  while (DateTime.now().isBefore(deadline)) {
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
}) async {
  final label = description ?? '$finder';
  final deadline = DateTime.now().add(timeout);
  var pumps = 0;
  while (DateTime.now().isBefore(deadline)) {
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
}) async {
  final deadline = DateTime.now().add(timeout);
  var pumps = 0;
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(pumpInterval);
    pumps += 1;
    if (condition()) return;
  }
  throw StateError(
    'pumpUntilCondition: "$description" was not satisfied within '
    '${timeout.inSeconds}s ($pumps pumps at ${pumpInterval.inMilliseconds}ms).',
  );
}
