/// Widget tests for [ImportNsecScreen].
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/pages/onboarding/import_nsec_screen.dart';
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
      circleServiceProvider.overrideWithValue(MockCircleService()),
      relayServiceProvider.overrideWithValue(MockRelayService()),
    ];
  }

  testWidgets('renders title, body, hint and CTA', (tester) async {
    final service = _RecordingIdentityService();

    await pumpLocalized(
      tester,
      const ImportNsecScreen(),
      overrides: buildOverrides(service: service),
    );

    expect(find.text('Import your existing key'), findsOneWidget);
    expect(
      find.text(
        'Paste the secret key you backed up from another '
        'Haven-compatible app.',
      ),
      findsOneWidget,
    );
    expect(find.text('Import'), findsOneWidget);
    expect(find.text('nsec1…'), findsOneWidget);
  });

  testWidgets(
    'empty input shows invalid-format error and does not call service',
    (tester) async {
      final service = _RecordingIdentityService();

      await pumpLocalized(
        tester,
        const ImportNsecScreen(),
        overrides: buildOverrides(service: service),
      );

      await tester.tap(find.text('Import'));
      await tester.pump();

      expect(
        find.text(
          'That doesn’t look like a valid backup key. '
          'Please check and try again.',
        ),
        findsOneWidget,
      );
      expect(service.importCalls, isEmpty);
    },
  );

  testWidgets(
    'input that does not start with nsec1 shows invalid-format error',
    (tester) async {
      final service = _RecordingIdentityService();

      await pumpLocalized(
        tester,
        const ImportNsecScreen(),
        overrides: buildOverrides(service: service),
      );

      await tester.enterText(find.byType(TextField), 'npub1somethingsomething');
      await tester.tap(find.text('Import'));
      await tester.pump();

      expect(
        find.text(
          'That doesn’t look like a valid backup key. '
          'Please check and try again.',
        ),
        findsOneWidget,
      );
      expect(service.importCalls, isEmpty);
    },
  );

  testWidgets('valid-looking nsec calls importFromNsec', (tester) async {
    final service = _RecordingIdentityService();

    await pumpLocalized(
      tester,
      const ImportNsecScreen(),
      overrides: buildOverrides(service: service),
    );

    const validLooking = 'nsec1abcdefghij';
    await tester.enterText(find.byType(TextField), validLooking);
    await tester.tap(find.text('Import'));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(service.importCalls, [validLooking]);
  });

  testWidgets('service failure surfaces the generic import error', (
    tester,
  ) async {
    final service = _RecordingIdentityService(throwOnImport: true);

    await pumpLocalized(
      tester,
      const ImportNsecScreen(),
      overrides: buildOverrides(service: service),
    );

    await tester.enterText(find.byType(TextField), 'nsec1abcdefghij');
    await tester.tap(find.text('Import'));
    await tester.pump();
    await tester.pump();

    expect(
      find.text('We couldn’t import that key. Please check and try again.'),
      findsOneWidget,
    );
    expect(service.importCalls, ['nsec1abcdefghij']);
  });
}

class _RecordingIdentityService implements IdentityService {
  _RecordingIdentityService({this.throwOnImport = false});

  final bool throwOnImport;
  final List<String> importCalls = [];

  @override
  Future<Identity> importFromNsec(String nsec) async {
    importCalls.add(nsec);
    if (throwOnImport) {
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
  Future<Identity> createIdentity() async => throw UnimplementedError();

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
