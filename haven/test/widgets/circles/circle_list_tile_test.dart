/// Widget tests for [CircleListTile] grapheme-safe avatar initial.
///
/// Guards against regression of the UTF-16 code-unit indexing bug where
/// `displayName[0]` splits a surrogate pair (emoji, etc.) and renders '?'.
/// The fix replaces `displayName[0]` with
/// `displayName.characters.first` before uppercasing.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/widgets/circles/circle_list_tile.dart';

import '../../mocks/mock_circle_service.dart';

/// Pumps a [CircleListTile] for [circle] inside a minimal Riverpod+Material
/// harness and returns the [Text] rendered inside the leading [CircleAvatar].
Future<String?> _avatarInitial(
  WidgetTester tester,
  Circle circle,
) async {
  final mock = MockCircleService(circles: [circle]);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [circleServiceProvider.overrideWithValue(mock)],
      child: MaterialApp(
        home: Scaffold(body: CircleListTile(circle: circle)),
      ),
    ),
  );
  await tester.pumpAndSettle();

  // The leading avatar is a CircleAvatar whose child is a Text.
  final avatar = tester.widget<CircleAvatar>(
    find.descendant(
      of: find.byType(CircleListTile),
      matching: find.byType(CircleAvatar),
    ),
  );
  final text = avatar.child! as Text;
  return text.data;
}

void main() {
  group('CircleListTile avatar initial — grapheme-safe', () {
    testWidgets('Latin circle name shows uppercased first letter', (
      tester,
    ) async {
      final circle = TestCircleFactory.createCircle(displayName: 'Family');
      expect(await _avatarInitial(tester, circle), 'F');
    });

    testWidgets(
      'emoji-prefixed circle name shows the emoji grapheme, not "?"',
      (tester) async {
        // '🎉 Party' — the leading emoji is a surrogate pair.
        // Before the fix, displayName[0] returns a lone surrogate → '?'.
        final circle =
            TestCircleFactory.createCircle(displayName: '🎉 Party');
        final initial = await _avatarInitial(tester, circle);
        expect(initial, isNot('?'));
        // The avatar text must equal the uppercased emoji (uppercase is a no-op
        // for emoji, so the emoji itself is the expected value).
        expect(initial, '🎉');
      },
    );

    testWidgets('Cyrillic circle name shows uppercased first Cyrillic letter', (
      tester,
    ) async {
      final circle = TestCircleFactory.createCircle(displayName: 'Семья');
      final initial = await _avatarInitial(tester, circle);
      expect(initial, 'С');
    });

    testWidgets(
      'regional-indicator flag prefix shows the flag grapheme, not "?"',
      (tester) async {
        // '🇩🇪 Deutschland' — two regional-indicator code points = one grapheme.
        final circle =
            TestCircleFactory.createCircle(displayName: '🇩🇪 Deutschland');
        final initial = await _avatarInitial(tester, circle);
        expect(initial, isNot('?'));
        expect(initial, '🇩🇪');
      },
    );

    testWidgets(
      'ZWJ family emoji prefix shows the full cluster, not "?"',
      (tester) async {
        final circle =
            TestCircleFactory.createCircle(displayName: '👨‍👩‍👧 The Smiths');
        final initial = await _avatarInitial(tester, circle);
        expect(initial, isNot('?'));
        expect(initial, '👨‍👩‍👧');
      },
    );
  });
}
