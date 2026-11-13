/// Editable relay settings page for Haven.
///
/// Shows three independent relay categories — Inbox (kind 10050), KeyPackage
/// (kind 10002), and Profile (kind-0, local-only policy — never published)
/// — with add/remove/restore controls, then the read-only lookup relays
/// inviters search, plus a short framing caption. Each Inbox, KeyPackage and
/// lookup row says, per kind expected there, whether the relay serves it
/// (`relayStatusProvider`); "Republish" appears when one misses a kind or
/// serves an old one.
///
/// The Profile section's remove control is deliberately absent on the curated
/// pool entries — `usable_profile_relays()` unions
/// `profile_relay_pool_default()` back in on every resolution (pinned by
/// `haven-core/tests/profile_curated_pool_removal.rs`), so deleting one would
/// shorten the list on screen without shortening what Haven actually dials.
///
/// The Profile section also shows an advisory, non-blocking warning on any row
/// whose relay already carries this account's location-plane traffic — circle,
/// inbox, KeyPackage or discovery-plane lookups (see
/// `profileRelayContaminationProvider`), and — distinct from that per-row
/// warning — a banner when the pool has underflowed entirely: too few usable
/// Profile relays remain to look up anyone's profile, so member names/photos
/// silently stop updating with no other visible signal (see
/// `_ProfilePoolUnderflowBanner`, `profilePoolStatusProvider`).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/constants/relays.dart';
import 'package:haven/src/models/relay_ring_slot.dart';
import 'package:haven/src/pages/settings/add_relay_sheet.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/relay_preferences_provider.dart';
import 'package:haven/src/providers/relay_status_provider.dart';
import 'package:haven/src/services/relay_preferences_service.dart';
import 'package:haven/src/test_keys.dart';
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
      // Opening the page is the user asking for the lists, so a read that
      // failed earlier is asked again rather than shown as failed.
      retryFailedRelayLoads(ref);
      ref.read(relayStatusProvider.notifier).checkAllRelays();
      unawaited(_topUpProfileRelays());
    });
  }

  /// Re-adds any curated profile relay missing from the stored Profile list.
  ///
  /// A build shipped before this page dropped the remove control let a curated
  /// entry's deletion "succeed" cosmetically — `usable_profile_relays()`
  /// re-admits it regardless — so an upgraded install can hold a Profile list
  /// shorter than what Haven actually dials. This page's other two repairs, the
  /// empty-category action and the underflow banner, are both conditional and
  /// never fire for a merely-short list, so the top-up runs unconditionally on
  /// every open. It is idempotent and, since `restoreDefaults` never re-adds a
  /// relay the user removed themselves, cannot undo a legitimate removal.
  ///
  /// Routed through the notifier rather than
  /// `RelayPreferencesService.restoreDefaultProfileRelays` so the visible list
  /// is refreshed by the same call that writes.
  Future<void> _topUpProfileRelays() async {
    try {
      // Wait for the notifier's own `build()` to settle before writing —
      // otherwise a still-in-flight initial read can complete AFTER this
      // call's write and overwrite the topped-up state with its stale one.
      await ref.read(profileRelaysProvider.future);
      await ref.read(profileRelaysProvider.notifier).restoreDefaults();
    } on Object catch (e) {
      // Non-fatal: the page is still usable and the relays are dialled either
      // way. Rule 8 — type only, never the message.
      debugPrint('Profile relay top-up failed: ${e.runtimeType}');
    }
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
        // After the lists the user edits: Haven's own, read-only.
        const _LookupSection(),
        const _RepublishAction(),
        const SizedBox(height: HavenSpacing.lg),
        const _BackendCaption(),
        const SizedBox(height: HavenSpacing.base),
      ],
    );
  }
}

/// Curated profile-pool URLs (normalized), computed once rather than on
/// every rebuild of [_RelaySection]. Haven re-admits these regardless of the
/// stored list (see the library doc), so a row for one never offers removal.
/// Excludes the debug-only `set_profile_relays_for_test` override, which is
/// unreachable in release and unused by any lane that renders this page.
final Set<String> _unremovableProfileRelays = {
  for (final url in fallbackDefaultProfileRelays)
    normalizeRelayUrlForComparison(url),
};

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
    // `.value` rethrows a failed first load, which paints the page as an
    // error box; rows without a status show "Not checked" instead.
    final status = ref.watch(relayStatusProvider).valueOrNull;
    // Contamination warning is advisory and Profile-only (task requirement):
    // only watch the set when this section IS the Profile category, so the
    // Inbox/KeyPackage sections neither pay for nor rebuild on it.
    final contaminated = category == RelayCategory.profile
        ? ref.watch(profileRelayContaminationProvider)
        : const <String>{};
    final unremovable = category == RelayCategory.profile
        ? _unremovableProfileRelays
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
                          kinds: _kindsFor(category, _rowFor(status, urls[i])),
                          onRemove:
                              unremovable.contains(
                                normalizeRelayUrlForComparison(urls[i]),
                              )
                              ? null
                              : () => _removeRelay(context, ref, urls[i]),
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
    final list = ref.read(_listProviderFor(category)).valueOrNull ?? const [];
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

