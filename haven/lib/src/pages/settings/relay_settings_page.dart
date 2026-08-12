/// Editable relay settings page for Haven.
///
/// Shows three independent relay categories — Inbox (kind 10050), KeyPackage
/// (kind 10002), and Profile (kind-0, local-only policy — never published)
/// — with add/remove/restore controls, plus a short caption linking to
/// Privacy ▸ Relays for the full explanation. The Profile section also shows
/// an advisory, non-blocking warning on any row whose relay already carries
/// this account's location-plane traffic — circle, inbox, KeyPackage or
/// discovery-plane lookups (see
/// `profileRelayContaminationProvider`), and — distinct from that per-row
/// warning — a banner when the pool has underflowed entirely: too few
/// usable Profile relays remain to look up anyone's profile, so member
/// names/photos silently stop updating with no other visible signal (see
/// `_ProfilePoolUnderflowBanner`, `profilePoolStatusProvider`).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/pages/settings/add_relay_sheet.dart';
import 'package:haven/src/pages/settings/privacy_content.dart';
import 'package:haven/src/pages/settings/privacy_topic_page.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/legacy_retraction_provider.dart';
import 'package:haven/src/providers/relay_preferences_provider.dart';
import 'package:haven/src/providers/relay_status_provider.dart';
import 'package:haven/src/services/relay_preferences_service.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:haven/src/widgets/common/refresh_ring/refresh_ring_button.dart';
import 'package:haven/src/widgets/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Editable settings page for the user's relay preferences.
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
      if (!mounted) return;
      ref.read(relayStatusProvider.notifier).checkAllRelays();
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final identity = ref.watch(identityProvider);
    final relayStatus = ref.watch(relayStatusProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.relaySettingsTitle),
        actions: [
          // One ring per relay being checked (union of inbox + KeyPackage).
          // During loading / error the slots are empty, so the ring shows the
          // plain refresh icon. Replaces the former spinner-swap.
          RefreshRingButton(
            slots: relayStatus.valueOrNull?.ringSlots ?? const [],
            onPressed: () =>
                ref.read(relayStatusProvider.notifier).checkAllRelays(),
            tooltip: l10n.relaySettingsCheckRelaysTooltip,
            // Green/red here mean "holds your data" vs "missing it / unreachable"
            // — not "answered" — so use the data-centric a11y vocabulary.
            vocabulary: RefreshRingVocabulary.hasData,
          ),
        ],
      ),
      body: identity.when(
        data: (id) => id == null
            ? HavenScrollFill(
                child: HavenEmptyState(
                  icon: LucideIcons.userX,
                  title: l10n.relaySettingsNoIdentityTitle,
                  message: l10n.relaySettingsNoIdentityMessage,
                ),
              )
            : _buildBody(l10n),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) => HavenScrollFill(
          child: HavenEmptyState(
            icon: LucideIcons.circleAlert,
            message: l10n.relaySettingsLoadIdentityError,
          ),
        ),
      ),
    );
  }

  Widget _buildBody(AppLocalizations l10n) {
    return ListView(
      padding: const EdgeInsets.all(HavenSpacing.base),
      children: [
        _RelaySection(
          category: RelayCategory.inbox,
          title: l10n.relaySettingsInboxTitle,
          subtitle: l10n.relaySettingsInboxSubtitle,
        ),
        const SizedBox(height: HavenSpacing.lg),
        _RelaySection(
          category: RelayCategory.keyPackage,
          title: l10n.relaySettingsKeyPackageTitle,
          subtitle: l10n.relaySettingsKeyPackageSubtitle,
        ),
        const SizedBox(height: HavenSpacing.lg),
        _RelaySection(
          category: RelayCategory.profile,
          title: l10n.relaySettingsProfileTitle,
          subtitle: l10n.relaySettingsProfileSubtitle,
        ),
        const SizedBox(height: HavenSpacing.lg),
        const _LegacyRetractionPendingNote(),
        const _BackendCaption(),
        const SizedBox(height: HavenSpacing.base),
      ],
    );
  }
}

