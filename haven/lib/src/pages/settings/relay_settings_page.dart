/// Editable relay settings page for Haven.
///
/// Shows two independent relay categories (Inbox kind 10050 + KeyPackage
/// kind 10051) with add/remove/restore controls.
/// A footer note explains, in plain language, how Haven's relay-based backend
/// works and what the Inbox and KeyPackage relay lists are for.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/pages/settings/add_relay_sheet.dart';
import 'package:haven/src/providers/identity_provider.dart';
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
            ? HavenEmptyState(
                icon: LucideIcons.userX,
                title: l10n.relaySettingsNoIdentityTitle,
                message: l10n.relaySettingsNoIdentityMessage,
              )
            : _buildBody(l10n),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) => HavenEmptyState(
          icon: LucideIcons.circleAlert,
          message: l10n.relaySettingsLoadIdentityError,
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
        const _BackendExplainerNote(),
        const SizedBox(height: HavenSpacing.base),
      ],
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
    };

ProviderListenable<AsyncValue<List<String>>> _listProviderFor(
  RelayCategory category,
) => switch (category) {
  RelayCategory.inbox => inboxRelaysProvider,
  RelayCategory.keyPackage => keyPackageRelaysProvider,
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
  });

  final String url;
  final RelayEventStatus? status;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final displayUrl = url.replaceFirst('wss://', '');
    return ListTile(
      leading: _StatusDot(status: status),
      title: Text(displayUrl, style: theme.textTheme.bodyMedium),
      trailing: IconButton(
        tooltip: l10n.relaySettingsRemoveTooltip(displayUrl),
        icon: const Icon(LucideIcons.trash2),
        onPressed: onRemove,
      ),
    );
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

/// Footer note explaining, in plain language, how Haven's relay-based backend
/// works and what the Inbox and KeyPackage relay lists are for.
///
/// Sits below the two relay sections so the abstract "Inbox" / "KeyPackage"
/// headers have a concrete, accurate explanation. Deliberately avoids raw
/// protocol jargon (kind numbers, MLS) while staying technically correct:
/// relays only ever see end-to-end-encrypted data, never location or circle
/// membership.
class _BackendExplainerNote extends StatelessWidget {
  const _BackendExplainerNote();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final bodyStyle = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final termStyle = bodyStyle?.copyWith(
      color: scheme.onSurface,
      fontWeight: FontWeight.bold,
    );
    return Semantics(
      label: l10n.relaySettingsExplainerSemantics,
      container: true,
      explicitChildNodes: true,
      child: Container(
        padding: const EdgeInsets.all(HavenSpacing.base),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(
              header: true,
              child: Text(
                l10n.relaySettingsExplainerHeading,
                style: theme.textTheme.titleSmall?.copyWith(
                  color: scheme.onSurface,
                ),
              ),
            ),
            const SizedBox(height: HavenSpacing.sm),
            Text(l10n.relaySettingsExplainerNostr, style: bodyStyle),
            const SizedBox(height: HavenSpacing.sm),
            Text(l10n.relaySettingsExplainerMarmot, style: bodyStyle),
            const SizedBox(height: HavenSpacing.sm),
            Text(l10n.relaySettingsExplainerMetadata, style: bodyStyle),
            const SizedBox(height: HavenSpacing.sm),
            Text.rich(
              TextSpan(
                style: bodyStyle,
                children: [
                  TextSpan(
                    text: l10n.relaySettingsExplainerInboxTerm,
                    style: termStyle,
                  ),
                  TextSpan(text: l10n.relaySettingsExplainerInboxBody),
                ],
              ),
            ),
            const SizedBox(height: HavenSpacing.sm),
            Text.rich(
              TextSpan(
                style: bodyStyle,
                children: [
                  TextSpan(
                    text: l10n.relaySettingsExplainerKeyPackageTerm,
                    style: termStyle,
                  ),
                  TextSpan(text: l10n.relaySettingsExplainerKeyPackageBody),
                ],
              ),
            ),
            const SizedBox(height: HavenSpacing.sm),
            Text.rich(
              TextSpan(
                style: bodyStyle,
                children: [
                  TextSpan(
                    text: l10n.relaySettingsExplainerOwnRelayTerm,
                    style: termStyle,
                  ),
                  TextSpan(text: l10n.relaySettingsExplainerOwnRelayBody),
                ],
              ),
            ),
            const SizedBox(height: HavenSpacing.sm),
            Text.rich(
              TextSpan(
                style: bodyStyle,
                children: [
                  TextSpan(
                    text: l10n.relaySettingsExplainerReachabilityTerm,
                    style: termStyle,
                  ),
                  TextSpan(text: l10n.relaySettingsExplainerReachabilityBody),
                ],
              ),
            ),
            const SizedBox(height: HavenSpacing.sm),
            Text(l10n.relaySettingsExplainerFooter, style: bodyStyle),
          ],
        ),
      ),
    );
  }
}
