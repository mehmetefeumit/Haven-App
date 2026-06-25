/// Widget tests for [CreateIdentityScreen].
library;

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/pages/onboarding/create_identity_screen.dart';
import 'package:haven/src/pages/onboarding/import_nsec_screen.dart';
import 'package:haven/src/providers/onboarding_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/identity_service.dart';

import '../../helpers/localized_app_harness.dart';
import '../../mocks/mock_circle_service.dart';
import '../../mocks/mock_relay_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  List<Override> buildOverrides({required _RecordingIdentityService service}) {
    return [
      identityServiceProvider.overrideWithValue(service),
      onboardingControllerProvider.overrideWith(
        (ref) => OnboardingController(OnboardingFlags.none),
      ),
      circleServiceProvider.overrideWithValue(MockCircleService()),
      relayServiceProvider.overrideWithValue(MockRelayService()),
    ];
  }

  testWidgets('renders title, body, warning, CTA and import link', (
    tester,
  ) async {
    final service = _RecordingIdentityService();

    await pumpLocalized(
      tester,
      const CreateIdentityScreen(),
      overrides: buildOverrides(service: service),
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
    expect(find.text('Create My Identity'), findsOneWidget);
    expect(find.textContaining('Import it instead'), findsOneWidget);
  });

  testWidgets('tapping the primary CTA invokes createIdentity', (tester) async {
    final service = _RecordingIdentityService();

    await pumpLocalized(
      tester,
      const CreateIdentityScreen(),
      overrides: buildOverrides(service: service),
    );

    await tester.tap(find.text('Create My Identity'));
    // Success leaves background work fire-and-forget; bounded pump avoids
    // a pumpAndSettle hang on the spinner.
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(service.createIdentityCalls, 1);
  });

  testWidgets('service failure surfaces a snackbar', (tester) async {
    final service = _RecordingIdentityService(throwOnCreate: true);

    await pumpLocalized(
      tester,
      const CreateIdentityScreen(),
      overrides: buildOverrides(service: service),
    );

    await tester.tap(find.text('Create My Identity'));
    await tester.pump();
    await tester.pump();

    expect(
      find.text(
        'Something went wrong creating your identity. Please try again.',
      ),
      findsOneWidget,
    );
    expect(service.createIdentityCalls, 1);
  });

  testWidgets('import link navigates to ImportNsecScreen', (tester) async {
    final service = _RecordingIdentityService();

    await pumpLocalized(
      tester,
      const CreateIdentityScreen(),
      overrides: buildOverrides(service: service),
    );

    await tester.tap(find.textContaining('Import it instead'));
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
