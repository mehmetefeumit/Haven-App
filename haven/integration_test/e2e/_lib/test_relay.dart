/// Lightweight Nostr client used by E2E scenarios to observe the local
/// strfry relay.
///
/// `TestRelay` is *not* part of the system under test — it is a probe layer
/// that lets scenarios assert "did event X land on the relay?" and wait for
/// cross-process synchronization barriers (e.g. "Bob's instance should not
/// proceed until Alice's gift-wrap is observable").
///
/// The production code uses `NostrRelayService` for relay interaction; this
/// helper deliberately bypasses it so probe state stays independent of the
/// SUT.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:web_socket_channel/web_socket_channel.dart';

/// Default URL the strfry container exposes on the host. Android emulators
/// reach the host via the well-known alias `10.0.2.2`; iOS simulators reach
/// it via `localhost`. CI passes the right URL via `--dart-define`.
const String defaultStrfryUrl = String.fromEnvironment(
  'HAVEN_E2E_RELAY',
  defaultValue: 'ws://localhost:7777',
);

/// URL of the SECOND hermetic strfry instance (relay R2).
///
/// Distinct from [defaultStrfryUrl] (R1). The relay-customization tests add
/// R2 to the user's relay preferences and then assert that events (kind 30443,
/// 10002, 10050, 445) actually land on R2. Using a physically separate relay
/// process makes the proof definitive: if the production add-relay path
/// silently failed, events would arrive on R1 only and every `firstWhere` on
/// `r2` would time out, turning the test red. CI spins up a second strfry
/// container bound to the port below (7778) alongside the first (7777).
const String secondStrfryUrl = String.fromEnvironment(
  'HAVEN_E2E_RELAY_2',
  defaultValue: 'ws://localhost:7778',
);

/// The compiled-in value when a lane passes no `--dart-define`. Named so the
/// "is this an instrumented run?" test below is a comparison against one
/// constant rather than a magic string repeated at each call site.
const String kDefaultWireSentinelToken =
    'HAVEN_WIRE_SENTINEL:default0000000000000000000000000000';

/// Token carried by the wire-journal sentinel frame
/// ([TestRelay.emitWireJournalSentinel]).
///
/// The lane generates a fresh token, hands the SAME string to the drive (via
/// this define) and to the host oracle (via
/// `check-wire-journal.sh --sentinel`), so the two agree without the host
/// having to scrape it back out of a log:
///
/// ```sh
/// TOKEN="HAVEN_WIRE_SENTINEL:$(openssl rand -hex 16)"
/// flutter drive --dart-define=HAVEN_WIRE_SENTINEL="$TOKEN" …
/// bash tooling/e2e/ci/check-wire-journal.sh --sentinel "$TOKEN" …
/// ```
///
/// The default keeps a local `flutter drive` working with no extra flags; a
/// journal only ever covers one run, so a fixed default cannot collide with a
/// previous one. The `HAVEN_WIRE_SENTINEL:` prefix is the shared contract —
/// keep it, because the oracle matches the token as a literal substring of the
/// recorded line and a bare hex string could occur inside ordinary frame
/// content.
const String wireJournalSentinelToken = String.fromEnvironment(
  'HAVEN_WIRE_SENTINEL',
  defaultValue: kDefaultWireSentinelToken,
);

/// Whether THIS BUILD was made by a lane that declared a recording proxy.
///
/// The token is minted per run by the lane and passed to the drive and to the
/// host oracles as one string; `scripts/ci/check_wire_oracle_lane_reachable.sh`
/// (link 4) pins that a lane which runs an oracle also passes this define. So a
/// non-default token is a lane's explicit statement that a recorder is in path.
///
/// This gates [TestRelay.announceMlsGroupId], and it is a SECURITY gate, not a
/// convenience one. `e2e-flakiness-stress.yml` drives this same scenario
/// against strfry directly (`HAVEN_E2E_RELAY: ws://10.0.2.2:7777`, no proxy).
/// An unconditional announce there would put the REAL MLS group id on a relay
/// socket every night — a direct Security Rule 4 violation — because the frame
/// is written before the missing ack can be noticed 15 s later.
bool get wireRecorderDeclared =>
    wireJournalSentinelToken != kDefaultWireSentinelToken;

/// Frame verb the recording proxy intercepts as a snapshot marker. Must match
/// `SENTINEL_VERB` in `tooling/e2e/local-relay/src/frame.rs`.
const String _sentinelVerb = 'HAVEN_WIRE_SENTINEL';

/// Frame verb the proxy answers a marker with. Must match
/// `SENTINEL_ACK_VERB` in `tooling/e2e/local-relay/src/frame.rs`.
const String _sentinelAckVerb = 'HAVEN_WIRE_SENTINEL_ACK';

/// Frame verb the recording proxy intercepts as a real-MLS-group-id
/// announcement ([TestRelay.announceMlsGroupId]). Must match
/// `MLS_GROUP_ID_VERB` in `tooling/e2e/local-relay/src/frame.rs`.
const String _mlsGroupIdVerb = 'HAVEN_WIRE_MLS_GROUP_ID';

/// Frame verb the proxy answers an announcement with. Must match
/// `MLS_GROUP_ID_ACK_VERB` in `tooling/e2e/local-relay/src/frame.rs`.
const String _mlsGroupIdAckVerb = 'HAVEN_WIRE_MLS_GROUP_ID_ACK';

