/// Widget tests for [CreateIdentityScreen] — the merged create-identity +
/// display-name screen (page 2 of 2).
///
/// Covers the full "Create My Identity" sequence: create keypair (idempotent
/// on resume), publish the public profile, run the location prominent
/// disclosure, and complete onboarding — plus the pre-filled anonymous name,
/// the empty-name fallback, and the existing-name preservation on resume.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/constants/location.dart';
import 'package:haven/src/pages/onboarding/create_identity_screen.dart';
import 'package:haven/src/pages/onboarding/import_nsec_screen.dart';
import 'package:haven/src/pages/settings/relay_settings_page.dart';
import 'package:haven/src/providers/location_disclosure_provider.dart';
import 'package:haven/src/providers/onboarding_provider.dart';
import 'package:haven/src/providers/relay_preferences_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/providers/storage_reset_notice_provider.dart';
import 'package:haven/src/rust/api.dart'
    show NostrIdentityManager, PublicIdentity;
import 'package:haven/src/services/android_background_location.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/services/location_service.dart';
import 'package:haven/src/services/maintenance_service.dart';
import 'package:haven/src/services/nostr_identity_service.dart';
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
    required IdentityService service,
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
      expect(service.setDisplayNameCalls, [name]);
      expect(
        profile.methodCalls.map((c) => c.method),
        contains('updateOwnProfile'),
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

  testWidgets('an edited name is what gets saved and published', (
    tester,
  ) async {
    final service = _RecordingIdentityService();
    final profile = MockProfileService();

    await pumpLocalized(
      tester,
      const CreateIdentityScreen(),
      overrides: buildOverrides(service: service, profileService: profile),
      settle: false,
    );
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'Wren Willow');
    await tester.tap(find.byKey(WidgetKeys.createIdentityCta));
    await pumpFrames(tester);
    await tester.tap(find.byKey(WidgetKeys.locationDisclosureAgree));
    await pumpFrames(tester);

    expect(service.setDisplayNameCalls, ['Wren Willow']);
  });

  testWidgets('declining the disclosure still completes onboarding', (
    tester,
  ) async {
    final service = _RecordingIdentityService();
    final location = _FakeLocationService();

    await pumpLocalized(
      tester,
      const CreateIdentityScreen(),
      overrides: buildOverrides(service: service, locationService: location),
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
    expect(service.setDisplayNameCalls, hasLength(1));
    expect(prefs.getBool(kOnboardingCompletedKey), isTrue);
    // ...but nothing was requested or enabled.
    expect(prefs.getBool(kBackgroundSharingKey), isNot(true));
    expect(location.requestPermissionCalled, isFalse);
  });

  testWidgets('a cleared field falls back to a generated name (never empty)', (
    tester,
  ) async {
    final service = _RecordingIdentityService();

    await pumpLocalized(
      tester,
      const CreateIdentityScreen(),
      overrides: buildOverrides(service: service),
      settle: false,
    );
    await tester.pump();

    await tester.enterText(find.byType(TextField), '');
    await tester.tap(find.byKey(WidgetKeys.createIdentityCta));
    await pumpFrames(tester);
    await tester.tap(find.byKey(WidgetKeys.locationDisclosureAgree));
    await pumpFrames(tester);

    expect(service.setDisplayNameCalls, hasLength(1));
    final saved = service.setDisplayNameCalls.single!;
    expect(_namePattern.hasMatch(saved), isTrue, reason: 'saved: "$saved"');
  });

  testWidgets(
    'resume (identity already exists): does not re-create the keypair',
    (tester) async {
      final service = _RecordingIdentityService(hasIdentityValue: true);

      await pumpLocalized(
        tester,
        const CreateIdentityScreen(),
        overrides: buildOverrides(service: service),
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
      expect(service.setDisplayNameCalls, hasLength(1));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(kOnboardingCompletedKey), isTrue);
    },
  );

  testWidgets('resume with an existing chosen name preserves it (no clobber)', (
    tester,
  ) async {
    final service = _RecordingIdentityService(
      hasIdentityValue: true,
      existingDisplayName: 'Alice',
    );

    await pumpLocalized(
      tester,
      const CreateIdentityScreen(),
      overrides: buildOverrides(service: service),
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
    expect(service.setDisplayNameCalls, ['Alice']);
  });

  testWidgets('a create failure surfaces a snackbar and does not complete', (
    tester,
  ) async {
    final service = _RecordingIdentityService(throwOnCreate: true);

    await pumpLocalized(
      tester,
      const CreateIdentityScreen(),
      overrides: buildOverrides(service: service),
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
      final maintenance = _FakeMaintenance(MockRelayPreferencesService());
      maintenance.kpAnswers.add(
        () => Completer<KeyPackageMaintenanceOutcome>().future,
      );

      await pumpLocalized(
        tester,
        const CreateIdentityScreen(),
        overrides: buildOverrides(service: service, maintenance: maintenance),
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
      expect(service.setDisplayNameCalls, hasLength(1));
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

  // ── A stored key secure storage cannot read yet ─────────────────────────
  //
  // The screen is reachable with a key stored (an interrupted first run): a
  // read that fails must not pass for an empty store, or the tap creates a
  // new key over the stored one and publishes a fresh name over the saved
  // one.

  const createError =
      'Something went wrong creating your identity. Please try again.';
  const unavailable = IdentityStorageUnavailableException();

  Finder cta() => find.byKey(WidgetKeys.createIdentityCta);

  testWidgets(
    'a stored name replaces the generated one once storage can be read',
    (tester) async {
      final service = _RecordingIdentityService(
        hasIdentityValue: true,
        existingDisplayName: 'Alice',
      )..hasIdentityAnswers.add(unavailable);

      await pumpLocalized(
        tester,
        const CreateIdentityScreen(),
        overrides: buildOverrides(service: service),
        settle: false,
      );
      await tester.pump();
      expect(_namePattern.hasMatch(prefilledName(tester)), isTrue);

      await tester.pump(const Duration(seconds: 1));
      await tester.pump();

      expect(prefilledName(tester), 'Alice');
      expect(service.hasIdentityCalls, 2);
    },
  );

  testWidgets(
    'while storage cannot say whether a key is stored, a tap creates, saves '
    'and publishes nothing, and can be repeated',
    (tester) async {
      final service = _RecordingIdentityService(hasIdentityError: unavailable);
      final profile = MockProfileService();
      final maintenance = _FakeMaintenance(MockRelayPreferencesService());

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

      await tester.tap(cta());
      await pumpFrames(tester);

      expect(find.text(createError), findsOneWidget);
      expect(service.createIdentityCalls, 0);
      expect(service.setDisplayNameCalls, isEmpty);
      expect(
        profile.methodCalls.map((c) => c.method),
        isNot(anyOf(contains('updateOwnProfile'), contains('syncOwnProfile'))),
      );
      expect(maintenance.calls, isEmpty, reason: 'nothing published');
      expect(await onboardingCompleted(), isFalse);
      expect(find.text('Create My Identity'), findsOneWidget);

      // Once the snackbar has gone, the same tap is refused the same way.
      await tester.pump(const Duration(seconds: 5));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text(createError), findsNothing);
      await tester.tap(cta());
      await pumpFrames(tester);
      expect(find.text(createError), findsOneWidget);
      expect(service.createIdentityCalls, 0);
    },
  );

  testWidgets(
    'storage readable by the tap: the stored key and stored name are used',
    (tester) async {
      final service = _RecordingIdentityService(
        hasIdentityValue: true,
        existingDisplayName: 'Alice',
      )..hasIdentityAnswers.add(unavailable);

      await pumpLocalized(
        tester,
        const CreateIdentityScreen(),
        overrides: buildOverrides(service: service),
        settle: false,
      );
      await tester.pump();

      // Before the first retry.
      await tester.tap(cta());
      await pumpFrames(tester);
      await tester.tap(find.byKey(WidgetKeys.locationDisclosureAgree));
      await pumpFrames(tester);

      expect(service.createIdentityCalls, 0);
      expect(service.setDisplayNameCalls, ['Alice']);
      expect(await onboardingCompleted(), isTrue);
    },
  );

  testWidgets('an edit made while storage could not be read wins', (
    tester,
  ) async {
    final service = _RecordingIdentityService(
      hasIdentityValue: true,
      existingDisplayName: 'Alice',
    )..hasIdentityAnswers.add(unavailable);

    await pumpLocalized(
      tester,
      const CreateIdentityScreen(),
      overrides: buildOverrides(service: service),
      settle: false,
    );
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'Wren Willow');
    await tester.pump(const Duration(seconds: 5));
    expect(prefilledName(tester), 'Wren Willow');
    expect(service.hasIdentityCalls, 1, reason: 'the edit ended the retries');

    await tester.tap(cta());
    await pumpFrames(tester);
    await tester.tap(find.byKey(WidgetKeys.locationDisclosureAgree));
    await pumpFrames(tester);

    expect(service.setDisplayNameCalls, ['Wren Willow']);
  });

  testWidgets(
    'a create refused for unreadable storage saves nothing, and the screen '
    'goes on trying to read',
    (tester) async {
      final service = _RecordingIdentityService(createError: unavailable);

      await pumpLocalized(
        tester,
        const CreateIdentityScreen(),
        overrides: buildOverrides(service: service),
        settle: false,
      );
      await tester.pump();
      await tester.tap(cta());
      await pumpFrames(tester);

      expect(find.text(createError), findsOneWidget);
      expect(service.createIdentityCalls, 1);
      expect(service.setDisplayNameCalls, isEmpty);
      expect(await onboardingCompleted(), isFalse);
      expect(service.hasIdentityCalls, 2);

      await tester.pump(const Duration(seconds: 1));
      expect(service.hasIdentityCalls, 3, reason: 're-armed by the refusal');
    },
  );

  testWidgets('any other failed create re-arms nothing', (tester) async {
    final service = _RecordingIdentityService(throwOnCreate: true);

    await pumpLocalized(
      tester,
      const CreateIdentityScreen(),
      overrides: buildOverrides(service: service),
      settle: false,
    );
    await tester.pump();
    await tester.tap(cta());
    await pumpFrames(tester);
    await tester.pump(const Duration(seconds: 60));

    expect(find.text(createError), findsOneWidget);
    expect(service.hasIdentityCalls, 2);
  });

  testWidgets(
    'a failed identity check shows fixed copy, logs no identifier, and the '
    'button works again',
    (tester) async {
      final logs = LogCapture();
      addTearDown(logs.restore);
      final service = _RecordingIdentityService()
        ..hasIdentityAnswers.addAll([false, Exception('npub1plantedplanted')]);

      await pumpLocalized(
        tester,
        const CreateIdentityScreen(),
        overrides: buildOverrides(service: service),
        settle: false,
      );
      await tester.pump();
      await tester.tap(cta());
      await pumpFrames(tester);

      expect(find.text(createError), findsOneWidget);
      expect(find.textContaining('planted'), findsNothing);
      expect(service.createIdentityCalls, 0);
      expect(find.text('Create My Identity'), findsOneWidget);
      logs
        ..assertContains('[Onboarding] identity check failed: _Exception')
        ..assertNoNeedles(['npub1plantedplanted'])
        ..restore();
    },
  );

  testWidgets(
    'a restore that throws anything else is logged by type and retried',
    (tester) async {
      final logs = LogCapture();
      addTearDown(logs.restore);
      final service = _RecordingIdentityService(
        hasIdentityValue: true,
        existingDisplayName: 'Alice',
      )..hasIdentityAnswers.add(Exception('npub1plantedplanted'));

      await pumpLocalized(
        tester,
        const CreateIdentityScreen(),
        overrides: buildOverrides(service: service),
        settle: false,
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();

      expect(prefilledName(tester), 'Alice');
      logs
        ..assertContains('[Onboarding] name restore failed: _Exception')
        ..assertNoNeedles(['npub1plantedplanted'])
        ..restore();
    },
  );

  testWidgets(
    'storage that stays unreadable is retried at 1, 2, 4, 8 and 16 s, then '
    'every 30 s',
    (tester) async {
      final service = _RecordingIdentityService(hasIdentityError: unavailable);

      await pumpLocalized(
        tester,
        const CreateIdentityScreen(),
        overrides: buildOverrides(service: service),
        settle: false,
      );
      await tester.pump();
      expect(service.hasIdentityCalls, 1);

      var now = Duration.zero;
      Future<int> callsAt(Duration at) async {
        await tester.pump(at - now);
        now = at;
        return service.hasIdentityCalls;
      }

      const millis = Duration(milliseconds: 1);
      for (final (seconds, calls) in [
        (1, 2),
        (3, 3),
        (7, 4),
        (15, 5),
        (31, 6),
        (61, 7),
        (91, 8),
        (121, 9),
      ]) {
        final due = Duration(seconds: seconds);
        expect(await callsAt(due - millis), calls - 1, reason: 'before $due');
        expect(await callsAt(due), calls, reason: 'at $due');
      }
    },
  );

  testWidgets('a tap that starts the create path stops the retries', (
    tester,
  ) async {
    final service = _RecordingIdentityService()
      ..hasIdentityAnswers.add(unavailable);

    await pumpLocalized(
      tester,
      const CreateIdentityScreen(
        restoreRetryDelays: [Duration(milliseconds: 100)],
      ),
      overrides: buildOverrides(service: service),
      settle: false,
    );
    await tester.pump();
    await tester.tap(cta());
    await pumpFrames(tester);
    await tester.pump(const Duration(seconds: 5));

    expect(service.createIdentityCalls, 1);
    expect(service.hasIdentityCalls, 2, reason: 'the restore and the tap');
  });

  testWidgets('leaving the screen stops the retries', (tester) async {
    // Restored inside the body: testWidgets checks debugPrint before
    // addTearDown callbacks run (see log_capture.dart).
    final logs = LogCapture();
    addTearDown(logs.restore);
    final service = _RecordingIdentityService(hasIdentityError: unavailable);

    await pumpLocalized(
      tester,
      const CreateIdentityScreen(),
      overrides: buildOverrides(service: service),
      settle: false,
    );
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 5));

    // A retry that outlived the screen would fail on its disposed `ref`,
    // which the restore swallows and logs: neither may happen.
    expect(service.hasIdentityCalls, 1);
    expect(logs.joined, isNot(contains('[Onboarding] name restore failed')));
    logs.restore();
  });

  testWidgets(
    'a tap and the first restore failing on one read step the backoff once',
    (tester) async {
      final firstRead = Completer<void>();
      final service = _RecordingIdentityService(hasIdentityError: unavailable)
        ..hasIdentityGates.add(firstRead);

      await pumpLocalized(
        tester,
        const CreateIdentityScreen(),
        overrides: buildOverrides(service: service),
        settle: false,
      );
      await tester.pump();
      // The restore's read is still out; the tap's fails first.
      await tester.tap(cta());
      await tester.pump();
      expect(find.text(createError), findsOneWidget);
      firstRead.complete();
      await tester.pump();
      expect(service.hasIdentityCalls, 2);

      await tester.pump(const Duration(milliseconds: 999));
      expect(service.hasIdentityCalls, 2);
      await tester.pump(const Duration(milliseconds: 1));
      expect(service.hasIdentityCalls, 3, reason: 'the first retry, at 1 s');
    },
  );

  testWidgets(
    'a stored name that cannot be read at the tap is not published over: '
    'nothing is saved or published, and the next tap uses it',
    (tester) async {
      final service = _RecordingIdentityService(
        hasIdentityValue: true,
        existingDisplayName: 'Alice',
      )..hasIdentityAnswers.add(unavailable);
      service.getDisplayNameErrors.add(Exception('prefs unreadable'));
      final maintenance = _FakeMaintenance(MockRelayPreferencesService());

      await pumpLocalized(
        tester,
        const CreateIdentityScreen(),
        overrides: buildOverrides(service: service, maintenance: maintenance),
        settle: false,
      );
      await tester.pump();
      await tester.tap(cta());
      await pumpFrames(tester);

      expect(find.text(createError), findsOneWidget);
      expect(service.createIdentityCalls, 0);
      expect(service.setDisplayNameCalls, isEmpty);
      expect(maintenance.calls, isEmpty, reason: 'nothing published');
      expect(await onboardingCompleted(), isFalse);

      // The re-armed retry reads the name; the snackbar goes.
      await tester.pump(const Duration(seconds: 5));
      await tester.pump(const Duration(seconds: 1));
      expect(prefilledName(tester), 'Alice');
      await tester.tap(cta());
      await pumpFrames(tester);
      await tester.tap(find.byKey(WidgetKeys.locationDisclosureAgree));
      await pumpFrames(tester);

      expect(service.setDisplayNameCalls, ['Alice']);
      expect(await onboardingCompleted(), isTrue);
    },
  );

  testWidgets(
    'a cleared field whose stored-name fallback cannot be read publishes '
    'nothing, and the button works again',
    (tester) async {
      final logs = LogCapture();
      addTearDown(logs.restore);
      final service = _RecordingIdentityService(
        hasIdentityValue: true,
        existingDisplayName: 'Alice',
      );
      final maintenance = _FakeMaintenance(MockRelayPreferencesService());

      await pumpLocalized(
        tester,
        const CreateIdentityScreen(),
        overrides: buildOverrides(service: service, maintenance: maintenance),
        settle: false,
      );
      await tester.pump();
      await tester.enterText(find.byType(TextField), '');
      service.getDisplayNameErrors.add(Exception('npub1plantedplanted'));
      await tester.tap(cta());
      await pumpFrames(tester);

      expect(find.text(createError), findsOneWidget);
      expect(service.setDisplayNameCalls, isEmpty);
      expect(maintenance.calls, isEmpty, reason: 'nothing published');
      expect(await onboardingCompleted(), isFalse);
      logs
        ..assertContains('[Onboarding] stored name read failed: _Exception')
        ..assertNoNeedles(['npub1plantedplanted'])
        ..restore();

      // Once the snackbar has gone, the same tap goes through.
      await tester.pump(const Duration(seconds: 5));
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(cta());
      await pumpFrames(tester);
      await tester.tap(find.byKey(WidgetKeys.locationDisclosureAgree));
      await pumpFrames(tester);

      expect(service.setDisplayNameCalls, ['Alice']);
      expect(await onboardingCompleted(), isTrue);
    },
  );

  testWidgets(
    'a name the user typed is saved even when the stored one cannot be read',
    (tester) async {
      final service = _RecordingIdentityService(
        hasIdentityValue: true,
        existingDisplayName: 'Alice',
      )..hasIdentityAnswers.add(unavailable);
      service.getDisplayNameErrors.add(Exception('prefs unreadable'));

      await pumpLocalized(
        tester,
        const CreateIdentityScreen(),
        overrides: buildOverrides(service: service),
        settle: false,
      );
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'Wren Willow');
      await tester.tap(cta());
      await pumpFrames(tester);
      await tester.tap(find.byKey(WidgetKeys.locationDisclosureAgree));
      await pumpFrames(tester);

      expect(service.setDisplayNameCalls, ['Wren Willow']);
    },
  );

  testWidgets(
    'with the real identity service, an unreadable stored key is never '
    'replaced',
    (tester) async {
      final storage = _ScriptedStorage(
        stored: _storedKey,
        readError: PlatformException(code: 'locked', details: -25308),
      );
      final manager = _FakeIdentityManager();

      await pumpLocalized(
        tester,
        const CreateIdentityScreen(),
        overrides: buildOverrides(service: _realService(storage, manager)),
        settle: false,
      );
      await tester.pump();
      await tester.tap(cta());
      await pumpFrames(tester);

      expect(find.text(createError), findsOneWidget);
      expect(manager.createCalls, 0);
      expect(storage.writes, isEmpty);
      expect(storage.stored, _storedKey);
    },
  );

  testWidgets(
    'with the real identity service, a fresh install creates its key at the '
    'tap with no storage read more than before',
    (tester) async {
      final storage = _ScriptedStorage();
      final manager = _FakeIdentityManager();

      await pumpLocalized(
        tester,
        const CreateIdentityScreen(),
        overrides: buildOverrides(service: _realService(storage, manager)),
        settle: false,
      );
      await tester.pump();
      await tester.tap(cta());
      await pumpFrames(tester);

      expect(find.byKey(WidgetKeys.locationDisclosureAgree), findsOneWidget);
      expect(manager.createCalls, 1);
      expect(storage.writes, hasLength(1));
      // The restore's, the tap's, the identity notifier's first load and the
      // create's: one each, as before the restore asked hasIdentity.
      expect(storage.readCalls, 4);
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
    'if the name LOCAL SAVE fails, the picked photo is NOT saved either',
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
        await tester.tap(find.byKey(WidgetKeys.locationDisclosureAgree));
        await pumpFrames(tester);
      } finally {
        log.restore();
      }

      // The name local save threw, so the avatar's local save is gated off
      // — no picture-only local edit is queued without the intended name.
      final methods = profile.methodCalls.map((c) => c.method);
      expect(methods, contains('updateOwnProfile'));
      expect(methods, isNot(contains('setOwnAvatar')));
      // The picked photo was lost with it, and the user is told so.
      expect(find.text(_photoNotSaved), findsOneWidget);
      log
        ..assertContains('[Onboarding] profile name save failed: StateError')
        ..assertNoNeedles([name]);
      // Onboarding still completes: the local-save failure is logged by
      // `_saveOnboardingProfileLocally` and reported, and the background
      // publish trigger is unconditional (there is nothing to publish, but
      // triggering it is harmless — see `ProfileSyncOutcome.nothingPending`).
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(kOnboardingCompletedKey), isTrue);
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
    this.hasIdentityError,
    this.existingDisplayName,
    this.throwOnCreate = false,
    this.createError,
  });

  final bool hasIdentityValue;

  /// When set, [hasIdentity] throws it once [hasIdentityAnswers] run out.
  Exception? hasIdentityError;
  final String? existingDisplayName;
  final bool throwOnCreate;

  /// When set, [createIdentity] throws it.
  final Exception? createError;

  /// What successive [hasIdentity] calls answer, one each: a `bool` is
  /// returned, an [Exception] thrown.
  final List<Object> hasIdentityAnswers = [];

  /// Successive [hasIdentity] calls wait on these, one each, before
  /// answering.
  final List<Completer<void>> hasIdentityGates = [];

  /// Errors successive [getDisplayName] calls throw, one each.
  final List<Exception> getDisplayNameErrors = [];

  int hasIdentityCalls = 0;
  int createIdentityCalls = 0;
  final List<String?> setDisplayNameCalls = [];

  static final _identity = Identity(
    pubkeyHex:
        '1111111111111111111111111111111111111111111111111111111111111111',
    npub: 'npub1stub',
    createdAt: DateTime(2025),
  );

  @override
  Future<bool> hasIdentity() async {
    hasIdentityCalls++;
    if (hasIdentityGates.isNotEmpty) await hasIdentityGates.removeAt(0).future;
    if (hasIdentityAnswers.isNotEmpty) {
      final answer = hasIdentityAnswers.removeAt(0);
      if (answer is Exception) throw answer;
      return answer as bool;
    }
    final error = hasIdentityError;
    if (error != null) throw error;
    return hasIdentityValue;
  }

  @override
  Future<Identity?> getIdentity() async =>
      (hasIdentityValue || createIdentityCalls > 0) ? _identity : null;

  @override
  Future<Identity> createIdentity() async {
    createIdentityCalls++;
    if (throwOnCreate) {
      throw const IdentityServiceException('boom');
    }
    final error = createError;
    if (error != null) throw error;
    return _identity;
  }

  @override
  Future<String?> getDisplayName() async {
    if (getDisplayNameErrors.isNotEmpty) throw getDisplayNameErrors.removeAt(0);
    return existingDisplayName;
  }

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

