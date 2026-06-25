/// Settings page for Haven.
///
/// Main settings menu providing access to identity and app settings.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/pages/identity_page.dart';
import 'package:haven/src/pages/settings/about_page.dart';
import 'package:haven/src/pages/settings/appearance_settings_page.dart';
import 'package:haven/src/pages/settings/location_settings_page.dart';
import 'package:haven/src/pages/settings/map_style_settings_page.dart';
import 'package:haven/src/pages/settings/relay_settings_page.dart';
import 'package:haven/src/providers/debug_log_provider.dart';
import 'package:haven/src/providers/map_style_provider.dart';
import 'package:haven/src/widgets/common/disclosure_chevron.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Page displaying app settings.
///
/// Provides navigation to sub-settings pages for identity, privacy,
/// notifications, and about information.
class SettingsPage extends ConsumerWidget {
  /// Creates the settings page.
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final mapStyle = ref.watch(mapStyleControllerProvider);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.settingsTitle)),
      body: ListView(
        children: [
          _SettingsTile(
            icon: LucideIcons.user,
            title: l10n.settingsIdentityTitle,
            subtitle: l10n.settingsIdentitySubtitle,
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (context) => const IdentityPage(),
                ),
              );
            },
          ),
          _SettingsTile(
            icon: LucideIcons.server,
            title: l10n.settingsRelaysTitle,
            subtitle: l10n.settingsRelaysSubtitle,
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (context) => const RelaySettingsPage(),
                ),
              );
            },
          ),
          _SettingsTile(
            icon: LucideIcons.mapPin,
            title: l10n.settingsLocationTitle,
            subtitle: l10n.settingsLocationSubtitle,
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (context) => const LocationSettingsPage(),
                ),
              );
            },
          ),
          _SettingsTile(
            icon: LucideIcons.layers,
            title: l10n.settingsMapStyleTitle,
            subtitle: mapStyleLabel(l10n, mapStyle),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (context) => const MapStyleSettingsPage(),
                ),
              );
            },
          ),
          _SettingsTile(
            icon: LucideIcons.palette,
            title: l10n.appearanceTitle,
            subtitle: l10n.settingsAppearanceSubtitle,
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (context) => const AppearanceSettingsPage(),
                ),
              );
            },
          ),
          _SettingsTile(
            icon: LucideIcons.info,
            title: l10n.settingsAboutTitle,
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (context) => const AboutPage(),
                ),
              );
            },
          ),
          if (kDebugMode)
            Consumer(
              builder: (context, ref, _) {
                final isVisible = ref.watch(debugLogProvider).isVisible;
                return SwitchListTile(
                  secondary: const Icon(LucideIcons.bug),
                  title: Text(l10n.settingsDebugOverlayTitle),
                  subtitle: Text(l10n.settingsDebugOverlaySubtitle),
                  value: isVisible,
                  onChanged: (_) =>
                      ref.read(debugLogProvider.notifier).toggleOverlay(),
                );
              },
            ),
        ],
      ),
    );
  }
}

class _SettingsTile extends StatelessWidget {
  const _SettingsTile({
    required this.icon,
    required this.title,
    this.subtitle,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return ListTile(
      leading: Icon(icon, color: colorScheme.onSurfaceVariant),
      title: Text(title),
      subtitle: subtitle != null ? Text(subtitle!) : null,
      trailing: onTap != null ? const DisclosureChevron() : null,
      onTap: onTap,
    );
  }
}
