/// Editable relay settings page for Haven.
///
/// Shows two independent relay categories (Inbox kind 10050 + KeyPackage
/// kind 10051) with add/remove/restore controls and privacy toggles.
/// Per the marmot-protocol review, the underlying publish flow always
/// unions the user's list with `DEFAULT_RELAYS` for discoverability —
/// the footer disclosure surfaces this so the privacy implication is
/// not hidden.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/constants/relays.dart';
import 'package:haven/src/pages/settings/add_relay_sheet.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/relay_preferences_provider.dart';
import 'package:haven/src/providers/relay_status_provider.dart';
import 'package:haven/src/services/relay_preferences_service.dart';
import 'package:haven/src/theme/theme.dart';
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
  bool _calloutDismissed = false;

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
                    icon: const Icon(LucideIcons.refreshCw),
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
              icon: const Icon(LucideIcons.refreshCw),
              tooltip: 'Check relays',
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
                icon: LucideIcons.userX,
                title: 'No Identity',
                message: 'Create an identity first to manage relays.',
              )
            : _buildBody(),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) => const HavenEmptyState(
          icon: LucideIcons.circleAlert,
          message: 'Failed to load identity.',
        ),
      ),
    );
  }

  Widget _buildBody() {
    return ListView(
      padding: const EdgeInsets.all(HavenSpacing.base),
      children: [
        const _PrivacyCallout(),
        if (!_calloutDismissed) ...[
          const SizedBox(height: HavenSpacing.sm),
          _ExistingCirclesCallout(
            onDismissed: () => setState(() => _calloutDismissed = true),
          ),
        ],
        const SizedBox(height: HavenSpacing.lg),
        const _RelaySection(
          category: RelayCategory.inbox,
          title: 'My Inbox Relays',
          subtitle: 'kind 10050 — where invitations reach you',
        ),
        const SizedBox(height: HavenSpacing.lg),
        const _RelaySection(
          category: RelayCategory.keyPackage,
          title: 'My KeyPackage Relays',
          subtitle: 'kind 10051 — where invitees discover your encryption keys',
        ),
        const SizedBox(height: HavenSpacing.lg),
        const _PrivacySection(),
        const SizedBox(height: HavenSpacing.lg),
        const _UnionDisclosure(),
        const SizedBox(height: HavenSpacing.base),
      ],
    );
  }
}

