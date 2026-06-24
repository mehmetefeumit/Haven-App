/// Settings subpage for avatar-sharing controls.
///
/// Holds the "Send my avatar" / "Receive avatars" privacy toggles (§7.5) and
/// the data-saver toggle (§5.7 DEC-2) that lengthens the avatar anti-entropy
/// re-share interval from 24 h to 72 h. The photo itself (set / view / remove)
/// is managed on the Identity page; this page is purely the sharing settings.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/providers/avatar_anti_entropy_provider.dart';
import 'package:haven/src/providers/avatar_data_saver_provider.dart';
import 'package:haven/src/providers/avatar_receive_provider.dart';
import 'package:haven/src/providers/avatar_send_provider.dart';
import 'package:haven/src/providers/own_avatar_provider.dart';

/// Settings page exposing the avatar send/receive and data-saver toggles.
class PhotoSharingPage extends ConsumerWidget {
  /// Creates the photo-sharing settings page.
  const PhotoSharingPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final avatarAsync = ref.watch(ownAvatarProvider);
    final dataSaverEnabled = ref.watch(avatarDataSaverProvider);
    final sendEnabled = ref.watch(avatarSendProvider);
    final receiveEnabled = ref.watch(avatarReceiveProvider);

    // The data-saver card only matters when an avatar exists to re-share.
    final hasAvatar = avatarAsync.valueOrNull != null;

    return Scaffold(
      appBar: AppBar(title: const Text('Photo sharing')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 24),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Text(
              'Control how profile photos are shared within your circles. '
              'Photos are always end-to-end encrypted.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          _PrivacyCard(
            sendEnabled: sendEnabled,
            receiveEnabled: receiveEnabled,
          ),
          if (hasAvatar) ...[
            const SizedBox(height: 24),
            _DataSaverCard(enabled: dataSaverEnabled),
          ],
        ],
      ),
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
/// persisted via shared preferences using the same pattern as the
/// data-saver toggle.
class _PrivacyCard extends ConsumerWidget {
  const _PrivacyCard({required this.sendEnabled, required this.receiveEnabled});

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
                  ref.read(avatarAntiEntropyProvider.notifier).reschedule();
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
