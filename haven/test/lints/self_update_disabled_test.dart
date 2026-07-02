/// Regression guard for the M5 self-update disable.
///
/// Leaderless periodic + post-join self-update is the DOMINANT generator of
/// MLS epoch forks (two members rotating from the same epoch and each eagerly
/// merging their own commit diverge permanently). M5 disables it via the
/// `enablePeriodicSelfUpdate` kill switch. These tests fail loudly if a future
/// change re-introduces an ungated self-update driver — re-opening the fork.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('M5 — self-update stays disabled', () {
    test('no production self-update timer is re-introduced', () {
      // The hourly `_selfUpdateTimer` was removed in M5. A re-added timer
      // field / Timer.periodic driving self-update would re-enable the fork.
      final offenders = <String>[];
      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        if (entity.path.contains(
          '${Platform.pathSeparator}rust${Platform.pathSeparator}',
        )) {
          continue; // generated bindings
        }
        final src = entity.readAsStringSync();
        if (src.contains('_selfUpdateTimer')) {
          offenders.add(entity.path);
        }
      }
      expect(
        offenders,
        isEmpty,
        reason: 'a self-update timer was re-introduced in: $offenders',
      );
    });

    test(
      'every selfUpdateProvider read/invalidate is in a flag-gated file',
      () {
        // Every production trigger of the rotation provider must live in a file
        // that gates it on `enablePeriodicSelfUpdate`. A new driver file that
        // reads/invalidates the provider without referencing the flag is the
        // regression we are guarding against.
        final callPattern = RegExp(
          r'\b(read|invalidate)\(\s*selfUpdateProvider\b',
        );
        final offenders = <String>[];
        for (final entity in Directory('lib').listSync(recursive: true)) {
          if (entity is! File || !entity.path.endsWith('.dart')) continue;
          if (entity.path.contains(
            '${Platform.pathSeparator}rust${Platform.pathSeparator}',
          )) {
            continue; // generated bindings
          }
          if (entity.path.endsWith('self_update_provider.dart')) {
            continue; // the provider definition itself
          }
          final src = entity.readAsStringSync();
          if (callPattern.hasMatch(src) &&
              !src.contains('enablePeriodicSelfUpdate')) {
            offenders.add(entity.path);
          }
        }
        expect(
          offenders,
          isEmpty,
          reason:
              'ungated selfUpdateProvider trigger(s) — must be behind '
              'enablePeriodicSelfUpdate: $offenders',
        );
      },
    );
  });
}
