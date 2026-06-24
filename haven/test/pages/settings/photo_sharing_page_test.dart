/// Widget tests for [PhotoSharingPage].
///
/// This page holds only the avatar sharing controls — the §7.5 "Send my
/// avatar" / "Receive avatars" toggles and the M3 data-saver toggle. The
/// photo itself (set / view / remove) is exercised by the
/// `identity_photo_header_test.dart`, so the avatar/disclosure/change-remove
/// assertions live there, not here.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/pages/settings/photo_sharing_page.dart';
import 'package:haven/src/providers/avatar_data_saver_provider.dart';
import 'package:haven/src/providers/avatar_receive_provider.dart';
import 'package:haven/src/providers/avatar_send_provider.dart';
import 'package:haven/src/providers/own_avatar_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ---------------------------------------------------------------------------
// Build helper.
// ---------------------------------------------------------------------------

Widget _buildPage({
  Uint8List? thumbnailBytes,
  bool dataSaverEnabled = false,
  bool sendEnabled = true,
  bool receiveEnabled = true,
}) {
  return ProviderScope(
    overrides: [
      // Override ownAvatarProvider so hasAvatar is deterministic without the
      // identity -> circle-service -> thumbnail async chain.
      ownAvatarProvider.overrideWith((_) async => thumbnailBytes),
      avatarDataSaverProvider.overrideWith(
        (_) => _SeededDataSaverNotifier(enabled: dataSaverEnabled),
      ),
      avatarSendProvider.overrideWith(
        (_) => _SeededSendNotifier(enabled: sendEnabled),
      ),
      avatarReceiveProvider.overrideWith(
        (_) => _SeededReceiveNotifier(enabled: receiveEnabled),
      ),
    ],
    child: const MaterialApp(home: PhotoSharingPage()),
  );
}

// ---------------------------------------------------------------------------
// Seeded notifiers (test seams).
// ---------------------------------------------------------------------------

class _SeededDataSaverNotifier extends AvatarDataSaverNotifier {
  _SeededDataSaverNotifier({required bool enabled})
    : super(prefs: _DummyPrefs(seeded: enabled));
}

class _SeededSendNotifier extends AvatarSendNotifier {
  _SeededSendNotifier({required bool enabled})
    : super(prefs: _DummyPrefs(seeded: enabled));
}

class _SeededReceiveNotifier extends AvatarReceiveNotifier {
  _SeededReceiveNotifier({required bool enabled})
    : super(prefs: _DummyPrefs(seeded: enabled));
}

class _DummyPrefs implements SharedPreferences {
  _DummyPrefs({required this.seeded});

  final bool seeded;

  @override
  bool? getBool(String key) => seeded;

  @override
  Future<bool> setBool(String key, bool value) async => true;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PhotoSharingPage', () {
    testWidgets('shows the "Photo sharing" app bar title', (tester) async {
      await tester.pumpWidget(_buildPage());
      await tester.pump();
      expect(find.text('Photo sharing'), findsOneWidget);
    });

