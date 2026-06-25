/// Widget tests for [OnboardingShell] dispatch.
///
/// [OnboardingShell] watches [onboardingStepProvider] and renders one of the
/// step-specific screens. We override the underlying flags + a stub
/// [IdentityService] to drive the derived step to each value in turn.
library;

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/pages/onboarding/create_identity_screen.dart';
import 'package:haven/src/pages/onboarding/display_name_screen.dart';
import 'package:haven/src/pages/onboarding/onboarding_shell.dart';
import 'package:haven/src/pages/onboarding/ready_screen.dart';
import 'package:haven/src/pages/onboarding/welcome_screen.dart';
import 'package:haven/src/providers/onboarding_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/localized_app_harness.dart';
import '../../mocks/mock_circle_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  List<Override> buildOverrides({
    required OnboardingFlags flags,
    required Identity? identity,
  }) {
    return [
      onboardingControllerProvider.overrideWith(
        (ref) => OnboardingController(flags),
      ),
      identityServiceProvider.overrideWithValue(
        _StubIdentityService(identity),
      ),
      circleServiceProvider.overrideWithValue(MockCircleService()),
    ];
  }

  testWidgets('welcome step renders WelcomeScreen', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await pumpLocalized(
      tester,
      const OnboardingShell(),
      overrides: buildOverrides(flags: OnboardingFlags.none, identity: null),
    );

    expect(find.byType(WelcomeScreen), findsOneWidget);
  });

  testWidgets('createIdentity step renders CreateIdentityScreen', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await pumpLocalized(
      tester,
      const OnboardingShell(),
      overrides: buildOverrides(
        flags: const OnboardingFlags(
          introSeen: true,
          displayNameSet: false,
          completed: false,
        ),
        identity: null,
      ),
    );

    expect(find.byType(CreateIdentityScreen), findsOneWidget);
  });

  testWidgets('displayName step renders DisplayNameScreen', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await pumpLocalized(
      tester,
      const OnboardingShell(),
      overrides: buildOverrides(
        flags: const OnboardingFlags(
          introSeen: true,
          displayNameSet: false,
          completed: false,
        ),
        identity: _stubIdentity,
      ),
    );

    expect(find.byType(DisplayNameScreen), findsOneWidget);
  });

  testWidgets('ready step renders ReadyScreen', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await pumpLocalized(
      tester,
      const OnboardingShell(),
      overrides: buildOverrides(
        flags: const OnboardingFlags(
          introSeen: true,
          displayNameSet: true,
          completed: false,
        ),
        identity: _stubIdentity,
      ),
    );

    expect(find.byType(ReadyScreen), findsOneWidget);
  });

  testWidgets('done step renders an empty placeholder', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await pumpLocalized(
      tester,
      const OnboardingShell(),
      overrides: buildOverrides(
        flags: const OnboardingFlags(
          introSeen: true,
          displayNameSet: true,
          completed: true,
        ),
        identity: _stubIdentity,
      ),
    );

    expect(find.byType(WelcomeScreen), findsNothing);
    expect(find.byType(CreateIdentityScreen), findsNothing);
    expect(find.byType(DisplayNameScreen), findsNothing);
    expect(find.byType(ReadyScreen), findsNothing);
  });
}

final _stubIdentity = Identity(
  pubkeyHex:
      '1111111111111111111111111111111111111111111111111111111111111111',
  npub: 'npub1stub',
  createdAt: DateTime(2025),
);

class _StubIdentityService implements IdentityService {
  _StubIdentityService(this._identity);

  final Identity? _identity;

  @override
  Future<Identity?> getIdentity() async => _identity;

  @override
  Future<bool> hasIdentity() async => _identity != null;

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
  Future<String> getPubkeyHex() async =>
      _identity?.pubkeyHex ?? (throw UnimplementedError());

  @override
  Future<List<int>> getSecretBytes() async => throw UnimplementedError();

  @override
  Future<String?> getDisplayName() async => null;

  @override
  Future<void> setDisplayName(String? name) async {}

  @override
  Future<void> clearCache() async {}
}
