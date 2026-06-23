/// Settings page for managing the user's own profile picture.
///
/// M1 scope: local only (zero-network). The photo is processed and
/// stored in the encrypted Rust core; no bytes leave the device in M1.
///
/// M3: adds the data-saver toggle that lengthens the avatar anti-entropy
/// re-share interval from 24 h to 72 h (§5.7 DEC-2).
///
/// §7.5: adds "Send my avatar" and "Receive avatars" privacy toggles.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/providers/avatar_anti_entropy_provider.dart';
import 'package:haven/src/providers/avatar_data_saver_provider.dart';
import 'package:haven/src/providers/avatar_receive_provider.dart';
import 'package:haven/src/providers/avatar_send_provider.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/own_avatar_provider.dart';
import 'package:haven/src/widgets/identity/avatar.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';

/// Settings page for "Your Profile" — own-avatar set / remove + toggles.
class ProfilePicturePage extends ConsumerWidget {
  /// Creates the profile picture settings page.
  const ProfilePicturePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final avatarAsync = ref.watch(ownAvatarProvider);
    final controllerAsync = ref.watch(ownAvatarControllerProvider);
    final identityAsync = ref.watch(identityProvider);
    final displayNameAsync = ref.watch(displayNameProvider);
    final dataSaverEnabled = ref.watch(avatarDataSaverProvider);
    final sendEnabled = ref.watch(avatarSendProvider);
    final receiveEnabled = ref.watch(avatarReceiveProvider);

    final isLoading = controllerAsync.isLoading;

    // Derive initials from the user's display name (grapheme-safe).
    // Falls back to '?' — never slices the npub, which would produce
    // a meaningless glyph (the npub '1' separator is at index 4).
    final displayName = displayNameAsync.valueOrNull;
    final initials = _initialsFor(displayName);

    // True once the avatar provider has resolved to non-null bytes.
    // Used to gate the data-saver card (only meaningful when an avatar
    // exists to re-share) and to disable "Remove photo" (no-op otherwise).
    final hasAvatar = avatarAsync.valueOrNull != null;

    return Scaffold(
      appBar: AppBar(title: const Text('Your Profile')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 24),
        children: [
          _AvatarDisplay(
            avatarAsync: avatarAsync,
            initials: initials,
            publicKey: identityAsync.valueOrNull?.pubkeyHex,
            onTap: isLoading
                ? null
                : () => _ActionButtons._staticPickAndSet(context, ref),
          ),
          const SizedBox(height: 24),
          _DisclosureCard(),
          const SizedBox(height: 24),
          _ActionButtons(isLoading: isLoading, hasAvatar: hasAvatar),
          const SizedBox(height: 24),
          _PrivacyCard(sendEnabled: sendEnabled, receiveEnabled: receiveEnabled),
          if (hasAvatar) ...[
            const SizedBox(height: 24),
            _DataSaverCard(enabled: dataSaverEnabled),
          ],
        ],
      ),
    );
  }

  /// Derives 1-2 grapheme-safe initials from [displayName].
  ///
  /// Handles multi-byte Unicode, emoji, ZWJ sequences, and flag glyphs
  /// correctly by iterating grapheme clusters via `String.characters`.
  /// Returns '?' when [displayName] is null or empty.
  @visibleForTesting
  static String initialsForTest(String? displayName) =>
      _initialsFor(displayName);

  static String _initialsFor(String? displayName) {
    final name = displayName?.trim();
    if (name == null || name.isEmpty) return '?';
    final parts = name.split(RegExp(r'\s+'));
    if (parts.length >= 2) {
      final first = parts.first.characters.first;
      final last = parts.last.characters.first;
      return (first + last).toUpperCase();
    }
    return name.characters.first.toUpperCase();
  }
}

// ---------------------------------------------------------------------------
// Sub-widgets
// ---------------------------------------------------------------------------

class _AvatarDisplay extends StatelessWidget {
  const _AvatarDisplay({
    required this.avatarAsync,
    this.initials,
    this.publicKey,
    this.onTap,
  });

  final AsyncValue<Uint8List?> avatarAsync;
  final String? initials;
  final String? publicKey;

  /// Called when the avatar is tapped — same action as "Change photo".
  /// Null while a pick/set operation is in progress.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    // Pass initials/publicKey to the loading and error branches so the
    // user sees their own initials rather than a blank/? circle.
    final avatar = avatarAsync.when(
      data: (bytes) => HavenAvatar(
        imageBytes: bytes,
        initials: initials,
        publicKey: publicKey,
        size: HavenAvatarSize.xlarge,
      ),
      loading: () => HavenAvatar(
        initials: initials,
        publicKey: publicKey,
        size: HavenAvatarSize.xlarge,
      ),
      error: (err, stack) => HavenAvatar(
        initials: initials,
        publicKey: publicKey,
        size: HavenAvatarSize.xlarge,
      ),
    );

