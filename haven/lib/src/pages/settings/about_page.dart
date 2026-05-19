/// About page for Haven.
///
/// Consolidates privacy, security, and technology information
/// into a single informational page accessible from Settings.
library;

import 'package:flutter/material.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Page displaying Haven's privacy guarantees.
///
/// Sized to fit a single screen: hero at top, info cards in the middle,
/// footer pinned at the bottom via [Spacer].
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
        child: Padding(
          padding: const EdgeInsets.all(HavenSpacing.base),
          child: Column(
            children: [
              _HeroSection(colorScheme: colorScheme, textTheme: textTheme),
              const SizedBox(height: HavenSpacing.xl),
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
                    'Haven has no backend that can be surveilled, hacked, '
                    'or shut down. Your data flows directly between devices.',
              ),
              _buildInfoRow(
                context,
                icon: LucideIcons.eyeOff,
                title: 'No Tracking',
                description:
                    'Haven uses OpenStreetMap. Your location is never sent '
                    'to Google, Apple, or any advertising network.',
              ),
              _buildInfoRow(
                context,
                icon: LucideIcons.code,
                title: 'Open Source',
                description:
                    "Haven's code is publicly auditable. Anyone can verify "
                    'that it does what it claims.',
              ),
              const Spacer(),
              _Footer(colorScheme: colorScheme, textTheme: textTheme),
            ],
          ),
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
