@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/constants/location.dart';
import 'package:haven/src/services/mls_session_handover.dart';
import 'package:haven/src/widgets/map/member_marker.dart';

void main() {
  group('location constants', () {
    test('kLocationUpdateInterval is 2 minutes (120 seconds)', () {
      // Drift guard: this constant is threaded through the FFI as the
      // nominal for `jitteredPublishIntervalSecs()` and influences the
      // TTL floor passed to `encryptLocation`. A silent change here
      // shifts the NIP-40 expiration window on every published kind:445
      // event.
      expect(kLocationUpdateInterval.inSeconds, 120);
    });

    test('overlap guard is strictly below min jittered interval', () {
      // The publish-skip guard MUST sit below the minimum jittered
      // publish interval, otherwise genuine short-end jittered ticks
      // would be suppressed and the jitter distribution would become
      // biased upward.
      expect(
        kLocationPublishOverlapGuard,
        lessThan(kLocationPublishMinInterval),
      );
    });

    test('overlap guard is pinned at 60 seconds', () {
      // This ordering test alone does not bound the value: a guard far below
      // 60s still satisfies "strictly below the min interval" while letting
      // the disclosed motion trigger (kMotionTriggerDistanceMeters) fire far
      // more often than intended, sharpening the movement signal a relay
      // sees. Widening it dampens the motion trigger's responsiveness beyond
      // what the ordering test alone would ever flag.
      expect(kLocationPublishOverlapGuard, const Duration(seconds: 60));
    });

    test('kLocationPublishMinInterval is 72s (nominal * 0.6)', () {
      // Authoritative bound lives in Rust at
      // `PUBLISH_INTERVAL_JITTER_FRACTION_BP = 4000` (40% spread).
      // This Dart-side constant is a drift check only.
      expect(
        kLocationPublishMinInterval,
        Duration(seconds: (120 * 0.6).round()),
      );
      expect(kLocationPublishMinInterval.inSeconds, 72);
    });

    test('kStreamPositionMaxAge equals kLocationPublishMaxInterval', () {
      // The stream-position cache serves publish cycles; a fix bounded by
      // the max jittered publish interval is never staler than what an
      // on-time publish tick would have captured. Pinned so the iOS
      // background publish path's freshness bound cannot silently drift.
      expect(kStreamPositionMaxAge, kLocationPublishMaxInterval);
    });

    test('kLocationPublishMaxInterval is 168s (nominal * 1.4)', () {
      expect(
        kLocationPublishMaxInterval,
        Duration(seconds: (120 * 1.4).round()),
      );
      expect(kLocationPublishMaxInterval.inSeconds, 168);
    });

    test('min < nominal < max ordering holds', () {
      expect(kLocationPublishMinInterval, lessThan(kLocationUpdateInterval));
      expect(kLocationUpdateInterval, lessThan(kLocationPublishMaxInterval));
    });

    test('TTL network buffer is positive', () {
      expect(kTtlNetworkBufferSeconds, greaterThan(0));
    });

    test('kStationaryDwell is one nominal publish cadence', () {
      // Derived, not chosen: the iOS session may only coarsen its accuracy
      // after a full publish cadence of evidence that the device is still, so
      // the input to a publish is never coarsened on less evidence than the
      // interval between two publishes.
      expect(kStationaryDwell, kLocationUpdateInterval);
    });

    test('kStationaryConfirmMaxAge is half the freshness window (84 s)', () {
      // `~/` is not a constant expression, so the constant is written as a
      // literal and the derivation is pinned here.
      expect(kStationaryConfirmMaxAge, kStreamPositionMaxAge ~/ 2);
      expect(kStationaryConfirmMaxAge.inSeconds, 84);
    });

    test('an escalation still has time to land a Best fix in the cache '
        'window', () {
      // The ordering the stationary profile rests on: nothing confirming for
      // kStationaryConfirmMaxAge returns the session to Best, and that has to
      // happen with the cached Best fix still inside kStreamPositionMaxAge, or
      // a stationary user would publish from a one-shot instead of the fix the
      // coarse tier was busy confirming.
      expect(kStationaryConfirmMaxAge, lessThan(kStreamPositionMaxAge));
      expect(
        kStreamPositionMaxAge - kStationaryConfirmMaxAge,
        greaterThanOrEqualTo(kStationaryConfirmMaxAge),
        reason: 'a full second escalation window must fit inside the '
            'freshness bound, or a single missed Best fix ages the cache out',
      );
    });

    test('kStationaryAnchorMaxAge is the age at which Haven would have told '
        'the user (5 min)', () {
      // The chain of confirmations is what removes the 168 s ceiling on how
      // old a PUBLISHED coordinate may be — the wire carries the publish
      // instant, never the fix's — so this is the ceiling that replaces it.
      // It is kMemberAgePillThreshold: the owner-chosen age at which the map
      // pill and the roster's "last seen" line start telling the user a peer's
      // fix is behind. The staleness Haven hides may never exceed the
      // staleness Haven would have shown.
      expect(kStationaryAnchorMaxAge, kMemberAgePillThreshold);
      expect(kStationaryAnchorMaxAge.inSeconds, 300);
    });

    test('the anchor cap sits above both windows it supersedes, and under two '
        'freshness windows', () {
      // Below kStreamPositionMaxAge the cap would bind before the confirmation
      // chain ever ran and the coarse tier could not exist; below
      // kStationaryConfirmMaxAge the no-confirmation trigger would be dead
      // code. Above two freshness windows it would stop being the "bounded
      // multiple" the decision asks for, and would pass the age at which the
      // app itself calls a peer's fix stale.
      expect(kStationaryAnchorMaxAge, greaterThan(kStreamPositionMaxAge));
      expect(kStationaryAnchorMaxAge, greaterThan(kStationaryConfirmMaxAge));
      expect(kStationaryAnchorMaxAge, lessThan(kStreamPositionMaxAge * 2));
    });

    test('only fixes as precise as the distance they judge may confirm', () {
      // A fix coarser than the threshold it is compared against cannot resolve
      // that threshold, so the confirming accuracy is the trigger distance
      // itself (OD-P3-d, decided at 100 m). The pair also fixes the undetected
      // displacement bound at 200 m, which the constant's doc states.
      expect(kStationaryConfirmMaxAccuracyMeters, kMotionTriggerDistanceMeters);
      expect(
        kMotionTriggerDistanceMeters + kStationaryConfirmMaxAccuracyMeters,
        200,
      );
    });

    test('motion trigger distance is pinned at 100 metres', () {
      // Narrowing lets a moving device leak a finer-grained motion signal to
      // a relay (a motion-triggered publish fires on much smaller
      // displacements, subject only to the overlap guard); widening delays a
      // legitimate publish behind a displacement well past what is disclosed.
      expect(kMotionTriggerDistanceMeters, 100);
    });
  });

  group('background fix-request constants', () {
    test('kBackgroundFixLeadTime is 10 s — the AOSP hot-TTFF figure', () {
      // Not a taste number: `GPS_POLLING_THRESHOLD_INTERVAL`
      // (`GnssLocationProvider.java:228`, "Typical hot TTFF is ~5 seconds") is
      // the interval above which the framework stops the GNSS engine between
      // fixes, i.e. the platform's own estimate of a re-acquisition. Shrink it
      // and a re-acquisition outlives the lead, so the publish lands after its
      // due-time and the realized gap runs past kLocationPublishMaxInterval.
      expect(kBackgroundFixLeadTime, const Duration(seconds: 10));
    });

    test('kMinFixRequestInterval is 31 s — one second above the S+ '
        'MIN_REQUEST_DELAY_MS', () {
      // `LocationProviderManager.MIN_REQUEST_DELAY_MS` (30 s, `:181`) is the
      // threshold at which the S+ historical-delivery / delayed-register
      // regime engages. At or below it the request is a CONTINUOUS
      // HIGH_ACCURACY one — the 100 % GNSS duty cycle this whole phase exists
      // to remove — so the floor must sit strictly above it.
      expect(kMinFixRequestInterval, const Duration(seconds: 31));
      expect(
        kMinFixRequestInterval,
        greaterThan(const Duration(seconds: 30)),
        reason: 'at MIN_REQUEST_DELAY_MS the platform runs the request '
            'continuously and delivers no historical fix',
      );
    });

    test('the fix horizon exceeds the fix lead', () {
      // The fix is requested `lead` BEFORE the due-time, so when it arrives
      // the circle it was taken for is still `lead` short of due. A horizon
      // below the lead would make every delivery find nothing due: the cycle
      // would publish nothing, re-register, and pay one GNSS acquisition per
      // cycle forever.
      expect(kBackgroundFixHorizon, greaterThan(kBackgroundFixLeadTime));
    });

    test('the fix horizon is declared independently of the stagger spread', () {
      // The two are 30 s today and mean different things: the spread caps how
      // long ONE publish burst may take (a freshness budget on the shared
      // fix), the horizon decides which circles a delivered fix serves. An
      // equality assertion cannot tell a deliberate coincidence from a re-
      // coupling, so pin the DECLARATION: P5 re-caps the spread, and a
      // horizon defined in terms of it would silently move the due window.
      final source = File('lib/src/constants/location.dart').readAsStringSync();
      final declaration = source
          .split('\n')
          .firstWhere(
            (l) => l.startsWith('const Duration kBackgroundFixHorizon'),
            orElse: () => '',
          );
      expect(
        declaration,
        isNotEmpty,
        reason: 'the horizon must be a top-level const in this file',
      );
      expect(
        declaration.contains('kPublishStaggerMaxSpread'),
        isFalse,
        reason: 'the due horizon must not be derived from the stagger spread',
      );
    });

    test('kRegistrationSlack is 5 s and stays under the lead', () {
      // The slack is the loop breaker: a re-registration re-delivers the fix
      // just consumed (S+ historical delivery), so a target that moved by a
      // second or two must NOT cost a cancel+listen. Wider than the lead and a
      // kept registration could deliver after the due-time it was aimed at.
      expect(kRegistrationSlack, const Duration(seconds: 5));
      expect(kRegistrationSlack, lessThan(kBackgroundFixLeadTime));
    });

    test('kPublishWakeLockTimeout is twice one relay attempt and exactly '
        '30000 ms', () {
      // Derived from the drain budget (ONE relay publish attempt), not chosen:
      // the scoped lock must outlive fix→encrypt→publish→ack, which is one
      // attempt plus the fetch that follows it.
      expect(kPublishWakeLockTimeout, kBackgroundTeardownDrainBudget * 2);
      // The Kotlin twin (`PublishWakeLock.MAX_TIMEOUT_MS = 30_000L`) coerces
      // every request into `[1, 30_000]`, and nothing but this pins the two
      // sides of the channel together.
      expect(kPublishWakeLockTimeout.inMilliseconds, 30000);
    });

    test('the cold-cache delivery wait is far cheaper than the one-shot it '
        'replaces', () {
      // The wait exists to catch the S+ historical delivery instead of paying
      // a 30 s HIGH_ACCURACY acquisition on every foreground→background
      // handoff. Grow it past the one-shot's own timeout and the fallback
      // becomes cheaper than the optimisation, which is the point at which
      // waiting stops being free on API ≤ 30 (no historical delivery at all).
      expect(kFirstDeliveryWait, const Duration(seconds: 2));
      expect(kFirstDeliveryWait, lessThan(kOneShotLocationTimeout));
    });
  });

  group('foreground→background handoff signals', () {
    test('carry presence only — no identity, coordinate or circle', () {
      // The payload IS the message: the task answers a signal by running its
      // ordinary cycle, which re-reads ownership, disclosure and the roster
      // from its own gates. Anything richer here would be state crossing an
      // isolate boundary that the receiving side would then have to trust.
      for (final signal in const [
        kForegroundPausedSignal,
        kForegroundResumedSignal,
      ]) {
        expect(signal, isNotEmpty);
        expect(
          RegExp(r'^haven\.foreground\.[a-z]+$').hasMatch(signal),
          isTrue,
          reason: 'a signal must stay a bare namespaced verb: $signal',
        );
      }
      expect(
        kForegroundPausedSignal,
        isNot(kForegroundResumedSignal),
        reason: 'one signal arms the service and the other disarms it; a '
            'collision would make a resume look like a pause',
      );
    });
  });
}
