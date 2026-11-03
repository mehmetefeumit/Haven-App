/// The bounded poll behind the iOS background lane's P2d oracle
/// (`ios_bg_publish_test.dart`): a peer's row in the PERSISTED last-known
/// store, read until it lands and the caller's second condition holds.
///
/// Its own file so `test/e2e/stored_fix_poll_test.dart` can drive it under
/// `fake_async`; the drive passes the store read in, so the read stays in the
/// drive where `check_ios_background_publish.sh` pins it.
library;

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart' show debugPrint, immutable;
import 'package:haven/src/services/circle_service.dart' show DecryptedLocation;

const Duration _pollInterval = Duration(seconds: 5);

bool _always() => true;

/// What one bounded poll of the persisted last-known store saw.
@immutable
class StoredFixObservation {
  /// Creates a [StoredFixObservation].
  const StoredFixObservation({
    required this.fix,
    required this.polls,
    required this.wall,
  });

  /// The peer's persisted row, or `null` if none ever appeared.
  ///
  /// Non-null at the deadline does NOT mean the poll's `settled` held: a poll
  /// that saw the row but never its second condition returns the row too.
  final DecryptedLocation? fix;

  /// How many reads the poll made — printed so a run that never got to ASK is
  /// distinguishable from one that asked and was answered nothing.
  final int polls;

  /// Wall clock the poll consumed. Compared against its own budget before its
  /// verdict is trusted: a frozen isolate observes nothing for reasons that
  /// have nothing to do with the catch-up sweep.
  final Duration wall;
}

/// Polls [read] for [senderPubkeyHex]'s row until a read returns it while
/// [settled] holds, or [budget] expires.
///
/// [settled] exists because the row and the event the caller attributes it to
/// are observed separately: P2d's row has two writers, and the receive timer's
/// sweep count advances only when its sweep finishes — after a burst's catch-up
/// may already have written the row. Returning on the row alone samples the
/// count too early (CI run 41576538923).
///
/// Each read is bounded by the remaining budget: a read that hangs inside
/// SQLCipher or the FFI must be subject to the deadline rather than outlive it.
Future<StoredFixObservation> pollForStoredPeerFix({
  required Future<List<DecryptedLocation>> Function() read,
  required String senderPubkeyHex,
  required Duration budget,
  bool Function() settled = _always,
}) async {
  final startedAt = clock.now();
  final deadline = startedAt.add(budget);
  final wanted = senderPubkeyHex.toLowerCase();
  var polls = 0;
  DecryptedLocation? fix;
  while (true) {
    final remaining = deadline.difference(clock.now());
    if (remaining <= Duration.zero) break;
    try {
      final rows = await read().timeout(remaining);
      polls += 1;
      for (final row in rows) {
        if (row.senderPubkey.toLowerCase() == wanted) {
          fix = row;
          break;
        }
      }
      if (fix != null && settled()) break;
    } on Object catch (e) {
      // Rule 8: the type only — the read reaches SQLCipher and the FFI.
      debugPrint('[bg-publish] last-known read failed: ${e.runtimeType}');
    }
    await Future<void>.delayed(_pollInterval);
  }
  return StoredFixObservation(
    fix: fix,
    polls: polls,
    wall: clock.now().difference(startedAt),
  );
}
