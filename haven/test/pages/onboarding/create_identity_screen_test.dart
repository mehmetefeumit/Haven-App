/// Widget tests for [CreateIdentityScreen] — the merged create-identity +
/// display-name screen (page 2 of 2).
///
/// Covers the full "Create My Identity" sequence: create keypair (idempotent
/// on resume), publish the public profile, run the location prominent
/// disclosure, and complete onboarding — plus the pre-filled anonymous name,
/// the empty-name fallback, and the existing-name preservation on resume.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/constants/location.dart';
import 'package:haven/src/pages/onboarding/create_identity_screen.dart';
import 'package:haven/src/pages/onboarding/import_nsec_screen.dart';
import 'package:haven/src/pages/settings/relay_settings_page.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/location_disclosure_provider.dart';
import 'package:haven/src/providers/onboarding_provider.dart';
import 'package:haven/src/providers/relay_preferences_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/providers/storage_reset_notice_provider.dart';
import 'package:haven/src/services/android_background_location.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/services/location_service.dart';
import 'package:haven/src/services/maintenance_service.dart';
import 'package:haven/src/services/profile_service.dart';
import 'package:haven/src/services/relay_service.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/widgets/common/storage_reset_notice_dialog.dart';
import 'package:haven/src/widgets/identity/avatar.dart';
import 'package:haven/src/widgets/identity/public_profile_notice.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/localized_app_harness.dart';
import '../../helpers/log_capture.dart';
import '../../mocks/mock_circle_service.dart';
import '../../mocks/mock_profile_service.dart';
import '../../mocks/mock_relay_preferences_service.dart';
import '../../mocks/mock_relay_service.dart';

final _namePattern = RegExp(r'^[A-Z][a-z]+ [A-Z][a-z]+$');

/// `onboardingDisplayNameError`, in English.
const _nameNotSaved = 'Couldn’t save that name. Please try again.';

/// Every name onboarding saved, in order: the own profile row is the save.
List<Object?> _savedNames(MockProfileService profile) => [
  for (final call in profile.methodCalls)
    if (call.method == 'updateOwnProfile') call.args['displayName'],
];