/// Subtle, non-blocking note shown only while the Dark Matter cutover's
/// once-only legacy-KeyPackage retraction (plan §6 F10b) has not yet
/// completed — most commonly because no relay was reachable this session.
/// Absent entirely once the retraction succeeds (or was already done), so
/// most users never see it.
class _LegacyRetractionPendingNote extends ConsumerWidget {
  const _LegacyRetractionPendingNote();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(legacyRetractionProvider).valueOrNull;
    if (status != LegacyRetractionUiStatus.pending) {
      return const SizedBox.shrink();
    }
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: HavenSpacing.lg),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            LucideIcons.clock,
            size: 16,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(width: HavenSpacing.xs),
          Expanded(
            child: Text(
              l10n.relaySettingsLegacyRetractionPending,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RelaySection extends ConsumerWidget {
  const _RelaySection({
    required this.category,
    required this.title,
    required this.subtitle,
  });

  final RelayCategory category;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final relays = ref.watch(_listProviderFor(category));
    final status = ref.watch(relayStatusProvider).value;
    // Contamination warning is advisory and Profile-only (task requirement):
    // only watch the set when this section IS the Profile category, so the
    // Inbox/KeyPackage sections neither pay for nor rebuild on it.
    final contaminated = category == RelayCategory.profile
        ? ref.watch(profileRelayContaminationProvider)
        : const <String>{};

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: theme.textTheme.titleSmall?.copyWith(
            color: theme.colorScheme.primary,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          subtitle,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        if (category == RelayCategory.profile) ...[
          const SizedBox(height: HavenSpacing.sm),
          const _ProfilePoolUnderflowBanner(),
        ],
        const SizedBox(height: HavenSpacing.sm),
        relays.when(
          data: (urls) {
            if (urls.isEmpty) {
              return _EmptyCategoryState(category: category);
            }
            return Card(
              child: Column(
                children: [
                  for (var i = 0; i < urls.length; i++)
                    Column(
                      children: [
                        _EditableRelayRow(
                          url: urls[i],
                          status: _statusFor(status, urls[i]),
                          onRemove: () => _removeRelay(context, ref, urls[i]),
                          isContaminated: contaminated.contains(
                            normalizeRelayUrlForComparison(urls[i]),
                          ),
                        ),
                        if (i < urls.length - 1)
                          const Divider(height: 1, indent: HavenSpacing.base),
                      ],
                    ),
                ],
              ),
            );
          },
          loading: () => const HavenSkeletonList(itemCount: 3),
          error: (_, _) => HavenEmptyState(
            icon: LucideIcons.circleAlert,
            message: l10n.relaySettingsLoadRelaysError,
          ),
        ),
        const SizedBox(height: HavenSpacing.sm),
        Wrap(
          spacing: HavenSpacing.sm,
          children: [
            OutlinedButton.icon(
              icon: const Icon(LucideIcons.plus, size: 16),
              label: Text(l10n.relaySettingsAddRelay),
              onPressed: () => _onAddRelayTapped(context, ref),
            ),
            TextButton.icon(
              icon: const Icon(LucideIcons.rotateCcw, size: 16),
              label: Text(l10n.relaySettingsRestoreDefaults),
              onPressed: () => _onRestoreDefaultsTapped(context, ref),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _onAddRelayTapped(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final l10n = AppLocalizations.of(context);
    final canonical = await showAddRelaySheet(context, category: category);
    if (canonical == null) return;
    try {
      final notifier = _notifierFor(ref, category);
      await notifier.addRelay(canonical);
      // Kick off a status check so the new relay row's dot updates from
      // "Not checked" to its real state without requiring the user to
      // tap the refresh icon. The check is async and bounded by the
      // relay status notifier's own concurrency model.
      // ignore: unawaited_futures
      ref.read(relayStatusProvider.notifier).checkAllRelays();
    } on RelayValidationError catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } on Object {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.relaySettingsAddRelayError)),
      );
    }
  }

  Future<void> _removeRelay(
    BuildContext context,
    WidgetRef ref,
    String url,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final l10n = AppLocalizations.of(context);
    try {
      final notifier = _notifierFor(ref, category);
      await notifier.removeRelay(url);
    } on RelayValidationError catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } on Object {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.relaySettingsRemoveRelayError)),
      );
    }
  }

  Future<void> _onRestoreDefaultsTapped(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final scheme = Theme.of(context).colorScheme;
    final messenger = ScaffoldMessenger.of(context);
    final l10n = AppLocalizations.of(context);
    final list = ref.read(_listProviderFor(category)).value ?? const [];
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.relaySettingsRestoreTitle),
        content: Text(l10n.relaySettingsRestoreBody(list.length)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: scheme.error),
            child: Text(l10n.relaySettingsRestoreConfirm),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _notifierFor(ref, category).wipeAndReset();
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.relaySettingsRestoreSuccess)),
      );
    } on Object {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.relaySettingsRestoreError)),
      );
    }
  }
}

