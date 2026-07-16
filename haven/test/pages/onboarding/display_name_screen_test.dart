/// Widget tests for [DisplayNameScreen].
///
/// Covers:
/// - Skip button flips `display_name_set` without touching the name service.
/// - Continue with non-empty text calls `setDisplayName` then flips the flag.
/// - Continue with empty text is treated as implicit skip (flag flips, no
///   service call).
/// - Service failures surface a snackbar and keep the step unflipped so the
///   user can retry.
/// - The combined [PublicProfileNotice] disclosure is shown on this screen.
/// - Continue with non-empty text ALSO best-effort publishes the name as the
///   public kind-0 profile — publishing is unconditional (public-by-default,
///   owner-directed 2026-07-16), so there is no consent step in between.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/pages/onboarding/display_name_screen.dart';
import 'package:haven/src/providers/onboarding_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/widgets/identity/public_profile_notice.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/localized_app_harness.dart';
import '../../mocks/mock_profile_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  List<Override> buildOverrides({
    required _RecordingIdentityService service,
    OnboardingFlags initialFlags = OnboardingFlags.none,
    MockProfileService? profileService,
  }) {
    return [
      identityServiceProvider.overrideWithValue(service),
      onboardingControllerProvider.overrideWith(
        (ref) => OnboardingController(initialFlags),
      ),
      // The screen always attempts a best-effort public-profile publish when
      // a non-empty name is saved (unconditional, no consent gate) — override
      // with a mock so no test reaches the real Rust FFI bridge.
      profileServiceProvider.overrideWithValue(
        profileService ?? MockProfileService(),
      ),
    ];
  }

  testWidgets(
    'Skip button flips display_name_set flag without calling the service',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final service = _RecordingIdentityService();

      await pumpLocalized(
        tester,
        const DisplayNameScreen(),
        overrides: buildOverrides(service: service),
      );

      await tester.tap(find.text('Skip'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(service.setDisplayNameCalls, isEmpty);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(kOnboardingDisplayNameSetKey), isTrue);
    },
  );

  testWidgets(
    'Continue with non-empty text saves the name then flips the flag',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final service = _RecordingIdentityService();

      await pumpLocalized(
        tester,
        const DisplayNameScreen(),
        overrides: buildOverrides(service: service),
      );

      await tester.enterText(find.byType(TextField), 'Alex');
      await tester.tap(find.text('Continue'));
      // Don't pumpAndSettle: success path leaves the spinner running
      // forever because the parent is expected to swap the screen away.
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(service.setDisplayNameCalls, ['Alex']);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(kOnboardingDisplayNameSetKey), isTrue);
    },
  );

  testWidgets('Continue with empty text still flips the flag (implicit skip)', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final service = _RecordingIdentityService();

    await pumpLocalized(
      tester,
      const DisplayNameScreen(),
      overrides: buildOverrides(service: service),
    );

    await tester.tap(find.text('Continue'));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(service.setDisplayNameCalls, isEmpty);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(kOnboardingDisplayNameSetKey), isTrue);
  });

  testWidgets(
    'service failure surfaces a snackbar and keeps the flag unflipped',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final service = _RecordingIdentityService(throwOnSet: true);

      await pumpLocalized(
        tester,
        const DisplayNameScreen(),
        overrides: buildOverrides(service: service),
      );

      await tester.enterText(find.byType(TextField), 'Alex');
      await tester.tap(find.text('Continue'));
      await tester.pump();
      await tester.pump();

      expect(
        find.text('Couldn’t save that name. Please try again.'),
        findsOneWidget,
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(kOnboardingDisplayNameSetKey), isNull);
    },
  );

  testWidgets(
    'shows the combined public-profile disclosure notice',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final service = _RecordingIdentityService();

      await pumpLocalized(
        tester,
        const DisplayNameScreen(),
        overrides: buildOverrides(service: service),
      );

      expect(find.byType(PublicProfileNotice), findsOneWidget);
      expect(find.text('Profile is public'), findsOneWidget);
    },
  );

  testWidgets(
    'Continue with non-empty text also best-effort publishes the public '
    'profile (no consent gate)',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final service = _RecordingIdentityService();
      final profileService = MockProfileService();

      await pumpLocalized(
        tester,
        const DisplayNameScreen(),
        overrides: buildOverrides(
          service: service,
          profileService: profileService,
        ),
      );

      await tester.enterText(find.byType(TextField), 'Alex');
      await tester.tap(find.text('Continue'));
      // The publish is fire-and-forget (unawaited) — pump several real frames
      // so its Future resolves before asserting on it.
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(service.setDisplayNameCalls, ['Alex']);
      expect(
        profileService.methodCalls.map((c) => c.method),
        contains('updateOwnProfile'),
        reason:
            'Publishing is unconditional — saving a name during onboarding '
            'must also attempt to publish the public kind-0 profile.',
      );
    },
  );

  testWidgets(
    'Skip never touches the profile service (nothing to publish)',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final service = _RecordingIdentityService();
      final profileService = MockProfileService();

      await pumpLocalized(
        tester,
        const DisplayNameScreen(),
        overrides: buildOverrides(
          service: service,
          profileService: profileService,
        ),
      );

      await tester.tap(find.text('Skip'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(profileService.methodCalls, isEmpty);
    },
  );
}

class _RecordingIdentityService implements IdentityService {
  _RecordingIdentityService({this.throwOnSet = false});

  final bool throwOnSet;
  final List<String?> setDisplayNameCalls = [];

  @override
  Future<void> setDisplayName(String? name) async {
    if (throwOnSet) {
      throw const IdentityServiceException('boom');
    }
    setDisplayNameCalls.add(name);
  }

  @override
  Future<String?> getDisplayName() async => null;

  @override
  Future<Identity?> getIdentity() async => null;

  @override
  Future<bool> hasIdentity() async => false;

  @override
  Future<Identity> createIdentity() async => throw UnimplementedError();

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
  Future<String> getPubkeyHex() async => throw UnimplementedError();

  @override
  Future<List<int>> getSecretBytes() async => throw UnimplementedError();

  @override
  Future<void> clearCache() async {}
}
