/// [MemberAvatar]'s initials disc shares the map marker's palette promise:
/// the same pubkey maps to the same [AvatarPaletteEntry], with white initials.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/widgets/circles/member_avatar.dart';
import 'package:haven/src/widgets/map/marker_metrics.dart';

import '../../mocks/mock_profile_service.dart';

void main() {
  Future<void> pump(WidgetTester tester, String pubkey) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          profileServiceProvider.overrideWithValue(MockProfileService()),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Center(
              child: MemberAvatar(pubkey: pubkey, displayName: 'Bo'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final pubkey in ['00${'a' * 62}', '2b${'c' * 62}', 'ff${'0' * 62}']) {
    testWidgets('initials disc for ${pubkey.substring(0, 2)} uses the '
        "map's palette entry with white text", (tester) async {
      await pump(tester, pubkey);

      final entry = avatarPaletteFor(pubkey);
      final gradientBoxes = tester
          .widgetList<DecoratedBox>(
            find.descendant(
              of: find.byType(CircleAvatar),
              matching: find.byType(DecoratedBox),
            ),
          )
          .map((b) => b.decoration)
          .whereType<BoxDecoration>()
          .where((d) => d.gradient != null)
          .toList();
      expect(gradientBoxes, hasLength(1));
      expect(gradientBoxes.single.shape, BoxShape.circle);
      final gradient = gradientBoxes.single.gradient! as LinearGradient;
      expect(gradient.begin, Alignment.topCenter);
      expect(gradient.end, Alignment.bottomCenter);
      expect(gradient.colors, [entry.top, entry.bottom]);

      final text = tester.widget<Text>(
        find.descendant(
          of: find.byType(CircleAvatar),
          matching: find.text('B'),
        ),
      );
      expect(text.style?.color, kAvatarInitialsColor);
      expect(tester.getSize(find.byType(CircleAvatar)), const Size(40, 40));
    });
  }
}
