/// Widget tests for [AppRouter].
///
/// The completed=true branch renders `MapShell`, which pulls in Rust FFI,
/// the relay service, platform-channel calls, and a foreground-service
/// lifecycle provider — out of scope for a pure widget test. What this
/// file covers is the routing decision itself:
///
/// - completed=false → `OnboardingShell` renders.
///
/// Full end-to-end verification of the MapShell branch lives in the plan's
/// manual verification steps and any future integration tests.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/pages/onboarding/onboarding_shell.dart';
import 'package:haven/src/providers/onboarding_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/widgets/app_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../mocks/mock_circle_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('renders OnboardingShell when completed is false', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          onboardingControllerProvider.overrideWith(
            (ref) => OnboardingController(OnboardingFlags.none),
          ),
          identityServiceProvider.overrideWithValue(_StubIdentityService()),
          circleServiceProvider.overrideWithValue(MockCircleService()),
        ],
        child: const MaterialApp(home: AppRouter()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(OnboardingShell), findsOneWidget);
  });

  testWidgets(
    'renders OnboardingShell for mid-flow flags with completed=false',
    (tester) async {
      // Defensive: inconsistent persisted state (completed=false, others=true)
      // must still route to onboarding because AppRouter only keys off
      // `completed`. Verifies the simple boolean gate.
      SharedPreferences.setMockInitialValues({});

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            onboardingControllerProvider.overrideWith(
              (ref) => OnboardingController(
                const OnboardingFlags(
                  introSeen: true,
                  displayNameSet: true,
                  completed: false,
                ),
              ),
            ),
            identityServiceProvider.overrideWithValue(_StubIdentityService()),
            circleServiceProvider.overrideWithValue(MockCircleService()),
          ],
          child: const MaterialApp(home: AppRouter()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(OnboardingShell), findsOneWidget);
    },
  );
}

class _StubIdentityService implements IdentityService {
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
  Future<String?> getDisplayName() async => null;

  @override
  Future<void> setDisplayName(String? name) async {}

  @override
  Future<void> clearCache() async {}
}
