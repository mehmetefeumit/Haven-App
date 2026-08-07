// Static guards for the parts of the cross-circle `created_at` decorrelation
// that cannot be executed under `flutter test`.
//
// ## What is and is not pinned here
//
// The decorrelation PROPERTY — that two circles' `encryptLocation` calls land
// more than a whole second apart — is proved by execution, not by grep:
//
//   * foreground burst + chained scheduler ticks:
//     `test/providers/location_publish_decorrelation_test.dart` asserts on the
//     recorded wall-clock instants of the encrypt calls, with the production
//     `PublishStagger`;
//   * the background pacing rule and its seed:
//     `test/services/per_circle_due_tracker_test.dart` drives
//     `seedStaggered` and `nextBackgroundPublishSlot` directly, including the
//     slow-publish case;
//   * the stagger's own bounds: `test/services/publish_stagger_test.dart`.
//
// What CANNOT be executed is the background publish CYCLE that calls those
// pieces. `BackgroundLocationTaskHandler._publishCycle` drives
// `CircleManagerFfi` directly, so reaching it needs the Rust bridge and a live
// foreground service — `flutter test` cannot get there, which is why the
// disclosure gate in that same file is guarded the same way
// (`test/services/background_location_disclosure_gate_test.dart`).
//
// So this file pins WIRING only: that the cycle still routes through the
// decorrelating helpers instead of the shapes it used to have. It matches
// identifiers, never prose, so a comment rewrite cannot satisfy or break it.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String relativePath) {
  final file = File(relativePath);
  if (!file.existsSync()) {
    fail(
      'expected source file not found: $relativePath (has it moved? this test '
      'pins a privacy invariant to its call site)',
    );
  }
  return file.readAsStringSync();
}

/// Strips `//` line comments and `///` doc comments so an assertion can never
/// be satisfied — or broken — by a comment that merely mentions an identifier.
String _codeOnly(String source) => source
    .split('\n')
    .where((line) => !line.trimLeft().startsWith('//'))
    .join('\n');

void main() {
  group('background publish cycle wiring', () {
    late String code;

    setUp(() {
      code = _codeOnly(_read('lib/src/services/background_location_task.dart'));
    });

    test('seeds per-circle schedules through the STAGGERED seed', () {
      // `pruneToKeys({})` empties the tracker on every cycle the foreground
      // owns publishing, so this seed re-runs on every foreground→background
      // handoff. Seeding the whole roster at one instant is what made every
      // handoff publish all circles inside one second.
      expect(
        code,
        contains('seedStaggered('),
        reason: 'the background cycle no longer uses the staggered seed',
      );
    });

    test('does not seed every circle at the cycle timestamp', () {
      expect(
        code,
        isNot(contains('seedIfAbsent(key, timestamp)')),
        reason: 'this is the exact pre-fix shape: one shared due-time for the '
            'whole roster, re-applied on every handoff',
      );
    });

    test('paces each publish through the running-gap slot rule', () {
      expect(
        code,
        contains('nextBackgroundPublishSlot('),
        reason: 'without this the cycle publishes its due circles back to '
            'back; the 72 s poll routinely selects several at once, so the '
            'per-circle tracker alone cannot space them',
      );
    });

    test('the decorrelation wait is the cancellable one', () {
      expect(code, contains('_sleepUnlessShuttingDown('));
      expect(
        code,
        isNot(contains('await Future<void>.delayed(wait)')),
        reason: 'an uncancellable wait would spend the service-stop window '
            'sleeping between circles',
      );
    });

    test('shutdown is signalled BEFORE onDestroy awaits the in-flight cycle',
        () {
      final signal = code.indexOf('_shutdownSignal.complete()');
      final awaitInFlight = code.indexOf('await _inFlightPublish');
      expect(signal, isNot(-1));
      expect(awaitInFlight, isNot(-1));
      expect(
        signal,
        lessThan(awaitInFlight),
        reason: 'signalling after the await releases nothing — the await is '
            'what the wait is blocking',
      );
    });
  });

  group('foreground pause cancels an in-flight burst', () {
    // `MapShell` cannot be widget-tested without the Rust bridge (CLAUDE.md),
    // which is why its `detached` handling is pinned the same way in
    // `test/pages/map_shell_detached_release_test.dart`. The BEHAVIOUR of the
    // guard being tripped — a disposed burst stops mid-flight — is executed in
    // `location_publish_decorrelation_test.dart`; what is pinned here is only
    // that pause actually trips it.
    late String pausedBody;

    setUpAll(() {
      final source = _read('lib/src/pages/map_shell.dart');
      final start = source.indexOf('Future<void> _onPaused() async {');
      expect(
        start,
        isNonNegative,
        reason: '_onPaused must exist; if it was renamed, update this guard '
            'rather than deleting it',
      );
      // Bounded by the next member, so the assertion below cannot be satisfied
      // by an invalidate somewhere else in a 1500-line file.
      final end = source.indexOf('\n  /// ', start);
      expect(end, greaterThan(start));
      pausedBody = source.substring(start, end);
    });

    test('pause invalidates the burst publisher', () {
      expect(
        pausedBody,
        contains('invalidate(locationPublisherProvider)'),
        reason: 'a paced burst runs for tens of seconds, so without this it '
            'keeps publishing after pause has already told the background '
            'isolate the foreground is finished',
      );
    });
  });

  group('stagger randomness source', () {
    test('the production stagger draws from a CSPRNG', () {
      // This is a privacy control: a predictable delay stream lets an observer
      // subtract the stagger and recover the co-timing it was added to hide.
      // `Random()` is seeded from a low-entropy source and is explicitly not
      // acceptable here.
      final code = _codeOnly(_read('lib/src/services/publish_stagger.dart'));
      expect(
        code,
        contains('rng ?? Random.secure()'),
        reason: 'the default randomness source is no longer a CSPRNG',
      );
    });
  });
}
