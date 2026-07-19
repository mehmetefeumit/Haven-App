/// Widget tests for [CreateIdentityScreen] — the merged create-identity +
/// display-name screen (page 2 of 2).
///
/// Covers the full "Create My Identity" sequence: create keypair (idempotent
/// on resume), publish the public profile, run the location prominent
/// disclosure, and complete onboarding — plus the pre-filled anonymous name,
/// the empty-name fallback, and the existing-name preservation on resume.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/constants/location.dart';
import 'package:haven/src/pages/onboarding/create_identity_screen.dart';
import 'package:haven/src/pages/onboarding/import_nsec_screen.dart';
import 'package:haven/src/providers/onboarding_provider.dart';
import 'package:haven/src/providers/relay_preferences_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/services/location_service.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/widgets/identity/avatar.dart';
import 'package:haven/src/widgets/identity/public_profile_notice.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/localized_app_harness.dart';
import '../../mocks/mock_circle_service.dart';
import '../../mocks/mock_profile_service.dart';
import '../../mocks/mock_relay_preferences_service.dart';
import '../../mocks/mock_relay_service.dart';

final _namePattern = RegExp(r'^[A-Z][a-z]+ [A-Z][a-z]+$');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // createIdentity runs the M10.1 pending-wipe reconcile, which reads
  // SharedPreferences; an empty store means "no wipe pending".
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  List<Override> buildOverrides({
    required _RecordingIdentityService service,
    MockProfileService? profileService,
    _FakeLocationService? locationService,
  }) {
    return [
      identityServiceProvider.overrideWithValue(service),
      onboardingControllerProvider.overrideWith(
        (ref) => OnboardingController(
          const OnboardingFlags(introSeen: true, completed: false),
        ),
      ),
      circleServiceProvider.overrideWithValue(MockCircleService()),
      relayServiceProvider.overrideWithValue(MockRelayService()),
      profileServiceProvider.overrideWithValue(
        profileService ?? MockProfileService(),
      ),
      relayPreferencesServiceProvider.overrideWith(
        (ref) async => MockRelayPreferencesService(),
      ),
      locationServiceProvider.overrideWithValue(
        locationService ?? _FakeLocationService(),
      ),
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

  testWidgets('renders title, body, warning, disclosure, field, and CTA', (
    tester,
  ) async {
    await pumpLocalized(
      tester,
      const CreateIdentityScreen(),
      overrides: buildOverrides(service: _RecordingIdentityService()),
    );

    expect(find.text('Create your identity'), findsOneWidget);
    expect(
      find.text(
        'Haven will create a private identity that lives only on this '
        'phone. It’s how your circles recognise you.',
      ),
      findsOneWidget,
    );
    expect(
      find.text(
        'If you lose this phone or delete the app, your identity is gone. '
        'Haven has no way to recover it for you.',
      ),
      findsOneWidget,
    );
    // The public-profile disclosure must be present since publishing is
    // now mandatory and unskippable.
    expect(find.byType(PublicProfileNotice), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.byKey(WidgetKeys.createIdentityCta), findsOneWidget);
    expect(find.text('Create My Identity'), findsOneWidget);
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
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(kOnboardingCompletedKey), isTrue);
      expect(prefs.getBool(kBackgroundSharingKey), isTrue);
      expect(location.requestPermissionCalled, isTrue);
    },
  );

  testWidgets('an edited name is what gets saved and published', (tester) async {
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

  testWidgets(
    'resume with an existing chosen name preserves it (no clobber)',
    (tester) async {
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
    },
  );

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

  testWidgets('if the name publish fails, the picked photo is NOT published', (
    tester,
  ) async {
    final service = _RecordingIdentityService();
    final profile = MockProfileService()..shouldThrowOnUpdateOwnProfile = true;
    final photoBytes = Uint8List.fromList([4, 2]);

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

    await tester.tap(find.byKey(WidgetKeys.createIdentityCta));
    await pumpFrames(tester);
    await tester.tap(find.byKey(WidgetKeys.locationDisclosureAgree));
    await pumpFrames(tester);

    // The name publish threw, so the avatar upload is gated off — no
    // picture-only kind-0 is published without the intended name.
    final methods = profile.methodCalls.map((c) => c.method);
    expect(methods, contains('updateOwnProfile'));
    expect(methods, isNot(contains('setOwnAvatar')));
    // Onboarding still completes (the profile publish is fire-and-forget).
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(kOnboardingCompletedKey), isTrue);
  });

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
  Future<bool> hasIdentity() async => hasIdentityValue;

  @override
  Future<Identity?> getIdentity() async =>
      (hasIdentityValue || createIdentityCalls > 0) ? _identity : null;

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
  bool requestPermissionCalled = false;

  @override
  Future<bool> requestPermission() async {
    requestPermissionCalled = true;
    return true;
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
