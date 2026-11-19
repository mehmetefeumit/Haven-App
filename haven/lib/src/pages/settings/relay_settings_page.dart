/// Editable relay settings page for Haven.
///
/// Three relay categories the user edits — Inbox (kind 10050), KeyPackage
/// (kinds 30443 and 10002) and Profile (kind 0, a list kept on the phone and
/// never published) — then the read-only lookup relays Haven copies the two
/// relay lists to, and a short framing caption. Each section title carries a
/// circled question mark that opens an explanation panel over the page.
///
/// Every Inbox, KeyPackage and lookup row shows, per item expected on that
/// relay, a symbol that follows the maintenance passes as they check and
/// publish (`relayStatusProvider`). The page offers no refresh and no
/// republish: opening it runs a pass only when the last one is stale
/// ([ownRelayBoardIsStale]), and one screen-reader announcement follows each
/// pass when it settles. An Inbox row whose relay refused the pass's read of
/// this account's invitations says so, in words and with an icon; when every
/// inbox relay refused it, a banner offers the defaults back.
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
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/constants/relays.dart';
import 'package:haven/src/models/own_relay_board.dart';
import 'package:haven/src/pages/settings/add_relay_sheet.dart';
import 'package:haven/src/pages/settings/relay_info_sheet.dart';
import 'package:haven/src/pages/settings/relay_status_cell.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/key_package_provider.dart';
import 'package:haven/src/providers/relay_preferences_provider.dart';
import 'package:haven/src/providers/relay_status_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/relay_preferences_service.dart';
import 'package:haven/src/services/relay_service.dart' show InboxRead;
import 'package:haven/src/test_keys.dart';
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
  /// The relay the user just added, normalized, until its check settles.
  String? _added;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Opening the page is the user asking for the lists, so a read that
      // failed earlier is asked again rather than shown as failed.
      retryFailedRelayLoads(ref);
      if (ownRelayBoardIsStale(
        ref.read(maintenanceServiceProvider).ownRelayBoard(),
      )) {
        ref
          ..invalidate(keyPackagePublisherProvider)
          ..read(keyPackagePublisherProvider);
      }
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

  void _onRelayAdded(String url) =>
      _added = normalizeRelayUrlForComparison(url);

  /// One announcement when a pass settles, and one for a relay the user just
  /// added once its own check settles — never one per symbol.
  void _announce(RelayStatusState? previous, RelayStatusState next) {
    if (!mounted) return;
    final l10n = AppLocalizations.of(context);
    final messages = <String>[];
    final added = _added;
    // The add cleared the new row's cells in the same call as the write, so a
    // settled row now is a pass's verdict on it, however fast that pass was.
    final row = added == null ? null : _rowFor(next, added);
    if (row != null && !next.running && !row.expected.any(_unsettled)) {
      final host = row.relayUrl.replaceFirst('wss://', '');
      messages.add(
        row.expected.every((k) => k == KindPresence.current)
            ? l10n.relaySettingsAddedRelayUpToDate(host)
            : l10n.relaySettingsAddedRelayNotUpToDate(host),
      );
      _added = null;
    }
    // A pass has stretches where no symbol moves — a KeyPackage being made,
    // the next kind not begun — so only the board's own flag says it ended.
    final wasActive = previous != null && (previous.busy || previous.running);
    if (wasActive && !next.busy && !next.running) {
      final notCurrent = next.relays
          .where((r) => r.expected.any((k) => k != KindPresence.current))
          .length;
      messages.add(l10n.relaySettingsCheckSettled(notCurrent));
      // A pass that ended without judging the added relay (it failed first,
      // or the relay is gone) leaves its outcome to this count.
      _added = null;
    }
    final view = View.of(context);
    final direction = Directionality.of(context);
    for (final message in messages) {
      unawaited(SemanticsService.sendAnnouncement(view, message, direction));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final identity = ref.watch(identityProvider);
    ref.listen(relayStatusProvider, _announce);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.relaySettingsTitle)),
      body: identity.when(
        data: (id) => id == null
            ? HavenScrollFill(
                child: HavenEmptyState(
                  icon: LucideIcons.userX,
                  title: l10n.relaySettingsNoIdentityTitle,
                  message: l10n.relaySettingsNoIdentityMessage,
                ),
              )
            : _buildBody(),
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

  Widget _buildBody() {
    return ListView(
      padding: const EdgeInsets.all(HavenSpacing.base),
      children: [
        _RelaySection(
          category: RelayCategory.inbox,
          section: RelaySettingsSection.inbox,
          onAdded: _onRelayAdded,
        ),
        const SizedBox(height: HavenSpacing.lg),
        _RelaySection(
          category: RelayCategory.keyPackage,
          section: RelaySettingsSection.keyPackage,
          onAdded: _onRelayAdded,
        ),
        const SizedBox(height: HavenSpacing.lg),
        _RelaySection(
          category: RelayCategory.profile,
          section: RelaySettingsSection.profile,
          onAdded: _onRelayAdded,
        ),
        // Below every control the user taps, so a note appearing or going
        // never moves a row under a finger.
        const _HoldNotes(),
        const SizedBox(height: HavenSpacing.lg),
        // After the lists the user edits: Haven's own, read-only.
        const _LookupSection(),
        const SizedBox(height: HavenSpacing.lg),
        const _BackendCaption(),
        const SizedBox(height: HavenSpacing.base),
      ],
    );
  }
}