/// `onboardingPhotoNotSaved`, in English.
const _photoNotSaved =
    'Your photo couldn’t be saved. You can add it later in Settings, under '
    'Identity.';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // createIdentity runs the M10.1 pending-wipe reconcile, which reads
  // SharedPreferences; an empty store means "no wipe pending".
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  List<Override> buildOverrides({
    required _RecordingIdentityService service,
    MockProfileService? profileService,
    _FakeLocationService? locationService,
    _FakeMaintenance? maintenance,
    MockRelayPreferencesService? relayPrefs,
    MockCircleService? circles,
    bool resetNoticeOwed = false,
    AndroidBackgroundLocation? allTime,
  }) {
    final prefs = relayPrefs ?? MockRelayPreferencesService();
    return [
      storageResetNoticeProvider.overrideWith((ref) => resetNoticeOwed),
      identityServiceProvider.overrideWithValue(service),
      onboardingControllerProvider.overrideWith(
        (ref) => OnboardingController(
          const OnboardingFlags(introSeen: true, completed: false),
        ),
      ),
      circleServiceProvider.overrideWithValue(circles ?? MockCircleService()),
      relayServiceProvider.overrideWithValue(MockRelayService()),
      profileServiceProvider.overrideWithValue(
        profileService ?? MockProfileService(),
      ),
      relayPreferencesServiceProvider.overrideWith((ref) async => prefs),
      locationServiceProvider.overrideWithValue(
        locationService ?? _FakeLocationService(),
      ),
      maintenanceServiceProvider.overrideWithValue(
        maintenance ?? _FakeMaintenance(prefs),
      ),
      if (allTime != null)
        androidBackgroundLocationProvider.overrideWithValue(allTime),
    ];
  }

  // The success path leaves the CTA spinner running forever (production swaps
  // the screen away), so pumpAndSettle can't be used after a tap.
  Future<void> pumpFrames(WidgetTester tester, [int frames = 16]) async {
    for (var i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  String prefilledName(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField)).controller!.text;

  testWidgets('renders title, disclosure, field, and CTA', (tester) async {
    await pumpLocalized(
      tester,
      const CreateIdentityScreen(),
      overrides: buildOverrides(service: _RecordingIdentityService()),
    );

    expect(find.text('Create your identity'), findsOneWidget);
    // The public-profile disclosure must be present since publishing is
    // now mandatory and unskippable.
    expect(find.byType(PublicProfileNotice), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.byKey(WidgetKeys.createIdentityCta), findsOneWidget);
    expect(find.text('Create My Identity'), findsOneWidget);
  });

  testWidgets('photo and name field match the Identity page', (tester) async {
    await pumpLocalized(
      tester,
      const CreateIdentityScreen(),
      overrides: buildOverrides(service: _RecordingIdentityService()),
    );

    // IdentityPhotoHeader's avatar is HavenAvatarSize.xlarge (96dp) and
    // DisplayNameCard is a Card around a dense outlined field labelled once.
    expect(tester.getSize(find.byType(HavenAvatar)), const Size(96, 96));
    expect(
      find.ancestor(of: find.byType(TextField), matching: find.byType(Card)),
      findsOneWidget,
    );
    final decoration = tester
        .widget<TextField>(find.byType(TextField))
        .decoration!;
    expect(decoration.isDense, isTrue);
    expect(decoration.border, isA<OutlineInputBorder>());
    expect(find.text('Display Name'), findsOneWidget);
  });

  testWidgets('the display-name field is pre-filled with an anonymous name', (
    tester,
  ) async {
    await pumpLocalized(
      tester,
      const CreateIdentityScreen(),
      overrides: buildOverrides(service: _RecordingIdentityService()),
    );

    expect(_namePattern.hasMatch(prefilledName(tester)), isTrue);
  });

  testWidgets('opts the display-name field out of IME personalized learning', (
    tester,
  ) async {
    await pumpLocalized(
      tester,
      const CreateIdentityScreen(),
      overrides: buildOverrides(service: _RecordingIdentityService()),
    );

    // Publishing this name to relays is the user's deliberate choice; the
    // keyboard's learned-word dictionary is a different recipient — an
    // OS-side store Haven cannot wipe on logout and that rides the device
    // backup and any third-party keyboard.
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.enableIMEPersonalizedLearning, isFalse);
  });

  testWidgets('offers the display-name field to no platform autofill service', (
    tester,
  ) async {
    await pumpLocalized(
      tester,
      const CreateIdentityScreen(),
      overrides: buildOverrides(service: _RecordingIdentityService()),
    );

    // This name is a generated pseudonym, not the user's legal name — an
    // autofill service has nothing to supply, yet the framework's default
    // empty hint list would still hand it the current editing value.
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.autofillHints, isNull);
  });

  testWidgets('does not expose the import-existing-key affordance', (
    tester,
  ) async {
    await pumpLocalized(
      tester,
      const CreateIdentityScreen(),
      overrides: buildOverrides(service: _RecordingIdentityService()),
    );

    expect(find.textContaining('Import it instead'), findsNothing);
    expect(find.byType(ImportNsecScreen), findsNothing);
  });

  testWidgets(
    'accepting: creates identity, publishes profile, enables background, '
    'and completes onboarding',
    (tester) async {
      final service = _RecordingIdentityService();
      final profile = MockProfileService();
      final location = _FakeLocationService();

      await pumpLocalized(
        tester,
        const CreateIdentityScreen(),
        overrides: buildOverrides(
          service: service,
          profileService: profile,
          locationService: location,
        ),
        settle: false,
      );
      await tester.pump();
      final name = prefilledName(tester);

      await tester.tap(find.byKey(WidgetKeys.createIdentityCta));
      await pumpFrames(tester);

      // Disclosure-before-collection: the pop-up shows and nothing is
      // requested until the user consents.
      expect(find.byKey(WidgetKeys.locationDisclosureAgree), findsOneWidget);
      expect(location.requestPermissionCalled, isFalse);

      await tester.tap(find.byKey(WidgetKeys.locationDisclosureAgree));
      await pumpFrames(tester);

      expect(service.createIdentityCalls, 1);
      expect(_savedNames(profile), [name]);
      expect(
        service.setDisplayNameCalls,
        isEmpty,
        reason: 'the own profile row is the save: a name held only on this '
            'device is one no relay gets',
      );
      expect(
        await ProviderScope.containerOf(
          tester.element(find.byType(CreateIdentityScreen)),
        ).read(displayNameProvider.future),
        name,
        reason: 'the saved name is the one every surface shows',
      );
      // The local save must also trigger the background publish.
      expect(
        profile.methodCalls.map((c) => c.method),
        contains('syncOwnProfile'),
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(kOnboardingCompletedKey), isTrue);
      expect(prefs.getBool(kBackgroundSharingKey), isTrue);
      expect(location.requestPermissionCalled, isTrue);
    },
  );

  testWidgets('a name already read as none before the save shows the saved '
      'one after it', (tester) async {
    final gate = Completer<void>();
    final profile = MockProfileService()..updateOwnProfileGate = gate;
    await pumpLocalized(
      tester,
      const CreateIdentityScreen(),
      overrides: buildOverrides(
        service: _RecordingIdentityService(),
        profileService: profile,
      ),
      settle: false,
    );
    await tester.pump();
    final name = prefilledName(tester);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(CreateIdentityScreen)),
    );
    final held = container.listen(displayNameProvider, (_, _) {});
    addTearDown(held.close);

    await tester.tap(find.byKey(WidgetKeys.createIdentityCta));
    await pumpFrames(tester);
    // The save is in flight and the new identity's name has been read: none.
    expect(_savedNames(profile), [name]);
    expect(container.read(displayNameProvider), const AsyncData<String?>(null));

    gate.complete();
    await pumpFrames(tester);

    expect(container.read(displayNameProvider).valueOrNull, name);
  });

  group('Android 11+ without "Allow all the time"', () {
    testWidgets('one disclosure carries the step; Agree asks foreground, then '
        'background, before sharing is enabled, and MapShell owes nothing', (
      tester,
    ) async {
      final allTime = _MissingAllTime();
      final location = _FakeLocationService();
      final order = <String>[];
      location.onRequest = () => order.add('foreground');
      allTime.onRequest = () async {
        final prefs = await SharedPreferences.getInstance();
        order.add(
          prefs.getBool(kBackgroundSharingKey) ?? false
              ? 'background, after enable'
              : 'background',
        );
      };

      await pumpLocalized(
        tester,
        const CreateIdentityScreen(),
        overrides: buildOverrides(
          service: _RecordingIdentityService(),
          locationService: location,
          allTime: allTime,
        ),
        settle: false,
      );
      await tester.pump();
      await tester.tap(find.byKey(WidgetKeys.createIdentityCta));
      await pumpFrames(tester);

      expect(
        find.textContaining('Next, on the screen Android opens'),
        findsOneWidget,
        reason: 'the request below must follow a disclosure that explains it',
      );
      expect(allTime.requests, 0, reason: 'a request before the disclosure');
      await tester.tap(find.byKey(WidgetKeys.locationDisclosureAgree));
      await pumpFrames(tester);

      expect(order, ['foreground', 'background']);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(kBackgroundSharingKey), isTrue);
      expect(prefs.getBool(kAndroidBackgroundLocationPromptedKey), isTrue);
      expect(
        foregroundConsentStepDue(
          sharingOn: true,
          backgroundAccepted:
              prefs.getBool(kLocationDisclosureBackgroundAcceptedKey) ?? false,
          acceptedVersion:
              prefs.getInt(kLocationDisclosureBackgroundVersionKey) ?? 1,
          promptedVersion:
              prefs.getInt(kLocationDisclosureBackgroundPromptedVersionKey) ??
              0,
          allTime: await allTime.status(),
          allTimePrompted:
              prefs.getBool(kAndroidBackgroundLocationPromptedKey) ?? false,
        ),
        ForegroundConsentStep.none,
        reason: 'MapShell would show the same long dialog a second time',
      );
    });

    testWidgets('a foreground refusal asks nothing more, and the step is not '
        'asked again', (tester) async {
      final allTime = _MissingAllTime();
      await pumpLocalized(
        tester,
        const CreateIdentityScreen(),
        overrides: buildOverrides(
          service: _RecordingIdentityService(),
          locationService: _FakeLocationService(grants: false),
          allTime: allTime,
        ),
        settle: false,
      );
      await tester.pump();
      await tester.tap(find.byKey(WidgetKeys.createIdentityCta));
      await pumpFrames(tester);
      await tester.tap(find.byKey(WidgetKeys.locationDisclosureAgree));
      await pumpFrames(tester);

      expect(allTime.requests, 0);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(kAndroidBackgroundLocationPromptedKey), isTrue);
    });

    testWidgets('a failed background request logs its type only and still '
        'enables sharing', (tester) async {
      // Rule 15: an exception's text may carry anything the platform put in
      // it; the line names the type alone.
      const planted = 'npub1plantedplantedplanted wss://planted.example';
      final allTime = _MissingAllTime()
        ..onRequest = () async => throw StateError(planted);
      // Restored inside the body: testWidgets checks debugPrint before
      // addTearDown callbacks run (see log_capture.dart).
      final logs = LogCapture();
      await pumpLocalized(
        tester,
        const CreateIdentityScreen(),
        overrides: buildOverrides(
          service: _RecordingIdentityService(),
          allTime: allTime,
        ),
        settle: false,
      );
      await tester.pump();
      await tester.tap(find.byKey(WidgetKeys.createIdentityCta));
      await pumpFrames(tester);
      await tester.tap(find.byKey(WidgetKeys.locationDisclosureAgree));
      await pumpFrames(tester);

      logs.restore();
      logs
        ..assertContains('Onboarding background location failed: StateError')
        ..assertNoNeedles(['npub1planted', 'planted.example']);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(kBackgroundSharingKey), isTrue);
    });

    testWidgets('a decline asks for nothing and records no step', (
      tester,
    ) async {
      final allTime = _MissingAllTime();
      await pumpLocalized(
        tester,
        const CreateIdentityScreen(),
        overrides: buildOverrides(
          service: _RecordingIdentityService(),
          allTime: allTime,
        ),
        settle: false,
      );
      await tester.pump();
      await tester.tap(find.byKey(WidgetKeys.createIdentityCta));
      await pumpFrames(tester);
      await tester.tap(find.byKey(WidgetKeys.locationDisclosureNotNow));
      await pumpFrames(tester);

      expect(allTime.requests, 0);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(kAndroidBackgroundLocationPromptedKey), isNull);
    });
  });

  testWidgets('an edited name is what gets saved and published', (tester) async {
    final profile = MockProfileService();

    await pumpLocalized(
      tester,
      const CreateIdentityScreen(),
      overrides: buildOverrides(
        service: _RecordingIdentityService(),
        profileService: profile,
      ),
      settle: false,
    );
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'Wren Willow');
    await tester.tap(find.byKey(WidgetKeys.createIdentityCta));
    await pumpFrames(tester);
    await tester.tap(find.byKey(WidgetKeys.locationDisclosureAgree));
    await pumpFrames(tester);

    expect(_savedNames(profile), ['Wren Willow']);
  });

  testWidgets('declining the disclosure still completes onboarding', (
    tester,
  ) async {
    final service = _RecordingIdentityService();
    final profile = MockProfileService();
    final location = _FakeLocationService();

    await pumpLocalized(
      tester,
      const CreateIdentityScreen(),
      overrides: buildOverrides(
        service: service,
        profileService: profile,
        locationService: location,
      ),
      settle: false,
    );
    await tester.pump();

    await tester.tap(find.byKey(WidgetKeys.createIdentityCta));
    await pumpFrames(tester);
    expect(find.byKey(WidgetKeys.locationDisclosureNotNow), findsOneWidget);
    await tester.tap(find.byKey(WidgetKeys.locationDisclosureNotNow));
    await pumpFrames(tester);

    final prefs = await SharedPreferences.getInstance();
    // Identity is still created + name saved, and onboarding completes...
    expect(service.createIdentityCalls, 1);
    expect(_savedNames(profile), hasLength(1));
    expect(prefs.getBool(kOnboardingCompletedKey), isTrue);
    // ...but nothing was requested or enabled.
    expect(prefs.getBool(kBackgroundSharingKey), isNot(true));
    expect(location.requestPermissionCalled, isFalse);
  });

  testWidgets('a cleared field falls back to a generated name (never empty)', (
    tester,
  ) async {
    final profile = MockProfileService();

    await pumpLocalized(
      tester,
      const CreateIdentityScreen(),
      overrides: buildOverrides(
        service: _RecordingIdentityService(),
        profileService: profile,
      ),
      settle: false,
    );
    await tester.pump();

    await tester.enterText(find.byType(TextField), '');
    await tester.tap(find.byKey(WidgetKeys.createIdentityCta));
    await pumpFrames(tester);
    await tester.tap(find.byKey(WidgetKeys.locationDisclosureAgree));
    await pumpFrames(tester);

    expect(_savedNames(profile), hasLength(1));
    final saved = _savedNames(profile).single! as String;
    expect(_namePattern.hasMatch(saved), isTrue, reason: 'saved: "$saved"');
  });

  testWidgets(
    'resume (identity already exists): does not re-create the keypair',
    (tester) async {
      final service = _RecordingIdentityService(hasIdentityValue: true);
      final profile = MockProfileService();

      await pumpLocalized(
        tester,
        const CreateIdentityScreen(),
        overrides: buildOverrides(service: service, profileService: profile),
        settle: false,
      );
      await tester.pump();

      await tester.tap(find.byKey(WidgetKeys.createIdentityCta));
      await pumpFrames(tester);
      await tester.tap(find.byKey(WidgetKeys.locationDisclosureAgree));
      await pumpFrames(tester);

      // The pre-existing identity is detected and never overwritten...
      expect(service.createIdentityCalls, 0);
      // ...but the rest of the sequence still runs.
      expect(_savedNames(profile), hasLength(1));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(kOnboardingCompletedKey), isTrue);
    },
  );

  testWidgets(
    'resume with an existing chosen name preserves it (no clobber)',
    (tester) async {
      final service = _RecordingIdentityService(
        hasIdentityValue: true,
        existingDisplayName: 'Alice',
      );
      final profile = MockProfileService();

      await pumpLocalized(
        tester,
        const CreateIdentityScreen(),
        overrides: buildOverrides(service: service, profileService: profile),
        settle: false,
      );
      // Let initState's async restore replace the random pre-fill with "Alice".
      await tester.pump();
      await tester.pump();
      expect(prefilledName(tester), 'Alice');

    await tester.tap(find.byKey(WidgetKeys.createIdentityCta));
    await pumpFrames(tester);
    await tester.tap(find.byKey(WidgetKeys.locationDisclosureAgree));
    await pumpFrames(tester);

      // The existing name is saved as-is — not overwritten by a fresh random.
      expect(_savedNames(profile), ['Alice']);
    },
  );

  testWidgets(
    'resume after the name was saved restores the one the profile row holds',
    (tester) async {
      // Killed after the save, before onboarding completed: the row holds the
      // name and nothing else does.
      final profile = MockProfileService(
        ownProfile: Profile(
          pubkeyHex: _RecordingIdentityService._identity.pubkeyHex,
          displayName: 'Wren Willow',
        ),
      );

      await pumpLocalized(
        tester,
        const CreateIdentityScreen(),
        overrides: buildOverrides(
          service: _RecordingIdentityService(hasIdentityValue: true),
          profileService: profile,
        ),
        settle: false,
      );
      await tester.pump();
      await tester.pump();
      expect(prefilledName(tester), 'Wren Willow');

      await tester.tap(find.byKey(WidgetKeys.createIdentityCta));
      await pumpFrames(tester);
      await tester.tap(find.byKey(WidgetKeys.locationDisclosureAgree));
      await pumpFrames(tester);

      expect(_savedNames(profile), ['Wren Willow']);
    },
  );

  testWidgets('a create failure surfaces a snackbar and does not complete', (
    tester,
  ) async {
    final service = _RecordingIdentityService(throwOnCreate: true);
    final profile = MockProfileService();

    await pumpLocalized(
      tester,
      const CreateIdentityScreen(),
      overrides: buildOverrides(service: service, profileService: profile),
      settle: false,
    );
    await tester.pump();

    await tester.tap(find.byKey(WidgetKeys.createIdentityCta));
    await pumpFrames(tester);

    expect(
      find.text(
        'Something went wrong creating your identity. Please try again.',
      ),
      findsOneWidget,
    );
    expect(service.createIdentityCalls, 1);
    // No disclosure, no name save, no completion.
    expect(find.byKey(WidgetKeys.locationDisclosureAgree), findsNothing);
    expect(service.setDisplayNameCalls, isEmpty);
    expect(_savedNames(profile), isEmpty);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(kOnboardingCompletedKey), isNot(true));
  });

  // ── Finishing setup (owner decision OD-C, 2026-11-12) ────────────────────
  //
  // The user enters only once others can invite them: a QR code shown before
  // the relay lists and KeyPackage are where an inviter looks is one nobody
  // can use.

  const setupError =
      "Couldn't finish setting up your account. Check your connection and "
      'try again.';

  Future<bool> onboardingCompleted() async =>
      (await SharedPreferences.getInstance()).getBool(
        kOnboardingCompletedKey,
      ) ??
      false;

  testWidgets(
    'seeds the default relays before anything is published, and publishes '
    'the relay lists before the KeyPackage',
    (tester) async {
      final prefs = MockRelayPreferencesService();
      final maintenance = _FakeMaintenance(prefs);

      await pumpLocalized(
        tester,
        const CreateIdentityScreen(),
        overrides: buildOverrides(
          service: _RecordingIdentityService(),
          maintenance: maintenance,
          relayPrefs: prefs,
        ),
        settle: false,
      );
      await tester.pump();

      await tester.tap(find.byKey(WidgetKeys.createIdentityCta));
      await pumpFrames(tester);

      expect(
        maintenance.seededAtFirstPublish,
        isTrue,
        reason:
            'an unseeded relay list reads as empty: a publish before the '
            'seed does nothing, and the QR code is shown anyway',
      );
      expect(maintenance.calls, ['relayList', 'kp']);
    },
  );

  testWidgets(
    'waits on "Finishing setup…" and enters only once others can invite the '
    'user',
    (tester) async {
      final maintenance = _FakeMaintenance(MockRelayPreferencesService());
      final landed = Completer<KeyPackageMaintenanceOutcome>();
      maintenance.kpAnswers.add(() => landed.future);
      final semantics = tester.ensureSemantics();

      await pumpLocalized(
        tester,
        const CreateIdentityScreen(),
        overrides: buildOverrides(
          service: _RecordingIdentityService(),
          maintenance: maintenance,
        ),
        settle: false,
      );
      await tester.pump();

      await tester.tap(find.byKey(WidgetKeys.createIdentityCta));
      await pumpFrames(tester);

      expect(find.text('Finishing setup…'), findsOneWidget);
      expect(
        find.bySemanticsLabel('Finishing setup…'),
        findsOneWidget,
        reason: 'the wait is announced as progress, not just drawn',
      );
      expect(find.byKey(WidgetKeys.locationDisclosureAgree), findsNothing);
      expect(await onboardingCompleted(), isFalse);

      landed.complete(_published);
      await pumpFrames(tester);
      expect(find.byKey(WidgetKeys.locationDisclosureAgree), findsOneWidget);
      await tester.tap(find.byKey(WidgetKeys.locationDisclosureAgree));
      await pumpFrames(tester);

      expect(await onboardingCompleted(), isTrue);
      semantics.dispose();
    },
  );

  testWidgets(
    'a publish that never settles times out to a fixed error with Retry, '
    'which resumes without creating or saving anything again',
    (tester) async {
      // Restored inside the body: testWidgets checks debugPrint before
      // addTearDown callbacks run (see log_capture.dart).
      final logs = LogCapture();
      addTearDown(logs.restore);
      final service = _RecordingIdentityService();
      final profile = MockProfileService();
      final maintenance = _FakeMaintenance(MockRelayPreferencesService());
      maintenance.kpAnswers.add(
        () => Completer<KeyPackageMaintenanceOutcome>().future,
      );

      await pumpLocalized(
        tester,
        const CreateIdentityScreen(),
        overrides: buildOverrides(
          service: service,
          profileService: profile,
          maintenance: maintenance,
        ),
        settle: false,
      );
      await tester.pump();

      await tester.tap(find.byKey(WidgetKeys.createIdentityCta));
      await pumpFrames(tester);
      expect(find.text(setupError), findsNothing, reason: 'still waiting');

      await tester.pump(const Duration(seconds: 60));
      await pumpFrames(tester);

      expect(find.text(setupError), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(find.byKey(WidgetKeys.locationDisclosureAgree), findsNothing);
      expect(await onboardingCompleted(), isFalse);
      expect(
        tester.widget<TextField>(find.byType(TextField)).enabled,
        isFalse,
        reason: 'the name is saved; an edit here would be silently dropped',
      );
      logs.assertContains('[Onboarding] finishing setup timed out');

      // The relays come back.
      await tester.tap(find.byKey(WidgetKeys.createIdentityCta));
      await pumpFrames(tester);
      await tester.tap(find.byKey(WidgetKeys.locationDisclosureAgree));
      await pumpFrames(tester);

      expect(await onboardingCompleted(), isTrue);
      expect(service.createIdentityCalls, 1);
      expect(_savedNames(profile), hasLength(1));
      expect(maintenance.calls, ['relayList', 'kp', 'relayList', 'kp']);
      logs.restore();
    },
  );

  testWidgets(
    'a proven failure shows the error at once, not after the full wait',
    (tester) async {
      final maintenance = _FakeMaintenance(MockRelayPreferencesService());
      maintenance.kpAnswers.add(
        () async => const KeyPackageMaintenanceFailed(
          KeyPackageFailureKind.publishNotAcked,
        ),
      );

      await pumpLocalized(
        tester,
        const CreateIdentityScreen(),
        overrides: buildOverrides(
          service: _RecordingIdentityService(),
          maintenance: maintenance,
        ),
        settle: false,
      );
      await tester.pump();

      await tester.tap(find.byKey(WidgetKeys.createIdentityCta));
      // Well inside the 60 s wait.
      await pumpFrames(tester);

      expect(find.text(setupError), findsOneWidget);
      expect(find.byKey(WidgetKeys.locationDisclosureAgree), findsNothing);

      await tester.tap(find.byKey(WidgetKeys.createIdentityCta));
      await pumpFrames(tester);
      expect(find.byKey(WidgetKeys.locationDisclosureAgree), findsOneWidget);
    },
  );

  testWidgets(
    'a publisher that throws shows fixed copy only and logs no identifier',
    (tester) async {
      // Restored inside the body: testWidgets checks debugPrint before
      // addTearDown callbacks run (see log_capture.dart).
      final logs = LogCapture();
      addTearDown(logs.restore);
      final maintenance = _FakeMaintenance(MockRelayPreferencesService())
        ..relayListThrows = StateError(
          'npub1plantedplanted at wss://planted.example',
        );

      await pumpLocalized(
        tester,
        const CreateIdentityScreen(),
        overrides: buildOverrides(
          service: _RecordingIdentityService(),
          maintenance: maintenance,
        ),
        settle: false,
      );
      await tester.pump();

      await tester.tap(find.byKey(WidgetKeys.createIdentityCta));
      await pumpFrames(tester);

      expect(find.text(setupError), findsOneWidget);
      expect(find.textContaining('planted'), findsNothing);
      expect(find.textContaining('StateError'), findsNothing);
      logs
        ..assertContains('[Reachability] republish failed')
        ..assertNoNeedles(['npub1plantedplanted', 'wss://planted.example'])
        ..restore();
    },
  );

  // ── The storage-reset notice during onboarding ──────────────────────────
  //
  // The core publishes nothing until the notice is answered, and MapShell,
  // which otherwise shows it, comes only after this screen: a user who owes
  // it must be able to answer it here, or Retry can never succeed.

  bool resetNoticeStillOwed(WidgetTester tester) => ProviderScope.containerOf(
    tester.element(find.byType(CreateIdentityScreen)),
  ).read(storageResetNoticeProvider);

  testWidgets(
    'an owed notice is answered before anything is published, then the user '
    'enters, and the map is not shown it again',
    (tester) async {
      final circles = _ResetCircles();
      final maintenance = _FakeMaintenance(MockRelayPreferencesService())
        ..held = () => !circles.acknowledged;

      await pumpLocalized(
        tester,
        const CreateIdentityScreen(),
        overrides: buildOverrides(
          service: _RecordingIdentityService(),
          maintenance: maintenance,
          circles: circles,
          resetNoticeOwed: true,
        ),
        settle: false,
      );
      await tester.pump();

      await tester.tap(find.byKey(WidgetKeys.createIdentityCta));
      await pumpFrames(tester);

      expect(find.byType(StorageResetNoticeDialog), findsOneWidget);
      expect(maintenance.calls, isEmpty, reason: 'it would be held anyway');

      await tester.tap(find.byKey(WidgetKeys.storageResetContinue));
      await pumpFrames(tester);

      expect(circles.acknowledged, isTrue);
      expect(maintenance.calls, ['relayList', 'kp'], reason: 'one publish');
      expect(find.text(setupError), findsNothing);
      await tester.tap(find.byKey(WidgetKeys.locationDisclosureAgree));
      await pumpFrames(tester);

      expect(await onboardingCompleted(), isTrue);
      expect(
        resetNoticeStillOwed(tester),
        isFalse,
        reason: 'answered here, so MapShell does not ask again',
      );
    },
  );

  testWidgets(
    'Relay settings from the notice: nothing is acknowledged or published '
    'until the user comes back',
    (tester) async {
      final circles = _ResetCircles();
      final maintenance = _FakeMaintenance(MockRelayPreferencesService())
        ..held = () => !circles.acknowledged;

      await pumpLocalized(
        tester,
        const CreateIdentityScreen(),
        overrides: buildOverrides(
          service: _RecordingIdentityService(),
          maintenance: maintenance,
          circles: circles,
          resetNoticeOwed: true,
        ),
        settle: false,
      );
      await tester.pump();

      await tester.tap(find.byKey(WidgetKeys.createIdentityCta));
      await pumpFrames(tester);
      await tester.tap(find.byKey(WidgetKeys.storageResetOpenRelaySettings));
      await pumpFrames(tester);

      expect(find.byType(RelaySettingsPage), findsOneWidget);
      expect(circles.acknowledged, isFalse);
      expect(maintenance.calls, isEmpty);

      await tester.pageBack();
      await pumpFrames(tester);

      expect(circles.acknowledged, isTrue);
      expect(maintenance.calls, ['relayList', 'kp']);
      await tester.tap(find.byKey(WidgetKeys.locationDisclosureAgree));
      await pumpFrames(tester);
      expect(await onboardingCompleted(), isTrue);
    },
  );

  testWidgets(
    'a publish held for a notice no launch flag announced shows the notice, '
    'not the connection error, and then enters',
    (tester) async {
      final circles = _ResetCircles();
      final maintenance = _FakeMaintenance(MockRelayPreferencesService())
        ..held = () => !circles.acknowledged;

      await pumpLocalized(
        tester,
        const CreateIdentityScreen(),
        overrides: buildOverrides(
          service: _RecordingIdentityService(),
          maintenance: maintenance,
          circles: circles,
        ),
        settle: false,
      );
      await tester.pump();

      await tester.tap(find.byKey(WidgetKeys.createIdentityCta));
      await pumpFrames(tester);

      expect(find.byType(StorageResetNoticeDialog), findsOneWidget);
      expect(find.text(setupError), findsNothing);

      await tester.tap(find.byKey(WidgetKeys.storageResetContinue));
      await pumpFrames(tester);
      await tester.tap(find.byKey(WidgetKeys.locationDisclosureAgree));
      await pumpFrames(tester);

      expect(await onboardingCompleted(), isTrue);
      expect(maintenance.calls, ['relayList', 'kp', 'relayList', 'kp']);
    },
  );

  testWidgets('an answer that is not saved publishes nothing and blames no '
      'connection; Retry asks again, and Try Again alone releases it', (
    tester,
  ) async {
    final circles = _ResetCircles()
      ..shouldThrowOnAcknowledgeStorageReset = true;
    final maintenance = _FakeMaintenance(MockRelayPreferencesService())
      ..held = () => !circles.acknowledged;

    await pumpLocalized(
      tester,
      const CreateIdentityScreen(),
      overrides: buildOverrides(
        service: _RecordingIdentityService(),
        maintenance: maintenance,
        circles: circles,
        resetNoticeOwed: true,
      ),
      settle: false,
    );
    await tester.pump();

    await tester.tap(find.byKey(WidgetKeys.createIdentityCta));
    await pumpFrames(tester);
    await tester.tap(find.byKey(WidgetKeys.storageResetContinue));
    await pumpFrames(tester);

    final l10n = l10nOf(tester, CreateIdentityScreen);
    expect(find.text(l10n.storageResetAcknowledgeFailed), findsOneWidget);
    expect(find.text(setupError), findsNothing);
    expect(find.text('Retry'), findsOneWidget);
    expect(maintenance.calls, isEmpty);
    expect(await onboardingCompleted(), isFalse);

    // Retry asks the notice again rather than publishing into the hold.
    await tester.tap(find.byIcon(Icons.close));
    await pumpFrames(tester);
    await tester.tap(find.byKey(WidgetKeys.createIdentityCta));
    await pumpFrames(tester);
    expect(find.byType(StorageResetNoticeDialog), findsOneWidget);
    await tester.tap(find.byKey(WidgetKeys.storageResetContinue));
    await pumpFrames(tester);
    expect(maintenance.calls, isEmpty);

    // The snackbar's Try Again saves it and starts the publish.
    circles.shouldThrowOnAcknowledgeStorageReset = false;
    await tester.tap(find.text(l10n.commonTryAgain));
    await pumpFrames(tester);
    expect(maintenance.calls, ['relayList', 'kp']);

    await tester.tap(find.byKey(WidgetKeys.createIdentityCta));
    await pumpFrames(tester);
    expect(find.byType(StorageResetNoticeDialog), findsNothing);
    await tester.tap(find.byKey(WidgetKeys.locationDisclosureAgree));
    await pumpFrames(tester);
    expect(await onboardingCompleted(), isTrue);
  });

  // ── Optional profile photo ────────────────────────────────────────────────

  testWidgets('shows the optional add-photo affordance, not a remove action', (
    tester,
  ) async {
    await pumpLocalized(
      tester,
      const CreateIdentityScreen(),
      overrides: buildOverrides(service: _RecordingIdentityService()),
    );

    // The avatar circle and the "optional" invitation are present; there is
    // nothing to remove yet.
    expect(find.byType(HavenAvatar), findsOneWidget);
    expect(find.text('Add a photo (optional)'), findsOneWidget);
    expect(find.text('Remove'), findsNothing);
  });

  testWidgets(
    'a picked photo is published AFTER the name, with the picked bytes, and '
    'onboarding completes',
    (tester) async {
      final service = _RecordingIdentityService();
      final profile = MockProfileService();
      final photoBytes = Uint8List.fromList([9, 8, 7, 6, 5]);

      await pumpLocalized(
        tester,
        CreateIdentityScreen(pickPhoto: (_) async => photoBytes),
        overrides: buildOverrides(service: service, profileService: profile),
        settle: false,
      );
      await tester.pump();

      // Pick a photo: tapping the avatar runs the injected pick+crop and holds
      // the bytes locally (nothing is published yet — no identity exists).
      await tester.tap(find.byType(HavenAvatar));
      await tester.pump();
      await tester.pump();
      expect(find.text('Remove'), findsOneWidget);
      expect(
        profile.methodCalls.map((c) => c.method),
        isNot(contains('setOwnAvatar')),
        reason: 'nothing is published until "Create My Identity" is tapped',
      );

      await tester.tap(find.byKey(WidgetKeys.createIdentityCta));
      await pumpFrames(tester);
      await tester.tap(find.byKey(WidgetKeys.locationDisclosureAgree));
      await pumpFrames(tester);

      final methods = profile.methodCalls.map((c) => c.method).toList();
      expect(methods, contains('updateOwnProfile'));
      expect(methods, contains('setOwnAvatar'));
      // The two kind-0 writes must not race: the name publishes first so the
      // avatar upload merges into a kind-0 that already carries the name.
      expect(
        methods.indexOf('updateOwnProfile') < methods.indexOf('setOwnAvatar'),
        isTrue,
        reason: 'the display name must publish before the avatar',
      );
      // The exact picked bytes reach the avatar upload.
      final avatarCall = profile.methodCalls.firstWhere(
        (c) => c.method == 'setOwnAvatar',
      );
      expect(avatarCall.args['raw'], photoBytes);
      expect(find.text(_photoNotSaved), findsNothing);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(kOnboardingCompletedKey), isTrue);
    },
  );

  testWidgets(
    'a picked photo that cannot be saved is reported in fixed copy, and '
    'onboarding still completes',
    (tester) async {
      final profile = MockProfileService();
      await pumpLocalized(
        tester,
        CreateIdentityScreen(pickPhoto: (_) async => Uint8List(3)),
        overrides: buildOverrides(
          service: _RecordingIdentityService(),
          profileService: profile,
        ),
        settle: false,
      );
      await tester.pump();
      final name = prefilledName(tester);
      // Rule 15: the user's own name, planted in the error the save throws.
      profile.setOwnAvatarError = StateError('no space for $name');
      // Restored inside the body: testWidgets checks that debugPrint is back
      // before addTearDown callbacks run.
      final log = LogCapture();
      try {
        await tester.tap(find.byType(HavenAvatar));
        await tester.pump();
        await tester.pump();
        await tester.tap(find.byKey(WidgetKeys.createIdentityCta));
        await pumpFrames(tester);
        await tester.tap(find.byKey(WidgetKeys.locationDisclosureAgree));
        await pumpFrames(tester);
      } finally {
        log.restore();
      }

      expect(
        find.text(_photoNotSaved),
        findsOneWidget,
        reason: 'a photo the user chose must not vanish silently',
      );
      expect(find.textContaining('no space'), findsNothing);
      log
        ..assertContains('[Onboarding] profile photo save failed: StateError')
        ..assertNoNeedles([name]);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(kOnboardingCompletedKey), isTrue);
    },
  );

  testWidgets('without a picked photo, no avatar is published', (tester) async {
    final service = _RecordingIdentityService();
    final profile = MockProfileService();

    await pumpLocalized(
      tester,
      const CreateIdentityScreen(),
      overrides: buildOverrides(service: service, profileService: profile),
      settle: false,
    );
    await tester.pump();

    await tester.tap(find.byKey(WidgetKeys.createIdentityCta));
    await pumpFrames(tester);
    await tester.tap(find.byKey(WidgetKeys.locationDisclosureAgree));
    await pumpFrames(tester);

    // The name is still published, but no avatar upload is attempted.
    expect(
      profile.methodCalls.map((c) => c.method),
      contains('updateOwnProfile'),
    );
    expect(
      profile.methodCalls.map((c) => c.method),
      isNot(contains('setOwnAvatar')),
    );
    expect(find.text(_photoNotSaved), findsNothing);
  });

  testWidgets('removing a picked photo publishes the profile without one', (
    tester,
  ) async {
    final service = _RecordingIdentityService();
    final profile = MockProfileService();
    final photoBytes = Uint8List.fromList([1, 2, 3]);

    await pumpLocalized(
      tester,
      CreateIdentityScreen(pickPhoto: (_) async => photoBytes),
      overrides: buildOverrides(service: service, profileService: profile),
      settle: false,
    );
    await tester.pump();

    await tester.tap(find.byType(HavenAvatar));
    await tester.pump();
    await tester.pump();
    expect(find.text('Remove'), findsOneWidget);

    // Clear it: the invitation returns and the photo is dropped.
    await tester.tap(find.text('Remove'));
    await tester.pump();
    expect(find.text('Add a photo (optional)'), findsOneWidget);
    expect(find.text('Remove'), findsNothing);

    await tester.tap(find.byKey(WidgetKeys.createIdentityCta));
    await pumpFrames(tester);
    await tester.tap(find.byKey(WidgetKeys.locationDisclosureAgree));
    await pumpFrames(tester);

    expect(
      profile.methodCalls.map((c) => c.method),
      isNot(contains('setOwnAvatar')),
    );
  });

  testWidgets('cancelling the picker leaves the state unchanged', (
    tester,
  ) async {
    await pumpLocalized(
      tester,
      CreateIdentityScreen(pickPhoto: (_) async => null),
      overrides: buildOverrides(service: _RecordingIdentityService()),
      settle: false,
    );
    await tester.pump();

    await tester.tap(find.byType(HavenAvatar));
    await tester.pump();
    await tester.pump();

    // Nothing was captured: the add-photo invitation is still shown, and there
    // is no Remove affordance.
    expect(find.text('Add a photo (optional)'), findsOneWidget);
    expect(find.text('Remove'), findsNothing);
  });

  testWidgets(
    'a name the profile row cannot take is not presented as saved: fixed '
    'copy, nothing saved or published, and a retry saves it',
    (tester) async {
      final service = _RecordingIdentityService();
      final profile = MockProfileService();
      final photoBytes = Uint8List.fromList([4, 2]);

      await pumpLocalized(
        tester,
        CreateIdentityScreen(pickPhoto: (_) async => photoBytes),
        overrides: buildOverrides(service: service, profileService: profile),
        settle: false,
      );
      await tester.pump();
      final name = prefilledName(tester);
      // Rule 15: the user's own name, planted in the error the save throws.
      profile.updateOwnProfileError = StateError('cannot store $name');
      final log = LogCapture();
      try {
        await tester.tap(find.byType(HavenAvatar));
        await tester.pump();
        await tester.pump();

        await tester.tap(find.byKey(WidgetKeys.createIdentityCta));
        await pumpFrames(tester);
      } finally {
        log.restore();
      }

      expect(find.text(_nameNotSaved), findsOneWidget);
      expect(find.textContaining('cannot store'), findsNothing);
      log
        ..assertContains('[Onboarding] profile name save failed: StateError')
        ..assertNoNeedles([name]);
      expect(
        service.setDisplayNameCalls,
        isEmpty,
        reason: 'a name held only on this device would never reach a relay',
      );
      expect(
        await ProviderScope.containerOf(
          tester.element(find.byType(CreateIdentityScreen)),
        ).read(displayNameProvider.future),
        isNull,
        reason: 'nothing may show a name that was not saved',
      );
      final methods = profile.methodCalls.map((c) => c.method);
      expect(methods, isNot(contains('setOwnAvatar')));
      expect(methods, isNot(contains('syncOwnProfile')));
      expect(find.byKey(WidgetKeys.locationDisclosureAgree), findsNothing);
      expect(await onboardingCompleted(), isFalse);
      expect(
        tester.widget<TextField>(find.byType(TextField)).enabled,
        isTrue,
        reason: 'the user stays here, free to try again',
      );

      // The store takes it on the next try.
      profile.updateOwnProfileError = null;
      tester
          .state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger))
          .removeCurrentSnackBar();
      await tester.pump();
      await tester.tap(find.byKey(WidgetKeys.createIdentityCta));
      await pumpFrames(tester);
      await tester.tap(find.byKey(WidgetKeys.locationDisclosureAgree));
      await pumpFrames(tester);

      expect(_savedNames(profile), [name, name]);
      expect(profile.ownProfile?.displayName, name);
      expect(profile.ownProfile?.pictureBytes, photoBytes);
      expect(profile.syncOwnProfileCalls, greaterThanOrEqualTo(1));
      expect(service.createIdentityCalls, 1);
      expect(await onboardingCompleted(), isTrue);
    },
  );

  testWidgets('does not scroll on a common phone viewport (390x844)', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await pumpLocalized(
      tester,
      const CreateIdentityScreen(),
      overrides: buildOverrides(service: _RecordingIdentityService()),
    );

    expect(tester.takeException(), isNull);
    final position = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position;
    expect(
      position.maxScrollExtent,
      0,
      reason:
          'CreateIdentityScreen must fit without scrolling on 390x844 in its '
          'resting (no-keyboard) state, even with the avatar picker present',
    );
  });

  testWidgets('does not scroll on 390x844 with a photo picked (taller state)', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final photoBytes = Uint8List.fromList([1, 2, 3, 4]);
    await pumpLocalized(
      tester,
      CreateIdentityScreen(pickPhoto: (_) async => photoBytes),
      overrides: buildOverrides(service: _RecordingIdentityService()),
      settle: false,
    );
    await tester.pump();
    await tester.tap(find.byType(HavenAvatar));
    await tester.pump();
    await tester.pump();
    expect(find.text('Remove'), findsOneWidget);

    final position = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position;
    expect(
      position.maxScrollExtent,
      0,
      reason:
          'the taller picked-photo state (with the Remove button) must also '
          'fit without scrolling on 390x844',
    );
  });
}

