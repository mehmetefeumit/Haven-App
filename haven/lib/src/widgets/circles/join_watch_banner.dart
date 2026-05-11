/// Banner shown above the map during a post-circle-add burst-poll window.
///
/// Renders nothing while the watcher is idle. While active, shows a
/// short status message and a dismiss button so the user can cancel
/// the burst early.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:haven/src/providers/join_watcher_provider.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// A persistent, dismissible banner that surfaces the current
/// [JoinWatchState] to the user.
class JoinWatchBanner extends ConsumerWidget {
  /// Creates the banner.
  const JoinWatchBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(joinWatcherProvider);

    if (!state.isActive) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final message = switch (state.mode) {
      JoinWatchMode.adminWaitingForJoin => 'Waiting for member to join…',
      JoinWatchMode.joinerWaitingForLocations => 'Finding circle members…',
      JoinWatchMode.idle => '',
    };

    return Material(
      color: theme.colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Semantics(
          liveRegion: true,
          child: Row(
            children: [
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(
                    theme.colorScheme.onPrimaryContainer,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  message,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
                ),
              ),
              IconButton(
                icon: Icon(
                  LucideIcons.x,
                  size: 18,
                  color: theme.colorScheme.onPrimaryContainer,
                ),
                tooltip: 'Stop waiting',
                visualDensity: VisualDensity.compact,
                onPressed: () =>
                    ref.read(joinWatcherProvider.notifier).cancel(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
