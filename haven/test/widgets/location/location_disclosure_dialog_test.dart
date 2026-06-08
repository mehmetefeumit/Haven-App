/// Widget tests for [LocationDisclosureDialog].
///
/// The dialog is a static-`show` modal, so each test pumps a host widget
/// that calls [LocationDisclosureDialog.show] in response to a button tap
/// and captures the returned [Future<bool>].
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/widgets/location/location_disclosure_dialog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Builds a host widget whose only button calls
  /// [LocationDisclosureDialog.show] with the given [includeBackground]
  /// flag and stores the resolved value in [result].
  Widget buildHost({
    required bool includeBackground,
    required ValueNotifier<bool?> result,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              result.value = await LocationDisclosureDialog.show(
                context,
                includeBackground: includeBackground,
              );
            },
            child: const Text('Show dialog'),
          ),
        ),
      ),
    );
  }

  group('LocationDisclosureDialog (foreground)', () {
    testWidgets('dialog appears after triggering show', (tester) async {
      final result = ValueNotifier<bool?>(null);
      await tester.pumpWidget(
        buildHost(includeBackground: false, result: result),
      );

      await tester.tap(find.text('Show dialog'));
      await tester.pumpAndSettle();

      // Dialog must be visible.
      expect(find.byKey(WidgetKeys.locationDisclosureAgree), findsOneWidget);
      expect(find.byKey(WidgetKeys.locationDisclosureNotNow), findsOneWidget);
    });

    testWidgets(
      'dialog text contains "end-to-end encrypted"',
      (tester) async {
        final result = ValueNotifier<bool?>(null);
        await tester.pumpWidget(
          buildHost(includeBackground: false, result: result),
        );

        await tester.tap(find.text('Show dialog'));
        await tester.pumpAndSettle();

        expect(
          find.textContaining('end-to-end encrypted'),
          findsAtLeastNWidgets(1),
        );
      },
    );

    testWidgets('tapping Agree resolves the future to true', (tester) async {
      final result = ValueNotifier<bool?>(null);
      await tester.pumpWidget(
        buildHost(includeBackground: false, result: result),
      );

      await tester.tap(find.text('Show dialog'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(WidgetKeys.locationDisclosureAgree));
      await tester.pumpAndSettle();

      expect(result.value, isTrue);
    });

    testWidgets(
      'tapping Not now resolves the future to false',
      (tester) async {
        final result = ValueNotifier<bool?>(null);
        await tester.pumpWidget(
          buildHost(includeBackground: false, result: result),
        );

        await tester.tap(find.text('Show dialog'));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(WidgetKeys.locationDisclosureNotNow));
        await tester.pumpAndSettle();

        expect(result.value, isFalse);
      },
    );
  });

  group('LocationDisclosureDialog (background)', () {
    testWidgets(
      'includeBackground:true shows background-specific copy',
      (tester) async {
        final result = ValueNotifier<bool?>(null);
        await tester.pumpWidget(
          buildHost(includeBackground: true, result: result),
        );

        await tester.tap(find.text('Show dialog'));
        await tester.pumpAndSettle();

        expect(
          find.textContaining(
            'even when the app is closed or not in use',
          ),
          findsAtLeastNWidgets(1),
        );
      },
    );

    testWidgets(
      'includeBackground:false does NOT show background sentence',
      (tester) async {
        final result = ValueNotifier<bool?>(null);
        await tester.pumpWidget(
          buildHost(includeBackground: false, result: result),
        );

        await tester.tap(find.text('Show dialog'));
        await tester.pumpAndSettle();

        expect(
          find.textContaining(
            'even when the app is closed or not in use',
          ),
          findsNothing,
        );
      },
    );
  });
}
