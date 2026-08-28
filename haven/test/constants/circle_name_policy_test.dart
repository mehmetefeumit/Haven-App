/// Tests for the circle-name length policy constants.
///
/// `kCircleNameMaxLength` is quoted verbatim in `nameCircleNameTooLongError`
/// ("...50 characters or less"); ties the constant to that ARB string so the
/// two cannot drift apart independently. The validator's actual BEHAVIOUR at
/// the boundary, and `kCircleNameMaxGraphemes`'s own boundary, are pinned in
/// `test/pages/circles/name_circle_page_test.dart`, next to the widget that
/// owns them.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/constants/circle_name_policy.dart';

import '../helpers/english_arb.dart';

const _sanitizeSource = '../haven-core/src/directory/sanitize.rs';

void main() {
  test('kCircleNameMaxLength is 50', () {
    expect(kCircleNameMaxLength, 50);
  });

  test('matches the number named in nameCircleNameTooLongError', () {
    expect(
      englishArb('nameCircleNameTooLongError'),
      contains('$kCircleNameMaxLength characters or less'),
      reason: 'nameCircleNameTooLongError no longer names '
          '$kCircleNameMaxLength (constant and copy have drifted apart)',
    );
  });

  test("kCircleNameMaxGraphemes mirrors haven-core's "
      'DISPLAY_NAME_MAX_GRAPHEMES', () {
    final file = File(_sanitizeSource);
    if (!file.existsSync()) {
      fail(
        'cannot read $_sanitizeSource — this test pins '
        'kCircleNameMaxGraphemes to the Rust constant it must mirror',
      );
    }
    expect(
      file.readAsStringSync(),
      contains('pub const DISPLAY_NAME_MAX_GRAPHEMES: usize = '
          '$kCircleNameMaxGraphemes;'),
      reason: 'kCircleNameMaxGraphemes no longer names the same number as '
          "haven-core's DISPLAY_NAME_MAX_GRAPHEMES — a UI cap looser than "
          'the real storage cap silently truncates what the user typed',
    );
  });
}
