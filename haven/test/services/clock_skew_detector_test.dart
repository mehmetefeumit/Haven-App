/// Tests for [ClockSkewDetector] — the device-clock skew policy.
///
/// Every test here is written against a behaviour that was BROKEN before this
/// feature: a relay rejection that died in a `debugPrint`, a slow clock that
/// reported success while losing 100 % of updates, and a threshold that did not
/// exist. The negative controls matter as much as the positives — a detector
/// that cries wolf would be worse than the silence it replaces, because it
/// would send users to fix a clock that is fine while the real cause goes
/// unmentioned.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/constants/location.dart';
import 'package:haven/src/rust/api.dart'
    show DeviceClockComplaintFfi, LocationPublishFfi;
import 'package:haven/src/services/clock_skew_detector.dart';

/// A controllable clock so sample expiry is exercised without sleeping.
class _FakeClock {
  DateTime now = DateTime.utc(2026, 8, 3, 12);
  DateTime call() => now;
}

void main() {
  group('threshold', () {
    // The threshold is not a free parameter. Both bounds are asserted, so a
    // change in EITHER direction fails: widening hides real breakage,
    // narrowing cries wolf.
    test('is pinned at 120s and derived from the constants that bound it', () {
      expect(
        kClockSkewAlertThreshold,
        const Duration(seconds: 120),
        reason:
            'the alert threshold moved. See the derivation on '
            'kClockSkewAlertThreshold; it must stay past the lag at which '
            'most publish cycles leave a hole and well under the total-loss '
            'point.',
      );

      // The retention as Dart derives it: the cadence ceiling plus two
      // network buffers (LOCATION_MESSAGE_RETENTION_SECS = 168 + 2 * 30).
      final retention =
          kLocationPublishMaxInterval +
          const Duration(seconds: 2 * kTtlNetworkBufferSeconds);

      // The total-loss point IS the retention: the relay pool drops an event
      // once its expiration is behind the receiver's clock, with no grace.
      expect(
        kClockSkewTotalLossThreshold,
        retention,
        reason:
            'total loss = the retention, because the relay pool drops an '
            'expired event on receipt with no grace',
      );

      // Lower bound: past the lag at which the residency left to a lagging
      // publisher drops under the median publish interval, so a lag whose
      // holes are only the jitter's tail never raises the alarm.
      expect(
        kClockSkewAlertThreshold,
        greaterThan(retention - kLocationUpdateInterval),
      );

      // Upper bound: at the total-loss point every location is already
      // silently discarded. The alarm must fire strictly before that.
      expect(kClockSkewAlertThreshold, lessThan(kClockSkewTotalLossThreshold));

      // ...and the harm is real by the time we speak: the residency left
      // (228 - 120 = 108 s) is under the 168 s worst-case interval.
      expect(
        retention - kClockSkewAlertThreshold,
        lessThan(kLocationPublishMaxInterval),
      );
    });
  });

  // How a relay's refusal text is read for the clock is Rust's alone now
  // (`relay/clock_skew.rs` `classifies_strfry_future_rejection`,
  // `classifies_explicit_future_rejections`,
  // `classifies_explicit_past_rejections`,
  // `classification_is_case_insensitive`,
  // `ordinary_rejections_are_not_clock_complaints`); it crosses typed, and
  // what `publishEvent` makes of it is
  // `nostr_relay_service_publish_event_test.dart`'s. Dart used to mirror the
  // phrase tables and parse an error-string token.

  group('publish signal', () {
    test("a drive's clock evidence raises the relay signal in its direction",
        () {
      for (final (evidence, complaint) in [
        (DeviceClockComplaintFfi.ahead, DeviceClockComplaint.ahead),
        (DeviceClockComplaintFfi.behind, DeviceClockComplaint.behind),
        (DeviceClockComplaintFfi.unspecified, DeviceClockComplaint.unspecified),
      ]) {
        final detector = ClockSkewDetector();
        addTearDown(detector.dispose);

        detector.recordDriveClockRejection(evidence);

        expect(detector.status.signal, ClockSkewSignal.relayRejectedTimestamp);
        expect(detector.status.complaint, complaint);
      }
    });

    // Which relays blamed what, and how their answers merge, is classified in
    // Rust now (`relay/clock_skew.rs`
    // `publish_outcome_merges_a_specific_direction_over_unspecified`,
    // `publish_outcome_collapses_contradicting_directions`,
    // `publish_outcome_is_silent_for_non_clock_rejections`); a send any relay
    // took crosses as `accepted` (`rust_builder` api.rs, the LocationPublish
    // mapping). Before, Dart classified the relays' text itself.
    test('a send no relay took for its time raises the relay signal in its '
        'direction', () {
      for (final (publish, complaint) in [
        (LocationPublishFfi.clockAhead, DeviceClockComplaint.ahead),
        (LocationPublishFfi.clockBehind, DeviceClockComplaint.behind),
        (LocationPublishFfi.clockUnspecified, DeviceClockComplaint.unspecified),
      ]) {
        final detector = ClockSkewDetector();
        addTearDown(detector.dispose);

        detector.recordLocationPublish(publish);

        expect(detector.status.signal, ClockSkewSignal.relayRejectedTimestamp);
        expect(detector.status.complaint, complaint);
      }
    });

    test('a change a relay acknowledged clears a raised signal, and a later '
        "drive's evidence raises it again", () {
      final detector = ClockSkewDetector();
      addTearDown(detector.dispose);

      detector
        ..recordDriveClockRejection(DeviceClockComplaintFfi.ahead)
        ..recordDriveAccepted();
      expect(detector.status.signal, ClockSkewSignal.none);

      detector.recordDriveClockRejection(DeviceClockComplaintFfi.behind);
      expect(detector.status.complaint, DeviceClockComplaint.behind);
    });

    test('a send a relay took, or one every relay refused for something '
        'else, clears a raised signal', () {
      for (final publish in [
        LocationPublishFfi.accepted,
        LocationPublishFfi.refused,
      ]) {
        final detector = ClockSkewDetector();
        addTearDown(detector.dispose);

        detector
          ..recordLocationPublish(LocationPublishFfi.clockAhead)
          ..recordLocationPublish(publish);

        expect(
          detector.status.signal,
          ClockSkewSignal.none,
          reason: '$publish',
        );
      }
    });

    test('a send no relay was reached for, or that was not sent, does not '
        'clear a raised signal', () {
      // A dropped connection says nothing either way about the clock; letting
      // it clear the verdict would hide a clock that is still wrong.
      for (final publish in [
        LocationPublishFfi.unreachable,
        LocationPublishFfi.expired,
        LocationPublishFfi.superseded,
        LocationPublishFfi.ended,
        LocationPublishFfi.inFlight,
      ]) {
        final detector = ClockSkewDetector();
        addTearDown(detector.dispose);

        detector
          ..recordLocationPublish(LocationPublishFfi.clockAhead)
          ..recordLocationPublish(publish);

        expect(
          detector.status.signal,
          ClockSkewSignal.relayRejectedTimestamp,
          reason: '$publish',
        );
      }
    });
  });

  group('peer signal (the slow direction)', () {
    ClockSkewDetector build(_FakeClock clock) {
      final d = ClockSkewDetector(now: clock.call);
      addTearDown(d.dispose);
      return d;
    }

    test('does NOT fire on one outlying peer while another peer agrees with '
        'this device', () {
      // A regression pin on the UNCHANGED two-source bar, not evidence about
      // the sole-source exception: this case passes identically with that
      // exception reverted (mutation-checked), because two live samples take
      // it out of the exception's reach entirely. It is here because the bar
      // is what the exception is carved out of — while a second member is
      // reachable, that member's agreement with our clock is what keeps a
      // lone outlier from being read as evidence about this phone.
      final clock = _FakeClock();
      final detector = build(clock);

      detector
        ..recordPeerTimestamp(
          senderPubkey: 'aa' * 32,
          peerTimestamp: clock.now.add(const Duration(hours: 6)),
        )
        ..recordPeerTimestamp(
          senderPubkey: 'bb' * 32,
          peerTimestamp: clock.now,
        );

      expect(detector.status.signal, ClockSkewSignal.none);
      expect(detector.status.corroboratingSources, 0);
    });

    test('fires on the ONLY peer of a two-member circle', () {
      // The blind spot this closes. A two-member circle can never produce two
      // corroborating members, so the old bar was not merely unmet but
      // unmeetable — and a device whose clock is >= the alert threshold
      // behind loses 100 % of its updates while every publish still reports
      // success. The most common circle size was structurally unable to see
      // the exact fault this detector exists to surface.
      final clock = _FakeClock();
      final detector = build(clock);

      detector.recordPeerTimestamp(
        senderPubkey: 'aa' * 32,
        peerTimestamp: clock.now.add(const Duration(hours: 6)),
      );

      final status = detector.status;
      expect(status.signal, ClockSkewSignal.peersAheadOfDevice);
      expect(status.complaint, DeviceClockComplaint.behind);
      expect(
        status.corroboratingSources,
        1,
        reason:
            'the verdict must report the single source honestly, not inflate '
            'it to the nominal two',
      );
      expect(status.offsetSecs, const Duration(hours: 6).inSeconds);
    });

    test('a second peer joining a two-member verdict can clear it', () {
      // Follows directly from the rule: the sole-source exception applies
      // only while a second member is unavailable. Once one is heard AND
      // agrees with us, the two-source bar governs again and the banner must
      // clear — otherwise a verdict raised while alone would outlive the
      // evidence that refutes it.
      final clock = _FakeClock();
      final detector = build(clock);

      detector.recordPeerTimestamp(
        senderPubkey: 'aa' * 32,
        peerTimestamp: clock.now.add(const Duration(hours: 6)),
      );
      expect(detector.status.signal, ClockSkewSignal.peersAheadOfDevice);

      detector.recordPeerTimestamp(
        senderPubkey: 'bb' * 32,
        peerTimestamp: clock.now,
      );

      expect(detector.status.signal, ClockSkewSignal.none);
    });

    test('never counts repeated samples from the SAME peer as two sources',
        () {
      // Samples are keyed by member id, so one member can never supply two of
      // them. Without this, a single skewed (or malicious) member could
      // corroborate itself just by publishing twice, and would then survive a
      // second, agreeing member joining the circle.
      final clock = _FakeClock();
      final detector = build(clock);

      for (var i = 0; i < 5; i++) {
        detector.recordPeerTimestamp(
          senderPubkey: 'aa' * 32,
          peerTimestamp: clock.now.add(const Duration(hours: 6)),
        );
        clock.now = clock.now.add(const Duration(seconds: 30));
      }

      expect(detector.trackedSourceCountForTest, 1);
      expect(
        detector.status.corroboratingSources,
        1,
        reason:
            'five publications from one member are still one member; only '
            'the sole-source rule may fire here, never a fabricated second '
            'source',
      );

      // And the proof that the count is real: one agreeing member is enough
      // to clear it, which could not happen if the five samples had been
      // counted as independent corroboration.
      detector.recordPeerTimestamp(
        senderPubkey: 'bb' * 32,
        peerTimestamp: clock.now,
      );
      expect(detector.status.signal, ClockSkewSignal.none);
    });

    test('ignores letter case when keying members', () {
      final clock = _FakeClock();
      final detector = build(clock);

      detector
        ..recordPeerTimestamp(
          senderPubkey: 'AB' * 32,
          peerTimestamp: clock.now.add(const Duration(hours: 6)),
        )
        ..recordPeerTimestamp(
          senderPubkey: 'ab' * 32,
          peerTimestamp: clock.now.add(const Duration(hours: 6)),
        );

      expect(
        detector.trackedSourceCountForTest,
        1,
        reason: 'the two casings are one member',
      );
      expect(
        detector.status.corroboratingSources,
        1,
        reason:
            'case folding must not manufacture a second corroborating source '
            '— the verdict here is the sole-source one, not a two-peer one',
      );
    });

    test('fires once two distinct members corroborate past the threshold', () {
      final clock = _FakeClock();
      final detector = build(clock);

      detector
        ..recordPeerTimestamp(
          senderPubkey: 'aa' * 32,
          peerTimestamp: clock.now.add(const Duration(hours: 6)),
        )
        ..recordPeerTimestamp(
          senderPubkey: 'bb' * 32,
          peerTimestamp: clock.now.add(const Duration(hours: 6, minutes: 5)),
        );

      final status = detector.status;
      expect(status.signal, ClockSkewSignal.peersAheadOfDevice);
      expect(status.complaint, DeviceClockComplaint.behind);
      expect(status.corroboratingSources, 2);
      // The SMALLEST offset both members independently exceeded — a lower
      // bound no single member can inflate.
      expect(status.offsetSecs, const Duration(hours: 6).inSeconds);
    });

    test('does not fire just below the threshold, and does at it', () {
      final clock = _FakeClock();
      final detector = build(clock);
      final justUnder =
          kClockSkewAlertThreshold - const Duration(seconds: 1);

      detector
        ..recordPeerTimestamp(
          senderPubkey: 'aa' * 32,
          peerTimestamp: clock.now.add(justUnder),
        )
        ..recordPeerTimestamp(
          senderPubkey: 'bb' * 32,
          peerTimestamp: clock.now.add(justUnder),
        );
      expect(
        detector.status.signal,
        ClockSkewSignal.none,
        reason: 'one second under the threshold must stay quiet',
      );

      detector
        ..recordPeerTimestamp(
          senderPubkey: 'aa' * 32,
          peerTimestamp: clock.now.add(kClockSkewAlertThreshold),
        )
        ..recordPeerTimestamp(
          senderPubkey: 'bb' * 32,
          peerTimestamp: clock.now.add(kClockSkewAlertThreshold),
        );
      expect(detector.status.signal, ClockSkewSignal.peersAheadOfDevice);
    });

    test('never fires on peers that are BEHIND this device', () {
      // Negative offsets are structurally uninformative: the receiver already
      // dropped anything older than retention + grace, and ordinary catch-up
      // legitimately delivers minutes-old locations. Firing here would blame
      // the clock for normal delivery latency.
      final clock = _FakeClock();
      final detector = build(clock);

      for (final key in ['aa', 'bb', 'cc']) {
        detector.recordPeerTimestamp(
          senderPubkey: key * 32,
          peerTimestamp: clock.now.subtract(const Duration(hours: 6)),
        );
      }

      expect(detector.status.signal, ClockSkewSignal.none);
    });

    test('one honest peer does not drag two skewed ones below threshold', () {
      final clock = _FakeClock();
      final detector = build(clock);

      detector
        ..recordPeerTimestamp(
          senderPubkey: 'aa' * 32,
          peerTimestamp: clock.now,
        )
        ..recordPeerTimestamp(
          senderPubkey: 'bb' * 32,
          peerTimestamp: clock.now.add(const Duration(minutes: 10)),
        )
        ..recordPeerTimestamp(
          senderPubkey: 'cc' * 32,
          peerTimestamp: clock.now.add(const Duration(minutes: 10)),
        );

      expect(detector.status.signal, ClockSkewSignal.peersAheadOfDevice);
      expect(detector.status.corroboratingSources, 2);
    });

    test('evidence expires, so the banner clears after the clock is fixed', () {
      final clock = _FakeClock();
      final detector = build(clock);

      detector
        ..recordPeerTimestamp(
          senderPubkey: 'aa' * 32,
          peerTimestamp: clock.now.add(const Duration(hours: 6)),
        )
        ..recordPeerTimestamp(
          senderPubkey: 'bb' * 32,
          peerTimestamp: clock.now.add(const Duration(hours: 6)),
        );
      expect(detector.status.signal, ClockSkewSignal.peersAheadOfDevice);

      // The clock is fixed; a fresh sample arrives with no offset while the
      // old ones age out.
      clock.now = clock.now.add(
        ClockSkewDetector.peerSampleTtl + const Duration(minutes: 1),
      );
      detector.recordPeerTimestamp(
        senderPubkey: 'cc' * 32,
        peerTimestamp: clock.now,
      );

      expect(detector.status.signal, ClockSkewSignal.none);
    });

    test('tracked members are bounded', () {
      final clock = _FakeClock();
      final detector = build(clock);

      for (var i = 0; i < ClockSkewDetector.maxTrackedSources + 20; i++) {
        detector.recordPeerTimestamp(
          senderPubkey: i.toRadixString(16).padLeft(64, '0'),
          peerTimestamp: clock.now,
        );
      }
      expect(detector.trackedSourceCountForTest,
          lessThanOrEqualTo(ClockSkewDetector.maxTrackedSources));
    });

    test('reset forgets every accumulated signal', () {
      final clock = _FakeClock();
      final detector = build(clock);

      detector
        ..recordLocationPublish(LocationPublishFfi.clockAhead)
        ..recordPeerTimestamp(
          senderPubkey: 'aa' * 32,
          peerTimestamp: clock.now.add(const Duration(hours: 6)),
        )
        ..reset();

      expect(detector.status, ClockSkewStatus.healthy);
    });
  });

  group('precedence and notification', () {
    test('the relay signal outranks the peer signal', () {
      // A relay rejection means sharing is failing RIGHT NOW; the peer signal
      // means it is failing invisibly. The more urgent one owns the surface.
      final clock = _FakeClock();
      final detector = ClockSkewDetector(now: clock.call);
      addTearDown(detector.dispose);

      detector
        ..recordPeerTimestamp(
          senderPubkey: 'aa' * 32,
          peerTimestamp: clock.now.add(const Duration(hours: 6)),
        )
        ..recordPeerTimestamp(
          senderPubkey: 'bb' * 32,
          peerTimestamp: clock.now.add(const Duration(hours: 6)),
        )
        ..recordLocationPublish(LocationPublishFfi.clockAhead);

      expect(detector.status.signal, ClockSkewSignal.relayRejectedTimestamp);
      expect(detector.status.complaint, DeviceClockComplaint.ahead);
    });

    test('emits on the change stream only when the verdict changes', () async {
      final detector = ClockSkewDetector();
      addTearDown(detector.dispose);

      final seen = <ClockSkewStatus>[];
      final sub = detector.changes.listen(seen.add);
      addTearDown(sub.cancel);

      detector
        ..recordLocationPublish(LocationPublishFfi.clockAhead)
        ..recordLocationPublish(LocationPublishFfi.clockAhead)
        ..recordLocationPublish(LocationPublishFfi.accepted);

      await Future<void>.delayed(Duration.zero);
      expect(seen.map((s) => s.signal).toList(), [
        ClockSkewSignal.relayRejectedTimestamp,
        ClockSkewSignal.none,
      ]);
    });

    test('the rendered verdict buckets its corroborating peers', () {
      // `ClockSkewStatus` is interpolated into the verdict `debugPrint`, and
      // "7 distinct members corroborated" is an exact count of the user's
      // co-members (Rule 15). The offset is a DELTA, so it stays exact.
      const status = ClockSkewStatus(
        signal: ClockSkewSignal.peersAheadOfDevice,
        offsetSecs: 42,
        corroboratingSources: 7,
      );

      final rendered = status.toString();
      expect(rendered, contains('sources: 5+'));
      expect(rendered, contains('offsetSecs: 42'));
      expect(
        rendered,
        isNot(contains('7')),
        reason: 'the exact number of corroborating peers must not survive',
      );
    });
  });
}
