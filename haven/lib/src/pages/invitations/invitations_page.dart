/// Dedicated invitations page for Haven.
///
/// Displays all pending circle invitations with auto-poll on open
/// and manual refresh support.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/pages/settings/relay_settings_page.dart';
import 'package:haven/src/providers/invitation_poll_status_provider.dart';
import 'package:haven/src/providers/invitation_provider.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/widgets/circles/invitation_card.dart';
import 'package:haven/src/widgets/common/empty_state.dart';
import 'package:haven/src/widgets/common/refresh_ring/refresh_ring_button.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

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
    // Ping the inbox relays as soon as the page opens; the Settle Pill shows
    // the result, and the notifier refreshes the list if anything new arrives.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _refresh();
    });
  }

  void _refresh() {
    // The background poller (invitationPollerProvider, driven by MapShell) may
    // also be polling the same inbox relays; both paths de-duplicate via the
    // Rust processed-gift-wraps table, so a rare concurrent overlap is safe.
    unawaited(ref.read(invitationPollStatusProvider.notifier).refresh());
  }

  void _openInboxSettings() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (context) => const RelaySettingsPage()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final invitationsAsync = ref.watch(pendingInvitationsProvider);
    // Drives the app-bar refresh ring: per-relay slots plus the no-inbox state.
    final pollStatus = ref.watch(invitationPollStatusProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.commonInvitations),
        actions: [
          RefreshRingButton(
            key: WidgetKeys.invitationsRefresh,
            slots: pollStatus.slots,
            onPressed: _refresh,
            tooltip: l10n.invitationsRefreshTooltip,
            noInbox: pollStatus.outcome == InvitationPollOutcome.noInbox,
            onNoInbox: _openInboxSettings,
          ),
        ],
      ),
      body: invitationsAsync.when(
        data: (invitations) => _buildList(l10n, invitations),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) => Center(child: Text(l10n.invitationsLoadError)),
      ),
    );
  }

  Widget _buildList(AppLocalizations l10n, List<Invitation> invitations) {
    if (invitations.isEmpty) {
      return HavenEmptyState(
        icon: LucideIcons.mail,
        title: l10n.invitationsEmptyTitle,
        message: l10n.invitationsEmptyMessage,
      );
    }

    return ListView.builder(
      itemCount: invitations.length,
      itemBuilder: (context, index) =>
          InvitationCard(invitation: invitations[index]),
    );
  }
}
