/// Host-side proof of the bounded poll behind the iOS background lane's P2d
/// oracle ([pollForStoredPeerFix]).
///
/// The lane runs on a backgrounded iOS Simulator only, so the poll's exit rule
/// would otherwise execute nowhere else. The rule that matters is the one CI
/// run 41576538923 broke: the row landing is not enough while the caller's
/// `settled` does not hold yet.
///
/// These run under plain `flutter test` (no Rust bridge, no device), on
/// `fake_async`'s clock, so every instant below is exact.
library;

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/services/circle_service.dart' show DecryptedLocation;

import '../../integration_test/e2e/_lib/stored_fix_poll.dart';

final String _peer = 'ab12cd34' * 8;

DecryptedLocation _row(String sender) => DecryptedLocation(
  senderPubkey: sender,
  latitude: 1.5,
  longitude: 2.5,
  geohash: 's00twy01m',
  timestamp: DateTime.utc(2026, 11, 3),
  expiresAt: DateTime.utc(2026, 11, 4),
);

/// Runs one poll to completion on a fake clock and reports when it returned.
({StoredFixObservation observation, Duration returnedAt}) _run({
  required Future<List<DecryptedLocation>> Function(Duration now) read,
  required Duration budget,
  bool Function(Duration now)? settled,
}) {
  late StoredFixObservation observation;
  late Duration returnedAt;
  fakeAsync((async) {
    var done = false;
    unawaited(
      pollForStoredPeerFix(
        read: () => read(async.elapsed),
        // Upper case: the poll matches the sender case-insensitively.
        senderPubkeyHex: _peer.toUpperCase(),
        budget: budget,
        settled: settled == null ? () => true : () => settled(async.elapsed),
      ).then((o) {
        observation = o;
        returnedAt = async.elapsed;
        done = true;
      }),
    );
    async.elapse(budget * 2);
    expect(done, isTrue, reason: 'the poll outlived twice its own budget');
  });
  return (observation: observation, returnedAt: returnedAt);
}

void main() {
  const window = Duration(seconds: 215);

  test('a row that lands before the caller settles is polled past, and the '
      'poll returns on the first read after it settles', () {
    // CI run 41576538923: a burst wrote the row 56 s after the publish, and
    // the receive timer's sweep finished ~25 s later.
    const rowAt = Duration(seconds: 56);
    const sweptAt = Duration(seconds: 81);
    final run = _run(
      read: (now) async => now >= rowAt ? [_row(_peer)] : const [],
      budget: window,
      settled: (now) => now >= sweptAt,
    );
    expect(run.observation.fix, isNotNull);
    expect(run.returnedAt, const Duration(seconds: 85));
    expect(run.observation.wall, run.returnedAt);
    expect(run.observation.polls, 18);
  });

  test('settled with no row keeps polling until the row lands', () {
    final run = _run(
      read: (now) async =>
          now >= const Duration(seconds: 30) ? [_row(_peer)] : const [],
      budget: window,
    );
    expect(run.observation.fix, isNotNull);
    expect(run.returnedAt, const Duration(seconds: 30));
  });

  test("another sender's row is not the peer's", () {
    final run = _run(
      read: (now) async => [_row('ff' * 32)],
      budget: const Duration(seconds: 20),
    );
    expect(run.observation.fix, isNull);
  });

  test('a row that never lands is null at the deadline', () {
    final run = _run(
      read: (now) async => const [],
      budget: const Duration(seconds: 20),
    );
    expect(run.observation.fix, isNull);
    expect(run.returnedAt, const Duration(seconds: 20));
    expect(run.observation.polls, 4);
  });

  test('a row that lands but never settles is returned at the deadline', () {
    final run = _run(
      read: (now) async => [_row(_peer)],
      budget: const Duration(seconds: 20),
      settled: (now) => false,
    );
    expect(run.observation.fix, isNotNull);
    expect(run.returnedAt, const Duration(seconds: 20));
  });

  test('a read that hangs is cut at the remaining budget', () {
    final hung = Completer<List<DecryptedLocation>>();
    final run = _run(
      read: (now) =>
          now >= const Duration(seconds: 10) ? hung.future : Future.value([]),
      budget: const Duration(seconds: 20),
    );
    expect(run.observation.fix, isNull);
    expect(run.observation.polls, 2);
    // Cut at 20 s, then the one interval the loop waits before it re-checks.
    expect(run.returnedAt, const Duration(seconds: 25));
  });

  test('a read that throws is retried, and logs its type only', () {
    final printed = <String>[];
    final saved = debugPrint;
    debugPrint = (message, {wrapWidth}) => printed.add(message ?? '');
    addTearDown(() => debugPrint = saved);
    final run = _run(
      read: (now) async {
        if (now < const Duration(seconds: 10)) {
          throw StateError('read failed for $_peer');
        }
        return [_row(_peer)];
      },
      budget: window,
    );
    expect(run.observation.fix, isNotNull);
    expect(run.returnedAt, const Duration(seconds: 10));
    expect(run.observation.polls, 1);
    expect(printed, hasLength(2));
    // The exact line: any pubkey, in any case, would change it.
    expect(
      printed,
      everyElement('[bg-publish] last-known read failed: StateError'),
    );
  });
}
