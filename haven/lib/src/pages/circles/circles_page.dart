/// Circles page for Haven.
///
/// Manages user's circles - groups of trusted contacts for location sharing.
library;

import 'package:flutter/material.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:haven/src/widgets/widgets.dart';

/// Page displaying and managing user's circles.
///
/// Shows a list of circles with pending invitations highlighted at the top.
/// Full circle management will be enabled once Nostr relay integration is
/// complete.
class CirclesPage extends StatelessWidget {
  /// Creates the circles page.
  const CirclesPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Circles'),
        actions: const [
          EncryptionBadge(size: EncryptionBadgeSize.small),
          SizedBox(width: HavenSpacing.base),
        ],
      ),
      body: const _CirclesEmptyState(),
      floatingActionButton: FloatingActionButton.extended(
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
