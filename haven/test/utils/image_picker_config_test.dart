/// Pins `configureImagePicker`: Haven's one switch to the scoped,
/// permission-free Android Photo Picker, which `main()` and the
/// integration-test harness both call.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/utils/image_picker_config.dart';
import 'package:image_picker_android/image_picker_android.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class _OtherPicker extends ImagePickerPlatform
    with MockPlatformInterfaceMixin {}

void main() {
  late ImagePickerPlatform original;
  setUp(() => original = ImagePickerPlatform.instance);
  tearDown(() => ImagePickerPlatform.instance = original);

  test('on Android it selects the system Photo Picker', () {
    // Without it image_picker opens the ACTION_GET_CONTENT document browser.
    final android = ImagePickerAndroid();
    ImagePickerPlatform.instance = android;
    expect(android.useAndroidPhotoPicker, isFalse, reason: 'anti-vacuity');
    configureImagePicker();
    expect(android.useAndroidPhotoPicker, isTrue);
  });

  test('elsewhere it changes nothing and does not throw', () {
    final other = _OtherPicker();
    ImagePickerPlatform.instance = other;
    configureImagePicker();
    expect(ImagePickerPlatform.instance, same(other));
  });

  test('the app calls it at start-up', () {
    expect(
      File('lib/main.dart').readAsStringSync(),
      contains('  configureImagePicker();\n'),
    );
  });
}
