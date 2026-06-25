/// Tests for the own-avatar pick → crop → set flow in `avatar_picker.dart`.
///
/// The flow opens the permission-free system photo picker, then a square-locked
/// crop/rotate editor, and only sets the avatar once the user confirms the crop.
/// These tests drive the real glue (`pickAndSetOwnAvatar`) end-to-end through a
/// fake [ImagePickerPlatform] and a fake [ImageCropperPlatform], plus a
/// source-level regression guard that fails the build if a runtime photo
/// permission is ever reintroduced.
library;

import 'dart:io';
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
import 'package:haven/src/widgets/identity/identity_photo_header.dart';
import 'package:image_cropper_platform_interface/image_cropper_platform_interface.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import '../../mocks/mock_circle_service.dart';

/// A fake [ImagePickerPlatform] that returns a canned [XFile] (or throws)
/// without touching any platform channel, so the pick glue is testable.
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
    if (throwError) throw Exception('picker failure');
    return result;
  }
}

/// A fake [ImageCropperPlatform] that returns a canned [CroppedFile] (or
/// throws) without launching the native crop UI.
class _FakeImageCropper extends ImageCropperPlatform
    with MockPlatformInterfaceMixin {
  _FakeImageCropper({this.result, this.throwError = false});

  /// The cropped file the editor returns (null models a user cancellation).
  final CroppedFile? result;

  /// When true, [cropImage] throws to model an editor failure.
  final bool throwError;

  int callCount = 0;
  CropAspectRatio? lastAspectRatio;
  String? lastSourcePath;

  @override
  Future<CroppedFile?> cropImage({
    required String sourcePath,
    int? maxWidth,
    int? maxHeight,
    CropAspectRatio? aspectRatio,
    ImageCompressFormat compressFormat = ImageCompressFormat.jpg,
    int compressQuality = 90,
    List<PlatformUiSettings>? uiSettings,
  }) async {
    callCount++;
    lastSourcePath = sourcePath;
    lastAspectRatio = aspectRatio;
    if (throwError) throw Exception('cropper failure');
    return result;
  }
}

final _fakeIdentity = Identity(
  pubkeyHex:
      'abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234',
  npub: 'npub1testtest0001',
  createdAt: DateTime(2024),
);

/// A minimal JPEG-ish byte string. The mock services never decode it, so the
/// exact contents only need to round-trip through the temp file unchanged.
final _bytes = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0x01, 0x02, 0x03]);

/// Writes [_bytes] to a fresh temp file and returns it (so the flow's
/// `readAsBytes()` and best-effort delete operate on a real file).
File _writeTempFile(String name) {
  final dir = Directory.systemTemp.createTempSync('haven_avatar_test_');
  final file = File('${dir.path}/$name.jpg')..writeAsBytesSync(_bytes);
  return file;
}

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
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: IdentityPhotoHeader()),
    ),
  );
}

