/// Device-clock skew detection from signals Haven already receives.
///
/// ## The defect this exists to close
///
/// Every wall-clock dependency on the send path bottoms out in one unguarded
/// `SystemTime::now()`. The MDK peeler stamps the inner application event
/// with `now_unix_seconds()` and binds the outer kind-445 `created_at` to it,
/// and the engine derives the NIP-40 `expiration` as `created_at + 228 s`. A
/// device with a wrong clock therefore signs events that are wrong in *both*
/// fields, and both resulting failures used to be completely silent:
///
/// * **Clock ahead** — a spec-conformant relay refuses every event as being in
///   its future, so location sharing is dead for the session. The rejection
///   died in a `debugPrint`. Inside the relay's future window the publish is
///   accepted instead and the device goes deaf: once it runs
///   [kClockSkewTotalLossThreshold] ahead, its own relay pool discards every
///   peer location as expired. Neither signal below sees that case — the relay
///   took the event, and the peer timestamps are in the events that were
///   dropped.
/// * **Clock behind** — the expiration is computed from the same skewed clock,
///   so the event expires early, or is born expired. The relay still ACKs it,
///   **the publisher reports success**, and a correctly-clocked peer's relay
///   pool discards it on receipt once it has expired. Past
///   [kClockSkewTotalLossThreshold] the loss is total and indistinguishable
///   from working.
///
/// ## The time reference, and what it deliberately is NOT
///
/// Haven never contacts a third party for time — no NTP, no `time.google.com`,
/// no HTTP `Date` probe. Any of those would add an unencrypted, correlatable
/// network fingerprint to a privacy-first app (Security Rule 10). Both signals
/// come from connections Haven already makes:
///
/// 1. **The relay's `OK false` reason** (the *ahead* direction). A relay that
///    refuses an event on timestamp grounds is a correctly-clocked observer
///    saying so directly. Classified in Rust
///    (`haven-core/src/relay/clock_skew.rs`) so no relay prose ever crosses the
///    FFI; only the closed [DeviceClockComplaint] classification does.
/// 2. **MLS-authenticated peer timestamps** (the *behind* direction). See
///    [ClockSkewDetector.recordPeerTimestamp].
///
/// Neither signal ever rewrites `created_at`. Publishing a timestamp that
/// disagrees with the device clock has protocol consequences (the TTL, the
/// `since` cursor and the peeler's inner/outer binding all ride the same value)
/// and would need its own security analysis. Surfacing the problem is in scope;
/// forging around it is not.
///
/// ## Why the peer signal is trustworthy and the obvious one is not
///
/// The outer kind-445 `created_at` is **attacker-writable and never
/// authenticated**: anyone who has observed one of a circle's events can mint
/// kind-445s carrying arbitrary timestamps. It is therefore never used here.
///
/// What this class consumes instead is `DecryptedLocation.timestamp` — the
/// sender's own clock reading from *inside* the MLS ciphertext — attributed to
/// `senderPubkey`, the MLS-authenticated member id. Producing one requires the
/// current epoch's key material, i.e. requires being a current member of the
/// circle. See [ClockSkewDetector.recordPeerTimestamp] for the resulting
/// threat model.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:haven/src/constants/location.dart';
import 'package:haven/src/rust/api.dart'
    show DeviceClockComplaintFfi, LocationPublishFfi;
import 'package:haven/src/utils/log_alias.dart';

/// What the evidence says about the direction of this device's clock error.
enum DeviceClockComplaint {
  /// The device clock runs fast (events land in the relay's future).
  ahead,

  /// The device clock runs slow (events are born expired; peers are ahead).
  behind,

  /// The timestamp was named as the problem, but not the direction. strfry's
  /// "event too far off from the current time" is the canonical example.
  unspecified,
}

/// Which signal, if any, is currently accusing the device clock.
enum ClockSkewSignal {
  /// No evidence of clock skew.
  none,

  /// No relay accepted a location, and at least one blamed the timestamp.
  /// Location sharing is not working *right now*.
  relayRejectedTimestamp,

  /// Independent, MLS-authenticated circle members consistently report times
  /// in this device's future. Publishing appears to succeed but peers are
  /// discarding the results.
  peersAheadOfDevice,
}

/// A snapshot of the clock-skew verdict.
@immutable
class ClockSkewStatus {
  /// Creates a status snapshot.
  const ClockSkewStatus({
    this.signal = ClockSkewSignal.none,
    this.complaint,
    this.offsetSecs,
    this.corroboratingSources = 0,
  });

