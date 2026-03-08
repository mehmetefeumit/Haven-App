/// Circles page for Haven.
///
/// Manages user's circles - groups of trusted contacts for location sharing.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:haven/src/pages/circles/create_circle_page.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:haven/src/widgets/widgets.dart';

/// Page displaying and managing user's circles.
///
/// Shows a list of circles with pending invitations highlighted at the top.
/// Requires identity setup before circle creation is enabled.
class CirclesPage extends ConsumerWidget {
  /// Creates the circles page.
  const CirclesPage({super.key});

  /// Handles the create circle button press.
  void _onCreateCirclePressed(BuildContext context) {
    Navigator.push<void>(
      context,
      MaterialPageRoute(builder: (context) => const CreateCirclePage()),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final identityAsync = ref.watch(identityProvider);
    final circlesAsync = ref.watch(circlesProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Circles'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh circles',
            onPressed: () {
              ref.invalidate(circlesProvider);
            },
          ),
          const EncryptionBadge(size: EncryptionBadgeSize.small),
          const SizedBox(width: HavenSpacing.base),
        ],
      ),
      body: _buildBody(context, circlesAsync: circlesAsync),
      floatingActionButton: identityAsync.when(
        data: (identity) => FloatingActionButton.extended(
          onPressed: identity != null
              ? () => _onCreateCirclePressed(context)
              : () {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                        'Circle creation requires identity setup first',
                      ),
                    ),
                  );
                },
          icon: const Icon(Icons.add),
          label: const Text('Create Circle'),
        ),
        loading: () => null,
        error: (_, _) => FloatingActionButton.extended(
          onPressed: () {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Circle creation requires identity setup first'),
              ),
            );
          },
          icon: const Icon(Icons.add),
          label: const Text('Create Circle'),
        ),
      ),
    );
  }

  Widget _buildBody(
    BuildContext context, {
    required AsyncValue<List<Circle>> circlesAsync,
  }) {
    final circles = circlesAsync.valueOrNull ?? [];

    if (circles.isEmpty && !circlesAsync.isLoading) {
      return const _CirclesEmptyState();
    }

    if (circlesAsync.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    return ListView(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            HavenSpacing.base,
            HavenSpacing.sm,
            HavenSpacing.base,
            HavenSpacing.sm,
          ),
          child: Text(
            'Your Circles',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        for (final circle in circles) CircleListTile(circle: circle),
      ],
    );
  }
}

class _CirclesEmptyState extends StatelessWidget {
  const _CirclesEmptyState();

  @override
  Widget build(BuildContext context) {
    return const HavenEmptyState(
      icon: Icons.groups_outlined,
      title: 'No Circles Yet',
      message:
          'Create a circle to start sharing your location '
          'with trusted friends and family. '
          'All location data is end-to-end encrypted.',
    );
  }
}
