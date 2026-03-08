/// Invitations floating button widget for Haven.
///
/// A floating circular button that provides access to the invitations page
/// from the map view, with a badge showing the pending invitation count.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/pages/invitations/invitations_page.dart';
import 'package:haven/src/providers/invitation_count_provider.dart';

/// A floating button that navigates to the invitations page.
///
/// Styled consistently with [SettingsFloatingButton]. Displays a [Badge]
/// with the pending invitation count when invitations are available.
class InvitationsFloatingButton extends ConsumerWidget {
  /// Creates an invitations floating button.
  const InvitationsFloatingButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorScheme = Theme.of(context).colorScheme;
    final count = ref.watch(invitationCountProvider);

    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surface,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.15),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Badge(
        isLabelVisible: count > 0,
        label: Text('$count'),
        child: IconButton(
          icon: Icon(count > 0 ? Icons.mail : Icons.mail_outlined),
          color: colorScheme.onSurface,
          tooltip: count > 0
              ? '$count pending invitation${count == 1 ? '' : 's'}'
              : 'Invitations',
          onPressed: () {
            Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (context) => const InvitationsPage(),
              ),
            );
          },
        ),
      ),
    );
  }
}