/// Shortest MLS group id [encodeWireMlsGroupId] accepts, in bytes.
///
/// The floor is EXACT, not generous: OpenMLS mints a 16-byte group id
/// (`openmls/src/group/mod.rs:73`, `rng.random_vec(16)`), so every real id sits
/// precisely on this value. Do NOT raise it "for safety" — that rejects every
/// id the app actually creates and hard-fails every lane. 16 bytes is 128 bits,
/// which is what the coincidence argument below needs. A short literal is the
/// dangerous failure mode, not a missing one — the host oracle greps the
/// journal for this string, and a handful of hex characters occurs inside
/// ordinary event ids by chance, so a truncated announcement would make the
/// oracle report a leak on frames that never carried the id.
const int kMinWireMlsGroupIdBytes = 16;

/// Longest id [encodeWireMlsGroupId] accepts, in bytes.
///
/// Mirrors `MLS_GROUP_ID_MAX_HEX = 128` in
/// `tooling/e2e/local-relay/src/frame.rs`. Without it the two sides disagree:
/// Dart would TRANSMIT an over-long id that the proxy silently refuses, and the
/// caller would learn about it 15 s later as "the proxy is not recording the
/// ids it is handed" — blaming the recorder for a caller bug. Unreachable at
/// the real 16 bytes; it exists so the two validators fail on the same inputs.
const int kMaxWireMlsGroupIdBytes = 64;

/// The one representation the drive, the proxy's sidecar and the host oracle
/// all agree on. Anchored, so a partial match cannot satisfy it.
final RegExp _lowercaseHexOnly = RegExp(r'^[0-9a-f]+$');

/// Encodes [mlsGroupId] as the lowercase hex the wire-correlation oracle
/// searches the journal for, rejecting anything that would make that search
/// meaningless.
///
/// The contract is: lowercase hex, even length, at least
/// [kMinWireMlsGroupIdBytes] * 2 characters. Validating it HERE — before the
/// frame is written — is what keeps a malformed id from becoming a host-side
/// search term that either can never match (wrong case) or matches by chance
/// (too short). Both of those read as a C5.8 result rather than as an error,
/// which is precisely the failure this channel exists to avoid.
///
/// Throws [ArgumentError] if [mlsGroupId] is shorter than
/// [kMinWireMlsGroupIdBytes] or holds a value outside a byte. The thrown
/// message names lengths and positions only, never the id or any part of it
/// (Security Rule 6).
String encodeWireMlsGroupId(List<int> mlsGroupId) {
  if (mlsGroupId.length > kMaxWireMlsGroupIdBytes) {
    throw ArgumentError(
      'MLS group id is ${mlsGroupId.length} byte(s); the recording proxy '
      'refuses anything over $kMaxWireMlsGroupIdBytes '
      '(MLS_GROUP_ID_MAX_HEX). Sending it would be refused silently and '
      'surface as an ack timeout that blames the proxy for a caller bug.',
    );
  }
  if (mlsGroupId.length < kMinWireMlsGroupIdBytes) {
    throw ArgumentError(
      'MLS group id is ${mlsGroupId.length} byte(s); the wire-correlation '
      'oracle needs at least $kMinWireMlsGroupIdBytes so the literal it '
      'searches for cannot collide with ordinary frame content. A short id '
      'here is usually the pre-accept gift-wrap stand-in rather than the real '
      'group id.',
    );
  }
  for (var i = 0; i < mlsGroupId.length; i++) {
    final b = mlsGroupId[i];
    if (b < 0 || b > 255) {
      throw ArgumentError(
        'MLS group id byte $i is outside 0..255, so it did not come from '
        'CircleFfi.mlsGroupId. Encoding it would produce a hex string of the '
        'wrong length and the oracle would search for a value no frame can '
        'contain.',
      );
    }
  }
  final hex =
      mlsGroupId.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  // A self-check on the encoder, not on the caller. The frame's whole purpose
  // is to hand the host a literal it can grep for, so an odd-length or
  // upper-case string would search for something the journal cannot contain
  // and report clean. The loop above cannot currently produce one; the check
  // costs nothing and pins the property for whoever changes the encoding.
  if (hex.length.isOdd || !_lowercaseHexOnly.hasMatch(hex)) {
    throw ArgumentError(
      'MLS group id did not encode to even-length lowercase hex '
      '(${hex.length} char(s)); the host oracle would search the journal for '
      'a literal it can never match.',
    );
  }
  return hex;
}

/// The recording proxy's answer to a sentinel marker.
///
/// [wireSeq] is the snapshot boundary the host oracle asserts up to;
/// [connId] identifies the emitting connection, which lets a caller EXCLUDE
/// its own probe traffic when attributing what the app sent.
class WireJournalSentinel {
  /// Constructs from a decoded `HAVEN_WIRE_SENTINEL_ACK` frame.
  const WireJournalSentinel({
    required this.token,
    required this.wireSeq,
    required this.connId,
  });

  /// The token echoed back, identical to the one emitted.
  final String token;

  /// Sequence number assigned to the sentinel line — the snapshot boundary.
  final int wireSeq;

  /// The proxy's id for the connection that emitted the marker.
  final String connId;
}

