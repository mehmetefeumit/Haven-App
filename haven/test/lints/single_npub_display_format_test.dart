/// Regression guard for the ONE npub display format (plan §7.1).
///
/// `NpubValidator.shortenForDisplay` is an anti-impersonation control, not
/// styling: it pins 12 leading characters AND the 6-character bech32
/// checksum, taking a lookalike grind from ~2^35 to ~2^65. A second, shorter
/// form somewhere else in the UI silently hands an attacker the cheap end of
/// that range — and a widget that takes the length as a *parameter* hands it
/// out at the call site, where nobody reviewing the widget will see it.
///
/// `KeyDisplay`/`CompactKeyDisplay` did exactly that (`truncateLength: 4`
/// compiled) until they were deleted as dead code. This test fails if any
/// production code re-introduces a caller-settable truncation length.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('npub display format', () {
    test('no production widget takes a truncation length from its caller', () {
      // A declaration or a named argument — both are the lever.
      final lever = RegExp(r'\btruncateLength\b');
      final offenders = <String>[];
      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        if (entity.path.contains(
          '${Platform.pathSeparator}rust${Platform.pathSeparator}',
        )) {
          continue; // generated bindings
        }
        if (lever.hasMatch(entity.readAsStringSync())) {
          offenders.add(entity.path);
        }
      }
      expect(
        offenders,
        isEmpty,
        reason:
            'a caller-settable npub truncation length reappeared in: '
            '$offenders — shorten through NpubValidator.shortenForDisplay, '
            'which has no length parameter',
      );
    });
  });
}
