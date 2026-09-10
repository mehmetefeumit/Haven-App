// The Android wake-lock POLICY of phase P2a, asserted as it actually is.
//
// Three facts, and they only make sense together:
//
//   1. The `flutter_foreground_task` plugin's PERMANENT, untimed
//      PARTIAL_WAKE_LOCK is still held — `allowWakeLock` is left unset, so the
//      plugin default (true) stands. It is the only wake source for the no-fix
//      watchdog and the "armed but never delivered" recovery, so turning it off
//      here would stop background sharing silently on the exact cohort it
//      exists for, while looking like a battery fix.
//   2. Haven's own SCOPED `Haven:publish` lock exists beside it, bounded
//      natively, so removing the permanent one — once a replacement wake source
//      is proven — is a deletion rather than a redesign.
//   3. That scoped lock is NEVER released from the plugin's Kotlin lifecycle
//      listeners. The plugin invokes Dart's `onDestroy` asynchronously and then
//      calls those listeners synchronously, i.e. before the isolate's bounded
//      teardown drain has started: a release there drops the CPU under the last
//      publish of the session.
//
// This file exists because there are NO JVM tests in this repository. Nothing
// executes `PublishWakeLock.kt` on a host runner, so its policy is held by
// source assertions here, by `scripts/ci/check_android_location_power.sh`
// (which additionally owns the registration call and the manifest permission)
// and by the B1 e2e lane's `dumpsys power` oracle. Behaviour on the Dart side
// of the channel is covered by `test/services/publish_wake_lock_test.dart`.
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/constants/location.dart';

const _managerPath = 'lib/src/services/background_location_manager.dart';
const _kotlinPath =
    'android/app/src/main/kotlin/com/oblivioustech/haven/PublishWakeLock.kt';

String _read(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    fail('expected source file not found: $path (has it moved?)');
  }
  return file.readAsStringSync();
}

/// Strips `/* */` blocks and whole-line `//` comments, preserving line count.
///
/// Prose is exactly where this policy is explained — every rule below is
/// spelled out in a comment beside the code it governs — so a scan that could
/// not tell the two apart would report the explanation as the violation.
String _code(String source) {
  final withoutBlocks =
      source.replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '');
  return withoutBlocks
      .split('\n')
      .map((line) => line.trimLeft().startsWith('//') ? '' : line)
      .join('\n');
}

/// The argument list of the first `<name>(` invocation, brace/paren balanced.
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

/// The lines of a Kotlin member, from its signature to the next declaration.
///
/// Bounded by the NEXT member rather than by braces so that both body forms
/// read alike: an expression body (`= Unit`) has no braces to balance, and a
/// brace-balancing slice would run to the end of the file and report whatever
/// it found there against the wrong member.
String _kotlinMember(String code, String signature) {
  final lines = code.split('\n');
  final start = lines.indexWhere((l) => l.contains(signature));
  if (start < 0) fail('no `$signature` found in PublishWakeLock.kt');
  final nextMember =
      RegExp(r'^\s{0,8}(override |private |internal |public )*fun ');
  final body = <String>[lines[start]];
  for (var i = start + 1; i < lines.length; i++) {
    if (nextMember.hasMatch(lines[i])) break;
    body.add(lines[i]);
  }
  return body.join('\n');
}

