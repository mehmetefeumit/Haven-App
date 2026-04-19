/// Widget tests for [CreateIdentityScreen].
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/pages/onboarding/create_identity_screen.dart';
import 'package:haven/src/pages/onboarding/import_nsec_screen.dart';
import 'package:haven/src/pages/onboarding/onboarding_strings.dart';
import 'package:haven/src/providers/onboarding_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/identity_service.dart';

import '../../mocks/mock_circle_service.dart';
import '../../mocks/mock_relay_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget buildHarness({required _RecordingIdentityService service}) {
    return ProviderScope(
      overrides: [
        identityServiceProvider.overrideWithValue(service),
        onboardingControllerProvider.overrideWith(
          (ref) => OnboardingController(OnboardingFlags.none),
        ),
        circleServiceProvider.overrideWithValue(MockCircleService()),
        relayServiceProvider.overrideWithValue(MockRelayService()),
      ],
      child: const MaterialApp(home: CreateIdentityScreen()),
    );
  }

  testWidgets('renders title, body, warning, CTA and import link', (
    tester,
  ) async {
    final service = _RecordingIdentityService();

    await tester.pumpWidget(buildHarness(service: service));
    await tester.pumpAndSettle();

    expect(find.text(OnboardingStrings.createIdentityTitle), findsOneWidget);
    expect(find.text(OnboardingStrings.createIdentityBody), findsOneWidget);
    expect(find.text(OnboardingStrings.createIdentityWarning), findsOneWidget);
    expect(find.text(OnboardingStrings.createIdentityCta), findsOneWidget);
    expect(
      find.textContaining(OnboardingStrings.createIdentityImportLink),
      findsOneWidget,
    );
  });

  testWidgets('tapping the primary CTA invokes createIdentity', (tester) async {
    final service = _RecordingIdentityService();

    await tester.pumpWidget(buildHarness(service: service));
    await tester.pumpAndSettle();

    await tester.tap(find.text(OnboardingStrings.createIdentityCta));
    // Success leaves background work fire-and-forget; bounded pump avoids
    // a pumpAndSettle hang on the spinner.
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(service.createIdentityCalls, 1);
  });

  testWidgets('service failure surfaces a snackbar', (tester) async {
    final service = _RecordingIdentityService(throwOnCreate: true);

    await tester.pumpWidget(buildHarness(service: service));
    await tester.pumpAndSettle();

    await tester.tap(find.text(OnboardingStrings.createIdentityCta));
    await tester.pump();
    await tester.pump();

    expect(find.text(OnboardingStrings.createIdentityError), findsOneWidget);
    expect(service.createIdentityCalls, 1);
  });

  testWidgets('import link navigates to ImportNsecScreen', (tester) async {
    final service = _RecordingIdentityService();

    await tester.pumpWidget(buildHarness(service: service));
    await tester.pumpAndSettle();

    await tester.tap(
      find.textContaining(OnboardingStrings.createIdentityImportLink),
    );
    await tester.pumpAndSettle();

    expect(find.byType(ImportNsecScreen), findsOneWidget);
  });
}

class _RecordingIdentityService implements IdentityService {
  _RecordingIdentityService({this.throwOnCreate = false});

  final bool throwOnCreate;
  int createIdentityCalls = 0;

  @override
  Future<Identity> createIdentity() async {
    createIdentityCalls++;
    if (throwOnCreate) {
      throw const IdentityServiceException('boom');
    }
    return Identity(
      pubkeyHex:
          '1111111111111111111111111111111111111111111111111111111111111111',
      npub: 'npub1stub',
      createdAt: DateTime(2025),
    );
  }

  @override
  Future<Identity?> getIdentity() async => null;

  @override
  Future<bool> hasIdentity() async => false;

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
