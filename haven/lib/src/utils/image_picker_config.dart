/// The one place Haven configures the system image picker, so `main()` and the
/// integration-test harness drive the same picker.
library;

import 'package:image_picker_android/image_picker_android.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';

/// Forces the Android system Photo Picker (scoped, permission-free, per-item
/// access) instead of image_picker's default ACTION_GET_CONTENT document
/// browser. The user picks one photo and the app receives only that image —
/// no whole-library permission is ever requested or held. The `is` guard
/// makes this a no-op on iOS/web/desktop, where the gallery picker
/// (PHPickerViewController on iOS) is already scoped and permission-free.
void configureImagePicker() {
  final imagePickerPlatform = ImagePickerPlatform.instance;
  if (imagePickerPlatform is ImagePickerAndroid) {
    imagePickerPlatform.useAndroidPhotoPicker = true;
  }
}