class _PrivacyCallout extends StatelessWidget {
  const _PrivacyCallout();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(HavenSpacing.base),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(LucideIcons.shield, color: scheme.onPrimaryContainer),
            const SizedBox(width: HavenSpacing.md),
            Expanded(
              child: Text(
                'Relays only see your encrypted invitations and public key '
                '— never your location or messages. Default relays work for '
                'most people. Use a custom relay only if you run your own '
                'or want to control who can observe when you are invited.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: scheme.onPrimaryContainer,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ExistingCirclesCallout extends StatelessWidget {
  const _ExistingCirclesCallout({required this.onDismissed});

  final VoidCallback onDismissed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          HavenSpacing.base,
          HavenSpacing.sm,
          HavenSpacing.sm,
          HavenSpacing.sm,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(LucideIcons.info, color: scheme.onSurfaceVariant, size: 20),
            const SizedBox(width: HavenSpacing.md),
            Expanded(
              child: Text(
                'Existing circles keep the relays they were created with. '
                'Changes here apply only to new circles you create and to '
                'how others reach you with new invitations.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            IconButton(
              tooltip: 'Dismiss this notice',
              icon: Icon(LucideIcons.x, color: scheme.onSurfaceVariant),
              // Session-scoped dismissal in v1; persisting across launches
              // via shared_preferences is a follow-up.
              onPressed: onDismissed,
            ),
          ],
        ),
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
          error: (_, _) => const HavenEmptyState(
            icon: LucideIcons.circleAlert,
            message: 'Failed to load relays.',
          ),
        ),
        const SizedBox(height: HavenSpacing.sm),
        Wrap(
          spacing: HavenSpacing.sm,
          children: [
            OutlinedButton.icon(
              icon: const Icon(LucideIcons.plus, size: 16),
              label: const Text('Add relay'),
              onPressed: () => _onAddRelayTapped(context, ref),
            ),
            TextButton.icon(
              icon: const Icon(LucideIcons.rotateCcw, size: 16),
              label: const Text('Restore defaults'),
              onPressed: () => _onRestoreDefaultsTapped(context, ref),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _onAddRelayTapped(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
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
        const SnackBar(content: Text('Failed to add relay.')),
      );
    }
  }

  Future<void> _removeRelay(
    BuildContext context,
    WidgetRef ref,
    String url,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final notifier = _notifierFor(ref, category);
      await notifier.removeRelay(url);
    } on RelayValidationError catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } on Object {
      messenger.showSnackBar(
        const SnackBar(content: Text('Failed to remove relay.')),
      );
    }
  }

  Future<void> _onRestoreDefaultsTapped(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final scheme = Theme.of(context).colorScheme;
    final messenger = ScaffoldMessenger.of(context);
    final list = ref.read(_listProviderFor(category)).value ?? const [];
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Restore default relays?'),
        content: Text(
          'Your current ${list.length} '
          '${list.length == 1 ? "relay" : "relays"} will be replaced with '
          "Haven's defaults. This cannot be undone.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: scheme.error),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _notifierFor(ref, category).wipeAndReset();
      messenger.showSnackBar(
        const SnackBar(content: Text('Defaults restored.')),
      );
    } on Object {
      messenger.showSnackBar(
        const SnackBar(content: Text('Failed to restore defaults.')),
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
    final theme = Theme.of(context);
    final displayUrl = url.replaceFirst('wss://', '');
    return ListTile(
      leading: _StatusDot(status: status),
      title: Text(displayUrl, style: theme.textTheme.bodyMedium),
      trailing: IconButton(
        tooltip: 'Remove $displayUrl',
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
    final scheme = Theme.of(context).colorScheme;
    final overall = _summarize(status);
    final (Color color, IconData icon, String label) = switch (overall) {
      _OverallStatus.connected => (
        HavenSecurityColors.encrypted,
        LucideIcons.circleCheck,
        'Connected',
      ),
      _OverallStatus.checking => (
        scheme.onSurfaceVariant,
        LucideIcons.loaderCircle,
        'Checking',
      ),
      _OverallStatus.unreachable => (
        HavenSecurityColors.warning,
        LucideIcons.circleAlert,
        "Can't reach",
      ),
      _OverallStatus.notChecked => (
        scheme.outline,
        LucideIcons.circle,
        'Not checked',
      ),
    };
    return Tooltip(
      message: label,
      child: Semantics(
        label: 'Relay status: $label',
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
    return HavenEmptyState(
      icon: LucideIcons.serverCrash,
      title: 'No relays configured',
      message:
          'You need at least one relay so others can reach you. '
          'Tap below to restore Haven defaults.',
      actionLabel: 'Restore defaults',
      onAction: () async {
        // Capture the messenger BEFORE the await so we don't reach into
        // a potentially unmounted context. Surface restore failures via
        // SnackBar — silent failures here strand the user in the empty
        // state with no feedback that retry is needed.
        final messenger = ScaffoldMessenger.of(context);
        final notifier = _notifierFor(ref, category);
        try {
          await notifier.restoreDefaults();
        } on Object {
          messenger.showSnackBar(
            const SnackBar(content: Text('Failed to restore defaults.')),
          );
        }
      },
    );
  }
}

/// Surfaces the outcome of a toggle-off retract via SnackBar so the user
/// learns whether their published relay list was actually withdrawn from
/// relays. The toggle has already been persisted by the time this runs.
void _showRetractSnackBar(
  ScaffoldMessengerState messenger,
  RetractOutcome outcome, {
  required String successMessage,
}) {
  final SnackBar bar;
  switch (outcome) {
    case RetractOutcome.retracted:
      bar = SnackBar(content: Text(successMessage));
    case RetractOutcome.nothingToRetract:
      // The toggle is off and there's nothing on relays to withdraw.
      // Tell the user the setting is saved without overpromising.
      bar = const SnackBar(content: Text('Publishing disabled.'));
    case RetractOutcome.failed:
      // Toggle is OFF locally but the prior signed event is still on
      // relays. Be honest about the limitation — NIP-09 + empty-
      // replacement are best-effort and may not have reached every
      // relay that has the old list.
      bar = const SnackBar(
        content: Text(
          'Setting saved. Could not confirm removal from all relays — they '
          'may still serve your previous list for a while.',
        ),
        duration: Duration(seconds: 6),
      );
  }
  messenger.showSnackBar(bar);
}

class _PrivacySection extends ConsumerStatefulWidget {
  const _PrivacySection();

  @override
  ConsumerState<_PrivacySection> createState() => _PrivacySectionState();
}

class _PrivacySectionState extends ConsumerState<_PrivacySection> {
  /// Per-toggle interlocks. While one of these is `true`, the
  /// corresponding `SwitchListTile` receives `onChanged: null`, which
  /// makes Material visually disable the switch and ignore further taps.
  /// Without this, a rapid double-tap could fire two concurrent
  /// `setEnabled` calls and race the OFF retract against the ON
  /// republisher; on non-compliant relays the empty-replacement could
  /// land after the new list, leaving the user looking re-published
  /// while their wire state shows the empty.
  bool _kpBusy = false;
  bool _inboxBusy = false;

  Future<void> _onKpChanged(bool v) async {
    if (_kpBusy) return;
    setState(() => _kpBusy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final outcome = await ref
          .read(publishKpRelayListProvider.notifier)
          .setEnabled(enabled: v);
      if (!v) {
        _showRetractSnackBar(
          messenger,
          outcome,
          successMessage: 'KeyPackage relay list withdrawn from relays.',
        );
      }
    } on Object {
      messenger.showSnackBar(
        const SnackBar(content: Text('Failed to update setting.')),
      );
    } finally {
      if (mounted) setState(() => _kpBusy = false);
    }
  }

  Future<void> _onInboxChanged(bool v) async {
    if (_inboxBusy) return;
    setState(() => _inboxBusy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final outcome = await ref
          .read(publishInboxRelayListProvider.notifier)
          .setEnabled(enabled: v);
      if (!v) {
        _showRetractSnackBar(
          messenger,
          outcome,
          successMessage: 'Inbox relay list withdrawn from relays.',
        );
      }
    } on Object {
      messenger.showSnackBar(
        const SnackBar(content: Text('Failed to update setting.')),
      );
    } finally {
      if (mounted) setState(() => _inboxBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final kpAsync = ref.watch(publishKpRelayListProvider);
    final inboxAsync = ref.watch(publishInboxRelayListProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Privacy',
          style: theme.textTheme.titleSmall?.copyWith(
            color: theme.colorScheme.primary,
          ),
        ),
        const SizedBox(height: HavenSpacing.sm),
        Card(
          child: Column(
            children: [
              kpAsync.when(
                data: (enabled) => _PublishToggle(
                  title: 'Publish KeyPackage relay list (kind 10051)',
                  subtitle:
                      'Lets others discover where to fetch your invitation '
                      'keys. Off means new contacts must add you via QR code '
                      'or shared pubkey.',
                  enabled: enabled,
                  onChanged: _kpBusy ? null : _onKpChanged,
                ),
                loading: () => const ListTile(
                  title: Text('Publish KeyPackage relay list (kind 10051)'),
                  trailing: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
                error: (_, _) => const ListTile(
                  title: Text('Publish KeyPackage relay list (kind 10051)'),
                  subtitle: Text('Failed to load.'),
                ),
              ),
              const Divider(height: 1, indent: HavenSpacing.base),
              inboxAsync.when(
                data: (enabled) => _PublishToggle(
                  title: 'Publish Inbox relay list (kind 10050)',
                  subtitle:
                      'Lets others know where to deliver invitations to you. '
                      'Off means existing circle members can still reach you, '
                      'but new invites require QR code or shared pubkey.',
                  enabled: enabled,
                  onChanged: _inboxBusy ? null : _onInboxChanged,
                ),
                loading: () => const ListTile(
                  title: Text('Publish Inbox relay list (kind 10050)'),
                  trailing: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
                error: (_, _) => const ListTile(
                  title: Text('Publish Inbox relay list (kind 10050)'),
                  subtitle: Text('Failed to load.'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PublishToggle extends StatelessWidget {
  const _PublishToggle({
    required this.title,
    required this.subtitle,
    required this.enabled,
    required this.onChanged,
  });

  final String title;
  final String subtitle;
  final bool enabled;
  /// `null` while a previous toggle is still in flight — Material's
  /// [`SwitchListTile`] then renders the switch as disabled and ignores
  /// further taps, so a rapid double-tap cannot race two `setEnabled`
  /// calls (and the OFF retract cannot land after the ON republisher).
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      title: Text(title),
      subtitle: Text(subtitle),
      isThreeLine: true,
      value: enabled,
      onChanged: onChanged,
      secondary: Icon(enabled ? LucideIcons.cloudUpload : LucideIcons.cloudOff),
    );
  }
}

class _UnionDisclosure extends StatelessWidget {
  const _UnionDisclosure();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final defaults = defaultRelays
        .map((u) => u.replaceFirst('wss://', ''))
        .join(', ');
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: HavenSpacing.sm),
      child: Text(
        'For discoverability, Haven also publishes your relay lists to '
        'Haven defaults ($defaults) and polls those same defaults for '
        'incoming invitations. This means anyone querying those public '
        'relays for your pubkey can see which relays you use, even if '
        'you have only added private custom relays above. Toggle off '
        'the publish settings above to stop publishing entirely; you '
        'will then only be invitable via QR code or a shared pubkey.',
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
      ),
    );
  }
}