bool _unsettled(KindPresence k) =>
    k == KindPresence.checking ||
    k == KindPresence.publishing ||
    k == KindPresence.notChecked;

/// Curated profile-pool URLs (normalized), computed once rather than on
/// every rebuild of [_RelaySection]. Haven re-admits these regardless of the
/// stored list (see the library doc), so a row for one never offers removal.
/// Excludes the debug-only `set_profile_relays_for_test` override, which is
/// unreachable in release and unused by any lane that renders this page.
final Set<String> _unremovableProfileRelays = {
  for (final url in fallbackDefaultProfileRelays)
    normalizeRelayUrlForComparison(url),
};

/// A section's title, a heading to screen readers, with the circled question
/// mark that opens its explanation right after it in reading order.
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.section});

  final RelaySettingsSection section;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final title = relaySectionTitle(l10n, section);
    return Row(
      children: [
        Flexible(
          child: Semantics(
            header: true,
            child: Text(
              title,
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ),
        ),
        IconButton(
          key: WidgetKeys.relaySettingsInfoButton(section.name),
          tooltip: l10n.relaySettingsInfoTooltip(title),
          icon: Icon(
            LucideIcons.circleQuestionMark,
            size: 20,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          onPressed: () => showRelayInfoSheet(context, section),
        ),
      ],
    );
  }
}

class _RelaySection extends ConsumerWidget {
  const _RelaySection({
    required this.category,
    required this.section,
    required this.onAdded,
  });

  final RelayCategory category;
  final RelaySettingsSection section;

  /// Told the canonical URL of a relay the user added to a list whose rows
  /// carry symbols.
  final ValueChanged<String> onAdded;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final relays = ref.watch(_listProviderFor(category));
    final status = ref.watch(relayStatusProvider);
    // Contamination warning is advisory and Profile-only (task requirement):
    // only watch the set when this section IS the Profile category, so the
    // Inbox/KeyPackage sections neither pay for nor rebuild on it.
    final contaminated = category == RelayCategory.profile
        ? ref.watch(profileRelayContaminationProvider)
        : const <String>{};
    final unremovable = category == RelayCategory.profile
        ? _unremovableProfileRelays
        : const <String>{};
    // Only inbox rows carry a read verdict: what the last pass's read saw.
    bool refused(String url) =>
        category == RelayCategory.inbox &&
        _rowFor(status, url)?.inboxRead == InboxRead.refused;
    final allRefused = switch (relays.valueOrNull) {
      final urls? when urls.isNotEmpty => urls.every(refused),
      _ => false,
    };

