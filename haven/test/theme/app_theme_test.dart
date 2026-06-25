/// Tests for [HavenTheme].
///
/// Verifies theme-level invariants that affect every screen, so a regression
/// is caught once here rather than per-page.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/theme/app_theme.dart';

void main() {
  group('HavenTheme AppBar', () {
    // The leading back button is centred in a fixed 56px slot, so its glyph
    // sits 4px further from the edge than a flush-right action icon. Without
    // trailing padding the app bar looks off-centre. 4px of trailing padding
    // equalises the leading and trailing icon insets on every page that has
    // an AppBar action (invitations, circles, relay settings, qr scanner, …).
    const expected = EdgeInsetsDirectional.only(end: 4);

    test('light theme insets trailing actions to match back button', () {
      expect(HavenTheme.light().appBarTheme.actionsPadding, expected);
    });

    test('dark theme insets trailing actions to match back button', () {
      expect(HavenTheme.dark().appBarTheme.actionsPadding, expected);
    });
  });
}
