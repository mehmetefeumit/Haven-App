/// Shared own-avatar pick / set / remove pipeline.
///
/// Extracted so the Identity photo header and any other surface reuse the
/// exact same gallery picker and SnackBar feedback rather than duplicating
/// it. All EXIF stripping, downscaling, encryption, and relay publishing
/// happen inside [OwnAvatarController]; this layer only opens the system
/// picker and shows user-facing feedback.
///
/// No app-level photo permission is requested: the system photo pickers
/// (Android Photo Picker / iOS PHPickerViewController) are permission-free,
/// scoped pickers that grant access only to the single item the user selects.
/// That is strictly more private than requesting whole-library access, and it
/// removes the Android dead-end where a runtime photo permission can neither be
/// granted (none is declared) nor toggled in system settings.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/providers/own_avatar_provider.dart';
import 'package:image_picker/image_picker.dart';

/// Picks an image from the system gallery and stores it as the own avatar.
///
/// Opens the permission-free system photo picker directly — the picker is
/// itself the user's grant and is scoped to the chosen image, so there is no
/// runtime permission to request and nothing to deny. Uses
/// `requestFullMetadata: false` so no EXIF/location metadata is requested,
/// reads the bytes, and delegates persistence + publish to
/// [OwnAvatarController.pickAndSet]. Shows a success or generic-failure
/// SnackBar. Never surfaces raw errors to the user.
Future<void> pickAndSetOwnAvatar(BuildContext context, WidgetRef ref) async {
  // Open the system gallery picker directly. The Android Photo Picker and
  // iOS PHPicker need no runtime permission and grant only the chosen image,
  // so there is no permission to request and nothing to deny.
  final picker = ImagePicker();
  final XFile? file;
  try {
    file = await picker.pickImage(
      source: ImageSource.gallery,
      requestFullMetadata: false, // do not ask for full EXIF/location metadata
    );
  } on Object {
    // A picker failure must surface generic copy, never a permission
    // narrative or a raw error (no-raw-errors-in-UI rule).
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Could not update your photo. Please try again.'),
      ),
    );
    return;
  }
  if (file == null) return; // user cancelled

  // Read bytes immediately and drop the XFile reference.
  final raw = await file.readAsBytes();

  if (!context.mounted) return;

  try {
    await ref.read(ownAvatarControllerProvider.notifier).pickAndSet(raw);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Photo updated — shared with your circles, '
          'end-to-end encrypted.',
        ),
      ),
    );
  } on Object {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Could not update your photo. Please try again.'),
      ),
    );
  }
}

/// Removes the own avatar via [OwnAvatarController.remove], with SnackBars.
///
/// A pure pass-through to the controller — deliberately NOT gated on the
/// "Send my avatar" toggle, so a user who has disabled outgoing sharing can
/// still retract an already-shared avatar (the controller publishes the
/// tombstone before clearing locally).
Future<void> removeOwnAvatar(BuildContext context, WidgetRef ref) async {
  try {
    await ref.read(ownAvatarControllerProvider.notifier).remove();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Photo removed.')),
    );
  } on Object {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Could not remove your photo. Please try again.'),
      ),
    );
  }
}
