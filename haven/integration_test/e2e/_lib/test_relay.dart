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
/// 10051, 10050, 445) actually land on R2. Using a physically separate relay
/// process makes the proof definitive: if the production add-relay path
/// silently failed, events would arrive on R1 only and every `firstWhere` on
/// `r2` would time out, turning the test red. CI spins up a second strfry
/// container bound to the port below (7778) alongside the first (7777).
const String secondStrfryUrl = String.fromEnvironment(
  'HAVEN_E2E_RELAY_2',
  defaultValue: 'ws://localhost:7778',
);

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

  /// Publishes a pre-signed Nostr event JSON to the relay.
  ///
  /// Used by `SyntheticUser` to put a relay-only identity's events (e.g.
  /// KeyPackage kind 443) on the wire so the system-under-test can fetch
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
      completer.completeError(
        TimeoutException(
          'TestRelay.firstWhere timed out after ${timeout.inSeconds}s '
          'with filter $filter',
        ),
      );
      cleanup();
    });

    _sendReq(subId, filter);
    return completer.future;
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
