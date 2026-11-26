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
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/constants/location.dart';
import 'package:haven/src/providers/location_disclosure_provider.dart';
import 'package:haven/src/services/android_background_location.dart';
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
        // The disclosure dialog reads its copy through AppLocalizations since
        // the strings moved out of hard-coded Dart, so the harness must supply
        // the delegates the app supplies.
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
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

    testWidgets(
      'persists the acceptance BEFORE it publishes it in memory',
      (tester) async {
        // THE ORDERING ANOTHER READER DEPENDS ON.
        //
        // `LocationAccessNotifier._disclosureAccepted` gates the whole
        // location-access banner and consults SharedPreferences and nothing
        // else. It used to read this controller's in-memory state first, with
        // a doc claiming that closed a race — but the race cannot happen in
        // this direction: prefs is written and awaited before `state` is
        // touched, and the only other write path (`_syncFromPrefs`) derives
        // memory FROM prefs. So in-memory-true always implied prefs-true, the
        // extra read was unreachable as load-bearing, and deleting it changed
        // nothing. It is gone.
        //
        // Which makes THIS the invariant to pin. If someone later reorders
        // `ensureDisclosed` to publish in memory first and persist afterwards,
        // the deleted read would silently become load-bearing again and a
        // probe landing in that window would misread a consenting user as
        // un-disclosed — staying quiet through a real outage. Asserting the
        // two flags at the end could not catch that; both are true by then.
        // So the pref is sampled AT the moment the state changes.
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();

        bool? prefAtPublish;
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final controller = container.read(
          locationDisclosureControllerProvider.notifier,
        );
        // Fires synchronously on every `state = ...`, so it observes the
        // ordering rather than the outcome.
        controller.addListener((state) {
          if (state.foregroundAccepted) {
            prefAtPublish ??= prefs.getBool(kLocationDisclosureAcceptedKey);
          }
        });

        final result = ValueNotifier<bool?>(null);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(
                body: Consumer(
                  builder: (context, ref, _) => ElevatedButton(
                    onPressed: () async {
                      result.value = await ref
                          .read(locationDisclosureControllerProvider.notifier)
                          .ensureDisclosed(context, includeBackground: false);
                    },
                    child: const Text('Trigger'),
                  ),
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.text('Trigger'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(WidgetKeys.locationDisclosureAgree));
        await tester.pumpAndSettle();

        expect(result.value, isTrue);
        expect(
          prefAtPublish,
          isTrue,
          reason: 'The persisted flag must already be set the instant the '
              'in-memory state says accepted. Everything that reads consent '
              'from prefs alone — the location-access banner\'s gate, the '
              'publishers — depends on prefs never being behind memory.',
        );
      },
    );
  });

  group('versioned background consent (OD-R3)', () {
    test('backgroundResumeDisclosureAccepted needs both disclosures at the '
        'current version; anything missing is a refusal', () {
      bool accepted(bool? fg, bool? bg, int? version) =>
          backgroundResumeDisclosureAccepted(
            foregroundAccepted: fg,
            backgroundAccepted: bg,
            acceptedVersion: version,
          );
      expect(accepted(null, null, null), isFalse);
      expect(accepted(true, true, null), isFalse, reason: 'v1 (no int)');
      expect(accepted(true, true, 1), isFalse);
      expect(accepted(true, true, kBackgroundDisclosureVersion), isTrue);
      expect(accepted(true, true, kBackgroundDisclosureVersion + 1), isTrue);
      expect(accepted(false, true, kBackgroundDisclosureVersion), isFalse);
      expect(accepted(true, false, kBackgroundDisclosureVersion), isFalse);
      expect(accepted(null, true, kBackgroundDisclosureVersion), isFalse);
    });

    testWidgets('accepting the background disclosure records the current '
        'version and the prompted version', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final result = ValueNotifier<bool?>(null);
      await tester.pumpWidget(
        buildHost(includeBackground: true, result: result),
      );
      await tester.tap(find.text('Trigger'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(WidgetKeys.locationDisclosureAgree));
      await tester.pumpAndSettle();

      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getInt(kLocationDisclosureBackgroundVersionKey),
        kBackgroundDisclosureVersion,
      );
      expect(
        prefs.getInt(kLocationDisclosureBackgroundPromptedVersionKey),
        kBackgroundDisclosureVersion,
      );
      expect(backgroundResumeDisclosureAcceptedIn(prefs), isTrue);
    });

    testWidgets('an older background acceptance re-shows the dialog when '
        'background sharing is turned on again', (tester) async {
      SharedPreferences.setMockInitialValues({
        kLocationDisclosureAcceptedKey: true,
        kLocationDisclosureBackgroundAcceptedKey: true,
      });
      final result = ValueNotifier<bool?>(null);
      await tester.pumpWidget(
        buildHost(includeBackground: true, result: result),
      );
      await tester.tap(find.text('Trigger'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(WidgetKeys.locationDisclosureAgree),
        findsOneWidget,
        reason: 'a v1 acceptance passed as consent to the v2 text',
      );
      await tester.tap(find.byKey(WidgetKeys.locationDisclosureAgree));
      await tester.pumpAndSettle();
      final prefs = await SharedPreferences.getInstance();
      expect(backgroundResumeDisclosureAcceptedIn(prefs), isTrue);
    });

    testWidgets('a current background acceptance is not asked again', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        kLocationDisclosureAcceptedKey: true,
        kLocationDisclosureBackgroundAcceptedKey: true,
        kLocationDisclosureBackgroundVersionKey: kBackgroundDisclosureVersion,
      });
      final result = ValueNotifier<bool?>(null);
      await tester.pumpWidget(
        buildHost(includeBackground: true, result: result),
      );
      await tester.tap(find.text('Trigger'));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(WidgetKeys.locationDisclosureAgree), findsNothing);
      expect(result.value, isTrue);
    });
  });

  group('reconfirmBackgroundIfOwed', () {
    const updateLeadFragment = 'Background sharing has changed since you';
    final v1SharingOn = <String, Object>{
      kBackgroundSharingKey: true,
      kLocationDisclosureAcceptedKey: true,
      kLocationDisclosureBackgroundAcceptedKey: true,
    };

    Widget host(ValueNotifier<bool?> result, {bool force = false}) =>
        ProviderScope(
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: Consumer(
                builder: (context, ref, _) => ElevatedButton(
                  onPressed: () async {
                    result.value = await ref
                        .read(locationDisclosureControllerProvider.notifier)
                        .reconfirmBackgroundIfOwed(context, force: force);
                  },
                  child: const Text('Trigger'),
                ),
              ),
            ),
          ),
        );

    Future<void> trigger(WidgetTester tester) async {
      await tester.tap(find.text('Trigger'));
      await tester.pumpAndSettle();
    }

    testWidgets('shows the updated disclosure once to a sharing user with an '
        'older acceptance; Not now records only that it was shown', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues(v1SharingOn);
      final result = ValueNotifier<bool?>(null);
      await tester.pumpWidget(host(result));
      await trigger(tester);
      expect(find.textContaining(updateLeadFragment), findsOneWidget);

      await tester.tap(find.byKey(WidgetKeys.locationDisclosureNotNow));
      await tester.pumpAndSettle();
      expect(result.value, isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getInt(kLocationDisclosureBackgroundPromptedVersionKey),
        kBackgroundDisclosureVersion,
      );
      expect(prefs.getInt(kLocationDisclosureBackgroundVersionKey), isNull);
      expect(
        prefs.getBool(kBackgroundSharingKey),
        isTrue,
        reason: '"Not now" is not an opt-out of background sharing',
      );
      expect(prefs.getBool(kLocationDisclosureBackgroundAcceptedKey), isTrue);

      result.value = true;
      await trigger(tester);
      expect(find.byKey(WidgetKeys.locationDisclosureAgree), findsNothing);
      expect(result.value, isNull, reason: 'asked twice');
    });

    testWidgets('Agree records the current version', (tester) async {
      SharedPreferences.setMockInitialValues(v1SharingOn);
      final result = ValueNotifier<bool?>(null);
      await tester.pumpWidget(host(result));
      await trigger(tester);
      await tester.tap(find.byKey(WidgetKeys.locationDisclosureAgree));
      await tester.pumpAndSettle();

      expect(result.value, isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(backgroundResumeDisclosureAcceptedIn(prefs), isTrue);
    });

    for (final (label, seed) in <(String, Map<String, Object>)>[
      ('sharing off', {...v1SharingOn, kBackgroundSharingKey: false}),
      (
        'a current acceptance',
        {
          ...v1SharingOn,
          kLocationDisclosureBackgroundVersionKey: kBackgroundDisclosureVersion,
        },
      ),
      (
        'already shown',
        {
          ...v1SharingOn,
          kLocationDisclosureBackgroundPromptedVersionKey:
              kBackgroundDisclosureVersion,
        },
      ),
    ]) {
      testWidgets('is not owed with $label', (tester) async {
        SharedPreferences.setMockInitialValues(seed);
        final result = ValueNotifier<bool?>(true);
        await tester.pumpWidget(host(result));
        await trigger(tester);
        expect(find.byKey(WidgetKeys.locationDisclosureAgree), findsNothing);
        expect(result.value, isNull);
      });
    }

    testWidgets('force re-asks a user who already chose Not now (the '
        'settings advisory)', (tester) async {
      SharedPreferences.setMockInitialValues({
        ...v1SharingOn,
        kLocationDisclosureBackgroundPromptedVersionKey:
            kBackgroundDisclosureVersion,
      });
      final result = ValueNotifier<bool?>(null);
      await tester.pumpWidget(host(result, force: true));
      await trigger(tester);
      expect(find.textContaining(updateLeadFragment), findsOneWidget);
    });
  });

  group('the foreground consent step (R-3)', () {
    const missing = BackgroundLocationStatus(
      required: true,
      granted: false,
      optionLabel: 'Allow all the time',
    );
    const granted = BackgroundLocationStatus(required: true, granted: true);

    ForegroundConsentStep due({
      bool sharingOn = true,
      int version = 1,
      int prompted = 0,
      BackgroundLocationStatus allTime = missing,
      bool allTimePrompted = false,
    }) => foregroundConsentStepDue(
      sharingOn: sharingOn,
      backgroundAccepted: true,
      acceptedVersion: version,
      promptedVersion: prompted,
      allTime: allTime,
      allTimePrompted: allTimePrompted,
    );

    const v2 = kBackgroundDisclosureVersion;

    test('the re-confirm wins, carrying the all-time step where it is '
        'missing; the all-time step alone only at the current version', () {
      expect(due(), ForegroundConsentStep.reconfirmWithAllTime);
      expect(due(allTime: granted), ForegroundConsentStep.reconfirm);
      expect(
        due(allTime: BackgroundLocationStatus.notRequired),
        ForegroundConsentStep.reconfirm,
      );
      expect(
        due(prompted: v2),
        ForegroundConsentStep.none,
        reason: 'an older acceptance is never asked for "all the time"',
      );
      expect(due(version: v2), ForegroundConsentStep.allTime);
      expect(due(version: v2, allTimePrompted: true), ForegroundConsentStep.none);
      expect(due(version: v2, allTime: granted), ForegroundConsentStep.none);
      expect(due(sharingOn: false), ForegroundConsentStep.none);
    });

    late _FakeAllTime allTime;
    late List<bool> inFrontAnswers;

    Widget host(ValueNotifier<bool?> result) => ProviderScope(
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => ElevatedButton(
              onPressed: () async {
                result.value = await ref
                    .read(locationDisclosureControllerProvider.notifier)
                    .runForegroundConsentStep(
                      context,
                      allTime: allTime,
                      inFront: () {
                        inFrontAnswers.add(true);
                        return true;
                      },
                    );
              },
              child: const Text('Step'),
            ),
          ),
        ),
      ),
    );

    Future<void> step(WidgetTester tester) async {
      await tester.tap(find.text('Step'));
      await tester.pumpAndSettle();
    }

    const leadFragment = 'Background sharing has changed since you';
    const stepFragment = 'Next, Android opens';

    setUp(() => inFrontAnswers = []);

    testWidgets('Android 11+ with an older acceptance: ONE dialog, carrying '
        'the all-time step; Agree records v2, then requests', (tester) async {
      SharedPreferences.setMockInitialValues({
        kBackgroundSharingKey: true,
        kLocationDisclosureAcceptedKey: true,
        kLocationDisclosureBackgroundAcceptedKey: true,
      });
      allTime = _FakeAllTime(missing, grantOnRequest: true);
      final result = ValueNotifier<bool?>(null);
      await tester.pumpWidget(host(result));
      await step(tester);

      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.textContaining(leadFragment), findsOneWidget);
      expect(find.textContaining(stepFragment), findsOneWidget);
      await tester.tap(find.byKey(WidgetKeys.locationDisclosureAgree));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing, reason: 'a 2nd dialog');
      expect(allTime.requests, 1);
      final prefs = await SharedPreferences.getInstance();
      expect(backgroundResumeDisclosureAcceptedIn(prefs), isTrue);
      expect(prefs.getBool(kAndroidBackgroundLocationPromptedKey), isTrue);

      await step(tester);
      expect(find.byType(AlertDialog), findsNothing, reason: 'asked again');
    });

    testWidgets('Not now on the combined dialog requests nothing, and nothing '
        'is asked again', (tester) async {
      SharedPreferences.setMockInitialValues({
        kBackgroundSharingKey: true,
        kLocationDisclosureAcceptedKey: true,
        kLocationDisclosureBackgroundAcceptedKey: true,
      });
      allTime = _FakeAllTime(missing);
      final result = ValueNotifier<bool?>(null);
      await tester.pumpWidget(host(result));
      await step(tester);
      await tester.tap(find.byKey(WidgetKeys.locationDisclosureNotNow));
      await tester.pumpAndSettle();
      expect(allTime.requests, 0);

      await step(tester);
      expect(find.byType(AlertDialog), findsNothing, reason: 're-nagged');
    });

    testWidgets('at the current version the all-time step alone is shown, '
        'once, without the update lead', (tester) async {
      SharedPreferences.setMockInitialValues({
        kBackgroundSharingKey: true,
        kLocationDisclosureAcceptedKey: true,
        kLocationDisclosureBackgroundAcceptedKey: true,
        kLocationDisclosureBackgroundVersionKey: v2,
      });
      allTime = _FakeAllTime(missing);
      final result = ValueNotifier<bool?>(null);
      await tester.pumpWidget(host(result));
      await step(tester);
      expect(find.textContaining(stepFragment), findsOneWidget);
      expect(find.textContaining(leadFragment), findsNothing);
      await tester.tap(find.byKey(WidgetKeys.locationDisclosureNotNow));
      await tester.pumpAndSettle();
      expect(allTime.requests, 0);

      await step(tester);
      expect(find.byType(AlertDialog), findsNothing, reason: 're-nagged');
    });

    testWidgets('when Android no longer shows its page, Agree opens app '
        'settings instead of doing nothing', (tester) async {
      SharedPreferences.setMockInitialValues({
        kBackgroundSharingKey: true,
        kLocationDisclosureAcceptedKey: true,
        kLocationDisclosureBackgroundAcceptedKey: true,
        kLocationDisclosureBackgroundVersionKey: v2,
      });
      allTime = _FakeAllTime(missing, shows: false);
      final result = ValueNotifier<bool?>(null);
      await tester.pumpWidget(host(result));
      await step(tester);
      await tester.tap(find.byKey(WidgetKeys.locationDisclosureAgree));
      await tester.pumpAndSettle();
      expect(allTime.requests, 1);
      expect(allTime.settingsOpened, 1);
    });

    testWidgets('nothing is owed: no dialog and no permission read is shown', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        kBackgroundSharingKey: true,
        kLocationDisclosureAcceptedKey: true,
        kLocationDisclosureBackgroundAcceptedKey: true,
        kLocationDisclosureBackgroundVersionKey: v2,
      });
      allTime = _FakeAllTime(granted);
      final result = ValueNotifier<bool?>(null);
      await tester.pumpWidget(host(result));
      await step(tester);
      expect(find.byType(AlertDialog), findsNothing);
      expect(result.value, isTrue);
      expect(inFrontAnswers, isEmpty, reason: 'nothing to show, nothing read');
    });

    testWidgets('an app that left the front shows nothing and owes the step',
        (tester) async {
      SharedPreferences.setMockInitialValues({
        kBackgroundSharingKey: true,
        kLocationDisclosureAcceptedKey: true,
        kLocationDisclosureBackgroundAcceptedKey: true,
      });
      allTime = _FakeAllTime(missing);
      final result = ValueNotifier<bool?>(null);
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: Consumer(
                builder: (context, ref, _) => ElevatedButton(
                  onPressed: () async {
                    result.value = await ref
                        .read(locationDisclosureControllerProvider.notifier)
                        .runForegroundConsentStep(
                          context,
                          allTime: allTime,
                          inFront: () => false,
                        );
                  },
                  child: const Text('Step'),
                ),
              ),
            ),
          ),
        ),
      );
      await step(tester);
      expect(find.byType(AlertDialog), findsNothing);
      expect(result.value, isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getInt(kLocationDisclosureBackgroundPromptedVersionKey),
        isNull,
        reason: 'recorded as shown though nothing was',
      );
    });
  });
}

/// A background-location permission the test drives.
class _FakeAllTime implements AndroidBackgroundLocation {
  _FakeAllTime(this.current, {this.grantOnRequest = false, this.shows = true});

  BackgroundLocationStatus current;
  final bool grantOnRequest;
  final bool shows;
  int requests = 0;
  int settingsOpened = 0;

  @override
  Future<BackgroundLocationStatus> status() async => current;

  @override
  Future<bool> request() async {
    requests++;
    if (grantOnRequest) {
      current = const BackgroundLocationStatus(required: true, granted: true);
    }
    return shows;
  }

  @override
  Future<void> openAppSettings() async => settingsOpened++;
}
