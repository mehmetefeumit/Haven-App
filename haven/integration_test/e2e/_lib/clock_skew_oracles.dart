/// The pure decision half of the B8 clock-skew lane's GATING oracles.
///
/// ## Why these live outside the drive target
///
/// B8 runs on a rooted emulator whose wall clock is moved from a shell servo.
/// Nothing about that is reproducible on a host, so the predicates that decide
/// whether the lane is green would otherwise only ever execute inside a
/// 40-minute CI job — which is exactly where a rotted oracle hides. Factored
/// out here they are ordinary pure functions, and
/// `haven/test/e2e/clock_skew_oracles_test.dart` drives every one of them with
/// BOTH a healthy-tree input and a reverted-fix input, so "the lane would go
/// red if the fix were reverted" is a claim with a test behind it rather than a
/// claim in a comment.
///
/// Each predicate returns `null` when the property holds and a human-readable
/// reason when it does not, so the drive can record the reason as a `FINDING`
/// (one run reports every defect) instead of throwing at the first one.
///
/// ## What these do NOT decide
///
/// Nothing here reads a clock, a relay, or a device. Every input is an
/// observation the drive already made on-device; the asymmetry that makes each
/// observation meaningful is documented at the drive's call site, because it is
/// a property of HOW the observation was taken, not of the predicate.
library;

import 'package:haven/src/services/clock_skew_detector.dart';
import 'package:haven/src/services/relay_service.dart';

/// The wire tokens `DeviceClockComplaint::wire_token` can produce.
///
/// Mirrored from `haven-core/src/relay/clock_skew.rs`. The *prefix* those
/// tokens ride on (`haven.clock.device_clock_rejected`) is pinned across the
/// two languages by `scripts/ci/check_clock_skew_policy_parity.sh`; this set
/// pins the suffix vocabulary the lane is willing to accept, so a rejection
/// that arrives classified-but-unrecognised is reported rather than silently
/// degraded.
const Set<String> kDeviceClockWireTokens = <String>{
  'ahead',
  'behind',
  'unspecified',
};

/// Holds when a publish the relays refused on timestamp grounds reached Dart
/// as a *classified* device-clock fault rather than as a generic failure.
///
/// [publishError] is whatever the production publish path threw, or `null` if
/// it did not throw at all.
///
/// This is the single predicate that a revert of the `publish_with_retry`
/// change fails: before it, a fully-unacknowledged publish collapsed to
/// `RelayError::AllRelaysFailed`, the per-relay reasons were dropped inside
/// Rust, and `NostrRelayService` had nothing to recognise — so the only thing
/// reaching Dart was `RelayServiceException('Failed to publish event')`.
String? checkFastClockRejectionClassified(Object? publishError) {
  if (publishError == null) {
    return 'the production publish path REPORTED SUCCESS for an event signed '
        '6 h in the future. The lane cannot judge the classification of a '
        'rejection that never happened.';
  }
  if (publishError is RelayClockRejectionException) {
    final token = publishError.complaintToken;
    if (kDeviceClockWireTokens.contains(token)) return null;
    return 'the refusal was classified as a device-clock fault but carries an '
        'unrecognised direction token "$token" — Dart and Rust disagree about '
        'the wire vocabulary, so the verdict degrades to "unspecified" and the '
        'direction is lost.';
  }
  if (ClockSkewDetector.complaintFromError(publishError) != null) {
    return 'the FFI error still carries the device-clock token, but the relay '
        'service no longer converts it into a RelayClockRejectionException '
        '(saw ${publishError.runtimeType}), so every caller above it sees an '
        'untyped failure.';
  }
  return 'the relays refused the event on timestamp grounds and the refusal '
      'reached Dart as ${publishError.runtimeType} with NO device-clock '
      'classification. This is the pre-fix behaviour: publish_with_retry '
      'collapsing a fully-unacknowledged publish into a generic failure and '
      'discarding the per-relay reasons, which is what made a fast clock a '
      'silent outage.';
}

/// Holds when the classified rejection actually reached something that can act
/// on it — the app's [ClockSkewDetector] — and raised its verdict.
///
/// A classification nothing consumes is indistinguishable, from the user's
/// side, from no classification at all.
String? checkRelayVerdictRaised(ClockSkewStatus status) {
  if (status.signal == ClockSkewSignal.relayRejectedTimestamp) return null;
  return "the detector was told the relays refused this device's timestamp "
      'and its verdict is still "${status.signal.name}". The classification '
      'reaches no consumer, so nothing can surface it.';
}

