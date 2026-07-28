/// Privacy hub page.
///
/// Consolidates Haven's privacy and technology explanations, which were
/// previously scattered across the About page, the relay settings footer, and
/// several in-context notes. Sits directly above About in Settings.
///
/// The hub deliberately opens with always-visible summary prose rather than a
/// bare list of chevron rows. A reader who wants a thirty-second answer gets
/// one without tapping anything; a reader who wants depth taps through to a
/// topic, and from there into that topic's collapsed detail region. That
/// layering is what lets the section carry full technical detail while staying
/// readable by someone who has never heard of Nostr.
library;

import 'package:flutter/material.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/pages/settings/privacy_content.dart';
import 'package:haven/src/pages/settings/privacy_topic_page.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:haven/src/widgets/widgets.dart';

/// Page listing the Privacy topics, under an always-visible plain-language
/// summary.
///
/// A plain [StatelessWidget] with no providers and no async state, so it is
/// fully testable on the host without the Rust bridge.
class PrivacyPage extends StatelessWidget {
  /// Creates the privacy hub page.
  const PrivacyPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.privacyTitle)),
      body: SafeArea(
        child: ListView(
          children: [
            Padding(
              // Plain text on the page surface, not a card: boxing the summary
              // would make it read as a caveat rather than the answer.
              padding: const EdgeInsets.fromLTRB(
                HavenSpacing.base,
                HavenSpacing.base,
                HavenSpacing.base,
                HavenSpacing.sm,
              ),
              child: Text(
                l10n.privacyHubSummary,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            for (final group in privacyTopicGroups) ...[
              HavenSectionHeader(
                label: group.heading(l10n),
                headingLevel: 2,
              ),
              for (final topic in group.topics)
                HavenSettingsTile(
                  key: WidgetKeys.privacyTopicTile(topic.name),
                  icon: privacyTopicIcon(topic),
                  title: privacyTopicTitle(l10n, topic),
                  subtitle: privacyTopicSubtitle(l10n, topic),
                  onTap: () => Navigator.push(
                    context,
                    PrivacyTopicPage.route(topic),
                  ),
                ),
            ],
            const SizedBox(height: HavenSpacing.base),
          ],
        ),
      ),
    );
  }
}
