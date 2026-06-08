/// Widget tests for [LocationDisclosureController.ensureDisclosed].
///
/// Tests the three scenarios described in the task spec:
///
/// 1. Fresh state — dialog shown, Agree persists keys and returns true.
/// 2. Short-circuit — foreground key already persisted, no dialog shown.
/// 3. Background separation — foreground persisted but background not;
///    ensureDisclosed(includeBackground:true) must still show the dialog.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/constants/location.dart';
import 'package:haven/src/providers/location_disclosure_provider.dart';
import 'package:haven/src/test_keys.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Builds a host widget that calls
  /// [LocationDisclosureController.ensureDisclosed] when its button is tapped
  /// and stores the resolved value in [result].
  Widget buildHost({
    required bool includeBackground,
    required ValueNotifier<bool?> result,
  }) {
    return ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => ElevatedButton(
              onPressed: () async {
                result.value = await ref
                    .read(locationDisclosureControllerProvider.notifier)
                    .ensureDisclosed(
                      context,
                      includeBackground: includeBackground,
                    );
              },
              child: const Text('Trigger'),
            ),
          ),
        ),
      ),
    );
  }

  group('LocationDisclosureController.ensureDisclosed', () {
    testWidgets(
      'fresh state: dialog appears, Agree persists key and returns true',
      (tester) async {
        SharedPreferences.setMockInitialValues({});

        final result = ValueNotifier<bool?>(null);
        await tester.pumpWidget(
          buildHost(includeBackground: false, result: result),
        );

        await tester.tap(find.text('Trigger'));
        await tester.pumpAndSettle();

        // Dialog must be on screen.
        expect(find.byKey(WidgetKeys.locationDisclosureAgree), findsOneWidget);

        // Tap Agree.
        await tester.tap(find.byKey(WidgetKeys.locationDisclosureAgree));
        await tester.pumpAndSettle();

        // Future resolves to true.
        expect(result.value, isTrue);

        // Key persisted.
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getBool(kLocationDisclosureAcceptedKey), isTrue);
      },
    );

    testWidgets(
      'fresh state: Agree on foreground does NOT persist background key',
      (tester) async {
        SharedPreferences.setMockInitialValues({});

        final result = ValueNotifier<bool?>(null);
        await tester.pumpWidget(
          buildHost(includeBackground: false, result: result),
        );

        await tester.tap(find.text('Trigger'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(WidgetKeys.locationDisclosureAgree));
        await tester.pumpAndSettle();

        final prefs = await SharedPreferences.getInstance();
        // Background key must NOT have been set by a foreground-only agree.
        expect(
          prefs.getBool(kLocationDisclosureBackgroundAcceptedKey),
          isNot(isTrue),
        );
      },
    );

    testWidgets(
      'fresh state: Not Now returns false and does not persist key',
      (tester) async {
        SharedPreferences.setMockInitialValues({});

        final result = ValueNotifier<bool?>(null);
        await tester.pumpWidget(
          buildHost(includeBackground: false, result: result),
        );

        await tester.tap(find.text('Trigger'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(WidgetKeys.locationDisclosureNotNow));
        await tester.pumpAndSettle();

        expect(result.value, isFalse);

        final prefs = await SharedPreferences.getInstance();
        expect(
          prefs.getBool(kLocationDisclosureAcceptedKey),
          isNot(isTrue),
        );
      },
    );

    testWidgets(
      'short-circuit: foreground already accepted — no dialog shown',
      (tester) async {
        SharedPreferences.setMockInitialValues({
          kLocationDisclosureAcceptedKey: true,
        });

        final result = ValueNotifier<bool?>(null);
        await tester.pumpWidget(
          buildHost(includeBackground: false, result: result),
        );

        await tester.tap(find.text('Trigger'));
        // Use pump rather than pumpAndSettle so any dialog opening
        // would be detected before it settles.
        await tester.pump();
        await tester.pump();

        // No dialog should have appeared.
        expect(
          find.byKey(WidgetKeys.locationDisclosureAgree),
          findsNothing,
        );

        // Future must have resolved to true immediately.
        expect(result.value, isTrue);
      },
    );

    testWidgets(
      'background separation: foreground accepted but background not'
      ' — dialog is shown for background request',
      (tester) async {
        // Only foreground key is set; background key is absent.
        SharedPreferences.setMockInitialValues({
          kLocationDisclosureAcceptedKey: true,
        });

        final result = ValueNotifier<bool?>(null);
        await tester.pumpWidget(
          buildHost(includeBackground: true, result: result),
        );

        await tester.tap(find.text('Trigger'));
        await tester.pumpAndSettle();

        // Dialog must appear because background consent is still needed.
        expect(
          find.byKey(WidgetKeys.locationDisclosureAgree),
          findsOneWidget,
        );

        // Dismiss without confirming to avoid leaking state.
        await tester.tap(find.byKey(WidgetKeys.locationDisclosureNotNow));
        await tester.pumpAndSettle();
        expect(result.value, isFalse);
      },
    );

    testWidgets(
      'background accept persists both fg and bg keys',
      (tester) async {
        SharedPreferences.setMockInitialValues({});

        final result = ValueNotifier<bool?>(null);
        await tester.pumpWidget(
          buildHost(includeBackground: true, result: result),
        );

        await tester.tap(find.text('Trigger'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(WidgetKeys.locationDisclosureAgree));
        await tester.pumpAndSettle();

        expect(result.value, isTrue);

        final prefs = await SharedPreferences.getInstance();
        // Background acceptance implies foreground acceptance.
        expect(prefs.getBool(kLocationDisclosureAcceptedKey), isTrue);
        expect(
          prefs.getBool(kLocationDisclosureBackgroundAcceptedKey),
          isTrue,
        );
      },
    );
  });
}
