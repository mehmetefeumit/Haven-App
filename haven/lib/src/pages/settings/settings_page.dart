/// Settings page for Haven.
///
/// Main settings menu providing access to identity and app settings.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/pages/identity_page.dart';
import 'package:haven/src/pages/settings/about_page.dart';
import 'package:haven/src/pages/settings/location_settings_page.dart';
import 'package:haven/src/pages/settings/map_style_settings_page.dart';
import 'package:haven/src/pages/settings/profile_picture_page.dart';
import 'package:haven/src/pages/settings/relay_settings_page.dart';
import 'package:haven/src/pages/settings/theme_settings_page.dart';
import 'package:haven/src/providers/debug_log_provider.dart';
import 'package:haven/src/providers/map_style_provider.dart';
import 'package:haven/src/providers/theme_mode_provider.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Returns the icon that best represents [mode] in the settings list.
IconData _iconForMode(ThemeMode mode) {
  switch (mode) {
    case ThemeMode.system:
      return LucideIcons.smartphone;
    case ThemeMode.light:
      return LucideIcons.sun;
    case ThemeMode.dark:
      return LucideIcons.moon;
  }
}

/// Page displaying app settings.
///
/// Provides navigation to sub-settings pages for identity, privacy,
/// notifications, and about information.
class SettingsPage extends ConsumerWidget {
  /// Creates the settings page.
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeControllerProvider);
    final mapStyle = ref.watch(mapStyleControllerProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          _SettingsTile(
            icon: LucideIcons.user,
            title: 'Identity',
            subtitle: 'Manage your account and keys',
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
            icon: LucideIcons.circleUser,
            title: 'Your Profile',
            subtitle: 'Profile picture visible to your circles',
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (context) => const ProfilePicturePage(),
                ),
              );
            },
          ),
          _SettingsTile(
            icon: LucideIcons.server,
            title: 'Relays',
            subtitle: 'Where invitations reach you',
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
            title: 'Location',
            subtitle: 'Background sharing and permissions',
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
            title: 'Map style',
            subtitle: mapStyleLabel(mapStyle),
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
            icon: _iconForMode(themeMode),
            title: 'Theme',
            subtitle: themeModeLabel(themeMode),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (context) => const ThemeSettingsPage(),
                ),
              );
            },
          ),
          _SettingsTile(
            icon: LucideIcons.info,
            title: 'About',
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
                  title: const Text('Debug Log Overlay'),
                  subtitle: const Text('Show log output on screen'),
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
      trailing: onTap != null ? const Icon(LucideIcons.chevronRight) : null,
      onTap: onTap,
    );
  }
}
