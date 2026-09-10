/// Widget tests for [LocationDisclosureDialog].
///
/// The dialog is a static-`show` modal, so each test pumps a host widget
/// that calls [LocationDisclosureDialog.show] in response to a button tap
/// and captures the returned [Future<bool>].
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/widgets/location/location_disclosure_dialog.dart';

/// Every string the dialog renders, in tree order, excluding the host button.
List<String> renderedDialogText(WidgetTester tester) => tester
    .widgetList<Text>(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(Text),
      ),
    )
    .map((t) => t.data ?? '')
    .toList();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Builds a host widget whose only button calls
  /// [LocationDisclosureDialog.show] with the given [includeBackground]
  /// flag and stores the resolved value in [result].
  ///
  /// [isIOS] selects the background sentence. It is pinned rather than left to
  /// `Platform.isIOS` because the host running `flutter test` is neither
  /// platform, so an implicit default would silently decide which of two
  /// compliance strings these tests assert on. Platform-specific accuracy of
  /// that sentence is covered in `test/lints/background_claim_accuracy_test
  /// .dart`.
  Widget buildHost({
    required bool includeBackground,
    required ValueNotifier<bool?> result,
    required bool isIOS,
  }) {
    return MaterialApp(
      // The copy lives in the ARB, so the delegates are not optional
      // scaffolding here: without them `AppLocalizations.of` throws and the
      // dialog renders nothing at all (`nullable-getter: false` in l10n.yaml).
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              result.value = await LocationDisclosureDialog.show(
                context,
                includeBackground: includeBackground,
                isIOS: isIOS,
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
        buildHost(includeBackground: false, result: result, isIOS: false),
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
          buildHost(includeBackground: false, result: result, isIOS: false),
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
          buildHost(includeBackground: false, result: result, isIOS: false),
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
            buildHost(
              includeBackground: includeBackground,
              result: result,
              isIOS: false,
            ),
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
        buildHost(includeBackground: false, result: result, isIOS: false),
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
          buildHost(includeBackground: false, result: result, isIOS: false),
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
      'includeBackground:true shows background-specific copy (Android)',
      (tester) async {
        final result = ValueNotifier<bool?>(null);
        await tester.pumpWidget(
          buildHost(includeBackground: true, result: result, isIOS: false),
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
      'includeBackground:true shows background-specific copy (iOS)',
      (tester) async {
        final result = ValueNotifier<bool?>(null);
        await tester.pumpWidget(
          buildHost(includeBackground: true, result: result, isIOS: true),
        );

        await tester.tap(find.text('Show dialog'));
        await tester.pumpAndSettle();

        expect(
          find.textContaining('If iOS closes Haven, sharing stops'),
          findsAtLeastNWidgets(1),
        );
      },
    );

    testWidgets(
      'includeBackground:false does NOT show background sentence',
      (tester) async {
        for (final isIOS in [false, true]) {
          final result = ValueNotifier<bool?>(null);
          await tester.pumpWidget(
            buildHost(includeBackground: false, result: result, isIOS: isIOS),
          );

          await tester.tap(find.text('Show dialog'));
          await tester.pumpAndSettle();

          expect(
            find.textContaining(
              'even when the app is closed or not in use',
            ),
            findsNothing,
            reason: 'leaked with isIOS=$isIOS',
          );
          expect(
            find.textContaining('If iOS closes Haven'),
            findsNothing,
            reason: 'leaked with isIOS=$isIOS',
          );
          await tester.tap(find.byKey(WidgetKeys.locationDisclosureNotNow));
          await tester.pumpAndSettle();
        }
      },
    );

    testWidgets(
      'includeBackground:true tells the user they can turn it off in Settings',
      (tester) async {
        final result = ValueNotifier<bool?>(null);
        await tester.pumpWidget(
          buildHost(includeBackground: true, result: result, isIOS: false),
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
          buildHost(includeBackground: false, result: result, isIOS: false),
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

  // The consent copy moved from `static const String` fields on
  // `LocationDisclosureStrings` into the `locationDisclosure*` ARB group, so
  // that the twelve non-English locales stop being asked to consent in a
  // language they may not read. An extraction that dropped a paragraph,
  // reordered two, wired a slot to the wrong key or quietly reworded a sentence
  // would still render *a* dialog — so these pin what the user actually reads:
  // the exact English text, in the exact order, in each of the three shapes the
  // dialog has.
  //
  // Verbatim literals, deliberately, NOT the generated getters: comparing the
  // render against `l10n.locationDisclosureWhy` only proves the widget read
  // that key, and would keep agreeing with itself if the words behind it
  // changed. This is a consent artefact; the words are the promise.
  group('LocationDisclosureDialog (consent copy)', () {
    const title = 'Sharing your location';
    const why =
        'Haven shows your live location to the people in the circles you '
        'choose, and shows you theirs on the map. To do this, Haven needs '
        'permission to use your device’s precise location.';
    const how =
        'Your location is end-to-end encrypted on your device, so only the '
        'members of the circles you choose can read it, not Haven. Haven runs '
        'no servers of its own: your encrypted updates pass through '
        'independent relays run by other people, which see your network '
        'address but never where you are. Drawing the map asks Stadia Maps for '
        'the areas around you and your circle, so it learns roughly where that '
        'is, but never your name, your key, or who is in your circles. Stadia '
        'Maps says it does not sell or trade personal information, sets no '
        'cookies on your device, and keeps server logs for about two weeks — '
        'its own policy, which Haven cannot enforce.';
    const sharing =
        'While Haven is open and you are in a circle, your location is sent '
        'automatically every couple of minutes. There is no pause. To stop '
        'sharing with a circle, leave it.';
    const backgroundAndroid =
        'This app uses location data to enable sharing with your circles '
        'even when the app is closed or not in use.';
    const backgroundIos =
        'This app uses location data to enable sharing with your circles even '
        'when Haven is in the background and you are not using it. If iOS '
        'closes Haven, sharing stops until you open it again — Haven may '
        'still wake up to fetch your circles’ locations, but never to send '
        'yours.';
    const manage =
        'You can turn background sharing off at any time in '
        'Settings → Location.';
    const agree = 'Agree';
    const notNow = 'Not now';

    Future<List<String>> pumpAndRead(
      WidgetTester tester, {
      required bool includeBackground,
      required bool isIOS,
    }) async {
      final result = ValueNotifier<bool?>(null);
      await tester.pumpWidget(
        buildHost(
          includeBackground: includeBackground,
          result: result,
          isIOS: isIOS,
        ),
      );
      await tester.tap(find.text('Show dialog'));
      await tester.pumpAndSettle();
      return renderedDialogText(tester);
    }

    testWidgets('foreground scope renders the whole disclosure, in order',
        (tester) async {
      expect(
        await pumpAndRead(tester, includeBackground: false, isIOS: false),
        equals(<String>[title, why, how, sharing, notNow, agree]),
      );
    });

    testWidgets('background scope on Android adds the Play sentence and the '
        'off-switch line', (tester) async {
      expect(
        await pumpAndRead(tester, includeBackground: true, isIOS: false),
        equals(<String>[
          title,
          why,
          how,
          sharing,
          backgroundAndroid,
          manage,
          notNow,
          agree,
        ]),
      );
    });

    testWidgets('background scope on iOS states the limit instead',
        (tester) async {
      expect(
        await pumpAndRead(tester, includeBackground: true, isIOS: true),
        equals(<String>[
          title,
          why,
          how,
          sharing,
          backgroundIos,
          manage,
          notNow,
          agree,
        ]),
      );
    });
  });
}
