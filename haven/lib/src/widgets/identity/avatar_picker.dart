/// Shared own-avatar pick / crop / set / remove pipeline.
///
/// Extracted so the Identity photo header and any other surface reuse the exact
/// same gallery picker, square crop/rotate editor, and SnackBar feedback rather
/// than duplicating it. All EXIF stripping, downscaling, encryption, and relay
/// publishing happen inside [OwnAvatarController]; this layer only opens the
/// system picker, runs the crop editor, and shows user-facing feedback.
///
/// No app-level photo permission is requested: the system photo pickers
/// (Android Photo Picker / iOS PHPickerViewController) are permission-free,
/// scoped pickers that grant access only to the single item the user selects.
/// That is strictly more private than requesting whole-library access, and it
/// removes the Android dead-end where a runtime photo permission can neither be
/// granted (none is declared) nor toggled in system settings. The crop editor
/// (uCrop / TOCropViewController) likewise operates only on the picked file and
/// needs no permission.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/providers/own_avatar_provider.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:image_picker/image_picker.dart';

/// Picks an image from the system gallery, lets the user crop/rotate it to a
/// square, and stores the result as the own avatar.
///
/// Flow: open the permission-free system picker → square-locked crop/rotate
/// editor → read the cropped bytes → delegate persistence + publish to
/// [OwnAvatarController.pickAndSet]. Cancelling the picker OR the crop editor
/// is a silent no-op. `requestFullMetadata: false` keeps EXIF/location metadata
/// out of the picked bytes (the Rust pipeline strips it again and bakes
/// orientation, defence in depth). The picker and cropper temp files are
/// best-effort deleted once their bytes are read so avatar pixels do not linger
/// on disk. Shows a
/// success or generic-failure SnackBar; never surfaces raw errors to the user.
Future<void> pickAndSetOwnAvatar(BuildContext context, WidgetRef ref) async {
  // Capture localizations before the first await so the success message does
  // not touch a possibly-unmounted context after the picker/crop round-trip.
  final l10n = AppLocalizations.of(context);
  // ── Stage 1: scoped, permission-free system picker ──────────────────────
  final picker = ImagePicker();
  final XFile? picked;
  try {
    picked = await picker.pickImage(
      source: ImageSource.gallery,
      requestFullMetadata: false, // do not ask for full EXIF/location metadata
    );
  } on Object {
    if (context.mounted) _showGenericFailure(context);
    return;
  }
  if (picked == null) return; // user cancelled the picker

  if (!context.mounted) {
    await _deleteQuietly(picked.path);
    return;
  }

  // ── Stage 2: square-locked crop / rotate editor ─────────────────────────
  // The cropper output is NEVER trusted as final — its bytes are re-run through
  // the Rust pipeline, which strips all metadata and bakes orientation. uCrop /
  // TOCropViewController already emit an upright image (they read the source
  // EXIF orientation and normalise it), so there is no double-rotation with the
  // Rust orientation fix.
  final CroppedFile? cropped;
  try {
    cropped = await _cropToSquare(context, picked.path);
  } on Object {
    await _deleteQuietly(picked.path);
    if (context.mounted) _showGenericFailure(context);
    return;
  }
  if (cropped == null) {
    // User cancelled the crop — silent no-op, but clean up the picked temp.
    await _deleteQuietly(picked.path);
    return;
  }

  // ── Read the cropped bytes, then delete BOTH temp files (privacy) ───────
  final Uint8List raw;
  try {
    raw = await cropped.readAsBytes();
  } on Object {
    if (context.mounted) _showGenericFailure(context);
    return;
  } finally {
    // Best-effort cleanup regardless of read outcome.
    await _deleteQuietly(cropped.path);
    await _deleteQuietly(picked.path);
  }

  if (!context.mounted) return;

  // ── Stage 3: hand to the controller (Rust strips metadata + bakes
  //    orientation, encrypts, publishes) ───────────────────────────────────
  try {
    await ref.read(ownAvatarControllerProvider.notifier).pickAndSet(raw);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l10n.avatarPickerPhotoUpdated)),
    );
  } on Object {
    if (context.mounted) _showGenericFailure(context);
  }
}

