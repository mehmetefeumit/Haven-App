// Static guard: `kTileMaxRetention`/`kTileIdlePurgeAge` must actually reach
// the eviction call, not merely exist as unread constants.
//
// `flutter test` cannot execute `tileCacheEvict` itself — it is a generated
// Rust-FFI binding with no `RustLib.init()` in the unit-test environment (see
// CLAUDE.md, "Widget tests with Rust FFI"). What CAN be pinned without the
// bridge is that both cold-start call sites still pass these identifiers
// rather than a re-typed literal, matching the wiring-only pattern in
// `publish_decorrelation_wiring_test.dart`. It matches identifiers, never
// prose, so a comment rewrite cannot satisfy or break it.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String relativePath) {
  final file = File(relativePath);
  if (!file.existsSync()) {
    fail(
      'expected source file not found: $relativePath (has it moved? this '
      'test pins a privacy invariant to its call site)',
    );
  }
  return file.readAsStringSync();
}

/// Strips `//`/`///` line comments so a comment merely mentioning the
/// identifiers can never satisfy this test on its own.
String _codeOnly(String source) => source
    .split('\n')
    .where((line) => !line.trimLeft().startsWith('//'))
    .join('\n');

void main() {
  group('tile eviction call sites pass the named retention constants', () {
    for (final path in [
      'lib/main.dart',
      'lib/src/pages/map/map_page.dart',
    ]) {
      group(path, () {
        late String code;

        setUp(() => code = _codeOnly(_read(path)));

        test('idleAgeSecs is wired to kTileIdlePurgeAge', () {
          expect(
            code,
            contains('idleAgeSecs: kTileIdlePurgeAge.inSeconds'),
            reason: '$path no longer passes kTileIdlePurgeAge to the '
                'eviction call',
          );
        });

        test('maxRetentionSecs is wired to kTileMaxRetention', () {
          expect(
            code,
            contains('maxRetentionSecs: kTileMaxRetention.inSeconds'),
            reason: '$path no longer passes kTileMaxRetention to the '
                'eviction call — the "up to seven days" privacy promise '
                'would no longer be enforced there',
          );
        });
      });
    }
  });
}
