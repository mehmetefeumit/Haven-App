/// Profile-photo header for the Identity page.
///
/// Shows the user's avatar (tap to view full screen when set, or to add one
/// when not), an "Edit Photo" action, a "Remove" action (only when a photo is
/// set, behind a confirmation), and a short end-to-end-encryption note.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/own_avatar_provider.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:haven/src/widgets/identity/avatar.dart';
import 'package:haven/src/widgets/identity/avatar_fullscreen_viewer.dart';
import 'package:haven/src/widgets/identity/avatar_initials.dart';
import 'package:haven/src/widgets/identity/avatar_picker.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Identity-page header for viewing and changing the user's profile photo.
class IdentityPhotoHeader extends ConsumerWidget {
  /// Creates the identity photo header.
  const IdentityPhotoHeader({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorScheme = Theme.of(context).colorScheme;

    final avatarAsync = ref.watch(ownAvatarProvider);
    final displayNameAsync = ref.watch(displayNameProvider);
    final identityAsync = ref.watch(identityProvider);
    final isLoading = ref.watch(ownAvatarControllerProvider).isLoading;

    final bytes = avatarAsync.valueOrNull;
    final hasAvatar = bytes != null && bytes.isNotEmpty;
    final initials = avatarInitials(displayNameAsync.valueOrNull);
    final pubkeyHex = identityAsync.valueOrNull?.pubkeyHex;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: _AvatarWithBadge(
            avatarAsync: avatarAsync,
            initials: initials,
            publicKey: pubkeyHex,
            hasAvatar: hasAvatar,
            // Tap the avatar body: view when a photo exists, else pick one.
            onAvatarTap: isLoading
                ? null
                : hasAvatar
                ? () => showAvatarFullscreen(context, bytes)
                : () => pickAndSetOwnAvatar(context, ref),
            // The badge is always the "change photo" affordance.
            onBadgeTap: isLoading
                ? null
                : () => pickAndSetOwnAvatar(context, ref),
          ),
        ),
        const SizedBox(height: HavenSpacing.md),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TextButton.icon(
              onPressed: isLoading
                  ? null
                  : () => pickAndSetOwnAvatar(context, ref),
              icon: const Icon(LucideIcons.imagePlus, size: 18),
              label: const Text('Edit Photo'),
            ),
            if (hasAvatar) ...[
              const SizedBox(width: HavenSpacing.sm),
              TextButton.icon(
                onPressed: isLoading
                    ? null
                    : () => _confirmAndRemove(context, ref),
                icon: const Icon(LucideIcons.trash2, size: 18),
                label: const Text('Remove'),
                style: TextButton.styleFrom(
                  foregroundColor: colorScheme.error,
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }

  /// Confirms with the user, then removes the avatar (broadcasting a tombstone
  /// to every circle). Mirrors the destructive-confirm pattern used for
  /// identity deletion.
  Future<void> _confirmAndRemove(BuildContext context, WidgetRef ref) async {
    final colorScheme = Theme.of(context).colorScheme;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove profile photo?'),
        content: const Text(
          'This removes your photo for everyone in your circles.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: colorScheme.error),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!context.mounted) return;
    await removeOwnAvatar(context, ref);
  }
}

/// The circular avatar with a camera "edit" badge overlaid bottom-right.
class _AvatarWithBadge extends StatelessWidget {
  const _AvatarWithBadge({
    required this.avatarAsync,
    required this.initials,
    required this.publicKey,
    required this.hasAvatar,
    required this.onAvatarTap,
    required this.onBadgeTap,
  });

  final AsyncValue<Uint8List?> avatarAsync;
  final String initials;
  final String? publicKey;
  final bool hasAvatar;
  final VoidCallback? onAvatarTap;
  final VoidCallback? onBadgeTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    // Show the user's initials in every branch (loading/error included) so the
    // circle is never blank while bytes resolve.
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

    return SizedBox(
      width: 96,
      height: 96,
      child: Stack(
        children: [
          Semantics(
            button: true,
            label: hasAvatar ? 'View profile photo' : 'Add profile photo',
            child: InkWell(
              onTap: onAvatarTap,
              customBorder: const CircleBorder(),
              child: avatar,
            ),
          ),
          Positioned(
            right: 0,
            bottom: 0,
            child: Semantics(
              button: true,
              label: 'Change profile photo',
              child: Material(
                color: colorScheme.primary,
                shape: CircleBorder(
                  side: BorderSide(color: colorScheme.surface, width: 2),
                ),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: onBadgeTap,
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: Icon(
                      LucideIcons.camera,
                      size: 16,
                      color: colorScheme.onPrimary,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
