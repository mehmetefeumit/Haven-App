// The Android boot/update resume policy, as source (owner-directed
// 2026-11-26, OD-R2). Paired with guard checks 14c/14e/14n in
// `scripts/ci/check_m7_native_wake_guards.sh`; the receiver's decision is
// unit-tested in `android/app/src/test/.../BootResumeTest.kt`.
//
//   1. The plugin's own boot/update options are absent. They steer only its
//      RebootReceiver, which the manifest removes; back in place they would
//      read as a second start path, and on a plugin whose receiver returned
//      they would restart sharing on options an OLD build stored, without
//      the resume rule.
//   2. `backgroundCallback` keeps its name, library and entry-point pragma.
//      The callback handle the plugin stores is a hash of name and library,
//      and the engine resolves it from a cache that survives an app update.
//      A rename means the boot or update start launches a service whose Dart
//      never runs while its notification claims sharing.
//   3. The system-start gate is the first thing `onStart` awaits, ahead of
//      every bit of work (idle flag, Rust, keyring, session).
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _managerPath = 'lib/src/services/background_location_manager.dart';
const _taskPath = 'lib/src/services/background_location_task.dart';

String _read(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    fail('expected source file not found: $path (has it moved?)');
  }
  return file.readAsStringSync();
}

/// Strips `/* */` blocks and whole-line `//` comments, preserving line count:
/// the policy is explained in prose beside the code it governs.
String _code(String source) {
  final withoutBlocks = source.replaceAll(
    RegExp(r'/\*.*?\*/', dotAll: true),
    '',
  );
  return withoutBlocks
      .split('\n')
      .map((line) => line.trimLeft().startsWith('//') ? '' : line)
      .join('\n');
}

/// The argument list of the first `<name>(` invocation, paren balanced.
String _callSlice(String code, String name) {
  final start = code.indexOf('$name(');
  if (start < 0) fail('no `$name(` call found in the code');
  var depth = 0;
  for (var i = start + name.length; i < code.length; i++) {
    final c = code[i];
    if (c == '(') depth++;
    if (c == ')') {
      depth--;
      if (depth == 0) return code.substring(start, i + 1);
    }
  }
  fail('unbalanced parentheses after `$name(`');
}

void main() {
  test('ForegroundTaskOptions sets no boot or update start option', () {
    final options = _callSlice(
      _code(_read(_managerPath)),
      'ForegroundTaskOptions',
    );
    for (final option in ['autoRunOnBoot', 'autoRunOnMyPackageReplaced']) {
      expect(
        options,
        isNot(contains(option)),
        reason:
            '$option steers only the plugin RebootReceiver, which the '
            'manifest removes; BootResumeReceiver owns the boot and update '
            'start under the resume rule',
      );
    }
  });

  test('backgroundCallback keeps its library, name and entry-point pragma', () {
    final code = _code(_read(_taskPath));
    expect(
      RegExp(
        r"@pragma\('vm:entry-point'\)\s*\nvoid backgroundCallback\(\)",
      ).hasMatch(code),
      isTrue,
      reason:
          'the plugin stores a handle to this function, keyed on its '
          'name and library, and resolves it after an app update; renamed, '
          'moved or tree-shaken, a boot or update start runs a service whose '
          'Dart never starts while its notification claims sharing',
    );
  });

  test('the system-start gate is the first thing onStart awaits', () {
    final code = _code(_read(_taskPath));
    final start = code.indexOf(
      'Future<void> onStart(DateTime timestamp, TaskStarter starter) async {',
    );
    expect(start, isNonNegative, reason: 'onStart signature not found');
    final firstAwait = RegExp(r'\bawait\b').firstMatch(code.substring(start));
    expect(firstAwait, isNotNull);
    final at = start + firstAwait!.start;
    final line =
        code.substring(code.lastIndexOf('\n', at) + 1, at).trim() +
        code.substring(at).split('\n').first;
    expect(
      line,
      startsWith('if (await gate.check(starter) != null)'),
      reason:
          'a start Haven did not make (boot, update, sticky restart) '
          'must be judged before any work: the idle flag, Rust, the keyring '
          'and the session all come after',
    );
  });
}