  /// The all-clear.
  static const ClockSkewStatus healthy = ClockSkewStatus();

  /// Which signal fired.
  final ClockSkewSignal signal;

  /// Direction of the error, when the evidence states one.
  final DeviceClockComplaint? complaint;

  /// Measured magnitude in seconds, when the evidence provides one.
  ///
  /// Only the peer signal measures a magnitude; a relay rejection reports a
  /// direction but no size, so this is `null` for
  /// [ClockSkewSignal.relayRejectedTimestamp].
  final int? offsetSecs;

  /// How many distinct MLS-authenticated members corroborated the peer signal.
  final int corroboratingSources;

  /// Whether the device clock is currently under suspicion.
  bool get isSkewed => signal != ClockSkewSignal.none;

  @override
  bool operator ==(Object other) =>
      other is ClockSkewStatus &&
      other.signal == signal &&
      other.complaint == complaint &&
      other.offsetSecs == offsetSecs &&
      other.corroboratingSources == corroboratingSources;

  @override
  int get hashCode =>
      Object.hash(signal, complaint, offsetSecs, corroboratingSources);

  @override
  String toString() =>
      'ClockSkewStatus(signal: $signal, complaint: $complaint, '
      'offsetSecs: $offsetSecs, '
      'sources: ${magnitudeBucket(corroboratingSources)})';
}

/// One MLS-authenticated member's most recent clock reading.
@immutable
class _PeerSample {
  const _PeerSample({required this.offsetSecs, required this.observedAt});

  /// `peerTimestamp - localNow`, in seconds. Positive means the peer's clock
  /// is ahead of ours.
  final int offsetSecs;

  /// Local time the sample was taken (used only for expiry).
  final DateTime observedAt;
}

/// Accumulates clock-skew evidence and reports a verdict.
///
/// One instance per app (a Riverpod singleton). It holds no secrets: only
/// per-member second offsets keyed by public MLS member ids, all of which the
/// caller already has in hand.
class ClockSkewDetector {
  /// Creates a detector.
  ///
  /// [now] is injectable so tests can drive the sample-expiry logic without
  /// sleeping.
  ClockSkewDetector({DateTime Function() now = DateTime.now}) : _now = now;

  /// Distinct MLS-authenticated members that must independently agree before
  /// the peer signal fires — whenever that many members are *available* to
  /// agree. See [_evaluate] for the sole-source exception.
  ///
  /// Two, not one: while a second member is reachable, that member's agreement
  /// with our clock is direct evidence that the odd one out is the outlier,
  /// and a single member's clock being wrong is far more likely than everyone
  /// else's. Because samples are keyed by member id, one member can never
  /// supply two of them — firing this signal falsely requires two *colluding*
  /// members who are already trusted with the user's location, and the worst
  /// they achieve is a warning banner: the verdict never changes what Haven
  /// signs, publishes, or stores.
  static const int minCorroboratingSources = 2;

  /// How long a peer sample stays evidence.
  ///
  /// Peers republish at most every `kLocationPublishMaxInterval` (168 s), so
  /// this covers roughly five missed cycles — long enough that an intermittent
  /// peer still corroborates, short enough that the banner clears within
  /// minutes of the clock being fixed.
  static const Duration peerSampleTtl = Duration(minutes: 15);

  /// Upper bound on tracked members, so a large or churning roster cannot grow
  /// this map without limit. Oldest sample is evicted first.
  static const int maxTrackedSources = 64;

  final DateTime Function() _now;
  final Map<String, _PeerSample> _peerSamples = <String, _PeerSample>{};
  final StreamController<ClockSkewStatus> _changes =
      StreamController<ClockSkewStatus>.broadcast();

  DeviceClockComplaint? _relayComplaint;
  ClockSkewStatus _status = ClockSkewStatus.healthy;

  /// The current verdict.
  ClockSkewStatus get status => _status;

  /// Emits whenever [status] changes value.
  Stream<ClockSkewStatus> get changes => _changes.stream;

  // -------------------------------------------------------------------------
  // Signal 1 — the relay's own verdict on our timestamp (the *ahead*
  // direction).
  // -------------------------------------------------------------------------

