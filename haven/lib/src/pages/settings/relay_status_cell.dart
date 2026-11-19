/// The per-kind status symbols of the Relays page: one [RelayKindStatusCell]
/// per item a relay row reports, drawn with the same [RelayStatusGlyph] the
/// section panels' legend explains.
library;

import 'package:flutter/material.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/providers/relay_status_provider.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// The side of the fixed box every status symbol is drawn in, so a change of
/// state never moves anything on the row.
const double kRelayStatusGlyphBox = 20;

/// The short name of [kind] shown beside its symbol.
String relayKindLabel(AppLocalizations l10n, RelayKind kind) => switch (kind) {
  RelayKind.keyPackage => l10n.relaySettingsKindKeyPackage,
  RelayKind.relayList => l10n.relaySettingsKindRelayList,
  RelayKind.inboxRelayList => l10n.relaySettingsKindInboxList,
};

/// The exact state, as spoken and as the symbol's tooltip shows it.
String kindPresenceLabel(AppLocalizations l10n, KindPresence status) =>
    switch (status) {
      KindPresence.notChecked => l10n.relaySettingsStatusNotChecked,
      KindPresence.checking => l10n.relaySettingsStatusChecking,
      KindPresence.publishing => l10n.relaySettingsPresencePublishing,
      KindPresence.current => l10n.relaySettingsPresencePublished,
      KindPresence.missing => l10n.relaySettingsPresenceMissing,
      KindPresence.outdated => l10n.relaySettingsPresenceOutdated,
      KindPresence.refused => l10n.relaySettingsPresenceRefused,
      KindPresence.unconfirmed => l10n.relaySettingsPresenceUnconfirmed,
      KindPresence.noAnswer => l10n.relaySettingsPresenceNoAnswer,
      KindPresence.held => l10n.relaySettingsPresenceHeld,
    };

/// One item a relay row reports: its short name and its status symbol.
///
/// Read as one phrase ("KeyPackage: Relay refused it"); a tap shows the exact
/// state for those who cannot tell four red crosses apart.
class RelayKindStatusCell extends StatelessWidget {
  /// Creates a cell.
  const RelayKindStatusCell({
    required this.relayUrl,
    required this.kind,
    required this.status,
    super.key,
  });

  /// The relay this cell is about. Not rendered, not in any key.
  final String relayUrl;

  /// The item.
  final RelayKind kind;

  /// What the relay holds of it, or what Haven is doing there.
  final KindPresence status;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final kindLabel = relayKindLabel(l10n, kind);
    final state = kindPresenceLabel(l10n, status);
    return Semantics(
      label: l10n.relaySettingsKindLine(kindLabel, state),
      excludeSemantics: true,
      child: Tooltip(
        message: state,
        triggerMode: TooltipTriggerMode.tap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 24),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  kindLabel,
                  textAlign: TextAlign.end,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              RelayStatusGlyph(status: status),
            ],
          ),
        ),
      ),
    );
  }
}

/// The symbol for [status]: a shape per meaning, colour only as a second cue.
///
/// Decorative: whoever shows it says the state in words.
class RelayStatusGlyph extends StatelessWidget {
  /// Creates a glyph.
  const RelayStatusGlyph({required this.status, super.key});

  /// The state drawn.
  final KindPresence status;

  @override
  Widget build(BuildContext context) {
    final neutral = Theme.of(context).colorScheme.onSurfaceVariant;
    final Widget glyph = switch (status) {
      KindPresence.notChecked || KindPresence.checking => Icon(
        LucideIcons.circleDashed,
        size: 18,
        color: neutral,
      ),
      KindPresence.publishing => _PublishingGlyph(color: neutral),
      KindPresence.current => const Icon(
        LucideIcons.circleCheck,
        size: 18,
        color: HavenSecurityColors.encrypted,
      ),
      KindPresence.missing ||
      KindPresence.outdated ||
      KindPresence.refused ||
      KindPresence.unconfirmed => const Icon(
        LucideIcons.circleX,
        size: 18,
        color: HavenSecurityColors.danger,
      ),
      KindPresence.noAnswer => const Icon(
        Icons.question_mark,
        size: 18,
        color: HavenSecurityColors.warning,
      ),
      KindPresence.held => Icon(
        LucideIcons.circlePause,
        size: 18,
        color: neutral,
      ),
    };
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: kRelayStatusGlyphBox,
        child: Center(child: glyph),
      ),
    );
  }
}

/// An up arrow in a turning ring: sent, the relay's answer awaited. Still
/// when the platform asks for reduced motion.
class _PublishingGlyph extends StatelessWidget {
  const _PublishingGlyph({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) {
      return Icon(LucideIcons.circleArrowUp, size: 18, color: color);
    }
    return Stack(
      alignment: Alignment.center,
      children: [
        SizedBox.square(
          dimension: 18,
          child: CircularProgressIndicator(strokeWidth: 2, color: color),
        ),
        Icon(LucideIcons.arrowUp, size: 11, color: color),
      ],
    );
  }
}