    return Column(
      key: WidgetKeys.relaySettingsSection(section.name),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(section: section),
        if (category == RelayCategory.profile)
          const _ProfilePoolUnderflowBanner(),
        if (allRefused)
          _InboxAllRefusedBanner(
            onRestore: () => _onRestoreDefaultsTapped(context, ref),
          ),
        relays.when(
          data: (urls) {
            if (urls.isEmpty) {
              return _EmptyCategoryState(category: category);
            }
            return Card(
              child: Column(
                children: [
                  for (var i = 0; i < urls.length; i++) ...[
                    _RelayRow(
                      url: urls[i],
                      cells: _cellsFor(category, _rowFor(status, urls[i])),
                      onRemove:
                          unremovable.contains(
                            normalizeRelayUrlForComparison(urls[i]),
                          )
                          ? null
                          : () => _removeRelay(context, ref, urls[i]),
                      isContaminated: contaminated.contains(
                        normalizeRelayUrlForComparison(urls[i]),
                      ),
                      isInboxRefused: refused(urls[i]),
                    ),
                    if (i < urls.length - 1)
                      const Divider(height: 1, indent: HavenSpacing.base),
                  ],
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
              key: WidgetKeys.relaySettingsAddRelay(section.name),
              icon: const Icon(LucideIcons.plus, size: 16),
              label: Text(l10n.relaySettingsAddRelay),
              onPressed: () => _onAddRelayTapped(context, ref),
            ),
            TextButton.icon(
              key: WidgetKeys.relaySettingsRestoreDefaults(section.name),
              icon: const Icon(LucideIcons.rotateCcw, size: 16),
              label: Text(l10n.relaySettingsRestoreDefaults),
              onPressed: () => _onRestoreDefaultsTapped(context, ref),
            ),
          ],
        ),
      ],
    );
  }

