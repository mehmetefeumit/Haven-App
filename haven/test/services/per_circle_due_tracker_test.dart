import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/constants/location.dart';
import 'package:haven/src/services/per_circle_due_tracker.dart';
import 'package:haven/src/services/publish_stagger.dart';

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
      final tracker = PerCircleDueTracker()
        ..seedIfAbsent('a', firstDue)
        // A second seed with a different time must NOT overwrite: a circle
        // that is already publishing on its own cadence is never yanked to a
        // new phase.
        ..seedIfAbsent('a', t0);
      expect(tracker.nextDueForTest['a'], firstDue);
      expect(tracker.isDue('a', t0), isFalse);
    });

    test('a burst re-arms every circle it published onto ONE due', () {
      // The coalescing guarantee at the data-structure level, and the reason
      // it must be ONE due rather than one per circle: `dueKeysUpTo` orders by
      // due ascending, so distinct dues make the next burst's order a function
      // of this burst's order. The CSPRNG permutation would then be dead code
      // from the second burst on, the same circle would lead every burst, and
      // the whole-second delta between the two circles' `created_at` would
      // print the same number forever — the archive link the stagger exists
      // to break.
      final tracker = PerCircleDueTracker()
        ..seedIfAbsent('a', t0)
        ..seedIfAbsent('b', t0);
      expect(tracker.nextDueForTest['a'], tracker.nextDueForTest['b']);

      // The burst published them a 4 s stagger gap apart.
      final due = nextBurstDue(
        firstPublishStartedAt: t0,
        lastPublishStartedAt: t0.add(const Duration(seconds: 4)),
        interval: const Duration(seconds: 120),
        minInterval: kLocationPublishMinInterval,
      );
      tracker.markBurstPublished(<String>['a', 'b'], due);

      expect(tracker.nextDueForTest['a'], due);
      expect(
        tracker.nextDueForTest['b'],
        tracker.nextDueForTest['a'],
        reason: 'a due per circle carries the burst order into the next '
            'burst, which is exactly what freezes the permutation',
      );
      expect(tracker.isDue('a', t0), isFalse);
      expect(
        tracker.isDue('a', due.subtract(const Duration(seconds: 1))),
        isFalse,
      );
      expect(tracker.isDue('a', due), isTrue);
    });

    test('a burst re-arms only what it published — a failed or deferred '
        'circle stays overdue', () {
      final tracker = PerCircleDueTracker()
        ..seedIfAbsent('published', t0)
        ..seedIfAbsent('deferred', t0)
        ..markBurstPublished(
          <String>['published'],
          t0.add(const Duration(seconds: 120)),
        );

      expect(tracker.isDue('deferred', t0), isTrue);
      expect(tracker.nextDueForTest['deferred'], t0);
      expect(tracker.isDue('published', t0), isFalse);
    });

    test('a pruned-then-reseeded circle gets a genuinely fresh phase', () {
      final tracker = PerCircleDueTracker()
        ..seedIfAbsent('a', t0)
        ..markBurstPublished(
          <String>['a'],
          t0.add(const Duration(seconds: 90)),
        )
        ..pruneToKeys(<String>{}); // a leaves
      expect(tracker.length, 0);
      // Rejoin later: seed picks up the NEW time, not the stale t0+90.
      final rejoin = t0.add(const Duration(seconds: 500));
      tracker.seedIfAbsent('a', rejoin);
      expect(tracker.nextDueForTest['a'], rejoin);
    });

    test('pruneToKeys drops untracked circles and keeps the rest', () {
      final tracker = PerCircleDueTracker()
        ..seedIfAbsent('a', t0)
        ..seedIfAbsent('b', t0)
        ..seedIfAbsent('c', t0)
        ..pruneToKeys({'a', 'c'});
      expect(tracker.length, 2);
      expect(tracker.nextDueForTest.keys, containsAll(<String>['a', 'c']));
      expect(tracker.nextDueForTest.containsKey('b'), isFalse);
    });
  });

  group('nextBurstDue', () {
    final t0 = DateTime.utc(2026, 1, 1, 12);

    /// The two bounds every circle's REALIZED gap must land between, given a
    /// burst that re-arms onto `nextBurstDue` and a next burst that spends up
    /// to [spread] of its own.
    ///
    /// A circle publishes at `first + o` and next at `due + o'`, both offsets
    /// anywhere in `[0, spread]` because the permutation is fresh every burst.
    /// So the gap ranges over `(due - first) ± spread`.
    ({Duration min, Duration max}) realizedGapRange({
      required Duration interval,
      required Duration spread,
    }) {
      final due = nextBurstDue(
        firstPublishStartedAt: t0,
        lastPublishStartedAt: t0.add(spread),
        interval: interval,
        minInterval: kLocationPublishMinInterval,
      );
      final shift = due.difference(t0);
      return (min: shift - spread, max: shift + spread);
    }

    test('every realized gap stays at or above the disclosed cadence floor, '
        'for every interval and every spread', () {
      // The mutant this kills: anchoring the shared due at the burst's FIRST
      // publish alone. At the short end of the jitter band that re-arms the
      // circle which published LAST a whole spread early — 42 s against the
      // 72 s floor the app discloses — and every plane reads the same helper.
      for (var secs = kLocationPublishMinInterval.inSeconds;
          secs <= kLocationPublishMaxInterval.inSeconds;
          secs++) {
        for (var spreadSecs = 0;
            spreadSecs <= kPublishStaggerMaxSpread.inSeconds;
            spreadSecs++) {
          final range = realizedGapRange(
            interval: Duration(seconds: secs),
            spread: Duration(seconds: spreadSecs),
          );
          expect(
            range.min,
            greaterThanOrEqualTo(kLocationPublishMinInterval),
            reason: 'interval ${secs}s spread ${spreadSecs}s re-armed a '
                'circle ${kLocationPublishMinInterval - range.min} inside the '
                'floor Haven discloses',
          );
        }
      }
    });

    test('and at or below the cadence ceiling plus ONE burst spread, for '
        'every interval and every spread', () {
      // The other mutant: anchoring at the LAST publish alone. That makes the
      // circle which published FIRST wait `interval + spread` before the next
      // burst even starts, and up to another spread inside it — 228 s at the
      // top of the band, exactly the retention the no-gap invariant must stay
      // under, with nothing left for propagation.
      final ceiling = kLocationPublishMaxInterval + kPublishStaggerMaxSpread;
      for (var secs = kLocationPublishMinInterval.inSeconds;
          secs <= kLocationPublishMaxInterval.inSeconds;
          secs++) {
        for (var spreadSecs = 0;
            spreadSecs <= kPublishStaggerMaxSpread.inSeconds;
            spreadSecs++) {
          final range = realizedGapRange(
            interval: Duration(seconds: secs),
            spread: Duration(seconds: spreadSecs),
          );
          expect(
            range.max,
            lessThanOrEqualTo(ceiling),
            reason: 'interval ${secs}s spread ${spreadSecs}s can push a '
                'circle to ${range.max}, past the $ceiling the 228 s '
                'kind-445 retention leaves room for',
          );
        }
      }
    });

    test('a burst that spent no spread re-arms exactly one interval after it '
        'started', () {
      // Anti-vacuity for the floor above: the clamp must ENGAGE only where
      // the spread genuinely eats into the floor, never as a blanket rewrite
      // of the sampled cadence.
      expect(
        nextBurstDue(
          firstPublishStartedAt: t0,
          lastPublishStartedAt: t0,
          interval: const Duration(seconds: 90),
          minInterval: kLocationPublishMinInterval,
        ),
        t0.add(const Duration(seconds: 90)),
      );
      // A wide spread under a LONG interval is still the interval: the floor
      // only binds when `spread + 72 s` overtakes it.
      expect(
        nextBurstDue(
          firstPublishStartedAt: t0,
          lastPublishStartedAt: t0.add(kPublishStaggerMaxSpread),
          interval: kLocationPublishMaxInterval,
          minInterval: kLocationPublishMinInterval,
        ),
        t0.add(kLocationPublishMaxInterval),
      );
      // ...and it does bind at the short end.
      expect(
        nextBurstDue(
          firstPublishStartedAt: t0,
          lastPublishStartedAt: t0.add(kPublishStaggerMaxSpread),
          interval: kLocationPublishMinInterval,
          minInterval: kLocationPublishMinInterval,
        ),
        t0.add(kPublishStaggerMaxSpread + kLocationPublishMinInterval),
        reason: 'the last circle of the burst must still get its full floor',
      );
    });
  });

  group('PerCircleDueTracker.dueKeysUpTo', () {
    final t0 = DateTime.utc(2026, 1, 1, 12);

    test('returns the due circles most-overdue first', () {
      final tracker = PerCircleDueTracker()
        ..seedIfAbsent('late', t0.subtract(const Duration(seconds: 40)))
        ..seedIfAbsent('later', t0.subtract(const Duration(seconds: 90)))
        ..seedIfAbsent('soon', t0.add(const Duration(seconds: 5)));

      expect(
        tracker.dueKeysUpTo(
          <String>{'late', 'later', 'soon'},
          t0.add(const Duration(seconds: 30)),
        ),
        ['later', 'late', 'soon'],
        reason: 'the circle that has waited longest must take the zero gap, '
            'so the stagger shifts WHICH circle waits instead of adding to '
            'the worst-case inter-publish gap',
      );
    });

    test('ties are broken by the order the caller asks in, never by key', () {
      // A burst seeds and re-arms its circles together, so equal due-times are
      // the NORM and the tie-break IS the publish order. Sorting ties by key
      // would put one circle's `created_at` permanently ahead of its sibling's
      // — a stable relationship between the two stamps, which is the
      // second-order fingerprint `PublishStagger.shuffled` exists to prevent.
      // The caller owns the order and passes a CSPRNG permutation.
      final tracker = PerCircleDueTracker()
        ..seedIfAbsent('a', t0)
        ..seedIfAbsent('b', t0)
        ..seedIfAbsent('c', t0);

      expect(tracker.dueKeysUpTo(<String>['c', 'a', 'b'], t0), ['c', 'a', 'b']);
      expect(tracker.dueKeysUpTo(<String>['b', 'c', 'a'], t0), ['b', 'c', 'a']);
    });

    test("an overdue circle still outranks the caller's order", () {
      // The tie-break may only decide ties: a circle that has waited longer
      // than its siblings must still take the zero gap.
      final tracker = PerCircleDueTracker()
        ..seedIfAbsent('overdue', t0.subtract(const Duration(seconds: 40)))
        ..seedIfAbsent('a', t0)
        ..seedIfAbsent('b', t0);

      expect(
        tracker.dueKeysUpTo(<String>['b', 'a', 'overdue'], t0),
        ['overdue', 'b', 'a'],
      );
    });

    test('the horizon admits circles seeded a few seconds into the future', () {
      final tracker = PerCircleDueTracker()
        ..seedIfAbsent('now', t0)
        ..seedIfAbsent('staggered', t0.add(const Duration(seconds: 6)))
        ..seedIfAbsent('next-cycle', t0.add(const Duration(seconds: 100)));

      expect(
        tracker.dueKeysUpTo(
          <String>{'now', 'staggered', 'next-cycle'},
          t0.add(kPublishStaggerMaxSpread),
        ),
        ['now', 'staggered'],
        reason: 'without the horizon a staggered circle would wait a whole '
            '72 s poll interval to publish — the stagger must cost seconds, '
            'not a cycle',
      );
    });

    test('an untracked key is never returned', () {
      final tracker = PerCircleDueTracker()..seedIfAbsent('a', t0);
      expect(tracker.dueKeysUpTo(<String>{'a', 'ghost'}, t0), ['a']);
    });

    test('earliestDue is the minimum over tracked keys and null when nothing '
        'is tracked', () {
      final tracker = PerCircleDueTracker();
      expect(tracker.earliestDue(<String>{'a', 'b'}), isNull);

      tracker
        ..seedIfAbsent('late', t0.add(const Duration(seconds: 140)))
        ..seedIfAbsent('soon', t0.add(const Duration(seconds: 80)))
        ..seedIfAbsent('middle', t0.add(const Duration(seconds: 100)));

      expect(
        tracker.earliestDue(<String>{'late', 'soon', 'middle'}),
        t0.add(const Duration(seconds: 80)),
        reason: 'the background fix request is aimed at the FIRST circle that '
            'needs one; aiming at any later due-time starves the earlier '
            'circle by the difference',
      );
    });

    test('earliestDue sees only the keys it is asked about', () {
      // The cycle folds its own projections (slot + pre-sampled interval) for
      // the circles it is about to publish and asks the tracker only about the
      // rest, so a tracked key outside the argument must not leak in — nor may
      // an untracked key in it be treated as due now.
      final tracker = PerCircleDueTracker()
        ..seedIfAbsent('asked', t0.add(const Duration(seconds: 100)))
        ..seedIfAbsent('unasked', t0.add(const Duration(seconds: 40)));

      expect(
        tracker.earliestDue(<String>{'asked', 'ghost'}),
        t0.add(const Duration(seconds: 100)),
      );
    });

    test('earliestDue reports an overdue circle at its own past due-time', () {
      // Clamping an overdue circle to `now` would hide exactly the case the
      // interval floor exists for: the aim is already in the past, so the
      // request must fall back to the platform minimum rather than to a
      // fabricated future target.
      final overdue = t0.subtract(const Duration(seconds: 45));
      final tracker = PerCircleDueTracker()
        ..seedIfAbsent('overdue', overdue)
        ..seedIfAbsent('later', t0.add(const Duration(seconds: 90)));

      expect(tracker.earliestDue(<String>{'overdue', 'later'}), overdue);
    });
  });

  group('nextBackgroundPublishSlot', () {
    final t0 = DateTime.utc(2026, 1, 1, 12);
    final deadline = t0.add(kPublishStaggerMaxSpread);

    test('the first circle of a cycle publishes at its own due-time', () {
      expect(
        nextBackgroundPublishSlot(
          dueAt: t0.subtract(const Duration(seconds: 30)),
          lastPublishStartedAt: null,
          gap: const Duration(seconds: 4),
          phaseStart: t0,
          deadline: deadline,
        ),
        t0.subtract(const Duration(seconds: 30)),
      );
    });

    test(
      'a same-cycle sibling is held a gap past the previous publish, even '
      'when both were due at the same instant',
      () {
        // The 72 s poll routinely selects two independently-scheduled circles
        // in one cycle; without this they would publish back to back inside
        // one second.
        expect(
          nextBackgroundPublishSlot(
            dueAt: t0,
            lastPublishStartedAt: t0,
            gap: const Duration(milliseconds: 4500),
            phaseStart: t0,
            deadline: deadline,
          ),
          t0.add(const Duration(milliseconds: 4500)),
        );
      },
    );

    test(
      'a slow publish cannot compress the next gap — the gap is measured from '
      'the ACTUAL previous start, not from a pre-computed slot',
      () {
        // Publish 1 was due at t0+2 but only started at t0+9 because publish 0
        // overran. A fixed-slot schedule would fire publish 2 at its original
        // t0+4 slot, 5 s BEFORE publish 1. Running measurement cannot.
        final slot = nextBackgroundPublishSlot(
          dueAt: t0.add(const Duration(seconds: 4)),
          lastPublishStartedAt: t0.add(const Duration(seconds: 9)),
          gap: const Duration(seconds: 3),
          phaseStart: t0,
          deadline: deadline,
        );
        expect(slot, t0.add(const Duration(seconds: 12)));
      },
    );

    test(
      'a simulated cycle keeps every consecutive pair more than a second '
      'apart, including under overrunning publishes',
      () {
        final stagger = PublishStagger(rng: Random(6));
        final rng = Random(21);
        for (var trial = 0; trial < 200; trial++) {
          final phaseStart = t0;
          // Six circles, all selected by the same 72 s cycle, with due-times
          // scattered across the window (the realistic same-bucket case).
          final dues = <DateTime>[
            for (var i = 0; i < 6; i++)
              phaseStart.add(Duration(milliseconds: rng.nextInt(20000) - 5000)),
          ]..sort();

          final starts = <DateTime>[];
          DateTime? last;
          for (final due in dues) {
            final slot = nextBackgroundPublishSlot(
              dueAt: due,
              lastPublishStartedAt: last,
              gap: stagger.sampleGap(totalPublishes: dues.length),
              phaseStart: phaseStart,
              // Generous deadline so this trial exercises the pacing, not the
              // budget cut-off (which has its own test below).
              deadline: phaseStart.add(const Duration(minutes: 5)),
            );
            expect(slot, isNotNull);
            // A publish may START later than its slot (relay latency, a slow
            // encrypt); model that as the caller does, by recording the real
            // start and measuring the next gap from it.
            final actualStart = slot!.add(
              Duration(milliseconds: rng.nextInt(6000)),
            );
            starts.add(actualStart);
            last = actualStart;
          }

          for (var i = 1; i < starts.length; i++) {
            expect(
              starts[i].difference(starts[i - 1]).inMilliseconds,
              greaterThan(1000),
              reason: 'trial $trial put two circles in the same second',
            );
          }
        }
      },
    );

    test(
      'the budget defers the remainder rather than compressing the gaps',
      () {
        expect(
          nextBackgroundPublishSlot(
            dueAt: t0,
            lastPublishStartedAt: deadline.subtract(
              const Duration(milliseconds: 500),
            ),
            gap: const Duration(seconds: 4),
            phaseStart: t0,
            deadline: deadline,
          ),
          isNull,
          reason: 'publishing anyway would put this circle within 0.5 s of its '
              'sibling — a deferred publish is late, a compressed one is '
              'linked forever',
        );
      },
    );

    test('an untracked circle falls back to the phase start, not to null', () {
      expect(
        nextBackgroundPublishSlot(
          dueAt: null,
          lastPublishStartedAt: null,
          gap: const Duration(seconds: 4),
          phaseStart: t0,
          deadline: deadline,
        ),
        t0,
      );
    });
  });
}