/// Opens the native square-locked crop/rotate editor on [sourcePath], themed to
/// the app [ColorScheme]. Returns the cropped file, or `null` if cancelled.
///
/// The aspect ratio is locked to 1:1 because avatars are stored square and
/// masked to a circle at display time. Rotation stays available so the user can
/// correct framing. Output is a JPEG re-run through the Rust pipeline.
Future<CroppedFile?> _cropToSquare(BuildContext context, String sourcePath) {
  final theme = Theme.of(context);
  final scheme = theme.colorScheme;
  final isLight = theme.brightness == Brightness.light;
  final l10n = AppLocalizations.of(context);

  return ImageCropper().cropImage(
    sourcePath: sourcePath,
    aspectRatio: const CropAspectRatio(ratioX: 1, ratioY: 1),
    // Intermediate bound above the canonical 512 px tier (AVATAR_TIER_EDGE_PX);
    // keep ≥ that tier if it is ever raised, so the cropper is not undersized.
    maxWidth: 1024,
    maxHeight: 1024,
    // compressFormat (jpg) and compressQuality (90) are the plugin defaults;
    // the Rust pipeline re-encodes anyway, so they need not be overridden.
    uiSettings: [
      AndroidUiSettings(
        toolbarTitle: l10n.avatarPickerCropTitle,
        toolbarColor: scheme.surface,
        toolbarWidgetColor: scheme.onSurface,
        activeControlsWidgetColor: scheme.primary,
        backgroundColor: scheme.surface,
        statusBarLight: isLight,
        lockAspectRatio: true,
        hideBottomControls: false, // keep the rotate / scale controls
        initAspectRatio: CropAspectRatioPreset.square,
        aspectRatioPresets: const [CropAspectRatioPreset.square],
      ),
      IOSUiSettings(
        title: l10n.avatarPickerCropTitle,
        aspectRatioLockEnabled: true,
        resetAspectRatioEnabled: false,
        aspectRatioPickerButtonHidden: true,
        doneButtonTitle: l10n.avatarPickerCropDone,
        cancelButtonTitle: l10n.avatarPickerCropCancel,
        aspectRatioPresets: const [CropAspectRatioPreset.square],
      ),
    ],
  );
}

/// Removes the own avatar via [OwnAvatarController.remove], with SnackBars.
///
/// A pure pass-through to the controller — deliberately NOT gated on the
/// "Send my avatar" toggle, so a user who has disabled outgoing sharing can
/// still retract an already-shared avatar (the controller publishes the
/// tombstone before clearing locally).
Future<void> removeOwnAvatar(BuildContext context, WidgetRef ref) async {
  // Capture localizations before the await so neither SnackBar touches a
  // possibly-unmounted context after the remove round-trip.
  final l10n = AppLocalizations.of(context);
  try {
    await ref.read(ownAvatarControllerProvider.notifier).remove();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l10n.avatarPickerPhotoRemoved)),
    );
  } on Object {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l10n.avatarPickerRemoveError)),
    );
  }
}

/// Best-effort delete of a temp file produced by the picker or cropper.
///
/// Never throws and never surfaces a raw error: privacy cleanup is advisory and
/// these files live in OS-evictable cache, so a failed delete is non-fatal.
Future<void> _deleteQuietly(String path) async {
  if (path.isEmpty) return;
  try {
    await File(path).delete();
  } on Object {
    // Temp file already gone / locked — the OS evicts cache regardless.
  }
}

/// Shows the single generic "could not update" SnackBar (no raw errors in UI).
void _showGenericFailure(BuildContext context) {
  if (!context.mounted) return;
  final l10n = AppLocalizations.of(context);
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(l10n.avatarPickerUpdateError)),
  );
}