RelayCategoryNotifier _notifierFor(WidgetRef ref, RelayCategory category) =>
    switch (category) {
      RelayCategory.inbox => ref.read(inboxRelaysProvider.notifier),
      RelayCategory.keyPackage => ref.read(keyPackageRelaysProvider.notifier),
      RelayCategory.profile => ref.read(profileRelaysProvider.notifier),
    };

ProviderListenable<AsyncValue<List<String>>> _listProviderFor(
  RelayCategory category,
) => switch (category) {
  RelayCategory.inbox => inboxRelaysProvider,
  RelayCategory.keyPackage => keyPackageRelaysProvider,
  RelayCategory.profile => profileRelaysProvider,
};

RelayEventStatus? _statusFor(RelayStatusState? state, String url) {
  if (state == null) return null;
  for (final r in state.relays) {
    if (r.relayUrl == url) return r;
  }
  return null;
}

class _EditableRelayRow extends StatelessWidget {
  const _EditableRelayRow({
    required this.url,
    required this.status,
    required this.onRemove,
    this.isContaminated = false,
  });

  final String url;
  final RelayEventStatus? status;
  final VoidCallback onRemove;

  /// Advisory-only: `true` when this relay also carries the account's
  /// location-plane traffic — circle, inbox, KeyPackage or discovery-plane
  /// lookups (see `profileRelayContaminationProvider`).
  /// Only ever set for Profile-section rows. Never gates [onRemove] or the
  /// Add-relay flow — it is purely informational.
  final bool isContaminated;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final displayUrl = url.replaceFirst('wss://', '');
    return ListTile(
      leading: _StatusDot(status: status),
      title: Text(displayUrl, style: theme.textTheme.bodyMedium),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isContaminated) _ContaminationWarningIcon(url: displayUrl),
          IconButton(
            tooltip: l10n.relaySettingsRemoveTooltip(displayUrl),
            icon: const Icon(LucideIcons.trash2),
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }
}

/// Advisory warning icon shown next to a Profile-relay row whose URL also
/// carries the account's circle or inbox traffic.
///
/// Follows the same [Tooltip] + [Semantics] pattern as [_StatusDot]: a short
/// visible tooltip plus a fuller screen-reader label that names the relay so
/// the warning is understandable out of visual context.
class _ContaminationWarningIcon extends StatelessWidget {
  const _ContaminationWarningIcon({required this.url});

  /// Display URL (`wss://` stripped), named in the accessibility label.
  final String url;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Tooltip(
      message: l10n.relaySettingsProfileContaminationTooltip,
      child: Semantics(
        label: l10n.relaySettingsProfileContaminationSemantics(url),
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 4),
          child: Icon(
            LucideIcons.triangleAlert,
            color: HavenSecurityColors.warning,
            size: 18,
          ),
        ),
      ),
    );
  }
}

