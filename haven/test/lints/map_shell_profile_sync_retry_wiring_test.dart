// Static guard for a wiring promise that cannot be executed: `map_shell.dart`
// needs the Rust bridge (CLAUDE.md), so it cannot be widget-tested, and
// `flutter test` cannot simulate cold-start / app-resume lifecycle events
// against it either. This pins that `triggerProfileSyncRetry` — the
// resume/cold-start entry point for the own-profile publish retry — is
// wired beside BOTH existing `triggerProfileRefresh` call sites, so a future
// edit cannot silently drop one without a red test.
//
// Matches `test/lints/publish_decorrelation_wiring_test.dart`'s technique:
// strip comments so a prose mention can never satisfy the assertion, and
// match identifiers only.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _codeOnly(String source) => source
    .split('\n')
    .where((line) => !line.trimLeft().startsWith('//'))
    .join('\n');

void main() {
  test(
    'triggerProfileSyncRetry is wired at both the cold-start and resume '
    'profile-refresh call sites',
    () {
      const path = 'lib/src/pages/map_shell.dart';
      final file = File(path);
      expect(
        file.existsSync(),
        isTrue,
        reason: 'expected source file not found: $path',
      );
      final code = _codeOnly(file.readAsStringSync());

      final refreshCallCount = 'triggerProfileRefresh('.allMatches(code).length;
      final retryCallCount = 'triggerProfileSyncRetry('.allMatches(code).length;

      expect(
        refreshCallCount,
        2,
        reason: 'this test assumes exactly the two known '
            'triggerProfileRefresh call sites (cold-start + resume); update '
            'both this count and the reasoning below if a third is added',
      );
      expect(
        retryCallCount,
        2,
        reason: 'triggerProfileSyncRetry must be wired beside BOTH '
            'triggerProfileRefresh call sites, so a resumed session and a '
            'cold start both resume any own-profile publish a prior session '
            'left queued',
      );
    },
  );
}
