/// About page for Haven.
///
/// Consolidates privacy, security, and technology information
/// into a single informational page accessible from Settings.
library;

import 'package:flutter/material.dart';
import 'package:haven/src/constants/tiles.dart';
import 'package:haven/src/pages/onboarding/onboarding_strings.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:haven/src/widgets/common/haven_logo.dart';
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
                          title: OnboardingStrings.valueProp1Title,
                          description: OnboardingStrings.valueProp1Body,
                        ),
                        _buildInfoRow(
                          context,
                          icon: LucideIcons.network,
                          title: OnboardingStrings.valueProp2Title,
                          description: OnboardingStrings.valueProp2Body,
                        ),
                        _buildInfoRow(
                          context,
                          icon: LucideIcons.userX,
                          title: OnboardingStrings.valueProp3Title,
                          description: OnboardingStrings.valueProp3Body,
                        ),
                        const SizedBox(height: HavenSpacing.base),
                        const _WhoCanSeeWhat(),
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

/// Non-boxed "who can see what" disclosure.
///
/// Lists each outside party in Haven's location-sharing pipeline and exactly
/// what they can observe, then recommends a VPN. The claims are verified
/// against the Marmot/Nostr protocol and Haven's implementation: relays and
/// the map provider see only network metadata (IP, timing, sizes), never
/// location plaintext or circle membership.
class _WhoCanSeeWhat extends StatelessWidget {
  const _WhoCanSeeWhat();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final bodyStyle = theme.textTheme.bodyMedium?.copyWith(
      color: scheme.onSurfaceVariant,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Who can see what', style: theme.textTheme.titleMedium),
        const SizedBox(height: HavenSpacing.sm),
        Text(
          'Your exact location is readable only by the people you choose. '
          'Here is what the main parties can and cannot see.',
          style: bodyStyle,
        ),
        const SizedBox(height: HavenSpacing.md),
        const _Actor(
          who: 'Circle members you share with',
          sees:
              'Your exact location and the display name you pick, but only '
              'inside the circles you share with them, never your other '
              'circles.',
        ),
        const _Actor(
          who: 'Relay operators',
          sees:
              'The servers that pass your messages along. They see your IP '
              'address, the public key you publish under (a random ID, not '
              'your name), the size and timing of your traffic, and which '
              'account you searched for when you look someone up. They can '
              'never read your location, your messages, your circle names, '
              'or who is in your circles.',
        ),
        const _Actor(
          who: 'The map provider (Stadia Maps)',
          sees:
              'Only while the map is open: your IP address and the area you '
              'are viewing, so it can send the right map images. Never your '
              'circles or your shared location. Stadia anonymizes IP addresses '
              'and does not sell your data.',
        ),
        const _Actor(
          who: 'Haven’s developers',
          sees:
              'Nothing. Haven runs no servers and collects no analytics. A '
              'developer could only see what a relay operator sees, and only '
              'if you used a relay they happen to run.',
        ),
        const SizedBox(height: HavenSpacing.sm),
        Text(
          'Even so, your activity is not invisible. A relay you use, or '
          'anyone watching your network, can tell that you are active, '
          'roughly when, and how often, from connection timing and message '
          'sizes.',
          style: bodyStyle,
        ),
        const SizedBox(height: HavenSpacing.md),
        Text(
          'Screenshot protection',
          style: theme.textTheme.titleSmall,
        ),
        const SizedBox(height: HavenSpacing.xs),
        Text(
          'On Android, Haven blocks screenshots and screen recording '
          'app-wide to prevent accidental location exposure. This is a '
          'system-level protection (FLAG_SECURE) that applies to every '
          'screen in the app, including the map and member lists.',
          style: bodyStyle,
        ),
        const SizedBox(height: HavenSpacing.md),
        Text('Stay more private with a VPN', style: theme.textTheme.titleSmall),
        const SizedBox(height: HavenSpacing.xs),
        Text(
          'Relays and the map provider see your IP address, and your '
          'internet provider sees which servers you reach. A trusted VPN '
          'hides your IP address from them. We recommend Mullvad. It does '
          'not change what your circle members see, and it shifts trust to '
          'the VPN provider.',
          style: bodyStyle,
        ),
        const SizedBox(height: HavenSpacing.xs),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => _open(context, 'https://mullvad.net'),
            icon: const Icon(LucideIcons.externalLink, size: 16),
            label: const Text('mullvad.net'),
          ),
        ),
      ],
    );
  }

  /// Opens [url] in the external browser, swallowing failures with a generic
  /// message (raw errors are never surfaced to the user).
  Future<void> _open(BuildContext context, String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } on Object catch (e) {
      debugPrint('[About] link launch failed: ${e.runtimeType}');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open link')),
        );
      }
    }
  }
}

/// A single actor row in [_WhoCanSeeWhat], rendered as a hanging bullet with
/// the actor name in bold followed by what they can observe.
class _Actor extends StatelessWidget {
  const _Actor({required this.who, required this.sees});

  /// The party being described (e.g. "Relay operators").
  final String who;

  /// Plain-language summary of what [who] can observe.
  final String sees;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final bodyStyle = theme.textTheme.bodyMedium?.copyWith(
      color: scheme.onSurfaceVariant,
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: HavenSpacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('•  ', style: bodyStyle),
          Expanded(
            child: Text.rich(
              TextSpan(
                style: bodyStyle,
                children: [
                  TextSpan(
                    text: who,
                    style: bodyStyle?.copyWith(
                      color: scheme.onSurface,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  TextSpan(text: ': $sees'),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Hero section with the Haven logo, name, and tagline.
class _HeroSection extends StatelessWidget {
  const _HeroSection({required this.colorScheme, required this.textTheme});

  final ColorScheme colorScheme;
  final TextTheme textTheme;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const SizedBox(height: HavenSpacing.lg),
        const HavenLogo(size: 96),
        const SizedBox(height: HavenSpacing.base),
        Text(
          'Haven',
          style: textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: HavenSpacing.xs),
        Text(
          'Private and censorship-resistant location sharing.',
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
