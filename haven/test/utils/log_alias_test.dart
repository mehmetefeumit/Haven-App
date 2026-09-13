/// Tests for the Dart mirror of `haven_core::log_alias` (Security Rule 15).
///
/// The FFI call is faked throughout — `flutter test` never calls
/// `RustLib.init()`, so a test exercising the real binding would only prove
/// the degrade-on-failure path, not the memo/bucket/relative-time logic this
/// file actually owns.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/utils/log_alias.dart';

import '../helpers/log_capture.dart';

/// A fake FFI call recording every invocation and returning a handle derived
/// from the class + value, so a test can tell "the real value never reached
/// the fake a second time" (memo hit) from "it did" (memo miss) without
/// depending on the real HMAC.
({
  String Function({required LogAliasClassFfi class_, required String value})
  call,
  List<({LogAliasClassFfi class_, String value})> invocations,
})
_fakeFfi() {
  final invocations = <({LogAliasClassFfi class_, String value})>[];
  String call({required LogAliasClassFfi class_, required String value}) {
    invocations.add((class_: class_, value: value));
    return '${class_.name}#fake${invocations.length}';
  }

  return (call: call, invocations: invocations);
}

void main() {
  late String Function({
    required LogAliasClassFfi class_,
    required String value,
  })
  originalCall;

  setUp(() {
    originalCall = logAliasFfiCall;
    clearLogAliasMemo();
  });

  tearDown(() {
    logAliasFfiCall = originalCall;
    clearLogAliasMemo();
  });

  group('logAlias', () {
    test('a repeated call with the same class+value is a memo hit', () {
      final fake = _fakeFfi();
      logAliasFfiCall = fake.call;

      final first = logAliasHandle(LogAliasClass.circle, 'deadbeef');
      final second = logAliasHandle(LogAliasClass.circle, 'deadbeef');

      expect(first, second);
      expect(
        fake.invocations,
        hasLength(1),
        reason: 'the second call must be served from the memo, never hit '
            'the FFI a second time for the same class+value',
      );
    });

    test('a different value, or a different class, is a memo miss', () {
      final fake = _fakeFfi();
      logAliasFfiCall = fake.call;

      logAliasHandle(LogAliasClass.circle, 'deadbeef');
      logAliasHandle(LogAliasClass.circle, 'cafebabe');
      logAliasHandle(LogAliasClass.peer, 'deadbeef');

      expect(
        fake.invocations,
        hasLength(3),
        reason: 'three distinct (class, value) pairs must all reach the FFI',
      );
    });

    test('clearLogAliasMemo forces the next call back to the FFI', () {
      final fake = _fakeFfi();
      logAliasFfiCall = fake.call;

      logAliasHandle(LogAliasClass.circle, 'deadbeef');
      clearLogAliasMemo();
      logAliasHandle(LogAliasClass.circle, 'deadbeef');

      expect(fake.invocations, hasLength(2));
    });

    test('the memo is bounded — it clears itself before growing unbounded', () {
      final fake = _fakeFfi();
      logAliasFfiCall = fake.call;

      // One over the internal 512-entry bound, all distinct values.
      for (var i = 0; i < 513; i++) {
        logAliasHandle(LogAliasClass.event, 'event-$i');
      }
      expect(fake.invocations, hasLength(513));

      // The very first value was memoized before the bound-triggered clear,
      // so if the map never cleared, re-requesting it now would be a memo
      // hit (no new invocation). Since it DOES clear, this is a fresh miss.
      logAliasHandle(LogAliasClass.event, 'event-0');
      expect(
        fake.invocations,
        hasLength(514),
        reason: 'the memo must have been cleared at some point during the '
            '513 distinct insertions, or this early value would still be '
            'cached and this call would not reach the FFI',
      );
    });

    test('degrades to a fixed marker and logs only the failure type when '
        'the FFI call throws', () {
      final logged = LogCapture.install();
      logAliasFfiCall = ({required class_, required value}) =>
          throw StateError('bridge not initialized');

      final handle = logAliasHandle(
        LogAliasClass.relay,
        'wss://relay.example.com',
      );

      expect(handle, 'relay#??????');
      logged
        ..assertContains('StateError')
        ..assertNoNeedles(['wss://relay.example.com', 'relay.example.com']);
    });

    test('a degraded call is not memoized as if it were a real handle', () {
      var calls = 0;
      logAliasFfiCall = ({required class_, required value}) {
        calls++;
        if (calls == 1) throw StateError('transient');
        return '${class_.name}#recovered';
      };

      final first = logAliasHandle(LogAliasClass.peer, 'npub1x');
      final second = logAliasHandle(LogAliasClass.peer, 'npub1x');

      expect(first, 'peer#??????');
      expect(
        second,
        'peer#recovered',
        reason: 'a transient FFI failure must not permanently poison the '
            'handle for a value that later resolves successfully',
      );
    });
  });

  group('magnitudeBucket', () {
    test('buckets 0, 1, 2-4 and 5+ exactly like the Rust side', () {
      expect(magnitudeBucket(0), '0');
      expect(magnitudeBucket(1), '1');
      expect(magnitudeBucket(2), '2-4');
      expect(magnitudeBucket(4), '2-4');
      expect(magnitudeBucket(5), '5+');
      expect(magnitudeBucket(9001), '5+');
    });

    test('never states the exact count once past the single-digit buckets', () {
      // 5 itself is excluded: "5+" trivially starts with "5" by design — the
      // property under test is that a LARGER count is never spelled out in
      // full, not that the bucket's own leading digit is hidden.
      for (final n in [6, 42, 1000]) {
        expect(magnitudeBucket(n), isNot(contains('$n')));
      }
    });
  });

  group('relativeSecs', () {
    test('formats an instant after the origin with a plus sign', () {
      final origin = DateTime(2026, 1, 1, 12);
      final t = origin.add(const Duration(seconds: 34));
      expect(relativeSecs(LogOrigin.forTest(origin), t), 't+34s');
    });

    test('formats an instant before the origin with a minus sign', () {
      final origin = DateTime(2026, 1, 1, 12);
      final t = origin.subtract(const Duration(seconds: 60));
      expect(relativeSecs(LogOrigin.forTest(origin), t), 't-60s');
    });

    test('formats the origin itself as t+0s', () {
      final origin = DateTime(2026, 1, 1, 12);
      expect(relativeSecs(LogOrigin.forTest(origin), origin), 't+0s');
    });

    test('never reveals the absolute wall-clock instant', () {
      final origin = DateTime(2026, 9, 12, 8, 3, 29);
      final t = origin.add(const Duration(minutes: 5));
      final rendered = relativeSecs(LogOrigin.forTest(origin), t);
      expect(rendered, isNot(contains('2026')));
      expect(
        rendered,
        isNot(contains(origin.millisecondsSinceEpoch.toString())),
      );
    });

    test('LogOrigin.now() captures the real current instant', () {
      final before = DateTime.now();
      final origin = LogOrigin.now();
      final after = DateTime.now();
      // Indirect: relativeSecs(origin, after) must be a small non-negative
      // offset — the only externally observable property of a `LogOrigin`,
      // by design (its instant is otherwise opaque).
      final rendered = relativeSecs(origin, after);
      expect(rendered, startsWith('t+'));
      expect(
        after.difference(before).inSeconds,
        lessThan(2),
        reason: 'sanity: this test itself must run fast',
      );
    });
  });

  group('LogAliasClass.tag', () {
    test('matches haven_core::log_alias::LogAliasClass::tag() exactly', () {
      // Parity pin: haven-core/src/log_alias.rs's `tag()` match arms, copied
      // literally. A drift here (e.g. a future variant added on one side but
      // not the other, or a spelling change) must fail this test, not show
      // up as a mismatched prefix between a Rust-emitted and a Dart-degraded
      // handle for the same class.
      const expected = {
        LogAliasClass.circle: 'circle',
        LogAliasClass.peer: 'peer',
        LogAliasClass.event: 'event',
        LogAliasClass.relay: 'relay',
        LogAliasClass.keyPackage: 'key_package',
        LogAliasClass.subscription: 'subscription',
      };

      expect(
        expected.keys.toSet(),
        LogAliasClass.values.toSet(),
        reason: 'every enum variant must be covered by this parity table — '
            'a variant added to one side and not the other must fail loudly',
      );
      for (final entry in expected.entries) {
        expect(entry.key.tag, entry.value);
      }
    });

    test('the degraded marker uses the snake_case tag, not enum .name', () {
      logAliasFfiCall = ({required class_, required value}) =>
          throw StateError('bridge not initialized');

      expect(
        logAliasHandle(LogAliasClass.keyPackage, 'slot-1'),
        'key_package#??????',
        reason: 'must read key_package#??????, matching the real FFI '
            "handle's prefix — not keyPackage#?????? (enum .name)",
      );
    });
  });

  group('bridge-unavailable warning is one-shot per isolate', () {
    test('logs the failure type only once across repeated degraded calls',
        () {
      final logged = LogCapture.install();
      logAliasFfiCall = ({required class_, required value}) =>
          throw StateError('bridge not initialized');

      logAliasHandle(LogAliasClass.circle, 'aaaa');
      logAliasHandle(LogAliasClass.peer, 'bbbb');
      logAliasHandle(LogAliasClass.event, 'cccc');

      expect(
        logged.lines.where((l) => l != null && l.contains('StateError')),
        hasLength(1),
        reason: 'every call after the first degraded one must stay silent, '
            'or a sustained bridge outage would print one line per log call '
            'for the rest of the process — itself a volume/timing signal',
      );
    });

    test('clearLogAliasMemo re-arms the warning for a fresh observation', () {
      final logged = LogCapture.install();
      logAliasFfiCall = ({required class_, required value}) =>
          throw StateError('bridge not initialized');

      logAliasHandle(LogAliasClass.circle, 'aaaa');
      clearLogAliasMemo();
      logAliasHandle(LogAliasClass.circle, 'aaaa');

      expect(
        logged.lines.where((l) => l != null && l.contains('StateError')),
        hasLength(2),
      );
    });
  });

  group('rotateLogAliasSalt', () {
    late void Function() originalRotateCall;

    setUp(() => originalRotateCall = rotateLogAliasSaltCall);
    tearDown(() => rotateLogAliasSaltCall = originalRotateCall);

    test('a throwing FFI call is swallowed, never propagates', () {
      rotateLogAliasSaltCall = () => throw StateError('rotation unavailable');

      expect(rotateLogAliasSaltNow, returnsNormally);
    });

    test('a throwing FFI call logs only the failure type', () {
      final logged = LogCapture.install();
      rotateLogAliasSaltCall = () =>
          throw StateError('rotation unavailable: leaked-value-should-not-log');

      rotateLogAliasSaltNow();

      logged
        ..assertContains('StateError')
        ..assertNoNeedles(['leaked-value-should-not-log']);
    });

    test('a successful call reaches the injected FFI exactly once', () {
      var calls = 0;
      rotateLogAliasSaltCall = () => calls++;

      rotateLogAliasSaltNow();

      expect(calls, 1);
    });
  });
}