/// A single Nostr event as observed off the relay.
///
/// Holds the raw JSON object; scenarios that need to inspect tags decode
/// inline. Avoiding a full type model keeps `TestRelay` lightweight and
/// avoids drifting away from the wire format.
class TestRelayEvent {
  /// Constructs from a decoded relay payload.
  const TestRelayEvent(this.raw);

  /// The decoded event JSON (`{"id":..., "pubkey":..., "kind":..., ...}`).
  final Map<String, dynamic> raw;

  /// Convenience: event kind.
  int get kind => raw['kind'] as int;

  /// Convenience: event id as hex.
  String get id => raw['id'] as String;

  /// Convenience: author pubkey as hex.
  String get pubkey => raw['pubkey'] as String;

  /// Convenience: `created_at` Unix seconds.
  int get createdAt => raw['created_at'] as int;

  /// Convenience: the `tags` array as a list of string lists.
  List<List<String>> get tags {
    final dynamic raw = this.raw['tags'];
    if (raw is! List) return const [];
    return raw
        .whereType<List<dynamic>>()
        .map((tag) => tag.whereType<String>().toList(growable: false))
        .toList(growable: false);
  }

  /// Returns the first tag whose key equals [tagName], if any.
  List<String>? tag(String tagName) {
    for (final t in tags) {
      if (t.isNotEmpty && t.first == tagName) return t;
    }
    return null;
  }
}

/// Observes a hermetic Nostr relay (strfry) for E2E test assertions and
/// cross-process barriers.
///
/// A single `TestRelay` opens one WebSocket and multiplexes one subscription
/// per `firstWhere` / `events` call. Closing via [dispose] cancels all in-
/// flight subscriptions and the underlying socket.
class TestRelay {
  TestRelay._(this.url, this._channel);

  /// Opens a connection to [url] (default: [defaultStrfryUrl]).
  static Future<TestRelay> connect({String? url}) async {
    final target = Uri.parse(url ?? defaultStrfryUrl);
    final channel = WebSocketChannel.connect(target);
    await channel.ready;
    return TestRelay._(target.toString(), channel).._listen();
  }

  /// The relay URL this client is connected to.
  final String url;

  /// Mutable so the reconnect path can swap in a fresh socket on
  /// transient strfry disconnects (see `_attemptReconnect`).
  WebSocketChannel _channel;
  final Map<String, _Subscription> _subs = <String, _Subscription>{};
  final List<_PendingOk> _pendingOks = <_PendingOk>[];
  final List<_PendingSentinel> _pendingSentinels = <_PendingSentinel>[];
  final List<_PendingMlsGroupId> _pendingMlsGroupIds = <_PendingMlsGroupId>[];
  final Random _rng = Random.secure();

  /// `true` once [dispose] has been called or the bounded reconnect
  /// budget has been exhausted. No further operations are permitted.
  bool _closed = false;

  /// `true` between a transport-level disconnect and either a
  /// successful reconnect or the final exhaustion. While set,
  /// [_sendReq] / [_sendClose] are silently dropped — the subscription
  /// stays registered in [_subs] and will be re-issued when the new
  /// channel comes up.
  bool _writable = true;

  /// Monotonically advancing reconnect attempt counter. Reset to 0
  /// on every successful reconnect.
  int _reconnectAttempt = 0;
  Timer? _reconnectTimer;

  /// Strfry on GitHub-hosted runners occasionally drops WebSocket
  /// connections under load ("1006/Resource temporarily unavailable"
  /// in strfry's log) — typically once or twice per scenario on warm
  /// runs, more on cold ones. Three reconnect attempts at 1 s / 2 s /
  /// 4 s backoff has covered every observed disconnect pattern in
  /// the artifact archive. Going higher would mostly extend test
  /// failure latency on truly broken environments.
  static const int _maxReconnectAttempts = 3;

  void _listen() {
    _channel.stream.listen(
      _onMessage,
      onDone: _onTransportDone,
      onError: (Object _) => _onTransportDone(),
      cancelOnError: false,
    );
  }

