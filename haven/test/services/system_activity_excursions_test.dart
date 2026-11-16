/// Pins `SystemActivityExcursions`: a pause during Haven's own photo picker or
/// crop editor holds the MLS session handoff for a bounded grace, anchored at
/// the trip's first pause, and every other pause hands over at once.
library;

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/constants/location.dart';
import 'package:haven/src/services/background_idle_waiter.dart';
import 'package:haven/src/services/mls_session_handover.dart';
import 'package:haven/src/services/system_activity_excursions.dart';

import '../helpers/log_capture.dart';

void main() {
  const tick = Duration(microseconds: 1);

  /// Opens a trip held open by [hold] — the picker or editor on screen.
  void openTrip(SystemActivityExcursions excursions, Completer<void> hold) {
    unawaited(excursions.run(() => hold.future));
  }

  test('an ordinary pause owes no grace', () {
    // Leaving the app hands the session over at once, as it always has.
    expect(SystemActivityExcursions().graceForPause(), isNull);
  });

  test('a pause during a trip is held exactly to the bound', () {
    fakeAsync((async) {
      final excursions = SystemActivityExcursions();
      openTrip(excursions, Completer<void>());
      var ended = false;
      unawaited(excursions.graceForPause()!.then((_) => ended = true));

      async.elapse(kSystemActivityHandoffGrace - tick);
      expect(ended, isFalse, reason: 'released before its bound');
      async.elapse(tick);
      expect(ended, isTrue, reason: 'held past its bound');
      expect(async.pendingTimers, isEmpty);
    });
  });

  test("a second pause keeps what is left of the first one's grace", () {
    // The opaque picker and the crop editor each pause Haven. Restarting the
    // grace at the second would hold publishing for twice the bound after the
    // foreground stopped at the first.
    fakeAsync((async) {
      final excursions = SystemActivityExcursions();
      openTrip(excursions, Completer<void>());
      var first = false;
      var second = false;
      unawaited(excursions.graceForPause()!.then((_) => first = true));
      async.elapse(const Duration(seconds: 15));
      unawaited(excursions.graceForPause()!.then((_) => second = true));

      async.elapse(const Duration(seconds: 5) - tick);
      expect(second, isFalse);
      async.elapse(tick);
      expect(
        [first, second],
        [true, true],
        reason: "both pauses end where the first one's bound did",
      );
    });
  });

  test('a pause after the grace ran out, with no resume between, hands over '
      'at once', () {
    fakeAsync((async) {
      final excursions = SystemActivityExcursions();
      openTrip(excursions, Completer<void>());
      unawaited(excursions.graceForPause());
      async.elapse(kSystemActivityHandoffGrace);
      expect(excursions.graceForPause(), isNull);
      expect(async.pendingTimers, isEmpty);
    });
  });

  test('a resume starts the next stretch away with a whole grace', () {
    fakeAsync((async) {
      final excursions = SystemActivityExcursions();
      openTrip(excursions, Completer<void>());
      unawaited(excursions.graceForPause());
      async.elapse(kSystemActivityHandoffGrace);
      excursions.endGrace(HandoffGraceEnd.resumed);

      var ended = false;
      unawaited(excursions.graceForPause()!.then((_) => ended = true));
      async.elapse(kSystemActivityHandoffGrace - tick);
      expect(ended, isFalse);
      async.elapse(tick);
      expect(ended, isTrue);
    });
  });

  for (final cause in [
    HandoffGraceEnd.resumed,
    HandoffGraceEnd.detached,
    HandoffGraceEnd.disposed,
  ]) {
    test('ending the grace (${cause.name}) releases it at once and leaves no '
        'timer', () {
      fakeAsync((async) {
        final excursions = SystemActivityExcursions();
        openTrip(excursions, Completer<void>());
        var ended = false;
        unawaited(excursions.graceForPause()!.then((_) => ended = true));
        excursions.endGrace(cause);
        async.flushMicrotasks();
        expect(ended, isTrue);
        expect(async.pendingTimers, isEmpty);
      });
    });
  }

  test(
    'a pause with no trip in flight ends a pending grace: the user left',
    () {
      fakeAsync((async) {
        final excursions = SystemActivityExcursions();
        final hold = Completer<void>();
        openTrip(excursions, hold);
        var ended = false;
        unawaited(excursions.graceForPause()!.then((_) => ended = true));
        hold.complete();
        async.flushMicrotasks();
        expect(excursions.inFlight, isFalse);

        expect(excursions.graceForPause(), isNull);
        async.flushMicrotasks();
        expect(ended, isTrue);
        expect(async.pendingTimers, isEmpty);
      });
    },
  );

  test('a trip whose body throws is still over', () async {
    final excursions = SystemActivityExcursions();
    await expectLater(
      excursions.run<void>(() async => throw StateError('picker')),
      throwsStateError,
    );
    expect(excursions.inFlight, isFalse);
  });

  group('the save a handoff waits for', () {
    test('is settled at once when nothing is being saved', () async {
      final excursions = SystemActivityExcursions();
      var settled = false;
      unawaited(excursions.saved.then((_) => settled = true));
      await pumpEventQueue();
      expect(settled, isTrue);
    });

    test('settles when the last save does, throwing or not', () async {
      final excursions = SystemActivityExcursions();
      final first = Completer<void>();
      final second = Completer<void>();
      final saving1 = excursions.save(() => first.future);
      final saving2 = excursions.save(() => second.future);
      var settled = false;
      unawaited(excursions.saved.then((_) => settled = true));

      first.complete();
      await saving1;
      await pumpEventQueue();
      expect(settled, isFalse, reason: 'one save is still in flight');

      second.completeError(StateError('decode'));
      await expectLater(saving2, throwsStateError);
      await pumpEventQueue();
      expect(settled, isTrue);
    });

    test('is in flight from the synchronous start of the save', () {
      // The handoff checks it and releases in one synchronous step, so a save
      // must count from the instant it is called, before its first await.
      final excursions = SystemActivityExcursions();
      final gate = Completer<void>();
      unawaited(excursions.save(() => gate.future));
      var settled = false;
      unawaited(excursions.saved.then((_) => settled = true));
      expect(settled, isFalse);
      gate.complete();
    });
  });

  group('the bounds are the decided ones', () {
    test('the grace is the owner-chosen 20 s, and fits inside the freshness '
        'of the stamp the pause leaves', () {
      expect(kSystemActivityHandoffGrace, const Duration(seconds: 20));
      // The last heartbeat is at most one interval before the pause, and the
      // service treats the stamp as live for two: so it defers on its own gate
      // for the whole grace instead of probing a live owner.
      expect(
        kBackgroundRepeatInterval + kSystemActivityHandoffGrace,
        lessThan(kBackgroundRepeatInterval * 2),
      );
    });

    test("a save waits for the handoff to end for twice the resume's idle "
        'wait', () {
      expect(kHandoffEndWait, kBackgroundIdleMaxWait * 2);
    });
  });

  group("the grace's debug line", () {
    test('names how it ended and nothing else', () {
      // Rule 15. Identifiers planted where a careless line could pick them
      // up: the trip's own result, and the deadline as an absolute instant.
      const npub =
          'npub1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqp9k8z0';
      const path = '/data/user/0/com.oblivioustech.haven/cache/cropped-42.jpg';
      final log = LogCapture.install();
      fakeAsync((async) {
        final excursions = SystemActivityExcursions();
        final deadline = DateTime.now().add(kSystemActivityHandoffGrace);
        unawaited(
          excursions.run<String>(() async {
            await Completer<void>().future;
            return '$npub $path $deadline';
          }),
        );
        for (final cause in HandoffGraceEnd.values) {
          if (cause == HandoffGraceEnd.expired) {
            unawaited(excursions.graceForPause());
            async.elapse(kSystemActivityHandoffGrace);
            // Silent (nothing pending): starts the next stretch away.
            excursions.endGrace(HandoffGraceEnd.resumed);
          } else if (cause == HandoffGraceEnd.superseded) {
            // Only reachable with no trip in flight: a fresh tracker.
            final other = SystemActivityExcursions();
            final hold = Completer<void>();
            unawaited(other.run(() => hold.future));
            unawaited(other.graceForPause());
            hold.complete();
            async.flushMicrotasks();
            other.graceForPause();
          } else {
            unawaited(excursions.graceForPause());
            excursions.endGrace(cause);
          }
        }
        log
          ..assertContains('[MapShell] handoff grace: ended by expired')
          ..assertNoNeedles([npub, path, deadline.toIso8601String()]);
        expect(
          log.lines,
          [
            for (final cause in HandoffGraceEnd.values)
              '[MapShell] handoff grace: ended by ${cause.name}',
          ],
          reason:
              'one fixed line per ending, in the C6 vocabulary the e2e '
              'lanes read',
        );
      });
    });

    test('is silent when there was no grace to end', () {
      final log = LogCapture.install();
      SystemActivityExcursions()
        ..endGrace(HandoffGraceEnd.resumed)
        ..graceForPause();
      expect(log.lines, isEmpty);
    });
  });
}
