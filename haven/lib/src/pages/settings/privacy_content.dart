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
import 'package:haven/src/constants/tiles.dart';
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

  /// What a relay is, which lists Haven keeps, and the discovery lookups.
  relays,

  /// MLS/Marmot in plain language, including the membership-change caveat.
  encryption,

  /// What circle members can observe, contrasted with what relays can.
  whatOthersSee,

  /// Metadata, traffic patterns, network address, and whether a VPN helps.
  inference,
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
  PrivacyTopicGroup(
    heading: _howLocationTravelsHeading,
    topics: [
      PrivacyTopic.relays,
      PrivacyTopic.encryption,
      PrivacyTopic.whatOthersSee,
    ],
  ),
  PrivacyTopicGroup(
    heading: _theLimitsHeading,
    topics: [PrivacyTopic.inference],
  ),
];

String _basicsHeading(AppLocalizations l10n) => l10n.privacyGroupBasicsHeading;

String _howLocationTravelsHeading(AppLocalizations l10n) =>
    l10n.privacyGroupHowLocationTravelsHeading;

String _theLimitsHeading(AppLocalizations l10n) =>
    l10n.privacyGroupTheLimitsHeading;

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

/// An outbound link to a named third party.
///
/// Kept a distinct block type rather than an inline span so the affordance is
/// a real button with a button role for assistive technology, and so the URL
/// lives in `constants/` rather than inside a translatable string.
final class PrivacyLink extends PrivacyBlock {
  /// Creates a [PrivacyLink].
  const PrivacyLink({required this.label, required this.url});

  /// Visible label — typically the bare hostname, so the destination is
  /// legible before the reader taps.
  final String label;

  /// Destination URL. Never localized.
  final String url;
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
  // Reuses the glyphs those concepts already carry elsewhere in the app:
  // `server` is the Settings → Relays icon, `lock` the encryption value prop.
  PrivacyTopic.relays => LucideIcons.server,
  PrivacyTopic.encryption => LucideIcons.lock,
  PrivacyTopic.whatOthersSee => LucideIcons.eye,
  PrivacyTopic.inference => LucideIcons.activity,
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
      PrivacyTopic.relays => l10n.privacyRelaysTitle,
      PrivacyTopic.encryption => l10n.privacyEncryptionTitle,
      PrivacyTopic.whatOthersSee => l10n.privacyWhatOthersSeeTitle,
      PrivacyTopic.inference => l10n.privacyInferenceTitle,
    };

/// Returns [topic]'s hub tile subtitle — a one-line preview of the answer.
String privacyTopicSubtitle(AppLocalizations l10n, PrivacyTopic topic) =>
    switch (topic) {
      PrivacyTopic.whatHavenIs => l10n.privacyWhatHavenIsSubtitle,
      PrivacyTopic.yourKeys => l10n.privacyYourKeysSubtitle,
      PrivacyTopic.publicProfile => l10n.privacyPublicProfileSubtitle,
      PrivacyTopic.relays => l10n.privacyRelaysSubtitle,
      PrivacyTopic.encryption => l10n.privacyEncryptionSubtitle,
      PrivacyTopic.whatOthersSee => l10n.privacyWhatOthersSeeSubtitle,
      PrivacyTopic.inference => l10n.privacyInferenceSubtitle,
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
  PrivacyTopic.relays => [
    PrivacyPara(l10n.privacyRelaysWhatIsARelay),
    PrivacyPara(l10n.privacyRelaysWhyMany),
    PrivacyPara(l10n.privacyRelaysYourLists),
    PrivacyMeansForYou(l10n.privacyRelaysMeansForYou),
    PrivacyMoreDetail([
      l10n.privacyRelaysDetailIndexers,
      l10n.privacyRelaysDetailKeyListIsPublic,
    ]),
  ],
  PrivacyTopic.encryption => [
    PrivacyPara(l10n.privacyEncryptionPerCircle),
    PrivacyPara(l10n.privacyEncryptionWhenSomeoneJoins),
    PrivacyPara(l10n.privacyEncryptionWhenSomeoneLeaves),
    // A warning rather than a plain paragraph because it is the one place the
    // reader could otherwise walk away with a false belief: Haven rotates keys
    // only on membership change, so one key covers a whole epoch and a removed
    // member keeps whatever they archived from it.
    PrivacyNote(
      l10n.privacyEncryptionKeysChangeOnMembership,
      tone: HavenInfoNoteTone.warning,
    ),
    PrivacyMeansForYou(l10n.privacyEncryptionMeansForYou),
    PrivacyMoreDetail([
      l10n.privacyEncryptionDetailMls,
      l10n.privacyEncryptionDetailEpochs,
    ]),
  ],
  PrivacyTopic.whatOthersSee => [
    // Two actors on one page, each under its own navigable heading, so the
    // contrast between "the people you chose" and "the servers in between"
    // cannot be missed by someone who reads only one half.
    PrivacyHeading(l10n.privacyWhatOthersSeeMembersHeading),
    PrivacyPara(l10n.privacyWhatOthersSeeMembersExact),
    PrivacyPara(l10n.privacyWhatOthersSeeCannotPause),
    PrivacyPara(l10n.privacyWhatOthersSeeMembersLearnKey),
    PrivacyNote(
      l10n.privacyWhatOthersSeeCoMemberIp,
      tone: HavenInfoNoteTone.warning,
    ),
    // Platform-asymmetric, and the only place in the app that states it: this
    // note is why the "Your phone" topic could be dropped without losing the
    // screenshot disclosure entirely.
    PrivacyNote(
      l10n.privacyWhatOthersSeeScreenshots,
      tone: HavenInfoNoteTone.warning,
    ),
    PrivacyHeading(l10n.privacyWhatOthersSeeRelaysHeading),
    PrivacyPara(l10n.privacyWhatOthersSeeRelaysCannot),
    PrivacyPara(l10n.privacyWhatOthersSeeRelaysCan),
    PrivacyMeansForYou(l10n.privacyWhatOthersSeeMeansForYou),
    PrivacyMoreDetail([
      l10n.privacyWhatOthersSeeDetailTag,
      l10n.privacyWhatOthersSeeDetailExpiry,
    ]),
  ],
  PrivacyTopic.inference => [
    PrivacyPara(l10n.privacyInferenceWhatIsMetadata),
    PrivacyPara(l10n.privacyInferenceActivityPattern),
    PrivacyPara(l10n.privacyInferencePresence),
    PrivacyHeading(l10n.privacyInferenceIpHeading),
    PrivacyPara(l10n.privacyInferenceIpAddress),
    PrivacyHeading(l10n.privacyInferenceVpnHeading),
    PrivacyPara(l10n.privacyInferenceVpnHelps),
    // The label is the bare hostname so the destination is legible before the
    // tap; the URL itself lives in constants, never in a translated string.
    PrivacyLink(label: l10n.aboutVpnLinkLabel, url: kMullvadUrl),
    PrivacyPara(l10n.privacyInferenceVpnLimits),
    PrivacyMeansForYou(l10n.privacyInferenceMeansForYou),
    PrivacyMoreDetail([
      l10n.privacyInferenceDetailJitter,
      l10n.privacyInferenceDetailOutOfScope,
    ]),
  ],
};