  void _onMessage(dynamic data) {
    if (data is! String) return;
    final List<dynamic> frame;
    try {
      final dynamic decoded = jsonDecode(data);
      if (decoded is! List) return;
      frame = decoded;
    } on FormatException {
      return;
    }
    if (frame.isEmpty) return;
    final tag = frame.first;
    if (tag == _sentinelAckVerb && frame.length >= 4) {
      // Synthesized by the recording proxy, never by a relay. Matched on the
      // echoed token so two overlapping sentinels cannot resolve each other's
      // future with the wrong boundary.
      final token = frame[1];
      final seq = frame[2];
      final connId = frame[3];
      if (token is! String || seq is! int || connId is! String) return;
      for (final pending in List<_PendingSentinel>.from(_pendingSentinels)) {
        if (pending.token == token) {
          _pendingSentinels.remove(pending);
          if (!pending.completer.isCompleted) {
            pending.completer.complete(
              WireJournalSentinel(
                token: token,
                wireSeq: seq,
                connId: connId,
              ),
            );
          }
          break;
        }
      }
      return;
    }
    if (tag == _mlsGroupIdAckVerb && frame.length >= 2) {
      // Synthesized by the recording proxy, never by a relay. Matched on the
      // echoed id so two announcements in flight cannot resolve each other's
      // future — the ids differ, and an ack for a circle the drive did not
      // announce is ignored rather than credited to another one.
      final hex = frame[1];
      if (hex is! String) return;
      for (final pending in List<_PendingMlsGroupId>.from(
        _pendingMlsGroupIds,
      )) {
        if (pending.hex == hex) {
          _pendingMlsGroupIds.remove(pending);
          if (!pending.completer.isCompleted) pending.completer.complete();
          break;
        }
      }
      return;
    }
    if (tag == 'EVENT' && frame.length >= 3) {
      final subId = frame[1] as String?;
      final eventJson = frame[2];
      if (subId == null || eventJson is! Map<String, dynamic>) return;
      final sub = _subs[subId];
      if (sub != null) sub.onEvent(TestRelayEvent(eventJson));
    } else if (tag == 'EOSE' && frame.length >= 2) {
      final subId = frame[1] as String?;
      if (subId == null) return;
      _subs[subId]?.onEose();
    } else if (tag == 'OK' && frame.length >= 4) {
      final eventId = frame[1];
      final accepted = frame[2];
      final message = frame[3];
      if (eventId is! String || accepted is! bool || message is! String) {
        return;
      }
      for (final pending in List<_PendingOk>.from(_pendingOks)) {
        if (pending.eventId == eventId) {
          _pendingOks.remove(pending);
          if (!pending.completer.isCompleted) {
            pending.completer.complete((accepted, message));
          }
          break;
        }
      }
    }
  }

  /// Handles a transport-level socket close. Two paths:
  ///
  ///   * **Reconnect-eligible (default)** — the socket dropped
  ///     unexpectedly (strfry hiccup, network blip). Keep [_subs]
  ///     intact so they can be re-issued, fail any in-flight publish
  ///     OK waits (re-publishing isn't safely idempotent), and
  ///     schedule a reconnect attempt with exponential backoff.
  ///   * **Permanent close** — [dispose] already ran or the bounded
  ///     reconnect budget was exhausted. Tears down everything with
  ///     a clear error message naming the reason.
  void _onTransportDone() {
    if (_closed) return;
    _writable = false;

    // Pending OK awaits cannot be safely retried (a re-publish of
    // the same signed event would either dedupe at the relay or
    // produce a confusing second OK), so they fail immediately.
    // The snapshot+clear pattern guards against re-entrancy if any
    // error handler mutates _pendingOks while we iterate.
    final pendingOks = _pendingOks.toList(growable: false);
    _pendingOks.clear();
    for (final pending in pendingOks) {
      if (!pending.completer.isCompleted) {
        pending.completer.completeError(
          StateError('relay connection closed before OK arrived'),
        );
      }
    }

    // A sentinel ack can never arrive on a socket that is gone, and the marker
    // is bound to the connection the proxy recorded it on — so surface the
    // loss now rather than letting the caller sit out its full timeout and
    // then blame the recorder for a frame whose answer was dropped in transit.
    final pendingSentinels = _pendingSentinels.toList(growable: false);
    _pendingSentinels.clear();
    for (final pending in pendingSentinels) {
      if (!pending.completer.isCompleted) {
        pending.completer.completeError(
          StateError(
            'relay connection closed before the wire-journal sentinel was '
            'acked',
          ),
        );
      }
    }

    // Same reasoning for a group-id announcement, with a sharper consequence:
    // an announcement whose ack was lost in transit leaves the host oracle
    // searching for FEWER ids than the wire could carry, which still reports
    // clean. Surface the loss at the disconnect instead of letting the caller
    // sit out its timeout and blame the proxy.
    final pendingIds = _pendingMlsGroupIds.toList(growable: false);
    _pendingMlsGroupIds.clear();
    for (final pending in pendingIds) {
      if (!pending.completer.isCompleted) {
        pending.completer.completeError(
          StateError(
            'relay connection closed before the MLS group id announcement '
            'was acked',
          ),
        );
      }
    }

    _scheduleReconnect();
  }

  /// Fails every in-flight subscription with [message] and marks the
  /// relay permanently closed. Used when the reconnect budget runs
  /// out — the snapshot+clear pattern matches `_onTransportDone`'s
  /// reasoning: each subscription's onError handler re-enters
  /// `_subs.remove(subId)` via `cleanup()`, so iterating the live
  /// map would throw ConcurrentModificationError.
  void _failAllSubscriptions(String message) {
    _closed = true;
    _reconnectTimer?.cancel();
    final subs = _subs.values.toList(growable: false);
    _subs.clear();
    for (final s in subs) {
      s.completeWithError(StateError(message));
    }
  }

  void _scheduleReconnect() {
    if (_closed) return;
    _reconnectAttempt += 1;
    if (_reconnectAttempt > _maxReconnectAttempts) {
      _failAllSubscriptions(
        'relay connection closed; reconnect exhausted after '
        '$_maxReconnectAttempts attempts',
      );
      return;
    }
    // 1s, 2s, 4s backoff — fast enough that callers' outer timeouts
    // (typically 30–90 s in scenarios) absorb the reconnect window,
    // slow enough that a flapping relay isn't hammered.
    final delaySeconds = 1 << (_reconnectAttempt - 1);
    _reconnectTimer = Timer(
      Duration(seconds: delaySeconds),
      _attemptReconnect,
    );
  }

