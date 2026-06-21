/// Editable relay settings page for Haven.
///
/// Shows two independent relay categories (Inbox kind 10050 + KeyPackage
/// kind 10051) with add/remove/restore controls.
/// A footer note explains, in plain language, how Haven's relay-based backend
/// works and what the Inbox and KeyPackage relay lists are for.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
      children: const [
        _RelaySection(
          category: RelayCategory.inbox,
          title: 'My Inbox Relays',
          subtitle: 'kind 10050, where invitations reach you',
        ),
        SizedBox(height: HavenSpacing.lg),
        _RelaySection(
          category: RelayCategory.keyPackage,
          title: 'My KeyPackage Relays',
          subtitle: 'kind 10051, where invitees discover your encryption keys',
        ),
        SizedBox(height: HavenSpacing.lg),
        _BackendExplainerNote(),
        SizedBox(height: HavenSpacing.base),
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
      label: 'How Haven relays work',
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
                'How this works',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: scheme.onSurface,
                ),
              ),
            ),
            const SizedBox(height: HavenSpacing.sm),
            Text(
              'Haven has no central server. It runs on two open technologies. '
              'Nostr is a network of independent servers called relays that '
              'anyone can run; they receive your messages, hold them briefly, '
              'and hand them on when your contacts ask. No single relay is '
              'essential, so if one goes offline the others keep working, and '
              'anything a relay could be forced to hand over is only ever '
              'encrypted data.',
              style: bodyStyle,
            ),
            const SizedBox(height: HavenSpacing.sm),
            Text(
              'The Marmot protocol encrypts your messages on your device '
              'before they leave it, using the MLS (Messaging Layer Security) '
              'standard. Each circle is its own encrypted group with its own '
              'keys, so separate circles cannot be linked together. Those '
              'keys also keep advancing over time, a property called '
              'forward secrecy, so even a key exposed later cannot unlock '
              'your earlier messages.',
              style: bodyStyle,
            ),
            const SizedBox(height: HavenSpacing.sm),
            Text(
              'Because of this, a relay never sees your location, your '
              'messages, who is in your circles, or your identity on those '
              'messages. Each message is published from a fresh, single-use '
              'sending address, so nothing in the message ties it to your '
              'account. A relay still sees some metadata, though: a random '
              'per-circle tag, the timing and size of your traffic, and the '
              'network address you connect from.',
              style: bodyStyle,
            ),
            const SizedBox(height: HavenSpacing.sm),
            Text.rich(
              TextSpan(
                style: bodyStyle,
                children: [
                  TextSpan(text: 'Inbox relays', style: termStyle),
                  const TextSpan(
                    text:
                        ' are your mailbox: where invitations to join a '
                        'circle, themselves encrypted, are delivered for you '
                        'to collect. For someone to invite you, they must be '
                        'able to reach one of these relays.',
                  ),
                ],
              ),
            ),
            const SizedBox(height: HavenSpacing.sm),
            Text.rich(
              TextSpan(
                style: bodyStyle,
                children: [
                  TextSpan(text: 'KeyPackage relays', style: termStyle),
                  const TextSpan(
                    text:
                        ' are where you publish a small bundle of your '
                        'public keys, which is safe to share. Someone who '
                        'knows your account fetches it from these relays to '
                        'add you to a circle.',
                  ),
                ],
              ),
            ),
            const SizedBox(height: HavenSpacing.sm),
            Text.rich(
              TextSpan(
                style: bodyStyle,
                children: [
                  TextSpan(text: 'Using your own relay.', style: termStyle),
                  const TextSpan(
                    text:
                        ' Each circle also carries its own relay list, '
                        'shared with every member when they join; that '
                        'list, not your inbox, is where the circle’s '
                        'ongoing encrypted updates travel. So if you would '
                        'rather avoid public relays, you can run your own '
                        'and point a circle at it: once everyone has '
                        'joined, that circle’s traffic can flow through it '
                        'alone.',
                  ),
                ],
              ),
            ),
            const SizedBox(height: HavenSpacing.sm),
            Text.rich(
              TextSpan(
                style: bodyStyle,
                children: [
                  TextSpan(
                    text: 'The catch is reachability.',
                    style: termStyle,
                  ),
                  const TextSpan(
                    text:
                        ' Every member must be able to connect to that '
                        'relay, and when you first invite someone, the two '
                        'of you need a relay you can both reach (for example, '
                        'the same private relay listed as everyone’s inbox '
                        'and KeyPackage relay). A private relay still sees '
                        'the same encrypted traffic and timing as any other; '
                        'you simply control who runs it.',
                  ),
                ],
              ),
            ),
            const SizedBox(height: HavenSpacing.sm),
            Text(
              'You can add or remove relays in either list at any time. '
              'More relays make you easier to reach; fewer give you more '
              'control over where your encrypted traffic goes.',
              style: bodyStyle,
            ),
          ],
        ),
      ),
    );
  }
}
