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

import 'package:haven/src/rust/api.dart' show LocationPublishFfi;
import 'package:haven/src/services/clock_skew_detector.dart';
import 'package:haven/src/utils/log_alias.dart' show magnitudeBucket;

/// Holds when a location the relays refused on timestamp grounds reached Dart
/// as a *classified* device-clock fault rather than as a generic failure.
///
/// [publish] is what the production send answered — the fanout driver's one
/// send of a sealed location — or `null` when [error] says it never answered.
///
/// This is the single predicate a revert of the typed clock refusal fails:
/// without it a send every relay refused for its time folds into
/// `unreachable`, the per-relay reasons are dropped inside Rust, and nothing
/// reaching Dart says the clock is wrong.
String? checkFastClockRejectionClassified(
  LocationPublishFfi? publish, {
  Object? error,
}) {
  if (publish == null) {
    return 'the production send never answered '
        '(threw ${error?.runtimeType ?? 'nothing'}), so the lane cannot judge '
        'the classification of its refusal.';
  }
  return switch (publish) {
    LocationPublishFfi.clockAhead ||
    LocationPublishFfi.clockBehind ||
    LocationPublishFfi.clockUnspecified => null,
    LocationPublishFfi.accepted =>
      'the production send REPORTED SUCCESS for an event signed 6 h in the '
          'future. The lane cannot judge the classification of a rejection '
          'that never happened.',
    LocationPublishFfi.unreachable =>
      'the relays refused the event on timestamp grounds and the send '
          'answered `unreachable` with NO device-clock classification. This '
          'is the pre-fix behaviour: a refusal blamed on the timestamp folded '
          'into a generic failure, which is what made a fast clock a silent '
          'outage.',
    LocationPublishFfi.refused =>
      'the send answered `refused` with no device-clock classification: the '
          'refusal was read, and its timestamp blame dropped.',
    LocationPublishFfi.expired ||
    LocationPublishFfi.superseded ||
    LocationPublishFfi.ended ||
    LocationPublishFfi.inFlight ||
    LocationPublishFfi.meshOnly =>
      'the sealed location was not sent to a relay (${publish.name}), so '
          'the lane cannot judge the classification of a refusal.',
  };
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

/// Holds when the ONLY member Haven has heard from raises the peer signal on
/// its own.
///
/// The sole-source half of the corroboration rule, and the one a revert to a
/// flat `minCorroboratingSources = 2` fails. A two-member circle can never
/// produce a second corroborating member, so a rule that always waits for one
/// leaves the most common circle size structurally unable to see a
/// disagreement it can never corroborate. Corroboration is still what makes a
/// lone member's report evidence about *this device* rather than about that
/// member — so the moment a second member is heard the exception is withdrawn
/// and the two-source bar governs again, unchanged. That direction is
/// unobservable on this lane (the backward jump puts every real peer ahead),
/// so it is pinned by `clock_skew_detector_test.dart` instead.
///
/// A sole source supports a strictly weaker claim than a corroborated one, and
/// the banner must say so — see [checkSoleSourceCopyHedged].
///
/// [sourcesFed] is asserted rather than trusted: a predicate handed zero or
/// two samples would be answering a different question, which is the failure
/// shape this repo keeps finding.
String? checkSoleSourceRaisesVerdict(
  ClockSkewStatus status, {
  required int sourcesFed,
  required int thresholdSecs,
}) {
  if (sourcesFed != 1) {
    return 'HARNESS: the sole-source probe was fed $sourcesFed sample(s), '
        'not 1, so it proves nothing about a two-member circle.';
  }
  if (status.signal != ClockSkewSignal.peersAheadOfDevice) {
    return 'the only member this device can hear from reported a time more '
        'than ${thresholdSecs}s ahead and the verdict is still '
        '"${status.signal.name}". No second member exists to corroborate it, '
        'so a rule that waits for one is silent forever on the commonest '
        'circle size — while every publish keeps reporting success.';
  }
  if (status.complaint != DeviceClockComplaint.behind) {
    return 'the sole-source verdict fired with complaint '
        '"${status.complaint?.name ?? '-'}" instead of "behind" — the copy '
        'shown to the user is chosen from the direction, so a wrong direction '
        'is wrong advice.';
  }
  if (status.corroboratingSources != 1) {
    return 'the sole-source verdict claims '
        '${status.corroboratingSources} corroborating source(s) from ONE '
        'member. The count is the evidence the verdict rests on and must not '
        'be inflated to the nominal '
        '${ClockSkewDetector.minCorroboratingSources}.';
  }
  return null;
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
    return 'the $fault banner rendered '
        '${magnitudeBucket(renderedTexts.length)} text(s) but '
        'none of them is the copy this fault is supposed to show.';
  }
  return null;
}

