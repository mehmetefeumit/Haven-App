/// Content model for the Privacy pages.
///
/// The whole of the Privacy section's copy is declared here as data, and
/// rendered by a single widget in `privacy_topic_page.dart`. The point is
/// enforcement rather than brevity: heading semantics, heading levels,
/// spacing, text styles and RTL padding are applied once in the renderer, so
/// it is structurally impossible to ship a section title that a screen reader
/// cannot navigate to, or body prose set at a size too small to read. It also
/// makes [privacyBlocksFor] the complete string manifest for the feature — one
/// switch to audit when checking translation coverage.
///
/// Topics are added to [PrivacyTopic] as their copy lands, so the enum is
/// always exhaustively covered and the hub never links to an empty page.
library;

import 'package:flutter/widgets.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/widgets/common/info_note.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// A Privacy topic, each rendered as its own route from the Privacy hub.
enum PrivacyTopic {
  /// What Haven is, why there is no account, and what the developers can see.
  whatHavenIs,

  /// The secret/public key pair, where the secret lives, and losing it.
  yourKeys,

  /// That the display name and photo are published publicly and permanently.
  publicProfile,
}

/// A group of related [PrivacyTopic]s, shown under one header on the hub.
class PrivacyTopicGroup {
  /// Creates a [PrivacyTopicGroup].
  const PrivacyTopicGroup({required this.heading, required this.topics});

  /// Resolves the group's localized header text.
  final String Function(AppLocalizations) heading;

  /// Topics in this group, in display order.
  final List<PrivacyTopic> topics;
}

/// The Privacy hub's groups, in display order.
///
/// Ordered by the question a worried reader asks first — what is this and who
/// runs it, then what identifies me, then what is already public — rather than
/// by how the implementation is layered.
const List<PrivacyTopicGroup> privacyTopicGroups = [
  PrivacyTopicGroup(
    heading: _basicsHeading,
    topics: [
      PrivacyTopic.whatHavenIs,
      PrivacyTopic.yourKeys,
      PrivacyTopic.publicProfile,
    ],
  ),
];

String _basicsHeading(AppLocalizations l10n) => l10n.privacyGroupBasicsHeading;

// ---------------------------------------------------------------------------
// Block types
// ---------------------------------------------------------------------------

/// A single renderable element of a Privacy topic page.
sealed class PrivacyBlock {
  const PrivacyBlock();
}

/// A section title within a topic. Rendered as a semantic heading at level 2.
final class PrivacyHeading extends PrivacyBlock {
  /// Creates a [PrivacyHeading].
  const PrivacyHeading(this.text);

  /// The heading text.
  final String text;
}

/// A body paragraph. Rendered as its own screen-reader node so a reader can
/// re-read one paragraph at a time.
final class PrivacyPara extends PrivacyBlock {
  /// Creates a [PrivacyPara].
  const PrivacyPara(this.text);

  /// The paragraph text.
  final String text;
}

/// The "what this means for you" block: fixed label, fixed position at the end
/// of a topic's tier-2 content.
///
/// Must be actionable or reassuring, never a restatement of the paragraphs
/// above. Where there is genuinely nothing for the reader to do, it says so.
final class PrivacyMeansForYou extends PrivacyBlock {
  /// Creates a [PrivacyMeansForYou].
  const PrivacyMeansForYou(this.text);

  /// The text of the block.
  final String text;
}

/// A callout for an honest limitation.
///
/// [HavenInfoNoteTone.warning] is reserved for limits the reader can act on;
/// everything else stays neutral so the page does not read as a string of
/// alarms.
final class PrivacyNote extends PrivacyBlock {
  /// Creates a [PrivacyNote].
  const PrivacyNote(this.text, {this.tone = HavenInfoNoteTone.neutral});

  /// The note text.
  final String text;

  /// Visual tone of the callout.
  final HavenInfoNoteTone tone;
}

/// The collapsed tier-3 region holding technical depth.
final class PrivacyMoreDetail extends PrivacyBlock {
  /// Creates a [PrivacyMoreDetail].
  const PrivacyMoreDetail(this.paragraphs);