  /// Records what the one send of a sealed location did, by variant: a send
  /// a relay took clears the relay signal, and so does one every answering
  /// relay refused for something other than its time (the relays judged the
  /// event and blamed nothing about its clock); one no relay took with at
  /// least one blaming its timestamp raises it in that direction; one no
  /// relay was reached for, or that was not sent to a relay, says nothing
  /// either way.
  void recordLocationPublish(LocationPublishFfi publish) {
    switch (publish) {
      case LocationPublishFfi.accepted || LocationPublishFfi.refused:
        _setRelayComplaint(null);
      case LocationPublishFfi.clockAhead:
        _setRelayComplaint(DeviceClockComplaint.ahead);
      case LocationPublishFfi.clockBehind:
        _setRelayComplaint(DeviceClockComplaint.behind);
      case LocationPublishFfi.clockUnspecified:
        _setRelayComplaint(DeviceClockComplaint.unspecified);
      case LocationPublishFfi.unreachable ||
          LocationPublishFfi.expired ||
          LocationPublishFfi.superseded ||
          LocationPublishFfi.ended ||
          LocationPublishFfi.inFlight ||
          LocationPublishFfi.meshOnly:
        break;
    }
  }

  /// Records what a drive's relays blamed on this device's clock, by variant:
  /// the core hands it over only when no relay took what the drive sent
  /// (a seal's, a leave's, a change's, an ingest's or a resume's drives). A
  /// drive that blamed nothing says nothing either way: it may have sent
  /// nothing at all.
  void recordDriveClockRejection(DeviceClockComplaintFfi complaint) {
    _setRelayComplaint(switch (complaint) {
      DeviceClockComplaintFfi.ahead => DeviceClockComplaint.ahead,
      DeviceClockComplaintFfi.behind => DeviceClockComplaint.behind,
      DeviceClockComplaintFfi.unspecified => DeviceClockComplaint.unspecified,
    });
  }

  /// Records a change a relay acknowledged: a relay took this device's
  /// timestamp, so the relay signal clears, as an answered location send
  /// clears it — a clock that was fixed stops showing the banner even with
  /// sharing off.
  void recordDriveAccepted() => _setRelayComplaint(null);

  void _setRelayComplaint(DeviceClockComplaint? complaint) {
    if (_relayComplaint == complaint) {
      _recompute();
      return;
    }
    _relayComplaint = complaint;
    _recompute();
  }

  // -------------------------------------------------------------------------
  // Signal 2 — corroborated peer timestamps (the *behind* direction).
  // -------------------------------------------------------------------------

  /// Records one MLS-authenticated member's clock reading.
  ///
  /// [peerTimestamp] MUST be `DecryptedLocation.timestamp` — the sender's own
  /// reading from *inside* the MLS ciphertext — and [senderPubkey] MUST be
  /// the MLS-authenticated member id that came back with it. Never pass the
  /// outer kind-445 `created_at`: it is unauthenticated and
  /// attacker-writable, so anyone who has seen one of the circle's events
  /// could steer this signal.
  ///
  /// ## Why only the "device is behind" direction is inferred
  ///
  /// The two directions are not symmetric, and treating them as if they were
  /// would produce a detector that cries wolf:
  ///
  /// * **Positive offsets carry no legitimate bias.** A correctly-clocked peer
  ///   never stamps a future time, and every source of delay between their
  ///   `encrypt` and our `decrypt` pushes the observed offset *more negative*.
  ///   So a consistently positive offset can only be clock disagreement.
  /// * **Negative offsets are structurally uninformative.** An event whose
  ///   NIP-40 expiration is behind this device's clock is dropped by the relay
  ///   pool on receipt, so every sample that reaches this method already
  ///   satisfies `offset >= -228`. The evidence for "our clock is ahead" has
  ///   been discarded before we could see it, and any threshold small enough
  ///   to fire inside that window would fire on ordinary catch-up delivering a
  ///   two-minute-old location. The *ahead* direction is covered by signal 1
  ///   instead, where a relay reports it directly — and only there, so a
  ///   device ahead by less than the relay's own future window is not
  ///   detected at all.
  void recordPeerTimestamp({
    required String senderPubkey,
    required DateTime peerTimestamp,
  }) {
    final key = senderPubkey.toLowerCase();
    if (key.isEmpty) return;
    final observedAt = _now();
    final offset = peerTimestamp.difference(observedAt).inSeconds;

    _peerSamples[key] = _PeerSample(offsetSecs: offset, observedAt: observedAt);
    _evictExpiredAndOverflow(observedAt);
    _recompute();
  }

