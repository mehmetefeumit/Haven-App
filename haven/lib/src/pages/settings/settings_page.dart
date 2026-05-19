/// Settings page for Haven.
///
/// Main settings menu providing access to identity and app settings.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/pages/identity_page.dart';
import 'package:haven/src/pages/settings/about_page.dart';
import 'package:haven/src/pages/settings/relay_settings_page.dart';
import 'package:haven/src/providers/debug_log_provider.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Page displaying app settings.
///
/// Provides navigation to sub-settings pages for identity, privacy,
/// notifications, and about information.
class SettingsPage extends StatelessWidget {
  /// Creates the settings page.
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          _SettingsSection(
            title: 'Account',
            showDivider: false,
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
            ],
          ),
          _SettingsSection(
            title: 'Network',
            children: [
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
            ],
          ),
          _SettingsSection(
            title: 'Appearance',
            children: [
              _SettingsTile(
                icon: LucideIcons.moon,
                title: 'Theme',
                subtitle: 'System default',
                onTap: () {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Theme selection coming soon'),
                    ),
                  );
                },
              ),
            ],
          ),
          _SettingsSection(
            title: 'About',
            children: [
              _SettingsTile(
                icon: LucideIcons.info,
                title: 'About Haven',
                subtitle: 'Version 0.1.0',
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (context) => const AboutPage(),
                    ),
                  );
                },
              ),
            ],
          ),
          if (kDebugMode)
            _SettingsSection(
              title: 'Developer',
              children: [
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
        ],
      ),
    );
  }
}

class _SettingsSection extends StatelessWidget {
  const _SettingsSection({
    required this.title,
    required this.children,
    this.showDivider = true,
  });

  final String title;
  final List<Widget> children;

  /// Whether to show a divider above this section.
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showDivider) const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            HavenSpacing.base,
            HavenSpacing.lg,
            HavenSpacing.base,
            HavenSpacing.sm,
          ),
          child: Text(
            title,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
        ),
        ...children,
      ],
    );
  }
}

class _SettingsTile extends StatelessWidget {
  const _SettingsTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.trailing,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return ListTile(
      leading: Icon(icon, color: colorScheme.onSurfaceVariant),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing:
          trailing ??
          (onTap != null ? const Icon(LucideIcons.chevronRight) : null),
      onTap: onTap,
    );
  }
}
