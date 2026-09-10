/// The arithmetic behind the Android foreground service's ONE long-interval
/// platform location request (D3 (iii) of `docs/POWER_EFFICIENCY_PLAN.md`).
///
/// The interval is what decides whether the GNSS receiver is duty-cycled by
/// the platform (≈ 5 mA) or held on (60–85 mA) — published third-party draw
/// figures (§6.5a of the plan, E-I2/E-I1), never measured on Haven or on any
/// device this project has — and, because a publish now rides a delivery
/// instead of a software tick, it is also the only thing
/// holding every circle's realized inter-publish gap inside the 228 s NIP-40
/// retention every peer's marker depends on. Both are pure arithmetic, so both
/// are proved here by SWEEPING the parameter space rather than by examples: a
/// bound that is right at 72 s and 168 s and wrong at 101 s is exactly the
/// shape of defect a handful of cases misses.
///
/// The retention bound HOLDS on every hot fix and, on S+, on cold ones too. It
/// does not hold on API 23–30 with a cold TTFF: that regime pays two
/// acquisitions per registration, and the sweep below states the residual as
/// an equality rather than avoiding the space that finds it.
///
/// The platform half of the model is AOSP, quoted in §2.2 of the plan:
///
/// * **S+ (`LocationProviderManager`, API 31+)** — after cancel + re-listen the
///   manager delays applying the new request, and the provider hibernates until
///   `lastFix + interval`; the next fix therefore lands at `lastFix + interval`
///   plus TTFF, anchored at the LAST FIX, never at the registration instant.
/// * **API 23–30** — no delayed register: cancel + listen restarts GNSS at
///   once (one extra acquisition) and hibernates from THAT fix, so the delivery
///   lands at `registeredAt + TTFF + interval + TTFF`.
/// * Deliveries are late by TTFF, never late by the framework, and never early
///   for the request's own hibernate cycle. A fix belonging to ANOTHER consumer
///   can still pass this registration's fastest-interval gate up to 10 % of the
///   interval early — modelled here as an EXTRA delivery that does not move the
///   registration's own schedule.
///
/// SCOPE — this is not an end-to-end proof. [FgsModel] drives the real
/// scheduling primitives ([nextFixRequestInterval], [registrationIsAligned],
/// [PerCircleDueTracker], [nextBackgroundPublishSlot], [PublishStagger]) but
/// reimplements the ORDER in which the cycle calls them. Move the shipped
/// registration below the publish loop and every assertion here still passes,
/// so the retention conclusion holds for the arithmetic and for this ordering
/// — not for whatever `background_location_task.dart` does today. The shipped
/// ordering is pinned separately: behaviourally by the "registration is aimed
/// before anything is published" group in
/// `background_location_task_delivery_cycle_test.dart`, and structurally by
/// `scripts/ci/check_android_location_power.sh` check (5).
@TestOn('vm')
library;

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/constants/location.dart';
import 'package:haven/src/services/background_fix_request.dart';
import 'package:haven/src/services/per_circle_due_tracker.dart';
import 'package:haven/src/services/publish_stagger.dart';

/// `LocationProviderManager.MIN_REQUEST_DELAY_MS` (`:181`) — the threshold the
/// floor must clear, named here so the assertions read as the platform rule
/// they encode rather than as a number.
const Duration kMinRequestDelay = Duration(seconds: 30);

/// `LOCATION_MESSAGE_RETENTION_SECS` (228 s), the NIP-40 lifetime the engine
/// stamps on every kind-445. A realized gap at or past it is a marker that
/// expires at every peer.
const Duration kLocationMessageRetention = Duration(
  seconds: 168 + 2 * kTtlNetworkBufferSeconds,
);

/// The two AOSP delivery regimes the gap proof is stated over.
enum Api { sPlus, legacy }

/// When the platform delivers the fix a registration issued at [registeredAt]
/// for [interval] asks for.
///
/// [early] is the fraction of the interval a foreign consumer's fix may be
/// accepted ahead of schedule (the fastest-interval gate's 10 % band).
DateTime deliveryAt({
  required Api api,
  required DateTime lastFixAt,
  required DateTime registeredAt,
  required Duration interval,
  required Duration ttff,
  double early = 0,
}) {
  final spacing = interval * (1 - early);
  return switch (api) {
    Api.sPlus => lastFixAt.add(spacing).add(ttff),
    Api.legacy => registeredAt.add(ttff).add(spacing).add(ttff),
  };
}

DateTime _later(DateTime a, DateTime b) => a.isAfter(b) ? a : b;

Duration _atLeastZero(Duration d) => d.isNegative ? Duration.zero : d;