  void _evictExpiredAndOverflow(DateTime now) {
    _peerSamples.removeWhere(
      (_, s) => now.difference(s.observedAt) > peerSampleTtl,
    );
    while (_peerSamples.length > maxTrackedSources) {
      // Dart's default Map is insertion-ordered and every write re-inserts,
      // so the first key is the least recently updated.
      _peerSamples.remove(_peerSamples.keys.first);
    }
  }

  /// Test seam: how many distinct members currently hold a sample.
  @visibleForTesting
  int get trackedSourceCountForTest => _peerSamples.length;

  /// Forgets all accumulated evidence (identity deletion, sign-out, tests).
  void reset() {
    _peerSamples.clear();
    _relayComplaint = null;
    _recompute();
  }

  /// Releases the change stream.
  Future<void> dispose() => _changes.close();

  // -------------------------------------------------------------------------
  // Verdict
  // -------------------------------------------------------------------------

  void _recompute() {
    final next = _evaluate();
    if (next == _status) return;
    _status = next;
    // log-scan-ok: signal/complaint are enum variant names, sources bucketed
    debugPrint(
      '[ClockSkew] verdict: ${next.signal.name} '
      'complaint=${next.complaint?.name ?? "-"} '
      'sources=${magnitudeBucket(next.corroboratingSources)}',
    );
    if (!_changes.isClosed) _changes.add(next);
  }

  ClockSkewStatus _evaluate() {
    // The relay signal outranks the peer signal: it means location sharing is
    // failing *right now*, whereas the peer signal means it is failing
    // invisibly. Both are worth saying; the more urgent one wins the surface.
    final relayComplaint = _relayComplaint;
    if (relayComplaint != null) {
      return ClockSkewStatus(
        signal: ClockSkewSignal.relayRejectedTimestamp,
        complaint: relayComplaint,
      );
    }

    final now = _now();
    final corroborating = <int>[];
    var liveSources = 0;
    for (final sample in _peerSamples.values) {
      if (now.difference(sample.observedAt) > peerSampleTtl) continue;
      liveSources++;
      if (sample.offsetSecs >= kClockSkewAlertThreshold.inSeconds) {
        corroborating.add(sample.offsetSecs);
      }
    }
    // The sole-source exception. [minCorroboratingSources] asks a second
    // member to break the tie between "our clock is behind" and "theirs is
    // ahead" — but in a two-member circle there IS no second member, so the
    // bar is not merely unmet, it is unmeetable, and the most common circle
    // size was structurally blind to a fault that loses 100 % of its
    // updates silently (the whole reason this detector exists).
    //
    // Firing on one member is therefore allowed ONLY when that member is the
    // only one Haven has heard from inside [peerSampleTtl]. The moment a
    // second member is heard the exception is withdrawn and the two-source
    // bar governs again, so a verdict raised while alone clears if that
    // second member turns out to agree with this device. Everything above one
    // live sample behaves exactly as it did before — this is an added
    // exception, not a relaxed bar.
    //
    // What a sole source can and cannot support, exactly: with one peer,
    // "we are behind" and "they are ahead" are indistinguishable from inside
    // this process. Nor does a disagreement of this size prove any loss: a
    // location keeps `228 s - gap` of residency, so until the gap reaches
    // [kClockSkewTotalLossThreshold] (228 s) a member who is online still
    // receives every one, and only a member who catches up later can find one
    // already expired. Between 120 s and that point, all that is known is that
    // the clocks disagree.
    //
    // That is why the sole-source verdict must NOT be surfaced with the copy
    // the corroborated one uses: `resolveClockSkewCopy`
    // (`widgets/location/clock_skew_banner.dart`) branches on
    // `corroboratingSources == 1` and renders a hedged title and body that
    // name neither a culprit nor a loss. Anything that raises this signal on
    // one source without that branch is a user-visible false claim.
    final soleSource =
        liveSources == 1 && corroborating.length == 1;
    if (!soleSource && corroborating.length < minCorroboratingSources) {
      return ClockSkewStatus.healthy;
    }
    corroborating.sort();
    return ClockSkewStatus(
      signal: ClockSkewSignal.peersAheadOfDevice,
      complaint: DeviceClockComplaint.behind,
      // The smallest offset that every corroborating member independently
      // exceeded: a lower bound on the lag, which no single member can
      // inflate.
      offsetSecs: corroborating.first,
      corroboratingSources: corroborating.length,
    );
  }
}
