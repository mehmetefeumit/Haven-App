/// One line saying whether others can invite this account, shown above the
/// QR code and on the Identity page.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/pages/settings/relay_settings_page.dart';
import 'package:haven/src/providers/own_reachability_provider.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Icon + text for [OwnReachability], never colour alone, with the one action
/// each state allows: Retry where a relay coming back can change the answer,
/// a link to Relay settings where only the user can.
///
/// Rebuilt only when the state changes, and the text is a live region, so a
/// screen reader hears a change and never a routine tick that changed nothing.
class ReachabilityStatusRow extends ConsumerWidget {
  /// Creates the row.
  const ReachabilityStatusRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final status = ref.watch(ownReachabilityProvider.select((s) => s.status));

    final (IconData icon, Color color, String text) = switch (status) {
      OwnReachability.checking => (
        LucideIcons.loaderCircle,
        theme.colorScheme.onSurfaceVariant,
        l10n.reachabilityChecking,
      ),
      OwnReachability.ready => (
        LucideIcons.circleCheck,
        HavenSecurityColors.encrypted,
        l10n.reachabilityReady,
      ),
      OwnReachability.cantCheck => (
        LucideIcons.wifiOff,
        theme.colorScheme.onSurfaceVariant,
        l10n.reachabilityCantCheck,
      ),
      OwnReachability.notReady => (
        LucideIcons.triangleAlert,
        HavenSecurityColors.warning,
        l10n.reachabilityNotReady,
      ),
      OwnReachability.noRelaysConfigured => (
        LucideIcons.triangleAlert,
        HavenSecurityColors.warning,
        l10n.reachabilityNoRelays,
      ),
      OwnReachability.awaitingReset => (
        LucideIcons.clock,
        theme.colorScheme.onSurfaceVariant,
        l10n.reachabilityAwaitingReset,
      ),
    };

    final Widget? action = switch (status) {
      OwnReachability.notReady || OwnReachability.cantCheck => TextButton(
        onPressed: () => ref.read(ownReachabilityProvider.notifier).republish(),
        style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
        child: Text(l10n.commonRetry),
      ),
      OwnReachability.noRelaysConfigured => TextButton(
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const RelaySettingsPage()),
        ),
        style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
        child: Text(l10n.reachabilityOpenRelaySettings),
      ),
      OwnReachability.checking ||
      OwnReachability.ready ||
      OwnReachability.awaitingReset => null,
    };

    return Row(
      children: [
        ExcludeSemantics(child: Icon(icon, size: 20, color: color)),
        const SizedBox(width: HavenSpacing.sm),
        Expanded(
          child: Semantics(
            liveRegion: true,
            child: Text(text, style: theme.textTheme.bodyMedium),
          ),
        ),
        if (action != null) ...[const SizedBox(width: HavenSpacing.sm), action],
      ],
    );
  }
}
