/// Widget tests for [OnboardingShell] dispatch.
///
/// [OnboardingShell] watches [onboardingStepProvider] and renders one of the
/// two step screens (or an empty placeholder when done). We drive the derived
/// step by overriding the persisted flags.
library;

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/pages/onboarding/create_identity_screen.dart';
import 'package:haven/src/pages/onboarding/intro_screen.dart';
import 'package:haven/src/pages/onboarding/onboarding_shell.dart';
import 'package:haven/src/providers/onboarding_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/localized_app_harness.dart';
import '../../mocks/mock_circle_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  List<Override> buildOverrides(OnboardingFlags flags) {
    return [
      onboardingControllerProvider.overrideWith(
        (ref) => OnboardingController(flags),
      ),
      identityServiceProvider.overrideWithValue(_StubIdentityService()),
      circleServiceProvider.overrideWithValue(MockCircleService()),
    ];
  }

  testWidgets('intro step renders IntroScreen', (tester) async {
    await pumpLocalized(
      tester,
      const OnboardingShell(),
      overrides: buildOverrides(OnboardingFlags.none),
    );

    expect(find.byType(IntroScreen), findsOneWidget);
  });

  testWidgets('createIdentity step renders CreateIdentityScreen', (
    tester,
  ) async {
    await pumpLocalized(
      tester,
      const OnboardingShell(),
      overrides: buildOverrides(
        const OnboardingFlags(introSeen: true, completed: false),
      ),
    );

    expect(find.byType(CreateIdentityScreen), findsOneWidget);
  });

  testWidgets('done step renders an empty placeholder', (tester) async {
    await pumpLocalized(
      tester,
      const OnboardingShell(),
      overrides: buildOverrides(
        const OnboardingFlags(introSeen: true, completed: true),
      ),
    );

    expect(find.byType(IntroScreen), findsNothing);
    expect(find.byType(CreateIdentityScreen), findsNothing);
  });
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
