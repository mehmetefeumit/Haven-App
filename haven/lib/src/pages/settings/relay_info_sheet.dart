/// The explanation panel behind each Relays-page section's circled question
/// mark: what the relays are for, what Haven keeps there, what the user can
/// do, and — for the sections whose rows carry symbols — what each symbol
/// means.
library;

import 'package:flutter/material.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/pages/settings/relay_status_cell.dart';
import 'package:haven/src/providers/relay_status_provider.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/theme/theme.dart';

/// A section of the Relays page.
enum RelaySettingsSection {
  /// The user's inbox list.
  inbox,

  /// The user's `KeyPackage` list.
  keyPackage,

  /// The user's profile list.
  profile,

  /// Haven's lookup relays.
  lookup,
}

/// The section's title, as its header and its panel show it.
String relaySectionTitle(AppLocalizations l10n, RelaySettingsSection s) =>
    switch (s) {
      RelaySettingsSection.inbox => l10n.relaySettingsInboxTitle,
      RelaySettingsSection.keyPackage => l10n.relaySettingsKeyPackageTitle,
      RelaySettingsSection.profile => l10n.relaySettingsProfileTitle,
      RelaySettingsSection.lookup => l10n.relaySettingsLookupTitle,
    };

/// Opens [section]'s explanation over the page, never taller than half the
/// screen: the ratio is applied at every layout, so a rotation or larger text
/// while it is open keeps it there, and a long explanation scrolls inside it.
Future<void> showRelayInfoSheet(
  BuildContext context,
  RelaySettingsSection section,
) => showModalBottomSheet<void>(
  context: context,
  useSafeArea: true,
  showDragHandle: true,
  scrollControlDisabledMaxHeightRatio: 0.5,
  shape: const RoundedRectangleBorder(
    borderRadius: BorderRadius.vertical(
      top: Radius.circular(HavenSpacing.base),
    ),
  ),
  builder: (_) => RelayInfoSheet(section: section),
);

/// The body of [showRelayInfoSheet]. Text only, so nothing in it can be
/// swallowed by a scroll in flight.
class RelayInfoSheet extends StatelessWidget {
  /// Creates the panel for [section].
  const RelayInfoSheet({required this.section, super.key});

  /// The section explained.
  final RelaySettingsSection section;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final (paragraphs, technical) = switch (section) {
      RelaySettingsSection.inbox => (
        [
          l10n.relaySettingsInboxInfoWhat,
          l10n.relaySettingsInboxInfoKeeps,
          l10n.relaySettingsInboxInfoMissing,
          l10n.relaySettingsInboxInfoActions,
        ],
        l10n.relaySettingsInboxInfoTechnical,
      ),
      RelaySettingsSection.keyPackage => (
        [
          l10n.relaySettingsKeyPackageInfoWhat,
          l10n.relaySettingsKeyPackageInfoKeeps,
          l10n.relaySettingsKeyPackageInfoMissing,
          l10n.relaySettingsKeyPackageInfoActions,
        ],
        l10n.relaySettingsKeyPackageInfoTechnical,
      ),
      RelaySettingsSection.profile => (
        [
          l10n.relaySettingsProfileInfoWhat,
          l10n.relaySettingsProfileInfoKeeps,
          l10n.relaySettingsProfileInfoPrivacy,
          l10n.relaySettingsProfileInfoActions,
        ],
        l10n.relaySettingsProfileInfoTechnical,
      ),
      RelaySettingsSection.lookup => (
        [
          l10n.relaySettingsLookupInfoWhat,
          l10n.relaySettingsLookupInfoKeeps,
          l10n.relaySettingsLookupInfoMissing,
          l10n.relaySettingsLookupInfoActions,
        ],
        l10n.relaySettingsLookupInfoTechnical,
      ),
    };
    return SingleChildScrollView(
      key: WidgetKeys.relaySettingsInfoSheet,
      // The safe area leaves the bottom inset to the sheet's content.
      padding: EdgeInsetsDirectional.fromSTEB(
        HavenSpacing.lg,
        0,
        HavenSpacing.lg,
        HavenSpacing.lg + MediaQuery.paddingOf(context).bottom,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: Text(
              relaySectionTitle(l10n, section),
              style: theme.textTheme.titleMedium,
            ),
          ),
          for (final p in paragraphs) ...[
            const SizedBox(height: HavenSpacing.md),
            Text(p, style: theme.textTheme.bodyMedium),
          ],
          const SizedBox(height: HavenSpacing.md),
          Text(
            technical,
            key: WidgetKeys.relaySettingsInfoTechnical,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (section != RelaySettingsSection.profile) ...[
            const SizedBox(height: HavenSpacing.lg),
            const _StatusLegend(),
          ],
        ],
      ),
    );
  }
}

/// One line per symbol the rows draw, beside the very glyph they draw.
class _StatusLegend extends StatelessWidget {
  const _StatusLegend();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final lines = [
      (KindPresence.current, l10n.relaySettingsLegendCurrent),
      (KindPresence.publishing, l10n.relaySettingsLegendPublishing),
      (KindPresence.checking, l10n.relaySettingsLegendChecking),
      (KindPresence.missing, l10n.relaySettingsLegendNotOnRelay),
      (KindPresence.noAnswer, l10n.relaySettingsLegendNoAnswer),
      (KindPresence.held, l10n.relaySettingsLegendHeld),
    ];
    return Column(
      key: WidgetKeys.relaySettingsLegend,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          header: true,
          child: Text(
            l10n.relaySettingsLegendTitle,
            style: theme.textTheme.titleSmall,
          ),
        ),
        for (final (status, text) in lines) ...[
          const SizedBox(height: HavenSpacing.sm),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              RelayStatusGlyph(status: status),
              const SizedBox(width: HavenSpacing.md),
              Expanded(child: Text(text, style: theme.textTheme.bodyMedium)),
            ],
          ),
        ],
      ],
    );
  }
}
