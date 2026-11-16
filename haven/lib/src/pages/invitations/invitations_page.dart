/// Dedicated invitations page for Haven.
///
/// Displays all pending circle invitations with an inbox read on open,
/// manual refresh, and a notice when a read did not reach every relay.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/pages/settings/relay_settings_page.dart';
import 'package:haven/src/providers/invitation_poll_status_provider.dart';
import 'package:haven/src/providers/invitation_provider.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/theme/theme.dart';
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
    // Read the inbox relays as soon as the page opens; the ring and the notice
    // show the result, and the notifier refreshes the list if anything new
    // arrives.
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

  /// Opens Relay settings, and reads the inbox again on return so a notice
  /// the user just fixed there does not outlive the fix.
  Future<void> _openInboxSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (context) => const RelaySettingsPage()),
    );
    if (!mounted) return;
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final invitationsAsync = ref.watch(pendingInvitationsProvider);
    // Drives the app-bar refresh ring (per-relay slots plus the no-inbox
    // state) and the notice above the list.
    final pollStatus = ref.watch(invitationPollStatusProvider);
    final notice = _noticeFor(l10n, pollStatus);

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
        data: (invitations) => _scroll(
          notice,
          invitations.isEmpty
              ? _fill(
                  HavenEmptyState(
                    icon: LucideIcons.mail,
                    title: l10n.invitationsEmptyTitle,
                    message: l10n.invitationsEmptyMessage,
                  ),
                )
              : SliverList.builder(
                  itemCount: invitations.length,
                  itemBuilder: (context, index) =>
                      InvitationCard(invitation: invitations[index]),
                ),
        ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) => _scroll(
          notice,
          _fill(
            HavenEmptyState(
              icon: LucideIcons.circleAlert,
              message: l10n.invitationsLoadError,
              actionLabel: l10n.commonRetry,
              onAction: () => ref.invalidate(pendingInvitationsProvider),
            ),
          ),
        ),
      ),
    );
  }

  /// The notice a settled refresh calls for, or `null` when it read every
  /// relay and nothing failed.
  Widget? _noticeFor(AppLocalizations l10n, InvitationPollStatus status) =>
      switch (status.outcome) {
        InvitationPollOutcome.refused => _InboxNotice(
          message: l10n.invitationsNoticeRefused(status.refused),
          actionLabel: l10n.invitationsNoticeOpenRelaySettings,
          onAction: _openInboxSettings,
        ),
        InvitationPollOutcome.notSaved => _InboxNotice(
          message: l10n.invitationsNoticeNotSaved(status.notSaved),
          actionLabel: l10n.commonTryAgain,
          onAction: _refresh,
        ),
        InvitationPollOutcome.offline => _InboxNotice(
          message: l10n.invitationsNoticeOffline,
          actionLabel: l10n.commonTryAgain,
          onAction: _refresh,
        ),
        InvitationPollOutcome.incomplete => _InboxNotice(
          message: l10n.invitationsNoticeIncomplete,
          actionLabel: l10n.invitationsNoticeOpenRelaySettings,
          onAction: _openInboxSettings,
        ),
        // The ring itself routes a missing inbox to Relay settings.
        InvitationPollOutcome.noInbox ||
        InvitationPollOutcome.newInvites ||
        InvitationPollOutcome.upToDate ||
        null => null,
      };

  Widget _scroll(Widget? notice, Widget content) => CustomScrollView(
    slivers: [
      if (notice != null)
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(
            HavenSpacing.base,
            HavenSpacing.base,
            HavenSpacing.base,
            0,
          ),
          sliver: SliverToBoxAdapter(child: notice),
        ),
      content,
    ],
  );

  /// Viewport-filling placeholder content that scrolls when taller.
  Widget _fill(Widget child) =>
      SliverFillRemaining(hasScrollBody: false, child: child);
}

/// Why the last refresh did not read every inbox relay in full, with the
/// one action that helps.
///
/// One container, so a screen reader moves through its sentence and its
/// button together; not a live region, because the ring already announces
/// the refresh's result and two announcements would talk over each other.
/// Names no relay: the page never holds a relay URL.
class _InboxNotice extends StatelessWidget {
  const _InboxNotice({
    required this.message,
    required this.actionLabel,
    required this.onAction,
  });

  final String message;
  final String actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      container: true,
      child: Container(
        key: WidgetKeys.invitationsInboxNotice,
        padding: const EdgeInsets.all(HavenSpacing.md),
        decoration: BoxDecoration(
          color: HavenSecurityColors.warning.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(HavenSpacing.sm),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const ExcludeSemantics(
              child: Icon(
                LucideIcons.triangleAlert,
                size: 18,
                color: HavenSecurityColors.warning,
              ),
            ),
            const SizedBox(width: HavenSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    message,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: TextButton(
                      onPressed: onAction,
                      child: Text(actionLabel),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