void main() {
  group('the plugin keeps its permanent wake lock (P2a)', () {
    test('allowWakeLock is not set (the plugin lock is the watchdog wake '
        'source until a replacement is proven)', () {
      final slice = _callSlice(
        _code(_read(_managerPath)),
        'ForegroundTaskOptions',
      );

      expect(
        slice,
        isNotEmpty,
        reason: 'anti-vacuity: a file-wide search would be satisfied by the '
            'comment explaining the absence',
      );
      expect(slice, contains('eventAction:'));
      expect(
        slice.contains('allowWakeLock'),
        isFalse,
        reason: 'setting allowWakeLock — to either value — takes a position on '
            'the plugin lock. `false` removes the only wake source the no-fix '
            'watchdog has, which stops background sharing silently indoors; '
            '`true` states the default and reads as a decision that was '
            'reviewed. Phase P2b flips this assertion, together with the '
            'battery-exemption predicate it will be bound to.',
      );
    });
  });

  group('the scoped Haven:publish lock exists and is bounded natively', () {
    final kotlin = _code(_read(_kotlinPath));

    test('onEngineCreate installs the channel handler on this object', () {
      // Anti-vacuity for every other assertion in this file, and for the B1
      // lane's `dumpsys power` oracle: gutted to `= Unit` this object is still
      // a registered lifecycle listener, still declares the channel name and
      // still holds a correct lock — one that nothing can ever ask it to take.
      // Dart's every acquire becomes a MissingPluginException the client
      // swallows by design, so the whole feature is silently dead while both
      // halves keep reading right. `HavenApplication.onCreate` registering the
      // listener is the OTHER half and is pinned by
      // `check_android_location_power.sh` (2).
      final member = _kotlinMember(kotlin, 'fun onEngineCreate(');

      expect(
        member,
        contains('CHANNEL_NAME'),
        reason: 'the handler must be installed on the constant Dart is pinned '
            'to; a literal here drifts from `PublishWakeLock.channel` without '
            'either side changing',
      );
      expect(
        member,
        contains('setMethodCallHandler(this)'),
        reason: 'naming the channel is not installing it — this is the one '
            'line that makes acquire/release reach the PowerManager',
      );
    });

    test('it is a non-reference-counted PARTIAL_WAKE_LOCK tagged '
        'Haven:publish', () {
      expect(
        kotlin,
        contains('PowerManager.PARTIAL_WAKE_LOCK'),
        reason: 'a FULL/SCREEN_BRIGHT lock would light the screen of a '
            'backgrounded phone',
      );
      expect(
        kotlin,
        contains('"Haven:publish"'),
        reason: 'the tag is what `dumpsys power` reports, and what the B1 '
            'lane oracle looks for; renaming it silently blinds that oracle',
      );
      expect(
        kotlin,
        contains('setReferenceCounted(false)'),
        reason: 'a reference-counted lock needs one release per acquire; the '
            'cycle re-acquires per circle and releases once, so counting '
            'would leave it held for the whole session',
      );
    });

    test('every acquire is timed, and the timeout is coerced natively', () {
      expect(
        kotlin,
        contains('coerceIn(1L, MAX_TIMEOUT_MS)'),
        reason: 'the ceiling has to be applied on the side of the channel Dart '
            'cannot edit: a caller asking for a longer hold must be capped, '
            'not trusted',
      );
      expect(
        RegExp(r'\bacquire\(\s*\)').hasMatch(kotlin),
        isFalse,
        reason: 'a bare acquire() is untimed — exactly the permanent hold this '
            'phase is building the ground to remove',
      );
    });

    test('MAX_TIMEOUT_MS is the twin of kPublishWakeLockTimeout', () {
      final match = RegExp(
        r'MAX_TIMEOUT_MS\s*=\s*([0-9_]+)L',
      ).firstMatch(kotlin);
      expect(
        match,
        isNotNull,
        reason: 'the ceiling must stay a named Long constant; the guard and '
            'this test both read it by name',
      );

      final millis = int.parse(match!.group(1)!.replaceAll('_', ''));
      expect(
        millis,
        kPublishWakeLockTimeout.inMilliseconds,
        reason: 'Dart and Kotlin hold the same bound from opposite sides of a '
            'method channel, and nothing but this reads both. If they drift, '
            'the lock either expires mid-publish or outlives the cycle that '
            'took it.',
      );
    });
  });

  group('release is never owned by the plugin lifecycle listeners', () {
    final kotlin = _code(_read(_kotlinPath));

    test('the destroy listeners do nothing at all', () {
      for (final name in const ['onTaskDestroy', 'onEngineWillDestroy']) {
        final member = _kotlinMember(kotlin, 'fun $name(')
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();

        expect(
          RegExp('^override fun $name'r'\(\) (= Unit|\{ ?\})$')
              .hasMatch(member),
          isTrue,
          reason: 'these two run SYNCHRONOUSLY right after the plugin invokes '
              'Dart onDestroy ASYNCHRONOUSLY — before the bounded teardown '
              'drain and its final publish have started. Releasing the lock '
              'there hands the CPU back under the drain that still needs it, '
              'and detaching the channel there leaves the final release of '
              'that drain with no handler to reach. Both belong to the Dart '
              'onDestroy finally, with the native timeout as the backstop. '
              'The assertion is emptiness rather than an absence of two '
              'tokens, because a body that calls a helper reads innocent and '
              'does the same damage. Found: `$member`',
        );
      }
    });

    test('the release path is still reachable from the channel', () {
      expect(
        _kotlinMember(kotlin, 'fun onMethodCall(').contains('release()'),
        isTrue,
        reason: 'anti-vacuity for the two assertions above: they would also '
            'pass if release() had been deleted outright, which would leave '
            'every cycle relying on the timeout alone',
      );
    });
  });
}
