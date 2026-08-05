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
import 'package:haven/src/services/clock_skew_detector.dart';
import 'package:haven/src/services/relay_service.dart';

/// A controllable clock so sample expiry is exercised without sleeping.
class _FakeClock {
  DateTime now = DateTime.utc(2026, 8, 3, 12);
  DateTime call() => now;
}

PublishResult _publishResult({
  List<String> acceptedBy = const [],
  List<String> rejectionReasons = const [],
}) => PublishResult(
  eventId: 'e' * 64,
  acceptedBy: acceptedBy,
  rejectedBy: [
    for (var i = 0; i < rejectionReasons.length; i++)
      RelayRejection(
        relay: 'wss://relay$i.example.com',
        reason: rejectionReasons[i],
      ),
  ],
  failed: const [],
);

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
            'kClockSkewAlertThreshold; it must stay 2x the receiver grace '
            'window and well under the total-loss point.',
      );

      // Lower bound: RECEIVER_EXPIRATION_GRACE_SECS = 60 s is the band of
      // disagreement the protocol absorbs by design. Alerting inside it fires
      // on skew that costs the user nothing.
      const grace = Duration(seconds: 60);
      expect(kClockSkewAlertThreshold, greaterThan(grace));
      expect(kClockSkewAlertThreshold, grace * 2);

      // Upper bound: at 288 s every location is already silently discarded by
      // a correctly-clocked peer. The alarm must fire strictly before that.
      expect(
        kClockSkewTotalLossThreshold,
        const Duration(seconds: 288),
        reason: 'total loss = retention (228) + receiver grace (60)',
      );
      expect(kClockSkewAlertThreshold, lessThan(kClockSkewTotalLossThreshold));

      // ...and before the no-gap invariant is beyond rescue: at the threshold
      // the residency left to a lagging publisher (228 - 120 = 108 s) is
      // already under the 168 s worst-case inter-publish gap, so the harm is
      // real by the time we speak.
      const retention = Duration(seconds: 228);
      const maxPublishGap = kLocationPublishMaxInterval;
      expect(kClockSkewAlertThreshold, lessThan(retention));
      expect(retention - kClockSkewAlertThreshold, lessThan(maxPublishGap));
    });
  });

  group('relay rejection classification', () {
    test("reads strfry's timestamp refusal as a clock complaint", () {
      expect(
        ClockSkewDetector.classifyRelayRejection(
          'invalid: event too far off from the current time',
        ),
        DeviceClockComplaint.unspecified,
      );
    });

    test('reads an explicit future refusal as "ahead"', () {
      for (final reason in [
        'invalid: event created_at is too far in the future',
        'invalid: event is too new',
        'invalid: created_at newer than 900 seconds from now',
        'invalid: future timestamp not allowed',
      ]) {
        expect(
          ClockSkewDetector.classifyRelayRejection(reason),
          DeviceClockComplaint.ahead,
          reason: reason,
        );
      }
    });

    test('reads an explicit past / expired refusal as "behind"', () {
      for (final reason in [
        'invalid: event too old',
        'invalid: created_at older than 3600 seconds',
        'invalid: event is too far in the past',
        'invalid: event expired',
        'invalid: outdated event',
      ]) {
        expect(
          ClockSkewDetector.classifyRelayRejection(reason),
          DeviceClockComplaint.behind,
          reason: reason,
        );
      }
    });

    test('is case-insensitive', () {
      expect(
        ClockSkewDetector.classifyRelayRejection(
          'INVALID: EVENT TOO FAR OFF FROM THE CURRENT TIME',
        ),
        DeviceClockComplaint.unspecified,
      );
    });

    // The negative control for the entire mechanism.
    test('never reads an ordinary failure as a clock complaint', () {
      for (final reason in [
        'blocked: pubkey not on the allowlist',
        'rate-limited: slow down',
        'invalid: bad signature',
        'invalid: event id does not match',
        'pow: difficulty 20 is less than 25',
        'duplicate: already have this event',
        'restricted: we do not accept events from unauthenticated users',
        'error: event too large',
        'connection timed out',
        'operation timed out after 30s',
        'not connected (status: disconnected)',
        'websocket error: connection reset by peer',
        '',
      ]) {
        expect(
          ClockSkewDetector.classifyRelayRejection(reason),
          isNull,
          reason: 'must NOT be read as a clock complaint: "$reason"',
        );
      }
    });
  });

  group('FFI error token', () {
    test('extracts the complaint from the Haven-authored token', () {
      expect(
        ClockSkewDetector.complaintFromError(
          'haven.clock.device_clock_rejected:ahead',
        ),
        DeviceClockComplaint.ahead,
      );
      expect(
        ClockSkewDetector.complaintFromError(
          'haven.clock.device_clock_rejected:behind',
        ),
        DeviceClockComplaint.behind,
      );
      expect(
        ClockSkewDetector.complaintFromError(
          'haven.clock.device_clock_rejected:unspecified',
        ),
        DeviceClockComplaint.unspecified,
      );
    });

    test('the enum name IS the wire token', () {
      // `NostrRelayService` converts a parsed complaint back to a token with
      // `.name`, and the Rust `Display` emits exactly these three suffixes. A
      // rename of any enum member would silently produce a token neither side
      // recognises, so pin the mapping rather than the enum.
      expect(DeviceClockComplaint.ahead.name, 'ahead');
      expect(DeviceClockComplaint.behind.name, 'behind');
      expect(DeviceClockComplaint.unspecified.name, 'unspecified');
      for (final complaint in DeviceClockComplaint.values) {
        expect(
          ClockSkewDetector.complaintFromError(
            '${ClockSkewDetector.deviceClockRejectedToken}:${complaint.name}',
          ),
          complaint,
        );
      }
    });

    test('survives a wrapped / decorated error string', () {
      expect(
        ClockSkewDetector.complaintFromError(
          Exception('haven.clock.device_clock_rejected:ahead)'),
        ),
        DeviceClockComplaint.ahead,
      );
    });

    test('ignores an unrelated error', () {
      expect(
        ClockSkewDetector.complaintFromError('All relays failed'),
        isNull,
      );
      expect(
        ClockSkewDetector.complaintFromError(
          const RelayServiceException('Failed to publish event'),
        ),
        isNull,
      );
    });
  });

  group('publish signal', () {
    test('a fully-rejected clock publish raises the relay signal', () {
      // Before the fix this outcome reached nothing at all: the reason was
      // dropped inside publish_with_retry and the caller only logged.
      final detector = ClockSkewDetector();
      addTearDown(detector.dispose);

      expect(detector.status.isSkewed, isFalse);
      detector.recordPublishResult(
        _publishResult(
          rejectionReasons: const [
            'invalid: event too far off from the current time',
          ],
        ),
      );

      expect(detector.status.signal, ClockSkewSignal.relayRejectedTimestamp);
      expect(detector.status.complaint, DeviceClockComplaint.unspecified);
    });

    test('a fully-rejected NON-clock publish does not blame the clock', () {
      final detector = ClockSkewDetector();
      addTearDown(detector.dispose);

      detector.recordPublishResult(
        _publishResult(rejectionReasons: const ['rate-limited: slow down']),
      );

      expect(detector.status.signal, ClockSkewSignal.none);
    });

    test('a partially-accepted publish does not blame the clock', () {
      // The location DID reach the network. Warning here would be crying wolf.
      final detector = ClockSkewDetector();
      addTearDown(detector.dispose);

      detector.recordPublishResult(
        _publishResult(
          acceptedBy: const ['wss://ok.example.com'],
          rejectionReasons: const [
            'invalid: event too far off from the current time',
          ],
        ),
      );

      expect(detector.status.signal, ClockSkewSignal.none);
    });

    test('a later success clears a raised relay signal', () {
      final detector = ClockSkewDetector();
      addTearDown(detector.dispose);

      detector.recordPublishClockRejection('ahead');
      expect(detector.status.isSkewed, isTrue);

      detector.recordPublishResult(
        _publishResult(acceptedBy: const ['wss://ok.example.com']),
      );

      expect(detector.status.signal, ClockSkewSignal.none);
    });

    test('an ordinary transport failure does not clear a raised signal', () {
      // A dropped connection says nothing either way about the clock; letting
      // it clear the verdict would hide a clock that is still wrong.
      final detector = ClockSkewDetector();
      addTearDown(detector.dispose);

      detector
        ..recordPublishClockRejection('ahead')
        ..recordPublishError(
          const RelayServiceException('Failed to publish event'),
        );

      expect(detector.status.signal, ClockSkewSignal.relayRejectedTimestamp);
    });

    test('the generic entry point still classifies the TYPED rejection', () {
      // `RelayClockRejectionException.toString()` is
      // `'RelayClockRejectionException(device clock ahead)'` — it carries no
      // `haven.clock.device_clock_rejected:` marker, because the token lives in
      // a field so the relay layer needs no dependency on this enum. So the
      // text parser cannot see it, and a caller that hands the typed exception
      // to the generic entry point used to drop the classification in silence.
      //
      // That silence is not hypothetical: it is exactly what made the B8 lane
      // report three findings (verdict, surface, copy) against production code
      // that was correct — the drive had copied the publish call site and read
      // the token out of `toString()`. Production catches the typed exception
      // first and never relied on this path; this pins the backstop so the
      // next caller to reach for it cannot lose the verdict the same way.
      final detector = ClockSkewDetector();
      addTearDown(detector.dispose);

      const error = RelayClockRejectionException('ahead');
      expect(
        ClockSkewDetector.complaintFromError(error),
        isNull,
        reason: 'the marker is deliberately absent from toString()',
      );

      detector.recordPublishError(error);

      expect(detector.status.signal, ClockSkewSignal.relayRejectedTimestamp);
      expect(detector.status.complaint, DeviceClockComplaint.ahead);
    });

    test('the typed rejection carries the slow direction through too', () {
      final detector = ClockSkewDetector();
      addTearDown(detector.dispose);

      detector.recordPublishError(const RelayClockRejectionException('behind'));

      expect(detector.status.complaint, DeviceClockComplaint.behind);
    });

    test('an unknown typed token degrades to unspecified, not silence', () {
      // Not reachable from production today — NostrRelayService builds the
      // token from `DeviceClockComplaint.name`, a closed enum — so this pins
      // the CONTRACT rather than a live path: if a future wire token arrives
      // that this build does not know, the fault must still surface as "the
      // clock is wrong, direction unknown" rather than vanish. Degrading
      // loudly beats dropping it.
      final detector = ClockSkewDetector();
      addTearDown(detector.dispose);

      detector.recordPublishError(
        const RelayClockRejectionException('sideways'),
      );

      expect(detector.status.signal, ClockSkewSignal.relayRejectedTimestamp);
      expect(detector.status.complaint, DeviceClockComplaint.unspecified);
    });

    test('two relays disagreeing about direction collapse to unspecified', () {
      final detector = ClockSkewDetector();
      addTearDown(detector.dispose);

      detector.recordPublishResult(
        _publishResult(
          rejectionReasons: const [
            'invalid: created_at is in the future',
            'invalid: event too old',
          ],
        ),
      );

      expect(detector.status.complaint, DeviceClockComplaint.unspecified);
    });

    test('a stated direction beats an unspecified one', () {
      final detector = ClockSkewDetector();
      addTearDown(detector.dispose);

      detector.recordPublishResult(
        _publishResult(
          rejectionReasons: const [
            'invalid: event too far off from the current time',
            'invalid: created_at is in the future',
          ],
        ),
      );

      expect(detector.status.complaint, DeviceClockComplaint.ahead);
    });
  });

  group('peer signal (the slow direction)', () {
    ClockSkewDetector build(_FakeClock clock) {
      final d = ClockSkewDetector(now: clock.call);
      addTearDown(d.dispose);
      return d;
    }

    test('does NOT fire on a single outlying peer', () {
      // The load-bearing negative. One member's clock being wrong is far more
      // likely than everyone else's; a detector that fired here would blame
      // the user's phone for someone else's fault.
      final clock = _FakeClock();
      final detector = build(clock);

      detector.recordPeerTimestamp(
        senderPubkey: 'aa' * 32,
        peerTimestamp: clock.now.add(const Duration(hours: 6)),
      );

      expect(detector.status.signal, ClockSkewSignal.none);
      expect(detector.status.corroboratingSources, 0);
    });

    test('does NOT fire on repeated samples from the SAME peer', () {
      // Samples are keyed by member id, so one member can never supply two of
      // them. Without this, a single skewed (or malicious) member could
      // corroborate itself just by publishing twice.
      final clock = _FakeClock();
      final detector = build(clock);

      for (var i = 0; i < 5; i++) {
        detector.recordPeerTimestamp(
          senderPubkey: 'aa' * 32,
          peerTimestamp: clock.now.add(const Duration(hours: 6)),
        );
        clock.now = clock.now.add(const Duration(seconds: 30));
      }

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

      expect(detector.status.signal, ClockSkewSignal.none);
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
        ..recordPublishClockRejection('ahead')
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
        ..recordPublishClockRejection('ahead');

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
        ..recordPublishClockRejection('ahead')
        ..recordPublishClockRejection('ahead')
        ..recordPublishResult(
          _publishResult(acceptedBy: const ['wss://ok.example.com']),
        );

      await Future<void>.delayed(Duration.zero);
      expect(seen.map((s) => s.signal).toList(), [
        ClockSkewSignal.relayRejectedTimestamp,
        ClockSkewSignal.none,
      ]);
    });
  });
}
