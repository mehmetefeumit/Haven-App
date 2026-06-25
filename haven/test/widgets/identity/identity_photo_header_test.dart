/// Widget tests for [IdentityPhotoHeader].
///
/// Covers avatar rendering (Image.memory only, never network), the E2E note,
/// the Edit Photo / Remove affordances (Remove gated on an existing avatar and
/// behind a confirmation), the full-screen-on-tap behaviour, and the
/// pick-and-set happy path (driven via the controller because the real photo
/// picker needs a platform channel unavailable in widget tests).
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/own_avatar_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/widgets/identity/avatar.dart';
import 'package:haven/src/widgets/identity/avatar_fullscreen_viewer.dart';
import 'package:haven/src/widgets/identity/identity_photo_header.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../mocks/mock_circle_service.dart';

final _fakeIdentity = Identity(
  pubkeyHex:
      'abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234',
  npub: 'npub1testtest0001',
  createdAt: DateTime(2024),
);

Widget _buildHeader({
  required MockCircleService circleService,
  Uint8List? thumbnailBytes,
  String? displayName = 'Alice',
}) {
  circleService.avatarThumbnailBytes = thumbnailBytes;

  return ProviderScope(
    overrides: [
      identityProvider.overrideWith((_) async => _fakeIdentity),
      displayNameProvider.overrideWith((_) async => displayName),
      ownAvatarProvider.overrideWith((_) async => thumbnailBytes),
      circleServiceProvider.overrideWithValue(circleService),
      // No circles -> the remove path skips relay publishing and goes
      // straight to the local clear, with nothing pending after the test.
      circlesProvider.overrideWith((_) async => const <Circle>[]),
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
      await tester.pumpWidget(
        _buildHeader(
          circleService: MockCircleService(),
          thumbnailBytes: jpegHeader,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(HavenAvatar), findsOneWidget);
      final images = tester.widgetList<Image>(find.byType(Image));
      for (final img in images) {
        expect(img.image, isNot(isA<NetworkImage>()));
      }
    });

    testWidgets('shows the "Edit Photo" action', (tester) async {
      await tester.pumpWidget(
        _buildHeader(circleService: MockCircleService()),
      );
      await tester.pumpAndSettle();

      expect(find.text('Edit Photo'), findsOneWidget);
    });

    testWidgets('shows the camera edit badge', (tester) async {
      await tester.pumpWidget(
        _buildHeader(circleService: MockCircleService()),
      );
      await tester.pumpAndSettle();

      expect(find.byIcon(LucideIcons.camera), findsOneWidget);
    });

    testWidgets('renders initials when no avatar bytes are present', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildHeader(circleService: MockCircleService(), displayName: 'Alice'),
      );
      await tester.pumpAndSettle();

      // Fallback initial from the display name.
      expect(find.text('A'), findsOneWidget);
    });

    testWidgets('"Remove" is hidden when no avatar is set', (tester) async {
      await tester.pumpWidget(
        _buildHeader(circleService: MockCircleService()),
      );
      await tester.pumpAndSettle();

      expect(find.text('Remove'), findsNothing);
    });

    testWidgets('"Remove" is shown when an avatar is set', (tester) async {
      final jpegHeader = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0]);
      await tester.pumpWidget(
        _buildHeader(
          circleService: MockCircleService(),
          thumbnailBytes: jpegHeader,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Remove'), findsOneWidget);
    });

    testWidgets(
      'Remove asks for confirmation, then clears the avatar on confirm',
      (tester) async {
        final jpegHeader = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0]);
        final svc = MockCircleService();
        await tester.pumpWidget(
          _buildHeader(circleService: svc, thumbnailBytes: jpegHeader),
        );
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

        expect(svc.clearMyAvatarCalled, isTrue);
        expect(find.text('Photo removed.'), findsOneWidget);
      },
    );

    testWidgets('Remove can be cancelled without clearing', (tester) async {
      final jpegHeader = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0]);
      final svc = MockCircleService();
      await tester.pumpWidget(
        _buildHeader(circleService: svc, thumbnailBytes: jpegHeader),
      );
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

      expect(svc.clearMyAvatarCalled, isFalse);
    });

    testWidgets('tapping the avatar opens the full-screen viewer', (
      tester,
    ) async {
      final jpegHeader = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0]);
      await tester.pumpWidget(
        _buildHeader(
          circleService: MockCircleService(),
          thumbnailBytes: jpegHeader,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byType(HavenAvatar));
      await tester.pumpAndSettle();

      expect(find.byType(AvatarFullscreenViewer), findsOneWidget);
      expect(find.byType(InteractiveViewer), findsOneWidget);
    });

    testWidgets(
      'pickAndSet via the controller calls setMyAvatar with bytes',
      (tester) async {
        // The real photo picker needs a platform channel, so the pick happy
        // path is driven directly through the controller (the same route the
        // Edit Photo button delegates to once the picker returns bytes). The
        // full picker glue is covered in avatar_picker_test.dart.
        final svc = MockCircleService();
        await tester.pumpWidget(_buildHeader(circleService: svc));
        await tester.pumpAndSettle();

        final container = ProviderScope.containerOf(
          tester.element(find.byType(IdentityPhotoHeader)),
        );
        final bytes = Uint8List.fromList([0x01, 0x02, 0x03, 0x04]);
        await container
            .read(ownAvatarControllerProvider.notifier)
            .pickAndSet(bytes);
        await tester.pump(Duration.zero);

        expect(svc.setMyAvatarCalledWithBytes, isNotNull);
        expect(svc.methodCalls, contains('setMyAvatar'));
      },
    );
  });
}
