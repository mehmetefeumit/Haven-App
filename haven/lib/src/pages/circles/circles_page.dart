/// Circles page for Haven.
///
/// Manages user's circles - groups of trusted contacts for location sharing.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:haven/src/pages/circles/create_circle_page.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/invitation_provider.dart';
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
    final invitationsAsync = ref.watch(pendingInvitationsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Circles'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Check for invitations',
            onPressed: () {
              ref
                ..invalidate(invitationPollerProvider)
                ..invalidate(pendingInvitationsProvider)
                ..invalidate(circlesProvider);
            },
          ),
          const EncryptionBadge(size: EncryptionBadgeSize.small),
          const SizedBox(width: HavenSpacing.base),
        ],
      ),
      body: _buildBody(
        context,
        circlesAsync: circlesAsync,
        invitationsAsync: invitationsAsync,
      ),
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
    required AsyncValue<List<Invitation>> invitationsAsync,
  }) {
    final circles = circlesAsync.valueOrNull ?? [];
    final invitations = invitationsAsync.valueOrNull ?? [];

    // Show empty state when both are empty and not loading
    if (circles.isEmpty &&
        invitations.isEmpty &&
        !circlesAsync.isLoading &&
        !invitationsAsync.isLoading) {
      return const _CirclesEmptyState();
    }

    // Show loading indicator while both are loading initially
    if (circlesAsync.isLoading && invitationsAsync.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    return ListView(
      children: [
        // Pending invitations section
        if (invitations.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(
              HavenSpacing.base,
              HavenSpacing.base,
              HavenSpacing.base,
              HavenSpacing.sm,
            ),
            child: Text(
              'Pending Invitations',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          for (final invitation in invitations)
            InvitationCard(invitation: invitation),
          const SizedBox(height: HavenSpacing.sm),
        ],

        // Circles section
        if (circles.isNotEmpty) ...[
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
