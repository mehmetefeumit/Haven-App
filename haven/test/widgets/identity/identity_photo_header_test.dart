/// Widget tests for [IdentityPhotoHeader].
///
/// Covers avatar rendering (Image.memory only, never network), the Edit
/// Photo / Remove affordances (Remove gated on an existing avatar and behind
/// a confirmation), the full-screen-on-tap behaviour, that both Edit and
/// Remove are unconditional (saving is public-by-default, owner-directed
/// 2026-07-16 — there is no consent gate on either), and the Remove button's
/// own in-flight spinner. The full pick/set happy path (real picker + crop
/// glue) is covered in `avatar_picker_test.dart`, which also mounts this
/// widget. The header's local `_busy` state's independence from the
/// page-scoped `ProfileSyncStatusLine` (which this header no longer renders
/// — see [IdentityPhotoHeader]'s class doc) is covered where the two are
/// actually siblings, in `test/pages/identity_page_test.dart`.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/providers/identity_provider.dart';
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

  });

  group('IdentityPhotoHeader — remove-in-flight spinner (S7)', () {
    testWidgets(
      'shows a spinner in place of the Remove label while the retraction '
      'is in flight, and disables the picker actions until it resolves',
      (tester) async {
        final jpegHeader = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0]);
        final gate = Completer<void>();
        final svc = MockProfileService(
          ownProfile: Profile(
            pubkeyHex: _fakeIdentity.pubkeyHex,
            pictureBytes: jpegHeader,
            pictureHash: 'mock-hash',
          ),
        )..removeOwnAvatarGate = gate;

        await tester.pumpWidget(
          _buildHeader(thumbnailBytes: jpegHeader, profileService: svc),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.widgetWithText(TextButton, 'Remove'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.widgetWithText(TextButton, 'Remove'),
          ),
        );
        await tester.pump();
        // Lets the dialog's own 150ms dismiss transition finish so its
        // "Remove" button text is gone before asserting on the header's —
        // NOT pumpAndSettle: the header's own removal spinner (asserted
        // below) is indeterminate and would hang it.
        await tester.pump(const Duration(milliseconds: 200));

        // Removal is in flight (gated): the Remove label is replaced by a
        // spinner...
        final removeButton = find.ancestor(
          of: find.byIcon(LucideIcons.trash2),
          matching: find.byType(TextButton),
        );
        expect(find.text('Remove'), findsNothing);
        expect(
          find.descendant(
            of: removeButton,
            matching: find.byType(CircularProgressIndicator),
          ),
          findsOneWidget,
        );
        // ...both photo actions are disabled while `_busy`...
        expect(
          tester.widget<TextButton>(removeButton).onPressed,
          isNull,
          reason: '_busy must disable Remove itself while removing',
        );
        expect(
          tester
              .widget<TextButton>(
                find.widgetWithText(TextButton, 'Edit Photo'),
              )
              .onPressed,
          isNull,
          reason: '_busy must disable Edit Photo while removing',
        );

        gate.complete();
        await tester.pumpAndSettle();

        // The retraction resolved and cleared the avatar, so the whole
        // Remove control (spinner included) disappears — nothing is left
        // spinning forever.
        expect(
          svc.methodCalls.map((c) => c.method),
          contains('removeOwnAvatar'),
        );
        expect(find.text('Remove'), findsNothing);
        expect(find.byType(CircularProgressIndicator), findsNothing);
      },
    );
  });
}
