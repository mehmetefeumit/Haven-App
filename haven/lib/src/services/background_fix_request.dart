/// The arithmetic behind the Android foreground service's single platform
/// location request.
///
/// While the app is backgrounded with sharing on, the FGS holds exactly ONE
/// `LocationManager` registration and publishes on its deliveries. The
/// registration's interval is therefore the whole cadence: it decides when the
/// GNSS receiver runs (the platform hibernates it until `lastFix + interval`,
/// §2.2 of `docs/POWER_EFFICIENCY_PLAN.md`) and, because a publish now rides a
/// delivery instead of a software tick, it also decides every circle's realized
/// inter-publish gap — which the 228 s NIP-40 retention that keeps a peer's
/// marker alive has to cover.
///
/// It covers it everywhere but one corner, which the sweep states rather than
/// assumes away: on API 23–30 a cold (30 s) TTFF is paid TWICE per
/// registration, and `J + rho + sigma ≥ 178 s` then puts the realized gap at
/// or past the retention, up to 248 s. The peer's marker expires for at most
/// 20 s, and returns on the next publish.
///
/// Pure on purpose: no clock, no plugin, no I/O. That is what lets the gap
/// proof in D3 (iii) be a swept proof rather than a handful of examples
/// (`test/services/background_fix_request_test.dart`).
library;

import 'package:haven/src/constants/location.dart';

/// The interval to ask the platform for, so the next fix arrives
/// [kBackgroundFixLeadTime] before [earliestDue].
///
/// [now] is the instant the registration is issued — early in the cycle, ahead
/// of its publishes. [plannedPublishStart] is when this cycle's first publish
/// is planned for, or [now] when nothing is due; it anchors the ceiling, so a
/// capped request still leaves the lead intact for the publish that follows it.
///
/// The result is bounded on both sides, and the two bounds mean different
/// things:
///
/// * **Floor — [kMinFixRequestInterval].** A platform bound (see the constant).
///   It is deliberately NOT anchored at the publish this registration follows:
///   a floor of `kLocationPublishMinInterval` (or of that minus the lead) would
///   starve a second circle whose own cadence falls 31–71 s later. That the
///   steady-state single-circle request is at least
///   `kLocationPublishMinInterval − kBackgroundFixLeadTime` (62 s) is a
///   consequence of [earliestDue], which for a circle just published is its
///   publish start plus a sampled interval of at least 72 s — not of a clamp.
/// * **Ceiling — [kLocationPublishMaxInterval], measured from the publish this
///   registration follows minus the lead.** A due-time far in the future (a
///   forward device-clock jump, a schedule restored stale) would otherwise
///   silence the receiver until it arrived. The tighter of the two anchors
///   applies, so the request never exceeds one max publish interval and the
///   fix it schedules is never more than `max − lead` after the publish it
///   follows.
///
/// The floor is applied last, so it wins over the ceiling: an interval under
/// it is not a duty-cycled request at all.
Duration nextFixRequestInterval({
  required DateTime earliestDue,
  required DateTime now,
  required DateTime plannedPublishStart,
}) {
  final target = earliestDue.subtract(kBackgroundFixLeadTime);
  final latest = _earlier(
    plannedPublishStart.add(
      kLocationPublishMaxInterval - kBackgroundFixLeadTime,
    ),
    now.add(kLocationPublishMaxInterval),
  );
  final interval = _earlier(target, latest).difference(now);
  return interval < kMinFixRequestInterval ? kMinFixRequestInterval : interval;
}

/// Whether a live registration aimed at [registeredTarget] is close enough to
/// [target] to keep.
///
/// Re-registering costs a cancel + listen and, on S+, an immediate historical
/// re-delivery of the fix just consumed — which drives another cycle, which
/// would re-register again. This is the loop breaker, so it is deliberately
/// symmetric: an aim that moved EARLIER by no more than [kRegistrationSlack]
/// is as much a non-event as one that moved later.
bool registrationIsAligned(DateTime registeredTarget, DateTime target) =>
    registeredTarget.difference(target).abs() <= kRegistrationSlack;

DateTime _earlier(DateTime a, DateTime b) => a.isBefore(b) ? a : b;
