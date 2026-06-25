/// Widget tests for [NameCirclePage].
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/pages/circles/name_circle_page.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpPage(WidgetTester tester) async {
    // NameCirclePage only reads providers when Create is pressed, so it pumps
    // without overrides. ProviderScope is still required for its `ref`.
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: NameCirclePage(memberKeyPackages: []),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('shows the plain-language "what this circle means" note', (
    tester,
  ) async {
    await pumpPage(tester);

    // The useful disclosure is present: mutual location + name visibility,
    // the name's source, and cross-circle isolation.
    expect(
      find.textContaining('can see each other’s location and display name'),
      findsOneWidget,
    );
    expect(
      find.textContaining('you set in Settings → Identity'),
      findsOneWidget,
    );
    expect(
      find.textContaining('stays separate from any others'),
      findsOneWidget,
    );
  });

  testWidgets('drops the old green encryption badge and lock icon', (
    tester,
  ) async {
    await pumpPage(tester);

    expect(
      find.text('Your location is encrypted and private to this circle'),
      findsNothing,
    );
    expect(find.byIcon(LucideIcons.lock), findsNothing);
  });
}