RelayPresence? _rowFor(RelayStatusState? state, String url) {
  if (state == null) return null;
  final key = normalizeRelayUrlForComparison(url);
  for (final r in state.relays) {
    if (normalizeRelayUrlForComparison(r.relayUrl) == key) return r;
  }
  return null;
}

/// A kind a relay row reports on.
enum _Kind { keyPackage, relayList, inboxList }

/// The kinds a section's row reports: what that list is published for. A
/// relay on two lists shows each list's kinds in that list's section.
List<(_Kind, KindPresence)> _kindsFor(
  RelayCategory category,
  RelayPresence? row,
) => switch (category) {
  RelayCategory.inbox => [
    (_Kind.inboxList, row?.inboxRelayList ?? KindPresence.notChecked),
  ],
  RelayCategory.keyPackage => [
    (_Kind.keyPackage, row?.keyPackage ?? KindPresence.notChecked),
    (_Kind.relayList, row?.relayList ?? KindPresence.notChecked),
  ],
  // Profile relays carry only the public profile, which this check does
  // not ask about.
  RelayCategory.profile => const [],
};

class _EditableRelayRow extends StatelessWidget {
  const _EditableRelayRow({
    required this.url,
    required this.kinds,
    required this.onRemove,
    this.isContaminated = false,
  });

  final String url;

  /// The kinds this row reports, each with what the relay serves of it.
  final List<(_Kind, KindPresence)> kinds;

  /// Removes this relay, or `null` to suppress the control — the curated
  /// profile-pool rows, which Haven dials regardless of whether a remove
  /// button exists for them.
  final VoidCallback? onRemove;

  /// Advisory-only: `true` when this relay also carries the account's
  /// location-plane traffic — circle, inbox, KeyPackage or discovery-plane
  /// lookups (see `profileRelayContaminationProvider`).
  /// Only ever set for Profile-section rows. Never gates [onRemove] or the
  /// Add-relay flow — it is purely informational.
  final bool isContaminated;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final displayUrl = url.replaceFirst('wss://', '');
    final remove = onRemove;
    return ListTile(
      leading: kinds.isEmpty
          ? null
          : _PresenceDot(slot: summarizePresence(kinds.map((k) => k.$2))),
      title: _RelayRowText(url: displayUrl, kinds: kinds),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isContaminated) _ContaminationWarningIcon(url: displayUrl),
          if (remove != null)
            IconButton(
              tooltip: l10n.relaySettingsRemoveTooltip(displayUrl),
              icon: const Icon(LucideIcons.trash2),
              onPressed: remove,
            ),
        ],
      ),
    );
  }
}

/// Advisory warning icon shown next to a Profile-relay row whose URL also
/// carries the account's circle or inbox traffic.
///
/// A short visible [Tooltip] plus a fuller screen-reader label that names the
/// relay, so the warning is understandable out of visual context.
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

/// A relay's address and one line per kind it reports ("KeyPackage:
/// Published"), merged so a screen reader reads the row as one sentence.
class _RelayRowText extends StatelessWidget {
  const _RelayRowText({required this.url, required this.kinds});

  final String url;
  final List<(_Kind, KindPresence)> kinds;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final lineStyle = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return MergeSemantics(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(url, style: theme.textTheme.bodyMedium),
          for (final (kind, presence) in kinds)
            Text(
              l10n.relaySettingsKindLine(
                _kindLabel(l10n, kind),
                _presenceLabel(l10n, presence),
              ),
              style: lineStyle,
            ),
        ],
      ),
    );
  }
}

String _kindLabel(AppLocalizations l10n, _Kind kind) => switch (kind) {
  _Kind.keyPackage => l10n.relaySettingsKindKeyPackage,
  _Kind.relayList => l10n.relaySettingsKindRelayList,
  _Kind.inboxList => l10n.relaySettingsKindInboxList,
};