class _RecordingIdentityService implements IdentityService {
  _RecordingIdentityService({
    this.hasIdentityValue = false,
    this.existingDisplayName,
    this.throwOnCreate = false,
  });

  final bool hasIdentityValue;
  final String? existingDisplayName;
  final bool throwOnCreate;

  int createIdentityCalls = 0;
  final List<String?> setDisplayNameCalls = [];

  static final _identity = Identity(
    pubkeyHex:
        '1111111111111111111111111111111111111111111111111111111111111111',
    npub: 'npub1stub',
    createdAt: DateTime(2025),
  );

  @override
  Future<bool> hasIdentity() async =>
      hasIdentityValue || createIdentityCalls > 0;

  @override
  Future<Identity?> getIdentity() async =>
      (await hasIdentity()) ? _identity : null;

  @override
  Future<Identity> createIdentity() async {
    createIdentityCalls++;
    if (throwOnCreate) {
      throw const IdentityServiceException('boom');
    }
    return _identity;
  }

  @override
  Future<String?> getDisplayName() async => existingDisplayName;

  @override
  Future<void> setDisplayName(String? name) async {
    setDisplayNameCalls.add(name);
  }

  @override
  Future<Identity> importFromNsec(String nsec) async =>
      throw UnimplementedError();

  @override
  Future<void> deleteIdentity() async {}

