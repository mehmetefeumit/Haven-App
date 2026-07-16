/// Widget tests for [IdentityPhotoHeader].
///
/// Covers avatar rendering (Image.memory only, never network), the Edit
/// Photo / Remove affordances (Remove gated on an existing avatar and behind
/// a confirmation), the full-screen-on-tap behaviour, and that both Edit and
/// Remove are unconditional (publishing is public-by-default, owner-directed
/// 2026-07-16 — there is no consent gate on either). The pick-and-set happy
/// path is driven via the controller because the real photo picker needs a
/// platform channel unavailable in widget tests — the full picker glue is
/// covered in `avatar_picker_test.dart`.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/own_profile_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/services/profile_service.dart';
import 'package:haven/src/widgets/identity/avatar.dart';
import 'package:haven/src/widgets/identity/avatar_fullscreen_viewer.dart';
import 'package:haven/src/widgets/identity/identity_photo_header.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../mocks/mock_profile_service.dart';

final _fakeIdentity = Identity(
  pubkeyHex:
      'abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234',
  npub: 'npub1testtest0001',
  createdAt: DateTime(2024),
);

Widget _buildHeader({
  Uint8List? thumbnailBytes,
  String? displayName = 'Alice',
  MockProfileService? profileService,
}) {
  final svc =
      profileService ??
      MockProfileService(
        ownProfile: Profile(
          pubkeyHex: _fakeIdentity.pubkeyHex,
          pictureBytes: thumbnailBytes,
          pictureHash: thumbnailBytes != null ? 'mock-hash' : null,
        ),
      );

  return ProviderScope(
    overrides: [
      identityProvider.overrideWith((_) async => _fakeIdentity),
      displayNameProvider.overrideWith((_) async => displayName),
      profileServiceProvider.overrideWithValue(svc),
    ],
    child: const MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: IdentityPhotoHeader()),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('IdentityPhotoHeader', () {
    testWidgets('renders a HavenAvatar and never a NetworkImage', (
      tester,
    ) async {
      final jpegHeader = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0]);
      await tester.pumpWidget(_buildHeader(thumbnailBytes: jpegHeader));
      await tester.pumpAndSettle();

      expect(find.byType(HavenAvatar), findsOneWidget);
      final images = tester.widgetList<Image>(find.byType(Image));
      for (final img in images) {
        expect(img.image, isNot(isA<NetworkImage>()));
      }
    });

    testWidgets('shows the "Edit Photo" action', (tester) async {
      await tester.pumpWidget(_buildHeader());
      await tester.pumpAndSettle();

      expect(find.text('Edit Photo'), findsOneWidget);
    });

    testWidgets('shows the camera edit badge', (tester) async {
      await tester.pumpWidget(_buildHeader());
      await tester.pumpAndSettle();

      expect(find.byIcon(LucideIcons.camera), findsOneWidget);
    });

    testWidgets(
      'the change-photo badge has an at-least-48dp tap target (#4, WCAG '
      '2.5.5)',
      (tester) async {
        await tester.pumpWidget(_buildHeader());
        await tester.pumpAndSettle();

        final badgeInkWell = find.ancestor(
          of: find.byIcon(LucideIcons.camera),
          matching: find.byType(InkWell),
        );
        final size = tester.getSize(badgeInkWell);

        expect(
          size.width,
          greaterThanOrEqualTo(48),
          reason:
              "The badge's visual accent stays small, but its tappable "
              'InkWell must be at least the WCAG-minimum 48dp square.',
        );
        expect(size.height, greaterThanOrEqualTo(48));
      },
    );

    testWidgets('renders initials when no avatar bytes are present', (
      tester,
    ) async {
      await tester.pumpWidget(_buildHeader());
      await tester.pumpAndSettle();

      // Fallback initial from the display name.
      expect(find.text('A'), findsOneWidget);
    });

    testWidgets('"Remove" is hidden when no avatar is set', (tester) async {
      await tester.pumpWidget(_buildHeader());
      await tester.pumpAndSettle();

      expect(find.text('Remove'), findsNothing);
    });

    testWidgets('"Remove" is shown when an avatar is set', (tester) async {
      final jpegHeader = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0]);
      await tester.pumpWidget(_buildHeader(thumbnailBytes: jpegHeader));
      await tester.pumpAndSettle();

      expect(find.text('Remove'), findsOneWidget);
    });

    testWidgets(
      'Remove asks for confirmation, then clears the avatar on confirm',
      (tester) async {
        final jpegHeader = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0]);
        final svc = MockProfileService(
          ownProfile: Profile(
            pubkeyHex: _fakeIdentity.pubkeyHex,
            pictureBytes: jpegHeader,
            pictureHash: 'mock-hash',
          ),
        );
        await tester.pumpWidget(_buildHeader(profileService: svc));
        await tester.pumpAndSettle();

        // Tap the header Remove button -> confirmation dialog.
        await tester.tap(find.widgetWithText(TextButton, 'Remove'));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(find.text('Remove profile photo?'), findsOneWidget);

        // Confirm in the dialog.
        await tester.tap(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.widgetWithText(TextButton, 'Remove'),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(
          svc.methodCalls.map((c) => c.method),
          contains('removeOwnAvatar'),
        );
        expect(find.text('Photo removed.'), findsOneWidget);
      },
    );

    testWidgets('Remove can be cancelled without clearing', (tester) async {
      final jpegHeader = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0]);
      final svc = MockProfileService(
        ownProfile: Profile(
          pubkeyHex: _fakeIdentity.pubkeyHex,
          pictureBytes: jpegHeader,
          pictureHash: 'mock-hash',
        ),
      );
      await tester.pumpWidget(_buildHeader(profileService: svc));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(TextButton, 'Remove'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(TextButton, 'Cancel'),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        svc.methodCalls.map((c) => c.method),
        isNot(contains('removeOwnAvatar')),
      );
    });

    testWidgets(
      'Remove proceeds with no consent dialog (publishing is unconditional)',
      (tester) async {
        final jpegHeader = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0]);
        final svc = MockProfileService(
          ownProfile: Profile(
            pubkeyHex: _fakeIdentity.pubkeyHex,
            pictureBytes: jpegHeader,
            pictureHash: 'mock-hash',
          ),
        );
        await tester.pumpWidget(_buildHeader(profileService: svc));
        await tester.pumpAndSettle();

        await tester.tap(find.widgetWithText(TextButton, 'Remove'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.widgetWithText(TextButton, 'Remove'),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          svc.methodCalls.map((c) => c.method),
          contains('removeOwnAvatar'),
          reason: 'Retraction proceeds with only the destructive-confirm '
              'dialog — there is no separate consent gate '
              '(public-by-default, owner-directed 2026-07-16).',
        );
        expect(find.byType(AlertDialog), findsNothing);
      },
    );

    testWidgets('tapping the avatar opens the full-screen viewer', (
      tester,
    ) async {
      final jpegHeader = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0]);
      await tester.pumpWidget(_buildHeader(thumbnailBytes: jpegHeader));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(HavenAvatar));
      await tester.pumpAndSettle();

      expect(find.byType(AvatarFullscreenViewer), findsOneWidget);
      expect(find.byType(InteractiveViewer), findsOneWidget);
    });

    testWidgets(
      'pickAndSet via the controller calls setOwnAvatar with bytes',
      (tester) async {
        // The real photo picker needs a platform channel, so the pick happy
        // path is driven directly through the controller (the same route
        // the Edit Photo button delegates to once the picker returns
        // bytes). The full picker glue — including that tapping Edit Photo
        // goes straight to the picker with no consent dialog in front of it
        // — is covered end-to-end in avatar_picker_test.dart.
        final svc = MockProfileService();
        await tester.pumpWidget(_buildHeader(profileService: svc));
        await tester.pumpAndSettle();

        final container = ProviderScope.containerOf(
          tester.element(find.byType(IdentityPhotoHeader)),
        );
        final bytes = Uint8List.fromList([0x01, 0x02, 0x03, 0x04]);
        await container
            .read(ownProfileControllerProvider.notifier)
            .setAvatar(bytes);
        await tester.pump(Duration.zero);

        expect(
          svc.methodCalls.map((c) => c.method),
          contains('setOwnAvatar'),
        );
      },
    );
  });
}