  Future<void> _attemptReconnect() async {
    if (_closed) return;
    try {
      final channel = WebSocketChannel.connect(Uri.parse(url));
      await channel.ready.timeout(const Duration(seconds: 5));
      _channel = channel;
      _writable = true;
      _reconnectAttempt = 0;
      _listen();
      // Re-issue REQ for each surviving subscription so events
      // continue flowing through the same completers/listeners that
      // were registered before the disconnect. Strfry's `since=`
      // semantics + each subscription's own dedupe (e.g. collectN's
      // seenIds set) make this idempotent: events that arrived
      // during the disconnect window are replayed and either match
      // the still-pending filter (good) or are de-duped (also good).
      for (final entry in _subs.entries) {
        _channel.sink.add(
          jsonEncode(<dynamic>['REQ', entry.key, entry.value.filter]),
        );
      }
    } on Object {
      // Reconnect failed; queue another attempt (or exhaust).
      _writable = false;
      _scheduleReconnect();
    }
  }

  String _randomSubId() {
    final bytes = List<int>.generate(
      8,
      (_) => _rng.nextInt(256),
      growable: false,
    );
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  void _sendReq(String subId, Map<String, dynamic> filter) {
    if (_closed) {
      throw StateError('TestRelay is closed');
    }
    // During the reconnect window the old sink is closed and the new
    // one isn't ready yet. Drop the write silently: the subscription
    // is already registered in [_subs] and `_attemptReconnect` will
    // re-issue every active REQ once the new channel is up.
    if (!_writable) return;
    _channel.sink.add(jsonEncode(<dynamic>['REQ', subId, filter]));
  }

  void _sendClose(String subId) {
    if (_closed) return;
    // Same reconnect-window guard as `_sendReq` — the local cleanup
    // (`_subs.remove(subId)`) is what actually frees the slot; the
    // CLOSE frame is a courtesy notification to strfry.
    if (!_writable) return;
    _channel.sink.add(jsonEncode(<dynamic>['CLOSE', subId]));
  }

  /// Emits the wire-journal SENTINEL frame and returns the token it carried.
  ///
  /// The host-side structural oracle
  /// (`tooling/e2e/ci/check-wire-journal.sh`, backlog item C2) asserts only
  /// over journal lines whose `wire_seq` is at or below this frame's. Without
  /// that boundary the oracle races the background wakes (WorkManager /
  /// BGTask) that keep appending to the journal while it reads, and its
  /// sample would be irreproducible.
  ///
  /// The frame is `["HAVEN_WIRE_SENTINEL","<token>"]`. The recording proxy
  /// INTERCEPTS it: the marker is journalled as an ordinary `dir:"c2r"` frame
  /// and is never forwarded upstream, so no relay ever sees it and nothing
  /// about the scenario is perturbed. The proxy answers with
  /// `["HAVEN_WIRE_SENTINEL_ACK","<token>",<wire_seq>,"<conn_id>"]`, which
  /// this method returns as [WireJournalSentinel] — the ack is synthesized by
  /// the proxy and deliberately NOT journalled, since recording it as
  /// `dir:"r2c"` would claim the relay sent it.
  ///
  /// Waiting for the ack is the point. A fire-and-forget marker that never
  /// reached the recorder surfaces on the host as "no sentinel in the
  /// journal" — a true failure, but one that blames the recorder for a frame
  /// the drive never got out. Failing here instead keeps the attribution
  /// where the fault is.
  ///
  /// Call this LAST, after the traffic that should be inside the snapshot.
  /// Calling it more than once is fine: the oracle anchors on the highest
  /// matching `wire_seq`, so the snapshot extends to the last marker emitted.
  ///
  /// Throws [StateError] if the marker could not be written, or if no ack
  /// arrives within [timeout] — which is also what happens when the lane
  /// pointed the app straight at a relay instead of through the proxy.
  Future<WireJournalSentinel> emitWireJournalSentinel({
    String token = wireJournalSentinelToken,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    if (_closed) {
      throw StateError(
        'TestRelay is closed; the wire-journal sentinel was never emitted.',
      );
    }
    // Wait out a reconnect window rather than letting the write drop on the
    // floor: this frame has no subscription behind it, so nothing would ever
    // re-issue it.
    final deadline = DateTime.now().add(timeout);
    while (!_writable && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (_closed || !_writable) {
      throw StateError(
        'TestRelay was not writable within ${timeout.inSeconds}s; the '
        'wire-journal sentinel was never emitted, so the host oracle cannot '
        'anchor its snapshot.',
      );
    }
    final completer = Completer<WireJournalSentinel>();
    _pendingSentinels.add(_PendingSentinel(token, completer));
    _channel.sink.add(jsonEncode(<dynamic>[_sentinelVerb, token]));
    try {
      return await completer.future.timeout(timeout);
    } on TimeoutException {
      throw StateError(
        'no wire-journal sentinel ack within ${timeout.inSeconds}s. Either '
        'this connection does not run through the recording proxy, or the '
        'proxy is not recording.',
      );
    } finally {
      _pendingSentinels.removeWhere((p) => p.token == token);
    }
  }

  /// Announces one circle's REAL MLS group id to the recording proxy.
  ///
  /// The wire-correlation oracle's C5.8 asserts Security Rule 4: the real MLS
  /// group id never appears on the wire. To assert that a value is ABSENT the
  /// oracle has to know it, and it cannot learn it from the journal — its
  /// absence there *is* the assertion. So the drive has to hand it over out of
  /// band, and this is that channel.
  ///
  /// It is deliberately NOT the drive log. That log is uploaded as a CI
  /// artifact with weeks of retention and doubles as the canary oracle's
  /// `--manifest` input; `wire_canaries.dart` ("Where the manifest may be
  /// written, and what may go in it") records the decision that a Rule-4 value
  /// must never go there. The frame is
  /// `["HAVEN_WIRE_MLS_GROUP_ID","<lowercase-hex>"]`; the proxy INTERCEPTS it,
  /// never forwards it upstream and never journals it, and writes it to a
  /// host-side sidecar the lane does not upload. It answers with
  /// `["HAVEN_WIRE_MLS_GROUP_ID_ACK","<hex>"]`, which is what this method
  /// waits for.
  ///
  /// Waiting for the ack is the point, and for a sharper reason than
  /// [emitWireJournalSentinel]'s. A marker that never arrives makes the host
  /// fail closed; an ANNOUNCEMENT that never arrives makes it scan for fewer
  /// ids than the wire could carry — a weaker check that still reports clean.
  /// Failing here converts that silent weakening into a loud failure with the
  /// blame in the right place.
  ///
  /// Call once per circle the scenario creates, as soon as the id exists.
  /// Order does not matter: the sidecar is read on the host after the run, so
  /// an id announced late still covers frames recorded early. Announcing the
  /// same id twice is harmless — the host searches for a set.
  ///
  /// [mlsGroupId] is `CircleFfi.mlsGroupId`; [encodeWireMlsGroupId] validates
  /// it. Nothing derived from it is returned, so no caller can accidentally
  /// route it into a log or a manifest (Security Rules 4 and 6).
  ///
  /// Throws [ArgumentError] if the id fails the contract, and [StateError] if
  /// the frame could not be written or no ack arrives within [timeout] —
  /// which is also what happens when the lane pointed the app straight at a
  /// relay instead of through the proxy.
  Future<void> announceMlsGroupId({
    required List<int> mlsGroupId,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    // FIRST STATEMENT, before validation and before the writability poll.
    // `wireRecorderDeclared` is a compile-time constant, so there is nothing to
    // wait for — and the ack timeout further down cannot stand in for this
    // check, because it fires 15 s AFTER the frame is written. On an unproxied
    // lane the id would already be on the relay by then. Security Rule 4: the
    // real MLS group id must never reach a relay.
    if (!wireRecorderDeclared) {
      throw StateError(
        'refusing to announce an MLS group id: this build declares no '
        'recording proxy (HAVEN_WIRE_SENTINEL is the compiled default), so '
        'the frame would go to the relay itself. Callers must gate on '
        'wireRecorderDeclared.',
      );
    }
    // Validate second, so a malformed id fails identically whatever state the
    // socket is in: that is the caller's bug, not the transport's.
    final hex = encodeWireMlsGroupId(mlsGroupId);
    if (_closed) {
      throw StateError(
        'TestRelay is closed; the MLS group id was never announced, so the '
        'wire-correlation oracle will not know to look for it.',
      );
    }
    // Wait out a reconnect window rather than letting the write drop on the
    // floor: like the sentinel, this frame has no subscription behind it, so
    // nothing would ever re-issue it.
    final deadline = DateTime.now().add(timeout);
    while (!_writable && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (_closed || !_writable) {
      throw StateError(
        'TestRelay was not writable within ${timeout.inSeconds}s; the MLS '
        'group id was never announced, so the wire-correlation oracle would '
        'scan for fewer ids than the wire could carry and still report clean.',
      );
    }
    final pending = _PendingMlsGroupId(hex, Completer<void>());
    _pendingMlsGroupIds.add(pending);
    _channel.sink.add(jsonEncode(<dynamic>[_mlsGroupIdVerb, hex]));
    try {
      await pending.completer.future.timeout(timeout);
    } on TimeoutException {
      throw StateError(
        'no MLS-group-id ack within ${timeout.inSeconds}s. Either this '
        'connection does not run through the recording proxy, or the proxy '
        'is not recording the ids it is handed.',
      );
    } finally {
      // By identity, not by value: a re-announcement of the SAME circle must
      // not have its still-pending twin cancelled out from under it.
      _pendingMlsGroupIds.remove(pending);
    }
  }

  /// Publishes a pre-signed Nostr event JSON to the relay.
  ///
  /// Used by `SyntheticUser` to put a relay-only identity's events (e.g.
  /// KeyPackage kind 30443) on the wire so the system-under-test can fetch
  /// them through its normal relay-query path.
  ///
  /// [eventJson] must be a complete, signed Nostr event payload (the inner
  /// object — not wrapped in a `["EVENT", ...]` frame; this method adds
  /// the protocol envelope). Use [publishAndAwaitOk] when the caller
  /// needs the relay's `OK` acknowledgement; this fire-and-forget variant
  /// returns once the frame is queued on the WebSocket.
  void publish(String eventJson) {
    if (_closed) {
      throw StateError('TestRelay is closed');
    }
    if (!_writable) {
      throw StateError(
        'TestRelay is reconnecting; publish cannot be safely retried '
        'transparently (would risk duplicate event delivery). Caller '
        'should retry after the reconnect window.',
      );
    }
    // Validate the JSON is a Map (defensive — strfry would reject a
    // malformed event but the test failure would be confusing).
    final decoded = jsonDecode(eventJson);
    if (decoded is! Map<String, dynamic>) {
      throw ArgumentError.value(
        eventJson,
        'eventJson',
        'must decode to a JSON object',
      );
    }
    _channel.sink.add(jsonEncode(<dynamic>['EVENT', decoded]));
  }

  /// Publishes an event and waits for the relay's OK frame for it.
  ///
  /// Returns `(accepted, message)` where `accepted` is the boolean from
  /// the `OK` frame and `message` is the relay's free-form note.
  ///
  /// Throws on timeout or if the relay returns NOTICE/CLOSED before the
  /// OK for this event id.
  Future<(bool accepted, String message)> publishAndAwaitOk(
    String eventJson, {
    Duration timeout = const Duration(seconds: 5),
  }) {
    if (_closed) {
      throw StateError('TestRelay is closed');
    }
    if (!_writable) {
      throw StateError(
        'TestRelay is reconnecting; publishAndAwaitOk cannot be safely '
        'retried transparently. Caller should retry after the reconnect '
        'window.',
      );
    }
    final decoded = jsonDecode(eventJson);
    if (decoded is! Map<String, dynamic>) {
      throw ArgumentError.value(
        eventJson,
        'eventJson',
        'must decode to a JSON object',
      );
    }
    final eventId = decoded['id'];
    if (eventId is! String) {
      throw ArgumentError.value(
        eventJson,
        'eventJson',
        'event JSON must include an "id" string',
      );
    }
    final completer = Completer<(bool, String)>();
    final pending = _PendingOk(eventId: eventId, completer: completer);
    _pendingOks.add(pending);
    final timer = Timer(timeout, () {
      if (completer.isCompleted) return;
      _pendingOks.remove(pending);
      completer.completeError(
        TimeoutException(
          'TestRelay.publishAndAwaitOk timed out after '
          '${timeout.inSeconds}s for event $eventId',
        ),
      );
    });
    completer.future.whenComplete(timer.cancel);
    _channel.sink.add(jsonEncode(<dynamic>['EVENT', decoded]));
    return completer.future;
  }

  /// Subscribes to events matching [filter] and emits each as it arrives.
  ///
  /// The returned stream completes (without error) when [dispose] is
  /// called. Callers MUST listen with `await for` or `.listen` so the
  /// underlying subscription is closed cleanly.
  Stream<TestRelayEvent> events(Map<String, dynamic> filter) {
    final subId = _randomSubId();
    final controller = StreamController<TestRelayEvent>();
    final sub = _Subscription(
      filter: filter,
      onEvent: controller.add,
      onEose: () {},
      onError: controller.addError,
    );
    _subs[subId] = sub;
    controller.onCancel = () {
      _sendClose(subId);
      _subs.remove(subId);
    };
    _sendReq(subId, filter);
    return controller.stream;
  }

  /// Waits until an event matching [filter] (and optionally [matcher]) is
  /// observed on the relay, or fails after [timeout].
  ///
  /// `firstWhere` is the canonical cross-process synchronization primitive
  /// in E2E scenarios — Bob's role waits for Alice's gift-wrap before
  /// tapping Accept, etc.
  Future<TestRelayEvent> firstWhere({
    required Map<String, dynamic> filter,
    bool Function(TestRelayEvent event)? matcher,
    Duration timeout = const Duration(seconds: 30),
  }) {
    final completer = Completer<TestRelayEvent>();
    final subId = _randomSubId();
    Timer? timer;

    void cleanup() {
      timer?.cancel();
      _sendClose(subId);
      _subs.remove(subId);
    }

    final sub = _Subscription(
      filter: filter,
      onEvent: (event) {
        if (completer.isCompleted) return;
        if (matcher != null && !matcher(event)) return;
        completer.complete(event);
        cleanup();
      },
      onEose: () {},
      onError: (Object err) {
        if (completer.isCompleted) return;
        completer.completeError(err);
        cleanup();
      },
    );
    _subs[subId] = sub;

    timer = Timer(timeout, () {
      if (completer.isCompleted) return;
      cleanup();
      // Enrich the failure with a test-runner-only snapshot of what the
      // relay ACTUALLY holds for this filter's scope before surfacing the
      // timeout. The probe is bounded (2s) and best-effort; the wait has
      // already failed, so the added latency only affects the error path.
      unawaited(
        _timeoutDiagnostic(filter).then((diagnostic) {
          if (completer.isCompleted) return;
          completer.completeError(
            TimeoutException(
              'TestRelay.firstWhere timed out after ${timeout.inSeconds}s '
              'with filter $filter.$diagnostic',
            ),
          );
        }),
      );
    });

    _sendReq(subId, filter);
    return completer.future;
  }

  /// Builds a test-runner-only diagnostic suffix for a [firstWhere]
  /// timeout: a short snapshot of what the relay ACTUALLY holds for the
  /// same author/tag scope with the kind constraint dropped.
  ///
  /// A wrong-kind wait (e.g. a filter still naming a retired wire kind
  /// after a protocol migration) then reports "the relay holds kinds
  /// {30443}" instead of an unexplained timeout, while an
  /// empty snapshot points at the publisher never reaching the relay.
  /// Best-effort: never throws, returns an empty string when there is no
  /// author/tag scope to probe or the probe itself fails.
  Future<String> _timeoutDiagnostic(Map<String, dynamic> filter) async {
    try {
      final probe = <String, dynamic>{'limit': 25};
      for (final key in const <String>['authors', '#p', '#h', '#e']) {
        final dynamic value = filter[key];
        if (value != null) probe[key] = value;
      }
      if (probe.length == 1) {
        // Kind-only filter — a whole-relay snapshot would be noise.
        return '';
      }
      final held = await collectN(
        count: 25,
        filter: probe,
        timeout: const Duration(seconds: 2),
      );
      if (held.isEmpty) {
        return " Diagnostic: the relay holds NO events for this filter's "
            'author/tag scope (kind constraint dropped) — the expected '
            'publisher likely never reached the relay.';
      }
      final kinds = held.map((e) => e.kind).toSet().toList()..sort();
      return ' Diagnostic: for the same author/tag scope the relay holds '
          '${held.length} event(s) of kind(s) $kinds (kind constraint '
          'dropped) — a mismatch against the waited-for kind usually means '
          'the wait filters a stale/retired wire kind.';
    } on Object {
      return '';
    }
  }

  /// Collects up to [count] distinct events matching [filter], or returns
  /// the partial subset collected so far if [timeout] elapses first.
  ///
  /// This is the multi-event sibling of [firstWhere] and is the canonical
  /// gate for scenarios that need to wait for a known number of discrete
  /// relay events before driving downstream UI assertions — e.g.
  /// scenario_05 waiting for `LeavePlan::AdminHandoff`'s three-commit
  /// sequence (AdminHandoff → SelfDemote → SelfRemove) to land before
  /// asking Bob's MDK to apply them. Compared to a fixed retry loop, this
  /// pattern ties the wait to a *concrete observable on the wire* rather
  /// than guessing at timing.
  ///
  /// On timeout, the call resolves to whatever events have been seen so
  /// far (deduplicated by event id) rather than throwing. The caller's
  /// assertion is then free to surface the partial count meaningfully —
  /// "expected 3, saw 2" is more actionable than "TimeoutException".
  Future<List<TestRelayEvent>> collectN({
    required int count,
    required Map<String, dynamic> filter,
    Duration timeout = const Duration(minutes: 2),
  }) {
    if (_closed) {
      throw StateError('TestRelay is closed');
    }
    if (count <= 0) {
      throw ArgumentError.value(count, 'count', 'must be positive');
    }
    final completer = Completer<List<TestRelayEvent>>();
    final collected = <TestRelayEvent>[];
    final seenIds = <String>{};
    final subId = _randomSubId();
    Timer? timer;

    void cleanup() {
      timer?.cancel();
      _sendClose(subId);
      _subs.remove(subId);
    }

    final sub = _Subscription(
      filter: filter,
      onEvent: (event) {
        if (completer.isCompleted) return;
        if (!seenIds.add(event.id)) return;
        collected.add(event);
        if (collected.length >= count) {
          completer.complete(List<TestRelayEvent>.unmodifiable(collected));
          cleanup();
        }
      },
      onEose: () {},
      onError: (Object err) {
        if (completer.isCompleted) return;
        completer.completeError(err);
        cleanup();
      },
    );
    _subs[subId] = sub;

    timer = Timer(timeout, () {
      if (completer.isCompleted) return;
      completer.complete(List<TestRelayEvent>.unmodifiable(collected));
      cleanup();
    });

    _sendReq(subId, filter);
    return completer.future;
  }

  /// Closes all subscriptions and the underlying socket. Idempotent.
  Future<void> dispose() async {
    if (_closed) return;
    _closed = true;
    _reconnectTimer?.cancel();
    if (_writable) {
      for (final subId in _subs.keys.toList(growable: false)) {
        _sendClose(subId);
      }
    }
    _subs.clear();
    await _channel.sink.close();
  }
}

class _Subscription {
  _Subscription({
    required this.filter,
    required this.onEvent,
    required this.onEose,
    required this.onError,
  });

  /// The filter this subscription was originally issued with. Held so
  /// that `TestRelay._attemptReconnect` can re-issue the REQ verbatim
  /// against a fresh socket after a transient strfry disconnect.
  final Map<String, dynamic> filter;
  final void Function(TestRelayEvent) onEvent;
  final void Function() onEose;
  final void Function(Object) onError;

  void completeWithError(Object error) => onError(error);
}

class _PendingOk {
  _PendingOk({required this.eventId, required this.completer});

  final String eventId;
  final Completer<(bool, String)> completer;
}

class _PendingSentinel {
  _PendingSentinel(this.token, this.completer);

  final String token;
  final Completer<WireJournalSentinel> completer;
}

/// One in-flight [TestRelay.announceMlsGroupId] awaiting its proxy ack.
///
/// [hex] is held only to match the echoed ack; it is never logged and never
/// leaves this file (Security Rules 4 and 6).
class _PendingMlsGroupId {
  _PendingMlsGroupId(this.hex, this.completer);

  final String hex;
  final Completer<void> completer;
}