  @override
  Future<String> exportNsec() async => throw UnimplementedError();

  @override
  Future<String> sign(Uint8List messageHash) async =>
      throw UnimplementedError();

  @override
  Future<String> getPubkeyHex() async => _identity.pubkeyHex;

  @override
  Future<List<int>> getSecretBytes() async => throw UnimplementedError();

  @override
  Future<void> clearCache() async {}
}

/// Minimal [LocationService] fake. Onboarding only calls [requestPermission];
/// every other member is unused and asserts if reached.
class _FakeLocationService implements LocationService {
  _FakeLocationService({this.grants = true});

  /// What the foreground permission request answers.
  final bool grants;
  bool requestPermissionCalled = false;

  /// Called on [requestPermission], before it answers.
  void Function()? onRequest;

  @override
  Future<bool> requestPermission() async {
    requestPermissionCalled = true;
    onRequest?.call();
    return grants;
  }

  @override
  Future<LocationPermissionStatus> checkPermission() =>
      throw UnimplementedError();

  @override
  Future<Position> getCurrentLocation() => throw UnimplementedError();

  @override
  Future<Position> getCurrentLocationFresh() => throw UnimplementedError();

  @override
  Stream<Position> getLocationStream() => throw UnimplementedError();

  @override
  Future<bool> isLocationServiceEnabled() => throw UnimplementedError();
}