/// Warning banner shown at the top of the Profile section when the
/// profile-plane relay pool has underflowed
/// ([ProfilePoolStatus.isUnderflow] — see that type's doc for why only
/// counts, never URLs, ever reach this layer). Absent for every other
/// status, including while the status is still loading or failed to load,
/// so most users never see it.
///
/// An underflow otherwise has no visible signal at all: the Rust-side
/// profile fetch (`fetchMemberProfiles`) silently falls back to cached rows
/// and skips the network, so members' names and photos just quietly stop
/// updating. This banner exists specifically to surface that and offer the
/// fix.
class _ProfilePoolUnderflowBanner extends ConsumerWidget {
  const _ProfilePoolUnderflowBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(profilePoolStatusProvider).valueOrNull;
    if (status == null || !status.isUnderflow) {
      return const SizedBox.shrink();
    }
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: HavenSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          HavenInfoNote(
            icon: LucideIcons.triangleAlert,
            tone: HavenInfoNoteTone.warning,
            title: l10n.relaySettingsProfileUnderflowTitle,
            paragraphs: [l10n.relaySettingsProfileUnderflowMessage],
          ),
          const SizedBox(height: HavenSpacing.sm),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              icon: const Icon(LucideIcons.rotateCcw, size: 16),
              label: Text(l10n.relaySettingsProfileUnderflowRestoreButton),
              onPressed: () => _onRestore(context, ref),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _onRestore(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final l10n = AppLocalizations.of(context);
    try {
      final service = await ref.read(relayPreferencesServiceProvider.future);
      await service.restoreDefaultProfileRelays();
      // Refresh both the visible Profile relay list (the recovery action
      // adds back curated relays directly at the storage layer, bypassing
      // `ProfileRelaysNotifier`'s own mutation methods) and the status this
      // banner watches, so a successful recovery clears itself immediately.
      ref
        ..invalidate(profileRelaysProvider)
        ..invalidate(profilePoolStatusProvider);
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.relaySettingsRestoreSuccess)),
      );
    } on Object {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.relaySettingsRestoreError)),
      );
    }
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.status});

  final RelayEventStatus? status;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final overall = _summarize(status);
    final (Color color, IconData icon, String label) = switch (overall) {
      _OverallStatus.connected => (
        HavenSecurityColors.encrypted,
        LucideIcons.circleCheck,
        l10n.relaySettingsStatusConnected,
      ),
      _OverallStatus.checking => (
        scheme.onSurfaceVariant,
        LucideIcons.loaderCircle,
        l10n.relaySettingsStatusChecking,
      ),
      _OverallStatus.unreachable => (
        HavenSecurityColors.warning,
        LucideIcons.circleAlert,
        l10n.relaySettingsStatusUnreachable,
      ),
      _OverallStatus.notChecked => (
        scheme.outline,
        LucideIcons.circle,
        l10n.relaySettingsStatusNotChecked,
      ),
    };
    return Tooltip(
      message: label,
      child: Semantics(
        label: l10n.relaySettingsStatusSemantics(label),
        child: Icon(icon, color: color, size: 20),
      ),
    );
  }

  _OverallStatus _summarize(RelayEventStatus? s) {
    if (s == null) return _OverallStatus.notChecked;
    final all = [s.keyPackage, s.relayList, s.inboxRelayList];
    if (all.any((r) => r.status == EventCheckStatus.checking)) {
      return _OverallStatus.checking;
    }
    if (all.any((r) => r.status == EventCheckStatus.found)) {
      return _OverallStatus.connected;
    }
    if (all.any(
      (r) =>
          r.status == EventCheckStatus.notFound ||
          r.status == EventCheckStatus.error,
    )) {
      return _OverallStatus.unreachable;
    }
    return _OverallStatus.notChecked;
  }
}

enum _OverallStatus { connected, checking, unreachable, notChecked }

class _EmptyCategoryState extends ConsumerWidget {
  const _EmptyCategoryState({required this.category});

  final RelayCategory category;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    return HavenEmptyState(
      icon: LucideIcons.serverCrash,
      title: l10n.relaySettingsEmptyTitle,
      message: l10n.relaySettingsEmptyMessage,
      actionLabel: l10n.relaySettingsRestoreDefaults,
      onAction: () async {
        // Capture the messenger + l10n BEFORE the await so we don't reach into
        // a potentially unmounted context. Surface restore failures via
        // SnackBar — silent failures here strand the user in the empty
        // state with no feedback that retry is needed.
        final messenger = ScaffoldMessenger.of(context);
        final l10n = AppLocalizations.of(context);
        final notifier = _notifierFor(ref, category);
        try {
          await notifier.restoreDefaults();
        } on Object {
          messenger.showSnackBar(
            SnackBar(content: Text(l10n.relaySettingsRestoreError)),
          );
        }
      },
    );
  }
}

/// Short caption below the two relay sections, with a link into the Privacy
/// section for the full explanation.
///
/// This page is a *control* surface, so it keeps only enough framing to make
/// the abstract "Inbox" / "KeyPackage" headers meaningful. The long-form
/// explanation of what a relay is, which lists Haven keeps, and what a relay
/// operator can observe now lives in Privacy ▸ Relays — one place, not two, so
/// the two copies cannot drift apart.
class _BackendCaption extends StatelessWidget {
  const _BackendCaption();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.relaySettingsBackendCaption,
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton(
            onPressed: () => Navigator.push(
              context,
              PrivacyTopicPage.route(PrivacyTopic.relays),
            ),
            child: Text(l10n.commonLearnMore),
          ),
        ),
      ],
    );
  }
}