/// Holds when ONE member reporting a time in this device's future does **not**
/// raise the peer signal.
///
/// The negative half of the corroboration rule, and the one a revert to
/// `minCorroboratingSources = 1` fails. A lone peer's clock being wrong is far
/// more likely than everyone else's, so a single sample is never evidence
/// about *us*.
///
/// [sourcesFed] is asserted rather than trusted: a predicate handed zero
/// samples would pass vacuously, which is the failure shape this repo keeps
/// finding.
String? checkSingleSourceStaysSilent(
  ClockSkewStatus status, {
  required int sourcesFed,
}) {
  if (sourcesFed != 1) {
    return 'HARNESS: the single-source probe was fed $sourcesFed sample(s), '
        'not 1, so it proves nothing about corroboration.';
  }
  if (status.signal == ClockSkewSignal.none) return null;
  return 'ONE member reporting a future time already raised '
      '"${status.signal.name}" (${status.corroboratingSources} source(s)). '
      'Corroboration is what makes the peer signal evidence about this device '
      'rather than about that member.';
}

/// Holds when two distinct MLS-authenticated members agreeing that this device
/// is behind raises the peer verdict, with the direction and magnitude the
/// evidence supports.
///
/// [thresholdSecs] is `kClockSkewAlertThreshold` — passed in rather than read
/// here so the drive states the number it actually compared against.
String? checkPeerSkewCorroborated(
  ClockSkewStatus status, {
  required int thresholdSecs,
}) {
  if (status.signal != ClockSkewSignal.peersAheadOfDevice) {
    return 'two distinct MLS-authenticated members independently reported '
        'times more than ${thresholdSecs}s ahead of this device and the '
        'verdict is "${status.signal.name}". The slow-clock direction has no '
        'relay to report it, so this signal is the only one that can.';
  }
  if (status.complaint != DeviceClockComplaint.behind) {
    return 'the peer signal fired with complaint '
        '"${status.complaint?.name ?? '-'}" instead of "behind" — the copy '
        'shown to the user is chosen from the direction, so a wrong direction '
        'is wrong advice.';
  }
  if (status.corroboratingSources < ClockSkewDetector.minCorroboratingSources) {
    return 'the peer verdict claims only ${status.corroboratingSources} '
        'corroborating source(s); the rule requires '
        '${ClockSkewDetector.minCorroboratingSources}.';
  }
  final offset = status.offsetSecs;
  if (offset == null) {
    return 'the peer verdict carries no measured offset, so nothing pins it to '
        'the skew that was actually applied.';
  }
  if (offset < thresholdSecs) {
    return 'the peer verdict reports an offset of ${offset}s, below the '
        '${thresholdSecs}s alert threshold it is supposed to have exceeded.';
  }
  return null;
}

/// Holds when the user-visible surface rendered [expectedBody] for a fault.
///
/// [renderedTexts] is every `Text` the banner actually painted. A positive
/// check on purpose: "the banner did not render the wrong copy" would also
/// pass when the banner rendered nothing at all, which is the exact regression
/// this lane exists to catch.
String? checkFaultSurfaced({
  required String fault,
  required List<String> renderedTexts,
  required String expectedBody,
}) {
  if (renderedTexts.isEmpty) {
    return 'the $fault fault raised its verdict but the banner painted '
        'NOTHING, so the failure is exactly as silent as it was before the '
        'surface existed.';
  }
  if (!renderedTexts.contains(expectedBody)) {
    return 'the $fault banner rendered ${renderedTexts.length} text(s) but '
        'none of them is the copy this fault is supposed to show.';
  }
  return null;
}

/// Holds when the two faults say DIFFERENT things.
///
/// A relay rejection means nothing is being shared at all; the peer signal
/// means the send succeeded and the data was then discarded. Collapsing them
/// into one sentence makes the second one a lie in the direction that matters,
/// because it implies the send itself failed.
///
/// The bodies are compared, never logged: they are static localised copy, but
/// the lane's logcat is uploaded as a CI artifact and there is no reason to
/// widen what it carries.
String? checkFaultCopyDistinct({
  required String rejectedBody,
  required String behindBody,
}) {
  if (rejectedBody.isEmpty || behindBody.isEmpty) {
    return 'one of the two fault bodies is empty '
        '(rejected=${rejectedBody.length} chars, '
        'behind=${behindBody.length} chars), so one fault has no copy at all.';
  }
  if (rejectedBody == behindBody) {
    return 'both faults render the SAME body. "your location is not reaching '
        'anyone" and "your location is being sent and discarded" are '
        'different situations with different consequences, and one shared '
        'sentence necessarily misstates one of them.';
  }
  return null;
}
