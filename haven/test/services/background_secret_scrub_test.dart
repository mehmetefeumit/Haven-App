/// Security Rule 9 for the background isolates.
///
/// Dart has no `zeroize`, so the raw 32-byte identity secret must be scrubbed
/// as soon as it has been handed across the FFI boundary. `withFreshSecret`
/// owns that `finally`; fetching into a bare local instead leaves the nsec in
/// the isolate's heap for the GC to relocate rather than erase, reachable from
/// a heap dump, tombstone, or core file on a rooted or debuggable device.
///
/// These paths matter more than a one-off fetch: both are re-entered on a
/// schedule. `_openCircleManager` is called by the session-reclaim path on
/// every backoff window, and the catch-up worker runs per background wake — so
/// an unscrubbed fetch mints a fresh copy each time rather than leaving one.
///
/// Neither call site can be reached under `flutter test` (both need the Rust
/// bridge), so these assert over the source. There is no repo-wide Rule 9
/// guard, which is why the background paths — the ones that repeat — are
/// pinned here explicitly.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Matches `await <anything>.getSecretBytes()` assigned to a bare local, which
/// is the shape that has no scrub attached.
final _bareFetch = RegExp(
  r'final\s+\w+\s*=\s*await\s+[\w!.]*getSecretBytes\(\)',
);

void main() {
  const paths = <String, String>{
    'background_location_task.dart':
        'lib/src/services/background_location_task.dart',
    'background_catchup_worker.dart':
        'lib/src/services/background_catchup_worker.dart',
  };

  paths.forEach((name, path) {
    group(name, () {
      late String source;

      setUpAll(() => source = File(path).readAsStringSync());

      test('the identity secret is fetched through withFreshSecret', () {
        expect(
          source.contains('withFreshSecret('),
          isTrue,
          reason: 'the scrub lives in that helper\'s finally; without it the '
              'nsec is left to the GC',
        );
      });

      test('no bare local holds the secret', () {
        final hits = _bareFetch
            .allMatches(source)
            .map((m) => m.group(0))
            .toList();
        expect(
          hits,
          isEmpty,
          reason: 'a bare local has no scrub attached, and these paths repeat '
              'on a schedule so each call leaves another copy behind; found: '
              '$hits',
        );
      });
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
