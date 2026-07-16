/// Profile-photo header for the Identity page.
///
/// Shows the user's avatar (tap to view full screen when set, or to add one
/// when not), an "Edit Photo" action, a "Remove" action (only when a photo is
/// set, behind a confirmation), and a short end-to-end-encryption note.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/own_profile_provider.dart';
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
    final l10n = AppLocalizations.of(context);

    final profileAsync = ref.watch(ownProfileProvider);
    final avatarAsync = profileAsync.whenData(
      (profile) => profile?.pictureBytes,
    );
    final displayNameAsync = ref.watch(displayNameProvider);
    final identityAsync = ref.watch(identityProvider);
    final isLoading = ref.watch(ownProfileControllerProvider).isLoading;

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
              label: Text(l10n.photoHeaderEditPhoto),
            ),
            if (hasAvatar) ...[
              const SizedBox(width: HavenSpacing.sm),
              TextButton.icon(
                onPressed: isLoading
                    ? null
                    : () => _confirmAndRemove(context, ref),
                icon: const Icon(LucideIcons.trash2, size: 18),
                label: Text(l10n.photoHeaderRemove),
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
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.photoHeaderRemoveTitle),
        content: Text(l10n.photoHeaderRemoveBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: colorScheme.error),
            child: Text(l10n.photoHeaderRemove),
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
    final l10n = AppLocalizations.of(context);

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
            label: hasAvatar
                ? l10n.photoHeaderViewPhotoSemantics
                : l10n.photoHeaderAddPhotoSemantics,
            child: InkWell(
              onTap: onAvatarTap,
              customBorder: const CircleBorder(),
              child: avatar,
            ),
          ),
          // The badge's VISUAL circle stays a small 28dp accent (matching the
          // design), but its tappable area is grown to the WCAG-minimum 48dp
          // square via the SizedBox below — `Material`/`InkWell` fill
          // whatever box constrains them, so the ink/tap region covers the
          // full 48dp while the `Align`-ed inner circle keeps its original
          // on-screen position (bottom-end corner of the 48dp box), pixel
          // for pixel where the old 28dp-only badge used to sit (#4).
          PositionedDirectional(
            end: 0,
            bottom: 0,
            child: Semantics(
              button: true,
              label: l10n.photoHeaderChangePhotoSemantics,
              child: SizedBox(
                width: 48,
                height: 48,
                child: Material(
                  color: Colors.transparent,
                  shape: const CircleBorder(),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: onBadgeTap,
                    child: Align(
                      alignment: AlignmentDirectional.bottomEnd,
                      child: Container(
                        width: 28,
                        height: 28,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: colorScheme.primary,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: colorScheme.surface,
                            width: 2,
                          ),
                        ),
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
            ),
          ),
        ],
      ),
    );
  }
}
