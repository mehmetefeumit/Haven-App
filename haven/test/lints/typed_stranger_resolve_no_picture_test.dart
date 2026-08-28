// Static guard for plan §10 D2 (member-picker typed-stranger resolve): the
// resolve must never force a picture download.
//
// `flutter test` cannot execute
// `NostrProfileService.resolveTypedStrangerProfile` itself — it wraps a
// generated Rust-FFI binding with no `RustLib.init()` in the unit-test
// environment (see CLAUDE.md, "Widget tests with Rust FFI").
// What CAN be pinned without the bridge is the source shape the promise rests
// on: `_toProfile`'s `forcePictureLookup` parameter defaults to `false`, and
// this is the one call site that must never override it. The sibling
// `refreshMemberProfiles` passes `forcePictureLookup: true` as part of its OWN
// batched-download flow — copying that pattern here would force a picture
// download the instant a stranger's npub resolves, which is exactly what D2
// forbids. No new picture-handling code is added by this method; that
// restraint IS the implementation, and this test is what makes it fail loud
// if a future edit adds it back.
//
// Scoped to the ONE method's body (never a whole-file substring search): a
// whole-file `expect(source, isNot(contains('forcePictureLookup: true')))`
// would also incidentally trip over `refreshMemberProfiles`'s unrelated,
// legitimate use of the same flag.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _path = 'lib/src/services/nostr_profile_service.dart';
const _signature =
    'Future<Profile?> resolveTypedStrangerProfile(String npub) async {';

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

/// The full source of the method starting at [signature] — from the
/// signature through its balanced closing brace — or fails the test if it
/// cannot be found.
///
/// Brace-counted rather than a fixed line window, so the boundary stays
/// exact regardless of how the method body is reformatted.
String _methodBody(String source, String signature) {
  final start = source.indexOf(signature);
  if (start == -1) {
    fail('expected method signature not found: $signature');
  }
  final bodyStart = source.indexOf('{', start);
  var depth = 0;
  for (var i = bodyStart; i < source.length; i++) {
    if (source[i] == '{') depth++;
    if (source[i] == '}') {
      depth--;
      if (depth == 0) return source.substring(start, i + 1);
    }
  }
  fail('unbalanced braces scanning method: $signature');
}

/// Strips `//`/`///` line comments so a comment merely NAMING the flag (as
/// this method's own doc, above, explains the sibling method's DIFFERENT
/// behaviour) can never trip — or launder — this check on its own. Matches
/// `tile_eviction_wiring_test.dart`'s convention.
String _codeOnly(String source) => source
    .split('\n')
    .where((line) => !line.trimLeft().startsWith('//'))
    .join('\n');

void main() {
  final body = _codeOnly(_methodBody(_read(_path), _signature));

  test('resolveTypedStrangerProfile never forces a picture lookup', () {
    expect(
      body,
      isNot(contains('forcePictureLookup: true')),
      reason:
          'D2: a picture URL is an HTTP GET to a host the profile owner '
          "chose, from the user's IP — that must never fire merely because "
          "a stranger's npub was typed. forcePictureLookup must stay at "
          'its default (false) at this call site.',
    );
  });

  test(
    'resolveTypedStrangerProfile mirrors the thumbnail-only resolution '
    'getMemberProfile uses',
    () {
      expect(
        body,
        contains('fullResolution: false'),
        reason:
            'mirrors getMemberProfile — the lightweight, single-pubkey read '
            'path, not the full-resolution own-profile path.',
      );
    },
  );
}