/// Android 11+ without "Allow all the time", as the channel reports it.
class _MissingAllTime implements AndroidBackgroundLocation {
  int requests = 0;

  /// Awaited on [request], before it answers.
  Future<void> Function()? onRequest;

  @override
  Future<BackgroundLocationStatus> status() async =>
      const BackgroundLocationStatus(
        required: true,
        granted: false,
        optionLabel: 'Allow all the time',
      );

  @override
  Future<bool> request() async {
    requests++;
    await onRequest?.call();
    return true;
  }

  @override
  Future<void> openAppSettings() async {}
}

/// A KeyPackage tick an own relay acknowledged: this device's current
/// package is served.
const _published = KeyPackageMaintenancePublished(
  relaysAcked: 1,
  isFreshSlotMinted: true,
);

/// A [MaintenanceService] whose two publishing tasks are recorded and
/// scripted, so the publisher onboarding waits on runs without the bridge.
class _FakeMaintenance extends MaintenanceService {
  _FakeMaintenance(this._prefs)
    : super(
        relayService: MockRelayService(),
        circleManagerFactory: () async => throw UnimplementedError(),
        identitySecretBytes: () async => const <int>[],
      );

  final MockRelayPreferencesService _prefs;

  /// Each task, in call order.
  final List<String> calls = [];