void main() {
  final t0 = DateTime.utc(2026, 1, 1, 12);

  group('nextFixRequestInterval', () {
    test('targets the earliest due minus the fix lead', () {
      // The whole point of the lead: the fix is asked for BEFORE the due, so
      // the acquisition and the encrypt happen inside it and the publish lands
      // on the due-time rather than a TTFF after it.
      expect(
        nextFixRequestInterval(
          earliestDue: t0.add(const Duration(seconds: 120)),
          now: t0,
          plannedPublishStart: t0,
        ),
        const Duration(seconds: 110),
      );
    });

    test('never requests an interval at or below MIN_REQUEST_DELAY_MS (30 s) '
        '— the floor is kMinFixRequestInterval', () {
      // At or below MIN_REQUEST_DELAY_MS the S+ manager treats the request as
      // continuous HIGH_ACCURACY and delivers no historical fix: the receiver
      // never sleeps, which is the drain this phase exists to remove. Swept
      // across every aim from a minute overdue to a minute out, because the
      // floor has to hold for an aim in the PAST (an overdue circle) as much
      // as for one just under the threshold.
      var points = 0;
      String? violation;
      for (var ms = -60000; ms <= 60000 && violation == null; ms += 100) {
        final interval = nextFixRequestInterval(
          earliestDue: t0.add(Duration(milliseconds: ms)),
          now: t0,
          plannedPublishStart: t0,
        );
        points++;
        if (interval <= kMinRequestDelay) {
          violation = 'INV-FLOOR: aim at ${ms}ms gave $interval, which the '
              'S+ manager would run as a continuous request';
        } else if (interval < kMinFixRequestInterval) {
          violation = 'INV-FLOOR: aim at ${ms}ms gave $interval, below '
              'kMinFixRequestInterval';
        }
      }
      expect(violation, isNull, reason: violation ?? '');
      expect(points, 1201, reason: 'the sweep must actually have run');
    });

    test('the initial registration after a publish asks for at least '
        'kLocationPublishMinInterval − kBackgroundFixLeadTime', () {
      // The registration is issued BEFORE the cycle's publishes, so `now` sits
      // at or before the planned publish start and the circle being published
      // re-arms to that start plus a sampled interval of at least 72 s. 62 s is
      // therefore the smallest request a healthy single-circle cycle can make
      // — the bound the B1 lane's `dumpsys location` oracle asserts.
      const floor = Duration(seconds: 62);
      expect(floor, kLocationPublishMinInterval - kBackgroundFixLeadTime);

      var points = 0;
      String? violation;
      for (
        var j = kLocationPublishMinInterval.inSeconds;
        j <= kLocationPublishMaxInterval.inSeconds && violation == null;
        j++
      ) {
        for (var ahead = 0; ahead <= 30; ahead++) {
          final publishStart = t0.add(Duration(seconds: ahead));
          final interval = nextFixRequestInterval(
            earliestDue: publishStart.add(Duration(seconds: j)),
            now: t0,
            plannedPublishStart: publishStart,
          );
          points++;
          if (interval < floor) {
            violation = 'INV-62: J=${j}s with the registration ${ahead}s '
                'ahead of the publish asked for $interval';
            break;
          }
        }
      }
      expect(violation, isNull, reason: violation ?? '');
      expect(points, 97 * 31);
    });

    test('a second circle due between 31 s and 71 s after a publish gets its '
        'own fix at its due − lead', () {
      // M-9: the floor is a PLATFORM bound, never a cadence bound. Anchoring
      // it at the last publish (62 s, or the 72 s a reviewer proposed) starves
      // a sibling whose own independent cadence falls inside that window — by
      // up to 41 s, i.e. a 219–239 s realized gap, past the retention.
      var points = 0;
      var worstLateness = Duration.zero;
      String? violation;
      for (var ms = 30000; ms <= 82000 && violation == null; ms += 100) {
        final siblingDue = t0.add(Duration(milliseconds: ms));
        final interval = nextFixRequestInterval(
          earliestDue: siblingDue,
          now: t0,
          plannedPublishStart: t0,
        );
        points++;
        final want = _atLeastZero(
          siblingDue.difference(t0) - kBackgroundFixLeadTime,
        );
        final expected = want < kMinFixRequestInterval
            ? kMinFixRequestInterval
            : want;
        if (interval != expected) {
          violation = 'INV-M9: a sibling due ${ms}ms out was aimed at '
              '$interval instead of $expected';
          break;
        }
        final lateness = _atLeastZero(t0.add(interval).difference(siblingDue));
        if (lateness > worstLateness) worstLateness = lateness;
      }
      expect(violation, isNull, reason: violation ?? '');
      expect(points, 521);
      expect(
        worstLateness,
        kMinFixRequestInterval - kBackgroundFixHorizon,
        reason: 'INV-M9: the ONLY starvation the floor may cause is the '
            'one-second stretch between the horizon (the latest due a cycle '
            'leaves unpublished) and the platform floor. A 62 s floor makes '
            'this 32 s, a 72 s floor 42 s — a realized gap past the retention',
      );
    });

    test('a far-future due can silence GNSS for no more than one max publish '
        'interval', () {
      // A forward device-clock jump between `markBurstPublished` and the
      // next cycle (or a due-time restored from a stale schedule) puts the
      // aim hours out.
      // Without the cap the FGS would register once for that aim and take no
      // fix until it arrived — the silent-stop class this plan exists to close.
      for (final ahead in const [
        Duration(seconds: 169),
        Duration(minutes: 5),
        Duration(hours: 3),
      ]) {
        // Swept over where the cycle's first publish sits relative to the
        // registration, because the two halves of the ceiling bind in
        // different places: the registration instant bounds how long the
        // receiver may sleep, the publish start bounds the gap that follows it.
        for (final ahead0 in const [
          Duration.zero,
          Duration(seconds: 10),
          kPublishStaggerMaxSpread,
        ]) {
          final publishStart = t0.add(ahead0);
          final interval = nextFixRequestInterval(
            earliestDue: t0.add(ahead),
            now: t0,
            plannedPublishStart: publishStart,
          );
          expect(
            interval,
            lessThanOrEqualTo(kLocationPublishMaxInterval),
            reason: 'INV-CAP: an aim $ahead out with the publish $ahead0 later '
                'must still take a fix inside one max publish interval',
          );
          // ...and tightly enough that the publish which follows that fix is
          // still inside kLocationPublishMaxInterval of the publish it follows
          // — the ceiling keeps the lead available to absorb TTFF.
          //
          // Compared with `isAfter` rather than `lessThanOrEqualTo`, which is
          // only an equality test on DateTime in this matcher version.
          final publishAfterFix = t0.add(interval).add(kBackgroundFixLeadTime);
          final ceiling = publishStart.add(kLocationPublishMaxInterval);
          expect(
            publishAfterFix.isAfter(ceiling),
            isFalse,
            reason: 'INV-CAP: an aim $ahead out with the publish $ahead0 later '
                'scheduled its fix at $publishAfterFix, past $ceiling — the '
                'ceiling must leave the lead intact',
          );
        }
      }
    });

    test('the registration must be issued within kBackgroundFixHorizon − '
        'kBackgroundFixLeadTime of the fix that triggered the cycle', () {
      // Registering LATE in the cycle is not merely untidy: the interval is
      // measured from `now`, while the S+ provider re-anchors on the last fix,
      // so every second between the delivery and the registration pulls the
      // next delivery a second further ahead of the due it was aimed at. Past
      // `horizon − lead` (20 s) the fix lands outside `dueKeysUpTo`'s window,
      // the cycle publishes nothing and pays another acquisition.
      const j = Duration(seconds: 120);
      for (var rho = 0; rho <= 30; rho++) {
        final fixAt = t0;
        final now = fixAt.add(Duration(seconds: rho));
        final publishStart = now;
        final due = publishStart.add(j);
        final interval = nextFixRequestInterval(
          earliestDue: due,
          now: now,
          plannedPublishStart: publishStart,
        );
        // S+ anchors the next delivery at the last fix, not at `now`.
        final delivery = fixAt.add(interval);
        final insideHorizon = !delivery
            .add(kBackgroundFixHorizon)
            .isBefore(due);
        expect(
          insideHorizon,
          rho <= (kBackgroundFixHorizon - kBackgroundFixLeadTime).inSeconds,
          reason: 'INV-REGISTER-EARLY: with a ${rho}s gate delay the fix lands '
              '${due.difference(delivery)} before its due, and the horizon is '
              '$kBackgroundFixHorizon',
        );
      }
    });
  });

  group('registrationIsAligned', () {
    test('tolerates kRegistrationSlack and no more', () {
      // The loop breaker: a re-registration costs a cancel + listen and, on
      // S+, re-delivers the fix just consumed. A target that moved by a second
      // must therefore NOT re-register; one that moved past the slack must.
      final target = t0.add(const Duration(seconds: 100));
      for (final sign in const [1, -1]) {
        expect(
          registrationIsAligned(
            target.add(kRegistrationSlack * sign),
            target,
          ),
          isTrue,
          reason: 'exactly the slack is still aligned (sign $sign)',
        );
        final past = kRegistrationSlack * sign + Duration(milliseconds: sign);
        expect(
          registrationIsAligned(target.add(past), target),
          isFalse,
          reason: 'a millisecond past the slack is a re-aim (sign $sign)',
        );
      }
      expect(registrationIsAligned(target, target), isTrue);
    });
  });

  group('the realized inter-publish gap', () {
    // Timeline of one circle, anchored on the publish whose gap is measured:
    //
    //   lastFix ──rho──▶ registration ──sigma──▶ publish (t = 0) ... due = J
    //
    // `rho` is the delivery→registration latency (the gates), `sigma` the
    // registration→publish latency (fix read, stagger, encrypt). The next
    // cycle runs the same code path, so the same rho + sigma sits between its
    // delivery and this circle's next publish, and the slot rule never lets a
    // circle publish before its own due-time.
    ({Duration gap, Duration interval}) run({
      required Api api,
      required int j,
      required int ttff,
      required int rho,
      required int sigma,
      int? ceiling,
    }) {
      final publish = t0;
      final registeredAt = publish.subtract(Duration(seconds: sigma));
      final lastFixAt = registeredAt.subtract(Duration(seconds: rho));
      final due = publish.add(Duration(seconds: j));
      var interval = nextFixRequestInterval(
        earliestDue: due,
        now: registeredAt,
        plannedPublishStart: publish,
      );
      // The one lever that closes the cold residual, applied HERE rather than
      // inside `nextFixRequestInterval` because it is costed below, not
      // shipped. A third bound in the shipped function would have to be
      // gated on the API level, which nothing in this app can read.
      if (ceiling != null && interval.inSeconds > ceiling) {
        interval = Duration(seconds: ceiling);
      }
      final delivery = deliveryAt(
        api: api,
        lastFixAt: lastFixAt,
        registeredAt: registeredAt,
        interval: interval,
        ttff: Duration(seconds: ttff),
      );
      final nextPublish = _later(
        due,
        delivery.add(Duration(seconds: rho + sigma)),
      );
      return (gap: nextPublish.difference(publish), interval: interval);
    }

    test('never exceeds kLocationPublishMaxInterval for a hot fix', () {
      // EXHAUSTIVE over the space D3 (iii) states the proof on: both API
      // models × every sampled interval × every hot TTFF × every split of the
      // in-cycle latency. `rho` stops at `horizon − lead` because past it the
      // fix lands outside the due window (pinned by INV-REGISTER-EARLY above)
      // and the cycle's answer is another acquisition, not a late publish.
      final maxRho = (kBackgroundFixHorizon - kBackgroundFixLeadTime).inSeconds;
      var points = 0;
      var worst = Duration.zero;
      String? violation;
      outer:
      for (final api in Api.values) {
        for (
          var j = kLocationPublishMinInterval.inSeconds;
          j <= kLocationPublishMaxInterval.inSeconds;
          j++
        ) {
          for (var ttff = 0; ttff <= kBackgroundFixLeadTime.inSeconds; ttff++) {
            for (var rho = 0; rho <= maxRho; rho++) {
              for (
                var sigma = 0;
                sigma + rho <= kPublishStaggerMaxSpread.inSeconds;
                sigma++
              ) {
                final r = run(
                  api: api,
                  j: j,
                  ttff: ttff,
                  rho: rho,
                  sigma: sigma,
                );
                points++;
                if (r.gap > worst) worst = r.gap;

                // What the lead buys, stated as the bound it buys: TTFF plus
                // the registration→publish latency (twice the TTFF on the
                // legacy regime, which acquires once to register and once to
                // deliver) comes out of the lead, and only the excess reaches
                // the gap.
                final spent = api == Api.sPlus
                    ? ttff + sigma
                    : 2 * ttff + rho + sigma;
                final bound =
                    Duration(seconds: j) +
                    _atLeastZero(
                      Duration(seconds: spent) - kBackgroundFixLeadTime,
                    );
                if (r.gap > bound) {
                  violation =
                      'INV-LEAD: $api J=${j}s TTFF=${ttff}s rho=${rho}s '
                      'sigma=${sigma}s realized ${r.gap} > $bound';
                  break outer;
                }
                if (spent <= kBackgroundFixLeadTime.inSeconds &&
                    r.gap > kLocationPublishMaxInterval) {
                  violation =
                      'INV-CADENCE: $api J=${j}s TTFF=${ttff}s rho=${rho}s '
                      'sigma=${sigma}s realized ${r.gap}, past the jitter '
                      'ceiling $kLocationPublishMaxInterval with the lead '
                      'unspent';
                  break outer;
                }
                if (r.gap >= kLocationMessageRetention) {
                  violation =
                      'INV-TTL: $api J=${j}s TTFF=${ttff}s rho=${rho}s '
                      'sigma=${sigma}s realized ${r.gap}, at or past the '
                      '$kLocationMessageRetention retention — the marker '
                      'expires at every peer';
                  break outer;
                }
                if (r.interval <= kMinRequestDelay) {
                  violation = 'INV-FLOOR: $api J=${j}s rho=${rho}s '
                      'sigma=${sigma}s asked for ${r.interval}';
                  break outer;
                }
              }
            }
          }
        }
      }
      expect(violation, isNull, reason: violation ?? '');
      expect(points, 2 * 97 * 11 * 441, reason: 'the sweep must have run');
      expect(
        worst,
        lessThan(kLocationMessageRetention),
        reason: 'the worst hot-fix gap in the whole space stays inside the '
            'retention',
      );
    });

    test('a cold TTFF outruns the lead, and on API ≤ 30 it outruns the '
        'retention as well — the residual, exactly', () {
      // A cold acquisition (the plan sizes it at the one-shot ceiling, 30 s)
      // swept over the SAME rho/sigma space as the hot proof above. That
      // matters more than it looks: this half used to run only at
      // rho = sigma = 0, so the two halves of one statement disagreed about
      // the space they covered, and the cold bound held by avoiding the part
      // its sibling proved on.
      //
      // Swept honestly, the two API regimes part company:
      //
      //  * S+ stays inside the retention everywhere. The provider re-anchors
      //    on the LAST FIX, so the in-cycle latency (rho + sigma) is spent
      //    before the anchor rather than after it and only ONE acquisition is
      //    paid for. Worst realized gap 198 s, 30 s of headroom left.
      //  * API 23–30 does not. Cancel + listen restarts GNSS immediately, so
      //    the regime pays TWO acquisitions per registration: 60 s of cold
      //    TTFF against a 10 s lead, while the jitter ceiling leaves only
      //    228 − 168 = 60 s of headroom under the retention. Every second of
      //    in-cycle latency past the lead is therefore a second past the
      //    retention.
      //
      // The residual is stated as an EQUALITY on both the worst gap and the
      // breach SET, not as a "stays under" that a future change could satisfy
      // by moving the goalposts: a peer's kind-445 expires `worstOverrun`
      // before its replacement lands, so the marker disappears for that long
      // and comes back on the next publish. Nothing is lost and no AP suspend
      // is involved — but it is real and it is not proved away. The lever
      // that WOULD close it, and the reason it is not taken, are costed in
      // the test below rather than asserted in prose.
      const cold = 30;
      // The breach threshold, as the sum that decides it. Derivation: on
      // legacy the next publish lands at `2·TTFF + rho + interval`, and the
      // interval is `min(J − lead + sigma, max)`, so the gap reaches the
      // retention exactly when J + rho + sigma ≥ 228 − 2·30 + 10.
      const breachAtSum = 178;
      final maxRho = (kBackgroundFixHorizon - kBackgroundFixLeadTime).inSeconds;
      var points = 0;
      final worst = {for (final api in Api.values) api: Duration.zero};
      var minBreachLatency = 1 << 30;
      String? violation;
      outer:
      for (final api in Api.values) {
        for (
          var j = kLocationPublishMinInterval.inSeconds;
          j <= kLocationPublishMaxInterval.inSeconds;
          j++
        ) {
          for (var rho = 0; rho <= maxRho; rho++) {
            for (
              var sigma = 0;
              sigma + rho <= kPublishStaggerMaxSpread.inSeconds;
              sigma++
            ) {
              final r = run(api: api, j: j, ttff: cold, rho: rho, sigma: sigma);
              points++;
              if (r.gap > worst[api]!) worst[api] = r.gap;

              final breached = r.gap >= kLocationMessageRetention;
              if (breached && rho + sigma < minBreachLatency) {
                minBreachLatency = rho + sigma;
              }
              final expected =
                  api == Api.legacy && j + rho + sigma >= breachAtSum;
              if (breached != expected) {
                violation =
                    'INV-COLD-TTL: $api J=${j}s rho=${rho}s sigma=${sigma}s '
                    'realized ${r.gap}, ${breached ? "at or past" : "inside"} '
                    'the $kLocationMessageRetention retention — the residual '
                    'is J + rho + sigma >= ${breachAtSum}s on legacy and '
                    'nothing on S+';
                break outer;
              }
              if (r.interval <= kMinRequestDelay) {
                violation = 'INV-FLOOR: $api J=${j}s rho=${rho}s '
                    'sigma=${sigma}s asked for ${r.interval}';
                break outer;
              }
            }
          }
        }
      }
      expect(violation, isNull, reason: violation ?? '');
      expect(points, 2 * 97 * 441, reason: 'the sweep must have run');

      expect(
        worst[Api.sPlus],
        const Duration(seconds: 198),
        reason: 'INV-COLD: on S+ a cold acquisition costs the gap TTFF minus '
            'the lead and nothing else, so it stays 30 s clear of the '
            'retention',
      );
      expect(
        worst[Api.legacy],
        const Duration(seconds: 248),
        reason: 'INV-COLD: two cold acquisitions plus the full in-cycle '
            'latency, on top of the longest jittered interval',
      );
      // The user-visible size of the residual: how long a peer's marker is
      // absent in the worst case, which is the number the disclosure and the
      // power plan have to quote.
      final worstOverrun = worst[Api.legacy]! - kLocationMessageRetention;
      expect(
        worstOverrun,
        const Duration(seconds: 20),
        reason: 'the marker expires this long before its replacement lands, '
            'once, on the worst point of the legacy space',
      );
      // ...and what it costs to GET there, which is the other half of how big
      // this is. `J` is capped at the jitter ceiling, so no unlucky interval
      // reaches the breach on its own.
      expect(
        minBreachLatency,
        breachAtSum - kLocationPublishMaxInterval.inSeconds,
        reason: 'the residual is unreachable below this much in-cycle '
            'latency. A single-circle cycle spends about a second there '
            '(encrypt plus the slot); ten needs a multi-circle decorrelation '
            'burst, on top of a receiver cold enough to pay a 30 s TTFF',
      );
    });

    test('the ceiling that would close the residual, and the acquisition it '
        'would waste — why it is not taken', () {
      // The decision this file's residual rests on, kept as arithmetic rather
      // than as a claim in a plan, so that moving the retention, the jitter
      // ceiling, the horizon or the lead re-opens it instead of silently
      // invalidating it.
      //
      // The lever is a ceiling on the requested interval, applied ONLY on API
      // 23-30. Gating it is free on S+ by construction — an API branch costs
      // the majority regime nothing — so the reason it is not shipped is NOT
      // that it would slow the receiver down everywhere. It is (a) that
      // nothing in this app can read `Build.VERSION.SDK_INT`: the consumer is
      // the foreground-service isolate, whose engine is created without an
      // Activity, so the read would be a second native channel installed from
      // `HavenApplication.onCreate`, cached across an async hop, threaded
      // into `background_fix_request.dart` — which is pure precisely so this
      // proof can be a sweep — and held by new source guards, because there
      // are no JVM tests here; and (b) that the ceiling is not free on the
      // cohort it protects either, which is the arithmetic below.
      const cold = 30;
      final maxRho = (kBackgroundFixHorizon - kBackgroundFixLeadTime).inSeconds;
      final ceiling =
          kLocationMessageRetention.inSeconds - 2 * cold - maxRho - 1;
      expect(
        ceiling,
        147,
        reason: 'derived, not chosen: on legacy the next publish lands at '
            '2*TTFF + interval + rho, so the interval has to leave a second '
            'of room under the retention once both cold acquisitions and the '
            'widest gate latency are paid',
      );

      var points = 0;
      var worst = Duration.zero;
      String? violation;
      outer:
      for (final api in Api.values) {
        for (
          var j = kLocationPublishMinInterval.inSeconds;
          j <= kLocationPublishMaxInterval.inSeconds;
          j++
        ) {
          for (var rho = 0; rho <= maxRho; rho++) {
            for (
              var sigma = 0;
              sigma + rho <= kPublishStaggerMaxSpread.inSeconds;
              sigma++
            ) {
              final r = run(
                api: api,
                j: j,
                ttff: cold,
                rho: rho,
                sigma: sigma,
                ceiling: ceiling,
              );
              points++;
              if (r.gap > worst) worst = r.gap;
              if (r.gap >= kLocationMessageRetention) {
                violation =
                    'INV-CEILING: $api J=${j}s rho=${rho}s sigma=${sigma}s '
                    'realized ${r.gap} under a ${ceiling}s ceiling, still at '
                    'or past the $kLocationMessageRetention retention';
                break outer;
              }
              if (r.interval <= kMinRequestDelay) {
                violation = 'INV-FLOOR: $api J=${j}s rho=${rho}s '
                    'sigma=${sigma}s asked for ${r.interval}';
                break outer;
              }
            }
          }
        }
      }
      expect(violation, isNull, reason: violation ?? '');
      expect(points, 2 * 97 * 441, reason: 'the sweep must have run');
      expect(
        worst,
        const Duration(seconds: 227),
        reason: 'the ceiling empties the breach set outright — one second of '
            'headroom on the worst legacy point, by construction',
      );

      // And the cost, in the same arithmetic. The ceiling does not move a
      // due-time, only a delivery: the slot rule never publishes a circle
      // before its due, so a fix that lands early WAITS, and the next
      // registration — issued at that earlier instant — asks for a longer
      // interval, which the ceiling cuts again. Fix age therefore walks
      // `age <- J + age - ceiling` instead of self-correcting to the lead,
      // and ONE step from the steady state at the top of the jitter band
      // already puts the next delivery outside the window a fix can serve.
      final ageAfterOneCappedStep =
          kBackgroundFixLeadTime +
          kLocationPublishMaxInterval -
          Duration(seconds: ceiling);
      expect(
        ageAfterOneCappedStep,
        greaterThan(kBackgroundFixHorizon),
        reason: 'a delivery that far ahead of every due-time selects no '
            'circle at all, so the acquisition it woke the receiver for is '
            'spent for nothing — on the same API 23-30 devices, and on HOT '
            'fixes rather than only on the cold ones the residual needs',
      );
    });

    test('a fix accepted up to 10 % early never publishes a circle before its '
        'due-time, and deliveries stay at least 55 s apart', () {
      // The 10 % band is what the fastest-interval gate would ACCEPT from a
      // foreign consumer's fix, not what this registration's own hibernate
      // cycle emits. An accepted early fix cannot pull a publish forward — the
      // slot rule floors every publish at the circle's own due-time — and the
      // spacing it leaves between deliveries is the bound the B1 lane asserts
      // on `cycle trigger=delivery` markers.
      final b1Bound = Duration(
        seconds:
            (0.9 *
                    (kLocationPublishMinInterval - kBackgroundFixLeadTime)
                        .inSeconds)
                .floor(),
      );
      expect(b1Bound, const Duration(seconds: 55));

      var points = 0;
      String? violation;
      outer:
      for (
        var j = kLocationPublishMinInterval.inSeconds;
        j <= kLocationPublishMaxInterval.inSeconds;
        j++
      ) {
        for (var ttff = 0; ttff <= kBackgroundFixLeadTime.inSeconds; ttff++) {
          final publish = t0;
          final due = publish.add(Duration(seconds: j));
          final interval = nextFixRequestInterval(
            earliestDue: due,
            now: publish,
            plannedPublishStart: publish,
          );
          final early = deliveryAt(
            api: Api.sPlus,
            lastFixAt: publish,
            registeredAt: publish,
            interval: interval,
            ttff: Duration(seconds: ttff),
            early: 0.1,
          );
          points++;
          // The slot rule (`nextBackgroundPublishSlot`) never returns a slot
          // before the circle's own due-time, so the earliest the circle can
          // publish on that fix is the due itself.
          final slot = nextBackgroundPublishSlot(
            dueAt: due,
            lastPublishStartedAt: null,
            gap: kPublishStaggerMinGap,
            phaseStart: early,
            deadline: early.add(kPublishStaggerMaxSpread),
          );
          if (slot != null && slot.isBefore(due)) {
            violation = 'INV-EARLY: J=${j}s TTFF=${ttff}s published at $slot, '
                'before its due $due';
            break outer;
          }
          final spacing = early.difference(publish);
          if (spacing < b1Bound) {
            violation = 'INV-EARLY-SPACING: J=${j}s TTFF=${ttff}s left '
                '$spacing between deliveries, under the $b1Bound the B1 '
                'oracle asserts';
            break outer;
          }
        }
      }
      expect(violation, isNull, reason: violation ?? '');
      expect(points, 97 * 11);
    });
  });

  group('a modelled foreground-service run', () {
    test('holds every circle inside the retention for every circle count and '
        'every sampled interval', () {
      var configs = 0;
      String? violation;
      outer:
      for (final api in Api.values) {
        for (var circles = 1; circles <= 8; circles++) {
          for (final ttff in const [0, 5, 10]) {
            for (final rho in const [0, 3]) {
              for (final early in const [false, true]) {
                final sim = FgsModel(
                  api: api,
                  ttff: Duration(seconds: ttff),
                  gateDelay: Duration(seconds: rho),
                  circleCount: circles,
                  start: t0,
                  foreignEarlyFix: early,
                )..run(deliveries: 120 * circles);
                configs++;

                final label =
                    '$api n=$circles TTFF=${ttff}s rho=${rho}s '
                    'early=$early';
                if (sim.gaps.isEmpty) {
                  violation = 'VACUOUS: $label recorded no gap at all';
                  break outer;
                }
                if (early && sim.foreignDeliveries == 0) {
                  violation = 'VACUOUS: $label never injected a foreign early '
                      'fix, so the 10 % band went untested';
                  break outer;
                }
                if (sim.drawsPerCircle < 97) {
                  violation = 'VACUOUS: $label swept only '
                      '${sim.drawsPerCircle} of the 97 sampled intervals';
                  break outer;
                }
                if (sim.worstGap >= kLocationMessageRetention) {
                  violation = 'INV-TTL: $label realized ${sim.worstGap}, at or '
                      'past the $kLocationMessageRetention retention';
                  break outer;
                }
                if (sim.shortestGap < kLocationPublishMinInterval) {
                  violation = 'INV-CADENCE-FLOOR: $label realized '
                      '${sim.shortestGap}, under the disclosed minimum '
                      '$kLocationPublishMinInterval';
                  break outer;
                }
                if (sim.smallestInterval <= kMinRequestDelay) {
                  violation = 'INV-FLOOR: $label asked the platform for '
                      '${sim.smallestInterval}';
                  break outer;
                }
                // One tick, one burst: EVERY circle publishes in EVERY
                // cycle that publishes at all, so the device wakes its radio
                // once per interval rather than once per circle. Swept to 8
                // circles, on this registration's OWN deliveries, and exact
                // for every API regime, TTFF and gate delay here — 1.00 cycles
                // per circle-interval at each of them.
                //
                // It was NOT exact while every circle carried its own due:
                // the dues drifted apart by the stagger the burst spent, the
                // selection window (`kBackgroundFixHorizon` less the lead the
                // fix is aimed ahead by) eventually failed to span them, and
                // the roster split across two cycles — 2.2 circles per cycle
                // at n = 4 rising to 5.7 at n = 12, i.e. 1.8-2.1 cycles per
                // circle-interval and 54-63 wakes an hour instead of 30. One
                // shared due (`nextBurstDue`) and a deadline anchored at the
                // burst's first PUBLISH rather than at the cycle start are
                // what close both halves of that.
                //
                // Past the budget the split is deliberate, so the sweep stops
                // at 8: from 12 circles the 3 s per-gap floor needs 33 s of
                // spread, the cycle cuts whatever will not fit inside the 30 s
                // budget, and the cut circle waits for the NEXT delivery. This
                // model's own worst realized gap at n = 12 — driven on the same
                // grid, outside the swept range — is ~310 s, past the 228 s
                // retention, which is why 12 is not asserted here.
                //
                // That is NOT the timer planes' service-period ladder (336 s
                // scheduled at n = 12, 366 s with the burst-position
                // differential, `kMaxCirclesPerBurst`). Different mechanism:
                // this plane cuts on the SPREAD and re-serves on the next
                // delivery, where a timer-driven burst defers a whole slice for
                // `ceil(N / kMaxCirclesPerBurst)` bursts. Neither figure may be
                // used to "correct" the other.
                if (!early && sim.minPerServingCycle != circles) {
                  violation = 'INV-COALESCE: $label served a cycle with '
                      '${sim.minPerServingCycle} of $circles circles — every '
                      'roster inside the burst budget must publish in ONE '
                      'burst per interval';
                  break outer;
                }
                if (sim.servingCycles == 0) {
                  violation = 'VACUOUS: $label never published in a scheduled '
                      'cycle at all';
                  break outer;
                }
                // Two named terms, never one slack number. A burst pushes a
                // circle past its due by the stagger budget it spends to
                // decorrelate `created_at`s (the 30 s the retention's 60 s
                // margin is sized for) and by however late the DELIVERY
                // itself was — an acquisition the lead was meant to cover,
                // paid twice on the regime with no delayed register, of which
                // only the excess reaches the wire.
                //
                // The stagger term is the full spread in BOTH directions now
                // that a burst re-arms onto one shared due (`nextBurstDue`):
                // the permutation is live every burst, so a circle can lead
                // one and trail the next. Per-circle dues made that term
                // converge to zero instead — by freezing the order, which is
                // the archive fingerprint the shuffle exists to prevent.
                final spent = api == Api.sPlus ? ttff : 2 * ttff + rho;
                final lateness = Duration(
                  seconds: max(0, spent - kBackgroundFixLeadTime.inSeconds),
                );
                final burstCeiling = kLocationPublishMaxInterval +
                    kPublishStaggerMaxSpread +
                    lateness;
                if (sim.worstGap > burstCeiling) {
                  violation = 'INV-STAGGER-BOUND: $label realized '
                      '${sim.worstGap}, past the $burstCeiling a decorrelated '
                      'burst can cost';
                  break outer;
                }
                // With no sibling to stagger against and the lead still
                // covering the acquisition (twice over on the legacy regime,
                // which acquires once to register and once to deliver), the
                // gap must not leave the jitter band at all.
                if (circles == 1 &&
                    spent <= kBackgroundFixLeadTime.inSeconds &&
                    sim.worstGap > kLocationPublishMaxInterval) {
                  violation = 'INV-CADENCE: $label realized ${sim.worstGap} '
                      'with no sibling to stagger against and the lead unspent';
                  break outer;
                }
              }
            }
          }
        }
      }
      expect(violation, isNull, reason: violation ?? '');
      expect(configs, 2 * 8 * 3 * 2 * 2);
    });
  });
}