/// Taps "Edit Photo" and drives the pick → crop → read → delete → set flow to
/// completion.
///
/// The flow performs real `dart:io` file reads and deletes, which
/// `pumpAndSettle` alone does NOT await (it only waits on the frame scheduler).
/// [WidgetTester.runAsync] runs the real event loop so the I/O actually
/// finishes before the final pump renders the resulting SnackBar / state.
Future<void> _tapEditPhoto(WidgetTester tester) async {
  await tester.runAsync(() async {
    await tester.tap(find.widgetWithText(TextButton, 'Edit Photo'));
    // The pick → crop → read → delete → set chain interleaves real file I/O
    // with widget rebuilds. Pump real frames while yielding to the real event
    // loop so BOTH the I/O and the rebuilds progress to completion (pumpAndSettle
    // alone never awaits real `dart:io` futures).
    for (var i = 0; i < 15; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  });
  await tester.pump(); // final render of the resulting SnackBar / state
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Both platform instances are process-globals; capture the defaults and
  // restore them after every test so a fake never leaks into another test.
  late final ImagePickerPlatform originalPicker;
  late final ImageCropperPlatform originalCropper;
  setUpAll(() {
    originalPicker = ImagePickerPlatform.instance;
    originalCropper = ImageCropperPlatform.instance;
  });
  tearDown(() {
    ImagePickerPlatform.instance = originalPicker;
    ImageCropperPlatform.instance = originalCropper;
  });

  group('pickAndSetOwnAvatar (pick → square crop → set)', () {
    testWidgets(
      'picked + cropped image flows to setMyAvatar with a square lock, '
      'shows success, and deletes both temp files',
      (tester) async {
        final pickedFile = _writeTempFile('picked');
        final croppedFile = _writeTempFile('cropped');
        final picker = _FakeImagePicker(result: XFile(pickedFile.path));
        ImagePickerPlatform.instance = picker;
        final cropper = _FakeImageCropper(
          result: CroppedFile(croppedFile.path),
        );
        ImageCropperPlatform.instance = cropper;

        final svc = MockCircleService();
        await tester.pumpWidget(_buildHeader(svc));
        await tester.pumpAndSettle();

        await _tapEditPhoto(tester);

        // The picker did not request full EXIF/location metadata, and the
        // editor was opened on the picked file, locked to a 1:1 square.
        expect(picker.lastRequestFullMetadata, isFalse);
        expect(cropper.callCount, 1);
        expect(cropper.lastSourcePath, pickedFile.path);
        expect(cropper.lastAspectRatio?.ratioX, 1);
        expect(cropper.lastAspectRatio?.ratioY, 1);

        // The cropped bytes reached the controller -> circle service.
        expect(svc.setMyAvatarCalledWithBytes, isNotNull);
        expect(svc.setMyAvatarCalledWithBytes, equals(_bytes));
        expect(svc.methodCalls, contains('setMyAvatar'));

        expect(find.textContaining('Photo updated'), findsOneWidget);

        // Both temp files are cleaned up after the bytes are read (privacy).
        expect(pickedFile.existsSync(), isFalse);
        expect(croppedFile.existsSync(), isFalse);
      },
    );

    testWidgets('cancelling the picker never opens the editor or sets', (
      tester,
    ) async {
      ImagePickerPlatform.instance = _FakeImagePicker(); // null -> cancelled
      // The cropper must never be invoked when the picker is cancelled, so it
      // needs no result (and we avoid leaking an unused temp file).
      final cropper = _FakeImageCropper();
      ImageCropperPlatform.instance = cropper;

      final svc = MockCircleService();
      await tester.pumpWidget(_buildHeader(svc));
      await tester.pumpAndSettle();

      await _tapEditPhoto(tester);

      expect(cropper.callCount, 0);
      expect(svc.setMyAvatarCalledWithBytes, isNull);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('cancelling the crop sets nothing and shows no SnackBar', (
      tester,
    ) async {
      final pickedFile = _writeTempFile('picked');
      ImagePickerPlatform.instance = _FakeImagePicker(
        result: XFile(pickedFile.path),
      );
      // Cropper returns null -> user backed out of the editor.
      ImageCropperPlatform.instance = _FakeImageCropper();

      final svc = MockCircleService();
      await tester.pumpWidget(_buildHeader(svc));
      await tester.pumpAndSettle();

      await _tapEditPhoto(tester);

      expect(svc.setMyAvatarCalledWithBytes, isNull);
      expect(svc.methodCalls, isNot(contains('setMyAvatar')));
      expect(find.byType(SnackBar), findsNothing);
      // The picked temp is still cleaned up even though the user cancelled.
      expect(pickedFile.existsSync(), isFalse);
    });

    testWidgets('a crop failure shows a generic SnackBar and sets nothing', (
      tester,
    ) async {
      final pickedFile = _writeTempFile('picked');
      ImagePickerPlatform.instance = _FakeImagePicker(
        result: XFile(pickedFile.path),
      );
      ImageCropperPlatform.instance = _FakeImageCropper(throwError: true);

      final svc = MockCircleService();
      await tester.pumpWidget(_buildHeader(svc));
      await tester.pumpAndSettle();

      await _tapEditPhoto(tester);

      expect(svc.setMyAvatarCalledWithBytes, isNull);
      expect(
        find.textContaining('Could not update your photo'),
        findsOneWidget,
      );
      expect(pickedFile.existsSync(), isFalse);
    });

    testWidgets('a picker failure shows a generic SnackBar and never crops', (
      tester,
    ) async {
      ImagePickerPlatform.instance = _FakeImagePicker(throwError: true);
      final cropper = _FakeImageCropper();
      ImageCropperPlatform.instance = cropper;

      final svc = MockCircleService();
      await tester.pumpWidget(_buildHeader(svc));
      await tester.pumpAndSettle();

      await _tapEditPhoto(tester);

      expect(cropper.callCount, 0);
      expect(svc.setMyAvatarCalledWithBytes, isNull);
      expect(
        find.textContaining('Could not update your photo'),
        findsOneWidget,
      );
    });
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
    });

    test('still drops EXIF/location metadata at the pick boundary', () {
      expect(readSource().contains('requestFullMetadata: false'), isTrue);
    });

    test('still routes the picked photo through a square-locked crop editor',
        () {
      final source = readSource();
      expect(source.contains('ImageCropper()'), isTrue);
      expect(
        source.contains('CropAspectRatio(ratioX: 1, ratioY: 1)'),
        isTrue,
        reason: 'Avatars are stored square; the editor must lock 1:1.',
      );
    });
  });
}
