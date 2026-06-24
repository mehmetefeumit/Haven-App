/// Tests for the own-avatar pick flow in `avatar_picker.dart`.
///
/// The flow opens the permission-free system photo picker directly — there is
/// no `permission_handler` gate and no "open settings" dead-end. These tests
/// drive the real glue (`pickAndSetOwnAvatar`) end-to-end through a fake
/// [ImagePickerPlatform], plus a source-level regression guard that fails the
/// build if a runtime photo permission is ever reintroduced.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/own_avatar_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/widgets/identity/identity_photo_header.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import '../../mocks/mock_circle_service.dart';

/// A fake [ImagePickerPlatform] that returns a canned [XFile] (or throws)
/// without touching any platform channel, so the pick glue is testable.
///
/// [MockPlatformInterfaceMixin] bypasses the platform-interface verification
/// token, which the `ImagePickerPlatform.instance` setter otherwise enforces.
class _FakeImagePicker extends ImagePickerPlatform
    with MockPlatformInterfaceMixin {
  _FakeImagePicker({this.result, this.throwError = false});

  /// The file the picker hands back (null models a user cancellation).
  final XFile? result;

  /// When true, [getImageFromSource] throws to model a picker failure.
  final bool throwError;

  int callCount = 0;
  ImageSource? lastSource;
  bool? lastRequestFullMetadata;

  @override
  Future<XFile?> getImageFromSource({
    required ImageSource source,
    ImagePickerOptions options = const ImagePickerOptions(),
  }) async {
    callCount++;
    lastSource = source;
    lastRequestFullMetadata = options.requestFullMetadata;
    if (throwError) {
      throw Exception('picker failure');
    }
    return result;
  }
}

final _fakeIdentity = Identity(
  pubkeyHex:
      'abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234',
  npub: 'npub1testtest0001',
  createdAt: DateTime(2024),
);

Widget _buildHeader(MockCircleService circleService) {
  return ProviderScope(
    overrides: [
      identityProvider.overrideWith((_) async => _fakeIdentity),
      displayNameProvider.overrideWith((_) async => 'Alice'),
      ownAvatarProvider.overrideWith((_) async => null),
      circleServiceProvider.overrideWithValue(circleService),
      // No circles -> pickAndSet's best-effort publish loop has nothing to do.
      circlesProvider.overrideWith((_) async => const <Circle>[]),
    ],
    child: const MaterialApp(
      home: Scaffold(body: IdentityPhotoHeader()),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ImagePickerPlatform.instance is a process-global; capture the default and
  // restore it after every test so a fake never leaks into another test.
  late final ImagePickerPlatform originalImagePicker;
  setUpAll(() => originalImagePicker = ImagePickerPlatform.instance);
  tearDown(() => ImagePickerPlatform.instance = originalImagePicker);

  group('pickAndSetOwnAvatar (system picker, no permission gate)', () {
    testWidgets(
      'a picked image flows to setMyAvatar and shows the success SnackBar',
      (tester) async {
        final jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0x01, 0x02]);
        final fake = _FakeImagePicker(
          result: XFile.fromData(jpeg, mimeType: 'image/jpeg', name: 'p.jpg'),
        );
        ImagePickerPlatform.instance = fake;

        final svc = MockCircleService();
        await tester.pumpWidget(_buildHeader(svc));
        await tester.pumpAndSettle();

        await tester.tap(find.widgetWithText(TextButton, 'Edit Photo'));
        await tester.pumpAndSettle();

        // The picker was opened for the gallery, without requesting full
        // EXIF/location metadata.
        expect(fake.callCount, 1);
        expect(fake.lastSource, ImageSource.gallery);
        expect(fake.lastRequestFullMetadata, isFalse);

        // The chosen bytes reached the controller -> circle service.
        expect(svc.setMyAvatarCalledWithBytes, isNotNull);
        expect(svc.setMyAvatarCalledWithBytes, equals(jpeg));
        expect(svc.methodCalls, contains('setMyAvatar'));

        expect(
          find.textContaining('Photo updated'),
          findsOneWidget,
        );
      },
    );

    testWidgets('cancelling the picker sets nothing and shows no SnackBar', (
      tester,
    ) async {
      final fake = _FakeImagePicker(); // result == null -> cancelled
      ImagePickerPlatform.instance = fake;

      final svc = MockCircleService();
      await tester.pumpWidget(_buildHeader(svc));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(TextButton, 'Edit Photo'));
      await tester.pumpAndSettle();

      expect(fake.callCount, 1);
      expect(svc.setMyAvatarCalledWithBytes, isNull);
      expect(svc.methodCalls, isNot(contains('setMyAvatar')));
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets(
      'a picker failure shows a generic SnackBar and never sets an avatar',
      (tester) async {
        final fake = _FakeImagePicker(throwError: true);
        ImagePickerPlatform.instance = fake;

        final svc = MockCircleService();
        await tester.pumpWidget(_buildHeader(svc));
        await tester.pumpAndSettle();

        await tester.tap(find.widgetWithText(TextButton, 'Edit Photo'));
        await tester.pumpAndSettle();

        expect(svc.setMyAvatarCalledWithBytes, isNull);
        expect(
          find.textContaining('Could not update your photo'),
          findsOneWidget,
        );
      },
    );
  });

  group('avatar_picker source regression guard', () {
    String readSource() => File(
      'lib/src/widgets/identity/avatar_picker.dart',
    ).readAsStringSync();

    test('does not reintroduce a runtime photo permission gate', () {
      final source = readSource();
      expect(
        source.contains('permission_handler'),
        isFalse,
        reason: 'The system photo picker is permission-free; reintroducing '
            'permission_handler re-creates the Android settings dead-end.',
      );
      expect(source.contains('Permission.photos'), isFalse);
      expect(source.contains('openAppSettings'), isFalse);
      expect(source.contains('_showPermissionDeniedSheet'), isFalse);
    });

    test('still drops EXIF/location metadata at the pick boundary', () {
      expect(readSource().contains('requestFullMetadata: false'), isTrue);
    });
  });
}