  /// Paragraphs revealed when the reader expands the region.
  final List<String> paragraphs;
}

// ---------------------------------------------------------------------------
// Per-topic metadata and content
// ---------------------------------------------------------------------------

/// Returns the icon for [topic]'s hub tile.
///
/// Deliberately monochrome and reused from elsewhere in the app: Haven's colour
/// system promises that a coloured pixel always carries meaning, so tile icons
/// never take a security colour.
IconData privacyTopicIcon(PrivacyTopic topic) => switch (topic) {
  PrivacyTopic.whatHavenIs => LucideIcons.shieldCheck,
  PrivacyTopic.yourKeys => LucideIcons.key,
  PrivacyTopic.publicProfile => LucideIcons.globe,
};

/// Returns [topic]'s hub tile title.
///
/// Titles are front-loaded with their distinguishing word so a screen-reader
/// user scanning by heading hears what differs first (WCAG 2.4.6).
String privacyTopicTitle(AppLocalizations l10n, PrivacyTopic topic) =>
    switch (topic) {
      PrivacyTopic.whatHavenIs => l10n.privacyWhatHavenIsTitle,
      PrivacyTopic.yourKeys => l10n.privacyYourKeysTitle,
      PrivacyTopic.publicProfile => l10n.privacyPublicProfileTitle,
    };

/// Returns [topic]'s hub tile subtitle — a one-line preview of the answer.
String privacyTopicSubtitle(AppLocalizations l10n, PrivacyTopic topic) =>
    switch (topic) {
      PrivacyTopic.whatHavenIs => l10n.privacyWhatHavenIsSubtitle,
      PrivacyTopic.yourKeys => l10n.privacyYourKeysSubtitle,
      PrivacyTopic.publicProfile => l10n.privacyPublicProfileSubtitle,
    };

/// Returns the ordered content blocks for [topic].
///
/// This switch is the complete copy manifest for the Privacy section.
List<PrivacyBlock> privacyBlocksFor(
  AppLocalizations l10n,
  PrivacyTopic topic,
) => switch (topic) {
  PrivacyTopic.whatHavenIs => [
    PrivacyPara(l10n.privacyWhatHavenIsNoAccount),
    PrivacyPara(l10n.privacyWhatHavenIsNoServers),
    PrivacyMeansForYou(l10n.privacyWhatHavenIsMeansForYou),
    PrivacyMoreDetail([
      l10n.privacyWhatHavenIsDetailNoTelemetry,
      l10n.privacyWhatHavenIsDetailNoPush,
    ]),
  ],
  PrivacyTopic.yourKeys => [
    PrivacyPara(l10n.privacyYourKeysWhatTheyAre),
    PrivacyPara(l10n.privacyYourKeysSecretStaysHere),
    PrivacyPara(l10n.privacyYourKeysPublicIsSafe),
    PrivacyMeansForYou(l10n.privacyYourKeysMeansForYou),
    PrivacyNote(
      l10n.privacyYourKeysNeverShareSecret,
      tone: HavenInfoNoteTone.warning,
    ),
    PrivacyMoreDetail([
      l10n.privacyYourKeysDetailFormats,
      l10n.privacyYourKeysDetailSeparation,
    ]),
  ],
  PrivacyTopic.publicProfile => [
    PrivacyPara(l10n.privacyPublicProfileIsPublic),
    PrivacyPara(l10n.privacyPublicProfileOnSave),
    PrivacyPara(l10n.privacyPublicProfilePseudonym),
    PrivacyMeansForYou(l10n.privacyPublicProfileMeansForYou),
    PrivacyNote(
      l10n.privacyPublicProfileRemovalIsNotDeletion,
      tone: HavenInfoNoteTone.warning,
    ),
    PrivacyMoreDetail([
      l10n.privacyPublicProfileDetailKindZero,
      l10n.privacyPublicProfileDetailExifStripped,
    ]),
  ],
};
