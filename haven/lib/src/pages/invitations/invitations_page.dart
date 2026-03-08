/// Dedicated invitations page for Haven.
///
/// Displays all pending circle invitations with auto-poll on open
/// and manual refresh support.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/providers/invitation_provider.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/widgets/circles/invitation_card.dart';
import 'package:haven/src/widgets/common/empty_state.dart';

/// A page that lists all pending circle invitations.
///
/// Automatically polls for new invitations when opened and provides
/// a refresh button in the app bar. Reuses [InvitationCard] for
/// each invitation entry.
class InvitationsPage extends ConsumerStatefulWidget {
  /// Creates the invitations page.
  const InvitationsPage({super.key});

  @override
  ConsumerState<InvitationsPage> createState() => _InvitationsPageState();
}

class _InvitationsPageState extends ConsumerState<InvitationsPage> {
  @override
  void initState() {
    super.initState();
    // Poll for new invitations as soon as the page opens.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref
        ..invalidate(invitationPollerProvider)
        ..read(invitationPollerProvider);
    });
  }

  void _refresh() {
    ref
      ..invalidate(invitationPollerProvider)
      ..read(invitationPollerProvider)
      ..invalidate(pendingInvitationsProvider);
  }

  @override
  Widget build(BuildContext context) {
    final invitationsAsync = ref.watch(pendingInvitationsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Invitations'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh invitations',
            onPressed: _refresh,
          ),
        ],
      ),
      body: invitationsAsync.when(
        data: (invitations) => _buildList(invitations),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) =>
            const Center(child: Text('Could not load invitations')),
      ),
    );
  }

  Widget _buildList(List<Invitation> invitations) {
    if (invitations.isEmpty) {
      return const HavenEmptyState(
        icon: Icons.mail_outlined,
        title: 'No Invitations',
        message: 'When someone invites you to a circle, it will appear here.',
      );
    }

    return ListView.builder(
      itemCount: invitations.length,
      itemBuilder: (context, index) =>
          InvitationCard(invitation: invitations[index]),
    );
  }
}
