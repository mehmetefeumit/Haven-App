import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/services/per_circle_due_tracker.dart';

void main() {
  group('PerCircleDueTracker', () {
    final t0 = DateTime.utc(2026, 1, 1, 12);

    test('an unregistered circle is never due', () {
      final tracker = PerCircleDueTracker();
      expect(tracker.isDue('a', t0), isFalse);
      expect(tracker.length, 0);
    });

    test('seedIfAbsent(now) makes a circle immediately due', () {
      final tracker = PerCircleDueTracker()..seedIfAbsent('a', t0);
      expect(tracker.isDue('a', t0), isTrue);
      // ...and still due a moment later.
      expect(tracker.isDue('a', t0.add(const Duration(seconds: 1))), isTrue);
    });

    test('seedIfAbsent with a future due-time is not yet due', () {
      final due = t0.add(const Duration(seconds: 120));
      final tracker = PerCircleDueTracker()..seedIfAbsent('a', due);
      expect(tracker.isDue('a', t0), isFalse);
      expect(tracker.isDue('a', due), isTrue);
      expect(
        tracker.isDue('a', due.add(const Duration(seconds: 1))),
        isTrue,
      );
    });

    test('seedIfAbsent is idempotent — a tracked circle keeps its schedule', () {
      final firstDue = t0.add(const Duration(seconds: 100));
      final tracker = PerCircleDueTracker()..seedIfAbsent('a', firstDue);
      // A second seed with a different time must NOT overwrite: a circle that
      // is already publishing on its own cadence is never yanked to a new phase.
      tracker.seedIfAbsent('a', t0);
      expect(tracker.nextDueForTest['a'], firstDue);
      expect(tracker.isDue('a', t0), isFalse);
    });

    test('markPublished re-arms a fresh interval from now, clearing due', () {
      final tracker = PerCircleDueTracker()..seedIfAbsent('a', t0);
      expect(tracker.isDue('a', t0), isTrue);
      tracker.markPublished('a', t0, 90);
      // No longer due immediately after publishing.
      expect(tracker.isDue('a', t0), isFalse);
      expect(tracker.isDue('a', t0.add(const Duration(seconds: 89))), isFalse);
      expect(tracker.isDue('a', t0.add(const Duration(seconds: 90))), isTrue);
    });

    test('markPublished re-arms off now, not off a stale due-time (no drift)', () {
      final tracker = PerCircleDueTracker()..seedIfAbsent('a', t0);
      // Circle was due at t0 but the cycle only got to it 50s late.
      final late = t0.add(const Duration(seconds: 50));
      tracker.markPublished('a', late, 100);
      // Next due is late+100, NOT t0+100 — so a slow cycle can't compress the
      // real inter-publish gap below the intended interval.
      expect(tracker.nextDueForTest['a'], late.add(const Duration(seconds: 100)));
    });

    test('two circles seeded together get independent, decorrelated phases', () {
      // The decorrelation guarantee at the data-structure level: independent
      // interval samples produce independent next-due times even from the same
      // seed instant.
      final tracker = PerCircleDueTracker()
        ..seedIfAbsent('a', t0)
        ..seedIfAbsent('b', t0);
      tracker.markPublished('a', t0, 72); // a's fresh sample
      tracker.markPublished('b', t0, 168); // b's fresh sample
      expect(tracker.nextDueForTest['a'], t0.add(const Duration(seconds: 72)));
      expect(tracker.nextDueForTest['b'], t0.add(const Duration(seconds: 168)));
      // At t0+100s, a is due again but b is not — they no longer publish in
      // lockstep.
      final at100 = t0.add(const Duration(seconds: 100));
      expect(tracker.isDue('a', at100), isTrue);
      expect(tracker.isDue('b', at100), isFalse);
    });

    test('pruneToKeys drops untracked circles and keeps the rest', () {
      final tracker = PerCircleDueTracker()
        ..seedIfAbsent('a', t0)
        ..seedIfAbsent('b', t0)
        ..seedIfAbsent('c', t0);
      tracker.pruneToKeys({'a', 'c'});
      expect(tracker.length, 2);
      expect(tracker.nextDueForTest.keys, containsAll(<String>['a', 'c']));
      expect(tracker.nextDueForTest.containsKey('b'), isFalse);
    });

    test('a pruned-then-reseeded circle gets a genuinely fresh phase', () {
      final tracker = PerCircleDueTracker()..seedIfAbsent('a', t0);
      tracker.markPublished('a', t0, 90); // due at t0+90
      tracker.pruneToKeys(<String>{}); // a leaves
      expect(tracker.length, 0);
      // Rejoin later: seed picks up the NEW time, not the stale t0+90.
      final rejoin = t0.add(const Duration(seconds: 500));
      tracker.seedIfAbsent('a', rejoin);
      expect(tracker.nextDueForTest['a'], rejoin);
    });
  });
}
