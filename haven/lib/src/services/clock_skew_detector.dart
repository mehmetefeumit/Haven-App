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
///   died in a `debugPrint`.
/// * **Clock behind** — the expiration is computed from the same skewed clock,
///   so the event is born already expired. The relay still ACKs it, **the
///   publisher reports success**, and a correctly-clocked peer discards it
///   before decryption. The loss is total and indistinguishable from working.
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
import 'package:haven/src/services/relay_service.dart';

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
      'offsetSecs: $offsetSecs, sources: $corroboratingSources)';
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

  /// The Haven-authored token that carries a device-clock classification
  /// across the FFI's `Result<T, String>` error flattening.
  ///
  /// Emitted by `RelayError::DeviceClockRejected`'s `Display`
  /// (`haven-core/src/relay/clock_skew.rs`). Contains no relay-controlled
  /// text by construction, so matching it cannot be steered by a hostile
  /// relay. The two literals are pinned together by
  /// `scripts/ci/check_clock_skew_policy_parity.sh`.
  static const String deviceClockRejectedToken =
      'haven.clock.device_clock_rejected';

  /// Distinct MLS-authenticated members that must independently agree before
  /// the peer signal fires.
  ///
  /// Two, not one: a single member's clock being wrong is far more likely than
  /// everyone else's, so one sample is never evidence about *us*. Because
  /// samples are keyed by member id, one member can never supply two of them —
  /// firing this signal falsely requires two *colluding* members who are
  /// already trusted with the user's location, and the worst they achieve is a
  /// warning banner: the verdict never changes what Haven signs, publishes, or
  /// stores.
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

  /// Extracts a device-clock classification from an error raised by the
  /// publish path, or `null` when the error is not a clock rejection.
  ///
  /// Matches only the Haven-authored [deviceClockRejectedToken]; a relay's own
  /// words are never part of this string (Security Rule 8) and are never
  /// inspected here.
  static DeviceClockComplaint? complaintFromError(Object error) {
    final text = error is String ? error : error.toString();
    const marker = '$deviceClockRejectedToken:';
    final start = text.indexOf(marker);
    if (start < 0) return null;
    final suffix = text.substring(start + marker.length);
    // Stop at the first non-token character so a wrapped/decorated error
    // ("... haven.clock.device_clock_rejected:ahead)") still parses.
    final match = RegExp('^[a-z]+').firstMatch(suffix);
    return _complaintFromWireToken(match?.group(0) ?? '');
  }

  static DeviceClockComplaint? _complaintFromWireToken(String token) {
    switch (token) {
      case 'ahead':
        return DeviceClockComplaint.ahead;
      case 'behind':
        return DeviceClockComplaint.behind;
      case 'unspecified':
        return DeviceClockComplaint.unspecified;
      default:
        return null;
    }
  }

  /// Classifies a single relay rejection reason.
  ///
  /// A Dart mirror of
  /// `haven_core::relay::clock_skew::classify_relay_rejection`,
  /// needed for the *partial* rejection case: when one relay accepts and
  /// another rejects, Rust returns `Ok`, so the reasons reach Dart as
  /// [RelayRejection] text rather than as a classified error. The two
  /// implementations are pinned together by
  /// `scripts/ci/check_clock_skew_policy_parity.sh`.
  ///
  /// Returns `null` for every rejection that is not about the timestamp (rate
  /// limits, auth, proof-of-work, size caps, blocked kinds, transport errors),
  /// so an ordinary outage is never misreported to the user as a broken clock.
  static DeviceClockComplaint? classifyRelayRejection(String reason) {
    final lowered = reason.toLowerCase();
    bool containsAny(List<String> phrases) => phrases.any(lowered.contains);

    if (containsAny(_aheadPhrases)) return DeviceClockComplaint.ahead;
    if (containsAny(_behindPhrases)) return DeviceClockComplaint.behind;
    if (containsAny(_unspecifiedPhrases)) {
      return DeviceClockComplaint.unspecified;
    }
    return null;
  }

  static const List<String> _aheadPhrases = <String>[
    'in the future',
    'into the future',
    'too new',
    'newer than',
    'future timestamp',
    'future created_at',
  ];

  static const List<String> _behindPhrases = <String>[
    'too old',
    'older than',
    'in the past',
    'into the past',
    'outdated',
    'event expired',
    'event is expired',
    'expired event',
  ];

  // Deliberately excludes the bare word `time`: "connection timed out" is a
  // transport failure, not a clock verdict, and transport errors share the
  // rejection channel with genuine `OK false` reasons.
  static const List<String> _unspecifiedPhrases = <String>[
    'too far off',
    'created_at',
    'creation date',
    'creation time',
    'timestamp',
    'time stamp',
    'clock',
    'current time',
    'time skew',
    'invalid time',
  ];

  /// Records the outcome of a publish that returned a [PublishResult].
  ///
  /// A publish that reached at least one relay clears the relay signal: the
  /// location is on the network, so telling the user their clock is broken
  /// would be crying wolf. A publish that reached none, where at least one
  /// relay blamed the timestamp, raises it.
  void recordPublishResult(PublishResult result) {
    if (result.isSuccess) {
      _setRelayComplaint(null);
      return;
    }
    DeviceClockComplaint? merged;
    for (final rejection in result.rejectedBy) {
      final complaint = classifyRelayRejection(rejection.reason);
      if (complaint == null) continue;
      merged = merged == null ? complaint : _merge(merged, complaint);
    }
    _setRelayComplaint(merged);
  }

  /// Records a publish that threw.
  ///
  /// Raises the relay signal when the error is a [RelayClockRejectionException]
  /// or carries [deviceClockRejectedToken]; leaves the current verdict
  /// untouched otherwise, because an ordinary transport failure says nothing
  /// either way about the clock — clearing the verdict there would let one
  /// dropped connection hide a clock that is still wrong.
  ///
  /// The typed branch makes this method total over the error vocabulary its own
  /// service layer actually throws. [RelayClockRejectionException.toString]
  /// deliberately does not embed [deviceClockRejectedToken] — the token lives
  /// in a field so the relay layer needs no dependency on this enum — so
  /// [complaintFromError] cannot parse one out of it. A caller that reaches for
  /// the generic entry point with the typed exception in hand would otherwise
  /// drop the classification silently. Production catches the typed exception
  /// first and calls [recordPublishClockRejection] directly; this is the
  /// backstop for every other caller, not a replacement for that call site.
  ///
  /// The two branches differ on ONE input, deliberately: an *unrecognised*
  /// token. The typed branch degrades it to
  /// [DeviceClockComplaint.unspecified] (a fault the relays typed as a clock
  /// complaint is still a clock complaint, whatever direction word it used),
  /// while the text branch stays silent (arbitrary error prose must not be
  /// read as a verdict). Not reachable in production — the token is built from
  /// a [DeviceClockComplaint]'s `name`, a closed enum — so this is a contract
  /// for future wire tokens, not a live divergence.
  void recordPublishError(Object error) {
    if (error is RelayClockRejectionException) {
      recordPublishClockRejection(error.complaintToken);
      return;
    }
    final complaint = complaintFromError(error);
    if (complaint == null) return;
    _setRelayComplaint(complaint);
  }

  /// Records a publish refused on timestamp grounds, from an already-parsed
  /// wire token (`ahead` / `behind` / `unspecified`).
  ///
  /// Used by the service layer, which receives the classification as a typed
  /// `RelayClockRejectionException` rather than as raw error text. An
  /// unrecognised token degrades to [DeviceClockComplaint.unspecified] rather
  /// than to silence: the relays did refuse the timestamp, and only the
  /// direction is unknown.
  void recordPublishClockRejection(String wireToken) {
    _setRelayComplaint(
      _complaintFromWireToken(wireToken) ?? DeviceClockComplaint.unspecified,
    );
  }

  static DeviceClockComplaint _merge(
    DeviceClockComplaint a,
    DeviceClockComplaint b,
  ) {
    if (a == DeviceClockComplaint.unspecified) return b;
    if (b == DeviceClockComplaint.unspecified) return a;
    if (a == b) return a;
    // Two relays that disagree about the direction: report the fact, not a
    // coin flip.
    return DeviceClockComplaint.unspecified;
  }

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
  ///   NIP-40 expiration is more than `RECEIVER_EXPIRATION_GRACE_SECS` past is
  ///   dropped by the receiver before decryption, so every sample that reaches
  ///   this method already satisfies `offset > -(228 + 60)`. The evidence for
  ///   "our clock is ahead" has been discarded before we could see it, and any
  ///   threshold small enough to fire inside that window would fire on ordinary
  ///   catch-up delivering a two-minute-old location. The *ahead* direction is
  ///   covered by signal 1 instead, where a relay reports it directly.
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
    debugPrint(
      '[ClockSkew] verdict: ${next.signal.name} '
      'complaint=${next.complaint?.name ?? "-"} '
      'sources=${next.corroboratingSources}',
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
    for (final sample in _peerSamples.values) {
      if (now.difference(sample.observedAt) > peerSampleTtl) continue;
      if (sample.offsetSecs >= kClockSkewAlertThreshold.inSeconds) {
        corroborating.add(sample.offsetSecs);
      }
    }
    if (corroborating.length < minCorroboratingSources) {
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
