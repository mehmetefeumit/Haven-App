/// Widget tests for [LegacyCutoverExplainerDialog].
///
/// The dialog is a static-`show` modal, so each test pumps a host widget
/// that calls [LegacyCutoverExplainerDialog.show] in response to a button
/// tap.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/widgets/common/legacy_cutover_explainer_dialog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget buildHost() {
    return MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => LegacyCutoverExplainerDialog.show(context),
            child: const Text('Show dialog'),
          ),
        ),
      ),
    );
  }

  group('LegacyCutoverExplainerDialog', () {
    testWidgets('appears after triggering show, with title + both paragraphs '
        'and an acknowledgement button', (tester) async {
      await tester.pumpWidget(buildHost());

      await tester.tap(find.text('Show dialog'));
      await tester.pumpAndSettle();

      expect(find.text('Haven has been updated'), findsOneWidget);
      expect(
        find.text(
          'Your identity and public profile are unchanged — there is '
          'nothing you need to do for those.',
        ),
        findsOneWidget,
      );
      expect(
        find.text(
          'For improved security, your circles need to be re-created and '
          'their members re-invited before you can share locations in them '
          'again.',
        ),
        findsOneWidget,
      );
      expect(find.text('Got it'), findsOneWidget);
    });

    testWidgets('dismisses when the acknowledgement button is tapped', (
      tester,
    ) async {
      await tester.pumpWidget(buildHost());

      await tester.tap(find.text('Show dialog'));
      await tester.pumpAndSettle();
      expect(find.text('Haven has been updated'), findsOneWidget);

      await tester.tap(find.text('Got it'));
      await tester.pumpAndSettle();

      expect(find.text('Haven has been updated'), findsNothing);
    });
  });
}
