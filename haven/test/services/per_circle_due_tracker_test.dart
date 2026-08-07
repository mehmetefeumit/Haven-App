import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
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

  // ---------------------------------------------------------------------------
  // The background half of the shared-`created_at` leak.
  //
  // The background isolate empties this tracker on every cycle where the
  // foreground owns publishing, so the seed re-runs on EVERY foreground→
  // background handoff. Seeding the whole roster at one instant therefore
  // re-created the co-timed burst on every handoff, not merely the first.
  // ---------------------------------------------------------------------------

  group('PerCircleDueTracker.seedStaggered', () {
    final t0 = DateTime.utc(2026, 1, 1, 12);

    test(
      'a handoff does NOT re-seed every circle to the same instant',
      () {
        final tracker = PerCircleDueTracker()
          ..seedStaggered(
            <String>{'a', 'b', 'c', 'd'},
            t0,
            PublishStagger(rng: Random(1)),
          );

        final dueTimes = tracker.nextDueForTest.values.toList();
        expect(dueTimes.length, 4);
        expect(
          dueTimes.toSet().length,
          4,
          reason: 'every circle sharing one due-time is exactly what made the '
              'handoff publish them all inside one wall-clock second',
        );
      },
    );

    test(
      'seeded due-times are more than a second apart — the created_at stamp '
      'is whole seconds, so anything less is no separation at all',
      () {
        for (var seed = 0; seed < 40; seed++) {
          final tracker = PerCircleDueTracker()
            ..seedStaggered(
              <String>{'a', 'b', 'c', 'd', 'e'},
              t0,
              PublishStagger(rng: Random(seed)),
            );
          final sorted = tracker.nextDueForTest.values.toList()..sort();
          for (var i = 1; i < sorted.length; i++) {
            expect(
              sorted[i].difference(sorted[i - 1]).inMilliseconds,
              greaterThan(1000),
              reason: 'seed $seed put two circles inside the same second',
            );
          }
        }
      },
    );

    test('exactly one circle is seeded due-now, so the handoff is prompt', () {
      final tracker = PerCircleDueTracker()
        ..seedStaggered(
          <String>{'a', 'b', 'c'},
          t0,
          PublishStagger(rng: Random(2)),
        );
      expect(
        tracker.nextDueForTest.values.where((d) => d == t0).length,
        1,
        reason: 'delaying EVERY circle would widen the handoff gap for no '
            'decorrelation gain — only the relative offsets matter',
      );
    });

    test(
      'the whole seeded spread fits inside one background cycle, so no circle '
      'slips a 72 s polling interval',
      () {
        final stagger = PublishStagger(rng: Random(3));
        for (var n = 2; n <= 8; n++) {
          final keys = <String>{for (var i = 0; i < n; i++) 'c$i'};
          final tracker = PerCircleDueTracker()
            ..seedStaggered(keys, t0, stagger);
          final latest = tracker.nextDueForTest.values.reduce(
            (a, b) => a.isAfter(b) ? a : b,
          );
          expect(
            latest.difference(t0),
            lessThanOrEqualTo(stagger.maxSpreadFor(n)),
          );
          expect(
            latest.difference(t0),
            lessThan(const Duration(seconds: 72)),
            reason: 'a stagger wider than kBackgroundRepeatInterval would push '
                'the circle to the NEXT cycle instead of this one',
          );
        }
      },
    );

    test('does not disturb — or spend an offset on — a tracked circle', () {
      // Seed-swept: a tracked circle must never consume a stagger slot for ANY
      // permutation. Asserting on a single seed would pass whenever that seed
      // happened to shuffle the fresh circle to the front.
      for (var seed = 0; seed < 40; seed++) {
        final ownPhase = t0.add(const Duration(seconds: 95));
        final tracker = PerCircleDueTracker()
          ..seedIfAbsent('a', ownPhase)
          ..seedStaggered(
            <String>{'a', 'b'},
            t0,
            PublishStagger(rng: Random(seed)),
          );

        expect(tracker.nextDueForTest['a'], ownPhase, reason: 'seed $seed');
        expect(
          tracker.nextDueForTest['b'],
          t0,
          reason: 'seed $seed: b is the only fresh circle, so it takes the '
              'due-now slot rather than being pushed behind a phantom sibling '
              '— a long-lived roster must never delay a genuinely new circle',
        );
      }
    });

    test('which circle gets the due-now slot varies across handoffs', () {
      final firsts = <String>{};
      for (var seed = 0; seed < 40; seed++) {
        final tracker = PerCircleDueTracker()
          ..seedStaggered(
            <String>{'a', 'b', 'c'},
            t0,
            PublishStagger(rng: Random(seed)),
          );
        firsts.addAll(
          tracker.nextDueForTest.entries
              .where((e) => e.value == t0)
              .map((e) => e.key),
        );
      }
      expect(
        firsts.length,
        greaterThan(1),
        reason: 'a fixed "who goes first" would be a stable order an observer '
            'could learn',
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