/// Holds when a SOLE-SOURCE verdict is surfaced with copy that neither
/// accuses this phone nor claims a loss.
///
/// The evidence is one member, which establishes a disagreement and nothing
/// else. Two things the corroborated copy asserts anyway:
///
/// * **Whose clock.** The two devices are not symmetric observers — a peer
///   running fast makes THIS device fire while the peer's own detector stays
///   silent (negative offsets are structurally uninformative) — so
///   `clockSkewTitle` ("this phone's clock is wrong") would accuse the
///   innocent device and never the guilty one.
/// * **Whether anything is lost.** An online member still receives every
///   location until the gap reaches 228 s (the relay pool drops a location
///   once it has expired, with no grace), while the signal fires at 120 s, and
///   one member cannot say which side lags. So `clockSkewBodyBehind` ("the
///   locations it sends expire early, and your circles can miss some or all
///   of them") asserts a loss on this phone the evidence does not place
///   there, and its remedy cannot clear it.
///
/// So this is not a style check: the two corroborated strings are the exact
/// user-visible false claims, and the oracle names them.
String? checkSoleSourceCopyHedged({
  required List<String> renderedTexts,
  required String hedgedTitle,
  required String hedgedBody,
  required String corroboratedTitle,
  required String corroboratedBody,
}) {
  if (renderedTexts.isEmpty) {
    return 'the sole-source verdict painted NOTHING, so the fault is as '
        'silent as it was before the surface existed.';
  }
  for (final banned in <String>[corroboratedTitle, corroboratedBody]) {
    if (renderedTexts.contains(banned)) {
      return 'a verdict resting on ONE member rendered the corroborated '
          'copy, which asserts both that this phone is the wrong one and that '
          'its locations are expiring early. Neither follows from one '
          'sample: under a 228 s gap an online member still receives every '
          'location, and one member cannot say which side lags.';
    }
  }
  if (!renderedTexts.contains(hedgedTitle) ||
      !renderedTexts.contains(hedgedBody)) {
    return 'the sole-source verdict rendered '
        '${magnitudeBucket(renderedTexts.length)} text(s), '
        'but not the hedged title AND body this case is required to show.';
  }
  return null;
}

/// Holds when the two faults say DIFFERENT things.
///
/// A relay rejection means nothing is being shared at all; the peer signal
/// means the send succeeded and the data then expired early. Collapsing them
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
        '(rejected=${magnitudeBucket(rejectedBody.length)} chars, '
        'behind=${magnitudeBucket(behindBody.length)} chars), so one fault '
        'has no copy at all.';
  }
  if (rejectedBody == behindBody) {
    return 'both faults render the SAME body. "your location is not reaching '
        'anyone" and "your location is being sent and discarded" are '
        'different situations with different consequences, and one shared '
        'sentence necessarily misstates one of them.';
  }
  return null;
}

/// Holds when a peer location did NOT reach a device whose clock runs past the
/// total-loss point ahead.
///
/// The caller has already shown the relay still held the location when the
/// device fetched it, so a missing location was dropped on the device: by the
/// relay pool, on receipt, because its NIP-40 expiration was behind the
/// device's clock. `kClockSkewTotalLossThreshold`, the alert threshold's upper
/// bound and the banner copy are all derived from that drop point.
String? checkPoolDropsPastTotalLoss({required bool delivered}) {
  if (delivered) {
    return 'a peer location reached a device whose clock runs past the '
        'total-loss point ahead, while its expiration was behind that clock. '
        'The relay pool no longer drops an expired event on receipt, so '
        'kClockSkewTotalLossThreshold is not the drop point and every '
        'threshold and banner derived from it is wrong.';
  }
  return null;
}
