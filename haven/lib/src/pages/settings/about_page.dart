/// About page for Haven.
///
/// Consolidates privacy, security, and technology information
/// into a single informational page accessible from Settings.
library;

import 'package:flutter/material.dart';
import 'package:haven/src/constants/tiles.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

/// Page displaying Haven's privacy guarantees.
///
/// Hero at top, info cards in the middle, footer pinned at the bottom via
/// [Spacer] when the content fits the viewport. On shorter screens the
/// content scrolls instead of overflowing.
class AboutPage extends StatelessWidget {
  /// Creates the about page.
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: const Text('About')),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                child: IntrinsicHeight(
                  child: Padding(
                    padding: const EdgeInsets.all(HavenSpacing.base),
                    child: Column(
                      children: [
                        _HeroSection(
                          colorScheme: colorScheme,
                          textTheme: textTheme,
                        ),
                        const SizedBox(height: HavenSpacing.xl),
                        _buildInfoRow(
                          context,
                          icon: LucideIcons.lock,
                          title: 'Encrypted',
                          description:
                              'Your location is encrypted on your device '
                              'before it leaves. Only members of the circles '
                              'you have joined can decrypt your location '
                              'information.',
                        ),
                        _buildInfoRow(
                          context,
                          icon: LucideIcons.cloudOff,
                          title: 'Decentralized Backend Servers',
                          description:
                              'Haven is built on the decentralized Nostr '
                              'protocol; there is no single point of failure '
                              'which can be censored, hacked, or shut down.',
                        ),
                        _buildInfoRow(
                          context,
                          icon: LucideIcons.eyeOff,
                          title: 'No Tracking',
                          description:
                              'Haven has no ad trackers and no analytics. Your '
                              'encrypted location is never sold or shared with '
                              'advertisers or data brokers — only the circle '
                              'members you choose can read it.',
                        ),
                        _buildInfoRow(
                          context,
                          icon: LucideIcons.map,
                          title: 'Maps by Stadia Maps',
                          description:
                              'Map images come from Stadia Maps, built on '
                              'OpenStreetMap data. Opening the map sends your '
                              'device’s IP address to Stadia so it can deliver '
                              'map tiles. Stadia anonymizes IP addresses and '
                              'does not sell your data.',
                        ),
                        _buildInfoRow(
                          context,
                          icon: LucideIcons.code,
                          title: 'Open Source',
                          description:
                              "Haven's code is publicly auditable. Anyone "
                              'can verify that it does what it claims.',
                        ),
                        const SizedBox(height: HavenSpacing.sm),
                        const _LegalLinks(),
                        const Spacer(),
                        _Footer(colorScheme: colorScheme, textTheme: textTheme),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  /// Builds a single privacy/feature info row.
  ///
  /// Matches the onboarding `_ValuePropCard` styling so the About page
  /// reads as a continuation of the onboarding visual language.
  Widget _buildInfoRow(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String description,
  }) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Semantics(
      label: '$title. $description',
      container: true,
      child: Padding(
        padding: const EdgeInsets.only(bottom: HavenSpacing.md),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(HavenSpacing.base),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(HavenSpacing.md),
                  decoration: BoxDecoration(
                    color: colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(HavenSpacing.md),
                  ),
                  child: Icon(icon, color: colorScheme.onPrimaryContainer),
                ),
                const SizedBox(width: HavenSpacing.base),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: theme.textTheme.titleMedium),
                      const SizedBox(height: HavenSpacing.xs),
                      Text(
                        description,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Private sub-widgets
// ---------------------------------------------------------------------------

/// Legal & attribution actions: privacy policy, open-source licenses
/// (including the OSM/ODbL and Stadia entries), and the OpenStreetMap
/// "report a map issue" / "support" links, plus the compound attribution line.
class _LegalLinks extends StatelessWidget {
  const _LegalLinks();

  Future<void> _open(BuildContext context, String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } on Object catch (e) {
      // Never surface raw errors; generic message + typed debug log only.
      debugPrint('[About] link launch failed: ${e.runtimeType}');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open link')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          child: Column(
            children: [
              ListTile(
                leading: const Icon(LucideIcons.scale),
                title: const Text('Open-source licenses'),
                trailing: const Icon(LucideIcons.chevronRight),
                onTap: () => showLicensePage(
                  context: context,
                  applicationName: 'Haven',
                  applicationVersion: '0.1.0',
                  applicationLegalese: '© 2026 Haven · MIT License',
                ),
              ),
              ListTile(
                leading: const Icon(LucideIcons.flag),
                title: const Text('Report a map issue'),
                trailing: const Icon(LucideIcons.externalLink),
                onTap: () => _open(context, kOsmFixTheMapUrl),
              ),
              ListTile(
                leading: const Icon(LucideIcons.heart),
                title: const Text('Support OpenStreetMap'),
                trailing: const Icon(LucideIcons.externalLink),
                onTap: () => _open(context, kSupportOsmUrl),
              ),
            ],
          ),
        ),
        const SizedBox(height: HavenSpacing.sm),
        Text(
          '© Stadia Maps · © OpenMapTiles · © OpenStreetMap contributors\n'
          'Map data licensed under ODbL',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

/// Hero section with the Haven shield icon, name, and tagline.
class _HeroSection extends StatelessWidget {
  const _HeroSection({required this.colorScheme, required this.textTheme});

  final ColorScheme colorScheme;
  final TextTheme textTheme;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const SizedBox(height: HavenSpacing.lg),
        Text(
          'Haven',
          style: textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: HavenSpacing.xs),
        Text(
          'Private and unstoppable location sharing.',
          style: textTheme.bodyMedium?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

/// Footer row showing copyright and version information.
class _Footer extends StatelessWidget {
  const _Footer({required this.colorScheme, required this.textTheme});

  final ColorScheme colorScheme;
  final TextTheme textTheme;

  @override
  Widget build(BuildContext context) {
    final mutedStyle = textTheme.bodySmall?.copyWith(
      color: colorScheme.onSurfaceVariant,
    );

    return Column(
      children: [
        const Divider(),
        const SizedBox(height: HavenSpacing.sm),
        Text(
          'Licensed under the MIT License',
          style: mutedStyle,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: HavenSpacing.xs),
        Text('Version 0.1.0', style: mutedStyle, textAlign: TextAlign.center),
      ],
    );
  }
}
