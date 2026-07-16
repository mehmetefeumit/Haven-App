/// Tests for IdentityPage.
///
/// The substantive widget-level tests for the photo header, display-name
/// card, and QR page live in their own files; this file keeps the cheap
/// `NpubQrCode` value checks plus a smoke test that locks the consolidated
/// Identity-page structure (photo header, the combined public-profile
/// disclosure notice, display name, and the QR / Photo-sharing / Advanced
/// subpage entries). Publishing is public-by-default and unconditional
/// (owner-directed 2026-07-16) — there is no Public Profile toggle to test.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/pages/identity_page.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/widgets/identity/display_name_card.dart';
import 'package:haven/src/widgets/identity/identity_photo_header.dart';
import 'package:haven/src/widgets/identity/npub_qr_code.dart';
import 'package:haven/src/widgets/identity/public_profile_notice.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../mocks/mock_profile_service.dart';

class _FakeIdentityService implements IdentityService {
  static final _identity = Identity(
    pubkeyHex:
        'abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234',
    npub: 'npub1testtest0001',
    createdAt: DateTime(2024),
  );

  @override
  Future<bool> hasIdentity() async => true;

  @override
  Future<Identity?> getIdentity() async => _identity;

  @override
  Future<Identity> createIdentity() => throw UnimplementedError();

  @override
  Future<Identity> importFromNsec(String nsec) => throw UnimplementedError();

  @override
  Future<String> exportNsec() => throw UnimplementedError();

  @override
  Future<String> sign(Uint8List messageHash) => throw UnimplementedError();

  @override
  Future<String> getPubkeyHex() async => _identity.pubkeyHex;

  @override
  Future<List<int>> getSecretBytes() => throw UnimplementedError();

  @override
  Future<void> deleteIdentity() async {}

  @override
  Future<String?> getDisplayName() async => 'Alice';

  @override
  Future<void> setDisplayName(String? name) async {}

  @override
  Future<void> clearCache() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('IdentityPage support types', () {
    testWidgets('NpubQrCode encodes nostr: URI prefix', (tester) async {
      const npub =
          'npub1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqspcd5tr';
      const widget = NpubQrCode(npub: npub);
      expect(widget.qrData, equals('nostr:$npub'));
    });

    testWidgets('NpubQrSize enum has expected dimensions', (tester) async {
      expect(NpubQrSize.small.dimension, 150);
      expect(NpubQrSize.medium.dimension, 200);
      expect(NpubQrSize.large.dimension, 280);
    });
  });

  group('IdentityPage structure', () {
    Widget build({MockProfileService? profileService}) => ProviderScope(
      overrides: [
        identityServiceProvider.overrideWithValue(_FakeIdentityService()),
        // No profile/avatar set — the header shows initials and hides
        // Remove.
        profileServiceProvider.overrideWithValue(
          profileService ?? MockProfileService(),
        ),
      ],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: IdentityPage(),
      ),
    );

    testWidgets('renders the photo header and display-name card', (
      tester,
    ) async {
      await tester.pumpWidget(build());
      await tester.pumpAndSettle();

      expect(find.byType(IdentityPhotoHeader), findsOneWidget);
      expect(find.byType(DisplayNameCard), findsOneWidget);
    });

    testWidgets(
      'shows the combined public-profile disclosure notice',
      (tester) async {
        await tester.pumpWidget(build());
        await tester.pumpAndSettle();

        expect(find.byType(PublicProfileNotice), findsOneWidget);
        expect(find.text('Profile is public'), findsOneWidget);
      },
    );

    testWidgets(
      'never shows a Public Profile toggle — publishing is unconditional',
      (tester) async {
        await tester.pumpWidget(build());
        await tester.pumpAndSettle();

        expect(find.byType(SwitchListTile), findsNothing);
        expect(find.text('Public Profile'), findsNothing);
      },
    );

    testWidgets('lists the Public Key QR and Advanced entries', (
      tester,
    ) async {
      await tester.pumpWidget(build());
      await tester.pumpAndSettle();

      expect(find.text('Public Key QR'), findsOneWidget);
      expect(
        find.text('Photo sharing'),
        findsNothing,
        reason: 'photo-sharing settings were removed',
      );
      expect(find.text('Advanced'), findsOneWidget);
    });

    testWidgets('shows the refresh action in the app bar', (tester) async {
      await tester.pumpWidget(build());
      await tester.pumpAndSettle();

      expect(find.byKey(WidgetKeys.identityRefreshButton), findsOneWidget);
    });
  });
}