/// A base64 identity key, as stored.
final String _storedKey = base64Encode(List.filled(32, 7));

NostrIdentityService _realService(
  FlutterSecureStorage storage,
  NostrIdentityManager manager,
) => NostrIdentityService(
  storage: storage,
  wipeTileCache: () async {},
  keyringInitializer: () async {},
  managerFactory: () async => manager,
  isIOS: false,
);

/// The Rust identity manager, for the real [NostrIdentityService]; members
/// the screen does not reach throw.
class _FakeIdentityManager implements NostrIdentityManager {
  int createCalls = 0;
  String? _pubkey;

  @override
  bool hasIdentity() => _pubkey != null;

  @override
  PublicIdentity? getIdentity() => _pubkey == null
      ? null
      : PublicIdentity(pubkeyHex: _pubkey!, npub: 'npub1stub', createdAt: 0);

  @override
  String pubkeyHex() => _pubkey!;

  @override
  Future<PublicIdentity> loadFromBytes({required List<int> secretBytes}) async {
    _pubkey = '11' * 32;
    return getIdentity()!;
  }

  @override
  Future<PublicIdentity> createIdentity() async {
    createCalls++;
    _pubkey = '22' * 32;
    return getIdentity()!;
  }

  @override
  Future<Uint8List> getSecretBytes() async =>
      Uint8List.fromList(List.filled(32, 9));

  @override
  Future<void> deleteIdentity() async => _pubkey = null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Secure storage holding [stored]; every read throws [readError] when set.
class _ScriptedStorage extends FlutterSecureStorage {
  _ScriptedStorage({this.stored, this.readError});

  String? stored;
  final Exception? readError;
  int readCalls = 0;
  final List<String> writes = [];

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    readCalls++;
    final error = readError;
    if (error != null) throw error;
    return stored;
  }

  @override
  Future<bool> containsKey({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => stored != null;

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    writes.add(value!);
    stored = value;
  }
}
