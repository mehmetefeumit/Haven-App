/// Host-side proof that the B8 clock-skew lane's GATING oracles separate a
/// healthy tree from a reverted fix.
///
/// The lane itself only runs on a rooted emulator whose wall clock is moved
/// from a shell servo, so its predicates would otherwise execute nowhere else.
/// The shell half of the demonstration lives in
/// `tooling/e2e/ci/run-b8-clock-skew.sh --self-test` (fixture group 16 feeds
/// it logs a reverted run would produce); this is the other half — the same
/// predicates the drive calls, fed the values each revert would actually
/// produce.
///
/// Every group therefore has BOTH directions:
///
///   * HEALTHY — what today's tree produces. If this side ever fails, the lane
///     is red on a green tree, which is worse than no lane at all.
///   * REVERTED — what the tree produced before the fix, or would produce if a
///     load-bearing piece were removed. If this side ever passes, the lane has
///     stopped gating and would stay green through the regression.
///
/// These run under plain `flutter test`: no Rust bridge, no device.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/constants/location.dart'
    show kClockSkewAlertThreshold;
import 'package:haven/src/services/clock_skew_detector.dart';
import 'package:haven/src/services/relay_service.dart';
import 'package:haven/src/widgets/location/clock_skew_banner.dart';

import '../../integration_test/e2e/_lib/clock_skew_oracles.dart';

/// A fixed "now" so the peer-sample arithmetic is exact rather than racy.
final DateTime _now = DateTime.utc(2026, 8, 3, 12);

/// The magnitude B8 applies. Six hours, far above the 120 s alert threshold.
const Duration _skew = Duration(hours: 6);

ClockSkewDetector _detector() => ClockSkewDetector(now: () => _now);

