// Static guard for plan §10 D2 (member-picker typed-stranger resolve): the
// resolve itself never waits on a picture.
//
// Since 2026-11-12 (owner direction) a resolved person's picture IS
// downloaded — by `strangerPictureProvider`, a separate provider the row
// watches only once the resolve has returned a profile with no picture
// cached. Keeping the download OUT of the resolve is what guarantees the name
// is never held back by a GET to a server the person chose, which is the
// promise pinned here.
//
// `flutter test` cannot execute
// `NostrProfileService.resolveTypedStrangerProfile` itself — it wraps a
// generated Rust-FFI binding with no `RustLib.init()` in the unit-test
// environment (see CLAUDE.md, "Widget tests with Rust FFI"). What CAN be
// pinned without the bridge is the source shape the promise rests on: the
// method reads only already-cached thumbnail bytes (`_toProfile`'s
// `forcePictureLookup` stays at its default `false`) and starts no download.
//
// Scoped to the ONE method's body (never a whole-file substring search): the
// same file's `downloadMemberPictures` legitimately names the download.

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

  test('resolveTypedStrangerProfile never waits on a picture', () {
    expect(
      body,
      isNot(contains('forcePictureLookup: true')),
      reason:
          'the resolve reads only cached thumbnail bytes; '
          'forcePictureLookup must stay at its default (false) here.',
    );
    expect(
      body,
      isNot(contains('ownloadMemberPicture')),
      reason:
          'the picture is downloaded by strangerPictureProvider after the '
          'resolve returns — inside the resolve, a GET to a server the '
          'person chose would hold back their name.',
    );
  });

  test('resolveTypedStrangerProfile mirrors the thumbnail-only resolution '
      'getMemberProfile uses', () {
    expect(
      body,
      contains('fullResolution: false'),
      reason:
          'mirrors getMemberProfile — the lightweight, single-pubkey read '
          'path, not the full-resolution own-profile path.',
    );
  });
}