/// A deterministic model of one FGS publish cycle driving the real scheduling
/// primitives ([nextFixRequestInterval], [registrationIsAligned],
/// [PerCircleDueTracker], [nextBackgroundPublishSlot], [PublishStagger]) with
/// the AOSP delivery schedule modelled around them.
///
/// Nothing here reads a clock: every instant is derived from [start], so the
/// run is identical on every machine.
class FgsModel {
  FgsModel({
    required this.api,
    required this.ttff,
    required this.gateDelay,
    required int circleCount,
    required this.start,
    this.foreignEarlyFix = false,
  }) : circles = [for (var i = 0; i < circleCount; i++) 'circle-$i'];

  final Api api;

  /// Time to first fix once the receiver starts searching.
  final Duration ttff;

  /// Delivery → registration: the cycle's gates, before anything is published.
  final Duration gateDelay;

  final List<String> circles;
  final DateTime start;

  /// Whether a foreign consumer's fix is accepted 10 % of the interval early
  /// (an EXTRA delivery; it does not move this registration's own schedule).
  final bool foreignEarlyFix;

  final _tracker = PerCircleDueTracker();
  // A real distribution, seeded so the run is reproducible.
  final _stagger = PublishStagger(rng: Random(7));
  final _lastPublish = <String, DateTime>{};
  final _publishes = <String, int>{};

