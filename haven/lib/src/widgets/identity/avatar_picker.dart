/// Shared own-avatar pick / set / remove pipeline.
///
/// Extracted so the Identity photo header and any other surface reuse the
/// exact same permission flow, gallery picker, and SnackBar feedback rather
/// than duplicating it. All EXIF stripping, downscaling, encryption, and
/// relay publishing happen inside [OwnAvatarController]; this layer only
/// handles permission, the system picker, and user-facing feedback.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/providers/own_avatar_provider.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';

/// Picks an image from the system gallery and stores it as the own avatar.
///
/// Checks photo-library permission first (prompting, or showing a denied
/// bottom sheet when permanently denied), opens the gallery picker with
/// `requestFullMetadata: false` so no EXIF/location metadata is requested,
/// reads the bytes, and delegates persistence + publish to
/// [OwnAvatarController.pickAndSet]. Shows a success or generic-failure
/// SnackBar. Never surfaces raw errors to the user.
Future<void> pickAndSetOwnAvatar(BuildContext context, WidgetRef ref) async {
  // Check photo library permission before opening the picker.
  final status = await Permission.photos.status;

  if (status.isPermanentlyDenied) {
    if (!context.mounted) return;
    await _showPermissionDeniedSheet(context);
    return;
  }

  if (status.isDenied) {
    final result = await Permission.photos.request();
    if (!result.isGranted) {
      if (!context.mounted) return;
      await _showPermissionDeniedSheet(context);
      return;
    }
  }

  // Open the system gallery picker.
  final picker = ImagePicker();
  final file = await picker.pickImage(
    source: ImageSource.gallery,
    requestFullMetadata: false, // do not ask for full EXIF/location metadata
  );
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

/// Shows a bottom sheet explaining that photo-library access is required and
/// offering a shortcut to the OS app settings.
Future<void> _showPermissionDeniedSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    builder: (ctx) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Photo access required',
                style: Theme.of(ctx).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              const Text(
                'To set a profile picture, allow Haven to access your '
                'photo library in your device settings.',
              ),
              const SizedBox(height: 16),
              OutlinedButton(
                onPressed: () {
                  Navigator.of(ctx).pop();
                  openAppSettings();
                },
                child: const Text('Open settings'),
              ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Not now'),
              ),
            ],
          ),
        ),
      );
    },
  );
}
