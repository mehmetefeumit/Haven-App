/// Sender retention settings page.
///
/// Lets the user choose how long receivers should keep their last-known
/// location on disk after the user stops broadcasting. The chosen value
/// is embedded inside every outgoing encrypted `LocationMessage` as a
/// soft privacy contract. A value of `Never` publishes `0`, instructing
/// honest receivers to discard the row immediately.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/location_sharing_provider.dart';
import 'package:haven/src/providers/sender_retention_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/theme/theme.dart';

/// Page for configuring sender-controlled last-known-location retention.
class SenderRetentionSettingsPage extends ConsumerWidget {
  /// Creates a sender retention settings page.
  const SenderRetentionSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final selectedSecs = ref.watch(senderRetentionProvider);
    final circleService = ref.read(circleServiceProvider);
    final receiverCeilingSecs = circleService.locationReceiverMaxRetentionSecs;

    return Scaffold(
      appBar: AppBar(title: const Text('Location Retention')),
      body: ListView(
        padding: const EdgeInsets.all(HavenSpacing.base),
        children: [
          Card(
            color: colorScheme.primaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(HavenSpacing.base),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.schedule, color: colorScheme.onPrimaryContainer),
                  const SizedBox(width: HavenSpacing.md),
                  Expanded(
                    child: Text(
                      'Choose how long circle members should keep your '
                      'last-known location after you stop sharing. When '
                      'the time expires, their app will automatically '
                      'remove your pin.',
                      style: textTheme.bodySmall?.copyWith(
                        color: colorScheme.onPrimaryContainer,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: HavenSpacing.lg),
          Text(
            'Retention Duration',
            style: textTheme.titleSmall?.copyWith(color: colorScheme.primary),
          ),
          const SizedBox(height: HavenSpacing.sm),
          Card(
            child: RadioGroup<int>(
              groupValue: selectedSecs,
              onChanged: (value) async {
                if (value == null) return;
                await ref
                    .read(senderRetentionProvider.notifier)
                    .setRetention(value);
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Retention set to ${_formatDuration(value)}'),
                    duration: const Duration(seconds: 2),
                  ),
                );
              },
              child: Column(
                children: [
                  for (final secs in kSenderRetentionPresets)
                    RadioListTile<int>(
                      value: secs,
                      title: Text(_formatDuration(secs)),
                      subtitle: Text(_describePreset(secs)),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: HavenSpacing.lg),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: HavenSpacing.sm),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.info_outline,
                  size: 16,
                  color: colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: HavenSpacing.sm),
                Expanded(
                  child: Text(
                    'The maximum retention allowed is '
                    '${_formatDuration(receiverCeilingSecs)}. Longer '
                    'durations will be reduced to this limit.',
                    style: textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: HavenSpacing.lg),
          Card(
            child: ListTile(
              leading: Icon(Icons.cleaning_services, color: colorScheme.error),
              title: const Text('Clear My Location From Others'),
              subtitle: const Text(
                'Sends a request to all your circles to remove your '
                'last-known location immediately.',
              ),
              onTap: () => _handleClearLocation(context, ref),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _handleClearLocation(BuildContext context, WidgetRef ref) async {
    final colorScheme = Theme.of(context).colorScheme;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Clear Location?'),
        content: const Text(
          'This will ask all your circles to remove your last-known '
          'location. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: TextButton.styleFrom(foregroundColor: colorScheme.error),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    // Show a modal loading dialog while the cascade runs. The cascade
    // performs an identity read, a local wipe, and a relay publish, so
    // it can take several seconds on slow networks. Blocking interaction
    // avoids double-triggers.
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const Center(child: CircularProgressIndicator()),
      ),
    );

    final circleService = ref.read(circleServiceProvider);
    final notifier = ref.read(senderRetentionProvider.notifier);
    final previous = ref.read(senderRetentionProvider);

    try {
      // Step 1: wipe the user's own local last-known rows FIRST, across
      // every circle (including hidden ones) via the single sender-wide
      // FFI. Doing this BEFORE the relay publish guarantees that no
      // echoed self-broadcast from the in-flight publish can re-seed
      // our own pin into the local cache after the wipe.
      try {
        final identity = await ref.read(identityProvider.future);
        final ownPubkey = identity?.pubkeyHex;
        if (ownPubkey != null) {
          await circleService.removeLastKnownForSender(senderPubkey: ownPubkey);
        }
      } on Object catch (e) {
        debugPrint('[SenderRetention] local self-wipe failed: $e');
      }

      // Step 2: temporarily flip retention to 0, force an immediate
      // publish via the publisher provider (which reads the retention
      // value at invocation time), then restore the previous preference.
      await notifier.setRetention(0);
      try {
        ref.invalidate(locationPublisherProvider);
        await ref.read(locationPublisherProvider.future);
      } on Object catch (e) {
        debugPrint('[SenderRetention] clear publish failed: $e');
      } finally {
        await notifier.setRetention(previous);
      }
    } finally {
      // Dismiss the loading dialog regardless of outcome.
      if (context.mounted) {
        Navigator.of(context, rootNavigator: true).pop();
      }
    }

    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Clear request sent to all circles'),
        duration: Duration(seconds: 3),
      ),
    );
  }

  String _describePreset(int secs) {
    if (secs == 0) {
      return 'Circle members remove your location when a new update arrives';
    }
    return 'Circle members keep your last pin for up to ${_formatDuration(secs)}';
  }

  String _formatDuration(int secs) {
    if (secs == 0) return 'Never';
    if (secs < 3600) {
      final mins = secs ~/ 60;
      return '$mins min';
    }
    if (secs < 24 * 3600) {
      final hours = secs ~/ 3600;
      return hours == 1 ? '1 hour' : '$hours hours';
    }
    final days = secs ~/ (24 * 3600);
    return days == 1 ? '1 day' : '$days days';
  }
}
