/// Tests for [PublishStagger] — the CSPRNG delay that keeps two circles'
/// kind-445 events out of the same wall-clock second.
///
/// The property under test is NOT "a delay happens". It is that the delay is
/// (a) always more than one second, because the engine binds the outer
/// `created_at` to the inner app event's WHOLE-SECOND timestamp so sub-second
/// jitter is invisible on the wire; (b) randomised, because a constant stagger
/// is itself a fingerprint; and (c) bounded, because a location is only worth
/// sending while it is current.
library;

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/constants/location.dart';
import 'package:haven/src/services/publish_stagger.dart';

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
        // 11 is the crossover: past it the per-gap floor (minGap + 1 s, which
        // keeps the gap both >1 s and non-degenerate) no longer fits inside
        // 30 s, and the BUDGET is what yields — see [maxGapFor].
        for (var circles = 2; circles <= 11; circles++) {
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
      'a burst far beyond any plausible roster still publishes inside the '
      'GPS-fix freshness window it took its fix from',
      () {
        // The one freshness bound that is not a preference: the single fix
        // taken at burst start must still be publishable by the app's own
        // rule when the LAST circle goes out.
        //
        // 40 circles is already several times any plausible roster. Beyond
        // ~56 this must fail, and that is arithmetic rather than a defect:
        // N events more than a second apart cannot fit in under N seconds,
        // and the separation is the property being bought.
        final stagger = PublishStagger(rng: Random(13));
        expect(
          stagger.maxSpreadFor(40),
          lessThan(kStreamPositionMaxAge),
          reason: 'past this the burst would publish a fix the app itself '
              'considers too stale to send',
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
        final noGapSlack =
            const Duration(seconds: 228) - kLocationPublishMaxInterval;
        expect(kPublishStaggerMaxSpread, lessThanOrEqualTo(noGapSlack ~/ 2));
        // The single GPS fix taken at burst start must still be publishable by
        // the app's own freshness rule when the LAST circle goes out.
        expect(kPublishStaggerMaxSpread, lessThan(kStreamPositionMaxAge));
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
