/// About page for Haven.
///
/// Identity, attribution and legal information: the app's value propositions,
/// open-source licenses, the OpenStreetMap/Stadia attribution links, and the
/// version footer.
///
/// The privacy and technology explanations that used to live here now sit in
/// the Privacy section (`privacy_page.dart`), one level above About in
/// Settings, so there is exactly one place in the app that answers "what can
/// others see". Do not reintroduce a second copy here.
library;

import 'package:flutter/material.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/constants/tiles.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:haven/src/utils/external_link.dart';
import 'package:haven/src/widgets/common/disclosure_chevron.dart';
import 'package:haven/src/widgets/common/haven_logo.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Page displaying Haven's identity, attribution and legal information.
///
/// Hero, then info cards, then legal actions, then the version footer — one
/// plain scrolling column.
///
/// The footer is deliberately NOT pinned to the bottom of the viewport. This
/// page used to do that with `ConstrainedBox(minHeight:) + IntrinsicHeight +
/// Spacer`, which is the usual idiom for it, but `IntrinsicHeight` reports the
/// wrong height once `Text` wraps: the page overflowed by 48px at 100% text
/// scale on a 320dp surface and by 288px at 200%. `SliverFillRemaining` does
/// not fix it either, because `Spacer` needs a bounded height and this content
/// legitimately exceeds the viewport. Pinning is cosmetic; not clipping the
/// licenses and attribution is not.
class AboutPage extends StatelessWidget {
  /// Creates the about page.
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.aboutTitle)),
      body: SafeArea(
        child: SingleChildScrollView(
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
                          title: l10n.onboardingValueProp1Title,
                          description: l10n.onboardingValueProp1Body,
                        ),
                        _buildInfoRow(
                          context,
                          icon: LucideIcons.network,
                          title: l10n.onboardingValueProp2Title,
                          description: l10n.onboardingValueProp2Body,
                        ),
                        _buildInfoRow(
                          context,
                          icon: LucideIcons.userX,
                          title: l10n.onboardingValueProp3Title,
                          description: l10n.onboardingValueProp3Body,
                        ),
                        const SizedBox(height: HavenSpacing.sm),
                        const _LegalLinks(),
                        const SizedBox(height: HavenSpacing.xl),
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

/// Legal & attribution actions: open-source licenses (including the OSM/ODbL
/// and Stadia entries) and the OpenStreetMap "report a map issue" / "support"
/// links, plus the compound attribution line.
///
/// Note: there is deliberately no privacy-policy entry here, because Haven has
/// no published privacy policy yet (`kHavenWebsiteUrl` is still a placeholder).
/// An earlier version of this comment claimed one was rendered; it never was.
class _LegalLinks extends StatelessWidget {
  const _LegalLinks();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          child: Column(
            children: [
              ListTile(
                leading: const Icon(LucideIcons.scale),
                title: Text(l10n.aboutLicensesTitle),
                trailing: const DisclosureChevron(),
                onTap: () => showLicensePage(
                  context: context,
                  applicationName: 'Haven',
                  applicationVersion: '0.1.0',
                  applicationLegalese: l10n.aboutLicensesLegalese,
                ),
              ),
              ListTile(
                leading: const Icon(LucideIcons.flag),
                title: Text(l10n.aboutReportMapIssue),
                trailing: const Icon(LucideIcons.externalLink),
                onTap: () => openExternalLink(
                  context,
                  kOsmFixTheMapUrl,
                  logTag: 'About',
                ),
              ),
              ListTile(
                leading: const Icon(LucideIcons.heart),
                title: Text(l10n.aboutSupportOsm),
                trailing: const Icon(LucideIcons.externalLink),
                onTap: () =>
                    openExternalLink(context, kSupportOsmUrl, logTag: 'About'),
              ),
            ],
          ),
        ),
        const SizedBox(height: HavenSpacing.sm),
        Text(
          l10n.aboutMapAttribution,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
          textAlign: TextAlign.center,
        ),
      ],
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
    final l10n = AppLocalizations.of(context);
    return Column(
      children: [
        const SizedBox(height: HavenSpacing.lg),
        const HavenLogo(size: 96),
        const SizedBox(height: HavenSpacing.base),
        Text(
          l10n.aboutHeroName,
          style: textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: HavenSpacing.xs),
        Text(
          l10n.aboutHeroTagline,
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
    final l10n = AppLocalizations.of(context);
    final mutedStyle = textTheme.bodySmall?.copyWith(
      color: colorScheme.onSurfaceVariant,
    );

    return Column(
      children: [
        const Divider(),
        const SizedBox(height: HavenSpacing.sm),
        Text(
          l10n.aboutFooterLicense,
          style: mutedStyle,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: HavenSpacing.xs),
        Text(
          l10n.aboutFooterVersion('0.1.0'),
          style: mutedStyle,
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}
