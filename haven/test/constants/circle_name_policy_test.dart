/// Tests for the circle-name length policy constant.
///
/// `kCircleNameMaxLength` is quoted verbatim in `nameCircleNameTooLongError`
/// ("...50 characters or less"); ties the constant to that ARB string so the
/// two cannot drift apart independently. The validator's actual BEHAVIOUR at
/// the boundary is pinned in `test/pages/circles/name_circle_page_test.dart`,
/// next to the widget that owns it.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/constants/circle_name_policy.dart';

import '../helpers/english_arb.dart';

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
}
