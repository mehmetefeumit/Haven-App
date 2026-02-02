/// Settings page for Haven.
///
/// Main settings menu providing access to identity, privacy, and app settings.
library;

import 'package:flutter/material.dart';
import 'package:haven/src/pages/identity_page.dart';
import 'package:haven/src/pages/settings/privacy_settings_page.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:haven/src/widgets/widgets.dart';

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
                icon: Icons.person,
                title: 'Nostr Identity',
                subtitle: 'Manage your cryptographic identity',
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
            title: 'Privacy',
            children: [
              _SettingsTile(
                icon: Icons.location_on,
                title: 'Location Privacy',
                subtitle: 'Default precision and sharing settings',
                trailing: const PrivacyChip(level: PrivacyLevel.exact),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (context) => const PrivacySettingsPage(),
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
                icon: Icons.dark_mode,
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
                icon: Icons.info,
                title: 'About Haven',
                subtitle: 'Version 0.1.0',
                onTap: () {
                  showAboutDialog(
                    context: context,
                    applicationName: 'Haven',
                    applicationVersion: '0.1.0',
                    applicationLegalese: '© 2024 Haven Contributors',
                    children: const [
                      SizedBox(height: HavenSpacing.base),
                      Text(
                        'Secure, privacy-first location sharing using '
                        'the Marmot Protocol (MLS + Nostr) for end-to-end '
                        'encrypted group messaging.',
                      ),
                    ],
                  );
                },
              ),
              const _SettingsTile(
                icon: Icons.lock,
                title: 'Security',
                subtitle: 'E2E encrypted with Marmot Protocol',
                trailing: EncryptionBadge(showLabel: true),
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
          trailing ?? (onTap != null ? const Icon(Icons.chevron_right) : null),
      onTap: onTap,
    );
  }
}