    return Center(
      child: Tooltip(
        message: 'Change photo',
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(48),
          child: Semantics(
            button: true,
            label: 'Change profile photo',
            child: avatar,
          ),
        ),
      ),
    );
  }
}

class _DisclosureCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textStyle = Theme.of(context).textTheme.bodySmall?.copyWith(
      color: colorScheme.onSurfaceVariant,
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.lock_outline,
              size: 16,
              color: colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Your photo is end-to-end encrypted before it leaves your '
                'device. Only the people in your circles can see it. '
                'Haven never sees it.',
                style: textStyle,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionButtons extends ConsumerWidget {
  const _ActionButtons({required this.isLoading, required this.hasAvatar});

  final bool isLoading;

  /// Whether the user currently has an avatar set.
  ///
  /// Used to disable "Remove photo" when there is nothing to remove —
  /// prevents a no-op tombstone broadcast to every circle.
  final bool hasAvatar;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FilledButton(
            onPressed: isLoading
                ? null
                : () => _staticPickAndSet(context, ref),
            child: const Text('Change photo'),
          ),
          const SizedBox(height: 8),
          // Disabled (not hidden) when no avatar is set to avoid a no-op
          // tombstone broadcast; also shows "No profile photo set" hint.
          OutlinedButton(
            onPressed: (isLoading || !hasAvatar)
                ? null
                : () => _remove(context, ref),
            child: const Text('Remove photo'),
          ),
          if (!hasAvatar) ...[
            const SizedBox(height: 4),
            Text(
              'No profile photo set',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Shared pick-and-set logic used by both the "Change photo" button
  /// and the tappable avatar. Static so [_AvatarDisplay] can call it
  /// without holding a reference to the [_ActionButtons] instance.
  static Future<void> _staticPickAndSet(
    BuildContext context,
    WidgetRef ref,
  ) async {
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
      await ref
          .read(ownAvatarControllerProvider.notifier)
          .pickAndSet(raw);
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

  Future<void> _remove(BuildContext context, WidgetRef ref) async {
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

  static Future<void> _showPermissionDeniedSheet(
    BuildContext context,
  ) {
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
}

// ---------------------------------------------------------------------------
// §7.5 — Privacy toggles: send / receive
// ---------------------------------------------------------------------------

/// Card that exposes the "Send my avatar" and "Receive avatars" privacy
/// toggles (§7.5).
///
/// Both default to `true` (feature works out of the box) and are
/// persisted via [SharedPreferences] using the same pattern as the
/// data-saver toggle.
class _PrivacyCard extends ConsumerWidget {
  const _PrivacyCard({
    required this.sendEnabled,
    required this.receiveEnabled,
  });

  final bool sendEnabled;
  final bool receiveEnabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Card(
        child: Column(
          children: [
            SwitchListTile(
              title: const Text('Send my avatar'),
              subtitle: Text(
                sendEnabled
                    ? 'Your photo is shared with circle members'
                    : 'Your photo is not sent to anyone',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              value: sendEnabled,
              onChanged: (value) async {
                await ref
                    .read(avatarSendProvider.notifier)
                    .setEnabled(enabled: value);
              },
            ),
            const Divider(height: 1, indent: 16, endIndent: 16),
            SwitchListTile(
              title: const Text('Receive avatars'),
              subtitle: Text(
                receiveEnabled
                    ? 'Circle members’ photos are shown'
                    : 'Avatars are not downloaded or stored',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              value: receiveEnabled,
              onChanged: (value) async {
                await ref
                    .read(avatarReceiveProvider.notifier)
                    .setEnabled(enabled: value);
              },
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// M3 — Data-saver toggle
// ---------------------------------------------------------------------------

/// Card that exposes the data-saver toggle for avatar anti-entropy.
///
/// When data-saver is on, the periodic avatar re-share interval is lengthened
/// from 24 h to 72 h to reduce mobile data use (§5.7 DEC-2).
class _DataSaverCard extends ConsumerWidget {
  const _DataSaverCard({required this.enabled});

  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Card(
        child: Column(
          children: [
            SwitchListTile(
              title: const Text('Data saver'),
              subtitle: Text(
                enabled
                    ? 'Profile re-shares every 3 days'
                    : 'Profile re-shares every 24 hours',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              value: enabled,
              onChanged: (value) async {
                await ref
                    .read(avatarDataSaverProvider.notifier)
                    .setEnabled(enabled: value);
                // Re-arm the anti-entropy timer so the new cadence takes
                // effect on the next tick rather than at the previously
                // scheduled fire time.
                try {
                  ref
                      .read(avatarAntiEntropyProvider.notifier)
                      .reschedule();
                } on Object {
                  // Best-effort: provider may not be alive (e.g. tests
                  // that only override the data-saver provider).
                }
              },
            ),
          ],
        ),
      ),
    );
  }
}
