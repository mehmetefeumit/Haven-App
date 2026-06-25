/// Widget tests for [QrCodePage].
///
/// Verifies the page shows the QR code, the npub as selectable text, and a
/// copy affordance, and that it handles the loading / error / no-identity
/// branches gracefully (never a raw error, never a broken QR).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/pages/settings/qr_code_page.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/widgets/identity/npub_qr_code.dart';

const _testNpub = 'npub1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqspcd5tr';

final _fakeIdentity = Identity(
  pubkeyHex:
      'abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234',
  npub: _testNpub,
  createdAt: DateTime(2024),
);

Widget _build({
  Identity? identity,
  bool loading = false,
  bool error = false,
}) {
  return ProviderScope(
    overrides: [
      identityProvider.overrideWith((_) {
        if (loading) return Completer<Identity?>().future;
        if (error) return Future<Identity?>.error(Exception('boom'));
        return Future<Identity?>.value(identity);
      }),
    ],
    child: const MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: QrCodePage(),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('QrCodePage', () {
    testWidgets('shows the "Public Key QR" app bar title', (tester) async {
      await tester.pumpWidget(_build(identity: _fakeIdentity));
      await tester.pumpAndSettle();
      expect(find.text('Public Key QR'), findsOneWidget);
    });

    testWidgets('explains the public key in plain language (mentions Nostr)', (
      tester,
    ) async {
      await tester.pumpWidget(_build(identity: _fakeIdentity));
      await tester.pumpAndSettle();
      expect(find.text('What is this?'), findsOneWidget);
      expect(find.textContaining('Nostr'), findsOneWidget);
      expect(find.textContaining('safe to share'), findsOneWidget);
    });

    testWidgets('renders the QR code', (tester) async {
      await tester.pumpWidget(_build(identity: _fakeIdentity));
      await tester.pumpAndSettle();
      expect(find.byType(NpubQrCode), findsOneWidget);
    });

    testWidgets('shows the npub as selectable text', (tester) async {
      await tester.pumpWidget(_build(identity: _fakeIdentity));
      await tester.pumpAndSettle();

      final selectable = tester.widget<SelectableText>(
        find.byType(SelectableText),
      );
      expect(selectable.data, equals(_testNpub));
    });

    testWidgets('shows a copy affordance', (tester) async {
      await tester.pumpWidget(_build(identity: _fakeIdentity));
      await tester.pumpAndSettle();
      expect(
        find.widgetWithText(TextButton, 'Copy public key'),
        findsOneWidget,
      );
    });

    testWidgets('never renders a NetworkImage', (tester) async {
      await tester.pumpWidget(_build(identity: _fakeIdentity));
      await tester.pumpAndSettle();
      final images = tester.widgetList<Image>(find.byType(Image));
      for (final img in images) {
        expect(img.image, isNot(isA<NetworkImage>()));
      }
    });

    testWidgets('shows a loading indicator while identity resolves', (
      tester,
    ) async {
      await tester.pumpWidget(_build(loading: true));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('shows a generic message on error (no raw error)', (
      tester,
    ) async {
      await tester.pumpWidget(_build(error: true));
      await tester.pumpAndSettle();
      expect(find.textContaining('public key'), findsOneWidget);
      expect(find.textContaining('boom'), findsNothing);
      expect(find.byType(NpubQrCode), findsNothing);
    });

    testWidgets('shows a "No identity" message when identity is null', (
      tester,
    ) async {
      await tester.pumpWidget(_build());
      await tester.pumpAndSettle();
      expect(find.textContaining('No identity'), findsOneWidget);
      expect(find.byType(NpubQrCode), findsNothing);
    });
  });
}
