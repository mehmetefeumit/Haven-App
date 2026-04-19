/// Widget tests for [DisplayNameScreen].
///
/// Covers:
/// - Skip button flips `display_name_set` without touching the name service.
/// - Continue with non-empty text calls `setDisplayName` then flips the flag.
/// - Continue with empty text is treated as implicit skip (flag flips, no
///   service call).
/// - Service failures surface a snackbar and keep the step unflipped so the
///   user can retry.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/pages/onboarding/display_name_screen.dart';
import 'package:haven/src/pages/onboarding/onboarding_strings.dart';
import 'package:haven/src/providers/onboarding_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget buildHarness({
    required _RecordingIdentityService service,
    OnboardingFlags initialFlags = OnboardingFlags.none,
  }) {
    return ProviderScope(
      overrides: [
        identityServiceProvider.overrideWithValue(service),
        onboardingControllerProvider.overrideWith(
          (ref) => OnboardingController(initialFlags),
        ),
      ],
      child: const MaterialApp(home: DisplayNameScreen()),
    );
  }

  testWidgets(
    'Skip button flips display_name_set flag without calling the service',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final service = _RecordingIdentityService();

      await tester.pumpWidget(buildHarness(service: service));
      await tester.pumpAndSettle();

      await tester.tap(find.text(OnboardingStrings.displayNameSkip));
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

      await tester.pumpWidget(buildHarness(service: service));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'Alex');
      await tester.tap(find.text(OnboardingStrings.displayNameCta));
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

    await tester.pumpWidget(buildHarness(service: service));
    await tester.pumpAndSettle();

    await tester.tap(find.text(OnboardingStrings.displayNameCta));
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

      await tester.pumpWidget(buildHarness(service: service));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'Alex');
      await tester.tap(find.text(OnboardingStrings.displayNameCta));
      await tester.pump();
      await tester.pump();

      expect(find.text(OnboardingStrings.displayNameError), findsOneWidget);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(kOnboardingDisplayNameSetKey), isNull);
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
