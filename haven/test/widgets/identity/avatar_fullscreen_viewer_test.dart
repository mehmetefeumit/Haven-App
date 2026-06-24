/// Widget tests for [AvatarFullscreenViewer] and [showAvatarFullscreen].
///
/// Verifies the viewer renders from in-memory bytes only (never a network
/// URL), is pinch-zoomable, has a decode-failure fallback, and is dismissable
/// via its close button.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/widgets/identity/avatar_fullscreen_viewer.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

void main() {
  final bytes = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0]);

  group('AvatarFullscreenViewer', () {
    testWidgets('renders an InteractiveViewer with a MemoryImage', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(home: AvatarFullscreenViewer(imageBytes: bytes)),
      );

      expect(find.byType(InteractiveViewer), findsOneWidget);

      final image = tester.widget<Image>(find.byType(Image));
      expect(
        image.image,
        isA<MemoryImage>(),
        reason: 'fullscreen viewer must render bytes via Image.memory',
      );
      expect(
        image.image,
        isNot(isA<NetworkImage>()),
        reason: 'fullscreen viewer must never use NetworkImage',
      );
    });

    testWidgets('Image has a decode-failure errorBuilder', (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: AvatarFullscreenViewer(imageBytes: bytes)),
      );

      final image = tester.widget<Image>(find.byType(Image));
      expect(
        image.errorBuilder,
        isNotNull,
        reason: 'a decode failure must fall back rather than show a void',
      );
    });

    testWidgets('has a close button', (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: AvatarFullscreenViewer(imageBytes: bytes)),
      );

      expect(find.byIcon(LucideIcons.x), findsOneWidget);
      expect(find.byTooltip('Close'), findsOneWidget);
    });
  });

  group('showAvatarFullscreen', () {
    testWidgets('pushes the viewer and the close button dismisses it', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => showAvatarFullscreen(context, bytes),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byType(AvatarFullscreenViewer), findsOneWidget);

      await tester.tap(find.byIcon(LucideIcons.x));
      await tester.pumpAndSettle();
      expect(find.byType(AvatarFullscreenViewer), findsNothing);
    });
  });
}