  final gaps = <Duration>[];

  DateTime? _registeredTarget;
  late DateTime _lastFixAt;
  Duration _interval = kLocationPublishMaxInterval;
  // Assigned by the first cycle, which always registers: it has no prior
  // target to be aligned with.
  late DateTime _nextDelivery;
  var _reRegistered = false;

  /// How many foreign consumers' fixes were accepted ahead of schedule.
  int foreignDeliveries = 0;

  /// Cycles that published something, and the fewest circles any of them
  /// published — the wake count coalescing is about, on the plane where the
  /// selection window rather than the timer decides it.
  ///
  /// Counted over SCHEDULED cycles only. A foreign consumer's early fix is an
  /// extra delivery Haven did not ask for, and one that serves an already
  /// overdue circle is a bonus rather than a wake this cadence paid for.
  int servingCycles = 0;
  int? minPerServingCycle;

  Duration worstGap = Duration.zero;
  Duration shortestGap = kLocationMessageRetention;
  Duration smallestInterval = kLocationPublishMaxInterval;

  /// How many of the 97 possible sampled intervals every circle has used.
  int get drawsPerCircle => circles
      .map((c) => min(_publishes[c] ?? 0, 97))
      .reduce((a, b) => a < b ? a : b);

  /// Walks all 97 sampled intervals, one draw per CYCLE.
  ///
  /// Shared across the burst exactly as production shares it: an independent
  /// draw per circle would pull the roster back into a wake apiece, which is
  /// the cost coalescing removed.
  int _sampledInterval() =>
      kLocationPublishMinInterval.inSeconds + (_cycles % 97);

