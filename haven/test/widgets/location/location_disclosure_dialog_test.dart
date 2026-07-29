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

    testWidgets(
      'names every third party the encrypted location reaches',
      (tester) async {
        // This dialog is the Google Play Prominent Disclosure and the record of
        // the user's consent. It previously claimed location was seen by
        // "never Haven, and never any other entity", which was false: encrypted
        // updates transit third-party relays, and drawing the map sends tile
        // coordinates derived from members' positions to an outside provider.
        // A disclosure must name third-party transmission, not deny it.
        final result = ValueNotifier<bool?>(null);
        await tester.pumpWidget(
          buildHost(includeBackground: false, result: result),
        );
        await tester.tap(find.text('Show dialog'));
        await tester.pumpAndSettle();

        expect(find.textContaining('relays run by other people'), findsOneWidget);
        expect(find.textContaining('Stadia Maps'), findsAtLeastNWidgets(1));
        // Attributed, with the retention window: never shortened to a
        // 'no logging' claim, which their policy does not support.
        expect(
          find.textContaining('does not sell or trade personal information'),
          findsOneWidget,
        );
        expect(find.textContaining('server logs'), findsOneWidget);
        // The absolute must never come back.
        expect(find.textContaining('never any other entity'), findsNothing);
      },
    );

    testWidgets(
      'states that foreground sharing cannot be paused, in BOTH scopes',
      (tester) async {
        // `background`/`manage` render only in the background scope, so the
        // foreground fact has to live in an always-shown string — otherwise a
        // foreground-only consent advertises a toggle the user does not get.
        for (final includeBackground in [false, true]) {
          final result = ValueNotifier<bool?>(null);
          await tester.pumpWidget(
            buildHost(includeBackground: includeBackground, result: result),
          );
          await tester.tap(find.text('Show dialog'));
          await tester.pumpAndSettle();

          expect(
            find.textContaining('There is no pause'),
            findsOneWidget,
            reason: 'missing with includeBackground=$includeBackground',
          );
          expect(
            find.textContaining('leave it'),
            findsOneWidget,
            reason: 'no way to stop given (includeBackground=$includeBackground)',
          );
          await tester.tap(find.byKey(WidgetKeys.locationDisclosureNotNow));
          await tester.pumpAndSettle();
        }
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

    testWidgets(
      'includeBackground:true tells the user they can turn it off in Settings',
      (tester) async {
        final result = ValueNotifier<bool?>(null);
        await tester.pumpWidget(
          buildHost(includeBackground: true, result: result),
        );

        await tester.tap(find.text('Show dialog'));
        await tester.pumpAndSettle();

        expect(
          find.textContaining('turn background sharing off'),
          findsAtLeastNWidgets(1),
        );
      },
    );

    testWidgets(
      'includeBackground:false does NOT show the Settings off-switch line',
      (tester) async {
        final result = ValueNotifier<bool?>(null);
        await tester.pumpWidget(
          buildHost(includeBackground: false, result: result),
        );

        await tester.tap(find.text('Show dialog'));
        await tester.pumpAndSettle();

        expect(
          find.textContaining('turn background sharing off'),
          findsNothing,
        );
      },
    );
  });
}
