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

    test('HEALTHY: one member ahead does NOT accuse this device', () {
      final detector = detectorWithPeersAhead(1);
      addTearDown(detector.dispose);
      expect(
        checkSingleSourceStaysSilent(detector.status, sourcesFed: 1),
        isNull,
      );
    });

    test('REVERTED: a rule that fires on one source is caught', () {
      // `minCorroboratingSources` back to 1. A lone peer's clock being wrong
      // is far likelier than everyone else's, so this would accuse the user of
      // a fault they do not have.
      final reason = checkSingleSourceStaysSilent(
        const ClockSkewStatus(
          signal: ClockSkewSignal.peersAheadOfDevice,
          complaint: DeviceClockComplaint.behind,
          offsetSecs: 21600,
          corroboratingSources: 1,
        ),
        sourcesFed: 1,
      );
      expect(reason, isNotNull);
      expect(reason, contains('Corroboration'));
    });

    test('the single-source probe cannot pass on zero samples', () {
      // Vacuity guard: a detector that was fed nothing is silent for reasons
      // that have nothing to do with the corroboration rule.
      expect(
        checkSingleSourceStaysSilent(ClockSkewStatus.healthy, sourcesFed: 0),
        isNotNull,
      );
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
    });
  });
}
