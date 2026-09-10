/// Tests for [PublishStagger] — the CSPRNG delay that keeps two circles'
/// kind-445 events out of the same wall-clock second.
///
/// The property under test is NOT "a delay happens". It is that the delay is
/// (a) always more than one second, because the engine binds the outer
/// `created_at` to the inner app event's WHOLE-SECOND timestamp so sub-second
/// jitter is invisible on the wire; (b) randomised, because a constant stagger
/// is itself a fingerprint; and (c) bounded, because a location is only worth
/// sending while it is current.
///
/// (b) is not one property but a FAMILY of them, one per burst size, because
/// the per-gap ceiling is priced at the burst's own size
/// ([PublishStagger.maxGapFor]) and therefore shrinks as the roster grows. The
/// two tables below are what pin that family; see
/// `expected whole-second delta alphabet, swept over every burst size the app
/// admits`.
library;

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/constants/location.dart';
import 'package:haven/src/services/publish_stagger.dart';

/// Per-gap ceiling in milliseconds for every burst size a production burst can
/// have.
///
/// A LITERAL table, not `maxSpread ~/ (n - 1)` re-derived: re-deriving it here
/// would make the test agree with any pricing rule, including one that thins
/// the delta alphabet below. This is the shape of the roster-size estimator
/// documented on `PUB-COALESCE`: the ceiling is injective in n over n >= 5 in
/// MILLISECONDS, but `created_at` is whole SECONDS, and the quantization
/// collapses seven with eight and nine with ten — so the ceiling an observer
/// can actually read resolves the roster exactly at five, six and eleven and
/// only to a PAIR otherwise ([_expectedDeltaAlphabet]). One bit coarser on two
/// pairs, never absent. A change to it must be a visible edit here.
const _expectedMaxGapMs = <int, int>{
  2: 9000,
  3: 9000,
  4: 9000,
  5: 7500,
  6: 6000,
  7: 5000,
  8: 4285,
  9: 3750,
  10: 3333,
  11: 3000,
};

/// The EXACT set of whole-second `created_at` deltas an archive reader can
/// observe from a burst of `n` circles.
///
/// Every gap lands in `[kPublishStaggerMinGap, maxGapFor(n)]`, and the observer
/// reads `floor(t + gap) - floor(t)` for a sub-second phase `t` it does not
/// control — so the alphabet runs from `2` to `(999 + maxGapFor(n)) ~/ 1000`.
/// Literal for the same reason as [_expectedMaxGapMs]: this table is the
/// disclosed claim, and set EQUALITY is what makes a thinning fail rather than
/// pass as "at least two values".
const _expectedDeltaAlphabet = <int, Set<int>>{
  2: {2, 3, 4, 5, 6, 7, 8, 9},
  3: {2, 3, 4, 5, 6, 7, 8, 9},
  4: {2, 3, 4, 5, 6, 7, 8, 9},
  5: {2, 3, 4, 5, 6, 7, 8},
  6: {2, 3, 4, 5, 6},
  7: {2, 3, 4, 5},
  8: {2, 3, 4, 5},
  9: {2, 3, 4},
  10: {2, 3, 4},
  11: {2, 3},
};