void main() {
  group('checkFastClockRejectionClassified', () {
    test('HEALTHY: a typed device-clock rejection passes', () {
      // What `NostrRelayService.publishEvent` throws today when
      // `publish_with_retry` classified the refusal.
      for (final token in kDeviceClockWireTokens) {
        expect(
          checkFastClockRejectionClassified(
            RelayClockRejectionException(token),
          ),
          isNull,
          reason: 'token "$token" is part of the wire vocabulary',
        );
      }
    });

    test('REVERTED: publish_with_retry collapsing to AllRelaysFailed fails',
        () {
      // The pre-fix behaviour: the per-relay reasons are discarded inside
      // Rust, `RelayError::AllRelaysFailed` crosses the FFI, and
      // `NostrRelayService` has nothing to recognise.
      final reason = checkFastClockRejectionClassified(
        const RelayServiceException('Failed to publish event'),
      );
      expect(reason, isNotNull);
      expect(reason, contains('NO device-clock classification'));
    });

    test('REVERTED: the raw pre-fix FFI error string fails', () {
      // One layer lower: `RelayError::AllRelaysFailed`'s own Display, in case
      // a future refactor stops wrapping FFI errors at all.
      expect(
        checkFastClockRejectionClassified(
          'All relays failed to accept the event',
        ),
        isNotNull,
      );
    });

    test('REVERTED: a service layer that stops typing the error fails', () {
      // The token still crosses the FFI, but nothing converts it into a
      // `RelayClockRejectionException`, so every caller above sees an untyped
      // failure. Caught, and named distinctly so triage lands in the right
      // file.
      final reason = checkFastClockRejectionClassified(
        Exception('${ClockSkewDetector.deviceClockRejectedToken}:ahead'),
      );
      expect(reason, isNotNull);
      expect(reason, contains('RelayClockRejectionException'));
    });

    test('REVERTED: a wire-token rename is caught rather than degraded', () {
      // The direction would silently collapse to "unspecified" at runtime.
      expect(
        checkFastClockRejectionClassified(
          const RelayClockRejectionException('fast'),
        ),
        isNotNull,
      );
    });

    test('a publish that SUCCEEDED cannot satisfy the oracle', () {
      // Guards the vacuity mode: with no refusal there is no classification to
      // judge, and reporting that as "held" would bless a relay that accepted
      // an event signed 6 h in its future.
      expect(checkFastClockRejectionClassified(null), isNotNull);
    });
  });

  group('checkRelayVerdictRaised', () {
    test('HEALTHY: the real detector raises the verdict from a token', () {
      final detector = _detector()..recordPublishClockRejection('unspecified');
      addTearDown(detector.dispose);
      expect(checkRelayVerdictRaised(detector.status), isNull);
    });

    test('REVERTED: a detector never told about the rejection fails', () {
      final detector = _detector();
      addTearDown(detector.dispose);
      expect(checkRelayVerdictRaised(detector.status), isNotNull);
    });

    test('REVERTED: a drifted wire token leaves the verdict unraised', () {
      // What `check_clock_skew_policy_parity.sh` exists to prevent, seen from
      // the runtime side: the error carries a token Dart no longer matches, so
      // `recordPublishError` finds nothing and the banner never appears.
      final detector = _detector()
        ..recordPublishError('haven.clock.device_clock_REFUSED:ahead');
      addTearDown(detector.dispose);
      expect(checkRelayVerdictRaised(detector.status), isNotNull);
    });
  });

  group('the peer signal', () {
    /// Feeds [count] distinct members a reading [_skew] ahead of this device,
    /// exactly as the drive does after jumping the clock backwards.
    ClockSkewDetector detectorWithPeersAhead(int count) {
      final detector = _detector();
      for (var i = 0; i < count; i++) {
        detector.recordPeerTimestamp(
          senderPubkey: 'member-$i',
          peerTimestamp: _now.add(_skew),
        );
      }
      return detector;
    }

    test('HEALTHY: the sole member of a two-member circle raises the verdict',
        () {
      final detector = detectorWithPeersAhead(1);
      addTearDown(detector.dispose);
      expect(
        checkSoleSourceRaisesVerdict(
          detector.status,
          sourcesFed: 1,
          thresholdSecs: kClockSkewAlertThreshold.inSeconds,
        ),
        isNull,
      );
      expect(
        detector.status.corroboratingSources,
        1,
        reason: 'one member is one source; the count must not be inflated',
      );
    });

    test('REVERTED: a rule that always waits for a second member is caught',
        () {
      // The pre-fix behaviour. A two-member circle can never produce a second
      // corroborating member, so this left the commonest circle size unable
      // to see a fault that discards 100 % of its updates while every publish
      // still reports success.
      final reason = checkSoleSourceRaisesVerdict(
        ClockSkewStatus.healthy,
        sourcesFed: 1,
        thresholdSecs: kClockSkewAlertThreshold.inSeconds,
      );
      expect(reason, isNotNull);
      expect(reason, contains('corroborate'));
    });

    test('REVERTED: a sole-source verdict claiming two sources is caught', () {
      // The count is the evidence the verdict rests on. Reporting the nominal
      // two from one member would make the sole-source path indistinguishable
      // from real corroboration in every log and diagnostic.
      final reason = checkSoleSourceRaisesVerdict(
        const ClockSkewStatus(
          signal: ClockSkewSignal.peersAheadOfDevice,
          complaint: DeviceClockComplaint.behind,
          offsetSecs: 21600,
          corroboratingSources: 2,
        ),
        sourcesFed: 1,
        thresholdSecs: kClockSkewAlertThreshold.inSeconds,
      );
      expect(reason, isNotNull);
      expect(reason, contains('corroborating source'));
    });

    test('REVERTED: the wrong direction is caught on the sole-source path too',
        () {
      expect(
        checkSoleSourceRaisesVerdict(
          const ClockSkewStatus(
            signal: ClockSkewSignal.peersAheadOfDevice,
            complaint: DeviceClockComplaint.ahead,
            offsetSecs: 21600,
            corroboratingSources: 1,
          ),
          sourcesFed: 1,
          thresholdSecs: kClockSkewAlertThreshold.inSeconds,
        ),
        isNotNull,
      );
    });

    test('the sole-source probe cannot pass on the wrong sample count', () {
      // Vacuity guard, both ways. Zero samples means the detector was silent
      // for reasons that have nothing to do with the rule; two means the
      // probe is answering the corroboration question, not this one.
      for (final fed in <int>[0, 2]) {
        expect(
          checkSoleSourceRaisesVerdict(
            ClockSkewStatus.healthy,
            sourcesFed: fed,
            thresholdSecs: kClockSkewAlertThreshold.inSeconds,
          ),
          isNotNull,
          reason: 'a probe fed $fed sample(s) proves nothing here',
        );
      }
    });

    test('HEALTHY: two distinct members ahead DO raise the verdict', () {
      final detector = detectorWithPeersAhead(2);
      addTearDown(detector.dispose);
      expect(
        checkPeerSkewCorroborated(
          detector.status,
          thresholdSecs: kClockSkewAlertThreshold.inSeconds,
        ),
        isNull,
      );
      // …and the measured offset really is the applied skew, so the oracle is
      // pinned to the jump rather than to any positive number.
      expect(detector.status.offsetSecs, _skew.inSeconds);
      expect(detector.status.corroboratingSources, 2);
    });

    test('REVERTED: removing the peer signal is caught', () {
      final reason = checkPeerSkewCorroborated(
        ClockSkewStatus.healthy,
        thresholdSecs: kClockSkewAlertThreshold.inSeconds,
      );
      expect(reason, isNotNull);
      expect(reason, contains('only one that can'));
    });

    test('REVERTED: the wrong direction is caught', () {
      // The user-facing copy is chosen from the direction, so "ahead" here
      // would tell a lagging device to fix the opposite problem.
      expect(
        checkPeerSkewCorroborated(
          const ClockSkewStatus(
            signal: ClockSkewSignal.peersAheadOfDevice,
            complaint: DeviceClockComplaint.ahead,
            offsetSecs: 21600,
            corroboratingSources: 2,
          ),
          thresholdSecs: kClockSkewAlertThreshold.inSeconds,
        ),
        isNotNull,
      );
    });

    test('REVERTED: a verdict below the alert threshold is caught', () {
      expect(
        checkPeerSkewCorroborated(
          const ClockSkewStatus(
            signal: ClockSkewSignal.peersAheadOfDevice,
            complaint: DeviceClockComplaint.behind,
            offsetSecs: 30,
            corroboratingSources: 2,
          ),
          thresholdSecs: kClockSkewAlertThreshold.inSeconds,
        ),
        isNotNull,
      );
    });

    test('a NO-OP clock jump cannot satisfy the corroboration oracle', () {
      // The lane's central vacuity risk, asserted rather than argued: if the
      // servo silently failed and the clock never moved, every peer reading
      // would be ~0 s from the reader's own clock and the verdict would stay
      // healthy.
      final detector = _detector();
      addTearDown(detector.dispose);
      for (var i = 0; i < 4; i++) {
        detector.recordPeerTimestamp(
          senderPubkey: 'member-$i',
          peerTimestamp: _now,
        );
      }
      expect(
        checkPeerSkewCorroborated(
          detector.status,
          thresholdSecs: kClockSkewAlertThreshold.inSeconds,
        ),
        isNotNull,
      );
    });
  });

  group('the user-visible surface', () {
    test('HEALTHY: the expected body among the painted texts passes', () {
      expect(
        checkFaultSurfaced(
          fault: 'fast-clock',
          renderedTexts: <String>["Check this phone's clock", 'body copy'],
          expectedBody: 'body copy',
        ),
        isNull,
      );
    });

    test('REVERTED: a banner that paints nothing is caught', () {
      final reason = checkFaultSurfaced(
        fault: 'fast-clock',
        renderedTexts: const <String>[],
        expectedBody: 'body copy',
      );
      expect(reason, isNotNull);
      expect(reason, contains('NOTHING'));
    });

    test("REVERTED: a banner showing the OTHER fault's copy is caught",
        () {
      expect(
        checkFaultSurfaced(
          fault: 'fast-clock',
          renderedTexts: const <String>['title', 'the other body'],
          expectedBody: 'body copy',
        ),
        isNotNull,
      );
    });

    test('HEALTHY: two different bodies pass', () {
      expect(
        checkFaultCopyDistinct(rejectedBody: 'a', behindBody: 'b'),
        isNull,
      );
    });

    test('REVERTED: one shared sentence for both faults is caught', () {
      final reason = checkFaultCopyDistinct(
        rejectedBody: 'same',
        behindBody: 'same',
      );
      expect(reason, isNotNull);
      expect(reason, contains('SAME body'));
    });

    test('an empty body cannot pass as "distinct"', () {
      expect(
        checkFaultCopyDistinct(rejectedBody: '', behindBody: 'b'),
        isNotNull,
      );
    });

    test('HEALTHY: the hedged sole-source copy passes', () {
      expect(
        checkSoleSourceCopyHedged(
          renderedTexts: const <String>['hedged title', 'hedged body'],
          hedgedTitle: 'hedged title',
          hedgedBody: 'hedged body',
          corroboratedTitle: 'accusing title',
          corroboratedBody: 'loss-claiming body',
        ),
        isNull,
      );
    });

    test('REVERTED: the corroborated copy on a sole source is caught', () {
      // The exact regression `resolveClockSkewCopy`'s branch prevents: one
      // member's word rendered as "this phone's clock is wrong" plus "the
      // locations it sends expire", neither of which one sample supports.
      for (final banned in <String>['accusing title', 'loss-claiming body']) {
        final reason = checkSoleSourceCopyHedged(
          renderedTexts: <String>[banned, 'hedged body'],
          hedgedTitle: 'hedged title',
          hedgedBody: 'hedged body',
          corroboratedTitle: 'accusing title',
          corroboratedBody: 'loss-claiming body',
        );
        expect(reason, isNotNull, reason: 'banned text "$banned" passed');
        expect(reason, contains('ONE member'));
      }
    });

    test('REVERTED: a sole-source banner that paints nothing is caught', () {
      final reason = checkSoleSourceCopyHedged(
        renderedTexts: const <String>[],
        hedgedTitle: 'hedged title',
        hedgedBody: 'hedged body',
        corroboratedTitle: 'accusing title',
        corroboratedBody: 'loss-claiming body',
      );
      expect(reason, isNotNull);
      expect(reason, contains('NOTHING'));
    });

    test('REVERTED: a hedged title without its hedged body is caught', () {
      // Half a bundle is not a hedge: the body is where the loss claim lives.
      expect(
        checkSoleSourceCopyHedged(
          renderedTexts: const <String>['hedged title', 'something else'],
          hedgedTitle: 'hedged title',
          hedgedBody: 'hedged body',
          corroboratedTitle: 'accusing title',
          corroboratedBody: 'loss-claiming body',
        ),
        isNotNull,
      );
    });
  });

  group('the healthy tree really is green', () {
    testWidgets("today's copy satisfies the distinctness oracle",
        (tester) async {
      // The lane's `surface-distinct` gate reads what the banner painted. Pin
      // the same property against the REAL localisations here, so a copy
      // change that collapses the two faults is caught in `flutter test`
      // rather than 40 minutes into an emulator lane.
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      final rejected = resolveClockSkewCopy(
        const ClockSkewStatus(
          signal: ClockSkewSignal.relayRejectedTimestamp,
          complaint: DeviceClockComplaint.ahead,
        ),
        l10n,
      );
      final behind = resolveClockSkewCopy(
        const ClockSkewStatus(
          signal: ClockSkewSignal.peersAheadOfDevice,
          complaint: DeviceClockComplaint.behind,
          offsetSecs: 21600,
          corroboratingSources: 2,
        ),
        l10n,
      );
      expect(rejected, isNotNull);
      expect(behind, isNotNull);
      expect(
        checkFaultCopyDistinct(
          rejectedBody: rejected!.message,
          behindBody: behind!.message,
        ),
        isNull,
      );

      // …and the sole-source bundle really is a THIRD thing, not either of
      // the two above. Pinned against the real localisations for the same
      // reason: a copy change that reunified them would otherwise only
      // surface 40 minutes into an emulator lane.
      final sole = resolveClockSkewCopy(
        const ClockSkewStatus(
          signal: ClockSkewSignal.peersAheadOfDevice,
          complaint: DeviceClockComplaint.behind,
          offsetSecs: 150,
          corroboratingSources: 1,
        ),
        l10n,
      );
      expect(sole, isNotNull);
      expect(
        checkSoleSourceCopyHedged(
          renderedTexts: <String>[sole!.title, sole.message],
          hedgedTitle: l10n.clockSkewTitleDisagreement,
          hedgedBody: l10n.clockSkewBodyDisagreement,
          corroboratedTitle: l10n.clockSkewTitle,
          corroboratedBody: l10n.clockSkewBodyBehind,
        ),
        isNull,
      );
    });
  });
}
