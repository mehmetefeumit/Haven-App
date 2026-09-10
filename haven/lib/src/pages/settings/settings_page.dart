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
import 'package:haven/src/providers/background_location_provider.dart';
import 'package:haven/src/providers/debug_log_provider.dart';
import 'package:haven/src/widgets/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Page displaying app settings.
///
/// Provides navigation to the sub-settings pages.
class SettingsPage extends StatelessWidget {
  /// Creates the settings page.
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.settingsTitle)),
      body: ListView(
        children: [
          HavenSettingsTile(
            icon: LucideIcons.user,
            title: l10n.settingsIdentityTitle,
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (context) => const IdentityPage(),
                ),
              );
            },
          ),
          HavenSettingsTile(
            icon: LucideIcons.server,
            title: l10n.settingsRelaysTitle,
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (context) => const RelaySettingsPage(),
                ),
              );
            },
          ),
          // The only hub row with a subtitle: it reports the background-sharing
          // SETTING, which has no other standing surface — a confirmed-Always
          // iPhone shows no blue bar, so without this line nothing tells the
          // user at a glance that Haven keeps sharing once they leave it.
          // Deliberately not a health reading: the setting is what the user
          // chose, and the map's own banners own the fault states.
          Consumer(
            builder: (context, ref, _) => HavenSettingsTile(
              icon: LucideIcons.mapPin,
              title: l10n.settingsLocationTitle,
              subtitle: ref.watch(backgroundSharingProvider)
                  ? l10n.settingsLocationSubtitleOn
                  : l10n.settingsLocationSubtitleOff,
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (context) => const LocationSettingsPage(),
                  ),
                );
              },
            ),
          ),
          HavenSettingsTile(
            icon: LucideIcons.layers,
            title: l10n.settingsMapStyleTitle,
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (context) => const MapStyleSettingsPage(),
                ),
              );
            },
          ),
          HavenSettingsTile(
            icon: LucideIcons.palette,
            title: l10n.appearanceTitle,
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (context) => const AppearanceSettingsPage(),
                ),
              );
            },
          ),
          HavenSettingsTile(
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
