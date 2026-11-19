/// One kind-0 per profile edit, accounted without rendering an event id.
///
/// A failing `expect` prints its operands into the drive log, so the ids are
/// compared here and only booleans, buckets and relay handles reach a matcher
/// or a reason (Security Rule 15).
///
/// A relay owes a subscriber only the newest replaceable event (NIP-01), and
/// strfry's live monitor reads its store after each write batch
/// (`src/apps/relay/RelayReqMonitor.cpp`, the `DBChange` branch): an event
/// superseded before that read reaches no live subscriber. What a relay
/// delivers live therefore cannot be counted per edit on the Android lane; it
/// is held to the edits' own events instead, and each edit's event is proved
/// on every relay by the scenario's stored-event waits (`recordEdit`).
library;

import 'dart:async' show StreamController, StreamSubscription, TimeoutException;

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/utils/log_alias.dart'
    show LogAliasClass, logAliasHandle, magnitudeBucket;

import 'test_relay.dart' show TestRelay, TestRelayEvent;

/// Watches one author's kind-0 on every pool relay and accounts it per edit.
class Kind0Ledger {
  /// Subscribes to [authorHex]'s kind-0 on every pool relay; call it
  /// before anything can publish, and cancel it when done.
  Kind0Ledger(this._pool, String authorHex) {
    for (var i = 0; i < _pool.length; i++) {
      _delivered.add(<String>{});
      _watches.add(
        _pool[i]
            .events(<String, dynamic>{
              'kinds': const <int>[0],
              'authors': <String>[authorHex],
            })
            .listen((event) {
              _delivered[i].add(event.id);
              _arrivals.add(null);
            }),
      );
    }
  }

  final List<TestRelay> _pool;
  final List<Set<String>> _delivered = <Set<String>>[];
  final List<StreamSubscription<TestRelayEvent>> _watches =
      <StreamSubscription<TestRelayEvent>>[];
  final StreamController<void> _arrivals = StreamController<void>.broadcast();
  final Set<String> _edits = <String>{};
  String? _newest;

  /// Whether pool relay [i] has delivered any kind-0 of the author yet.
  bool deliveredAny(int i) => _delivered[i].isNotEmpty;

  /// Records the event every pool relay serves for one edit: the same signed
  /// event on all of them, and not one an earlier edit published.
  void recordEdit(List<TestRelayEvent> servedByEachRelay, String step) {
    final distinct = servedByEachRelay.map((e) => e.id).toSet();
    expect(
      distinct.length == 1,
      isTrue,
      reason:
          '$step: every pool relay must serve the same signed kind-0, but '
          'they serve ${magnitudeBucket(distinct.length)} distinct ones.',
    );
    expect(
      _edits.add(distinct.single),
      isTrue,
      reason:
          '$step: the edit must publish a kind-0 of its own, not one an '
          'earlier edit published.',
    );
    _newest = distinct.single;
  }

  /// Every kind-0 any pool relay delivered is one of [edits] recorded edits'
  /// events: more means a pass signed again for an edit already published.
  ///
  /// First waits, up to [timeout], for each relay to deliver the newest
  /// edit's event live — nothing supersedes it, so every relay delivers it —
  /// which proves the watch is live and has caught up with every earlier
  /// event.
  Future<void> expectOnePerEdit({
    required int edits,
    required Duration timeout,
  }) async {
    expect(
      _edits.length == edits,
      isTrue,
      reason:
          'one kind-0 per edit: ${magnitudeBucket(_edits.length)} recorded '
          'for ${magnitudeBucket(edits)} edits.',
    );
    final newest = _newest;
    if (newest == null) fail('no edit was recorded');
    for (var i = 0; i < _pool.length; i++) {
      if (_delivered[i].contains(newest)) continue;
      try {
        await _arrivals.stream
            .firstWhere((_) => _delivered[i].contains(newest))
            .timeout(timeout);
      } on TimeoutException {
        fail(
          '${logAliasHandle(LogAliasClass.relay, _pool[i].url)} did not '
          'deliver the newest edit live within ${timeout.inSeconds}s, so its '
          'watch cannot account for the edits.',
        );
      }
    }
    for (var i = 0; i < _pool.length; i++) {
      final strays = _delivered[i].difference(_edits);
      expect(
        strays.isEmpty,
        isTrue,
        reason:
            '${logAliasHandle(LogAliasClass.relay, _pool[i].url)} delivered '
            '${magnitudeBucket(strays.length)} kind-0(s) no edit published: '
            'a pass signed again for an edit it had already published.',
      );
    }
  }

  /// Closes every watch.
  Future<void> cancel() async {
    for (final watch in _watches) {
      await watch.cancel();
    }
    await _arrivals.close();
  }
}
