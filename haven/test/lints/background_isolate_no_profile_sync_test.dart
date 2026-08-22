// Static guard: the own-profile publish trigger must NEVER run in a
// background isolate.
//
// `utils/profile_sync_trigger.dart` reads the FOREGROUND Riverpod
// `ProviderContainer` (via `WidgetRef`) to reach `ownProfileSyncProvider`'s
// single coalescing point. Both background entry points construct their own
// throwaway service wiring outside that container
// (`background_identity_service.dart` / a fresh `CircleManagerFfi` per wake)
// — calling the trigger there would either crash (no `WidgetRef` exists) or,
// if some other path reached the same symbols directly, defeat the one
// coalescing point `triggerProfileSync`'s doc promises. This cannot be
// exercised behaviourally under `flutter test` (both files need the Rust
// bridge and, for the WorkManager file, a real background wake — see
// `test/lints/publish_decorrelation_wiring_test.dart` for the same
// constraint), so it is pinned by source scan instead: neither background
// file may reference any profile-sync symbol at all.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String relativePath) {
  final file = File(relativePath);
  if (!file.existsSync()) {
    fail(
      'expected source file not found: $relativePath (has it moved? this '
      'test pins a privacy/correctness invariant to its call site)',
    );
  }
  return file.readAsStringSync();
}

/// Strips `//` line comments and `///` doc comments so an assertion can
/// never be satisfied — or broken — by a comment that merely mentions a
/// symbol (a prose reference, a "do not do X" warning, etc.).
String _codeOnly(String source) => source
    .split('\n')
    .where((line) => !line.trimLeft().startsWith('//'))
    .join('\n');

/// Every identifier that would indicate the own-profile sync/publish path
/// has been wired into a background entry point.
const _profileSyncSymbols = [
  'triggerProfileSync',
  'triggerProfileSyncRetry',
  'ownProfileSyncProvider',
  'OwnProfileSyncController',
  'syncOwnProfile',
  'syncMyProfile',
];

void main() {
  group('background isolates never reference profile-sync symbols', () {
    for (final path in [
      'lib/src/services/background_location_task.dart',
      'lib/src/services/background_catchup_worker.dart',
    ]) {
      test(path, () {
        final code = _codeOnly(_read(path));
        for (final symbol in _profileSyncSymbols) {
          expect(
            code,
            isNot(contains(symbol)),
            reason:
                '$path must never reference "$symbol" — the own-profile '
                'publish trigger reads the FOREGROUND Riverpod container '
                'and must only ever run from it (see '
                '`utils/profile_sync_trigger.dart`)',
          );
        }
      });
    }
  });
}
