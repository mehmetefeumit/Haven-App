/// How it works page for Haven.
///
/// A plain-language overview of how Haven, Nostr, Marmot and MLS fit together,
/// reached from Settings. The copy stays at the level of design and protocol so
/// that ordinary code changes do not falsify it, and every claim-bearing
/// paragraph is registered in `docs/privacy/privacy_invariants.json`.
library;

import 'package:flutter/material.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:haven/src/widgets/common/section_header.dart';

/// Page explaining, in plain language, how Haven works.
class HowItWorksPage extends StatelessWidget {
  /// Creates the How it works page.
  const HowItWorksPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final sections = <(String, List<String>)>[
      (
        l10n.howItWorksIdentityHeading,
        [
          l10n.howItWorksIdentityKeys,
          l10n.howItWorksIdentityBackup,
          l10n.howItWorksIdentityProfile,
        ],
      ),
      (
        l10n.howItWorksNostrHeading,
        [
          l10n.howItWorksNostrRelays,
          l10n.howItWorksNostrChecks,
          l10n.howItWorksNostrYourRelays,
        ],
      ),
      (
        l10n.howItWorksEncryptionHeading,
        [
          l10n.howItWorksEncryptionStandards,
          l10n.howItWorksEncryptionCircleKeys,
        ],
      ),
      (
        l10n.howItWorksInvitationsHeading,
        [l10n.howItWorksInvitations, l10n.howItWorksMembership],
      ),
      (
        l10n.howItWorksSharingHeading,
        [l10n.howItWorksSharingWhen, l10n.howItWorksSharingUpdate],
      ),
      (l10n.howItWorksMapHeading, [l10n.howItWorksMap]),
      (l10n.howItWorksOnDeviceHeading, [l10n.howItWorksOnDevice]),
      (
        l10n.howItWorksLimitsHeading,
        [
          l10n.howItWorksLimitsAddress,
          l10n.howItWorksLimitsPatterns,
          l10n.howItWorksLimitsPeople,
        ],
      ),
    ];

    return Scaffold(
      appBar: AppBar(title: Text(l10n.howItWorksTitle)),
      body: SafeArea(
        // A plain column, not a lazy list: the page is short, and every
        // paragraph stays in the tree for screen readers and tests alike.
        child: SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: HavenSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: HavenSpacing.sm),
              _Paragraph(l10n.howItWorksIntro),
              for (final (heading, paragraphs) in sections) ...[
                HavenSectionHeader(label: heading, headingLevel: 2),
                for (final paragraph in paragraphs) _Paragraph(paragraph),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Paragraph extends StatelessWidget {
  const _Paragraph(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(
        HavenSpacing.base,
        0,
        HavenSpacing.base,
        HavenSpacing.md,
      ),
      // The app's explanatory-paragraph style (Location settings' intro, the
      // QR page), which keeps every paragraph below its section heading's size.
      child: Text(
        text,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
