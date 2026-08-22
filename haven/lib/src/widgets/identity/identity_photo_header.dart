/// Profile-photo header for the Identity page.
///
/// Shows the user's avatar (tap to view full screen when set, or to add one
/// when not), an "Edit Photo" action, and a "Remove" action (only when a
/// photo is set, behind a confirmation). The own-profile sync status line
/// lives once, at page scope (`identity_page.dart`) — not here.
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
///
/// `_busy` is LOCAL, purely-widget state — it gates only the pick/remove
/// affordances in THIS header, and is deliberately independent of the
/// page-scoped `ProfileSyncStatusLine`'s `ownProfileSyncProvider`-driven
/// state: an in-flight background publish (e.g. from a name edit elsewhere
/// on the page) must never disable picking a new photo, and picking a new
/// photo must never appear to change the sync status of a prior, unrelated
/// publish still in flight.
class IdentityPhotoHeader extends ConsumerStatefulWidget {
  /// Creates the identity photo header.
  const IdentityPhotoHeader({super.key});

  @override
  ConsumerState<IdentityPhotoHeader> createState() =>
      _IdentityPhotoHeaderState();
}

class _IdentityPhotoHeaderState extends ConsumerState<IdentityPhotoHeader> {
  bool _busy = false;

  /// Whether a removal is in flight specifically — a subset of [_busy]
  /// (which also spans the native picker) that gates ONLY the Remove
  /// button's own spinner, so picking a new photo never shows it.
  bool _removing = false;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);

    final profileAsync = ref.watch(ownProfileProvider);
    final avatarAsync = profileAsync.whenData(
      (profile) => profile?.pictureBytes,
    );
    final displayNameAsync = ref.watch(displayNameProvider);
    final identityAsync = ref.watch(identityProvider);
    final isLoading = _busy;

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
                : () => _pick(context),
            // The badge is always the "change photo" affordance.
            onBadgeTap: isLoading ? null : () => _pick(context),
          ),
        ),
        const SizedBox(height: HavenSpacing.md),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TextButton.icon(
              onPressed: isLoading ? null : () => _pick(context),
              icon: const Icon(LucideIcons.imagePlus, size: 18),
              label: Text(l10n.photoHeaderEditPhoto),
            ),
            if (hasAvatar) ...[
              const SizedBox(width: HavenSpacing.sm),
              TextButton.icon(
                onPressed: isLoading
                    ? null
                    : () => _confirmAndRemove(context),
                icon: const Icon(LucideIcons.trash2, size: 18),
                // The synchronous retraction call has no other visible
                // feedback while it is in flight — show a spinner in place
                // of the label rather than leaving only the greyed-out
                // button (`circles_bottom_sheet.dart`'s leave/remove idiom).
                label: _removing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(l10n.photoHeaderRemove),
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

  /// Runs the pick → crop → local-save flow, tracking [_busy] for its
  /// duration (try/finally so a thrown or cancelled pick always releases it).
  Future<void> _pick(BuildContext context) async {
    setState(() => _busy = true);
    try {
      await pickAndSetOwnAvatar(context, ref);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Confirms with the user, then removes the avatar (broadcasting a tombstone
  /// to every circle). Mirrors the destructive-confirm pattern used for
  /// identity deletion.
  Future<void> _confirmAndRemove(BuildContext context) async {
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
    setState(() {
      _busy = true;
      _removing = true;
    });
    try {
      await removeOwnAvatar(context, ref);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _removing = false;
        });
      }
    }
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