    testWidgets('shows the privacy caption', (tester) async {
      await tester.pumpWidget(_buildPage());
      await tester.pump();
      expect(
        find.textContaining('end-to-end encrypted'),
        findsOneWidget,
      );
    });
  });

  // -------------------------------------------------------------------------
  // §7.5: Privacy toggles
  // -------------------------------------------------------------------------

  group('PhotoSharingPage — §7.5 privacy toggles', () {
    testWidgets('shows "Send my avatar" and "Receive avatars" toggles', (
      tester,
    ) async {
      await tester.pumpWidget(_buildPage());
      await tester.pump();

      expect(find.text('Send my avatar'), findsOneWidget);
      expect(find.text('Receive avatars'), findsOneWidget);
    });

    testWidgets('"Send my avatar" toggle reflects enabled state', (
      tester,
    ) async {
      await tester.pumpWidget(_buildPage(sendEnabled: true));
      await tester.pump();

      final sendTile = tester.widget<SwitchListTile>(
        find.ancestor(
          of: find.text('Send my avatar'),
          matching: find.byType(SwitchListTile),
        ),
      );
      expect(sendTile.value, isTrue);
    });

    testWidgets('"Send my avatar" toggle reflects disabled state', (
      tester,
    ) async {
      await tester.pumpWidget(_buildPage(sendEnabled: false));
      await tester.pump();

      final sendTile = tester.widget<SwitchListTile>(
        find.ancestor(
          of: find.text('Send my avatar'),
          matching: find.byType(SwitchListTile),
        ),
      );
      expect(sendTile.value, isFalse);
    });

    testWidgets('"Receive avatars" toggle reflects enabled state', (
      tester,
    ) async {
      await tester.pumpWidget(_buildPage(receiveEnabled: true));
      await tester.pump();

      final receiveTile = tester.widget<SwitchListTile>(
        find.ancestor(
          of: find.text('Receive avatars'),
          matching: find.byType(SwitchListTile),
        ),
      );
      expect(receiveTile.value, isTrue);
    });

    testWidgets('"Receive avatars" toggle reflects disabled state', (
      tester,
    ) async {
      await tester.pumpWidget(_buildPage(receiveEnabled: false));
      await tester.pump();

      final receiveTile = tester.widget<SwitchListTile>(
        find.ancestor(
          of: find.text('Receive avatars'),
          matching: find.byType(SwitchListTile),
        ),
      );
      expect(receiveTile.value, isFalse);
    });

    testWidgets(
      'tapping "Send my avatar" toggle updates avatarSendProvider state',
      (tester) async {
        await tester.pumpWidget(_buildPage(sendEnabled: true));
        await tester.pump();

        await tester.tap(
          find.ancestor(
            of: find.text('Send my avatar'),
            matching: find.byType(SwitchListTile),
          ),
        );
        await tester.pump();

        final container = ProviderScope.containerOf(
          tester.element(find.byType(PhotoSharingPage)),
        );
        expect(
          container.read(avatarSendProvider),
          isFalse,
          reason: 'tapping send toggle must disable it',
        );
      },
    );

    testWidgets(
      'tapping "Receive avatars" toggle updates avatarReceiveProvider state',
      (tester) async {
        await tester.pumpWidget(_buildPage(receiveEnabled: true));
        await tester.pump();

        await tester.tap(
          find.ancestor(
            of: find.text('Receive avatars'),
            matching: find.byType(SwitchListTile),
          ),
        );
        await tester.pump();

        final container = ProviderScope.containerOf(
          tester.element(find.byType(PhotoSharingPage)),
        );
        expect(
          container.read(avatarReceiveProvider),
          isFalse,
          reason: 'tapping receive toggle must disable it',
        );
      },
    );

    testWidgets('"send enabled" subtitle is shown when send is on', (
      tester,
    ) async {
      await tester.pumpWidget(_buildPage(sendEnabled: true));
      await tester.pump();

      expect(find.textContaining('shared with circle members'), findsOneWidget);
    });

    testWidgets('"not sent to anyone" subtitle is shown when send is off', (
      tester,
    ) async {
      await tester.pumpWidget(_buildPage(sendEnabled: false));
      await tester.pump();

      expect(find.textContaining('not sent to anyone'), findsOneWidget);
    });

    testWidgets('"photos are shown" subtitle is shown when receive is on', (
      tester,
    ) async {
      await tester.pumpWidget(_buildPage(receiveEnabled: true));
      await tester.pump();

      expect(find.textContaining('photos are shown'), findsOneWidget);
    });

    testWidgets(
      '"not downloaded or stored" subtitle is shown when receive is off',
      (tester) async {
        await tester.pumpWidget(_buildPage(receiveEnabled: false));
        await tester.pump();

        expect(find.textContaining('not downloaded or stored'), findsOneWidget);
      },
    );
  });

  // -------------------------------------------------------------------------
  // M3: Data-saver toggle
  // -------------------------------------------------------------------------

  group('PhotoSharingPage — M3 data-saver card', () {
    final jpegHeader = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0]);

    testWidgets('data-saver card is hidden when no avatar is set', (
      tester,
    ) async {
      await tester.pumpWidget(_buildPage());
      await tester.pump();

      expect(
        find.text('Data saver'),
        findsNothing,
        reason: 'data-saver card must be hidden when no avatar exists',
      );
    });

    testWidgets('data-saver card is visible when an avatar is set', (
      tester,
    ) async {
      await tester.pumpWidget(_buildPage(thumbnailBytes: jpegHeader));
      await tester.pump();
      await tester.pumpAndSettle();

      expect(
        find.text('Data saver'),
        findsOneWidget,
        reason: 'data-saver card must appear once an avatar exists',
      );
    });

    testWidgets('shows "every 24 hours" subtitle when data-saver is off', (
      tester,
    ) async {
      await tester.pumpWidget(_buildPage(thumbnailBytes: jpegHeader));
      await tester.pump();
      await tester.pumpAndSettle();

      expect(find.textContaining('24 hours'), findsOneWidget);
    });

    testWidgets('shows "every 3 days" subtitle when data-saver is on', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildPage(thumbnailBytes: jpegHeader, dataSaverEnabled: true),
      );
      await tester.pump();
      await tester.pumpAndSettle();

      expect(find.textContaining('3 days'), findsOneWidget);
    });

    testWidgets('SwitchListTile reflects data-saver off state', (tester) async {
      await tester.pumpWidget(_buildPage(thumbnailBytes: jpegHeader));
      await tester.pump();
      await tester.pumpAndSettle();

      final dataSaverTile = tester.widget<SwitchListTile>(
        find.ancestor(
          of: find.text('Data saver'),
          matching: find.byType(SwitchListTile),
        ),
      );
      expect(dataSaverTile.value, isFalse);
    });

    testWidgets('SwitchListTile reflects data-saver on state', (tester) async {
      await tester.pumpWidget(
        _buildPage(thumbnailBytes: jpegHeader, dataSaverEnabled: true),
      );
      await tester.pump();
      await tester.pumpAndSettle();

      final dataSaverTile = tester.widget<SwitchListTile>(
        find.ancestor(
          of: find.text('Data saver'),
          matching: find.byType(SwitchListTile),
        ),
      );
      expect(dataSaverTile.value, isTrue);
    });

    testWidgets(
      'tapping the data-saver switch calls setEnabled on the notifier',
      (tester) async {
        await tester.pumpWidget(_buildPage(thumbnailBytes: jpegHeader));
        await tester.pump();
        await tester.pumpAndSettle();

        await tester.tap(
          find.ancestor(
            of: find.text('Data saver'),
            matching: find.byType(SwitchListTile),
          ),
        );
        await tester.pump();

        final container = ProviderScope.containerOf(
          tester.element(find.byType(PhotoSharingPage)),
        );
        expect(
          container.read(avatarDataSaverProvider),
          isTrue,
          reason: 'tapping data-saver toggle must update the provider state',
        );
      },
    );
  });
}
