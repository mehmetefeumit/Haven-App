/// Scenario failure-state dumper.
///
/// Call from a scenario's `catch` block before re-throwing to flush
/// observable state into `debugPrint`. The output lands in the
/// per-device logcat artifact (CI captures the entire logcat stream)
/// so on-call developers don't need to re-run the scenario locally to
/// see what state the test was in at the moment of failure.
///
/// Usage:
///
/// ```dart
/// try {
///   // ... scenario body ...
/// } on Object catch (e, st) {
///   await dumpScenarioState(
///     tester: tester,
///     ctx: ctx,
///     label: 'pre-rethrow',
///   );
///   rethrow;
/// }
/// ```
///
/// The dumper is deliberately defensive: every read is wrapped in its
/// own try/catch so a partial state failure doesn't mask the original
/// exception. The output is structured (one line per fact, all prefixed
/// `[diagnostics:<label>]`) so it's easy to grep out of a 50-MB logcat.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/main.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/location_sharing_provider.dart';

import 'scenario_harness.dart';

/// Prints a structured snapshot of test-observable state to
/// `debugPrint`. Safe to call from any `catch` block; never throws.
Future<void> dumpScenarioState({
  required WidgetTester tester,
  required ScenarioContext ctx,
  String label = 'failure',
}) async {
  final prefix = '[diagnostics:$label]';

  void log(String fact) {
    debugPrint('$prefix $fact');
  }

  log('=== begin ===');
  log('role=${ctx.role.name}');
  log('relay=${ctx.relay.url}');

  // ProviderContainer access — guarded because HavenApp may not be
  // mounted (e.g., failure happened during pumpWidget itself).
  try {
    final element = tester.element(find.byType(HavenApp));
    final container = ProviderScope.containerOf(element, listen: false);

    // Circles snapshot.
    try {
      final circles = await container.read(circlesProvider.future);
      log('circles.count=${circles.length}');
      for (final circle in circles) {
        log(
          'circle name="${circle.displayName}" '
          'membership=${circle.membershipStatus.name} '
          'members=${circle.members.length}',
        );
      }
    } on Object catch (e) {
      log('circles.read=ERROR ${e.runtimeType}');
    }

    // Selected circle's member locations.
    try {
      final memberLocations = await container.read(
        memberLocationsProvider.future,
      );
      log('memberLocations.count=${memberLocations.length}');
      for (final loc in memberLocations) {
        log('memberLocation pubkey=${loc.pubkey} ts=${loc.timestamp}');
      }
    } on Object catch (e) {
      log('memberLocations.read=ERROR ${e.runtimeType}');
    }
  } on Object catch (e) {
    log(
      'container.access=ERROR ${e.runtimeType} '
      '(HavenApp likely not mounted)',
    );
  }

  // Top-level widget summary — captures what's actually on screen at
  // failure time, in case the assertion was about a missing/present
  // widget. Avoid dumping the full tree (huge); just count common
  // top-level pages.
  for (final widgetName in const <String>[
    'WelcomeScreen',
    'ValuePropsScreen',
    'CreateIdentityScreen',
    'DisplayNameScreen',
    'ReadyScreen',
    'MapShell',
    'CreateCirclePage',
    'NameCirclePage',
    'InvitationsPage',
  ]) {
    try {
      final count = find
          .byWidgetPredicate((w) => w.runtimeType.toString() == widgetName)
          .evaluate()
          .length;
      if (count > 0) {
        log('onScreen $widgetName=$count');
      }
    } on Object {
      // ignore — finder failure is non-fatal
    }
  }

  log('=== end ===');
}
