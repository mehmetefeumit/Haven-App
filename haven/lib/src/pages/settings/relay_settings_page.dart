/// Relay settings page for Haven.
///
/// Shows default relay list and per-relay event publication status.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/relay_status_provider.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:haven/src/widgets/widgets.dart';

/// Page displaying relay status and event publication info.
class RelaySettingsPage extends ConsumerStatefulWidget {
  /// Creates the relay settings page.
  const RelaySettingsPage({super.key});

  @override
  ConsumerState<RelaySettingsPage> createState() => _RelaySettingsPageState();
}

class _RelaySettingsPageState extends ConsumerState<RelaySettingsPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(relayStatusProvider.notifier).checkAllRelays();
    });
  }

  @override
  Widget build(BuildContext context) {
    final identity = ref.watch(identityProvider);
    final relayStatus = ref.watch(relayStatusProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Relays'),
        actions: [
          relayStatus.when(
            data: (state) => state.isRefreshing
                ? const Padding(
                    padding: EdgeInsets.all(HavenSpacing.base),
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : IconButton(
                    icon: const Icon(Icons.refresh),
                    tooltip: 'Check relays',
                    onPressed: () {
                      ref.read(relayStatusProvider.notifier).checkAllRelays();
                    },
                  ),
            loading: () => const Padding(
              padding: EdgeInsets.all(HavenSpacing.base),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
            error: (_, _) => IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: () {
                ref.read(relayStatusProvider.notifier).checkAllRelays();
              },
            ),
          ),
        ],
      ),
      body: identity.when(
        data: (id) => id == null
            ? const HavenEmptyState(
                icon: Icons.person_off,
                title: 'No Identity',
                message:
                    'Create a Nostr identity first to publish '
                    'events to relays.',
              )
            : _buildRelayList(context, relayStatus),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) => const HavenEmptyState(
          icon: Icons.error_outline,
          message: 'Failed to load identity.',
        ),
      ),
    );
  }

  Widget _buildRelayList(
    BuildContext context,
    AsyncValue<RelayStatusState> relayStatus,
  ) {
    final colorScheme = Theme.of(context).colorScheme;

    return relayStatus.when(
      data: (state) => ListView(
        padding: const EdgeInsets.all(HavenSpacing.base),
        children: [
          // Info card
          Card(
            color: colorScheme.primaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(HavenSpacing.base),
              child: Row(
                children: [
                  Icon(Icons.dns, color: colorScheme.onPrimaryContainer),
                  const SizedBox(width: HavenSpacing.md),
                  Expanded(
                    child: Text(
                      'Relays store your KeyPackage and relay list so '
                      'others can invite you to circles.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colorScheme.onPrimaryContainer,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: HavenSpacing.base),

          // Relay cards
          for (final relay in state.relays) ...[
            _RelayCard(relay: relay),
            const SizedBox(height: HavenSpacing.sm),
          ],

          // Last checked timestamp
          if (state.lastChecked != null)
            Padding(
              padding: const EdgeInsets.only(top: HavenSpacing.sm),
              child: Text(
                'Last checked: ${_formatTimestamp(state.lastChecked!)}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
            ),
        ],
      ),
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (_, _) => const HavenEmptyState(
        icon: Icons.error_outline,
        message: 'Failed to load relay status.',
      ),
    );
  }

  String _formatTimestamp(DateTime timestamp) {
    final now = DateTime.now();
    final diff = now.difference(timestamp);
    if (diff.inSeconds < 60) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }
}

class _RelayCard extends StatelessWidget {
  const _RelayCard({required this.relay});

  final RelayEventStatus relay;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    // Strip wss:// prefix for display
    final displayUrl = relay.relayUrl.replaceFirst('wss://', '');

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(HavenSpacing.base),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Relay URL header
            Row(
              children: [
                Icon(
                  Icons.cloud,
                  size: 20,
                  color: colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: HavenSpacing.sm),
                Expanded(
                  child: Text(
                    displayUrl,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
              ],
            ),
            const SizedBox(height: HavenSpacing.md),

            // Kind 443 status row
            _StatusRow(label: 'KeyPackage (443)', result: relay.keyPackage),
            const SizedBox(height: HavenSpacing.sm),

            // Kind 10051 status row
            _StatusRow(label: 'Relay List (10051)', result: relay.relayList),
          ],
        ),
      ),
    );
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({required this.label, required this.result});

  final String label;
  final KindCheckResult result;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    final (
      IconData icon,
      Color color,
      String statusText,
    ) = switch (result.status) {
      EventCheckStatus.pending => (
        Icons.circle_outlined,
        colorScheme.onSurfaceVariant,
        'Not checked',
      ),
      EventCheckStatus.checking => (
        Icons.hourglass_empty,
        colorScheme.onSurfaceVariant,
        'Checking...',
      ),
      EventCheckStatus.found => (
        Icons.check_circle,
        HavenSecurityColors.encrypted,
        result.newestTimestamp != null
            ? _formatRelativeTime(result.newestTimestamp!)
            : 'Found',
      ),
      EventCheckStatus.notFound => (
        Icons.cancel,
        HavenSecurityColors.warning,
        'Not found',
      ),
      EventCheckStatus.error => (
        Icons.error,
        HavenSecurityColors.danger,
        'Error',
      ),
    };

    return Row(
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: HavenSpacing.sm),
        Expanded(
          child: Text(label, style: Theme.of(context).textTheme.bodySmall),
        ),
        Text(
          statusText,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: color),
        ),
      ],
    );
  }

  String _formatRelativeTime(DateTime timestamp) {
    final now = DateTime.now();
    final diff = now.difference(timestamp);
    if (diff.inSeconds < 60) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 30) return '${diff.inDays}d ago';
    return '${timestamp.month}/${timestamp.day}/${timestamp.year}';
  }
}