  /// The add is a local write; the pass it starts is not waited for, and the
  /// new row's symbols follow it.
  Future<void> _onAddRelayTapped(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final l10n = AppLocalizations.of(context);
    final canonical = await showAddRelaySheet(context, category: category);
    if (canonical == null) return;
    try {
      await _notifierFor(ref, category).addRelay(canonical);
      // A Profile row carries no symbol, so it has no check to announce.
      if (category != RelayCategory.profile) onAdded(canonical);
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

RelayPresence? _rowFor(RelayStatusState state, String url) {
  final key = normalizeRelayUrlForComparison(url);
  for (final r in state.relays) {
    if (normalizeRelayUrlForComparison(r.relayUrl) == key) return r;
  }
  return null;
}

/// The items a section's row reports: what that list is published for. A
/// relay on two lists shows each list's items in that list's section.
List<(RelayKind, KindPresence)> _cellsFor(
  RelayCategory category,
  RelayPresence? row,
) => switch (category) {
  RelayCategory.inbox => [
    (RelayKind.inboxRelayList, row?.inboxRelayList ?? KindPresence.notChecked),
  ],
  RelayCategory.keyPackage => [
    (RelayKind.keyPackage, row?.keyPackage ?? KindPresence.notChecked),
    (RelayKind.relayList, row?.relayList ?? KindPresence.notChecked),
  ],
  // Profile relays carry only the public profile, which no screen reports
  // per relay.
  RelayCategory.profile => const [],
};

/// A relay's address at the start, its items' symbols stacked at the end.
///
/// The address and symbols read as one sentence; the remove button stays its
/// own control. Symbols sit in fixed boxes, so a change of state never moves
/// the remove button under a finger.
class _RelayRow extends StatelessWidget {
  const _RelayRow({
    required this.url,
    required this.cells,
    required this.onRemove,
    this.isContaminated = false,
    this.isInboxRefused = false,
  });

  final String url;

  /// The items this row reports, each with what the relay holds of it.
  final List<(RelayKind, KindPresence)> cells;

  /// Removes this relay, or `null` to suppress the control — the curated
  /// profile-pool rows, which Haven dials regardless of whether a remove
  /// button exists for them, and the lookup rows.
  final VoidCallback? onRemove;

  /// Advisory-only: `true` when this relay also carries the account's
  /// location-plane traffic — circle, inbox, KeyPackage or discovery-plane
  /// lookups (see `profileRelayContaminationProvider`).
  /// Only ever set for Profile-section rows. Never gates [onRemove] or the
  /// Add-relay flow — it is purely informational.
  final bool isContaminated;

  /// `true` when this inbox relay refused the last pass's read of this
  /// account's gift wraps. Only ever set for Inbox-section rows.
  final bool isInboxRefused;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final displayUrl = url.replaceFirst('wss://', '');
    final remove = onRemove;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 56),
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(
          HavenSpacing.base,
          HavenSpacing.xs,
          HavenSpacing.xs,
          HavenSpacing.xs,
        ),
        child: Row(
          children: [
            Expanded(
              child: MergeSemantics(
                child: LayoutBuilder(
                  builder: (context, constraints) => Row(
                    children: [
                      // Never cut: the part that tells two relays apart is
                      // often at the end. Left to right in every locale, so
                      // its punctuation is not reordered.
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              displayUrl,
                              textDirection: TextDirection.ltr,
                              style: theme.textTheme.bodyMedium,
                            ),
                            // In words, so it is never carried by colour alone.
                            if (isInboxRefused)
                              Text(
                                l10n.relaySettingsInboxRefused,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                          ],
                        ),
                      ),
                      if (cells.isNotEmpty) ...[
                        const SizedBox(width: HavenSpacing.md),
                        ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: constraints.maxWidth / 2,
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              for (final (kind, status) in cells)
                                RelayKindStatusCell(
                                  relayUrl: url,
                                  kind: kind,
                                  status: status,
                                ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            if (isContaminated) _ContaminationWarningIcon(url: displayUrl),
            if (isInboxRefused) _InboxRefusedWarningIcon(url: displayUrl),
            if (remove != null)
              IconButton(
                key: WidgetKeys.relaySettingsRemoveRelay,
                tooltip: l10n.relaySettingsRemoveTooltip(displayUrl),
                icon: const Icon(LucideIcons.trash2),
                onPressed: remove,
              ),
          ],
        ),
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

/// Warning icon next to an inbox relay that refused the last pass's read of
/// this account's gift wraps. Same shape as [_ContaminationWarningIcon]: a
/// short tooltip, and a screen-reader label that names the relay.
class _InboxRefusedWarningIcon extends StatelessWidget {
  const _InboxRefusedWarningIcon({required this.url});

  /// Display URL (`wss://` stripped), named in the accessibility label.
  final String url;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Tooltip(
      message: l10n.relaySettingsInboxRefusedTooltip,
      child: Semantics(
        label: l10n.relaySettingsInboxRefusedSemantics(url),
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

/// Banner at the top of the Inbox section when every inbox relay refused the
/// last pass's read of this account's gift wraps: no invitation reaches the
/// user until one does. Haven's defaults hold no such relay.
class _InboxAllRefusedBanner extends StatelessWidget {
  const _InboxAllRefusedBanner({required this.onRestore});

  final VoidCallback onRestore;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: HavenSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          HavenInfoNote(
            icon: LucideIcons.triangleAlert,
            tone: HavenInfoNoteTone.warning,
            title: l10n.relaySettingsInboxAllRefusedTitle,
            paragraphs: [l10n.relaySettingsInboxAllRefusedMessage],
          ),
          const SizedBox(height: HavenSpacing.sm),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              icon: const Icon(LucideIcons.rotateCcw, size: 16),
              label: Text(l10n.relaySettingsRestoreDefaults),
              onPressed: onRestore,
            ),
          ),
        ],
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

/// Why Haven publishes nothing of a kind now, from the board's first read, so
/// the note is there on the page's first frame.
class _HoldNotes extends ConsumerWidget {
  const _HoldNotes();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final holds = ref.watch(relayStatusProvider.select((s) => s.holds)).values;
    if (holds.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: HavenSpacing.lg),
      child: Column(
        key: WidgetKeys.relaySettingsHeldNote,
        children: [
          for (final hold in OwnPublishHold.values)
            if (holds.contains(hold))
              Padding(
                padding: const EdgeInsets.only(bottom: HavenSpacing.sm),
                child: HavenInfoNote(
                  icon: LucideIcons.circlePause,
                  paragraphs: [
                    switch (hold) {
                      OwnPublishHold.awaitingResetAcknowledgement =>
                        l10n.relaySettingsPublishingHeld,
                      OwnPublishHold.noRelaysConfigured =>
                        l10n.relaySettingsHeldNoRelays,
                      OwnPublishHold.publishingSuppressed =>
                        l10n.relaySettingsHeldNotYetPublished,
                    },
                  ],
                ),
              ),
        ],
      ),
    );
  }
}

/// The lookup relays Haven copies the relay lists to, with what each holds
/// of them. Read-only: the list is Haven's, not the user's.
class _LookupSection extends ConsumerWidget {
  const _LookupSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows = [
      for (final r in ref.watch(relayStatusProvider).relays)
        if (r.lookup) r,
    ];
    return Column(
      key: WidgetKeys.relaySettingsSection(RelaySettingsSection.lookup.name),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader(section: RelaySettingsSection.lookup),
        Card(
          child: Column(
            children: [
              for (var i = 0; i < rows.length; i++) ...[
                _RelayRow(
                  url: rows[i].relayUrl,
                  cells: [
                    if (rows[i].relayList case final p?)
                      (RelayKind.relayList, p),
                    if (rows[i].inboxRelayList case final p?)
                      (RelayKind.inboxRelayList, p),
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

/// Short caption at the foot of the page.
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
