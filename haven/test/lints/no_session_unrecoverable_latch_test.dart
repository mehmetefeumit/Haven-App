/// Source pin: no session-scoped "unrecoverable" latch comes back in Dart.
///
/// MDK persists a halted group's state, and every circle read carries it as
/// `CircleEngineState.unrecoverable`; the old in-memory latch forgot it at
/// every restart and needed two verdicts before it believed one. A latch
/// reintroduced beside the durable state would let the two disagree, and the
/// one that forgets is the one that would let a send through.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('lib/ names none of the deleted latch symbols', () {
    const banned = [
      'isCircleBlocked',
      'markCircleBlocked',
      '_blockedCircleIds',
      '_unconfirmedWedges',
      '_reanchorGeneration',
    ];
    final offenders = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      if (entity.path.startsWith('lib/src/rust/')) continue;
      final source = entity.readAsStringSync();
      for (final symbol in banned) {
        if (source.contains(symbol)) offenders.add('${entity.path}: $symbol');
      }
    }
    expect(offenders, isEmpty);
  });

  test('the scan sees lib/ at all', () {
    // Anti-vacuity: run from a directory with no lib/ the scan would pass.
    expect(File('lib/main.dart').existsSync(), isTrue);
  });
}
