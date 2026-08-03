/// Security Rule 9 for every path that opens a `CircleManagerFfi`.
///
/// Dart has no `zeroize`, so the raw 32-byte identity secret must be scrubbed
/// as soon as it has been handed across the FFI boundary. `withFreshSecret`
/// owns that `finally`; fetching into a bare local instead leaves the nsec in
/// the isolate's heap for the GC to relocate rather than erase, reachable from
/// a heap dump, tombstone, or core file on a rooted or debuggable device.
///
/// These paths matter more than a one-off fetch because they all repeat:
/// `_openCircleManager` is re-entered by the session-reclaim path on every
/// backoff window, the catch-up worker runs per background wake, and the circle
/// service re-opens on every `initialize()` — including the retry after a
/// guard handover. An unscrubbed fetch mints a fresh copy each time rather than
/// leaving a single one.
///
/// None of these call sites can be reached under `flutter test` (all need the
/// Rust bridge), so these assert over the source. There is no repo-wide Rule 9
/// guard, which is why the repeating paths are pinned here explicitly.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Every `CircleManagerFfi.newInstance(` in a file, paired with the source that
/// lexically precedes it, so each open can be checked for an enclosing scrub.
Iterable<String> _openSitesWithContext(String source) sync* {
  const marker = 'CircleManagerFfi.newInstance(';
  var from = 0;
  while (true) {
    final at = source.indexOf(marker, from);
    if (at < 0) return;
    // Enough context to contain the enclosing `withFreshSecret(` call, which
    // sits within a few lines in every current call shape.
    yield source.substring((at - 400).clamp(0, source.length), at);
    from = at + marker.length;
  }
}

void main() {
  const paths = <String, String>{
    'background_location_task.dart':
        'lib/src/services/background_location_task.dart',
    'background_catchup_worker.dart':
        'lib/src/services/background_catchup_worker.dart',
    'nostr_circle_service.dart': 'lib/src/services/nostr_circle_service.dart',
  };

  paths.forEach((name, path) {
    group(name, () {
      late String source;

      setUpAll(() => source = File(path).readAsStringSync());

      test('every manager open is wrapped in withFreshSecret', () {
        // Asserted PER OPEN SITE rather than as a file-level `contains`. A
        // file-wide check passes on an unrelated use elsewhere in the same
        // file — exactly how an earlier version of this test let an unscrubbed
        // open through in nostr_circle_service.dart.
        final sites = _openSitesWithContext(source).toList();
        expect(
          sites,
          isNotEmpty,
          reason: 'this file is listed because it opens a manager; if that '
              'moved, update the list rather than deleting the check',
        );
        for (final context in sites) {
          expect(
            context.contains('withFreshSecret('),
            isTrue,
            reason: 'a manager opened outside withFreshSecret leaves the raw '
                'nsec for a GC that relocates rather than erases; these paths '
                'repeat, so each call leaves another copy behind',
          );
        }
      });
    });
  });

  group('the guard handover is bounded', () {
    late String source;

    setUpAll(
      () => source = File(
        'lib/src/services/nostr_circle_service.dart',
      ).readAsStringSync(),
    );

    test('recovery is attempted at most once per initialize', () {
      // The handover stops the foreground service and restarts it. Looping on
      // it would stop and restart on every pass — thrashing the user's
      // background location sharing and its notification — while never making
      // progress against a guard held by something the handover cannot reach.
      final at = source.indexOf('await handover(dataDir)');
      expect(at, isNonNegative, reason: 'the recovery must be wired');

      // The call must sit in a one-shot guard clause, not a loop condition.
      final window = source.substring(
        (at - 200).clamp(0, source.length),
        at + 200,
      );
      expect(
        RegExp(r'(while|for)\s*\([^)]*handover').hasMatch(window),
        isFalse,
        reason: 'the recovery must not be retried in a loop',
      );
      expect(
        window.contains('rethrow'),
        isTrue,
        reason: 'a declined or failed handover must surface the ORIGINAL '
            'failure rather than being swallowed',
      );
    });

    test('the background isolate does not attempt a handover', () {
      // It is usually the HOLDER, so a handover would be asking the service to
      // stop itself. The injected-manager constructor must pass null.
      final at = source.indexOf('NostrCircleService.withInjectedManager({');
      expect(at, isNonNegative);
      final ctor = source.substring(at, source.indexOf('\n\n', at));
      expect(
        ctor.contains('_sessionHandover = null'),
        isTrue,
        reason: 'the holder must not be wired to stop itself',
      );
    });
  });

  test('withFreshSecret actually scrubs', () {
    // Guards the assumption every assertion above rests on. If the helper ever
    // stopped wiping, the checks would still pass while protecting nothing.
    final helper = File('lib/src/services/fresh_secret.dart').readAsStringSync();
    expect(helper.contains('finally'), isTrue);
    expect(
      RegExp(r'fillRange\(\s*0\s*,\s*\w+\.length\s*,\s*0\s*\)').hasMatch(helper),
      isTrue,
      reason: 'the helper must overwrite the buffer, not merely drop it',
    );
  });
}
