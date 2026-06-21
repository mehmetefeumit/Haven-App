/// Tests for shared marker metrics: hue, initials, and the no-drift guarantee
/// that the edge droplet and the on-map marker compute identical colours.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/widgets/map/marker_metrics.dart';
import 'package:haven/src/widgets/map/member_marker.dart';

void main() {
  final scheme = ThemeData.light().colorScheme;

  group('avatarHue', () {
    test('is deterministic for a given pubkey', () {
      expect(avatarHue('abc123', scheme), avatarHue('abc123', scheme));
    });

    test('falls back to a surface tone when no key is available', () {
      expect(avatarHue(null, scheme), scheme.surfaceContainerHigh);
      expect(avatarHue('', scheme), scheme.surfaceContainerHigh);
    });

    testWidgets('matches the colour MemberMarker actually renders (no drift)', (
      tester,
    ) async {
      const pubkey = 'deadbeef';
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.light(),
          home: const Scaffold(
            body: Center(
              child: MemberMarker(initials: 'AB', publicKey: pubkey),
            ),
          ),
        ),
      );

      // The avatar disc is the only circular Container with a fill colour.
      final avatarColor = tester
          .widgetList<Container>(find.byType(Container))
          .map((c) => c.decoration)
          .whereType<BoxDecoration>()
          .firstWhere((d) => d.shape == BoxShape.circle && d.color != null)
          .color!;

      expect(avatarColor, avatarHue(pubkey, scheme));
    });
  });

  group('markerInitials', () {
    test('two words yield their leading letters', () {
      expect(markerInitials('Jane Doe', 'x'), 'JD');
    });

    test('one word yields its first letter', () {
      expect(markerInitials('Jane', 'x'), 'J');
    });

    test('no name falls back to the pubkey prefix', () {
      expect(markerInitials(null, 'abcdef'), 'ab');
    });

    test('a one-character pubkey is returned whole', () {
      expect(markerInitials(null, 'a'), 'a');
    });
  });

  group('onAvatarColor', () {
    test('dark foreground on a light background', () {
      expect(onAvatarColor(const Color(0xFFFFFFFF)), const Color(0xFF0A0A0A));
    });

    test('white foreground on a dark background', () {
      expect(onAvatarColor(const Color(0xFF000000)), Colors.white);
    });
  });
}