  /// Whether the default relays were seeded when the first publish began.
  bool? seededAtFirstPublish;

  /// What successive KeyPackage steps answer, one each; an own relay
  /// acknowledging the package once these run out.
  final List<Future<KeyPackageMaintenanceOutcome> Function()> kpAnswers = [];

  /// When set, the relay-list step throws it.
  Object? relayListThrows;

  /// While true, the core holds both steps for the storage-reset notice.
  bool Function() held = () => false;

  @override
  Future<RelayListMaintenanceResult> maintainRelayList({
    required bool foreground,
  }) async {
    calls.add('relayList');
    seededAtFirstPublish ??= _prefs.didSeed;
    final boom = relayListThrows;
    if (boom != null) throw boom;
    if (held()) {
      return const RelayListMaintenanceResult(
        inbox: _heldList,
        keyPackage: _heldList,
      );
    }
    return relayListsCurrent;
  }

  @override
  Future<KeyPackageMaintenanceOutcome> maintainKeyPackage() async {
    calls.add('kp');
    seededAtFirstPublish ??= _prefs.didSeed;
    if (held()) {
      return const KeyPackageMaintenanceFailed(
        KeyPackageFailureKind.awaitingResetAcknowledgement,
      );
    }
    if (kpAnswers.isEmpty) return _published;
    return kpAnswers.removeAt(0)();
  }
}

const _heldList = RelayListCategoryResult(
  action: RelayListMaintenanceAction.awaitingResetAcknowledgement,
  ownConfirmed: false,
);

/// Records whether the storage reset was acknowledged — a save that threw
/// was not.
class _ResetCircles extends MockCircleService {
  bool acknowledged = false;

  @override
  Future<void> acknowledgeStorageReset() async {
    await super.acknowledgeStorageReset();
    acknowledged = true;
  }
}
