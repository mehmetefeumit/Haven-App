/// Renderer for a single Privacy topic.
///
/// One widget renders every topic from the data in `privacy_content.dart`, so
/// typography, spacing, heading semantics and the position of the "what this
/// means for you" block are identical on all of them and cannot drift apart as
/// topics are added.
library;

import 'package:flutter/material.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/pages/settings/privacy_content.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:haven/src/utils/external_link.dart';
import 'package:haven/src/widgets/common/info_note.dart';
import 'package:haven/src/widgets/common/more_detail_section.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// A single Privacy topic page.
///
/// Prose is set at `bodyMedium` (14sp) rather than the `bodySmall` used by the
/// app's short explainer notes: this is reading content, and 12sp does not
/// sustain a page of it. Nothing here uses `maxLines` or ellipsis — text must
/// be free to reflow at 200% scale rather than truncate.
class PrivacyTopicPage extends StatelessWidget {
  /// Creates a [PrivacyTopicPage] for [topic].
  const PrivacyTopicPage({required this.topic, super.key});

  /// The topic to render.
  final PrivacyTopic topic;

  /// Returns a route showing [topic].
  static Route<void> route(PrivacyTopic topic) => MaterialPageRoute<void>(
    builder: (_) => PrivacyTopicPage(topic: topic),
  );

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final blocks = privacyBlocksFor(l10n, topic);
    final bodyStyle = theme.textTheme.bodyMedium?.copyWith(
      color: scheme.onSurfaceVariant,
    );

    return Scaffold(
      appBar: AppBar(title: Text(privacyTopicTitle(l10n, topic))),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(HavenSpacing.base),
          children: [
            for (final block in blocks)
              _PrivacyBlockView(
                block: block,
                bodyStyle: bodyStyle,
                l10n: l10n,
              ),
          ],
        ),
      ),
    );
  }
}

/// Renders one [PrivacyBlock].
class _PrivacyBlockView extends StatelessWidget {
  const _PrivacyBlockView({
    required this.block,
    required this.bodyStyle,
    required this.l10n,
  });

  final PrivacyBlock block;
  final TextStyle? bodyStyle;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return switch (block) {
      // Level 2: the page title in the app bar is the level-1 heading, so
      // section titles sit one level under it.
      PrivacyHeading(:final text) => Padding(
        padding: const EdgeInsets.only(bottom: HavenSpacing.sm),
        child: Semantics(
          header: true,
          headingLevel: 2,
          child: Text(text, style: theme.textTheme.titleMedium),
        ),
      ),
      PrivacyPara(:final text) => Padding(
        padding: const EdgeInsets.only(bottom: HavenSpacing.md),
        child: Text(text, style: bodyStyle),
      ),
      PrivacyMeansForYou(:final text) => Padding(
        padding: const EdgeInsets.only(bottom: HavenSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(
              header: true,
              headingLevel: 3,
              child: Text(
                l10n.privacyMeansForYouLabel,
                style: theme.textTheme.titleSmall,
              ),
            ),
            const SizedBox(height: HavenSpacing.xs),
            Text(text, style: bodyStyle),
          ],
        ),
      ),
      // mergeSemantics is off: these are full paragraphs, and a merged node
      // cannot be navigated or re-read a sentence at a time.
      PrivacyNote(:final text, :final tone) => Padding(
        padding: const EdgeInsets.only(bottom: HavenSpacing.md),
        child: HavenInfoNote(
          paragraphs: [text],
          tone: tone,
          density: HavenInfoNoteDensity.comfortable,
          mergeSemantics: false,
        ),
      ),
      PrivacyLink(:final label, :final url) => Padding(
        padding: const EdgeInsets.only(bottom: HavenSpacing.md),
        child: Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton.icon(
            onPressed: () =>
                openExternalLink(context, url, logTag: 'Privacy'),
            icon: const Icon(LucideIcons.externalLink, size: 16),
            label: Text(label),
          ),
        ),
      ),
      PrivacyMoreDetail(:final paragraphs) => Padding(
        padding: const EdgeInsets.only(bottom: HavenSpacing.md),
        child: HavenMoreDetailSection(
          label: l10n.privacyMoreDetailLabel,
          expandHint: l10n.privacyMoreDetailExpandHint,
          collapseHint: l10n.privacyMoreDetailCollapseHint,
          expandedAnnouncement: l10n.privacyMoreDetailExpandedAnnouncement,
          collapsedAnnouncement: l10n.privacyMoreDetailCollapsedAnnouncement,
          children: [
            for (var i = 0; i < paragraphs.length; i++) ...[
              if (i > 0) const SizedBox(height: HavenSpacing.md),
              Text(paragraphs[i], style: bodyStyle),
            ],
          ],
        ),
      ),
    };
  }
}