String _presenceLabel(AppLocalizations l10n, KindPresence presence) =>
    switch (presence) {
      KindPresence.notChecked => l10n.relaySettingsStatusNotChecked,
      KindPresence.checking => l10n.relaySettingsStatusChecking,
      KindPresence.current => l10n.relaySettingsPresencePublished,
      KindPresence.outdated => l10n.relaySettingsPresenceOutdated,
      KindPresence.missing => l10n.relaySettingsPresenceMissing,
      KindPresence.noAnswer => l10n.relaySettingsStatusUnreachable,
    };

/// The row's summary, as colour and shape. Decorative: the row's lines say
/// the same in words.
class _PresenceDot extends StatelessWidget {
  const _PresenceDot({required this.slot});

  final RelayRingSlotState slot;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (Color color, IconData icon) = switch (slot) {
      RelayRingSlotState.ok => (
        HavenSecurityColors.encrypted,
        LucideIcons.circleCheck,
      ),
      RelayRingSlotState.checking => (
        scheme.onSurfaceVariant,
        LucideIcons.loaderCircle,
      ),
      RelayRingSlotState.error => (
        HavenSecurityColors.warning,
        LucideIcons.circleAlert,
      ),
      RelayRingSlotState.pending => (scheme.outline, LucideIcons.circle),
    };
    return ExcludeSemantics(child: Icon(icon, color: color, size: 20));
  }
}

/// The lookup relays inviters search, with what each serves of this
/// account's relay lists. Read-only: the list is Haven's, not the user's.
class _LookupSection extends ConsumerWidget {
  const _LookupSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final rows = [
      for (final r
          in ref.watch(relayStatusProvider).valueOrNull?.relays ??
              const <RelayPresence>[])
        if (r.lookup) r,
    ];
    if (rows.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.relaySettingsLookupTitle,
          style: theme.textTheme.titleSmall?.copyWith(
            color: theme.colorScheme.primary,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          l10n.relaySettingsLookupSubtitle,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: HavenSpacing.sm),
        Card(
          child: Column(
            children: [
              for (var i = 0; i < rows.length; i++) ...[
                _EditableRelayRow(
                  url: rows[i].relayUrl,
                  kinds: [
                    if (rows[i].relayList case final p?) (_Kind.relayList, p),
                    if (rows[i].inboxRelayList case final p?)
                      (_Kind.inboxList, p),
                  ],
                  onRemove: null,
                ),
                if (i < rows.length - 1)
                  const Divider(height: 1, indent: HavenSpacing.base),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// "Republish", offered when a relay that answered misses an expected kind
/// or serves an old one: the same ordered publish maintenance runs, then a
/// fresh check, reported in fixed copy.
class _RepublishAction extends ConsumerWidget {
  const _RepublishAction();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final state = ref.watch(relayStatusProvider).valueOrNull;
    if (state == null || !(state.needsRepublish || state.isRepublishing)) {
      return const SizedBox.shrink();
    }
    final busy = state.isRepublishing || state.isRefreshing;
    return Padding(
      padding: const EdgeInsets.only(top: HavenSpacing.sm),
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        child: FilledButton.tonalIcon(
          key: WidgetKeys.relaySettingsRepublish,
          icon: const Icon(LucideIcons.upload, size: 16),
          label: Text(l10n.relaySettingsRepublish),
          onPressed: busy ? null : () => _republish(context, ref),
        ),
      ),
    );
  }

  Future<void> _republish(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final l10n = AppLocalizations.of(context);
    final outcome = await ref.read(relayStatusProvider.notifier).republish();
    messenger.showSnackBar(
      SnackBar(
        content: Text(switch (outcome) {
          RepublishOutcome.allCurrent => l10n.relaySettingsRepublishDone,
          RepublishOutcome.incomplete => l10n.relaySettingsRepublishIncomplete,
          RepublishOutcome.heldForReset => l10n.relaySettingsRepublishHeld,
        }),
      ),
    );
  }
}

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

/// Short caption below the two relay sections.
///
/// This page is a *control* surface, so it keeps only enough framing to make
/// the abstract "Inbox" / "KeyPackage" headers meaningful — no long-form
/// explainer, which is what let two copies of it drift apart before.
class _BackendCaption extends StatelessWidget {
  const _BackendCaption();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Text(
      l10n.relaySettingsBackendCaption,
      style: theme.textTheme.bodySmall?.copyWith(
        color: scheme.onSurfaceVariant,
      ),
    );
  }
}
