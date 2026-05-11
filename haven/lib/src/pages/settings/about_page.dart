/// About page for Haven.
///
/// Consolidates privacy, security, and technology information
/// into a single informational page accessible from Settings.
library;

import 'package:flutter/material.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Page displaying Haven's privacy guarantees and protocol information.
///
/// This is the canonical place users can learn about end-to-end encryption,
/// the decentralised architecture, and the Marmot Protocol stack. Technical
/// details are hidden behind an [ExpansionTile] so casual users are not
/// overwhelmed, while curious users can expand the section on demand.
class AboutPage extends StatelessWidget {
  /// Creates the about page.
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: const Text('About Haven')),
      body: ListView(
        padding: const EdgeInsets.all(HavenSpacing.base),
        children: [
          // ---------- Hero ----------
          _HeroSection(colorScheme: colorScheme, textTheme: textTheme),

          const SizedBox(height: HavenSpacing.xl),

          // ---------- Your Privacy ----------
          Text(
            'Your Privacy',
            style: textTheme.titleSmall?.copyWith(color: colorScheme.primary),
          ),
          const SizedBox(height: HavenSpacing.base),
          _buildInfoRow(
            context,
            icon: LucideIcons.lock,
            title: 'Encrypted',
            description:
                'Your location is encrypted on your device before it '
                'leaves. Only the people in your circles can see where '
                'you are.',
          ),
          _buildInfoRow(
            context,
            icon: LucideIcons.cloudOff,
            title: 'No Central Server',
            description:
                'Haven has no backend that can be surveilled, hacked, or '
                'shut down. Your data flows directly between devices.',
          ),
          _buildInfoRow(
            context,
            icon: LucideIcons.eyeOff,
            title: 'No Tracking',
            description:
                'Haven uses OpenStreetMap. Your location is never sent to '
                'Google, Apple, or any advertising network.',
          ),
          _buildInfoRow(
            context,
            icon: LucideIcons.code,
            title: 'Open Source',
            description:
                "Haven's code is publicly auditable. Anyone can verify "
                'that it does what it claims.',
          ),

          const SizedBox(height: HavenSpacing.lg),

          // ---------- How It Works (collapsed by default) ----------
          _HowItWorksSection(colorScheme: colorScheme, textTheme: textTheme),

          const SizedBox(height: HavenSpacing.xl),

          // ---------- Footer ----------
          _Footer(colorScheme: colorScheme, textTheme: textTheme),

          const SizedBox(height: HavenSpacing.lg),
        ],
      ),
    );
  }

  /// Builds a single privacy/feature info row.
  ///
  /// Each row pairs a tinted icon container on the left with a bold [title]
  /// and a muted [description] on the right, consistent with the design
  /// pattern used across other settings pages.
  Widget _buildInfoRow(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String description,
  }) {
    final colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.only(bottom: HavenSpacing.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(HavenSpacing.sm),
            decoration: BoxDecoration(
              color: HavenSecurityColors.encrypted.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(HavenSpacing.sm),
            ),
            child: Icon(
              icon,
              size: 20,
              color: HavenSecurityColors.encrypted,
              semanticLabel: title,
            ),
          ),
          const SizedBox(width: HavenSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: HavenSpacing.xs),
                Text(
                  description,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Private sub-widgets
// ---------------------------------------------------------------------------

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
        Container(
          padding: const EdgeInsets.all(HavenSpacing.lg),
          decoration: BoxDecoration(
            color: HavenSecurityColors.encrypted.withValues(alpha: 0.1),
            shape: BoxShape.circle,
          ),
          child: const Icon(
            LucideIcons.shield,
            size: 48,
            color: HavenSecurityColors.encrypted,
            semanticLabel: 'Haven security shield',
          ),
        ),
        const SizedBox(height: HavenSpacing.base),
        Text(
          'Haven',
          style: textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: HavenSpacing.xs),
        Text(
          'Private location sharing for the people you trust.',
          style: textTheme.bodyMedium?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

/// Collapsible "How It Works" section describing the Marmot Protocol stack.
///
/// Collapsed by default so the protocol detail is opt-in for curious users
/// and does not clutter the page for everyone else.
class _HowItWorksSection extends StatelessWidget {
  const _HowItWorksSection({
    required this.colorScheme,
    required this.textTheme,
  });

  final ColorScheme colorScheme;
  final TextTheme textTheme;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        leading: Icon(LucideIcons.info, color: colorScheme.onSurfaceVariant),
        title: Text(
          'How It Works',
          style: textTheme.titleSmall?.copyWith(color: colorScheme.primary),
        ),
        // Collapsed by default — technical content is opt-in (this is the
        // ExpansionTile default, stated here for clarity).
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              HavenSpacing.base,
              HavenSpacing.xs,
              HavenSpacing.base,
              HavenSpacing.lg,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Haven uses the Marmot Protocol, which combines two '
                  'established technologies:',
                  style: textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: HavenSpacing.base),
                _BulletPoint(
                  colorScheme: colorScheme,
                  textTheme: textTheme,
                  label: 'MLS (Messaging Layer Security)',
                  description:
                      'An IETF standard for end-to-end encrypted group '
                      'messaging with forward secrecy and post-compromise '
                      'security.',
                ),
                const SizedBox(height: HavenSpacing.md),
                _BulletPoint(
                  colorScheme: colorScheme,
                  textTheme: textTheme,
                  label: 'Nostr',
                  description:
                      'A decentralized communication protocol that '
                      'eliminates the need for central servers. Your data '
                      'is relayed through multiple independent servers, so '
                      'no single entity can censor or surveil your '
                      'communications.',
                ),
                const SizedBox(height: HavenSpacing.base),
                Text(
                  'Together, they ensure your location data can only be '
                  'read by the members of your circles.',
                  style: textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A single bullet-point row used inside [_HowItWorksSection].
class _BulletPoint extends StatelessWidget {
  const _BulletPoint({
    required this.colorScheme,
    required this.textTheme,
    required this.label,
    required this.description,
  });

  final ColorScheme colorScheme;
  final TextTheme textTheme;
  final String label;
  final String description;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ExcludeSemantics(
          child: Padding(
            padding: const EdgeInsets.only(top: HavenSpacing.xs),
            child: Icon(
              LucideIcons.circle,
              size: 6,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        const SizedBox(width: HavenSpacing.sm),
        Expanded(
          child: RichText(
            text: TextSpan(
              style: textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
              children: [
                TextSpan(
                  text: '$label \u2014 ',
                  style: textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: colorScheme.onSurface,
                  ),
                ),
                TextSpan(text: description),
              ],
            ),
          ),
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
          '© 2024 Haven Contributors',
          style: mutedStyle,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: HavenSpacing.xs),
        Text('Version 0.1.0', style: mutedStyle, textAlign: TextAlign.center),
      ],
    );
  }
}