void main() {
  group('PublishStagger bounds', () {
    test(
      'every sampled gap exceeds one second — the created_at stamp is whole '
      'seconds, so a sub-second gap would be no gap at all',
      () {
        final stagger = PublishStagger(rng: Random(1));
        for (var circles = 2; circles <= 40; circles++) {
          for (var i = 0; i < 200; i++) {
            final gap = stagger.sampleGap(totalPublishes: circles);
            expect(
              gap.inMilliseconds,
              greaterThan(1000),
              reason:
                  'a gap of one second or less can leave two publishes in the '
                  'same whole-second created_at (circles=$circles)',
            );
          }
        }
      },
    );

    test('the production minimum gap is above one second', () {
      // Pins the constant itself: the whole defence is that floor(t + gap) >
      // floor(t), which fails the moment this drops to a second or below.
      expect(kPublishStaggerMinGap.inMilliseconds, greaterThan(1000));
      expect(
        PublishStagger().sampleGap().inMilliseconds,
        greaterThanOrEqualTo(kPublishStaggerMinGap.inMilliseconds),
      );
    });

    test(
      'gaps are randomised, not a constant stagger (a constant is a '
      'fingerprint of its own)',
      () {
        // Support only: 100 distinct values out of 7001 is a low bar, and the
        // SHAPE of the draw is pinned by the uniformity sweep below.
        final stagger = PublishStagger(rng: Random(7));
        final seen = <int>{
          for (var i = 0; i < 500; i++) stagger.sampleGap().inMilliseconds,
        };
        expect(
          seen.length,
          greaterThan(100),
          reason: 'a near-degenerate distribution would let an observer '
              'predict — and therefore undo — the stagger',
        );
      },
    );

    test(
      'the draw is UNIFORM across its support, not merely inside it — swept '
      'over every burst size',
      () {
        // `sampleGap` documents a uniform draw, and nothing tested the SHAPE:
        // the alphabet sweep asserts which deltas are REACHABLE and the test
        // above accepts any 100 distinct values out of 7001, so a draw that
        // printed 2 s on nineteen bursts in twenty and grazed the rest of the
        // support once each satisfied both. The disclosed defence rests on the
        // shape, not the support — "a constant delta is as good a link as no
        // gap at all" reads on a heavily skewed draw almost exactly as it reads
        // on a constant one, because the observer still sees the same offset
        // nearly every burst.
        //
        // Quartiles OF THE SUPPORT rather than fixed one-second buckets: the
        // support is 7001 ms wide at two circles and 1001 at the cap. One
        // seeded [Random], so every count below is a fixed number rather than a
        // sample that might drift — no tolerance is being spent on luck. The
        // band is 5% of the expected 5000; the widest deviation this sampler
        // shows is 3.1% (4845, at the cap), while a triangular draw over the
        // same support puts two quartiles at 2500 and a floor-weighted one
        // takes 10020 of the 20000 in its lowest — both miss by a factor.
        const draws = 20000;
        const expected = draws ~/ 4;
        const tolerance = expected ~/ 20;
        for (var n = 2; n <= kMaxCirclesPerBurst; n++) {
          final stagger = PublishStagger(rng: Random(59));
          final minMs = kPublishStaggerMinGap.inMilliseconds;
          final width = stagger.maxGapFor(n).inMilliseconds - minMs + 1;
          final quartiles = List<int>.filled(4, 0);
          for (var i = 0; i < draws; i++) {
            final gapMs = stagger.sampleGap(totalPublishes: n).inMilliseconds;
            quartiles[min(3, ((gapMs - minMs) * 4) ~/ width)]++;
          }
          for (var q = 0; q < 4; q++) {
            expect(
              quartiles[q],
              closeTo(expected, tolerance),
              reason: 'at $n circles quartile $q of the gap support took '
                  '${quartiles[q]} of $draws draws rather than about '
                  '$expected: the draw favours part of its own range, so most '
                  'bursts print the same few offsets and an observer needs '
                  'fewer of them to read the schedule. Counts were $quartiles',
            );
          }
        }
      },
    );

    test('the per-gap ceiling is the priced table, for every burst size', () {
      // `maxGapFor` is the ONLY thing that sets the delta alphabet below, and
      // it is also — over n >= 5, where it stops saturating at maxGap — an
      // injective function of the burst size IN MILLISECONDS. That injectivity
      // does NOT survive the whole-second quantization of `created_at`: the
      // alphabet an observer holding one delta per burst reads resolves the
      // roster exactly at five, six and eleven circles and only to a pair at
      // seven/eight and nine/ten, which share {2…5} and {2, 3, 4}
      // ([_expectedDeltaAlphabet]). The count still leaks — one bit coarser on
      // those two pairs, not absent (PUB-COALESCE, Cost 3). Both readings need
      // the table pinned, and both need it pinned as VALUES rather than as the
      // formula.
      final stagger = PublishStagger(rng: Random(41));
      for (var n = 2; n <= kMaxCirclesPerBurst; n++) {
        expect(
          stagger.maxGapFor(n).inMilliseconds,
          _expectedMaxGapMs[n],
          reason: 'the per-gap ceiling at $n circles moved',
        );
      }
      expect(
        _expectedMaxGapMs.keys.toSet(),
        {for (var n = 2; n <= kMaxCirclesPerBurst; n++) n},
        reason: 'the table must cover exactly the burst sizes production can '
            'reach, so moving kMaxCirclesPerBurst forces an edit here',
      );
      // Monotone non-increasing, and strictly decreasing from the point the
      // spread budget starts binding — the two facts that make the ceiling a
      // roster-count estimator rather than a constant.
      for (var n = 3; n <= kMaxCirclesPerBurst; n++) {
        expect(
          _expectedMaxGapMs[n],
          lessThanOrEqualTo(_expectedMaxGapMs[n - 1]!),
        );
      }
      for (var n = 6; n <= kMaxCirclesPerBurst; n++) {
        expect(
          _expectedMaxGapMs[n],
          lessThan(_expectedMaxGapMs[n - 1]!),
          reason: 'from six circles up each burst size prices a DISTINCT '
              'ceiling, which is what makes the span invertible to n',
        );
      }
    });

    test(
      'expected whole-second delta alphabet, swept over every burst size the '
      'app admits',
      () {
        // The one assertion that sees the roster-dependence of the surviving
        // defence. The alphabet is NOT a constant eight values: `maxGapFor`
        // prices every gap at the burst's own size, so it thins monotonically
        // — eight values up to four circles, and exactly {2, 3} at the cap.
        // Asserted as SET EQUALITY per burst size, because "at least k
        // values" is exactly the shape that let the eight-value claim stand
        // while the shipped alphabet at eleven circles was two.
        //
        // The first publish's sub-second phase is not the schedule's to
        // choose, so one seeded Random feeds both it and the gap: what is
        // measured is `floor(t + gap) - floor(t)`, never the gap.
        final rng = Random(97);
        final stagger = PublishStagger(rng: rng);
        final realized = <int, Set<int>>{};
        for (var n = 2; n <= kMaxCirclesPerBurst; n++) {
          final deltas = <int>{};
          for (var i = 0; i < 20000; i++) {
            final phaseMs = rng.nextInt(1000);
            final gapMs = stagger.sampleGap(totalPublishes: n).inMilliseconds;
            deltas.add((phaseMs + gapMs) ~/ 1000 - phaseMs ~/ 1000);
          }
          realized[n] = deltas;
          expect(
            deltas,
            _expectedDeltaAlphabet[n],
            reason: 'the observable delta alphabet at $n circles is not what '
                'the record claims: the disclosed downgrade in KIND rests on '
                'HOW MANY distinct offsets a burst can print',
          );
        }

        // The claim the tables encode, asserted over the realized sets so it
        // cannot be satisfied by editing the tables alone.
        for (var n = 3; n <= kMaxCirclesPerBurst; n++) {
          expect(
            realized[n]!.length,
            lessThanOrEqualTo(realized[n - 1]!.length),
            reason: 'the alphabet must thin monotonically in the roster size; '
                'a non-monotone step means the pricing rule changed shape',
          );
        }
        // Anti-vacuity at the cap, as a literal. At kMaxCirclesPerBurst the
        // priced ceiling is 3000 ms and so is the per-gap floor, but it is the
        // PRICING that binds here, not the floor: lowering the floor to minGap
        // leaves `maxSpread ~/ (n - 1)` at 3000 and this alphabet at {2, 3}.
        // (The floor binds only PAST the cap, where the pricing would go under
        // it — `an oversized burst sacrifices the spread budget, never the >1 s
        // separation` is what holds the gap above a second there, and
        // `kMaxCirclesPerBurst is DERIVED …` pins the floor's value.) So the
        // observer sees a TWO-element alphabet — two shifted equality joins
        // over the same whole-network index — and a change to the pricing, to
        // the spread budget or to the cap moves this number and must move this
        // line with it rather than silently invalidating the prose quoting it.
        expect(
          realized[kMaxCirclesPerBurst],
          <int>{2, 3},
          reason: 'at the cap the surviving defence is a constant factor, not '
              'a change in kind — the record says so and this pins it',
        );
        // And the property none of the thinning is allowed to touch.
        for (final deltas in realized.values) {
          expect(
            deltas.every((d) => d > 1),
            isTrue,
            reason: 'a delta of one second or less means two circles could '
                'carry the same stamp, which is the leak itself',
          );
        }
      },
    );

    test(
      'whole-second created_at deltas take all EIGHT distinct values over '
      '1000 sampled gaps, at the DEFAULT burst size of two',
      () {
        // The defence the shared burst tick KEEPS, stated as the observer sees
        // it. An archive holding two circles' kind-445s reads no milliseconds:
        // only `floor(created_at)` of each, so the only thing it can compare is
        // the whole-second delta. A constant delta is as good a link as no gap
        // at all — a 2-2.5 s stagger would print 2 or 3 s on EVERY burst —
        // whereas 2-9 s spreads it across eight values.
        //
        // Scope: `sampleGap()` with no argument prices the gap at
        // `totalPublishes = 2`, so this pins the TWO-circle case only. Every
        // larger burst prices a smaller ceiling and therefore a thinner
        // alphabet; that family is swept above.
        //
        // The first publish's sub-second phase is not the schedule's to choose,
        // so it is drawn too: what is measured here is
        // `floor(t + gap) - floor(t)`, not the gap.
        final rng = Random(23);
        final stagger = PublishStagger(rng: rng);
        final deltas = <int>{};
        for (var i = 0; i < 1000; i++) {
          final phaseMs = rng.nextInt(1000);
          final gapMs = stagger.sampleGap().inMilliseconds;
          deltas.add((phaseMs + gapMs) ~/ 1000 - phaseMs ~/ 1000);
        }

        // EIGHT, not "at least five". A floor of five admits any range down
        // to 2-6 s, so narrowing `kPublishStaggerMaxGap` from 9 s to 6 s —
        // which is a one-token edit, and which every spread assertion in this
        // file survives because they are all decided by the 3 s per-gap floor
        // — would leave this green while a third of the delta alphabet
        // disappeared.
        expect(
          deltas,
          <int>{2, 3, 4, 5, 6, 7, 8, 9},
          reason: 'a near-constant whole-second delta is itself the '
              'cross-circle link the stagger exists to break: an observer who '
              'sees the same delta every burst has learned the schedule',
        );
        // And the constant itself, so the alphabet above cannot be satisfied
        // by a coincidence of the seed.
        expect(kPublishStaggerMaxGap, const Duration(seconds: 9));
        expect(
          deltas.every((d) => d > 1),
          isTrue,
          reason: 'a delta of one second or less means both circles could '
              'carry the same stamp',
        );
      },
    );

    test('gaps stay inside the per-gap ceiling for the burst size', () {
      final stagger = PublishStagger(rng: Random(3));
      for (var circles = 2; circles <= 40; circles++) {
        final ceiling = stagger.maxGapFor(circles);
        for (var i = 0; i < 100; i++) {
          expect(
            stagger.sampleGap(totalPublishes: circles),
            lessThanOrEqualTo(ceiling),
          );
        }
      }
    });

    test(
      'a realistic burst stays inside the spread budget, so no circle is '
      'delayed past the point where its location is still worth sending',
      () {
        final stagger = PublishStagger(rng: Random(11));
        // [kMaxCirclesPerBurst] is the crossover: past it the per-gap floor
        // (minGap + 1 s, which keeps the gap both >1 s and non-degenerate) no
        // longer fits inside 30 s. The burst is what yields there — the
        // extra circles are deferred to the next tick — so no production
        // burst ever asks for a spread this loop does not cover.
        for (var circles = 2; circles <= kMaxCirclesPerBurst; circles++) {
          for (var i = 0; i < 100; i++) {
            final total = stagger
                .sampleGaps(circles)
                .fold(Duration.zero, (a, b) => a + b);
            expect(
              total,
              lessThanOrEqualTo(kPublishStaggerMaxSpread),
              reason: 'burst of $circles circles overran the freshness budget',
            );
          }
        }
      },
    );

    test(
      'the fix-freshness crossover is 57 circles, and the cap keeps every '
      'production burst five times inside it',
      () {
        // The one freshness bound that is not a preference: the single fix
        // taken at burst start must still be publishable by the app's own
        // rule when the LAST circle goes out. Past the cap the per-gap floor
        // is a flat 3 s, so the spread is `3 × (n − 1)` and the crossover is
        // exact rather than approximate — it used to be recorded as "still
        // respected at 60+ circles", which is precisely the false side of it.
        final stagger = PublishStagger(rng: Random(13));
        expect(
          stagger.maxSpreadFor(56),
          lessThan(kStreamPositionMaxAge),
          reason: 'the last burst size whose fix is still publishable',
        );
        expect(
          stagger.maxSpreadFor(57),
          greaterThanOrEqualTo(kStreamPositionMaxAge),
          reason: 'and the first that is not — arithmetic, not a defect: n '
              'events more than a second apart cannot fit in under n seconds, '
              'and the separation is the property being bought',
        );
        // Production never asks: a burst stops at the cap and defers the rest.
        expect(
          stagger.maxSpreadFor(kMaxCirclesPerBurst),
          lessThan(kStreamPositionMaxAge),
        );
      },
    );

    test(
      'the spread budget is dominated by the freshness constants it must '
      'respect',
      () {
        // A burst must finish before another burst may start, or two bursts
        // interleave and the pacing means nothing.
        expect(
          kPublishStaggerMaxSpread,
          lessThan(kLocationPublishOverlapGuard),
        );
        // The no-gap invariant's slack is retention (228 s) minus the maximum
        // publish interval (168 s). The stagger may spend at most part of it.
        //
        // 228 stays a LITERAL on purpose. Spelling it as
        // `kLocationPublishMaxInterval + 2 * kTtlNetworkBufferSeconds` cancels
        // algebraically against the subtraction: the bound collapses to
        // `2 * kTtlNetworkBufferSeconds` and stops moving with the cadence
        // ceiling at all, so raising `kLocationPublishMaxInterval` past the
        // retention window would leave this green. The literal is what pins
        // the bound to the wire truth instead.
        final noGapSlack =
            const Duration(seconds: 228) - kLocationPublishMaxInterval;
        expect(
          kPublishStaggerMaxSpread,
          lessThanOrEqualTo(noGapSlack ~/ 2),
          reason: 'deliberate tripwire paired with the derivation it must not '
              'be written from: 228 is LOCATION_MESSAGE_RETENTION_SECS in '
              'haven-core/src/location/ttl.rs, the value the engine stamps '
              'into the NIP-40 expiration tag — a cadence change must be a '
              'visible edit here, never a silent cancellation',
        );
        // The single GPS fix taken at burst start must still be publishable by
        // the app's own freshness rule when the LAST circle goes out.
        expect(kPublishStaggerMaxSpread, lessThan(kStreamPositionMaxAge));
      },
    );

    test(
      'kMaxCirclesPerBurst is DERIVED from the spread budget and the per-gap '
      'floor, not chosen',
      () {
        final stagger = PublishStagger(rng: Random(29));
        // The arithmetic in the constant's doc, executed:
        //   n − 1 ≤ kPublishStaggerMaxSpread ÷ (kPublishStaggerMinGap + 1 s)
        final floor = kPublishStaggerMinGap + const Duration(seconds: 1);
        expect(
          kMaxCirclesPerBurst,
          kPublishStaggerMaxSpread.inMilliseconds ~/ floor.inMilliseconds + 1,
          reason: 'the cap must move with the constants it is derived from, '
              'never be re-chosen beside them',
        );
        // Stated the other way round, against the function the burst planner
        // actually calls: the cap is the LARGEST burst that still fits the
        // budget, and one more circle does not.
        expect(
          stagger.maxSpreadFor(kMaxCirclesPerBurst),
          kPublishStaggerMaxSpread,
          reason: 'a cap below the crossover defers circles that fit, and '
              'every deferral costs a whole extra interval',
        );
        expect(
          stagger.maxSpreadFor(kMaxCirclesPerBurst + 1),
          greaterThan(kPublishStaggerMaxSpread),
          reason: 'a cap above the crossover lets a burst spend spread the '
              'retention has no room for',
        );
      },
    );

    test(
      'kMaxCirclesPerAccount puts the deferral ladder out of production reach, '
      'with exactly one circle of headroom',
      () {
        final stagger = PublishStagger(rng: Random(37));
        // The derivation, executed. A roster the app admits fits ONE burst, so
        // no circle is ever deferred and the ceil(N / cap) service-period
        // ladder is unreachable.
        expect(
          kMaxCirclesPerAccount,
          lessThan(kMaxCirclesPerBurst),
          reason: 'a roster at or past the burst cap is a roster whose tail '
              'the burst defers, which is the whole coverage hole',
        );
        // Headroom of exactly one circle. The burst cap is DERIVED from the
        // spread budget and the per-gap floor (test above), so a cadence or
        // freshness change can tighten it; the spare circle absorbs one such
        // tightening, and at eleven the first one would defer a tail again.
        expect(kMaxCirclesPerAccount, kMaxCirclesPerBurst - 1);
        // Every roster the app admits is served WHOLE, inside the spread the
        // freshness budget allows.
        for (var n = 1; n <= kMaxCirclesPerAccount; n++) {
          expect(stagger.sampleGaps(n), hasLength(n));
          expect(
            stagger.maxSpreadFor(n),
            lessThanOrEqualTo(kPublishStaggerMaxSpread),
            reason: 'a roster of $n is admissible, so its burst must fit the '
                'budget without deferring anything',
          );
        }
        // Anti-vacuity, in the units that matter: the bound is doing work, not
        // restating a bound that already held. Two circles past it is where the
        // no-gap floor actually breaks — 228 s is
        // LOCATION_MESSAGE_RETENTION_SECS, a literal for the reason the
        // spread-budget test spells out.
        const margin = Duration(seconds: 228 - kTtlNetworkBufferSeconds);
        expect(
          kLocationPublishMaxInterval +
              stagger.maxSpreadFor(kMaxCirclesPerAccount + 2),
          greaterThan(margin),
          reason: 'if the no-gap floor held two circles past the bound, the '
              'bound would be refusing circles for nothing',
        );
        // And the disclosed observable: the largest burst a bounded roster can
        // produce is kMaxCirclesPerAccount, so the alphabet the copy and the
        // manifest state ends at three values. `{2,3}` remains a value of
        // maxGapFor one circle further on, which no observer reaches.
        expect(_expectedDeltaAlphabet[kMaxCirclesPerAccount], {2, 3, 4});
        expect(_expectedDeltaAlphabet[kMaxCirclesPerBurst], {2, 3});
      },
    );

    test(
      'the no-gap invariant holds across the WHOLE admissible range, with the '
      'disclosed propagation margin intact',
      () {
        // `LOCATION_MESSAGE_RETENTION_SECS`, a literal for the reason the
        // tripwire below spells out: writing it as
        // `kLocationPublishMaxInterval + 2 * kTtlNetworkBufferSeconds` makes
        // the bound cancel algebraically and stop tracking the wire.
        const retention = Duration(seconds: 228);
        final stagger = PublishStagger(rng: Random(31));
        // A circle that leads one burst and trails the next waits the cadence
        // ceiling plus one spread. Swept over every burst size a production
        // burst can have — not asserted at a single point, which is how the
        // n ≥ 22 case (63 s of spread, a kind-445 that has ALREADY expired
        // when its replacement is created) went unnoticed.
        for (var n = 1; n <= kMaxCirclesPerBurst; n++) {
          final worstGap =
              kLocationPublishMaxInterval + stagger.maxSpreadFor(n);
          expect(
            worstGap,
            lessThanOrEqualTo(
              retention - const Duration(seconds: kTtlNetworkBufferSeconds),
            ),
            reason: 'a burst of $n circles can leave a peer $worstGap '
                'without a fresh kind-445, which spends the propagation and '
                'clock-skew margin the retention reserves',
          );
        }
        // The cap is what makes that a statement about EVERY roster rather
        // than about small ones: one more circle than the cap breaks it, and
        // that circle is deferred rather than published.
        expect(
          kLocationPublishMaxInterval +
              stagger.maxSpreadFor(kMaxCirclesPerBurst + 1),
          greaterThan(
            retention - const Duration(seconds: kTtlNetworkBufferSeconds),
          ),
          reason: 'anti-vacuity: if the bound held past the cap the cap would '
              'be deferring circles for nothing',
        );
      },
    );

    test(
      'and past the cap, the deferral ladder in SECONDS — the figures the '
      'record quotes for a ceil(N / kMaxCirclesPerBurst) service period',
      () {
        // The service PERIOD is behaviour, not arithmetic: it is
        // `_takeBurstSlice`'s round-robin, swept over both sides of every rung
        // by `a deferred circle waits ceil(N / kMaxCirclesPerBurst) bursts` in
        // `test/providers/location_publish_scheduler_provider_test.dart`. What
        // this pins is the other half of the same claim — the seconds
        // `kMaxCirclesPerBurst`'s own doc and INV-W-445-EXPIRATION-WINDOW's
        // residual quote for those periods, which are the cadence bounds
        // multiplied by them. Pinned HERE because the constants are, and rung
        // by rung as literals so a cadence change is a visible edit rather
        // than a silent re-derivation that moves the prose with the proof.
        //
        // `LOCATION_MESSAGE_RETENTION_SECS`, a literal for the reason the
        // spread-budget test above spells out.
        const retention = Duration(seconds: 228);
        Duration best(int bursts) => kLocationPublishMinInterval * bursts;
        Duration mean(int bursts) => kLocationUpdateInterval * bursts;
        Duration worst(int bursts) => kLocationPublishMaxInterval * bursts;

        // N = 12…22 — two bursts.
        expect(best(2), const Duration(seconds: 144));
        expect(mean(2), const Duration(seconds: 240));
        expect(worst(2), const Duration(seconds: 336));
        // And 366 s once the burst-position differential is counted: a circle
        // may LEAD one burst and TRAIL the one two ticks later, a whole spread
        // apart, so the differential ADDS to the scheduled worst case. 366 is
        // the number the record quotes; 336 is the number without it.
        expect(
          worst(2) + kPublishStaggerMaxSpread,
          const Duration(seconds: 366),
          reason: 'the burst-position differential is what makes the quoted '
              'worst case 366 s rather than 336 s',
        );
        // N = 23…33 — three.
        expect(best(3), const Duration(seconds: 216));
        expect(mean(3), const Duration(seconds: 360));
        expect(worst(3), const Duration(seconds: 504));
        // N ≥ 34 — four or more.
        expect(best(4), const Duration(seconds: 288));

        // Which rung leaves a peer's marker expired at the relay, and which
        // does so on EVERY publish rather than on most — the reason the ladder
        // is stated as a ladder instead of a single figure.
        expect(
          best(2),
          lessThan(retention),
          reason: 'at two bursts the BEST case is still inside the retention, '
              'which is what makes the hole most interval pairs and not all',
        );
        expect(
          mean(2),
          greaterThan(retention),
          reason: 'while the MEAN is already past it',
        );
        expect(
          best(4),
          greaterThan(retention),
          reason: 'from the thirty-fourth circle even the FLOOR of the cadence '
              'outlives the retention, so the marker is expired on every '
              'publish rather than usually — the rung the record calls out',
        );
      },
    );

    test(
      'an oversized burst sacrifices the spread budget, never the >1 s '
      'separation',
      () {
        final stagger = PublishStagger(rng: Random(5));
        // 40 circles cannot fit in 30 s at more than a second apiece.
        expect(
          stagger.maxSpreadFor(40),
          greaterThan(kPublishStaggerMaxSpread),
          reason: 'the budget is what yields',
        );
        expect(
          stagger.maxGapFor(40).inMilliseconds,
          greaterThan(1000),
          reason: 'the separation is what does not',
        );
      },
    );
  });

  group('PublishStagger.sampleGaps', () {
    test('the first publish of a burst is not delayed', () {
      final gaps = PublishStagger(rng: Random(2)).sampleGaps(5);
      expect(gaps.first, Duration.zero);
      expect(gaps.length, 5);
      for (final gap in gaps.skip(1)) {
        expect(gap.inMilliseconds, greaterThan(1000));
      }
    });

    test('a single-circle burst has no gaps to sample', () {
      expect(PublishStagger(rng: Random(2)).sampleGaps(1), [Duration.zero]);
      expect(PublishStagger(rng: Random(2)).sampleGaps(0), isEmpty);
    });

    test('two bursts of the same size do not produce the same gaps', () {
      final stagger = PublishStagger(rng: Random(9));
      final first = stagger.sampleGaps(4);
      final second = stagger.sampleGaps(4);
      expect(
        first,
        isNot(second),
        reason: 'gaps are re-sampled per burst; a burst-invariant schedule '
            'would be as linkable as no schedule at all',
      );
    });
  });

  group('PublishStagger.shuffled', () {
    test('does not always put the same circle first', () {
      final stagger = PublishStagger(rng: Random(4));
      final firsts = <String>{
        for (var i = 0; i < 100; i++)
          stagger.shuffled(<String>['a', 'b', 'c', 'd']).first,
      };
      expect(
        firsts.length,
        greaterThan(1),
        reason: 'a stable "who publishes first" is a second-order '
            'fingerprint of the same burst',
      );
    });

    test('is a permutation — no circle is dropped or duplicated', () {
      final stagger = PublishStagger(rng: Random(4));
      const input = <String>['a', 'b', 'c', 'd', 'e'];
      for (var i = 0; i < 50; i++) {
        expect(stagger.shuffled(input).toSet(), input.toSet());
        expect(stagger.shuffled(input).length, input.length);
      }
    });

    test("leaves the caller's list untouched", () {
      final input = <String>['a', 'b', 'c'];
      PublishStagger(rng: Random(4)).shuffled(input);
      expect(input, ['a', 'b', 'c']);
    });
  });

  group('PublishStagger.none', () {
    test('waits for nothing — test-only escape hatch', () {
      final stagger = PublishStagger.none();
      expect(stagger.sampleGap(), Duration.zero);
      expect(stagger.sampleGaps(4), List.filled(4, Duration.zero));
    });
  });
}