  int _cycles = 0;
  bool _foreignCycle = false;

  void run({required int deliveries}) {
    for (final key in circles) {
      _tracker.seedIfAbsent(key, start);
    }
    var fixAt = start;
    for (var i = 0; i < deliveries; i++) {
      _cycle(fixAt);
      if (!_reRegistered) {
        // The live registration hibernates until `lastFix + interval` and then
        // spends a TTFF acquiring.
        _nextDelivery = fixAt.add(_interval).add(ttff);
      }
      final scheduled = _nextDelivery;
      if (foreignEarlyFix) {
        final foreign = scheduled.subtract(_interval * 0.1);
        if (foreign.isAfter(fixAt)) {
          foreignDeliveries++;
          _foreignCycle = true;
          _cycle(foreign);
          _foreignCycle = false;
          // A cycle that kept its registration leaves the platform's own
          // schedule alone; one that re-aimed replaced it.
          if (!_reRegistered) _nextDelivery = scheduled;
        }
      }
      fixAt = _nextDelivery;
    }
  }

  void _cycle(DateTime fixAt) {
    _lastFixAt = fixAt;
    _reRegistered = false;
    final now = fixAt.add(gateDelay);
    final phaseStart = now;
    _cycles++;

    // Shuffled in, as production does: a burst's circles are due in the same
    // instant, so the tie-break is the publish order, and the worst realized
    // gap belongs to a circle that moves from the front of one burst to the
    // back of the next.
    final dueKeys = _tracker.dueKeysUpTo(
      _stagger.shuffled(circles),
      now.add(kBackgroundFixHorizon),
    );
    // Pre-sampled before the registration, so the aim is the interval the
    // burst will actually be re-armed on.
    final sampled = _sampledInterval();

    final planned = <String, DateTime>{};
    DateTime? lastStart;
    DateTime? firstStart;
    for (final key in dueKeys) {
      final slot = nextBackgroundPublishSlot(
        dueAt: _tracker.dueAt(key),
        lastPublishStartedAt: lastStart,
        gap: _stagger.sampleGap(totalPublishes: dueKeys.length),
        phaseStart: phaseStart,
        // Anchored at the burst's first publish, as the cycle anchors it: the
        // fix is delivered a lead-time BEFORE the due it was taken for, so a
        // deadline measured from the cycle start hands the burst only
        // `30 s − lead` of its own budget.
        deadline: (firstStart ?? phaseStart).add(kPublishStaggerMaxSpread),
      );
      // The cycle stops at its budget and leaves the rest due, rather than
      // compressing the gaps it is spending to decorrelate.
      if (slot == null) break;
      final at = _later(slot, phaseStart);
      planned[key] = at;
      lastStart = at;
      firstStart ??= at;
    }

    // ONE projected due for the whole burst, exactly as `nextBurstDue`
    // records it: a due per slot would aim the request at a schedule the
    // burst never adopts.
    final burstDue = planned.isEmpty
        ? null
        : nextBurstDue(
            firstPublishStartedAt: planned.values.first,
            lastPublishStartedAt: planned.values.last,
            interval: Duration(seconds: sampled),
            minInterval: kLocationPublishMinInterval,
          );
    var earliest = burstDue;
    final untouched = _tracker.earliestDue([
      for (final key in circles)
        if (!planned.containsKey(key)) key,
    ]);
    if (untouched != null &&
        (earliest == null || untouched.isBefore(earliest))) {
      earliest = untouched;
    }

    if (earliest != null) {
      _ensureRegistration(
        earliestDue: earliest,
        now: now,
        plannedPublishStart: planned.isEmpty ? now : planned.values.first,
      );
    }

    if (planned.isNotEmpty && !_foreignCycle) {
      servingCycles++;
      final fewest = minPerServingCycle;
      if (fewest == null || planned.length < fewest) {
        minPerServingCycle = planned.length;
      }
    }
    planned.forEach((key, at) {
      final previous = _lastPublish[key];
      if (previous != null) {
        final gap = at.difference(previous);
        gaps.add(gap);
        if (gap > worstGap) worstGap = gap;
        if (gap < shortestGap) shortestGap = gap;
      }
      _lastPublish[key] = at;
      _publishes[key] = (_publishes[key] ?? 0) + 1;
    });
    if (burstDue != null) _tracker.markBurstPublished(planned.keys, burstDue);
  }

  void _ensureRegistration({
    required DateTime earliestDue,
    required DateTime now,
    required DateTime plannedPublishStart,
  }) {
    final target = earliestDue.subtract(kBackgroundFixLeadTime);
    final registered = _registeredTarget;
    if (registered != null && registrationIsAligned(registered, target)) return;

    final interval = nextFixRequestInterval(
      earliestDue: earliestDue,
      now: now,
      plannedPublishStart: plannedPublishStart,
    );
    if (interval < smallestInterval) smallestInterval = interval;
    _registeredTarget = target;
    _interval = interval;
    _reRegistered = true;
    _nextDelivery = deliveryAt(
      api: api,
      lastFixAt: _lastFixAt,
      registeredAt: now,
      interval: interval,
      ttff: ttff,
    );
  }
}
